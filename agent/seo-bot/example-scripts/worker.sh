#!/usr/bin/env bash
# seo-bot/worker.sh — Fresh claude -p call for ONE article.
# Inputs come from the orchestrator's CSV-driven cross product.
# Usage: worker.sh <a_title> <a_desc> <b_title> <b_desc> <c_title> <c_desc>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${SEO_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi
: "${SKILLS_DIR:?SKILLS_DIR must be set in .env}"
# shellcheck disable=SC1091
source "${SKILLS_DIR}/developing/project-management/lc_api.sh"

A_TITLE="${1:?a_title required}";  A_DESC="${2:?a_desc required}"
B_TITLE="${3:?b_title required}";  B_DESC="${4:?b_desc required}"
C_TITLE="${5:?c_title required}";  C_DESC="${6:?c_desc required}"
LC_USER="${LC_USER:-}"
LC_PASS="${LC_PASS:-}"

: "${ARTICLES_TABLE_ID:?ARTICLES_TABLE_ID must be set in .env}"
: "${TITLE_COLUMN_ID:?TITLE_COLUMN_ID must be set in .env}"
: "${ARTICLE_BLOB_COLUMN_ID:?ARTICLE_BLOB_COLUMN_ID must be set in .env}"

if [ -z "${LC_AUTH_HEADER:-}" ] && [ -n "${LC_USER}" ]; then
    LC_TOKEN=""
    if [ -n "${LC_PASS}" ]; then
        LC_TOKEN=$(curl -s -X POST "${LC_API}/login/password" \
            -H "Content-Type: application/json" \
            -d "{\"user_name\":\"${LC_USER}\",\"password\":\"${LC_PASS}\"}" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
    fi
    [ -n "${LC_TOKEN}" ] || LC_TOKEN="${LC_USER}"
    export LC_AUTH_HEADER="Authorization: Bearer ${LC_TOKEN}"
fi

ARTICLE_TITLE="${A_TITLE}-${B_TITLE}-${C_TITLE}"
ARTICLE_FILE="${SEO_DIR}/.tmp/article-${ARTICLE_TITLE}.md"
PROMPT_FILE="${SEO_DIR}/.tmp/prompt-${ARTICLE_TITLE}.md"

log() { echo "$(date '+%H:%M:%S') [W ${ARTICLE_TITLE}] $*"; }

cat > "$PROMPT_FILE" <<EOF
You are an SEO copywriter. Write ONE article for this exact combination.

## Target Audience persona — ${A_TITLE}
${A_DESC}

## Promotion / 檔期 — ${B_TITLE}
${B_DESC}

## Featured Product — ${C_TITLE}
${C_DESC}

## Constraints
- Output ONE markdown file. First line is "# <title>" (the title).
- Length: at least 400 characters of substantive prose.
- Mention the persona name "${A_TITLE}" by name at least once.
- Mention the promotion name "${B_TITLE}" or its Chinese variant at least once.
- Mention the product name "${C_TITLE}" by name at least once.
- Persona-relevant pain point → product as solution → promo CTA.
- No filler. Don't include this prompt in the output.
- Do NOT mention any other persona name, promotion, or product. The
  driver's verifier checks this — single-combination only.

## Output
Write the article to this exact path: ${ARTICLE_FILE}

Then exit. Do NOT upload — the orchestrator handles upload.
EOF

log "spawning fresh claude -p (timeout 120s)"
timeout 120 claude -p --dangerously-skip-permissions "$(cat "$PROMPT_FILE")" \
    >/dev/null 2>&1 || true

if [ ! -s "$ARTICLE_FILE" ]; then
    log "FAIL: claude did not produce $ARTICLE_FILE"
    exit 1
fi

LEN=$(wc -c < "$ARTICLE_FILE")
log "article written, ${LEN} bytes"

ROW_ID=$(lc_row_create "$ARTICLES_TABLE_ID" \
    "$(printf '{"row_data":{"%s":"%s"}}' "$TITLE_COLUMN_ID" "$ARTICLE_TITLE")")
if [ -z "$ROW_ID" ]; then
    log "FAIL: lc_row_create returned empty row_id"
    exit 1
fi
log "row created, row_id=$ROW_ID"

if ! lc_blob_upload "$ARTICLES_TABLE_ID" "$ROW_ID" "$ARTICLE_BLOB_COLUMN_ID" "$ARTICLE_FILE"; then
    log "FAIL: lc_blob_upload"
    exit 1
fi
log "uploaded OK"
