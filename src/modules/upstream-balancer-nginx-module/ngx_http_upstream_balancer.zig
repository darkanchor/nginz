const ngx = @import("ngx");

const conf = ngx.conf;
const ngx_command_t = conf.ngx_command_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = ngx.http.ngx_http_module_t;

const ngx_string = ngx.string.ngx_string;

fn ngx_conf_accept_placeholder(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    data: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cf;
    _ = cmd;
    _ = data;
    return conf.NGX_CONF_OK;
}

export const ngx_http_upstream_balancer_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = null,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = null,
    .merge_loc_conf = null,
};

export const ngx_http_upstream_balancer_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("upstream_balancer_sticky_cookie"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_accept_placeholder,
        .conf = 0,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("upstream_balancer_sticky_header"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_accept_placeholder,
        .conf = 0,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("upstream_balancer_fallback"),
        .type = conf.NGX_HTTP_UPS_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_accept_placeholder,
        .conf = 0,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_upstream_balancer_module = ngx.module.make_module(
    @constCast(&ngx_http_upstream_balancer_commands),
    @constCast(&ngx_http_upstream_balancer_module_ctx),
);

test "upstream balancer scaffold module" {}
