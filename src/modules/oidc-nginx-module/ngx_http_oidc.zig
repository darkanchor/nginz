const std = @import("std");
const ngx = @import("ngx");

const buf = ngx.buf;
const ssl = ngx.ssl;
const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const cjson = ngx.cjson;
const CJSON = cjson.CJSON;

const NGX_OK = core.NGX_OK;
const NGX_DONE = core.NGX_DONE;
const NGX_AGAIN = core.NGX_AGAIN;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;

const ngx_str_t = core.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_msec_t = core.ngx_msec_t;
const ngx_pool_t = core.ngx_pool_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_buf_t = buf.ngx_buf_t;
const ngx_chain_t = buf.ngx_chain_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;
const ngx_http_variable_value_t = http.ngx_http_variable_value_t;

const ngx_string = ngx.string.ngx_string;
const ngx_null_str = ngx.string.ngx_null_str;
const ngx_sprintf = ngx.string.ngx_sprintf;
const NArray = ngx.array.NArray;
const NList = ngx.list.NList;
const NChain = buf.NChain;
const ngx_table_elt_t = ngx.hash.ngx_table_elt_t;
const NSSL_AES_256_GCM = ssl.NSSL_AES_256_GCM;

const PAGE_SIZE = 4096;
extern var ngx_pagesize: ngx_uint_t;
extern var ngx_http_upstream_module: ngx_module_t;

// Constants for redirect
const NGX_HTTP_MOVED_TEMPORARILY: ngx_uint_t = 302;

extern var ngx_http_core_module: ngx_module_t;
extern fn time(t: ?*i64) i64;
extern fn BN_new() ?*ssl.BIGNUM;
extern fn BN_free(a: ?*ssl.BIGNUM) void;
extern fn BN_bin2bn(s: [*c]const u8, len: c_int, ret: ?*ssl.BIGNUM) ?*ssl.BIGNUM;
extern fn RSA_new() ?*ssl.RSA;
extern fn RSA_free(r: ?*ssl.RSA) void;
extern fn RSA_set0_key(r: ?*ssl.RSA, n: ?*ssl.BIGNUM, e: ?*ssl.BIGNUM, d: ?*ssl.BIGNUM) c_int;
extern fn EVP_PKEY_new() ?*ssl.EVP_PKEY;
extern fn EVP_PKEY_set1_RSA(pkey: ?*ssl.EVP_PKEY, key: ?*ssl.RSA) c_int;
extern fn getaddrinfo(node: [*:0]const u8, service: [*:0]const u8, hints: ?*const std.posix.addrinfo, res: *?*std.posix.addrinfo) c_int;
extern fn freeaddrinfo(res: ?*std.posix.addrinfo) void;
extern fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern fn connect(fd: c_int, addr: ?*const std.posix.sockaddr, len: std.posix.socklen_t) c_int;
extern fn send(fd: c_int, buf: [*c]const u8, len: usize, flags: c_int) isize;
extern fn recv(fd: c_int, buf: [*c]u8, len: usize, flags: c_int) isize;
extern fn close(fd: c_int) c_int;
const CFile = opaque {};
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*CFile;
extern fn fread(ptr: ?*anyopaque, size: usize, nmemb: usize, stream: ?*CFile) usize;
extern fn fseek(stream: ?*CFile, offset: c_long, whence: c_int) c_int;
extern fn ftell(stream: ?*CFile) c_long;
extern fn fclose(stream: ?*CFile) c_int;

// Constants
const STATE_SIZE = 32;
const NONCE_SIZE = 32;
const IV_SIZE = NSSL_AES_256_GCM.IV_SIZE;
const SESSION_DURATION_SEC = 3600; // 1 hour default
const MAX_PENDING_COOKIES: usize = 4;
const MAX_JWKS_KEYS: usize = 16;
const DISCOVERY_CACHE_TTL_SEC: i64 = 300;
const JWKS_CACHE_TTL_SEC: i64 = 300;
const CLAIM_TIME_SKEW_SEC: i64 = 30;

// Headers to pass through from upstream
const oidc_pass_headers = [_]ngx_str_t{
    ngx.string.ngx_null_str,
};

const oidc_hide_headers = [_]ngx_str_t{
    ngx.string.ngx_null_str,
};

var oidc_last_error_buf: [128]u8 = undefined;
var oidc_last_error_len: usize = 0;

fn setOidcLastError(msg: []const u8) void {
    const len = @min(msg.len, oidc_last_error_buf.len);
    @memcpy(oidc_last_error_buf[0..len], msg[0..len]);
    oidc_last_error_len = len;
}

fn oidcLastError() []const u8 {
    if (oidc_last_error_len == 0) return "OIDC internal error";
    return oidc_last_error_buf[0..oidc_last_error_len];
}

const oidc_jwks_key = extern struct {
    kid: ngx_str_t,
    n: ngx_str_t,
    e: ngx_str_t,
};

// Location configuration
const oidc_loc_conf = extern struct {
    enabled: ngx_flag_t,
    discovery_url: ngx_str_t,
    client_id: ngx_str_t,
    client_secret: ngx_str_t,
    redirect_uri: ngx_str_t,
    scope: ngx_str_t,
    cookie_name: ngx_str_t,
    cookie_secret: ngx_str_t, // 32-byte hex key for AES-256-GCM
    use_pkce: ngx_flag_t,

    // Derived from discovery or config
    issuer: ngx_str_t,
    authorization_endpoint: ngx_str_t,
    token_endpoint: ngx_str_t,
    jwks_uri: ngx_str_t,
    metadata_owned: ngx_flag_t,
    discovery_loaded_at: i64,
    jwks_loaded_at: i64,
    jwks_keys: [MAX_JWKS_KEYS]oidc_jwks_key,
    jwks_key_count: usize,

    // AES cipher context (initialized on first use)
    aes: ?*NSSL_AES_256_GCM,

    // Upstream config for token endpoint
    ups: http.ngx_http_upstream_conf_t,
};

// Token exchange state
const token_exchange_state = enum(ngx_uint_t) {
    PENDING,
    READING_HEADERS,
    READING_BODY,
    SUCCESS,
    FAILED,
};

// Request context
const oidc_request_ctx = extern struct {
    done: ngx_flag_t,
    lccf: [*c]oidc_loc_conf,

    // Session claims (if valid session exists)
    sub: ngx_str_t,
    email: ngx_str_t,
    name: ngx_str_t,

    // State for callback handling
    state: ngx_str_t,
    nonce: ngx_str_t,
    code_verifier: ngx_str_t,
    original_uri: ngx_str_t,

    // Token exchange state
    token_state: token_exchange_state,
    token_response: [*c]ngx_chain_t,
    http_status: http.ngx_http_status_t,

    // Body reading state (for reading body in process_header)
    content_length: isize,
    body_received: usize,
    body_buf: [*c]u8,
    body_capacity: usize,

    pending_cookies: [MAX_PENDING_COOKIES]ngx_str_t,
    pending_cookie_count: ngx_uint_t,
};

// Session structure (stored in encrypted cookie)
const OidcSession = struct {
    sub: []const u8,
    email: []const u8,
    name: []const u8,
    exp: i64,
    iat: i64,
};

// ============================================================================
// Utility Functions
// ============================================================================

// Generate random bytes and encode as hex
fn generateRandomHex(pool: [*c]ngx_pool_t, num_bytes: usize) ?ngx_str_t {
    var random_bytes: [64]u8 = undefined;
    const actual_bytes = @min(num_bytes, 64);

    if (ssl.RAND_bytes(&random_bytes, @intCast(actual_bytes)) != 1) {
        return null;
    }

    const hex_len = actual_bytes * 2;
    const hex_buf = core.castPtr(u8, core.ngx_pnalloc(pool, hex_len)) orelse return null;

    const hex_chars = "0123456789abcdef";
    for (0..actual_bytes) |i| {
        hex_buf[i * 2] = hex_chars[random_bytes[i] >> 4];
        hex_buf[i * 2 + 1] = hex_chars[random_bytes[i] & 0x0f];
    }

    return ngx_str_t{ .len = hex_len, .data = hex_buf };
}

// Parse hex string to bytes
fn hexToBytes(hex: []const u8, out: []u8) bool {
    if (hex.len != out.len * 2) return false;

    for (out, 0..) |*byte, i| {
        const high = hexDigitToInt(hex[i * 2]) orelse return false;
        const low = hexDigitToInt(hex[i * 2 + 1]) orelse return false;
        byte.* = (high << 4) | low;
    }
    return true;
}

fn hexDigitToInt(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// Base64url encode (JWT-style, no padding)
fn base64urlEncode(pool: [*c]ngx_pool_t, data: []const u8) ?ngx_str_t {
    const encoded_len = ssl.ngx_base64_encoded_length(data.len);
    const buf_ptr = core.castPtr(u8, core.ngx_pnalloc(pool, encoded_len + 1)) orelse return null;

    var src = ngx_str_t{ .len = data.len, .data = @constCast(data.ptr) };
    var dst = ngx_str_t{ .len = 0, .data = buf_ptr };

    ngx.string.ngx_encode_base64(&dst, &src);

    // Convert to base64url: + -> -, / -> _, remove padding
    var final_len: usize = dst.len;
    for (0..dst.len) |i| {
        if (buf_ptr[i] == '+') buf_ptr[i] = '-';
        if (buf_ptr[i] == '/') buf_ptr[i] = '_';
        if (buf_ptr[i] == '=') {
            final_len = i;
            break;
        }
    }

    return ngx_str_t{ .len = final_len, .data = buf_ptr };
}

// Base64url decode
fn base64urlDecode(pool: [*c]ngx_pool_t, encoded: []const u8) ?ngx_str_t {
    // Add padding if needed
    const padding_needed = (4 - (encoded.len % 4)) % 4;
    const padded_len = encoded.len + padding_needed;

    const padded_buf = core.castPtr(u8, core.ngx_pnalloc(pool, padded_len)) orelse return null;

    // Copy and convert from base64url to base64
    for (encoded, 0..) |c, i| {
        if (c == '-') {
            padded_buf[i] = '+';
        } else if (c == '_') {
            padded_buf[i] = '/';
        } else {
            padded_buf[i] = c;
        }
    }
    // Add padding
    for (encoded.len..padded_len) |i| {
        padded_buf[i] = '=';
    }

    const decoded_len = ssl.ngx_base64_decoded_length(padded_len);
    const out_buf = core.castPtr(u8, core.ngx_pnalloc(pool, decoded_len)) orelse return null;

    var src = ngx_str_t{ .len = padded_len, .data = padded_buf };
    var dst = ngx_str_t{ .len = 0, .data = out_buf };

    if (ngx.string.ngx_decode_base64(&dst, &src) != NGX_OK) {
        return null;
    }

    return dst;
}

// URL encode a string
fn urlEncode(pool: [*c]ngx_pool_t, str: []const u8) ?ngx_str_t {
    // Worst case: every char becomes %XX (3x size)
    const max_len = str.len * 3;
    const buf_ptr = core.castPtr(u8, core.ngx_pnalloc(pool, max_len)) orelse return null;

    var out_idx: usize = 0;
    for (str) |c| {
        if (isUrlSafe(c)) {
            buf_ptr[out_idx] = c;
            out_idx += 1;
        } else {
            buf_ptr[out_idx] = '%';
            buf_ptr[out_idx + 1] = "0123456789ABCDEF"[c >> 4];
            buf_ptr[out_idx + 2] = "0123456789ABCDEF"[c & 0x0f];
            out_idx += 3;
        }
    }

    return ngx_str_t{ .len = out_idx, .data = buf_ptr };
}

fn isUrlSafe(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
}

fn appendJsonEscaped(out: []u8, offset: *usize, value: []const u8) bool {
    for (value) |c| {
        switch (c) {
            '"', '\\' => {
                if (offset.* + 2 > out.len) return false;
                out[offset.*] = '\\';
                out[offset.* + 1] = c;
                offset.* += 2;
            },
            '\n' => {
                if (offset.* + 2 > out.len) return false;
                out[offset.*] = '\\';
                out[offset.* + 1] = 'n';
                offset.* += 2;
            },
            '\r' => {
                if (offset.* + 2 > out.len) return false;
                out[offset.*] = '\\';
                out[offset.* + 1] = 'r';
                offset.* += 2;
            },
            '\t' => {
                if (offset.* + 2 > out.len) return false;
                out[offset.*] = '\\';
                out[offset.* + 1] = 't';
                offset.* += 2;
            },
            else => {
                if (c < 0x20 or offset.* + 1 > out.len) return false;
                out[offset.*] = c;
                offset.* += 1;
            },
        }
    }
    return true;
}

fn allocPersistentBytes(bytes: []const u8) ?[*]u8 {
    const duped = std.heap.c_allocator.dupe(u8, bytes) catch return null;
    return duped.ptr;
}

fn allocPersistentNgxStr(bytes: []const u8) ?ngx_str_t {
    if (bytes.len == 0) return ngx_null_str;
    const duped = std.heap.c_allocator.dupe(u8, bytes) catch return null;
    return ngx_str_t{ .len = duped.len, .data = duped.ptr };
}

fn freePersistentNgxStr(str: *ngx_str_t) void {
    if (str.*.len == 0 or str.*.data == core.nullptr(u8)) {
        str.* = ngx_null_str;
        return;
    }

    std.heap.c_allocator.free(str.*.data[0..str.*.len]);
    str.* = ngx_null_str;
}

fn clearOwnedMetadata(lccf: *oidc_loc_conf) void {
    if (lccf.metadata_owned == 1) {
        freePersistentNgxStr(&lccf.issuer);
        freePersistentNgxStr(&lccf.authorization_endpoint);
        freePersistentNgxStr(&lccf.token_endpoint);
        freePersistentNgxStr(&lccf.jwks_uri);
    }

    lccf.metadata_owned = 0;
    lccf.discovery_loaded_at = 0;
}

fn clearJwksCache(lccf: *oidc_loc_conf) void {
    var idx: usize = 0;
    while (idx < lccf.jwks_key_count and idx < MAX_JWKS_KEYS) : (idx += 1) {
        freePersistentNgxStr(&lccf.jwks_keys[idx].kid);
        freePersistentNgxStr(&lccf.jwks_keys[idx].n);
        freePersistentNgxStr(&lccf.jwks_keys[idx].e);
    }

    lccf.jwks_key_count = 0;
    lccf.jwks_loaded_at = 0;
}

fn fetchUrlBody(url: []const u8) ?[]u8 {
    if (std.mem.indexOf(u8, url, "://") == null) {
        const path_z = std.heap.c_allocator.dupeZ(u8, url) catch return null;
        defer std.heap.c_allocator.free(path_z);

        const mode = "rb";
        const file = fopen(path_z.ptr, mode) orelse {
            setOidcLastError("fopen failed");
            return null;
        };
        defer _ = fclose(file);

        if (fseek(file, 0, 2) != 0) {
            setOidcLastError("fseek end failed");
            return null;
        }
        const size = ftell(file);
        if (size < 0) {
            setOidcLastError("ftell failed");
            return null;
        }
        if (fseek(file, 0, 0) != 0) {
            setOidcLastError("fseek start failed");
            return null;
        }

        const body = std.heap.c_allocator.alloc(u8, @intCast(size)) catch return null;
        errdefer std.heap.c_allocator.free(body);
        const read_n = fread(body.ptr, 1, body.len, file);
        if (read_n != body.len) {
            setOidcLastError("fread short read");
            return null;
        }
        return body;
    }

    const parsed_host = get_host(ngx_str_t{ .len = url.len, .data = @constCast(url.ptr) });
    if (parsed_host.ssl) return null;

    const host_slice = core.slicify(u8, parsed_host.host.data, parsed_host.host.len);
    const path_slice = core.slicify(u8, parsed_host.path.data, parsed_host.path.len);
    const host_z = std.heap.c_allocator.dupeZ(u8, host_slice) catch return null;
    defer std.heap.c_allocator.free(host_z);

    var port_buf: [16]u8 = undefined;
    const port_slice = std.fmt.bufPrint(&port_buf, "{d}", .{parsed_host.port}) catch return null;
    const port_z = std.heap.c_allocator.dupeZ(u8, port_slice) catch return null;
    defer std.heap.c_allocator.free(port_z);

    var hints: std.posix.addrinfo = .{
        .flags = .{ .NUMERICSERV = true },
        .family = std.posix.AF.UNSPEC,
        .socktype = std.posix.SOCK.STREAM,
        .protocol = std.posix.IPPROTO.TCP,
        .canonname = null,
        .addr = null,
        .addrlen = 0,
        .next = null,
    };
    var res: ?*std.posix.addrinfo = null;
    if (getaddrinfo(host_z.ptr, port_z.ptr, &hints, &res) != 0) {
        setOidcLastError("getaddrinfo failed");
        return null;
    }
    defer if (res) |addr| freeaddrinfo(addr);

    var fd: c_int = -1;
    var it = res;
    while (it) |addr| : (it = addr.next) {
        fd = socket(addr.family, addr.socktype, addr.protocol);
        if (fd < 0) continue;
        if (connect(fd, addr.addr, addr.addrlen) == 0) break;
        _ = close(fd);
        fd = -1;
    }
    if (fd < 0) {
        setOidcLastError("connect failed");
        return null;
    }
    defer _ = close(fd);

    const request = std.fmt.allocPrint(std.heap.c_allocator, "GET {s} HTTP/1.1\r\nHost: {s}\r\nAccept: application/json\r\nConnection: close\r\n\r\n", .{ path_slice, host_slice }) catch return null;
    defer std.heap.c_allocator.free(request);

    var sent: usize = 0;
    while (sent < request.len) {
        const wrote = send(fd, request.ptr + sent, request.len - sent, 0);
        if (wrote <= 0) {
            setOidcLastError("send failed");
            return null;
        }
        sent += @intCast(wrote);
    }

    var response = std.ArrayList(u8).initCapacity(std.heap.c_allocator, 4096) catch return null;
    defer response.deinit(std.heap.c_allocator);

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = recv(fd, &chunk[0], chunk.len, 0);
        if (n < 0) {
            setOidcLastError("recv failed");
            return null;
        }
        if (n == 0) break;
        response.appendSlice(std.heap.c_allocator, chunk[0..@intCast(n)]) catch return null;
    }

    const header_end = std.mem.indexOf(u8, response.items, "\r\n\r\n") orelse {
        setOidcLastError("missing response header terminator");
        return null;
    };
    const status_end = std.mem.indexOf(u8, response.items, "\r\n") orelse {
        setOidcLastError("missing status line terminator");
        return null;
    };
    const status_line = response.items[0..status_end];
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 200") and !std.mem.startsWith(u8, status_line, "HTTP/1.0 200")) {
        setOidcLastError("non-200 response");
        return null;
    }

    return std.heap.c_allocator.dupe(u8, response.items[header_end + 4 ..]) catch null;
}

fn loadDiscoveryMetadata(lccf: *oidc_loc_conf, force_refresh: bool) bool {
    if (lccf.discovery_url.len == 0) return false;

    const now = time(null);
    if (!force_refresh and
        lccf.discovery_loaded_at > 0 and
        now - lccf.discovery_loaded_at < DISCOVERY_CACHE_TTL_SEC and
        lccf.issuer.len > 0 and
        lccf.authorization_endpoint.len > 0 and
        lccf.token_endpoint.len > 0 and
        lccf.jwks_uri.len > 0)
    {
        return true;
    }

    const discovery_url = core.slicify(u8, lccf.discovery_url.data, lccf.discovery_url.len);
    const body = fetchUrlBody(discovery_url) orelse return false;
    defer std.heap.c_allocator.free(body);

    const DiscoveryDoc = struct {
        issuer: []const u8,
        authorization_endpoint: []const u8,
        token_endpoint: []const u8,
        jwks_uri: []const u8,
    };

    const parsed = std.json.parseFromSlice(DiscoveryDoc, std.heap.c_allocator, body, .{ .ignore_unknown_fields = true }) catch {
        setOidcLastError("discovery json parse failed");
        return false;
    };
    defer parsed.deinit();

    if (parsed.value.issuer.len == 0 or
        parsed.value.authorization_endpoint.len == 0 or
        parsed.value.token_endpoint.len == 0 or
        parsed.value.jwks_uri.len == 0)
    {
        setOidcLastError("discovery missing required fields");
        return false;
    }

    var issuer = allocPersistentNgxStr(parsed.value.issuer) orelse return false;
    errdefer freePersistentNgxStr(&issuer);
    var authorization_endpoint = allocPersistentNgxStr(parsed.value.authorization_endpoint) orelse return false;
    errdefer freePersistentNgxStr(&authorization_endpoint);
    var token_endpoint = allocPersistentNgxStr(parsed.value.token_endpoint) orelse return false;
    errdefer freePersistentNgxStr(&token_endpoint);
    var jwks_uri = allocPersistentNgxStr(parsed.value.jwks_uri) orelse return false;
    errdefer freePersistentNgxStr(&jwks_uri);

    clearOwnedMetadata(lccf);
    clearJwksCache(lccf);

    lccf.issuer = issuer;
    lccf.authorization_endpoint = authorization_endpoint;
    lccf.token_endpoint = token_endpoint;
    lccf.jwks_uri = jwks_uri;
    lccf.metadata_owned = 1;
    lccf.discovery_loaded_at = now;
    return true;
}

fn loadJwksKeys(lccf: *oidc_loc_conf, force_refresh: bool) bool {
    if (lccf.jwks_uri.len == 0 and !loadDiscoveryMetadata(lccf, force_refresh)) {
        return false;
    }

    const now = time(null);
    if (!force_refresh and
        lccf.jwks_loaded_at > 0 and
        now - lccf.jwks_loaded_at < JWKS_CACHE_TTL_SEC and
        lccf.jwks_key_count > 0)
    {
        return true;
    }

    const jwks_uri = core.slicify(u8, lccf.jwks_uri.data, lccf.jwks_uri.len);
    const body = fetchUrlBody(jwks_uri) orelse return false;
    defer std.heap.c_allocator.free(body);

    const JwkDoc = struct {
        keys: []const struct {
            kty: []const u8 = "",
            kid: ?[]const u8 = null,
            alg: ?[]const u8 = null,
            use: ?[]const u8 = null,
            n: ?[]const u8 = null,
            e: ?[]const u8 = null,
        },
    };

    const parsed = std.json.parseFromSlice(JwkDoc, std.heap.c_allocator, body, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();

    clearJwksCache(lccf);

    for (parsed.value.keys) |key| {
        if (lccf.jwks_key_count >= MAX_JWKS_KEYS) break;
        const kid = key.kid orelse continue;
        const n = key.n orelse continue;
        const e = key.e orelse continue;
        if (!std.mem.eql(u8, key.kty, "RSA")) continue;
        if (key.alg) |alg| {
            if (!std.mem.eql(u8, alg, "RS256")) continue;
        }
        if (key.use) |use| {
            if (!std.mem.eql(u8, use, "sig")) continue;
        }

        const idx = lccf.jwks_key_count;
        lccf.jwks_keys[idx].kid = allocPersistentNgxStr(kid) orelse continue;
        lccf.jwks_keys[idx].n = allocPersistentNgxStr(n) orelse {
            freePersistentNgxStr(&lccf.jwks_keys[idx].kid);
            continue;
        };
        lccf.jwks_keys[idx].e = allocPersistentNgxStr(e) orelse {
            freePersistentNgxStr(&lccf.jwks_keys[idx].kid);
            freePersistentNgxStr(&lccf.jwks_keys[idx].n);
            continue;
        };
        lccf.jwks_key_count += 1;
    }

    lccf.jwks_loaded_at = now;
    return lccf.jwks_key_count > 0;
}

fn findJwksKey(lccf: *oidc_loc_conf, kid: []const u8, allow_refresh: bool) ?*oidc_jwks_key {
    if (!loadJwksKeys(lccf, false)) return null;

    var idx: usize = 0;
    while (idx < lccf.jwks_key_count) : (idx += 1) {
        const cached_kid = core.slicify(u8, lccf.jwks_keys[idx].kid.data, lccf.jwks_keys[idx].kid.len);
        if (std.mem.eql(u8, cached_kid, kid)) return &lccf.jwks_keys[idx];
    }

    if (!allow_refresh or !loadJwksKeys(lccf, true)) return null;

    idx = 0;
    while (idx < lccf.jwks_key_count) : (idx += 1) {
        const cached_kid = core.slicify(u8, lccf.jwks_keys[idx].kid.data, lccf.jwks_keys[idx].kid.len);
        if (std.mem.eql(u8, cached_kid, kid)) return &lccf.jwks_keys[idx];
    }

    return null;
}

fn makeRsaPublicKey(pool: [*c]ngx_pool_t, jwk: *const oidc_jwks_key) ?*ssl.EVP_PKEY {
    const n_decoded = base64urlDecode(pool, core.slicify(u8, jwk.n.data, jwk.n.len)) orelse return null;
    const e_decoded = base64urlDecode(pool, core.slicify(u8, jwk.e.data, jwk.e.len)) orelse return null;

    const rsa = RSA_new() orelse return null;
    errdefer RSA_free(rsa);

    const n_bn = BN_bin2bn(n_decoded.data, @intCast(n_decoded.len), null) orelse return null;
    const e_bn = BN_bin2bn(e_decoded.data, @intCast(e_decoded.len), null) orelse {
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

fn verifyRs256Signature(pool: [*c]ngx_pool_t, jwk: *const oidc_jwks_key, signing_input: []const u8, signature_b64: []const u8) bool {
    const signature = base64urlDecode(pool, signature_b64) orelse return false;
    const pkey = makeRsaPublicKey(pool, jwk) orelse return false;
    defer ssl.EVP_PKEY_free(pkey);

    const md_ctx = ssl.EVP_MD_CTX_new() orelse return false;
    defer ssl.EVP_MD_CTX_free(md_ctx);
    defer _ = ssl.EVP_MD_CTX_reset(md_ctx);

    if (ssl.EVP_DigestVerifyInit(md_ctx, null, ssl.EVP_sha256(), null, pkey) != 1) return false;
    if (ssl.EVP_DigestVerifyUpdate(md_ctx, signing_input.ptr, signing_input.len) != 1) return false;
    return ssl.EVP_DigestVerifyFinal(md_ctx, signature.data, signature.len) == 1;
}

// Find cookie value by name
fn findCookie(r: [*c]ngx_http_request_t, name: []const u8) ?ngx_str_t {
    // In nginx, headers_in.cookie is a single pointer to a table_elt_t
    // The value contains all cookies in "name1=val1; name2=val2" format
    const cookie_header = r.*.headers_in.cookie;
    if (cookie_header == core.nullptr(ngx_table_elt_t)) return null;
    if (cookie_header.*.value.len == 0) return null;

    const cookie_str = core.slicify(u8, cookie_header.*.value.data, cookie_header.*.value.len);

    // Parse cookies: name1=value1; name2=value2
    var pos: usize = 0;
    while (pos < cookie_str.len) {
        // Skip leading spaces
        while (pos < cookie_str.len and (cookie_str[pos] == ' ' or cookie_str[pos] == ';')) {
            pos += 1;
        }
        if (pos >= cookie_str.len) break;

        // Find the '='
        const eq_pos = std.mem.indexOfPos(u8, cookie_str, pos, "=") orelse break;
        const key = cookie_str[pos..eq_pos];

        // Find end of value (semicolon or end)
        const value_start = eq_pos + 1;
        var value_end = value_start;
        while (value_end < cookie_str.len and cookie_str[value_end] != ';') {
            value_end += 1;
        }

        if (std.mem.eql(u8, key, name)) {
            if (value_end > value_start) {
                return ngx_str_t{
                    .len = value_end - value_start,
                    .data = cookie_header.*.value.data + value_start,
                };
            }
        }

        pos = value_end + 1;
    }

    return null;
}

// Parse query parameter from URI
fn getQueryParam(r: [*c]ngx_http_request_t, param_name: []const u8) ?ngx_str_t {
    if (r.*.args.len == 0) return null;

    const args = core.slicify(u8, r.*.args.data, r.*.args.len);
    const search_key = param_name;

    var pos: usize = 0;
    while (pos < args.len) {
        // Find parameter name
        const eq_pos = std.mem.indexOfPos(u8, args, pos, "=") orelse break;
        const key = args[pos..eq_pos];

        // Find end of value
        const amp_pos = std.mem.indexOfPos(u8, args, eq_pos + 1, "&") orelse args.len;
        const value_start = eq_pos + 1;
        const value_end = amp_pos;

        if (std.mem.eql(u8, key, search_key)) {
            return ngx_str_t{
                .len = value_end - value_start,
                .data = r.*.args.data + value_start,
            };
        }

        pos = amp_pos + 1;
    }

    return null;
}

// ============================================================================
// Session Management
// ============================================================================

fn initAesContext(lccf: *oidc_loc_conf, pool: [*c]ngx_pool_t) ?*NSSL_AES_256_GCM {
    // Don't cache AES context - the pool is request-scoped but lccf is location-scoped
    // This would cause use-after-free when the first request's pool is freed
    _ = lccf.aes;

    // Parse hex key
    if (lccf.cookie_secret.len != 64) return null; // 32 bytes = 64 hex chars

    var key_bytes: [32]u8 = undefined;
    const secret_slice = core.slicify(u8, lccf.cookie_secret.data, lccf.cookie_secret.len);
    if (!hexToBytes(secret_slice, &key_bytes)) return null;

    const aes_ptr = core.castPtr(NSSL_AES_256_GCM, core.ngx_pcalloc(pool, @sizeOf(NSSL_AES_256_GCM))) orelse return null;

    aes_ptr.* = NSSL_AES_256_GCM.init(ngx_str_t{ .len = 32, .data = &key_bytes }) catch return null;

    return aes_ptr;
}

fn encryptSession(lccf: *oidc_loc_conf, session_json: ngx_str_t, pool: [*c]ngx_pool_t) ?ngx_str_t {
    const aes = initAesContext(lccf, pool) orelse return null;

    // Generate random IV
    var iv: [IV_SIZE]u8 = undefined;
    if (ssl.RAND_bytes(&iv, IV_SIZE) != 1) return null;

    const iv_str = ngx_str_t{ .len = IV_SIZE, .data = &iv };
    const aad = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };

    // Encrypt
    const encrypted = aes.encrypt(session_json, iv_str, aad, pool) catch return null;

    // Prepend IV to encrypted data: IV || ciphertext || tag (all base64)
    // For simplicity, we'll encode IV separately and concatenate
    const iv_b64 = base64urlEncode(pool, &iv) orelse return null;

    // Final format: iv_base64.encrypted_base64
    const total_len = iv_b64.len + 1 + encrypted.len;
    const result = core.castPtr(u8, core.ngx_pnalloc(pool, total_len)) orelse return null;

    @memcpy(result[0..iv_b64.len], core.slicify(u8, iv_b64.data, iv_b64.len));
    result[iv_b64.len] = '.';
    @memcpy(result[iv_b64.len + 1 ..][0..encrypted.len], core.slicify(u8, encrypted.data, encrypted.len));

    return ngx_str_t{ .len = total_len, .data = result };
}

fn decryptSession(lccf: *oidc_loc_conf, cookie_value: ngx_str_t, pool: [*c]ngx_pool_t) ?ngx_str_t {
    const aes = initAesContext(lccf, pool) orelse return null;

    const cookie_slice = core.slicify(u8, cookie_value.data, cookie_value.len);

    // Split by '.'
    const dot_pos = std.mem.indexOf(u8, cookie_slice, ".") orelse return null;

    const iv_b64 = cookie_slice[0..dot_pos];
    const encrypted_b64 = cookie_slice[dot_pos + 1 ..];

    // Decode IV
    const iv_decoded = base64urlDecode(pool, iv_b64) orelse return null;
    if (iv_decoded.len != IV_SIZE) return null;

    // Decrypt
    const encrypted_str = ngx_str_t{
        .len = encrypted_b64.len,
        .data = cookie_value.data + dot_pos + 1,
    };
    const aad = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };

    const decrypted = aes.decrypt(encrypted_str, iv_decoded, aad, pool) catch return null;

    return decrypted;
}

fn checkSession(r: [*c]ngx_http_request_t, lccf: *oidc_loc_conf, rctx: *oidc_request_ctx) bool {
    const cookie_name = if (lccf.cookie_name.len > 0)
        core.slicify(u8, lccf.cookie_name.data, lccf.cookie_name.len)
    else
        "oidc_session";

    const cookie_value = findCookie(r, cookie_name) orelse return false;

    // Decrypt session cookie
    const decrypted = decryptSession(lccf, cookie_value, r.*.pool) orelse return false;

    // Parse JSON
    var cj = CJSON.init(r.*.pool);
    const session_json = cj.decode(decrypted) catch return false;

    // Check expiration
    if (CJSON.query(session_json, "$.exp")) |exp_node| {
        if (CJSON.intValue(exp_node)) |exp| {
            const now = time(null);
            if (now > exp) return false; // Expired
        }
    }

    // Extract claims
    if (CJSON.query(session_json, "$.sub")) |sub_node| {
        if (CJSON.stringValue(sub_node)) |sub| {
            rctx.sub = ngx_str_t{ .len = sub.len, .data = sub.data };
        }
    }

    if (CJSON.query(session_json, "$.email")) |email_node| {
        if (CJSON.stringValue(email_node)) |email| {
            rctx.email = ngx_str_t{ .len = email.len, .data = email.data };
        }
    }

    if (CJSON.query(session_json, "$.name")) |name_node| {
        if (CJSON.stringValue(name_node)) |name| {
            rctx.name = ngx_str_t{ .len = name.len, .data = name.data };
        }
    }

    return true;
}

// ============================================================================
// PKCE Support
// ============================================================================

fn generateCodeChallenge(pool: [*c]ngx_pool_t, code_verifier: []const u8) ?ngx_str_t {
    // SHA256 hash of code_verifier using Zig's std.crypto
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(code_verifier, &hash, .{});

    // Base64url encode
    return base64urlEncode(pool, &hash);
}

// ============================================================================
// Authorization Redirect
// ============================================================================

fn ensureOidcMetadataReady(lccf: *oidc_loc_conf) bool {
    if (lccf.discovery_url.len == 0 or lccf.client_id.len == 0 or lccf.redirect_uri.len == 0 or lccf.cookie_secret.len == 0) {
        return false;
    }

    return loadDiscoveryMetadata(lccf, false);
}

fn sendRedirect(r: [*c]ngx_http_request_t, location: ngx_str_t) ngx_int_t {
    // Add Location header to headers_out list and set location pointer
    var headers = NList(ngx_table_elt_t).init0(&r.*.headers_out.headers);
    const h = headers.append() catch return NGX_ERROR;
    h.*.hash = 1;
    h.*.key = ngx_string("Location");
    h.*.value = location;
    h.*.lowcase_key = @constCast("location");
    r.*.headers_out.location = h;

    // Return 302 - nginx will generate the response
    return @intCast(NGX_HTTP_MOVED_TEMPORARILY);
}

fn buildAuthorizationUrl(
    r: [*c]ngx_http_request_t,
    lccf: *oidc_loc_conf,
    state: ngx_str_t,
    nonce: ngx_str_t,
    code_challenge: ?ngx_str_t,
) ?ngx_str_t {
    // Build URL: authorization_endpoint?response_type=code&client_id=...
    const endpoint = if (lccf.authorization_endpoint.len > 0)
        lccf.authorization_endpoint
    else
        return null; // Need discovery or explicit config

    const scope = if (lccf.scope.len > 0) lccf.scope else ngx_string("openid profile email");

    // Calculate total URL length (generous estimate)
    const url_len = endpoint.len + 512 + lccf.client_id.len + lccf.redirect_uri.len + scope.len;
    const url_buf = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, url_len)) orelse return null;

    var offset: usize = 0;

    // Copy endpoint
    @memcpy(url_buf[offset..][0..endpoint.len], core.slicify(u8, endpoint.data, endpoint.len));
    offset += endpoint.len;

    // Add query separator
    url_buf[offset] = '?';
    offset += 1;

    // response_type=code
    const rt = "response_type=code&";
    @memcpy(url_buf[offset..][0..rt.len], rt);
    offset += rt.len;

    // client_id
    const cid = "client_id=";
    @memcpy(url_buf[offset..][0..cid.len], cid);
    offset += cid.len;
    @memcpy(url_buf[offset..][0..lccf.client_id.len], core.slicify(u8, lccf.client_id.data, lccf.client_id.len));
    offset += lccf.client_id.len;
    url_buf[offset] = '&';
    offset += 1;

    // redirect_uri (URL encoded)
    const ruri = "redirect_uri=";
    @memcpy(url_buf[offset..][0..ruri.len], ruri);
    offset += ruri.len;
    const encoded_redirect = urlEncode(r.*.pool, core.slicify(u8, lccf.redirect_uri.data, lccf.redirect_uri.len)) orelse return null;
    @memcpy(url_buf[offset..][0..encoded_redirect.len], core.slicify(u8, encoded_redirect.data, encoded_redirect.len));
    offset += encoded_redirect.len;
    url_buf[offset] = '&';
    offset += 1;

    // scope
    const sc = "scope=";
    @memcpy(url_buf[offset..][0..sc.len], sc);
    offset += sc.len;
    const encoded_scope = urlEncode(r.*.pool, core.slicify(u8, scope.data, scope.len)) orelse return null;
    @memcpy(url_buf[offset..][0..encoded_scope.len], core.slicify(u8, encoded_scope.data, encoded_scope.len));
    offset += encoded_scope.len;
    url_buf[offset] = '&';
    offset += 1;

    // state
    const st = "state=";
    @memcpy(url_buf[offset..][0..st.len], st);
    offset += st.len;
    @memcpy(url_buf[offset..][0..state.len], core.slicify(u8, state.data, state.len));
    offset += state.len;
    url_buf[offset] = '&';
    offset += 1;

    // nonce
    const nc = "nonce=";
    @memcpy(url_buf[offset..][0..nc.len], nc);
    offset += nc.len;
    @memcpy(url_buf[offset..][0..nonce.len], core.slicify(u8, nonce.data, nonce.len));
    offset += nonce.len;

    // PKCE parameters
    if (code_challenge) |cc| {
        url_buf[offset] = '&';
        offset += 1;
        const ccm = "code_challenge=";
        @memcpy(url_buf[offset..][0..ccm.len], ccm);
        offset += ccm.len;
        @memcpy(url_buf[offset..][0..cc.len], core.slicify(u8, cc.data, cc.len));
        offset += cc.len;
        url_buf[offset] = '&';
        offset += 1;
        const ccm2 = "code_challenge_method=S256";
        @memcpy(url_buf[offset..][0..ccm2.len], ccm2);
        offset += ccm2.len;
    }

    return ngx_str_t{ .len = offset, .data = url_buf };
}

fn redirectToAuthorization(r: [*c]ngx_http_request_t, lccf: *oidc_loc_conf, rctx: *oidc_request_ctx) ngx_int_t {
    if (!ensureOidcMetadataReady(lccf)) {
        return sendError(r, 500, "OIDC discovery metadata unavailable");
    }

    // Generate state and nonce
    const state = generateRandomHex(r.*.pool, STATE_SIZE) orelse return NGX_ERROR;
    const nonce = generateRandomHex(r.*.pool, NONCE_SIZE) orelse return NGX_ERROR;

    // PKCE code_verifier and code_challenge
    var code_challenge: ?ngx_str_t = null;
    var code_verifier: ?ngx_str_t = null;

    if (lccf.use_pkce == 1) {
        code_verifier = generateRandomHex(r.*.pool, 32);
        if (code_verifier) |cv| {
            code_challenge = generateCodeChallenge(r.*.pool, core.slicify(u8, cv.data, cv.len));
        }
    }

    // Build authorization URL
    const auth_url = buildAuthorizationUrl(r, lccf, state, nonce, code_challenge) orelse return NGX_ERROR;

    // Store state cookie (encrypted with original URI)
    const original_uri = ngx_str_t{ .len = r.*.uri.len, .data = r.*.uri.data };
    _ = setStateCookie(r, lccf, rctx, state, nonce, code_verifier, original_uri);

    // Send 302 redirect
    return sendRedirect(r, auth_url);
}

fn setStateCookie(
    r: [*c]ngx_http_request_t,
    lccf: *oidc_loc_conf,
    rctx: *oidc_request_ctx,
    state: ngx_str_t,
    nonce: ngx_str_t,
    code_verifier: ?ngx_str_t,
    original_uri: ngx_str_t,
) bool {
    // Build state JSON with escaped string values
    var state_json_buf: [1280]u8 = undefined;
    const cv_slice = if (code_verifier) |cv| core.slicify(u8, cv.data, cv.len) else "";
    const state_slice = core.slicify(u8, state.data, state.len);
    const nonce_slice = core.slicify(u8, nonce.data, nonce.len);
    const uri_slice = core.slicify(u8, original_uri.data, original_uri.len);

    var offset: usize = 0;
    const prefix1 = "{\"state\":\"";
    @memcpy(state_json_buf[offset..][0..prefix1.len], prefix1);
    offset += prefix1.len;
    if (!appendJsonEscaped(&state_json_buf, &offset, state_slice)) return false;

    const prefix2 = "\",\"nonce\":\"";
    @memcpy(state_json_buf[offset..][0..prefix2.len], prefix2);
    offset += prefix2.len;
    if (!appendJsonEscaped(&state_json_buf, &offset, nonce_slice)) return false;

    const prefix3 = "\",\"cv\":\"";
    @memcpy(state_json_buf[offset..][0..prefix3.len], prefix3);
    offset += prefix3.len;
    if (!appendJsonEscaped(&state_json_buf, &offset, cv_slice)) return false;

    const prefix4 = "\",\"uri\":\"";
    @memcpy(state_json_buf[offset..][0..prefix4.len], prefix4);
    offset += prefix4.len;
    if (!appendJsonEscaped(&state_json_buf, &offset, uri_slice)) return false;

    const suffix = "\"}";
    @memcpy(state_json_buf[offset..][0..suffix.len], suffix);
    offset += suffix.len;

    const state_json = state_json_buf[0..offset];

    // Encrypt
    const encrypted = encryptSession(lccf, ngx_str_t{ .len = state_json.len, .data = @constCast(state_json.ptr) }, r.*.pool) orelse return false;

    // Set cookie
    const cookie_name = "oidc_state";
    return queueHttpCookie(r, rctx, cookie_name, encrypted, 300, true); // 5 min expiry
}

fn queueHttpCookie(
    r: [*c]ngx_http_request_t,
    rctx: *oidc_request_ctx,
    name: []const u8,
    value: ngx_str_t,
    max_age: i64,
    http_only: bool,
) bool {
    if (rctx.pending_cookie_count >= MAX_PENDING_COOKIES) {
        return false;
    }

    // Build Set-Cookie header value
    const cookie_len = name.len + 1 + value.len + 100; // Extra for attributes
    const cookie_buf = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, cookie_len)) orelse return false;

    var offset: usize = 0;

    // name=value
    @memcpy(cookie_buf[offset..][0..name.len], name);
    offset += name.len;
    cookie_buf[offset] = '=';
    offset += 1;

    // Handle empty value (for cookie deletion)
    if (value.len > 0 and value.data != core.nullptr(u8)) {
        @memcpy(cookie_buf[offset..][0..value.len], core.slicify(u8, value.data, value.len));
        offset += value.len;
    }

    // ; Path=/
    const path = "; Path=/";
    @memcpy(cookie_buf[offset..][0..path.len], path);
    offset += path.len;

    // ; Max-Age=
    var age_buf: [32]u8 = undefined;
    const age_str = std.fmt.bufPrint(&age_buf, "; Max-Age={d}", .{max_age}) catch return false;
    @memcpy(cookie_buf[offset..][0..age_str.len], age_str);
    offset += age_str.len;

    if (http_only) {
        const ho = "; HttpOnly";
        @memcpy(cookie_buf[offset..][0..ho.len], ho);
        offset += ho.len;
    }

    // ; SameSite=Lax
    const ss = "; SameSite=Lax";
    @memcpy(cookie_buf[offset..][0..ss.len], ss);
    offset += ss.len;

    rctx.pending_cookies[rctx.pending_cookie_count] = ngx_str_t{ .len = offset, .data = cookie_buf };
    rctx.pending_cookie_count += 1;
    return true;
}

// ============================================================================
// Host parsing for upstream
// ============================================================================

const Host = struct {
    host: ngx_str_t,
    port: u16,
    ssl: bool,
    path: ngx_str_t,
};

fn get_port(p0: [*c]u8, p1: [*c]u8) ?u16 {
    var d: usize = 0;
    var p: [*c]u8 = p0 + 1;
    while (@intFromPtr(p) < @intFromPtr(p1)) : (p += 1) {
        if (p.* >= '0' and p.* <= '9') {
            d = d * 10 + p.* - '0';
            continue;
        }
        if (p.* == '/') {
            break;
        }
        return null;
    }
    return if (d > 65535 or d == 0) null else @as(u16, @intCast(d));
}

fn get_host(url: ngx_str_t) Host {
    var h = Host{
        .host = url,
        .port = 80,
        .ssl = false,
        .path = ngx_string("/"),
    };

    const url_slice = core.slicify(u8, url.data, url.len);

    // Parse protocol
    var start_idx: usize = 0;
    if (url.len > 7 and std.mem.eql(u8, url_slice[0..7], "http://")) {
        start_idx = 7;
        h.port = 80;
    } else if (url.len > 8 and std.mem.eql(u8, url_slice[0..8], "https://")) {
        start_idx = 8;
        h.port = 443;
        h.ssl = true;
    }

    // Find port or path
    var host_end: usize = url.len;
    var path_start: usize = url.len;
    var i: usize = start_idx;
    while (i < url.len) : (i += 1) {
        if (url_slice[i] == ':') {
            host_end = i;
            // Parse port
            if (get_port(url.data + i, url.data + url.len)) |port| {
                h.port = port;
            }
        } else if (url_slice[i] == '/') {
            if (host_end == url.len) {
                host_end = i;
            }
            path_start = i;
            break;
        }
    }

    h.host = ngx_str_t{
        .data = url.data + start_idx,
        .len = host_end - start_idx,
    };

    if (path_start < url.len) {
        h.path = ngx_str_t{
            .data = url.data + path_start,
            .len = url.len - path_start,
        };
    }

    return h;
}

// ============================================================================
// Token Exchange Upstream
// ============================================================================

fn build_token_request(
    r: [*c]ngx_http_request_t,
    rctx: [*c]oidc_request_ctx,
) ?ngx_str_t {
    const lccf = rctx.*.lccf;
    const host = get_host(lccf.*.token_endpoint);

    // Build POST body
    const body_max_len: usize = 2048;
    const body_buf = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, body_max_len)) orelse return null;

    var write: [*c]u8 = body_buf;
    write = ngx_sprintf(write, "grant_type=authorization_code&");
    write = ngx_sprintf(write, "code=%V&", &rctx.*.state); // state holds the code during token exchange
    write = ngx_sprintf(write, "redirect_uri=");

    // URL encode redirect_uri
    const redirect_encoded = urlEncode(r.*.pool, core.slicify(u8, lccf.*.redirect_uri.data, lccf.*.redirect_uri.len)) orelse return null;
    write = ngx_sprintf(write, "%V&", &redirect_encoded);

    write = ngx_sprintf(write, "client_id=%V", &lccf.*.client_id);

    // Add client_secret if configured
    if (lccf.*.client_secret.len > 0) {
        write = ngx_sprintf(write, "&client_secret=%V", &lccf.*.client_secret);
    }

    // Add code_verifier for PKCE
    if (rctx.*.code_verifier.len > 0) {
        write = ngx_sprintf(write, "&code_verifier=%V", &rctx.*.code_verifier);
    }

    const body_len = core.ngz_len(body_buf, write);

    // Build HTTP request
    const req_max_len: usize = body_len + 512;
    const req_buf = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, req_max_len)) orelse return null;

    write = req_buf;
    write = ngx_sprintf(write, "POST %V HTTP/1.1\r\n", &host.path);
    write = ngx_sprintf(write, "Host: %V\r\n", &host.host);
    write = ngx_sprintf(write, "Content-Type: application/x-www-form-urlencoded\r\n");
    write = ngx_sprintf(write, "Content-Length: %d\r\n", body_len);
    write = ngx_sprintf(write, "Connection: close\r\n");
    write = ngx_sprintf(write, "\r\n");

    // Append body
    @memcpy(write[0..body_len], body_buf[0..body_len]);
    write += body_len;

    const req_len = core.ngz_len(req_buf, write);
    return ngx_str_t{ .len = req_len, .data = req_buf };
}

fn oidc_upstream_create_request(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const rctx = core.castPtr(
        oidc_request_ctx,
        r.*.ctx[ngx_http_oidc_module.ctx_index],
    ) orelse return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

    const req = build_token_request(r, rctx) orelse return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

    var chain = NChain.init(r.*.pool);
    var out = ngx_chain_t{
        .buf = core.nullptr(ngx_buf_t),
        .next = core.nullptr(ngx_chain_t),
    };
    const last = chain.allocStr(req, &out) catch return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

    rctx.*.token_state = .PENDING;
    if (r.*.upstream.*.request_bufs == core.nullptr(ngx_chain_t)) {
        last.*.buf.*.flags.last_buf = true;
        last.*.buf.*.flags.last_in_chain = true;
    }
    last.*.next = r.*.upstream.*.request_bufs;
    r.*.upstream.*.request_bufs = last;

    r.*.upstream.*.flags.header_sent = false;
    r.*.upstream.*.flags.request_sent = false;
    r.*.header_hash = 1;

    return NGX_OK;
}

fn oidc_upstream_process_status(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const rctx = core.castPtr(
        oidc_request_ctx,
        r.*.ctx[ngx_http_oidc_module.ctx_index],
    ) orelse return NGX_ERROR;

    const u = r.*.upstream;
    const rc = http.ngx_http_parse_status_line(r, &u.*.buffer, &rctx.*.http_status);

    if (rc == NGX_AGAIN) return rc;
    if (rc == NGX_ERROR) return rc;

    if (u.*.state != core.nullptr(http.ngx_http_upstream_state_t) and u.*.state.*.status == 0) {
        u.*.state.*.status = rctx.*.http_status.code;
    }

    u.*.headers_in.status_n = rctx.*.http_status.code;
    const len = core.ngz_len(rctx.*.http_status.start, rctx.*.http_status.end);
    u.*.headers_in.status_line.len = len;

    if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, len))) |data| {
        core.ngz_memcpy(data, rctx.*.http_status.start, len);
        u.*.headers_in.status_line.data = data;

        // Initialize body reading state
        rctx.*.token_state = .READING_HEADERS;
        rctx.*.content_length = -1;
        rctx.*.body_received = 0;
        rctx.*.body_buf = core.nullptr(u8);
        rctx.*.body_capacity = 0;

        u.*.process_header = oidc_upstream_process_header;
        return oidc_upstream_process_header(r);
    }

    return NGX_ERROR;
}

fn oidc_upstream_process_header(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const rctx = core.castPtr(
        oidc_request_ctx,
        r.*.ctx[ngx_http_oidc_module.ctx_index],
    ) orelse return NGX_ERROR;

    const u = r.*.upstream;

    // Phase 1: Parse HTTP headers
    if (rctx.*.token_state == .READING_HEADERS) {
        while (true) {
            const rc = http.ngx_http_parse_header_line(r, &u.*.buffer, 1);
            switch (rc) {
                NGX_OK => {
                    // Check for Content-Length header
                    const key_slice = core.slicify(u8, r.*.header_name_start, core.ngz_len(r.*.header_name_start, r.*.header_name_end));
                    if (std.ascii.eqlIgnoreCase(key_slice, "content-length")) {
                        const val_slice = core.slicify(u8, r.*.header_start, core.ngz_len(r.*.header_start, r.*.header_end));
                        rctx.*.content_length = std.fmt.parseInt(isize, val_slice, 10) catch -1;
                    }
                    continue;
                },
                NGX_AGAIN => return rc,
                http.NGX_HTTP_PARSE_HEADER_DONE => {
                    // Headers done, start reading body
                    rctx.*.token_state = .READING_BODY;

                    // Allocate body buffer
                    const body_size: usize = if (rctx.*.content_length > 0)
                        @intCast(rctx.*.content_length)
                    else
                        4096; // Default buffer size

                    rctx.*.body_buf = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, body_size)) orelse return NGX_ERROR;
                    rctx.*.body_capacity = body_size;
                    rctx.*.body_received = 0;

                    // Check if there's body data already in the buffer
                    const remaining = core.ngz_len(u.*.buffer.pos, u.*.buffer.last);
                    if (remaining > 0) {
                        const to_copy = @min(remaining, rctx.*.body_capacity);
                        @memcpy(rctx.*.body_buf[0..to_copy], core.slicify(u8, u.*.buffer.pos, to_copy));
                        rctx.*.body_received = to_copy;
                        u.*.buffer.pos += to_copy;
                    }

                    // Check if we have the complete body
                    if (rctx.*.content_length >= 0 and rctx.*.body_received >= @as(usize, @intCast(rctx.*.content_length))) {
                        return process_token_response_and_setup_redirect(r, rctx);
                    }

                    // Need more data
                    return NGX_AGAIN;
                },
                else => return http.NGX_HTTP_UPSTREAM_INVALID_HEADER,
            }
        }
    }

    // Phase 2: Read body
    if (rctx.*.token_state == .READING_BODY) {
        // Read available data from buffer
        const available = core.ngz_len(u.*.buffer.pos, u.*.buffer.last);
        if (available > 0) {
            const space_left = rctx.*.body_capacity - rctx.*.body_received;
            const to_copy = @min(available, space_left);
            if (to_copy > 0) {
                @memcpy(rctx.*.body_buf[rctx.*.body_received..][0..to_copy], core.slicify(u8, u.*.buffer.pos, to_copy));
                rctx.*.body_received += to_copy;
                u.*.buffer.pos += to_copy;
            }
        }

        // Check if we have the complete body
        if (rctx.*.content_length >= 0 and rctx.*.body_received >= @as(usize, @intCast(rctx.*.content_length))) {
            return process_token_response_and_setup_redirect(r, rctx);
        }

        // Need more data
        return NGX_AGAIN;
    }

    return NGX_ERROR;
}

fn process_token_response_and_setup_redirect(r: [*c]ngx_http_request_t, rctx: [*c]oidc_request_ctx) ngx_int_t {
    const body = ngx_str_t{
        .data = rctx.*.body_buf,
        .len = rctx.*.body_received,
    };

    if (body.len == 0) {
        return setup_error_response(r, 502, "Empty token response");
    }

    // Parse JSON response
    var cj = CJSON.init(r.*.pool);
    const json = cj.decode(body) catch {
        return setup_error_response(r, 502, "Invalid token response JSON");
    };

    // Check for error in response
    if (CJSON.query(json, "$.error")) |_| {
        return setup_error_response(r, 400, "IdP returned error");
    }

    // Extract id_token
    const id_token_node = CJSON.query(json, "$.id_token") orelse {
        return setup_error_response(r, 502, "No id_token in response");
    };

    const id_token = CJSON.stringValue(id_token_node) orelse {
        return setup_error_response(r, 502, "Invalid id_token");
    };

    // Parse JWT and extract claims
    const claims = validateIdToken(r.*.pool, rctx.*.lccf, core.slicify(u8, id_token.data, id_token.len), rctx.*.nonce) orelse {
        return setup_error_response(r, 400, "Failed to validate id_token");
    };

    // Create session with real claims
    const session_created = createSessionFromClaims(r, rctx.*.lccf, rctx, claims);
    if (!session_created) {
        return setup_error_response(r, 500, "Failed to create session");
    }

    // Clear state cookie
    _ = queueHttpCookie(r, rctx, "oidc_state", ngx_str_t{ .len = 0, .data = core.nullptr(u8) }, 0, false);

    rctx.*.token_state = .SUCCESS;

    // Setup 302 redirect response - this will be sent when nginx calls send_header
    // Our header filter will add the session cookies
    //
    // IMPORTANT: We must set both status_n and status_line in u->headers_in
    // because ngx_http_upstream_send_response copies both to r->headers_out
    const u = r.*.upstream;
    u.*.headers_in.status_n = NGX_HTTP_MOVED_TEMPORARILY;
    u.*.headers_in.status_line = ngx_string("302 Moved Temporarily");
    u.*.headers_in.content_length_n = 0;
 
    r.*.headers_out.status = NGX_HTTP_MOVED_TEMPORARILY;
    r.*.headers_out.content_length_n = 0;

    // Add Location header to r->headers_out (this won't be overwritten)
    var headers = NList(ngx_table_elt_t).init0(&r.*.headers_out.headers);
    const h = headers.append() catch return NGX_ERROR;
    h.*.hash = 1;
    h.*.key = ngx_string("Location");
    h.*.value = rctx.*.original_uri;
    h.*.lowcase_key = @constCast("location");
    r.*.headers_out.location = h;

    // Return NGX_OK - nginx will now call send_header with our 302 response
    // Our header filter will add the session cookies
    return NGX_OK;
}

fn setup_error_response(r: [*c]ngx_http_request_t, status: ngx_uint_t, message: []const u8) ngx_int_t {
    const u = r.*.upstream;
    const data = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, message.len)) orelse return NGX_ERROR;
    @memcpy(core.slicify(u8, data, message.len), message);

    const status_line = switch (status) {
        400 => ngx_string("400 Bad Request"),
        500 => ngx_string("500 Internal Server Error"),
        502 => ngx_string("502 Bad Gateway"),
        else => ngx_string("500 Internal Server Error"),
    };

    u.*.buffer.pos = data;
    u.*.buffer.last = data + message.len;
    u.*.length = 0;
    u.*.headers_in.status_n = status;
    u.*.headers_in.status_line = status_line;
    u.*.headers_in.content_length_n = @intCast(message.len);
    r.*.headers_out.status = status;
    r.*.headers_out.content_type = ngx_string("text/plain");
    r.*.headers_out.content_type_len = 10;
    r.*.headers_out.content_length_n = @intCast(message.len);
    return NGX_OK;
}

fn oidc_upstream_input_filter_init(ctx: ?*anyopaque) callconv(.c) ngx_int_t {
    if (core.castPtr(ngx_http_request_t, ctx)) |r| {
        const u = r.*.upstream;
        u.*.length = u.*.headers_in.content_length_n;
    }
    return NGX_OK;
}

fn oidc_upstream_input_filter(ctx: ?*anyopaque, bytes: isize) callconv(.c) ngx_int_t {
    const r = core.castPtr(ngx_http_request_t, ctx) orelse return NGX_ERROR;
    const u = r.*.upstream;
    const b = &u.*.buffer;

    if (bytes > 0) {
        var ll: [*c][*c]ngx_chain_t = &u.*.out_bufs;
        while (ll.* != core.nullptr(ngx_chain_t)) {
            ll = &ll.*.*.next;
        }

        if (buf.ngx_chain_get_free_buf(r.*.pool, &u.*.free_bufs)) |cl| {
            cl.*.buf.*.flags.flush = true;
            cl.*.buf.*.flags.memory = true;

            const last = b.*.last;
            cl.*.buf.*.pos = last;
            b.*.last += @intCast(bytes);
            cl.*.buf.*.last = b.*.last;
            cl.*.buf.*.tag = u.*.output.tag;

            ll.* = cl;
        } else {
            return NGX_ERROR;
        }
    }

    if (u.*.length > 0) {
        u.*.length -= @min(u.*.length, bytes);
        if (u.*.length == 0) {
            u.*.flags.keepalive = true;
        }
    }

    return NGX_OK;
}

fn oidc_upstream_finalize_request(r: [*c]ngx_http_request_t, rc: ngx_int_t) callconv(.c) void {
    _ = rc;
    // Nothing to do here - we've already set up the response in process_header
    // The header filter added cookies, nginx sent the 302 response
    _ = r;
}

// ============================================================================
// JWT Parsing
// ============================================================================

const JWTClaims = struct {
    sub: ngx_str_t,
    email: ngx_str_t,
    name: ngx_str_t,
    iss: ngx_str_t,
    nonce: ngx_str_t,
    exp: i64,
    iat: i64,
};

const JWTHeader = struct {
    alg: ngx_str_t,
    kid: ngx_str_t,
};

fn parseIdTokenHeader(pool: [*c]ngx_pool_t, header_b64: []const u8) ?JWTHeader {
    const header_decoded = base64urlDecode(pool, header_b64) orelse return null;

    var cj = CJSON.init(pool);
    const json = cj.decode(header_decoded) catch return null;

    var header = JWTHeader{ .alg = ngx_null_str, .kid = ngx_null_str };

    if (CJSON.query(json, "$.alg")) |node| {
        if (CJSON.stringValue(node)) |v| header.alg = v;
    }
    if (CJSON.query(json, "$.kid")) |node| {
        if (CJSON.stringValue(node)) |v| header.kid = v;
    }

    if (header.alg.len == 0 or header.kid.len == 0) return null;
    return header;
}

fn parseIdTokenClaims(pool: [*c]ngx_pool_t, payload_b64: []const u8) ?JWTClaims {
    const payload_decoded = base64urlDecode(pool, payload_b64) orelse return null;

    var cj = CJSON.init(pool);
    const json = cj.decode(payload_decoded) catch return null;

    var claims = JWTClaims{
        .sub = ngx_null_str,
        .email = ngx_null_str,
        .name = ngx_null_str,
        .iss = ngx_null_str,
        .nonce = ngx_null_str,
        .exp = 0,
        .iat = 0,
    };

    if (CJSON.query(json, "$.sub")) |node| {
        if (CJSON.stringValue(node)) |v| claims.sub = v;
    }
    if (CJSON.query(json, "$.email")) |node| {
        if (CJSON.stringValue(node)) |v| claims.email = v;
    }
    if (CJSON.query(json, "$.name")) |node| {
        if (CJSON.stringValue(node)) |v| claims.name = v;
    }
    if (CJSON.query(json, "$.iss")) |node| {
        if (CJSON.stringValue(node)) |v| claims.iss = v;
    }
    if (CJSON.query(json, "$.nonce")) |node| {
        if (CJSON.stringValue(node)) |v| claims.nonce = v;
    }
    if (CJSON.query(json, "$.exp")) |node| {
        if (CJSON.intValue(node)) |v| claims.exp = v;
    }
    if (CJSON.query(json, "$.iat")) |node| {
        if (CJSON.intValue(node)) |v| claims.iat = v;
    }

    return claims;
}

fn payloadAudienceMatches(payload_json: [*c]cjson.cJSON, expected_aud: []const u8) bool {
    const aud_node = CJSON.query(payload_json, "$.aud") orelse return false;

    if (CJSON.stringValue(aud_node)) |aud| {
        return std.mem.eql(u8, core.slicify(u8, aud.data, aud.len), expected_aud);
    }

    if (CJSON.arrValue(aud_node)) |aud_arr| {
        var it = CJSON.Iterator.init(aud_arr);
        while (it.next()) |item| {
            if (CJSON.stringValue(item)) |aud| {
                if (std.mem.eql(u8, core.slicify(u8, aud.data, aud.len), expected_aud)) {
                    return true;
                }
            }
        }
    }

    return false;
}

fn validateIdToken(pool: [*c]ngx_pool_t, lccf: *oidc_loc_conf, token: []const u8, expected_nonce: ngx_str_t) ?JWTClaims {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    const rest = token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;

    const header_b64 = token[0..first_dot];
    const payload_b64 = rest[0..second_dot];
    const signature_b64 = rest[second_dot + 1 ..];
    if (signature_b64.len == 0) return null;

    const header = parseIdTokenHeader(pool, header_b64) orelse return null;
    const alg = core.slicify(u8, header.alg.data, header.alg.len);
    if (!std.mem.eql(u8, alg, "RS256")) return null;

    const kid = core.slicify(u8, header.kid.data, header.kid.len);
    const jwk = findJwksKey(lccf, kid, true) orelse return null;

    const signing_input = token[0 .. first_dot + 1 + second_dot];
    if (!verifyRs256Signature(pool, jwk, signing_input, signature_b64)) return null;

    const payload_decoded = base64urlDecode(pool, payload_b64) orelse return null;
    var cj = CJSON.init(pool);
    const payload_json = cj.decode(payload_decoded) catch return null;

    const claims = parseIdTokenClaims(pool, payload_b64) orelse return null;
    const now = time(null);

    if (claims.sub.len == 0 or claims.iss.len == 0 or claims.exp == 0) return null;
    if (claims.nonce.len == 0 or expected_nonce.len == 0) return null;

    const expected_iss = core.slicify(u8, lccf.issuer.data, lccf.issuer.len);
    const actual_iss = core.slicify(u8, claims.iss.data, claims.iss.len);
    if (!std.mem.eql(u8, actual_iss, expected_iss)) return null;

    const expected_aud = core.slicify(u8, lccf.client_id.data, lccf.client_id.len);
    if (!payloadAudienceMatches(payload_json, expected_aud)) return null;

    if (claims.exp + CLAIM_TIME_SKEW_SEC < now) return null;

    const expected_nonce_slice = core.slicify(u8, expected_nonce.data, expected_nonce.len);
    const actual_nonce = core.slicify(u8, claims.nonce.data, claims.nonce.len);
    if (!std.mem.eql(u8, actual_nonce, expected_nonce_slice)) return null;

    return claims;
}

fn createSessionFromClaims(r: [*c]ngx_http_request_t, lccf: [*c]oidc_loc_conf, rctx: [*c]oidc_request_ctx, claims: JWTClaims) bool {
    // Build session JSON with escaped string values
    var session_json_buf: [2048]u8 = undefined;

    const sub_slice = core.slicify(u8, claims.sub.data, claims.sub.len);
    const email_slice = if (claims.email.len > 0)
        core.slicify(u8, claims.email.data, claims.email.len)
    else
        "";
    const name_slice = if (claims.name.len > 0)
        core.slicify(u8, claims.name.data, claims.name.len)
    else
        "";

    // Use IdP's exp or default to 1 hour
    const exp_time: i64 = if (claims.exp > 0) claims.exp else time(null) + SESSION_DURATION_SEC;
    const iat_time: i64 = if (claims.iat > 0) claims.iat else time(null);

    var offset: usize = 0;
    const prefix1 = "{\"sub\":\"";
    @memcpy(session_json_buf[offset..][0..prefix1.len], prefix1);
    offset += prefix1.len;
    if (!appendJsonEscaped(&session_json_buf, &offset, sub_slice)) return false;

    const prefix2 = "\",\"email\":\"";
    @memcpy(session_json_buf[offset..][0..prefix2.len], prefix2);
    offset += prefix2.len;
    if (!appendJsonEscaped(&session_json_buf, &offset, email_slice)) return false;

    const prefix3 = "\",\"name\":\"";
    @memcpy(session_json_buf[offset..][0..prefix3.len], prefix3);
    offset += prefix3.len;
    if (!appendJsonEscaped(&session_json_buf, &offset, name_slice)) return false;

    const suffix = std.fmt.bufPrint(session_json_buf[offset..], "\",\"exp\":{d},\"iat\":{d}}}", .{
        exp_time,
        iat_time,
    }) catch return false;
    offset += suffix.len;

    const session_json = session_json_buf[0..offset];

    const encrypted_session = encryptSession(lccf, ngx_str_t{ .len = session_json.len, .data = @constCast(session_json.ptr) }, r.*.pool) orelse return false;

    const cookie_name = if (lccf.*.cookie_name.len > 0)
        core.slicify(u8, lccf.*.cookie_name.data, lccf.*.cookie_name.len)
    else
        "oidc_session";

    return queueHttpCookie(r, rctx, cookie_name, encrypted_session, SESSION_DURATION_SEC, true);
}

fn init_upstream_conf(ups: [*c]http.ngx_http_upstream_conf_t) void {
    ups.*.buffering = 0;
    ups.*.buffer_size = 32 * ngx_pagesize;
    ups.*.ssl_verify = 0;
    ups.*.connect_timeout = 60000;
    ups.*.send_timeout = 60000;
    ups.*.read_timeout = 60000;
    ups.*.module = ngx_string("ngx_http_oidc_module");
    ups.*.hide_headers = conf.NGX_CONF_UNSET_PTR;
    ups.*.pass_headers = conf.NGX_CONF_UNSET_PTR;
}

fn create_token_upstream(r: [*c]ngx_http_request_t, rctx: [*c]oidc_request_ctx) !ngx_int_t {
    if (http.ngx_http_upstream_create(r) != NGX_OK) {
        return error.UpstreamError;
    }

    const lccf = rctx.*.lccf;
    r.*.upstream.*.conf = &lccf.*.ups;
    r.*.upstream.*.flags.buffering = false;
    r.*.upstream.*.create_request = oidc_upstream_create_request;
    r.*.upstream.*.process_header = oidc_upstream_process_status;
    r.*.upstream.*.input_filter_init = oidc_upstream_input_filter_init;
    r.*.upstream.*.input_filter = oidc_upstream_input_filter;
    r.*.upstream.*.finalize_request = oidc_upstream_finalize_request;

    const host = get_host(lccf.*.token_endpoint);

    const resolved = core.ngz_pcalloc_c(http.ngx_http_upstream_resolved_t, r.*.pool) orelse return error.OOM;
    r.*.upstream.*.resolved = resolved;
    r.*.upstream.*.resolved.*.host = host.host;
    r.*.upstream.*.resolved.*.port = host.port;
    r.*.upstream.*.flags.ssl = host.ssl;
    r.*.upstream.*.resolved.*.naddrs = 1;

    const response_chain = core.ngz_pcalloc_c(ngx_chain_t, r.*.pool) orelse return error.OOM;
    rctx.*.token_response = response_chain;
    rctx.*.token_response.*.next = core.nullptr(ngx_chain_t);
    r.*.upstream.*.input_filter_ctx = r;

    http.ngx_http_upstream_init(r);

    return NGX_DONE;
}

// ============================================================================
// Callback Handler
// ============================================================================

fn isCallbackUri(r: [*c]ngx_http_request_t, lccf: *oidc_loc_conf) bool {
    if (lccf.redirect_uri.len == 0) return false;

    // Simple check: does the request URI match the path part of redirect_uri?
    // In production, this would be more robust
    const redirect_slice = core.slicify(u8, lccf.redirect_uri.data, lccf.redirect_uri.len);

    // Find path in redirect_uri (after host)
    if (std.mem.indexOf(u8, redirect_slice, "://")) |proto_end| {
        const after_proto = redirect_slice[proto_end + 3 ..];
        if (std.mem.indexOf(u8, after_proto, "/")) |path_start| {
            const redirect_path = after_proto[path_start..];
            const request_path = core.slicify(u8, r.*.uri.data, r.*.uri.len);
            return std.mem.eql(u8, redirect_path, request_path);
        }
    }

    return false;
}

fn handleCallback(r: [*c]ngx_http_request_t, lccf: *oidc_loc_conf, rctx: *oidc_request_ctx) ngx_int_t {
    if (!ensureOidcMetadataReady(lccf)) {
        return sendError(r, 500, "OIDC discovery metadata unavailable");
    }

    // Surface IdP callback errors before requiring an authorization code
    if (getQueryParam(r, "error")) |error_param| {
        const error_slice = core.slicify(u8, error_param.data, error_param.len);
        if (getQueryParam(r, "error_description")) |desc_param| {
            const desc_slice = core.slicify(u8, desc_param.data, desc_param.len);
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "OIDC error: {s} ({s})", .{ error_slice, desc_slice }) catch "OIDC callback error";
            return sendError(r, 400, msg);
        }

        var msg_buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "OIDC error: {s}", .{error_slice}) catch "OIDC callback error";
        return sendError(r, 400, msg);
    }

    // Get authorization code from query params
    const code = getQueryParam(r, "code") orelse {
        return sendError(r, 400, "Missing authorization code");
    };

    // Get state from query params
    const state_param = getQueryParam(r, "state") orelse {
        return sendError(r, 400, "Missing state parameter");
    };

    // Get and validate state cookie
    const state_cookie = findCookie(r, "oidc_state") orelse {
        return sendError(r, 400, "Missing state cookie");
    };

    // Decrypt state cookie
    const decrypted_state = decryptSession(lccf, state_cookie, r.*.pool) orelse {
        return sendError(r, 400, "Invalid state cookie");
    };

    // Parse state JSON
    var cj = CJSON.init(r.*.pool);
    const state_json = cj.decode(decrypted_state) catch {
        return sendError(r, 400, "Invalid state JSON");
    };

    // Verify state matches
    if (CJSON.query(state_json, "$.state")) |stored_state_node| {
        if (CJSON.stringValue(stored_state_node)) |stored_state| {
            const state_param_slice = core.slicify(u8, state_param.data, state_param.len);
            const stored_state_slice = core.slicify(u8, stored_state.data, stored_state.len);
            if (!std.mem.eql(u8, state_param_slice, stored_state_slice)) {
                return sendError(r, 400, "State mismatch");
            }
        }
    }

    // Get original URI
    var original_uri: ngx_str_t = ngx_string("/");
    if (CJSON.query(state_json, "$.uri")) |uri_node| {
        if (CJSON.stringValue(uri_node)) |uri| {
            original_uri = ngx_str_t{ .len = uri.len, .data = uri.data };
        }
    }

    // Get code_verifier for PKCE
    var code_verifier: ngx_str_t = ngx_null_str;
    if (CJSON.query(state_json, "$.cv")) |cv_node| {
        if (CJSON.stringValue(cv_node)) |cv| {
            code_verifier = cv;
        }
    }

    var nonce: ngx_str_t = ngx_null_str;
    if (CJSON.query(state_json, "$.nonce")) |nonce_node| {
        if (CJSON.stringValue(nonce_node)) |stored_nonce| {
            nonce = stored_nonce;
        }
    }

    if (nonce.len == 0) {
        return sendError(r, 400, "Missing nonce state");
    }

    // Store state for token exchange (reusing the state field to pass the code)
    rctx.*.state = code;
    rctx.*.nonce = nonce;
    rctx.*.code_verifier = code_verifier;
    rctx.*.original_uri = original_uri;
    rctx.*.lccf = lccf;

    // Check if token_endpoint is configured
    if (lccf.*.token_endpoint.len == 0) {
        return sendError(r, 500, "Token endpoint not configured");
    }

    // Initiate token exchange via upstream
    const rc = create_token_upstream(r, rctx) catch {
        return sendError(r, 500, "Failed to create upstream request");
    };

    return rc;
}

fn sendError(r: [*c]ngx_http_request_t, status: ngx_uint_t, message: []const u8) ngx_int_t {
    r.*.headers_out.status = status;
    r.*.headers_out.content_type = ngx_string("text/plain");
    r.*.headers_out.content_type_len = 10;
    r.*.headers_out.content_length_n = @intCast(message.len);

    const rc = http.ngx_http_send_header(r);
    if (rc == NGX_ERROR or rc > NGX_OK) {
        return rc;
    }

    // Create response body
    const b = core.castPtr(ngx_buf_t, core.ngx_pcalloc(r.*.pool, @sizeOf(ngx_buf_t))) orelse return NGX_ERROR;

    b.*.pos = @constCast(message.ptr);
    b.*.last = @constCast(message.ptr) + message.len;
    b.*.flags.memory = true;
    b.*.flags.last_buf = true;
    b.*.flags.last_in_chain = true;

    var out: ngx_chain_t = undefined;
    out.buf = b;
    out.next = null;

    return http.ngx_http_output_filter(r, &out);
}

// ============================================================================
// Access Phase Handler
// ============================================================================

export fn ngx_http_oidc_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        oidc_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_oidc_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) {
        return NGX_DECLINED;
    }

    // Get or create request context
    const rctx = http.ngz_http_get_module_ctx(
        oidc_request_ctx,
        r,
        &ngx_http_oidc_module,
    ) catch return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

    if (rctx.*.done == 1) {
        return NGX_DECLINED;
    }

    rctx.*.lccf = lccf;
    rctx.*.pending_cookie_count = 0;

    // Validate required config and discovery-backed metadata fail-closed.
    if (!ensureOidcMetadataReady(lccf)) {
        rctx.*.done = 1;
        return sendError(r, 500, oidcLastError());
    }

    // Check for valid session
    if (checkSession(r, lccf, rctx)) {
        rctx.*.done = 1;
        // Session valid - claims available via $oidc_claim_* variables
        return NGX_DECLINED;
    }

    // Check if this is the callback URI
    if (isCallbackUri(r, lccf)) {
        rctx.*.done = 1;
        return handleCallback(r, lccf, rctx);
    }

    // No session, not callback - redirect to authorization endpoint
    rctx.*.done = 1;
    return redirectToAuthorization(r, lccf, rctx);
}

// ============================================================================
// Header Filter
// ============================================================================

var ngx_http_oidc_next_header_filter: http.ngx_http_output_header_filter_pt = null;

fn getOidcCtx(r: [*c]ngx_http_request_t) ?[*c]oidc_request_ctx {
    return core.castPtr(oidc_request_ctx, r.*.ctx[ngx_http_oidc_module.ctx_index]);
}

export fn ngx_http_oidc_header_filter(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    if (getOidcCtx(r)) |rctx| {
        if (rctx.*.pending_cookie_count > 0) {
            var headers = NList(ngx_table_elt_t).init0(&r.*.headers_out.headers);
            var idx: usize = 0;
            while (idx < rctx.*.pending_cookie_count) : (idx += 1) {
                if (headers.append()) |h| {
                    h.*.hash = 1;
                    h.*.key = ngx_string("Set-Cookie");
                    h.*.value = rctx[0].pending_cookies[idx];
                    h.*.lowcase_key = @constCast("set-cookie");
                } else |_| {}
            }
            rctx.*.pending_cookie_count = 0;
        }
    }

    if (ngx_http_oidc_next_header_filter) |next| {
        return next(r);
    }
    return NGX_OK;
}

// ============================================================================
// Nginx Variable Handlers
// ============================================================================

// Variable getter for $oidc_claim_sub
fn ngx_http_oidc_variable_sub(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    return get_oidc_claim_variable(r, v, .sub);
}

// Variable getter for $oidc_claim_email
fn ngx_http_oidc_variable_email(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    return get_oidc_claim_variable(r, v, .email);
}

// Variable getter for $oidc_claim_name
fn ngx_http_oidc_variable_name(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    return get_oidc_claim_variable(r, v, .name);
}

const ClaimType = enum { sub, email, name };

fn get_oidc_claim_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    claim_type: ClaimType,
) ngx_int_t {
    // Get request context
    const rctx = core.castPtr(
        oidc_request_ctx,
        r.*.ctx[ngx_http_oidc_module.ctx_index],
    ) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };

    // Get the appropriate claim based on type
    const claim = switch (claim_type) {
        .sub => rctx.*.sub,
        .email => rctx.*.email,
        .name => rctx.*.name,
    };

    // Check if claim has a value
    if (claim.len == 0 or claim.data == core.nullptr(u8)) {
        v.*.flags.not_found = true;
        return NGX_OK;
    }

    // Set variable value
    v.*.data = claim.data;
    v.*.flags.len = @intCast(claim.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = false;
    v.*.flags.not_found = false;

    return NGX_OK;
}

// ============================================================================
// Configuration
// ============================================================================

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(oidc_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = conf.NGX_CONF_UNSET;
        p.*.use_pkce = conf.NGX_CONF_UNSET;
        p.*.discovery_url = ngx_null_str;
        p.*.client_id = ngx_null_str;
        p.*.client_secret = ngx_null_str;
        p.*.redirect_uri = ngx_null_str;
        p.*.scope = ngx_null_str;
        p.*.cookie_name = ngx_null_str;
        p.*.cookie_secret = ngx_null_str;
        p.*.issuer = ngx_null_str;
        p.*.authorization_endpoint = ngx_null_str;
        p.*.token_endpoint = ngx_null_str;
        p.*.jwks_uri = ngx_null_str;
        p.*.metadata_owned = 0;
        p.*.discovery_loaded_at = 0;
        p.*.jwks_loaded_at = 0;
        p.*.jwks_key_count = 0;
        p.*.aes = null;
        init_upstream_conf(&p.*.ups);
        return p;
    }
    return null;
}

fn merge_loc_conf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    const prev = core.castPtr(oidc_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(oidc_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.enabled == conf.NGX_CONF_UNSET) {
        c.*.enabled = if (prev.*.enabled == conf.NGX_CONF_UNSET) 0 else prev.*.enabled;
    }

    if (c.*.use_pkce == conf.NGX_CONF_UNSET) {
        c.*.use_pkce = if (prev.*.use_pkce == conf.NGX_CONF_UNSET) 1 else prev.*.use_pkce;
    }

    if (c.*.discovery_url.len == 0 and prev.*.discovery_url.len > 0) {
        c.*.discovery_url = prev.*.discovery_url;
    }

    if (c.*.client_id.len == 0 and prev.*.client_id.len > 0) {
        c.*.client_id = prev.*.client_id;
    }

    if (c.*.client_secret.len == 0 and prev.*.client_secret.len > 0) {
        c.*.client_secret = prev.*.client_secret;
    }

    if (c.*.redirect_uri.len == 0 and prev.*.redirect_uri.len > 0) {
        c.*.redirect_uri = prev.*.redirect_uri;
    }

    if (c.*.scope.len == 0 and prev.*.scope.len > 0) {
        c.*.scope = prev.*.scope;
    }

    if (c.*.cookie_name.len == 0 and prev.*.cookie_name.len > 0) {
        c.*.cookie_name = prev.*.cookie_name;
    }

    if (c.*.cookie_secret.len == 0 and prev.*.cookie_secret.len > 0) {
        c.*.cookie_secret = prev.*.cookie_secret;
    }

    c.*.issuer = ngx_null_str;
    c.*.authorization_endpoint = ngx_null_str;
    c.*.token_endpoint = ngx_null_str;
    c.*.jwks_uri = ngx_null_str;
    c.*.metadata_owned = 0;
    c.*.discovery_loaded_at = 0;
    c.*.jwks_loaded_at = 0;
    c.*.jwks_key_count = 0;

    // Initialize upstream hide headers hash
    var hash = ngx.hash.ngx_hash_init_t{
        .max_size = 100,
        .bucket_size = 1024,
        .name = @constCast("oidc_headers_hash"),
    };
    if (http.ngx_http_upstream_hide_headers_hash(
        cf,
        &c.*.ups,
        &prev.*.ups,
        @constCast(&oidc_hide_headers),
        &hash,
    ) != NGX_OK) {
        return conf.NGX_CONF_ERROR;
    }

    return conf.NGX_CONF_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    // Register nginx variables for OIDC claims
    const oidc_variables = [_]struct {
        name: ngx_str_t,
        handler: *const fn ([*c]ngx_http_request_t, [*c]ngx_http_variable_value_t, core.uintptr_t) callconv(.c) ngx_int_t,
    }{
        .{ .name = ngx_string("oidc_claim_sub"), .handler = ngx_http_oidc_variable_sub },
        .{ .name = ngx_string("oidc_claim_email"), .handler = ngx_http_oidc_variable_email },
        .{ .name = ngx_string("oidc_claim_name"), .handler = ngx_http_oidc_variable_name },
    };

    for (oidc_variables) |v| {
        var name = v.name;
        if (http.ngx_http_add_variable(cf, &name, http.NGX_HTTP_VAR_NOCACHEABLE)) |variable| {
            variable.*.get_handler = v.handler;
            variable.*.data = 0;
        }
    }

    // Register access phase handler
    const cmcf = core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    var handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_ACCESS_PHASE].handlers,
    );
    const h = handlers.append() catch return NGX_ERROR;
    h.* = ngx_http_oidc_handler;

    return NGX_OK;
}

fn postconfiguration_filter(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    _ = cf;
    ngx_http_oidc_next_header_filter = http.ngx_http_top_header_filter;
    http.ngx_http_top_header_filter = ngx_http_oidc_header_filter;
    return NGX_OK;
}

export const ngx_http_oidc_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_oidc_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("oidc"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_FLAG,
        .set = conf.ngx_conf_set_flag_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(oidc_loc_conf, "enabled"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("oidc_discovery"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(oidc_loc_conf, "discovery_url"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("oidc_client_id"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(oidc_loc_conf, "client_id"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("oidc_client_secret"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(oidc_loc_conf, "client_secret"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("oidc_redirect_uri"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(oidc_loc_conf, "redirect_uri"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("oidc_scope"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(oidc_loc_conf, "scope"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("oidc_cookie_name"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(oidc_loc_conf, "cookie_name"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("oidc_cookie_secret"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(oidc_loc_conf, "cookie_secret"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("oidc_pkce"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_FLAG,
        .set = conf.ngx_conf_set_flag_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(oidc_loc_conf, "use_pkce"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("oidc_authorization_endpoint"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(oidc_loc_conf, "authorization_endpoint"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("oidc_token_endpoint"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(oidc_loc_conf, "token_endpoint"),
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_oidc_module = ngx.module.make_module(
    @constCast(&ngx_http_oidc_commands),
    @constCast(&ngx_http_oidc_module_ctx),
);

export const ngx_http_oidc_filter_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration_filter,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = null,
    .merge_loc_conf = null,
};

export const ngx_http_oidc_filter_commands = [_]ngx_command_t{
    conf.ngx_null_command,
};

export var ngx_http_oidc_filter_module = ngx.module.make_module(
    @constCast(&ngx_http_oidc_filter_commands),
    @constCast(&ngx_http_oidc_filter_module_ctx),
);

// ============================================================================
// Tests
// ============================================================================

const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "oidc module" {
    try expect(ngx_http_oidc_module.version > 0);
}

test "hexToBytes" {
    var out: [4]u8 = undefined;
    try expect(hexToBytes("deadbeef", &out));
    try expectEqual(out[0], 0xde);
    try expectEqual(out[1], 0xad);
    try expectEqual(out[2], 0xbe);
    try expectEqual(out[3], 0xef);
}

test "hexToBytes invalid" {
    var out: [4]u8 = undefined;
    try expect(!hexToBytes("zzzzzzzz", &out));
    try expect(!hexToBytes("dead", &out)); // Wrong length
}
