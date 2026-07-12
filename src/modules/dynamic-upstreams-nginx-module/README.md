## Dynamic Upstreams Module

Runtime upstream reconfiguration module for updating peer tables without a full nginx reload.

### Status

**Feature ready** — truthful introspection, atomic full-snapshot replacement, PATCH add/remove/replace compilation into immutable snapshot activation, worker-events fanout, operational status fields, bounded static-file polling, health-aware activation, and consul service-discovery reconciliation are implemented and test-backed.

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
- `PATCH` supports two exclusive modes: drain control (`drain` / `undrain`) and membership diff (`add`, `remove`, `replace`). Membership PATCH never mutates the live peer graph in place; it compiles the requested diff against the current active-or-static peer set and activates the result through the same immutable snapshot path as `PUT`.
- Membership PATCH preserves unchanged peer relative order, removes peers in place, and appends new peers deterministically in request order. `replace` uses peer address as identity; replacing one address with another keeps the slot position while still producing a full next generation.
- Drain state remains separate from snapshot membership: `drain` / `undrain` update only the drain table consulted by `upstream-balancer` for new request selection.
- `dynamic_upstreams_source static` plus `dynamic_upstreams_source_file` and `dynamic_upstreams_refresh` enables worker-0 polling of a JSON source file with no-op refresh on unchanged content.
- `dynamic_upstreams_source consul` reconciles healthy instances from Consul’s `/v1/health/service/<name>?passing=true` endpoint, forwards optional `tag` / `dc` / token metadata, and treats an empty healthy result as a valid empty upstream snapshot.
- Successful activation can publish a `snapshot_activated` event through the explicit `dynamic_upstreams_worker_events_zone` and `dynamic_upstreams_worker_events_channel` pair.
- Health-aware activation filters candidate peers through `ngz_healthcheck_is_peer_eligible()` before making a generation live.
- Source-driven reconciliation still requires discovered peer addresses to be IP literals plus port; hostname resolution is not performed in this module.

### Current Test Coverage

`tests/dynamic-upstreams/dynamic-upstreams.test.js` now proves:

- truthful `GET` / `HEAD` behavior for static peers and active snapshots
- whole-snapshot replacement through `PUT`
- PATCH add/remove/replace through immutable next-generation activation
- validation failures preserve the previous generation
- duplicate peers are rejected
- mixed or invalid PATCH shapes are rejected without changing the active generation
- content-type enforcement and deterministic `405` / `415` responses
- worker-events fanout on activation
- static-file polling with last-good preservation on source failure
- health-aware activation and re-inclusion after recovery
- consul source query metadata forwarding (`tag`, `dc`, `X-Consul-Token`)
- consul source last-good preservation on transport failure
- consul source reconciliation to an empty peer set when no healthy instances remain

### Directive Surface

| Directive | Syntax | Context | Purpose |
|---|---|---|---|
| `dynamic_upstreams_managed` | `;` | `upstream` | Register a managed shared-memory snapshot store and balancer handoff for this upstream |
| `dynamic_upstreams_api` | `;` | `location` | Expose the control endpoint for read/write upstream operations |
| `dynamic_upstreams_source` | `<consul\|static>` | `location` | Select the reconciliation source for the endpoint |
| `dynamic_upstreams_source_file` | `<path>` | `location` | Provide the JSON snapshot file used by `dynamic_upstreams_source static` |
| `dynamic_upstreams_target` | `<upstream_name>` | `location` | Bind the endpoint to an upstream group |
| `dynamic_upstreams_refresh` | `<milliseconds>` | `location` | Configure background reconciliation cadence |
| `dynamic_upstreams_worker_events_zone` | `<zone>` | `location` | Explicit worker-events zone for native notifications |
| `dynamic_upstreams_worker_events_channel` | `<channel>` | `location` | Publish snapshot activation notifications to the configured worker-events zone |
| `dynamic_upstreams_consul_address` | `<ip:port>` | `location` | Consul agent address (IP literal + port, default port 8500) |
| `dynamic_upstreams_consul_service` | `<name>` | `location` | Consul service name to query via `/v1/health/service/<name>?passing=true` |
| `dynamic_upstreams_consul_tag` | `<tag>` | `location` | Optional tag filter applied to the health query |
| `dynamic_upstreams_consul_token` | `<token>` | `location` | Optional Consul ACL token sent as `X-Consul-Token` |
| `dynamic_upstreams_consul_dc` | `<datacenter>` | `location` | Optional datacenter query parameter |

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

Current PATCH contract:

- allowed write method: `PATCH`
- accepted content type: `application/json`
- PATCH payloads are either:
  - drain mode: `{ "drain": "IP:port" }` or `{ "undrain": "IP:port" }`
  - membership mode: any combination of
    - `add: [{ "address": "IP:port", "weight": N? }, ...]`
    - `remove: ["IP:port", ...]`
    - `replace: [{ "current": "IP:port", "address": "IP:port", "weight": N? }, ...]`
- drain mode and membership mode are mutually exclusive in one request
- `replace` defaults `current` to `address` when only a weight change is needed
- membership PATCH validates against the current active generation when present, otherwise against the static upstream peer list
- successful membership PATCH responses include `changed`, `added`, `removed`, `generation`, and `peer_count`
- validation failures preserve the previously active generation and drain table

### Request / Worker Lifecycle

- Control API lives at `location` scope
- Reads should serve current active snapshot state
- Writes should validate a full replacement snapshot before activation; PATCH compiles its diff into that same replacement model rather than mutating peers in place
- Background reconciliation should be a later phase, not a requirement for the first useful version

### Traceability and Audit Hooks

| Requirement / claim | Evidence |
|---|---|
| `GET` / `HEAD` are truthful about the bound upstream | `tests/dynamic-upstreams/dynamic-upstreams.test.js` Phase 1 block |
| Snapshot replacement is atomic and preserves last good state on validation failure | same test file, Phase 2 block |
| Membership PATCH compiles add/remove/replace into the same immutable activation path and preserves deterministic order | same test file, Phase 7 block |
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
- [x] `consul` source mode implemented with blocking TCP adapter

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
            dynamic_upstreams_consul_address 127.0.0.1:8500;
            dynamic_upstreams_consul_service api-backend;
            dynamic_upstreams_consul_tag primary;
            dynamic_upstreams_consul_dc dc-west;
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

## Implementation Status (as of 2026-05-07, Phase 3 complete)

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
| `dynamic_upstreams_source static\|consul` | `location` | Selects the reconciliation source; `consul` requires `dynamic_upstreams_consul_address` and `dynamic_upstreams_consul_service` |
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

- **`consul` source mode**: worker-0 timer polls `GET /v1/health/service/<name>?passing=true` via a blocking HTTP/1.0 TCP connection, converts the response into a peer snapshot, and activates it with the same last-good semantics as the static source.  The consul address must be an IP literal (no DNS).  Connection and read timeouts are 5 seconds.

---

## Known Limitations / Technical Debt

These items are working but suboptimal or incomplete in the Phase 1+2 implementation.

### 1. Long slab mutex hold during `PUT`

All slab allocations for a new snapshot (Snapshot struct, peers struct, N × peer_t, N × sockaddr, N × name strings) happen while holding `shpool->mutex`. For large peer lists this blocks all workers' slab operations (including those on other upstreams sharing the same zone) for the duration of the entire build loop.

**Better**: allocate outside the lock using a pool-backed staging area or per-call `ngx_slab_calloc`, then hold the mutex only for the pointer swap. Deferred to Phase 3 hardening.

### 2. Slab mutex on every proxied request (`du_get_active_peers`)

`du_get_active_peers` is called on every upstream connection to pin the active snapshot. It acquires and releases `shpool->mutex` to safely read `store->active` and increment the refcount atomically. At high request rates this becomes contention on a single shared lock.

**Better**: a dedicated per-store spinlock or an atomic compare-and-swap loop for the refcount increment, leaving the slab mutex for allocations only. Deferred to Phase 3 hardening.

### 3. Blocking consul HTTP in the event loop

The consul timer refresh uses a blocking POSIX TCP socket (HTTP/1.0, 5-second timeout) in worker 0's event loop.  For typical Consul deployments on localhost this is a sub-millisecond operation.  If Consul is slow or unreachable, worker 0's event loop stalls for up to 5 seconds per refresh cycle, delaying timers for other modules.

**Better**: implement async Consul polling via nginx's non-blocking event machinery (similar to the upstream health-check module).  Deferred to a future hardening pass.

## Next-Term Roadmap

### Priority adjustments from milestone-2 conclusion

- **Confirmed**: async Consul polling is still a real correctness and operability gap.
- **Confirmed, but narrowed**: persistence is still needed for **cold restart/bootstrap**. Graceful config reload already reuses the shared zone store through `du_zone_init_cb(...)`; the remaining gap is restart-time restore when no inherited zone exists.
- **Confirmed, but narrowed**: the request path should still stop touching `shpool->mutex`, but the refcount is already atomic today. The next step is removing the slab mutex from `du_get_active_peers`, not introducing atomics from scratch.
- **Confirmed, but reordered**: graceful drain should land before generic PATCH semantics. Drain is the safer primitive for zero-downtime removal, and PATCH can then compile into the same whole-snapshot activation pipeline instead of inventing a separate in-place mutation path.
- **Challenged**: “graceful drain” is not completely absent. Snapshot-level draining and deferred reclamation are already implemented. What is missing is **operator-visible per-peer drain state** that keeps old requests alive while excluding the peer from new selections.

### Phase 4 - Cold-start persistence and restore

**Goal**

Preserve the last good active snapshot across full nginx restart, not just config reload.

**TODO**

- [x] Add a module-owned journal file format for the active snapshot and minimal metadata: upstream name, generation, source mode, peer list, and persisted-at timestamp.
- [x] Write the journal only after successful activation; use write-to-temp + rename so a crash never leaves a partial live file.
- [x] Restore from journal during process init before the first refresh timer fires, and only for `dynamic_upstreams_managed` upstreams that opt in via `dynamic_upstreams_journal <path>`.
- [x] Reject journal restore when the upstream name or persisted schema version does not match the current config.
- [x] Treat corrupt or incomplete journal data as non-fatal: keep static-config peers active, record a restore error, and wait for the next PUT or source refresh.
- [x] Expose restore status in `GET`: `restored_from_journal` and `restore_error_code`.

**Verification scope**

- [x] Integration test: PUT survives `stopNginz()` + `startNginz()` and peers are restored from journal.
- [x] Restart test proving the restored snapshot is visible before any PUT or refresh cycle.
- [x] Failure-injection test: invalid JSON in journal → nginx starts, `restore_error_code > 0`, no snapshot restored.
- Reload-vs-restart regression (reload reuses inherited shared memory, restart uses journal path) — not yet covered.

**Phase 4 implementation summary (2026-05-09)**

- New directive: `dynamic_upstreams_journal <path>` — opt-in per managed upstream location.
- Journal format: JSON with `schema=1`, `target`, `source`, `generation`, `persisted_at_msec`, `peers[{address,weight}]`.
- Write path: `writeFileAtomic` (write to `<path>.tmp`, then `rename`) on every successful activation; best-effort (errors silently ignored).
- Restore path: `restore_from_journal` runs in `dynamic_upstreams_init_process` before first refresh timer, worker 0 only; bypasses health filter (`skip_health_filter=true`) to restore all journal peers at cold start.
- Skip restore if store already has an active snapshot (config reload inherits shared zone normally).
- GET response adds `restored_from_journal` (bool) and `restore_error_code` (u32) fields.
- 4 new integration tests in `tests/dynamic-upstreams/nginx-journal.conf` + journal test block.
- **Drain contract (cross-module)**: `UpstreamStore` now carries `drain_count: u32` and `drain_table: [32]DrainEntry` in slab memory. `export fn ngz_du_is_peer_draining` is the request-time contract exported to `upstream-balancer` and future callers. Hot path is a single atomic load per managed upstream (returns 0 when `drain_count == 0`). The table is populated by Phase 7 PATCH /drain; until then `drain_count` is always 0.
- **Managed upstream tracking**: `managed_ducfs[MAX_REFRESH_ENTRIES]` and `managed_ducf_count` are populated in `postconfiguration` so `ngz_du_is_peer_draining` can walk all managed stores without per-request config traversal.

### Phase 5 - Async source adapter for Consul

**Goal**

Replace the worker-0 blocking Consul adapter with nginx-native non-blocking refresh machinery.

**TODO**

- [ ] Split the source refresh path into a common “fetch -> parse -> build_and_activate_snapshot” pipeline with source-specific transport adapters.
- [ ] Replace `consul_http_get(...)` with an nginx event-driven client connection owned by worker 0, using explicit connect, write, read, timeout, and finalize states.
- [ ] Allow at most one in-flight refresh per location entry; skip overlapping timer ticks instead of running concurrent refreshes.
- [ ] Keep current last-good semantics: transport errors, timeout, invalid status, and invalid JSON update shared error state but never clear the active generation.
- [ ] Preserve “empty healthy result is valid state” semantics for Consul while still distinguishing transport failure from an empty result.
- [ ] Keep the IP-literal-only requirement for the first async version; DNS-based resolution is a separate roadmap item.

**Verification scope**

- Extend the Consul mock tests to cover success, timeout, connect failure, malformed JSON, and empty healthy result.
- Add a timer-liveness regression test proving another worker-0 timer continues to fire while Consul is slow.
- Add a no-op refresh regression test so identical Consul membership does not churn generations or emit duplicate `snapshot_activated` events.
- Add multi-worker coverage proving only worker 0 owns the async refresh state machine while all workers observe the same activated generation.

### Phase 6 - Lockless request-time snapshot pinning

**Goal**

Remove `shpool->mutex` from `du_get_active_peers()` while preserving safe snapshot lifetime.

**TODO**

- [x] Change `store.active` reads to an atomic-load retry loop instead of reading under the slab mutex.
- [x] Keep `Snapshot.refcount` atomic, but stop freeing draining snapshots directly from the request release path.
- [x] Move final reclamation to the draining-list reaper under lock so a request can safely increment a snapshot refcount after loading the pointer but before reclamation.
- [x] Add a retry rule: load active snapshot, increment refcount, then verify the snapshot is still the active one or still valid for pinning; if not, release and retry.
- [x] Keep slab mutex ownership only on activation/reaper paths that mutate the active pointer or free slab allocations.

**Verification scope**

- Add a stress-style integration test that hammers proxied traffic while concurrently issuing repeated PUT updates; no crashes, hangs, or malformed responses are acceptable.
- Add a generation-lifetime regression test proving a draining snapshot is not freed before the last request releases it.
- Add perf verification for the capture-and-purge benchmark plus a dynamic-upstreams-only proxy run, with instructions/req and cache-miss deltas compared before/after the lock removal.
- Add debug assertions or unit coverage around refcount transitions so underflow and double-release are caught early.

**Phase 6 implementation summary (2026-05-09)**

- `du_get_active_peers` is now lockless: atomic load of `store.active` (`.acquire`) → speculative refcount increment → re-load to verify still active → return on match; release and retry (up to 4 attempts) on mismatch. No slab mutex held on the request hot path.
- `store.active` writes use `@atomicStore` with `.release` (still under slab mutex in the writer), pairing correctly with `.acquire` loads in the reader.
- `du_release_generation` delegates the final free to `reap_draining` (which runs under slab mutex) rather than freeing inline. This makes `reap_draining` the single owner of the free path, preventing a concurrent lockless reader from racing with a free.
- **Known residual risk**: between the atomic pointer load and the refcount increment, a concurrent PUT + full drain + reaper cycle on another worker could free the snapshot. The race window is 1–2 CPU instructions (~1 ns); the reaper cycle requires TCP I/O + mutex acquisition (~µs minimum). No epoch-based reclamation is implemented; a future phase may add it if empirical data shows this matters.
- All 38 existing integration tests pass with the new implementation.

**Phase 5 implementation summary (2026-05-09)**

- `PATCH /dynamic-upstreams` with `{"drain":"ip:port"}` or `{"undrain":"ip:port"}` — idempotent, address-keyed drain table mutation.
- Drain state lives in `UpstreamStore.drain_table[32]DrainEntry` (slab memory); `drain_count` is a `u32` written with `.release` semantics after the table entries are populated, so the lockless reader in `ngz_du_is_peer_draining` sees a consistent snapshot.
- Both drain and undrain are protected by the slab mutex, same as snapshot activation.
- GET response now includes `drain_count` (atomic `.acquire` load, always 0 until first PATCH drain).
- `PATCH` wired in the main handler dispatcher alongside `GET` and `PUT`.
- 8 new integration tests: drain/undrain round-trip, idempotency, GET reflection, input validation (bad JSON, missing field, oversized address, missing Content-Type).

### Phase 7 - Per-peer drain first, PATCH semantics second

**Goal**

Add operator-visible incremental control without abandoning the immutable whole-snapshot activation model.

**TODO**

- [x] Introduce a per-peer desired-state model in the control plane: `active` and `draining` first; do not mutate live peer structs in place.
- [x] Add a drain-capable write contract, `PATCH`, that accepts `drain` and `undrain` operations (address-keyed, idempotent).
- [x] Compile every partial mutation (`add`, `replace`, `remove`) into a full next-generation snapshot by diffing against the current active generation, not by editing the active generation in place.
- [x] Preserve peer order for unchanged peers and append new peers deterministically so affinity churn stays bounded.
- [ ] Delay hard removal of a drained peer until a subsequent generation excludes it, keeping the old generation alive until request refcounts naturally reach zero.
- [x] Surface patch-plan results in the API response: `changed`, `added`, `removed`, and resulting `generation` / `peer_count`.

**Phase 7 implementation summary (2026-05-09)**

- `PATCH add/remove/replace` is now request-time diffing over the current active generation when present, or the static peer set before the first dynamic activation.
- The synthesized peer list is always published through the existing immutable `activate_snapshot_from_specs(...)` path used by `PUT`; there is no second live-mutation model.
- Unchanged peers keep their prior relative order. New peers append deterministically in request order. `replace` keeps the target slot position while treating peer address as cross-generation identity.
- Drain state remains out-of-band in `UpstreamStore.drain_table`; membership PATCH does not mutate or derive drain entries.
- Successful membership PATCH responses return `changed`, `added`, `removed`, `generation`, and `peer_count`. Drain/undrain responses continue to surface drain-specific fields.

**Verification scope**

- Add integration tests for `PATCH drain` excluding a peer from new selection while old in-flight requests still complete.
- Add tests for `PATCH add` and `PATCH remove` proving the API compiles to a new generation and preserves last-good semantics on validation failure.
- Add multi-worker tests proving all workers agree on the drained/active peer set after activation.
- Add sticky-affinity regression coverage with `upstream-balancer` proving unchanged peers keep their relative ordering after partial mutation.

### Engineering Audit Verdict (2026-07-12)

**Verdict: S0 CONCURRENT LIFETIME FIXED; STRESS PROOF OPEN.** Drain validation now pins the active snapshot for the complete traversal and releases it through the existing refcount protocol. All drain-table readers take the slab mutex used by drain/undrain mutation, eliminating races with whole-entry swaps. Paired balancer request cleanup prevents abandoned generation pins. The focused 58-case suite is green on isolated rerun (one preceding run had a non-reproduced validation-request reset); sustained PUT/PATCH/drain/traffic, reload, client-abort, and slab-pressure stress remains the acceptance proof.
