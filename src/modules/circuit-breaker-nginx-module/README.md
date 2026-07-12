## Circuit Breaker Module

Circuit breaker pattern implementation for nginx to protect backends from cascading failures.

### Status

**Implemented** - Basic functionality complete with shared-memory circuit state

### Features

- **Three States**: Closed (normal), Open (fail-fast), Half-Open (testing)
- **Configurable Thresholds**: Failure count before opening, successes before closing
- **Timeout Recovery**: Automatic transition to half-open after timeout
- **5xx Detection**: Counts 5xx responses as failures
- **State Variable**: Circuit state exposed via `$ngz_circuit_state`
- **Shared Memory State**: Open, closed, and half-open transitions are coordinated across workers

### Directives

#### circuit_breaker_threshold

*syntax:* `circuit_breaker_threshold <failures>;`
*default:* `5`
*context:* `location`

Enable circuit breaker and set the number of failures before opening the circuit.

#### circuit_breaker_timeout

*syntax:* `circuit_breaker_timeout <time>;`
*default:* `30s`
*context:* `location`

Time before transitioning from open to half-open state. Accepts seconds with 's' suffix or raw milliseconds.

#### circuit_breaker_success_threshold

*syntax:* `circuit_breaker_success_threshold <successes>;`
*default:* `2`
*context:* `location`

Number of successes in half-open state before closing the circuit.

### Usage

```nginx
upstream backend {
    server 10.0.0.1:8080;
    server 10.0.0.2:8080;
}

server {
    listen 8080;

    location /api {
        circuit_breaker_threshold 5;
        circuit_breaker_timeout 30s;
        circuit_breaker_success_threshold 2;

        proxy_pass http://backend;
    }

    # Expose circuit state for monitoring
    location /circuit-status {
        circuit_breaker_threshold 5;
        add_header X-Circuit-State $ngz_circuit_state;
        return 200 "state: $ngz_circuit_state\n";
    }
}
```

### Circuit States

```
     failures >= threshold
  ┌─────────────────────────┐
  │                         ▼
┌─┴────┐  timeout    ┌──────────┐
│CLOSED│◄────────────│   OPEN   │
└──────┘             └────┬─────┘
  ▲                       │
  │  successes >=         │ timeout
  │  threshold            ▼
  │               ┌───────────┐
  └───────────────│ HALF-OPEN │
       success    └───────────┘
```

### Behavior

1. **Closed State**: Normal operation. Requests pass through. Consecutive failures are counted.
2. **Open State**: Returns 503 immediately without forwarding to upstream. Transitions to half-open after timeout.
3. **Half-Open State**: Allows requests through for testing. Success closes circuit, failure re-opens it.

### Limitations

- **Location-Based**: Each location has its own circuit state
- **5xx Only**: Only 5xx status codes are counted as failures
- **Reload/Restart Reset**: Circuit state is stored in nginx shared memory and resets when the shared zone is recreated

### Future Enhancements

- **Per-Upstream Circuits**: Independent circuit per upstream server
- **Custom Failure Criteria**: Configure which status codes count as failures
- **Metrics Export**: Prometheus-compatible metrics

### References

- [Circuit Breaker Pattern](https://martinfowler.com/bliki/CircuitBreaker.html)
- [Netflix Hystrix](https://github.com/Netflix/Hystrix)

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/circuit-breaker/`.
- [x] Bun integration coverage now verifies closed-state failure streak reset, non-5xx responses not tripping the circuit, raw-millisecond timeout parsing, and open-state reporting via `$ngz_circuit_state`.
- [x] Circuit state is now stored in an nginx shared-memory zone keyed by configured location identity instead of per-worker globals.
- [x] Bun integration coverage now runs with `worker_processes 2` and verifies that an open circuit is enforced across workers.
- [x] No additional documentation gaps were identified in this audit pass.

### Engineering Audit Verdict (2026-07-12)

**Verdict: S0 FIXED; S1 RECOVERY CONTROL OPEN.** Capacity exhaustion now returns no entry instead of aliasing entry zero, and protected requests fail closed with 503 when circuit state cannot be allocated. A 64+1 unit regression proves the first circuit remains unchanged, while the focused 16-case integration suite remains green. S1 follow-ups are saturation telemetry/configurable capacity, strict malformed directive rejection, and a bounded number of half-open probes to prevent a recovery stampede.
