const std = @import("std");
const ngx = @import("ngx.zig");
const core = @import("ngx_core.zig");
const expectEqual = std.testing.expectEqual;

const u_char = core.u_char;
pub const ngx_str_t = core.ngx_str_t;
pub const ngx_keyval_t = ngx.ngx_keyval_t;

pub inline fn ngx_string(str: []const u8) ngx_str_t {
    return ngx_str_t{ .len = str.len, .data = @constCast(str.ptr) };
}

pub inline fn ngx_string_from_ptr(p0: [*c]u8, p1: [*c]u8) ngx_str_t {
    return ngx_str_t{ .data = p0, .len = core.ngz_len(p0, p1) };
}

pub inline fn make_slice(s: ngx_str_t) []u8 {
    return core.slicify(u8, s.data, s.len);
}

pub inline fn ngx_string_from_pool(p: [*c]u8, l: usize, pool: [*c]core.ngx_pool_t) !ngx_str_t {
    if (core.castPtr(u8, core.ngx_pnalloc(pool, l))) |p0| {
        core.ngz_memcpy(p0, p, l);
        return ngx_str_t{ .data = p0, .len = l };
    }
    return core.NError.OOM;
}

pub fn ngx_cstring_from_pool(ss: []ngx_str_t, pool: [*c]core.ngx_pool_t) ![][*c]u8 {
    var len: usize = 0;
    for (ss) |s| {
        len += s.len;
    }
    len += ss.len;
    std.debug.assert(len > 0);
    if (core.castPtr(u8, core.ngx_pnalloc(pool, len))) |p0| {
        if (core.ngz_pcalloc_n(ss.len, [*c]u8, pool)) |ps| {
            for (ss, 0..) |s, i| {
                ps[i] = p0;
                core.ngz_memcpy(p0, s.data, s.len);
                p0[s.len] = 0;
                p0 += s.len + 1;
            }
            return core.slicify([*c]u8, ps, ss.len);
        }
    }
    return core.NError.OOM;
}

pub fn concat_string_from_pool(ss: []const ngx_str_t, by: []const u8, pool: [*c]core.ngx_pool_t) !ngx_str_t {
    var len: usize = 0;
    for (ss) |s| {
        len += s.len;
        len += by.len;
    }
    if (len == 0) {
        return ngx_null_str;
    }

    len = len - by.len;
    if (core.castPtr(u8, core.ngx_pnalloc(pool, len))) |p0| {
        var pi: [*c]u8 = p0;
        var i: usize = 0;
        while (pi < p0 + len) : (i += 1) {
            core.ngz_memcpy(pi, ss[i].data, ss[i].len);
            pi += ss[i].len;
            if (i + 1 < ss.len) {
                core.ngz_memcpy(pi, @constCast(by.ptr), by.len);
                pi += by.len;
            }
        }
        return ngx_str_t{ .data = p0, .len = len };
    }
    return core.NError.OOM;
}

pub const ngx_null_str = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };

pub inline fn ngx_str_set(str: [*c]ngx_str_t, text: []const u8) void {
    str.*.len = text.len;
    str.*.data = text.ptr;
}

pub inline fn ngx_str_null(str: [*c]ngx_str_t) void {
    str.*.len = 0;
    str.*.data = core.nullptr(u8);
}

pub inline fn ngx_tolower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c | 0x20 else c;
}

pub inline fn ngx_toupper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c & ~@as(u8, 0x20) else c;
}

pub inline fn eql(s0: ngx_str_t, s1: ngx_str_t) bool {
    return std.mem.eql(u8, core.slicify(u8, s0.data, s0.len), core.slicify(u8, s1.data, s1.len));
}

pub inline fn strlen(s: [*c]u8) usize {
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    return len;
}

pub inline fn ngx_strlchr(p: [*c]u_char, last: [*c]u_char, c: u_char) [*c]u_char {
    var vp: [*c]u_char = p;
    while (vp < last) : (vp += 1) {
        if (vp.* == c) {
            return vp;
        }
    }
    return core.nullptr(u_char);
}

const ngx_log_init = ngx.ngx_log_init;
const ngx_create_pool = ngx.ngx_create_pool;
const ngx_destroy_pool = ngx.ngx_destroy_pool;
test "ngx_toupper" {
    for ('a'..'z' + 1) |c| {
        const upper = ngx_toupper(@intCast(c));
        try expectEqual(upper, @as(u8, @intCast(c)) & ~@as(u8, 0x20));
    }
    try expectEqual(ngx_toupper('A'), 'A');
    try expectEqual(ngx_toupper('0'), '0');
    try expectEqual(ngx_toupper(' '), ' ');
}

test "string" {
    try expectEqual(@sizeOf(ngx_str_t), 16);
    const log = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(1024, log);
    defer ngx_destroy_pool(pool);

    const ss = [_]ngx_str_t{ ngx_string("abc"), ngx_string("123") };

    const s0 = try concat_string_from_pool(ss[0..], " ", pool);
    try expectEqual(eql(s0, ngx_string("abc 123")), true);

    const s1 = try concat_string_from_pool(ss[0..], "", pool);
    try expectEqual(eql(s1, ngx_string("abc123")), true);

    const s2 = try concat_string_from_pool(ss[0..], ",", pool);
    try expectEqual(eql(s2, ngx_string("abc,123")), true);
}

pub const ngx_strlow = ngx.ngx_strlow;
pub const ngx_hex_dump = ngx.ngx_hex_dump;
pub const ngx_escape_uri = ngx.ngx_escape_uri;
pub const ngx_unescape_uri = ngx.ngx_unescape_uri;
pub const ngx_encode_base64 = ngx.ngx_encode_base64;
pub const ngx_decode_base64 = ngx.ngx_decode_base64;

pub const ngx_sprintf = ngx.ngx_sprintf;
pub const ngx_snprintf = ngx.ngx_snprintf;
pub const ngx_slprintf = ngx.ngx_slprintf;
pub const ngx_vslprintf = ngx.ngx_vslprintf;
