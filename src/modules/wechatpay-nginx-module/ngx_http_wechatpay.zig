const std = @import("std");
const ngx = @import("ngx");

const buf = ngx.buf;
const ssl = ngx.ssl;
const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const file = ngx.file;
const cjson = ngx.cjson;
const CJSON = cjson.CJSON;

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
const WECHATPAY_AUTH_HEADER = ngx_string("WECHATPAY2-SHA256-RSA2048");
extern var ngx_pagesize: ngx_uint_t;
extern var ngx_http_core_module: ngx_module_t;
extern var ngx_http_upstream_module: ngx_module_t;

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
};

const wechatpay_loc_conf = extern struct {
    proxy: ngx_str_t,
    apiclient_key: ngx_str_t,
    apiclient_serial: ngx_str_t,
    wechatpay_public_key: ngx_str_t,
    wechatpay_serial: ngx_str_t,
    mch_id: ngx_str_t,
    aes_secret: ngx_str_t,
    access_control: ngx_flag_t,
    oaep_encrypt: ngx_flag_t,
    oaep_decrypt: ngx_flag_t,
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
    cf.*.ssl_verify = 0;
    cf.*.connect_timeout = 60000;
    cf.*.send_timeout = 60000;
    cf.*.read_timeout = 60000;
    cf.*.module = ngx_string("ngx_http_wechatpay_module");
    cf.*.hide_headers = conf.NGX_CONF_UNSET_PTR;
    cf.*.pass_headers = conf.NGX_CONF_UNSET_PTR;
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
        p.*.oaep_encrypt = conf.NGX_CONF_UNSET;
        p.*.oaep_decrypt = conf.NGX_CONF_UNSET;
        p.*.aes_secret = ngx.string.ngx_null_str;
        p.*.access_control = 0;

        init_upstream_conf(&p.*.ups);
        return p;
    }
    return null;
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
            ngx.log.ngx_http_conf_debug(cf, "aes key %V", .{arg});
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
    conf.ngx_conf_merge_str_value(&ch.*.apiclient_key, &pr.*.apiclient_key, ngx_string(""));
    conf.ngx_conf_merge_str_value(&ch.*.apiclient_serial, &pr.*.apiclient_serial, ngx_string(""));
    conf.ngx_conf_merge_str_value(&ch.*.wechatpay_public_key, &pr.*.wechatpay_public_key, ngx_string(""));
    conf.ngx_conf_merge_str_value(&ch.*.wechatpay_serial, &pr.*.wechatpay_serial, ngx_string(""));
    conf.ngx_conf_merge_str_value(&ch.*.mch_id, &pr.*.mch_id, ngx_string(""));
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
            if (core.castPtr(
                http.ngx_http_core_loc_conf_t,
                conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
            )) |clcf| {
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

fn sign_request(
    lccf: [*c]wechatpay_loc_conf,
    r: [*c]ngx_http_request_t,
    data: [*c]u8,
) !ngx_str_t {
    const nstr = try nonce(r.*.pool);
    const tstr = try timestamp(r.*.pool);
    var write: [*c]u8 = data;
    write = ngx_sprintf(write, "%V\n", &r.*.method_name);
    write = ngx_sprintf(write, "%V?%V\n", &r.*.uri, &r.*.args);
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
    var content_length: usize = 1024;
    if (!r.*.flags1.discard_body and r.*.headers_in.content_length_n > 0) {
        content_length += @intCast(r.*.headers_in.content_length_n);
    }
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
        write = ngx_sprintf(write, "%V %V?%V HTTP/1.1\r\n", &r.*.method_name, &r.*.uri, &r.*.args);
        // Use main request headers: subrequest headers_in is a struct-copy whose
        // embedded part and last pointer diverge (list inconsistent for iteration).
        var headers = NList(ngx_table_elt_t).init0(&r.*.main.*.headers_in.headers);
        var it = headers.iterator();
        while (it.next()) |h| {
            write = ngx_sprintf(write, "%V: %V\r\n", &h.*.key, &h.*.value);
        }
        write = ngx_sprintf(write, "%V\r\n", &sign);
        const len = core.ngz_len(data, write);
        return ngx.string.ngx_string_from_pool(data, len, r.*.pool);
    }
    return core.NError.OOM;
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
    const req_id = try find_header(headers, ngx_string("Request-ID"));
    if (req_id.len == 0 or !ngx.string.eql(w_serial, lccf.*.wechatpay_serial)) {
        return false;
    }
    const w_nonce = try find_header(headers, ngx_string("Wechatpay-Nonce"));
    const w_timestamp = try find_header(headers, ngx_string("Wechatpay-Timestamp"));
    const w_signature = try find_header(headers, ngx_string("Wechatpay-Signature"));
    var write: [*c]u8 = data;
    write = ngx_sprintf(write, "%V\n", &w_timestamp);
    write = ngx_sprintf(write, "%V\n", &w_nonce);
    write = ngx_sprintf(write, "%V\n", &body);
    const len = core.ngz_len(data, write);
    const rsa = lccf.*.ctx.*.rsa;
    return rsa.*.verify_sha256(w_signature, ngx_str_t{ .data = data, .len = len }, pool);
}

fn send_header(r: [*c]ngx_http_request_t) ngx_int_t {
    r.*.headers_out.status = http.NGX_HTTP_OK;
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

fn wechatpay_preconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    ssl.SSL_LOG = cf.*.log;
    return NGX_OK;
}

fn wechatpay_postconfiguration(
    cf: [*c]ngx_conf_t,
) callconv(.c) ngx_int_t {
    if (core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    )) |cmcf| {
        var handlers = NArray(http.ngx_http_handler_pt).init0(
            &cmcf[0].phases[http.NGX_HTTP_ACCESS_PHASE].handlers,
        );
        const h = handlers.append() catch return NGX_ERROR;
        h.* = ngx_http_wechatpay_access_handler;
    }
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
        const req = build_request(rctx.*.lccf, r) catch return NGX_HTTP_INTERNAL_SERVER_ERROR;
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
        last.*.next = r.*.upstream.*.request_bufs;
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
        u.*.length = u.*.headers_in.content_length_n;
    }
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
            const len: usize = @intCast(bytes);
            var chain = NChain.init(r.*.pool);
            const last = buf.ngz_chain_last(rctx.*.res);
            const cl = chain.alloc(len, last) catch return NGX_ERROR;
            core.ngz_memcpy(cl.*.buf.*.last, u.*.buffer.pos, len);
            cl.*.buf.*.last += len;
            u.*.buffer.pos += len;

            ngx.log.ngz_log_error(
                ngx.log.NGX_LOG_DEBUG,
                r.*.connection.*.log,
                0,
                "reading upstream %d bytes",
                .{bytes},
            );
            if (u.*.length > 0) {
                u.*.length -= @min(u.*.length, bytes);
            }
            if (u.*.length == 0) {
                u.*.flags.keepalive = true;
            }
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
        if (rc != NGX_OK) {
            rctx.*.sig_verify = .SIG_VERIFICATION_BYPASS;
            return;
        }
        const u = r.*.upstream;
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

        if (body.len > 0) {
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

    const host = get_host(lccf.*.proxy);
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

export fn ngx_http_wechatpay_proxy_body_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) void {
    if (core.castPtr(
        wechatpay_request_context,
        r.*.ctx[ngx_http_wechatpay_module.ctx_index],
    )) |rctx| {
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
        const rctx = http.ngz_http_get_module_ctx(
            wechatpay_request_context,
            r,
            &ngx_http_wechatpay_module,
        ) catch return NGX_HTTP_INTERNAL_SERVER_ERROR;
        if (rctx.*.lccf == core.nullptr(wechatpay_loc_conf)) {
            rctx.*.lccf = lccf;
        }
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
        .name = ngx_string("wechatpay_proxy_pass"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(wechatpay_loc_conf, "proxy"),
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
