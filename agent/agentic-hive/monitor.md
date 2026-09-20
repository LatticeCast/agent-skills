# Monitor — Hive Supervision

The hive does not supervise itself. After the supervising agent starts
`run.sh`, it must arm one monitor at a 2–3 minute cadence. A monitor is valid
only if each tick both records a timestamped result and delivers that result
to the supervising conversation. Stop it when the queen reports completion.

## Select a delivery method

Choose the native capability of the supervising provider first. When the
supervising conversation is an attached tmux Codex pane, submit a monitor
prompt with `tmux send-keys -l "$PROMPT"` followed by
`tmux send-keys C-m`. **Do not use `Enter`**: it is not a reliable tmux submit
key for this flow. After submission, capture the pane and verify the prompt or
its resulting work appears; a command exit code alone does not prove delivery.

| Supervising provider | Preferred monitor | When to use it |
|---|---|---|
| Claude Code | Claude Code's native Monitor/cron capability | Preferred when the Claude Code host exposes it; configure its schedule to submit the status prompt to this conversation. |
| Codex | Codex host Monitor/scheduled wakeup | Preferred when the host can wake the same conversation and emit the report. |
| Codex with host scheduler unavailable | `monitor-cron.sh` → `codex exec resume` | Use the checked-in bridge with a saved Codex session ID. |
| Any provider with no chat-resume capability | Dedicated monitor session using `llm.sh` | It preserves an audit log, but does **not** satisfy conversation delivery by itself; the supervisor must inspect and report it. |

Native provider features vary by installed version and host. Use the provider's
native configuration instead of inventing CLI flags. For example, Claude
Code's Monitor/cron feature should own the schedule and submit the prompt;
the local `claude --help` CLI may not expose an equivalent standalone cron
command.

## Monitor prompt and checks

Every tick reads `.tmp/out/queen.log`, worker logs, and PM status, then reports
the current ticket, step, elapsed time, and one of these signals:

| Signal | Meaning and required action |
|---|---|
| `ORCH_DEAD` | Queen exited; inspect logs and restart only when appropriate. |
| `ALERT` (`TIMEOUT`, `FAILED`, or `ERROR`) | Investigate before allowing more work. |
| `API_ERROR` twice | Inspect `docker compose logs backend`. |
| Same ticket in `testing` for 30+ minutes | Bee is likely hung; reap or investigate. |
| `ALL DONE!` and queue empty | Verify the final state, report summary, then stop monitoring. |

On a `TIMEOUT`, inspect `git log --oneline -5`. A bee can commit before the
900-second queen timeout, leaving PM at `testing` or `review`; if the ticket is
actually integrated, update it to `merged` so it is not repeated.

## Codex cron bridge

Use this only when Codex's host Monitor cannot remain active.

1. Set `MONITOR_CODEX_SESSION_ID` in `.tmp/agentic-hive/.env`.
2. Copy `example-scripts/monitor-cron.sh` into `.tmp/agentic-hive/`.
3. Install one cron entry:

```cron
*/2 * * * * cd /abs/project && bash .tmp/agentic-hive/monitor-cron.sh /abs/project >> .tmp/out/hive-monitor-cron.log 2>&1
```

The script loads `.env`, locks overlapping ticks with `flock`, writes the
trigger time, and runs `codex exec resume` with the status prompt. After its
first tick, verify both `.tmp/out/hive-monitor-cron.log` and that this chat
received the report. A zero process exit alone is not proof of delivery.

Remove the cron entry when the hive completes.

## Dedicated monitor session (fallback)

When a provider cannot resume the supervising conversation, a project-local
`monitor.sh` may source `.env` and `llm.sh`, call `llm_run` every 180 seconds,
and append results to `.tmp/out/monitor.log`. This is useful for independent
health analysis, but it is not a replacement for an in-chat report.

Do not arm a monitor for a single ticket being watched interactively or while
debugging the hive scripts themselves.
