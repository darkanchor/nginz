const std = @import("std");
const ngx = @import("ngx");
const CJSON = ngx.cjson.CJSON;

// Parsing is only for validation/key selection. Never reserialize the signed body.
pub fn requestEnv(pool: [*c]ngx.core.ngx_pool_t, body: []const u8) !u1 {
    var cj = CJSON.init(pool);
    const obj = cj.decodeStrict(ngx.string.ngx_string(body)) catch |err| return switch (err) {
        error.JSON_ERROR => error.InvalidRequest,
        else => err,
    };
    if (CJSON.objValue(obj) == null) return error.InvalidRequest;
    for ([_][:0]const u8{ "access_token", "pay_sig", "signature" }) |field| {
        if (ngx.cjson.cJSON_GetObjectItemCaseSensitive(obj, field.ptr) != null) return error.InvalidRequest;
    }
    const env = CJSON.numberLiteral(ngx.cjson.cJSON_GetObjectItemCaseSensitive(obj, "env")) orelse return error.InvalidRequest;
    if (std.mem.eql(u8, env, "0")) return 0;
    if (std.mem.eql(u8, env, "1")) return 1;
    return error.InvalidRequest;
}

pub fn sign(key: []const u8, path: []const u8, body: []const u8) ![64]u8 {
    const digest = try ngx.ssl.hmacSha256(key, &.{ path, "&", body });
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn escapeToken(token: []const u8, out: []u8) []u8 {
    const hex = "0123456789ABCDEF";
    var i: usize = 0;
    for (token) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            out[i] = c;
            i += 1;
        } else {
            out[i] = '%';
            out[i + 1] = hex[c >> 4];
            out[i + 2] = hex[c & 15];
            i += 3;
        }
    }
    return out[0..i];
}

pub fn validPath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/xpay/") or path.len == 6) return false;
    for (path[6..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

pub fn validOrigin(origin: []const u8) bool {
    const host = if (std.mem.startsWith(u8, origin, "https://")) origin[8..] else if (std.mem.startsWith(u8, origin, "http://")) origin[7..] else return false;
    if (host.len == 0) return false;
    var parts = std.mem.splitScalar(u8, host, ':');
    const name = parts.next().?;
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '.') return false;
    }
    if (parts.next()) |port| {
        for (port) |c| if (!std.ascii.isDigit(c)) return false;
        if ((std.fmt.parseInt(u16, port, 10) catch return false) == 0) return false;
    }
    return parts.next() == null;
}

test "strict XPay environment and authentication fields" {
    const log = ngx.core.ngx_log_init(ngx.core.c_str(""), ngx.core.c_str(""));
    const pool = ngx.core.ngx_create_pool(4096, log) orelse return error.OutOfMemory;
    defer ngx.core.ngx_destroy_pool(pool);
    try std.testing.expectEqual(@as(u1, 0), try requestEnv(pool, "{\"env\":0,\"text\":\"中文\"}"));
    try std.testing.expectEqual(@as(u1, 1), try requestEnv(pool, "{\"env\":1}"));
    for ([_][]const u8{
        "",                      "{}",                          "[]",                            "null",                            "{\"env\":0}junk",                    "{\"env\":0}\x00",
        "{\"env\":0.0}",         "{\"env\":1e0}",               "{\"env\":-0}",                  "{\"env\":2}",                     "{\"env\":true}",                     "{\"env\":\"0\"}",
        "{\"env\":0,\"env\":1}", "{\"env\":0,\"e\\u006ev\":0}", "{\"env\":0,\"pay_sig\":\"x\"}", "{\"env\":0,\"signature\":\"x\"}", "{\"env\":0,\"access_token\":\"x\"}",
    }) |body| try std.testing.expectError(error.InvalidRequest, requestEnv(pool, body));
}
