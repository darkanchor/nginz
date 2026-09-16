const std = @import("std");
const ngx = @import("ngx");

const buf = ngx.buf;
const ssl = ngx.ssl;
const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const shm = ngx.shm;
const file = ngx.file;
const cjson = ngx.cjson;
const CJSON = cjson.CJSON;
const xpay = @import("xpay.zig");

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_AGAIN = core.NGX_AGAIN;
const NGX_DECLINED = core.NGX_DECLINED;
const NGX_CONF_ERROR = conf.NGX_CONF_ERROR;
const NGX_HTTP_SERVICE_UNAVAILABLE = http.NGX_HTTP_SERVICE_UNAVAILABLE;
const NGX_HTTP_INTERNAL_SERVER_ERROR = http.NGX_HTTP_INTERNAL_SERVER_ERROR;

const ngx_str_t = core.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_msec_t = core.ngx_msec_t;
const ngx_pool_t = core.ngx_pool_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_buf_t = ngx.buf.ngx_buf_t;
const ngx_event_t = core.ngx_event_t;
const ngx_chain_t = ngx.buf.ngx_chain_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_array_t = ngx.array.ngx_array_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_kayval_t = ngx.string.ngx_keyval_t;
const ngx_table_elt_t = ngx.hash.ngx_table_elt_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;

const ngx_string = ngx.string.ngx_string;
const ngx_sprintf = ngx.string.ngx_sprintf;
const NList = ngx.list.NList;
const NChain = ngx.buf.NChain;
const NArray = ngx.array.NArray;
const NSSL_RSA = ssl.NSSL_RSA;
const NSSL_AES_256_GCM = ssl.NSSL_AES_256_GCM;

const PAGE_SIZE = 4096;
const WECHATPAY_MAX_CLOCK_SKEW_SEC: i64 = 300;
const WECHATPAY_REPLAY_CAPACITY: usize = 1024;
const WECHATPAY_REPLAY_ZONE_SIZE: usize = 256 * 1024;
const WECHATPAY_DEFAULT_BODY_MAX_SIZE: usize = 1024 * 1024;
const NGX_HTTP_REQUEST_ENTITY_TOO_LARGE: ngx_int_t = 413;
const WECHATPAY_AUTH_HEADER = ngx_string("WECHATPAY2-SHA256-RSA2048");
extern var ngx_pagesize: ngx_uint_t;
extern var ngx_http_core_module: ngx_module_t;
extern var ngx_http_upstream_module: ngx_module_t;

const ReplayEntry = extern struct {
    nonce_len: u8,
    accepted_at: i64,
    nonce: [64]u8,
};

const ReplayStore = extern struct {
    next_index: usize,
    entries: [WECHATPAY_REPLAY_CAPACITY]ReplayEntry,
};

var wechatpay_replay_zone: [*c]core.ngx_shm_zone_t = core.nullptr(core.ngx_shm_zone_t);

fn replay_zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        zone.*.data = data;
        return NGX_OK;
    }
    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        zone.*.data = shpool.*.data;
        return NGX_OK;
    }
    const mem = shm.ngx_slab_calloc(shpool, @sizeOf(ReplayStore)) orelse return NGX_ERROR;
    const store = core.castPtr(ReplayStore, mem) orelse return NGX_ERROR;
    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

fn acceptFreshNonceInStore(store: *ReplayStore, nonce_value: []const u8, now: i64) bool {
    if (nonce_value.len == 0 or nonce_value.len > 64) return false;
    var reusable_index: ?usize = null;
    for (&store.entries) |*entry| {
        if (entry.nonce_len == nonce_value.len and entry.accepted_at >= now - WECHATPAY_MAX_CLOCK_SKEW_SEC and
            std.mem.eql(u8, entry.nonce[0..nonce_value.len], nonce_value)) return false;
    }

    var offset: usize = 0;
    while (offset < WECHATPAY_REPLAY_CAPACITY) : (offset += 1) {
        const index = (store.next_index + offset) % WECHATPAY_REPLAY_CAPACITY;
        const candidate = &store.entries[index];
        if (candidate.nonce_len == 0 or candidate.accepted_at < now - WECHATPAY_MAX_CLOCK_SKEW_SEC) {
            reusable_index = index;
            break;
        }
    }
    const index = reusable_index orelse return false;
    const entry = &store.entries[index];
    entry.* = std.mem.zeroes(ReplayEntry);
    entry.nonce_len = @intCast(nonce_value.len);
    entry.accepted_at = now;
    @memcpy(entry.nonce[0..nonce_value.len], nonce_value);
    store.next_index = (index + 1) % WECHATPAY_REPLAY_CAPACITY;
    return true;
}

fn acceptFreshNonce(zone_override: [*c]core.ngx_shm_zone_t, nonce_value: []const u8, now: i64) bool {
    const zone = if (zone_override != null) zone_override else wechatpay_replay_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.data == null or zone.*.shm.addr == null) return false;
    const store_c = core.castPtr(ReplayStore, zone.*.data) orelse return false;
    const store: *ReplayStore = @ptrCast(@alignCast(store_c));
    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return false;

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.*.mutex);
    return acceptFreshNonceInStore(store, nonce_value, now);
}

const WError = error{
    BODY_ERROR,
    HEADER_ERROR,
    COMMAND_ERROR,
    UPSTREAM_ERROR,
    SIGNATURE_ERROR,
};

const oaep_action = enum(ngx_uint_t) {
    OAEP_DECRYPT,
    OAEP_ENCRYPT,
    OAEP_NONE,
};

const signature_verification_status = enum(ngx_uint_t) {
    SIG_VERIFICATION_FAILED,
    SIG_VERIFICATION_SUCCESS,
    SIG_VERIFICATION_PENDDING,
    SIG_VERIFICATION_BYPASS,
};

const wechatpay_context = extern struct {
    rsa: [*c]NSSL_RSA,
    aes: [*c]NSSL_AES_256_GCM,
    action: oaep_action,
};

const wechatpay_request_context = extern struct {
    res: [*c]ngx_chain_t,
    lccf: [*c]wechatpay_loc_conf,
    sig_verify: signature_verification_status,
    status: http.ngx_http_status_t,
    done_access: ngx_flag_t,
    response_bytes: usize,
    prepared_headers: ngx_str_t,
    captured_request: ngx_str_t,
    captured_response: ngx_str_t,
    verified_notification: ngx_str_t,
    xpay_body: ngx_str_t,
    transport_complete: bool,
    chunked: http.ngx_http_chunked_t,
};

const wechatpay_loc_conf = extern struct {
    proxy: ngx_str_t,
    xpay_proxy: ngx_str_t,
    xpay_live_key: ngx_str_t,
    xpay_sandbox_key: ngx_str_t,
    xpay_access_token: [*c]http.ngx_http_complex_value_t,
    xpay_auth: ngx_str_t,
    xpay_env: ngx_int_t,
    audit_request: ngx_str_t,
    replay_zone: [*c]core.ngx_shm_zone_t,
    apiclient_key: ngx_str_t,
    apiclient_serial: ngx_str_t,
    wechatpay_public_key: ngx_str_t,
    wechatpay_serial: ngx_str_t,
    mch_id: ngx_str_t,
    aes_secret: ngx_str_t,
    access_control: ngx_flag_t,
    oaep_encrypt: ngx_flag_t,
    oaep_decrypt: ngx_flag_t,
    allow_insecure_http: ngx_flag_t,
    body_max_size: usize,
    ctx: [*c]wechatpay_context,
    ups: http.ngx_http_upstream_conf_t,
};

const wechatpay_hide_headers = [_]ngx_str_t{
    ngx.string.ngx_null_str,
};

const wechatpay_pass_headers = [_]ngx_str_t{
    ngx_string("Request-ID"),
    ngx_string("Wechatpay-Nonce"),
    ngx_string("Wechatpay-Signature"),
    ngx_string("Wechatpay-Timestamp"),
    ngx_string("Wechatpay-Serial"),
    ngx_string("Wechatpay-Signature-Type"),
    ngx.string.ngx_null_str,
};

fn init_upstream_conf(cf: [*c]http.ngx_http_upstream_conf_t) void {
    cf.*.buffering = 0;
    cf.*.buffer_size = 32 * ngx_pagesize;
    cf.*.ssl_verify = 1;
    cf.*.ssl_server_name = 1;
    cf.*.ssl_session_reuse = 1;
    cf.*.connect_timeout = 60000;
    cf.*.send_timeout = 60000;
    cf.*.read_timeout = 60000;
    cf.*.module = ngx_string("ngx_http_wechatpay_module");
    cf.*.hide_headers = conf.NGX_CONF_UNSET_PTR;
    cf.*.pass_headers = conf.NGX_CONF_UNSET_PTR;
}

fn ensure_upstream_tls(cf: [*c]ngx_conf_t, ups: [*c]http.ngx_http_upstream_conf_t) bool {
    if (ups.*.ssl == core.nullptr(ssl.ngx_ssl_t)) {
        ups.*.ssl = core.ngz_pcalloc_c(ssl.ngx_ssl_t, cf.*.pool) orelse return false;
    }
    return ssl.configure_verified_client(cf, ups.*.ssl);
}

fn init_wechatpay_context(
    cf: [*c]wechatpay_loc_conf,
    p: [*c]ngx_pool_t,
) ![*c]wechatpay_context {
    if (core.ngz_pcalloc_c(wechatpay_context, p)) |ctx| {
        if (core.ngz_pcalloc_c(NSSL_RSA, p)) |rsa| {
            rsa.* = try NSSL_RSA.init(cf.*.apiclient_key, cf.*.wechatpay_public_key);
            ctx.*.rsa = rsa;

            ctx.*.aes = core.nullptr(NSSL_AES_256_GCM);
            if (cf.*.aes_secret.len == NSSL_AES_256_GCM.KEY_SIZE) {
                if (core.ngz_pcalloc_c(NSSL_AES_256_GCM, p)) |aes| {
                    aes.* = try NSSL_AES_256_GCM.init(cf.*.aes_secret);
                    ctx.*.aes = aes;
                } else {
                    return core.NError.OOM;
                }
            }
            ctx.*.action = .OAEP_NONE;
            if (cf.*.oaep_encrypt == 1) {
                ctx.*.action = .OAEP_ENCRYPT;
            }
            if (cf.*.oaep_decrypt == 1) {
                ctx.*.action = .OAEP_DECRYPT;
            }
            return ctx;
        }
    }
    return core.NError.OOM;
}

fn deinit_wechatpay_context(ctx: [*c]wechatpay_context) void {
    ctx.*.rsa.*.deinit();
    if (ctx.*.aes != core.nullptr(NSSL_AES_256_GCM)) {
        ctx.*.aes.*.deinit();
    }
}

fn wechatpay_create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(wechatpay_loc_conf, cf.*.pool)) |p| {
        p.*.xpay_env = conf.NGX_CONF_UNSET;
        p.*.oaep_encrypt = conf.NGX_CONF_UNSET;
        p.*.oaep_decrypt = conf.NGX_CONF_UNSET;
        p.*.allow_insecure_http = conf.NGX_CONF_UNSET;
        p.*.body_max_size = conf.NGX_CONF_UNSET_SIZE;
        p.*.aes_secret = ngx.string.ngx_null_str;
        p.*.access_control = 0;

        init_upstream_conf(&p.*.ups);
        return p;
    }
    return null;
}

fn set_replay_zone(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, loc: ?*anyopaque) callconv(.c) [*c]u8 {
    _ = cmd;
    const config = core.castPtr(wechatpay_loc_conf, loc) orelse return NGX_CONF_ERROR;
    var index: ngx_uint_t = 1;
    const name = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &index) orelse return NGX_CONF_ERROR;
    const zone = shm.ngx_shared_memory_add(cf, name, WECHATPAY_REPLAY_ZONE_SIZE, @constCast(&ngx_http_wechatpay_module));
    if (zone == null) return NGX_CONF_ERROR;
    zone.*.init = replay_zone_init;
    config.*.replay_zone = zone;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_wechatpay_access(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(wechatpay_loc_conf, loc)) |lccf| {
        lccf.*.access_control = 1;
        var i: ngx_uint_t = 1;
        while (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            lccf.*.aes_secret = arg.*;
            break;
        }
    }
    return conf.NGX_CONF_OK;
}

fn config_assert(cf: [*c]ngx_conf_t, condition: bool, statement: []const u8) !void {
    if (!condition) {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_EMERG, cf.*.log, 0, statement.ptr, .{});
        return core.NError.CONF_ERROR;
    }
}

fn config_check(
    cf: [*c]ngx_conf_t,
    ch: [*c]wechatpay_loc_conf,
) [*c]u8 {
    const b0 = ssl.check_public_key(ch.*.wechatpay_public_key) catch false;
    config_assert(cf, b0, "invalid wechatpay public key") catch return NGX_CONF_ERROR;
    const b1 = ssl.check_private_key(ch.*.apiclient_key) catch false;
    config_assert(cf, b1, "invalid wechatpay apiclient key") catch return NGX_CONF_ERROR;
    config_assert(cf, ch.*.wechatpay_serial.len > 0, "invalid wechatpay serial") catch return NGX_CONF_ERROR;
    config_assert(cf, ch.*.apiclient_serial.len > 0, "invalid apiclient serial") catch return NGX_CONF_ERROR;
    config_assert(cf, ch.*.mch_id.len > 0, "invalid wechatpay mch_id") catch return NGX_CONF_ERROR;

    ch.*.ctx = init_wechatpay_context(ch, cf.*.pool) catch return NGX_CONF_ERROR;
    return conf.NGX_CONF_OK;
}

inline fn merge_loc(ch: [*c]wechatpay_loc_conf, pr: [*c]wechatpay_loc_conf) void {
    conf.ngx_conf_merge_str_value(&ch.*.xpay_live_key, &pr.*.xpay_live_key, ngx_string(""));
    conf.ngx_conf_merge_str_value(&ch.*.xpay_sandbox_key, &pr.*.xpay_sandbox_key, ngx_string(""));
    conf.ngx_conf_merge_str_value(&ch.*.xpay_auth, &pr.*.xpay_auth, ngx_string(""));
    if (ch.*.xpay_access_token == null) ch.*.xpay_access_token = pr.*.xpay_access_token;
    if (ch.*.xpay_env == conf.NGX_CONF_UNSET) ch.*.xpay_env = if (pr.*.xpay_env == conf.NGX_CONF_UNSET) 0 else pr.*.xpay_env;
    if (ch.*.replay_zone == null) ch.*.replay_zone = pr.*.replay_zone;
    conf.ngx_conf_merge_str_value(&ch.*.audit_request, &pr.*.audit_request, ngx_string(""));
    conf.ngx_conf_merge_str_value(&ch.*.apiclient_key, &pr.*.apiclient_key, ngx_string(""));
    conf.ngx_conf_merge_str_value(&ch.*.apiclient_serial, &pr.*.apiclient_serial, ngx_string(""));
    conf.ngx_conf_merge_str_value(&ch.*.wechatpay_public_key, &pr.*.wechatpay_public_key, ngx_string(""));
    conf.ngx_conf_merge_str_value(&ch.*.wechatpay_serial, &pr.*.wechatpay_serial, ngx_string(""));
    conf.ngx_conf_merge_str_value(&ch.*.mch_id, &pr.*.mch_id, ngx_string(""));
    if (ch.*.allow_insecure_http == conf.NGX_CONF_UNSET) {
        ch.*.allow_insecure_http = if (pr.*.allow_insecure_http == conf.NGX_CONF_UNSET) 0 else pr.*.allow_insecure_http;
    }
    if (ch.*.body_max_size == conf.NGX_CONF_UNSET_SIZE) {
        ch.*.body_max_size = if (pr.*.body_max_size == conf.NGX_CONF_UNSET_SIZE)
            WECHATPAY_DEFAULT_BODY_MAX_SIZE
        else
            pr.*.body_max_size;
    }
}

fn wechatpay_merge_loc_conf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    if (core.castPtr(wechatpay_loc_conf, parent)) |pr| {
        if (core.castPtr(wechatpay_loc_conf, child)) |ch| {
            merge_loc(ch, pr);
            var hash = ngx.hash.ngx_hash_init_t{
                .max_size = 100,
                .bucket_size = 1024,
                .name = @constCast("wechatpay_headers_hash"),
            };
            if (http.ngx_http_upstream_hide_headers_hash(
                cf,
                &ch.*.ups,
                &pr.*.ups,
                @constCast(&wechatpay_hide_headers),
                &hash,
            ) != NGX_OK) {
                return NGX_CONF_ERROR;
            }
            if (ch.*.ups.ssl == core.nullptr(ssl.ngx_ssl_t) and pr.*.ups.ssl != core.nullptr(ssl.ngx_ssl_t)) {
                ch.*.ups.ssl = pr.*.ups.ssl;
            }
            if (!ensure_upstream_tls(cf, &ch.*.ups)) return NGX_CONF_ERROR;
            if (ch.*.xpay_proxy.len > 0) {
                config_assert(cf, ch.*.proxy.len == 0 and ch.*.access_control == 0 and
                    ch.*.oaep_encrypt == conf.NGX_CONF_UNSET and ch.*.oaep_decrypt == conf.NGX_CONF_UNSET, "wechatpay XPay cannot be combined with v3 handlers") catch return NGX_CONF_ERROR;
                config_assert(cf, ch.*.xpay_access_token != null, "wechatpay XPay requires access_token") catch return NGX_CONF_ERROR;
                const auth = str_slice(ch.*.xpay_auth);
                config_assert(cf, std.mem.eql(u8, auth, "appkey") or std.mem.eql(u8, auth, "token"), "wechatpay_xpay_auth must be appkey or token") catch return NGX_CONF_ERROR;
                config_assert(cf, ch.*.xpay_env == 0 or ch.*.xpay_env == 1, "wechatpay_xpay_env must be 0 or 1") catch return NGX_CONF_ERROR;
                if (std.mem.eql(u8, auth, "appkey")) {
                    const key = if (ch.*.xpay_env == 0) ch.*.xpay_live_key else ch.*.xpay_sandbox_key;
                    config_assert(cf, key.len > 0, "wechatpay XPay selected AppKey is missing") catch return NGX_CONF_ERROR;
                }
                // No URI suffix, credentials or query in the configured origin.
                config_assert(cf, xpay.validOrigin(str_slice(ch.*.xpay_proxy)), "wechatpay_xpay_proxy_pass requires an http(s) origin without path or credentials") catch return NGX_CONF_ERROR;
                ch.*.ups.next_upstream_tries = 1;
                ch.*.ups.next_upstream = 0; // never replay a mutation
            }
            if (ch.*.proxy.len > 0 or ch.*.xpay_proxy.len > 0) {
                const proxy = str_slice(if (ch.*.xpay_proxy.len > 0) ch.*.xpay_proxy else ch.*.proxy);
                if (!std.mem.startsWith(u8, proxy, "https://") and
                    !(ch.*.allow_insecure_http == 1 and std.mem.startsWith(u8, proxy, "http://")))
                {
                    ngx.log.ngz_log_error(ngx.log.NGX_LOG_EMERG, cf.*.log, 0, "wechatpay_proxy_pass must use https unless wechatpay_allow_insecure_http is on", .{});
                    return NGX_CONF_ERROR;
                }
            }
            if (core.castPtr(
                http.ngx_http_core_loc_conf_t,
                conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
            )) |clcf| {
                if (ch.*.xpay_proxy.len > 0) {
                    clcf.*.handler = ngx_http_wechatpay_proxy_handler;
                    return conf.NGX_CONF_OK;
                }
                if (ch.*.proxy.len > 0) {
                    clcf.*.handler = ngx_http_wechatpay_proxy_handler;
                    return config_check(cf, ch);
                }
                if (ch.*.oaep_decrypt != conf.NGX_CONF_UNSET or
                    ch.*.oaep_encrypt != conf.NGX_CONF_UNSET)
                {
                    clcf.*.handler = ngx_http_wechatpay_oaep_handler;
                    return config_check(cf, ch);
                }
            }
            if (ch.*.access_control == 1) {
                return config_check(cf, ch);
            }
        }
    }
    return conf.NGX_CONF_OK;
}

fn nonce(p: [*c]ngx_pool_t) !ngx_str_t {
    var bf: [16]u8 = undefined;
    if (ssl.RAND_bytes(&bf, bf.len) != 1) {
        return WError.HEADER_ERROR;
    }
    if (core.castPtr(u8, core.ngx_pnalloc(p, bf.len * 2))) |b| {
        _ = ngx.string.ngx_hex_dump(b, &bf, bf.len);
        return ngx_str_t{ .data = b, .len = bf.len * 2 };
    }
    return core.NError.OOM;
}

fn timestamp(p: [*c]ngx_pool_t) !ngx_str_t {
    if (core.castPtr(u8, core.ngx_pnalloc(p, 16))) |b| {
        var t = core.ngx_time();
        var t0 = t;
        var len: usize = 0;
        while (t0 > 0) : (len += 1) {
            t0 = @divTrunc(t0, 10);
        }

        var i = len;
        while (i > 0) : (i -= 1) {
            b[i - 1] = '0' + @as(u8, @intCast(@mod(t, 10)));
            t = @divTrunc(t, 10);
        }
        return ngx_str_t{ .data = b, .len = len };
    }
    return core.NError.OOM;
}

fn read_body(r: [*c]ngx_http_request_t) ngx_str_t {
    const res: ngx_str_t = ngx.string.ngx_null_str;
    if (r.*.request_body == core.nullptr(http.ngx_http_request_body_t)) {
        return res;
    }
    if (r.*.request_body.*.bufs == core.nullptr(buf.ngx_chain_t)) {
        return res;
    }

    var total: usize = 0;
    var chain = r.*.request_body.*.bufs;
    while (chain != core.nullptr(buf.ngx_chain_t)) : (chain = chain.*.next) {
        const b = chain.*.buf;
        if (b == core.nullptr(buf.ngx_buf_t) or buf.ngx_buf_special(b)) continue;
        const chunk_len = buf.ngx_buf_size(b);
        if (chunk_len < 0) return res;
        total += @intCast(chunk_len);
    }
    if (total == 0) return res;

    const raw = core.ngx_pnalloc(r.*.pool, total) orelse return res;
    const out = core.castPtr(u8, raw) orelse return res;

    var offset: usize = 0;
    chain = r.*.request_body.*.bufs;
    while (chain != core.nullptr(buf.ngx_chain_t)) : (chain = chain.*.next) {
        const b = chain.*.buf;
        if (b == core.nullptr(buf.ngx_buf_t) or buf.ngx_buf_special(b)) continue;

        const chunk_len_off = buf.ngx_buf_size(b);
        if (chunk_len_off < 0) return res;
        const chunk_len: usize = @intCast(chunk_len_off);
        if (chunk_len == 0) continue;

        if (buf.ngx_buf_in_memory_only(b)) {
            @memcpy(out[offset .. offset + chunk_len], core.slicify(u8, b.*.pos, chunk_len));
            offset += chunk_len;
            continue;
        }

        if (b.*.flags.in_file and b.*.file != core.nullptr(file.ngx_file_t)) {
            const read_len = file.ngx_read_file(b.*.file, out + offset, chunk_len, b.*.file_pos);
            if (read_len == NGX_ERROR or @as(usize, @intCast(read_len)) != chunk_len) return res;
            offset += chunk_len;
            continue;
        }

        return res;
    }

    return ngx_str_t{ .data = out, .len = offset };
}

fn request_body_exceeds_limit(r: [*c]ngx_http_request_t, limit: usize) bool {
    if (r.*.headers_in.content_length_n > 0 and
        @as(u64, @intCast(r.*.headers_in.content_length_n)) > @as(u64, @intCast(limit))) return true;
    if (r.*.request_body == core.nullptr(http.ngx_http_request_body_t) or
        r.*.request_body.*.bufs == core.nullptr(buf.ngx_chain_t)) return false;

    var total: usize = 0;
    var chain = r.*.request_body.*.bufs;
    while (chain != core.nullptr(buf.ngx_chain_t)) : (chain = chain.*.next) {
        const b = chain.*.buf;
        if (b == core.nullptr(buf.ngx_buf_t) or buf.ngx_buf_special(b)) continue;
        const chunk_len = buf.ngx_buf_size(b);
        if (chunk_len < 0) return true;
        total = std.math.add(usize, total, @intCast(chunk_len)) catch return true;
        if (total > limit) return true;
    }
    return false;
}

fn sign_request(
    lccf: [*c]wechatpay_loc_conf,
    r: [*c]ngx_http_request_t,
    data: [*c]u8,
) !ngx_str_t {
    const nstr = try nonce(r.*.pool);
    const tstr = try timestamp(r.*.pool);
    var write: [*c]u8 = data;
    write = ngx_sprintf(write, "%V\n", &r.*.method_name);
    write = ngx_sprintf(write, "%V", &r.*.uri);
    if (r.*.args.len > 0) write = ngx_sprintf(write, "?%V", &r.*.args);
    write = ngx_sprintf(write, "\n");
    write = ngx_sprintf(write, "%V\n", &tstr);
    write = ngx_sprintf(write, "%V\n", &nstr);
    const body = read_body(r);
    write = ngx_sprintf(write, "%V\n", &body);
    var len = core.ngz_len(data, write);

    const rsa = lccf.*.ctx.*.rsa;
    const signed = try rsa.*.sign_sha256(ngx_str_t{ .data = data, .len = len }, r.*.pool);

    write = data;
    write = ngx_sprintf(write, "Authorization: %V ", &WECHATPAY_AUTH_HEADER);
    write = ngx_sprintf(write, "mchid=\"%V\",", &lccf.*.mch_id);
    write = ngx_sprintf(write, "serial_no=\"%V\",", &lccf.*.apiclient_serial);
    write = ngx_sprintf(write, "nonce_str=\"%V\",", &nstr);
    write = ngx_sprintf(write, "timestamp=\"%V\",", &tstr);
    write = ngx_sprintf(write, "signature=\"%V\"\r\n", &signed);
    len = core.ngz_len(data, write);
    return ngx.string.ngx_string_from_pool(data, len, r.*.pool);
}

fn build_request(
    lccf: [*c]wechatpay_loc_conf,
    r: [*c]ngx_http_request_t,
) !ngx_str_t {
    const body = read_body(r);
    const content_length: usize = 2048 + body.len + r.*.uri.len + r.*.args.len;
    if (core.castPtr(
        u8,
        core.ngx_pmemalign(
            r.*.pool,
            core.ngx_align(content_length, PAGE_SIZE),
            core.NGX_ALIGNMENT,
        ),
    )) |data| {
        defer _ = core.ngx_pfree(r.*.pool, data);

        const sign = try sign_request(lccf, r, data);
        var write: [*c]u8 = data;
        write = ngx_sprintf(write, "%V %V", &r.*.method_name, &r.*.uri);
        if (r.*.args.len > 0) write = ngx_sprintf(write, "?%V", &r.*.args);
        const provider = get_host(lccf.*.proxy);
        write = ngx_sprintf(write, " HTTP/1.1\r\nHost: %V", &provider.host);
        if ((provider.ssl and provider.port != 443) or (!provider.ssl and provider.port != 80)) {
            write = ngx_sprintf(write, ":%ui", @as(ngx_uint_t, provider.port));
        }
        write = ngx_sprintf(write, "\r\nContent-Type: application/json\r\nAccept: application/json\r\nUser-Agent: nginz-wechatpay/1.0\r\nContent-Length: %uz\r\nConnection: close\r\n", body.len);
        // Select the configured verification key, including public-key mode
        // while the merchant is migrating away from platform certificates.
        write = ngx_sprintf(write, "Wechatpay-Serial: %V\r\n", &lccf.*.wechatpay_serial);
        // A payment subrequest never forwards user JWTs, cookies, caller Host,
        // forged provider Authorization or any other main-request headers.
        write = ngx_sprintf(write, "%V\r\n", &sign);
        const len = core.ngz_len(data, write);
        return ngx.string.ngx_string_from_pool(data, len, r.*.pool);
    }
    return core.NError.OOM;
}

fn str_slice(value: ngx_str_t) []const u8 {
    return if (value.len == 0) "" else core.slicify(u8, value.data, value.len);
}

fn prepare_xpay_request(r: [*c]ngx_http_request_t, ctx: [*c]wechatpay_request_context) !void {
    const lc = ctx.*.lccf;
    const body = read_body(r);
    const env = try xpay.requestEnv(str_slice(body));
    if (env != lc.*.xpay_env) return error.InvalidRequest;
    var token: ngx_str_t = ngx.string.ngx_null_str;
    if (http.ngx_http_complex_value(r, lc.*.xpay_access_token, &token) != NGX_OK or token.len == 0 or token.len > 8192)
        return error.InvalidCredentials;
    const key = if (env == 0) lc.*.xpay_live_key else lc.*.xpay_sandbox_key;
    const signed = std.mem.eql(u8, str_slice(lc.*.xpay_auth), "appkey");
    if (signed and key.len == 0) return error.InvalidCredentials;
    const digest = xpay.sign(str_slice(key), str_slice(r.*.uri), str_slice(body));
    const hex = ngx_str_t{ .data = @constCast(&digest), .len = digest.len };
    const escaped_buf = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, token.len * 3)) orelse return error.OutOfMemory;
    const escaped = xpay.escapeToken(str_slice(token), escaped_buf[0 .. token.len * 3]);
    const escaped_token = ngx_str_t{ .data = escaped_buf, .len = escaped.len };
    const provider = get_host(lc.*.xpay_proxy);
    const capacity = 512 + r.*.uri.len + escaped.len + provider.host.len;
    const data = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, capacity)) orelse return error.OutOfMemory;
    var write = ngx_sprintf(data, "POST %V?access_token=%V", &r.*.uri, &escaped_token);
    if (signed) write = ngx_sprintf(write, "&pay_sig=%V", &hex);
    write = ngx_sprintf(write, " HTTP/1.1\r\nHost: %V", &provider.host);
    if ((provider.ssl and provider.port != 443) or (!provider.ssl and provider.port != 80)) {
        write = ngx_sprintf(write, ":%ui", @as(ngx_uint_t, provider.port));
    }
    write = ngx_sprintf(write, "\r\nContent-Type: application/json\r\nAccept: application/json\r\nUser-Agent: nginz-wechatpay/1.0\r\nContent-Length: %uz\r\nConnection: close\r\n\r\n", body.len);
    ctx.*.prepared_headers = .{ .data = data, .len = core.ngz_len(data, write) };
    ctx.*.xpay_body = body;

    // Audit the exact path/body, never the token-bearing request target.
    const audit = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, 256 + r.*.uri.len + body.len)) orelse return error.OutOfMemory;
    const end = ngx_sprintf(audit, "POST %V HTTP/1.1\r\nX-Wechatpay-Protocol: xpay\r\nX-Wechatpay-Auth: %V\r\nX-Wechatpay-Env: %i\r\nContent-Type: application/json\r\nContent-Length: %uz\r\n\r\n%V", &r.*.uri, &lc.*.xpay_auth, lc.*.xpay_env, body.len, &body);
    ctx.*.captured_request = .{ .data = audit, .len = core.ngz_len(audit, end) };
}

fn find_header(headers: [*c]NList(ngx_table_elt_t), name: ngx_str_t) !ngx_str_t {
    const key = ngx.hash.ngx_hash_key_lc(name.data, name.len);
    var it = headers.*.iterator();
    while (it.next()) |h| {
        if (h.*.hash == key) {
            return h.*.value;
        }
    }
    return WError.HEADER_ERROR;
}

fn verify_request(
    lccf: [*c]wechatpay_loc_conf,
    headers: [*c]NList(ngx_table_elt_t),
    body: ngx_str_t,
    pool: [*c]ngx_pool_t,
    data: [*c]u8,
) !bool {
    const w_serial = try find_header(headers, ngx_string("Wechatpay-Serial"));
    if (!ngx.string.eql(w_serial, lccf.*.wechatpay_serial)) {
        return false;
    }
    const w_nonce = try find_header(headers, ngx_string("Wechatpay-Nonce"));
    const w_timestamp = try find_header(headers, ngx_string("Wechatpay-Timestamp"));
    const w_signature = try find_header(headers, ngx_string("Wechatpay-Signature"));
    const timestamp_slice = core.slicify(u8, w_timestamp.data, w_timestamp.len);
    const signed_at = std.fmt.parseInt(i64, timestamp_slice, 10) catch return false;
    const now: i64 = @intCast(core.ngx_time());
    if (signed_at < now - WECHATPAY_MAX_CLOCK_SKEW_SEC or signed_at > now + WECHATPAY_MAX_CLOCK_SKEW_SEC) return false;
    if (w_nonce.len == 0 or w_nonce.len > 64 or w_signature.len == 0 or w_signature.len > 512) return false;
    var write: [*c]u8 = data;
    write = ngx_sprintf(write, "%V\n", &w_timestamp);
    write = ngx_sprintf(write, "%V\n", &w_nonce);
    write = ngx_sprintf(write, "%V\n", &body);
    const len = core.ngz_len(data, write);
    const rsa = lccf.*.ctx.*.rsa;
    if (!try rsa.*.verify_sha256(w_signature, ngx_str_t{ .data = data, .len = len }, pool)) return false;
    return acceptFreshNonce(lccf.*.replay_zone, core.slicify(u8, w_nonce.data, w_nonce.len), now);
}

fn send_header(r: [*c]ngx_http_request_t) ngx_int_t {
    if (r.*.headers_out.status == 0) r.*.headers_out.status = http.NGX_HTTP_OK;
    http.ngx_http_clear_content_length(r);
    http.ngx_http_clear_accept_ranges(r);

    return http.ngx_http_send_header(r);
}

fn send_body(r: [*c]ngx_http_request_t, chain: [*c]ngx_chain_t) ngx_int_t {
    if (r.*.flags1.header_only) {
        // auth_request subrequests: send headers (so status is readable) but no body.
        if (!r.*.flags1.header_sent) {
            const hrc = send_header(r);
            if (hrc == NGX_ERROR or hrc > NGX_OK) return hrc;
        }
        return http.ngx_http_send_special(r, http.NGX_HTTP_LAST);
    }
    if (!r.*.flags1.header_sent) {
        if (NGX_OK != send_header(r)) {
            return NGX_ERROR;
        }
    }

    if (chain != core.nullptr(ngx_chain_t)) {
        return http.ngx_http_output_filter(r, chain);
    } else {
        return http.ngx_http_send_special(r, http.NGX_HTTP_LAST);
    }
}

fn wechatpay_audit_variable(r: [*c]ngx_http_request_t, v: [*c]http.ngx_http_variable_value_t, data: core.uintptr_t) callconv(.c) ngx_int_t {
    const ctx = core.castPtr(wechatpay_request_context, r.*.ctx[ngx_http_wechatpay_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    const value = switch (data) {
        0 => ctx.*.captured_request,
        1 => ctx.*.captured_response,
        3 => ctx.*.verified_notification,
        4 => if (ctx.*.lccf != null and ctx.*.lccf.*.xpay_proxy.len > 0) ngx_string("xpay") else ngx_string("v3"),
        5 => if (ctx.*.transport_complete) ngx_string("complete") else ngx_string("incomplete"),
        else => if (ctx.*.sig_verify == .SIG_VERIFICATION_SUCCESS) ngx_string("success") else ngx_string("unverified"),
    };
    v.*.data = value.data;
    v.*.flags.len = @intCast(value.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn wechatpay_preconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    const names = [_][]const u8{ "wechatpay_request", "wechatpay_response", "wechatpay_verification", "wechatpay_notification", "wechatpay_protocol", "wechatpay_transport" };
    for (names, 0..) |name, index| {
        var key = ngx_str_t{ .data = @constCast(name.ptr), .len = name.len };
        const v = http.ngx_http_add_variable(cf, &key, http.NGX_HTTP_VAR_NOCACHEABLE) orelse return NGX_ERROR;
        v.*.get_handler = wechatpay_audit_variable;
        v.*.data = index;
    }
    ssl.SSL_LOG = cf.*.log;
    wechatpay_replay_zone = core.nullptr(core.ngx_shm_zone_t);
    return NGX_OK;
}

fn ngx_http_wechatpay_preaccess_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        wechatpay_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_wechatpay_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.access_control == 0) return NGX_DECLINED;
    if (r == r.*.main) return NGX_DECLINED;

    ngx.log.ngz_log_error(ngx.log.NGX_LOG_WARN, r.*.connection.*.log, 0, "wechatpay: subrequests are not supported on wechatpay-enabled locations", .{});
    return http.NGX_HTTP_FORBIDDEN;
}

fn wechatpay_postconfiguration(
    cf: [*c]ngx_conf_t,
) callconv(.c) ngx_int_t {
    var zone_name = ngx_string("wechatpay_replay_zone");
    const replay_zone = shm.ngx_shared_memory_add(cf, &zone_name, WECHATPAY_REPLAY_ZONE_SIZE, @constCast(&ngx_http_wechatpay_module));
    if (replay_zone == core.nullptr(core.ngx_shm_zone_t)) return NGX_ERROR;
    replay_zone.*.init = replay_zone_init;
    wechatpay_replay_zone = replay_zone;

    const cmcf = core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    var preaccess_handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_PREACCESS_PHASE].handlers,
    );
    const ph = preaccess_handlers.append() catch return NGX_ERROR;
    ph.* = ngx_http_wechatpay_preaccess_handler;

    var access_handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_ACCESS_PHASE].handlers,
    );
    const h = access_handlers.append() catch return NGX_ERROR;
    h.* = ngx_http_wechatpay_access_handler;

    return NGX_OK;
}

const Host = struct {
    host: ngx_str_t,
    port: u16,
    ssl: bool,
};

fn get_port(p0: [*c]u8, p1: [*c]u8) ?u16 {
    var d: usize = 0;
    var p: [*c]u8 = p0 + 1;
    while (p < p1) : (p += 1) {
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

fn get_host(host: ngx_str_t) Host {
    var h = Host{ .host = host, .port = 80, .ssl = false };
    var i: usize = @min(host.len, 6);
    while (i < host.len) : (i += 1) {
        if (host.data[i] == ':') {
            h.host = ngx.string.ngx_string_from_ptr(host.data, host.data + i);
            break;
        }
    }
    const port = get_port(host.data + i, host.data + host.len);
    h.port = port orelse 80;

    if (host.len > 7 and std.mem.eql(u8, core.slicify(u8, host.data, 7), "http://")) {
        h.host = ngx.string.ngx_string_from_ptr(host.data + 7, host.data + i);
        h.port = port orelse 80;
    }

    if (host.len > 8 and std.mem.eql(u8, core.slicify(u8, host.data, 8), "https://")) {
        h.host = ngx.string.ngx_string_from_ptr(host.data + 8, host.data + i);
        h.port = port orelse 443;
        h.ssl = true;
    }

    return h;
}

////////////////////////////  WECHATPAY UPSTREAM  //////////////////////////////////////////////////
fn ngx_http_wechatpay_proxy_upstream_create_request(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    if (core.castPtr(
        wechatpay_request_context,
        r.*.ctx[ngx_http_wechatpay_module.ctx_index],
    )) |rctx| {
        const req = if (rctx.*.prepared_headers.len > 0) rctx.*.prepared_headers else build_request(rctx.*.lccf, r) catch return NGX_HTTP_INTERNAL_SERVER_ERROR;
        var chain = NChain.init(r.*.pool);
        var out = buf.ngx_chain_t{
            .buf = core.nullptr(ngx_buf_t),
            .next = core.nullptr(ngx_chain_t),
        };
        const last = chain.allocStr(req, &out) catch return NGX_HTTP_INTERNAL_SERVER_ERROR;
        rctx.*.sig_verify = .SIG_VERIFICATION_PENDDING;
        if (r.*.upstream.*.request_bufs == core.nullptr(ngx_chain_t)) {
            last.*.buf.*.flags.last_buf = true;
            last.*.buf.*.flags.last_in_chain = true;
        }
        if (rctx.*.lccf.*.xpay_proxy.len > 0) {
            // Use the captured bytes, not mutable request/file buffers after audit.
            const body_chain = chain.allocStr(rctx.*.xpay_body, last) catch return NGX_ERROR;
            body_chain.*.buf.*.flags.last_buf = true;
            body_chain.*.buf.*.flags.last_in_chain = true;
        } else {
            last.*.next = r.*.upstream.*.request_bufs;
        }
        r.*.upstream.*.request_bufs = last;

        r.*.upstream.*.flags.header_sent = false;
        r.*.upstream.*.flags.request_sent = false;
        r.*.header_hash = 1;
    }
    return NGX_OK;
}

fn ngx_http_wechatpay_proxy_upstream_process_status(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    if (core.castPtr(
        wechatpay_request_context,
        r.*.ctx[ngx_http_wechatpay_module.ctx_index],
    )) |rctx| {
        const u = r.*.upstream;
        const rc = http.ngx_http_parse_status_line(r, &u.*.buffer, &rctx.*.status);
        if (rc == NGX_AGAIN) {
            return rc;
        }
        if (rc == NGX_ERROR) {
            return http.NGX_HTTP_UPSTREAM_INVALID_HEADER;
        }
        if (u.*.state != core.nullptr(http.ngx_http_upstream_state_t) and
            u.*.state.*.status == 0)
        {
            u.*.state.*.status = rctx.*.status.code;
        }
        u.*.headers_in.status_n = rctx.*.status.code;
        const len = core.ngz_len(rctx.*.status.start, rctx.*.status.end);
        u.*.headers_in.status_line.len = len;
        if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, len))) |data| {
            core.ngz_memcpy(data, rctx.*.status.start, len);
            u.*.headers_in.status_line.data = data;
            u.*.process_header = ngx_http_wechatpay_proxy_upstream_process_header;
            return ngx_http_wechatpay_proxy_upstream_process_header(r);
        }
    }
    return NGX_ERROR;
}

fn ngx_http_wechatpay_proxy_upstream_process_header(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    if (core.castPtr(
        http.ngx_http_upstream_main_conf_t,
        conf.ngx_http_get_module_main_conf(r, &ngx_http_upstream_module),
    )) |umcf| {
        const u = r.*.upstream;
        var headers = NList(ngx_table_elt_t).init0(&u.*.headers_in.headers);
        while (true) {
            const rc = http.ngx_http_parse_header_line(r, &u.*.buffer, 1);
            switch (rc) {
                NGX_OK => {
                    const h = headers.append() catch return NGX_ERROR;
                    if (http.ngz_set_upstream_header(
                        h,
                        r,
                        umcf,
                        &wechatpay_pass_headers,
                    ) != NGX_OK) {
                        return NGX_ERROR;
                    }
                    continue;
                },
                NGX_AGAIN => return rc,
                http.NGX_HTTP_PARSE_HEADER_DONE => {
                    if (u.*.headers_in.flags.chunked) {
                        u.*.headers_in.content_length_n = -1;
                    }
                    const rctx = core.castPtr(
                        wechatpay_request_context,
                        r.*.ctx[ngx_http_wechatpay_module.ctx_index],
                    ) orelse return NGX_ERROR;
                    if (u.*.headers_in.content_length_n > 0 and
                        @as(u64, @intCast(u.*.headers_in.content_length_n)) > @as(u64, @intCast(rctx.*.lccf.*.body_max_size)))
                    {
                        return http.NGX_HTTP_UPSTREAM_INVALID_HEADER;
                    }
                    return NGX_OK;
                },
                else => return http.NGX_HTTP_UPSTREAM_INVALID_HEADER,
            }
        }
    }
    return NGX_OK;
}

fn ngx_http_wechatpay_proxy_upstream_input_filter_init(
    ctx: ?*anyopaque,
) callconv(.c) ngx_int_t {
    if (core.castPtr(ngx_http_request_t, ctx)) |r| {
        const u = r.*.upstream;
        const rctx = core.castPtr(
            wechatpay_request_context,
            r.*.ctx[ngx_http_wechatpay_module.ctx_index],
        ) orelse return NGX_ERROR;
        rctx.*.response_bytes = 0;
        if (u.*.headers_in.content_length_n > 0 and
            @as(u64, @intCast(u.*.headers_in.content_length_n)) > @as(u64, @intCast(rctx.*.lccf.*.body_max_size)))
        {
            return NGX_ERROR;
        }
        u.*.length = if (u.*.headers_in.flags.chunked) 1 else u.*.headers_in.content_length_n;
        if (u.*.headers_in.status_n == 204 or u.*.headers_in.status_n == 304) u.*.length = 0;
    }
    return NGX_OK;
}

fn capture_response_chunk(r: [*c]ngx_http_request_t, ctx: [*c]wechatpay_request_context, data: [*c]u8, len: usize) !void {
    if (len == 0) return;
    ctx.*.response_bytes = try std.math.add(usize, ctx.*.response_bytes, len);
    if (ctx.*.response_bytes > ctx.*.lccf.*.body_max_size) return error.BodyTooLarge;
    var chain = NChain.init(r.*.pool);
    const last = buf.ngz_chain_last(ctx.*.res);
    const cl = try chain.alloc(len, last);
    core.ngz_memcpy(cl.*.buf.*.last, data, len);
    cl.*.buf.*.last += len;
}

// Returning NGX_ERROR from the input filter terminates the main request,
// including njs promises. Mark an upstream error so core finalizes with 502.
fn fail_upstream_input(r: [*c]ngx_http_request_t) ngx_int_t {
    r.*.upstream.*.flags.@"error" = true;
    r.*.upstream.*.length = 1;
    r.*.upstream.*.buffer.pos = r.*.upstream.*.buffer.last;
    return NGX_OK;
}

fn ngx_http_wechatpay_proxy_upstream_input_filter(
    ctx: ?*anyopaque,
    bytes: isize,
) callconv(.c) ngx_int_t {
    if (core.castPtr(ngx_http_request_t, ctx)) |r| {
        if (core.castPtr(
            wechatpay_request_context,
            r.*.ctx[ngx_http_wechatpay_module.ctx_index],
        )) |rctx| {
            const u = r.*.upstream;
            if (bytes < 0) return fail_upstream_input(r);
            const b = &u.*.buffer;
            b.*.pos = b.*.last;
            b.*.last += @intCast(bytes);
            if (u.*.headers_in.flags.chunked) {
                while (true) {
                    const rc = http.ngx_http_parse_chunked(r, b, &rctx.*.chunked, 0);
                    if (rc == NGX_OK) {
                        const len: usize = @min(core.ngz_len(b.*.pos, b.*.last), @as(usize, @intCast(rctx.*.chunked.size)));
                        capture_response_chunk(r, rctx, b.*.pos, len) catch return fail_upstream_input(r);
                        b.*.pos += len;
                        rctx.*.chunked.size -= @intCast(len);
                    } else if (rc == core.NGX_DONE) {
                        if (b.*.pos != b.*.last) return fail_upstream_input(r);
                        u.*.length = 0;
                        return NGX_OK;
                    } else if (rc == NGX_AGAIN) {
                        return NGX_OK;
                    } else return fail_upstream_input(r);
                }
            }
            const len: usize = @intCast(bytes);
            if (u.*.length >= 0 and bytes > u.*.length) return fail_upstream_input(r);
            capture_response_chunk(r, rctx, b.*.pos, len) catch return fail_upstream_input(r);
            b.*.pos = b.*.last;
            if (u.*.length >= 0) u.*.length -= bytes;
            return NGX_OK;
        }
    }
    return NGX_ERROR;
}

fn ngx_http_wechatpay_proxy_upstream_finalize_request(
    r: [*c]ngx_http_request_t,
    rc: ngx_int_t,
) callconv(.c) void {
    if (core.castPtr(
        wechatpay_request_context,
        r.*.ctx[ngx_http_wechatpay_module.ctx_index],
    )) |rctx| {
        if (rctx.*.res != core.nullptr(ngx_chain_t)) {
            rctx.*.captured_response = buf.ngz_chain_content(rctx.*.res, r.*.pool) catch ngx.string.ngx_null_str;
        }
        if (rc != NGX_OK) {
            // Transport/framing failures are gateway errors, not signature
            // failures. BYPASS prevents the header filter rewriting 502 to 401.
            rctx.*.sig_verify = .SIG_VERIFICATION_BYPASS;
            if (!r.*.flags1.header_sent) {
                r.*.headers_out.status = http.NGX_HTTP_BAD_GATEWAY;
                http.ngx_http_clear_content_length(r);
                http.ngx_http_clear_accept_ranges(r);
                _ = http.ngx_http_send_header(r);
                // Upstream core owns finalization after this callback. Tell it
                // that the gateway response has already been emitted.
                r.*.upstream.*.flags.header_sent = true;
                _ = http.ngx_http_send_special(r, http.NGX_HTTP_LAST);
            }
            return;
        }
        const u = r.*.upstream;
        rctx.*.transport_complete = !r.*.flags1.header_only;
        // XPay has no API v3 response signature. Release the complete HTTP
        // response unchanged; applications interpret errcode and order state.
        if (rctx.*.lccf.*.xpay_proxy.len > 0) {
            rctx.*.sig_verify = .SIG_VERIFICATION_BYPASS;
            r.*.headers_out.status = u.*.headers_in.status_n;
            const tail = buf.ngz_chain_last(rctx.*.res);
            if (tail != null and tail.*.buf != null) {
                tail.*.buf.*.flags.last_buf = r == r.*.main;
                tail.*.buf.*.flags.last_in_chain = true;
            }
            _ = send_body(r, rctx.*.res.*.next);
            return;
        }
        // For header_only subrequests (auth_request): nginx upstream skips body
        // reading so signature verification is impossible. Forward the upstream
        // HTTP status directly; the header filter leaves BYPASS alone.
        if (r.*.flags1.header_only) {
            rctx.*.sig_verify = .SIG_VERIFICATION_BYPASS;
            r.*.headers_out.status = u.*.headers_in.status_n;
            http.ngx_http_clear_content_length(r);
            http.ngx_http_clear_accept_ranges(r);
            _ = http.ngx_http_send_header(r);
            _ = http.ngx_http_send_special(r, http.NGX_HTTP_LAST);
            return;
        }
        var last: [*c]ngx_chain_t = core.nullptr(ngx_chain_t);
        rctx.*.sig_verify = .SIG_VERIFICATION_FAILED;
        last = buf.ngz_chain_last(rctx.*.res);
        const body = buf.ngz_chain_content(
            rctx.*.res,
            r.*.pool,
        ) catch ngx.string.ngx_null_str;

        {
            if (core.castPtr(u8, core.ngx_pmemalign(
                r.*.pool,
                core.ngx_align(body.len + 1024, PAGE_SIZE),
                core.NGX_ALIGNMENT,
            ))) |data| {
                defer _ = core.ngx_pfree(r.*.pool, data);
                var headers = NList(ngx_table_elt_t).init0(&u.*.headers_in.headers);
                const verify = verify_request(
                    rctx.*.lccf,
                    &headers,
                    body,
                    r.*.pool,
                    data,
                ) catch false;
                if (verify) {
                    rctx.*.sig_verify = .SIG_VERIFICATION_SUCCESS;
                }
            }
        }
        r.*.headers_out.status = u.*.headers_in.status_n;
        // send body explicitly
        if (last != core.nullptr(ngx_chain_t) and
            last.*.buf != core.nullptr(ngx_buf_t))
        {
            last.*.buf.*.flags.last_buf = (r == r.*.main);
            last.*.buf.*.flags.last_in_chain = true;
        }
        if (NGX_OK != send_body(r, rctx.*.res.*.next)) {
            ngx.log.ngz_log_error(
                ngx.log.NGX_LOG_WARN,
                r.*.connection.*.log,
                0,
                "wechatpay response failed",
                .{},
            );
        }
    }
}

fn create_upstream(
    r: [*c]ngx_http_request_t,
    rctx: [*c]wechatpay_request_context,
) !ngx_int_t {
    if (http.ngx_http_upstream_create(r) != NGX_OK) {
        return WError.UPSTREAM_ERROR;
    }

    const lccf: [*c]wechatpay_loc_conf = rctx.*.lccf;
    r.*.upstream.*.conf = &lccf.*.ups;
    r.*.upstream.*.flags.buffering = false;
    r.*.upstream.*.create_request = ngx_http_wechatpay_proxy_upstream_create_request;
    r.*.upstream.*.process_header = ngx_http_wechatpay_proxy_upstream_process_status;
    r.*.upstream.*.input_filter_init = ngx_http_wechatpay_proxy_upstream_input_filter_init;
    r.*.upstream.*.input_filter = ngx_http_wechatpay_proxy_upstream_input_filter;
    r.*.upstream.*.finalize_request = ngx_http_wechatpay_proxy_upstream_finalize_request;

    const host = get_host(if (lccf.*.xpay_proxy.len > 0) lccf.*.xpay_proxy else lccf.*.proxy);
    if (core.ngz_pcalloc_c(
        http.ngx_http_upstream_resolved_t,
        r.*.pool,
    )) |resolved| {
        r.*.upstream.*.resolved = resolved;
        r.*.upstream.*.resolved.*.host = host.host;
        r.*.upstream.*.resolved.*.port = host.port;
        r.*.upstream.*.flags.ssl = host.ssl;
        r.*.upstream.*.resolved.*.naddrs = 1;

        if (core.ngz_pcalloc_c(ngx_chain_t, r.*.pool)) |chain| {
            rctx.*.res = chain;
            rctx.*.res.*.next = core.nullptr(ngx_chain_t);
            r.*.upstream.*.input_filter_ctx = r;
            http.ngx_http_upstream_init(r);
            return core.NGX_DONE;
        }
    }

    return core.NError.OOM;
}

// Finish a suspended in-memory njs subrequest without routing an nginx HTML
// special response through its postponed body chain. There is no upstream yet.
fn reject_audited_request(r: [*c]ngx_http_request_t, status: ngx_uint_t) void {
    r.*.headers_out.status = status;
    // Resume after the background audit's finalizer unwinds. Completing the
    // njs payment sibling here re-enters its parent's promise/subrequest chain.
    r.*.write_event_handler = resume_audit_rejection;
    if (http.ngx_http_post_request(r, null) != NGX_OK) {
        http.ngx_http_finalize_request(r, NGX_ERROR);
    }
}

fn resume_audit_rejection(r: [*c]ngx_http_request_t) callconv(.c) void {
    r.*.headers_out.content_length_n = 0;
    const rc = http.ngx_http_send_header(r);
    const body_rc = if (rc == NGX_OK) http.ngx_http_send_special(r, http.NGX_HTTP_LAST) else rc;
    http.ngx_http_finalize_request(r, if (body_rc == NGX_ERROR) NGX_ERROR else NGX_OK);
}

// The configured internal audit handler commits the exact signed request
// before upstream_init can dispatch it. Its failure closes the payment path.
fn audit_request_done(sr: [*c]ngx_http_request_t, data: ?*anyopaque, rc: ngx_int_t) callconv(.c) ngx_int_t {
    const parent = core.castPtr(ngx_http_request_t, data) orelse return NGX_ERROR;
    const ctx = core.castPtr(wechatpay_request_context, parent.*.ctx[ngx_http_wechatpay_module.ctx_index]) orelse return NGX_ERROR;
    if (rc != NGX_OK or sr.*.headers_out.status < 200 or sr.*.headers_out.status >= 300) {
        reject_audited_request(parent, NGX_HTTP_SERVICE_UNAVAILABLE);
        return NGX_OK;
    }
    const result = create_upstream(parent, ctx) catch {
        reject_audited_request(parent, NGX_HTTP_INTERNAL_SERVER_ERROR);
        return NGX_OK;
    };
    if (result != core.NGX_DONE) http.ngx_http_finalize_request(parent, result);
    return NGX_OK;
}

export fn ngx_http_wechatpay_proxy_body_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) void {
    if (core.castPtr(
        wechatpay_request_context,
        r.*.ctx[ngx_http_wechatpay_module.ctx_index],
    )) |rctx| {
        if (request_body_exceeds_limit(r, rctx.*.lccf.*.body_max_size)) {
            http.ngx_http_finalize_request(r, NGX_HTTP_REQUEST_ENTITY_TOO_LARGE);
            return;
        }
        if (rctx.*.lccf.*.xpay_proxy.len > 0) {
            prepare_xpay_request(r, rctx) catch |err| {
                http.ngx_http_finalize_request(r, if (err == error.InvalidRequest) http.NGX_HTTP_BAD_REQUEST else NGX_HTTP_INTERNAL_SERVER_ERROR);
                return;
            };
        }
        if (rctx.*.lccf.*.audit_request.len > 0) {
            if (rctx.*.lccf.*.xpay_proxy.len == 0) {
                rctx.*.prepared_headers = build_request(rctx.*.lccf, r) catch {
                    http.ngx_http_finalize_request(r, NGX_HTTP_INTERNAL_SERVER_ERROR);
                    return;
                };
                const body = read_body(r);
                const size = rctx.*.prepared_headers.len + body.len;
                const raw = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, size)) orelse {
                    http.ngx_http_finalize_request(r, NGX_HTTP_INTERNAL_SERVER_ERROR);
                    return;
                };
                @memcpy(raw[0..rctx.*.prepared_headers.len], core.slicify(u8, rctx.*.prepared_headers.data, rctx.*.prepared_headers.len));
                @memcpy(raw[rctx.*.prepared_headers.len..][0..body.len], core.slicify(u8, body.data, body.len));
                rctx.*.captured_request = .{ .data = raw, .len = size };
            }
            const ps = core.ngz_pcalloc_c(http.ngx_http_post_subrequest_t, r.*.pool) orelse {
                http.ngx_http_finalize_request(r, NGX_HTTP_INTERNAL_SERVER_ERROR);
                return;
            };
            ps.*.handler = audit_request_done;
            ps.*.data = r;
            var sr: [*c]ngx_http_request_t = undefined;
            // njs captures this payment subrequest in memory. nginx forbids
            // children of an in-memory request, so attach the audit as a
            // background sibling under main. The callback retains the actual
            // payment request and starts it only after the audit commits.
            if (http.ngx_http_subrequest(r.*.main, &rctx.*.lccf.*.audit_request, null, &sr, ps, 4 | 16) != NGX_OK) {
                http.ngx_http_finalize_request(r, NGX_HTTP_SERVICE_UNAVAILABLE);
            } else {
                sr.*.flags1.header_only = true;
                sr.*.ctx[ngx_http_wechatpay_module.ctx_index] = rctx;
            }
            return;
        }
        const rc = create_upstream(r, rctx) catch {
            http.ngx_http_finalize_request(r, NGX_HTTP_INTERNAL_SERVER_ERROR);
            return;
        };
        if (rc != core.NGX_DONE) {
            http.ngx_http_finalize_request(r, rc);
        }
    } else {
        http.ngx_http_finalize_request(r, NGX_HTTP_SERVICE_UNAVAILABLE);
    }
}

export fn ngx_http_wechatpay_proxy_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    if (core.castPtr(
        wechatpay_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_wechatpay_module),
    )) |lccf| {
        if (lccf.*.xpay_proxy.len > 0) {
            if (r.*.method != http.NGX_HTTP_POST) return http.NGX_HTTP_NOT_ALLOWED;
            // All documented endpoint arguments belong in JSON. Reject queries
            // entirely, including encoded or duplicate authentication fields.
            if (r.*.args.len != 0 or !xpay.validPath(str_slice(r.*.uri))) return http.NGX_HTTP_BAD_REQUEST;
        }
        const rctx = http.ngz_http_get_module_ctx(
            wechatpay_request_context,
            r,
            &ngx_http_wechatpay_module,
        ) catch return NGX_HTTP_INTERNAL_SERVER_ERROR;
        if (rctx.*.lccf == core.nullptr(wechatpay_loc_conf)) {
            rctx.*.lccf = lccf;
        }
        if (request_body_exceeds_limit(r, lccf.*.body_max_size)) return NGX_HTTP_REQUEST_ENTITY_TOO_LARGE;
        r.*.flags1.discard_body = false;
        const rc = http.ngx_http_read_client_request_body(r, ngx_http_wechatpay_proxy_body_handler);
        return if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) rc else core.NGX_DONE;
    }
    return NGX_DECLINED;
}

//////////////////////////   WECHATPAY ACCESS //////////////////////////////////////////////////////

// if verified aes decrypt https://pay.weixin.qq.com/doc/v3/merchant/4012791902
fn aes_decode(
    r: [*c]ngx_http_request_t,
    body: ngx_str_t,
    aes: [*c]NSSL_AES_256_GCM,
    data: [*c]u8,
) !ngx_str_t {
    if (aes == core.nullptr(NSSL_AES_256_GCM)) {
        return body;
    }
    var cj = CJSON.init(r.*.pool);
    const json = try cj.decode(body);
    var it = CJSON.RecursiveIterator.init(json);
    while (it.next()) |j0| {
        if (CJSON.objValue(j0)) |j| {
            const ciphertext = CJSON.query(j, "$.ciphertext");
            const aad = CJSON.query(j, "$.associated_data");
            const iv = CJSON.query(j, "$.nonce");
            if (ciphertext != null and aad != null and iv != null) {
                const plaintxt = try aes.*.decrypt(
                    CJSON.stringValue(ciphertext.?).?,
                    CJSON.stringValue(iv.?).?,
                    CJSON.stringValue(aad.?).?,
                    r.*.pool,
                );
                var write: [*c]u8 = data;
                write = ngx_sprintf(write, "plaintxt");
                write.* = 0;
                write = ngx_sprintf(write + 1, "%V", &plaintxt);
                write.* = 0;

                if (cjson.cJSON_AddStringToObject(
                    j,
                    data,
                    data + 9,
                    &cj.alloc,
                ) == core.nullptr(cjson.cJSON)) {
                    return WError.BODY_ERROR;
                }
            }
        }
    }
    return cj.encode(json);
}

fn wechatpay_check_access(r: [*c]ngx_http_request_t) !ngx_int_t {
    if (core.castPtr(
        wechatpay_request_context,
        r.*.ctx[ngx_http_wechatpay_module.ctx_index],
    )) |rctx| {
        var content_length: usize = 1024;
        if (!r.*.flags1.discard_body and r.*.headers_in.content_length_n > 0) {
            content_length += @intCast(r.*.headers_in.content_length_n);
        }
        if (core.castPtr(u8, core.ngx_pmemalign(
            r.*.pool,
            core.ngx_align(content_length, PAGE_SIZE),
            core.NGX_ALIGNMENT,
        ))) |data| {
            defer _ = core.ngx_pfree(r.*.pool, data);

            const lccf = rctx.*.lccf;
            const mch_id = lccf.*.mch_id;
            // verify signature
            const body = read_body(r);
            var headers = NList(ngx_table_elt_t).init0(&r.*.headers_in.headers);
            const verify = verify_request(lccf, &headers, body, r.*.pool, data) catch false;
            if (!verify) {
                ngx.log.ngz_log_error(
                    ngx.log.NGX_LOG_WARN,
                    r.*.connection.*.log,
                    0,
                    "mch_id %V signature verification failed",
                    .{&mch_id},
                );
                return WError.SIGNATURE_ERROR;
            }

            const new_body = try aes_decode(r, body, lccf.*.ctx.*.aes, data);
            // njs may have cached the original body for an ACCESS audit. Expose
            // the authenticated, decrypted envelope separately from that cache.
            rctx.*.verified_notification = new_body;
            if (new_body.len > body.len) {
                var chain = NChain.init(r.*.pool);
                var out = buf.ngx_chain_t{
                    .buf = core.nullptr(ngx_buf_t),
                    .next = core.nullptr(ngx_chain_t),
                };
                const last = try chain.allocStr(new_body, &out);
                last.*.buf.*.flags.last_buf = (r == r.*.main);
                last.*.buf.*.flags.last_in_chain = true;
                r.*.request_body.*.bufs = last;
            }
            rctx.*.done_access = 1;
            return NGX_DECLINED;
        }
    }
    return http.NGX_HTTP_FORBIDDEN;
}

export fn ngx_http_wechatpay_access_body_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) void {
    const rctx = core.castPtr(
        wechatpay_request_context,
        r.*.ctx[ngx_http_wechatpay_module.ctx_index],
    ) orelse {
        http.ngx_http_finalize_request(r, NGX_HTTP_SERVICE_UNAVAILABLE);
        return;
    };
    if (request_body_exceeds_limit(r, rctx.*.lccf.*.body_max_size)) {
        http.ngx_http_finalize_request(r, NGX_HTTP_REQUEST_ENTITY_TOO_LARGE);
        return;
    }
    if (wechatpay_check_access(r)) |_| {
        r.*.write_event_handler = http.ngx_http_core_run_phases;
        http.ngx_http_core_run_phases(r);
    } else |e| {
        const rc = switch (e) {
            WError.SIGNATURE_ERROR => http.NGX_HTTP_UNAUTHORIZED,
            WError.BODY_ERROR => http.NGX_HTTP_BAD_REQUEST,
            else => http.NGX_HTTP_FORBIDDEN,
        };
        http.ngx_http_finalize_request(r, rc);
    }
}

export fn ngx_http_wechatpay_access_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    if (core.castPtr(
        wechatpay_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_wechatpay_module),
    )) |lccf| {
        if (lccf.*.access_control == 0) {
            return NGX_DECLINED;
        }
        const rctx = http.ngz_http_get_module_ctx(
            wechatpay_request_context,
            r,
            &ngx_http_wechatpay_module,
        ) catch return http.NGX_HTTP_FORBIDDEN;
        if (rctx.*.done_access == 1) {
            return NGX_DECLINED;
        }
        if (rctx.*.lccf == core.nullptr(wechatpay_loc_conf)) {
            rctx.*.lccf = lccf;
            rctx.*.done_access = 0;
        }
        if (request_body_exceeds_limit(r, lccf.*.body_max_size)) return NGX_HTTP_REQUEST_ENTITY_TOO_LARGE;
        r.*.flags1.discard_body = false;
        const rc = http.ngx_http_read_client_request_body(r, ngx_http_wechatpay_access_body_handler);
        if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) {
            return rc;
        }
        http.ngx_http_finalize_request(r, core.NGX_DONE);
        return core.NGX_DONE;
    }
    return NGX_DECLINED;
}

//////////////////////////     OAEP HANDLER   //////////////////////////////////////////////////////

fn execute_oaep_action(
    r: [*c]ngx_http_request_t,
    ctx: [*c]wechatpay_context,
) !ngx_int_t {
    const action = ctx.*.action;
    const body = read_body(r);
    if (body.len == 0) {
        return NGX_OK;
    }
    const msg = switch (action) {
        .OAEP_DECRYPT => try ctx.*.rsa.*.oaep_decrypt(body, r.*.pool),
        .OAEP_ENCRYPT => try ctx.*.rsa.*.oaep_encrypt(body, r.*.pool),
        .OAEP_NONE => body,
    };
    var out = buf.ngx_chain_t{
        .buf = core.nullptr(ngx_buf_t),
        .next = core.nullptr(ngx_chain_t),
    };
    var chain = NChain.init(r.*.pool);
    const last = try chain.allocStr(msg, &out);
    last.*.buf.*.flags.last_buf = (r == r.*.main);
    last.*.buf.*.flags.last_in_chain = true;

    return send_body(r, out.next);
}

export fn ngx_http_wechatpay_oaep_body_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) void {
    if (core.castPtr(
        wechatpay_request_context,
        r.*.ctx[ngx_http_wechatpay_module.ctx_index],
    )) |rctx| {
        if (request_body_exceeds_limit(r, rctx.*.lccf.*.body_max_size)) {
            http.ngx_http_finalize_request(r, NGX_HTTP_REQUEST_ENTITY_TOO_LARGE);
            return;
        }
        if (execute_oaep_action(r, rctx.*.lccf.*.ctx)) |rc| {
            http.ngx_http_finalize_request(r, rc);
        } else |e| {
            const rc = switch (e) {
                core.NError.SSL_ERROR => http.NGX_HTTP_BAD_REQUEST,
                else => NGX_HTTP_INTERNAL_SERVER_ERROR,
            };
            http.ngx_http_finalize_request(r, rc);
        }
    } else {
        http.ngx_http_finalize_request(r, NGX_HTTP_SERVICE_UNAVAILABLE);
    }
}

export fn ngx_http_wechatpay_oaep_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    if (core.castPtr(
        wechatpay_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_wechatpay_module),
    )) |lccf| {
        const rctx = http.ngz_http_get_module_ctx(
            wechatpay_request_context,
            r,
            &ngx_http_wechatpay_module,
        ) catch return NGX_HTTP_INTERNAL_SERVER_ERROR;
        if (rctx.*.lccf == core.nullptr(wechatpay_loc_conf)) {
            rctx.*.lccf = lccf;
        }
        if (request_body_exceeds_limit(r, lccf.*.body_max_size)) return NGX_HTTP_REQUEST_ENTITY_TOO_LARGE;
        const rc = http.ngx_http_read_client_request_body(r, ngx_http_wechatpay_oaep_body_handler);
        return if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) rc else core.NGX_DONE;
    }
    return NGX_DECLINED;
}

export const ngx_http_wechatpay_module_ctx = ngx_http_module_t{
    .preconfiguration = wechatpay_preconfiguration,
    .postconfiguration = wechatpay_postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = wechatpay_create_loc_conf,
    .merge_loc_conf = wechatpay_merge_loc_conf,
};

const CONF_PHASES = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF;
export const ngx_http_wechatpay_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("wechatpay_xpay_proxy_pass"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "xpay_proxy"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_xpay_auth"),
        .type = CONF_PHASES | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "xpay_auth"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_xpay_env"),
        .type = CONF_PHASES | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_num_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "xpay_env"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_xpay_access_token"),
        .type = CONF_PHASES | conf.NGX_CONF_TAKE1,
        .set = http.ngx_http_set_complex_value_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "xpay_access_token"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_xpay_live_key_file"),
        .type = CONF_PHASES | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_file_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "xpay_live_key"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_xpay_sandbox_key_file"),
        .type = CONF_PHASES | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_file_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "xpay_sandbox_key"),
        .post = null,
    },

    ngx_command_t{
        .name = ngx_string("wechatpay_replay_zone"),
        .type = CONF_PHASES | conf.NGX_CONF_TAKE1,
        .set = set_replay_zone,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_audit_request"),
        .type = CONF_PHASES | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "audit_request"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_proxy_pass"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "proxy"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_allow_insecure_http"),
        .type = CONF_PHASES | conf.NGX_CONF_FLAG,
        .set = conf.ngx_conf_set_flag_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "allow_insecure_http"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_body_max_size"),
        .type = CONF_PHASES | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_size_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "body_max_size"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_apiclient_key_file"),
        .type = CONF_PHASES | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_file_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "apiclient_key"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_apiclient_serial"),
        .type = CONF_PHASES | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "apiclient_serial"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_public_key_file"),
        .type = CONF_PHASES | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_file_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "wechatpay_public_key"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_serial"),
        .type = CONF_PHASES | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "wechatpay_serial"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_mch_id"),
        .type = CONF_PHASES | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "mch_id"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_oaep_encrypt"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_FLAG,
        .set = conf.ngx_conf_set_flag_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "oaep_encrypt"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_oaep_decrypt"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_FLAG,
        .set = conf.ngx_conf_set_flag_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "oaep_decrypt"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("wechatpay_access"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_ANY,
        .set = ngx_conf_set_wechatpay_access,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_wechatpay_module = ngx.module.make_module(
    @constCast(&ngx_http_wechatpay_commands),
    @constCast(&ngx_http_wechatpay_module_ctx),
);

//////////////////////////    WECHATPAY HEADER FILTER   ////////////////////////////////////////////
fn postconfiguration_filter(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    _ = cf;
    ngx_http_wechatpay_next_header_filter = http.ngx_http_top_header_filter;
    http.ngx_http_top_header_filter = ngx_http_wechatpay_header_filter;

    ngx_http_wechatpay_next_output_body_filter = http.ngx_http_top_body_filter;
    http.ngx_http_top_body_filter = ngx_http_wechatpay_output_body_filter;

    return NGX_OK;
}

export fn ngx_http_wechatpay_output_body_filter(
    r: [*c]ngx_http_request_t,
    c: [*c]ngx_chain_t,
) callconv(.c) ngx_int_t {
    if (r.*.upstream != core.nullptr(http.ngx_http_upstream_t) and
        r.*.upstream.*.finalize_request != null and
        r.*.upstream.*.finalize_request.? == ngx_http_wechatpay_proxy_upstream_finalize_request)
    {
        if (core.castPtr(
            wechatpay_request_context,
            r.*.ctx[ngx_http_wechatpay_module.ctx_index],
        )) |rctx| {
            switch (rctx.*.sig_verify) {
                .SIG_VERIFICATION_PENDDING => return NGX_OK,
                .SIG_VERIFICATION_FAILED => {},
                .SIG_VERIFICATION_SUCCESS => {},
                .SIG_VERIFICATION_BYPASS => {},
            }
        }
    }
    if (ngx_http_wechatpay_next_output_body_filter) |filter| {
        return filter(r, c);
    }
    return NGX_OK;
}

export fn ngx_http_wechatpay_header_filter(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    if (r.*.upstream != core.nullptr(http.ngx_http_upstream_t) and
        r.*.upstream.*.finalize_request != null and
        r.*.upstream.*.finalize_request.? == ngx_http_wechatpay_proxy_upstream_finalize_request)
    {
        if (core.castPtr(
            wechatpay_request_context,
            r.*.ctx[ngx_http_wechatpay_module.ctx_index],
        )) |rctx| {
            switch (rctx.*.sig_verify) {
                .SIG_VERIFICATION_PENDDING => return NGX_OK,
                .SIG_VERIFICATION_FAILED => {
                    r.*.headers_out.status = http.NGX_HTTP_UNAUTHORIZED;
                    r.*.headers_out.status_line = ngx_string("401 SIGN VERIFICATION ERROR");
                },
                .SIG_VERIFICATION_SUCCESS => {},
                .SIG_VERIFICATION_BYPASS => {},
            }
        }
    }
    if (ngx_http_wechatpay_next_header_filter) |filter| {
        return filter(r);
    }
    return NGX_OK;
}

export const ngx_http_wechatpay_filter_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration_filter,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = null,
    .merge_loc_conf = null,
};

export const ngx_http_wechatpay_filter_commands = [_]ngx_command_t{
    conf.ngx_null_command,
};

export var ngx_http_wechatpay_filter_module = ngx.module.make_module(
    @constCast(&ngx_http_wechatpay_filter_commands),
    @constCast(&ngx_http_wechatpay_filter_module_ctx),
);

var ngx_http_wechatpay_next_header_filter: http.ngx_http_output_header_filter_pt = null;
var ngx_http_wechatpay_next_output_body_filter: http.ngx_http_output_body_filter_pt = null;

const expectEqual = std.testing.expectEqual;
test "wechatpay module" {
    const host0 = get_host(ngx_string("https://abcd.com:80"));
    try expectEqual(host0.port, 80);
    try expectEqual(host0.ssl, true);
    try expectEqual(ngx.string.eql(host0.host, ngx_string("abcd.com")), true);

    const host1 = get_host(ngx_string("https://abcd.com"));
    try expectEqual(host1.port, 443);
    try expectEqual(host1.ssl, true);
    try expectEqual(ngx.string.eql(host1.host, ngx_string("abcd.com")), true);

    const host2 = get_host(ngx_string("abcd.com:8080/"));
    try expectEqual(host2.port, 8080);
    try expectEqual(host2.ssl, false);
    try expectEqual(ngx.string.eql(host2.host, ngx_string("abcd.com")), true);
}

test "replay store fails closed at capacity and reclaims only expired entries" {
    var store = std.mem.zeroes(ReplayStore);
    const now: i64 = 10_000;
    var nonce_buf: [64]u8 = undefined;

    for (0..WECHATPAY_REPLAY_CAPACITY) |i| {
        const value = try std.fmt.bufPrint(&nonce_buf, "nonce-{d}", .{i});
        try std.testing.expect(acceptFreshNonceInStore(&store, value, now));
    }

    try std.testing.expect(!acceptFreshNonceInStore(&store, "capacity-overflow", now));
    try std.testing.expect(!acceptFreshNonceInStore(&store, "nonce-0", now));

    const after_window = now + WECHATPAY_MAX_CLOCK_SKEW_SEC + 1;
    try std.testing.expect(acceptFreshNonceInStore(&store, "reclaimed-after-expiry", after_window));
}
