## Health Check Module

Passive/self-health endpoints for nginx with shared-memory aggregation and a minimal active HTTP probe.

### Status

**Feature Ready (bounded scope)** - shared-memory request counters, shared readiness state, and a single module-global active HTTP probe are implemented.

### Features

- **Shared-memory counters**: passive request and failure counts aggregate across nginx workers
- **Shared readiness state**: `/ready` and `/health` read the same probe result from shared memory
- **Active HTTP probing**: one worker periodically probes a configured `http://host:port/path` target
- **Threshold-based health transitions**: configurable consecutive fail/pass thresholds drive readiness
- **JSON endpoints**: `/health`, `/healthz`, and `/ready` return machine-readable responses

### Directives

#### health_status

*syntax:* `health_status;`
*context:* `location`

Enable the JSON health endpoint for this location.

#### health_liveness

*syntax:* `health_liveness;`
*context:* `location`

Enable a simple liveness endpoint. It returns `200` as long as nginx is serving requests.

#### health_readiness

*syntax:* `health_readiness;`
*context:* `location`

Enable a readiness endpoint. When active probing is configured, readiness follows the shared probe state; otherwise it stays ready.

#### health_probe

*syntax:* `health_probe http://host:port/path;`
*context:* `location`

Configure the module-global active probe target. The current implementation supports plain HTTP targets only.

#### health_probe_interval

*syntax:* `health_probe_interval <time>;`
*default:* `5000ms`
*context:* `location`

Interval between active probes. Accepts raw milliseconds, `Nms`, or `Ns`.

#### health_probe_timeout

*syntax:* `health_probe_timeout <time>;`
*default:* `1000ms`
*context:* `location`

Socket send/receive timeout used by active probes. Accepts raw milliseconds, `Nms`, or `Ns`.

#### health_probe_fails

*syntax:* `health_probe_fails <count>;`
*default:* `2`
*context:* `location`

Number of consecutive failed probes required to mark readiness unhealthy.

#### health_probe_passes

*syntax:* `health_probe_passes <count>;`
*default:* `1`
*context:* `location`

Number of consecutive successful probes required to recover readiness.

### Usage

```nginx
http {
    server {
        listen 8080;

        location /health {
            health_status;
            health_probe http://127.0.0.1:9001/probe;
            health_probe_interval 1s;
            health_probe_timeout 250ms;
            health_probe_fails 2;
            health_probe_passes 2;
        }

        location /healthz {
            health_liveness;
        }

        location /ready {
            health_readiness;
        }

        location / {
            proxy_pass http://backend;
        }
    }
}
```

### Response Examples

**healthy `/health`:**
```json
{
  "status": "healthy",
  "healthy": true,
  "ready": true,
  "requests": 123,
  "failed": 4,
  "success_rate": 96,
  "probe_enabled": true,
  "probe_healthy": true,
  "probe_last_status": 200,
  "probe_total_successes": 8,
  "probe_total_failures": 1,
  "probe_consecutive_successes": 2,
  "probe_consecutive_failures": 0
}
```

**unhealthy `/ready`:**
```json
{"status":"not_ready"}
```

### Nginx Variables

These variables are available in any nginx context after the module is loaded.

| Variable | Value | Description |
|---|---|---|
| `$health_readiness` | `1` / `0` | `1` if the instance is ready (probe healthy or no probe configured), `0` otherwise |
| `$health_liveness` | `1` | Always `1` while nginx is alive |
| `$health_backend_healthy_count` | `1` / `0` | `1` if the active probe target is currently healthy, `0` otherwise |
| `$health_backend_total_count` | `1` / `0` | `1` if an active probe target is configured, `0` if probe is disabled |
| `$health_backend_failure_count` | decimal | Current consecutive probe failure count |

These variables let `nginz-njs` scripted modules compose health-aware routing and gating decisions without a subrequest round-trip.

### Behavior Notes

- Passive `requests`, `failed`, and `success_rate` counters exclude the health endpoints themselves.
- Active probe results are shared across workers, but only one worker performs the periodic probe loop.
- Probe success currently means an HTTP status in the `2xx` or `3xx` range.

### Limitations

- **Single module-global probe target**: the active probe configuration is shared by the module, not keyed per location/upstream.
- **HTTP only**: no HTTPS/TLS probing yet.
- **No upstream peer marking**: probe failures affect module readiness endpoints only; upstream peers are not marked down in nginx.
- **Best-effort timeout scope**: the configured probe timeout covers socket send/receive timeouts; full nonblocking connect/poll logic is not implemented.
- **Reload/restart reset**: shared-memory state resets when the shared zone is recreated.

### Future Enhancements

- HTTPS probe support
- Multiple keyed probe definitions
- Richer match rules (headers/body)
- Export probe metrics through the prometheus module

### Documentation Audit Checklist

- [x] Audit date: 2026-04-24
- [x] Bun integration coverage exists at `tests/healthcheck/`.
- [x] README now matches the implemented shared-memory passive counters, shared readiness state, and module-global active HTTP probe behavior.
- [x] Remaining limitations are documented without claiming unsupported upstream marking or per-target feature matrices.
