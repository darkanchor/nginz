# Dynamic Upstreams Combo Baseline - Perf Stat

Date: 2026-05-07

Artifact:

- `perf/dynamic-upstreams/benchmark/output/2026-05-07T08-26-31.340Z-dynamic-upstreams-releasesmall-baseline-perf-stat-final`

Command:

```bash
bun perf/dynamic-upstreams/benchmark/run.js --requests=500 --warmup=50 --profile=perf-stat --artifact-tag=baseline-perf-stat-final
```

Build / profile mode:

- `ZIG_OPTIMIZE=ReleaseSmall`
- `--profile=perf-stat`

Scenario set:

- `sticky-read`
- `sticky-read-with-churn`
- `capture-and-purge`

Headline results:

| scenario | c=1 rps | c=8 rps | c=32 rps | c=32 p95 |
|---|---:|---:|---:|---:|
| `sticky-read` | 2029.97 | 6494.02 | 7165.45 | 12.46 ms |
| `sticky-read-with-churn` | 2184.14 | 7845.89 | 8513.47 | 14.02 ms |
| `capture-and-purge` | 1455.23 | 4531.11 | 4847.38 | 12.01 ms |

Representative perf counters:

- `profiling/sticky-read-c32/perf-stat.txt`
  - `task-clock`: `59.42 msec`
  - `cycles`: `72,154,485`
  - `instructions`: `29,915,658`
  - `cache-misses`: `48,874`
- `profiling/capture-and-purge-c32/perf-stat.txt`
  - `task-clock`: `99.82 msec`
  - `cycles`: `147,201,197`
  - `instructions`: `53,791,615`
  - `cache-misses`: `116,716`

Notes:

- All slices completed `500/500`.
- The runner now writes one `perf-stat.txt` and one `summary.json` per scenario/concurrency slice under `profiling/`.
- The earlier `baseline-perf-stat` run from the same day is superseded; it predated the bounded FIFO teardown and per-slice profiling layout.
