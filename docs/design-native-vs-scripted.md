# Design: Native Zig vs njs/QuickJS Module Boundary

Informed by a survey of 255 modules across the ngx-modules catalog (140 native C, 115 Lua) and the current nginz module base.

## Decision framework

The ROADMAP names the intended boundary already:

> native Zig = primitives, engines, performance-critical integrations  
> njs = orchestration, policy logic, product customization, glue code

A simple checklist makes this concrete for any candidate module:

| Question | Native if... | njs if... |
|---|---|---|
| Hot path? | yes — per-request, CPU-sensitive | no — low frequency or async |
| Needs shared memory? | yes — counters, rings, maps | no — or shared dict is enough |
| Deep C API? | yes — BPF, QUIC, parser engines | no — HTTP objects are sufficient |
| Policy / branching logic? | no | yes — claim rules, routing trees, flag eval |
| Rapid iteration likely? | no | yes — webhook signatures, OAuth flows |
| Data structure is the module? | yes — trie, ring, LRU | no — logic around plain HTTP state |

When both columns apply, build a native primitive and expose it through njs. That is the hybrid model the ROADMAP already uses implicitly for shared dict + njs hooks.

---

## Native Zig candidates

### Tier 1 — high leverage, clear product value

#### `brotli` + `zstd` compression
- **Why native**: compression is pure hot-path CPU work; no scripting layer can accelerate it
- **Catalog signal**: `ngx_brotli` and `zstd-nginx-module` both exist and are widely deployed
- **Nginz gap**: only gzip is available today; both brotli and zstd have wide browser/CDN adoption
- **Approach**: Zig module wrapping upstream `brotli` and `zstd` C libraries as output filter; mirrors the existing `echoz` filter pattern
- **Priority**: high — unlocks a real performance feature with no scripting equivalent

#### `headers-more`
- **Why native**: per-request header manipulation at filter phase; needs to run efficiently on every response
- **Catalog signal**: `headers-more-nginx-module` is among the most universally deployed nginx additions
- **Nginz gap**: no equivalent today; security response headers, CORS, and CSP all need this
- **Approach**: header filter module with `add_header`, `set_header`, `remove_header` directives; can build on the existing `echoz` filter ordering experience
- **Priority**: high — needed by almost every production deployment

#### `vts` (virtual-host traffic status)
- **Why native**: per-location / per-upstream metrics with shared-memory ring storage; inherently performance-sensitive
- **Catalog signal**: `nginx-module-vts` is the de facto real-time nginx status dashboard module
- **Nginz gap**: `prometheus` module exists but vts provides richer per-upstream / per-server-zone breakdowns
- **Approach**: shared-memory zone module exporting per-location/upstream counters; complements rather than replaces `prometheus`
- **Priority**: medium — strong commercial-nginx signal, pairs with upstream policy work

#### `cache-purge` + `srcache`
- **Why native**: cache manipulation requires direct access to nginx's proxy cache internals; `srcache` (subrequest-driven transparent caching) needs filter chain integration
- **Catalog signal**: `ngx_cache_purge` fills a real operational gap; `srcache` enables transparent application-layer caching patterns that are hard to replicate otherwise
- **Nginz gap**: `cache-tags` exists but cache purge and transparent subrequest caching are different axes
- **Approach**: two separate modules; purge is simpler (shared-mem key invalidation); srcache requires subrequest + body filter cooperation
- **Priority**: medium — completes the programmable cache story from ROADMAP §5

#### `hmac-secure-link`
- **Why native**: HMAC verification on hot path; same logic that made JWT native makes this native
- **Catalog signal**: `nginx-hmac-secure-link` combines nginx's built-in `secure_link` with HMAC-SHA, widely used for signed URL patterns
- **Nginz gap**: JWT + OIDC are covered; signed URL / webhook token verification is not
- **Approach**: access-phase handler similar to JWT module; reuses existing HMAC infrastructure
- **Priority**: medium — closes the signed-URL gap in the security suite

### Tier 2 — upstream / LB platform work

#### `sticky` session balancing
- **Why native**: upstream peer selection is a C API; no scripting layer can safely override the balancer callback
- **Catalog signal**: `nginx-sticky-module-ng` is the reference; sticky sessions appear in nearly every commercial-nginx feature list
- **Approach**: upstream balancer module (peer.get/free callbacks) with cookie-based or header-based affinity; builds on upstream balancer from ROADMAP §3
- **Priority**: medium — natural companion to upstream balancer work

#### `upstream-dynamic` / `upsync`
- **Why native**: dynamic peer add/remove requires shared-memory peer tables; this is deep C API territory
- **Catalog signal**: `nginx-upstream-dynamic-servers` and `tengine/upsync-module` show the pattern; Consul integration (nginz already has) needs dynamic upstream management
- **Approach**: pairs with the existing `consul` module for a complete service-discovery story
- **Priority**: low-medium — high value but complex; do upstream balancer first

---

## njs/QuickJS candidates

These are modules where the Lua ecosystem has invested heavily — not because Lua is fast, but because the problems are logic-heavy and njs fits them just as well.

### Tier 1 — highest immediate value

#### HTTP client composition (`lua-resty-http` analog)
- **Lua pattern**: `lua-resty-http` wraps `ngx.location.capture()` for HTTP client flows
- **njs equivalent**: `ngx.fetch()` already exists in the njs surface
- **What to ship**: a documented njs library (`.js` file checked into nginz) wrapping `ngx.fetch()` with a clean API: retry, timeout, auth header injection, response body parsing
- **Why njs**: pure logic wrapper, no C integration needed, rapid iteration as APIs change
- **Priority**: high — enables all subrequest composition patterns today without a new native module

#### Session management (`lua-resty-session` analog)
- **Lua pattern**: cookie-based session with AES encryption + HMAC, shared dict for server-side store
- **njs equivalent**: njs for the cookie logic + AES/HMAC via Web Crypto; shared dict for server-side sessions once that module lands
- **What to ship**: njs session library; server-side storage pluggable (shared dict or redis)
- **Why njs**: session logic is branchy policy code, not performance-critical parsing
- **Priority**: medium — needed for stateful gateway patterns; depends on shared dict

#### Policy / authz engine (`lua-resty-casbin` analog)
- **Lua pattern**: `lua-resty-casbin` evaluates RBAC/ABAC policies at request time
- **njs equivalent**: njs JWT claim extraction + policy evaluation; can call `ngx.fetch()` for external OPA/Cedar decision point
- **What to ship**: njs policy evaluation library that pairs with the native JWT module via nginx variables; OPA sidecar integration example
- **Why njs**: policy rules change frequently; scripting is the right layer for branching authorization logic
- **Priority**: high — high-demand in API gateway scenarios; ROADMAP §7 names this

#### Response templating (`lua-resty-template` analog)
- **Lua pattern**: `lua-resty-template` renders Mustache-like templates from nginx variables
- **njs equivalent**: njs body filter that fills template slots from `r.variables`
- **What to ship**: simple njs body filter library; works as a lightweight edge-rendering layer
- **Why njs**: pure string transformation; no parser engine needed
- **Priority**: low-medium — real use case but not platform-enabling

### Tier 2 — pairs well with native work

#### Two-level LRU + shared dict cache (`lua-resty-mlcache` analog)
- **Lua pattern**: `lua-resty-mlcache` combines per-worker LRU cache with shared dict backing store and a stampede-collapse lock
- **njs equivalent**: njs manages LRU policy; shared dict is the backing layer once native module lands
- **What to ship**: njs mlcache library wrapping `ngx.shared` with LRU eviction and lock collapse
- **Why njs**: the policy (eviction, TTL, stampede logic) is script-friendly; the shared memory primitive stays native
- **Priority**: medium — very high leverage once shared dict exists

#### Metrics forwarding (`lua-resty-statsd` / `lua-resty-influx` analog)
- **Lua pattern**: sends per-request metrics to StatsD or InfluxDB over UDP
- **njs equivalent**: log phase njs script using `ngx.fetch()` or a shared dict buffer
- **What to ship**: njs log-phase metrics emitter; DogStatsD format first (simplest)
- **Why njs**: protocol serialization is string work; no performance requirement in log phase
- **Priority**: low — `prometheus` module covers the pull-based story; this covers push

#### Feature flags + A/B routing
- **Lua pattern**: various custom solutions; `lua-resty-mlcache` often backs flag state
- **njs equivalent**: njs reads flag state from shared dict or upstream fetch, applies routing/header logic
- **What to ship**: example njs script + ROADMAP note; not a separate packaged module yet
- **Why njs**: flag evaluation is pure conditional logic
- **Priority**: low — more an application pattern than a platform primitive

---

## Hybrid patterns (native primitive + njs policy)

Some problems need both. The right pattern is: native Zig provides the performance primitive or C-API integration, njs provides the policy shell.

### Phantom token / OAuth introspection
- **Native**: HTTP subrequest to introspection endpoint (same mechanism as `jwt_key_request`); cache introspection result in shared dict by token hash
- **njs**: claim-to-role mapping, downstream header injection, error response shaping
- **Catalog signal**: `nginx-phantom-token-module` — native C module that swaps opaque tokens for JWTs via introspection subrequest
- **Recommended approach**: extend the JWT module with an `jwt_introspect_endpoint` directive (native), expose result variables to njs for policy evaluation

### Worker-level event bus
- **Native**: shared-memory signal ring (write from any worker, broadcast); native because it requires shared-memory atomics
- **njs**: subscribe to events in a log-phase or timer handler; acts on cache invalidation, config reload signals, session revocation
- **Catalog signal**: `lua-resty-worker-events` is widely used for cross-worker coordination in OpenResty
- **Recommended approach**: native shared ring module, njs handler convention

### Geo / IP intelligence
- **Native**: MaxMind-style MMDB lookup (binary trie in shared memory); C binding to `libmaxminddb`
- **njs**: policy on top — block, redirect, tag, or rate-limit by country/ASN via variables
- **Catalog signal**: `ngx_http_geoip2_module` is the reference; IP intelligence is common in WAF and traffic modules
- **Recommended approach**: native module exposing `$geoip2_country`, `$geoip2_asn` etc.; njs for routing/blocking policy

---

## Prioritized build sequence

Given the ROADMAP's stated top three (njs platform, shared dict, upstream balancer), the catalog survey adds specificity:

### Sprint 1 — platform enablement
1. **njs first-class packaging** — docs, examples, bun integration tests for `ngx.fetch()`, body filters, shared dict; no new C code required
2. **`headers-more`** — native, unblocks almost every production deployment
3. **`brotli`** — native, performance feature with no scripting alternative

### Sprint 2 — state + composition
4. **Shared dict module** — native, unblocks mlcache, session, feature flags, phantom-token cache
5. **njs HTTP client library** — scripted, wraps `ngx.fetch()`, ships with examples and tests
6. **njs session library** — scripted, depends on shared dict

### Sprint 3 — traffic + observability
7. **Upstream balancer + sticky** — native, complements `consul` and `healthcheck`
8. **`vts`** — native, per-location/upstream metrics complement `prometheus`
9. **njs policy/authz library** — scripted, pairs with JWT/OIDC claim variables

### Deferred (complexity > immediate value)
- `srcache` — complex filter-chain interaction; do after upstream balancer
- `upstream-dynamic` / `upsync` — after upstream balancer foundation
- Geo / IP intelligence — real dependency on `libmaxminddb` C library; high value but isolated
- Phantom token — extend JWT module when OAuth introspection use case is concrete
- Worker event bus — do after shared dict; design together

---

## What not to build as native

Modules that exist in the Lua catalog but belong in njs, not native Zig:

| Lua module | Why not native | njs alternative |
|---|---|---|
| `lua-resty-jwt` | JWT is already native; claim policy is script | njs script on `$jwt_claim_*` variables |
| `lua-resty-http` | `ngx.fetch()` already exists | njs wrapper library |
| `lua-resty-radixtree` | routing logic, not parser engine | njs radix library |
| `lua-resty-validation` | input schema logic | njs + JSON Schema (or native jsonschema module) |
| `lua-resty-statsd` | log-phase string formatting | njs log handler |
| `lua-resty-template` | string rendering | njs body filter |

Building these native would add C integration complexity with no performance gain. njs is the right layer.

---

## Summary

The catalog confirms the ROADMAP boundary is correctly drawn. The practical gaps are:

**Native**: brotli, zstd, headers-more, vts, cache-purge, hmac-secure-link, sticky — all performance-sensitive or C-API-bound  
**njs**: HTTP client library, session, policy/authz, mlcache, metrics forwarding — all logic-heavy, benefit from rapid iteration  
**Hybrid**: phantom token, geo/IP, worker events — native primitive + njs policy shell

---

## Why most of the catalog was not selected

255 modules were surveyed. The table above and the priority lists above account for roughly 25. The rest fall into the categories below.

### Already covered — would duplicate existing nginz modules

| Catalog module | What already covers it |
|---|---|
| `nginx-auth-jwt` (upstream C reference) | `jwt` module — nginz already has better coverage |
| `lua-resty-jwt` | same |
| `lua-resty-openidc` | `oidc` module |
| `ngx_http_auth_request_module` | nginx core built-in; `jwt_key_request` subrequest mechanism already works on top of it |
| `ngx_http_limit_req_module` | nginx core built-in; `ratelimit` module wraps and extends it |
| `ngx_http_limit_conn_module` | nginx core built-in |
| `lua-resty-redis` | `redis` module |
| `lua-resty-postgres` / `lua-resty-mysql` | `pgrest` module covers PostgreSQL; MySQL is out of scope but pgrest sets the pattern |
| `echo-nginx-module` | `echoz` module |
| `ngx_http_redis2_module` | `redis` module; raw protocol via config directives is an anti-pattern in nginz |
| `ngx_http_geo_module` | nginx core already has basic geo; the gap (GeoIP2 MMDB) is addressed in the deferred geo module |
| `lua-resty-lrucache` | subsumed by the mlcache design above; a standalone LRU without shared dict backing is too limited |
| `lua-resty-hmac` | HMAC is available via the `hmac-secure-link` candidate and njs Web Crypto |

### Little product value — real modules, wrong priority

These exist and work, but they solve narrow or fading problems. Building them would consume roadmap attention without advancing the platform.

| Catalog module | Why skipped |
|---|---|
| `nginx-dav-ext-module` | WebDAV extensions; almost no current use case |
| `iconv-nginx-module` | Character set conversion in the request path; effectively a dead use case |
| `memc-nginx-module` | Memcached via nginx config directives; Memcached itself is in decline |
| `ngx_http_redis2_module` | Raw Redis text protocol through config; superseded by real Redis integration |
| `nginx-upload-module` | Multipart upload handling; narrow, complex, high maintenance |
| `mod_zip` | ZIP assembly from sub-requests; extremely niche |
| `ngx_http_substitutions_filter_module` / `subs-filter` | Regex substitution in response body; very narrow use case, high complexity |
| `array-var-nginx-module` | Array variable support — works around nginx config limitations that Zig modules don't have |
| `set-misc-nginx-module` | Miscellaneous variable operations — again works around nginx config limitations, not relevant in Zig |
| `lua-resty-cassandra` | Cassandra driver; specific data store, not a general platform primitive |
| `lua-resty-mongo` | MongoDB driver; same reasoning |
| `lua-resty-influx` | InfluxDB push metrics; narrow protocol, low general value |
| `nginx-lua-prometheus` | Prometheus via Lua; nginz has a native prometheus module that does this better |
| `ngx_devel_kit` (NDK) | Meta-toolkit for C module authors; nginz modules are written in Zig, NDK macros are irrelevant |

### Wrong direction — fundamentally incompatible with nginz's design

These are real, widely-deployed pieces of software. They are not selected because their design directly conflicts with nginz's architecture choices, not because they are low quality.

| Catalog module | Why it's a no-go |
|---|---|
| `lua-nginx-module` (OpenResty core) | This IS the Lua runtime. Nginz chose njs/QuickJS. Adding Lua would mean maintaining two full scripting ecosystems — exactly what the ROADMAP explicitly rules out. |
| `stream-lua-nginx-module` | Same: Lua in the stream path. Same conflict. |
| `ngx_mruby` | Ruby scripting in nginx. Wrong runtime direction entirely. |
| `nginx-clojure` | JVM (Java/Clojure/Groovy) embedded in nginx. Far outside nginz scope. |
| Kong plugin system | Application-layer API gateway framework. nginz is a module platform, not an application framework. Kong is the thing you build on top of this. |
| Passenger / Phusion | Ruby/Python app server integration. Out of scope — nginz is not an application server. |
| Any RTMP / media streaming module | `ngx_rtmp_module` and derivatives are a significant fork of the nginx event loop for media protocol handling. Huge maintenance surface for a very niche use case. If media streaming is needed, it should be a separate project or binary. |
| `mod_security` v2/v3 | The C reference WAF. Nginz has a native WAF. ModSecurity v3 embeds a 200k-line C library with its own parser framework. The native WAF approach is the right call — keep the detection engine under control, not imported. |
| `openresty` bundle | A distribution, not a module. Nginz is its own distribution. |
| Tengine-specific modules | Tengine is a fork, not an upstream. Modules that require Tengine patches cannot be built on stock nginx. |

### Native no-goes — should not be native even though C versions exist

Some of these have native C implementations in the catalog, but building them as native Zig modules in nginz would be the wrong abstraction.

| Module type | Why scripted is correct |
|---|---|
| Claim-to-role / RBAC policy (`lua-resty-casbin` analog) | Policy rules change constantly — version-controlled scripts are the right artifact, not recompiled binaries |
| Response templating (`lua-resty-template` analog) | String interpolation has no meaningful hot-path; native adds complexity for zero performance gain |
| Routing logic libraries (`lua-resty-radixtree` analog) | A radix tree lookup is O(k) on path depth; njs is fast enough; native buys nothing here |
| Feature flag evaluation | Pure conditional logic on request variables; scripting is faster to iterate than recompilation |
| Webhook signature verification glue | Signatures change per-vendor; the verification primitive is native (HMAC), the glue is scripted |
| StatsD / DogStatsD metric emission | Log-phase string formatting; no performance constraint |

The pattern: when the performance-critical operation is already native (HMAC, JSON parsing, variable lookup), the surrounding coordination logic belongs in njs.

### Scripted no-goes — should not be scripted even though Lua patterns exist

Some things have Lua solutions in OpenResty but should not follow the same pattern in nginz.

| Module type | Why native is required |
|---|---|
| WAF detection engine | Regex NFA traversal, scoring, and pattern matching at line rate; njs cannot run this without degrading throughput |
| JWT / JWS signature verification | Cryptographic primitives must be in auditable, predictable native code; also hot path |
| Rate limit counters | Requires shared-memory atomic increments; njs has no access to shm atomics outside of `ngx.shared`, which is too coarse for per-IP/per-route token buckets |
| Circuit breaker state machine | Same: shared-memory state transitions across worker processes require native locking primitives |
| brotli / zstd compression | CPU-bound filter; JS cannot compress at acceptable throughput |
| TLS / ACME certificate management | Deep C API (OpenSSL), timer interaction, file I/O; no sensible scripting path |
| Request body parsing (JSON Schema validation) | Per-request JSON parse is the hot path; native cJSON is the right choice |

The pattern: when correctness, predictability, or shared-memory coordination is the requirement, native Zig is not optional.

---

## Recommendations: concur vs challenge

These recommendations are based on three inputs:

- the project `ROADMAP.md`
- the current `nginz` module base
- the broader module taxonomy in `/home/kaiwu/Documents/gitea/ngx-modules/json/index.json`

The taxonomy matters because it shows where the nginx ecosystem has concentrated real module demand:

- **native-heavy areas**: Authentication & Security, Content Processing, Utilities & Variables, Monitoring & Logging, Protocol & Transport, Upstream & Load Balancing
- **Lua-heavy areas**: HTTP client/proxy, routing logic, policy wrappers, data-store glue, nginx-core integration, observability push adapters

That split broadly supports the design boundary in this document, but it also suggests a few adjustments in emphasis.

### Concur

#### 1. Concur: keep the native-vs-scripted boundary explicit

The document’s core rule is sound:

- **native Zig** for hot-path primitives, shared-memory state, and deep nginx/OpenSSL/system integration
- **njs/QuickJS** for orchestration, policy composition, and product-specific logic

This matches both the roadmap and the ecosystem counts from `index.json`. The native catalog is strongest where correctness, performance, or low-level integration dominate. The Lua catalog is strongest where people want to change behavior quickly without recompiling.

#### 2. Concur: do not build a parallel Lua story

This is the right strategic constraint. The roadmap already says the project should not split into a separate Lua runtime track, and the design doc uses that correctly as a forcing function. The taxonomy does not contradict this. It shows where Lua was useful historically, but most of those wins came from *programmability*, not from Lua as a language requirement.

#### 3. Concur: productize the existing njs path before adding more native platform pieces

The strongest alignment between this design doc and the roadmap is the idea that the immediate gap is not “missing scripting,” but “missing productized scripting.”

The roadmap’s “HTTP njs hook module” and this doc’s “njs first-class packaging” are effectively the same platform move and should be treated as one coordinated initiative:

- supported packaging
- first-class examples
- integration coverage
- conventions for native-to-script exposure

That should happen before the project takes on too many additional native modules.

#### 4. Concur: native `headers-more`, compression, and upstream policy are the right early native bets

From the ecosystem taxonomy, native demand clusters heavily around:

- security/authentication
- content processing / filtering
- load balancing / upstream control

So the design doc is directionally right to prioritize:

- `headers-more`
- `brotli` / `zstd`
- upstream balancer / sticky / policy work

These are categories where njs is not a substitute.

### Challenge

#### 5. Challenge: keep Sprint 1 explicitly mixed instead of letting njs productization dominate the framing

The current nginz module base is already broad, but the project still lacks a few “every deployment expects this” native features.

If forced to choose sequencing, I would avoid letting “njs first-class packaging” read like the *only* Sprint 1 priority. It should stay paired with at least one immediately marketable native deployment primitive, especially:

1. `headers-more`
2. `brotli`

Reason: the roadmap is trying to build both OpenResty-style flexibility and commercial-nginx credibility. `headers-more` and modern compression do more for day-one production credibility than docs/examples alone.

So my refinement is:

- **Sprint 1 should be mixed, not purely platformization**
- one scripting-platform deliverable
- one or two obvious native production features

#### 6. Challenge: “shared dict” is under-specified relative to how central it is to the whole architecture

The design treats shared dict as a natural next primitive, which is correct, but the document understates how many later choices become constrained by it.

Before building policy/authz/session/mlcache-style layers, the project needs an explicit shared-dict contract:

- value types
- eviction model
- memory accounting
- atomic operations
- timer / expiration semantics
- cross-worker notification expectations

Without that, downstream njs libraries risk becoming throwaway adapters around an unstable core primitive.

I would add a short design requirement:

> No session/policy/cache library should be treated as stable until the shared-dict primitive contract is stable.

#### 7. Challenge: some items listed as “njs libraries” are really product bundles, not just libraries

The document is right that pieces like session/authz/http-wrapper belong in njs, but they will not succeed as raw helper files alone. They need to be treated as packaged platform capabilities with:

- config conventions
- example deployments
- support boundaries
- versioned compatibility guarantees

In other words, the doc should distinguish:

- **njs helper library**
- **njs-backed nginz product feature**

That distinction matters for maintenance and roadmap promises.

#### 8. Challenge: “vts” is probably less urgent than first-class gateway control primitives

The taxonomy does show meaningful monitoring/logging demand on the native side, but relative to the current nginz base, richer observability is less urgent than:

- shared dict
- upstream policy / sticky balancing
- programmable cache behavior
- policy/authz composition

`prometheus` already gives nginz a respectable metrics story. A stronger commercial-nginx gap today is not “more dashboards,” but “more gateway-grade traffic policy and shared state.”

So I would move `vts` down one priority notch behind:

1. shared dict
2. upstream balancer / sticky
3. headers-more
4. compression

#### 9. Challenge: the document should explicitly separate “module candidates” from “platform bundles”

Right now the list mixes:

- real native modules
- njs libraries
- hybrid module-plus-script systems

That is conceptually correct, but operationally muddy.

I would add a simple label to each candidate:

- **native module**
- **njs library**
- **hybrid platform bundle**

This will reduce later roadmap confusion about what “shipping” an item actually means.

### Recommended near-term adjustment

If I compress the roadmap and this design into a sharper execution view, my recommendation is:

#### Near-term top five

1. **njs first-class packaging + examples + test matrix**
2. **headers-more**
3. **brotli**
4. **shared dict primitive with a documented contract**
5. **upstream balancer / sticky policy foundation**

This keeps the document’s core philosophy intact while improving delivery order for real operator value.

### Final recommendation

Overall, I **concur** with the design boundary and with the rejection of a second scripting ecosystem.

I **challenge** the sequencing and packaging assumptions in three places:

- Sprint 1 should include at least one obvious native production primitive, not just njs platformization
- shared dict needs a stricter primitive contract before too many dependent libraries are promised
- the document should classify deliverables as native modules, njs libraries, or hybrid bundles to keep roadmap promises crisp

That would make the document stronger without changing its core thesis.
