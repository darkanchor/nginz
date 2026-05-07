## Dynamic Upstreams Module

Runtime upstream reconfiguration module for updating peer tables without a full nginx reload.

### Status

**Phase 1 + Phase 2 complete; Phase 3 nearly complete** — truthful introspection, atomic full-snapshot replacement, worker-events fanout, operational status fields, bounded static-file polling, and health-aware activation are implemented and tested. `consul` source support is the remaining Phase 3 gap.

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

### Current Behavior

- `dynamic_upstreams_api` installs a real `GET` / `HEAD` / `PUT` control endpoint.
- `dynamic_upstreams_target <name>` binds the endpoint to a named upstream and is validated at config load.
- `dynamic_upstreams_managed` registers a shared-memory snapshot store and the peer-source handoff used by `upstream-balancer`.
- `GET` exposes the active generation, current peers, source mode, and operational fields such as `last_success_at_msec`, `last_error_at_msec`, and `last_error_code`.
- `PUT` accepts whole-snapshot replacement with pool/slab-backed validation, duplicate-peer rejection, and last-good preservation on failure.
- `dynamic_upstreams_source static` plus `dynamic_upstreams_source_file` and `dynamic_upstreams_refresh` enables worker-0 polling of a JSON source file with no-op refresh on unchanged content.
- Successful activation can publish a `snapshot_activated` event through `dynamic_upstreams_worker_events_channel`.
- Health-aware activation filters candidate peers through `ngz_healthcheck_is_peer_eligible()` before making a generation live.

### Current Test Coverage

`tests/dynamic-upstreams/dynamic-upstreams.test.js` now proves:

- truthful `GET` / `HEAD` behavior for static peers and active snapshots
- whole-snapshot replacement through `PUT`
- validation failures preserve the previous generation
- duplicate peers are rejected
- content-type enforcement and deterministic `405` / `415` responses
- worker-events fanout on activation
- static-file polling with last-good preservation on source failure
- health-aware activation and re-inclusion after recovery

### Directive Surface

| Directive | Syntax | Context | Purpose |
|---|---|---|---|
| `dynamic_upstreams_managed` | `;` | `upstream` | Register a managed shared-memory snapshot store and balancer handoff for this upstream |
| `dynamic_upstreams_api` | `;` | `location` | Expose the control endpoint for read/write upstream operations |
| `dynamic_upstreams_source` | `<consul\|static>` | `location` | Select the reconciliation source for the endpoint |
| `dynamic_upstreams_source_file` | `<path>` | `location` | Provide the JSON snapshot file used by `dynamic_upstreams_source static` |
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

Current write contract:

- allowed write method: `PUT`
- accepted content type: `application/json`
- peer validation rules:
  - non-empty `peers` array
  - each `address` must be an IP literal plus port
  - duplicate peer addresses are rejected
  - malformed JSON or missing required fields fail without changing the active generation
- success responses return the activated generation and peer count
- validation failures preserve the previously active generation

### Request / Worker Lifecycle

- Control API lives at `location` scope
- Reads should serve current active snapshot state
- Writes should validate a full replacement snapshot before activation
- Background reconciliation should be a later phase, not a requirement for the first useful version

### Traceability and Audit Hooks

| Requirement / claim | Evidence |
|---|---|
| `GET` / `HEAD` are truthful about the bound upstream | `tests/dynamic-upstreams/dynamic-upstreams.test.js` Phase 1 block |
| Snapshot replacement is atomic and preserves last good state on validation failure | same test file, Phase 2 block |
| Source-driven refresh preserves last good state on failure | same test file, refresh block |
| Worker-events fanout publishes activation notifications | same test file, Phase 3 worker-events block |
| Health-aware activation excludes ineligible peers and re-admits them after recovery | same test file, health-aware block |

### Phase Status

#### Phase 1 - Read-only control surface

- [x] `GET` returns truthful JSON for the configured upstream
- [x] `HEAD` mirrors the read contract headers without a body
- [x] neighboring routes remain unaffected
- [x] target binding is validated at config load

#### Phase 2 - Safe snapshot replacement

- [x] `PUT` performs whole-snapshot replacement without reload
- [x] readers only see complete generations
- [x] invalid payloads preserve the previously active generation
- [x] duplicate-peer rejection and peer validation are test-backed

#### Phase 3 - Reconciliation and operational depth

- [x] bounded static-file polling is implemented
- [x] source failure preserves the last good snapshot
- [x] worker-events fanout on activation is implemented
- [x] operational fields for last success and last error are exposed
- [x] health-aware activation is implemented
- [ ] `consul` source mode remains the last meaningful gap

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

### Rationale

The `dynamic-upstreams` module is meant to solve a different problem from `upstream-balancer`.

In plain words: `upstream-balancer` decides which backend to pick for one request. `dynamic-upstreams` is supposed to change the backend list itself while nginx is still running, without doing a full reload.

So the design is basically this:

- `upstream-balancer` owns request-time routing.
- `dynamic-upstreams` owns runtime updates to the peer table.
- `healthcheck` may later influence which peers are usable.
- Service discovery like Consul is a possible input source later, not the core of the first implementation.

The README for [dynamic-upstreams]() is explicit that this module should act like a control plane, not a routing engine. It should expose an API endpoint, validate incoming upstream definitions, build a new immutable snapshot of peers, and then switch nginx over to that new snapshot safely.

That “snapshot” idea is the key design choice. Instead of editing the live peer list in place, it wants to build a complete new generation, validate it, and then atomically flip from old generation to new generation. That is the right instinct, because in-place mutation is how you get half-updated state, worker races, and crashes.

The current implementation now covers that design through a real read/write control API, atomic whole-snapshot activation, bounded static-source polling, worker-events fanout, and health-aware activation. The one remaining source adapter gap is `consul`.

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
| `dynamic_upstreams_source static` | `location` | Enables static-source semantics; `consul` still fails config load |
| `dynamic_upstreams_source_file <path>` | `location` | Absolute or config-prefixed JSON file used by the refresh timer |
| `dynamic_upstreams_refresh <ms>` | `location` | Enables worker-0 polling of the static source file at the configured interval |
| `dynamic_upstreams_worker_events_channel <channel>` | `location` | Optional worker-events fanout channel for `snapshot_activated` notifications |

### Phase 3 — Nearly complete

Implemented in this slice:

- **Worker-events fanout**: successful `PUT` publishes a `snapshot_activated` event to the configured `dynamic_upstreams_worker_events_channel`.
- **Operational fields**: `GET` now exposes `last_success_at_msec`, `last_error_at_msec`, and `last_error_code`.
- **Write-path guardrail**: `PUT` now requires `Content-Type: application/json` and records request-level failures in shared state for inspection.
- **Multi-worker verification**: a Phase 3 test config with `worker_processes 2` verifies snapshot activation plus worker-events visibility.
- **Static source polling**: worker `0` owns a cancelable timer that reloads a JSON snapshot from `dynamic_upstreams_source_file` every `dynamic_upstreams_refresh` milliseconds.
- **Last-good preservation**: unreadable or invalid source files update shared error state but do not replace the active generation.
- **No-op refresh on unchanged source**: polling the same peer list does not churn generations or emit duplicate activation events.
- **Health-aware activation**: both `PUT` and timer-driven refresh filter candidate peers through `ngz_healthcheck_is_peer_eligible()` before activation and keep the last good snapshot if every peer is currently ineligible.

Still pending:

- **`consul` source mode**: source-driven reconciliation is implemented only for `static` files in this phase.

---

## Known Limitations / Technical Debt

These items are working but suboptimal or incomplete in the Phase 1+2 implementation.

### 1. Long slab mutex hold during `PUT`

All slab allocations for a new snapshot (Snapshot struct, peers struct, N × peer_t, N × sockaddr, N × name strings) happen while holding `shpool->mutex`. For large peer lists this blocks all workers' slab operations (including those on other upstreams sharing the same zone) for the duration of the entire build loop.

**Better**: allocate outside the lock using a pool-backed staging area or per-call `ngx_slab_calloc`, then hold the mutex only for the pointer swap. Deferred to Phase 3 hardening.

### 2. Slab mutex on every proxied request (`du_get_active_peers`)

`du_get_active_peers` is called on every upstream connection to pin the active snapshot. It acquires and releases `shpool->mutex` to safely read `store->active` and increment the refcount atomically. At high request rates this becomes contention on a single shared lock.

**Better**: a dedicated per-store spinlock or an atomic compare-and-swap loop for the refcount increment, leaving the slab mutex for allocations only. Deferred to Phase 3 hardening.

### 3. `consul` source mode is still absent

Phase 3 now covers operational metadata, worker-events fanout, bounded static-file polling, and health-aware activation, but `consul` is still rejected at config load because this module does not yet expose a source-specific discovery contract.

**Fix**: add a documented `consul` source adapter with the same last-good semantics as the static file source.
