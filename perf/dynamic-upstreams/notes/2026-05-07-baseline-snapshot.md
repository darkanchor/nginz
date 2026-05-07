# Dynamic Upstreams Combo Baseline - Snapshot

Date: 2026-05-07

Artifact:

- `perf/dynamic-upstreams/benchmark/output/2026-05-07T08-26-18.625Z-dynamic-upstreams-releasesmall-baseline-snapshot-final`

Command:

```bash
bun perf/dynamic-upstreams/benchmark/run.js --requests=500 --warmup=50 --artifact-tag=baseline-snapshot-final
```

Build / profile mode:

- `ZIG_OPTIMIZE=ReleaseSmall`
- `--profile=snapshot` (default)

Scenario set:

- `sticky-read`
- `sticky-read-with-churn`
- `capture-and-purge`

Headline results:

| scenario | c=1 rps | c=8 rps | c=32 rps | c=32 p95 |
|---|---:|---:|---:|---:|
| `sticky-read` | 2803.98 | 6592.49 | 7082.93 | 15.74 ms |
| `sticky-read-with-churn` | 2753.59 | 7573.40 | 8010.56 | 8.60 ms |
| `capture-and-purge` | 1392.58 | 5563.54 | 6456.32 | 9.60 ms |

Notes:

- All slices completed `500/500`.
- Per-slice profiling summaries now live under:
  - `profiling/sticky-read-c1/summary.json`
  - `profiling/sticky-read-c8/summary.json`
  - `profiling/sticky-read-c32/summary.json`
  - `profiling/sticky-read-with-churn-c1/summary.json`
  - `profiling/sticky-read-with-churn-c8/summary.json`
  - `profiling/sticky-read-with-churn-c32/summary.json`
  - `profiling/capture-and-purge-c1/summary.json`
  - `profiling/capture-and-purge-c8/summary.json`
  - `profiling/capture-and-purge-c32/summary.json`
- This is the baseline to compare future combo-path optimizations against.
