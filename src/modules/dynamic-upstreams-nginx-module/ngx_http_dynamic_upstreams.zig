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
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_buf_t = buf.ngx_buf_t;
const ngx_chain_t = buf.ngx_chain_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;

const ngx_string = ngx.string.ngx_string;

extern var ngx_http_core_module: ngx_module_t;

const dynamic_upstreams_loc_conf = extern struct {
    api_enabled: ngx_flag_t,
    source: ngx_str_t,
    target: ngx_str_t,
    refresh_ms: ngx_uint_t,
};

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(dynamic_upstreams_loc_conf, cf.*.pool)) |p| {
        p.*.api_enabled = conf.NGX_CONF_UNSET;
        p.*.source = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
        p.*.target = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
        p.*.refresh_ms = 0;
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
    const prev = core.castPtr(dynamic_upstreams_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(dynamic_upstreams_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.api_enabled == conf.NGX_CONF_UNSET) {
        c.*.api_enabled = if (prev.*.api_enabled == conf.NGX_CONF_UNSET) 0 else prev.*.api_enabled;
    }
    if (c.*.source.len == 0) c.*.source = prev.*.source;
    if (c.*.target.len == 0) c.*.target = prev.*.target;
    if (c.*.refresh_ms == 0) c.*.refresh_ms = prev.*.refresh_ms;

    return conf.NGX_CONF_OK;
}

fn send_placeholder_json(r: [*c]ngx_http_request_t, body: ngx_str_t) ngx_int_t {
    const content_type = ngx_string("application/json");
    r.*.headers_out.status = 501;
    r.*.headers_out.content_type = content_type;
    r.*.headers_out.content_type_len = content_type.len;
    r.*.headers_out.content_length_n = @intCast(body.len);

    const header_rc = http.ngx_http_send_header(r);
    if (header_rc == NGX_ERROR or header_rc > NGX_OK) {
        return header_rc;
    }
    if (r.*.method == http.NGX_HTTP_HEAD) {
        return NGX_OK;
    }

    const out_buf = core.ngz_pcalloc_c(ngx_buf_t, r.*.pool) orelse return NGX_ERROR;
    out_buf.*.pos = body.data;
    out_buf.*.last = body.data + body.len;
    out_buf.*.flags.memory = true;
    out_buf.*.flags.last_buf = true;
    out_buf.*.flags.last_in_chain = true;

    const chain = core.ngz_pcalloc_c(ngx_chain_t, r.*.pool) orelse return NGX_ERROR;
    chain.*.buf = out_buf;
    chain.*.next = core.nullptr(ngx_chain_t);

    return http.ngx_http_output_filter(r, chain);
}

export fn ngx_http_dynamic_upstreams_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    return send_placeholder_json(r, ngx_string("{\"status\":\"not_implemented\",\"module\":\"dynamic_upstreams\"}"));
}

fn ngx_conf_set_dynamic_upstreams_api(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(dynamic_upstreams_loc_conf, loc)) |lccf| {
        lccf.*.api_enabled = 1;

        const clcf = core.castPtr(
            http.ngx_http_core_loc_conf_t,
            conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
        ) orelse return conf.NGX_CONF_OK;
        clcf.*.handler = ngx_http_dynamic_upstreams_handler;
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_dynamic_upstreams_source(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(dynamic_upstreams_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            lccf.*.source = arg.*;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_dynamic_upstreams_target(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(dynamic_upstreams_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            lccf.*.target = arg.*;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_dynamic_upstreams_refresh(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(dynamic_upstreams_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const slice = core.slicify(u8, arg.*.data, arg.*.len);
            lccf.*.refresh_ms = std.fmt.parseInt(ngx_uint_t, slice, 10) catch 0;
        }
    }
    return conf.NGX_CONF_OK;
}

export const ngx_http_dynamic_upstreams_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = null,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_dynamic_upstreams_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_api"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_dynamic_upstreams_api,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_source"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_dynamic_upstreams_source,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_target"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_dynamic_upstreams_target,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("dynamic_upstreams_refresh"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_dynamic_upstreams_refresh,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_dynamic_upstreams_module = ngx.module.make_module(
    @constCast(&ngx_http_dynamic_upstreams_commands),
    @constCast(&ngx_http_dynamic_upstreams_module_ctx),
);

test "dynamic upstreams scaffold module" {}
