## Upstream Balancer Module

Planned upstream balancer and sticky-session foundation for nginx peer selection in Zig.

### Status

**Planning / scaffolded** - module directory, exported Zig module, package wiring, and placeholder directive surface exist. Runtime peer selection is not implemented yet.

### Scope

This module is the planned foundation for commercial-grade upstream control that stays in native Zig rather than per-request scripting. The target is to own the high-risk upstream peer lifecycle in a small, auditable codebase before layering dynamic upstream reconfiguration on top.

### Planned Directives

| Directive | Planned Syntax | Planned Context | Purpose |
|---|---|---|---|
| `upstream_balancer_sticky_cookie` | `<cookie_name>` | `upstream` | Enable cookie-based affinity against the upstream peer table |
| `upstream_balancer_sticky_header` | `<header_name>` | `upstream` | Enable header-based affinity for controlled clients or internal routing |
| `upstream_balancer_fallback` | `<next|off>` | `upstream` | Define whether the balancer may fall back to stock peer selection when affinity misses |

### Detailed Design

#### Phase 1 - peer-selection foundation

- Wrap nginx upstream peer selection callbacks safely in Zig
- Introduce a minimal shared-memory peer metadata model
- Preserve stock-nginx behavior until a sticky policy is explicitly configured

#### Phase 2 - sticky policies

- Cookie affinity
- Header affinity
- Deterministic fallback rules

#### Phase 3 - policy depth

- Weighted peer policy integration
- Better observability around affinity hits/misses
- Clean dependency handoff for the dynamic upstreams module

### Example Target Shape

```nginx
http {
    upstream backend {
        upstream_balancer_sticky_cookie route;
        upstream_balancer_fallback next;

        server 10.0.0.11:8080;
        server 10.0.0.12:8080;
    }
}
```

### Current Scaffold Behavior

- The scaffold only reserves directive names and build/package/module wiring.
- No sticky policy, peer override, or runtime metadata is active yet.
- Until implementation lands, this module should be treated as design scaffolding rather than an operational feature.

### Risks / Implementation Notes

- Upstream peer lifecycle and refcount correctness are the core risk surface.
- This module should stay narrowly focused on peer selection and affinity state.
- Dynamic upstream mutation is intentionally split into a follow-on module.

### Documentation Audit Checklist

- [x] Audit date: 2026-05-03
- [x] Scaffolded Zig module and README exist under `src/modules/upstream-balancer-nginx-module/`.
- [x] Build, package, and module-registration wiring are planned alongside this scaffold.
- [ ] Integration coverage is not added yet.
