# Prepare — Write Runner Scripts

After planning creates tickets in LatticeCast PM, prepare the runner scripts before starting bees.

**Write customized shell runners**, referencing `example-scripts/` as a pattern guide. Copy the deterministic `story_gate.py` and LLM adapter helpers as-is; do not reimplement their safety gates. Each project may need different context, skills, test commands, or bee pipeline steps.

## Step 1: Create directories

```bash
mkdir -p .tmp/agentic-hive .tmp/out
```

## Step 2: Write each script

Read the example scripts in `.agent-skills/agent/agentic-hive/example-scripts/` to understand the patterns, then **write customized versions** for this project:

### 2a. `run.sh` — project-specific wrapper
- Set `TABLE_ID` for this project's PM table
- Call `start.sh` with project dir, max cycles, num workers

### 2b. `start.sh` — tmux session setup
- Validate PM is running
- Kill existing session
- Start queen in tmux window 0

### 2c. `stop.sh` — kill session
- Kill tmux session; preserve worktrees and locks until their owner is confirmed stopped

### 2d. `queen.sh` — pure rule-based task dispatch (NO LLM)
- Cache column IDs at startup (`_col_cache.json`)
- Recover orphaned in_progress tickets
- Use `story_gate.py plan` to select one story's next issue, or request integration
- Process one issue at a time; blocked/unknown state stops rather than skipping
- On `MERGE: <id>`, call `story_gate.py land`; only success permits another story
- Preserve failures and locks; never reset/clean a worktree or remove an unowned lock

### 2e. `bee.sh` — bash infra + LLM code
- Extract row_id from task description
- Set status to `in_progress` immediately (bash, not LLM)
- Build context from AGENTS.md (with CLAUDE.md fallback), README.md, skills, ticket doc
- Pipeline: implement → test → review → commit to story → issue merged
- Queen alone verifies/merges the completed story into main
- PM status updates via bash helpers (never LLM)
- Sources `llm.sh` for the actual LLM call — don't inline a provider CLI here

### 2f. Deterministic helpers — copy, don't rewrite

Copy these five files as-is from `example-scripts/`:

- `story_gate.py` — serial PM/Git scheduling and verified main integration
- `llm.sh` — selects and runs `LLM_PROVIDER=claude|codex|hermes`
- `format_claude_stream.py` — formats Claude stream-json events
- `format_codex_stream.py` — formats Codex JSONL events
- `format_hermes_stream.py` — formats Hermes JSONL events

Provider-specific CLI details belong in `llm.sh`; `bee.sh` stays
provider-neutral.

### 2g. `.env` — per-project values

Write `.tmp/agentic-hive/.env` from `.env.example`:

```bash
LC_API=http://localhost:13491/api/v1
PM_USER=lattice
PM_PASS=
TABLE_ID=pm
WORKSPACE_ID=<uuid>
PROJECT_DIR=/abs/path/to/project
SKILLS_DIR=/abs/path/to/project/.agent-skills
LLM_PROVIDER=claude
LLM_PROJECT_DIR=/abs/path/to/project
HIVE_VERIFY_CMD=<project checks against the current worktree>
# Optional separate story-level command; falls back to HIVE_VERIFY_CMD.
HIVE_STORY_VERIFY_CMD=<full integrated checks against the current worktree>
MONITOR_CODEX_SESSION_ID=
# CLAUDE_MODEL=sonnet
# CODEX_MODEL=gpt-5.6-codex
# HERMES_MODEL=deepseek-flash
# HERMES_PROVIDER=deepseek
# HERMES_BASE_URL=https://api.deepseek.com/v1
# DEEPSEEK_API_KEY is injected by the runner/secret store; never write it here.
```

That's it. The helpers (`pm_*`, `lc_*`) are sourced from the skill,
not duplicated per project:

```bash
# at the top of queen.sh / bee.sh:
set -a
source "${SCRIPT_DIR}/.env"
set +a
source "${SKILLS_DIR}/developing/project-management/pm_tool.sh"
# pm_tool.sh auto-sources its bundled lc_api.sh
```

The story gate requires a nonempty verification command and runs it from a
detached integration worktree combining current main and the story. It exports
`PROJECT_DIR` and `HIVE_INTEGRATION_DIR` pointing there, plus `HIVE_REPO_ROOT`
and `HIVE_STORY_ID`. Ensure Docker/build commands use that source tree (and
initialize dependencies/submodules when needed); testing containers mounted to
the original checkout does not validate the candidate. Verification must leave
the candidate clean. Repository commit hooks must run normally, never be bypassed.

### 2h. Monitor configuration

Read [monitor.md](monitor.md) before selecting a monitor. For the Codex cron
bridge, write `monitor-cron.sh` from the example and set
`MONITOR_TMUX_TARGET=<session>:<window>`. It must submit to that real pane:
when busy send `Escape`, then literal prompt + `C-m`; never use `Enter` or
`Tab`.

## Customization points per project

When writing scripts, tailor these to the specific project:

| What | Customize |
|------|-----------|
| **Context files** | Which files to load (AGENTS.md, CLAUDE.md, README.md, .tmp/llm*.md) |
| **Skills loaded** | Which `Skill(developing-*)` to include in bee prompt |
| **Test commands** | FE: svelte-check, build. BE: pytest, ast.parse. Or project-specific |
| **Num workers** | 1; a story must land in main before another starts |
| **Bee prompt** | Task-specific rules, file restrictions, coding patterns |

## File layout after prepare

```
.tmp/agentic-hive/
├── .env                    ← per-project: LC_API, WORKSPACE_ID, TABLE_ID, …
├── .env.example            ← template for the local .env
├── run.sh                  ← bash run.sh — calls start.sh
├── start.sh                ← tmux session setup
├── stop.sh                 ← kill session
├── queen.sh                ← pure rule-based task dispatch
├── story_gate.py           ← deterministic scheduling + integration gate
├── bee.sh                  ← bash infra + LLM code
├── llm.sh                  ← Claude/Codex/Hermes provider adapter
├── format_claude_stream.py ← Claude stream-json formatter
├── format_codex_stream.py  ← Codex JSONL formatter
├── format_hermes_stream.py ← Hermes JSONL formatter
└── monitor-cron.sh         ← optional cron → Codex resume bridge
```

PM/LC helpers (`pm_*`, `lc_*`) live in the skill submodule, not in
`.tmp/agentic-hive/`. Scripts source them from `${SKILLS_DIR}`.

## Checklist before running

- [ ] LatticeCast PM running (`curl localhost:13491/api/v1/status`)
- [ ] `TABLE_ID` set in `.tmp/agentic-hive/.env`
- [ ] Shell runners + `story_gate.py` + all 4 LLM helpers in place
- [ ] Story verification command configured and confirmed to test the candidate worktree
- [ ] `_col_cache.json` will be auto-created by queen at startup
