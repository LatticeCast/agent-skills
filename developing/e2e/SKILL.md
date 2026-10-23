---
name: developing/e2e
description: End-to-end tests — pytest + Playwright drives a real browser, every step verifies DB state, optional per-step snapshot.
user-invocable: false
version: 0.16.1
---

# E2E Testing — pytest + Playwright + BE/DB Verification

## Three pillars

| Pillar | Catches |
|---|---|
| **Playwright UI** | DOM / routing / hydration bugs |
| **BE API read (or direct DB)** | BE silently dropped writes |
| **Step snapshots** (opt-in) | visual regressions |

## Two-container architecture

```
┌─────────────────────────────┐     ws://browser:4444     ┌─────────────────────┐
│ e2e                    │ ────────────────────────▶ │ browser             │
│ pytest + playwright + httpx │   (Playwright client/srv) │ playwright run-srv  │
│ runs pytest test suite      │                           │ Chromium            │
└─────────────────────────────┘                           └─────────────────────┘
```

- **e2e** — uv image, no Chromium. Connects via `BROWSER_WS`.
- **browser** — owns Chromium. Mounts `./.browser:/output` for screenshots.
- Tests bind-mounted at `/scripts`.

## Test organisation

Tests live in **domain folders**, each with `__init__.py`:

```
e2e/
├── conftest.py           # shared fixtures
├── e2e_base.py           # utility module (login, api, connect_browser, seed_login_info)
├── auth/                 # login, admin, user config
├── workspace/            # CRUD, members, roles
├── tables/               # columns, rows, filters, inline edit
├── table_views/          # kanban, timeline, view CRUD
└── template/             # PM, CRM, SEO framework templates
```

Each folder has `__init__.py` + `test_<topic>.py` files.

**One topic per file.** A "topic" is one user-visible behavior that
fails or passes as a unit. < 300 lines. Split when it grows.

Cross-domain tests MUST exercise the topic on at least two view types.
Per-view tests MUST also assert state persists after navigation away
and back.

## conftest.py fixtures

Shared fixtures auto-discovered by pytest:

- `snapshot` (function) — `True` when `--snapshot` flag passed, controls screenshot capture
- `browser` (session) — connect via `BROWSER_WS`, yield, close
- `page` (function) — new page per test (1400×900), auto-close
- `admin_token` (session) — `login("lattice")`, return JWT
- `authed_page` (function) — page with auth cookie + seed_login_info for admin
- `workspace` (function) — create temp workspace, yield `(ws_id, ws_name)`, delete after
- `pm_table` (function) — create a PM template table in a workspace, yield `(table_id, ws_id, columns, views)`; `table_id` is the numeric identity as text, ready for URL building

Tests declare what they need by parameter name — no manual setup/teardown.

Utility helpers available via `from e2e_base import BASE, api`:

- `BASE` — backend URL (`BASE_URL` env, default `http://localhost:13491`)
- `api(method, path, token, **kw)` — authenticated request wrapper

## Running

```bash
docker compose --profile test up -d browser e2e

# full suite
docker compose exec -T e2e pytest --tb=short -q

# one folder
docker compose exec -T e2e pytest <domain>/ -v

# one file
docker compose exec -T e2e pytest <domain>/test_<topic>.py -v

# with screenshots (saved to .browser/)
docker compose exec -T e2e pytest <domain>/test_<topic>.py -v --snapshot
```

## Sub-files (lazy)

- [setup.md](setup.md) — bootstrap test users (PG + BE).
- [flow_template.md](flow_template.md) — canonical test sequence.

## Rules

1. Every UI mutation → DB check. UI "saved" ≠ DB has it.
2. Every DB mutation → UI check. DB row ≠ UI rendered it.
3. No `sleep()`. Use Playwright `wait_for_*`.
4. No conditional skipping. Failures must be loud.
5. Idempotent setup via conftest fixtures.
6. `--snapshot` opt-in. Default off (CI stays fast).

## CRITICAL: FIX SOURCE, never workaround in test

The test encodes **intended behavior**. If it fails, **the source is
wrong, not the test.** Fix the FE/BE, do NOT twist the test.

### Banned patterns

| Pattern | Hides | Do instead |
|---|---|---|
| `wait_for_timeout(N)` / `sleep(N)` | unobservable state | `expect_response()` or `data-status` attr |
| `try: except: pass` around assert | flaky FE | fix the FE |
| conditional assert (`if visible`) | maybe-bug | require it or delete it |
| text/CSS selector replacing missing testid | missing testid | add `data-testid` to FE component |
| `pytest.skip` / `# flaky` | unfixed bug | open bug ticket, fix it |

### Missing testid = FE bug

If there's no `data-testid` or observable state on the element —
**add it to the FE component.** That's test-affordance scope, not
new behavior.

### Scope of test tickets

Allowed: add missing `data-testid`, fix wrong response shapes, expose
existing state as `data-*` attributes.

**Never:** add new BE routes, new FE buttons/modals, new store actions,
or new fields that don't already exist. If the feature isn't built,
stop and flag it — don't invent behavior in a test ticket.
