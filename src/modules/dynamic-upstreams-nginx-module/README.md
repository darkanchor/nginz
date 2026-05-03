## Dynamic Upstreams Module

Planned runtime upstream reconfiguration module for updating peer tables without a full nginx reload.

### Status

**Planning / scaffolded** - module wiring and placeholder API surface exist. Runtime peer-table mutation is not implemented yet.

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

### Integration Points

- `src/modules/dynamic-upstreams-nginx-module/ngx_http_dynamic_upstreams.zig`
- `src/modules/upstream-balancer-nginx-module/README.md` and eventual runtime contract
- `src/modules/healthcheck-nginx-module/README.md` for future health-aware drain behavior
- `build.zig`
- `src/ngz_modules.zig`
- `project/build_package.zig`
- nginx request handling: location-scoped content handler serving a JSON control endpoint

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
