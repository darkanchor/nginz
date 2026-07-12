# ROADMAP

## Direction

Nginz should grow toward a platform that is credible at both:

- the **commercial nginx** layer: traffic control, upstream policy, security, observability, gateway behavior
- the **OpenResty ecosystem** layer: programmable edge behavior, shared state, internal composition, policy logic

The project should **not** branch into a separate Lua story. `build.zig` already shows the intended scripting/runtime direction:

- `njs` is part of the build
- `quickjs` is part of the build

So the roadmap should amplify that direction rather than compete with it.

## Current module base

The existing modules already cover a good foundation:

- security/auth: `jwt`, `oidc`, `waf`, `acme`, `jsonschema`
- traffic: `healthcheck`, `canary`, `ratelimit`, `requestid`, `circuit-breaker`
- data/upstream: `pgrest`, `redis`, `consul`
- processing/edge: `graphql`, `transform`, `cache-tags`, `prometheus`

That means the next modules should focus less on isolated point features and more on **platform-enabling gaps**.

## Priority roadmap

### 1. HTTP njs hook module

Highest-priority gap.

Goal:

- expose request/response lifecycle hooks to the existing njs+QuickJS runtime
- make scripting useful for access/content/header/body filter style policies
- provide a stable native bridge instead of pushing logic into ad hoc modules

Why first:

- biggest OpenResty-equivalent gap now
- multiplies the value of existing modules
- enables fast policy/prototype work without adding a second scripting ecosystem

### 2. Shared dict / key-value module

Goal:

- provide cheap worker/shared state for counters, flags, caches, sticky keys, sessions, feature gates

Why next:

- required for serious programmable edge behavior
- pairs naturally with njs hooks
- useful for WAF, ratelimit, canary, auth, and circuit breaker logic

### 3. Upstream balancer / policy module

Goal:

- dynamic backend selection
- retry/failover policy
- weighted routing
- sticky-ish policies and metadata-aware balancing

Why next:

- strong commercial-nginx value
- complements `consul`, `healthcheck`, `canary`, and `circuit-breaker`

### 4. Subrequest / internal fetch composition module

Goal:

- enable internal request composition for auth, enrichment, policy checks, and gateway chaining

Why:

- very high leverage for OpenResty-style app composition
- useful for authz, service discovery, and edge orchestration

### 5. Programmable cache / cache policy module

Goal:

- richer cache keys
- purge controls
- stale policy
- policy-driven cache behavior

Why:

- major gateway/commercial feature area
- more substantial than `cache-tags` alone

### 6. Geo / IP intelligence module

Goal:

- country / ASN / IP intelligence lookups
- tagging for routing, WAF, and access policy

Why:

- useful for both gateway and security stacks
- integrates naturally with WAF and traffic modules

### 7. Policy / authz engine module

Goal:

- centralized authorization and policy evaluation
- pair with JWT/OIDC and subrequests

Why:

- important for API gateway and zero-trust scenarios
- can be native, njs-backed, or hybrid

### 8. Stream/TCP policy modules

Goal:

- extend beyond HTTP into stream-level traffic control and observability

Why:

- necessary for real commercial-nginx parity ambitions
- should come after the HTTP programmable platform is stronger

## Suggested build order

If choosing the most pragmatic next three:

1. **HTTP njs hook module**
2. **shared dict / key-value module**
3. **upstream balancer / policy module**

This sequence gives the best compound payoff:

- programmable edge behavior
- shared state
- dynamic traffic policy

Together, those move Nginz much closer to both OpenResty-style flexibility and commercial-nginx-style gateway strength.

## Milestone 2

Milestone 2 turns the current roadmap analysis into a concrete scaffold-and-design pass for the next native platform modules.

### Sprint 1 - upstream foundation

1. **Upstream balancer + sticky scaffold**
   - native Zig module scaffolded in-tree
   - directive surface and README design documented
   - positioned as the peer-lifecycle foundation for later dynamic upstream work

2. **Dynamic upstreams scaffold**
   - separate module from balancer work
   - placeholder API surface and design documented
   - explicitly dependent on the upstream balancer foundation rather than treated as parallel first implementation work

### Sprint 2 - coordination and cache control

3. **Worker event bus scaffold**
   - native shared-memory/event primitive planned for cross-worker signaling
   - intended to support njs integration, cache invalidation fanout, and runtime coordination

4. **Selective cache-purge API scaffold**
   - operator-facing cache invalidation surface
   - positioned as complementary to `cache-tags`, not a replacement for it

### Existing module scope adjustment

5. **Healthcheck roadmap update**
   - active HTTP checks already exist and should be treated as implemented scope
   - the next milestone work is upstream-keyed health state, peer marking, and later slow-start/recovery behavior

### Milestone 2 exclusions

- **VTS** remains deferred for now because `prometheus` already covers most immediate observability needs.
- **REST runtime API** remains an **njs/productization** target, not a new Zig module in this milestone.

### Milestone 2 deliverable shape

The goal of this milestone is not full feature completion. The goal is to land:

- repo-consistent module directories under `src/modules/`
- detailed README designs and directive plans
- skeleton Zig modules wired into build/package/module registration paths
- a corrected healthcheck roadmap that reflects active checks already being present

## What to avoid

- do **not** start a parallel Lua ecosystem
- do **not** add modules that duplicate built-in nginx controls without clear product value
- do **not** prioritize isolated feature modules over platform-enabling modules now

## Near-term heuristic

For the next module choice, prefer modules that satisfy at least two of these:

- unlock other modules
- expose reusable platform primitives
- improve gateway programmability
- improve traffic control depth
- close a recognizable commercial nginx / OpenResty gap

## Detailed discussion

### njs / QuickJS platform work

This needs a clarification.

Nginz already builds in **njs** with a **QuickJS** engine path. That means the project does **not** need a second scripting ecosystem, and it should not spend roadmap energy inventing a Lua-equivalent runtime story from scratch.

The practical gap is not “how do we add scripting?” The practical gap is:

- how do we make the existing **njs + QuickJS** path a **first-class nginz feature**,
- how do we package and test it well,
- and how do we expose nginz-native capabilities to it cleanly.

#### What njs already gives us

The existing nginx njs surface is already substantial:

- HTTP request/response objects
- body and header filter hooks
- subrequests
- `ngx.fetch()`
- variables access
- timers
- filesystem helpers
- `ngx.shared`
- stream session APIs
- periodic handlers

So the roadmap should **assume these primitives exist** and avoid duplicating them in another module.

#### What nginz still needs around njs

The missing work is mostly platformization and integration:

1. **First-class packaging and documentation**
   - clear setup story
   - example configs and scripts
   - install/package flow
   - explicit support matrix for HTTP and stream usage

2. **Strong integration testing**
   - checked-in njs examples
   - Bun/integration coverage for request handlers, filters, subrequests, shared dict usage, and fetch flows
   - confidence that the built-in njs story is stable across nginz releases

3. **Native-to-JS bridge design**
   - expose nginz-native module capabilities to the scripting layer in a deliberate way
   - especially where raw nginx/njs primitives are too low-level or awkward

4. **Operational developer experience**
   - logging/debugging guidance
   - conventions for file layout and deployment
   - QuickJS/njs compatibility notes
   - performance and safety guidance for edge scripting

#### The pragmatic first target

So the revised “first target” is:

> **Make njs a first-class nginz platform feature.**

That means:

- no new scripting language runtime
- no Lua detour
- no duplicate programmable surface

Instead, it means making the existing njs path feel like a supported product capability rather than an embedded component hidden in the build.

#### What should follow after that

Once njs is productized properly, the next modules should focus on the places where native Zig modules and scripting can complement each other:

- upstream/balancer policy
- geo/IP intelligence
- policy/authz
- programmable cache behavior
- stream/TCP policy modules

Those are stronger roadmap targets than “build another scripting module,” because they produce platform primitives that njs can orchestrate rather than compete with.

### Candidate njs-first modules

If nginz wants an OpenResty-like programmable ecosystem around the existing njs+QuickJS runtime, the next step is not a new runtime. The next step is to implement a few **real modules or module packs in njs** and let that shape the platform boundary.

Good candidates:

#### 1. Response templating / lightweight rendering module

Use njs for:

- HTML / text / JSON templating
- edge-rendered fragments
- lightweight dynamic responses

Why this is a good fit:

- content logic is script-friendly
- low-risk compared with deep request-processing engines
- easy to demonstrate and package

#### 2. Policy / authorization module

Use njs for:

- path / method / header policy logic
- JWT / OIDC claim-to-policy decisions
- custom access decisions and response shaping

Why this is a good fit:

- heavy on branching and business logic
- complements native auth primitives rather than replacing them
- a natural “programmable gateway” use case

#### 3. Edge workflow / orchestration module

Use njs for:

- subrequest orchestration
- `ngx.fetch()`-driven enrichment
- combining internal and external results
- auth / enrichment / routing workflows

Why this is a good fit:

- this is exactly where scripting is strongest
- awkward to keep building as one-off native modules

#### 4. Feature flag / experimentation module

Use njs for:

- rollout decisions
- flag evaluation
- A/B assignment logic
- dynamic request bucketing

Why this is a good fit:

- logic-heavy, not parser-heavy
- pairs well with canary, request id, and shared state

#### 5. Custom response/body transform module

Use njs for:

- response shaping
- field masking
- conditional JSON mutation
- application-specific rewrites

Why this is a good fit:

- similar to common OpenResty scripting patterns
- complements the native `transform` module with custom policy logic

#### 6. Webhook / protocol glue module

Use njs for:

- request signing
- callback verification
- remote API glue
- lightweight protocol adaptation

Why this is a good fit:

- these integrations are often awkward, fast-changing, and script-friendly

### What should stay native

The njs layer should not become the default place for every feature.

Keep these native in Zig:

- WAF core detection and parser engine
- rate limit primitives
- shared-memory data structures
- upstream balancer internals
- deep stream / TCP processing
- performance-critical parsers, scanners, and scoring engines

Reason:

- performance
- memory control
- safety and determinism
- lower-level nginx integration

### Native vs njs boundary

The intended model should be:

- **native Zig modules** provide primitives, engines, and performance-sensitive integrations
- **njs modules** provide orchestration, policy logic, product customization, and glue code

That is the right analogue to the OpenResty ecosystem:

- not “replace the server with scripts”
- but “use scripts as the composition and customization layer on top of strong native primitives”

### Distribution story

An opm-like distribution layer may make sense later, but it should not be the first step.

Recommended order:

1. ship a few good njs-first modules
2. define file layout and packaging conventions
3. define import / dependency conventions
4. only then consider a lightweight registry / installer workflow

The platform value comes from having good reusable modules first, not from building a package manager before there is an ecosystem worth packaging.

## Whole-Module Engineering Audit — 2026-07-12

### Scope and confidence

This pass reviewed all 26 directories under `src/modules`, from the small synchronous modules through the shared-memory, asynchronous upstream, cryptographic, and database modules. The baseline revision was `ca4841d` (`zones`), whose fix establishes an important rule: an `ngx_shm_zone_t *` stored in a process global is a descriptor owned by one nginx configuration cycle, not permanent module-owned state. Every active cycle must register/rebind its zones, and removing a directive must clear or replace every cycle-owned global reference.

`zig build test` passes. The full `bun test` run reports 1,129 passing and four failing tests: the real Redis and PostgreSQL container suites cannot start because their named containers are absent, while two njs combo-subrequest cases fail even in an isolated rerun (duplicate INCR side effect and a connection reset). Passing happy-path tests do not discharge the findings below, which require capacity exhaustion, configuration removal on reload, oversized/malicious upstream data, TLS failure, client abort, or concurrent cross-worker mutation. Each module README contains the detailed verdict and required proof.

### Severity and scheduling decision

- **S0 — release blocker:** memory-safety/lifetime defects, authentication or PKI transport bypass, or deterministic cross-policy/cross-backend state aliasing. Fix and add a regression proof before feature releases.
- **S1 — high:** bounded-input, policy-isolation, capacity, failure-mode, or availability defects that can deny service or weaken a control under realistic stress. Fix immediately after S0, before performance work.
- **S2 — medium:** contention, avoidable allocation/copying, and observability gaps where correctness is preserved. Optimize only after S0/S1 invariants are proven.
- **S3 — low/feature:** protocol breadth, richer syntax, and product gaps. Schedule last.

This ordering is deliberate: **robustness first, performance second, feature gaps last**. A fast shared-memory primitive with an unclear owner, scope, capacity failure, or reload lifetime is not acceptable foundation work.

### Audit disposition by module (easy to hard)

| Module | Decision | Principal issue or proof |
|---|---|---|
| `hello` | pass / S3 cleanup | synchronous request-pool-only code; improve response metadata |
| `canary` | S1 fixed | checked entropy, strict percentage parsing, explicit zero override |
| `requestid` | S1 fixed | checked entropy and bounded visible-ASCII propagated IDs |
| `transform` | S1 buffering fixed | known-length 1 MiB default bound, consumed memory/file buffers, exact JSON media type; streaming remains deferred |
| `prometheus` | pass, then S2 | reload-safe shared zone; per-request global mutex contention |
| `circuit-breaker` | S0 fixed / S1 | saturation fails closed without aliasing; telemetry and half-open admission remain |
| `cache-tags` | S1 integrity fixed | bounds/capacity reject with warning; counters/reload pressure remain |
| `ratelimit` | S1 capacity fixed | live windows never evicted; collision identity/metrics remain |
| `graphql` | S1 heuristic fixed | bounded body/temp-file policy plus fail-closed fragments; a real parser/complexity model remains deferred |
| `jsonschema` | S1 semantics fixed | unsupported vocabulary rejects config; bounded body/temp-file and exact JSON media policy added |
| `echoz` | S0 fixed | lifetime-ordered null checks plus worker-survival regression |
| `worker-events` | S0 fixed / S1 | cycle registry prevents stale/last-zone routing; explicit named native binding remains |
| `cache-purge` | S1 partial | hard cache-tags dependency and safe event lifetime; named binding/ack remains |
| `consul` | S0 fixed / S1 | checked pool builders and complete bounded framing; chunked support deferred |
| `redis` | S0 fixed / S1 | bounded RESP/JSON handling; larger incremental streaming deferred |
| `wechatpay` | S0 fixed / S1 | verified TLS plus shared freshness/replay window; capacity/body bounds remain |
| `oidc` | S0 fixed / S1 | verified HTTPS token/discovery/JWKS and bounds; evented fetch/TLS negatives remain |
| `jwt` | S0 fixed | exact key algorithm and strict multi-key `kid` selection enforced |
| `nftset` | pass with S1 | shared zones are cycle-safe; synchronous Netlink blocks request workers |
| `healthcheck` | S0 fixed / S1 | cycle globals fully reset; verified, event-driven probe I/O remains |
| `upstream-balancer` | S0 fixed / proof | idempotent request cleanup and init-failure unpin added; stress proof remains |
| `dynamic-upstreams` | S0 fixed / proof | traversals pin snapshots and drain readers lock; stress/reload proof remains |
| `waf` | S1 isolation fixed | policy-scoped reputation prevents cross-location contamination; capacity/reload/multi-worker proof remains |
| `acme` | S0 transport fixed / S1 | verified TLS, HTTPS default, and explicit private-CA live issuance fixed; negative TLS and capacity behavior need proof |
| `njs` | S0 cleared / soak | composition passes 17/17 and 170/170 repeated after Redis/pgrest fixes |
| `pgrest` | S0 fixed / S1 | per-worker pools keyed by backend and limit; capacity/teardown proof remains |

### S0 fix program

#### 1. Stop worker corruption and unsafe parsing

Fix `echoz`, `consul`, and `redis` first because they have direct worker-safety failure paths. Introduce checked builders/parsers with explicit maximums and controlled HTTP errors. Verification must include boundary-minus-one/boundary/boundary-plus-one, integer overflow, fragmented input, temp-file bodies where applicable, malformed peer data, and a follow-up request proving the worker survived.

#### 2. Restore authentication and PKI transport guarantees

Enable CA and hostname verification by default in `oidc`, `acme`, and `wechatpay`; insecure test trust must require explicit test-only configuration. Enforce WeChat Pay timestamp/replay policy. In `jwt`, require exact algorithm/key matching and a strict `kid` policy. Negative tests must cover untrusted CA, hostname mismatch, expired/not-yet-valid certificate, algorithm substitution, wrong curve/key type, missing/unknown `kid`, and replay.

#### 3. Make scope, capacity, and reload ownership explicit

- `circuit-breaker`: never return another key's entry on exhaustion; use a keyed store or fail conservatively with saturation telemetry.
- `worker-events`: remove the last-created default-zone dependency; consumers bind a named zone in current-cycle configuration.
- `healthcheck`: move service-probe/event settings into cycle configuration or reset/copy all globals in preconfiguration; no pointer into a retired pool may reach a worker timer.
- `pgrest`: create per-worker pools keyed by backend/configuration identity rather than a singleton.

Required reload matrix for every module owning cycle state: unchanged config, changed value, added directive, removed directive, failed reload followed by continued old-worker service, repeated successful reloads, and graceful old-worker exit.

#### 4. Close dynamic peer lifetime races

Treat `dynamic-upstreams` and `upstream-balancer` as one correctness unit. Every snapshot traversal must pin a generation; every pin must have an idempotent request-pool cleanup backstop; drain state must be immutable/versioned or read under synchronization. Stress proof must run simultaneous traffic, PUT/PATCH/drain/undrain, retries, client aborts, no-eligible-peer cases, reloads, and slab pressure while asserting that retired generations are reclaimed.

#### 5. Diagnose the njs composition crash and duplicate side effect

Run `tests/njs/combo-subrequest.test.js` with preserved nginx logs, worker exit status, and core/sanitizer evidence. Determine whether a subrequest is being executed twice, a Redis response is being replayed, or pgrest/njs request finalization is corrupting the parent lifecycle. The acceptance proof is deterministic single execution of non-idempotent subrequests, no connection reset, and repeated multi-worker runs under the same composition graph.

### Shared-memory proof obligations

No SHM module is considered complete until its README/tests answer all of these:

1. **Owner/tag:** which module tag owns the zone, and can another module safely retrieve it?
2. **Cycle binding:** where is the current cycle's descriptor registered and rebound? What happens when configuration removes it?
3. **Data lifetime:** which bytes live in slab memory, cycle pools, request pools, worker globals, or stack storage?
4. **Scope key:** are entries global, server-, location-, upstream-, policy-, or tenant-scoped? Is that scope encoded in the key rather than implied by call site?
5. **Synchronization:** which lock/atomic protocol protects every field and compound invariant? Release/acquire on a count does not legalize concurrent non-atomic mutation of the entries it counts.
6. **Capacity:** what happens at full capacity? Never alias an unrelated key, silently reset a security budget, or truncate identity.
7. **Failure mode:** does allocation/lookup/lock/dependency failure fail open, fail closed, reject configuration, or return an operational error? The choice must be explicit and observable.
8. **Reload proof:** do unchanged/changed/removed zones preserve only intended data, with no old descriptor or config-pool pointer retained?
9. **Cross-worker proof:** do at least two workers observe the same committed state without half-written entries or stale local caches?
10. **Observability:** expose saturation, eviction, truncation, dropped events, allocation failure, and last error without requiring debug logs.

### S1 robustness program

After S0 is green:

1. Bound body/filter/parser work in `transform`, `graphql`, `jsonschema`, and WAF; define temp-file and unsupported-syntax behavior.
2. Make WAF reputation scope explicit and test conflicting location policies.
3. Make cache-tags identities non-truncating and cache-purge dependencies/physical invalidation semantics honest.
4. Define conservative capacity policy for ratelimit and add saturation metrics.
5. Make canary/requestid entropy and configuration failures explicit.
6. Bound nftset's synchronous Netlink latency or move it off the request path.
7. Turn silent configured-resource omissions (healthcheck caps, optional native dependencies) into config errors or explicit degraded states.

### S2 performance program

Only after the robustness suite passes:

- replace Prometheus request-path mutex serialization with documented atomic/snapshot semantics;
- reduce WAF and nftset lock hold times without weakening compound invariants;
- make transform/Consul/Redis/pgrest response processing streaming or bounded-chunk where semantics allow;
- shard or index fixed shared tables only after scope/capacity behavior is correct;
- benchmark pgrest per-backend pools and serializers after pool isolation, not before;
- benchmark dynamic peer selection under generation churn and verify reclamation counters alongside latency.

Performance acceptance must include correctness counters (drops, evictions, active/retired generations, pool ownership), not throughput alone.

### S3 feature decisions

Defer new rule syntax, new GraphQL/JSON Schema vocabulary, additional Redis/Consul operations, broader JWT algorithms, richer ACME automation, and new native modules until S0 and S1 are closed. The existing njs platform remains the preferred place for fast-changing orchestration and glue. Feature work may proceed only when it does not expand an unaudited lifetime, parser, or shared-state surface.
