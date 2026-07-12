const std = @import("std");
const ngx = @import("ngx");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const hash = ngx.hash;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;

const ngx_str_t = core.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_pool_t = core.ngx_pool_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;
const ngx_http_variable_value_t = http.ngx_http_variable_value_t;
const ngx_table_elt_t = hash.ngx_table_elt_t;

const ngx_string = ngx.string.ngx_string;
const NList = ngx.list.NList;

// UUID4 length: 8-4-4-4-12 = 36 characters
const UUID4_LEN: usize = 36;
const MAX_ACCEPTED_REQUEST_ID_LEN: usize = 128;

// Default header name
const default_header_name: ngx_str_t = ngx_string("X-Request-ID");

// Location configuration
const requestid_loc_conf = extern struct {
    enabled: ngx_flag_t,
    add_to_response: ngx_flag_t,
    header_name: ngx_str_t,
};

// Request context - stores the generated/propagated request ID for this request
const requestid_ctx = extern struct {
    request_id: ngx_str_t,
    id_set: ngx_flag_t,
};

// Hex lookup table for fast UUID formatting
const hex_chars = "0123456789abcdef";

// Generate UUID4 and write to buffer
// UUID4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
// where x is random hex and y is 8, 9, a, or b
fn generate_uuid4(buf: [*]u8) bool {
    // Use Zig's crypto random for high-quality randomness
    var random_bytes: [16]u8 = undefined;
    if (std.c.getrandom(&random_bytes, random_bytes.len, 0) != random_bytes.len) return false;

    // Set version (4) in byte 6 (bits 4-7)
    random_bytes[6] = (random_bytes[6] & 0x0f) | 0x40;

    // Set variant (10xx) in byte 8 (bits 6-7)
    random_bytes[8] = (random_bytes[8] & 0x3f) | 0x80;

    // Format as UUID string: 8-4-4-4-12
    var pos: usize = 0;
    for (0..16) |i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[pos] = '-';
            pos += 1;
        }
        buf[pos] = hex_chars[random_bytes[i] >> 4];
        buf[pos + 1] = hex_chars[random_bytes[i] & 0x0f];
        pos += 2;
    }
    return true;
}

fn valid_incoming_request_id(value: ngx_str_t) bool {
    if (value.len == 0 or value.len > MAX_ACCEPTED_REQUEST_ID_LEN or value.data == null) return false;
    for (core.slicify(u8, value.data, value.len)) |c| {
        if (c < 0x21 or c > 0x7e) return false;
    }
    return true;
}

// Find incoming X-Request-ID header (or custom header name)
fn find_request_id_header(r: [*c]ngx_http_request_t, header_name: ngx_str_t) ?ngx_str_t {
    var headers = NList(ngx_table_elt_t).init0(&r.*.headers_in.headers);
    var it = headers.iterator();

    while (it.next()) |h| {
        if (h.*.key.len == header_name.len) {
            // Case-insensitive comparison
            var match = true;
            const key_slice = core.slicify(u8, h.*.key.data, h.*.key.len);
            const name_slice = core.slicify(u8, header_name.data, header_name.len);
            for (key_slice, name_slice) |a, b| {
                const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
                const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
                if (la != lb) {
                    match = false;
                    break;
                }
            }
            if (match) {
                return h.*.value;
            }
        }
    }
    return null;
}

// Get or create the request ID for this request
fn get_or_create_request_id(r: [*c]ngx_http_request_t, lccf: [*c]requestid_loc_conf) ?ngx_str_t {
    // Get or create context
    const ctx = http.ngz_http_get_module_ctx(requestid_ctx, r, &ngx_http_requestid_filter_module) catch return null;

    // Check if we already have an ID set
    if (ctx.*.id_set != 0) {
        return ctx.*.request_id;
    }

    // First, check for incoming header
    if (find_request_id_header(r, lccf.*.header_name)) |incoming_id| if (valid_incoming_request_id(incoming_id)) {
        // Copy incoming ID to pool
        if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, incoming_id.len))) |buf| {
            core.ngz_memcpy(buf, incoming_id.data, incoming_id.len);
            ctx.*.request_id = ngx_str_t{ .len = incoming_id.len, .data = buf };
            ctx.*.id_set = 1;
            return ctx.*.request_id;
        }
        return null;
    };

    // Generate new UUID4
    if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, UUID4_LEN))) |buf| {
        if (!generate_uuid4(buf)) {
            ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, r.*.connection.*.log, 0,
                "requestid: entropy acquisition failed", .{});
            return null;
        }
        ctx.*.request_id = ngx_str_t{ .len = UUID4_LEN, .data = buf };
        ctx.*.id_set = 1;
        return ctx.*.request_id;
    }

    return null;
}

// Variable getter for $request_id
fn ngx_http_requestid_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;

    // Get location config
    const lccf = core.castPtr(
        requestid_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_requestid_filter_module),
    ) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };

    // Check if enabled
    if (lccf.*.enabled != 1) {
        v.*.flags.not_found = true;
        return NGX_OK;
    }

    // Get or create the request ID
    if (get_or_create_request_id(r, lccf)) |request_id| {
        v.*.data = request_id.data;
        v.*.flags.len = @intCast(request_id.len);
        v.*.flags.valid = true;
        v.*.flags.no_cacheable = false;
        v.*.flags.not_found = false;
        return NGX_OK;
    }

    v.*.flags.not_found = true;
    return NGX_OK;
}

// Header filter to add X-Request-ID to response
var ngx_http_requestid_next_header_filter: http.ngx_http_output_header_filter_pt = null;

export fn ngx_http_requestid_header_filter(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    // Get location config
    const lccf = core.castPtr(
        requestid_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_requestid_filter_module),
    ) orelse {
        ngx.log.ngz_log_error(
            ngx.log.NGX_LOG_NOTICE,
            r.*.connection.*.log,
            0,
            "requestid: lccf is null",
            .{},
        );
        if (ngx_http_requestid_next_header_filter) |next| {
            return next(r);
        }
        return NGX_OK;
    };

    // Check if enabled and should add to response
    if (lccf.*.enabled == 1 and lccf.*.add_to_response == 1) {
        // Get or create the request ID
        if (get_or_create_request_id(r, lccf)) |request_id| {
            ngx.log.ngz_log_debug(
                ngx.log.NGX_LOG_DEBUG_HTTP,
                r.*.connection.*.log,
                0,
                "requestid: adding header %V=%V",
                .{ &lccf.*.header_name, &request_id },
            );
            // Add header to response
            var headers = NList(ngx_table_elt_t).init0(&r.*.headers_out.headers);
            if (headers.append()) |h| {
                h.*.hash = 1;
                h.*.key = lccf.*.header_name;
                h.*.value = request_id;
                h.*.lowcase_key = lccf.*.header_name.data;
            } else |_| {
                ngx.log.ngz_log_debug(
                    ngx.log.NGX_LOG_DEBUG_HTTP,
                    r.*.connection.*.log,
                    0,
                    "requestid: failed to append header",
                    .{},
                );
            }
        } else {
            ngx.log.ngz_log_debug(
                ngx.log.NGX_LOG_DEBUG_HTTP,
                r.*.connection.*.log,
                0,
                "requestid: failed to get/create request_id",
                .{},
            );
        }
    }

    // Call next filter
    if (ngx_http_requestid_next_header_filter) |next| {
        return next(r);
    }
    return NGX_OK;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(requestid_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = conf.NGX_CONF_UNSET;
        p.*.add_to_response = conf.NGX_CONF_UNSET;
        p.*.header_name = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
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
    const prev = core.castPtr(requestid_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(requestid_loc_conf, child) orelse return conf.NGX_CONF_OK;

    // Merge enabled flag
    if (c.*.enabled == conf.NGX_CONF_UNSET) {
        c.*.enabled = if (prev.*.enabled == conf.NGX_CONF_UNSET) 0 else prev.*.enabled;
    }

    // Merge add_to_response flag
    if (c.*.add_to_response == conf.NGX_CONF_UNSET) {
        c.*.add_to_response = if (prev.*.add_to_response == conf.NGX_CONF_UNSET) 1 else prev.*.add_to_response;
    }

    // Merge header_name
    if (c.*.header_name.len == 0) {
        c.*.header_name = if (prev.*.header_name.len == 0) default_header_name else prev.*.header_name;
    }

    return conf.NGX_CONF_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    // Register $ngz_request_id variable
    var vs = [_]http.ngx_http_variable_t{http.ngx_http_variable_t{
        .name = ngx_string("ngz_request_id"),
        .set_handler = null,
        .get_handler = ngx_http_requestid_variable,
        .data = 0,
        .flags = http.NGX_HTTP_VAR_NOCACHEABLE,
        .index = 0,
    }};
    for (&vs) |*v| {
        if (http.ngx_http_add_variable(cf, &v.name, v.flags)) |x| {
            x.*.get_handler = v.get_handler;
            x.*.data = v.data;
        }
    }

    // Install header filter
    ngx_http_requestid_next_header_filter = http.ngx_http_top_header_filter;
    http.ngx_http_top_header_filter = ngx_http_requestid_header_filter;

    return NGX_OK;
}

fn ngx_conf_set_requestid_header(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(requestid_loc_conf, loc)) |lccf| {
        lccf.*.enabled = 1;
        // Get the argument (header name)
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            lccf.*.header_name = arg.*;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_requestid_response(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(requestid_loc_conf, loc)) |lccf| {
        lccf.*.enabled = 1;
        // Get the argument (on/off)
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const slice = core.slicify(u8, arg.*.data, arg.*.len);
            if (std.mem.eql(u8, slice, "on")) {
                lccf.*.add_to_response = 1;
            } else if (std.mem.eql(u8, slice, "off")) {
                lccf.*.add_to_response = 0;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

export const ngx_http_requestid_filter_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_requestid_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("request_id_header"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_requestid_header,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("request_id_response"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_requestid_response,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_requestid_filter_module = ngx.module.make_module(
    @constCast(&ngx_http_requestid_commands),
    @constCast(&ngx_http_requestid_filter_module_ctx),
);

// Tests
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "uuid4 generation" {
    var buf: [UUID4_LEN]u8 = undefined;
    try expect(generate_uuid4(&buf));

    // Check format: 8-4-4-4-12
    try expectEqual(buf[8], '-');
    try expectEqual(buf[13], '-');
    try expectEqual(buf[18], '-');
    try expectEqual(buf[23], '-');

    // Check version (4) at position 14
    try expectEqual(buf[14], '4');

    // Check variant at position 19 (should be 8, 9, a, or b)
    try expect(buf[19] == '8' or buf[19] == '9' or buf[19] == 'a' or buf[19] == 'b');
}

test "requestid module" {
}

test "incoming request ids are bounded and visible ASCII" {
    const valid = ngx_string("trace-123_ABC");
    try expect(valid_incoming_request_id(valid));
    const empty = ngx_string("");
    try expect(!valid_incoming_request_id(empty));
    var control = [_]u8{ 'a', '\n', 'b' };
    try expect(!valid_incoming_request_id(.{ .data = &control, .len = control.len }));
    var oversized = [_]u8{'x'} ** (MAX_ACCEPTED_REQUEST_ID_LEN + 1);
    try expect(!valid_incoming_request_id(.{ .data = &oversized, .len = oversized.len }));
}
