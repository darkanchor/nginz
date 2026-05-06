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

// ── Shared metadata model — must match cache-tags exactly ─────────────────────

const MAX_TAGS: usize = 256;
const MAX_URIS_PER_TAG: usize = 64;
const MAX_TAG_LEN: usize = 64;
const MAX_URI_LEN: usize = 256;
const CACHE_TAGS_ZONE_SIZE: usize = 8 * 1024 * 1024;

const TagEntry = extern struct {
    tag: [MAX_TAG_LEN]u8,
    tag_len: usize,
    uris: [MAX_URIS_PER_TAG][MAX_URI_LEN]u8,
    uri_lens: [MAX_URIS_PER_TAG]usize,
    uri_count: usize,
};

const cache_tags_store = extern struct {
    initialized: ngx_flag_t,
    tag_count: usize,
    tags: [MAX_TAGS]TagEntry,
    tag_used: [MAX_TAGS]u8,
};

var ngx_http_cache_purge_tags_zone: [*c]core.ngx_shm_zone_t = core.nullptr(core.ngx_shm_zone_t);

fn get_tags_store() ?[*c]cache_tags_store {
    const zone = ngx_http_cache_purge_tags_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.data == null) return null;
    return core.castPtr(cache_tags_store, zone.*.data);
}

fn get_tags_shpool() ?[*c]core.ngx_slab_pool_t {
    const zone = ngx_http_cache_purge_tags_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.shm.addr == null or zone.*.data == null) return null;
    return core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr);
}

// ── Enums ─────────────────────────────────────────────────────────────────────

const MatchMode = enum(c_uint) {
    exact = 0,
    prefix = 1,
    glob = 2,
    unset = 255,
};

const AuthMode = enum(c_uint) {
    off = 0,
    allowlist = 1,
    signed_token = 2,
    unset = 255,
};

// ── Location config ───────────────────────────────────────────────────────────

const DEFAULT_MAX_KEYS: ngx_uint_t = 256;

const cache_purge_loc_conf = extern struct {
    api_enabled: ngx_flag_t,
    zone_name: ngx_str_t,
    match_mode: MatchMode,
    auth_mode: AuthMode,
    max_keys: ngx_uint_t,
};

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(cache_purge_loc_conf, cf.*.pool)) |p| {
        p.*.api_enabled = conf.NGX_CONF_UNSET;
        p.*.zone_name = ngx_null_str;
        p.*.match_mode = .unset;
        p.*.auth_mode = .unset;
        p.*.max_keys = 0;
        return p;
    }
    return null;
}

fn merge_loc_conf(cf: [*c]ngx_conf_t, parent: ?*anyopaque, child: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    const prev = core.castPtr(cache_purge_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(cache_purge_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.api_enabled == conf.NGX_CONF_UNSET) {
        c.*.api_enabled = if (prev.*.api_enabled == conf.NGX_CONF_UNSET) 0 else prev.*.api_enabled;
    }
    if (c.*.zone_name.len == 0) c.*.zone_name = prev.*.zone_name;
    if (c.*.max_keys == 0) {
        c.*.max_keys = if (prev.*.max_keys > 0) prev.*.max_keys else DEFAULT_MAX_KEYS;
    }
    if (c.*.match_mode == .unset) {
        c.*.match_mode = if (prev.*.match_mode == .unset) .exact else prev.*.match_mode;
    }
    if (c.*.auth_mode == .unset) {
        c.*.auth_mode = if (prev.*.auth_mode == .unset) .off else prev.*.auth_mode;
    }

    if (c.*.api_enabled == 1) {
        if (c.*.match_mode == .prefix) {
            return @constCast("cache_purge_match prefix is not yet implemented; use exact");
        }
        if (c.*.match_mode == .glob) {
            return @constCast("cache_purge_match glob is not yet implemented; use exact");
        }
        if (c.*.auth_mode == .allowlist) {
            return @constCast("cache_purge_authorize allowlist is not yet implemented; use off");
        }
        if (c.*.auth_mode == .signed_token) {
            return @constCast("cache_purge_authorize signed_token is not yet implemented; use off");
        }
    }

    return conf.NGX_CONF_OK;
}

// ── Tag helpers ───────────────────────────────────────────────────────────────

fn find_tag_idx(store: [*c]cache_tags_store, tag: []const u8) ?usize {
    for (&store[0].tags, 0..) |*entry, i| {
        if (store[0].tag_used[i] != @as(u8, 1)) continue;
        if (entry.tag_len != tag.len) continue;
        const entry_tag: []const u8 = @ptrCast(entry.tag[0..entry.tag_len]);
        if (std.mem.eql(u8, entry_tag, tag)) return i;
    }
    return null;
}

fn remove_tag_at(store: [*c]cache_tags_store, idx: usize) usize {
    for (&store[0].tags, 0..) |*entry, i| {
        if (i != idx) continue;
        const count = entry.uri_count;
        entry.* = std.mem.zeroes(TagEntry);
        store[0].tag_used[i] = @as(u8, 0);
        store.*.tag_count -= 1;
        return count;
    }
    return 0;
}

// ── JSON building helpers ─────────────────────────────────────────────────────

fn json_escape_len(src: []const u8) usize {
    var len: usize = 0;
    for (src) |c| {
        switch (c) {
            '"', '\\' => len += 2,
            '\n', '\r', '\t' => len += 2,
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
            '"' => { dst[pos] = '\\'; dst[pos + 1] = '"'; pos += 2; },
            '\\' => { dst[pos] = '\\'; dst[pos + 1] = '\\'; pos += 2; },
            '\n' => { dst[pos] = '\\'; dst[pos + 1] = 'n'; pos += 2; },
            '\r' => { dst[pos] = '\\'; dst[pos + 1] = 'r'; pos += 2; },
            '\t' => { dst[pos] = '\\'; dst[pos + 1] = 't'; pos += 2; },
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                const hex = "0123456789abcdef";
                dst[pos] = '\\'; dst[pos + 1] = 'u'; dst[pos + 2] = '0'; dst[pos + 3] = '0';
                dst[pos + 4] = hex[(c >> 4) & 0xF]; dst[pos + 5] = hex[c & 0xF];
                pos += 6;
            },
            else => { dst[pos] = c; pos += 1; },
        }
    }
    return pos;
}

fn write_usize_into(out: []u8, value: usize) usize {
    if (value == 0) { out[0] = '0'; return 1; }
    var v = value;
    var pos: usize = 0;
    var tmp: [20]u8 = undefined;
    while (v > 0) { tmp[pos] = @as(u8, @intCast((v % 10) + '0')); pos += 1; v /= 10; }
    for (0..pos) |i| out[i] = tmp[pos - 1 - i];
    return pos;
}

fn append(p: *[*]u8, end: [*]u8, s: []const u8) void {
    const rem = @intFromPtr(end) - @intFromPtr(p.*);
    const n = @min(s.len, rem);
    @memcpy(p.*[0..n], s[0..n]);
    p.* += n;
}

fn append_escaped(p: *[*]u8, end: [*]u8, s: []const u8) void {
    if (s.len == 0) return;
    const rem = @intFromPtr(end) - @intFromPtr(p.*);
    const esc_len = json_escape_len(s);
    if (esc_len > rem) return;
    const n = json_escape_into(p.*[0..rem], s);
    p.* += n;
}

fn append_usize(p: *[*]u8, end: [*]u8, value: usize) void {
    var tmp: [20]u8 = undefined;
    const n = write_usize_into(&tmp, value);
    append(p, end, tmp[0..n]);
}

// ── Response helper ───────────────────────────────────────────────────────────

fn send_json_response(r: [*c]ngx_http_request_t, status: ngx_uint_t, body: ngx_str_t) ngx_int_t {
    const content_type = ngx_string("application/json");
    r.*.headers_out.status = status;
    r.*.headers_out.content_type = content_type;
    r.*.headers_out.content_type_len = content_type.len;
    r.*.headers_out.content_length_n = @intCast(body.len);

    const header_rc = http.ngx_http_send_header(r);
    if (header_rc == NGX_ERROR or header_rc > NGX_OK) return header_rc;
    if (r.*.method == http.NGX_HTTP_HEAD) return NGX_OK;

    const out_buf = core.ngz_pcalloc_c(ngx_buf_t, r.*.pool) orelse return NGX_ERROR;
    out_buf.*.pos = body.data;
    out_buf.*.last = body.data + body.len;
    out_buf.*.flags.memory = true;
    out_buf.*.flags.last_buf = true;
    out_buf.*.flags.last_in_chain = true;

    const chain = core.ngz_pcalloc_c(ngx_chain_t, r.*.pool) orelse return NGX_ERROR;
    chain.*.buf = out_buf;
    chain.*.next = core.nullptr(ngx_chain_t);

    return http.ngx_http_output_filter(r, chain);
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

// ── Per-target result ─────────────────────────────────────────────────────────

const PurgeResult = extern struct {
    target: [MAX_TAG_LEN]u8,
    target_len: usize,
    purged: usize,
    found: ngx_flag_t,
};

// ── POST body handler ─────────────────────────────────────────────────────────

fn purge_body_handler(r: [*c]ngx_http_request_t) callconv(.c) void {
    const lccf = core.castPtr(
        cache_purge_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_cache_purge_module),
    ) orelse {
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };

    const has_body = r.*.request_body != core.nullptr(http.ngx_http_request_body_t) and
        r.*.request_body.*.bufs != core.nullptr(ngx_chain_t);
    if (!has_body) {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST, ngx_string("{\"module\":\"cache_purge\",\"status\":\"error\",\"error\":\"missing request body\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    const body_str = buf.ngz_chain_content(r.*.request_body.*.bufs, r.*.pool) catch {
        _ = send_json_response(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR, ngx_string("{\"module\":\"cache_purge\",\"status\":\"error\",\"error\":\"failed to read body\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };

    if (body_str.len == 0) {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST, ngx_string("{\"module\":\"cache_purge\",\"status\":\"error\",\"error\":\"empty request body\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    var cj = CJSON.init(r.*.pool);
    const json = cj.decode(body_str) catch {
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST, ngx_string("{\"module\":\"cache_purge\",\"status\":\"error\",\"error\":\"invalid JSON\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    };

    const targets_node = cjson.cJSON_GetObjectItem(json, "targets");
    if (targets_node == core.nullptr(cjson.cJSON) or cjson.cJSON_IsArray(targets_node) != 1) {
        cj.free(json);
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST, ngx_string("{\"module\":\"cache_purge\",\"status\":\"error\",\"error\":\"'targets' must be an array\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    const target_count_i = cjson.cJSON_GetArraySize(targets_node);
    if (target_count_i < 0) {
        cj.free(json);
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST, ngx_string("{\"module\":\"cache_purge\",\"status\":\"error\",\"error\":\"invalid targets array\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }
    const target_count: usize = @intCast(target_count_i);

    if (target_count > lccf.*.max_keys) {
        cj.free(json);
        _ = send_json_response(r, http.NGX_HTTP_BAD_REQUEST, ngx_string("{\"module\":\"cache_purge\",\"status\":\"error\",\"error\":\"too many targets: exceeds max_keys\"}"));
        http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
        return;
    }

    // Copy target strings to pool before freeing cjson
    var tag_bufs: ?[*c]ngx_str_t = null;
    if (target_count > 0) {
        tag_bufs = core.castPtr(ngx_str_t, core.ngx_pcalloc(r.*.pool, target_count * @sizeOf(ngx_str_t)));
        if (tag_bufs == null) {
            cj.free(json);
            http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
            return;
        }
        for (0..target_count) |i| {
            const item = cjson.cJSON_GetArrayItem(targets_node, @intCast(i));
            if (item == core.nullptr(cjson.cJSON) or cjson.cJSON_IsString(item) != 1) {
                tag_bufs.?[i] = ngx_null_str;
                continue;
            }
            const tv = CJSON.stringValue(item) orelse {
                tag_bufs.?[i] = ngx_null_str;
                continue;
            };
            if (tv.len == 0 or tv.data == null) {
                tag_bufs.?[i] = ngx_null_str;
                continue;
            }
            const len = @min(tv.len, MAX_TAG_LEN);
            const data = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, len)) orelse {
                tag_bufs.?[i] = ngx_null_str;
                continue;
            };
            @memcpy(core.slicify(u8, data, len), tv.data[0..len]);
            tag_bufs.?[i] = ngx_str_t{ .data = data, .len = len };
        }
    }
    cj.free(json);

    // Allocate result array
    var results: ?[*c]PurgeResult = null;
    if (target_count > 0) {
        results = core.castPtr(PurgeResult, core.ngx_pcalloc(r.*.pool, target_count * @sizeOf(PurgeResult)));
        if (results == null) {
            http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
            return;
        }
    }

    var total_purged: usize = 0;
    var total_missing: usize = 0;

    if (target_count > 0) {
        const store = get_tags_store();
        const store_shpool = get_tags_shpool();

        if (store != null and store_shpool != null) {
            shm.ngx_shmtx_lock(&store_shpool.?.*.mutex);
            for (0..target_count) |i| {
                const tag_str = tag_bufs.?[i];
                if (tag_str.len == 0 or tag_str.data == null) {
                    results.?[i].target_len = 0;
                    results.?[i].found = 0;
                    total_missing += 1;
                    continue;
                }
                const tag = core.slicify(u8, tag_str.data, tag_str.len);
                const len = @min(tag.len, MAX_TAG_LEN);
                @memcpy(results.?[i].target[0..len], tag[0..len]);
                results.?[i].target_len = len;

                if (find_tag_idx(store.?, tag[0..len])) |idx| {
                    results.?[i].purged = remove_tag_at(store.?, idx);
                    results.?[i].found = 1;
                    total_purged += results.?[i].purged;
                } else {
                    results.?[i].purged = 0;
                    results.?[i].found = 0;
                    total_missing += 1;
                }
            }
            shm.ngx_shmtx_unlock(&store_shpool.?.*.mutex);
        } else {
            // Zone not initialized — report all as missing
            for (0..target_count) |i| {
                const tag_str = tag_bufs.?[i];
                if (tag_str.len > 0 and tag_str.data != null) {
                    const len = @min(tag_str.len, MAX_TAG_LEN);
                    @memcpy(results.?[i].target[0..len], core.slicify(u8, tag_str.data, len));
                    results.?[i].target_len = len;
                }
                results.?[i].purged = 0;
                results.?[i].found = 0;
            }
            total_missing = target_count;
        }
    }

    // Build JSON response outside shm lock
    const est_size: usize = target_count * 200 + 256;
    const resp_raw = core.ngx_pnalloc(r.*.pool, est_size) orelse {
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };
    const resp_mem: [*c]u8 = @ptrCast(@alignCast(resp_raw));
    var w: [*]u8 = resp_mem;
    const w_end = w + est_size;

    append(&w, w_end, "{\"module\":\"cache_purge\",\"zone\":\"");
    if (lccf.*.zone_name.len > 0 and lccf.*.zone_name.data != null) {
        append_escaped(&w, w_end, core.slicify(u8, lccf.*.zone_name.data, lccf.*.zone_name.len));
    }
    append(&w, w_end, "\",\"match\":\"exact\",\"requested\":");
    append_usize(&w, w_end, target_count);
    append(&w, w_end, ",\"purged\":");
    append_usize(&w, w_end, total_purged);
    append(&w, w_end, ",\"missing\":");
    append_usize(&w, w_end, total_missing);
    append(&w, w_end, ",\"rejected\":0,\"results\":[");
    for (0..target_count) |i| {
        if (i > 0) append(&w, w_end, ",");
        const result = results.?[i];
        append(&w, w_end, "{\"target\":\"");
        const tgt: []const u8 = @ptrCast(result.target[0..result.target_len]);
        append_escaped(&w, w_end, tgt);
        append(&w, w_end, "\",\"purged\":");
        append_usize(&w, w_end, result.purged);
        append(&w, w_end, "}");
    }
    append(&w, w_end, "]}");

    const resp_body = ngx_str_t{
        .data = resp_mem,
        .len = @intCast(@intFromPtr(w) - @intFromPtr(resp_mem)),
    };
    _ = send_json_response(r, http.NGX_HTTP_OK, resp_body);
    http.ngx_http_finalize_request(r, NGX_OK);
}

// ── POST entry point ──────────────────────────────────────────────────────────

fn handle_purge(r: [*c]ngx_http_request_t) ngx_int_t {
    if (!is_json_content_type(r)) {
        return send_json_response(r, 415, ngx_string("{\"module\":\"cache_purge\",\"status\":\"error\",\"error\":\"content-type must be application/json\"}"));
    }
    const rc = http.ngx_http_read_client_request_body(r, purge_body_handler);
    if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) return rc;
    return core.NGX_DONE;
}

// ── Main handler ──────────────────────────────────────────────────────────────

export fn ngx_http_cache_purge_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    if (r.*.method == http.NGX_HTTP_POST) return handle_purge(r);
    return send_json_response(r, http.NGX_HTTP_NOT_ALLOWED, ngx_string("{\"module\":\"cache_purge\",\"status\":\"error\",\"error\":\"method not allowed; use POST\"}"));
}

// ── Directive handlers ────────────────────────────────────────────────────────

fn ngx_conf_set_cache_purge_api(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(cache_purge_loc_conf, loc)) |lccf| {
        lccf.*.api_enabled = 1;
        const clcf = core.castPtr(
            http.ngx_http_core_loc_conf_t,
            conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
        ) orelse return conf.NGX_CONF_OK;
        clcf.*.handler = ngx_http_cache_purge_handler;
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_cache_purge_zone(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(cache_purge_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            lccf.*.zone_name = arg.*;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_cache_purge_match(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(cache_purge_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const slice = core.slicify(u8, arg.*.data, arg.*.len);
            if (std.mem.eql(u8, slice, "exact")) {
                lccf.*.match_mode = .exact;
            } else if (std.mem.eql(u8, slice, "prefix")) {
                lccf.*.match_mode = .prefix;
            } else if (std.mem.eql(u8, slice, "glob")) {
                lccf.*.match_mode = .glob;
            } else {
                return @constCast("cache_purge_match: valid values are exact, prefix, glob");
            }
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_cache_purge_authorize(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(cache_purge_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const slice = core.slicify(u8, arg.*.data, arg.*.len);
            if (std.mem.eql(u8, slice, "off")) {
                lccf.*.auth_mode = .off;
            } else if (std.mem.eql(u8, slice, "allowlist")) {
                lccf.*.auth_mode = .allowlist;
            } else if (std.mem.eql(u8, slice, "signed-token") or std.mem.eql(u8, slice, "signed_token")) {
                lccf.*.auth_mode = .signed_token;
            } else {
                return @constCast("cache_purge_authorize: valid values are off, allowlist, signed-token");
            }
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_cache_purge_max_keys(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(cache_purge_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const slice = core.slicify(u8, arg.*.data, arg.*.len);
            const parsed = std.fmt.parseInt(ngx_uint_t, slice, 10) catch {
                return @constCast("cache_purge_max_keys: must be a positive integer");
            };
            if (parsed == 0) {
                return @constCast("cache_purge_max_keys: must be greater than 0");
            }
            lccf.*.max_keys = parsed;
        }
    }
    return conf.NGX_CONF_OK;
}

// ── Postconfiguration ─────────────────────────────────────────────────────────

fn zone_init_noop(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) zone.*.data = data;
    return NGX_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    // Skip in unit-test builds where cache-tags is not linked
    if (comptime @import("builtin").is_test) return NGX_OK;
    return postconfiguration_impl(cf);
}

fn postconfiguration_impl(cf: [*c]ngx_conf_t) ngx_int_t {
    // cache-tags module pointer — same tag used for zone ownership
    const cache_tags_tag = @extern(?*anyopaque, .{
        .name = "ngx_http_cache_tags_filter_module",
        .linkage = .weak,
    });
    if (cache_tags_tag == null) return NGX_OK;

    var zone_name = ngx_string("cache_tags_zone");
    const zone = shm.ngx_shared_memory_add(cf, &zone_name, CACHE_TAGS_ZONE_SIZE, cache_tags_tag);
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return NGX_OK;
    if (zone.*.init == null) zone.*.init = zone_init_noop;
    ngx_http_cache_purge_tags_zone = zone;
    return NGX_OK;
}

// ── Module exports ────────────────────────────────────────────────────────────

export const ngx_http_cache_purge_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_cache_purge_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("cache_purge_api"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_cache_purge_api,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("cache_purge_zone"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_cache_purge_zone,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("cache_purge_match"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_cache_purge_match,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("cache_purge_authorize"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_cache_purge_authorize,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("cache_purge_max_keys"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_cache_purge_max_keys,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_cache_purge_module = ngx.module.make_module(
    @constCast(&ngx_http_cache_purge_commands),
    @constCast(&ngx_http_cache_purge_module_ctx),
);

test "cache purge module" {}
