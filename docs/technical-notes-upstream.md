# Technical Notes: Dynamic Upstreams

Deep-dive on the hardest Milestone 2 module: runtime upstream peer
reconfiguration.

This document is an audit and corrected design note, not just a feature wish
list. It assumes the intended Milestone 2 setting:

- `upstream-balancer` is implemented and owns the upstream callback surface
- `worker-events` is implemented and provides cross-worker signaling
- `healthcheck` is implemented with upstream-peer-aware health state
- `dynamic-upstreams` is the last hard module to finish on top of them

That assumption is important. The point here is not to revisit whether those
dependencies exist, but to define the safest way to complete
`dynamic-upstreams` given that they do.

---

## Context: What The Other Modules Already Deliver

Under the intended setting, dynamic-upstreams is not building in isolation.
It is the runtime control layer that sits on top of three already-finished
primitives.

### upstream-balancer

Assume this module already:

- owns `init_upstream`, `init`, `get`, and `free` callback handoff
- can serve traffic from a module-provided peer source instead of only the
  config-time static upstream table
- supports sticky cookie/header affinity and explicit fallback semantics
- preserves a documented peer identity contract across generations

Dynamic-upstreams depends on this for request-time peer selection. Without
that handoff, dynamic-upstreams can store snapshots but cannot actually route
through them.

### worker-events

Assume this module already:

- provides a shared-memory event ring
- broadcasts typed cross-worker events
- tracks generations and dropped events
- lets consumers subscribe to invalidation-class signals

Dynamic-upstreams uses this as fanout and convergence acceleration after
activating a new snapshot. It should not be the only correctness mechanism,
but it is a real integration point once implemented.

### healthcheck

Assume this module already:

- tracks health keyed by upstream peer identity
- exposes peer-health query APIs to native modules
- can publish peer transition events
- distinguishes health reporting from peer selection policy

Dynamic-upstreams uses this for optional activation-time filtering and later
for recovery-driven re-inclusion decisions.

---

## Audit Of The Earlier Design

The earlier note had the right high-level direction: snapshot replacement,
generation tracking, and last-good preservation. Those parts should stay.

The weak points were these:

1. It modeled dynamic peers as a custom `PeerEntry[]` table detached from
   nginx's native upstream peer structures.
2. It showed `free_peer()` reloading `store.active`, which is wrong after a
   generation switch.
3. It proposed force-freeing draining snapshots on timeout, which is unsafe if
   requests still hold references.
4. It leaned too heavily on worker-events for correctness instead of treating
   them as fanout on top of shared-memory truth.
5. It mixed the static snapshot-write path with later features like source
   polling and health-driven reconciliation before the base mutation model was
   nailed down.

The biggest correctness issue is item 3:

`free_peer()` must release the exact snapshot captured for the request, not
whatever snapshot happens to be active when the request finishes.

If we get that wrong, generation swaps can produce refcount leaks or
use-after-free.

---

## Non-Negotiable Constraints

Any real implementation has to respect nginx's upstream model:

- peer selection happens through the upstream peer callback contract
- round-robin peers have concrete runtime fields such as weights, fail counts,
  `max_fails`, `fail_timeout`, backup chains, and lock/ref fields when shared
  memory is involved
- long-lived connections and retry logic expect stable peer objects for the
  lifetime of the request
- cross-worker visibility is a shared-memory problem first, not an event-bus
  problem

This leads to one key design decision:

Dynamic-upstreams should not invent an isolated peer table and ask the
balancer to reinterpret it from scratch if we can avoid it.

The safer path is to keep the runtime snapshot close to nginx's native
`ngx_http_upstream_rr_peers_t` / `ngx_http_upstream_rr_peer_t` layout and swap
complete peer graphs atomically.

That is also consistent with how nginx's own upstream zone module copies peer
graphs into shared memory.

---

## Corrected Design Direction

### Core choice

Use a snapshot-oriented shared-memory store where each generation owns a full
round-robin peer graph plus small module metadata.

That means:

- the control plane validates a complete replacement peer list
- it builds a new snapshot in shared memory
- it publishes that snapshot with one pointer swap under lock
- requests pin one snapshot for their lifetime
- old snapshots become draining and are freed only when their refcount reaches
  zero

### What version 1 should do

Version 1 should be deliberately narrow:

- static target binding
- read-only introspection first
- then full-snapshot replacement via one write method
- IPv4/IPv6 socket addresses only at first
- no background source polling
- no health filtering
- no dependency on worker-events

### What version 1 should not do

- partial add/remove mutations
- DNS/service-discovery-driven peer churn
- health-triggered live mutation
- forced release of referenced snapshots
- sticky-cookie migration semantics across generations

---

## Architecture

With its dependencies in place, dynamic-upstreams has three jobs:

1. own the shared-memory canonical peer snapshots for managed upstreams
2. expose the control and reconciliation surface for replacing snapshots
3. coordinate activation, draining, and cross-worker convergence safely

The implementation still needs phases, but those phases are now internal to
dynamic-upstreams rather than blocked on missing prerequisite modules.

---

## Shared State Model

### Store shape

Each managed upstream should have a stable control block in shared memory:

```zig
const UpstreamStore = extern struct {
    name: ngx_str_t,
    active: ?*anyopaque, // cast to [*c]Snapshot or *Snapshot outside the ABI struct
    draining_head: ?*anyopaque,
    next_generation: u64,
    last_error_code: u32,
    last_error_at_msec: i64,
    last_success_at_msec: i64,
};
```

Each snapshot should contain module metadata plus one complete peer graph:

```zig
const Snapshot = extern struct {
    generation: u64,
    refcount: ngx_atomic_t,
    draining: ngx_flag_t,
    peer_count: ngx_uint_t,
    peers: [*c]ngx_http_upstream_rr_peers_t,
    next_draining: ?*anyopaque,
};
```

Important Zig ABI note: these examples are intentionally C-ABI-safe. The
runtime implementation should not place Zig-native pointers like `*Snapshot`
inside an `extern struct`. Use C pointers (`[*c]T`) or opaque pointer fields
inside the ABI struct, then cast at the module boundary.

### Why not a custom `PeerEntry[]` only?

Because the runtime peer object needs more than address strings.

Even the first useful implementation needs to preserve enough data for peer
selection and retry behavior:

- `sockaddr` / `socklen`
- `name`
- `weight`
- `max_conns`
- `max_fails`
- `fail_timeout`
- `down`
- peer chaining
- aggregate fields on `ngx_http_upstream_rr_peers_t`

If we store only a lightweight custom peer table, the balancer ends up
re-implementing too much of nginx's peer runtime contract. That is a higher
risk design.

### Representation choice

The snapshot should therefore allocate:

- one `Snapshot`
- one `ngx_http_upstream_rr_peers_t`
- one linked list of `ngx_http_upstream_rr_peer_t`
- per-peer `sockaddr` and `name` buffers

All of that lives in the module's shared-memory zone and is immutable after
activation except for refcount and draining bookkeeping.

Version 1 should reject unsupported peer properties instead of pretending to
support them.

Examples to reject initially:

- hostnames requiring background resolution
- backup peers, unless explicitly implemented
- slow-start metadata
- per-peer TLS/session metadata

---

## Request Lifecycle

The request must pin a snapshot once and release that same snapshot later.

### Per-request context

`upstream-balancer` should store request-local state similar to:

```zig
const DynamicPeerCtx = extern struct {
    snapshot: [*c]Snapshot,
    peers: [*c]ngx_http_upstream_rr_peers_t,
    current: [*c]ngx_http_upstream_rr_peer_t,
};
```

### Correct flow

1. Request enters upstream peer init.
2. Balancer finds the `UpstreamStore` for the upstream.
3. Under store lock or equivalent atomic discipline, balancer reads
   `store.active`.
4. Balancer increments that snapshot's refcount.
5. Balancer stores the snapshot pointer in request-local context.
6. `get_peer()` selects from `ctx.snapshot`, not from `store.active`.
7. `free_peer()` decrements `ctx.snapshot.refcount`.
8. If refcount reaches zero and snapshot is draining, free it.

That point is critical:

`get_peer()` and `free_peer()` must work against the pinned request snapshot,
not the latest active snapshot in shared memory.

### Consequence

A request that started on generation 7 can safely finish on generation 7 even
if generation 8 becomes active midway through the request.

That is the core safety property we need.

---

## Activation Lifecycle

### Write path

For the first writable version, support one explicit contract:

- one bound upstream per endpoint
- one full replacement payload
- one atomic activation path

Example request shape:

```json
{
  "peers": [
    { "address": "10.0.0.11:8080", "weight": 1 },
    { "address": "10.0.0.12:8080", "weight": 1 }
  ]
}
```

### Validation rules for version 1

- at least one peer is required
- address must parse into a concrete socket address
- duplicate address entries are rejected
- weight must be positive if present
- unsupported fields are rejected explicitly

### Activation sequence

1. Parse and validate payload outside the shared-memory lock as much as
   possible.
2. Lock the shared-memory store.
3. Build a fully populated new snapshot in shared memory.
4. Set `generation = store.next_generation`.
5. Swap `store.active` to the new snapshot.
6. Mark previous active snapshot as draining and link it into the draining
   list.
7. Increment `store.next_generation`.
8. Unlock.
9. Return success with generation and peer count.

If any allocation or validation step fails before the pointer swap, the last
good active snapshot remains untouched.

### No timeout force-free

Do not free draining snapshots just because they are old.

Age is not proof that no request still references them.

If we later add leak detection, it should report suspiciously old draining
snapshots through introspection and logs, not force-release memory behind live
requests.

---

## Control API

### Phase 1

Replace the `501` placeholder with truthful read-only JSON.

Minimum response fields:

```json
{
  "module": "dynamic_upstreams",
  "target": "api_backend",
  "writable": false,
  "generation": 0,
  "peer_count": 1,
  "peers": [
    { "address": "127.0.0.1:19002", "weight": 1 }
  ]
}
```

That response can be backed by the configured static upstream even before live
mutation exists.

### Phase 2

Add one write method:

- `PUT` for full replacement

Expected behavior:

- `GET` returns active generation
- `HEAD` mirrors `GET` headers without a body
- `PUT` replaces the full snapshot
- unsupported methods return `405`

The API should stay bound to one upstream named by
`dynamic_upstreams_target`.

That is simpler and safer than designing a global routing API first.

### Source modes

The current directive surface includes `dynamic_upstreams_source`, but version
1 should only accept `static`.

`consul` should remain documented as future work, not as an active phase
requirement.

If `consul` is configured before that phase exists, config load should fail
clearly.

---

## Handoff Contract With `upstream-balancer`

This is the most important module boundary.

### Dynamic-upstreams must guarantee

- `store.active` changes only by complete snapshot swap
- an active snapshot is immutable after publication
- generation ids are monotonic
- peer ordering inside one generation is stable
- snapshot memory remains valid until its refcount drops to zero

### Upstream-balancer must guarantee

- it pins one snapshot per request
- it never releases a different snapshot than the one it pinned
- it uses the pinned peer graph for selection and fallback
- it copies any request-lifetime address/name data if nginx requires request
  pool ownership for the connection path it uses

### Sticky affinity

Sticky behavior should be generation-scoped.

That means:

- a sticky key may map to peer index `n` within one generation
- if the next generation has no matching peer at that position or identity,
  the balancer applies documented fallback behavior
- there is no implicit sticky remap in version 1

That is acceptable as long as it is documented plainly.

---

## Worker Events And Healthcheck

### Worker-events

Assuming worker-events is already finished, dynamic-upstreams should use it
for:

- snapshot-activated fanout
- cache invalidation of per-worker derived state
- operator-visible transition notifications

It still should not be the only correctness mechanism. Shared memory remains
the source of truth, and worker-events is the prompt for fast convergence.

### Healthcheck

Assuming healthcheck is already finished and keyed by peer identity,
dynamic-upstreams should use it for:

- excluding unhealthy peers from newly built snapshots
- reintroducing recovered peers
- operator-visible health state per dynamic peer

What should still be deferred is automatic health-triggered in-place mutation.
Version 1 should apply health at activation boundaries, not let healthcheck
silently mutate the active snapshot out of band.

---

## Implementation Plan

### Phase 1: truthful introspection

Goal:

- keep the current directives
- validate `dynamic_upstreams_target`
- return real data for the bound upstream instead of `501`

This phase proves:

- config-time lookup of upstream definitions
- JSON serialization of upstream peers
- safe module wiring without mutation

### Phase 2: static snapshot replacement

Goal:

- add the shared-memory zone
- create one `UpstreamStore` per managed upstream
- support full replacement via `PUT`
- pin snapshots per request through the balancer

This phase is the first real dynamic-upstreams milestone.

### Phase 3: reconciliation and integration depth

With the core swap path correct, add:

- source polling
- worker-events fanout
- health-aware filtering
- richer peer flags

These belong after Phase 2 because they all depend on the snapshot lifecycle
already being correct.

---

## Test Strategy

### Zig unit tests

- payload validation
- duplicate-address rejection
- generation increment rules
- snapshot publish rules
- draining list bookkeeping

### Bun integration tests for Phase 1

- `GET` returns truthful JSON for configured target
- `HEAD` is consistent
- invalid target fails clearly
- neighboring routes remain unaffected
- placeholder `501` is gone for valid config

### Bun integration tests for Phase 2

- `PUT` activates a new generation
- invalid payload preserves old generation
- concurrent reads never observe partial activation
- traffic reaches new peers after activation
- in-flight requests on the old generation still complete
- worker-events fanout does not change correctness, only convergence speed
- health-filtered activation excludes unhealthy peers without mutating the
  prior generation

### Multi-worker coverage

Before Phase 2 is called complete, prove:

- one worker activates a snapshot
- another worker serves traffic from the new generation
- old generations remain valid until all referencing requests finish

---

## Failure Semantics

Required behavior:

| Failure | Required behavior |
|---|---|
| invalid target upstream | fail config load or return a stable API error |
| invalid JSON payload | return `400`, preserve active snapshot |
| unsupported source mode | fail config load |
| shared-memory allocation failure | return `503`, preserve active snapshot |
| concurrent writes | serialize under store lock; last successful swap wins |
| source polling failure in later phases | preserve last good snapshot |
| worker-events delivery lag/loss | workers re-read shared-memory truth on next access; no split-brain state |
| peer unhealthy during activation | exclude or mark per documented health-filter policy; preserve prior generation on policy failure |

One important rule:

Preserving the last good snapshot is more important than accepting every
requested update.

---

## Final Position

The right approach is to keep the snapshot idea and discard the parts that are
too speculative.

Confirmed:

- snapshot replacement is the right mutation model
- generation-gated activation is the right consistency model
- last-good preservation is the right failure model

Rejected or deferred:

- custom peer storage detached from nginx peer graphs
- `free_peer()` lookup via current active pointer
- timeout-based forced freeing of draining snapshots
- worker-events as the sole correctness path
- healthcheck-driven out-of-band mutation of the active generation
- `consul` refresh before the static write path exists

If we follow that corrected design, dynamic-upstreams becomes hard but
tractable: first introspect, then atomically swap native-style peer snapshots,
then layer on reconciliation and health-aware activation through the already
finished supporting modules.
