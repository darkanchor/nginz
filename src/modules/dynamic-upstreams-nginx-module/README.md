## Dynamic Upstreams Module

Planned runtime upstream reconfiguration module for updating peer tables without a full nginx reload.

### Status

**Phase 1 + Phase 2 complete; Phase 3 started** — truthful introspection and atomic full-snapshot replacement are implemented and tested. Worker-events fanout and operational status fields are now live; source polling and health-aware activation are still pending.

### Purpose and Boundaries

This module is the runtime control layer built on top of the upstream balancer foundation. Its job is to publish, validate, and safely activate new upstream peer snapshots without requiring a full nginx reload.

This module should own:

- control endpoint contract
- upstream membership validation
- snapshot generation/version bookkeeping
- safe activation of new peer sets

This module should **not** own:

- peer selection policy itself
- core health probing logic
- unrelated gateway APIs

### Current Scaffold Behavior

- `dynamic_upstreams_api` installs a placeholder JSON endpoint that returns HTTP `501`.
- The additional directives reserve configuration names and store stub values for future implementation.
- No peer-table updates, discovery integration, or background reconciliation are active yet.

### Current Scaffold Test Coverage

`tests/dynamic-upstreams/dynamic-upstreams.test.js` currently proves:

- the scaffold endpoint returns an explicit JSON `501 Not Implemented` response
- `HEAD` requests behave deterministically on the placeholder endpoint
- neighboring routes remain unaffected while the control surface is still scaffold-only

### Directive Surface

| Directive | Planned Syntax | Planned Context | Purpose |
|---|---|---|---|
| `dynamic_upstreams_api` | `;` | `location` | Expose the control endpoint for read/write upstream operations |
| `dynamic_upstreams_source` | `<consul|static>` | `location` | Select the reconciliation source for the endpoint |
| `dynamic_upstreams_target` | `<upstream_name>` | `location` | Bind the endpoint to an upstream group |
| `dynamic_upstreams_refresh` | `<milliseconds>` | `location` | Configure background reconciliation cadence |
| `dynamic_upstreams_worker_events_channel` | `<channel>` | `location` | Publish snapshot activation notifications to the worker-events default zone |

### Integration Points

- `src/modules/dynamic-upstreams-nginx-module/ngx_http_dynamic_upstreams.zig`
- `src/modules/upstream-balancer-nginx-module/README.md` and eventual runtime contract
- `src/modules/healthcheck-nginx-module/README.md` for future health-aware drain behavior
- `build.zig`
- `src/ngz_modules.zig`
- `project/build_package.zig`
- nginx request handling: location-scoped content handler serving a JSON control endpoint

### Milestone 2 Reminder

- `dynamic-upstreams` is not the direct blocker for current healthcheck completeness, but its snapshot/peer-identity contract must stay compatible with future health-aware peer filtering in `upstream-balancer`.
- When health-aware drain/remove behavior is added later, document it as an explicit cross-module contract with `healthcheck` and `upstream-balancer`, not as implicit mutation from this module.

### Data Model and Config

#### Planned location config shape

Document and implement fields for:

- API enabled flag
- target upstream name
- source mode (`static` first, `consul` later)
- refresh interval

Phase 1-2 config validation rules should include:

- `dynamic_upstreams_target` is required when `dynamic_upstreams_api` is enabled
- unsupported `dynamic_upstreams_source` values fail config load
- refresh values must be positive integers in milliseconds once background reconciliation is implemented

#### Planned runtime snapshot model

Use a snapshot-oriented model rather than in-place mutation:

- active generation id
- staged generation id
- immutable peer list per generation
- validation result / last update status

This module should document which fields must be shared with the upstream balancer contract and which remain private to control-plane logic.

### Planned API Contract

#### Phase 1 read response shape

The first truthful read-only response should be JSON with fields equivalent to:

- `module`: `dynamic_upstreams`
- `target`: upstream name
- `generation`: current active generation id
- `peers`: array of peer descriptors
- `source`: configured source mode

#### Phase 2 write request shape

The first writable snapshot request should be one explicit JSON schema, for example:

```json
{
  "peers": [
    { "address": "10.0.0.11:8080" },
    { "address": "10.0.0.12:8080" }
  ]
}
```

Before Phase 2 is called complete, the README must name:

- allowed HTTP write method
- accepted content type
- peer validation rules
- success and validation-error response shapes

### Request / Worker Lifecycle

- Control API lives at `location` scope
- Reads should serve current active snapshot state
- Writes should validate a full replacement snapshot before activation
- Background reconciliation should be a later phase, not a requirement for the first useful version

### Traceability and Audit Hooks

| Requirement / claim | Evidence today | Required future evidence |
|---|---|---|
| The scaffold endpoint is explicitly unimplemented rather than silently inert | `tests/dynamic-upstreams/dynamic-upstreams.test.js` | Keep placeholder behavior explicit until Phase 1 read-only introspection replaces it |
| Phase 1 is read-only and truthful about the bound upstream | Phase 1 TDD checklist | Bun tests for `GET`, `HEAD`, invalid target binding, and unaffected neighboring routes |
| Phase 2 snapshot replacement is atomic | Phase 2 TDD checklist | Bun tests for add/remove operations, malformed writes, and multi-worker visibility without partial reads |
| Phase 3 source-driven refresh preserves last good state on failure | Phase 3 TDD checklist | Bun tests for bounded refresh, stale-but-valid behavior, and documented drain semantics |

### Phase Plan

#### Phase 1 - Read-only control surface

**Scope**

Replace the placeholder endpoint with a truthful read-only API for one named upstream.

**Implementation notes**

- Keep the first version introspection-only
- Report what upstream the endpoint is bound to and what the current peer snapshot looks like
- Make bad target bindings fail clearly at config time or runtime, but not silently

**TDD checklist**

- [ ] Add a Bun test for `GET` returning a stable JSON shape
- [ ] Add a Bun test for `HEAD` on the control endpoint
- [ ] Add a Bun test for a missing or invalid target upstream name
- [ ] Add a Bun test proving neighboring routes remain unaffected
- [ ] Add a Bun test proving valid Phase 1 requests no longer return the scaffold `501` placeholder

**Implementation checklist**

- [ ] Replace `501` with a read-only JSON response for the bound upstream
- [ ] Validate and store the named target upstream in config
- [ ] Define the response schema for active peer snapshot reporting
- [ ] Emit clear errors for unsupported source modes in the current phase

**Exit criteria**

- `GET` returns the documented JSON fields for the configured upstream and `HEAD` remains consistent with that contract
- Invalid target bindings fail in one documented way: config-load rejection or runtime API error response
- The runtime still performs no peer mutation yet

#### Phase 2 - Safe snapshot replacement

**Scope**

Add controlled write support for replacing the active peer snapshot without partial reads.

**Implementation notes**

- Start with a simple static JSON payload or equivalent deterministic source
- Validate the full peer list before making it visible
- Use generation/version tracking so readers never observe a half-applied update

Peer validation rules must be written down before Phase 2 closes, including at least:

- address syntax expectations
- duplicate-peer handling
- whether weights or flags are accepted yet or rejected explicitly

**TDD checklist**

- [ ] Add a Bun test for adding peers to an upstream snapshot
- [ ] Add a Bun test for removing peers from an upstream snapshot
- [ ] Add a Bun test for rejecting malformed write payloads with stable error responses
- [ ] Add a multi-worker test proving readers never observe partial snapshot state

**Implementation checklist**

- [ ] Define write request schema and validation rules
- [ ] Introduce snapshot generation/version tracking
- [ ] Implement atomic active-snapshot replacement
- [ ] Reject invalid peer entries before activation
- [ ] Record last successful and last failed update state for inspection

**Exit criteria**

- A full peer snapshot can be replaced without reload
- Readers only see complete generations
- Validation failures leave the previously active generation readable and unchanged

#### Phase 3 - Reconciliation and operational depth

**Scope**

Add bounded source-driven refresh and operational behavior for production use.

**Implementation notes**

- `consul` integration should come only after the static write path is stable
- Drain/remove behavior should be documented explicitly
- Health-aware filtering should integrate with healthcheck state only after both contracts are documented

Bounded refresh must be made concrete before this phase closes, including:

- refresh interval source
- maximum retry/backoff behavior
- what state is returned while the last refresh attempt has failed

**TDD checklist**

- [ ] Add a Bun test for bounded refresh polling behavior
- [ ] Add a Bun test for source failure retaining last good snapshot
- [ ] Add a Bun test for drain semantics if they are introduced
- [ ] Add multi-worker verification for visibility of refreshed snapshots

**Implementation checklist**

- [ ] Implement source reconciliation loop with bounded retry/refresh policy
- [ ] Preserve last known good snapshot on source failure
- [ ] Document drain/remove semantics and compatibility with healthcheck
- [ ] Expose operational fields for active generation, source state, and last error

**Exit criteria**

- Source-driven reconciliation exposes documented refresh interval, last success, and last error fields
- Failure to refresh does not destroy the last good snapshot
- The read/write API contract is explicit enough that another module or operator can use it without reading Zig implementation details

### Failure Handling

- Unsupported methods should return deterministic API errors
- Invalid payloads should return stable validation errors instead of partial mutation
- Shared-memory exhaustion or snapshot allocation failures must preserve the last good state
- Source failures must degrade to stale-but-valid active state rather than empty state

### Observability

The control endpoint should eventually surface at least:

- target upstream name
- active generation id
- staged generation id if relevant
- peer count
- source mode
- last error / last successful refresh timestamp

### Compatibility and Ordering Constraints

- Do not implement this module ahead of the upstream-balancer peer identity contract
- Keep the module in the upstream-control area of `src/ngz_modules.zig`
- Do not make `worker-events` a hard dependency for the first useful version
- If healthcheck-aware behavior is added, document it as an integration contract rather than an implicit assumption

### Intentionally Not Supported Yet

- partial in-place peer mutation without full snapshot validation
- automatic `consul` reconciliation before static write-path semantics are stable
- `worker-events` fanout as a prerequisite for the first operational version
- implicit peer health filtering without a documented healthcheck contract

### Open Questions

- Should invalid `dynamic_upstreams_target` bindings fail entirely at config load, or remain a runtime API error for read-only endpoints?
- What exact write payload shape best matches the upstream-balancer peer identity contract without exposing nginx internals casually?
- Which snapshot bookkeeping fields must be shared across workers versus remaining private to control-plane inspection?

### Example Target Config

```nginx
http {
    upstream api_backend {
        server 10.0.0.11:8080;
        server 10.0.0.12:8080;
    }

    server {
        location /api/upstreams {
            dynamic_upstreams_api;
            dynamic_upstreams_target api_backend;
            dynamic_upstreams_source consul;
            dynamic_upstreams_refresh 5000;
        }
    }
}
```

### Deferred Work

- broad runtime API aggregation beyond upstream management
- automatic fanout over a worker event bus
- advanced source plugins beyond static and consul

### Documentation Audit Checklist

- [x] Audit date: 2026-05-03
- [x] Scaffolded Zig module and README exist under `src/modules/dynamic-upstreams-nginx-module/`.
- [x] Placeholder API endpoint is intentionally explicit about `501 Not Implemented` state.
- [x] README now includes phased checked todos and binary exit criteria for implementation.
- [x] Bun integration coverage exists at `tests/dynamic-upstreams/` for placeholder JSON, `HEAD`, and neighboring-route behavior.
- [x] Current scaffold claims now trace to present tests and future phase-specific verification points.

The `dynamic-upstreams` module is meant to solve a different problem from `upstream-balancer`.

In plain words: `upstream-balancer` decides which backend to pick for one request. `dynamic-upstreams` is supposed to change the backend list itself while nginx is still running, without doing a full reload.

So the design is basically this:

- `upstream-balancer` owns request-time routing.
- `dynamic-upstreams` owns runtime updates to the peer table.
- `healthcheck` may later influence which peers are usable.
- Service discovery like Consul is a possible input source later, not the core of the first implementation.

The README for [dynamic-upstreams]() is explicit that this module should act like a control plane, not a routing engine. It should expose an API endpoint, validate incoming upstream definitions, build a new immutable snapshot of peers, and then switch nginx over to that new snapshot safely.

That “snapshot” idea is the key design choice. Instead of editing the live peer list in place, it wants to build a complete new generation, validate it, and then atomically flip from old generation to new generation. That is the right instinct, because in-place mutation is how you get half-updated state, worker races, and crashes.

Right now, just like the balancer module, it is still mostly scaffolded. The API endpoint exists only as a placeholder and returns `501 Not Implemented`. The intended directives are:

- `dynamic_upstreams_api`
- `dynamic_upstreams_source <consul|static>`
- `dynamic_upstreams_target <upstream_name>`
- `dynamic_upstreams_refresh <milliseconds>`

The intended first useful version is read-only: expose a JSON view of one configured upstream and its current active snapshot. Only after that would it accept writes to replace the peer set.

The main technical challenges are more severe here than in a normal config API:

1. Atomicity across workers  
Nginx has multiple workers. If one worker sees the new peer set while another still sees the old one, that can be acceptable only if both snapshots are complete and valid. What cannot happen is partial visibility.

2. Safe lifetime management  
Requests may still be using the old peer snapshot while a new one becomes active. That means old generations cannot be freed too early.

3. Validation before activation  
A bad update must be rejected completely. Duplicate peers, malformed addresses, unsupported fields, or empty peer lists all need clear handling before anything becomes live.

4. Contract with the balancer  
This module cannot invent peer identity casually. Whatever peer IDs or generation semantics it uses must match what `upstream-balancer` expects for sticky routing. Otherwise affinity breaks the moment a snapshot changes.

5. No in-place mutation  
The README is pushing hard toward whole-snapshot replacement. That is because patching live upstream structures is much riskier than publishing a new immutable generation.

6. Truthful control API  
The API should reflect what is actually active, not what was last requested. If activation fails, the old generation must remain active and visible.

7. Future source integration  
Consul or refresh loops sound simple, but they add reconciliation problems: stale state, transient failures, partial discovery results, and “last known good” behavior. The README is right to defer that until the static write path is solid.

So in plain terms, the module is trying to become nginx’s runtime upstream update manager. Its design is conservative: read first, then safe whole-snapshot writes, then optional external reconciliation. The hard part is not serving JSON. The hard part is changing backend membership live, across workers, without races, broken stickiness, or memory lifetime bugs.

One useful way to think about the boundary is:

- `upstream-balancer`: “Which peer should this request use?”
- `dynamic-upstreams`: “What is the current set of peers at all?”

That separation is sound. The challenge is making the handoff between those two modules precise enough that dynamic updates do not destroy deterministic routing.

---

## Implementation Status (as of 2026-05-07)

### Phase 1 — Complete

- `GET` returns truthful JSON for the configured upstream (static peers or active snapshot).
- `HEAD` mirrors headers without body, content-length matches `GET`.
- `PUT`, `POST`, `DELETE`, and other methods return `405`.
- Neighboring routes are unaffected.
- `dynamic_upstreams_target` is resolved at config load; missing name fails config.
- `dynamic_upstreams_source` accepts only `static`; any other value fails config load.
- 4 integration tests pass.

### Phase 2 — Complete

Shared-memory snapshot replacement via `PUT`.

- `dynamic_upstreams_managed` inside an `upstream {}` block registers a 4 MB slab zone and wires the upstream into the balancer peer-source vtable via `upstream_balancer_ensure_hook` + `upstream_balancer_register_peer_source`.
- `PUT` with `{"peers":[{"address":"IP:port","weight":N},...]}` validates the full peer list, builds a new `Snapshot` + `ngx_http_upstream_rr_peers_t` peer graph entirely in slab memory, atomically swaps `store->active`, and marks the previous snapshot as draining.
- Draining snapshots are freed only when their refcount reaches zero (opportunistically after `PUT` and lazily on the last `du_release_generation` call that decrements to zero).
- `GET` pins the active snapshot (increments refcount under slab mutex) before iterating peers, then releases it after the JSON body is built — no use-after-free under concurrent `PUT`.
- Validation rejects: empty peer list, peer count > 256, non-IP addresses (hostnames), weight outside 1–65535, missing `address` field, invalid JSON.
- `flags.weighted` is set to `true` when any peer weight ≠ 1, enabling nginx round-robin's weighted selection path.
- Zone init handles config reload (reuse of previous slab store) and multi-worker first-init race via `shpool->data`.
- 9 integration tests pass.

### Implemented directive surface

| Directive | Context | Effect |
|---|---|---|
| `dynamic_upstreams_managed` | `upstream {}` | Registers shared-memory zone and balancer vtable hook for this upstream |
| `dynamic_upstreams_api` | `location` | Installs the GET/PUT control handler |
| `dynamic_upstreams_target <name>` | `location` | Binds the endpoint to a named upstream; resolved at config time |
| `dynamic_upstreams_source static` | `location` | Accepted but no-op in Phase 2; any other value fails config load |
| `dynamic_upstreams_refresh <ms>` | `location` | Parsed and validated; still unused until source polling lands |
| `dynamic_upstreams_worker_events_channel <channel>` | `location` | Optional worker-events fanout channel for `snapshot_activated` notifications |

### Phase 3 — In progress

Implemented in this slice:

- **Worker-events fanout**: successful `PUT` publishes a `snapshot_activated` event to the configured `dynamic_upstreams_worker_events_channel`.
- **Operational fields**: `GET` now exposes `last_success_at_msec`, `last_error_at_msec`, and `last_error_code`.
- **Write-path guardrail**: `PUT` now requires `Content-Type: application/json` and records request-level failures in shared state for inspection.
- **Multi-worker verification**: a Phase 3 test config with `worker_processes 2` verifies snapshot activation plus worker-events visibility.

Still pending:

- **Source polling**: timer-driven reconciliation loop, initially for a `static` file source, then `consul`. Must preserve last-good snapshot on source failure and document bounded retry/backoff.
- **Health-aware activation**: at `PUT` time, query healthcheck state and exclude peers that are currently failing. Must apply at activation boundaries only — healthcheck must not mutate the active snapshot out of band.
- **`dynamic_upstreams_refresh` enforcement**: wire the stored interval into the Phase 3 polling timer.

---

## Known Limitations / Technical Debt

These items are working but suboptimal or incomplete in the Phase 1+2 implementation.

### 1. Long slab mutex hold during `PUT`

All slab allocations for a new snapshot (Snapshot struct, peers struct, N × peer_t, N × sockaddr, N × name strings) happen while holding `shpool->mutex`. For large peer lists this blocks all workers' slab operations (including those on other upstreams sharing the same zone) for the duration of the entire build loop.

**Better**: allocate outside the lock using a pool-backed staging area or per-call `ngx_slab_calloc`, then hold the mutex only for the pointer swap. Deferred to Phase 3 hardening.

### 2. Slab mutex on every proxied request (`du_get_active_peers`)

`du_get_active_peers` is called on every upstream connection to pin the active snapshot. It acquires and releases `shpool->mutex` to safely read `store->active` and increment the refcount atomically. At high request rates this becomes contention on a single shared lock.

**Better**: a dedicated per-store spinlock or an atomic compare-and-swap loop for the refcount increment, leaving the slab mutex for allocations only. Deferred to Phase 3 hardening.

### 3. Source polling and health-aware activation are still absent

Phase 3 now covers operational metadata and worker-events fanout, but the control plane still only supports explicit static `PUT` replacement. There is no timer-driven refresh loop yet, and no activation-time filtering against healthcheck state.

**Fix**: add bounded polling first, then layer health-aware activation on top of the existing healthcheck peer-eligibility contract.
