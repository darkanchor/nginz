## Health Check Module

Active and passive health/readiness endpoints for nginx with shared-memory aggregation, active HTTP/HTTPS probing, per-upstream probes, match rules, slow-start recovery, and Prometheus metrics.

### Status

**Feature-complete for probing/reporting, with balancer and worker-events integration landed** — The module provides service-level readiness, per-upstream probes, per-peer probes, body/status match rules, HTTPS support, slow-start recovery tracking, a Prometheus-format metrics endpoint, nginx variables, worker-events transition fanout, and a balancer-facing peer-eligibility contract consumed by `upstream-balancer`. It still does not mark nginx upstream peers `down` directly, and upstream/peer probe failures still do not drive `/ready` by themselves.

### Rationale

The `healthcheck` module is different from the pure scaffolded milestone-2 modules because it already does real work today. Its job is to give nginx a shared answer to two different questions:

- “Am I alive?”
- “Am I ready to serve traffic?”

It does that with two signal types:

- passive request/failure counters aggregated across workers
- active probes that periodically check a target and publish the result into shared memory

The design is intentionally simple at the core. One worker owns the probe timers, updates shared state, and every worker reads the same readiness/health view. That keeps `/health`, `/healthz`, `/ready`, variables, and metrics consistent across workers instead of each worker inventing a private answer.

This module currently solves the reporting/probing side of the problem well:

- service-level liveness and readiness endpoints
- active HTTP/HTTPS probes with thresholds
- per-upstream and per-peer probe reporting
- match rules, slow-start tracking, and metrics

What it still does **not** do is the narrower remaining part of milestone 2:

- mark upstream peers down in nginx core structures
- make upstream or peer probe failures change `/ready` by themselves
- define broader routing policy beyond the balancer-side eligibility contract

That remaining work belongs at the integration boundary with `upstream-balancer` and `worker-events`, not inside probe execution itself.

### Features

- **Shared-memory counters**: passive request and failure counts aggregate across nginx workers
- **Shared readiness state**: `/ready` and `/health` read the same probe result from shared memory
- **Active HTTP/HTTPS probing**: one worker periodically probes configured targets and shares the result across workers
- **Threshold-based health transitions**: configurable consecutive fail/pass thresholds drive readiness and probe health
- **Per-upstream and per-peer visibility**: `/health` reports service-level, upstream-level, and peer-level probe state
- **Prometheus metrics**: `/metrics` exports the module state in text format for scraping
- **Nginx variables**: readiness/liveness/probe-state variables are available to scripted or native routing logic
- **Worker-events transition fanout**: service-level probe state transitions can publish notifications into the worker-events ring
- **Balancer-facing peer eligibility**: `upstream-balancer` can exclude unhealthy or slow-starting peers through `ngz_healthcheck_is_peer_eligible()`

### Directives

#### Location-context

| Directive | Args | Default | Description |
|---|---|---|---|
| `health_status` | — | — | Enable `/health` JSON endpoint |
| `health_liveness` | — | — | Enable `/healthz` liveness endpoint |
| `health_readiness` | — | — | Enable `/ready` readiness endpoint |
| `health_metrics` | — | — | Enable Prometheus-format metrics endpoint |
| `health_probe` | `http[s]://host:port/path` | — | Service-level probe target |
| `health_probe_interval` | `<time>` | `5000ms` | Probe interval |
| `health_probe_timeout` | `<time>` | `1000ms` | Socket send/recv timeout |
| `health_probe_fails` | `<count>` | `2` | Consecutive failures to go unhealthy |
| `health_probe_passes` | `<count>` | `1` | Consecutive successes to recover |
| `health_probe_slow_start` | `<time>` | `0` (disabled) | Recovery ramp duration |
| `health_probe_match` | `status=<min>-<max> [body=<str>]` | — | Match rules for probe response |
| `health_worker_events_channel` | `<channel>` | — | Publish service-level transition events to the worker-events default zone |

#### Upstream-context

| Directive | Args | Default | Description |
|---|---|---|---|
| `health_upstream_probe` | `http[s]://host:port/path` | — | Per-upstream probe target |
| `health_upstream_probe_interval` | `<time>` | `5000ms` | Probe interval |
| `health_upstream_probe_timeout` | `<time>` | `1000ms` | Socket timeout |
| `health_upstream_probe_fails` | `<count>` | `2` | Fail threshold |
| `health_upstream_probe_passes` | `<count>` | `1` | Pass threshold |
| `health_upstream_probe_slow_start` | `<time>` | `0` | Recovery ramp |
| `health_upstream_probe_match` | `status=<min>-<max> [body=<str>]` | — | Match rules |
| `health_upstream_peer_probe` | `<addr> <http[s]://host:port/path>` | — | Per-peer probe (repeatable) |

### Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      Shared Memory                        │
│  ┌─────────────────┐ ┌──────────────┐ ┌──────────────┐  │
│  │ Service-level    │ │ Per-upstream  │ │ Per-peer       │  │
│  │ store            │ │ stores        │ │ stores         │  │
│  └─────────────────┘ └──────────────┘ └──────────────┘  │
└──────────────────────────────────────────────────────────┘
         ▲                    ▲                 ▲
         │ write (w0)         │ write (w0)      │ write (w0)
         │                    │                 │
┌────────┴──────┐  ┌─────────┴────┐  ┌────────┴──────┐
│ Service probe │  │ Upstream     │  │ Peer probes   │
│ timer         │  │ timers       │  │ timers         │
└───────────────┘  └──────────────┘  └───────────────┘
         ▲ read (all workers)
         │
┌────────┴────────────────────────────────────────────────┐
│  /health   → JSON (service + upstreams + peers)          │
│  /ready    → 200 or 503                                  │
│  /healthz  → 200                                         │
│  /metrics  → Prometheus text                             │
└─────────────────────────────────────────────────────────┘
```

### Behavior Notes

- Passive `requests`, `failed`, and `success_rate` counters exclude the health endpoints themselves.
- Active probe results are shared across workers, but only worker `0` performs the periodic probe loops.
- Liveness and readiness are intentionally different. Nginx can be alive while readiness is failing.
- Fail/pass thresholds are there to avoid flapping under a noisy backend.
- Service-level readiness currently follows the service-level `health_probe`; upstream and peer probe failures are reported, but do not yet change `/ready` by themselves.
- Upstream peer selection can consume probe state through `upstream-balancer`, which excludes unhealthy peers and peers still inside slow-start recovery.
- Slow-start metadata is not a general-purpose traffic shaper; it is currently used only by the balancer-side peer-eligibility check.

### Phases

- **Phase 1** ✅ Shared counters, readiness/liveness, active HTTP probe, thresholds, per-upstream probes, nginx variables
- **Phase 2** Partial: per-upstream probes, `upstreams_summary`, per-peer probe reporting, match rules. Remaining: balancer-facing peer health contract
- **Phase 3** Mostly complete: HTTPS/TLS probing, body/status match rules, slow-start recovery, Prometheus metrics, worker-events transition fanout, and balancer-facing peer eligibility are implemented. Remaining: direct nginx peer marking and any future readiness-policy expansion.

#### Phase 1 - shared health and readiness

This is the original foundation of the module:

- shared-memory passive request/failure counters
- shared liveness/readiness endpoints
- active probe loop with fail/pass thresholds
- one consistent readiness answer across workers

This phase is complete and real, not scaffold-only.

#### Phase 2 - upstream-keyed health visibility

This phase expands the module from one service-level readiness view into upstream-aware visibility:

- per-upstream probe definitions
- per-upstream reporting instead of one shared probe only
- `upstreams_summary`
- per-peer probe reporting
- richer match rules for status/body expectations

Most of the reporting side of this phase is implemented. The part that is still open is the contract that lets this health data affect upstream behavior through `upstream-balancer`.

#### Phase 3 - operational depth and integration

This phase adds recovery depth and operator-facing polish:

- HTTPS/TLS probing
- body/status match rules
- slow-start recovery metadata
- Prometheus-format metrics
- transition fanout through `worker-events`
- health-aware upstream control through `upstream-balancer`

The probing/visibility parts of this phase are largely implemented. The routing/control parts are still pending because they depend on other milestone-2 modules.

### Limitations

- **No direct peer marking yet**: probe failures are observable and can exclude peers through `upstream-balancer`, but the module does not mark nginx upstream peers `down` directly.
- **Readiness remains service-level**: upstream and peer probe failures do not automatically flip `/ready` unless the service-level probe itself fails.
- **Best-effort timeout scope**: probe timeout currently covers connect/send/receive at the socket layer used by the module, not a richer nginx-native async probe engine.
- **Reload/restart reset**: shared-memory probe state resets when zones are recreated.
