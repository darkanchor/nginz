## Worker Events Module

Planned cross-worker event bus primitive for nginz-native and njs-integrated coordination.

### Status

**Planning / scaffolded** - module wiring and placeholder API surface exist. Cross-worker event delivery is not implemented yet.

### Purpose and Boundaries

This module provides the native primitive for cross-worker signaling so higher-level invalidation, revocation, orchestration, and policy flows do not depend on polling.

This module should own:

- shared-memory event ring / queue semantics
- publish and inspect operations
- channel naming and generation tracking
- dropped-event accounting

This module should **not** own:

- full application-level workflow logic
- cache invalidation policy itself
- broad runtime API aggregation

### Current Scaffold Behavior

- `worker_events_api` installs a placeholder JSON endpoint that returns HTTP `501`.
- Remaining directives reserve configuration names and store stub values for the future event-bus implementation.
- No shared-memory ring, publish path, or subscription integration is active yet.

### Current Scaffold Test Coverage

`tests/worker-events/worker-events.test.js` currently proves:

- the scaffold endpoint returns an explicit JSON `501 Not Implemented` response
- `HEAD` requests remain deterministic on the placeholder endpoint
- normal non-module routes still work while cross-worker delivery is unimplemented

### Directive Surface

| Directive | Planned Syntax | Planned Context | Purpose |
|---|---|---|---|
| `worker_events_api` | `;` | `location` | Expose an operational endpoint for inspecting or publishing events |
| `worker_events_zone` | `<name>` | `location` | Select the shared-memory zone used for the event ring |
| `worker_events_channel` | `<channel>` | `location` | Bind the endpoint to a named logical event channel |
| `worker_events_ring_size` | `<entries>` | `location` | Configure the planned ring-buffer capacity |

### Integration Points

- `src/modules/worker-events-nginx-module/ngx_http_worker_events.zig`
- future consumers: `cache-purge`, `healthcheck`, njs modules in `nginz-njs`
- `build.zig`
- `src/ngz_modules.zig`
- `project/build_package.zig`
- nginx request handling: location-scoped content handler serving publish/inspect operations

### Data Model and Config

#### Planned location config shape

Document and implement:

- API enabled flag
- zone name
- default channel name
- configured ring capacity

#### Planned shared-memory model

Use a simple ring/event-log model:

- write index
- read/inspect generation
- fixed-size event entries
- channel name or channel id
- dropped-event counter

Do not hide overflow semantics. Document them explicitly from the first real implementation.

### Planned API Contract

#### Phase 1 event shape

Phase 1 should standardize one minimal event entry with fields equivalent to:

- `generation`
- `channel`
- `type`
- `payload`

#### Endpoint directionality

- `GET` inspects ring/channel state
- `POST` publishes one event to the configured channel
- if later phases support publishing to arbitrary channels, that must be documented as an explicit contract change

### Request / Worker Lifecycle

- Control endpoint lives at `location` scope
- Writers append events to shared state
- Readers inspect or tail state from shared memory
- Multi-worker behavior is required before Phase 2 can be called complete

### Traceability and Audit Hooks

| Requirement / claim | Evidence today | Required future evidence |
|---|---|---|
| The scaffold control endpoint is explicitly unimplemented | `tests/worker-events/worker-events.test.js` | Keep placeholder behavior explicit until Phase 1 publish/introspection replaces it |
| Phase 1 introduces one bounded publish/introspection contract | Phase 1 TDD checklist | Bun tests for single-event publish, inspect response, invalid config, and unaffected neighboring routes |
| Phase 2 is not complete until cross-worker visibility is proven | Phase 2 TDD checklist | Multi-worker Bun tests for ordering, overflow, dropped-event accounting, and channel behavior |
| Phase 3 is stable enough for njs/native consumers | Phase 3 TDD checklist | Integration coverage for one real consumer path and any publish authorization added |

### Planned Consumers

- njs policy shells
- cache invalidation fanout
- session or token revocation propagation
- dynamic upstream / health state notifications

### Phase Plan

#### Phase 1 - Shared primitive and publish path

**Scope**

Replace the placeholder endpoint with a minimal publish/introspection surface backed by a simple shared structure.

**Implementation notes**

- Keep the first protocol narrow: one event shape, one publish path, one inspect path
- Prefer append-only semantics over complex acknowledgement logic
- Reject invalid config (ring size, zone name) early
- Phase 1 must state whether the shared-memory ring is already cross-worker or intentionally limited to one-worker validation only

**TDD checklist**

- [ ] Add a Bun test for publishing one event successfully
- [ ] Add a Bun test for inspecting current ring state
- [ ] Add a Bun test for invalid ring size or missing zone config
- [ ] Add a Bun test proving neighboring routes remain unaffected

**Implementation checklist**

- [ ] Replace `501` with a real publish/introspection JSON contract
- [ ] Implement config validation for zone, channel, and ring size
- [ ] Introduce the initial shared-memory ring structure
- [ ] Record event count and minimal metadata per event

**Exit criteria**

- One worker can publish an event and the endpoint can inspect the stored state
- Invalid config is rejected deterministically
- The README names the event entry fields, publish method, inspect method, and shared-memory layout used by Phase 1

#### Phase 2 - Cross-worker delivery semantics

**Scope**

Make the ring behavior deterministic enough for multi-worker coordination.

**Implementation notes**

- Choose and document one overflow policy, or make the policy explicitly configurable
- Add generation tracking so readers can reason about missed events
- Require `worker_processes 2` coverage before calling this phase complete

**TDD checklist**

- [ ] Add a multi-worker Bun test for cross-worker visibility of published events
- [ ] Add a Bun test for event ordering within one channel
- [ ] Add a Bun test for overflow and dropped-event accounting
- [ ] Add a Bun test for multiple channels if channel multiplexing is introduced in this phase

**Implementation checklist**

- [ ] Implement generation tracking and dropped-event accounting
- [ ] Define and enforce ring overflow semantics
- [ ] Ensure readers never observe corrupted partial event entries
- [ ] Add enough introspection to debug event loss and channel activity

**Exit criteria**

- Multi-worker tests prove one worker can publish and another can inspect the same event within the documented ring semantics
- Overflow behavior is explicit and observable
- The ring can be trusted for invalidation-class signals

#### Phase 3 - Consumer surface and policy hardening

**Scope**

Stabilize the module for njs-facing and operator-facing use.

**Implementation notes**

- njs subscription conventions belong here, not earlier
- Publish authorization and endpoint hardening should be explicit
- Keep consumer integration light enough that modules can adopt it incrementally

**TDD checklist**

- [ ] Add a Bun test for unauthorized publish rejection once auth exists
- [ ] Add an integration test for one real consumer path, such as cache invalidation fanout
- [ ] Add a test for consumer lag / missed-generation reporting if exposed

**Implementation checklist**

- [ ] Document and stabilize njs-facing event conventions
- [ ] Add publish authorization or operational guardrails
- [ ] Add consumer-oriented introspection for lag / missed events if needed

**Exit criteria**

- The README defines enough publish/inspect fields and error responses for one consumer module or njs package to integrate directly
- Introspection exposes enough fields to diagnose publish failure, overflow, and missed-generation conditions without raw memory inspection

### Failure Handling

- Invalid config should fail at config load time
- Invalid publish payloads should produce stable API errors
- Ring overflow must be bounded and observable, never silent corruption
- Shared-memory exhaustion must fail safely without breaking the worker

### Observability

The first useful implementation should expose:

- zone name
- channel name or channel id
- ring capacity
- last generation id
- dropped-event count

### Compatibility and Ordering Constraints

- Any shared-state phase requires explicit multi-worker tests before being considered complete
- Do not make this module depend on njs for its core correctness
- Keep it as a content/control module, not a filter
- Other modules should treat this as a transport primitive, not a policy engine

### Intentionally Not Supported Yet

- guaranteed delivery or acknowledgement semantics
- cross-node fanout
- workflow-specific subscription behavior owned by consumers
- replay/retention models beyond a bounded ring

### Open Questions

- Should overflow drop the oldest event, reject the newest publish, or expose both policies via configuration?
- What event payload size and serialization constraints keep the shared-memory ring simple enough to audit?
- Is channel multiplexing a Phase 2 concern, or should the first multi-worker version stay single-channel per endpoint?

### Example Target Config

```nginx
server {
    location /internal/worker-events {
        worker_events_api;
        worker_events_zone bus;
        worker_events_channel cache.invalidate;
        worker_events_ring_size 1024;
    }
}
```

### Deferred Work

- rich workflow orchestration semantics
- cross-node delivery
- advanced retention or replay models

### Documentation Audit Checklist

- [x] Audit date: 2026-05-03
- [x] Scaffolded Zig module and README exist under `src/modules/worker-events-nginx-module/`.
- [x] Placeholder API endpoint makes non-implemented state explicit.
- [x] README now includes phased checked todos and binary exit criteria for implementation.
- [x] Bun integration coverage exists at `tests/worker-events/` for placeholder JSON, `HEAD`, and unaffected-route behavior.
- [x] Current scaffold claims now trace to present tests and future phase-specific verification points.
