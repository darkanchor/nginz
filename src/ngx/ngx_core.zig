const std = @import("std");
const ngx = @import("ngx.zig");
const ngx_opts = @import("ngx_opts");
const ArrayList = std.array_list.Managed;
const expectEqual = std.testing.expectEqual;

pub const ngx_version = ngx_opts.nginx_version;
pub const ngx_stdin = std.posix.STDIN_FILENO;
pub const ngx_stdout = std.posix.STDOUT_FILENO;
pub const ngx_stderr = std.posix.STDERR_FILENO;

pub const NULL = ngx.NULL;
pub const NGX_ALIGNMENT = ngx.NGX_ALIGNMENT;
pub const NGX_CACHELINE_SIZE = ngx.NGX_CPU_CACHE_LINE;

pub const NGX_OK = ngx.NGX_OK;
pub const NGX_ERROR = ngx.NGX_ERROR;
pub const NGX_AGAIN = ngx.NGX_AGAIN;
pub const NGX_BUSY = ngx.NGX_BUSY;
pub const NGX_DONE = ngx.NGX_DONE;
pub const NGX_DECLINED = ngx.NGX_DECLINED;
pub const NGX_ABORT = ngx.NGX_ABORT;

pub const uintptr_t = usize;
pub const off_t = ngx.off_t;
pub const u_char = ngx.u_char;
pub const in_port_t = ngx.in_port_t;
pub const ngx_dir_t = ngx.ngx_dir_t;
pub const ngx_process_t = ngx.ngx_process_t;

pub const ngx_err_t = ngx.ngx_err_t;
pub const ngx_str_t = ngx.ngx_str_t;
pub const ngx_int_t = ngx.ngx_int_t;
pub const ngx_uint_t = ngx.ngx_uint_t;
pub const ngx_pool_t = ngx.ngx_pool_t;
pub const ngx_flag_t = ngx.ngx_flag_t;
pub const ngx_msec_t = ngx.ngx_msec_t;
pub const ngx_cycle_t = ngx.ngx_cycle_t;

pub const ngx_url_t = ngx.ngx_url_t;
pub const ngx_cidr_t = ngx.ngx_cidr_t;
pub const ngx_event_t = ngx.ngx_event_t;
pub const ngx_resolver_t = ngx.ngx_resolver_t;
pub const ngx_slab_pool_t = ngx.ngx_slab_pool_t;
pub const ngx_listening_t = ngx.ngx_listening_t;
pub const ngx_event_pipe_t = ngx.ngx_event_pipe_t;
pub const ngx_connection_t = ngx.ngx_connection_t;
pub const ngx_syslog_peer_t = ngx.ngx_syslog_peer_t;
pub const ngx_resolver_ctx_t = ngx.ngx_resolver_ctx_t;
pub const ngx_resolver_node_t = ngx.ngx_resolver_node_t;
pub const ngx_open_file_info_t = ngx.ngx_open_file_info_t;
pub const ngx_variable_value_t = ngx.ngx_variable_value_t;
pub const ngx_peer_connection_t = ngx.ngx_peer_connection_t;
pub const ngx_ext_rename_file_t = ngx.ngx_ext_rename_file_t;
pub const ngx_output_chain_ctx_t = ngx.ngx_output_chain_ctx_t;
pub const ngx_cached_open_file_t = ngx.ngx_cached_open_file_t;
pub const ngx_pool_cleanup_t = ngx.ngx_pool_cleanup_t;
pub const ngx_open_file_t = ngx.ngx_open_file_t;
pub const ngx_path_t = ngx.ngx_path_t;
pub const ngx_shm_zone_t = ngx.ngx_shm_zone_t;
pub const ngx_shm_t = ngx.ngx_shm_t;

pub const ngx_pfree = ngx.ngx_pfree;
pub const ngx_palloc = ngx.ngx_palloc;
pub const ngx_pcalloc = ngx.ngx_pcalloc;
pub const ngx_pnalloc = ngx.ngx_pnalloc;
pub const ngx_pmemalign = ngx.ngx_pmemalign;

pub const ngx_time = ngx.ngx_time;
pub const ngx_random = ngx.ngx_random;
pub const ngx_timeofday = ngx.ngx_timeofday;
pub const ngx_ptocidr = ngx.ngx_ptocidr;

pub const ngx_log_init = ngx.ngx_log_init;
pub const ngx_time_init = ngx.ngx_time_init;
pub const ngx_create_pool = ngx.ngx_create_pool;
pub const ngx_destroy_pool = ngx.ngx_destroy_pool;
pub const ngx_pool_cleanup_add = ngx.ngx_pool_cleanup_add;

pub const NError = error{
    OOM,
    SSL_ERROR,
    CONF_ERROR,
    FILE_ERROR,
    HASH_ERROR,
    JSON_ERROR,
    TIMER_ERROR,
    REQUEST_ERROR,
};

pub fn Pair(comptime T: type, comptime U: type) type {
    return struct {
        t: T,
        u: U,
    };
}

pub inline fn sizeof(comptime s: []const u8) usize {
    return s.len;
}

pub inline fn c_str(s: []const u8) [*c]u_char {
    return @constCast(s.ptr);
}

pub inline fn ngz_len(p0: [*c]u8, p1: [*c]u8) ngx_uint_t {
    return @intFromPtr(p1) - @intFromPtr(p0);
}

pub inline fn ngx_align(d: ngx_uint_t, comptime a: ngx_uint_t) ngx_uint_t {
    if (a < 1) {
        @compileError("cannot align to 0");
    }
    return (d + (a - 1)) & ~(a - 1);
}

pub inline fn nullptr(comptime T: type) [*c]T {
    return @as([*c]T, @ptrCast(@alignCast(NULL)));
}

pub inline fn slicify(comptime T: type, p: [*c]T, len: usize) []T {
    return p[0..len];
}

pub inline fn make_slice(comptime T: type, p: [*c]T, comptime validFn: fn ([*c]T) bool) []T {
    var len: usize = 0;
    var p0: [*c]T = p;
    while (validFn(p0)) : (len += 1) {
        p0 += 1;
    }
    return slicify(T, p, len);
}

pub inline fn nonNullPtr(comptime T: type, p: [*c]T) ?[*c]T {
    return if (p != nullptr(T)) p else null;
}

pub inline fn castPtr(comptime T: type, p: ?*anyopaque) ?[*c]T {
    const p0 = @as([*c]T, @ptrCast(@alignCast(p)));
    return nonNullPtr(T, p0);
}

pub inline fn ngz_pcalloc_c(comptime T: type, p: [*c]ngx_pool_t) ?[*c]T {
    if (ngx_pcalloc(p, @sizeOf(T))) |p0| {
        return @as([*c]T, @ptrCast(@alignCast(p0)));
    }
    return null;
}

pub inline fn ngz_pcalloc_n(N: ngx_uint_t, comptime T: type, p: [*c]ngx_pool_t) ?[*c]T {
    if (ngx_pcalloc(p, @sizeOf(T) * N)) |p0| {
        return @as([*c]T, @ptrCast(@alignCast(p0)));
    }
    return null;
}

pub inline fn ngz_pcalloc(comptime T: type, p: [*c]ngx_pool_t) ?*T {
    if (ngx_pcalloc(p, @sizeOf(T))) |p0| {
        return @as(*T, @ptrCast(@alignCast(p0)));
    }
    return null;
}

pub inline fn ngz_memcpy(dst: [*c]u8, src: [*c]u8, len: ngx_uint_t) void {
    @memcpy(slicify(u8, dst, len), slicify(u8, src, len));
}

test "core" {
    try expectEqual(sizeof("-2147483648"), 11);
    try expectEqual(sizeof("-9223372036854775808"), 20);
    try expectEqual(NGX_ALIGNMENT, 8);
    try expectEqual(ngx_align(5, 1), 5);
    try expectEqual(ngx_align(5, 4), 8);
    try expectEqual(ngx_align(6, 4), 8);
    try expectEqual(ngx_align(8, 8), 8);
    try expectEqual(ngx_align(10, 8), 16);
    try expectEqual(ngx_align(798, 1024), 1024);
    try expectEqual(ngx_align(1025, 1024), 2048);
    try expectEqual(ngx_align(1025, 4096), 4096);
    try expectEqual(ngx_align(4100, 4096), 4096 * 2);

    try expectEqual(@sizeOf(c_uint), 4);
    try expectEqual(@sizeOf([4]c_uint), 16);
    try expectEqual(@sizeOf(ngx_dir_t), 168);
    try expectEqual(@sizeOf(ngx_process_t), 48);
    try expectEqual(@sizeOf(ngx_int_t), 8);
    try expectEqual(@sizeOf(ngx_uint_t), 8);
    try expectEqual(@sizeOf(ngx_msec_t), 8);
    try expectEqual(@sizeOf(ngx_pool_t), 80);
    try expectEqual(@sizeOf(ngx_cycle_t), 688);

    try expectEqual(@sizeOf(ngx_output_chain_ctx_t), 128);
    try expectEqual(@sizeOf(ngx_listening_t), 336);
    try expectEqual(@sizeOf(ngx_connection_t), 248);
    try expectEqual(@sizeOf(ngx_ext_rename_file_t), 40);
    try expectEqual(@sizeOf(ngx_url_t), 224);
    try expectEqual(@sizeOf(ngx_open_file_info_t), 104);
    try expectEqual(@sizeOf(ngx_cached_open_file_t), 144);
    try expectEqual(@sizeOf(ngx_resolver_node_t), 184);
    try expectEqual(@sizeOf(ngx_resolver_t), 512);
    try expectEqual(@sizeOf(ngx_resolver_ctx_t), 224);
    try expectEqual(@sizeOf(ngx_slab_pool_t), 200);
    try expectEqual(@sizeOf(ngx_variable_value_t), 16);
    try expectEqual(@sizeOf(ngx_syslog_peer_t), 456);
    try expectEqual(@sizeOf(ngx_event_t), 96);
    try expectEqual(@sizeOf(ngx_peer_connection_t), 152);
    try expectEqual(@sizeOf(ngx_event_pipe_t), 304);
}

pub fn PointerIterator(comptime T: type) type {
    return struct {
        const Self = @This();
        p: [*:0]T,
        i: usize = 0,

        pub fn init(p: [*c]T) Self {
            return Self{
                .p = @ptrCast(p),
            };
        }

        pub fn next(self: *Self) ?T {
            defer self.i += 1;
            return if (self.p[self.i] != 0) self.p[self.i] else null;
        }
    };
}

pub fn NAllocator(comptime PAGE_SIZE: ngx_uint_t) type {
    return extern struct {
        const Self = @This();
        fba: ?*anyopaque,
        pool: [*c]ngx_pool_t,

        pub fn init(p: [*c]ngx_pool_t) !Self {
            if (ngz_pcalloc(std.heap.FixedBufferAllocator, p)) |fba| {
                if (castPtr(u8, ngx_pmemalign(p, PAGE_SIZE, NGX_ALIGNMENT))) |buf| {
                    fba.* = std.heap.FixedBufferAllocator.init(slicify(u8, buf, PAGE_SIZE));
                    return Self{ .fba = @ptrCast(@alignCast(fba)), .pool = p };
                }
            }
            return NError.OOM;
        }

        pub fn deinit(self: *Self) void {
            const fba = @as(*std.heap.FixedBufferAllocator, @ptrCast(@alignCast(self.fba)));
            _ = ngx_pfree(self.pool, fba.buffer.ptr);
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self.fba.?,
                .vtable = &.{
                    .remap = remap,
                    .alloc = alloc,
                    .resize = resize,
                    .free = free,
                },
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            var fba: *std.heap.FixedBufferAllocator = @ptrCast(@alignCast(ctx));
            return fba.allocator().rawAlloc(len, ptr_align, ret_addr);
        }

        fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            var fba: *std.heap.FixedBufferAllocator = @ptrCast(@alignCast(ctx));
            return fba.allocator().rawResize(buf, buf_align, new_len, ret_addr);
        }

        fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
            var fba: *std.heap.FixedBufferAllocator = @ptrCast(@alignCast(ctx));
            return fba.allocator().rawFree(buf, buf_align, ret_addr);
        }

        fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            var fba: *std.heap.FixedBufferAllocator = @ptrCast(@alignCast(ctx));
            return fba.allocator().rawRemap(buf, buf_align, new_len, ret_addr);
        }
    };
}

/// Adapt an nginx pool to containers that take a Zig allocator. Small frees
/// follow nginx pool lifetime; large allocations can be released immediately.
pub fn poolAllocator(pool: [*c]ngx_pool_t) std.mem.Allocator {
    return .{ .ptr = @ptrCast(pool), .vtable = &PoolAllocator.vtable };
}

const PoolAllocator = struct {
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const pool: *ngx_pool_t = @ptrCast(@alignCast(ctx));
        const bytes = if (alignment.toByteUnits() <= NGX_ALIGNMENT)
            ngx_palloc(pool, len)
        else
            ngx_pmemalign(pool, len, alignment.toByteUnits());
        return @ptrCast(bytes);
    }

    fn resize(_: *anyopaque, bytes: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        return new_len <= bytes.len;
    }

    fn remap(_: *anyopaque, bytes: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
        return if (new_len <= bytes.len) bytes.ptr else null;
    }

    fn free(ctx: *anyopaque, bytes: []u8, _: std.mem.Alignment, _: usize) void {
        _ = ngx_pfree(@ptrCast(@alignCast(ctx)), bytes.ptr);
    }
};

extern fn inet_pton(family: c_int, text: [*:0]const u8, address: *anyopaque) c_int;

pub const IpAddress = union(enum) {
    ip4: [4]u8,
    ip6: [16]u8,

    /// libc parses a single address, without accepting CIDR suffixes or ports.
    pub fn parse(text: []const u8) ?IpAddress {
        var storage: [46]u8 = undefined;
        if (text.len == 0 or text.len >= storage.len or std.mem.indexOfScalar(u8, text, 0) != null) return null;
        @memcpy(storage[0..text.len], text);
        storage[text.len] = 0;
        const terminated: [*:0]const u8 = @ptrCast(&storage);
        var v4: [4]u8 = undefined;
        if (inet_pton(std.posix.AF.INET, terminated, &v4) == 1) return .{ .ip4 = v4 };
        var v6: [16]u8 = undefined;
        if (inet_pton(std.posix.AF.INET6, terminated, &v6) == 1) return .{ .ip6 = v6 };
        return null;
    }

    pub fn inCidr(self: IpAddress, cidr: ngx_cidr_t) bool {
        return switch (self) {
            .ip4 => |bytes| cidr.family == std.posix.AF.INET and (@as(u32, @bitCast(bytes)) & cidr.u.in.mask) == cidr.u.in.addr,
            .ip6 => |bytes| blk: {
                if (cidr.family != std.posix.AF.INET6) break :blk false;
                for (bytes, cidr.u.in6.mask.__in6_u.__u6_addr8, cidr.u.in6.addr.__in6_u.__u6_addr8) |byte, mask, addr| {
                    if (byte & mask != addr) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

test "allocator" {
    const log = ngx_log_init(c_str(""), c_str(""));
    ngx_time_init();

    const pool = ngx_create_pool(1024, log);
    defer ngx_destroy_pool(pool);

    var fba = try NAllocator(1024).init(pool);
    defer fba.deinit();
    const allocator = fba.allocator();

    var as = ArrayList(usize).init(allocator);
    for (0..10) |i| {
        try as.append(i);
    }
    try expectEqual(as.items.len, 10);
}

test "pool allocator grows containers and honors alignment" {
    const logger = ngx_log_init(c_str(""), c_str(""));
    const pool = ngx_create_pool(4096, logger) orelse return error.OutOfMemory;
    defer ngx_destroy_pool(pool);
    const allocator = poolAllocator(pool);
    var values = std.ArrayList(u32).empty;
    defer values.deinit(allocator);
    for (0..10000) |i| try values.append(allocator, @intCast(i));
    for (values.items, 0..) |value, i| try expectEqual(@as(u32, @intCast(i)), value);
    const aligned = try allocator.alignedAlloc(u8, .@"64", 8192);
    defer allocator.free(aligned);
    try expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % 64);
    const terminated = try allocator.dupeZ(u8, "pool string");
    defer allocator.free(terminated);
    try std.testing.expectEqualStrings("pool string", std.mem.span(terminated.ptr));
}

test "libc address parsing and nginx CIDR masks" {
    const Case = struct { address: []const u8, network: []const u8, matches: bool };
    for ([_]Case{
        .{ .address = "192.0.2.42", .network = "192.0.2.0/24", .matches = true },
        .{ .address = "192.0.3.42", .network = "192.0.2.0/24", .matches = false },
        .{ .address = "192.0.2.42", .network = "192.0.2.42/32", .matches = true },
        .{ .address = "192.0.2.42", .network = "0.0.0.0/0", .matches = true },
        .{ .address = "2001:db8::42", .network = "2001:db8::/32", .matches = true },
        .{ .address = "2001:db9::42", .network = "2001:db8::/32", .matches = false },
        .{ .address = "::1", .network = "::1/128", .matches = true },
        .{ .address = "::1", .network = "::/0", .matches = true },
        .{ .address = "::ffff:192.0.2.42", .network = "::ffff:192.0.2.0/120", .matches = true },
        .{ .address = "::ffff:192.0.2.42", .network = "192.0.2.0/24", .matches = false },
    }) |case| {
        const address = IpAddress.parse(case.address) orelse return error.InvalidAddress;
        var network = ngx_str_t{ .data = @constCast(case.network.ptr), .len = case.network.len };
        var cidr = std.mem.zeroes(ngx_cidr_t);
        try expectEqual(NGX_OK, ngx_ptocidr(&network, &cidr));
        try expectEqual(case.matches, address.inCidr(cidr));
    }
    for ([_][]const u8{ "", "127.1", "256.0.0.1", "127.0.0.1/8", "127.0.0.1:80", "[::1]", "::1\x00junk", "not-an-ip" }) |invalid| {
        try std.testing.expect(IpAddress.parse(invalid) == null);
    }
}
