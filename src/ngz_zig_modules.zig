// Single compilation unit for all Zig nginx modules.
// Combining them here means ngx.zig is analysed once instead of 22 times,
// which cuts LLVM's peak memory usage proportionally in release builds.
comptime {
    _ = @import("modules/hello-nginx-module/ngx_http_hello.zig");
    _ = @import("modules/echoz-nginx-module/ngx_http_echoz.zig");
    _ = @import("modules/wechatpay-nginx-module/ngx_http_wechatpay.zig");
    _ = @import("modules/pgrest-nginx-module/ngx_http_pgrest.zig");
    _ = @import("modules/redis-nginx-module/ngx_http_redis.zig");
    _ = @import("modules/consul-nginx-module/ngx_http_consul.zig");
    _ = @import("modules/upstream-balancer-nginx-module/ngx_http_upstream_balancer.zig");
    _ = @import("modules/dynamic-upstreams-nginx-module/ngx_http_dynamic_upstreams.zig");
    _ = @import("modules/jwt-nginx-module/ngx_http_jwt.zig");
    _ = @import("modules/oidc-nginx-module/ngx_http_oidc.zig");
    _ = @import("modules/waf-nginx-module/ngx_http_waf.zig");
    _ = @import("modules/acme-nginx-module/ngx_http_acme.zig");
    _ = @import("modules/jsonschema-nginx-module/ngx_http_jsonschema.zig");
    _ = @import("modules/healthcheck-nginx-module/ngx_http_healthcheck.zig");
    _ = @import("modules/canary-nginx-module/ngx_http_canary.zig");
    _ = @import("modules/ratelimit-nginx-module/ngx_http_ratelimit.zig");
    _ = @import("modules/requestid-nginx-module/ngx_http_requestid.zig");
    _ = @import("modules/circuit-breaker-nginx-module/ngx_http_circuit_breaker.zig");
    _ = @import("modules/worker-events-nginx-module/ngx_http_worker_events.zig");
    _ = @import("modules/graphql-nginx-module/ngx_http_graphql.zig");
    _ = @import("modules/transform-nginx-module/ngx_http_transform.zig");
    _ = @import("modules/cache-tags-nginx-module/ngx_http_cache_tags.zig");
    _ = @import("modules/cache-purge-nginx-module/ngx_http_cache_purge.zig");
    _ = @import("modules/prometheus-nginx-module/ngx_http_prometheus.zig");
    _ = @import("modules/nftset-nginx-module/ngx_http_nftset.zig");
    _ = @import("modules/mqtt-nginx-module/ngx_stream_mqtt.zig");
}
