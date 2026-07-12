const std = @import("std");
const ngx = @import("ngx");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const shm = ngx.shm;

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
const ngx_http_variable_value_t = http.ngx_http_variable_value_t;

const ngx_string = ngx.string.ngx_string;
const NArray = ngx.array.NArray;

// External nginx core module
extern var ngx_http_core_module: ngx_module_t;

const CIRCUIT_ZONE_SIZE: usize = 128 * 1024;
const MAX_CIRCUITS = 64;
const MAX_CIRCUIT_KEY_LEN = 192;

// Circuit breaker states
const CircuitState = enum(u8) {
    closed, // Normal operation, requests pass through
    open, // Circuit tripped, requests fail fast with 503
    half_open, // Testing if service recovered
};
// Kept outside the enum so the shared-memory structure layout stays stable
// across graceful reloads. It represents a half-open circuit with its single
// recovery probe admitted.
const CIRCUIT_STATE_HALF_OPEN_PROBE_IN_FLIGHT: u8 = 3;

// Location configuration
const circuit_breaker_loc_conf = extern struct {
    enabled: ngx_flag_t,
    failure_threshold: ngx_uint_t, // failures before opening
    success_threshold: ngx_uint_t, // successes in half-open before closing
    timeout_ms: ngx_uint_t, // milliseconds before half-open
    circuit_key: ngx_str_t,
};

const SharedCircuitStats = extern struct {
    state: u8,
    failure_count: u32,
    success_count: u32,
    last_state_change_ms: i64, // timestamp when state last changed
};

const CircuitEntry = extern struct {
    key_len: u16,
    key: [MAX_CIRCUIT_KEY_LEN]u8,
    stats: SharedCircuitStats,
};

const circuit_store = extern struct {
    initialized: ngx_flag_t,
    circuit_count: ngx_uint_t,
    entries: [MAX_CIRCUITS]CircuitEntry,
};

var ngx_http_circuit_breaker_zone: [*c]core.ngx_shm_zone_t = core.nullptr(core.ngx_shm_zone_t);

fn circuitStateFromByte(value: u8) CircuitState {
    return switch (value) {
        @intFromEnum(CircuitState.open) => .open,
        @intFromEnum(CircuitState.half_open) => .half_open,
        CIRCUIT_STATE_HALF_OPEN_PROBE_IN_FLIGHT => .half_open,
        else => .closed,
    };
}

fn getCircuitStore() ?[*c]circuit_store {
    if (ngx_http_circuit_breaker_zone == core.nullptr(core.ngx_shm_zone_t)) return null;
    return core.castPtr(circuit_store, ngx_http_circuit_breaker_zone.*.data);
}

fn getCircuitShpool() ?[*c]core.ngx_slab_pool_t {
    const zone = ngx_http_circuit_breaker_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.shm.addr == null or zone.*.data == null) {
        return null;
    }
    return core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr);
}

fn ngx_http_circuit_breaker_zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        zone.*.data = data;
        return NGX_OK;
    }

    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        zone.*.data = shpool.*.data;
        return NGX_OK;
    }

    const store_mem = shm.ngx_slab_calloc(shpool, @sizeOf(circuit_store)) orelse return NGX_ERROR;
    const store = core.castPtr(circuit_store, store_mem) orelse return NGX_ERROR;
    store.* = std.mem.zeroes(circuit_store);
    store.*.initialized = 1;
    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

fn initCircuitKey(cf: [*c]ngx_conf_t, lccf: *circuit_breaker_loc_conf) [*c]u8 {
    const clcf = core.castPtr(
        http.ngx_http_core_loc_conf_t,
        conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
    ) orelse return conf.NGX_CONF_ERROR;
    const cscf = core.castPtr(
        http.ngx_http_core_srv_conf_t,
        conf.ngx_http_conf_get_module_srv_conf(cf, &ngx_http_core_module),
    ) orelse return conf.NGX_CONF_ERROR;

    const server_name = if (cscf.*.server_name.len > 0 and cscf.*.server_name.data != null)
        core.slicify(u8, cscf.*.server_name.data, cscf.*.server_name.len)
    else
        "_";

    const location_name = if (clcf.*.name.len > 0 and clcf.*.name.data != null)
        core.slicify(u8, clcf.*.name.data, clcf.*.name.len)
    else
        "/";

    const key_buf = core.castPtr(u8, core.ngx_pnalloc(cf.*.pool, MAX_CIRCUIT_KEY_LEN)) orelse return conf.NGX_CONF_ERROR;
    const key_slice = core.slicify(u8, key_buf, MAX_CIRCUIT_KEY_LEN);
    const rendered = std.fmt.bufPrint(key_slice, "{s}|{s}", .{ server_name, location_name }) catch return conf.NGX_CONF_ERROR;

    lccf.*.circuit_key = ngx_str_t{ .data = key_buf, .len = rendered.len };
    return conf.NGX_CONF_OK;
}

fn findOrCreateCircuit(store: *circuit_store, key: []const u8) ?*SharedCircuitStats {
    for (&store.entries) |*entry| {
        const entry_key: []const u8 = @ptrCast(entry.key[0..entry.key_len]);
        if (entry.key_len == key.len and std.mem.eql(u8, entry_key, key)) {
            return &entry.stats;
        }
    }

    if (store.*.circuit_count >= MAX_CIRCUITS) {
        return null;
    }

    for (&store.entries) |*entry| {
        if (entry.key_len == 0) {
            entry.* = std.mem.zeroes(CircuitEntry);
            const copy_len = @min(key.len, MAX_CIRCUIT_KEY_LEN);
            @memcpy(entry.key[0..copy_len], key[0..copy_len]);
            entry.key_len = @intCast(copy_len);
            entry.stats.state = @intFromEnum(CircuitState.closed);
            store.*.circuit_count += 1;
            return &entry.stats;
        }
    }

    return null;
}

fn getCircuitStats(lccf: *circuit_breaker_loc_conf) ?[*c]SharedCircuitStats {
    const store_ptr = getCircuitStore() orelse return null;
    const store = core.castPtr(circuit_store, store_ptr) orelse return null;
    const key = core.slicify(u8, lccf.*.circuit_key.data, lccf.*.circuit_key.len);
    return findOrCreateCircuit(store, key);
}

// Get current time in milliseconds
fn getCurrentTimeMs() i64 {
    // Use nginx's cached time
    const tp = core.ngx_timeofday();
    if (tp) |t| {
        return @as(i64, @intCast(t.*.sec)) * 1000 + @as(i64, @intCast(t.*.msec));
    }
    return 0;
}

// Check if circuit should transition from OPEN to HALF_OPEN
fn checkTimeout(stats: *SharedCircuitStats, timeout_ms: ngx_uint_t) void {
    if (circuitStateFromByte(stats.state) != .open) return;

    const now = getCurrentTimeMs();
    const elapsed = now - stats.last_state_change_ms;

    if (elapsed >= @as(i64, @intCast(timeout_ms))) {
        stats.state = @intFromEnum(CircuitState.half_open);
        stats.success_count = 0;
        stats.failure_count = 0;
        stats.last_state_change_ms = now;
    }
}

// Record a successful request
fn recordSuccess(stats: *SharedCircuitStats, success_threshold: ngx_uint_t) void {
    switch (circuitStateFromByte(stats.state)) {
        .closed => {
            // Reset failure count on success
            stats.failure_count = 0;
        },
        .half_open => {
            stats.success_count += 1;
            if (stats.success_count >= success_threshold) {
                // Enough successes, close the circuit
                stats.state = @intFromEnum(CircuitState.closed);
                stats.failure_count = 0;
                stats.success_count = 0;
                stats.last_state_change_ms = getCurrentTimeMs();
            } else {
                // The single half-open probe completed successfully; admit
                // the next probe only after this outcome is recorded.
                stats.state = @intFromEnum(CircuitState.half_open);
            }
        },
        .open => {
            // Shouldn't happen - requests blocked when open
        },
    }
}

// Record a failed request
fn recordFailure(stats: *SharedCircuitStats, failure_threshold: ngx_uint_t) void {
    switch (circuitStateFromByte(stats.state)) {
        .closed => {
            stats.failure_count += 1;
            if (stats.failure_count >= failure_threshold) {
                // Too many failures, open the circuit
                stats.state = @intFromEnum(CircuitState.open);
                stats.last_state_change_ms = getCurrentTimeMs();
            }
        },
        .half_open => {
            // Any failure in half-open immediately opens the circuit
            stats.state = @intFromEnum(CircuitState.open);
            stats.failure_count = 0;
            stats.success_count = 0;
            stats.last_state_change_ms = getCurrentTimeMs();
        },
        .open => {
            // Already open
        },
    }
}

// Request context to track if we should record the response
const circuit_breaker_ctx = extern struct {
    should_track: ngx_flag_t,
    is_half_open_probe: ngx_flag_t,
    admission: ngx_str_t,
};

const admission_allow = ngx_string("allow");
const admission_open = ngx_string("open");
const admission_half_open_busy = ngx_string("half_open_busy");
const admission_capacity = ngx_string("capacity");

// Access phase handler - check circuit state
fn ngx_http_circuit_breaker_access_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        circuit_breaker_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_circuit_breaker_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) {
        return NGX_DECLINED;
    }

    // Allocate request-local state before reserving a shared half-open slot.
    // Otherwise an allocation failure after the reservation can leave the
    // circuit permanently reporting a probe in flight.
    const ctx = http.ngz_http_get_module_ctx(circuit_breaker_ctx, r, &ngx_http_circuit_breaker_module) catch return NGX_ERROR;
    const shpool = getCircuitShpool() orelse return http.NGX_HTTP_SERVICE_UNAVAILABLE;
    shm.ngx_shmtx_lock(&shpool.*.mutex);
    var is_half_open_probe: ngx_flag_t = 0;
    const admission = blk: {
        // Saturation or missing shared state must fail closed. Failing open
        // here silently removes protection precisely when its state is gone.
        const stats = getCircuitStats(lccf) orelse break :blk admission_capacity;

        checkTimeout(stats, lccf.*.timeout_ms);
        switch (circuitStateFromByte(stats.*.state)) {
            .open => break :blk admission_open,
            .half_open => {
                // A half-open circuit admits exactly one probe. The marker is
                // set while locked so concurrent workers cannot stampede it.
                if (stats.*.state == CIRCUIT_STATE_HALF_OPEN_PROBE_IN_FLIGHT) {
                    break :blk admission_half_open_busy;
                }
                stats.*.state = CIRCUIT_STATE_HALF_OPEN_PROBE_IN_FLIGHT;
                is_half_open_probe = 1;
                break :blk admission_allow;
            },
            .closed => break :blk admission_allow,
        }
    };
    shm.ngx_shmtx_unlock(&shpool.*.mutex);

    // Do not render a response under the shared-memory mutex: response
    // headers can evaluate observability variables that acquire this mutex.
    if (admission.data == admission_allow.data) {
        ctx.*.should_track = 1;
        ctx.*.is_half_open_probe = is_half_open_probe;
        ctx.*.admission = admission_allow;
        return NGX_DECLINED;
    }
    ctx.*.should_track = 0;
    ctx.*.is_half_open_probe = 0;
    ctx.*.admission = admission;
    r.*.headers_out.status = http.NGX_HTTP_SERVICE_UNAVAILABLE;
    return http.NGX_HTTP_SERVICE_UNAVAILABLE;
}

// Log phase handler - record success/failure
fn ngx_http_circuit_breaker_log_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    // Don't track subrequests
    if (r != r.*.main) {
        return NGX_OK;
    }

    const lccf = core.castPtr(
        circuit_breaker_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_circuit_breaker_module),
    ) orelse return NGX_OK;

    if (lccf.*.enabled != 1) {
        return NGX_OK;
    }

    // Check if we should track this request
    const ctx = http.ngz_http_get_module_ctx(circuit_breaker_ctx, r, &ngx_http_circuit_breaker_module) catch return NGX_OK;
    if (ctx.*.should_track != 1) {
        return NGX_OK;
    }

    const shpool = getCircuitShpool() orelse return NGX_OK;
    shm.ngx_shmtx_lock(&shpool.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.*.mutex);

    const stats = getCircuitStats(lccf) orelse return NGX_OK;
    const status = r.*.headers_out.status;

    // Only the request that acquired the half-open slot may settle it. A
    // slower request admitted while the circuit was closed can finish after
    // the transition and must not be mistaken for the recovery probe.
    if (ctx.*.is_half_open_probe == 1) {
        if (stats.*.state != CIRCUIT_STATE_HALF_OPEN_PROBE_IN_FLIGHT) return NGX_OK;
        stats.*.state = @intFromEnum(CircuitState.half_open);
    } else if (circuitStateFromByte(stats.*.state) != .closed) {
        return NGX_OK;
    }

    // Consider 5xx as failures, everything else as success
    if (status >= 500 and status < 600) {
        recordFailure(stats, lccf.*.failure_threshold);
    } else if (status > 0) {
        recordSuccess(stats, lccf.*.success_threshold);
    }

    return NGX_OK;
}

// Variable getter for $ngz_circuit_state
fn ngx_http_circuit_state_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;

    const lccf = core.castPtr(
        circuit_breaker_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_circuit_breaker_module),
    ) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };

    if (lccf.*.enabled != 1) {
        v.*.flags.not_found = true;
        return NGX_OK;
    }

    const shpool = getCircuitShpool() orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    shm.ngx_shmtx_lock(&shpool.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.*.mutex);

    const stats = getCircuitStats(lccf) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    checkTimeout(stats, lccf.*.timeout_ms);

    const state_str = switch (circuitStateFromByte(stats.*.state)) {
        .closed => "closed",
        .open => "open",
        .half_open => "half_open",
    };

    v.*.data = @constCast(state_str.ptr);
    v.*.flags.len = @intCast(state_str.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;

    return NGX_OK;
}

fn ngx_http_circuit_admission_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = http.ngz_http_get_module_ctx(circuit_breaker_ctx, r, &ngx_http_circuit_breaker_module) catch {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    if (ctx.*.admission.len == 0 or ctx.*.admission.data == null) {
        v.*.flags.not_found = true;
        return NGX_OK;
    }
    v.*.data = ctx.*.admission.data;
    v.*.flags.len = @intCast(ctx.*.admission.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

const CIRCUIT_METRIC_ENTRIES: core.uintptr_t = 0;
const CIRCUIT_METRIC_CAPACITY: core.uintptr_t = 1;

fn ngx_http_circuit_metric_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    var value: ngx_uint_t = MAX_CIRCUITS;
    if (data == CIRCUIT_METRIC_ENTRIES) {
        const shpool = getCircuitShpool() orelse {
            v.*.flags.not_found = true;
            return NGX_OK;
        };
        shm.ngx_shmtx_lock(&shpool.*.mutex);
        const store = getCircuitStore() orelse {
            shm.ngx_shmtx_unlock(&shpool.*.mutex);
            v.*.flags.not_found = true;
            return NGX_OK;
        };
        value = store.*.circuit_count;
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
    }

    const out = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, 32)) orelse return NGX_ERROR;
    const rendered = std.fmt.bufPrint(out[0..32], "{d}", .{value}) catch return NGX_ERROR;
    v.*.data = rendered.ptr;
    v.*.flags.len = @intCast(rendered.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(circuit_breaker_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = conf.NGX_CONF_UNSET;
        p.*.failure_threshold = 5;
        p.*.success_threshold = 2;
        p.*.timeout_ms = 30000; // 30 seconds
        p.*.circuit_key = ngx_str_t{ .len = 0, .data = null };
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
    const prev = core.castPtr(circuit_breaker_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(circuit_breaker_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.enabled == conf.NGX_CONF_UNSET) {
        c.*.enabled = if (prev.*.enabled == conf.NGX_CONF_UNSET) 0 else prev.*.enabled;
    }

    if (c.*.failure_threshold == 5 and prev.*.failure_threshold != 5) {
        c.*.failure_threshold = prev.*.failure_threshold;
    }

    if (c.*.success_threshold == 2 and prev.*.success_threshold != 2) {
        c.*.success_threshold = prev.*.success_threshold;
    }

    if (c.*.timeout_ms == 30000 and prev.*.timeout_ms != 30000) {
        c.*.timeout_ms = prev.*.timeout_ms;
    }

    if (c.*.circuit_key.len == 0) {
        c.*.circuit_key = prev.*.circuit_key;
    }

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_threshold(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(circuit_breaker_loc_conf, loc)) |lccf| {
        lccf.*.enabled = 1;
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const slice = core.slicify(u8, arg.*.data, arg.*.len);
            const threshold = std.fmt.parseInt(ngx_uint_t, slice, 10) catch return conf.NGX_CONF_ERROR;
            if (threshold == 0) return conf.NGX_CONF_ERROR;
            lccf.*.failure_threshold = threshold;
        }
        return initCircuitKey(cf, lccf);
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_success_threshold(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(circuit_breaker_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const slice = core.slicify(u8, arg.*.data, arg.*.len);
            const threshold = std.fmt.parseInt(ngx_uint_t, slice, 10) catch return conf.NGX_CONF_ERROR;
            if (threshold == 0) return conf.NGX_CONF_ERROR;
            lccf.*.success_threshold = threshold;
        }
        if (lccf.*.enabled == 1 and lccf.*.circuit_key.len == 0) {
            return initCircuitKey(cf, lccf);
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_timeout(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(circuit_breaker_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const slice = core.slicify(u8, arg.*.data, arg.*.len);
            // Parse as milliseconds or with 's' suffix for seconds
            if (slice.len > 0 and slice[slice.len - 1] == 's') {
                const secs = std.fmt.parseInt(ngx_uint_t, slice[0 .. slice.len - 1], 10) catch return conf.NGX_CONF_ERROR;
                if (secs == 0) return conf.NGX_CONF_ERROR;
                lccf.*.timeout_ms = std.math.mul(ngx_uint_t, secs, 1000) catch return conf.NGX_CONF_ERROR;
            } else {
                const timeout = std.fmt.parseInt(ngx_uint_t, slice, 10) catch return conf.NGX_CONF_ERROR;
                if (timeout == 0) return conf.NGX_CONF_ERROR;
                lccf.*.timeout_ms = timeout;
            }
        }
        if (lccf.*.enabled == 1 and lccf.*.circuit_key.len == 0) {
            return initCircuitKey(cf, lccf);
        }
    }
    return conf.NGX_CONF_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    var zone_name = ngx_string("circuit_breaker_zone");
    const zone = shm.ngx_shared_memory_add(cf, &zone_name, CIRCUIT_ZONE_SIZE, @constCast(&ngx_http_circuit_breaker_module));
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return NGX_ERROR;
    zone.*.init = ngx_http_circuit_breaker_zone_init;
    ngx_http_circuit_breaker_zone = zone;

    // Register $ngz_circuit_state variable
    var vs = [_]http.ngx_http_variable_t{ http.ngx_http_variable_t{
        .name = ngx_string("ngz_circuit_state"),
        .set_handler = null,
        .get_handler = ngx_http_circuit_state_variable,
        .data = 0,
        .flags = http.NGX_HTTP_VAR_NOCACHEABLE,
        .index = 0,
    }, http.ngx_http_variable_t{
        .name = ngx_string("ngz_circuit_admission"),
        .set_handler = null,
        .get_handler = ngx_http_circuit_admission_variable,
        .data = 0,
        .flags = http.NGX_HTTP_VAR_NOCACHEABLE,
        .index = 0,
    }, http.ngx_http_variable_t{
        .name = ngx_string("ngz_circuit_entries"),
        .set_handler = null,
        .get_handler = ngx_http_circuit_metric_variable,
        .data = CIRCUIT_METRIC_ENTRIES,
        .flags = http.NGX_HTTP_VAR_NOCACHEABLE,
        .index = 0,
    }, http.ngx_http_variable_t{
        .name = ngx_string("ngz_circuit_capacity"),
        .set_handler = null,
        .get_handler = ngx_http_circuit_metric_variable,
        .data = CIRCUIT_METRIC_CAPACITY,
        .flags = http.NGX_HTTP_VAR_NOCACHEABLE,
        .index = 0,
    } };
    for (&vs) |*v| {
        if (http.ngx_http_add_variable(cf, &v.name, v.flags)) |x| {
            x.*.get_handler = v.get_handler;
            x.*.data = v.data;
        }
    }

    // Register access phase handler
    const cmcf = core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    var access_handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_ACCESS_PHASE].handlers,
    );
    const h1 = access_handlers.append() catch return NGX_ERROR;
    h1.* = ngx_http_circuit_breaker_access_handler;

    // Register log phase handler (NGX_HTTP_LOG_PHASE = 10)
    var log_handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[10].handlers,
    );
    const h2 = log_handlers.append() catch return NGX_ERROR;
    h2.* = ngx_http_circuit_breaker_log_handler;

    return NGX_OK;
}

export const ngx_http_circuit_breaker_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_circuit_breaker_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("circuit_breaker_threshold"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_threshold,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("circuit_breaker_success_threshold"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_success_threshold,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("circuit_breaker_timeout"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_timeout,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_circuit_breaker_module = ngx.module.make_module(
    @constCast(&ngx_http_circuit_breaker_commands),
    @constCast(&ngx_http_circuit_breaker_module_ctx),
);

// Tests
const expectEqual = std.testing.expectEqual;

test "circuit_breaker module" {}

test "capacity exhaustion never aliases an existing circuit" {
    var store: circuit_store = std.mem.zeroes(circuit_store);
    var key_buf: [32]u8 = undefined;

    for (0..MAX_CIRCUITS) |i| {
        const key = try std.fmt.bufPrint(&key_buf, "circuit-{d}", .{i});
        const stats = findOrCreateCircuit(&store, key) orelse return error.TestUnexpectedResult;
        stats.failure_count = @intCast(i + 1);
    }

    const first_before = store.entries[0].stats.failure_count;
    try std.testing.expect(findOrCreateCircuit(&store, "overflow-circuit") == null);
    try std.testing.expectEqual(first_before, store.entries[0].stats.failure_count);
    try std.testing.expectEqual(@as(ngx_uint_t, MAX_CIRCUITS), store.circuit_count);
}

test "an ordinary request cannot settle an in-flight half-open probe" {
    var stats = std.mem.zeroes(SharedCircuitStats);
    stats.state = CIRCUIT_STATE_HALF_OPEN_PROBE_IN_FLIGHT;
    stats.success_count = 0;

    // This is the state guard used by the log handler for a request admitted
    // before the circuit transitioned out of closed.
    if (circuitStateFromByte(stats.state) == .closed) {
        recordSuccess(&stats, 1);
    }

    try expectEqual(CIRCUIT_STATE_HALF_OPEN_PROBE_IN_FLIGHT, stats.state);
    try expectEqual(@as(ngx_uint_t, 0), stats.success_count);
}
