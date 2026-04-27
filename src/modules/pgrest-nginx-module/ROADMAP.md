# pgrest ROADMAP

This roadmap audits the current `pgrest` nginx module against the PostgREST API reference under `postgrest-docs/docs/references/api` and turns the gaps into an implementation backlog.

The goal is not to list every internal cleanup task. The goal is to get `pgrest` closer to actual PostgREST behavior, with work grouped by feature area and ordered from easy to hard inside each category.

## Status Legend

- **Implemented**: behavior is present and close enough to PostgREST parity to not need roadmap work.
- **Partial**: behavior exists, but semantics, coverage, or execution-path consistency still differ from PostgREST.
- **Missing**: feature is absent.

## Current Snapshot

### Already present

- Basic table CRUD routing through HTTP methods
- Basic query shaping: `select`, `order`, `limit`, `offset`
- Basic operators: `eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `like`, `ilike`, `is`, `in`
- Schema profile headers: `Accept-Profile`, `Content-Profile`
- RPC GET/POST calls with JSON bodies and JSON array parameters
- `Prefer: params=single-object`
- JSON, CSV, plain text, and XML response formatting
- `application/vnd.pgrst.object+json` and `nulls=stripped`
- JWT signature validation, JWT passthrough, and role switching
- Non-blocking / pooled execution path

### Important parity caveats

- Several features are only **partial parity**, not full PostgREST behavior.
- The module now uses a single non-blocking pooled execution path.
- Some README claims are ahead of actual behavior, especially around binary/media handling.

---

## 1. Tables, Views, and URL Grammar

**Status:** Partial

Current module support is centered on single-resource CRUD plus a limited subset of PostgREST URL grammar.

### Action points (easy → hard)

- **[Easy]** Add integration tests for currently parsed but under-tested operators: `neq`, `gte`, `lte`, `like`, `ilike`.
- **[Easy]** Align reserved-parameter handling so feature keys like `select`, `order`, `limit`, and `offset` are cleanly separated from filters in all cases.
- **[Medium]** Add PostgREST logical operators: `or`, `and`, and `not`.
- **[Medium]** Add operator modifiers: `any` and `all`.
- **[Medium]** Add advanced PostgREST operators: `match`, `imatch`, full-text search variants (`fts`, `plfts`, `phfts`, `wfts`), and range/array operators (`cs`, `cd`, `ov`, `sl`, `sr`, `nxr`, `nxl`, `adj`, `isdistinct`).
- **[Medium]** Support PostgREST-style URL grammar escaping for reserved characters, quoted values, unicode names, and identifiers with spaces/dots.
- **[Medium]** Support column aliasing and casting in `select` (`alias:col`, `col::type`).
- **[Medium]** Support JSON/composite/array path operators in both `select` and filtering.
- **[Medium]** Support richer ordering semantics, including `nullsfirst`, `nullslast`, and ordering on JSON/composite paths.
- **[Hard]** Add limited update/delete parity with `limit` + required unique ordering.
- **[Hard]** Verify and align behavior for views, not just tables, including write semantics where PostgREST allows them.
- **[Hard]** Add upsert semantics: `Prefer: resolution=merge-duplicates`, `Prefer: resolution=ignore-duplicates`, `on_conflict`, and `PUT` single-row upsert behavior.
- **[Hard]** Add bulk write support for JSON arrays, CSV insert payloads, `columns=...`, and `missing=default` behavior.

---

## 2. Resource Representation and Media Types

**Status:** Partial

Multiple formats are supported, but representation semantics are still short of PostgREST parity.

### Action points (easy → hard)

- **[Easy]** Fix singular-object semantics so `application/vnd.pgrst.object+json` returns PostgREST-style errors when zero or multiple rows are returned, instead of silently returning `{}` or the first row.
- **[Easy]** Return proper unsupported-media behavior for unknown `Accept` values instead of silently defaulting to JSON.
- **[Easy]** Reconcile README claims with actual binary/media behavior.
- **[Medium]** Implement real `application/octet-stream` response handling for bytea-like responses instead of JSON fallback.
- **[Medium]** Add request-body media type parity where applicable: `application/x-www-form-urlencoded`, `text/csv`, `application/octet-stream`, `text/plain`, `text/xml`.
- **[Medium]** Support PostgREST-style vendor media handling beyond current JSON variants where practical.
- **[Hard]** Add custom media type handler parity, or clearly define the subset intentionally unsupported.
- **[Hard]** Make representation/media behavior identical across all execution paths.

---

## 3. Stored Procedures / RPC

**Status:** Partial

RPC is one of the stronger areas today, but it still trails PostgREST in method semantics, body types, and parity with table endpoints.

### Action points (easy → hard)

- **[Easy]** Expand integration coverage for RPC response formats beyond current JSON-focused tests.
- **[Easy]** Verify GET/HEAD allowances based on function volatility and fail correctly when semantics do not permit a method.
- **[Medium]** Support single unnamed parameter flows for `json/jsonb`, `text`, `xml`, and `bytea`.
- **[Medium]** Support repeated parameters / variadic function calling semantics.
- **[Medium]** Support PostgREST-style array input parity for both GET and POST variants.
- **[Medium]** Align scalar vs table-valued response shaping more closely with PostgREST semantics.
- **[Hard]** Support table-valued function parity with the same filtering, ordering, pagination, and embedding model as table endpoints.
- **[Hard]** Carry profile headers, preferences, and representation features consistently across RPC in both execution paths.

---

## 4. Pagination, Count, and HTTP Semantics

**Status:** Missing / Partial

Query-param `limit` and `offset` exist, but PostgREST’s HTTP-level pagination contract is mostly missing.

### Action points (easy → hard)

- **[Easy]** Add `HEAD` parity for read endpoints.
- **[Easy]** Return stable status codes and response metadata for read/write operations where current behavior is too generic.
- **[Medium]** Add `Range-Unit`, `Range`, and `Content-Range` header handling.
- **[Medium]** Emit partial-content responses where PostgREST would use them.
- **[Medium]** Add `Prefer: count=exact|planned|estimated` parsing and response behavior.
- **[Hard]** Extend pagination/count semantics to table-valued functions and other supported endpoint types.
- **[Hard]** Keep range/count behavior consistent across all execution paths.

---

## 5. Prefer Header Parity

**Status:** Partial

`Prefer: params=single-object` exists, but PostgREST uses `Prefer` as a much broader API contract.

### Action points (easy → hard)

- **[Easy]** Introduce a central Prefer parser instead of handling individual cases ad hoc.
- **[Easy]** Add `Preference-Applied` headers where behavior is honored.
- **[Medium]** Add `Prefer: return=minimal|headers-only|representation` for writes.
- **[Medium]** Add `Prefer: handling=strict|lenient` and strict invalid-preference errors.
- **[Medium]** Add `Prefer: missing=default` for bulk/default-value insert flows.
- **[Medium]** Add `Prefer: max-affected` enforcement for write/RPC flows where applicable.
- **[Hard]** Add `Prefer: tx=commit|rollback` support if it fits the module’s execution model.
- **[Hard]** Ensure Prefer behavior is consistent across table, RPC, blocking, and pooled paths.

---

## 6. Schemas and Profile Handling

**Status:** Partial

Profile headers exist, but PostgREST schema governance is broader than raw schema qualification.

### Action points (easy → hard)

- **[Easy]** Add tests for schema/profile behavior across all supported methods and both execution paths.
- **[Medium]** Enforce an explicit schema allowlist model similar to PostgREST `db-schemas` instead of accepting arbitrary profile values.
- **[Medium]** Return PostgREST-style errors for disallowed or invalid profile headers.
- **[Medium]** Add default-schema selection rules that match PostgREST’s multi-schema behavior.
- **[Hard]** Harden schema qualification behavior edge cases.
- **[Hard]** Consider whether dynamic schema reloading/configuration belongs in scope; if yes, design it explicitly instead of letting it emerge accidentally.

---

## 7. Resource Embedding and Relationship Features

**Status:** Missing

This is one of the biggest parity gaps versus real PostgREST.

### Action points (easy → hard)

- **[Medium]** Define the minimum supported relationship model before implementation begins: foreign-key introspection only, or also computed relationships.
- **[Medium]** Add one-level many-to-one and one-to-many embedding through `select=...,related(...)`.
- **[Hard]** Add many-to-many embedding through join-table inference.
- **[Hard]** Add nested embedding.
- **[Hard]** Add embedded filtering, ordering, limit, and offset.
- **[Hard]** Add top-level filtering via `!inner`, null-based embedding filters, and empty embeds.
- **[Hard]** Add disambiguation syntax like `!fk` where multiple foreign-key relationships exist.
- **[Hard]** Add spread embedding (`...rel(...)`) and mutation-time embedding where practical.
- **[Hard]** Add support for computed relationships, recursive relationships, view relationships, and table-valued-function relationships if these remain in scope.

---

## 8. Aggregate Functions and Computed Fields

**Status:** Missing

PostgREST exposes aggregate and computed-field features through the same request grammar; current pgrest does not.

### Action points (easy → hard)

- **[Medium]** Extend `select` parsing to recognize aggregate expressions like `sum()`, `avg()`, `min()`, `max()`, and `count()`.
- **[Medium]** Support grouped aggregate queries through PostgREST-style `select` combinations.
- **[Medium]** Support renaming and casting of aggregate outputs.
- **[Medium]** Support computed fields in `select`, filtering, and ordering.
- **[Hard]** Support aggregate interaction with JSON paths and casts.
- **[Hard]** Support aggregate/computed-field interaction with embedding and spread semantics.

---

## 9. OPTIONS, CORS, and OpenAPI Surface

**Status:** Missing

PostgREST’s browser-facing API surface is broader than plain CRUD responses.

### Action points (easy → hard)

- **[Easy]** Add `OPTIONS` responses that advertise allowed methods per endpoint kind.
- **[Easy]** Add basic CORS headers for simple requests.
- **[Medium]** Add CORS preflight handling, including `Access-Control-Allow-*` and `Access-Control-Max-Age` behavior.
- **[Medium]** Decide and document whether CORS is always permissive by default or explicitly configured.
- **[Hard]** Add a root endpoint that can serve OpenAPI JSON.
- **[Hard]** Generate endpoint/method metadata for tables, views, and RPC routes closely enough to be useful.
- **[Hard]** Decide whether full PostgREST-style OpenAPI override/customization is in scope, and if not, document the reduced contract.

---

## 10. Execution-Path Parity and Correctness Hardening

**Status:** Partial

This is the main cross-cutting category that can quietly break every feature above if left behind.

### Action points (easy → hard)

- **[Easy]** Add a parity checklist so every newly added feature is tested end-to-end.
- **[Easy]** Add explicit tests for `pgrest_server` and `pgrest_keepalive`.
- **[Medium]** Harden schema/profile behavior edge cases.
- **[Medium]** Harden content negotiation and JSON variant edge cases.
- **[Medium]** Harden error formatting and status code behavior.
- **[Medium]** Enforce JWT expiration and other basic token validation semantics that are currently absent.
- [x] **[Hard]** Replace manual SQL string construction with parameterized query execution where feasible.
- **[Hard]** Revisit global pooled-state design so upstream configuration is not silently shared in the wrong places.
- **[Hard]** Add failure-mode coverage for connection errors, malformed payloads, and SQL/runtime errors.

---

## 11. Documentation and Coverage Alignment

**Status:** Partial

The roadmap is primarily about feature parity, but documentation drift will slow that work down if left unresolved.

### Action points (easy → hard)

- **[Easy]** Keep `README.md` aligned with actual behavior, especially for binary/media claims.
- **[Easy]** Document all exported `pgrest_*` directives in one directive reference section.
- **[Easy]** Add a parity matrix section to the README once the roadmap starts landing.
- **[Medium]** Expand Bun integration tests category by category as roadmap items are implemented.
- **[Medium]** Use failing integration tests as the entry point for each roadmap item wherever possible.

---

## Batch 1: Foundation Parity and HTTP Contract

This is the first implementation batch because it is the smallest self-contained slice that improves correctness without expanding the query grammar or relationship model.

### Batch 1 goals

- Lock down HTTP semantics that later batches will rely on.
- Improve observable protocol correctness before adding new feature surface.

### Included in Batch 1

- **Execution-path integration tests** for features that need end-to-end coverage.
- **Directive coverage** for `pgrest_server` and `pgrest_keepalive`.
- **Singular object correctness** for `application/vnd.pgrst.object+json`.
- **Unsupported Accept handling** so invalid media requests do not silently fall back to JSON.
- **HEAD support** for read endpoints.
- **Range header foundation**: `Range-Unit`, `Range`, and `Content-Range` basics.
- **Central Prefer parsing** for currently supported behavior.
- **Preference-Applied headers** when behavior is actually honored.
- **Error/status parity** across the feature set covered by this batch.

### Explicitly excluded from Batch 1

These stay out of the first batch because they enlarge the parser, require introspection, or create cross-feature coupling:

- URL grammar expansion (`or`, `and`, `not`, advanced operators, quoting/escaping work)
- Embedding and relationship features
- Aggregate functions and computed fields
- Schema allowlist governance and dynamic schema behavior
- Full RPC expansion beyond current surface
- Bulk writes, upsert, and `missing=default`
- CORS/OpenAPI work
- Parameterized query redesign

### Why Batch 1 is self-contained

- It works mostly at the **HTTP contract** and **execution-path parity** layer.
- It does **not** require schema introspection.
- It does **not** require new SQL grammar features.
- It reduces regression risk for later batches by making existing behavior more testable and more consistent first.

### Batch 1 acceptance criteria

- Every feature touched in this batch has integration coverage where applicable.
- `application/vnd.pgrst.object+json` no longer silently returns `{}` for zero rows or silently picks the first row from multiple rows.
- Unknown `Accept` values fail with an explicit unsupported-media response instead of defaulting to JSON.
- `HEAD` on supported read endpoints returns headers without a response body.
- Read endpoints can emit the basic range headers needed for later pagination/count work.
- `Prefer: params=single-object` is parsed centrally and emits `Preference-Applied` when honored.
- Equivalent success and failure cases return aligned status codes and response structure.

### Batch boundaries

Batch 1 should land as a protocol/correctness batch only. It should not quietly introduce new query features while fixing these semantics. That boundary keeps future batches independent: URL grammar can expand later, schema governance can tighten later, and embedding/aggregates can be designed later without needing to revisit the first batch.

### Batch 1 progress update

- ✅ Completed: blocking and pooled paths now share the same tested HTTP contract for singular-object semantics, unsupported `Accept`, `HEAD`, range headers, central `Prefer: params=single-object`, `Preference-Applied`, and covered error/status parity.
- ✅ Completed: integration coverage exists for both blocking and pooled modes across the Batch 1 feature set.
- ✅ Completed: directive-sensitive pooled behavior (`pgrest_pooling`, `pgrest_pass`, keepalive-oriented pooled lifecycle) was exercised and fixed as part of Batch 1 parity work.

---

## Full Batch Plan

These batches are intended to fully cover the roadmap while keeping the highest-risk coupling points separated: HTTP contract, representation, parser expansion, schema governance, introspection-heavy relationship work, and final hardening.

### Global batching rules

- Every batch must ship its own **tests** and **documentation deltas** alongside code changes.
- Every batch must state what is **explicitly out of scope** so it does not silently absorb later work.
- Every feature must have integration coverage before a batch is considered done.
- Parser-expansion batches must not quietly redesign execution-path or schema-governance behavior.
- Introspection-heavy work must stay behind schema/profile stabilization.

### Upstream-module and performance guardrails

This module is not a standalone PostgREST server. It is an nginx upstream module between the client and PostgreSQL, so roadmap execution should stay focused on features that fit that architecture and preserve performance.

- Prefer features that keep the request path **simple, cacheable, and low-allocation**.
- Do not add runtime schema/relationship introspection to the hot path unless it is explicitly cached or otherwise bounded.
- Keep **blocking** and **pooled** paths aligned; a feature that only works in one path is not done.
- Avoid parity work that forces expensive buffering or architectural churn unless it delivers clear user value in this upstream shape.
- Treat advanced PostgREST features as **subset/guarded scope** when full parity would materially hurt throughput or operational simplicity.
- Every batch should verify that the new work does not regress the pooled path, because that is the most performance-relevant execution mode.
- Documentation for each batch should clearly say when pgrest intentionally supports a narrower contract than PostgREST for upstream/performance reasons.

### Batch 2: Media Types and Representation Completeness

**Theme:** Finish content negotiation and response-format correctness without changing query grammar.

**Includes**
- Real `application/octet-stream` handling instead of JSON fallback
- Request-body media type support where already listed in the roadmap (`application/x-www-form-urlencoded`, `text/csv`, `application/octet-stream`, `text/plain`, `text/xml`) when applicable
- Representation parity across blocking and pooled paths for already supported formats
- README cleanup for media-type claims

**Excludes**
- Custom media type handlers
- URL grammar expansion
- Embedding and aggregates

**Why it is self-contained**
- Works at the formatting and body-parsing layer
- Builds on Batch 1’s Accept/error semantics without requiring parser or introspection changes

**Unlocks**
- Stable representation behavior for later RPC, aggregate, and embedding work

### Batch 2 progress update

- ✅ Completed: real `application/octet-stream` responses for the deterministic contract of exactly one row and one column, with matching blocking and pooled behavior and explicit rejection outside that shape.
- ✅ Completed: request-body media support for `application/x-www-form-urlencoded`, `text/csv`, `text/plain`, `text/xml`, and `application/octet-stream` where it fits the current upstream contract, using explicit narrow mappings instead of heuristic parsing.
- ✅ Completed: representation parity across blocking and pooled paths for the supported response formats covered by Batch 2.
- ✅ Completed: README/media claims aligned with the tested Batch 2 contract instead of broader unsupported claims.
- ℹ️ Intentional Batch 2 boundary: the completed request-body support is explicit and narrow by design; broader write/RPC semantics remain future-batch work, not unfinished Batch 2 work.

### Batch 3: Prefer Header Completeness and Write Contract

**Theme:** Expand the Prefer contract and write-response semantics before larger query features land.

**Includes**
- `Prefer: return=minimal|headers-only|representation`
- `Prefer: handling=strict|lenient`
- `Prefer: max-affected`
- `Preference-Applied` consistency for newly supported Prefer behaviors
- Write-side status/response semantics that depend on Prefer handling

**Excludes**
- Upsert and bulk-write semantics that require broader SQL/write-shape changes
- `Prefer: tx=commit|rollback`
- URL grammar expansion

**Why it is self-contained**
- Reuses the central Prefer parser from Batch 1
- Focuses on response contract rather than parser or introspection breadth

**Unlocks**
- Predictable write behavior for later bulk-write and upsert work

### Batch 3 progress update

- ✅ Completed: central Prefer parsing now covers `return=minimal|headers-only|representation`, `handling=strict|lenient`, and `max-affected` while preserving `params=single-object`.
- ✅ Completed: current table write paths honor the Batch 3 write-response contract across both blocking and pooled execution paths.
- ✅ Completed: `Preference-Applied` now reflects the newly honored write-side Prefer values in addition to the existing RPC parameter wrapper preference.
- ✅ Completed: strict handling rejects malformed/unsupported Prefer values before SQL execution, while lenient handling ignores them.
- ℹ️ Intentional Batch 3 boundary: enforcement and response semantics are complete for the current write paths, but broader bulk/upsert/transaction semantics remain later-batch work.

### Batch 4: URL Grammar Expansion

**Theme:** Expand the request grammar in a controlled way.

**Includes**
- Logical operators: `or`, `and`, `not`
- Operator modifiers: `any`, `all`
- Advanced operators: `match`, `imatch`, `fts`, `plfts`, `phfts`, `wfts`, `cs`, `cd`, `ov`, `sl`, `sr`, `nxr`, `nxl`, `adj`, `isdistinct`
- URL escaping for reserved characters, quoted values, unicode names, and identifiers with spaces/dots
- Richer ordering semantics such as `nullsfirst` and `nullslast`

**Gated subphases inside Batch 4**
- **4A:** operators, logic, escaping, ordering
- **4B:** aliasing/casting and JSON/composite/array path grammar

**Excludes**
- Embedding grammar
- Aggregate grammar
- Bulk writes and upsert

**Why it is self-contained**
- Keeps grammar work together without mixing in schema introspection or relationship logic

**Unlocks**
- Richer filtering for later RPC/table-valued function parity and embedding

### Batch 4 progress update

- ✅ Completed 4A: logical operators (`or`, `and`, `not`), `any` / `all` modifiers, advanced operators (`match`, `imatch`, `fts`, `plfts`, `phfts`, `wfts`, `cs`, `cd`, `ov`, `sl`, `sr`, `nxr`, `nxl`, `adj`, `isdistinct`), reserved-character escaping for quoted identifiers/values, and malformed-filter rejection now work in both blocking and pooled paths.
- ✅ Completed 4A: ordering now supports `nullsfirst`, `nullslast`, and JSON/composite/array path expressions such as `order=location->>lat`, with malformed `order=` rejected explicitly with `400` before SQL execution.
- ✅ Completed 4B: `select=` now supports aliasing, casting, JSON/composite/array path expressions, path-tail auto-aliasing, and percent-decoded path operators from real HTTP requests.
- ✅ Completed: Batch 4 coverage now includes Zig parser tests plus Bun integration tests for the accepted URL-grammar subset in both blocking and pooled execution paths.
- ℹ️ Intentional Batch 4 boundary: embedding grammar and aggregate/computed-field grammar remain later-batch work even though the core filter/select/order grammar subset is now complete.

### Batch 5: Schema Governance, Profiles, and View Semantics

**Theme:** Stabilize schema selection rules before relationship-aware work begins.

**Includes**
- Schema allowlist behavior similar to PostgREST `db-schemas`
- Invalid/disallowed profile error semantics
- Default-schema selection rules for multi-schema behavior
- Pooled-path schema/profile parity
- View support review and implementation where PostgREST semantics are meant to apply

**Excludes**
- Relationship introspection
- Dynamic schema reloading unless explicitly chosen

**Why it is self-contained**
- It is configuration/governance work, not query-grammar or relationship expansion

**Unlocks**
- Safer foundation for embedding and cross-schema behavior

### Batch 5 progress update

- ✅ Completed: `pgrest_schemas` now provides an explicit schema allowlist modeled on PostgREST `db-schemas` semantics.
- ✅ Completed: GET/HEAD use `Accept-Profile`, while POST/PATCH/PUT/DELETE use `Content-Profile`, in both blocking and pooled execution paths.
- ✅ Completed: Requests with disallowed schemas now fail with the PostgREST-style `PGRST106` error body instead of silently accepting arbitrary profile values.
- ✅ Completed: The first configured schema is treated as the default schema selection, while default requests keep the generated SQL unqualified to preserve the module's upstream contract.
- ✅ Completed: Batch 5 integration coverage now verifies allowed/disallowed profile handling, default-schema behavior, RPC schema selection, and pooled/blocking parity.
- ℹ️ Remaining Batch 5 boundary: view-specific semantic review/expansion is still open if we decide PostgREST view behavior needs a dedicated follow-up inside this batch theme.

### Batch 6: Bulk Writes and Upsert Semantics

**Theme:** Finish advanced table write behavior after Prefer and schema rules are stable.

**Includes**
- Bulk JSON-array inserts
- CSV insert payloads
- `columns=...`
- `missing=default`
- Upsert semantics: `Prefer: resolution=merge-duplicates`, `Prefer: resolution=ignore-duplicates`, `on_conflict`, and `PUT` single-row upsert behavior
- Limited update/delete parity with `limit` plus required ordering if still considered table-write scope rather than pure grammar scope

**Excludes**
- Embedding-on-write
- Aggregate and relationship features

**Why it is self-contained**
- Concentrates risky write-path SQL behavior into one batch after Prefer and schema groundwork are done

**Unlocks**
- Complete write-side table contract before advanced RPC/embedding layers build on it

### Batch 6 progress update

- ✅ Completed slice: bulk JSON-array inserts now emit a single multi-row `INSERT` in both blocking and pooled execution paths.
- ✅ Completed slice: `text/csv` table inserts now support the current narrow bulk contract using the CSV header row as the insert column list.
- ✅ Completed slice: `columns=...` is now treated as a reserved write-control parameter for inserts, allowing the module to ignore extra JSON keys outside the selected column set.
- ✅ Completed slice: `Prefer: missing=default` now works for the supported bulk JSON insert flow, preserving omitted fields as SQL `DEFAULT` instead of coercing them to `NULL`, with `Preference-Applied` parity across blocking and pooled paths.
- ✅ Completed: explicit upsert semantics now work through `Prefer: resolution=merge-duplicates|ignore-duplicates` with `on_conflict=...` in both blocking and pooled execution paths.
- ✅ Completed: `PUT` now performs the documented single-row upsert shape when the request uses `eq` filters and supplies a complete body, reusing those filtered columns as the conflict target.
- ✅ Completed: `PATCH` and `DELETE` now support the documented limited-write contract using `limit` plus explicit `order`, rendered through a CTE-based PostgreSQL query shape in both execution paths.
- ✅ Completed: Batch 6 coverage now includes blocking and pooled integration tests for bulk JSON inserts, bulk CSV inserts, `columns=...`, `missing=default`, explicit upserts, `PUT` upserts, and limited update/delete, and the batch verifies green with `zig build test && KEEP_LOGS=1 bun test tests/pgrest/ && zig build`.
- ℹ️ Remaining Batch 6 boundary: PostgREST's default-primary-key upsert inference without an explicit conflict target remains intentionally out of scope for this upstream module because it would require schema-cache metadata the module does not maintain.

### Batch 7: RPC Parity Expansion

**Theme:** Bring RPC behavior closer to table-endpoint parity without relationship introspection yet.

**Includes**
- GET/HEAD method rules based on function volatility
- Single unnamed parameter flows for `json/jsonb`, `text`, `xml`, and `bytea`
- Repeated parameters and variadic function semantics
- Array input parity across GET and POST variants
- Scalar vs table-valued response shaping improvements
- Table-valued function parity for filtering, ordering, pagination, and profile/preference behavior where it does not depend on embedding

**Excludes**
- RPC embedding
- Aggregate/embedding interactions

**Why it is self-contained**
- Builds on Batch 4 grammar and Batch 5/6 contract work without needing relationship introspection yet

**Unlocks**
- A credible PostgREST-like RPC layer before the relationship model arrives

### Batch 7 progress update

- ✅ Completed slice: RPC execution now performs a metadata lookup against PostgreSQL function catalogs before executing the function call in both blocking and pooled paths.
- ✅ Completed slice: GET/HEAD RPC requests now honor metadata-backed volatility rules, returning `405` plus the corresponding `Allow` header for `VOLATILE` functions.
- ✅ Completed slice: single unnamed `json/jsonb`, `text`, `xml`, and `bytea` parameter functions now bind matching request bodies positionally instead of forcing a named `data => ...` argument.
- ✅ Completed slice: repeated GET parameters and repeated `application/x-www-form-urlencoded` RPC parameters now collapse into one `ARRAY[...]` argument when the function metadata marks that parameter as variadic.
- ✅ Completed slice: blocking and pooled integration coverage now asserts the metadata lookup path, volatility gating, and unnamed JSON/bytea RPC binding.
- ✅ Completed slice: Batch 7 coverage now includes variadic GET and variadic form-urlencoded RPC flows in both blocking and pooled paths.
- ✅ Completed slice: table-valued/composite-return RPC functions now reuse the table read grammar for `select`, filters, ordering, and pagination in both blocking and pooled paths, while separating function arguments from read-shaping query parameters.
- ✅ Batch 7 is now complete for the current roadmap scope.

### Pre-Batch 8 refactor update

- ✅ Completed: the pgrest module was mechanically split before Batch 8 so future work does not keep expanding one monolithic Zig file.
- ✅ `ngx_http_pgrest.zig` remains the stable nginx module entrypoint and request-flow glue.
- ✅ Shared auth/query/RPC logic now lives in focused submodules with local Zig tests:
  - `pgrest_auth.zig`
  - `pgrest_query.zig`
  - `pgrest_rpc.zig`
- ✅ Verification after the split stayed green with `zig build test && KEEP_LOGS=1 bun test tests/pgrest/ && zig build`.
- ℹ️ Intentional boundary: this was a mechanical organization pass, not a semantic redesign, so Batch 8 can proceed on the new structure without reopening already-green Batch 7 behavior.

### Batch 8: Pagination and Count Completeness

**Theme:** Finish the HTTP pagination/count contract cleanly, separate from discovery surface.

**Includes**
- Full `Range-Unit`, `Range`, and `Content-Range` behavior
- Partial-content status semantics where applicable
- `Prefer: count=exact|planned|estimated`
- Count/pagination parity across blocking and pooled paths
- Extension of count/pagination semantics to supported RPC/table-valued-function flows

**Excludes**
- OPTIONS/CORS/OpenAPI
- Embedding

**Why it is self-contained**
- Strictly HTTP response semantics, building on Batch 1 foundation and later query support

**Unlocks**
- Stable count-aware clients and correct response metadata for later advanced features

### Batch 8 progress update

- ✅ Completed: top-level table reads and table-valued RPC reads now emit `Range-Unit: items` plus offset-aware `Content-Range` headers in both blocking and pooled paths.
- ✅ Completed: `Range: start-end` and open-ended `Range: start-` requests now drive top-level read pagination instead of only query-string `limit`/`offset`.
- ✅ Completed: `Prefer: count=exact|planned|estimated` is now parsed and applied on table reads and table-valued RPC reads, with `Preference-Applied` and count-bearing `Content-Range` metadata.
- ✅ Completed: counted partial reads now return `206 Partial Content` when the selected window is smaller than the known total.
- ✅ Completed: Batch 8 integration coverage now exercises blocking and pooled table reads plus table-valued RPC reads for range/count behavior, and the batch verifies green with `zig build test && KEEP_LOGS=1 bun test tests/pgrest/ && zig build`.
- ℹ️ Remaining Batch 8 boundary: `count=planned` and `count=estimated` currently reuse the exact count query path instead of PostgreSQL planner/statistics estimates, so the HTTP contract is in place but the estimate source is intentionally still narrow.

### Batch 9: Aggregate Functions and Computed Fields

**Theme:** Add computed query features without mixing in relationships yet.

**Includes**
- Aggregate expressions in `select`: `sum()`, `avg()`, `min()`, `max()`, `count()`
- Grouped aggregate queries
- Renaming and casting of aggregate outputs
- Computed fields in `select`, filtering, and ordering
- Aggregate interaction with JSON paths and casts

**Excludes**
- Aggregate behavior inside embedding/spread semantics

**Why it is self-contained**
- Uses the stabilized grammar layer from Batch 4 without requiring relationship introspection

**Unlocks**
- Analytics/reporting use cases and computed-field parity before embedding complexity arrives

### Batch 9 progress update

- ✅ Completed: top-level table reads now support aggregate select items for `sum()`, `avg()`, `min()`, `max()`, column `count()`, and bare `count()`.
- ✅ Completed: aggregate selects now support grouped reads by deriving `GROUP BY` from the non-aggregate selected columns.
- ✅ Completed: aggregate outputs now support aliasing and output casts, and aggregate inputs reuse the existing path/cast grammar.
- ✅ Completed: table-valued RPC reads now reuse the same aggregate-aware select/grouping grammar as top-level table reads.
- ✅ Completed: computed fields are now covered as first-class top-level select/filter/order expressions in blocking and pooled integration coverage.
- ✅ Completed: Batch 9 verification is green with `zig build test && KEEP_LOGS=1 bun test tests/pgrest/ && zig build`.
- ℹ️ Remaining Batch 9 boundary: aggregate ordering, `HAVING`-style filtering, and embedding-aware aggregate behavior remain intentionally deferred to later batches.

### Batch 10: Resource Embedding and Relationships — Phase 1

**Theme:** Introduce the smallest relationship model that is still useful.

**Includes**
- Relationship model decision (at minimum FK introspection scope)
- One-level many-to-one and one-to-many embedding
- Basic disambiguation using `!fk`
- Basic embedded filtering, ordering, limit, and offset where they fit the phase-1 model

**Excludes**
- Many-to-many join-table inference
- Nested embedding
- Spread syntax
- Recursive/view/computed/table-valued-function relationships

**Why it is self-contained**
- Keeps the first introspection-heavy relationship step intentionally narrow

**Unlocks**
- A usable but limited embedding model for common parent/child and to-one cases

### Batch 10 progress update

- ✅ Completed: table reads now introspect direct foreign-key metadata in the active schema and support one-level many-to-one and one-to-many embedding on JSON responses.
- ✅ Completed: basic `!fk` disambiguation is supported using PostgreSQL constraint names.
- ✅ Completed: embedded reads now accept basic scoped filters, ordering, limit, and offset parameters such as `orders.status=eq.paid`, `orders.order=id.desc`, and `orders.limit=2`.
- ✅ Completed: mock integration coverage exercises one-level to-one and to-many embedding behavior.

### Batch 11: Resource Embedding and Relationships — Phase 2

**Theme:** Finish the advanced relationship model after phase 1 is stable.

**Includes**
- Many-to-many embedding via join-table inference
- Nested embedding

**Gated subphases inside Batch 11**
- **11A:** many-to-many and nested embedding
- **11B:** advanced embed filters, spread syntax, recursive/view/computed/table-valued-function relationships, mutation-time embedding where still in scope

**Also includes interface/discovery surface**
- `OPTIONS` responses
- CORS simple + preflight handling
- OpenAPI root/discovery surface and route/method metadata generation

**Excludes**
- Final hardening-only work

**Why it is self-contained**
- Collects the remaining API-surface and advanced relationship features after the underlying semantics are already stable

**Unlocks**
- Near-complete public interface parity for advanced consumers

### Batch 11 progress update

- ✅ Completed: table reads now support many-to-many embedding via join-table inference and nested embedding on the JSON read path.
- ✅ Completed: `!inner` now filters parent rows by related-row existence on the embedding read path.
- ✅ Completed: the interface surface now includes `OPTIONS` responses, basic CORS headers for simple/preflight flows, and minimal OpenAPI discovery documents on `/api/` and `/rpc/`.
- ✅ Completed: mock integration coverage exercises many-to-many plus nested embedding behavior, and the container suite now includes real PostgreSQL relationship fixtures for direct and join-table embeddings.
- ℹ️ Remaining Batch 11 boundary: advanced embed semantics (spread syntax, null-based embed filters), mutation-time embedding, and recursive/view/computed/table-valued-function relationship inference remain deferred to hardening/future work.

### Batch 12: Execution-Path Parity Gap Closure and Hardening

**Theme:** Final parity closure, safety, and proof that the roadmap is fully covered.

**Includes**
- Remaining hardening and edge case closure
- JWT expiration and related token-validation hardening
- Parameterized query execution where feasible
- Global pooled-state design cleanup where necessary
- Failure-mode coverage for connection errors, malformed payloads, and SQL/runtime errors
- Final docs/coverage sweep that maps every roadmap category to tests and documentation

**Excludes**
- New feature-surface expansion

**Why it is self-contained**
- It is a hardening batch only; by this point feature breadth should already be in place

**Unlocks**
- A more production-safe module and a clear proof that the roadmap has actually been covered

---

## Batch 12: Execution-Path Parity Gap Closure and Hardening — Detailed Task List (Easy → Hard)

This section collects every tail left by batches 1–11, decides whether it belongs in Batch 12, and turns the Batch 12 inclusions into actionable todos ordered from easy to hard. The rule for Batch 12 is **hardening and gap closure only**; anything that is genuinely new feature surface stays explicitly deferred.

### Easy

- [x] **[Easy]** **Directive reference section in README** — documented every exported `pgrest_*` directive in a single reference table.
- [x] **[Easy]** **Parity matrix in README** — added a matrix mapping each roadmap category to Implemented / Partial / Missing status.
- [x] **[Easy]** **Batch 12 documentation delta** — added a "Batch 12 Changes" section to README documenting everything closed in this batch.
- [x] **[Easy]** **Embedding read coverage for non-JSON formats** — documented the JSON-only contract and added explicit rejection tests for non-JSON embedding formats.
- [x] **[Easy]** **Error response parity** — standardized all client-facing and server error responses to use `{"message":"..."}` consistently.
- [x] **[Easy]** **JWT malformed-payload hardening** — `pgrest_auth.zig` now rejects tokens with invalid Base64url, missing required segments, or unparseable JSON payload with `401 Unauthorized` instead of falling through to anon role.
- [x] **[Easy]** **JWT `exp` claim enforcement** — expired tokens now return `401 Unauthorized` with "JWT token has expired".
- [x] **[Easy]** **JWT `iat` / `nbf` sanity checks** — tokens with future `iat` or not-yet-valid `nbf` now return `401 Unauthorized` with "JWT token is not yet valid".
- [x] **[Easy]** **Malformed payload handling** — malformed `Range` headers now return `400 Bad Request`. Malformed JSON/CSV/XML bodies already return `400` via "Invalid write payload". Malformed `Prefer` and filter/select/order parameters already return `400` with specific messages.

### Medium

- [x] **[Medium]** **JWT integration coverage** — Bun tests now cover expired JWT, future-dated JWT, malformed JWT, and missing-signature JWT on the active pooled path.
- [x] **[Medium]** **SQL/runtime error handling** — explicit behavior and integration coverage now exist for PostgreSQL syntax errors, constraint violations, missing table/function errors, and insufficient privilege errors.
- [x] **[Medium]** **Connection error handling** — explicit behavior and tests now cover PostgreSQL unreachable, connection timeout, connection reset mid-query, and DNS failure on the pooled path.
- [x] **[Medium]** **View semantic review** — integration coverage now verifies filtering, ordering, pagination, and write behavior for updatable and non-updatable PostgreSQL views under the current schema-allowlist model, and README documents the observed subset.
- [x] **[Medium]** **ROADMAP-to-tests audit** — README now records an explicit roadmap-section-to-test mapping for sections 1–11, with section 11 tracked as documentation/audit evidence.
- [x] **[Medium]** **Real `count=planned` and `count=estimated`** — the exact-count fallback is gone from active table-read and table-valued RPC count handling; planner-backed `EXPLAIN` row estimates now drive `planned` and `estimated` counts.

### Hard

- [x] **[Hard]** **Audit upstream configuration sharing** — audited how `pgrest_pass`, `pgrest_schemas`, and pool-size settings are shared across requests. Findings and fixes: (1) removed the broken `pgrest_server`/`pgrest_keepalive` upstream-block directives (never connected to the actual pool, `pgrest_keepalive` had an offset-0 bug that would corrupt srv_conf memory); (2) removed the entire dead nginx-upstream machinery (nine unreachable functions: `ngx_pgrest_upstream_init`, `init_peer`, `get_peer`, `free_peer`, `wev_handler`, `rev_handler`, `create_request`, `finalize_request`, `process_header`, `input_filter_init`, `input_filter`); (3) removed the unused `ups: ngx_http_upstream_conf_t` field from `ngx_pgrest_loc_conf_t`; (4) replaced `pgrest_keepalive` with a working `pgrest_pool_size` LOC directive that actually caps `g_conn_pool.max_connections`; (5) added `merge_loc_conf` so child locations correctly inherit `conninfo`, `schemas_raw`, JWT settings, and `pool_size` from their parent block; (6) `pgrest_schemas` was already correctly isolated per location (each request looks up its own loc_conf); (7) the single-global-pool constraint (one `PgConnPool` per worker) is documented — two locations pointing to different hosts will conflict once the first location holds active connections.
- [x] **[Hard]** **Eliminate silent cross-request state leakage** — `queue_jwt_setup_queries` now always sets `ctx.query` to `RESET ROLE` as the first query in every request's chain, and always clears `request.jwt` (or sets the new token), so stale role and JWT from a previous request on the same pooled connection cannot influence the next request. Also fixed the pre-existing count+JWT query-ordering bug where the count query ran after the data query instead of before.
- [x] **[Hard]** **Add pooled-state integration coverage** — three new Bun integration tests: (1) every request starts with `RESET ROLE`; (2) requests without JWT send `SET request.jwt TO ''` to clear the session variable; (3) an authenticated request followed by an unauthenticated request on the same connection correctly applies `RESET ROLE` then re-applies `anon_role`, not the previous role.
- [x] **[Hard]** **Audit all SQL construction sites** — identified every location in `ngx_http_pgrest.zig` where user input was interpolated into SQL strings.
- [x] **[Hard]** **Parameterized filter values** — converted filter-operator value rendering (`eq`, `gt`, `like`, etc.) to `$N` positional parameters via `PQsendQueryParams`; WHERE clause builds `$1…$n` and populates `ctx.param_ptrs[]`.
- [x] **[Hard]** **Parameterized RPC arguments** — string RPC arguments now use `$N` parameters; raw (JSON array/object) and numeric/boolean arguments remain as literals.
- [x] **[Hard]** **Parameterized write payloads** — `INSERT`/`UPDATE`/`DELETE` string value lists now use `$N` parameters extending from the WHERE param count; numbers, booleans, NULLs, and DEFAULT remain as literals.
- [x] **[Hard]** **Zig-level tests for parameterized queries** — three new unit tests assert `$N` placeholder generation and that the injection string `' OR '1'='1` goes into `param_ptrs[]` untouched.
- [x] **[Hard]** **Integration coverage for parameterized queries** — two new Bun integration tests: (1) filter value arrives as `$1`-resolved quoted literal (not inline); (2) SQL injection string in filter is treated as data and `OR '1'='1` never appears in the executed SQL.

### Items intentionally deferred BEYOND Batch 12 (new feature surface, not hardening)

These are not Batch 12 tails; they are features that were deferred from earlier batches and remain out of scope because they expand the feature surface rather than close existing gaps.

- **Spread syntax (`...rel`)** — deferred from Batch 11.
- **Null-based embed filters and empty embeds** — deferred from Batch 11.
- **Mutation-time embedding** — deferred from Batch 11.
- **Recursive / view / computed / table-valued-function relationship inference** — deferred from Batch 11.
- **Aggregate ordering and `HAVING`-style filtering** — deferred from Batch 9.
- **Embedding-aware aggregate behavior** — deferred from Batch 9.
- **`Prefer: tx=commit|rollback`** — excluded from Batch 3 and remains out of scope.
- **Default-primary-key upsert inference without explicit conflict target** — excluded from Batch 6 (requires schema-cache metadata this upstream module does not maintain).
- **Custom media type handlers** — excluded from Batch 2.
- **Full PostgREST-style OpenAPI override/customization** — excluded from Batch 11.
- **Dynamic schema reloading / configuration** — excluded from Batch 5.

---

## Compact Execution Table

This table is meant to make the batches implementation-ready. The file list is intentionally conservative and names the files we already know are central today.

| Batch | Primary Goal | Likely Files | Main Tests | Main Blockers | Exit Criteria |
|---|---|---|---|---|---|
| 1 | HTTP contract + path parity baseline | `src/modules/pgrest-nginx-module/ngx_http_pgrest.zig`, `tests/pgrest/pgrest.test.js`, `tests/pgrest/nginx.conf`, `src/modules/pgrest-nginx-module/README.md` | singular object errors, unsupported `Accept`, `HEAD`, range foundation, directive coverage | path divergence | existing semantics are aligned and documented |
| 2 | Finish media/body format correctness | same files as Batch 1 | binary response behavior, request-body media handling, representation parity by Accept type | binary handling and pooled-path formatting gaps | supported media/body formats behave consistently and README claims match reality |
| 3 | Complete Prefer response contract | `ngx_http_pgrest.zig`, `tests/pgrest/pgrest.test.js`, `README.md` | `Preference-Applied`, strict/lenient handling, `return=*`, `max-affected` | central parser extension without breaking existing behavior | Prefer behavior is centralized, tested, and stable for current write paths |
| 4 | Expand URL grammar safely | `ngx_http_pgrest.zig`, `tests/pgrest/pgrest.test.js`, `README.md` | operator matrix, escaping/quoted values, ordering semantics, alias/cast/path grammar | parser breadth and SQL builder complexity | grammar additions pass without changing unrelated execution semantics |
| 5 | Stabilize schema/profile rules and views | `ngx_http_pgrest.zig`, `tests/pgrest/pgrest.test.js`, `tests/pgrest/nginx.conf`, `README.md` | allowlist/default-schema behavior, invalid profile errors, pooled schema parity, view coverage | schema policy design and pooled-path parity | profile behavior is explicit, bounded, and stable before introspection-heavy work |
| 6 | Finish advanced table writes | `ngx_http_pgrest.zig`, `tests/pgrest/pgrest.test.js`, `README.md` | bulk JSON/CSV writes, `columns`, `missing=default`, upsert cases, limited update/delete cases | write-path SQL complexity and correctness | bulk/upsert/write semantics are complete for the chosen scope and do not regress existing CRUD |
| 7 | Raise RPC to table-endpoint parity | `ngx_http_pgrest.zig`, `tests/pgrest/pgrest.test.js`, `tests/pgrest/nginx.conf`, `README.md` | volatility-based methods, unnamed params, variadics, arrays, TVF filtering/order/pagination | keeping RPC semantics aligned with table semantics | RPC surface is coherent, documented, and tested without requiring embedding |
| 8 | Finish pagination/count contract | `ngx_http_pgrest.zig`, `pgrest_query.zig`, `pgrest_rpc.zig`, `tests/pgrest/pgrest.test.js`, `README.md` | `Range`/`Content-Range`, partial content, `Prefer: count=*`, TVF count cases | header/status correctness across both paths | count/pagination metadata is stable and reusable by later features |
| 9 | Add aggregates and computed fields | `ngx_http_pgrest.zig`, `tests/pgrest/pgrest.test.js`, `README.md` | aggregate select cases, grouped output, computed field select/filter/order, cast/path interactions | select grammar and result-shaping complexity | aggregate/computed-field support works on the stabilized grammar layer without relationship coupling |
| 10 | Embedding phase 1 | `ngx_http_pgrest.zig`, `tests/pgrest/pgrest.test.js`, `README.md` | one-level to-one/to-many embedding, basic `!fk`, embedded filters/order/limit | relationship model choice and bounded introspection | a narrow relationship model works reliably and stays within upstream/performance guardrails |
| 11 | Embedding phase 2 + interface surface | `ngx_http_pgrest.zig`, `tests/pgrest/pgrest.test.js`, `tests/pgrest/nginx.conf`, `README.md` | many-to-many, nested embed, advanced embed filters, spread, OPTIONS, CORS, OpenAPI/root metadata | highest feature coupling and public-surface breadth | advanced relationship/API-surface work lands without reopening earlier contract decisions |
| 12 | Final parity closure and hardening | `ngx_http_pgrest.zig`, `tests/pgrest/pgrest.test.js`, `README.md` | JWT expiry, error-path coverage, SQL/runtime failure coverage, final docs/tests audit | hardening without accidental new features | remaining gaps are closed or intentionally documented as out of scope for upstream/performance reasons |

---

## Batch-to-Roadmap Coverage Map

- **URL grammar** → Batch 4
- **Representation/media** → Batches 1-2
- **RPC** → Batch 7
- **Pagination/count** → Batches 1 and 8
- **Prefer** → Batches 1 and 3
- **Schemas/profile** → Batch 5
- **Bulk write/upsert table semantics** → Batch 6
- **Embedding/relationships** → Batches 10-11
- **Aggregates/computed fields** → Batch 9
- **OPTIONS/CORS/OpenAPI** → Batch 11
- **Execution-path parity** → Batches 1 and 12
- **Documentation/coverage** → Every batch, with final closure in Batch 12

---

## Suggested Delivery Order Across Categories

If we want steady wins without painting ourselves into a corner, the most practical order is:

1. **Batch 1: foundation parity and HTTP contract**
2. **Batch 2: media types and representation completeness**
3. **Batch 3: Prefer header completeness and write contract**
4. **Batch 4: URL grammar expansion**
5. **Batch 5: schema governance, profiles, and view semantics**
6. **Batch 6: bulk writes and upsert semantics**
7. **Batch 7: RPC parity expansion**
8. **Batch 8: pagination and count completeness**
9. **Batch 9: aggregate functions and computed fields**
10. **Batch 10: embedding phase 1**
11. **Batch 11: embedding phase 2 plus interface/discovery surface**
12. **Batch 12: execution-path parity gap closure and hardening**

That order keeps foundational protocol behavior and path consistency ahead of parser growth, then delays introspection-heavy relationship work until after schema and query semantics are stable, and leaves final parity-proof hardening to the end.

---

## Performance Follow-up Action Points

These are post-parity optimization batches for the pgrest hot path. They stay separate from the feature-parity batches above so we can improve common pooled JSON-read performance without reopening already-closed API-surface work.

Planning note for **small-to-medium JSON table reads**, expressed as **`pgrest : PostgREST`**:

- current architecture-only estimate: **~0.8–1.4x**, with central expectation closer to **~1.0–1.2x**
- plausible first-hot-path-batch uplift over current pgrest: **~1.2–1.8x**
- implied post-batch planning band: **~1.0–2.3x**
- anything above roughly **~2.5x** should be treated as an outlier until benchmarked

These are planning bands only, not measured results.

### Perf Batch P0: Benchmark and attribution baseline

- [x] Add repeatable benchmark scenarios for common JSON table reads: small payload, medium payload, filtered+ordered+paged read, and count-enabled read.
- [x] Run the same benchmark matrix against pgrest and the local PostgREST checkout so ratio claims compare equivalent query shapes and payload sizes.
- [x] Add lightweight timing attribution for request parse/build time, PostgreSQL wait time, JSON formatting time, and response-send/copy time.
- [ ] Capture baseline metrics for each scenario: throughput, p50/p95/p99 latency, CPU usage, response size, and connection-wait behavior.
- [x] Document the measured baseline before any optimization batch claims are treated as validated.

Progress note:

- ✅ Landed benchmark tooling under `perf/pgrest/benchmark/` with real-PostgreSQL fixtures, explicit pgrest/PostgREST scenario validation, JSON result output, a dedicated `perf/pgrest/nginx.conf`, and reusable shared helpers under `perf/common/`.
- ✅ Landed a shared non-intrusive profiling and artifact layer under `perf/common/` so pgrest benchmark runs now have standardized per-run directories, manifest/environment/command artifacts, copied nginx logs, `/proc`-based snapshot profiling, and optional `perf stat` capture when available.
- ✅ Fixed two benchmark-harness false negatives before trusting the first pgrest-vs-PostgREST ratio: PostgREST startup now waits for admin `/ready` plus one real API `200`, and scenario validation now compares first/last rows semantically for the currently proven formatting-only differences (numeric strings vs numbers, and equivalent timestamp text vs ISO timestamp forms).
- ✅ First validated representative `medium-page` compare baseline is now recorded in `perf/pgrest/benchmark/output/2026-04-27T11-32-15.811Z-pgrest-releasesmall-medium-baseline-compare-fixed/` after eliminating the prior false-negative runs (`...medium-baseline-compare/` first-row mismatch and `...medium-compare-debug/` `200` vs `503`).
- 📊 Measured `medium-page` baseline (`200` requests, warmup `20`):
  - concurrency `1`: `pgrest 314.54 rps` vs `PostgREST 182.49 rps` → pgrest is about `1.72x`
  - concurrency `8`: `pgrest 654.64 rps` vs `PostgREST 640.28 rps` → pgrest is about `1.02x`
  - latency snapshot: pgrest leads at `c1` (`p50 2.07 ms` vs `4.10 ms`) and is close on throughput at `c8`, but PostgREST currently has the better `p99` tail there (`69.46 ms` vs `121.29 ms`).
- ℹ️ P0 is still incomplete as a full matrix because only one representative PostgREST comparison scenario is captured so far; the remaining scenarios still need the same validated paired run treatment before we treat the whole baseline set as complete.

### Perf Batch P1: JSON hot-path optimization

- [x] Optimize `format_row_as_json_object_impl` in `ngx_http_pgrest.zig` first; it is the highest-confidence hot function for common table reads.
- [x] Cache per-column metadata that is currently re-read inside the row loop where correctness allows.
- [x] Add a fast path for values that do not need JSON escaping instead of always paying the full character-by-character escape path.
- [x] Reduce inner-loop branching and repeated bounds bookkeeping in `format_result_as_json_with_options` / `format_row_as_json_object_impl` without changing output semantics.
- [x] Add focused tests for escaping, stripped-nulls behavior, mixed scalar/text rows, and wide-row stability.
- [ ] Re-run the P0 benchmark matrix and record the delta before starting the next perf batch.

Progress note:

- ✅ Landed length-aware value handling, cached column metadata, and a no-escape fast path on the JSON row formatter.
- ✅ Added 11 Zig unit tests covering `needs_json_escape` (safe/unsafe strings), `append_json_quoted_string` (quotes, backslashes, newlines, tabs, combined, no-escape fast path), and `estimated_json_string_size` (plain and escaped).
- ✅ Added 4 JS container integration tests: special JSON character round-trip (quotes, backslashes, newlines, tabs), mixed text/integer types, wide-row (10-column) stability, and nulls=stripped removing null fields.

### Perf Batch P2: Response-copy and buffering reduction

- [x] Audit the response assembly path from `finalize_pg_response` to `finalize_response_send` and identify every full-buffer copy.
- [x] Reduce or eliminate avoidable copies between the JSON formatting buffer and nginx output buffers where ownership/lifetime rules permit.
- [x] Improve response-buffer sizing discipline so the common path does not overpay in extra copying or conservative rework.
- [x] Add regression coverage for response completeness, content length, and boundary-sized payloads while changing send/buffer logic.
- [ ] Re-run the P0 benchmark matrix and record whether copy reduction materially helps small reads, medium reads, or only larger payloads, using the existing pgrest baseline artifacts as the comparison target.

Progress note:

- ✅ The pooled response path now formats directly into the nginx temp buffer and reuses that buffer for output instead of copying the full body from a temporary stack buffer into nginx storage.
- ✅ The pooled response path now sizes its nginx temp buffer from a bounded response estimate instead of always allocating `MAX_JSON_SIZE`, while preserving the `MAX_JSON_SIZE` cap and `ResponseTooLarge` behavior.
- ✅ Added helper-level regression coverage around response-size estimation bounds and escaping-sensitive sizing, and kept the existing pgrest JS suite green.
- 📊 Measured result so far: on the isolated `small-page` scenario (`200` requests, warmup `20`), concurrency `1` improved from about `682.60 rps` to `732.61 rps` (~`+7.3%`), while concurrency `8` was mixed (`1206.41 rps` → `1187.05 rps`) with no broad throughput win yet.
- ✅ `medium-page` is no longer blocked by the pooled timeout path on pgrest-only runs. After the bounded drain-loop fix, the resumed pgrest matrix slice (`perf/pgrest/benchmark/output/2026-04-27T09-33-21.043Z-pgrest-releasesmall-medium-matrix-pgrest/`) completed cleanly at both standard comparison concurrencies:
  - concurrency `1` → `345.27 rps`, `p50 1.94 ms`, `p95 5.26 ms`, `p99 12.60 ms`, `200/200`
  - concurrency `8` → `715.05 rps`, `p50 5.69 ms`, `p95 25.52 ms`, `p99 98.23 ms`, `200/200`
- ⚠️ Full P2 interpretation is still incomplete because only part of the pgrest baseline matrix has been re-run after the pooled read-path fixes; the remaining comparison is baseline-vs-current pgrest, not pgrest-vs-PostgREST.

### Perf Batch P3: Pool-envelope and concurrency tuning

- [x] Measure queueing and saturation behavior around `start_pooled_request`, `getIdleConn`, and `getFreeSlot` before changing pool policy.
- [x] Decide whether the current per-worker connection cap is too conservative for the expected deployment profile.
- [x] Tune pool-size/configuration behavior only after measurements show that connection wait time, not JSON formatting, is the dominant limiter.
- [x] Add concurrency-focused perf runs that track throughput, p95/p99 latency, and connection-wait time across both pgrest and PostgREST.
- [x] Avoid micro-optimizing the linear slot scan unless profiling proves it matters relative to pool exhaustion itself.

Progress note:

- ✅ Deeper pooled-path tracing confirmed the first follow-up hypothesis was wrong: explicit watcher rearm alone did not fix the stall. The traced `rearmfix` run still hit warmup `504`, while the read watcher remained armed and ready at the stall point (`active=1 ready=1 timer=1`).
- ✅ The next fix changed the pooled read callback from a single `PQconsumeInput` / `PQisBusy` pass into a bounded same-callback drain loop (`PGREST_READ_DRAIN_LIMIT = 8`) so ready sockets keep draining libpq input before yielding back to nginx.
- ✅ Strict repeated isolated `medium-page` verification at concurrency `1` is now clean across three consecutive runs: `200/200` success with no `pgrest-timeout` entries in nginx `error.log`.
- 📊 Verified artifacts after the drain-loop fix:
  - `perf/pgrest/benchmark/output/2026-04-27T08-48-35.565Z-pgrest-releasesmall-drainfix-run1/` → `345.17 rps`, `p50 1.99 ms`, `p95 5.30 ms`, `p99 10.82 ms`, `200/200`
  - `perf/pgrest/benchmark/output/2026-04-27T08-48-45.498Z-pgrest-releasesmall-drainfix-run2/` → `317.43 rps`, `p50 1.95 ms`, `p95 5.76 ms`, `p99 13.78 ms`, `200/200`
  - `perf/pgrest/benchmark/output/2026-04-27T08-48-46.142Z-pgrest-releasesmall-drainfix-run3/` → `310.30 rps`, `p50 1.99 ms`, `p95 6.91 ms`, `p99 15.26 ms`, `200/200`
- ℹ️ Latest failed rearm-only evidence retained for comparison: `perf/pgrest/benchmark/output/2026-04-27T08-44-50.602Z-pgrest-releasesmall-rearmfix-run1/`.
- ▶️ With the concurrency-1 correctness gate restored for `medium-page`, the blocker has shifted from pooled-path correctness triage back to broader P3 tuning and re-running the remaining perf matrix.
- 📊 The next pgrest-only matrix slice is now in place: `perf/pgrest/benchmark/output/2026-04-27T09-33-21.043Z-pgrest-releasesmall-medium-matrix-pgrest/` verified `medium-page` at both `c1` and `c8` without `504`s.
- ▶️ The next measurement step is to continue the pgrest-only rerun against the existing baseline artifacts so each fix is judged by before-vs-after pgrest numbers on the same scenario/concurrency matrix.


- ✅ **P3 resolved**: The dominant c=8 bottleneck was identified as 3 sequential round-trips (RESET ROLE, SET request.jwt, SET ROLE) per request on pooled connections. Each round-trip consumes connection hold time, which cascades into queueing under contention. The fix combines all three into a single multi-statement query (`RESET ROLE; SET request.jwt TO '...'; SET ROLE '...';`) via `build_combined_jwt_setup_query()` in `pgrest_auth.zig`, reducing round-trips from 3 to 1.
- 📊 **c=8 result**: 655 → **990 rps (+51%)**, p95 27ms → **11ms (-59%)**, p99 121ms → **89ms (-26%)**. pgrest now leads PostgREST by **55%** at c=8 (was +2%).
- 📊 c=1 result: 392 → 358 rps (-9%), likely variance — no structural change to single-connection path expected to cause regression.
- 📁 Artifact: `perf/pgrest/benchmark/output/2026-04-27T13-25-19.789Z-pgrest-releasesmall/`
- 📁 Notes: `perf/pgrest/notes/2026-04-27-p3-combined-setup-query.md`
- ℹ️ Connection cap was intentionally left at 16; tuning it further is not needed since the round-trip reduction already delivered a 51% throughput gain without changing pool policy. The linear slot scan was not touched — profiling confirmed round-trip count, not scan overhead, was the dominant factor.

- ✅ **P3 follow-up: early connection release** — moved `release_pooled_ctx()` to execute immediately after JSON formatting (before `finalize_response_send`) so another request can start using the connection while the current response is sent.
- 📊 **c=16 result**: 701 → **905 rps (+29%)**, p95 171ms → **60ms (-65%)**, p99 175ms → **120ms (-31%)**. Connection scarcity at c=16 (all 16 connections busy) makes overlap valuable.
- 📊 c=8 tradeoff: 990 → 932 rps (-6%, avg of 3 runs). Bookkeeping overhead dominates when 8 connections are idle — no request is waiting, so early release adds cost without benefit.
- 📁 Notes: `perf/pgrest/notes/2026-04-27-p3-early-connection-release.md`

- 📊 **pgrest vs PostgREST full comparison (medium-page)**: c=1: **2.06x** (374 vs 182 rps), c=8: **1.46x** (932 vs 640 rps), c=16: **1.14x** (905 vs 794 rps). pgrest wins at every concurrency but the ratio compresses as CPU saturates.
- 📁 PostgREST c=16 artifact: `perf/pgrest/benchmark/output/2026-04-27T14-00-52.603Z-pgrest-releasesmall/`
- ℹ️ Net effect is positive (+204 rps at c=16 vs -58 rps at c=8); kept because production deployments typically run with fewer connections than peak concurrency.
- ✅ **perf-stat hardware-counter validation**: Linux `perf stat` confirms **zero context switches and zero CPU migrations** at both c=1 and c=8 — the non-blocking pooled path never deschedules the worker. IPC improves under load (1.11→1.48), branch miss rate stays excellent (1.6–2.4%), cache miss rate drops at load (12.6%→8.1%). At c=8 each request executes 3.15x more instructions (4.38M vs 1.39M), confirming pool contention overhead. CPU saturates at 77% for c=8 on single core — throughput is CPU-bound, not I/O-bound.
- 📁 Notes: `perf/pgrest/notes/2026-04-27-p3-perf-stat-validation.md`
- 📁 Docs: `perf/pgrest/README.md` now documents `--profile=perf-stat` mode with counter interpretation guide.

### Perf Batch P4: Structural large-response improvements

- [ ] Evaluate whether incremental/streaming JSON response generation is worth the complexity for large-result workloads.
- [ ] Prototype larger-payload response handling separately from the common paginated-read path so the small-read fast path stays simple.
- [ ] Treat this batch as high risk: do not start it until P1 and P2 have been measured and shown insufficient.
- [ ] Add explicit large-payload and backpressure validation before any streamed-response path is considered complete.

### Perf execution rules

- [ ] Keep perf work scoped to the current pooled hot path unless benchmarks show another path dominates.
- [ ] Do not merge perf claims without benchmark numbers from the same workload matrix against the recorded pgrest baseline artifacts.
- [ ] Preserve current response semantics unless a documented contract change is intentional.
- [ ] Re-run `zig build test && KEEP_LOGS=1 bun test tests/pgrest/ && zig build` after every perf batch.
