const std = @import("std");
const ngx = @import("ngx");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const cjson = ngx.cjson;
const ssl = ngx.ssl;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;
const NGX_HTTP_UNAUTHORIZED = http.NGX_HTTP_UNAUTHORIZED;

const ngx_str_t = core.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;

const ngx_string = ngx.string.ngx_string;
const NArray = ngx.array.NArray;
const CJSON = cjson.CJSON;
const file = ngx.file;
const log = ngx.log;

extern var ngx_http_core_module: ngx_module_t;
extern fn time(t: ?*i64) i64;

// ── OpenSSL bindings (existing from ssl module) ───────────────────────

const HMAC_CTX = ssl.HMAC_CTX;
const HMAC_CTX_new = ssl.HMAC_CTX_new;
const HMAC_CTX_free = ssl.HMAC_CTX_free;
const HMAC_Init_ex = ssl.HMAC_Init_ex;
const HMAC_Update = ssl.HMAC_Update;
const HMAC_Final = ssl.HMAC_Final;
const EVP_sha256 = ssl.EVP_sha256;

const EVP_PKEY = ssl.EVP_PKEY;
const EVP_PKEY_free = ssl.EVP_PKEY_free;
const EVP_MD_CTX = ssl.EVP_MD_CTX;
const EVP_MD_CTX_new = ssl.EVP_MD_CTX_new;
const EVP_MD_CTX_free = ssl.EVP_MD_CTX_free;
const EVP_DigestVerifyInit = ssl.EVP_DigestVerifyInit;
const EVP_DigestVerifyUpdate = ssl.EVP_DigestVerifyUpdate;
const EVP_DigestVerifyFinal = ssl.EVP_DigestVerifyFinal;

const BIO = ssl.BIO;
const BIO_new_mem_buf = ssl.BIO_new_mem_buf;
const BIO_free = ssl.BIO_free;
const PEM_read_bio_PUBKEY = ssl.PEM_read_bio_PUBKEY;
const BN_bn2bin = ssl.BN_bn2bin;
const BN_num_bytes = ssl.BN_num_bytes;

// ── Missing OpenSSL bindings (declared locally) ───────────────────────

extern fn EVP_sha384() ?*const ssl.EVP_MD;
extern fn EVP_sha512() ?*const ssl.EVP_MD;

// ── C file I/O (for BIO key loading, PEM_read_bio needs BIO from raw buffer) ──

// ── Supported algorithms ──────────────────────────────────────────────

const Algorithm = enum(u8) {
    HS256,
    HS384,
    HS512,
    RS256,
    RS384,
    RS512,
};

const JwtKey = extern struct {
    kid: ngx_str_t, // key ID (from JWKS kid or keyval object key)
    alg: Algorithm, // algorithm for this key
    pkey: ?*EVP_PKEY, // loaded public key (RSA/ECDSA), null for HMAC
    secret: ngx_str_t, // HMAC secret (for HS256/384/512)
};

const MAX_KEYS = 16;

const jwt_loc_conf = extern struct {
    enabled: ngx_flag_t,
    // Legacy inline secret (backwards compatible)
    secret: ngx_str_t,
    // File-based keys
    key_file: ngx_str_t,
    key_format: ngx_uint_t, // 0=jwks, 1=keyval
    // Loaded key set
    keys_count: ngx_uint_t,
    keys: [MAX_KEYS]JwtKey,
};

// ── Base64URL decode ──────────────────────────────────────────────────

fn base64url_decode(input: []const u8, output: []u8) ?usize {
    if (input.len == 0) return 0;

    var temp: [4096]u8 = undefined;
    if (input.len > temp.len) return null;

    var temp_len: usize = 0;
    for (input) |c| {
        temp[temp_len] = switch (c) {
            '-' => '+',
            '_' => '/',
            else => c,
        };
        temp_len += 1;
    }

    while (temp_len % 4 != 0) {
        temp[temp_len] = '=';
        temp_len += 1;
    }

    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var out_idx: usize = 0;
    var i: usize = 0;

    while (i + 4 <= temp_len) : (i += 4) {
        const a = std.mem.indexOfScalar(u8, alphabet, temp[i]) orelse return null;
        const b = std.mem.indexOfScalar(u8, alphabet, temp[i + 1]) orelse return null;
        const c_val: usize = if (temp[i + 2] == '=') 0 else std.mem.indexOfScalar(u8, alphabet, temp[i + 2]) orelse return null;
        const d_val: usize = if (temp[i + 3] == '=') 0 else std.mem.indexOfScalar(u8, alphabet, temp[i + 3]) orelse return null;

        if (out_idx >= output.len) return null;
        output[out_idx] = @truncate((a << 2) | (b >> 4));
        out_idx += 1;

        if (temp[i + 2] != '=') {
            if (out_idx >= output.len) return null;
            output[out_idx] = @truncate(((b & 0x0f) << 4) | (c_val >> 2));
            out_idx += 1;
        }
        if (temp[i + 3] != '=') {
            if (out_idx >= output.len) return null;
            output[out_idx] = @truncate(((c_val & 0x03) << 6) | d_val);
            out_idx += 1;
        }
    }

    return out_idx;
}

// ── Constant-time comparison ──────────────────────────────────────────

fn const_time_eq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

// ── HMAC verification (HS256/384/512) ────────────────────────────────

fn hmac_verify(data: []const u8, signature: []const u8, secret: []const u8, md: ?*const ssl.EVP_MD, expected_len: usize) bool {
    if (signature.len != expected_len) return false;

    const ctx = HMAC_CTX_new() orelse return false;
    defer HMAC_CTX_free(ctx);

    if (HMAC_Init_ex(ctx, secret.ptr, @intCast(secret.len), md, null) != 1) return false;
    if (HMAC_Update(ctx, data.ptr, data.len) != 1) return false;

    var computed: [64]u8 = undefined; // max SHA-512 = 64 bytes
    var len: c_uint = @intCast(expected_len);
    if (HMAC_Final(ctx, &computed, &len) != 1) return false;

    return const_time_eq(computed[0..expected_len], signature);
}

// ── RSA verification (RS256/384/512) ──────────────────────────────────

fn rsa_verify(data: []const u8, signature: []const u8, pkey: ?*EVP_PKEY, md: *const ssl.EVP_MD) bool {
    const ctx = EVP_MD_CTX_new() orelse return false;
    defer EVP_MD_CTX_free(ctx);

    if (EVP_DigestVerifyInit(ctx, null, md, null, pkey) != 1) return false;
    if (EVP_DigestVerifyUpdate(ctx, data.ptr, data.len) != 1) return false;
    return EVP_DigestVerifyFinal(ctx, signature.ptr, signature.len) == 1;
}

// ── Algorithm dispatch table (comptime lookup) ────────────────────────

const JwtSigInfo = struct {
    md: ?*const ssl.EVP_MD, // null for HMAC (uses HMAC_* API directly)
    sig_len: usize, // expected signature length in bytes
    is_rsa: bool,
};

fn algo_info(alg: Algorithm) JwtSigInfo {
    return switch (alg) {
        .HS256 => .{ .md = null, .sig_len = 32, .is_rsa = false },
        .HS384 => .{ .md = null, .sig_len = 48, .is_rsa = false },
        .HS512 => .{ .md = null, .sig_len = 64, .is_rsa = false },
        .RS256 => .{ .md = EVP_sha256(), .sig_len = 256, .is_rsa = true },
        .RS384 => .{ .md = EVP_sha384(), .sig_len = 384, .is_rsa = true },
        .RS512 => .{ .md = EVP_sha512(), .sig_len = 512, .is_rsa = true },
    };
}

fn algo_from_str(s: []const u8) ?Algorithm {
    const algs = [_]struct { []const u8, Algorithm }{
        .{ "HS256", .HS256 },
        .{ "HS384", .HS384 },
        .{ "HS512", .HS512 },
        .{ "RS256", .RS256 },
        .{ "RS384", .RS384 },
        .{ "RS512", .RS512 },
    };
    for (algs) |entry| {
        if (std.mem.eql(u8, s, entry[0])) return entry[1];
    }
    return null;
}

// ── HMAC digest function by algorithm ────────────────────────────────

fn hmac_md_for(alg: Algorithm) ?*const ssl.EVP_MD {
    return switch (alg) {
        .HS256 => EVP_sha256(),
        .HS384 => EVP_sha384(),
        .HS512 => EVP_sha512(),
        else => EVP_sha256(), // unreachable for HMAC
    };
}

// ── Key matching by kid ───────────────────────────────────────────────

fn find_key_by_kid(lccf: [*c]jwt_loc_conf, kid: []const u8) ?*JwtKey {
    for (lccf.*.keys[0..lccf.*.keys_count]) |*key| {
        const k = core.slicify(u8, key.kid.data, key.kid.len);
        if (std.mem.eql(u8, k, kid)) return key;
    }
    return null;
}

// ── Load PEM public key ───────────────────────────────────────────────

fn load_pubkey_from_pem(pem: []const u8) ?*EVP_PKEY {
    // BIO_new_mem_buf doesn't modify the buffer but takes non-const
    const bio = BIO_new_mem_buf(pem.ptr, @intCast(pem.len)) orelse return null;
    defer _ = BIO_free(bio);

    return PEM_read_bio_PUBKEY(bio, null, null, null);
}

// ── Load keys from keyval JSON file ───────────────────────────────────

fn load_keys_keyval(data: []u8, pool: [*c]core.ngx_pool_t, keys: *[MAX_KEYS]JwtKey, count: *ngx_uint_t) bool {
    var cj = CJSON.init(pool);
    const root = cj.decode(ngx_str_t{ .data = data.ptr, .len = data.len }) catch return false;
    defer cj.free(root);

    // Use CJSON.Iterator for proper object traversal
    var it = CJSON.Iterator.init(root);
    while (it.next()) |val_node| {
        if (count.* >= MAX_KEYS) break;

        // val_node is the value; val_node.*.string is the key name
        if (val_node.*.string == null) continue;
        const kid = ngx_str_t{ .data = val_node.*.string, .len = ngx.string.strlen(val_node.*.string) };

        // Get value as string
        const val_str = CJSON.stringValue(val_node) orelse continue;
        const val_slice = core.slicify(u8, val_str.data, val_str.len);

        if (std.mem.startsWith(u8, val_slice, "-----BEGIN")) {
            const pkey = load_pubkey_from_pem(val_slice) orelse continue;
            keys[count.*] = JwtKey{
                .kid = kid,
                .alg = .RS256,
                .pkey = pkey,
                .secret = ngx.string.ngx_null_str,
            };
        } else {
            keys[count.*] = JwtKey{
                .kid = kid,
                .alg = .HS256,
                .pkey = null,
                .secret = val_str,
            };
        }
        count.* += 1;
    }
    return count.* > 0;
}

// ── Load keys from JWKS JSON file ─────────────────────────────────────

fn load_keys_jwks(data: []u8, pool: [*c]core.ngx_pool_t, keys: *[MAX_KEYS]JwtKey, count: *ngx_uint_t) bool {
    var cj = CJSON.init(pool);
    const root = cj.decode(ngx_str_t{ .data = data.ptr, .len = data.len }) catch return false;
    defer cj.free(root);

    // Look for "keys" array
    const keys_node = CJSON.query(root, "$.keys") orelse return false;
    var entry = keys_node.*.child;
    while (entry != null and count.* < MAX_KEYS) : (entry = entry.*.next) {
        const kty_node = CJSON.query(entry, "$.kty") orelse {
            entry = entry.*.next;
            continue;
        };
        const kty = CJSON.stringValue(kty_node) orelse {
            entry = entry.*.next;
            continue;
        };
        const kty_slice = core.slicify(u8, kty.data, kty.len);

        // Get kid
        var kid_str = ngx.string.ngx_null_str;
        if (CJSON.query(entry, "$.kid")) |kid_node| {
            if (CJSON.stringValue(kid_node)) |k| {
                kid_str = k;
            }
        }

        // Get alg
        var alg: Algorithm = .HS256;
        if (CJSON.query(entry, "$.alg")) |alg_node| {
            if (CJSON.stringValue(alg_node)) |a| {
                alg = algo_from_str(core.slicify(u8, a.data, a.len)) orelse .HS256;
            }
        }

        if (std.mem.eql(u8, kty_slice, "oct")) {
            // HMAC key: extract "k" field (base64url-encoded secret)
            if (CJSON.query(entry, "$.k")) |k_node| {
                if (CJSON.stringValue(k_node)) |k_val| {
                    var secret_buf: [256]u8 = undefined;
                    const k_slice = core.slicify(u8, k_val.data, k_val.len);
                    if (base64url_decode(k_slice, &secret_buf)) |secret_len| {
                        // Allocate secret in config pool
                        if (core.castPtr(u8, core.ngx_pnalloc(pool, secret_len))) |secret_copy| {
                            @memcpy(core.slicify(u8, secret_copy, secret_len), secret_buf[0..secret_len]);
                            keys[count.*] = JwtKey{
                                .kid = kid_str,
                                .alg = alg,
                                .pkey = null,
                                .secret = ngx_str_t{ .data = secret_copy, .len = secret_len },
                            };
                            count.* += 1;
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, kty_slice, "RSA")) {
            // RSA key: for now skip (needs BN_bin2bn + RSA_new)
            // TODO: implement when RSA construction bindings are available
        }
    }
    return count.* > 0;
}

// ── Load key file ─────────────────────────────────────────────────────

fn load_key_file(cf: [*c]ngx_conf_t, lccf: [*c]jwt_loc_conf) bool {
    if (lccf.*.key_file.len == 0) return false;

    // Resolve path relative to config file directory
    var resolved = lccf.*.key_file;
    if (conf.ngx_conf_full_name(cf.*.cycle, &resolved, 1) != core.NGX_OK) {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "jwt: failed to resolve key file path", .{});
        return false;
    }

    // Use nginx's file reader (following waf module pattern)
    const content = file.ngz_open_file(resolved, cf.*.log, cf.*.pool) catch {
        log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "jwt: failed to open key file: %V", .{&resolved});
        return false;
    };
    const data = core.slicify(u8, content.data, content.len);

    lccf.*.keys_count = 0;

    if (lccf.*.key_format == 1) {
        return load_keys_keyval(data, cf.*.pool, &lccf.*.keys, &lccf.*.keys_count);
    } else {
        return load_keys_jwks(data, cf.*.pool, &lccf.*.keys, &lccf.*.keys_count);
    }
}

// ── Validate JWT signature (unified dispatch) ─────────────────────────

fn validate_jwt_signature(token: []const u8, lccf: [*c]jwt_loc_conf, pool: [*c]core.ngx_pool_t) bool {
    // Split token into header.payload.signature
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return false;
    const rest = token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;

    // Decode header
    const header_b64 = token[0..first_dot];
    var header_json: [1024]u8 = undefined;
    const header_len = base64url_decode(header_b64, &header_json) orelse return false;

    var cj = CJSON.init(pool);
    const header = cj.decode(ngx_str_t{ .data = header_json[0..header_len].ptr, .len = header_len }) catch return false;
    defer cj.free(header);

    // Extract and validate algorithm
    const alg_node = CJSON.query(header, "$.alg") orelse return false;
    const alg_str = CJSON.stringValue(alg_node) orelse return false;
    const alg = algo_from_str(core.slicify(u8, alg_str.data, alg_str.len)) orelse return false;

    // Select key: try kid match first, fall back to first key
    var key: ?*JwtKey = null;
    if (CJSON.query(header, "$.kid")) |kid_node| {
        if (CJSON.stringValue(kid_node)) |kid_val| {
            key = find_key_by_kid(lccf, core.slicify(u8, kid_val.data, kid_val.len));
        }
    }
    if (key == null and lccf.*.keys_count > 0) {
        key = @as(?*JwtKey, @ptrCast(&lccf.*.keys[0]));
    }
    if (key == null) return false;

    const sig_info = algo_info(alg);

    // Verify algorithm type matches key type (RSA key → RSA alg, HMAC key → HMAC alg)
    if (sig_info.is_rsa != (key.?.pkey != null)) return false;
    const header_payload = token[0 .. first_dot + 1 + second_dot];
    const signature_b64 = rest[second_dot + 1 ..];

    // Decode signature
    var signature: [512]u8 = undefined;
    const sig_len = base64url_decode(signature_b64, &signature) orelse return false;

    // Dispatch to verifier
    if (sig_info.is_rsa) {
        if (key.?.pkey == null) return false;
        return rsa_verify(header_payload, signature[0..sig_len], key.?.pkey, sig_info.md.?);
    } else {
        const secret = core.slicify(u8, key.?.secret.data, key.?.secret.len);
        return hmac_verify(header_payload, signature[0..sig_len], secret, hmac_md_for(alg), sig_info.sig_len);
    }
}

// ── Legacy HMAC validation (backwards compat with jwt_secret) ────────
// Supports HS256, HS384, HS512 by reading alg from token header.

fn validate_jwt_legacy_hmac(token: []const u8, secret: []const u8, pool: [*c]core.ngx_pool_t) bool {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return false;
    const rest = token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;

    const header_b64 = token[0..first_dot];
    var header: [1024]u8 = undefined;
    const header_len = base64url_decode(header_b64, &header) orelse return false;

    var cj = CJSON.init(pool);
    const header_json = cj.decode(ngx_str_t{ .data = header[0..header_len].ptr, .len = header_len }) catch return false;
    defer cj.free(header_json);

    const alg_node = CJSON.query(header_json, "$.alg") orelse return false;
    const alg_str = CJSON.stringValue(alg_node) orelse return false;
    const alg = algo_from_str(core.slicify(u8, alg_str.data, alg_str.len)) orelse return false;

    // Only HMAC algorithms are valid with inline secret
    if (algo_info(alg).is_rsa) return false;

    const sig_info = algo_info(alg);
    const header_payload = token[0 .. first_dot + 1 + second_dot];
    const signature_b64 = rest[second_dot + 1 ..];

    var signature: [512]u8 = undefined;
    const sig_len = base64url_decode(signature_b64, &signature) orelse return false;

    return hmac_verify(header_payload, signature[0..sig_len], secret, hmac_md_for(alg), sig_info.sig_len);
}

// ── Expiration check ──────────────────────────────────────────────────

fn check_expiration(payload_json: []const u8, pool: [*c]core.ngx_pool_t) bool {
    var cj = CJSON.init(pool);
    const json = cj.decode(ngx_str_t{ .data = @constCast(payload_json.ptr), .len = payload_json.len }) catch return false;
    defer cj.free(json);

    if (CJSON.query(json, "$.exp")) |exp_node| {
        if (CJSON.intValue(exp_node)) |exp| {
            if (exp < time(null)) return false;
        }
    }
    if (CJSON.query(json, "$.nbf")) |nbf_node| {
        if (CJSON.intValue(nbf_node)) |nbf| {
            if (nbf > time(null)) return false;
        }
    }
    return true;
}

// ── Extract Bearer token ──────────────────────────────────────────────

fn extract_bearer_token(r: [*c]ngx_http_request_t) ?[]const u8 {
    const auth_header = r.*.headers_in.authorization orelse return null;
    const value = core.slicify(u8, auth_header.*.value.data, auth_header.*.value.len);
    if (value.len < 7) return null;
    const prefix = value[0..7];
    if (!std.ascii.eqlIgnoreCase(prefix, "Bearer ")) return null;
    return value[7..];
}

// ── Split token into dot-separated parts ──────────────────────────────

fn split_jwt(token: []const u8) ?struct { header_b64: []const u8, payload_b64: []const u8, sig_b64: []const u8 } {
    const d1 = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    const rest = token[d1 + 1 ..];
    const d2 = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    return .{
        .header_b64 = token[0..d1],
        .payload_b64 = rest[0..d2],
        .sig_b64 = rest[d2 + 1 ..],
    };
}

// ── Access handler ────────────────────────────────────────────────────

export fn ngx_http_jwt_access_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        jwt_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_jwt_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) return NGX_DECLINED;

    const token = extract_bearer_token(r) orelse return NGX_HTTP_UNAUTHORIZED;

    // Prefer key-file based validation, fall back to legacy secret
    if (lccf.*.keys_count > 0) {
        if (!validate_jwt_signature(token, lccf, r.*.pool)) {
            return NGX_HTTP_UNAUTHORIZED;
        }
    } else if (lccf.*.secret.len > 0) {
        const secret = core.slicify(u8, lccf.*.secret.data, lccf.*.secret.len);
        if (!validate_jwt_legacy_hmac(token, secret, r.*.pool)) {
            return NGX_HTTP_UNAUTHORIZED;
        }
    } else {
        return NGX_DECLINED;
    }

    // Decode payload and check expiration
    const parts = split_jwt(token) orelse return NGX_HTTP_UNAUTHORIZED;
    var payload: [4096]u8 = undefined;
    const payload_len = base64url_decode(parts.payload_b64, &payload) orelse return NGX_HTTP_UNAUTHORIZED;
    if (!check_expiration(payload[0..payload_len], r.*.pool)) {
        return NGX_HTTP_UNAUTHORIZED;
    }

    return NGX_OK;
}

// ── Config functions ──────────────────────────────────────────────────

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(jwt_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = 0;
        p.*.secret = ngx.string.ngx_null_str;
        p.*.key_file = ngx.string.ngx_null_str;
        p.*.key_format = 1; // default: keyval
        p.*.keys_count = 0;
        return p;
    }
    return null;
}

fn merge_loc_conf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cf;
    const prev = core.castPtr(jwt_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(jwt_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.enabled == 0) c.*.enabled = prev.*.enabled;
    if (c.*.secret.len == 0) c.*.secret = prev.*.secret;
    if (c.*.key_file.len == 0) c.*.key_file = prev.*.key_file;
    if (c.*.key_format == 1 and prev.*.key_format != 1) c.*.key_format = prev.*.key_format;

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_jwt_secret(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        lccf.*.enabled = 1;
        var index: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index)) |arg| {
            lccf.*.secret = arg.*;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_jwt_key_file(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        lccf.*.enabled = 1;

        var index: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index)) |arg| {
            lccf.*.key_file = arg.*;
        }
        // Parse optional format argument
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index)) |fmt_arg| {
            const fmt = core.slicify(u8, fmt_arg.*.data, fmt_arg.*.len);
            if (std.mem.eql(u8, fmt, "jwks")) {
                lccf.*.key_format = 0;
            } else if (std.mem.eql(u8, fmt, "keyval")) {
                lccf.*.key_format = 1;
            }
        }
        // Load keys from file at config time
        if (lccf.*.key_file.len > 0) {
            _ = load_key_file(cf, lccf);
        }
    }
    return conf.NGX_CONF_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    const cmcf = core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    var handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_ACCESS_PHASE].handlers,
    );
    const h = handlers.append() catch return NGX_ERROR;
    h.* = ngx_http_jwt_access_handler;

    return NGX_OK;
}

export const ngx_http_jwt_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_jwt_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("jwt_secret"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_jwt_secret,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_key_file"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE12,
        .set = ngx_conf_set_jwt_key_file,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_jwt_module = ngx.module.make_module(
    @constCast(&ngx_http_jwt_commands),
    @constCast(&ngx_http_jwt_module_ctx),
);

// ── Tests ─────────────────────────────────────────────────────────────

const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "jwt module" {}

test "base64url_decode" {
    var output: [256]u8 = undefined;
    const len = base64url_decode("SGVsbG8", &output) orelse 0;
    try expectEqual(len, 5);
    try expectEqual(output[0..5].*, "Hello".*);
}

test "algo_from_str all supported" {
    try expect(algo_from_str("HS256") != null);
    try expect(algo_from_str("HS384") != null);
    try expect(algo_from_str("HS512") != null);
    try expect(algo_from_str("RS256") != null);
    try expect(algo_from_str("RS384") != null);
    try expect(algo_from_str("RS512") != null);
    try expect(algo_from_str("ES256") == null);
    try expect(algo_from_str("none") == null);
}

test "algo_info sig lengths" {
    try expectEqual(algo_info(.HS256).sig_len, 32);
    try expectEqual(algo_info(.HS384).sig_len, 48);
    try expectEqual(algo_info(.HS512).sig_len, 64);
    try expect(algo_info(.RS256).is_rsa);
    try expect(!algo_info(.HS256).is_rsa);
}

test "const_time_eq" {
    try expect(const_time_eq("abc", "abc"));
    try expect(!const_time_eq("abc", "abd"));
    try expect(!const_time_eq("abc", "ab"));
    try expect(!const_time_eq("ab", "abc"));
}

test "split_jwt" {
    const parts = split_jwt("a.b.c") orelse unreachable;
    try expectEqual(parts.header_b64.len, 1);
    try expectEqual(parts.payload_b64.len, 1);
    try expectEqual(parts.sig_b64.len, 1);

    try expect(split_jwt("no.dots") == null);
    try expect(split_jwt("only.one.dot") == null);
}
