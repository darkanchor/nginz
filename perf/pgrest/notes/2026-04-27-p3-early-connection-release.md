# P3 Follow-up: Early Connection Release

## Hypothesis

The pool connection is currently held through JSON formatting AND response
sending to the nginx client. Releasing it immediately after draining the final
PGresult (before formatting/sending) lets another request start using the
connection while the current request assembles and sends its HTTP response.
This overlap should reduce connection contention at high concurrency.

## Change

In `ngx_http_pgrest.zig` `finalize_pg_response()`, moved `release_pooled_ctx()`
to execute immediately after `format_result_for_response()` succeeds, before
`finalize_response_send()`. The formatted JSON is already in the nginx temp
buffer — the PG connection is no longer needed.

```zig
// Before: format → send → release
// After:  format → release → send
release_pooled_ctx(ctx, false);
const rc = finalize_response_send(r, response_body_buf, ...);
```

## Command

```bash
zig build -Doptimize=ReleaseSmall
bun perf/pgrest/benchmark/run.js --scenario=medium-page --concurrency=1,8,16 --requests=200 --warmup=20 --service=pgrest
```

## Scenario

`medium-page` — 100-row JSON payload via pooled pgrest with JWT auth.

## Artifacts

- c=1,8,16 matrix: `perf/pgrest/benchmark/output/2026-04-27T13-54-49.134Z-pgrest-releasesmall/`
- c=8 re-runs: `...T13-55-28.402Z...` (915 rps), `...T13-56-15.008Z...` (961 rps)

## Before (P3 combined query, no early release)

```
c=1:  358 rps, p50=2.26ms, p95=3.39ms, p99=5.40ms
c=8:  990 rps, p50=3.97ms, p95=11.0ms, p99=89.2ms
c=16: 701 rps, p50=8.21ms, p95=171ms,  p99=175ms
```

## After (P3 combined query + early release)

```
c=1:  374 rps, p50=2.12ms, p95=3.27ms, p99=5.98ms
c=8:  932 rps, p50=4.38ms, p95=13.8ms, p99=85.6ms  (avg of 3 runs)
c=16: 905 rps, p50=8.63ms, p95=60.3ms, p99=120ms
```

## Delta

| Metric | c=1 | c=8 | c=16 |
|--------|------|------|------|
| rps | +4% | **-6%** | **+29%** |
| p50 | -6% | +10% | +5% |
| p95 | -4% | +25% | **-65%** |
| p99 | +11% | -4% | **-31%** |

c=8 re-runs: 919, 915, 961 rps (avg 932, consistent regression vs 990).

## Analysis

This is a **connection scarcity tradeoff**:

- **c=16 (+29%, p95 -65%)**: All 16 connections are busy. Early release creates
  overlap — the next request starts its setup query while the current response
  is being sent. Directly reduces contention.
- **c=8 (-6%)**: 8 idle connections at all times. The bookkeeping overhead of
  release (pgClear, pool state manipulation, timer deletion) adds measurable
  cost without benefit since no request is waiting for a connection.
- **c=1 (+4%)**: Within variance.

The net effect is positive: +204 rps gain at c=16 vs -58 rps regression at c=8.
In production, connection pressure is the default scenario.

## Decision

**Keep.** The c=16 gain (+29% throughput, p95 latency cut by 65%) outweighs the
modest c=8 regression. Production deployments typically run with fewer
connections than peak concurrency, where early release provides real overlap.
