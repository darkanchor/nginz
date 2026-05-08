# Dynamic Upstreams Combo - Best Benchmarks

Date: 2026-05-09

This note records the best measured results from the 2026-05-08 milestone-2 hardening rounds, not simply the last experiment that was run.

## Best Artifacts

Best retained `sticky-read` slice:

- `perf/dynamic-upstreams/benchmark/output/2026-05-08T10-23-53.868Z-dynamic-upstreams-releasesmall-round3-post-healthcheck-index`

Best measured `capture-and-purge` slice:

- `perf/dynamic-upstreams/benchmark/output/2026-05-08T09-38-31.422Z-dynamic-upstreams-releasesmall-round2b-post-uritbl`

Reference baseline snapshot:

- `perf/dynamic-upstreams/benchmark/output/2026-05-07T08-26-18.625Z-dynamic-upstreams-releasesmall-baseline-snapshot-final`

## Headline Results

| scenario | artifact tag | c=1 rps | c=8 rps | highest measured p95 |
|---|---|---:|---:|---:|
| `sticky-read` | `round3-post-healthcheck-index` | `2459.53` | `6178.79` | `2.93 ms` at `c=8` |
| `capture-and-purge` | `round2b-post-uritbl` | `1525.62` | `5247.06` | `2.44 ms` at `c=8` |

## Baseline Comparison

2026-05-07 baseline snapshot at the same scenarios:

| scenario | c=1 rps | c=8 rps |
|---|---:|---:|
| `sticky-read` | `2803.98` | `6592.49` |
| `capture-and-purge` | `1392.58` | `5563.54` |

Read against baseline:

- `sticky-read` did not produce a clear improvement story in these rounds; the measured shape is still noisy enough that structure-only changes should not be oversold from one run
- `capture-and-purge` is where the meaningful proven win landed
  - `c=1`: `1392.58 -> 1525.62` which is a `+9.6%` throughput improvement
  - `c=8`: `5563.54 -> 5247.06` which is a `-5.7%` throughput change
  - `c=8 p95`: baseline snapshot did not report this row directly, but the best retained round stayed at `2.44 ms`

## What Produced The Best Result

The strongest measured gain in `capture-and-purge` came from reducing wasted `cache-tags` metadata work:

- bounded tag walks stop once the active tag set is exhausted
- `addUriToTag()` returns immediately once a tag has already reached its URI cap

That second change matters most in the combo benchmark because stable tags like `combo` and `backend-*` saturate early. Before the change, the module kept paying duplicate-check cost on each captured response even though the tag could not accept more URIs.

## What Did Not Become The New Best

Later rounds were useful for ruling things out:

- healthcheck peer-probe address indexing cleaned up the lookup path, but did not establish a clear new `sticky-read` high-water mark
- the broader exact-array purge fast parser regressed the combo benchmark and was removed
- the remaining direct-index exact purge cleanup is safe, but it is not the source of the best measured throughput

## Current Recommendation

Use this note as the benchmark reference for the best measured state from the 2026-05-08 hardening work.

If the next round is meant to exploit user-visible opt-in/opt-out tradeoffs, the right target is now:

- `cache_purge_worker_events_mode per_target`
- `cache_purge_worker_events_mode summary`
- `cache_purge_worker_events_mode off`

That needs a dedicated multi-target purge benchmark slice, because the current combo benchmark only purges one exact target per iteration.
