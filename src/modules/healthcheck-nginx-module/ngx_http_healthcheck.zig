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
extern var ngx_worker: ngx_uint_t;

const HEALTHCHECK_ZONE_SIZE: usize = 64 * 1024;
const MAX_PROBE_HOST_LEN: usize = 255;
const MAX_PROBE_PATH_LEN: usize = 255;
const MAX_JSON_RESPONSE_LEN: usize = 768;

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

const healthcheck_loc_conf = extern struct {
    status_enabled: ngx_flag_t,
    liveness_enabled: ngx_flag_t,
    readiness_enabled: ngx_flag_t,
};

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
};

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
};

const ProbeResult = struct {
    success: bool,
    status: ngx_uint_t,
};

var ngx_http_healthcheck_zone: [*c]core.ngx_shm_zone_t = core.nullptr(core.ngx_shm_zone_t);
var probe_timer_event: core.ngx_event_t = std.mem.zeroes(core.ngx_event_t);

var healthcheck_probe_enabled: bool = false;
var healthcheck_probe_interval_ms: ngx_msec_t = 5000;
var healthcheck_probe_timeout_ms: ngx_msec_t = 1000;
var healthcheck_probe_fail_threshold: ngx_uint_t = 2;
var healthcheck_probe_pass_threshold: ngx_uint_t = 1;
var healthcheck_probe_port: u16 = 80;
var healthcheck_probe_host_len: usize = 0;
var healthcheck_probe_path_len: usize = 1;
var healthcheck_probe_host_buf: [MAX_PROBE_HOST_LEN]u8 = [_]u8{0} ** MAX_PROBE_HOST_LEN;
var healthcheck_probe_path_buf: [MAX_PROBE_PATH_LEN]u8 = [_]u8{0} ** MAX_PROBE_PATH_LEN;

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

fn getCurrentTimeMs() i64 {
    const tp = core.ngx_timeofday();
    if (tp) |t| {
        return @as(i64, @intCast(t.*.sec)) * 1000 + @as(i64, @intCast(t.*.msec));
    }
    return 0;
}

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

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(healthcheck_loc_conf, cf.*.pool)) |p| {
        p.*.status_enabled = 0;
        p.*.liveness_enabled = 0;
        p.*.readiness_enabled = 0;
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

    return conf.NGX_CONF_OK;
}

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

fn applyProbeTarget(raw_target: []const u8) bool {
    if (!std.mem.startsWith(u8, raw_target, "http://")) return false;

    const rest = raw_target[7..];
    const slash_index = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash_index];
    const path = if (slash_index < rest.len) rest[slash_index..] else "/";

    if (host_port.len == 0 or path.len == 0 or path.len > MAX_PROBE_PATH_LEN) return false;
    if (std.mem.indexOfScalar(u8, host_port, '[') != null or std.mem.indexOfScalar(u8, host_port, ']') != null) {
        return false;
    }

    const colon_index = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return false;
    if (colon_index == 0 or colon_index + 1 >= host_port.len) return false;

    const host = host_port[0..colon_index];
    const port_raw = host_port[colon_index + 1 ..];
    const port = std.fmt.parseInt(u16, port_raw, 10) catch return false;

    if (host.len == 0 or host.len > MAX_PROBE_HOST_LEN) return false;

    @memset(healthcheck_probe_host_buf[0..], 0);
    @memcpy(healthcheck_probe_host_buf[0..host.len], host);
    healthcheck_probe_host_len = host.len;

    @memset(healthcheck_probe_path_buf[0..], 0);
    @memcpy(healthcheck_probe_path_buf[0..path.len], path);
    healthcheck_probe_path_len = path.len;

    healthcheck_probe_port = port;
    healthcheck_probe_enabled = true;
    return true;
}

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
    };
    shm.ngx_shmtx_unlock(&shpool.*.mutex);
    return snapshot;
}

fn readinessFromSnapshot(snapshot: healthcheck_snapshot) bool {
    return if (snapshot.probe_enabled) snapshot.ready else true;
}

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

fn sendJsonResponse(r: [*c]ngx_http_request_t, json: []const u8, status: ngx_uint_t) ngx_int_t {
    r.*.headers_out.content_type = ngx_str_t{ .len = 16, .data = @constCast("application/json") };
    r.*.headers_out.content_type_len = 16;
    r.*.headers_out.status = status;
    r.*.headers_out.content_length_n = @intCast(json.len);

    const rc = http.ngx_http_send_header(r);
    if (rc == NGX_ERROR or rc > NGX_OK) return rc;

    const b = core.castPtr(ngx.buf.ngx_buf_t, core.ngx_pcalloc(r.*.pool, @sizeOf(ngx.buf.ngx_buf_t))) orelse return NGX_ERROR;
    const data = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, json.len)) orelse return NGX_ERROR;

    @memcpy(core.slicify(u8, data, json.len), json);

    b.*.pos = data;
    b.*.last = data + json.len;
    b.*.flags.memory = true;
    b.*.flags.last_buf = true;
    b.*.flags.last_in_chain = true;

    var out: ngx.buf.ngx_chain_t = undefined;
    out.buf = b;
    out.next = null;
    return http.ngx_http_output_filter(r, &out);
}

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

    var buf: [MAX_JSON_RESPONSE_LEN]u8 = undefined;
    const json = std.fmt.bufPrint(&buf,
        \\{{"status":"{s}","healthy":{s},"ready":{s},"requests":{d},"failed":{d},"success_rate":{d},"probe_enabled":{s},"probe_healthy":{s},"probe_last_status":{d},"probe_total_successes":{d},"probe_total_failures":{d},"probe_consecutive_successes":{d},"probe_consecutive_failures":{d}}}
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
        snapshot.probe_total_successes,
        snapshot.probe_total_failures,
        snapshot.probe_consecutive_successes,
        snapshot.probe_consecutive_failures,
    }) catch return NGX_ERROR;

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

fn scheduleNextProbe(delay_ms: ngx_msec_t) void {
    event.ngx_event_add_timer(&probe_timer_event, delay_ms);
}

fn hostSlice() []const u8 {
    return healthcheck_probe_host_buf[0..healthcheck_probe_host_len];
}

fn pathSlice() []const u8 {
    return healthcheck_probe_path_buf[0..healthcheck_probe_path_len];
}

fn performActiveProbe() ProbeResult {
    if (!healthcheck_probe_enabled or healthcheck_probe_host_len == 0) {
        return .{ .success = true, .status = 0 };
    }

    var host_buf: [MAX_PROBE_HOST_LEN + 1]u8 = [_]u8{0} ** (MAX_PROBE_HOST_LEN + 1);
    var port_buf: [6:0]u8 = [_:0]u8{0} ** 6;
    @memcpy(host_buf[0..healthcheck_probe_host_len], hostSlice());

    const port_slice = std.fmt.bufPrint(&port_buf, "{d}", .{healthcheck_probe_port}) catch return .{ .success = false, .status = 0 };
    port_buf[port_slice.len] = 0;

    var hints = std.mem.zeroes(AddrInfo);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    var results: ?*AddrInfo = null;
    if (getaddrinfo(host_buf[0..healthcheck_probe_host_len :0], port_buf[0..port_slice.len :0], &hints, &results) != 0 or results == null) {
        return .{ .success = false, .status = 0 };
    }
    defer freeaddrinfo(results);

    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(
        &request_buf,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\nUser-Agent: nginz-healthcheck\r\n\r\n",
        .{ pathSlice(), hostSlice() },
    ) catch return .{ .success = false, .status = 0 };

    var it = results;
    while (it) |ai| : (it = ai.ai_next) {
        if (ai.ai_addr == null) continue;

        const fd = socket(ai.ai_family, if (ai.ai_socktype != 0) ai.ai_socktype else SOCK_STREAM, ai.ai_protocol);
        if (fd < 0) continue;

        const timeout = Timeval{
            .tv_sec = @intCast(healthcheck_probe_timeout_ms / 1000),
            .tv_usec = @intCast((healthcheck_probe_timeout_ms % 1000) * 1000),
        };
        _ = setsockopt(fd, SOL_SOCKET_C, SO_RCVTIMEO_C, &timeout, @sizeOf(Timeval));
        _ = setsockopt(fd, SOL_SOCKET_C, SO_SNDTIMEO_C, &timeout, @sizeOf(Timeval));

        if (connect(fd, ai.ai_addr.?, ai.ai_addrlen) != 0) {
            _ = close(fd);
            continue;
        }

        var sent_total: usize = 0;
        while (sent_total < request.len) {
            const sent = send(fd, request.ptr + sent_total, request.len - sent_total, 0);
            if (sent <= 0) {
                _ = close(fd);
                return .{ .success = false, .status = 0 };
            }
            sent_total += @intCast(sent);
        }

        var response_buf: [256]u8 = undefined;
        const received = recv(fd, &response_buf, response_buf.len, 0);
        if (received <= 0) {
            _ = close(fd);
            return .{ .success = false, .status = 0 };
        }

        const received_slice = response_buf[0..@intCast(received)];
        if (!std.mem.startsWith(u8, received_slice, "HTTP/")) {
            _ = close(fd);
            return .{ .success = false, .status = 0 };
        }

        const first_space = std.mem.indexOfScalar(u8, received_slice, ' ') orelse {
            _ = close(fd);
            return .{ .success = false, .status = 0 };
        };
        const second_space_rel = std.mem.indexOfScalar(u8, received_slice[first_space + 1 ..], ' ') orelse {
            _ = close(fd);
            return .{ .success = false, .status = 0 };
        };
        const status_slice = received_slice[first_space + 1 .. first_space + 1 + second_space_rel];
        const status = std.fmt.parseInt(ngx_uint_t, status_slice, 10) catch {
            _ = close(fd);
            return .{ .success = false, .status = 0 };
        };
        _ = close(fd);
        return .{ .success = status >= 200 and status < 400, .status = status };
    }

    return .{ .success = false, .status = 0 };
}

fn recordProbeResult(result: ProbeResult) void {
    const store = getStore() orelse return;
    const shpool = getShpool() orelse return;

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.*.mutex);

    store.*.probe_enabled = if (healthcheck_probe_enabled) 1 else 0;
    store.*.probe_last_status = result.status;
    store.*.probe_last_checked_ms = getCurrentTimeMs();

    if (result.success) {
        store.*.probe_total_successes += 1;
        store.*.probe_consecutive_successes += 1;
        store.*.probe_consecutive_failures = 0;
        if (store.*.probe_consecutive_successes >= healthcheck_probe_pass_threshold) {
            store.*.probe_healthy = 1;
            store.*.ready = 1;
        }
    } else {
        store.*.probe_total_failures += 1;
        store.*.probe_consecutive_failures += 1;
        store.*.probe_consecutive_successes = 0;
        if (store.*.probe_consecutive_failures >= healthcheck_probe_fail_threshold) {
            store.*.probe_healthy = 0;
            store.*.ready = 0;
        }
    }
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

fn healthcheck_init_process(cycle: [*c]core.ngx_cycle_t) callconv(.c) ngx_int_t {
    if (!healthcheck_probe_enabled) return NGX_OK;
    if (ngx_worker != 0) return NGX_OK;
    if (getStore() == null) return NGX_OK;

    probe_timer_event = std.mem.zeroes(core.ngx_event_t);
    probe_timer_event.handler = healthcheck_probe_timer_handler;
    probe_timer_event.log = cycle.*.log;
    scheduleNextProbe(25);
    return NGX_OK;
}

fn healthcheck_exit_process(_: [*c]core.ngx_cycle_t) callconv(.c) void {
    if (probe_timer_event.flags.timer_set) {
        event.ngx_event_del_timer(&probe_timer_event);
    }
    probe_timer_event = std.mem.zeroes(core.ngx_event_t);
}

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
            var buf: [16]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{snapshot.probe_consecutive_failures}) catch {
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

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    if (ngx_http_healthcheck_zone == core.nullptr(core.ngx_shm_zone_t)) {
        var zone_name = ngx_string("healthcheck_zone");
        const zone = shm.ngx_shared_memory_add(cf, &zone_name, HEALTHCHECK_ZONE_SIZE, @constCast(&ngx_http_healthcheck_module));
        if (zone == core.nullptr(core.ngx_shm_zone_t)) return NGX_ERROR;
        zone.*.init = healthcheck_zone_init;
        ngx_http_healthcheck_zone = zone;
    }

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

    const cmcf = core.castPtr(http.ngx_http_core_main_conf_t, conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module)) orelse return NGX_ERROR;
    var log_handlers = NArray(http.ngx_http_handler_pt).init0(&cmcf[0].phases[10].handlers);
    const h = log_handlers.append() catch return NGX_ERROR;
    h.* = ngx_http_healthcheck_log_handler;
    return NGX_OK;
}

export const ngx_http_healthcheck_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_healthcheck_commands = [_]ngx_command_t{
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
    conf.ngx_null_command,
};

export var ngx_http_healthcheck_module = blk: {
    var m = ngx.module.make_module(@constCast(&ngx_http_healthcheck_commands), @constCast(&ngx_http_healthcheck_module_ctx));
    m.init_process = healthcheck_init_process;
    m.exit_process = healthcheck_exit_process;
    break :blk m;
};

test "healthcheck module" {}
