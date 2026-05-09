const std = @import("std");
const ngx = @import("ngx");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const shm = ngx.shm;
const event = ngx.event;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;

const ngx_str_t = core.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_msec_t = core.ngx_msec_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;

const ngx_string = ngx.string.ngx_string;
const NArray = ngx.array.NArray;

extern var ngx_http_core_module: ngx_module_t;
extern var ngx_http_upstream_module: ngx_module_t;
extern var ngx_worker: ngx_uint_t;
extern var ngx_http_worker_events_default_zone: [*c]core.ngx_shm_zone_t;
extern fn ngx_http_worker_events_publish_internal(
    zone: [*c]core.ngx_shm_zone_t,
    channel_str: ngx_str_t,
    type_str: ngx_str_t,
    payload_str: ngx_str_t,
) callconv(.c) ngx_int_t;

const HEALTHCHECK_ZONE_SIZE: usize = 64 * 1024;
const UPSTREAM_ZONE_SIZE: usize = 32 * 1024;
const MAX_PROBE_HOST_LEN: usize = 255;
const MAX_PROBE_PATH_LEN: usize = 255;
const MAX_JSON_RESPONSE_LEN: usize = 8192;
const MAX_UPSTREAM_PROBES: usize = 32;
const MAX_UPSTREAM_NAME_LEN: usize = 127;

const AF_UNSPEC: c_int = 0;
const SOCK_STREAM: c_int = 1;
const SOL_SOCKET_C: c_int = 1;
const SO_RCVTIMEO_C: c_int = 20;
const SO_SNDTIMEO_C: c_int = 21;

const Timeval = extern struct {
    tv_sec: i64,
    tv_usec: i64,
};

const SockAddr = extern struct {
    sa_family: u16,
    sa_data: [14]u8,
};

const AddrInfo = extern struct {
    ai_flags: c_int,
    ai_family: c_int,
    ai_socktype: c_int,
    ai_protocol: c_int,
    ai_addrlen: u32,
    ai_addr: ?*SockAddr,
    ai_canonname: [*c]u8,
    ai_next: ?*AddrInfo,
};

extern fn socket(domain: c_int, type_: c_int, protocol: c_int) c_int;
extern fn connect(fd: c_int, addr: *const anyopaque, len: u32) c_int;
extern fn send(fd: c_int, buf: *const anyopaque, len: usize, flags: c_int) isize;
extern fn recv(fd: c_int, buf: *anyopaque, len: usize, flags: c_int) isize;
extern fn close(fd: c_int) c_int;
extern fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: u32) c_int;
extern fn getaddrinfo(node: [*:0]const u8, service: [*:0]const u8, hints: ?*const AddrInfo, res: [*c]?*AddrInfo) c_int;
extern fn freeaddrinfo(res: ?*AddrInfo) void;

// ── OpenSSL / TLS externs (used for HTTPS probes) ──────────────────────────

const SSL_CTX = opaque {};
const SSL = opaque {};
extern fn TLS_client_method() ?*SSL_CTX;
extern fn SSL_CTX_new(method: ?*SSL_CTX) ?*SSL_CTX;
extern fn SSL_new(ctx: ?*SSL_CTX) ?*SSL;
extern fn SSL_set_fd(ssl: ?*SSL, fd: c_int) c_int;
extern fn SSL_connect(ssl: ?*SSL) c_int;
extern fn SSL_read(ssl: ?*SSL, buf: [*c]u8, num: c_int) c_int;
extern fn SSL_write(ssl: ?*SSL, buf: [*c]const u8, num: c_int) c_int;
extern fn SSL_shutdown(ssl: ?*SSL) c_int;
extern fn SSL_free(ssl: ?*SSL) void;
extern fn SSL_CTX_free(ctx: ?*SSL_CTX) void;

// ── Probe feature flags ─────────────────────────────────────────────────────

const PROBE_FLAG_TLS: u8 = 1 << 0;
const PROBE_FLAG_HAS_MATCH: u8 = 1 << 1;

// ── Match rule config ───────────────────────────────────────────────────────

const MAX_PROBE_MATCH_BODY_LEN: usize = 255;

const ProbeMatchConfig = struct {
    status_min: ngx_uint_t, // 0 = don't check status range
    status_max: ngx_uint_t,
    body_len: usize, // 0 = don't check body
    body_buf: [MAX_PROBE_MATCH_BODY_LEN]u8,
};

const ProbeMatchResult = struct {
    status_ok: bool,
    body_ok: bool,
};

// ── Config structs ───────────────────────────────────────────────────────────

const healthcheck_loc_conf = extern struct {
    status_enabled: ngx_flag_t,
    liveness_enabled: ngx_flag_t,
    readiness_enabled: ngx_flag_t,
    worker_events_channel: ngx_str_t,
};

// Per-upstream probe config stored in upstream {} srv_conf.
const healthcheck_ups_conf = extern struct {
    probe_enabled: ngx_flag_t,
    probe_interval_ms: ngx_msec_t,
    probe_timeout_ms: ngx_msec_t,
    probe_fail_threshold: ngx_uint_t,
    probe_pass_threshold: ngx_uint_t,
    probe_slow_start_ms: ngx_msec_t,
    probe_port: ngx_uint_t,
    probe_host_len: usize,
    probe_path_len: usize,
    probe_flags: u8, // PROBE_FLAG_TLS, PROBE_FLAG_HAS_MATCH
    probe_host_buf: [MAX_PROBE_HOST_LEN]u8,
    probe_path_buf: [MAX_PROBE_PATH_LEN]u8,
    match_status_min: ngx_uint_t,
    match_status_max: ngx_uint_t,
    match_body_len: usize,
    match_body_buf: [MAX_PROBE_MATCH_BODY_LEN]u8,
};

// ── Shared memory layout ─────────────────────────────────────────────────────

const healthcheck_store = extern struct {
    initialized: ngx_flag_t,
    ready: ngx_flag_t,
    probe_enabled: ngx_flag_t,
    probe_healthy: ngx_flag_t,
    total_requests: u64,
    failed_requests: u64,
    probe_last_status: ngx_uint_t,
    probe_last_checked_ms: i64,
    probe_last_started_ms: i64,
    probe_consecutive_successes: u32,
    probe_consecutive_failures: u32,
    probe_total_successes: u64,
    probe_total_failures: u64,
    // Slow-start recovery: ms elapsed since recovery began.
    // When > 0 and < slow_start_ms, the peer is in ramp-up.
    probe_slow_start_elapsed_ms: i64,
    probe_recovered_at_ms: i64,
};

// ── Read-only snapshots (not in shared memory) ───────────────────────────────

const healthcheck_snapshot = struct {
    ready: bool,
    probe_enabled: bool,
    probe_healthy: bool,
    total_requests: u64,
    failed_requests: u64,
    probe_last_status: ngx_uint_t,
    probe_last_checked_ms: i64,
    probe_last_started_ms: i64,
    probe_consecutive_successes: u32,
    probe_consecutive_failures: u32,
    probe_total_successes: u64,
    probe_total_failures: u64,
    probe_slow_start_elapsed_ms: i64,
    probe_recovered_at_ms: i64,
};

const upstream_snapshot = struct {
    name: []const u8,
    probe_healthy: bool,
    probe_last_status: ngx_uint_t,
    probe_last_checked_ms: i64,
    probe_last_started_ms: i64,
    probe_total_successes: u64,
    probe_total_failures: u64,
    probe_consecutive_successes: u32,
    probe_consecutive_failures: u32,
    probe_slow_start_elapsed_ms: i64,
    probe_recovered_at_ms: i64,
};

const peer_snapshot = struct {
    upstream_name: []const u8,
    peer_addr: []const u8,
    probe_healthy: bool,
    probe_last_status: ngx_uint_t,
    probe_last_checked_ms: i64,
    probe_last_started_ms: i64,
    probe_total_successes: u64,
    probe_total_failures: u64,
    probe_consecutive_successes: u32,
    probe_consecutive_failures: u32,
    probe_slow_start_elapsed_ms: i64,
    probe_recovered_at_ms: i64,
};

const ProbeResult = struct {
    success: bool,
    status: ngx_uint_t,
    match_status_ok: bool,
    match_body_ok: bool,
};

// ── Per-upstream probe tracking (worker-local, stable global array) ──────────

const MAX_PEER_PROBES: usize = 64;
const MAX_PEER_ADDR_LEN: usize = 63;
const PEER_PROBE_INDEX_SLOTS: usize = 128;

const PeerProbeEntry = struct {
    interval_ms: ngx_msec_t,
    timeout_ms: ngx_msec_t,
    fail_threshold: ngx_uint_t,
    pass_threshold: ngx_uint_t,
    slow_start_ms: ngx_msec_t,
    port: u16,
    host_len: usize,
    path_len: usize,
    addr_len: usize,
    flags: u8, // PROBE_FLAG_TLS, PROBE_FLAG_HAS_MATCH
    host_buf: [MAX_PROBE_HOST_LEN + 1]u8,
    path_buf: [MAX_PROBE_PATH_LEN]u8,
    addr_buf: [MAX_PEER_ADDR_LEN + 1]u8,
    name_buf: [MAX_UPSTREAM_NAME_LEN + 1]u8, // parent upstream name
    name_len: usize,
    zone: [*c]core.ngx_shm_zone_t,
    timer: core.ngx_event_t,
    match_status_min: ngx_uint_t,
    match_status_max: ngx_uint_t,
    match_body_len: usize,
    match_body_buf: [MAX_PROBE_MATCH_BODY_LEN]u8,
};

const UpstreamProbeEntry = struct {
    interval_ms: ngx_msec_t,
    timeout_ms: ngx_msec_t,
    fail_threshold: ngx_uint_t,
    pass_threshold: ngx_uint_t,
    slow_start_ms: ngx_msec_t,
    port: u16,
    host_len: usize,
    path_len: usize,
    flags: u8, // PROBE_FLAG_TLS, PROBE_FLAG_HAS_MATCH
    host_buf: [MAX_PROBE_HOST_LEN + 1]u8, // null-terminated for getaddrinfo
    path_buf: [MAX_PROBE_PATH_LEN]u8,
    name_len: usize,
    name_buf: [MAX_UPSTREAM_NAME_LEN + 1]u8,
    zone: [*c]core.ngx_shm_zone_t,
    timer: core.ngx_event_t,
    match_status_min: ngx_uint_t,
    match_status_max: ngx_uint_t,
    match_body_len: usize,
    match_body_buf: [MAX_PROBE_MATCH_BODY_LEN]u8,
};

// ── Module-level globals ─────────────────────────────────────────────────────

var ngx_http_healthcheck_zone: [*c]core.ngx_shm_zone_t = core.nullptr(core.ngx_shm_zone_t);
var probe_timer_event: core.ngx_event_t = std.mem.zeroes(core.ngx_event_t);

var healthcheck_probe_enabled: bool = false;
var healthcheck_probe_interval_ms: ngx_msec_t = 5000;
var healthcheck_probe_timeout_ms: ngx_msec_t = 1000;
var healthcheck_probe_fail_threshold: ngx_uint_t = 2;
var healthcheck_probe_pass_threshold: ngx_uint_t = 1;
var healthcheck_probe_slow_start_ms: ngx_msec_t = 0;
var healthcheck_probe_port: u16 = 80;
var healthcheck_probe_host_len: usize = 0;
var healthcheck_probe_path_len: usize = 1;
var healthcheck_probe_flags: u8 = 0; // PROBE_FLAG_TLS, PROBE_FLAG_HAS_MATCH
var healthcheck_probe_host_buf: [MAX_PROBE_HOST_LEN]u8 = [_]u8{0} ** MAX_PROBE_HOST_LEN;
var healthcheck_probe_path_buf: [MAX_PROBE_PATH_LEN]u8 = [_]u8{0} ** MAX_PROBE_PATH_LEN;
var healthcheck_probe_match_status_min: ngx_uint_t = 0;
var healthcheck_probe_match_status_max: ngx_uint_t = 0;
var healthcheck_probe_match_body_len: usize = 0;
var healthcheck_probe_match_body_buf: [MAX_PROBE_MATCH_BODY_LEN]u8 = [_]u8{0} ** MAX_PROBE_MATCH_BODY_LEN;
var healthcheck_worker_events_channel: ngx_str_t = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };

var upstream_probes: [MAX_UPSTREAM_PROBES]UpstreamProbeEntry = undefined;
var upstream_probe_count: usize = 0;

var peer_probes: [MAX_PEER_PROBES]PeerProbeEntry = undefined;
var peer_probe_count: usize = 0;
var peer_probe_index_slots: [PEER_PROBE_INDEX_SLOTS]u8 = [_]u8{0} ** PEER_PROBE_INDEX_SLOTS;

// ── Shared memory helpers ────────────────────────────────────────────────────

fn getStore() ?[*c]healthcheck_store {
    if (ngx_http_healthcheck_zone == core.nullptr(core.ngx_shm_zone_t)) return null;
    return core.castPtr(healthcheck_store, ngx_http_healthcheck_zone.*.data);
}

fn getShpool() ?[*c]core.ngx_slab_pool_t {
    const zone = ngx_http_healthcheck_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.shm.addr == null or zone.*.data == null) {
        return null;
    }
    return core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr);
}

fn getUpstreamStore(entry: *UpstreamProbeEntry) ?[*c]healthcheck_store {
    const zone = entry.zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.data == null) return null;
    return core.castPtr(healthcheck_store, zone.*.data);
}

fn getUpstreamShpool(entry: *UpstreamProbeEntry) ?[*c]core.ngx_slab_pool_t {
    const zone = entry.zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.shm.addr == null or zone.*.data == null) return null;
    return core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr);
}

fn getCurrentTimeMs() i64 {
    const tp = core.ngx_timeofday();
    if (tp) |t| {
        return @as(i64, @intCast(t.*.sec)) * 1000 + @as(i64, @intCast(t.*.msec));
    }
    return 0;
}

fn publishHealthTransition(healthy: bool, status: ngx_uint_t, checked_at_ms: i64) void {
    const zone = ngx_http_worker_events_default_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return;
    if (healthcheck_worker_events_channel.len == 0 or healthcheck_worker_events_channel.data == null) return;

    const event_type = ngx_string("transition");
    var payload_buf: [192]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &payload_buf,
        "{{\"scope\":\"service\",\"healthy\":{s},\"status\":{d},\"checked_at_msec\":{d}}}",
        .{ if (healthy) "true" else "false", status, checked_at_ms },
    ) catch return;

    const payload_str = ngx_str_t{ .len = payload.len, .data = @constCast(payload.ptr) };
    _ = ngx_http_worker_events_publish_internal(zone, healthcheck_worker_events_channel, event_type, payload_str);
}

// ── Zone init callbacks ──────────────────────────────────────────────────────

fn healthcheck_zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        zone.*.data = data;
        return NGX_OK;
    }

    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        zone.*.data = shpool.*.data;
        return NGX_OK;
    }

    const store_mem = shm.ngx_slab_calloc(shpool, @sizeOf(healthcheck_store)) orelse return NGX_ERROR;
    const store = core.castPtr(healthcheck_store, store_mem) orelse return NGX_ERROR;
    store.* = std.mem.zeroes(healthcheck_store);
    store.*.initialized = 1;
    store.*.ready = 1;
    store.*.probe_healthy = 1;
    store.*.probe_enabled = if (healthcheck_probe_enabled) 1 else 0;
    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

fn upstream_probe_zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        zone.*.data = data;
        return NGX_OK;
    }

    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        zone.*.data = shpool.*.data;
        return NGX_OK;
    }

    const store_mem = shm.ngx_slab_calloc(shpool, @sizeOf(healthcheck_store)) orelse return NGX_ERROR;
    const store = core.castPtr(healthcheck_store, store_mem) orelse return NGX_ERROR;
    store.* = std.mem.zeroes(healthcheck_store);
    store.*.initialized = 1;
    store.*.ready = 1;
    store.*.probe_healthy = 1;
    store.*.probe_enabled = 1;
    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

// ── Location and upstream config lifecycle ───────────────────────────────────

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(healthcheck_loc_conf, cf.*.pool)) |p| {
        p.*.status_enabled = 0;
        p.*.liveness_enabled = 0;
        p.*.readiness_enabled = 0;
        p.*.worker_events_channel = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
        return p;
    }
    return null;
}

fn merge_loc_conf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cf;
    const prev = core.castPtr(healthcheck_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(healthcheck_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.status_enabled == 0) c.*.status_enabled = prev.*.status_enabled;
    if (c.*.liveness_enabled == 0) c.*.liveness_enabled = prev.*.liveness_enabled;
    if (c.*.readiness_enabled == 0) c.*.readiness_enabled = prev.*.readiness_enabled;
    if (c.*.worker_events_channel.len == 0) c.*.worker_events_channel = prev.*.worker_events_channel;

    return conf.NGX_CONF_OK;
}

// Called for each upstream {} block; allocates per-upstream probe config.
fn create_srv_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(healthcheck_ups_conf, cf.*.pool)) |p| {
        // Memory is zero-initialized by ngz_pcalloc_c (calloc). Only set non-zero defaults.
        p.*.probe_interval_ms = 5000;
        p.*.probe_timeout_ms = 1000;
        p.*.probe_fail_threshold = 2;
        p.*.probe_pass_threshold = 1;
        return p;
    }
    return null;
}

fn merge_srv_conf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cf;
    _ = parent;
    _ = child;
    // Each upstream {} is independent; no inheritance needed.
    return conf.NGX_CONF_OK;
}

// ── Probe target parsing ─────────────────────────────────────────────────────

fn parseDurationMs(value: []const u8) ?ngx_msec_t {
    if (value.len == 0) return null;
    if (std.mem.endsWith(u8, value, "ms")) {
        return std.fmt.parseInt(ngx_msec_t, value[0 .. value.len - 2], 10) catch null;
    }
    if (std.mem.endsWith(u8, value, "s")) {
        const secs = std.fmt.parseInt(ngx_msec_t, value[0 .. value.len - 1], 10) catch return null;
        return secs * 1000;
    }
    return std.fmt.parseInt(ngx_msec_t, value, 10) catch null;
}

fn configError(cf: [*c]ngx_conf_t, msg: []const u8) [*c]u8 {
    ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, cf.*.log, 0, core.c_str(msg), .{});
    return conf.NGX_CONF_ERROR;
}

// Parse http[s]://host:port/path and write into the provided buffers.
// Returns false on any validation failure.
fn parseProbeTarget(
    raw_target: []const u8,
    host_buf: []u8,
    path_buf: []u8,
    host_len_out: *usize,
    path_len_out: *usize,
    port_out: *u16,
    flags_out: *u8,
) bool {
    var is_tls = false;
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, raw_target, "https://")) {
        is_tls = true;
        rest = raw_target[8..];
    } else if (std.mem.startsWith(u8, raw_target, "http://")) {
        rest = raw_target[7..];
    } else {
        return false;
    }

    const slash_index = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash_index];
    const path = if (slash_index < rest.len) rest[slash_index..] else "/";

    if (host_port.len == 0 or path.len == 0 or path.len > MAX_PROBE_PATH_LEN) return false;
    if (std.mem.indexOfScalar(u8, host_port, '[') != null or
        std.mem.indexOfScalar(u8, host_port, ']') != null) return false;

    const colon_index = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return false;
    if (colon_index == 0 or colon_index + 1 >= host_port.len) return false;

    const host = host_port[0..colon_index];
    const port_raw = host_port[colon_index + 1 ..];
    const port = std.fmt.parseInt(u16, port_raw, 10) catch return false;

    if (host.len == 0 or host.len > MAX_PROBE_HOST_LEN) return false;
    if (host_buf.len < host.len or path_buf.len < path.len) return false;

    @memset(host_buf, 0);
    @memcpy(host_buf[0..host.len], host);
    host_len_out.* = host.len;

    @memset(path_buf, 0);
    @memcpy(path_buf[0..path.len], path);
    path_len_out.* = path.len;

    port_out.* = port;
    if (is_tls) {
        flags_out.* |= PROBE_FLAG_TLS;
    }
    return true;
}

fn applyProbeTarget(raw_target: []const u8) bool {
    var port: u16 = 0;
    var flags: u8 = 0;
    const ok = parseProbeTarget(
        raw_target,
        &healthcheck_probe_host_buf,
        &healthcheck_probe_path_buf,
        &healthcheck_probe_host_len,
        &healthcheck_probe_path_len,
        &port,
        &flags,
    );
    if (ok) {
        healthcheck_probe_port = port;
        healthcheck_probe_flags = flags;
        healthcheck_probe_enabled = true;
    }
    return ok;
}

fn applyProbeTargetToConf(ups_conf: *healthcheck_ups_conf, raw_target: []const u8) bool {
    var port: u16 = 0;
    var host_len: usize = 0;
    var path_len: usize = 0;
    var flags: u8 = 0;
    const ok = parseProbeTarget(
        raw_target,
        &ups_conf.probe_host_buf,
        &ups_conf.probe_path_buf,
        &host_len,
        &path_len,
        &port,
        &flags,
    );
    if (ok) {
        ups_conf.probe_host_len = host_len;
        ups_conf.probe_path_len = path_len;
        ups_conf.probe_port = port;
        ups_conf.probe_flags = flags;
        ups_conf.probe_enabled = 1;
    }
    return ok;
}

// ── Core probe execution ─────────────────────────────────────────────────────

fn performProbeWith(
    host_cstr: [*:0]const u8,
    host_slice: []const u8,
    path_slice: []const u8,
    port: u16,
    timeout_ms: ngx_msec_t,
    use_tls: bool,
    match_status_min: ngx_uint_t,
    match_status_max: ngx_uint_t,
    match_body: []const u8,
) ProbeResult {
    var port_buf: [6:0]u8 = [_:0]u8{0} ** 6;
    const port_slice = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return .{ .success = false, .status = 0, .match_status_ok = true, .match_body_ok = true };
    port_buf[port_slice.len] = 0;

    var hints = std.mem.zeroes(AddrInfo);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    var results: ?*AddrInfo = null;
    if (getaddrinfo(host_cstr, port_buf[0..port_slice.len :0], &hints, &results) != 0 or results == null) {
        return .{ .success = false, .status = 0, .match_status_ok = true, .match_body_ok = true };
    }
    defer freeaddrinfo(results);

    var request_buf: [1024]u8 = undefined;
    const request = std.fmt.bufPrint(
        &request_buf,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\nUser-Agent: nginz-healthcheck\r\n\r\n",
        .{ path_slice, host_slice },
    ) catch return .{ .success = false, .status = 0, .match_status_ok = true, .match_body_ok = true };

    var it = results;
    while (it) |ai| : (it = ai.ai_next) {
        if (ai.ai_addr == null) continue;

        const fd = socket(ai.ai_family, if (ai.ai_socktype != 0) ai.ai_socktype else SOCK_STREAM, ai.ai_protocol);
        if (fd < 0) continue;

        const timeout = Timeval{
            .tv_sec = @intCast(timeout_ms / 1000),
            .tv_usec = @intCast((timeout_ms % 1000) * 1000),
        };
        _ = setsockopt(fd, SOL_SOCKET_C, SO_RCVTIMEO_C, &timeout, @sizeOf(Timeval));
        _ = setsockopt(fd, SOL_SOCKET_C, SO_SNDTIMEO_C, &timeout, @sizeOf(Timeval));

        if (connect(fd, ai.ai_addr.?, ai.ai_addrlen) != 0) {
            _ = close(fd);
            continue;
        }

        // TLS handshake if HTTPS target
        var ssl: ?*SSL = null;
        if (use_tls) {
            const method = TLS_client_method();
            if (method) |m| {
                const ctx = SSL_CTX_new(m);
                if (ctx) |c| {
                    ssl = SSL_new(c);
                    if (ssl) |s| {
                        _ = SSL_set_fd(s, fd);
                        if (SSL_connect(s) != 1) {
                            SSL_free(s);
                            SSL_CTX_free(c);
                            _ = close(fd);
                            continue;
                        }
                    } else {
                        SSL_CTX_free(c);
                    }
                }
            }
            if (ssl == null) {
                _ = close(fd);
                continue;
            }
        }

        var sent_total: usize = 0;
        while (sent_total < request.len) {
            var sent: isize = undefined;
            if (ssl) |s| {
                sent = @intCast(SSL_write(s, request.ptr + sent_total, @intCast(request.len - sent_total)));
            } else {
                sent = send(fd, request.ptr + sent_total, request.len - sent_total, 0);
            }
            if (sent <= 0) {
                if (ssl) |s| {
                    _ = SSL_shutdown(s);
                    SSL_free(s);
                }
                _ = close(fd);
                return .{ .success = false, .status = 0, .match_status_ok = true, .match_body_ok = true };
            }
            sent_total += @intCast(sent);
        }

        var response_buf: [4096]u8 = undefined;
        const received: isize = if (ssl) |s|
            @intCast(SSL_read(s, &response_buf, @intCast(response_buf.len)))
        else
            recv(fd, &response_buf, response_buf.len, 0);

        if (received <= 0) {
            if (ssl) |s| {
                _ = SSL_shutdown(s);
                SSL_free(s);
            }
            _ = close(fd);
            return .{ .success = false, .status = 0, .match_status_ok = true, .match_body_ok = true };
        }

        const received_slice = response_buf[0..@intCast(received)];
        if (ssl) |s| {
            _ = SSL_shutdown(s);
            SSL_free(s);
        }
        _ = close(fd);

        if (!std.mem.startsWith(u8, received_slice, "HTTP/")) {
            return .{ .success = false, .status = 0, .match_status_ok = true, .match_body_ok = true };
        }

        const first_space = std.mem.indexOfScalar(u8, received_slice, ' ') orelse {
            return .{ .success = false, .status = 0, .match_status_ok = true, .match_body_ok = true };
        };
        const second_space_rel = std.mem.indexOfScalar(u8, received_slice[first_space + 1 ..], ' ') orelse {
            return .{ .success = false, .status = 0, .match_status_ok = true, .match_body_ok = true };
        };
        const status_slice = received_slice[first_space + 1 .. first_space + 1 + second_space_rel];
        const status = std.fmt.parseInt(ngx_uint_t, status_slice, 10) catch {
            return .{ .success = false, .status = 0, .match_status_ok = true, .match_body_ok = true };
        };

        // Evaluate match rules
        var match_ok_status = true;
        var match_ok_body = true;

        if (match_status_min > 0 and match_status_max > 0) {
            match_ok_status = status >= match_status_min and status <= match_status_max;
        }

        if (match_body.len > 0) {
            // Find the body (after \r\n\r\n)
            const header_end = std.mem.indexOf(u8, received_slice, "\r\n\r\n");
            if (header_end) |he| {
                const body = received_slice[he + 4 ..];
                match_ok_body = std.mem.indexOf(u8, body, match_body) != null;
            } else {
                match_ok_body = false;
            }
        }

        const base_success = status >= 200 and status < 400;
        const success = base_success and match_ok_status and match_ok_body;
        return .{ .success = success, .status = status, .match_status_ok = match_ok_status, .match_body_ok = match_ok_body };
    }

    return .{ .success = false, .status = 0, .match_status_ok = true, .match_body_ok = true };
}

fn performActiveProbe() ProbeResult {
    if (!healthcheck_probe_enabled or healthcheck_probe_host_len == 0) {
        return .{ .success = true, .status = 0, .match_status_ok = true, .match_body_ok = true };
    }
    var host_cstr_buf: [MAX_PROBE_HOST_LEN + 1]u8 = [_]u8{0} ** (MAX_PROBE_HOST_LEN + 1);
    @memcpy(host_cstr_buf[0..healthcheck_probe_host_len], healthcheck_probe_host_buf[0..healthcheck_probe_host_len]);
    return performProbeWith(
        host_cstr_buf[0..healthcheck_probe_host_len :0],
        healthcheck_probe_host_buf[0..healthcheck_probe_host_len],
        healthcheck_probe_path_buf[0..healthcheck_probe_path_len],
        healthcheck_probe_port,
        healthcheck_probe_timeout_ms,
        (healthcheck_probe_flags & PROBE_FLAG_TLS) != 0,
        healthcheck_probe_match_status_min,
        healthcheck_probe_match_status_max,
        healthcheck_probe_match_body_buf[0..healthcheck_probe_match_body_len],
    );
}

fn performUpstreamProbe(entry: *const UpstreamProbeEntry) ProbeResult {
    return performProbeWith(
        entry.host_buf[0..entry.host_len :0],
        entry.host_buf[0..entry.host_len],
        entry.path_buf[0..entry.path_len],
        entry.port,
        entry.timeout_ms,
        (entry.flags & PROBE_FLAG_TLS) != 0,
        entry.match_status_min,
        entry.match_status_max,
        entry.match_body_buf[0..entry.match_body_len],
    );
}

fn performPeerProbe(entry: *const PeerProbeEntry) ProbeResult {
    return performProbeWith(
        entry.host_buf[0..entry.host_len :0],
        entry.host_buf[0..entry.host_len],
        entry.path_buf[0..entry.path_len],
        entry.port,
        entry.timeout_ms,
        (entry.flags & PROBE_FLAG_TLS) != 0,
        entry.match_status_min,
        entry.match_status_max,
        entry.match_body_buf[0..entry.match_body_len],
    );
}

// ── Probe result recording ───────────────────────────────────────────────────

fn recordProbeResult(result: ProbeResult) void {
    const store = getStore() orelse return;
    const shpool = getShpool() orelse return;
    var emit_transition = false;
    var transition_healthy = false;
    const transition_status: ngx_uint_t = result.status;
    var transition_checked_at: i64 = 0;

    shm.ngx_shmtx_lock(&shpool.*.mutex);

    const now = getCurrentTimeMs();
    store.*.probe_enabled = if (healthcheck_probe_enabled) 1 else 0;
    store.*.probe_last_status = result.status;
    store.*.probe_last_checked_ms = now;

    if (result.success) {
        store.*.probe_total_successes += 1;
        store.*.probe_consecutive_successes += 1;
        store.*.probe_consecutive_failures = 0;
        if (store.*.probe_consecutive_successes >= healthcheck_probe_pass_threshold) {
            const was_unhealthy = store.*.probe_healthy == 0;
            store.*.probe_healthy = 1;
            store.*.ready = 1;
            if (was_unhealthy) {
                emit_transition = true;
                transition_healthy = true;
                transition_checked_at = now;
            }
            // Start slow-start tracking on recovery
            if (was_unhealthy and healthcheck_probe_slow_start_ms > 0) {
                store.*.probe_recovered_at_ms = now;
                store.*.probe_slow_start_elapsed_ms = 0;
            }
        }
        // Update slow-start elapsed during ramp-up
        if (store.*.probe_recovered_at_ms > 0 and healthcheck_probe_slow_start_ms > 0) {
            store.*.probe_slow_start_elapsed_ms = now - store.*.probe_recovered_at_ms;
            if (store.*.probe_slow_start_elapsed_ms >= @as(i64, @intCast(healthcheck_probe_slow_start_ms))) {
                store.*.probe_slow_start_elapsed_ms = @as(i64, @intCast(healthcheck_probe_slow_start_ms));
                store.*.probe_recovered_at_ms = 0; // ramp complete
            }
        }
    } else {
        store.*.probe_total_failures += 1;
        store.*.probe_consecutive_failures += 1;
        store.*.probe_consecutive_successes = 0;
        store.*.probe_slow_start_elapsed_ms = 0;
        store.*.probe_recovered_at_ms = 0;
        if (store.*.probe_consecutive_failures >= healthcheck_probe_fail_threshold) {
            const was_healthy = store.*.probe_healthy == 1;
            store.*.probe_healthy = 0;
            store.*.ready = 0;
            if (was_healthy) {
                emit_transition = true;
                transition_healthy = false;
                transition_checked_at = now;
            }
        }
    }

    shm.ngx_shmtx_unlock(&shpool.*.mutex);

    if (emit_transition) {
        publishHealthTransition(transition_healthy, transition_status, transition_checked_at);
    }
}

fn recordUpstreamProbeResult(entry: *UpstreamProbeEntry, result: ProbeResult) void {
    const store = getUpstreamStore(entry) orelse return;
    const shpool = getUpstreamShpool(entry) orelse return;

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.*.mutex);

    const now = getCurrentTimeMs();
    store.*.probe_last_status = result.status;
    store.*.probe_last_checked_ms = now;

    if (result.success) {
        store.*.probe_total_successes += 1;
        store.*.probe_consecutive_successes += 1;
        store.*.probe_consecutive_failures = 0;
        if (store.*.probe_consecutive_successes >= entry.pass_threshold) {
            const was_unhealthy = store.*.probe_healthy == 0;
            store.*.probe_healthy = 1;
            store.*.ready = 1;
            if (was_unhealthy and entry.slow_start_ms > 0) {
                store.*.probe_recovered_at_ms = now;
                store.*.probe_slow_start_elapsed_ms = 0;
            }
        }
        if (store.*.probe_recovered_at_ms > 0 and entry.slow_start_ms > 0) {
            store.*.probe_slow_start_elapsed_ms = now - store.*.probe_recovered_at_ms;
            if (store.*.probe_slow_start_elapsed_ms >= @as(i64, @intCast(entry.slow_start_ms))) {
                store.*.probe_slow_start_elapsed_ms = @as(i64, @intCast(entry.slow_start_ms));
                store.*.probe_recovered_at_ms = 0;
            }
        }
    } else {
        store.*.probe_total_failures += 1;
        store.*.probe_consecutive_failures += 1;
        store.*.probe_consecutive_successes = 0;
        store.*.probe_slow_start_elapsed_ms = 0;
        store.*.probe_recovered_at_ms = 0;
        if (store.*.probe_consecutive_failures >= entry.fail_threshold) {
            store.*.probe_healthy = 0;
            store.*.ready = 0;
        }
    }
}

fn recordPeerProbeResult(entry: *PeerProbeEntry, result: ProbeResult) void {
    const zone = entry.zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.data == null) return;
    const store = core.castPtr(healthcheck_store, zone.*.data) orelse return;
    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return;

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.*.mutex);

    const now = getCurrentTimeMs();
    store.*.probe_last_status = result.status;
    store.*.probe_last_checked_ms = now;

    if (result.success) {
        store.*.probe_total_successes += 1;
        store.*.probe_consecutive_successes += 1;
        store.*.probe_consecutive_failures = 0;
        if (store.*.probe_consecutive_successes >= entry.pass_threshold) {
            const was_unhealthy = store.*.probe_healthy == 0;
            store.*.probe_healthy = 1;
            store.*.ready = 1;
            if (was_unhealthy and entry.slow_start_ms > 0) {
                store.*.probe_recovered_at_ms = now;
                store.*.probe_slow_start_elapsed_ms = 0;
            }
        }
        if (store.*.probe_recovered_at_ms > 0 and entry.slow_start_ms > 0) {
            store.*.probe_slow_start_elapsed_ms = now - store.*.probe_recovered_at_ms;
            if (store.*.probe_slow_start_elapsed_ms >= @as(i64, @intCast(entry.slow_start_ms))) {
                store.*.probe_slow_start_elapsed_ms = @as(i64, @intCast(entry.slow_start_ms));
                store.*.probe_recovered_at_ms = 0;
            }
        }
    } else {
        store.*.probe_total_failures += 1;
        store.*.probe_consecutive_failures += 1;
        store.*.probe_consecutive_successes = 0;
        store.*.probe_slow_start_elapsed_ms = 0;
        store.*.probe_recovered_at_ms = 0;
        if (store.*.probe_consecutive_failures >= entry.fail_threshold) {
            store.*.probe_healthy = 0;
            store.*.ready = 0;
        }
    }
}

fn peerProbeHash(addr: []const u8) usize {
    return @as(usize, std.hash.crc.Crc32.hash(addr)) % PEER_PROBE_INDEX_SLOTS;
}

fn rebuildPeerProbeIndex() void {
    @memset(peer_probe_index_slots[0..], 0);
    for (0..peer_probe_count) |i| {
        const entry = &peer_probes[i];
        if (entry.addr_len == 0) continue;
        var slot = peerProbeHash(entry.addr_buf[0..entry.addr_len]);
        var remaining = PEER_PROBE_INDEX_SLOTS;
        while (remaining > 0) : (remaining -= 1) {
            if (peer_probe_index_slots[slot] == 0) {
                peer_probe_index_slots[slot] = @as(u8, @intCast(i + 1));
                break;
            }
            slot = (slot + 1) % PEER_PROBE_INDEX_SLOTS;
        }
    }
}

fn findPeerProbeEntry(addr: []const u8) ?*const PeerProbeEntry {
    if (peer_probe_count == 0) return null;
    var slot = peerProbeHash(addr);
    var remaining = PEER_PROBE_INDEX_SLOTS;
    while (remaining > 0) : (remaining -= 1) {
        const entry_idx_plus_one = peer_probe_index_slots[slot];
        if (entry_idx_plus_one == 0) return null;
        const entry = &peer_probes[entry_idx_plus_one - 1];
        if (entry.addr_len == addr.len and std.mem.eql(u8, addr, entry.addr_buf[0..entry.addr_len])) {
            return entry;
        }
        slot = (slot + 1) % PEER_PROBE_INDEX_SLOTS;
    }
    return null;
}

// ── Cross-module API ─────────────────────────────────────────────────────────

const HEALTHCHECK_PEER_STATE_ELIGIBLE: c_int = 0;
const HEALTHCHECK_PEER_STATE_UNHEALTHY: c_int = 1;
const HEALTHCHECK_PEER_STATE_SLOW_START: c_int = 2;

export fn ngz_healthcheck_peer_state(addr_data: [*c]u8, addr_len: usize) callconv(.c) c_int {
    if (peer_probe_count == 0) return HEALTHCHECK_PEER_STATE_ELIGIBLE;
    const addr = core.slicify(u8, addr_data, addr_len);
    const entry = findPeerProbeEntry(addr) orelse return HEALTHCHECK_PEER_STATE_ELIGIBLE;
    const zone = entry.zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.data == null) return HEALTHCHECK_PEER_STATE_ELIGIBLE;
    const store = core.castPtr(healthcheck_store, zone.*.data) orelse return HEALTHCHECK_PEER_STATE_ELIGIBLE;
    if (store.*.probe_healthy == 0) return HEALTHCHECK_PEER_STATE_UNHEALTHY;
    if (store.*.probe_recovered_at_ms > 0) return HEALTHCHECK_PEER_STATE_SLOW_START;
    return HEALTHCHECK_PEER_STATE_ELIGIBLE;
}

// Returns 1 if the peer at addr_data/addr_len is eligible for selection,
// 0 if it is known-unhealthy according to a configured peer probe.
// Peers with no probe configured are considered eligible (fail-open).
// Called per-request from the upstream-balancer module; no lock taken —
// reading a single ngx_flag_t word is atomic on x86-64 and acceptable
// for selection-time decisions where a stale read degrades gracefully.
export fn ngz_healthcheck_is_peer_eligible(addr_data: [*c]u8, addr_len: usize) callconv(.c) c_int {
    return if (ngz_healthcheck_peer_state(addr_data, addr_len) == HEALTHCHECK_PEER_STATE_ELIGIBLE) 1 else 0;
}

// ── Snapshot readers ─────────────────────────────────────────────────────────

fn readStoreSnapshot() healthcheck_snapshot {
    const defaults = healthcheck_snapshot{
        .ready = true,
        .probe_enabled = healthcheck_probe_enabled,
        .probe_healthy = true,
        .total_requests = 0,
        .failed_requests = 0,
        .probe_last_status = 0,
        .probe_last_checked_ms = 0,
        .probe_last_started_ms = 0,
        .probe_consecutive_successes = 0,
        .probe_consecutive_failures = 0,
        .probe_total_successes = 0,
        .probe_total_failures = 0,
        .probe_slow_start_elapsed_ms = 0,
        .probe_recovered_at_ms = 0,
    };

    const store = getStore() orelse return defaults;
    const shpool = getShpool() orelse return defaults;

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    const snapshot = healthcheck_snapshot{
        .ready = store.*.ready == 1,
        .probe_enabled = store.*.probe_enabled == 1,
        .probe_healthy = store.*.probe_healthy == 1,
        .total_requests = store.*.total_requests,
        .failed_requests = store.*.failed_requests,
        .probe_last_status = store.*.probe_last_status,
        .probe_last_checked_ms = store.*.probe_last_checked_ms,
        .probe_last_started_ms = store.*.probe_last_started_ms,
        .probe_consecutive_successes = store.*.probe_consecutive_successes,
        .probe_consecutive_failures = store.*.probe_consecutive_failures,
        .probe_total_successes = store.*.probe_total_successes,
        .probe_total_failures = store.*.probe_total_failures,
        .probe_slow_start_elapsed_ms = store.*.probe_slow_start_elapsed_ms,
        .probe_recovered_at_ms = store.*.probe_recovered_at_ms,
    };
    shm.ngx_shmtx_unlock(&shpool.*.mutex);
    return snapshot;
}

fn readUpstreamSnapshot(entry: *UpstreamProbeEntry) upstream_snapshot {
    const name_slice = entry.name_buf[0..entry.name_len];
    const defaults = upstream_snapshot{
        .name = name_slice,
        .probe_healthy = true,
        .probe_last_status = 0,
        .probe_last_checked_ms = 0,
        .probe_last_started_ms = 0,
        .probe_total_successes = 0,
        .probe_total_failures = 0,
        .probe_consecutive_successes = 0,
        .probe_consecutive_failures = 0,
        .probe_slow_start_elapsed_ms = 0,
        .probe_recovered_at_ms = 0,
    };

    const store = getUpstreamStore(entry) orelse return defaults;
    const shpool = getUpstreamShpool(entry) orelse return defaults;

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    const snap = upstream_snapshot{
        .name = name_slice,
        .probe_healthy = store.*.probe_healthy == 1,
        .probe_last_status = store.*.probe_last_status,
        .probe_last_checked_ms = store.*.probe_last_checked_ms,
        .probe_last_started_ms = store.*.probe_last_started_ms,
        .probe_total_successes = store.*.probe_total_successes,
        .probe_total_failures = store.*.probe_total_failures,
        .probe_consecutive_successes = store.*.probe_consecutive_successes,
        .probe_consecutive_failures = store.*.probe_consecutive_failures,
        .probe_slow_start_elapsed_ms = store.*.probe_slow_start_elapsed_ms,
        .probe_recovered_at_ms = store.*.probe_recovered_at_ms,
    };
    shm.ngx_shmtx_unlock(&shpool.*.mutex);
    return snap;
}

fn readPeerSnapshot(entry: *PeerProbeEntry) peer_snapshot {
    const upstream_name_slice = entry.name_buf[0..entry.name_len];
    const addr_slice = entry.addr_buf[0..entry.addr_len];
    const defaults = peer_snapshot{
        .upstream_name = upstream_name_slice,
        .peer_addr = addr_slice,
        .probe_healthy = true,
        .probe_last_status = 0,
        .probe_last_checked_ms = 0,
        .probe_last_started_ms = 0,
        .probe_total_successes = 0,
        .probe_total_failures = 0,
        .probe_consecutive_successes = 0,
        .probe_consecutive_failures = 0,
        .probe_slow_start_elapsed_ms = 0,
        .probe_recovered_at_ms = 0,
    };

    const zone = entry.zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.data == null) return defaults;
    const store = core.castPtr(healthcheck_store, zone.*.data) orelse return defaults;
    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return defaults;

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    const snap = peer_snapshot{
        .upstream_name = upstream_name_slice,
        .peer_addr = addr_slice,
        .probe_healthy = store.*.probe_healthy == 1,
        .probe_last_status = store.*.probe_last_status,
        .probe_last_checked_ms = store.*.probe_last_checked_ms,
        .probe_last_started_ms = store.*.probe_last_started_ms,
        .probe_total_successes = store.*.probe_total_successes,
        .probe_total_failures = store.*.probe_total_failures,
        .probe_consecutive_successes = store.*.probe_consecutive_successes,
        .probe_consecutive_failures = store.*.probe_consecutive_failures,
        .probe_slow_start_elapsed_ms = store.*.probe_slow_start_elapsed_ms,
        .probe_recovered_at_ms = store.*.probe_recovered_at_ms,
    };
    shm.ngx_shmtx_unlock(&shpool.*.mutex);
    return snap;
}

fn readinessFromSnapshot(snapshot: healthcheck_snapshot) bool {
    return if (snapshot.probe_enabled) snapshot.ready else true;
}

// ── Active probe scheduling (service-level) ──────────────────────────────────

fn maybeRunActiveProbe() void {
    if (!healthcheck_probe_enabled) return;

    const store = getStore() orelse return;
    const shpool = getShpool() orelse return;
    const now = getCurrentTimeMs();

    var should_probe = false;
    shm.ngx_shmtx_lock(&shpool.*.mutex);
    const last_seen = if (store.*.probe_last_started_ms > store.*.probe_last_checked_ms)
        store.*.probe_last_started_ms
    else
        store.*.probe_last_checked_ms;
    if (store.*.probe_last_checked_ms == 0 or now - last_seen >= @as(i64, @intCast(healthcheck_probe_interval_ms))) {
        store.*.probe_enabled = 1;
        store.*.probe_last_started_ms = now;
        should_probe = true;
    }
    shm.ngx_shmtx_unlock(&shpool.*.mutex);

    if (!should_probe) return;
    recordProbeResult(performActiveProbe());
}

fn scheduleNextProbe(delay_ms: ngx_msec_t) void {
    event.ngx_event_add_timer(&probe_timer_event, delay_ms);
}

fn healthcheck_probe_timer_handler(ev: [*c]core.ngx_event_t) callconv(.c) void {
    if (ev.*.flags.timer_set) {
        event.ngx_event_del_timer(ev);
    }
    ev.*.flags.timedout = false;

    if (!healthcheck_probe_enabled) return;

    if (getStore()) |store| {
        if (getShpool()) |shpool| {
            shm.ngx_shmtx_lock(&shpool.*.mutex);
            store.*.probe_enabled = 1;
            store.*.probe_last_started_ms = getCurrentTimeMs();
            shm.ngx_shmtx_unlock(&shpool.*.mutex);
        }
    }

    recordProbeResult(performActiveProbe());
    scheduleNextProbe(healthcheck_probe_interval_ms);
}

// ── Per-upstream probe timer ─────────────────────────────────────────────────

fn upstream_probe_timer_handler(ev: [*c]core.ngx_event_t) callconv(.c) void {
    if (ev.*.flags.timer_set) event.ngx_event_del_timer(ev);
    ev.*.flags.timedout = false;

    const entry = @as(*UpstreamProbeEntry, @ptrCast(@alignCast(ev.*.data orelse {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, ev.*.log, 0, "upstream_probe_timer: ev.data is null", .{});
        return;
    })));

    if (getUpstreamStore(entry)) |store| {
        if (getUpstreamShpool(entry)) |shpool| {
            shm.ngx_shmtx_lock(&shpool.*.mutex);
            store.*.probe_last_started_ms = getCurrentTimeMs();
            shm.ngx_shmtx_unlock(&shpool.*.mutex);
        }
    }

    const result = performUpstreamProbe(entry);
    recordUpstreamProbeResult(entry, result);
    event.ngx_event_add_timer(&entry.timer, entry.interval_ms);
}

// ── Per-peer probe timer handler ─────────────────────────────────────────────

fn peer_probe_timer_handler(ev: [*c]core.ngx_event_t) callconv(.c) void {
    if (ev.*.flags.timer_set) event.ngx_event_del_timer(ev);
    ev.*.flags.timedout = false;

    const entry = @as(*PeerProbeEntry, @ptrCast(@alignCast(ev.*.data orelse {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, ev.*.log, 0, "peer_probe_timer: ev.data is null", .{});
        return;
    })));

    const result = performPeerProbe(entry);
    recordPeerProbeResult(entry, result);
    event.ngx_event_add_timer(&entry.timer, entry.interval_ms);
}

// ── JSON response helpers ────────────────────────────────────────────────────

fn sendResponse(r: [*c]ngx_http_request_t, body: []const u8, content_type: []const u8, status: ngx_uint_t) ngx_int_t {
    r.*.headers_out.content_type = ngx_str_t{ .len = content_type.len, .data = @constCast(content_type.ptr) };
    r.*.headers_out.content_type_len = @intCast(content_type.len);
    r.*.headers_out.status = status;
    r.*.headers_out.content_length_n = @intCast(body.len);

    const rc = http.ngx_http_send_header(r);
    if (rc == NGX_ERROR or rc > NGX_OK) return rc;

    const b = core.castPtr(ngx.buf.ngx_buf_t, core.ngx_pcalloc(r.*.pool, @sizeOf(ngx.buf.ngx_buf_t))) orelse return NGX_ERROR;
    const data = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, body.len)) orelse return NGX_ERROR;

    @memcpy(core.slicify(u8, data, body.len), body);

    b.*.pos = data;
    b.*.last = data + body.len;
    b.*.flags.memory = true;
    b.*.flags.last_buf = true;
    b.*.flags.last_in_chain = true;

    var out: ngx.buf.ngx_chain_t = undefined;
    out.buf = b;
    out.next = null;
    return http.ngx_http_output_filter(r, &out);
}

fn sendJsonResponse(r: [*c]ngx_http_request_t, json: []const u8, status: ngx_uint_t) ngx_int_t {
    return sendResponse(r, json, "application/json", status);
}

// ── HTTP handlers ────────────────────────────────────────────────────────────

export fn ngx_http_healthcheck_status_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(healthcheck_loc_conf, conf.ngx_http_get_module_loc_conf(r, &ngx_http_healthcheck_module)) orelse return NGX_DECLINED;
    if (lccf.*.status_enabled != 1) return NGX_DECLINED;

    maybeRunActiveProbe();
    const snapshot = readStoreSnapshot();
    const ready = readinessFromSnapshot(snapshot);
    const health_pct: u64 = if (snapshot.total_requests > 0)
        ((snapshot.total_requests - snapshot.failed_requests) * 100) / snapshot.total_requests
    else
        100;

    var json_buf: [MAX_JSON_RESPONSE_LEN]u8 = undefined;
    var pos: usize = 0;

    const fixed_part = std.fmt.bufPrint(json_buf[pos..],
        \\{{"status":"{s}","healthy":{s},"ready":{s},"requests":{d},"failed":{d},"success_rate":{d},"probe_enabled":{s},"probe_healthy":{s},"probe_last_status":{d},"probe_last_checked_ms":{d},"probe_last_started_ms":{d},"probe_slow_start_elapsed_ms":{d},"probe_recovered_at_ms":{d},"probe_total_successes":{d},"probe_total_failures":{d},"probe_consecutive_successes":{d},"probe_consecutive_failures":{d}
    , .{
        if (ready) "healthy" else "unhealthy",
        if (ready) "true" else "false",
        if (ready) "true" else "false",
        snapshot.total_requests,
        snapshot.failed_requests,
        health_pct,
        if (snapshot.probe_enabled) "true" else "false",
        if (!snapshot.probe_enabled or snapshot.probe_healthy) "true" else "false",
        snapshot.probe_last_status,
        snapshot.probe_last_checked_ms,
        snapshot.probe_last_started_ms,
        snapshot.probe_slow_start_elapsed_ms,
        snapshot.probe_recovered_at_ms,
        snapshot.probe_total_successes,
        snapshot.probe_total_failures,
        snapshot.probe_consecutive_successes,
        snapshot.probe_consecutive_failures,
    }) catch return NGX_ERROR;
    pos += fixed_part.len;

    if (upstream_probe_count > 0) {
        // Aggregate summary across all upstream probes.
        var ups_healthy_count: u32 = 0;
        var ups_unhealthy_count: u32 = 0;
        for (0..upstream_probe_count) |i| {
            const s = readUpstreamSnapshot(&upstream_probes[i]);
            if (s.probe_healthy) {
                ups_healthy_count += 1;
            } else {
                ups_unhealthy_count += 1;
            }
        }

        const summary_part = std.fmt.bufPrint(json_buf[pos..],
            \\,"upstreams_summary":{{"healthy":{d},"unhealthy":{d},"total":{d}}}
        , .{ ups_healthy_count, ups_unhealthy_count, upstream_probe_count }) catch return NGX_ERROR;
        pos += summary_part.len;

        const sep = ",\"upstreams\":[";
        if (pos + sep.len > json_buf.len) return NGX_ERROR;
        @memcpy(json_buf[pos..][0..sep.len], sep);
        pos += sep.len;

        for (0..upstream_probe_count) |i| {
            if (i > 0) {
                if (pos >= json_buf.len) return NGX_ERROR;
                json_buf[pos] = ',';
                pos += 1;
            }
            const snap = readUpstreamSnapshot(&upstream_probes[i]);
            const entry_part = std.fmt.bufPrint(json_buf[pos..],
                \\{{"name":"{s}","probe_healthy":{s},"probe_last_status":{d},"probe_last_checked_ms":{d},"probe_last_started_ms":{d},"probe_slow_start_elapsed_ms":{d},"probe_recovered_at_ms":{d},"probe_total_successes":{d},"probe_total_failures":{d},"probe_consecutive_successes":{d},"probe_consecutive_failures":{d}}}
            , .{
                snap.name,
                if (snap.probe_healthy) "true" else "false",
                snap.probe_last_status,
                snap.probe_last_checked_ms,
                snap.probe_last_started_ms,
                snap.probe_slow_start_elapsed_ms,
                snap.probe_recovered_at_ms,
                snap.probe_total_successes,
                snap.probe_total_failures,
                snap.probe_consecutive_successes,
                snap.probe_consecutive_failures,
            }) catch return NGX_ERROR;
            pos += entry_part.len;
        }

        if (pos >= json_buf.len) return NGX_ERROR;
        json_buf[pos] = ']';
        pos += 1;
    }

    // Per-peer probe results
    if (peer_probe_count > 0) {
        const peer_sep = ",\"peers\":[";
        if (pos + peer_sep.len > json_buf.len) return NGX_ERROR;
        @memcpy(json_buf[pos..][0..peer_sep.len], peer_sep);
        pos += peer_sep.len;

        for (0..peer_probe_count) |i| {
            if (i > 0) {
                if (pos >= json_buf.len) return NGX_ERROR;
                json_buf[pos] = ',';
                pos += 1;
            }
            const snap = readPeerSnapshot(&peer_probes[i]);
            const ppart = std.fmt.bufPrint(json_buf[pos..],
                \\{{"upstream":"{s}","peer":"{s}","probe_healthy":{s},"probe_last_status":{d},"probe_total_successes":{d},"probe_total_failures":{d},"probe_consecutive_successes":{d},"probe_consecutive_failures":{d}}}
            , .{
                snap.upstream_name,
                snap.peer_addr,
                if (snap.probe_healthy) "true" else "false",
                snap.probe_last_status,
                snap.probe_total_successes,
                snap.probe_total_failures,
                snap.probe_consecutive_successes,
                snap.probe_consecutive_failures,
            }) catch return NGX_ERROR;
            pos += ppart.len;
        }

        if (pos >= json_buf.len) return NGX_ERROR;
        json_buf[pos] = ']';
        pos += 1;
    }

    if (pos >= json_buf.len) return NGX_ERROR;
    json_buf[pos] = '}';
    pos += 1;
    const json = json_buf[0..pos];

    return sendJsonResponse(r, json, if (ready) 200 else 503);
}

export fn ngx_http_healthcheck_liveness_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(healthcheck_loc_conf, conf.ngx_http_get_module_loc_conf(r, &ngx_http_healthcheck_module)) orelse return NGX_DECLINED;
    if (lccf.*.liveness_enabled != 1) return NGX_DECLINED;
    return sendJsonResponse(r, "{\"status\":\"alive\"}", 200);
}

export fn ngx_http_healthcheck_readiness_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(healthcheck_loc_conf, conf.ngx_http_get_module_loc_conf(r, &ngx_http_healthcheck_module)) orelse return NGX_DECLINED;
    if (lccf.*.readiness_enabled != 1) return NGX_DECLINED;

    maybeRunActiveProbe();
    const snapshot = readStoreSnapshot();
    if (readinessFromSnapshot(snapshot)) {
        return sendJsonResponse(r, "{\"status\":\"ready\"}", 200);
    }
    return sendJsonResponse(r, "{\"status\":\"not_ready\"}", 503);
}

fn ngx_http_healthcheck_log_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    if (r != r.*.main) return NGX_OK;

    const lccf = core.castPtr(healthcheck_loc_conf, conf.ngx_http_get_module_loc_conf(r, &ngx_http_healthcheck_module));
    if (lccf != null and (lccf.?.*.status_enabled == 1 or lccf.?.*.liveness_enabled == 1 or lccf.?.*.readiness_enabled == 1)) {
        return NGX_OK;
    }

    const store = getStore() orelse return NGX_OK;
    const shpool = getShpool() orelse return NGX_OK;

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    store.*.total_requests += 1;
    if (r.*.headers_out.status >= 400) {
        store.*.failed_requests += 1;
    }
    shm.ngx_shmtx_unlock(&shpool.*.mutex);
    return NGX_OK;
}

// ── Directive set callbacks: location context ────────────────────────────────

fn ngx_conf_set_health_status(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(healthcheck_loc_conf, loc)) |lccf| {
        lccf.*.status_enabled = 1;
        if (core.castPtr(http.ngx_http_core_loc_conf_t, conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module))) |clcf| {
            clcf.*.handler = ngx_http_healthcheck_status_handler;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_health_liveness(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(healthcheck_loc_conf, loc)) |lccf| {
        lccf.*.liveness_enabled = 1;
        if (core.castPtr(http.ngx_http_core_loc_conf_t, conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module))) |clcf| {
            clcf.*.handler = ngx_http_healthcheck_liveness_handler;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_health_readiness(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(healthcheck_loc_conf, loc)) |lccf| {
        lccf.*.readiness_enabled = 1;
        if (core.castPtr(http.ngx_http_core_loc_conf_t, conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module))) |clcf| {
            clcf.*.handler = ngx_http_healthcheck_readiness_handler;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_health_worker_events_channel(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(healthcheck_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            lccf.*.worker_events_channel = arg.*;
            healthcheck_worker_events_channel = arg.*;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_health_probe(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = loc;

    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return configError(cf, "health_probe requires an absolute http://host:port/path target");
    const value = core.slicify(u8, arg.*.data, arg.*.len);
    if (!applyProbeTarget(value)) {
        return configError(cf, "health_probe only supports absolute http://host:port/path targets");
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_health_probe_interval(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = loc;

    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return configError(cf, "health_probe_interval requires a value");
    const value = core.slicify(u8, arg.*.data, arg.*.len);
    healthcheck_probe_interval_ms = parseDurationMs(value) orelse return configError(cf, "health_probe_interval must be an integer, Nms, or Ns");
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_health_probe_timeout(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = loc;

    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return configError(cf, "health_probe_timeout requires a value");
    const value = core.slicify(u8, arg.*.data, arg.*.len);
    healthcheck_probe_timeout_ms = parseDurationMs(value) orelse return configError(cf, "health_probe_timeout must be an integer, Nms, or Ns");
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_health_probe_fails(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = loc;

    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return configError(cf, "health_probe_fails requires a value");
    const value = core.slicify(u8, arg.*.data, arg.*.len);
    healthcheck_probe_fail_threshold = std.fmt.parseInt(ngx_uint_t, value, 10) catch return configError(cf, "health_probe_fails must be a positive integer");
    if (healthcheck_probe_fail_threshold == 0) return configError(cf, "health_probe_fails must be greater than zero");
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_health_probe_passes(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = loc;

    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return configError(cf, "health_probe_passes requires a value");
    const value = core.slicify(u8, arg.*.data, arg.*.len);
    healthcheck_probe_pass_threshold = std.fmt.parseInt(ngx_uint_t, value, 10) catch return configError(cf, "health_probe_passes must be a positive integer");
    if (healthcheck_probe_pass_threshold == 0) return configError(cf, "health_probe_passes must be greater than zero");
    return conf.NGX_CONF_OK;
}

// ── Directive set callbacks: upstream context ────────────────────────────────

fn ngx_conf_set_health_upstream_probe(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, data: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const ups_conf = core.castPtr(healthcheck_ups_conf, data) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse
        return configError(cf, "health_upstream_probe requires an absolute http://host:port/path target");
    const value = core.slicify(u8, arg.*.data, arg.*.len);
    if (!applyProbeTargetToConf(ups_conf, value)) {
        return configError(cf, "health_upstream_probe only supports absolute http://host:port/path targets");
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_health_upstream_probe_interval(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, data: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const ups_conf = core.castPtr(healthcheck_ups_conf, data) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse
        return configError(cf, "health_upstream_probe_interval requires a value");
    const value = core.slicify(u8, arg.*.data, arg.*.len);
    ups_conf.*.probe_interval_ms = parseDurationMs(value) orelse
        return configError(cf, "health_upstream_probe_interval must be an integer, Nms, or Ns");
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_health_upstream_probe_timeout(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, data: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const ups_conf = core.castPtr(healthcheck_ups_conf, data) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse
        return configError(cf, "health_upstream_probe_timeout requires a value");
    const value = core.slicify(u8, arg.*.data, arg.*.len);
    ups_conf.*.probe_timeout_ms = parseDurationMs(value) orelse
        return configError(cf, "health_upstream_probe_timeout must be an integer, Nms, or Ns");
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_health_upstream_probe_fails(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, data: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const ups_conf = core.castPtr(healthcheck_ups_conf, data) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse
        return configError(cf, "health_upstream_probe_fails requires a value");
    const value = core.slicify(u8, arg.*.data, arg.*.len);
    const n = std.fmt.parseInt(ngx_uint_t, value, 10) catch
        return configError(cf, "health_upstream_probe_fails must be a positive integer");
    if (n == 0) return configError(cf, "health_upstream_probe_fails must be greater than zero");
    ups_conf.*.probe_fail_threshold = n;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_health_upstream_probe_passes(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, data: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const ups_conf = core.castPtr(healthcheck_ups_conf, data) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse
        return configError(cf, "health_upstream_probe_passes requires a value");
    const value = core.slicify(u8, arg.*.data, arg.*.len);
    const n = std.fmt.parseInt(ngx_uint_t, value, 10) catch
        return configError(cf, "health_upstream_probe_passes must be a positive integer");
    if (n == 0) return configError(cf, "health_upstream_probe_passes must be greater than zero");
    ups_conf.*.probe_pass_threshold = n;
    return conf.NGX_CONF_OK;
}

// ── Directive set callbacks: match & slow-start (location context) ──────────

fn ngx_conf_set_health_probe_match(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = loc;

    // Format: health_probe_match status=<min>-<max> body=<substring>;
    var i: ngx_uint_t = 1;
    while (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const val = core.slicify(u8, arg.*.data, arg.*.len);
        if (std.mem.startsWith(u8, val, "status=")) {
            const range = val["status=".len..];
            const dash = std.mem.indexOfScalar(u8, range, '-') orelse
                return configError(cf, "health_probe_match status requires <min>-<max> format");
            const min_str = range[0..dash];
            const max_str = range[dash + 1 ..];
            healthcheck_probe_match_status_min = std.fmt.parseInt(ngx_uint_t, min_str, 10) catch
                return configError(cf, "health_probe_match status: invalid min value");
            healthcheck_probe_match_status_max = std.fmt.parseInt(ngx_uint_t, max_str, 10) catch
                return configError(cf, "health_probe_match status: invalid max value");
            healthcheck_probe_flags |= PROBE_FLAG_HAS_MATCH;
        } else if (std.mem.startsWith(u8, val, "body=")) {
            const body_str = val["body=".len..];
            if (body_str.len == 0 or body_str.len > MAX_PROBE_MATCH_BODY_LEN)
                return configError(cf, "health_probe_match body: empty or too long");
            @memcpy(healthcheck_probe_match_body_buf[0..body_str.len], body_str);
            healthcheck_probe_match_body_len = body_str.len;
            healthcheck_probe_flags |= PROBE_FLAG_HAS_MATCH;
        } else {
            return configError(cf, "health_probe_match: expected status=<min>-<max> or body=<substring>");
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_health_probe_slow_start(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = loc;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse
        return configError(cf, "health_probe_slow_start requires a time value");
    const value = core.slicify(u8, arg.*.data, arg.*.len);
    healthcheck_probe_slow_start_ms = parseDurationMs(value) orelse
        return configError(cf, "health_probe_slow_start must be an integer, Nms, or Ns");
    return conf.NGX_CONF_OK;
}

// ── Directive set callbacks: match & slow-start (upstream context) ───────────

fn ngx_conf_set_health_upstream_probe_match(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, data: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const ups_conf = core.castPtr(healthcheck_ups_conf, data) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    while (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const val = core.slicify(u8, arg.*.data, arg.*.len);
        if (std.mem.startsWith(u8, val, "status=")) {
            const range = val["status=".len..];
            const dash = std.mem.indexOfScalar(u8, range, '-') orelse
                return configError(cf, "health_upstream_probe_match status requires <min>-<max> format");
            ups_conf.*.match_status_min = std.fmt.parseInt(ngx_uint_t, range[0..dash], 10) catch
                return configError(cf, "health_upstream_probe_match status: invalid min value");
            ups_conf.*.match_status_max = std.fmt.parseInt(ngx_uint_t, range[dash + 1 ..], 10) catch
                return configError(cf, "health_upstream_probe_match status: invalid max value");
            ups_conf.*.probe_flags |= PROBE_FLAG_HAS_MATCH;
        } else if (std.mem.startsWith(u8, val, "body=")) {
            const body_str = val["body=".len..];
            if (body_str.len == 0 or body_str.len > MAX_PROBE_MATCH_BODY_LEN)
                return configError(cf, "health_upstream_probe_match body: empty or too long");
            @memcpy(ups_conf.*.match_body_buf[0..body_str.len], body_str);
            ups_conf.*.match_body_len = body_str.len;
            ups_conf.*.probe_flags |= PROBE_FLAG_HAS_MATCH;
        } else {
            return configError(cf, "health_upstream_probe_match: expected status=<min>-<max> or body=<substring>");
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_health_upstream_probe_slow_start(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, data: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const ups_conf = core.castPtr(healthcheck_ups_conf, data) orelse return conf.NGX_CONF_OK;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse
        return configError(cf, "health_upstream_probe_slow_start requires a time value");
    const value = core.slicify(u8, arg.*.data, arg.*.len);
    ups_conf.*.probe_slow_start_ms = parseDurationMs(value) orelse
        return configError(cf, "health_upstream_probe_slow_start must be an integer, Nms, or Ns");
    return conf.NGX_CONF_OK;
}

// ── Directive set callbacks: per-peer probe (upstream context) ───────────────

fn ngx_conf_set_health_upstream_peer_probe(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, data: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const uscf = core.castPtr(http.ngx_http_upstream_srv_conf_t, conf.ngx_http_conf_get_module_srv_conf(cf, &ngx_http_upstream_module)) orelse
        return configError(cf, "health_upstream_peer_probe: upstream context unavailable");
    if (peer_probe_count >= MAX_PEER_PROBES) return configError(cf, "too many health_upstream_peer_probe entries");

    var i: ngx_uint_t = 1;
    const addr_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse
        return configError(cf, "health_upstream_peer_probe requires <addr> <target>");
    const target_arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse
        return configError(cf, "health_upstream_peer_probe requires <addr> <target>");

    const addr_val = core.slicify(u8, addr_arg.*.data, addr_arg.*.len);
    const target_val = core.slicify(u8, target_arg.*.data, target_arg.*.len);

    if (addr_val.len == 0 or addr_val.len > MAX_PEER_ADDR_LEN)
        return configError(cf, "health_upstream_peer_probe: invalid peer address");

    const idx = peer_probe_count;
    peer_probe_count += 1;
    const entry = &peer_probes[idx];
    entry.* = std.mem.zeroes(PeerProbeEntry);

    // Parse probe target
    var port: u16 = 0;
    var host_len: usize = 0;
    var path_len: usize = 0;
    var flags: u8 = 0;
    if (!parseProbeTarget(target_val, &entry.host_buf, &entry.path_buf, &host_len, &path_len, &port, &flags)) {
        peer_probe_count -= 1;
        return configError(cf, "health_upstream_peer_probe: invalid target, must be http[s]://host:port/path");
    }
    entry.host_len = host_len;
    entry.path_len = path_len;
    entry.port = port;
    entry.flags = flags;

    // Set defaults, then inherit any upstream probe settings already configured
    // in this upstream block (health_upstream_probe_interval etc.).
    entry.interval_ms = 5000;
    entry.timeout_ms = 1000;
    entry.fail_threshold = 2;
    entry.pass_threshold = 1;
    entry.slow_start_ms = 0;
    if (core.castPtr(healthcheck_ups_conf, data)) |ucf| {
        if (ucf.*.probe_interval_ms > 0) entry.interval_ms = ucf.*.probe_interval_ms;
        if (ucf.*.probe_timeout_ms > 0) entry.timeout_ms = ucf.*.probe_timeout_ms;
        if (ucf.*.probe_fail_threshold > 0) entry.fail_threshold = ucf.*.probe_fail_threshold;
        if (ucf.*.probe_pass_threshold > 0) entry.pass_threshold = ucf.*.probe_pass_threshold;
        if (ucf.*.probe_slow_start_ms > 0) entry.slow_start_ms = ucf.*.probe_slow_start_ms;
    }

    // Copy peer address
    entry.addr_len = addr_val.len;
    @memcpy(entry.addr_buf[0..addr_val.len], addr_val);
    entry.addr_buf[addr_val.len] = 0;

    // Copy upstream name
    entry.name_len = @min(uscf.*.host.len, MAX_UPSTREAM_NAME_LEN);
    @memcpy(entry.name_buf[0..entry.name_len], core.slicify(u8, uscf.*.host.data, entry.name_len));
    entry.name_buf[entry.name_len] = 0;

    // Create shared memory zone
    const prefix = "healthcheck_peer_";
    const total_len = prefix.len + entry.name_len + 1 + entry.addr_len;
    const name_data = core.castPtr(u8, core.ngx_pnalloc(cf.*.pool, total_len)) orelse {
        peer_probe_count -= 1;
        return configError(cf, "health_upstream_peer_probe: alloc failed");
    };
    const name_slice = core.slicify(u8, name_data, total_len);
    @memcpy(name_slice[0..prefix.len], prefix);
    const rest = name_slice[prefix.len..];
    const nlen = std.fmt.bufPrint(rest, "{s}_{s}", .{ entry.name_buf[0..entry.name_len], entry.addr_buf[0..entry.addr_len] }) catch {
        peer_probe_count -= 1;
        return configError(cf, "health_upstream_peer_probe: name too long");
    };
    const actual_len = prefix.len + nlen.len;

    var zone_name = ngx_str_t{ .len = actual_len, .data = name_data };
    const zone = shm.ngx_shared_memory_add(cf, &zone_name, UPSTREAM_ZONE_SIZE, @constCast(&ngx_http_healthcheck_module));
    if (zone == core.nullptr(core.ngx_shm_zone_t)) {
        peer_probe_count -= 1;
        return configError(cf, "health_upstream_peer_probe: shared memory add failed");
    }
    zone.*.init = upstream_probe_zone_init;
    entry.zone = zone;
    rebuildPeerProbeIndex();

    return conf.NGX_CONF_OK;
}

// ── Directive set callbacks: metrics endpoint ────────────────────────────────

fn ngx_conf_set_health_metrics(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(http.ngx_http_core_loc_conf_t, conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module))) |clcf| {
        clcf.*.handler = ngx_http_healthcheck_metrics_handler;
    }
    _ = loc;
    return conf.NGX_CONF_OK;
}

// ── Prometheus metrics handler ───────────────────────────────────────────────

fn buildPrometheusLine(buf: []u8, pos: *usize, metric: []const u8, value: anytype, labels: []const u8) bool {
    const line = std.fmt.bufPrint(buf[pos.*..], "{s}{s} {d}\n", .{ metric, labels, value }) catch return false;
    pos.* += line.len;
    return true;
}

export fn ngx_http_healthcheck_metrics_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    maybeRunActiveProbe();
    const snapshot = readStoreSnapshot();

    var buf: [MAX_JSON_RESPONSE_LEN]u8 = undefined;
    var pos: usize = 0;

    const labels = "{module=\"healthcheck\"}";

    _ = buildPrometheusLine(&buf, &pos, "nginz_health_requests_total", snapshot.total_requests, labels);
    _ = buildPrometheusLine(&buf, &pos, "nginz_health_failed_requests_total", snapshot.failed_requests, labels);
    _ = buildPrometheusLine(&buf, &pos, "nginz_health_ready", if (readinessFromSnapshot(snapshot)) @as(u8, 1) else @as(u8, 0), labels);
    _ = buildPrometheusLine(&buf, &pos, "nginz_health_probe_healthy", if (snapshot.probe_enabled and snapshot.probe_healthy) @as(u8, 1) else @as(u8, 0), labels);
    _ = buildPrometheusLine(&buf, &pos, "nginz_health_probe_last_status", snapshot.probe_last_status, labels);
    _ = buildPrometheusLine(&buf, &pos, "nginz_health_probe_successes_total", snapshot.probe_total_successes, labels);
    _ = buildPrometheusLine(&buf, &pos, "nginz_health_probe_failures_total", snapshot.probe_total_failures, labels);
    _ = buildPrometheusLine(&buf, &pos, "nginz_health_probe_consecutive_successes", snapshot.probe_consecutive_successes, labels);
    _ = buildPrometheusLine(&buf, &pos, "nginz_health_probe_consecutive_failures", snapshot.probe_consecutive_failures, labels);

    // Per-upstream probe metrics
    for (0..upstream_probe_count) |i| {
        const snap = readUpstreamSnapshot(&upstream_probes[i]);
        var ulabels_buf: [128]u8 = undefined;
        const ulabels = std.fmt.bufPrint(&ulabels_buf, "{{module=\"healthcheck\",upstream=\"{s}\"}}", .{snap.name}) catch continue;
        _ = buildPrometheusLine(&buf, &pos, "nginz_health_upstream_probe_healthy", if (snap.probe_healthy) @as(u8, 1) else @as(u8, 0), ulabels);
        _ = buildPrometheusLine(&buf, &pos, "nginz_health_upstream_probe_last_status", snap.probe_last_status, ulabels);
    }

    // Per-peer probe metrics
    for (0..peer_probe_count) |i| {
        const snap = readPeerSnapshot(&peer_probes[i]);
        var plabels_buf: [256]u8 = undefined;
        const plabels = std.fmt.bufPrint(&plabels_buf, "{{module=\"healthcheck\",upstream=\"{s}\",peer=\"{s}\"}}", .{ snap.upstream_name, snap.peer_addr }) catch continue;
        _ = buildPrometheusLine(&buf, &pos, "nginz_health_peer_probe_healthy", if (snap.probe_healthy) @as(u8, 1) else @as(u8, 0), plabels);
        _ = buildPrometheusLine(&buf, &pos, "nginz_health_peer_probe_last_status", snap.probe_last_status, plabels);
    }

    const body = buf[0..pos];
    return sendResponse(r, body, "text/plain; version=0.0.4", 200);
}

// ── Nginx variables ──────────────────────────────────────────────────────────

const ngx_http_variable_value_t = http.ngx_http_variable_value_t;

const HEALTH_VAR_READINESS: core.uintptr_t = 0;
const HEALTH_VAR_LIVENESS: core.uintptr_t = 1;
const HEALTH_VAR_BACKEND_HEALTHY_COUNT: core.uintptr_t = 2;
const HEALTH_VAR_BACKEND_TOTAL_COUNT: core.uintptr_t = 3;
const HEALTH_VAR_BACKEND_FAILURE_COUNT: core.uintptr_t = 4;

fn ngx_http_healthcheck_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    const snapshot = readStoreSnapshot();

    switch (data) {
        HEALTH_VAR_READINESS => {
            v.*.data = if (readinessFromSnapshot(snapshot)) @constCast("1") else @constCast("0");
            v.*.flags.len = 1;
        },
        HEALTH_VAR_LIVENESS => {
            v.*.data = @constCast("1");
            v.*.flags.len = 1;
        },
        HEALTH_VAR_BACKEND_HEALTHY_COUNT => {
            v.*.data = if (snapshot.probe_enabled and snapshot.probe_healthy) @constCast("1") else @constCast("0");
            v.*.flags.len = 1;
        },
        HEALTH_VAR_BACKEND_TOTAL_COUNT => {
            v.*.data = if (snapshot.probe_enabled) @constCast("1") else @constCast("0");
            v.*.flags.len = 1;
        },
        HEALTH_VAR_BACKEND_FAILURE_COUNT => {
            var tmp_buf: [16]u8 = undefined;
            const slice = std.fmt.bufPrint(&tmp_buf, "{d}", .{snapshot.probe_consecutive_failures}) catch {
                v.*.flags.not_found = true;
                return NGX_OK;
            };
            const copied = ngx.string.ngx_string_from_pool(@constCast(slice.ptr), slice.len, r.*.pool) catch {
                v.*.flags.not_found = true;
                return NGX_OK;
            };
            v.*.data = copied.data;
            v.*.flags.len = @intCast(copied.len);
        },
        else => {
            v.*.flags.not_found = true;
            return NGX_OK;
        },
    }

    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

// ── Module init ──────────────────────────────────────────────────────────────

fn preconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    _ = cf;
    // Reset per-config-cycle globals before directive parsing starts.
    upstream_probe_count = 0;
    peer_probe_count = 0;
    @memset(peer_probe_index_slots[0..], 0);
    return NGX_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {

    // Service-level shared zone.
    if (ngx_http_healthcheck_zone == core.nullptr(core.ngx_shm_zone_t)) {
        var zone_name = ngx_string("healthcheck_zone");
        const zone = shm.ngx_shared_memory_add(cf, &zone_name, HEALTHCHECK_ZONE_SIZE, @constCast(&ngx_http_healthcheck_module));
        if (zone == core.nullptr(core.ngx_shm_zone_t)) return NGX_ERROR;
        zone.*.init = healthcheck_zone_init;
        ngx_http_healthcheck_zone = zone;
    }

    // Variables.
    var vs = [_]http.ngx_http_variable_t{
        http.ngx_http_variable_t{ .name = ngx_string("health_readiness"), .set_handler = null, .get_handler = ngx_http_healthcheck_variable, .data = HEALTH_VAR_READINESS, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("health_liveness"), .set_handler = null, .get_handler = ngx_http_healthcheck_variable, .data = HEALTH_VAR_LIVENESS, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("health_backend_healthy_count"), .set_handler = null, .get_handler = ngx_http_healthcheck_variable, .data = HEALTH_VAR_BACKEND_HEALTHY_COUNT, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("health_backend_total_count"), .set_handler = null, .get_handler = ngx_http_healthcheck_variable, .data = HEALTH_VAR_BACKEND_TOTAL_COUNT, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("health_backend_failure_count"), .set_handler = null, .get_handler = ngx_http_healthcheck_variable, .data = HEALTH_VAR_BACKEND_FAILURE_COUNT, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
    };
    for (&vs) |*v| {
        if (http.ngx_http_add_variable(cf, &v.name, v.flags)) |x| {
            x.*.get_handler = v.get_handler;
            x.*.data = v.data;
        }
    }

    // Log phase handler.
    const cmcf = core.castPtr(http.ngx_http_core_main_conf_t, conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module)) orelse return NGX_ERROR;
    var log_handlers = NArray(http.ngx_http_handler_pt).init0(&cmcf[0].phases[10].handlers);
    const h = log_handlers.append() catch return NGX_ERROR;
    h.* = ngx_http_healthcheck_log_handler;

    // Iterate upstream {} blocks; create a named shm zone for each with a probe.
    const umcf_ptr = conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_upstream_module);
    const umcf = core.castPtr(http.ngx_http_upstream_main_conf_t, umcf_ptr) orelse return NGX_OK;

    if (umcf.*.upstreams.elts == null) return NGX_OK;
    const uscfp = @as([*][*c]http.ngx_http_upstream_srv_conf_t, @ptrCast(@alignCast(umcf.*.upstreams.elts)));

    for (0..umcf.*.upstreams.nelts) |i| {
        if (upstream_probe_count >= MAX_UPSTREAM_PROBES) break;

        const uscf = uscfp[i];
        const ups_conf = core.castPtr(
            healthcheck_ups_conf,
            conf.ngx_http_conf_upstream_srv_conf(uscf, &ngx_http_healthcheck_module),
        ) orelse continue;

        if (ups_conf.*.probe_enabled != 1) continue;

        const idx = upstream_probe_count;
        upstream_probe_count += 1;

        const entry = &upstream_probes[idx];
        entry.* = std.mem.zeroes(UpstreamProbeEntry);
        entry.interval_ms = ups_conf.*.probe_interval_ms;
        entry.timeout_ms = ups_conf.*.probe_timeout_ms;
        entry.fail_threshold = ups_conf.*.probe_fail_threshold;
        entry.pass_threshold = ups_conf.*.probe_pass_threshold;
        entry.slow_start_ms = ups_conf.*.probe_slow_start_ms;
        entry.flags = ups_conf.*.probe_flags;
        entry.port = @intCast(ups_conf.*.probe_port);
        entry.host_len = ups_conf.*.probe_host_len;
        entry.path_len = ups_conf.*.probe_path_len;
        entry.match_status_min = ups_conf.*.match_status_min;
        entry.match_status_max = ups_conf.*.match_status_max;
        entry.match_body_len = ups_conf.*.match_body_len;
        @memcpy(entry.match_body_buf[0..entry.match_body_len], ups_conf.*.match_body_buf[0..entry.match_body_len]);
        @memcpy(entry.host_buf[0..entry.host_len], ups_conf.*.probe_host_buf[0..entry.host_len]);
        entry.host_buf[entry.host_len] = 0;
        @memcpy(entry.path_buf[0..entry.path_len], ups_conf.*.probe_path_buf[0..entry.path_len]);
        entry.name_len = @min(uscf.*.host.len, MAX_UPSTREAM_NAME_LEN);
        @memcpy(entry.name_buf[0..entry.name_len], core.slicify(u8, uscf.*.host.data, entry.name_len));
        entry.name_buf[entry.name_len] = 0;

        // Build zone name: "healthcheck_upstream_<name>"
        const prefix = "healthcheck_upstream_";
        const total_len = prefix.len + entry.name_len;
        const name_data = core.castPtr(u8, core.ngx_pnalloc(cf.*.pool, total_len)) orelse {
            upstream_probe_count -= 1;
            continue;
        };
        const name_slice = core.slicify(u8, name_data, total_len);
        @memcpy(name_slice[0..prefix.len], prefix);
        @memcpy(name_slice[prefix.len..], entry.name_buf[0..entry.name_len]);

        var zone_name = ngx_str_t{ .len = total_len, .data = name_data };
        const zone = shm.ngx_shared_memory_add(cf, &zone_name, UPSTREAM_ZONE_SIZE, @constCast(&ngx_http_healthcheck_module));
        if (zone == core.nullptr(core.ngx_shm_zone_t)) {
            upstream_probe_count -= 1;
            continue;
        }
        zone.*.init = upstream_probe_zone_init;
        entry.zone = zone;
    }

    return NGX_OK;
}

fn healthcheck_init_process(cycle: [*c]core.ngx_cycle_t) callconv(.c) ngx_int_t {
    if (ngx_worker != 0) return NGX_OK;

    // Service-level probe timer.
    if (healthcheck_probe_enabled) {
        if (getStore() != null) {
            probe_timer_event = std.mem.zeroes(core.ngx_event_t);
            probe_timer_event.handler = healthcheck_probe_timer_handler;
            probe_timer_event.log = cycle.*.log;
            // data must be non-null to avoid segfault in ngx_event_ident(ev->data)
            // when debug logging is enabled (ngx_event_expire_timers)
            probe_timer_event.data = &probe_timer_event;
            // mark as cancelable so nginx can exit gracefully on SIGQUIT
            probe_timer_event.flags.cancelable = true;
            scheduleNextProbe(25);
        }
    }

    // Per-upstream probe timers; stagger starts so they don't all fire at once.
    for (0..upstream_probe_count) |i| {
        const entry = &upstream_probes[i];
        if (entry.zone == core.nullptr(core.ngx_shm_zone_t)) continue;
        if (entry.zone.*.data == null) continue;

        entry.timer = std.mem.zeroes(core.ngx_event_t);
        entry.timer.handler = upstream_probe_timer_handler;
        entry.timer.log = cycle.*.log;
        entry.timer.data = entry;
        // mark as cancelable so nginx can exit gracefully on SIGQUIT
        entry.timer.flags.cancelable = true;
        const delay: ngx_msec_t = 50 + @as(ngx_msec_t, @intCast(i)) * 25;
        event.ngx_event_add_timer(&entry.timer, delay);
    }

    // Per-peer probe timers; stagger starts so they don't all fire at once.
    for (0..peer_probe_count) |i| {
        const entry = &peer_probes[i];
        if (entry.zone == core.nullptr(core.ngx_shm_zone_t)) continue;
        if (entry.zone.*.data == null) continue;

        entry.timer = std.mem.zeroes(core.ngx_event_t);
        entry.timer.handler = peer_probe_timer_handler;
        entry.timer.log = cycle.*.log;
        entry.timer.data = entry;
        entry.timer.flags.cancelable = true;
        const delay: ngx_msec_t = 75 + @as(ngx_msec_t, @intCast(i)) * 25;
        event.ngx_event_add_timer(&entry.timer, delay);
    }

    return NGX_OK;
}

fn healthcheck_exit_process(_: [*c]core.ngx_cycle_t) callconv(.c) void {
    if (probe_timer_event.flags.timer_set) {
        event.ngx_event_del_timer(&probe_timer_event);
    }
    probe_timer_event = std.mem.zeroes(core.ngx_event_t);

    for (0..upstream_probe_count) |i| {
        const entry = &upstream_probes[i];
        if (entry.timer.flags.timer_set) {
            event.ngx_event_del_timer(&entry.timer);
        }
    }

    for (0..peer_probe_count) |i| {
        const entry = &peer_probes[i];
        if (entry.timer.flags.timer_set) {
            event.ngx_event_del_timer(&entry.timer);
        }
    }
}

// ── Module registration ──────────────────────────────────────────────────────

export const ngx_http_healthcheck_module_ctx = ngx_http_module_t{
    .preconfiguration = preconfiguration,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = create_srv_conf,
    .merge_srv_conf = merge_srv_conf,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_healthcheck_commands = [_]ngx_command_t{
    // ── location {} directives ──────────────────────────────────────────────
    ngx_command_t{
        .name = ngx_string("health_status"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_health_status,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_liveness"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_health_liveness,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_readiness"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_health_readiness,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_probe"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_health_probe,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_probe_interval"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_health_probe_interval,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_probe_timeout"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_health_probe_timeout,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_probe_fails"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_health_probe_fails,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_probe_passes"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_health_probe_passes,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_worker_events_channel"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_health_worker_events_channel,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // ── upstream {} directives ──────────────────────────────────────────────
    ngx_command_t{
        .name = ngx_string("health_upstream_probe"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_health_upstream_probe,
        .conf = conf.NGX_HTTP_SRV_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_upstream_probe_interval"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_health_upstream_probe_interval,
        .conf = conf.NGX_HTTP_SRV_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_upstream_probe_timeout"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_health_upstream_probe_timeout,
        .conf = conf.NGX_HTTP_SRV_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_upstream_probe_fails"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_health_upstream_probe_fails,
        .conf = conf.NGX_HTTP_SRV_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_upstream_probe_passes"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_health_upstream_probe_passes,
        .conf = conf.NGX_HTTP_SRV_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // ── match & slow-start (location context) ────────────────────────────
    ngx_command_t{
        .name = ngx_string("health_probe_match"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE12,
        .set = ngx_conf_set_health_probe_match,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_probe_slow_start"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_health_probe_slow_start,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    // ── match & slow-start (upstream context) ────────────────────────────
    ngx_command_t{
        .name = ngx_string("health_upstream_probe_match"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE12,
        .set = ngx_conf_set_health_upstream_probe_match,
        .conf = conf.NGX_HTTP_SRV_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_upstream_probe_slow_start"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_health_upstream_probe_slow_start,
        .conf = conf.NGX_HTTP_SRV_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_upstream_peer_probe"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_health_upstream_peer_probe,
        .conf = conf.NGX_HTTP_SRV_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("health_metrics"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_health_metrics,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_healthcheck_module = blk: {
    var m = ngx.module.make_module(@constCast(&ngx_http_healthcheck_commands), @constCast(&ngx_http_healthcheck_module_ctx));
    m.init_process = healthcheck_init_process;
    m.exit_process = healthcheck_exit_process;
    break :blk m;
};

test "healthcheck module" {}
