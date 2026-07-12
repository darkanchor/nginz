const std = @import("std");
const ngx = @import("ngx");

const buf = ngx.buf;
const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const file = ngx.file;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;

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
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_table_elt_t = ngx.hash.ngx_table_elt_t;
const ngx_http_request_t = http.ngx_http_request_t;

const ngx_string = ngx.string.ngx_string;
const NList = ngx.list.NList;
const NChain = ngx.buf.NChain;
const NArray = ngx.array.NArray;
const NTimer = ngx.event.NTimer;
const NSubrequest = http.NSubrequest;

extern var ngx_http_core_module: ngx_module_t;

const echoz_command_type = enum(ngx_int_t) {
    echoz,
    echozn,
    echoz_duplicate,
    echoz_flush,
    echoz_sleep,
    echoz_location_async,
    echoz_request_body,
    echoz_read_request_body,
    echoz_exec,
    echoz_before_body,
    echoz_after_body,
    echoz_status,
    echoz_header,
};

const echoz_parameter = extern struct {
    raw: ngx_str_t,
    variables: ngx_uint_t,
    lengths: [*c]ngx_array_t,
    values: [*c]ngx_array_t,
};

const echoz_command = extern struct {
    type: echoz_command_type,
    params: NArray(echoz_parameter),
};

const ZError = error{
    DECLINE,
    BODY_ERROR,
    REDIRECTING,
    SCRIPT_ERROR,
    HEADER_ERROR,
    READING_BODY,
    WAITING_TIMER,
    COMMAND_ERROR,
};

const loc_conf = extern struct {
    headers: NArray(echoz_command),
    content_handlers: NArray(echoz_command),
    prepend_filters: NArray(echoz_command),
    append_filters: NArray(echoz_command),
};

const space_str: ngx_str_t = ngx_string(" ");
const newline_str: ngx_str_t = ngx_string("\n");

const echoz_context = extern struct {
    chain: NChain,
    header_sent: ngx_flag_t,
    content_ready: ngx_flag_t,
    iterator: NArray(echoz_command).IteratorType,
};

const echoz_filter_context = extern struct {
    done_first: ngx_flag_t,
    header_set: ngx_flag_t,
};

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    var vs = [_]http.ngx_http_variable_t{http.ngx_http_variable_t{
        .name = ngx.string.ngx_string("echoz_request_body"),
        .set_handler = null,
        .get_handler = ngx_http_echoz_request_body_variable,
        .data = 0,
        .flags = http.NGX_HTTP_VAR_NOCACHEABLE,
        .index = 0,
    }};
    for (&vs) |*v| {
        const x = http.ngx_http_add_variable(cf, &v.name, v.flags);
        x.*.get_handler = v.get_handler;
        x.*.data = v.data;
    }
    return NGX_OK;
}

fn postconfiguration_filter(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    _ = cf;
    ngx_http_echoz_next_header_filter = http.ngx_http_top_header_filter;
    http.ngx_http_top_header_filter = ngx_http_echoz_header_filter;

    ngx_http_echoz_next_output_body_filter = http.ngx_http_top_body_filter;
    http.ngx_http_top_body_filter = ngx_http_echoz_output_body_filter;
    return NGX_OK;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(loc_conf, cf.*.pool)) |p| {
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
    if (core.castPtr(loc_conf, child)) |ch| {
        if (ch.*.content_handlers.inited()) {
            if (core.castPtr(
                http.ngx_http_core_loc_conf_t,
                conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
            )) |clcf| {
                clcf.*.handler = ngx_http_echoz_handler;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

fn parse_uri(
    r: [*c]ngx_http_request_t,
    ps: *const NArray(ngx_str_t),
) ![*c]ngx_str_t {
    if (core.ngz_pcalloc_n(2, ngx_str_t, r.*.pool)) |s2| {
        s2[0] = ps.at(0).?.*;
        var flags: ngx_uint_t = 0;
        if (http.ngx_http_parse_unsafe_uri(r, s2, s2 + 1, &flags) != NGX_OK) {
            return ZError.COMMAND_ERROR;
        }
        if (s2[1].len == 0 and ps.size() > 2) { // there is a space
            s2[1] = ps.at(2).?.*;
        }
        return s2;
    }
    return core.NError.OOM;
}

fn atof(s: ngx_str_t, precision: ngx_uint_t) ngx_msec_t {
    var t2 = [2]ngx_uint_t{ 0, 0 };
    var i: usize = 0;
    var p: ngx_uint_t = 0;
    for (core.slicify(u8, s.data, s.len)) |c| {
        if (p > @min(precision, 3)) {
            break;
        }
        if (c >= '0' and c <= '9') {
            t2[i] = t2[i] * 10 + c - '0';
        }
        if (c == '.' and i == 0) {
            i += 1;
        }
        if (i > 0) {
            p += 1;
        }
    }
    for (0..4 - p) |_| {
        t2[1] *= 10;
    }
    return t2[0] * 1000 + t2[1];
}

fn atoz(s: [*c]ngx_str_t) ZError!ngx_uint_t {
    var x: ngx_uint_t = 0;
    for (core.slicify(u8, s.*.data, s.*.len)) |c| {
        switch (c) {
            '_' => continue,
            '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => x = x * 10 + c - '0',
            else => return ZError.COMMAND_ERROR,
        }
    }
    return x;
}

fn send_header(
    r: [*c]ngx_http_request_t,
    ctx: [*c]echoz_context,
) ZError!void {
    if (ctx.*.header_sent == 0) {
        r.*.headers_out.status = http.NGX_HTTP_OK;
        http.ngx_http_clear_content_length(r);
        http.ngx_http_clear_accept_ranges(r);

        if (http.ngx_http_send_header(r) != NGX_OK) {
            return ZError.HEADER_ERROR;
        }
        ctx.*.header_sent = 1;
    }
}

fn send_body(
    r: [*c]ngx_http_request_t,
    ctx: [*c]echoz_context,
    chain: [*c]ngx_chain_t,
) ZError!void {
    try send_header(r, ctx);
    if (r.*.flags1.header_only) {
        if (r.*.flags1.background) {
            return;
        }
        if (http.ngx_http_send_special(r, http.NGX_HTTP_LAST) != NGX_OK) {
            return ZError.BODY_ERROR;
        }
        return;
    }
    if (chain != core.nullptr(ngx_chain_t)) {
        if (http.ngx_http_output_filter(r, chain) != NGX_OK) {
            return ZError.BODY_ERROR;
        }
    } else {
        if (http.ngx_http_send_special(r, http.NGX_HTTP_LAST) != NGX_OK) {
            return ZError.BODY_ERROR;
        }
    }
}

inline fn write_buf(
    it: *NArray(ngx_str_t).IteratorType,
    b: [*c]ngx_buf_t,
) void {
    while (it.next()) |s| {
        core.ngz_memcpy(b.*.last, s.*.data, s.*.len);
        b.*.last += s.*.len;
    }
}

inline fn set_type(offset: ngx_int_t) echoz_command_type {
    return @enumFromInt(@intFromEnum(echoz_command_type.echoz) + offset);
}

fn map(
    ps: NArray(echoz_parameter),
    r: [*c]ngx_http_request_t,
    total_length: *ngx_uint_t,
) !NArray(ngx_str_t) {
    var ss = try NArray(ngx_str_t).init(r.*.pool, ps.size());
    var i: ngx_uint_t = 0;
    while (i < ps.size()) : (i += 1) {
        if (ps.at(i)) |p0| {
            const s0 = try ss.append();
            if (p0.*.variables == 0) {
                s0.* = p0.*.raw;
            }
            if (p0.*.variables > 0 and http.ngx_http_script_run(
                r,
                s0,
                p0.*.lengths.*.elts,
                0,
                p0.*.values.*.elts,
            ) == core.nullptr(core.u_char)) {
                return ZError.SCRIPT_ERROR;
            }
            total_length.* += s0.*.len;
            if (i + 1 < ps.size()) {
                const space = try ss.append();
                space.* = space_str;
                total_length.* += 1;
            }
        }
    }
    return ss;
}

fn echoz_exec_command(
    cmd: [*c]echoz_command,
    ctx: [*c]echoz_context,
    r: [*c]ngx_http_request_t,
    c: [*c]ngx_chain_t,
) !void {
    var total_length: ngx_uint_t = 0;
    const parameters = try map(cmd.*.params, r, &total_length);
    switch (cmd.*.type) {
        .echoz => {
            const last = try ctx.*.chain.allocNStr(parameters, c);
            _ = try ctx.*.chain.allocStr(newline_str, last);
        },
        .echozn => _ = try ctx.*.chain.allocNStr(parameters, c),
        .echoz_duplicate => {
            var it = parameters.iterator();
            if (it.next()) |first| {
                const n = try atoz(first);
                const len = total_length - first.*.len - 1;
                const cl = try ctx.*.chain.alloc(n * len, c);
                _ = it.next(); //skip the space
                for (0..n) |_| {
                    write_buf(&it, cl.*.buf);
                    it.resetN(2);
                }
            }
        },
        .echoz_flush => {
            if (http.ngx_http_send_special(r, http.NGX_HTTP_FLUSH) != NGX_OK) {
                return ZError.BODY_ERROR;
            }
        },
        .echoz_sleep => {
            var it = parameters.iterator();
            if (it.next()) |delay| {
                try NTimer.activate(r, ngx_http_echoz_handler, atof(delay.*, 3));
                return ZError.WAITING_TIMER;
            }
        },
        .echoz_location_async => {
            const s2 = try parse_uri(r, &parameters);
            const sr = try NSubrequest.createWithFlags(r, s2, s2 + 1, NSubrequest.BACKGROUND);
            sr.*.header_in = r.*.header_in;
            sr.*.flags1.header_only = true;
        },
        .echoz_request_body => {
            if (r.*.request_body != core.nullptr(http.ngx_http_request_body_t)) {
                var bufs = r.*.request_body.*.bufs;
                const it: [*c][*c]ngx_chain_t = &bufs;
                var cl: [*c]ngx_chain_t = c;
                while (buf.ngz_chain_iterate(it)) |b| {
                    if (b == core.nullptr(ngx_buf_t) or buf.ngx_buf_special(b)) {
                        continue;
                    }
                    cl = try ctx.*.chain.allocBuf(cl);
                    cl.*.buf.* = b.*;
                    cl.*.buf.*.flags.last_buf = false;
                    cl.*.buf.*.flags.last_in_chain = false;
                }
            }
        },
        .echoz_read_request_body => {
            const rc = http.ngx_http_read_client_request_body(r, ngx_http_echoz_client_body_handler);
            return if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) ZError.BODY_ERROR else ZError.READING_BODY;
        },
        .echoz_exec => {
            const s2 = try parse_uri(r, &parameters);
            r.*.write_event_handler = http.ngx_http_request_empty_handler;
            if (s2[0].data[0] == '@') {
                if (r.*.ctx != core.nullptr(?*anyopaque)) {
                    @memset(core.slicify(?*anyopaque, r.*.ctx, http.ngx_http_max_module), null);
                }
                if (http.ngx_http_named_location(r, s2) == core.NGX_DONE) {
                    return ZError.REDIRECTING;
                }
            } else {
                if (http.ngx_http_internal_redirect(r, s2, s2 + 1) == core.NGX_DONE) {
                    return ZError.REDIRECTING;
                }
            }
            return ZError.COMMAND_ERROR;
        },
        else => return ZError.COMMAND_ERROR,
    }
}

fn echoz_handle(r: [*c]ngx_http_request_t) !ngx_int_t {
    if (core.castPtr(
        loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_echoz_module),
    )) |lccf| {
        const ctx = try http.ngz_http_get_module_ctx(
            echoz_context,
            r,
            &ngx_http_echoz_module,
        );
        var out = buf.ngx_chain_t{
            .buf = core.nullptr(ngx_buf_t),
            .next = core.nullptr(ngx_chain_t),
        };

        if (ctx.*.content_ready == 0) {
            ctx.*.iterator = lccf.*.content_handlers.iterator();
            ctx.*.chain = NChain.init(r.*.pool);
            ctx.*.header_sent = 0;
            ctx.*.content_ready = 1;
        }

        while (ctx.*.iterator.next()) |cmd| {
            try echoz_exec_command(cmd, ctx, r, &out);
            if (out.next != core.nullptr(ngx_chain_t)) {
                try send_body(r, ctx, out.next);
                out.next = core.nullptr(ngx_chain_t);
            }
        }
        try send_body(r, ctx, out.next);
    }
    return NGX_OK;
}

fn echoz_header_filter(
    r: [*c]ngx_http_request_t,
    lccf: [*c]loc_conf,
) !void {
    var it = lccf.*.headers.iterator();
    while (it.next()) |cmd| {
        var total_length: ngx_uint_t = 0;
        var parameters = try map(cmd.*.params, r, &total_length);
        const ps = parameters.slice();
        switch (cmd.*.type) {
            .echoz_header => {
                var headers = NList(ngx_table_elt_t).init0(&r.*.headers_out.headers);
                const h = try headers.append();
                h.*.hash = r.*.header_hash;
                h.*.key = ps[0];
                h.*.value = ps[2]; // skip a space
                h.*.lowcase_key = ps[0].data;
            },
            .echoz_status => {
                r.*.headers_out.status = try atoz(&ps[0]);
                r.*.headers_out.status_line = try ngx.string.concat_string_from_pool(
                    ps[0..],
                    "",
                    r.*.pool,
                );
            },
            else => return ZError.HEADER_ERROR,
        }
    }
}

export fn ngx_http_echoz_header_filter(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    if (core.castPtr(
        loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_echoz_filter_module),
    )) |lccf| {
        const ctx = http.ngz_http_get_module_ctx(
            echoz_filter_context,
            r,
            &ngx_http_echoz_filter_module,
        ) catch return NGX_ERROR;

        if (ctx.*.header_set == 0 and lccf.*.headers.inited()) {
            echoz_header_filter(r, lccf) catch return NGX_ERROR;
            http.ngx_http_clear_content_length(r);
            http.ngx_http_clear_accept_ranges(r);
            ctx.*.header_set = 1;
        }
    }
    if (ngx_http_echoz_next_header_filter) |filter| {
        return filter(r);
    }
    return NGX_OK;
}

fn echoz_filter(
    r: [*c]ngx_http_request_t,
    c: [*c]ngx_chain_t,
) ![*c]ngx_chain_t {
    var out = ngx_chain_t{ .buf = core.nullptr(ngx_buf_t), .next = c };
    if (core.castPtr(
        loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_echoz_filter_module),
    )) |lccf| {
        const ctx = try http.ngz_http_get_module_ctx(
            echoz_filter_context,
            r,
            &ngx_http_echoz_filter_module,
        );

        if (ctx.*.done_first == 0 and
            lccf.*.prepend_filters.inited())
        {
            var it = lccf.*.prepend_filters.iterator();
            var last: [*c]ngx_chain_t = &out;
            var chain = NChain.init(r.*.pool);
            while (it.next()) |cmd| {
                var total_length: ngx_uint_t = 0;
                const parameters = try map(cmd.*.params, r, &total_length);
                last = try chain.allocNStr(parameters, last);
            }
            last.*.next = c;
            ctx.*.done_first = 1;
        }

        if (lccf.*.append_filters.inited()) {
            var is_last = false;
            var last = c;
            var cl = last;
            while (last != core.nullptr(ngx_chain_t)) {
                if (last.*.buf.*.flags.last_buf or
                    last.*.buf.*.flags.last_in_chain)
                {
                    is_last = true;
                    break;
                }
                cl = last;
                last = last.*.next;
            }

            if (is_last) {
                if (last.*.buf.*.last > last.*.buf.*.pos) {
                    last.*.buf.*.flags.last_buf = false;
                } else {
                    last = cl;
                }
                var chain = NChain.init(r.*.pool);
                var it = lccf.*.append_filters.iterator();
                while (it.next()) |cmd| {
                    var total_length: ngx_uint_t = 0;
                    const parameters = try map(cmd.*.params, r, &total_length);
                    last = try chain.allocNStr(parameters, last);
                }
                last.*.buf.*.flags.last_buf = (r == r.*.main);
            }
        }
    }
    return out.next;
}

export fn ngx_http_echoz_output_body_filter(
    r: [*c]ngx_http_request_t,
    c: [*c]ngx_chain_t,
) callconv(.c) ngx_int_t {
    const cl = echoz_filter(r, c) catch c;
    if (ngx_http_echoz_next_output_body_filter) |filter| {
        return filter(r, cl);
    }
    return NGX_OK;
}

export fn ngx_http_echoz_request_body_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]http.ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    v.*.flags.not_found = true;

    const request_body = r.*.request_body;
    if (request_body == core.nullptr(http.ngx_http_request_body_t)) {
        return NGX_OK;
    }
    if (request_body.*.bufs == core.nullptr(buf.ngx_chain_t)) {
        return NGX_OK;
    }
    // ngz_chain_content only joins in-memory buffers.  A temp-file-backed
    // request body must not be exposed as a partial value.
    if (request_body.*.temp_file != core.nullptr(file.ngx_temp_file_t)) {
        return NGX_OK;
    }
    const body = buf.ngz_chain_content(
        request_body.*.bufs,
        r.*.pool,
    ) catch return NGX_ERROR;
    if (body.len > 0) {
        v.*.data = body.data;
        v.*.flags.len = @intCast(body.len);
        v.*.flags.valid = true;
        v.*.flags.no_cacheable = false;
        v.*.flags.not_found = false;
    }
    return NGX_OK;
}

export fn ngx_http_echoz_client_body_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) void {
    http.ngx_http_finalize_request(r, ngx_http_echoz_handler(r));
}

export fn ngx_http_echoz_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    if (echoz_handle(r)) |rc| {
        return rc;
    } else |e| {
        return switch (e) {
            ZError.WAITING_TIMER,
            ZError.READING_BODY,
            ZError.REDIRECTING,
            => core.NGX_DONE,
            else => http.NGX_HTTP_INTERNAL_SERVER_ERROR,
        };
    }
}

fn echoz_init_parameters(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    cs: *NArray(echoz_command),
) [*c]u8 {
    if (!cs.*.inited()) {
        cs.* = NArray(echoz_command).init(cf.*.pool, 1) catch return conf.NGX_CONF_ERROR;
    }

    const echoz = cs.*.append() catch return conf.NGX_CONF_ERROR;
    echoz.*.type = set_type(@intCast(cmd.*.offset));
    echoz.*.params = NArray(echoz_parameter).init(cf.*.pool, 1) catch return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    while (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        ngx.log.ngx_http_conf_debug(cf, "%V", .{arg});
        const param = echoz.*.params.append() catch return conf.NGX_CONF_ERROR;
        param.*.raw = arg.*;
        param.*.lengths = core.nullptr(ngx_array_t);
        param.*.values = core.nullptr(ngx_array_t);
        param.*.variables = conf.ngz_http_conf_variables_parse(
            cf,
            arg,
            &param.*.lengths,
            &param.*.values,
        ) catch return conf.NGX_CONF_ERROR;
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_echoz(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    if (core.castPtr(loc_conf, loc)) |lccf| {
        switch (cmd.*.offset) {
            11, 12 => return echoz_init_parameters(cf, cmd, &lccf.*.headers),
            9 => return echoz_init_parameters(cf, cmd, &lccf.*.prepend_filters),
            10 => return echoz_init_parameters(cf, cmd, &lccf.*.append_filters),
            else => return echoz_init_parameters(cf, cmd, &lccf.*.content_handlers),
        }
    }
    return conf.NGX_CONF_OK;
}

export const ngx_http_echoz_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_echoz_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("echoz"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_ANY,
        .set = ngx_conf_set_echoz,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("echozn"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_ANY,
        .set = ngx_conf_set_echoz,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 1,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("echoz_duplicate"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_2MORE,
        .set = ngx_conf_set_echoz,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 2,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("echoz_flush"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_echoz,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 3,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("echoz_sleep"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_echoz,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 4,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("echoz_location_async"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE12,
        .set = ngx_conf_set_echoz,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 5,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("echoz_request_body"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_echoz,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 6,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("echoz_read_request_body"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_NOARGS,
        .set = ngx_conf_set_echoz,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 7,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("echoz_exec"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE12,
        .set = ngx_conf_set_echoz,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 8,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_echoz_module = ngx.module.make_module(
    @constCast(&ngx_http_echoz_commands),
    @constCast(&ngx_http_echoz_module_ctx),
);

export const ngx_http_echoz_filter_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration_filter,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = null,
};

export const ngx_http_echoz_filter_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("echoz_before_body"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_ANY,
        .set = ngx_conf_set_echoz,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 9,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("echoz_after_body"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_ANY,
        .set = ngx_conf_set_echoz,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 10,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("echoz_status"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_echoz,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 11,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("echoz_header"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE2,
        .set = ngx_conf_set_echoz,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 12,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_echoz_filter_module = ngx.module.make_module(
    @constCast(&ngx_http_echoz_filter_commands),
    @constCast(&ngx_http_echoz_filter_module_ctx),
);

var ngx_http_echoz_next_header_filter: http.ngx_http_output_header_filter_pt = null;
var ngx_http_echoz_next_output_body_filter: http.ngx_http_output_body_filter_pt = null;

const expectEqual = std.testing.expectEqual;
test "echoz module" {
    const len = core.sizeof(ngx.module.NGX_MODULE_SIGNATURE);
    const slice = core.slicify(u8, @constCast(ngx_http_echoz_module.signature), len);
    try expectEqual(slice.len, 40);

    try expectEqual(atof(ngx_string("2.181"), 2), 2180);
    try expectEqual(atof(ngx_string("2.1011"), 3), 2101);
    try expectEqual(atof(ngx_string("21"), 3), 21000);
}
