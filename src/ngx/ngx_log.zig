const std = @import("std");
const ngx = @import("ngx.zig");
const core = @import("ngx_core.zig");
const conf = @import("ngx_conf.zig");
const expectEqual = std.testing.expectEqual;

pub const ngx_log_t = ngx.ngx_log_t;
pub const NGX_LOG_STDERR = @as(c_int, 0);
pub const NGX_LOG_EMERG = @as(c_int, 1);
pub const NGX_LOG_ALERT = @as(c_int, 2);
pub const NGX_LOG_CRIT = @as(c_int, 3);
pub const NGX_LOG_ERR = @as(c_int, 4);
pub const NGX_LOG_WARN = @as(c_int, 5);
pub const NGX_LOG_NOTICE = @as(c_int, 6);
pub const NGX_LOG_INFO = @as(c_int, 7);
pub const NGX_LOG_DEBUG = @as(c_int, 8);

pub const NGX_LOG_DEBUG_CORE = @as(c_int, 0x010);
pub const NGX_LOG_DEBUG_ALLOC = @as(c_int, 0x020);
pub const NGX_LOG_DEBUG_MUTEX = @as(c_int, 0x040);
pub const NGX_LOG_DEBUG_EVENT = @as(c_int, 0x080);
pub const NGX_LOG_DEBUG_HTTP = @as(c_int, 0x100);
pub const NGX_LOG_DEBUG_MAIL = @as(c_int, 0x200);
pub const NGX_LOG_DEBUG_STREAM = @as(c_int, 0x400);
pub const NGX_LOG_DEBUG_FIRST = NGX_LOG_DEBUG_CORE;
pub const NGX_LOG_DEBUG_LAST = NGX_LOG_DEBUG_STREAM;
pub const NGX_LOG_DEBUG_CONNECTION = @as(c_uint, 0x80000000);

pub const NGX_LOG_DEBUG_ALL = @as(c_int, 0x7ffffff0);
pub const NGX_MAX_ERROR_STR = @as(c_int, 2048);

const ngx_uint_t = core.ngx_uint_t;
const ngx_err_t = core.ngx_err_t;
const ngx_conf_t = conf.ngx_conf_t;

const ngx_log_error_core = ngx.ngx_log_error_core;
pub fn ngz_log_error(level: ngx_uint_t, log: [*c]ngx_log_t, err: ngx_err_t, fmt: [*c]const u8, args: anytype) void {
    const ArgsType = @TypeOf(args);
    const info = @typeInfo(ArgsType);
    if (info != .@"struct") {
        @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
    }
    if (info.@"struct".fields.len > 8) {
        @compileError("too many args");
    }
    if (log.*.log_level >= level) {
        switch (info.@"struct".fields.len) {
            0 => ngx_log_error_core(level, log, err, fmt),
            1 => ngx_log_error_core(level, log, err, fmt, @as(info.@"struct".fields[0].type, args[0])),
            2 => ngx_log_error_core(level, log, err, fmt, @as(info.@"struct".fields[0].type, args[0]), @as(info.@"struct".fields[1].type, args[1])),
            3 => ngx_log_error_core(level, log, err, fmt, @as(info.@"struct".fields[0].type, args[0]), @as(info.@"struct".fields[1].type, args[1]), @as(info.@"struct".fields[2].type, args[2])),
            4 => ngx_log_error_core(level, log, err, fmt, @as(info.@"struct".fields[0].type, args[0]), @as(info.@"struct".fields[1].type, args[1]), @as(info.@"struct".fields[2].type, args[2]), @as(info.@"struct".fields[3].type, args[3])),
            5 => ngx_log_error_core(level, log, err, fmt, @as(info.@"struct".fields[0].type, args[0]), @as(info.@"struct".fields[1].type, args[1]), @as(info.@"struct".fields[2].type, args[2]), @as(info.@"struct".fields[3].type, args[3]), @as(info.@"struct".fields[4].type, args[4])),
            6 => ngx_log_error_core(level, log, err, fmt, @as(info.@"struct".fields[0].type, args[0]), @as(info.@"struct".fields[1].type, args[1]), @as(info.@"struct".fields[2].type, args[2]), @as(info.@"struct".fields[3].type, args[3]), @as(info.@"struct".fields[4].type, args[4]), @as(info.@"struct".fields[5].type, args[5])),
            7 => ngx_log_error_core(level, log, err, fmt, @as(info.@"struct".fields[0].type, args[0]), @as(info.@"struct".fields[1].type, args[1]), @as(info.@"struct".fields[2].type, args[2]), @as(info.@"struct".fields[3].type, args[3]), @as(info.@"struct".fields[4].type, args[4]), @as(info.@"struct".fields[5].type, args[5]), @as(info.@"struct".fields[6].type, args[6])),
            8 => ngx_log_error_core(level, log, err, fmt, @as(info.@"struct".fields[0].type, args[0]), @as(info.@"struct".fields[1].type, args[1]), @as(info.@"struct".fields[2].type, args[2]), @as(info.@"struct".fields[3].type, args[3]), @as(info.@"struct".fields[4].type, args[4]), @as(info.@"struct".fields[5].type, args[5]), @as(info.@"struct".fields[6].type, args[6]), @as(info.@"struct".fields[7].type, args[7])),
            else => unreachable,
        }
    }
}

pub fn ngz_log_debug(level: ngx_uint_t, log: [*c]ngx_log_t, err: ngx_err_t, fmt: [*c]const u8, args: anytype) void {
    const ArgsType = @TypeOf(args);
    const info = @typeInfo(ArgsType);
    if (info != .@"struct") {
        @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
    }
    if (info.@"struct".fields.len > 8) {
        @compileError("too many args");
    }
    if (log.*.log_level & level > 0) {
        switch (info.@"struct".fields.len) {
            0 => ngx_log_error_core(NGX_LOG_DEBUG, log, err, fmt),
            1 => ngx_log_error_core(NGX_LOG_DEBUG, log, err, fmt, @as(info.@"struct".fields[0].type, args[0])),
            2 => ngx_log_error_core(NGX_LOG_DEBUG, log, err, fmt, @as(info.@"struct".fields[0].type, args[0]), @as(info.@"struct".fields[1].type, args[1])),
            3 => ngx_log_error_core(NGX_LOG_DEBUG, log, err, fmt, @as(info.@"struct".fields[0].type, args[0]), @as(info.@"struct".fields[1].type, args[1]), @as(info.@"struct".fields[2].type, args[2])),
            4 => ngx_log_error_core(NGX_LOG_DEBUG, log, err, fmt, @as(info.@"struct".fields[0].type, args[0]), @as(info.@"struct".fields[1].type, args[1]), @as(info.@"struct".fields[2].type, args[2]), @as(info.@"struct".fields[3].type, args[3])),
            5 => ngx_log_error_core(NGX_LOG_DEBUG, log, err, fmt, @as(info.@"struct".fields[0].type, args[0]), @as(info.@"struct".fields[1].type, args[1]), @as(info.@"struct".fields[2].type, args[2]), @as(info.@"struct".fields[3].type, args[3]), @as(info.@"struct".fields[4].type, args[4])),
            6 => ngx_log_error_core(NGX_LOG_DEBUG, log, err, fmt, @as(info.@"struct".fields[0].type, args[0]), @as(info.@"struct".fields[1].type, args[1]), @as(info.@"struct".fields[2].type, args[2]), @as(info.@"struct".fields[3].type, args[3]), @as(info.@"struct".fields[4].type, args[4]), @as(info.@"struct".fields[5].type, args[5])),
            7 => ngx_log_error_core(NGX_LOG_DEBUG, log, err, fmt, @as(info.@"struct".fields[0].type, args[0]), @as(info.@"struct".fields[1].type, args[1]), @as(info.@"struct".fields[2].type, args[2]), @as(info.@"struct".fields[3].type, args[3]), @as(info.@"struct".fields[4].type, args[4]), @as(info.@"struct".fields[5].type, args[5]), @as(info.@"struct".fields[6].type, args[6])),
            8 => ngx_log_error_core(NGX_LOG_DEBUG, log, err, fmt, @as(info.@"struct".fields[0].type, args[0]), @as(info.@"struct".fields[1].type, args[1]), @as(info.@"struct".fields[2].type, args[2]), @as(info.@"struct".fields[3].type, args[3]), @as(info.@"struct".fields[4].type, args[4]), @as(info.@"struct".fields[5].type, args[5]), @as(info.@"struct".fields[6].type, args[6]), @as(info.@"struct".fields[7].type, args[7])),
            else => unreachable,
        }
    }
}

pub inline fn ngx_http_conf_debug(cf: [*c]ngx_conf_t, fmt: [*c]const u8, args: anytype) void {
    cf.*.log.*.log_level |= NGX_LOG_DEBUG_HTTP;
    ngz_log_debug(NGX_LOG_DEBUG_HTTP, cf.*.log, 0, fmt, args);
}

const ngx_time_init = ngx.ngx_time_init;
const ngx_log_init = ngx.ngx_log_init;
test "log" {
    try expectEqual(@sizeOf(ngx_log_t), 120);
    const log = ngx_log_init(core.c_str(""), core.c_str(""));
    try expectEqual(log.*.log_level, NGX_LOG_NOTICE);

    log.*.log_level |= NGX_LOG_DEBUG_CORE;
    ngx_time_init();
    ngz_log_debug(NGX_LOG_DEBUG_HTTP, log, 0, "this never shows", .{});
}
