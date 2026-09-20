#!/bin/bash
# llm.sh — provider-neutral CLI adapter for agentic-hive workers
#
# Public interface:
#   llm_validate
#   llm_run <prompt> <log_file>
#   llm_stop <worker_pid> [TERM|KILL]
#
# Select a provider with LLM_PROVIDER=claude|codex|hermes. LLM_BACKEND remains
# supported as a compatibility alias for existing hive configurations.

LLM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${LLM_SCRIPT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

LLM_PROVIDER="${LLM_PROVIDER:-${LLM_BACKEND:-claude}}"
LLM_BACKEND="${LLM_PROVIDER}"
LLM_PROJECT_DIR="${LLM_PROJECT_DIR:-${PROJECT_DIR:-$PWD}}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CODEX_BIN="${CODEX_BIN:-codex}"
HERMES_BIN="${HERMES_BIN:-hermes}"

_llm_print_command() {
  local provider="$1"
  shift
  printf 'llm.sh: dry run (%s):' "$provider"
  printf ' %q' "$@"
  printf ' < <prompt-on-stdin>\n'
}

llm_validate() {
  case "$LLM_PROVIDER" in
    claude)
      command -v "$CLAUDE_BIN" >/dev/null 2>&1 || {
        echo "llm.sh: claude executable not found: ${CLAUDE_BIN}" >&2
        return 127
      }
      [ -f "${LLM_SCRIPT_DIR}/format_claude_stream.py" ] || {
        echo "llm.sh: missing formatter: ${LLM_SCRIPT_DIR}/format_claude_stream.py" >&2
        return 1
      }
      ;;
    codex)
      command -v "$CODEX_BIN" >/dev/null 2>&1 || {
        echo "llm.sh: codex executable not found: ${CODEX_BIN}" >&2
        return 127
      }
      [ -f "${LLM_SCRIPT_DIR}/format_codex_stream.py" ] || {
        echo "llm.sh: missing formatter: ${LLM_SCRIPT_DIR}/format_codex_stream.py" >&2
        return 1
      }
      ;;
    hermes)
      command -v "$HERMES_BIN" >/dev/null 2>&1 || {
        echo "llm.sh: hermes executable not found: ${HERMES_BIN}" >&2
        return 127
      }
      [ -f "${LLM_SCRIPT_DIR}/format_hermes_stream.py" ] || {
        echo "llm.sh: missing formatter: ${LLM_SCRIPT_DIR}/format_hermes_stream.py" >&2
        return 1
      }
      ;;
    *)
      echo "llm.sh: unknown LLM_PROVIDER='${LLM_PROVIDER}' (known: claude, codex, hermes)" >&2
      return 2
      ;;
  esac
}

_llm_run_claude() {
  local prompt="$1"
  local log_file="$2"
  local -a command=(
    "$CLAUDE_BIN" -p
    --dangerously-skip-permissions
    --no-session-persistence
    --output-format=stream-json
    --verbose
  )
  [ -z "${CLAUDE_MODEL:-}" ] || command+=(--model "$CLAUDE_MODEL")

  if [ "${LLM_DRY_RUN:-0}" = "1" ]; then
    _llm_print_command claude "${command[@]}"
    return 0
  fi

  if (
    set +e
    printf '%s\n' "$prompt" \
      | env CLAUDECODE= "${command[@]}" 2>&1 \
      | python3 -u "${LLM_SCRIPT_DIR}/format_claude_stream.py" \
      | tee -a "$log_file"
    exit "${PIPESTATUS[1]}"
  ); then
    return 0
  else
    return $?
  fi
}

_llm_run_codex() {
  local prompt="$1"
  local log_file="$2"
  local -a command=(
    "$CODEX_BIN" exec
    --json
    --color never
    --ephemeral
    --dangerously-bypass-approvals-and-sandbox
    --cd "$LLM_PROJECT_DIR"
  )
  [ -z "${CODEX_MODEL:-}" ] || command+=(--model "$CODEX_MODEL")
  command+=(-)

  if [ "${LLM_DRY_RUN:-0}" = "1" ]; then
    _llm_print_command codex "${command[@]}"
    return 0
  fi

  if (
    set +e
    printf '%s\n' "$prompt" \
      | "${command[@]}" 2>&1 \
      | python3 -u "${LLM_SCRIPT_DIR}/format_codex_stream.py" \
      | tee -a "$log_file"
    exit "${PIPESTATUS[1]}"
  ); then
    return 0
  else
    return $?
  fi
}

_llm_run_hermes() {
  local prompt="$1"
  local log_file="$2"
  local -a command=(
    "$HERMES_BIN" chat
    --query-file -
    --oneshot
    --format stream-json
    --yolo
    --in "$LLM_PROJECT_DIR"
  )
  [ -z "${HERMES_MODEL:-}" ] || command+=(--model "$HERMES_MODEL")
  [ -z "${HERMES_PROVIDER:-}" ] || command+=(--provider "$HERMES_PROVIDER")

  if [ "${LLM_DRY_RUN:-0}" = "1" ]; then
    _llm_print_command hermes "${command[@]}"
    return 0
  fi

  if (
    set +e
    printf '%s\n' "$prompt" \
      | "${command[@]}" 2>&1 \
      | python3 -u "${LLM_SCRIPT_DIR}/format_hermes_stream.py" \
      | tee -a "$log_file"
    exit "${PIPESTATUS[1]}"
  ); then
    return 0
  else
    return $?
  fi
}

llm_run() {
  local prompt="${1:?llm_run requires a prompt}"
  local log_file="${2:?llm_run requires a log file}"

  llm_validate || return $?
  case "$LLM_PROVIDER" in
    claude) _llm_run_claude "$prompt" "$log_file" ;;
    codex) _llm_run_codex "$prompt" "$log_file" ;;
    hermes) _llm_run_hermes "$prompt" "$log_file" ;;
  esac
}

_llm_signal_tree() {
  local pid="$1"
  local signal="$2"
  local child

  while read -r child; do
    [ -z "$child" ] || _llm_signal_tree "$child" "$signal"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
  kill "-${signal}" "$pid" 2>/dev/null || true
}

llm_stop() {
  local worker_pid="${1:?llm_stop requires a worker PID}"
  local signal="${2:-TERM}"

  if [[ ! "$worker_pid" =~ ^[0-9]+$ ]] || [ "$worker_pid" -le 1 ]; then
    echo "llm.sh: refusing invalid worker PID: ${worker_pid}" >&2
    return 2
  fi
  case "$signal" in
    TERM|KILL) ;;
    *)
      echo "llm.sh: unsupported stop signal: ${signal} (known: TERM, KILL)" >&2
      return 2
      ;;
  esac

  # Pipelines add intermediate shells, so walk descendants deepest-first
  # before signaling the work() wrapper itself.
  _llm_signal_tree "$worker_pid" "$signal"
}
