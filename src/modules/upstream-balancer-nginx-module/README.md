## Upstream Balancer Module

Planned upstream balancer and sticky-session foundation for nginx peer selection in Zig.

### Status

**Planning / scaffolded** - module directory, exported Zig module, package wiring, and placeholder directive surface exist. Runtime peer selection is not implemented yet.

### Purpose and Boundaries

This module is the native foundation for upstream peer selection policy. Its purpose is to take ownership of the risky nginx upstream callback surface in a small, auditable Zig implementation before dynamic upstream mutation is added on top.

This module should stay focused on:

- upstream peer selection callbacks
- sticky affinity inputs and policy evaluation
- peer metadata needed by selection
- compatibility handoff to `dynamic-upstreams`

This module should **not** own:

- runtime add/remove of peers
- service discovery polling
- health probing itself
- broad operational APIs unrelated to peer selection

### Current Scaffold Behavior

- The scaffold reserves directive names and build/package/module wiring.
- No sticky policy, peer override, or runtime metadata is active yet.
- Proxy traffic should remain equivalent to stock nginx behavior until a real selection policy is implemented.

### Current Scaffold Test Coverage

`tests/upstream-balancer/upstream-balancer.test.js` currently proves:

- the scaffold directives are accepted by nginx config parsing
- proxy traffic still reaches the backend successfully
- cookie/header affinity inputs do not break stock proxy behavior while sticky selection is still unimplemented

### Directive Surface

| Directive | Planned Syntax | Planned Context | Purpose |
|---|---|---|---|
| `upstream_balancer_sticky_cookie` | `<cookie_name>` | `upstream` | Enable cookie-based affinity against the upstream peer table |
| `upstream_balancer_sticky_header` | `<header_name>` | `upstream` | Enable header-based affinity for controlled clients or internal routing |
| `upstream_balancer_fallback` | `<next|off>` | `upstream` | Define whether the balancer may fall back to stock peer selection when affinity misses |

### Integration Points

- `src/modules/upstream-balancer-nginx-module/ngx_http_upstream_balancer.zig`
- `build.zig`
- `src/ngz_modules.zig` — keep the module in the upstream-balance section after nginx built-ins
- `src/ngz_zig_modules.zig`
- `project/build_package.zig`
- nginx upstream peer hook surface: wrap `ngx_http_upstream_peer_t` callback ownership explicitly rather than introducing a parallel routing path
- future consumers: `dynamic-upstreams`, `healthcheck`

### Data Model and Config

#### Planned upstream config shape

Document and implement an upstream-scoped config model with fields equivalent to:

- sticky mode: off / cookie / header
- sticky key name
- fallback mode: `next` or `off`
- future room for per-peer metadata hooks

Config rules that must be enforced once parsing is real:

- `upstream_balancer_sticky_cookie` and `upstream_balancer_sticky_header` are mutually exclusive in one upstream block
- omitting both directives keeps sticky mode `off`
- invalid fallback values fail config load immediately

#### Planned runtime metadata

Phase 1 should use the smallest metadata contract that can support selection without mutation:

- stable peer identifier derived from upstream peer order at config/snapshot generation time
- peer index / generation snapshot
- optional affinity hash key cache

Do **not** design the Phase 1 metadata around dynamic updates yet. Only add fields that Phase 1 or 2 actually need.

### Request / Worker Lifecycle

- Config parsing happens in the `upstream {}` block.
- Per-request selection runs only through upstream peer callbacks.
- If no sticky directive is configured, behavior should remain equivalent to stock nginx selection.
- Any shared-memory use in later phases must remain readable across workers without partial state visibility.

### Planned Affinity Contract

- The first deterministic mapping may use a simple documented hash such as `crc32(key) % peer_count`; whichever hash lands must be named in the README before Phase 2 is called complete.
- `upstream_balancer_fallback next` means fallback applies to the current request only unless a later phase explicitly documents affinity migration semantics.
- `upstream_balancer_fallback off` means the module returns a deterministic failure/decline path rather than silently selecting a different peer.
- Cookie mode in the first useful version reads an existing request cookie only; setting or rotating sticky cookies is deferred until explicitly designed.

### Traceability and Audit Hooks

| Requirement / claim | Evidence today | Required future evidence |
|---|---|---|
| Scaffold directives do not break proxying | `tests/upstream-balancer/upstream-balancer.test.js` | Keep this test green as Phase 1 callback wiring lands |
| Phase 1 callback ownership does not change routing when sticky mode is effectively inactive | Phase 1 TDD checklist | Bun tests for callback-path installation, neighboring-upstream isolation, and unchanged backend reachability |
| Phase 2 sticky selection is deterministic and fallback-aware | Phase 2 TDD checklist | Bun tests for cookie/header affinity, miss behavior, malformed input, and fallback semantics |
| Phase 3 defines a stable contract for `dynamic-upstreams` | README contract + later integration coverage | Tests proving peer identity/generation behavior remains compatible with snapshot replacement |

### Phase Plan

#### Phase 1 - Upstream callback foundation

**Scope**

Build the minimal native wrapper around nginx upstream peer selection so the module can safely sit in the callback path without changing routing behavior unless configured.

**Implementation notes**

- Introduce upstream-level config storage and directive parsing
- Hook the upstream callback path without changing effective peer choice when sticky mode is off
- Document the exact callback handoff between stock nginx and module-owned logic
- Keep the first implementation read-only with respect to peer membership

**TDD checklist**

- [ ] Add a Bun integration test proving upstream config directives parse successfully
- [ ] Add a Bun integration test proving proxy traffic still reaches the backend with sticky mode configured but not yet active
- [ ] Add a Bun integration test proving neighboring upstreams without this module remain unaffected
- [ ] Add a Zig unit test for directive parsing defaults and fallback-mode parsing if the parser gains logic beyond placeholder acceptance

**Implementation checklist**

- [ ] Replace placeholder directive handlers with real upstream-config parsing
- [ ] Store parsed upstream state in a stable module-owned config struct
- [ ] Register the module into the upstream callback path without altering stock behavior when sticky mode is unset
- [ ] Log clear config-time errors for invalid directive combinations

**Exit criteria**

- Upstream directives are parsed into real upstream-scoped config
- Proxy traffic still behaves like stock nginx when no sticky match is active
- Tests prove the module can sit in the upstream path without regressions
- No shared-memory mutation or peer replacement is required yet

#### Phase 2 - Sticky selection

**Scope**

Implement one deterministic affinity policy at a time: cookie first, then header. Fallback behavior must be explicit and test-backed.

**Implementation notes**

- Start with cookie affinity because it maps most directly to sticky sessions
- Header affinity should reuse the same peer-key resolution path rather than introducing a second routing engine
- Define precisely what happens on malformed cookie/header input and on unknown affinity keys

**TDD checklist**

- [ ] Add a Bun test for cookie affinity hitting the same peer across repeated requests
- [ ] Add a Bun test for header affinity with stable routing
- [ ] Add a Bun test for affinity miss with `upstream_balancer_fallback next`
- [ ] Add a Bun test for affinity miss with `upstream_balancer_fallback off`
- [ ] Add a Bun test for malformed cookie/header input producing deterministic fallback behavior
- [ ] Add a multi-worker Bun test proving the same affinity key resolves to the same peer across workers for one generation

**Implementation checklist**

- [ ] Implement cookie extraction and affinity-key normalization
- [ ] Implement header extraction and affinity-key normalization
- [ ] Map affinity keys to peer identity deterministically
- [ ] Apply explicit fallback semantics for miss / invalid key / unavailable peer
- [ ] Emit clear debug logging for affinity hit, miss, and fallback paths

**Exit criteria**

- At least one sticky mode routes repeat requests to the same peer deterministically
- Fallback behavior is explicit and test-backed
- Malformed affinity input produces one documented fallback or failure outcome without crashing the worker

#### Phase 3 - Operational depth and handoff contract

**Scope**

Harden the selection path for future dynamic upstream work and operational visibility.

**Implementation notes**

- Define the peer identity contract that `dynamic-upstreams` must preserve
- Keep observability light but useful: hit/miss counters or debug traces are enough for the first useful version
- Document how health-marked or drained peers should be handled once other modules integrate

**TDD checklist**

- [ ] Add a multi-peer test covering weighted/fallback interaction if weights are introduced
- [ ] Add a test proving affinity survives worker restarts only within documented bounds
- [ ] Add shared-state coverage if shared memory is introduced for observability or peer metadata

**Implementation checklist**

- [ ] Document and stabilize peer identity and generation expectations
- [ ] Add minimal observability for affinity hits/misses
- [ ] Document compatibility expectations for future `dynamic-upstreams` integration

**Exit criteria**

- The README names the peer identity, hash, and fallback contract that `dynamic-upstreams` must preserve
- Logs or counters expose enough information to distinguish affinity hit, miss, and fallback for one request path
- Any shared-state behavior is multi-worker tested before being called complete

### Failure Handling

- Invalid directive syntax or unsupported combinations should fail at config time
- Runtime selection failures must prefer deterministic fallback over partial undefined behavior
- Unknown affinity keys must not crash the worker or corrupt peer state
- If a peer becomes unusable, the module must either fall back explicitly or decline cleanly according to configured fallback mode

### Observability

Phase 1-2 should at least log:

- module enabled / disabled for an upstream
- affinity mode selected
- affinity hit / miss
- fallback path taken

Future expansion can add counters, but do not block the first useful implementation on a full metrics surface.

### Compatibility and Ordering Constraints

- Keep this module registered in `src/ngz_modules.zig` alongside upstream balancer modules
- Do not turn this into a filter or content module
- Do not let this module outrun `dynamic-upstreams` with assumptions about mutable peer storage that are not documented here
- If later integration with healthcheck exists, document peer health inputs instead of baking health logic directly into this module

### Intentionally Not Supported Yet

- runtime peer add/remove or snapshot activation
- service discovery polling or reconciliation
- peer health probing and recovery policy
- broad metrics or operational API surfaces beyond selection-path debugging

### Open Questions

- What exact peer identity tuple should remain stable when `dynamic-upstreams` begins replacing snapshots?
- Should sticky key mapping preserve affinity across worker restart only within one generation, or across reload-compatible peer identity as well?
- What is the smallest observability surface that makes sticky failures debuggable without turning this into a metrics module?

### Example Target Config

```nginx
http {
    upstream backend {
        upstream_balancer_sticky_cookie route;
        upstream_balancer_fallback next;

        server 10.0.0.11:8080;
        server 10.0.0.12:8080;
    }
}
```

### Deferred Work

- weighted policy tuning beyond simple sticky selection
- richer metrics surface
- direct peer mutation
- service discovery or reconciliation

### Documentation Audit Checklist

- [x] Audit date: 2026-05-03
- [x] Scaffolded Zig module and README exist under `src/modules/upstream-balancer-nginx-module/`.
- [x] README now includes phased checked todos and binary exit criteria for implementation.
- [x] Build, package, and module-registration wiring are planned alongside this scaffold.
- [x] Bun integration coverage exists at `tests/upstream-balancer/` for directive acceptance and proxy preservation.
- [x] Current scaffold claims now trace to present tests and future phase-specific verification points.
