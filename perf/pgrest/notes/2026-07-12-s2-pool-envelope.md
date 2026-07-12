# S2 pool envelope check — 2026-07-12

ReleaseSmall, `small-page`, 200 measured requests after 20 warmups, pgrest only.

The initial run used `pgrest_pool_size 16`. Concurrency 1 and 8 completed, but concurrency 32 produced pool-exhaustion 503 responses. The configurable maximum was raised to 32 while the production default remains 16, and the benchmark config now opts into 32.

| concurrency | RPS | p50 | p95 | p99 | correctness |
|---:|---:|---:|---:|---:|---:|
| 1 | 881.38 | 0.92 ms | 1.51 ms | 5.32 ms | 200/200 |
| 8 | 2545.50 | 2.20 ms | 6.45 ms | 17.76 ms | 200/200 |
| 32 | 2012.35 | 11.34 ms | 37.57 ms | 75.60 ms | 200/200 |

Result: 32 connections remove the correctness failure but do not improve peak throughput for this workload. Keep 16 as the conservative default; use a larger pool only after observing the deployment's database capacity and latency knee.

Artifact: `perf/pgrest/benchmark/output/2026-07-12T08-49-44.034Z-pgrest-releasesmall-s2-pool32/`.
