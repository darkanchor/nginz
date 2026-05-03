# cache-purge — Performance

Performance scaffolding for the cache-purge module.

The module is currently a scaffold (planned selective cache-purge API intended to
complement `cache-tags`). The main endpoint returns a 501 placeholder. These
benchmarks establish a baseline for the current minimal path.

## Quick start

```bash
# Full matrix (all scenarios, concurrencies 1,8,32)
bun perf/cache-purge/benchmark/run.js

# Single scenario
bun perf/cache-purge/benchmark/run.js --scenario=placeholder-501

# Narrow load
bun perf/cache-purge/benchmark/run.js --scenario=placeholder-501 --concurrency=1,8 --requests=500 --warmup=50
```

## Scenarios

| Name | Description | Expected | Notes |
|------|------------|----------|-------|
| `placeholder-501` | GET on scaffold endpoint → 501 + JSON body | status=501, body={"status":"not_implemented","module":"cache_purge"} | Full module directive path, minimal response |
| `placeholder-head` | HEAD on scaffold endpoint → 501, empty body | status=501, body="" | Same path, HEAD method — headers-only path |
| `healthy-route` | GET on `/` → 200 "ok" | body="ok" | Neighboring echozn route — baseline module-off path |

## No external dependencies

Zero containers, zero services. The module responds with inline JSON or delegates
to echozn.

## Caveats

- The 501 path is the current production path for this scaffold module.
  When the module gets a real implementation with cache-key matching and
  zone-based purging, the overhead profile will change materially and a new
  baseline must be collected.
- This module is designed to complement `cache-tags`; a combined perf scenario
  may be appropriate once both modules have real implementations.
