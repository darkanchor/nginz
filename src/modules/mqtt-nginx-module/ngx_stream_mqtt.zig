const std = @import("std");
const ngx = @import("ngx");

const array = ngx.array;
const conf = ngx.conf;
const core = ngx.core;
const string = ngx.string;
const vx = ngx.vx;

const ngx_command_t = conf.ngx_command_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_int_t = core.ngx_int_t;
const ngx_str_t = core.ngx_str_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_stream_session_t = vx.ngx_stream_session_t;
const ngx_stream_module_t = vx.ngx_stream_module_t;
const ngx_stream_conf_ctx_t = vx.ngx_stream_conf_ctx_t;
const ngx_stream_core_main_conf_t = vx.ngx_stream_core_main_conf_t;
const ngx_stream_core_srv_conf_t = vx.ngx_stream_core_srv_conf_t;
const ngx_stream_complex_value_t = vx.ngx_stream_complex_value_t;
const ngx_stream_compile_complex_value_t = vx.ngx_stream_compile_complex_value_t;
const ngx_stream_variable_value_t = vx.ngx_stream_variable_value_t;
const ngx_chain_t = ngx.buf.ngx_chain_t;
const NArray = array.NArray;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;

const NGX_STREAM_MAIN_CONF: ngx_uint_t = 0x02000000;
const NGX_STREAM_SRV_CONF: ngx_uint_t = 0x04000000;
const NGX_STREAM_MAIN_CONF_OFFSET: ngx_uint_t = @offsetOf(ngx_stream_conf_ctx_t, "main_conf");
const NGX_STREAM_SRV_CONF_OFFSET: ngx_uint_t = @offsetOf(ngx_stream_conf_ctx_t, "srv_conf");

const VAR_CLIENTID: usize = 0;
const VAR_USERNAME: usize = 1;

const MqttConnectField = enum(c_uint) {
    clientid = 0,
    username = 1,
    password = 2,
};

const MqttPrereadSrvConf = extern struct {
    enabled: ngx_flag_t,
};

const MqttPrereadMainConf = extern struct {
    enabled: ngx_flag_t,
};

const MqttFilterSrvConf = extern struct {
    enabled: ngx_flag_t,
    rewrites: NArray(MqttConnectRewrite),
};

const MqttFilterMainConf = extern struct {
    enabled: ngx_flag_t,
};

const MqttSessionCtx = extern struct {
    parsed: ngx_flag_t,
    clientid: ngx_str_t,
    username: ngx_str_t,
};

const MqttConnectRewrite = extern struct {
    field: MqttConnectField,
    source: ngx_str_t,
    value: ngx_stream_complex_value_t,
};

extern var ngx_stream_core_module: ngx_module_t;
extern var ngx_stream_top_filter: vx.ngx_stream_filter_pt;

var ngx_stream_mqtt_next_filter: vx.ngx_stream_filter_pt = null;

inline fn getConfCtx(cf: [*c]ngx_conf_t) [*c]ngx_stream_conf_ctx_t {
    return @as([*c]ngx_stream_conf_ctx_t, @ptrCast(@alignCast(cf.*.ctx)));
}

inline fn getConfStreamCoreMainConf(cf: [*c]ngx_conf_t) ?*ngx_stream_core_main_conf_t {
    const ctx = getConfCtx(cf);
    return @as(?*ngx_stream_core_main_conf_t, @ptrCast(@alignCast(
        ctx.*.main_conf[ngx_stream_core_module.ctx_index],
    )));
}

inline fn getConfStreamCoreSrvConf(cf: [*c]ngx_conf_t) ?*ngx_stream_core_srv_conf_t {
    const ctx = getConfCtx(cf);
    return @as(?*ngx_stream_core_srv_conf_t, @ptrCast(@alignCast(
        ctx.*.srv_conf[ngx_stream_core_module.ctx_index],
    )));
}

inline fn getConfPrereadMainConf(cf: [*c]ngx_conf_t) ?*MqttPrereadMainConf {
    const ctx = getConfCtx(cf);
    return @as(?*MqttPrereadMainConf, @ptrCast(@alignCast(
        ctx.*.main_conf[ngx_stream_mqtt_preread_module.ctx_index],
    )));
}

inline fn getConfPrereadSrvConf(cf: [*c]ngx_conf_t) ?*MqttPrereadSrvConf {
    const ctx = getConfCtx(cf);
    return @as(?*MqttPrereadSrvConf, @ptrCast(@alignCast(
        ctx.*.srv_conf[ngx_stream_mqtt_preread_module.ctx_index],
    )));
}

inline fn getConfFilterMainConf(cf: [*c]ngx_conf_t) ?*MqttFilterMainConf {
    const ctx = getConfCtx(cf);
    return @as(?*MqttFilterMainConf, @ptrCast(@alignCast(
        ctx.*.main_conf[ngx_stream_mqtt_filter_module.ctx_index],
    )));
}

inline fn getConfFilterSrvConf(cf: [*c]ngx_conf_t) ?*MqttFilterSrvConf {
    const ctx = getConfCtx(cf);
    return @as(?*MqttFilterSrvConf, @ptrCast(@alignCast(
        ctx.*.srv_conf[ngx_stream_mqtt_filter_module.ctx_index],
    )));
}

inline fn getPrereadSrvConf(s: [*c]ngx_stream_session_t) ?*MqttPrereadSrvConf {
    return @as(?*MqttPrereadSrvConf, @ptrCast(@alignCast(
        s.*.srv_conf[ngx_stream_mqtt_preread_module.ctx_index],
    )));
}

inline fn getFilterSrvConf(s: [*c]ngx_stream_session_t) ?*MqttFilterSrvConf {
    return @as(?*MqttFilterSrvConf, @ptrCast(@alignCast(
        s.*.srv_conf[ngx_stream_mqtt_filter_module.ctx_index],
    )));
}

inline fn getSessionCtx(s: [*c]ngx_stream_session_t) ?*MqttSessionCtx {
    return @as(?*MqttSessionCtx, @ptrCast(@alignCast(
        s.*.ctx[ngx_stream_mqtt_preread_module.ctx_index],
    )));
}

inline fn setSessionCtx(s: [*c]ngx_stream_session_t, ctx: *MqttSessionCtx) void {
    s.*.ctx[ngx_stream_mqtt_preread_module.ctx_index] = ctx;
}

fn createPrereadSrvConf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const scf = core.ngz_pcalloc_c(MqttPrereadSrvConf, cf.*.pool) orelse return null;
    scf.*.enabled = conf.NGX_CONF_UNSET;
    return scf;
}

fn createPrereadMainConf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const mcf = core.ngz_pcalloc_c(MqttPrereadMainConf, cf.*.pool) orelse return null;
    mcf.*.enabled = conf.NGX_CONF_UNSET;
    return mcf;
}

fn initPrereadMainConf(
    cf: [*c]ngx_conf_t,
    data: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cf;
    const mcf = core.castPtr(MqttPrereadMainConf, data) orelse return conf.NGX_CONF_OK;
    if (mcf.*.enabled == conf.NGX_CONF_UNSET) mcf.*.enabled = 0;
    return conf.NGX_CONF_OK;
}

fn mergePrereadSrvConf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    const prev = core.castPtr(MqttPrereadSrvConf, parent) orelse return conf.NGX_CONF_OK;
    const cur = core.castPtr(MqttPrereadSrvConf, child) orelse return conf.NGX_CONF_OK;
    const main_enabled = if (getConfPrereadMainConf(cf)) |mcf| mcf.*.enabled else 0;
    if (cur.*.enabled == conf.NGX_CONF_UNSET) {
        cur.*.enabled = if (prev.*.enabled != conf.NGX_CONF_UNSET) prev.*.enabled else main_enabled;
    }
    return conf.NGX_CONF_OK;
}

fn createFilterMainConf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const mcf = core.ngz_pcalloc_c(MqttFilterMainConf, cf.*.pool) orelse return null;
    mcf.*.enabled = conf.NGX_CONF_UNSET;
    return mcf;
}

fn initFilterMainConf(
    cf: [*c]ngx_conf_t,
    data: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cf;
    const mcf = core.castPtr(MqttFilterMainConf, data) orelse return conf.NGX_CONF_OK;
    if (mcf.*.enabled == conf.NGX_CONF_UNSET) mcf.*.enabled = 0;
    return conf.NGX_CONF_OK;
}

fn createFilterSrvConf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const scf = core.ngz_pcalloc_c(MqttFilterSrvConf, cf.*.pool) orelse return null;
    scf.*.enabled = conf.NGX_CONF_UNSET;
    scf.*.rewrites = NArray(MqttConnectRewrite).init(cf.*.pool, 2) catch return null;
    return scf;
}

fn mergeFilterSrvConf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    const prev = core.castPtr(MqttFilterSrvConf, parent) orelse return conf.NGX_CONF_OK;
    const cur = core.castPtr(MqttFilterSrvConf, child) orelse return conf.NGX_CONF_OK;
    const main_enabled = if (getConfFilterMainConf(cf)) |mcf| mcf.*.enabled else 0;
    if (cur.*.enabled == conf.NGX_CONF_UNSET) {
        cur.*.enabled = if (prev.*.enabled != conf.NGX_CONF_UNSET) prev.*.enabled else main_enabled;
    }
    if (cur.*.rewrites.size() == 0 and prev.*.rewrites.size() != 0) {
        cur.*.rewrites = prev.*.rewrites;
    }
    return conf.NGX_CONF_OK;
}

fn preconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    var clientid_name = string.ngx_string("mqtt_preread_clientid");
    var username_name = string.ngx_string("mqtt_preread_username");

    const flags = vx.NGX_STREAM_VAR_CHANGEABLE | vx.NGX_STREAM_VAR_NOCACHEABLE;
    const clientid = vx.ngx_stream_add_variable(cf, &clientid_name, flags);
    if (clientid == core.nullptr(vx.ngx_stream_variable_t)) return NGX_ERROR;
    clientid.*.get_handler = ngx_stream_mqtt_variable;
    clientid.*.data = VAR_CLIENTID;

    const username = vx.ngx_stream_add_variable(cf, &username_name, flags);
    if (username == core.nullptr(vx.ngx_stream_variable_t)) return NGX_ERROR;
    username.*.get_handler = ngx_stream_mqtt_variable;
    username.*.data = VAR_USERNAME;

    return NGX_OK;
}

fn postconfigurationPreread(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    const cmcf = getConfStreamCoreMainConf(cf) orelse return NGX_ERROR;
    var handlers = NArray(vx.ngx_stream_handler_pt).init0(&cmcf.phases[vx.NGX_STREAM_PREREAD_PHASE].handlers);
    const h = handlers.append() catch return NGX_ERROR;
    h.* = ngx_stream_mqtt_preread_handler;
    return NGX_OK;
}

fn postconfigurationFilter(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    _ = cf;
    ngx_stream_mqtt_next_filter = ngx_stream_top_filter;
    ngx_stream_top_filter = ngx_stream_mqtt_filter;
    return NGX_OK;
}

fn parseFlag(value: ngx_str_t) ?ngx_flag_t {
    const s = core.slicify(u8, value.data, value.len);
    if (std.ascii.eqlIgnoreCase(s, "on")) return 1;
    if (std.ascii.eqlIgnoreCase(s, "off")) return 0;
    return null;
}

fn setPrereadFlag(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = loc;
    const args = core.castPtr(ngx_str_t, cf.*.args.*.elts) orelse return conf.NGX_CONF_ERROR;
    const value = parseFlag(args[1]) orelse return @as([*c]u8, @constCast("invalid value"));
    if ((cf.*.cmd_type & NGX_STREAM_MAIN_CONF) != 0) {
        const mcf = getConfPrereadMainConf(cf) orelse return conf.NGX_CONF_ERROR;
        mcf.*.enabled = value;
        return conf.NGX_CONF_OK;
    }
    const scf = getConfPrereadSrvConf(cf) orelse return conf.NGX_CONF_ERROR;
    scf.*.enabled = value;
    return conf.NGX_CONF_OK;
}

fn setFilterFlag(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    _ = loc;
    const args = core.castPtr(ngx_str_t, cf.*.args.*.elts) orelse return conf.NGX_CONF_ERROR;
    const value = parseFlag(args[1]) orelse return @as([*c]u8, @constCast("invalid value"));
    if ((cf.*.cmd_type & NGX_STREAM_MAIN_CONF) != 0) {
        const mcf = getConfFilterMainConf(cf) orelse return conf.NGX_CONF_ERROR;
        mcf.*.enabled = value;
        return conf.NGX_CONF_OK;
    }
    const scf = getConfFilterSrvConf(cf) orelse return conf.NGX_CONF_ERROR;
    scf.*.enabled = value;
    return conf.NGX_CONF_OK;
}

export fn ngx_stream_mqtt_variable(
    s: [*c]ngx_stream_session_t,
    v: [*c]ngx_stream_variable_value_t,
    data: usize,
) callconv(.c) ngx_int_t {
    const ctx = getSessionCtx(s) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };

    const value = switch (data) {
        VAR_CLIENTID => ctx.clientid,
        VAR_USERNAME => ctx.username,
        else => string.ngx_null_str,
    };

    if (value.len == 0 or value.data == core.nullptr(u8)) {
        v.*.flags.not_found = true;
        return NGX_OK;
    }

    v.*.data = value.data;
    v.*.flags.len = @intCast(value.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

export fn ngx_stream_mqtt_preread_handler(s: [*c]ngx_stream_session_t) callconv(.c) ngx_int_t {
    const scf = getPrereadSrvConf(s) orelse return NGX_DECLINED;
    if (scf.*.enabled != 1) return NGX_DECLINED;

    if (getSessionCtx(s) == null) {
        const ctx = core.ngz_pcalloc_c(MqttSessionCtx, s.*.connection.*.pool) orelse return NGX_ERROR;
        setSessionCtx(s, ctx);
    }

    // Parser implementation is intentionally deferred to the module roadmap.
    // The scaffold installs the preread hook and variable surface without
    // consuming bytes or changing proxy behavior.
    return NGX_DECLINED;
}

export fn ngx_stream_mqtt_filter(
    s: [*c]ngx_stream_session_t,
    in: [*c]ngx_chain_t,
    from_upstream: ngx_uint_t,
) callconv(.c) ngx_int_t {
    if (from_upstream == 0) {
        if (getFilterSrvConf(s)) |scf| {
            _ = scf;
            // CONNECT rewrite is documented in README.md and will be implemented
            // in this filter before forwarding client-to-upstream bytes.
        }
    }

    if (ngx_stream_mqtt_next_filter) |next| {
        return next(s, in, from_upstream);
    }
    return NGX_OK;
}

fn parseConnectField(value: ngx_str_t) ?MqttConnectField {
    const s = core.slicify(u8, value.data, value.len);
    if (std.ascii.eqlIgnoreCase(s, "clientid")) return .clientid;
    if (std.ascii.eqlIgnoreCase(s, "username")) return .username;
    if (std.ascii.eqlIgnoreCase(s, "password")) return .password;
    return null;
}

fn setMqttConnect(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const scf = core.castPtr(MqttFilterSrvConf, loc) orelse return conf.NGX_CONF_ERROR;
    const args = core.castPtr(ngx_str_t, cf.*.args.*.elts) orelse return conf.NGX_CONF_ERROR;
    const field = parseConnectField(args[1]) orelse return @as([*c]u8, @constCast("invalid MQTT CONNECT field"));

    const rewrite = scf.*.rewrites.append() catch return conf.NGX_CONF_ERROR;
    rewrite.*.field = field;
    rewrite.*.source = args[2];
    rewrite.*.value = std.mem.zeroes(ngx_stream_complex_value_t);

    var ccv = std.mem.zeroes(ngx_stream_compile_complex_value_t);
    ccv.cf = cf;
    ccv.value = &rewrite.*.source;
    ccv.complex_value = &rewrite.*.value;
    ccv.flags.complete_lengths = true;
    ccv.flags.complete_values = true;
    if (vx.ngx_stream_compile_complex_value(&ccv) != NGX_OK) {
        return conf.NGX_CONF_ERROR;
    }
    return conf.NGX_CONF_OK;
}

export const ngx_stream_mqtt_preread_module_ctx = ngx_stream_module_t{
    .preconfiguration = preconfiguration,
    .postconfiguration = postconfigurationPreread,
    .create_main_conf = createPrereadMainConf,
    .init_main_conf = initPrereadMainConf,
    .create_srv_conf = createPrereadSrvConf,
    .merge_srv_conf = mergePrereadSrvConf,
};

export const ngx_stream_mqtt_filter_module_ctx = ngx_stream_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfigurationFilter,
    .create_main_conf = createFilterMainConf,
    .init_main_conf = initFilterMainConf,
    .create_srv_conf = createFilterSrvConf,
    .merge_srv_conf = mergeFilterSrvConf,
};

export const ngx_stream_mqtt_preread_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = string.ngx_string("mqtt_preread"),
        .type = NGX_STREAM_MAIN_CONF | NGX_STREAM_SRV_CONF | conf.NGX_CONF_FLAG,
        .set = setPrereadFlag,
        .conf = 0,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export const ngx_stream_mqtt_filter_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = string.ngx_string("mqtt"),
        .type = NGX_STREAM_MAIN_CONF | NGX_STREAM_SRV_CONF | conf.NGX_CONF_FLAG,
        .set = setFilterFlag,
        .conf = 0,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = string.ngx_string("mqtt_set_connect"),
        .type = NGX_STREAM_SRV_CONF | conf.NGX_CONF_TAKE2,
        .set = setMqttConnect,
        .conf = NGX_STREAM_SRV_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_stream_mqtt_preread_module = ngx.module.make_stream_module(
    @constCast(&ngx_stream_mqtt_preread_commands),
    @constCast(&ngx_stream_mqtt_preread_module_ctx),
);

export var ngx_stream_mqtt_filter_module = ngx.module.make_stream_module(
    @constCast(&ngx_stream_mqtt_filter_commands),
    @constCast(&ngx_stream_mqtt_filter_module_ctx),
);

test "mqtt stream modules are registered as stream modules" {
    try std.testing.expectEqual(@as(ngx_uint_t, @intCast(ngx.module.NGX_STREAM_MODULE)), ngx_stream_mqtt_preread_module.type);
    try std.testing.expectEqual(@as(ngx_uint_t, @intCast(ngx.module.NGX_STREAM_MODULE)), ngx_stream_mqtt_filter_module.type);
}

test "mqtt_set_connect field parser" {
    try std.testing.expectEqual(MqttConnectField.clientid, parseConnectField(string.ngx_string("clientid")).?);
    try std.testing.expectEqual(MqttConnectField.username, parseConnectField(string.ngx_string("username")).?);
    try std.testing.expectEqual(MqttConnectField.password, parseConnectField(string.ngx_string("password")).?);
    try std.testing.expect(parseConnectField(string.ngx_string("topic")) == null);
}
