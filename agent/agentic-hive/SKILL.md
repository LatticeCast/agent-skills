---
name: agent/agentic-hive
description: Start the autonomous multi-agent dev loop — a queen + bees in tmux solving tickets from LatticeCast PM
argument-hint: plan | running | status
version: 0.40.3
---

# agentic-hive — Autonomous Dev Loop

Start a tmux-based queen that runs N bees in parallel to solve project tickets autonomously.

## Flow

```
1. User calls /agentic-hive plan
2. Planning: discuss design → write .tmp/llm.design.*.md for review
3. User approves → create tickets in LatticeCast PM
5. User approve start bees
6. Bees: query PM → pick todo ticket → worktree branch → implement → update status → merge
```

## Ticket Sizing — 900s Hard Cap

Every bee has a **900-second wall clock** before the queen
gives up on it and kills the tmux window. This is non-negotiable —
don't raise it. If a ticket can't be completed in 15 minutes of
bee time, **the ticket is too big — split it before opening**.

Practical sizing rules when filing tickets:

- **One testable behavior, not one layer or file.** A task may touch frontend,
  backend, storage, and tests when that is required to deliver one coherent
  behavior end-to-end. Split only at a real, independently testable behavior
  boundary; never split a feature into frontend-only and backend-only tickets.
- **One topic** (for tests this is enforced by `developing/e2e`'s
  one-topic-per-file rule).
- **<300 lines of new code.** Skim the description: if it sounds like
  "add column type X _and_ wire it through 4 views", that's 5 tickets,
  not 1.
- **Smoke test rerunable in <60s.** Tests that need long-running
  Docker setup or external services blow the budget on docker compose
  warm-up alone.

Signals you went too big:
- Queen log shows `Still working: [N] (900s)` → `TIMEOUT after
  900s` → ticket should be split.
- Bee hits `debugging` 3+ times — usually means the ticket
  description doesn't constrain the surface area enough.

Recovery from a TIMEOUT: see "Recovery rule" below.

## Prerequisites

- **LatticeCast PM running** — `http://localhost:13491/api/v1/status` must respond
- See `Skill(developing/project-management)` for setup (git clone + docker compose up)
- `README.md` — project overview

## Branch Hierarchy

Tickets follow a strict 3-level hierarchy: **Epic → Story → Issue**

| Level | Branch base | Merges into |
|-------|-------------|-------------|
| Epic  | (no branch — grouping only) | — |
| Story | declared `Base Story` (`main` or another story) | `main` (when all issues merged) |
| Issue | story branch | story branch |

```
main
└── story/{story-row-id}        ← base: main, or its declared Base Story branch
    ├── task-{row-id} commit    ← serial ticket commit on the story branch
    ├── bug-{row-id} commit
    └── final integrated verification commit (if needed)
```

**One story has one persistent worktree and branch.** Bees process one ticket
at a time per story and commit directly to that story branch; they never make
issue branches. This keeps related controller/store/UI work on one integrated
code state. Merge the story into `main` only after all child tickets and the
story-level verification pass.

**Story dependency base rule:** `Parent` always remains the epic row for PM
hierarchy. Each story doc MUST declare `## Base Story` with exactly one value:
`- main` or `- story-<row-id>`. A dependent story is created from the declared
story branch. Do not start it until that branch exists; if it is already merged
and its branch was cleaned up, create from `main` because it contains the same
commits.

## Bee Workflow

### On Start — Read These First

1. `README.md` and Compose — project overview, architecture, runtime topology
2. **Query LatticeCast PM** — use `Skill(developing/project-management)` "Query Tickets" for current status
3. Any `.tmp/llm*.md` files and the parent story/issue docs — design docs, API specs, decisions, and work logs
4. **Load `Skill(developing/programming)`** + **`Skill(developing/project-management)`**
5. Trace the source path named by the issue before editing; a symptom alone is not a root cause.

### Step 1: Identify Parent Story Branch

Before creating a worktree, look up the issue's parent story in LatticeCast PM:

```bash
# Get the issue row to find parent story row_id
ISSUE_ROW_ID="<row_id>"
TABLE_ID="<table_id>"
# From row_data, get the Parent column value (= story row_id)
# Then fetch that story row to get its type-<row_id> key (e.g. story-5)
# Story branch name: story/{story-key-lowercase}  e.g. story/story-5
STORY_BRANCH="story/<story-key-lowercase>"
```

Ensure the story branch exists; create it from main if not:
```bash
git checkout main
git checkout -b "$STORY_BRANCH" 2>/dev/null || git checkout "$STORY_BRANCH"
```

### Step 2: Reuse the Persistent Story Worktree

```bash
STORY_BRANCH="story/story-<parent-row-id>"
STORY_WORKTREE=".tmp/story_<parent-row-id>"
git worktree add "$STORY_WORKTREE" "$STORY_BRANCH"  # only if it does not yet exist
cd "$STORY_WORKTREE"
```

All tickets for this story use this same worktree serially. Tickets from other
stories may use their own story worktrees in parallel.

### Step 3: Pick Ticket → Read Ticket → Read Story → Then Claim
- Query LatticeCast PM for `todo` issues (type=task or type=bug).
- **READ THE COMPLETE ISSUE DOC FIRST** via
  `pm_read_doc <issue_row_id>` (the PM template's default doc blob).
  - Title is just a short summary — the documents are the specification.
  - If a previous bee attempted the issue, its doc has the work log and what
    remains.
- Resolve its `Parent` from the issue, fetch that parent story row, then
  **READ THE COMPLETE STORY DOC** via
  `pm_read_doc <story_row_id>` (the PM template's default doc blob).
  - The story doc is the authoritative root-cause, data-flow, legacy-removal,
    dependency, and integration specification for the issue.
  - Reconcile the issue with the story before editing; it may not reintroduce
    a rejected legacy path or contradict the story's target invariants.
- Only after both reads and both gates pass, update PM status to `in_progress`.
- Append to the issue doc: `- {timestamp} Picked up by W{id}; read story-<id> and issue spec`.
- Work on ONLY that ticket.

### Step 3.1: Ticket Quality Gate — Refuse Incomplete Work

Before changing status or opening a worktree, verify that the issue doc has:
`## Current Behavior and Evidence`, `## Root Cause`, `## Target Invariants`,
`## End-to-End Data Flow`, `## Legacy Paths to Remove or Replace`,
`## Exact Scope`, and `## Acceptance Matrix`. Verify that the parent story doc
has `## Base Story`, `## Context Read`, `## Current Behavior and Evidence`,
`## Root Cause`, `## Target Invariants and Data Flow`,
`## Legacy Paths to Remove or Replace`, and
`## Issue Dependency and Integration Plan`.

If any section is missing, vague, contradicted by the source, or leaves an
active legacy path unspecified, **do not implement**. Append the missing
evidence to the ticket doc, set status to `debugging`, and return it to the
planner. A bee must never invent a design to make an invalid ticket pass.

### Step 3.2: Parent-Story Gate — Refuse Orphan Issues

Before dispatching any `task` or `bug`, resolve its PM `Parent` field and fetch
that row. It must exist and have `Type=story`. A missing parent, an epic
parent, or any non-story parent is a planning error: do not create a worktree,
do not change the issue to `in_progress`, and do not implement it. Mark it
`debugging` with the parent failure and return it to the planner.

**IMPORTANT: API uses `row_id` (BIGINT, integer) in URL paths and JSON.
The v0.40 squash renamed the old `row_number` field to `row_id`; the
legacy UUID row identifier is long gone.**

### Step 3.5: Check if Test Ticket
- Check the ticket's Tags column in `row_data`
- If tags contain `"test"` → this is a **test ticket**, go to Step 4T instead of Step 4
- If tags do NOT contain `"test"` → normal implementation, go to Step 4

### Step 4T: Test Ticket (title starts with `e2e_test_` or tags include `"test"`)
Instead of writing application code, write + run one e2e test.

1. Load `Skill(developing/e2e)` — follow its two-container
   architecture (e2e runs the script, browser owns Chromium).
2. Parse the test filename from the ticket title (the
   `e2e_test_<scope>_<topic>.py` token).
3. Bring both services up:
   `docker compose --profile test up -d browser e2e`
4. Write the test at `e2e/<filename>.py`, following the skill's
   "one topic per file" rule and connecting via
   `pw.chromium.connect(os.environ['BROWSER_WS'])`.
5. Run it:
   `docker compose exec -T e2e python3 /scripts/<filename>.py`
6. Exit 0 → append `PASS` + any screenshot paths to ticket doc, go to
   Step 5 (commit).
   Non-zero → append stderr to doc, set status to `debugging`, retry
   (max 3 attempts per Bee Rules).

### Step 4: Implement — MUST update doc continuously
- Make the smallest possible change to complete the ticket
- **Append to doc** after each significant step:
  - `- {timestamp} Reading {file} to understand existing pattern`
  - `- {timestamp} Creating {file} with {description}`
  - `- {timestamp} Modifying {file}: {what changed}`
  - `- {timestamp} Decision: {why I chose X over Y}`
- Stay in scope — don't refactor unrelated code
- **After ANY FE visual change**, take a Playwright snapshot via `docker compose exec browser` and verify it looks correct

### Step 5: Test, Format, Lint, Commit
Use `Skill(developing/programming)` workflow:
- Update PM status → `testing` via `PUT /api/v1/tables/{table_id}/rows/{row_id}`
- Run tests (if fail → `debugging`, append error to doc)
- Format + lint
- Commit → update PM status to `review`

### Step 6: Leave the Ticket Commit on the Story Branch

The ticket commit is already on the persistent story branch. Do not create,
merge, or delete an issue branch/worktree. Update PM status → `merged`.

### Step 7: Check if All Story Issues Done → Merge Story into Main

After marking the issue merged, check sibling issues in PM:

```bash
# Query all rows in table, filter by Parent = <story_row_id>
# If ALL sibling issues have status=merged:
git checkout main
git merge "$STORY_BRANCH"
git branch -d "$STORY_BRANCH"
# Update story PM status → merged
```

If siblings are **not all merged**, leave the story branch open.

### Step 8: Complete
Bee leaves the PM status at `merged`. Queen polls PM to detect completion —
no trigger files are needed.

## Bee Rules

- **ONE ticket per session.** Do not batch multiple tickets.
- **Never ask questions.** Make reasonable decisions and document them in the commit message.
- **Stay in your assigned scope.** Don't touch files outside your task boundary.
- **If stuck after 3 attempts:** set PM status to `debugging`, stop.
- **All tests must pass** before committing.
- **Don't break existing tests.**
- **Commit messages:** `<type>-<row_id>: <verb> <what>` (e.g., `task-42: add user auth endpoint`, `bug-7: fix login redirect`)
- **Story branches base off main.**
- **Never create issue branches for tickets in a story.** Commit to the
  persistent story branch and process sibling tickets serially.
- **CRITICAL: Continuously update the ticket doc.** Use `pm_append_doc` / `pm_write_doc` (`row_id`, not the removed `row_number`). They write the PM template's default doc blob. Append timestamped entries after EVERY action. Empty doc after work = FAILED.
- **CRITICAL: FE changes MUST have `.browser/` snapshot.** Run a Playwright check from `e2e` (`docker compose exec -T e2e python3 -c "..."` connecting via `BROWSER_WS`) — server-side `page.screenshot(path="/output/...")` lands at `.browser/...` on host. If the snapshot looks wrong, fix before committing.
- **API uses `row_id` (integer) in URL paths**, not the removed UUID row identifier. Example: `PUT /api/v1/tables/{tid}/rows/42`.
- **NEVER POST new rows to update status.** Always use `PUT /api/v1/tables/{table_id}/rows/{row_id}` to update existing row_data. POST creates a NEW row and therefore a duplicate derived ticket key such as `task-42`. Bees must ONLY update, never create.
- **If stuck:** diagnose why, append error + analysis to the ticket doc, try a different approach. If it still cannot finish, commit recoverable partial work, log what's done and what's left, set status to `debugging`, and stop. The next bee resumes by reading the doc.

## Provider-neutral LLM adapter (`llm.sh`)

Bees don't call an LLM CLI inline — `bee.sh`'s `step()` calls
`llm_run()` from `example-scripts/llm.sh`, which selects
`$LLM_PROVIDER` (`claude` by default, or `codex` or `hermes`) and streams progress
lines back into the step's log file. `$LLM_BACKEND` remains a backwards-
compatible alias. Adding another CLI provider changes `llm.sh` and its
formatter only — `queen.sh` and `bee.sh` stay unchanged.

The abstraction is:

```text
bee.sh step() → llm.sh llm_run() → Claude, Codex, or Hermes CLI
```

The `claude` backend calls `claude -p --output-format=stream-json
--verbose` and pipes through `example-scripts/format_claude_stream.py`.
Every event the LLM emits — thinking blocks, tool calls, tool results,
the final cost — gets rendered as one short line. So when you `tmux
attach -t <session>` and switch into a bee window, you see the hive's
progress in real time instead of waiting for one giant blob at the end
of a slow call.

`claude -p` alone streams the final text only. `--verbose` alone does
nothing for tool-less prompts. The pair `--output-format=stream-json
--verbose` (with `format_claude_stream.py` to format it) is the only
combination that exposes the full inner loop. A non-Claude provider
needs its own equivalent formatter to preserve the same live view.

The `codex` provider sends the prompt on stdin to `codex exec --json
--ephemeral --dangerously-bypass-approvals-and-sandbox`, pins execution
to `$LLM_PROJECT_DIR`, and pipes JSONL through
`example-scripts/format_codex_stream.py`. Select it with:

```bash
export LLM_PROVIDER=codex
# export CODEX_MODEL=gpt-5.6-codex  # optional
```

All adapters pass prompts over stdin, preserve the actual provider exit
code through the formatting pipeline, and support `LLM_DRY_RUN=1` for
command-construction checks without starting a model run.

The `hermes` provider calls `hermes chat --query-file - --oneshot --format
stream-json --yolo --in "$LLM_PROJECT_DIR"` and formats its JSONL output with
`example-scripts/format_hermes_stream.py`. `--yolo` explicitly bypasses all
Hermes dangerous-command approval prompts, so hive bees can execute their
ticket workflow unattended. Select it with:

```bash
export LLM_PROVIDER=hermes
# Hermes/DeepSeek is the standard unattended hive configuration:
# export HERMES_MODEL=deepseek-flash
# export HERMES_PROVIDER=deepseek
# export HERMES_BASE_URL=https://api.deepseek.com/v1
# Inject DEEPSEEK_API_KEY from the runner secret store; never commit it.
```

### Watchdog: kill the provider if log goes silent

An LLM provider can hang silently after a few
minutes — usually after spawning an `Agent`/`Explore` sub-agent or a
long-running tool call. The subprocess stays alive but the event
pipe stops emitting events; without a guard the ticket burns the full
900s budget waiting.

The `example-scripts/bee.sh` `step()` function wraps `llm_run()` with a
watchdog that samples the log file every 30s and calls `llm_stop()` if it
hasn't grown for 120s. When it fires, `llm_run()` returns
non-zero → ERR trap flips the row to `debugging` → queen advances.
120s detection traded for 780s of otherwise-wasted budget.

## 3 Phases

| Phase | Doc | What |
|-------|-----|------|
| **Plan** | [plan.md](plan.md) | Discuss design → create tickets in LatticeCast PM |
| **Prepare** | [prepare.md](prepare.md) | Write project's `.tmp/agentic-hive/.env` + scripts that source the skill |
| **Run** | [running.md](running.md) | `bash run.sh`, `tmux attach`, `stop.sh`, recovery |
| **Monitor** | [monitor.md](monitor.md) | Required supervising-agent monitoring; select a provider delivery method |

## Monitoring

The hive does not self-supervise. Read [monitor.md](monitor.md) whenever a
hive run is started, unless it is a single interactive ticket or a dry-run.
The supervising agent must choose a delivery method that reports status into
the conversation and prove the first scheduled report arrives.

## Key Dependencies

- `Skill(developing/project-management)` — provides `pm_tool.sh` and its
  bundled `lc_api.sh` HTTP wrapper.
- `Skill(developing/programming)` — test/format/lint workflow.
- LatticeCast PM — ticket tracking, doc storage (MinIO).

## Composition pattern

Every project that uses the hive writes its own `.tmp/agentic-hive/.env`
and the hive's local scripts source it + the skill's `pm_tool.sh`:

```bash
# .tmp/agentic-hive/.env — per-project values only
LC_API=http://localhost:13491/api/v1
PM_USER=lattice
PM_PASS=
TABLE_ID=pm
WORKSPACE_ID=<uuid>
PROJECT_DIR=/abs/path/to/project
SKILLS_DIR=/abs/path/to/project/.agent-skills
LLM_PROVIDER=claude
LLM_PROJECT_DIR=/abs/path/to/project

# queen.sh / bee.sh
set -a
source "${SCRIPT_DIR}/.env"
set +a
source "${SKILLS_DIR}/developing/project-management/pm_tool.sh"
# pm_*, lc_* are now available
```

## Example Scripts

[example-scripts/](example-scripts/) — reference implementations:

| Script | Role |
|--------|------|
| queen.sh | Pure rule-based: query PM → spawn → poll → cleanup |
| bee.sh | Bash infra + LLM code: `source pm_tool.sh` for PM ops |
| llm.sh | Provider abstraction: validates, runs, and stops Claude, Codex, or Hermes |
| format_claude_stream.py | Formats Claude stream-json as live log lines |
| format_codex_stream.py | Formats `codex exec --json` JSONL as live log lines |
| format_hermes_stream.py | Formats Hermes stream-json events as live log lines |
| start.sh / stop.sh | tmux session lifecycle |
| monitor-cron.sh | cron-safe deterministic monitor + Codex chat resume |
