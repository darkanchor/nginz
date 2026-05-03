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
