# redis performance tooling

This directory contains redis-specific benchmark runners, configs, and notes.

Shared perf helpers live under `perf/common/`.

## Contents

- `nginx.conf` — reference benchmark config for redis GET operations
- `benchmark/` — benchmark runner, scenarios, and validation logic
- `notes/` — iteration logs

## Usage

```bash
# Full matrix (all scenarios, concurrencies 1,8,32)
bun perf/redis/benchmark/run.js

# Narrower run
bun perf/redis/benchmark/run.js --scenario=small-read --concurrency=1,8 --requests=200 --warmup=20

# With perf-stat hardware counters
bun perf/redis/benchmark/run.js --scenario=small-read --concurrency=1,8 --profile=perf-stat
```

## Scenarios

| Scenario | Payload | Description |
|----------|---------|-------------|
| `small-read` | ~30 B | GET a small string |
| `medium-read` | ~1 KB | GET a medium string |
| `large-read` | ~8 KB | GET a large string |
| `static-read` | ~30 B | GET with static key (avoids URI parsing) |

## Baseline (2026-04-27, ReleaseSmall, Redis mock)

```
service     scenario     c=1 rps   c=8 rps   c=32 rps
nginz-redis small-read    2066      4517      4740
nginz-redis medium-read   1894      3964      4735
nginz-redis large-read    1571      3529      3900
nginz-redis static-read   2064      4805      4673
```

### Key observations

- **c=1 throughput**: 1500–2100 rps depending on payload size. The nginx upstream
  path processes ~2000 single-concurrency Redis GETs per second against a local
  mock.
- **Payload sensitivity**: From 30 B to 8 KB, throughput drops only ~25%. The
  nginx upstream buffer chain handles large responses efficiently.
- **Static vs URI key**: Identical throughput — URI-based key extraction has
  negligible overhead on the hot path.
- **c=8 scaling**: ~2.2x throughput increase (vs linear 8x), CPU-bound on the
  single worker core. Maximum observed ~4800 rps.
- **c=32 saturation**: Throughput caps at ~4700 rps regardless of payload —
  the single nginx worker core is fully saturated.

### Comparison with pgrest

| Metric | redis (small-read) | pgrest (medium-page) |
|--------|-------------------|---------------------|
| c=1 rps | 2066 | 374 |
| c=8 rps | 4517 | 932 |
| Latency p50 | 0.39 ms | 1.85 ms |

Redis GET path is ~5.5x faster than pgrest's pooled PostgreSQL path at c=1.
This is expected: the nginx upstream mechanism is simpler than the custom libpq
pool, and the Redis mock responds instantly (no query planning, no JSON
formatting overhead).

## Profiling

Same `--profile=snapshot|perf-stat` modes as pgrest. See
`perf/pgrest/README.md` for counter interpretation guide.

When using `--profile=perf-stat`, the runner monitors the nginz worker PID.
The FIFO-based signalling mechanism (documented in `perf/common/profiling.js`)
avoids Bun spawn/kill limitations with process trees.
