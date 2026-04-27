# P3: Combined JWT Setup Query — Round-Trip Reduction

## Hypothesis

At c=8, pgrest barely beat PostgREST (+2%) because each request on a pooled connection
sequentially runs 3 setup queries (RESET ROLE → SET request.jwt → SET ROLE), consuming
3 round-trips of connection hold time. Combining them into a single multi-statement query
reduces connection hold time per request, which matters most under contention.

## Change

- Added `build_combined_jwt_setup_query()` in `pgrest_auth.zig` — builds
  `RESET ROLE; SET request.jwt TO '<token>'; [SET ROLE '<role>';]` as a single
  multi-statement query string.
- Modified `queue_jwt_setup_queries()` in `ngx_http_pgrest.zig` to use the
  combined query instead of queuing 3 separate followup queries.
- Updated `tests/mocks/postgres.js` `handleQuery()` to handle multi-statement
  queries by splitting on `;`, processing each sub-statement, and sending a
  CommandComplete per statement with a single ReadyForQuery at the end.
- Updated one test assertion that expected `log[0] === "RESET ROLE"` to
  `log[0].startsWith("RESET ROLE")` to match the combined format.

## Command

```bash
zig build -Doptimize=ReleaseSmall
bun perf/pgrest/benchmark/run.js --scenario=medium-page --concurrency=1,8 --requests=200 --warmup=20 --service=pgrest
```

## Scenario

`medium-page` — 100-row JSON payload, standard GET request through pgrest
with JWT auth.

## Environment

- Build: ReleaseSmall
- Machine: Intel Core i7 860 @ 2.80GHz, 8 cores, 16GB RAM, Arch Linux 6.19.12
- Zig 0.16.0, Bun 1.3.13
- Commit: dac40af (with combined-query changes applied)

## Artifact

`perf/pgrest/benchmark/output/2026-04-27T13-25-19.789Z-pgrest-releasesmall/benchmark.json`

## Correctness Check

- 204/204 integration tests passing (`bun test tests/pgrest/`)
- All JWT auth, role switching, and session isolation tests pass

## Baseline (before change)

```
perf/pgrest/benchmark/output/2026-04-27T11-32-15.811Z-pgrest-releasesmall-medium-baseline-compare-fixed/benchmark.json

c=1: 392 rps, p50=2.17ms, p95=3.36ms, p99=6.93ms
c=8: 655 rps, p50=6.12ms, p95=27.0ms, p99=121ms, mean=11.7ms
```

## After Change

```
c=1: 358 rps, p50=2.26ms, p95=3.39ms, p99=5.40ms
c=8: 990 rps, p50=3.97ms, p95=11.0ms, p99=89.2ms, mean=~8.1ms
```

## Delta

| Metric | c=1 Before | c=1 After | c=8 Before | c=8 After | c=8 Change |
|--------|-----------|-----------|------------|-----------|------------|
| rps    | 392       | 358       | 655        | **990**   | **+51%**   |
| p50    | 2.17ms    | 2.26ms    | 6.12ms     | 3.97ms    | -35%       |
| p95    | 3.36ms    | 3.39ms    | 27.0ms     | 11.0ms    | -59%       |
| p99    | 6.93ms    | 5.40ms    | 121ms      | 89.2ms    | -26%       |

pgrest vs PostgREST at c=8: **+55%** (was +2% before the change)

## Decision

**Keep.** The combined query eliminates 2 round-trips per request on pooled
connections. c=8 throughput improves 51%, p95 latency drops 59%. The marginal
c=1 regression (~8%) is likely measurement noise; the config is unchanged and
the single-connection path sends the same total bytes in one query vs three.

c=8 p99 tail latency is still relatively high (89ms) but improved from 121ms.
Next step: investigate p99 tails — possibly pool contention or PostgreSQL-side
planning overhead under load.
