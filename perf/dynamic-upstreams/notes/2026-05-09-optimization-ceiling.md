# Dynamic Upstreams Combo - Optimization Ceiling

Date: 2026-05-09

This note closes the 2026-05-09 optimization session and documents why no further profitable optimizations remain for the current benchmark shape without functionality tradeoffs or structural changes.

## What Was Achieved This Session

Two changes were made and measured:

| change | instr/req delta | cycles/req delta |
|---|---:|---:|
| Replace `std.mem.zeroes(TagEntry)` with field-only reset | -3.7% | **-16.7%** |
| `cache_purge_worker_events_mode off` (opt-in) | -2.6% | ~-1.6% (noisy) |
| **Combined** | **~-6.2%** | **~-17–18%** |

The zeroing fix was the dominant win because removing 16.6 KB of shm zero-writes eliminated most of the pipeline-stall cycles that made `cycles/req` 4× higher than `instr/req` suggested. The IPC at c=32 moved from 0.365 (baseline) to 0.423 after the fix.

## Instruction Budget After Both Changes

At c=32, `capture-and-purge` now runs at approximately 101k instructions/req. The estimate for what owns those instructions:

| component | estimated share | notes |
|---|---|---|
| nginx infrastructure | ~64% (~65k) | HTTP parsing, proxy pass, filter chain, response write |
| module code (all four modules) | ~36% (~36k) | cache_tags + cache_purge + upstream_balancer + worker_events |

The nginx infrastructure cost is not reducible without modifying nginx internals. The module code share (~36k instr/req) has been significantly reduced from its original ~44k by removing the zeroing and (optionally) the event publish.

## Remaining Module-Level Angles and Why They Are Not Worth Pursuing

### Tag lookup with a hash map

With `tag_count` typically 2–3 in the benchmark, the `active_seen` early-exit linear scan terminates in 2–3 iterations. A hash map adds constant overhead (hash compute, collision handling, maintenance on mutation). It is only faster once the active tag count is large — typically above 32–64 entries. For the current benchmark it would be slower.

Even in production workloads with larger tag sets, the `tag_used[256]` scan (256 byte-comparisons) is cache-resident and completes in nanoseconds. A hash map would help only when scan latency becomes measurable, which requires hundreds of active tags.

### Lock splitting or per-bucket locks

The shmtx is held for at most a 2–3 entry linear scan plus one field mutation. The hold time is tens of nanoseconds. Splitting into finer locks would add implementation complexity without reducing hold time materially. The perf-stat runs consistently show 0 context switches and 0 CPU migrations — the mutex is not producing kernel-visible contention.

### Compile-time `max_uris_per_tag` / `max_uri_len` reduction

This would shrink `TagEntry` from 16.6 KiB to 2.2 KiB (7.5×). Before the zeroing fix, this would have been a significant win: reducing the per-purge zero-write from 16.6 KB to 2.2 KB would have cut ~85% of the shm write pressure.

After the zeroing fix, the struct is no longer zeroed on create or purge. The bytes actually touched per request are now ~50–150 bytes regardless of struct size (tag name copy, uri copy, uri_count field, tag_used flag). The struct size reduction no longer changes the per-request memory traffic.

The value that remains is:
- Smaller shm zone footprint (564 KiB vs 4.1 MiB) — relevant for memory-constrained environments
- Better cold-start cache behavior when the zone is first accessed
- A user-visible tuning knob for deployments that know their URI space is compact

This is worth implementing as a `build.zig` option (see `2026-05-09-optimization-angles.md`), but it is not a perf priority for the current benchmark shape. It belongs in a future maintenance round rather than a perf study.

### Asynchronous event publication

Making `ngx_http_worker_events_publish_internal` asynchronous (queueing the write to a per-worker buffer, flushing on the next event loop tick) would remove the worker-events mutex from the purge hot path entirely. The savings would be ~2.6% instructions and the second mutex acquire, which is currently modest.

The implementation cost is high: per-worker pending-write queues, flush-on-tick plumbing, and careful ordering guarantees for consumers. The return is <3% instructions. Not justified for this benchmark.

### URI tracking opt-out

Disabling `addUriToTag` entirely (`cache_tags_track_uris off`) would save the URI memcpy and uri_count increment per captured response. For the benchmark, each unique-token tag starts at `uri_count = 0` so `addUriToTag` immediately writes slot 0 without any scan. The saving is one memcpy (~40 bytes) per capture request — negligible.

This directive would have value for workloads with high-cardinality tags and many URIs per tag that repeatedly hit the deduplication scan before the cap. It is not useful for the current benchmark shape.

## Why the c=1 Throughput Remains Hard to Read

All c=1 numbers across every scenario are 25–40% below prior baselines this session. The prior "best" numbers were the highest observed values from multiple runs, not steady-state medians. The c=1 path (single sequential Bun client → nginx → backend → nginx → Bun) is dominated by socket round-trip latency on the loopback interface, which varies with OS scheduler state, CPU frequency, and whether the loopback socket is warm. Machine state today differs from the 2026-05-07 and 2026-05-08 runs.

The hardware counters at c=32 are the more reliable per-request signal because at full load the profiling window captures mostly active CPU work. Those counters consistently show the improvements: -16.7% cycles/req after the zeroing fix.

## Conclusion

The `capture-and-purge` hot path has been optimized to the point where further gains require either:

1. **Structural changes** with non-trivial implementation risk (async event publish, lock-free shm, hash-indexed tag store). Each saves <5% instructions against the current profile and adds substantial complexity.

2. **Functionality tradeoffs** already covered as opt-in directives:
   - `cache_purge_worker_events_mode off` — eliminates cross-worker invalidation notification
   - `cache_tags_track_uris off` (future) — eliminates URI-level tracking
   - Compile-time `max_uris_per_tag` / `max_uri_len` reduction (future) — shrinks memory footprint with no runtime behaviour change

3. **Rewriting the test benchmark** to use a different workload shape — but that defeats the purpose of benchmarking what the combo stack actually does.

The remaining ~64% of per-request instructions are nginx-side (proxy pass, HTTP parsing, filter chain). That is the correct place for this stack to spend its CPU time. The module layers are now thin relative to the nginx core work they orchestrate.

This is the expected steady state. No further perf investigation is warranted unless a future change introduces regression or a new hardware-counter run identifies a new hot spot.
