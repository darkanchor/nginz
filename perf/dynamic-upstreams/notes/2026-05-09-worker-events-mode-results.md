# Dynamic Upstreams Combo - Worker-Events Mode Experiment

Date: 2026-05-09

Artifacts:

- `perf/dynamic-upstreams/benchmark/output/2026-05-09T01-09-39.144Z-dynamic-upstreams-releasesmall-round5-wevents-per-target` (snapshot, sequential)
- `perf/dynamic-upstreams/benchmark/output/2026-05-09T01-09-45.217Z-dynamic-upstreams-releasesmall-round5-wevents-off` (snapshot, sequential)
- `perf/dynamic-upstreams/benchmark/output/2026-05-09T01-10-06.434Z-dynamic-upstreams-releasesmall-round5-wevents-per-target-stat` (perf-stat, parallel — counters only)
- `perf/dynamic-upstreams/benchmark/output/2026-05-09T01-10-06.441Z-dynamic-upstreams-releasesmall-round5-wevents-off-stat` (perf-stat, parallel — counters only)

Command:

```bash
# benchmark_cli.js now accepts --worker-events-mode=off|per_target|summary
ZIG_OPTIMIZE=ReleaseSmall bun perf/dynamic-upstreams/benchmark/run.js \
  --scenario=capture-and-purge --requests=500 --warmup=50 \
  --worker-events-mode=per_target --artifact-tag=round5-wevents-per-target

ZIG_OPTIMIZE=ReleaseSmall bun perf/dynamic-upstreams/benchmark/run.js \
  --scenario=capture-and-purge --requests=500 --warmup=50 \
  --worker-events-mode=off --artifact-tag=round5-wevents-off
```

## What Was Tested

The benchmark issues one purge per iteration and the purge always succeeds (the tag was just captured). With `per_target` mode, every successful purge calls `ngx_http_worker_events_publish_internal`, which:
1. Acquires the worker-events shm mutex
2. Writes ~640 bytes (channel + event type + JSON payload) into a ring slot
3. Releases the mutex

This adds a second `ngx_shmtx_lock` acquisition per iteration, separate from the cache-tags mutex. The question was whether this overhead is measurable.

## Throughput Results (sequential, same session)

| mode | c=1 rps | c=8 rps | c=32 rps |
|---|---:|---:|---:|
| `per_target` | 1104.22 | 5028.13 | 4602.90 |
| `off` | 989.69 | 4678.80 | 5612.62 |
| delta | -10.4% | -6.9% | +21.9% |

The direction is inconsistent: `off` is slower at c=1 and c=8, faster at c=32. The c=1 and c=8 differences (10% and 7%) are within the noise band established from prior runs. The c=32 swing of +21.9% is large enough to be real signal, but one run at each setting is not enough to confirm a stable direction given the run-to-run variance already documented in this benchmark.

Throughput numbers from this benchmark are not conclusive on their own for the worker-events mode comparison.

## Hardware Counter Results (perf-stat, parallel run — counter comparisons only)

The perf-stat runs were launched in parallel, so their throughput numbers are invalid (both nginx instances competed for CPU). The per-request instruction counts are still meaningful because they reflect what each nginx process actually executed per request regardless of scheduling.

| metric | per_target c=32 | off c=32 | delta |
|---|---:|---:|---:|
| instr/req | 103,161 | 100,528 | **-2.6%** |
| cache miss/req | 211.1 | 199.0 | **-5.7%** |
| branch miss rate | 5.95% | 5.96% | flat |

The instruction savings confirm that removing the event publish path is real:
- ~2,600 fewer instructions per request — consistent with removing the ring write and associated JSON payload construction
- ~12 fewer cache misses per request — removing one shm write per purge reduces cache pressure modestly

## What This Tells Us

1. **The event publish is measurably expensive at the instruction level** (~2.6% reduction when removed), but it is small in absolute terms compared to the zeroing fix (-3.7% instr, -16.7% cycles).

2. **The second mutex is not a major bottleneck at moderate concurrency** (c=8). At c=32, removing it appears to reduce contention enough to matter, but single-run variance prevents a firm conclusion from this session.

3. **`off` is not the right default** for production multi-worker deployments. The purpose of `worker_events_mode` is to notify other workers of purges so they can drop their local in-process caches or propagate invalidation. Disabling it silently skips that notification.

## Recommendation

- Use `cache_purge_worker_events_mode off` in single-worker deployments or benchmarks where cross-worker event propagation is not needed. It saves ~2.6% instructions and ~6% cache misses per purge.
- Keep `per_target` as the default for multi-worker configurations. The overhead is real but modest relative to the proxy + cache-tags work on the same path.
- `summary` mode offers no advantage over `per_target` for single-target purges (the current benchmark workload). It only helps for high-fanout batches (many targets per POST) where reducing event count matters.
