const std = @import("std");
const ngx = @import("ngx.zig");
const core = @import("ngx_core.zig");
const http = @import("ngx_http.zig");
const file = @import("ngx_file.zig");
const array = @import("ngx_array.zig");
const string = @import("ngx_string.zig");
const module = @import("ngx_module.zig");
const expectEqual = std.testing.expectEqual;

pub const ngx_conf_t = ngx.ngx_conf_t;
pub const ngx_command_t = ngx.ngx_command_t;
pub const ngx_http_conf_ctx_t = ngx.ngx_http_conf_ctx_t;

pub const NGX_CONF_UNSET = ngx.NGX_CONF_UNSET;
pub const NGX_CONF_UNSET_UINT = ngx.NGX_CONF_UNSET_UINT;
pub const NGX_CONF_UNSET_PTR = ngx.NGX_CONF_UNSET_PTR;
pub const NGX_CONF_UNSET_SIZE = ngx.NGX_CONF_UNSET_SIZE;
pub const NGX_CONF_UNSET_MSEC = ngx.NGX_CONF_UNSET_MSEC;

pub const NGX_CONF_NOARGS = ngx.NGX_CONF_NOARGS;
pub const NGX_CONF_TAKE1 = ngx.NGX_CONF_TAKE1;
pub const NGX_CONF_TAKE2 = ngx.NGX_CONF_TAKE2;
pub const NGX_CONF_TAKE3 = ngx.NGX_CONF_TAKE3;
pub const NGX_CONF_TAKE4 = ngx.NGX_CONF_TAKE4;
pub const NGX_CONF_TAKE5 = ngx.NGX_CONF_TAKE5;
pub const NGX_CONF_TAKE6 = ngx.NGX_CONF_TAKE6;
pub const NGX_CONF_TAKE7 = ngx.NGX_CONF_TAKE7;
pub const NGX_CONF_TAKE12 = ngx.NGX_CONF_TAKE12;
pub const NGX_CONF_TAKE13 = ngx.NGX_CONF_TAKE13;
pub const NGX_CONF_TAKE23 = ngx.NGX_CONF_TAKE23;
pub const NGX_CONF_TAKE123 = ngx.NGX_CONF_TAKE123;
pub const NGX_CONF_TAKE1234 = ngx.NGX_CONF_TAKE1234;

pub const NGX_CONF_BLOCK = ngx.NGX_CONF_BLOCK;
pub const NGX_CONF_FLAG = ngx.NGX_CONF_FLAG;
pub const NGX_CONF_ANY = ngx.NGX_CONF_ANY;
pub const NGX_CONF_1MORE = ngx.NGX_CONF_1MORE;
pub const NGX_CONF_2MORE = ngx.NGX_CONF_2MORE;

pub const NGX_CONF_OK = @as([*c]u8, @ptrCast(ngx.NGX_CONF_OK));
pub const NGX_CONF_ERROR = @as([*c]u8, @ptrCast(ngx.NGX_CONF_ERROR));

pub const ngx_conf_full_name = ngx.ngx_conf_full_name;
pub const ngx_conf_set_flag_slot = ngx.ngx_conf_set_flag_slot;
pub const ngx_conf_set_str_slot = ngx.ngx_conf_set_str_slot;
pub const ngx_conf_set_str_array_slot = ngx.ngx_conf_set_str_array_slot;
pub const ngx_conf_set_keyval_slot = ngx.ngx_conf_set_keyval_slot;
pub const ngx_conf_set_num_slot = ngx.ngx_conf_set_num_slot;
pub const ngx_conf_set_size_slot = ngx.ngx_conf_set_size_slot;
pub const ngx_conf_set_off_slot = ngx.ngx_conf_set_off_slot;
pub const ngx_conf_set_msec_slot = ngx.ngx_conf_set_msec_slot;
pub const ngx_conf_set_sec_slot = ngx.ngx_conf_set_sec_slot;
pub const ngx_conf_set_bufs_slot = ngx.ngx_conf_set_bufs_slot;
pub const ngx_conf_set_enum_slot = ngx.ngx_conf_set_enum_slot;
pub const ngx_conf_set_bitmask_slot = ngx.ngx_conf_set_bitmask_slot;

pub const NGX_HTTP_MAIN_CONF_OFFSET = @offsetOf(ngx_http_conf_ctx_t, "main_conf");
pub const NGX_HTTP_SRV_CONF_OFFSET = @offsetOf(ngx_http_conf_ctx_t, "srv_conf");
pub const NGX_HTTP_LOC_CONF_OFFSET = @offsetOf(ngx_http_conf_ctx_t, "loc_conf");

pub const NGX_HTTP_MAIN_CONF = ngx.NGX_HTTP_MAIN_CONF;
pub const NGX_HTTP_LOC_CONF = ngx.NGX_HTTP_LOC_CONF;
pub const NGX_HTTP_SRV_CONF = ngx.NGX_HTTP_SRV_CONF;
pub const NGX_HTTP_UPS_CONF = ngx.NGX_HTTP_UPS_CONF;

const NULL = core.NULL;
const ngx_str_t = string.ngx_str_t;
const ngx_array_t = array.ngx_array_t;
const ngx_module_t = module.ngx_module_t;
const ngx_http_request_t = http.ngx_http_request_t;

extern var ngx_http_core_module: ngx_module_t;
extern var ngx_http_upstream_module: ngx_module_t;

pub const ngx_null_command = ngx_command_t{
    .name = string.ngx_null_str,
    .type = 0,
    .set = @ptrCast(NULL),
    .conf = 0,
    .offset = 0,
    .post = @ptrCast(NULL),
};

pub inline fn ngx_conf_merge_str_value(cf: [*c]ngx_str_t, pr: [*c]ngx_str_t, de: ngx_str_t) void {
    if (cf.*.data == core.nullptr(u8)) {
        if (pr.*.data != core.nullptr(u8)) {
            cf.*.data = pr.*.data;
            cf.*.len = pr.*.len;
        } else {
            cf.* = de;
        }
    }
}

pub fn ngx_conf_set_file_slot(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, conf: ?*anyopaque) callconv(.c) [*c]u8 {
    if (core.castPtr(u8, conf)) |p| {
        if (core.castPtr(ngx_str_t, @ptrCast(p + cmd.*.offset))) |f| {
            if (f.*.data != core.nullptr(u8)) {
                return @as([*c]u8, @constCast("is duplicate"));
            }
            if (core.castPtr(ngx_str_t, cf.*.args.*.elts)) |param| {
                var path = param[1];
                if (ngx_conf_full_name(cf.*.cycle, &path, 1) == core.NGX_OK) {
                    f.* = file.ngz_open_file(path, cf.*.log, cf.*.pool) catch return NGX_CONF_ERROR;
                    return NGX_CONF_OK;
                }
            }
        }
    }
    return NGX_CONF_ERROR;
}

// http{}
pub inline fn ngx_http_get_module_main_conf(r: [*c]ngx_http_request_t, m: *ngx_module_t) ?*anyopaque {
    return r.*.main_conf[m.ctx_index];
}

// server{}
pub inline fn ngx_http_get_module_srv_conf(r: [*c]ngx_http_request_t, m: *ngx_module_t) ?*anyopaque {
    return r.*.srv_conf[m.ctx_index];
}

// location{}
pub inline fn ngx_http_get_module_loc_conf(r: [*c]ngx_http_request_t, m: *ngx_module_t) ?*anyopaque {
    return r.*.loc_conf[m.ctx_index];
}

// http{}
pub inline fn ngx_http_conf_get_module_main_conf(cf: [*c]ngx_conf_t, m: *ngx_module_t) ?*anyopaque {
    if (core.castPtr(ngx_http_conf_ctx_t, cf.*.ctx)) |p| {
        return p.*.main_conf[m.ctx_index];
    }
    return null;
}

// server{}
pub inline fn ngx_http_conf_get_module_srv_conf(cf: [*c]ngx_conf_t, m: *ngx_module_t) ?*anyopaque {
    if (core.castPtr(ngx_http_conf_ctx_t, cf.*.ctx)) |p| {
        return p.*.srv_conf[m.ctx_index];
    }
    return null;
}

// location{}
pub inline fn ngx_http_conf_get_module_loc_conf(cf: [*c]ngx_conf_t, m: *ngx_module_t) ?*anyopaque {
    if (core.castPtr(ngx_http_conf_ctx_t, cf.*.ctx)) |p| {
        return p.*.loc_conf[m.ctx_index];
    }
    return null;
}

pub inline fn ngx_http_conf_upstream_srv_conf(uscf: [*c]http.ngx_http_upstream_srv_conf_t, m: *ngx_module_t) ?*anyopaque {
    // Implicit upstreams (proxy_pass http://ip:port) have srv_conf == null
    if (uscf.*.srv_conf == null) return null;
    return uscf.*.srv_conf[m.ctx_index];
}

pub inline fn ngz_http_conf_variables_parse(
    cf: [*c]ngx_conf_t,
    script: [*c]string.ngx_str_t,
    lengths: [*c][*c]ngx_array_t,
    values: [*c][*c]ngx_array_t,
) !core.ngx_uint_t {
    const n = ngx.ngx_http_script_variables_count(script);
    if (n > 0) {
        var sc: ngx.ngx_http_script_compile_t = std.mem.zeroes(ngx.ngx_http_script_compile_t);
        sc.cf = cf;
        sc.variables = n;
        sc.source = script;
        sc.values = values;
        sc.lengths = lengths;
        sc.flags.complete_values = true;
        sc.flags.complete_lengths = true;
        if (ngx.ngx_http_script_compile(&sc) != core.NGX_OK) {
            return core.NError.CONF_ERROR;
        }
    }
    return n;
}

test "conf" {
    try expectEqual(@sizeOf(ngx_conf_t), 96);
    try expectEqual(@sizeOf(ngx_command_t), 56);
}
