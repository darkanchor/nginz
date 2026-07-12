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
const ngx_conf_t = conf.ngx_conf_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;
const ngx_http_variable_value_t = http.ngx_http_variable_value_t;
const ngx_table_elt_t = hash.ngx_table_elt_t;

const ngx_string = ngx.string.ngx_string;
const NList = ngx.list.NList;

// Location configuration
const canary_loc_conf = extern struct {
    enabled: ngx_flag_t,
    percentage: ngx_uint_t, // 0-100
    percentage_set: ngx_flag_t,
    header_name: ngx_str_t,
    header_value: ngx_str_t,
};

// Request context - stores the canary decision for this request
const canary_ctx = extern struct {
    is_canary: ngx_flag_t, // 1 if routed to canary, 0 otherwise
    decision_made: ngx_flag_t,
};

// Find header value by name (case-insensitive)
fn find_header(r: [*c]ngx_http_request_t, header_name: ngx_str_t) ?ngx_str_t {
    if (header_name.len == 0) return null;

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

// Compare two ngx_str_t (case-insensitive)
fn str_eq_ci(a: ngx_str_t, b: ngx_str_t) bool {
    if (a.len != b.len) return false;
    const a_slice = core.slicify(u8, a.data, a.len);
    const b_slice = core.slicify(u8, b.data, b.len);
    for (a_slice, b_slice) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

// Determine if request should go to canary
fn should_route_to_canary(r: [*c]ngx_http_request_t, lccf: *canary_loc_conf) bool {
    // Priority 1: Check header match
    if (lccf.header_name.len > 0 and lccf.header_value.len > 0) {
        if (find_header(r, lccf.header_name)) |header_val| {
            if (str_eq_ci(header_val, lccf.header_value)) {
                return true;
            }
        }
    }

    // Priority 2: Percentage-based routing
    if (lccf.percentage > 0) {
        // Generate random number 0-99
        var random_byte: [1]u8 = undefined;
        if (std.c.getrandom(&random_byte, random_byte.len, 0) != random_byte.len) {
            ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, r.*.connection.*.log, 0,
                "canary: entropy acquisition failed; routing to stable", .{});
            return false;
        }
        const random_value: u32 = @as(u32, random_byte[0]) * 100 / 256;

        if (random_value < lccf.percentage) {
            return true;
        }
    }

    return false;
}

// Get or create canary decision for this request
fn get_canary_decision(r: [*c]ngx_http_request_t) ?*canary_ctx {
    // Get location config
    const lccf = core.castPtr(
        canary_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_canary_module),
    ) orelse return null;

    // Check if enabled
    if (lccf.*.enabled != 1) return null;

    // Get or create context
    const ctx = http.ngz_http_get_module_ctx(canary_ctx, r, &ngx_http_canary_module) catch return null;

    // Make decision if not already made
    if (ctx.*.decision_made != 1) {
        ctx.*.is_canary = if (should_route_to_canary(r, lccf)) 1 else 0;
        ctx.*.decision_made = 1;
    }

    return ctx;
}

// Variable getter for $ngz_canary
fn ngx_http_canary_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;

    if (get_canary_decision(r)) |ctx| {
        if (ctx.is_canary == 1) {
            v.*.data = @constCast("1");
            v.*.flags.len = 1;
        } else {
            v.*.data = @constCast("0");
            v.*.flags.len = 1;
        }
        v.*.flags.valid = true;
        v.*.flags.no_cacheable = false;
        v.*.flags.not_found = false;
    } else {
        // Not enabled or error - return "0"
        v.*.data = @constCast("0");
        v.*.flags.len = 1;
        v.*.flags.valid = true;
        v.*.flags.no_cacheable = false;
        v.*.flags.not_found = false;
    }

    return NGX_OK;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(canary_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = conf.NGX_CONF_UNSET;
        p.*.percentage = 0;
        p.*.percentage_set = 0;
        p.*.header_name = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
        p.*.header_value = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
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
    const prev = core.castPtr(canary_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(canary_loc_conf, child) orelse return conf.NGX_CONF_OK;

    // Merge enabled flag
    if (c.*.enabled == conf.NGX_CONF_UNSET) {
        c.*.enabled = if (prev.*.enabled == conf.NGX_CONF_UNSET) 0 else prev.*.enabled;
    }

    // Merge percentage
    if (c.*.percentage_set == 0) {
        c.*.percentage = prev.*.percentage;
        c.*.percentage_set = prev.*.percentage_set;
    }

    // Merge header name/value
    if (c.*.header_name.len == 0) {
        c.*.header_name = prev.*.header_name;
        c.*.header_value = prev.*.header_value;
    }

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_canary_percentage(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(canary_loc_conf, loc)) |lccf| {
        lccf.*.enabled = 1;
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const slice = core.slicify(u8, arg.*.data, arg.*.len);
            lccf.*.percentage = std.fmt.parseInt(ngx_uint_t, slice, 10) catch
                return @constCast("canary_percentage must be an integer from 0 to 100");
            if (lccf.*.percentage > 100)
                return @constCast("canary_percentage must be an integer from 0 to 100");
            lccf.*.percentage_set = 1;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_canary_header(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(canary_loc_conf, loc)) |lccf| {
        lccf.*.enabled = 1;
        var i: ngx_uint_t = 1;
        // First arg: header name
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |name| {
            lccf.*.header_name = name.*;
        }
        // Second arg: header value
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |value| {
            lccf.*.header_value = value.*;
        }
    }
    return conf.NGX_CONF_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    // Register $ngz_canary variable
    var vs = [_]http.ngx_http_variable_t{http.ngx_http_variable_t{
        .name = ngx_string("ngz_canary"),
        .set_handler = null,
        .get_handler = ngx_http_canary_variable,
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

    return NGX_OK;
}

export const ngx_http_canary_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_canary_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("canary_percentage"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_canary_percentage,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("canary_header"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_canary_header,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_canary_module = ngx.module.make_module(
    @constCast(&ngx_http_canary_commands),
    @constCast(&ngx_http_canary_module_ctx),
);

// Tests
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "canary module" {
}

test "explicit zero percentage does not inherit" {
    var parent: canary_loc_conf = std.mem.zeroes(canary_loc_conf);
    var child: canary_loc_conf = std.mem.zeroes(canary_loc_conf);
    parent.percentage = 50;
    parent.percentage_set = 1;
    child.percentage = 0;
    child.percentage_set = 1;
    if (child.percentage_set == 0) child.percentage = parent.percentage;
    try expectEqual(@as(ngx_uint_t, 0), child.percentage);
}
