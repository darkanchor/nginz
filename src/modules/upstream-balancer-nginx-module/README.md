## Upstream Balancer Module

Sticky-session upstream balancer for nginx peer selection in Zig.

### Status

**Phases 1, 2, and 3 complete** — cookie and header affinity selection is live, multi-worker consistency is verified, and healthcheck peer health state is now wired into peer eligibility via a narrow cross-module API. 15 integration tests pass.

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

### Current Behavior

- Directives are parsed into `BalancerSrvConf` stored in `uscf->srv_conf[ctx_index]`.
- The module wraps nginx's upstream callback chain: `init_upstream` → `init_peer` → `get_peer` / `free_peer`.
- When sticky mode is off, behavior is identical to stock nginx round-robin.
- When sticky mode is cookie or header, the affinity key is extracted via the nginx variable system (`cookie_<name>` / `http_<name>`), hashed with CRC32-IsoHdlc, and mapped to `hash % eligible_peer_count` to select a peer deterministically.
- `upstream_balancer_fallback next`: affinity miss falls back to round-robin for that request.
- `upstream_balancer_fallback off`: affinity miss returns `NGX_BUSY` (502 to client).
- `upstream_balancer_sticky_cookie` and `upstream_balancer_sticky_header` are mutually exclusive; a config with both in one upstream block fails at parse time.

### Current Test Coverage

`tests/upstream-balancer/upstream-balancer.test.js` proves:

- plain upstream (no sticky directives) proxies normally — neighboring upstreams are unaffected
- cookie and header upstreams proxy successfully with no sticky key present (fallback next)
- same cookie key routes to the same backend across repeated requests (deterministic)
- a second distinct cookie key is independently stable
- header affinity proxies successfully with a stable key
- missing cookie + fallback next → 200
- missing cookie + fallback off → 502
- cookie and header directives in the same upstream block are rejected at parse time (checked via `nginx -t` stderr)
- multi-worker affinity consistency (20 requests across 2 workers, same key → same backend)
- healthcheck integration: unhealthy peers (probe failing) are excluded from sticky selection; traffic returns to the healthy peer; recovery is observed when the probe resumes succeeding

### Directive Surface

| Directive | Syntax | Context | Purpose |
|---|---|---|---|
| `upstream_balancer_sticky_cookie` | `<cookie_name>` | `upstream` | Enable cookie-based affinity against the upstream peer table |
| `upstream_balancer_sticky_header` | `<header_name>` | `upstream` | Enable header-based affinity for controlled clients or internal routing |
| `upstream_balancer_fallback` | `<next\|off>` | `upstream` | Define whether the balancer may fall back to stock peer selection when affinity misses |

Mutual exclusion: `sticky_cookie` and `sticky_header` cannot both appear in the same upstream block. Config load fails immediately if they do.

### Integration Points

- `src/modules/upstream-balancer-nginx-module/ngx_http_upstream_balancer.zig`
- `build.zig`
- `src/ngz_modules.zig` — keep the module in the upstream-balance section after nginx built-ins
- `src/ngz_zig_modules.zig`
- `project/build_package.zig`
- nginx upstream peer hook surface: wrap `ngx_http_upstream_peer_t` callback ownership explicitly rather than introducing a parallel routing path
- cross-module API: `ngz_healthcheck_is_peer_eligible` exported from `healthcheck`, declared `extern` in this module, wired into `is_eligible(p)` helper used by `count_eligible` and `peer_at`

### Milestone 2 Reminder

- `healthcheck` probing/reporting is already implemented separately, but milestone 2 is not complete until this module can consume documented peer-health input and apply it during peer selection.
- The missing healthcheck integration here is selection-time behavior only: skip unhealthy peers, define fallback semantics, and document what happens while a peer is in slow-start recovery.
- Do not duplicate probing logic in this module; consume `healthcheck` state through a narrow contract instead.

### Data Model and Config

#### Upstream config — `BalancerSrvConf`

Stored in `uscf->srv_conf[ctx_index]`, allocated from the config pool:

| Field | Type | Purpose |
|---|---|---|
| `sticky_mode` | `c_int` | `STICKY_OFF` / `STICKY_COOKIE` / `STICKY_HEADER` |
| `fallback_mode` | `c_int` | `FALLBACK_NEXT` / `FALLBACK_OFF` |
| `key_name` | `ngx_str_t` | Cookie or header name as given in the directive |
| `var_index` | `ngx_int_t` | Pre-registered nginx variable index for fast per-request lookup |
| `original_init_upstream` | `?*anyopaque` | Saved original `peer.init_upstream` (round-robin by default) |
| `original_init_peer` | `?*anyopaque` | Saved original `peer.init` after init_upstream runs |

Config invariants:
- `sticky_cookie` and `sticky_header` are mutually exclusive — config fails immediately if both appear.
- Omitting both directives keeps `sticky_mode = STICKY_OFF`; the module sits in the callback path but delegates to round-robin transparently.
- Invalid `fallback` values fail config load immediately.

#### Per-request context — `BalancerRequestCtx`

Allocated from `r->pool` per request in `init_peer`:

| Field | Purpose |
|---|---|
| `conf_ptr` | Pointer back to `BalancerSrvConf` |
| `request_ptr` | Pointer to `ngx_http_request_t` for variable lookup |
| `original_data` | Original round-robin `peer.data` |
| `original_get` | Original `get_peer` function |
| `original_free` | Original `free_peer` function |
| `sticky_used` | Set to 1 after a sticky selection; retries delegate to round-robin |

### Request / Worker Lifecycle

- Config parsing happens in the `upstream {}` block.
- Per-request selection runs only through upstream peer callbacks.
- If no sticky directive is configured, behavior should remain equivalent to stock nginx selection.
- Any shared-memory use in later phases must remain readable across workers without partial state visibility.

### Affinity Contract

**Hash function**: `CRC32-IsoHdlc` (`std.hash.crc.Crc32.hash(key)`) — the same algorithm as Ethernet/ZIP CRC32. The peer index is `hash % eligible_peer_count` where eligible means `peer.down == 0`. This contract is stable within one configuration generation.

- `upstream_balancer_fallback next` means fallback applies to the current request only; a retry will call the original round-robin picker.
- `upstream_balancer_fallback off` means the module returns `NGX_BUSY` rather than silently selecting a different peer, which nginx upstream translates to a 502 response without retrying.
- Cookie mode reads an existing request cookie only; setting or rotating sticky cookies is deferred until explicitly designed.
- Peer identity is derived from the peer list order at `init_upstream` time. If `dynamic-upstreams` replaces the peer set, affinity keys may resolve to different peers — that handoff contract is a Phase 3 concern.

### Traceability and Audit Hooks

| Requirement / claim | Evidence |
|---|---|
| Directives do not break proxying | `tests/upstream-balancer/upstream-balancer.test.js` — plain, cookie, and header upstreams all proxy successfully |
| Callback ownership does not change routing when sticky is inactive | same test file — plain upstream and fallback-next paths |
| Sticky selection is deterministic across repeated requests | "cookie affinity: same key routes to same backend" test (5 iterations) |
| Fallback semantics are explicit | "cookie absent, fallback next → 200" and "cookie absent, fallback off → 502" tests |
| Invalid directive combinations are rejected at parse time | nginx `-t` stderr check in "config validation" describe block |
| Affinity hash is named and stable | This README: CRC32-IsoHdlc, `hash % eligible_peer_count` |
| Affinity is consistent across workers | "multi-worker consistency" describe block — 20 requests × 2 workers, same key, same backend |
| Peer identity contract is defined | Peer Identity Contract section in this README |
| Healthcheck integration is implemented | `ngz_healthcheck_is_peer_eligible` cross-module API; "upstream-balancer healthcheck integration" test block |

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

- [x] Add a Bun integration test proving upstream config directives parse successfully
- [x] Add a Bun integration test proving proxy traffic still reaches the backend with sticky mode configured but key absent (fallback next)
- [x] Add a Bun integration test proving neighboring upstreams without this module remain unaffected (plain upstream)
- [x] Add a Bun integration test proving invalid directive combinations are rejected at parse time

**Implementation checklist**

- [x] Replace placeholder directive handlers with real upstream-config parsing
- [x] Store parsed upstream state in a stable module-owned config struct (`BalancerSrvConf`)
- [x] Register the module into the upstream callback path without altering stock behavior when sticky mode is unset
- [x] Log clear config-time errors for invalid directive combinations

**Exit criteria**

- ✅ Upstream directives are parsed into real upstream-scoped config
- ✅ Proxy traffic still behaves like stock nginx when no sticky match is active
- ✅ Tests prove the module can sit in the upstream path without regressions
- ✅ No shared-memory mutation or peer replacement is required yet

#### Phase 2 - Sticky selection

**Scope**

Implement one deterministic affinity policy at a time: cookie first, then header. Fallback behavior must be explicit and test-backed.

**Implementation notes**

- Start with cookie affinity because it maps most directly to sticky sessions
- Header affinity should reuse the same peer-key resolution path rather than introducing a second routing engine
- Define precisely what happens on malformed cookie/header input and on unknown affinity keys

**TDD checklist**

- [x] Add a Bun test for cookie affinity hitting the same peer across repeated requests
- [x] Add a Bun test for header affinity with stable routing
- [x] Add a Bun test for affinity miss with `upstream_balancer_fallback next`
- [x] Add a Bun test for affinity miss with `upstream_balancer_fallback off`
- [x] Empty/absent cookie or header key is treated as a miss and follows the configured fallback policy (covered by fallback tests; empty key: `vv.flags.len == 0` → key_absent path)
- [ ] Add a multi-worker Bun test proving the same affinity key resolves to the same peer across workers for one generation — deferred to Phase 3

**Implementation checklist**

- [x] Implement cookie extraction via nginx variable system (`cookie_<name>`)
- [x] Implement header extraction via nginx variable system (`http_<lowercased_name>`, `-` → `_`)
- [x] Map affinity keys to peer identity deterministically (CRC32-IsoHdlc `hash % eligible_peer_count`)
- [x] Apply explicit fallback semantics for miss / invalid key / unavailable peer
- [x] Emit clear debug logging for affinity hit, miss, and fallback paths

**Exit criteria**

- ✅ Cookie affinity routes repeat requests to the same peer deterministically
- ✅ Header affinity routes repeat requests to the same peer deterministically
- ✅ Fallback behavior is explicit and test-backed for both `next` and `off`
- ✅ Absent/empty affinity key produces a documented fallback outcome without crashing the worker
- ✅ Affinity hash function is named in this README

#### Phase 3 - Operational depth and handoff contract

**Scope**

Harden the selection path for future dynamic upstream work and operational visibility.

**Implementation notes**

- Define the peer identity contract that `dynamic-upstreams` must preserve
- Keep observability light but useful: hit/miss counters or debug traces are enough for the first useful version
- Document how health-marked or drained peers should be handled once other modules integrate
- This phase should also close the milestone-2 gap where `healthcheck` state exists but does not yet influence live peer selection.

**TDD checklist**

- [x] Add a Bun test proving the same affinity key resolves to the same backend across both workers (20 requests, `worker_processes 2`)
- [x] Add a Bun test proving distinct keys are each independently stable across workers
- [ ] Add shared-state coverage if shared memory is introduced for observability or peer metadata — no shared memory introduced; N/A for this phase
- [ ] Add weighted/fallback interaction tests if weights are introduced — weights not introduced; N/A for this phase

**Implementation checklist**

- [x] Document and stabilize peer identity and generation expectations (see Peer Identity Contract below)
- [x] Debug logging at hit/miss/fallback decision points is the minimal observability surface (no counters needed for Phase 3)
- [x] Document compatibility expectations for `dynamic-upstreams` integration (see Peer Identity Contract)
- [x] Integrate `healthcheck` peer health state into peer eligibility via `ngz_healthcheck_is_peer_eligible` cross-module API

**Exit criteria**

- ✅ The README names the peer identity, hash, and fallback contract that `dynamic-upstreams` must preserve
- ✅ Debug logs distinguish affinity hit, miss, and fallback path per request (NGX_LOG_DEBUG level, enabled with `error_log ... debug`)
- ✅ Multi-worker consistency is empirically verified — 20 requests across 2 workers with the same key always land on the same backend
- ✅ Healthcheck peer health state influences peer eligibility via `ngz_healthcheck_is_peer_eligible` cross-module API

### Failure Handling

- Invalid directive syntax or unsupported combinations should fail at config time
- Runtime selection failures must prefer deterministic fallback over partial undefined behavior
- Unknown affinity keys must not crash the worker or corrupt peer state
- If a peer becomes unusable, the module must either fall back explicitly or decline cleanly according to configured fallback mode

### Observability

The following events are logged at `NGX_LOG_DEBUG` level (requires `error_log ... debug` in the config):

| Event | Log message |
|---|---|
| Callback installed for upstream | `upstream_balancer: callback installed` |
| Affinity hit — peer chosen by hash | `upstream_balancer: sticky hit` |
| Affinity key absent, fallback next | `upstream_balancer: sticky key absent, fallback next` |
| Affinity key absent, fallback off | `upstream_balancer: sticky key absent, fallback off` |

This is sufficient to trace the decision path for any single request. No shared-memory counters are introduced in Phases 1–3.

### Peer Identity Contract

This section is the stability contract that `dynamic-upstreams` must preserve.

**Identity definition**: A peer's identity is its position among eligible peers in `ngx_http_upstream_rr_peers_t.peer` linked list, counted at request time. That position is implicit — there is no stable peer ID field. The mapping from cookie/header key to peer is: `CRC32(key) % eligible_peer_count` where eligible means `peer.down == 0` AND `ngz_healthcheck_is_peer_eligible(peer.name) == 1`.

**Generation boundary**: A configuration reload is a generation boundary. After a reload, `init_upstream` is called again, the peer list is rebuilt, and `eligible_peer_count` may change. Any keys that previously mapped to peer index N may now map to a different peer if the list length or peer ordering changed. **This is acceptable, documented behavior — affinity is not guaranteed across config reloads.**

**Contract for `dynamic-upstreams`**: When `dynamic-upstreams` adds or removes peers, it must trigger a proper nginx upstream reinitialization (equivalent to a reload) so that this module's `init_upstream` runs again. It must not mutate the peer linked list behind the module's back between `init_upstream` calls, because that would silently change `eligible_peer_count` and invalidate in-flight affinity mappings without a clean generation transition.

**Worker consistency**: All nginx workers fork from the master after config parsing. The peer list and its order are identical across workers for a given generation. Because the hash is pure (CRC32 is deterministic, no per-worker state), every worker resolves the same key to the same peer index. This is verified empirically by the multi-worker tests.

### Healthcheck Integration

The `healthcheck` module maintains per-peer `probe_healthy` state in per-peer shared memory zones. It does **not** set `peer.down` on `ngx_http_upstream_rr_peer_t`. The integration uses a narrow cross-module API instead of relying on `peer.down`.

**Implemented contract**:

```zig
// Exported from healthcheck module
export fn ngz_healthcheck_is_peer_eligible(addr_data: [*c]u8, addr_len: usize) callconv(.c) c_int;
```

The balancer declares this as `extern` and calls it from the `is_eligible(p)` helper, which combines the nginx-native `peer.down` check with the healthcheck module's `probe_healthy` state. Both `count_eligible` and `peer_at` use `is_eligible`.

**Fail-open semantics**: If a peer has no probe configured, `ngz_healthcheck_is_peer_eligible` returns 1 (eligible). This prevents startup-time exclusion of unprobed peers and ensures the module works correctly when healthcheck peer probes are not configured.

**Probe settings inheritance**: Per-peer probe settings inherit from the upstream's `health_upstream_probe_interval/fails/passes` directives, so probe timing only needs to be set once per upstream block.

**Integration test**: `tests/upstream-balancer/nginx-healthcheck-balancer.conf` + "upstream-balancer healthcheck integration" describe block verify that an unhealthy peer is excluded from sticky selection and traffic returns after probe recovery.

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

- When `dynamic-upstreams` begins replacing peer sets at runtime, should the balancer get an explicit "generation changed" signal, or detect it implicitly by comparing `peers.number` against a cached value?

### Design Rationale

This section explains the reasoning behind the design in plain terms, including the parts that are hard.

**What this module does**: It owns nginx's low-level upstream peer selection callback and adds sticky routing on top. "Sticky" means: if a request carries a cookie or header key, the same key consistently lands on the same backend server. Without this module, nginx's default round-robin spreads requests across backends unpredictably, which breaks session-dependent applications.

**Why a separate module for this**: nginx upstream internals — specifically the `peer.init_upstream`, `peer.init`, `peer.get`, and `peer.free` callback chain — are a sharp edge. Inserting yourself into that chain carelessly can silently break routing for all upstreams in the process. Owning it in a small, auditable Zig module keeps the dangerous code surface minimal and independently testable before other modules build on it.

**The design layering**: Three separate modules own three separate concerns:
1. `upstream-balancer` (this module) owns request-time peer selection.
2. `dynamic-upstreams` will own changing the set of peers at runtime (add/remove servers without reloading).
3. `healthcheck` owns probing and reporting peer health.

That separation matters because mixing these responsibilities into one module creates entangled state and makes each piece harder to audit. For example, `healthcheck` does active TCP probing on timers — that logic has no business being inside a per-request selection callback.

**Why CRC32 and not a better hash**: CRC32-IsoHdlc is fast, available in Zig's standard library with no external dependency, and is deterministic across all platforms. For the sticky use case, hash quality (uniform distribution) matters but collision resistance does not. With CRC32 the distribution is good enough for typical upstream counts (2–10 peers), and the algorithm is well-understood. If distribution becomes a problem at larger peer counts, the hash can be swapped at the cost of one line of code.

**The hard parts**:

- *Callback ownership without disruption*: Installing `init_upstream` from a directive handler (not postconfiguration) mirrors how nginx's own sticky upstream module works. The key invariant is that the saved `original_init_upstream` pointer must be the round-robin initializer, not a previous module's wrapper — the ordering in `ngz_modules.zig` controls this.

- *Per-request context allocation*: Every request gets a `BalancerRequestCtx` from `r->pool`. This avoids global state and makes each request's affinity decision independent. The context holds the saved get/free callbacks so retries can fall back to round-robin without the balancer re-running sticky logic.

- *Retry handling*: `sticky_used == 1` signals that sticky selection already ran for this request. A retry (e.g., TCP connect failure) delegates to the original round-robin picker. Without this flag, the balancer would keep re-selecting the same failed peer on every retry attempt.

- *Peer identity stability across workers*: Because nginx workers fork from the master after config parsing, the peer linked list is byte-for-byte identical in every worker. The CRC32 hash and `% eligible_peer_count` are pure functions of config-time data, so every worker resolves the same key to the same peer independently and without coordination.

- *The generation problem*: Peer identity is currently positional — peer index 0 is the first non-down peer in the list. If `dynamic-upstreams` changes that list (adds a peer, removes one, reorders), the mapping shifts. The Peer Identity Contract section above defines the generation boundary and what `dynamic-upstreams` must do to respect it.

- *Healthcheck wiring*: `peer.down` is the standard nginx signal for "this peer is out of rotation," but the healthcheck module uses its own shared-memory `probe_healthy` field and does not set `peer.down`. The `is_eligible(p)` helper combines both: `peer.down == 0` AND `ngz_healthcheck_is_peer_eligible(peer.name) != 0`. This keeps probing logic out of the balancer and selection logic out of healthcheck.

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

- [x] Audit date: 2026-05-07
- [x] Phases 1, 2, and 3 implemented and integration-tested (15/15 tests passing).
- [x] Affinity hash function named: CRC32-IsoHdlc (`std.hash.crc.Crc32`), `hash % eligible_peer_count`.
- [x] Fallback semantics documented and test-backed for both `next` and `off`.
- [x] Mutual-exclusion config error is detected and reported at parse time.
- [x] Multi-worker affinity consistency verified empirically (20 requests, 2 workers).
- [x] Peer Identity Contract defined — generation boundary, `dynamic-upstreams` obligations, worker consistency guarantee.
- [x] Healthcheck integration gap documented — intended cross-module contract specified, current limitation described.
- [x] Design Rationale section explains the hard parts: callback ownership, retry handling, generation problem, healthcheck wiring.
