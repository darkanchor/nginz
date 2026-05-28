const std = @import("std");
const ngx = @import("ngx");

const buf = ngx.buf;
const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
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

const ngx_string = ngx.string.ngx_string;
const CJSON = cjson.CJSON;

extern var ngx_http_core_module: ngx_module_t;

// Location configuration
const transform_loc_conf = extern struct {
    enabled: ngx_flag_t,
    response_path: ngx_str_t, // JSON path like "$.data.items"
};

// Request context for buffering response
const transform_ctx = extern struct {
    buffer: [*c]u8,
    buffer_len: usize,
    buffer_cap: usize,
    done: ngx_flag_t,
};

fn encodeJsonString(value: ngx_str_t, pool: [*c]core.ngx_pool_t) ?ngx_str_t {
    const slice = core.slicify(u8, value.data, value.len);

    var escaped_len: usize = 2; // opening + closing quote
    for (slice) |c| {
        escaped_len += switch (c) {
            '"', '\\', '\n', '\r', '\t' => 2,
            else => if (c < 0x20) return null else 1,
        };
    }

    const out = core.castPtr(u8, core.ngx_pnalloc(pool, escaped_len)) orelse return null;
    var pos: usize = 0;
    out[pos] = '"';
    pos += 1;

    for (slice) |c| {
        switch (c) {
            '"', '\\' => {
                out[pos] = '\\';
                out[pos + 1] = c;
                pos += 2;
            },
            '\n' => {
                out[pos] = '\\';
                out[pos + 1] = 'n';
                pos += 2;
            },
            '\r' => {
                out[pos] = '\\';
                out[pos + 1] = 'r';
                pos += 2;
            },
            '\t' => {
                out[pos] = '\\';
                out[pos + 1] = 't';
                pos += 2;
            },
            else => {
                out[pos] = c;
                pos += 1;
            },
        }
    }

    out[pos] = '"';
    return ngx_str_t{ .data = out, .len = escaped_len };
}

// Extract JSON at path and serialize result
fn extractJsonPath(json_str: ngx_str_t, path: []const u8, pool: [*c]core.ngx_pool_t) ?ngx_str_t {
    var cj = CJSON.init(pool);

    // Parse JSON
    const json = cj.decode(json_str) catch return null;
    defer cj.free(json);

    // Query the path (CJSON.query handles $. prefix and dot notation)
    const result = CJSON.query(json, path) orelse return null;

    if (CJSON.stringValue(result)) |string_value| {
        return encodeJsonString(string_value, pool);
    }

    // Encode result back to string
    return cj.encode(result) catch return null;
}

// Append data to context buffer
fn appendToBuffer(ctx: [*c]transform_ctx, data: []const u8, pool: [*c]core.ngx_pool_t) bool {
    const new_len = ctx.*.buffer_len + data.len;

    // Grow buffer if needed
    if (new_len > ctx.*.buffer_cap) {
        const new_cap = if (ctx.*.buffer_cap == 0) 4096 else ctx.*.buffer_cap * 2;
        const final_cap = if (new_cap < new_len) new_len else new_cap;

        const new_buf = core.castPtr(u8, core.ngx_pnalloc(pool, final_cap)) orelse return false;

        if (ctx.*.buffer_len > 0 and ctx.*.buffer != null) {
            @memcpy(core.slicify(u8, new_buf, ctx.*.buffer_len), core.slicify(u8, ctx.*.buffer, ctx.*.buffer_len));
        }

        ctx.*.buffer = new_buf;
        ctx.*.buffer_cap = final_cap;
    }

    // Copy data
    @memcpy(core.slicify(u8, ctx.*.buffer + ctx.*.buffer_len, data.len), data);
    ctx.*.buffer_len = new_len;
    return true;
}

// Body filter - buffers and transforms response
var ngx_http_transform_next_body_filter: http.ngx_http_output_body_filter_pt = null;

export fn ngx_http_transform_body_filter(r: [*c]ngx_http_request_t, in: [*c]ngx_chain_t) callconv(.c) ngx_int_t {
    if (r != r.*.main) {
        if (ngx_http_transform_next_body_filter) |next| return next(r, in);
        return NGX_OK;
    }

    const lccf = core.castPtr(
        transform_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_transform_filter_module),
    ) orelse {
        if (ngx_http_transform_next_body_filter) |next| return next(r, in);
        return NGX_OK;
    };

    // Skip if not enabled or no path configured
    if (lccf.*.enabled != 1 or lccf.*.response_path.len == 0) {
        if (ngx_http_transform_next_body_filter) |next| return next(r, in);
        return NGX_OK;
    }

    // Skip non-JSON responses
    if (r.*.headers_out.content_type.len > 0) {
        const ct = core.slicify(u8, r.*.headers_out.content_type.data, r.*.headers_out.content_type.len);
        if (std.mem.indexOf(u8, ct, "application/json") == null) {
            if (ngx_http_transform_next_body_filter) |next| return next(r, in);
            return NGX_OK;
        }
    }

    const ctx = http.ngz_http_get_module_ctx(transform_ctx, r, &ngx_http_transform_filter_module) catch {
        if (ngx_http_transform_next_body_filter) |next| return next(r, in);
        return NGX_OK;
    };

    if (ctx.*.done == 1) {
        if (ngx_http_transform_next_body_filter) |next| return next(r, in);
        return NGX_OK;
    }

    // Buffer incoming data
    var cl = in;
    var is_last = false;
    while (cl != null) : (cl = cl.*.next) {
        const b = cl.*.buf;
        if (b == null) continue;

        const pos = @intFromPtr(b.*.pos);
        const last = @intFromPtr(b.*.last);
        if (last > pos) {
            const data = core.slicify(u8, b.*.pos, last - pos);
            if (!appendToBuffer(ctx, data, r.*.pool)) {
                return NGX_ERROR;
            }
        }

        if (b.*.flags.last_buf) {
            is_last = true;
            break;
        }
    }

    // If not done buffering, return OK (don't pass to next filter yet)
    if (!is_last) {
        return NGX_OK;
    }

    ctx.*.done = 1;

    // Transform the buffered content
    const path = core.slicify(u8, lccf.*.response_path.data, lccf.*.response_path.len);
    const buffered = ngx_str_t{ .data = ctx.*.buffer, .len = ctx.*.buffer_len };

    // Try to extract the JSON path
    const output = extractJsonPath(buffered, path, r.*.pool) orelse buffered;

    // Create new buffer with content
    const out_buf = core.castPtr(ngx_buf_t, core.ngx_pcalloc(r.*.pool, @sizeOf(ngx_buf_t))) orelse return NGX_ERROR;

    out_buf.*.pos = output.data;
    out_buf.*.last = output.data + output.len;
    out_buf.*.flags.memory = true;
    out_buf.*.flags.last_buf = (r == r.*.main);
    out_buf.*.flags.last_in_chain = true;

    var out_chain: ngx_chain_t = undefined;
    out_chain.buf = out_buf;
    out_chain.next = null;

    if (ngx_http_transform_next_body_filter) |next| {
        return next(r, &out_chain);
    }
    return NGX_OK;
}

// Header filter - clear content length since we'll change it
var ngx_http_transform_next_header_filter: http.ngx_http_output_header_filter_pt = null;

export fn ngx_http_transform_header_filter(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    if (r != r.*.main) {
        if (ngx_http_transform_next_header_filter) |next| return next(r);
        return NGX_OK;
    }

    const lccf = core.castPtr(
        transform_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_transform_filter_module),
    ) orelse {
        if (ngx_http_transform_next_header_filter) |next| return next(r);
        return NGX_OK;
    };

    // If transform is enabled, clear content-length (we'll set it after transform)
    if (lccf.*.enabled == 1 and lccf.*.response_path.len > 0) {
        // Check if JSON
        if (r.*.headers_out.content_type.len > 0) {
            const ct = core.slicify(u8, r.*.headers_out.content_type.data, r.*.headers_out.content_type.len);
            if (std.mem.indexOf(u8, ct, "application/json") != null) {
                r.*.headers_out.content_length_n = -1;
                if (r.*.headers_out.content_length != null) {
                    r.*.headers_out.content_length.*.hash = 0;
                    r.*.headers_out.content_length = null;
                }
            }
        }
    }

    if (ngx_http_transform_next_header_filter) |next| return next(r);
    return NGX_OK;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(transform_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = 0;
        p.*.response_path = ngx_str_t{ .len = 0, .data = null };
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
    const prev = core.castPtr(transform_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(transform_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.enabled == 0) c.*.enabled = prev.*.enabled;
    if (c.*.response_path.len == 0) c.*.response_path = prev.*.response_path;

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_transform(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(transform_loc_conf, loc)) |lccf| {
        lccf.*.enabled = 1;
        // Get the path argument
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            lccf.*.response_path = arg.*;
        }
    }
    return conf.NGX_CONF_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    _ = cf;
    // Install header filter
    ngx_http_transform_next_header_filter = http.ngx_http_top_header_filter;
    http.ngx_http_top_header_filter = ngx_http_transform_header_filter;

    // Install body filter
    ngx_http_transform_next_body_filter = http.ngx_http_top_body_filter;
    http.ngx_http_top_body_filter = ngx_http_transform_body_filter;

    return NGX_OK;
}

export const ngx_http_transform_filter_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_transform_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("transform_response"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_transform,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_transform_filter_module = ngx.module.make_module(
    @constCast(&ngx_http_transform_commands),
    @constCast(&ngx_http_transform_filter_module_ctx),
);

// Tests
const expectEqual = std.testing.expectEqual;

test "transform module" {}
