## Canary/Traffic Splitting Module

Traffic splitting for canary deployments and A/B testing.

### Status

**Implemented** - Core functionality complete

### Features

- **Percentage-Based Routing**: Route N% of traffic to canary upstream
- **Header-Based Routing**: Route based on specific header values (e.g., X-Canary: true)
- **Priority System**: Header match takes priority over percentage
- **Variable Export**: `$ngz_canary` variable for use in configs and logs

### Directives

#### canary_percentage

*syntax:* `canary_percentage <0-100>;`
*default:* `0`
*context:* `location`

Enable canary routing and set percentage of traffic to route to canary. Uses cryptographically secure random number generation.

#### canary_header

*syntax:* `canary_header <name> <value>;`
*context:* `location`

Enable canary routing and route to canary when request header matches value (case-insensitive). This takes priority over percentage-based routing.

### Variables

#### $ngz_canary

Returns `"1"` if the request should be routed to canary, `"0"` otherwise.

Use with nginx `map` directive for clean upstream selection.

### Usage

```nginx
http {
    # Define upstreams
    upstream stable {
        server 10.0.0.1:8080;
        server 10.0.0.2:8080;
    }

    upstream canary {
        server 10.0.1.1:8080;
    }

    # Map canary decision to backend
    map $ngz_canary $backend {
        "1"     canary;
        default stable;
    }

    server {
        # Percentage-based canary (10% to canary)
        location /api {
            canary_percentage 10;
            proxy_pass http://$backend;
        }

        # Header-based routing (for testers/developers)
        location /api/v2 {
            canary_header X-Canary true;
            proxy_pass http://$backend;
        }

        # Combined: header override + percentage fallback
        location /app {
            canary_percentage 5;
            canary_header X-Beta-Tester yes;
            proxy_pass http://$backend;
        }
    }
}
```

### How It Works

1. **Request arrives** at a location with canary configured
2. **Header check** (if configured): If the specified header matches, route to canary
3. **Percentage check** (if configured): Generate random number, route to canary if below threshold
4. **Variable set**: `$ngz_canary` is set to "1" (canary) or "0" (stable)
5. **Upstream selection**: Use `map` directive to select upstream based on variable

### Use Cases

**Gradual Rollout**
```nginx
canary_percentage 5;   # Start with 5%
# Later increase to 10%, 25%, 50%, 100%
```

**Developer Testing**
```nginx
canary_header X-Canary true;
# Developers add header to test new version
```

**A/B Testing**
```nginx
canary_percentage 50;  # 50/50 split
# Track metrics per version
```

### Future Enhancements

- **Cookie-Based Routing**: Route based on cookie values (sticky sessions)
- **Weighted Upstreams**: Weighted distribution across multiple upstreams
- **Metrics Export**: Track traffic split for monitoring

### References

- [Kubernetes Canary Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#canary-deployment)
- [NGINX Canary Deployments](https://www.nginx.com/blog/dynamic-a-b-testing-with-nginx-plus/)

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/canary/`.
- [x] Bun integration coverage now verifies 0% and 100% percentage boundaries, header-mismatch percentage fallback, and repeated `$ngz_canary` reads staying stable within a single request.
- [x] No additional documentation gaps were identified in this audit pass.

### Engineering Audit Verdict (2026-07-12)

**Verdict: S1 FIXED.** Entropy acquisition is checked and fails predictably to the stable route with an error log. Invalid or out-of-range percentages now fail configuration instead of becoming zero or 100, and explicit `percentage_set` state lets a child `0%` override inherit correctly. The focused 15-case routing suite and a zero-inheritance unit proof are green.
