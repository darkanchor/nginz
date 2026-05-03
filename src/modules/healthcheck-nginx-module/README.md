## Health Check Module

Passive/self-health endpoints for nginx with shared-memory aggregation and active HTTP checks, with the next scope focused on upstream peer-state integration.

### Status

**Feature Ready (bounded scope)** - shared-memory request counters, shared readiness state, and active HTTP probing are implemented. The next planned scope is upstream-keyed health state, peer marking, and recovery/slow-start behavior.

### Features

- **Shared-memory counters**: passive request and failure counts aggregate across nginx workers
- **Shared readiness state**: `/ready` and `/health` read the same probe result from shared memory
- **Active HTTP probing**: one worker periodically probes a configured `http://host:port/path` target and shares the result across workers
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

Configure the active probe target. The current implementation supports plain HTTP targets only and still applies one shared probe definition rather than upstream-keyed probe sets.

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
- The current active-check implementation is intentionally scoped to readiness/state reporting rather than direct upstream peer control.

### Limitations

- **Shared probe scope**: active checks exist today, but the current configuration is still shared by the module instead of keyed per upstream peer set.
- **HTTP only**: no HTTPS/TLS probing yet.
- **No upstream peer marking**: probe failures affect module readiness endpoints only; upstream peers are not marked down in nginx.
- **Best-effort timeout scope**: the configured probe timeout covers socket send/receive timeouts; full nonblocking connect/poll logic is not implemented.
- **Reload/restart reset**: shared-memory state resets when the shared zone is recreated.

### Planned Phases

#### Phase 1 - current implemented scope

- Shared-memory passive request/failure counters
- Shared readiness/liveness endpoints
- Active HTTP probe loop with fail/pass thresholds

#### Phase 2 - upstream integration

- Upstream-keyed probe definitions
- Peer marking so unhealthy probes can influence upstream selection
- Better per-upstream visibility rather than one shared probe state

#### Phase 3 - recovery behavior

- Slow-start / recovery ramp semantics
- Richer match rules (headers/body/status policy)
- HTTPS/TLS probing and expanded protocol coverage

### Future Enhancements

- Export probe metrics through the prometheus module
- Event-bus integration for health-state fanout
- Better operator introspection for peer transitions

### Documentation Audit Checklist

- [x] Audit date: 2026-05-03
- [x] Bun integration coverage exists at `tests/healthcheck/`.
- [x] README now reflects that active checks are already implemented and that the missing roadmap work is upstream integration rather than probe existence.
- [x] Variable integration coverage now verifies readiness/liveness/backend probe variables in both healthy and unhealthy shared-state paths.
- [x] Remaining limitations are documented without claiming unsupported upstream marking or per-target feature matrices.

The `healthcheck` module is different from the previous ones because it is not just a scaffold. It already works in a limited but real way.

In plain words, this module gives nginx a way to answer two questions:

- “Am I alive?”
- “Am I ready to serve traffic?”

It does that with two kinds of signals. First, it keeps shared counters across workers for normal request traffic and failures. Second, it can actively probe a configured HTTP target on a timer, then share that result with every worker.

The design is deliberately simple right now. One worker runs the periodic probe loop. The result of that probe is written into shared memory. Then `/health`, `/healthz`, and `/ready` all read the same shared state. That means all workers answer consistently instead of each worker inventing its own view.

The current behavior in [README.md](), [ngx_http_healthcheck.zig](), and [healthcheck.test.js]() is:

- `health_status` exposes a JSON health endpoint
- `health_liveness` exposes a simple “process is alive” endpoint
- `health_readiness` exposes a readiness endpoint
- `health_probe` configures an active HTTP probe target
- interval, timeout, fail threshold, and pass threshold control probe behavior

So the module is doing two jobs:

1. Passive health reporting  
It counts requests and failures across workers.

2. Active readiness checking  
It periodically probes a backend-like target and flips readiness healthy/unhealthy based on consecutive pass/fail thresholds.

That threshold design matters. It avoids flapping. One failed probe does not instantly mark the system unhealthy unless configured that way. Likewise recovery can require multiple successful probes before traffic is considered safe again.

The biggest design limitation is also the main next step: the probe state is currently shared at the module level, not keyed per upstream peer. So it can say “the configured probe target is healthy” but it does not yet integrate directly with nginx upstream peer selection.

That leads to the main technical challenges:

1. Shared state across workers  
The module needs one consistent readiness state for all workers. Shared memory solves that, but you have to get synchronization and lifecycle right.

2. Single-writer probe loop  
Only one worker should run the active probe timer, otherwise you get duplicate probes and conflicting state updates.

3. Avoiding false health signals  
Liveness and readiness are different. The module gets that right: nginx can be alive while readiness is failing.

4. Flap control  
Fail/pass thresholds are there to avoid noisy state transitions. Without them, a shaky backend would make readiness unstable.

5. Upstream integration is still missing  
This is the real unfinished part. Today the module reports health. It does not yet mark upstream peers down or influence load balancing directly.

6. Probe scope is too broad  
Right now there is effectively one shared probe definition, not a full per-upstream or per-peer health model. That is fine for service readiness, but not enough for a serious upstream health system.

7. Probe implementation limits  
The README is honest here: HTTP only, no TLS probing yet, and timeout handling is still fairly basic.

So in plain terms, the module already works as a shared readiness/liveness system for nginx itself, with active probing and counters. What it is not yet is a full upstream health manager.

A useful mental model is:

- today: “is this nginx instance ready?”
- later: “which upstream peers are healthy, and should the balancer avoid the bad ones?”

That second step is the hard one. It requires the health state to become peer-aware and to integrate cleanly with the upstream-balancer logic instead of just exposing `/ready` and `/health`.
