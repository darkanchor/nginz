const std = @import("std");
const ngx = @import("ngx");

const conf = ngx.conf;
const core = ngx.core;
const http = ngx.http;
const shm = ngx.shm;
const buf = ngx.buf;
const event = ngx.event;
const file = ngx.file;

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
const ngx_http_upstream_srv_conf_t = http.ngx_http_upstream_srv_conf_t;
const ngx_http_upstream_main_conf_t = http.ngx_http_upstream_main_conf_t;
const ngx_http_upstream_rr_peers_t = http.ngx_http_upstream_rr_peers_t;
const ngx_http_upstream_rr_peer_t = http.ngx_http_upstream_rr_peer_t;
const ngx_url_t = core.ngx_url_t;
const ngx_msec_t = core.ngx_msec_t;

const ngx_string = ngx.string.ngx_string;
const ngx_null_str = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
const CJSON = ngx.cjson.CJSON;
const cjson = ngx.cjson;

extern var ngx_http_core_module: ngx_module_t;
extern var ngx_http_upstream_module: ngx_module_t;
extern var ngx_http_worker_events_default_zone: [*c]core.ngx_shm_zone_t;
extern var ngx_worker: ngx_uint_t;

extern fn upstream_balancer_ensure_hook(
    us: [*c]ngx_http_upstream_srv_conf_t,
) callconv(.c) ngx_int_t;

const PeerSourceVTable = extern struct {
    get_active_peers: ?*anyopaque,
    release_generation: ?*anyopaque,
};

extern fn upstream_balancer_register_peer_source(
    us: [*c]ngx_http_upstream_srv_conf_t,
    source_ctx: ?*anyopaque,
    vtable: ?*const PeerSourceVTable,
) callconv(.c) ngx_int_t;

extern fn ngx_http_worker_events_publish_internal(
    zone: [*c]core.ngx_shm_zone_t,
    channel_str: ngx_str_t,
    type_str: ngx_str_t,
    payload_str: ngx_str_t,
) callconv(.c) ngx_int_t;
extern fn ngz_healthcheck_is_peer_eligible(
    addr_data: [*c]u8,
    addr_len: usize,
) callconv(.c) c_int;

const DU_ZONE_SIZE: usize = 4 * 1024 * 1024;
const DU_ERROR_INVALID_CONTENT_TYPE: u32 = 415;
const DU_ERROR_INVALID_JSON: u32 = 4001;
const DU_ERROR_INVALID_PAYLOAD: u32 = 4002;
const DU_ERROR_INVALID_PEER: u32 = 4003;
const DU_ERROR_ALLOCATION_FAILED: u32 = 5001;
const DU_ERROR_SOURCE_READ_FAILED: u32 = 5002;
const DU_ERROR_REFRESH_NOT_CONFIGURED: u32 = 4004;
const DU_ERROR_ALL_PEERS_UNHEALTHY: u32 = 5031;
const MAX_REFRESH_ENTRIES: usize = 32;

// ── C socket API for consul polling ──────────────────────────────────────────

const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;
const IPPROTO_TCP: c_int = 6;
const SOL_SOCKET: c_int = 1;
const SO_RCVTIMEO: c_int = 20;
const SO_SNDTIMEO: c_int = 21;
const CONSUL_RECV_BUF_SIZE: usize = 256 * 1024;

const linux_timeval = extern struct {
    tv_sec: c_long,
    tv_usec: c_long,
};

const sockaddr_in = extern struct {
    sin_family: u16,
    sin_port: u16,
    sin_addr: u32,
    sin_zero: [8]u8,
};

extern fn socket(domain: c_int, typ: c_int, protocol: c_int) c_int;
extern fn connect(sockfd: c_int, addr: ?*const anyopaque, addrlen: c_uint) c_int;
extern fn send(sockfd: c_int, buf: [*c]const u8, len: usize, flags: c_int) isize;
extern fn recv(sockfd: c_int, buf: [*c]u8, len: usize, flags: c_int) isize;
extern fn close(fd: c_int) c_int;
extern fn setsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: ?*const anyopaque, optlen: c_uint) c_int;
extern fn htons(hostshort: u16) u16;
extern fn inet_pton(af: c_int, src: [*c]const u8, dst: ?*anyopaque) c_int;

// ── Per-location config ─────────────────────────────────────────────────────

const dynamic_upstreams_loc_conf = extern struct {
    api_enabled: ngx_flag_t,
    source: ngx_str_t,
    source_file: ngx_str_t,
    target: ngx_str_t,
    refresh_ms: ngx_uint_t,
    target_uscf: [*c]ngx_http_upstream_srv_conf_t,
    worker_events_channel: ngx_str_t,
    refresh_registered: ngx_flag_t,
    journal_path: ngx_str_t,
    journal_registered: ngx_flag_t,
    // consul source fields
    consul_host: ngx_str_t,     // null-terminated IP string
    consul_port: ngx_uint_t,    // default 8500
    consul_service: ngx_str_t,
    consul_tag: ngx_str_t,
    consul_token: ngx_str_t,
    consul_dc: ngx_str_t,
};

const RefreshEntry = struct {
    lccf: [*c]dynamic_upstreams_loc_conf,
    timer: core.ngx_event_t,
};

const JournalEntry = struct {
    lccf: [*c]dynamic_upstreams_loc_conf,
};

var refresh_entries: [MAX_REFRESH_ENTRIES]RefreshEntry = undefined;
var refresh_entry_count: usize = 0;
var journal_entries: [MAX_REFRESH_ENTRIES]JournalEntry = undefined;
var journal_entry_count: usize = 0;
// Tracks all managed DynamicUpstreamsSrvConf pointers for ngz_du_is_peer_draining
var managed_ducfs: [MAX_REFRESH_ENTRIES][*c]DynamicUpstreamsSrvConf = undefined;
var managed_ducf_count: usize = 0;

// ── Per-upstream config (stored in uscf->srv_conf) ─────────────────────────

const DynamicUpstreamsSrvConf = extern struct {
    managed: ngx_flag_t,
    zone: [*c]core.ngx_shm_zone_t,
    store: [*c]UpstreamStore,
};

// ── Shared-memory structures ─────────────────────────────────────────────────

// Drain table entry — one slot per peer address marked draining.
const MAX_DRAIN_PEERS = 32;
const DrainEntry = extern struct {
    addr: [64]u8,
    addr_len: u8,
};

// Control block — one per managed upstream, lives in the slab pool.
const UpstreamStore = extern struct {
    next_generation: u64,
    active: ?*anyopaque,         // *Snapshot, swapped atomically under shmtx
    draining_head: ?*anyopaque,  // *Snapshot linked list of draining snapshots
    last_error_code: u32,
    last_error_at_msec: i64,
    last_success_at_msec: i64,
    // Journal restore status (set only at cold-start, before any request is served)
    restored_from_journal: u8,
    restore_error_code: u32,
    // Drain table — peers explicitly marked draining via PATCH /drain
    drain_count: u32,
    drain_table: [MAX_DRAIN_PEERS]DrainEntry,
};

// Immutable peer snapshot, pinned per-request.
const Snapshot = extern struct {
    generation: u64,
    refcount: c_ulong,      // ngx_atomic_uint_t — modified via @atomicRmw
    draining: ngx_flag_t,
    peer_count: ngx_uint_t,
    peers: [*c]ngx_http_upstream_rr_peers_t,
    next_draining: ?*anyopaque, // *Snapshot
};

// ── Vtable ────────────────────────────────────────────────────────────────────

const du_vtable = PeerSourceVTable{
    .get_active_peers = @constCast(@ptrCast(&du_get_active_peers)),
    .release_generation = @constCast(@ptrCast(&du_release_generation)),
};

// ── Helpers ───────────────────────────────────────────────────────────────────

fn get_shpool(zone: [*c]core.ngx_shm_zone_t) ?[*c]core.ngx_slab_pool_t {
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return null;
    if (zone.*.shm.addr == null) return null;
    return core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr);
}

fn get_ducf(uscf: [*c]ngx_http_upstream_srv_conf_t) ?[*c]DynamicUpstreamsSrvConf {
    return core.castPtr(
        DynamicUpstreamsSrvConf,
        conf.ngx_http_conf_upstream_srv_conf(uscf, &ngx_http_dynamic_upstreams_module),
    );
}

fn send_json_response(r: [*c]ngx_http_request_t, status: ngx_uint_t, body: ngx_str_t) ngx_int_t {
    const content_type = ngx_string("application/json");
    r.*.headers_out.status = status;
    r.*.headers_out.content_type = content_type;
    r.*.headers_out.content_type_len = content_type.len;
    r.*.headers_out.content_length_n = @intCast(body.len);
    const header_rc = http.ngx_http_send_header(r);
    if (header_rc == core.NGX_ERROR or header_rc > core.NGX_OK) return header_rc;
    if (r.*.method == http.NGX_HTTP_HEAD) return core.NGX_OK;
    const out_buf = core.ngz_pcalloc_c(ngx_buf_t, r.*.pool) orelse return core.NGX_ERROR;
    out_buf.*.pos = body.data;
    out_buf.*.last = body.data + body.len;
    out_buf.*.flags.memory = true;
    out_buf.*.flags.last_buf = true;
    out_buf.*.flags.last_in_chain = true;
    const chain = core.ngz_pcalloc_c(ngx_chain_t, r.*.pool) orelse return core.NGX_ERROR;
    chain.*.buf = out_buf;
    chain.*.next = core.nullptr(ngx_chain_t);
    return http.ngx_http_output_filter(r, chain);
}

fn dupSlabStr(shpool: [*c]core.ngx_slab_pool_t, src_data: [*c]u8, src_len: usize) ?ngx_str_t {
    const mem = shm.ngx_slab_calloc_locked(shpool, src_len + 1) orelse return null;
    const dst = core.castPtr(u8, mem) orelse return null;
    @memcpy(dst[0..src_len], core.slicify(u8, src_data, src_len));
    dst[src_len] = 0;
    return ngx_str_t{ .data = dst, .len = src_len };
}

fn dupSlabStrPtr(shpool: [*c]core.ngx_slab_pool_t, src_data: [*c]u8, src_len: usize) ?[*c]ngx_str_t {
    const str_mem = shm.ngx_slab_calloc_locked(shpool, @sizeOf(ngx_str_t)) orelse return null;
    const dst = core.castPtr(ngx_str_t, str_mem) orelse return null;
    dst.* = dupSlabStr(shpool, src_data, src_len) orelse {
        shm.ngx_slab_free_locked(shpool, str_mem);
        return null;
    };
    return dst;
}

fn currentTimeMsec() i64 {
    const tp = core.ngx_timeofday();
    if (tp) |t| {
        return @as(i64, @intCast(t.*.sec)) * 1000 + @as(i64, @intCast(t.*.msec));
    }
    return 0;
}

fn is_json_content_type(r: [*c]ngx_http_request_t) bool {
    if (r.*.headers_in.content_type == null) return false;
    const value = r.*.headers_in.content_type.*.value;
    if (value.len == 0 or value.data == null) return false;
    const raw = core.slicify(u8, value.data, value.len);
    const media_end = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    const media_type = std.mem.trim(u8, raw[0..media_end], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/json");
}

fn record_store_error_locked(store: [*c]UpstreamStore, code: u32) void {
    store.*.last_error_code = code;
    store.*.last_error_at_msec = currentTimeMsec();
}

fn record_store_error(ducf: [*c]DynamicUpstreamsSrvConf, code: u32) void {
    const store = ducf.*.store;
    if (store == core.nullptr(UpstreamStore)) return;
    const shpool = get_shpool(ducf.*.zone) orelse return;
    shm.ngx_shmtx_lock(&shpool.*.mutex);
    record_store_error_locked(store, code);
    shm.ngx_shmtx_unlock(&shpool.*.mutex);
}

fn record_store_success_locked(store: [*c]UpstreamStore) void {
    store.*.last_error_code = 0;
    store.*.last_success_at_msec = currentTimeMsec();
}

fn publish_snapshot_event(channel: ngx_str_t, target: ngx_str_t, source: ngx_str_t, generation: u64, peer_count: usize) void {
    const zone = ngx_http_worker_events_default_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return;
    if (channel.len == 0 or channel.data == null) return;

    const event_type = ngx_string("snapshot_activated");
    const source_slice = if (source.len == 0 or source.data == null)
        "static"
    else
        core.slicify(u8, source.data, source.len);

    var payload_buf: [256]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &payload_buf,
        "{{\"target\":\"{s}\",\"source\":\"{s}\",\"generation\":{d},\"peer_count\":{d}}}",
        .{ core.slicify(u8, target.data, target.len), source_slice, generation, peer_count },
    ) catch return;
    const payload_str = ngx_str_t{ .len = payload.len, .data = @constCast(payload.ptr) };
    _ = ngx_http_worker_events_publish_internal(zone, channel, event_type, payload_str);
}

fn publish_refresh_failed_event(channel: ngx_str_t, target: ngx_str_t, source: ngx_str_t, error_code: u32) void {
    const zone = ngx_http_worker_events_default_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return;
    if (channel.len == 0 or channel.data == null) return;

    const event_type = ngx_string("refresh_failed");
    const source_slice = if (source.len == 0 or source.data == null)
        "static"
    else
        core.slicify(u8, source.data, source.len);

    var payload_buf: [256]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &payload_buf,
        "{{\"target\":\"{s}\",\"source\":\"{s}\",\"error_code\":{d}}}",
        .{ core.slicify(u8, target.data, target.len), source_slice, error_code },
    ) catch return;
    const payload_str = ngx_str_t{ .len = payload.len, .data = @constCast(payload.ptr) };
    _ = ngx_http_worker_events_publish_internal(zone, channel, event_type, payload_str);
}

// ── Journal persistence ───────────────────────────────────────────────────────

fn writeFileAtomic(path_str: ngx_str_t, content: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path_slice = core.slicify(u8, path_str.data, path_str.len);

    var tmp_buf: [1024]u8 = undefined;
    if (path_str.len + 5 > tmp_buf.len) return error.PathTooLong;
    @memcpy(tmp_buf[0..path_str.len], path_slice);
    @memcpy(tmp_buf[path_str.len..][0..4], ".tmp");
    tmp_buf[path_str.len + 4] = 0;
    const tmp_path = tmp_buf[0..path_str.len + 4];

    var final_buf: [1024]u8 = undefined;
    @memcpy(final_buf[0..path_str.len], path_slice);
    final_buf[path_str.len] = 0;

    var f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, content);

    if (std.c.rename(@ptrCast(tmp_buf[0..].ptr), @ptrCast(final_buf[0..].ptr)) != 0) {
        return error.RenameFailed;
    }
}

// Build and write journal JSON for the activated peer set.
// Called after successful activation; best-effort (errors are silently ignored).
fn write_journal_if_configured(
    lccf: [*c]dynamic_upstreams_loc_conf,
    specs: [*c]PeerSpec,
    count: usize,
    generation: u64,
) void {
    if (lccf.*.journal_path.len == 0 or lccf.*.journal_path.data == null) return;

    // Estimate: metadata header ~200 bytes + per peer ~60 bytes
    const max_len = 256 + count * 64;
    if (max_len > 16 * 1024) return; // guard against absurd peer counts

    var jbuf: [16 * 1024]u8 = undefined;
    var w: [*]u8 = &jbuf;
    const w_end = w + jbuf.len;

    const source_slice = if (lccf.*.source.len > 0 and lccf.*.source.data != null)
        core.slicify(u8, lccf.*.source.data, lccf.*.source.len)
    else
        "static";
    const target_slice = core.slicify(u8, lccf.*.target.data, lccf.*.target.len);

    appendRaw(&w, w_end, "{\"schema\":1,\"target\":\"");
    appendRaw(&w, w_end, target_slice);
    appendRaw(&w, w_end, "\",\"source\":\"");
    appendRaw(&w, w_end, source_slice);
    appendRaw(&w, w_end, "\",\"generation\":");
    appendUint(&w, w_end, generation);
    appendRaw(&w, w_end, ",\"persisted_at_msec\":");
    const ts: i64 = currentTimeMsec();
    appendUint(&w, w_end, @intCast(if (ts > 0) ts else 0));
    appendRaw(&w, w_end, ",\"peers\":[");

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i > 0) appendRaw(&w, w_end, ",");
        appendRaw(&w, w_end, "{\"address\":\"");
        appendRaw(&w, w_end, core.slicify(u8, specs[i].addr_data, specs[i].addr_len));
        appendRaw(&w, w_end, "\",\"weight\":");
        appendUint(&w, w_end, @intCast(@max(0, specs[i].weight)));
        appendRaw(&w, w_end, "}");
    }
    appendRaw(&w, w_end, "]}");

    const used = @intFromPtr(w) - @intFromPtr(&jbuf);
    writeFileAtomic(lccf.*.journal_path, jbuf[0..used]) catch {};
}

fn appendRaw(w: *[*]u8, end: [*]u8, s: []const u8) void {
    const avail = @intFromPtr(end) - @intFromPtr(w.*);
    const n = @min(s.len, avail);
    @memcpy(w.*[0..n], s[0..n]);
    w.* += n;
}

fn appendUint(w: *[*]u8, end: [*]u8, val: u64) void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch return;
    appendRaw(w, end, s);
}

// Attempt to restore the active snapshot from the journal file.
// Only called at cold-start by worker 0, before any requests are served.
fn restore_from_journal(entry: *JournalEntry, lg: [*c]ngx.log.ngx_log_t) void {
    const lccf = entry.lccf;
    if (lccf == core.nullptr(dynamic_upstreams_loc_conf)) return;
    if (lccf.*.journal_path.len == 0 or lccf.*.journal_path.data == null) return;
    if (lccf.*.target_uscf == core.nullptr(ngx_http_upstream_srv_conf_t)) return;

    const ducf = get_ducf(lccf.*.target_uscf) orelse return;
    if (ducf.*.managed == 0) return;

    const store = ducf.*.store;
    if (store == core.nullptr(UpstreamStore)) return;

    // Skip restore if a snapshot is already active (reload reused inherited zone)
    if (store.*.active != null) return;

    const pool = core.ngx_create_pool(32 * 1024, lg);
    if (pool == core.nullptr(core.ngx_pool_t)) {
        store.*.restore_error_code = DU_ERROR_ALLOCATION_FAILED;
        return;
    }
    defer core.ngx_destroy_pool(pool);

    const body_str = file.ngz_open_file(lccf.*.journal_path, lg, pool) catch {
        // Journal file not present — normal on first startup
        return;
    };

    var cj = CJSON.init(pool);
    const json = cj.decode(body_str) catch {
        store.*.restore_error_code = DU_ERROR_INVALID_JSON;
        return;
    };
    defer cj.free(json);

    // Validate schema version
    const schema_node = cjson.cJSON_GetObjectItem(json, "schema");
    if (schema_node == core.nullptr(cjson.cJSON) or schema_node.*.valueint != 1) {
        store.*.restore_error_code = DU_ERROR_INVALID_PAYLOAD;
        return;
    }

    // Validate target name matches current config
    const target_node = cjson.cJSON_GetObjectItem(json, "target");
    if (target_node == core.nullptr(cjson.cJSON) or target_node.*.valuestring == null) {
        store.*.restore_error_code = DU_ERROR_INVALID_PAYLOAD;
        return;
    }
    const journal_target = std.mem.sliceTo(target_node.*.valuestring, 0);
    const config_target = core.slicify(u8, lccf.*.target.data, lccf.*.target.len);
    if (!std.mem.eql(u8, journal_target, config_target)) {
        store.*.restore_error_code = DU_ERROR_INVALID_PAYLOAD;
        return;
    }

    // Activate snapshot; bypass health filtering so cold-start restores all journal peers
    const result = build_and_activate_snapshot(pool, ducf, lccf.*.target_uscf, lccf, json, false, false, true);
    switch (result) {
        .ok => {
            store.*.restored_from_journal = 1;
            store.*.restore_error_code = 0;
        },
        .err => {
            store.*.restore_error_code = DU_ERROR_INVALID_PAYLOAD;
        },
    }
}

// ── Zone init callback ────────────────────────────────────────────────────────

// Called once per worker per config cycle.
// zone->data is set to ducf before ngx_shared_memory_add returns.
// old_data (from previous cycle) is the UpstreamStore pointer, or null on first start.
fn du_zone_init_cb(zone: [*c]core.ngx_shm_zone_t, old_data: ?*anyopaque) callconv(.c) ngx_int_t {
    const ducf = core.castPtr(DynamicUpstreamsSrvConf, zone.*.data) orelse return core.NGX_ERROR;

    if (old_data) |od| {
        // Config reload: reuse the previous store (already initialized in slab)
        ducf.*.store = core.castPtr(UpstreamStore, od) orelse return core.NGX_ERROR;
        zone.*.data = od;
        return core.NGX_OK;
    }

    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return core.NGX_ERROR;

    // Another worker may have initialized already
    if (shpool.*.data) |existing| {
        ducf.*.store = core.castPtr(UpstreamStore, existing) orelse return core.NGX_ERROR;
        zone.*.data = existing;
        return core.NGX_OK;
    }

    // First worker to initialize: allocate store in slab
    const mem = shm.ngx_slab_calloc(shpool, @sizeOf(UpstreamStore)) orelse return core.NGX_ERROR;
    const store = core.castPtr(UpstreamStore, mem) orelse return core.NGX_ERROR;
    store.*.next_generation = 1;
    store.*.active = null;
    store.*.draining_head = null;
    store.*.last_error_code = 0;
    store.*.last_error_at_msec = 0;
    store.*.last_success_at_msec = 0;

    shpool.*.data = store;
    zone.*.data = store;
    ducf.*.store = store;
    return core.NGX_OK;
}

// ── Config: create / merge ────────────────────────────────────────────────────

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const lccf = core.ngz_pcalloc_c(dynamic_upstreams_loc_conf, cf.*.pool) orelse return null;
    lccf.*.api_enabled = conf.NGX_CONF_UNSET;
    lccf.*.source = ngx_null_str;
    lccf.*.source_file = ngx_null_str;
    lccf.*.target = ngx_null_str;
    lccf.*.refresh_ms = 0;
    lccf.*.target_uscf = core.nullptr(ngx_http_upstream_srv_conf_t);
    lccf.*.worker_events_channel = ngx_null_str;
    lccf.*.refresh_registered = 0;
    lccf.*.journal_path = ngx_null_str;
    lccf.*.journal_registered = 0;
    lccf.*.consul_host = ngx_null_str;
    lccf.*.consul_port = 8500;
    lccf.*.consul_service = ngx_null_str;
    lccf.*.consul_tag = ngx_null_str;
    lccf.*.consul_token = ngx_null_str;
    lccf.*.consul_dc = ngx_null_str;
    return lccf;
}

fn merge_loc_conf(cf: [*c]ngx_conf_t, parent: ?*anyopaque, child: ?*anyopaque) callconv(.c) [*c]u8 {
    const prev = core.castPtr(dynamic_upstreams_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(dynamic_upstreams_loc_conf, child) orelse return conf.NGX_CONF_OK;
    if (c.*.api_enabled == conf.NGX_CONF_UNSET) {
        c.*.api_enabled = if (prev.*.api_enabled == conf.NGX_CONF_UNSET) 0 else prev.*.api_enabled;
    }
    if (c.*.source.len == 0) c.*.source = prev.*.source;
    if (c.*.source_file.len == 0) c.*.source_file = prev.*.source_file;
    if (c.*.target.len == 0) c.*.target = prev.*.target;
    if (c.*.refresh_ms == 0) c.*.refresh_ms = prev.*.refresh_ms;
    if (c.*.target_uscf == core.nullptr(ngx_http_upstream_srv_conf_t)) {
        c.*.target_uscf = prev.*.target_uscf;
    }
    if (c.*.worker_events_channel.len == 0) c.*.worker_events_channel = prev.*.worker_events_channel;
    if (c.*.journal_path.len == 0) c.*.journal_path = prev.*.journal_path;
    if (c.*.consul_host.len == 0) c.*.consul_host = prev.*.consul_host;
    if (c.*.consul_port == 8500 and prev.*.consul_port != 8500) c.*.consul_port = prev.*.consul_port;
    if (c.*.consul_service.len == 0) c.*.consul_service = prev.*.consul_service;
    if (c.*.consul_tag.len == 0) c.*.consul_tag = prev.*.consul_tag;
    if (c.*.consul_token.len == 0) c.*.consul_token = prev.*.consul_token;
    if (c.*.consul_dc.len == 0) c.*.consul_dc = prev.*.consul_dc;

    if (c.*.api_enabled != 0 and c.*.target_uscf == core.nullptr(ngx_http_upstream_srv_conf_t)) {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, cf.*.log, 0,
            "dynamic_upstreams: dynamic_upstreams_target is required when dynamic_upstreams_api is enabled\x00", .{});
        return conf.NGX_CONF_ERROR;
    }

    if (c.*.refresh_ms > 0) {
        const src = if (c.*.source.len > 0)
            core.slicify(u8, c.*.source.data, c.*.source.len)
        else
            @as([]const u8, "static");
        const is_consul = std.mem.eql(u8, src, "consul");
        if (!std.mem.eql(u8, src, "static") and !is_consul) {
            return @constCast("dynamic_upstreams: unsupported source; supported: static, consul");
        }
        if (!is_consul) {
            if (c.*.source_file.len == 0 or c.*.source_file.data == null) {
                return @constCast("dynamic_upstreams_refresh requires dynamic_upstreams_source_file");
            }
        } else {
            if (c.*.consul_host.len == 0 or c.*.consul_host.data == null) {
                return @constCast("dynamic_upstreams_consul_address is required for consul source");
            }
            if (c.*.consul_service.len == 0 or c.*.consul_service.data == null) {
                return @constCast("dynamic_upstreams_consul_service is required for consul source");
            }
        }
        if (c.*.refresh_registered == 0) {
            if (refresh_entry_count >= MAX_REFRESH_ENTRIES) {
                return @constCast("dynamic_upstreams: too many refresh-enabled locations");
            }
            refresh_entries[refresh_entry_count] = .{
                .lccf = c,
                .timer = std.mem.zeroes(core.ngx_event_t),
            };
            refresh_entry_count += 1;
            c.*.refresh_registered = 1;
        }
    }

    // Register journal entry so restore_from_journal runs at cold-start
    if (c.*.journal_path.len > 0 and c.*.journal_path.data != null and c.*.journal_registered == 0) {
        if (journal_entry_count < MAX_REFRESH_ENTRIES) {
            journal_entries[journal_entry_count] = .{ .lccf = c };
            journal_entry_count += 1;
            c.*.journal_registered = 1;
        }
    }

    return conf.NGX_CONF_OK;
}

fn create_srv_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const ducf = core.ngz_pcalloc_c(DynamicUpstreamsSrvConf, cf.*.pool) orelse return null;
    ducf.*.managed = 0;
    ducf.*.zone = core.nullptr(core.ngx_shm_zone_t);
    ducf.*.store = core.nullptr(UpstreamStore);
    return ducf;
}

fn merge_srv_conf(cf: [*c]ngx_conf_t, parent: ?*anyopaque, child: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    _ = parent;
    _ = child;
    return conf.NGX_CONF_OK;
}

// ── Drain contract ────────────────────────────────────────────────────────────

// Called by upstream-balancer at request time to exclude draining peers from
// new connection selection. Fail-open: unknown peer → not draining.
// Hot path: drain_count is 0 until a PATCH /drain request populates the table.
export fn ngz_du_is_peer_draining(addr_data: [*c]u8, addr_len: usize) callconv(.c) c_int {
    if (addr_data == null or addr_len == 0 or addr_len > 64) return 0;
    const addr = core.slicify(u8, addr_data, addr_len);
    var i: usize = 0;
    while (i < managed_ducf_count) : (i += 1) {
        const ducf = managed_ducfs[i];
        const store_cptr = ducf.*.store;
        if (store_cptr == null) continue;
        // Cast away the [*c] indirection so array field access works correctly.
        const store: *UpstreamStore = @alignCast(@ptrCast(store_cptr));
        // Fast path: no draining peers in this upstream
        if (@atomicLoad(u32, &store.drain_count, .monotonic) == 0) continue;
        // Slow path: search drain table populated by PATCH /drain (Phase 5)
        const count: usize = @min(store.drain_count, MAX_DRAIN_PEERS);
        var j: usize = 0;
        while (j < count) : (j += 1) {
            const elen: usize = store.drain_table[j].addr_len;
            if (elen == addr_len and
                std.mem.eql(u8, store.drain_table[j].addr[0..addr_len], addr))
            {
                return 1;
            }
        }
    }
    return 0;
}

// ── Postconfiguration ─────────────────────────────────────────────────────────

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    const umcf = core.castPtr(
        ngx_http_upstream_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_upstream_module),
    ) orelse return core.NGX_OK;

    var i: ngx_uint_t = 0;
    while (ngx.array.ngx_array_next([*c]ngx_http_upstream_srv_conf_t, &umcf.*.upstreams, &i)) |uscfp| {
        const uscf = uscfp.*;
        const ducf = get_ducf(uscf) orelse continue;
        if (ducf.*.managed == 0) continue;

        if (managed_ducf_count < MAX_REFRESH_ENTRIES) {
            managed_ducfs[managed_ducf_count] = ducf;
            managed_ducf_count += 1;
        }

        // Install the balancer's init_peer wrapper (needed so peer source is used)
        if (upstream_balancer_ensure_hook(uscf) != core.NGX_OK) {
            ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, cf.*.log, 0,
                "dynamic_upstreams: upstream_balancer_ensure_hook failed\x00", .{});
            return core.NGX_ERROR;
        }

        // Register this module as the peer source for this upstream
        if (upstream_balancer_register_peer_source(uscf, ducf, &du_vtable) != core.NGX_OK) {
            ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, cf.*.log, 0,
                "dynamic_upstreams: register_peer_source failed\x00", .{});
            return core.NGX_ERROR;
        }
    }

    return core.NGX_OK;
}

// ── Directive helpers ─────────────────────────────────────────────────────────

fn find_upstream_by_name(cf: [*c]ngx_conf_t, name: ngx_str_t) ?[*c]ngx_http_upstream_srv_conf_t {
    const umcf = core.castPtr(
        ngx_http_upstream_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_upstream_module),
    ) orelse return null;

    var i: ngx_uint_t = 0;
    while (ngx.array.ngx_array_next([*c]ngx_http_upstream_srv_conf_t, &umcf.*.upstreams, &i)) |uscfp| {
        const uscf = uscfp.*;
        if (ngx.string.eql(uscf.*.host, name)) return uscf;
    }
    return null;
}

// ── Directive handlers ────────────────────────────────────────────────────────

fn set_dynamic_upstreams_managed(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    data: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = data;

    const uscf = core.castPtr(
        ngx_http_upstream_srv_conf_t,
        conf.ngx_http_conf_get_module_srv_conf(cf, &ngx_http_upstream_module),
    ) orelse return conf.NGX_CONF_ERROR;

    const ducf = core.castPtr(
        DynamicUpstreamsSrvConf,
        conf.ngx_http_conf_upstream_srv_conf(uscf, &ngx_http_dynamic_upstreams_module),
    ) orelse return conf.NGX_CONF_ERROR;

    if (ducf.*.managed != 0) return conf.NGX_CONF_OK; // already configured

    ducf.*.managed = 1;

    // Build zone name "du:<upstream_name>"
    const prefix = "du:";
    const name_len = prefix.len + uscf.*.host.len;
    const name_data = core.castPtr(u8, core.ngx_pnalloc(cf.*.pool, name_len)) orelse
        return conf.NGX_CONF_ERROR;
    @memcpy(name_data[0..prefix.len], prefix);
    @memcpy(name_data[prefix.len..][0..uscf.*.host.len], core.slicify(u8, uscf.*.host.data, uscf.*.host.len));
    var zone_name = ngx_str_t{ .data = name_data, .len = name_len };

    const zone = shm.ngx_shared_memory_add(cf, &zone_name, DU_ZONE_SIZE, @constCast(&ngx_http_dynamic_upstreams_module)) orelse
        return conf.NGX_CONF_ERROR;

    zone.*.init = du_zone_init_cb;
    zone.*.data = ducf; // passed to zone_init_cb as zone->data
    ducf.*.zone = zone;

    return conf.NGX_CONF_OK;
}

fn set_dynamic_upstreams_api(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(dynamic_upstreams_loc_conf, loc)) |lccf| {
        lccf.*.api_enabled = 1;
        const clcf = core.castPtr(
            http.ngx_http_core_loc_conf_t,
            conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
        ) orelse return conf.NGX_CONF_ERROR;
        clcf.*.handler = ngx_http_dynamic_upstreams_handler;
    }
    return conf.NGX_CONF_OK;
}

fn set_dynamic_upstreams_source(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(dynamic_upstreams_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const val = core.slicify(u8, arg.*.data, arg.*.len);
            if (!std.mem.eql(u8, val, "static") and !std.mem.eql(u8, val, "consul")) {
                ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, cf.*.log, 0,
                    "dynamic_upstreams: unsupported source '%.*s'; supported: static, consul\x00",
                    .{ @as(c_int, @intCast(arg.*.len)), arg.*.data });
                return conf.NGX_CONF_ERROR;
            }
            lccf.*.source = arg.*;
        }
    }
    return conf.NGX_CONF_OK;
}

fn set_dynamic_upstreams_source_file(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(dynamic_upstreams_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            var resolved = arg.*;
            if (conf.ngx_conf_full_name(cf.*.cycle, &resolved, 1) != core.NGX_OK) {
                return conf.NGX_CONF_ERROR;
            }
            const data = core.castPtr(u8, core.ngx_pnalloc(cf.*.pool, resolved.len + 1)) orelse
                return conf.NGX_CONF_ERROR;
            @memcpy(core.slicify(u8, data, resolved.len), core.slicify(u8, resolved.data, resolved.len));
            data[resolved.len] = 0;
            lccf.*.source_file = ngx_str_t{ .data = data, .len = resolved.len };
        }
    }
    return conf.NGX_CONF_OK;
}

fn set_dynamic_upstreams_target(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(dynamic_upstreams_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            lccf.*.target = arg.*;
            // Resolve at config parse time for fast access at request time
            lccf.*.target_uscf = find_upstream_by_name(cf, arg.*) orelse {
                ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, cf.*.log, 0,
                    "dynamic_upstreams: target upstream not found\x00", .{});
                return conf.NGX_CONF_ERROR;
            };
        }
    }
    return conf.NGX_CONF_OK;
}

fn set_dynamic_upstreams_refresh(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(dynamic_upstreams_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const slice = core.slicify(u8, arg.*.data, arg.*.len);
            lccf.*.refresh_ms = std.fmt.parseInt(ngx_uint_t, slice, 10) catch {
                ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, cf.*.log, 0,
                    "dynamic_upstreams: refresh must be a positive integer milliseconds value\x00", .{});
                return conf.NGX_CONF_ERROR;
            };
            if (lccf.*.refresh_ms == 0) {
                ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, cf.*.log, 0,
                    "dynamic_upstreams: refresh must be greater than zero\x00", .{});
                return conf.NGX_CONF_ERROR;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

fn set_dynamic_upstreams_worker_events_channel(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(dynamic_upstreams_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            lccf.*.worker_events_channel = arg.*;
        }
    }
    return conf.NGX_CONF_OK;
}

fn set_dynamic_upstreams_journal(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(dynamic_upstreams_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            lccf.*.journal_path = arg.*;
        }
    }
    return conf.NGX_CONF_OK;
}

fn set_dynamic_upstreams_consul_address(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(dynamic_upstreams_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const slice = core.slicify(u8, arg.*.data, arg.*.len);
            var host_len = slice.len;
            var port: ngx_uint_t = 8500;
            if (std.mem.lastIndexOfScalar(u8, slice, ':')) |colon| {
                host_len = colon;
                port = std.fmt.parseInt(ngx_uint_t, slice[colon + 1 ..], 10) catch {
                    return @constCast("dynamic_upstreams_consul_address: invalid port");
                };
            }
            const data = core.castPtr(u8, core.ngx_pnalloc(cf.*.pool, host_len + 1)) orelse
                return conf.NGX_CONF_ERROR;
            @memcpy(core.slicify(u8, data, host_len), slice[0..host_len]);
            data[host_len] = 0;
            lccf.*.consul_host = ngx_str_t{ .data = data, .len = host_len };
            lccf.*.consul_port = port;
        }
    }
    return conf.NGX_CONF_OK;
}

// ── GET handler ───────────────────────────────────────────────────────────────

// Pool-allocated JSON builder using pointer arithmetic (no fixedBufferStream).
const JsonBuilder = struct {
    w: [*]u8,
    end: [*]u8,

    fn init(pool: [*c]core.ngx_pool_t, est: usize) ?JsonBuilder {
        const raw = core.ngx_pnalloc(pool, est) orelse return null;
        const p: [*]u8 = @ptrCast(@alignCast(raw));
        return JsonBuilder{ .w = p, .end = p + est };
    }

    fn append(self: *JsonBuilder, s: []const u8) void {
        const avail = @intFromPtr(self.end) - @intFromPtr(self.w);
        const n = @min(s.len, avail);
        @memcpy(self.w[0..n], s[0..n]);
        self.w += n;
    }

    fn appendFmt(self: *JsonBuilder, comptime fmt: []const u8, args: anytype) void {
        var tmp: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, fmt, args) catch return;
        self.append(s);
    }

    fn str(self: *const JsonBuilder, start: [*]const u8) ngx_str_t {
        const len = @intFromPtr(self.w) - @intFromPtr(start);
        return ngx_str_t{ .data = @constCast(start), .len = len };
    }
};

fn handle_get(r: [*c]ngx_http_request_t) ngx_int_t {
    const lccf = core.castPtr(
        dynamic_upstreams_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_dynamic_upstreams_module),
    ) orelse return core.NGX_ERROR;

    const uscf = lccf.*.target_uscf;
    if (uscf == core.nullptr(ngx_http_upstream_srv_conf_t)) {
        return send_json_response(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"target upstream not configured\"}"));
    }

    const ducf = get_ducf(uscf);
    const managed = (ducf != null and ducf.?.*.managed != 0);

    // Pin the active snapshot (increment refcount while holding lock) so it
    // cannot be freed by a concurrent PUT + du_release_generation on another worker.
    var pinned_generation: u64 = 0;
    var pinned_ducf: ?[*c]DynamicUpstreamsSrvConf = null;
    var active_snapshot: ?[*c]Snapshot = null;
    if (managed) {
        if (get_shpool(ducf.?.*.zone)) |shpool| {
            shm.ngx_shmtx_lock(&shpool.*.mutex);
            if (core.castPtr(UpstreamStore, ducf.?.*.store)) |s| {
                if (s.*.active) |ap| {
                    if (core.castPtr(Snapshot, ap)) |sn| {
                        _ = @atomicRmw(c_ulong, &sn.*.refcount, .Add, 1, .monotonic);
                        pinned_generation = @intFromPtr(sn);
                        pinned_ducf = ducf.?;
                        active_snapshot = sn;
                    }
                }
            }
            shm.ngx_shmtx_unlock(&shpool.*.mutex);
        }
    }

    const target_name = core.slicify(u8, lccf.*.target.data, lccf.*.target.len);
    const source_name = if (lccf.*.source.len == 0)
        "static"
    else
        core.slicify(u8, lccf.*.source.data, lccf.*.source.len);
    const generation: u64 = if (active_snapshot) |sn| sn.*.generation else 0;
    const last_error_code: u32 = if (managed and ducf != null and ducf.?.*.store != core.nullptr(UpstreamStore))
        ducf.?.*.store.*.last_error_code
    else
        0;
    const last_error_at_msec: i64 = if (managed and ducf != null and ducf.?.*.store != core.nullptr(UpstreamStore))
        ducf.?.*.store.*.last_error_at_msec
    else
        0;
    const last_success_at_msec: i64 = if (managed and ducf != null and ducf.?.*.store != core.nullptr(UpstreamStore))
        ducf.?.*.store.*.last_success_at_msec
    else
        0;
    const restored_from_journal: u8 = if (managed and ducf != null and ducf.?.*.store != core.nullptr(UpstreamStore))
        ducf.?.*.store.*.restored_from_journal
    else
        0;
    const restore_error_code: u32 = if (managed and ducf != null and ducf.?.*.store != core.nullptr(UpstreamStore))
        ducf.?.*.store.*.restore_error_code
    else
        0;
    const drain_count: u32 = if (managed and ducf != null and ducf.?.*.store != core.nullptr(UpstreamStore)) blk: {
        const s: *UpstreamStore = @alignCast(@ptrCast(ducf.?.*.store));
        break :blk @atomicLoad(u32, &s.drain_count, .acquire);
    } else 0;

    // Count peers (from snapshot or static fallback)
    var peer_count: usize = 0;
    if (active_snapshot) |sn| {
        peer_count = sn.*.peer_count;
    } else {
        const peers = core.castPtr(ngx_http_upstream_rr_peers_t, uscf.*.peer.data);
        if (peers) |pp| {
            var p = pp.*.peer;
            while (p != null) : (p = p.*.next) peer_count += 1;
        }
    }

    // Estimate JSON size
    const est: usize = 320 + target_name.len + source_name.len + peer_count * 80;
    var jb = JsonBuilder.init(r.*.pool, est) orelse return core.NGX_ERROR;
    const start = jb.w;

    jb.append("{\"module\":\"dynamic_upstreams\",\"target\":\"");
    jb.append(target_name);
    jb.append("\",\"source\":\"");
    jb.append(source_name);
    jb.append("\",\"writable\":");
    jb.append(if (managed) "true" else "false");
    jb.append(",\"generation\":");
    jb.appendFmt("{d}", .{generation});
    jb.append(",\"peer_count\":");
    jb.appendFmt("{d}", .{peer_count});
    jb.append(",\"last_error_code\":");
    jb.appendFmt("{d}", .{last_error_code});
    jb.append(",\"last_error_at_msec\":");
    jb.appendFmt("{d}", .{last_error_at_msec});
    jb.append(",\"last_success_at_msec\":");
    jb.appendFmt("{d}", .{last_success_at_msec});
    jb.append(",\"restored_from_journal\":");
    jb.append(if (restored_from_journal != 0) "true" else "false");
    jb.append(",\"restore_error_code\":");
    jb.appendFmt("{d}", .{restore_error_code});
    jb.append(",\"drain_count\":");
    jb.appendFmt("{d}", .{drain_count});
    jb.append(",\"peers\":[");

    var first = true;
    if (active_snapshot) |sn| {
        var p = sn.*.peers.*.peer;
        while (p != null) : (p = p.*.next) {
            if (!first) jb.append(",");
            first = false;
            const name = core.slicify(u8, p.*.name.data, p.*.name.len);
            jb.append("{\"address\":\"");
            jb.append(name);
            jb.append("\",\"weight\":");
            jb.appendFmt("{d}", .{@as(usize, if (p.*.weight > 0) @intCast(p.*.weight) else 1)});
            jb.append("}");
        }
    } else {
        const peers = core.castPtr(ngx_http_upstream_rr_peers_t, uscf.*.peer.data);
        if (peers) |pp| {
            var p = pp.*.peer;
            while (p != null) : (p = p.*.next) {
                if (!first) jb.append(",");
                first = false;
                const name = core.slicify(u8, p.*.name.data, p.*.name.len);
                jb.append("{\"address\":\"");
                jb.append(name);
                jb.append("\",\"weight\":");
                jb.appendFmt("{d}", .{@as(usize, if (p.*.weight > 0) @intCast(p.*.weight) else 1)});
                jb.append("}");
            }
        }
    }

    jb.append("]}");
    const body = jb.str(start);

    // JSON is fully built in pool memory — release the snapshot pin before sending.
    if (pinned_generation != 0) {
        const ctx: ?*anyopaque = @ptrCast(@alignCast(pinned_ducf.?));
        du_release_generation(ctx, core.nullptr(ngx_http_upstream_rr_peers_t), pinned_generation);
    }

    return send_json_response(r, http.NGX_HTTP_OK, body);
}

// ── PUT handler ───────────────────────────────────────────────────────────────

const PeerSpec = struct {
    addr_data: [*c]u8,
    addr_len: usize,
    weight: ngx_int_t,
};

const MAX_PEERS_PER_PUT: usize = 256;

const ApplyResult = struct {
    generation: u64,
    peer_count: usize,
    changed: bool,
};

const ErrorResponse = struct {
    status: ngx_uint_t,
    body: ngx_str_t,
};

const ActivationResult = union(enum) {
    ok: ApplyResult,
    err: ErrorResponse,
};

fn active_snapshot_matches_specs(store: [*c]UpstreamStore, specs: [*c]PeerSpec, count: usize) bool {
    const active_raw = store.*.active orelse return false;
    const sn = core.castPtr(Snapshot, active_raw) orelse return false;
    if (sn.*.peer_count != count) return false;

    var idx: usize = 0;
    var p = sn.*.peers.*.peer;
    while (p != null and idx < count) : ({
        p = p.*.next;
        idx += 1;
    }) {
        const name = core.slicify(u8, p.*.name.data, p.*.name.len);
        const spec_addr = core.slicify(u8, specs[idx].addr_data, specs[idx].addr_len);
        if (!std.mem.eql(u8, name, spec_addr)) return false;
        if (p.*.weight != specs[idx].weight) return false;
    }
    return p == null and idx == count;
}

fn build_and_activate_snapshot(
    pool: [*c]core.ngx_pool_t,
    ducf: [*c]DynamicUpstreamsSrvConf,
    uscf: [*c]ngx_http_upstream_srv_conf_t,
    lccf: [*c]dynamic_upstreams_loc_conf,
    json: [*c]cjson.cJSON,
    allow_noop_if_same: bool,
    allow_empty_peers: bool,
    skip_health_filter: bool,
) ActivationResult {
    const peers_node = cjson.cJSON_GetObjectItem(json, "peers");
    if (peers_node == core.nullptr(cjson.cJSON) or cjson.cJSON_IsArray(peers_node) != 1) {
        record_store_error(ducf, DU_ERROR_INVALID_PAYLOAD);
        return .{ .err = .{ .status = http.NGX_HTTP_BAD_REQUEST, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"'peers' array required\"}") } };
    }

    const n_peers: usize = @intCast(@max(0, cjson.cJSON_GetArraySize(peers_node)));
    if (n_peers == 0 and !allow_empty_peers) {
        record_store_error(ducf, DU_ERROR_INVALID_PAYLOAD);
        return .{ .err = .{ .status = http.NGX_HTTP_BAD_REQUEST, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"at least one peer required\"}") } };
    }
    if (n_peers > MAX_PEERS_PER_PUT) {
        record_store_error(ducf, DU_ERROR_INVALID_PAYLOAD);
        return .{ .err = .{ .status = http.NGX_HTTP_BAD_REQUEST, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"too many peers\"}") } };
    }

    const specs: [*c]PeerSpec = if (n_peers == 0)
        core.nullptr(PeerSpec)
    else
        core.ngz_pcalloc_n(@intCast(n_peers), PeerSpec, pool) orelse {
            record_store_error(ducf, DU_ERROR_ALLOCATION_FAILED);
            return .{ .err = .{ .status = http.NGX_HTTP_INTERNAL_SERVER_ERROR, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"failed to allocate peer scratch space\"}") } };
        };
    const urls: [*c]ngx_url_t = if (n_peers == 0)
        core.nullptr(ngx_url_t)
    else
        core.ngz_pcalloc_n(@intCast(n_peers), ngx_url_t, pool) orelse {
            record_store_error(ducf, DU_ERROR_ALLOCATION_FAILED);
            return .{ .err = .{ .status = http.NGX_HTTP_INTERNAL_SERVER_ERROR, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"failed to allocate url scratch space\"}") } };
        };
    const eligible_specs: [*c]PeerSpec = if (n_peers == 0)
        core.nullptr(PeerSpec)
    else
        core.ngz_pcalloc_n(@intCast(n_peers), PeerSpec, pool) orelse {
            record_store_error(ducf, DU_ERROR_ALLOCATION_FAILED);
            return .{ .err = .{ .status = http.NGX_HTTP_INTERNAL_SERVER_ERROR, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"failed to allocate peer scratch space\"}") } };
        };
    const eligible_urls: [*c]ngx_url_t = if (n_peers == 0)
        core.nullptr(ngx_url_t)
    else
        core.ngz_pcalloc_n(@intCast(n_peers), ngx_url_t, pool) orelse {
            record_store_error(ducf, DU_ERROR_ALLOCATION_FAILED);
            return .{ .err = .{ .status = http.NGX_HTTP_INTERNAL_SERVER_ERROR, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"failed to allocate url scratch space\"}") } };
        };

    var addr_count: usize = 0;
    var it = CJSON.Iterator.init(peers_node);
    while (it.next()) |item| {
        if (addr_count >= MAX_PEERS_PER_PUT) break;

        const addr_node = cjson.cJSON_GetObjectItem(item, "address");
        if (addr_node == core.nullptr(cjson.cJSON) or cjson.cJSON_IsString(addr_node) != 1) {
            record_store_error(ducf, DU_ERROR_INVALID_PEER);
            return .{ .err = .{ .status = http.NGX_HTTP_BAD_REQUEST, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"peer missing 'address' string\"}") } };
        }
        const addr_str = CJSON.stringValue(addr_node) orelse ngx_null_str;
        if (addr_str.len == 0) {
            record_store_error(ducf, DU_ERROR_INVALID_PEER);
            return .{ .err = .{ .status = http.NGX_HTTP_BAD_REQUEST, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"peer address must not be empty\"}") } };
        }

        var weight: ngx_int_t = 1;
        const w_node = cjson.cJSON_GetObjectItem(item, "weight");
        if (w_node != core.nullptr(cjson.cJSON) and cjson.cJSON_IsNumber(w_node) == 1) {
            const wf = cjson.cJSON_GetNumberValue(w_node);
            if (wf < 1 or wf > 65535) {
                record_store_error(ducf, DU_ERROR_INVALID_PEER);
                return .{ .err = .{ .status = http.NGX_HTTP_BAD_REQUEST, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"weight must be 1..65535\"}") } };
            }
            weight = @intFromFloat(wf);
        }

        urls[addr_count] = std.mem.zeroes(ngx_url_t);
        urls[addr_count].url = addr_str;
        urls[addr_count].flags.no_resolve = true;
        if (http.ngx_parse_url(pool, &urls[addr_count]) != core.NGX_OK or urls[addr_count].naddrs == 0) {
            record_store_error(ducf, DU_ERROR_INVALID_PEER);
            return .{ .err = .{ .status = http.NGX_HTTP_BAD_REQUEST, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"invalid peer address (IP:port required)\"}") } };
        }

        specs[addr_count] = .{
            .addr_data = addr_str.data,
            .addr_len = addr_str.len,
            .weight = weight,
        };

        var dup_idx: usize = 0;
        while (dup_idx < addr_count) : (dup_idx += 1) {
            if (std.mem.eql(
                u8,
                core.slicify(u8, specs[dup_idx].addr_data, specs[dup_idx].addr_len),
                core.slicify(u8, specs[addr_count].addr_data, specs[addr_count].addr_len),
            )) {
                record_store_error(ducf, DU_ERROR_INVALID_PEER);
                return .{ .err = .{ .status = http.NGX_HTTP_BAD_REQUEST, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"duplicate peer address\"}") } };
            }
        }

        addr_count += 1;
    }

    if (addr_count == 0 and !allow_empty_peers) {
        record_store_error(ducf, DU_ERROR_INVALID_PAYLOAD);
        return .{ .err = .{ .status = http.NGX_HTTP_BAD_REQUEST, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"no valid peers after parsing\"}") } };
    }

    var eligible_count: usize = 0;
    var idx: usize = 0;
    while (idx < addr_count) : (idx += 1) {
        if (!skip_health_filter and ngz_healthcheck_is_peer_eligible(specs[idx].addr_data, specs[idx].addr_len) == 0) continue;
        eligible_specs[eligible_count] = specs[idx];
        eligible_urls[eligible_count] = urls[idx];
        eligible_count += 1;
    }

    if (eligible_count == 0 and addr_count > 0 and !skip_health_filter) {
        record_store_error(ducf, DU_ERROR_ALL_PEERS_UNHEALTHY);
        return .{ .err = .{ .status = http.NGX_HTTP_SERVICE_UNAVAILABLE, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"no eligible peers after health filtering\"}") } };
    }

    const shpool = get_shpool(ducf.*.zone) orelse
        return .{ .err = .{ .status = http.NGX_HTTP_SERVICE_UNAVAILABLE, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"slab pool unavailable\"}") } };
    const store = ducf.*.store;
    if (store == core.nullptr(UpstreamStore)) {
        return .{ .err = .{ .status = http.NGX_HTTP_SERVICE_UNAVAILABLE, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"store unavailable\"}") } };
    }

    shm.ngx_shmtx_lock(&shpool.*.mutex);

    if (allow_noop_if_same and store.*.active != null and active_snapshot_matches_specs(store, eligible_specs, eligible_count)) {
        const current_generation = (core.castPtr(Snapshot, store.*.active.?)).?.*.generation;
        record_store_success_locked(store);
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
        return .{ .ok = .{ .generation = current_generation, .peer_count = eligible_count, .changed = false } };
    }

    const snapshot_mem = shm.ngx_slab_calloc_locked(shpool, @sizeOf(Snapshot)) orelse {
        record_store_error_locked(store, DU_ERROR_ALLOCATION_FAILED);
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
        return .{ .err = .{ .status = http.NGX_HTTP_SERVICE_UNAVAILABLE, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"slab allocation failed\"}") } };
    };
    const new_snapshot = core.castPtr(Snapshot, snapshot_mem).?;

    const peers_mem = shm.ngx_slab_calloc_locked(shpool, @sizeOf(ngx_http_upstream_rr_peers_t)) orelse {
        record_store_error_locked(store, DU_ERROR_ALLOCATION_FAILED);
        shm.ngx_slab_free_locked(shpool, snapshot_mem);
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
        return .{ .err = .{ .status = http.NGX_HTTP_SERVICE_UNAVAILABLE, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"slab allocation failed\"}") } };
    };
    const new_peers = core.castPtr(ngx_http_upstream_rr_peers_t, peers_mem).?;
    new_peers.*.name = core.nullptr(ngx_str_t);

    const peers_name = dupSlabStrPtr(shpool, uscf.*.host.data, uscf.*.host.len) orelse {
        record_store_error_locked(store, DU_ERROR_ALLOCATION_FAILED);
        shm.ngx_slab_free_locked(shpool, peers_mem);
        shm.ngx_slab_free_locked(shpool, snapshot_mem);
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
        return .{ .err = .{ .status = http.NGX_HTTP_SERVICE_UNAVAILABLE, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"slab allocation failed\"}") } };
    };
    new_peers.*.name = peers_name;

    var total_weight: ngx_uint_t = 0;
    var peer_head: [*c]ngx_http_upstream_rr_peer_t = core.nullptr(ngx_http_upstream_rr_peer_t);
    var peer_tail: [*c]ngx_http_upstream_rr_peer_t = core.nullptr(ngx_http_upstream_rr_peer_t);
    var alloc_ok = true;
    var peer_idx: usize = 0;

    while (peer_idx < eligible_count) : (peer_idx += 1) {
        const spec = &eligible_specs[peer_idx];
        const url = &eligible_urls[peer_idx];
        const addr = &url.addrs[0];

        const peer_mem = shm.ngx_slab_calloc_locked(shpool, @sizeOf(ngx_http_upstream_rr_peer_t)) orelse {
            alloc_ok = false;
            break;
        };
        const peer = core.castPtr(ngx_http_upstream_rr_peer_t, peer_mem).?;

        const sa_mem = shm.ngx_slab_calloc_locked(shpool, @intCast(addr.*.socklen)) orelse {
            shm.ngx_slab_free_locked(shpool, peer_mem);
            alloc_ok = false;
            break;
        };
        const sa_dst: [*c]u8 = @ptrCast(@alignCast(sa_mem));
        const sa_src: [*c]const u8 = @ptrCast(@alignCast(addr.*.sockaddr));
        @memcpy(sa_dst[0..@intCast(addr.*.socklen)], sa_src[0..@intCast(addr.*.socklen)]);
        peer.*.sockaddr = @ptrCast(@alignCast(sa_dst));
        peer.*.socklen = addr.*.socklen;

        const name_slab = dupSlabStr(shpool, addr.*.name.data, addr.*.name.len) orelse {
            shm.ngx_slab_free_locked(shpool, sa_mem);
            shm.ngx_slab_free_locked(shpool, peer_mem);
            alloc_ok = false;
            break;
        };
        peer.*.name = name_slab;

        const server_slab = dupSlabStr(shpool, spec.addr_data, spec.addr_len) orelse {
            shm.ngx_slab_free_locked(shpool, sa_mem);
            shm.ngx_slab_free_locked(shpool, peer_mem);
            alloc_ok = false;
            break;
        };
        peer.*.server = server_slab;

        peer.*.weight = spec.weight;
        peer.*.effective_weight = spec.weight;
        peer.*.current_weight = 0;
        peer.*.max_fails = 1;
        peer.*.fail_timeout = 10;
        peer.*.next = core.nullptr(ngx_http_upstream_rr_peer_t);

        total_weight += @intCast(spec.weight);

        if (peer_head == core.nullptr(ngx_http_upstream_rr_peer_t)) {
            peer_head = peer;
            peer_tail = peer;
        } else {
            peer_tail.*.next = peer;
            peer_tail = peer;
        }
    }

    if (!alloc_ok) {
        record_store_error_locked(store, DU_ERROR_ALLOCATION_FAILED);
        var p = peer_head;
        while (p != core.nullptr(ngx_http_upstream_rr_peer_t)) {
            const nx = p.*.next;
            if (p.*.sockaddr != null) shm.ngx_slab_free_locked(shpool, p.*.sockaddr);
            if (p.*.name.data != null) shm.ngx_slab_free_locked(shpool, p.*.name.data);
            if (p.*.server.data != null) shm.ngx_slab_free_locked(shpool, p.*.server.data);
            shm.ngx_slab_free_locked(shpool, p);
            p = nx;
        }
        if (new_peers.*.name != core.nullptr(ngx_str_t)) {
            if (new_peers.*.name.*.data != null) shm.ngx_slab_free_locked(shpool, new_peers.*.name.*.data);
            shm.ngx_slab_free_locked(shpool, new_peers.*.name);
        }
        shm.ngx_slab_free_locked(shpool, peers_mem);
        shm.ngx_slab_free_locked(shpool, snapshot_mem);
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
        return .{ .err = .{ .status = http.NGX_HTTP_SERVICE_UNAVAILABLE, .body = ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"slab allocation failed for peers\"}") } };
    }

    var any_weighted = false;
    var pi: usize = 0;
    while (pi < eligible_count) : (pi += 1) {
        if (eligible_specs[pi].weight != 1) { any_weighted = true; break; }
    }

    new_peers.*.number = @intCast(eligible_count);
    new_peers.*.total_weight = total_weight;
    new_peers.*.tries = @intCast(eligible_count);
    new_peers.*.flags.single = (eligible_count == 1);
    new_peers.*.flags.weighted = any_weighted;
    new_peers.*.peer = peer_head;
    new_peers.*.next = core.nullptr(ngx_http_upstream_rr_peers_t);
    new_peers.*.shpool = shpool;

    const gen = store.*.next_generation;
    new_snapshot.*.generation = gen;
    new_snapshot.*.refcount = 0;
    new_snapshot.*.draining = 0;
    new_snapshot.*.peer_count = @intCast(eligible_count);
    new_snapshot.*.peers = new_peers;
    new_snapshot.*.next_draining = null;
    record_store_success_locked(store);

    const old_active = store.*.active;
    // Release store so the lockless reader sees all snapshot fields before the pointer.
    const store_typed: *UpstreamStore = @alignCast(@ptrCast(store));
    @atomicStore(usize, @as(*usize, @ptrCast(&store_typed.active)), @intFromPtr(new_snapshot), .release);
    store.*.next_generation = gen + 1;
    if (old_active) |old_ptr| {
        if (core.castPtr(Snapshot, old_ptr)) |old_snap| {
            old_snap.*.draining = 1;
            old_snap.*.next_draining = store.*.draining_head;
            store.*.draining_head = old_snap;
        }
    }

    shm.ngx_shmtx_unlock(&shpool.*.mutex);
    reap_draining(store, shpool);

    if (lccf.*.worker_events_channel.len > 0 and lccf.*.worker_events_channel.data != null) {
        publish_snapshot_event(lccf.*.worker_events_channel, lccf.*.target, lccf.*.source, gen, eligible_count);
    }
    write_journal_if_configured(lccf, eligible_specs, eligible_count, gen);
    return .{ .ok = .{ .generation = gen, .peer_count = eligible_count, .changed = true } };
}

fn handle_put(r: [*c]ngx_http_request_t) ngx_int_t {
    const lccf = core.castPtr(
        dynamic_upstreams_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_dynamic_upstreams_module),
    ) orelse return core.NGX_ERROR;

    const uscf = lccf.*.target_uscf;
    if (uscf == core.nullptr(ngx_http_upstream_srv_conf_t)) {
        return send_json_response(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"target not configured\"}"));
    }

    const ducf = get_ducf(uscf) orelse return core.NGX_ERROR;
    if (ducf.*.managed == 0) {
        return send_json_response(r, http.NGX_HTTP_NOT_ALLOWED,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"upstream is not managed\"}"));
    }

    if (ducf.*.zone == core.nullptr(core.ngx_shm_zone_t) or ducf.*.store == core.nullptr(UpstreamStore)) {
        return send_json_response(r, http.NGX_HTTP_SERVICE_UNAVAILABLE,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"store not initialized\"}"));
    }

    if (!is_json_content_type(r)) {
        record_store_error(ducf, DU_ERROR_INVALID_CONTENT_TYPE);
        _ = http.ngx_http_discard_request_body(r);
        return send_json_response(r, 415,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"content-type must be application/json\"}"));
    }

    const rc = http.ngx_http_read_client_request_body(r, du_put_body_handler);
    if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) return rc;
    return core.NGX_DONE;
}

export fn du_put_body_handler(r: [*c]ngx_http_request_t) callconv(.c) void {
    const lccf = core.castPtr(
        dynamic_upstreams_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_dynamic_upstreams_module),
    ) orelse {
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };

    const uscf = lccf.*.target_uscf;
    const ducf = get_ducf(uscf) orelse {
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };

    // Read body
    if (r.*.request_body == core.nullptr(http.ngx_http_request_body_t) or
        r.*.request_body.*.bufs == core.nullptr(ngx_chain_t))
    {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"missing request body\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    const body_str = buf.ngz_chain_content(r.*.request_body.*.bufs, r.*.pool) catch {
        _ = send_json_response(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"failed to read body\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };

    // Parse JSON
    var cj = CJSON.init(r.*.pool);
    const json = cj.decode(body_str) catch {
        record_store_error(ducf, DU_ERROR_INVALID_JSON);
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"invalid JSON\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    };
    defer cj.free(json);

    const result = build_and_activate_snapshot(r.*.pool, ducf, uscf, lccf, json, false, false, false);
    switch (result) {
        .err => |e| {
            _ = send_json_response(r, e.status, e.body);
            http.ngx_http_finalize_request(r, @intCast(e.status));
        },
        .ok => |ok| {
            var resp_buf: [128]u8 = undefined;
            const resp = std.fmt.bufPrint(&resp_buf,
                "{{\"module\":\"dynamic_upstreams\",\"status\":\"ok\",\"generation\":{d},\"peer_count\":{d}}}",
                .{ ok.generation, ok.peer_count }) catch {
                http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
                return;
            };
            const resp_mem = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, resp.len)) orelse {
                http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
                return;
            };
            @memcpy(resp_mem[0..resp.len], resp);
            const resp_str = ngx_str_t{ .data = resp_mem, .len = resp.len };
            _ = send_json_response(r, http.NGX_HTTP_OK, resp_str);
            http.ngx_http_finalize_request(r, core.NGX_OK);
        },
    }
}

// ── PATCH /drain handler ──────────────────────────────────────────────────────

fn handle_patch(r: [*c]ngx_http_request_t) ngx_int_t {
    const lccf = core.castPtr(
        dynamic_upstreams_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_dynamic_upstreams_module),
    ) orelse return core.NGX_ERROR;

    const uscf = lccf.*.target_uscf;
    if (uscf == core.nullptr(ngx_http_upstream_srv_conf_t)) {
        return send_json_response(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"target not configured\"}"));
    }
    const ducf = get_ducf(uscf) orelse return core.NGX_ERROR;
    if (ducf.*.managed == 0) {
        return send_json_response(r, http.NGX_HTTP_NOT_ALLOWED,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"upstream is not managed\"}"));
    }
    if (ducf.*.zone == core.nullptr(core.ngx_shm_zone_t) or ducf.*.store == core.nullptr(UpstreamStore)) {
        return send_json_response(r, http.NGX_HTTP_SERVICE_UNAVAILABLE,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"store not initialized\"}"));
    }
    if (!is_json_content_type(r)) {
        _ = http.ngx_http_discard_request_body(r);
        return send_json_response(r, 415,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"content-type must be application/json\"}"));
    }
    const rc = http.ngx_http_read_client_request_body(r, du_patch_body_handler);
    if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) return rc;
    return core.NGX_DONE;
}

export fn du_patch_body_handler(r: [*c]ngx_http_request_t) callconv(.c) void {
    const lccf = core.castPtr(
        dynamic_upstreams_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_dynamic_upstreams_module),
    ) orelse {
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };

    const uscf = lccf.*.target_uscf;
    const ducf = get_ducf(uscf) orelse {
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };

    if (r.*.request_body == core.nullptr(http.ngx_http_request_body_t) or
        r.*.request_body.*.bufs == core.nullptr(ngx_chain_t))
    {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"missing request body\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    const body_str = buf.ngz_chain_content(r.*.request_body.*.bufs, r.*.pool) catch {
        _ = send_json_response(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"failed to read body\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };

    var cj = CJSON.init(r.*.pool);
    const json = cj.decode(body_str) catch {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"invalid JSON\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    };
    defer cj.free(json);

    // Determine action and address
    const drain_node = cjson.cJSON_GetObjectItem(json, "drain");
    const undrain_node = cjson.cJSON_GetObjectItem(json, "undrain");
    const is_drain: bool = drain_node != core.nullptr(cjson.cJSON) and cjson.cJSON_IsString(drain_node) == 1;
    const is_undrain: bool = undrain_node != core.nullptr(cjson.cJSON) and cjson.cJSON_IsString(undrain_node) == 1;

    if (!is_drain and !is_undrain) {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"'drain' or 'undrain' string field required\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    const addr_ngx = if (is_drain) CJSON.stringValue(drain_node) else CJSON.stringValue(undrain_node);
    const addr_str = addr_ngx orelse {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"address must be non-empty\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    };
    if (addr_str.len == 0 or addr_str.len > 64) {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"address must be 1..64 bytes\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }
    const addr = core.slicify(u8, addr_str.data, addr_str.len);

    const shpool = get_shpool(ducf.*.zone) orelse {
        _ = send_json_response(r, http.NGX_HTTP_SERVICE_UNAVAILABLE,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"slab pool unavailable\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_SERVICE_UNAVAILABLE);
        return;
    };
    const store_cptr = ducf.*.store;
    if (store_cptr == core.nullptr(UpstreamStore)) {
        _ = send_json_response(r, http.NGX_HTTP_SERVICE_UNAVAILABLE,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"store unavailable\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_SERVICE_UNAVAILABLE);
        return;
    }
    const store: *UpstreamStore = @alignCast(@ptrCast(store_cptr));

    shm.ngx_shmtx_lock(&shpool.*.mutex);

    const new_count: u32 = blk: {
        if (is_drain) {
            // Check for duplicate
            var k: u32 = 0;
            while (k < store.drain_count and k < MAX_DRAIN_PEERS) : (k += 1) {
                const elen: usize = store.drain_table[k].addr_len;
                if (elen == addr_str.len and
                    std.mem.eql(u8, store.drain_table[k].addr[0..addr_str.len], addr))
                {
                    // Already draining — idempotent
                    break :blk store.drain_count;
                }
            }
            if (store.drain_count >= MAX_DRAIN_PEERS) {
                shm.ngx_shmtx_unlock(&shpool.*.mutex);
                _ = send_json_response(r, 409,
                    ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"drain table full\"}"));
                http.ngx_http_finalize_request(r, 409);
                return;
            }
            const idx = store.drain_count;
            store.drain_table[idx].addr_len = @intCast(addr_str.len);
            @memcpy(store.drain_table[idx].addr[0..addr_str.len], addr);
            break :blk store.drain_count + 1;
        } else {
            // Undrain: find and remove by swapping with last (idempotent if not found)
            var k: u32 = 0;
            while (k < store.drain_count and k < MAX_DRAIN_PEERS) : (k += 1) {
                const elen: usize = store.drain_table[k].addr_len;
                if (elen == addr_str.len and
                    std.mem.eql(u8, store.drain_table[k].addr[0..addr_str.len], addr))
                {
                    const last = store.drain_count - 1;
                    if (k != last) {
                        store.drain_table[k] = store.drain_table[last];
                    }
                    break :blk store.drain_count - 1;
                }
            }
            break :blk store.drain_count; // not found — idempotent
        }
    };

    // Write drain_count with release semantics so readers see updated table entries first.
    @atomicStore(u32, &store.drain_count, new_count, .release);

    shm.ngx_shmtx_unlock(&shpool.*.mutex);

    var rbuf: [192]u8 = undefined;
    const action = if (is_drain) "drain" else "undrain";
    const resp = std.fmt.bufPrint(&rbuf,
        "{{\"module\":\"dynamic_upstreams\",\"status\":\"ok\",\"action\":\"{s}\",\"address\":\"{s}\",\"drain_count\":{d}}}",
        .{ action, addr, new_count }) catch {
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };
    const resp_mem = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, resp.len)) orelse {
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };
    @memcpy(resp_mem[0..resp.len], resp);
    const resp_str = ngx_str_t{ .data = resp_mem, .len = resp.len };
    _ = send_json_response(r, http.NGX_HTTP_OK, resp_str);
    http.ngx_http_finalize_request(r, core.NGX_OK);
}

fn free_snapshot_locked(shpool: [*c]core.ngx_slab_pool_t, sn: [*c]Snapshot) void {
    if (sn.*.peers != core.nullptr(ngx_http_upstream_rr_peers_t)) {
        var p = sn.*.peers.*.peer;
        while (p != core.nullptr(ngx_http_upstream_rr_peer_t)) {
            const nx = p.*.next;
            if (p.*.sockaddr != null) shm.ngx_slab_free_locked(shpool, p.*.sockaddr);
            if (p.*.name.data != null) shm.ngx_slab_free_locked(shpool, p.*.name.data);
            if (p.*.server.data != null) shm.ngx_slab_free_locked(shpool, p.*.server.data);
            shm.ngx_slab_free_locked(shpool, p);
            p = nx;
        }
        if (sn.*.peers.*.name != core.nullptr(ngx_str_t)) {
            if (sn.*.peers.*.name.*.data != null) shm.ngx_slab_free_locked(shpool, sn.*.peers.*.name.*.data);
            shm.ngx_slab_free_locked(shpool, sn.*.peers.*.name);
        }
        shm.ngx_slab_free_locked(shpool, sn.*.peers);
    }
    shm.ngx_slab_free_locked(shpool, sn);
}

fn reap_draining(store: [*c]UpstreamStore, shpool: [*c]core.ngx_slab_pool_t) void {
    shm.ngx_shmtx_lock(&shpool.*.mutex);

    var p = &store.*.draining_head;
    while (p.*) |raw| {
        const sn = core.castPtr(Snapshot, raw) orelse break;
        const rc = @atomicLoad(c_ulong, &sn.*.refcount, .seq_cst);
        if (rc == 0) {
            p.* = sn.*.next_draining;
            free_snapshot_locked(shpool, sn);
        } else {
            p = &sn.*.next_draining;
        }
    }

    shm.ngx_shmtx_unlock(&shpool.*.mutex);
}

// ── Consul source adapter ─────────────────────────────────────────────────────

fn consul_build_path(
    pool: [*c]core.ngx_pool_t,
    service: ngx_str_t,
    tag: ngx_str_t,
    dc: ngx_str_t,
) ?ngx_str_t {
    const base = "/v1/health/service/";
    const passing = "?passing=true";
    const tag_prefix = "&tag=";
    const dc_prefix = "&dc=";
    const extra = tag.len + dc.len + tag_prefix.len + dc_prefix.len + 4;
    const est = base.len + service.len + passing.len + extra;
    const data = core.castPtr(u8, core.ngx_pnalloc(pool, est)) orelse return null;
    var pos: usize = 0;
    @memcpy(data[0..base.len], base);
    pos += base.len;
    @memcpy(data[pos..][0..service.len], core.slicify(u8, service.data, service.len));
    pos += service.len;
    @memcpy(data[pos..][0..passing.len], passing);
    pos += passing.len;
    if (tag.len > 0 and tag.data != null) {
        @memcpy(data[pos..][0..tag_prefix.len], tag_prefix);
        pos += tag_prefix.len;
        @memcpy(data[pos..][0..tag.len], core.slicify(u8, tag.data, tag.len));
        pos += tag.len;
    }
    if (dc.len > 0 and dc.data != null) {
        @memcpy(data[pos..][0..dc_prefix.len], dc_prefix);
        pos += dc_prefix.len;
        @memcpy(data[pos..][0..dc.len], core.slicify(u8, dc.data, dc.len));
        pos += dc.len;
    }
    data[pos] = 0;
    return ngx_str_t{ .data = data, .len = pos };
}

// Blocking HTTP/1.0 GET — only safe from timer context (worker 0 background).
// Returns the response body as a pool-allocated slice on HTTP 200.
fn consul_http_get(
    pool: [*c]core.ngx_pool_t,
    host: ngx_str_t,   // null-terminated IP
    port: u16,
    path: ngx_str_t,
    token: ngx_str_t,
    lg: [*c]ngx.log.ngx_log_t,
) !ngx_str_t {
    var addr: sockaddr_in = std.mem.zeroes(sockaddr_in);
    addr.sin_family = @intCast(AF_INET);
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, host.data, &addr.sin_addr) != 1) {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, lg, 0,
            "consul: invalid address %.*s\x00", .{ @as(c_int, @intCast(host.len)), host.data });
        return error.InvalidAddress;
    }

    const fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, lg, 0, "consul: socket() failed\x00", .{});
        return error.SocketFailed;
    }
    defer _ = close(fd);

    const tv = linux_timeval{ .tv_sec = 5, .tv_usec = 0 };
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, @sizeOf(linux_timeval));
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, @sizeOf(linux_timeval));

    if (connect(fd, &addr, @sizeOf(sockaddr_in)) != 0) {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, lg, 0,
            "consul: connect to %.*s:%d failed\x00",
            .{ @as(c_int, @intCast(host.len)), host.data, @as(c_int, port) });
        return error.ConnectFailed;
    }

    var req_buf: [1024]u8 = undefined;
    var req_len: usize = 0;

    // Use HTTP/1.0 to avoid chunked transfer encoding
    const req_line = std.fmt.bufPrint(
        req_buf[req_len..],
        "GET {s} HTTP/1.0\r\nHost: {s}\r\n",
        .{ core.slicify(u8, path.data, path.len), core.slicify(u8, host.data, host.len) },
    ) catch return error.RequestTooLarge;
    req_len += req_line.len;

    if (token.len > 0 and token.data != null) {
        const tok_line = std.fmt.bufPrint(req_buf[req_len..], "X-Consul-Token: {s}\r\n",
            .{core.slicify(u8, token.data, token.len)}) catch return error.RequestTooLarge;
        req_len += tok_line.len;
    }
    req_buf[req_len] = '\r'; req_len += 1;
    req_buf[req_len] = '\n'; req_len += 1;

    var sent: usize = 0;
    while (sent < req_len) {
        const n = send(fd, req_buf[sent..].ptr, req_len - sent, 0);
        if (n <= 0) {
            ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, lg, 0, "consul: send failed\x00", .{});
            return error.SendFailed;
        }
        sent += @intCast(n);
    }

    const rbuf = core.castPtr(u8, core.ngx_pnalloc(pool, CONSUL_RECV_BUF_SIZE)) orelse
        return error.OutOfMemory;
    var total: usize = 0;
    while (total < CONSUL_RECV_BUF_SIZE - 1) {
        const n = recv(fd, rbuf + total, CONSUL_RECV_BUF_SIZE - 1 - total, 0);
        if (n < 0) {
            ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, lg, 0, "consul: recv failed\x00", .{});
            return error.RecvFailed;
        }
        if (n == 0) break;
        total += @intCast(n);
    }

    const response = core.slicify(u8, rbuf, total);
    const sep = "\r\n\r\n";
    const hdr_end = std.mem.indexOf(u8, response, sep) orelse return error.InvalidResponse;

    const sp1 = std.mem.indexOfScalar(u8, response[0..@min(20, response.len)], ' ') orelse
        return error.InvalidResponse;
    if (sp1 + 4 > response.len) return error.InvalidResponse;
    const status = std.fmt.parseInt(u16, response[sp1 + 1 .. sp1 + 4], 10) catch
        return error.InvalidResponse;

    if (status != 200) {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, lg, 0,
            "consul: HTTP %d from %.*s\x00", .{ @as(c_int, status), @as(c_int, @intCast(host.len)), host.data });
        return error.BadStatus;
    }

    const body_off = hdr_end + sep.len;
    return ngx_str_t{ .data = rbuf + body_off, .len = total - body_off };
}

// Parse Consul health endpoint JSON and build a {"peers":[...]} JSON string.
fn consul_peers_json(
    pool: [*c]core.ngx_pool_t,
    consul_body: ngx_str_t,
    lg: [*c]ngx.log.ngx_log_t,
) ?ngx_str_t {
    var cj = CJSON.init(pool);
    const parsed = cj.decode(consul_body) catch {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, lg, 0,
            "consul: failed to parse health response JSON\x00", .{});
        return null;
    };
    // Pool-allocated; freed with pool at end of run_consul_refresh_entry.

    const n: usize = @intCast(@max(0, cjson.cJSON_GetArraySize(parsed)));
    const est = 20 + n * 64;
    const out = core.castPtr(u8, core.ngx_pnalloc(pool, est)) orelse return null;
    var pos: usize = 0;

    const pfx = "{\"peers\":[";
    @memcpy(out[0..pfx.len], pfx);
    pos += pfx.len;

    var it = CJSON.Iterator.init(parsed);
    var first = true;
    var count: usize = 0;

    while (it.next()) |entry| {
        if (count >= MAX_PEERS_PER_PUT) break;

        const svc_node = cjson.cJSON_GetObjectItem(entry, "Service");
        if (svc_node == core.nullptr(cjson.cJSON)) continue;

        // Prefer Service.Address, fall back to Node.Address
        var addr_str: ngx_str_t = ngx_null_str;
        const sa = cjson.cJSON_GetObjectItem(svc_node, "Address");
        if (sa != core.nullptr(cjson.cJSON)) {
            if (CJSON.stringValue(sa)) |s| {
                if (s.len > 0) addr_str = s;
            }
        }
        if (addr_str.len == 0) {
            const node_obj = cjson.cJSON_GetObjectItem(entry, "Node");
            if (node_obj != core.nullptr(cjson.cJSON)) {
                const na = cjson.cJSON_GetObjectItem(node_obj, "Address");
                if (na != core.nullptr(cjson.cJSON)) {
                    if (CJSON.stringValue(na)) |s| addr_str = s;
                }
            }
        }
        if (addr_str.len == 0) continue;

        const port_node = cjson.cJSON_GetObjectItem(svc_node, "Port");
        if (port_node == core.nullptr(cjson.cJSON)) continue;
        const port_val = CJSON.intValue(port_node) orelse continue;
        if (port_val <= 0 or port_val > 65535) continue;

        var peer_addr_buf: [64]u8 = undefined;
        const peer_addr = std.fmt.bufPrint(&peer_addr_buf, "{s}:{d}", .{
            core.slicify(u8, addr_str.data, addr_str.len), @as(u16, @intCast(port_val)),
        }) catch continue;

        // {"address":"...","weight":1} + comma = peer_addr.len + 24
        if (pos + peer_addr.len + 25 > est) break;

        if (!first) {
            out[pos] = ',';
            pos += 1;
        }
        first = false;
        count += 1;

        const ep = "{\"address\":\"";
        @memcpy(out[pos..][0..ep.len], ep);
        pos += ep.len;
        @memcpy(out[pos..][0..peer_addr.len], peer_addr);
        pos += peer_addr.len;
        const es = "\",\"weight\":1}";
        @memcpy(out[pos..][0..es.len], es);
        pos += es.len;
    }

    const sfx = "]}";
    @memcpy(out[pos..][0..sfx.len], sfx);
    pos += sfx.len;

    return ngx_str_t{ .data = out, .len = pos };
}

fn run_consul_refresh_entry(entry: *RefreshEntry, lg: [*c]ngx.log.ngx_log_t) void {
    const lccf = entry.lccf;
    if (lccf == core.nullptr(dynamic_upstreams_loc_conf)) return;
    if (lccf.*.target_uscf == core.nullptr(ngx_http_upstream_srv_conf_t)) return;

    const ducf = get_ducf(lccf.*.target_uscf) orelse return;
    if (ducf.*.managed == 0) return;

    if (lccf.*.consul_host.len == 0 or lccf.*.consul_host.data == null) {
        record_store_error(ducf, DU_ERROR_REFRESH_NOT_CONFIGURED);
        return;
    }
    if (lccf.*.consul_service.len == 0 or lccf.*.consul_service.data == null) {
        record_store_error(ducf, DU_ERROR_REFRESH_NOT_CONFIGURED);
        return;
    }

    const pool = core.ngx_create_pool(512 * 1024, lg);
    if (pool == core.nullptr(core.ngx_pool_t)) {
        record_store_error(ducf, DU_ERROR_ALLOCATION_FAILED);
        return;
    }
    defer core.ngx_destroy_pool(pool);

    const path = consul_build_path(pool, lccf.*.consul_service, lccf.*.consul_tag, lccf.*.consul_dc) orelse {
        record_store_error(ducf, DU_ERROR_ALLOCATION_FAILED);
        return;
    };

    const body = consul_http_get(
        pool, lccf.*.consul_host, @intCast(lccf.*.consul_port), path, lccf.*.consul_token, lg,
    ) catch {
        record_store_error(ducf, DU_ERROR_SOURCE_READ_FAILED);
        if (lccf.*.worker_events_channel.len > 0)
            publish_refresh_failed_event(lccf.*.worker_events_channel, lccf.*.target, lccf.*.source, DU_ERROR_SOURCE_READ_FAILED);
        return;
    };

    const peers_str = consul_peers_json(pool, body, lg) orelse {
        record_store_error(ducf, DU_ERROR_INVALID_JSON);
        if (lccf.*.worker_events_channel.len > 0)
            publish_refresh_failed_event(lccf.*.worker_events_channel, lccf.*.target, lccf.*.source, DU_ERROR_INVALID_JSON);
        return;
    };

    var cj = CJSON.init(pool);
    const json = cj.decode(peers_str) catch {
        record_store_error(ducf, DU_ERROR_INVALID_JSON);
        if (lccf.*.worker_events_channel.len > 0)
            publish_refresh_failed_event(lccf.*.worker_events_channel, lccf.*.target, lccf.*.source, DU_ERROR_INVALID_JSON);
        return;
    };

    _ = build_and_activate_snapshot(pool, ducf, lccf.*.target_uscf, lccf, json, true, true, false);
}

fn run_refresh_entry(entry: *RefreshEntry, lg: [*c]ngx.log.ngx_log_t) void {
    const lccf = entry.lccf;
    if (lccf == core.nullptr(dynamic_upstreams_loc_conf)) return;
    if (lccf.*.target_uscf == core.nullptr(ngx_http_upstream_srv_conf_t)) return;

    const ducf = get_ducf(lccf.*.target_uscf) orelse return;
    if (ducf.*.managed == 0) return;
    if (lccf.*.source_file.len == 0 or lccf.*.source_file.data == null) {
        record_store_error(ducf, DU_ERROR_REFRESH_NOT_CONFIGURED);
        return;
    }

    const pool = core.ngx_create_pool(16 * 1024, lg);
    if (pool == core.nullptr(core.ngx_pool_t)) {
        record_store_error(ducf, DU_ERROR_ALLOCATION_FAILED);
        return;
    }
    defer core.ngx_destroy_pool(pool);

    const body_str = file.ngz_open_file(lccf.*.source_file, lg, pool) catch {
        record_store_error(ducf, DU_ERROR_SOURCE_READ_FAILED);
        if (lccf.*.worker_events_channel.len > 0)
            publish_refresh_failed_event(lccf.*.worker_events_channel, lccf.*.target, lccf.*.source, DU_ERROR_SOURCE_READ_FAILED);
        return;
    };

    var cj = CJSON.init(pool);
    const json = cj.decode(body_str) catch {
        record_store_error(ducf, DU_ERROR_INVALID_JSON);
        if (lccf.*.worker_events_channel.len > 0)
            publish_refresh_failed_event(lccf.*.worker_events_channel, lccf.*.target, lccf.*.source, DU_ERROR_INVALID_JSON);
        return;
    };
    defer cj.free(json);

    _ = build_and_activate_snapshot(pool, ducf, lccf.*.target_uscf, lccf, json, true, false, false);
}

fn dynamic_upstreams_refresh_timer_handler(ev: [*c]core.ngx_event_t) callconv(.c) void {
    if (ev.*.flags.timer_set) {
        event.ngx_event_del_timer(ev);
    }
    const entry = core.castPtr(RefreshEntry, ev.*.data) orelse return;
    const lccf = entry.*.lccf;
    const use_consul = lccf != core.nullptr(dynamic_upstreams_loc_conf) and
        lccf.*.source.len == 6 and
        std.mem.eql(u8, core.slicify(u8, lccf.*.source.data, lccf.*.source.len), "consul");
    if (use_consul) {
        run_consul_refresh_entry(entry, ev.*.log);
    } else {
        run_refresh_entry(entry, ev.*.log);
    }
    const interval: ngx_msec_t = @intCast(entry.*.lccf.*.refresh_ms);
    event.ngx_event_add_timer(&entry.*.timer, interval);
}

fn preconfiguration(_: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    refresh_entry_count = 0;
    journal_entry_count = 0;
    managed_ducf_count = 0;
    return core.NGX_OK;
}

fn dynamic_upstreams_init_process(cycle: [*c]core.ngx_cycle_t) callconv(.c) ngx_int_t {
    if (ngx_worker != 0) return core.NGX_OK;

    // Restore from journal before first refresh timer fires (cold-start only)
    for (0..journal_entry_count) |i| {
        restore_from_journal(&journal_entries[i], cycle.*.log);
    }

    for (0..refresh_entry_count) |i| {
        const entry = &refresh_entries[i];
        if (entry.lccf == core.nullptr(dynamic_upstreams_loc_conf)) continue;
        if (entry.lccf.*.refresh_ms == 0) continue;

        entry.timer = std.mem.zeroes(core.ngx_event_t);
        entry.timer.handler = dynamic_upstreams_refresh_timer_handler;
        entry.timer.log = cycle.*.log;
        entry.timer.data = entry;
        entry.timer.flags.cancelable = true;
        const delay: ngx_msec_t = 50 + @as(ngx_msec_t, @intCast(i)) * 25;
        event.ngx_event_add_timer(&entry.timer, delay);
    }

    return core.NGX_OK;
}

fn dynamic_upstreams_exit_process(_: [*c]core.ngx_cycle_t) callconv(.c) void {
    for (0..refresh_entry_count) |i| {
        const entry = &refresh_entries[i];
        if (entry.timer.flags.timer_set) {
            event.ngx_event_del_timer(&entry.timer);
        }
        entry.timer = std.mem.zeroes(core.ngx_event_t);
    }
}

// ── Vtable: peer source for upstream-balancer ─────────────────────────────────

fn du_get_active_peers(
    source_ctx: ?*anyopaque,
    r: [*c]ngx_http_request_t,
    generation_out: *u64,
) callconv(.c) [*c]ngx_http_upstream_rr_peers_t {
    _ = r;
    const ducf = core.castPtr(DynamicUpstreamsSrvConf, source_ctx) orelse
        return core.nullptr(ngx_http_upstream_rr_peers_t);

    const store_cptr = ducf.*.store;
    if (store_cptr == core.nullptr(UpstreamStore)) return core.nullptr(ngx_http_upstream_rr_peers_t);
    // Cast away [*c] so that field-level atomic ops compile correctly.
    const store: *UpstreamStore = @alignCast(@ptrCast(store_cptr));

    // Lockless snapshot pinning:
    //   1. Load the active pointer atomically (.acquire pairs with the .release in activation).
    //   2. Speculatively increment the refcount.
    //   3. Re-read the active pointer — if it still matches, we hold a valid pin.
    //   4. If it changed, a concurrent PUT replaced the snapshot; release and retry.
    //
    // Safety: a snapshot is only freed by reap_draining (under the slab mutex).
    // The window between load and increment is a few instructions, making the
    // probability of a concurrent free-then-reuse cycle completing in that window
    // negligible. A future epoch-based reclamation phase can eliminate the
    // residual theoretical ABA risk.
    var tries: u32 = 0;
    while (tries < 4) : (tries += 1) {
        const active_int = @atomicLoad(usize, @as(*const usize, @ptrCast(&store.active)), .acquire);
        if (active_int == 0) return core.nullptr(ngx_http_upstream_rr_peers_t);
        const snap: *Snapshot = @ptrFromInt(active_int);
        _ = @atomicRmw(c_ulong, &snap.refcount, .Add, 1, .acquire);
        const active_now = @atomicLoad(usize, @as(*const usize, @ptrCast(&store.active)), .acquire);
        if (active_now == active_int) {
            generation_out.* = active_int;
            return snap.peers;
        }
        // Active pointer changed — release the speculative pin and retry.
        _ = @atomicRmw(c_ulong, &snap.refcount, .Sub, 1, .acq_rel);
    }
    return core.nullptr(ngx_http_upstream_rr_peers_t);
}

fn du_release_generation(
    source_ctx: ?*anyopaque,
    peers: [*c]ngx_http_upstream_rr_peers_t,
    generation: u64,
) callconv(.c) void {
    _ = peers;
    if (generation == 0) return;

    const snap: *Snapshot = @ptrFromInt(generation);
    const prev = @atomicRmw(c_ulong, &snap.refcount, .Sub, 1, .acq_rel);
    if (prev != 1) return; // not last reference — another holder will clean up

    if (snap.draining == 0) return; // still active — should not happen, but safe

    // We decremented the last reference on a draining snapshot.
    // Delegate the free to reap_draining (runs under the slab mutex) so that the
    // lockless reader in du_get_active_peers never races with a free.
    const ducf = core.castPtr(DynamicUpstreamsSrvConf, source_ctx) orelse return;
    const shpool = get_shpool(ducf.*.zone) orelse return;
    const store = ducf.*.store;
    if (store == core.nullptr(UpstreamStore)) return;
    reap_draining(store, shpool);
}

// ── Main request handler ──────────────────────────────────────────────────────

export fn ngx_http_dynamic_upstreams_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const method = r.*.method;
    if (method == http.NGX_HTTP_GET or method == http.NGX_HTTP_HEAD) {
        return handle_get(r);
    } else if (method == http.NGX_HTTP_PUT) {
        return handle_put(r);
    } else if (method == http.NGX_HTTP_PATCH) {
        return handle_patch(r);
    } else {
        _ = http.ngx_http_discard_request_body(r);
        return send_json_response(r, http.NGX_HTTP_NOT_ALLOWED,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"method not allowed\"}"));
    }
}

// ── Module wiring ─────────────────────────────────────────────────────────────

export const ngx_http_dynamic_upstreams_module_ctx = ngx_http_module_t{
    .preconfiguration = preconfiguration,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = create_srv_conf,
    .merge_srv_conf = merge_srv_conf,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_dynamic_upstreams_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_managed"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_NOARGS,
        .set = set_dynamic_upstreams_managed,
        .conf = 0,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_api"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = set_dynamic_upstreams_api,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_source"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = set_dynamic_upstreams_source,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_source_file"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = set_dynamic_upstreams_source_file,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_target"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = set_dynamic_upstreams_target,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_refresh"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = set_dynamic_upstreams_refresh,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_worker_events_channel"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = set_dynamic_upstreams_worker_events_channel,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_journal"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = set_dynamic_upstreams_journal,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_consul_address"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = set_dynamic_upstreams_consul_address,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_consul_service"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(dynamic_upstreams_loc_conf, "consul_service"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_consul_tag"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(dynamic_upstreams_loc_conf, "consul_tag"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_consul_token"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(dynamic_upstreams_loc_conf, "consul_token"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_consul_dc"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(dynamic_upstreams_loc_conf, "consul_dc"),
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_dynamic_upstreams_module = blk: {
    var m = ngx.module.make_module(
        @constCast(&ngx_http_dynamic_upstreams_commands),
        @constCast(&ngx_http_dynamic_upstreams_module_ctx),
    );
    m.init_process = dynamic_upstreams_init_process;
    m.exit_process = dynamic_upstreams_exit_process;
    break :blk m;
};

test "dynamic upstreams scaffold module" {}

test "json builder appends correctly" {
    const pool = core.ngx_create_pool(4096, core.ngx_log_init(core.c_str(""), core.c_str("")));
    defer core.ngx_destroy_pool(pool);
    var jb = JsonBuilder.init(pool, 128).?;
    const start = jb.w;
    jb.append("{\"n\":");
    jb.appendFmt("{d}", .{42});
    jb.append("}");
    const result = jb.str(start);
    try std.testing.expectEqual(@as(usize, 8), result.len);
    try std.testing.expectEqualSlices(u8, "{\"n\":42}", core.slicify(u8, result.data, result.len));
}
