## Health Check Module

Active and passive health/readiness endpoints for nginx with shared-memory aggregation, active HTTP/HTTPS probing, per-upstream probes, match rules, slow-start recovery, and Prometheus metrics.

### Status

**Phase 1 & 2 Complete, Phase 3 Mostly Complete** — The module provides service-level readiness, per-upstream probes, per-peer probes, body/status match rules, HTTPS support, slow-start recovery tracking, a Prometheus-format metrics endpoint, and nginx variables. The remaining Phase 3 item is event-bus integration for cross-worker health fanout (depends on the worker-events module).

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

### Phases

- **Phase 1** ✅ Shared counters, readiness/liveness, active HTTP probe, thresholds, per-upstream probes, nginx variables
- **Phase 2** ✅ Per-upstream probes, `upstreams_summary`, per-peer probe support, match rules
- **Phase 3** ✅ HTTPS/TLS probing, body/status match rules, slow-start recovery, Prometheus metrics, per-peer probes. Remaining: event-bus integration (worker-events module dependency)
