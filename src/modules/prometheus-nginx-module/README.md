## Prometheus Metrics Module

Native Prometheus metrics exporter for nginx.

### Status

**Implemented** - Core functionality complete with histograms and shared-memory cross-worker aggregation

### Features

- **Request Counters**: Total requests, requests by status code class (1xx-5xx)
- **Latency Histogram**: Request duration with standard buckets (5ms to 10s)
- **Metrics Endpoint**: Exposes `/metrics` in Prometheus exposition format
- **Self-Exclusion**: Metrics endpoint requests are not counted
- **Shared Memory Aggregation**: Counters and histograms are aggregated across nginx workers

### Metrics Exposed

```
# HELP nginx_up Whether nginx is up
# TYPE nginx_up gauge
nginx_up 1

# HELP nginx_http_requests_total Total number of HTTP requests
# TYPE nginx_http_requests_total counter
nginx_http_requests_total 12345

# HELP nginx_http_requests_by_status HTTP requests by status code class
# TYPE nginx_http_requests_by_status counter
nginx_http_requests_by_status{status="1xx"} 0
nginx_http_requests_by_status{status="2xx"} 10000
nginx_http_requests_by_status{status="3xx"} 500
nginx_http_requests_by_status{status="4xx"} 800
nginx_http_requests_by_status{status="5xx"} 45

# HELP nginx_http_request_duration_seconds Request duration in seconds
# TYPE nginx_http_request_duration_seconds histogram
nginx_http_request_duration_seconds_bucket{le="0.005"} 5000
nginx_http_request_duration_seconds_bucket{le="0.01"} 7500
nginx_http_request_duration_seconds_bucket{le="0.025"} 9000
nginx_http_request_duration_seconds_bucket{le="0.05"} 10500
nginx_http_request_duration_seconds_bucket{le="0.1"} 11200
nginx_http_request_duration_seconds_bucket{le="0.25"} 11800
nginx_http_request_duration_seconds_bucket{le="0.5"} 12100
nginx_http_request_duration_seconds_bucket{le="1"} 12300
nginx_http_request_duration_seconds_bucket{le="2.5"} 12340
nginx_http_request_duration_seconds_bucket{le="5"} 12344
nginx_http_request_duration_seconds_bucket{le="10"} 12345
nginx_http_request_duration_seconds_bucket{le="+Inf"} 12345
nginx_http_request_duration_seconds_sum 125.432
nginx_http_request_duration_seconds_count 12345
```

### Directives

#### prometheus_metrics

*syntax:* `prometheus_metrics;`
*context:* `location`

Expose the `/metrics` endpoint at this location. Returns metrics in Prometheus text exposition format.

### Usage

```nginx
http {
    server {
        listen 8080;

        # Your application endpoints
        location / {
            proxy_pass http://backend;
        }

        # Prometheus metrics endpoint
        location /metrics {
            prometheus_metrics;

            # Optional: restrict access to monitoring systems
            allow 10.0.0.0/8;
            allow 127.0.0.1;
            deny all;
        }
    }
}
```

### Prometheus Configuration

Add to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'nginx'
    static_configs:
      - targets: ['nginx-server:8080']
    metrics_path: '/metrics'
```

### Nginx Variables

These variables expose low-cost shared-memory Prometheus state to `nginz-njs` or config-level policy without scraping `/metrics`.

| Variable | Values | Scripted consumers |
|---|---|---|
| `$prometheus_requests_total` | decimal | `metrics`, `workflow` — load-aware routing and response shaping |
| `$prometheus_error_rate` | decimal (0.0–1.0) | `circuit_breaker_policy`, `security_gateway` — degraded-mode or challenge policy |

- `$prometheus_requests_total` is the current shared request counter excluding `/metrics` self-scrapes.
- `$prometheus_error_rate` is `(4xx + 5xx) / total_requests`, formatted to three decimal places. It returns `0.000` when no requests have been counted yet.

These variables read from the same shared-memory counters already maintained by the module, with no extra network or parsing cost.

### Limitations

Current implementation has these limitations:

- **Reload/Restart Reset**: Metrics live in nginx shared memory and still reset when the shared zone is recreated on full restart

### Future Enhancements

- **Connection Metrics**: Active connections, accepted, handled
- **Variable Surface Expansion**: add `$prometheus_active_connections` once the module has real connection-lifecycle bookkeeping rather than scrape-only counters
- **Upstream Metrics**: Upstream response times, failures
- **Custom Labels**: Add labels from nginx variables
- **Configurable Buckets**: Custom histogram bucket boundaries

### References

- [Prometheus Exposition Format](https://prometheus.io/docs/instrumenting/exposition_formats/)
- [nginx-prometheus-exporter](https://github.com/nginxinc/nginx-prometheus-exporter)

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/prometheus/`.
- [x] Bun integration coverage now verifies HEAD handling on `/metrics`, self-scrape exclusion for both request totals and histogram counts, cumulative histogram buckets, and `+Inf` matching histogram count.
- [x] Metrics are now stored in an nginx shared-memory zone so `/metrics` aggregates traffic across multiple workers.
- [x] Bun integration coverage now runs with `worker_processes 2` and verifies cross-worker request aggregation.
- [x] Nginx variable coverage now verifies `$prometheus_requests_total` and `$prometheus_error_rate` against live traffic.
- [x] No additional documentation gaps were identified in this audit pass.

### Engineering Audit Verdict (2026-07-12)

**Verdict: PASS WITH S2 PERFORMANCE WORK.** The shared zone is now registered and its global descriptor refreshed every configuration cycle; reads and writes are mutex-protected. The remaining concern is one global slab mutex acquisition in the log path for every request, which becomes a worker-serialization point at high throughput. Prefer atomic counters (with a documented snapshot consistency model), add overflow handling, and state explicitly that the metrics intentionally aggregate every server/location rather than providing tenant isolation.
