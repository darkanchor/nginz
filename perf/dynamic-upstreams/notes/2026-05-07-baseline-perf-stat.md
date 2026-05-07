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

Counter-derived view of the hot path:

| scenario | payload | instr/req | cycles/req | IPC | branch miss rate | cache miss rate |
|---|---:|---:|---:|---:|---:|---:|
| `sticky-read c32` | 70 B | 59.8k | 144.3k | 0.415 | 5.56% | 3.35% |
| `sticky-read-with-churn c32` | 71 B | 60.8k | 127.9k | 0.475 | 4.90% | 4.35% |
| `capture-and-purge c32` | 253.6 B | 107.6k | 294.4k | 0.365 | 5.70% | 4.68% |

Analysis:

### 1. Snapshot activation churn is not the expensive part of the common read path

At `c=32`, `sticky-read-with-churn` outperforms plain `sticky-read` in this run (`8513.47` vs `7165.45` rps), while instructions per request move only from `59.8k` to `60.8k` (+1.7%). That is the key finding from the baseline set:

- bounded snapshot activation does add some metadata/cache pressure
- but it does **not** materially expand the CPU hot path for a normal sticky proxied read
- the throughput difference is therefore better explained by normal run variance and slightly different backend distribution than by any real speedup from churn itself

The hot request path stays dominated by steady proxy work:

- sticky peer selection in `upstream-balancer`
- health-aware eligibility filtering
- proxied read to the local backend
- lightweight `cache_tags` capture

### 2. Exact purge roughly doubles the per-request CPU footprint

The moment the benchmark switches from read-only traffic to `capture-and-purge`, the profile changes sharply:

- throughput at `c=32` falls 32.4% relative to `sticky-read`
- instructions per request jump 79.8% (`59.8k` -> `107.6k`)
- cycles per request jump 104.0% (`144.3k` -> `294.4k`)
- cache misses per request jump from `97.7` to `233.4`

That is the cleanest evidence in this note. The costly part of the milestone-2 combo stack is not "dynamic upstreams exist"; it is the operator control cycle that forces:

- one tagged proxied response
- JSON parsing and request validation on the purge endpoint
- exact lookup/mutation in the shared `cache-tags` store
- per-target accounting
- optional worker-events publication

### 3. The common path remains scheduler-clean

Every profiled slice reports:

- `0` context switches
- `0` CPU migrations

So the combo baseline is not hiding blocking syscalls or descheduling pathologies. The cost is on-CPU and in-process. That matches the code structure: most work is local metadata handling, sticky selection, and proxy/filter logic rather than kernel wakeups or cross-process waits.

### 4. Cache behavior points to shared metadata mutation, not a blown instruction cache

The cache-miss rates are still moderate across the set:

- `sticky-read c32`: `3.35%`
- `sticky-read-with-churn c32`: `4.35%`
- `capture-and-purge c32`: `4.68%`

Those are not catastrophic numbers. They do, however, show a consistent direction:

- bounded snapshot churn perturbs cache locality a bit
- exact purge perturbs it more

That matches the design of the runtime:

- snapshot activation touches shared peer-generation state and event publication
- purge walks and mutates the canonical `cache-tags` metadata store
- both paths are bounded, but only purge materially increases the amount of per-request shared mutable state traffic

### 5. Branch behavior is stable enough that control flow is not the first tuning target

Branch miss rates stay in a narrow band from `4.90%` to `5.70%`. That is useful because it rules out one easy but wrong conclusion. The combo-path slowdown is not primarily from branch-heavy parser chaos or highly unpredictable dispatch. The bigger story is instruction count and cache footprint.

Optimization priorities implied by this baseline:

1. Keep the steady sticky proxy path alone unless later runs show regression there.
2. Focus on `capture-and-purge`, especially shared-store invalidation and fanout work.
3. Treat snapshot activation overhead as secondary until it appears in a mutation-heavy overlapping scenario.

Notes:

- All slices completed `500/500`.
- The runner now writes one `perf-stat.txt` and one `summary.json` per scenario/concurrency slice under `profiling/`.
- The earlier `baseline-perf-stat` run from the same day is superseded; it predated the bounded FIFO teardown and per-slice profiling layout.
- This note is the best source for baseline hot-path claims; the snapshot companion note is better treated as the headline throughput table.
