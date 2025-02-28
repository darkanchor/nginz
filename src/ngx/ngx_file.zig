const std = @import("std");
const ngx = @import("ngx.zig");
const log = @import("ngx_log.zig");
const core = @import("ngx_core.zig");
const string = @import("ngx_string.zig");
const expectEqual = std.testing.expectEqual;

const off_t = core.off_t;
const ngx_log_t = log.ngx_log_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_pool_t = core.ngx_pool_t;
const ngx_str_t = string.ngx_str_t;

pub const ngx_fd_t = ngx.ngx_fd_t;
pub const ngx_file_t = ngx.ngx_file_t;
pub const ngx_file_info_t = ngx.ngx_file_info_t;
pub const ngx_temp_file_t = ngx.ngx_temp_file_t;

const NGX_FILE_OPEN = ngx.NGX_FILE_OPEN;
const NGX_FILE_RDWR = ngx.NGX_FILE_RDWR;
const NGX_FILE_RDONLY = ngx.NGX_FILE_RDONLY;
const NGX_FILE_WRONLY = ngx.NGX_FILE_WRONLY;
const NGX_FILE_ERROR = ngx.NGX_FILE_ERROR;
const NGX_INVALID_FILE = ngx.NGX_INVALID_FILE;

pub const ngx_fd_info = ngx.ngx_fd_info;
pub const ngx_file_size = ngx.ngx_file_size;
pub const ngx_read_file = ngx.ngx_read_file;
pub const ngx_write_file = ngx.ngx_write_file;
pub const ngx_close_file = ngx.ngx_close_file;
pub const ngx_open_tempfile = ngx.ngx_open_tempfile;

pub inline fn ngx_open_file(file: ngx_str_t, mode: c_int, access: c_int) ngx_fd_t {
    return ngx.open(file.data, mode, access);
}

pub fn ngz_open_file(path: ngx_str_t, lg: [*c]ngx_log_t, pool: [*c]ngx_pool_t) !ngx_str_t {
    var info: ngx_file_info_t = std.mem.zeroes(ngx_file_info_t);
    var file: ngx_file_t = std.mem.zeroes(ngx_file_t);
    file.name = path;
    file.fd = ngx_open_file(path, NGX_FILE_RDONLY | NGX_FILE_OPEN, 0);
    file.log = lg;
    if (file.fd == NGX_INVALID_FILE) {
        return core.NError.FILE_ERROR;
    }
    defer _ = ngx_close_file(file.fd);
    if (ngx_fd_info(file.fd, &info) == NGX_FILE_ERROR) {
        return core.NError.FILE_ERROR;
    }

    const size: usize = @intCast(ngx_file_size(&info));
    if (core.castPtr(u8, core.ngx_pcalloc(pool, size))) |p| {
        const len = ngx_read_file(&file, p, size, 0);
        if (len == core.NGX_ERROR) {
            return core.NError.FILE_ERROR;
        }
        return ngx_str_t{ .data = p, .len = @as(usize, @intCast(len)) };
    }
    return core.NError.OOM;
}

test "file" {
    try expectEqual(@sizeOf(ngx_file_t), 232);
    try expectEqual(@sizeOf(ngx_temp_file_t), 280);
}
