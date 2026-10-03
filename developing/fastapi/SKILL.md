---
name: developing/fastapi
description: FastAPI backend development — async-by-default, multi-worker safe. Use when writing FastAPI routes, DB access, or any I/O call in the backend.
version: 0.3.1
---

# FastAPI: Async + Multi-Worker

Two rules govern every line of backend code:
1. **Async** — every I/O call must be awaitable
2. **Stateless** — every worker is independent, shared state lives in Valkey

## Rule 1: Async by Default

One blocking call freezes the event loop → all concurrent users stall.

### Use async-native libraries (preferred)
- DB: `AsyncSession` + `asyncpg` (already done)
- S3-compatible blob storage (RustFS): `aioboto3` — `async with s3_client() as s3: await s3.put_object(...)`
- HTTP: `httpx.AsyncClient` — never `requests`
- Sleep: `await asyncio.sleep(n)` — never `time.sleep(n)`

### Fallback: `asyncio.to_thread` (when no async lib exists)
```python
await asyncio.to_thread(sync_function, arg1, arg2)
```

### Anti-patterns
```python
# BAD — blocks event loop
client.put_object(Bucket=..., Body=data)
requests.get(url)
time.sleep(5)

# GOOD — async native
async with s3_client() as s3:
    await s3.put_object(Bucket=..., Body=data)
async with httpx.AsyncClient() as c:
    r = await c.get(url)
await asyncio.sleep(5)
```

**Root cause incident:** sync `boto3.put_object()` blocked the event loop during a large upload. Every other user saw "backend died" for 30+ seconds. Fixed in v0.19 by switching to aioboto3. See CHANGELOG v0.18-v0.19.

## Rule 2: Multi-Worker Stateless

We run `--workers 4`. Each worker is a **separate OS process** with its own memory. They share NOTHING except external services (PG, Valkey, RustFS blob storage).

### What's safe (per-worker, independent)
- Connection pools (`app_engine`, `login_engine`, `redis_client`) — each worker creates its own. PG/Valkey handle concurrent connections fine.
- `aioboto3.Session()` — stateless factory, creates client per call.
- `@lru_cache` on immutable config (`get_settings()`) — cached per worker, never changes.
- Read-only constants (`BTREE_TYPES`, `GIN_TYPES`).
- Log file append (`ServerTee`) — Linux atomic for writes < 4096 bytes.

### What breaks multi-worker
```python
# BAD — module-level mutable cache (per-worker, not shared)
_user_cache: dict[str, User] = {}

# GOOD — use Valkey (shared across all workers)
await redis.setex(f"user:{uid}", 300, json.dumps(data))
cached = await redis.get(f"user:{uid}")
```

### Rules
- **No module-level dict/list caches.** If you need cache, use Valkey with TTL.
- **No in-process locks** (`threading.Lock`, `asyncio.Lock`) for cross-request coordination — they only protect within one worker.
- **No file-based coordination** (lock files, temp state files). Use Valkey or PG advisory locks.

## Lifespan: Init vs Side-Effects

```python
# GOOD — connection pool init (each worker does its own, no conflict)
async def lifespan(app):
    await init_db()       # creates per-worker connection pool
    redis = await get_redis()
    await redis.ping()
    yield
    await close_db()

# BAD — side-effects in lifespan (4 workers = 4 concurrent runs)
async def lifespan(app):
    await run_migrations()     # 4 concurrent DDL → crash
    await create_default_user()  # 4 concurrent INSERT → duplicate
```

### Where side-effects belong
| Side-effect | Where to run |
|---|---|
| Migrations | `migration` container (`--profile migration`) |
| Seed data (dev user) | Migration SQL (`V31__seed.sql`) or admin API |
| Bucket creation | `ensure_bucket_exists()` — idempotent, OK in lifespan |
| JWKS pre-cache | `get_jwks()` → Valkey — idempotent, OK in lifespan |

## Auto-Create User (disabled)

No-auth mode (`AUTH_REQUIRED=false`) used to auto-create users on first request. This races across workers (4 concurrent INSERTs on same email). **Currently disabled** — returns 403 with "bootstrap required".

If re-enabling later, use:
```sql
INSERT INTO auth.users (...) VALUES (...)
ON CONFLICT (user_id) DO NOTHING;
```

## DDL from App Code

`app_user` has **no DDL privileges** (cannot CREATE INDEX, ALTER TABLE). Per-column JSONB indexes are managed via `SECURITY DEFINER` functions owned by dba:

```python
# Repository calls PG function (runs as dba via SECURITY DEFINER)
await session.execute(
    text("SELECT create_row_data_index(:idx, :tid, :cid, :ct)")
    .bindparams(idx=idx_name, tid=table_id, cid=col_id, ct=col_type)
)
```

Never grant `CREATE` or table ownership to `app_user`. If a new DDL operation is needed at request time, add a SECURITY DEFINER function in a migration.

## Session Deps

```python
async def get_session():
    async with app_session_factory() as session:
        yield session
```

No `finally: rollback()` safety nets. asyncpg pool runs `DISCARD ALL` on connection return — clears all session state (including `app.current_user_id` for RLS). If a request errors, the aborted transaction is cleaned up by pool reset.

## Worker Count

| Environment | Workers | Why |
|---|---|---|
| Dev + `--reload` | 1 | reload requires single process |
| Dev (no reload) | 1-4 | test multi-worker behavior |
| Prod I/O-bound | 4 | async handles concurrency per worker; 4 gives fault isolation |
| Prod CPU-bound | `nproc` | one event loop per core |

## Pre-Merge Checklist

```bash
# Grep for blocking calls
grep -rn "requests\." backend/src/
grep -rn "time\.sleep" backend/src/
grep -rn "boto3\." backend/src/   # should be aioboto3

# Grep for worker-local mutable state
grep -rnE "^[a-z_]+ *= *(\{\}|\[\])" backend/src/

# Grep for DDL in request path
grep -rnE "CREATE INDEX|DROP INDEX|ALTER TABLE" backend/src/
```
