const std = @import("std");
const ngx = @import("ngx");

const array = ngx.array;
const conf = ngx.conf;
const core = ngx.core;
const log = ngx.log;
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
const NGX_AGAIN = core.NGX_AGAIN;
const NGX_DECLINED = core.NGX_DECLINED;

const NGX_STREAM_MAIN_CONF: ngx_uint_t = 0x02000000;
const NGX_STREAM_SRV_CONF: ngx_uint_t = 0x04000000;
const NGX_STREAM_MAIN_CONF_OFFSET: ngx_uint_t = @offsetOf(ngx_stream_conf_ctx_t, "main_conf");
const NGX_STREAM_SRV_CONF_OFFSET: ngx_uint_t = @offsetOf(ngx_stream_conf_ctx_t, "srv_conf");

const VAR_CLIENTID: usize = 0;
const VAR_USERNAME: usize = 1;
const MQTT_MAX_REMAINING_LENGTH: usize = 268_435_455;
const MQTT_REWRITE_BUFFER_LIMIT: usize = 1024 * 1024;

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

const MqttFilterCtx = extern struct {
    processed: ngx_flag_t,
    buffered: ngx_str_t,
};

const MqttConnectRewrite = extern struct {
    field: MqttConnectField,
    source: ngx_str_t,
    value: ngx_stream_complex_value_t,
};

const MqttVersion = enum {
    v311,
    v5,
};

const FieldRef = struct {
    len_offset: usize,
    value_offset: usize,
    value_len: usize,
};

const ConnectView = struct {
    version: MqttVersion,
    frame_len: usize,
    remaining_len: usize,
    remaining_len_width: usize,
    connect_flags_offset: usize,
    clientid: FieldRef,
    username: ?FieldRef,
    password: ?FieldRef,
};

const RemainingLength = struct {
    value: usize,
    width: usize,
};

const ParseConnectError = error{
    Incomplete,
    Malformed,
};

const AppendBufferError = error{
    Overflow,
    NoMemory,
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

inline fn getFilterCtx(s: [*c]ngx_stream_session_t) ?*MqttFilterCtx {
    return @as(?*MqttFilterCtx, @ptrCast(@alignCast(
        s.*.ctx[ngx_stream_mqtt_filter_module.ctx_index],
    )));
}

inline fn setFilterCtx(s: [*c]ngx_stream_session_t, ctx: *MqttFilterCtx) void {
    s.*.ctx[ngx_stream_mqtt_filter_module.ctx_index] = ctx;
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

fn checkedAdd(a: usize, b: usize) ?usize {
    return std.math.add(usize, a, b) catch null;
}

fn checkedSub(a: usize, b: usize) ?usize {
    if (a < b) return null;
    return a - b;
}

fn checkedRangeEnd(start: usize, len: usize, limit: usize) ?usize {
    const end = checkedAdd(start, len) orelse return null;
    if (end > limit) return null;
    return end;
}

fn checkedFieldStorageLen(value_len: usize) ?usize {
    if (value_len > 0xffff) return null;
    return checkedAdd(2, value_len);
}

fn logStream(s: [*c]ngx_stream_session_t, level: ngx_uint_t, message: [*c]const u8) void {
    log.ngz_log_error(level, s.*.connection.*.log, 0, message, .{});
}

fn decodeMqttVarIntAt(input: []const u8, start: usize) ParseConnectError!RemainingLength {
    if (start >= input.len) return error.Incomplete;

    var value: usize = 0;
    var multiplier: usize = 1;
    var i: usize = start;
    var width: usize = 0;

    while (width < 4) : (width += 1) {
        if (i >= input.len) return error.Incomplete;
        const encoded = input[i];
        i += 1;
        const part = std.math.mul(usize, @as(usize, encoded & 0x7f), multiplier) catch return error.Malformed;
        value = std.math.add(usize, value, part) catch return error.Malformed;

        if ((encoded & 0x80) == 0) {
            return .{ .value = value, .width = width + 1 };
        }

        multiplier = std.math.mul(usize, multiplier, 128) catch return error.Malformed;
    }

    return error.Malformed;
}

fn mqttVarIntWidth(value: usize) usize {
    if (value < 128) return 1;
    if (value < 16_384) return 2;
    if (value < 2_097_152) return 3;
    return 4;
}

fn encodeMqttVarInt(out: []u8, pos: *usize, len: usize) bool {
    if (len > MQTT_MAX_REMAINING_LENGTH) return false;
    var value = len;
    while (true) {
        if (pos.* >= out.len) return false;
        var encoded: u8 = @intCast(value % 128);
        value /= 128;
        if (value > 0) encoded |= 0x80;
        out[pos.*] = encoded;
        pos.* += 1;
        if (value == 0) break;
    }
    return true;
}

fn putMqttString(out: []u8, pos: *usize, value: []const u8) bool {
    const field_len = checkedFieldStorageLen(value.len) orelse return false;
    if (pos.* > out.len or out.len - pos.* < field_len) return false;
    out[pos.*] = @intCast((value.len >> 8) & 0xff);
    out[pos.* + 1] = @intCast(value.len & 0xff);
    pos.* += 2;
    @memcpy(out[pos.*..][0..value.len], value);
    pos.* += value.len;
    return true;
}

fn putSlice(out: []u8, pos: *usize, value: []const u8) bool {
    if (pos.* > out.len) return false;
    if (out.len - pos.* < value.len) return false;
    @memcpy(out[pos.*..][0..value.len], value);
    pos.* += value.len;
    return true;
}

fn parseLengthPrefixed(input: []const u8, pos: *usize, frame_end: usize) ParseConnectError!FieldRef {
    if (pos.* > frame_end or frame_end - pos.* < 2) return error.Incomplete;
    const len_offset = pos.*;
    const value_len = (@as(usize, input[pos.*]) << 8) | @as(usize, input[pos.* + 1]);
    pos.* = checkedRangeEnd(pos.*, 2, frame_end) orelse return error.Incomplete;
    if (value_len > frame_end - pos.*) return error.Incomplete;
    const value_offset = pos.*;
    pos.* = checkedRangeEnd(pos.*, value_len, frame_end) orelse return error.Incomplete;
    return .{
        .len_offset = len_offset,
        .value_offset = value_offset,
        .value_len = value_len,
    };
}

fn skipLengthPrefixed(input: []const u8, pos: *usize, frame_end: usize) ParseConnectError!void {
    _ = try parseLengthPrefixed(input, pos, frame_end);
}

fn skipMqtt5Properties(input: []const u8, pos: *usize, frame_end: usize) ParseConnectError!void {
    const props = try decodeMqttVarIntAt(input, pos.*);
    pos.* = checkedRangeEnd(pos.*, props.width, frame_end) orelse return error.Incomplete;
    if (props.value > frame_end - pos.*) return error.Incomplete;
    pos.* = checkedRangeEnd(pos.*, props.value, frame_end) orelse return error.Incomplete;
}

fn parseConnectView(input: []const u8) ParseConnectError!ConnectView {
    if (input.len < 2) return error.Incomplete;
    if (input[0] != 0x10) return error.Malformed;

    const remaining = try decodeMqttVarIntAt(input, 1);
    if (remaining.value > MQTT_MAX_REMAINING_LENGTH) return error.Malformed;
    const header_len = checkedAdd(1, remaining.width) orelse return error.Malformed;
    const frame_len = std.math.add(usize, header_len, remaining.value) catch return error.Malformed;
    if (input.len < frame_len) return error.Incomplete;

    const frame_end = frame_len;
    var pos = header_len;

    const protocol = try parseLengthPrefixed(input, &pos, frame_end);
    const protocol_name = input[protocol.value_offset..][0..protocol.value_len];
    if (!std.mem.eql(u8, protocol_name, "MQTT")) return error.Malformed;
    if (pos >= frame_end) return error.Incomplete;

    const level = input[pos];
    pos = checkedRangeEnd(pos, 1, frame_end) orelse return error.Incomplete;
    const version: MqttVersion = switch (level) {
        4 => .v311,
        5 => .v5,
        else => return error.Malformed,
    };

    if (frame_end - pos < 3) return error.Incomplete;
    const connect_flags_offset = pos;
    const flags = input[pos];
    pos = checkedRangeEnd(pos, 1, frame_end) orelse return error.Incomplete;

    if ((flags & 0x01) != 0) return error.Malformed;
    const will_flag = (flags & 0x04) != 0;
    const username_flag = (flags & 0x80) != 0;
    const password_flag = (flags & 0x40) != 0;
    if (password_flag and !username_flag) return error.Malformed;
    if (!will_flag and (flags & 0x38) != 0) return error.Malformed;

    pos = checkedRangeEnd(pos, 2, frame_end) orelse return error.Incomplete; // keep alive

    if (version == .v5) {
        try skipMqtt5Properties(input, &pos, frame_end);
    }

    const clientid = try parseLengthPrefixed(input, &pos, frame_end);

    if (will_flag) {
        if (version == .v5) {
            try skipMqtt5Properties(input, &pos, frame_end);
        }
        try skipLengthPrefixed(input, &pos, frame_end); // will topic
        try skipLengthPrefixed(input, &pos, frame_end); // will payload
    }

    const username = if (username_flag)
        try parseLengthPrefixed(input, &pos, frame_end)
    else
        null;
    const password = if (password_flag)
        try parseLengthPrefixed(input, &pos, frame_end)
    else
        null;

    if (pos != frame_end) return error.Malformed;

    return .{
        .version = version,
        .frame_len = frame_len,
        .remaining_len = remaining.value,
        .remaining_len_width = remaining.width,
        .connect_flags_offset = connect_flags_offset,
        .clientid = clientid,
        .username = username,
        .password = password,
    };
}

fn dupField(pool: [*c]core.ngx_pool_t, input: []const u8, field: FieldRef) ?ngx_str_t {
    if (field.value_len == 0) return ngx_str_t{ .len = 0, .data = null };
    const mem = core.castPtr(u8, core.ngx_pnalloc(pool, field.value_len)) orelse return null;
    @memcpy(core.slicify(u8, mem, field.value_len), input[field.value_offset..][0..field.value_len]);
    return ngx_str_t{ .len = field.value_len, .data = mem };
}

fn ngxStrSlice(value: ngx_str_t) []const u8 {
    if (value.len == 0 or value.data == core.nullptr(u8)) return "";
    return core.slicify(u8, value.data, value.len);
}

const RewriteValues = struct {
    clientid: ?ngx_str_t = null,
    username: ?ngx_str_t = null,
    password: ?ngx_str_t = null,
};

fn evaluateRewrites(s: [*c]ngx_stream_session_t, scf: *MqttFilterSrvConf) ?RewriteValues {
    var values = RewriteValues{};
    var it = scf.rewrites.iterator();
    while (it.next()) |rewrite| {
        var evaluated = string.ngx_null_str;
        if (vx.ngx_stream_complex_value(s, &rewrite.*.value, &evaluated) != NGX_OK) return null;
        switch (rewrite.*.field) {
            .clientid => values.clientid = evaluated,
            .username => values.username = evaluated,
            .password => values.password = evaluated,
        }
    }
    return values;
}

fn originalFieldSlice(input: []const u8, field: ?FieldRef) ?[]const u8 {
    const f = field orelse return null;
    return input[f.value_offset..][0..f.value_len];
}

fn selectedOptionalField(input: []const u8, field: ?FieldRef, rewrite: ?ngx_str_t) ?[]const u8 {
    if (rewrite) |value| {
        const rewritten = ngxStrSlice(value);
        if (rewritten.len == 0) return null;
        return rewritten;
    }
    return originalFieldSlice(input, field);
}

fn rewriteConnectFrame(pool: [*c]core.ngx_pool_t, input: []const u8, view: ConnectView, values: RewriteValues) ?ngx_str_t {
    const old_header_len = checkedAdd(1, view.remaining_len_width) orelse return null;
    const old_flags = input[view.connect_flags_offset];

    const clientid = if (values.clientid) |value| ngxStrSlice(value) else input[view.clientid.value_offset..][0..view.clientid.value_len];
    const clientid_storage_len = checkedFieldStorageLen(clientid.len) orelse return null;
    const selected_username = selectedOptionalField(input, view.username, values.username);
    const password = selectedOptionalField(input, view.password, values.password);
    const username: ?[]const u8 = selected_username orelse if (password != null) @as([]const u8, "") else null;
    const username_storage_len = if (username) |value| checkedFieldStorageLen(value.len) orelse return null else 0;
    const password_storage_len = if (password) |value| checkedFieldStorageLen(value.len) orelse return null else 0;

    var fields_start = view.frame_len;
    if (view.username) |field| fields_start = @min(fields_start, field.len_offset);
    if (view.password) |field| fields_start = @min(fields_start, field.len_offset);

    const after_clientid = checkedAdd(view.clientid.value_offset, view.clientid.value_len) orelse return null;
    const body_before_clientid = checkedSub(view.clientid.len_offset, old_header_len) orelse return null;
    const body_between_clientid_and_auth = checkedSub(fields_start, after_clientid) orelse return null;

    var new_remaining = checkedAdd(body_before_clientid, clientid_storage_len) orelse return null;
    new_remaining = checkedAdd(new_remaining, body_between_clientid_and_auth) orelse return null;
    new_remaining = checkedAdd(new_remaining, username_storage_len) orelse return null;
    new_remaining = checkedAdd(new_remaining, password_storage_len) orelse return null;
    if (new_remaining > MQTT_MAX_REMAINING_LENGTH) return null;

    const new_header_len = checkedAdd(1, mqttVarIntWidth(new_remaining)) orelse return null;
    const trailing_len = checkedSub(input.len, view.frame_len) orelse return null;
    var out_len = checkedAdd(new_header_len, new_remaining) orelse return null;
    out_len = checkedAdd(out_len, trailing_len) orelse return null;
    if (out_len > MQTT_REWRITE_BUFFER_LIMIT) return null;
    const data = core.castPtr(u8, core.ngx_pnalloc(pool, out_len)) orelse return null;
    const out = core.slicify(u8, data, out_len);

    var pos: usize = 0;
    out[pos] = 0x10;
    pos += 1;
    if (!encodeMqttVarInt(out, &pos, new_remaining)) return null;
    if (!putSlice(out, &pos, input[old_header_len..view.clientid.len_offset])) return null;
    if (!putMqttString(out, &pos, clientid)) return null;
    if (!putSlice(out, &pos, input[after_clientid..fields_start])) return null;
    if (username) |value| if (!putMqttString(out, &pos, value)) return null;
    if (password) |value| if (!putMqttString(out, &pos, value)) return null;
    if (!putSlice(out, &pos, input[view.frame_len..])) return null;
    if (pos != out_len) return null;

    const old_flags_delta = checkedSub(view.connect_flags_offset, old_header_len) orelse return null;
    const new_flags_offset = checkedAdd(new_header_len, old_flags_delta) orelse return null;
    if (new_flags_offset >= out.len) return null;
    var new_flags = old_flags;
    if (username != null) {
        new_flags |= 0x80;
    } else {
        new_flags &= ~@as(u8, 0x80);
    }
    if (password != null) {
        new_flags |= 0x40;
        new_flags |= 0x80;
    } else {
        new_flags &= ~@as(u8, 0x40);
    }
    out[new_flags_offset] = new_flags;

    return ngx_str_t{ .len = out_len, .data = data };
}

fn checkedBufferedLen(existing_len: usize, chunk_len: usize) AppendBufferError!usize {
    const len = std.math.add(usize, existing_len, chunk_len) catch return error.Overflow;
    if (len > MQTT_REWRITE_BUFFER_LIMIT) return error.Overflow;
    return len;
}

fn appendBuffered(pool: [*c]core.ngx_pool_t, existing: ngx_str_t, chunk: ngx_str_t) AppendBufferError!ngx_str_t {
    if (existing.len == 0) return chunk;
    if (chunk.len == 0) return existing;

    const len = try checkedBufferedLen(existing.len, chunk.len);
    const data = core.castPtr(u8, core.ngx_pnalloc(pool, len)) orelse return error.NoMemory;
    const out = core.slicify(u8, data, len);
    @memcpy(out[0..existing.len], ngxStrSlice(existing));
    @memcpy(out[existing.len..][0..chunk.len], ngxStrSlice(chunk));
    return ngx_str_t{ .len = len, .data = data };
}

fn drainChain(in: [*c]ngx_chain_t) void {
    var cl = in;
    while (cl != core.nullptr(ngx_chain_t)) : (cl = cl.*.next) {
        const b = cl.*.buf;
        if (b == core.nullptr(ngx.buf.ngx_buf_t)) continue;
        if (ngx.buf.ngx_buf_in_memory(b)) {
            b.*.pos = b.*.last;
        }
        if (b.*.flags.in_file) {
            b.*.file_pos = b.*.file_last;
        }
    }
}

fn chainFromString(pool: [*c]core.ngx_pool_t, value: ngx_str_t) ?[*c]ngx_chain_t {
    const cl = core.ngz_pcalloc_c(ngx_chain_t, pool) orelse return null;
    const b = core.ngz_pcalloc_c(ngx.buf.ngx_buf_t, pool) orelse return null;
    b.*.start = value.data;
    b.*.pos = value.data;
    b.*.last = value.data + value.len;
    b.*.end = value.data + value.len;
    b.*.flags.memory = true;
    b.*.flags.flush = true;
    cl.*.buf = b;
    cl.*.next = core.nullptr(ngx_chain_t);
    return cl;
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

    const ctx = getSessionCtx(s) orelse blk: {
        const ctx = core.ngz_pcalloc_c(MqttSessionCtx, s.*.connection.*.pool) orelse return NGX_ERROR;
        setSessionCtx(s, ctx);
        break :blk ctx;
    };

    if (ctx.*.parsed == 1) return NGX_OK;

    const b = s.*.connection.*.buffer;
    if (b == core.nullptr(ngx.buf.ngx_buf_t) or b.*.pos == null or b.*.last == null) {
        return NGX_AGAIN;
    }

    const len = @intFromPtr(b.*.last) - @intFromPtr(b.*.pos);
    const data = core.slicify(u8, b.*.pos, len);
    const view = parseConnectView(data) catch |err| switch (err) {
        error.Incomplete => return NGX_AGAIN,
        error.Malformed => {
            logStream(s, log.NGX_LOG_WARN, "mqtt preread malformed CONNECT");
            ctx.*.parsed = 1;
            return NGX_OK;
        },
    };

    ctx.*.clientid = dupField(s.*.connection.*.pool, data, view.clientid) orelse return NGX_ERROR;
    if (view.username) |username| {
        ctx.*.username = dupField(s.*.connection.*.pool, data, username) orelse return NGX_ERROR;
    }
    ctx.*.parsed = 1;
    return NGX_OK;
}

export fn ngx_stream_mqtt_filter(
    s: [*c]ngx_stream_session_t,
    in: [*c]ngx_chain_t,
    from_upstream: ngx_uint_t,
) callconv(.c) ngx_int_t {
    if (from_upstream == 0 and in != core.nullptr(ngx_chain_t)) {
        if (getFilterSrvConf(s)) |scf| {
            if (scf.*.enabled == 1 and scf.*.rewrites.size() > 0) {
                const fctx = getFilterCtx(s) orelse blk: {
                    const ctx = core.ngz_pcalloc_c(MqttFilterCtx, s.*.connection.*.pool) orelse return NGX_ERROR;
                    setFilterCtx(s, ctx);
                    break :blk ctx;
                };

                if (fctx.*.processed != 1) {
                    const chunk = ngx.buf.ngz_chain_content(in, s.*.connection.*.pool) catch {
                        logStream(s, log.NGX_LOG_ERR, "mqtt rewrite failed to read input chain");
                        return NGX_ERROR;
                    };
                    const content = appendBuffered(s.*.connection.*.pool, fctx.*.buffered, chunk) catch |err| switch (err) {
                        error.Overflow => {
                            logStream(s, log.NGX_LOG_ERR, "mqtt rewrite buffer exceeded limit");
                            return NGX_ERROR;
                        },
                        error.NoMemory => {
                            logStream(s, log.NGX_LOG_ERR, "mqtt rewrite buffer allocation failed");
                            return NGX_ERROR;
                        },
                    };
                    const input = ngxStrSlice(content);
                    const view = parseConnectView(input) catch |err| switch (err) {
                        error.Incomplete => {
                            fctx.*.buffered = content;
                            drainChain(in);
                            return NGX_OK;
                        },
                        error.Malformed => {
                            logStream(s, log.NGX_LOG_ERR, "mqtt rewrite malformed CONNECT");
                            return NGX_ERROR;
                        },
                    };
                    const values = evaluateRewrites(s, scf) orelse {
                        logStream(s, log.NGX_LOG_ERR, "mqtt rewrite complex value evaluation failed");
                        return NGX_ERROR;
                    };
                    const rewritten = rewriteConnectFrame(s.*.connection.*.pool, input, view, values) orelse {
                        logStream(s, log.NGX_LOG_ERR, "mqtt CONNECT rewrite exceeded limits or allocation failed");
                        return NGX_ERROR;
                    };
                    const out = chainFromString(s.*.connection.*.pool, rewritten) orelse {
                        logStream(s, log.NGX_LOG_ERR, "mqtt rewrite output chain allocation failed");
                        return NGX_ERROR;
                    };
                    fctx.*.processed = 1;
                    fctx.*.buffered = string.ngx_null_str;
                    drainChain(in);
                    if (ngx_stream_mqtt_next_filter) |next| {
                        return next(s, out, from_upstream);
                    }
                    return NGX_OK;
                }
            }
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

fn appendMqttString(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try list.append(allocator, @intCast((value.len >> 8) & 0xff));
    try list.append(allocator, @intCast(value.len & 0xff));
    try list.appendSlice(allocator, value);
}

fn appendRemainingLength(list: *std.ArrayList(u8), allocator: std.mem.Allocator, len: usize) !void {
    var value = len;
    while (true) {
        var encoded: u8 = @intCast(value % 128);
        value /= 128;
        if (value > 0) encoded |= 0x80;
        try list.append(allocator, encoded);
        if (value == 0) break;
    }
}

fn buildConnectPacket(allocator: std.mem.Allocator, version: MqttVersion, clientid: []const u8, username: ?[]const u8, password: ?[]const u8) ![]u8 {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);

    try appendMqttString(&body, allocator, "MQTT");
    try body.append(allocator, if (version == .v311) 4 else 5);
    var flags: u8 = 0x02;
    if (username != null) flags |= 0x80;
    if (password != null) flags |= 0x40;
    try body.append(allocator, flags);
    try body.appendSlice(allocator, &.{ 0x00, 0x3c });
    if (version == .v5) try body.append(allocator, 0x00);
    try appendMqttString(&body, allocator, clientid);
    if (username) |u| try appendMqttString(&body, allocator, u);
    if (password) |p| try appendMqttString(&body, allocator, p);

    var packet = std.ArrayList(u8).empty;
    try packet.append(allocator, 0x10);
    try appendRemainingLength(&packet, allocator, body.items.len);
    try packet.appendSlice(allocator, body.items);
    return packet.toOwnedSlice(allocator);
}

test "MQTT CONNECT parser extracts MQTT 3.1.1 identity fields" {
    const packet = try buildConnectPacket(std.testing.allocator, .v311, "client-a", "alice", "secret");
    defer std.testing.allocator.free(packet);

    const view = try parseConnectView(packet);
    try std.testing.expectEqual(MqttVersion.v311, view.version);
    try std.testing.expectEqual(packet.len, view.frame_len);
    try std.testing.expectEqualSlices(u8, "client-a", packet[view.clientid.value_offset..][0..view.clientid.value_len]);
    try std.testing.expect(view.username != null);
    try std.testing.expectEqualSlices(u8, "alice", packet[view.username.?.value_offset..][0..view.username.?.value_len]);
    try std.testing.expect(view.password != null);
    try std.testing.expectEqualSlices(u8, "secret", packet[view.password.?.value_offset..][0..view.password.?.value_len]);
}

test "MQTT CONNECT parser extracts MQTT 5 identity fields with properties" {
    const packet = try buildConnectPacket(std.testing.allocator, .v5, "client-v5", "bob", null);
    defer std.testing.allocator.free(packet);

    const view = try parseConnectView(packet);
    try std.testing.expectEqual(MqttVersion.v5, view.version);
    try std.testing.expectEqualSlices(u8, "client-v5", packet[view.clientid.value_offset..][0..view.clientid.value_len]);
    try std.testing.expect(view.username != null);
    try std.testing.expectEqualSlices(u8, "bob", packet[view.username.?.value_offset..][0..view.username.?.value_len]);
    try std.testing.expect(view.password == null);
}

test "MQTT CONNECT parser reports incomplete and malformed frames" {
    const packet = try buildConnectPacket(std.testing.allocator, .v311, "client-a", null, null);
    defer std.testing.allocator.free(packet);

    for (0..packet.len) |prefix_len| {
        try std.testing.expectError(error.Incomplete, parseConnectView(packet[0..prefix_len]));
    }

    var bad_type = try std.testing.allocator.dupe(u8, packet);
    defer std.testing.allocator.free(bad_type);
    bad_type[0] = 0x30;
    try std.testing.expectError(error.Malformed, parseConnectView(bad_type));

    var bad_flags = try std.testing.allocator.dupe(u8, packet);
    defer std.testing.allocator.free(bad_flags);
    const view = try parseConnectView(bad_flags);
    bad_flags[view.connect_flags_offset] |= 0x01;
    try std.testing.expectError(error.Malformed, parseConnectView(bad_flags));

    try std.testing.expectError(error.Malformed, decodeMqttVarIntAt(&.{ 0xff, 0xff, 0xff, 0xff, 0x00 }, 0));
    try std.testing.expectError(error.Malformed, parseConnectView(&.{ 0x10, 0xff, 0xff, 0xff, 0xff }));
}

fn expectFieldInFrame(field: FieldRef, frame_len: usize) !void {
    const len_end = try std.math.add(usize, field.len_offset, 2);
    const value_end = try std.math.add(usize, field.value_offset, field.value_len);
    try std.testing.expect(len_end <= frame_len);
    try std.testing.expect(value_end <= frame_len);
    try std.testing.expect(field.value_offset >= len_end);
}

test "MQTT CONNECT parser fuzz-like malformed inputs stay bounded" {
    var prng = std.Random.DefaultPrng.init(0x6d_71_74_74);
    var buf: [128]u8 = undefined;

    for (0..512) |i| {
        const len = i % (buf.len + 1);
        prng.random().bytes(buf[0..len]);

        const view = parseConnectView(buf[0..len]) catch |err| {
            try std.testing.expect(err == error.Incomplete or err == error.Malformed);
            continue;
        };

        try std.testing.expect(view.frame_len <= len);
        try std.testing.expect(view.remaining_len <= MQTT_MAX_REMAINING_LENGTH);
        try std.testing.expect(view.connect_flags_offset < view.frame_len);
        try expectFieldInFrame(view.clientid, view.frame_len);
        if (view.username) |field| try expectFieldInFrame(field, view.frame_len);
        if (view.password) |field| try expectFieldInFrame(field, view.frame_len);
    }
}

test "MQTT rewrite buffer limit is explicit" {
    try std.testing.expectEqual(@as(usize, MQTT_REWRITE_BUFFER_LIMIT), try checkedBufferedLen(MQTT_REWRITE_BUFFER_LIMIT - 1, 1));
    try std.testing.expectError(error.Overflow, checkedBufferedLen(MQTT_REWRITE_BUFFER_LIMIT, 1));
    try std.testing.expectError(error.Overflow, checkedBufferedLen(std.math.maxInt(usize), 1));
}

test "MQTT CONNECT rewrite updates identity fields and flags" {
    const packet = try buildConnectPacket(std.testing.allocator, .v311, "client-a", "alice", null);
    defer std.testing.allocator.free(packet);

    const nlog = core.ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = core.ngx_create_pool(4096, nlog);
    defer core.ngx_destroy_pool(pool);

    const clientid = string.ngx_string("client-a:127.0.0.1");
    const username = string.ngx_string("alice@edge-a");
    const password = string.ngx_string("broker-local-secret");
    const rewritten = rewriteConnectFrame(pool, packet, try parseConnectView(packet), .{
        .clientid = clientid,
        .username = username,
        .password = password,
    }).?;

    const out = ngxStrSlice(rewritten);
    const view = try parseConnectView(out);
    try std.testing.expectEqualSlices(u8, "client-a:127.0.0.1", out[view.clientid.value_offset..][0..view.clientid.value_len]);
    try std.testing.expect(view.username != null);
    try std.testing.expectEqualSlices(u8, "alice@edge-a", out[view.username.?.value_offset..][0..view.username.?.value_len]);
    try std.testing.expect(view.password != null);
    try std.testing.expectEqualSlices(u8, "broker-local-secret", out[view.password.?.value_offset..][0..view.password.?.value_len]);
    try std.testing.expect((out[view.connect_flags_offset] & 0xc0) == 0xc0);
}

test "MQTT CONNECT rewrite keeps auth flags valid when optional fields change" {
    const nlog = core.ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = core.ngx_create_pool(8192, nlog);
    defer core.ngx_destroy_pool(pool);

    const no_auth = try buildConnectPacket(std.testing.allocator, .v311, "client-a", null, null);
    defer std.testing.allocator.free(no_auth);
    const add_password = rewriteConnectFrame(pool, no_auth, try parseConnectView(no_auth), .{
        .password = string.ngx_string("secret"),
    }).?;
    const add_password_out = ngxStrSlice(add_password);
    const add_password_view = try parseConnectView(add_password_out);
    try std.testing.expect(add_password_view.username != null);
    try std.testing.expectEqual(@as(usize, 0), add_password_view.username.?.value_len);
    try std.testing.expect(add_password_view.password != null);
    try std.testing.expectEqualSlices(u8, "secret", add_password_out[add_password_view.password.?.value_offset..][0..add_password_view.password.?.value_len]);

    const auth = try buildConnectPacket(std.testing.allocator, .v311, "client-a", "alice", "secret");
    defer std.testing.allocator.free(auth);
    const empty = string.ngx_string("");
    const remove_password = rewriteConnectFrame(pool, auth, try parseConnectView(auth), .{
        .password = empty,
    }).?;
    const remove_password_out = ngxStrSlice(remove_password);
    const remove_password_view = try parseConnectView(remove_password_out);
    try std.testing.expect(remove_password_view.username != null);
    try std.testing.expect(remove_password_view.password == null);
    try std.testing.expectEqualSlices(u8, "alice", remove_password_out[remove_password_view.username.?.value_offset..][0..remove_password_view.username.?.value_len]);

    const remove_both = rewriteConnectFrame(pool, auth, try parseConnectView(auth), .{
        .username = empty,
        .password = empty,
    }).?;
    const remove_both_view = try parseConnectView(ngxStrSlice(remove_both));
    try std.testing.expect(remove_both_view.username == null);
    try std.testing.expect(remove_both_view.password == null);
}

test "MQTT CONNECT rewrite preserves MQTT 5 properties and will fields" {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(std.testing.allocator);

    try appendMqttString(&body, std.testing.allocator, "MQTT");
    try body.append(std.testing.allocator, 5);
    try body.append(std.testing.allocator, 0x86); // clean start, will flag, username
    try body.appendSlice(std.testing.allocator, &.{ 0x00, 0x3c });
    try body.appendSlice(std.testing.allocator, &.{ 0x03, 0x21, 0x00, 0x2a }); // CONNECT properties
    try appendMqttString(&body, std.testing.allocator, "client-v5");
    try body.appendSlice(std.testing.allocator, &.{ 0x02, 0x18, 0x01 }); // Will properties
    try appendMqttString(&body, std.testing.allocator, "will/topic");
    try appendMqttString(&body, std.testing.allocator, "payload");
    try appendMqttString(&body, std.testing.allocator, "erin");

    var packet = std.ArrayList(u8).empty;
    defer packet.deinit(std.testing.allocator);
    try packet.append(std.testing.allocator, 0x10);
    try appendRemainingLength(&packet, std.testing.allocator, body.items.len);
    try packet.appendSlice(std.testing.allocator, body.items);

    const original = packet.items;
    const original_view = try parseConnectView(original);

    const nlog = core.ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = core.ngx_create_pool(4096, nlog);
    defer core.ngx_destroy_pool(pool);

    const rewritten = rewriteConnectFrame(pool, original, original_view, .{
        .username = string.ngx_string("erin@edge-a"),
    }).?;
    const out = ngxStrSlice(rewritten);
    const out_view = try parseConnectView(out);

    const original_header_len = 1 + original_view.remaining_len_width;
    const out_header_len = 1 + out_view.remaining_len_width;
    try std.testing.expectEqualSlices(
        u8,
        original[original_header_len..original_view.clientid.len_offset],
        out[out_header_len..out_view.clientid.len_offset],
    );

    const original_after_clientid = original_view.clientid.value_offset + original_view.clientid.value_len;
    const out_after_clientid = out_view.clientid.value_offset + out_view.clientid.value_len;
    try std.testing.expectEqualSlices(
        u8,
        original[original_after_clientid..original_view.username.?.len_offset],
        out[out_after_clientid..out_view.username.?.len_offset],
    );

    try std.testing.expectEqualSlices(u8, "erin@edge-a", out[out_view.username.?.value_offset..][0..out_view.username.?.value_len]);
}
