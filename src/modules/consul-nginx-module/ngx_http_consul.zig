const std = @import("std");
const ngx = @import("ngx");

const buf = ngx.buf;
const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const cjson = ngx.cjson;
const CJSON = cjson.CJSON;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_AGAIN = core.NGX_AGAIN;
const NGX_DECLINED = core.NGX_DECLINED;

const ngx_str_t = core.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_pool_t = core.ngx_pool_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_buf_t = ngx.buf.ngx_buf_t;
const ngx_chain_t = ngx.buf.ngx_chain_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;

const ngx_string = ngx.string.ngx_string;
const NChain = ngx.buf.NChain;

extern var ngx_http_core_module: ngx_module_t;
extern var ngx_pagesize: ngx_uint_t;

// Consul query type
const ConsulQueryType = enum(c_int) {
    services = 0, // GET /v1/health/service/<name>?passing=true
    kv = 1, // GET /v1/kv/<key>
    catalog = 2, // GET /v1/catalog/services
};

// Location config for consul directives
const consul_loc_conf = extern struct {
    host: ngx_str_t,
    port: ngx_uint_t,
    enabled: ngx_flag_t,
    query_type: ConsulQueryType,
    service_name: ngx_str_t,
    kv_key: ngx_str_t,
    tag: ngx_str_t,
    dc: ngx_str_t,
    token: ngx_str_t,
    passing_only: ngx_flag_t,
    ups: http.ngx_http_upstream_conf_t,
};

// Per-request context
const consul_request_ctx = extern struct {
    lccf: [*c]consul_loc_conf,
    res: [*c]ngx_chain_t,
    query_type: ConsulQueryType,
    service_name: ngx_str_t,
    kv_key: ngx_str_t,
    response_data: ngx_str_t,
    kv_value: ngx_str_t,
    kv_found: u8,
    service_healthy_count: ngx_uint_t,
    lookup_error: u8,
};

const consul_hide_headers = [_]ngx_str_t{
    ngx.string.ngx_null_str,
};

const ConsulError = error{
    UpstreamCreateFailed,
    OutOfMemory,
    ParseError,
    RequestTooLarge,
};

const CONSUL_REQUEST_MAX: usize = 16 * 1024;
const CONSUL_RENDER_MAX: usize = 64 * 1024;

const BoundedWriter = struct {
    bytes: []u8,
    len: usize = 0,

    fn append(self: *BoundedWriter, value: []const u8) bool {
        if (value.len > self.bytes.len - self.len) return false;
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.len += value.len;
        return true;
    }

    fn appendByte(self: *BoundedWriter, value: u8) bool {
        if (self.len == self.bytes.len) return false;
        self.bytes[self.len] = value;
        self.len += 1;
        return true;
    }

    fn appendDecimal(self: *BoundedWriter, value: usize) bool {
        var tmp: [20]u8 = undefined;
        const n = write_decimal(&tmp, value);
        return self.append(tmp[0..n]);
    }

    fn appendJsonString(self: *BoundedWriter, value: []const u8) bool {
        if (!self.appendByte('"')) return false;
        for (value) |c| {
            switch (c) {
                '"', '\\' => {
                    if (!self.appendByte('\\') or !self.appendByte(c)) return false;
                },
                '\n' => if (!self.append("\\n")) return false,
                '\r' => if (!self.append("\\r")) return false,
                '\t' => if (!self.append("\\t")) return false,
                else => {
                    if (c < 0x20) {
                        const hex = "0123456789abcdef";
                        if (!self.append("\\u00") or
                            !self.appendByte(hex[c >> 4]) or
                            !self.appendByte(hex[c & 0x0f])) return false;
                    } else if (!self.appendByte(c)) return false;
                },
            }
        }
        return self.appendByte('"');
    }

    fn appendUrlComponent(self: *BoundedWriter, value: []const u8) bool {
        const hex = "0123456789ABCDEF";
        for (value) |c| {
            const unreserved = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
            if (unreserved) {
                if (!self.appendByte(c)) return false;
            } else {
                if (!self.appendByte('%') or
                    !self.appendByte(hex[c >> 4]) or
                    !self.appendByte(hex[c & 0x0f])) return false;
            }
        }
        return true;
    }

    fn appendUrlPath(self: *BoundedWriter, value: []const u8) bool {
        const hex = "0123456789ABCDEF";
        for (value) |c| {
            const allowed = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~' or c == '/';
            if (allowed) {
                if (!self.appendByte(c)) return false;
            } else {
                if (!self.appendByte('%') or
                    !self.appendByte(hex[c >> 4]) or
                    !self.appendByte(hex[c & 0x0f])) return false;
            }
        }
        return true;
    }
};

fn init_upstream_conf(cf: [*c]http.ngx_http_upstream_conf_t) void {
    cf.*.buffering = 0;
    // process_header validates and transforms the complete bounded Consul
    // frame. Leave explicit headroom for status/headers and chunk metadata.
    cf.*.buffer_size = CONSUL_RENDER_MAX + 16 * 1024;
    cf.*.ssl_verify = 0;
    cf.*.connect_timeout = 5000;
    cf.*.send_timeout = 5000;
    cf.*.read_timeout = 10000;
    cf.*.module = ngx_string("ngx_http_consul_module");
    cf.*.hide_headers = conf.NGX_CONF_UNSET_PTR;
    cf.*.pass_headers = conf.NGX_CONF_UNSET_PTR;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(consul_loc_conf, cf.*.pool)) |p| {
        p.*.port = 8500;
        p.*.enabled = 0;
        p.*.host = ngx.string.ngx_null_str;
        p.*.service_name = ngx.string.ngx_null_str;
        p.*.kv_key = ngx.string.ngx_null_str;
        p.*.tag = ngx.string.ngx_null_str;
        p.*.dc = ngx.string.ngx_null_str;
        p.*.token = ngx.string.ngx_null_str;
        p.*.query_type = .services;
        p.*.passing_only = 1;
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
    const prev = core.castPtr(consul_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(consul_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.host.len == 0) c.*.host = prev.*.host;
    if (c.*.token.len == 0) c.*.token = prev.*.token;
    if (c.*.dc.len == 0) c.*.dc = prev.*.dc;
    if (c.*.port == 8500 and prev.*.port != 8500) c.*.port = prev.*.port;

    // Setup upstream headers hash
    if (c.*.enabled == 1) {
        var hash = ngx.hash.ngx_hash_init_t{
            .max_size = 100,
            .bucket_size = 1024,
            .name = @constCast("consul_headers_hash"),
        };
        if (http.ngx_http_upstream_hide_headers_hash(
            cf,
            &c.*.ups,
            &prev.*.ups,
            @constCast(&consul_hide_headers),
            &hash,
        ) != NGX_OK) {
            return conf.NGX_CONF_ERROR;
        }
    }

    return conf.NGX_CONF_OK;
}

const ParsedHostPort = struct { host: ngx_str_t, port: u16 };

// Parse host[:port], including bracketed IPv6 literals. Invalid and partial
// ports are rejected at configuration time rather than silently defaulted.
fn parse_host_port(arg: ngx_str_t) ?ParsedHostPort {
    if (arg.len == 0 or arg.data == null) return null;
    const value = core.slicify(u8, arg.data, arg.len);
    var host = arg;
    var port: u16 = 8500;

    if (value[0] == '[') {
        const close = std.mem.indexOfScalar(u8, value, ']') orelse return null;
        if (close == 1) return null;
        host = .{ .data = arg.data + 1, .len = close - 1 };
        if (close + 1 < value.len) {
            if (value[close + 1] != ':' or close + 2 == value.len) return null;
            port = std.fmt.parseInt(u16, value[close + 2 ..], 10) catch return null;
            if (port == 0) return null;
        }
        return .{ .host = host, .port = port };
    }

    const first_colon = std.mem.indexOfScalar(u8, value, ':');
    const last_colon = std.mem.lastIndexOfScalar(u8, value, ':');
    if (first_colon != null and first_colon.? == last_colon.?) {
        const colon = first_colon.?;
        if (colon == 0 or colon + 1 == value.len) return null;
        port = std.fmt.parseInt(u16, value[colon + 1 ..], 10) catch return null;
        if (port == 0) return null;
        host.len = colon;
    }
    return .{ .host = host, .port = port };
}

// Helper: write usize as decimal string
fn write_decimal(out: []u8, value: usize) usize {
    var v = value;
    var pos: usize = 0;
    if (v == 0) {
        out[0] = '0';
        return 1;
    }
    var temp: [20]u8 = undefined;
    var temp_pos: usize = 0;
    while (v > 0) : (temp_pos += 1) {
        temp[temp_pos] = @intCast('0' + @mod(v, 10));
        v = @divTrunc(v, 10);
    }
    // Reverse
    while (temp_pos > 0) {
        temp_pos -= 1;
        out[pos] = temp[temp_pos];
        pos += 1;
    }
    return pos;
}

fn append_json_string(out_buf: []u8, out_len: *usize, value: []const u8) bool {
    if (out_len.* >= out_buf.len) return false;
    out_buf[out_len.*] = '"';
    out_len.* += 1;

    for (value) |c| {
        switch (c) {
            '"', '\\' => {
                if (out_len.* + 2 > out_buf.len) return false;
                out_buf[out_len.*] = '\\';
                out_buf[out_len.* + 1] = c;
                out_len.* += 2;
            },
            '\n' => {
                if (out_len.* + 2 > out_buf.len) return false;
                out_buf[out_len.*] = '\\';
                out_buf[out_len.* + 1] = 'n';
                out_len.* += 2;
            },
            '\r' => {
                if (out_len.* + 2 > out_buf.len) return false;
                out_buf[out_len.*] = '\\';
                out_buf[out_len.* + 1] = 'r';
                out_len.* += 2;
            },
            '\t' => {
                if (out_len.* + 2 > out_buf.len) return false;
                out_buf[out_len.*] = '\\';
                out_buf[out_len.* + 1] = 't';
                out_len.* += 2;
            },
            else => {
                if (c < 0x20) return false;
                if (out_len.* + 1 > out_buf.len) return false;
                out_buf[out_len.*] = c;
                out_len.* += 1;
            },
        }
    }

    if (out_len.* >= out_buf.len) return false;
    out_buf[out_len.*] = '"';
    out_len.* += 1;
    return true;
}

// Build HTTP GET request for Consul API
fn build_consul_request(rctx: [*c]consul_request_ctx, pool: [*c]ngx_pool_t) !ngx_str_t {
    const lccf = rctx.*.lccf;
    const raw = core.castPtr(u8, core.ngx_pnalloc(pool, CONSUL_REQUEST_MAX)) orelse return ConsulError.OutOfMemory;
    var writer = BoundedWriter{ .bytes = core.slicify(u8, raw, CONSUL_REQUEST_MAX) };

    if (!writer.append("GET ")) return ConsulError.RequestTooLarge;

    switch (rctx.*.query_type) {
        .services => {
            if (!writer.append("/v1/health/service/") or
                !writer.appendUrlComponent(core.slicify(u8, rctx.*.service_name.data, rctx.*.service_name.len)))
                return ConsulError.RequestTooLarge;
            var has_query = false;
            if (lccf.*.passing_only == 1) {
                if (!writer.append("?passing=true")) return ConsulError.RequestTooLarge;
                has_query = true;
            }
            if (lccf.*.tag.len > 0) {
                if (!writer.append(if (has_query) "&tag=" else "?tag=") or
                    !writer.appendUrlComponent(core.slicify(u8, lccf.*.tag.data, lccf.*.tag.len)))
                    return ConsulError.RequestTooLarge;
                has_query = true;
            }
            if (lccf.*.dc.len > 0) {
                if (!writer.append(if (has_query) "&dc=" else "?dc=") or
                    !writer.appendUrlComponent(core.slicify(u8, lccf.*.dc.data, lccf.*.dc.len)))
                    return ConsulError.RequestTooLarge;
            }
        },
        .kv => {
            if (!writer.append("/v1/kv/") or
                !writer.appendUrlPath(core.slicify(u8, rctx.*.kv_key.data, rctx.*.kv_key.len)))
                return ConsulError.RequestTooLarge;
        },
        .catalog => if (!writer.append("/v1/catalog/services")) return ConsulError.RequestTooLarge,
    }

    const host = core.slicify(u8, lccf.*.host.data, lccf.*.host.len);
    if (std.mem.indexOfAny(u8, host, "\r\n") != null) return ConsulError.ParseError;
    if (!writer.append(" HTTP/1.1\r\nHost: ") or !writer.append(host)) return ConsulError.RequestTooLarge;
    if (lccf.*.port != 80) {
        if (!writer.appendByte(':') or !writer.appendDecimal(lccf.*.port)) return ConsulError.RequestTooLarge;
    }
    if (!writer.append("\r\nConnection: close\r\n")) return ConsulError.RequestTooLarge;
    if (lccf.*.token.len > 0) {
        const token = core.slicify(u8, lccf.*.token.data, lccf.*.token.len);
        if (std.mem.indexOfAny(u8, token, "\r\n") != null) return ConsulError.ParseError;
        if (!writer.append("X-Consul-Token: ") or !writer.append(token) or !writer.append("\r\n"))
            return ConsulError.RequestTooLarge;
    }
    if (!writer.append("\r\n")) return ConsulError.RequestTooLarge;
    return .{ .data = raw, .len = writer.len };
}

////////////////////////////  CONSUL UPSTREAM  //////////////////////////////////////////////////

fn ngx_http_consul_upstream_create_request(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    if (core.castPtr(
        consul_request_ctx,
        r.*.ctx[ngx_http_consul_module.ctx_index],
    )) |rctx| {
        const cmd = build_consul_request(rctx, r.*.pool) catch return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

        var chain = NChain.init(r.*.pool);
        var out = ngx_chain_t{
            .buf = core.nullptr(ngx_buf_t),
            .next = core.nullptr(ngx_chain_t),
        };
        const last = chain.allocStr(cmd, &out) catch return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

        last.*.buf.*.flags.last_buf = true;
        last.*.buf.*.flags.last_in_chain = true;
        last.*.next = r.*.upstream.*.request_bufs;
        r.*.upstream.*.request_bufs = last;

        r.*.upstream.*.flags.header_sent = false;
        r.*.upstream.*.flags.request_sent = false;
        r.*.header_hash = 1;

        ngx.log.ngz_log_error(
            ngx.log.NGX_LOG_DEBUG,
            r.*.connection.*.log,
            0,
            "consul: sending request type=%d",
            .{@intFromEnum(rctx.*.query_type)},
        );
    }
    return NGX_OK;
}

// Parse Consul service response and build simplified JSON
fn build_services_response(json_data: ngx_str_t, pool: [*c]ngx_pool_t, healthy_count: *ngx_uint_t) ?ngx_str_t {
    var cj = CJSON.init(pool);
    const parsed = cj.decode(json_data) catch return null;
    defer cj.free(parsed);

    const out = core.castPtr(u8, core.ngx_pnalloc(pool, CONSUL_RENDER_MAX)) orelse return null;
    var writer = BoundedWriter{ .bytes = core.slicify(u8, out, CONSUL_RENDER_MAX) };
    if (!writer.append("{\"services\":[")) return null;

    var it = CJSON.Iterator.init(parsed);
    var first = true;
    healthy_count.* = 0;
    while (it.next()) |entry| {
        const svc = cjson.cJSON_GetObjectItem(entry, "Service");
        if (svc == core.nullptr(cjson.cJSON)) continue;

        healthy_count.* += 1;
        if (!first and !writer.appendByte(',')) return null;
        first = false;
        if (!writer.appendByte('{')) return null;
        var has_field = false;

        const id_node = cjson.cJSON_GetObjectItem(svc, "ID");
        if (id_node != core.nullptr(cjson.cJSON)) {
            if (CJSON.stringValue(id_node)) |id_str| {
                if (!writer.append("\"id\":") or
                    !writer.appendJsonString(core.slicify(u8, id_str.data, id_str.len))) return null;
                has_field = true;
            }
        }

        const addr_node = cjson.cJSON_GetObjectItem(svc, "Address");
        if (addr_node != core.nullptr(cjson.cJSON)) {
            if (CJSON.stringValue(addr_node)) |addr_str| {
                if (has_field and !writer.appendByte(',')) return null;
                if (!writer.append("\"address\":") or
                    !writer.appendJsonString(core.slicify(u8, addr_str.data, addr_str.len))) return null;
                has_field = true;
            }
        }

        const port_node = cjson.cJSON_GetObjectItem(svc, "Port");
        if (port_node != core.nullptr(cjson.cJSON)) {
            if (CJSON.intValue(port_node)) |port_val| {
                if (port_val < 0) return null;
                if (has_field and !writer.appendByte(',')) return null;
                if (!writer.append("\"port\":") or !writer.appendDecimal(@intCast(port_val))) return null;
                has_field = true;
            }
        }

        const tags_node = cjson.cJSON_GetObjectItem(svc, "Tags");
        if (tags_node != core.nullptr(cjson.cJSON) and cjson.cJSON_IsArray(tags_node) == 1) {
            if (has_field and !writer.appendByte(',')) return null;
            if (!writer.append("\"tags\":[")) return null;

            var tag_it = CJSON.Iterator.init(tags_node);
            var first_tag = true;
            while (tag_it.next()) |tag| {
                if (CJSON.stringValue(tag)) |tag_str| {
                    if (!first_tag and !writer.appendByte(',')) return null;
                    first_tag = false;
                    if (!writer.appendJsonString(core.slicify(u8, tag_str.data, tag_str.len))) return null;
                }
            }
            if (!writer.appendByte(']')) return null;
        }
        if (!writer.appendByte('}')) return null;
    }

    if (!writer.append("]}")) return null;
    return .{ .data = out, .len = writer.len };
}

// Parse Consul KV response and build JSON
fn build_kv_response(json_data: ngx_str_t, pool: [*c]ngx_pool_t, rctx: [*c]consul_request_ctx) ?ngx_str_t {
    var cj = CJSON.init(pool);

    const parsed = cj.decode(json_data) catch return null;
    defer cj.free(parsed);

    // Response is array with single object containing "Value" (base64 encoded)
    var out_buf: [4096]u8 = undefined;
    var out_len: usize = 0;

    var it = CJSON.Iterator.init(parsed);
    if (it.next()) |entry| {
        const value_node = cjson.cJSON_GetObjectItem(entry, "Value");
        if (value_node != core.nullptr(cjson.cJSON)) {
            if (CJSON.stringValue(value_node)) |value_str| {
                const value_slice = core.slicify(u8, value_str.data, value_str.len);
                var decoded: [2048]u8 = undefined;
                const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(value_slice) catch return null;

                if (decoded_len <= decoded.len) {
                    const prefix = "{\"value\":";
                    @memcpy(out_buf[out_len..][0..prefix.len], prefix);
                    out_len += prefix.len;

                    if (std.base64.standard.Decoder.decode(&decoded, value_slice)) |_| {
                        if (!append_json_string(&out_buf, &out_len, decoded[0..decoded_len])) {
                            return null;
                        }
                        rctx.*.kv_found = 1;
                        if (core.castPtr(u8, core.ngx_pnalloc(pool, decoded_len))) |vc| {
                            @memcpy(core.slicify(u8, vc, decoded_len), decoded[0..decoded_len]);
                            rctx.*.kv_value = ngx_str_t{ .data = vc, .len = decoded_len };
                        }
                    } else |_| {
                        const raw_len = @min(value_slice.len, 1024);
                        if (!append_json_string(&out_buf, &out_len, value_slice[0..raw_len])) {
                            return null;
                        }
                        rctx.*.kv_found = 1;
                        if (core.castPtr(u8, core.ngx_pnalloc(pool, raw_len))) |vc| {
                            @memcpy(core.slicify(u8, vc, raw_len), value_slice[0..raw_len]);
                            rctx.*.kv_value = ngx_str_t{ .data = vc, .len = raw_len };
                        }
                    }

                    const suffix = "}";
                    @memcpy(out_buf[out_len..][0..suffix.len], suffix);
                    out_len += suffix.len;
                }
            }
        }
    }

    if (out_len == 0) {
        const not_found = "{\"value\":null}";
        @memcpy(out_buf[0..not_found.len], not_found);
        out_len = not_found.len;
    }

    if (core.castPtr(u8, core.ngx_pnalloc(pool, out_len))) |data| {
        @memcpy(core.slicify(u8, data, out_len), out_buf[0..out_len]);
        return ngx_str_t{ .data = data, .len = out_len };
    }
    return null;
}

// Build catalog response
fn build_catalog_response(json_data: ngx_str_t, pool: [*c]ngx_pool_t) ?ngx_str_t {
    var cj = CJSON.init(pool);
    const parsed = cj.decode(json_data) catch return null;
    defer cj.free(parsed);

    const out = core.castPtr(u8, core.ngx_pnalloc(pool, CONSUL_RENDER_MAX)) orelse return null;
    var writer = BoundedWriter{ .bytes = core.slicify(u8, out, CONSUL_RENDER_MAX) };
    if (!writer.append("{\"services\":[")) return null;

    var it = CJSON.Iterator.init(parsed);
    var first = true;
    while (it.next()) |entry| {
        if (entry.*.string != core.nullptr(u8)) {
            if (!first and !writer.appendByte(',')) return null;
            first = false;
            var name_len: usize = 0;
            var p = entry.*.string;
            while (p.* != 0) : (name_len += 1) p += 1;
            if (!writer.appendJsonString(core.slicify(u8, entry.*.string, name_len))) return null;
        }
    }

    if (!writer.append("]}")) return null;
    return .{ .data = out, .len = writer.len };
}

fn parse_content_length(headers: []const u8) ?usize {
    var result: ?usize = null;
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next(); // status line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return null;
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const parsed = std.fmt.parseInt(usize, value, 10) catch return null;
            if (parsed > CONSUL_RENDER_MAX) return null;
            if (result != null and result.? != parsed) return null;
            result = parsed;
        }
    }
    return result;
}

fn has_chunked_encoding(headers: []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            return std.ascii.eqlIgnoreCase(value, "chunked");
        }
    }
    return false;
}

const ChunkScan = union(enum) { incomplete, invalid, complete: usize };

fn scan_chunked_body(input: []const u8) ChunkScan {
    var pos: usize = 0;
    var decoded: usize = 0;
    while (true) {
        const line_rel = std.mem.indexOf(u8, input[pos..], "\r\n") orelse return .incomplete;
        const line = input[pos .. pos + line_rel];
        if (line.len == 0 or std.mem.indexOfScalar(u8, line, ';') != null) return .invalid;
        const chunk_len = std.fmt.parseInt(usize, line, 16) catch return .invalid;
        pos += line_rel + 2;
        if (chunk_len == 0) {
            if (input.len - pos < 2) return .incomplete;
            if (!std.mem.eql(u8, input[pos .. pos + 2], "\r\n")) return .invalid;
            return .{ .complete = decoded };
        }
        if (chunk_len > CONSUL_RENDER_MAX - decoded) return .invalid;
        if (input.len - pos < chunk_len + 2) return .incomplete;
        if (!std.mem.eql(u8, input[pos + chunk_len .. pos + chunk_len + 2], "\r\n")) return .invalid;
        decoded += chunk_len;
        pos += chunk_len + 2;
    }
}

fn decode_chunked_body(input: []const u8, output: []u8) bool {
    var pos: usize = 0;
    var written: usize = 0;
    while (true) {
        const line_rel = std.mem.indexOf(u8, input[pos..], "\r\n") orelse return false;
        const chunk_len = std.fmt.parseInt(usize, input[pos .. pos + line_rel], 16) catch return false;
        pos += line_rel + 2;
        if (chunk_len == 0) return written == output.len;
        @memcpy(output[written .. written + chunk_len], input[pos .. pos + chunk_len]);
        written += chunk_len;
        pos += chunk_len + 2;
    }
}

// Parse HTTP response from Consul
fn ngx_http_consul_upstream_process_header(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    if (core.castPtr(
        consul_request_ctx,
        r.*.ctx[ngx_http_consul_module.ctx_index],
    )) |rctx| {
        const u = r.*.upstream;
        const b = &u.*.buffer;
        const received_len = @intFromPtr(b.*.last) - @intFromPtr(b.*.pos);
        const received = core.slicify(u8, b.*.pos, received_len);
        const header_end = std.mem.indexOf(u8, received, "\r\n\r\n") orelse return NGX_AGAIN;
        const status_line_end = std.mem.indexOf(u8, received[0..header_end], "\r\n") orelse return NGX_ERROR;
        const status_line = received[0..status_line_end];
        const first_space = std.mem.indexOfScalar(u8, status_line, ' ') orelse return NGX_ERROR;
        if (first_space + 4 > status_line.len) return NGX_ERROR;
        const status: ngx_uint_t = std.fmt.parseInt(ngx_uint_t, status_line[first_space + 1 .. first_space + 4], 10) catch return NGX_ERROR;
        if (status < 100 or status > 599) return NGX_ERROR;

        const body_offset = header_end + 4;
        const available_body_len = received.len - body_offset;
        const headers = received[0 .. header_end + 2];
        var body_start = b.*.pos + body_offset;
        var body_len: usize = 0;
        if (has_chunked_encoding(headers)) {
            switch (scan_chunked_body(received[body_offset..])) {
                .incomplete => return NGX_AGAIN,
                .invalid => return http.NGX_HTTP_UPSTREAM_INVALID_HEADER,
                .complete => |decoded_len| {
                    if (decoded_len > 0) {
                        const decoded = core.castPtr(u8, core.ngx_pnalloc(r.*.pool, decoded_len)) orelse return NGX_ERROR;
                        if (!decode_chunked_body(received[body_offset..], decoded[0..decoded_len])) return NGX_ERROR;
                        body_start = decoded;
                    }
                    body_len = decoded_len;
                },
            }
        } else {
            const expected_body_len = parse_content_length(headers) orelse return NGX_ERROR;
            if (available_body_len < expected_body_len) return NGX_AGAIN;
            body_len = expected_body_len;
        }

        // Store response data
        rctx.*.response_data = ngx_str_t{
            .data = body_start,
            .len = body_len,
        };

        // Handle based on status - 404 first since it may have empty body
        if (status == 404) {
            // Not found - return empty/null response
            rctx.*.kv_found = 0;
            const not_found = if (rctx.*.query_type == .kv)
                "{\"value\":null}"
            else
                "{\"services\":[]}";

            if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, not_found.len))) |data| {
                @memcpy(core.slicify(u8, data, not_found.len), not_found);
                b.*.pos = data;
                b.*.last = data + not_found.len;
            }

            u.*.headers_in.status_n = 200;
            u.*.headers_in.content_length_n = @intCast(not_found.len);
            u.*.length = 0;

            r.*.headers_out.content_type = ngx_str_t{ .len = 16, .data = @constCast("application/json") };
            r.*.headers_out.content_type_len = 16;
            r.*.headers_out.content_type_lowcase = null;

            return NGX_OK;
        }

        if (status != 200) {
            // Error response
            rctx.*.lookup_error = 1;
            const error_json = "{\"error\":\"consul_error\"}";
            if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, error_json.len))) |data| {
                @memcpy(core.slicify(u8, data, error_json.len), error_json);
                b.*.pos = data;
                b.*.last = data + error_json.len;
            }

            u.*.headers_in.status_n = 502;
            u.*.headers_in.content_length_n = error_json.len;
            u.*.length = 0;

            r.*.headers_out.content_type = ngx_str_t{ .len = 16, .data = @constCast("application/json") };
            r.*.headers_out.content_type_len = 16;
            r.*.headers_out.content_type_lowcase = null;

            return NGX_OK;
        }

        // Parse and transform JSON response
        var svc_count: ngx_uint_t = 0;
        const json_response: ?ngx_str_t = switch (rctx.*.query_type) {
            .services => blk: {
                const r2 = build_services_response(rctx.*.response_data, r.*.pool, &svc_count);
                rctx.*.service_healthy_count = svc_count;
                break :blk r2;
            },
            .kv => build_kv_response(rctx.*.response_data, r.*.pool, rctx),
            .catalog => build_catalog_response(rctx.*.response_data, r.*.pool),
        };

        if (json_response) |json| {
            b.*.pos = json.data;
            b.*.last = json.data + json.len;

            u.*.headers_in.status_n = 200;
            u.*.headers_in.content_length_n = @intCast(json.len);
            u.*.length = 0;

            r.*.headers_out.content_type = ngx_str_t{ .len = 16, .data = @constCast("application/json") };
            r.*.headers_out.content_type_len = 16;
            r.*.headers_out.content_type_lowcase = null;
        } else {
            // Parse error - return error
            rctx.*.lookup_error = 1;
            const error_json = "{\"error\":\"parse_error\"}";
            if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, error_json.len))) |data| {
                @memcpy(core.slicify(u8, data, error_json.len), error_json);
                b.*.pos = data;
                b.*.last = data + error_json.len;
            }

            u.*.headers_in.status_n = 500;
            u.*.headers_in.content_length_n = error_json.len;
            u.*.length = 0;

            r.*.headers_out.content_type = ngx_str_t{ .len = 16, .data = @constCast("application/json") };
            r.*.headers_out.content_type_len = 16;
            r.*.headers_out.content_type_lowcase = null;
        }

        return NGX_OK;
    }
    return NGX_ERROR;
}

fn ngx_http_consul_upstream_input_filter_init(
    ctx: ?*anyopaque,
) callconv(.c) ngx_int_t {
    if (core.castPtr(ngx_http_request_t, ctx)) |r| {
        const u = r.*.upstream;
        u.*.length = u.*.headers_in.content_length_n;
    }
    return NGX_OK;
}

fn ngx_http_consul_upstream_input_filter(
    ctx: ?*anyopaque,
    bytes: isize,
) callconv(.c) ngx_int_t {
    if (core.castPtr(ngx_http_request_t, ctx)) |r| {
        const u = r.*.upstream;
        const b = &u.*.buffer;

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
            u.*.length -= bytes;

            if (u.*.length == 0) {
                u.*.flags.keepalive = true;
            }

            return NGX_OK;
        }
    }
    return NGX_ERROR;
}

fn ngx_http_consul_upstream_finalize_request(
    r: [*c]ngx_http_request_t,
    rc: ngx_int_t,
) callconv(.c) void {
    _ = r;
    _ = rc;
}

fn create_upstream(
    r: [*c]ngx_http_request_t,
    rctx: [*c]consul_request_ctx,
) !ngx_int_t {
    if (http.ngx_http_upstream_create(r) != NGX_OK) {
        return ConsulError.UpstreamCreateFailed;
    }

    const lccf: [*c]consul_loc_conf = rctx.*.lccf;
    r.*.upstream.*.conf = &lccf.*.ups;
    r.*.upstream.*.flags.buffering = false;
    r.*.upstream.*.create_request = ngx_http_consul_upstream_create_request;
    r.*.upstream.*.process_header = ngx_http_consul_upstream_process_header;
    r.*.upstream.*.input_filter_init = ngx_http_consul_upstream_input_filter_init;
    r.*.upstream.*.input_filter = ngx_http_consul_upstream_input_filter;
    r.*.upstream.*.finalize_request = ngx_http_consul_upstream_finalize_request;
    r.*.upstream.*.input_filter_ctx = r;

    if (core.ngz_pcalloc_c(
        http.ngx_http_upstream_resolved_t,
        r.*.pool,
    )) |resolved| {
        r.*.upstream.*.resolved = resolved;
        r.*.upstream.*.resolved.*.host = lccf.*.host;
        r.*.upstream.*.resolved.*.port = @intCast(lccf.*.port);
        r.*.upstream.*.flags.ssl = false;
        r.*.upstream.*.resolved.*.naddrs = 1;

        if (core.ngz_pcalloc_c(ngx_chain_t, r.*.pool)) |chain| {
            rctx.*.res = chain;
            rctx.*.res.*.next = core.nullptr(ngx_chain_t);
            http.ngx_http_upstream_init(r);
            return core.NGX_DONE;
        }
    }

    return ConsulError.OutOfMemory;
}

// Extract service name from URI: /consul/services/<name>
fn get_service_from_uri(r: [*c]ngx_http_request_t) ngx_str_t {
    // URI format: /consul/services/<service_name>
    const uri = core.slicify(u8, r.*.uri.data, r.*.uri.len);

    // Find last /
    var last_slash: usize = 0;
    for (uri, 0..) |c, i| {
        if (c == '/') last_slash = i;
    }

    if (last_slash + 1 < uri.len) {
        return ngx_str_t{
            .data = r.*.uri.data + last_slash + 1,
            .len = r.*.uri.len - last_slash - 1,
        };
    }

    return ngx.string.ngx_null_str;
}

// Extract key from URI: /consul/kv/<key>
fn get_key_from_uri(r: [*c]ngx_http_request_t) ngx_str_t {
    // URI format: /consul/kv/<key>
    const uri = core.slicify(u8, r.*.uri.data, r.*.uri.len);

    // Find /kv/ prefix
    const kv_prefix = "/kv/";
    if (std.mem.indexOf(u8, uri, kv_prefix)) |idx| {
        const key_start = idx + kv_prefix.len;
        if (key_start < uri.len) {
            return ngx_str_t{
                .data = r.*.uri.data + key_start,
                .len = r.*.uri.len - key_start,
            };
        }
    }

    // Fallback: get last path component
    return get_service_from_uri(r);
}

export fn ngx_http_consul_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        consul_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_consul_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) {
        return NGX_DECLINED;
    }

    // Only allow GET requests
    if (r.*.method != http.NGX_HTTP_GET) {
        return http.NGX_HTTP_NOT_ALLOWED;
    }

    // Get or create request context
    const rctx = http.ngz_http_get_module_ctx(
        consul_request_ctx,
        r,
        &ngx_http_consul_module,
    ) catch return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

    if (rctx.*.lccf == core.nullptr(consul_loc_conf)) {
        rctx.*.lccf = lccf;
        rctx.*.query_type = lccf.*.query_type;

        // Get service name or key from config or URI
        switch (lccf.*.query_type) {
            .services => {
                if (lccf.*.service_name.len > 0) {
                    rctx.*.service_name = lccf.*.service_name;
                } else {
                    rctx.*.service_name = get_service_from_uri(r);
                }
            },
            .kv => {
                if (lccf.*.kv_key.len > 0) {
                    rctx.*.kv_key = lccf.*.kv_key;
                } else {
                    rctx.*.kv_key = get_key_from_uri(r);
                }
            },
            .catalog => {},
        }
    }

    // Read request body (even if we don't need it, this properly manages request lifecycle)
    const rc = http.ngx_http_read_client_request_body(r, ngx_http_consul_body_handler);
    if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) {
        return rc;
    }
    return core.NGX_DONE;
}

export fn ngx_http_consul_body_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) void {
    if (core.castPtr(
        consul_request_ctx,
        r.*.ctx[ngx_http_consul_module.ctx_index],
    )) |rctx| {
        const rc = create_upstream(r, rctx) catch {
            http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
            return;
        };
        // Only finalize on error - upstream will handle completion
        if (rc != core.NGX_DONE) {
            http.ngx_http_finalize_request(r, rc);
        }
    } else {
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
    }
}

////////////////////////////  DIRECTIVES  //////////////////////////////////////////////////

fn ngx_conf_set_consul_pass(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(consul_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const parsed = parse_host_port(arg.*) orelse return @constCast("consul_services requires a valid host[:port]");
            lccf.*.host = parsed.host;
            lccf.*.port = parsed.port;
            lccf.*.enabled = 1;
            lccf.*.query_type = .services;

            // Set content handler
            if (core.castPtr(
                http.ngx_http_core_loc_conf_t,
                conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
            )) |clcf| {
                clcf.*.handler = ngx_http_consul_handler;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_consul_kv(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(consul_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const parsed = parse_host_port(arg.*) orelse return @constCast("consul_kv requires a valid host[:port]");
            lccf.*.host = parsed.host;
            lccf.*.port = parsed.port;
            lccf.*.enabled = 1;
            lccf.*.query_type = .kv;

            // Set content handler
            if (core.castPtr(
                http.ngx_http_core_loc_conf_t,
                conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
            )) |clcf| {
                clcf.*.handler = ngx_http_consul_handler;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_consul_catalog(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(consul_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const parsed = parse_host_port(arg.*) orelse return @constCast("consul_catalog requires a valid host[:port]");
            lccf.*.host = parsed.host;
            lccf.*.port = parsed.port;
            lccf.*.enabled = 1;
            lccf.*.query_type = .catalog;

            // Set content handler
            if (core.castPtr(
                http.ngx_http_core_loc_conf_t,
                conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
            )) |clcf| {
                clcf.*.handler = ngx_http_consul_handler;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

const ngx_http_variable_value_t = http.ngx_http_variable_value_t;

const CONSUL_VAR_KV_VALUE: core.uintptr_t = 0;
const CONSUL_VAR_KV_FOUND: core.uintptr_t = 1;
const CONSUL_VAR_SVC_COUNT: core.uintptr_t = 2;
const CONSUL_VAR_LOOKUP_ERROR: core.uintptr_t = 3;

fn ngx_http_consul_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    const rctx = core.castPtr(consul_request_ctx, r.*.ctx[ngx_http_consul_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };

    switch (data) {
        CONSUL_VAR_KV_VALUE => {
            if (rctx.*.kv_found == 1 and rctx.*.kv_value.len > 0) {
                v.*.data = rctx.*.kv_value.data;
                v.*.flags.len = @intCast(rctx.*.kv_value.len);
            } else {
                v.*.flags.not_found = true;
                return NGX_OK;
            }
        },
        CONSUL_VAR_KV_FOUND => {
            v.*.data = if (rctx.*.kv_found == 1) @constCast("1") else @constCast("0");
            v.*.flags.len = 1;
        },
        CONSUL_VAR_SVC_COUNT => {
            var num_buf: [24]u8 = undefined;
            const slice = std.fmt.bufPrint(&num_buf, "{d}", .{rctx.*.service_healthy_count}) catch {
                v.*.flags.not_found = true;
                return NGX_OK;
            };
            const copied = ngx.string.ngx_string_from_pool(@constCast(slice.ptr), slice.len, r.*.pool) catch {
                v.*.flags.not_found = true;
                return NGX_OK;
            };
            v.*.data = copied.data;
            v.*.flags.len = @intCast(copied.len);
        },
        CONSUL_VAR_LOOKUP_ERROR => {
            if (rctx.*.lookup_error == 1) {
                v.*.data = @constCast("consul_error");
                v.*.flags.len = 12;
            } else {
                v.*.flags.not_found = true;
                return NGX_OK;
            }
        },
        else => {
            v.*.flags.not_found = true;
            return NGX_OK;
        },
    }
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    var vs = [_]http.ngx_http_variable_t{
        http.ngx_http_variable_t{ .name = ngx_string("consul_kv_value"), .set_handler = null, .get_handler = ngx_http_consul_variable, .data = CONSUL_VAR_KV_VALUE, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("consul_kv_found"), .set_handler = null, .get_handler = ngx_http_consul_variable, .data = CONSUL_VAR_KV_FOUND, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("consul_service_healthy_count"), .set_handler = null, .get_handler = ngx_http_consul_variable, .data = CONSUL_VAR_SVC_COUNT, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("consul_lookup_error"), .set_handler = null, .get_handler = ngx_http_consul_variable, .data = CONSUL_VAR_LOOKUP_ERROR, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
    };
    for (&vs) |*v| {
        if (http.ngx_http_add_variable(cf, &v.name, v.flags)) |x| {
            x.*.get_handler = v.get_handler;
            x.*.data = v.data;
        }
    }
    return NGX_OK;
}

export const ngx_http_consul_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_consul_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("consul_services"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_consul_pass,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("consul_kv"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_consul_kv,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("consul_catalog"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_consul_catalog,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("consul_service"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(consul_loc_conf, "service_name"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("consul_key"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(consul_loc_conf, "kv_key"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("consul_tag"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(consul_loc_conf, "tag"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("consul_dc"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(consul_loc_conf, "dc"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("consul_token"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(consul_loc_conf, "token"),
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_consul_module = ngx.module.make_module(
    @constCast(&ngx_http_consul_commands),
    @constCast(&ngx_http_consul_module_ctx),
);

// Tests
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "consul module" {
    try expect(ngx_http_consul_module.version > 0);
}

test "parse_host_port" {
    const r1 = parse_host_port(ngx_string("localhost:8500")).?;
    try expectEqual(r1.port, 8500);
    try expectEqual(r1.host.len, 9);

    const r2 = parse_host_port(ngx_string("127.0.0.1:8501")).?;
    try expectEqual(r2.port, 8501);
    try expectEqual(r2.host.len, 9);

    const r3 = parse_host_port(ngx_string("consul.local")).?;
    try expectEqual(r3.port, 8500);
    try expectEqual(r3.host.len, 12);

    const r4 = parse_host_port(ngx_string("[::1]:8502")).?;
    try expectEqual(r4.port, 8502);
    try expect(std.mem.eql(u8, core.slicify(u8, r4.host.data, r4.host.len), "::1"));

    try expect(parse_host_port(ngx_string("localhost:bad")) == null);
    try expect(parse_host_port(ngx_string("localhost:70000")) == null);
    try expect(parse_host_port(ngx_string("localhost:0")) == null);
}

test "write_decimal" {
    var test_buf: [20]u8 = undefined;

    try expectEqual(write_decimal(&test_buf, 0), 1);
    try expectEqual(test_buf[0], '0');

    try expectEqual(write_decimal(&test_buf, 123), 3);
    try expect(std.mem.eql(u8, test_buf[0..3], "123"));

    try expectEqual(write_decimal(&test_buf, 8080), 4);
    try expect(std.mem.eql(u8, test_buf[0..4], "8080"));
}

test "bounded writer rejects overflow without advancing" {
    var storage: [8]u8 = undefined;
    var writer = BoundedWriter{ .bytes = &storage };
    try expect(writer.append("12345678"));
    try expect(!writer.append("x"));
    try expectEqual(@as(usize, 8), writer.len);
    try expect(std.mem.eql(u8, storage[0..writer.len], "12345678"));
}

test "bounded writer escapes JSON and URL components" {
    var storage: [128]u8 = undefined;
    var writer = BoundedWriter{ .bytes = &storage };
    try expect(writer.appendJsonString("quote\" slash\\ line\n\x01"));
    try expect(std.mem.eql(u8, storage[0..writer.len], "\"quote\\\" slash\\\\ line\\n\\u0001\""));

    writer.len = 0;
    try expect(writer.appendUrlComponent("a b/c?d"));
    try expect(std.mem.eql(u8, storage[0..writer.len], "a%20b%2Fc%3Fd"));
}

test "content length framing is strict and bounded" {
    try expectEqual(@as(?usize, 12), parse_content_length("HTTP/1.1 200 OK\r\nContent-Length: 12\r\n"));
    try expect(parse_content_length("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n") == null);
    try expect(parse_content_length("HTTP/1.1 200 OK\r\nContent-Length: nope\r\n") == null);
    try expect(parse_content_length("HTTP/1.1 200 OK\r\nContent-Length: 70000\r\n") == null);
}
