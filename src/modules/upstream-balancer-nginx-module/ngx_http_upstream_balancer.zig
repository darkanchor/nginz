const std = @import("std");
const ngx = @import("ngx");

const conf = ngx.conf;
const core = ngx.core;
const http = ngx.http;
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
const ngx_http_upstream_rr_peer_t = http.ngx_http_upstream_rr_peer_t;

extern var ngx_http_upstream_module: ngx_module_t;

// Provided by the healthcheck module. Returns 1 if the peer is eligible
// (healthy or not monitored), 0 if a configured probe marks it unhealthy.
extern fn ngz_healthcheck_is_peer_eligible(addr_data: [*c]u8, addr_len: usize) callconv(.c) c_int;

extern fn ngx_http_upstream_init_round_robin(
    cf: [*c]ngx_conf_t,
    us: [*c]ngx_http_upstream_srv_conf_t,
) callconv(.c) ngx_int_t;

const STICKY_OFF: c_int = 0;
const STICKY_COOKIE: c_int = 1;
const STICKY_HEADER: c_int = 2;

const FALLBACK_NEXT: c_int = 0;
const FALLBACK_OFF: c_int = 1;

// Per-upstream configuration stored in uscf->srv_conf[ctx_index].
const BalancerSrvConf = extern struct {
    sticky_mode: c_int,
    fallback_mode: c_int,
    key_name: ngx_str_t,
    var_index: ngx_int_t,
    original_init_upstream: ?*anyopaque,
    original_init_peer: ?*anyopaque,
};

// Per-request context allocated from r->pool.
const BalancerRequestCtx = extern struct {
    conf_ptr: ?*anyopaque,
    request_ptr: ?*anyopaque,
    original_data: ?*anyopaque,
    original_get: ?*anyopaque,
    original_free: ?*anyopaque,
    sticky_used: c_int,
};

fn configError(cf: [*c]ngx_conf_t, comptime msg: []const u8) [*c]u8 {
    ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, cf.*.log, 0, msg ++ "\x00", .{});
    return conf.NGX_CONF_ERROR;
}

fn create_srv_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const bcf = core.ngz_pcalloc(BalancerSrvConf, cf.*.pool) orelse return null;
    bcf.sticky_mode = STICKY_OFF;
    bcf.fallback_mode = FALLBACK_NEXT;
    bcf.var_index = core.NGX_ERROR;
    return @ptrCast(bcf);
}

fn merge_srv_conf(cf: [*c]ngx_conf_t, parent: ?*anyopaque, child: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    _ = parent;
    _ = child;
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

    u.*.peer.get = upstream_balancer_get_peer;
    u.*.peer.free = upstream_balancer_free_peer;
    u.*.peer.data = @ptrCast(ctx);

    return core.NGX_OK;
}

// A peer is eligible if nginx hasn't marked it down AND the healthcheck module
// (when loaded) considers it healthy. Fail-open: no probe entry → eligible.
fn is_eligible(p: [*c]ngx_http_upstream_rr_peer_t) bool {
    if (p.*.down != 0) return false;
    return ngz_healthcheck_is_peer_eligible(p.*.name.data, p.*.name.len) != 0;
}

// Count eligible peers in the primary peer linked list.
fn count_eligible(peers: [*c]ngx_http_upstream_rr_peer_t) ngx_uint_t {
    var n: ngx_uint_t = 0;
    var p = peers;
    while (p != null) : (p = p.*.next) {
        if (is_eligible(p)) n += 1;
    }
    return n;
}

// Walk the linked list and return the peer at the given position among eligible peers.
fn peer_at(peers: [*c]ngx_http_upstream_rr_peer_t, pos: ngx_uint_t) ?[*c]ngx_http_upstream_rr_peer_t {
    var idx: ngx_uint_t = 0;
    var p = peers;
    while (p != null) : (p = p.*.next) {
        if (!is_eligible(p)) continue;
        if (idx == pos) return p;
        idx += 1;
    }
    return null;
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

    // Extract affinity key via nginx variable system.
    const r = @as([*c]ngx_http_request_t, @ptrCast(@alignCast(ctx.request_ptr)));
    const vv = http.ngx_http_get_flushed_variable(r, @intCast(bcf.*.var_index));
    const key_absent = (vv == null) or vv.*.flags.not_found or (vv.*.flags.len == 0);

    if (key_absent) {
        if (bcf.*.fallback_mode == FALLBACK_OFF) {
            ngx.log.ngz_log_error(ngx.log.NGX_LOG_DEBUG, pc.*.log, 0,
                "upstream_balancer: sticky key absent, fallback off\x00", .{});
            return core.NGX_BUSY;
        }
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_DEBUG, pc.*.log, 0,
            "upstream_balancer: sticky key absent, fallback next\x00", .{});
        return orig_get(pc, ctx.original_data);
    }

    // Deterministic mapping: crc32(key) % eligible_peer_count.
    // Affinity contract: same key, same generation → same peer index.
    const key = core.slicify(u8, vv.*.data, vv.*.flags.len);
    const hash = std.hash.crc.Crc32.hash(key);

    const rrp = @as([*c]ngx_http_upstream_rr_peer_data_t, @ptrCast(@alignCast(ctx.original_data)));
    const head = rrp.*.peers.*.peer;

    const eligible = count_eligible(head);
    if (eligible == 0) {
        if (bcf.*.fallback_mode == FALLBACK_OFF) return core.NGX_BUSY;
        return orig_get(pc, ctx.original_data);
    }

    const pos = @as(ngx_uint_t, hash) % eligible;
    const chosen = peer_at(head, pos) orelse {
        if (bcf.*.fallback_mode == FALLBACK_OFF) return core.NGX_BUSY;
        return orig_get(pc, ctx.original_data);
    };

    pc.*.sockaddr = chosen.*.sockaddr;
    pc.*.socklen = chosen.*.socklen;
    pc.*.name = &chosen.*.name;
    chosen.*.conns += 1;
    rrp.*.current = chosen;
    ctx.sticky_used = 1;

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
}

export const ngx_http_upstream_balancer_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = null,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = create_srv_conf,
    .merge_srv_conf = merge_srv_conf,
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
    conf.ngx_null_command,
};

export var ngx_http_upstream_balancer_module = ngx.module.make_module(
    @constCast(&ngx_http_upstream_balancer_commands),
    @constCast(&ngx_http_upstream_balancer_module_ctx),
);

test "upstream balancer Phase 1 scaffold" {}
