# Design: True Commercial Gaps in the Open-Source nginx Module Ecosystem

> Companion to `design-native-vs-scripted.md` — different lens, not a correction.
> That doc assumes nginz ships as a binary product. This one does not.

## Meta-frame

**The nginz binary is a test harness, not a deliverable.** It exists for integration-testing our Zig `.so` modules against a real nginx event loop.

**The deliverable is the Zig modules themselves.** They load into whatever nginx the operator runs — open-source, nginx-plus, OpenResty, Tengine.

We do not aim to replicate existing open-source nginx modules. If a C module solves the problem well with no crash history or operational pain, we leave it alone.

## Methodology

This analysis is grounded in the [ngx-modules catalog]() which surveys **255 nginx modules** (140 native C, 115 Lua). Each candidate is evaluated against three criteria:

1. **Commercial gap:** Is this a feature gate-kept behind nginx-plus or other commercial distributions?
2. **C pain level:** Does the existing C implementation have known crash classes, memory-safety issues, or reliability problems that Zig's safety model directly addresses?
3. **Alternatives exist?** Is there already a good open-source solution we can recommend instead of building?

## Reality check: what the catalog already provides

Before listing gaps, we must acknowledge what the open-source ecosystem already has that is **good enough** — modules we should not touch because the C implementation is battle-tested and the pain surface is negligible.

### Modules confirmed as "no gap" after catalog audit

| Module | Catalog entry | Why skip |
|---|---|---|
| **brotli / zstd** | `native-compression-optimization/brotli`, `/zstd` | Thin C glue over upstream C libraries. Performance bottleneck is the library, not the module wrapper. Zero crash history in the glue layer. |
| **headers-more** | `native-utilities-variables` | One of the most battle-tested C modules in existence. ~15 years of production use. Zero crash history. Ubiquitous. |
| **HMAC secure-link** | `native-authentication-security/hmac-secure-link` | Simple state machine. No shared memory. No reload hazards. Works fine as C. |
| **GeoIP2** | `native-geo-location/geoip2` | Thin C glue over `libmaxminddb` (well-audited C library). Bindings are trivial. No crash history. |
| **JWT / OIDC** | `native-authentication-security/jwt` | Already covered by nginz's JWT and OIDC modules. Done. |
| **NJS shared dict** | `native-lua-scripting/njs` (built-in: `ngx_js_shared_dict.c`) | Production-grade shared memory zone by Dmitry Volyntsev (nginx core team). RB-tree + slab allocator + rwlock + TTL + JSON persistence. No Lua coupling — built directly into njs. Do not build. |
| **All Lua authentication modules** | `lua-authentication-security/` (14 modules) | OpenResty ecosystem. If needed, their patterns can be replicated in njs. Not a native module gap. |
| **All Lua data store drivers** | `lua-data-store-drivers/` (12 modules) | Lua cosocket-based clients (Redis, MySQL, Kafka, etc.). njs lacks cosocket, but porting protocol drivers is an njs platform gap, not a native module gap. |
| **Phantom token** | `native-authentication-security/phantom-token` | Existing C module is prototype-grade, but RFC 9068 (JWT access tokens) is making this pattern obsolete. Zero-trust migration increasingly issues JWTs directly. Low and declining demand. Defer. |

## True gaps

Each gap is supported by evidence from the 255-module catalog.

### 1. Upstream balancer + sticky sessions

**Catalog evidence:**
- `native-upstream-load-balancing/sticky` — the reference C module. Known crash class under reload-and-race conditions due to peer reference-count errors.
- `lua-routing-load-balancing/balancer`, `/upstream` — proves the community *needs* custom balancer logic but is forced into Lua because the C API is unreliable.

**Why this is a gap:**
- **Commercial:** Sticky sessions are a flagship nginx-plus feature. Open-source `sticky` module exists but is unreliable.
- **Pain:** The nginx upstream peer API (`peer.get`/`peer.free` callbacks, reference counts on `ngx_http_upstream_peer_t`, shared-memory peer lists, fail/bypass counters, worker-exit ordering) is **the single most crash-prone module interface in the nginx ecosystem**. Getting the reference-counting and deallocation lifecycle right in C is notoriously hard — multiple modules have shipped broken implementations.
- **Zig advantage:** Zig's explicit memory management and lack of hidden control flow make shared-memory peer lifecycle auditable. The pattern (atomic refcount in shared memory, deterministic free on worker exit) is exactly where C's implicit tooling fails.

**Alternative:** None at the stock-nginx level. OpenResty's `balancer_by_lua_block` works but runs Lua per-request, unacceptable for high-throughput deployments.

### 2. Dynamic upstream reconfiguration (no reload)

**Catalog evidence:**
- `native-upstream-load-balancing/upsync` — syncs upstreams from Consul/etcd. Had crash CVEs from peer table corruption during shared-memory updates.
- `native-upstream-load-balancing/upstream-dynamic` — async DNS re-resolution. Narrower scope but same shared-peer-table problem.
- `lua-routing-load-balancing/upstream` — OpenResty Lua balancer that fetches peers per-request. Performance-prohibitive.
- nginz already has a `consul` module.

**Why this is a gap:**
- **Commercial:** Dynamic upstreams without reload is a flagship nginx-plus feature (`/api/` endpoint for upstream management).
- **Pain:** The dominant pattern is Consul template + `nginx -s reload`, which tears down connections and causes latency spikes. `upsync` avoids reload but its two-phase peer table swap has a history of corruption bugs. An atomic RCU-style pointer swap on shared memory is the correct solution.
- **Zig advantage:** Lock-free shared-memory data structures benefit from Zig's explicit memory ordering and comptime generics.

**Blocks on:** Upstream balancer (item 1) — dynamic upstreams reuse the same peer table infrastructure.

### 3. Active health checks + slow-start

**Catalog evidence:**
- `lua-routing-load-balancing/upstream-healthcheck` — described as "Health Checker for NGINX Upstream Servers in Pure Lua." **This is direct evidence**: the community needed active health checks so badly they built it in Lua, because no stock-nginx C module exists.
- `lua-miscellaneous-utilities/healthcheck` — another Lua healthcheck library.
- **No native C module** for active health checks exists in the catalog. Tengine has one (`nginx_upstream_check_module`) but it requires a forked nginx — it cannot be loaded as a dynamic module into stock nginx.

**Why this is a gap:**
- **Commercial:** Active health checks are consistently the #1 cited reason for upgrading to nginx-plus in their documentation and case studies. Nginx-plus periodically probes upstreams with HTTP/TCP/HTTPS health checks at configurable intervals.
- **Pain:** Stock nginx only has passive health checks (`max_fails` + `fail_timeout`) — it only detects failures on requests *already being proxied*. Without active probes, a failed upstream stays in rotation until a user's request fails against it.
- **Paired need — slow-start:** When a health check (or admin action) marks a server healthy, nginx-plus gradually ramps traffic to it (`slow_start`). Without this, a recovering server gets thundering-herded. No open-source module provides this either.
- **Zig advantage:** Timer management + shared memory health state + safe filter chain integration. The module logic is straightforward — the barrier has always been that building it requires patching nginx core. A Zig dynamic module bypasses this.

**Priority note:** This is the most surprising gap in the catalog. It's a well-known nginx-plus feature with zero adequate open-source alternatives, yet it's rarely discussed in module-building circles because the Tengine patch exists as a quasi-solution.

### 4. Worker event bus (njs-native)

**Catalog evidence:**
- `lua-monitoring-observability/worker-events` — described as "Cross Worker Events for NGINX in Pure Lua." **Direct evidence**: the OpenResty community needed this so much they built `lua-resty-worker-events`.
- njs has zero equivalent — no way for one worker to signal another.

**Why this is a gap:**
- **Not a commercial gap** (nginx-plus doesn't advertise this), but an **architectural enabler** for the Zig-native + njs-policy hybrid model.
- Without cross-worker signaling, cache invalidation, config-reload hooks, session revocation, and feature-flag updates cannot propagate between workers in njs. Each worker discovers changes independently — poll-based, not event-driven.
- **Catalog proof:** The Lua module exists for exactly this reason. The OpenResty ecosystem depends on it. njs is left out.

**Approach:** A small shared-memory signal ring in Zig (atomic ring buffer, multi-producer single-consumer per worker) with an njs event handler surface: `ngx.on('cache:invalidate', handler)`. The ring is the native primitive; the subscription pattern is the njs policy shell.

### 5. Selective cache-purge (with REST API)

**Catalog evidence:**
- `native-caching-performance/cache-purge` — raw HTTP PURGE method. No selective purge, no access control, no audit.
- `native-caching-performance/selective-cache-purge` — **interesting**: uses Redis for GLOB pattern matching to support selective invalidation. This proves someone needed selective purge badly enough to add a Redis dependency.
- `native-utilities-variables/keyval` — key-value store with REST-accessible API. Partially overlaps.
- nginz already has `cache-tags`.

**Why this is a gap:**
- Nginx-plus provides programmatic cache-purge through its `/api/` endpoint, supporting selective invalidation by URL prefix, cache tags, or wildcard patterns.
- `ngx_cache_purge` works but is operationally raw — no rate limiting, no access zones, no audit logging, no JSON response.
- `selective-cache-purge` solves the pattern-matching problem but at the cost of a Redis dependency. A shared-memory solution would be operationally simpler.

**Priority:** Medium. Many operations teams are fine with `ngx_cache_purge` + IP-allowlist. The pain is real but not acute.

### 6. VTS (memory-safe virtual-host traffic status)

**Catalog evidence:**
- `native-monitoring-logging/vts` — "NGINX virtual host traffic status module." De facto standard for real-time status dashboards.
- `native-monitoring-logging/traffic-accounting` — real-time bidirectional traffic metering. Nginx-plus analogue.
- `native-protocol-transport/stream-sts` — stream-module variant of vts.
- nginz already has a `prometheus` module.

**Why this is a gap:**
- `nginx-module-vts` (vozlt) has had memory-management issues under high-cardinality metric spaces (many locations × many upstreams × many status codes). The metric ring is pool-allocated with manual lifecycle — leaks have been reported.
- However, the Prometheus module already covers 90% of monitoring needs. VTS provides richer per-upstream breakdowns, but this is a convenience feature, not an architectural gap.

**Priority:** Low. Build only if observability is a declared product priority.

### 7. Unified REST runtime API

**Catalog evidence:**
- `native-utilities-variables/keyval` — key-value store. Has some REST-like access but no unified `/api/` endpoint.
- `native-monitoring-logging/vts` — exposes JSON status but read-only.
- `native-caching-performance/cache-purge` — accepts PURGE requests but writes only.
- **No module** provides the unified read-write runtime API that nginx-plus exposes at `/api/` (upstream status, cache info, keyval read/write, upstream server add/remove).

**Why this is a gap:**
- Not every deployment needs this, but for automated operations (Kubernetes integration, CI/CD pipelines, auto-scaling), the lack of a read-write runtime API means every configuration change requires a config file edit + reload.
- **This is an njs library, not a native module.** `ngx.shared` provides the keyval backend. nginx's upstream status is accessible via `ngx.__proto__` in njs. A well-structured njs library serving an HTTP JSON API with proper auth would close this gap without any Zig code.

**Priority:** Low-medium. High value but no Zig work required. Best done as a capstone once dynamic upstreams (item 2) and cache-purge (item 5) are functional.

## What NOT to build (complete list)

Derived from the full catalog audit. These are modules that either (a) already have production-grade C implementations with no crash history, or (b) are better built as njs libraries on top of existing primitives.

### Already production-grade in C — skip

| Category | Modules | Reason |
|---|---|---|
| Authentication & Security | auth-digest, auth-ldap, auth-pam, auth-totp, auth-hash, bot-verifier, captcha, testcookie, spnego-http-auth, shibboleth, ntlm, secure-token | All working C modules. No crash history. Varying demand but none have the kind of pain that justifies a Zig rewrite. |
| Compression & Optimization | brotli, zstd, unbrotli, unzstd, concat, immutable, length-hiding, compression-normalize, compression-vary | Thin glue over libraries. No pain. |
| Content Processing | fancyindex, form-input, substitutions, upload, upload-progress, iconv, image-filter, jpeg, webp, xslt, xss, markdown, html-sanitize, vod, sxg | Either core nginx built-ins, trivial C code, or highly specialized. No crash patterns. |
| Geo & Location | geoip, geoip2, accept-language | Thin glue over well-audited C libraries (libmaxminddb, etc.). |
| Monitoring & Logging | statsd, graphite, log-zmq, log-sqlite, upstream-log, pipelog, error-log-write, log-var-set | All working C modules. Simple state. No shared memory hazards. |
| Protocol & Transport | ajp, rtmp, srt, doh, proxy-connect | Specialized protocols. Niche demand, working C code. |
| Upstream & LB | upstream-fair, upstream-jdomain, combined-upstreams | Fair is simple. Jdomain is async DNS — solid C code. Combined-upstreams is complex but no crash history. |
| Utilities & Variables | array-var, set-misc, let, var, echo, ndk, coolkit, cookie-flag, cookie-limit, delay, device-type, dynamic-etag, ipset-access, nftset-access, limit-traffic-rate | All working C modules. The set-misc/let/var space is well-covered. headers-more is the standout for reliability. |
| Miscellaneous | acme, otel, nchan, postgres, pagespeed, passenger, memc, redis2, redis-rate-limit, slowfs, small-light, f4fhds, flv, google, live-common, cgi, dav-ext, sysguard, tuning, untar, wasm-wasmtime, fips-check | All working. Some are huge (pagespeed), some are niche (wasm), but none have the kind of shared-memory crash class that Zig addresses. |

### Better as njs libraries — skip native

| Category | Modules | njs approach |
|---|---|---|
| Authentication & Security | hmac, jwt, jwt-verification, openidc (all Lua) | nginz already has native JWT + OIDC. HMAC via njs Web Crypto. |
| Caching & Performance | mlcache, lrucache, lock, counter, global-throttle, limit-rate, limit-traffic (all Lua) | njs + `ngx.shared` covers all of these. mlcache is an njs library. |
| Data Store Drivers | redis, mysql, postgres, kafka, etc. (all Lua cosocket) | njs platform gap — no cosocket. When njs gets it, these become njs libraries. |
| Monitoring | stats, influx, timer, txid (all Lua) | njs log phase + `ngx.fetch()` covers push metrics. |
| Routing | radixtree, router, locations, vhost (all Lua) | njs string matching is sufficient for most routing. Radix tree could be native if routing performance is critical, but defer. |

## Updated priority

Based on the full catalog audit of 255 modules, the njs built-in shared dict discovery, and the "commercial gap + C pain" dual filter:

```
Rank | Module                      | Type    | Why
─────────────────────────────────────────────────────────────────────────────
1    | Upstream balancer + sticky  | Zig     | Highest C crash surface (#1 nginx-plus gap)
2    | Dynamic upstreams          | Zig     | Peer table CVEs in upsync; completes consul module
3    | Active health checks       | Zig     | Biggest unfilled nginx-plus gap; Lua workaround is proof
4    | Worker event bus           | Zig     | OpenResty has it, njs doesn't; Lua module proves the need
5    | Selective cache-purge API  | Zig     | Nginx-plus feature; selective-cache-purge uses Redis crutch
6    | VTS (memory-safe)          | Zig     | Leak issues under high cardinality; lower urgency
7    | REST runtime API           | njs lib | Nginx-plus /api/ analogue; no Zig needed, high ops value
```

## Build order rationale

**Sprints 1-2 (foundation):**

1. **Upstream balancer + sticky** — highest pain, unlocks everything below
2. **Dynamic upstreams** — reuses peer infrastructure from (1); completes consul integration

**Sprints 3-4 (commercial features):**

3. **Active health checks + slow-start** — standalone module; no dependency on (1) but pairs naturally
4. **Worker event bus** — enables all njs hybrid patterns; the ring buffer pattern is reusable

**Sprints 5+ (polish):**

5. **Selective cache-purge** — depends on shared ring (for purge notifications) if built, otherwise standalone
6. **VTS** — lower urgency; prometheus covers most needs
7. **REST runtime API (njs)** — can be done in parallel; capstone that makes the modules product-ready

## Relationship to the original doc

The original `design-native-vs-scripted.md` is correct for its frame: "what do we ship in the nginz binary to make it a complete product?"

This doc answers a different question: "which modules are worth writing in Zig because the open-source community genuinely suffers without them?"

The two lists diverge at every key decision:

| Area | Original doc (binary product) | This doc (gap vendor) |
|---|---|---|
| brotli/zstd | Tier 1 native | Skip — no pain |
| headers-more | Sprint 1 native | Skip — battle-tested C |
| shared dict | Sprint 2 native | Skip — built into njs |
| Upstream balancer | Sprint 3, medium | #1 priority |
| Dynamic upstreams | Deferred | #2 priority |
| Active health checks | Not listed | #3 priority |
| Worker event bus | Deferred | #4 priority |

Neither is wrong — they serve different product strategies.

## Audit (2026-05-03)

### Decision

**Partially agree.** The seven-item list is directionally strong as a gap analysis, but I do **not** agree that we should proceed to all seven as equal Zig module targets right now.

The repo evidence supports a **phased subset**, not a blanket go-ahead:

- **Proceed first (highest-value Zig work):**
  1. **Upstream balancer + sticky**
  2. **Dynamic upstreams** — but only after the balancer/peer-table foundation is stable
- **Proceed, but narrowed to existing groundwork:**
  3. **Active health checks + slow-start** should be treated as an extension of the existing `healthcheck` module, because active probing already exists; the missing commercial-grade piece is upstream peer marking and recovery behavior
- **Proceed later (medium priority):**
  4. **Worker event bus**
  5. **Selective cache-purge API**
- **Defer / reframe:**
  6. **VTS** — defer; current `prometheus` coverage already handles most observability needs and this doc already ranks VTS lower
  7. **REST runtime API** — reframe as **njs library / productization work**, not a Zig module

### Reasons

1. **The repo is mature enough for new modules, but not for all seven in parallel.**
   Existing access/content/filter/upstream/shared-memory patterns are strong across the current module base, so the project is capable of substantial new work. But the most dangerous surface in this list is upstream peer lifecycle, and there is currently no existing module using nginx upstream `peer.get` / `peer.free` APIs. That makes broad-front execution the wrong risk posture.

2. **Some of the listed “gaps” are already partially closed by the current repo.**
   - Built-in **njs** already exists and is tested.
   - **`js_shared_dict`** already exists through njs, which weakens any plan that assumes a native shared-state primitive must be built first.
   - The **`healthcheck`** module already implements active probing, so the real missing work is not “health checks” in general but specifically upstream integration, peer marking, and slow-start semantics.
   - **`prometheus`** already covers much of the observability story, which lowers the urgency of VTS.

3. **The docs are using different strategy lenses and should not be merged into a single execution queue.**
   `ROADMAP.md` mixes platformization and product breadth. This commercial-gaps note is trying to identify where Zig meaningfully improves on the open-source ecosystem. Those are useful perspectives, but they do not imply that every item here should become an immediate Zig build target.

4. **The REST runtime API is explicitly not a Zig-module candidate.**
   This document already says the runtime API is best done as an **njs library**. That is the correct framing and should stay explicit in any execution plan.

5. **VTS is a reasonable idea, but not one of the next best uses of effort.**
   It is a convenience/completeness feature, not the sharpest commercial gap, especially when upstream control, runtime traffic policy, and existing healthcheck work remain more strategic.

### Recommended execution interpretation of this note

If this document is kept as the commercial-gap reference, the practical takeaway should be:

- **Go now:** upstream balancer + sticky
- **Go next, dependent on that foundation:** dynamic upstreams
- **Go as enhancement, not greenfield module:** healthcheck peer-marking + slow-start
- **Go later:** worker event bus, selective cache-purge API
- **Do not treat as current Zig-module work:** VTS, REST runtime API

That keeps the core thesis of this document intact while aligning it with the actual repo state and avoiding duplicate work where the platform already has coverage.
