# Technical Notes: Worker Events

Deep-dive implementation plan for the `worker-events` module.

This document is the technical attack plan behind
`src/modules/worker-events-nginx-module/README.md`. It is intentionally more
concrete than the README: it focuses on the shared-memory ring model,
cross-worker correctness, API semantics, and the boundaries this module must
keep so it does not turn into a policy engine.

The intended setting is:

- `worker-events` is a reusable native primitive for cross-worker signaling
- `healthcheck`, `dynamic-upstreams`, and `cache-purge` are consumers, not
  owners, of event transport semantics
- shared memory is the source of truth for module state; worker-events is
  notification and convergence glue on top of that truth
- this module must be useful on its own before any consumer-specific behavior
  is layered on top

---

## Mission

`worker-events` has one job: let one worker publish a small event and let
other workers observe it through a bounded, auditable shared-memory transport.

Its phased mission is:

1. expose one stable publish/introspection contract
2. store events in a bounded shared-memory ring
3. make cross-worker visibility deterministic and observable
4. remain generic enough that multiple modules can adopt it without inheriting
   each other's policy

That means this module is not:

- a workflow engine
- a durable queue
- a cross-node bus
- a source of truth for cache, health, or upstream state

It is the transport primitive.

---

## What Makes This Module Hard

The difficulty is not the HTTP endpoint. The difficulty is building a shared
ring that stays correct under concurrent workers and stays honest about loss.

The risky areas are:

- shared-memory layout and locking
- ring overflow semantics
- generation accounting for missed events
- making readers safe in the face of concurrent writes
- keeping payload shape flexible without turning the ring into a heap allocator
- not confusing notification with correctness

If we get that wrong, consumers either miss real changes silently or begin to
trust a transport that cannot justify that trust.

---

## Current Scaffold

Today the code in
`src/modules/worker-events-nginx-module/ngx_http_worker_events.zig` only
stores location-scoped config and exposes a placeholder handler:

- `worker_events_api`
- `worker_events_zone <name>`
- `worker_events_channel <channel>`
- `worker_events_ring_size <entries>`

The current tests only prove:

- the endpoint exists
- it returns a JSON `501`
- `HEAD` is deterministic
- neighboring routes still work

So this note is about turning that scaffold into the first real event bus.

---

## Design Principles

- **Bounded always**: ring size, payload size, and channel name size must have
  hard limits.
- **Shared-memory truth**: publication success means the event was appended to
  the ring, not that consumers acted on it.
- **Observable loss**: overflow and missed events must be measurable, never
  silent.
- **Append-only semantics**: version 1 should be write-once, inspect-many, not
  ack/delete.
- **Generic event shape**: event structure must be consumer-neutral.
- **No hidden allocations on publish**: publishing into shared memory should
  not depend on variable per-event slab allocations if a fixed entry model can
  avoid it.

---

## Correct Design Direction

### Core choice

Use one shared-memory ring per configured zone, with fixed-size entries and a
monotonic generation counter.

That means:

- `worker_events_zone` selects a shared-memory ring
- `worker_events_channel` filters logical traffic within that ring
- each publish appends one event with a generation id
- readers inspect a slice of the ring and infer missed history from
  generation bounds
- overflow drops the oldest retained history, not the newest publish

### Why overwrite-oldest is the right default

For invalidation-class signals, freshness is usually more important than
retaining arbitrarily old events.

Rejecting newest publishes when the ring is full looks safer, but it creates a
worse operator story:

- the publisher sees a failure
- the consumer still has only stale history
- producers may need retries or backoff logic immediately

Overwrite-oldest with dropped counters is simpler and keeps the newest truth
moving through the system. Consumers can still detect that history was lost.

---

## Shared State Model

Each configured zone should own one stable shared-memory control block:

```zig
const WorkerEventsStore = extern struct {
    initialized: ngx_flag_t,
    capacity: ngx_uint_t,
    payload_max: ngx_uint_t,

    next_generation: u64,
    write_index: ngx_uint_t,
    retained_count: ngx_uint_t,

    oldest_generation: u64,
    newest_generation: u64,
    dropped_events: u64,
};
```

Each ring entry should be fixed-size and self-contained:

```zig
const WorkerEventEntry = extern struct {
    generation: u64,
    channel_len: u16,
    type_len: u16,
    payload_len: u32,
    created_at_msec: i64,

    channel: [64]u8,
    event_type: [64]u8,
    payload: [512]u8,
};
```

Important ABI note: keep shared-memory structs C-ABI-safe. Avoid Zig slices,
managed containers, or pointers that require external lifetime tracking.

### Why fixed-size entries

Fixed-size entries trade some memory efficiency for much safer concurrency:

- no per-event shared-memory allocation path on publish
- no linked-list corruption risk
- easier overwrite semantics
- easier inspection endpoint
- no partial free problem

This module should optimize for auditability first, not packing density.

### Zone sizing

One zone is:

- one `WorkerEventsStore`
- `capacity` x `WorkerEventEntry`

Version 1 should reject impossible configurations early:

- `ring_size == 0`
- ring too large for the declared zone size
- channel/type/payload limits larger than compiled entry fields

---

## Config Model

The directives are currently location-scoped, but the real model splits into:

1. **location binding**
   - enable API
   - bind to zone
   - provide default channel

2. **zone ownership**
   - one actual ring per zone name
   - one canonical ring size per zone

That means multiple locations may point at the same zone, but their
configuration must not conflict on capacity or payload bounds.

### Location config shape

```zig
const WorkerEventsLocConf = extern struct {
    api_enabled: ngx_flag_t,
    zone_name: ngx_str_t,
    default_channel: ngx_str_t,
    ring_size: ngx_uint_t,
};
```

### Config rules

- `worker_events_zone` is required when `worker_events_api` is enabled
- `worker_events_ring_size` is required on first declaration of a zone
- empty zone/channel names are invalid
- two locations using the same zone name must not disagree on ring size
- if `worker_events_channel` is omitted, `GET` may still inspect the whole
  zone, but `POST` should fail unless an explicit channel is supplied via body
  or query

---

## API Contract

Version 1 should keep the API intentionally narrow.

### Publish

- method: `POST`
- content type: `application/json`
- one event per request

Request body shape:

```json
{
  "type": "cache_purge",
  "payload": "{\"tag\":\"user-123\"}"
}
```

If later phases allow an object payload instead of a string payload, that
should be documented as an explicit contract expansion. Version 1 should
prefer a string payload because the transport should not own application-level
JSON schema.

Response shape:

```json
{
  "module": "worker_events",
  "status": "published",
  "zone": "default",
  "channel": "cache",
  "generation": 42
}
```

### Inspect

- method: `GET`
- query params:
  - `channel=<name>` optional
  - `since=<generation>` optional
  - `limit=<count>` optional, bounded by capacity

Response shape:

```json
{
  "module": "worker_events",
  "zone": "default",
  "channel": "cache",
  "oldest_generation": 31,
  "newest_generation": 42,
  "dropped_events": 3,
  "events": [
    {
      "generation": 40,
      "type": "cache_purge",
      "payload": "{\"tag\":\"user-123\"}"
    }
  ]
}
```

### `HEAD`

`HEAD` should mirror `GET` status/headers and omit the body.

### Why not subscriptions yet

Long-polling or streaming can come later if needed. Version 1 should stick to:

- publish one event
- inspect retained state

That is enough to make the transport real and testable.

---

## Publish Path

Publishing should follow this flow:

1. validate method and body size
2. resolve location config and shared zone
3. validate channel/type/payload lengths
4. lock the shared-memory zone mutex
5. take `generation = next_generation`
6. write one fully-populated entry into `entries[write_index]`
7. advance `write_index`
8. update `next_generation`, `newest_generation`, and retention metadata
9. if the ring was already full:
   - advance `oldest_generation`
   - increment `dropped_events`
10. unlock
11. return the published generation

### Correctness rule

The store metadata must only be advanced after the entry is fully written.

Otherwise a reader may observe a generation number that points at an entry
whose payload was only partially copied.

With the zone mutex held for the whole entry write, version 1 can keep this
simple and safe.

---

## Read Path

Reading should not expose raw ring internals. It should expose a stable,
filtered slice.

The inspect flow should be:

1. validate method and query args
2. resolve zone and optional channel filter
3. lock the zone mutex
4. snapshot:
   - `oldest_generation`
   - `newest_generation`
   - `dropped_events`
   - retained entries matching the filter and `since`
5. unlock
6. render JSON from the local snapshot

### Why local snapshot rendering matters

Do not hold the zone mutex while formatting JSON or allocating request-memory
buffers. Copy event entries into request-local memory first, then unlock.

That keeps the shared lock held only for:

- fixed-size metadata reads
- bounded entry copies

not for output rendering.

---

## Multi-Worker Semantics

The ring is shared across workers, but correctness still has to be stated
carefully:

- **publication** means the event is visible in shared memory
- **delivery** means another worker can observe it on an inspect read
- **consumption** is outside the scope of this module

This distinction matters for consumers:

- `healthcheck` should still keep shared probe state as source of truth
- `dynamic-upstreams` should still keep active snapshot pointers in shared
  memory as source of truth
- `cache-purge` should still mutate canonical purge metadata directly

Worker-events is the prompt to re-read truth, not the truth itself.

---

## Failure Handling

Config-time failures:

- missing zone
- invalid ring size
- conflicting ring size for a reused zone
- invalid default channel

Runtime failures:

- unsupported method
- malformed JSON
- missing required `type`
- payload too large
- shared zone unavailable

Overflow is not a request failure. It is a successful publish with observable
history loss recorded in:

- `oldest_generation`
- `dropped_events`

That distinction should be explicit in both docs and tests.

---

## Observability

Version 1 introspection should expose enough fields to debug the bus:

- zone name
- configured capacity
- oldest generation
- newest generation
- dropped event count
- filtered event list

Later phases may add:

- per-channel counters
- last publish time
- last publish type

But those are additive.

---

## Consumer Contract

Consumers should treat the module as:

- bounded
- lossy under pressure
- cross-worker visible
- suitable for “something changed” signals

Consumers should **not** assume:

- durable delivery
- exactly-once delivery
- total history retention
- arbitrary payload size

This is why the first healthcheck integration should publish only a concise
transition event such as:

```json
{
  "type": "peer_health_changed",
  "payload": "{\"upstream\":\"backend\",\"peer\":\"10.0.0.1:8080\"}"
}
```

and then force readers to re-read canonical health state.

---

## Phase Plan

### Phase 1 - Shared primitive and API truth

Build:

- real zone creation
- fixed-size event ring
- `POST` publish
- `GET` inspect
- stable JSON responses

Do not build:

- consumer-specific schemas
- subscriptions
- auth
- replay beyond retained ring history

### Phase 2 - Cross-worker semantics and missed-history reporting

Add:

- multi-worker test coverage
- generation-based `since` behavior
- explicit overflow semantics
- dropped-event accounting

This is the phase where the module becomes safe for invalidation-class
consumers.

### Phase 3 - Consumer integration and hardening

Add only after the ring is already trustworthy:

- publish authorization
- consumer-oriented introspection
- early native integrations such as:
  - `healthcheck` transition fanout
  - `cache-purge` invalidation fanout

---

## Intended Non-Features

Version 1-3 should still avoid:

- ack protocols
- durable persistence
- cross-node replication
- workflow-owned semantics
- unbounded payloads

If those are ever needed, they should be separate modules or explicit future
phases, not accidental creep in this transport.

---

## Concrete Next Steps

1. replace placeholder handler with real method-aware `GET`/`POST` responses
2. add shared-memory zone creation and config validation
3. implement a fixed-size ring with overwrite-oldest semantics
4. add Bun tests for publish, inspect, and multi-worker visibility
5. only then attach one real consumer such as `healthcheck` or `cache-purge`

That sequence keeps the primitive honest before any dependent module begins to
trust it.
