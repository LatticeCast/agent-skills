#!/usr/bin/env bash
# lc_api.sh — Internal HTTP foundation for developing/project-management.
# Thin curl wrappers: one function per route; no PM domain rules, caching, or
# hidden side effects. pm_tool.sh sources this file to add PM workflows.
#
# Source this; it only defines functions, no side effects.
#   source /path/to/developing/project-management/lc_api.sh
#
# Caller MUST set before authenticated lc_* calls:
#   LC_API           — base URL, e.g. http://localhost:13491/api/v1
#   LC_AUTH_HEADER   — full header, e.g. "Authorization: Bearer <access_token>"
# Optional:
#   LC_THROTTLE_MS   — sleep between calls (default 0)
#
# All functions write JSON/text to stdout on success and exit non-zero
# on HTTP error (curl -sf), with the response body on stderr.

# ── Internals ─────────────────────────────────────────────────────────────

_lc_throttle() {
    local ms="${LC_THROTTLE_MS:-0}"
    [ "$ms" -gt 0 ] 2>/dev/null && sleep "$(awk "BEGIN{print $ms/1000}")"
    return 0
}

_lc_check_env() {
    : "${LC_API:?LC_API must be set (e.g. http://localhost:13491/api/v1)}"
    : "${LC_AUTH_HEADER:?LC_AUTH_HEADER must be set (e.g. 'Authorization: Bearer ...')}"
}

# _lc_curl METHOD PATH [BODY_FILE] [EXTRA_HEADER ...]
# Body, if any, is a file path; never a shell-substituted string.
_lc_curl() {
    _lc_check_env
    _lc_throttle
    local method="$1" path="$2" body_file="${3:-}"
    shift 3 2>/dev/null || shift $#
    local args=(-sf -X "$method" -H "$LC_AUTH_HEADER")
    for h in "$@"; do args+=(-H "$h"); done
    if [ -n "$body_file" ]; then
        args+=(--data-binary "@${body_file}")
    fi
    local out err rc
    err=$(mktemp)
    out=$(curl "${args[@]}" "${LC_API}${path}" 2>"$err")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "lc_api: ${method} ${path} failed (curl rc=${rc})" >&2
        cat "$err" >&2
        rm -f "$err"
        return "$rc"
    fi
    rm -f "$err"
    printf '%s' "$out"
}

# Helper: serialize a JSON dict from a here-doc into a temp file path.
# Usage:  body=$(_lc_json '{"foo":"bar"}'); ... ; rm -f "$body"
_lc_json() {
    local f
    f=$(mktemp --suffix=.json)
    printf '%s' "$1" > "$f"
    printf '%s' "$f"
}

# URL-encode a single segment for path components (rough-and-ready).
_lc_uenc() {
    python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"
}

# ── Health + auth ─────────────────────────────────────────────────────────

lc_status() { _lc_curl GET "/status"; }

# lc_login_password USER PASS → echoes access_token (raw)
lc_login_password() {
    local body; body=$(_lc_json "$(printf '{"user_name":"%s","password":"%s"}' "$1" "$2")")
    local out rc
    # Login is public. Do not fabricate a bearer token from a user name:
    # obtain a real token here, then callers set LC_AUTH_HEADER.
    _lc_throttle
    out=$(curl -sf -X POST "${LC_API:?LC_API must be set (e.g. http://localhost:13491/api/v1)}/login/password" \
        -H "Content-Type: application/json" \
        --data-binary "@${body}")
    rc=$?
    rm -f "$body"
    [ "$rc" -ne 0 ] && return "$rc"
    printf '%s' "$out" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))"
}

# ── Workspaces ────────────────────────────────────────────────────────────

lc_workspace_list()   { _lc_curl GET "/workspaces"; }
lc_workspace_create() {
    local body; body=$(_lc_json "$(printf '{"workspace_name":"%s"}' "$1")")
    _lc_curl POST "/workspaces" "$body" "Content-Type: application/json"
    local rc=$?; rm -f "$body"; return $rc
}
lc_workspace_member_add() {
    # $1=workspace_id $2=user_name $3=role
    local body; body=$(_lc_json "$(printf '{"user_name":"%s","role":"%s"}' "$2" "$3")")
    _lc_curl POST "/workspaces/$1/members" "$body" "Content-Type: application/json"
    local rc=$?; rm -f "$body"; return $rc
}

# ── Tables ────────────────────────────────────────────────────────────────

lc_table_list() {
    if [ -n "${1:-}" ]; then
        _lc_curl GET "/tables?workspace_id=$1"
    else
        _lc_curl GET "/tables"
    fi
}
lc_table_get()    { _lc_curl GET    "/tables/$1"; }
lc_table_create() {
    # $1=table_id $2=workspace_id
    local body; body=$(_lc_json "$(printf '{"table_id":"%s","workspace_id":"%s"}' "$1" "$2")")
    _lc_curl POST "/tables" "$body" "Content-Type: application/json"
    local rc=$?; rm -f "$body"; return $rc
}
lc_table_create_from_template() {
    # $1=table_id $2=workspace_id $3=template kind (default pm)
    local body kind="${3:-pm}"
    body=$(_lc_json "$(printf '{\"table_id\":\"%s\",\"workspace_id\":\"%s\"}' "$1" "$2")")
    _lc_curl POST "/tables/template/${kind}" "$body" "Content-Type: application/json"
    local rc=$?; rm -f "$body"; return $rc
}
lc_table_delete() { _lc_curl DELETE "/tables/$1"; }

# ── Columns ───────────────────────────────────────────────────────────────
# v40: per-aspect GET /columns was removed. Read columns from
# GET /tables/{tid} response (`.columns` array). Every mutation returns
# the full TableSchema {columns, view_order, default_view, views}.

lc_column_create()  {
    local body; body=$(_lc_json "$2")
    _lc_curl POST "/tables/$1/columns" "$body" "Content-Type: application/json"
    local rc=$?; rm -f "$body"; return $rc
}
lc_column_update()  {
    local body; body=$(_lc_json "$3")
    _lc_curl PATCH "/tables/$1/columns/$2" "$body" "Content-Type: application/json"
    local rc=$?; rm -f "$body"; return $rc
}
lc_column_delete()  { _lc_curl DELETE "/tables/$1/columns/$2"; }

# ── Rows ──────────────────────────────────────────────────────────────────
# v40: rows are addressed by row_id (BIGINT, auto-assigned per table).
# The old `row_number` field is gone — endpoints, JSON, and URLs all
# use `row_id`.

# lc_row_list TID [LIMIT] [FILTER_JSON]
lc_row_list() {
    local tid="$1" limit="${2:-100}" filter="${3:-}"
    local q="limit=${limit}"
    if [ -n "$filter" ]; then
        local enc; enc=$(_lc_uenc "$filter")
        q="${q}&filter_json=${enc}"
    fi
    _lc_curl GET "/tables/${tid}/rows?${q}"
}

# lc_row_get TID ROW_ID
lc_row_get() { _lc_curl GET "/tables/$1/rows/$2"; }

# lc_row_create TID '{"row_data": {...}}' → echoes the new row_id
lc_row_create() {
    local body; body=$(_lc_json "$2")
    local out rc
    out=$(_lc_curl POST "/tables/$1/rows" "$body" "Content-Type: application/json")
    rc=$?; rm -f "$body"; [ "$rc" -ne 0 ] && return $rc
    printf '%s' "$out" | python3 -c "import sys,json; print(json.load(sys.stdin)['row_id'])"
}

# lc_row_update TID ROW_ID JSON_BODY (e.g. '{"row_data": {...}}')
lc_row_update() {
    local body; body=$(_lc_json "$3")
    _lc_curl PUT "/tables/$1/rows/$2" "$body" "Content-Type: application/json"
    local rc=$?; rm -f "$body"; return $rc
}
# lc_row_patch TID ROW_ID JSON_BODY — merges the given fields and leaves every
# other column alone. Prefer it over lc_row_update whenever only some fields
# change: a whole-row PUT has to carry every value back, and a blob cell's
# metadata descriptor is rejected on the way in.
lc_row_patch() {
    local body; body=$(_lc_json "$3")
    _lc_curl PATCH "/tables/$1/rows/$2" "$body" "Content-Type: application/json"
    local rc=$?; rm -f "$body"; return $rc
}

lc_row_delete() { _lc_curl DELETE "/tables/$1/rows/$2"; }

# ── Blob cells ────────────────────────────────────────────────────────────
# Blob cell bodies are addressed separately from row_data metadata. Every blob
# operation uses the selected-column route; there are no legacy /doc routes.

# lc_blob_doc_read TID ROW_ID COLUMN_ID
lc_blob_doc_read() { lc_blob_download "$1" "$2" "$3"; }

# lc_blob_doc_write TID ROW_ID COLUMN_ID [-f FILE]
# Without -f: reads Markdown from stdin.
lc_blob_doc_write() {
    local tid="$1" rid="$2" cid="$3" file=""
    if [ "${4:-}" = "-f" ] && [ -n "${5:-}" ]; then
        file="$5"
    else
        file=$(mktemp)
        cat > "$file"
    fi
    _lc_check_env
    _lc_throttle
    curl -sf -X PUT "${LC_API}/tables/${tid}/rows/${rid}/blob/${cid}" \
        -H "$LC_AUTH_HEADER" -F "file=@${file};type=text/markdown"
    local rc=$?
    [ "${4:-}" != "-f" ] && rm -f "$file"
    return $rc
}

# lc_blob_upload TID ROW_ID COLUMN_ID FILE
lc_blob_upload() {
    _lc_check_env
    _lc_throttle
    curl -sf -X PUT "${LC_API}/tables/$1/rows/$2/blob/$3" -H "$LC_AUTH_HEADER" -F "file=@$4"
}

# lc_blob_download TID ROW_ID COLUMN_ID [OUTPUT_FILE]
lc_blob_download() {
    _lc_check_env
    _lc_throttle
    if [ -n "${4:-}" ]; then
        curl -sf "${LC_API}/tables/$1/rows/$2/blob/$3" -H "$LC_AUTH_HEADER" -o "$4"
    else
        curl -sf "${LC_API}/tables/$1/rows/$2/blob/$3" -H "$LC_AUTH_HEADER"
    fi
}

lc_blob_delete() { _lc_curl DELETE "/tables/$1/rows/$2/blob/$3"; }

# ── Views ─────────────────────────────────────────────────────────────────
# v40: views are addressed by view_id (BIGINT, auto-assigned per table).
# Display name + view type live INSIDE the config JSONB
# (`{"name":"Sprint Board","type":"kanban",…}`). CRUD bodies pass the
# whole config; the BE merges into the existing row.
#
# Note: order / default_view / col_order live in table_schemas.config.
# Use `lc_schema_patch` (below) to change any of those; the legacy
# /view-order and /default-view endpoints are gone.

lc_view_list()   { _lc_curl GET  "/tables/$1/views"; }
lc_view_get()    { _lc_curl GET  "/tables/$1/views/$2"; }   # $2 = view_id (int)
lc_view_create() {
    local body; body=$(_lc_json "$2")
    _lc_curl POST "/tables/$1/views" "$body" "Content-Type: application/json"
    local rc=$?; rm -f "$body"; return $rc
}
lc_view_update() {
    local body; body=$(_lc_json "$3")
    _lc_curl PUT "/tables/$1/views/$2" "$body" "Content-Type: application/json"
    local rc=$?; rm -f "$body"; return $rc
}
lc_view_delete() { _lc_curl DELETE "/tables/$1/views/$2"; }

# lc_schema_patch TID JSON
#   Body is any subset of {view_order: [int...], default_view: int,
#   col_order: [str_column_id...]}. Returns the full TableSchema.
lc_schema_patch() {
    local body; body=$(_lc_json "$2")
    _lc_curl PATCH "/tables/$1" "$body" "Content-Type: application/json"
    local rc=$?; rm -f "$body"; return $rc
}

# ── Dashboard widget query ────────────────────────────────────────────────

# lc_block_query TID VIEW_ID BLOCK_ID [PARAMS_JSON]
lc_block_query() {
    local body; body=$(_lc_json "$(printf '{"params":%s}' "${4:-{}}")")
    _lc_curl POST \
        "/tables/$1/views/$2/blocks/$(_lc_uenc "$3")/query" \
        "$body" "Content-Type: application/json"
    local rc=$?; rm -f "$body"; return $rc
}
