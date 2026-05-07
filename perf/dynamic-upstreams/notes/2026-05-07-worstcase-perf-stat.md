# Dynamic Upstreams Combo Worst-Case - Perf Stat

Date: 2026-05-07

Scenario:

- `capture-purge-with-churn`

Artifact:

- `perf/dynamic-upstreams/benchmark/output/2026-05-07T08-44-49.527Z-dynamic-upstreams-releasesmall-worstcase-perf-stat`

Command:

```bash
bun perf/dynamic-upstreams/benchmark/run.js --scenario=capture-purge-with-churn --requests=500 --warmup=50 --profile=perf-stat --artifact-tag=worstcase-perf-stat
```

Build / profile mode:

- `ZIG_OPTIMIZE=ReleaseSmall`
- `--profile=perf-stat`

Headline results:

| concurrency | rps | p50 | p95 | p99 |
|---|---:|---:|---:|---:|
| `1` | 1351.52 | 0.60 ms | 1.34 ms | 4.22 ms |
| `8` | 4251.64 | 1.42 ms | 3.64 ms | 9.09 ms |
| `32` | 5188.41 | 4.83 ms | 11.70 ms | 13.50 ms |

Representative perf counters:

- `profiling/capture-purge-with-churn-c8/perf-stat.txt`
  - `task-clock`: `112.50 msec`
  - `cycles`: `155,937,326`
  - `instructions`: `53,963,227`
  - `cache-misses`: `55,105`
- `profiling/capture-purge-with-churn-c32/perf-stat.txt`
  - `task-clock`: `87.85 msec`
  - `cycles`: `131,030,553`
  - `instructions`: `50,727,264`
  - `cache-misses`: `114,555`

Counter-derived view:

| concurrency | instr/req | cycles/req | IPC | branch miss rate | cache miss rate | cache misses/req |
|---|---:|---:|---:|---:|---:|---:|
| `1` | 109.2k | 309.3k | 0.353 | 7.25% | 2.57% | 152.5 |
| `8` | 107.9k | 311.9k | 0.346 | 6.85% | 2.13% | 110.2 |
| `32` | 101.5k | 262.1k | 0.387 | 4.75% | 5.41% | 229.1 |

Analysis:

### 1. This is the real mutation-heavy combo hot path

Unlike the baseline note, there is no ambiguity about what dominates here. Every request executes:

- a proxied capture through the sticky upstream path
- `cache_tags` metadata capture
- an exact purge against the shared store
- concurrent `dynamic-upstreams` snapshot activation in the background

This is the closest thing in the current suite to a composite operator storm. The numbers confirm that it is much heavier than the read path, but they also sharpen *where* the cost lives.

### 2. Extra churn does not increase total instruction count much; it increases memory pressure

The most important comparison is not against `sticky-read`. It is against baseline `capture-and-purge c32` from the same day:

- `capture-and-purge c32`: `107.6k` instructions/req, `4.68%` cache miss rate
- `capture-purge-with-churn c32`: `101.5k` instructions/req, `5.41%` cache miss rate

So adding concurrent snapshot activation does **not** expand the control-flow footprint dramatically. In fact, this run executes 5.7% fewer instructions per request than baseline purge at `c=32`. What it does do is raise cache-miss rate by another 15.7%.

That strongly suggests the overlap penalty is about shared mutable state locality:

- snapshot generation activation and event publication touch a different working set
- exact purge still mutates the tag metadata store
- the two together produce more cache churn, even when total instruction count stays in the same band

### 3. The contention signature shows up in cache behavior at `c=32`

At `c=8`, cache miss rate is only `2.13%`. At `c=32`, it jumps to `5.41%`, while cache misses per request more than double (`110.2` -> `229.1`).

That is the cleanest microarchitectural signal in this note:

- low and medium concurrency keep the working set mostly resident
- high concurrency in the overlap path pushes enough shared metadata and peer-generation state through the machine to degrade locality substantially

Branch prediction does not tell the same story. Branch miss rate improves from `6.85%` at `c=8` to `4.75%` at `c=32`, so control flow predictability is not the limiting factor in the worst-case slice.

### 4. The path is still CPU-bound, not scheduler-bound

Like the baseline runs, every slice reports:

- `0` context switches
- `0` CPU migrations

So even the worst-case combo path is not spending time blocked in the kernel. The slowdown is from executing more on-CPU work against a less cache-friendly composite working set.

### 5. Why the snapshot and perf-stat headlines differ

The snapshot run for the same worst-case scenario reported a much worse `c=32` result (`4348.32` rps, `23.58 ms` p95) than this perf-stat run (`5188.41` rps, `11.70 ms` p95). That is not a contradiction; it means this path has visible run-to-run variance once contention gets high.

The right reading is:

- use the snapshot note to understand that the worst-case path can tail badly
- use this perf-stat note to understand that the underlying cost driver is cache locality under overlapping metadata mutation, not a huge explosion in branchy control flow

Optimization priorities implied by this run:

1. Reduce shared-store mutation footprint in `cache-purge` before touching the steady sticky path.
2. Minimize event/publication work performed synchronously on the overlap path.
3. Re-check the active-snapshot churn workload only after purge-path locality is improved; snapshot churn alone is not showing up as the primary CPU cost.

Notes:

- All slices completed `500/500`.
- This run is the counter-oriented version of the same worst-case benchmark and should be used for drill-down, not for headline throughput gating.
- The `c=32` slice shows higher cache-miss pressure than the `c=8` slice while staying within the same bounded scenario shape.
- Per-slice profiling files are under:
  - `profiling/capture-purge-with-churn-c1/`
  - `profiling/capture-purge-with-churn-c8/`
  - `profiling/capture-purge-with-churn-c32/`
