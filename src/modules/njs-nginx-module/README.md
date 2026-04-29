# NJS (QuickJS) Module

nginx built-in JavaScript module powered by QuickJS engine. Nginz bundles njs and provides
integration tests demonstrating its use as an orchestration layer between Redis, PGrest, and
other nginx modules via `r.subrequest()`.

## Status

**Built-in** — njs is compiled into the nginz binary. Tests demonstrate ecosystem integration.

## Features (tested)

- **`r.subrequest()`** — internal subrequests to other nginx locations
- **`Promise.all()`** — parallel subrequest fan-out
- **`r.args`, `r.requestText`, `r.headersIn/Out`** — request/response inspection
- **`ngx.fetch()`** — external HTTP requests
- **`js_shared_dict`** — shared in-memory key-value store
- **`Buffer`, `crypto`** — encoding and hashing
- **`querystring`, `fs`, `xml`** — stdlib modules

## Test Files

| File | Purpose | Tests |
|------|---------|-------|
| `njs.test.js` | Core njs runtime (handlers, crypto, Buffer) | 18 |
| `http-features.test.js` | `r.subrequest`, `ngx.fetch`, `js_shared_dict` | 14 |
| `stdlib.test.js` | querystring, fs, xml modules | 14 |
| `redis-subrequest.test.js` | Single-command Redis subrequests (all 14 commands) | 26 |
| `pgrest-subrequest.test.js` | Single-operation PGrest CRUD via subrequests | 6 |
| `combo-subrequest.test.js` | Cross-service orchestrations | 17 |

**Total: 95 tests**

## Combo Patterns (njs + Redis + PGrest)

All combo handlers live in `tests/njs/combo_subrequest.js` and demonstrate real-world
orchestration patterns using `r.subrequest()` to chain internal nginx locations.

### Same-Service Combos

```nginx
# Redis SET then GET — write-then-read round-trip
location /combo/redis-write-read {
    js_content main.redis_write_then_read;
}
```

```js
async function redis_write_then_read(r) {
    var setReply = await r.subrequest('/_redis/combo_set', {
        method: 'POST', body: r.requestText,
    });
    var getReply = await r.subrequest('/_redis/combo_get');
    // Returns { set: {...}, get: { value: "..." } }
}
```

| Combo | Commands | Description |
|-------|----------|-------------|
| write-then-read | SET → GET | Write a value, immediately read it back (shared key via `redis_key`) |
| INCR twice | INCR → INCR | Sequential counter increments in one request |
| DEL + refresh | DEL → PGrest → SET | Invalidate stale cache, fetch fresh data, re-cache |

### Cross-Service Combos

```nginx
# Redis + PGrest parallel fetch
location /combo/redis-pgrest-parallel {
    js_content main.redis_and_pgrest;
}
```

```js
async function redis_and_pgrest(r) {
    var [redisReply, pgReply] = await Promise.all([
        r.subrequest('/_redis/get/cached-users'),
        r.subrequest('/_pgrest/api/users'),
    ]);
    // Combines redis_value + pgrest_user_count in response
}
```

| Combo | Services | Description |
|-------|----------|-------------|
| parallel fetch | Redis ∥ PGrest | `Promise.all` fan-out to both backends |
| conditional cache | Redis → PGrest | Check Redis first; on MISS, fallback to PGrest |
| read-through cache | Redis → PGrest → Redis | On MISS: fetch PGrest, populate cache, return |
| counter + data | Redis INCR + PGrest GET | Increment hit counter + fetch data in one request |

### Advanced Patterns

| Combo | Commands | Description |
|-------|----------|-------------|
| TTL-aware refresh | GET + TTL → PGrest | Check TTL; if expiring, refresh from PGrest |
| DECR rate gate | DECR → allow/deny PGrest | Decrement quota; block if exhausted (429) |
| hash config query | HGET → PGrest | Read query config from Redis hash; parametrize PGrest `select` |
| MGET batch fallback | MGET → PGrest | Batch Redis lookup; for each MISS, fallback to PGrest |
| EXISTS guard | EXISTS → allow/deny PGrest | Feature-gate writes behind a Redis guard key |
| PING health gate | PING → PGrest | Health-check Redis; only query PGrest if healthy |
| STRLEN refresh | STRLEN → PGrest → SET | Validate cache payload size; refresh if too short |

## Cross-Command Key Sharing

Redis module derives keys from URI paths (`/_redis/get/mykey` → key `_redis/get/mykey`).
When a combo needs to write and read the **same key** from different command locations,
use the `redis_key` directive to pin a fixed key:

```nginx
# Two locations sharing key "combo-data"
location /_redis/combo_set {
    internal;
    redis_pass 127.0.0.1:16379;
    redis_command set;
    redis_key combo-data;
}
location /_redis/combo_get {
    internal;
    redis_pass 127.0.0.1:16379;
    redis_command get;
    redis_key combo-data;
}
```

Now `r.subrequest('/_redis/combo_set', { method: 'POST', body: 'x' })` and
`r.subrequest('/_redis/combo_get')` both operate on the same Redis key.

## Running Tests

```bash
# All njs tests
bun test tests/njs/

# Specific test files
bun test tests/njs/redis-subrequest.test.js
bun test tests/njs/combo-subrequest.test.js
bun test tests/njs/pgrest-subrequest.test.js
```

Tests use mock servers for Redis (port 16379) and PostgreSQL (port 15432) — no external
containers needed. The mocks are started/stopped automatically by each test file.

## Nginx Config Pattern for Subrequest Tests

```nginx
http {
    js_engine qjs;
    js_path ".";
    js_import main from my_handlers.js;

    server {
        listen 8888;

        # Internal targets (only reachable via subrequest)
        location /_redis/get/ {
            internal;
            redis_pass 127.0.0.1:16379;
        }

        location /_pgrest/api/ {
            internal;
            pgrest_pass "host=127.0.0.1 port=15432 dbname=test user=test password=test";
            pgrest_schemas "public";
        }

        # Public njs handlers
        location /api/cached-users {
            js_content main.redis_check_then_pgrest;
        }
    }
}
```

## Limitations

- **Sequential PGrest subrequests**: Two back-to-back PGrest subrequests in the same njs
  handler may fail with ECONNRESET (mock limitation). Cross-service sequences
  (e.g. PGrest → Redis SET) work fine.
- **Redis key prefixes**: URI-based key derivation means different command locations
  produce different Redis keys. Use `redis_key` directive for shared-key combos.
- **Subrequest body size**: Large request bodies through `r.subrequest()` may require
  `client_body_in_single_buffer on` on the target location.

## References

- [nginx njs documentation](https://nginx.org/en/docs/njs/)
- [njs reference](https://nginx.org/en/docs/njs/reference.html)
