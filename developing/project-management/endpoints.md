# PM HTTP Contract

Use `pm_tool.sh` for PM work. This file is the small route reference for a
consumer that must use `lc_api.sh` directly. Load the project's `.env`; its
`LC_API` includes `/api/v1`, and `pm_login` creates `LC_AUTH_HEADER`.

```bash
set -a; source .env; set +a
source .agent-skills/developing/project-management/pm_tool.sh
pm_login
```

## Identities and mutations

- Workspace identity is UUID `workspace_id`; table identity is
  `table_id` (BIGINT identity) with `table_name` as its unique-per-workspace
  display name; `row_id` is a per-table BIGINT.
- Schema is returned by `GET /tables/{table_id}`. Row values are
  `row_data[column_uuid]`; do not use column names as keys.
- `PATCH /tables/{table_id}/rows/{row_id}` merges non-blob data. `PUT` replaces
  non-blob data while preserving blob metadata. Neither can mutate a blob cell.
- A blob cell has one metadata object in row data and bytes in object storage.
  Use the selected blob routes, never an ordinary row update.

| Need | Route / helper |
|---|---|
| Login | `POST /login/password` / `pm_login` |
| Read schema | `GET /tables/{table_id}` / `lc_table_get` |
| Create/read/update row | `/tables/{table_id}/rows` / `lc_row_*` |
| Read/write selected text blob | `/rows/{row_id}/blob/{column_id}` / `lc_blob_doc_*` |
| Upload/download/delete selected binary blob | `/rows/{row_id}/blob/{column_id}` / `lc_blob_*` |
| PM ticket document | `pm_read_doc`, `pm_write_doc`, `pm_append_doc` |

There are no `/rows/{row_id}/doc` or `/blob/{column_id}/doc` compatibility
routes. `pm_*_doc`, queen, and story gate use `pm_doc_column.py` to resolve the
current `Doc` column with `type=blob, options.kind=text`, or the sole text blob
when renamed. Missing/ambiguous candidates fail; legacy `kind=doc` and stale
`_doc_col` caches are not used. All reads/writes use the addressed blob route.

`lc_blob_upload TID ROW_ID COLUMN_ID FILE [CONTENT_TYPE]` optionally sets the
multipart file MIME type. `lc_blob_doc_write` delegates with `text/markdown`.

## PM conventions

- Template fields are resolved by `pm_cache_cols`; no hard-coded UUIDs.
- `pm_set_status <row_id> <status>` is the only normal status writer. Never
  POST a status change: POST creates a second ticket row.
- Ticket display key is `<type>-<row_id>`; PM has no stored Key column.
- Executable `task`/`bug` rows must have `Parent=<story row_id>`. Validate with
  `pm_require_story_parent` and `pm_require_hive_context` before dispatch.
- Current statuses: `todo → in_progress → testing → review → merged`, with
  `debugging → testing` as the recovery loop.

## Template setup route

`lc_table_create_from_template <table_name> <workspace_id> [kind]` calls
`POST /tables/template/{kind}`; `kind` defaults to `pm`. The call returns the
assigned numeric `table_id`, which every later table-scoped path must use.

The caller must have write access to the target workspace. Template creation
returns the full schema snapshot; apply it as authoritative state.
