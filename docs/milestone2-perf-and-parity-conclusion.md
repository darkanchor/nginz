# Milestone 2 Conclusive Tech Note: Performance and Commercial Parity

Date: 2026-05-09

This note closes the milestone-2 performance study and assesses where the dynamic-upstreams stack stands relative to nginx Plus commercial features. It covers the full arc: what was optimized, the ceiling we hit, what makes this implementation solid, and where genuine gaps remain.

---

## Part 1: Performance Study Conclusions

### What Was Measured

The benchmark is a `capture-and-purge` loop: each iteration proxies a request through the full combo stack (nginx → upstream-balancer → dynamic-upstreams → cache-tags → cache-purge → worker-events), captures a `Cache-Tag` header, and immediately purges that tag. This exercises every hot path in the stack simultaneously.

Measurement methodology:

- **c=32 hardware counters** (perf-stat) are the reliable per-request signal. At full concurrency, the profiling window captures mostly active CPU work.
- **c=1 throughput** is dominated by loopback socket round-trip latency and varies significantly with OS scheduler state and CPU frequency. It is not a reliable steady-state signal across sessions or machines.
- **Parallel perf-stat runs** (two nginx instances competing) invalidate throughput numbers but preserve instruction counts — used only for counter comparison.

All conclusions in this section are based on c=32 instruction/cycle/cache-miss counts from the benchmark artifacts in `perf/dynamic-upstreams/benchmark/output/`.

### Round 1: Zeroing Fix (−3.7% instr, −16.7% cycles)

**Root cause**: `std.mem.zeroes(TagEntry)` was called at two points on every capture-and-purge iteration — once when a new tag slot was created in `findOrCreateTag`, and once when the slot was freed in `purgeByTag`. Each `TagEntry` is 16,976 bytes (16.6 KiB): `tag[64]` + `tag_len(8)` + `uris[64][256]` + `uri_lens[64×8]` + `uri_count(8)`. Two zero-writes per iteration = ~33 KB of shm writes per request = roughly 49 MB/s at 1525 RPS. This is pipeline-stall-heavy memory traffic, not just instruction count.

**Safety invariant**: `tag_used[i] = 0` gates all reads from any slot. A slot whose `tag_used` flag is 0 is invisible to every scanner in the store. The only field that must be initialized on slot creation is `uri_count = 0`, because `addUriToTag` uses it as the write cursor and would otherwise write past a stale capacity.

**Fix**:
- On slot creation: replace `entry.* = std.mem.zeroes(TagEntry)` with `entry.uri_count = 0` (plus the tag name copy already present).
- On slot purge: remove the `std.mem.zeroes` entirely. Setting `tag_used[i] = 0` is sufficient.

**Measured result at c=32**:

| metric | baseline (round3) | after fix | delta |
|---|---:|---:|---:|
| instructions/req | 106,879 | 102,879 | **−3.7%** |
| cycles/req | 281,566 | 234,659 | **−16.7%** |
| IPC | 0.365 | 0.423 | **+15.9%** |
| cache misses/req | 214.3 | 209.8 | **−2.1%** |

The cycles/req improvement (−16.7%) is 4.5× larger than the instruction/req improvement (−3.7%) because zero-writes into the slab are pipeline-stall-heavy: they write to shared memory addresses that are cache-cold on purge, forcing the CPU to stall on write-combine flushes. Removing them improves IPC from 0.365 to 0.423, confirming the bottleneck was stall-bound, not instruction-bound.

### Round 2: Worker-Events Mode Opt-In (−2.6% instr, −5.7% cache misses)

**What was measured**: `cache_purge_worker_events_mode per_target` vs `off`. The `per_target` default acquires the worker-events shmtx, writes ~640 bytes into a ring slot, and releases the mutex on every successful purge. This is a second `ngx_shmtx_lock` per purge iteration, separate from the cache-tags mutex.

**Measured result (hardware counters, parallel run — counters only)**:

| metric | per_target | off | delta |
|---|---:|---:|---:|
| instructions/req | 103,161 | 100,528 | **−2.6%** |
| cache misses/req | 211.1 | 199.0 | **−5.7%** |
| branch miss rate | 5.95% | 5.96% | flat |

**Recommendation**: `off` is documented in `cache-purge` README as appropriate for single-worker deployments or benchmarks where cross-worker notification is not needed. `per_target` remains the default for multi-worker. The cost is real but modest relative to the proxy + cache-tags work on the same path.

### Instruction Budget After Both Changes

At c=32, `capture-and-purge` runs at approximately 101k instructions/req:

| component | estimated share | notes |
|---|---|---|
| nginx infrastructure | ~64% (~65k) | HTTP parsing, proxy pass, filter chain, response write |
| module code (all four modules) | ~36% (~36k) | cache_tags + cache_purge + upstream_balancer + worker_events |

The nginx infrastructure cost is not reducible without modifying nginx internals. The module share (~36k instr/req) is now lean relative to the framework it orchestrates.

### Optimization Ceiling

All remaining module-level angles were evaluated:

**Tag lookup with a hash map**: with `tag_count` typically 2–3 in the benchmark, the `active_seen` linear scan terminates in 2–3 iterations. A hash map adds constant overhead (hash compute, collision handling, maintenance) and is only faster above ~32–64 entries. Not profitable.

**Lock splitting or per-bucket locks**: the shmtx hold time is tens of nanoseconds (2–3 entry scan plus one field mutation). Hardware counters show 0 context switches and 0 CPU migrations across all runs — the mutex is not producing kernel-visible contention. Splitting would add complexity with no measurable benefit.

**Compile-time `TagEntry` size reduction**: before the zeroing fix, shrinking `TagEntry` from 16.6 KiB to 2.2 KiB would have cut ~85% of per-purge shm write pressure. After the fix, the struct is no longer zeroed on create or purge. Bytes actually touched per request are ~50–150 regardless of struct size (tag name copy, uri copy, uri_count field, tag_used flag). The size reduction no longer changes per-request memory traffic. It retains value as a shm footprint reduction (564 KiB vs 4.1 MiB) — a `build.zig` option worth adding in a maintenance round, not a perf priority.

**Asynchronous event publication**: removing `ngx_http_worker_events_publish_internal` from the purge hot path entirely would save ~2.6% instructions. The implementation cost is high (per-worker pending-write queues, flush-on-tick plumbing, ordering guarantees). Return is <3% instructions. Not justified.

**URI tracking opt-out** (`cache_tags_track_uris off`): for the benchmark, each unique-token tag starts at `uri_count = 0`, so `addUriToTag` immediately writes slot 0 without any deduplication scan. The saving is one memcpy (~40 bytes) per capture — negligible. Useful for high-cardinality/high-URI-count production workloads, worth adding as a future directive, not a perf priority today.

**Conclusion**: no further profitable optimizations remain for the current benchmark shape without structural changes or functionality tradeoffs. The expected steady state has been reached.

---

## Part 2: Solidity Assessment

The hardware counters and throughput numbers tell a consistent story across all scenarios:

- **0 context switches, 0 CPU migrations** across every perf-stat run. The shmtx paths are not producing kernel-visible contention at the tested concurrency levels.
- **IPC 0.423 at c=32** after the zeroing fix, up from 0.365. The module code is no longer stall-dominated.
- **Churn path is negligible on steady read**. `sticky-read` (no purge, no zeroing) shows this cleanly: the balancer and snapshot overhead vanishes into noise against the proxy pass baseline.
- **Generation pinning model is correct**. `du_get_active_peers` increments refcount under slab mutex on every proxied request, ensuring no snapshot is freed while a request holds a reference. This is the right correctness model, though it is a documented technical debt item for high-concurrency workloads (see gaps section).
- **Last-good preservation works across worker restart**. The atomic full-replacement with last-good fallback was validated in integration tests across multiple worker configurations.
- **Cross-worker cache invalidation is proven**. `worker_processes 2` integration tests verify that a capture on worker-A is visible to a purge on worker-B through the shared slab.

---

## Part 3: Commercial Parity — Edges

These are capabilities this stack has that nginx Plus does not expose as a clean self-contained primitive.

### Tag-Based Cache Invalidation

nginx Plus has proxy cache and purge via ngx_cache_purge, but it does not have a built-in tag/surrogate-key model. `cache-tags` + `cache-purge` together implement a Fastly Surrogate Keys-style workflow: upstream responses carry `Cache-Tag` headers, the module stores tag→URI mappings in shared memory, and the purge API invalidates by tag in one operation across all workers. nginx Plus requires external tooling (custom scripts, a CDN layer, or a commercial add-on) to achieve this.

### General Worker-Events Bus

nginx Plus cross-worker coordination is not exposed as a programmable primitive to user-level modules. `worker-events` provides a publish/subscribe ring that any module in this stack can use: `healthcheck` publishes health transitions, `cache-purge` publishes successful invalidations, and `dynamic-upstreams` can publish generation activations. This is a reusable coordination layer, not glue code.

### Explicit Generation Model with Audit Trail

The dynamic-upstreams snapshot model uses explicit generation numbers and last-good preservation. Every activation has a traceable generation, and the previous snapshot is retained until all in-flight requests that hold its refcount release it. nginx Plus dynamic reconfiguration (via the upstream API) mutates in-place with no generation tracking and no last-good fallback.

### Consul Native Integration

The consul source for dynamic-upstreams polls the Consul catalog directly from the worker event loop, parsing the JSON response and activating a new snapshot when membership changes. This is native integration with no sidecar dependency (no nginx-sync or consul-template). nginx Plus requires consul-template or a sidecar agent to translate Consul state into nginx Plus upstream API calls.

### Module-Owned Purge Contract

`cache-purge` operates against a shared metadata store that is owned and maintained by `cache-tags` and accessed by the purge module through a well-defined struct boundary. The purge API reports exact counts (URIs invalidated per tag, tags processed per batch), supports per-target worker-events fanout, and exposes nginx variables (`$cache_tags_last_purged`, `$cache_tags_last_tag`, `$cache_tags_last_error`) for scripting and logging. This is not available in stock nginx or vanilla nginx Plus.

---

## Part 4: Commercial Parity — Gaps

These are capabilities nginx Plus provides that this stack does not yet match.

### Partial Server Mutation (PATCH semantics)

nginx Plus allows adding or removing individual servers from an upstream group via the upstream API without replacing the entire peer set. The current `dynamic-upstreams` model is always a full snapshot replacement: PUT or Consul-sourced activation always replaces all peers atomically. Partial mutations require iteration-aware in-place updates, which conflict with the snapshot immutability model. Addressable by introducing a diff+merge phase before snapshot activation, but not trivial.

### State Persistence Across Restart

nginx Plus upstream zone state persists across graceful reloads because the shared memory zone is inherited by the new worker generation. The current `dynamic-upstreams` implementation loses snapshot state on nginx restart/reload — the worker-0 timer re-polls Consul or waits for the next PUT, meaning there is a window where the upstream is serving only the static config peers. Addressable with a disk-based snapshot journal or shared memory persistence across reload.

### Graceful Drain

nginx Plus supports marking a server as `draining` — it receives no new requests but finishes in-flight requests before being removed. The current snapshot model has no drain state. A `draining` peer would need generation-aware routing exclusion (skip for new connections) while allowing the refcount on the old generation to reach zero naturally. The generation + refcount model is the right foundation for this, but the balancer `get` callback does not currently consult drain state.

### DNS-Based Upstream Resolution

nginx Plus can resolve upstream hostnames at runtime using system DNS, re-querying at the TTL. Stock nginx resolves upstream addresses at config load only. `dynamic-upstreams` currently requires explicit peer addresses in PUT requests or Consul-provided IPs. DNS-aware resolution is useful for Kubernetes environments where pod IPs change frequently. Addressable but not currently planned.

### Blocking Consul HTTP/1.0 on Worker-0 Event Loop

The Consul source uses a simple HTTP/1.0 blocking socket on the worker-0 event loop with a 5-second timeout. This is correct for the current load but is a single-worker blocking operation — a slow Consul response can stall worker-0's event processing for the timeout duration. nginx Plus equivalent polling uses non-blocking async DNS + upstream connections. Addressable by moving to nginx's non-blocking upstream connection machinery, which is substantial but the right long-term fix.

### Per-Request Slab Mutex in `du_get_active_peers`

`du_get_active_peers` acquires the slab mutex on every proxied request to increment the generation refcount. At c=32 this produces no kernel-visible contention (0 migrations, 0 context switches), but under sustained high concurrency this is a single serialization point that will eventually become a bottleneck. nginx Plus manages peer set access through atomic operations and per-upstream zone locking, not a global slab mutex. Addressable by replacing the slab mutex with a CAS-based refcount (Zig's `@atomicRmw` on an atomic counter embedded in the snapshot header).

### Sticky Learn

nginx Plus has `sticky learn` — the upstream remembers which backend a client was last routed to, using a response cookie as the key, without requiring the client to resend the cookie. `upstream-balancer` currently requires the sticky identity to arrive in the request (cookie or header). A sticky-learn model requires a shared state table updated on response (in the header filter or `peer.free` callback). Not currently implemented.

---

## Part 5: Priority Order for Future Improvements

The gaps above are ranked by impact on production correctness and operational safety:

1. **State persistence across restart** — a production deployment that loses its upstream peer set on reload is operationally unreliable. This is the most important gap for production readiness.

2. **Async Consul polling** — the blocking event-loop issue is a correctness risk under slow Consul responses, not just a performance issue. Moving to non-blocking upstream connections on the worker event loop removes a potential multi-second stall from worker-0.

3. **Per-request slab mutex → CAS refcount** — this is benign today but becomes a scalability ceiling. An `@atomicRmw` refcount on the snapshot header replaces the slab mutex for the common read path. The slab mutex is still needed for snapshot activation (write path), which is rare.

4. **Partial server mutation (PATCH)** — relevant for deployments that perform incremental backend fleet changes rather than full replacements. Lower urgency than the three items above, but important for operational flexibility.

5. **Graceful drain** — the generation + refcount model is already the right foundation. The work is adding drain state to peer structs and consulting it in the balancer `get` callback. Useful for zero-downtime backend rotation.

6. **DNS-based resolution** and **sticky learn** are lower priority and have external workarounds (explicit IP registration via PUT, client-side sticky cookies).

---

## Summary

The dynamic-upstreams stack is performance-optimized to the point where the module layers (~36% of per-request instructions) are thin relative to the nginx infrastructure they orchestrate (~64%). The dominant optimization was removing unnecessary shm zero-writes from the hot path, yielding −16.7% cycles/req. No further gains are available without structural changes disproportionate to the savings.

The implementation is solid: generation tracking, last-good preservation, cross-worker cache invalidation, tag-based purge, and a general worker-events bus are all working and integration-tested. These are capabilities with no direct equivalent in stock nginx or clean primitives in nginx Plus.

The honest gaps are operational rather than architectural: state persistence, async source polling, per-request slab mutex contention, and drain semantics. All are addressable within the current model — none require redesigning the generation or snapshot machinery. The foundation is the right one.
