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

Notes:

- All slices completed `500/500`.
- This run is the counter-oriented version of the same worst-case benchmark and should be used for drill-down, not for headline throughput gating.
- The `c=32` slice shows higher cache-miss pressure than the `c=8` slice while staying within the same bounded scenario shape.
- Per-slice profiling files are under:
  - `profiling/capture-purge-with-churn-c1/`
  - `profiling/capture-purge-with-churn-c8/`
  - `profiling/capture-purge-with-churn-c32/`
