#!/usr/bin/env bash
# pm_tool.sh — PM domain helpers built on lc_api.sh.
#
# Composition:   .env + lc_api.sh + pm_*  (this file)
# Source order in your script:
#   set -a; source <project>/.env; set +a     # exports LC_API, PM_USER, PM_PASS, …
#   source <skills>/developing/project-management/pm_tool.sh
#
# pm_tool.sh sources its bundled lc_api.sh automatically if the caller has not
# already sourced it.
#
# Required env (set by your .env):
#   LC_API           e.g. http://localhost:13491/api/v1
#   PM_USER          e.g. claude         (used for password-mode login)
#   WORKSPACE_ID     pm table's workspace UUID
#   TABLE_ID         the PM table's table_id (default: 'pm')
# Optional:
#   PM_PASS          ignored when AUTH_REQUIRED=false on backend
#   PROJECT_DIR      where to put caches (defaults to $PWD)

set -uo pipefail

PM_ENV_FILE="${PM_ENV_FILE:-${PROJECT_DIR:-$PWD}/.env}"
if [ -f "${PM_ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    source "${PM_ENV_FILE}"
    set +a
fi

# ── Locate bundled lc_api.sh and source it if not already ────────────────
_PM_TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F lc_status >/dev/null; then
    # shellcheck disable=SC1091
    source "${_PM_TOOL_DIR}/lc_api.sh"
fi

# ── Defaults ─────────────────────────────────────────────────────────────
PM_USER="${PM_USER:-${LC_USER:-claude}}"
PM_PASS="${PM_PASS:-${LC_PASS:-}}"
TABLE_ID="${TABLE_ID:-pm}"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"
PM_CACHE_DIR="${PROJECT_DIR}/.tmp/agentic-hive"
TOKEN_CACHE="${PM_CACHE_DIR}/_pm_token"
COL_CACHE="${PM_CACHE_DIR}/_col_cache.json"
DOC_COL_CACHE="${PM_CACHE_DIR}/_doc_col"

mkdir -p "${PM_CACHE_DIR}"

# ── Auth / token cache ───────────────────────────────────────────────────

# pm_login → ensures LC_AUTH_HEADER is set through password login.
# A PM user name is never a bearer token. An empty PM_PASS is still sent to
# /login/password for accounts without a configured password.
pm_login() {
    if [ -n "${LC_AUTH_HEADER:-}" ]; then return 0; fi
    local token=""
    if [ -f "${TOKEN_CACHE}" ]; then
        token=$(cat "${TOKEN_CACHE}")
    fi
    if [ -z "${token}" ]; then
        token=$(lc_login_password "${PM_USER}" "${PM_PASS}") || {
            echo "pm: password login failed for ${PM_USER}" >&2
            return 1
        }
        [ -n "${token}" ] || {
            echo "pm: password login returned no access token for ${PM_USER}" >&2
            return 1
        }
        printf '%s' "${token}" > "${TOKEN_CACHE}"
    fi
    export LC_AUTH_HEADER="Authorization: Bearer ${token}"
}

# ── Column cache ─────────────────────────────────────────────────────────

# pm_cache_cols → fetches table columns and writes name→column_id map to
# COL_CACHE as JSON. Idempotent; safe to call multiple times.
# v40: per-aspect GET /columns is gone — read from GET /tables/{tid}.
pm_cache_cols() {
    pm_login
    lc_table_get "${TABLE_ID}" \
        | python3 -c '
import sys, json
t = json.load(sys.stdin)
out = {c["name"]: c["column_id"] for c in t["columns"]}
print(json.dumps(out))' \
        > "${COL_CACHE}"
}

# pm_col NAME → echoes column_id for the named column.
pm_col() {
    [ ! -s "${COL_CACHE}" ] && pm_cache_cols
    python3 -c "import json; print(json.load(open('${COL_CACHE}')).get('$1',''))"
}

# pm_doc_col → echoes the PM template's doc blob column_id. The current API
# requires all blob access to name its column explicitly; `/doc` routes no
# longer exist.
pm_doc_col() {
    if [ ! -s "${DOC_COL_CACHE}" ]; then
        pm_login
        lc_table_get "${TABLE_ID}" \
            | python3 -c '
import json, sys
table = json.load(sys.stdin)
column = next((c for c in table["columns"]
               if c.get("type") == "blob" and c.get("options", {}).get("kind") == "doc"), None)
if not column:
    raise SystemExit("pm: table has no doc blob column")
print(column["column_id"])' \
            > "${DOC_COL_CACHE}"
    fi
    cat "${DOC_COL_CACHE}"
}

# pm_row_type ROW_ID → ticket Type value (epic, story, task, or bug).
pm_row_type() {
    local rid="$1" type_col
    pm_login
    type_col=$(pm_col Type)
    lc_row_get "${TABLE_ID}" "${rid}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['row_data'].get('${type_col}',''))"
}

# pm_require_story_parent ISSUE_ROW_ID → echoes the verified parent story row_id.
# Fails closed unless ISSUE_ROW_ID is a task/bug whose Parent points to a
# currently readable row with Type=story. This is the one dependency boundary
# used by both ticket creation and bee dispatch.
pm_require_story_parent() {
    local issue_id="$1" type_col parent_col issue_json issue_type parent_id story_type
    pm_login
    type_col=$(pm_col Type)
    parent_col=$(pm_col Parent)
    [ -n "${type_col}" ] && [ -n "${parent_col}" ] || {
        echo "pm: PM table requires Type and Parent columns" >&2
        return 1
    }
    issue_json=$(lc_row_get "${TABLE_ID}" "${issue_id}") || return 1
    issue_type=$(printf '%s' "${issue_json}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['row_data'].get('${type_col}',''))")
    case "${issue_type}" in
        task|bug) ;;
        *)
            echo "pm: row ${issue_id} is not an executable task/bug" >&2
            return 1
            ;;
    esac
    parent_id=$(printf '%s' "${issue_json}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['row_data'].get('${parent_col}',''))")
    [[ "${parent_id}" =~ ^[0-9]+$ ]] || {
        echo "pm: ${issue_type}-${issue_id} has no numeric Parent story row_id" >&2
        return 1
    }
    story_type=$(pm_row_type "${parent_id}") || return 1
    [ "${story_type}" = "story" ] || {
        echo "pm: ${issue_type}-${issue_id} parent ${parent_id} is ${story_type:-missing}, not story" >&2
        return 1
    }
    printf '%s\n' "${parent_id}"
}

# pm_read_ticket_doc ROW_ID → reads the PM template's default doc blob for any row.
pm_read_ticket_doc() {
    pm_login
    lc_blob_doc_read "${TABLE_ID}" "$1" "$(pm_doc_col)"
}

# pm_require_hive_context ISSUE_ROW_ID → verifies issue + parent story docs,
# then echoes the parent story row_id. The required headings match the hive
# planning gate; missing evidence is a planning error, never an LLM prompt.
pm_require_hive_context() {
    local issue_id="$1" story_id issue_doc story_doc heading
    story_id=$(pm_require_story_parent "${issue_id}") || return 1
    issue_doc=$(pm_read_ticket_doc "${issue_id}") || return 1
    story_doc=$(pm_read_ticket_doc "${story_id}") || return 1
    for heading in \
        '## Current Behavior and Evidence' \
        '## Root Cause' \
        '## Target Invariants' \
        '## End-to-End Data Flow' \
        '## Legacy Paths to Remove or Replace' \
        '## Exact Scope' \
        '## Acceptance Matrix'; do
        [[ "${issue_doc}" == *"${heading}"* ]] || {
            echo "pm: issue ${issue_id} missing ${heading}" >&2
            return 1
        }
    done
    for heading in \
        '## Base Story' \
        '## Context Read' \
        '## Current Behavior and Evidence' \
        '## Root Cause' \
        '## Target Invariants and Data Flow' \
        '## Legacy Paths to Remove or Replace' \
        '## Issue Dependency and Integration Plan'; do
        [[ "${story_doc}" == *"${heading}"* ]] || {
            echo "pm: story ${story_id} missing ${heading}" >&2
            return 1
        }
    done
    printf '%s\n' "${story_id}"
}

# pm_validate_issue_parents ISSUE_ROW_ID [...] — plan-phase hierarchy audit.
# The planner calls this after creating every issue in a plan and before it
# announces the plan ready. It deliberately reuses the same parent rule that
# dispatch uses, so ticket creation and bee execution cannot drift.
pm_validate_issue_parents() {
    local issue_id story_id
    [ "$#" -gt 0 ] || {
        echo "pm: no issue row_ids supplied for parent audit" >&2
        return 1
    }
    for issue_id in "$@"; do
        story_id=$(pm_require_story_parent "${issue_id}") || return 1
        printf 'pm: verified issue %s → story %s\n' "${issue_id}" "${story_id}" >&2
    done
}

# ── Row helpers ──────────────────────────────────────────────────────────

# pm_set_status ROW_ID STATUS — patches the Status field on the given row.
#
# Sends only Status. It used to read the whole row_data back, edit one key and
# PUT all of it, which stopped working once a ticket document became a blob
# cell: row_data then carries a descriptor for it, and the server rejects that
# descriptor on the way in. endpoints.md is explicit — "PATCH merges non-blob
# data ... Neither can mutate a blob cell."
pm_set_status() {
    local rid="$1" status="$2"
    pm_login
    local sid; sid=$(pm_col Status)
    if [ -z "${sid}" ]; then
        echo "pm_set_status: no Status column in ${TABLE_ID}" >&2
        return 1
    fi
    lc_row_patch "${TABLE_ID}" "${rid}" \
        "{\"row_data\": {\"${sid}\": \"${status}\"}}" >/dev/null
}

# pm_create_ticket TITLE TYPE PRIORITY [PARENT_RN]
# Echoes the new row_id on success. task/bug creation fails unless Parent is a
# readable row whose Type is story.
pm_create_ticket() {
    pm_login
    local title="$1" type="${2:-task}" priority="${3:-medium}" parent="${4:-}"
    local TID; TID=$(pm_col Title)
    local TY;  TY=$(pm_col Type)
    local SID; SID=$(pm_col Status)
    local PR;  PR=$(pm_col Priority)
    local PRN; PRN=$(pm_col Parent)
    local SD;  SD=$(pm_col "Start Date")
    local DD;  DD=$(pm_col "Due Date")
    local today; today=$(date -u +%Y-%m-%d)

    case "${type}" in
        task|bug)
            [ -n "${parent}" ] || {
                echo "pm: ${type} tickets require Parent=<story_row_id>" >&2
                return 1
            }
            local parent_type
            parent_type=$(pm_row_type "${parent}") || return 1
            [ "${parent_type}" = "story" ] || {
                echo "pm: ${type} parent ${parent} is ${parent_type:-missing}, not story" >&2
                return 1
            }
            ;;
    esac

    local row_data
    row_data=$(python3 -c "
import json
rd = {
    '${TID}': '''${title}''',
    '${TY}':  '${type}',
    '${SID}': 'todo',
    '${PR}':  '${priority}',
    '${SD}':  '${today}',
    '${DD}':  '${today}',
}
parent = '${parent}'
if parent:
    rd['${PRN}'] = parent
print(json.dumps({'row_data': rd}))")
    lc_row_create "${TABLE_ID}" "${row_data}"
}

# pm_get_todo_tasks → echoes "row_id|title" lines.
pm_get_todo_tasks() {
    pm_login
    local SID; SID=$(pm_col Status)
    local TY;  TY=$(pm_col Type)
    local TI;  TI=$(pm_col Title)
    local filter; filter=$(printf '{"%s":"todo"}' "${SID}")
    lc_row_list "${TABLE_ID}" 200 "${filter}" \
        | python3 -c "
import sys, json
rows = json.load(sys.stdin)
todo = [r for r in rows if r['row_data'].get('${TY}') in ('task','bug')]
todo.sort(key=lambda r: r['row_id'])
for r in todo:
    print(f\"{r['row_id']}|{r['row_data'].get('${TI}','?')}\")"
}

# ── Doc helpers ──────────────────────────────────────────────────────────

pm_read_doc()   { pm_login; lc_blob_doc_read "${TABLE_ID}" "$1" "$(pm_doc_col)"; }
pm_write_doc()  {
    # pm_write_doc RN CONTENT
    pm_login
    printf '%s' "$2" | lc_blob_doc_write "${TABLE_ID}" "$1" "$(pm_doc_col)"
}
pm_append_doc() {
    # pm_append_doc RN MESSAGE — appends a timestamped line.
    pm_login
    local rn="$1" msg="$2"
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local cur; cur=$(lc_blob_doc_read "${TABLE_ID}" "${rn}" "$(pm_doc_col)" 2>/dev/null || echo "")
    printf '%s\n- %s %s' "${cur}" "${ts}" "${msg}" \
        | lc_blob_doc_write "${TABLE_ID}" "${rn}" "$(pm_doc_col)"
}
