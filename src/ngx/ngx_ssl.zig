const std = @import("std");
const ngx = @import("ngx.zig");
const log = @import("ngx_log.zig");
const core = @import("ngx_core.zig");
const string = @import("ngx_string.zig");
const expectEqual = std.testing.expectEqual;

const u_char = core.u_char;
const nullptr = core.nullptr;
const ngx_str_t = core.ngx_str_t;
const ngx_pool_t = core.ngx_pool_t;
const ngx_string = string.ngx_string;

const CRYPTO_malloc_fn = ngx.CRYPTO_malloc_fn;
const CRYPTO_realloc_fn = ngx.CRYPTO_realloc_fn;
const CRYPTO_free_fn = ngx.CRYPTO_free_fn;

pub const OPENSSL_init_crypto = ngx.OPENSSL_init_crypto;
pub const CRYPTO_set_mem_functions = ngx.CRYPTO_set_mem_functions;
pub const OPENSSL_INIT_ADD_ALL_CIPHERS = ngx.OPENSSL_INIT_ADD_ALL_CIPHERS;
pub const OPENSSL_INIT_ADD_ALL_DIGESTS = ngx.OPENSSL_INIT_ADD_ALL_DIGESTS;
pub const OPENSSL_INIT_LOAD_CRYPTO_STRINGS = ngx.OPENSSL_INIT_LOAD_CRYPTO_STRINGS;
pub const ngx_ssl_t = ngx.ngx_ssl_t;
pub const NGX_SSL_DEFAULT_PROTOCOLS = ngx.NGX_SSL_DEFAULT_PROTOCOLS;
pub const ngx_ssl_create = ngx.ngx_ssl_create;
pub const ngx_ssl_client_session_cache = ngx.ngx_ssl_client_session_cache;
pub const ngx_ssl_cleanup_ctx = ngx.ngx_ssl_cleanup_ctx;

pub const RAND_bytes = ngx.RAND_bytes;
pub const EVP_PKEY_free = ngx.EVP_PKEY_free;
pub const EVP_PKEY_CTX_new = ngx.EVP_PKEY_CTX_new;
pub const EVP_PKEY_CTX_free = ngx.EVP_PKEY_CTX_free;

pub const BIO = ngx.BIO;
pub const EVP_PKEY = ngx.EVP_PKEY;
pub const BIO_free = ngx.BIO_free;
pub const BIO_new_mem_buf = ngx.BIO_new_mem_buf;
pub const PEM_read_bio_PUBKEY = ngx.PEM_read_bio_PUBKEY;
pub const PEM_read_bio_PrivateKey = ngx.PEM_read_bio_PrivateKey;

// AES-256-GCM
const EVP_CIPHER_CTX = ngx.EVP_CIPHER_CTX;
const EVP_aes_256_gcm = ngx.EVP_aes_256_gcm;
const EVP_CIPHER_CTX_new = ngx.EVP_CIPHER_CTX_new;
const EVP_CIPHER_CTX_free = ngx.EVP_CIPHER_CTX_free;
const EVP_CIPHER_CTX_reset = ngx.EVP_CIPHER_CTX_reset;
const EVP_CTRL_GCM_GET_TAG = ngx.EVP_CTRL_GCM_GET_TAG;
const EVP_CTRL_GCM_SET_TAG = ngx.EVP_CTRL_GCM_SET_TAG;
const EVP_CIPHER_CTX_set_padding = ngx.EVP_CIPHER_CTX_set_padding;

const EVP_EncryptInit_ex = ngx.EVP_EncryptInit_ex;
const EVP_EncryptUpdate = ngx.EVP_EncryptUpdate;
const EVP_EncryptFinal_ex = ngx.EVP_EncryptFinal_ex;
const EVP_CIPHER_CTX_ctrl = ngx.EVP_CIPHER_CTX_ctrl;
const EVP_DecryptInit_ex = ngx.EVP_DecryptInit_ex;
const EVP_DecryptUpdate = ngx.EVP_DecryptUpdate;
const EVP_DecryptFinal_ex = ngx.EVP_DecryptFinal_ex;

// RSA-OAEP
pub const EVP_RSA_gen = ngx.EVP_RSA_gen;
pub const EVP_PKEY_CTX = ngx.EVP_PKEY_CTX;
pub const RSA_PKCS1_OAEP_PADDING = ngx.RSA_PKCS1_OAEP_PADDING;
pub const RSA_PKCS1_PADDING = ngx.RSA_PKCS1_PADDING;
pub const RSA_NO_PADDING = ngx.RSA_NO_PADDING;
pub const EVP_PKEY_encrypt_init = ngx.EVP_PKEY_encrypt_init;
pub const EVP_PKEY_CTX_set_rsa_padding = ngx.EVP_PKEY_CTX_set_rsa_padding;
pub const EVP_PKEY_encrypt = ngx.EVP_PKEY_encrypt;
pub const EVP_PKEY_decrypt_init = ngx.EVP_PKEY_decrypt_init;
pub const EVP_PKEY_decrypt = ngx.EVP_PKEY_decrypt;
pub const EVP_PKEY_public_check = ngx.EVP_PKEY_public_check;
pub const EVP_PKEY_private_check = ngx.EVP_PKEY_private_check;

// ACME
pub const BIGNUM = ngx.BIGNUM;
pub const BIO_new = ngx.BIO_new;
pub const BIO_ctrl = ngx.BIO_ctrl;
pub const BIO_s_mem = ngx.BIO_s_mem;
pub const BN_bn2bin = ngx.BN_bn2bin;
pub const BN_num_bytes = ngx.BN_num_bytes;
pub const RSA_get0_key = ngx.RSA_get0_key;
pub const BIO_CTRL_INFO = ngx.BIO_CTRL_INFO;
pub const EVP_PKEY_get0_RSA = ngx.EVP_PKEY_get0_RSA;
pub const PEM_write_bio_PrivateKey = ngx.PEM_write_bio_PrivateKey;

// SHA256/384/512 DIGEST SIGN/VERIFY
const SHA256_DIGEST_LENGTH = ngx.SHA256_DIGEST_LENGTH;
pub const EVP_sha256 = ngx.EVP_sha256;
pub extern fn EVP_sha384() ?*const EVP_MD;
pub extern fn EVP_sha512() ?*const EVP_MD;
pub const EVP_MD_CTX = ngx.EVP_MD_CTX;
pub const EVP_MD_CTX_new = ngx.EVP_MD_CTX_new;
pub const EVP_MD_CTX_free = ngx.EVP_MD_CTX_free;
pub const EVP_MD_CTX_reset = ngx.EVP_MD_CTX_reset;
pub const EVP_DigestVerifyInit = ngx.EVP_DigestVerifyInit;
pub const EVP_DigestVerifyUpdate = ngx.EVP_DigestVerifyUpdate;
pub const EVP_DigestVerifyFinal = ngx.EVP_DigestVerifyFinal;
pub const EVP_DigestSignInit = ngx.EVP_DigestSignInit;
pub const EVP_DigestSignUpdate = ngx.EVP_DigestSignUpdate;
pub const EVP_DigestSignFinal = ngx.EVP_DigestSignFinal;

// X509_REQ (CSR) generation for ACME
pub const ASN1_STRING = ngx.ASN1_STRING;
pub const GENERAL_NAMES = ngx.GENERAL_NAMES;
pub const GENERAL_NAME = ngx.GENERAL_NAME;
pub const X509_REQ = ngx.X509_REQ;
pub const X509_NAME = ngx.X509_NAME;
pub const X509_EXTENSION = ngx.X509_EXTENSION;
pub const X509_EXTENSIONS = ngx.X509_EXTENSIONS;
pub const X509V3_CTX = ngx.X509V3_CTX;
pub const d2i_X509_REQ = ngx.d2i_X509_REQ;
pub const X509_REQ_new = ngx.X509_REQ_new;
pub const X509_REQ_free = ngx.X509_REQ_free;
pub const X509_REQ_set_version = ngx.X509_REQ_set_version;
pub const X509_REQ_get_subject_name = ngx.X509_REQ_get_subject_name;
pub const X509_REQ_get_extensions = ngx.X509_REQ_get_extensions;
pub const X509_REQ_set_pubkey = ngx.X509_REQ_set_pubkey;
pub const X509_REQ_sign = ngx.X509_REQ_sign;
pub const X509_REQ_add_extensions = ngx.X509_REQ_add_extensions;
pub const X509_NAME_get_text_by_NID = ngx.X509_NAME_get_text_by_NID;
pub const X509_NAME_add_entry_by_txt = ngx.X509_NAME_add_entry_by_txt;
pub const ASN1_STRING_length = ngx.ASN1_STRING_length;
pub const ASN1_STRING_get0_data = ngx.ASN1_STRING_get0_data;
pub const GENERAL_NAME_get0_value = ngx.GENERAL_NAME_get0_value;
pub const GENERAL_NAMES_free = ngx.GENERAL_NAMES_free;
pub const X509_EXTENSION_free = ngx.X509_EXTENSION_free;
pub const X509V3_EXT_conf_nid = ngx.X509V3_EXT_conf_nid;
pub const X509V3_get_d2i = ngx.X509V3_get_d2i;
pub const X509V3_set_ctx = ngx.X509V3_set_ctx;
pub const X509v3_add_ext = ngx.X509v3_add_ext;
pub const sk_GENERAL_NAME_num = ngx.sk_GENERAL_NAME_num;
pub const sk_GENERAL_NAME_value = ngx.sk_GENERAL_NAME_value;
pub const sk_X509_EXTENSION_pop_free = ngx.sk_X509_EXTENSION_pop_free;
pub const i2d_X509_REQ = ngx.i2d_X509_REQ;
pub const GEN_DNS = ngx.GEN_DNS;
pub const MBSTRING_ASC = ngx.MBSTRING_ASC;
pub const NID_commonName = ngx.NID_commonName;
pub const NID_subject_alt_name = ngx.NID_subject_alt_name;
pub const RSA = ngx.struct_rsa_st;
pub const V_ASN1_IA5STRING = ngx.V_ASN1_IA5STRING;

// X509 certificate parsing (for expiry checking)
pub const X509 = ngx.X509;
pub const X509_free = ngx.X509_free;
pub const PEM_read_bio_X509 = ngx.PEM_read_bio_X509;
pub const X509_get_notAfter = ngx.X509_get_notAfter;
pub const ASN1_TIME = ngx.ASN1_TIME;
pub const ASN1_TIME_diff = ngx.ASN1_TIME_diff;

// base64
const EVP_EncodeBlock = ngx.EVP_EncodeBlock;
const EVP_DecodeBlock = ngx.EVP_DecodeBlock;

// EC keys (ECDSA) — declared locally since not in ngx.zig
pub const EC_KEY = opaque {};
pub extern fn EC_KEY_new_by_curve_name(nid: c_int) ?*EC_KEY;
pub extern fn EC_KEY_free(key: ?*EC_KEY) void;
pub extern fn EC_KEY_get0_group(key: ?*const EC_KEY) ?*anyopaque;

// Raw public key import (EdDSA, ECDSA) — declared locally
pub extern fn EVP_PKEY_new_raw_public_key(nid: c_int, e: ?*anyopaque, pub_key: [*c]const u8, len: usize) ?*EVP_PKEY;

// RSA-PSS — declared locally
pub const RSA_PKCS1_PSS_PADDING: c_int = 6;
pub const RSA_PSS_SALTLEN_DIGEST: c_int = -1;
pub extern fn EVP_PKEY_CTX_set_rsa_pss_saltlen(ctx: ?*EVP_PKEY_CTX, saltlen: c_int) c_int;

// Curve NIDs — declared locally
pub const NID_X9_62_prime256v1: c_int = 415;
pub const NID_secp384r1: c_int = 715;
pub const NID_secp521r1: c_int = 716;
pub const NID_secp256k1: c_int = 714;
pub const NID_ED25519: c_int = 1087;
pub extern fn OBJ_txt2nid(s: [*c]const u8) c_int;

// HMAC
pub const HMAC_CTX = ngx.HMAC_CTX;
pub const HMAC_CTX_new = ngx.HMAC_CTX_new;
pub const HMAC_CTX_free = ngx.HMAC_CTX_free;
pub const HMAC_Init_ex = ngx.HMAC_Init_ex;
pub const HMAC_Update = ngx.HMAC_Update;
pub const HMAC_Final = ngx.HMAC_Final;
pub const EVP_MD = ngx.EVP_MD;

const ERR_get_error = ngx.ERR_get_error;
const ERR_error_string_n = ngx.ERR_error_string_n;
const ERR_print_errors_cb = ngx.ERR_print_errors_cb;

const ngx_encode_base64 = ngx.ngx_encode_base64;
const ngx_decode_base64 = ngx.ngx_decode_base64;

pub inline fn ngx_base64_encoded_length(len: usize) usize {
    return ((len + 2) / 3) * 4;
}

pub inline fn ngx_base64_decoded_length(len: usize) usize {
    return ((len + 3) / 4) * 3;
}

inline fn not_null(p: ?*anyopaque) bool {
    return p != core.NULL;
}

inline fn is_one(r: c_int) bool {
    return r == 1;
}

inline fn is_zero_or_more(r: c_int) bool {
    return r >= 0;
}

pub var SSL_LOG: ?*anyopaque = null;
fn ssl_log(msg: [*c]const u8, len: usize, logger: ?*anyopaque) callconv(.c) c_int {
    if (core.castPtr(log.ngx_log_t, logger)) |l| {
        var str = ngx_str_t{ .len = len, .data = @constCast(msg) };
        log.ngz_log_error(log.NGX_LOG_WARN, l, 0, "%V", .{&str});
    }
    return core.NGX_OK;
}

pub fn sslcall(comptime F: anytype, args: anytype, comptime predicate: anytype) !@TypeOf(@call(.auto, F, args)) {
    const ResultType = @TypeOf(@call(.auto, F, args));
    const result: ResultType = @call(.auto, F, args);

    if (!predicate(result)) {
        ERR_print_errors_cb(ssl_log, SSL_LOG);
        return core.NError.SSL_ERROR;
    } else {
        return result;
    }
}

pub fn check_public_key(key: ngx_str_t) !bool {
    const pkey_bio = try sslcall(BIO_new_mem_buf, .{ key.data, @as(c_int, @intCast(key.len)) }, not_null);
    defer _ = BIO_free(pkey_bio);
    const pkey = try sslcall(PEM_read_bio_PUBKEY, .{ pkey_bio, null, null, null }, not_null);
    defer EVP_PKEY_free(pkey);
    const ctx = try sslcall(EVP_PKEY_CTX_new, .{ pkey, null }, not_null);
    defer EVP_PKEY_CTX_free(ctx);
    _ = sslcall(EVP_PKEY_public_check, .{ctx}, is_one) catch return false;
    return true;
}

pub fn check_private_key(key: ngx_str_t) !bool {
    const pkey_bio = try sslcall(BIO_new_mem_buf, .{ key.data, @as(c_int, @intCast(key.len)) }, not_null);
    defer _ = BIO_free(pkey_bio);
    const pkey = try sslcall(PEM_read_bio_PrivateKey, .{ pkey_bio, null, null, null }, not_null);
    defer EVP_PKEY_free(pkey);
    const ctx = try sslcall(EVP_PKEY_CTX_new, .{ pkey, null }, not_null);
    defer EVP_PKEY_CTX_free(ctx);
    _ = sslcall(EVP_PKEY_private_check, .{ctx}, is_one) catch return false;
    return true;
}

inline fn base64_decoded_len(b64: ngx_str_t, blen: c_int) usize {
    var len: usize = @intCast(blen);
    if (b64.len > 0) {
        var i: usize = b64.len - 1;
        while (i > 0 and len > 0 and b64.data[i] == '=') : (i -= 1) {
            len -= 1;
        }
    }
    return len;
}

pub const NSSL_RSA = extern struct {
    const Self = @This();
    prv_key_bio: ?*BIO,
    pub_key_bio: ?*BIO,
    prv_key: ?*EVP_PKEY,
    pub_key: ?*EVP_PKEY,

    md_ctx: ?*EVP_MD_CTX,
    en_ctx: ?*EVP_PKEY_CTX,
    de_ctx: ?*EVP_PKEY_CTX,

    pub fn init(prvkey: ngx_str_t, pubkey: ngx_str_t) !Self {
        _ = OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null);
        const prv_key_bio = try sslcall(BIO_new_mem_buf, .{ prvkey.data, @as(c_int, @intCast(prvkey.len)) }, not_null);
        const pub_key_bio = try sslcall(BIO_new_mem_buf, .{ pubkey.data, @as(c_int, @intCast(pubkey.len)) }, not_null);
        const prv_key = try sslcall(PEM_read_bio_PrivateKey, .{ prv_key_bio, null, null, null }, not_null);
        const pub_key = try sslcall(PEM_read_bio_PUBKEY, .{ pub_key_bio, null, null, null }, not_null);
        const md_ctx = try sslcall(EVP_MD_CTX_new, .{}, not_null);
        const en_ctx = try sslcall(EVP_PKEY_CTX_new, .{ pub_key, null }, not_null);
        _ = try sslcall(EVP_PKEY_encrypt_init, .{en_ctx}, is_one);
        _ = try sslcall(EVP_PKEY_CTX_set_rsa_padding, .{ en_ctx, RSA_PKCS1_OAEP_PADDING }, is_one);

        const de_ctx = try sslcall(EVP_PKEY_CTX_new, .{ prv_key, null }, not_null);
        _ = try sslcall(EVP_PKEY_decrypt_init, .{de_ctx}, is_one);
        _ = try sslcall(EVP_PKEY_CTX_set_rsa_padding, .{ de_ctx, RSA_PKCS1_OAEP_PADDING }, is_one);

        return Self{
            .prv_key_bio = prv_key_bio,
            .pub_key_bio = pub_key_bio,
            .prv_key = prv_key,
            .pub_key = pub_key,
            .md_ctx = md_ctx,
            .en_ctx = en_ctx,
            .de_ctx = de_ctx,
        };
    }

    pub fn deinit(self: *Self) void {
        EVP_MD_CTX_free(self.md_ctx);
        EVP_PKEY_CTX_free(self.en_ctx);
        EVP_PKEY_CTX_free(self.de_ctx);

        EVP_PKEY_free(self.prv_key);
        EVP_PKEY_free(self.pub_key);
        _ = BIO_free(self.prv_key_bio);
        _ = BIO_free(self.pub_key_bio);
    }

    pub fn sign_sha256(self: *Self, msg: ngx_str_t, pool: [*c]ngx_pool_t) !ngx_str_t {
        var buf: [512]u8 = undefined; // 512 bytes accommodates RSA-4096 signatures
        var len: usize = buf.len;
        if (core.castPtr(u8, core.ngx_pnalloc(pool, ngx_base64_encoded_length(len)))) |p| {
            defer _ = EVP_MD_CTX_reset(self.md_ctx);
            _ = try sslcall(EVP_DigestSignInit, .{ self.md_ctx, null, EVP_sha256(), null, self.prv_key }, is_one);
            _ = try sslcall(EVP_DigestSignUpdate, .{ self.md_ctx, msg.data, msg.len }, is_one);
            _ = try sslcall(EVP_DigestSignFinal, .{ self.md_ctx, &buf, &len }, is_one);
            const blen = try sslcall(EVP_EncodeBlock, .{ p, &buf, @as(c_int, @intCast(len)) }, is_zero_or_more);
            return ngx_str_t{ .len = @intCast(blen), .data = p };
        }
        return core.NError.OOM;
    }

    pub fn verify_sha256(self: *Self, sig: ngx_str_t, msg: ngx_str_t, pool: [*c]ngx_pool_t) !bool {
        if (core.castPtr(u8, core.ngx_pnalloc(pool, ngx_base64_decoded_length(sig.len)))) |p| {
            defer _ = EVP_MD_CTX_reset(self.md_ctx);
            const blen = try sslcall(EVP_DecodeBlock, .{ p, sig.data, @as(c_int, @intCast(sig.len)) }, is_zero_or_more);
            _ = try sslcall(EVP_DigestVerifyInit, .{ self.md_ctx, null, EVP_sha256(), null, self.pub_key }, is_one);
            _ = try sslcall(EVP_DigestVerifyUpdate, .{ self.md_ctx, msg.data, msg.len }, is_one);
            _ = sslcall(EVP_DigestVerifyFinal, .{ self.md_ctx, p, base64_decoded_len(sig, blen) }, is_one) catch return false;
            return true;
        }
        return core.NError.OOM;
    }

    pub fn oaep_encrypt(self: *Self, msg: ngx_str_t, pool: [*c]ngx_pool_t) !ngx_str_t {
        var len: usize = 0;
        _ = try sslcall(EVP_PKEY_encrypt, .{ self.en_ctx, null, &len, msg.data, msg.len }, is_one);
        if (core.castPtr(u8, core.ngx_pnalloc(pool, len))) |p0| {
            _ = try sslcall(EVP_PKEY_encrypt, .{ self.en_ctx, p0, &len, msg.data, msg.len }, is_one);
            if (core.castPtr(u8, core.ngx_pnalloc(pool, ngx_base64_encoded_length(len)))) |p1| {
                const blen = try sslcall(EVP_EncodeBlock, .{ p1, p0, @as(c_int, @intCast(len)) }, is_zero_or_more);
                return ngx_str_t{ .len = @intCast(blen), .data = p1 };
            }
        }
        return core.NError.OOM;
    }

    pub fn oaep_decrypt(self: *Self, msg: ngx_str_t, pool: [*c]ngx_pool_t) !ngx_str_t {
        if (core.castPtr(u8, core.ngx_pnalloc(pool, ngx_base64_decoded_length(msg.len)))) |p0| {
            const blen = try sslcall(EVP_DecodeBlock, .{ p0, msg.data, @as(c_int, @intCast(msg.len)) }, is_zero_or_more);
            const dlen = base64_decoded_len(msg, blen);
            var len: usize = 0;
            _ = try sslcall(EVP_PKEY_decrypt, .{ self.de_ctx, null, &len, p0, dlen }, is_one);
            if (core.castPtr(u8, core.ngx_pnalloc(pool, len))) |p1| {
                _ = try sslcall(EVP_PKEY_decrypt, .{ self.de_ctx, p1, &len, p0, dlen }, is_one);
                return ngx_str_t{ .len = len, .data = p1 };
            }
        }
        return core.NError.OOM;
    }
};

fn ptag(tag: [*c]u8) void {
    for (0..16) |i| {
        std.debug.print("{x}", .{tag[i]});
    }
    std.debug.print("\n", .{});
}

pub const NSSL_AES_256_GCM = extern struct {
    const Self = @This();
    pub const KEY_SIZE = 32;
    pub const IV_SIZE = 12;
    pub const TAG_SIZE = 16;

    ctx: ?*EVP_CIPHER_CTX,
    key: [KEY_SIZE]u8 = undefined,

    pub fn init(k: ngx_str_t) !Self {
        _ = OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null);
        const ctx = try sslcall(EVP_CIPHER_CTX_new, .{}, not_null);
        var cipher = Self{
            .ctx = ctx,
        };
        @memcpy(core.slicify(u8, &cipher.key[0], KEY_SIZE), core.slicify(u8, k.data, KEY_SIZE));
        return cipher;
    }

    pub fn deinit(self: *Self) void {
        EVP_CIPHER_CTX_free(self.ctx);
    }

    pub fn encrypt(self: *Self, msg: ngx_str_t, iv: ngx_str_t, aad: ngx_str_t, pool: [*c]ngx_pool_t) !ngx_str_t {
        defer _ = EVP_CIPHER_CTX_reset(self.ctx);
        _ = try sslcall(EVP_EncryptInit_ex, .{ self.ctx, EVP_aes_256_gcm(), null, null, null }, is_one);
        _ = try sslcall(EVP_EncryptInit_ex, .{ self.ctx, null, null, &self.key[0], iv.data }, is_one);
        _ = try sslcall(EVP_CIPHER_CTX_set_padding, .{ self.ctx, 0 }, is_one);
        if (core.castPtr(u8, core.ngx_pnalloc(pool, msg.len + TAG_SIZE))) |p0| {
            var len: c_int = 0;
            var tlen: c_int = 0;
            if (aad.len > 0) {
                _ = try sslcall(EVP_EncryptUpdate, .{ self.ctx, null, &tlen, aad.data, @as(c_int, @intCast(aad.len)) }, is_one);
            }
            _ = try sslcall(EVP_EncryptUpdate, .{ self.ctx, p0, &len, msg.data, @as(c_int, @intCast(msg.len)) }, is_one);
            const tag = p0 + @as(usize, @intCast(len));
            _ = try sslcall(EVP_EncryptFinal_ex, .{ self.ctx, tag, &tlen }, is_one);
            _ = try sslcall(EVP_CIPHER_CTX_ctrl, .{ self.ctx, EVP_CTRL_GCM_GET_TAG, TAG_SIZE, tag }, is_one);
            if (core.castPtr(u8, core.ngx_pnalloc(pool, ngx_base64_encoded_length(@as(usize, @intCast(len + TAG_SIZE)))))) |p1| {
                const blen = try sslcall(EVP_EncodeBlock, .{ p1, p0, len + TAG_SIZE }, is_zero_or_more);
                return ngx_str_t{ .len = @intCast(blen), .data = p1 };
            }
        }
        return core.NError.OOM;
    }

    pub fn decrypt(self: *Self, msg: ngx_str_t, iv: ngx_str_t, aad: ngx_str_t, pool: [*c]ngx_pool_t) !ngx_str_t {
        defer _ = EVP_CIPHER_CTX_reset(self.ctx);
        _ = try sslcall(EVP_DecryptInit_ex, .{ self.ctx, EVP_aes_256_gcm(), null, null, null }, is_one);
        _ = try sslcall(EVP_DecryptInit_ex, .{ self.ctx, null, null, &self.key[0], iv.data }, is_one);
        _ = try sslcall(EVP_CIPHER_CTX_set_padding, .{ self.ctx, 0 }, is_one);
        if (core.castPtr(u8, core.ngx_pnalloc(pool, ngx_base64_decoded_length(msg.len)))) |p0| {
            const blen = try sslcall(EVP_DecodeBlock, .{ p0, msg.data, @as(c_int, @intCast(msg.len)) }, is_zero_or_more);
            const dlen = base64_decoded_len(msg, blen);
            if (core.castPtr(u8, core.ngx_pnalloc(pool, dlen))) |p1| {
                var len: c_int = 0;
                var tlen: c_int = 0;
                _ = try sslcall(EVP_CIPHER_CTX_ctrl, .{ self.ctx, EVP_CTRL_GCM_SET_TAG, TAG_SIZE, p0 + (dlen - TAG_SIZE) }, is_one);
                if (aad.len > 0) {
                    _ = try sslcall(EVP_DecryptUpdate, .{ self.ctx, null, &tlen, aad.data, @as(c_int, @intCast(aad.len)) }, is_one);
                }
                _ = try sslcall(EVP_DecryptUpdate, .{ self.ctx, p1, &len, p0, @as(c_int, @intCast(dlen - TAG_SIZE)) }, is_one);
                _ = try sslcall(EVP_DecryptFinal_ex, .{ self.ctx, p1 + @as(usize, @intCast(len)), &tlen }, is_one);
                return ngx_str_t{ .data = p1, .len = @intCast(len) };
            }
        }
        return core.NError.OOM;
    }
};

const ngx_log_init = ngx.ngx_log_init;
const ngx_create_pool = ngx.ngx_create_pool;
const ngx_destroy_pool = ngx.ngx_destroy_pool;
test "ssl" {
    const nlog = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(1024, nlog);
    defer ngx_destroy_pool(pool);

    const keys = [2][]const u8{
        \\-----BEGIN RSA PRIVATE KEY-----
        \\MIIEogIBAAKCAQEAptpm+qvIDCh/9wjU26SQCK26ogYkBhDrYxnAaw2JbbBsp1oD
        \\bHKk+1r381NeBUG2HEFAuU+Fr72u5ot3yKdzoF/FajAzQNKnm569/D3upKoi8mYB
        \\aST15Uig8j8qoUW1U217LL0jEHlSnHV3lcaDTXqDpTRR4Bfz9IqOgJgFZ8/oTfEo
        \\mSrjrLYef81Eyxr7ZIMQXEKKEK7V4UXKS0+/fDsiG/cXidhzt8UbTL9vqXqxM2+I
        \\DImyO+FAc/tkBG55LmzxPto1Nq0WbnZzRM/wTzrd0I/8NlevxtFbphg4evlHjFNI
        \\7+GrqR87ViEwuAJJ9Je5QQjct5YJfFRWiZ5CMQIDAQABAoIBAGBi/GhEgezcHIg1
        \\ltlHaFlLGuxsRbUnYwM9phVxnXk7GJlYe2/TjpERjPkIqOC6hBwwadZjJORP3FCc
        \\Mtc8PKRhjuZ377O7vU0915x2nnyLOGL1IE2AJ3iLi0ZFzTea0FPgg+5lWHM00s9F
        \\YI6qPcGtS41M+xtMWwZiYE3TBBRibHiY8ugGyaNAhiMKehyW05uApjlIF55wwCGx
        \\BkyESJpGRR/6853iHke6Ge+xVcMa9QmQdoH0QqL/8kT28PL568mJJr0Ow/83t4+d
        \\Pe70YPzKAxgUnaDsHJqO+b8qH69AEs8rTI5h2Mon6pH+bJT66KUoiXhn+Kf+4LSs
        \\henRP10CgYEA1QJSfuFOWVRjrg3N/rAIc/Ak84BTZavbyrkqBSuoTs9i/nMI/hOz
        \\VxpDntg7Bx2Tctl6sZO3GioTxKdc/YYaTKci1TKBbeginpsqEQVgwkMCy8HpvUmR
        \\fyAMqLwZC4h9+j+NiZtuoFJDTCgv+WYbasX+kWYEUM21bnSYuO7yEQsCgYEAyIdP
        \\r9uzqPgzN34Tmx+CNTa16VjhBh+zkBtXRLDLhWBeIYxoYNJARD98Pb1XZdvpkZZW
        \\Sk7MfaKo2/DomzyyyB/MbHWwAdFi3yb4y7uMJfyC1MzdUSNN3Vp579hJxHkJ+nN4
        \\Ys76yfcEeVOLnvUT1Z0KKCdIWRdT1Lgi+X1itzMCgYBJUXlPzwGG4fNFj97d0X23
        \\Wmt9nSgXkOYgi0eZbAOMzPmIF9R6kBFk49dur4Lx2g5Ms+r1gKC/0sfnIqxxX11i
        \\EQ1+UNoYGJUB/uql3TIG68XkmKR50P7RwRhaZBRC0gJ6xrFTMjsL2ATuC88niyvY
        \\vrn3FiRaI9RVZrDCxwxvLQKBgEXW4okEAqGBuAzGqztmkOnJoTehDdYdKmOxMgap
        \\cGiGdKJIjX3THDDoz3ONQyglnEZpTqpYoV3MTfU0BT8zt6x9bqwDnQY1D7NalmIW
        \\cqw0Mri8lQQSQKcsQLWo5aA466G/n5kCL1Qx5OwAjesRvhOyuvvbGpZ0ymyWqQ+t
        \\fLkDAoGATcul1L8y5D/wNVP1GXbXMZfBsFP3bbqy8c+Ashm6g8OLm2mGNntd5Z6h
        \\1KkID7Yksh+dZ6t7XaPBtGACXX5Eryr537JVvdX8hAVCp5HVtaN/9VBVP8Ka2e4s
        \\VS/xeNgOMQ7uzhRPBJ8HiTmdI1nHhDnYQpGiBgQn0Z5RAkSvFMk=
        \\-----END RSA PRIVATE KEY-----
        ,
        \\-----BEGIN PUBLIC KEY-----
        \\MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwXNI6sdlknHBnK8Fu2U6
        \\Cwor9qY747jP8KAfeBMeveEt1TqaHkLfaSD07trZLhGpfs8/AHqjhgSMO1O10YQW
        \\OrrJ4hjIWPKqxbgrYMkBQc+mwdiWp4W3ByCqxBRagCveCXRWCmuJYovl9H/bsDI0
        \\iGbpVtEOghJtfciisYSgxcLufUDTRkvwxjIBK1pCRjk33jJ5YTBWTHMRtMAOcFLN
        \\F6hdEYdX8SPsgHHeLZ5Lv2T/686w1xtgCHef/sd4uSfWmyzsalQdHG/e4IyYmrhx
        \\+O3VBoNDzE3nx23bFeV/RVNCG7cV6VhmYokJNHa/erIPkEmEFID6A5wQOXuxUkmJ
        \\WwIDAQAB
        \\-----END PUBLIC KEY-----
        ,
    };

    const data0 =
        \\GET
        \\/v3/refund/domestic/refunds/123123123123
        \\1554208460
        \\593BEC0C930BF1AFEB40B4A08C8FB242
        \\
        \\
    ;
    const signed0 =
        \\Lc9VXxmeonkdV8Xk9tmigQFLhl0vRWTerdmoRu01aAnYwIrD/5nsSwE1WlmZGLRlAFTNQ3QsMa0+VRDlJp1Wp5p0nO8EK68b5sJBbjouxaFciIfq1zfDWWz+jqhcMoKXI1A6dPm1AW7D4d30WsMTNzp6g23OXakIsh9LO3lUmwvTuE0BY8ncf6tNGk4wKmvXwERd/ZpoQY3MAVKz+Nakwc+2XBmzT66KcUehU5kr4IvGa/lEU5RZb/q00zP9VLdBhC/jQSX3X1UcJLCtEc4gTmib4tnmAT+bHF/e17ZAuxDNcx6rqT8gNEXqaJGG+1OflMSTU2tpyG65G4dMKdFcoA==
    ;

    const data1 =
        \\POST
        \\/v3/pay/transactions/jsapi
        \\1554208460
        \\593BEC0C930BF1AFEB40B4A08C8FB242
        \\{"appid":"wxd678efh567hg6787","mchid":"1230000109","description":"Image形象店-深圳腾大-QQ公仔","out_trade_no":"1217752501201407033233368018","notify_url":"https://www.weixin.qq.com/wxpay/pay.php","amount":{"total":100,"currency":"CNY"},"payer":{"openid":"oUpF8uMuAJO_M2pxb1Q9zNjWeS6o"}}
        \\
    ;

    const signed1 =
        \\gEuexJ547PHFV77TQ6eiE4tphVYfWfUe1Wc2dBmVnoMYU2rl/M4zhw+b3vBhuMw6AC7pteNkryLA7UWU2h+umo0OdSuuLm1++O3NckQPCSfm6dypsjn4GYm84KMqXWFrhFmyxEwIdEJDr3w1UYfxOcu55OQupfLkrt/ZzuOspnliJFrPzGQFUk7lGqMMtpz3EfbDUNxnVsHblORg3hVmuYNmbGWnS2ovU30Y2Q+iKFDxzkaXBk8LTy6HzvxizRo6Q+J4SVM7O0hKXfgo1QdI68kpzNULb3EVBXlhTyPUzhkHzzLxECL1qHl3HH2hEv8++C+4wBlsagF3j/O6PABojA==
    ;

    const data2 =
        \\GET
        \\/v3/marketing/partnerships?limit=5&offset=10&authorized_data%3D%7B%22business_type%22%3A%22FAVOR_STOCK%22%2C%20%22stock_id%22%3A%222433405%22%7D&partner%3D%7B%22type%22%3A%22APPID%22%2C%22appid%22%3A%22wx4e1916a585d1f4e9%22%2C%22merchant_id%22%3A%222480029552%22%7D
        \\1554208460
        \\593BEC0C930BF1AFEB40B4A08C8FB242
        \\
        \\
    ;

    const signed2 =
        \\C9PrZx8RTw7NF+e6SLmZxKgUBdXjH6EmUiu1i85Y6MApfWn4ueNpS4ED5no6uGObU0cfzTdaWyl6gAWDmyO2nG3MjHursadpzpNT8d+HaZapKis+boTHwJLgZXHXtacjX4zx2lOk/AONrKCLkjXRnh/DDp/kNsmDNYEiu+d/SeVvr+cL0XkL0CibAphyQSLYkv7Fh9uel89ax3ZGgVnBx+/MaBLCrYc1UqyYBDqfWPhS9fZf2OSghWMFp9c5dm+ORc97XbgzSOwAl8dcfLSrL/Sb4+L57+JZiq0iURjMXWzAD8FTUFYsJtJOYszRXJKLZNh4WGST39oplhhSdtxcoQ==
    ;

    const data3 =
        \\POST
        \\/v3/marketing/favor/media/image-upload
        \\1554208460
        \\593BEC0C930BF1AFEB40B4A08C8FB242
        \\{ "filename": "wechatpay_logo.png", "sha256": "d2973a45b1d528c21ebb77792ef3fcea40fa9a4e04a17e35369102ba9c84c8b1"}
        \\
    ;

    const signed3 =
        \\oykQTJijZbHL+0QjYjOcwvovGxlU9LMcfVheUUdvr94DIzN02MBwwAwnBMsDqGTnXe0fr7kxFbXz3cd53e7Fx2VU8S9Lt3u1dCMQV+b5Ut6wpReTMBcfSVVXl4AbmLHxvyi1KhVg+O3KGL2BT4dEbuR93voru/p/9CS7gyMSviZiupf1cuaipyTdZ/1Nn4ESeuPX8H7p2nwaxNLbS/rdLltvQGU1ecK0m4u5p4uXh1mdM1Kh8fymJHvkurOzVORoB3Y23g2RUFT0WwNBVxpp19bdAWsqIoouPjyY6tFGD9cnQIVmIbm9oRDrOWmQMHubWlmjYL5UfP39pq1T+/hNpw==
    ;

    const data4 =
        \\1722850421
        \\d824f2e086d3c1df967785d13fcd22ef
        \\{"code_url":"weixin://wxpay/bizpayurl?pr=JyC91EIz1"}
        \\
    ;

    const signed4 =
        \\mfI1CPqvBrgcXfgXMFjdNIhBf27ACE2YyeWsWV9ZI7T7RU0vHvbQpu9Z32ogzc+k8ZC5n3kz7h70eWKjgqNdKQF0eRp8mVKlmfzMLBVHbssB9jEZEDXThOX1XFqX7s7ymia1hoHQxQagPGzkdWxtlZPZ4ZPvr1RiqkgAu6Is8MZgXXrRoBKqjmSdrP1N7uxzJ/cjfSiis9FiLjuADoqmQ1P7p2N876YPAol7Rn0+GswwAwxldbdLrmVSjfytfSBJFqTMHn4itojgxSWWN1byuckQt8hSTEv/Lg97QoeGniYP17T80pJeQyL3b+295FPHSO2AtvCgyIbKMZ0BALilAA==
    ;

    const ds = [_][2][]const u8{
        .{ data0, signed0 },
        .{ data1, signed1 },
        .{ data2, signed2 },
        .{ data3, signed3 },
        .{ data4, signed4 },
    };

    var rsa = try NSSL_RSA.init(ngx_string(keys[0]), ngx_string(keys[1]));
    defer rsa.deinit();

    for (ds, 0..) |t, i| {
        if (i < 4) {
            const signed = try rsa.sign_sha256(ngx_string(t[0]), pool);
            try expectEqual(std.mem.eql(u8, core.slicify(u8, signed.data, signed.len), t[1]), true);
        } else {
            try expectEqual(rsa.verify_sha256(ngx_string(t[1]), ngx_string(t[0]), pool), true);
        }
    }

    const keys1 = [3][]const u8{
        \\-----BEGIN PRIVATE KEY-----
        \\MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDGPEEIEpWHQinm
        \\tCzGsnfGYhM2lqgtP/AGgbiM62MZWJMRhUtlZMV/Ownm6x3ZLEgXAzRYWOdVqq/w
        \\PrWxc4W5d4dmjjaKjc7erW0Z+l6mn8kXAJ7UbmdXaisX1fbHvls5WdKx+4nN2Lmn
        \\2Fy3cWdIbXebvrobf65t6pcOqsC4YDDTRGwr+TfE6k/MAv2025U3H7biXB3tuRya
        \\TOqDddC9IKTwROenoJDLnF0maEBfkvLokJ2GZCuYRuNdOJsayzrp3kl462soo/vO
        \\VZyPz8ejP1OeltmxDX9xyuz/6ywSO0o7VU5YX+qcakzjNuIeUKh51joxIBEG8PbR
        \\2m3ExYerAgMBAAECggEADdOvryIP6MDmSBk5Jk+i2xhSjsD9A54tRJO3wHYkRP63
        \\A2A9kHNYjM9PzLOJmXEYdijbD259p3puwZGEl6QFjjIwJFvqO5Y4kuYCpIhtVOHz
        \\fMJzHnSBvZWO++w73yLMtutbYhHrD4vJjbnufaODUlUp8P5H4BmMnE4VZNVNxY5d
        \\Z6VMhonvSvoc30hKyNwG7JuGkpIuL8lhJcQS2Y4bssXqaYVCbOi1mDW2gQ0UJ4wE
        \\a3Ik+AgcUYJeFp6oDa4R0RUhLjavjCF65UtKSFSWJ67dTxoPco21Dj42AUP4t09g
        \\HKBFOBbxDp9ssps4mhdCYACTS2HJcNinXrNZLdJxAQKBgQDpI3A3tIUqsbiPis5h
        \\LWoxag1OJi1vVRKSQzO09WP6iclhlMjhx/UIyqkHV8oZQt3aMrEEhrrDGdA6yOVa
        \\0lBJxNzBGttyGIQC1ucxKYYHS8hrg5reJr1NJgpBmkCMZKuhsPAzMYPzrLQ6mZq6
        \\pK3jvec4/ZVSWF5Wm2IXaljq+wKBgQDZrKGGJnKPQ5d15Ptq6c47cYnDborupJed
        \\HYx+5QWgB7Pkf28q8CkyHHP9WNsmlZMA/s1ifKT0Ac7DIvqHAcw9zcpMl91h1QSb
        \\qtTcdPT7D/KjwvA8bKJiutvC0C9lbjSnD+JcAVnLb3XRerfAfa0AiqpFy8OkdaVu
        \\P+fP4YY3EQKBgQCHDhV636NpGS0OUl29474pxALTK8CURxcMDcwNXz48q8cyNSut
        \\x9UF88i5TTzxJ1A3j7gGJDpavUBoXWqoEz+ZjGZJo1JOpS8MKgwh6akP3vHKfqGf
        \\YZe18nxshnwwGD1o3IQ5U8zZw0lgzQzaZH2reZ5R4Gy5GCIGT9siL2Q1MwKBgB8P
        \\y1zhT6ex9YMVUetHwe4pnYcN1zWGtzvsY4gYFl1nu/v3U13FN5u3A7Y7X8p5vah+
        \\s8BCGSfYujCOZUGut/55x0x2v1ielTHBhu6OogbRl8ZWowF8Xw/HqmR6YMkQmOLe
        \\GWcXqkClfyKNaHtHc9CH+RRMp3Zoc1rwM5wuioCBAoGAV4thpW1oCKAXf+O5+KZH
        \\dTPrRcHSwRZzhjfwlb3f2jlmJBx8JscXXf0Ro0kZCd3rMVdgThU70TgJMNsCsAoE
        \\iVEP9wZC6IQ3+9g2FVwEv8P6LZevCe9E22Iatx5AmIt2wrygUrGAvxOCjKGZjzZB
        \\6I7+OFjwOHYwndji7Tw8tIM=
        \\-----END PRIVATE KEY-----
        ,
        \\-----BEGIN PUBLIC KEY-----
        \\MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxjxBCBKVh0Ip5rQsxrJ3
        \\xmITNpaoLT/wBoG4jOtjGViTEYVLZWTFfzsJ5usd2SxIFwM0WFjnVaqv8D61sXOF
        \\uXeHZo42io3O3q1tGfpepp/JFwCe1G5nV2orF9X2x75bOVnSsfuJzdi5p9hct3Fn
        \\SG13m766G3+ubeqXDqrAuGAw00RsK/k3xOpPzAL9tNuVNx+24lwd7bkcmkzqg3XQ
        \\vSCk8ETnp6CQy5xdJmhAX5Ly6JCdhmQrmEbjXTibGss66d5JeOtrKKP7zlWcj8/H
        \\oz9TnpbZsQ1/ccrs/+ssEjtKO1VOWF/qnGpM4zbiHlCoedY6MSARBvD20dptxMWH
        \\qwIDAQAB
        \\-----END PUBLIC KEY-----
        ,
        \\Hello, OpenSSL 3.0 RSA-OAEP!
        ,
    };

    var rsa_oaep = try NSSL_RSA.init(ngx_string(keys1[0]), ngx_string(keys1[1]));
    defer rsa_oaep.deinit();

    const b64 = try rsa_oaep.oaep_encrypt(ngx_string(keys1[2]), pool);
    const txt = try rsa_oaep.oaep_decrypt(b64, pool);
    try std.testing.expectEqualSlices(u8, core.slicify(u8, txt.data, txt.len), keys1[2]);

    const aes_256_gcm = [4][]const u8{
        \\000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
        ,
        \\000102030405060708090a0b
        ,
        \\Hello, OpenSSL 3.0 AES-256-GCM!!!
        ,
        \\aad
        ,
    };

    var aes = try NSSL_AES_256_GCM.init(ngx_string(aes_256_gcm[0]));
    defer aes.deinit();

    const bb = try aes.encrypt(ngx_string(aes_256_gcm[2]), ngx_string(aes_256_gcm[1]), ngx_string(aes_256_gcm[3]), pool);
    const tt = try aes.decrypt(bb, ngx_string(aes_256_gcm[1]), ngx_string(aes_256_gcm[3]), pool);
    try std.testing.expectEqualSlices(u8, core.slicify(u8, tt.data, tt.len), aes_256_gcm[2]);
}
