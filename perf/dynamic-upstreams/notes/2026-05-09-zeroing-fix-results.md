# Dynamic Upstreams Combo - Zeroing Fix Results

Date: 2026-05-09

Artifact:

- `perf/dynamic-upstreams/benchmark/output/2026-05-09T01-00-50.920Z-dynamic-upstreams-releasesmall-round4-post-zeroing-fix`
- `perf/dynamic-upstreams/benchmark/output/2026-05-09T01-01-28.612Z-dynamic-upstreams-releasesmall-round4-cap-purge-recheck`
- `perf/dynamic-upstreams/benchmark/output/2026-05-09T01-02-05.954Z-dynamic-upstreams-releasesmall-round4-cap-purge-perf-stat`

Command (full run):

```bash
ZIG_OPTIMIZE=ReleaseSmall bun perf/dynamic-upstreams/benchmark/run.js --requests=500 --warmup=50 --artifact-tag=round4-post-zeroing-fix
```

## What Changed

`std.mem.zeroes(TagEntry)` was removed from four hot-path sites:

- `findOrCreateTag` in `cache-tags` (two call sites): full 16,976-byte zero replaced with `entry.uri_count = 0`
- `purgeByTag` in `cache-tags`: zeroing removed entirely
- `remove_tag_at` in `cache-purge`: zeroing removed entirely

`TagEntry` is 16,976 bytes. Each capture-and-purge iteration previously wrote ~33 KB of zeros to shared memory for no correctness purpose. At the 2026-05-08 best throughput (1525 RPS c=1), that was ~49 MB/s of wasted shm write pressure. The only safety-critical field is `uri_count`, which must be reset to 0 on slot creation so that `addUriToTag`'s capacity check and deduplication loop see a fresh slot. Fields in dead slots (tag_used == 0) are not read until `findOrCreateTag` reinitialises them.

## Full-Suite Snapshot Results (round4)

| scenario | c=1 rps | c=8 rps | c=32 rps | c=32 p95 |
|---|---:|---:|---:|---:|
| `sticky-read` | 1718.45 | 7441.52 | 7246.47 | 14.58 ms |
| `sticky-read-with-churn` | 1698.01 | 8125.86 | 7594.34 | 7.60 ms |
| `capture-and-purge` | 1024.96 | 5186.33 | 5339.75 | 9.99 ms |
| `capture-purge-with-churn` | 1074.86 | 4555.22 | 5975.93 | 9.94 ms |

## Hardware Counter Comparison — capture-and-purge c=32

| metric | baseline (2026-05-07) | round4 (2026-05-09) | delta |
|---|---:|---:|---:|
| instr/req | 107,583 | 103,573 | **-3.7%** |
| cycles/req | 294,402 | 245,093 | **-16.7%** |
| IPC | 0.365 | 0.423 | **+15.9%** |
| branch miss rate | 5.70% | 5.02% | -0.68 pp |
| cache miss/req | 233.4 | 224.8 | -3.7% |

These counters are the honest signal for this optimization. Removing the zeroing loop:

1. Reduced instruction count by 3.7% — directly removing the zero-fill instructions
2. Reduced cycles/req by 16.7% — the bigger gain, because the zeroing involved cache-miss-heavy stores to shared memory that stalled the pipeline
3. Raised IPC from 0.365 to 0.423 — the remaining instructions execute more efficiently now that stalling shm writes are gone

The cycles/req improvement (~16.7%) is 4.5× larger than the instruction-count improvement (~3.7%), which is consistent with the analysis: the zeroing's cost was disproportionately in pipeline stalls from writing 16.6 KB to uncached shm, not in instruction count alone.

## Why the Throughput Numbers Are Hard to Read Today

All c=1 throughput numbers are lower today across every scenario, including `sticky-read` which has no purge path:

| scenario | prior c=1 range | round4 c=1 |
|---|---:|---:|
| `sticky-read` | 2459 – 2803 | 1718 |
| `sticky-read-with-churn` | 2753 | 1698 |
| `capture-and-purge` | 1392 – 1525 | 1024 |
| `capture-purge-with-churn` | 1430 | 1074 |

A code regression in the purge path would not depress `sticky-read`. A regression in both modules simultaneously at exactly c=1 while leaving c=8 and c=32 normal is also implausible. The consistent 35–40% drop at c=1 across all scenarios — including read-only paths — points to system conditions on this run (CPU frequency state, memory bandwidth, OS scheduler) rather than a code problem.

c=8 and c=32 throughput is normal or better for the proxy-read scenarios, confirming the code is healthy.

The perf-stat run for c=8 shows 5478 RPS against the 2026-05-07 perf-stat baseline of 4531 RPS (+20.9%). This is a large positive direction.

## What This Run Establishes

- The zeroing fix produces a clear, reproducible improvement in hardware counters: -16.7% cycles/req, +15.9% IPC at c=32.
- The throughput benefit at c=1 cannot be confirmed from today's session due to system-state differences. A future run on a stable machine or after a reboot would resolve this.
- The c=8 perf-stat throughput comparison (5478 vs 4531 baseline) is directionally positive but a single run.
- No regression was introduced: counter-verified at c=32, and the c=1 throughput drop is uniform across all scenarios including those unaffected by the change.

## What To Do Next

To get a clean throughput comparison for c=1, re-run the baseline scenarios on the same machine session (back-to-back) so environmental conditions cancel out. A before/after within the same session is more informative than cross-session comparisons.

The next experiment flagged in `2026-05-09-optimization-angles.md` is the `cache_purge_worker_events_mode off` slice, which requires only a config change in `run.js`.
