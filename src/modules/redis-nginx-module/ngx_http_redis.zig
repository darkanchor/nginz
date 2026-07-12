const std = @import("std");
const ngx = @import("ngx");

const buf = ngx.buf;
const core = ngx.core;
const conf = ngx.conf;
const file = ngx.file;
const http = ngx.http;

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
const ngx_sprintf = ngx.string.ngx_sprintf;
const NChain = ngx.buf.NChain;

extern var ngx_http_core_module: ngx_module_t;
extern var ngx_http_upstream_module: ngx_module_t;
extern var ngx_pagesize: ngx_uint_t;

// Redis commands supported
const RedisCommand = enum(c_int) {
    get = 0, // GET key
    set = 1, // SET key value
    del = 2, // DEL key
    incr = 3, // INCR key
    expire = 4, // EXPIRE key seconds
    mget = 5, // MGET key1 key2 ...
    decr = 6, // DECR key
    exists = 7, // EXISTS key
    ttl = 8, // TTL key
    ping = 9, // PING
    strlen = 10, // STRLEN key
    hget = 11, // HGET key field
    hset = 12, // HSET key field value
    hdel = 13, // HDEL key field
};

// Redis RESP parsing state
const RespState = enum(c_int) {
    start, // Waiting for type byte
    reading_length, // Reading bulk string length
    reading_data, // Reading bulk string data
    done, // Parsing complete
    resp_error, // Parse error
};

// Location config for redis directives
const redis_loc_conf = extern struct {
    host: ngx_str_t,
    port: ngx_uint_t,
    key: ngx_str_t,
    enabled: ngx_flag_t,
    command: RedisCommand,
    ups: http.ngx_http_upstream_conf_t,
};

// Per-request context
const redis_request_ctx = extern struct {
    lccf: [*c]redis_loc_conf,
    res: [*c]ngx_chain_t,
    key: ngx_str_t,
    value: ngx_str_t, // For SET/HSET: value to store; For EXPIRE: TTL as string
    field: ngx_str_t, // For HGET/HSET/HDEL: hash field name
    command: RedisCommand, // Command for this request
    state: RespState,
    data_len: isize, // Expected length from RESP (-1 for nil)
    data: ngx_str_t, // Copied data from Redis response
    mget_count: ngx_uint_t, // For MGET: number of keys
    mget_keys: [16]ngx_str_t, // For MGET: array of keys (max 16)
    last_exists: u8,
    last_error: u8,
    conn_failed: u8,
};

const redis_hide_headers = [_]ngx_str_t{
    ngx.string.ngx_null_str,
};

const RedisError = error{
    UpstreamCreateFailed,
    OutOfMemory,
};

const REDIS_MAX_ARRAY_ITEMS: usize = 16;
const REDIS_MAX_VALUE_SIZE: usize = 32 * 1024;
const REDIS_MAX_JSON_SIZE: usize = 256 * 1024;

const JsonWriter = struct {
    bytes: []u8,
    len: usize = 0,

    fn append(self: *JsonWriter, value: []const u8) bool {
        if (value.len > self.bytes.len - self.len) return false;
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.len += value.len;
        return true;
    }

    fn appendByte(self: *JsonWriter, value: u8) bool {
        if (self.len == self.bytes.len) return false;
        self.bytes[self.len] = value;
        self.len += 1;
        return true;
    }

    fn appendEscaped(self: *JsonWriter, value: []const u8) bool {
        const hex = "0123456789abcdef";
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
                        if (!self.append("\\u00") or
                            !self.appendByte(hex[c >> 4]) or
                            !self.appendByte(hex[c & 0x0f])) return false;
                    } else if (!self.appendByte(c)) return false;
                },
            }
        }
        return true;
    }
};

fn escapedJsonLen(value: []const u8) ?usize {
    var total: usize = 0;
    for (value) |c| {
        const add: usize = if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c == '\t') 2 else if (c < 0x20) 6 else 1;
        if (add > REDIS_MAX_JSON_SIZE - total) return null;
        total += add;
    }
    return total;
}

fn init_upstream_conf(cf: [*c]http.ngx_http_upstream_conf_t) void {
    cf.*.buffering = 0;
    // RESP is validated as one bounded frame in process_header. This must fit
    // the maximum accepted JSON-producing frame plus RESP metadata so legal
    // 32 KiB bulk values and fragmented reads cannot fill the header buffer.
    cf.*.buffer_size = REDIS_MAX_JSON_SIZE + 16 * 1024;
    cf.*.ssl_verify = 0;
    cf.*.connect_timeout = 5000;
    cf.*.send_timeout = 5000;
    cf.*.read_timeout = 5000;
    cf.*.module = ngx_string("ngx_http_redis_module");
    cf.*.hide_headers = conf.NGX_CONF_UNSET_PTR;
    cf.*.pass_headers = conf.NGX_CONF_UNSET_PTR;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(redis_loc_conf, cf.*.pool)) |p| {
        p.*.port = 6379;
        p.*.enabled = 0;
        p.*.host = ngx.string.ngx_null_str;
        p.*.key = ngx.string.ngx_null_str;
        p.*.command = .get; // Default to GET
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
    const prev = core.castPtr(redis_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(redis_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.host.len == 0) c.*.host = prev.*.host;
    if (c.*.key.len == 0) c.*.key = prev.*.key;
    if (c.*.port == 6379 and prev.*.port != 6379) c.*.port = prev.*.port;

    // Setup upstream headers hash
    if (c.*.enabled == 1) {
        var hash = ngx.hash.ngx_hash_init_t{
            .max_size = 100,
            .bucket_size = 1024,
            .name = @constCast("redis_headers_hash"),
        };
        if (http.ngx_http_upstream_hide_headers_hash(
            cf,
            &c.*.ups,
            &prev.*.ups,
            @constCast(&redis_hide_headers),
            &hash,
        ) != NGX_OK) {
            return conf.NGX_CONF_ERROR;
        }
    }

    return conf.NGX_CONF_OK;
}

// Parse host:port from redis_pass directive
fn parse_host_port(arg: ngx_str_t) struct { host: ngx_str_t, port: u16 } {
    var host = arg;
    var port: u16 = 6379;

    var i: usize = 0;
    while (i < arg.len) : (i += 1) {
        if (arg.data[i] == ':') {
            host.len = i;
            var p: u16 = 0;
            var j: usize = i + 1;
            while (j < arg.len) : (j += 1) {
                if (arg.data[j] >= '0' and arg.data[j] <= '9') {
                    p = p * 10 + @as(u16, arg.data[j] - '0');
                } else {
                    break;
                }
            }
            if (p > 0) port = p;
            break;
        }
    }

    return .{ .host = host, .port = port };
}

fn ngx_conf_set_redis_pass(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(redis_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const parsed = parse_host_port(arg.*);
            lccf.*.host = parsed.host;
            lccf.*.port = parsed.port;
            lccf.*.enabled = 1;

            // Set content handler
            if (core.castPtr(
                http.ngx_http_core_loc_conf_t,
                conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
            )) |clcf| {
                clcf.*.handler = ngx_http_redis_handler;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_redis_command(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(redis_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const s = core.slicify(u8, arg.*.data, arg.*.len);
            if (std.mem.eql(u8, s, "get")) {
                lccf.*.command = .get;
            } else if (std.mem.eql(u8, s, "set")) {
                lccf.*.command = .set;
            } else if (std.mem.eql(u8, s, "del")) {
                lccf.*.command = .del;
            } else if (std.mem.eql(u8, s, "incr")) {
                lccf.*.command = .incr;
            } else if (std.mem.eql(u8, s, "decr")) {
                lccf.*.command = .decr;
            } else if (std.mem.eql(u8, s, "expire")) {
                lccf.*.command = .expire;
            } else if (std.mem.eql(u8, s, "mget")) {
                lccf.*.command = .mget;
            } else if (std.mem.eql(u8, s, "exists")) {
                lccf.*.command = .exists;
            } else if (std.mem.eql(u8, s, "ttl")) {
                lccf.*.command = .ttl;
            } else if (std.mem.eql(u8, s, "ping")) {
                lccf.*.command = .ping;
            } else if (std.mem.eql(u8, s, "strlen")) {
                lccf.*.command = .strlen;
            } else if (std.mem.eql(u8, s, "hget")) {
                lccf.*.command = .hget;
            } else if (std.mem.eql(u8, s, "hset")) {
                lccf.*.command = .hset;
            } else if (std.mem.eql(u8, s, "hdel")) {
                lccf.*.command = .hdel;
            } else {
                return conf.NGX_CONF_ERROR;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

// Helper: write usize as decimal string, return length written
fn write_decimal(out: []u8, value: usize) usize {
    var len_buf: [20]u8 = undefined;
    var v = value;
    var len_pos: usize = 0;
    if (v == 0) {
        out[0] = '0';
        return 1;
    }
    while (v > 0) : (len_pos += 1) {
        len_buf[len_pos] = @intCast('0' + @mod(v, 10));
        v = @divTrunc(v, 10);
    }
    // Reverse into output buffer
    var j: usize = 0;
    while (j < len_pos) : (j += 1) {
        out[j] = len_buf[len_pos - 1 - j];
    }
    return len_pos;
}

// Helper: write bulk string $<len>\r\n<data>\r\n
fn write_bulk_string(out: [*c]u8, pos: *usize, str: ngx_str_t) void {
    out[pos.*] = '$';
    pos.* += 1;
    pos.* += write_decimal(core.slicify(u8, out + pos.*, 20), str.len);
    out[pos.*] = '\r';
    pos.* += 1;
    out[pos.*] = '\n';
    pos.* += 1;
    @memcpy(core.slicify(u8, out + pos.*, str.len), core.slicify(u8, str.data, str.len));
    pos.* += str.len;
    out[pos.*] = '\r';
    pos.* += 1;
    out[pos.*] = '\n';
    pos.* += 1;
}

// Build RESP GET command: *2\r\n$3\r\nGET\r\n$<len>\r\n<key>\r\n
fn build_get_command(key: ngx_str_t, pool: [*c]ngx_pool_t) !ngx_str_t {
    // Calculate buffer size: *2\r\n$3\r\nGET\r\n$<len>\r\n<key>\r\n
    // Max length digits = 20 for usize
    const max_size = 4 + 4 + 3 + 2 + 1 + 20 + 2 + key.len + 2;

    if (core.castPtr(u8, core.ngx_pnalloc(pool, max_size))) |data| {
        var pos: usize = 0;

        // *2\r\n
        const header = "*2\r\n$3\r\nGET\r\n$";
        @memcpy(data[pos..][0..header.len], header);
        pos += header.len;

        // Write key length as decimal
        var len_buf: [20]u8 = undefined;
        var len = key.len;
        var len_pos: usize = 0;
        if (len == 0) {
            len_buf[0] = '0';
            len_pos = 1;
        } else {
            while (len > 0) : (len_pos += 1) {
                len_buf[len_pos] = @intCast('0' + @mod(len, 10));
                len = @divTrunc(len, 10);
            }
            // Reverse
            var j: usize = 0;
            while (j < len_pos / 2) : (j += 1) {
                const tmp = len_buf[j];
                len_buf[j] = len_buf[len_pos - 1 - j];
                len_buf[len_pos - 1 - j] = tmp;
            }
        }
        @memcpy(data[pos..][0..len_pos], len_buf[0..len_pos]);
        pos += len_pos;

        // \r\n
        data[pos] = '\r';
        pos += 1;
        data[pos] = '\n';
        pos += 1;

        // Copy key
        @memcpy(data[pos..][0..key.len], core.slicify(u8, key.data, key.len));
        pos += key.len;

        // \r\n
        data[pos] = '\r';
        pos += 1;
        data[pos] = '\n';
        pos += 1;

        return ngx_str_t{ .data = data, .len = pos };
    }
    return RedisError.OutOfMemory;
}

// Build RESP SET command: *3\r\n$3\r\nSET\r\n$<keylen>\r\n<key>\r\n$<vallen>\r\n<val>\r\n
fn build_set_command(key: ngx_str_t, value: ngx_str_t, pool: [*c]ngx_pool_t) !ngx_str_t {
    const max_size = 64 + key.len + value.len;
    if (core.castPtr(u8, core.ngx_pnalloc(pool, max_size))) |data| {
        var pos: usize = 0;
        const header = "*3\r\n$3\r\nSET\r\n";
        @memcpy(data[pos..][0..header.len], header);
        pos += header.len;
        write_bulk_string(data, &pos, key);
        write_bulk_string(data, &pos, value);
        return ngx_str_t{ .data = data, .len = pos };
    }
    return RedisError.OutOfMemory;
}

// Build RESP DEL command: *2\r\n$3\r\nDEL\r\n$<keylen>\r\n<key>\r\n
fn build_del_command(key: ngx_str_t, pool: [*c]ngx_pool_t) !ngx_str_t {
    const max_size = 64 + key.len;
    if (core.castPtr(u8, core.ngx_pnalloc(pool, max_size))) |data| {
        var pos: usize = 0;
        const header = "*2\r\n$3\r\nDEL\r\n";
        @memcpy(data[pos..][0..header.len], header);
        pos += header.len;
        write_bulk_string(data, &pos, key);
        return ngx_str_t{ .data = data, .len = pos };
    }
    return RedisError.OutOfMemory;
}

// Build RESP INCR command: *2\r\n$4\r\nINCR\r\n$<keylen>\r\n<key>\r\n
fn build_incr_command(key: ngx_str_t, pool: [*c]ngx_pool_t) !ngx_str_t {
    const max_size = 64 + key.len;
    if (core.castPtr(u8, core.ngx_pnalloc(pool, max_size))) |data| {
        var pos: usize = 0;
        const header = "*2\r\n$4\r\nINCR\r\n";
        @memcpy(data[pos..][0..header.len], header);
        pos += header.len;
        write_bulk_string(data, &pos, key);
        return ngx_str_t{ .data = data, .len = pos };
    }
    return RedisError.OutOfMemory;
}

// Build RESP EXPIRE command: *3\r\n$6\r\nEXPIRE\r\n$<keylen>\r\n<key>\r\n$<ttllen>\r\n<ttl>\r\n
fn build_expire_command(key: ngx_str_t, ttl: ngx_str_t, pool: [*c]ngx_pool_t) !ngx_str_t {
    const max_size = 64 + key.len + ttl.len;
    if (core.castPtr(u8, core.ngx_pnalloc(pool, max_size))) |data| {
        var pos: usize = 0;
        const header = "*3\r\n$6\r\nEXPIRE\r\n";
        @memcpy(data[pos..][0..header.len], header);
        pos += header.len;
        write_bulk_string(data, &pos, key);
        write_bulk_string(data, &pos, ttl);
        return ngx_str_t{ .data = data, .len = pos };
    }
    return RedisError.OutOfMemory;
}

// Build RESP MGET command: *<n+1>\r\n$4\r\nMGET\r\n$<len1>\r\n<key1>\r\n...
fn build_mget_command(keys: []const ngx_str_t, count: usize, pool: [*c]ngx_pool_t) !ngx_str_t {
    // Calculate max size
    var total_key_len: usize = 0;
    for (keys[0..count]) |k| {
        total_key_len += k.len;
    }
    const max_size = 64 + total_key_len + count * 32;

    if (core.castPtr(u8, core.ngx_pnalloc(pool, max_size))) |data| {
        var pos: usize = 0;

        // *<count+1>\r\n
        data[pos] = '*';
        pos += 1;
        pos += write_decimal(core.slicify(u8, data + pos, 20), count + 1);
        data[pos] = '\r';
        pos += 1;
        data[pos] = '\n';
        pos += 1;

        // $4\r\nMGET\r\n
        const mget_str = "$4\r\nMGET\r\n";
        @memcpy(data[pos..][0..mget_str.len], mget_str);
        pos += mget_str.len;

        // Write each key
        for (keys[0..count]) |k| {
            write_bulk_string(data, &pos, k);
        }

        return ngx_str_t{ .data = data, .len = pos };
    }
    return RedisError.OutOfMemory;
}

// Helper: build a 2-arg RESP command (*2\r\n$<cmdlen>\r\n<cmd>\r\n$<keylen>\r\n<key>\r\n)
fn build_two_arg_command(comptime cmd: []const u8, key: ngx_str_t, pool: [*c]ngx_pool_t) !ngx_str_t {
    const max_size = 64 + cmd.len + key.len;
    if (core.castPtr(u8, core.ngx_pnalloc(pool, max_size))) |data| {
        var pos: usize = 0;

        // *2\r\n$<cmdlen>\r\n<cmd>\r\n
        const prefix = "*2\r\n$";
        @memcpy(data[pos..][0..prefix.len], prefix);
        pos += prefix.len;
        pos += write_decimal(core.slicify(u8, data + pos, 20), cmd.len);
        data[pos] = '\r';
        pos += 1;
        data[pos] = '\n';
        pos += 1;
        @memcpy(data[pos..][0..cmd.len], cmd);
        pos += cmd.len;
        data[pos] = '\r';
        pos += 1;
        data[pos] = '\n';
        pos += 1;

        // write_bulk_string handles $<len>\r\n<data>\r\n
        write_bulk_string(data, &pos, key);
        return ngx_str_t{ .data = data, .len = pos };
    }
    return RedisError.OutOfMemory;
}

// Build RESP PING command: *1\r\n$4\r\nPING\r\n
fn build_ping_command(pool: [*c]ngx_pool_t) !ngx_str_t {
    const ping_cmd = "*1\r\n$4\r\nPING\r\n";
    if (core.castPtr(u8, core.ngx_pnalloc(pool, ping_cmd.len))) |data| {
        @memcpy(core.slicify(u8, data, ping_cmd.len), ping_cmd);
        return ngx_str_t{ .data = data, .len = ping_cmd.len };
    }
    return RedisError.OutOfMemory;
}

// Build RESP HGET command: *3\r\n$4\r\nHGET\r\n$<keylen>\r\n<key>\r\n$<fieldlen>\r\n<field>\r\n
fn build_hget_command(key: ngx_str_t, field: ngx_str_t, pool: [*c]ngx_pool_t) !ngx_str_t {
    const max_size = 64 + key.len + field.len;
    if (core.castPtr(u8, core.ngx_pnalloc(pool, max_size))) |data| {
        var pos: usize = 0;
        const header = "*3\r\n$4\r\nHGET\r\n";
        @memcpy(data[pos..][0..header.len], header);
        pos += header.len;
        write_bulk_string(data, &pos, key);
        write_bulk_string(data, &pos, field);
        return ngx_str_t{ .data = data, .len = pos };
    }
    return RedisError.OutOfMemory;
}

// Build RESP HSET command: *4\r\n$4\r\nHSET\r\n$<keylen>\r\n<key>\r\n$<fieldlen>\r\n<field>\r\n$<vallen>\r\n<val>\r\n
fn build_hset_command(key: ngx_str_t, field: ngx_str_t, value: ngx_str_t, pool: [*c]ngx_pool_t) !ngx_str_t {
    const max_size = 64 + key.len + field.len + value.len;
    if (core.castPtr(u8, core.ngx_pnalloc(pool, max_size))) |data| {
        var pos: usize = 0;
        const header = "*4\r\n$4\r\nHSET\r\n";
        @memcpy(data[pos..][0..header.len], header);
        pos += header.len;
        write_bulk_string(data, &pos, key);
        write_bulk_string(data, &pos, field);
        write_bulk_string(data, &pos, value);
        return ngx_str_t{ .data = data, .len = pos };
    }
    return RedisError.OutOfMemory;
}

// Build RESP HDEL command: *3\r\n$4\r\nHDEL\r\n$<keylen>\r\n<key>\r\n$<fieldlen>\r\n<field>\r\n
fn build_hdel_command(key: ngx_str_t, field: ngx_str_t, pool: [*c]ngx_pool_t) !ngx_str_t {
    const max_size = 64 + key.len + field.len;
    if (core.castPtr(u8, core.ngx_pnalloc(pool, max_size))) |data| {
        var pos: usize = 0;
        const header = "*3\r\n$4\r\nHDEL\r\n";
        @memcpy(data[pos..][0..header.len], header);
        pos += header.len;
        write_bulk_string(data, &pos, key);
        write_bulk_string(data, &pos, field);
        return ngx_str_t{ .data = data, .len = pos };
    }
    return RedisError.OutOfMemory;
}

// Get key to query
fn get_redis_key(r: [*c]ngx_http_request_t, lccf: [*c]redis_loc_conf) ngx_str_t {
    if (lccf.*.key.len > 0) {
        return lccf.*.key;
    }
    var key = r.*.uri;
    if (key.len > 0 and key.data[0] == '/') {
        key.data += 1;
        key.len -= 1;
    }
    return key;
}

////////////////////////////  REDIS UPSTREAM  //////////////////////////////////////////////////

fn ngx_http_redis_upstream_create_request(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    if (core.castPtr(
        redis_request_ctx,
        r.*.ctx[ngx_http_redis_module.ctx_index],
    )) |rctx| {
        // Build command based on type
        const cmd = switch (rctx.*.command) {
            .get => build_get_command(rctx.*.key, r.*.pool),
            .set => build_set_command(rctx.*.key, rctx.*.value, r.*.pool),
            .del => build_del_command(rctx.*.key, r.*.pool),
            .incr => build_incr_command(rctx.*.key, r.*.pool),
            .decr => build_two_arg_command("DECR", rctx.*.key, r.*.pool),
            .expire => build_expire_command(rctx.*.key, rctx.*.value, r.*.pool),
            .mget => build_mget_command(&rctx[0].mget_keys, rctx.*.mget_count, r.*.pool),
            .exists => build_two_arg_command("EXISTS", rctx.*.key, r.*.pool),
            .ttl => build_two_arg_command("TTL", rctx.*.key, r.*.pool),
            .ping => build_ping_command(r.*.pool),
            .strlen => build_two_arg_command("STRLEN", rctx.*.key, r.*.pool),
            .hget => build_hget_command(rctx.*.key, rctx.*.field, r.*.pool),
            .hset => build_hset_command(rctx.*.key, rctx.*.field, rctx.*.value, r.*.pool),
            .hdel => build_hdel_command(rctx.*.key, rctx.*.field, r.*.pool),
        } catch return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

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
            "redis: sending command for key: %V",
            .{&rctx.*.key},
        );
    }
    return NGX_OK;
}

// Build JSON response from Redis value
fn build_json_response(rctx: [*c]redis_request_ctx, pool: [*c]ngx_pool_t) ?ngx_str_t {
    if (rctx.*.data_len < 0) {
        return ngx_string("{\"value\":null}");
    }

    if (rctx.*.data.len == 0) {
        return if (rctx.*.command == .set or rctx.*.command == .ping or rctx.*.command == .hset)
            ngx_string("{\"ok\":true}")
        else
            ngx_string("{\"value\":\"\"}");
    }

    const value = core.slicify(u8, rctx.*.data.data, rctx.*.data.len);
    const is_int_cmd = switch (rctx.*.command) {
        .incr, .decr, .del, .expire, .exists, .ttl, .strlen, .hset, .hdel => true,
        else => false,
    };
    if (is_int_cmd) _ = std.fmt.parseInt(i64, value, 10) catch return null;

    const prefix = "{\"value\":";
    const suffix = if (is_int_cmd) "}" else "\"}";
    const escaped_len = if (is_int_cmd) value.len else escapedJsonLen(value) orelse return null;
    const quote_len: usize = if (is_int_cmd) 0 else 1;
    const total = prefix.len + quote_len + escaped_len + suffix.len;
    if (total > REDIS_MAX_JSON_SIZE) return null;
    const data = core.castPtr(u8, core.ngx_pnalloc(pool, total)) orelse return null;
    var writer = JsonWriter{ .bytes = core.slicify(u8, data, total) };
    if (!writer.append(prefix)) return null;
    if (!is_int_cmd and !writer.appendByte('"')) return null;
    if (is_int_cmd) {
        if (!writer.append(value)) return null;
    } else if (!writer.appendEscaped(value)) return null;
    if (!writer.append(suffix) or writer.len != total) return null;
    return .{ .data = data, .len = total };
}

// Build JSON array response from MGET results
fn build_mget_json_response(values: [][2]ngx_str_t, count: usize, pool: [*c]ngx_pool_t) ?ngx_str_t {
    const prefix = "{\"values\":[";
    const suffix = "]}";
    if (count > values.len or count > REDIS_MAX_ARRAY_ITEMS) return null;

    var total = prefix.len + suffix.len + if (count > 0) count - 1 else 0;
    if (total > REDIS_MAX_JSON_SIZE) return null;
    for (values[0..count]) |item| {
        if (item[0].len == 0) {
            total += 4;
        } else {
            const value = core.slicify(u8, item[1].data, item[1].len);
            const escaped = escapedJsonLen(value) orelse return null;
            if (escaped + 2 > REDIS_MAX_JSON_SIZE - total) return null;
            total += escaped + 2;
        }
    }
    if (total > REDIS_MAX_JSON_SIZE) return null;

    const data = core.castPtr(u8, core.ngx_pnalloc(pool, total)) orelse return null;
    var writer = JsonWriter{ .bytes = core.slicify(u8, data, total) };
    if (!writer.append(prefix)) return null;
    for (values[0..count], 0..) |item, i| {
        if (i > 0 and !writer.appendByte(',')) return null;
        if (item[0].len == 0) {
            if (!writer.append("null")) return null;
        } else {
            if (!writer.appendByte('"') or
                !writer.appendEscaped(core.slicify(u8, item[1].data, item[1].len)) or
                !writer.appendByte('"')) return null;
        }
    }
    if (!writer.append(suffix) or writer.len != total) return null;
    return .{ .data = data, .len = total };
}

// Parse RESP response - Redis doesn't use HTTP headers
// Response format: $<len>\r\n<data>\r\n or $-1\r\n (nil) or -ERR msg\r\n (error)
fn ngx_http_redis_upstream_process_header(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    if (core.castPtr(
        redis_request_ctx,
        r.*.ctx[ngx_http_redis_module.ctx_index],
    )) |rctx| {
        const u = r.*.upstream;
        const b = &u.*.buffer;
        const received_len = @intFromPtr(b.*.last) - @intFromPtr(b.*.pos);
        const received = core.slicify(u8, b.*.pos, received_len);

        // Need at least type byte + \r\n
        if (received.len < 3) {
            return NGX_AGAIN;
        }

        const type_byte = b.*.pos[0];

        switch (type_byte) {
            '$' => {
                // Bulk string: $<len>\r\n<data>\r\n
                const line_end = std.mem.indexOf(u8, received[1..], "\r\n") orelse return NGX_AGAIN;
                const length_text = received[1 .. 1 + line_end];
                const data_start_idx = 1 + line_end + 2;

                if (std.mem.eql(u8, length_text, "-1")) {
                    // Nil response ($-1\r\n)
                    rctx.*.data_len = -1;
                    rctx.*.data = ngx.string.ngx_null_str;
                    rctx.*.state = .done;
                    rctx.*.last_exists = 0;
                } else {
                    const needed = std.fmt.parseInt(usize, length_text, 10) catch {
                        rctx.*.state = .resp_error;
                        return http.NGX_HTTP_UPSTREAM_INVALID_HEADER;
                    };
                    if (needed > REDIS_MAX_VALUE_SIZE) {
                        rctx.*.state = .resp_error;
                        return http.NGX_HTTP_UPSTREAM_INVALID_HEADER;
                    }
                    if (data_start_idx > received.len or received.len - data_start_idx < needed + 2) return NGX_AGAIN;
                    if (received[data_start_idx + needed] != '\r' or received[data_start_idx + needed + 1] != '\n') {
                        rctx.*.state = .resp_error;
                        return http.NGX_HTTP_UPSTREAM_INVALID_HEADER;
                    }

                    // Copy data to request pool
                    if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, needed))) |data_copy| {
                        @memcpy(core.slicify(u8, data_copy, needed), received[data_start_idx..][0..needed]);
                        rctx.*.data = ngx_str_t{ .data = data_copy, .len = needed };
                    } else {
                        return NGX_ERROR;
                    }

                    rctx.*.data_len = @intCast(needed);
                    rctx.*.state = .done;
                    rctx.*.last_exists = 1;
                }

                // Build JSON response and replace buffer content
                if (build_json_response(rctx, r.*.pool)) |json| {
                    // Replace buffer with JSON
                    b.*.pos = json.data;
                    b.*.last = json.data + json.len;

                    u.*.headers_in.status_n = 200;
                    u.*.headers_in.content_length_n = @intCast(json.len);
                    // Set length to 0 - we've consumed all upstream data
                    // The content is already in the buffer ready to be sent
                    u.*.length = 0;

                    // Set content-type header
                    r.*.headers_out.content_type = ngx_str_t{ .len = 16, .data = @constCast("application/json") };
                    r.*.headers_out.content_type_len = 16;
                    r.*.headers_out.content_type_lowcase = null;
                } else return NGX_ERROR;

                return NGX_OK;
            },
            '-' => {
                // Error response: -ERR message\r\n
                if (std.mem.indexOf(u8, received[1..], "\r\n") == null) return NGX_AGAIN;
                rctx.*.last_error = 1;
                rctx.*.state = .resp_error;
                rctx.*.data_len = -1;
                rctx.*.data = ngx.string.ngx_null_str;

                // Build error JSON
                const error_json = "{\"error\":\"redis_error\"}";
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

                return NGX_OK;
            },
            '+' => {
                // Simple string: +OK\r\n
                if (std.mem.indexOf(u8, received[1..], "\r\n") == null) return NGX_AGAIN;
                rctx.*.data_len = 0;
                rctx.*.data = ngx.string.ngx_null_str;
                rctx.*.state = .done;
                rctx.*.last_exists = 1;

                // Build empty value JSON
                if (build_json_response(rctx, r.*.pool)) |json| {
                    b.*.pos = json.data;
                    b.*.last = json.data + json.len;
                    u.*.headers_in.status_n = 200;
                    u.*.headers_in.content_length_n = @intCast(json.len);
                    u.*.length = 0;

                    r.*.headers_out.content_type = ngx_str_t{ .len = 16, .data = @constCast("application/json") };
                    r.*.headers_out.content_type_len = 16;
                    r.*.headers_out.content_type_lowcase = null;
                } else return NGX_ERROR;

                return NGX_OK;
            },
            ':' => {
                // Integer: :1000\r\n - treat as string
                const int_len = std.mem.indexOf(u8, received[1..], "\r\n") orelse return NGX_AGAIN;
                const int_text = received[1 .. 1 + int_len];
                _ = std.fmt.parseInt(i64, int_text, 10) catch {
                    rctx.*.state = .resp_error;
                    return http.NGX_HTTP_UPSTREAM_INVALID_HEADER;
                };
                if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, int_len))) |data_copy| {
                    @memcpy(core.slicify(u8, data_copy, int_len), int_text);
                    rctx.*.data = ngx_str_t{ .data = data_copy, .len = int_len };
                } else {
                    return NGX_ERROR;
                }

                rctx.*.data_len = @intCast(int_len);
                rctx.*.state = .done;
                rctx.*.last_exists = 1;

                if (build_json_response(rctx, r.*.pool)) |json| {
                    b.*.pos = json.data;
                    b.*.last = json.data + json.len;
                    u.*.headers_in.status_n = 200;
                    u.*.headers_in.content_length_n = @intCast(json.len);
                    u.*.length = 0;

                    r.*.headers_out.content_type = ngx_str_t{ .len = 16, .data = @constCast("application/json") };
                    r.*.headers_out.content_type_len = 16;
                    r.*.headers_out.content_type_lowcase = null;
                } else return NGX_ERROR;

                return NGX_OK;
            },
            '*' => {
                // Array response (MGET): *<count>\r\n<elements>
                const count_end = std.mem.indexOf(u8, received[1..], "\r\n") orelse return NGX_AGAIN;
                const count = std.fmt.parseInt(usize, received[1 .. 1 + count_end], 10) catch {
                    rctx.*.state = .resp_error;
                    return http.NGX_HTTP_UPSTREAM_INVALID_HEADER;
                };
                if (count > REDIS_MAX_ARRAY_ITEMS or count != rctx.*.mget_count) {
                    rctx.*.state = .resp_error;
                    return http.NGX_HTTP_UPSTREAM_INVALID_HEADER;
                }
                var pos: usize = 1 + count_end + 2;

                // Parse each array element
                var values = std.mem.zeroes([REDIS_MAX_ARRAY_ITEMS][2]ngx_str_t); // [is_present, value]
                var idx: usize = 0;
                while (idx < count) : (idx += 1) {
                    if (pos >= received.len) return NGX_AGAIN;
                    if (received[pos] == '$') {
                        const elem_line_rel = std.mem.indexOf(u8, received[pos + 1 ..], "\r\n") orelse return NGX_AGAIN;
                        const elem_text = received[pos + 1 .. pos + 1 + elem_line_rel];
                        pos += 1 + elem_line_rel + 2;

                        if (std.mem.eql(u8, elem_text, "-1")) {
                            values[idx][0] = ngx.string.ngx_null_str; // nil marker
                            values[idx][1] = ngx.string.ngx_null_str;
                        } else {
                            const elem_len = std.fmt.parseInt(usize, elem_text, 10) catch {
                                rctx.*.state = .resp_error;
                                return http.NGX_HTTP_UPSTREAM_INVALID_HEADER;
                            };
                            if (elem_len > REDIS_MAX_VALUE_SIZE) {
                                rctx.*.state = .resp_error;
                                return http.NGX_HTTP_UPSTREAM_INVALID_HEADER;
                            }
                            if (pos > received.len or received.len - pos < elem_len + 2) return NGX_AGAIN;
                            if (received[pos + elem_len] != '\r' or received[pos + elem_len + 1] != '\n') {
                                rctx.*.state = .resp_error;
                                return http.NGX_HTTP_UPSTREAM_INVALID_HEADER;
                            }

                            // Copy value
                            if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, elem_len))) |val_copy| {
                                @memcpy(core.slicify(u8, val_copy, elem_len), received[pos..][0..elem_len]);
                                values[idx][0] = ngx_str_t{ .data = @constCast("1"), .len = 1 }; // present marker
                                values[idx][1] = ngx_str_t{ .data = val_copy, .len = elem_len };
                            } else {
                                return NGX_ERROR;
                            }
                            pos += elem_len + 2;
                        }
                    } else {
                        rctx.*.state = .resp_error;
                        return http.NGX_HTTP_UPSTREAM_INVALID_HEADER;
                    }
                }

                rctx.*.state = .done;
                rctx.*.last_exists = 1;

                // Build MGET JSON response
                if (build_mget_json_response(&values, count, r.*.pool)) |json| {
                    b.*.pos = json.data;
                    b.*.last = json.data + json.len;
                    u.*.headers_in.status_n = 200;
                    u.*.headers_in.content_length_n = @intCast(json.len);
                    u.*.length = 0;

                    r.*.headers_out.content_type = ngx_str_t{ .len = 16, .data = @constCast("application/json") };
                    r.*.headers_out.content_type_len = 16;
                    r.*.headers_out.content_type_lowcase = null;
                } else return NGX_ERROR;

                return NGX_OK;
            },
            else => {
                rctx.*.state = .resp_error;
                return http.NGX_HTTP_UPSTREAM_INVALID_HEADER;
            },
        }
    }
    return NGX_ERROR;
}

fn ngx_http_redis_upstream_input_filter_init(
    ctx: ?*anyopaque,
) callconv(.c) ngx_int_t {
    if (core.castPtr(ngx_http_request_t, ctx)) |r| {
        const u = r.*.upstream;
        // Set length to the content we'll send - will be decremented in filter
        u.*.length = u.*.headers_in.content_length_n;
    }
    return NGX_OK;
}

fn ngx_http_redis_upstream_input_filter(
    ctx: ?*anyopaque,
    bytes: isize,
) callconv(.c) ngx_int_t {
    if (core.castPtr(ngx_http_request_t, ctx)) |r| {
        const u = r.*.upstream;
        const b = &u.*.buffer;

        // Find the end of out_bufs chain
        var ll: [*c][*c]ngx_chain_t = &u.*.out_bufs;
        while (ll.* != core.nullptr(ngx_chain_t)) {
            ll = &ll.*.*.next;
        }

        // Get a free buffer from the pool
        if (buf.ngx_chain_get_free_buf(r.*.pool, &u.*.free_bufs)) |cl| {
            cl.*.buf.*.flags.flush = true;
            cl.*.buf.*.flags.memory = true;

            // Point to the data in the upstream buffer
            const last = b.*.last;
            cl.*.buf.*.pos = last;
            b.*.last += @intCast(bytes);
            cl.*.buf.*.last = b.*.last;
            cl.*.buf.*.tag = u.*.output.tag;

            // Add to output chain
            ll.* = cl;

            // Decrement remaining length
            u.*.length -= bytes;

            // When done, allow connection reuse (Redis can pipeline)
            if (u.*.length == 0) {
                u.*.flags.keepalive = true;
            }

            return NGX_OK;
        }
    }
    return NGX_ERROR;
}

fn ngx_http_redis_upstream_finalize_request(
    r: [*c]ngx_http_request_t,
    rc: ngx_int_t,
) callconv(.c) void {
    _ = rc;
    if (core.castPtr(redis_request_ctx, r.*.ctx[ngx_http_redis_module.ctx_index])) |rctx| {
        if (rctx.*.state != .done and rctx.*.state != .resp_error) {
            rctx.*.conn_failed = 1;
        }
    }
}

fn create_upstream(
    r: [*c]ngx_http_request_t,
    rctx: [*c]redis_request_ctx,
) !ngx_int_t {
    if (http.ngx_http_upstream_create(r) != NGX_OK) {
        return RedisError.UpstreamCreateFailed;
    }

    const lccf: [*c]redis_loc_conf = rctx.*.lccf;
    r.*.upstream.*.conf = &lccf.*.ups;
    r.*.upstream.*.flags.buffering = false;
    r.*.upstream.*.create_request = ngx_http_redis_upstream_create_request;
    r.*.upstream.*.process_header = ngx_http_redis_upstream_process_header;
    r.*.upstream.*.input_filter_init = ngx_http_redis_upstream_input_filter_init;
    r.*.upstream.*.input_filter = ngx_http_redis_upstream_input_filter;
    r.*.upstream.*.finalize_request = ngx_http_redis_upstream_finalize_request;
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

    return RedisError.OutOfMemory;
}

// Body handler - called after request body is read/discarded
export fn ngx_http_redis_body_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) void {
    if (core.castPtr(
        redis_request_ctx,
        r.*.ctx[ngx_http_redis_module.ctx_index],
    )) |rctx| {
        // Extract value from request body for SET, EXPIRE, and HSET
        if (rctx.*.command == .set or rctx.*.command == .expire or rctx.*.command == .hset) {
            rctx.*.value = get_request_body(r);
            if (rctx.*.value.len == 0 and rctx.*.command == .set) {
                // SET requires a value
                http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
                return;
            }
            if (rctx.*.value.len == 0 and rctx.*.command == .expire) {
                // EXPIRE requires TTL - default to 60 seconds
                rctx.*.value = ngx_string("60");
            }
            if (rctx.*.value.len == 0 and rctx.*.command == .hset) {
                // HSET requires a value
                http.ngx_http_finalize_request(r, http.NGX_HTTP_BAD_REQUEST);
                return;
            }
        }

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

// Parse request body content from chain
fn get_request_body(r: [*c]ngx_http_request_t) ngx_str_t {
    if (r.*.request_body == core.nullptr(http.ngx_http_request_body_t)) {
        return ngx.string.ngx_null_str;
    }
    if (r.*.request_body.*.bufs == core.nullptr(ngx_chain_t)) {
        const tf = r.*.request_body.*.temp_file;
        if (tf == core.nullptr(file.ngx_temp_file_t)) {
            return ngx.string.ngx_null_str;
        }

        const total_off = if (r.*.request_body.*.received > 0) r.*.request_body.*.received else tf.*.offset;
        if (total_off <= 0) {
            return ngx.string.ngx_null_str;
        }

        const total: usize = @intCast(total_off);
        const raw = core.ngx_pnalloc(r.*.pool, total) orelse return ngx.string.ngx_null_str;
        const out = core.castPtr(u8, raw) orelse return ngx.string.ngx_null_str;
        const read_len = file.ngx_read_file(&tf.*.file, out, total, 0);
        if (read_len == NGX_ERROR or @as(usize, @intCast(read_len)) != total) {
            return ngx.string.ngx_null_str;
        }
        return ngx_str_t{ .data = out, .len = total };
    }

    var total: usize = 0;
    var chain = r.*.request_body.*.bufs;
    while (chain != core.nullptr(ngx_chain_t)) : (chain = chain.*.next) {
        const b = chain.*.buf;
        if (b == core.nullptr(ngx_buf_t) or buf.ngx_buf_special(b)) continue;
        const chunk_len = buf.ngx_buf_size(b);
        if (chunk_len < 0) return ngx.string.ngx_null_str;
        total += @intCast(chunk_len);
    }

    if (total == 0) {
        const tf = r.*.request_body.*.temp_file;
        if (tf == core.nullptr(file.ngx_temp_file_t)) {
            return ngx.string.ngx_null_str;
        }

        const total_off = if (r.*.request_body.*.received > 0) r.*.request_body.*.received else tf.*.offset;
        if (total_off <= 0) {
            return ngx.string.ngx_null_str;
        }

        const file_total: usize = @intCast(total_off);
        const raw = core.ngx_pnalloc(r.*.pool, file_total) orelse return ngx.string.ngx_null_str;
        const out = core.castPtr(u8, raw) orelse return ngx.string.ngx_null_str;
        const read_len = file.ngx_read_file(&tf.*.file, out, file_total, 0);
        if (read_len == NGX_ERROR or @as(usize, @intCast(read_len)) != file_total) {
            return ngx.string.ngx_null_str;
        }
        return ngx_str_t{ .data = out, .len = file_total };
    }

    const raw = core.ngx_pnalloc(r.*.pool, total) orelse return ngx.string.ngx_null_str;
    const out = core.castPtr(u8, raw) orelse return ngx.string.ngx_null_str;

    var offset: usize = 0;
    chain = r.*.request_body.*.bufs;
    while (chain != core.nullptr(ngx_chain_t)) : (chain = chain.*.next) {
        const b = chain.*.buf;
        if (b == core.nullptr(ngx_buf_t) or buf.ngx_buf_special(b)) continue;

        const chunk_len_off = buf.ngx_buf_size(b);
        if (chunk_len_off < 0) return ngx.string.ngx_null_str;
        const chunk_len: usize = @intCast(chunk_len_off);
        if (chunk_len == 0) continue;

        if (buf.ngx_buf_in_memory_only(b)) {
            @memcpy(out[offset .. offset + chunk_len], core.slicify(u8, b.*.pos, chunk_len));
            offset += chunk_len;
            continue;
        }

        if (b.*.flags.in_file and b.*.file != core.nullptr(file.ngx_file_t)) {
            const read_len = file.ngx_read_file(b.*.file, out + offset, chunk_len, b.*.file_pos);
            if (read_len == NGX_ERROR or @as(usize, @intCast(read_len)) != chunk_len) {
                return ngx.string.ngx_null_str;
            }
            offset += chunk_len;
            continue;
        }

        return ngx.string.ngx_null_str;
    }

    return ngx_str_t{ .data = out, .len = offset };
}

// Parse comma-separated keys from query string for MGET
fn parse_mget_keys(r: [*c]ngx_http_request_t, rctx: [*c]redis_request_ctx) void {
    // Look for ?keys=key1,key2,key3 in args
    if (r.*.args.len == 0) {
        // Use URI as single key
        rctx[0].mget_keys[0] = get_redis_key(r, rctx.*.lccf);
        rctx.*.mget_count = 1;
        return;
    }

    // Parse keys=... from query string
    const args = core.slicify(u8, r.*.args.data, r.*.args.len);
    var pos: usize = 0;

    // Find keys= parameter
    while (pos + 5 < args.len) : (pos += 1) {
        if (std.mem.eql(u8, args[pos..][0..5], "keys=")) {
            pos += 5;
            break;
        }
    }

    if (pos + 5 >= args.len and !std.mem.eql(u8, args[0..@min(5, args.len)], "keys=")) {
        // No keys= found, use URI as single key
        rctx[0].mget_keys[0] = get_redis_key(r, rctx.*.lccf);
        rctx.*.mget_count = 1;
        return;
    }

    if (pos == 0 and args.len >= 5 and std.mem.eql(u8, args[0..5], "keys=")) {
        pos = 5;
    }

    // Parse comma-separated keys
    var count: ngx_uint_t = 0;
    var key_start = pos;

    while (pos <= args.len and count < 16) {
        const is_end = pos == args.len;
        const is_sep = !is_end and (args[pos] == ',' or args[pos] == '&');

        if (is_end or is_sep) {
            const key_len = pos - key_start;
            if (key_len > 0) {
                // Copy key to pool
                if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, key_len))) |key_copy| {
                    @memcpy(core.slicify(u8, key_copy, key_len), args[key_start..pos]);
                    rctx[0].mget_keys[count] = ngx_str_t{ .data = key_copy, .len = key_len };
                    count += 1;
                }
            }
            if (is_end or args[pos] == '&') break;
            key_start = pos + 1;
        }
        pos += 1;
    }

    rctx.*.mget_count = count;
    if (count == 0) {
        // Fallback to URI as single key
        rctx[0].mget_keys[0] = get_redis_key(r, rctx.*.lccf);
        rctx.*.mget_count = 1;
    }
}

// Parse a named query parameter from the request args.
// Returns ngx_null_str if the parameter is not found.
fn parse_query_param(r: [*c]ngx_http_request_t, comptime name: []const u8) ngx_str_t {
    if (r.*.args.len == 0) return ngx.string.ngx_null_str;
    const args = core.slicify(u8, r.*.args.data, r.*.args.len);
    var pos: usize = 0;

    while (pos + name.len + 1 < args.len) : (pos += 1) {
        if (std.mem.eql(u8, args[pos..][0..name.len], name) and args[pos + name.len] == '=') {
            pos += name.len + 1; // skip "name="
            const val_start = pos;
            while (pos < args.len and args[pos] != '&') : (pos += 1) {}
            const val_len = pos - val_start;
            if (val_len > 0) {
                if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, val_len))) |val_copy| {
                    @memcpy(core.slicify(u8, val_copy, val_len), args[val_start..pos]);
                    return ngx_str_t{ .data = val_copy, .len = val_len };
                }
            }
            break;
        }
    }
    return ngx.string.ngx_null_str;
}

export fn ngx_http_redis_handler(
    r: [*c]ngx_http_request_t,
) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        redis_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_redis_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) {
        return NGX_DECLINED;
    }

    // Determine command based on config and HTTP method
    var command = lccf.*.command;

    // Map HTTP methods to commands if using default GET command
    if (command == .get) {
        if (r.*.method == http.NGX_HTTP_DELETE) {
            command = .del;
        } else if (r.*.method != http.NGX_HTTP_GET and r.*.method != http.NGX_HTTP_POST) {
            return http.NGX_HTTP_NOT_ALLOWED;
        }
    }

    // Validate HTTP method for command
    switch (command) {
        .get, .mget, .exists, .ttl, .strlen, .hget => {
            if (r.*.method != http.NGX_HTTP_GET) {
                return http.NGX_HTTP_NOT_ALLOWED;
            }
        },
        .set, .incr, .decr, .expire, .hset => {
            if (r.*.method != http.NGX_HTTP_POST) {
                return http.NGX_HTTP_NOT_ALLOWED;
            }
        },
        .del, .hdel => {
            if (r.*.method != http.NGX_HTTP_DELETE and r.*.method != http.NGX_HTTP_POST) {
                return http.NGX_HTTP_NOT_ALLOWED;
            }
        },
        .ping => {
            // PING accepts any method
        },
    }

    // Get or create request context
    const rctx = http.ngz_http_get_module_ctx(
        redis_request_ctx,
        r,
        &ngx_http_redis_module,
    ) catch return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

    if (rctx.*.lccf == core.nullptr(redis_loc_conf)) {
        rctx.*.lccf = lccf;
        rctx.*.command = command;
        rctx.*.key = get_redis_key(r, lccf);
        rctx.*.value = ngx.string.ngx_null_str;
        rctx.*.field = ngx.string.ngx_null_str;
        rctx.*.state = .start;
        rctx.*.data_len = 0;
        rctx.*.data = ngx.string.ngx_null_str;
        rctx.*.mget_count = 0;

        // Parse MGET keys from query string
        if (command == .mget) {
            parse_mget_keys(r, rctx);
        }

        // Parse field from query string for hash commands
        if (command == .hget or command == .hset or command == .hdel) {
            rctx.*.field = parse_query_param(r, "field");
            if (rctx.*.field.len == 0) {
                // field is required for hash commands
                return http.NGX_HTTP_BAD_REQUEST;
            }
        }
    }

    // Read request body (needed for SET/EXPIRE with value in body)
    const rc = http.ngx_http_read_client_request_body(r, ngx_http_redis_body_handler);
    if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) {
        return rc;
    }
    return core.NGX_DONE;
}

const ngx_http_variable_value_t = http.ngx_http_variable_value_t;

const REDIS_VAR_LAST_VALUE: core.uintptr_t = 0;
const REDIS_VAR_LAST_EXISTS: core.uintptr_t = 1;
const REDIS_VAR_LAST_ERROR: core.uintptr_t = 2;
const REDIS_VAR_CONN_STATE: core.uintptr_t = 3;

fn ngx_http_redis_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    const rctx = core.castPtr(redis_request_ctx, r.*.ctx[ngx_http_redis_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };

    switch (data) {
        REDIS_VAR_LAST_VALUE => {
            if (rctx.*.last_exists == 1 and rctx.*.data.len > 0) {
                v.*.data = rctx.*.data.data;
                v.*.flags.len = @intCast(rctx.*.data.len);
            } else {
                v.*.flags.not_found = true;
                return NGX_OK;
            }
        },
        REDIS_VAR_LAST_EXISTS => {
            v.*.data = if (rctx.*.last_exists == 1) @constCast("1") else @constCast("0");
            v.*.flags.len = 1;
        },
        REDIS_VAR_LAST_ERROR => {
            if (rctx.*.last_error == 1) {
                v.*.data = @constCast("redis_error");
                v.*.flags.len = 11;
            } else if (rctx.*.conn_failed == 1) {
                v.*.data = @constCast("connection_failed");
                v.*.flags.len = 17;
            } else {
                v.*.flags.not_found = true;
                return NGX_OK;
            }
        },
        REDIS_VAR_CONN_STATE => {
            if (rctx.*.conn_failed == 1) {
                v.*.data = @constCast("error");
                v.*.flags.len = 5;
            } else if (rctx.*.last_error == 1) {
                v.*.data = @constCast("degraded");
                v.*.flags.len = 8;
            } else {
                v.*.data = @constCast("connected");
                v.*.flags.len = 9;
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
        http.ngx_http_variable_t{ .name = ngx_string("redis_last_value"), .set_handler = null, .get_handler = ngx_http_redis_variable, .data = REDIS_VAR_LAST_VALUE, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("redis_last_exists"), .set_handler = null, .get_handler = ngx_http_redis_variable, .data = REDIS_VAR_LAST_EXISTS, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("redis_last_error"), .set_handler = null, .get_handler = ngx_http_redis_variable, .data = REDIS_VAR_LAST_ERROR, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("redis_connection_state"), .set_handler = null, .get_handler = ngx_http_redis_variable, .data = REDIS_VAR_CONN_STATE, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
    };
    for (&vs) |*v| {
        if (http.ngx_http_add_variable(cf, &v.name, v.flags)) |x| {
            x.*.get_handler = v.get_handler;
            x.*.data = v.data;
        }
    }
    return NGX_OK;
}

export const ngx_http_redis_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_redis_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("redis_pass"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_redis_pass,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("redis_key"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(redis_loc_conf, "key"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("redis_command"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_redis_command,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_redis_module = ngx.module.make_module(
    @constCast(&ngx_http_redis_commands),
    @constCast(&ngx_http_redis_module_ctx),
);

// Tests
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "redis module" {
    try expect(ngx_http_redis_module.version > 0);
}

test "parse_host_port" {
    const r1 = parse_host_port(ngx_string("localhost:6379"));
    try expectEqual(r1.port, 6379);
    try expectEqual(r1.host.len, 9);

    const r2 = parse_host_port(ngx_string("127.0.0.1:6380"));
    try expectEqual(r2.port, 6380);
    try expectEqual(r2.host.len, 9);

    const r3 = parse_host_port(ngx_string("redis.local"));
    try expectEqual(r3.port, 6379);
    try expectEqual(r3.host.len, 11);
}

test "JSON writer preserves content and rejects overflow" {
    const input = "quote\" slash\\ line\n\x01";
    try expectEqual(@as(?usize, 28), escapedJsonLen(input));

    var storage: [28]u8 = undefined;
    var writer = JsonWriter{ .bytes = &storage };
    try expect(writer.appendEscaped(input));
    try expectEqual(storage.len, writer.len);
    try expect(std.mem.eql(u8, &storage, "quote\\\" slash\\\\ line\\n\\u0001"));
    try expect(!writer.appendByte('x'));
}

test "MGET JSON renderer rejects counts beyond its storage contract" {
    var values = std.mem.zeroes([REDIS_MAX_ARRAY_ITEMS + 1][2]ngx_str_t);
    try expect(build_mget_json_response(&values, values.len, core.nullptr(ngx_pool_t)) == null);
}
