const std = @import("std");
const ngx = @import("ngx");

const conf = ngx.conf;
const core = ngx.core;
const http = ngx.http;
const shm = ngx.shm;
const list = ngx.list;
const string = ngx.string;

const ngx_command_t = conf.ngx_command_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_str_t = string.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_peer_connection_t = core.ngx_peer_connection_t;
const ngx_http_request_t = http.ngx_http_request_t;
const ngx_http_upstream_srv_conf_t = http.ngx_http_upstream_srv_conf_t;
const ngx_http_upstream_rr_peer_data_t = http.ngx_http_upstream_rr_peer_data_t;
const ngx_http_upstream_rr_peers_t = http.ngx_http_upstream_rr_peers_t;
const ngx_http_upstream_rr_peer_t = http.ngx_http_upstream_rr_peer_t;
const ngx_table_elt_t = ngx.hash.ngx_table_elt_t;
const NList = list.NList;

extern var ngx_http_upstream_module: ngx_module_t;
extern var ngx_http_core_module: ngx_module_t;

// Provided by the healthcheck module. Returns 1 if the peer is eligible
// (healthy or not monitored), 0 if a configured probe marks it unhealthy.
extern fn ngz_healthcheck_is_peer_eligible(addr_data: [*c]u8, addr_len: usize) callconv(.c) c_int;
extern fn ngz_healthcheck_peer_state(addr_data: [*c]u8, addr_len: usize) callconv(.c) c_int;

extern fn ngx_http_upstream_init_round_robin(
    cf: [*c]ngx_conf_t,
    us: [*c]ngx_http_upstream_srv_conf_t,
) callconv(.c) ngx_int_t;
extern fn ngx_rwlock_wlock(lock: ?*anyopaque) callconv(.c) void;
extern fn ngx_rwlock_unlock(lock: ?*anyopaque) callconv(.c) void;

const STICKY_OFF: c_int = 0;
const STICKY_COOKIE: c_int = 1;
const STICKY_HEADER: c_int = 2;

const FALLBACK_NEXT: c_int = 0;
const FALLBACK_OFF: c_int = 1;
const DIRECT_COOKIE_PREFIX = "peer:";
const DEFAULT_COOKIE_ATTRS = "; Path=/; HttpOnly; SameSite=Lax";
const BALANCER_METRICS_ZONE_SIZE: usize = 32 * 1024;
const HEALTHCHECK_PEER_STATE_ELIGIBLE: c_int = 0;
const HEALTHCHECK_PEER_STATE_UNHEALTHY: c_int = 1;
const HEALTHCHECK_PEER_STATE_SLOW_START: c_int = 2;

const balancer_metrics_store = extern struct {
    initialized: core.ngx_flag_t,
    requests_total: u64,
    sticky_cookie_requests_total: u64,
    sticky_header_requests_total: u64,
    runtime_peer_source_requests_total: u64,
    direct_peer_hits: u64,
    hash_hits: u64,
    key_absent_misses: u64,
    direct_peer_misses: u64,
    fallback_next_total: u64,
    fallback_off_total: u64,
    cookies_issued_total: u64,
    cookies_rotated_total: u64,
    peer_rejections_tried_total: u64,
    peer_rejections_unhealthy_total: u64,
    peer_rejections_slow_start_total: u64,
    peer_rejections_fail_window_total: u64,
    peer_rejections_max_conns_total: u64,
    peer_rejections_draining_total: u64,
};

var ngx_http_upstream_balancer_zone: [*c]core.ngx_shm_zone_t = core.nullptr(core.ngx_shm_zone_t);
var ngx_http_upstream_balancer_next_header_filter: http.ngx_http_output_header_filter_pt = null;

// Per-upstream configuration stored in uscf->srv_conf[ctx_index].
const BalancerSrvConf = extern struct {
    sticky_mode: c_int,
    fallback_mode: c_int,
    issue_cookie: core.ngx_flag_t,
    key_name: ngx_str_t,
    cookie_attrs: ngx_str_t,
    upstream_name: ngx_str_t,
    var_index: ngx_int_t,
    peer_source_ctx: ?*anyopaque,
    peer_source_vtable: ?*const PeerSourceVTable,
    original_init_upstream: ?*anyopaque,
    original_init_peer: ?*anyopaque,
};

const balancer_loc_conf = extern struct {
    status_endpoint: core.ngx_flag_t,
};

// Per-request context allocated from r->pool.
const BalancerRequestCtx = extern struct {
    conf_ptr: ?*anyopaque,
    request_ptr: ?*anyopaque,
    original_data: ?*anyopaque,
    original_get: ?*anyopaque,
    original_free: ?*anyopaque,
    sticky_used: c_int,
    pending_cookie: ngx_str_t,
    pending_cookie_rotate: core.ngx_flag_t,
    dynamic_peers: [*c]ngx_http_upstream_rr_peers_t,
    dynamic_generation: u64,
    dynamic_source_ctx: ?*anyopaque,
    dynamic_release_generation: ?*anyopaque,
    dynamic_active: core.ngx_flag_t,
};

const PeerSourceGetActivePeersFn = *const fn (?*anyopaque, [*c]ngx_http_request_t, *u64) callconv(.c) [*c]ngx_http_upstream_rr_peers_t;
const PeerSourceReleaseGenerationFn = *const fn (?*anyopaque, [*c]ngx_http_upstream_rr_peers_t, u64) callconv(.c) void;
const PeerSourceIsPeerDrainingFn = *const fn (?*anyopaque, [*c]u8, usize) callconv(.c) c_int;

const PeerSourceVTable = extern struct {
    get_active_peers: ?*anyopaque,
    release_generation: ?*anyopaque,
    is_peer_draining: ?*anyopaque,
};

fn configError(cf: [*c]ngx_conf_t, comptime msg: []const u8) [*c]u8 {
    ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, cf.*.log, 0, msg ++ "\x00", .{});
    return conf.NGX_CONF_ERROR;
}

fn create_srv_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const bcf = core.ngz_pcalloc(BalancerSrvConf, cf.*.pool) orelse return null;
    bcf.sticky_mode = STICKY_OFF;
    bcf.fallback_mode = FALLBACK_NEXT;
    bcf.issue_cookie = 0;
    bcf.var_index = core.NGX_ERROR;
    bcf.peer_source_ctx = null;
    bcf.peer_source_vtable = null;
    return @ptrCast(bcf);
}

fn merge_srv_conf(cf: [*c]ngx_conf_t, parent: ?*anyopaque, child: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    _ = parent;
    _ = child;
    return conf.NGX_CONF_OK;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const lcf = core.ngz_pcalloc(balancer_loc_conf, cf.*.pool) orelse return null;
    lcf.status_endpoint = 0;
    return @ptrCast(lcf);
}

fn merge_loc_conf(cf: [*c]ngx_conf_t, parent: ?*anyopaque, child: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    const prev = core.castPtr(balancer_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(balancer_loc_conf, child) orelse return conf.NGX_CONF_OK;
    if (c.*.status_endpoint == 0) c.*.status_endpoint = prev.*.status_endpoint;
    return conf.NGX_CONF_OK;
}

fn get_balancer_conf(cf: [*c]ngx_conf_t) ?[*c]BalancerSrvConf {
    const uscf = core.castPtr(
        ngx_http_upstream_srv_conf_t,
        conf.ngx_http_conf_get_module_srv_conf(cf, &ngx_http_upstream_module),
    ) orelse return null;
    return core.castPtr(
        BalancerSrvConf,
        conf.ngx_http_conf_upstream_srv_conf(uscf, &ngx_http_upstream_balancer_module),
    );
}

fn getMetricsStore() ?[*c]balancer_metrics_store {
    if (ngx_http_upstream_balancer_zone == core.nullptr(core.ngx_shm_zone_t)) return null;
    return core.castPtr(balancer_metrics_store, ngx_http_upstream_balancer_zone.*.data);
}

fn getMetricsShpool() ?[*c]core.ngx_slab_pool_t {
    const zone = ngx_http_upstream_balancer_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.shm.addr == null or zone.*.data == null) return null;
    return core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr);
}

fn atomicLoadMetric(ptr: *const u64) u64 {
    return @atomicLoad(u64, ptr, .monotonic);
}

const BalancerMetric = enum {
    requests_total,
    sticky_cookie_requests_total,
    sticky_header_requests_total,
    runtime_peer_source_requests_total,
    direct_peer_hits,
    hash_hits,
    key_absent_misses,
    direct_peer_misses,
    fallback_next_total,
    fallback_off_total,
    cookies_issued_total,
    cookies_rotated_total,
    peer_rejections_tried_total,
    peer_rejections_unhealthy_total,
    peer_rejections_slow_start_total,
    peer_rejections_fail_window_total,
    peer_rejections_max_conns_total,
    peer_rejections_draining_total,
};

fn incrementMetric(metric: BalancerMetric) void {
    const store = getMetricsStore() orelse return;
    switch (metric) {
        .requests_total => _ = @atomicRmw(u64, &store.*.requests_total, .Add, 1, .monotonic),
        .sticky_cookie_requests_total => _ = @atomicRmw(u64, &store.*.sticky_cookie_requests_total, .Add, 1, .monotonic),
        .sticky_header_requests_total => _ = @atomicRmw(u64, &store.*.sticky_header_requests_total, .Add, 1, .monotonic),
        .runtime_peer_source_requests_total => _ = @atomicRmw(u64, &store.*.runtime_peer_source_requests_total, .Add, 1, .monotonic),
        .direct_peer_hits => _ = @atomicRmw(u64, &store.*.direct_peer_hits, .Add, 1, .monotonic),
        .hash_hits => _ = @atomicRmw(u64, &store.*.hash_hits, .Add, 1, .monotonic),
        .key_absent_misses => _ = @atomicRmw(u64, &store.*.key_absent_misses, .Add, 1, .monotonic),
        .direct_peer_misses => _ = @atomicRmw(u64, &store.*.direct_peer_misses, .Add, 1, .monotonic),
        .fallback_next_total => _ = @atomicRmw(u64, &store.*.fallback_next_total, .Add, 1, .monotonic),
        .fallback_off_total => _ = @atomicRmw(u64, &store.*.fallback_off_total, .Add, 1, .monotonic),
        .cookies_issued_total => _ = @atomicRmw(u64, &store.*.cookies_issued_total, .Add, 1, .monotonic),
        .cookies_rotated_total => _ = @atomicRmw(u64, &store.*.cookies_rotated_total, .Add, 1, .monotonic),
        .peer_rejections_tried_total => _ = @atomicRmw(u64, &store.*.peer_rejections_tried_total, .Add, 1, .monotonic),
        .peer_rejections_unhealthy_total => _ = @atomicRmw(u64, &store.*.peer_rejections_unhealthy_total, .Add, 1, .monotonic),
        .peer_rejections_slow_start_total => _ = @atomicRmw(u64, &store.*.peer_rejections_slow_start_total, .Add, 1, .monotonic),
        .peer_rejections_fail_window_total => _ = @atomicRmw(u64, &store.*.peer_rejections_fail_window_total, .Add, 1, .monotonic),
        .peer_rejections_max_conns_total => _ = @atomicRmw(u64, &store.*.peer_rejections_max_conns_total, .Add, 1, .monotonic),
        .peer_rejections_draining_total => _ = @atomicRmw(u64, &store.*.peer_rejections_draining_total, .Add, 1, .monotonic),
    }
}

fn snapshotMetrics() ?balancer_metrics_store {
    const store = getMetricsStore() orelse return null;
    return balancer_metrics_store{
        .initialized = store.*.initialized,
        .requests_total = atomicLoadMetric(&store.*.requests_total),
        .sticky_cookie_requests_total = atomicLoadMetric(&store.*.sticky_cookie_requests_total),
        .sticky_header_requests_total = atomicLoadMetric(&store.*.sticky_header_requests_total),
        .runtime_peer_source_requests_total = atomicLoadMetric(&store.*.runtime_peer_source_requests_total),
        .direct_peer_hits = atomicLoadMetric(&store.*.direct_peer_hits),
        .hash_hits = atomicLoadMetric(&store.*.hash_hits),
        .key_absent_misses = atomicLoadMetric(&store.*.key_absent_misses),
        .direct_peer_misses = atomicLoadMetric(&store.*.direct_peer_misses),
        .fallback_next_total = atomicLoadMetric(&store.*.fallback_next_total),
        .fallback_off_total = atomicLoadMetric(&store.*.fallback_off_total),
        .cookies_issued_total = atomicLoadMetric(&store.*.cookies_issued_total),
        .cookies_rotated_total = atomicLoadMetric(&store.*.cookies_rotated_total),
        .peer_rejections_tried_total = atomicLoadMetric(&store.*.peer_rejections_tried_total),
        .peer_rejections_unhealthy_total = atomicLoadMetric(&store.*.peer_rejections_unhealthy_total),
        .peer_rejections_slow_start_total = atomicLoadMetric(&store.*.peer_rejections_slow_start_total),
        .peer_rejections_fail_window_total = atomicLoadMetric(&store.*.peer_rejections_fail_window_total),
        .peer_rejections_max_conns_total = atomicLoadMetric(&store.*.peer_rejections_max_conns_total),
        .peer_rejections_draining_total = atomicLoadMetric(&store.*.peer_rejections_draining_total),
    };
}

fn balancer_zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        zone.*.data = data;
        return core.NGX_OK;
    }
    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return core.NGX_ERROR;
    if (shpool.*.data != null) {
        zone.*.data = shpool.*.data;
        return core.NGX_OK;
    }
    const mem = shm.ngx_slab_calloc(shpool, @sizeOf(balancer_metrics_store)) orelse return core.NGX_ERROR;
    const store = core.castPtr(balancer_metrics_store, mem) orelse return core.NGX_ERROR;
    store.* = std.mem.zeroes(balancer_metrics_store);
    store.*.initialized = 1;
    shpool.*.data = store;
    zone.*.data = store;
    return core.NGX_OK;
}

// Install our init_upstream hook on first sticky directive in an upstream block.
fn install_init_upstream_hook(cf: [*c]ngx_conf_t) bool {
    const uscf = core.castPtr(
        ngx_http_upstream_srv_conf_t,
        conf.ngx_http_conf_get_module_srv_conf(cf, &ngx_http_upstream_module),
    ) orelse return false;
    const bcf = core.castPtr(
        BalancerSrvConf,
        conf.ngx_http_conf_upstream_srv_conf(uscf, &ngx_http_upstream_balancer_module),
    ) orelse return false;

    if (bcf.*.original_init_upstream == null) {
        bcf.*.original_init_upstream = if (uscf.*.peer.init_upstream) |f|
            @constCast(@ptrCast(f))
        else
            @constCast(@ptrCast(&ngx_http_upstream_init_round_robin));
        uscf.*.peer.init_upstream = upstream_balancer_init_upstream;
    }
    return true;
}

// Build "cookie_<name>" variable name string from pool (no $ prefix for ngx_http_get_variable_index).
fn build_cookie_varname(cf: [*c]ngx_conf_t, name: ngx_str_t) ?ngx_str_t {
    const prefix = "cookie_";
    const total = prefix.len + name.len;
    const vardata = core.castPtr(u8, core.ngx_pnalloc(cf.*.pool, total)) orelse return null;
    @memcpy(core.slicify(u8, vardata, prefix.len), prefix);
    @memcpy(core.slicify(u8, vardata + prefix.len, name.len), core.slicify(u8, name.data, name.len));
    return ngx_str_t{ .len = total, .data = vardata };
}

// Build "http_<lowercased_name>" variable name, replacing '-' with '_' (no $ prefix).
fn build_header_varname(cf: [*c]ngx_conf_t, name: ngx_str_t) ?ngx_str_t {
    const prefix = "http_";
    const total = prefix.len + name.len;
    const vardata = core.castPtr(u8, core.ngx_pnalloc(cf.*.pool, total)) orelse return null;
    @memcpy(core.slicify(u8, vardata, prefix.len), prefix);
    const src = core.slicify(u8, name.data, name.len);
    const dst = core.slicify(u8, vardata + prefix.len, name.len);
    for (src, 0..) |ch, idx| {
        dst[idx] = if (ch == '-') '_' else if (ch >= 'A' and ch <= 'Z') ch | 0x20 else ch;
    }
    return ngx_str_t{ .len = total, .data = vardata };
}

fn dupPoolString(pool: [*c]core.ngx_pool_t, input: []const u8) ?ngx_str_t {
    const mem = core.castPtr(u8, core.ngx_pnalloc(pool, input.len)) orelse return null;
    @memcpy(mem[0..input.len], input);
    return ngx_str_t{ .len = input.len, .data = mem };
}

fn triedWordCount(peer_count: ngx_uint_t) usize {
    const bits_per_word = 8 * @sizeOf(usize);
    if (peer_count == 0) return 1;
    return (@as(usize, peer_count) + bits_per_word - 1) / bits_per_word;
}

fn totalPeerCount(peers: [*c]ngx_http_upstream_rr_peers_t) ngx_uint_t {
    var total: ngx_uint_t = 0;
    var chain = peers;
    while (chain != null) : (chain = chain.*.next) {
        var peer = chain.*.peer;
        while (peer != null) : (peer = peer.*.next) {
            total += 1;
        }
    }
    return total;
}

fn applyDynamicPeerGraph(
    ctx: *BalancerRequestCtx,
    rrp: [*c]ngx_http_upstream_rr_peer_data_t,
    peers: [*c]ngx_http_upstream_rr_peers_t,
    tried: [*c]usize,
    generation: u64,
    source_ctx: ?*anyopaque,
    release_generation: ?*anyopaque,
) void {
    rrp.*.peers = peers;
    rrp.*.current = null;
    rrp.*.tried = tried;
    rrp.*.config = if (peers.*.config != null) peers.*.config.* else 0;

    ctx.dynamic_peers = peers;
    ctx.dynamic_generation = generation;
    ctx.dynamic_source_ctx = source_ctx;
    ctx.dynamic_release_generation = release_generation;
    ctx.dynamic_active = 1;
}

fn releaseDynamicPeerGraph(ctx: *BalancerRequestCtx) void {
    if (ctx.dynamic_active == 0) return;
    if (ctx.dynamic_release_generation) |raw_release| {
        const release_fn: PeerSourceReleaseGenerationFn =
            @ptrCast(@alignCast(raw_release));
        release_fn(ctx.dynamic_source_ctx, ctx.dynamic_peers, ctx.dynamic_generation);
    }
    ctx.dynamic_peers = core.nullptr(ngx_http_upstream_rr_peers_t);
    ctx.dynamic_generation = 0;
    ctx.dynamic_source_ctx = null;
    ctx.dynamic_release_generation = null;
    ctx.dynamic_active = 0;
}

fn bindDynamicPeerSource(
    r: [*c]ngx_http_request_t,
    bcf: *BalancerSrvConf,
    ctx: *BalancerRequestCtx,
) ngx_int_t {
    const vtable = bcf.peer_source_vtable orelse return core.NGX_OK;
    const raw_get = vtable.get_active_peers orelse return core.NGX_OK;
    const get_fn: PeerSourceGetActivePeersFn =
        @ptrCast(@alignCast(raw_get));

    var generation: u64 = 0;
    const peers = get_fn(bcf.peer_source_ctx, r, &generation);
    if (peers == null) return core.NGX_OK;

    const rrp = core.castPtr(ngx_http_upstream_rr_peer_data_t, ctx.original_data) orelse return core.NGX_ERROR;
    const total_peers = totalPeerCount(peers);
    const tried_words = triedWordCount(total_peers);
    const tried_mem = core.castPtr(usize, core.ngx_pcalloc(r.*.pool, tried_words * @sizeOf(usize))) orelse return core.NGX_ERROR;

    applyDynamicPeerGraph(ctx, rrp, peers, tried_mem, generation, bcf.peer_source_ctx, @constCast(@ptrCast(vtable.release_generation)));
    incrementMetric(.runtime_peer_source_requests_total);
    return core.NGX_OK;
}

fn set_sticky_cookie(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, data: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = data;

    const bcf = get_balancer_conf(cf) orelse
        return configError(cf, "upstream_balancer_sticky_cookie: upstream context unavailable");
    if (bcf.*.sticky_mode != STICKY_OFF)
        return configError(cf, "upstream_balancer_sticky_cookie and upstream_balancer_sticky_header are mutually exclusive");

    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse
        return configError(cf, "upstream_balancer_sticky_cookie requires a cookie name");
    if (arg.*.len == 0)
        return configError(cf, "upstream_balancer_sticky_cookie: cookie name must not be empty");

    bcf.*.key_name = arg.*;
    bcf.*.sticky_mode = STICKY_COOKIE;

    var varname = build_cookie_varname(cf, arg.*) orelse return conf.NGX_CONF_ERROR;
    const vi = http.ngx_http_get_variable_index(cf, &varname);
    if (vi == core.NGX_ERROR)
        return configError(cf, "upstream_balancer_sticky_cookie: failed to register variable");
    bcf.*.var_index = vi;

    if (!install_init_upstream_hook(cf)) return conf.NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

fn set_sticky_header(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, data: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = data;

    const bcf = get_balancer_conf(cf) orelse
        return configError(cf, "upstream_balancer_sticky_header: upstream context unavailable");
    if (bcf.*.sticky_mode != STICKY_OFF)
        return configError(cf, "upstream_balancer_sticky_cookie and upstream_balancer_sticky_header are mutually exclusive");

    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse
        return configError(cf, "upstream_balancer_sticky_header requires a header name");
    if (arg.*.len == 0)
        return configError(cf, "upstream_balancer_sticky_header: header name must not be empty");

    bcf.*.key_name = arg.*;
    bcf.*.sticky_mode = STICKY_HEADER;

    var varname = build_header_varname(cf, arg.*) orelse return conf.NGX_CONF_ERROR;
    const vi = http.ngx_http_get_variable_index(cf, &varname);
    if (vi == core.NGX_ERROR)
        return configError(cf, "upstream_balancer_sticky_header: failed to register variable");
    bcf.*.var_index = vi;

    if (!install_init_upstream_hook(cf)) return conf.NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

fn set_fallback(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, data: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = data;

    const bcf = get_balancer_conf(cf) orelse
        return configError(cf, "upstream_balancer_fallback: upstream context unavailable");

    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse
        return configError(cf, "upstream_balancer_fallback requires a value");

    const val = core.slicify(u8, arg.*.data, arg.*.len);
    if (std.mem.eql(u8, val, "next")) {
        bcf.*.fallback_mode = FALLBACK_NEXT;
    } else if (std.mem.eql(u8, val, "off")) {
        bcf.*.fallback_mode = FALLBACK_OFF;
    } else {
        return configError(cf, "upstream_balancer_fallback: value must be 'next' or 'off'");
    }

    return conf.NGX_CONF_OK;
}

fn set_issue_cookie(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, data: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = data;
    const bcf = get_balancer_conf(cf) orelse
        return configError(cf, "upstream_balancer_issue_cookie: upstream context unavailable");
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse
        return configError(cf, "upstream_balancer_issue_cookie requires on|off");
    const val = core.slicify(u8, arg.*.data, arg.*.len);
    if (std.mem.eql(u8, val, "on")) {
        bcf.*.issue_cookie = 1;
    } else if (std.mem.eql(u8, val, "off")) {
        bcf.*.issue_cookie = 0;
    } else {
        return configError(cf, "upstream_balancer_issue_cookie: value must be 'on' or 'off'");
    }
    return conf.NGX_CONF_OK;
}

fn set_cookie_attrs(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, data: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = data;
    const bcf = get_balancer_conf(cf) orelse
        return configError(cf, "upstream_balancer_cookie_attrs: upstream context unavailable");
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse
        return configError(cf, "upstream_balancer_cookie_attrs requires an attribute string");
    bcf.*.cookie_attrs = arg.*;
    return conf.NGX_CONF_OK;
}

fn send_json_response(r: [*c]ngx_http_request_t, status: ngx_uint_t, body: ngx_str_t) ngx_int_t {
    const content_type = string.ngx_string("application/json");
    r.*.headers_out.status = status;
    r.*.headers_out.content_type = content_type;
    r.*.headers_out.content_type_len = content_type.len;
    r.*.headers_out.content_length_n = @intCast(body.len);
    const header_rc = http.ngx_http_send_header(r);
    if (header_rc == core.NGX_ERROR or header_rc > core.NGX_OK) return header_rc;
    if (r.*.method == http.NGX_HTTP_HEAD or r.*.flags1.header_only) return core.NGX_OK;
    const out_buf = core.ngz_pcalloc(ngx.buf.ngx_buf_t, r.*.pool) orelse return core.NGX_ERROR;
    out_buf.pos = body.data;
    out_buf.last = body.data + body.len;
    out_buf.flags.memory = true;
    out_buf.flags.last_buf = (r == r.*.main);
    out_buf.flags.last_in_chain = true;
    const chain = core.ngz_pcalloc(ngx.buf.ngx_chain_t, r.*.pool) orelse return core.NGX_ERROR;
    chain.buf = out_buf;
    chain.next = core.nullptr(ngx.buf.ngx_chain_t);
    return http.ngx_http_output_filter(r, chain);
}

export fn ngx_http_upstream_balancer_status_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    // Status endpoint reads shared-memory metrics and is only meaningful
    // for main requests. Refuse subrequests.
    if (r != r.*.main) return http.NGX_HTTP_FORBIDDEN;

    if (r.*.method != http.NGX_HTTP_GET and r.*.method != http.NGX_HTTP_HEAD) {
        return http.NGX_HTTP_NOT_ALLOWED;
    }
    const snapshot = snapshotMetrics() orelse
        return send_json_response(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR, string.ngx_string("{\"module\":\"upstream_balancer\",\"status\":\"error\",\"error\":\"metrics unavailable\"}"));
    var body_buf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf,
        "{{\"module\":\"upstream_balancer\",\"status\":\"ok\",\"requests_total\":{d},\"sticky_cookie_requests_total\":{d},\"sticky_header_requests_total\":{d},\"runtime_peer_source_requests_total\":{d},\"direct_peer_hits\":{d},\"hash_hits\":{d},\"key_absent_misses\":{d},\"direct_peer_misses\":{d},\"fallback_next_total\":{d},\"fallback_off_total\":{d},\"cookies_issued_total\":{d},\"cookies_rotated_total\":{d},\"peer_rejections_tried_total\":{d},\"peer_rejections_unhealthy_total\":{d},\"peer_rejections_slow_start_total\":{d},\"peer_rejections_fail_window_total\":{d},\"peer_rejections_max_conns_total\":{d},\"peer_rejections_draining_total\":{d}}}",
        .{
            snapshot.requests_total,
            snapshot.sticky_cookie_requests_total,
            snapshot.sticky_header_requests_total,
            snapshot.runtime_peer_source_requests_total,
            snapshot.direct_peer_hits,
            snapshot.hash_hits,
            snapshot.key_absent_misses,
            snapshot.direct_peer_misses,
            snapshot.fallback_next_total,
            snapshot.fallback_off_total,
            snapshot.cookies_issued_total,
            snapshot.cookies_rotated_total,
            snapshot.peer_rejections_tried_total,
            snapshot.peer_rejections_unhealthy_total,
            snapshot.peer_rejections_slow_start_total,
            snapshot.peer_rejections_fail_window_total,
            snapshot.peer_rejections_max_conns_total,
            snapshot.peer_rejections_draining_total,
        },
    ) catch return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    const body_str = dupPoolString(r.*.pool, body) orelse return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    return send_json_response(r, http.NGX_HTTP_OK, body_str);
}

fn set_status_endpoint(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(balancer_loc_conf, loc)) |lcf| {
        lcf.*.status_endpoint = 1;
        const clcf = core.castPtr(http.ngx_http_core_loc_conf_t, conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module)) orelse return conf.NGX_CONF_ERROR;
        clcf.*.handler = ngx_http_upstream_balancer_status_handler;
    }
    return conf.NGX_CONF_OK;
}

// Config-time: called by nginx for each upstream block that has our directive.
// Calls the original init_upstream, then installs our init_peer wrapper.
export fn upstream_balancer_init_upstream(
    cf: [*c]ngx_conf_t,
    us: [*c]ngx_http_upstream_srv_conf_t,
) callconv(.c) ngx_int_t {
    const bcf = core.castPtr(
        BalancerSrvConf,
        conf.ngx_http_conf_upstream_srv_conf(us, &ngx_http_upstream_balancer_module),
    ) orelse return core.NGX_ERROR;

    const orig_fn: *const fn ([*c]ngx_conf_t, [*c]ngx_http_upstream_srv_conf_t) callconv(.c) ngx_int_t =
        @ptrCast(@alignCast(bcf.*.original_init_upstream orelse return core.NGX_ERROR));
    if (orig_fn(cf, us) != core.NGX_OK) return core.NGX_ERROR;

    bcf.*.upstream_name = us.*.host;
    bcf.*.original_init_peer = @constCast(@ptrCast(us.*.peer.init));
    us.*.peer.init = upstream_balancer_init_peer;

    ngx.log.ngz_log_error(ngx.log.NGX_LOG_DEBUG, cf.*.log, 0,
        "upstream_balancer: callback installed\x00", .{});

    return core.NGX_OK;
}

// Per-request: called once to set up peer selection for a proxied request.
// Wraps get_peer/free_peer with our sticky-aware versions.
export fn upstream_balancer_init_peer(
    r: [*c]ngx_http_request_t,
    us: [*c]ngx_http_upstream_srv_conf_t,
) callconv(.c) ngx_int_t {
    const bcf = core.castPtr(
        BalancerSrvConf,
        conf.ngx_http_conf_upstream_srv_conf(us, &ngx_http_upstream_balancer_module),
    ) orelse return core.NGX_ERROR;

    const orig_init: *const fn ([*c]ngx_http_request_t, [*c]ngx_http_upstream_srv_conf_t) callconv(.c) ngx_int_t =
        @ptrCast(@alignCast(bcf.*.original_init_peer orelse return core.NGX_ERROR));
    if (orig_init(r, us) != core.NGX_OK) return core.NGX_ERROR;

    const ctx = core.ngz_pcalloc(BalancerRequestCtx, r.*.pool) orelse return core.NGX_ERROR;
    const u = r.*.upstream orelse return core.NGX_ERROR;

    ctx.conf_ptr = @ptrCast(bcf);
    ctx.request_ptr = @ptrCast(r);
    ctx.original_data = u.*.peer.data;
    ctx.original_get = @constCast(@ptrCast(u.*.peer.get));
    ctx.original_free = @constCast(@ptrCast(u.*.peer.free));
    ctx.sticky_used = 0;
    ctx.pending_cookie = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
    ctx.pending_cookie_rotate = 0;
    ctx.dynamic_peers = core.nullptr(ngx_http_upstream_rr_peers_t);
    ctx.dynamic_generation = 0;
    ctx.dynamic_source_ctx = null;
    ctx.dynamic_release_generation = null;
    ctx.dynamic_active = 0;

    r.*.ctx[ngx_http_upstream_balancer_module.ctx_index] = ctx;

    if (bindDynamicPeerSource(r, bcf, ctx) != core.NGX_OK) return core.NGX_ERROR;

    u.*.peer.get = upstream_balancer_get_peer;
    u.*.peer.free = upstream_balancer_free_peer;
    u.*.peer.data = @ptrCast(ctx);

    return core.NGX_OK;
}

// A peer is eligible if nginx hasn't marked it down, the healthcheck module
// (when loaded) considers it healthy, and it is not explicitly draining.
// All checks fail-open: unknown peer → eligible.
fn is_eligible(source_ctx: ?*anyopaque, p: [*c]ngx_http_upstream_rr_peer_t) bool {
    if (p.*.down != 0) return false;
    switch (ngz_healthcheck_peer_state(p.*.name.data, p.*.name.len)) {
        HEALTHCHECK_PEER_STATE_ELIGIBLE => {},
        HEALTHCHECK_PEER_STATE_UNHEALTHY => return false,
        HEALTHCHECK_PEER_STATE_SLOW_START => return false,
        else => if (ngz_healthcheck_is_peer_eligible(p.*.name.data, p.*.name.len) == 0) return false,
    }
    if (peerSourceIsDraining(source_ctx, null, p.*.name.data, p.*.name.len)) return false;
    return true;
}

fn peerSourceIsDraining(
    source_ctx: ?*anyopaque,
    vtable: ?*const PeerSourceVTable,
    addr_data: [*c]u8,
    addr_len: usize,
) bool {
    const peer_source_vtable = vtable orelse return false;
    const raw_check = peer_source_vtable.is_peer_draining orelse return false;
    const check_fn: PeerSourceIsPeerDrainingFn = @ptrCast(@alignCast(raw_check));
    return check_fn(source_ctx, addr_data, addr_len) != 0;
}

fn peers_wlock(peers: [*c]ngx_http_upstream_rr_peers_t) void {
    if (peers.*.shpool != null) {
        ngx_rwlock_wlock(@ptrCast(&peers.*.rwlock));
    }
}

fn peers_unlock(peers: [*c]ngx_http_upstream_rr_peers_t) void {
    if (peers.*.shpool != null) {
        ngx_rwlock_unlock(@ptrCast(&peers.*.rwlock));
    }
}

fn peer_ref(peers: [*c]ngx_http_upstream_rr_peers_t, peer: [*c]ngx_http_upstream_rr_peer_t) void {
    if (peers.*.shpool != null) {
        peer.*.refs += 1;
    }
}

fn peer_weight(peer: [*c]ngx_http_upstream_rr_peer_t) ngx_uint_t {
    return if (peer.*.weight == 0) 1 else @intCast(peer.*.weight);
}

fn peer_is_tried(rrp: [*c]ngx_http_upstream_rr_peer_data_t, index: ngx_uint_t) bool {
    const bits_per_word = 8 * @sizeOf(usize);
    const word = index / bits_per_word;
    const bit = @as(usize, 1) << @intCast(index % bits_per_word);
    return (rrp.*.tried[word] & bit) != 0;
}

fn mark_peer_tried(rrp: [*c]ngx_http_upstream_rr_peer_data_t, index: ngx_uint_t) void {
    const bits_per_word = 8 * @sizeOf(usize);
    const word = index / bits_per_word;
    const bit = @as(usize, 1) << @intCast(index % bits_per_word);
    rrp.*.tried[word] |= bit;
}

fn peer_available_for_sticky(
    source_ctx: ?*anyopaque,
    peer_source_vtable: ?*const PeerSourceVTable,
    rrp: [*c]ngx_http_upstream_rr_peer_data_t,
    peer: [*c]ngx_http_upstream_rr_peer_t,
    index: ngx_uint_t,
    now: @TypeOf(core.ngx_time()),
) bool {
    if (peer_is_tried(rrp, index)) {
        incrementMetric(.peer_rejections_tried_total);
        return false;
    }
    if (peer.*.down != 0) return false;
    switch (ngz_healthcheck_peer_state(peer.*.name.data, peer.*.name.len)) {
        HEALTHCHECK_PEER_STATE_UNHEALTHY => {
            incrementMetric(.peer_rejections_unhealthy_total);
            return false;
        },
        HEALTHCHECK_PEER_STATE_SLOW_START => {
            incrementMetric(.peer_rejections_slow_start_total);
            return false;
        },
        else => {},
    }
    if (peerSourceIsDraining(source_ctx, peer_source_vtable, peer.*.name.data, peer.*.name.len)) {
        incrementMetric(.peer_rejections_draining_total);
        return false;
    }
    if (peer.*.max_fails != 0 and peer.*.fails >= peer.*.max_fails and now - peer.*.checked <= peer.*.fail_timeout) {
        incrementMetric(.peer_rejections_fail_window_total);
        return false;
    }
    if (peer.*.max_conns != 0 and peer.*.conns >= peer.*.max_conns) {
        incrementMetric(.peer_rejections_max_conns_total);
        return false;
    }
    return true;
}

const StickySelection = struct {
    peer: [*c]ngx_http_upstream_rr_peer_t,
    index: ngx_uint_t,
};

fn select_direct_peer(
    source_ctx: ?*anyopaque,
    peer_source_vtable: ?*const PeerSourceVTable,
    rrp: [*c]ngx_http_upstream_rr_peer_data_t,
    target_name: []const u8,
) ?StickySelection {
    const now = core.ngx_time();
    var index: ngx_uint_t = 0;
    var peer = rrp.*.peers.*.peer;
    while (peer != null) : ({
        peer = peer.*.next;
        index += 1;
    }) {
        if (!peer_available_for_sticky(source_ctx, peer_source_vtable, rrp, peer, index, now)) continue;
        const name = core.slicify(u8, peer.*.name.data, peer.*.name.len);
        if (std.mem.eql(u8, name, target_name)) {
            if (now - peer.*.checked > peer.*.fail_timeout) peer.*.checked = now;
            return .{ .peer = peer, .index = index };
        }
    }
    return null;
}

fn select_sticky_peer(
    source_ctx: ?*anyopaque,
    peer_source_vtable: ?*const PeerSourceVTable,
    rrp: [*c]ngx_http_upstream_rr_peer_data_t,
    hash: u32,
) ?StickySelection {
    const peers = rrp.*.peers;
    const now = core.ngx_time();

    var total_weight: ngx_uint_t = 0;
    var index: ngx_uint_t = 0;
    var peer = peers.*.peer;
    while (peer != null) : ({
        peer = peer.*.next;
        index += 1;
    }) {
        if (peer_available_for_sticky(source_ctx, peer_source_vtable, rrp, peer, index, now)) {
            total_weight += peer_weight(peer);
        }
    }

    if (total_weight == 0) return null;

    const target = @as(ngx_uint_t, hash) % total_weight;
    var cumulative: ngx_uint_t = 0;
    index = 0;
    peer = peers.*.peer;
    while (peer != null) : ({
        peer = peer.*.next;
        index += 1;
    }) {
        if (!peer_available_for_sticky(source_ctx, peer_source_vtable, rrp, peer, index, now)) continue;
        cumulative += peer_weight(peer);
        if (target < cumulative) {
            if (now - peer.*.checked > peer.*.fail_timeout) {
                peer.*.checked = now;
            }
            return .{ .peer = peer, .index = index };
        }
    }

    return null;
}

fn buildIssuedCookieValue(r: [*c]ngx_http_request_t, bcf: *BalancerSrvConf, peer: [*c]ngx_http_upstream_rr_peer_t) ?ngx_str_t {
    if (bcf.*.sticky_mode != STICKY_COOKIE or bcf.*.issue_cookie == 0) return null;
    const name = core.slicify(u8, peer.*.name.data, peer.*.name.len);
    const attrs = if (bcf.*.cookie_attrs.len > 0 and bcf.*.cookie_attrs.data != null)
        core.slicify(u8, bcf.*.cookie_attrs.data, bcf.*.cookie_attrs.len)
    else
        DEFAULT_COOKIE_ATTRS;
    const key_name = core.slicify(u8, bcf.*.key_name.data, bcf.*.key_name.len);
    const value_len = key_name.len + 1 + DIRECT_COOKIE_PREFIX.len + name.len + attrs.len;
    const mem = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, value_len)) orelse return null;
    var offset: usize = 0;
    @memcpy(mem[offset..][0..key_name.len], key_name);
    offset += key_name.len;
    mem[offset] = '=';
    offset += 1;
    @memcpy(mem[offset..][0..DIRECT_COOKIE_PREFIX.len], DIRECT_COOKIE_PREFIX);
    offset += DIRECT_COOKIE_PREFIX.len;
    @memcpy(mem[offset..][0..name.len], name);
    offset += name.len;
    @memcpy(mem[offset..][0..attrs.len], attrs);
    offset += attrs.len;
    return ngx_str_t{ .len = offset, .data = mem };
}

fn queueIssuedCookie(ctx: *BalancerRequestCtx, cookie: ngx_str_t, rotate: bool) void {
    ctx.pending_cookie = cookie;
    ctx.pending_cookie_rotate = if (rotate) 1 else 0;
    incrementMetric(if (rotate) .cookies_rotated_total else .cookies_issued_total);
}

// Per-request: select a peer.
// On the first call, applies sticky selection or falls back per policy.
// On retries (sticky_used != 0), delegates directly to the original round-robin picker.
export fn upstream_balancer_get_peer(
    pc: [*c]ngx_peer_connection_t,
    data: ?*anyopaque,
) callconv(.c) ngx_int_t {
    const ctx = @as(*BalancerRequestCtx, @ptrCast(@alignCast(data)));
    const bcf = @as(*BalancerSrvConf, @ptrCast(@alignCast(ctx.conf_ptr)));
    incrementMetric(.requests_total);

    const orig_get: *const fn ([*c]ngx_peer_connection_t, ?*anyopaque) callconv(.c) ngx_int_t =
        @ptrCast(@alignCast(ctx.original_get));

    // Retry path: sticky selection already made; let round-robin handle retries.
    if (ctx.sticky_used != 0) {
        return orig_get(pc, ctx.original_data);
    }

    // Passthrough when sticky mode is off.
    if (bcf.*.sticky_mode == STICKY_OFF) {
        return orig_get(pc, ctx.original_data);
    }

    incrementMetric(if (bcf.*.sticky_mode == STICKY_COOKIE) .sticky_cookie_requests_total else .sticky_header_requests_total);

    // Extract affinity key via nginx variable system.
    const r = @as([*c]ngx_http_request_t, @ptrCast(@alignCast(ctx.request_ptr)));
    const vv = http.ngx_http_get_flushed_variable(r, @intCast(bcf.*.var_index));
    const key_absent = (vv == null) or vv.*.flags.not_found or (vv.*.flags.len == 0);
    const rrp = @as([*c]ngx_http_upstream_rr_peer_data_t, @ptrCast(@alignCast(ctx.original_data)));
    const source_ctx = if (ctx.dynamic_source_ctx != null) ctx.dynamic_source_ctx else bcf.*.peer_source_ctx;
    const peer_source_vtable = bcf.*.peer_source_vtable;

    if (key_absent) {
        incrementMetric(.key_absent_misses);
        if (bcf.*.fallback_mode == FALLBACK_OFF) {
            incrementMetric(.fallback_off_total);
            ngx.log.ngz_log_error(ngx.log.NGX_LOG_DEBUG, pc.*.log, 0,
                "upstream_balancer: sticky key absent, fallback off\x00", .{});
            return core.NGX_BUSY;
        }
        incrementMetric(.fallback_next_total);
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_DEBUG, pc.*.log, 0,
            "upstream_balancer: sticky key absent, fallback next\x00", .{});
        const rc = orig_get(pc, ctx.original_data);
        if (rc == core.NGX_OK) {
            if (rrp.*.current != null) {
                if (buildIssuedCookieValue(r, bcf, rrp.*.current)) |cookie| queueIssuedCookie(ctx, cookie, false);
            }
        }
        return rc;
    }

    const key = core.slicify(u8, vv.*.data, vv.*.flags.len);
    const peers = rrp.*.peers;
    var direct_target: ?[]const u8 = null;
    if (std.mem.startsWith(u8, key, DIRECT_COOKIE_PREFIX)) {
        direct_target = key[DIRECT_COOKIE_PREFIX.len..];
    }

    // Deterministic mapping: crc32(key) across weighted eligible peers unless
    // this is one of our direct peer cookies.
    const hash = std.hash.crc.Crc32.hash(key);

    pc.*.flags.cached = false;
    pc.*.connection = null;

    peers_wlock(peers);
    var peers_locked = true;
    defer if (peers_locked) peers_unlock(peers);

    if (peers.*.config != null and rrp.*.config != peers.*.config.*) {
        if (bcf.*.fallback_mode == FALLBACK_OFF) return core.NGX_BUSY;
        peers_unlock(peers);
        peers_locked = false;
        return orig_get(pc, ctx.original_data);
    }

    var direct_target_missed = false;
    const maybe_chosen = if (direct_target) |target_name| blk: {
        if (select_direct_peer(source_ctx, peer_source_vtable, rrp, target_name)) |selection| break :blk selection;
        direct_target_missed = true;
        break :blk select_sticky_peer(source_ctx, peer_source_vtable, rrp, hash);
    } else select_sticky_peer(source_ctx, peer_source_vtable, rrp, hash);
    const chosen = maybe_chosen orelse {
        if (direct_target != null) incrementMetric(.direct_peer_misses);
        if (bcf.*.fallback_mode == FALLBACK_OFF) {
            incrementMetric(.fallback_off_total);
            pc.*.name = peers.*.name;
            return core.NGX_BUSY;
        }
        incrementMetric(.fallback_next_total);
        peers_unlock(peers);
        peers_locked = false;
        const rc = orig_get(pc, ctx.original_data);
        if (rc == core.NGX_OK and direct_target != null) {
            if (rrp.*.current != null) {
                if (buildIssuedCookieValue(r, bcf, rrp.*.current)) |cookie| queueIssuedCookie(ctx, cookie, true);
            }
        }
        return rc;
    };

    pc.*.sockaddr = chosen.peer.*.sockaddr;
    pc.*.socklen = chosen.peer.*.socklen;
    pc.*.name = &chosen.peer.*.name;
    chosen.peer.*.conns += 1;
    peer_ref(peers, chosen.peer);
    rrp.*.current = chosen.peer;
    mark_peer_tried(rrp, chosen.index);
    ctx.sticky_used = 1;
    if (direct_target_missed) {
        incrementMetric(.direct_peer_misses);
        incrementMetric(.hash_hits);
        if (buildIssuedCookieValue(r, bcf, chosen.peer)) |cookie| queueIssuedCookie(ctx, cookie, true);
    } else {
        incrementMetric(if (direct_target != null) .direct_peer_hits else .hash_hits);
    }

    ngx.log.ngz_log_error(ngx.log.NGX_LOG_DEBUG, pc.*.log, 0,
        "upstream_balancer: sticky hit\x00", .{});

    return core.NGX_OK;
}

// Per-request: release the peer and let the original free_peer update accounting.
export fn upstream_balancer_free_peer(
    pc: [*c]ngx_peer_connection_t,
    data: ?*anyopaque,
    state: ngx_uint_t,
) callconv(.c) void {
    const ctx = @as(*BalancerRequestCtx, @ptrCast(@alignCast(data)));
    const orig_free: *const fn ([*c]ngx_peer_connection_t, ?*anyopaque, ngx_uint_t) callconv(.c) void =
        @ptrCast(@alignCast(ctx.original_free));
    orig_free(pc, ctx.original_data, state);
    releaseDynamicPeerGraph(ctx);
}

/// Install the init_peer wrapper on an upstream that has no sticky directive.
/// Called from dynamic-upstreams postconfiguration, after all init_upstream
/// callbacks have already run and set uscf->peer.init to round-robin's init_peer.
export fn upstream_balancer_ensure_hook(
    us: [*c]ngx_http_upstream_srv_conf_t,
) callconv(.c) ngx_int_t {
    const bcf = core.castPtr(
        BalancerSrvConf,
        conf.ngx_http_conf_upstream_srv_conf(us, &ngx_http_upstream_balancer_module),
    ) orelse return core.NGX_ERROR;

    // Already installed via a sticky directive — nothing to do
    if (bcf.*.original_init_peer != null) return core.NGX_OK;

    // init_upstream has already run; us->peer.init is now round-robin's init_peer
    if (us.*.peer.init == null) return core.NGX_ERROR;

    bcf.*.original_init_peer = @constCast(@ptrCast(us.*.peer.init));
    bcf.*.upstream_name = us.*.host;
    us.*.peer.init = upstream_balancer_init_peer;
    return core.NGX_OK;
}

export fn upstream_balancer_register_peer_source(
    us: [*c]ngx_http_upstream_srv_conf_t,
    source_ctx: ?*anyopaque,
    vtable: ?*const PeerSourceVTable,
) callconv(.c) ngx_int_t {
    const bcf = core.castPtr(
        BalancerSrvConf,
        conf.ngx_http_conf_upstream_srv_conf(us, &ngx_http_upstream_balancer_module),
    ) orelse return core.NGX_ERROR;

    bcf.*.peer_source_ctx = source_ctx;
    bcf.*.peer_source_vtable = vtable;
    return core.NGX_OK;
}

export fn ngx_http_upstream_balancer_header_filter(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    // Only emit Set-Cookie for main requests. Subrequests that happen to
    // pass through this filter must not leak affinity cookies into the
    // parent response.
    if (r == r.*.main) {
        if (core.castPtr(BalancerRequestCtx, r.*.ctx[ngx_http_upstream_balancer_module.ctx_index])) |ctx| {
            if (ctx.*.pending_cookie.len > 0 and ctx.*.pending_cookie.data != null) {
                var headers = NList(ngx_table_elt_t).init0(&r.*.headers_out.headers);
                if (headers.append()) |h| {
                    h.*.hash = 1;
                    h.*.key = string.ngx_string("Set-Cookie");
                    h.*.value = ctx.*.pending_cookie;
                    h.*.lowcase_key = @constCast("set-cookie");
                } else |_| {}
                ctx.*.pending_cookie = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
            }
        }
    }
    if (ngx_http_upstream_balancer_next_header_filter) |next| return next(r);
    return core.NGX_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    var zone_name = string.ngx_string("upstream_balancer_metrics");
    const zone = shm.ngx_shared_memory_add(cf, &zone_name, BALANCER_METRICS_ZONE_SIZE, @constCast(&ngx_http_upstream_balancer_module)) orelse return core.NGX_ERROR;
    zone.*.init = balancer_zone_init;
    ngx_http_upstream_balancer_zone = zone;
    return core.NGX_OK;
}

fn postconfiguration_filter(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    _ = cf;
    ngx_http_upstream_balancer_next_header_filter = http.ngx_http_top_header_filter;
    http.ngx_http_top_header_filter = ngx_http_upstream_balancer_header_filter;
    return core.NGX_OK;
}

export const ngx_http_upstream_balancer_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = create_srv_conf,
    .merge_srv_conf = merge_srv_conf,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_upstream_balancer_filter_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration_filter,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = null,
    .merge_loc_conf = null,
};

export const ngx_http_upstream_balancer_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = string.ngx_string("upstream_balancer_sticky_cookie"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE1,
        .set = set_sticky_cookie,
        .conf = 0,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = string.ngx_string("upstream_balancer_sticky_header"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE1,
        .set = set_sticky_header,
        .conf = 0,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = string.ngx_string("upstream_balancer_fallback"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE1,
        .set = set_fallback,
        .conf = 0,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = string.ngx_string("upstream_balancer_issue_cookie"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE1,
        .set = set_issue_cookie,
        .conf = 0,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = string.ngx_string("upstream_balancer_cookie_attrs"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE1,
        .set = set_cookie_attrs,
        .conf = 0,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = string.ngx_string("upstream_balancer_status"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = set_status_endpoint,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_upstream_balancer_module = ngx.module.make_module(
    @constCast(&ngx_http_upstream_balancer_commands),
    @constCast(&ngx_http_upstream_balancer_module_ctx),
);

export var ngx_http_upstream_balancer_filter_module = ngx.module.make_module(
    @constCast(&[_]ngx_command_t{conf.ngx_null_command}),
    @constCast(&ngx_http_upstream_balancer_filter_module_ctx),
);

test "upstream balancer Phase 1 scaffold" {}

test "triedWordCount rounds peer counts to machine words" {
    try std.testing.expectEqual(@as(usize, 1), triedWordCount(0));
    try std.testing.expectEqual(@as(usize, 1), triedWordCount(1));
    try std.testing.expectEqual(@as(usize, 1), triedWordCount(@intCast(8 * @sizeOf(usize))));
    try std.testing.expectEqual(@as(usize, 2), triedWordCount(@intCast(8 * @sizeOf(usize) + 1)));
}

test "totalPeerCount includes backup peer chains" {
    var peer1 = std.mem.zeroes(ngx_http_upstream_rr_peer_t);
    var peer2 = std.mem.zeroes(ngx_http_upstream_rr_peer_t);
    var backup_peer = std.mem.zeroes(ngx_http_upstream_rr_peer_t);
    peer1.next = &peer2;
    peer2.next = core.nullptr(ngx_http_upstream_rr_peer_t);
    backup_peer.next = core.nullptr(ngx_http_upstream_rr_peer_t);

    var backup_peers = std.mem.zeroes(ngx_http_upstream_rr_peers_t);
    backup_peers.peer = &backup_peer;
    backup_peers.next = core.nullptr(ngx_http_upstream_rr_peers_t);

    var peers = std.mem.zeroes(ngx_http_upstream_rr_peers_t);
    peers.peer = &peer1;
    peers.next = &backup_peers;

    try std.testing.expectEqual(@as(ngx_uint_t, 3), totalPeerCount(&peers));
}

var test_release_generation_calls: usize = 0;
var test_release_generation_value: u64 = 0;
var test_is_peer_draining_calls: usize = 0;
var test_is_peer_draining_source_ctx: ?*anyopaque = null;
var test_is_peer_draining_addr_len: usize = 0;
var test_is_peer_draining_addr: [64]u8 = [_]u8{0} ** 64;

fn testReleaseGeneration(
    source_ctx: ?*anyopaque,
    peers: [*c]ngx_http_upstream_rr_peers_t,
    generation: u64,
) callconv(.c) void {
    _ = source_ctx;
    _ = peers;
    test_release_generation_calls += 1;
    test_release_generation_value = generation;
}

fn testIsPeerDraining(
    source_ctx: ?*anyopaque,
    addr_data: [*c]u8,
    addr_len: usize,
) callconv(.c) c_int {
    test_is_peer_draining_calls += 1;
    test_is_peer_draining_source_ctx = source_ctx;
    test_is_peer_draining_addr_len = addr_len;
    @memset(&test_is_peer_draining_addr, 0);
    @memcpy(test_is_peer_draining_addr[0..addr_len], core.slicify(u8, addr_data, addr_len));
    return 1;
}

test "dynamic peer graph can be pinned and released once per request ctx" {
    test_release_generation_calls = 0;
    test_release_generation_value = 0;

    var peers = std.mem.zeroes(ngx_http_upstream_rr_peers_t);
    var tried_buf = [_]usize{ 0, 0 };
    var rrp = std.mem.zeroes(ngx_http_upstream_rr_peer_data_t);
    var ctx = std.mem.zeroes(BalancerRequestCtx);

    applyDynamicPeerGraph(
        &ctx,
        &rrp,
        &peers,
        @ptrCast(&tried_buf),
        77,
        null,
        @constCast(@ptrCast(&testReleaseGeneration)),
    );

    try std.testing.expectEqual(@as(core.ngx_flag_t, 1), ctx.dynamic_active);
    try std.testing.expectEqual(@as(u64, 77), ctx.dynamic_generation);
    try std.testing.expectEqual(@as([*c]ngx_http_upstream_rr_peers_t, &peers), rrp.peers);
    try std.testing.expectEqual(@as([*c]usize, @ptrCast(&tried_buf)), rrp.tried);

    releaseDynamicPeerGraph(&ctx);
    try std.testing.expectEqual(@as(usize, 1), test_release_generation_calls);
    try std.testing.expectEqual(@as(u64, 77), test_release_generation_value);
    try std.testing.expectEqual(@as(core.ngx_flag_t, 0), ctx.dynamic_active);

    releaseDynamicPeerGraph(&ctx);
    try std.testing.expectEqual(@as(usize, 1), test_release_generation_calls);
}

test "peer source draining helper fail-opens without callback" {
    var addr = [_]u8{ '1', '2', '7', '.', '0', '.', '0', '.', '1', ':', '8', '0', '8', '0' };
    try std.testing.expect(!peerSourceIsDraining(null, null, &addr, addr.len));

    const vtable = PeerSourceVTable{
        .get_active_peers = null,
        .release_generation = null,
        .is_peer_draining = null,
    };
    try std.testing.expect(!peerSourceIsDraining(null, &vtable, &addr, addr.len));
}

test "peer source draining helper delegates to callback" {
    test_is_peer_draining_calls = 0;
    test_is_peer_draining_source_ctx = null;
    test_is_peer_draining_addr_len = 0;
    @memset(&test_is_peer_draining_addr, 0);

    var source_value: u8 = 7;
    var addr = [_]u8{ '1', '0', '.', '0', '.', '0', '.', '1', ':', '9', '0', '0', '0' };
    const vtable = PeerSourceVTable{
        .get_active_peers = null,
        .release_generation = null,
        .is_peer_draining = @constCast(@ptrCast(&testIsPeerDraining)),
    };

    try std.testing.expect(peerSourceIsDraining(&source_value, &vtable, &addr, addr.len));
    try std.testing.expectEqual(@as(usize, 1), test_is_peer_draining_calls);
    try std.testing.expectEqual(@intFromPtr(&source_value), @intFromPtr(test_is_peer_draining_source_ctx.?));
    try std.testing.expectEqual(addr.len, test_is_peer_draining_addr_len);
    try std.testing.expectEqualSlices(u8, addr[0..], test_is_peer_draining_addr[0..addr.len]);
}
