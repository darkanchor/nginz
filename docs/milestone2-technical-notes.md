### Gaps
Here is the clean mapping, one by one.

**1. `upstream-balancer`**
Stock nginx gap it fills:
stock nginx has built-in balancing methods, but it does not give you the exact sticky-routing behavior this repo wants: cookie-based or header-based affinity with explicit fallback semantics and a module-owned policy layer.

What stock nginx already has:
- round robin
- weighted round robin
- `least_conn`
- `ip_hash`
- `hash` / `hash ... consistent`

What is still missing:
- sticky by request cookie
- sticky by arbitrary request header
- explicit `fallback next` vs `fallback off`
- a native place to combine affinity with future health and dynamic snapshot logic

So this module fills the “custom peer selection policy” gap.

**2. `dynamic-upstreams`**
Stock nginx gap it fills:
changing upstream membership at runtime without reload.

What stock nginx already has:
- static upstream blocks from config
- optional DNS re-resolution in some cases
- upstream zones/shared state in certain builds and modes

What is still missing:
- a first-class control API to inspect and replace upstream peers live
- atomic snapshot replacement of peer sets
- generation/versioned runtime peer state
- a clean operator workflow for add/remove/replace backends

So this module fills the “runtime upstream reconfiguration” gap.

**3. `healthcheck`**
Stock nginx gap it fills:
active readiness/health state that is shared across workers, plus a path toward upstream health-aware routing.

What stock nginx already has:
- passive upstream failure counters like `max_fails` / `fail_timeout`
- basic process liveness from “nginx is up”
- no rich built-in JSON health/readiness surface

What is still missing:
- `/health`, `/ready`, `/healthz` style endpoints with shared state
- active periodic HTTP probes with thresholds
- one shared readiness view across workers
- future peer-aware health input that can feed balancer decisions

So this module fills the “active health and readiness reporting” gap, and later the “health-aware upstream control” gap.

**4. `worker-events`**
Stock nginx gap it fills:
cross-worker signaling.

What stock nginx already has:
- workers
- shared memory primitives
- timers and events

What is still missing:
- a reusable event bus primitive for “worker A needs worker B/C/D to notice something changed”
- generation tracking for missed events
- dropped-event accounting
- a small operational publish/inspect API

Without this, modules often fall back to polling or ad hoc shared-state checks.

So this module fills the “cross-worker coordination primitive” gap.

**5. `cache-purge`**
Stock nginx gap it fills:
targeted operator-driven cache invalidation through an explicit API.

What stock nginx already has:
- proxy cache
- coarse purge patterns in some ecosystems or builds
- general cache controls

What is still missing:
- a clean JSON control endpoint for targeted invalidation
- exact/prefix/tag-oriented invalidation semantics
- operator-visible result reporting
- a module-level contract with cache metadata instead of external glue

So this module fills the “selective cache invalidation control plane” gap.

A concise before/after view:

- `upstream-balancer`: from built-in fixed algorithms to programmable sticky selection
- `dynamic-upstreams`: from static upstream config to live peer-set replacement
- `healthcheck`: from basic passive failure behavior to active shared readiness state
- `worker-events`: from no reusable worker fanout primitive to cross-worker event signaling
- `cache-purge`: from broad/coarse cache handling to targeted purge API

If you want, I can turn this into a matrix with columns:
`module | stock nginx already has | missing gap | why this repo splits it this way`.

### Sequence

From easiest to hardest, and taking the documented dependencies seriously, I’d implement them in this order:

1. `healthcheck`
It is already the furthest along. The current scope is real and working, so the remaining work is mostly expansion: upstream-keyed health state, peer marking, and recovery behavior. That is still nontrivial, but it is much less foundational than the others because it already stands on its own.

2. `worker-events`
As designed, this is a small primitive with a tight scope: shared-memory ring, publish, inspect, dropped-event accounting. It is tricky because of concurrency, but it has relatively few moving parts and does not need to understand routing, cache internals, or upstream mutation semantics.

3. `upstream-balancer`
This is the first truly sharp-edge module. It owns nginx upstream peer-selection callbacks, which is deep internal territory. But its scope is still narrower than `dynamic-upstreams`: first get callback ownership and sticky selection right against a fixed peer set.

4. `cache-purge`
This looks simpler from the outside because it is “just an API,” but it depends on a clean metadata contract with `cache-tags`, and possibly later benefits from `worker-events` fanout. Its difficulty is less about nginx internals and more about building correct, bounded, shared invalidation semantics. I’d still put it after `upstream-balancer` because the balancer is a harder platform dependency for other traffic modules, while purge can stay operationally isolated.

5. `dynamic-upstreams`
This should be last. The README basically says so. It depends on the upstream-balancer foundation and its peer identity contract. It also wants snapshot generation, atomic replacement, multi-worker visibility, and eventually health-aware behavior. This is where memory lifetime, worker coordination, and routing correctness all collide.

If you want the dependency-aware view rather than just difficulty order, it is:

- `healthcheck` and `worker-events` can be built independently first.
- `upstream-balancer` must land before `dynamic-upstreams`.
- `cache-purge` is independent of balancer work, but cleaner if `worker-events` exists before its later fanout phase.
- `dynamic-upstreams` should wait until `upstream-balancer` is stable, and ideally until the health state contract is clear enough that peer health won’t need a redesign.

So the practical sequence I would use is:

1. `healthcheck`
2. `worker-events`
3. `upstream-balancer`
4. `cache-purge`
5. `dynamic-upstreams`

If the goal is strict platform layering rather than easiest delivery, I’d tighten it slightly to:

1. `healthcheck`
2. `worker-events`
3. `upstream-balancer`
4. `dynamic-upstreams`
5. `cache-purge`

That second order puts the upstream foundation work before the cache control surface, because `dynamic-upstreams` is the bigger architectural blocker.

### After Milestone 2

Stock nginx upstream routing is not only round robin.

Out of the box, nginx already supports a few built-in balancing modes for upstreams, mainly:

- plain round robin: the default
- weighted round robin: via server weights
- `least_conn`
- `ip_hash`
- `hash <key>` and `hash <key> consistent`

It also has failure handling knobs like `max_fails`, `fail_timeout`, backup servers, and retry behavior, but those are not the same thing as a full health-aware or dynamic control-plane system.

What stock nginx does not give you cleanly is the combination this repo is aiming at:

- native sticky routing based on cookie or header, with explicit fallback semantics
- runtime upstream membership changes without reload
- upstream health state that can feed peer selection directly
- cross-worker signaling primitives for coordination
- operator-facing selective cache invalidation APIs

So when these planned sprints land, the step change is not “nginx can load balance now.” It already can. The step change is that `nginz` becomes a more programmable traffic platform.

In practical terms, you would gain:

1. Better affinity behavior
You can pin a client to the same backend using a cookie or header, instead of relying on `ip_hash` or a generic hash directive that may not match your application needs.

2. Runtime backend updates
You can add, remove, or replace upstream peers without a full reload, using snapshot activation rather than static config only.

3. Health-aware routing
Backend health can move from just “reported on an endpoint” to actually influencing whether a peer is selected.

4. Stronger coordination across workers
Modules can propagate cache invalidations, revocations, or state changes without crude polling loops.

5. Operational cache control
You can invalidate targeted cache entries through an explicit API instead of broad purge patterns or external glue.

If the whole roadmap around these modules lands cleanly, the end state is roughly this:

- stock nginx: “serve traffic with static upstream config and some built-in balancing algorithms”
- `nginz` after these sprints: “serve traffic with programmable sticky routing, live upstream reconfiguration, health-aware peer control, cross-worker eventing, and operator APIs around cache and runtime state”

The biggest upgrade is not a new balancing algorithm by itself. It is moving from static load balancing to a controlled runtime traffic system.

A concise before/after view:

- today with stock nginx: good static reverse proxy and load balancer
- after these modules: closer to an application delivery platform with dynamic backends, affinity, health state, and control APIs

If useful, I can map each planned module to the exact stock-nginx gap it fills, one by one.

### Technical briefs

Yes, in principle these sprints can be done on stock nginx without patching upstream core. The important distinction is:

- nginx exposes enough module hooks to *wrap and steer* upstream selection
- nginx does **not** expose a polished public SDK for all of this
- some of what you would use, especially for dynamic upstreams, is effectively internal nginx API, so it is possible but sharp

The core upstream extension points are in [ngx_http_upstream.h](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/ngx_http_upstream.h) and the round-robin peer implementation in [ngx_http_upstream_round_robin.h](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/ngx_http_upstream_round_robin.h).

What nginx exposes for upstream modules is basically this:

1. Upstream init at config time  
`ngx_http_upstream_peer_t` on `ngx_http_upstream_srv_conf_t` gives you:
- `init_upstream(cf, us)`
- `init(r, us)`
- `data`

This is the hook where a module can take over an `upstream {}` block’s peer-selection setup.

2. Per-request peer selection  
After `init(r, us)`, nginx uses `r->upstream->peer`, whose callbacks include:
- `get`
- `free`
- `set_session`
- `save_session`
- optionally `notify`

This is the real balancer surface. Your module can wrap stock round robin instead of replacing nginx core.

3. Stock round-robin helpers  
Nginx already exports helpers like:
- `ngx_http_upstream_init_round_robin`
- `ngx_http_upstream_init_round_robin_peer`
- `ngx_http_upstream_get_round_robin_peer`
- `ngx_http_upstream_free_round_robin_peer`

Those are declared in [ngx_http_upstream_round_robin.h](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/ngx_http_upstream_round_robin.h). So a custom module can reuse nginx’s built-in peer table and fallback behavior.

4. Actual example in nginx source  
The bundled sticky module shows the exact pattern in [ngx_http_upstream_sticky_module.c](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/modules/ngx_http_upstream_sticky_module.c):
- save original `init_upstream`
- call it
- replace `us->peer.init`
- in request init, save original `u->peer.get/free/...`
- replace them with wrapper callbacks

That is the blueprint for `upstream-balancer`.

So module by module:

`upstream-balancer`
- Yes, this is exactly what those callbacks are for.
- It can install `init_upstream` / `init`, then wrap `get/free/set_session/save_session/notify`.
- Sticky cookie/header affinity, explicit fallback, and health-aware peer avoidance can all live here.
- No upstream core patch needed.

`healthcheck`
- Current health endpoints do not depend on upstream core at all.
- The future “mark bad peers unavailable” part can still avoid patching core if the balancer callback consults shared health state before choosing a peer.
- In other words, healthcheck does not have to mutate nginx core behavior directly; it can feed state into the custom balancer.

`dynamic-upstreams`
- This is the hardest one.
- It still can be done without patching core, but not because nginx gives you a neat “replace peers” callback.
- The realistic paths are:
  - maintain your own module-owned snapshot structure and have the balancer read from that
  - or manipulate nginx upstream peer structures and shared upstream-zone state very carefully
- Nginx does expose the peer structs and upstream server confs in headers, plus locking/refcount helpers in round-robin headers when upstream zones are enabled, but this is much closer to internal surgery than a clean public API.
- So: possible without patching, yes. Clean and low-risk, no.

`worker-events`
- Not upstream-core related.
- Uses normal nginx module surfaces: location handler, shared memory zone, timer/event loop, locks/atomics.
- No upstream callbacks involved.

`cache-purge`
- Also not upstream-core related.
- Uses location/content handler plus shared metadata structures.
- No upstream callbacks involved.

So the exact upstream callback surface that matters for the traffic sprints is:

- config-time: `uscf->peer.init_upstream`
- request-time setup: `uscf->peer.init`
- request-time peer ops on `r->upstream->peer`:
  - `get`
  - `free`
  - `set_session`
  - `save_session`
  - `notify` if present

That is enough for:
- sticky routing
- fallback behavior
- health-aware peer skipping
- custom peer identity handling
- reading from module-owned dynamic snapshots

What it is not enough for by itself is a clean first-class runtime upstream membership API. That part is why `dynamic-upstreams` is hard: nginx exposes the structures, but not a pleasant stable contract for mutating them live.

So the short answer is:

- `upstream-balancer`: yes, directly via official upstream callback hooks
- `healthcheck`: yes, mostly outside upstream core; future peer effects flow through balancer callbacks
- `dynamic-upstreams`: yes, but by working against nginx internals and/or a module-owned peer snapshot model
- `worker-events` and `cache-purge`: unrelated to upstream core

If useful, I can draw the exact callback chain for one request:
`init_upstream -> init_peer -> get_peer -> connect -> free_peer`,
and show where sticky, health, and dynamic snapshot logic would slot in.

### One request

For one proxied request, the upstream path in nginx looks like this:

```text
client request
  ->
location / proxy_pass
  ->
ngx_http_upstream machinery starts
  ->
upstream srv conf chosen (`ngx_http_upstream_srv_conf_t`)
  ->
config-time upstream init already happened earlier:
  `uscf->peer.init_upstream(cf, us)`
  default: `ngx_http_upstream_init_round_robin`
  our hook point: `upstream-balancer`
  ->
request-time peer init:
  `uscf->peer.init(r, us)`
  default: round-robin peer init
  our hook point: `upstream-balancer`
  ->
request peer callbacks installed on `r->upstream->peer`
  -
  `get(pc, data)`          choose peer
  `free(pc, data, state)`  release/report result
  `set_session(pc, data)`  restore TLS session if used
  `save_session(pc, data)` save TLS session if used
  `notify(...)`            optional upstream event notification
  ->
`get()` runs
  default: stock nginx picks peer
  with our module: `upstream-balancer` can:
  - read sticky cookie/header
  - consult health state
  - consult dynamic snapshot
  - fallback to stock peer choice
  ->
connect to selected backend
  ->
send request / receive response
  ->
`free()` runs
  stock nginx updates peer failure/load accounting
  with our module: `upstream-balancer` can observe success/failure and preserve wrapper behavior
  ->
response returned to client
```

Now mark the planned modules on that chain:

```text
1. Request enters nginx
   `healthcheck`
   - passive counters can observe request success/failure
   - `/health` `/ready` endpoints are outside the upstream callback path

2. Upstream config was prepared earlier
   `upstream-balancer`
   - hooks `uscf->peer.init_upstream`
   - wraps stock upstream initialization

3. Request starts upstream peer setup
   `upstream-balancer`
   - hooks `uscf->peer.init`
   - swaps in wrapped `get/free/set_session/save_session/notify`

4. Peer selection happens in `get()`
   `upstream-balancer`
   - sticky cookie/header lookup
   - fallback policy
   - future health-aware peer filtering
   - future dynamic peer snapshot lookup

   `healthcheck`
   - future role: provide shared peer-health input consumed here

   `dynamic-upstreams`
   - future role: provide current active peer snapshot consumed here

5. Backend request runs
   stock nginx connection/request processing

6. Peer release happens in `free()`
   `upstream-balancer`
   - can preserve stock accounting and attach affinity-related behavior

7. Response goes back
   `cache-tags` / `cache-purge`
   - not part of upstream peer callback chain itself
   - cache-related modules sit on cache/control/filter paths, not on `peer.get/free`

8. Cross-worker coordination
   `worker-events`
   - not in the request's upstream callback chain
   - future side-channel for broadcasting:
     - cache invalidations
     - health transitions
     - dynamic-upstream state changes
```

The important structural point is this:

- `upstream-balancer` sits directly inside the peer callback chain.
- `dynamic-upstreams` and future peer-aware `healthcheck` feed data into that chain.
- `worker-events` is beside the chain, not inside it.
- `cache-purge` is an operator/control endpoint, not part of peer selection.

If you want the same diagram with actual function names from stock nginx and the wrapper points labeled against the source files, I can lay that out next.

Here is the concrete callback chain for one proxied request, tied to the stock nginx source and marked with where the planned modules attach.

**Source Hooks**

Nginx exposes the upstream hook surface here:

- `init_upstream` and `init` on `ngx_http_upstream_peer_t` in [ngx_http_upstream.h](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/ngx_http_upstream.h:85)
- config-time selection of `init_upstream` or stock round robin in [ngx_http_upstream.c](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/ngx_http_upstream.c:7264)
- stock round-robin peer helpers in [ngx_http_upstream_round_robin.h](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/ngx_http_upstream_round_robin.h:201)

The bundled sticky module shows the exact wrapping pattern:

- wrap upstream init in [ngx_http_upstream_sticky_module.c](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/modules/ngx_http_upstream_sticky_module.c:223)
- wrap request peer init in [ngx_http_upstream_sticky_module.c](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/modules/ngx_http_upstream_sticky_module.c:241)
- wrap `get_peer` in [ngx_http_upstream_sticky_module.c](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/modules/ngx_http_upstream_sticky_module.c:340)
- wrap `free_peer` in [ngx_http_upstream_sticky_module.c](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/modules/ngx_http_upstream_sticky_module.c:406)

**One Request**

```text
1. nginx loads config
   ->
   for each upstream block:
   uscf->peer.init_upstream(cf, us)
   default if unset:
   ngx_http_upstream_init_round_robin

   Source:
   [ngx_http_upstream.c](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/ngx_http_upstream.c:7264)

   Our module:
   upstream-balancer
   - installs its own init_upstream
   - usually calls stock init first, then wraps peer init
```

```text
2. client request hits a proxy_pass location
   ->
   nginx resolves the chosen upstream srv conf
   ->
   request-time upstream peer init runs:
   uscf->peer.init(r, us)

   Hook type defined in:
   [ngx_http_upstream.h](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/ngx_http_upstream.h:87)

   Our module:
   upstream-balancer
   - allocates per-request balancer state
   - saves original peer callbacks
   - replaces r->upstream->peer.get/free/set_session/save_session
```

That is exactly what the sticky module does here:

- save original peer callbacks: [ngx_http_upstream_sticky_module.c](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/modules/ngx_http_upstream_sticky_module.c:265)
- replace them with wrappers: [ngx_http_upstream_sticky_module.c](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/modules/ngx_http_upstream_sticky_module.c:272)

```text
3. nginx needs a backend peer
   ->
   r->upstream->peer.get(pc, data)

   Stock behavior:
   round robin / least_conn / hash family eventually choose a peer

   Our module:
   upstream-balancer
   - read sticky cookie/header
   - map key to peer identity
   - consult fallback policy
   - consult dynamic snapshot
   - consult health state
   - optionally call original stock get_peer as fallback
```

The sticky module’s wrapper shows the pattern:

- derive affinity input
- optionally set a hint
- call original picker
- clear wrapper state
- continue

See [ngx_http_upstream_sticky_module.c](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/modules/ngx_http_upstream_sticky_module.c:340).

**Where other planned modules matter at `get_peer` time**

- `healthcheck`
  - future role: provide shared peer-health state so unhealthy peers can be skipped
  - not by patching upstream core, but by feeding data into `upstream-balancer`

- `dynamic-upstreams`
  - future role: provide the active peer snapshot that `upstream-balancer` selects from
  - this is why its contract depends on balancer peer identity

```text
4. nginx connects to the selected backend
   ->
   optional TLS session hooks:
   r->upstream->peer.set_session(...)
   ...
   r->upstream->peer.save_session(...)

   Our module:
   upstream-balancer
   - usually forwards these through unchanged
```

```text
5. request runs against backend
   ->
   response or failure happens
   ->
   r->upstream->peer.free(pc, data, state)
```

This is where stock nginx updates peer accounting and retry/failure state. Our wrapper can observe the result and still delegate to stock logic. The sticky example does that in [ngx_http_upstream_sticky_module.c](/home/kaiwu/Documents/gitea/nginz/submodules/nginx/src/http/modules/ngx_http_upstream_sticky_module.c:406).

**Where the other modules sit**

These are *not* in the upstream peer callback chain:

- `worker-events`
  - side-channel coordination primitive
  - future use: broadcast “state changed” events across workers

- `cache-purge`
  - control/content endpoint
  - not part of backend peer choice

- `healthcheck` today
  - `/health`, `/ready`, `/healthz` are regular HTTP handlers, outside peer selection
  - only future peer-aware health ties back into `upstream-balancer`

**Short version**

The exact request path is:

```text
config load
-> init_upstream
-> request arrives
-> init_peer
-> get_peer
-> connect/send/recv
-> free_peer
-> response returns
```

The module placement is:

- `upstream-balancer`: directly on `init_upstream`, `init_peer`, `get_peer`, `free_peer`
- `dynamic-upstreams`: feeds peer snapshot data into `upstream-balancer`
- `healthcheck`: feeds future peer health data into `upstream-balancer`
- `worker-events`: outside the chain, for cross-worker notifications
- `cache-purge`: outside the chain, as an operator API

If you want, I can draw the same chain again as a sequence diagram with boxes for `stock nginx`, `upstream-balancer`, `dynamic-upstreams`, and `healthcheck`.

Here is the sequence diagram version.

```text
Client
  |
  | HTTP request
  v
nginx location / proxy_pass
  |
  | uses upstream srv conf selected from config
  v
stock nginx upstream core
  |
  | request-time peer init
  | uscf->peer.init(r, us)
  v
upstream-balancer
  |
  | wrap original callbacks on r->upstream->peer
  | save original get/free/set_session/save_session
  v
stock peer implementation
  |
  | now waiting for peer selection through wrapped callbacks
  v

stock nginx upstream core
  |
  | choose backend
  | r->upstream->peer.get(pc, data)
  v
upstream-balancer
  |
  | read sticky input from request
  | - cookie
  | - header
  |
  | ask health state:
  | "which peers should be avoided?"
  v
healthcheck
  |
  | return shared health view
  | today: mostly instance/probe readiness
  | later: peer-aware health state
  v
upstream-balancer
  |
  | ask dynamic upstream state:
  | "what peer snapshot is active?"
  v
dynamic-upstreams
  |
  | return active generation / peer set
  | later: immutable snapshot chosen at runtime
  v
upstream-balancer
  |
  | decide:
  | - sticky hit -> target peer
  | - sticky miss -> fallback policy
  | - unhealthy peer -> skip or fail
  | - no custom hit -> delegate
  |
  | optional fallback into stock picker
  v
stock peer implementation
  |
  | round robin / least_conn / hash family chooses concrete peer
  v
stock nginx upstream core
  |
  | connect to backend
  | maybe set TLS session
  v
Backend peer
  |
  | response / error
  v
stock nginx upstream core
  |
  | release/report peer result
  | r->upstream->peer.free(pc, data, state)
  v
upstream-balancer
  |
  | observe success/failure
  | preserve sticky bookkeeping if needed
  | forward to original free()
  v
stock peer implementation
  |
  | update peer accounting / retry state
  v
stock nginx upstream core
  |
  | send response to client
  v
Client
```

Now the side-channel modules that are not on the hot request path:

```text
Operator/API caller
  |
  | POST/GET control request
  v
cache-purge
  |
  | invalidate cache metadata / keys
  |
  | optional future fanout:
  v
worker-events
  |
  | publish cross-worker event
  v
other workers / consumers
```

```text
Timer / control action
  |
  v
dynamic-upstreams
  |
  | activate new peer snapshot
  |
  | optional future fanout:
  v
worker-events
  |
  | notify other workers a new generation is live
  v
upstream-balancer on later requests
```

```text
Probe timer
  |
  v
healthcheck
  |
  | update shared health state
  |
  | optional future fanout:
  v
worker-events
  |
  | notify health transition
  v
upstream-balancer on later requests
```

The important engineering boundary is this:

- `stock nginx upstream core` drives the lifecycle
- `upstream-balancer` is the only planned module directly inside peer selection callbacks
- `dynamic-upstreams` and `healthcheck` are state providers to that balancer
- `worker-events` is coordination glue beside the path
- `cache-purge` is an operational API, not a balancer component

So if you collapse it to one line, the real runtime layering is:

```text
stock nginx lifecycle
  -> upstream-balancer policy layer
    -> reads dynamic-upstreams state
    -> reads healthcheck state
    -> may use worker-events indirectly for freshness/coordination
```

And separately:

```text
cache-purge / dynamic-upstreams / healthcheck
  -> may publish operational state changes through worker-events
```

If you want, the next useful step is a second diagram showing just the config-time and worker-time lifecycle:
`master parse -> init_upstream -> worker start -> request init -> get/free -> timer updates shared state`.

Here is the config-time and worker-time lifecycle diagram.

```text
MASTER PROCESS
  |
  | parse nginx config
  |
  | upstream { ... }
  | location /health ...
  | location /dynamic-upstreams ...
  | location /worker-events ...
  | location /cache-purge ...
  v
module directive parsers run
  |
  | upstream-balancer
  | - parse sticky mode
  | - parse fallback mode
  |
  | healthcheck
  | - parse endpoint flags
  | - parse probe target / thresholds
  |
  | dynamic-upstreams
  | - parse control endpoint binding
  | - parse target upstream / source mode
  |
  | worker-events
  | - parse zone / channel / ring size
  |
  | cache-purge
  | - parse zone / match mode / auth mode / max keys
  v
upstream config init phase
  |
  | for each upstream:
  | uscf->peer.init_upstream(cf, us)
  v
stock nginx upstream init
  |
  | default:
  | ngx_http_upstream_init_round_robin
  |
  | or wrapped by:
  v
upstream-balancer
  |
  | call stock upstream init first
  | save original uscf->peer.init
  | replace uscf->peer.init with module wrapper
  v
config completed
  |
  | shared memory zones initialized
  v
shared state becomes available
  |
  | healthcheck shared counters/probe state
  | worker-events ring state
  | future dynamic-upstreams snapshots
  | future cache metadata / purge index
  v
workers fork
```

Now worker-time:

```text
WORKER PROCESS START
  |
  | worker-local startup
  v
timers / shared state roles established
  |
  | healthcheck
  | - one worker owns active probe timer
  | - all workers can read shared readiness state
  |
  | worker-events
  | - all workers can read/write shared ring once implemented
  |
  | dynamic-upstreams
  | - future: all workers read active snapshot generation
  |
  | cache-purge
  | - future: all workers read shared purge metadata
```

Per request:

```text
REQUEST ARRIVES
  |
  | normal location match
  v
branch by location/module type

A) proxy_pass request
   |
   v
   upstream request init
   |
   | uscf->peer.init(r, us)
   v
   upstream-balancer
   |
   | allocate request-local peer wrapper state
   | save original r->upstream->peer callbacks
   | replace get/free/set_session/save_session
   v
   peer selection
   |
   | r->upstream->peer.get(...)
   v
   upstream-balancer
   |
   | inspect request affinity input
   | read current health state
   | read current dynamic snapshot
   | choose peer or delegate to stock picker
   v
   backend I/O
   |
   v
   r->upstream->peer.free(...)
   |
   v
   upstream-balancer -> stock peer free()
   |
   v
   response sent

B) /health or /ready request
   |
   v
   healthcheck handler
   |
   | read shared counters/probe state
   | return JSON status
   v
   response sent

C) /dynamic-upstreams request
   |
   v
   dynamic-upstreams handler
   |
   | read or future-write active snapshot
   | validate replacement before activation
   v
   response sent

D) /worker-events request
   |
   v
   worker-events handler
   |
   | inspect ring or publish event
   v
   response sent

E) /cache-purge request
   |
   v
   cache-purge handler
   |
   | validate request
   | consult purge metadata
   | invalidate matching entries
   v
   response sent
```

Background activity alongside requests:

```text
BACKGROUND TIMERS / STATE CHANGES
  |
  +-> healthcheck probe timer
  |    |
  |    | probe target
  |    | update shared readiness/health state
  |    v
  |    future input to upstream-balancer
  |
  +-> dynamic-upstreams refresh/control action
  |    |
  |    | build new peer snapshot
  |    | validate whole snapshot
  |    | atomically switch active generation
  |    v
  |    future input to upstream-balancer
  |
  +-> worker-events publish
       |
       | append event to shared ring
       | readers inspect later
       v
       optional coordination for other modules
```

The key separation by lifecycle is:

- config time:
  modules parse directives and install hooks
- worker start:
  shared memory and timers become active
- request time:
  `upstream-balancer` is the hot-path policy hook
- background time:
  `healthcheck`, `dynamic-upstreams`, and `worker-events` update shared state that later requests consume

So the most important dependency in lifecycle terms is:

```text
config-time hook installation
  -> request-time balancer wrapper exists
  -> background/shared state providers become useful
  -> later requests consume that state safely
```

That is why `upstream-balancer` is the central runtime join point, even though several other modules are easier to build first.

## Integration Reminder

The module-local work is now in better shape than the milestone-2 integration
story. This section is here as a reminder of the remaining join points between
modules so they do not get lost while individual modules look "done" in
isolation.

### Current module-local status

- `healthcheck` is locally ready for reporting and probing.
- `worker-events` is locally ready as a shared event-ring primitive.
- `cache-purge` is locally ready for exact-match invalidation against the
  current shared `cache-tags` metadata store.

What remains is mostly integration, not standalone feature scaffolding.

### Integration points still pending

#### 1. `healthcheck` -> `upstream-balancer`

This is the most important milestone-2 gap still open.

`healthcheck` already knows how to:

- keep shared readiness state
- probe service-level targets
- probe upstream-level targets
- probe peer targets
- expose health information to endpoints, metrics, and variables

What it still does not do by itself:

- mark nginx upstream peers down
- exclude unhealthy peers from live peer selection
- influence fallback or retry behavior during selection
- coordinate slow-start recovery with actual traffic routing

So the remaining work here is:

- define the peer identity contract shared between `healthcheck` and
  `upstream-balancer`
- decide how balancer selection reads health state safely
- decide what "unhealthy" means for peer exclusion versus degraded routing
- wire slow-start recovery metadata into real peer weighting/eligibility

This is the boundary where health reporting becomes health-aware routing.

#### 2. `healthcheck` -> `worker-events`

This is the transition-fanout gap.

Today `healthcheck` stores shared state and every worker can read that state.
That is already useful, but milestone 2 still expects a way for workers to
notice important health transitions without relying only on later polling or
incidental reads.

The intended shape is narrow:

- `healthcheck` remains the source of truth
- `worker-events` carries "something changed" signals
- consumers react by re-reading shared health state rather than trusting the
  event payload as the truth itself

The remaining work here is:

- define event type names for health transitions
- decide what minimal payload is safe and useful
- publish events only on meaningful transitions, not every probe tick
- document consumer expectations for re-reading shared state

#### 3. `worker-events` -> first real consumer

`worker-events` is now useful as a primitive, but milestone 2 is stronger if
one real module actually consumes it.

Likely first consumers:

- `healthcheck` transition fanout
- later cache invalidation fanout

What is still missing:

- one end-to-end integration that proves a producer emits events and another
  module or worker consumes them correctly
- integration tests that validate the boundary rather than only the event ring
  itself

Until this lands, `worker-events` should be treated as locally complete but not
yet integration-proven.

#### 4. `cache-purge` -> `worker-events` (optional later phase)

This is not required for the current exact-match cache-purge milestone slice.

`cache-purge` is already useful without event fanout because it mutates the
shared purge metadata directly. But if later cache invalidation behavior needs
workers to react faster or trigger follow-on work, `worker-events` is the
intended additive mechanism.

Important constraint:

- do not make `worker-events` a prerequisite for truthful exact invalidation

If this integration lands later, it should be framed as:

- purge metadata mutation remains the source of truth
- emitted events are notifications about the mutation
- consumers re-read shared metadata if they need current state

### Practical conclusion

For milestone 2 planning purposes:

- `healthcheck`, `worker-events`, and `cache-purge` are each locally ready in
  their current narrowed scopes
- the major remaining milestone-2 work is cross-module integration
- the highest-priority integration is `healthcheck` feeding
  `upstream-balancer`
- the next clean integration is `healthcheck` publishing transitions over
  `worker-events`
- `cache-purge` fanout through `worker-events` is useful later, but not a
  blocker for the current exact-match control-plane goal
