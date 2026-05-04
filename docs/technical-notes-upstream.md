# Technical Notes: Dynamic Upstreams

> Deep-dive on the hardest Milestone 2 module: runtime upstream peer
> reconfiguration.  Assumes healthcheck, worker-events, upstream-balancer,
> and cache-purge are already built.

---

## Context: What The Easier Modules Already Deliver

Before dynamic-upstreams does anything useful, four other modules must be
feature-complete.  Here is what each provides at the handoff boundary.

### upstream-balancer

Owns the nginx peer callback contract.  At this point it:

- Intercepts `uscf->peer.init_upstream` and `uscf->peer.init` at config time
  for upstream blocks that have balancer directives
- In each request, replaces `r->upstream->peer.get`/`free` with its own
  handlers
- Provides sticky-cookie and sticky-header affinity against a fixed peer set
- Supports explicit `fallback next` / `fallback off` semantics
- Exports a **config-time registration API** that other modules can call to
  attach a custom peer source:

```zig
// Called during postconfiguration by dynamic-upstreams.
// Tells upstream-balancer: "for upstream with name X, read peers from my
// store instead of the static ngx_http_upstream_rr_peers_t."
fn balancer_register_peer_source(
    upstream_name: []const u8,
    store: *UpstreamStore,
) void;
```

Why this matters for dynamic-upstreams: without this hook, the balancer has
no way to discover dynamically-injected peers.  With it, dynamic-upstreams
owns the storage and the balancer only reads from it.

### worker-events

A shared-memory ring buffer for cross-worker signaling:

- Publish a typed event with a payload
- Workers consume events via timer-based polling or an event handler
- Generation tracking to detect missed events
- Dropped-event accounting

What dynamic-upstreams uses it for:

- After a peer snapshot is activated on the control-plane worker, broadcast
  an event so all workers re-read the active generation pointer
- Avoids polling the SHM zone on every request (though reads still check the
  pointer; the event is a prompt, not a guarantee)
- Also used for health-state transitions: when healthcheck marks a peer down,
  dynamic-upstreams is notified to re-evaluate the active snapshot

### healthcheck

Active HTTP probing with shared-memory state:

- Per-peer probe timer, configurable interval/timeout/thresholds
- `health_readiness` / `health_liveness` / `health_status` endpoints
- Shared-memory `healthcheck_store` with probe counters and health flags
- nginx variables: `health_backend_ready`, `health_backend_healthy`, etc.
- Peer-health query API: `healthcheck_peer_is_healthy(addr) → bool`

What dynamic-upstreams uses it for:

- Before activating a new snapshot, filter out peers that healthcheck reports
  as unhealthy (optional, controlled by a directive flag)
- After activation, subscribe to health transitions so a peer that recovers
  can be re-included without a full snapshot replacement (Phase 2+ feature)

---

## Dynamic Upstreams: Architecture

With all dependencies satisfied, dynamic-upstreams has exactly three jobs:

1. **Own a shared-memory upstream store** — the canonical peer set for each
   managed upstream, safely visible to all workers
2. **Expose a control API** — JSON endpoint for inspecting and replacing peer
   snapshots
3. **Manage snapshot lifecycle** — generation tracking, atomic activation,
   draining, and garbage collection of old generations

### Design Principles

- **Snapshot-oriented, not mutation-oriented**: a write always provides a
  complete replacement peer list.  No partial add/remove operations in the
  first version.
- **Generation-gated**: every snapshot has a monotonic generation ID.
  Readers never observe a partially-applied snapshot.
- **Fail-safe**: allocation failure, payload validation failure, or source
  failure always preserve the last-good active state.
- **Decoupled storage**: dynamic-upstreams owns the SHM zone; the balancer
  reads from it via a pointer it registered at config time.

---

## Data Model: Shared-Memory Upstream Store

Defined in `ngx_http_dynamic_upstreams.zig`, allocated in a dedicated
`ngx_shm_zone_t`.

### Core Structures

```zig
/// A single backend peer, stored in shared memory.
/// Sized to fit sockaddr_storage (28 bytes on Linux) plus metadata.
const PEER_ADDR_MAX = 28;
const PEER_NAME_MAX = 256;

const PeerEntry = extern struct {
    addr: [PEER_ADDR_MAX]u8,       // sockaddr_storage
    addr_len: socklen_t,
    name: [PEER_NAME_MAX]u8,      // human-readable "10.0.0.11:8080\0"
    name_len: u16,
    weight: u16,
    max_conns: u16,
    max_fails: u16,
    fail_timeout_sec: u16,
    down: bool,
    backup: bool,
    // Padding to next alignment (no bool[] in extern structs, but
    // the C ABI packs these as separate fields)
};

/// One complete peer set, immutable after activation.
/// Layout: fixed header followed by a variable-length peer array.
const UpstreamSnapshot = extern struct {
    magic: u32,                    // sanity check: 0xDEADBEEF
    generation: u64,               // monotonic, incremented on each activate
    state: SnapshotState,          // staging / active / draining
    ref_count: u32,                // in-flight requests referencing this snapshot
    peer_count: u32,
    // PeerEntry peers[0];         // flexible array, allocated separately via slab
};

const SnapshotState = enum(u8) {
    staging  = 0,
    active   = 1,
    draining = 2,
};

/// Per-upstream control block, stored in the same SHM zone.
const UpstreamStore = extern struct {
    name: [256]u8,                 // upstream block name, e.g. "api_backend"
    name_len: u16,
    active: ?*UpstreamSnapshot,    // currently serving; never null after first activation
    staging: ?*UpstreamSnapshot,   // being validated; null when idle
    last_error: [256]u8,
    last_error_len: u16,
    last_ok_timestamp_ms: i64,
    reserved: [64]u8,             // future: health-aware filter flags, etc.
};
```

### SHM Zone Layout

```
ngx_shm_zone_t (e.g. "dynamic_upstreams")
  └── ngx_slab_pool_t
        ├── mutex
        └── allocations:
              ├── UpstreamStore[]        — one per managed upstream
              ├── UpstreamSnapshot[]     — active + staging snapshots
              └── PeerEntry[]            — variable-length peer arrays
```

The zone is created once in `postconfiguration` / `init_main_conf`.  The
size is configured by a directive, e.g. `dynamic_upstreams_zone_size 256k`.

### Allocation Strategy

- **Store entries**: one per upstream name registered via
  `dynamic_upstreams_target`.  Allocated in `postconfiguration` and never
  freed.
- **Snapshots**: allocated via `ngx_slab_calloc` on each write.  Freed when
  `ref_count` drops to zero and `state == draining`.
- **Peer arrays**: allocated as a single contiguous slab block after the
  snapshot header.  The snapshot stores the pointer; the peers are not
  inline to keep the snapshot header small and fixed-size.

```
Snapshot memory layout (two slab allocations):

  [UpstreamSnapshot header]  ← slab block 1 (fixed size)
  [PeerEntry x N]            ← slab block 2 (variable size, pointer from header)
```

This makes `ngx_slab_free` on the snapshot straightforward: free block 2,
then free block 1.

---

## Request Lifecycle Integration

This is how a proxied request flows once dynamic-upstreams is active.

```
1. Client request hits location with proxy_pass.
2. nginx upstream machinery starts, selects upstream "api_backend".
3. upstream-balancer's registered peer.init(r, us) runs.
   → It sets pc->get = balancer_get_peer
   → It sets pc->free = balancer_free_peer
   → It stores a reference to UpstreamStore.active in pc->data
4. balancer_get_peer(pc, data):
   → Load store.active (atomic read of the pointer)
   → Increment snapshot.ref_count (SHM lock + atomic increment)
   → Select peer from snapshot.peers[] using round-robin or sticky logic
   → Set pc->sockaddr = pool-allocated copy of peer.addr
   → Set pc->name = pool-allocated copy of peer.name
   → Return NGX_OK
5. nginx connects to backend, sends request, receives response.
6. balancer_free_peer(pc, data, state):
   → Load store.active
   → Decrement snapshot.ref_count
   → If ref_count == 0 and state == draining:
        ngx_slab_free(shpool, snapshot)
```

### Why copy sockaddr to the request pool?

nginx's connection code expects `pc->sockaddr` to remain valid for the
lifetime of the upstream connection.  If we pointed directly into SHM,
another worker could free the snapshot during draining while this worker
still has in-flight connections.  Instead:

- `balancer_get_peer` allocates a `sockaddr_storage` from `r->pool`
- `memcpy` the addr from the snapshot's peer entry
- `pc->sockaddr` points to the pool copy

The request pool outlives the upstream connection, so this is safe.

---

## Snapshot Lifecycle

### Activation

```
write endpoint receives PUT /api/upstreams/api_backend
  with JSON body: { "peers": [{"address": "10.0.0.11:8080"}, ...] }

1. Parse JSON, validate:
   - Each address: valid ip:port or hostname:port
   - No duplicate addresses in the list
   - At least one peer
   - Weight > 0 if present
2. If invalid: return JSON error, store.active unchanged
3. Allocate UpstreamSnapshot from SHM slab pool:
   - generation = store.active.generation + 1
   - state = staging
   - ref_count = 0
   - peer_count = parsed count
4. Allocate PeerEntry[] from SHM slab pool:
   - Copy parsed addresses/weights into entries
5. Lock SHM mutex
6. store.staging = newly allocated snapshot
7. Validate staging snapshot: (sanity check pointer, checksum)
8. store.active = store.staging     ← atomic activation
9. store.staging = null
10. If old active snapshot has ref_count == 0:
       → Free it immediately
    Else:
       → Set old active.state = draining
       → (worker-events broadcast to prompt workers to drain)
11. Unlock SHM mutex
12. Publish worker-events event: "snapshot_activated: api_backend, gen=7"
13. Return JSON with new generation ID and peer count
```

### Draining

After activation, the old snapshot must not be freed until no worker has an
in-flight request referencing it.

```
balancer_free_peer decrements ref_count (under SHM lock).

If ref_count == 0 AND state == draining:
  → Free the snapshot (both header and peer array allocations)
  → (This can happen on any worker, not just the one that activated it)
```

**Timeout fallback**: if a snapshot remains in `draining` state for longer
than a configured interval (e.g. 60 seconds), the next activation cycle
forces its release.  This prevents leaked snapshots from accumulating if
`free_peer` is somehow never called for some references.

### Worker-Events Integration

On activation, the control-plane worker broadcasts:

```
EventType: SnapshotActivated
Payload:   upstream_name (256 bytes) + generation_id (u64)
```

Workers that have registered interest in this event re-read the store and
update any per-worker cached state.  This is not strictly required for
correctness — reads are always against the SHM zone — but it accelerates
convergence and enables per-worker cache invalidation if needed.

---

## Control API

### Directive Surface

```
dynamic_upstreams_api;                     # enables the control endpoint
dynamic_upstreams_target api_backend;      # binds to upstream block
dynamic_upstreams_source static;           # source mode (static|consul)
dynamic_upstreams_refresh 5000;            # background refresh interval (ms)
dynamic_upstreams_health_filter on|off;    # skip unhealthy peers on activation
```

### Endpoints

#### GET /api/upstreams/{name}

Returns current active snapshot:

```
200 OK
Content-Type: application/json

{
  "module": "dynamic_upstreams",
  "target": "api_backend",
  "generation": 7,
  "source": "static",
  "peer_count": 2,
  "peers": [
    {
      "address": "10.0.0.11:8080",
      "weight": 1,
      "max_conns": 0,
      "down": false,
      "backup": false
    },
    {
      "address": "10.0.0.12:8080",
      "weight": 1,
      "max_conns": 0,
      "down": false,
      "backup": false
    }
  ],
  "last_error": null,
  "last_ok_timestamp_ms": 1714812345678
}
```

#### PUT /api/upstreams/{name}

Replace the active snapshot:

```
Request:
PUT /api/upstreams/api_backend
Content-Type: application/json

{
  "peers": [
    {"address": "10.0.0.11:8080", "weight": 2},
    {"address": "10.0.0.13:8080", "weight": 1}
  ]
}

Response 200:
{
  "status": "activated",
  "generation": 8,
  "peer_count": 2
}

Response 400:
{
  "status": "validation_error",
  "errors": [
    {"field": "peers[2].address", "message": "invalid address format"},
    {"field": "peers[0]", "message": "duplicate address: 10.0.0.11:8080"}
  ]
}

Response 503:
{
  "status": "error",
  "message": "shared memory exhausted; last good snapshot preserved"
}
```

Unsupported methods return `405 Method Not Allowed` with an Allow header.

### Background Reconciliation (Phase 2)

When `dynamic_upstreams_source consul` is configured (or any future source),
the module starts a periodic timer per managed upstream.  Each tick:

1. Query the source (e.g. Consul service endpoint)
2. Parse result into a peer list
3. Compare with the current active snapshot
4. If different, validate and activate as a new snapshot
5. On failure: log the error, preserve last-good snapshot, update
   `store.last_error`

The timer runs on the worker that received the first request to the control
endpoint (or on worker 0 if configured at startup).  Snapshot activation
is visible to all workers because the SHM store is shared.

---

## Integration With upstream-balancer: The Handoff Contract

The most critical interface in the system.  Documented here so both modules
evolve against the same expectations.

### What dynamic-upstreams guarantees

- `UpstreamStore.active` is never null after the first activation
- `active.generation` is monotonic and never wraps (u64)
- The active snapshot is immutable after activation (no field changes)
- A peer entry's `addr` / `name` / `weight` are stable for the snapshot's
  lifetime
- `UpstreamStore` is in shared memory; readers must lock or use atomic reads

### What upstream-balancer must preserve

- Peer identity is derived from `(addr, name)` tuple within a generation.
  Two peers in the same generation with different addresses are different
  peers.  A removed peer simply does not appear in the new snapshot.
- Sticky affinity keys map to peer index within the active generation.
  If a sticky key maps to index 3 and the new generation has only 2 peers,
  fallback semantics apply.
- `balancer_get_peer` must copy sockaddr/name to the request pool, not
  point directly into SHM.

### Peer Identity For Sticky Affinity

When dynamic-upstreams activates a new snapshot, some sticky sessions may
point to peers that no longer exist.  The fallback behavior must be
documented:

1. If the sticky key maps to a peer index within bounds → deliver to that peer
2. If the index is out of bounds → apply `fallback next` or `fallback off`
   per the upstream-balancer configuration
3. No implicit remapping of sticky keys to different peers

This means sticky affinity is generation-scoped.  A client whose peer was
removed will experience a miss; the operator should expect this and plan
drain windows or use health-filter to remove inactive peers before dropping
them.

---

## Testing Strategy

### Unit Tests (Zig)

- `UpstreamSnapshot` allocation and freeing in simulated SHM
- Generation ID monotonicity and wrapping behavior
- Peer entry serialization/deserialization between SHM and JSON
- Validation rules: duplicate addresses, invalid formats, weight bounds
- Lock/unlock sequences around snapshot activation

### Integration Tests (Bun)

**Phase 1 — Read-only:**
- `GET` returns stable JSON with correct peer count and addresses
- `HEAD` returns same headers as `GET` without body
- Invalid target name returns 404 or clear error
- Upstream configured without `dynamic_upstreams_api` is unaffected
- Neighboring routes (e.g. healthcheck endpoints) unaffected

**Phase 2 — Snapshot replacement:**
- `PUT` with valid payload activates new peers immediately visible via `GET`
- `PUT` with invalid payload returns 400, old snapshot preserved
- `PUT` with same payload (no change) returns success with same generation
- Proxy traffic routes to newly added peers after activation
- Proxy traffic stops routing to removed peers after activation
- 10 concurrent `PUT` requests: last one wins, no crashes

**Phase 3 — Multi-worker:**
- Activate snapshot on one worker; verify all workers serve the new peers
- Verify active-leader election for reconciliation timer (only one worker
  polls the upstream source)

**Phase 4 — Drain + Health:**
- Activate replacement while requests are in-flight against old peers
- Verify old snapshot is freed after all in-flight requests complete
- With `health_filter on`, unhealthy peers are excluded from the activated
  snapshot (healthcheck must report them as unhealthy first)
- Sticky session to a removed peer falls back per balancer policy

---

## Failure Modes and Recovery

| Failure | Behavior |
|---|---|
| SHM slab exhaustion on `PUT` | Return 503, preserve last-good snapshot |
| Invalid JSON payload | Return 400, no state change |
| Upstream target not found at config time | Fail config load with clear error |
| Worker process crash mid-activation | Lock is released on crash; SHM is in a consistent state because activation is a single pointer write under lock |
| Control endpoint receives unexpected HTTP method | Return 405 |
| Background reconciliation source unreachable | Log error, preserve last-good snapshot, retry on next interval |
| Stale draining snapshot never reaches ref_count=0 | Force-release after timeout (configurable, default 60s) |

---

## What Not To Build In The First Version

- Partial peer add/remove (always full snapshot replacement)
- Weighted least-conn or custom selection in the control API (that is
  upstream-balancer's job)
- Automatic consul integration before static write-path is stable
- WebSocket or streaming-aware peer tracking
- Per-request peer metrics (may be added by prometheus module later)

First version goal: a control endpoint that can atomically swap a complete
peer set, and a balancer that serves from it.  Everything else is Phase 2+.

---

## Appendix: Key nginx C Types Referenced

```
ngx_http_upstream_srv_conf_t {
    ngx_http_upstream_peer_t peer;    // { init_upstream, init, data }
    void **srv_conf;                   // per-module config pointers
    ngx_array_t *servers;              // ngx_http_upstream_server_t[]
    ngx_str_t host;
    in_port_t port;
}

ngx_http_upstream_peer_t {
    ngx_http_upstream_init_pt       init_upstream;   // config-time
    ngx_http_upstream_init_peer_pt  init;            // per-request
    void *data;
}

ngx_peer_connection_s {
    ngx_connection_t *connection;
    struct sockaddr *sockaddr;
    socklen_t socklen;
    ngx_str_t *name;
    ngx_event_get_peer_pt   get;       // select peer
    ngx_event_free_peer_pt  free;      // release peer
    void *data;                        // opaque per-request state
}
```

All of these are already exported in the Zig bindings via
`src/ngx/ngx_http.zig`.  The peer callback function pointer types
(`ngx_event_get_peer_pt`, `ngx_event_free_peer_pt`) are defined in nginx's
`ngx_event_connect.h` and need `extern fn` declarations added to the
bindings if not already present.

---

*Documented 2026-05-04 — Implementation-focused notes for dynamic-upstreams,
assuming healthcheck, worker-events, upstream-balancer, and cache-purge are
complete.*
