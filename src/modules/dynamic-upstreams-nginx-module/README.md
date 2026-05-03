## Dynamic Upstreams Module

Planned runtime upstream reconfiguration module for updating peer tables without a full nginx reload.

### Status

**Planning / scaffolded** - module wiring and placeholder API surface exist. Runtime peer-table mutation is not implemented yet.

### Scope

This module is the planned follow-on to the upstream balancer foundation. Its job is to update upstream membership safely once peer lifecycle and selection hooks are under native Zig control.

### Planned Directives

| Directive | Planned Syntax | Planned Context | Purpose |
|---|---|---|---|
| `dynamic_upstreams_api` | `;` | `location` | Expose the control endpoint for read/write upstream operations |
| `dynamic_upstreams_source` | `<consul|static>` | `location` | Select the reconciliation source for the endpoint |
| `dynamic_upstreams_target` | `<upstream_name>` | `location` | Bind the endpoint to an upstream group |
| `dynamic_upstreams_refresh` | `<milliseconds>` | `location` | Configure background reconciliation cadence |

### Detailed Design

#### Phase 1 - control surface scaffold

- API endpoint shape for listing and mutating upstream members
- Config model for binding a control endpoint to a named upstream
- Deliberate dependency on the upstream balancer module's peer metadata foundation

#### Phase 2 - safe peer-table updates

- Atomic replacement of active peer snapshots
- Explicit generation/version tracking in shared memory
- Consul-backed reconciliation path for service discovery-driven updates

#### Phase 3 - operational depth

- Validation and audit responses
- Safer removal/drain semantics
- Better introspection for active and pending peer views

### Example Target Shape

```nginx
http {
    upstream api_backend {
        server 10.0.0.11:8080;
        server 10.0.0.12:8080;
    }

    server {
        location /api/upstreams {
            dynamic_upstreams_api;
            dynamic_upstreams_target api_backend;
            dynamic_upstreams_source consul;
            dynamic_upstreams_refresh 5000;
        }
    }
}
```

### Current Scaffold Behavior

- `dynamic_upstreams_api` installs a placeholder JSON endpoint that returns HTTP `501`.
- The additional directives only reserve configuration names and store stub values for future implementation.
- No peer-table updates, discovery integration, or background reconciliation are active yet.

### Dependencies

- Upstream balancer / sticky foundation
- Shared peer metadata contract
- Healthcheck peer-state integration for future drain / unhealthy handling

### Documentation Audit Checklist

- [x] Audit date: 2026-05-03
- [x] Scaffolded Zig module and README exist under `src/modules/dynamic-upstreams-nginx-module/`.
- [x] Placeholder API endpoint is intentionally explicit about `501 Not Implemented` state.
- [ ] Integration coverage is not added yet.
