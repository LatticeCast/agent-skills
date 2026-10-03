---
name: agent/seo-bot
description: Cross-product SEO article generator. Reads 3 CSVs (TA × promotion × product), loops the full Cartesian product, and spawns one fresh `claude -p` worker per article. Saves to LatticeCast articles table via lc_api.sh.
argument-hint: run | status
version: 0.3.2
---

# seo-bot — Cross-Product Article Generator

Spawns N×M×K fresh `claude -p` workers, one per (TA × promo × product)
combo. Each worker writes one article in isolation; the orchestrator
just loops + uploads via `lc_api.sh`.

## Architecture (same shape as `agentic-hive`)

```
Project root (e.g. seo-system/)
├── .env                   # LC_API, LC_USER, LC_PASS, ARTICLES_TABLE_ID, …
├── .env.example           # config template
├── .agent-skills/         # contains developing/project-management/lc_api.sh
└── seo-bot/
    ├── run.sh             # entry point (sources .env, calls orch)
    ├── orchestrator.sh    # pure shell — reads CSVs, loops product
    ├── worker.sh          # bash infra + `claude -p` for ONE article
    ├── audiences.csv      # TA personas
    ├── promotions.csv     # promotions / campaigns
    └── products.csv       # featured products
```

## Config contract

`.env` must define:

| Var | Purpose |
|---|---|
| `LC_API` | Base URL, e.g. `http://localhost:13491/api/v1` |
| `LC_USER` | Login user_name for `/login/password` |
| `LC_PASS` | Login password for `/login/password` |
| `ARTICLES_TABLE_ID` | Table ID for the articles table |
| `TITLE_COLUMN_ID` | Column ID for the title field in articles |
| `ARTICLE_BLOB_COLUMN_ID` | Column ID for the article's `blob` cell |
| `SKILLS_DIR` | Absolute path to the project's `.agent-skills` submodule |

## How it works

1. `bash seo-bot/run.sh` → sources `.env`, runs orchestrator
2. **Orchestrator (rule-based, no LLM):**
   - Parse `audiences.csv`, `promotions.csv`, `products.csv` (header row + `title,description`)
   - Build cross product (3 × 4 × 2 = 24 typically; generic for any size)
   - Query existing rows via `lc_row_list` on `ARTICLES_TABLE_ID`
   - Skip combos already covered (idempotent — safe to rerun)
   - For each missing combo, exec `worker.sh` with the 3 (title, desc) pairs
   - Sleep 1s between workers (rate-limit per CLAUDE.md)
3. **Worker (bash + LLM):**
   - Compose a prompt embedding the three contexts
   - `timeout 120 claude -p --dangerously-skip-permissions "<prompt>"`
   - Worker writes ONE markdown file to `~/.tmp/article-<title>.md`
   - Bash creates row via `lc_row_create` then uploads via `lc_blob_upload`
   - **No LLM in the upload path** — bash handles it deterministically
4. Orchestrator logs in, derives `LC_AUTH_HEADER` at runtime, and emits
   `ALL_DONE` when count reached; otherwise exits non-zero

Each worker is a fresh process — **no shared context** between articles.

## CSV format

UTF-8, comma-delimited, first row is header. Two columns: `title,description`.

```csv
title,description
akai,26-year-old male office worker. WFH 3d/wk. Loves bouldering.
meiwen,22-year-old female grad student. Industrial design. Tight budget.
```

Title becomes the article-name component (used for the unique
`articles.Title` like `akai-spring-2026-ergopro-chair`). Description
is fed to the LLM as persona/context.

## Article-title contract

Worker uploads with `Title = "${a_title}-${b_title}-${c_title}"`.

This title is the dedupe key and the verifier's signal — it must be
unique across all combos. Don't change the format unless you also
update orchestrator's `contains` skip-check.

## Worker rules

- **One combo only.** Don't mention any other persona/promo/product.
- **≥400 chars** of substantive prose. The driver enforces this.
- **First line is `# <title>`.**
- **No filler / no echoing the prompt.**
- **Don't curl from inside the worker** — bash handles upload via
  `lc_row_create` + `lc_blob_upload`. Same rule as `agentic-hive`.

## Rate limit

`sleep 1` between workers in the orchestrator. From `seo-system/CLAUDE.md`:
> API rate limit: wait 1 second between each API call

## Idempotency

Re-running `run.sh` after partial completion picks up where it left
off — already-uploaded titles are skipped via `lc_row_list`.

## Composition

Sources `lc_api.sh` from `developing/project-management` (the bundled thin
LatticeCast HTTP wrapper). Project `.env` provides `SKILLS_DIR`, `LC_API`,
`LC_USER`, `LC_PASS`, and table/column IDs. The bot logs in and derives
`LC_AUTH_HEADER` at runtime. The bot itself contains no
LatticeCast-specific code beyond the `lc_*` function calls.

## When to use this skill

- You have 3 source dimensions and want every cross-product article
  written without context leak between articles.
- You want deterministic, idempotent, rerunnable batch generation.
- You want cheap parallelism: each `claude -p` is independent.

For single-article writing: just use `claude` directly in the
seo-system project — pilot Claude reads `CLAUDE.md`, runs
`get_context.sh`, and writes ad-hoc.

## Reference scripts

[example-scripts/run.sh](example-scripts/run.sh)
[example-scripts/orchestrator.sh](example-scripts/orchestrator.sh)
[example-scripts/worker.sh](example-scripts/worker.sh)
[example-scripts/audiences.csv](example-scripts/audiences.csv) [promotions.csv](example-scripts/promotions.csv) [products.csv](example-scripts/products.csv)

Copy these into `<project>/seo-bot/`, replace CSVs with your real
sources, ensure `<project>/.env` defines `LC_API`,
`LC_USER`, `LC_PASS`, `ARTICLES_TABLE_ID`, `TITLE_COLUMN_ID`, and
`SKILLS_DIR`. Then `bash seo-bot/run.sh`.
