## Rate Limiting Module

Fixed-window rate limiting with backward-compatible per-IP defaults and optional variable-driven inputs for generic policy composition.

### Directives

#### ratelimit_rate

*syntax:* `ratelimit_rate <N>r/s;` or `ratelimit_rate <N>;`
*context:* `location`

Enable rate limiting and set the rate limit in requests per second.

#### ratelimit_burst

*syntax:* `ratelimit_burst <N>;`
*default:* `0`
*context:* `location`

Allow additional burst requests beyond the rate limit.

#### ratelimit_key

*syntax:* `ratelimit_key $variable;`
*default:* client IP address
*context:* `location`

Override the identity used for rate-limit accounting within the current location's policy bucket. This prepares the module for future cross-module composition: other modules can publish a stable request-local key via an nginx variable, and ratelimit will count against that key instead of `$remote_addr` while still preserving location-scoped limits.

#### ratelimit_cost

*syntax:* `ratelimit_cost $variable;`
*default:* `1`
*context:* `location`

Override how many tokens a request consumes. The variable should resolve to an integer. Invalid or missing values fall back to `1`.

#### ratelimit_skip

*syntax:* `ratelimit_skip $variable;`
*default:* disabled
*context:* `location`

Bypass enforcement when the variable resolves to a truthy value such as `1`, `true`, `yes`, or `on`. This is useful when an earlier ACCESS module emits a soft “trusted/bypass” signal.

### Variables

#### $ratelimit_result

Per-request decision from the ratelimit module: `allow` or `deny`.

#### $ratelimit_key

The effective key used for accounting on the current request. By default this is the client IP string; when `ratelimit_key` is configured it reflects the resolved variable value.

#### $ratelimit_source

Where the effective key came from:
- `ip` — built-in client IP fallback
- `variable` — value came from `ratelimit_key`

#### $ratelimit_cost

The effective token cost applied to the current request.

### Usage

```nginx
http {
    server {
        listen 8888;

        # Basic rate limiting: 10 requests/second
        location /api {
            ratelimit_rate 10r/s;
            proxy_pass http://backend;
        }

        # Custom rate with burst
        location /api/heavy {
            ratelimit_rate 5r/s;
            ratelimit_burst 10;
            proxy_pass http://backend;
        }

        # Strict rate limiting
        location /login {
            ratelimit_rate 3r/s;
            proxy_pass http://auth;
        }

        # Variable-driven generic key (for future cross-module composition)
        location /api/shared {
            set $rl_key customer-42;
            ratelimit_rate 20r/s;
            ratelimit_key $rl_key;
            proxy_pass http://backend;
        }

        # Variable-driven cost / skip signals
        location /expensive {
            set $rl_cost 3;
            set $rl_skip 0;

            ratelimit_rate 10r/s;
            ratelimit_cost $rl_cost;
            ratelimit_skip $rl_skip;

            add_header X-Ratelimit-Result $ratelimit_result always;
            add_header X-Ratelimit-Key $ratelimit_key always;
            add_header X-Ratelimit-Source $ratelimit_source always;
            add_header X-Ratelimit-Cost $ratelimit_cost always;

            proxy_pass http://backend;
        }
    }
}
```

### Behavior

- Rate limiting is per client IP address by default
- `ratelimit_key`, `ratelimit_cost`, and `ratelimit_skip` let the module consume request-local signals from nginx variables
- Uses a 1-second fixed window algorithm
- Returns HTTP 429 (Too Many Requests) when limit exceeded
- Runs in the access phase so earlier access modules can publish signals first
- Rate state is stored in nginx shared memory, so the same budget is enforced across workers
- Maximum 1024 unique keys tracked in the shared zone (oldest entries reused when full)
- Shared bucket scope is derived from `server_name|location`, which keeps limits stable across workers and reloads but is only as unique as that pair
- Counters remain location-scoped; `ratelimit_key` changes identity inside that location, not across unrelated locations

### Algorithm

The module uses a simple fixed window counter:
- Each IP gets a counter that resets every second
- Requests are allowed if `count < rate + burst`
- When the window expires, the counter resets to 0

When `ratelimit_key` is configured, the same algorithm applies to the resolved variable value instead of the client IP for that location's bucket. When `ratelimit_cost` is configured, each request consumes that many tokens from the current window. When `ratelimit_skip` is truthy, enforcement is bypassed for that request.

### Composition Direction

This module now exposes a minimal generic policy surface without changing existing behavior. The intended pattern is:

1. Earlier modules keep their own private request context.
2. Those modules publish request-local signals via nginx variables.
3. `ratelimit` reads those variables and makes the final allow/deny decision.

This keeps cross-module contracts explicit and avoids direct coupling between module-private `ctx` structs.

Because `ratelimit` now runs in the ACCESS phase, it only sees signals from modules that run before it and return `NGX_DECLINED`. If an earlier ACCESS handler returns `401`, `403`, `429`, or another final status, ratelimit will not run for that request.

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/ratelimit/`.
- [x] Bun integration coverage now verifies plain numeric `ratelimit_rate <N>` syntax, burst accounting, post-window reset behavior, and separate counters for different rate-limited locations.
- [x] Generic ratelimit inputs now support variable-driven key, cost, and skip signals while preserving the original per-IP behavior and existing tests.
- [x] ACCESS-phase composition tradeoff is documented: ratelimit only sees earlier soft-signal modules, not handlers that already finalized the request.
- [x] Fixed-window counters now live in a shared-memory zone, and the Bun coverage runs with `worker_processes 2` to verify cross-worker enforcement.
- [x] No additional documentation gaps were identified in this audit pass.

### Engineering Audit Verdict (2026-07-12)

**Verdict: S1 CAPACITY POLICY FIXED; IDENTITY/TELEMETRY OPEN.** At 1,024 simultaneous live windows, a new key is now denied rather than evicting another client's enforcement state; expired entries remain reusable. A full-table unit proof preserves the first bucket, and the focused 14-case multi-worker suite is green. Saturation metrics and collision-resolving key identity beyond the current 64-bit hash remain S1 hardening.
