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

Analysis:

- This run separates three materially different paths:
  - `sticky-read`: steady-state request path through `upstream-balancer`, `dynamic-upstreams`, `healthcheck`, and proxying with `cache_tags` capture enabled.
  - `sticky-read-with-churn`: same request path while a background loop keeps activating replacement snapshots through `PUT /dynamic-upstreams`.
  - `capture-and-purge`: proxy one tagged response, then issue an exact `cache-purge` mutation against the shared `cache-tags` store.
- The hot path is therefore not "dynamic-upstreams only". It is a combined runtime path:
  - sticky peer lookup in `upstream-balancer`
  - health-aware peer eligibility checks
  - upstream proxying
  - response-side tag capture into the shared metadata store
  - and, for the purge scenario, exact invalidation plus worker-events publication
- The interesting result is that snapshot churn is not the dominant cost in the common proxy-read path. At `c=32`, `sticky-read-with-churn` is 13.1% faster than `sticky-read` in this snapshot run (`8010.56` vs `7082.93` rps). That should not be read as "churn improves performance"; it means the bounded two-peer weight-flip workload does not create a clear throughput penalty here, and ordinary run-to-run placement or client scheduling noise is large enough to swamp the control-plane overhead.
- The purge path is where the real cost appears. At `c=1`, `capture-and-purge` is roughly 50.3% slower than `sticky-read` (`1392.58` vs `2803.98` rps), which is consistent with the scenario doing two HTTP control operations and a shared-store mutation on every measured iteration. At `c=32`, the gap narrows to 8.8%, which means the worker can overlap parts of the control cycle under load, but the path is still clearly heavier than a steady proxied read.
- Tail latency in this baseline snapshot does not scale monotonically with "more control-plane work":
  - `sticky-read` has the worst `c=32` p95 at `15.74 ms`
  - `sticky-read-with-churn` lands at `8.60 ms`
  - `capture-and-purge` lands at `9.60 ms`
- That again argues against simplistic one-run conclusions. For throughput gating, treat this snapshot as useful directionally, but use the paired `perf-stat` run for the more defensible story about where extra cost shows up.

What this run says with high confidence:

- Bounded snapshot activation is not obviously destabilizing the common sticky proxy path.
- Exact capture-plus-purge is the first path that materially changes the performance profile of the stack.
- The combo benchmark behaves like a CPU-and-metadata-mutation study, not an I/O-blocking study.

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
- Use [2026-05-07-baseline-perf-stat.md](/home/kaiwu/Documents/gitea/nginz/perf/dynamic-upstreams/notes/2026-05-07-baseline-perf-stat.md) for hardware-counter analysis of the same scenario set.
- This is the baseline to compare future combo-path optimizations against, but the perf-stat companion note is the better source for hot-path claims.
