# Redis Module — perf-stat Hardware Counter Analysis

## Hypothesis

The redis module uses nginx's built-in upstream mechanism (no custom pool).
It should show zero context switches / CPU migrations (same as pgrest) but much
lower instructions per request since there's no JSON formatting or PostgreSQL
protocol overhead.

## Command

```bash
bun perf/redis/benchmark/run.js --scenario=small-read --concurrency=1,8 \
  --requests=100 --warmup=10 --profile=perf-stat
```

(Captured separately with `--artifact-tag=c1-only` for c=1 to avoid output
file overwrite.)

## Scenario

`small-read` — GET a 30-byte string value from Redis mock (localhost).

## Artifacts

- c=1: `perf/redis/benchmark/output/2026-04-27T15-50-08.903Z-redis-releasesmall-c1-only/profiling/perf-stat.txt`
- c=8: `perf/redis/benchmark/output/2026-04-27T15-49-23.649Z-redis-releasesmall/profiling/perf-stat.txt`

## Results

### c=1 (100 requests, 1933 rps, ~52ms wall)

```
task-clock:       16.2 ms   (31% CPU — mostly idle waiting for mock)
instructions:     3.47 M    (34.7K per request — 40x leaner than pgrest)
cycles:           10.5 M    (IPC = 0.33 — very low, I/O bound)
branches:         807 K     (8.1K per request)
branch-misses:     77 K     (9.5% miss rate — event loop dispatch)
cache-references: 256 K
cache-misses:      3.3 K    (1.3% miss rate — excellent)
context-switches:   0       ← worker never blocks
cpu-migrations:     0       ← pinned
page-faults:        0
```

### c=8 (104 requests, 2998 rps, ~35ms wall)

```
task-clock:        8.67 ms  (25% CPU — even lower under concurrency)
instructions:     2.38 M    (22.9K per request — less than c=1!)
cycles:           6.56 M    (IPC = 0.36)
branches:         559 K     (5.4K per request)
branch-misses:     36 K     (6.4% miss rate)
cache-references: 133 K
cache-misses:      6.7 K    (5.0% miss rate)
context-switches:   0
cpu-migrations:     0
page-faults:        1
```

## Analysis

### Redis vs pgrest: 40x instruction efficiency

| Metric | redis (small-read, c=1) | pgrest (medium-page, c=1) | Ratio |
|--------|------------------------|--------------------------|-------|
| instructions/req | 34.7 K | 1.39 M | **40x** |
| task-clock/req | 162 µs | 760 µs | 4.7x |
| IPC | 0.33 | 1.11 | — |

The redis upstream path executes 40x fewer instructions per request than
pgrest's pooled PostgreSQL path.  This quantifies the cost of pgrest's feature
surface: JSON formatting, SQL building, JWT validation, parameterized queries,
and custom pool management.

### Instructions per request DECREASES with concurrency (unlike pgrest)

For pgrest, c=8 had 3.15x more instructions per request than c=1 (pool
contention overhead).  For redis, c=8 has 34% FEWER instructions per request
(34.7K → 22.9K).  Why?

The nginx upstream mechanism interleaves concurrent connections efficiently
within a single event loop iteration.  At c=1, the worker handles one
connection's events per iteration plus idle-loop overhead.  At c=8, multiple
connections are ready on each iteration, amortizing the event loop's fixed
cost across more requests.

### I/O bound, not CPU bound

IPC of 0.33 is the defining characteristic: the worker spends ~2/3 of its time
stalled waiting for the mock to respond.  This is the correct behavior for an
event-driven proxy — the worker should never spin on CPU when I/O is pending.

Compare with pgrest's IPC of 1.11 at c=1 and 1.48 at c=8 — pgrest is
CPU-bound (JSON formatting, SQL logic), while redis is I/O-bound (waiting on
upstream).

### The nginx upstream is the right architecture

Zero context switches and CPU migrations at both concurrency levels confirm
that nginx's built-in upstream mechanism is as non-blocking as pgrest's custom
pool.  But it achieves this with 40x fewer instructions per request.  This is
the architecture to prefer for simple proxy/passthrough modules.

### Branch miss rate

At 6.4–9.5%, the branch miss rate is higher than pgrest's 1.6–2.4%.  This
reflects the nginx event loop's dispatch logic — the code path per event is
short and the branch pattern varies with the number of ready connections.
Not a concern at this scale.

## Decision

The redis module's perf characteristics confirm the architectural best practice:
use nginx's built-in upstream for simple proxy modules, reserve custom pools
only when the upstream protocol requires non-trivial state management (like
pgrest's JWT role switching and parameterized queries).
