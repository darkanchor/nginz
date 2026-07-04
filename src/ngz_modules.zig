const ngx = @import("ngx/nginx.zig");
const ngx_module_t = ngx.module.ngx_module_t;

// Core Nginx Modules
extern var ngx_core_module: ngx_module_t;
extern var ngx_errlog_module: ngx_module_t;
extern var ngx_conf_module: ngx_module_t;
extern var ngx_openssl_module: ngx_module_t;
extern var ngx_openssl_cache_module: ngx_module_t;
extern var ngx_quic_module: ngx_module_t;
extern var ngx_quic_bpf_module: ngx_module_t;
extern var ngx_regex_module: ngx_module_t;

// Event Modules
extern var ngx_events_module: ngx_module_t;
extern var ngx_event_core_module: ngx_module_t;
extern var ngx_epoll_module: ngx_module_t;

// HTTP Core Modules
extern var ngx_http_module: ngx_module_t;
extern var ngx_http_core_module: ngx_module_t;
extern var ngx_http_log_module: ngx_module_t;
extern var ngx_http_upstream_module: ngx_module_t;
extern var ngx_thread_pool_module: ngx_module_t;

extern var ngx_http_v2_module: ngx_module_t;
extern var ngx_http_v3_module: ngx_module_t;
extern var ngx_http_static_module: ngx_module_t;
extern var ngx_http_autoindex_module: ngx_module_t;
extern var ngx_http_index_module: ngx_module_t;
extern var ngx_http_mirror_module: ngx_module_t;
extern var ngx_http_try_files_module: ngx_module_t;
extern var ngx_http_auth_basic_module: ngx_module_t;
extern var ngx_http_access_module: ngx_module_t;
extern var ngx_http_auth_request_module: ngx_module_t;

// Limit Modules
extern var ngx_http_limit_conn_module: ngx_module_t;
extern var ngx_http_limit_req_module: ngx_module_t;

// Routing & Filtering Modules
extern var ngx_http_geo_module: ngx_module_t;
extern var ngx_http_map_module: ngx_module_t;
extern var ngx_http_split_clients_module: ngx_module_t;
extern var ngx_http_referer_module: ngx_module_t;
extern var ngx_http_rewrite_module: ngx_module_t;

// Security Modules
extern var ngx_http_ssl_module: ngx_module_t;

// Proxy & Backend Modules
extern var ngx_http_proxy_module: ngx_module_t;
extern var ngx_http_fastcgi_module: ngx_module_t;
extern var ngx_http_uwsgi_module: ngx_module_t;
extern var ngx_http_scgi_module: ngx_module_t;
extern var ngx_http_grpc_module: ngx_module_t;
extern var ngx_http_memcached_module: ngx_module_t;

// Misc Modules
extern var ngx_http_empty_gif_module: ngx_module_t;
extern var ngx_http_browser_module: ngx_module_t;

// Upstream Balance Modules
extern var ngx_http_upstream_hash_module: ngx_module_t;
extern var ngx_http_upstream_ip_hash_module: ngx_module_t;
extern var ngx_http_upstream_least_conn_module: ngx_module_t;
extern var ngx_http_upstream_random_module: ngx_module_t;
extern var ngx_http_upstream_keepalive_module: ngx_module_t;
extern var ngx_http_upstream_zone_module: ngx_module_t;

// Filter Modules (first block)
extern var ngx_http_write_filter_module: ngx_module_t;
extern var ngx_http_header_filter_module: ngx_module_t;
extern var ngx_http_chunked_filter_module: ngx_module_t;
extern var ngx_http_v2_filter_module: ngx_module_t;
extern var ngx_http_v3_filter_module: ngx_module_t;
extern var ngx_http_range_header_filter_module: ngx_module_t;
extern var ngx_http_gzip_filter_module: ngx_module_t;
extern var ngx_http_postpone_filter_module: ngx_module_t;
extern var ngx_http_ssi_filter_module: ngx_module_t;
extern var ngx_http_charset_filter_module: ngx_module_t;
extern var ngx_http_xslt_filter_module: ngx_module_t;
extern var ngx_http_userid_filter_module: ngx_module_t;
extern var ngx_http_headers_filter_module: ngx_module_t;

// More Filter Modules
extern var ngx_http_copy_filter_module: ngx_module_t;
extern var ngx_http_range_body_filter_module: ngx_module_t;
extern var ngx_http_not_modified_filter_module: ngx_module_t;
extern var ngx_http_echoz_filter_module: ngx_module_t;
extern var ngx_http_wechatpay_filter_module: ngx_module_t;
extern var ngx_http_oidc_filter_module: ngx_module_t;

// NJS Modules
extern var ngx_http_js_module: ngx_module_t;

// Upstream Store & Processing Modules (our custom modules)
extern var ngx_http_hello_module: ngx_module_t;
extern var ngx_http_echoz_module: ngx_module_t;
extern var ngx_http_wechatpay_module: ngx_module_t;
extern var ngx_http_pgrest_module: ngx_module_t;
extern var ngx_http_redis_module: ngx_module_t;
extern var ngx_http_consul_module: ngx_module_t;
extern var ngx_http_upstream_balancer_module: ngx_module_t;
extern var ngx_http_upstream_balancer_filter_module: ngx_module_t;
extern var ngx_http_dynamic_upstreams_module: ngx_module_t;

// Security & Auth Modules
extern var ngx_http_jwt_module: ngx_module_t;
extern var ngx_http_oidc_module: ngx_module_t;
extern var ngx_http_waf_module: ngx_module_t;
extern var ngx_http_waf_filter_module: ngx_module_t;
extern var ngx_http_acme_module: ngx_module_t;
extern var ngx_http_jsonschema_module: ngx_module_t;

// Traffic Management Modules
extern var ngx_http_healthcheck_module: ngx_module_t;
extern var ngx_http_canary_module: ngx_module_t;
extern var ngx_http_ratelimit_module: ngx_module_t;
extern var ngx_http_requestid_filter_module: ngx_module_t;
extern var ngx_http_circuit_breaker_module: ngx_module_t;
extern var ngx_http_worker_events_module: ngx_module_t;

// Network Security Modules
extern var ngx_http_nftset_module: ngx_module_t;

// Advanced Processing Modules
extern var ngx_http_graphql_module: ngx_module_t;
extern var ngx_http_cache_tags_filter_module: ngx_module_t;
extern var ngx_http_transform_filter_module: ngx_module_t;
extern var ngx_http_cache_purge_module: ngx_module_t;
extern var ngx_http_prometheus_module: ngx_module_t;

// Stream Modules
extern var ngx_stream_module: ngx_module_t;
extern var ngx_stream_core_module: ngx_module_t;
extern var ngx_stream_proxy_module: ngx_module_t;
extern var ngx_stream_upstream_module: ngx_module_t;
extern var ngx_stream_ssl_module: ngx_module_t;
extern var ngx_stream_realip_module: ngx_module_t;
extern var ngx_stream_limit_conn_module: ngx_module_t;
extern var ngx_stream_access_module: ngx_module_t;
extern var ngx_stream_geo_module: ngx_module_t;
extern var ngx_stream_map_module: ngx_module_t;
extern var ngx_stream_split_clients_module: ngx_module_t;
extern var ngx_stream_return_module: ngx_module_t;
extern var ngx_stream_pass_module: ngx_module_t;
extern var ngx_stream_set_module: ngx_module_t;
extern var ngx_stream_upstream_hash_module: ngx_module_t;
extern var ngx_stream_upstream_least_conn_module: ngx_module_t;
extern var ngx_stream_upstream_random_module: ngx_module_t;
extern var ngx_stream_upstream_zone_module: ngx_module_t;
extern var ngx_stream_ssl_preread_module: ngx_module_t;
extern var ngx_stream_write_filter_module: ngx_module_t;
extern var ngx_stream_mqtt_preread_module: ngx_module_t;
extern var ngx_stream_mqtt_filter_module: ngx_module_t;
extern var ngx_stream_log_module: ngx_module_t;

// Ordered list of modules (following nginx's module loading order)
export const ngx_modules = [_][*c]ngx_module_t{
    // Core modules
    &ngx_core_module,
    &ngx_errlog_module,
    &ngx_conf_module,
    &ngx_openssl_module,
    &ngx_openssl_cache_module,
    &ngx_quic_module,
    &ngx_quic_bpf_module,
    &ngx_regex_module,

    // Event modules
    &ngx_events_module,
    &ngx_event_core_module,
    &ngx_epoll_module,

    // HTTP core
    &ngx_http_module,
    &ngx_http_core_module,
    &ngx_http_log_module,
    &ngx_http_upstream_module,

    // Standard HTTP modules
    &ngx_thread_pool_module,
    &ngx_http_v2_module,
    &ngx_http_v3_module,
    &ngx_http_static_module,
    &ngx_http_autoindex_module,
    &ngx_http_index_module,
    &ngx_http_mirror_module,
    &ngx_http_try_files_module,
    &ngx_http_auth_basic_module,
    &ngx_http_access_module,
    &ngx_http_auth_request_module,

    // Limit modules
    &ngx_http_limit_conn_module,
    &ngx_http_limit_req_module,

    // Access phase modules (custom)
    &ngx_http_wechatpay_module,
    &ngx_http_jsonschema_module,
    &ngx_http_ratelimit_module,
    &ngx_http_jwt_module,
    &ngx_http_waf_module,
    &ngx_http_circuit_breaker_module,
    &ngx_http_nftset_module,

    // Routing & filtering
    &ngx_http_geo_module,
    &ngx_http_map_module,
    &ngx_http_split_clients_module,
    &ngx_http_referer_module,
    &ngx_http_rewrite_module,

    // Security
    &ngx_http_ssl_module,

    // Proxy & backend
    &ngx_http_proxy_module,
    &ngx_http_fastcgi_module,
    &ngx_http_uwsgi_module,
    &ngx_http_scgi_module,
    &ngx_http_grpc_module,
    &ngx_http_memcached_module,

    // Misc
    &ngx_http_empty_gif_module,
    &ngx_http_browser_module,

    // Upstream balance
    &ngx_http_upstream_hash_module,
    &ngx_http_upstream_ip_hash_module,
    &ngx_http_upstream_least_conn_module,
    &ngx_http_upstream_random_module,
    &ngx_http_upstream_keepalive_module,
    &ngx_http_upstream_zone_module,
    &ngx_http_upstream_balancer_module,
    &ngx_http_dynamic_upstreams_module,

    // Javascript modules
    &ngx_http_js_module,

    // NJS Extended Modules
    &ngx_http_echoz_module,

    // Custom Upstream Processing Modules
    &ngx_http_pgrest_module,
    &ngx_http_redis_module,
    &ngx_http_consul_module,
    &ngx_http_hello_module,

    // Security & Auth
    &ngx_http_oidc_module,
    &ngx_http_acme_module,

    // Traffic Management
    &ngx_http_healthcheck_module,
    &ngx_http_canary_module,
    &ngx_http_worker_events_module,

    // Advanced Processing
    &ngx_http_graphql_module,
    &ngx_http_cache_purge_module,
    &ngx_http_prometheus_module,

    // Filter Modules (placed at the end)
    &ngx_http_write_filter_module,
    &ngx_http_header_filter_module,
    &ngx_http_chunked_filter_module,
    &ngx_http_v2_filter_module,
    &ngx_http_v3_filter_module,
    &ngx_http_range_header_filter_module,
    &ngx_http_gzip_filter_module,
    &ngx_http_postpone_filter_module,
    &ngx_http_ssi_filter_module,
    &ngx_http_charset_filter_module,
    &ngx_http_xslt_filter_module,
    &ngx_http_userid_filter_module,

    &ngx_http_echoz_filter_module,
    &ngx_http_wechatpay_filter_module,
    &ngx_http_upstream_balancer_filter_module,
    &ngx_http_oidc_filter_module,
    &ngx_http_requestid_filter_module,
    &ngx_http_cache_tags_filter_module,
    &ngx_http_transform_filter_module,
    &ngx_http_waf_filter_module,

    &ngx_http_headers_filter_module,

    // More Filter Modules
    &ngx_http_copy_filter_module,
    &ngx_http_range_body_filter_module,
    &ngx_http_not_modified_filter_module,

    // Stream modules
    &ngx_stream_module,
    &ngx_stream_core_module,
    &ngx_stream_proxy_module,
    &ngx_stream_upstream_module,
    &ngx_stream_ssl_module,
    &ngx_stream_realip_module,
    &ngx_stream_limit_conn_module,
    &ngx_stream_access_module,
    &ngx_stream_geo_module,
    &ngx_stream_map_module,
    &ngx_stream_split_clients_module,
    &ngx_stream_return_module,
    &ngx_stream_pass_module,
    &ngx_stream_set_module,
    &ngx_stream_upstream_hash_module,
    &ngx_stream_upstream_least_conn_module,
    &ngx_stream_upstream_random_module,
    &ngx_stream_upstream_zone_module,
    &ngx_stream_ssl_preread_module,
    &ngx_stream_mqtt_preread_module,
    &ngx_stream_write_filter_module,
    &ngx_stream_mqtt_filter_module,
    &ngx_stream_log_module,

    // Null terminator
    ngx.core.nullptr(ngx_module_t),
};

// Module names array (for logging/debugging)
export const ngx_module_names = [_][*c]const u8{
    "ngx_core_module",
    "ngx_errlog_module",
    "ngx_conf_module",
    "ngx_openssl_module",
    "ngx_openssl_cache_module",
    "ngx_quic_module",
    "ngx_quic_bpf_module",
    "ngx_regex_module",
    "ngx_events_module",
    "ngx_event_core_module",
    "ngx_epoll_module",
    "ngx_thread_pool_module",
    "ngx_http_module",
    "ngx_http_core_module",
    "ngx_http_log_module",
    "ngx_http_upstream_module",
    "ngx_http_v2_module",
    "ngx_http_v3_module",
    "ngx_http_static_module",
    "ngx_http_autoindex_module",
    "ngx_http_index_module",
    "ngx_http_mirror_module",
    "ngx_http_try_files_module",
    "ngx_http_auth_basic_module",
    "ngx_http_access_module",
    "ngx_http_auth_request_module",
    "ngx_http_limit_conn_module",
    "ngx_http_limit_req_module",
    "ngx_http_wechatpay_module",
    "ngx_http_jsonschema_module",
    "ngx_http_ratelimit_module",
    "ngx_http_waf_module",
    "ngx_http_circuit_breaker_module",
    "ngx_http_nftset_module",
    "ngx_http_geo_module",
    "ngx_http_map_module",
    "ngx_http_split_clients_module",
    "ngx_http_referer_module",
    "ngx_http_rewrite_module",
    "ngx_http_ssl_module",
    "ngx_http_proxy_module",
    "ngx_http_fastcgi_module",
    "ngx_http_uwsgi_module",
    "ngx_http_scgi_module",
    "ngx_http_grpc_module",
    "ngx_http_memcached_module",
    "ngx_http_empty_gif_module",
    "ngx_http_browser_module",
    "ngx_http_upstream_hash_module",
    "ngx_http_upstream_ip_hash_module",
    "ngx_http_upstream_least_conn_module",
    "ngx_http_upstream_random_module",
    "ngx_http_upstream_keepalive_module",
    "ngx_http_upstream_zone_module",
    "ngx_http_upstream_balancer_module",
    "ngx_http_dynamic_upstreams_module",
    "ngx_http_js_module",
    "ngx_http_echoz_module",
    "ngx_http_pgrest_module",
    "ngx_http_redis_module",
    "ngx_http_consul_module",
    "ngx_http_hello_module",
    "ngx_http_jwt_module",
    "ngx_http_oidc_module",
    "ngx_http_acme_module",
    "ngx_http_healthcheck_module",
    "ngx_http_canary_module",
    "ngx_http_worker_events_module",
    "ngx_http_graphql_module",
    "ngx_http_cache_purge_module",
    "ngx_http_prometheus_module",
    "ngx_http_write_filter_module",
    "ngx_http_header_filter_module",
    "ngx_http_chunked_filter_module",
    "ngx_http_v2_filter_module",
    "ngx_http_v3_filter_module",
    "ngx_http_range_header_filter_module",
    "ngx_http_gzip_filter_module",
    "ngx_http_postpone_filter_module",
    "ngx_http_ssi_filter_module",
    "ngx_http_charset_filter_module",
    "ngx_http_xslt_filter_module",
    "ngx_http_userid_filter_module",

    "ngx_http_echoz_filter_module",
    "ngx_http_wechatpay_filter_module",
    "ngx_http_upstream_balancer_filter_module",
    "ngx_http_oidc_filter_module",
    "ngx_http_requestid_filter_module",
    "ngx_http_cache_tags_filter_module",
    "ngx_http_transform_filter_module",
    "ngx_http_waf_filter_module",

    "ngx_http_headers_filter_module",
    "ngx_http_copy_filter_module",
    "ngx_http_range_body_filter_module",
    "ngx_http_not_modified_filter_module",

    // Stream modules
    "ngx_stream_module",
    "ngx_stream_core_module",
    "ngx_stream_proxy_module",
    "ngx_stream_upstream_module",
    "ngx_stream_ssl_module",
    "ngx_stream_realip_module",
    "ngx_stream_limit_conn_module",
    "ngx_stream_access_module",
    "ngx_stream_geo_module",
    "ngx_stream_map_module",
    "ngx_stream_split_clients_module",
    "ngx_stream_return_module",
    "ngx_stream_pass_module",
    "ngx_stream_set_module",
    "ngx_stream_upstream_hash_module",
    "ngx_stream_upstream_least_conn_module",
    "ngx_stream_upstream_random_module",
    "ngx_stream_upstream_zone_module",
    "ngx_stream_ssl_preread_module",
    "ngx_stream_mqtt_preread_module",
    "ngx_stream_write_filter_module",
    "ngx_stream_mqtt_filter_module",
    "ngx_stream_log_module",

    // Null terminator
    ngx.core.nullptr(u8),
};
