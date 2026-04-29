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
const NGX_HTTP_PREACCESS_PHASE: usize = 5;

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
extern fn EVP_DigestVerify(ctx: ?*EVP_MD_CTX, sigret: [*c]const u8, siglen: usize, tbs: [*c]const u8, tbslen: usize) c_int;

const BIO = ssl.BIO;
const BIO_new_mem_buf = ssl.BIO_new_mem_buf;
const BIO_free = ssl.BIO_free;
const PEM_read_bio_PUBKEY = ssl.PEM_read_bio_PUBKEY;
const BN_bn2bin = ssl.BN_bn2bin;
const BN_num_bytes = ssl.BN_num_bytes;

// ── Missing OpenSSL bindings (declared locally) ───────────────────────

extern fn EVP_sha384() ?*const ssl.EVP_MD;
extern fn EVP_sha512() ?*const ssl.EVP_MD;
extern fn BN_bin2bn(s: [*c]const u8, len: c_int, ret: ?*ssl.BIGNUM) ?*ssl.BIGNUM;
extern fn BN_free(a: ?*ssl.BIGNUM) void;
extern fn RSA_new() ?*ssl.RSA;
extern fn RSA_free(r: ?*ssl.RSA) void;
extern fn RSA_set0_key(r: ?*ssl.RSA, n: ?*ssl.BIGNUM, e: ?*ssl.BIGNUM, d: ?*ssl.BIGNUM) c_int;
extern fn EVP_PKEY_new() ?*ssl.EVP_PKEY;
extern fn EVP_PKEY_set1_RSA(pkey: ?*ssl.EVP_PKEY, key: ?*ssl.RSA) c_int;

// ── C file I/O (for BIO key loading, PEM_read_bio needs BIO from raw buffer) ──

// ── Supported algorithms ──────────────────────────────────────────────

const Algorithm = enum(u8) {
    HS256, HS384, HS512,
    RS256, RS384, RS512,
    ES256, ES384, ES512, ES256K,
    PS256, PS384, PS512,
    EdDSA,
};

const JwtKey = extern struct {
    kid: ngx_str_t, // key ID (from JWKS kid or keyval object key)
    alg: Algorithm, // algorithm for this key
    pkey: ?*EVP_PKEY, // loaded public key (RSA/ECDSA), null for HMAC
    secret: ngx_str_t, // HMAC secret (for HS256/384/512)
};

const MAX_KEYS = 16;
const MAX_CLAIM_VARS = 8;
const MAX_REQUIRE_CLAIMS = 8;

const jwt_claim_var = extern struct {
    name: ngx_str_t, // claim/header name (e.g., "sub", "iss")
    var_index: ngx_uint_t, // nginx variable index
};

const jwt_claim_entry = extern struct {
    name: ngx_str_t,
    value: ngx_str_t,
};

const ClaimOp = enum(u8) {
    eq,  // equal (string comparison)
    neq, // not-equal (string comparison)
    gt,  // greater-than (numeric)
    lt,  // less-than (numeric)
    ge,  // greater-or-equal (numeric)
    le,  // less-or-equal (numeric)
};

const jwt_require_rule = extern struct {
    name: ngx_str_t, // claim name
    op: ClaimOp,
    value: ngx_str_t, // expected value as string
};

const jwt_loc_conf = extern struct {
    enabled: ngx_flag_t,
    explicit_disable: ngx_flag_t, // set by jwt_secret off to block inheritance
    // Legacy inline secret (backwards compatible)
    secret: ngx_str_t,
    // Token source: null = Authorization header, else nginx variable name
    token_var: ngx_str_t,
    // File-based keys
    key_file: ngx_str_t,
    key_format: ngx_uint_t, // 0=jwks, 1=keyval
    // Loaded key set
    keys_count: ngx_uint_t,
    keys: [MAX_KEYS]JwtKey,
    // Claim variable registrations
    claim_vars_count: ngx_uint_t,
    claim_vars: [MAX_CLAIM_VARS]jwt_claim_var,
    header_vars_count: ngx_uint_t,
    header_vars: [MAX_CLAIM_VARS]jwt_claim_var,
    // Header validation rules
    require_header_count: ngx_uint_t,
    require_header_rules: [MAX_REQUIRE_CLAIMS]jwt_require_rule,
    // Claim validation rules
    require_count: ngx_uint_t,
    require_rules: [MAX_REQUIRE_CLAIMS]jwt_require_rule,
    // Variable checks (jwt_require)
    require_var_count: ngx_uint_t,
    require_var_indices: [MAX_CLAIM_VARS]ngx_uint_t,
    // Revocation lists
    revocation_sub_file: ngx_str_t,
    revocation_kid_file: ngx_str_t,
    revoked_subs_count: ngx_uint_t,
    revoked_subs: [MAX_KEYS]ngx_str_t,
    revoked_kids_count: ngx_uint_t,
    revoked_kids: [MAX_KEYS]ngx_str_t,
    // Toggles
    validate_exp: ngx_flag_t,
    validate_sig: ngx_flag_t,
    leeway: ngx_int_t,
    phase: ngx_uint_t,
};

// Per-request JWT context (stored via ngx_http_get_module_ctx)
const jwt_ctx = extern struct {
    lccf: [*c]jwt_loc_conf,
    claims_json: ngx_str_t, // raw payload JSON (for $jwt_claims)
    claim_values_count: ngx_uint_t,
    claim_values: [MAX_CLAIM_VARS]jwt_claim_entry,
    header_values_count: ngx_uint_t,
    header_values: [MAX_CLAIM_VARS]jwt_claim_entry,
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

// ── RSA/EC/EdDSA verification (RS, ES, PS, EdDSA) ────────────────────

fn rsa_verify(data: []const u8, signature: []const u8, pkey: ?*EVP_PKEY, md: ?*const ssl.EVP_MD) bool {
    const ctx = EVP_MD_CTX_new() orelse return false;
    defer EVP_MD_CTX_free(ctx);
    if (EVP_DigestVerifyInit(ctx, null, md, null, pkey) != 1) return false;
    if (md == null) {
        return EVP_DigestVerify(ctx, signature.ptr, signature.len, data.ptr, data.len) == 1;
    }
    if (EVP_DigestVerifyUpdate(ctx, data.ptr, data.len) != 1) return false;
    return EVP_DigestVerifyFinal(ctx, signature.ptr, signature.len) == 1;
}

fn rsa_pss_verify(data: []const u8, signature: []const u8, pkey: ?*EVP_PKEY, md: ?*const ssl.EVP_MD) bool {
    const ctx = EVP_MD_CTX_new() orelse return false;
    defer EVP_MD_CTX_free(ctx);
    var pctx: ?*ssl.EVP_PKEY_CTX = null;
    if (EVP_DigestVerifyInit(ctx, &pctx, md, null, pkey) != 1) return false;
    if (pctx != null) {
        _ = ssl.EVP_PKEY_CTX_set_rsa_padding(pctx, ssl.RSA_PKCS1_PSS_PADDING);
        _ = ssl.EVP_PKEY_CTX_set_rsa_pss_saltlen(pctx, ssl.RSA_PSS_SALTLEN_DIGEST);
    }
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
        .ES256 => .{ .md = EVP_sha256(), .sig_len = 64, .is_rsa = true },
        .ES384 => .{ .md = EVP_sha384(), .sig_len = 96, .is_rsa = true },
        .ES512 => .{ .md = EVP_sha512(), .sig_len = 132, .is_rsa = true },
        .ES256K => .{ .md = EVP_sha256(), .sig_len = 64, .is_rsa = true },
        .PS256 => .{ .md = EVP_sha256(), .sig_len = 256, .is_rsa = true },
        .PS384 => .{ .md = EVP_sha384(), .sig_len = 384, .is_rsa = true },
        .PS512 => .{ .md = EVP_sha512(), .sig_len = 512, .is_rsa = true },
        .EdDSA => .{ .md = null, .sig_len = 64, .is_rsa = true },
    };
}

fn algo_from_str(s: []const u8) ?Algorithm {
    const algs = [_]struct { []const u8, Algorithm }{
        .{ "HS256", .HS256 }, .{ "HS384", .HS384 }, .{ "HS512", .HS512 },
        .{ "RS256", .RS256 }, .{ "RS384", .RS384 }, .{ "RS512", .RS512 },
        .{ "ES256", .ES256 }, .{ "ES384", .ES384 }, .{ "ES512", .ES512 },
        .{ "ES256K", .ES256K }, .{ "EdDSA", .EdDSA },
        .{ "PS256", .PS256 }, .{ "PS384", .PS384 }, .{ "PS512", .PS512 },
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

fn load_pubkey_from_rsa_jwk(n_b64: []const u8, e_b64: []const u8) ?*EVP_PKEY {
    var n_buf: [4096]u8 = undefined;
    const n_len = base64url_decode(n_b64, &n_buf) orelse return null;

    var e_buf: [64]u8 = undefined;
    const e_len = base64url_decode(e_b64, &e_buf) orelse return null;

    const rsa = RSA_new() orelse return null;
    errdefer RSA_free(rsa);

    const n_bn = BN_bin2bn(n_buf[0..n_len].ptr, @intCast(n_len), null) orelse return null;
    const e_bn = BN_bin2bn(e_buf[0..e_len].ptr, @intCast(e_len), null) orelse {
        BN_free(n_bn);
        return null;
    };

    if (RSA_set0_key(rsa, n_bn, e_bn, null) != 1) {
        BN_free(n_bn);
        BN_free(e_bn);
        return null;
    }

    const pkey = EVP_PKEY_new() orelse return null;
    if (EVP_PKEY_set1_RSA(pkey, rsa) != 1) {
        ssl.EVP_PKEY_free(pkey);
        return null;
    }

    RSA_free(rsa);
    return pkey;
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
        var alg: Algorithm = if (std.mem.eql(u8, kty_slice, "RSA")) .RS256 else .HS256;
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
            const n_node = CJSON.query(entry, "$.n") orelse continue;
            const e_node = CJSON.query(entry, "$.e") orelse continue;
            const n_val = CJSON.stringValue(n_node) orelse continue;
            const e_val = CJSON.stringValue(e_node) orelse continue;
            const pkey = load_pubkey_from_rsa_jwk(
                core.slicify(u8, n_val.data, n_val.len),
                core.slicify(u8, e_val.data, e_val.len),
            ) orelse continue;
            keys[count.*] = JwtKey{
                .kid = kid_str,
                .alg = alg,
                .pkey = pkey,
                .secret = ngx.string.ngx_null_str,
            };
            count.* += 1;
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
        // EdDSA: EVP_DigestVerify with NULL md handles EdDSA natively
        if (alg == .EdDSA) {
            return rsa_verify(header_payload, signature[0..sig_len], key.?.pkey, null);
        }
        // RSA-PSS: need PSS padding setup
        if (alg == .PS256 or alg == .PS384 or alg == .PS512) {
            return rsa_pss_verify(header_payload, signature[0..sig_len], key.?.pkey, sig_info.md.?);
        }
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

fn check_expiration(payload_json: []const u8, pool: [*c]core.ngx_pool_t, leeway: ngx_int_t) bool {
    var cj = CJSON.init(pool);
    const json = cj.decode(ngx_str_t{ .data = @constCast(payload_json.ptr), .len = payload_json.len }) catch return false;
    defer cj.free(json);

    const now = time(null);
    if (CJSON.query(json, "$.exp")) |exp_node| {
        if (CJSON.intValue(exp_node)) |exp| {
            if (exp + leeway < now) return false;
        }
    }
    if (CJSON.query(json, "$.nbf")) |nbf_node| {
        if (CJSON.intValue(nbf_node)) |nbf| {
            if (nbf - leeway > now) return false;
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

// ── Access handlers ───────────────────────────────────────────────────

fn jwt_validate_phase_request(r: [*c]ngx_http_request_t, lccf: [*c]jwt_loc_conf) ngx_int_t {

    // Extract token: prefer cookie/variable, fallback to Authorization header
    const token = if (lccf.*.token_var.len > 0) blk: {
        // Look up nginx variable
        const vn = lccf.*.token_var;
        const vk = http.ngx_http_get_variable_index(null, @constCast(&vn));
        if (vk != core.NGX_ERROR) {
            if (http.ngx_http_get_flushed_variable(r, @intCast(vk))) |vv| {
                if (vv.*.flags.valid and vv.*.flags.len > 0) {
                    break :blk core.slicify(u8, vv.*.data, @intCast(vv.*.flags.len));
                }
            }
        }
        break :blk null;
    } else extract_bearer_token(r);

    const token_slice = token orelse return NGX_HTTP_UNAUTHORIZED;

    // Validate signature (unless disabled)
    const vs: ngx_int_t = if (lccf.*.validate_sig == conf.NGX_CONF_UNSET) @as(ngx_int_t, 1) else lccf.*.validate_sig;
    if (vs != 0) {
        if (lccf.*.keys_count > 0) {
            if (!validate_jwt_signature(token_slice, lccf, r.*.pool)) {
                return NGX_HTTP_UNAUTHORIZED;
            }
        } else if (lccf.*.secret.len > 0) {
            const secret = core.slicify(u8, lccf.*.secret.data, lccf.*.secret.len);
            if (!validate_jwt_legacy_hmac(token_slice, secret, r.*.pool)) {
                return NGX_HTTP_UNAUTHORIZED;
            }
        } else {
            return NGX_DECLINED;
        }
    }

    // Decode payload
    const parts = split_jwt(token_slice) orelse return NGX_HTTP_UNAUTHORIZED;
    var payload: [4096]u8 = undefined;
    const payload_len = base64url_decode(parts.payload_b64, &payload) orelse return NGX_HTTP_UNAUTHORIZED;

    // Optional expiration check (jwt_validate_exp, default on)
    const ve: ngx_int_t = if (lccf.*.validate_exp == conf.NGX_CONF_UNSET) @as(ngx_int_t, 1) else lccf.*.validate_exp;
    if (ve != 0) {
        const leeway: ngx_int_t = if (lccf.*.leeway == conf.NGX_CONF_UNSET) @as(ngx_int_t, 0) else lccf.*.leeway;
        if (!check_expiration(payload[0..payload_len], r.*.pool, leeway)) {
            return NGX_HTTP_UNAUTHORIZED;
        }
    }

    // Enforce jwt_require_header rules (validate JOSE headers)
    if (lccf.*.require_header_count > 0) {
        var cj = CJSON.init(r.*.pool);
        // Decode header JSON for evaluation
        var header_json_buf: [1024]u8 = undefined;
        const header_json_len = base64url_decode(parts.header_b64, &header_json_buf) orelse return NGX_HTTP_UNAUTHORIZED;
        const header_json = cj.decode(ngx_str_t{ .data = header_json_buf[0..header_json_len].ptr, .len = header_json_len }) catch return NGX_HTTP_UNAUTHORIZED;
        defer cj.free(header_json);

        const rh: [*]const jwt_require_rule = @ptrCast(&lccf.*.require_header_rules);
        for (0..lccf.*.require_header_count) |i| {
            if (!eval_require_rule(header_json, &rh[i], r.*.pool)) {
                return NGX_HTTP_UNAUTHORIZED;
            }
        }
    }

    // Enforce jwt_require_claim rules
    if (lccf.*.require_count > 0) {
        var cj = CJSON.init(r.*.pool);
        const json = cj.decode(ngx_str_t{ .data = @constCast(payload[0..payload_len].ptr), .len = payload_len }) catch return NGX_HTTP_UNAUTHORIZED;
        defer cj.free(json);

        const rc: [*]const jwt_require_rule = @ptrCast(&lccf.*.require_rules);
        for (0..lccf.*.require_count) |i| {
            if (!eval_require_rule(json, &rc[i], r.*.pool)) {
                return NGX_HTTP_UNAUTHORIZED;
            }
        }
    }

    // Enforce jwt_require variable checks (after sig + claim validation)
    if (lccf.*.require_var_count > 0) {
        const ri: [*]const ngx_uint_t = @ptrCast(&lccf.*.require_var_indices);
        for (0..lccf.*.require_var_count) |i| {
            const vv = http.ngx_http_get_flushed_variable(r, ri[i]);
            if (vv == null or vv.*.flags.not_found or vv.*.flags.len == 0 or (vv.*.flags.len == 1 and vv.*.data[0] == '0')) {
                return NGX_HTTP_UNAUTHORIZED;
            }
        }
    }

    // Store claims and header values in request context for variable extraction
    const rctx = http.ngz_http_get_module_ctx(jwt_ctx, r, &ngx_http_jwt_module) catch return NGX_HTTP_UNAUTHORIZED;
    if (rctx.*.lccf == core.nullptr(jwt_loc_conf)) {
        rctx.*.lccf = lccf;
        // Copy payload JSON to pool for $jwt_claims variable
        if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, payload_len))) |json_copy| {
            @memcpy(core.slicify(u8, json_copy, payload_len), payload[0..payload_len]);
            rctx.*.claims_json = ngx_str_t{ .data = json_copy, .len = payload_len };
        }
        // Extract registered claim values
        if (lccf.*.claim_vars_count > 0) {
            populate_claims(rctx, payload[0..payload_len], lccf, r.*.pool);
        }
        if (lccf.*.header_vars_count > 0) {
            var header_json_buf: [1024]u8 = undefined;
            const header_json_len = base64url_decode(parts.header_b64, &header_json_buf) orelse return NGX_HTTP_UNAUTHORIZED;
            populate_headers(rctx, header_json_buf[0..header_json_len], lccf, r.*.pool);
        }
    }

    // Revocation check
    if (lccf.*.revoked_subs_count > 0 or lccf.*.revoked_kids_count > 0) {
        if (!check_revocations(r, lccf, parts.header_b64, parts.payload_b64)) return NGX_HTTP_UNAUTHORIZED;
    }

    return NGX_OK;
}

export fn ngx_http_jwt_preaccess_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        jwt_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_jwt_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) return NGX_DECLINED;
    const phase_is_preaccess = lccf.*.phase != conf.NGX_CONF_UNSET_UINT and lccf.*.phase == 1;
    if (!phase_is_preaccess) return NGX_DECLINED;

    return jwt_validate_phase_request(r, lccf);
}

export fn ngx_http_jwt_access_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        jwt_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_jwt_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) return NGX_DECLINED;
    const phase_is_preaccess = lccf.*.phase != conf.NGX_CONF_UNSET_UINT and lccf.*.phase == 1;
    if (phase_is_preaccess) return NGX_DECLINED;

    return jwt_validate_phase_request(r, lccf);
}

fn check_revocations(r: [*c]ngx_http_request_t, lccf: [*c]jwt_loc_conf, header_b64: []const u8, payload_b64: []const u8) bool {
    var payload: [4096]u8 = undefined;
    const payload_len = base64url_decode(payload_b64, &payload) orelse return false;
    var cj = CJSON.init(r.*.pool);
    if (lccf.*.revoked_subs_count > 0) {
        const json = cj.decode(ngx_str_t{ .data = @constCast(payload[0..payload_len].ptr), .len = payload_len }) catch return false;
        defer cj.free(json);
        if (CJSON.query(json, ".sub")) |sub_node| {
            if (CJSON.stringValue(sub_node)) |sub_val| {
                const s = core.slicify(u8, sub_val.data, sub_val.len);
                const rs: [*]const ngx_str_t = @ptrCast(&lccf.*.revoked_subs);
                for (0..lccf.*.revoked_subs_count) |i| {
                    if (std.mem.eql(u8, s, core.slicify(u8, rs[i].data, rs[i].len))) return false;
                }
            }
        }
    }
    if (lccf.*.revoked_kids_count > 0) {
        var header_json: [1024]u8 = undefined;
        const header_len = base64url_decode(header_b64, &header_json) orelse return false;
        const hdr = cj.decode(ngx_str_t{ .data = @constCast(header_json[0..header_len].ptr), .len = header_len }) catch return false;
        defer cj.free(hdr);
        if (CJSON.query(hdr, ".kid")) |kid_node| {
            if (CJSON.stringValue(kid_node)) |kid_val| {
                const s = core.slicify(u8, kid_val.data, kid_val.len);
                const rk: [*]const ngx_str_t = @ptrCast(&lccf.*.revoked_kids);
                for (0..lccf.*.revoked_kids_count) |i| {
                    if (std.mem.eql(u8, s, core.slicify(u8, rk[i].data, rk[i].len))) return false;
                }
            }
        } else return false;
    }
    return true;
}

// ── Config functions ──────────────────────────────────────────────────

fn create_jwt_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(jwt_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = 0;
        p.*.explicit_disable = 0;
        p.*.secret = ngx.string.ngx_null_str;
        p.*.token_var = ngx.string.ngx_null_str;
        p.*.key_file = ngx.string.ngx_null_str;
        p.*.key_format = 1;
        p.*.keys_count = 0;
        p.*.claim_vars_count = 0;
        p.*.header_vars_count = 0;
        p.*.require_header_count = 0;
        p.*.require_count = 0;
        p.*.require_var_count = 0;
        p.*.validate_exp = conf.NGX_CONF_UNSET;
        p.*.validate_sig = conf.NGX_CONF_UNSET;
        p.*.leeway = conf.NGX_CONF_UNSET;
        p.*.phase = conf.NGX_CONF_UNSET_UINT;
        p.*.revoked_subs_count = 0;
        p.*.revoked_kids_count = 0;
        return p;
    }
    return null;
}

fn create_main_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque { return create_jwt_conf(cf); }
fn create_srv_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque { return create_jwt_conf(cf); }
fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque { return create_jwt_conf(cf); }

fn merge_jwt_conf(cf: [*c]ngx_conf_t, parent: ?*anyopaque, child: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cf;
    const prev = core.castPtr(jwt_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(jwt_loc_conf, child) orelse return conf.NGX_CONF_OK;

    // Convert [*c]T to *const T / *T to get correct field access semantics.
    // Direct [*c]T.*.array_field access can miscompile for large extern structs.
    const p: *const jwt_loc_conf = @ptrCast(@alignCast(prev));
    const ch: *jwt_loc_conf = @ptrCast(@alignCast(c));

    if (ch.enabled == 0 and ch.explicit_disable == 0) ch.enabled = p.enabled;
    if (ch.secret.len == 0) ch.secret = p.secret;
    if (ch.key_file.len == 0) ch.key_file = p.key_file;
    if (ch.key_format == 1 and p.key_format != 1) ch.key_format = p.key_format;
    if (ch.validate_exp == conf.NGX_CONF_UNSET) ch.validate_exp = p.validate_exp;
    if (ch.validate_sig == conf.NGX_CONF_UNSET) ch.validate_sig = p.validate_sig;
    if (ch.leeway == conf.NGX_CONF_UNSET) ch.leeway = p.leeway;
    if (ch.token_var.len == 0) ch.token_var = p.token_var;
    if (ch.phase == conf.NGX_CONF_UNSET_UINT) ch.phase = p.phase;

    // keys array
    if (ch.keys_count == 0 and p.keys_count > 0) {
        @memcpy(ch.keys[0..p.keys_count], p.keys[0..p.keys_count]);
        ch.keys_count = p.keys_count;
    }

    // Merge claim_vars: append parent entries after child entries
    if (p.claim_vars_count > 0) {
        for (0..p.claim_vars_count) |i| {
            if (ch.claim_vars_count >= MAX_CLAIM_VARS) break;
            ch.claim_vars[ch.claim_vars_count] = p.claim_vars[i];
            ch.claim_vars_count += 1;
        }
    }

    if (p.header_vars_count > 0) {
        for (0..p.header_vars_count) |i| {
            if (ch.header_vars_count >= MAX_CLAIM_VARS) break;
            ch.header_vars[ch.header_vars_count] = p.header_vars[i];
            ch.header_vars_count += 1;
        }
    }

    // require_rules array
    if (ch.require_count == 0 and p.require_count > 0) {
        @memcpy(ch.require_rules[0..p.require_count], p.require_rules[0..p.require_count]);
        ch.require_count = p.require_count;
    }

    // require_header_rules array
    if (ch.require_header_count == 0 and p.require_header_count > 0) {
        @memcpy(ch.require_header_rules[0..p.require_header_count], p.require_header_rules[0..p.require_header_count]);
        ch.require_header_count = p.require_header_count;
    }

    // require_var_indices array
    if (ch.require_var_count == 0 and p.require_var_count > 0) {
        @memcpy(ch.require_var_indices[0..p.require_var_count], p.require_var_indices[0..p.require_var_count]);
        ch.require_var_count = p.require_var_count;
    }

    // revoked_subs array
    if (ch.revoked_subs_count == 0 and p.revoked_subs_count > 0) {
        @memcpy(ch.revoked_subs[0..p.revoked_subs_count], p.revoked_subs[0..p.revoked_subs_count]);
        ch.revoked_subs_count = p.revoked_subs_count;
    }

    // revoked_kids array
    if (ch.revoked_kids_count == 0 and p.revoked_kids_count > 0) {
        @memcpy(ch.revoked_kids[0..p.revoked_kids_count], p.revoked_kids[0..p.revoked_kids_count]);
        ch.revoked_kids_count = p.revoked_kids_count;
    }

    return conf.NGX_CONF_OK;
}

fn merge_srv_conf(cf: [*c]ngx_conf_t, p: ?*anyopaque, c: ?*anyopaque) callconv(.c) [*c]u8 { return merge_jwt_conf(cf, p, c); }
fn merge_loc_conf(cf: [*c]ngx_conf_t, p: ?*anyopaque, c: ?*anyopaque) callconv(.c) [*c]u8 { return merge_jwt_conf(cf, p, c); }

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
            const s = core.slicify(u8, arg.*.data, arg.*.len);
            // Check for token=$variable syntax
            if (std.mem.eql(u8, s, "off")) {
                lccf.*.enabled = 0;
                lccf.*.explicit_disable = 1;
            } else if (std.mem.startsWith(u8, s, "token=")) {
                const var_name = s["token=".len..];
                if (core.castPtr(u8, core.ngx_pnalloc(cf.*.pool, var_name.len))) |copy| {
                    @memcpy(core.slicify(u8, copy, var_name.len), var_name);
                    lccf.*.token_var = ngx_str_t{ .data = copy, .len = var_name.len };
                }
            } else {
                lccf.*.secret = arg.*;
            }
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

// ── Variable get_handlers ─────────────────────────────────────────────

fn jwt_variable_claims(
    r: [*c]ngx_http_request_t,
    v: [*c]http.ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    const rctx = core.castPtr(jwt_ctx, r.*.ctx[ngx_http_jwt_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    if (rctx.*.claims_json.len == 0) {
        v.*.flags.not_found = true;
        return NGX_OK;
    }
    v.*.data = rctx.*.claims_json.data;
    v.*.flags.len = @intCast(rctx.*.claims_json.len);
    v.*.flags.valid = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn jwt_variable_nowtime(
    r: [*c]ngx_http_request_t,
    v: [*c]http.ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    var buf: [32]u8 = undefined;
    const now: i64 = time(null);
    const now_u: usize = @intCast(if (now < 0) @as(i64, 0) else now);

    var tmp = now_u;
    var pos: usize = buf.len;
    if (tmp == 0) {
        pos -= 1;
        buf[pos] = '0';
    } else {
        while (tmp > 0) {
            pos -= 1;
            buf[pos] = @intCast('0' + (tmp % 10));
            tmp /= 10;
        }
    }
    const s = buf[pos..];
    // Copy to request pool (stack buffer is ephemeral)
    if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, s.len))) |copy| {
        @memcpy(core.slicify(u8, copy, s.len), s);
        v.*.data = copy;
        v.*.flags.len = @intCast(s.len);
        v.*.flags.valid = true;
        v.*.flags.not_found = false;
    } else {
        v.*.flags.not_found = true;
    }
    return NGX_OK;
}

fn find_ctx_value(entries: []const jwt_claim_entry, name: ngx_str_t) ?ngx_str_t {
    const n = core.slicify(u8, name.data, name.len);
    for (entries) |*cv| {
        if (std.mem.eql(u8, core.slicify(u8, cv.name.data, cv.name.len), n)) {
            return cv.value;
        }
    }
    return null;
}

fn find_claim_value(rctx: [*c]jwt_ctx, name: ngx_str_t) ?ngx_str_t {
    return find_ctx_value(rctx.*.claim_values[0..rctx.*.claim_values_count], name);
}

fn find_header_value(rctx: [*c]jwt_ctx, name: ngx_str_t) ?ngx_str_t {
    return find_ctx_value(rctx.*.header_values[0..rctx.*.header_values_count], name);
}

fn jwt_variable_claim(
    r: [*c]ngx_http_request_t,
    v: [*c]http.ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    const name_ptr: [*c]ngx_str_t = @ptrFromInt(data);
    const rctx = core.castPtr(jwt_ctx, r.*.ctx[ngx_http_jwt_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    if (find_claim_value(rctx, name_ptr.*)) |val| {
        v.*.data = val.data;
        v.*.flags.len = @intCast(val.len);
        v.*.flags.valid = true;
        v.*.flags.not_found = false;
    } else {
        v.*.flags.not_found = true;
    }
    return NGX_OK;
}

fn jwt_variable_header(
    r: [*c]ngx_http_request_t,
    v: [*c]http.ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    const name_ptr: [*c]ngx_str_t = @ptrFromInt(data);
    const rctx = core.castPtr(jwt_ctx, r.*.ctx[ngx_http_jwt_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    if (find_header_value(rctx, name_ptr.*)) |val| {
        v.*.data = val.data;
        v.*.flags.len = @intCast(val.len);
        v.*.flags.valid = true;
        v.*.flags.not_found = false;
    } else {
        v.*.flags.not_found = true;
    }
    return NGX_OK;
}

// ── Extract and store claim value from JSON payload ──────────────────

fn build_query_path(name: []const u8, buf: []u8) ?[]const u8 {
    if (name.len == 0) return null;
    if (name[0] == '$') {
        if (name.len > buf.len) return null;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    if (name[0] == '.' or name[0] == '[') {
        if (name.len + 1 > buf.len) return null;
        buf[0] = '$';
        @memcpy(buf[1 .. 1 + name.len], name);
        return buf[0 .. 1 + name.len];
    }
    if (name.len + 2 > buf.len) return null;
    buf[0] = '$';
    buf[1] = '.';
    @memcpy(buf[2 .. 2 + name.len], name);
    return buf[0 .. 2 + name.len];
}

fn extract_claim(json: [*c]cjson.cJSON, name: []const u8, pool: [*c]core.ngx_pool_t) ?ngx_str_t {
    var path_buf: [128]u8 = undefined;
    const path = build_query_path(name, &path_buf) orelse return null;

    const node = CJSON.query(json, path) orelse return null;

    // Try string first, then integer, then boolean, then null
    if (CJSON.stringValue(node)) |s| {
        return s;
    }
    if (CJSON.intValue(node)) |i| {
        // Convert int to string in pool
        var ibuf: [32]u8 = undefined;
        var v = if (i < 0) blk: {
            break :blk @as(u64, @intCast(-i));
        } else @as(u64, @intCast(i));
        var pos: usize = ibuf.len;
        if (v == 0) {
            pos -= 1;
            ibuf[pos] = '0';
        } else {
            while (v > 0) {
                pos -= 1;
                ibuf[pos] = @intCast('0' + (v % 10));
                v /= 10;
            }
        }
        if (i < 0) {
            pos -= 1;
            ibuf[pos] = '-';
        }
        const is = ibuf[pos..];
        if (core.castPtr(u8, core.ngx_pnalloc(pool, is.len))) |copy| {
            @memcpy(core.slicify(u8, copy, is.len), is);
            return ngx_str_t{ .data = copy, .len = is.len };
        }
        return null;
    }
    return null;
}

fn audience_node_matches(node: [*c]cjson.cJSON, expected: []const u8) bool {
    if (CJSON.stringValue(node)) |aud| {
        return std.mem.eql(u8, core.slicify(u8, aud.data, aud.len), expected);
    }

    if (CJSON.arrValue(node)) |aud_arr| {
        var it = CJSON.Iterator.init(aud_arr);
        while (it.next()) |item| {
            if (CJSON.stringValue(item)) |aud| {
                if (std.mem.eql(u8, core.slicify(u8, aud.data, aud.len), expected)) {
                    return true;
                }
            }
        }
    }

    return false;
}

fn populate_claims(rctx: [*c]jwt_ctx, payload_json: []const u8, lccf: [*c]jwt_loc_conf, pool: [*c]core.ngx_pool_t) void {
    var cj = CJSON.init(pool);
    const json = cj.decode(ngx_str_t{ .data = @constCast(payload_json.ptr), .len = payload_json.len }) catch return;
    defer cj.free(json);

    // Extract registered claim variables
    for (lccf.*.claim_vars[0..lccf.*.claim_vars_count]) |*cv| {
        if (rctx.*.claim_values_count >= MAX_CLAIM_VARS) break;
        if (cv.name.data == null) continue;
        const name = core.slicify(u8, cv.name.data, cv.name.len);
        if (extract_claim(json, name, pool)) |val| {
            const idx = rctx.*.claim_values_count;
            const ce: [*]jwt_claim_entry = @ptrCast(&rctx.*.claim_values);
            ce[idx].name = cv.name;
            ce[idx].value = val;
            rctx.*.claim_values_count += 1;
        }
    }
}

fn populate_headers(rctx: [*c]jwt_ctx, header_json: []const u8, lccf: [*c]jwt_loc_conf, pool: [*c]core.ngx_pool_t) void {
    var cj = CJSON.init(pool);
    const json = cj.decode(ngx_str_t{ .data = @constCast(header_json.ptr), .len = header_json.len }) catch return;
    defer cj.free(json);

    for (lccf.*.header_vars[0..lccf.*.header_vars_count]) |*hv| {
        if (rctx.*.header_values_count >= MAX_CLAIM_VARS) break;
        if (hv.name.data == null) continue;
        const name = core.slicify(u8, hv.name.data, hv.name.len);
        if (extract_claim(json, name, pool)) |val| {
            const idx = rctx.*.header_values_count;
            const he: [*]jwt_claim_entry = @ptrCast(&rctx.*.header_values);
            he[idx].name = hv.name;
            he[idx].value = val;
            rctx.*.header_values_count += 1;
        }
    }
}

// ── Directive handlers for jwt_claim / jwt_header ─────────────────────

fn ngx_conf_set_jwt_claim(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        if (lccf.*.claim_vars_count >= MAX_CLAIM_VARS) return conf.NGX_CONF_ERROR;

        var index: ngx_uint_t = 1;
        // First arg: $variable name
        const var_name = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index) orelse return conf.NGX_CONF_ERROR;
        // Second arg: claim name
        const claim_name = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index) orelse return conf.NGX_CONF_ERROR;

        // Register the nginx variable with our claim get_handler
        var vn = var_name.*;
        // Strip leading '$' if present
        if (vn.len > 0 and vn.data[0] == '$') {
            vn.data += 1;
            vn.len -= 1;
        }

        // Store claim name in config (pool-allocated for lifetime)
        if (core.ngz_pcalloc_c(ngx_str_t, cf.*.pool)) |name_copy| {
            name_copy.* = claim_name.*;

            if (http.ngx_http_add_variable(cf, &vn, http.NGX_HTTP_VAR_NOCACHEABLE)) |variable| {
                variable.*.get_handler = jwt_variable_claim;
                variable.*.data = @intFromPtr(name_copy);
            }

            const idx = lccf.*.claim_vars_count;
            const cv: [*]jwt_claim_var = @ptrCast(&lccf.*.claim_vars);
            cv[idx].name = claim_name.*;
            cv[idx].var_index = 0;
            lccf.*.claim_vars_count += 1;
        }
    }
    return conf.NGX_CONF_OK;
}

// ── Directive: jwt_require_claim ──────────────────────────────────────

fn ngx_conf_set_jwt_require_claim(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        if (lccf.*.require_count >= MAX_REQUIRE_CLAIMS) return conf.NGX_CONF_ERROR;

        var index: ngx_uint_t = 1;
        const claim_name = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index) orelse return conf.NGX_CONF_ERROR;
        const op_str = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index) orelse return conf.NGX_CONF_ERROR;
        const val_str = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index) orelse return conf.NGX_CONF_ERROR;

        const op = parse_claim_op(op_str.*) orelse return conf.NGX_CONF_ERROR;

        const rc: [*]jwt_require_rule = @ptrCast(&lccf.*.require_rules);
        const idx = lccf.*.require_count;
        rc[idx].name = claim_name.*;
        rc[idx].op = op;
        rc[idx].value = val_str.*;
        lccf.*.require_count += 1;
    }
    return conf.NGX_CONF_OK;
}

// ── Directive: jwt_validate_exp ───────────────────────────────────────

fn ngx_conf_set_jwt_validate_exp(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        var index: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index)) |arg| {
            const s = core.slicify(u8, arg.*.data, arg.*.len);
            if (std.mem.eql(u8, s, "on")) lccf.*.validate_exp = 1
            else if (std.mem.eql(u8, s, "off")) lccf.*.validate_exp = 0
            else return conf.NGX_CONF_ERROR;
        }
    }
    return conf.NGX_CONF_OK;
}

// ── Directive: jwt_leeway ─────────────────────────────────────────────

fn ngx_conf_set_jwt_leeway(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        var index: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index)) |arg| {
            const s = core.slicify(u8, arg.*.data, arg.*.len);
            lccf.*.leeway = std.fmt.parseInt(ngx_int_t, s, 10) catch return conf.NGX_CONF_ERROR;
        }
    }
    return conf.NGX_CONF_OK;
}

// ── Evaluate a require_claim rule against the payload ────────────────

fn eval_require_rule(json: [*c]cjson.cJSON, rule: *const jwt_require_rule, pool: [*c]core.ngx_pool_t) bool {
    const name = core.slicify(u8, rule.name.data, rule.name.len);
    var path_buf: [256]u8 = undefined;
    const path = build_query_path(name, &path_buf) orelse return false;
    const claim_node = CJSON.query(json, path);

    const node = claim_node orelse return (rule.op == .neq); // missing claim: eq fails, neq passes

    _ = pool;
    const expected = core.slicify(u8, rule.value.data, rule.value.len);

    if (std.mem.eql(u8, name, "aud")) {
        const matched = audience_node_matches(node, expected);
        return switch (rule.op) {
            .eq => matched,
            .neq => !matched,
            else => false,
        };
    }

    // Get claim value as string
    var claim_val: [256]u8 = undefined;
    var claim_slice: []const u8 = undefined;

    if (CJSON.stringValue(node)) |s| {
        claim_slice = core.slicify(u8, s.data, s.len);
    } else if (CJSON.intValue(node)) |i| {
        // Convert int to string
        var v: u64 = if (i < 0) @intCast(-i) else @intCast(i);
        var pos: usize = claim_val.len;
        if (v == 0) {
            pos -= 1;
            claim_val[pos] = '0';
        } else {
            while (v > 0) {
                pos -= 1;
                claim_val[pos] = @intCast('0' + (v % 10));
                v /= 10;
            }
        }
        if (i < 0) {
            pos -= 1;
            claim_val[pos] = '-';
        }
        claim_slice = claim_val[pos..];
    } else {
        return (rule.op == .neq);
    }

    switch (rule.op) {
        .eq => return std.mem.eql(u8, claim_slice, expected),
        .neq => return !std.mem.eql(u8, claim_slice, expected),
        .gt, .lt, .ge, .le => {
            const cv = std.fmt.parseFloat(f64, claim_slice) catch return false;
            const ev = std.fmt.parseFloat(f64, expected) catch return false;
            return switch (rule.op) {
                .gt => cv > ev,
                .lt => cv < ev,
                .ge => cv >= ev,
                .le => cv <= ev,
                else => false,
            };
        },
    }
}

// ── Directive: jwt_validate_sig ───────────────────────────────────────

fn ngx_conf_set_jwt_validate_sig(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        var index: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index)) |arg| {
            const s = core.slicify(u8, arg.*.data, arg.*.len);
            if (std.mem.eql(u8, s, "on")) lccf.*.validate_sig = 1
            else if (std.mem.eql(u8, s, "off")) lccf.*.validate_sig = 0
            else return conf.NGX_CONF_ERROR;
        }
    }
    return conf.NGX_CONF_OK;
}

// ── Directive: jwt_require ────────────────────────────────────────────

fn ngx_conf_set_jwt_require(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        var index: ngx_uint_t = 1;
        while (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index)) |arg| {
            if (lccf.*.require_var_count >= MAX_CLAIM_VARS) break;
            const s = core.slicify(u8, arg.*.data, arg.*.len);
            if (s.len > 0 and s[0] == '$') {
                // Register variable index (lookup at runtime)
                const vn: [*c]u8 = arg.*.data + 1;
                const vn_len = arg.*.len - 1;
                const vn_str = ngx_str_t{ .data = vn, .len = vn_len };
                if (http.ngx_http_get_variable_index(cf, @constCast(&vn_str)) != core.NGX_ERROR) {
                    const rc: [*]ngx_uint_t = @ptrCast(&lccf.*.require_var_indices);
                    rc[lccf.*.require_var_count] = @intCast(http.ngx_http_get_variable_index(cf, @constCast(&vn_str)));
                    lccf.*.require_var_count += 1;
                }
            }
        }
    }
    return conf.NGX_CONF_OK;
}

// ── Directive: jwt_phase ──────────────────────────────────────────────

fn ngx_conf_set_jwt_phase(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        var index: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index)) |arg| {
            const s = core.slicify(u8, arg.*.data, arg.*.len);
            if (std.mem.eql(u8, s, "preaccess")) lccf.*.phase = 1
            else if (std.mem.eql(u8, s, "access")) lccf.*.phase = 0
            else return conf.NGX_CONF_ERROR;
        }
    }
    return conf.NGX_CONF_OK;
}

// ── Directive: jwt_header ─────────────────────────────────────────────

fn ngx_conf_set_jwt_header(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        if (lccf.*.header_vars_count >= MAX_CLAIM_VARS) return conf.NGX_CONF_ERROR;
        var index: ngx_uint_t = 1;
        const var_name = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index) orelse return conf.NGX_CONF_ERROR;
        const hdr_name = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index) orelse return conf.NGX_CONF_ERROR;
        var vn = var_name.*;
        if (vn.len > 0 and vn.data[0] == '$') { vn.data += 1; vn.len -= 1; }
        if (core.ngz_pcalloc_c(ngx_str_t, cf.*.pool)) |name_copy| {
            name_copy.* = hdr_name.*;
            if (http.ngx_http_add_variable(cf, &vn, http.NGX_HTTP_VAR_NOCACHEABLE)) |variable| {
                variable.*.get_handler = jwt_variable_header;
                variable.*.data = @intFromPtr(name_copy);
            }
            const hv: [*]jwt_claim_var = @ptrCast(&lccf.*.header_vars);
            const idx = lccf.*.header_vars_count;
            hv[idx].name = hdr_name.*;
            hv[idx].var_index = 0;
            lccf.*.header_vars_count += 1;
        }
    }
    return conf.NGX_CONF_OK;
}

// ── Directive: jwt_require_header ────────────────────────────────────

fn ngx_conf_set_jwt_require_header(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        if (lccf.*.require_header_count >= MAX_REQUIRE_CLAIMS) return conf.NGX_CONF_ERROR;
        var index: ngx_uint_t = 1;
        const hdr_name = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index) orelse return conf.NGX_CONF_ERROR;
        const op_str = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index) orelse return conf.NGX_CONF_ERROR;
        const val_str = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index) orelse return conf.NGX_CONF_ERROR;
        const op = parse_claim_op(op_str.*) orelse return conf.NGX_CONF_ERROR;
        const rh: [*]jwt_require_rule = @ptrCast(&lccf.*.require_header_rules);
        const idx = lccf.*.require_header_count;
        rh[idx].name = hdr_name.*;
        rh[idx].op = op;
        rh[idx].value = val_str.*;
        lccf.*.require_header_count += 1;
    }
    return conf.NGX_CONF_OK;
}

fn parse_claim_op(op_str: ngx_str_t) ?ClaimOp {
    const s = core.slicify(u8, op_str.data, op_str.len);
    if (std.mem.eql(u8, s, "eq")) return .eq;
    if (std.mem.eql(u8, s, "!eq")) return .neq;
    if (std.mem.eql(u8, s, "gt")) return .gt;
    if (std.mem.eql(u8, s, "lt")) return .lt;
    if (std.mem.eql(u8, s, "ge")) return .ge;
    if (std.mem.eql(u8, s, "le")) return .le;
    return null;
}

// ── Directive: jwt_issuer ─────────────────────────────────────────────

fn ngx_conf_set_jwt_issuer(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    // Shortcut for: jwt_require_claim iss eq <value>
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        if (lccf.*.require_count >= MAX_REQUIRE_CLAIMS) return conf.NGX_CONF_ERROR;
        var index: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index)) |arg| {
            const rc: [*]jwt_require_rule = @ptrCast(&lccf.*.require_rules);
            const idx = lccf.*.require_count;
            rc[idx].name = ngx_string("iss");
            rc[idx].op = .eq;
            rc[idx].value = arg.*;
            lccf.*.require_count += 1;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_jwt_audience(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        if (lccf.*.require_count >= MAX_REQUIRE_CLAIMS) return conf.NGX_CONF_ERROR;
        var index: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index)) |arg| {
            const rc: [*]jwt_require_rule = @ptrCast(&lccf.*.require_rules);
            const idx = lccf.*.require_count;
            rc[idx].name = ngx_string("aud");
            rc[idx].op = .eq;
            rc[idx].value = arg.*;
            lccf.*.require_count += 1;
        }
    }
    return conf.NGX_CONF_OK;
}

// ── Directive: jwt_revocation_list_sub ────────────────────────────────

fn load_revocation_list(cf: [*c]ngx_conf_t, file_path: ngx_str_t, values: *[MAX_KEYS]ngx_str_t, count: *ngx_uint_t) void {
    var resolved = file_path;
    if (conf.ngx_conf_full_name(cf.*.cycle, &resolved, 1) != core.NGX_OK) return;
    const content = file.ngz_open_file(resolved, cf.*.log, cf.*.pool) catch return;
    const data = core.slicify(u8, content.data, content.len);

    var cj = CJSON.init(cf.*.pool);
    const root = cj.decode(ngx_str_t{ .data = data.ptr, .len = data.len }) catch return;
    defer cj.free(root);

    var it = CJSON.Iterator.init(root);
    while (it.next()) |val_node| {
        if (count.* >= MAX_KEYS) break;
        if (CJSON.stringValue(val_node)) |value| {
            const v: [*]ngx_str_t = @ptrCast(values);
            v[count.*] = value;
            count.* += 1;
        }
    }
}

fn ngx_conf_set_revocation_sub(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        var index: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index)) |arg| {
            lccf.*.revocation_sub_file = arg.*;
            load_revocation_list(cf, arg.*, &lccf.*.revoked_subs, &lccf.*.revoked_subs_count);
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_revocation_kid(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jwt_loc_conf, loc)) |lccf| {
        var index: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index)) |arg| {
            lccf.*.revocation_kid_file = arg.*;
            load_revocation_list(cf, arg.*, &lccf.*.revoked_kids, &lccf.*.revoked_kids_count);
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_jwt_key_request(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = loc;
    log.ngz_log_error(log.NGX_LOG_EMERG, cf.*.log, 0, "jwt_key_request is not implemented yet; use jwt_key_file for local key material", .{});
    return conf.NGX_CONF_ERROR;
}

// ── Postconfiguration ──────────────────────────────────────────────────

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    // Register $jwt_claims and $jwt_nowtime
    var claims_name = ngx_string("jwt_claims");
    if (http.ngx_http_add_variable(cf, &claims_name, http.NGX_HTTP_VAR_NOCACHEABLE)) |v| {
        v.*.get_handler = jwt_variable_claims;
    }
    var nowtime_name = ngx_string("jwt_nowtime");
    if (http.ngx_http_add_variable(cf, &nowtime_name, http.NGX_HTTP_VAR_NOCACHEABLE)) |v| {
        v.*.get_handler = jwt_variable_nowtime;
    }

    // Register both preaccess and access handlers; runtime location config decides which one runs.
    const cmcf = core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    var handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[NGX_HTTP_PREACCESS_PHASE].handlers,
    );
    const pre_h = handlers.append() catch return NGX_ERROR;
    pre_h.* = ngx_http_jwt_preaccess_handler;

    handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_ACCESS_PHASE].handlers,
    );
    const h = handlers.append() catch return NGX_ERROR;
    h.* = ngx_http_jwt_access_handler;

    return NGX_OK;
}

export const ngx_http_jwt_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = create_main_conf,
    .init_main_conf = null,
    .create_srv_conf = create_srv_conf,
    .merge_srv_conf = merge_srv_conf,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_jwt_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("jwt_secret"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE12,
        .set = ngx_conf_set_jwt_secret,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_key_file"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE12,
        .set = ngx_conf_set_jwt_key_file,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_claim"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_jwt_claim,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_require_claim"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE3,
        .set = ngx_conf_set_jwt_require_claim,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_validate_exp"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_jwt_validate_exp,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_leeway"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_jwt_leeway,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_validate_sig"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_jwt_validate_sig,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_require"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1 | conf.NGX_CONF_1MORE,
        .set = ngx_conf_set_jwt_require,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_phase"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_jwt_phase,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_issuer"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_jwt_issuer,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_audience"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_jwt_audience,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_header"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_jwt_header,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_require_header"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE3,
        .set = ngx_conf_set_jwt_require_header,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_revocation_list_sub"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_revocation_sub,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_revocation_list_kid"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_revocation_kid,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("jwt_key_request"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE12,
        .set = ngx_conf_set_jwt_key_request,
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
    try expect(algo_from_str("ES256") != null);
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
    try expect(split_jwt("only.onedot") == null);
}

test "jwt_loc_conf layout" {
    _ = @sizeOf(jwt_loc_conf);
    _ = @alignOf(jwt_loc_conf);
}
