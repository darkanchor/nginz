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

// Location configuration
const ratelimit_loc_conf = extern struct {
    enabled: ngx_flag_t,
    rate: ngx_uint_t, // requests per second
    rate_set: ngx_flag_t,
    burst: ngx_uint_t, // extra requests allowed
    burst_set: ngx_flag_t,
    key_var: ngx_str_t,
    key_var_index: ngx_int_t,
    cost_var: ngx_str_t,
    cost_var_index: ngx_int_t,
    skip_var: ngx_str_t,
    skip_var_index: ngx_int_t,
    bucket_scope: ngx_str_t,
};

const RATELIMIT_ZONE_SIZE: usize = 128 * 1024;

// Shared cross-worker rate limit entry
const RateLimitEntry = extern struct {
    key_hash: u64,
    count: u64,
    window_start: i64, // timestamp in seconds
    last_used: i64,
};

const MAX_ENTRIES = 1024;

const ratelimit_store = extern struct {
    initialized: ngx_flag_t,
    entry_count: ngx_uint_t,
    entries: [MAX_ENTRIES]RateLimitEntry,
    capacity_rejected: u64,
    reclaimed_entries: u64,
};

var ngx_http_ratelimit_zone: [*c]core.ngx_shm_zone_t = core.nullptr(core.ngx_shm_zone_t);

const ratelimit_ctx = extern struct {
    decision: ngx_str_t,
    key: ngx_str_t,
    source: ngx_str_t,
    cost: ngx_uint_t,
};

const decision_allow = ngx_string("allow");
const decision_deny = ngx_string("deny");
const source_ip = ngx_string("ip");
const source_variable = ngx_string("variable");

// Simple hash function for IP address string
fn hashIPString(addr_text: ngx_str_t) u32 {
    if (addr_text.len == 0 or addr_text.data == null) return 0;

    const slice = core.slicify(u8, addr_text.data, addr_text.len);
    var hash: u32 = 0;
    for (slice) |c| {
        hash = hash *% 31 +% c;
    }
    return hash;
}

fn hashBytes(bytes: []const u8) u64 {
    var hash: u64 = 1469598103934665603;
    for (bytes) |b| {
        hash ^= b;
        hash *%= 1099511628211;
    }
    return if (hash == 0) 1 else hash;
}

fn buildBucketHash(lccf: *ratelimit_loc_conf, key_hash: u64) u64 {
    const scope_hash = hashBytes(core.slicify(u8, lccf.*.bucket_scope.data, lccf.*.bucket_scope.len));
    var data: [@sizeOf(u64) * 2]u8 = undefined;
    @memcpy(data[0..@sizeOf(u64)], std.mem.asBytes(&scope_hash));
    @memcpy(data[@sizeOf(u64)..], std.mem.asBytes(&key_hash));
    return hashBytes(&data);
}

// Get current time in seconds
fn getCurrentTimeSec() i64 {
    const tp = core.ngx_timeofday();
    if (tp) |t| {
        return @intCast(t.*.sec);
    }
    return 0;
}

fn getRateLimitStore() ?[*c]ratelimit_store {
    if (ngx_http_ratelimit_zone == core.nullptr(core.ngx_shm_zone_t)) return null;
    return core.castPtr(ratelimit_store, ngx_http_ratelimit_zone.*.data);
}

fn getRateLimitShpool() ?[*c]core.ngx_slab_pool_t {
    const zone = ngx_http_ratelimit_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.shm.addr == null or zone.*.data == null) {
        return null;
    }
    return core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr);
}

fn ngx_http_ratelimit_zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        zone.*.data = data;
        return NGX_OK;
    }

    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        zone.*.data = shpool.*.data;
        return NGX_OK;
    }

    const store_mem = shm.ngx_slab_calloc(shpool, @sizeOf(ratelimit_store)) orelse return NGX_ERROR;
    const store = core.castPtr(ratelimit_store, store_mem) orelse return NGX_ERROR;
    store.* = std.mem.zeroes(ratelimit_store);
    store.*.initialized = 1;
    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

fn getOrCreateEntry(store: *ratelimit_store, key_hash: u64, current_time: i64) ?*RateLimitEntry {
    var empty_entry: ?*RateLimitEntry = null;
    var reusable_entry: ?*RateLimitEntry = null;

    for (&store.entries) |*entry| {
        if (entry.key_hash == 0) {
            if (empty_entry == null) empty_entry = entry;
            continue;
        }
        if (entry.key_hash == key_hash) return entry;
        if (entry.window_start < current_time and reusable_entry == null) reusable_entry = entry;
    }

    // Never evict a live window: that resets another client's enforcement
    // budget.  Saturation is conservatively denied until an entry expires.
    const entry = empty_entry orelse reusable_entry orelse {
        store.capacity_rejected += 1;
        return null;
    };
    if (entry.key_hash == 0) store.entry_count += 1;
    if (entry.key_hash != 0) store.reclaimed_entries += 1;
    entry.* = .{
        .key_hash = key_hash,
        .count = 0,
        .window_start = current_time,
        .last_used = current_time,
    };
    return entry;
}

// Check rate limit and return true if allowed
fn checkRateLimit(store: *ratelimit_store, key_hash: u64, rate: ngx_uint_t, burst: ngx_uint_t, cost: ngx_uint_t) bool {
    const current_time = getCurrentTimeSec();
    const entry = getOrCreateEntry(store, key_hash, current_time) orelse return false;

    // Check if window has expired (1 second window)
    if (current_time > entry.window_start) {
        // Reset for new window
        entry.window_start = current_time;
        entry.count = 0;
    }

    entry.last_used = current_time;

    // Check if under limit (rate + burst)
    const limit: u64 = @as(u64, rate) + @as(u64, burst);
    if (cost == 0) return true;
    const next = entry.count +| @as(u64, cost);
    if (next <= limit) {
        entry.count = next;
        return true;
    }

    return false;
}

// Get remaining requests in current window
fn getRemainingRequests(store: *ratelimit_store, key_hash: u64, rate: ngx_uint_t, burst: ngx_uint_t) u32 {
    const current_time = getCurrentTimeSec();
    const limit = rate + burst;

    for (&store.entries) |*entry| {
        if (entry.key_hash == key_hash) {
            if (current_time == entry.window_start) {
                if (entry.count >= limit) return 0;
                return @intCast(@as(u64, limit) - entry.count);
            }
            return @intCast(limit);
        }
    }

    // No entry found, full limit available
    return limit;
}

fn initBucketScope(cf: [*c]ngx_conf_t, lccf: *ratelimit_loc_conf) [*c]u8 {
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

    const buf_len = server_name.len + location_name.len + 2;
    const scope_buf = core.castPtr(u8, core.ngx_pnalloc(cf.*.pool, buf_len)) orelse return conf.NGX_CONF_ERROR;
    const scope_slice = core.slicify(u8, scope_buf, buf_len);
    const rendered = std.fmt.bufPrint(scope_slice, "{s}|{s}", .{ server_name, location_name }) catch return conf.NGX_CONF_ERROR;
    lccf.*.bucket_scope = ngx_str_t{ .data = scope_buf, .len = rendered.len };
    return conf.NGX_CONF_OK;
}

fn setCtx(r: [*c]ngx_http_request_t, decision: ngx_str_t, key: ngx_str_t, source: ngx_str_t, cost: ngx_uint_t) void {
    const ctx = core.ngz_pcalloc_c(ratelimit_ctx, r.*.pool) orelse return;
    ctx.*.decision = decision;
    ctx.*.key = key;
    ctx.*.source = source;
    ctx.*.cost = cost;
    r.*.ctx[ngx_http_ratelimit_module.ctx_index] = ctx;
}

fn parseRateValue(slice: []const u8) ?ngx_uint_t {
    if (slice.len == 0) return null;
    if (std.mem.endsWith(u8, slice, "r/s")) {
        if (slice.len <= 3) return null;
        return std.fmt.parseInt(ngx_uint_t, slice[0 .. slice.len - 3], 10) catch null;
    }
    return std.fmt.parseInt(ngx_uint_t, slice, 10) catch null;
}

fn resolveIndexedVariable(r: [*c]ngx_http_request_t, idx: ngx_int_t) ?[*c]ngx_http_variable_value_t {
    if (idx < 0) return null;
    const value = http.ngx_http_get_flushed_variable(r, @intCast(idx));
    if (value == null or value == core.nullptr(ngx_http_variable_value_t)) return null;
    if (value.*.flags.not_found) return null;
    return value;
}

fn parseBoolVariable(value: [*c]ngx_http_variable_value_t) bool {
    const slice = core.slicify(u8, value.*.data, value.*.flags.len);
    return std.mem.eql(u8, slice, "1") or
        std.ascii.eqlIgnoreCase(slice, "true") or
        std.ascii.eqlIgnoreCase(slice, "yes") or
        std.ascii.eqlIgnoreCase(slice, "on");
}

fn getRateLimitKey(r: [*c]ngx_http_request_t, lccf: *ratelimit_loc_conf) struct { hash: u64, key: ngx_str_t, source: ngx_str_t } {
    if (resolveIndexedVariable(r, lccf.*.key_var_index)) |value| {
        const slice = core.slicify(u8, value.*.data, value.*.flags.len);
        if (slice.len > 0) {
            return .{
                .hash = hashBytes(slice),
                .key = ngx_str_t{ .data = value.*.data, .len = value.*.flags.len },
                .source = source_variable,
            };
        }
    }

    const addr_text = r.*.connection.*.addr_text;
    var ip_hash = hashIPString(addr_text);
    if (ip_hash == 0) ip_hash = 1;
    return .{
        .hash = ip_hash,
        .key = addr_text,
        .source = source_ip,
    };
}

fn getRequestCost(r: [*c]ngx_http_request_t, lccf: *ratelimit_loc_conf) ngx_uint_t {
    if (resolveIndexedVariable(r, lccf.*.cost_var_index)) |value| {
        const slice = core.slicify(u8, value.*.data, value.*.flags.len);
        if (std.fmt.parseInt(ngx_uint_t, slice, 10) catch null) |parsed| {
            return parsed;
        }
    }
    return 1;
}

fn shouldSkipRateLimit(r: [*c]ngx_http_request_t, lccf: *ratelimit_loc_conf) bool {
    if (resolveIndexedVariable(r, lccf.*.skip_var_index)) |value| {
        return parseBoolVariable(value);
    }
    return false;
}

fn ngx_http_ratelimit_result_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = core.castPtr(ratelimit_ctx, r.*.ctx[ngx_http_ratelimit_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    v.*.data = ctx.*.decision.data;
    v.*.flags.len = @intCast(ctx.*.decision.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn ngx_http_ratelimit_key_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = core.castPtr(ratelimit_ctx, r.*.ctx[ngx_http_ratelimit_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    if (ctx.*.key.len == 0 or ctx.*.key.data == null) {
        v.*.flags.not_found = true;
        return NGX_OK;
    }
    v.*.data = ctx.*.key.data;
    v.*.flags.len = @intCast(ctx.*.key.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn ngx_http_ratelimit_source_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = core.castPtr(ratelimit_ctx, r.*.ctx[ngx_http_ratelimit_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    v.*.data = ctx.*.source.data;
    v.*.flags.len = @intCast(ctx.*.source.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn ngx_http_ratelimit_cost_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = core.castPtr(ratelimit_ctx, r.*.ctx[ngx_http_ratelimit_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    var buf: [32]u8 = undefined;
    const cost_slice = std.fmt.bufPrint(&buf, "{d}", .{ctx.*.cost}) catch {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    const copied = ngx.string.ngx_string_from_pool(@constCast(cost_slice.ptr), cost_slice.len, r.*.pool) catch {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    v.*.data = copied.data;
    v.*.flags.len = @intCast(copied.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

const RATELIMIT_METRIC_ENTRIES: core.uintptr_t = 0;
const RATELIMIT_METRIC_CAPACITY_REJECTED: core.uintptr_t = 1;
const RATELIMIT_METRIC_RECLAIMED: core.uintptr_t = 2;

fn ngx_http_ratelimit_metric_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    var value: u64 = 0;
    if (getRateLimitShpool()) |shpool| {
        shm.ngx_shmtx_lock(&shpool.*.mutex);
        if (getRateLimitStore()) |store| {
            value = switch (data) {
                RATELIMIT_METRIC_ENTRIES => @intCast(store.*.entry_count),
                RATELIMIT_METRIC_CAPACITY_REJECTED => store.*.capacity_rejected,
                RATELIMIT_METRIC_RECLAIMED => store.*.reclaimed_entries,
                else => 0,
            };
        }
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
    }

    var value_buf: [24]u8 = undefined;
    const slice = std.fmt.bufPrint(&value_buf, "{d}", .{value}) catch {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    const copied = ngx.string.ngx_string_from_pool(@constCast(slice.ptr), slice.len, r.*.pool) catch {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    v.*.data = copied.data;
    v.*.flags.len = @intCast(copied.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn normalizeVariableName(raw: []const u8) []const u8 {
    if (raw.len > 0 and raw[0] == '$') return raw[1..];
    return raw;
}

fn resolveConfigVariableIndex(cf: [*c]ngx_conf_t, raw_name: ngx_str_t) ngx_int_t {
    const raw_slice = core.slicify(u8, raw_name.data, raw_name.len);
    const normalized = normalizeVariableName(raw_slice);
    if (normalized.len == 0) return -1;
    var name = ngx_string(normalized);
    return http.ngx_http_get_variable_index(cf, &name);
}

fn ngx_conf_set_ratelimit_key(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const idx = resolveConfigVariableIndex(cf, arg.*);
        if (idx == conf.NGX_CONF_ERROR) return conf.NGX_CONF_ERROR;
        lccf.*.key_var = arg.*;
        lccf.*.key_var_index = idx;
        return conf.NGX_CONF_OK;
    }
    return conf.NGX_CONF_ERROR;
}

fn ngx_conf_set_ratelimit_cost(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const idx = resolveConfigVariableIndex(cf, arg.*);
        if (idx == conf.NGX_CONF_ERROR) return conf.NGX_CONF_ERROR;
        lccf.*.cost_var = arg.*;
        lccf.*.cost_var_index = idx;
        return conf.NGX_CONF_OK;
    }
    return conf.NGX_CONF_ERROR;
}

fn ngx_conf_set_ratelimit_skip(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lccf = core.castPtr(ratelimit_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const idx = resolveConfigVariableIndex(cf, arg.*);
        if (idx == conf.NGX_CONF_ERROR) return conf.NGX_CONF_ERROR;
        lccf.*.skip_var = arg.*;
        lccf.*.skip_var_index = idx;
        return conf.NGX_CONF_OK;
    }
    return conf.NGX_CONF_ERROR;
}

// Access phase handler
fn ngx_http_ratelimit_access_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        ratelimit_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_ratelimit_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) {
        return NGX_DECLINED;
    }

    const resolved = getRateLimitKey(r, lccf);
    const bucket_hash = buildBucketHash(lccf, resolved.hash);
    const cost = getRequestCost(r, lccf);

    if (shouldSkipRateLimit(r, lccf)) {
        setCtx(r, decision_allow, resolved.key, resolved.source, cost);
        return NGX_DECLINED;
    }

    const shpool = getRateLimitShpool() orelse return NGX_DECLINED;
    const store = getRateLimitStore() orelse return NGX_DECLINED;
    shm.ngx_shmtx_lock(&shpool.*.mutex);
    const allowed = checkRateLimit(store, bucket_hash, lccf.*.rate, lccf.*.burst, cost);
    shm.ngx_shmtx_unlock(&shpool.*.mutex);

    if (allowed) {
        setCtx(r, decision_allow, resolved.key, resolved.source, cost);
        return NGX_DECLINED; // Request allowed
    }

    // Rate limit exceeded - return 429 Too Many Requests
    setCtx(r, decision_deny, resolved.key, resolved.source, cost);
    return 429;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(ratelimit_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = conf.NGX_CONF_UNSET;
        p.*.rate = 10; // default 10 requests per second
        p.*.rate_set = conf.NGX_CONF_UNSET;
        p.*.burst = 0; // no burst by default
        p.*.burst_set = conf.NGX_CONF_UNSET;
        p.*.key_var_index = -1;
        p.*.cost_var_index = -1;
        p.*.skip_var_index = -1;
        p.*.bucket_scope = ngx_str_t{ .len = 0, .data = null };
        return p;
    }
    return null;
}

fn merge_loc_conf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    const prev = core.castPtr(ratelimit_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(ratelimit_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.enabled == conf.NGX_CONF_UNSET) {
        c.*.enabled = if (prev.*.enabled == conf.NGX_CONF_UNSET) 0 else prev.*.enabled;
    }

    if (c.*.rate_set == conf.NGX_CONF_UNSET) {
        if (prev.*.rate_set != conf.NGX_CONF_UNSET) {
            c.*.rate = prev.*.rate;
            c.*.rate_set = prev.*.rate_set;
        } else {
            c.*.rate = 10;
            c.*.rate_set = 0;
        }
    }

    if (c.*.burst_set == conf.NGX_CONF_UNSET) {
        if (prev.*.burst_set != conf.NGX_CONF_UNSET) {
            c.*.burst = prev.*.burst;
            c.*.burst_set = prev.*.burst_set;
        } else {
            c.*.burst = 0;
            c.*.burst_set = 0;
        }
    }

    if (c.*.key_var.data == null and prev.*.key_var.data != null) {
        c.*.key_var = prev.*.key_var;
        c.*.key_var_index = prev.*.key_var_index;
    }
    if (c.*.cost_var.data == null and prev.*.cost_var.data != null) {
        c.*.cost_var = prev.*.cost_var;
        c.*.cost_var_index = prev.*.cost_var_index;
    }
    if (c.*.skip_var.data == null and prev.*.skip_var.data != null) {
        c.*.skip_var = prev.*.skip_var;
        c.*.skip_var_index = prev.*.skip_var_index;
    }

    if (c.*.bucket_scope.len == 0 and prev.*.bucket_scope.len > 0) {
        c.*.bucket_scope = prev.*.bucket_scope;
    }

    if (c.*.enabled == 1 and c.*.bucket_scope.len == 0) {
        return initBucketScope(cf, c);
    }

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_ratelimit_rate(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(ratelimit_loc_conf, loc)) |lccf| {
        lccf.*.enabled = 1;
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const slice = core.slicify(u8, arg.*.data, arg.*.len);
            lccf.*.rate = parseRateValue(slice) orelse return conf.NGX_CONF_ERROR;
            lccf.*.rate_set = 1;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_ratelimit_burst(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(ratelimit_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const slice = core.slicify(u8, arg.*.data, arg.*.len);
            lccf.*.burst = std.fmt.parseInt(ngx_uint_t, slice, 10) catch return conf.NGX_CONF_ERROR;
            lccf.*.burst_set = 1;
        }
    }
    return conf.NGX_CONF_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    var zone_name = ngx_string("ratelimit_zone");
    const zone = shm.ngx_shared_memory_add(cf, &zone_name, RATELIMIT_ZONE_SIZE, @constCast(&ngx_http_ratelimit_module));
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return NGX_ERROR;
    zone.*.init = ngx_http_ratelimit_zone_init;
    ngx_http_ratelimit_zone = zone;

    var vs = [_]http.ngx_http_variable_t{
        http.ngx_http_variable_t{ .name = ngx_string("ratelimit_result"), .set_handler = null, .get_handler = ngx_http_ratelimit_result_variable, .data = 0, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("ratelimit_key"), .set_handler = null, .get_handler = ngx_http_ratelimit_key_variable, .data = 0, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("ratelimit_source"), .set_handler = null, .get_handler = ngx_http_ratelimit_source_variable, .data = 0, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("ratelimit_cost"), .set_handler = null, .get_handler = ngx_http_ratelimit_cost_variable, .data = 0, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("ratelimit_entries"), .set_handler = null, .get_handler = ngx_http_ratelimit_metric_variable, .data = RATELIMIT_METRIC_ENTRIES, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("ratelimit_capacity_rejected"), .set_handler = null, .get_handler = ngx_http_ratelimit_metric_variable, .data = RATELIMIT_METRIC_CAPACITY_REJECTED, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("ratelimit_reclaimed"), .set_handler = null, .get_handler = ngx_http_ratelimit_metric_variable, .data = RATELIMIT_METRIC_RECLAIMED, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
    };
    for (&vs) |*v| {
        if (http.ngx_http_add_variable(cf, &v.name, v.flags)) |x| {
            x.*.get_handler = v.get_handler;
            x.*.data = v.data;
        }
    }

    // Register access phase handler so earlier ACCESS modules can publish variables first.
    const cmcf = core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    var handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_ACCESS_PHASE].handlers,
    );
    const h = handlers.append() catch return NGX_ERROR;
    h.* = ngx_http_ratelimit_access_handler;

    return NGX_OK;
}

export const ngx_http_ratelimit_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_ratelimit_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("ratelimit_rate"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_ratelimit_rate,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("ratelimit_burst"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_ratelimit_burst,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("ratelimit_key"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_ratelimit_key,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("ratelimit_cost"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_ratelimit_cost,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("ratelimit_skip"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_ratelimit_skip,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_ratelimit_module = ngx.module.make_module(
    @constCast(&ngx_http_ratelimit_commands),
    @constCast(&ngx_http_ratelimit_module_ctx),
);

// Tests
const expectEqual = std.testing.expectEqual;

test "ratelimit module" {
}

test "full live table rejects a new key without evicting enforcement state" {
    var store: ratelimit_store = std.mem.zeroes(ratelimit_store);
    const now: i64 = 100;
    for (&store.entries, 0..) |*entry, i| {
        entry.* = .{ .key_hash = i + 1, .count = 1, .window_start = now, .last_used = now };
    }
    store.entry_count = MAX_ENTRIES;
    const first_before = store.entries[0];
    try std.testing.expect(getOrCreateEntry(&store, MAX_ENTRIES + 10, now) == null);
    try std.testing.expectEqualDeep(first_before, store.entries[0]);
    try expectEqual(@as(u64, 1), store.capacity_rejected);
}
