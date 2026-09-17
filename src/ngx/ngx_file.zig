const std = @import("std");
const ngx = @import("ngx.zig");
const log = @import("ngx_log.zig");
const core = @import("ngx_core.zig");
const string = @import("ngx_string.zig");
const expectEqual = std.testing.expectEqual;
const c = std.c;

extern fn mkstemp(template: [*:0]u8) c_int;
extern fn stat(path: [*:0]const u8, info: *ngx_file_info_t) c_int;

fn pathZ(path: []const u8, storage: []u8) ![:0]u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (path.len >= storage.len) return error.PathTooLong;
    @memcpy(storage[0..path.len], path);
    storage[path.len] = 0;
    return storage[0..path.len :0];
}

fn interrupted() bool {
    return c._errno().* == @intFromEnum(c.E.INTR);
}

pub fn exists(path: []const u8) bool {
    var storage: [4096]u8 = undefined;
    const name = pathZ(path, &storage) catch return false;
    return c.access(name, c.F_OK) == 0;
}

fn ensureDirectory(path: [*:0]const u8) !void {
    if (c.mkdir(path, 0o755) == 0) return;
    if (c._errno().* != @intFromEnum(c.E.EXIST)) return error.MkdirFailed;
    var info: ngx_file_info_t = undefined;
    if (stat(path, &info) != 0 or !c.S.ISDIR(info.st_mode)) return error.NotDirectory;
}

pub fn createDirPath(path: []const u8) !void {
    var storage: [4096]u8 = undefined;
    const name = try pathZ(path, &storage);
    for (name, 0..) |char, i| {
        if (char != '/' or i == 0) continue;
        name[i] = 0;
        try ensureDirectory(name.ptr);
        name[i] = '/';
    }
    try ensureDirectory(name.ptr);
}

/// Replace a file only after a complete write. Each writer owns a unique temp
/// file, so concurrent nginx workers cannot truncate or rename each other's data.
pub fn writeFileAtomic(path: []const u8, contents: []const u8, mode: c.mode_t) !void {
    var path_storage: [4096]u8 = undefined;
    const final = try pathZ(path, &path_storage);
    var temp_storage: [4096]u8 = undefined;
    const temp = std.fmt.bufPrintSentinel(&temp_storage, "{s}.tmp.XXXXXX", .{final}, 0) catch return error.PathTooLong;
    const fd = mkstemp(temp.ptr);
    if (fd < 0) return error.CreateFailed;
    var opened = true;
    defer if (opened) {
        _ = c.close(fd);
    };
    defer _ = c.unlink(temp.ptr);
    if (c.fchmod(fd, mode) != 0) return error.ChmodFailed;
    var offset: usize = 0;
    while (offset < contents.len) {
        const n = c.write(fd, contents.ptr + offset, contents.len - offset);
        if (n < 0 and interrupted()) continue;
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
    while (c.fsync(fd) != 0) {
        if (!interrupted()) return error.SyncFailed;
    }
    opened = false;
    if (c.close(fd) != 0) return error.CloseFailed;
    if (c.rename(temp.ptr, final.ptr) != 0) return error.RenameFailed;
}

pub fn readFile(path: []const u8, output: []u8) ![]u8 {
    var storage: [4096]u8 = undefined;
    const name = try pathZ(path, &storage);
    const fd = c.open(name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var offset: usize = 0;
    while (offset < output.len) {
        const n = c.read(fd, output.ptr + offset, output.len - offset);
        if (n < 0 and interrupted()) continue;
        if (n < 0) return error.ReadFailed;
        if (n == 0) return output[0..offset];
        offset += @intCast(n);
    }
    var extra: [1]u8 = undefined;
    while (true) {
        const n = c.read(fd, &extra, 1);
        if (n < 0 and interrupted()) continue;
        if (n < 0) return error.ReadFailed;
        if (n > 0) return error.FileTooBig;
        return output;
    }
}

pub fn removeTree(path: []const u8) !void {
    var storage: [4096]u8 = undefined;
    const name = try pathZ(path, &storage);
    try removeTreeAt(c.AT.FDCWD, name);
}

fn removeTreeAt(parent: c_int, name: [*:0]const u8) error{ DeleteFailed, OpenFailed, ReadFailed }!void {
    if (c.unlinkat(parent, name, 0) == 0) return;
    if (c._errno().* == @intFromEnum(c.E.NOENT)) return;
    if (c._errno().* != @intFromEnum(c.E.ISDIR)) return error.DeleteFailed;
    const fd = c.openat(parent, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return error.OpenFailed;
    const dir = c.fdopendir(fd) orelse {
        _ = c.close(fd);
        return error.OpenFailed;
    };
    defer _ = c.closedir(dir);
    while (true) {
        c._errno().* = 0;
        const entry = c.readdir(dir) orelse {
            if (c._errno().* != 0) return error.ReadFailed;
            break;
        };
        const child = std.mem.sliceTo(&entry.name, 0);
        if (std.mem.eql(u8, child, ".") or std.mem.eql(u8, child, "..")) continue;
        try removeTreeAt(fd, @ptrCast(child.ptr)); // readdir names are NUL-terminated
    }
    if (c.unlinkat(parent, name, c.AT.REMOVEDIR) != 0 and c._errno().* != @intFromEnum(c.E.NOENT)) return error.DeleteFailed;
}

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

extern fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

test "libc file operations preserve complete writes and do not follow cleanup symlinks" {
    var template = "/tmp/nginz-file-test-XXXXXX".*;
    const root = std.mem.span(mkdtemp(&template) orelse return error.CreateFailed);
    defer removeTree(root) catch {};
    var path_storage: [512]u8 = undefined;
    const nested = try std.fmt.bufPrint(&path_storage, "{s}/one/two", .{root});
    try createDirPath(nested);
    try createDirPath(nested);
    try std.testing.expect(exists(nested));
    var key_storage: [512]u8 = undefined;
    const key = try std.fmt.bufPrintSentinel(&key_storage, "{s}/key", .{nested}, 0);
    try writeFileAtomic(key, "private key", 0o600);
    var info: ngx_file_info_t = undefined;
    try expectEqual(@as(c_int, 0), stat(key.ptr, &info));
    try expectEqual(@as(c_uint, 0o600), info.st_mode & 0o777);
    var bytes: [16]u8 = undefined;
    try std.testing.expectEqualStrings("private key", try readFile(key, &bytes));
    try std.testing.expectError(error.FileTooBig, readFile(key, bytes[0..3]));
    try writeFileAtomic(key, "new", 0o600);
    try std.testing.expectEqualStrings("new", try readFile(key, bytes[0..3]));
    try std.testing.expectError(error.NotDirectory, createDirPath(key));
    try std.testing.expectError(error.RenameFailed, writeFileAtomic(nested, "cannot replace directory", 0o600));
    try std.testing.expect(exists(key));
    var outside_storage: [512]u8 = undefined;
    const outside = try std.fmt.bufPrintSentinel(&outside_storage, "{s}/outside", .{root}, 0);
    try createDirPath(outside);
    var marker_storage: [512]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_storage, "{s}/keep", .{outside});
    try writeFileAtomic(marker, "keep", 0o600);
    var link_storage: [512]u8 = undefined;
    const link = try std.fmt.bufPrintSentinel(&link_storage, "{s}/link", .{nested}, 0);
    try expectEqual(@as(c_int, 0), c.symlink(outside.ptr, link.ptr));
    try removeTree(nested);
    try std.testing.expect(!exists(nested));
    try std.testing.expect(exists(marker));
    try removeTree(nested); // already removed
    try std.testing.expectError(error.InvalidPath, writeFileAtomic("bad\x00path", "", 0o600));
}
