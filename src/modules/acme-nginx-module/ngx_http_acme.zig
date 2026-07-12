const std = @import("std");
const ngx = @import("ngx");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const shm = ngx.shm;
const ssl = ngx.ssl;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;
const NGX_AGAIN = core.NGX_AGAIN;
const NGX_DONE = core.NGX_DONE;

const ngx_str_t = core.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_msec_t = core.ngx_msec_t;
const ngx_pool_t = core.ngx_pool_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;

const ngx_string = ngx.string.ngx_string;
const ngx_null_str = ngx.string.ngx_null_str;

// ============================================================================
// Base64url encoding (RFC 4648 Section 5)
// ============================================================================

// Standard base64 to base64url conversion (in-place)
// Replaces: '+' -> '-', '/' -> '_', removes '=' padding
fn base64_to_base64url(data: []u8) []u8 {
    var len = data.len;

    // Remove padding
    while (len > 0 and data[len - 1] == '=') {
        len -= 1;
    }

    // Replace characters
    for (data[0..len]) |*c| {
        if (c.* == '+') {
            c.* = '-';
        } else if (c.* == '/') {
            c.* = '_';
        }
    }

    return data[0..len];
}

// Base64url to standard base64 conversion
// Replaces: '-' -> '+', '_' -> '/', adds '=' padding
fn base64url_to_base64(data: []u8, out: []u8) []u8 {
    var i: usize = 0;
    for (data) |c| {
        if (c == '-') {
            out[i] = '+';
        } else if (c == '_') {
            out[i] = '/';
        } else {
            out[i] = c;
        }
        i += 1;
    }

    // Add padding
    const padding = (4 - (i % 4)) % 4;
    for (0..padding) |_| {
        out[i] = '=';
        i += 1;
    }

    return out[0..i];
}

fn ngx_str_slice(value: ngx_str_t) []const u8 {
    if (value.len == 0 or value.data == core.nullptr(u8)) {
        return &.{};
    }
    return core.slicify(u8, value.data, value.len);
}

fn fixed_string_write(dest: []u8, len_out: *usize, value: []const u8) bool {
    if (value.len > dest.len) return false;
    if (value.len > 0) {
        @memcpy(dest[0..value.len], value);
    }
    len_out.* = value.len;
    return true;
}

fn fixed_string_clear(dest: []u8, len_out: *usize) void {
    _ = dest;
    len_out.* = 0;
}

fn fixed_string_slice(dest: []const u8, len: usize) []const u8 {
    return dest[0..len];
}

fn pool_string_from_slice(pool: [*c]ngx_pool_t, value: []const u8) ?ngx_str_t {
    if (value.len == 0) return ngx_null_str;
    const copied = duplicate_bytes(pool, value) orelse return null;
    return ngx_str_t{ .len = copied.len, .data = @constCast(copied.ptr) };
}

// Encode bytes to base64url string (no padding)
pub fn base64url_encode(pool: [*c]ngx_pool_t, input: []const u8) ?ngx_str_t {
    if (input.len == 0) {
        return ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
    }

    // Allocate space for base64 (with potential padding)
    const b64_len = ssl.ngx_base64_encoded_length(input.len);
    const buf = core.castPtr(u8, core.ngx_pnalloc(pool, b64_len)) orelse return null;

    // Encode using nginx's base64
    var src = ngx_str_t{ .len = input.len, .data = @constCast(input.ptr) };
    var dst = ngx_str_t{ .len = b64_len, .data = buf };
    ngx.string.ngx_encode_base64(&dst, &src);

    // Convert to base64url (in-place) and remove padding
    const result = base64_to_base64url(core.slicify(u8, dst.data, dst.len));

    return ngx_str_t{ .len = result.len, .data = dst.data };
}

// Decode base64url string to bytes
pub fn base64url_decode(pool: [*c]ngx_pool_t, input: ngx_str_t) ?ngx_str_t {
    if (input.len == 0) {
        return ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
    }

    // Need temporary buffer for base64 conversion (with padding)
    const padded_len = input.len + ((4 - (input.len % 4)) % 4);
    const temp = core.castPtr(u8, core.ngx_pnalloc(pool, padded_len)) orelse return null;

    // Convert base64url to base64
    const b64 = base64url_to_base64(core.slicify(u8, input.data, input.len), core.slicify(u8, temp, padded_len));

    // Allocate output buffer
    const out_len = ssl.ngx_base64_decoded_length(b64.len);
    const out = core.castPtr(u8, core.ngx_pnalloc(pool, out_len)) orelse return null;

    // Decode
    var src = ngx_str_t{ .len = b64.len, .data = temp };
    var dst = ngx_str_t{ .len = out_len, .data = out };

    if (ngx.string.ngx_decode_base64(&dst, &src) != NGX_OK) {
        return null;
    }

    return dst;
}

// ============================================================================
// SHA256 hashing
// ============================================================================

pub fn sha256_hash(input: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &hash, .{});
    return hash;
}

// ============================================================================
// JWK Thumbprint (RFC 7638)
// ============================================================================

// For RSA keys, the canonical JWK format is:
// {"e":"<base64url>","kty":"RSA","n":"<base64url>"}
// (keys must be in lexicographic order: e, kty, n)

// Compute thumbprint from RSA public key components
pub fn compute_jwk_thumbprint(pool: [*c]ngx_pool_t, e: []const u8, n: []const u8) ?ngx_str_t {
    // Encode e and n as base64url
    const e_b64 = base64url_encode(pool, e) orelse return null;
    const n_b64 = base64url_encode(pool, n) orelse return null;

    // Build canonical JWK JSON
    // {"e":"...","kty":"RSA","n":"..."}
    const prefix = "{\"e\":\"";
    const mid1 = "\",\"kty\":\"RSA\",\"n\":\"";
    const suffix = "\"}";

    const json_len = prefix.len + e_b64.len + mid1.len + n_b64.len + suffix.len;
    const json_buf = core.castPtr(u8, core.ngx_pnalloc(pool, json_len)) orelse return null;

    var pos: usize = 0;
    @memcpy(json_buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    @memcpy(json_buf[pos .. pos + e_b64.len], core.slicify(u8, e_b64.data, e_b64.len));
    pos += e_b64.len;
    @memcpy(json_buf[pos .. pos + mid1.len], mid1);
    pos += mid1.len;
    @memcpy(json_buf[pos .. pos + n_b64.len], core.slicify(u8, n_b64.data, n_b64.len));
    pos += n_b64.len;
    @memcpy(json_buf[pos .. pos + suffix.len], suffix);

    // SHA256 hash the JSON
    const hash = sha256_hash(core.slicify(u8, json_buf, json_len));

    // Base64url encode the hash
    return base64url_encode(pool, &hash);
}

// ============================================================================
// OpenSSL bindings for RSA key management (via ssl wrapper)
// ============================================================================

const EVP_PKEY = ssl.EVP_PKEY;
const EVP_MD_CTX = ssl.EVP_MD_CTX;
const BIGNUM = ssl.BIGNUM;
const BIO = ssl.BIO;
const RSA = ssl.RSA;

const EVP_RSA_gen = ssl.EVP_RSA_gen;
const EVP_PKEY_free = ssl.EVP_PKEY_free;
const EVP_PKEY_get0_RSA = ssl.EVP_PKEY_get0_RSA;
const RSA_get0_key = ssl.RSA_get0_key;
const BN_num_bytes = ssl.BN_num_bytes;
const BN_bn2bin = ssl.BN_bn2bin;
const BIO_new = ssl.BIO_new;
const BIO_s_mem = ssl.BIO_s_mem;
const BIO_free = ssl.BIO_free;
const BIO_ctrl = ssl.BIO_ctrl;
const BIO_new_mem_buf = ssl.BIO_new_mem_buf;
const PEM_write_bio_PrivateKey = ssl.PEM_write_bio_PrivateKey;
const PEM_read_bio_PrivateKey = ssl.PEM_read_bio_PrivateKey;
const EVP_MD_CTX_new = ssl.EVP_MD_CTX_new;
const EVP_MD_CTX_free = ssl.EVP_MD_CTX_free;
const EVP_MD_CTX_reset = ssl.EVP_MD_CTX_reset;
const EVP_sha256 = ssl.EVP_sha256;
const EVP_DigestSignInit = ssl.EVP_DigestSignInit;
const EVP_DigestSignUpdate = ssl.EVP_DigestSignUpdate;
const EVP_DigestSignFinal = ssl.EVP_DigestSignFinal;
const OPENSSL_init_crypto = ssl.OPENSSL_init_crypto;
const OPENSSL_INIT_ADD_ALL_CIPHERS = ssl.OPENSSL_INIT_ADD_ALL_CIPHERS;
const OPENSSL_INIT_ADD_ALL_DIGESTS = ssl.OPENSSL_INIT_ADD_ALL_DIGESTS;
const OPENSSL_INIT_LOAD_CRYPTO_STRINGS = ssl.OPENSSL_INIT_LOAD_CRYPTO_STRINGS;
const BIO_CTRL_INFO = ssl.BIO_CTRL_INFO;

// ============================================================================
// RSA Account Key Management
// ============================================================================

pub const AcmeAccountKey = struct {
    const Self = @This();

    pkey: ?*EVP_PKEY,
    md_ctx: ?*EVP_MD_CTX,

    // Public key components (for JWK)
    e_bytes: []u8,
    n_bytes: []u8,

    pub fn generate(pool: [*c]ngx_pool_t) !Self {
        _ = OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null);

        // Generate 2048-bit RSA key
        const pkey = EVP_RSA_gen(2048) orelse return error.KeyGenFailed;

        // Create MD context for signing
        const md_ctx = EVP_MD_CTX_new() orelse {
            EVP_PKEY_free(pkey);
            return error.ContextFailed;
        };

        // Extract public key components
        const key = try extractKeyComponents(pkey, pool);

        return Self{
            .pkey = pkey,
            .md_ctx = md_ctx,
            .e_bytes = key.e,
            .n_bytes = key.n,
        };
    }

    pub fn loadFromPem(pem: ngx_str_t, pool: [*c]ngx_pool_t) !Self {
        _ = OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null);

        const bio = BIO_new_mem_buf(pem.data, @intCast(pem.len)) orelse return error.BioFailed;
        defer _ = BIO_free(bio);

        const pkey = PEM_read_bio_PrivateKey(bio, null, null, null) orelse return error.PemParseFailed;

        const md_ctx = EVP_MD_CTX_new() orelse {
            EVP_PKEY_free(pkey);
            return error.ContextFailed;
        };

        const key = try extractKeyComponents(pkey, pool);

        return Self{
            .pkey = pkey,
            .md_ctx = md_ctx,
            .e_bytes = key.e,
            .n_bytes = key.n,
        };
    }

    fn extractKeyComponents(pkey: *EVP_PKEY, pool: [*c]ngx_pool_t) !struct { e: []u8, n: []u8 } {
        const rsa = EVP_PKEY_get0_RSA(pkey) orelse return error.NotRsaKey;

        var n_bn: ?*const BIGNUM = null;
        var e_bn: ?*const BIGNUM = null;
        RSA_get0_key(rsa, &n_bn, &e_bn, null);

        if (n_bn == null or e_bn == null) return error.KeyComponentsFailed;

        // Get sizes
        const n_size: usize = @intCast(BN_num_bytes(n_bn));
        const e_size: usize = @intCast(BN_num_bytes(e_bn));

        // Allocate buffers
        const n_buf = core.castPtr(u8, core.ngx_pnalloc(pool, n_size)) orelse return error.AllocFailed;
        const e_buf = core.castPtr(u8, core.ngx_pnalloc(pool, e_size)) orelse return error.AllocFailed;

        // Extract bytes
        _ = BN_bn2bin(n_bn, n_buf);
        _ = BN_bn2bin(e_bn, e_buf);

        return .{
            .e = core.slicify(u8, e_buf, e_size),
            .n = core.slicify(u8, n_buf, n_size),
        };
    }

    pub fn toPem(self: *Self, pool: [*c]ngx_pool_t) !ngx_str_t {
        const bio = BIO_new(BIO_s_mem()) orelse return error.BioFailed;
        defer _ = BIO_free(bio);

        if (PEM_write_bio_PrivateKey(bio, self.pkey, null, null, 0, null, null) != 1) {
            return error.PemWriteFailed;
        }

        // Get the PEM data from BIO
        var data: [*c]u8 = undefined;
        const len = BIO_ctrl(bio, BIO_CTRL_INFO, 0, @ptrCast(&data));

        if (len <= 0) return error.BioEmpty;

        // Copy to pool
        const pem_buf = core.castPtr(u8, core.ngx_pnalloc(pool, @intCast(len))) orelse return error.AllocFailed;
        @memcpy(core.slicify(u8, pem_buf, @intCast(len)), core.slicify(u8, data, @intCast(len)));

        return ngx_str_t{ .len = @intCast(len), .data = pem_buf };
    }

    pub fn getThumbprint(self: *Self, pool: [*c]ngx_pool_t) ?ngx_str_t {
        return compute_jwk_thumbprint(pool, self.e_bytes, self.n_bytes);
    }

    pub fn signRs256(self: *Self, message: []const u8, pool: [*c]ngx_pool_t) !ngx_str_t {
        // RS256 signature buffer (max 256 bytes for 2048-bit key)
        var sig_buf: [256]u8 = undefined;
        var sig_len: usize = sig_buf.len;

        defer _ = EVP_MD_CTX_reset(self.md_ctx);

        if (EVP_DigestSignInit(self.md_ctx, null, EVP_sha256(), null, self.pkey) != 1) {
            return error.SignInitFailed;
        }

        if (EVP_DigestSignUpdate(self.md_ctx, message.ptr, message.len) != 1) {
            return error.SignUpdateFailed;
        }

        if (EVP_DigestSignFinal(self.md_ctx, &sig_buf, &sig_len) != 1) {
            return error.SignFinalFailed;
        }

        // Base64url encode the signature
        return base64url_encode(pool, sig_buf[0..sig_len]) orelse error.EncodeFailed;
    }

    pub fn deinit(self: *Self) void {
        if (self.md_ctx) |ctx| EVP_MD_CTX_free(ctx);
        if (self.pkey) |key| EVP_PKEY_free(key);
        self.pkey = null;
        self.md_ctx = null;
    }
};

// ============================================================================
// JWS (JSON Web Signature) for ACME - RFC 7515
// ============================================================================

// JWS format for ACME:
// {
//   "protected": base64url({"alg":"RS256","nonce":"...","url":"...","kid":"..."})
//   "payload": base64url(payload_json) or "" for POST-as-GET
//   "signature": base64url(RS256(protected.payload))
// }

pub fn createJws(
    pool: [*c]ngx_pool_t,
    account_key: *AcmeAccountKey,
    nonce: ngx_str_t,
    url: ngx_str_t,
    kid: ?ngx_str_t, // account URL, null for new account (use jwk instead)
    payload: ?ngx_str_t, // null for POST-as-GET
) !ngx_str_t {
    // Build protected header
    const protected = try buildProtectedHeader(pool, account_key, nonce, url, kid);
    const protected_b64 = base64url_encode(pool, core.slicify(u8, protected.data, protected.len)) orelse return error.EncodeFailed;

    // Encode payload (or empty string for POST-as-GET)
    var payload_b64: ngx_str_t = undefined;
    if (payload) |p| {
        payload_b64 = base64url_encode(pool, core.slicify(u8, p.data, p.len)) orelse return error.EncodeFailed;
    } else {
        payload_b64 = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
    }

    // Create signing input: protected.payload
    const signing_input_len = protected_b64.len + 1 + payload_b64.len;
    const signing_input = core.castPtr(u8, core.ngx_pnalloc(pool, signing_input_len)) orelse return error.AllocFailed;

    var pos: usize = 0;
    @memcpy(signing_input[pos .. pos + protected_b64.len], core.slicify(u8, protected_b64.data, protected_b64.len));
    pos += protected_b64.len;
    signing_input[pos] = '.';
    pos += 1;
    if (payload_b64.len > 0) {
        @memcpy(signing_input[pos .. pos + payload_b64.len], core.slicify(u8, payload_b64.data, payload_b64.len));
    }

    // Sign
    const signature = try account_key.signRs256(core.slicify(u8, signing_input, signing_input_len), pool);

    // Build JWS JSON
    return buildJwsJson(pool, protected_b64, payload_b64, signature);
}

fn buildProtectedHeader(
    pool: [*c]ngx_pool_t,
    account_key: *AcmeAccountKey,
    nonce: ngx_str_t,
    url: ngx_str_t,
    kid: ?ngx_str_t,
) !ngx_str_t {
    // Calculate size
    // {"alg":"RS256","nonce":"...","url":"...", "kid":"..."} or
    // {"alg":"RS256","jwk":{...},"nonce":"...","url":"..."}

    if (kid) |k| {
        // With kid (existing account)
        const template = "{\"alg\":\"RS256\",\"kid\":\"";
        const mid1 = "\",\"nonce\":\"";
        const mid2 = "\",\"url\":\"";
        const suffix = "\"}";

        const len = template.len + k.len + mid1.len + nonce.len + mid2.len + url.len + suffix.len;
        const buf = core.castPtr(u8, core.ngx_pnalloc(pool, len)) orelse return error.AllocFailed;

        var pos: usize = 0;
        @memcpy(buf[pos .. pos + template.len], template);
        pos += template.len;
        @memcpy(buf[pos .. pos + k.len], core.slicify(u8, k.data, k.len));
        pos += k.len;
        @memcpy(buf[pos .. pos + mid1.len], mid1);
        pos += mid1.len;
        @memcpy(buf[pos .. pos + nonce.len], core.slicify(u8, nonce.data, nonce.len));
        pos += nonce.len;
        @memcpy(buf[pos .. pos + mid2.len], mid2);
        pos += mid2.len;
        @memcpy(buf[pos .. pos + url.len], core.slicify(u8, url.data, url.len));
        pos += url.len;
        @memcpy(buf[pos .. pos + suffix.len], suffix);

        return ngx_str_t{ .len = len, .data = buf };
    } else {
        // With JWK (new account registration)
        const e_b64 = base64url_encode(pool, account_key.e_bytes) orelse return error.EncodeFailed;
        const n_b64 = base64url_encode(pool, account_key.n_bytes) orelse return error.EncodeFailed;

        const template = "{\"alg\":\"RS256\",\"jwk\":{\"e\":\"";
        const mid1 = "\",\"kty\":\"RSA\",\"n\":\"";
        const mid2 = "\"},\"nonce\":\"";
        const mid3 = "\",\"url\":\"";
        const suffix = "\"}";

        const len = template.len + e_b64.len + mid1.len + n_b64.len + mid2.len + nonce.len + mid3.len + url.len + suffix.len;
        const buf = core.castPtr(u8, core.ngx_pnalloc(pool, len)) orelse return error.AllocFailed;

        var pos: usize = 0;
        @memcpy(buf[pos .. pos + template.len], template);
        pos += template.len;
        @memcpy(buf[pos .. pos + e_b64.len], core.slicify(u8, e_b64.data, e_b64.len));
        pos += e_b64.len;
        @memcpy(buf[pos .. pos + mid1.len], mid1);
        pos += mid1.len;
        @memcpy(buf[pos .. pos + n_b64.len], core.slicify(u8, n_b64.data, n_b64.len));
        pos += n_b64.len;
        @memcpy(buf[pos .. pos + mid2.len], mid2);
        pos += mid2.len;
        @memcpy(buf[pos .. pos + nonce.len], core.slicify(u8, nonce.data, nonce.len));
        pos += nonce.len;
        @memcpy(buf[pos .. pos + mid3.len], mid3);
        pos += mid3.len;
        @memcpy(buf[pos .. pos + url.len], core.slicify(u8, url.data, url.len));
        pos += url.len;
        @memcpy(buf[pos .. pos + suffix.len], suffix);

        return ngx_str_t{ .len = len, .data = buf };
    }
}

fn buildJwsJson(
    pool: [*c]ngx_pool_t,
    protected: ngx_str_t,
    payload: ngx_str_t,
    signature: ngx_str_t,
) !ngx_str_t {
    const prefix = "{\"protected\":\"";
    const mid1 = "\",\"payload\":\"";
    const mid2 = "\",\"signature\":\"";
    const suffix = "\"}";

    const len = prefix.len + protected.len + mid1.len + payload.len + mid2.len + signature.len + suffix.len;
    const buf = core.castPtr(u8, core.ngx_pnalloc(pool, len)) orelse return error.AllocFailed;

    var pos: usize = 0;
    @memcpy(buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos .. pos + protected.len], core.slicify(u8, protected.data, protected.len));
    pos += protected.len;
    @memcpy(buf[pos .. pos + mid1.len], mid1);
    pos += mid1.len;
    if (payload.len > 0) {
        @memcpy(buf[pos .. pos + payload.len], core.slicify(u8, payload.data, payload.len));
        pos += payload.len;
    }
    @memcpy(buf[pos .. pos + mid2.len], mid2);
    pos += mid2.len;
    @memcpy(buf[pos .. pos + signature.len], core.slicify(u8, signature.data, signature.len));
    pos += signature.len;
    @memcpy(buf[pos .. pos + suffix.len], suffix);

    return ngx_str_t{ .len = len, .data = buf };
}

// ============================================================================
// CSR (Certificate Signing Request) Generation
// ============================================================================

// X509_REQ bindings
const ASN1_STRING = ssl.ASN1_STRING;
const GENERAL_NAMES = ssl.GENERAL_NAMES;
const X509_REQ = ssl.X509_REQ;
const X509_NAME = ssl.X509_NAME;
const X509_EXTENSION = ssl.X509_EXTENSION;
const X509_EXTENSIONS = ssl.X509_EXTENSIONS;
const X509V3_CTX = ssl.X509V3_CTX;
const d2i_X509_REQ = ssl.d2i_X509_REQ;
const X509_REQ_new = ssl.X509_REQ_new;
const X509_REQ_free = ssl.X509_REQ_free;
const X509_REQ_set_version = ssl.X509_REQ_set_version;
const X509_REQ_get_subject_name = ssl.X509_REQ_get_subject_name;
const X509_REQ_get_extensions = ssl.X509_REQ_get_extensions;
const X509_REQ_set_pubkey = ssl.X509_REQ_set_pubkey;
const X509_REQ_sign = ssl.X509_REQ_sign;
const X509_REQ_add_extensions = ssl.X509_REQ_add_extensions;
const X509_NAME_get_text_by_NID = ssl.X509_NAME_get_text_by_NID;
const X509_NAME_add_entry_by_txt = ssl.X509_NAME_add_entry_by_txt;
const ASN1_STRING_length = ssl.ASN1_STRING_length;
const ASN1_STRING_get0_data = ssl.ASN1_STRING_get0_data;
const GENERAL_NAME_get0_value = ssl.GENERAL_NAME_get0_value;
const GENERAL_NAMES_free = ssl.GENERAL_NAMES_free;
const X509_EXTENSION_free = ssl.X509_EXTENSION_free;
const X509V3_EXT_conf_nid = ssl.X509V3_EXT_conf_nid;
const X509V3_get_d2i = ssl.X509V3_get_d2i;
const X509V3_set_ctx = ssl.X509V3_set_ctx;
const X509v3_add_ext = ssl.X509v3_add_ext;
const sk_GENERAL_NAME_num = ssl.sk_GENERAL_NAME_num;
const sk_GENERAL_NAME_value = ssl.sk_GENERAL_NAME_value;
const sk_X509_EXTENSION_pop_free = ssl.sk_X509_EXTENSION_pop_free;
const i2d_X509_REQ = ssl.i2d_X509_REQ;
const GEN_DNS = ssl.GEN_DNS;
const MBSTRING_ASC = ssl.MBSTRING_ASC;
const NID_commonName = ssl.NID_commonName;
const NID_subject_alt_name = ssl.NID_subject_alt_name;
const V_ASN1_IA5STRING = ssl.V_ASN1_IA5STRING;

fn decode_csr_request(pool: [*c]ngx_pool_t, csr: ngx_str_t) !*X509_REQ {
    const der = base64url_decode(pool, csr) orelse return error.CsrDecodeFailed;
    var der_ptr: [*c]const u8 = der.data;
    return d2i_X509_REQ(null, &der_ptr, @intCast(der.len)) orelse error.CsrDecodeFailed;
}

fn assert_csr_subject_cn(req: *X509_REQ, expected_domain: []const u8) !void {
    const subject_name = X509_REQ_get_subject_name(req) orelse return error.CsrSubjectFailed;
    var cn_buf: [256]u8 = undefined;
    const cn_len = X509_NAME_get_text_by_NID(subject_name, NID_commonName, cn_buf[0..].ptr, @intCast(cn_buf.len));
    if (cn_len <= 0) return error.CsrCnFailed;
    try std.testing.expectEqualStrings(expected_domain, cn_buf[0..@intCast(cn_len)]);
}

fn assert_csr_single_dns_san(req: *X509_REQ, expected_domain: []const u8) !void {
    const exts = X509_REQ_get_extensions(req) orelse return error.CsrSanFailed;
    defer sk_X509_EXTENSION_pop_free(exts, X509_EXTENSION_free);

    const san_any = X509V3_get_d2i(exts, NID_subject_alt_name, null, null) orelse return error.CsrSanFailed;
    const san_names: *GENERAL_NAMES = @ptrCast(@alignCast(san_any));
    defer GENERAL_NAMES_free(san_names);

    const san_count: usize = @intCast(sk_GENERAL_NAME_num(san_names));
    try std.testing.expectEqual(@as(usize, 1), san_count);

    const san_entry = sk_GENERAL_NAME_value(san_names, 0);
    var san_type: c_int = 0;
    const san_value_any = GENERAL_NAME_get0_value(san_entry, &san_type) orelse return error.CsrSanFailed;

    try std.testing.expectEqual(@as(c_int, GEN_DNS), san_type);

    const san_value: [*c]const ASN1_STRING = @ptrCast(@alignCast(san_value_any));
    try std.testing.expectEqual(@as(c_int, V_ASN1_IA5STRING), san_value.*.type);

    const san_len: usize = @intCast(ASN1_STRING_length(san_value));
    const san_data = ASN1_STRING_get0_data(san_value);
    try std.testing.expectEqualStrings(expected_domain, san_data[0..san_len]);
}

/// Generate a Certificate Signing Request (CSR) for a domain
/// Returns base64url-encoded DER format CSR
pub fn generateCsr(pool: [*c]ngx_pool_t, domain: ngx_str_t, pkey: *EVP_PKEY) !ngx_str_t {
    _ = OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null);

    // Create new X509_REQ
    const req = X509_REQ_new() orelse return error.CsrCreateFailed;
    defer X509_REQ_free(req);

    // Set version to 0 (v1)
    if (X509_REQ_set_version(req, 0) != 1) {
        return error.CsrVersionFailed;
    }

    // Get subject name and add CN
    const subject_name = X509_REQ_get_subject_name(req) orelse return error.CsrSubjectFailed;

    // Add Common Name (CN) with the domain
    if (X509_NAME_add_entry_by_txt(
        subject_name,
        "CN",
        @intCast(MBSTRING_ASC),
        domain.data,
        @intCast(domain.len),
        -1,
        0,
    ) != 1) {
        return error.CsrCnFailed;
    }

    // Set public key
    if (X509_REQ_set_pubkey(req, pkey) != 1) {
        return error.CsrPubkeyFailed;
    }

    var san_value_buf: [512]u8 = undefined;
    if (domain.len + 4 > san_value_buf.len) {
        return error.CsrSanFailed;
    }
    @memcpy(san_value_buf[0..4], "DNS:");
    if (domain.len > 0) {
        @memcpy(san_value_buf[4 .. 4 + domain.len], core.slicify(u8, domain.data, domain.len));
    }
    san_value_buf[4 + domain.len] = 0;

    var v3_ctx: X509V3_CTX = undefined;
    X509V3_set_ctx(&v3_ctx, null, null, req, null, 0);

    const san_ext = X509V3_EXT_conf_nid(null, &v3_ctx, NID_subject_alt_name, &san_value_buf[0]) orelse {
        return error.CsrSanFailed;
    };

    var exts: ?*X509_EXTENSIONS = null;
    if (X509v3_add_ext(&exts, san_ext, -1) == null) {
        X509_EXTENSION_free(san_ext);
        return error.CsrSanFailed;
    }
    defer if (exts) |stack| {
        sk_X509_EXTENSION_pop_free(stack, X509_EXTENSION_free);
    };

    if (X509_REQ_add_extensions(req, exts) != 1) {
        return error.CsrSanFailed;
    }

    // Sign with SHA256
    if (X509_REQ_sign(req, pkey, EVP_sha256()) == 0) {
        return error.CsrSignFailed;
    }

    // Convert to DER format
    // First call to get size
    var der_len = i2d_X509_REQ(req, null);
    if (der_len <= 0) {
        return error.CsrDerFailed;
    }

    // Allocate buffer for DER
    const der_buf = core.castPtr(u8, core.ngx_pnalloc(pool, @intCast(der_len))) orelse return error.AllocFailed;

    // Second call to actually encode
    var der_ptr: [*c]u8 = der_buf;
    der_len = i2d_X509_REQ(req, &der_ptr);
    if (der_len <= 0) {
        return error.CsrDerFailed;
    }

    // Base64url encode the DER
    return base64url_encode(pool, core.slicify(u8, der_buf, @intCast(der_len))) orelse error.EncodeFailed;
}

/// Domain key for certificate (separate from account key)
pub const AcmeDomainKey = struct {
    const Self = @This();

    pkey: ?*EVP_PKEY,

    pub fn generate(pool: [*c]ngx_pool_t) !Self {
        _ = pool;
        _ = OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null);

        // Generate 2048-bit RSA key for the certificate
        const pkey = EVP_RSA_gen(2048) orelse return error.KeyGenFailed;

        return Self{
            .pkey = pkey,
        };
    }

    pub fn loadFromPem(pem: ngx_str_t) !Self {
        _ = OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null);

        const bio = BIO_new_mem_buf(pem.data, @intCast(pem.len)) orelse return error.BioFailed;
        defer _ = BIO_free(bio);

        const pkey = PEM_read_bio_PrivateKey(bio, null, null, null) orelse return error.PemParseFailed;

        return Self{
            .pkey = pkey,
        };
    }

    pub fn toPem(self: *Self, pool: [*c]ngx_pool_t) !ngx_str_t {
        const bio = BIO_new(BIO_s_mem()) orelse return error.BioFailed;
        defer _ = BIO_free(bio);

        if (PEM_write_bio_PrivateKey(bio, self.pkey, null, null, 0, null, null) != 1) {
            return error.PemWriteFailed;
        }

        // Get the PEM data from BIO
        var data: [*c]u8 = undefined;
        const len = BIO_ctrl(bio, BIO_CTRL_INFO, 0, @ptrCast(&data));

        if (len <= 0) return error.BioEmpty;

        // Copy to pool
        const pem_buf = core.castPtr(u8, core.ngx_pnalloc(pool, @intCast(len))) orelse return error.AllocFailed;
        @memcpy(core.slicify(u8, pem_buf, @intCast(len)), core.slicify(u8, data, @intCast(len)));

        return ngx_str_t{ .len = @intCast(len), .data = pem_buf };
    }

    pub fn createCsr(self: *Self, pool: [*c]ngx_pool_t, domain: ngx_str_t) !ngx_str_t {
        return generateCsr(pool, domain, self.pkey orelse return error.NullKey);
    }

    pub fn deinit(self: *Self) void {
        if (self.pkey) |key| EVP_PKEY_free(key);
        self.pkey = null;
    }
};

// ============================================================================
// File Storage
// ============================================================================

/// ACME storage manager for account keys, domain keys, and certificates
/// Storage layout:
///   {storage_path}/
///   ├── account.key           # RSA private key (PEM)
///   └── certs/
///       └── {domain}/
///           ├── privkey.pem   # Domain private key
///           └── fullchain.pem # Certificate + intermediates
pub const AcmeStorage = struct {
    const Self = @This();

    storage_path: []const u8,

    fn localIo() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    pub fn init(path: []const u8) Self {
        return Self{ .storage_path = path };
    }

    /// Ensure storage directories exist
    pub fn ensureDirectories(self: *Self) !void {
        const io = localIo();

        // Create base directory
        std.Io.Dir.cwd().createDirPath(io, self.storage_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Create certs subdirectory
        var path_buf: [512]u8 = undefined;
        const certs_path = std.fmt.bufPrint(&path_buf, "{s}/certs", .{self.storage_path}) catch return error.PathTooLong;
        std.Io.Dir.cwd().createDirPath(io, certs_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    /// Ensure domain directory exists
    pub fn ensureDomainDir(self: *Self, domain: []const u8) !void {
        const io = localIo();
        var path_buf: [512]u8 = undefined;
        const domain_path = std.fmt.bufPrint(&path_buf, "{s}/certs/{s}", .{ self.storage_path, domain }) catch return error.PathTooLong;
        std.Io.Dir.cwd().createDirPath(io, domain_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    // ---- Account Key ----

    pub fn accountKeyPath(self: *Self, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/account.key", .{self.storage_path}) catch return error.PathTooLong;
    }

    fn writeFileAtomic(path: []const u8, pem: []const u8, mode: u32) !void {
        const io = localIo();
        var tmp_buf: [1024]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return error.PathTooLong;

        var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .permissions = .fromMode(mode) });
        defer file.close(io);
        try file.writeStreamingAll(io, pem);

        var old_z: [1024]u8 = undefined;
        @memcpy(old_z[0..tmp_path.len], tmp_path);
        old_z[tmp_path.len] = 0;
        var new_z: [1024]u8 = undefined;
        @memcpy(new_z[0..path.len], path);
        new_z[path.len] = 0;

        if (std.c.rename(@ptrCast(&old_z[0]), @ptrCast(&new_z[0])) != 0) {
            return error.RenameFailed;
        }
    }

    pub fn saveAccountKey(self: *Self, pem: []const u8) !void {
        var path_buf: [512]u8 = undefined;
        const path = try self.accountKeyPath(&path_buf);
        try writeFileAtomic(path, pem, 0o600);
    }

    pub fn loadAccountKey(self: *Self, buf: []u8) ![]const u8 {
        const io = localIo();
        var path_buf: [512]u8 = undefined;
        const path = try self.accountKeyPath(&path_buf);

        return std.Io.Dir.cwd().readFile(io, path, buf) catch return error.AccountKeyNotFound;
    }

    pub fn accountKeyExists(self: *Self) bool {
        const io = localIo();
        var path_buf: [512]u8 = undefined;
        const path = self.accountKeyPath(&path_buf) catch return false;
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
        return true;
    }

    // ---- Domain Key ----

    pub fn domainKeyPath(self: *Self, domain: []const u8, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/certs/{s}/privkey.pem", .{ self.storage_path, domain }) catch return error.PathTooLong;
    }

    pub fn saveDomainKey(self: *Self, domain: []const u8, pem: []const u8) !void {
        try self.ensureDomainDir(domain);
        var path_buf: [512]u8 = undefined;
        const path = try self.domainKeyPath(domain, &path_buf);
        try writeFileAtomic(path, pem, 0o600);
    }

    pub fn loadDomainKey(self: *Self, domain: []const u8, buf: []u8) ![]const u8 {
        const io = localIo();
        var path_buf: [512]u8 = undefined;
        const path = try self.domainKeyPath(domain, &path_buf);

        return std.Io.Dir.cwd().readFile(io, path, buf) catch return error.DomainKeyNotFound;
    }

    pub fn domainKeyExists(self: *Self, domain: []const u8) bool {
        const io = localIo();
        var path_buf: [512]u8 = undefined;
        const path = self.domainKeyPath(domain, &path_buf) catch return false;
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
        return true;
    }

    // ---- Certificate ----

    pub fn certPath(self: *Self, domain: []const u8, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/certs/{s}/fullchain.pem", .{ self.storage_path, domain }) catch return error.PathTooLong;
    }

    pub fn saveCertificate(self: *Self, domain: []const u8, pem: []const u8) !void {
        try self.ensureDomainDir(domain);
        var path_buf: [512]u8 = undefined;
        const path = try self.certPath(domain, &path_buf);
        try writeFileAtomic(path, pem, 0o644);
    }

    pub fn loadCertificate(self: *Self, domain: []const u8, buf: []u8) ![]const u8 {
        const io = localIo();
        var path_buf: [512]u8 = undefined;
        const path = try self.certPath(domain, &path_buf);

        return std.Io.Dir.cwd().readFile(io, path, buf) catch return error.CertNotFound;
    }

    pub fn certExists(self: *Self, domain: []const u8) bool {
        const io = localIo();
        var path_buf: [512]u8 = undefined;
        const path = self.certPath(domain, &path_buf) catch return false;
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
        return true;
    }

    /// Remove all storage for a domain
    pub fn removeDomain(self: *Self, domain: []const u8) !void {
        const io = localIo();
        var path_buf: [512]u8 = undefined;
        const domain_path = std.fmt.bufPrint(&path_buf, "{s}/certs/{s}", .{ self.storage_path, domain }) catch return error.PathTooLong;
        std.Io.Dir.cwd().deleteTree(io, domain_path) catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }

    /// Clean up entire storage (for testing)
    pub fn removeAll(self: *Self) void {
        const io = localIo();
        std.Io.Dir.cwd().deleteTree(io, self.storage_path) catch {};
    }
};

// ============================================================================
// Certificate Expiry Checking
// ============================================================================

// X509 certificate parsing bindings
const X509 = ssl.X509;
const X509_free = ssl.X509_free;
const PEM_read_bio_X509 = ssl.PEM_read_bio_X509;
const X509_get_notAfter = ssl.X509_get_notAfter;
const ASN1_TIME_diff = ssl.ASN1_TIME_diff;

/// Get days until certificate expires
/// Returns negative if already expired, positive if still valid
pub fn getCertDaysRemaining(cert_pem: []const u8) !i32 {
    _ = OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null);

    const bio = BIO_new_mem_buf(cert_pem.ptr, @intCast(cert_pem.len)) orelse return error.BioFailed;
    defer _ = BIO_free(bio);

    const cert = PEM_read_bio_X509(bio, null, null, null) orelse return error.CertParseFailed;
    defer X509_free(cert);

    const not_after = X509_get_notAfter(cert);
    if (not_after == null) return error.CertNoExpiry;

    var days: c_int = 0;
    var secs: c_int = 0;

    // ASN1_TIME_diff compares to current time if first arg is null
    if (ASN1_TIME_diff(&days, &secs, null, not_after) != 1) {
        return error.TimeDiffFailed;
    }

    return days;
}

/// Check if certificate needs renewal
pub fn certNeedsRenewal(cert_pem: []const u8, renew_before_days: u32) !bool {
    const days_remaining = try getCertDaysRemaining(cert_pem);
    return days_remaining <= @as(i32, @intCast(renew_before_days));
}

// ============================================================================
// ACME Client - Protocol State Machine and Request Builder
// ============================================================================

/// ACME protocol states
pub const AcmeState = enum {
    idle, // Not started
    need_directory, // Need to fetch directory
    need_nonce, // Need to get a fresh nonce
    need_account, // Need to register/lookup account
    need_order, // Need to create certificate order
    need_order_poll, // Need to poll existing order status
    need_authorization, // Need to get authorization details
    need_challenge_ready, // Need to signal challenge ready
    waiting_validation, // Waiting for ACME server to validate
    need_finalize, // Need to finalize order with CSR
    need_certificate, // Need to download certificate
    complete, // Certificate obtained
    err, // Error state
};

fn acme_state_name(state: AcmeState) []const u8 {
    return switch (state) {
        .idle => "idle",
        .need_directory => "need_directory",
        .need_nonce => "need_nonce",
        .need_account => "need_account",
        .need_order => "need_order",
        .need_order_poll => "need_order_poll",
        .need_authorization => "need_authorization",
        .need_challenge_ready => "need_challenge_ready",
        .waiting_validation => "waiting_validation",
        .need_finalize => "need_finalize",
        .need_certificate => "need_certificate",
        .complete => "complete",
        .err => "err",
    };
}

/// ACME directory endpoints (parsed from /directory response)
pub const AcmeDirectory = struct {
    new_nonce: ngx_str_t,
    new_account: ngx_str_t,
    new_order: ngx_str_t,
    revoke_cert: ngx_str_t,
    key_change: ngx_str_t,

    pub fn init() AcmeDirectory {
        return AcmeDirectory{
            .new_nonce = ngx_null_str,
            .new_account = ngx_null_str,
            .new_order = ngx_null_str,
            .revoke_cert = ngx_null_str,
            .key_change = ngx_null_str,
        };
    }

    /// Parse directory JSON response
    pub fn parse(pool: [*c]ngx_pool_t, json_body: []const u8) !AcmeDirectory {
        const CJSON = ngx.cjson.CJSON;
        var cj = CJSON.init(pool);
        const json = try cj.decode(ngx_str_t{ .len = json_body.len, .data = @constCast(json_body.ptr) });

        var dir = AcmeDirectory.init();

        if (CJSON.query(json, "$.newNonce")) |n| if (CJSON.stringValue(n)) |v| {
            dir.new_nonce = v;
        };
        if (CJSON.query(json, "$.newAccount")) |n| if (CJSON.stringValue(n)) |v| {
            dir.new_account = v;
        };
        if (CJSON.query(json, "$.newOrder")) |n| if (CJSON.stringValue(n)) |v| {
            dir.new_order = v;
        };
        if (CJSON.query(json, "$.revokeCert")) |n| if (CJSON.stringValue(n)) |v| {
            dir.revoke_cert = v;
        };
        if (CJSON.query(json, "$.keyChange")) |n| if (CJSON.stringValue(n)) |v| {
            dir.key_change = v;
        };

        // Verify required endpoints are present
        if (dir.new_nonce.len == 0 or dir.new_account.len == 0 or dir.new_order.len == 0) {
            return error.InvalidDirectory;
        }

        return dir;
    }
};

/// ACME order state
pub const AcmeOrder = struct {
    order_url: ngx_str_t, // URL of the order (from Location header)
    finalize_url: ngx_str_t, // URL to finalize the order
    certificate_url: ngx_str_t, // URL to download certificate (after finalization)
    authorization_urls: [8]ngx_str_t, // URLs for authorization objects
    authorization_count: usize,
    status: ngx_str_t, // "pending", "ready", "processing", "valid", "invalid"

    pub fn init() AcmeOrder {
        return AcmeOrder{
            .order_url = ngx_null_str,
            .finalize_url = ngx_null_str,
            .certificate_url = ngx_null_str,
            .authorization_urls = [_]ngx_str_t{ngx_null_str} ** 8,
            .authorization_count = 0,
            .status = ngx_null_str,
        };
    }

    /// Parse order JSON response
    pub fn parse(self: *AcmeOrder, pool: [*c]ngx_pool_t, json_body: []const u8) !void {
        const CJSON = ngx.cjson.CJSON;
        var cj = CJSON.init(pool);
        const json = try cj.decode(ngx_str_t{ .len = json_body.len, .data = @constCast(json_body.ptr) });

        self.finalize_url = ngx_null_str;
        self.certificate_url = ngx_null_str;
        self.authorization_urls = [_]ngx_str_t{ngx_null_str} ** 8;
        self.authorization_count = 0;
        self.status = ngx_null_str;

        if (CJSON.query(json, "$.status")) |n| if (CJSON.stringValue(n)) |v| {
            self.status = v;
        };
        if (CJSON.query(json, "$.finalize")) |n| if (CJSON.stringValue(n)) |v| {
            self.finalize_url = v;
        };
        if (CJSON.query(json, "$.certificate")) |n| if (CJSON.stringValue(n)) |v| {
            self.certificate_url = v;
        };

        // Parse authorizations array
        if (CJSON.query(json, "$.authorizations")) |auth_array| {
            if (CJSON.arrValue(auth_array)) |arr| {
                var it = CJSON.Iterator.init(arr);
                while (it.next()) |item| {
                    if (self.authorization_count < self.authorization_urls.len) {
                        if (CJSON.stringValue(item)) |url| {
                            self.authorization_urls[self.authorization_count] = url;
                            self.authorization_count += 1;
                        }
                    }
                }
            }
        }
    }
};

/// ACME authorization state
pub const AcmeAuthorization = struct {
    challenge_url: ngx_str_t, // URL to POST to signal challenge ready
    challenge_token: ngx_str_t, // Token for HTTP-01 challenge
    status: ngx_str_t, // "pending", "valid", "invalid"

    pub fn init() AcmeAuthorization {
        return AcmeAuthorization{
            .challenge_url = ngx_null_str,
            .challenge_token = ngx_null_str,
            .status = ngx_null_str,
        };
    }

    /// Parse authorization JSON response, extract HTTP-01 challenge
    pub fn parse(self: *AcmeAuthorization, pool: [*c]ngx_pool_t, json_body: []const u8) !void {
        const CJSON = ngx.cjson.CJSON;
        var cj = CJSON.init(pool);
        const json = try cj.decode(ngx_str_t{ .len = json_body.len, .data = @constCast(json_body.ptr) });

        self.challenge_url = ngx_null_str;
        self.challenge_token = ngx_null_str;
        self.status = ngx_null_str;

        if (CJSON.query(json, "$.status")) |n| if (CJSON.stringValue(n)) |v| {
            self.status = v;
        };

        // Find HTTP-01 challenge in challenges array
        if (CJSON.query(json, "$.challenges")) |chlgs| {
            if (CJSON.arrValue(chlgs)) |arr| {
                var it = CJSON.Iterator.init(arr);
                while (it.next()) |challenge| {
                    if (CJSON.query(challenge, "$.type")) |type_node| {
                        if (CJSON.stringValue(type_node)) |challenge_type| {
                            if (std.mem.eql(u8, core.slicify(u8, challenge_type.data, challenge_type.len), "http-01")) {
                                if (CJSON.query(challenge, "$.url")) |url_node| {
                                    if (CJSON.stringValue(url_node)) |v| self.challenge_url = v;
                                }
                                if (CJSON.query(challenge, "$.token")) |token_node| {
                                    if (CJSON.stringValue(token_node)) |v| self.challenge_token = v;
                                }
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
};

/// ACME Client - manages protocol state and builds requests
pub const AcmeClient = struct {
    const Self = @This();

    pool: [*c]ngx_pool_t,
    state: AcmeState,
    directory_url: ngx_str_t,
    domain: ngx_str_t,

    // Protocol state
    directory: AcmeDirectory,
    current_nonce: ngx_str_t,
    account_url: ngx_str_t, // kid for JWS
    order: AcmeOrder,
    authorization: AcmeAuthorization,
    current_auth_index: usize, // Which authorization we're processing

    // Keys
    account_key: ?*AcmeAccountKey,
    domain_key: ?*AcmeDomainKey,

    // Error info
    last_error: ngx_str_t,
    last_debug: ngx_str_t,

    pub fn init(pool: [*c]ngx_pool_t, directory_url: ngx_str_t, domain: ngx_str_t) Self {
        return Self{
            .pool = pool,
            .state = .idle,
            .directory_url = directory_url,
            .domain = domain,
            .directory = AcmeDirectory.init(),
            .current_nonce = ngx_null_str,
            .account_url = ngx_null_str,
            .order = AcmeOrder.init(),
            .authorization = AcmeAuthorization.init(),
            .current_auth_index = 0,
            .account_key = null,
            .domain_key = null,
            .last_error = ngx_null_str,
            .last_debug = ngx_null_str,
        };
    }

    fn setDebug(self: *Self, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        if (duplicate_bytes(self.pool, msg)) |copy| {
            self.last_debug = ngx_str_t{ .len = copy.len, .data = @constCast(copy.ptr) };
        }
    }

    /// Set account key (must be called before starting)
    pub fn setAccountKey(self: *Self, key: *AcmeAccountKey) void {
        self.account_key = key;
    }

    /// Set domain key (must be called before finalization)
    pub fn setDomainKey(self: *Self, key: *AcmeDomainKey) void {
        self.domain_key = key;
    }

    /// Update nonce from response header
    pub fn updateNonce(self: *Self, nonce: ngx_str_t) void {
        self.current_nonce = nonce;
    }

    /// Start the ACME flow
    pub fn start(self: *Self) void {
        self.state = .need_directory;
    }

    // ---- Request Builders ----

    /// Build HTTP request for fetching directory
    pub fn buildDirectoryRequest(self: *Self) !AcmeHttpRequest {
        return AcmeHttpRequest{
            .method = .GET,
            .url = self.directory_url,
            .body = ngx_null_str,
            .content_type = ngx_null_str,
        };
    }

    /// Build HTTP request for getting a nonce
    pub fn buildNonceRequest(self: *Self) !AcmeHttpRequest {
        return AcmeHttpRequest{
            .method = .HEAD,
            .url = self.directory.new_nonce,
            .body = ngx_null_str,
            .content_type = ngx_null_str,
        };
    }

    /// Build HTTP request for account registration
    pub fn buildAccountRequest(self: *Self) !AcmeHttpRequest {
        const key = self.account_key orelse return error.NoAccountKey;

        // Payload: {"termsOfServiceAgreed": true, "contact": ["mailto:..."]}
        const payload = ngx_string("{\"termsOfServiceAgreed\":true}");

        const jws = try createJws(
            self.pool,
            key,
            self.current_nonce,
            self.directory.new_account,
            null, // No kid for new account (uses embedded JWK)
            payload,
        );

        return AcmeHttpRequest{
            .method = .POST,
            .url = self.directory.new_account,
            .body = jws,
            .content_type = ngx_string("application/jose+json"),
        };
    }

    /// Build HTTP request for creating an order
    pub fn buildOrderRequest(self: *Self) !AcmeHttpRequest {
        const key = self.account_key orelse return error.NoAccountKey;

        // Build payload: {"identifiers": [{"type": "dns", "value": "domain"}]}
        const payload_template = "{\"identifiers\":[{\"type\":\"dns\",\"value\":\"";
        const payload_suffix = "\"}]}";
        const payload_len = payload_template.len + self.domain.len + payload_suffix.len;
        const payload_buf = core.castPtr(u8, core.ngx_pnalloc(self.pool, payload_len)) orelse return error.AllocFailed;

        var pos: usize = 0;
        @memcpy(payload_buf[pos .. pos + payload_template.len], payload_template);
        pos += payload_template.len;
        @memcpy(payload_buf[pos .. pos + self.domain.len], core.slicify(u8, self.domain.data, self.domain.len));
        pos += self.domain.len;
        @memcpy(payload_buf[pos .. pos + payload_suffix.len], payload_suffix);

        const payload = ngx_str_t{ .len = payload_len, .data = payload_buf };

        const jws = try createJws(
            self.pool,
            key,
            self.current_nonce,
            self.directory.new_order,
            self.account_url,
            payload,
        );

        return AcmeHttpRequest{
            .method = .POST,
            .url = self.directory.new_order,
            .body = jws,
            .content_type = ngx_string("application/jose+json"),
        };
    }

    /// Build HTTP request for polling an existing order
    pub fn buildOrderPollRequest(self: *Self) !AcmeHttpRequest {
        const key = self.account_key orelse return error.NoAccountKey;

        const jws = try createJws(
            self.pool,
            key,
            self.current_nonce,
            self.order.order_url,
            self.account_url,
            null,
        );

        return AcmeHttpRequest{
            .method = .POST,
            .url = self.order.order_url,
            .body = jws,
            .content_type = ngx_string("application/jose+json"),
        };
    }

    /// Build HTTP request for getting authorization details
    pub fn buildAuthorizationRequest(self: *Self) !AcmeHttpRequest {
        const key = self.account_key orelse return error.NoAccountKey;

        if (self.current_auth_index >= self.order.authorization_count) {
            return error.NoMoreAuthorizations;
        }

        const auth_url = self.order.authorization_urls[self.current_auth_index];

        // POST-as-GET (empty payload)
        const jws = try createJws(
            self.pool,
            key,
            self.current_nonce,
            auth_url,
            self.account_url,
            null, // Empty payload for POST-as-GET
        );

        return AcmeHttpRequest{
            .method = .POST,
            .url = auth_url,
            .body = jws,
            .content_type = ngx_string("application/jose+json"),
        };
    }

    /// Build HTTP request for signaling challenge ready
    pub fn buildChallengeReadyRequest(self: *Self) !AcmeHttpRequest {
        const key = self.account_key orelse return error.NoAccountKey;

        // Empty object payload to signal ready
        const payload = ngx_string("{}");

        const jws = try createJws(
            self.pool,
            key,
            self.current_nonce,
            self.authorization.challenge_url,
            self.account_url,
            payload,
        );

        return AcmeHttpRequest{
            .method = .POST,
            .url = self.authorization.challenge_url,
            .body = jws,
            .content_type = ngx_string("application/jose+json"),
        };
    }

    /// Build HTTP request for finalizing order with CSR
    pub fn buildFinalizeRequest(self: *Self) !AcmeHttpRequest {
        const key = self.account_key orelse return error.NoAccountKey;
        const domain_key = self.domain_key orelse return error.NoDomainKey;

        // Generate CSR
        const csr = try domain_key.createCsr(self.pool, self.domain);

        // Build payload: {"csr": "base64url-encoded-csr"}
        const payload_prefix = "{\"csr\":\"";
        const payload_suffix = "\"}";
        const payload_len = payload_prefix.len + csr.len + payload_suffix.len;
        const payload_buf = core.castPtr(u8, core.ngx_pnalloc(self.pool, payload_len)) orelse return error.AllocFailed;

        var pos: usize = 0;
        @memcpy(payload_buf[pos .. pos + payload_prefix.len], payload_prefix);
        pos += payload_prefix.len;
        @memcpy(payload_buf[pos .. pos + csr.len], core.slicify(u8, csr.data, csr.len));
        pos += csr.len;
        @memcpy(payload_buf[pos .. pos + payload_suffix.len], payload_suffix);

        const payload = ngx_str_t{ .len = payload_len, .data = payload_buf };

        const jws = try createJws(
            self.pool,
            key,
            self.current_nonce,
            self.order.finalize_url,
            self.account_url,
            payload,
        );

        return AcmeHttpRequest{
            .method = .POST,
            .url = self.order.finalize_url,
            .body = jws,
            .content_type = ngx_string("application/jose+json"),
        };
    }

    /// Build HTTP request for downloading certificate
    pub fn buildCertificateRequest(self: *Self) !AcmeHttpRequest {
        const key = self.account_key orelse return error.NoAccountKey;

        // POST-as-GET
        const jws = try createJws(
            self.pool,
            key,
            self.current_nonce,
            self.order.certificate_url,
            self.account_url,
            null,
        );

        return AcmeHttpRequest{
            .method = .POST,
            .url = self.order.certificate_url,
            .body = jws,
            .content_type = ngx_string("application/jose+json"),
        };
    }

    // ---- Response Handlers ----

    /// Handle directory response
    pub fn handleDirectoryResponse(self: *Self, body: []const u8) !void {
        self.directory = try AcmeDirectory.parse(self.pool, body);
        self.state = .need_nonce;
    }

    /// Handle nonce response (nonce is in header, already updated via updateNonce)
    pub fn handleNonceResponse(self: *Self) void {
        if (self.account_url.len == 0) {
            self.state = .need_account;
        } else {
            self.state = .need_order;
        }
    }

    /// Handle account response
    pub fn handleAccountResponse(self: *Self, account_url: ngx_str_t) void {
        self.account_url = account_url;
        self.state = .need_order;
    }

    /// Handle order response
    pub fn handleOrderResponse(self: *Self, order_url: ngx_str_t, body: []const u8) !void {
        self.order.order_url = order_url;
        try self.order.parse(self.pool, body);

        // Check order status
        const status = core.slicify(u8, self.order.status.data, self.order.status.len);
        if (std.mem.eql(u8, status, "ready")) {
            self.state = .need_finalize;
        } else if (std.mem.eql(u8, status, "valid")) {
            self.state = .need_certificate;
        } else if (std.mem.eql(u8, status, "pending")) {
            self.current_auth_index = 0;
            self.state = .need_authorization;
        } else {
            self.state = .err;
            self.last_error = self.order.status;
        }
    }

    /// Handle authorization response
    pub fn handleAuthorizationResponse(self: *Self, body: []const u8) !void {
        try self.authorization.parse(self.pool, body);

        const status = core.slicify(u8, self.authorization.status.data, self.authorization.status.len);
        const token_len = self.authorization.challenge_token.len;
        if (std.mem.eql(u8, status, "valid")) {
            self.setDebug("auth status=valid token_len={d}", .{token_len});
            // This authorization is already valid, check next
            self.current_auth_index += 1;
            if (self.current_auth_index >= self.order.authorization_count) {
                self.state = .need_finalize;
            } else {
                self.state = .need_authorization;
            }
        } else if (std.mem.eql(u8, status, "pending")) {
            self.setDebug("auth status=pending token_len={d}", .{token_len});
            // Need to complete challenge
            self.state = .need_challenge_ready;
        } else {
            self.setDebug("auth status=other token_len={d}", .{token_len});
            self.state = .err;
            self.last_error = self.authorization.status;
        }
    }

    /// Handle challenge ready response
    pub fn handleChallengeReadyResponse(self: *Self) void {
        self.state = .waiting_validation;
    }

    /// Handle finalize response
    pub fn handleFinalizeResponse(self: *Self, body: []const u8) !void {
        try self.order.parse(self.pool, body);

        const status = core.slicify(u8, self.order.status.data, self.order.status.len);
        if (std.mem.eql(u8, status, "valid")) {
            self.state = .need_certificate;
        } else if (std.mem.eql(u8, status, "processing")) {
            // Need to poll order status
            self.state = .need_order_poll;
        } else {
            self.state = .err;
            self.last_error = self.order.status;
        }
    }

    /// Handle certificate response (returns the PEM certificate)
    pub fn handleCertificateResponse(self: *Self, body: []const u8) []const u8 {
        self.state = .complete;
        return body;
    }

    /// Prepare challenge for HTTP-01 validation
    /// Returns the key authorization to serve at /.well-known/acme-challenge/{token}
    pub fn prepareChallenge(self: *Self) !ngx_str_t {
        const key = self.account_key orelse return error.NoAccountKey;

        // Get thumbprint
        const thumbprint = key.getThumbprint(self.pool) orelse return error.ThumbprintFailed;

        // Key authorization = token.thumbprint
        const token = self.authorization.challenge_token;
        const key_auth_len = token.len + 1 + thumbprint.len;
        const key_auth_buf = core.castPtr(u8, core.ngx_pnalloc(self.pool, key_auth_len)) orelse return error.AllocFailed;

        var pos: usize = 0;
        @memcpy(key_auth_buf[pos .. pos + token.len], core.slicify(u8, token.data, token.len));
        pos += token.len;
        key_auth_buf[pos] = '.';
        pos += 1;
        @memcpy(key_auth_buf[pos .. pos + thumbprint.len], core.slicify(u8, thumbprint.data, thumbprint.len));

        return ngx_str_t{ .len = key_auth_len, .data = key_auth_buf };
    }

    /// Register the challenge in the challenge storage
    pub fn registerChallenge(self: *Self) !void {
        self.setDebug("register start token_len={d}", .{self.authorization.challenge_token.len});
        const key_auth = try self.prepareChallenge();
        const token_slice = core.slicify(u8, self.authorization.challenge_token.data, self.authorization.challenge_token.len);
        const shpool = getAcmeShpool();
        if (shpool) |sp| shm.ngx_shmtx_lock(&sp.*.mutex);
        defer if (shpool) |sp| shm.ngx_shmtx_unlock(&sp.*.mutex);

        // Add to challenge storage (expires in 5 minutes)
        if (!add_challenge(
            self.authorization.challenge_token,
            key_auth,
            self.domain,
            if (http.ngx_cycle == core.nullptr(core.ngx_cycle_t)) std.math.maxInt(ngx_msec_t) else ngx_current_msec + 5 * 60 * 1000,
        )) {
            self.setDebug("register failed add_challenge token_len={d}", .{token_slice.len});
            return error.ChallengeFull;
        }
        self.setDebug("register ok token_len={d}", .{token_slice.len});
    }
};

/// HTTP request method
pub const HttpMethod = enum {
    GET,
    HEAD,
    POST,
};

/// HTTP request structure for ACME operations
pub const AcmeHttpRequest = struct {
    method: HttpMethod,
    url: ngx_str_t,
    body: ngx_str_t,
    content_type: ngx_str_t,

    const user_agent = "nginz-acme/0.1";

    /// Build raw HTTP/1.1 request bytes
    pub fn build(self: *const AcmeHttpRequest, pool: [*c]ngx_pool_t, host: ngx_str_t) !ngx_str_t {
        // Parse path from URL
        const url_slice = core.slicify(u8, self.url.data, self.url.len);
        var path_start: usize = 0;

        // Skip scheme
        if (std.mem.indexOf(u8, url_slice, "://")) |idx| {
            path_start = idx + 3;
            // Find end of host
            if (std.mem.indexOfScalar(u8, url_slice[path_start..], '/')) |slash_idx| {
                path_start = path_start + slash_idx;
            } else {
                path_start = url_slice.len;
            }
        }

        const path = if (path_start < url_slice.len) url_slice[path_start..] else "/";

        // Method string
        const method_str = switch (self.method) {
            .GET => "GET",
            .HEAD => "HEAD",
            .POST => "POST",
        };

        // Calculate request size
        var size: usize = method_str.len + 1 + path.len + " HTTP/1.1\r\n".len;
        size += "Host: ".len + host.len + "\r\n".len;
        size += "User-Agent: ".len + user_agent.len + "\r\n".len;

        if (self.content_type.len > 0) {
            size += "Content-Type: ".len + self.content_type.len + "\r\n".len;
        }
        if (self.body.len > 0) {
            size += "Content-Length: ".len + 10 + "\r\n".len; // 10 digits for length
        }
        size += "\r\n".len; // End of headers
        size += self.body.len;

        // Allocate buffer
        const buf = core.castPtr(u8, core.ngx_pnalloc(pool, size)) orelse return error.AllocFailed;
        var pos: usize = 0;

        // Request line
        @memcpy(buf[pos .. pos + method_str.len], method_str);
        pos += method_str.len;
        buf[pos] = ' ';
        pos += 1;
        @memcpy(buf[pos .. pos + path.len], path);
        pos += path.len;
        const http_version = " HTTP/1.1\r\n";
        @memcpy(buf[pos .. pos + http_version.len], http_version);
        pos += http_version.len;

        // Host header
        const host_header = "Host: ";
        @memcpy(buf[pos .. pos + host_header.len], host_header);
        pos += host_header.len;
        @memcpy(buf[pos .. pos + host.len], core.slicify(u8, host.data, host.len));
        pos += host.len;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;

        // User-Agent header (Pebble requires this)
        const ua_header = "User-Agent: ";
        @memcpy(buf[pos .. pos + ua_header.len], ua_header);
        pos += ua_header.len;
        @memcpy(buf[pos .. pos + user_agent.len], user_agent);
        pos += user_agent.len;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;

        // Content-Type
        if (self.content_type.len > 0) {
            const ct_header = "Content-Type: ";
            @memcpy(buf[pos .. pos + ct_header.len], ct_header);
            pos += ct_header.len;
            @memcpy(buf[pos .. pos + self.content_type.len], core.slicify(u8, self.content_type.data, self.content_type.len));
            pos += self.content_type.len;
            buf[pos] = '\r';
            buf[pos + 1] = '\n';
            pos += 2;
        }

        // Content-Length
        if (self.body.len > 0) {
            const cl_header = "Content-Length: ";
            @memcpy(buf[pos .. pos + cl_header.len], cl_header);
            pos += cl_header.len;

            // Convert body length to string
            var len_buf: [10]u8 = undefined;
            const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{self.body.len}) catch return error.FormatFailed;
            @memcpy(buf[pos .. pos + len_str.len], len_str);
            pos += len_str.len;
            buf[pos] = '\r';
            buf[pos + 1] = '\n';
            pos += 2;
        }

        // End of headers
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;

        // Body
        if (self.body.len > 0) {
            @memcpy(buf[pos .. pos + self.body.len], core.slicify(u8, self.body.data, self.body.len));
            pos += self.body.len;
        }

        return ngx_str_t{ .len = pos, .data = buf };
    }
};

// ============================================================================
// Config Structures
// ============================================================================

pub const acme_main_conf = extern struct {
    enabled: ngx_flag_t,
    allow_insecure_http: ngx_flag_t,
    directory_url: ngx_str_t,
    trusted_certificate: ngx_str_t,
    account_email: ngx_str_t,
    storage_path: ngx_str_t,
    renew_before_days: ngx_uint_t,

    // Computed thumbprint (set after account key is loaded)
    account_thumbprint: ngx_str_t,
    ups: http.ngx_http_upstream_conf_t,
};

pub const acme_srv_conf = extern struct {
    domain: ngx_str_t,
};

const ACME_ZONE_SIZE: usize = 1024 * 1024;
const MAX_ACME_SESSIONS = 16;
const MAX_ACME_AUTH_URLS = 8;
const ACME_MAX_DOMAIN_LEN = 256;
const ACME_MAX_URL_LEN = 1024;
const ACME_MAX_TOKEN_LEN = 256;
const ACME_MAX_KEY_AUTH_LEN = 768;
const ACME_MAX_STATUS_LEN = 64;
const ACME_MAX_DEBUG_LEN = 256;

const acme_challenge_entry = extern struct {
    in_use: ngx_flag_t,
    expires: ngx_msec_t,
    token_len: usize,
    key_authorization_len: usize,
    domain_len: usize,
    token: [ACME_MAX_TOKEN_LEN]u8,
    key_authorization: [ACME_MAX_KEY_AUTH_LEN]u8,
    domain: [ACME_MAX_DOMAIN_LEN]u8,
};

const acme_session_entry = extern struct {
    in_use: ngx_flag_t,
    state: u32,
    current_auth_index: usize,
    authorization_count: usize,
    domain_len: usize,
    directory_url_len: usize,
    current_nonce_len: usize,
    account_url_len: usize,
    directory_new_nonce_len: usize,
    directory_new_account_len: usize,
    directory_new_order_len: usize,
    directory_revoke_cert_len: usize,
    directory_key_change_len: usize,
    order_url_len: usize,
    finalize_url_len: usize,
    certificate_url_len: usize,
    order_status_len: usize,
    authorization_challenge_url_len: usize,
    authorization_challenge_token_len: usize,
    authorization_status_len: usize,
    last_error_len: usize,
    last_debug_len: usize,
    auth_url_lens: [MAX_ACME_AUTH_URLS]usize,
    domain: [ACME_MAX_DOMAIN_LEN]u8,
    directory_url: [ACME_MAX_URL_LEN]u8,
    current_nonce: [ACME_MAX_URL_LEN]u8,
    account_url: [ACME_MAX_URL_LEN]u8,
    directory_new_nonce: [ACME_MAX_URL_LEN]u8,
    directory_new_account: [ACME_MAX_URL_LEN]u8,
    directory_new_order: [ACME_MAX_URL_LEN]u8,
    directory_revoke_cert: [ACME_MAX_URL_LEN]u8,
    directory_key_change: [ACME_MAX_URL_LEN]u8,
    order_url: [ACME_MAX_URL_LEN]u8,
    finalize_url: [ACME_MAX_URL_LEN]u8,
    certificate_url: [ACME_MAX_URL_LEN]u8,
    order_status: [ACME_MAX_STATUS_LEN]u8,
    authorization_challenge_url: [ACME_MAX_URL_LEN]u8,
    authorization_challenge_token: [ACME_MAX_TOKEN_LEN]u8,
    authorization_status: [ACME_MAX_STATUS_LEN]u8,
    last_error: [ACME_MAX_DEBUG_LEN]u8,
    last_debug: [ACME_MAX_DEBUG_LEN]u8,
    auth_urls: [MAX_ACME_AUTH_URLS][ACME_MAX_URL_LEN]u8,
};

const acme_store = extern struct {
    initialized: ngx_flag_t,
    challenge_count: ngx_uint_t,
    session_count: ngx_uint_t,
    challenges: [MAX_CHALLENGES]acme_challenge_entry,
    sessions: [MAX_ACME_SESSIONS]acme_session_entry,
};

var ngx_http_acme_zone: [*c]core.ngx_shm_zone_t = core.nullptr(core.ngx_shm_zone_t);
var acme_test_store: acme_store = std.mem.zeroes(acme_store);

fn getAcmeStore() ?*acme_store {
    if (ngx_http_acme_zone != core.nullptr(core.ngx_shm_zone_t)) {
        if (core.castPtr(acme_store, ngx_http_acme_zone.*.data)) |store| {
            return store;
        }
    }
    return &acme_test_store;
}

fn getAcmeShpool() ?[*c]core.ngx_slab_pool_t {
    const zone = ngx_http_acme_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.shm.addr == null or zone.*.data == null) {
        return null;
    }
    return core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr);
}

fn ngx_http_acme_zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        zone.*.data = data;
        return NGX_OK;
    }

    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        zone.*.data = shpool.*.data;
        return NGX_OK;
    }

    const store_mem = shm.ngx_slab_calloc(shpool, @sizeOf(acme_store)) orelse return NGX_ERROR;
    const store = core.castPtr(acme_store, store_mem) orelse return NGX_ERROR;
    store.* = std.mem.zeroes(acme_store);
    store.*.initialized = 1;
    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

fn init_upstream_conf(ups: [*c]http.ngx_http_upstream_conf_t) void {
    ups.*.buffering = 0;
    ups.*.buffer_size = 32 * ngx_pagesize;
    ups.*.ssl_verify = 1;
    ups.*.ssl_server_name = 1;
    ups.*.ssl_session_reuse = 1;
    ups.*.connect_timeout = 60000;
    ups.*.send_timeout = 60000;
    ups.*.read_timeout = 60000;
    ups.*.module = ngx_string("ngx_http_acme_module");
    ups.*.hide_headers = conf.NGX_CONF_UNSET_PTR;
    ups.*.pass_headers = conf.NGX_CONF_UNSET_PTR;
}

// ============================================================================
// Challenge Storage
// ============================================================================

// Active challenge entry
pub const acme_challenge_t = struct {
    token: ngx_str_t,
    key_authorization: ngx_str_t,
    domain: ngx_str_t,
    expires: ngx_msec_t,
};

// Simple challenge storage (shared-memory, array-based)
const MAX_CHALLENGES = 32;

fn duplicate_ngx_str(pool: [*c]ngx_pool_t, value: ngx_str_t) ?ngx_str_t {
    if (value.len == 0 or value.data == core.nullptr(u8)) {
        return ngx_null_str;
    }

    const buf = core.castPtr(u8, core.ngx_pnalloc(pool, value.len)) orelse return null;
    @memcpy(buf[0..value.len], core.slicify(u8, value.data, value.len));
    return ngx_str_t{ .len = value.len, .data = buf };
}

fn duplicate_bytes(pool: [*c]ngx_pool_t, value: []const u8) ?[]const u8 {
    if (value.len == 0) {
        return &.{};
    }

    const buf = core.castPtr(u8, core.ngx_pnalloc(pool, value.len)) orelse return null;
    @memcpy(buf[0..value.len], value);
    return buf[0..value.len];
}

pub fn add_challenge(token: ngx_str_t, key_auth: ngx_str_t, domain: ngx_str_t, expires: ngx_msec_t) bool {
    const store = getAcmeStore() orelse return false;

    if (store.*.challenge_count >= MAX_CHALLENGES) {
        cleanup_expired_challenges();
        if (store.*.challenge_count >= MAX_CHALLENGES) {
            return false;
        }
    }

    for (0..MAX_CHALLENGES) |i| {
        const slot = &(store.*.challenges[i]);
        if (slot.*.in_use == 0) {
            if (!fixed_string_write(&slot.*.token, &slot.*.token_len, ngx_str_slice(token))) return false;
            if (!fixed_string_write(&slot.*.key_authorization, &slot.*.key_authorization_len, ngx_str_slice(key_auth))) return false;
            if (!fixed_string_write(&slot.*.domain, &slot.*.domain_len, ngx_str_slice(domain))) return false;
            slot.*.expires = expires;
            slot.*.in_use = 1;
            store.*.challenge_count += 1;
            return true;
        }
    }
    return false;
}

pub fn find_challenge(pool: [*c]ngx_pool_t, token: []const u8, domain: []const u8) ?acme_challenge_t {
    const store = getAcmeStore() orelse return null;
    for (0..MAX_CHALLENGES) |i| {
        const slot = &(store.*.challenges[i]);
        if (slot.*.in_use == 1) {
            const stored_token = fixed_string_slice(&slot.*.token, slot.*.token_len);
            const stored_domain = fixed_string_slice(&slot.*.domain, slot.*.domain_len);
            if (std.mem.eql(u8, stored_token, token) and std.mem.eql(u8, stored_domain, domain)) {
                return acme_challenge_t{
                    .token = pool_string_from_slice(pool, stored_token) orelse return null,
                    .key_authorization = pool_string_from_slice(pool, fixed_string_slice(&slot.*.key_authorization, slot.*.key_authorization_len)) orelse return null,
                    .domain = pool_string_from_slice(pool, stored_domain) orelse return null,
                    .expires = slot.*.expires,
                };
            }
        }
    }
    return null;
}

pub fn remove_challenge(token: []const u8) void {
    const store = getAcmeStore() orelse return;
    for (0..MAX_CHALLENGES) |i| {
        const slot = &(store.*.challenges[i]);
        if (slot.*.in_use == 1) {
            const stored_token = fixed_string_slice(&slot.*.token, slot.*.token_len);
            if (std.mem.eql(u8, stored_token, token)) {
                slot.* = std.mem.zeroes(acme_challenge_entry);
                if (store.*.challenge_count > 0) store.*.challenge_count -= 1;
                return;
            }
        }
    }
}

// External variable for current time (only used at runtime, not in tests)
extern var ngx_current_msec: ngx_msec_t;

fn cleanup_expired_challenges() void {
    // Note: ngx_current_msec is only available at nginx runtime
    // During tests, we use maxInt for expires so this won't affect tests
    const now = ngx_current_msec;
    const store = getAcmeStore() orelse return;
    for (0..MAX_CHALLENGES) |i| {
        const slot = &(store.*.challenges[i]);
        if (slot.*.in_use == 1 and slot.*.expires < now) {
            slot.* = std.mem.zeroes(acme_challenge_entry);
            if (store.*.challenge_count > 0) store.*.challenge_count -= 1;
        }
    }
}

fn find_session_entry(store: *acme_store, domain: []const u8) ?*acme_session_entry {
    for (0..MAX_ACME_SESSIONS) |i| {
        const entry = &store.sessions[i];
        if (entry.*.in_use == 1 and std.mem.eql(u8, fixed_string_slice(&entry.*.domain, entry.*.domain_len), domain)) {
            return entry;
        }
    }
    return null;
}

fn get_or_create_session_entry(store: *acme_store, domain: []const u8) ?*acme_session_entry {
    if (find_session_entry(store, domain)) |entry| return entry;

    for (0..MAX_ACME_SESSIONS) |i| {
        const entry = &store.sessions[i];
        if (entry.*.in_use == 0) {
            entry.* = std.mem.zeroes(acme_session_entry);
            entry.*.in_use = 1;
            if (!fixed_string_write(&entry.*.domain, &entry.*.domain_len, domain)) {
                entry.* = std.mem.zeroes(acme_session_entry);
                return null;
            }
            entry.*.state = @intFromEnum(AcmeState.idle);
            store.session_count += 1;
            return entry;
        }
    }
    return null;
}

fn session_string_to_pool(pool: [*c]ngx_pool_t, bytes: []const u8) !ngx_str_t {
    return pool_string_from_slice(pool, bytes) orelse error.AllocFailed;
}

fn session_write_ngx_str(dest: []u8, dest_len: *usize, value: ngx_str_t) !void {
    if (!fixed_string_write(dest, dest_len, ngx_str_slice(value))) return error.StringTooLong;
}

fn session_clear_ngx_str(dest: []u8, dest_len: *usize) void {
    fixed_string_clear(dest, dest_len);
}

fn load_client_from_session(
    pool: [*c]ngx_pool_t,
    entry: *const acme_session_entry,
    directory_url: ngx_str_t,
    domain: ngx_str_t,
) !AcmeClient {
    var client = AcmeClient.init(pool, directory_url, domain);

    client.state = @enumFromInt(entry.state);
    client.directory_url = try session_string_to_pool(pool, fixed_string_slice(&entry.directory_url, entry.directory_url_len));
    if (client.directory_url.len == 0) {
        client.directory_url = directory_url;
    }
    client.current_nonce = try session_string_to_pool(pool, fixed_string_slice(&entry.current_nonce, entry.current_nonce_len));
    client.account_url = try session_string_to_pool(pool, fixed_string_slice(&entry.account_url, entry.account_url_len));
    client.directory.new_nonce = try session_string_to_pool(pool, fixed_string_slice(&entry.directory_new_nonce, entry.directory_new_nonce_len));
    client.directory.new_account = try session_string_to_pool(pool, fixed_string_slice(&entry.directory_new_account, entry.directory_new_account_len));
    client.directory.new_order = try session_string_to_pool(pool, fixed_string_slice(&entry.directory_new_order, entry.directory_new_order_len));
    client.directory.revoke_cert = try session_string_to_pool(pool, fixed_string_slice(&entry.directory_revoke_cert, entry.directory_revoke_cert_len));
    client.directory.key_change = try session_string_to_pool(pool, fixed_string_slice(&entry.directory_key_change, entry.directory_key_change_len));
    client.order.order_url = try session_string_to_pool(pool, fixed_string_slice(&entry.order_url, entry.order_url_len));
    client.order.finalize_url = try session_string_to_pool(pool, fixed_string_slice(&entry.finalize_url, entry.finalize_url_len));
    client.order.certificate_url = try session_string_to_pool(pool, fixed_string_slice(&entry.certificate_url, entry.certificate_url_len));
    client.order.status = try session_string_to_pool(pool, fixed_string_slice(&entry.order_status, entry.order_status_len));
    client.authorization.challenge_url = try session_string_to_pool(pool, fixed_string_slice(&entry.authorization_challenge_url, entry.authorization_challenge_url_len));
    client.authorization.challenge_token = try session_string_to_pool(pool, fixed_string_slice(&entry.authorization_challenge_token, entry.authorization_challenge_token_len));
    client.authorization.status = try session_string_to_pool(pool, fixed_string_slice(&entry.authorization_status, entry.authorization_status_len));
    client.last_error = try session_string_to_pool(pool, fixed_string_slice(&entry.last_error, entry.last_error_len));
    client.last_debug = try session_string_to_pool(pool, fixed_string_slice(&entry.last_debug, entry.last_debug_len));
    client.current_auth_index = entry.current_auth_index;
    client.order.authorization_count = entry.authorization_count;

    for (0..entry.authorization_count) |i| {
        client.order.authorization_urls[i] = try session_string_to_pool(pool, fixed_string_slice(&entry.auth_urls[i], entry.auth_url_lens[i]));
    }

    return client;
}

fn save_client_to_session(entry: *acme_session_entry, client: *const AcmeClient) !void {
    entry.*.state = @intFromEnum(client.state);
    entry.*.current_auth_index = client.current_auth_index;
    entry.*.authorization_count = client.order.authorization_count;
    try session_write_ngx_str(&entry.*.directory_url, &entry.*.directory_url_len, client.directory_url);
    try session_write_ngx_str(&entry.*.current_nonce, &entry.*.current_nonce_len, client.current_nonce);
    try session_write_ngx_str(&entry.*.account_url, &entry.*.account_url_len, client.account_url);
    try session_write_ngx_str(&entry.*.directory_new_nonce, &entry.*.directory_new_nonce_len, client.directory.new_nonce);
    try session_write_ngx_str(&entry.*.directory_new_account, &entry.*.directory_new_account_len, client.directory.new_account);
    try session_write_ngx_str(&entry.*.directory_new_order, &entry.*.directory_new_order_len, client.directory.new_order);
    try session_write_ngx_str(&entry.*.directory_revoke_cert, &entry.*.directory_revoke_cert_len, client.directory.revoke_cert);
    try session_write_ngx_str(&entry.*.directory_key_change, &entry.*.directory_key_change_len, client.directory.key_change);
    try session_write_ngx_str(&entry.*.order_url, &entry.*.order_url_len, client.order.order_url);
    try session_write_ngx_str(&entry.*.finalize_url, &entry.*.finalize_url_len, client.order.finalize_url);
    try session_write_ngx_str(&entry.*.certificate_url, &entry.*.certificate_url_len, client.order.certificate_url);
    try session_write_ngx_str(&entry.*.order_status, &entry.*.order_status_len, client.order.status);
    try session_write_ngx_str(&entry.*.authorization_challenge_url, &entry.*.authorization_challenge_url_len, client.authorization.challenge_url);
    try session_write_ngx_str(&entry.*.authorization_challenge_token, &entry.*.authorization_challenge_token_len, client.authorization.challenge_token);
    try session_write_ngx_str(&entry.*.authorization_status, &entry.*.authorization_status_len, client.authorization.status);
    try session_write_ngx_str(&entry.*.last_error, &entry.*.last_error_len, client.last_error);
    try session_write_ngx_str(&entry.*.last_debug, &entry.*.last_debug_len, client.last_debug);

    for (0..MAX_ACME_AUTH_URLS) |i| {
        if (i < client.order.authorization_count) {
            try session_write_ngx_str(&entry.*.auth_urls[i], &entry.*.auth_url_lens[i], client.order.authorization_urls[i]);
        } else {
            fixed_string_clear(&entry.*.auth_urls[i], &entry.*.auth_url_lens[i]);
        }
    }
}

fn initialize_session_for_domain(entry: *acme_session_entry, mcf: *acme_main_conf, domain: ngx_str_t) !void {
    entry.*.state = @intFromEnum(AcmeState.need_directory);
    entry.*.current_auth_index = 0;
    entry.*.authorization_count = 0;
    try session_write_ngx_str(&entry.*.domain, &entry.*.domain_len, domain);
    try session_write_ngx_str(&entry.*.directory_url, &entry.*.directory_url_len, mcf.directory_url);
    session_clear_ngx_str(&entry.*.current_nonce, &entry.*.current_nonce_len);
    session_clear_ngx_str(&entry.*.account_url, &entry.*.account_url_len);
    session_clear_ngx_str(&entry.*.directory_new_nonce, &entry.*.directory_new_nonce_len);
    session_clear_ngx_str(&entry.*.directory_new_account, &entry.*.directory_new_account_len);
    session_clear_ngx_str(&entry.*.directory_new_order, &entry.*.directory_new_order_len);
    session_clear_ngx_str(&entry.*.directory_revoke_cert, &entry.*.directory_revoke_cert_len);
    session_clear_ngx_str(&entry.*.directory_key_change, &entry.*.directory_key_change_len);
    session_clear_ngx_str(&entry.*.order_url, &entry.*.order_url_len);
    session_clear_ngx_str(&entry.*.finalize_url, &entry.*.finalize_url_len);
    session_clear_ngx_str(&entry.*.certificate_url, &entry.*.certificate_url_len);
    session_clear_ngx_str(&entry.*.order_status, &entry.*.order_status_len);
    session_clear_ngx_str(&entry.*.authorization_challenge_url, &entry.*.authorization_challenge_url_len);
    session_clear_ngx_str(&entry.*.authorization_challenge_token, &entry.*.authorization_challenge_token_len);
    session_clear_ngx_str(&entry.*.authorization_status, &entry.*.authorization_status_len);
    session_clear_ngx_str(&entry.*.last_error, &entry.*.last_error_len);
    session_clear_ngx_str(&entry.*.last_debug, &entry.*.last_debug_len);
    for (0..MAX_ACME_AUTH_URLS) |i| {
        fixed_string_clear(&entry.*.auth_urls[i], &entry.*.auth_url_lens[i]);
    }
}

fn load_or_create_account_key(pool: [*c]ngx_pool_t, storage: *AcmeStorage) !AcmeAccountKey {
    if (storage.accountKeyExists()) {
        var key_buf: [8192]u8 = undefined;
        const pem = try storage.loadAccountKey(&key_buf);
        return AcmeAccountKey.loadFromPem(ngx_str_t{ .len = pem.len, .data = @constCast(pem.ptr) }, pool);
    }

    var key = try AcmeAccountKey.generate(pool);
    const pem = try key.toPem(pool);
    try storage.saveAccountKey(ngx_str_slice(pem));
    return key;
}

fn load_domain_key_if_present(storage: *AcmeStorage, domain: []const u8) !?AcmeDomainKey {
    if (!storage.domainKeyExists(domain)) return null;

    var key_buf: [8192]u8 = undefined;
    const pem = try storage.loadDomainKey(domain, &key_buf);
    return try AcmeDomainKey.loadFromPem(ngx_str_t{ .len = pem.len, .data = @constCast(pem.ptr) });
}

// ============================================================================
// Configuration Functions
// ============================================================================

fn create_main_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const p = core.ngz_pcalloc_c(acme_main_conf, cf.*.pool) orelse return null;
    p.*.enabled = conf.NGX_CONF_UNSET;
    p.*.allow_insecure_http = conf.NGX_CONF_UNSET;
    p.*.renew_before_days = conf.NGX_CONF_UNSET_UINT;
    init_upstream_conf(&p.*.ups);
    return p;
}

fn init_main_conf(cf: [*c]ngx_conf_t, c: ?*anyopaque) callconv(.c) [*c]u8 {
    const mcf = core.castPtr(acme_main_conf, c) orelse return conf.NGX_CONF_ERROR;

    if (mcf.*.enabled == conf.NGX_CONF_UNSET) {
        mcf.*.enabled = 0;
    }
    if (mcf.*.allow_insecure_http == conf.NGX_CONF_UNSET) mcf.*.allow_insecure_http = 0;

    if (mcf.*.renew_before_days == conf.NGX_CONF_UNSET_UINT) {
        mcf.*.renew_before_days = 30;
    }

    // Default ACME server (Let's Encrypt production)
    if (mcf.*.directory_url.len == 0) {
        mcf.*.directory_url = ngx_string("https://acme-v02.api.letsencrypt.org/directory");
    }
    const directory_url = core.slicify(u8, mcf.*.directory_url.data, mcf.*.directory_url.len);
    if (!std.mem.startsWith(u8, directory_url, "https://") and
        !(mcf.*.allow_insecure_http == 1 and std.mem.startsWith(u8, directory_url, "http://")))
    {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_EMERG, cf.*.log, 0, "acme_server must use https unless acme_allow_insecure_http is on", .{});
        return conf.NGX_CONF_ERROR;
    }

    // Default storage path
    if (mcf.*.storage_path.len == 0) {
        mcf.*.storage_path = ngx_string("/etc/nginx/acme");
    }

    if (mcf.*.ups.ssl == core.nullptr(ssl.ngx_ssl_t)) {
        const ups_ssl = core.ngz_pcalloc_c(ssl.ngx_ssl_t, cf.*.pool) orelse return conf.NGX_CONF_ERROR;
        mcf.*.ups.ssl = ups_ssl;
    }

    if (!ssl.configure_verified_client(cf, mcf.*.ups.ssl)) return conf.NGX_CONF_ERROR;
    if (mcf.*.trusted_certificate.len > 0 and
        !ssl.add_trusted_certificate(cf, mcf.*.ups.ssl, &mcf.*.trusted_certificate))
    {
        return conf.NGX_CONF_ERROR;
    }

    return conf.NGX_CONF_OK;
}

fn create_srv_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const p = core.ngz_pcalloc_c(acme_srv_conf, cf.*.pool) orelse return null;
    return p;
}

// ============================================================================
// HTTP-01 Challenge Handler
// ============================================================================

const ACME_CHALLENGE_PREFIX = "/.well-known/acme-challenge/";

fn is_acme_challenge_uri(uri: ngx_str_t) bool {
    // Check if URI starts with the challenge prefix (including exact match for empty token)
    if (uri.len < ACME_CHALLENGE_PREFIX.len) {
        return false;
    }
    const prefix = core.slicify(u8, uri.data, ACME_CHALLENGE_PREFIX.len);
    return std.mem.eql(u8, prefix, ACME_CHALLENGE_PREFIX);
}

fn extract_token(uri: ngx_str_t) ?[]const u8 {
    if (uri.len <= ACME_CHALLENGE_PREFIX.len) {
        return null;
    }

    const token_start = ACME_CHALLENGE_PREFIX.len;
    const token = core.slicify(u8, uri.data + token_start, uri.len - token_start);

    // Validate token: should only contain base64url characters
    for (token) |c| {
        if (!((c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_'))
        {
            return null;
        }
    }

    if (token.len == 0) {
        return null;
    }

    return token;
}

export fn ngx_http_acme_challenge_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    // Check if this is an ACME challenge request
    if (!is_acme_challenge_uri(r.*.uri)) {
        return NGX_DECLINED;
    }

    // Get server config to check if acme_domain is set
    const scf = core.castPtr(acme_srv_conf, conf.ngx_http_get_module_srv_conf(r, &ngx_http_acme_module)) orelse {
        return NGX_DECLINED;
    };

    // Only handle challenges for servers with acme_domain configured
    if (scf.*.domain.len == 0) {
        return NGX_DECLINED;
    }

    // Extract token from URI
    const token = extract_token(r.*.uri) orelse {
        return http.NGX_HTTP_NOT_FOUND;
    };

    // Look up challenge
    const shpool = getAcmeShpool();
    if (shpool) |sp| shm.ngx_shmtx_lock(&sp.*.mutex);
    defer if (shpool) |sp| shm.ngx_shmtx_unlock(&sp.*.mutex);

    const challenge = find_challenge(r.*.pool, token, ngx_str_slice(scf.*.domain)) orelse {
        return http.NGX_HTTP_NOT_FOUND;
    };

    // Send response
    return send_challenge_response(r, challenge.key_authorization);
}

const NChain = ngx.buf.NChain;
const ngx_buf_t = ngx.buf.ngx_buf_t;
const ngx_chain_t = ngx.buf.ngx_chain_t;

fn send_challenge_response(r: [*c]ngx_http_request_t, key_auth: ngx_str_t) ngx_int_t {
    // Set response headers
    r.*.headers_out.status = 200;
    r.*.headers_out.content_type = ngx_string("text/plain");
    r.*.headers_out.content_type_len = 10;
    r.*.headers_out.content_length_n = @intCast(key_auth.len);

    const rc = http.ngx_http_send_header(r);
    if (rc == NGX_ERROR or rc > NGX_OK or r.*.flags1.header_only) {
        return rc;
    }

    // Create buffer for body using NChain helper
    var chain = NChain.init(r.*.pool);
    var out = ngx_chain_t{
        .buf = core.nullptr(ngx_buf_t),
        .next = core.nullptr(ngx_chain_t),
    };

    _ = chain.allocStr(key_auth, &out) catch {
        return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    };

    // Mark as last buffer
    if (out.next != core.nullptr(ngx_chain_t) and out.next.*.buf != core.nullptr(ngx_buf_t)) {
        out.next.*.buf.*.flags.last_buf = (r == r.*.main);
        out.next.*.buf.*.flags.last_in_chain = true;
    }

    const out_rc = http.ngx_http_output_filter(r, out.next);
    if (out_rc == NGX_ERROR or out_rc >= http.NGX_HTTP_SPECIAL_RESPONSE) {
        return out_rc;
    }
    http.ngx_http_finalize_request(r, out_rc);
    return NGX_DONE;
}

fn build_acme_status_json(pool: [*c]ngx_pool_t, status: []const u8, message: []const u8) ?ngx_str_t {
    const response_template = "{{\"status\":\"{s}\",\"message\":\"{s}\"}}";
    var response_buf: [256]u8 = undefined;
    const response = std.fmt.bufPrint(&response_buf, response_template, .{ status, message }) catch return null;

    const buf = core.castPtr(u8, core.ngx_pnalloc(pool, response.len)) orelse return null;
    @memcpy(buf[0..response.len], response);

    return ngx_str_t{ .len = response.len, .data = buf };
}

fn extract_acme_problem_detail(body: []const u8) ?[]const u8 {
    const key = "\"detail\"";
    const key_idx = std.mem.indexOf(u8, body, key) orelse return null;
    const after_key = body[key_idx + key.len ..];
    const colon_idx = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    var rest = after_key[colon_idx + 1 ..];

    while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\n' or rest[0] == '\r' or rest[0] == '\t')) {
        rest = rest[1..];
    }
    if (rest.len == 0 or rest[0] != '"') return null;
    rest = rest[1..];

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '"' and (i == 0 or rest[i - 1] != '\\')) {
            return rest[0..i];
        }
    }
    return null;
}

fn build_acme_upstream_error_json(pool: [*c]ngx_pool_t, status_code: ngx_uint_t, body: []const u8) ?ngx_str_t {
    var msg_buf: [256]u8 = undefined;
    const message = if (extract_acme_problem_detail(body)) |detail|
        std.fmt.bufPrint(&msg_buf, "ACME upstream {d}: {s}", .{ status_code, detail }) catch return null
    else
        std.fmt.bufPrint(&msg_buf, "ACME upstream step failed ({d})", .{status_code}) catch return null;

    return build_acme_status_json(pool, "error", message);
}

fn challenge_progress_message(pool: [*c]ngx_pool_t, client: *AcmeClient) ?ngx_str_t {
    if (client.last_debug.len > 0 and client.last_debug.data != core.nullptr(u8)) {
        return build_acme_status_json(pool, "started", core.slicify(u8, client.last_debug.data, client.last_debug.len));
    }

    if (client.authorization.challenge_token.len == 0 or client.authorization.challenge_token.data == core.nullptr(u8)) {
        return build_acme_status_json(pool, "started", "ACME step completed, call trigger again to continue");
    }

    var message_buf: [256]u8 = undefined;
    const token = core.slicify(u8, client.authorization.challenge_token.data, client.authorization.challenge_token.len);
    const message = std.fmt.bufPrint(&message_buf, "ACME step completed; challenge_token={s}", .{token}) catch return null;
    return build_acme_status_json(pool, "started", message);
}

// ============================================================================
// ACME Upstream Integration
// ============================================================================

extern var ngx_http_upstream_module: ngx_module_t;
extern var ngx_pagesize: ngx_uint_t;

/// Request context for ACME operations
const acme_request_context = extern struct {
    client: ?*anyopaque,
    account_key: ?*anyopaque,
    domain_key: ?*anyopaque,
    storage: ?*anyopaque,
    previous_challenge_token: ngx_str_t,

    // Response parsing
    status: http.ngx_http_status_t,
    response_body: ngx_str_t,
    response_nonce: ngx_str_t,
    response_location: ngx_str_t,

    // Response chain for body buffering
    res: [*c]ngx_chain_t,

    // Domain being processed
    domain: ngx_str_t,

    // Accessors
    fn getClient(self: *acme_request_context) *AcmeClient {
        return @ptrCast(@alignCast(self.client.?));
    }
    fn getAccountKey(self: *acme_request_context) *AcmeAccountKey {
        return @ptrCast(@alignCast(self.account_key.?));
    }
    fn getDomainKey(self: *acme_request_context) ?*AcmeDomainKey {
        if (self.domain_key) |dk| return @ptrCast(@alignCast(dk));
        return null;
    }
    fn getStorage(self: *acme_request_context) *AcmeStorage {
        return @ptrCast(@alignCast(self.storage.?));
    }
};

/// Parse URL to extract host, port, and SSL flag
fn parse_acme_url(url: ngx_str_t) struct { host: ngx_str_t, port: u16, use_ssl: bool } {
    const url_slice = core.slicify(u8, url.data, url.len);
    var host_start: usize = 0;
    var is_ssl = false;

    // Check scheme
    if (std.mem.startsWith(u8, url_slice, "https://")) {
        host_start = 8;
        is_ssl = true;
    } else if (std.mem.startsWith(u8, url_slice, "http://")) {
        host_start = 7;
        is_ssl = false;
    }

    // Find end of host (port or path)
    var host_end = host_start;
    var port: u16 = if (is_ssl) 443 else 80;

    while (host_end < url_slice.len) : (host_end += 1) {
        if (url_slice[host_end] == ':') {
            // Parse port
            var port_end = host_end + 1;
            while (port_end < url_slice.len and url_slice[port_end] >= '0' and url_slice[port_end] <= '9') {
                port_end += 1;
            }
            if (port_end > host_end + 1) {
                port = std.fmt.parseInt(u16, url_slice[host_end + 1 .. port_end], 10) catch port;
            }
            break;
        }
        if (url_slice[host_end] == '/') {
            break;
        }
    }

    return .{
        .host = ngx_str_t{ .len = host_end - host_start, .data = url.data + host_start },
        .port = port,
        .use_ssl = is_ssl,
    };
}

fn build_host_header(pool: [*c]ngx_pool_t, host: ngx_str_t, port: u16, use_ssl: bool) ?ngx_str_t {
    const default_port: u16 = if (use_ssl) 443 else 80;
    if (port == default_port) {
        return host;
    }

    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return null;
    const total_len = host.len + 1 + port_str.len;
    const buf = core.castPtr(u8, core.ngx_pnalloc(pool, total_len)) orelse return null;

    @memcpy(buf[0..host.len], core.slicify(u8, host.data, host.len));
    buf[host.len] = ':';
    @memcpy(buf[host.len + 1 .. total_len], port_str);

    return ngx_str_t{ .len = total_len, .data = buf };
}

/// Create upstream request callback
fn ngx_http_acme_upstream_create_request(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const rctx_c = core.castPtr(acme_request_context, r.*.ctx[ngx_http_acme_module.ctx_index]) orelse {
        return NGX_ERROR;
    };
    const rctx: *acme_request_context = @ptrCast(rctx_c);

    // Build request based on current state
    const client = rctx.getClient();
    const request = switch (client.state) {
        .need_directory => client.buildDirectoryRequest() catch return NGX_ERROR,
        .need_nonce => client.buildNonceRequest() catch return NGX_ERROR,
        .need_account => client.buildAccountRequest() catch return NGX_ERROR,
        .need_order => client.buildOrderRequest() catch return NGX_ERROR,
        .need_order_poll => client.buildOrderPollRequest() catch return NGX_ERROR,
        .need_authorization => client.buildAuthorizationRequest() catch return NGX_ERROR,
        .need_challenge_ready => client.buildChallengeReadyRequest() catch return NGX_ERROR,
        .need_finalize => client.buildFinalizeRequest() catch return NGX_ERROR,
        .need_certificate => client.buildCertificateRequest() catch return NGX_ERROR,
        else => return NGX_ERROR,
    };

    // Get host from URL
    const url_info = parse_acme_url(request.url);

    // Build raw HTTP request
    const host_header = build_host_header(r.*.pool, url_info.host, url_info.port, url_info.use_ssl) orelse return NGX_ERROR;

    const raw_request = request.build(r.*.pool, host_header) catch return NGX_ERROR;

    // Allocate chain for request
    var chain = NChain.init(r.*.pool);
    var out = ngx_chain_t{
        .buf = core.nullptr(ngx_buf_t),
        .next = core.nullptr(ngx_chain_t),
    };

    const last = chain.allocStr(raw_request, &out) catch return NGX_ERROR;
    last.*.buf.*.flags.last_buf = true;
    last.*.buf.*.flags.last_in_chain = true;

    r.*.upstream.*.request_bufs = last;
    r.*.upstream.*.flags.header_sent = false;
    r.*.upstream.*.flags.request_sent = false;
    r.*.header_hash = 1;

    return NGX_OK;
}

/// Process upstream response status line
fn ngx_http_acme_upstream_process_status(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const rctx_c = core.castPtr(acme_request_context, r.*.ctx[ngx_http_acme_module.ctx_index]) orelse {
        return NGX_ERROR;
    };
    const rctx: *acme_request_context = @ptrCast(rctx_c);

    const u = r.*.upstream;
    const rc = http.ngx_http_parse_status_line(r, &u.*.buffer, &rctx.status);

    if (rc == NGX_AGAIN) {
        return rc;
    }
    if (rc == NGX_ERROR) {
        return rc;
    }

    if (u.*.state != core.nullptr(http.ngx_http_upstream_state_t) and u.*.state.*.status == 0) {
        u.*.state.*.status = rctx.status.code;
    }

    u.*.headers_in.status_n = rctx.status.code;
    u.*.process_header = ngx_http_acme_upstream_process_header;

    return ngx_http_acme_upstream_process_header(r);
}

/// Process upstream response headers
fn ngx_http_acme_upstream_process_header(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const rctx_c = core.castPtr(acme_request_context, r.*.ctx[ngx_http_acme_module.ctx_index]) orelse {
        return NGX_ERROR;
    };
    const rctx: *acme_request_context = @ptrCast(rctx_c);

    const u = r.*.upstream;

    while (true) {
        const rc = http.ngx_http_parse_header_line(r, &u.*.buffer, 1);

        if (rc == NGX_OK) {
            // Check for Replay-Nonce header
            if (r.*.header_name_end != core.nullptr(u8) and r.*.header_start != core.nullptr(u8)) {
                const name_len = @intFromPtr(r.*.header_name_end) - @intFromPtr(r.*.header_name_start);
                const value_len = @intFromPtr(r.*.header_end) - @intFromPtr(r.*.header_start);

                if (name_len == 12) {
                    const name = core.slicify(u8, r.*.header_name_start, name_len);
                    if (std.mem.eql(u8, name, "Replay-Nonce") or std.mem.eql(u8, name, "replay-nonce")) {
                        rctx.response_nonce = ngx_str_t{
                            .len = value_len,
                            .data = r.*.header_start,
                        };
                        rctx.getClient().updateNonce(rctx.response_nonce);
                    }
                }

                // Check for Location header
                if (name_len == 8) {
                    const name = core.slicify(u8, r.*.header_name_start, name_len);
                    if (std.mem.eql(u8, name, "Location") or std.mem.eql(u8, name, "location")) {
                        rctx.response_location = ngx_str_t{
                            .len = value_len,
                            .data = r.*.header_start,
                        };
                    }
                }
            }
            continue;
        }

        if (rc == http.NGX_HTTP_PARSE_HEADER_DONE) {
            const body_len = @intFromPtr(u.*.buffer.last) - @intFromPtr(u.*.buffer.pos);
            if (body_len > 0) {
                const body_copy = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, body_len)) orelse return NGX_ERROR;
                @memcpy(body_copy[0..body_len], core.slicify(u8, u.*.buffer.pos, body_len));
                rctx.response_body = ngx_str_t{ .len = body_len, .data = body_copy };
            } else {
                rctx.response_body = ngx_null_str;
            }

            const body_slice = if (rctx.response_body.data != core.nullptr(u8) and rctx.response_body.len > 0)
                core.slicify(u8, rctx.response_body.data, rctx.response_body.len)
            else
                &.{};

            const local_response = (if (rctx.status.code >= 400)
                build_acme_upstream_error_json(r.*.pool, @intCast(rctx.status.code), body_slice)
            else
                challenge_progress_message(r.*.pool, rctx.getClient()) orelse build_acme_status_json(r.*.pool, "started", "ACME step completed, call trigger again to continue")) orelse return NGX_ERROR;

            u.*.buffer.pos = local_response.data;
            u.*.buffer.last = local_response.data + local_response.len;
            u.*.headers_in.status_n = 200;
            u.*.headers_in.content_length_n = @intCast(local_response.len);
            u.*.length = 0;

            r.*.headers_out.status = 200;
            r.*.headers_out.content_type = ngx_string("application/json");
            r.*.headers_out.content_type_len = 16;
            r.*.headers_out.content_type_lowcase = null;

            return NGX_OK;
        }

        if (rc == NGX_AGAIN) {
            return NGX_AGAIN;
        }

        return NGX_ERROR;
    }
}

/// Initialize input filter
fn ngx_http_acme_upstream_input_filter_init(ctx: ?*anyopaque) callconv(.c) ngx_int_t {
    if (core.castPtr(ngx_http_request_t, ctx)) |r| {
        const u = r.*.upstream;
        u.*.length = u.*.headers_in.content_length_n;
    }
    return NGX_OK;
}

/// Input filter for response body
fn ngx_http_acme_upstream_input_filter(ctx: ?*anyopaque, bytes: isize) callconv(.c) ngx_int_t {
    const r = core.castPtr(ngx_http_request_t, ctx) orelse return NGX_ERROR;
    const u = r.*.upstream;
    const b = &u.*.buffer;

    if (bytes > 0) {
        var ll: [*c][*c]ngx_chain_t = &u.*.out_bufs;
        while (ll.* != core.nullptr(ngx_chain_t)) {
            ll = &ll.*.*.next;
        }

        if (ngx.buf.ngx_chain_get_free_buf(r.*.pool, &u.*.free_bufs)) |cl| {
            cl.*.buf.*.flags.flush = true;
            cl.*.buf.*.flags.memory = true;

            const last = b.*.last;
            cl.*.buf.*.pos = last;
            b.*.last += @intCast(bytes);
            cl.*.buf.*.last = b.*.last;
            cl.*.buf.*.tag = u.*.output.tag;

            ll.* = cl;
            u.*.length -= bytes;

            if (u.*.length == 0) {
                u.*.flags.keepalive = true;
            }

            return NGX_OK;
        }

        return NGX_ERROR;
    }

    return NGX_OK;
}

/// Finalize upstream request
fn ngx_http_acme_upstream_finalize_request(r: [*c]ngx_http_request_t, rc: ngx_int_t) callconv(.c) void {
    const rctx_c = core.castPtr(acme_request_context, r.*.ctx[ngx_http_acme_module.ctx_index]) orelse return;
    const rctx: *acme_request_context = @ptrCast(rctx_c);
    const acme_client = rctx.getClient();
    const client_pool = acme_client.pool;

    if (rc != NGX_OK and rc != NGX_DONE) {
        acme_client.setDebug("finalize rc={d}", .{rc});
        acme_client.state = .err;
        return;
    }

    // Process response based on current state
    const status = rctx.status.code;
    const body: []const u8 = if (rctx.response_body.data != core.nullptr(u8) and rctx.response_body.len > 0)
        core.slicify(u8, rctx.response_body.data, rctx.response_body.len)
    else
        &.{};
    const stable_body = if (body.len > 0)
        (duplicate_bytes(client_pool, body) orelse {
            acme_client.setDebug("duplicate body failed len={d}", .{body.len});
            acme_client.state = .err;
            return;
        })
    else
        body;

    const previous_token = ngx_str_slice(rctx.previous_challenge_token);

    switch (acme_client.state) {
        .need_directory => {
            if (status == 200) {
                acme_client.handleDirectoryResponse(stable_body) catch {
                    acme_client.setDebug("need_directory parse failed", .{});
                    acme_client.state = .err;
                };
            } else {
                acme_client.setDebug("need_directory status={d}", .{status});
                acme_client.state = .err;
            }
        },
        .need_nonce => {
            // Nonce is in header, already processed
            acme_client.handleNonceResponse();
        },
        .need_account => {
            if (status == 200 or status == 201) {
                acme_client.handleAccountResponse(rctx.response_location);
            } else {
                acme_client.setDebug("need_account status={d}", .{status});
                acme_client.state = .err;
            }
        },
        .need_order => {
            if (status == 201) {
                acme_client.handleOrderResponse(rctx.response_location, stable_body) catch {
                    acme_client.setDebug("need_order parse failed", .{});
                    acme_client.state = .err;
                };
            } else {
                acme_client.setDebug("need_order status={d}", .{status});
                acme_client.state = .err;
            }
        },
        .need_order_poll => {
            if (status == 200) {
                const parsed_ok = blk: {
                    acme_client.order.parse(client_pool, stable_body) catch {
                        acme_client.setDebug("need_order_poll parse failed", .{});
                        acme_client.state = .err;
                        break :blk false;
                    };
                    break :blk true;
                };

                if (parsed_ok) {
                    const order_status = ngx_str_slice(acme_client.order.status);
                    if (std.mem.eql(u8, order_status, "valid")) {
                        acme_client.state = .need_certificate;
                    } else if (std.mem.eql(u8, order_status, "processing")) {
                        acme_client.state = .need_order_poll;
                    } else if (std.mem.eql(u8, order_status, "ready")) {
                        acme_client.state = .need_finalize;
                    } else if (std.mem.eql(u8, order_status, "pending")) {
                        acme_client.state = .need_authorization;
                    } else {
                        acme_client.last_error = acme_client.order.status;
                        acme_client.state = .err;
                    }
                }
            } else {
                acme_client.setDebug("need_order_poll status={d}", .{status});
                acme_client.state = .err;
            }
        },
        .need_authorization => {
            if (status == 200) {
                acme_client.handleAuthorizationResponse(stable_body) catch {
                    acme_client.setDebug("need_authorization parse failed", .{});
                    acme_client.state = .err;
                };

                // If we need to do a challenge, register it
                if (acme_client.state == .need_challenge_ready) {
                    acme_client.registerChallenge() catch {
                        acme_client.setDebug("registerChallenge failed", .{});
                        acme_client.state = .err;
                    };
                }

                if (previous_token.len > 0 and acme_client.state != .need_challenge_ready and acme_client.state != .waiting_validation) {
                    const shpool = getAcmeShpool();
                    if (shpool) |sp| shm.ngx_shmtx_lock(&sp.*.mutex);
                    remove_challenge(previous_token);
                    if (shpool) |sp| shm.ngx_shmtx_unlock(&sp.*.mutex);
                }
            } else {
                acme_client.setDebug("need_authorization status={d}", .{status});
                acme_client.state = .err;
            }
        },
        .need_challenge_ready => {
            if (status == 200) {
                acme_client.handleChallengeReadyResponse();
            } else {
                acme_client.setDebug("need_challenge_ready status={d}", .{status});
                acme_client.state = .err;
            }
        },
        .need_finalize => {
            if (status == 200) {
                acme_client.handleFinalizeResponse(stable_body) catch {
                    acme_client.setDebug("need_finalize parse failed", .{});
                    acme_client.state = .err;
                };
            } else {
                acme_client.setDebug("need_finalize status={d}", .{status});
                acme_client.state = .err;
            }
        },
        .need_certificate => {
            if (status == 200) {
                // Save the certificate!
                const cert_pem = acme_client.handleCertificateResponse(stable_body);

                // Save to storage
                const domain_slice = core.slicify(u8, rctx.domain.data, rctx.domain.len);
                const storage = rctx.getStorage();
                storage.saveCertificate(domain_slice, cert_pem) catch {
                    acme_client.setDebug("saveCertificate failed", .{});
                    acme_client.state = .err;
                };

                // Save domain key if we have it
                if (rctx.getDomainKey()) |dk| {
                    const pem = dk.toPem(r.*.pool) catch {
                        acme_client.setDebug("domainKey toPem failed", .{});
                        acme_client.state = .err;
                        return;
                    };
                    storage.saveDomainKey(domain_slice, core.slicify(u8, pem.data, pem.len)) catch {
                        acme_client.setDebug("saveDomainKey failed", .{});
                        acme_client.state = .err;
                    };
                }
            } else {
                acme_client.setDebug("need_certificate status={d}", .{status});
                acme_client.state = .err;
            }
        },
        else => {},
    }

    const domain_slice = ngx_str_slice(rctx.domain);
    const shpool = getAcmeShpool();
    if (shpool) |sp| shm.ngx_shmtx_lock(&sp.*.mutex);
    defer if (shpool) |sp| shm.ngx_shmtx_unlock(&sp.*.mutex);

    const store = getAcmeStore() orelse {
        acme_client.state = .err;
        acme_client.setDebug("shared store unavailable", .{});
        return;
    };
    const session = get_or_create_session_entry(store, domain_slice) orelse {
        acme_client.state = .err;
        acme_client.setDebug("session store full", .{});
        return;
    };
    save_client_to_session(session, acme_client) catch {
        acme_client.state = .err;
        acme_client.setDebug("session save failed", .{});
    };
}

/// Create upstream and start request
fn create_acme_upstream(r: [*c]ngx_http_request_t, rctx: *acme_request_context) !ngx_int_t {
    if (http.ngx_http_upstream_create(r) != NGX_OK) {
        return error.UpstreamCreateFailed;
    }

    const mcf = core.castPtr(acme_main_conf, conf.ngx_http_get_module_main_conf(r, &ngx_http_acme_module)) orelse {
        return error.UpstreamCreateFailed;
    };

    // Get URL for current state
    const acme_client = rctx.getClient();
    const url = switch (acme_client.state) {
        .need_directory => acme_client.directory_url,
        .need_nonce => acme_client.directory.new_nonce,
        .need_account => acme_client.directory.new_account,
        .need_order => acme_client.directory.new_order,
        .need_order_poll => acme_client.order.order_url,
        .need_authorization => acme_client.order.authorization_urls[acme_client.current_auth_index],
        .need_challenge_ready => acme_client.authorization.challenge_url,
        .need_finalize => acme_client.order.finalize_url,
        .need_certificate => acme_client.order.certificate_url,
        else => return error.InvalidState,
    };

    const url_info = parse_acme_url(url);

    // Configure upstream
    r.*.upstream.*.conf = &mcf.*.ups;
    r.*.upstream.*.flags.buffering = false;
    r.*.upstream.*.create_request = ngx_http_acme_upstream_create_request;
    r.*.upstream.*.process_header = ngx_http_acme_upstream_process_status;
    r.*.upstream.*.input_filter_init = ngx_http_acme_upstream_input_filter_init;
    r.*.upstream.*.input_filter = ngx_http_acme_upstream_input_filter;
    r.*.upstream.*.finalize_request = ngx_http_acme_upstream_finalize_request;

    // Set resolved address
    const resolved = core.ngz_pcalloc_c(http.ngx_http_upstream_resolved_t, r.*.pool) orelse return error.AllocFailed;
    r.*.upstream.*.resolved = resolved;
    r.*.upstream.*.resolved.*.host = url_info.host;
    r.*.upstream.*.resolved.*.port = url_info.port;
    r.*.upstream.*.flags.ssl = url_info.use_ssl;
    // Initialize response chain
    const chain = core.ngz_pcalloc_c(ngx_chain_t, r.*.pool) orelse return error.AllocFailed;
    rctx.res = chain;
    rctx.res.*.next = core.nullptr(ngx_chain_t);
    r.*.upstream.*.input_filter_ctx = r;

    http.ngx_http_upstream_init(r);

    return core.NGX_DONE;
}

// ============================================================================
// ACME Trigger Handler
// ============================================================================

const ACME_TRIGGER_PREFIX = "/.well-known/acme-trigger";

fn is_acme_trigger_uri(uri: ngx_str_t) bool {
    if (uri.len < ACME_TRIGGER_PREFIX.len) {
        return false;
    }
    const prefix = core.slicify(u8, uri.data, ACME_TRIGGER_PREFIX.len);
    return std.mem.eql(u8, prefix, ACME_TRIGGER_PREFIX);
}

fn worker_pool() ?[*c]ngx_pool_t {
    if (http.ngx_cycle == core.nullptr(core.ngx_cycle_t)) {
        return null;
    }
    return http.ngx_cycle.*.pool;
}

/// ACME trigger handler - advances the ACME state machine
export fn ngx_http_acme_trigger_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    // Check if this is an ACME trigger request
    if (!is_acme_trigger_uri(r.*.uri)) {
        return NGX_DECLINED;
    }

    // The trigger advances shared ACME session state and can place outbound
    // orders. Keep that surface on main requests only.
    if (r != r.*.main) {
        return http.NGX_HTTP_FORBIDDEN;
    }

    // Get main config
    const mcf = core.castPtr(acme_main_conf, conf.ngx_http_get_module_main_conf(r, &ngx_http_acme_module)) orelse {
        return NGX_DECLINED;
    };

    // Check if ACME is enabled
    if (mcf.*.enabled != 1) {
        return NGX_DECLINED;
    }

    // Get server config for domain
    const scf = core.castPtr(acme_srv_conf, conf.ngx_http_get_module_srv_conf(r, &ngx_http_acme_module)) orelse {
        return NGX_DECLINED;
    };

    if (scf.*.domain.len == 0) {
        // No domain configured - decline to let other handlers process
        return NGX_DECLINED;
    }

    const storage_ptr = core.ngz_pcalloc(AcmeStorage, r.*.pool) orelse {
        return send_acme_status_and_finalize(r, "error", "Failed to allocate storage");
    };
    storage_ptr.* = AcmeStorage.init(ngx_str_slice(mcf.*.storage_path));
    storage_ptr.ensureDirectories() catch {
        return send_acme_status_and_finalize(r, "error", "Failed to create storage directories");
    };

    const account_key_ptr = core.ngz_pcalloc(AcmeAccountKey, r.*.pool) orelse {
        return send_acme_status_and_finalize(r, "error", "Failed to allocate account key");
    };
    account_key_ptr.* = load_or_create_account_key(r.*.pool, storage_ptr) catch {
        return send_acme_status_and_finalize(r, "error", "Failed to load account key");
    };

    const domain_slice = ngx_str_slice(scf.*.domain);
    const shpool = getAcmeShpool();
    if (shpool) |sp| shm.ngx_shmtx_lock(&sp.*.mutex);

    const shared_store = getAcmeStore() orelse {
        if (shpool) |sp| shm.ngx_shmtx_unlock(&sp.*.mutex);
        return send_acme_status_code_and_finalize(r, http.NGX_HTTP_SERVICE_UNAVAILABLE, "error", "Shared ACME store unavailable");
    };
    const session = get_or_create_session_entry(shared_store, domain_slice) orelse {
        if (shpool) |sp| shm.ngx_shmtx_unlock(&sp.*.mutex);
        return send_acme_status_code_and_finalize(r, http.NGX_HTTP_SERVICE_UNAVAILABLE, "error", "Shared ACME session store full");
    };

    const was_initialized = session.*.directory_url_len > 0 or session.*.state != @intFromEnum(AcmeState.idle);
    if (!was_initialized) {
        initialize_session_for_domain(session, mcf, scf.*.domain) catch {
            if (shpool) |sp| shm.ngx_shmtx_unlock(&sp.*.mutex);
            return send_acme_status_and_finalize(r, "error", "Failed to initialize ACME session");
        };
    }

    const previous_token = pool_string_from_slice(r.*.pool, fixed_string_slice(&session.*.authorization_challenge_token, session.*.authorization_challenge_token_len)) orelse ngx_null_str;
    const client_snapshot = load_client_from_session(r.*.pool, session, mcf.*.directory_url, scf.*.domain) catch {
        if (shpool) |sp| shm.ngx_shmtx_unlock(&sp.*.mutex);
        return send_acme_status_and_finalize(r, "error", "Failed to restore ACME session");
    };

    if (shpool) |sp| shm.ngx_shmtx_unlock(&sp.*.mutex);

    if (!was_initialized) {
        return send_acme_status_and_finalize(r, "initialized", "ACME client initialized, call again to start flow");
    }

    const client = core.ngz_pcalloc(AcmeClient, r.*.pool) orelse {
        return send_acme_status_and_finalize(r, "error", "Failed to allocate ACME client");
    };
    client.* = client_snapshot;
    client.setAccountKey(account_key_ptr);

    const loaded_domain_key = load_domain_key_if_present(storage_ptr, domain_slice) catch {
        return send_acme_status_and_finalize(r, "error", "Failed to load domain key");
    };
    var domain_key_ptr: ?*AcmeDomainKey = null;
    if (loaded_domain_key) |dk| {
        domain_key_ptr = core.ngz_pcalloc(AcmeDomainKey, r.*.pool) orelse {
            return send_acme_status_and_finalize(r, "error", "Failed to allocate domain key");
        };
        domain_key_ptr.?.* = dk;
        client.setDomainKey(domain_key_ptr.?);
    }

    // Check current state and respond appropriately
    if (client.state == .complete) {
        return send_acme_status_and_finalize(r, "complete", "Certificate obtained successfully");
    }

    if (client.state == .err) {
        if (client.last_debug.len > 0 and client.last_debug.data != core.nullptr(u8)) {
            return send_acme_status_and_finalize(r, "error", core.slicify(u8, client.last_debug.data, client.last_debug.len));
        }
        if (client.last_error.len > 0 and client.last_error.data != core.nullptr(u8)) {
            return send_acme_status_and_finalize(r, "error", core.slicify(u8, client.last_error.data, client.last_error.len));
        }
        return send_acme_status_and_finalize(r, "error", "ACME error occurred");
    }

    if (client.state == .waiting_validation) {
        // Need to poll for validation - advance to check authorization
        client.state = .need_authorization;
    }

    // Generate domain key if needed for finalization
    if (client.state == .need_finalize and domain_key_ptr == null) {
        domain_key_ptr = core.ngz_pcalloc(AcmeDomainKey, r.*.pool) orelse {
            return send_acme_status_and_finalize(r, "error", "Failed to allocate domain key");
        };
        domain_key_ptr.?.* = AcmeDomainKey.generate(r.*.pool) catch {
            return send_acme_status_and_finalize(r, "error", "Failed to generate domain key");
        };
        const pem = domain_key_ptr.?.toPem(r.*.pool) catch {
            return send_acme_status_and_finalize(r, "error", "Failed to export domain key");
        };
        storage_ptr.saveDomainKey(domain_slice, ngx_str_slice(pem)) catch {
            return send_acme_status_and_finalize(r, "error", "Failed to save domain key");
        };
        client.setDomainKey(domain_key_ptr.?);
    }

    // Create request context for upstream
    const rctx = core.ngz_pcalloc(acme_request_context, r.*.pool) orelse {
        return send_acme_status_and_finalize(r, "error", "Failed to allocate request context");
    };
    rctx.* = acme_request_context{
        .client = @ptrCast(client),
        .account_key = @ptrCast(account_key_ptr),
        .domain_key = if (domain_key_ptr) |dk| @ptrCast(dk) else null,
        .storage = @ptrCast(storage_ptr),
        .previous_challenge_token = previous_token,
        .status = std.mem.zeroes(http.ngx_http_status_t),
        .response_body = ngx_null_str,
        .response_nonce = ngx_null_str,
        .response_location = ngx_null_str,
        .res = core.nullptr(ngx_chain_t),
        .domain = scf.*.domain,
    };

    r.*.ctx[ngx_http_acme_module.ctx_index] = rctx;

    // Create upstream and initiate request
    const rc = create_acme_upstream(r, rctx) catch {
        return send_acme_status_and_finalize(r, "error", "Failed to create upstream");
    };

    return rc;
}

fn send_acme_status_code(r: [*c]ngx_http_request_t, http_status: ngx_uint_t, status: []const u8, message: []const u8) ngx_int_t {
    const response = build_acme_status_json(r.*.pool, status, message) orelse return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

    // Set headers
    r.*.headers_out.status = http_status;
    r.*.headers_out.content_type = ngx_string("application/json");
    r.*.headers_out.content_type_len = 16;
    r.*.headers_out.content_length_n = @intCast(response.len);

    const rc = http.ngx_http_send_header(r);
    if (rc == NGX_ERROR or rc > NGX_OK or r.*.flags1.header_only) {
        return rc;
    }

    // Allocate response buffer
    var chain = NChain.init(r.*.pool);
    var out = ngx_chain_t{
        .buf = core.nullptr(ngx_buf_t),
        .next = core.nullptr(ngx_chain_t),
    };

    _ = chain.allocStr(response, &out) catch {
        return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    };

    if (out.next != core.nullptr(ngx_chain_t) and out.next.*.buf != core.nullptr(ngx_buf_t)) {
        out.next.*.buf.*.flags.last_buf = (r == r.*.main);
        out.next.*.buf.*.flags.last_in_chain = true;
    }

    return http.ngx_http_output_filter(r, out.next);
}

fn send_acme_status(r: [*c]ngx_http_request_t, status: []const u8, message: []const u8) ngx_int_t {
    return send_acme_status_code(r, http.NGX_HTTP_OK, status, message);
}

fn send_acme_status_code_and_finalize(r: [*c]ngx_http_request_t, http_status: ngx_uint_t, status: []const u8, message: []const u8) ngx_int_t {
    const rc = send_acme_status_code(r, http_status, status, message);
    if (rc == NGX_ERROR or rc >= http.NGX_HTTP_SPECIAL_RESPONSE) {
        return rc;
    }
    http.ngx_http_finalize_request(r, rc);
    return NGX_DONE;
}

fn send_acme_status_and_finalize(r: [*c]ngx_http_request_t, status: []const u8, message: []const u8) ngx_int_t {
    const rc = send_acme_status(r, status, message);
    if (rc == NGX_ERROR or rc >= http.NGX_HTTP_SPECIAL_RESPONSE) {
        return rc;
    }
    http.ngx_http_finalize_request(r, rc);
    return NGX_DONE;
}

// ============================================================================
// Module Registration
// ============================================================================

extern var ngx_http_core_module: ngx_module_t;

const NArray = ngx.array.NArray;

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    var zone_name = ngx_string("acme_zone");
    const zone = shm.ngx_shared_memory_add(cf, &zone_name, ACME_ZONE_SIZE, @constCast(&ngx_http_acme_module));
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return NGX_ERROR;
    zone.*.init = ngx_http_acme_zone_init;
    ngx_http_acme_zone = zone;

    // Register in PREACCESS so these URI guards also run for subrequests.
    // Nginx core skips the ACCESS phase entirely for subrequests.
    const cmcf = core.castPtr(http.ngx_http_core_main_conf_t, conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module)) orelse {
        return NGX_ERROR;
    };

    var handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_PREACCESS_PHASE].handlers,
    );

    // Register challenge handler
    const h1 = handlers.append() catch return NGX_ERROR;
    h1.* = ngx_http_acme_challenge_handler;

    // Register trigger handler
    const h2 = handlers.append() catch return NGX_ERROR;
    h2.* = ngx_http_acme_trigger_handler;

    return NGX_OK;
}

export const ngx_http_acme_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = create_main_conf,
    .init_main_conf = init_main_conf,
    .create_srv_conf = create_srv_conf,
    .merge_srv_conf = null,
    .create_loc_conf = null,
    .merge_loc_conf = null,
};

export const ngx_http_acme_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("acme"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_CONF_FLAG,
        .set = conf.ngx_conf_set_flag_slot,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = @offsetOf(acme_main_conf, "enabled"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("acme_server"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = @offsetOf(acme_main_conf, "directory_url"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("acme_allow_insecure_http"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_CONF_FLAG,
        .set = conf.ngx_conf_set_flag_slot,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = @offsetOf(acme_main_conf, "allow_insecure_http"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("acme_trusted_certificate"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = @offsetOf(acme_main_conf, "trusted_certificate"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("acme_email"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = @offsetOf(acme_main_conf, "account_email"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("acme_storage"),
        .type = conf.NGX_HTTP_MAIN_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_MAIN_CONF_OFFSET,
        .offset = @offsetOf(acme_main_conf, "storage_path"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("acme_domain"),
        .type = conf.NGX_HTTP_SRV_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_SRV_CONF_OFFSET,
        .offset = @offsetOf(acme_srv_conf, "domain"),
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_acme_module = ngx.module.make_module(
    @constCast(&ngx_http_acme_commands),
    @constCast(&ngx_http_acme_module_ctx),
);

// ============================================================================
// Unit Tests
// ============================================================================

const ngx_log_init = core.ngx_log_init;
const ngx_create_pool = core.ngx_create_pool;
const ngx_destroy_pool = core.ngx_destroy_pool;

test "base64url encode" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(4096, nlog);
    defer ngx_destroy_pool(pool);

    // Test vectors from RFC 4648
    {
        const result = base64url_encode(pool, "");
        try std.testing.expect(result != null);
        try std.testing.expectEqual(result.?.len, 0);
    }
    {
        const result = base64url_encode(pool, "f");
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings("Zg", core.slicify(u8, result.?.data, result.?.len));
    }
    {
        const result = base64url_encode(pool, "fo");
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings("Zm8", core.slicify(u8, result.?.data, result.?.len));
    }
    {
        const result = base64url_encode(pool, "foo");
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings("Zm9v", core.slicify(u8, result.?.data, result.?.len));
    }
    {
        const result = base64url_encode(pool, "foob");
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings("Zm9vYg", core.slicify(u8, result.?.data, result.?.len));
    }
    {
        const result = base64url_encode(pool, "fooba");
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings("Zm9vYmE", core.slicify(u8, result.?.data, result.?.len));
    }
    {
        const result = base64url_encode(pool, "foobar");
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings("Zm9vYmFy", core.slicify(u8, result.?.data, result.?.len));
    }
}

test "base64url encode with special chars" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(4096, nlog);
    defer ngx_destroy_pool(pool);

    // Test data that would produce + and / in standard base64
    // 0xfb, 0xff -> standard base64: "+/8" -> base64url: "-_8"
    const input = [_]u8{ 0xfb, 0xff };
    const result = base64url_encode(pool, &input);
    try std.testing.expect(result != null);

    const output = core.slicify(u8, result.?.data, result.?.len);
    // Should not contain + or /
    for (output) |c| {
        try std.testing.expect(c != '+');
        try std.testing.expect(c != '/');
    }
    // Should contain - or _ (the base64url replacements)
    try std.testing.expectEqualStrings("-_8", output);
}

test "base64url decode" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(4096, nlog);
    defer ngx_destroy_pool(pool);

    {
        const result = base64url_decode(pool, ngx_string("Zm9vYmFy"));
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings("foobar", core.slicify(u8, result.?.data, result.?.len));
    }
    {
        // With URL-safe chars
        const result = base64url_decode(pool, ngx_string("-_8"));
        try std.testing.expect(result != null);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xfb, 0xff }, core.slicify(u8, result.?.data, result.?.len));
    }
}

test "sha256 hash" {
    // Test vector: SHA256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    const hash_empty = sha256_hash("");
    try std.testing.expectEqual(hash_empty[0], 0xe3);
    try std.testing.expectEqual(hash_empty[1], 0xb0);
    try std.testing.expectEqual(hash_empty[31], 0x55);

    // Test vector: SHA256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    const hash_abc = sha256_hash("abc");
    try std.testing.expectEqual(hash_abc[0], 0xba);
    try std.testing.expectEqual(hash_abc[1], 0x78);
    try std.testing.expectEqual(hash_abc[31], 0xad);
}

test "is_acme_challenge_uri" {
    try std.testing.expect(is_acme_challenge_uri(ngx_string("/.well-known/acme-challenge/abc123")));
    try std.testing.expect(is_acme_challenge_uri(ngx_string("/.well-known/acme-challenge/a")));
    // Exact prefix match - returns true so we can return 404 for empty token
    try std.testing.expect(is_acme_challenge_uri(ngx_string("/.well-known/acme-challenge/")));
    // Without trailing slash - doesn't match the prefix
    try std.testing.expect(!is_acme_challenge_uri(ngx_string("/.well-known/acme-challenge")));
    try std.testing.expect(!is_acme_challenge_uri(ngx_string("/other/path")));
    try std.testing.expect(!is_acme_challenge_uri(ngx_string("")));
}

test "extract_token" {
    {
        const token = extract_token(ngx_string("/.well-known/acme-challenge/abc123"));
        try std.testing.expect(token != null);
        try std.testing.expectEqualStrings("abc123", token.?);
    }
    {
        const token = extract_token(ngx_string("/.well-known/acme-challenge/abc-123_XYZ"));
        try std.testing.expect(token != null);
        try std.testing.expectEqualStrings("abc-123_XYZ", token.?);
    }
    {
        // Invalid: contains path traversal
        const token = extract_token(ngx_string("/.well-known/acme-challenge/../etc/passwd"));
        try std.testing.expect(token == null);
    }
    {
        // Invalid: empty token
        const token = extract_token(ngx_string("/.well-known/acme-challenge/"));
        try std.testing.expect(token == null);
    }
}

test "challenge storage" {
    acme_test_store = std.mem.zeroes(acme_store);

    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(4096, nlog);
    defer ngx_destroy_pool(pool);

    // Add a challenge
    const token1 = ngx_string("token1");
    const key_auth1 = ngx_string("token1.thumbprint123");
    const domain1 = ngx_string("example.com");

    const added = add_challenge(token1, key_auth1, domain1, std.math.maxInt(ngx_msec_t));
    try std.testing.expect(added);
    try std.testing.expectEqual(acme_test_store.challenge_count, 1);

    // Find the challenge
    const found = find_challenge(pool, "token1", "example.com");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("token1.thumbprint123", core.slicify(u8, found.?.key_authorization.data, found.?.key_authorization.len));

    // Not found
    const not_found = find_challenge(pool, "token2", "example.com");
    try std.testing.expect(not_found == null);

    // Remove the challenge
    remove_challenge("token1");
    try std.testing.expectEqual(acme_test_store.challenge_count, 0);

    const after_remove = find_challenge(pool, "token1", "example.com");
    try std.testing.expect(after_remove == null);
}

test "challenge storage rejects capacity overflow without eviction" {
    acme_test_store = std.mem.zeroes(acme_store);

    var tokens: [MAX_CHALLENGES][16]u8 = undefined;
    var token_lengths: [MAX_CHALLENGES]usize = undefined;
    for (0..MAX_CHALLENGES) |i| {
        const token = try std.fmt.bufPrint(&tokens[i], "token-{d}", .{i});
        token_lengths[i] = token.len;
        try std.testing.expect(add_challenge(
            ngx_str_t{ .len = token.len, .data = token.ptr },
            ngx_string("key-authorization"),
            ngx_string("example.com"),
            std.math.maxInt(ngx_msec_t),
        ));
    }

    try std.testing.expectEqual(@as(ngx_uint_t, MAX_CHALLENGES), acme_test_store.challenge_count);
    try std.testing.expect(!add_challenge(
        ngx_string("overflow"),
        ngx_string("overflow.key-authorization"),
        ngx_string("example.com"),
        std.math.maxInt(ngx_msec_t),
    ));
    try std.testing.expectEqual(@as(ngx_uint_t, MAX_CHALLENGES), acme_test_store.challenge_count);
    try std.testing.expectEqualStrings(
        tokens[0][0..token_lengths[0]],
        fixed_string_slice(&acme_test_store.challenges[0].token, acme_test_store.challenges[0].token_len),
    );
}

test "session storage rejects capacity overflow without eviction" {
    var store = std.mem.zeroes(acme_store);
    var domains: [MAX_ACME_SESSIONS][32]u8 = undefined;
    var domain_lengths: [MAX_ACME_SESSIONS]usize = undefined;

    for (0..MAX_ACME_SESSIONS) |i| {
        const domain = try std.fmt.bufPrint(&domains[i], "domain-{d}.example.com", .{i});
        domain_lengths[i] = domain.len;
        try std.testing.expect(get_or_create_session_entry(&store, domain) != null);
    }

    try std.testing.expectEqual(@as(ngx_uint_t, MAX_ACME_SESSIONS), store.session_count);
    try std.testing.expect(get_or_create_session_entry(&store, "overflow.example.com") == null);
    try std.testing.expectEqual(@as(ngx_uint_t, MAX_ACME_SESSIONS), store.session_count);
    try std.testing.expectEqualStrings(
        domains[0][0..domain_lengths[0]],
        fixed_string_slice(&store.sessions[0].domain, store.sessions[0].domain_len),
    );
}

test "jwk thumbprint" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(4096, nlog);
    defer ngx_destroy_pool(pool);

    // Test with known RSA key components
    // e = 65537 (0x010001) - standard RSA exponent
    // n = some test modulus
    const e = [_]u8{ 0x01, 0x00, 0x01 };
    const n = [_]u8{ 0x00, 0xc5, 0x73, 0x48 }; // Truncated for test

    const thumbprint = compute_jwk_thumbprint(pool, &e, &n);
    try std.testing.expect(thumbprint != null);

    // Thumbprint should be base64url encoded (43 chars for SHA256)
    try std.testing.expectEqual(thumbprint.?.len, 43);

    // Should only contain base64url characters
    for (core.slicify(u8, thumbprint.?.data, thumbprint.?.len)) |c| {
        try std.testing.expect((c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_');
    }
}

test "RSA key generation" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(8192, nlog);
    defer ngx_destroy_pool(pool);

    // Generate a new RSA key
    var key = AcmeAccountKey.generate(pool) catch |err| {
        std.debug.print("Key generation failed: {}\n", .{err});
        return error.TestFailed;
    };
    defer key.deinit();

    // Verify key components are populated
    try std.testing.expect(key.e_bytes.len > 0);
    try std.testing.expect(key.n_bytes.len > 0);

    // e should be 65537 (0x010001) for standard RSA
    try std.testing.expectEqual(key.e_bytes.len, 3);
    try std.testing.expectEqual(key.e_bytes[0], 0x01);
    try std.testing.expectEqual(key.e_bytes[1], 0x00);
    try std.testing.expectEqual(key.e_bytes[2], 0x01);

    // n should be 256 bytes for 2048-bit key
    try std.testing.expectEqual(key.n_bytes.len, 256);
}

test "RSA key to PEM and back" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(16384, nlog);
    defer ngx_destroy_pool(pool);

    // Generate a key
    var key = AcmeAccountKey.generate(pool) catch return error.TestFailed;
    defer key.deinit();

    // Convert to PEM
    const pem = key.toPem(pool) catch return error.TestFailed;

    // Verify PEM format
    try std.testing.expect(pem.len > 0);
    const pem_str = core.slicify(u8, pem.data, pem.len);
    try std.testing.expect(std.mem.startsWith(u8, pem_str, "-----BEGIN PRIVATE KEY-----") or
        std.mem.startsWith(u8, pem_str, "-----BEGIN RSA PRIVATE KEY-----"));

    // Load from PEM
    var loaded_key = AcmeAccountKey.loadFromPem(pem, pool) catch return error.TestFailed;
    defer loaded_key.deinit();

    // Verify key components match
    try std.testing.expectEqualSlices(u8, key.e_bytes, loaded_key.e_bytes);
    try std.testing.expectEqualSlices(u8, key.n_bytes, loaded_key.n_bytes);
}

test "RSA signing" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(8192, nlog);
    defer ngx_destroy_pool(pool);

    // Generate a key
    var key = AcmeAccountKey.generate(pool) catch return error.TestFailed;
    defer key.deinit();

    // Sign a message
    const message = "test message to sign";
    const signature = key.signRs256(message, pool) catch return error.TestFailed;

    // Signature should be base64url encoded
    try std.testing.expect(signature.len > 0);

    // For 2048-bit RSA, signature is 256 bytes, base64url encoded = ~342 chars
    try std.testing.expect(signature.len > 300);
    try std.testing.expect(signature.len < 400);

    // Should only contain base64url characters
    for (core.slicify(u8, signature.data, signature.len)) |c| {
        try std.testing.expect((c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_');
    }
}

test "RSA thumbprint" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(8192, nlog);
    defer ngx_destroy_pool(pool);

    // Generate a key
    var key = AcmeAccountKey.generate(pool) catch return error.TestFailed;
    defer key.deinit();

    // Get thumbprint
    const thumbprint = key.getThumbprint(pool);
    try std.testing.expect(thumbprint != null);

    // Thumbprint should be 43 chars (base64url of SHA256)
    try std.testing.expectEqual(thumbprint.?.len, 43);
}

test "JWS creation with kid" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(16384, nlog);
    defer ngx_destroy_pool(pool);

    // Generate a key
    var key = AcmeAccountKey.generate(pool) catch return error.TestFailed;
    defer key.deinit();

    // Create JWS with kid (existing account)
    const nonce = ngx_string("test-nonce-12345");
    const url = ngx_string("https://acme.example.com/new-order");
    const kid = ngx_string("https://acme.example.com/acct/12345");
    const payload = ngx_string("{\"identifiers\":[{\"type\":\"dns\",\"value\":\"example.com\"}]}");

    const jws = createJws(pool, &key, nonce, url, kid, payload) catch return error.TestFailed;

    // Verify JWS structure
    const jws_str = core.slicify(u8, jws.data, jws.len);

    // Should contain required fields
    try std.testing.expect(std.mem.indexOf(u8, jws_str, "\"protected\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jws_str, "\"payload\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jws_str, "\"signature\":\"") != null);

    // Should start with { and end with }
    try std.testing.expectEqual(jws_str[0], '{');
    try std.testing.expectEqual(jws_str[jws_str.len - 1], '}');
}

test "JWS creation for new account (with jwk)" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(16384, nlog);
    defer ngx_destroy_pool(pool);

    // Generate a key
    var key = AcmeAccountKey.generate(pool) catch return error.TestFailed;
    defer key.deinit();

    // Create JWS without kid (new account, will embed JWK)
    const nonce = ngx_string("test-nonce-67890");
    const url = ngx_string("https://acme.example.com/new-account");
    const payload = ngx_string("{\"termsOfServiceAgreed\":true}");

    const jws = createJws(pool, &key, nonce, url, null, payload) catch return error.TestFailed;

    // Verify JWS structure
    const jws_str = core.slicify(u8, jws.data, jws.len);

    // Should contain required fields
    try std.testing.expect(std.mem.indexOf(u8, jws_str, "\"protected\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jws_str, "\"payload\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jws_str, "\"signature\":\"") != null);
}

test "JWS POST-as-GET (empty payload)" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(16384, nlog);
    defer ngx_destroy_pool(pool);

    // Generate a key
    var key = AcmeAccountKey.generate(pool) catch return error.TestFailed;
    defer key.deinit();

    // Create JWS with empty payload (POST-as-GET)
    const nonce = ngx_string("test-nonce-post-as-get");
    const url = ngx_string("https://acme.example.com/order/12345");
    const kid = ngx_string("https://acme.example.com/acct/12345");

    const jws = createJws(pool, &key, nonce, url, kid, null) catch return error.TestFailed;

    // Verify JWS has empty payload
    const jws_str = core.slicify(u8, jws.data, jws.len);

    // Should have empty payload: "payload":""
    try std.testing.expect(std.mem.indexOf(u8, jws_str, "\"payload\":\"\"") != null);
}

test "Domain key generation" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(8192, nlog);
    defer ngx_destroy_pool(pool);

    // Generate a domain key
    var key = AcmeDomainKey.generate(pool) catch |err| {
        std.debug.print("Domain key generation failed: {}\n", .{err});
        return error.TestFailed;
    };
    defer key.deinit();

    // Key should be valid
    try std.testing.expect(key.pkey != null);
}

test "Domain key to PEM and back" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(16384, nlog);
    defer ngx_destroy_pool(pool);

    // Generate a key
    var key = AcmeDomainKey.generate(pool) catch return error.TestFailed;
    defer key.deinit();

    // Convert to PEM
    const pem = key.toPem(pool) catch return error.TestFailed;

    // Verify PEM format
    try std.testing.expect(pem.len > 0);
    const pem_str = core.slicify(u8, pem.data, pem.len);
    try std.testing.expect(std.mem.startsWith(u8, pem_str, "-----BEGIN PRIVATE KEY-----") or
        std.mem.startsWith(u8, pem_str, "-----BEGIN RSA PRIVATE KEY-----"));

    // Load from PEM
    var loaded_key = AcmeDomainKey.loadFromPem(pem) catch return error.TestFailed;
    defer loaded_key.deinit();

    try std.testing.expect(loaded_key.pkey != null);
}

test "CSR generation" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(16384, nlog);
    defer ngx_destroy_pool(pool);

    // Generate a domain key
    var key = AcmeDomainKey.generate(pool) catch return error.TestFailed;
    defer key.deinit();

    // Create CSR for a domain
    const domain = ngx_string("example.com");
    const csr = key.createCsr(pool, domain) catch |err| {
        std.debug.print("CSR creation failed: {}\n", .{err});
        return error.TestFailed;
    };

    // CSR should be base64url encoded
    try std.testing.expect(csr.len > 0);

    // Should only contain base64url characters
    for (core.slicify(u8, csr.data, csr.len)) |c| {
        try std.testing.expect((c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_');
    }

    // Base64url encoded DER CSR is typically 600-1000 bytes for 2048-bit key
    try std.testing.expect(csr.len > 400);
    try std.testing.expect(csr.len < 1500);

    const req = decode_csr_request(pool, csr) catch return error.TestFailed;
    defer X509_REQ_free(req);

    assert_csr_subject_cn(req, "example.com") catch return error.TestFailed;
    assert_csr_single_dns_san(req, "example.com") catch return error.TestFailed;
}

test "CSR with different domain" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(16384, nlog);
    defer ngx_destroy_pool(pool);

    var key = AcmeDomainKey.generate(pool) catch return error.TestFailed;
    defer key.deinit();

    // Create CSRs for different domains
    const csr1 = key.createCsr(pool, ngx_string("example.com")) catch return error.TestFailed;
    const csr2 = key.createCsr(pool, ngx_string("test.example.com")) catch return error.TestFailed;

    // CSRs should be different (different CN)
    try std.testing.expect(!std.mem.eql(
        u8,
        core.slicify(u8, csr1.data, csr1.len),
        core.slicify(u8, csr2.data, csr2.len),
    ));

    const req1 = decode_csr_request(pool, csr1) catch return error.TestFailed;
    defer X509_REQ_free(req1);
    assert_csr_subject_cn(req1, "example.com") catch return error.TestFailed;
    assert_csr_single_dns_san(req1, "example.com") catch return error.TestFailed;

    const req2 = decode_csr_request(pool, csr2) catch return error.TestFailed;
    defer X509_REQ_free(req2);
    assert_csr_subject_cn(req2, "test.example.com") catch return error.TestFailed;
    assert_csr_single_dns_san(req2, "test.example.com") catch return error.TestFailed;
}

test "AcmeStorage directory creation" {
    const test_path = "/tmp/acme-test-storage";
    var storage = AcmeStorage.init(test_path);
    const io = std.Io.Threaded.global_single_threaded.io();
    defer storage.removeAll();

    // Create directories
    try storage.ensureDirectories();

    // Verify base dir exists
    std.Io.Dir.cwd().access(io, test_path, .{}) catch {
        return error.TestFailed;
    };

    // Verify certs dir exists
    std.Io.Dir.cwd().access(io, test_path ++ "/certs", .{}) catch {
        return error.TestFailed;
    };
}

test "AcmeStorage account key save/load" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(16384, nlog);
    defer ngx_destroy_pool(pool);

    const test_path = "/tmp/acme-test-account";
    var storage = AcmeStorage.init(test_path);
    defer storage.removeAll();

    try storage.ensureDirectories();

    // Generate account key
    var key = AcmeAccountKey.generate(pool) catch return error.TestFailed;
    defer key.deinit();

    // Convert to PEM
    const pem = key.toPem(pool) catch return error.TestFailed;
    const pem_slice = core.slicify(u8, pem.data, pem.len);

    // Save
    try storage.saveAccountKey(pem_slice);

    // Check exists
    try std.testing.expect(storage.accountKeyExists());

    // Load back
    var load_buf: [4096]u8 = undefined;
    const loaded = try storage.loadAccountKey(&load_buf);

    // Verify matches
    try std.testing.expectEqualStrings(pem_slice, loaded);
}

test "AcmeStorage domain key save/load" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(16384, nlog);
    defer ngx_destroy_pool(pool);

    const test_path = "/tmp/acme-test-domain";
    var storage = AcmeStorage.init(test_path);
    defer storage.removeAll();

    try storage.ensureDirectories();

    const domain = "test.example.com";

    // Generate domain key
    var key = AcmeDomainKey.generate(pool) catch return error.TestFailed;
    defer key.deinit();

    // Convert to PEM
    const pem = key.toPem(pool) catch return error.TestFailed;
    const pem_slice = core.slicify(u8, pem.data, pem.len);

    // Save
    try storage.saveDomainKey(domain, pem_slice);

    // Check exists
    try std.testing.expect(storage.domainKeyExists(domain));

    // Load back
    var load_buf: [4096]u8 = undefined;
    const loaded = try storage.loadDomainKey(domain, &load_buf);

    // Verify matches
    try std.testing.expectEqualStrings(pem_slice, loaded);
}

test "AcmeStorage certificate save/load" {
    const test_path = "/tmp/acme-test-cert";
    var storage = AcmeStorage.init(test_path);
    defer storage.removeAll();

    try storage.ensureDirectories();

    const domain = "cert.example.com";
    const test_cert = "-----BEGIN CERTIFICATE-----\nMIIB...fake...cert\n-----END CERTIFICATE-----\n";

    // Save
    try storage.saveCertificate(domain, test_cert);

    // Check exists
    try std.testing.expect(storage.certExists(domain));

    // Load back
    var load_buf: [4096]u8 = undefined;
    const loaded = try storage.loadCertificate(domain, &load_buf);

    // Verify matches
    try std.testing.expectEqualStrings(test_cert, loaded);
}

test "AcmeStorage paths" {
    var storage = AcmeStorage.init("/etc/nginx/acme");

    var buf: [512]u8 = undefined;

    const account_path = try storage.accountKeyPath(&buf);
    try std.testing.expectEqualStrings("/etc/nginx/acme/account.key", account_path);

    const domain_path = try storage.domainKeyPath("example.com", &buf);
    try std.testing.expectEqualStrings("/etc/nginx/acme/certs/example.com/privkey.pem", domain_path);

    const cert_path = try storage.certPath("example.com", &buf);
    try std.testing.expectEqualStrings("/etc/nginx/acme/certs/example.com/fullchain.pem", cert_path);
}

test "AcmeStorage non-existent files" {
    const test_path = "/tmp/acme-test-nonexist";
    var storage = AcmeStorage.init(test_path);
    defer storage.removeAll();

    try storage.ensureDirectories();

    // Account key should not exist
    try std.testing.expect(!storage.accountKeyExists());

    // Domain key should not exist
    try std.testing.expect(!storage.domainKeyExists("nonexistent.com"));

    // Cert should not exist
    try std.testing.expect(!storage.certExists("nonexistent.com"));

    // Load should fail with appropriate error
    var buf: [4096]u8 = undefined;
    const result = storage.loadAccountKey(&buf);
    try std.testing.expectError(error.AccountKeyNotFound, result);
}

// Note: Certificate expiry tests require a valid X509 certificate.
// These are tested via integration tests with real certificates.
// The getCertDaysRemaining and certNeedsRenewal functions work with
// actual PEM certificates obtained from ACME servers.

// ============================================================================
// ACME Client Unit Tests
// ============================================================================

test "AcmeDirectory parse" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(8192, nlog);
    defer ngx_destroy_pool(pool);

    const json =
        \\{
        \\  "newNonce": "https://acme.example.com/acme/new-nonce",
        \\  "newAccount": "https://acme.example.com/acme/new-acct",
        \\  "newOrder": "https://acme.example.com/acme/new-order",
        \\  "revokeCert": "https://acme.example.com/acme/revoke-cert",
        \\  "keyChange": "https://acme.example.com/acme/key-change"
        \\}
    ;

    const dir = AcmeDirectory.parse(pool, json) catch return error.TestFailed;

    try std.testing.expectEqualStrings(
        "https://acme.example.com/acme/new-nonce",
        core.slicify(u8, dir.new_nonce.data, dir.new_nonce.len),
    );
    try std.testing.expectEqualStrings(
        "https://acme.example.com/acme/new-acct",
        core.slicify(u8, dir.new_account.data, dir.new_account.len),
    );
    try std.testing.expectEqualStrings(
        "https://acme.example.com/acme/new-order",
        core.slicify(u8, dir.new_order.data, dir.new_order.len),
    );
}

test "AcmeOrder parse" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(8192, nlog);
    defer ngx_destroy_pool(pool);

    const json =
        \\{
        \\  "status": "pending",
        \\  "finalize": "https://acme.example.com/acme/order/12345/finalize",
        \\  "authorizations": [
        \\    "https://acme.example.com/acme/authz/abc123"
        \\  ]
        \\}
    ;

    var order = AcmeOrder.init();
    order.parse(pool, json) catch return error.TestFailed;

    try std.testing.expectEqualStrings(
        "pending",
        core.slicify(u8, order.status.data, order.status.len),
    );
    try std.testing.expectEqualStrings(
        "https://acme.example.com/acme/order/12345/finalize",
        core.slicify(u8, order.finalize_url.data, order.finalize_url.len),
    );
    try std.testing.expectEqual(order.authorization_count, 1);
    try std.testing.expectEqualStrings(
        "https://acme.example.com/acme/authz/abc123",
        core.slicify(u8, order.authorization_urls[0].data, order.authorization_urls[0].len),
    );
}

test "AcmeAuthorization parse" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(8192, nlog);
    defer ngx_destroy_pool(pool);

    const json =
        \\{
        \\  "status": "pending",
        \\  "challenges": [
        \\    {
        \\      "type": "http-01",
        \\      "url": "https://acme.example.com/acme/chall/abc123",
        \\      "token": "evaGxfADs6pSRb2LAv9IZf17Dt3juxGJ-PCt92wr-oA"
        \\    },
        \\    {
        \\      "type": "dns-01",
        \\      "url": "https://acme.example.com/acme/chall/xyz789",
        \\      "token": "other-token"
        \\    }
        \\  ]
        \\}
    ;

    var auth = AcmeAuthorization.init();
    auth.parse(pool, json) catch return error.TestFailed;

    try std.testing.expectEqualStrings(
        "pending",
        core.slicify(u8, auth.status.data, auth.status.len),
    );
    // Should have selected http-01 challenge
    try std.testing.expectEqualStrings(
        "https://acme.example.com/acme/chall/abc123",
        core.slicify(u8, auth.challenge_url.data, auth.challenge_url.len),
    );
    try std.testing.expectEqualStrings(
        "evaGxfADs6pSRb2LAv9IZf17Dt3juxGJ-PCt92wr-oA",
        core.slicify(u8, auth.challenge_token.data, auth.challenge_token.len),
    );
}

test "AcmeClient state machine" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(16384, nlog);
    defer ngx_destroy_pool(pool);

    var client = AcmeClient.init(
        pool,
        ngx_string("https://acme.example.com/directory"),
        ngx_string("test.example.com"),
    );

    // Initial state
    try std.testing.expectEqual(client.state, AcmeState.idle);

    // Start
    client.start();
    try std.testing.expectEqual(client.state, AcmeState.need_directory);

    // Handle directory response
    const dir_json =
        \\{"newNonce":"https://acme.example.com/nonce","newAccount":"https://acme.example.com/acct","newOrder":"https://acme.example.com/order"}
    ;
    client.handleDirectoryResponse(dir_json) catch return error.TestFailed;
    try std.testing.expectEqual(client.state, AcmeState.need_nonce);

    // Handle nonce response (no account yet)
    client.updateNonce(ngx_string("test-nonce-12345"));
    client.handleNonceResponse();
    try std.testing.expectEqual(client.state, AcmeState.need_account);
}

test "AcmeClient build directory request" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(8192, nlog);
    defer ngx_destroy_pool(pool);

    var client = AcmeClient.init(
        pool,
        ngx_string("https://acme-v02.api.letsencrypt.org/directory"),
        ngx_string("example.com"),
    );

    const req = client.buildDirectoryRequest() catch return error.TestFailed;

    try std.testing.expectEqual(req.method, HttpMethod.GET);
    try std.testing.expectEqualStrings(
        "https://acme-v02.api.letsencrypt.org/directory",
        core.slicify(u8, req.url.data, req.url.len),
    );
    try std.testing.expectEqual(req.body.len, 0);
}

test "AcmeHttpRequest build GET" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(4096, nlog);
    defer ngx_destroy_pool(pool);

    const req = AcmeHttpRequest{
        .method = .GET,
        .url = ngx_string("https://acme.example.com/directory"),
        .body = ngx_null_str,
        .content_type = ngx_null_str,
    };

    const raw = req.build(pool, ngx_string("acme.example.com")) catch return error.TestFailed;
    const raw_str = core.slicify(u8, raw.data, raw.len);

    // Should start with GET request line
    try std.testing.expect(std.mem.startsWith(u8, raw_str, "GET /directory HTTP/1.1\r\n"));

    // Should contain Host header
    try std.testing.expect(std.mem.indexOf(u8, raw_str, "Host: acme.example.com\r\n") != null);

    // Should end with \r\n\r\n (no body)
    try std.testing.expect(std.mem.endsWith(u8, raw_str, "\r\n\r\n"));
}

test "AcmeHttpRequest build POST" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(4096, nlog);
    defer ngx_destroy_pool(pool);

    const req = AcmeHttpRequest{
        .method = .POST,
        .url = ngx_string("https://acme.example.com/new-account"),
        .body = ngx_string("{\"test\":\"body\"}"),
        .content_type = ngx_string("application/jose+json"),
    };

    const raw = req.build(pool, ngx_string("acme.example.com")) catch return error.TestFailed;
    const raw_str = core.slicify(u8, raw.data, raw.len);

    // Should start with POST request line
    try std.testing.expect(std.mem.startsWith(u8, raw_str, "POST /new-account HTTP/1.1\r\n"));

    // Should contain headers
    try std.testing.expect(std.mem.indexOf(u8, raw_str, "Host: acme.example.com\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw_str, "Content-Type: application/jose+json\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw_str, "Content-Length: 15\r\n") != null);

    // Should end with body
    try std.testing.expect(std.mem.endsWith(u8, raw_str, "{\"test\":\"body\"}"));
}

test "AcmeClient build order request" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(16384, nlog);
    defer ngx_destroy_pool(pool);

    // Generate account key
    var key = AcmeAccountKey.generate(pool) catch return error.TestFailed;
    defer key.deinit();

    var client = AcmeClient.init(
        pool,
        ngx_string("https://acme.example.com/directory"),
        ngx_string("test.example.com"),
    );

    client.setAccountKey(&key);
    client.directory.new_order = ngx_string("https://acme.example.com/new-order");
    client.current_nonce = ngx_string("test-nonce");
    client.account_url = ngx_string("https://acme.example.com/acct/12345");

    const req = client.buildOrderRequest() catch return error.TestFailed;

    try std.testing.expectEqual(req.method, HttpMethod.POST);
    try std.testing.expectEqualStrings(
        "https://acme.example.com/new-order",
        core.slicify(u8, req.url.data, req.url.len),
    );
    try std.testing.expect(req.body.len > 0);
    try std.testing.expectEqualStrings(
        "application/jose+json",
        core.slicify(u8, req.content_type.data, req.content_type.len),
    );

    // Body should be valid JWS JSON
    const body = core.slicify(u8, req.body.data, req.body.len);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"protected\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"payload\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"signature\":\"") != null);
}
