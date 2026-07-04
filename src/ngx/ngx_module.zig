const std = @import("std");
const ngx = @import("ngx.zig");
const core = @import("ngx_core.zig");
const conf = @import("ngx_conf.zig");
const expectEqual = std.testing.expectEqual;

pub const ngx_module_t = ngx.ngx_module_t;
pub const NGX_HTTP_MODULE = ngx.NGX_HTTP_MODULE;
pub const NGX_STREAM_MODULE = @as(c_int, 0x4d525453);

const ngx_uint_t = core.ngx_uint_t;
const ngx_conf_t = core.ngx_conf_t;
const nginx_version = core.ngx_version;
const ngx_command_t = conf.ngx_command_t;

pub const NGX_MODULE_UNSET_INDEX = std.math.maxInt(ngx_uint_t);
// Signature is injected at build time via ngx_opts so that dynmod builds
// can target a different stock nginx without touching source files.
const ngx_opts = @import("ngx_opts");
pub const NGX_MODULE_SIGNATURE: []const u8 = ngx_opts.nginx_signature;

pub inline fn make_module(cmds: [*c]ngx_command_t, ctx: ?*anyopaque) ngx_module_t {
    return ngx_module_t{
        .ctx_index = NGX_MODULE_UNSET_INDEX,
        .index = NGX_MODULE_UNSET_INDEX,
        .name = core.nullptr(u8),
        .signature = @ptrCast(@constCast(NGX_MODULE_SIGNATURE.ptr)),
        .spare0 = 0,
        .spare1 = 0,
        .version = nginx_version,
        .ctx = ctx,
        .commands = cmds,
        .type = NGX_HTTP_MODULE,
        .init_master = null,
        .init_module = null,
        .init_process = null,
        .init_thread = null,
        .exit_thread = null,
        .exit_process = null,
        .exit_master = null,
        .spare_hook0 = 0,
        .spare_hook1 = 0,
        .spare_hook2 = 0,
        .spare_hook3 = 0,
        .spare_hook4 = 0,
        .spare_hook5 = 0,
        .spare_hook6 = 0,
        .spare_hook7 = 0,
    };
}

pub inline fn make_stream_module(cmds: [*c]ngx_command_t, ctx: ?*anyopaque) ngx_module_t {
    var m = make_module(cmds, ctx);
    m.type = NGX_STREAM_MODULE;
    return m;
}

test "module" {
    try expectEqual(@sizeOf(ngx_module_t), 200);
}
