# Dynamic Upstreams Combo Worst-Case - Snapshot

Date: 2026-05-07

Scenario:

- `capture-purge-with-churn`

Artifact:

- `perf/dynamic-upstreams/benchmark/output/2026-05-07T08-44-33.891Z-dynamic-upstreams-releasesmall-worstcase-snapshot`

Command:

```bash
bun perf/dynamic-upstreams/benchmark/run.js --scenario=capture-purge-with-churn --requests=500 --warmup=50 --artifact-tag=worstcase-snapshot
```

Build / profile mode:

- `ZIG_OPTIMIZE=ReleaseSmall`
- `--profile=snapshot` (default)

Headline results:

| concurrency | rps | p50 | p95 | p99 |
|---|---:|---:|---:|---:|
| `1` | 1430.06 | 0.54 ms | 1.28 ms | 4.43 ms |
| `8` | 5314.22 | 1.03 ms | 4.44 ms | 6.52 ms |
| `32` | 4348.32 | 5.88 ms | 23.58 ms | 26.19 ms |

Notes:

- All slices completed `500/500`.
- This is the worst-case milestone-2 combo path: exact cache capture and purge on every iteration while `dynamic-upstreams` activates snapshots in the background.
- The `c=32` slice shows the expected contention signature for this path: throughput drops versus the lighter control-plane path and tail latency grows materially.
- Per-slice profiling summaries are under:
  - `profiling/capture-purge-with-churn-c1/summary.json`
  - `profiling/capture-purge-with-churn-c8/summary.json`
  - `profiling/capture-purge-with-churn-c32/summary.json`
