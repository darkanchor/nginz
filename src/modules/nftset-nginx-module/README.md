## nftset-nginx-module

Zero-latency IP blocking for nginx using Linux nftables named sets.

### Status

**Feature Ready** — The module performs request-time kernel lookup via raw Netlink `NFT_MSG_GETSETELEM`, exposes `$nftset_result` and `$nftset_matched_set`, enforces `nftset_deny`, `nftset_status`, `nftset_fail_open`, `nftset_dryrun`, `nftset_cache_ttl`, `nftset_sets`, `nftset_autoadd`, and `nftset_ratelimit`/`nftset_autoban`, and runs live nftables coverage in Docker-isolated tests so host nftables never needs to be touched. Lookup caching keeps the existing per-worker L1 hot path, adds a shared-memory L2 for cross-worker reuse, uses a shared invalidation generation so definitive writes can evict stale local misses safely, and now conservatively disambiguates `ENOENT` with a `NFT_MSG_GETSET` slow-path probe so missing sets surface as lookup errors without regressing the common miss path.

See [GitHub issue #5](https://github.com/kaiwu/nginz/issues/5) for the original feature request.

---

### Detected Issues

- **Fixed in this audit:** the README had drifted behind the implementation. It still described kernel lookup as unimplemented and claimed a `libnftables` build/runtime dependency even though the module now uses a raw Netlink path and `build.zig` does not link `libnftables`.
- **Fixed in this audit:** the raw Netlink request path had unsafe unaligned packet-buffer access. The lookup code now uses byte-copy helpers instead of typed writes into unaligned buffers, which stopped nginx worker crashes on the first enabled request.
- **Fixed in this audit:** the raw Netlink exchange now uses the correct nfnetlink subsystem/message constants, sends explicitly to the kernel, correlates replies by `nlmsg_seq`, and rejects malformed/truncated frames as lookup errors instead of trusting them.
- **Fixed in this audit:** positive and negative membership behavior is now covered against live nftables sets in a Docker-isolated test namespace instead of relying only on fail-open / fail-closed fallback coverage.
- **Fixed in this audit:** `nftset_cache_ttl` now drives a two-level membership cache: per-worker L1 for hot hits plus a shared-memory L2 for cross-worker reuse, with generation-based invalidation when module writes definitively make an IP present.
- **Fixed in this audit:** the auto-add / auto-ban write path now refreshes caches only on definitive kernel outcomes (`added` / `exists`). Ambiguous completion without an ACK is treated as a write error instead of optimistic success.
- **Fixed in this audit:** `GETSETELEM` `ENOENT` is now disambiguated conservatively. The fast path is unchanged for confirmed hits, but an `ENOENT` miss now performs a raw `NFT_MSG_GETSET` probe: existing set ⇒ `not_in_set`, missing set ⇒ lookup error, ambiguous probe ⇒ `not_in_set`.

#### Motivation

Traditional IP blocking via `deny` directives or `geo` maps requires a full nginx reload to take effect. Linux nftables sets are kernel-side hash tables that can be updated atomically at runtime with `nft add element`. This lets an operator or security daemon block a crawling IP in < 1 ms without touching nginx configuration at all.

#### Architecture

```
Request
  │
  ▼
ACCESS phase handler (ngx_http_nftset_access_handler)
  │
  ├─ disabled → NGX_DECLINED
  │
  ├─ extract remote IP bytes from r->connection->sockaddr
  │
  ├─ query nftables named set via raw Netlink `NFT_MSG_GETSETELEM`
  │   ├─ nftset_deny on  → IP in set → 403 Forbidden
  │   └─ nftset_deny off → IP not in set → 403 Forbidden  (allowlist mode)
  │
  └─ NGX_DECLINED (pass through)
```

#### IP Lookup Strategy

Two implementation approaches were considered:

| Approach | Latency | Complexity | Notes |
|---|---|---|---|
| **libnftables** (`libnftables.so`) | ~10–50 µs | Medium | High-level C API; handles parsing; requires `libnftables-dev` |
| **Netlink socket** (raw) | ~1–5 µs | High | Direct kernel ABI; no extra deps; portable across distros |

The current module uses the raw Netlink path. `libnftables` remains a possible future fallback if the raw ABI path proves too brittle across kernels or capabilities.

The relevant Netlink message type is `NFT_MSG_GETSETELEM` on `NFNL_SUBSYS_NFTABLES`. The lookup is a point query (single IP → present/absent) so it does not iterate the full set. Because Linux overloads `ENOENT` for both “element missing” and “set missing”, the module now keeps the fast path on `GETSETELEM` and only performs a conservative `NFT_MSG_GETSET` existence probe after `ENOENT`.

#### nftables Set Requirements

The target nftables set must be of type `ipv4_addr` (for `inet`/`ip` families) or `ipv6_addr` (for `ip6`). For CIDR/prefix matching, create the set with `flags interval` and add prefixes like `127.0.0.0/24` or `10.0.0.0/8`. Example setup:

```bash
# Create table and set
nft add table inet filter
nft add set inet filter blocklist { type ipv4_addr \; flags dynamic,timeout \; }

# Block an IP at runtime (no nginx reload needed)
nft add element inet filter blocklist { 1.2.3.4 }

# Remove a block
nft delete element inet filter blocklist { 1.2.3.4 }
```

The module reads the set at request time and can cache definitive membership results for the configured TTL. The fast path remains per-worker L1; L1 misses can reuse a shared-memory L2 entry written by another worker. Set `nftset_cache_ttl 0;` when you need every request to reflect nftables mutations immediately.

For `nftset_autoadd`, the target set should allow runtime insertion. In practice this means creating it with `flags dynamic`; if you want per-element expiry, add `timeout` support as well.

---

### Directives

#### nftset

*syntax:* `nftset on|off;`
*default:* `nftset off;`
*context:* `http, server, location`

Enable or disable nftset IP checking for this location.

#### nftset_table

*syntax:* `nftset_table <name>;`
*default:* `nftset_table filter;`
*context:* `http, server, location`

nftables table name to query.

#### nftset_set

*syntax:* `nftset_set <name>;`
*default:* `nftset_set blocklist;`
*context:* `http, server, location`

nftables set name inside the table.

`nftset_set` also accepts the combined `table:set` form. When a colon is present the table name is extracted and `nftset_table` is updated accordingly, so a single directive fully specifies the target:

```nginx
nftset_set nginz_test:blocklist;
# equivalent to:
#   nftset_table nginz_test;
#   nftset_set   blocklist;
```

Plain names (no colon) continue to work as before for backward compatibility.

#### nftset_blacklist

*syntax:* `nftset_blacklist <table:set> [table:set ...];`
*default:* none
*context:* `http, server, location`

Shorthand that enables nftset, registers one or more sets as blocklist targets (`nftset_deny on`), and populates `nftset_sets`. Equivalent to:

```nginx
nftset     on;
nftset_sets table:setname;
nftset_deny on;
```

#### nftset_whitelist

*syntax:* `nftset_whitelist <table:set> [table:set ...];`
*default:* none
*context:* `http, server, location`

Shorthand that enables nftset in allowlist mode (`nftset_deny off`). Equivalent to:

```nginx
nftset      on;
nftset_sets table:setname;
nftset_deny off;
```

#### nftset_sets

*syntax:* `nftset_sets <table:set> [table:set ...];`
*default:* none
*context:* `http, server, location`

Variadic OR matching across multiple nftables sets. The first matching entry wins and populates `$nftset_matched_set` with the winning `table:set` value. When `nftset_sets` is configured, it overrides the single `nftset_table` / `nftset_set` pair for lookups in that context.

#### nftset_family

*syntax:* `nftset_family inet|ip|ip6;`
*default:* `nftset_family inet;`
*context:* `http, server, location`

nftables address family. Use `inet` for dual-stack, `ip` for IPv4-only, `ip6` for IPv6-only.

#### nftset_deny

*syntax:* `nftset_deny on|off;`
*default:* `nftset_deny on;`
*context:* `http, server, location`

- `on` — **blocklist** mode: IPs found in the set are denied.
- `off` — **allowlist** mode: IPs *not* found in the set are denied.

#### nftset_status

*syntax:* `nftset_status <code>;`
*default:* `nftset_status 403;`
*context:* `http, server, location`

HTTP status code returned when a request is blocked. Common values: `403` (Forbidden), `429` (Too Many Requests), `503` (Service Unavailable), `444` (nginx connection-close).

#### nftset_fail_open

*syntax:* `nftset_fail_open on|off;`
*default:* `nftset_fail_open off;`
*context:* `http, server, location`

Controls behaviour when the nftables kernel lookup itself fails (e.g. set does not exist, permission denied).

- `off` — deny the request (fail closed, secure default).
- `on` — allow the request through (fail open, prefer availability).

#### nftset_dryrun

*syntax:* `nftset_dryrun on|off;`
*default:* `nftset_dryrun off;`
*context:* `http, server, location`

When enabled, the module logs what it would block but never actually blocks. `$nftset_result` is set to `dryrun`. Useful for validating set membership before enabling enforcement.

#### nftset_cache_ttl

*syntax:* `nftset_cache_ttl <time>;`
*default:* `nftset_cache_ttl 60s;`
*context:* `http, server, location`

How long to cache the set membership result. Hot hits stay in a per-worker L1 cache, and L1 misses can fall through to a shared-memory L2 before touching the kernel. Set to `0` to disable both cache layers and force every request through the kernel lookup path.

#### nftset_autoadd

*syntax:* `nftset_autoadd on|off;`
*default:* `nftset_autoadd off;`
*context:* `http, server, location`

Adds the current client IP to a target nftables set during request handling. This is intended for honeypot, tarpitting, and progressive blocking flows. Auto-add is non-blocking: if insertion fails, the module logs the error but does not fail the request on that basis alone.

#### nftset_autoadd_table

*syntax:* `nftset_autoadd_table <name>;`
*default:* inherits `nftset_table`
*context:* `http, server, location`

Target nftables table for `nftset_autoadd`.

#### nftset_autoadd_set

*syntax:* `nftset_autoadd_set <name>;`
*default:* inherits `nftset_set`
*context:* `http, server, location`

Target nftables set for `nftset_autoadd`.

#### nftset_autoadd_family

*syntax:* `nftset_autoadd_family inet|ip|ip6;`
*default:* inherits `nftset_family`
*context:* `http, server, location`

Address family used for the auto-add write path. As with lookup, explicit family mismatches are logged and skipped.

#### nftset_autoadd_timeout

*syntax:* `nftset_autoadd_timeout <time>;`
*default:* `0`
*context:* `http, server, location`

Optional per-element timeout for auto-added entries. Encoded as milliseconds to the kernel. The target set must support timeout semantics, typically by being created with `flags dynamic,timeout`.

#### nftset_ratelimit_rate

*syntax:* `nftset_ratelimit_rate <N>r/s;` or `nftset_ratelimit_rate <N>;`
*default:* disabled
*context:* `http, server, location`

Enable a simple fixed-window per-IP rate limit in this context. Counting is shared across workers and scoped to the effective location config.

#### nftset_ratelimit_burst

*syntax:* `nftset_ratelimit_burst <N>;`
*default:* `0`
*context:* `http, server, location`

Allow extra requests beyond `nftset_ratelimit_rate` within the current 1-second window.

#### nftset_ratelimit_status

*syntax:* `nftset_ratelimit_status <code>;`
*default:* `429`
*context:* `http, server, location`

HTTP status code returned when the rate limit budget is exceeded.

#### nftset_autoban_table

*syntax:* `nftset_autoban_table <name>;`
*default:* inherits `nftset_table`
*context:* `http, server, location`

Target nftables table for auto-ban writes triggered by rate-limit overflow.

#### nftset_autoban_set

*syntax:* `nftset_autoban_set <name>;`
*default:* disabled
*context:* `http, server, location`

When set, an over-limit client IP is inserted into this nftables set using the same raw Netlink write path as `nftset_autoadd`.

#### nftset_autoban_family

*syntax:* `nftset_autoban_family inet|ip|ip6;`
*default:* inherits `nftset_family`
*context:* `http, server, location`

Address family used for the auto-ban write path.

#### nftset_autoban_timeout

*syntax:* `nftset_autoban_timeout <time>;`
*default:* `0`
*context:* `http, server, location`

Optional per-element timeout for auto-ban entries. The target set should support `timeout` semantics when this is non-zero.

---

### Usage

#### Blocklist (deny crawlers)

```nginx
location / {
    nftset         on;
    nftset_table   filter;
    nftset_set     blocklist;
    nftset_family  inet;
    nftset_deny    on;

    proxy_pass http://backend;
}
```

Block an abusive IP without reloading nginx:

```bash
nft add element inet filter blocklist { 203.0.113.42 }
```

#### Allowlist (internal API)

```nginx
location /internal/api {
    nftset         on;
    nftset_table   filter;
    nftset_set     trusted;
    nftset_family  inet;
    nftset_deny    off;   # deny anyone NOT in the set

    proxy_pass http://internal;
}
```

#### Multi-set OR logic

```nginx
location / {
    nftset       on;
    nftset_sets  filter:spammers filter:hackers filter:tor_exits;
    nftset_deny  on;

    proxy_pass http://backend;
}
```

#### CIDR / prefix matching

```bash
nft add set ip filter corp_ranges '{ type ipv4_addr; flags interval; }'
nft add element ip filter corp_ranges '{ 10.0.0.0/8, 192.168.0.0/16 }'
```

```nginx
location /internal {
    nftset       on;
    nftset_table filter;
    nftset_set   corp_ranges;
    nftset_deny  off;

    proxy_pass http://internal;
}
```

#### Auto-add honeypot

```bash
nft add set ip filter honeypot '{ type ipv4_addr; flags dynamic; }'
nft add set ip filter honeypot_timeout '{ type ipv4_addr; flags dynamic,timeout; timeout 5m; }'
```

```nginx
location /trap {
    nftset_autoadd       on;
    nftset_autoadd_table filter;
    nftset_autoadd_set   honeypot;

    return 200 "logged\n";
}

location /trap-temporary {
    nftset_autoadd         on;
    nftset_autoadd_table   filter;
    nftset_autoadd_set     honeypot_timeout;
    nftset_autoadd_timeout 10m;

    return 200 "logged temporarily\n";
}
```

If `nftset_autoadd` targets the same set used by request-time lookup in that location, a definitive `added`/`exists` result refreshes the shared L2 entry and bumps a shared invalidation generation so workers drop stale local L1 misses before the next lookup.

#### Rate limit with temporary autoban

```bash
nft add set ip filter ratelimit_banned '{ type ipv4_addr; flags dynamic,timeout; timeout 5m; }'
```

```nginx
location /login {
    nftset on;
    nftset_set ratelimit_banned;
    nftset_cache_ttl 5s;

    nftset_ratelimit_rate   10r/s;
    nftset_ratelimit_burst  5;
    nftset_ratelimit_status 429;

    nftset_autoban_table   filter;
    nftset_autoban_set     ratelimit_banned;
    nftset_autoban_timeout 10m;

    proxy_pass http://auth_backend;
}
```

When `nftset_autoban_set` matches the lookup set, a definitive write refreshes the shared cache and invalidates worker-local L1 entries so subsequent requests are denied by the normal nftset lookup path immediately across workers.

---

### Build

```bash
zig build

# Integration tests (config/inheritance + Docker-isolated live nftables coverage)
bun test tests/nftset/
```

The current implementation uses raw Netlink syscalls from Zig and does **not** link `libnftables` in `build.zig`.

The nftset test directory now contains two layers of coverage:

- `tests/nftset/nftset.test.js` validates directive parsing, inheritance, fail-open / fail-closed handling, and `$nftset_result` behavior without needing live nftables state.
- `tests/nftset/nftset.container.test.js` provisions real nftables tables/sets inside a disposable Docker container and verifies hit/miss behavior there, including cache TTL expiry, `cache_ttl 0` live-refresh behavior, shared-cache invalidation after definitive auto-add / auto-ban writes, write-failure no-refresh behavior, auto-add insertion/expiry/cache interaction, rate-limit overflow with optional auto-ban, missing-set error handling via the `GETSET` slow path, multi-set OR matching, IPv6 hit/miss, and interval/CIDR set matching, so no host nftables rules are modified.

---

### Limitations

- Linux only (nftables is a Linux kernel subsystem).
- Requires the nginx worker process to be able to complete nftables Netlink lookups. When lookup fails, `nftset_fail_open` controls whether the request passes through or is denied.
- IPv4-mapped IPv6 addresses are normalized onto the IPv4 lookup path. Native IPv6 hit/miss coverage now runs in Docker, but broader family / set-type interoperability still needs more real-kernel coverage.
- Lookup caching is two-level: per-worker L1 plus shared-memory L2. Lookup errors are never cached, so transient kernel or capability failures still re-evaluate on the next request.
- The rate limiter now uses nginx shared memory so the same fixed 1-second budget is enforced across workers for a given location/IP bucket.
- That shared rate-limit bucket is keyed by `server_name|location`, so its stability across workers/reloads depends on that pair remaining unique for the intended policy scope.
- Shared generation invalidation only covers lookup-relevant writes performed by this module (`nftset_autoadd` / `nftset_autoban`). Out-of-band `nft` mutations still age out by TTL unless caching is disabled.

---

### Gaps vs. ngx_http_nftset_access (reference module)

Comparison against the [GetPageSpeed nftset-access module](https://nginx-extras.getpagespeed.com/modules/nftset-access/).

#### Directive design

| Area | Reference | Ours | Status |
|---|---|---|---|
| Set spec format | `table:setname` combined token | `nftset_set` accepts both plain name and `table:set` | ✅ Fixed |
| Multiple sets | `nftset_blacklist t:s1 t:s2 …` (OR logic, variadic) | `nftset_sets table:set ...` with first-match OR semantics | ✅ Implemented |
| Blocklist/allowlist naming | Distinct `nftset_blacklist` and `nftset_whitelist` | Aliases for `nftset on; nftset_sets …; nftset_deny on\|off` | ✅ Fixed |
| Directive context | `http`, `server` (inherited down) | ~~`location` only~~ → **`http`, `server`, `location`** | ✅ Fixed |
| IP family | Auto-detected from client address | `nftset_family` is optional — auto-detected from `sockaddr->sa_family`; IPv4-mapped IPv6 normalised to `ip` | ✅ Fixed |

#### Directives

| Directive | Reference semantics | Status |
|---|---|---|
| `nftset_status <code>` | HTTP status on block (403/429/503/444) | ✅ Implemented |
| `nftset_cache_ttl <time>` | Per-worker result cache, default 60 s | ✅ Implemented as per-worker L1 + shared-memory L2 with live Docker coverage |
| `nftset_sets <table:set> ...` | Variadic OR matching across multiple sets | ✅ Implemented |
| `nftset_fail_open on\|off` | Allow/deny on lookup error | ✅ Implemented |
| `nftset_dryrun on\|off` | Log decision, never block | ✅ Implemented |
| `nftset_ratelimit …` | Per-IP rate limit with optional auto-ban | ✅ Implemented with live Docker coverage |
| `nftset_autoadd …` | Honeypot: auto-add client IP to a set, optionally with timeout | ✅ Implemented with live Docker coverage |
| `nftset_stats` | JSON stats endpoint | Open |
| `nftset_metrics` | Prometheus endpoint | Open (overlaps with prometheus module) |
| `nftset_challenge` / `nftset_challenge_difficulty` | JS PoW challenge | Open — significant complexity |

#### Nginx variables

| Variable | Meaning | Status |
|---|---|---|
| `$nftset_result` | `allow` / `deny` / `dryrun` / `error` | ✅ Implemented |
| `$nftset_matched_set` | `table:setname` of the matching set | ✅ Implemented |

### Remaining Work (hard)

1. **Broader write-path kernel coverage** — exercise more auto-add / autoban edge cases such as interval sets, maps, and version-specific batch reply shapes.

### Documentation Audit Checklist

- [x] Audit date: 2026-04-21
- [x] Bun integration coverage exists at `tests/nftset/`.
- [x] Gap fixed in this audit pass: README now reflects that kernel lookup is implemented via raw Netlink rather than still being a stub or a `libnftables`-linked path.
- [x] Gap fixed in this audit pass: the raw Netlink request path no longer performs unsafe unaligned struct access into packet buffers.
- [x] Gap fixed in this audit pass: the raw Netlink lookup now uses the correct nfnetlink subsystem/message constants, which made live nftables membership checks work instead of failing with `EINVAL`.
- [x] Bun integration coverage now verifies fail-open inheritance, fail-closed custom-status behavior, `$nftset_result` on lookup failure, dryrun behavior, directive inheritance across `server` / `location` blocks, and live membership hit/miss behavior in Docker-isolated nftables tests.
- [x] `nftset_ratelimit` now uses a shared-memory zone for cross-worker fixed-window accounting.
- [x] The lookup cache now keeps per-worker L1 hits while adding a shared-memory L2 plus generation-based invalidation for definitive auto-add / auto-ban writes.
- [x] `GETSETELEM` `ENOENT` is now conservatively disambiguated with a `GETSET` slow-path probe so missing sets become lookup errors while confirmed existing-set misses still return `not_in_set`.

### Engineering Audit Verdict (2026-07-12)

**Verdict: S1 BOUNDED; S2 CACHE CONTENTION REDUCED.** Shared zones are cycle-safe, rate limits use a rolling shared 1,000 ms window, and synchronous Netlink receives are capped at 10 ms. Shared lookup-cache reads no longer zero every expired slot while holding the mutex; reclamation stays on the store path. Shared insertion and lookup now begin at the key's hash bucket and linearly probe with full identity comparison, giving normal hits near-constant lock time while preserving collision correctness and eviction semantics. The 33-case mock and 35-case live suites are green.
