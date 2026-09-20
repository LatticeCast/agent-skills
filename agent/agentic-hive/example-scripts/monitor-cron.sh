#!/usr/bin/env bash
# monitor-cron.sh — cron entrypoint: log hive health, then trigger its actual
# attached Codex tmux pane.
# Usage: bash monitor-cron.sh <project_dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

PROJECT_DIR="${1:?Usage: monitor-cron.sh <project_dir>}"
PROJECT_DIR="$(cd "${PROJECT_DIR}" && pwd)"
: "${MONITOR_TMUX_TARGET:?MONITOR_TMUX_TARGET=<session>:<window> must be set in .env}"

OUT_DIR="${PROJECT_DIR}/.tmp/out"
LOCK_FILE="${OUT_DIR}/hive-monitor.lock"
RUN_LOG="${OUT_DIR}/hive-monitor-cron.log"
mkdir -p "${OUT_DIR}"

exec 9>"${LOCK_FILE}"
flock -n 9 || exit 0

STAMP="$(date '+%Y-%m-%d %H:%M:%S %z')"
PROMPT="Check ${OUT_DIR}/hive-monitor.log and ${OUT_DIR}/queen.log, then report the current hive status in this chat. Trigger time: ${STAMP}."
printf '%s cron tmux target=%s\n' "${STAMP}" "${MONITOR_TMUX_TARGET}" >> "${RUN_LOG}"

tmux has-session -t "${MONITOR_TMUX_TARGET%%:*}" || exit 1
PANE="$(tmux capture-pane -p -t "${MONITOR_TMUX_TARGET}" -S -80)"
if grep -qE 'Working \(|Messages to be submitted after next tool call|Queued follow-up inputs' <<<"${PANE}"; then
  tmux send-keys -t "${MONITOR_TMUX_TARGET}" Escape
  sleep 0.4
fi
tmux send-keys -t "${MONITOR_TMUX_TARGET}" -l "${PROMPT}"
sleep 0.2
tmux send-keys -t "${MONITOR_TMUX_TARGET}" C-m
tmux capture-pane -p -t "${MONITOR_TMUX_TARGET}" -S -80 > "${OUT_DIR}/hive-monitor-last.md"
