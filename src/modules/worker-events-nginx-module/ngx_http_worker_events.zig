const std = @import("std");
const ngx = @import("ngx");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const buf = ngx.buf;
const shm = ngx.shm;
const string = ngx.string;
const cjson = ngx.cjson;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;

const ngx_str_t = core.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_buf_t = buf.ngx_buf_t;
const ngx_chain_t = buf.ngx_chain_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;

const ngx_string = string.ngx_string;
const ngx_null_str = string.ngx_null_str;
const CJSON = cjson.CJSON;

extern var ngx_http_core_module: ngx_module_t;

// ── Constants ────────────────────────────────────────────────────────────────

const DEFAULT_RING_SIZE: ngx_uint_t = 1024;
const MAX_CHANNEL_LEN: usize = 64;
const MAX_TYPE_LEN: usize = 64;
const MAX_PAYLOAD_LEN: usize = 512;

const MAX_WORKER_EVENT_ZONES: usize = 16;
const WorkerEventsZoneBinding = struct {
    name: ngx_str_t,
    zone: [*c]core.ngx_shm_zone_t,
};
var worker_events_zone_count: usize = 0;
var worker_events_zones: [MAX_WORKER_EVENT_ZONES]WorkerEventsZoneBinding = undefined;

// ── Shared-memory data structures (C ABI) ────────────────────────────────────

const WorkerEventsStore = extern struct {
    initialized: ngx_flag_t,
    capacity: ngx_uint_t,
    payload_max: ngx_uint_t,

    next_generation: u64,
    write_index: ngx_uint_t,
    retained_count: ngx_uint_t,

    oldest_generation: u64,
    newest_generation: u64,
    dropped_events: u64,

    last_publish_msec: i64,
};

const WorkerEventEntry = extern struct {
    generation: u64,
    channel_len: u16,
    type_len: u16,
    payload_len: u32,
    created_at_msec: i64,

    channel: [MAX_CHANNEL_LEN]u8,
    event_type: [MAX_TYPE_LEN]u8,
    payload: [MAX_PAYLOAD_LEN]u8,
};

// ── Location config ──────────────────────────────────────────────────────────

const worker_events_loc_conf = extern struct {
    api_enabled: ngx_flag_t,
    zone_name: ngx_str_t,
    default_channel: ngx_str_t,
    ring_size: ngx_uint_t,
    publish_key: ngx_str_t,
    zone: [*c]core.ngx_shm_zone_t,
};

// ── Shared-memory helpers ────────────────────────────────────────────────────

fn get_store(zone: [*c]core.ngx_shm_zone_t) ?[*c]WorkerEventsStore {
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return null;
    return core.castPtr(WorkerEventsStore, zone.*.data);
}

fn get_shpool(zone: [*c]core.ngx_shm_zone_t) ?[*c]core.ngx_slab_pool_t {
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.shm.addr == null or zone.*.data == null) {
        return null;
    }
    return core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr);
}

fn get_entries(store: [*c]WorkerEventsStore) [*c]WorkerEventEntry {
    // Entries follow the store in the end-of-zone area.
    const store_size = @sizeOf(WorkerEventsStore);
    const base = @as([*]u8, @ptrCast(@alignCast(store)));
    return @as([*c]WorkerEventEntry, @ptrCast(@alignCast(base + store_size)));
}

fn get_current_time_msec() i64 {
    const tp = core.ngx_timeofday();
    if (tp) |t| {
        return @as(i64, @intCast(t.*.sec)) * 1000 + @as(i64, @intCast(t.*.msec));
    }
    return 0;
}

const PublishWriteResult = struct {
    generation: u64,
    created_at_msec: i64,
    retention_evicted: bool,
};

fn valid_publish_str(value: ngx_str_t, max_len: usize, allow_empty: bool) bool {
    if (value.data == null) return allow_empty and value.len == 0;
    if (value.len == 0) return allow_empty;
    return value.len <= max_len;
}

fn publish_to_ring(
    zone: [*c]core.ngx_shm_zone_t,
    channel_str: ngx_str_t,
    type_str: ngx_str_t,
    payload_str: ngx_str_t,
) ?PublishWriteResult {
    if (!valid_publish_str(channel_str, MAX_CHANNEL_LEN, false)) return null;
    if (!valid_publish_str(type_str, MAX_TYPE_LEN, false)) return null;
    if (!valid_publish_str(payload_str, MAX_PAYLOAD_LEN, true)) return null;

    const store = get_store(zone) orelse return null;
    const shpool = get_shpool(zone) orelse return null;

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.*.mutex);

    const entries = get_entries(store);
    const generation = store.*.next_generation;
    const write_idx = store.*.write_index;
    const capacity = store.*.capacity;

    const retention_evicted = store.*.retained_count == capacity;
    if (retention_evicted) {
        store.*.dropped_events += 1;
        if (store.*.oldest_generation == 0) {
            store.*.oldest_generation = entries[write_idx].generation;
        }
        store.*.oldest_generation = entries[write_idx].generation + 1;
    }

    const entry = &entries[write_idx];
    entry.*.generation = generation;
    entry.*.created_at_msec = get_current_time_msec();

    entry.*.channel_len = @intCast(@min(channel_str.len, MAX_CHANNEL_LEN));
    @memset(&entry.*.channel, 0);
    _ = str_copy(&entry.*.channel, channel_str);

    entry.*.type_len = @intCast(@min(type_str.len, MAX_TYPE_LEN));
    @memset(&entry.*.event_type, 0);
    _ = str_copy(&entry.*.event_type, type_str);

    entry.*.payload_len = @intCast(@min(payload_str.len, MAX_PAYLOAD_LEN));
    @memset(&entry.*.payload, 0);
    _ = str_copy(&entry.*.payload, payload_str);

    store.*.write_index = (write_idx + 1) % capacity;
    store.*.next_generation = generation + 1;
    store.*.newest_generation = generation;
    store.*.last_publish_msec = entry.*.created_at_msec;
    if (store.*.retained_count < capacity) {
        store.*.retained_count += 1;
    }
    if (store.*.oldest_generation == 0) {
        store.*.oldest_generation = generation;
    }

    return .{
        .generation = generation,
        .created_at_msec = entry.*.created_at_msec,
        .retention_evicted = retention_evicted,
    };
}

export fn ngx_http_worker_events_publish_internal(
    zone: [*c]core.ngx_shm_zone_t,
    channel_str: ngx_str_t,
    type_str: ngx_str_t,
    payload_str: ngx_str_t,
) callconv(.c) ngx_int_t {
    const result = publish_to_ring(zone, channel_str, type_str, payload_str) orelse return NGX_ERROR;
    // NGX_DECLINED is an acknowledged write with an overwrite of the oldest
    // retained event; callers must not treat it as a failed publication.
    return if (result.retention_evicted) NGX_DECLINED else NGX_OK;
}

/// Backward-compatible native publisher path.  It is intentionally available
/// only when the current configuration cycle contains exactly one event zone;
/// ambiguous multi-zone configurations fail instead of cross-routing events.
export fn ngx_http_worker_events_publish_default(
    channel_str: ngx_str_t,
    type_str: ngx_str_t,
    payload_str: ngx_str_t,
) callconv(.c) ngx_int_t {
    if (worker_events_zone_count != 1) return NGX_ERROR;
    return ngx_http_worker_events_publish_internal(worker_events_zones[0].zone, channel_str, type_str, payload_str);
}

/// Publish to an explicitly named zone in the current configuration cycle.
/// Native consumers must use this in multi-zone deployments.
export fn ngx_http_worker_events_publish_named(
    zone_name: ngx_str_t,
    channel_str: ngx_str_t,
    type_str: ngx_str_t,
    payload_str: ngx_str_t,
) callconv(.c) ngx_int_t {
    for (worker_events_zones[0..worker_events_zone_count]) |binding| {
        if (string.eql(binding.name, zone_name)) {
            return ngx_http_worker_events_publish_internal(binding.zone, channel_str, type_str, payload_str);
        }
    }
    return NGX_ERROR;
}

// ── Zone init callback ───────────────────────────────────────────────────────

fn zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        zone.*.data = data;
        return NGX_OK;
    }

    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        zone.*.data = shpool.*.data;
        return NGX_OK;
    }

    // Layout: [slab_pool][...free slab area (≥ 2 pages)...][store][entries...]
    // Store and entries sit at end of zone, outside slab management.
    // The slab pool remains available for nginx internals (mutex, etc.)
    // but we never allocate from it.
    const zone_size = zone.*.shm.size;
    const store_size = @sizeOf(WorkerEventsStore);
    const entry_size = @sizeOf(WorkerEventEntry);
    const min_slab_area: usize = 8192; // 2 pages for slab internals

    if (zone_size < @sizeOf(core.ngx_slab_pool_t) + min_slab_area + store_size + entry_size) {
        return NGX_ERROR;
    }

    const available = zone_size - @sizeOf(core.ngx_slab_pool_t) - min_slab_area;
    const capacity: ngx_uint_t = @intCast((available - store_size) / entry_size);
    if (capacity == 0) {
        return NGX_ERROR;
    }

    // Place store + entries at end of zone
    const base = @as([*]u8, @ptrCast(@alignCast(shpool)));
    const total_data = store_size + capacity * entry_size;
    const data_start = base + zone_size - total_data;
    const store = @as([*c]WorkerEventsStore, @ptrCast(@alignCast(data_start)));

    store.*.initialized = 1;
    store.*.capacity = capacity;
    store.*.payload_max = MAX_PAYLOAD_LEN;
    store.*.next_generation = 1;
    store.*.write_index = 0;
    store.*.retained_count = 0;
    store.*.oldest_generation = 0;
    store.*.newest_generation = 0;
    store.*.dropped_events = 0;

    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

// ── Location config lifecycle ────────────────────────────────────────────────

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(worker_events_loc_conf, cf.*.pool)) |p| {
        p.*.api_enabled = conf.NGX_CONF_UNSET;
        p.*.zone_name = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
        p.*.default_channel = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
        p.*.ring_size = 0;
        p.*.publish_key = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
        p.*.zone = core.nullptr(core.ngx_shm_zone_t);
        return p;
    }
    return null;
}

fn merge_loc_conf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    const prev = core.castPtr(worker_events_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(worker_events_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.api_enabled == conf.NGX_CONF_UNSET) {
        c.*.api_enabled = if (prev.*.api_enabled == conf.NGX_CONF_UNSET) 0 else prev.*.api_enabled;
    }
    if (c.*.zone_name.len == 0) c.*.zone_name = prev.*.zone_name;
    if (c.*.default_channel.len == 0) c.*.default_channel = prev.*.default_channel;
    if (c.*.ring_size == 0) c.*.ring_size = prev.*.ring_size;
    if (c.*.publish_key.len == 0) c.*.publish_key = prev.*.publish_key;
    if (c.*.zone == core.nullptr(core.ngx_shm_zone_t)) c.*.zone = prev.*.zone;

    if (c.*.api_enabled == 1) {
        if (c.*.zone_name.len == 0) {
            return @constCast("worker_events_api requires worker_events_zone");
        }
        if (c.*.default_channel.len == 0) {
            return @constCast("worker_events_api requires worker_events_channel");
        }
        if (c.*.zone == core.nullptr(core.ngx_shm_zone_t)) {
            c.*.zone = create_shared_zone(cf, c);
            if (c.*.zone == core.nullptr(core.ngx_shm_zone_t)) {
                return conf.NGX_CONF_ERROR;
            }
        }
    }

    return conf.NGX_CONF_OK;
}

// ── JSON helpers ─────────────────────────────────────────────────────────────

fn json_escape_len(src: []const u8) usize {
    var len: usize = 0;
    for (src) |c| {
        switch (c) {
            '"', '\\' => len += 2,
            '\n' => len += 2,
            '\r' => len += 2,
            '\t' => len += 2,
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => len += 6,
            else => len += 1,
        }
    }
    return len;
}

fn json_escape_into(dst: []u8, src: []const u8) usize {
    var pos: usize = 0;
    for (src) |c| {
        switch (c) {
            '"' => {
                dst[pos] = '\\';
                dst[pos + 1] = '"';
                pos += 2;
            },
            '\\' => {
                dst[pos] = '\\';
                dst[pos + 1] = '\\';
                pos += 2;
            },
            '\n' => {
                dst[pos] = '\\';
                dst[pos + 1] = 'n';
                pos += 2;
            },
            '\r' => {
                dst[pos] = '\\';
                dst[pos + 1] = 'r';
                pos += 2;
            },
            '\t' => {
                dst[pos] = '\\';
                dst[pos + 1] = 't';
                pos += 2;
            },
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                const hex = "0123456789abcdef";
                dst[pos] = '\\';
                dst[pos + 1] = 'u';
                dst[pos + 2] = '0';
                dst[pos + 3] = '0';
                dst[pos + 4] = hex[(c >> 4) & 0xF];
                dst[pos + 5] = hex[c & 0xF];
                pos += 6;
            },
            else => {
                dst[pos] = c;
                pos += 1;
            },
        }
    }
    return pos;
}

fn write_u64_into(out: []u8, value: u64) usize {
    if (value == 0) {
        out[0] = '0';
        return 1;
    }
    var v = value;
    var pos: usize = 0;
    var tmp: [20]u8 = undefined;
    while (v > 0) {
        tmp[pos] = @as(u8, @intCast((v % 10) + '0'));
        pos += 1;
        v /= 10;
    }
    var i: usize = 0;
    while (i < pos) : (i += 1) {
        out[i] = tmp[pos - 1 - i];
    }
    return pos;
}

fn str_copy(dst: []u8, src: ngx_str_t) usize {
    const len = @min(dst.len, src.len);
    if (len > 0) {
        @memcpy(dst[0..len], src.data[0..len]);
    }
    return len;
}

fn append_json_escaped_ngx_str(p: *[*]u8, end: [*]u8, s: ngx_str_t) void {
    if (s.len == 0 or s.data == null) return;
    const slice = core.slicify(u8, s.data, s.len);
    const rem = @intFromPtr(end) - @intFromPtr(p.*);
    const escaped_len = json_escape_len(slice);
    if (escaped_len > rem) return;
    const actual = json_escape_into(p.*[0..rem], slice);
    p.* += actual;
}

fn append_json_escaped_slice(p: *[*]u8, end: [*]u8, s: []const u8) void {
    if (s.len == 0) return;
    const rem = @intFromPtr(end) - @intFromPtr(p.*);
    const escaped_len = json_escape_len(s);
    if (escaped_len > rem) return;
    const actual = json_escape_into(p.*[0..rem], s);
    p.* += actual;
}

// ── Response helpers ─────────────────────────────────────────────────────────

fn send_json_response(r: [*c]ngx_http_request_t, status: ngx_uint_t, body: ngx_str_t) ngx_int_t {
    const content_type = ngx_string("application/json");
    r.*.headers_out.status = status;
    r.*.headers_out.content_type = content_type;
    r.*.headers_out.content_type_len = content_type.len;
    r.*.headers_out.content_length_n = @intCast(body.len);

    const header_rc = http.ngx_http_send_header(r);
    if (header_rc == NGX_ERROR or header_rc > NGX_OK) {
        return header_rc;
    }
    if (r.*.method == http.NGX_HTTP_HEAD or r.*.flags1.header_only) {
        return NGX_OK;
    }

    const out_buf = core.ngz_pcalloc_c(ngx_buf_t, r.*.pool) orelse return NGX_ERROR;
    out_buf.*.pos = body.data;
    out_buf.*.last = body.data + body.len;
    out_buf.*.flags.memory = true;
    out_buf.*.flags.last_buf = (r == r.*.main);
    out_buf.*.flags.last_in_chain = true;

    const chain = core.ngz_pcalloc_c(ngx_chain_t, r.*.pool) orelse return NGX_ERROR;
    chain.*.buf = out_buf;
    chain.*.next = core.nullptr(ngx_chain_t);

    return http.ngx_http_output_filter(r, chain);
}

fn request_content_type(r: [*c]ngx_http_request_t) ?[]const u8 {
    if (r.*.headers_in.content_type == null) return null;
    const value = r.*.headers_in.content_type.*.value;
    if (value.len == 0 or value.data == null) return null;
    return core.slicify(u8, value.data, value.len);
}

fn is_json_content_type(r: [*c]ngx_http_request_t) bool {
    const raw = request_content_type(r) orelse return false;
    const media_end = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    const media_type = std.mem.trim(u8, raw[0..media_end], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/json");
}

// ── GET / HEAD - Inspect handler ─────────────────────────────────────────────

fn handle_inspect(r: [*c]ngx_http_request_t) ngx_int_t {
    const lccf = core.castPtr(
        worker_events_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_worker_events_module),
    ) orelse return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

    // Resolve filter parameters
    var channel_filter: ngx_str_t = lccf.*.default_channel;
    var type_filter: ngx_str_t = ngx_null_str;
    var since_generation: u64 = 0;
    var limit_count: ngx_uint_t = 0;

    // Parse query args for channel filter
    if (r.*.args.len > 0) {
        // Parse query params manually
        const args = core.slicify(u8, r.*.args.data, r.*.args.len);
        var pos: usize = 0;
        while (pos < args.len) {
            const key_start = pos;
            while (pos < args.len and args[pos] != '=' and args[pos] != '&') : (pos += 1) {}
            const key_end = pos;
            var value_start: usize = pos;
            var value_end: usize = pos;
            if (pos < args.len and args[pos] == '=') {
                pos += 1;
                value_start = pos;
                while (pos < args.len and args[pos] != '&') : (pos += 1) {}
                value_end = pos;
            }
            if (pos < args.len and args[pos] == '&') pos += 1;

            const key = args[key_start..key_end];
            const value = args[value_start..value_end];

            if (std.mem.eql(u8, key, "channel")) {
                // Set channel filter from query
                channel_filter.len = @intCast(value.len);
                channel_filter.data = @constCast(value.ptr);
            } else if (std.mem.eql(u8, key, "type")) {
                type_filter.len = @intCast(value.len);
                type_filter.data = @constCast(value.ptr);
            } else if (std.mem.eql(u8, key, "since")) {
                since_generation = std.fmt.parseInt(u64, value, 10) catch 0;
            } else if (std.mem.eql(u8, key, "limit")) {
                limit_count = std.fmt.parseInt(ngx_uint_t, value, 10) catch 0;
            }
        }
    }

    // Access shared memory
    const zone = lccf.*.zone;
    const store = get_store(zone) orelse {
        const body = ngx_string("{\"module\":\"worker_events\",\"zone\":\"\",\"channel\":\"\",\"capacity\":0,\"oldest_generation\":0,\"newest_generation\":0,\"dropped_events\":0,\"last_publish_msec\":0,\"events\":[]}");
        return send_json_response(r, http.NGX_HTTP_OK, body);
    };

    const shpool = get_shpool(zone) orelse {
        return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    };

    // Lock and snapshot
    shm.ngx_shmtx_lock(&shpool.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.*.mutex);

    const oldest_gen = store.*.oldest_generation;
    const newest_gen = store.*.newest_generation;
    const dropped = store.*.dropped_events;
    const retained = store.*.retained_count;
    const capacity = store.*.capacity;
    const entries = get_entries(store);

    // Collect matching events (local copy to avoid holding lock during JSON render)
    const max_matched: usize = if (limit_count > 0)
        @min(@as(usize, limit_count), @as(usize, retained))
    else
        @as(usize, retained);
    const matched_buf_opt: ?[*c]WorkerEventEntry = if (max_matched > 0)
        core.castPtr(WorkerEventEntry, core.ngx_pnalloc(r.*.pool, max_matched * @sizeOf(WorkerEventEntry)))
    else
        null;
    var matched_count: usize = 0;

    if (retained > 0) {
        // Entries are at indices [0, retained) in ring order
        // The ring starts at write_index (next insertion point) for oldest
        var i: ngx_uint_t = 0;
        while (i < retained and matched_count < max_matched) : (i += 1) {
            // Ring is circular: write_index points to next slot, so oldest is at write_index (if full)
            // or at 0 (if not yet wrapped)
            var idx: ngx_uint_t = undefined;
            if (retained == capacity) {
                // Ring is full, oldest is at write_index
                idx = (store.*.write_index + i) % capacity;
            } else {
                // Ring not full, oldest is at 0
                idx = i;
            }

            const entry = &entries[idx];

            // Apply channel filter
            if (channel_filter.len > 0) {
                if (entry.channel_len != channel_filter.len) {
                    continue;
                }
                const ch_str = ngx_str_t{ .data = @constCast(&entry.channel), .len = entry.channel_len };
                if (!string.eql(ch_str, channel_filter)) {
                    continue;
                }
            }

            if (type_filter.len > 0) {
                if (entry.type_len != type_filter.len) {
                    continue;
                }
                const ty_str = ngx_str_t{ .data = @constCast(&entry.event_type), .len = entry.type_len };
                if (!string.eql(ty_str, type_filter)) {
                    continue;
                }
            }

            // Apply since filter
            if (since_generation > 0 and entry.generation <= since_generation) {
                continue;
            }

            // Apply limit
            if (limit_count > 0 and matched_count >= limit_count) {
                break;
            }

            matched_buf_opt.?[matched_count] = entry.*;
            matched_count += 1;
        }
    }

    // Render JSON response (unlocked)
    // Estimate size: ~200 bytes overhead + matched_count * ~800 bytes
    const est_size: usize = 256 + matched_count * 900;
    const buf_mem_raw = core.ngx_pnalloc(r.*.pool, est_size) orelse return NGX_ERROR;
    const buf_mem: [*c]u8 = @ptrCast(@alignCast(buf_mem_raw));
    var w: [*]u8 = buf_mem;
    const w_end = w + est_size;

    // Helper to write a string safely
    const append = struct {
        fn f(p: *[*]u8, end: [*]u8, s: []const u8) void {
            const rem = @intFromPtr(end) - @intFromPtr(p.*);
            const n = @min(s.len, rem);
            @memcpy(p.*[0..n], s[0..n]);
            p.* += n;
        }
    }.f;

    append(&w, w_end, "{\"module\":\"worker_events\",");
    append(&w, w_end, "\"zone\":\"");
    append_json_escaped_ngx_str(&w, w_end, lccf.*.zone_name);
    append(&w, w_end, "\",");
    append(&w, w_end, "\"channel\":\"");
    append_json_escaped_ngx_str(&w, w_end, channel_filter);
    append(&w, w_end, "\",");
    append(&w, w_end, "\"capacity\":");
    {
        var nbuf: [20]u8 = undefined;
        const n = write_u64_into(&nbuf, capacity);
        append(&w, w_end, nbuf[0..n]);
    }
    append(&w, w_end, ",\"oldest_generation\":");
    {
        var nbuf: [20]u8 = undefined;
        const n = write_u64_into(&nbuf, oldest_gen);
        append(&w, w_end, nbuf[0..n]);
    }
    append(&w, w_end, ",\"newest_generation\":");
    {
        var nbuf: [20]u8 = undefined;
        const n = write_u64_into(&nbuf, newest_gen);
        append(&w, w_end, nbuf[0..n]);
    }
    append(&w, w_end, ",\"dropped_events\":");
    {
        var nbuf: [20]u8 = undefined;
        const n = write_u64_into(&nbuf, dropped);
        append(&w, w_end, nbuf[0..n]);
    }
    append(&w, w_end, ",\"last_publish_msec\":");
    {
        var nbuf: [20]u8 = undefined;
        const n = write_u64_into(&nbuf, @as(u64, @bitCast(store.*.last_publish_msec)));
        append(&w, w_end, nbuf[0..n]);
    }
    append(&w, w_end, ",\"events\":[");

    for (0..matched_count) |i| {
        if (i > 0) append(&w, w_end, ",");
        const entry = &matched_buf_opt.?[i];
        append(&w, w_end, "{\"generation\":");
        {
            var nbuf: [20]u8 = undefined;
            const n = write_u64_into(&nbuf, entry.generation);
            append(&w, w_end, nbuf[0..n]);
        }
        append(&w, w_end, ",\"type\":\"");
        {
            const ty_len = @min(entry.type_len, MAX_TYPE_LEN);
            const ty_ptr = @as([*]const u8, @ptrCast(&entry.event_type));
            const ty = ty_ptr[0..ty_len];
            append_json_escaped_slice(&w, w_end, ty);
        }
        append(&w, w_end, "\",\"payload\":\"");
        // JSON-escape the payload
        {
            const pl_len = @min(entry.payload_len, MAX_PAYLOAD_LEN);
            const pl_ptr = @as([*]const u8, @ptrCast(&entry.payload));
            const pl = pl_ptr[0..pl_len];
            const escaped_len = json_escape_len(pl);
            const rem = @intFromPtr(w_end) - @intFromPtr(w);
            if (escaped_len <= rem) {
                const actual = json_escape_into(w[0..rem], pl);
                w += actual;
            }
        }
        append(&w, w_end, "\"}");
    }

    append(&w, w_end, "]}");

    const body = ngx_str_t{
        .data = buf_mem,
        .len = @intCast(@intFromPtr(w) - @intFromPtr(buf_mem)),
    };
    return send_json_response(r, http.NGX_HTTP_OK, body);
}

// ── POST body handler (called after body is read) ───────────────────────────

fn publish_body_handler(r: [*c]ngx_http_request_t) callconv(.c) void {
    // Read request body
    const b0 = r.*.request_body == core.nullptr(http.ngx_http_request_body_t);
    const b1 = r.*.request_body.*.bufs == core.nullptr(ngx_chain_t);
    if (b0 or b1) {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST, ngx_string("{\"module\":\"worker_events\",\"status\":\"error\",\"error\":\"missing request body\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    const body_str = buf.ngz_chain_content(r.*.request_body.*.bufs, r.*.pool) catch {
        _ = send_json_response(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR, ngx_string("{\"module\":\"worker_events\",\"status\":\"error\",\"error\":\"failed to read body\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };

    // Parse JSON
    var cj = CJSON.init(r.*.pool);
    const json = cj.decode(body_str) catch {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST, ngx_string("{\"module\":\"worker_events\",\"status\":\"error\",\"error\":\"invalid JSON\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    };
    defer cj.free(json);

    // Extract "type" (required)
    const type_node = cjson.cJSON_GetObjectItem(json, "type");
    if (type_node == core.nullptr(cjson.cJSON) or cjson.cJSON_IsString(type_node) != 1) {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST, ngx_string("{\"module\":\"worker_events\",\"status\":\"error\",\"error\":\"missing or invalid 'type' field\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    const type_str = CJSON.stringValue(type_node) orelse ngx_null_str;
    if (type_str.len == 0 or type_str.len > MAX_TYPE_LEN) {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST, ngx_string("{\"module\":\"worker_events\",\"status\":\"error\",\"error\":\"'type' must be 1-64 characters\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    // Extract "payload" (optional, fallback to empty string)
    var payload_str: ngx_str_t = ngx_null_str;
    if (cjson.cJSON_GetObjectItem(json, "payload")) |pl| {
        if (cjson.cJSON_IsString(pl) == 1) {
            payload_str = CJSON.stringValue(pl) orelse ngx_null_str;
        }
    }
    if (payload_str.len > MAX_PAYLOAD_LEN) {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST, ngx_string("{\"module\":\"worker_events\",\"status\":\"error\",\"error\":\"payload too large\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    // Get location config for channel
    const lccf = core.castPtr(
        worker_events_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_worker_events_module),
    ) orelse {
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };

    const channel_str = lccf.*.default_channel;
    if (channel_str.len == 0 or channel_str.len > MAX_CHANNEL_LEN) {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST, ngx_string("{\"module\":\"worker_events\",\"status\":\"error\",\"error\":\"channel not configured\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    const zone = lccf.*.zone;
    const publish_result = publish_to_ring(zone, channel_str, type_str, payload_str) orelse {
        _ = send_json_response(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR, ngx_string("{\"module\":\"worker_events\",\"status\":\"error\",\"error\":\"shared zone not initialized\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };

    // Build success response
    // Estimate max size: ~150 bytes
    const resp_size: usize = 256;
    const resp_mem_raw = core.ngx_pnalloc(r.*.pool, resp_size) orelse {
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };
    const resp_mem: [*c]u8 = @ptrCast(@alignCast(resp_mem_raw));
    var w2: [*]u8 = resp_mem;

    const append2 = struct {
        fn f(p: *[*]u8, s: []const u8) void {
            @memcpy(p.*[0..s.len], s[0..s.len]);
            p.* += s.len;
        }
    }.f;

    append2(&w2, "{\"module\":\"worker_events\",\"status\":\"published\",\"zone\":\"");
    {
        const n = @min(lccf.*.zone_name.len, MAX_CHANNEL_LEN);
        if (n > 0) {
            @memcpy(w2[0..n], lccf.*.zone_name.data[0..n]);
            w2 += n;
        }
    }
    append2(&w2, "\",\"channel\":\"");
    {
        const n = @min(channel_str.len, MAX_CHANNEL_LEN);
        if (n > 0) {
            @memcpy(w2[0..n], channel_str.data[0..n]);
            w2 += n;
        }
    }
    append2(&w2, "\",\"generation\":");
    {
        var nbuf: [20]u8 = undefined;
        const n = write_u64_into(&nbuf, publish_result.generation);
        @memcpy(w2[0..n], nbuf[0..n]);
        w2 += n;
    }
    append2(&w2, ",\"retention_evicted\":");
    append2(&w2, if (publish_result.retention_evicted) "true" else "false");
    append2(&w2, "}");

    const resp_body = ngx_str_t{
        .data = resp_mem,
        .len = @intCast(@intFromPtr(w2) - @intFromPtr(resp_mem)),
    };
    _ = send_json_response(r, http.NGX_HTTP_OK, resp_body);
    http.ngx_http_finalize_request(r, NGX_OK);
}

// ── POST - Publish handler ───────────────────────────────────────────────────

fn handle_publish(r: [*c]ngx_http_request_t) ngx_int_t {
    // Validate config first (cheap checks before body read)
    const lccf = core.castPtr(
        worker_events_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_worker_events_module),
    ) orelse return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

    if (lccf.*.default_channel.len == 0) {
        return send_json_response(r, http.NGX_HTTP_BAD_REQUEST, ngx_string("{\"module\":\"worker_events\",\"status\":\"error\",\"error\":\"channel not configured\"}"));
    }

    if (lccf.*.zone == core.nullptr(core.ngx_shm_zone_t)) {
        return send_json_response(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR, ngx_string("{\"module\":\"worker_events\",\"status\":\"error\",\"error\":\"shared zone not configured\"}"));
    }

    if (!is_json_content_type(r)) {
        return send_json_response(r, 415, ngx_string("{\"module\":\"worker_events\",\"status\":\"error\",\"error\":\"content-type must be application/json\"}"));
    }

    // Check publish authorization
    if (lccf.*.publish_key.len > 0) {
        const authorized = check_publish_auth(r, lccf);
        if (!authorized) {
            return send_json_response(r, http.NGX_HTTP_UNAUTHORIZED, ngx_string("{\"module\":\"worker_events\",\"status\":\"error\",\"error\":\"unauthorized: invalid publish key\"}"));
        }
    }

    // Read request body asynchronously
    const rc = http.ngx_http_read_client_request_body(r, publish_body_handler);
    if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) {
        return rc;
    }
    return core.NGX_DONE;
}

fn check_publish_auth(r: [*c]ngx_http_request_t, lccf: [*c]worker_events_loc_conf) bool {
    // Check query param ?key=...
    if (r.*.args.len > 0) {
        const args = core.slicify(u8, r.*.args.data, r.*.args.len);
        var pos: usize = 0;
        while (pos < args.len) {
            const key_start = pos;
            while (pos < args.len and args[pos] != '=' and args[pos] != '&') : (pos += 1) {}
            const key_end = pos;
            var value_start: usize = pos;
            var value_end: usize = pos;
            if (pos < args.len and args[pos] == '=') {
                pos += 1;
                value_start = pos;
                while (pos < args.len and args[pos] != '&') : (pos += 1) {}
                value_end = pos;
            }
            if (pos < args.len and args[pos] == '&') pos += 1;

            const key = args[key_start..key_end];
            if (std.mem.eql(u8, key, "key")) {
                const value = args[value_start..value_end];
                if (value.len == lccf.*.publish_key.len and std.mem.eql(u8, value, core.slicify(u8, lccf.*.publish_key.data, lccf.*.publish_key.len))) {
                    return true;
                }
            }
        }
    }

    return false;
}

// ── Main handler ─────────────────────────────────────────────────────────────

export fn ngx_http_worker_events_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    if (r.*.method == http.NGX_HTTP_GET or r.*.method == http.NGX_HTTP_HEAD) {
        return handle_inspect(r);
    }
    if (r.*.method == http.NGX_HTTP_POST) {
        return handle_publish(r);
    }
    return send_json_response(r, http.NGX_HTTP_NOT_ALLOWED, ngx_string("{\"module\":\"worker_events\",\"status\":\"error\",\"error\":\"method not allowed\"}"));
}

// ── Directive handlers ───────────────────────────────────────────────────────

fn ngx_conf_set_worker_events_api(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(worker_events_loc_conf, loc)) |lccf| {
        lccf.*.api_enabled = 1;

        const clcf = core.castPtr(
            http.ngx_http_core_loc_conf_t,
            conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
        ) orelse return conf.NGX_CONF_OK;
        clcf.*.handler = ngx_http_worker_events_handler;
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_worker_events_zone(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(worker_events_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            lccf.*.zone_name = arg.*;

            // If ring_size is already set, create zone now.
            // Otherwise, zone creation is deferred to ring_size handler.
            if (lccf.*.ring_size > 0 and lccf.*.zone_name.len > 0 and lccf.*.zone == core.nullptr(core.ngx_shm_zone_t)) {
                lccf.*.zone = create_shared_zone(cf, lccf);
            }
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_worker_events_channel(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(worker_events_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            lccf.*.default_channel = arg.*;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_worker_events_ring_size(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(worker_events_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const slice = core.slicify(u8, arg.*.data, arg.*.len);
            const parsed = std.fmt.parseInt(ngx_uint_t, slice, 10) catch {
                return @constCast("worker_events_ring_size must be a positive integer");
            };
            if (parsed == 0) {
                return @constCast("worker_events_ring_size must be a positive integer");
            }
            lccf.*.ring_size = parsed;

            // If zone_name was already set before ring_size, create zone now.
            if (lccf.*.ring_size > 0 and lccf.*.zone_name.len > 0 and lccf.*.zone == core.nullptr(core.ngx_shm_zone_t)) {
                lccf.*.zone = create_shared_zone(cf, lccf);
                if (lccf.*.zone == core.nullptr(core.ngx_shm_zone_t)) {
                    return conf.NGX_CONF_ERROR;
                }
            }
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_worker_events_publish_key(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(worker_events_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            lccf.*.publish_key = arg.*;
        }
    }
    return conf.NGX_CONF_OK;
}

fn create_shared_zone(cf: [*c]ngx_conf_t, lccf: [*c]worker_events_loc_conf) [*c]core.ngx_shm_zone_t {
    var rs = lccf.*.ring_size;
    if (rs == 0) {
        rs = DEFAULT_RING_SIZE;
    }

    const entry_size = @sizeOf(WorkerEventEntry);
    const store_size = @sizeOf(WorkerEventsStore);
    // Zone layout: [slab_pool][...free slab area (2 pages)...][store][entries...]
    const min_slab_area: usize = 8192;
    const data_size = store_size + rs * entry_size;
    const zone_size = @sizeOf(core.ngx_slab_pool_t) + min_slab_area + data_size;

    if (lccf.*.zone_name.len > 0) {
        const name_ptr: [*c]ngx_str_t = @constCast(&lccf.*.zone_name);
        const zone = shm.ngx_shared_memory_add(cf, name_ptr, zone_size, @constCast(&ngx_http_worker_events_module));
        if (zone != core.nullptr(core.ngx_shm_zone_t)) {
            zone.*.init = zone_init;
            var already_registered = false;
            for (worker_events_zones[0..worker_events_zone_count]) |binding| {
                if (string.eql(binding.name, lccf.*.zone_name)) {
                    already_registered = true;
                    break;
                }
            }
            if (!already_registered) {
                if (worker_events_zone_count >= MAX_WORKER_EVENT_ZONES) return core.nullptr(core.ngx_shm_zone_t);
                worker_events_zones[worker_events_zone_count] = .{ .name = lccf.*.zone_name, .zone = zone };
                worker_events_zone_count += 1;
            }
            return zone;
        }
    }
    return core.nullptr(core.ngx_shm_zone_t);
}

fn preconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    _ = cf;
    // The master parses each reload in the same process.  Never retain a zone
    // descriptor from the prior cycle in the new cycle's native registry.
    worker_events_zone_count = 0;
    return NGX_OK;
}

// ── Postconfiguration ────────────────────────────────────────────────────────

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    _ = cf;
    // Validate zone consistency if api is enabled
    // (More validation can be added here in later phases)
    return NGX_OK;
}

// ── Module exports ───────────────────────────────────────────────────────────

export const ngx_http_worker_events_module_ctx = ngx_http_module_t{
    .preconfiguration = preconfiguration,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_worker_events_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("worker_events_api"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_worker_events_api,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("worker_events_zone"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_worker_events_zone,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("worker_events_channel"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_worker_events_channel,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("worker_events_ring_size"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_worker_events_ring_size,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("worker_events_publish_key"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_worker_events_publish_key,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_worker_events_module = ngx.module.make_module(
    @constCast(&ngx_http_worker_events_commands),
    @constCast(&ngx_http_worker_events_module_ctx),
);

test "native default publisher rejects zero or ambiguous zones" {
    const saved = worker_events_zone_count;
    defer worker_events_zone_count = saved;

    worker_events_zone_count = 0;
    try std.testing.expectEqual(NGX_ERROR, ngx_http_worker_events_publish_default(ngx_string("c"), ngx_string("t"), ngx_null_str));

    worker_events_zone_count = 2;
    try std.testing.expectEqual(NGX_ERROR, ngx_http_worker_events_publish_default(ngx_string("c"), ngx_string("t"), ngx_null_str));
}

test "preconfiguration clears the prior cycle registry" {
    worker_events_zone_count = 3;
    try std.testing.expectEqual(NGX_OK, preconfiguration(core.nullptr(ngx_conf_t)));
    try std.testing.expectEqual(@as(usize, 0), worker_events_zone_count);
}

test "worker events scaffold module" {}
