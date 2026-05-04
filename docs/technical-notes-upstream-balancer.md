# Technical Notes: Upstream Balancer

Deep-dive implementation plan for the `upstream-balancer` module.

This document is the technical attack plan behind
`src/modules/upstream-balancer-nginx-module/README.md`. It is intentionally
more concrete than the README: it focuses on the nginx callback surface,
runtime state shape, sticky selection rules, and the contract this module must
expose to `dynamic-upstreams`.

The intended setting is:

- `upstream-balancer` is the first module that takes ownership of nginx's
  upstream peer callback surface in Zig
- `dynamic-upstreams` will later replace peer snapshots at runtime
- `healthcheck` may later mark peers unhealthy, but does not own selection
- this module must be correct on its own before any runtime peer mutation is
  layered on top

---

## Mission

`upstream-balancer` has one job: own request-time upstream peer selection in a
small native module without breaking stock nginx behavior.

Its phased mission is:

1. safely insert itself into nginx's upstream callback path
2. preserve stock behavior when sticky routing is effectively inactive
3. implement deterministic sticky selection from cookie or header input
4. define a stable peer identity contract for `dynamic-upstreams`

That means this module is not a discovery system, not a health manager, and
not a control API. It is the selector.

---

## What Makes This Module Hard

The difficulty is not hashing a cookie. The difficulty is owning nginx's sharp
upstream internals without causing regressions.

The risky areas are:

- `upstream {}`-scoped config parsing instead of normal location config
- `init_upstream` and per-request `init` callback interception
- chaining to nginx round-robin behavior when sticky mode is off or misses
- preserving retries, failure accounting, and per-request upstream state
- later compatibility with snapshot replacement from `dynamic-upstreams`

If we hook the callback path incorrectly, proxying breaks even before sticky
mode exists.

---

## Current Scaffold

Today the code in
`src/modules/upstream-balancer-nginx-module/ngx_http_upstream_balancer.zig`
only reserves directives:

- `upstream_balancer_sticky_cookie <name>`
- `upstream_balancer_sticky_header <name>`
- `upstream_balancer_fallback <next|off>`

The current handlers are placeholders. The existing test in
`tests/upstream-balancer/` only proves that:

- config parsing accepts the directive names
- proxy traffic still reaches the backend

One current scaffold mismatch should be fixed as Phase 1 starts:

- `tests/upstream-balancer/nginx.conf` enables both
  `upstream_balancer_sticky_cookie` and `upstream_balancer_sticky_header` in
  the same upstream block

That is acceptable for placeholder acceptance testing, but it conflicts with
the intended real config rule that those modes are mutually exclusive. Phase 1
should split that fixture into separate valid cases and add one explicit
invalid-config test.

So this note is about turning that scaffold into the first real balancer.

---

## Nginx Surface We Need To Own

For HTTP upstream selection, the important nginx structures are:

- `ngx_http_upstream_srv_conf_t`
- `ngx_http_upstream_peer_t`
- `ngx_http_upstream_rr_peers_t`
- `ngx_http_upstream_rr_peer_t`
- `ngx_http_upstream_rr_peer_data_t`
- `ngx_peer_connection_t`

The module must work through nginx's normal upstream callback surface, not by
inventing a parallel routing path.

The key handoff points are:

1. config-time upstream initialization
2. per-request peer initialization
3. request-time `get_peer`
4. request-time `free_peer`

The safest design is not to replace round-robin internals wholesale unless we
have to. Instead, we should wrap the stock round-robin peer data and override
selection only when sticky policy produces a usable peer.

---

## Design Principles

- **Stock-first**: if sticky mode is off, behavior must remain equivalent to
  stock nginx.
- **Request-local state**: all per-request selection state lives in request
  memory, not hidden globals.
- **Deterministic mapping**: the same affinity key and peer generation must
  resolve to the same peer on every worker.
- **Explicit fallback**: miss and invalid-key behavior must be documented and
  test-backed.
- **Selector, not owner**: this module selects peers from a provided peer
  graph; it does not own peer mutation.
- **Generation awareness**: peer identity must be documented in a way
  `dynamic-upstreams` can preserve.

---

## Config Model

The directives live in `upstream {}` context, so the module needs upstream
server configuration, not location configuration.

### Upstream-scoped config shape

Use a module-owned upstream config similar to:

```zig
const StickyMode = enum(c_uint) {
    off = 0,
    cookie = 1,
    header = 2,
};

const FallbackMode = enum(c_uint) {
    next = 0,
    off = 1,
};

const UpstreamBalancerSrvConf = extern struct {
    enabled: ngx_flag_t,
    sticky_mode: StickyMode,
    fallback_mode: FallbackMode,
    key_name: ngx_str_t,

    original_init_upstream: ?*anyopaque,
    original_init_peer: ?*anyopaque,

    // Future integration point for dynamic-upstreams registration.
    peer_source: ?*anyopaque,
};
```

Important ABI note: if this becomes an `extern struct`, keep C-ABI-safe field
types only. Function pointers and typed pointers may need to be stored as
opaque fields and cast at the Zig/C boundary.

### Config rules

These should be enforced at config time:

- `upstream_balancer_sticky_cookie` and
  `upstream_balancer_sticky_header` are mutually exclusive
- if both are absent, sticky mode is `off`
- `upstream_balancer_fallback` accepts only `next` or `off`
- empty cookie/header names are invalid
- repeated definitions in one upstream block should fail unless we explicitly
  choose last-one-wins semantics

### Why upstream-scoped config matters

Sticky policy is a property of the upstream peer set, not the location.

Multiple locations can proxy to the same upstream. If policy were stored at
location scope, peer identity and fallback semantics would become ambiguous.

---

## Callback Ownership Plan

### Phase 1 goal

Install the module into the upstream callback chain without changing routing
behavior when sticky mode is effectively inactive.

### Config-time hook

At upstream config time:

1. fetch this module's upstream srv conf
2. fetch `ngx_http_upstream_srv_conf_t`
3. save the current `uscf->peer.init_upstream`
4. replace it with `upstream_balancer_init_upstream`

That wrapper should:

1. call the original `init_upstream` first, which should normally build
   round-robin peer state
2. save the resulting `uscf->peer.init`
3. replace `uscf->peer.init` with `upstream_balancer_init_peer`
4. leave `uscf->peer.data` intact unless later dynamic integration requires
   a wrapped data structure

This ordering matters. We want nginx's normal peer graph to exist before we
wrap request-time behavior.

### Per-request hook

`upstream_balancer_init_peer(r, us)` should:

1. call the original `init_peer`
2. get the resulting request peer data from `r->upstream->peer.data`
3. allocate module-owned request context from `r->pool`
4. store:
   - module config pointer
   - original `get` / `free`
   - original peer data
   - peer graph pointer for selection
5. replace `r->upstream->peer.get` / `free` with module callbacks
6. replace `r->upstream->peer.data` with module request context

This is the safest wrapper shape because:

- nginx and round-robin still initialize normal request state first
- our module can delegate to the original implementation when needed
- `free_peer` can still preserve nginx failure accounting by calling through

---

## Request Context

The per-request context is the real heart of the module.

Use something like:

```zig
const BalancerRequestCtx = extern struct {
    conf: ?*anyopaque,              // cast to module srv conf
    original_data: ?*anyopaque,     // original round-robin peer data
    original_get: ?*anyopaque,      // original get_peer fn
    original_free: ?*anyopaque,     // original free_peer fn

    peers: [*c]ngx_http_upstream_rr_peers_t,
    current: [*c]ngx_http_upstream_rr_peer_t,

    sticky_attempted: ngx_flag_t,
    sticky_hit: ngx_flag_t,
    fallback_taken: ngx_flag_t,
    selected_peer_index: ngx_uint_t,
};
```

This should be request-local only.

Do not put request-time selection state into shared memory. Shared memory is
for peer graphs or metrics later, not one request's affinity decision.

---

## Sticky Key Extraction

The first useful version should support exactly two extraction modes.

### Cookie mode

Input:

- read existing request cookie by configured name

Rules:

- cookie name matching is exact
- empty cookie value is a miss
- malformed cookie header should degrade to a miss, not crash parsing
- module does not set or rotate cookies in version 1

### Header mode

Input:

- read request header by configured name

Rules:

- header lookup should be case-insensitive in the HTTP sense
- missing header is a miss
- empty header value is a miss

### Normalization

The first version should keep normalization deliberately narrow:

- use raw bytes of the cookie/header value
- do not trim or canonicalize beyond what nginx header/cookie parsing already
  provides
- document that `"abc"` and `"abc "` are different keys if they reach the
  module differently

That keeps behavior deterministic and easy to audit.

---

## Affinity Mapping

### Required property

The same key must resolve to the same peer set position for every worker in
the same generation.

### First mapping rule

The initial mapping can be:

`crc32(key) % eligible_peer_count`

That is enough for version 1 because:

- it is deterministic
- it is cheap
- every worker can compute it independently

The exact hash must be named in the README once implemented. Changing it later
is a behavior change, not an internal refactor.

### Eligible peer set

The first mapping decision is not just `peer_count`. We need a defined notion
of which peers are candidates.

Version 1 should limit itself to the primary peer chain and exclude peers
that are:

- statically marked `down`
- absent from the active peer graph

Do not try to invent special sticky semantics for backup peers in the first
version. Either ignore them for sticky mapping or document explicit later
support.

### Selection by peer index

Once the module has an eligible peer list for the current generation:

1. count peers in deterministic iteration order
2. compute hash modulo eligible count
3. walk to that index
4. select that peer

Deterministic iteration order must match the order nginx and
`dynamic-upstreams` agree on for the generation.

---

## Fallback Semantics

The fallback contract must be simple and exact.

### `upstream_balancer_fallback next`

If sticky selection cannot produce a usable peer, delegate to the original
nginx/round-robin `get_peer()` for this request.

Miss conditions include:

- sticky key absent
- sticky key empty
- sticky key malformed if parsing can fail
- computed peer unavailable under current policy
- peer index out of range for generation

### `upstream_balancer_fallback off`

If sticky selection cannot produce a usable peer, do not silently choose a
different peer.

The module should return a deterministic decline/failure path. The exact nginx
return code must be chosen carefully after checking the peer callback contract,
but the user-visible behavior must amount to:

- no alternate peer is selected
- the request fails cleanly instead of being rerouted

### Important boundary

Fallback is about sticky miss behavior, not upstream retry policy after a peer
was successfully chosen and then failed during connect/send/receive.

Once a peer is selected, nginx's normal upstream retry/failure machinery still
matters, and this module must not accidentally bypass it.

---

## How To Preserve Nginx Failure Accounting

This is one of the easiest places to get the design wrong.

If our module picks a peer directly, but never lets round-robin account for
that choice, retries and fail counters may break.

The right shape is:

1. keep original round-robin peer data in request context
2. when sticky mode hits, set the chosen peer into module context
3. populate `pc->sockaddr`, `pc->socklen`, and `pc->name` from that peer
4. ensure `free_peer()` still updates peer accounting consistently

There are two realistic implementation strategies:

### Strategy A: wrap round-robin data and emulate its peer bookkeeping

Pros:

- full control over sticky choice

Cons:

- highest risk
- easiest way to diverge from nginx's retry/failure semantics

### Strategy B: reuse round-robin structures and keep module-owned bookkeeping
thin

Pros:

- lower risk
- better compatibility with later `dynamic-upstreams`

Cons:

- requires careful understanding of round-robin peer data layout

This module should prefer Strategy B.

The practical target is not "own every balancing detail." It is "override peer
choice while preserving the rest of nginx's upstream behavior."

---

## Peer Identity Contract

This is the interface `dynamic-upstreams` depends on.

### Version 1 contract

Within one generation, peer identity is the deterministic position of a peer
in the active eligible peer order, plus the underlying peer address/name
tuple.

That means:

- worker A and worker B see the same peer order
- sticky key `K` hashes to the same index everywhere
- if the generation changes, the same key may resolve differently unless the
  new generation preserves that peer order and identity

### What `dynamic-upstreams` must preserve later

When runtime snapshots arrive, `dynamic-upstreams` must expose:

- one complete peer graph per generation
- stable iteration order within a generation
- clear add/remove semantics across generations

The balancer must not assume removed peers still exist. A sticky key that used
to point to a removed peer is a miss in the new generation.

### What not to promise yet

Do not promise stable sticky routing across arbitrary peer reorderings.

If operators want that later, it needs an explicit stable peer-id scheme and a
different mapping contract than simple index-based hashing.

---

## Dynamic-Upstreams Integration Shape

The later handoff should be:

- upstream-balancer owns callback interception and selection
- dynamic-upstreams owns the active peer graph pointer for a generation
- balancer reads from that active peer source

That suggests one module boundary:

```zig
const PeerSourceVTable = extern struct {
    get_active_peers: ?*anyopaque, // fn(ctx) -> [*c]ngx_http_upstream_rr_peers_t
    retain_generation: ?*anyopaque,
    release_generation: ?*anyopaque,
};
```

Or equivalently one smaller native registration helper:

```zig
// Conceptual only; exact ABI can differ.
fn upstream_balancer_register_peer_source(
    uscf: [*c]ngx_http_upstream_srv_conf_t,
    source_ctx: ?*anyopaque,
    vtable: [*c]const PeerSourceVTable,
) void;
```

The point is the contract, not the exact signature:

- balancer asks for the active peer graph
- balancer can pin and release a generation if the source is dynamic
- balancer stays agnostic about how the peer graph was produced

This is cleaner than making dynamic-upstreams reach into request callbacks.

---

## Healthcheck Integration Boundary

Healthcheck should remain an input, not the owner of selection.

Version 1 of upstream-balancer should not directly query health if the peer
graph already encodes usable/unusable peers.

Later, if health-aware selection is added:

- healthcheck may mark a peer temporarily ineligible
- balancer may skip it during sticky resolution
- fallback semantics still apply

But the core module should avoid hard-coding active probing policy.

---

## Observability

The first useful observability surface should be debug logging only.

Log lines should make these states distinguishable:

- module installed for upstream `X`
- sticky mode `cookie` or `header`
- sticky key present / absent
- sticky hash value
- selected peer index
- fallback taken
- fallback disabled failure

That is enough to debug most phase 1-2 issues without building a metrics
system into the selector.

If counters are added later, keep them secondary.

---

## Failure Modes

| Failure | Required behavior |
|---|---|
| invalid directive combination | fail config load |
| empty cookie/header name | fail config load |
| sticky key missing with fallback `next` | delegate to original selection |
| sticky key missing with fallback `off` | fail cleanly |
| malformed request header/cookie | deterministic miss; no crash |
| peer graph unavailable unexpectedly | fail cleanly or delegate per documented policy |
| selected peer unusable before connect | respect fallback mode at selection boundary |
| connect/send/receive failure after selection | preserve nginx upstream retry/failure handling |

One key rule:

The module must never silently convert "sticky required" into "any peer is
fine" when fallback is `off`.

---

## Implementation Phases

### Phase 1: real upstream config + callback wrapper

Build:

- upstream-scoped config storage
- real directive parsing
- `init_upstream` wrapper
- `init_peer` wrapper
- request context allocation
- delegation to original `get_peer` / `free_peer`

Exit criteria:

- sticky mode `off` behaves like stock nginx
- invalid configs fail early
- tests prove callback ownership does not break proxying

### Phase 2: cookie sticky selection

Build:

- cookie extraction
- deterministic hash
- eligible peer enumeration
- direct sticky peer selection
- explicit fallback handling

Exit criteria:

- repeated cookie value routes to same peer within one generation
- miss behavior is explicit and test-backed
- multi-worker consistency holds

### Phase 3: header sticky selection

Build:

- header extraction using same mapping path

Exit criteria:

- header mode behaves equivalently to cookie mode except for input source

### Phase 4: dynamic peer-source handoff

Build:

- peer-source registration boundary
- generation-aware request pinning if the source is dynamic
- compatibility tests with replaced peer graphs

Exit criteria:

- balancer can serve from static or dynamic peer sources with the same
  selection rules

---

## Test Plan

### Zig unit tests

- directive parsing defaults
- mutual exclusion of cookie/header modes
- fallback parsing
- hash determinism for sample inputs
- peer-index selection over fixed peer arrays

### Bun integration tests for Phase 1

- config with sticky directives still proxies successfully
- upstreams without this module remain unaffected
- invalid directive combinations fail config load

### Bun integration tests for Phase 2

- same cookie value reaches same backend across repeated requests
- different cookie values can reach different peers
- missing cookie with `fallback next` still proxies
- missing cookie with `fallback off` fails cleanly
- malformed cookie header behaves deterministically

### Bun integration tests for Phase 3

- same header value reaches same backend across repeated requests
- missing header follows documented fallback behavior

### Multi-worker tests

- same sticky key resolves the same way across workers
- behavior remains deterministic for one peer generation

### Dynamic integration tests

- sticky mapping works against a runtime-provided peer graph
- removed peer causes documented miss/fallback behavior
- generation change does not corrupt request-local state

---

## What Not To Build First

- cookie issuance/rotation
- backup-peer sticky semantics
- stable peer-id remapping across arbitrary reorderings
- metrics-heavy observability
- health probing logic
- service discovery polling

Those all make sense later. None are required to build a correct first
selector.

---

## Final Position

The safest way to finish `upstream-balancer` is:

1. own nginx's callback path with a thin wrapper
2. keep stock behavior intact when sticky routing is inactive
3. add deterministic sticky selection with explicit fallback
4. document peer identity tightly enough that `dynamic-upstreams` can preserve
   it later

If we do that, this module becomes a stable selector foundation instead of a
fragile special-case router.
