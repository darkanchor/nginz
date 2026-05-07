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

Analysis:

- This scenario is the real milestone-2 stress slice: every measured iteration does a proxied capture, exact purge, and concurrent snapshot activation churn. It is the shortest path in this suite to shared-store mutation pressure, event publication, and cross-worker convergence work happening together.
- The shape is different from the baseline proxy-read scenarios:
  - `c=1 -> c=8` scales well (`1430.06` -> `5314.22` rps, 3.7x)
  - `c=32` then collapses to `4348.32` rps, 18.2% below `c=8`
  - p95 jumps from `4.44 ms` at `c=8` to `23.58 ms` at `c=32`
- That is the classic signature of a contention-sensitive control path rather than a pure steady-state proxy path. The workload is still bounded and succeeds `500/500`, but once concurrency rises high enough the worker spends noticeably more time in queueing/tail amplification around the mutation-heavy path.
- Compared with the baseline snapshot `capture-and-purge` slice at `c=32`, worst-case combo throughput drops another 32.7% (`4348.32` vs `6456.32` rps) and p95 grows by 145.7% (`23.58 ms` vs `9.60 ms`). That delta is too large to explain by the extra `PUT /dynamic-upstreams` traffic alone; it points to the interaction between purge mutations and concurrent activation churn being the real source of pain.
- The companion perf-stat run shows a more stable headline (`5188.41` rps at `c=32`) than this snapshot run. That gap matters: this worst-case slice has visible run-to-run variance at high concurrency, so a single snapshot run should not be used as an absolute gate. The safe conclusion is qualitative:
  - this path is markedly more fragile than steady sticky reads
  - its first failure mode is tail latency under concurrency
  - and any optimization work should focus on shared metadata mutation and fanout, not the proxy read path

What this run says with high confidence:

- The combo worst-case path is not limited by simple request parsing or upstream proxying.
- The cost emerges only when exact purge and snapshot activation overlap.
- `c=32` is the first slice where the shared-control-plane path becomes visibly unstable enough to deserve dedicated tuning work.

Notes:

- All slices completed `500/500`.
- This is the worst-case milestone-2 combo path: exact cache capture and purge on every iteration while `dynamic-upstreams` activates snapshots in the background.
- The `c=32` slice shows the expected contention signature for this path: throughput drops versus the lighter control-plane path and tail latency grows materially.
- Per-slice profiling summaries are under:
  - `profiling/capture-purge-with-churn-c1/summary.json`
  - `profiling/capture-purge-with-churn-c8/summary.json`
  - `profiling/capture-purge-with-churn-c32/summary.json`
- Use [2026-05-07-worstcase-perf-stat.md](/home/kaiwu/Documents/gitea/nginz/perf/dynamic-upstreams/notes/2026-05-07-worstcase-perf-stat.md) for the counter-oriented breakdown of the same scenario.
