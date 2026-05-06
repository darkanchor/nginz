# Technical Notes: Cache Purge

Deep-dive implementation plan for the `cache-purge` module.

This document is the technical attack plan behind
`src/modules/cache-purge-nginx-module/README.md`. It is intentionally more
concrete than the README: it focuses on the metadata contract with
`cache-tags`, invalidation semantics, API shape, and the implementation order
that makes this module useful without over-promising what “purge” means.

The intended setting is:

- `cache-tags` already exists and owns response-side tag capture
- `cache-purge` is the operator-facing control plane for targeted invalidation
- `worker-events` may later help fan out invalidation notifications, but is
  not required for the first correct version
- this module must first become a truthful, bounded invalidation API before it
  grows advanced matching or authorization depth

---

## Mission

`cache-purge` has one job: accept an explicit operator request and invalidate
targeted cache metadata in a bounded, inspectable way.

Its phased mission is:

1. define a stable purge API contract
2. invalidate one exact target class correctly
3. add broader matching only if the metadata model can justify it
4. keep authorization and fanout additive rather than foundational

That means this module is not:

- a response filter
- a cache tag collector
- a generic workflow orchestrator
- a requirement for worker-events from day one

It is the control plane.

---

## What Makes This Module Hard

The difficulty is not the HTTP verb. The difficulty is deciding what exactly
gets invalidated and proving that the response tells the truth.

The risky areas are:

- the metadata contract with `cache-tags`
- exact versus prefix/glob matching cost
- keeping invalidation bounded under one operator request
- telling the truth about zero-hit, partial-hit, and rejected requests
- avoiding a fake “purge” that deletes bookkeeping but leaves actual cache
  behavior unchanged

That last point matters. Today `cache-tags` already stores tag metadata and
removes that metadata on purge, but that alone is not automatically the same
thing as purging a real nginx proxy-cache object.

So the design note has to be honest about what version 1 and 2 can claim.

---

## Current Reality And Overlap

There is an important repo-level fact:

- `cache-tags` is already implemented
- `cache-tags` already has a `cache_tags_purge` endpoint
- that endpoint already uses shared memory and supports exact tag lookup

So `cache-purge` is not starting from zero. It is starting beside an existing
module that already proves some of the metadata path.

Today `cache-tags` keeps a simple shared-memory store:

- tag -> list of URIs

Its current purge behavior:

- finds one exact tag
- returns the URI count
- removes that tag entry from the store

That gives us two important design conclusions.

### First conclusion

`cache-purge` should not invent a second independent tag store if it can
reuse or formalize the existing `cache-tags` metadata.

### Second conclusion

`cache-purge` should not immediately claim broader semantics than the metadata
can support.

If the only truthful index is exact tag -> URI list, then phase 1 and early
phase 2 should build around that truth.

---

## Correct Design Direction

### Core choice

Treat `cache-purge` as a control API layer over a canonical purge metadata
store, with `cache-tags` as the first producer of that metadata.

That means:

- `cache-tags` remains responsible for collecting and storing tag metadata
- `cache-purge` remains responsible for:
  - request validation
  - authorization
  - operator-visible result reporting
  - matching-policy decisions
  - calling the invalidation engine

### Version 1 principle

Start with exact invalidation only, against existing truthful metadata.

That gives the first useful implementation:

- a real endpoint
- bounded request validation
- one stable response shape
- exact tag invalidation through shared metadata

### Why exact-first is non-negotiable

The README already hints at `exact|prefix|glob`, but the current metadata does
not justify prefix or glob safely.

Exact matching is:

- bounded
- easy to explain
- easy to test
- already aligned with the current `cache-tags` store

Prefix and glob are not just parser changes. They imply different lookup
structures or expensive scans.

---

## The Real Semantics Question

The hardest design question is:

What does “purge success” mean?

There are three possible answers:

1. remove matching metadata entries only
2. remove matching cache metadata and also invalidate corresponding cache
   objects in nginx
3. mark matching objects as invalid for future reads without necessarily
   deleting the underlying file immediately

The repo does not yet show a full native cache-object invalidation path tied
to `cache-tags`, so the first implementation must be explicit:

- if only metadata is removed, say so
- if actual cache object invalidation is implemented, document the mechanism
- do not call the behavior “full cache purge” unless it really is

This doc recommends:

- version 1 and early version 2 should be framed as **selective metadata
  invalidation with operator-facing accounting**
- if later work adds real cache object invalidation, that should be documented
  as a concrete contract upgrade

That is stricter and more honest than pretending the hard part is already
solved.

---

## Metadata Model

### Recommended ownership split

Use one canonical purge metadata zone with a narrow interface.

Conceptually:

- `cache-tags` writes tag metadata during response processing
- `cache-purge` reads and mutates that metadata during operator requests

There are two practical ways to reach that:

1. **Shared store reuse**
   - `cache-purge` directly opens the same shared-memory zone used by
     `cache-tags`
   - both modules must then share the exact store layout contract

2. **Shared helper extraction**
   - move the store definition and helper functions into a shared Zig file
   - both modules import the same metadata engine

The second path is safer in this repo because it avoids duplicate struct drift.

### Recommended first store

The current `cache-tags` store is simple and fixed-size:

- tag count
- fixed array of tag entries
- each tag entry holds:
  - tag text
  - URI list

For phase 1 / early phase 2 of `cache-purge`, keep that model and build the
API around it rather than designing for prefix/glob immediately.

### What not to add yet

Do not introduce in the first useful version:

- glob indexes
- regex matching
- external Redis dependency
- unbounded string collections
- multiple independent metadata stores for the same purge surface

---

## Config Model

The scaffold directives live at `location` scope:

- `cache_purge_api`
- `cache_purge_zone`
- `cache_purge_match`
- `cache_purge_authorize`
- `cache_purge_max_keys`

That is correct for the control surface. The underlying metadata zone is the
real shared object.

### Location config shape

```zig
const CachePurgeLocConf = extern struct {
    api_enabled: ngx_flag_t,
    zone_name: ngx_str_t,
    match_mode: MatchMode,
    auth_mode: AuthMode,
    max_keys: ngx_uint_t,
};
```

Where:

```zig
const MatchMode = enum(c_uint) {
    exact = 0,
    prefix = 1,
    glob = 2,
};

const AuthMode = enum(c_uint) {
    off = 0,
    allowlist = 1,
    signed_token = 2,
};
```

### Config rules

- `cache_purge_zone` is required when `cache_purge_api` is enabled
- `cache_purge_match` defaults to `exact`
- `cache_purge_authorize` defaults to `off`
- `cache_purge_max_keys` must be > 0
- version 1 should reject `prefix` and `glob` at config time if the engine
  has not implemented them truthfully yet

That last rule matters. Accepting `glob` in config before the metadata model
supports it is just lying with nicer syntax.

---

## API Contract

Version 1 should keep one explicit write contract and one explicit inspectable
response shape.

### Method choice

Use `POST` for version 1 batch invalidation requests.

Why `POST`:

- better fit for JSON request bodies than `DELETE`
- easier to extend to multiple targets
- does not overload URL query length limits

### Request shape

```json
{
  "targets": ["user-123", "product-456"]
}
```

For version 1 under exact mode, the meaning of each target is:

- one exact tag string

If later versions add cache keys or target kinds, that should be an explicit
schema evolution, for example:

```json
{
  "kind": "tag",
  "targets": ["user-123"]
}
```

but version 1 should stay narrower than that.

### Response shape

```json
{
  "module": "cache_purge",
  "zone": "default",
  "match": "exact",
  "requested": 2,
  "purged": 5,
  "missing": 1,
  "rejected": 0,
  "results": [
    { "target": "user-123", "purged": 5 },
    { "target": "product-456", "purged": 0 }
  ]
}
```

### Zero-hit behavior

Zero-hit should be a non-error response with explicit accounting.

This is better operationally than making “nothing matched” ambiguous between:

- request was invalid
- auth blocked it
- metadata was missing

---

## Authorization Strategy

The README leaves room for:

- `off`
- `allowlist`
- `signed-token`

This doc recommends:

- version 1: `off` only, but keep the config surface parsed and validated
- version 2: `allowlist`
- version 3: `signed-token`

Why:

- auth is operationally important
- but auth is not the hardest technical part of this module
- the metadata truth contract must land first

Do not make auth complexity block exact invalidation correctness.

---

## Invalidation Flow

The first useful invalidation path should be:

1. validate method/content type/body size
2. parse JSON body
3. validate target count against `max_keys`
4. validate match mode is supported by the implementation
5. authorize request
6. resolve shared metadata zone
7. lock shared-memory store
8. for each target:
   - find matching exact tag entry
   - count matching URIs
   - remove or mark invalid the entry
9. unlock
10. return per-target and aggregate counts

### Why batch semantics must stay bounded

A purge endpoint can become a denial-of-service tool if one request can force:

- huge scans
- huge JSON output
- long mutex holds

So the implementation must bound:

- request body size
- target count
- output size
- supported matching modes

---

## Exact, Prefix, and Glob

These modes are not equivalent in cost.

### Exact

Works with the current model:

- direct tag lookup
- bounded cost
- already conceptually proven by `cache-tags`

### Prefix

Requires one of:

- scanning all tags
- maintaining a separate prefix-friendly index

Scanning all tags may be acceptable only if:

- `MAX_TAGS` is explicitly small
- the cost is documented
- the lock hold time is measured and bounded

If that cannot be defended, prefix should remain deferred.

### Glob

Glob is not “prefix with nicer syntax.” It is an operator promise with a much
higher scan and validation cost.

This document recommends:

- do not implement `glob` unless prefix and exact have already proven useful
- if `glob` is added, do it in a later phase with explicit cost bounds and
  tighter auth expectations

---

## Shared-Memory Correctness

The metadata store is shared across workers, so the invalidation engine must:

- hold the zone mutex while mutating store state
- keep mutation bounded
- avoid request rendering while holding the lock

Like `worker-events`, this module should:

- copy what it needs for output
- unlock
- then format JSON

Do not hold the shared-memory lock across response rendering.

---

## Relationship To `cache-tags`

This is the most important design boundary in the document.

`cache-tags` should own:

- response-side tag capture
- tag parsing from upstream headers
- writing tag metadata into shared memory

`cache-purge` should own:

- operator API
- auth and request validation
- match-mode policy
- operator-visible result reporting
- invalidation requests against the shared metadata engine

### Recommended refactor

If `cache-purge` becomes real, the repo should eventually extract the shared
tag metadata engine from `cache-tags` into a helper module or shared Zig file.

Otherwise the repo risks:

- duplicate shared-store definitions
- drift between purge and capture semantics
- two code paths mutating the same conceptual data differently

---

## Worker-Events Integration

`worker-events` should be explicitly non-foundational here.

The correctness model must be:

- purge metadata is mutated in shared memory first
- optional event fanout happens after mutation

That means worker-events can improve:

- convergence speed
- observability
- side-effect notifications

but should not determine whether the purge succeeded.

An example future event:

```json
{
  "type": "cache_purge",
  "payload": "{\"zone\":\"default\",\"target\":\"user-123\"}"
}
```

Consumers may react to that, but the canonical purge result is still the
shared metadata mutation and the HTTP response.

---

## Failure Handling

Config-time failures:

- missing zone
- invalid `max_keys`
- unsupported match mode for the current implementation
- unsupported auth mode for the current implementation

Runtime failures:

- unsupported method
- malformed JSON
- too many targets
- unauthorized request
- shared metadata zone unavailable

Non-error outcomes:

- zero-hit purge
- exact target exists but counts to zero due to already-removed metadata

Those should be explicit in the response body.

---

## Observability

Version 1 should expose:

- zone name
- match mode
- requested target count
- purged count
- missing count
- rejected count

Later versions may add:

- auth result detail
- elapsed invalidation time
- last error category

but the first useful implementation only needs truthful request accounting.

---

## Phase Plan

### Phase 1 - Truthful operator API

Build:

- real config validation
- one stable `POST` contract
- request bounds
- stable success/error responses

Do not build yet:

- prefix/glob
- signed-token auth
- worker-events fanout

### Phase 2 - Exact invalidation core

Build:

- exact tag invalidation against shared metadata
- bounded batch support
- multi-worker tests

Only after exact invalidation is stable should the module consider:

- prefix scans over the same metadata

### Phase 3 - Broader matching, auth depth, and fanout

Only after the exact path is production-credible should the module add:

- allowlist or signed-token auth
- prefix mode if the metadata cost is acceptable
- optional worker-events fanout
- glob only if there is a compelling operational case

---

## Intended Non-Features

Version 1-3 should still avoid:

- external Redis dependency as a prerequisite
- unbounded scans
- pretending metadata deletion equals full cache object purge unless it truly
  does
- requiring worker-events for single-node correctness

If later work adds true cache-object invalidation or more powerful matching,
that should be a documented contract upgrade, not silent scope drift.

---

## Concrete Next Steps

1. formalize the shared metadata contract with `cache-tags`
2. replace placeholder `501` with a method-aware JSON API
3. implement exact tag invalidation first
4. add multi-worker tests around shared metadata mutation
5. only then decide whether prefix mode is cheap enough to justify
6. add worker-events fanout later as acceleration, not correctness

That sequence keeps the module honest: first make targeted invalidation real,
then make it richer.
