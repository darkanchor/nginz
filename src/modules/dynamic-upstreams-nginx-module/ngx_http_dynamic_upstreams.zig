const std = @import("std");
const ngx = @import("ngx");

const conf = ngx.conf;
const core = ngx.core;
const http = ngx.http;
const shm = ngx.shm;
const buf = ngx.buf;

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

const ngx_string = ngx.string.ngx_string;
const ngx_null_str = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
const CJSON = ngx.cjson.CJSON;
const cjson = ngx.cjson;

extern var ngx_http_core_module: ngx_module_t;
extern var ngx_http_upstream_module: ngx_module_t;

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

const DU_ZONE_SIZE: usize = 4 * 1024 * 1024;

// ── Per-location config ─────────────────────────────────────────────────────

const dynamic_upstreams_loc_conf = extern struct {
    api_enabled: ngx_flag_t,
    source: ngx_str_t,
    target: ngx_str_t,
    refresh_ms: ngx_uint_t,
    target_uscf: [*c]ngx_http_upstream_srv_conf_t,
};

// ── Per-upstream config (stored in uscf->srv_conf) ─────────────────────────

const DynamicUpstreamsSrvConf = extern struct {
    managed: ngx_flag_t,
    zone: [*c]core.ngx_shm_zone_t,
    store: [*c]UpstreamStore,
};

// ── Shared-memory structures ─────────────────────────────────────────────────

// Control block — one per managed upstream, lives in the slab pool.
const UpstreamStore = extern struct {
    next_generation: u64,
    active: ?*anyopaque,         // *Snapshot, swapped atomically under shmtx
    draining_head: ?*anyopaque,  // *Snapshot linked list of draining snapshots
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
    lccf.*.target = ngx_null_str;
    lccf.*.refresh_ms = 0;
    lccf.*.target_uscf = core.nullptr(ngx_http_upstream_srv_conf_t);
    return lccf;
}

fn merge_loc_conf(cf: [*c]ngx_conf_t, parent: ?*anyopaque, child: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    const prev = core.castPtr(dynamic_upstreams_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(dynamic_upstreams_loc_conf, child) orelse return conf.NGX_CONF_OK;
    if (c.*.api_enabled == conf.NGX_CONF_UNSET) {
        c.*.api_enabled = if (prev.*.api_enabled == conf.NGX_CONF_UNSET) 0 else prev.*.api_enabled;
    }
    if (c.*.source.len == 0) c.*.source = prev.*.source;
    if (c.*.target.len == 0) c.*.target = prev.*.target;
    if (c.*.refresh_ms == 0) c.*.refresh_ms = prev.*.refresh_ms;
    if (c.*.target_uscf == core.nullptr(ngx_http_upstream_srv_conf_t)) {
        c.*.target_uscf = prev.*.target_uscf;
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
            if (!std.mem.eql(u8, val, "static")) {
                ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, cf.*.log, 0,
                    "dynamic_upstreams: only 'static' source is supported in this version\x00", .{});
                return conf.NGX_CONF_ERROR;
            }
            lccf.*.source = arg.*;
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
            lccf.*.refresh_ms = std.fmt.parseInt(ngx_uint_t, slice, 10) catch 0;
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
    const generation: u64 = if (active_snapshot) |sn| sn.*.generation else 0;

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
    const est: usize = 200 + target_name.len + peer_count * 80;
    var jb = JsonBuilder.init(r.*.pool, est) orelse return core.NGX_ERROR;
    const start = jb.w;

    jb.append("{\"module\":\"dynamic_upstreams\",\"target\":\"");
    jb.append(target_name);
    jb.append("\",\"writable\":");
    jb.append(if (managed) "true" else "false");
    jb.append(",\"generation\":");
    jb.appendFmt("{d}", .{generation});
    jb.append(",\"peer_count\":");
    jb.appendFmt("{d}", .{peer_count});
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
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"invalid JSON\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    };
    defer cj.free(json);

    // Validate: must have "peers" array
    const peers_node = cjson.cJSON_GetObjectItem(json, "peers");
    if (peers_node == core.nullptr(cjson.cJSON) or cjson.cJSON_IsArray(peers_node) != 1) {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"'peers' array required\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    const n_peers: usize = @intCast(@max(0, cjson.cJSON_GetArraySize(peers_node)));
    if (n_peers == 0) {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"at least one peer required\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }
    if (n_peers > MAX_PEERS_PER_PUT) {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"too many peers\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    // Parse and validate each peer, resolve addresses — all in r->pool
    // PeerSpec array on stack (small enough for our cap)
    var specs: [MAX_PEERS_PER_PUT]PeerSpec = undefined;
    var urls: [MAX_PEERS_PER_PUT]ngx_url_t = undefined;
    var addr_count: usize = 0;

    {
        var it = CJSON.Iterator.init(peers_node);
        while (it.next()) |item| {
            if (addr_count >= MAX_PEERS_PER_PUT) break;

            const addr_node = cjson.cJSON_GetObjectItem(item, "address");
            if (addr_node == core.nullptr(cjson.cJSON) or cjson.cJSON_IsString(addr_node) != 1) {
                _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
                    ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"peer missing 'address' string\"}"));
                http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
                return;
            }
            const addr_str = CJSON.stringValue(addr_node) orelse ngx_null_str;
            if (addr_str.len == 0) {
                _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
                    ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"peer address must not be empty\"}"));
                http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
                return;
            }

            var weight: ngx_int_t = 1;
            const w_node = cjson.cJSON_GetObjectItem(item, "weight");
            if (w_node != core.nullptr(cjson.cJSON) and cjson.cJSON_IsNumber(w_node) == 1) {
                const wf = cjson.cJSON_GetNumberValue(w_node);
                if (wf < 1 or wf > 65535) {
                    _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
                        ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"weight must be 1..65535\"}"));
                    http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
                    return;
                }
                weight = @intFromFloat(wf);
            }

            // Parse address: require IP:port, no DNS resolution
            urls[addr_count] = std.mem.zeroes(ngx_url_t);
            urls[addr_count].url = addr_str;
            urls[addr_count].flags.no_resolve = true;
            if (http.ngx_parse_url(r.*.pool, &urls[addr_count]) != core.NGX_OK or
                urls[addr_count].naddrs == 0)
            {
                _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
                    ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"invalid peer address (IP:port required)\"}"));
                http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
                return;
            }

            specs[addr_count] = PeerSpec{
                .addr_data = addr_str.data,
                .addr_len = addr_str.len,
                .weight = weight,
            };
            addr_count += 1;
        }
    }

    if (addr_count == 0) {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"no valid peers after parsing\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    // Build snapshot in slab (hold shpool->mutex for allocations + pointer swap)
    const shpool = get_shpool(ducf.*.zone) orelse {
        _ = send_json_response(r, http.NGX_HTTP_SERVICE_UNAVAILABLE,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"slab pool unavailable\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_SERVICE_UNAVAILABLE);
        return;
    };

    const store = ducf.*.store;
    if (store == core.nullptr(UpstreamStore)) {
        _ = send_json_response(r, http.NGX_HTTP_SERVICE_UNAVAILABLE,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"store unavailable\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_SERVICE_UNAVAILABLE);
        return;
    }

    shm.ngx_shmtx_lock(&shpool.*.mutex);

    const snapshot_mem = shm.ngx_slab_calloc_locked(shpool, @sizeOf(Snapshot)) orelse {
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
        _ = send_json_response(r, http.NGX_HTTP_SERVICE_UNAVAILABLE,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"slab allocation failed\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_SERVICE_UNAVAILABLE);
        return;
    };
    const new_snapshot = core.castPtr(Snapshot, snapshot_mem).?;

    const peers_mem = shm.ngx_slab_calloc_locked(shpool, @sizeOf(ngx_http_upstream_rr_peers_t)) orelse {
        shm.ngx_slab_free_locked(shpool, snapshot_mem);
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
        _ = send_json_response(r, http.NGX_HTTP_SERVICE_UNAVAILABLE,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"slab allocation failed\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_SERVICE_UNAVAILABLE);
        return;
    };
    const new_peers = core.castPtr(ngx_http_upstream_rr_peers_t, peers_mem).?;

    // Build the peer linked list in slab
    var total_weight: ngx_uint_t = 0;
    var peer_head: [*c]ngx_http_upstream_rr_peer_t = core.nullptr(ngx_http_upstream_rr_peer_t);
    var peer_tail: [*c]ngx_http_upstream_rr_peer_t = core.nullptr(ngx_http_upstream_rr_peer_t);
    var alloc_ok = true;
    var peer_idx: usize = 0;

    while (peer_idx < addr_count) : (peer_idx += 1) {
        const spec = &specs[peer_idx];
        const url = &urls[peer_idx];
        const addr = &url.addrs[0];

        const peer_mem = shm.ngx_slab_calloc_locked(shpool, @sizeOf(ngx_http_upstream_rr_peer_t)) orelse {
            alloc_ok = false;
            break;
        };
        const peer = core.castPtr(ngx_http_upstream_rr_peer_t, peer_mem).?;

        // Copy sockaddr to slab
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

        // Copy name string to slab
        const name_slab = dupSlabStr(shpool, addr.*.name.data, addr.*.name.len) orelse {
            shm.ngx_slab_free_locked(shpool, sa_mem);
            shm.ngx_slab_free_locked(shpool, peer_mem);
            alloc_ok = false;
            break;
        };
        peer.*.name = name_slab;

        // Also copy the "address:port" to server field
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
        peer.*.fail_timeout = 10; // 10 seconds default
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
        // Partial allocation: free what we built
        var p = peer_head;
        while (p != core.nullptr(ngx_http_upstream_rr_peer_t)) {
            const nx = p.*.next;
            if (p.*.sockaddr != null) shm.ngx_slab_free_locked(shpool, p.*.sockaddr);
            if (p.*.name.data != null) shm.ngx_slab_free_locked(shpool, p.*.name.data);
            if (p.*.server.data != null) shm.ngx_slab_free_locked(shpool, p.*.server.data);
            shm.ngx_slab_free_locked(shpool, p);
            p = nx;
        }
        shm.ngx_slab_free_locked(shpool, peers_mem);
        shm.ngx_slab_free_locked(shpool, snapshot_mem);
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
        _ = send_json_response(r, http.NGX_HTTP_SERVICE_UNAVAILABLE,
            ngx_string("{\"module\":\"dynamic_upstreams\",\"error\":\"slab allocation failed for peers\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_SERVICE_UNAVAILABLE);
        return;
    }

    // Check if any peer has non-unit weight so round-robin enables weighted selection.
    var any_weighted = false;
    {
        var pi: usize = 0;
        while (pi < addr_count) : (pi += 1) {
            if (specs[pi].weight != 1) { any_weighted = true; break; }
        }
    }

    // Populate peers struct
    new_peers.*.number = @intCast(addr_count);
    new_peers.*.total_weight = total_weight;
    new_peers.*.tries = @intCast(addr_count);
    new_peers.*.flags.single = (addr_count == 1);
    new_peers.*.flags.weighted = any_weighted;
    new_peers.*.peer = peer_head;
    new_peers.*.next = core.nullptr(ngx_http_upstream_rr_peers_t);
    new_peers.*.shpool = shpool; // enables rwlock in balancer peer selection

    // Populate snapshot
    const gen = store.*.next_generation;
    new_snapshot.*.generation = gen;
    new_snapshot.*.refcount = 0;
    new_snapshot.*.draining = 0;
    new_snapshot.*.peer_count = @intCast(addr_count);
    new_snapshot.*.peers = new_peers;
    new_snapshot.*.next_draining = null;

    // Atomically swap store->active
    const old_active = store.*.active;
    store.*.active = new_snapshot;
    store.*.next_generation = gen + 1;

    // Mark old snapshot as draining and push onto draining list
    if (old_active) |old_ptr| {
        if (core.castPtr(Snapshot, old_ptr)) |old_snap| {
            old_snap.*.draining = 1;
            old_snap.*.next_draining = store.*.draining_head;
            store.*.draining_head = old_snap;
        }
    }

    shm.ngx_shmtx_unlock(&shpool.*.mutex);

    // Try to reap zero-refcount draining snapshots
    reap_draining(store, shpool);

    // Send success response
    var resp_buf: [128]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf,
        "{{\"module\":\"dynamic_upstreams\",\"status\":\"ok\",\"generation\":{d},\"peer_count\":{d}}}",
        .{ gen, addr_count }) catch {
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

// ── Vtable: peer source for upstream-balancer ─────────────────────────────────

fn du_get_active_peers(
    source_ctx: ?*anyopaque,
    r: [*c]ngx_http_request_t,
    generation_out: *u64,
) callconv(.c) [*c]ngx_http_upstream_rr_peers_t {
    _ = r;
    const ducf = core.castPtr(DynamicUpstreamsSrvConf, source_ctx) orelse
        return core.nullptr(ngx_http_upstream_rr_peers_t);

    const store = ducf.*.store;
    if (store == core.nullptr(UpstreamStore)) return core.nullptr(ngx_http_upstream_rr_peers_t);

    const shpool = get_shpool(ducf.*.zone) orelse return core.nullptr(ngx_http_upstream_rr_peers_t);

    shm.ngx_shmtx_lock(&shpool.*.mutex);

    const snap_raw = store.*.active orelse {
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
        return core.nullptr(ngx_http_upstream_rr_peers_t);
    };
    const snap = core.castPtr(Snapshot, snap_raw) orelse {
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
        return core.nullptr(ngx_http_upstream_rr_peers_t);
    };

    // Pin snapshot for this request's lifetime
    _ = @atomicRmw(c_ulong, &snap.*.refcount, .Add, 1, .monotonic);
    generation_out.* = @intFromPtr(snap);

    shm.ngx_shmtx_unlock(&shpool.*.mutex);
    return snap.*.peers;
}

fn du_release_generation(
    source_ctx: ?*anyopaque,
    peers: [*c]ngx_http_upstream_rr_peers_t,
    generation: u64,
) callconv(.c) void {
    _ = peers;
    if (generation == 0) return;

    const snap: [*c]Snapshot = @ptrFromInt(generation);
    const prev = @atomicRmw(c_ulong, &snap.*.refcount, .Sub, 1, .acq_rel);
    if (prev != 1) return; // not last reference

    if (snap.*.draining == 0) return; // snapshot still active — should not happen, but safe

    // We are the last reference to a draining snapshot; free it under lock
    const ducf = core.castPtr(DynamicUpstreamsSrvConf, source_ctx) orelse return;
    const shpool = get_shpool(ducf.*.zone) orelse return;
    const store = ducf.*.store;
    if (store == core.nullptr(UpstreamStore)) return;

    shm.ngx_shmtx_lock(&shpool.*.mutex);

    // Remove from draining list
    var p = &store.*.draining_head;
    while (p.*) |raw| {
        const sn = core.castPtr(Snapshot, raw) orelse break;
        if (sn == snap) {
            p.* = sn.*.next_draining;
            break;
        }
        p = &sn.*.next_draining;
    }

    free_snapshot_locked(shpool, snap);
    shm.ngx_shmtx_unlock(&shpool.*.mutex);
}

// ── Main request handler ──────────────────────────────────────────────────────

export fn ngx_http_dynamic_upstreams_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const method = r.*.method;
    if (method == http.NGX_HTTP_GET or method == http.NGX_HTTP_HEAD) {
        return handle_get(r);
    } else if (method == http.NGX_HTTP_PUT) {
        return handle_put(r);
    } else {
        return http.NGX_HTTP_NOT_ALLOWED;
    }
}

// ── Module wiring ─────────────────────────────────────────────────────────────

export const ngx_http_dynamic_upstreams_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
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
    conf.ngx_null_command,
};

export var ngx_http_dynamic_upstreams_module = ngx.module.make_module(
    @constCast(&ngx_http_dynamic_upstreams_commands),
    @constCast(&ngx_http_dynamic_upstreams_module_ctx),
);

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
