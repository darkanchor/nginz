const std = @import("std");
const ngx = @import("ngx");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const buf = ngx.buf;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;

const ngx_str_t = core.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_buf_t = buf.ngx_buf_t;
const ngx_chain_t = buf.ngx_chain_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;

const ngx_string = ngx.string.ngx_string;

extern var ngx_http_core_module: ngx_module_t;

const hello_loc_conf = extern struct {
    hello_enabled: core.ngx_flag_t,
};

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(hello_loc_conf, cf.*.pool)) |p| {
        return p;
    }
    return null;
}

fn merge_loc_conf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = parent;
    if (core.castPtr(hello_loc_conf, child)) |ch| {
        if (ch.*.hello_enabled != 0) {
            if (core.castPtr(
                http.ngx_http_core_loc_conf_t,
                conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
            )) |clcf| {
                clcf.*.handler = ngx_http_hello_handler;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_hello(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cf;
    _ = cmd;
    if (core.castPtr(hello_loc_conf, loc)) |lccf| {
        lccf.*.hello_enabled = 1;
    }
    return conf.NGX_CONF_OK;
}

export fn ngx_http_hello_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    const hello_str = ngx_string("hello");

    // Set response status and content type
    r.*.headers_out.status = http.NGX_HTTP_OK;
    http.ngx_http_clear_content_length(r);
    http.ngx_http_clear_accept_ranges(r);

    // Send headers
    const header_rc = http.ngx_http_send_header(r);
    if (header_rc == NGX_ERROR or header_rc > NGX_OK) {
        return NGX_ERROR;
    }
    if (r.*.method == http.NGX_HTTP_HEAD or r.*.flags1.header_only) {
        return NGX_OK;
    }

    // Allocate buffer for response
    if (core.ngz_pcalloc_c(buf.ngx_buf_t, r.*.pool)) |b| {
        b.*.pos = hello_str.data;
        b.*.last = hello_str.data + hello_str.len;
        b.*.flags.memory = true;
        b.*.flags.last_buf = (r == r.*.main);
        b.*.flags.last_in_chain = true;

        // Allocate chain link
        if (core.ngz_pcalloc_c(ngx_chain_t, r.*.pool)) |chain| {
            chain.*.buf = b;
            chain.*.next = core.nullptr(ngx_chain_t);

            // Send body
            if (http.ngx_http_output_filter(r, chain) != NGX_OK) {
                return NGX_ERROR;
            }

            return NGX_OK;
        }
    }

    return NGX_ERROR;
}

export const ngx_http_hello_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = null,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_hello_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("hello"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_hello,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_hello_module = ngx.module.make_module(
    @constCast(&ngx_http_hello_commands),
    @constCast(&ngx_http_hello_module_ctx),
);
