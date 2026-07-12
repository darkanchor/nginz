# S2 snapshot churn check — 2026-07-12

ReleaseSmall `sticky-read-with-churn`, 200 measured requests per concurrency against the self-contained two-worker combo runtime.

| concurrency | RPS | p50 | p95 | p99 | correctness |
|---:|---:|---:|---:|---:|---:|
| 8 | 5493.23 | 0.96 ms | 2.90 ms | 9.89 ms | 200/200 |
| 32 | 5912.89 | 4.06 ms | 10.49 ms | 11.00 ms | 200/200 |

Request-path snapshot pins already use an atomic reader guard, active-pointer load, and refcount increment rather than the slab mutex. This run found no correctness loss or request-path throughput collapse during bounded activation churn. Slab allocation remains serialized on the control-plane activation path; changing its allocation layout is not justified without a larger-peer benchmark showing it as the dominant latency source.

Artifact: `perf/dynamic-upstreams/benchmark/output/2026-07-12T08-46-32.176Z-dynamic-upstreams-releasesmall-s2-audit/`.
