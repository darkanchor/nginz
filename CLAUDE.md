# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Nginz is a framework for writing nginx modules in Zig. It wraps nginx 1.30.0 and requires Zig 0.16. The project produces a `nginz` binary (nginx wrapper) and individual module object files.

## Skills
- Read from $HOME/.claude/skills
- This project requires zig 0.16, equip yourself with `skills/zig-0.16/SKILL.md`
- Nginx is a subtle piece of software, it might take substantial effort to learn a hard fact when debug its core and native modules, as you learnt, append to an existing skill or create one

## Build Commands

```bash
# Initial setup
git submodule init && git submodule update

# Build everything
zig build

# Run all Zig unit tests
zig build test

# Run integration tests for a specific module
bun test tests/<module-name>/
```

## Architecture

### Directory Structure
- `src/ngx/` - Zig bindings for nginx internals (nginx.zig is the main entry point)
- `src/modules/<name>-nginx-module/` - Individual nginx modules written in Zig
- `src/ngz_modules.zig` - Module registration and load order (critical for phase ordering), especially for filter modules
- `tests/<module>/` - Integration tests with nginx.conf and JS test files

### Module Registration Order

Module order in `ngz_modules.zig` is critical. Access phase modules must be placed together after limit modules:
```zig
// Limit modules
&ngx_http_limit_conn_module,
&ngx_http_limit_req_module,

// Access phase modules (custom) - must be grouped here
&ngx_http_wechatpay_module,
&ngx_http_jsonschema_module,
&ngx_http_ratelimit_module,
...
```

### nginx HTTP Phases

Understanding nginx phases is essential:
1. REWRITE phase - `return` directive runs here
2. ACCESS phase - authentication/authorization handlers
3. CONTENT phase - response generation (`echozn`, `proxy_pass`)

**Critical**: Access phase handlers won't execute if `return` is used in the same location block (return runs in rewrite phase before access). Use `echozn` or `proxy_pass` for content.

### Writing a New Module

Each module needs:
1. `src/modules/<name>-nginx-module/ngx_http_<name>.zig` - Module implementation
2. Entry in `build.zig` modules array
3. Entry in `src/ngz_modules.zig` (both `ngx_modules` array and `ngx_module_names`)
4. `tests/<name>/nginx.conf` and `<name>.test.js` for integration tests
5. No need of feature rich just yet, strive for correctness, simplicity and product proven

Module structure pattern:
```zig
const ngx = @import("ngx");

// Location config struct
const my_loc_conf = extern struct { ... };

// Handlers (use `export fn` for debuggable symbols)
export fn ngx_http_mymodule_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t { ... }

// Config functions
fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque { ... }
fn merge_loc_conf(...) callconv(.c) [*c]u8 { ... }

// Phase registration in postconfiguration
fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    // Register handler in appropriate phase (e.g., NGX_HTTP_ACCESS_PHASE)
}

// Module exports
export const ngx_http_mymodule_module_ctx = ngx_http_module_t{ ... };
export const ngx_http_mymodule_commands = [_]ngx_command_t{ ... };
export var ngx_http_mymodule_module = ngx.module.make_module(...);
```

### Ngx Bindings

Access nginx APIs through the ngx namespace:
- `ngx.core` - Core types (ngx_str_t, ngx_pool_t, NGX_OK/ERROR/DECLINED)
- `ngx.http` - HTTP types and functions
- `ngx.conf` - Configuration parsing
- `ngx.cjson` - JSON parsing via cJSON wrapper
- `ngz_log_error`- Logging

### Reference modules
- `echoz-nginx-module` - content module, header filter module, implement multiple module in the same file
- `wechatpay-nginx-module` - upstream, access module, header filter module, json encode/decode

### ATTENTIONS

- `ngx/ngx.zig` - NEVER use it directly, it is a huge nginx c bindings file which is imported as `ngx` in other wrappers, export and use the needed ones like `ngx_http.zig` or `ngx_core.zig` etc.
- `ngx/nginx.zig` - NEVER modify this file, neither delete nor add anything. It is imported as `ngx` in nginx module implementations, which is confusing as it reuses the same name
- `ngx/cjson.zig` - NEVER use it directly, it is the cjson c bindings file, use its wrapper `ngx.cjson`
- `ngx/pq.zig` - NEVER use it directly, likewise it is the libpq c bindings file, use its wrapper `ngx.pq` 
- `ngz_modules.zig` For a filter module, make sure to position the module in between `ngx_http_userid_filter_module` and `ngx_http_headers_filter_module` of this file
- Each module requires its own `README.md` documenting status, features, directives, usage examples, limitations, and future enhancements (see `prometheus-nginx-module/README.md` for reference)
- Perf notes under `perf/` must do more than record raw numbers. They should assist later perf studies by identifying the likely hot path, separating steady-state cost from control-plane or mutation-heavy cost, calling out the most credible bottlenecks, and using available counters such as instructions, IPC, branch misses, and cache misses when artifacts support those claims.
- Avoid using `buf` as a local variable name in module code — `const buf = ngx.buf;` is a top-level module alias in most modules, and a local `var buf` will shadow it and cause a compilation error
- The nginx main request count can be real tricky, especially in the subrequest situations. When in double, always add logs to assert, do experiments, never take things for granted or blunt guess

### Testing

Integration tests use Bun and run against a live nginx instance:
If used wrong, bun test could introduce false positives by itself, use curl to double confirm
```bash
bun test tests/jsonschema/
```

Test environment variables:
- `KEEP_LOGS=1` - Preserve runtime directory and nginx logs for debugging
- `ZIG_OPTIMIZE=ReleaseSafe` - Build with optimizations (faster tests, ~3x speedup)

```bash
# Debug build with logs preserved
KEEP_LOGS=1 bun test tests/oidc/

# Release build for faster test runs
ZIG_OPTIMIZE=ReleaseSafe bun test

# Both combined
KEEP_LOGS=1 ZIG_OPTIMIZE=ReleaseSafe bun test tests/acme/
```

Test nginx.conf files should use `error_log logs/error.log debug;` for debugging.

If a test nginx config uses custom variables or variable-backed headers/maps, add these in the `http {}` block to avoid the nginx startup warning about suboptimal variable hashing:

```nginx
variables_hash_max_size 2048;
variables_hash_bucket_size 128;
```


### Debugging

For GDB debugging, Zig mangles function names with module prefix:
```gdb
break ngx_http_jsonschema.ngx_http_jsonschema_access_handler
```

Use `nm zig-out/bin/nginz | grep <module>` to find actual symbol names.
