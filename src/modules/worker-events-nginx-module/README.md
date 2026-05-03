## Worker Events Module

Planned cross-worker event bus primitive for nginz-native and njs-integrated coordination.

### Status

**Planning / scaffolded** - module wiring and placeholder API surface exist. Cross-worker event delivery is not implemented yet.

### Scope

This module is intended to provide the native primitive for cross-worker signaling so higher-level policy, cache invalidation, revocation, and orchestration flows do not depend on polling.

### Planned Directives

| Directive | Planned Syntax | Planned Context | Purpose |
|---|---|---|---|
| `worker_events_api` | `;` | `location` | Expose an operational endpoint for inspecting or publishing events |
| `worker_events_zone` | `<name>` | `location` | Select the shared-memory zone used for the event ring |
| `worker_events_channel` | `<channel>` | `location` | Bind the endpoint to a named logical event channel |
| `worker_events_ring_size` | `<entries>` | `location` | Configure the planned ring-buffer capacity |

### Detailed Design

#### Phase 1 - shared primitive scaffold

- Reserve configuration surface and operational endpoint shape
- Define the event bus as a native primitive rather than an njs-only pattern
- Keep the first implementation deliberately narrow: append-only signaling and best-effort fanout

#### Phase 2 - event delivery

- Shared-memory ring with generation tracking
- Worker wake-up / polling integration suitable for njs subscriptions
- Named channels for cache invalidation, revocation, and config-change events

#### Phase 3 - developer surface

- njs subscription conventions
- Safer publish authorization patterns
- Operational introspection and dropped-event accounting

### Example Target Shape

```nginx
server {
    location /internal/worker-events {
        worker_events_api;
        worker_events_zone bus;
        worker_events_channel cache.invalidate;
        worker_events_ring_size 1024;
    }
}
```

### Current Scaffold Behavior

- `worker_events_api` installs a placeholder JSON endpoint that returns HTTP `501`.
- Remaining directives reserve configuration names and store stub values for the future event-bus implementation.
- No shared-memory ring, publish path, or subscription integration is active yet.

### Planned Consumers

- njs policy shells
- cache invalidation fanout
- session or token revocation propagation
- dynamic upstream / health state notifications

### Documentation Audit Checklist

- [x] Audit date: 2026-05-03
- [x] Scaffolded Zig module and README exist under `src/modules/worker-events-nginx-module/`.
- [x] Placeholder API endpoint makes non-implemented state explicit.
- [ ] Integration coverage is not added yet.
