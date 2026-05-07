## Nginz

nginz is a `nginx` module writer. It allows one to write nginx modules in `zig`. so far it 
is based on official nginx release 1.30.0 and zig 0.16. nginz is tested with linux only.

A companion project [nginz-njs](https://github.com/kaiwu/nginz-njs), provides Gleam/njs modules
for policy orchestration, JWT claim routing, rate-limit response shaping, session management,
and more — built on top of the native primitives exposed here.

The typical nginz workflow is following: 

```
$ git submodule init
$ git submodule update
$ rm -rf .zig-cache zig-out submodules/nginx/objs # might needed for a fresh build
$ zig build
$ zig build test
$ bun test
```

### Build strategy

The build has three tiers optimised for different goals:

| Command | Use case | Notes |
|---------|----------|-------|
| `zig build` | Development | Debug mode, fastest compile, safety checks on |
| `zig build -Doptimize=ReleaseSmall` | Release | Recommended — safety checks on, compact binary, LLVM-friendly |
| `zig build -Doptimize=ReleaseSafe` | **Avoid** | Safety checks on but full `-O2` — see below |

> [!WARNING]
> **`-Doptimize=ReleaseSafe` will segfault on some developer machines.** The build combines all
> modules into a single LLVM compilation unit, and ReleaseSafe's `-O2` pass over that unit
> exceeds 16 GB peak memory even with `-j1`. `ReleaseSmall` uses `-Os` and compiles successfully;
> it preserves all runtime safety checks and produces a comparably sized binary. Use it instead.

Nginx development requires some system library dependencies, which shall be addressed first.
A Dockerfile is provided as reference so that one can build their own dev image.

### Container Tests

Four modules rely on running containers for some of their integration tests. All container interaction uses `sudo docker`.

**nftset** — Docker-isolated live nftables suite. Provisions temporary tables/sets inside a
disposable container namespace so the host nftables ruleset is never touched.

**acme** — Disposable Dockerized ACME services for the live single-domain HTTP-01 flow:

- `ghcr.io/letsencrypt/pebble:latest`
- `ghcr.io/letsencrypt/pebble-challtestsrv:latest`

**pgrest** — Requires a running PostgreSQL container named `pgrest-nginz-test`. The tests create
and drop a dedicated database on each run, so no manual setup is needed beyond starting the container:

```bash
sudo docker run -d --name pgrest-nginz-test -p 5432:5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:18.1-trixie
```

**redis** — Requires a running Redis container named `redis-nginz-test`. Tests run against a
real Redis instance, flushing all keys before each suite:

```bash
sudo docker run -d --name redis-nginz-test -p 6379:6379 redis:8.6.2-trixie
```

> [!NOTE]
> The SSL zig bindings are generated with `OpenSSL 3`.

> [!CAUTION]
> Many nginx structs have variable sizes, as they depend on the opt-in features at compile time.
> Options such as `--with-compat`, `--with-http_ssl_module` could drastically affect many structs.
> To ensure binary compatibility, one needs to adjust the zig bindings accordingly. The project
> defaults to the configure options showed below in `main` branch. The `docker` branch configures
> as many features as the official nginx [docker][3] debian release. Note the structs differences
> in the test asserts.
>
> After upgrading the nginx submodule, run `zig build check-layout` (or `zig build check-layout
> -Ddocker=true` for the docker config) to verify C and Zig struct layouts match. Mismatches
> are typically caused by `spare` array sizes in `ngx.zig` not being adjusted when nginx adds
> new conditional fields that consume `NGX_COMPAT_BEGIN` slots.

To ease the development. A `nginz` binary is built as an artifact along with the module objects.
It is a nginx wrapper, and by default built with

`./auto/configure --with-http_ssl_module --with-http_xslt_module --with-debug`

nginz also has built-in `ngx_http_js_module` with quickjs engine.

For the higher-level product and module direction, see [ROADMAP.md](ROADMAP.md) and notes under `docs/`.

A module `echoz` is provided as an example, it is a tribute to @[agentzh][2] and his [echo][1] module. `echoz`
so far is a simplified version of `echo` and it misses some of the directives.

By all means, deploy the module objects with your own binary building toolchains.

## Integrating Modules with Stock Nginx

nginz provides a `package` build step that creates nginx-compatible module packages. Each package
contains the compiled object file and a `config` script for nginx's `./configure --add-module`.

### Building Module Packages

```bash
zig build package
```

This creates `zig-out/modules/` with a directory for each module:

```
zig-out/modules/
  echoz/
    config                      # nginx configure script
    ngx_http_echoz_module.o     # compiled module object
  jwt/
    config
    libcjson.a                  # bundled dependency
    ngx_http_jwt_module.o
  ...
```

### Using with Nginx

```bash
cd /path/to/nginx-source
./configure \
  --with-http_ssl_module \
  --add-module=/path/to/nginz/zig-out/modules/echoz \
  --add-module=/path/to/nginz/zig-out/modules/jwt
make
make install
```

### Important Notes

- **nginx version**: Modules are built against nginx 1.30.0. Using with other versions may cause
  compatibility issues.
- **Filter modules**: Modules containing filters (echoz, wechatpay, oidc, requestid, cache-tags,
  transform) have ordering dependencies. Their position relative to nginx's built-in filters is
  determined by `--add-module` order.
- **Dependencies**: Some modules require system libraries (e.g., pgrest needs `-lpq`). The config
  script handles this automatically.

## Module Status

26 modules total, including 2 reference/demo modules. All non-reference modules have integration tests and individual README documentation.

### Feature Ready (23)

| Module | Description |
|--------|-------------|
| **echoz** | Echo/response module with variable interpolation and filters |
| **jwt** | JWT validation (HS256), claims extraction |
| **jsonschema** | JSON Schema request/response validation |
| **graphql** | Query depth limiting, introspection control |
| **transform** | JSON path extraction and transformation |
| **waf** | SQL injection and XSS pattern detection |
| **canary** | Traffic splitting (percentage, header, cookie routing) |
| **consul** | Service discovery and KV store integration |
| **redis** | Redis commands via RESP protocol |
| **requestid** | UUID4 generation and X-Request-ID propagation |
| **ratelimit** | Fixed window rate limiting per IP |
| **circuit-breaker** | Failure detection with half-open recovery |
| **prometheus** | Native /metrics endpoint with histograms |
| **cache-tags** | Tag-based cache invalidation |
| **cache-purge** | Operator-facing exact/prefix tag invalidation API backed by `cache-tags`, with IP/CIDR allowlist auth, multi-worker mutation, and optional worker-events fanout |
| **acme** | Let's Encrypt certificate automation for single-domain HTTP-01 issuance with live Pebble/challtestsrv validation |
| **nftset** | nftables-backed IP allow/block checks via raw Netlink lookup |
| **oidc** | OpenID Connect SSO with PKCE and RS256 ID token verification |
| **pgrest** | PostgreSQL REST API with JWT auth, content negotiation (JSON/CSV/XML) |
| **healthcheck** | Health/readiness endpoints with shared-memory state, active probes, slow-start tracking, worker-events transition fanout, and balancer-facing peer eligibility |
| **dynamic-upstreams** | Live upstream snapshot replacement with GET/PUT control API, static-file polling, worker-events activation fanout, health-aware activation, and Consul-backed reconciliation with last-good preservation on refresh failure |
| **upstream-balancer** | Sticky upstream peer selection with cookie/header affinity, fallback control, cookie issuance, health-aware eligibility, and runtime peer-source handoff for dynamic snapshots |
| **wechatpay** | WeChat Pay signature signing and verification |
| **worker-events** | Cross-worker shared-memory event ring with publish/inspect API, overflow accounting, publish auth, and real native consumers in healthcheck, cache-purge, and dynamic-upstreams |

### Implemented with Limitations (0)

None currently.

### Planning (0)

None currently.

### Reference (2)

| Module | Description |
|--------|-------------|
| **hello** | Minimal module example |
| **njs** | QuickJS scripting engine (built-in); integration demos for njs+Redis+PGrest orchestration |

[1]: https://github.com/openresty/echo-nginx-module "echo"
[2]: https://github.com/agentzh "agentzh"
[3]: https://github.com/nginxinc/docker-nginx/blob/master/stable/debian/Dockerfile "docker"
