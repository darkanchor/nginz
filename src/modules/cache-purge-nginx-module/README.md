## Cache Purge Module

Planned selective cache-purge API for operational cache invalidation beyond raw PURGE semantics.

### Status

**Planning / scaffolded** - module wiring and placeholder API surface exist. Selective invalidation behavior is not implemented yet.

### Scope

This module is intended to complement `cache-tags` with an explicit operational API for targeted purge flows. The focus is controlled invalidation, better policy surface, and room for future matching strategies without forcing an external Redis dependency.

### Planned Directives

| Directive | Planned Syntax | Planned Context | Purpose |
|---|---|---|---|
| `cache_purge_api` | `;` | `location` | Expose the purge control endpoint |
| `cache_purge_zone` | `<name>` | `location` | Bind the endpoint to a named purge metadata zone |
| `cache_purge_match` | `<exact|prefix|glob>` | `location` | Choose the invalidation matching strategy |
| `cache_purge_authorize` | `<off|allowlist|signed-token>` | `location` | Define the planned authorization mode |
| `cache_purge_max_keys` | `<count>` | `location` | Bound batch invalidation request size |

### Detailed Design

#### Phase 1 - operational endpoint scaffold

- Reserve the control endpoint shape and config surface
- Keep purge API concerns separate from the `cache-tags` response filter
- Make the placeholder explicit so docs and code stay aligned during planning

#### Phase 2 - selective invalidation core

- Shared-memory purge metadata
- Exact and prefix invalidation first
- Clear response model for accepted, rejected, and missing keys

#### Phase 3 - policy depth

- Glob matching if justified
- Better auth / audit integration
- Event-bus fanout for cross-worker or cross-node invalidation workflows

### Example Target Shape

```nginx
server {
    location /internal/cache-purge {
        cache_purge_api;
        cache_purge_zone default;
        cache_purge_match prefix;
        cache_purge_authorize allowlist;
        cache_purge_max_keys 256;
    }
}
```

### Current Scaffold Behavior

- `cache_purge_api` installs a placeholder JSON endpoint that returns HTTP `501`.
- Remaining directives reserve configuration names and store stub values for future implementation.
- No invalidation, wildcard matching, or cache metadata management is active yet.

### Relationship To Existing Modules

- `cache-tags` remains the response/filter-side tagging primitive.
- This module is the planned operator-facing purge/control surface.
- The future worker event bus may become a fanout mechanism, but it is not required for the first useful implementation.

### Documentation Audit Checklist

- [x] Audit date: 2026-05-03
- [x] Scaffolded Zig module and README exist under `src/modules/cache-purge-nginx-module/`.
- [x] Placeholder API endpoint makes the non-implemented state explicit.
- [ ] Integration coverage is not added yet.
