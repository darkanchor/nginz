const std = @import("std");
const ngx = @import("ngx");

const buf = ngx.buf;
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
const ngx_buf_t = buf.ngx_buf_t;
const ngx_chain_t = buf.ngx_chain_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;

const ngx_string = ngx.string.ngx_string;

extern var ngx_http_core_module: ngx_module_t;

// Configuration
const cache_tags_main_conf = extern struct {
    tag_header: ngx_str_t,
};

const cache_tags_loc_conf = extern struct {
    enabled: ngx_flag_t,
    purge_enabled: ngx_flag_t,
};

const cache_tags_ctx = extern struct {
    last_purged: ngx_uint_t,
    last_tag: ngx_str_t,
    last_error: ngx_str_t,
    purge_recorded: ngx_flag_t,
    tag_recorded: ngx_flag_t,
    error_recorded: ngx_flag_t,
};

const CACHE_TAGS_ZONE_SIZE: usize = 8 * 1024 * 1024;

// Per-worker storage for tag → URI mappings
// Simple implementation: fixed arrays for demo purposes
const MAX_TAGS = 256;
const MAX_URIS_PER_TAG = 64;
const MAX_TAG_LEN = 64;
const MAX_URI_LEN = 256;

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

var ngx_http_cache_tags_zone: [*c]core.ngx_shm_zone_t = core.nullptr(core.ngx_shm_zone_t);

// Default header name
const default_tag_header = ngx_string("Cache-Tag");

const ngx_http_variable_value_t = http.ngx_http_variable_value_t;

const CACHE_TAGS_VAR_LAST_PURGED: core.uintptr_t = 0;
const CACHE_TAGS_VAR_LAST_TAG: core.uintptr_t = 1;
const CACHE_TAGS_VAR_LAST_ERROR: core.uintptr_t = 2;

fn getTagStore() ?[*c]cache_tags_store {
    if (ngx_http_cache_tags_zone == core.nullptr(core.ngx_shm_zone_t)) return null;
    return core.castPtr(cache_tags_store, ngx_http_cache_tags_zone.*.data);
}

fn getTagShpool() ?[*c]core.ngx_slab_pool_t {
    const zone = ngx_http_cache_tags_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.shm.addr == null or zone.*.data == null) {
        return null;
    }
    return core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr);
}

fn setCtx(r: [*c]ngx_http_request_t) ?*cache_tags_ctx {
    if (core.castPtr(cache_tags_ctx, r.*.ctx[ngx_http_cache_tags_filter_module.ctx_index])) |existing| {
        return existing;
    }

    const ctx = core.ngz_pcalloc_c(cache_tags_ctx, r.*.pool) orelse return null;
    r.*.ctx[ngx_http_cache_tags_filter_module.ctx_index] = ctx;
    return ctx;
}

fn setCtxTag(r: [*c]ngx_http_request_t, tag: []const u8) void {
    const ctx = setCtx(r) orelse return;
    const data = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, tag.len)) orelse return;
    @memcpy(core.slicify(u8, data, tag.len), tag);
    ctx.*.last_tag = ngx_str_t{ .data = data, .len = tag.len };
    ctx.*.tag_recorded = 1;
}

fn setCtxError(r: [*c]ngx_http_request_t, err_text: []const u8) void {
    const ctx = setCtx(r) orelse return;
    const data = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, err_text.len)) orelse return;
    @memcpy(core.slicify(u8, data, err_text.len), err_text);
    ctx.*.last_error = ngx_str_t{ .data = data, .len = err_text.len };
    ctx.*.error_recorded = 1;
}

fn setCtxPurgeResult(r: [*c]ngx_http_request_t, tag: []const u8, purged: usize) void {
    const ctx = setCtx(r) orelse return;
    setCtxTag(r, tag);
    ctx.*.last_purged = @intCast(purged);
    ctx.*.purge_recorded = 1;
}

fn ngx_http_cache_tags_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    const ctx = core.castPtr(cache_tags_ctx, r.*.ctx[ngx_http_cache_tags_filter_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };

    switch (data) {
        CACHE_TAGS_VAR_LAST_PURGED => {
            if (ctx.*.purge_recorded != 1) {
                v.*.flags.not_found = true;
                return NGX_OK;
            }
            var num_buf: [24]u8 = undefined;
            const slice = std.fmt.bufPrint(&num_buf, "{d}", .{ctx.*.last_purged}) catch {
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
        CACHE_TAGS_VAR_LAST_TAG => {
            if (ctx.*.tag_recorded != 1 or ctx.*.last_tag.data == null) {
                v.*.flags.not_found = true;
                return NGX_OK;
            }
            v.*.data = ctx.*.last_tag.data;
            v.*.flags.len = @intCast(ctx.*.last_tag.len);
        },
        CACHE_TAGS_VAR_LAST_ERROR => {
            if (ctx.*.error_recorded != 1 or ctx.*.last_error.data == null) {
                v.*.flags.not_found = true;
                return NGX_OK;
            }
            v.*.data = ctx.*.last_error.data;
            v.*.flags.len = @intCast(ctx.*.last_error.len);
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

fn ngx_http_cache_tags_zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        zone.*.data = data;
        return NGX_OK;
    }

    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        zone.*.data = shpool.*.data;
        return NGX_OK;
    }

    const store_mem = shm.ngx_slab_calloc(shpool, @sizeOf(cache_tags_store)) orelse return NGX_ERROR;
    const store = core.castPtr(cache_tags_store, store_mem) orelse return NGX_ERROR;
    store.* = std.mem.zeroes(cache_tags_store);
    store.*.initialized = 1;
    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

// Find or create a tag entry
fn findOrCreateTag(store: [*c]cache_tags_store, tag: []const u8) ?*TagEntry {
    if (tag.len == 0 or tag.len > MAX_TAG_LEN) return null;
    if (store.*.tag_count == 0) {
        if (store.*.tag_count >= MAX_TAGS) return null;
        for (&store[0].tags, 0..) |*entry, i| {
            if (store[0].tag_used[i] != @as(u8, 0)) continue;
            const len = tag.len;
            entry.tag_len = len;
            entry.uri_count = 0;
            @memcpy(entry.tag[0..len], tag[0..len]);
            store[0].tag_used[i] = @as(u8, 1);
            store.*.tag_count += 1;
            return entry;
        }
        return null;
    }

    // First, look for existing tag
    var active_seen: usize = 0;
    for (&store[0].tags, 0..) |*entry, i| {
        if (store[0].tag_used[i] != @as(u8, 1)) continue;
        active_seen += 1;
        const entry_tag: []const u8 = @ptrCast(entry.tag[0..entry.tag_len]);
        if (entry.tag_len == tag.len and std.mem.eql(u8, entry_tag, tag)) return entry;
        if (active_seen == store.*.tag_count) break;
    }

    // Create new tag entry
    if (store.*.tag_count >= MAX_TAGS) return null;

    for (&store[0].tags, 0..) |*entry, i| {
        if (store[0].tag_used[i] != @as(u8, 0)) continue;
        const len = tag.len;
        entry.tag_len = len;
        entry.uri_count = 0;
        @memcpy(entry.tag[0..len], tag[0..len]);
        store[0].tag_used[i] = @as(u8, 1);
        store.*.tag_count += 1;
        return entry;
    }
    return null;
}

// Find a tag entry (read-only)
fn findTag(store: [*c]cache_tags_store, tag: []const u8) ?*TagEntry {
    if (store.*.tag_count == 0) return null;
    var active_seen: usize = 0;
    for (&store[0].tags, 0..) |*entry, i| {
        if (store[0].tag_used[i] != @as(u8, 1)) continue;
        active_seen += 1;
        const entry_tag: []const u8 = @ptrCast(entry.tag[0..entry.tag_len]);
        if (entry.tag_len == tag.len and std.mem.eql(u8, entry_tag, tag)) return entry;
        if (active_seen == store.*.tag_count) break;
    }
    return null;
}

// Add a URI to a tag
fn addUriToTag(tag_entry: *TagEntry, uri: []const u8) bool {
    if (uri.len == 0 or uri.len > MAX_URI_LEN or tag_entry.uri_count >= MAX_URIS_PER_TAG) return false;

    // Check if URI already exists
    for (0..tag_entry.uri_count) |i| {
        if (tag_entry.uri_lens[i] == uri.len and
            std.mem.eql(u8, tag_entry.uris[i][0..tag_entry.uri_lens[i]], uri))
        {
            return true; // Already exists
        }
    }

    const len = uri.len;
    @memcpy(tag_entry.uris[tag_entry.uri_count][0..len], uri[0..len]);
    tag_entry.uri_lens[tag_entry.uri_count] = len;
    tag_entry.uri_count += 1;
    return true;
}

// Parse comma-separated tags and associate with URI
fn associateTagsWithUri(store: [*c]cache_tags_store, tags_str: []const u8, uri: []const u8) bool {
    if (uri.len == 0 or uri.len > MAX_URI_LEN) return false;
    var complete = true;
    var start: usize = 0;
    for (tags_str, 0..) |c, i| {
        if (c == ',') {
            const tag = std.mem.trim(u8, tags_str[start..i], " \t");
            if (tag.len > 0) {
                if (findOrCreateTag(store, tag)) |entry| {
                    if (!addUriToTag(entry, uri)) complete = false;
                } else complete = false;
            }
            start = i + 1;
        }
    }
    // Handle last tag
    const tag = std.mem.trim(u8, tags_str[start..], " \t");
    if (tag.len > 0) {
        if (findOrCreateTag(store, tag)) |entry| {
            if (!addUriToTag(entry, uri)) complete = false;
        } else complete = false;
    }
    return complete;
}

// Purge all URIs associated with a tag, returns count
fn purgeByTag(store: [*c]cache_tags_store, tag: []const u8) usize {
    if (store.*.tag_count == 0) return 0;
    var active_seen: usize = 0;
    for (&store[0].tags, 0..) |*entry, i| {
        if (store[0].tag_used[i] != @as(u8, 1)) continue;
        active_seen += 1;
        const entry_tag: []const u8 = @ptrCast(entry.tag[0..entry.tag_len]);
        if (entry.tag_len == tag.len and std.mem.eql(u8, entry_tag, tag)) {
            const count = entry.uri_count;
            store[0].tag_used[i] = @as(u8, 0);
            store.*.tag_count -= 1;
            return count;
        }
        if (active_seen == store.*.tag_count) break;
    }
    return 0;
}

// Get header value by name from response headers
fn getResponseHeader(r: [*c]ngx_http_request_t, header_name: ngx_str_t) ?[]const u8 {
    const name_slice = core.slicify(u8, header_name.data, header_name.len);

    // Use NList to iterate over response headers
    var headers = ngx.list.NList(ngx.hash.ngx_table_elt_t).init0(&r.*.headers_out.headers);
    var it = headers.iterator();
    while (it.next()) |h| {
        const key_slice = core.slicify(u8, h.*.key.data, h.*.key.len);
        if (std.ascii.eqlIgnoreCase(key_slice, name_slice)) {
            return core.slicify(u8, h.*.value.data, h.*.value.len);
        }
    }
    return null;
}

// Header filter to capture Cache-Tag header
var ngx_http_cache_tags_next_header_filter: http.ngx_http_output_header_filter_pt = null;

export fn ngx_http_cache_tags_header_filter(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        cache_tags_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_cache_tags_filter_module),
    );

    if (lccf == null or lccf.?.*.enabled != 1) {
        if (ngx_http_cache_tags_next_header_filter) |next| {
            return next(r);
        }
        return NGX_OK;
    }

    // Get main conf for header name
    const mcf = core.castPtr(
        cache_tags_main_conf,
        conf.ngx_http_get_module_main_conf(r, &ngx_http_cache_tags_filter_module),
    );

    const header_name = if (mcf != null and mcf.?.*.tag_header.len > 0)
        mcf.?.*.tag_header
    else
        default_tag_header;

    // Get URI for this request
    const uri = core.slicify(u8, r.*.uri.data, r.*.uri.len);

    // Look for Cache-Tag header in response
    if (getResponseHeader(r, header_name)) |tags_value| {
        if (getTagStore()) |store| {
            if (getTagShpool()) |shpool| {
                shm.ngx_shmtx_lock(&shpool.*.mutex);
                const complete = associateTagsWithUri(store, tags_value, uri);
                shm.ngx_shmtx_unlock(&shpool.*.mutex);
                if (!complete) {
                    ngx.log.ngz_log_error(ngx.log.NGX_LOG_WARN, r.*.connection.*.log, 0,
                        "cache_tags: tag/URI rejected due to bounds or shared-store capacity", .{});
                }
            }
        }
    }

    if (ngx_http_cache_tags_next_header_filter) |next| {
        return next(r);
    }
    return NGX_OK;
}

// Content handler for purge endpoint
export fn ngx_http_cache_tags_purge_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    // Only allow PURGE or DELETE methods
    if (r.*.method != http.NGX_HTTP_DELETE and r.*.method != http.NGX_HTTP_GET) {
        setCtxError(r, "method_not_allowed");
        return http.NGX_HTTP_NOT_ALLOWED;
    }

    // Get tag from query string: ?tag=mytag
    var tag_to_purge: ?[]const u8 = null;

    if (r.*.args.len > 0) {
        const args = core.slicify(u8, r.*.args.data, r.*.args.len);
        if (std.mem.indexOf(u8, args, "tag=")) |idx| {
            const start = idx + 4;
            var end = start;
            while (end < args.len and args[end] != '&') : (end += 1) {}
            if (end > start) {
                tag_to_purge = args[start..end];
            }
        }
    }

    // Build response
    var response_buf: [1024]u8 = undefined;
    var response_len: usize = 0;

    const store = getTagStore() orelse return NGX_ERROR;
    const shpool = getTagShpool() orelse return NGX_ERROR;

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.*.mutex);

    if (tag_to_purge) |tag| {
        const purged = purgeByTag(store, tag);
        setCtxPurgeResult(r, tag, purged);
        const result = std.fmt.bufPrint(&response_buf, "{{\"tag\":\"{s}\",\"purged\":{d}}}\n", .{ tag, purged }) catch {
            return NGX_ERROR;
        };
        response_len = result.len;
    } else {
        // List all tags
        var written: usize = 0;
        written += (std.fmt.bufPrint(response_buf[written..], "{{\"tags\":[", .{}) catch return NGX_ERROR).len;

        var first = true;
        for (&store[0].tags, 0..) |*entry, i| {
            if (store[0].tag_used[i] == @as(u8, 1)) {
                const entry_tag: []const u8 = @ptrCast(entry.tag[0..entry.tag_len]);
                if (!first) {
                    written += (std.fmt.bufPrint(response_buf[written..], ",", .{}) catch return NGX_ERROR).len;
                }
                written += (std.fmt.bufPrint(response_buf[written..], "{{\"tag\":\"{s}\",\"uris\":{d}}}", .{
                    entry_tag,
                    entry.uri_count,
                }) catch return NGX_ERROR).len;
                first = false;
            }
        }
        written += (std.fmt.bufPrint(response_buf[written..], "]}}\n", .{}) catch return NGX_ERROR).len;
        response_len = written;
    }

    // Set response headers
    const content_type = ngx_string("application/json");
    r.*.headers_out.content_type = content_type;
    r.*.headers_out.content_type_len = content_type.len;
    r.*.headers_out.status = 200;
    r.*.headers_out.content_length_n = @intCast(response_len);

    // Send headers
    const rc = http.ngx_http_send_header(r);
    if (rc == NGX_ERROR or rc > NGX_OK) {
        return rc;
    }
    if (r.*.method == http.NGX_HTTP_HEAD or r.*.flags1.header_only) {
        return NGX_OK;
    }

    // Allocate and send body
    const b = core.castPtr(ngx_buf_t, core.ngx_pcalloc(r.*.pool, @sizeOf(ngx_buf_t))) orelse return NGX_ERROR;
    const data = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, response_len)) orelse return NGX_ERROR;

    @memcpy(core.slicify(u8, data, response_len), response_buf[0..response_len]);

    b.*.pos = data;
    b.*.last = data + response_len;
    b.*.flags.memory = true;
    b.*.flags.last_buf = (r == r.*.main);
    b.*.flags.last_in_chain = true;

    var out: ngx_chain_t = undefined;
    out.buf = b;
    out.next = null;

    return http.ngx_http_output_filter(r, &out);
}

fn create_main_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(cache_tags_main_conf, cf.*.pool)) |p| {
        p.*.tag_header = ngx_str_t{ .len = 0, .data = null };
        return p;
    }
    return null;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(cache_tags_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = 0;
        p.*.purge_enabled = 0;
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
    const prev = core.castPtr(cache_tags_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(cache_tags_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.enabled == 0) {
        c.*.enabled = prev.*.enabled;
    }
    if (c.*.purge_enabled == 0) {
        c.*.purge_enabled = prev.*.purge_enabled;
    }

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_cache_tags(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cf;
    _ = cmd;
    if (core.castPtr(cache_tags_loc_conf, loc)) |lccf| {
        lccf.*.enabled = 1;
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_cache_tags_purge(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(cache_tags_loc_conf, loc)) |lccf| {
        lccf.*.purge_enabled = 1;

        // Register content handler for purge endpoint
        const clcf = core.castPtr(
            http.ngx_http_core_loc_conf_t,
            conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
        ) orelse return conf.NGX_CONF_OK;

        clcf.*.handler = ngx_http_cache_tags_purge_handler;
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_cache_tags_header(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    mc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(cache_tags_main_conf, mc)) |mcf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            mcf.*.tag_header = arg.*;
        }
    }
    return conf.NGX_CONF_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    var zone_name = ngx_string("cache_tags_zone");
    const zone = shm.ngx_shared_memory_add(cf, &zone_name, CACHE_TAGS_ZONE_SIZE, @constCast(&ngx_http_cache_tags_filter_module));
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return NGX_ERROR;
    zone.*.init = ngx_http_cache_tags_zone_init;
    ngx_http_cache_tags_zone = zone;

    var vs = [_]http.ngx_http_variable_t{
        http.ngx_http_variable_t{ .name = ngx_string("cache_tags_last_purged"), .set_handler = null, .get_handler = ngx_http_cache_tags_variable, .data = CACHE_TAGS_VAR_LAST_PURGED, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("cache_tags_last_tag"), .set_handler = null, .get_handler = ngx_http_cache_tags_variable, .data = CACHE_TAGS_VAR_LAST_TAG, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("cache_tags_last_error"), .set_handler = null, .get_handler = ngx_http_cache_tags_variable, .data = CACHE_TAGS_VAR_LAST_ERROR, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
    };
    for (&vs) |*v| {
        if (http.ngx_http_add_variable(cf, &v.name, v.flags)) |x| {
            x.*.get_handler = v.get_handler;
            x.*.data = v.data;
        }
    }

    // Install header filter
    ngx_http_cache_tags_next_header_filter = http.ngx_http_top_header_filter;
    http.ngx_http_top_header_filter = ngx_http_cache_tags_header_filter;
    return NGX_OK;
}

export const ngx_http_cache_tags_filter_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = create_main_conf,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_cache_tags_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("cache_tags"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_cache_tags,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("cache_tags_header"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_cache_tags_header,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("cache_tags_purge"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_cache_tags_purge,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_cache_tags_filter_module = ngx.module.make_module(
    @constCast(&ngx_http_cache_tags_commands),
    @constCast(&ngx_http_cache_tags_filter_module_ctx),
);

// Tests
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "cache_tags module" {}

test "tag parsing" {
    var store = std.mem.zeroes(cache_tags_store);

    try std.testing.expect(associateTagsWithUri(&store, "product, category, featured", "/api/products/123"));
    try std.testing.expect(associateTagsWithUri(&store, "category", "/api/products/456"));

    try expectEqual(store.tag_count, 3);

    const product_tag = findTag(&store, "product");
    try expectEqual(product_tag != null, true);
    try expectEqual(product_tag.?.uri_count, 1);

    const category_tag = findTag(&store, "category");
    try expectEqual(category_tag != null, true);
    try expectEqual(category_tag.?.uri_count, 2);

    // Test purge
    const purged = purgeByTag(&store, "category");
    try expectEqual(purged, 2);
    try expectEqual(store.tag_count, 2);
    try expectEqual(findTag(&store, "category") == null, true);
}

test "oversized tag and URI are rejected without consuming slots" {
    var store = std.mem.zeroes(cache_tags_store);
    var long_tag = [_]u8{'t'} ** (MAX_TAG_LEN + 1);
    var long_uri = [_]u8{'u'} ** (MAX_URI_LEN + 1);
    try std.testing.expect(!associateTagsWithUri(&store, &long_tag, "/ok"));
    try std.testing.expect(!associateTagsWithUri(&store, "ok", &long_uri));
    try expectEqual(@as(usize, 0), store.tag_count);
}
