const std = @import("std");
const ngx = @import("ngx");

const ssl = ngx.ssl;
const core = ngx.core;
const http = ngx.http;
const cjson = ngx.cjson;
const CJSON = cjson.CJSON;

const ngx_str_t = core.ngx_str_t;
const ngx_pool_t = core.ngx_pool_t;
const ngx_http_request_t = http.ngx_http_request_t;

fn extract_header_value(r: [*c]ngx_http_request_t, header_name: []const u8) ?[]const u8 {
    if (r == null) return null;

    const headers_list = &r.*.headers_in.headers;
    var part = &headers_list.*.part;

    var search_limit: usize = 100;
    while (search_limit > 0) : (search_limit -= 1) {
        const elts = core.castPtr(ngx.hash.ngx_table_elt_t, part.*.elts) orelse {
            if (part.*.next) |next_part| {
                part = next_part;
                continue;
            } else break;
        };

        var i: usize = 0;
        while (i < part.*.nelts) : (i += 1) {
            const elt = elts[i];
            if (elt.key.len > 0 and elt.key.data != core.nullptr(u8)) {
                const key = core.slicify(u8, elt.key.data, elt.key.len);
                if (std.mem.eql(u8, key, header_name) or std.ascii.eqlIgnoreCase(key, header_name)) {
                    if (elt.value.len > 0 and elt.value.data != core.nullptr(u8)) {
                        return core.slicify(u8, elt.value.data, elt.value.len);
                    }
                }
            }
        }

        if (part.*.next) |next_part| {
            part = next_part;
        } else break;
    }

    return null;
}

pub fn extract_jwt_token(r: [*c]ngx_http_request_t) ?[]const u8 {
    if (extract_header_value(r, "authorization")) |auth_header| {
        const bearer_prefix = "Bearer ";
        if (auth_header.len > bearer_prefix.len and std.mem.eql(u8, auth_header[0..bearer_prefix.len], bearer_prefix)) {
            return auth_header[bearer_prefix.len..];
        }
    }
    return null;
}

pub fn base64url_decode(input: []const u8, output: []u8) ?usize {
    const b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    var out_idx: usize = 0;
    var bits: u32 = 0;
    var bit_count: u32 = 0;

    for (input) |c| {
        const val: u32 = for (b64_chars, 0..) |bc, i| {
            if (bc == c) break @intCast(i);
        } else return null;

        bits = (bits << 6) | val;
        bit_count += 6;

        if (bit_count >= 8) {
            bit_count -= 8;
            if (out_idx >= output.len) return null;
            output[out_idx] = @truncate(bits >> @intCast(bit_count));
            out_idx += 1;
        }
    }

    return out_idx;
}

pub fn hmac_sha256(key: []const u8, data: []const u8, output: *[32]u8) bool {
    const ctx = ssl.HMAC_CTX_new() orelse return false;
    defer ssl.HMAC_CTX_free(ctx);

    if (ssl.HMAC_Init_ex(ctx, key.ptr, @intCast(key.len), ssl.EVP_sha256(), null) != 1) return false;
    if (ssl.HMAC_Update(ctx, data.ptr, data.len) != 1) return false;

    var len: c_uint = 32;
    if (ssl.HMAC_Final(ctx, output, &len) != 1) return false;
    return len == 32;
}

pub const JwtValidationError = enum {
    invalid_format,
    invalid_signature,
    expired,
    not_yet_valid,
};

fn validate_jwt_structure(token: []const u8) bool {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return false;
    if (first_dot == 0) return false;
    const rest = token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
    if (second_dot == 0) return false;
    if (std.mem.indexOfScalar(u8, rest[second_dot + 1 ..], '.') != null) return false;
    if (rest[second_dot + 1 ..].len == 0) return false;
    return true;
}

fn validate_jwt_claims(pool: [*c]ngx_pool_t, token: []const u8) ?JwtValidationError {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return .invalid_format;
    const rest = token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return .invalid_format;
    const payload_b64 = rest[0..second_dot];

    var payload_buf: [4096]u8 = undefined;
    const payload_len = base64url_decode(payload_b64, &payload_buf) orelse return .invalid_format;
    if (payload_len < 2 or payload_buf[0] != '{') return .invalid_format;

    var cj = CJSON.init(pool);
    const json = cj.decode(ngx_str_t{ .data = @constCast(payload_buf[0..payload_len].ptr), .len = payload_len }) catch return .invalid_format;
    defer cj.free(json);

    const now = @as(i64, @intCast(core.ngx_time()));

    if (CJSON.query(json, "$.exp")) |node| {
        if (CJSON.intValue(node)) |exp| {
            if (now > exp) return .expired;
        }
    }

    if (CJSON.query(json, "$.iat")) |node| {
        if (CJSON.intValue(node)) |iat| {
            if (now < iat) return .not_yet_valid;
        }
    }

    if (CJSON.query(json, "$.nbf")) |node| {
        if (CJSON.intValue(node)) |nbf| {
            if (now < nbf) return .not_yet_valid;
        }
    }

    return null;
}

pub fn validate_jwt_hs256(token: []const u8, secret: []const u8) bool {
    if (!validate_jwt_structure(token)) return false;

    const first_dot = std.mem.indexOfScalar(u8, token, '.').?;
    const rest = token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.').?;

    const header_payload = token[0 .. first_dot + 1 + second_dot];
    const signature_b64 = rest[second_dot + 1 ..];

    var signature: [256]u8 = undefined;
    const sig_len = base64url_decode(signature_b64, &signature) orelse return false;
    if (sig_len != 32) return false;

    var expected: [32]u8 = undefined;
    if (!hmac_sha256(secret, header_payload, &expected)) return false;

    var diff: u8 = 0;
    for (0..32) |i| diff |= signature[i] ^ expected[i];
    return diff == 0;
}

pub fn validate_jwt_token(pool: [*c]ngx_pool_t, token: []const u8, secret: []const u8) ?JwtValidationError {
    if (!validate_jwt_structure(token)) return .invalid_format;

    if (secret.len > 0) {
        if (!validate_jwt_hs256(token, secret)) return .invalid_signature;
    }

    return validate_jwt_claims(pool, token);
}

pub fn extract_jwt_role(pool: [*c]ngx_pool_t, jwt_token: []const u8, role_claim: []const u8) ?[]const u8 {
    const first_dot = std.mem.indexOfScalar(u8, jwt_token, '.') orelse return null;
    const rest = jwt_token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    const payload_b64 = rest[0..second_dot];

    var payload_buf: [4096]u8 = undefined;
    const payload_len = base64url_decode(payload_b64, &payload_buf) orelse return null;
    const payload = payload_buf[0..payload_len];

    var cj = CJSON.init(pool);
    const json = cj.decode(ngx_str_t{ .data = @constCast(payload.ptr), .len = payload.len }) catch return null;
    defer cj.free(json);

    var query_buf: [128]u8 = undefined;
    const query = std.fmt.bufPrint(&query_buf, "$.{s}", .{role_claim}) catch return null;
    const role_node = CJSON.query(json, query) orelse return null;
    const role_str = CJSON.stringValue(role_node) orelse return null;
    return core.slicify(u8, role_str.data, role_str.len);
}

pub fn build_reset_role_query(query_buf: []u8) ?usize {
    const q = "RESET ROLE";
    if (q.len + 1 > query_buf.len) return null;
    @memcpy(query_buf[0..q.len], q);
    query_buf[q.len] = 0;
    return q.len;
}

pub fn build_clear_jwt_query(query_buf: []u8) ?usize {
    const q = "SET request.jwt TO ''";
    if (q.len + 1 > query_buf.len) return null;
    @memcpy(query_buf[0..q.len], q);
    query_buf[q.len] = 0;
    return q.len;
}

pub fn build_set_postgresql_jwt_claim_query(jwt_token: []const u8, query_buf: []u8) ?usize {
    if (jwt_token.len == 0) return null;

    var pos: usize = 0;
    const set_prefix = "SET request.jwt TO '";
    if (set_prefix.len + jwt_token.len + 4 > query_buf.len) return null;
    @memcpy(query_buf[pos..][0..set_prefix.len], set_prefix);
    pos += set_prefix.len;

    for (jwt_token) |c| {
        if (pos >= query_buf.len - 2) return null;
        if (c == '\'') {
            if (pos >= query_buf.len - 3) return null;
            query_buf[pos] = '\'';
            pos += 1;
            query_buf[pos] = '\'';
            pos += 1;
        } else {
            query_buf[pos] = c;
            pos += 1;
        }
    }

    if (pos >= query_buf.len - 1) return null;
    query_buf[pos] = '\'';
    pos += 1;
    query_buf[pos] = 0;
    return pos;
}

/// Build a combined multi-statement query for the JWT/role setup phase.
/// The result is RESET ROLE; SET request.jwt TO '<token or empty>'; [SET ROLE '<role>';]
/// This replaces up to three sequential round-trips with a single query.
pub fn build_combined_jwt_setup_query(query_buf: []u8, jwt_token: ?[]const u8, role_to_set: ?[]const u8) ?usize {
    var pos: usize = 0;

    // RESET ROLE;
    const reset = "RESET ROLE; ";
    if (reset.len > query_buf.len - pos) return null;
    @memcpy(query_buf[pos..][0..reset.len], reset);
    pos += reset.len;

    // SET request.jwt TO '...';
    const jwt_prefix = "SET request.jwt TO '";
    if (jwt_prefix.len > query_buf.len - pos) return null;
    @memcpy(query_buf[pos..][0..jwt_prefix.len], jwt_prefix);
    pos += jwt_prefix.len;

    if (jwt_token) |token| {
        for (token) |c| {
            if (pos >= query_buf.len - 3) return null;
            if (c == '\'') {
                query_buf[pos] = '\'';
                pos += 1;
                query_buf[pos] = '\'';
                pos += 1;
            } else {
                query_buf[pos] = c;
                pos += 1;
            }
        }
    }

    if (pos >= query_buf.len - 3) return null;
    query_buf[pos] = '\'';
    pos += 1;
    query_buf[pos] = ';';
    pos += 1;
    query_buf[pos] = ' ';
    pos += 1;

    // SET ROLE '...'; (conditional)
    if (role_to_set) |role| {
        const role_prefix = "SET ROLE '";
        if (role_prefix.len > query_buf.len - pos) return null;
        @memcpy(query_buf[pos..][0..role_prefix.len], role_prefix);
        pos += role_prefix.len;

        for (role) |c| {
            if (pos >= query_buf.len - 3) return null;
            if (c == '\'') {
                query_buf[pos] = '\'';
                pos += 1;
                query_buf[pos] = '\'';
                pos += 1;
            } else {
                query_buf[pos] = c;
                pos += 1;
            }
        }

        if (pos >= query_buf.len - 2) return null;
        query_buf[pos] = '\'';
        pos += 1;
        query_buf[pos] = ';';
        pos += 1;
    }

    query_buf[pos] = 0;
    return pos;
}

pub fn build_set_postgresql_role_query(role: []const u8, query_buf: []u8) ?usize {
    if (role.len == 0) return null;

    var pos: usize = 0;
    const set_prefix = "SET ROLE '";
    if (set_prefix.len + role.len + 4 > query_buf.len) return null;
    @memcpy(query_buf[pos..][0..set_prefix.len], set_prefix);
    pos += set_prefix.len;

    for (role) |c| {
        if (pos >= query_buf.len - 2) return null;
        if (c == '\'') {
            if (pos >= query_buf.len - 3) return null;
            query_buf[pos] = '\'';
            pos += 1;
            query_buf[pos] = '\'';
            pos += 1;
        } else {
            query_buf[pos] = c;
            pos += 1;
        }
    }

    if (pos >= query_buf.len - 1) return null;
    query_buf[pos] = '\'';
    pos += 1;
    query_buf[pos] = 0;
    return pos;
}

test "build_combined_jwt_setup_query without token or role" {
    var buf: [256]u8 = undefined;
    const len = build_combined_jwt_setup_query(&buf, null, null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("RESET ROLE; SET request.jwt TO ''; ", buf[0..len]);
    try std.testing.expectEqual(@as(u8, 0), buf[len]);
}

test "build_combined_jwt_setup_query with token but no role" {
    var buf: [256]u8 = undefined;
    const len = build_combined_jwt_setup_query(&buf, "abc.def.ghi", null) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("RESET ROLE; SET request.jwt TO 'abc.def.ghi'; ", buf[0..len]);
    try std.testing.expectEqual(@as(u8, 0), buf[len]);
}

test "build_combined_jwt_setup_query with token and role" {
    var buf: [256]u8 = undefined;
    const len = build_combined_jwt_setup_query(&buf, "abc.def.ghi", "admin") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("RESET ROLE; SET request.jwt TO 'abc.def.ghi'; SET ROLE 'admin';", buf[0..len]);
    try std.testing.expectEqual(@as(u8, 0), buf[len]);
}

test "build_combined_jwt_setup_query escapes single quotes" {
    var buf: [256]u8 = undefined;
    const len = build_combined_jwt_setup_query(&buf, "it's", "d'min") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("RESET ROLE; SET request.jwt TO 'it''s'; SET ROLE 'd''min';", buf[0..len]);
    try std.testing.expectEqual(@as(u8, 0), buf[len]);
}

test "build_combined_jwt_setup_query fails on undersized buffer" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), build_combined_jwt_setup_query(&buf, "abc.def.ghi", "admin"));
}

test "build_reset_role_query produces RESET ROLE" {
    var buf: [64]u8 = undefined;
    const len = build_reset_role_query(&buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("RESET ROLE", buf[0..len]);
    try std.testing.expectEqual(@as(u8, 0), buf[len]);
}

test "build_clear_jwt_query produces SET request.jwt TO empty" {
    var buf: [64]u8 = undefined;
    const len = build_clear_jwt_query(&buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("SET request.jwt TO ''", buf[0..len]);
    try std.testing.expectEqual(@as(u8, 0), buf[len]);
}

test "build_reset_role_query fails on undersized buffer" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), build_reset_role_query(&buf));
}

test "auth base64url decode handles jwt alphabet" {
    var out: [8]u8 = undefined;
    const len = base64url_decode("SGVsbG8", &out) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Hello", out[0..len]);
}

test "validate_jwt_structure rejects malformed tokens" {
    try std.testing.expect(!validate_jwt_structure(""));
    try std.testing.expect(!validate_jwt_structure("nodots"));
    try std.testing.expect(!validate_jwt_structure("one.two"));
    try std.testing.expect(!validate_jwt_structure("one.two.three.extra"));
    try std.testing.expect(!validate_jwt_structure(".two.three"));
    try std.testing.expect(!validate_jwt_structure("one..three"));
    try std.testing.expect(!validate_jwt_structure("one.two."));
    try std.testing.expect(validate_jwt_structure("eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYWRtaW4ifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"));
}
