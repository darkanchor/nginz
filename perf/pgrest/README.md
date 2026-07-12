# pgrest performance tooling

This directory contains pgrest-specific benchmark runners, configs, fixtures, and notes.

Shared perf helpers live under `perf/common/`.

## Contents

- `nginx.conf` - reference benchmark config shape for pgrest
- `benchmark/` - pgrest vs PostgREST benchmark runner, fixtures, scenarios, and validation logic

## Artifact layout

Each benchmark run now writes a dedicated run directory under `perf/pgrest/benchmark/output/`:

```text
output/<run-id>/
  manifest.json
  benchmark.json
  environment.json
  command.json
  profiling/
    summary.json
    perf-stat.txt        # optional
  logs/
  runtime/              # preserved only with --keep-runtime
```

## Profiling modes

### snapshot (default)

Captures `/proc`-based process and system snapshots before and after the timed
section (PID status, meminfo, loadavg, cmdline).  Zero overhead, always safe.

### perf-stat

Uses Linux `perf stat` to collect hardware and software performance counters for
the nginz worker processes during the timed section.  Requires `perf` to be
installed.

```bash
bun perf/pgrest/benchmark/run.js --profile=perf-stat --scenario=medium-page --service=pgrest
```

The output file `profiling/perf-stat.txt` contains CSV-formatted counter values.
Key counters and what they tell you:

| Counter | What it measures | Good sign | Bad sign |
|---------|-----------------|-----------|----------|
| `task-clock` | CPU time consumed | — | — |
| `instructions` | Instructions executed | — | — |
| `cycles` | CPU cycles | IPC > 1.0 | IPC < 0.5 |
| `branches` | Branch instructions | — | — |
| `branch-misses` | Mispredicted branches | < 5% miss rate | > 10% miss rate |
| `cache-references` | Memory accesses | — | — |
| `cache-misses` | Cache misses | < 5% miss rate | > 20% miss rate |
| `context-switches` | Voluntary + involuntary switches | 0 | > 0 per request |
| `cpu-migrations` | Core migrations | 0 | > 0 per request |
| `page-faults` | Minor + major faults | < 1 per request | > 10 per request |

**Interpreting results**:
- `context-switches = 0` and `cpu-migrations = 0` confirm the nginx worker is
  never descheduled — our non-blocking pooled path is working as designed.
- `branch-misses < 5%` shows predictable control flow — the JSON formatter's
  fast-path branching and no-escape detection are well-predicted.
- `cache-misses < 15%` suggests reasonable memory locality.
- IPC (instructions / cycles) above 1.0 indicates efficient CPU utilization.

**NMI watchdog**: Hardware counters may show `<not counted>` if the NMI watchdog
is enabled.  Disable it temporarily (requires root):
```bash
echo 0 | sudo tee /proc/sys/kernel/nmi_watchdog
# ... run benchmark ...
echo 1 | sudo tee /proc/sys/kernel/nmi_watchdog
```
The runner attempts this automatically but will continue with software counters
if permission is denied.

## Usage

```bash
bun perf/pgrest/benchmark/run.js --help

# default matrix, both pgrest and postgrest
bun perf/pgrest/benchmark/run.js

# narrower run
bun perf/pgrest/benchmark/run.js --scenario=small-page --concurrency=1,8 --requests=200 --warmup=20

# enable optional perf stat capture when available
bun perf/pgrest/benchmark/run.js --profile=perf-stat --scenario=small-page --service=pgrest
```

Default profiling mode is `snapshot`. When `perf` is installed and the user asks for `--profile=perf-stat`, the runner adds system-counter capture without requiring module instrumentation.

The PostgreSQL container defaults to `pg18`; set `PGREST_BENCH_PG_CONTAINER` to reuse an already-running compatible container without renaming or disrupting it.

Results are written to `perf/pgrest/benchmark/output/`.

The runner now isolates each invocation with:

- a per-run benchmark database name
- a per-run nginz listen port
- a per-run PostgREST port/admin port when PostgREST is enabled
- a generated runtime nginx config written into the run artifact tree

## Schema cache note

PostgREST has a persistent startup-loaded schema cache that can be reloaded.

The current `pgrest` module does **not** have that same kind of persistent schema cache. It performs targeted runtime introspection for specific features such as relationship and RPC metadata, but there is no resident cached metadata layer equivalent to PostgREST's `SchemaCache`.
