const std = @import("std");
const ngx = @import("ngx");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const shm = ngx.shm;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;
const NGX_DONE = core.NGX_DONE;

const ngx_str_t = core.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_msec_t = core.ngx_msec_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_buf_t = ngx.buf.ngx_buf_t;
const ngx_chain_t = ngx.buf.ngx_chain_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;

const ngx_string = ngx.string.ngx_string;
const NArray = ngx.array.NArray;

// External nginx core module
extern var ngx_http_core_module: ngx_module_t;

const PROMETHEUS_ZONE_SIZE: usize = 64 * 1024;

// Histogram buckets for request duration (in milliseconds)
// Standard buckets: 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s
const HISTOGRAM_BUCKETS = [_]u64{ 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 };
const HISTOGRAM_BUCKET_LABELS = [_][]const u8{ "0.005", "0.01", "0.025", "0.05", "0.1", "0.25", "0.5", "1", "2.5", "5", "10" };

const prometheus_metrics_store = extern struct {
    initialized: ngx_flag_t,
    requests_total: u64,
    requests_1xx: u64,
    requests_2xx: u64,
    requests_3xx: u64,
    requests_4xx: u64,
    requests_5xx: u64,
    histogram_buckets: [HISTOGRAM_BUCKETS.len]u64,
    histogram_inf: u64,
    histogram_sum: u64,
    histogram_count: u64,
};

var ngx_http_prometheus_zone: [*c]core.ngx_shm_zone_t = core.nullptr(core.ngx_shm_zone_t);

// External nginx timing
extern var ngx_current_msec: ngx_msec_t;

const prometheus_loc_conf = extern struct {
    metrics_endpoint: ngx_flag_t,
};

const ngx_http_variable_value_t = http.ngx_http_variable_value_t;

const PROMETHEUS_VAR_REQUESTS_TOTAL: core.uintptr_t = 0;
const PROMETHEUS_VAR_ERROR_RATE: core.uintptr_t = 1;

fn getMetricsStore() ?[*c]prometheus_metrics_store {
    if (ngx_http_prometheus_zone == core.nullptr(core.ngx_shm_zone_t)) return null;
    return core.castPtr(prometheus_metrics_store, ngx_http_prometheus_zone.*.data);
}

fn getMetricsShpool() ?[*c]core.ngx_slab_pool_t {
    const zone = ngx_http_prometheus_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.shm.addr == null or zone.*.data == null) {
        return null;
    }
    return core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr);
}

fn snapshotMetrics() ?prometheus_metrics_store {
    const store = getMetricsStore() orelse return null;
    const shpool = getMetricsShpool() orelse return null;

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    const snapshot = store.*;
    shm.ngx_shmtx_unlock(&shpool.*.mutex);
    return snapshot;
}

fn ngx_http_prometheus_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    const snapshot = snapshotMetrics() orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };

    switch (data) {
        PROMETHEUS_VAR_REQUESTS_TOTAL => {
            var num_buf: [24]u8 = undefined;
            const slice = std.fmt.bufPrint(&num_buf, "{d}", .{snapshot.requests_total}) catch {
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
        PROMETHEUS_VAR_ERROR_RATE => {
            const error_count = snapshot.requests_4xx + snapshot.requests_5xx;
            const scaled: u64 = if (snapshot.requests_total == 0)
                0
            else
                @divTrunc(error_count * 1000, snapshot.requests_total);
            const whole = @divTrunc(scaled, 1000);
            const frac = @mod(scaled, 1000);

            var rate_buf: [16]u8 = undefined;
            const slice = std.fmt.bufPrint(&rate_buf, "{d}.{d:0>3}", .{ whole, frac }) catch {
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

fn ngx_http_prometheus_zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        zone.*.data = data;
        return NGX_OK;
    }

    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        zone.*.data = shpool.*.data;
        return NGX_OK;
    }

    const store_mem = shm.ngx_slab_calloc(shpool, @sizeOf(prometheus_metrics_store)) orelse return NGX_ERROR;
    const store = core.castPtr(prometheus_metrics_store, store_mem) orelse return NGX_ERROR;
    store.* = std.mem.zeroes(prometheus_metrics_store);
    store.*.initialized = 1;
    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(prometheus_loc_conf, cf.*.pool)) |p| {
        p.*.metrics_endpoint = 0;
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
    const prev = core.castPtr(prometheus_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(prometheus_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.metrics_endpoint == 0) {
        c.*.metrics_endpoint = prev.*.metrics_endpoint;
    }

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_prometheus_endpoint(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;

    if (core.castPtr(prometheus_loc_conf, loc)) |lccf| {
        lccf.*.metrics_endpoint = 1;

        // Register content handler for this location
        const clcf = core.castPtr(
            http.ngx_http_core_loc_conf_t,
            conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
        ) orelse return conf.NGX_CONF_OK;

        clcf.*.handler = ngx_http_prometheus_handler;
    }
    return conf.NGX_CONF_OK;
}

// Format a u64 as decimal string into buffer, return slice
fn formatU64(buf: []u8, value: u64) []const u8 {
    var temp: [20]u8 = undefined;
    var v = value;
    var i: usize = 20;

    if (v == 0) {
        return "0";
    }

    while (v > 0) {
        i -= 1;
        temp[i] = @intCast((v % 10) + '0');
        v /= 10;
    }

    const len = 20 - i;
    @memcpy(buf[0..len], temp[i..20]);
    return buf[0..len];
}

// Content handler for /metrics endpoint
export fn ngx_http_prometheus_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    // Only handle GET/HEAD
    if (r.*.method != http.NGX_HTTP_GET and r.*.method != http.NGX_HTTP_HEAD) {
        return http.NGX_HTTP_NOT_ALLOWED;
    }

    // Set content type
    const content_type = ngx_string("text/plain; version=0.0.4; charset=utf-8");
    r.*.headers_out.content_type = content_type;
    r.*.headers_out.content_type_len = content_type.len;

    // Allocate a large buffer for metrics output
    const max_response_len: usize = 8192;
    const buf_mem = core.ngx_pnalloc(r.*.pool, max_response_len) orelse return NGX_ERROR;
    const buf_ptr = core.castPtr(u8, buf_mem) orelse return NGX_ERROR;
    var pos: usize = 0;

    // Helper to append string
    const appendStr = struct {
        fn f(buffer: [*]u8, p: *usize, s: []const u8) void {
            @memcpy(buffer[p.*..][0..s.len], s);
            p.* += s.len;
        }
    }.f;

    // Helper to append number
    const appendNum = struct {
        fn f(buffer: [*]u8, p: *usize, value: u64) void {
            var temp: [20]u8 = undefined;
            var v = value;
            var i: usize = 20;
            if (v == 0) {
                buffer[p.*] = '0';
                p.* += 1;
                return;
            }
            while (v > 0) {
                i -= 1;
                temp[i] = @intCast((v % 10) + '0');
                v /= 10;
            }
            const len = 20 - i;
            @memcpy(buffer[p.*..][0..len], temp[i..20]);
            p.* += len;
        }
    }.f;

    const store = getMetricsStore() orelse return NGX_ERROR;
    const shpool = getMetricsShpool() orelse return NGX_ERROR;

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    const snapshot = store.*;
    shm.ngx_shmtx_unlock(&shpool.*.mutex);

    // nginx_up gauge
    appendStr(buf_ptr, &pos, "# HELP nginx_up Whether nginx is up\n");
    appendStr(buf_ptr, &pos, "# TYPE nginx_up gauge\n");
    appendStr(buf_ptr, &pos, "nginx_up 1\n\n");

    // nginx_http_requests_total counter
    appendStr(buf_ptr, &pos, "# HELP nginx_http_requests_total Total number of HTTP requests\n");
    appendStr(buf_ptr, &pos, "# TYPE nginx_http_requests_total counter\n");
    appendStr(buf_ptr, &pos, "nginx_http_requests_total ");
    appendNum(buf_ptr, &pos, snapshot.requests_total);
    appendStr(buf_ptr, &pos, "\n\n");

    // nginx_http_requests_by_status counter
    appendStr(buf_ptr, &pos, "# HELP nginx_http_requests_by_status HTTP requests by status code class\n");
    appendStr(buf_ptr, &pos, "# TYPE nginx_http_requests_by_status counter\n");
    appendStr(buf_ptr, &pos, "nginx_http_requests_by_status{status=\"1xx\"} ");
    appendNum(buf_ptr, &pos, snapshot.requests_1xx);
    appendStr(buf_ptr, &pos, "\n");
    appendStr(buf_ptr, &pos, "nginx_http_requests_by_status{status=\"2xx\"} ");
    appendNum(buf_ptr, &pos, snapshot.requests_2xx);
    appendStr(buf_ptr, &pos, "\n");
    appendStr(buf_ptr, &pos, "nginx_http_requests_by_status{status=\"3xx\"} ");
    appendNum(buf_ptr, &pos, snapshot.requests_3xx);
    appendStr(buf_ptr, &pos, "\n");
    appendStr(buf_ptr, &pos, "nginx_http_requests_by_status{status=\"4xx\"} ");
    appendNum(buf_ptr, &pos, snapshot.requests_4xx);
    appendStr(buf_ptr, &pos, "\n");
    appendStr(buf_ptr, &pos, "nginx_http_requests_by_status{status=\"5xx\"} ");
    appendNum(buf_ptr, &pos, snapshot.requests_5xx);
    appendStr(buf_ptr, &pos, "\n\n");

    // nginx_http_request_duration_seconds histogram
    appendStr(buf_ptr, &pos, "# HELP nginx_http_request_duration_seconds Request duration in seconds\n");
    appendStr(buf_ptr, &pos, "# TYPE nginx_http_request_duration_seconds histogram\n");

    // Output histogram buckets
    for (HISTOGRAM_BUCKET_LABELS, 0..) |label, i| {
        appendStr(buf_ptr, &pos, "nginx_http_request_duration_seconds_bucket{le=\"");
        appendStr(buf_ptr, &pos, label);
        appendStr(buf_ptr, &pos, "\"} ");
        appendNum(buf_ptr, &pos, snapshot.histogram_buckets[i]);
        appendStr(buf_ptr, &pos, "\n");
    }

    // +Inf bucket
    appendStr(buf_ptr, &pos, "nginx_http_request_duration_seconds_bucket{le=\"+Inf\"} ");
    appendNum(buf_ptr, &pos, snapshot.histogram_inf);
    appendStr(buf_ptr, &pos, "\n");

    // Sum (convert ms to seconds with 3 decimal places)
    appendStr(buf_ptr, &pos, "nginx_http_request_duration_seconds_sum ");
    const sum_secs = snapshot.histogram_sum / 1000;
    const sum_ms = snapshot.histogram_sum % 1000;
    appendNum(buf_ptr, &pos, sum_secs);
    appendStr(buf_ptr, &pos, ".");
    // Pad milliseconds with leading zeros
    if (sum_ms < 100) appendStr(buf_ptr, &pos, "0");
    if (sum_ms < 10) appendStr(buf_ptr, &pos, "0");
    appendNum(buf_ptr, &pos, sum_ms);
    appendStr(buf_ptr, &pos, "\n");

    // Count
    appendStr(buf_ptr, &pos, "nginx_http_request_duration_seconds_count ");
    appendNum(buf_ptr, &pos, snapshot.histogram_count);
    appendStr(buf_ptr, &pos, "\n");

    // Set content length
    r.*.headers_out.status = 200;
    r.*.headers_out.content_length_n = @intCast(pos);

    // Send headers
    const header_rc = http.ngx_http_send_header(r);
    if (header_rc == NGX_ERROR or header_rc > NGX_OK) {
        return header_rc;
    }
    if (r.*.method == http.NGX_HTTP_HEAD or r.*.flags1.header_only) {
        return NGX_OK;
    }

    // Create output buffer
    const b = core.castPtr(ngx_buf_t, core.ngx_pcalloc(r.*.pool, @sizeOf(ngx_buf_t))) orelse return NGX_ERROR;

    b.*.pos = buf_ptr;
    b.*.last = buf_ptr + pos;
    b.*.flags.memory = true;
    b.*.flags.last_buf = (r == r.*.main);
    b.*.flags.last_in_chain = true;

    // Create chain
    var out: ngx_chain_t = undefined;
    out.buf = b;
    out.next = null;

    return http.ngx_http_output_filter(r, &out);
}

// Log phase handler to count requests and track duration
fn ngx_http_prometheus_log_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    // Don't count subrequests
    if (r != r.*.main) {
        return NGX_OK;
    }

    // Don't count the metrics endpoint itself
    const lccf = core.castPtr(
        prometheus_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_prometheus_module),
    );
    if (lccf != null and lccf.?.*.metrics_endpoint == 1) {
        return NGX_OK;
    }

    const store = getMetricsStore() orelse return NGX_OK;
    const shpool = getMetricsShpool() orelse return NGX_OK;

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.*.mutex);

    // Increment total counter
    store.*.requests_total += 1;

    // Increment status-specific counter
    const status = r.*.headers_out.status;
    if (status >= 100 and status < 200) {
        store.*.requests_1xx += 1;
    } else if (status >= 200 and status < 300) {
        store.*.requests_2xx += 1;
    } else if (status >= 300 and status < 400) {
        store.*.requests_3xx += 1;
    } else if (status >= 400 and status < 500) {
        store.*.requests_4xx += 1;
    } else if (status >= 500 and status < 600) {
        store.*.requests_5xx += 1;
    }

    // Calculate request duration in milliseconds
    const start_time_ms: u64 = @as(u64, @intCast(r.*.start_sec)) * 1000 + r.*.start_msec;
    const current_ms: u64 = ngx_current_msec;
    const duration_ms: u64 = if (current_ms >= start_time_ms) current_ms - start_time_ms else 0;

    // Update histogram buckets (cumulative)
    for (&store[0].histogram_buckets, 0..) |*bucket, i| {
        if (duration_ms <= HISTOGRAM_BUCKETS[i]) {
            bucket.* += 1;
        }
    }

    // Update +Inf bucket, sum, and count
    store.*.histogram_inf += 1;
    store.*.histogram_sum += duration_ms;
    store.*.histogram_count += 1;

    return NGX_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    var zone_name = ngx_string("prometheus_metrics_zone");
    const zone = shm.ngx_shared_memory_add(cf, &zone_name, PROMETHEUS_ZONE_SIZE, @constCast(&ngx_http_prometheus_module));
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return NGX_ERROR;
    zone.*.init = ngx_http_prometheus_zone_init;
    ngx_http_prometheus_zone = zone;

    var vs = [_]http.ngx_http_variable_t{
        http.ngx_http_variable_t{ .name = ngx_string("prometheus_requests_total"), .set_handler = null, .get_handler = ngx_http_prometheus_variable, .data = PROMETHEUS_VAR_REQUESTS_TOTAL, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("prometheus_error_rate"), .set_handler = null, .get_handler = ngx_http_prometheus_variable, .data = PROMETHEUS_VAR_ERROR_RATE, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
    };
    for (&vs) |*v| {
        if (http.ngx_http_add_variable(cf, &v.name, v.flags)) |x| {
            x.*.get_handler = v.get_handler;
            x.*.data = v.data;
        }
    }

    // Register log phase handler
    const cmcf = core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    // NGX_HTTP_LOG_PHASE = 10
    var handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[10].handlers,
    );
    const h = handlers.append() catch return NGX_ERROR;
    h.* = ngx_http_prometheus_log_handler;

    return NGX_OK;
}

export const ngx_http_prometheus_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_prometheus_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("prometheus_metrics"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_prometheus_endpoint,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_prometheus_module = ngx.module.make_module(
    @constCast(&ngx_http_prometheus_commands),
    @constCast(&ngx_http_prometheus_module_ctx),
);

// Tests
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "prometheus module" {}

test "formatU64" {
    var buf: [20]u8 = undefined;
    try expectEqualStrings("0", formatU64(&buf, 0));
    try expectEqualStrings("123", formatU64(&buf, 123));
    try expectEqualStrings("9999999", formatU64(&buf, 9999999));
}
