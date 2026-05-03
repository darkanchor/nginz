## Cache Purge Module

Planned selective cache-purge API for operational cache invalidation beyond raw PURGE semantics.

### Status

**Planning / scaffolded** - module wiring and placeholder API surface exist. Selective invalidation behavior is not implemented yet.

### Purpose and Boundaries

This module complements `cache-tags` with an explicit operational purge/control surface. Its goal is to provide targeted invalidation without forcing an external Redis dependency or coupling the response filter to operator workflows.

This module should own:

- purge API contract
- request validation and authorization
- purge metadata lookup and invalidation semantics
- operator-visible result reporting

This module should **not** own:

- response tagging/filter behavior already handled by `cache-tags`
- generic workflow orchestration
- worker fanout as a Phase 1 requirement

### Current Scaffold Behavior

- `cache_purge_api` installs a placeholder JSON endpoint that returns HTTP `501`.
- Remaining directives reserve configuration names and store stub values for future implementation.
- No invalidation, wildcard matching, or cache metadata management is active yet.

### Current Scaffold Test Coverage

`tests/cache-purge/cache-purge.test.js` currently proves:

- the scaffold endpoint returns an explicit JSON `501 Not Implemented` response
- `HEAD` requests behave deterministically on the placeholder endpoint
- unrelated routes continue working while selective invalidation is still unimplemented

### Directive Surface

| Directive | Planned Syntax | Planned Context | Purpose |
|---|---|---|---|
| `cache_purge_api` | `;` | `location` | Expose the purge control endpoint |
| `cache_purge_zone` | `<name>` | `location` | Bind the endpoint to a named purge metadata zone |
| `cache_purge_match` | `<exact|prefix|glob>` | `location` | Choose the invalidation matching strategy |
| `cache_purge_authorize` | `<off|allowlist|signed-token>` | `location` | Define the planned authorization mode |
| `cache_purge_max_keys` | `<count>` | `location` | Bound batch invalidation request size |

### Integration Points

- `src/modules/cache-purge-nginx-module/ngx_http_cache_purge.zig`
- `src/modules/cache-tags-nginx-module/README.md`
- optional later consumer: `worker-events`
- `build.zig`
- `src/ngz_modules.zig`
- `project/build_package.zig`
- nginx request handling: location-scoped content handler serving a JSON purge/control endpoint

### Relationship To Existing Modules

- `cache-tags` remains the response/filter-side tagging primitive.
- This module is the operator-facing purge/control surface.
- `worker-events` may later become a fanout mechanism, but it is not required for the first useful implementation.

### Data Model and Config

#### Planned location config shape

Document and implement:

- API enabled flag
- zone name
- matching mode
- authorization mode
- max keys / max batch size

#### Planned purge metadata model

The first useful data model should support:

- exact lookup of tracked cache keys or tags
- bounded prefix matching if enabled
- per-request result accounting (purged count, missing count, rejected count)

Avoid baking glob matching into the Phase 1 or Phase 2 storage model unless it is proven necessary.

The README must eventually define how this module talks to `cache-tags`:

- shared zone / shared data structure
- cache key versus tag lookup path
- what makes an invalidation successful from the operator perspective

### Planned API Contract

#### Phase 1 request/response baseline

Before Phase 1 closes, the README must name:

- allowed HTTP method or methods
- how requested keys/tags are supplied
- success response shape
- validation-error response shape
- status codes for allowed, rejected, and over-limit requests

### Request / Worker Lifecycle

- Control endpoint lives at `location` scope
- Request validation should happen before any invalidation work
- Matching and invalidation should be bounded by explicit limits
- Multi-worker visibility matters once shared metadata is real, and must be test-backed

### Traceability and Audit Hooks

| Requirement / claim | Evidence today | Required future evidence |
|---|---|---|
| The scaffold purge endpoint is explicitly unimplemented | `tests/cache-purge/cache-purge.test.js` | Keep placeholder behavior explicit until Phase 1 contract replacement lands |
| Phase 1 defines a stable API contract before invalidation logic | Phase 1 TDD checklist | Bun tests for allowed/rejected methods, config validation, and max-keys request validation |
| Phase 2 exact invalidation is useful before broader matching modes | Phase 2 TDD checklist | Bun tests for exact invalidation, zero-hit behavior, optional prefix mode, and multi-worker metadata visibility |
| Phase 3 fanout and stronger auth stay additive | Phase 3 TDD checklist | Integration coverage for signed-token or allowlist auth and worker-events fanout only if implemented |

### Phase Plan

#### Phase 1 - Operator API contract

**Scope**

Replace the placeholder endpoint with a stable request/response contract and request validation, without implementing full selective invalidation yet.

**Implementation notes**

- Name the allowed methods explicitly before coding the handler (`DELETE`, `POST`, or another single documented choice)
- Make response schema stable before introducing matching complexity
- Keep this phase separate from `cache-tags` internals except where metadata access is unavoidable

**TDD checklist**

- [ ] Add a Bun test for allowed methods on the purge endpoint
- [ ] Add a Bun test for rejected methods
- [ ] Add a Bun test for invalid match mode / invalid auth mode handling
- [ ] Add a Bun test for max-keys validation on incoming requests
- [ ] Add a Bun test proving valid Phase 1 requests no longer return the scaffold `501` placeholder

**Implementation checklist**

- [ ] Replace `501` with a stable validation-aware JSON API
- [ ] Implement config parsing and validation for zone, match mode, auth mode, and max keys
- [ ] Define the request schema and response schema explicitly in the README and tests
- [ ] Emit deterministic error responses for bad requests

**Exit criteria**

- The endpoint documents and returns one explicit contract for methods, validation errors, and non-error success responses
- Config parsing and runtime rejection behavior are fully test-backed
- No hidden dependency on `worker-events` exists yet

#### Phase 2 - Selective invalidation core

**Scope**

Implement useful targeted invalidation with exact matching first, then prefix matching.

**Implementation notes**

- Exact matching should land before any broader matching mode
- Prefix matching should be added only if the metadata model can support it cleanly and testably
- Zero-hit responses should be explicit and non-error unless policy requires otherwise

**TDD checklist**

- [ ] Add a Bun test for exact-key or exact-tag invalidation success
- [ ] Add a Bun test for zero-hit invalidation returning a stable response
- [ ] Add a Bun test for prefix invalidation if prefix mode is enabled in this phase
- [ ] Add a multi-worker test proving purge metadata visibility across workers

**Implementation checklist**

- [ ] Implement exact invalidation against named purge metadata
- [ ] Enforce max-keys bounds during batch operations
- [ ] Add prefix invalidation only after exact invalidation is stable
- [ ] Return operator-usable result counts in the response body

**Exit criteria**

- Exact invalidation removes or marks invalid the targeted cache metadata and returns documented result counts
- Prefix matching remains deferred unless Phase 2 implementation and tests explicitly add it
- Multi-worker metadata behavior is verified before being called complete

#### Phase 3 - Policy hardening and fanout

**Scope**

Add optional advanced matching, authorization depth, and fanout integration.

**Implementation notes**

- Signed-token auth belongs here, not earlier
- Glob matching should only land if its cost/benefit is justified
- Fanout over `worker-events` should be additive rather than foundational

**TDD checklist**

- [ ] Add a Bun test for signed-token or allowlist authorization once supported
- [ ] Add a Bun test for glob matching only if the mode is implemented
- [ ] Add an integration test for event-bus fanout if worker-events coupling is added

**Implementation checklist**

- [ ] Add stronger authorization modes
- [ ] Add advanced matching only if needed after exact/prefix prove insufficient
- [ ] Add optional worker-events fanout for broader invalidation propagation

**Exit criteria**

- Any authorization mode added in this phase has explicit request requirements and test coverage
- Any advanced matching or worker-events fanout added in this phase is accompanied by concrete API and integration tests
- The operator-facing purge workflow is production-usable for the intended scope

### Failure Handling

- Unsupported methods should return stable API errors
- Invalid match/auth modes should fail at config time or return deterministic validation errors
- Shared-memory or metadata lookup failures must not produce silent partial invalidation
- Zero-hit invalidations should be explicit and inspectable rather than ambiguous success

### Observability

The first useful implementation should expose:

- requested match mode
- requested key/tag count
- purged count
- missing count
- authorization result
- last error category when a purge request fails

### Compatibility and Ordering Constraints

- Keep this as a control/content module, not a filter
- Do not duplicate `cache-tags` responsibilities
- Do not require `worker-events` for the first operational version
- Any shared metadata behavior must be multi-worker tested before the phase is called complete

### Intentionally Not Supported Yet

- full selective invalidation against real metadata in the scaffold phase
- glob matching before exact and prefix behavior prove necessary
- signed-token authorization before the base operator contract is stable
- `worker-events` fanout as a prerequisite for the first operational rollout

### Open Questions

- What is the cleanest metadata contract between `cache-tags` and this module: cache key index, tag index, or both?
- Should the first useful operator API use `DELETE`, `POST`, or a method-agnostic JSON envelope for batch invalidation?
- Should zero-hit invalidations always be non-error, or should policy allow stricter behavior later without changing the base response shape?

### Example Target Config

```nginx
server {
    location /internal/cache-purge {
        cache_purge_api;
        cache_purge_zone default;
        cache_purge_match prefix;
        cache_purge_authorize allowlist;
        cache_purge_max_keys 256;
    }
}
```

### Deferred Work

- cross-node invalidation
- rich audit sinks beyond response/log surface
- broad runtime API aggregation

### Documentation Audit Checklist

- [x] Audit date: 2026-05-03
- [x] Scaffolded Zig module and README exist under `src/modules/cache-purge-nginx-module/`.
- [x] Placeholder API endpoint makes the non-implemented state explicit.
- [x] README now includes phased checked todos and binary exit criteria for implementation.
- [x] Bun integration coverage exists at `tests/cache-purge/` for placeholder JSON, `HEAD`, and unaffected-route behavior.
- [x] Current scaffold claims now trace to present tests and future phase-specific verification points.

The `cache-purge` module is meant to be the operator-facing way to invalidate cached content. In plain words: it is supposed to give you an API endpoint where you can say “remove these cached entries” without doing a blunt full cache clear.

Its design is intentionally split from `cache-tags`. `cache-tags` is supposed to do the response-side work of tagging cache entries as they are created. `cache-purge` is supposed to do the control-side work of finding those tagged or indexed entries and invalidating them on demand.

That separation is good. One module writes metadata during normal traffic, the other uses that metadata later for operational invalidation. The README at [cache-purge]() is pretty explicit that this module should not become a filter, and should not duplicate what `cache-tags` already owns.

The intended API surface is small:

- `cache_purge_api`
- `cache_purge_zone <name>`
- `cache_purge_match <exact|prefix|glob>`
- `cache_purge_authorize <off|allowlist|signed-token>`
- `cache_purge_max_keys <count>`

So the shape is: expose a location, bind it to some purge metadata zone, choose how matching works, choose how callers are authorized, and put a hard limit on how many keys can be purged in one request.

The important design choice is that it wants to start with exact matching first, then maybe prefix matching later, and treat glob matching as optional and probably late. That is the right order. Exact invalidation is much easier to make correct and bounded. Prefix can be justified. Glob can get expensive and ambiguous fast.

Right now the module is still only scaffolded. The code in [ngx_http_cache_purge.zig]() stores stub config and returns a `501` placeholder JSON response. The test in [cache-purge.test.js]() only proves that placeholder behavior.

The real engineering challenges are mostly about metadata and correctness:

1. Defining the metadata contract with `cache-tags`  
This is the central problem. Purge cannot work unless there is a reliable index of what cache key or tag points to which cache entries. The README calls this out directly.

2. Choosing the lookup model  
You need to decide whether you purge by exact cache key, by tag, or both. Those are different data structures and different operational expectations.

3. Keeping invalidation bounded  
A purge API can become dangerous if one request can scan too much state. That is why the design includes `max_keys` and treats broader matching modes cautiously.

4. Multi-worker visibility  
If the cache metadata is shared, all workers need to see the same invalidation state. Otherwise one worker may still serve stale content after another thinks it was purged.

5. Partial failure handling  
A purge request must not silently invalidate some entries and lose track of the rest without saying so. The operator needs a truthful response: purged count, missing count, rejected count.

6. Authorization  
This endpoint is operationally sensitive. If it exists, it needs a clear policy for who can call it. The README is right to separate “base API contract” from stronger auth like signed tokens.

7. Not depending on `worker-events` too early  
The design keeps fanout optional. That is sensible. First make single-node selective invalidation work correctly. Then add cross-worker or broader event propagation as an improvement, not as a prerequisite.

So in plain terms, `cache-purge` is trying to become the safe remote control for cached content. It should let operators invalidate targeted entries without external Redis glue and without clearing everything.

The hard part is not building the HTTP endpoint. The hard part is building the metadata lookup path behind it so that “purge this” actually means something precise, bounded, and consistent across workers.

A useful mental model is:

- `cache-tags`: labels cached objects when they are written
- `cache-purge`: looks up those labels later and invalidates matching objects
- `worker-events`: may later help fan out purge notifications, but it is not the core of purge correctness

That architecture is sound. The risky part is the shared metadata design between tagging and purging.
