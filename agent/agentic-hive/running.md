# Running — Start, Monitor, Stop

## Start

```bash
bash .tmp/agentic-hive/run.sh          # 1 bee, 50 cycles
bash .tmp/agentic-hive/run.sh 50 1     # serial stories, 50 cycles
```

## Monitor — REQUIRED

Immediately after starting the hive, read [monitor.md](monitor.md) and arm a
supervising monitor. It must report into the supervising conversation, not
only a terminal log. Stop it when the hive finishes.

## Window inspection (live)

```bash
tmux attach -t <project-folder-name>
```

Tmux windows: `0:queen  1:w1-task-182`. Requests for multiple workers are
normalized to one: finish → verify → merge main → next story.

## Stop

```bash
bash .tmp/agentic-hive/stop.sh
```

Or from inside tmux: `Ctrl-B` then `:kill-session`

## Recovery

On startup, queen auto-recovers orphaned tickets:
- If `in_progress` tickets exist but no tmux bee window matches → reset to `todo`
- Partial code is preserved. A dirty story worktree blocks a new bee; inspect
  and resolve/commit the partial work before returning the issue to `todo`.
- An integration failure stops queen and marks the story `debugging` where PM
  is reachable. Inspect `.tmp/story-merge-<id>-*` and the story worktree; main
  does not move on a failed verification/conflict. Reconcile issues, then retry.
- Never remove `_git.lock` until its owning process is confirmed stopped.
- Newly integrated story branches remain available as ancestry evidence.

## Logs

```
.tmp/out/
├── queen.log
├── worker_1.log
└── worker_2.log
```

## Track Progress

Open LatticeCast PM board in browser:
```
http://localhost:13491/<workspace>/<table>
```

Switch to Sprint Board (Kanban) view to see ticket flow:
`todo → in_progress → testing → review → merged`.

## Runner regression tests

Run inside the project's tmux session, without starting real bees or contacting
the live PM service:

```bash
HIVE_TEST_TMP="$PWD/.tmp" PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s .agent-skills/agent/agentic-hive/tests -v
```

Fixtures use isolated Git repositories under `.tmp/` and a local fake PM server.
