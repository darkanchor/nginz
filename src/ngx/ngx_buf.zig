const std = @import("std");
const ngx = @import("ngx.zig");
const core = @import("ngx_core.zig");
const array = @import("ngx_array.zig");
const file = @import("ngx_file.zig");
const string = @import("ngx_string.zig");
const expectEqual = std.testing.expectEqual;

pub const ngx_buf_t = ngx.ngx_buf_t;
pub const ngx_chain_t = ngx.ngx_chain_t;
pub const ngx_buf_tag_t = ngx.ngx_buf_tag_t;
pub const ngx_chain_writer_ctx_t = ngx.ngx_chain_writer_ctx_t;

const off_t = core.off_t;
const u_char = core.u_char;
const ngx_str_t = core.ngx_str_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_pool_t = core.ngx_pool_t;
const NArray = array.NArray;

pub inline fn ngx_buf_in_memory(b: [*c]ngx_buf_t) bool {
    return b.*.flags.temporary or b.*.flags.memory or b.*.flags.mmap;
}

pub inline fn ngx_buf_in_memory_only(b: [*c]ngx_buf_t) bool {
    return ngx_buf_in_memory(b) and !b.*.flags.in_file;
}

pub inline fn ngx_buf_special(b: [*c]ngx_buf_t) bool {
    return (b.*.flags.flush or b.*.flags.last_buf or b.*.flags.sync) and !ngx_buf_in_memory(b) and !b.*.flags.in_file;
}

pub inline fn ngx_buf_sync_only(b: [*c]ngx_buf_t) bool {
    return b.*.flags.sync and !ngx_buf_in_memory(b) and !b.*.flags.in_file and !b.*.flags.flush and !b.*.flags.last_buf;
}

pub inline fn ngx_buf_size(b: [*c]ngx_buf_t) off_t {
    return if (ngx_buf_in_memory(b)) @as(off_t, @intCast(b.*.last - b.*.pos)) else b.*.file_last - b.*.file_pos;
}

pub inline fn ngx_alloc_buf(pool: [*c]ngx_pool_t) ?[*c]ngx_buf_t {
    return core.ngz_pcalloc_c(ngx_buf_t, pool);
}

pub inline fn ngx_free_chain(pool: [*c]ngx_pool_t, cl: [*c]ngx_chain_t) void {
    cl.*.next = pool.*.chain;
    pool.*.chain = cl;
}

pub const ngx_create_temp_buf = ngx.ngx_create_temp_buf;
pub const ngx_alloc_chain_link = ngx.ngx_alloc_chain_link;
pub const ngx_chain_update_chains = ngx.ngx_chain_update_chains;
pub const ngx_chain_get_free_buf = ngx.ngx_chain_get_free_buf;

pub inline fn ngz_chain_length(cl: [*c]ngx_chain_t) ngx_uint_t {
    var total: ngx_uint_t = 0;
    var n: [*c]ngx_chain_t = cl;
    while (n != NChain.NP) {
        if (n.*.buf != core.nullptr(ngx_buf_t) and !ngx_buf_special(n.*.buf)) {
            const chunk_len = ngx_buf_size(n.*.buf);
            if (chunk_len > 0) {
                total += @intCast(chunk_len);
            }
        }
        n = n.*.next;
    }
    return total;
}

pub inline fn ngz_chain_iterate(cl: [*c][*c]ngx_chain_t) ?[*c]ngx_buf_t {
    if (cl.* == core.nullptr(ngx_chain_t)) {
        return null;
    }
    defer cl.* = cl.*.*.next;
    return cl.*.*.buf;
}

pub inline fn ngz_chain_content(cl: [*c]ngx_chain_t, p: [*c]ngx_pool_t) !ngx_str_t {
    const len = ngz_chain_length(cl);
    if (len == 0) {
        return string.ngx_null_str;
    }
    if (core.castPtr(u8, core.ngx_pnalloc(p, len))) |b| {
        var ll = cl;
        var i: usize = 0;
        var s = core.slicify(u8, b, len);
        while (ngz_chain_iterate(&ll)) |bf| {
            if (bf == core.nullptr(ngx_buf_t) or ngx_buf_special(bf)) {
                continue;
            }

            const chunk_len_off = ngx_buf_size(bf);
            if (chunk_len_off < 0) {
                return core.NError.FILE_ERROR;
            }

            const chunk_len: usize = @intCast(chunk_len_off);
            if (chunk_len == 0) {
                continue;
            }

            if (ngx_buf_in_memory_only(bf)) {
                @memcpy(s[i .. i + chunk_len], core.slicify(u8, bf.*.pos, chunk_len));
                i += chunk_len;
                continue;
            }

            if (bf.*.flags.in_file and bf.*.file != core.nullptr(file.ngx_file_t)) {
                const read_len = file.ngx_read_file(bf.*.file, b + i, chunk_len, bf.*.file_pos);
                if (read_len == core.NGX_ERROR or @as(usize, @intCast(read_len)) != chunk_len) {
                    return core.NError.FILE_ERROR;
                }
                i += chunk_len;
                continue;
            }

            return core.NError.FILE_ERROR;
        }
        return ngx_str_t{ .data = b, .len = len };
    }
    return core.NError.OOM;
}

pub inline fn ngz_chain_last(cl: [*c]ngx_chain_t) [*c]ngx_chain_t {
    var c = cl;
    while (c.*.next != core.nullptr(ngx_chain_t)) {
        c = c.*.next;
    }
    return c;
}

// no copy
// ref ngx_http_upstream_non_buffered_filter
pub inline fn ngz_chain_append(cl: [*c]ngx_chain_t, p: [*c]ngx_pool_t) ![*c]ngx_buf_t {
    const last = ngz_chain_last(cl);
    if (core.nonNullPtr(ngx_chain_t, ngx_alloc_chain_link(p))) |ll| {
        if (core.ngz_pcalloc_c(ngx_buf_t, p)) |b| {
            b.*.flags.memory = true;
            b.*.flags.flush = true;
            ll.*.buf = b;
            ll.*.next = core.nullptr(ngx_chain_t);
            last.*.next = ll;
            return ll.*.buf;
        }
    }
    return core.NError.OOM;
}

pub const NChainIterator = extern struct {
    const Self = @This();
    const NP = core.nullptr(ngx_chain_t);

    chain: [*c]ngx_chain_t,

    pub fn init(c: [*c]ngx_chain_t) Self {
        return Self{
            .chain = c,
        };
    }

    pub fn next(self: *Self) ?[*c]ngx_buf_t {
        if (self.chain == core.nullptr(ngx_chain_t)) {
            return null;
        }
        defer self.chain = self.chain.*.next;
        return self.chain.*.buf;
    }
};

pub const NChain = extern struct {
    const Self = @This();
    const NP = core.nullptr(ngx_chain_t);

    pool: [*c]ngx_pool_t,

    pub fn init(p: [*c]ngx_pool_t) Self {
        return Self{ .pool = p };
    }

    pub fn create(self: *Self) ![*c]ngx_chain_t {
        const cl = ngx_alloc_chain_link(self.pool);
        if (cl != NP) {
            return cl;
        }
        return core.NError.OOM;
    }

    pub fn allocBuf(self: *Self, last: [*c]ngx_chain_t) ![*c]ngx_chain_t {
        if (core.nonNullPtr(ngx_chain_t, ngx_alloc_chain_link(self.pool))) |cl| {
            if (core.ngz_pcalloc_c(ngx_buf_t, self.pool)) |b| {
                b.*.flags.memory = true;
                cl.*.buf = b;
                cl.*.next = NP;
                last.*.next = cl;
                return cl;
            }
        }
        return core.NError.OOM;
    }

    pub fn allocStr(
        self: *Self,
        str: ngx_str_t,
        last: [*c]ngx_chain_t,
    ) ![*c]ngx_chain_t {
        if (str.len == 0) {
            return last;
        }
        if (core.ngz_pcalloc_c(ngx_chain_t, self.pool)) |cl| {
            if (core.ngz_pcalloc_c(ngx_buf_t, self.pool)) |b| {
                b.*.start = str.data;
                b.*.pos = str.data;
                b.*.end = str.data + str.len;
                b.*.last = str.data + str.len;
                b.*.flags.memory = true;

                cl.*.buf = b;
                cl.*.next = NP;
                last.*.next = cl;
                return cl;
            }
        }
        return core.NError.OOM;
    }

    // [last->next, last]
    pub fn allocNStr(
        self: *Self,
        as: NArray(ngx_str_t),
        last: [*c]ngx_chain_t,
    ) ![*c]ngx_chain_t {
        var cl: [*c]ngx_chain_t = last;
        var it = as.iterator();
        while (it.next()) |s| {
            cl = try self.allocStr(s.*, cl);
        }
        return cl;
    }

    pub fn alloc(
        self: *Self,
        size: ngx_uint_t,
        last: [*c]ngx_chain_t,
    ) ![*c]ngx_chain_t {
        if (core.ngz_pcalloc_c(ngx_chain_t, self.pool)) |cl0| {
            const b = ngx_create_temp_buf(self.pool, size);
            if (b != core.nullptr(ngx_buf_t)) {
                cl0.*.buf = b;
                cl0.*.next = NP;
                last.*.next = cl0;
                return cl0;
            }
        }
        return core.NError.OOM;
    }

    // [last->next .. last]
    pub fn allocN(
        self: *Self,
        size: ngx_uint_t,
        n: ngx_uint_t,
        last: [*c]ngx_chain_t,
    ) ![*c]ngx_chain_t {
        if (n > 0) {
            const cl: [*c]ngx_chain_t = try alloc(self, size, last);
            return allocN(self, size, n - 1, cl);
        }
        return last;
    }

    pub fn free(self: *Self, cl: [*c]ngx_chain_t) void {
        if (cl.*.buf != core.nullptr(ngx_buf_t)) cl.*.buf.*.last = cl.*.buf.*.pos;
        ngx_free_chain(self.pool, cl);
    }

    pub fn freeN(self: *Self, cl: [*c]ngx_chain_t) void {
        var last: [*c]ngx_chain_t = cl;
        while (last.*.next != NP) {
            if (last.*.buf != core.nullptr(ngx_buf_t)) last.*.buf.*.last = last.*.buf.*.pos;
            last = last.*.next;
        }
        last.*.next = self.pool.*.chain;
        self.pool.*.chain = cl;
    }
};

pub const NRingBuffer = extern struct {
    const Self = @This();

    buf: [*c]ngx_buf_t,
    //buf->pos is read pointer
    //buf->last is write pointer

    pub fn init(b: [*c]ngx_buf_t) Self {
        return Self{ .buf = b };
    }

    pub fn empty(self: *Self) bool {
        return self.buf.*.last == self.buf.*.pos;
    }

    pub fn size(self: *Self) ngx_uint_t {
        if (self.buf.*.last >= self.buf.*.pos) {
            return @intFromPtr(self.buf.*.last) - @intFromPtr(self.buf.*.pos);
        }
        const s0 = @intFromPtr(self.buf.*.end) - @intFromPtr(self.buf.*.pos);
        const s1 = @intFromPtr(self.buf.*.last) - @intFromPtr(self.buf.*.start);
        return s0 + s1;
    }

    pub fn full(self: *Self) bool {
        const s = @intFromPtr(self.buf.*.end) - @intFromPtr(self.buf.*.start);
        return size(self) == s;
    }

    pub fn space(self: *Self) ngx_uint_t {
        const s = @intFromPtr(self.buf.*.end) - @intFromPtr(self.buf.*.start);
        const s0 = size(self);
        return if (s > s0) s - s0 else 0;
    }

    pub fn write(self: *Self, p: [*c]u_char, len: ngx_uint_t) !void {
        if (len > space(self)) {
            return core.NError.OOM;
        }
        if (self.buf.*.last + len <= self.buf.*.end) {
            core.ngz_memcpy(self.buf.*.last, p, len);
            self.buf.*.last += len;
        } else {
            const part = @intFromPtr(self.buf.*.end) - @intFromPtr(self.buf.*.last);
            core.ngz_memcpy(self.buf.*.last, p, part);
            core.ngz_memcpy(self.buf.*.start, p + part, len - part);
            self.buf.*.last = self.buf.*.start + (len - part);
        }
    }

    pub fn read(self: *Self, p: [*c]u_char, len: ngx_uint_t) !void {
        if (len > size(self)) {
            return core.NError.OOM;
        }
        if (self.buf.*.pos + len <= self.buf.*.end) {
            core.ngz_memcpy(p, self.buf.*.pos, len);
            self.buf.*.pos += len;
        } else {
            const part = @intFromPtr(self.buf.*.end) - @intFromPtr(self.buf.*.pos);
            core.ngz_memcpy(p, self.buf.*.pos, part);
            core.ngz_memcpy(p + part, self.buf.*.start, len - part);
            self.buf.*.pos = self.buf.*.start + len - part;
        }
    }
};

test "buf" {
    try expectEqual(@sizeOf(ngx_buf_t), 80);
}
