## Redis Module

Simple Redis client using RESP protocol with non-blocking upstream I/O.

### Status

**Implemented** - GET, SET, DEL, INCR, DECR, EXPIRE, MGET, EXISTS, TTL, PING, STRLEN, HGET, HSET, HDEL commands

### Features

- **14 Commands**: GET, SET, DEL, INCR, DECR, EXPIRE, MGET, EXISTS, TTL, PING, STRLEN, HGET, HSET, HDEL
- **Non-blocking I/O**: Uses nginx upstream module for async operations
- **URI-based Keys**: Use request URI path as Redis key
- **Static Keys**: Configure fixed key via directive
- **JSON Responses**: Returns values as JSON objects
- **Connection Reuse**: Supports keepalive connections to Redis

### Directives

#### redis_pass

*syntax:* `redis_pass <host>:<port>;`
*context:* `location`

Enable Redis passthrough and specify the Redis server address.

```nginx
redis_pass 127.0.0.1:6379;
redis_pass redis.local:6380;
```

#### redis_key

*syntax:* `redis_key <key>;`
*context:* `location`

Set a static Redis key instead of deriving from URI.

```nginx
redis_key mykey;
```

#### redis_command

*syntax:* `redis_command <get|set|del|incr|decr|expire|mget|exists|ttl|ping|strlen|hget|hset|hdel>;`
*context:* `location`
*default:* `get`

Set the Redis command to execute. Default is `get`.

```nginx
redis_command set;
redis_command incr;
redis_command hget;
```

### Usage

```nginx
http {
    server {
        listen 8080;

        # GET - Fetch value using URI path as key
        # GET /cache/mykey -> Redis GET "cache/mykey"
        location /cache/ {
            redis_pass 127.0.0.1:6379;
        }

        # GET - Using static key
        # GET /config -> Redis GET "app-config"
        location /config {
            redis_pass 127.0.0.1:6379;
            redis_key app-config;
        }

        # SET - Store value (POST body becomes value)
        # POST /set/mykey with body "myvalue" -> Redis SET "set/mykey" "myvalue"
        location /set/ {
            redis_pass 127.0.0.1:6379;
            redis_command set;
        }

        # DEL - Delete key
        # POST /del/mykey -> Redis DEL "del/mykey"
        location /del/ {
            redis_pass 127.0.0.1:6379;
            redis_command del;
        }

        # INCR - Increment counter
        # POST /incr/counter -> Redis INCR "incr/counter"
        location /incr/ {
            redis_pass 127.0.0.1:6379;
            redis_command incr;
        }

        # EXPIRE - Set TTL (POST body is seconds, defaults to 60)
        # POST /expire/mykey with body "3600" -> Redis EXPIRE "expire/mykey" 3600
        location /expire/ {
            redis_pass 127.0.0.1:6379;
            redis_command expire;
        }

        # MGET - Get multiple values
        # GET /mget?keys=key1,key2,key3 -> Redis MGET key1 key2 key3
        location /mget {
            redis_pass 127.0.0.1:6379;
            redis_command mget;
        }

        # DECR - Decrement counter
        # POST /decr/counter -> Redis DECR "decr/counter"
        location /decr/ {
            redis_pass 127.0.0.1:6379;
            redis_command decr;
        }

        # EXISTS - Check if key exists
        # GET /exists/mykey -> Redis EXISTS "exists/mykey"
        location /exists/ {
            redis_pass 127.0.0.1:6379;
            redis_command exists;
        }

        # TTL - Get time-to-live
        # GET /ttl/mykey -> Redis TTL "ttl/mykey"
        location /ttl/ {
            redis_pass 127.0.0.1:6379;
            redis_command ttl;
        }

        # PING - Health check
        # GET /ping -> Redis PING
        location /ping {
            redis_pass 127.0.0.1:6379;
            redis_command ping;
        }

        # STRLEN - String length
        # GET /strlen/mykey -> Redis STRLEN "strlen/mykey"
        location /strlen/ {
            redis_pass 127.0.0.1:6379;
            redis_command strlen;
        }

        # HGET - Get hash field
        # GET /hget/myhash?field=name -> Redis HGET "hget/myhash" name
        location /hget/ {
            redis_pass 127.0.0.1:6379;
            redis_command hget;
        }

        # HSET - Set hash field
        # POST /hset/myhash?field=name with body "Alice" -> Redis HSET "hset/myhash" name Alice
        location /hset/ {
            redis_pass 127.0.0.1:6379;
            redis_command hset;
        }

        # HDEL - Delete hash field
        # POST /hdel/myhash?field=name -> Redis HDEL "hdel/myhash" name
        location /hdel/ {
            redis_pass 127.0.0.1:6379;
            redis_command hdel;
        }
    }
}
```

### HTTP Methods

| Command | HTTP Methods | Request Body | Query Params |
|---------|-------------|--------------|-------------|
| GET     | GET         | -            | - |
| SET     | POST        | Value to set | - |
| DEL     | POST, DELETE| -            | - |
| INCR    | POST        | -            | - |
| DECR    | POST        | -            | - |
| EXPIRE  | POST        | TTL seconds (optional, default 60) | - |
| MGET    | GET         | -            | keys=key1,key2,... |
| EXISTS  | GET         | -            | - |
| TTL     | GET         | -            | - |
| PING    | GET         | -            | - |
| STRLEN  | GET         | -            | - |
| HGET    | GET         | -            | field=<field> |
| HSET    | POST        | Value to set | field=<field> |
| HDEL    | POST, DELETE| -            | field=<field> |

### Response Format

**GET (value exists):**
```json
{"value":"the-value-from-redis"}
```

**GET (key not found):**
```json
{"value":null}
```

**SET (success):**
```json
{"ok":true}
```

**DEL (returns count of deleted keys):**
```json
{"value":1}
```

**INCR (returns new value):**
```json
{"value":42}
```

**DECR (returns new value):**
```json
{"value":9}
```

**EXPIRE (returns 1 if key exists, 0 if not):**
```json
{"value":1}
```

**MGET (returns array of values):**
```json
{"values":["value1","value2",null]}
```

**EXISTS (returns 1 if key exists, 0 if not):**
```json
{"value":1}
```

**TTL (returns TTL in seconds, -1 if no expiry, -2 if key not found):**
```json
{"value":300}
```

**PING (health check):**
```json
{"ok":true}
```

**STRLEN (returns string length, 0 if key not found):**
```json
{"value":5}
```

**HGET (returns hash field value):**
```json
{"value":"Alice"}
```

**HSET (returns 1 if field is new, 0 if updated):**
```json
{"value":1}
```

**HDEL (returns 1 if field was deleted, 0 if not found):**
```json
{"value":1}
```

**Error response:**
```json
{"error":"connection_failed"}
```

### Key Derivation

When `redis_key` is not configured, the key is derived from the request URI:
- URI `/cache/mykey` → Redis key `cache/mykey`
- URI `/data` → Redis key `data`

The leading slash is stripped from the URI to form the key.

### Nginx Variables

These variables expose per-request Redis state to `nginz-njs` scripted modules without a subrequest round-trip.

| Variable | Values | Scripted consumers |
|---|---|---|
| `$redis_last_value` | string / not found | `feature_flags`, `session` — cheap read-through cache adapter |
| `$redis_last_exists` | `1` / `0` | `feature_flags`, `workflow` — branch on key presence without JSON parsing |
| `$redis_last_error` | `redis_error` / `connection_failed` / not found | `workflow`, `circuit_breaker_policy` — retry/fallback policy |
| `$redis_connection_state` | `connected` / `degraded` / `error` | `health_gateway`, `workflow` — health-aware routing |

- `$redis_last_value` is set only when the key exists and has a non-empty string value. Not set for nil responses, SET/PING, or MGET.
- `$redis_last_exists` is `1` for any non-nil Redis response, `0` for nil (`$-1`).
- `$redis_last_error` is `redis_error` when Redis returned a `-ERR` response, `connection_failed` when the upstream connection failed, and not found otherwise.
- `$redis_connection_state` is `connected` (normal), `degraded` (Redis error response), or `error` (connection failure).

### Limitations

- **No Authentication**: Redis AUTH not supported
- **No Pipelining**: Single command per connection
- **MGET Max Keys**: Limited to 16 keys per request

### Testing

**Unit tests** (`redis.test.js`) use a mock Redis server (`tests/mocks/redis.js`) to test all module operations without external dependencies. Run with:

```bash
bun test tests/redis/redis.test.js
```

**Container tests** (`redis.container.test.js`) run against a real Redis instance for integration testing. Requires a running Redis Docker container:

```bash
# Start Redis container (one-time setup)
sudo docker run -d --name redis-nginz-test -p 6379:6379 redis:8.6.2-trixie

# Run container tests
bun test tests/redis/redis.container.test.js
```

### Future Enhancements

- **Authentication**: Redis AUTH and ACL support
- **Variable Expansion**: Support nginx variables in redis_key
- **Timeout Configuration**: Configurable connection and read timeouts
- **Cluster Support**: Redis Cluster mode routing

### References

- [Redis Protocol (RESP)](https://redis.io/docs/reference/protocol-spec/)
- [ngx_http_redis Module](https://www.nginx.com/resources/wiki/modules/redis/)

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/redis/`.
- [x] Gap recorded: this audit pass added Bun guardrails for JSON string escaping, invalid `INCR`/`EXPIRE` protocol errors, MGET query parsing with extra parameters, and the 16-key MGET limit.
- [x] Variable integration coverage now verifies `$redis_last_exists`, `$redis_last_error`, and `$redis_connection_state`, plus safe `$redis_last_value` hit semantics, across hit/miss/error/failure paths.
- [x] No additional documentation gaps were identified in this audit pass.

### Engineering Audit Verdict (2026-07-12)

**Verdict: S0/S1 CORE FIXED; S2 COPY REDUCED (2026-07-12).** RESP parsing is strictly bounded and the upstream buffer matches the enforced aggregate frame limit. JSON rendering now references bulk, integer, and MGET payload slices directly in the request-owned upstream frame instead of first duplicating each payload into request-pool storage; only the final escaped JSON representation is allocated. The exact-limit and full 67-case focused suite remains green. Larger streaming is a feature/performance extension.
