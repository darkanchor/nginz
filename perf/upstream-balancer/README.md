# upstream-balancer — Performance

This directory contains benchmark scaffolding for the upstream-balancer module.

The module is a scaffold (planned native upstream peer-selection and sticky-session
foundation). No actual load-balancing logic is implemented yet — these benchmarks
measure the current directive-handling and proxy-pass path overhead.

## Quick start

```bash
# Snapshot baseline (default) — all scenarios, concurrencies 1,8,32
bun perf/upstream-balancer/benchmark/run.js

# Single scenario
bun perf/upstream-balancer/benchmark/run.js --scenario=sticky-route

# Narrow load
bun perf/upstream-balancer/benchmark/run.js --scenario=sticky-route --concurrency=1,8 --requests=500 --warmup=50
```

## Scenarios

| Name | Description | Expected | Notes |
|------|------------|----------|-------|
| `sticky-route` | GET with sticky cookie + header → 200, proxied to mock backend | JSON body from mock | Full proxy path: balancer directives + upstream + proxy_pass |
| `direct-route` | GET with no sticky headers → 200, default upstream selection | JSON body from mock | Baseline proxy path without sticky overhead |
| `without-balancer` | GET on a non-balancer location → 200 echozn "healthy" | body="healthy" | Module not invoked — measures plain proxy overhead |

## Architecture

```
Bun runner → HTTP → nginz → upstream_balancer directives → proxy_pass → HTTP mock (127.0.0.1:<port>)
```

The upstream backend is an in-process HTTP mock server (via `tests/mocks/http.js`).

## No external dependencies

Zero containers, zero services. The mock backend responds instantly so every
millisecond measured is nginz processing overhead.

## Caveats

- The module is currently a scaffold. Benchmark results reflect the empty-shell
  directive overhead, not real load-balancer performance.
- `sticky-route` and `direct-route` both traverse the upstream and proxy modules.
  Differences between them isolate the sticky-directive parsing overhead.
