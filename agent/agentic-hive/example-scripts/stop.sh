#!/bin/bash
# stop.sh — Stop the tmux orchestrator session and all workers
# Usage: bash stop.sh [project_dir]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

PROJECT_DIR="${1:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd || echo "$PROJECT_DIR")"
SESSION="$(basename "$PROJECT_DIR")"

echo "Stopping tmux session: ${SESSION}"
tmux kill-session -t "$SESSION" 2>/dev/null && echo "Stopped." || echo "No session found."

# Integration/verification children may still be exiting. Leave locks and
# failed worktrees intact; only their confirmed owner may release them.
echo "Worktrees and locks preserved; inspect any interrupted integration before restarting."
