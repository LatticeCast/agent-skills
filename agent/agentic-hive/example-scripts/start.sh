#!/bin/bash
# start.sh — Start the multi-worker orchestrator in a tmux session
# Usage: bash start.sh <project_dir> [max_cycles] [num_workers]
# Monitor: tmux attach -t <project_folder_name>
# Stop: bash stop.sh <project_dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

PROJECT_DIR="${1:?Usage: bash start.sh <project_dir> [max_cycles] [num_workers]}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
MAX_CYCLES="${2:-50}"
NUM_WORKERS="${3:-1}"
if [ "$NUM_WORKERS" != 1 ]; then
  echo "Serial story integration requires one worker; ignoring num_workers=${NUM_WORKERS}"
  NUM_WORKERS=1
fi
SESSION="$(basename "$PROJECT_DIR")"

# Validate LatticeCast PM is running
if ! curl -s "${LC_API%/api/v1}/status" 2>/dev/null | grep -q '"ok"'; then
  echo "ERROR: LatticeCast PM is not running."
  echo "Start it: cd <LatticeCast-repo> && docker compose up -d backend frontend"
  echo "Or clone: git clone https://github.com/LatticeMage/LatticeCast.git"
  exit 1
fi

if [ ! -f "${PROJECT_DIR}/AGENTS.md" ] && [ ! -f "${PROJECT_DIR}/CLAUDE.md" ]; then
  echo "WARNING: neither ${PROJECT_DIR}/AGENTS.md nor CLAUDE.md was found."
  echo "Add agent instructions before starting autonomous workers."
fi

# Kill existing session if any
tmux kill-session -t "$SESSION" 2>/dev/null || true

# A lock may belong to an integration still running. Never remove it here.

mkdir -p "${PROJECT_DIR}/.tmp/out"

# Create tmux session with queen in window 0
tmux new-session -d -s "$SESSION" -n "queen" \
  "bash ${SCRIPT_DIR}/queen.sh '${PROJECT_DIR}' ${MAX_CYCLES} ${NUM_WORKERS}; echo 'Queen ended. Press enter.'; read"

echo "========================================="
echo " ${SESSION} started"
echo "========================================="
echo ""
echo " Project:       ${PROJECT_DIR}"
echo " tmux session:  ${SESSION}"
echo " Monitor:       tmux attach -t ${SESSION}"
echo " Stop:          bash ${SCRIPT_DIR}/stop.sh ${PROJECT_DIR}"
echo " Max cycles:    ${MAX_CYCLES}"
echo " Workers:       ${NUM_WORKERS}"
echo ""
echo " Window layout:"
echo "   0: queen — task planner + coordinator"
echo "   1-${NUM_WORKERS}: bees — each in its own tmux window"
echo ""
echo " Logs:"
echo "   ${PROJECT_DIR}/.tmp/out/queen.log"
echo "   ${PROJECT_DIR}/.tmp/out/worker_1.log .. worker_${NUM_WORKERS}.log"
echo ""
