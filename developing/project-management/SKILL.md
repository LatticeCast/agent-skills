---
name: developing/project-management
description: LatticeCast PM integration — ticket status updates, project setup, pre-flight checks. Internal library used by developing/programming, agent/agentic-hive, and developing/onboarding.
user-invocable: false
allowed-tools: Bash, Read
version: 0.12.2
---

# LatticeCast Project Management

> `pm_tool.sh` is the PM domain layer over the bundled `lc_api.sh` HTTP
> wrapper. The PM-specific helpers
> (`pm_login`, `pm_cache_cols`, `pm_set_status`, `pm_create_ticket`,
> `pm_get_todo_tasks`, `pm_*_doc`) compose both layers for consumers:
>
> ```bash
> set -a; source <project>/.env; set +a   # exports LC_API, PM_USER, TABLE_ID, …
> source <skills>/developing/project-management/pm_tool.sh   # auto-sources bundled lc_api.sh
> pm_login; pm_get_todo_tasks
> ```


Internal skill providing PM operations. Other skills compose via `Skill(developing/project-management)`.

For a non-PM consumer that only needs LatticeCast HTTP routes, source this
skill's bundled `lc_api.sh`. Do not depend on a separate lattice-cast skill.

The project `.env` is the source of connection settings. `LC_API` is the API
base (for example `http://localhost:13491/api/v1` or a deployed `/api/v1` URL);
never hard-code a host, token, or user in a reusable workflow.

> **First-time setup?** See [setup.md](setup.md)
> **Full API reference?** See [endpoints.md](endpoints.md)

## Daily Session

Source the project `.env`, then use `pm_tool.sh`; it logs in through
`/login/password`, caches the token outside Git, resolves column UUIDs, and
keeps row updates out of LLM prompts.

```bash
set -a; source .env; set +a
source .agent-skills/developing/project-management/pm_tool.sh
pm_login
pm_cache_cols
pm_get_todo_tasks
```

The PM user must already exist. Never fabricate `Authorization: Bearer
<user_name>`; `pm_login` obtains a real access token.

## Every `pm_*` entry point calls `pm_login` itself

`pm_login` is what sets `LC_AUTH_HEADER`; the `lc_*` layer only reads it. Each
`pm_*` function calls `pm_login` on entry rather than assuming a caller did.

This matters when writing or overriding a helper: reference `LC_AUTH_HEADER`
without calling `pm_login` first and, under `set -u`, the shell dies on an
unbound variable. In a hive that surfaces as a bee which logs its first line
and vanishes, with no error attributable to PM.

## ID Resolution

The login result is a JWT whose subject is the user UUID. Other identifier
fields (URL paths, member lookup) resolve in this order:
1. **UUID** — `a712f960-8f9f-4b9d-8d12-3be3cd2d75d1`
2. **user_name** — `lattice`, `homun-lang-002` (case-insensitive, regex `^[a-z0-9][a-z0-9_-]{2,31}$`)
3. **email** — `user@example.com` (case-insensitive)

## Current Data Contract

Rows use **`row_id`** (BIGINT, auto-increment per table). This was
renamed from `row_number` in v0.40 — the field, JSON key, and URL
segment are all `row_id` now.

```
table identity: (workspace_id, table_id)
row identity:   row_id (BIGINT, per table)
row values:     row_data[column_uuid]
```

PM templates do not contain a `Key` column. Derive the stable display key
from the row type and integer ID: `<type>-<row_id>` (for example
`story-5` or `bug-42`).

PM helpers resolve named template fields to column UUIDs. Use their `pm_*`
operations rather than hand-written curl or hard-coded column IDs.

Each ticket's detailed markdown is its default **doc blob cell**. `pm_read_doc`,
`pm_write_doc`, and `pm_append_doc` resolve that column from the PM schema and
use `/rows/{row_id}/blob/{column_id}`. New non-PM code must likewise address
its selected blob column directly; there are no `/doc` compatibility routes.

## Ensure Running

```bash
lc_status
```

If not running → tell user to `docker compose up -d`. **Do NOT fallback to file-based tracking.**

## Setup Project (used by developing/onboarding)

See [setup.md](setup.md). Summary:

1. Login as admin → get `$ADMIN_TOKEN`
2. `POST /api/v1/admin/users` — create bot user `claude` (admin must do this; auto-create is disabled)
3. Login as `claude` → get `$TOKEN`
4. `POST /api/v1/workspaces` (creates workspace with UUID `workspace_id`)
5. Ask user for team member identifiers
6. `POST /api/v1/workspaces/{ws_uuid}/members` with `{"user_name": "<id>", "role": "member"}`
7. `POST /api/v1/tables/template/pm`
8. Report board URL

## Workspace Membership

Only workspace owners can rename a workspace or manage members. The PM
workspace UUID belongs in `.env` as `WORKSPACE_ID`; use `lc_workspace_*`
helpers rather than treating a workspace name as its identity.

## Query and Mutate Tickets

`pm_get_todo_tasks` returns executable `task`/`bug` rows only.
`pm_require_story_parent` and `pm_require_hive_context` are fail-closed
planning/dispatch gates; do not bypass them with direct row creation.

## Update Ticket Status

**Use `pm_set_status` for an existing ticket. Never use POST to change one:**
POST creates another row. `pm_set_status` reads the current row and uses PUT;
the PG row mutation function preserves blob metadata.

Statuses: `todo` → `in_progress` → `testing` → `review` → `merged` (also `debugging` loop)

```bash
pm_set_status <row_id> in_progress
```

## Default Time Rule

When creating a ticket, if `Start Date` or `Due Date` not specified, **default both to today (UTC)**. Never leave empty.

## Ticket Docs

Use `pm_read_doc`, `pm_write_doc`, and `pm_append_doc`; they handle the
default doc blob and timestamped work log. All implementation evidence,
decisions, test results, and recovery state go in the ticket doc continuously.

## Status Flow

```
todo → in_progress → testing → review → merged
                       ↓
                    debugging → testing (loop)

Auto-cascade: all children merged → parent auto-merged
```
