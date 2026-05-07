# Dynamic Upstreams Combo Benchmark

This is the combined Milestone 2 performance harness.

It replaces the removed per-module perf scaffolding for:

- `dynamic-upstreams`
- `upstream-balancer`
- `healthcheck`
- `worker-events`

and keeps `cache-tags` plus `cache-purge` in the same runtime so the common operator control path can be measured beside the main proxy path.

## Why this suite exists

Those modules do not make much sense as isolated microbenchmarks. The common real deployment shape is:

- request traffic goes through `upstream-balancer`
- upstream membership is owned by `dynamic-upstreams`
- peer eligibility is shaped by `healthcheck`
- convergence signals flow through `worker-events`
- cache metadata can be invalidated through `cache-purge`

So this suite measures the stack as one runtime, named after `dynamic-upstreams` because that is the control-plane anchor.

## Scenarios

- `sticky-read`
  - steady proxy traffic through `upstream-balancer` with `cache_tags` enabled on the proxied location
- `sticky-read-with-churn`
  - the same traffic path while `PUT /dynamic-upstreams` keeps activating new snapshots in the background
- `capture-and-purge`
  - proxy one tagged response, then purge that exact tag through `cache-purge`
- `capture-purge-with-churn`
  - worst-case milestone-2 combo path: capture and exact purge on every measured iteration while `dynamic-upstreams` keeps activating snapshots in the background

## What the runtime includes

- `worker_processes 2`
- one managed upstream with:
  - `upstream_balancer_sticky_cookie`
  - `dynamic_upstreams_managed`
  - active upstream probes from `healthcheck`
- one `dynamic_upstreams_api` endpoint
- one `worker_events_api` endpoint
- one proxied app location with `cache_tags`
- one `cache_purge_api` endpoint

The runner starts two local mock backends and writes a generated nginx config into the per-run runtime directory.

## Usage

```bash
bun perf/dynamic-upstreams/benchmark/run.js
```

Examples:

```bash
bun perf/dynamic-upstreams/benchmark/run.js --scenario=sticky-read --requests=2000 --concurrency=8,32,64
bun perf/dynamic-upstreams/benchmark/run.js --scenario=sticky-read-with-churn --requests=1000 --concurrency=16 --artifact-tag=churn
bun perf/dynamic-upstreams/benchmark/run.js --scenario=capture-and-purge --requests=500 --concurrency=8
```

Default perf build mode is `ReleaseSmall`.

## Notes

- The generated runtime uses `PUT`-driven snapshot activation, not the static-file refresh timer.
- The churn scenario is intentionally bounded and uses the same backend addresses with changed weights so the benchmark stresses activation and fanout without inventing unrelated topology churn.
- `cache-purge` is measured as a control-plane cycle, not as a request-path feature bolted onto every proxied read.
- `capture-purge-with-churn` is the intended worst-case study slice for milestone 2 because it combines shared metadata mutation, worker-events publication, and background snapshot activation in one runtime.
