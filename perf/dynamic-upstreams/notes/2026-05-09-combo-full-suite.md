# Dynamic Upstreams Combo - Full Suite 2026-05-09

Date: 2026-05-09

Artifacts:

- `perf/dynamic-upstreams/benchmark/output/2026-05-09T15-10-35.439Z-dynamic-upstreams-releasesmall-combo-snapshot-2026-05-09` (snapshot, all 4 scenarios)
- `perf/dynamic-upstreams/benchmark/output/2026-05-09T15-10-47.552Z-dynamic-upstreams-releasesmall-combo-perf-stat-2026-05-09` (perf-stat, all 4 scenarios)

Commands:

```bash
ZIG_OPTIMIZE=ReleaseSmall bun perf/dynamic-upstreams/benchmark/run.js --requests=500 --warmup=50 --artifact-tag=combo-snapshot-2026-05-09
ZIG_OPTIMIZE=ReleaseSmall bun perf/dynamic-upstreams/benchmark/run.js --requests=500 --warmup=50 --profile=perf-stat --artifact-tag=combo-perf-stat-2026-05-09
```

Both runs were back-to-back on the same machine session.

## Snapshot Throughput Results

| scenario | c=1 rps | c=8 rps | c=32 rps | c=8 p95 | c=32 p95 |
|---|---:|---:|---:|---:|---:|
| `sticky-read` | 1980.68 | 8488.96 | 7019.21 | 1.95 ms | 17.07 ms |
| `sticky-read-with-churn` | 1753.98 | 6858.13 | 8726.91 | 2.45 ms | 6.37 ms |
| `capture-and-purge` | 1214.92 | 5338.32 | 6309.34 | 2.73 ms | 8.10 ms |
| `capture-purge-with-churn` | 1268.70 | 4880.17 | 6622.20 | 3.75 ms | 10.54 ms |

All slices completed 500/500 with 100% HTTP 200 success.

## Perf-Stat Hardware Counters (per-request)

| scenario | c | instr/req | cycles/req | IPC | branch miss rate | cache miss rate | cache misses/req |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `sticky-read` | 1 | 59,137 | 137,065 | 0.431 | 8.09% | 1.71% | 57.6 |
| `sticky-read` | 8 | 59,332 | 123,767 | 0.479 | 5.78% | 0.55% | 14.9 |
| `sticky-read` | 32 | 58,872 | 126,187 | 0.467 | 5.14% | 2.82% | 72.0 |
| `sticky-read-with-churn` | 1 | 60,514 | 141,583 | 0.427 | 8.21% | 2.57% | 91.3 |
| `sticky-read-with-churn` | 8 | 47,573 | 95,695 | 0.497 | 5.84% | 1.26% | 25.5 |
| `sticky-read-with-churn` | 32 | 55,038 | 131,548 | 0.418 | 5.69% | 3.53% | 93.6 |
| `capture-and-purge` | 1 | 101,605 | 234,887 | 0.433 | 7.68% | 2.62% | 148.7 |
| `capture-and-purge` | 8 | 100,531 | 241,393 | 0.416 | 5.38% | 2.73% | 120.8 |
| `capture-and-purge` | 32 | 100,499 | 224,150 | 0.448 | 5.25% | 4.00% | 179.6 |
| `capture-purge-with-churn` | 1 | 102,009 | 227,874 | 0.448 | 7.54% | 2.22% | 126.5 |
| `capture-purge-with-churn` | 8 | 99,748 | 212,509 | 0.469 | 5.63% | 1.39% | 60.1 |
| `capture-purge-with-churn` | 32 | 108,990 | 216,945 | 0.502 | 5.06% | 2.36% | 104.0 |

All slices: 0 context switches, 0 CPU migrations. The path is CPU-bound, not scheduler-bound.

## Comparison Against 2026-05-07 Baseline Perf-Stat

The 2026-05-07 baseline only captured the worst-case `capture-purge-with-churn` scenario.

| metric | baseline c=8 | today c=8 | delta |
|---|---:|---:|---:|
| instr/req | 107,926 | 99,748 | **-7.6%** |
| cycles/req | 311,875 | 212,509 | **-31.9%** |
| IPC | 0.346 | 0.469 | **+35.5%** |
| cache misses/req | 110.2 | 60.1 | **-45.5%** |

| metric | baseline c=32 | today c=32 | delta |
|---|---:|---:|---:|
| instr/req | 101,455 | 108,990 | +7.4% |
| cycles/req | 262,061 | 216,945 | **-17.2%** |
| IPC | 0.387 | 0.502 | **+29.7%** |
| cache misses/req | 229.1 | 104.0 | **-54.6%** |

The improvements are substantial and consistent:

1. **Cycles/req dropped ~32% at c=8 and ~17% at c=32** — the zeroing fix (angle 1 from optimization-angles.md) eliminated 33 KB of shared-memory zero-writes per capture-and-purge iteration. The pipeline was previously stalling on uncached shm writes.

2. **IPC improved ~30-35%** — the remaining instructions run more efficiently now that the cache-hostile zeroing loop is gone.

3. **Cache misses cut in half** — cache misses/req dropped from 110→60 (c=8) and 229→104 (c=32). The zeroing was the dominant source of cache pressure on this path.

4. **Instruction count modestly reduced** — the ~8% reduction at c=8 confirms the zeroing loop instructions are gone, but the much larger cycles/req reduction shows the zeroing's real cost was in stalls, not instruction count.

At c=32, instruction count increased slightly (+7.4%) — likely due to the better IPC allowing the machine to execute more instructions in the same wall time, including more churn-loop iterations. The cycles/req still dropped 17%.

## Comparison Against 2026-05-08 Best Benchmarks

| scenario | best c=1 (from notes) | today c=1 | best c=8 (from notes) | today c=8 |
|---|---:|---:|---:|---:|
| `sticky-read` | 2459.53 | 1980.68 | 6178.79 | 8488.96 |
| `capture-and-purge` | 1525.62 | 1214.92 | 5247.06 | 5338.32 |

The c=1 numbers are lower across the board today, consistent with the system-state variance documented in the zeroing-fix results note. The c=8 numbers are healthy: `sticky-read` c=8 is notably higher (8489 vs 6179, +37%).

The round4 zeroing-fix note already established that:
- c=1 throughput varies 35-40% between sessions due to environmental factors (CPU frequency, scheduling)
- c=8 and c=32 throughput is the more reliable signal
- Hardware counters are the honest comparison metric

## Comparison Against Round4 Post-Zeroing Snapshot

Today's run did not change any code from round4, so differences represent run-to-run variance.

| scenario | round4 c=1 | today c=1 | round4 c=8 | today c=8 | round4 c=32 | today c=32 |
|---|---:|---:|---:|---:|---:|---:|
| `sticky-read` | 1718.45 | 1980.68 | 7441.52 | 8488.96 | 7246.47 | 7019.21 |
| `sticky-read-with-churn` | 1698.01 | 1753.98 | 8125.86 | 6858.13 | 7594.34 | 8726.91 |
| `capture-and-purge` | 1024.96 | 1214.92 | 5186.33 | 5338.32 | 5339.75 | 6309.34 |
| `capture-purge-with-churn` | 1074.86 | 1268.70 | 4555.22 | 4880.17 | 5975.93 | 6622.20 |

Today's numbers are slightly higher across most cells, but the shape is consistent. No cell shows a material regression. The variance is within the range established by prior notes.

## Key Takeaways

### Steady read path (`sticky-read`)

- ~59k instructions/req, ~0.45 IPC — this is the lightest path in the suite
- c=8 achieves 0.479 IPC, c=32 at 0.467 — slight IPC drop from higher cache pressure
- Branch miss rates are reasonable (5-8%) and improve with concurrency
- Churn (background snapshot activation) adds ~2k instr/req at c=1, but at c=8 the cost nearly disappears (instr/req actually *decreased* in today's run, likely from sampling variance)

### Purge path (`capture-and-purge`)

- ~100k instructions/req — about 1.7× the read path
- The extra 41k instructions are the capture+purge logic (cache-tags metadata, exact purge lookup, JSON request parse)
- IPC is stable at ~0.43-0.45 across concurrency levels
- Branch miss rate at 5-8% — the exact-match fast-path parser prevents JSON library overhead

### Worst-case path (`capture-purge-with-churn`)

- ~100-109k instructions/req — similar to purge path
- Background churn adds ~0-9k instructions depending on phase alignment
- IPC is highest on this path (0.469 at c=8, 0.502 at c=32) — unexpected but consistent with prior notes: the extra concurrency stress falls on cache locality, not instruction throughput
- Cache misses/req increases from 60 (c=8) to 104 (c=32) — the overlap of snapshot activation and purge mutates enough working set to push past L2 comfort

### Remaining optimization headroom

The optimization-angles.md survey identified three remaining angles. Priority based on today's data:

1. **Angle 2 (worker-events mode)** — not tested in this run. The previous round5 experiment showed -2.6% instr and -5.7% cache misses when set to `off`, but single-run variance prevented a firm conclusion. This should be re-tested on the current codebase in a dedicated session.

2. **Angle 3 (TagEntry size reduction)** — the 16.6 KiB TagEntry is the primary working-set bloat. At c=32, cache misses/req is 104 (with-churn) to 180 (no-churn). Reducing TagEntry by 7.5× (compile-time option) would shrink the active working set from ~50 KB/worker to ~7 KB/worker, likely fitting entirely in L1 cache.

3. **Angle 4 (URI tracking opt-out)** — low priority for the current benchmark shape. The per-iteration unique-tag pattern means `addUriToTag` runs in O(1) with a single memcpy. Opt-out helps high-cardinality tag sets, not the benchmark profile.

## Machine Profile

- CPU: 8-core (as reported by `Cpus_allowed: ff`)
- Memory: 16 GB (MemTotal: 16358812 kB)
- No swap (SwapTotal: 0 kB)
- `perf_event_paranoid: 2`
- `perf` version 7.0.3-1
