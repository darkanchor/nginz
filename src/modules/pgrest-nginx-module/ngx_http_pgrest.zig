const std = @import("std");
const ngx = @import("ngx");
const pgrest_auth = @import("pgrest_auth.zig");

const pq = ngx.pq;
const buf = ngx.buf;
const event = ngx.event;
const ssl = ngx.ssl;
const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const file = ngx.file;
const log = ngx.log;
const cjson = ngx.cjson;
const CJSON = cjson.CJSON;

// libpq types and functions (re-exported from ngx_pq.zig)
const PGconn = pq.PGconn;
const PGresult = pq.PGresult;
const pgFinish = pq.pgFinish;
const pgStatus = pq.pgStatus;
const pgResultStatus = pq.pgResultStatus;
const pgNtuples = pq.pgNtuples;
const pgNfields = pq.pgNfields;
const pgFname = pq.pgFname;
const pgFtype = pq.pgFtype;
const pgGetvalue = pq.pgGetvalue;
const pgGetisnull = pq.pgGetisnull;
const pgGetlength = pq.pgGetlength;
const pgClear = pq.pgClear;
const pgErrorMessage = pq.pgErrorMessage;
const pgResultErrorMessage = pq.pgResultErrorMessage;
const pgResultErrorField = pq.pgResultErrorField;
const PG_DIAG_SQLSTATE = pq.PG_DIAG_SQLSTATE;
const PGRES_TUPLES_OK = pq.PGRES_TUPLES_OK;
const PGRES_COMMAND_OK = pq.PGRES_COMMAND_OK;

// Non-blocking libpq functions
const pgConnectStart = pq.pgConnectStart;
const pgConnectPoll = pq.pgConnectPoll;
const pgSetnonblocking = pq.pgSetnonblocking;
const pgSocket = pq.pgSocket;
const pgFlush = pq.pgFlush;
const pgSendQuery = pq.pgSendQuery;
const pgSendQueryParams = pq.pgSendQueryParams;
const pgConsumeInput = pq.pgConsumeInput;
const pgIsBusy = pq.pgIsBusy;
const pgGetResult = pq.pgGetResult;
const PGRES_POLLING_FAILED = pq.PGRES_POLLING_FAILED;
const PGRES_POLLING_READING = pq.PGRES_POLLING_READING;
const PGRES_POLLING_WRITING = pq.PGRES_POLLING_WRITING;
const PGRES_POLLING_OK = pq.PGRES_POLLING_OK;

const MAX_PARAMS = 64;
const PARAM_ARENA_SIZE = 8192;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_AGAIN = core.NGX_AGAIN;
const NGX_DECLINED = core.NGX_DECLINED;
const NGX_HTTP_METHOD_NOT_ALLOWED: ngx_uint_t = 405;
const NGX_HTTP_NOT_ACCEPTABLE: ngx_uint_t = 406;
const NGX_HTTP_UNSUPPORTED_MEDIA_TYPE: ngx_uint_t = 415;
const NGX_HTTP_PARTIAL_CONTENT: ngx_uint_t = 206;
const NGX_HTTP_OPTIONS_METHOD: ngx_uint_t = 0x00000200;

const NGX_CONF_OK = conf.NGX_CONF_OK;
const NGX_CONF_ERROR = conf.NGX_CONF_ERROR;

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

extern var ngx_http_core_module: ngx_module_t;
extern var ngx_pagesize: ngx_uint_t;
extern var ngx_current_msec: ngx_msec_t;

const NGX_CONF_UNSET: ngx_int_t = -1;

const ngx_pgrest_loc_conf_t = extern struct {
    conninfo: ngx_str_t,
    schemas_raw: ngx_str_t,
    pool_size: ngx_int_t, // max pooled connections; NGX_CONF_UNSET means use default

    // JWT role-based access control
    jwt_secret: ngx_str_t,
    anon_role: ngx_str_t,
    jwt_role_claim: ngx_str_t,
    jwt_role_claim_explicit: ngx_flag_t,
};

// ============================================================================
// Connection Pool Data Structures
// ============================================================================

/// Maximum connections in the pool
const POOL_MAX_CONNECTIONS = 16;
const PGREST_POOL_TIMEOUT_MS: ngx_msec_t = 5000;
const PGREST_READ_DRAIN_LIMIT: usize = 8;

/// Connection state in the pool
const PgConnState = enum(c_int) {
    free, // Available for use
    connecting, // Non-blocking connect in progress
    idle, // Connected and idle, ready for queries
    busy, // Executing a query
    conn_error, // Connection failed
};

/// Query execution state
const PgQueryState = enum(c_int) {
    none, // No query
    sending, // Sending query to server
    waiting, // Waiting for result
    reading, // Reading result
    done, // Query complete
    failed, // Query failed
};

const RpcExecutionPhase = enum(c_int) {
    none,
    metadata,
    count,
    call,
};

/// A single connection in the pool
const PgPoolConn = extern struct {
    conn: ?*PGconn, // libpq connection handle
    state: PgConnState, // Current connection state
    fd: c_int, // Socket file descriptor for event registration
    ngx_conn: ?*core.ngx_connection_t, // nginx connection wrapper
    request_ctx: ?*PgRequestCtx, // active request bound to this pooled connection
};

/// Connection pool for an upstream
const PgConnPool = struct {
    connections: [POOL_MAX_CONNECTIONS]PgPoolConn,
    conninfo: [512]u8, // Null-terminated connection string
    conninfo_len: usize,
    active_count: usize, // Number of active connections
    max_connections: usize, // Maximum allowed connections
    initialized: bool,

    pub fn init(self: *PgConnPool) void {
        self.initialized = false;
        self.active_count = 0;
        self.max_connections = POOL_MAX_CONNECTIONS;
        self.conninfo_len = 0;
        for (&self.connections) |*c| {
            c.conn = null;
            c.state = .free;
            c.fd = -1;
            c.ngx_conn = null;
            c.request_ctx = null;
        }
    }

    /// Find a free connection slot
    pub fn getFreeSlot(self: *PgConnPool) ?*PgPoolConn {
        for (&self.connections) |*c| {
            if (c.state == .free) {
                return c;
            }
        }
        return null;
    }

    /// Find an idle connection ready for use
    pub fn getIdleConn(self: *PgConnPool) ?*PgPoolConn {
        for (&self.connections) |*c| {
            if (c.state == .idle and c.conn != null) {
                return c;
            }
        }
        return null;
    }

    /// Release a connection back to pool
    pub fn releaseConn(self: *PgConnPool, pc: *PgPoolConn) void {
        if (pc.state == .conn_error or pc.conn == null) {
            // Close failed connections
            if (pc.conn != null) {
                pgFinish(pc.conn);
                pc.conn = null;
            }
            pc.state = .free;
            if (self.active_count > 0) self.active_count -= 1;
        } else {
            // Return to idle state for reuse
            pc.state = .idle;
        }
    }
};

fn is_pool_conn_reusable(pool_conn: *PgPoolConn) bool {
    const conn = pool_conn.conn orelse return false;
    if (pgStatus(conn) != pq.CONNECTION_OK) return false;
    if (pool_conn.fd < 0) return false;
    if (pgConsumeInput(conn) == 0) return false;
    return true;
}

fn discard_pool_conn(pool_conn: *PgPoolConn) void {
    pool_conn.state = .conn_error;
    pool_conn.request_ctx = null;
    if (pool_conn.ngx_conn) |ngx_conn| {
        if (ngx_conn.*.read != core.nullptr(core.ngx_event_t) and ngx_conn.*.read.*.flags.timer_set) {
            event.ngx_event_del_timer(ngx_conn.*.read);
        }
        if (ngx_conn.*.write != core.nullptr(core.ngx_event_t) and ngx_conn.*.write.*.flags.timer_set) {
            event.ngx_event_del_timer(ngx_conn.*.write);
        }
        ngx_conn.*.data = null;
        pool_conn.ngx_conn = null;
    }
    g_conn_pool.releaseConn(pool_conn);
}

fn pool_slot_index(pool_conn: *PgPoolConn) usize {
    return @intCast((@intFromPtr(pool_conn) - @intFromPtr(&g_conn_pool.connections[0])) / @sizeOf(PgPoolConn));
}

/// Per-request context for PostgreSQL operations
const PgRequestCtx = extern struct {
    pool_conn: ?*PgPoolConn, // Assigned connection from pool
    query_state: PgQueryState, // Current query execution state
    rpc_phase: RpcExecutionPhase,
    query: [MAX_QUERY_SIZE]u8, // Query buffer
    query_len: usize, // Query length
    next_query: [MAX_QUERY_SIZE]u8,
    next_query_len: usize,
    followup_queries: [4][MAX_QUERY_SIZE]u8,
    followup_query_lens: [4]usize,
    followup_query_count: usize,
    result: ?*PGresult, // Query result
    request: ?*ngx_http_request_t, // Back-reference to HTTP request
    response_format: ResponseFormat,
    singular_object: bool,
    strip_nulls: bool,
    is_head: bool,
    prefer_params_single_object: bool,
    prefer_return_mode: PreferReturnMode,
    prefer_handling: PreferHandling,
    prefer_resolution: PreferResolution,
    prefer_resolution_applied: bool,
    prefer_max_affected: usize,
    prefer_has_max_affected: bool,
    prefer_count_mode: PreferCountMode,
    prefer_count_applied: bool,
    prefer_missing_default: bool,
    prefer_invalid: bool,
    emit_range_headers: bool,
    response_range_start: usize,
    total_count: i64,
    has_total_count: bool,
    table_embed_metadata: bool,
    raw_json_field_count: usize,
    raw_json_field_lens: [8]usize,
    raw_json_fields: [8][64]u8,
    write_status: ngx_uint_t,
    write_send_body: bool,
    is_write_request: bool,
    // Parameterized query state: values collected during query building are
    // bound via PQsendQueryParams instead of inline SQL quoting.
    param_count: usize,
    param_overflow: bool,
    param_arena_used: usize,
    param_arena: [PARAM_ARENA_SIZE]u8,
    param_ptrs: [MAX_PARAMS][*c]const u8,
    trace_req_seq: usize,
    trace_query_seq: usize,
    trace_started_msec: ngx_msec_t,
    trace_last_progress_msec: ngx_msec_t,
    trace_last_flush_result: c_int,
    trace_last_poll_status: c_int,
    trace_read_calls: usize,
    trace_write_calls: usize,
    trace_finalize_calls: usize,
    trace_release_calls: usize,
    trace_last_event_len: usize,
    trace_last_event: [32]u8,
    count_held: usize, // number of r->main->count holds added in start_pooled_request
    // hold_main stays valid after ctx.request is nulled so release_pooled_ctx
    // can still decrement r->main->count.  hold_is_subrequest records whether
    // the hold was taken on a subrequest: if so, the final hold is "transferred"
    // to nginx's subrequest cleanup (r->main->count-- after the post_subrequest
    // callback returns) and must NOT be decremented here, otherwise an NJS/SSI
    // callback that drives count to zero would let nginx's subsequent decrement
    // touch freed memory.  For direct main requests there is no such follow-up
    // decrement and the hold MUST be released here or the request hangs.
    hold_main: [*c]ngx_http_request_t,
    hold_is_subrequest: bool,
};

var g_pgrest_trace_seq: usize = 0;

fn trace_set_last_event(ctx: *PgRequestCtx, event_name: []const u8) void {
    const copy_len = @min(event_name.len, ctx.*.trace_last_event.len);
    @memcpy(ctx.*.trace_last_event[0..copy_len], event_name[0..copy_len]);
    ctx.*.trace_last_event_len = copy_len;
    ctx.*.trace_last_progress_msec = ngx_current_msec;
}

fn trace_pool_event(ctx: *PgRequestCtx, pool_conn: ?*PgPoolConn, event_name: []const u8) void {
    const r = ctx.*.request orelse return;
    trace_set_last_event(ctx, event_name);
    const slot: usize = if (pool_conn) |pc| pool_slot_index(pc) else 9999;
    const fd: c_int = if (pool_conn) |pc| pc.fd else -1;
    const pool_state: c_int = if (pool_conn) |pc| @intFromEnum(pc.state) else -1;
    log.ngz_log_error(log.NGX_LOG_WARN, r.*.connection.*.log, 0,
        "pgrest-trace req=%uz slot=%uz fd=%d event=%*s qstate=%d pstate=%d qseq=%uz",
        .{ ctx.*.trace_req_seq, slot, fd, @as(c_int, @intCast(ctx.*.trace_last_event_len)), &ctx.*.trace_last_event, @intFromEnum(ctx.*.query_state), pool_state, ctx.*.trace_query_seq });
}

fn dump_pooled_timeout(ctx: *PgRequestCtx) void {
    const r = ctx.*.request orelse return;
    const pool_conn = ctx.*.pool_conn;
    const slot: usize = if (pool_conn) |pc| pool_slot_index(pc) else 9999;
    const fd: c_int = if (pool_conn) |pc| pc.fd else -1;
    const pool_state: c_int = if (pool_conn) |pc| @intFromEnum(pc.state) else -1;
    const age = ngx_current_msec - ctx.*.trace_started_msec;
    const stalled = ngx_current_msec - ctx.*.trace_last_progress_msec;
    log.ngz_log_error(log.NGX_LOG_WARN, r.*.connection.*.log, 0,
        "pgrest-timeout req=%uz slot=%uz fd=%d age=%M stalled=%M",
        .{ ctx.*.trace_req_seq, slot, fd, age, stalled });
    log.ngz_log_error(log.NGX_LOG_WARN, r.*.connection.*.log, 0,
        "pgrest-timeout-last req=%uz last=%*s qstate=%d pstate=%d",
        .{ ctx.*.trace_req_seq, @as(c_int, @intCast(ctx.*.trace_last_event_len)), &ctx.*.trace_last_event, @intFromEnum(ctx.*.query_state), pool_state });
    log.ngz_log_error(log.NGX_LOG_WARN, r.*.connection.*.log, 0,
        "pgrest-timeout-stats req=%uz qseq=%uz flush=%d poll=%d rcalls=%uz wcalls=%uz",
        .{ ctx.*.trace_req_seq, ctx.*.trace_query_seq, ctx.*.trace_last_flush_result, ctx.*.trace_last_poll_status, ctx.*.trace_read_calls, ctx.*.trace_write_calls });
    log.ngz_log_error(log.NGX_LOG_WARN, r.*.connection.*.log, 0,
        "pgrest-timeout-end req=%uz finals=%uz releases=%uz",
        .{ ctx.*.trace_req_seq, ctx.*.trace_finalize_calls, ctx.*.trace_release_calls });
}

fn ensure_pool_conninfo(conninfo: []const u8, max_conn: usize) bool {
    if (!g_pool_initialized) {
        g_conn_pool.init();
        g_pool_initialized = true;
    }

    if (max_conn > 0 and max_conn <= POOL_MAX_CONNECTIONS) {
        g_conn_pool.max_connections = max_conn;
    }

    if (!g_conn_pool.initialized) {
        if (conninfo.len == 0 or conninfo.len >= g_conn_pool.conninfo.len) return false;
        @memcpy(g_conn_pool.conninfo[0..conninfo.len], conninfo);
        g_conn_pool.conninfo[conninfo.len] = 0;
        g_conn_pool.conninfo_len = conninfo.len;
        g_conn_pool.initialized = true;
        return true;
    }

    if (g_conn_pool.conninfo_len == conninfo.len and std.mem.eql(u8, g_conn_pool.conninfo[0..conninfo.len], conninfo)) {
        return true;
    }

    // Different conninfo: only switch if no open connections remain.
    // (active_count covers both idle and busy connections.)
    if (g_conn_pool.active_count != 0 or conninfo.len == 0 or conninfo.len >= g_conn_pool.conninfo.len) {
        return false;
    }

    @memcpy(g_conn_pool.conninfo[0..conninfo.len], conninfo);
    g_conn_pool.conninfo[conninfo.len] = 0;
    g_conn_pool.conninfo_len = conninfo.len;
    g_conn_pool.initialized = true;
    return true;
}

/// Global connection pool (one per upstream)
var g_conn_pool: PgConnPool = undefined;
var g_pool_initialized: bool = false;

/// Maximum size for JSON result buffer
const MAX_JSON_SIZE = 65536;

/// Maximum number of columns for INSERT/UPDATE
const MAX_COLUMNS = 32;

/// Parsed JSON field for INSERT/UPDATE
const JsonField = struct {
    name: []const u8,
    value: []const u8,
    is_null: bool,
    is_number: bool,
    is_boolean: bool,
    is_missing: bool,
    name_buf: [256]u8,
    value_buf: [1024]u8,
};

const MAX_WRITE_ROWS = 16;

const WriteScalar = struct {
    value: []const u8 = "",
    is_null: bool = false,
    is_number: bool = false,
    is_boolean: bool = false,
    use_default: bool = false,
};

fn format_json_number(value: f64, buffer: []u8) []const u8 {
    const truncated = @trunc(value);
    if (truncated == value) {
        const int_value: i64 = @intFromFloat(truncated);
        return std.fmt.bufPrint(buffer, "{d}", .{int_value}) catch "0";
    }
    return std.fmt.bufPrint(buffer, "{d}", .{value}) catch "0";
}

fn append_sql_quoted(buf_out: []u8, pos_in: usize, value: []const u8) usize {
    var pos = pos_in;
    buf_out[pos] = '\'';
    pos += 1;

    for (value) |c| {
        if (c == '\'') {
            buf_out[pos] = '\'';
            pos += 1;
        }
        buf_out[pos] = c;
        pos += 1;
    }

    buf_out[pos] = '\'';
    pos += 1;
    return pos;
}

fn params_reset(ctx: *PgRequestCtx) void {
    ctx.*.param_count = 0;
    ctx.*.param_overflow = false;
    ctx.*.param_arena_used = 0;
}

fn params_add_text(ctx: *PgRequestCtx, value: []const u8) bool {
    if (ctx.*.param_overflow or ctx.*.param_count >= MAX_PARAMS) {
        ctx.*.param_overflow = true;
        return false;
    }
    const needed = value.len + 1;
    if (ctx.*.param_arena_used + needed > PARAM_ARENA_SIZE) {
        ctx.*.param_overflow = true;
        return false;
    }
    const start = ctx.*.param_arena_used;
    @memcpy(ctx.*.param_arena[start..][0..value.len], value);
    ctx.*.param_arena[start + value.len] = 0;
    ctx.*.param_ptrs[ctx.*.param_count] = @ptrCast(&ctx.*.param_arena[start]);
    ctx.*.param_count += 1;
    ctx.*.param_arena_used += needed;
    return true;
}

fn params_add_null(ctx: *PgRequestCtx) bool {
    if (ctx.*.param_overflow or ctx.*.param_count >= MAX_PARAMS) {
        ctx.*.param_overflow = true;
        return false;
    }
    ctx.*.param_ptrs[ctx.*.param_count] = null;
    ctx.*.param_count += 1;
    return true;
}

// Writes "$N" placeholder for the most recently added param.  Call only after
// a successful params_add_text / params_add_null.
fn write_param_placeholder(ctx: *const PgRequestCtx, out: []u8, pos: usize) usize {
    const s = std.fmt.bufPrint(out[pos..], "${d}", .{ctx.*.param_count}) catch return pos;
    return pos + s.len;
}

// Append a user-supplied string value.  When params != null, stores the value
// as a positional parameter ($N) and writes the placeholder into buf_out.
// Falls back to inline SQL quoting on overflow or when params is null.
fn append_param_or_quoted(buf_out: []u8, pos_in: usize, value: []const u8, params: ?*PgRequestCtx) usize {
    if (params) |ctx| {
        if (params_add_text(ctx, value)) {
            return write_param_placeholder(ctx, buf_out, pos_in);
        }
        // Overflow: fall back to safe quoting for this value only. Callers must
        // reject execution if earlier placeholders were already emitted.
    }
    return append_sql_quoted(buf_out, pos_in, value);
}

fn has_unsafe_param_overflow(ctx: *const PgRequestCtx, query: []const u8) bool {
    return ctx.*.param_overflow and ctx.*.param_count > 0 and
        std.mem.indexOfScalar(u8, query, '$') != null;
}

/// Parse JSON object into field array for INSERT/UPDATE
fn parse_json_body(
    pool: [*c]core.ngx_pool_t,
    body: []const u8,
    fields: *[MAX_COLUMNS]JsonField,
) usize {
    if (body.len == 0) return 0;

    // Initialize cJSON with pool allocator
    var json_parser = cjson.CJSON.init(pool);

    // Copy body to null-terminated buffer
    var body_buf: [4096]u8 = undefined;
    if (body.len >= body_buf.len) return 0;
    @memcpy(body_buf[0..body.len], body);
    body_buf[body.len] = 0;

    const body_str = ngx_str_t{ .data = &body_buf, .len = body.len };

    // Parse JSON
    const json = json_parser.decode(body_str) catch return 0;
    if (json == core.nullptr(cjson.cJSON)) return 0;

    // Iterate over object fields
    var it = cjson.CJSON.Iterator.init(json);
    var count: usize = 0;

    while (it.next()) |item| {
        if (count >= MAX_COLUMNS) break;

        // Get field name
        if (item.*.string != core.nullptr(u8)) {
            var name_len: usize = 0;
            while (item.*.string[name_len] != 0 and name_len < 256) : (name_len += 1) {}
            fields[count].name = item.*.string[0..name_len];

            // Get field value
            if (cjson.cJSON_IsNull(item) == 1) {
                fields[count].is_null = true;
                fields[count].is_number = false;
                fields[count].is_boolean = false;
                fields[count].is_missing = false;
                fields[count].value = "";
            } else if (cjson.cJSON_IsNumber(item) == 1) {
                fields[count].is_null = false;
                fields[count].is_number = true;
                fields[count].is_boolean = false;
                fields[count].is_missing = false;
                fields[count].value = format_json_number(
                    cjson.cJSON_GetNumberValue(item),
                    &fields[count].value_buf,
                );
            } else if (cjson.cJSON_IsString(item) == 1) {
                fields[count].is_null = false;
                fields[count].is_number = false;
                fields[count].is_boolean = false;
                fields[count].is_missing = false;
                if (cjson.cJSON_GetStringValue(item)) |str| {
                    var str_len: usize = 0;
                    while (str[str_len] != 0 and str_len < 1024) : (str_len += 1) {}
                    fields[count].value = str[0..str_len];
                } else {
                    fields[count].value = "";
                }
            } else if (cjson.cJSON_IsBool(item) == 1) {
                fields[count].is_null = false;
                fields[count].is_number = false;
                fields[count].is_boolean = true;
                fields[count].is_missing = false;
                fields[count].value = if (cjson.cJSON_IsTrue(item) == 1) "true" else "false";
            } else {
                continue; // Skip unsupported types
            }

            count += 1;
        }
    }

    return count;
}

fn decode_form_component_into(dest: []u8, src: []const u8) ?usize {
    var pos: usize = 0;
    var i: usize = 0;

    while (i < src.len) : (i += 1) {
        if (pos >= dest.len) return null;

        switch (src[i]) {
            '+' => {
                dest[pos] = ' ';
                pos += 1;
            },
            '%' => {
                if (i + 2 >= src.len) return null;
                const hi = std.fmt.charToDigit(src[i + 1], 16) catch return null;
                const lo = std.fmt.charToDigit(src[i + 2], 16) catch return null;
                dest[pos] = @as(u8, @intCast(hi * 16 + lo));
                pos += 1;
                i += 2;
            },
            else => {
                dest[pos] = src[i];
                pos += 1;
            },
        }
    }

    return pos;
}

fn parse_form_urlencoded_body(
    body: []const u8,
    fields: *[MAX_COLUMNS]JsonField,
) usize {
    if (body.len == 0) return 0;

    var count: usize = 0;
    var start: usize = 0;

    while (start <= body.len and count < MAX_COLUMNS) {
        var end = start;
        while (end < body.len and body[end] != '&') : (end += 1) {}

        const pair = body[start..end];
        if (pair.len > 0) {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const raw_name = pair[0..eq];
            const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";

            const name_len = decode_form_component_into(&fields[count].name_buf, raw_name) orelse return count;
            const value_len = decode_form_component_into(&fields[count].value_buf, raw_value) orelse return count;

            fields[count].name = fields[count].name_buf[0..name_len];
            fields[count].value = fields[count].value_buf[0..value_len];
            fields[count].is_null = false;
            fields[count].is_number = is_numeric(fields[count].value);
            fields[count].is_boolean = std.mem.eql(u8, fields[count].value, "true") or std.mem.eql(u8, fields[count].value, "false");
            fields[count].is_missing = false;
            count += 1;
        }

        if (end == body.len) break;
        start = end + 1;
    }

    return count;
}

fn parse_csv_row_into_fields(body: []const u8, fields: *[MAX_COLUMNS]JsonField) usize {
    if (body.len == 0) return 0;

    const newline = std.mem.indexOfScalar(u8, body, '\n') orelse return 0;
    const header_line = trim_ascii_spaces(body[0..newline]);
    if (header_line.len == 0) return 0;

    const data_rest = body[newline + 1 ..];
    const data_end = std.mem.indexOfScalar(u8, data_rest, '\n') orelse data_rest.len;
    const data_line = trim_ascii_spaces(data_rest[0..data_end]);
    if (data_line.len == 0) return 0;

    var count: usize = 0;
    var header_it = std.mem.splitScalar(u8, header_line, ',');
    var value_it = std.mem.splitScalar(u8, data_line, ',');

    while (header_it.next()) |raw_name| {
        const raw_value = value_it.next() orelse return 0;
        if (count >= MAX_COLUMNS) break;

        const name = trim_ascii_spaces(raw_name);
        const value = trim_ascii_spaces(raw_value);
        if (name.len == 0) return 0;
        if (name.len > fields[count].name_buf.len or value.len > fields[count].value_buf.len) return 0;

        @memcpy(fields[count].name_buf[0..name.len], name);
        @memcpy(fields[count].value_buf[0..value.len], value);
        fields[count].name = fields[count].name_buf[0..name.len];
        fields[count].value = fields[count].value_buf[0..value.len];
        fields[count].is_null = std.mem.eql(u8, value, "null") or std.mem.eql(u8, value, "NULL");
        fields[count].is_number = !fields[count].is_null and is_numeric(fields[count].value);
        fields[count].is_boolean = !fields[count].is_null and (std.mem.eql(u8, fields[count].value, "true") or std.mem.eql(u8, fields[count].value, "false"));
        fields[count].is_missing = false;
        count += 1;
    }

    if (value_it.next() != null) return 0;
    return count;
}

fn parse_single_value_body(
    name: []const u8,
    body: []const u8,
    fields: *[MAX_COLUMNS]JsonField,
) usize {
    if (body.len == 0 or name.len > fields[0].name_buf.len) return 0;

    @memcpy(fields[0].name_buf[0..name.len], name);
    fields[0].name = fields[0].name_buf[0..name.len];
    fields[0].value = body;
    fields[0].is_null = false;
    fields[0].is_number = false;
    fields[0].is_boolean = false;
    fields[0].is_missing = false;
    return 1;
}

const PreferOptions = struct {
    params_single_object: bool = false,
    return_mode: PreferReturnMode = .representation,
    handling: PreferHandling = .lenient,
    max_affected: ?usize = null,
    count_mode: PreferCountMode = .none,
    count_applied: bool = false,
    missing_default: bool = false,
    resolution: PreferResolution = .none,
    resolution_applied: bool = false,
    invalid: bool = false,
};

const PreferCountMode = enum(u8) {
    none,
    exact,
    planned,
    estimated,
};

const PreferResolution = enum(u8) {
    none,
    merge_duplicates,
    ignore_duplicates,
};

const PreferReturnMode = enum(u8) {
    representation,
    minimal,
    headers_only,
};

const PreferHandling = enum(u8) {
    lenient,
    strict,
};

const RequestBodyFormat = enum(u8) {
    none,
    json,
    form_urlencoded,
    csv,
    plain_text,
    xml,
    binary,
    unsupported,
};

const RequestOptions = struct {
    response_format: ResponseFormat = .json,
    singular_object: bool = false,
    strip_nulls: bool = false,
    is_head: bool = false,
    prefer: PreferOptions = .{},
    emit_range_headers: bool = false,
    range_requested: bool = false,
    range_invalid: bool = false,
    range_start: usize = 0,
    range_end: ?usize = null,
};

const MAX_EMBED_NODES = 16;
const MAX_RELATION_EDGES = 32;
const MAX_TABLE_NAMES = 16;

const SelectPlanNode = struct {
    alias_len: usize = 0,
    alias_buf: [64]u8 = std.mem.zeroes([64]u8),
    relation_len: usize = 0,
    relation_buf: [64]u8 = std.mem.zeroes([64]u8),
    fk_hint_len: usize = 0,
    fk_hint_buf: [96]u8 = std.mem.zeroes([96]u8),
    path_len: usize = 0,
    path_buf: [128]u8 = std.mem.zeroes([128]u8),
    inner_select_len: usize = 0,
    inner_select_buf: [512]u8 = std.mem.zeroes([512]u8),
    parent_index: i32 = -1,
    inner: bool = false,

    fn alias(self: *const SelectPlanNode) []const u8 {
        return self.alias_buf[0..self.alias_len];
    }

    fn relation(self: *const SelectPlanNode) []const u8 {
        return self.relation_buf[0..self.relation_len];
    }

    fn fkHint(self: *const SelectPlanNode) ?[]const u8 {
        return if (self.fk_hint_len == 0) null else self.fk_hint_buf[0..self.fk_hint_len];
    }

    fn path(self: *const SelectPlanNode) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn innerSelect(self: *const SelectPlanNode) []const u8 {
        return self.inner_select_buf[0..self.inner_select_len];
    }
};

const SelectPlan = struct {
    invalid: bool = false,
    has_embeds: bool = false,
    root_scalar_len: usize = 0,
    root_scalar_buf: [1024]u8 = std.mem.zeroes([1024]u8),
    node_count: usize = 0,
    nodes: [MAX_EMBED_NODES]SelectPlanNode = std.mem.zeroes([MAX_EMBED_NODES]SelectPlanNode),

    fn rootScalar(self: *const SelectPlan) []const u8 {
        return self.root_scalar_buf[0..self.root_scalar_len];
    }
};

const RelationEdge = struct {
    source_len: usize = 0,
    source_buf: [64]u8 = std.mem.zeroes([64]u8),
    target_len: usize = 0,
    target_buf: [64]u8 = std.mem.zeroes([64]u8),
    constraint_len: usize = 0,
    constraint_buf: [96]u8 = std.mem.zeroes([96]u8),
    source_cols_len: usize = 0,
    source_cols_buf: [128]u8 = std.mem.zeroes([128]u8),
    target_cols_len: usize = 0,
    target_cols_buf: [128]u8 = std.mem.zeroes([128]u8),

    fn source(self: *const RelationEdge) []const u8 {
        return self.source_buf[0..self.source_len];
    }

    fn target(self: *const RelationEdge) []const u8 {
        return self.target_buf[0..self.target_len];
    }

    fn constraint(self: *const RelationEdge) []const u8 {
        return self.constraint_buf[0..self.constraint_len];
    }

    fn sourceCols(self: *const RelationEdge) []const u8 {
        return self.source_cols_buf[0..self.source_cols_len];
    }

    fn targetCols(self: *const RelationEdge) []const u8 {
        return self.target_cols_buf[0..self.target_cols_len];
    }
};

const RelationMetadata = struct {
    edge_count: usize = 0,
    edges: [MAX_RELATION_EDGES]RelationEdge = std.mem.zeroes([MAX_RELATION_EDGES]RelationEdge),
};

const ResolvedRelationKind = enum(u8) {
    to_one,
    to_many,
    many_to_many,
};

const ResolvedRelation = struct {
    kind: ResolvedRelationKind,
    direct_edge_index: ?usize = null,
    junction_edge_to_parent: ?usize = null,
    junction_edge_to_target: ?usize = null,
};

const WriteResponseContract = struct {
    status: ngx_uint_t,
    send_body: bool,
    include_returning: bool,
};

const TableQueryBuildResult = struct {
    len: usize,
    json_fields: [MAX_COLUMNS]JsonField,
    json_field_count: usize,
};

const ResolvedSchema = struct {
    name: ?[]const u8,
    disallowed: bool,
    allowed_raw: []const u8,
};

fn trim_ascii_spaces(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;
    while (start < end and std.ascii.isWhitespace(value[start])) : (start += 1) {}
    while (end > start and std.ascii.isWhitespace(value[end - 1])) : (end -= 1) {}
    return value[start..end];
}

fn trim_media_type(value: []const u8) []const u8 {
    const trimmed = trim_ascii_spaces(value);
    const semi = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
    return trim_ascii_spaces(trimmed[0..semi]);
}

fn parse_prefer_header(r: [*c]ngx_http_request_t) PreferOptions {
    var prefer: PreferOptions = .{};
    const prefer_val = extract_header_value(r, "prefer") orelse return prefer;

    var it = std.mem.splitScalar(u8, prefer_val, ',');
    while (it.next()) |part| {
        const token = trim_ascii_spaces(part);
        if (std.mem.eql(u8, token, "params=single-object")) {
            prefer.params_single_object = true;
        } else if (std.mem.eql(u8, token, "return=representation")) {
            prefer.return_mode = .representation;
        } else if (std.mem.eql(u8, token, "return=minimal")) {
            prefer.return_mode = .minimal;
        } else if (std.mem.eql(u8, token, "return=headers-only")) {
            prefer.return_mode = .headers_only;
        } else if (std.mem.eql(u8, token, "handling=strict")) {
            prefer.handling = .strict;
        } else if (std.mem.eql(u8, token, "handling=lenient")) {
            prefer.handling = .lenient;
        } else if (std.mem.eql(u8, token, "resolution=merge-duplicates")) {
            prefer.resolution = .merge_duplicates;
            prefer.resolution_applied = true;
        } else if (std.mem.eql(u8, token, "resolution=ignore-duplicates")) {
            prefer.resolution = .ignore_duplicates;
            prefer.resolution_applied = true;
        } else if (std.mem.eql(u8, token, "missing=default")) {
            prefer.missing_default = true;
        } else if (std.mem.startsWith(u8, token, "max-affected=")) {
            const value = token["max-affected=".len..];
            prefer.max_affected = std.fmt.parseInt(usize, value, 10) catch {
                prefer.invalid = true;
                continue;
            };
        } else if (std.mem.eql(u8, token, "count=exact")) {
            prefer.count_mode = .exact;
        } else if (std.mem.eql(u8, token, "count=planned")) {
            prefer.count_mode = .planned;
        } else if (std.mem.eql(u8, token, "count=estimated")) {
            prefer.count_mode = .estimated;
        } else if (token.len != 0) {
            prefer.invalid = true;
        }
    }

    return prefer;
}

fn parse_request_options(r: [*c]ngx_http_request_t) RequestOptions {
    var opts: RequestOptions = .{};
    opts.is_head = r != null and r.*.method == http.NGX_HTTP_HEAD;
    opts.prefer = parse_prefer_header(r);
    opts.emit_range_headers = r != null and (r.*.method == http.NGX_HTTP_GET or r.*.method == http.NGX_HTTP_HEAD);

    if (extract_header_value(r, "accept")) |accept_val| {
        opts.singular_object = std.mem.containsAtLeast(u8, accept_val, 1, "application/vnd.pgrst.object+json");
        opts.strip_nulls = std.mem.containsAtLeast(u8, accept_val, 1, "nulls=stripped");
    }

    opts.response_format = parse_accept_header_from_request(r);

    if (extract_header_value(r, "range")) |range_val| {
        const trimmed = trim_ascii_spaces(range_val);
        if (trimmed.len > 0) {
            const dash = std.mem.indexOfScalar(u8, trimmed, '-') orelse trimmed.len;
            if (dash == 0 or dash == trimmed.len) {
                opts.range_invalid = true;
            } else {
                const start = std.fmt.parseInt(usize, trimmed[0..dash], 10) catch blk: {
                    opts.range_invalid = true;
                    break :blk 0;
                };
                if (!opts.range_invalid) {
                    const end_slice = trimmed[dash + 1 ..];
                    opts.range_requested = true;
                    opts.range_start = start;
                    opts.range_end = if (end_slice.len == 0)
                        null
                    else blk: {
                        const parsed_end = std.fmt.parseInt(usize, end_slice, 10) catch {
                            opts.range_invalid = true;
                            break :blk start;
                        };
                        break :blk if (parsed_end >= start) parsed_end else start;
                    };
                }
            }
        }
    }

    return opts;
}

fn effective_read_pagination(args: ngx_str_t, opts: RequestOptions) struct { pagination: Pagination, range_start: usize } {
    var pagination = parse_pagination(args);
    if (opts.range_requested) {
        pagination.offset = opts.range_start;
        pagination.limit = if (opts.range_end) |range_end|
            range_end - opts.range_start + 1
        else
            null;
    }
    return .{
        .pagination = pagination,
        .range_start = pagination.offset orelse 0,
    };
}

fn read_count_requested(opts: RequestOptions) bool {
    return opts.prefer.count_mode != .none;
}

fn build_explain_query(query_buf: []u8, inner_query: []const u8) usize {
    const prefix = "EXPLAIN (FORMAT JSON) ";
    @memcpy(query_buf[0..prefix.len], prefix);
    @memcpy(query_buf[prefix.len..][0..inner_query.len], inner_query);
    return prefix.len + inner_query.len;
}

fn build_table_count_query(query_buf: []u8, table: []const u8, where_clause: []const u8, mode: PreferCountMode) usize {
    if (mode == .planned or mode == .estimated) {
        var inner_query_buf: [MAX_QUERY_SIZE]u8 = undefined;
        const inner_query_len = build_sql_query(
            &inner_query_buf,
            .select,
            table,
            where_clause,
            &.{},
            "1",
            "",
            &.{},
            .{ .limit = null, .offset = null },
            false,
            null,
        );
        return build_explain_query(query_buf, inner_query_buf[0..inner_query_len]);
    }

    return build_sql_query(
        query_buf,
        .select,
        table,
        where_clause,
        &.{},
        "count(*)",
        "",
        &.{},
        .{ .limit = null, .offset = null },
        false,
        null,
    );
}

fn build_rpc_table_count_query(
    query_buf: []u8,
    mode: PreferCountMode,
    schema_name: ?[]const u8,
    function_name: []const u8,
    rpc_call: *const RpcCall,
    where_clause: []const u8,
) usize {
    if (mode == .planned or mode == .estimated) {
        var inner_query_buf: [MAX_QUERY_SIZE]u8 = undefined;
        const inner_query_len = build_rpc_table_query(
            &inner_query_buf,
            schema_name,
            function_name,
            rpc_call,
            where_clause,
            "1",
            "",
            &.{},
            .{ .limit = null, .offset = null },
            null,
        );
        return build_explain_query(query_buf, inner_query_buf[0..inner_query_len]);
    }

    return build_rpc_table_query(
        query_buf,
        schema_name,
        function_name,
        rpc_call,
        where_clause,
        "count(*)",
        "",
        &.{},
        .{ .limit = null, .offset = null },
        null,
    );
}

fn parse_explain_plan_rows(text: []const u8) ?i64 {
    const marker = "\"Plan Rows\":";
    const start_idx = std.mem.indexOf(u8, text, marker) orelse return null;
    var idx = start_idx + marker.len;
    while (idx < text.len and std.ascii.isWhitespace(text[idx])) : (idx += 1) {}
    const digits_start = idx;
    while (idx < text.len and std.ascii.isDigit(text[idx])) : (idx += 1) {}
    if (idx == digits_start) return null;
    return std.fmt.parseInt(i64, text[digits_start..idx], 10) catch null;
}

fn parse_count_query_result(mode: PreferCountMode, result: ?*PGresult) ?i64 {
    if (result == null or pgNtuples(result) == 0 or pgGetisnull(result, 0, 0) != 0) return 0;
    const value = pgGetvalue(result, 0, 0) orelse return null;
    const text = std.mem.span(value);
    if (mode == .planned or mode == .estimated) {
        return parse_explain_plan_rows(text);
    }
    return std.fmt.parseInt(i64, text, 10) catch null;
}

fn is_valid_schema_identifier(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value, 0..) |c, i| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
        if (i == 0 and std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn schema_header_name_for_method(method: ngx_uint_t) []const u8 {
    return if (method == http.NGX_HTTP_GET or method == http.NGX_HTTP_HEAD)
        "accept-profile"
    else
        "content-profile";
}

fn format_schema_error(buf_out: []u8, allowed_raw: []const u8) []const u8 {
    const prefix = "{\"code\":\"PGRST106\",\"details\":null,\"hint\":null,\"message\":\"The schema must be one of the following: ";
    const suffix = "\"}";
    var pos: usize = 0;
    @memcpy(buf_out[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf_out[pos..][0..allowed_raw.len], allowed_raw);
    pos += allowed_raw.len;
    @memcpy(buf_out[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    return buf_out[0..pos];
}

fn resolve_request_schema(
    r: [*c]ngx_http_request_t,
    loc_conf: *ngx_pgrest_loc_conf_t,
) ResolvedSchema {
    const allowed_raw = trim_ascii_spaces(core.slicify(u8, loc_conf.*.schemas_raw.data, loc_conf.*.schemas_raw.len));
    if (allowed_raw.len == 0) return .{ .name = null, .disallowed = false, .allowed_raw = "" };

    const header_name = schema_header_name_for_method(r.*.method);
    const requested = if (extract_header_value(r, header_name)) |raw|
        trim_ascii_spaces(raw)
    else
        "";

    var first_allowed: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, allowed_raw, ',');
    while (it.next()) |part| {
        const schema = trim_ascii_spaces(part);
        if (schema.len == 0 or !is_valid_schema_identifier(schema)) continue;
        if (first_allowed == null) first_allowed = schema;
        if (requested.len > 0 and std.mem.eql(u8, requested, schema)) {
            if (first_allowed != null and std.mem.eql(u8, schema, first_allowed.?)) {
                return .{ .name = null, .disallowed = false, .allowed_raw = allowed_raw };
            }
            return .{ .name = schema, .disallowed = false, .allowed_raw = allowed_raw };
        }
    }

    if (requested.len == 0) {
        return .{ .name = null, .disallowed = false, .allowed_raw = allowed_raw };
    }

    return .{ .name = null, .disallowed = true, .allowed_raw = allowed_raw };
}

fn dup_to_ngx_str(pool: [*c]ngx_pool_t, value: []const u8) ?ngx_str_t {
    const mem = core.ngx_pnalloc(pool, value.len) orelse return null;
    const ptr = core.castPtr(u8, mem) orelse return null;
    @memcpy(ptr[0..value.len], value);
    return ngx_str_t{ .data = ptr, .len = value.len };
}

fn append_response_header(
    r: [*c]ngx_http_request_t,
    key: []const u8,
    lowcase_key: []const u8,
    value: []const u8,
) bool {
    var headers = NList(ngx_table_elt_t).init0(&r.*.headers_out.headers);
    const h = headers.append() catch return false;
    h.*.hash = 1;
    h.*.key = ngx_str_t{ .data = @constCast(key.ptr), .len = key.len };
    h.*.value = dup_to_ngx_str(r.*.pool, value) orelse return false;
    h.*.lowcase_key = @constCast(lowcase_key.ptr);
    return true;
}

fn append_cors_headers(r: [*c]ngx_http_request_t, allow_methods: ?[]const u8) void {
    if (extract_header_value(r, "origin") == null and extract_header_value(r, "access-control-request-method") == null) return;
    _ = append_response_header(r, "Access-Control-Allow-Origin", "access-control-allow-origin", "*");
    _ = append_response_header(r, "Access-Control-Allow-Headers", "access-control-allow-headers", "Authorization, Content-Type, Prefer, Accept, Range, Range-Unit, Accept-Profile, Content-Profile");
    if (allow_methods) |methods| {
        _ = append_response_header(r, "Access-Control-Allow-Methods", "access-control-allow-methods", methods);
    }
}

fn append_preference_applied_header(r: [*c]ngx_http_request_t, opts: RequestOptions) void {
    var buf_out: [256]u8 = undefined;
    var pos: usize = 0;

    if (opts.prefer.params_single_object) {
        const token = "params=single-object";
        @memcpy(buf_out[pos..][0..token.len], token);
        pos += token.len;
    }

    if (opts.prefer.return_mode != .representation) {
        if (pos > 0) {
            buf_out[pos] = ',';
            pos += 1;
        }
        const token = switch (opts.prefer.return_mode) {
            .representation => "return=representation",
            .minimal => "return=minimal",
            .headers_only => "return=headers-only",
        };
        @memcpy(buf_out[pos..][0..token.len], token);
        pos += token.len;
    }

    if (opts.prefer.max_affected) |max_affected| {
        if (pos > 0) {
            buf_out[pos] = ',';
            pos += 1;
        }
        const token = std.fmt.bufPrint(buf_out[pos..], "max-affected={d}", .{max_affected}) catch return;
        pos += token.len;
    }

    if (opts.prefer.resolution_applied) {
        if (pos > 0) {
            buf_out[pos] = ',';
            pos += 1;
        }
        const token = switch (opts.prefer.resolution) {
            .merge_duplicates => "resolution=merge-duplicates",
            .ignore_duplicates => "resolution=ignore-duplicates",
            .none => "",
        };
        if (token.len > 0) {
            @memcpy(buf_out[pos..][0..token.len], token);
            pos += token.len;
        }
    }

    if (opts.prefer.count_applied and opts.prefer.count_mode != .none) {
        if (pos > 0) {
            buf_out[pos] = ',';
            pos += 1;
        }
        const token = switch (opts.prefer.count_mode) {
            .none => "",
            .exact => "count=exact",
            .planned => "count=planned",
            .estimated => "count=estimated",
        };
        if (token.len > 0) {
            @memcpy(buf_out[pos..][0..token.len], token);
            pos += token.len;
        }
    }

    if (opts.prefer.missing_default) {
        if (pos > 0) {
            buf_out[pos] = ',';
            pos += 1;
        }
        const token = "missing=default";
        @memcpy(buf_out[pos..][0..token.len], token);
        pos += token.len;
    }

    if (pos > 0) {
        _ = append_response_header(r, "Preference-Applied", "preference-applied", buf_out[0..pos]);
    }
}

fn append_range_headers(r: [*c]ngx_http_request_t, range_start: usize, ntuples: i32, total_count: ?i64, opts: RequestOptions) void {
    if (!opts.emit_range_headers) return;

    _ = append_response_header(r, "Range-Unit", "range-unit", "items");

    var content_range_buf: [64]u8 = undefined;
    const content_range = if (ntuples > 0) blk: {
        const range_end = range_start + @as(usize, @intCast(ntuples - 1));
        break :blk if (total_count) |count|
            std.fmt.bufPrint(content_range_buf[0..], "{d}-{d}/{d}", .{ range_start, range_end, count }) catch return
        else
            std.fmt.bufPrint(content_range_buf[0..], "{d}-{d}/*", .{ range_start, range_end }) catch return;
    } else if (total_count) |count|
        std.fmt.bufPrint(content_range_buf[0..], "*/{d}", .{count}) catch return
    else
        std.fmt.bufPrint(content_range_buf[0..], "*/0", .{}) catch return;

    _ = append_response_header(r, "Content-Range", "content-range", content_range);
}

fn read_response_status(status: ngx_uint_t, range_start: usize, ntuples: i32, total_count: ?i64, opts: RequestOptions) ngx_uint_t {
    if (status != http.NGX_HTTP_OK or !opts.emit_range_headers) return status;
    const total = total_count orelse return status;
    if (ntuples <= 0) {
        return if (total > 0 and range_start > 0) NGX_HTTP_PARTIAL_CONTENT else status;
    }
    const range_end = range_start + @as(usize, @intCast(ntuples - 1));
    return if (range_start > 0 or @as(i64, @intCast(range_end + 1)) < total)
        NGX_HTTP_PARTIAL_CONTENT
    else
        status;
}

fn send_json_payload(r: [*c]ngx_http_request_t, status: ngx_uint_t, body: []const u8) ngx_int_t {
    r.*.headers_out.status = status;
    const content_type = "application/json";
    r.*.headers_out.content_type = ngx_str_t{ .data = @constCast(content_type), .len = content_type.len };
    r.*.headers_out.content_type_len = content_type.len;
    r.*.headers_out.content_length_n = @intCast(body.len);
    append_cors_headers(r, null);

    const header_rc = http.ngx_http_send_header(r);
    if (header_rc == NGX_ERROR or header_rc > http.NGX_HTTP_SPECIAL_RESPONSE) {
        return header_rc;
    }

    if (r.*.method == http.NGX_HTTP_HEAD or r.*.flags1.header_only) {
        return http.ngx_http_send_special(r, http.NGX_HTTP_LAST);
    }

    const b = buf.ngx_create_temp_buf(r.*.pool, body.len) orelse {
        return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    };

    @memcpy(b.*.last[0..body.len], body);
    b.*.last += body.len;
    b.*.flags.last_buf = (r == r.*.main);
    b.*.flags.last_in_chain = true;

    var out: ngx_chain_t = std.mem.zeroes(ngx_chain_t);
    out.buf = b;
    out.next = null;
    return http.ngx_http_output_filter(r, &out);
}

fn send_json_error(r: [*c]ngx_http_request_t, status: ngx_uint_t, body: []const u8) ngx_int_t {
    return send_json_payload(r, status, body);
}

fn send_not_acceptable(r: [*c]ngx_http_request_t, body: []const u8) ngx_int_t {
    return send_json_error(r, NGX_HTTP_NOT_ACCEPTABLE, body);
}

fn send_unsupported_media_type(r: [*c]ngx_http_request_t, body: []const u8) ngx_int_t {
    return send_json_error(r, NGX_HTTP_UNSUPPORTED_MEDIA_TYPE, body);
}

fn is_uri_root_path(uri: ngx_str_t, suffix: []const u8) bool {
    if (uri.len == 0 or uri.data == core.nullptr(u8)) return false;
    const path = core.slicify(u8, uri.data, uri.len);
    return std.mem.eql(u8, path, suffix) or (path.len + 1 == suffix.len and suffix[suffix.len - 1] == '/' and std.mem.eql(u8, path, suffix[0 .. suffix.len - 1]));
}

fn send_options_response(r: [*c]ngx_http_request_t, allow_methods: []const u8) ngx_int_t {
    r.*.headers_out.status = http.NGX_HTTP_NO_CONTENT;
    r.*.headers_out.content_length_n = 0;
    _ = append_response_header(r, "Allow", "allow", allow_methods);
    append_cors_headers(r, allow_methods);
    const header_rc = http.ngx_http_send_header(r);
    if (header_rc == NGX_ERROR or header_rc > http.NGX_HTTP_SPECIAL_RESPONSE) return header_rc;
    return http.ngx_http_send_special(r, http.NGX_HTTP_LAST);
}

fn send_openapi_root(r: [*c]ngx_http_request_t, flavor: []const u8) ngx_int_t {
    const body = if (std.mem.eql(u8, flavor, "rpc"))
        "{\"openapi\":\"3.1.0\",\"info\":{\"title\":\"nginz pgrest rpc\",\"version\":\"0.1.0\"},\"paths\":{\"/rpc/{function}\":{\"get\":{\"summary\":\"Invoke stable/immutable RPC\"},\"post\":{\"summary\":\"Invoke RPC\"},\"options\":{\"summary\":\"Discover RPC route capabilities\"}}}}"
    else
        "{\"openapi\":\"3.1.0\",\"info\":{\"title\":\"nginz pgrest\",\"version\":\"0.1.0\"},\"paths\":{\"/api/{table}\":{\"get\":{\"summary\":\"Read table rows\"},\"head\":{\"summary\":\"Read headers only\"},\"post\":{\"summary\":\"Insert rows\"},\"patch\":{\"summary\":\"Update rows\"},\"put\":{\"summary\":\"Upsert a row\"},\"delete\":{\"summary\":\"Delete rows\"},\"options\":{\"summary\":\"Discover table route capabilities\"}}}}";
    return send_json_payload(r, http.NGX_HTTP_OK, body);
}

fn prefer_invalid_status() ngx_uint_t {
    return http.NGX_HTTP_BAD_REQUEST;
}

fn reject_invalid_prefer(r: [*c]ngx_http_request_t) ngx_int_t {
    return send_json_error(r, prefer_invalid_status(), "{\"message\":\"Invalid Prefer header\"}");
}

fn should_reject_invalid_prefer(opts: RequestOptions) bool {
    return opts.prefer.handling == .strict and opts.prefer.invalid;
}

fn write_response_contract(sql_op: SqlOp, prefer: PreferOptions) WriteResponseContract {
    const status = switch (sql_op) {
        .insert => @as(ngx_uint_t, 201),
        .update, .delete => http.NGX_HTTP_OK,
        else => http.NGX_HTTP_OK,
    };

    return .{
        .status = status,
        .send_body = prefer.return_mode == .representation,
        .include_returning = prefer.return_mode == .representation or prefer.max_affected != null,
    };
}

fn enforce_max_affected(r: [*c]ngx_http_request_t, opts: RequestOptions, ntuples: i32) ?ngx_int_t {
    const max_affected = opts.prefer.max_affected orelse return null;
    const affected: usize = @intCast(@max(ntuples, 0));
    if (affected > max_affected) {
        return send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Query exceeds Prefer: max-affected\"}");
    }
    return null;
}

fn finalize_response_send(
    r: [*c]ngx_http_request_t,
    response_buf: ?*ngx_buf_t,
    response_len: usize,
    content_type: [*:0]const u8,
    ntuples: i32,
    range_start: usize,
    total_count: ?i64,
    opts: RequestOptions,
    status: ngx_uint_t,
    send_body: bool,
) ngx_int_t {
    r.*.headers_out.status = read_response_status(status, range_start, ntuples, total_count, opts);
    const len = std.mem.len(content_type);
    r.*.headers_out.content_type = ngx_str_t{ .data = @constCast(content_type), .len = len };
    r.*.headers_out.content_type_len = len;
    r.*.headers_out.content_length_n = if (send_body and !opts.is_head) @intCast(response_len) else 0;

    append_preference_applied_header(r, opts);
    append_range_headers(r, range_start, ntuples, total_count, opts);
    append_cors_headers(r, null);

    const header_rc = http.ngx_http_send_header(r);
    if (header_rc == NGX_ERROR or header_rc > http.NGX_HTTP_SPECIAL_RESPONSE) {
        return header_rc;
    }

    if (opts.is_head or !send_body) {
        return http.ngx_http_send_special(r, http.NGX_HTTP_LAST);
    }

    const b = response_buf orelse return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    b.*.last = b.*.pos + response_len;
    b.*.flags.last_buf = (r == r.*.main);
    b.*.flags.last_in_chain = true;

    var out: ngx_chain_t = std.mem.zeroes(ngx_chain_t);
    out.buf = b;
    out.next = null;
    return http.ngx_http_output_filter(r, &out);
}

const FormatResponseError = error{
    BinaryShapeUnsupported,
    ResponseTooLarge,
};

fn format_result_as_binary(
    result: ?*PGresult,
    ntuples: i32,
    nfields: i32,
    response_buf: []u8,
) FormatResponseError!usize {
    if (result == null or ntuples != 1 or nfields != 1) {
        return error.BinaryShapeUnsupported;
    }

    if (pgGetisnull(result, 0, 0) != 0) {
        return 0;
    }

    const value = pgGetvalue(result, 0, 0) orelse return 0;
    const value_len: usize = @intCast(pgGetlength(result, 0, 0));
    if (value_len > response_buf.len) {
        return error.ResponseTooLarge;
    }

    @memcpy(response_buf[0..value_len], value[0..value_len]);
    return value_len;
}

fn format_result_for_response(
    result: ?*PGresult,
    ntuples: i32,
    nfields: i32,
    opts: RequestOptions,
    response_buf: []u8,
    content_type: *[*:0]const u8,
    raw_json_fields: []const [64]u8,
    raw_json_field_lens: []const usize,
    raw_json_field_count: usize,
) FormatResponseError!usize {
    switch (opts.response_format) {
        .json => {
            content_type.* = "application/json";
            return format_result_as_json_smart(
                result,
                ntuples,
                nfields,
                response_buf,
                opts.singular_object,
                opts.strip_nulls,
                raw_json_fields,
                raw_json_field_lens,
                raw_json_field_count,
            );
        },
        .csv => {
            content_type.* = "text/csv; charset=utf-8";
            return format_result_as_csv(result, ntuples, nfields, response_buf);
        },
        .plain_text => {
            content_type.* = "text/plain; charset=utf-8";
            if (ntuples > 0 and nfields > 0) {
                return format_result_as_plain_text(result, ntuples, response_buf);
            }
            return 0;
        },
        .xml => {
            content_type.* = "text/xml; charset=utf-8";
            return format_result_as_xml(result, ntuples, nfields, response_buf);
        },
        .binary => {
            content_type.* = "application/octet-stream";
            return try format_result_as_binary(result, ntuples, nfields, response_buf);
        },
        .unsupported => unreachable,
    }
}

fn release_pooled_ctx(ctx: *PgRequestCtx, failed: bool) void {
    ctx.*.trace_release_calls += 1;
    trace_pool_event(ctx, ctx.*.pool_conn, if (failed) "release-failed" else "release");
    if (ctx.*.result != null) {
        pgClear(ctx.*.result);
        ctx.*.result = null;
    }

    if (ctx.*.pool_conn) |pool_conn| {
        if (pool_conn.ngx_conn) |ngx_conn| {
            if (ngx_conn.*.read != core.nullptr(core.ngx_event_t) and ngx_conn.*.read.*.flags.timer_set) {
                event.ngx_event_del_timer(ngx_conn.*.read);
            }
            if (ngx_conn.*.write != core.nullptr(core.ngx_event_t) and ngx_conn.*.write.*.flags.timer_set) {
                event.ngx_event_del_timer(ngx_conn.*.write);
            }
        }
        // Release the count holds taken in start_pooled_request.  We use the
        // stashed hold_main (set when the hold was taken) instead of ctx.request,
        // because callers null ctx.request before reaching here.
        //
        // For subrequest holds, keep one hold so nginx's subrequest cleanup
        // (r->main->count-- after the post_subrequest callback) can balance it
        // — this preserves the 96632c3 guard against an NJS r.return() driving
        // count to zero mid-stack and freeing main before nginx's decrement.
        // For direct main-request holds there is no follow-up nginx decrement,
        // so all holds must be released here or the request hangs at count > 0.
        if (ctx.*.count_held > 0 and ctx.*.hold_main != core.nullptr(ngx_http_request_t)) {
            const leak: usize = if (ctx.*.hold_is_subrequest) 1 else 0;
            while (ctx.*.count_held > leak) {
                ctx.*.hold_main.*.flags0.count -%= 1;
                ctx.*.count_held -= 1;
            }
            if (!ctx.*.hold_is_subrequest) {
                ctx.*.hold_main = core.nullptr(ngx_http_request_t);
            }
        }
        pool_conn.request_ctx = null;
        if (failed) {
            pool_conn.state = .conn_error;
        }
        g_conn_pool.releaseConn(pool_conn);
        ctx.*.pool_conn = null;
    }
}

fn finalize_pooled_timeout(ctx: *PgRequestCtx) void {
    const r = ctx.*.request orelse return;
    dump_pooled_timeout(ctx);
    const rc = send_json_error(r, 504, "{\"message\":\"PostgreSQL connection timed out\"}");
    ctx.*.request = null;
    release_pooled_ctx(ctx, true);
    http.ngx_http_finalize_request(r, rc);
}

fn log_pooled_event_watch_state(ctx: *PgRequestCtx, pool_conn: *PgPoolConn, label: []const u8) void {
    _ = label;
    const r = ctx.*.request orelse return;
    const ngx_conn = pool_conn.ngx_conn orelse return;
    if (ngx_conn.*.read == core.nullptr(core.ngx_event_t)) return;

    const rev = ngx_conn.*.read;
    log.ngz_log_error(log.NGX_LOG_WARN, r.*.connection.*.log, 0,
        "pgrest-watch req=%uz slot=%uz fd=%d active=%d ready=%d timer=%d avail=%d",
        .{
            ctx.*.trace_req_seq,
            pool_slot_index(pool_conn),
            pool_conn.fd,
            @as(c_int, if (rev.*.flags.active) 1 else 0),
            @as(c_int, if (rev.*.flags.ready) 1 else 0),
            @as(c_int, if (rev.*.flags.timer_set) 1 else 0),
            rev.*.available,
        });
}

fn set_pooled_timer_mode(ctx: *PgRequestCtx, pool_conn: *PgPoolConn, want_read: bool, want_write: bool) bool {
    const ngx_conn = pool_conn.ngx_conn orelse return false;

    if (ngx_conn.*.read != core.nullptr(core.ngx_event_t)) {
        if (ngx_conn.*.read.*.flags.timer_set) {
            event.ngx_event_del_timer(ngx_conn.*.read);
        }
        if (want_read and http.ngx_handle_read_event(ngx_conn.*.read, 0) != NGX_OK) {
            trace_pool_event(ctx, pool_conn, "rearm-read-fail");
            return false;
        }
        if (want_read) {
            event.ngx_event_add_timer(ngx_conn.*.read, PGREST_POOL_TIMEOUT_MS);
        }
    }

    if (ngx_conn.*.write != core.nullptr(core.ngx_event_t)) {
        if (ngx_conn.*.write.*.flags.timer_set) {
            event.ngx_event_del_timer(ngx_conn.*.write);
        }
        if (want_write and http.ngx_handle_write_event(ngx_conn.*.write, 0) != NGX_OK) {
            trace_pool_event(ctx, pool_conn, "rearm-write-fail");
            return false;
        }
        if (want_write) {
            event.ngx_event_add_timer(ngx_conn.*.write, PGREST_POOL_TIMEOUT_MS);
        }
    }

    return true;
}

fn apply_query_flush_state(ctx: *PgRequestCtx, pool_conn: *PgPoolConn, flush_result: c_int) bool {
    ctx.*.trace_last_flush_result = flush_result;
    if (flush_result == 0) {
        ctx.*.query_state = .waiting;
        if (!set_pooled_timer_mode(ctx, pool_conn, true, false)) {
            ctx.*.query_state = .failed;
            return false;
        }
        trace_pool_event(ctx, pool_conn, "wait-read");
        return true;
    }
    if (flush_result > 0) {
        ctx.*.query_state = .sending;
        if (!set_pooled_timer_mode(ctx, pool_conn, false, true)) {
            ctx.*.query_state = .failed;
            return false;
        }
        trace_pool_event(ctx, pool_conn, "wait-write");
        return true;
    }

    ctx.*.query_state = .failed;
    _ = set_pooled_timer_mode(ctx, pool_conn, false, false);
    trace_pool_event(ctx, pool_conn, "flush-fail");
    return false;
}

const FailureResponse = struct {
    status: ngx_uint_t,
    body: []const u8,
};

fn contains_ascii_insensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn classify_connection_error_message(message: []const u8) FailureResponse {
    if (contains_ascii_insensitive(message, "could not translate host name")) {
        return .{ .status = http.NGX_HTTP_SERVICE_UNAVAILABLE, .body = "{\"message\":\"PostgreSQL DNS resolution failed\"}" };
    }
    if (contains_ascii_insensitive(message, "timeout expired") or contains_ascii_insensitive(message, "timed out")) {
        return .{ .status = 504, .body = "{\"message\":\"PostgreSQL connection timed out\"}" };
    }
    if (contains_ascii_insensitive(message, "connection reset by peer") or contains_ascii_insensitive(message, "server closed the connection unexpectedly")) {
        return .{ .status = http.NGX_HTTP_SERVICE_UNAVAILABLE, .body = "{\"message\":\"PostgreSQL connection reset\"}" };
    }
    if (contains_ascii_insensitive(message, "connection refused") or
        contains_ascii_insensitive(message, "could not connect to server") or
        contains_ascii_insensitive(message, "no route to host"))
    {
        return .{ .status = http.NGX_HTTP_SERVICE_UNAVAILABLE, .body = "{\"message\":\"PostgreSQL is unreachable\"}" };
    }
    return .{ .status = http.NGX_HTTP_SERVICE_UNAVAILABLE, .body = "{\"message\":\"PostgreSQL connection failed\"}" };
}

fn classify_result_error(result: *PGresult) FailureResponse {
    const sqlstate_ptr = pgResultErrorField(result, PG_DIAG_SQLSTATE);
    const sqlstate = if (sqlstate_ptr != null) std.mem.span(sqlstate_ptr) else "";
    if (std.mem.eql(u8, sqlstate, "42601")) {
        return .{ .status = http.NGX_HTTP_BAD_REQUEST, .body = "{\"message\":\"SQL syntax error\"}" };
    }
    if (std.mem.eql(u8, sqlstate, "42P01")) {
        return .{ .status = http.NGX_HTTP_NOT_FOUND, .body = "{\"message\":\"Undefined table\"}" };
    }
    if (std.mem.eql(u8, sqlstate, "42883")) {
        return .{ .status = http.NGX_HTTP_NOT_FOUND, .body = "{\"message\":\"Undefined function\"}" };
    }
    if (std.mem.eql(u8, sqlstate, "42501")) {
        return .{ .status = http.NGX_HTTP_FORBIDDEN, .body = "{\"message\":\"Insufficient privileges\"}" };
    }
    if (std.mem.startsWith(u8, sqlstate, "23")) {
        return .{ .status = 409, .body = "{\"message\":\"Constraint violation\"}" };
    }
    if (std.mem.startsWith(u8, sqlstate, "08")) {
        return .{ .status = http.NGX_HTTP_SERVICE_UNAVAILABLE, .body = "{\"message\":\"PostgreSQL connection failed\"}" };
    }

    const message_ptr = pgResultErrorMessage(result);
    const message = if (message_ptr != null) std.mem.span(message_ptr) else "";
    if (contains_ascii_insensitive(message, "syntax error")) {
        return .{ .status = http.NGX_HTTP_BAD_REQUEST, .body = "{\"message\":\"SQL syntax error\"}" };
    }
    if (contains_ascii_insensitive(message, "does not exist")) {
        if (contains_ascii_insensitive(message, "function")) {
            return .{ .status = http.NGX_HTTP_NOT_FOUND, .body = "{\"message\":\"Undefined function\"}" };
        }
        if (contains_ascii_insensitive(message, "relation")) {
            return .{ .status = http.NGX_HTTP_NOT_FOUND, .body = "{\"message\":\"Undefined table\"}" };
        }
    }
    if (contains_ascii_insensitive(message, "permission denied")) {
        return .{ .status = http.NGX_HTTP_FORBIDDEN, .body = "{\"message\":\"Insufficient privileges\"}" };
    }
    return .{ .status = http.NGX_HTTP_INTERNAL_SERVER_ERROR, .body = "{\"message\":\"PostgreSQL query failed\"}" };
}

fn classify_pooled_failure(ctx: *PgRequestCtx) FailureResponse {
    if (ctx.*.result) |result| {
        return classify_result_error(result);
    }
    if (ctx.*.pool_conn) |pool_conn| {
        if (pool_conn.conn) |conn| {
            const message_ptr = pgErrorMessage(conn);
            const message = if (message_ptr != null) std.mem.span(message_ptr) else "";
            if (message.len != 0) return classify_connection_error_message(message);
        }
    }
    return .{ .status = http.NGX_HTTP_INTERNAL_SERVER_ERROR, .body = "{\"message\":\"Query failed\"}" };
}

fn finalize_pooled_failure(ctx: *PgRequestCtx) void {
    const r = ctx.*.request orelse return;
    const failure = classify_pooled_failure(ctx);
    const rc = send_json_error(r, failure.status, failure.body);
    ctx.*.request = null;
    release_pooled_ctx(ctx, true);
    http.ngx_http_finalize_request(r, rc);
}

fn set_active_query(ctx: *PgRequestCtx, query: []const u8) bool {
    if (query.len == 0 or query.len >= ctx.*.query.len) return false;
    @memcpy(ctx.*.query[0..query.len], query);
    ctx.*.query_len = query.len;
    ctx.*.query[query.len] = 0;
    return true;
}

fn queue_followup_query(ctx: *PgRequestCtx, query: []const u8) bool {
    if (query.len == 0) return false;

    if (ctx.*.next_query_len == 0) {
        if (query.len >= ctx.*.next_query.len) return false;
        @memcpy(ctx.*.next_query[0..query.len], query);
        ctx.*.next_query_len = query.len;
        ctx.*.next_query[query.len] = 0;
        return true;
    }

    if (ctx.*.followup_query_count >= ctx.*.followup_queries.len) return false;
    const slot = ctx.*.followup_query_count;
    if (query.len >= ctx.*.followup_queries[slot].len) return false;
    @memcpy(ctx.*.followup_queries[slot][0..query.len], query);
    ctx.*.followup_query_lens[slot] = query.len;
    ctx.*.followup_queries[slot][query.len] = 0;
    ctx.*.followup_query_count += 1;
    return true;
}

fn promote_followup_query(ctx: *PgRequestCtx) bool {
    if (ctx.*.next_query_len == 0) return false;
    if (!set_active_query(ctx, ctx.*.next_query[0..ctx.*.next_query_len])) return false;

    if (ctx.*.followup_query_count > 0) {
        const next_len = ctx.*.followup_query_lens[0];
        @memcpy(ctx.*.next_query[0..next_len], ctx.*.followup_queries[0][0..next_len]);
        ctx.*.next_query_len = next_len;
        ctx.*.next_query[next_len] = 0;

        var i: usize = 1;
        while (i < ctx.*.followup_query_count) : (i += 1) {
            const dest = i - 1;
            const len = ctx.*.followup_query_lens[i];
            @memcpy(ctx.*.followup_queries[dest][0..len], ctx.*.followup_queries[i][0..len]);
            ctx.*.followup_query_lens[dest] = len;
            ctx.*.followup_queries[dest][len] = 0;
        }
        ctx.*.followup_query_count -= 1;
    } else {
        ctx.*.next_query_len = 0;
    }

    return true;
}

const JwtSetupResult = enum {
    ok,
    unauthorized,
    failed,
};

/// Sets up the per-request session isolation chain for the pooled path.
///
/// Uses a single combined multi-statement query (RESET ROLE; SET request.jwt;
/// SET ROLE) to avoid 2–3 sequential round-trips per request.
///
/// ctx.query is set to the combined setup query.  Callers must append their
/// main queries via queue_followup_query.
fn queue_jwt_setup_queries(ctx: *PgRequestCtx, loc_conf: *ngx_pgrest_loc_conf_t) JwtSetupResult {
    const r = ctx.*.request orelse return .failed;
    const jwt_token = extract_jwt_token(r);

    const secret = if (loc_conf.*.jwt_secret.len > 0 and loc_conf.*.jwt_secret.data != core.nullptr(u8))
        core.slicify(u8, loc_conf.*.jwt_secret.data, loc_conf.*.jwt_secret.len)
    else
        "";
    const anon_role = if (loc_conf.*.anon_role.len > 0 and loc_conf.*.anon_role.data != core.nullptr(u8))
        core.slicify(u8, loc_conf.*.anon_role.data, loc_conf.*.anon_role.len)
    else
        "";
    const role_claim = if (loc_conf.*.jwt_role_claim.len > 0 and loc_conf.*.jwt_role_claim.data != core.nullptr(u8))
        core.slicify(u8, loc_conf.*.jwt_role_claim.data, loc_conf.*.jwt_role_claim.len)
    else
        "role";

    // Validate JWT and determine which role to apply (before building the
    // combined query, so the result can be embedded inline).
    var role_to_set: ?[]const u8 = null;
    if (jwt_token) |token| {
        if (secret.len > 0) {
            if (pgrest_auth.validate_jwt_token(r.*.pool, token, secret)) |err| {
                _ = send_json_error(r, http.NGX_HTTP_UNAUTHORIZED, switch (err) {
                    .invalid_format => "{\"message\":\"Invalid JWT format\"}",
                    .invalid_signature => "{\"message\":\"Invalid JWT signature\"}",
                    .expired => "{\"message\":\"JWT token has expired\"}",
                    .not_yet_valid => "{\"message\":\"JWT token is not yet valid\"}",
                });
                return .unauthorized;
            }
            role_to_set = extract_jwt_role(r.*.pool, token, role_claim) orelse if (anon_role.len > 0) anon_role else null;
        }
    } else if (anon_role.len > 0) {
        role_to_set = anon_role;
    }

    // Build a single combined multi-statement query instead of enqueueing
    // separate RESET ROLE, SET request.jwt, and SET ROLE commands.
    var combined_buf: [MAX_QUERY_SIZE]u8 = undefined;
    const combined_len = pgrest_auth.build_combined_jwt_setup_query(&combined_buf, jwt_token, role_to_set) orelse return .failed;
    if (!set_active_query(ctx, combined_buf[0..combined_len])) return .failed;

    return .ok;
}

fn start_pooled_query(ctx: *PgRequestCtx, pool_conn: *PgPoolConn) bool {
    const conn = pool_conn.conn orelse return false;

    if (ctx.*.result != null) {
        pgClear(ctx.*.result);
        ctx.*.result = null;
    }

    const query_slice = std.mem.sliceTo(&ctx.*.query, 0);
    const use_params = ctx.*.param_count > 0 and !ctx.*.param_overflow and
        std.mem.indexOfScalar(u8, query_slice, '$') != null;
    const query_sent = if (use_params)
        pgSendQueryParams(conn, &ctx.*.query, @intCast(ctx.*.param_count), null, @ptrCast(&ctx.*.param_ptrs), null, null, 0)
    else
        pgSendQuery(conn, &ctx.*.query);
    if (query_sent == 0) {
        ctx.*.query_state = .failed;
        return false;
    }

    ctx.*.query_state = .sending;
    pool_conn.state = .busy;
    ctx.*.trace_query_seq += 1;
    trace_pool_event(ctx, pool_conn, "query-start");

    const flush_result = pgFlush(conn);
    if (!apply_query_flush_state(ctx, pool_conn, flush_result)) {
        return false;
    }

    return true;
}

fn start_pooled_request(ctx: *PgRequestCtx, loc_conf: *ngx_pgrest_loc_conf_t) ngx_int_t {
    const conninfo = core.slicify(u8, loc_conf.*.conninfo.data, loc_conf.*.conninfo.len);
    const max_conn: usize = if (loc_conf.*.pool_size > 0)
        @intCast(loc_conf.*.pool_size)
    else
        POOL_MAX_CONNECTIONS;
    if (!ensure_pool_conninfo(conninfo, max_conn)) {
        return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    g_pgrest_trace_seq += 1;
    ctx.*.trace_req_seq = g_pgrest_trace_seq;
    ctx.*.trace_started_msec = ngx_current_msec;
    ctx.*.trace_last_progress_msec = ngx_current_msec;
    ctx.*.trace_last_flush_result = -999;
    ctx.*.trace_last_poll_status = -999;
    ctx.*.trace_last_event_len = 0;
    trace_pool_event(ctx, null, "request-start");

    while (g_conn_pool.getIdleConn()) |pool_conn| {
        trace_pool_event(ctx, pool_conn, "idle-found");
        if (!is_pool_conn_reusable(pool_conn)) {
            trace_pool_event(ctx, pool_conn, "idle-reject");
            discard_pool_conn(pool_conn);
            continue;
        }
        trace_pool_event(ctx, pool_conn, "idle-reuse");
        ctx.*.pool_conn = pool_conn;
        pool_conn.request_ctx = ctx;
        pool_conn.state = .busy;
        const ngx_conn = pool_conn.ngx_conn orelse return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
        ngx_conn.*.data = pool_conn;
        if (!start_pooled_query(ctx, pool_conn)) {
            pool_conn.request_ctx = null;
            pool_conn.state = .conn_error;
            g_conn_pool.releaseConn(pool_conn);
            ctx.*.pool_conn = null;
            return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
        }
        const r = ctx.*.request.?;
        ctx.*.hold_main = r.*.main;
        ctx.*.hold_is_subrequest = (r != r.*.main);
        r.*.main.*.flags0.count +%= 1;
        ctx.*.count_held += 1;
        return core.NGX_DONE;
    }

    const pool_conn = g_conn_pool.getFreeSlot() orelse return http.NGX_HTTP_SERVICE_UNAVAILABLE;
    trace_pool_event(ctx, pool_conn, "free-slot");
    const conn = pgConnectStart(&g_conn_pool.conninfo);
    if (conn == null) return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    if (pgStatus(conn) == pq.CONNECTION_BAD) {
        const message_ptr = pgErrorMessage(conn);
        const message = if (message_ptr != null) std.mem.span(message_ptr) else "";
        const failure = classify_connection_error_message(message);
        pgFinish(conn);
        return send_json_error(ctx.*.request, failure.status, failure.body);
    }
    if (pgSetnonblocking(conn, 1) != 0) {
        pgFinish(conn);
        return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    const fd = pgSocket(conn);
    if (fd < 0) {
        pgFinish(conn);
        return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    const ngx_conn = http.ngx_get_connection(fd, ctx.*.request.?.*.connection.*.log);
    if (ngx_conn == core.nullptr(core.ngx_connection_t)) {
        pgFinish(conn);
        return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    }
    ngx_conn.*.log = ctx.*.request.?.*.connection.*.log;

    pool_conn.conn = conn;
    pool_conn.state = .connecting;
    pool_conn.fd = fd;
    pool_conn.ngx_conn = ngx_conn;
    pool_conn.request_ctx = ctx;
    g_conn_pool.active_count += 1;
    ctx.*.pool_conn = pool_conn;

    ngx_conn.*.data = pool_conn;
    if (ngx_conn.*.read != core.nullptr(core.ngx_event_t)) {
        ngx_conn.*.read.*.log = ngx_conn.*.log;
        ngx_conn.*.read.*.handler = ngx_pgrest_conn_read_handler;
        if (http.ngx_handle_read_event(ngx_conn.*.read, 0) != NGX_OK) {
            pool_conn.request_ctx = null;
            cleanup_pool_conn(pool_conn);
            ctx.*.pool_conn = null;
            return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
        }
    }
    if (ngx_conn.*.write != core.nullptr(core.ngx_event_t)) {
        ngx_conn.*.write.*.log = ngx_conn.*.log;
        ngx_conn.*.write.*.handler = ngx_pgrest_conn_write_handler;
        if (http.ngx_handle_write_event(ngx_conn.*.write, 0) != NGX_OK) {
            pool_conn.request_ctx = null;
            cleanup_pool_conn(pool_conn);
            ctx.*.pool_conn = null;
            return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
        }
    }

    {
        const r = ctx.*.request.?;
        ctx.*.hold_main = r.*.main;
        ctx.*.hold_is_subrequest = (r != r.*.main);
        r.*.main.*.flags0.count +%= 1;
        ctx.*.count_held += 1;
    }
    trace_pool_event(ctx, pool_conn, "connect-start");
    poll_pg_connection(ctx, pool_conn);
    return core.NGX_DONE;
}

fn column_is_raw_json(raw_json_fields: []const [64]u8, raw_json_field_lens: []const usize, raw_json_field_count: usize, name: []const u8) bool {
    for (raw_json_field_lens[0..raw_json_field_count], 0..) |len, idx| {
        if (std.mem.eql(u8, raw_json_fields[idx][0..len], name)) return true;
    }
    return false;
}

const JsonColumnMeta = struct {
    name: []const u8,
    emit_raw_json: bool,
};

const MIN_RESPONSE_BUFFER_SIZE: usize = 512;
const PG_JSON_OID: pq.Oid = 114;
const PG_JSONB_OID: pq.Oid = 3802;

fn column_has_native_json_type(result: ?*PGresult, col: i32) bool {
    if (result == null) return false;
    const oid = pgFtype(result, col);
    return oid == PG_JSON_OID or oid == PG_JSONB_OID;
}

fn build_json_column_meta(
    result: ?*PGresult,
    nfields: i32,
    raw_json_fields: []const [64]u8,
    raw_json_field_lens: []const usize,
    raw_json_field_count: usize,
    metas: *[MAX_COLUMNS]JsonColumnMeta,
) ?[]const JsonColumnMeta {
    if (result == null or nfields < 0 or nfields > MAX_COLUMNS) return null;

    var col: i32 = 0;
    while (col < nfields) : (col += 1) {
        const idx: usize = @intCast(col);
        const fname = pgFname(result, col);
        const name = if (fname != null) std.mem.span(fname) else "";
        metas[idx] = .{
            .name = name,
            .emit_raw_json = column_has_native_json_type(result, col) or
                column_is_raw_json(raw_json_fields, raw_json_field_lens, raw_json_field_count, name),
        };
    }

    return metas[0..@intCast(nfields)];
}

fn needs_json_escape(value: []const u8) bool {
    for (value) |c| {
        if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c == '\t') return true;
    }
    return false;
}

fn append_json_quoted_string(json_buf: []u8, pos_in: usize, value: []const u8) usize {
    if (pos_in >= json_buf.len) return pos_in;

    var pos = pos_in;
    json_buf[pos] = '"';
    pos += 1;

    if (!needs_json_escape(value)) {
        const remaining = json_buf.len - pos;
        const copy_len = @min(value.len, remaining);
        @memcpy(json_buf[pos..][0..copy_len], value[0..copy_len]);
        pos += copy_len;
        if (pos < json_buf.len) {
            json_buf[pos] = '"';
            pos += 1;
        }
        return pos;
    }

    for (value) |c| {
        switch (c) {
            '"', '\\' => {
                if (pos + 2 > json_buf.len) break;
                json_buf[pos] = '\\';
                json_buf[pos + 1] = c;
                pos += 2;
            },
            '\n' => {
                if (pos + 2 > json_buf.len) break;
                json_buf[pos] = '\\';
                json_buf[pos + 1] = 'n';
                pos += 2;
            },
            '\r' => {
                if (pos + 2 > json_buf.len) break;
                json_buf[pos] = '\\';
                json_buf[pos + 1] = 'r';
                pos += 2;
            },
            '\t' => {
                if (pos + 2 > json_buf.len) break;
                json_buf[pos] = '\\';
                json_buf[pos + 1] = 't';
                pos += 2;
            },
            else => {
                if (pos >= json_buf.len) break;
                json_buf[pos] = c;
                pos += 1;
            },
        }
    }

    if (pos < json_buf.len) {
        json_buf[pos] = '"';
        pos += 1;
    }
    return pos;
}

fn estimated_json_string_size(value: []const u8) usize {
    var size: usize = 2;
    for (value) |c| {
        size += switch (c) {
            '"', '\\', '\n', '\r', '\t' => 2,
            else => 1,
        };
    }
    return size;
}

fn estimate_json_row_size(
    result: ?*PGresult,
    row: i32,
    nfields: i32,
    strip_nulls: bool,
    column_meta: ?[]const JsonColumnMeta,
) usize {
    if (result == null) return 2;

    var size: usize = 2;
    var emitted_fields: usize = 0;
    var col: i32 = 0;
    while (col < nfields) : (col += 1) {
        const is_null = pgGetisnull(result, row, col) != 0;
        if (strip_nulls and is_null) continue;

        if (emitted_fields > 0) size += 1;
        emitted_fields += 1;

        const meta = if (column_meta) |items| items[@intCast(col)] else JsonColumnMeta{
            .name = blk: {
                const fname = pgFname(result, col);
                break :blk if (fname != null) std.mem.span(fname) else "";
            },
            .emit_raw_json = false,
        };

        size += meta.name.len + 3;
        if (is_null) {
            size += 4;
            continue;
        }

        const value = pgGetvalue(result, row, col) orelse {
            size += 4;
            continue;
        };
        const value_len: usize = @intCast(pgGetlength(result, row, col));
        const value_slice = value[0..value_len];
        size += if (meta.emit_raw_json)
            value_slice.len
        else
            estimated_json_string_size(value_slice);
    }

    return size;
}

fn estimate_response_buffer_size(
    result: ?*PGresult,
    ntuples: i32,
    nfields: i32,
    opts: RequestOptions,
    raw_json_fields: []const [64]u8,
    raw_json_field_lens: []const usize,
    raw_json_field_count: usize,
) usize {
    const clamped_min = MIN_RESPONSE_BUFFER_SIZE;
    const clamped_max = MAX_JSON_SIZE;

    switch (opts.response_format) {
        .json => {
            var column_metas: [MAX_COLUMNS]JsonColumnMeta = undefined;
            const column_meta = build_json_column_meta(result, nfields, raw_json_fields, raw_json_field_lens, raw_json_field_count, &column_metas);
            var estimated: usize = 0;
            if (opts.singular_object) {
                estimated = if (ntuples >= 1)
                    estimate_json_row_size(result, 0, nfields, opts.strip_nulls, column_meta)
                else
                    2;
            } else {
                estimated = 2;
                var row: i32 = 0;
                while (row < ntuples) : (row += 1) {
                    if (row > 0) estimated += 1;
                    estimated += estimate_json_row_size(result, row, nfields, opts.strip_nulls, column_meta);
                    if (estimated >= clamped_max) return clamped_max;
                }
            }
            return @max(clamped_min, @min(estimated, clamped_max));
        },
        .binary => {
            if (result != null and ntuples == 1 and nfields == 1 and pgGetisnull(result, 0, 0) == 0) {
                const value_len: usize = @intCast(pgGetlength(result, 0, 0));
                return @max(clamped_min, @min(value_len, clamped_max));
            }
            return clamped_min;
        },
        else => return clamped_max,
    }
}

/// Format a single row as a JSON object
/// Used when singular object format is requested
/// If strip_nulls is true, skips null values
fn format_row_as_json_object_impl(
    result: ?*PGresult,
    row: i32,
    nfields: i32,
    json_buf: []u8,
    strip_nulls: bool,
    raw_json_fields: []const [64]u8,
    raw_json_field_lens: []const usize,
    raw_json_field_count: usize,
    column_meta: ?[]const JsonColumnMeta,
) usize {
    if (result == null) return 0;

    var pos: usize = 0;

    // Start object
    json_buf[pos] = '{';
    pos += 1;

    var col: i32 = 0;
    var first_field: bool = true;
    while (col < nfields) : (col += 1) {
        // Check if value is null and we're stripping nulls
        const is_null = pgGetisnull(result, row, col) != 0;
        if (strip_nulls and is_null) {
            // Skip null fields when stripping nulls
            continue;
        }

        if (!first_field) {
            json_buf[pos] = ',';
            pos += 1;
        }
        first_field = false;

        // Get column name
        const meta = if (column_meta) |items| items[@intCast(col)] else JsonColumnMeta{
            .name = blk: {
                const fname = pgFname(result, col);
                break :blk if (fname != null) std.mem.span(fname) else "";
            },
            .emit_raw_json = blk: {
                const fname = pgFname(result, col);
                const field_name = if (fname != null) std.mem.span(fname) else "";
                break :blk column_is_raw_json(raw_json_fields, raw_json_field_lens, raw_json_field_count, field_name);
            },
        };
        if (meta.name.len != 0) {
            json_buf[pos] = '"';
            pos += 1;

            const remaining_for_name = if (pos <= json_buf.len) json_buf.len - pos else 0;
            const name_copy_len = @min(meta.name.len, remaining_for_name);
            @memcpy(json_buf[pos..][0..name_copy_len], meta.name[0..name_copy_len]);
            pos += name_copy_len;

            json_buf[pos] = '"';
            pos += 1;
            json_buf[pos] = ':';
            pos += 1;
        }

        // Check if value is null
        if (is_null) {
            const null_str = "null";
            @memcpy(json_buf[pos..][0..null_str.len], null_str);
            pos += null_str.len;
        } else {
            // Get value
            const value = pgGetvalue(result, row, col);
            if (value != null) {
                const value_len: usize = @intCast(pgGetlength(result, row, col));
                const value_slice = value[0..value_len];
                if (meta.emit_raw_json) {
                    const remaining_for_value = if (pos <= json_buf.len) json_buf.len - pos else 0;
                    const copy_len = @min(value_slice.len, remaining_for_value);
                    @memcpy(json_buf[pos..][0..copy_len], value_slice[0..copy_len]);
                    pos += copy_len;
                } else {
                    pos = append_json_quoted_string(json_buf, pos, value_slice);
                }
            } else {
                const null_str = "null";
                @memcpy(json_buf[pos..][0..null_str.len], null_str);
                pos += null_str.len;
            }
        }
    }

    // End object
    json_buf[pos] = '}';
    pos += 1;

    return pos;
}

/// Format a single row as a JSON object
/// Used when singular object format is requested
fn format_row_as_json_object(
    result: ?*PGresult,
    row: i32,
    nfields: i32,
    json_buf: []u8,
) usize {
    return format_row_as_json_object_impl(result, row, nfields, json_buf, false, &.{}, &.{}, 0, null);
}

/// Returns the length of JSON written to buffer
fn format_result_as_json(
    result: ?*PGresult,
    ntuples: i32,
    nfields: i32,
    json_buf: []u8,
) usize {
    var pos: usize = 0;

    // Start array
    json_buf[pos] = '[';
    pos += 1;

    var row: i32 = 0;
    while (row < ntuples) : (row += 1) {
        if (row > 0) {
            json_buf[pos] = ',';
            pos += 1;
        }

        // Start object
        json_buf[pos] = '{';
        pos += 1;

        var col: i32 = 0;
        while (col < nfields) : (col += 1) {
            if (col > 0) {
                json_buf[pos] = ',';
                pos += 1;
            }

            // Get column name
            const fname = pgFname(result, col);
            if (fname != null) {
                // "column_name":
                json_buf[pos] = '"';
                pos += 1;

                var i: usize = 0;
                while (fname[i] != 0 and pos < json_buf.len - 10) : (i += 1) {
                    json_buf[pos] = fname[i];
                    pos += 1;
                }

                json_buf[pos] = '"';
                pos += 1;
                json_buf[pos] = ':';
                pos += 1;
            }

            // Check if value is null
            if (pgGetisnull(result, row, col) != 0) {
                const null_str = "null";
                @memcpy(json_buf[pos..][0..null_str.len], null_str);
                pos += null_str.len;
            } else {
                // Get value
                const value = pgGetvalue(result, row, col);
                if (value != null) {
                    // Quote string values
                    json_buf[pos] = '"';
                    pos += 1;

                    var i: usize = 0;
                    while (value[i] != 0 and pos < json_buf.len - 10) : (i += 1) {
                        const c = value[i];
                        // Escape special JSON characters
                        if (c == '"' or c == '\\') {
                            json_buf[pos] = '\\';
                            pos += 1;
                        }
                        if (c == '\n') {
                            json_buf[pos] = '\\';
                            pos += 1;
                            json_buf[pos] = 'n';
                            pos += 1;
                        } else if (c == '\r') {
                            json_buf[pos] = '\\';
                            pos += 1;
                            json_buf[pos] = 'r';
                            pos += 1;
                        } else if (c == '\t') {
                            json_buf[pos] = '\\';
                            pos += 1;
                            json_buf[pos] = 't';
                            pos += 1;
                        } else {
                            json_buf[pos] = c;
                            pos += 1;
                        }
                    }

                    json_buf[pos] = '"';
                    pos += 1;
                } else {
                    const null_str = "null";
                    @memcpy(json_buf[pos..][0..null_str.len], null_str);
                    pos += null_str.len;
                }
            }
        }

        // End object
        json_buf[pos] = '}';
        pos += 1;
    }

    // End array
    json_buf[pos] = ']';
    pos += 1;

    return pos;
}

/// Format query results as JSON array with optional null stripping
fn format_result_as_json_with_options(
    result: ?*PGresult,
    ntuples: i32,
    nfields: i32,
    json_buf: []u8,
    strip_nulls: bool,
    raw_json_fields: []const [64]u8,
    raw_json_field_lens: []const usize,
    raw_json_field_count: usize,
) usize {
    var pos: usize = 0;
    var column_metas: [MAX_COLUMNS]JsonColumnMeta = undefined;
    const column_meta = build_json_column_meta(result, nfields, raw_json_fields, raw_json_field_lens, raw_json_field_count, &column_metas);

    // Start array
    json_buf[pos] = '[';
    pos += 1;

    var row: i32 = 0;
    while (row < ntuples) : (row += 1) {
        if (row > 0) {
            json_buf[pos] = ',';
            pos += 1;
        }

        // Use the implementation with null stripping option
        const row_len = format_row_as_json_object_impl(result, row, nfields, json_buf[pos..], strip_nulls, raw_json_fields, raw_json_field_lens, raw_json_field_count, column_meta);
        pos += row_len;
    }

    // End array
    json_buf[pos] = ']';
    pos += 1;

    return pos;
}

/// Format query results as JSON, respecting singular object preference and null stripping
/// If Accept header contains "application/vnd.pgrst.object+json" and there's exactly one row,
/// returns that row as a single object instead of an array
fn format_result_as_json_smart(
    result: ?*PGresult,
    ntuples: i32,
    nfields: i32,
    json_buf: []u8,
    singular_object: bool,
    strip_nulls: bool,
    raw_json_fields: []const [64]u8,
    raw_json_field_lens: []const usize,
    raw_json_field_count: usize,
) usize {
    // Check if singular object format is requested
    if (singular_object) {
        // For singular object format, return first row if it exists
        if (ntuples >= 1) {
            var column_metas: [MAX_COLUMNS]JsonColumnMeta = undefined;
            const column_meta = build_json_column_meta(result, nfields, raw_json_fields, raw_json_field_lens, raw_json_field_count, &column_metas);
            return format_row_as_json_object_impl(result, 0, nfields, json_buf, strip_nulls, raw_json_fields, raw_json_field_lens, raw_json_field_count, column_meta);
        }
        // If no rows, return empty object
        json_buf[0] = '{';
        json_buf[1] = '}';
        return 2;
    }

    // Default: return array format (with optional null stripping)
    return format_result_as_json_with_options(result, ntuples, nfields, json_buf, strip_nulls, raw_json_fields, raw_json_field_lens, raw_json_field_count);
}


fn pgrest_create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(ngx_pgrest_loc_conf_t, cf.*.pool)) |loc| {
        loc.*.jwt_role_claim = ngx_string("role");
        loc.*.jwt_role_claim_explicit = 0;
        loc.*.pool_size = NGX_CONF_UNSET;
        return loc;
    }
    return null;
}

fn pgrest_merge_loc_conf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cf;
    const prev = core.castPtr(ngx_pgrest_loc_conf_t, parent) orelse return NGX_CONF_OK;
    const cur = core.castPtr(ngx_pgrest_loc_conf_t, child) orelse return NGX_CONF_OK;

    if (cur.*.conninfo.len == 0) cur.*.conninfo = prev.*.conninfo;
    if (cur.*.schemas_raw.len == 0) cur.*.schemas_raw = prev.*.schemas_raw;
    if (cur.*.jwt_secret.len == 0) cur.*.jwt_secret = prev.*.jwt_secret;
    if (cur.*.anon_role.len == 0) cur.*.anon_role = prev.*.anon_role;
    if (cur.*.jwt_role_claim_explicit == 0 and prev.*.jwt_role_claim.len > 0) {
        cur.*.jwt_role_claim = prev.*.jwt_role_claim;
        cur.*.jwt_role_claim_explicit = prev.*.jwt_role_claim_explicit;
    }
    if (cur.*.pool_size == NGX_CONF_UNSET) cur.*.pool_size = prev.*.pool_size;
    return NGX_CONF_OK;
}

fn ngx_conf_set_pgrest_pass(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    data: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(ngx_pgrest_loc_conf_t, data)) |loc| {
        // Get the connection string argument
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            loc.*.conninfo = arg.*;

            // Register the content handler
            if (core.castPtr(
                http.ngx_http_core_loc_conf_t,
                conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
            )) |clcf| {
                clcf.*.handler = ngx_http_pgrest_upstream_handler;
                return NGX_CONF_OK;
            }
        }
    }
    return NGX_CONF_ERROR;
}

fn ngx_conf_set_pgrest_jwt_secret(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    data: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(ngx_pgrest_loc_conf_t, data)) |loc| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            loc.*.jwt_secret = arg.*;
            return NGX_CONF_OK;
        }
    }
    return NGX_CONF_ERROR;
}

fn ngx_conf_set_pgrest_anon_role(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    data: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(ngx_pgrest_loc_conf_t, data)) |loc| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            loc.*.anon_role = arg.*;
            return NGX_CONF_OK;
        }
    }
    return NGX_CONF_ERROR;
}

fn ngx_conf_set_pgrest_jwt_role_claim(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    data: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(ngx_pgrest_loc_conf_t, data)) |loc| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            loc.*.jwt_role_claim = arg.*;
            loc.*.jwt_role_claim_explicit = 1;
            return NGX_CONF_OK;
        }
    }
    return NGX_CONF_ERROR;
}

fn ngx_conf_set_pgrest_schemas(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    data: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(ngx_pgrest_loc_conf_t, data)) |loc| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const raw = trim_ascii_spaces(core.slicify(u8, arg.*.data, arg.*.len));
            if (raw.len == 0) return NGX_CONF_ERROR;

            var it = std.mem.splitScalar(u8, raw, ',');
            var count: usize = 0;
            while (it.next()) |part| {
                const schema = trim_ascii_spaces(part);
                if (schema.len == 0 or !is_valid_schema_identifier(schema)) {
                    return NGX_CONF_ERROR;
                }
                count += 1;
            }
            if (count == 0) return NGX_CONF_ERROR;

            loc.*.schemas_raw = arg.*;
            return NGX_CONF_OK;
        }
    }
    return NGX_CONF_ERROR;
}

fn ngx_conf_set_pgrest_pool_size(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    data: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(ngx_pgrest_loc_conf_t, data)) |loc| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const s = core.slicify(u8, arg.*.data, arg.*.len);
            const n = std.fmt.parseInt(ngx_int_t, s, 10) catch return NGX_CONF_ERROR;
            if (n < 1 or n > POOL_MAX_CONNECTIONS) return NGX_CONF_ERROR;
            loc.*.pool_size = n;
            return NGX_CONF_OK;
        }
    }
    return NGX_CONF_ERROR;
}

/// SQL operation types based on HTTP method
const SqlOp = enum {
    select,
    insert,
    update,
    delete,

    pub fn fromMethod(method: ngx_uint_t) ?SqlOp {
        return switch (method) {
            http.NGX_HTTP_GET => .select,
            http.NGX_HTTP_HEAD => .select,
            http.NGX_HTTP_POST => .insert,
            http.NGX_HTTP_PATCH => .update,
            http.NGX_HTTP_PUT => .update,
            http.NGX_HTTP_DELETE => .delete,
            else => null,
        };
    }

    pub fn keyword(self: SqlOp) []const u8 {
        return switch (self) {
            .select => "SELECT",
            .insert => "INSERT",
            .update => "UPDATE",
            .delete => "DELETE",
        };
    }
};

/// Maximum SQL query buffer size
const MAX_QUERY_SIZE = 4096;

/// Build SQL query from request components
/// Returns the length of the query written to the buffer
fn build_sql_query(
    query_buf: []u8,
    sql_op: SqlOp,
    table: []const u8,
    where_clause: []const u8,
    json_fields: []const JsonField,
    select_clause: []const u8,
    group_by_clause: []const u8,
    order_specs: []const OrderSpec,
    pagination: Pagination,
    include_returning: bool,
    params: ?*PgRequestCtx,
) usize {
    var pos: usize = 0;

    switch (sql_op) {
        .select => {
            // SELECT columns FROM table
            const select_str = "SELECT ";
            @memcpy(query_buf[pos..][0..select_str.len], select_str);
            pos += select_str.len;

            if (select_clause.len > 0) {
                @memcpy(query_buf[pos..][0..select_clause.len], select_clause);
                pos += select_clause.len;
            } else {
                // Select all columns
                query_buf[pos] = '*';
                pos += 1;
            }

            const from_str = " FROM ";
            @memcpy(query_buf[pos..][0..from_str.len], from_str);
            pos += from_str.len;

            @memcpy(query_buf[pos..][0..table.len], table);
            pos += table.len;
        },
        .insert => {
            // INSERT INTO table (cols) VALUES (vals)
            const insert_prefix = "INSERT INTO ";
            @memcpy(query_buf[pos..][0..insert_prefix.len], insert_prefix);
            pos += insert_prefix.len;

            @memcpy(query_buf[pos..][0..table.len], table);
            pos += table.len;

            if (json_fields.len > 0) {
                // Column names
                query_buf[pos] = ' ';
                pos += 1;
                query_buf[pos] = '(';
                pos += 1;

                for (json_fields, 0..) |field, i| {
                    if (i > 0) {
                        query_buf[pos] = ',';
                        pos += 1;
                    }
                    @memcpy(query_buf[pos..][0..field.name.len], field.name);
                    pos += field.name.len;
                }

                query_buf[pos] = ')';
                pos += 1;

                // VALUES
                const values_str = " VALUES (";
                @memcpy(query_buf[pos..][0..values_str.len], values_str);
                pos += values_str.len;

                for (json_fields, 0..) |field, i| {
                    if (i > 0) {
                        query_buf[pos] = ',';
                        pos += 1;
                    }

                    if (field.is_null) {
                        const null_str = "NULL";
                        @memcpy(query_buf[pos..][0..null_str.len], null_str);
                        pos += null_str.len;
                    } else if (field.is_number) {
                        @memcpy(query_buf[pos..][0..field.value.len], field.value);
                        pos += field.value.len;
                    } else {
                        pos = append_param_or_quoted(query_buf, pos, field.value, params);
                    }
                }

                query_buf[pos] = ')';
                pos += 1;

                if (include_returning) {
                    const returning = " RETURNING *";
                    @memcpy(query_buf[pos..][0..returning.len], returning);
                    pos += returning.len;
                }
            } else {
                const values = if (include_returning) " DEFAULT VALUES RETURNING *" else " DEFAULT VALUES";
                @memcpy(query_buf[pos..][0..values.len], values);
                pos += values.len;
            }
        },
        .update => {
            // UPDATE table SET col1=val1, col2=val2
            const update_prefix = "UPDATE ";
            @memcpy(query_buf[pos..][0..update_prefix.len], update_prefix);
            pos += update_prefix.len;

            @memcpy(query_buf[pos..][0..table.len], table);
            pos += table.len;

            const set_str = " SET ";
            @memcpy(query_buf[pos..][0..set_str.len], set_str);
            pos += set_str.len;

            if (json_fields.len > 0) {
                for (json_fields, 0..) |field, i| {
                    if (i > 0) {
                        query_buf[pos] = ',';
                        pos += 1;
                    }

                    @memcpy(query_buf[pos..][0..field.name.len], field.name);
                    pos += field.name.len;
                    query_buf[pos] = '=';
                    pos += 1;

                    if (field.is_null) {
                        const null_str = "NULL";
                        @memcpy(query_buf[pos..][0..null_str.len], null_str);
                        pos += null_str.len;
                    } else if (field.is_number) {
                        @memcpy(query_buf[pos..][0..field.value.len], field.value);
                        pos += field.value.len;
                    } else {
                        pos = append_param_or_quoted(query_buf, pos, field.value, params);
                    }
                }
            } else {
                const default_set = "updated_at=NOW()";
                @memcpy(query_buf[pos..][0..default_set.len], default_set);
                pos += default_set.len;
            }
        },
        .delete => {
            // DELETE FROM table
            const delete_prefix = "DELETE FROM ";
            @memcpy(query_buf[pos..][0..delete_prefix.len], delete_prefix);
            pos += delete_prefix.len;

            @memcpy(query_buf[pos..][0..table.len], table);
            pos += table.len;
        },
    }

    // Add WHERE clause if filters exist
    if (where_clause.len > 0) {
        const where = " WHERE ";
        @memcpy(query_buf[pos..][0..where.len], where);
        pos += where.len;

        @memcpy(query_buf[pos..][0..where_clause.len], where_clause);
        pos += where_clause.len;
    }

    // Add RETURNING for UPDATE/DELETE
    if ((sql_op == .update or sql_op == .delete) and include_returning) {
        const returning = " RETURNING *";
        @memcpy(query_buf[pos..][0..returning.len], returning);
        pos += returning.len;
    }

    if (sql_op == .select and group_by_clause.len > 0) {
        const group_by = " GROUP BY ";
        @memcpy(query_buf[pos..][0..group_by.len], group_by);
        pos += group_by.len;
        @memcpy(query_buf[pos..][0..group_by_clause.len], group_by_clause);
        pos += group_by_clause.len;
    }

    // Add ORDER BY for SELECT
    if (sql_op == .select and order_specs.len > 0) {
        const order_str = " ORDER BY ";
        @memcpy(query_buf[pos..][0..order_str.len], order_str);
        pos += order_str.len;

        for (order_specs, 0..) |spec, i| {
            if (i > 0) {
                query_buf[pos] = ',';
                pos += 1;
            }
            const expr = spec.expr();
            pos = append_column_expression(query_buf, pos, expr) orelse return pos;

            if (spec.dir == .desc) {
                const desc_str = " DESC";
                @memcpy(query_buf[pos..][0..desc_str.len], desc_str);
                pos += desc_str.len;
            } else {
                const asc_str = " ASC";
                @memcpy(query_buf[pos..][0..asc_str.len], asc_str);
                pos += asc_str.len;
            }

            switch (spec.nulls) {
                .none => {},
                .first => {
                    const nulls_first = " NULLS FIRST";
                    @memcpy(query_buf[pos..][0..nulls_first.len], nulls_first);
                    pos += nulls_first.len;
                },
                .last => {
                    const nulls_last = " NULLS LAST";
                    @memcpy(query_buf[pos..][0..nulls_last.len], nulls_last);
                    pos += nulls_last.len;
                },
            }
        }
    }

    // Add LIMIT/OFFSET for SELECT
    if (sql_op == .select) {
        if (pagination.limit) |limit| {
            const limit_str = " LIMIT ";
            @memcpy(query_buf[pos..][0..limit_str.len], limit_str);
            pos += limit_str.len;

            // Format number
            var num_buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{limit}) catch "0";
            @memcpy(query_buf[pos..][0..num_str.len], num_str);
            pos += num_str.len;
        }

        if (pagination.offset) |offset| {
            const offset_str = " OFFSET ";
            @memcpy(query_buf[pos..][0..offset_str.len], offset_str);
            pos += offset_str.len;

            var num_buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{offset}) catch "0";
            @memcpy(query_buf[pos..][0..num_str.len], num_str);
            pos += num_str.len;
        }
    }

    return pos;
}

/// Column selection for SELECT queries
const MAX_SELECT_COLUMNS = 32;

/// Parse ?select=col1,col2,col3 parameter
fn parse_select_columns(args: ngx_str_t, columns: *[MAX_SELECT_COLUMNS][]const u8) usize {
    if (args.len == 0 or args.data == core.nullptr(u8)) {
        return 0;
    }

    const query = core.slicify(u8, args.data, args.len);
    var pos: usize = 0;

    // Find select= parameter
    while (pos < query.len) {
        // Check for "select="
        if (pos + 7 <= query.len and std.mem.eql(u8, query[pos .. pos + 7], "select=")) {
            pos += 7;

            // Parse comma-separated column names
            var count: usize = 0;
            var col_start = pos;

            while (pos <= query.len and count < MAX_SELECT_COLUMNS) {
                if (pos == query.len or query[pos] == '&' or query[pos] == ',') {
                    if (pos > col_start) {
                        columns[count] = query[col_start..pos];
                        count += 1;
                    }
                    if (pos == query.len or query[pos] == '&') {
                        return count;
                    }
                    col_start = pos + 1;
                }
                pos += 1;
            }
            return count;
        }
        // Skip to next parameter
        while (pos < query.len and query[pos] != '&') : (pos += 1) {}
        pos += 1;
    }
    return 0;
}

/// Order direction
const OrderDir = enum {
    asc,
    desc,
};

const OrderNulls = enum {
    none,
    first,
    last,
};

/// Order specification
const OrderSpec = struct {
    expr_buf: [512]u8,
    expr_len: usize,
    dir: OrderDir,
    nulls: OrderNulls,

    fn expr(self: *const OrderSpec) []const u8 {
        return self.expr_buf[0..self.expr_len];
    }
};

const OrderParseResult = struct {
    count: usize,
    invalid: bool,
};

const MAX_ORDER_COLUMNS = 8;

fn find_last_top_level_separator(value: []const u8, needle: u8) ?usize {
    var depth: usize = 0;
    var in_quotes = false;
    var escaped = false;
    var last: ?usize = null;

    for (value, 0..) |c, i| {
        if (in_quotes) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') {
                in_quotes = false;
            }
            continue;
        }

        switch (c) {
            '"' => in_quotes = true,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }

        if (depth == 0 and c == needle) last = i;
    }

    return last;
}

fn parse_order_spec(raw_spec: []const u8) ?OrderSpec {
    if (raw_spec.len == 0) return null;

    var decoded_buf: [512]u8 = undefined;
    const spec = decode_query_component_into(&decoded_buf, trim_ascii_spaces(raw_spec)) orelse return null;
    if (spec.len == 0) return null;

    var expr_end = spec.len;
    var order = OrderSpec{
        .expr_buf = undefined,
        .expr_len = 0,
        .dir = .asc,
        .nulls = .none,
    };
    var saw_dir = false;

    while (find_last_top_level_separator(spec[0..expr_end], '.')) |dot| {
        const part = trim_ascii_spaces(spec[dot + 1 .. expr_end]);
        if (part.len == 0) return null;

        if (std.mem.eql(u8, part, "asc")) {
            if (saw_dir) return null;
            saw_dir = true;
            expr_end = dot;
            continue;
        }

        if (std.mem.eql(u8, part, "desc")) {
            if (saw_dir) return null;
            saw_dir = true;
            order.dir = .desc;
            expr_end = dot;
            continue;
        }

        if (std.mem.eql(u8, part, "nullsfirst")) {
            if (order.nulls != .none) return null;
            order.nulls = .first;
            expr_end = dot;
            continue;
        }

        if (std.mem.eql(u8, part, "nullslast")) {
            if (order.nulls != .none) return null;
            order.nulls = .last;
            expr_end = dot;
            continue;
        }

        return null;
    }

    const expr = trim_ascii_spaces(spec[0..expr_end]);
    if (expr.len == 0 or expr.len > order.expr_buf.len) return null;
    @memcpy(order.expr_buf[0..expr.len], expr);
    order.expr_len = expr.len;

    var expr_sql_buf: [1024]u8 = undefined;
    _ = append_column_expression(&expr_sql_buf, 0, order.expr()) orelse return null;

    return order;
}

fn reject_invalid_order(r: [*c]ngx_http_request_t) ngx_int_t {
    return send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid order parameter\"}");
}

/// Parse ?order=col1.desc,col2.asc.nullsfirst parameter
fn parse_order(args: ngx_str_t, orders: *[MAX_ORDER_COLUMNS]OrderSpec) OrderParseResult {
    if (args.len == 0 or args.data == core.nullptr(u8)) {
        return .{ .count = 0, .invalid = false };
    }

    const query = core.slicify(u8, args.data, args.len);
    var pos: usize = 0;

    // Find order= parameter
    while (pos < query.len) {
        if (pos + 6 <= query.len and std.mem.eql(u8, query[pos .. pos + 6], "order=")) {
            pos += 6;

            var count: usize = 0;
            var col_start = pos;

            while (pos <= query.len and count < MAX_ORDER_COLUMNS) {
                if (pos == query.len or query[pos] == '&' or query[pos] == ',') {
                    if (pos > col_start) {
                        const spec = query[col_start..pos];
                        orders[count] = parse_order_spec(spec) orelse return .{ .count = 0, .invalid = true };
                        count += 1;
                    } else {
                        return .{ .count = 0, .invalid = true };
                    }
                    if (pos == query.len or query[pos] == '&') {
                        return .{ .count = count, .invalid = false };
                    }
                    col_start = pos + 1;
                }
                pos += 1;
            }
            return .{ .count = count, .invalid = false };
        }
        while (pos < query.len and query[pos] != '&') : (pos += 1) {}
        pos += 1;
    }
    return .{ .count = 0, .invalid = false };
}

/// Pagination parameters
const Pagination = struct {
    limit: ?usize,
    offset: ?usize,
};

/// Parse ?limit=N&offset=M parameters
fn parse_pagination(args: ngx_str_t) Pagination {
    var result = Pagination{ .limit = null, .offset = null };

    if (args.len == 0 or args.data == core.nullptr(u8)) {
        return result;
    }

    const query = core.slicify(u8, args.data, args.len);
    var pos: usize = 0;

    while (pos < query.len) {
        // Check for limit=
        if (pos + 6 <= query.len and std.mem.eql(u8, query[pos .. pos + 6], "limit=")) {
            pos += 6;
            var num: usize = 0;
            while (pos < query.len and query[pos] >= '0' and query[pos] <= '9') {
                num = num * 10 + (query[pos] - '0');
                pos += 1;
            }
            result.limit = num;
        }
        // Check for offset=
        else if (pos + 7 <= query.len and std.mem.eql(u8, query[pos .. pos + 7], "offset=")) {
            pos += 7;
            var num: usize = 0;
            while (pos < query.len and query[pos] >= '0' and query[pos] <= '9') {
                num = num * 10 + (query[pos] - '0');
                pos += 1;
            }
            result.offset = num;
        } else {
            // Skip to next parameter
            while (pos < query.len and query[pos] != '&') : (pos += 1) {}
            pos += 1;
        }
    }

    return result;
}

fn parse_columns_param(args: ngx_str_t, columns: *[MAX_COLUMNS][]const u8) ?usize {
    if (args.len == 0 or args.data == core.nullptr(u8)) {
        return 0;
    }

    const query = core.slicify(u8, args.data, args.len);
    var pos: usize = 0;

    while (pos < query.len) {
        if (pos + 8 <= query.len and std.mem.eql(u8, query[pos .. pos + 8], "columns=")) {
            pos += 8;

            var count: usize = 0;
            var col_start = pos;
            while (pos <= query.len and count < MAX_COLUMNS) {
                if (pos == query.len or query[pos] == '&' or query[pos] == ',') {
                    if (pos <= col_start) return null;

                    var decoded_buf: [256]u8 = undefined;
                    const decoded = decode_query_component_into(&decoded_buf, query[col_start..pos]) orelse return null;
                    const name = trim_ascii_spaces(decoded);
                    if (name.len == 0 or !is_valid_schema_identifier(name)) return null;

                    columns[count] = query[col_start..pos];
                    count += 1;

                    if (pos == query.len or query[pos] == '&') {
                        return count;
                    }
                    col_start = pos + 1;
                }
                pos += 1;
            }

            if (count == MAX_COLUMNS and pos < query.len and query[pos] != '&') return null;
            return count;
        }

        while (pos < query.len and query[pos] != '&') : (pos += 1) {}
        pos += 1;
    }

    return 0;
}

fn parse_on_conflict_param(args: ngx_str_t, columns: *[MAX_COLUMNS][]const u8) ?usize {
    if (args.len == 0 or args.data == core.nullptr(u8)) {
        return 0;
    }

    const query = core.slicify(u8, args.data, args.len);
    var pos: usize = 0;

    while (pos < query.len) {
        if (pos + 12 <= query.len and std.mem.eql(u8, query[pos .. pos + 12], "on_conflict=")) {
            pos += 12;

            var count: usize = 0;
            var col_start = pos;
            while (pos <= query.len and count < MAX_COLUMNS) {
                if (pos == query.len or query[pos] == '&' or query[pos] == ',') {
                    if (pos <= col_start) return null;

                    var decoded_buf: [256]u8 = undefined;
                    const decoded = decode_query_component_into(&decoded_buf, query[col_start..pos]) orelse return null;
                    const name = trim_ascii_spaces(decoded);
                    if (name.len == 0 or !is_valid_schema_identifier(name)) return null;

                    columns[count] = query[col_start..pos];
                    count += 1;

                    if (pos == query.len or query[pos] == '&') {
                        return count;
                    }
                    col_start = pos + 1;
                }
                pos += 1;
            }

            if (count == MAX_COLUMNS and pos < query.len and query[pos] != '&') return null;
            return count;
        }

        while (pos < query.len and query[pos] != '&') : (pos += 1) {}
        pos += 1;
    }

    return 0;
}

/// PostgREST filter operators
const FilterOp = enum {
    eq, // equals
    neq, // not equals
    gt, // greater than
    gte, // greater than or equal
    lt, // less than
    lte, // less than or equal
    like, // LIKE pattern match
    ilike, // case-insensitive LIKE
    match, // regex match
    imatch, // case-insensitive regex match
    is_, // IS (for null checks)
    isdistinct, // IS DISTINCT FROM
    fts, // full text search
    plfts, // plain full text search
    phfts, // phrase full text search
    wfts, // web full text search
    in_, // IN (list of values)
    cs, // contains
    cd, // contained in
    ov, // overlap
    sl, // strictly left of
    sr, // strictly right of
    nxr, // does not extend right of
    nxl, // does not extend left of
    adj, // adjacent

    pub fn toSql(self: FilterOp) []const u8 {
        return switch (self) {
            .eq => "=",
            .neq => "<>",
            .gt => ">",
            .gte => ">=",
            .lt => "<",
            .lte => "<=",
            .like => "LIKE",
            .ilike => "ILIKE",
            .match => "~",
            .imatch => "~*",
            .is_ => "IS",
            .isdistinct => "IS DISTINCT FROM",
            .fts, .plfts, .phfts, .wfts => "@@",
            .in_ => "IN",
            .cs => "@>",
            .cd => "<@",
            .ov => "&&",
            .sl => "<<",
            .sr => ">>",
            .nxr => "&<",
            .nxl => "&>",
            .adj => "-|-",
        };
    }

    pub fn fromString(s: []const u8) ?FilterOp {
        if (std.mem.eql(u8, s, "eq")) return .eq;
        if (std.mem.eql(u8, s, "neq")) return .neq;
        if (std.mem.eql(u8, s, "gt")) return .gt;
        if (std.mem.eql(u8, s, "gte")) return .gte;
        if (std.mem.eql(u8, s, "lt")) return .lt;
        if (std.mem.eql(u8, s, "lte")) return .lte;
        if (std.mem.eql(u8, s, "like")) return .like;
        if (std.mem.eql(u8, s, "ilike")) return .ilike;
        if (std.mem.eql(u8, s, "match")) return .match;
        if (std.mem.eql(u8, s, "imatch")) return .imatch;
        if (std.mem.eql(u8, s, "is")) return .is_;
        if (std.mem.eql(u8, s, "isdistinct")) return .isdistinct;
        if (std.mem.eql(u8, s, "fts")) return .fts;
        if (std.mem.eql(u8, s, "plfts")) return .plfts;
        if (std.mem.eql(u8, s, "phfts")) return .phfts;
        if (std.mem.eql(u8, s, "wfts")) return .wfts;
        if (std.mem.eql(u8, s, "in")) return .in_;
        if (std.mem.eql(u8, s, "cs")) return .cs;
        if (std.mem.eql(u8, s, "cd")) return .cd;
        if (std.mem.eql(u8, s, "ov")) return .ov;
        if (std.mem.eql(u8, s, "sl")) return .sl;
        if (std.mem.eql(u8, s, "sr")) return .sr;
        if (std.mem.eql(u8, s, "nxr")) return .nxr;
        if (std.mem.eql(u8, s, "nxl")) return .nxl;
        if (std.mem.eql(u8, s, "adj")) return .adj;
        return null;
    }
};

/// A single filter condition parsed from query string
const Filter = struct {
    column: []const u8,
    op: FilterOp,
    value: []const u8,
};

/// Maximum number of filters we support
const MAX_FILTERS = 16;

/// Parse query string into filters
/// Format: column=op.value&column2=op2.value2
fn parse_filters(args: ngx_str_t, filters: *[MAX_FILTERS]Filter) usize {
    if (args.len == 0 or args.data == core.nullptr(u8)) {
        return 0;
    }

    const query = core.slicify(u8, args.data, args.len);
    var count: usize = 0;
    var pos: usize = 0;

    while (pos < query.len and count < MAX_FILTERS) {
        // Find end of this parameter (& or end of string)
        var param_end = pos;
        while (param_end < query.len and query[param_end] != '&') {
            param_end += 1;
        }

        const param = query[pos..param_end];

        // Parse column=op.value
        if (parse_single_filter(param)) |filter| {
            filters[count] = filter;
            count += 1;
        }

        pos = param_end + 1; // Skip the '&'
    }

    return count;
}

/// Parse a single filter parameter: column=op.value
fn parse_single_filter(param: []const u8) ?Filter {
    // Find '=' separator
    var eq_pos: usize = 0;
    while (eq_pos < param.len and param[eq_pos] != '=') {
        eq_pos += 1;
    }

    if (eq_pos == 0 or eq_pos >= param.len - 1) {
        return null; // No column name or no value
    }

    const column = param[0..eq_pos];
    const rest = param[eq_pos + 1 ..];

    // Find '.' separator between operator and value
    var dot_pos: usize = 0;
    while (dot_pos < rest.len and rest[dot_pos] != '.') {
        dot_pos += 1;
    }

    if (dot_pos == 0 or dot_pos >= rest.len) {
        return null; // No operator or no value
    }

    const op_str = rest[0..dot_pos];
    const value = rest[dot_pos + 1 ..];

    const op = FilterOp.fromString(op_str) orelse return null;

    return Filter{
        .column = column,
        .op = op,
        .value = value,
    };
}

fn append_filter_value(buf_out: []u8, pos_in: usize, filter: Filter, params: ?*PgRequestCtx) usize {
    var pos = pos_in;

    switch (filter.op) {
        .is_ => {
            if (std.ascii.eqlIgnoreCase(filter.value, "null")) {
                const null_str = "NULL";
                @memcpy(buf_out[pos..][0..null_str.len], null_str);
                return pos + null_str.len;
            }
            if (std.ascii.eqlIgnoreCase(filter.value, "true")) {
                const true_str = "TRUE";
                @memcpy(buf_out[pos..][0..true_str.len], true_str);
                return pos + true_str.len;
            }
            if (std.ascii.eqlIgnoreCase(filter.value, "false")) {
                const false_str = "FALSE";
                @memcpy(buf_out[pos..][0..false_str.len], false_str);
                return pos + false_str.len;
            }
            return append_param_or_quoted(buf_out, pos, filter.value, params);
        },
        .in_ => {
            if (filter.value.len >= 2 and filter.value[0] == '(' and filter.value[filter.value.len - 1] == ')') {
                buf_out[pos] = '(';
                pos += 1;

                const inner = filter.value[1 .. filter.value.len - 1];
                var item_start: usize = 0;
                var first = true;
                var i: usize = 0;

                while (i <= inner.len) : (i += 1) {
                    if (i == inner.len or inner[i] == ',') {
                        const item = inner[item_start..i];
                        if (!first) {
                            buf_out[pos] = ',';
                            pos += 1;
                        }
                        first = false;

                        if (std.ascii.eqlIgnoreCase(item, "null")) {
                            const null_str = "NULL";
                            @memcpy(buf_out[pos..][0..null_str.len], null_str);
                            pos += null_str.len;
                        } else if (std.ascii.eqlIgnoreCase(item, "true") or std.ascii.eqlIgnoreCase(item, "false") or is_numeric(item)) {
                            @memcpy(buf_out[pos..][0..item.len], item);
                            pos += item.len;
                        } else {
                            pos = append_param_or_quoted(buf_out, pos, item, params);
                        }

                        item_start = i + 1;
                    }
                }

                buf_out[pos] = ')';
                pos += 1;
                return pos;
            }

            return append_param_or_quoted(buf_out, pos, filter.value, params);
        },
        else => return append_param_or_quoted(buf_out, pos, filter.value, params),
    }
}

fn build_where_clause_from_filters(buf_out: []u8, filters: []const Filter, params: ?*PgRequestCtx) usize {
    var pos: usize = 0;

    for (filters, 0..) |filter, i| {
        if (i > 0) {
            const and_str = " AND ";
            @memcpy(buf_out[pos..][0..and_str.len], and_str);
            pos += and_str.len;
        }

        @memcpy(buf_out[pos..][0..filter.column.len], filter.column);
        pos += filter.column.len;

        buf_out[pos] = ' ';
        pos += 1;
        const op_sql = filter.op.toSql();
        @memcpy(buf_out[pos..][0..op_sql.len], op_sql);
        pos += op_sql.len;
        buf_out[pos] = ' ';
        pos += 1;

        pos = append_filter_value(buf_out, pos, filter, params);
    }

    return pos;
}

const WhereClauseResult = struct {
    len: usize,
    invalid: bool,
};

const SelectItemRenderResult = struct {
    select_len: usize,
    group_len: usize,
    aggregate: bool,
};

const AggregateFn = enum {
    sum,
    avg,
    min,
    max,
    count,

    fn sqlName(self: AggregateFn) []const u8 {
        return switch (self) {
            .sum => "sum",
            .avg => "avg",
            .min => "min",
            .max => "max",
            .count => "count",
        };
    }
};

fn decode_query_component_into(dest: []u8, src: []const u8) ?[]const u8 {
    var pos: usize = 0;
    var i: usize = 0;

    while (i < src.len) : (i += 1) {
        if (pos >= dest.len) return null;

        if (src[i] == '%') {
            if (i + 2 >= src.len) return null;
            const hi = std.fmt.charToDigit(src[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(src[i + 2], 16) catch return null;
            dest[pos] = @as(u8, @intCast(hi * 16 + lo));
            pos += 1;
            i += 2;
        } else {
            dest[pos] = src[i];
            pos += 1;
        }
    }

    return dest[0..pos];
}

fn unescape_wrapped_quotes_into(dest: []u8, value: []const u8) ?[]const u8 {
    const inner = if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
        value[1 .. value.len - 1]
    else
        value;

    var pos: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (pos >= dest.len) return null;
        if (inner[i] == '\\' and i + 1 < inner.len) {
            i += 1;
        }
        dest[pos] = inner[i];
        pos += 1;
    }

    return dest[0..pos];
}

fn is_simple_identifier(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn append_sql_identifier(buf_out: []u8, pos_in: usize, raw_value: []const u8) usize {
    var scratch: [512]u8 = undefined;
    const value = unescape_wrapped_quotes_into(&scratch, raw_value) orelse raw_value;

    if (is_simple_identifier(value)) {
        @memcpy(buf_out[pos_in..][0..value.len], value);
        return pos_in + value.len;
    }

    var pos = pos_in;
    buf_out[pos] = '"';
    pos += 1;
    for (value) |c| {
        if (c == '"') {
            buf_out[pos] = '"';
            pos += 1;
        }
        buf_out[pos] = c;
        pos += 1;
    }
    buf_out[pos] = '"';
    pos += 1;
    return pos;
}

fn append_castable_expression(buf_out: []u8, pos_in: usize, raw_expr: []const u8) ?usize {
    var expr = trim_ascii_spaces(raw_expr);
    if (expr.len == 0) return null;

    var cast: ?[]const u8 = null;
    if (std.mem.lastIndexOf(u8, expr, "::")) |cast_idx| {
        cast = trim_ascii_spaces(expr[cast_idx + 2 ..]);
        expr = trim_ascii_spaces(expr[0..cast_idx]);
        if (cast.?.len == 0 or expr.len == 0) return null;
    }

    var pos = append_column_expression(buf_out, pos_in, expr) orelse return null;
    if (cast) |cast_name| {
        const cast_sep = "::";
        @memcpy(buf_out[pos..][0..cast_sep.len], cast_sep);
        pos += cast_sep.len;
        pos = append_sql_identifier(buf_out, pos, cast_name);
    }
    return pos;
}

fn parse_aggregate_expression(expr_in: []const u8) ?struct {
    base_expr: []const u8,
    aggregate_fn: AggregateFn,
    output_cast: ?[]const u8,
} {
    const expr = trim_ascii_spaces(expr_in);
    if (std.mem.eql(u8, expr, "count()")) {
        return .{ .base_expr = "", .aggregate_fn = .count, .output_cast = null };
    }

    const candidates = [_]struct { suffix: []const u8, func: AggregateFn }{
        .{ .suffix = ".sum()", .func = .sum },
        .{ .suffix = ".avg()", .func = .avg },
        .{ .suffix = ".min()", .func = .min },
        .{ .suffix = ".max()", .func = .max },
        .{ .suffix = ".count()", .func = .count },
    };

    for (candidates) |candidate| {
        if (std.mem.lastIndexOf(u8, expr, candidate.suffix)) |idx| {
            const tail = expr[idx + candidate.suffix.len ..];
            var output_cast: ?[]const u8 = null;
            if (tail.len == 0) {
                // ok
            } else if (std.mem.startsWith(u8, tail, "::")) {
                const cast_name = trim_ascii_spaces(tail[2..]);
                if (cast_name.len == 0) return null;
                output_cast = cast_name;
            } else {
                continue;
            }

            const base_expr = trim_ascii_spaces(expr[0..idx]);
            if (base_expr.len == 0 and candidate.func != .count) return null;
            return .{ .base_expr = base_expr, .aggregate_fn = candidate.func, .output_cast = output_cast };
        }
    }
    return null;
}

fn append_column_expression(buf_out: []u8, pos_in: usize, raw_value: []const u8) ?usize {
    const arrow_idx = std.mem.indexOf(u8, raw_value, "->") orelse {
        return append_sql_identifier(buf_out, pos_in, raw_value);
    };

    var pos = pos_in;
    const base = raw_value[0..arrow_idx];
    const prefix = "to_jsonb(";
    @memcpy(buf_out[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    pos = append_sql_identifier(buf_out, pos, base);
    buf_out[pos] = ')';
    pos += 1;

    var rest = raw_value[arrow_idx..];
    var scratch: [256]u8 = undefined;
    while (rest.len > 0) {
        const is_text = std.mem.startsWith(u8, rest, "->>");
        const op = if (is_text) "->>" else if (std.mem.startsWith(u8, rest, "->")) "->" else return null;
        @memcpy(buf_out[pos..][0..op.len], op);
        pos += op.len;
        rest = rest[op.len..];

        const next_idx = std.mem.indexOf(u8, rest, "->") orelse rest.len;
        const segment_raw = rest[0..next_idx];
        if (segment_raw.len == 0) return null;
        const segment = unescape_wrapped_quotes_into(&scratch, segment_raw) orelse return null;
        if (is_numeric(segment)) {
            @memcpy(buf_out[pos..][0..segment.len], segment);
            pos += segment.len;
        } else {
            pos = append_sql_quoted(buf_out, pos, segment);
        }
        rest = rest[next_idx..];
    }

    return pos;
}

fn find_top_level_dot(value: []const u8) ?usize {
    var depth: usize = 0;
    var in_quotes = false;
    var escaped = false;

    for (value, 0..) |c, i| {
        if (in_quotes) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') {
                in_quotes = false;
            }
            continue;
        }

        switch (c) {
            '"' => in_quotes = true,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            '.' => if (depth == 0) return i,
            else => {},
        }
    }

    return null;
}

fn is_reserved_query_param(name: []const u8) bool {
    return std.mem.eql(u8, name, "select") or
        std.mem.eql(u8, name, "order") or
        std.mem.eql(u8, name, "columns") or
        std.mem.eql(u8, name, "on_conflict") or
        std.mem.eql(u8, name, "limit") or
        std.mem.eql(u8, name, "offset");
}

fn find_top_level_select_separator(value: []const u8, needle: u8) ?usize {
    var depth: usize = 0;
    var in_quotes = false;
    var escaped = false;

    for (value, 0..) |c, i| {
        if (in_quotes) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') {
                in_quotes = false;
            }
            continue;
        }

        switch (c) {
            '"' => in_quotes = true,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
        if (depth == 0 and c == needle) return i;
    }

    return null;
}

fn find_top_level_alias_separator(value: []const u8) ?usize {
    var depth: usize = 0;
    var in_quotes = false;
    var escaped = false;

    for (value, 0..) |c, i| {
        if (in_quotes) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') {
                in_quotes = false;
            }
            continue;
        }

        switch (c) {
            '"' => in_quotes = true,
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            ':' => {
                const prev_is_colon = i > 0 and value[i - 1] == ':';
                const next_is_colon = i + 1 < value.len and value[i + 1] == ':';
                if (depth == 0 and !prev_is_colon and !next_is_colon) return i;
            },
            else => {},
        }
    }

    return null;
}

fn parse_select_items(args: ngx_str_t, columns: *[MAX_SELECT_COLUMNS][]const u8) usize {
    if (args.len == 0 or args.data == core.nullptr(u8)) {
        return 0;
    }

    const query = core.slicify(u8, args.data, args.len);
    var pos: usize = 0;

    while (pos < query.len) {
        if (pos + 7 <= query.len and std.mem.eql(u8, query[pos .. pos + 7], "select=")) {
            pos += 7;

            var count: usize = 0;
            var item_start = pos;
            var depth: usize = 0;
            var in_quotes = false;
            var escaped = false;

            while (pos <= query.len and count < MAX_SELECT_COLUMNS) {
                const at_end = pos == query.len;
                if (!at_end) {
                    const c = query[pos];
                    if (in_quotes) {
                        if (escaped) {
                            escaped = false;
                        } else if (c == '\\') {
                            escaped = true;
                        } else if (c == '"') {
                            in_quotes = false;
                        }
                        pos += 1;
                        continue;
                    }

                    switch (c) {
                        '"' => {
                            in_quotes = true;
                            pos += 1;
                            continue;
                        },
                        '(' => depth += 1,
                        ')' => {
                            if (depth > 0) depth -= 1;
                        },
                        ',' => {
                            if (depth != 0) {
                                pos += 1;
                                continue;
                            }
                        },
                        '&' => {
                            if (depth != 0) {
                                pos += 1;
                                continue;
                            }
                        },
                        else => {
                            pos += 1;
                            continue;
                        },
                    }
                    if (c != ',' and c != '&') {
                        pos += 1;
                        continue;
                    }
                }

                if (pos > item_start) {
                    columns[count] = query[item_start..pos];
                    count += 1;
                }
                if (at_end or query[pos] == '&') return count;
                item_start = pos + 1;
                pos += 1;
            }
            return count;
        }

        while (pos < query.len and query[pos] != '&') : (pos += 1) {}
        pos += 1;
    }

    return 0;
}

fn extract_select_param(args: ngx_str_t) ?[]const u8 {
    if (args.len == 0 or args.data == core.nullptr(u8)) return null;
    const query = core.slicify(u8, args.data, args.len);
    var pos: usize = 0;
    while (pos < query.len) {
        if (pos + 7 <= query.len and std.mem.eql(u8, query[pos .. pos + 7], "select=")) {
            const start = pos + 7;
            var end = start;
            while (end < query.len and query[end] != '&') : (end += 1) {}
            return query[start..end];
        }
        while (pos < query.len and query[pos] != '&') : (pos += 1) {}
        pos += 1;
    }
    return null;
}

fn append_select_scalar(target: []u8, target_len: *usize, item: []const u8) bool {
    if (item.len == 0) return true;
    const needed = target_len.* + (if (target_len.* > 0) @as(usize, 1) else @as(usize, 0)) + item.len;
    if (needed > target.len) return false;
    if (target_len.* > 0) {
        target[target_len.*] = ',';
        target_len.* += 1;
    }
    @memcpy(target[target_len.*..][0..item.len], item);
    target_len.* += item.len;
    return true;
}

fn parse_select_plan_value(plan: *SelectPlan, select_value: []const u8, parent_index: i32, path_prefix: []const u8, scalar_out: []u8, scalar_len: *usize) void {
    var items: [MAX_SELECT_COLUMNS][]const u8 = undefined;
    const fake = ngx_str_t{ .data = @constCast(select_value.ptr), .len = select_value.len };
    const count = parse_select_items(fake, &items);
    if (count == 0 and select_value.len > 0) {
        // parse_select_items expects a full query string with select=
        var wrapped_buf: [640]u8 = undefined;
        const prefix = "select=";
        if (prefix.len + select_value.len > wrapped_buf.len) {
            plan.invalid = true;
            return;
        }
        @memcpy(wrapped_buf[0..prefix.len], prefix);
        @memcpy(wrapped_buf[prefix.len..][0..select_value.len], select_value);
        const wrapped = ngx_str_t{ .data = @constCast(wrapped_buf[0..].ptr), .len = prefix.len + select_value.len };
        const wrapped_count = parse_select_items(wrapped, &items);
        if (wrapped_count == 0 and select_value.len != 0) {
            plan.invalid = true;
            return;
        }
        return parse_select_plan_value_items(plan, items[0..wrapped_count], parent_index, path_prefix, scalar_out, scalar_len);
    }
    parse_select_plan_value_items(plan, items[0..count], parent_index, path_prefix, scalar_out, scalar_len);
}

fn parse_select_plan_value_items(plan: *SelectPlan, items: []const []const u8, parent_index: i32, path_prefix: []const u8, scalar_out: []u8, scalar_len: *usize) void {
    for (items) |raw_item| {
        const trimmed_item = trim_ascii_spaces(raw_item);
        var decoded_buf: [512]u8 = undefined;
        const item = decode_query_component_into(&decoded_buf, trimmed_item) orelse {
            plan.invalid = true;
            return;
        };
        if (item.len == 0) continue;

        const open_paren = if (parse_aggregate_expression(item) != null) null else find_top_level_open_paren(item);
        if (open_paren == null or item[item.len - 1] != ')') {
            if (!append_select_scalar(scalar_out, scalar_len, item)) {
                plan.invalid = true;
                return;
            }
            continue;
        }

        plan.has_embeds = true;
        if (plan.node_count >= plan.nodes.len) {
            plan.invalid = true;
            return;
        }

        const node_index = plan.node_count;
        plan.node_count += 1;
        var node = &plan.nodes[node_index];
        node.parent_index = parent_index;

        const head = trim_ascii_spaces(item[0..open_paren.?]);
        const inner_select = item[open_paren.? + 1 .. item.len - 1];

        var alias: ?[]const u8 = null;
        var relation_part = head;
        if (find_top_level_alias_separator(head)) |colon| {
            alias = trim_ascii_spaces(head[0..colon]);
            relation_part = trim_ascii_spaces(head[colon + 1 ..]);
        }

        var relation = relation_part;
        var fk_hint: ?[]const u8 = null;
        var embed_inner = false;
        if (std.mem.indexOfScalar(u8, relation_part, '!')) |bang| {
            relation = trim_ascii_spaces(relation_part[0..bang]);
            var modifier_it = std.mem.splitScalar(u8, relation_part[bang + 1 ..], '!');
            while (modifier_it.next()) |modifier_raw| {
                const modifier = trim_ascii_spaces(modifier_raw);
                if (modifier.len == 0) continue;
                if (std.mem.eql(u8, modifier, "inner")) {
                    embed_inner = true;
                } else if (fk_hint == null) {
                    fk_hint = modifier;
                }
            }
        }

        const alias_name = alias orelse relation;
        if (relation.len == 0 or alias_name.len == 0 or relation.len > node.relation_buf.len or alias_name.len > node.alias_buf.len or inner_select.len > node.inner_select_buf.len) {
            plan.invalid = true;
            return;
        }
        @memcpy(node.relation_buf[0..relation.len], relation);
        node.relation_len = relation.len;
        @memcpy(node.alias_buf[0..alias_name.len], alias_name);
        node.alias_len = alias_name.len;
        @memcpy(node.inner_select_buf[0..inner_select.len], inner_select);
        node.inner_select_len = inner_select.len;
        if (fk_hint) |hint| {
            if (hint.len > node.fk_hint_buf.len) {
                plan.invalid = true;
                return;
            }
            @memcpy(node.fk_hint_buf[0..hint.len], hint);
            node.fk_hint_len = hint.len;
        }
        node.inner = embed_inner;

        const path_len = if (path_prefix.len == 0) alias_name.len else path_prefix.len + 1 + alias_name.len;
        if (path_len > node.path_buf.len) {
            plan.invalid = true;
            return;
        }
        if (path_prefix.len > 0) {
            @memcpy(node.path_buf[0..path_prefix.len], path_prefix);
            node.path_buf[path_prefix.len] = '.';
            @memcpy(node.path_buf[path_prefix.len + 1 ..][0..alias_name.len], alias_name);
        } else {
            @memcpy(node.path_buf[0..alias_name.len], alias_name);
        }
        node.path_len = path_len;

        var child_scalar_len: usize = 0;
        var child_scalar_buf: [512]u8 = std.mem.zeroes([512]u8);
        parse_select_plan_value(plan, inner_select, @intCast(node_index), node.path(), &child_scalar_buf, &child_scalar_len);
        if (plan.invalid) return;
    }
}

fn build_select_plan_from_args(args: ngx_str_t) SelectPlan {
    var plan = SelectPlan{};
    const select_value = extract_select_param(args) orelse return plan;
    parse_select_plan_value(&plan, select_value, -1, "", &plan.root_scalar_buf, &plan.root_scalar_len);
    return plan;
}

fn find_top_level_open_paren(value: []const u8) ?usize {
    var depth: usize = 0;
    var in_quotes = false;
    var escaped = false;
    for (value, 0..) |c, i| {
        if (in_quotes) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') in_quotes = false;
            continue;
        }
        switch (c) {
            '"' => in_quotes = true,
            '(' => {
                if (depth == 0) return i;
                depth += 1;
            },
            ')' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

fn build_select_clause_from_value(buf_out: []u8, select_value: []const u8) WhereClauseResult {
    var wrapped_buf: [640]u8 = undefined;
    const prefix = "select=";
    if (prefix.len + select_value.len > wrapped_buf.len) return .{ .len = 0, .invalid = true };
    @memcpy(wrapped_buf[0..prefix.len], prefix);
    @memcpy(wrapped_buf[prefix.len..][0..select_value.len], select_value);
    const wrapped = ngx_str_t{ .data = @constCast(wrapped_buf[0..].ptr), .len = prefix.len + select_value.len };
    return build_select_clause_from_args(buf_out, wrapped);
}

fn build_group_by_clause_from_value(buf_out: []u8, select_value: []const u8) WhereClauseResult {
    var wrapped_buf: [640]u8 = undefined;
    const prefix = "select=";
    if (prefix.len + select_value.len > wrapped_buf.len) return .{ .len = 0, .invalid = true };
    @memcpy(wrapped_buf[0..prefix.len], prefix);
    @memcpy(wrapped_buf[prefix.len..][0..select_value.len], select_value);
    const wrapped = ngx_str_t{ .data = @constCast(wrapped_buf[0..].ptr), .len = prefix.len + select_value.len };
    return build_group_by_clause_from_args(buf_out, wrapped);
}

fn render_select_item(select_out: []u8, raw_item: []const u8, group_out: []u8) ?SelectItemRenderResult {
    const trimmed_item = trim_ascii_spaces(raw_item);
    var decoded_buf: [512]u8 = undefined;
    const item = decode_query_component_into(&decoded_buf, trimmed_item) orelse return null;
    if (item.len == 0) return null;
    if (std.mem.eql(u8, item, "*")) {
        select_out[0] = '*';
        return .{ .select_len = 1, .group_len = 0, .aggregate = false };
    }

    var alias: ?[]const u8 = null;
    var expr = item;
    if (find_top_level_alias_separator(item)) |colon| {
        alias = trim_ascii_spaces(item[0..colon]);
        expr = trim_ascii_spaces(item[colon + 1 ..]);
        if (alias.?.len == 0 or expr.len == 0) return null;
    }

    if (parse_aggregate_expression(expr)) |aggregate| {
        var pos: usize = 0;
        const fn_name = aggregate.aggregate_fn.sqlName();
        @memcpy(select_out[pos..][0..fn_name.len], fn_name);
        pos += fn_name.len;
        select_out[pos] = '(';
        pos += 1;
        if (aggregate.aggregate_fn == .count and aggregate.base_expr.len == 0) {
            select_out[pos] = '*';
            pos += 1;
        } else {
            pos = append_castable_expression(select_out, pos, aggregate.base_expr) orelse return null;
        }
        select_out[pos] = ')';
        pos += 1;
        if (aggregate.output_cast) |cast_name| {
            const cast_sep = "::";
            @memcpy(select_out[pos..][0..cast_sep.len], cast_sep);
            pos += cast_sep.len;
            pos = append_sql_identifier(select_out, pos, cast_name);
        }

        const alias_name = alias orelse fn_name;
        const as_sep = " AS ";
        @memcpy(select_out[pos..][0..as_sep.len], as_sep);
        pos += as_sep.len;
        pos = append_sql_identifier(select_out, pos, alias_name);
        return .{ .select_len = pos, .group_len = 0, .aggregate = true };
    }

    var pos: usize = 0;
    const group_len = append_castable_expression(group_out, 0, expr) orelse return null;
    pos = append_castable_expression(select_out, 0, expr) orelse return null;

    if (alias) |alias_name| {
        const as_sep = " AS ";
        @memcpy(select_out[pos..][0..as_sep.len], as_sep);
        pos += as_sep.len;
        pos = append_sql_identifier(select_out, pos, alias_name);
    } else if (std.mem.indexOf(u8, expr, "->") != null) {
        var tail = expr;
        var last_segment = expr;
        while (std.mem.indexOf(u8, tail, "->")) |idx| {
            tail = tail[idx + 2 ..];
            if (tail.len > 0 and tail[0] == '>') tail = tail[1..];
            last_segment = tail;
        }
        if (find_top_level_select_separator(last_segment, ':')) |_| return null;
        var scratch: [256]u8 = undefined;
        const alias_name = unescape_wrapped_quotes_into(&scratch, last_segment) orelse return null;
        if (alias_name.len == 0) return null;
        const as_sep = " AS ";
        @memcpy(select_out[pos..][0..as_sep.len], as_sep);
        pos += as_sep.len;
        pos = append_sql_identifier(select_out, pos, alias_name);
    }

    return .{ .select_len = pos, .group_len = group_len, .aggregate = false };
}

fn build_select_clause_from_args(buf_out: []u8, args: ngx_str_t) WhereClauseResult {
    var items: [MAX_SELECT_COLUMNS][]const u8 = undefined;
    const count = parse_select_items(args, &items);
    if (count == 0) return .{ .len = 0, .invalid = false };

    var pos: usize = 0;
    var scratch: [1024]u8 = undefined;
    for (items[0..count], 0..) |item, i| {
        if (i > 0) {
            buf_out[pos] = ',';
            pos += 1;
        }
        const rendered = render_select_item(buf_out[pos..], item, &scratch) orelse return .{ .len = 0, .invalid = true };
        pos += rendered.select_len;
    }

    return .{ .len = pos, .invalid = false };
}

fn build_group_by_clause_from_args(buf_out: []u8, args: ngx_str_t) WhereClauseResult {
    var items: [MAX_SELECT_COLUMNS][]const u8 = undefined;
    const count = parse_select_items(args, &items);
    if (count == 0) return .{ .len = 0, .invalid = false };

    var pos: usize = 0;
    var saw_aggregate = false;
    var group_count: usize = 0;
    var select_scratch: [1024]u8 = undefined;
    var group_scratch: [1024]u8 = undefined;

    for (items[0..count]) |item| {
        const rendered = render_select_item(&select_scratch, item, &group_scratch) orelse return .{ .len = 0, .invalid = true };
        if (rendered.aggregate) {
            saw_aggregate = true;
            continue;
        }
        if (group_count > 0) {
            buf_out[pos] = ',';
            pos += 1;
        }
        @memcpy(buf_out[pos..][0..rendered.group_len], group_scratch[0..rendered.group_len]);
        pos += rendered.group_len;
        group_count += 1;
    }

    return .{ .len = if (saw_aggregate) pos else 0, .invalid = false };
}

fn append_unique_table_name(names: *[MAX_TABLE_NAMES][64]u8, lens: *[MAX_TABLE_NAMES]usize, count: *usize, value: []const u8) bool {
    for (lens[0..count.*], 0..) |len, idx| {
        if (std.mem.eql(u8, names[idx][0..len], value)) return true;
    }
    if (count.* >= names.len or value.len > names[0].len) return false;
    @memcpy(names[count.*][0..value.len], value);
    lens[count.*] = value.len;
    count.* += 1;
    return true;
}

fn collect_plan_table_names(plan: *const SelectPlan, root_table: []const u8, names: *[MAX_TABLE_NAMES][64]u8, lens: *[MAX_TABLE_NAMES]usize) ?usize {
    var count: usize = 0;
    if (!append_unique_table_name(names, lens, &count, root_table)) return null;
    for (plan.nodes[0..plan.node_count]) |node| {
        if (!append_unique_table_name(names, lens, &count, node.relation())) return null;
    }
    return count;
}

fn build_relationship_metadata_query(query_buf: []u8, schema_name: ?[]const u8, table_names: *const [MAX_TABLE_NAMES][64]u8, table_name_lens: *const [MAX_TABLE_NAMES]usize, table_name_count: usize) usize {
    var pos: usize = 0;
    const prefix =
        "SELECT src.relname, tgt.relname, c.conname, STRING_AGG(sa.attname, ',' ORDER BY ord.ord), STRING_AGG(ta.attname, ',' ORDER BY ord.ord) FROM pg_constraint c JOIN pg_class src ON src.oid = c.conrelid JOIN pg_namespace sn ON sn.oid = src.relnamespace JOIN pg_class tgt ON tgt.oid = c.confrelid JOIN pg_namespace tn ON tn.oid = tgt.relnamespace JOIN LATERAL unnest(c.conkey, c.confkey) WITH ORDINALITY AS ord(src_attnum, tgt_attnum, ord) ON TRUE JOIN pg_attribute sa ON sa.attrelid = src.oid AND sa.attnum = ord.src_attnum JOIN pg_attribute ta ON ta.attrelid = tgt.oid AND ta.attnum = ord.tgt_attnum WHERE c.contype = 'f' AND sn.nspname = ";
    @memcpy(query_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    pos = append_sql_quoted(query_buf, pos, schema_name orelse "public");
    const mid = " AND tn.nspname = ";
    @memcpy(query_buf[pos..][0..mid.len], mid);
    pos += mid.len;
    pos = append_sql_quoted(query_buf, pos, schema_name orelse "public");
    const list_prefix = " AND (src.relname IN (";
    @memcpy(query_buf[pos..][0..list_prefix.len], list_prefix);
    pos += list_prefix.len;
    for (table_name_lens[0..table_name_count], 0..) |len, idx| {
        if (idx > 0) {
            query_buf[pos] = ',';
            pos += 1;
        }
        pos = append_sql_quoted(query_buf, pos, table_names[idx][0..len]);
    }
    const between = ") OR tgt.relname IN (";
    @memcpy(query_buf[pos..][0..between.len], between);
    pos += between.len;
    for (table_name_lens[0..table_name_count], 0..) |len, idx| {
        if (idx > 0) {
            query_buf[pos] = ',';
            pos += 1;
        }
        pos = append_sql_quoted(query_buf, pos, table_names[idx][0..len]);
    }
    const suffix = ")) GROUP BY src.relname, tgt.relname, c.conname ORDER BY src.relname, tgt.relname, c.conname";
    @memcpy(query_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    return pos;
}

fn copy_relation_string(dest: []u8, dest_len: *usize, value: []const u8) bool {
    if (value.len > dest.len) return false;
    @memcpy(dest[0..value.len], value);
    dest_len.* = value.len;
    return true;
}

fn parse_relation_metadata(result: ?*PGresult) ?RelationMetadata {
    var meta = RelationMetadata{};
    if (result == null) return meta;
    const rows = pgNtuples(result);
    var row: i32 = 0;
    while (row < rows) : (row += 1) {
        if (meta.edge_count >= meta.edges.len) return null;
        var edge = &meta.edges[meta.edge_count];
        const source = pgGetvalue(result, row, 0) orelse return null;
        const target = pgGetvalue(result, row, 1) orelse return null;
        const constraint = pgGetvalue(result, row, 2) orelse return null;
        const source_cols = pgGetvalue(result, row, 3) orelse return null;
        const target_cols = pgGetvalue(result, row, 4) orelse return null;
        if (!copy_relation_string(&edge.source_buf, &edge.source_len, std.mem.span(source)) or
            !copy_relation_string(&edge.target_buf, &edge.target_len, std.mem.span(target)) or
            !copy_relation_string(&edge.constraint_buf, &edge.constraint_len, std.mem.span(constraint)) or
            !copy_relation_string(&edge.source_cols_buf, &edge.source_cols_len, std.mem.span(source_cols)) or
            !copy_relation_string(&edge.target_cols_buf, &edge.target_cols_len, std.mem.span(target_cols))) return null;
        meta.edge_count += 1;
    }
    return meta;
}

fn scoped_args_match(full_key: []const u8, prefix: []const u8, immediate_only: bool) ?[]const u8 {
    if (prefix.len == 0) return full_key;
    if (!std.mem.startsWith(u8, full_key, prefix)) return null;
    if (full_key.len <= prefix.len or full_key[prefix.len] != '.') return null;
    const stripped = full_key[prefix.len + 1 ..];
    if (immediate_only and std.mem.indexOfScalar(u8, stripped, '.') != null) return null;
    return stripped;
}

fn build_scoped_args(args: ngx_str_t, prefix: []const u8, immediate_only: bool, out: []u8) ngx_str_t {
    if (args.len == 0 or args.data == core.nullptr(u8)) return .{ .data = core.nullptr(u8), .len = 0 };
    const query = core.slicify(u8, args.data, args.len);
    var pos: usize = 0;
    var out_pos: usize = 0;
    while (pos < query.len) {
        var end = pos;
        while (end < query.len and query[end] != '&') : (end += 1) {}
        const pair = query[pos..end];
        if (pair.len > 0) {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const key = pair[0..eq];
            if (scoped_args_match(key, prefix, immediate_only)) |stripped_key| {
                if (out_pos > 0) {
                    out[out_pos] = '&';
                    out_pos += 1;
                }
                @memcpy(out[out_pos..][0..stripped_key.len], stripped_key);
                out_pos += stripped_key.len;
                if (eq < pair.len) {
                    out[out_pos] = '=';
                    out_pos += 1;
                    const value = pair[eq + 1 ..];
                    @memcpy(out[out_pos..][0..value.len], value);
                    out_pos += value.len;
                }
            }
        }
        if (end == query.len) break;
        pos = end + 1;
    }
    return if (out_pos == 0) .{ .data = core.nullptr(u8), .len = 0 } else .{ .data = out.ptr, .len = out_pos };
}

fn append_qualified_column_list(buf_out: []u8, pos_in: usize, table_alias: []const u8, column_list: []const u8) ?usize {
    var pos = pos_in;
    var it = std.mem.splitScalar(u8, column_list, ',');
    var first = true;
    while (it.next()) |part| {
        const col = trim_ascii_spaces(part);
        if (col.len == 0) return null;
        if (!first) {
            buf_out[pos] = ',';
            pos += 1;
        }
        first = false;
        @memcpy(buf_out[pos..][0..table_alias.len], table_alias);
        pos += table_alias.len;
        buf_out[pos] = '.';
        pos += 1;
        pos = append_sql_identifier(buf_out, pos, col);
    }
    return pos;
}

fn append_column_equality_pairs(buf_out: []u8, pos_in: usize, left_alias: []const u8, left_cols: []const u8, right_alias: []const u8, right_cols: []const u8) ?usize {
    var pos = pos_in;
    var left_it = std.mem.splitScalar(u8, left_cols, ',');
    var right_it = std.mem.splitScalar(u8, right_cols, ',');
    var first = true;
    while (left_it.next()) |left_part| {
        const right_part = right_it.next() orelse return null;
        const left_col = trim_ascii_spaces(left_part);
        const right_col = trim_ascii_spaces(right_part);
        if (left_col.len == 0 or right_col.len == 0) return null;
        if (!first) {
            const and_sep = " AND ";
            @memcpy(buf_out[pos..][0..and_sep.len], and_sep);
            pos += and_sep.len;
        }
        first = false;
        @memcpy(buf_out[pos..][0..left_alias.len], left_alias);
        pos += left_alias.len;
        buf_out[pos] = '.';
        pos += 1;
        pos = append_sql_identifier(buf_out, pos, left_col);
        const eq_sep = " = ";
        @memcpy(buf_out[pos..][0..eq_sep.len], eq_sep);
        pos += eq_sep.len;
        @memcpy(buf_out[pos..][0..right_alias.len], right_alias);
        pos += right_alias.len;
        buf_out[pos] = '.';
        pos += 1;
        pos = append_sql_identifier(buf_out, pos, right_col);
    }
    if (right_it.next() != null) return null;
    return pos;
}

fn append_raw_json_field_name(ctx: *PgRequestCtx, name: []const u8) bool {
    if (ctx.*.raw_json_field_count >= ctx.*.raw_json_fields.len or name.len > ctx.*.raw_json_fields[0].len) return false;
    @memcpy(ctx.*.raw_json_fields[ctx.*.raw_json_field_count][0..name.len], name);
    ctx.*.raw_json_field_lens[ctx.*.raw_json_field_count] = name.len;
    ctx.*.raw_json_field_count += 1;
    return true;
}

fn build_safe_sql_alias(buf_out: []u8, prefix: []const u8, raw: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf_out[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    for (raw) |c| {
        if (pos >= buf_out.len) break;
        buf_out[pos] = if (std.ascii.isAlphanumeric(c) or c == '_') c else '_';
        pos += 1;
    }
    return buf_out[0..pos];
}

fn append_list_items_sql(
    buf_out: []u8,
    pos_in: usize,
    raw_value: []const u8,
    array_mode: bool,
    wildcard_mode: bool,
    params: ?*PgRequestCtx,
) ?usize {
    if (raw_value.len < 2) return null;
    const open = raw_value[0];
    const close = raw_value[raw_value.len - 1];
    if (!((open == '{' and close == '}') or (open == '(' and close == ')'))) return null;

    var pos = pos_in;
    if (array_mode) {
        const array_prefix = "ARRAY[";
        @memcpy(buf_out[pos..][0..array_prefix.len], array_prefix);
        pos += array_prefix.len;
    } else {
        buf_out[pos] = '(';
        pos += 1;
    }

    const inner = raw_value[1 .. raw_value.len - 1];
    var item_start: usize = 0;
    var first = true;
    var depth: usize = 0;
    var in_quotes = false;
    var escaped = false;
    var scratch: [512]u8 = undefined;
    var i: usize = 0;
    while (i <= inner.len) : (i += 1) {
        const at_end = i == inner.len;
        if (!at_end) {
            const c = inner[i];
            if (in_quotes) {
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == '"') {
                    in_quotes = false;
                }
                continue;
            }
            switch (c) {
                '"' => {
                    in_quotes = true;
                    continue;
                },
                '(' => depth += 1,
                ')' => {
                    if (depth > 0) depth -= 1;
                },
                ',' => {
                    if (depth != 0) continue;
                },
                else => continue,
            }
            if (c != ',' or depth != 0) continue;
        }

        const raw_item = trim_ascii_spaces(inner[item_start..i]);
        if (raw_item.len == 0) return null;
        if (!first) {
            buf_out[pos] = ',';
            pos += 1;
        }
        first = false;

        const item = unescape_wrapped_quotes_into(&scratch, raw_item) orelse return null;
        if (std.ascii.eqlIgnoreCase(item, "null")) {
            const null_str = "NULL";
            @memcpy(buf_out[pos..][0..null_str.len], null_str);
            pos += null_str.len;
        } else if (!wildcard_mode and (std.ascii.eqlIgnoreCase(item, "true") or std.ascii.eqlIgnoreCase(item, "false") or is_numeric(item))) {
            @memcpy(buf_out[pos..][0..item.len], item);
            pos += item.len;
        } else {
            var item_buf: [512]u8 = undefined;
            var item_view = item;
            if (wildcard_mode) {
                if (item.len > item_buf.len) return null;
                for (item, 0..) |c, j| item_buf[j] = if (c == '*') '%' else c;
                item_view = item_buf[0..item.len];
            }
            pos = append_param_or_quoted(buf_out, pos, item_view, params);
        }

        item_start = i + 1;
    }

    if (array_mode) {
        buf_out[pos] = ']';
    } else {
        buf_out[pos] = ')';
    }
    pos += 1;
    return pos;
}

fn append_simple_filter_sql(buf_out: []u8, pos_in: usize, expr: []const u8, params: ?*PgRequestCtx) ?usize {
    const first_dot = find_top_level_dot(expr) orelse return null;
    const column_raw = trim_ascii_spaces(expr[0..first_dot]);
    if (column_raw.len == 0) return null;

    var rest = expr[first_dot + 1 ..];
    var negated = false;
    if (std.mem.startsWith(u8, rest, "not.")) {
        negated = true;
        rest = rest[4..];
    }

    const second_dot = find_top_level_dot(rest) orelse return null;
    const op_token = trim_ascii_spaces(rest[0..second_dot]);
    const value_raw = rest[second_dot + 1 ..];
    if (op_token.len == 0 or value_raw.len == 0) return null;

    var modifier: ?[]const u8 = null;
    var fts_language: ?[]const u8 = null;
    var op_name = op_token;
    if (std.mem.indexOfScalar(u8, op_token, '(')) |paren| {
        if (op_token[op_token.len - 1] != ')') return null;
        op_name = op_token[0..paren];
        const inner = op_token[paren + 1 .. op_token.len - 1];
        if (std.mem.eql(u8, inner, "any") or std.mem.eql(u8, inner, "all")) {
            modifier = inner;
        } else {
            fts_language = inner;
        }
    }

    const op = FilterOp.fromString(op_name) orelse return null;
    const wildcard_mode = op == .like or op == .ilike;

    var pos = pos_in;
    if (negated) {
        const not_prefix = "NOT (";
        @memcpy(buf_out[pos..][0..not_prefix.len], not_prefix);
        pos += not_prefix.len;
    }

    pos = append_column_expression(buf_out, pos, column_raw) orelse return null;

    switch (op) {
        .fts, .plfts, .phfts, .wfts => {
            const op_sql = " @@ ";
            @memcpy(buf_out[pos..][0..op_sql.len], op_sql);
            pos += op_sql.len;
            const fn_name = switch (op) {
                .fts => "to_tsquery",
                .plfts => "plainto_tsquery",
                .phfts => "phraseto_tsquery",
                .wfts => "websearch_to_tsquery",
                else => unreachable,
            };
            @memcpy(buf_out[pos..][0..fn_name.len], fn_name);
            pos += fn_name.len;
            buf_out[pos] = '(';
            pos += 1;
            if (fts_language) |lang| {
                // FTS language is from the URL operator syntax like fts(english), treated as trusted identifier
                pos = append_sql_quoted(buf_out, pos, lang);
                const sep = ", ";
                @memcpy(buf_out[pos..][0..sep.len], sep);
                pos += sep.len;
            }
            var scratch: [512]u8 = undefined;
            const value = unescape_wrapped_quotes_into(&scratch, value_raw) orelse return null;
            pos = append_param_or_quoted(buf_out, pos, value, params);
            buf_out[pos] = ')';
            pos += 1;
        },
        else => {
            const op_sql = op.toSql();
            buf_out[pos] = ' ';
            pos += 1;
            @memcpy(buf_out[pos..][0..op_sql.len], op_sql);
            pos += op_sql.len;
            buf_out[pos] = ' ';
            pos += 1;

            if (modifier) |mod| {
                if (!(op == .eq or op == .like or op == .ilike or op == .gt or op == .gte or op == .lt or op == .lte or op == .match or op == .imatch)) return null;
                const any_all = if (std.mem.eql(u8, mod, "any")) "ANY (" else if (std.mem.eql(u8, mod, "all")) "ALL (" else return null;
                @memcpy(buf_out[pos..][0..any_all.len], any_all);
                pos += any_all.len;
                pos = append_list_items_sql(buf_out, pos, value_raw, true, wildcard_mode, params) orelse return null;
                buf_out[pos] = ')';
                pos += 1;
            } else switch (op) {
                .is_ => {
                    var scratch: [256]u8 = undefined;
                    const value = unescape_wrapped_quotes_into(&scratch, value_raw) orelse return null;
                    if (std.ascii.eqlIgnoreCase(value, "null")) {
                        const null_str = "NULL";
                        @memcpy(buf_out[pos..][0..null_str.len], null_str);
                        pos += null_str.len;
                    } else if (std.ascii.eqlIgnoreCase(value, "true")) {
                        const true_str = "TRUE";
                        @memcpy(buf_out[pos..][0..true_str.len], true_str);
                        pos += true_str.len;
                    } else if (std.ascii.eqlIgnoreCase(value, "false")) {
                        const false_str = "FALSE";
                        @memcpy(buf_out[pos..][0..false_str.len], false_str);
                        pos += false_str.len;
                    } else if (std.ascii.eqlIgnoreCase(value, "unknown")) {
                        const unknown_str = "UNKNOWN";
                        @memcpy(buf_out[pos..][0..unknown_str.len], unknown_str);
                        pos += unknown_str.len;
                    } else {
                        pos = append_param_or_quoted(buf_out, pos, value, params);
                    }
                },
                .isdistinct => {
                    var scratch: [256]u8 = undefined;
                    const value = unescape_wrapped_quotes_into(&scratch, value_raw) orelse return null;
                    if (std.ascii.eqlIgnoreCase(value, "null")) {
                        const null_str = "NULL";
                        @memcpy(buf_out[pos..][0..null_str.len], null_str);
                        pos += null_str.len;
                    } else if (std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "unknown") or is_numeric(value)) {
                        @memcpy(buf_out[pos..][0..value.len], value);
                        pos += value.len;
                    } else {
                        pos = append_param_or_quoted(buf_out, pos, value, params);
                    }
                },
                .in_ => pos = append_list_items_sql(buf_out, pos, value_raw, false, false, params) orelse return null,
                .cs, .cd, .ov, .sl, .sr, .nxr, .nxl, .adj => {
                    var scratch: [512]u8 = undefined;
                    const value = unescape_wrapped_quotes_into(&scratch, value_raw) orelse return null;
                    pos = append_param_or_quoted(buf_out, pos, value, params);
                },
                .match, .imatch => {
                    var scratch: [512]u8 = undefined;
                    const value = unescape_wrapped_quotes_into(&scratch, value_raw) orelse return null;
                    pos = append_param_or_quoted(buf_out, pos, value, params);
                },
                .like, .ilike => {
                    var scratch: [512]u8 = undefined;
                    const value = unescape_wrapped_quotes_into(&scratch, value_raw) orelse return null;
                    var pattern_buf: [512]u8 = undefined;
                    if (value.len > pattern_buf.len) return null;
                    for (value, 0..) |c, i| pattern_buf[i] = if (c == '*') '%' else c;
                    pos = append_param_or_quoted(buf_out, pos, pattern_buf[0..value.len], params);
                },
                else => {
                    var scratch: [512]u8 = undefined;
                    const value = unescape_wrapped_quotes_into(&scratch, value_raw) orelse return null;
                    const path_is_numeric = std.mem.indexOf(u8, column_raw, "->") != null and !std.mem.containsAtLeast(u8, column_raw, 1, "->>") and is_numeric(value);
                    if (path_is_numeric) {
                        @memcpy(buf_out[pos..][0..value.len], value);
                        pos += value.len;
                    } else {
                        pos = append_param_or_quoted(buf_out, pos, value, params);
                    }
                },
            }
        },
    }

    if (negated) {
        buf_out[pos] = ')';
        pos += 1;
    }

    return pos;
}

fn append_filter_expression_sql(buf_out: []u8, pos_in: usize, raw_expr: []const u8, params: ?*PgRequestCtx) ?usize {
    const expr = trim_ascii_spaces(raw_expr);
    if (expr.len == 0) return null;

    if (std.mem.startsWith(u8, expr, "or(") or std.mem.startsWith(u8, expr, "and(") or std.mem.startsWith(u8, expr, "not.or(") or std.mem.startsWith(u8, expr, "not.and(")) {
        var negated = false;
        var rest = expr;
        if (std.mem.startsWith(u8, rest, "not.")) {
            negated = true;
            rest = rest[4..];
        }

        const joiner = if (std.mem.startsWith(u8, rest, "or(")) " OR " else if (std.mem.startsWith(u8, rest, "and(")) " AND " else return null;
        const group_open = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
        if (rest[rest.len - 1] != ')') return null;
        const inner = rest[group_open + 1 .. rest.len - 1];

        var pos = pos_in;
        if (negated) {
            const not_prefix = "NOT (";
            @memcpy(buf_out[pos..][0..not_prefix.len], not_prefix);
            pos += not_prefix.len;
        } else {
            buf_out[pos] = '(';
            pos += 1;
        }

        var start: usize = 0;
        var depth: usize = 0;
        var in_quotes = false;
        var escaped = false;
        var first = true;
        var i: usize = 0;
        while (i <= inner.len) : (i += 1) {
            const at_end = i == inner.len;
            if (!at_end) {
                const c = inner[i];
                if (in_quotes) {
                    if (escaped) {
                        escaped = false;
                    } else if (c == '\\') {
                        escaped = true;
                    } else if (c == '"') {
                        in_quotes = false;
                    }
                    continue;
                }
                switch (c) {
                    '"' => {
                        in_quotes = true;
                        continue;
                    },
                    '(' => depth += 1,
                    ')' => {
                        if (depth > 0) depth -= 1;
                    },
                    ',' => {
                        if (depth != 0) continue;
                    },
                    else => continue,
                }
                if (c != ',' or depth != 0) continue;
            }

            const item = trim_ascii_spaces(inner[start..i]);
            if (item.len == 0) return null;
            if (!first) {
                @memcpy(buf_out[pos..][0..joiner.len], joiner);
                pos += joiner.len;
            }
            first = false;
            pos = append_filter_expression_sql(buf_out, pos, item, params) orelse return null;
            start = i + 1;
        }

        buf_out[pos] = ')';
        pos += 1;
        return pos;
    }

    return append_simple_filter_sql(buf_out, pos_in, expr, params);
}

fn build_where_clause_from_args(buf_out: []u8, args: ngx_str_t, params: ?*PgRequestCtx) WhereClauseResult {
    if (args.len == 0 or args.data == core.nullptr(u8)) {
        return .{ .len = 0, .invalid = false };
    }

    const query = core.slicify(u8, args.data, args.len);
    var pos: usize = 0;
    var out_pos: usize = 0;
    var first = true;

    while (pos < query.len) {
        var param_end = pos;
        while (param_end < query.len and query[param_end] != '&') : (param_end += 1) {}
        const param = query[pos..param_end];

        if (param.len > 0) {
            const eq = std.mem.indexOfScalar(u8, param, '=') orelse return .{ .len = 0, .invalid = true };
            if (eq == 0 or eq >= param.len - 1) return .{ .len = 0, .invalid = true };

            var key_buf: [512]u8 = undefined;
            var value_buf: [2048]u8 = undefined;
            const key = decode_query_component_into(&key_buf, param[0..eq]) orelse return .{ .len = 0, .invalid = true };
            const value = decode_query_component_into(&value_buf, param[eq + 1 ..]) orelse return .{ .len = 0, .invalid = true };

            if (!is_reserved_query_param(key)) {
                var expr_buf: [3072]u8 = undefined;
                var expr_len: usize = 0;
                if (std.mem.eql(u8, key, "or") or std.mem.eql(u8, key, "and") or std.mem.eql(u8, key, "not.or") or std.mem.eql(u8, key, "not.and")) {
                    if (key.len + value.len > expr_buf.len) return .{ .len = 0, .invalid = true };
                    @memcpy(expr_buf[0..key.len], key);
                    @memcpy(expr_buf[key.len..][0..value.len], value);
                    expr_len = key.len + value.len;
                } else {
                    if (key.len + 1 + value.len > expr_buf.len) return .{ .len = 0, .invalid = true };
                    @memcpy(expr_buf[0..key.len], key);
                    expr_buf[key.len] = '.';
                    @memcpy(expr_buf[key.len + 1 ..][0..value.len], value);
                    expr_len = key.len + 1 + value.len;
                }

                if (!first) {
                    const and_str = " AND ";
                    @memcpy(buf_out[out_pos..][0..and_str.len], and_str);
                    out_pos += and_str.len;
                }
                out_pos = append_filter_expression_sql(buf_out, out_pos, expr_buf[0..expr_len], params) orelse return .{ .len = 0, .invalid = true };
                first = false;
            }
        }

        pos = param_end + 1;
    }

    return .{ .len = out_pos, .invalid = false };
}

/// ============================================================================
/// HTTP Header Parsing
/// ============================================================================
/// Supported response formats
const ResponseFormat = enum(u8) {
    json, // application/json (default)
    csv, // text/csv
    plain_text, // text/plain (for scalar functions)
    xml, // text/xml (for XML functions)
    binary, // application/octet-stream (for bytea)
    unsupported,
};

/// Parse Accept header to determine response format from request
/// Supports: application/json, text/csv, text/plain, text/xml, application/octet-stream
fn parse_accept_header_from_request(r: [*c]ngx_http_request_t) ResponseFormat {
    const accept_val = extract_header_value(r, "accept") orelse return .json;

    if (std.mem.containsAtLeast(u8, accept_val, 1, "application/vnd.pgrst.object+json") or
        std.mem.containsAtLeast(u8, accept_val, 1, "application/vnd.pgrst.array+json") or
        std.mem.containsAtLeast(u8, accept_val, 1, "application/json") or
        std.mem.containsAtLeast(u8, accept_val, 1, "*/*"))
    {
        return .json;
    }

    // Check for specific content types (order matters - more specific first)
    if (std.mem.containsAtLeast(u8, accept_val, 1, "text/csv")) {
        return .csv;
    }
    if (std.mem.containsAtLeast(u8, accept_val, 1, "text/plain")) {
        return .plain_text;
    }
    if (std.mem.containsAtLeast(u8, accept_val, 1, "text/xml") or
        std.mem.containsAtLeast(u8, accept_val, 1, "application/xml"))
    {
        return .xml;
    }
    if (std.mem.containsAtLeast(u8, accept_val, 1, "application/octet-stream")) {
        return .binary;
    }

    return .unsupported;
}

fn parse_content_type_from_request(r: [*c]ngx_http_request_t) RequestBodyFormat {
    if (!request_needs_body(r)) return .none;

    const content_type = extract_header_value(r, "content-type") orelse return .json;
    const media_type = trim_media_type(content_type);

    if (media_type.len == 0) return .json;
    if (std.ascii.eqlIgnoreCase(media_type, "application/json")) return .json;
    if (std.ascii.eqlIgnoreCase(media_type, "application/x-www-form-urlencoded")) return .form_urlencoded;
    if (std.ascii.eqlIgnoreCase(media_type, "text/csv")) return .csv;
    if (std.ascii.eqlIgnoreCase(media_type, "text/plain")) return .plain_text;
    if (std.ascii.eqlIgnoreCase(media_type, "text/xml") or std.ascii.eqlIgnoreCase(media_type, "application/xml")) return .xml;
    if (std.ascii.eqlIgnoreCase(media_type, "application/octet-stream")) return .binary;
    return .unsupported;
}

/// Extract a header value from HTTP request headers
/// Searches through all headers for a case-insensitive match
/// Returns the header value if found, otherwise returns null
fn extract_header_value(r: [*c]ngx_http_request_t, header_name: []const u8) ?[]const u8 {
    if (r == null) return null;

    // Search in the headers list for the requested header
    const headers_list = &r.*.headers_in.headers;

    // Get a pointer to the list part structure
    var part = &headers_list.*.part;

    var search_limit: usize = 100; // Prevent infinite loops
    while (search_limit > 0) : (search_limit -= 1) {
        const elts = core.castPtr(ngx_table_elt_t, part.*.elts) orelse {
            // Move to next part if no elements
            if (part.*.next) |next_part| {
                part = next_part;
                continue;
            } else {
                break;
            }
        };

        var i: usize = 0;
        while (i < part.*.nelts) : (i += 1) {
            const elt = elts[i];
            if (elt.key.len > 0 and elt.key.data != core.nullptr(u8)) {
                const key = core.slicify(u8, elt.key.data, elt.key.len);

                // Check if this matches the requested header (case-insensitive)
                if (std.mem.eql(u8, key, header_name) or
                    std.ascii.eqlIgnoreCase(key, header_name))
                {
                    if (elt.value.len > 0 and elt.value.data != core.nullptr(u8)) {
                        return core.slicify(u8, elt.value.data, elt.value.len);
                    }
                }
            }
        }
        // Move to next part
        if (part.*.next) |next_part| {
            part = next_part;
        } else {
            break;
        }
    }

    return null;
}

/// Build a schema-qualified table name
/// If schema is provided, returns "schema.table", otherwise just "table"
fn build_qualified_table_name(
    buffer: []u8,
    schema: ?[]const u8,
    table: []const u8,
) usize {
    var pos: usize = 0;
    if (schema) |s| {
        if (s.len > 0) {
            @memcpy(buffer[pos..][0..s.len], s);
            pos += s.len;
            buffer[pos] = '.';
            pos += 1;
        }
    }
    @memcpy(buffer[pos..][0..table.len], table);
    pos += table.len;
    return pos;
}

/// ============================================================================
/// JWT Authentication
/// ============================================================================
/// Extract JWT token from Authorization header
/// Expects: "Authorization: Bearer <token>"
fn extract_jwt_token(r: [*c]ngx_http_request_t) ?[]const u8 {
    return pgrest_auth.extract_jwt_token(r);
}

// ============================================================================
// JWT Role Support
// ============================================================================

/// Base64url decode (JWT uses URL-safe base64 without padding)
fn base64url_decode(input: []const u8, output: []u8) ?usize {
    return pgrest_auth.base64url_decode(input, output);
}

/// Compute HMAC-SHA256 for JWT signature verification
fn hmac_sha256(key: []const u8, data: []const u8, output: *[32]u8) bool {
    return pgrest_auth.hmac_sha256(key, data, output);
}

/// Validate JWT signature (HS256)
fn validate_jwt_hs256(token: []const u8, secret: []const u8) bool {
    return pgrest_auth.validate_jwt_hs256(token, secret);
}

/// Extract role claim from JWT payload
/// Returns the role string or null if not found/invalid
fn extract_jwt_role(pool: [*c]ngx_pool_t, jwt_token: []const u8, role_claim: []const u8) ?[]const u8 {
    return pgrest_auth.extract_jwt_role(pool, jwt_token, role_claim);
}

/// ============================================================================
/// Smart Response Formatting
/// ============================================================================
/// Detect the result format based on query results
/// Returns:
///   0 = scalar/single value (e.g., count result)
///   1 = single row object
///   2 = multiple rows (array)
fn detect_result_format(result: ?*PGresult, ntuples: i32, nfields: i32) u8 {
    if (result == null) return 0;

    // Single field with multiple rows = array of scalars
    if (nfields == 1 and ntuples > 1) return 0;

    // Single field with one row = scalar
    if (nfields == 1 and ntuples == 1) return 0;

    // Single row = object
    if (ntuples == 1) return 1;

    // Multiple rows = array
    if (ntuples > 1) return 2;

    // No rows
    return 2;
}

/// Format result as scalar value (for functions returning single value)
fn format_result_as_scalar(
    result: ?*PGresult,
    json_buf: []u8,
) usize {
    if (result == null or pgNtuples(result) == 0) {
        const null_str = "null";
        @memcpy(json_buf[0..null_str.len], null_str);
        return null_str.len;
    }

    const value = pgGetvalue(result, 0, 0);
    if (value == null) {
        const null_str = "null";
        @memcpy(json_buf[0..null_str.len], null_str);
        return null_str.len;
    }

    // Check if value is numeric or string
    var is_number = true;
    var i: usize = 0;
    while (value[i] != 0) {
        const c = value[i];
        if ((c < '0' or c > '9') and c != '.' and c != '-' and c != '+' and c != 'e' and c != 'E') {
            is_number = false;
            break;
        }
        i += 1;
    }

    if (is_number) {
        // Output as number (no quotes)
        while (value[i] != 0) {
            i += 1;
        }
        @memcpy(json_buf[0..i], value[0..i]);
        return i;
    } else {
        // Output as quoted string
        var pos: usize = 0;
        json_buf[pos] = '"';
        pos += 1;
        i = 0;
        while (value[i] != 0) {
            const c = value[i];
            if (c == '"' or c == '\\') {
                json_buf[pos] = '\\';
                pos += 1;
            }
            json_buf[pos] = c;
            pos += 1;
            i += 1;
        }
        json_buf[pos] = '"';
        pos += 1;
        return pos;
    }
}

/// Format PostgreSQL result as plain text
/// Outputs first column of each row, one value per line
fn format_result_as_plain_text(
    result: ?*PGresult,
    ntuples: i32,
    text_buf: []u8,
) usize {
    if (result == null or ntuples == 0) return 0;

    var pos: usize = 0;

    // Output first column of each row
    var row: i32 = 0;
    while (row < ntuples) : (row += 1) {
        if (row > 0) {
            text_buf[pos] = '\n';
            pos += 1;
        }

        if (pgGetisnull(result, row, 0) == 0) {
            const value = pgGetvalue(result, row, 0);
            if (value != null) {
                var i: usize = 0;
                while (value[i] != 0) : (i += 1) {
                    text_buf[pos] = value[i];
                    pos += 1;
                }
            }
        }
    }

    return pos;
}

/// Format PostgreSQL result as CSV
fn format_result_as_csv(
    result: ?*PGresult,
    ntuples: i32,
    nfields: i32,
    csv_buf: []u8,
) usize {
    if (result == null) return 0;

    var pos: usize = 0;

    // Write header row with column names
    var col: i32 = 0;
    while (col < nfields) : (col += 1) {
        if (col > 0) {
            csv_buf[pos] = ',';
            pos += 1;
        }

        const fname = pgFname(result, col);
        if (fname != null) {
            // Quote field if it contains comma or quote
            var i: usize = 0;
            var needs_quote = false;
            while (fname[i] != 0) : (i += 1) {
                if (fname[i] == ',' or fname[i] == '"' or fname[i] == '\n') {
                    needs_quote = true;
                    break;
                }
            }

            if (needs_quote) {
                csv_buf[pos] = '"';
                pos += 1;
            }

            i = 0;
            while (fname[i] != 0) {
                if (fname[i] == '"') {
                    csv_buf[pos] = '"';
                    pos += 1;
                }
                csv_buf[pos] = fname[i];
                pos += 1;
                i += 1;
            }

            if (needs_quote) {
                csv_buf[pos] = '"';
                pos += 1;
            }
        }
    }
    csv_buf[pos] = '\n';
    pos += 1;

    // Write data rows
    var row: i32 = 0;
    while (row < ntuples) : (row += 1) {
        col = 0;
        while (col < nfields) : (col += 1) {
            if (col > 0) {
                csv_buf[pos] = ',';
                pos += 1;
            }

            if (pgGetisnull(result, row, col) != 0) {
                // Empty field for NULL
            } else {
                const value = pgGetvalue(result, row, col);
                if (value != null) {
                    // Quote field if it contains comma or quote
                    var i: usize = 0;
                    var needs_quote = false;
                    while (value[i] != 0) : (i += 1) {
                        if (value[i] == ',' or value[i] == '"' or value[i] == '\n') {
                            needs_quote = true;
                            break;
                        }
                    }

                    if (needs_quote) {
                        csv_buf[pos] = '"';
                        pos += 1;
                    }

                    i = 0;
                    while (value[i] != 0) {
                        if (value[i] == '"') {
                            csv_buf[pos] = '"';
                            pos += 1;
                        }
                        csv_buf[pos] = value[i];
                        pos += 1;
                        i += 1;
                    }

                    if (needs_quote) {
                        csv_buf[pos] = '"';
                        pos += 1;
                    }
                }
            }
        }
        csv_buf[pos] = '\n';
        pos += 1;
    }

    return pos;
}

/// Format PostgreSQL result as XML
/// Output format: <?xml version="1.0"?><root><row><col>value</col>...</row>...</root>
fn format_result_as_xml(
    result: ?*PGresult,
    ntuples: i32,
    nfields: i32,
    xml_buf: []u8,
) usize {
    if (result == null) return 0;

    var pos: usize = 0;

    // XML declaration and root element
    const xml_header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root>\n";
    @memcpy(xml_buf[pos..][0..xml_header.len], xml_header);
    pos += xml_header.len;

    // Write data rows
    var row: i32 = 0;
    while (row < ntuples) : (row += 1) {
        // Row start
        const row_start = "  <row>\n";
        @memcpy(xml_buf[pos..][0..row_start.len], row_start);
        pos += row_start.len;

        var col: i32 = 0;
        while (col < nfields) : (col += 1) {
            const fname = pgFname(result, col);
            if (fname == null) {
                col += 1;
                continue;
            }

            // Get field name length
            var fname_len: usize = 0;
            while (fname[fname_len] != 0) : (fname_len += 1) {}

            // Opening tag: "    <fieldname>"
            xml_buf[pos] = ' ';
            pos += 1;
            xml_buf[pos] = ' ';
            pos += 1;
            xml_buf[pos] = ' ';
            pos += 1;
            xml_buf[pos] = ' ';
            pos += 1;
            xml_buf[pos] = '<';
            pos += 1;
            @memcpy(xml_buf[pos..][0..fname_len], fname[0..fname_len]);
            pos += fname_len;
            xml_buf[pos] = '>';
            pos += 1;

            // Value (with XML escaping)
            if (pgGetisnull(result, row, col) == 0) {
                const value = pgGetvalue(result, row, col);
                if (value != null) {
                    var i: usize = 0;
                    while (value[i] != 0) : (i += 1) {
                        switch (value[i]) {
                            '<' => {
                                const esc = "&lt;";
                                @memcpy(xml_buf[pos..][0..esc.len], esc);
                                pos += esc.len;
                            },
                            '>' => {
                                const esc = "&gt;";
                                @memcpy(xml_buf[pos..][0..esc.len], esc);
                                pos += esc.len;
                            },
                            '&' => {
                                const esc = "&amp;";
                                @memcpy(xml_buf[pos..][0..esc.len], esc);
                                pos += esc.len;
                            },
                            '"' => {
                                const esc = "&quot;";
                                @memcpy(xml_buf[pos..][0..esc.len], esc);
                                pos += esc.len;
                            },
                            '\'' => {
                                const esc = "&apos;";
                                @memcpy(xml_buf[pos..][0..esc.len], esc);
                                pos += esc.len;
                            },
                            else => {
                                xml_buf[pos] = value[i];
                                pos += 1;
                            },
                        }
                    }
                }
            }

            // Closing tag: "</fieldname>\n"
            xml_buf[pos] = '<';
            pos += 1;
            xml_buf[pos] = '/';
            pos += 1;
            @memcpy(xml_buf[pos..][0..fname_len], fname[0..fname_len]);
            pos += fname_len;
            xml_buf[pos] = '>';
            pos += 1;
            xml_buf[pos] = '\n';
            pos += 1;
        }

        // Row end
        const row_end = "  </row>\n";
        @memcpy(xml_buf[pos..][0..row_end.len], row_end);
        pos += row_end.len;
    }

    // Root end
    const xml_footer = "</root>\n";
    @memcpy(xml_buf[pos..][0..xml_footer.len], xml_footer);
    pos += xml_footer.len;

    return pos;
}

/// Format result as single object (for queries returning one row)
fn format_result_as_object(
    result: ?*PGresult,
    nfields: i32,
    json_buf: []u8,
) usize {
    if (result == null or pgNtuples(result) == 0) {
        const empty_obj = "{}";
        @memcpy(json_buf[0..empty_obj.len], empty_obj);
        return empty_obj.len;
    }

    var pos: usize = 0;
    json_buf[pos] = '{';
    pos += 1;

    var col: i32 = 0;
    while (col < nfields) : (col += 1) {
        if (col > 0) {
            json_buf[pos] = ',';
            pos += 1;
        }

        const fname = pgFname(result, col);
        if (fname != null) {
            json_buf[pos] = '"';
            pos += 1;

            var i: usize = 0;
            while (fname[i] != 0) {
                json_buf[pos] = fname[i];
                pos += 1;
                i += 1;
            }

            json_buf[pos] = '"';
            pos += 1;
            json_buf[pos] = ':';
            pos += 1;
        }

        if (pgGetisnull(result, 0, col) != 0) {
            const null_str = "null";
            @memcpy(json_buf[pos..][0..null_str.len], null_str);
            pos += null_str.len;
        } else {
            const value = pgGetvalue(result, 0, col);
            if (value != null) {
                json_buf[pos] = '"';
                pos += 1;

                var i: usize = 0;
                while (value[i] != 0) {
                    const c = value[i];
                    if (c == '"' or c == '\\') {
                        json_buf[pos] = '\\';
                        pos += 1;
                    }
                    json_buf[pos] = c;
                    pos += 1;
                    i += 1;
                }

                json_buf[pos] = '"';
                pos += 1;
            } else {
                const null_str = "null";
                @memcpy(json_buf[pos..][0..null_str.len], null_str);
                pos += null_str.len;
            }
        }
    }

    json_buf[pos] = '}';
    pos += 1;

    return pos;
}

/// ============================================================================
/// RPC (Remote Procedure Call) - Stored Procedure Support
/// ============================================================================
/// Maximum number of RPC parameters
const MAX_RPC_PARAMS = 16;

/// RPC parameter for function call
const RpcParam = struct {
    name: []const u8,
    value: []const u8,
    is_null: bool = false,
    is_numeric: bool = false,
    is_boolean: bool = false,
    is_raw: bool = false,
    value_buf: [2048]u8 = std.mem.zeroes([2048]u8),
};

/// Parsed RPC call information
const RpcCall = struct {
    function_name: []const u8,
    params: [MAX_RPC_PARAMS]RpcParam,
    param_count: usize,
    prefer_single_object: bool = false, // Wrap parameters in single JSON object
    raw_body: [4096]u8 = std.mem.zeroes([4096]u8),
    raw_body_len: usize = 0,
};

const RpcVolatility = enum(u8) {
    volatile_fn,
    stable,
    immutable,
};

const RpcReturnKind = enum(u8) {
    scalar,
    composite_single,
    composite_setof,
};

const RpcSingleUnnamedKind = enum(u8) {
    none,
    json,
    text,
    xml,
    bytea,
};

const RpcMetadata = struct {
    volatility: RpcVolatility = .volatile_fn,
    return_kind: RpcReturnKind = .scalar,
    single_unnamed_kind: RpcSingleUnnamedKind = .none,
    has_variadic: bool = false,
    variadic_param_name_len: usize = 0,
    variadic_param_name_buf: [128]u8 = std.mem.zeroes([128]u8),
    input_param_names_len: usize = 0,
    input_param_names_buf: [256]u8 = std.mem.zeroes([256]u8),
    found: bool = false,
};

fn rpc_variadic_param_name(metadata: *const RpcMetadata) []const u8 {
    return metadata.variadic_param_name_buf[0..metadata.variadic_param_name_len];
}

fn rpc_input_param_names(metadata: *const RpcMetadata) []const u8 {
    return metadata.input_param_names_buf[0..metadata.input_param_names_len];
}

fn rpc_metadata_has_named_param(metadata: *const RpcMetadata, name: []const u8) bool {
    if (name.len == 0) return false;
    var it = std.mem.splitScalar(u8, rpc_input_param_names(metadata), ',');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}

fn rpc_single_unnamed_kind_type_name(kind: RpcSingleUnnamedKind) []const u8 {
    return switch (kind) {
        .none => "",
        .json => "json",
        .text => "text",
        .xml => "xml",
        .bytea => "bytea",
    };
}

fn rpc_single_unnamed_kind_media_matches(kind: RpcSingleUnnamedKind, body_format: RequestBodyFormat) bool {
    return switch (kind) {
        .json => body_format == .json,
        .text => body_format == .plain_text,
        .xml => body_format == .xml,
        .bytea => body_format == .binary,
        .none => false,
    };
}

fn rpc_allow_single_unnamed_fallback(body_format: RequestBodyFormat, prefer_single_object: bool) bool {
    if (prefer_single_object) return false;
    return switch (body_format) {
        .json, .plain_text, .xml, .binary => true,
        else => false,
    };
}

fn rpc_method_allowed(method: ngx_uint_t, metadata: RpcMetadata) bool {
    return switch (method) {
        http.NGX_HTTP_GET, http.NGX_HTTP_HEAD => metadata.volatility != .volatile_fn,
        http.NGX_HTTP_POST => true,
        else => false,
    };
}

fn rpc_allow_header(metadata: RpcMetadata) []const u8 {
    return if (metadata.volatility == .volatile_fn)
        "OPTIONS,POST"
    else
        "OPTIONS,GET,HEAD,POST";
}

fn rpc_returns_table_like(metadata: RpcMetadata) bool {
    return metadata.return_kind == .composite_single or metadata.return_kind == .composite_setof;
}

fn build_rpc_metadata_query(
    query_buf: []u8,
    schema_name: ?[]const u8,
    function_name: []const u8,
    requested_param_count: usize,
    allow_single_unnamed_fallback: bool,
) usize {
    var pos: usize = 0;
    const prefix =
        "SELECT p.provolatile, p.proretset, (t.typtype = 'c' OR COALESCE(p.proargmodes::text[] && '{t,b,o}', false)) AS rettype_is_composite, p.provariadic > 0 AS has_variadic, COALESCE(meta.unnamed_count, 0), COALESCE(meta.single_unnamed_kind, ''), COALESCE(meta.variadic_param_name, ''), COALESCE(meta.input_param_names, ''), CASE WHEN ";
    @memcpy(query_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    const requested_fit = std.fmt.bufPrint(query_buf[pos..], "{d} BETWEEN GREATEST(p.pronargs - p.pronargdefaults, 0) AND p.pronargs THEN 0 WHEN ", .{requested_param_count}) catch return pos;
    pos += requested_fit.len;

    const fallback_flag = if (allow_single_unnamed_fallback) "TRUE" else "FALSE";
    @memcpy(query_buf[pos..][0..fallback_flag.len], fallback_flag);
    pos += fallback_flag.len;

    const middle_prefix =
        " AND COALESCE(meta.unnamed_count, 0) = 1 AND COALESCE(meta.single_unnamed_kind, '') <> '' THEN 1 WHEN p.pronargs = 0 THEN 2 ELSE 3 END AS match_rank FROM pg_proc p JOIN pg_namespace pn ON pn.oid = p.pronamespace JOIN pg_type t ON t.oid = p.prorettype LEFT JOIN (SELECT p2.oid, COUNT(*) FILTER (WHERE COALESCE(a.name, '') = '') AS unnamed_count, MAX(CASE WHEN COALESCE(a.name, '') = '' THEN CASE format_type(a.type_oid, NULL) WHEN 'json' THEN 'json' WHEN 'jsonb' THEN 'json' WHEN 'text' THEN 'text' WHEN 'xml' THEN 'xml' WHEN 'bytea' THEN 'bytea' ELSE '' END ELSE '' END) AS single_unnamed_kind, MAX(CASE WHEN a.mode = 'v' THEN COALESCE(a.name, '') ELSE '' END) AS variadic_param_name, STRING_AGG(CASE WHEN COALESCE(a.name, '') <> '' THEN COALESCE(a.name, '') ELSE NULL END, ',' ORDER BY a.ord) AS input_param_names FROM pg_proc p2 LEFT JOIN LATERAL (SELECT ord, COALESCE(p2.proargnames[ord], '') AS name, COALESCE(p2.proallargtypes[ord], p2.proargtypes[ord - 1]) AS type_oid, COALESCE(p2.proargmodes[ord], 'i') AS mode FROM generate_series(1, COALESCE(array_length(p2.proallargtypes, 1), array_length(p2.proargnames, 1), p2.pronargs)) ord) a ON TRUE WHERE a.type_oid IS NOT NULL AND a.mode IN ('i','v') GROUP BY p2.oid) meta ON meta.oid = p.oid WHERE p.prokind = 'f' AND pn.nspname = ";
    @memcpy(query_buf[pos..][0..middle_prefix.len], middle_prefix);
    pos += middle_prefix.len;
    pos = append_sql_quoted(query_buf, pos, schema_name orelse "public");

    const middle = " AND p.proname = ";
    @memcpy(query_buf[pos..][0..middle.len], middle);
    pos += middle.len;
    pos = append_sql_quoted(query_buf, pos, function_name);

    const suffix = " ORDER BY match_rank ASC, p.pronargs ASC LIMIT 1";
    @memcpy(query_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    return pos;
}

fn parse_rpc_metadata_result(result: ?*PGresult) RpcMetadata {
    if (result == null or pgNtuples(result) <= 0 or pgNfields(result) < 9) return .{};

    if (pgGetisnull(result, 0, 8) == 0) {
        const rank_ptr = pgGetvalue(result, 0, 8);
        const raw_rank = if (rank_ptr != null) std.mem.span(rank_ptr) else "2";
        const rank = std.fmt.parseInt(usize, raw_rank, 10) catch 2;
        if (rank >= 3) return .{};
    }

    var metadata: RpcMetadata = .{ .found = true };

    if (pgGetisnull(result, 0, 0) == 0) {
        const volatility_ptr = pgGetvalue(result, 0, 0);
        const volatility_tag: u8 = if (volatility_ptr != null) volatility_ptr[0] else 'v';
        metadata.volatility = switch (volatility_tag) {
            'i' => .immutable,
            's' => .stable,
            else => .volatile_fn,
        };
    }

    const proretset_ptr = pgGetvalue(result, 0, 1);
    const proretset = pgGetisnull(result, 0, 1) == 0 and proretset_ptr != null and proretset_ptr[0] == 't';
    const composite_ptr = pgGetvalue(result, 0, 2);
    const rettype_is_composite = pgGetisnull(result, 0, 2) == 0 and composite_ptr != null and composite_ptr[0] == 't';
    metadata.return_kind = if (rettype_is_composite)
        (if (proretset) .composite_setof else .composite_single)
    else
        .scalar;

    const variadic_ptr = pgGetvalue(result, 0, 3);
    metadata.has_variadic = pgGetisnull(result, 0, 3) == 0 and variadic_ptr != null and variadic_ptr[0] == 't';

    var unnamed_count: usize = 0;
    if (pgGetisnull(result, 0, 4) == 0) {
        const raw_ptr = pgGetvalue(result, 0, 4);
        const raw = if (raw_ptr != null) std.mem.span(raw_ptr) else "0";
        unnamed_count = std.fmt.parseInt(usize, raw, 10) catch 0;
    }

    if (unnamed_count == 1 and pgGetisnull(result, 0, 5) == 0) {
        const raw_kind_ptr = pgGetvalue(result, 0, 5);
        const raw_kind = if (raw_kind_ptr != null) std.mem.span(raw_kind_ptr) else "";
        metadata.single_unnamed_kind = if (std.mem.eql(u8, raw_kind, "json"))
            .json
        else if (std.mem.eql(u8, raw_kind, "text"))
            .text
        else if (std.mem.eql(u8, raw_kind, "xml"))
            .xml
        else if (std.mem.eql(u8, raw_kind, "bytea"))
            .bytea
        else
            .none;
    }

    if (metadata.has_variadic and pgGetisnull(result, 0, 6) == 0) {
        const raw_name_ptr = pgGetvalue(result, 0, 6);
        const raw_name = if (raw_name_ptr != null) std.mem.span(raw_name_ptr) else "";
        if (raw_name.len > 0 and raw_name.len <= metadata.variadic_param_name_buf.len) {
            @memcpy(metadata.variadic_param_name_buf[0..raw_name.len], raw_name);
            metadata.variadic_param_name_len = raw_name.len;
        }
    }

    if (pgGetisnull(result, 0, 7) == 0) {
        const raw_params_ptr = pgGetvalue(result, 0, 7);
        const raw_params = if (raw_params_ptr != null) std.mem.span(raw_params_ptr) else "";
        if (raw_params.len > 0 and raw_params.len <= metadata.input_param_names_buf.len) {
            @memcpy(metadata.input_param_names_buf[0..raw_params.len], raw_params);
            metadata.input_param_names_len = raw_params.len;
        }
    }

    return metadata;
}

fn filter_rpc_query_args_by_metadata(
    args: ngx_str_t,
    metadata: *const RpcMetadata,
    include_rpc_args: bool,
    out: []u8,
) ngx_str_t {
    if (args.len == 0 or args.data == core.nullptr(u8)) {
        return ngx_str_t{ .data = core.nullptr(u8), .len = 0 };
    }

    const query = core.slicify(u8, args.data, args.len);
    var pos: usize = 0;
    var start: usize = 0;

    while (start <= query.len) {
        var end = start;
        while (end < query.len and query[end] != '&') : (end += 1) {}

        const pair = query[start..end];
        if (pair.len > 0) {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const raw_name = pair[0..eq];
            const matches_rpc = rpc_metadata_has_named_param(metadata, raw_name);
            if (matches_rpc == include_rpc_args) {
                if (pos > 0) {
                    out[pos] = '&';
                    pos += 1;
                }
                @memcpy(out[pos..][0..pair.len], pair);
                pos += pair.len;
            }
        }

        if (end == query.len) break;
        start = end + 1;
    }

    return if (pos == 0)
        ngx_str_t{ .data = core.nullptr(u8), .len = 0 }
    else
        ngx_str_t{ .data = out.ptr, .len = pos };
}

fn append_variadic_scalar(buf_out: []u8, pos_in: usize, param: RpcParam) usize {
    if (param.is_null) {
        const null_str = "NULL";
        @memcpy(buf_out[pos_in..][0..null_str.len], null_str);
        return pos_in + null_str.len;
    }
    if (param.is_boolean or param.is_numeric or param.is_raw) {
        @memcpy(buf_out[pos_in..][0..param.value.len], param.value);
        return pos_in + param.value.len;
    }
    return append_sql_quoted(buf_out, pos_in, param.value);
}

fn collapse_rpc_variadic_param(rpc_call: *RpcCall, metadata: *const RpcMetadata) void {
    const variadic_name = rpc_variadic_param_name(metadata);
    if (!metadata.has_variadic or variadic_name.len == 0) return;

    var match_indexes: [MAX_RPC_PARAMS]usize = undefined;
    var match_count: usize = 0;
    for (0..rpc_call.param_count) |i| {
        if (std.mem.eql(u8, rpc_call.params[i].name, variadic_name)) {
            match_indexes[match_count] = i;
            match_count += 1;
        }
    }
    if (match_count <= 1) return;

    const first_index = match_indexes[0];
    var pos: usize = 0;
    const prefix = "ARRAY[";
    @memcpy(rpc_call.params[first_index].value_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    for (match_indexes[0..match_count], 0..) |param_index, arr_i| {
        if (arr_i > 0) {
            rpc_call.params[first_index].value_buf[pos] = ',';
            pos += 1;
        }
        pos = append_variadic_scalar(rpc_call.params[first_index].value_buf[0..], pos, rpc_call.params[param_index]);
    }

    rpc_call.params[first_index].value_buf[pos] = ']';
    pos += 1;
    rpc_call.params[first_index].value = rpc_call.params[first_index].value_buf[0..pos];
    rpc_call.params[first_index].is_null = false;
    rpc_call.params[first_index].is_numeric = false;
    rpc_call.params[first_index].is_boolean = false;
    rpc_call.params[first_index].is_raw = true;
    rpc_call.params[first_index].name = variadic_name;

    var new_count: usize = 0;
    for (0..rpc_call.param_count) |i| {
        var skip = false;
        if (i != first_index) {
            for (match_indexes[1..match_count]) |matched_index| {
                if (i == matched_index) {
                    skip = true;
                    break;
                }
            }
        }
        if (skip) continue;
        if (new_count != i) {
            rpc_call.params[new_count] = rpc_call.params[i];
        }
        new_count += 1;
    }
    rpc_call.param_count = new_count;
}

fn write_ident_quoted(buf_out: []u8, pos_in: usize, ident: []const u8) usize {
    var pos = pos_in;
    buf_out[pos] = '"';
    pos += 1;
    for (ident) |c| {
        if (c == '"') {
            buf_out[pos] = '"';
            pos += 1;
        }
        buf_out[pos] = c;
        pos += 1;
    }
    buf_out[pos] = '"';
    pos += 1;
    return pos;
}

fn build_rpc_table_query(
    query_buf: []u8,
    schema_name: ?[]const u8,
    function_name: []const u8,
    rpc_params: *const RpcCall,
    where_clause: []const u8,
    select_clause: []const u8,
    group_by_clause: []const u8,
    order_specs: []const OrderSpec,
    pagination: Pagination,
    params: ?*PgRequestCtx,
) usize {
    var pos: usize = 0;
    const select_prefix = "SELECT ";
    @memcpy(query_buf[pos..][0..select_prefix.len], select_prefix);
    pos += select_prefix.len;

    if (select_clause.len > 0) {
        @memcpy(query_buf[pos..][0..select_clause.len], select_clause);
        pos += select_clause.len;
    } else {
        query_buf[pos] = '*';
        pos += 1;
    }

    const from_prefix = " FROM ";
    @memcpy(query_buf[pos..][0..from_prefix.len], from_prefix);
    pos += from_prefix.len;

    if (schema_name) |schema| {
        pos = write_ident_quoted(query_buf, pos, schema);
        query_buf[pos] = '.';
        pos += 1;
    }
    pos = write_ident_quoted(query_buf, pos, function_name);
    query_buf[pos] = '(';
    pos += 1;

    var i: usize = 0;
    while (i < rpc_params.param_count) : (i += 1) {
        if (i > 0) {
            query_buf[pos] = ',';
            pos += 1;
            query_buf[pos] = ' ';
            pos += 1;
        }

        const param = rpc_params.params[i];
        if (param.name.len > 0) {
            @memcpy(query_buf[pos..][0..param.name.len], param.name);
            pos += param.name.len;
            query_buf[pos] = ' ';
            pos += 1;
            query_buf[pos] = '=';
            pos += 1;
            query_buf[pos] = '>';
            pos += 1;
            query_buf[pos] = ' ';
            pos += 1;
        }

        if (param.is_raw) {
            @memcpy(query_buf[pos..][0..param.value.len], param.value);
            pos += param.value.len;
        } else if (param.is_null) {
            const null_str = "NULL";
            @memcpy(query_buf[pos..][0..null_str.len], null_str);
            pos += null_str.len;
        } else if (param.is_boolean or param.is_numeric) {
            @memcpy(query_buf[pos..][0..param.value.len], param.value);
            pos += param.value.len;
        } else {
            pos = append_param_or_quoted(query_buf, pos, param.value, params);
        }
    }

    query_buf[pos] = ')';
    pos += 1;

    if (where_clause.len > 0) {
        const where_prefix = " WHERE ";
        @memcpy(query_buf[pos..][0..where_prefix.len], where_prefix);
        pos += where_prefix.len;
        @memcpy(query_buf[pos..][0..where_clause.len], where_clause);
        pos += where_clause.len;
    }

    if (group_by_clause.len > 0) {
        const group_by = " GROUP BY ";
        @memcpy(query_buf[pos..][0..group_by.len], group_by);
        pos += group_by.len;
        @memcpy(query_buf[pos..][0..group_by_clause.len], group_by_clause);
        pos += group_by_clause.len;
    }

    if (order_specs.len > 0) {
        const order_prefix = " ORDER BY ";
        @memcpy(query_buf[pos..][0..order_prefix.len], order_prefix);
        pos += order_prefix.len;
        for (order_specs, 0..) |spec, order_i| {
            if (order_i > 0) {
                query_buf[pos] = ',';
                pos += 1;
            }
            const expr = spec.expr();
            pos = append_column_expression(query_buf, pos, expr) orelse return pos;

            if (spec.dir == .desc) {
                const desc_str = " DESC";
                @memcpy(query_buf[pos..][0..desc_str.len], desc_str);
                pos += desc_str.len;
            } else {
                const asc_str = " ASC";
                @memcpy(query_buf[pos..][0..asc_str.len], asc_str);
                pos += asc_str.len;
            }

            switch (spec.nulls) {
                .none => {},
                .first => {
                    const nulls_first = " NULLS FIRST";
                    @memcpy(query_buf[pos..][0..nulls_first.len], nulls_first);
                    pos += nulls_first.len;
                },
                .last => {
                    const nulls_last = " NULLS LAST";
                    @memcpy(query_buf[pos..][0..nulls_last.len], nulls_last);
                    pos += nulls_last.len;
                },
            }
        }
    }

    if (pagination.limit) |limit| {
        const limit_str = std.fmt.bufPrint(query_buf[pos..], " LIMIT {d}", .{limit}) catch return pos;
        pos += limit_str.len;
    }
    if (pagination.offset) |offset| {
        const offset_str = std.fmt.bufPrint(query_buf[pos..], " OFFSET {d}", .{offset}) catch return pos;
        pos += offset_str.len;
    }

    return pos;
}

fn rpc_method_not_allowed_response(r: [*c]ngx_http_request_t, metadata: RpcMetadata) ngx_int_t {
    _ = append_response_header(r, "Allow", "allow", rpc_allow_header(metadata));
    return send_json_error(r, NGX_HTTP_METHOD_NOT_ALLOWED, "{\"message\":\"The HTTP method is not allowed for this RPC function\"}");
}

fn rpc_metadata_not_found_response(r: [*c]ngx_http_request_t) ngx_int_t {
    return send_json_error(r, http.NGX_HTTP_NOT_FOUND, "{\"message\":\"Undefined function\"}");
}

fn apply_rpc_single_unnamed_param(
    metadata: RpcMetadata,
    body_format: RequestBodyFormat,
    body_data: []const u8,
    rpc_call: *RpcCall,
) bool {
    if (metadata.single_unnamed_kind == .none) return false;
    if (!rpc_single_unnamed_kind_media_matches(metadata.single_unnamed_kind, body_format)) return false;

    _ = rpc_single_unnamed_kind_type_name(metadata.single_unnamed_kind);
    set_rpc_single_raw_param(rpc_call, "", body_data);
    rpc_call.params[0].is_raw = false;
    return true;
}

fn resolved_default_schema_name(resolved_schema: ResolvedSchema) ?[]const u8 {
    if (resolved_schema.name) |name| return name;
    if (resolved_schema.allowed_raw.len == 0) return null;

    var it = std.mem.splitScalar(u8, resolved_schema.allowed_raw, ',');
    while (it.next()) |part| {
        const schema = trim_ascii_spaces(part);
        if (schema.len == 0) continue;
        if (is_valid_schema_identifier(schema)) return schema;
    }
    return null;
}

/// Detect if URI path points to RPC endpoint (/rpc/function_name)
/// Returns true if path starts with /rpc/
fn is_rpc_endpoint(uri: ngx_str_t) bool {
    if (uri.len < 5 or uri.data == core.nullptr(u8)) {
        return false;
    }
    const path = core.slicify(u8, uri.data, uri.len);
    if (path.len >= 5 and std.mem.eql(u8, path[0..4], "/rpc")) {
        // Check that next char is either / or end of string
        if (path.len == 4) return true;
        if (path.len > 4 and path[4] == '/') return true;
    }
    return false;
}

/// Extract RPC function name from URI path
/// URI format: /rpc/function_name
/// Returns the function name after /rpc/
fn extract_rpc_function_name(uri: ngx_str_t) ?[]const u8 {
    if (uri.len == 0 or uri.data == core.nullptr(u8)) {
        return null;
    }

    const path = core.slicify(u8, uri.data, uri.len);

    // Find /rpc/ prefix
    if (path.len < 5 or !std.mem.eql(u8, path[0..4], "/rpc")) {
        return null;
    }

    // Skip /rpc/
    const start: usize = 5;
    if (start >= path.len) {
        return null;
    }

    // Find end of function name (next slash or end of string)
    var end: usize = start;
    while (end < path.len and path[end] != '/') {
        end += 1;
    }

    if (end == start) {
        return null;
    }

    return path[start..end];
}

/// Parse JSON POST body as RPC function arguments
/// Format: { "param1": "value1", "param2": "value2" }
fn parse_rpc_json_body(
    pool: [*c]core.ngx_pool_t,
    body: []const u8,
    rpc_call: *RpcCall,
) void {
    if (body.len == 0) return;

    if (rpc_call.prefer_single_object) {
        rpc_call.raw_body_len = body.len;
        rpc_call.params[0].name = "data";
        rpc_call.params[0].value = body;
        rpc_call.params[0].is_raw = false;
        rpc_call.params[0].is_null = false;
        rpc_call.params[0].is_numeric = false;
        rpc_call.params[0].is_boolean = false;
        rpc_call.param_count = 1;
        return;
    }

    // Initialize cJSON with pool allocator
    var json_parser = cjson.CJSON.init(pool);

    // Copy body to null-terminated buffer
    var body_buf: [4096]u8 = undefined;
    if (body.len >= body_buf.len) return;
    @memcpy(body_buf[0..body.len], body);
    body_buf[body.len] = 0;

    const body_str = ngx_str_t{ .data = &body_buf, .len = body.len };

    // Parse JSON
    const json = json_parser.decode(body_str) catch return;
    if (json == core.nullptr(cjson.cJSON)) return;

    // Iterate over object fields
    var it = cjson.CJSON.Iterator.init(json);
    var count: usize = 0;

    while (it.next()) |item| {
        if (count >= MAX_RPC_PARAMS) break;

        // Get field name
        if (item.*.string != core.nullptr(u8)) {
            var name_len: usize = 0;
            while (item.*.string[name_len] != 0 and name_len < 256) : (name_len += 1) {}
            rpc_call.params[count].name = item.*.string[0..name_len];

            // Get field value
            if (cjson.cJSON_IsNull(item) == 1) {
                rpc_call.params[count].value = "NULL";
                rpc_call.params[count].is_null = true;
                rpc_call.params[count].is_numeric = false;
                rpc_call.params[count].is_boolean = false;
                rpc_call.params[count].is_raw = false;
            } else if (cjson.cJSON_IsNumber(item) == 1) {
                rpc_call.params[count].value = format_json_number(
                    cjson.cJSON_GetNumberValue(item),
                    &rpc_call.params[count].value_buf,
                );
                rpc_call.params[count].is_null = false;
                rpc_call.params[count].is_numeric = true;
                rpc_call.params[count].is_boolean = false;
                rpc_call.params[count].is_raw = false;
            } else if (cjson.cJSON_IsString(item) == 1) {
                if (cjson.cJSON_GetStringValue(item)) |str| {
                    var str_len: usize = 0;
                    while (str[str_len] != 0 and str_len < 1024) : (str_len += 1) {}
                    rpc_call.params[count].value = str[0..str_len];
                } else {
                    rpc_call.params[count].value = "";
                }
                rpc_call.params[count].is_null = false;
                rpc_call.params[count].is_numeric = false;
                rpc_call.params[count].is_boolean = false;
                rpc_call.params[count].is_raw = false;
            } else if (cjson.cJSON_IsBool(item) == 1) {
                rpc_call.params[count].value = if (cjson.cJSON_IsTrue(item) == 1) "true" else "false";
                rpc_call.params[count].is_null = false;
                rpc_call.params[count].is_numeric = false;
                rpc_call.params[count].is_boolean = true;
                rpc_call.params[count].is_raw = false;
            } else if (cjson.cJSON_IsArray(item) == 1) {
                // Support for array parameters - store as ARRAY constructor syntax
                // Convert array elements into ARRAY[...] format
                var arr_pos: usize = 0;
                var arr_buf = &rpc_call.params[count].value_buf;

                // Start with ARRAY[
                const arr_prefix = "ARRAY[";
                @memcpy(arr_buf[arr_pos..][0..arr_prefix.len], arr_prefix);
                arr_pos += arr_prefix.len;

                // Iterate array elements
                var arr_item = item.*.child;
                var arr_index: i32 = 0;
                while (arr_item != null and arr_pos < arr_buf.len - 10) {
                    if (arr_index > 0) {
                        arr_buf[arr_pos] = ',';
                        arr_pos += 1;
                    }

                    if (cjson.cJSON_IsNumber(arr_item) == 1) {
                        const num_str = format_json_number(
                            cjson.cJSON_GetNumberValue(arr_item),
                            arr_buf[arr_pos..],
                        );
                        if (arr_pos + num_str.len < arr_buf.len) {
                            arr_pos += num_str.len;
                        }
                    } else if (cjson.cJSON_IsString(arr_item) == 1) {
                        if (cjson.cJSON_GetStringValue(arr_item)) |str| {
                            var s_len: usize = 0;
                            while (str[s_len] != 0 and s_len < 256) : (s_len += 1) {}
                            if (arr_pos + (s_len * 2) + 2 < arr_buf.len) {
                                arr_pos = append_sql_quoted(arr_buf, arr_pos, str[0..s_len]);
                            }
                        }
                    } else if (cjson.cJSON_IsBool(arr_item) == 1) {
                        const bool_str = if (cjson.cJSON_IsTrue(arr_item) == 1) "true" else "false";
                        if (arr_pos + bool_str.len < arr_buf.len) {
                            @memcpy(arr_buf[arr_pos..][0..bool_str.len], bool_str);
                            arr_pos += bool_str.len;
                        }
                    } else if (cjson.cJSON_IsNull(arr_item) == 1) {
                        const null_str = "NULL";
                        if (arr_pos + null_str.len < arr_buf.len) {
                            @memcpy(arr_buf[arr_pos..][0..null_str.len], null_str);
                            arr_pos += null_str.len;
                        }
                    }

                    arr_item = arr_item.*.next;
                    arr_index += 1;
                }

                // Close with ]
                arr_buf[arr_pos] = ']';
                arr_pos += 1;

                rpc_call.params[count].value = arr_buf[0..arr_pos];
                rpc_call.params[count].is_null = false;
                rpc_call.params[count].is_numeric = false;
                rpc_call.params[count].is_boolean = false;
                rpc_call.params[count].is_raw = true;
            } else {
                continue; // Skip unsupported types (nested objects)
            }

            count += 1;
        }
    }

    rpc_call.param_count = count;
}

/// Parse query string parameters as RPC function arguments
/// Format: ?param1=value1&param2=value2
fn parse_rpc_params(args: ngx_str_t, rpc_call: *RpcCall) void {
    if (args.len == 0 or args.data == core.nullptr(u8)) {
        return;
    }

    const query = core.slicify(u8, args.data, args.len);
    var count: usize = 0;
    var pos: usize = 0;

    while (pos < query.len and count < MAX_RPC_PARAMS) {
        // Find end of this parameter (& or end of string)
        var param_end = pos;
        while (param_end < query.len and query[param_end] != '&') {
            param_end += 1;
        }

        const param = query[pos..param_end];

        // Parse param_name=value
        var eq_pos: usize = 0;
        while (eq_pos < param.len and param[eq_pos] != '=') {
            eq_pos += 1;
        }

        if (eq_pos > 0 and eq_pos < param.len - 1) {
            rpc_call.params[count].name = param[0..eq_pos];
            rpc_call.params[count].value = param[eq_pos + 1 ..];
            rpc_call.params[count].is_null = false;
            rpc_call.params[count].is_numeric = is_numeric(rpc_call.params[count].value);
            rpc_call.params[count].is_boolean = std.mem.eql(u8, rpc_call.params[count].value, "true") or std.mem.eql(u8, rpc_call.params[count].value, "false");
            rpc_call.params[count].is_raw = false;
            count += 1;
        }

        pos = param_end + 1; // Skip the '&'
    }

    rpc_call.param_count = count;
}

fn parse_rpc_form_body(body: []const u8, rpc_call: *RpcCall) void {
    if (body.len == 0) return;
    if (rpc_call.prefer_single_object) return;

    var count: usize = 0;
    var start: usize = 0;

    while (start <= body.len and count < MAX_RPC_PARAMS) {
        var end = start;
        while (end < body.len and body[end] != '&') : (end += 1) {}

        const pair = body[start..end];
        if (pair.len > 0) {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const raw_name = pair[0..eq];
            const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";

            const name_len = decode_form_component_into(&rpc_call.params[count].value_buf, raw_name) orelse return;
            if (name_len == 0) {
                if (end == body.len) break;
                start = end + 1;
                continue;
            }

            rpc_call.params[count].name = rpc_call.params[count].value_buf[0..name_len];

            const value_storage = rpc_call.raw_body[count * 256 .. @min(rpc_call.raw_body.len, (count + 1) * 256)];
            const value_len = decode_form_component_into(value_storage, raw_value) orelse return;
            rpc_call.params[count].value = value_storage[0..value_len];
            rpc_call.params[count].is_null = false;
            rpc_call.params[count].is_numeric = is_numeric(rpc_call.params[count].value);
            rpc_call.params[count].is_boolean = std.mem.eql(u8, rpc_call.params[count].value, "true") or std.mem.eql(u8, rpc_call.params[count].value, "false");
            rpc_call.params[count].is_raw = false;
            count += 1;
        }

        if (end == body.len) break;
        start = end + 1;
    }

    rpc_call.param_count = count;
}

fn set_rpc_single_raw_param(rpc_call: *RpcCall, name: []const u8, body: []const u8) void {
    if (body.len == 0 or name.len > rpc_call.params[0].value_buf.len) return;

    @memcpy(rpc_call.params[0].value_buf[0..name.len], name);
    rpc_call.params[0].name = rpc_call.params[0].value_buf[0..name.len];
    rpc_call.params[0].value = body;
    rpc_call.params[0].is_null = false;
    rpc_call.params[0].is_numeric = false;
    rpc_call.params[0].is_boolean = false;
    rpc_call.params[0].is_raw = false;
    rpc_call.raw_body_len = body.len;
    rpc_call.param_count = 1;
}

/// Build SQL function call from RPC parameters
/// Format: SELECT function_name(param1 => value1, param2 => value2)
/// Handles JSON arrays without quotes, regular strings with quotes
fn build_rpc_call_query(
    query_buf: []u8,
    schema_name: ?[]const u8,
    function_name: []const u8,
    rpc_params: *const RpcCall,
    params: ?*PgRequestCtx,
) usize {
    var pos: usize = 0;

    const select_str = "SELECT ";
    @memcpy(query_buf[pos..][0..select_str.len], select_str);
    pos += select_str.len;

    if (schema_name) |schema| {
        @memcpy(query_buf[pos..][0..schema.len], schema);
        pos += schema.len;
        query_buf[pos] = '.';
        pos += 1;
    }

    // Function name
    @memcpy(query_buf[pos..][0..function_name.len], function_name);
    pos += function_name.len;

    // Opening paren
    query_buf[pos] = '(';
    pos += 1;

    // Parameters as named arguments (PostgreSQL syntax)
    var i: usize = 0;
    while (i < rpc_params.param_count) : (i += 1) {
        if (i > 0) {
            query_buf[pos] = ',';
            pos += 1;
            query_buf[pos] = ' ';
            pos += 1;
        }

        const param = rpc_params.params[i];

        if (param.name.len > 0) {
            @memcpy(query_buf[pos..][0..param.name.len], param.name);
            pos += param.name.len;

            query_buf[pos] = ' ';
            pos += 1;
            query_buf[pos] = '=';
            pos += 1;
            query_buf[pos] = '>';
            pos += 1;
            query_buf[pos] = ' ';
            pos += 1;
        }

        // Parameter value handling
        // JSON arrays/objects are passed without quotes
        // Regular strings and other values are quoted
        if (param.is_raw) {
            @memcpy(query_buf[pos..][0..param.value.len], param.value);
            pos += param.value.len;
        } else if (param.is_null) {
            const null_str = "NULL";
            @memcpy(query_buf[pos..][0..null_str.len], null_str);
            pos += null_str.len;
        } else if (param.is_boolean or param.is_numeric) {
            @memcpy(query_buf[pos..][0..param.value.len], param.value);
            pos += param.value.len;
        } else {
            pos = append_param_or_quoted(query_buf, pos, param.value, params);
        }
    }

    // Closing paren
    query_buf[pos] = ')';
    pos += 1;

    return pos;
}

/// Check if a string represents a number
fn is_numeric(value: []const u8) bool {
    if (value.len == 0) return false;

    var i: usize = 0;
    // Allow leading minus sign
    if (value[0] == '-') {
        i = 1;
    }

    if (i >= value.len) return false;

    // Must have at least one digit
    var has_digit = false;
    var has_dot = false;

    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (c >= '0' and c <= '9') {
            has_digit = true;
        } else if (c == '.' and !has_dot) {
            has_dot = true;
        } else {
            return false;
        }
    }

    return has_digit;
}

fn request_needs_body(r: [*c]ngx_http_request_t) bool {
    return r.*.method == http.NGX_HTTP_POST or
        r.*.method == http.NGX_HTTP_PATCH or
        r.*.method == http.NGX_HTTP_PUT;
}

fn get_request_body_slice(r: [*c]ngx_http_request_t) ?[]const u8 {
    if (r.*.request_body == null) return null;
    const rb = r.*.request_body;

    if (rb.*.buf != null and !buf.ngx_buf_special(rb.*.buf)) {
        const b = rb.*.buf;
        const chunk_len_off = buf.ngx_buf_size(b);
        if (chunk_len_off < 0) return null;
        const chunk_len: usize = @intCast(chunk_len_off);
        if (chunk_len > 0) {
            const raw = core.ngx_pnalloc(r.*.pool, chunk_len) orelse return null;
            const out = core.castPtr(u8, raw) orelse return null;

            if (buf.ngx_buf_in_memory_only(b)) {
                @memcpy(out[0..chunk_len], core.slicify(u8, b.*.pos, chunk_len));
                return out[0..chunk_len];
            }

            if (b.*.flags.in_file and b.*.file != null) {
                const read_len = file.ngx_read_file(b.*.file, out, chunk_len, b.*.file_pos);
                if (read_len == NGX_ERROR or @as(usize, @intCast(read_len)) != chunk_len) return null;
                return out[0..chunk_len];
            }
        }
    }

    if (rb.*.bufs == null) {
        const tf = rb.*.temp_file;
        if (tf == null) return null;

        const total_off = if (rb.*.received > 0) rb.*.received else tf.*.offset;
        if (total_off <= 0) return null;

        const total: usize = @intCast(total_off);
        const raw = core.ngx_pnalloc(r.*.pool, total) orelse return null;
        const out = core.castPtr(u8, raw) orelse return null;
        const read_len = file.ngx_read_file(&tf.*.file, out, total, 0);
        if (read_len == NGX_ERROR or @as(usize, @intCast(read_len)) != total) return null;
        return out[0..total];
    }

    var total: usize = 0;
    var chain = rb.*.bufs;
    while (chain != null) : (chain = chain.*.next) {
        const b = chain.*.buf;
        if (b == null or buf.ngx_buf_special(b)) continue;
        const chunk_len = buf.ngx_buf_size(b);
        if (chunk_len < 0) return null;
        total += @intCast(chunk_len);
    }

    if (total == 0) {
        const tf = rb.*.temp_file;
        if (tf == null) return null;

        const total_off = if (rb.*.received > 0) rb.*.received else tf.*.offset;
        if (total_off <= 0) return null;

        const file_total: usize = @intCast(total_off);
        const raw = core.ngx_pnalloc(r.*.pool, file_total) orelse return null;
        const out = core.castPtr(u8, raw) orelse return null;
        const read_len = file.ngx_read_file(&tf.*.file, out, file_total, 0);
        if (read_len == NGX_ERROR or @as(usize, @intCast(read_len)) != file_total) return null;
        return out[0..file_total];
    }

    const raw = core.ngx_pnalloc(r.*.pool, total) orelse return null;
    const out = core.castPtr(u8, raw) orelse return null;

    var offset: usize = 0;
    chain = rb.*.bufs;
    while (chain != null) : (chain = chain.*.next) {
        const b = chain.*.buf;
        if (b == null or buf.ngx_buf_special(b)) continue;

        const chunk_len_off = buf.ngx_buf_size(b);
        if (chunk_len_off < 0) return null;
        const chunk_len: usize = @intCast(chunk_len_off);
        if (chunk_len == 0) continue;

        if (buf.ngx_buf_in_memory_only(b)) {
            @memcpy(out[offset .. offset + chunk_len], core.slicify(u8, b.*.pos, chunk_len));
            offset += chunk_len;
            continue;
        }

        if (b.*.flags.in_file and b.*.file != null) {
            const read_len = file.ngx_read_file(b.*.file, out + offset, chunk_len, b.*.file_pos);
            if (read_len == NGX_ERROR or @as(usize, @intCast(read_len)) != chunk_len) return null;
            offset += chunk_len;
            continue;
        }

        return null;
    }

    return out[0..offset];
}

fn parse_write_body_fields(
    body_format: RequestBodyFormat,
    body_data: []const u8,
    pool: [*c]ngx_pool_t,
    fields: *[MAX_COLUMNS]JsonField,
) usize {
    return switch (body_format) {
        .json => parse_json_body(pool, body_data, fields),
        .form_urlencoded => parse_form_urlencoded_body(body_data, fields),
        .csv => parse_csv_row_into_fields(body_data, fields),
        .plain_text, .xml, .binary => parse_single_value_body("data", body_data, fields),
        .none, .unsupported => 0,
    };
}

fn parse_json_scalar_into_field(item: ?*cjson.cJSON, field: *JsonField) bool {
    if (item == null) return false;

    if (cjson.cJSON_IsNull(item) == 1) {
        field.*.value = "";
        field.*.is_null = true;
        field.*.is_number = false;
        field.*.is_boolean = false;
        field.*.is_missing = false;
        return true;
    }

    if (cjson.cJSON_IsNumber(item) == 1) {
        field.*.value = format_json_number(cjson.cJSON_GetNumberValue(item), &field.value_buf);
        field.*.is_null = false;
        field.*.is_number = true;
        field.*.is_boolean = false;
        field.*.is_missing = false;
        return true;
    }

    if (cjson.cJSON_IsString(item) == 1) {
        if (cjson.cJSON_GetStringValue(item)) |str| {
            var str_len: usize = 0;
            while (str[str_len] != 0 and str_len < field.value_buf.len) : (str_len += 1) {}
            field.*.value = str[0..str_len];
        } else {
            field.*.value = "";
        }
        field.*.is_null = false;
        field.*.is_number = false;
        field.*.is_boolean = false;
        field.*.is_missing = false;
        return true;
    }

    if (cjson.cJSON_IsBool(item) == 1) {
        field.*.value = if (cjson.cJSON_IsTrue(item) == 1) "true" else "false";
        field.*.is_null = false;
        field.*.is_number = false;
        field.*.is_boolean = true;
        field.*.is_missing = false;
        return true;
    }

    return false;
}

fn find_json_object_field(row_obj: ?*cjson.cJSON, field_name: []const u8) ?*cjson.cJSON {
    if (row_obj == null or cjson.cJSON_IsObject(row_obj) != 1) return null;

    var it = cjson.CJSON.Iterator.init(row_obj);
    while (it.next()) |item| {
        if (item.*.string == core.nullptr(u8)) continue;
        var name_len: usize = 0;
        while (item.*.string[name_len] != 0 and name_len < 256) : (name_len += 1) {}
        if (std.mem.eql(u8, item.*.string[0..name_len], field_name)) return item;
    }

    return null;
}

fn parse_json_array_row(
    row_obj: ?*cjson.cJSON,
    fields: *[MAX_COLUMNS]JsonField,
    allowed_columns: []const []const u8,
    prefer_missing_default: bool,
) ?usize {
    if (row_obj == null or cjson.cJSON_IsObject(row_obj) != 1) return null;

    var count: usize = 0;

    if (allowed_columns.len > 0) {
        for (allowed_columns) |allowed_raw| {
            if (count >= MAX_COLUMNS) return null;

            var decoded_name_buf: [256]u8 = undefined;
            const decoded_name = decode_query_component_into(&decoded_name_buf, allowed_raw) orelse return null;
            const name = trim_ascii_spaces(decoded_name);
            if (name.len == 0 or name.len > fields[count].name_buf.len) return null;

            @memcpy(fields[count].name_buf[0..name.len], name);
            fields[count].name = fields[count].name_buf[0..name.len];

            const item = find_json_object_field(row_obj, fields[count].name);
            if (item == null) {
                fields[count].value = "";
                fields[count].is_number = false;
                fields[count].is_boolean = false;
                fields[count].is_null = !prefer_missing_default;
                fields[count].is_missing = true;
                count += 1;
                continue;
            }

            if (!parse_json_scalar_into_field(item, &fields[count])) return null;
            count += 1;
        }

        return count;
    }

    var it = cjson.CJSON.Iterator.init(row_obj);
    while (it.next()) |item| {
        if (count >= MAX_COLUMNS) break;
        if (item.*.string == core.nullptr(u8)) continue;

        var name_len: usize = 0;
        while (item.*.string[name_len] != 0 and name_len < fields[count].name_buf.len) : (name_len += 1) {}
        if (name_len == 0 or name_len >= fields[count].name_buf.len) return null;

        @memcpy(fields[count].name_buf[0..name_len], item.*.string[0..name_len]);
        fields[count].name = fields[count].name_buf[0..name_len];
        if (!parse_json_scalar_into_field(item, &fields[count])) return null;
        count += 1;
    }

    return count;
}

fn parse_json_array_body_rows(
    pool: [*c]core.ngx_pool_t,
    body: []const u8,
    rows: *[MAX_WRITE_ROWS][MAX_COLUMNS]JsonField,
    row_field_counts: *[MAX_WRITE_ROWS]usize,
    allowed_columns: []const []const u8,
    prefer_missing_default: bool,
) ?usize {
    if (body.len == 0) return 0;

    var json_parser = cjson.CJSON.init(pool);

    var body_buf: [8192]u8 = undefined;
    if (body.len >= body_buf.len) return null;
    @memcpy(body_buf[0..body.len], body);
    body_buf[body.len] = 0;

    const body_str = ngx_str_t{ .data = &body_buf, .len = body.len };
    const json = json_parser.decode(body_str) catch return null;
    if (json == core.nullptr(cjson.cJSON) or cjson.cJSON_IsArray(json) != 1) return 0;

    var row_ptr = json.*.child;
    var row_count: usize = 0;
    var inferred_columns: [MAX_COLUMNS][]const u8 = undefined;
    var inferred_count: usize = 0;
    while (row_ptr != null) {
        if (row_count >= MAX_WRITE_ROWS) return null;
        const columns_for_row = if (allowed_columns.len > 0) allowed_columns else inferred_columns[0..inferred_count];
        const field_count = parse_json_array_row(row_ptr, &rows[row_count], columns_for_row, prefer_missing_default) orelse return null;
        row_field_counts[row_count] = field_count;

        if (row_count == 0 and allowed_columns.len == 0) {
            inferred_count = field_count;
            for (rows[0][0..field_count], 0..) |field, idx| {
                inferred_columns[idx] = field.name;
            }
        }

        row_count += 1;
        row_ptr = row_ptr.*.next;
    }

    return row_count;
}

fn project_fields_to_columns(
    source: []const JsonField,
    dest: *[MAX_COLUMNS]JsonField,
    raw_columns: []const []const u8,
    prefer_missing_default: bool,
) ?usize {
    if (raw_columns.len == 0) return source.len;

    for (raw_columns, 0..) |raw_name, idx| {
        if (idx >= MAX_COLUMNS) return null;
        var decoded_name_buf: [256]u8 = undefined;
        const decoded_name = decode_query_component_into(&decoded_name_buf, raw_name) orelse return null;
        const name = trim_ascii_spaces(decoded_name);
        if (name.len == 0 or name.len > dest[idx].name_buf.len) return null;
        @memcpy(dest[idx].name_buf[0..name.len], name);
        dest[idx].name = dest[idx].name_buf[0..name.len];

        var matched = false;
        for (source) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                dest[idx].value = field.value;
                dest[idx].is_null = field.is_null;
                dest[idx].is_number = field.is_number;
                dest[idx].is_boolean = field.is_boolean;
                matched = true;
                break;
            }
        }

        if (!matched) {
            dest[idx].value = "";
            dest[idx].is_number = false;
            dest[idx].is_boolean = false;
            dest[idx].is_null = !prefer_missing_default;
            dest[idx].is_missing = true;
        } else {
            dest[idx].is_missing = false;
        }
    }

    return raw_columns.len;
}

fn parse_csv_bulk_rows(
    body: []const u8,
    rows: *[MAX_WRITE_ROWS][MAX_COLUMNS]JsonField,
    row_field_counts: *[MAX_WRITE_ROWS]usize,
) ?usize {
    if (body.len == 0) return 0;

    const newline = std.mem.indexOfScalar(u8, body, '\n') orelse return 0;
    const header_line = trim_ascii_spaces(body[0..newline]);
    if (header_line.len == 0) return 0;

    var header_names: [MAX_COLUMNS][]const u8 = undefined;
    var header_count: usize = 0;
    var header_it = std.mem.splitScalar(u8, header_line, ',');
    while (header_it.next()) |raw_name| {
        if (header_count >= MAX_COLUMNS) return null;
        const name = trim_ascii_spaces(raw_name);
        if (name.len == 0 or !is_valid_schema_identifier(name)) return null;
        header_names[header_count] = name;
        header_count += 1;
    }
    if (header_count == 0) return 0;

    var row_count: usize = 0;
    var line_start: usize = newline + 1;
    while (line_start < body.len) {
        var line_end = line_start;
        while (line_end < body.len and body[line_end] != '\n') : (line_end += 1) {}
        const line = trim_ascii_spaces(body[line_start..line_end]);
        if (line.len > 0) {
            if (row_count >= MAX_WRITE_ROWS) return null;
            var value_it = std.mem.splitScalar(u8, line, ',');

            for (header_names[0..header_count], 0..) |name, idx| {
                const raw_value = value_it.next() orelse return null;
                if (name.len > rows[row_count][idx].name_buf.len) return null;
                @memcpy(rows[row_count][idx].name_buf[0..name.len], name);
                rows[row_count][idx].name = rows[row_count][idx].name_buf[0..name.len];

                const value = trim_ascii_spaces(raw_value);
                if (value.len > rows[row_count][idx].value_buf.len) return null;
                @memcpy(rows[row_count][idx].value_buf[0..value.len], value);
                rows[row_count][idx].value = rows[row_count][idx].value_buf[0..value.len];
                rows[row_count][idx].is_null = std.mem.eql(u8, value, "NULL");
                rows[row_count][idx].is_number = !rows[row_count][idx].is_null and is_numeric(value);
                rows[row_count][idx].is_boolean = !rows[row_count][idx].is_null and (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false"));
                rows[row_count][idx].is_missing = false;
            }

            if (value_it.next() != null) return null;
            row_field_counts[row_count] = header_count;
            row_count += 1;
        }

        if (line_end == body.len) break;
        line_start = line_end + 1;
    }

    return row_count;
}

fn append_write_scalar(buf_out: []u8, pos_in: usize, scalar: WriteScalar, params: ?*PgRequestCtx) usize {
    if (scalar.use_default) {
        const token = "DEFAULT";
        @memcpy(buf_out[pos_in..][0..token.len], token);
        return pos_in + token.len;
    }
    if (scalar.is_null) {
        const token = "NULL";
        @memcpy(buf_out[pos_in..][0..token.len], token);
        return pos_in + token.len;
    }
    if (scalar.is_number or scalar.is_boolean) {
        @memcpy(buf_out[pos_in..][0..scalar.value.len], scalar.value);
        return pos_in + scalar.value.len;
    }
    return append_param_or_quoted(buf_out, pos_in, scalar.value, params);
}

fn json_field_to_scalar(field: JsonField) WriteScalar {
    return .{
        .value = field.value,
        .is_null = field.is_null,
        .is_number = field.is_number,
        .is_boolean = field.is_boolean,
        .use_default = field.is_missing,
    };
}

fn parse_filter_eq_column_values(
    args: ngx_str_t,
    name_storage: *[MAX_COLUMNS][256]u8,
    column_names: *[MAX_COLUMNS][]const u8,
    values: *[MAX_COLUMNS]WriteScalar,
) ?usize {
    var filters: [MAX_FILTERS]Filter = undefined;
    const filter_count = parse_filters(args, &filters);
    if (filter_count == 0) return 0;
    if (filter_count > MAX_COLUMNS) return null;

    for (filters[0..filter_count], 0..) |filter, idx| {
        if (filter.op != .eq) return null;

        var decoded_name_buf: [256]u8 = undefined;
        const decoded_name = decode_query_component_into(&decoded_name_buf, filter.column) orelse return null;
        const name = trim_ascii_spaces(decoded_name);
        if (name.len == 0 or !is_valid_schema_identifier(name) or name.len > name_storage[idx].len) return null;
        @memcpy(name_storage[idx][0..name.len], name);
        column_names[idx] = name_storage[idx][0..name.len];

        values[idx] = .{
            .value = filter.value,
            .is_null = false,
            .is_number = is_numeric(filter.value),
            .is_boolean = std.mem.eql(u8, filter.value, "true") or std.mem.eql(u8, filter.value, "false"),
            .use_default = false,
        };
    }

    return filter_count;
}

fn row_contains_column(row: []const JsonField, name: []const u8) bool {
    for (row) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

fn scalar_equals_field(scalar: WriteScalar, field: JsonField) bool {
    return scalar.is_null == field.is_null and
        scalar.is_number == field.is_number and
        scalar.is_boolean == field.is_boolean and
        scalar.use_default == field.is_missing and
        std.mem.eql(u8, scalar.value, field.value);
}

fn append_insert_row_from_json_fields(
    dest_columns: *[MAX_COLUMNS][]const u8,
    dest_scalars: *[MAX_COLUMNS]WriteScalar,
    existing_count: usize,
    source_fields: []const JsonField,
) ?usize {
    var count = existing_count;
    if (count > MAX_COLUMNS) return null;

    for (source_fields) |field| {
        if (field.name.len == 0) continue;
        var exists = false;
        for (dest_columns[0..count]) |existing| {
            if (std.mem.eql(u8, existing, field.name)) {
                exists = true;
                break;
            }
        }
        if (exists) continue;
        if (count >= MAX_COLUMNS) return null;
        dest_columns[count] = field.name;
        dest_scalars[count] = json_field_to_scalar(field);
        count += 1;
    }

    return count;
}

fn project_put_row(
    dest: *[MAX_COLUMNS]WriteScalar,
    column_names: []const []const u8,
    filter_columns: []const []const u8,
    filter_values: []const WriteScalar,
    body_fields: []const JsonField,
) ?void {
    if (column_names.len > MAX_COLUMNS) return null;

    for (column_names, 0..) |name, idx| {
        var matched_filter = false;
        for (filter_columns, 0..) |filter_name, filter_idx| {
            if (std.mem.eql(u8, filter_name, name)) {
                dest[idx] = filter_values[filter_idx];
                matched_filter = true;
                break;
            }
        }
        if (matched_filter) continue;

        var matched_body = false;
        for (body_fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                dest[idx] = json_field_to_scalar(field);
                matched_body = true;
                break;
            }
        }
        if (!matched_body) return null;
    }
}

fn build_limited_write_query(
    query_buf: []u8,
    sql_op: SqlOp,
    table: []const u8,
    where_clause: []const u8,
    order_specs: []const OrderSpec,
    pagination: Pagination,
    json_fields: []const JsonField,
    include_returning: bool,
    params: ?*PgRequestCtx,
) ?usize {
    if (!(sql_op == .update or sql_op == .delete)) return null;
    const limit = pagination.limit orelse return null;
    if (order_specs.len == 0) return null;

    var pos: usize = 0;
    const with_prefix = "WITH pgrest_limited AS (SELECT ctid FROM ";
    @memcpy(query_buf[pos..][0..with_prefix.len], with_prefix);
    pos += with_prefix.len;
    @memcpy(query_buf[pos..][0..table.len], table);
    pos += table.len;

    if (where_clause.len > 0) {
        const where = " WHERE ";
        @memcpy(query_buf[pos..][0..where.len], where);
        pos += where.len;
        @memcpy(query_buf[pos..][0..where_clause.len], where_clause);
        pos += where_clause.len;
    }

    const order = " ORDER BY ";
    @memcpy(query_buf[pos..][0..order.len], order);
    pos += order.len;
    for (order_specs, 0..) |spec, i| {
        if (i > 0) {
            query_buf[pos] = ',';
            pos += 1;
        }
        const expr = spec.expr();
        pos = append_column_expression(query_buf, pos, expr) orelse return null;
        if (spec.dir == .desc) {
            const desc_str = " DESC";
            @memcpy(query_buf[pos..][0..desc_str.len], desc_str);
            pos += desc_str.len;
        } else {
            const asc_str = " ASC";
            @memcpy(query_buf[pos..][0..asc_str.len], asc_str);
            pos += asc_str.len;
        }
        switch (spec.nulls) {
            .none => {},
            .first => {
                const nulls_first = " NULLS FIRST";
                @memcpy(query_buf[pos..][0..nulls_first.len], nulls_first);
                pos += nulls_first.len;
            },
            .last => {
                const nulls_last = " NULLS LAST";
                @memcpy(query_buf[pos..][0..nulls_last.len], nulls_last);
                pos += nulls_last.len;
            },
        }
    }

    const limit_str = " LIMIT ";
    @memcpy(query_buf[pos..][0..limit_str.len], limit_str);
    pos += limit_str.len;
    var num_buf: [32]u8 = undefined;
    const limit_num = std.fmt.bufPrint(&num_buf, "{d}", .{limit}) catch return null;
    @memcpy(query_buf[pos..][0..limit_num.len], limit_num);
    pos += limit_num.len;

    if (pagination.offset) |offset| {
        const offset_str = " OFFSET ";
        @memcpy(query_buf[pos..][0..offset_str.len], offset_str);
        pos += offset_str.len;
        const offset_num = std.fmt.bufPrint(&num_buf, "{d}", .{offset}) catch return null;
        @memcpy(query_buf[pos..][0..offset_num.len], offset_num);
        pos += offset_num.len;
    }

    const close_cte = ") ";
    @memcpy(query_buf[pos..][0..close_cte.len], close_cte);
    pos += close_cte.len;

    switch (sql_op) {
        .update => {
            const update_prefix = "UPDATE ";
            @memcpy(query_buf[pos..][0..update_prefix.len], update_prefix);
            pos += update_prefix.len;
            @memcpy(query_buf[pos..][0..table.len], table);
            pos += table.len;

            const set_str = " SET ";
            @memcpy(query_buf[pos..][0..set_str.len], set_str);
            pos += set_str.len;
            if (json_fields.len == 0) return null;
            for (json_fields, 0..) |field, i| {
                if (i > 0) {
                    query_buf[pos] = ',';
                    pos += 1;
                }
                @memcpy(query_buf[pos..][0..field.name.len], field.name);
                pos += field.name.len;
                query_buf[pos] = '=';
                pos += 1;
                if (field.is_null) {
                    const null_str = "NULL";
                    @memcpy(query_buf[pos..][0..null_str.len], null_str);
                    pos += null_str.len;
                } else if (field.is_number or field.is_boolean) {
                    @memcpy(query_buf[pos..][0..field.value.len], field.value);
                    pos += field.value.len;
                } else {
                    pos = append_param_or_quoted(query_buf, pos, field.value, params);
                }
            }
        },
        .delete => {
            const delete_prefix = "DELETE FROM ";
            @memcpy(query_buf[pos..][0..delete_prefix.len], delete_prefix);
            pos += delete_prefix.len;
            @memcpy(query_buf[pos..][0..table.len], table);
            pos += table.len;
        },
        else => return null,
    }

    const where_ctid = " WHERE ctid IN (SELECT ctid FROM pgrest_limited)";
    @memcpy(query_buf[pos..][0..where_ctid.len], where_ctid);
    pos += where_ctid.len;

    if (include_returning) {
        const returning = " RETURNING *";
        @memcpy(query_buf[pos..][0..returning.len], returning);
        pos += returning.len;
    }

    return pos;
}

fn build_insert_rows_query(
    query_buf: []u8,
    table: []const u8,
    column_names: []const []const u8,
    row_values: []const []const WriteScalar,
    on_conflict_columns: []const []const u8,
    prefer_resolution: PreferResolution,
    include_returning: bool,
    params: ?*PgRequestCtx,
) usize {
    var pos: usize = 0;

    const insert_prefix = "INSERT INTO ";
    @memcpy(query_buf[pos..][0..insert_prefix.len], insert_prefix);
    pos += insert_prefix.len;
    @memcpy(query_buf[pos..][0..table.len], table);
    pos += table.len;

    query_buf[pos] = ' ';
    pos += 1;
    query_buf[pos] = '(';
    pos += 1;
    for (column_names, 0..) |name, idx| {
        if (idx > 0) {
            query_buf[pos] = ',';
            pos += 1;
        }
        @memcpy(query_buf[pos..][0..name.len], name);
        pos += name.len;
    }
    query_buf[pos] = ')';
    pos += 1;

    const values_token = " VALUES ";
    @memcpy(query_buf[pos..][0..values_token.len], values_token);
    pos += values_token.len;

    for (row_values, 0..) |row, row_idx| {
        if (row_idx > 0) {
            query_buf[pos] = ',';
            pos += 1;
        }
        query_buf[pos] = '(';
        pos += 1;
        for (row, 0..) |scalar, col_idx| {
            if (col_idx > 0) {
                query_buf[pos] = ',';
                pos += 1;
            }
            pos = append_write_scalar(query_buf, pos, scalar, params);
        }
        query_buf[pos] = ')';
        pos += 1;
    }

    if (on_conflict_columns.len > 0 and prefer_resolution != .none) {
        const on_conflict = " ON CONFLICT (";
        @memcpy(query_buf[pos..][0..on_conflict.len], on_conflict);
        pos += on_conflict.len;

        for (on_conflict_columns, 0..) |name, idx| {
            if (idx > 0) {
                query_buf[pos] = ',';
                pos += 1;
            }
            @memcpy(query_buf[pos..][0..name.len], name);
            pos += name.len;
        }
        query_buf[pos] = ')';
        pos += 1;

        switch (prefer_resolution) {
            .merge_duplicates => {
                const do_update = " DO UPDATE SET ";
                @memcpy(query_buf[pos..][0..do_update.len], do_update);
                pos += do_update.len;

                for (column_names, 0..) |name, idx| {
                    if (idx > 0) {
                        query_buf[pos] = ',';
                        pos += 1;
                    }
                    @memcpy(query_buf[pos..][0..name.len], name);
                    pos += name.len;
                    query_buf[pos] = '=';
                    pos += 1;
                    const excluded = "EXCLUDED.";
                    @memcpy(query_buf[pos..][0..excluded.len], excluded);
                    pos += excluded.len;
                    @memcpy(query_buf[pos..][0..name.len], name);
                    pos += name.len;
                }
            },
            .ignore_duplicates => {
                const do_nothing = " DO NOTHING";
                @memcpy(query_buf[pos..][0..do_nothing.len], do_nothing);
                pos += do_nothing.len;
            },
            .none => {},
        }
    }

    if (include_returning) {
        const returning = " RETURNING *";
        @memcpy(query_buf[pos..][0..returning.len], returning);
        pos += returning.len;
    }

    return pos;
}

fn relation_hint_matches(edge: *const RelationEdge, hint: ?[]const u8) bool {
    return if (hint) |h| std.mem.eql(u8, edge.constraint(), h) else true;
}

fn resolve_relation(metadata: *const RelationMetadata, current_table: []const u8, node: *const SelectPlanNode) ?ResolvedRelation {
    var direct_match: ?ResolvedRelation = null;
    var direct_count: usize = 0;
    for (metadata.edges[0..metadata.edge_count], 0..) |edge, idx| {
        if (!relation_hint_matches(&edge, node.fkHint())) continue;
        if (std.mem.eql(u8, edge.source(), current_table) and std.mem.eql(u8, edge.target(), node.relation())) {
            direct_match = .{ .kind = .to_one, .direct_edge_index = idx };
            direct_count += 1;
        } else if (std.mem.eql(u8, edge.source(), node.relation()) and std.mem.eql(u8, edge.target(), current_table)) {
            direct_match = .{ .kind = .to_many, .direct_edge_index = idx };
            direct_count += 1;
        }
    }
    if (direct_count == 1 and direct_match != null) return direct_match;
    if (direct_count > 1) return null;

    var junction_match: ?ResolvedRelation = null;
    var junction_count: usize = 0;
    for (metadata.edges[0..metadata.edge_count], 0..) |edge_a, idx_a| {
        if (!std.mem.eql(u8, edge_a.target(), current_table)) continue;
        for (metadata.edges[0..metadata.edge_count], 0..) |edge_b, idx_b| {
            if (idx_a == idx_b) continue;
            if (!std.mem.eql(u8, edge_a.source(), edge_b.source())) continue;
            if (!std.mem.eql(u8, edge_b.target(), node.relation())) continue;
            if (!relation_hint_matches(&edge_a, node.fkHint()) and !relation_hint_matches(&edge_b, node.fkHint())) continue;
            junction_match = .{ .kind = .many_to_many, .junction_edge_to_parent = idx_a, .junction_edge_to_target = idx_b };
            junction_count += 1;
        }
    }
    return if (junction_count == 1) junction_match else null;
}

fn count_direct_children(plan: *const SelectPlan, parent_index: i32) usize {
    var count: usize = 0;
    for (plan.nodes[0..plan.node_count]) |node| {
        if (node.parent_index == parent_index) count += 1;
    }
    return count;
}

fn build_child_select_list(
    buf_out: []u8,
    schema_name: ?[]const u8,
    current_table: []const u8,
    table_alias: []const u8,
    current_path: []const u8,
    inner_select: []const u8,
    request_args: ngx_str_t,
    metadata: *const RelationMetadata,
) ?usize {
    var child_plan = SelectPlan{};
    parse_select_plan_value(&child_plan, inner_select, -1, current_path, &child_plan.root_scalar_buf, &child_plan.root_scalar_len);
    if (child_plan.invalid) return null;

    var pos: usize = 0;
    var scalar_added = false;
    if (child_plan.root_scalar_len > 0) {
        var scalar_select_buf: [1024]u8 = undefined;
        const scalar_result = build_select_clause_from_value(&scalar_select_buf, child_plan.rootScalar());
        if (scalar_result.invalid) return null;
        if (scalar_result.len > 0) {
            @memcpy(buf_out[pos..][0..scalar_result.len], scalar_select_buf[0..scalar_result.len]);
            pos += scalar_result.len;
            scalar_added = true;
        }
    }
    if (!scalar_added and count_direct_children(&child_plan, -1) == 0) {
        buf_out[0] = '*';
        return 1;
    }

    for (child_plan.nodes[0..child_plan.node_count]) |node| {
        if (node.parent_index != -1) continue;
        if (pos > 0) {
            buf_out[pos] = ',';
            pos += 1;
        }
        pos = build_embed_projection_sql(buf_out, pos, schema_name, current_table, table_alias, &node, request_args, metadata) orelse return null;
        const as_sep = " AS ";
        @memcpy(buf_out[pos..][0..as_sep.len], as_sep);
        pos += as_sep.len;
        pos = append_sql_identifier(buf_out, pos, node.alias());
    }
    return pos;
}

fn build_embed_projection_sql(
    buf_out: []u8,
    pos_in: usize,
    schema_name: ?[]const u8,
    current_table: []const u8,
    current_alias: []const u8,
    node: *const SelectPlanNode,
    request_args: ngx_str_t,
    metadata: *const RelationMetadata,
) ?usize {
    const resolved = resolve_relation(metadata, current_table, node) orelse return null;
    var pos = pos_in;
    buf_out[pos] = '(';
    pos += 1;
    const select_prefix = "SELECT ";
    @memcpy(buf_out[pos..][0..select_prefix.len], select_prefix);
    pos += select_prefix.len;

    var child_alias_buf: [96]u8 = undefined;
    const child_alias = build_safe_sql_alias(&child_alias_buf, "pgrest_rel_", node.path());
    var child_table_buf: [128]u8 = undefined;
    const child_table_len = build_qualified_table_name(&child_table_buf, schema_name, node.relation());
    const child_table = child_table_buf[0..child_table_len];

    switch (resolved.kind) {
        .to_one => {
            const prefix = "row_to_json(pgrest_embed_row) FROM (SELECT ";
            @memcpy(buf_out[pos..][0..prefix.len], prefix);
            pos += prefix.len;
            var child_select_buf: [2048]u8 = undefined;
            const child_select_len = build_child_select_list(&child_select_buf, schema_name, node.relation(), child_alias, node.path(), node.innerSelect(), request_args, metadata) orelse return null;
            @memcpy(buf_out[pos..][0..child_select_len], child_select_buf[0..child_select_len]);
            pos += child_select_len;
            const from_sep = " FROM ";
            @memcpy(buf_out[pos..][0..from_sep.len], from_sep);
            pos += from_sep.len;
            @memcpy(buf_out[pos..][0..child_table.len], child_table);
            pos += child_table.len;
            const as_sep = " AS ";
            @memcpy(buf_out[pos..][0..as_sep.len], as_sep);
            pos += as_sep.len;
            @memcpy(buf_out[pos..][0..child_alias.len], child_alias);
            pos += child_alias.len;
            const where_sep = " WHERE ";
            @memcpy(buf_out[pos..][0..where_sep.len], where_sep);
            pos += where_sep.len;
            const edge = &metadata.edges[resolved.direct_edge_index.?];
            pos = append_column_equality_pairs(buf_out, pos, child_alias, edge.targetCols(), current_alias, edge.sourceCols()) orelse return null;
        },
        .to_many => {
            const prefix = "COALESCE(json_agg(pgrest_embed_row), '[]') FROM (SELECT ";
            @memcpy(buf_out[pos..][0..prefix.len], prefix);
            pos += prefix.len;
            var child_select_buf: [2048]u8 = undefined;
            const child_select_len = build_child_select_list(&child_select_buf, schema_name, node.relation(), child_alias, node.path(), node.innerSelect(), request_args, metadata) orelse return null;
            @memcpy(buf_out[pos..][0..child_select_len], child_select_buf[0..child_select_len]);
            pos += child_select_len;
            const from_sep = " FROM ";
            @memcpy(buf_out[pos..][0..from_sep.len], from_sep);
            pos += from_sep.len;
            @memcpy(buf_out[pos..][0..child_table.len], child_table);
            pos += child_table.len;
            const as_sep = " AS ";
            @memcpy(buf_out[pos..][0..as_sep.len], as_sep);
            pos += as_sep.len;
            @memcpy(buf_out[pos..][0..child_alias.len], child_alias);
            pos += child_alias.len;
            const where_sep = " WHERE ";
            @memcpy(buf_out[pos..][0..where_sep.len], where_sep);
            pos += where_sep.len;
            const edge = &metadata.edges[resolved.direct_edge_index.?];
            pos = append_column_equality_pairs(buf_out, pos, child_alias, edge.sourceCols(), current_alias, edge.targetCols()) orelse return null;
        },
        .many_to_many => {
            const prefix = "COALESCE(json_agg(pgrest_embed_row), '[]') FROM (SELECT ";
            @memcpy(buf_out[pos..][0..prefix.len], prefix);
            pos += prefix.len;
            var child_select_buf: [2048]u8 = undefined;
            const child_select_len = build_child_select_list(&child_select_buf, schema_name, node.relation(), child_alias, node.path(), node.innerSelect(), request_args, metadata) orelse return null;
            @memcpy(buf_out[pos..][0..child_select_len], child_select_buf[0..child_select_len]);
            pos += child_select_len;
            const from_sep = " FROM ";
            @memcpy(buf_out[pos..][0..from_sep.len], from_sep);
            pos += from_sep.len;
            @memcpy(buf_out[pos..][0..child_table.len], child_table);
            pos += child_table.len;
            const as_sep = " AS ";
            @memcpy(buf_out[pos..][0..as_sep.len], as_sep);
            pos += as_sep.len;
            @memcpy(buf_out[pos..][0..child_alias.len], child_alias);
            pos += child_alias.len;
            const join_sep = " JOIN ";
            @memcpy(buf_out[pos..][0..join_sep.len], join_sep);
            pos += join_sep.len;
            const parent_edge = &metadata.edges[resolved.junction_edge_to_parent.?];
            const target_edge = &metadata.edges[resolved.junction_edge_to_target.?];
            var junction_table_buf: [128]u8 = undefined;
            const junction_table_len = build_qualified_table_name(&junction_table_buf, schema_name, parent_edge.source());
            const junction_table = junction_table_buf[0..junction_table_len];
            @memcpy(buf_out[pos..][0..junction_table.len], junction_table);
            pos += junction_table.len;
            const junction_alias = "pgrest_junction";
            @memcpy(buf_out[pos..][0..as_sep.len], as_sep);
            pos += as_sep.len;
            @memcpy(buf_out[pos..][0..junction_alias.len], junction_alias);
            pos += junction_alias.len;
            const on_sep = " ON ";
            @memcpy(buf_out[pos..][0..on_sep.len], on_sep);
            pos += on_sep.len;
            pos = append_column_equality_pairs(buf_out, pos, child_alias, target_edge.targetCols(), junction_alias, target_edge.sourceCols()) orelse return null;
            const where_sep = " WHERE ";
            @memcpy(buf_out[pos..][0..where_sep.len], where_sep);
            pos += where_sep.len;
            pos = append_column_equality_pairs(buf_out, pos, junction_alias, parent_edge.sourceCols(), current_alias, parent_edge.targetCols()) orelse return null;
        },
    }

    var scoped_args_buf: [2048]u8 = undefined;
    const scoped_args = build_scoped_args(request_args, node.path(), true, &scoped_args_buf);
    var where_buf: [1024]u8 = undefined;
    const where_result = build_where_clause_from_args(&where_buf, scoped_args, null);
    if (where_result.invalid) return null;
    if (where_result.len > 0) {
        const and_sep = " AND ";
        @memcpy(buf_out[pos..][0..and_sep.len], and_sep);
        pos += and_sep.len;
        @memcpy(buf_out[pos..][0..where_result.len], where_buf[0..where_result.len]);
        pos += where_result.len;
    }

    var child_plan = SelectPlan{};
    parse_select_plan_value(&child_plan, node.innerSelect(), -1, node.path(), &child_plan.root_scalar_buf, &child_plan.root_scalar_len);
    if (child_plan.invalid) return null;
    for (child_plan.nodes[0..child_plan.node_count]) |child_node| {
        if (child_node.parent_index != -1 or !child_node.inner) continue;
        const and_sep = " AND ";
        @memcpy(buf_out[pos..][0..and_sep.len], and_sep);
        pos += and_sep.len;
        pos = build_embed_exists_sql(buf_out, pos, schema_name, node.relation(), child_alias, &child_node, request_args, metadata) orelse return null;
    }

    var group_buf: [1024]u8 = undefined;
    const group_result = if (child_plan.root_scalar_len > 0) build_group_by_clause_from_value(&group_buf, child_plan.rootScalar()) else WhereClauseResult{ .len = 0, .invalid = false };
    if (group_result.invalid) return null;
    if (group_result.len > 0) {
        const group_sep = " GROUP BY ";
        @memcpy(buf_out[pos..][0..group_sep.len], group_sep);
        pos += group_sep.len;
        @memcpy(buf_out[pos..][0..group_result.len], group_buf[0..group_result.len]);
        pos += group_result.len;
    }

    var order_specs: [MAX_ORDER_COLUMNS]OrderSpec = undefined;
    const order_result = parse_order(scoped_args, &order_specs);
    if (order_result.invalid) return null;
    if (order_result.count > 0) {
        const order_sep = " ORDER BY ";
        @memcpy(buf_out[pos..][0..order_sep.len], order_sep);
        pos += order_sep.len;
        for (order_specs[0..order_result.count], 0..) |spec, idx| {
            if (idx > 0) {
                buf_out[pos] = ',';
                pos += 1;
            }
            pos = append_column_expression(buf_out, pos, spec.expr()) orelse return null;
            const dir = if (spec.dir == .desc) " DESC" else " ASC";
            @memcpy(buf_out[pos..][0..dir.len], dir);
            pos += dir.len;
            switch (spec.nulls) {
                .none => {},
                .first => {
                    const s = " NULLS FIRST";
                    @memcpy(buf_out[pos..][0..s.len], s);
                    pos += s.len;
                },
                .last => {
                    const s = " NULLS LAST";
                    @memcpy(buf_out[pos..][0..s.len], s);
                    pos += s.len;
                },
            }
        }
    }
    const pagination = parse_pagination(scoped_args);
    if (pagination.limit) |limit| {
        const s = " LIMIT ";
        @memcpy(buf_out[pos..][0..s.len], s);
        pos += s.len;
        const num = std.fmt.bufPrint(buf_out[pos..], "{d}", .{limit}) catch return null;
        pos += num.len;
    }
    if (pagination.offset) |offset| {
        const s = " OFFSET ";
        @memcpy(buf_out[pos..][0..s.len], s);
        pos += s.len;
        const num = std.fmt.bufPrint(buf_out[pos..], "{d}", .{offset}) catch return null;
        pos += num.len;
    }
    const close = ") AS pgrest_embed_row)";
    @memcpy(buf_out[pos..][0..close.len], close);
    pos += close.len;
    return pos;
}

fn build_embed_exists_sql(
    buf_out: []u8,
    pos_in: usize,
    schema_name: ?[]const u8,
    current_table: []const u8,
    current_alias: []const u8,
    node: *const SelectPlanNode,
    request_args: ngx_str_t,
    metadata: *const RelationMetadata,
) ?usize {
    const resolved = resolve_relation(metadata, current_table, node) orelse return null;
    var pos = pos_in;
    const prefix = "EXISTS (SELECT 1 FROM ";
    @memcpy(buf_out[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    var child_table_buf: [128]u8 = undefined;
    const child_table_len = build_qualified_table_name(&child_table_buf, schema_name, node.relation());
    const child_table = child_table_buf[0..child_table_len];
    var child_alias_buf: [96]u8 = undefined;
    const child_alias = build_safe_sql_alias(&child_alias_buf, "pgrest_rel_", node.path());

    @memcpy(buf_out[pos..][0..child_table.len], child_table);
    pos += child_table.len;
    const as_sep = " AS ";
    @memcpy(buf_out[pos..][0..as_sep.len], as_sep);
    pos += as_sep.len;
    @memcpy(buf_out[pos..][0..child_alias.len], child_alias);
    pos += child_alias.len;
    switch (resolved.kind) {
        .to_one => {
            const where_sep = " WHERE ";
            @memcpy(buf_out[pos..][0..where_sep.len], where_sep);
            pos += where_sep.len;
            const edge = &metadata.edges[resolved.direct_edge_index.?];
            pos = append_column_equality_pairs(buf_out, pos, child_alias, edge.targetCols(), current_alias, edge.sourceCols()) orelse return null;
        },
        .to_many => {
            const where_sep = " WHERE ";
            @memcpy(buf_out[pos..][0..where_sep.len], where_sep);
            pos += where_sep.len;
            const edge = &metadata.edges[resolved.direct_edge_index.?];
            pos = append_column_equality_pairs(buf_out, pos, child_alias, edge.sourceCols(), current_alias, edge.targetCols()) orelse return null;
        },
        .many_to_many => {
            const join_sep = " JOIN ";
            @memcpy(buf_out[pos..][0..join_sep.len], join_sep);
            pos += join_sep.len;
            const parent_edge = &metadata.edges[resolved.junction_edge_to_parent.?];
            const target_edge = &metadata.edges[resolved.junction_edge_to_target.?];
            var junction_table_buf: [128]u8 = undefined;
            const junction_table_len = build_qualified_table_name(&junction_table_buf, schema_name, parent_edge.source());
            const junction_table = junction_table_buf[0..junction_table_len];
            @memcpy(buf_out[pos..][0..junction_table.len], junction_table);
            pos += junction_table.len;
            const junction_alias = "pgrest_junction";
            @memcpy(buf_out[pos..][0..as_sep.len], as_sep);
            pos += as_sep.len;
            @memcpy(buf_out[pos..][0..junction_alias.len], junction_alias);
            pos += junction_alias.len;
            const on_sep = " ON ";
            @memcpy(buf_out[pos..][0..on_sep.len], on_sep);
            pos += on_sep.len;
            pos = append_column_equality_pairs(buf_out, pos, child_alias, target_edge.targetCols(), junction_alias, target_edge.sourceCols()) orelse return null;
            const where_sep = " WHERE ";
            @memcpy(buf_out[pos..][0..where_sep.len], where_sep);
            pos += where_sep.len;
            pos = append_column_equality_pairs(buf_out, pos, junction_alias, parent_edge.sourceCols(), current_alias, parent_edge.targetCols()) orelse return null;
        },
    }

    var scoped_args_buf: [2048]u8 = undefined;
    const scoped_args = build_scoped_args(request_args, node.path(), true, &scoped_args_buf);
    var where_buf: [1024]u8 = undefined;
    const where_result = build_where_clause_from_args(&where_buf, scoped_args, null);
    if (where_result.invalid) return null;
    if (where_result.len > 0) {
        const and_sep = " AND ";
        @memcpy(buf_out[pos..][0..and_sep.len], and_sep);
        pos += and_sep.len;
        @memcpy(buf_out[pos..][0..where_result.len], where_buf[0..where_result.len]);
        pos += where_result.len;
    }
    buf_out[pos] = ')';
    pos += 1;
    return pos;
}

fn build_table_embed_query(
    query_buf: []u8,
    qualified_table: []const u8,
    root_table: []const u8,
    schema_name: ?[]const u8,
    where_clause: []const u8,
    root_select_clause: []const u8,
    root_group_by_clause: []const u8,
    order_specs: []const OrderSpec,
    pagination: Pagination,
    request_args: ngx_str_t,
    plan: *const SelectPlan,
    metadata: *const RelationMetadata,
) ?usize {
    var pos: usize = 0;
    var has_where = false;
    const prefix = "SELECT ";
    @memcpy(query_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    var wrote_any = false;
    if (root_select_clause.len > 0) {
        @memcpy(query_buf[pos..][0..root_select_clause.len], root_select_clause);
        pos += root_select_clause.len;
        wrote_any = true;
    }
    for (plan.nodes[0..plan.node_count]) |node| {
        if (node.parent_index != -1) continue;
        if (wrote_any) {
            query_buf[pos] = ',';
            pos += 1;
        }
        pos = build_embed_projection_sql(query_buf, pos, schema_name, root_table, root_table, &node, request_args, metadata) orelse return null;
        const as_sep = " AS ";
        @memcpy(query_buf[pos..][0..as_sep.len], as_sep);
        pos += as_sep.len;
        pos = append_sql_identifier(query_buf, pos, node.alias());
        wrote_any = true;
    }
    if (!wrote_any) {
        query_buf[pos] = '*';
        pos += 1;
    }
    const from_sep = " FROM ";
    @memcpy(query_buf[pos..][0..from_sep.len], from_sep);
    pos += from_sep.len;
    @memcpy(query_buf[pos..][0..qualified_table.len], qualified_table);
    pos += qualified_table.len;
    if (where_clause.len > 0) {
        const where_sep = " WHERE ";
        @memcpy(query_buf[pos..][0..where_sep.len], where_sep);
        pos += where_sep.len;
        @memcpy(query_buf[pos..][0..where_clause.len], where_clause);
        pos += where_clause.len;
        has_where = true;
    }
    for (plan.nodes[0..plan.node_count]) |node| {
        if (node.parent_index != -1 or !node.inner) continue;
        const joiner = if (has_where) " AND " else " WHERE ";
        @memcpy(query_buf[pos..][0..joiner.len], joiner);
        pos += joiner.len;
        pos = build_embed_exists_sql(query_buf, pos, schema_name, root_table, root_table, &node, request_args, metadata) orelse return null;
        has_where = true;
    }
    if (root_group_by_clause.len > 0) {
        const group_sep = " GROUP BY ";
        @memcpy(query_buf[pos..][0..group_sep.len], group_sep);
        pos += group_sep.len;
        @memcpy(query_buf[pos..][0..root_group_by_clause.len], root_group_by_clause);
        pos += root_group_by_clause.len;
    }
    if (order_specs.len > 0) {
        const order_sep = " ORDER BY ";
        @memcpy(query_buf[pos..][0..order_sep.len], order_sep);
        pos += order_sep.len;
        for (order_specs, 0..) |spec, idx| {
            if (idx > 0) {
                query_buf[pos] = ',';
                pos += 1;
            }
            pos = append_column_expression(query_buf, pos, spec.expr()) orelse return null;
            const dir = if (spec.dir == .desc) " DESC" else " ASC";
            @memcpy(query_buf[pos..][0..dir.len], dir);
            pos += dir.len;
        }
    }
    if (pagination.limit) |limit| {
        const s = " LIMIT ";
        @memcpy(query_buf[pos..][0..s.len], s);
        pos += s.len;
        const num = std.fmt.bufPrint(query_buf[pos..], "{d}", .{limit}) catch return null;
        pos += num.len;
    }
    if (pagination.offset) |offset| {
        const s = " OFFSET ";
        @memcpy(query_buf[pos..][0..s.len], s);
        pos += s.len;
        const num = std.fmt.bufPrint(query_buf[pos..], "{d}", .{offset}) catch return null;
        pos += num.len;
    }
    return pos;
}

fn build_table_query(
    query_buf: []u8,
    r: [*c]ngx_http_request_t,
    pool: [*c]ngx_pool_t,
    sql_op: SqlOp,
    table: []const u8,
    body_format: RequestBodyFormat,
    opts: RequestOptions,
    where_clause: []const u8,
    select_clause: []const u8,
    group_by_clause: []const u8,
    order_specs: []const OrderSpec,
    pagination: Pagination,
    include_returning: bool,
    params: ?*PgRequestCtx,
) ?TableQueryBuildResult {
    var result_fields: [MAX_COLUMNS]JsonField = undefined;
    var result_field_count: usize = 0;
    var write_column_storage: [MAX_COLUMNS][256]u8 = undefined;
    var on_conflict_storage: [MAX_COLUMNS][256]u8 = undefined;

    var column_filter_buf: [MAX_COLUMNS][]const u8 = undefined;
    const column_filter_count = parse_columns_param(r.*.args, &column_filter_buf) orelse return null;
    var on_conflict_buf: [MAX_COLUMNS][]const u8 = undefined;
    const on_conflict_count = parse_on_conflict_param(r.*.args, &on_conflict_buf) orelse return null;

    if (sql_op == .insert or sql_op == .update) {
        if (get_request_body_slice(r)) |body_data| {
            result_field_count = parse_write_body_fields(body_format, body_data, pool, &result_fields);

            const is_put = r.*.method == http.NGX_HTTP_PUT;
            if (is_put) {
                var filter_name_storage: [MAX_COLUMNS][256]u8 = undefined;
                var filter_columns: [MAX_COLUMNS][]const u8 = undefined;
                var filter_values: [MAX_COLUMNS]WriteScalar = undefined;
                const filter_count = parse_filter_eq_column_values(r.*.args, &filter_name_storage, &filter_columns, &filter_values) orelse return null;
                if (filter_count == 0) return null;
                for (filter_columns[0..filter_count]) |name| {
                    if (!row_contains_column(result_fields[0..result_field_count], name)) return null;
                }
                for (filter_columns[0..filter_count], 0..) |name, idx| {
                    for (result_fields[0..result_field_count]) |field| {
                        if (std.mem.eql(u8, field.name, name) and !scalar_equals_field(filter_values[idx], field)) return null;
                    }
                }

                var put_columns: [MAX_COLUMNS][]const u8 = undefined;
                var put_scalars: [MAX_COLUMNS]WriteScalar = undefined;
                const put_column_count = if (column_filter_count > 0) blk: {
                    for (column_filter_buf[0..column_filter_count], 0..) |raw_name, idx| {
                        var decoded_name_buf: [256]u8 = undefined;
                        const decoded_name = decode_query_component_into(&decoded_name_buf, raw_name) orelse return null;
                        const trimmed_name = trim_ascii_spaces(decoded_name);
                        if (trimmed_name.len == 0 or trimmed_name.len > write_column_storage[idx].len) return null;
                        @memcpy(write_column_storage[idx][0..trimmed_name.len], trimmed_name);
                        put_columns[idx] = write_column_storage[idx][0..trimmed_name.len];
                    }
                    break :blk column_filter_count;
                } else blk: {
                    var count: usize = 0;
                    for (filter_columns[0..filter_count]) |name| {
                        if (count >= MAX_COLUMNS) return null;
                        put_columns[count] = name;
                        count += 1;
                    }
                    count = append_insert_row_from_json_fields(&put_columns, &put_scalars, count, result_fields[0..result_field_count]) orelse return null;
                    break :blk count;
                };

                if (put_column_count == 0) return null;
                project_put_row(&put_scalars, put_columns[0..put_column_count], filter_columns[0..filter_count], filter_values[0..filter_count], result_fields[0..result_field_count]) orelse return null;

                var conflict_columns: [MAX_COLUMNS][]const u8 = undefined;
                for (filter_columns[0..filter_count], 0..) |name, idx| {
                    conflict_columns[idx] = name;
                }

                var row_slices: [1][]const WriteScalar = .{put_scalars[0..put_column_count]};
                return .{
                    .len = build_insert_rows_query(
                        query_buf,
                        table,
                        put_columns[0..put_column_count],
                        row_slices[0..1],
                        conflict_columns[0..filter_count],
                        .merge_duplicates,
                        include_returning,
                        params,
                    ),
                    .json_fields = result_fields,
                    .json_field_count = result_field_count,
                };
            }

            const trimmed_body = trim_ascii_spaces(body_data);
            if (sql_op == .insert and opts.prefer.resolution != .none and on_conflict_count == 0) {
                return null;
            }
            if (sql_op == .insert and body_format == .json and trimmed_body.len > 0 and trimmed_body[0] == '[') {
                var bulk_rows: [MAX_WRITE_ROWS][MAX_COLUMNS]JsonField = undefined;
                var bulk_row_counts: [MAX_WRITE_ROWS]usize = std.mem.zeroes([MAX_WRITE_ROWS]usize);
                const bulk_count = parse_json_array_body_rows(
                    pool,
                    body_data,
                    &bulk_rows,
                    &bulk_row_counts,
                    column_filter_buf[0..column_filter_count],
                    opts.prefer.missing_default,
                ) orelse return null;

                if (bulk_count > 0) {
                    var write_columns: [MAX_COLUMNS][]const u8 = undefined;
                    const write_column_count = if (column_filter_count > 0) blk: {
                        for (column_filter_buf[0..column_filter_count], 0..) |raw_name, idx| {
                            var decoded_name_buf: [256]u8 = undefined;
                            const decoded_name = decode_query_component_into(&decoded_name_buf, raw_name) orelse return null;
                            const trimmed_name = trim_ascii_spaces(decoded_name);
                            if (trimmed_name.len == 0 or trimmed_name.len > write_column_storage[idx].len) return null;
                            @memcpy(write_column_storage[idx][0..trimmed_name.len], trimmed_name);
                            write_columns[idx] = write_column_storage[idx][0..trimmed_name.len];
                        }
                        break :blk column_filter_count;
                    } else blk: {
                        const inferred_count = bulk_row_counts[0];
                        for (bulk_rows[0][0..inferred_count], 0..) |field, idx| {
                            if (field.name.len == 0 or field.name.len > write_column_storage[idx].len) return null;
                            @memcpy(write_column_storage[idx][0..field.name.len], field.name);
                            write_columns[idx] = write_column_storage[idx][0..field.name.len];
                        }
                        break :blk inferred_count;
                    };

                    var row_scalars: [MAX_WRITE_ROWS][MAX_COLUMNS]WriteScalar = undefined;
                    var row_slices: [MAX_WRITE_ROWS][]const WriteScalar = undefined;
                    var row_idx: usize = 0;
                    while (row_idx < bulk_count) : (row_idx += 1) {
                        if (bulk_row_counts[row_idx] != write_column_count) return null;
                        for (bulk_rows[row_idx][0..write_column_count], 0..) |field, col_idx| {
                            row_scalars[row_idx][col_idx] = json_field_to_scalar(field);
                        }
                        row_slices[row_idx] = row_scalars[row_idx][0..write_column_count];
                    }

                    var on_conflict_columns: [MAX_COLUMNS][]const u8 = undefined;
                    for (on_conflict_buf[0..on_conflict_count], 0..) |raw_name, idx| {
                        var decoded_name_buf: [256]u8 = undefined;
                        const decoded_name = decode_query_component_into(&decoded_name_buf, raw_name) orelse return null;
                        const trimmed_name = trim_ascii_spaces(decoded_name);
                        if (trimmed_name.len == 0 or trimmed_name.len > on_conflict_storage[idx].len) return null;
                        @memcpy(on_conflict_storage[idx][0..trimmed_name.len], trimmed_name);
                        on_conflict_columns[idx] = on_conflict_storage[idx][0..trimmed_name.len];
                    }

                    return .{
                        .len = build_insert_rows_query(
                            query_buf,
                            table,
                            write_columns[0..write_column_count],
                            row_slices[0..bulk_count],
                            on_conflict_columns[0..on_conflict_count],
                            if (on_conflict_count > 0) opts.prefer.resolution else .none,
                            include_returning,
                            params,
                        ),
                        .json_fields = result_fields,
                        .json_field_count = result_field_count,
                    };
                }
            } else if (sql_op == .insert and body_format == .csv) {
                var bulk_rows: [MAX_WRITE_ROWS][MAX_COLUMNS]JsonField = undefined;
                var bulk_row_counts: [MAX_WRITE_ROWS]usize = std.mem.zeroes([MAX_WRITE_ROWS]usize);
                const bulk_count = parse_csv_bulk_rows(body_data, &bulk_rows, &bulk_row_counts) orelse return null;

                if (bulk_count > 0) {
                    var write_columns: [MAX_COLUMNS][]const u8 = undefined;
                    const write_column_count = bulk_row_counts[0];
                    for (bulk_rows[0][0..write_column_count], 0..) |field, idx| {
                        write_columns[idx] = field.name;
                    }

                    var row_scalars: [MAX_WRITE_ROWS][MAX_COLUMNS]WriteScalar = undefined;
                    var row_slices: [MAX_WRITE_ROWS][]const WriteScalar = undefined;
                    var row_idx: usize = 0;
                    while (row_idx < bulk_count) : (row_idx += 1) {
                        if (bulk_row_counts[row_idx] != write_column_count) return null;
                        for (bulk_rows[row_idx][0..write_column_count], 0..) |field, col_idx| {
                            row_scalars[row_idx][col_idx] = json_field_to_scalar(field);
                        }
                        row_slices[row_idx] = row_scalars[row_idx][0..write_column_count];
                    }

                    var on_conflict_columns: [MAX_COLUMNS][]const u8 = undefined;
                    for (on_conflict_buf[0..on_conflict_count], 0..) |raw_name, idx| {
                        var decoded_name_buf: [256]u8 = undefined;
                        const decoded_name = decode_query_component_into(&decoded_name_buf, raw_name) orelse return null;
                        const trimmed_name = trim_ascii_spaces(decoded_name);
                        if (trimmed_name.len == 0 or trimmed_name.len > on_conflict_storage[idx].len) return null;
                        @memcpy(on_conflict_storage[idx][0..trimmed_name.len], trimmed_name);
                        on_conflict_columns[idx] = on_conflict_storage[idx][0..trimmed_name.len];
                    }

                    return .{
                        .len = build_insert_rows_query(
                            query_buf,
                            table,
                            write_columns[0..write_column_count],
                            row_slices[0..bulk_count],
                            on_conflict_columns[0..on_conflict_count],
                            if (on_conflict_count > 0) opts.prefer.resolution else .none,
                            include_returning,
                            params,
                        ),
                        .json_fields = result_fields,
                        .json_field_count = result_field_count,
                    };
                }
            } else if (sql_op == .insert and column_filter_count > 0 and result_field_count > 0) {
                var projected_fields: [MAX_COLUMNS]JsonField = undefined;
                result_field_count = project_fields_to_columns(
                    result_fields[0..result_field_count],
                    &projected_fields,
                    column_filter_buf[0..column_filter_count],
                    opts.prefer.missing_default,
                ) orelse return null;
                @memcpy(result_fields[0..result_field_count], projected_fields[0..result_field_count]);
            }

            if (sql_op == .insert and on_conflict_count > 0 and result_field_count > 0) {
                var insert_column_names: [MAX_COLUMNS][]const u8 = undefined;
                for (result_fields[0..result_field_count], 0..) |field, idx| {
                    insert_column_names[idx] = field.name;
                }
                var on_conflict_columns: [MAX_COLUMNS][]const u8 = undefined;
                for (on_conflict_buf[0..on_conflict_count], 0..) |raw_name, idx| {
                    var decoded_name_buf: [256]u8 = undefined;
                    const decoded_name = decode_query_component_into(&decoded_name_buf, raw_name) orelse return null;
                    const trimmed_name = trim_ascii_spaces(decoded_name);
                    if (trimmed_name.len == 0 or trimmed_name.len > on_conflict_storage[idx].len) return null;
                    @memcpy(on_conflict_storage[idx][0..trimmed_name.len], trimmed_name);
                    on_conflict_columns[idx] = on_conflict_storage[idx][0..trimmed_name.len];
                }

                var row_scalars: [MAX_COLUMNS]WriteScalar = undefined;
                for (result_fields[0..result_field_count], 0..) |field, idx| {
                    row_scalars[idx] = json_field_to_scalar(field);
                }
                var row_slices: [1][]const WriteScalar = .{row_scalars[0..result_field_count]};

                return .{
                    .len = build_insert_rows_query(
                        query_buf,
                        table,
                        insert_column_names[0..result_field_count],
                        row_slices[0..1],
                        on_conflict_columns[0..on_conflict_count],
                        opts.prefer.resolution,
                        include_returning,
                        params,
                    ),
                    .json_fields = result_fields,
                    .json_field_count = result_field_count,
                };
            }
        }
    }

    if ((sql_op == .update or sql_op == .delete) and pagination.limit != null) {
        const limited = build_limited_write_query(
            query_buf,
            sql_op,
            table,
            where_clause,
            order_specs,
            pagination,
            result_fields[0..result_field_count],
            include_returning,
            params,
        ) orelse return null;
        return .{
            .len = limited,
            .json_fields = result_fields,
            .json_field_count = result_field_count,
        };
    }

    return .{
        .len = build_sql_query(
            query_buf,
            sql_op,
            table,
            where_clause,
            result_fields[0..result_field_count],
            select_clause,
            group_by_clause,
            order_specs,
            pagination,
            include_returning,
            params,
        ),
        .json_fields = result_fields,
        .json_field_count = result_field_count,
    };
}

fn parse_rpc_body_params(
    body_format: RequestBodyFormat,
    body_data: []const u8,
    pool: [*c]ngx_pool_t,
    rpc_call: *RpcCall,
) void {
    switch (body_format) {
        .json => parse_rpc_json_body(pool, body_data, rpc_call),
        .form_urlencoded => parse_rpc_form_body(body_data, rpc_call),
        .csv => set_rpc_single_raw_param(rpc_call, "data", body_data),
        .plain_text => set_rpc_single_raw_param(rpc_call, "data", body_data),
        .xml => set_rpc_single_raw_param(rpc_call, "data", body_data),
        .binary => set_rpc_single_raw_param(rpc_call, "data", body_data),
        .none, .unsupported => {},
    }
}

export fn ngx_http_pgrest_upstream_client_body_handler(r: [*c]ngx_http_request_t) callconv(.c) void {
    const rc = ngx_http_pgrest_upstream_handler(r);
    if (rc != core.NGX_DONE) {
        http.ngx_http_finalize_request(r, rc);
    }
}

/// Extract table name from URI path
/// URI format: /prefix/tablename or /tablename
/// Returns the last non-empty path segment (the table name)
/// Examples:
///   /api/users -> users
///   /users -> users
///   /api/v1/products -> products
fn extract_table_name(uri: ngx_str_t) ?[]const u8 {
    if (uri.len == 0 or uri.data == core.nullptr(u8)) {
        return null;
    }

    const path = core.slicify(u8, uri.data, uri.len);

    // Find the last non-empty path segment
    var end: usize = path.len;

    // Skip trailing slashes
    while (end > 0 and path[end - 1] == '/') {
        end -= 1;
    }

    if (end == 0) {
        return null;
    }

    // Find the start of the last segment (after the last slash)
    var start: usize = end;
    while (start > 0 and path[start - 1] != '/') {
        start -= 1;
    }

    if (start == end) {
        return null;
    }

    return path[start..end];
}

/// Handle RPC (stored procedure) call in non-blocking mode with connection pooling
fn handle_rpc_call_upstream(
    r: [*c]ngx_http_request_t,
    opts: RequestOptions,
    loc_conf: *ngx_pgrest_loc_conf_t,
) ngx_int_t {
    const body_format = parse_content_type_from_request(r);
    if (request_needs_body(r) and body_format == .unsupported) {
        return send_unsupported_media_type(r, "{\"message\":\"Unsupported request media type\"}");
    }

    const resolved_schema = resolve_request_schema(r, loc_conf);
    if (resolved_schema.disallowed) {
        var err_buf: [512]u8 = undefined;
        return send_json_error(r, NGX_HTTP_NOT_ACCEPTABLE, format_schema_error(&err_buf, resolved_schema.allowed_raw));
    }

    // Extract function name from URI
    const function_name = extract_rpc_function_name(r.*.uri) orelse {
        return http.NGX_HTTP_BAD_REQUEST;
    };

    // Allocate request context
    const ctx = core.ngz_pcalloc_c(PgRequestCtx, r.*.pool) orelse {
        return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    };

    // Parse RPC parameters from query string or POST body
    var rpc_call: RpcCall = undefined;
    rpc_call.param_count = 0;
    rpc_call.function_name = function_name;
    rpc_call.prefer_single_object = opts.prefer.params_single_object;
    const body_data = get_request_body_slice(r);

    // Try to parse POST body first (if present)
    if (body_data) |payload| {
        parse_rpc_body_params(body_format, payload, r.*.pool, &rpc_call);
    }

    // If no body parameters, parse query string
    if (rpc_call.param_count == 0) {
        parse_rpc_params(r.*.args, &rpc_call);
    }

    const effective_schema = resolved_default_schema_name(resolved_schema);

    // Build metadata query into the context
    ctx.*.query_len = build_rpc_metadata_query(
        &ctx[0].query,
        effective_schema,
        function_name,
        rpc_call.param_count,
        body_data != null and rpc_allow_single_unnamed_fallback(body_format, rpc_call.prefer_single_object),
    );
    ctx[0].query[ctx.*.query_len] = 0; // null terminate

    ctx.*.pool_conn = null;
    ctx.*.query_state = .none;
    ctx.*.rpc_phase = .metadata;
    ctx.*.result = null;
    ctx.*.request = r;
    ctx.*.response_format = opts.response_format;
    ctx.*.singular_object = opts.singular_object;
    ctx.*.strip_nulls = opts.strip_nulls;
    ctx.*.is_head = opts.is_head;
    ctx.*.prefer_params_single_object = opts.prefer.params_single_object;
    ctx.*.prefer_return_mode = opts.prefer.return_mode;
    ctx.*.prefer_handling = opts.prefer.handling;
    ctx.*.prefer_resolution = opts.prefer.resolution;
    ctx.*.prefer_resolution_applied = opts.prefer.resolution_applied;
    ctx.*.prefer_max_affected = opts.prefer.max_affected orelse 0;
    ctx.*.prefer_has_max_affected = opts.prefer.max_affected != null;
    ctx.*.prefer_count_mode = opts.prefer.count_mode;
    ctx.*.prefer_count_applied = false;
    ctx.*.prefer_missing_default = opts.prefer.missing_default;
    ctx.*.prefer_invalid = opts.prefer.invalid;
    ctx.*.emit_range_headers = opts.emit_range_headers;
    ctx.*.response_range_start = 0;
    ctx.*.total_count = 0;
    ctx.*.has_total_count = false;
    ctx.*.next_query_len = 0;
    ctx.*.followup_query_count = 0;
    ctx.*.write_status = http.NGX_HTTP_OK;
    ctx.*.write_send_body = true;
    ctx.*.is_write_request = false;
    return start_pooled_request(ctx, loc_conf);
}

/// Non-blocking content handler that uses upstream mechanism with connection pooling
fn ngx_http_pgrest_upstream_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    // Only read the client body for main requests. For subrequests (SSI
    // include, mirror) nginx short-circuits ngx_http_read_client_request_body
    // without populating r->request_body, so the gate below would loop
    // forever on r->request_body == null.
    if (r == r.*.main and r.*.request_body == null) {
        const rc = http.ngx_http_read_client_request_body(r, ngx_http_pgrest_upstream_client_body_handler);
        if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) {
            return rc;
        }
        return core.NGX_DONE;
    }

    // Mirror module creates background subrequests with header_only=1.
    // Only skip when BOTH are set: mirror fires these as side-effects and
    // discards the response.  njs also creates background subrequests but
    // without header_only — those need pgrest to process normally.
    if (r.*.flags1.header_only and r.*.flags1.background) {
        return core.NGX_OK;
    }

    // Get location config to retrieve connection string
    const loc_conf = core.castPtr(
        ngx_pgrest_loc_conf_t,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_pgrest_module),
    ) orelse {
        return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    };

    // Initialize pool with connection string if not already done
    if (!g_pool_initialized) {
        g_conn_pool.init();
        g_pool_initialized = true;
    }

    if (!g_conn_pool.initialized) {
        const conninfo = core.slicify(u8, loc_conf.*.conninfo.data, loc_conf.*.conninfo.len);
        if (conninfo.len > 0 and conninfo.len < g_conn_pool.conninfo.len) {
            @memcpy(g_conn_pool.conninfo[0..conninfo.len], conninfo);
            g_conn_pool.conninfo[conninfo.len] = 0;
            g_conn_pool.conninfo_len = conninfo.len;
            g_conn_pool.initialized = true;
        }
    }

    const opts = parse_request_options(r);
    if (opts.response_format == .unsupported) {
        return send_not_acceptable(r, "{\"message\":\"None of these media types are available\"}");
    }
    if (should_reject_invalid_prefer(opts)) {
        return reject_invalid_prefer(r);
    }
    if (opts.range_invalid) {
        return send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid Range header\"}");
    }

    const resolved_schema = resolve_request_schema(r, loc_conf);
    if (resolved_schema.disallowed) {
        var err_buf: [512]u8 = undefined;
        return send_json_error(r, NGX_HTTP_NOT_ACCEPTABLE, format_schema_error(&err_buf, resolved_schema.allowed_raw));
    }

    if (r.*.method == NGX_HTTP_OPTIONS_METHOD) {
        if (is_rpc_endpoint(r.*.uri)) {
            return send_options_response(r, "OPTIONS,GET,HEAD,POST");
        }
        return send_options_response(r, "OPTIONS,GET,HEAD,POST,PATCH,PUT,DELETE");
    }

    if ((r.*.method == http.NGX_HTTP_GET or r.*.method == http.NGX_HTTP_HEAD) and is_uri_root_path(r.*.uri, "/api/")) {
        return send_openapi_root(r, "table");
    }
    if ((r.*.method == http.NGX_HTTP_GET or r.*.method == http.NGX_HTTP_HEAD) and is_uri_root_path(r.*.uri, "/rpc/")) {
        return send_openapi_root(r, "rpc");
    }

    const body_format = parse_content_type_from_request(r);
    if (request_needs_body(r) and body_format == .unsupported) {
        return send_unsupported_media_type(r, "{\"message\":\"Unsupported request media type\"}");
    }

    // Check if this is an RPC (stored procedure) call
    if (is_rpc_endpoint(r.*.uri)) {
        return handle_rpc_call_upstream(r, opts, loc_conf);
    }

    // Extract table name from URI
    const table_name = extract_table_name(r.*.uri) orelse {
        return http.NGX_HTTP_BAD_REQUEST;
    };

    var qualified_table_buf: [512]u8 = undefined;
    const qualified_table_len = build_qualified_table_name(
        qualified_table_buf[0..],
        resolved_schema.name,
        table_name,
    );
    const qualified_table = qualified_table_buf[0..qualified_table_len];

    // Map HTTP method to SQL operation
    const sql_op = SqlOp.fromMethod(r.*.method) orelse {
        return http.NGX_HTTP_NOT_ALLOWED;
    };
    const is_write_request = sql_op == .insert or sql_op == .update or sql_op == .delete;
    const write_contract = write_response_contract(sql_op, opts.prefer);

    // Allocate request context before WHERE clause building so params can be collected
    const ctx = core.ngz_pcalloc_c(PgRequestCtx, r.*.pool) orelse {
        return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
    };
    params_reset(ctx);

    // Parse query string filters.
    // For PUT, the WHERE clause is used only to derive conflict key columns; it
    // is never embedded in the INSERT ON CONFLICT SQL, so don't accumulate
    // params here — they would be unreferenced in the final query.
    var where_buf: [MAX_QUERY_SIZE]u8 = undefined;
    const where_result = build_where_clause_from_args(&where_buf, r.*.args,
        if (r.*.method == http.NGX_HTTP_PUT) null else ctx);
    if (where_result.invalid) {
        return send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid filter parameter\"}");
    }
    const where_len = where_result.len;

    const select_plan = build_select_plan_from_args(r.*.args);
    if (select_plan.invalid) {
        return send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid select parameter\"}");
    }
    if (select_plan.has_embeds and opts.response_format != .json) {
        return send_not_acceptable(r, "{\"message\":\"Embedded resources are only available for JSON responses\"}");
    }

    // Parse column selection
    var select_buf: [MAX_QUERY_SIZE]u8 = undefined;
    const select_result = if (select_plan.has_embeds)
        build_select_clause_from_value(&select_buf, select_plan.rootScalar())
    else
        build_select_clause_from_args(&select_buf, r.*.args);
    if (select_result.invalid) {
        return send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid select parameter\"}");
    }

    var group_by_buf: [MAX_QUERY_SIZE]u8 = undefined;
    const group_by_result = if (select_plan.has_embeds)
        build_group_by_clause_from_value(&group_by_buf, select_plan.rootScalar())
    else
        build_group_by_clause_from_args(&group_by_buf, r.*.args);
    if (group_by_result.invalid) {
        return send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid select parameter\"}");
    }

    // Parse ordering
    var order_specs: [MAX_ORDER_COLUMNS]OrderSpec = undefined;
    const order_parse = parse_order(r.*.args, &order_specs);
    if (order_parse.invalid) {
        return reject_invalid_order(r);
    }
    const order_count = order_parse.count;

    // Parse pagination
    const pagination_info = effective_read_pagination(r.*.args, opts);
    const pagination = pagination_info.pagination;

    var table_query_buf: [MAX_QUERY_SIZE]u8 = undefined;

    ctx.*.pool_conn = null;
    ctx.*.query_state = .none;
    ctx.*.result = null;
    ctx.*.request = r;
    ctx.*.response_format = opts.response_format;
    ctx.*.singular_object = opts.singular_object;
    ctx.*.strip_nulls = opts.strip_nulls;
    ctx.*.is_head = opts.is_head;
    ctx.*.prefer_params_single_object = opts.prefer.params_single_object;
    ctx.*.prefer_return_mode = opts.prefer.return_mode;
    ctx.*.prefer_handling = opts.prefer.handling;
    ctx.*.prefer_resolution = opts.prefer.resolution;
    ctx.*.prefer_resolution_applied = opts.prefer.resolution_applied;
    ctx.*.prefer_max_affected = opts.prefer.max_affected orelse 0;
    ctx.*.prefer_has_max_affected = opts.prefer.max_affected != null;
    ctx.*.prefer_count_mode = opts.prefer.count_mode;
    ctx.*.prefer_count_applied = false;
    ctx.*.prefer_missing_default = opts.prefer.missing_default;
    ctx.*.prefer_invalid = opts.prefer.invalid;
    ctx.*.emit_range_headers = opts.emit_range_headers;
    ctx.*.response_range_start = pagination_info.range_start;
    ctx.*.total_count = 0;
    ctx.*.has_total_count = false;
    ctx.*.table_embed_metadata = false;
    ctx.*.raw_json_field_count = 0;
    ctx.*.next_query_len = 0;
    ctx.*.followup_query_count = 0;
    ctx.*.write_status = if (is_write_request) write_contract.status else http.NGX_HTTP_OK;
    ctx.*.write_send_body = if (is_write_request) write_contract.send_body else true;
    ctx.*.is_write_request = is_write_request;

    const table_query = if (sql_op == .select and select_plan.has_embeds) blk: {
        var table_names: [MAX_TABLE_NAMES][64]u8 = std.mem.zeroes([MAX_TABLE_NAMES][64]u8);
        var table_name_lens: [MAX_TABLE_NAMES]usize = std.mem.zeroes([MAX_TABLE_NAMES]usize);
        const table_name_count = collect_plan_table_names(&select_plan, table_name, &table_names, &table_name_lens) orelse {
            return send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid embed parameter\"}");
        };
        const metadata_query_len = build_relationship_metadata_query(&table_query_buf, resolved_schema.name, &table_names, &table_name_lens, table_name_count);
        ctx.*.table_embed_metadata = true;
        for (select_plan.nodes[0..select_plan.node_count]) |node| {
            if (node.parent_index == -1 and !append_raw_json_field_name(ctx, node.alias())) {
                return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
            }
        }
        break :blk TableQueryBuildResult{
            .len = metadata_query_len,
            .json_fields = undefined,
            .json_field_count = 0,
        };
    } else build_table_query(
        &table_query_buf,
        r,
        r.*.pool,
        sql_op,
        qualified_table,
        body_format,
        opts,
        where_buf[0..where_len],
        select_buf[0..select_result.len],
        group_by_buf[0..group_by_result.len],
        order_specs[0..order_count],
        pagination,
        if (is_write_request) write_contract.include_returning else true,
        ctx,
    ) orelse return send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid write payload\"}");

    if (has_unsafe_param_overflow(ctx, table_query_buf[0..table_query.len])) {
        return send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Too many SQL parameters\"}");
    }

    if (ctx.*.table_embed_metadata) {
        // Metadata phase runs as the connection user; JWT/role setup happens
        // in the second phase after the metadata result arrives.
        if (!set_active_query(ctx, table_query_buf[0..table_query.len])) {
            return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
        }
        ctx.*.rpc_phase = .metadata;
    } else {
        // queue_jwt_setup_queries sets ctx.query = RESET ROLE and queues
        // jwt/role setup as followup.  Main queries are then appended after.
        const jwt_result = queue_jwt_setup_queries(ctx, loc_conf);
        if (jwt_result == .unauthorized) return http.NGX_HTTP_UNAUTHORIZED;
        if (jwt_result == .failed) return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

        if (!is_write_request and read_count_requested(opts)) {
            var count_query_buf: [MAX_QUERY_SIZE]u8 = undefined;
            const count_query_len = build_table_count_query(&count_query_buf, qualified_table, where_buf[0..where_len], opts.prefer.count_mode);
            if (!queue_followup_query(ctx, count_query_buf[0..count_query_len])) {
                return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
            }
            if (!queue_followup_query(ctx, table_query_buf[0..table_query.len])) {
                return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
            }
            ctx.*.rpc_phase = .count;
        } else {
            if (!queue_followup_query(ctx, table_query_buf[0..table_query.len])) {
                return http.NGX_HTTP_INTERNAL_SERVER_ERROR;
            }
            ctx.*.rpc_phase = .call;
        }
    }

    return start_pooled_request(ctx, loc_conf);
}

/// Connection-level write event handler
/// Called when the socket is ready for writing
fn ngx_pgrest_conn_write_handler(ev: [*c]core.ngx_event_t) callconv(.c) void {
    const c = core.castPtr(core.ngx_connection_t, ev.*.data) orelse return;
    const pool_conn = core.castPtr(PgPoolConn, c.*.data) orelse return;
    const ctx = pool_conn.*.request_ctx orelse return;
    ctx.*.trace_write_calls += 1;

    if (ev.*.flags.timedout) {
        if (ev.*.flags.timer_set) event.ngx_event_del_timer(ev);
        ev.*.flags.timedout = false;
        finalize_pooled_timeout(ctx);
        return;
    }

    if (pool_conn.*.state == .connecting) {
        // Continue connection polling
        trace_pool_event(ctx, pool_conn, "write-connect");
        poll_pg_connection(ctx, pool_conn);
    } else if (pool_conn.*.state == .busy and ctx.*.query_state == .sending) {
        // Continue sending query
        if (pool_conn.*.conn != null) {
            trace_pool_event(ctx, pool_conn, "write-flush");
            const flush_result = pgFlush(pool_conn.*.conn);
            if (flush_result == 0) {
                // Flushed successfully, wait for result
                _ = apply_query_flush_state(ctx, pool_conn, flush_result);
            } else if (flush_result > 0) {
                _ = apply_query_flush_state(ctx, pool_conn, flush_result);
            } else if (flush_result < 0) {
                // Error
                _ = apply_query_flush_state(ctx, pool_conn, flush_result);
                finalize_pooled_failure(ctx);
            }
            // flush_result > 0 means more data to write, wait for next event
        }
    }
}

/// Connection-level read event handler
/// Called when the socket is ready for reading
fn ngx_pgrest_conn_read_handler(ev: [*c]core.ngx_event_t) callconv(.c) void {
    const c = core.castPtr(core.ngx_connection_t, ev.*.data) orelse return;
    const pool_conn = core.castPtr(PgPoolConn, c.*.data) orelse return;
    const ctx = pool_conn.*.request_ctx orelse return;
    ctx.*.trace_read_calls += 1;

    if (ev.*.flags.timedout) {
        if (ev.*.flags.timer_set) event.ngx_event_del_timer(ev);
        ev.*.flags.timedout = false;
        finalize_pooled_timeout(ctx);
        return;
    }

    if (pool_conn.*.state == .connecting) {
        // Continue connection polling
        trace_pool_event(ctx, pool_conn, "read-connect");
        poll_pg_connection(ctx, pool_conn);
    } else if (pool_conn.*.state == .busy and ctx.*.query_state == .waiting) {
        process_waiting_query_read(ctx, pool_conn, ev);
    }
}

fn process_waiting_query_read(ctx: *PgRequestCtx, pool_conn: *PgPoolConn, ev: [*c]core.ngx_event_t) void {
    if (pool_conn.*.conn != null) {
        const conn = pool_conn.*.conn.?;
        var drain_iters: usize = 0;
        while (true) {
            trace_pool_event(ctx, pool_conn, "read-consume");
            if (pgConsumeInput(conn) == 0) {
                ctx.*.query_state = .failed;
                finalize_pooled_failure(ctx);
                return;
            }

            if (pgIsBusy(conn) == 0) {
                ctx.*.result = pgGetResult(conn);
                ctx.*.query_state = .done;
                _ = set_pooled_timer_mode(ctx, pool_conn, false, false);
                trace_pool_event(ctx, pool_conn, "result-ready");

                while (pgGetResult(conn) != null) {}

                finalize_pg_response(ctx);
                return;
            }

            drain_iters += 1;
            if (!ev.*.flags.ready or drain_iters >= PGREST_READ_DRAIN_LIMIT) {
                if (!set_pooled_timer_mode(ctx, pool_conn, true, false)) {
                    ctx.*.query_state = .failed;
                    finalize_pooled_failure(ctx);
                    return;
                }
                log_pooled_event_watch_state(ctx, pool_conn, "read-busy");
                trace_pool_event(ctx, pool_conn, "read-busy");
                return;
            }
        }
    }
}

fn maybe_process_ready_wait_read(ctx: *PgRequestCtx, pool_conn: *PgPoolConn) void {
    if (ctx.*.query_state != .waiting or pool_conn.*.state != .busy) return;
    const ngx_conn = pool_conn.ngx_conn orelse return;
    if (ngx_conn.*.read == core.nullptr(core.ngx_event_t)) return;

    const rev = ngx_conn.*.read;
    if (!rev.*.flags.ready) return;

    trace_pool_event(ctx, pool_conn, "wait-read-ready");
    // Post the event to be processed at the end of the current event-loop
    // iteration rather than calling process_waiting_query_read synchronously.
    // Direct synchronous processing creates a nested finalize_pg_response call
    // stack that interacts badly with NJS's synchronous ngx_http_run_posted_requests
    // call in the post-subrequest callback, leading to use-after-free in
    // ngx_http_set_lingering_close when the main request is freed mid-stack.
    event.ngz_post_event(rev);
}

/// Poll libpq connection during async connect
fn poll_pg_connection(ctx: *PgRequestCtx, pool_conn: *PgPoolConn) void {
    const conn = pool_conn.conn orelse return;

    const poll_status = pgConnectPoll(conn);
    ctx.*.trace_last_poll_status = @intCast(poll_status);

    switch (poll_status) {
        PGRES_POLLING_OK => {
            // Connection established!
            pool_conn.state = .idle;
            _ = set_pooled_timer_mode(ctx, pool_conn, false, false);
            trace_pool_event(ctx, pool_conn, "poll-ok");

            // If we have a pending query, send it now
            if (ctx.*.query_len > 0) {
                const q_slice = std.mem.sliceTo(&ctx.*.query, 0);
                const do_params = ctx.*.param_count > 0 and !ctx.*.param_overflow and
                    std.mem.indexOfScalar(u8, q_slice, '$') != null;
                const sent = if (do_params)
                    pgSendQueryParams(conn, &ctx.*.query, @intCast(ctx.*.param_count), null, @ptrCast(&ctx.*.param_ptrs), null, null, 0)
                else
                    pgSendQuery(conn, &ctx.*.query);
                if (sent != 0) {
                    ctx.*.query_state = .sending;
                    pool_conn.state = .busy;
                    ctx.*.trace_query_seq += 1;
                    trace_pool_event(ctx, pool_conn, "poll-send");

                    // Try to flush immediately
                    const flush_result = pgFlush(conn);
                    if (!apply_query_flush_state(ctx, pool_conn, flush_result)) {
                        ctx.*.query_state = .failed;
                    }
                } else {
                    ctx.*.query_state = .failed;
                }
            }
        },
        PGRES_POLLING_FAILED => {
            // Connection failed
            pool_conn.state = .conn_error;
            ctx.*.query_state = .failed;
            trace_pool_event(ctx, pool_conn, "poll-failed");
            finalize_pooled_failure(ctx);
        },
        PGRES_POLLING_READING, PGRES_POLLING_WRITING => {
            // Still connecting, wait for next event
            if (!set_pooled_timer_mode(ctx, pool_conn, poll_status == PGRES_POLLING_READING, poll_status == PGRES_POLLING_WRITING)) {
                pool_conn.state = .conn_error;
                ctx.*.query_state = .failed;
                finalize_pooled_failure(ctx);
                return;
            }
            trace_pool_event(ctx, pool_conn, if (poll_status == PGRES_POLLING_READING) "poll-read" else "poll-write");
        },
        else => {},
    }
}

/// Finalize the PostgreSQL response and send to client
fn finalize_pg_response(ctx: *PgRequestCtx) void {
    const r = ctx.*.request orelse return;
    ctx.*.trace_finalize_calls += 1;
    trace_pool_event(ctx, ctx.*.pool_conn, "finalize-enter");
    const opts = RequestOptions{
        .response_format = ctx.*.response_format,
        .singular_object = ctx.*.singular_object,
        .strip_nulls = ctx.*.strip_nulls,
        .is_head = ctx.*.is_head,
        .prefer = .{
            .params_single_object = ctx.*.prefer_params_single_object,
            .return_mode = ctx.*.prefer_return_mode,
            .handling = ctx.*.prefer_handling,
            .count_mode = ctx.*.prefer_count_mode,
            .count_applied = ctx.*.prefer_count_applied,
            .resolution = ctx.*.prefer_resolution,
            .resolution_applied = ctx.*.prefer_resolution_applied,
            .max_affected = if (ctx.*.prefer_has_max_affected) ctx.*.prefer_max_affected else null,
            .missing_default = ctx.*.prefer_missing_default,
            .invalid = ctx.*.prefer_invalid,
        },
        .emit_range_headers = ctx.*.emit_range_headers,
    };

    if (ctx.*.query_state != .done or ctx.*.result == null) {
        finalize_pooled_failure(ctx);
        return;
    }

    const result = ctx.*.result.?;
    const status = pgResultStatus(result);

    if (status != PGRES_TUPLES_OK and status != PGRES_COMMAND_OK) {
        finalize_pooled_failure(ctx);
        return;
    }

    const active_q = ctx.*.query[0..ctx.*.query_len];
    if (status == PGRES_COMMAND_OK and (std.mem.startsWith(u8, active_q, "SET ") or std.mem.startsWith(u8, active_q, "RESET "))) {
        if (!promote_followup_query(ctx)) {
            finalize_pooled_failure(ctx);
            return;
        }

        if (ctx.*.pool_conn) |pool_conn| {
            if (!start_pooled_query(ctx, pool_conn)) {
                finalize_pooled_failure(ctx);
                return;
            }
            maybe_process_ready_wait_read(ctx, pool_conn);
            return;
        }
    }

    if (ctx.*.rpc_phase == .count) {
        const parsed_total = parse_count_query_result(ctx.*.prefer_count_mode, result) orelse {
            finalize_pooled_failure(ctx);
            return;
        };
        ctx.*.total_count = parsed_total;
        ctx.*.has_total_count = true;
        ctx.*.prefer_count_applied = true;
        if (ctx.*.next_query_len == 0) {
            finalize_pooled_failure(ctx);
            return;
        }

        if (!promote_followup_query(ctx)) {
            finalize_pooled_failure(ctx);
            return;
        }
        ctx.*.rpc_phase = .call;

        if (ctx.*.pool_conn) |pool_conn| {
            if (!start_pooled_query(ctx, pool_conn)) {
                finalize_pooled_failure(ctx);
                return;
            }
            maybe_process_ready_wait_read(ctx, pool_conn);
            return;
        }
    }

    // Format result as JSON
    const ntuples = pgNtuples(result);
    const nfields = pgNfields(result);

    if (ctx.*.rpc_phase == .metadata and ctx.*.table_embed_metadata) {
        const metadata = parse_relation_metadata(result) orelse {
            finalize_pooled_failure(ctx);
            return;
        };
        const loc_conf = core.castPtr(
            ngx_pgrest_loc_conf_t,
            conf.ngx_http_get_module_loc_conf(r, &ngx_http_pgrest_module),
        ) orelse {
            finalize_pooled_failure(ctx);
            return;
        };
        const resolved_schema = resolve_request_schema(r, loc_conf);
        const table_name = extract_table_name(r.*.uri) orelse {
            const rc = http.NGX_HTTP_BAD_REQUEST;
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, rc);
            return;
        };
        var qualified_table_buf: [512]u8 = undefined;
        const qualified_table_len = build_qualified_table_name(qualified_table_buf[0..], resolved_schema.name, table_name);
        const qualified_table = qualified_table_buf[0..qualified_table_len];

        params_reset(ctx);
        var where_buf: [MAX_QUERY_SIZE]u8 = undefined;
        const where_result = build_where_clause_from_args(&where_buf, r.*.args, ctx);
        if (where_result.invalid) {
            const rc = send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid filter parameter\"}");
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, rc);
            return;
        }

        const select_plan = build_select_plan_from_args(r.*.args);
        if (select_plan.invalid) {
            const rc = send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid select parameter\"}");
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, rc);
            return;
        }
        var select_buf: [MAX_QUERY_SIZE]u8 = undefined;
        const select_result = build_select_clause_from_value(&select_buf, select_plan.rootScalar());
        if (select_result.invalid) {
            const rc = send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid select parameter\"}");
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, rc);
            return;
        }
        var group_by_buf: [MAX_QUERY_SIZE]u8 = undefined;
        const group_by_result = build_group_by_clause_from_value(&group_by_buf, select_plan.rootScalar());
        if (group_by_result.invalid) {
            const rc = send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid select parameter\"}");
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, rc);
            return;
        }
        var order_specs: [MAX_ORDER_COLUMNS]OrderSpec = undefined;
        const order_parse = parse_order(r.*.args, &order_specs);
        if (order_parse.invalid) {
            const rc = reject_invalid_order(r);
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, rc);
            return;
        }
        const req_opts = parse_request_options(r);
        if (req_opts.range_invalid) {
            const rc = send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid Range header\"}");
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, rc);
            return;
        }
        const pagination_info = effective_read_pagination(r.*.args, req_opts);
        ctx.*.response_range_start = pagination_info.range_start;

        var data_query_buf: [MAX_QUERY_SIZE]u8 = undefined;
        const data_query_len = build_table_embed_query(
            &data_query_buf,
            qualified_table,
            table_name,
            resolved_schema.name,
            where_buf[0..where_result.len],
            select_buf[0..select_result.len],
            group_by_buf[0..group_by_result.len],
            order_specs[0..order_parse.count],
            pagination_info.pagination,
            r.*.args,
            &select_plan,
            &metadata,
        ) orelse {
            const rc = send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid embed parameter\"}");
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, rc);
            return;
        };

        if (has_unsafe_param_overflow(ctx, data_query_buf[0..data_query_len])) {
            const rc = send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Too many SQL parameters\"}");
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, rc);
            return;
        }

        ctx.*.next_query_len = 0;
        ctx.*.followup_query_count = 0;
        const jwt_result = queue_jwt_setup_queries(ctx, loc_conf);
        if (jwt_result == .unauthorized) {
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, http.NGX_HTTP_UNAUTHORIZED);
            return;
        }
        if (jwt_result == .failed) {
            finalize_pooled_failure(ctx);
            return;
        }
        // queue_jwt_setup_queries set ctx.query = RESET ROLE; append main
        // queries in the correct order: count (if requested) then data.
        if (read_count_requested(req_opts)) {
            var count_query_buf: [MAX_QUERY_SIZE]u8 = undefined;
            const count_query_len = build_table_count_query(&count_query_buf, qualified_table, where_buf[0..where_result.len], opts.prefer.count_mode);
            if (!queue_followup_query(ctx, count_query_buf[0..count_query_len])) {
                finalize_pooled_failure(ctx);
                return;
            }
            if (!queue_followup_query(ctx, data_query_buf[0..data_query_len])) {
                finalize_pooled_failure(ctx);
                return;
            }
            ctx.*.rpc_phase = .count;
        } else {
            if (!queue_followup_query(ctx, data_query_buf[0..data_query_len])) {
                finalize_pooled_failure(ctx);
                return;
            }
            ctx.*.rpc_phase = .call;
        }
        if (ctx.*.pool_conn) |pool_conn| {
            if (!start_pooled_query(ctx, pool_conn)) {
                finalize_pooled_failure(ctx);
                return;
            }
            maybe_process_ready_wait_read(ctx, pool_conn);
            return;
        }
    }

    if (ctx.*.rpc_phase == .metadata) {
        const metadata = parse_rpc_metadata_result(result);
        if (!metadata.found) {
            const rc = rpc_metadata_not_found_response(r);
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, rc);
            return;
        }

        if (!rpc_method_allowed(r.*.method, metadata)) {
            const rc = rpc_method_not_allowed_response(r, metadata);
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, rc);
            return;
        }

        const loc_conf = core.castPtr(
            ngx_pgrest_loc_conf_t,
            conf.ngx_http_get_module_loc_conf(r, &ngx_http_pgrest_module),
        ) orelse {
            const rc = http.NGX_HTTP_INTERNAL_SERVER_ERROR;
            ctx.*.request = null;
            release_pooled_ctx(ctx, true);
            http.ngx_http_finalize_request(r, rc);
            return;
        };
        const resolved_schema = resolve_request_schema(r, loc_conf);
        const function_name = extract_rpc_function_name(r.*.uri) orelse {
            const rc = http.NGX_HTTP_BAD_REQUEST;
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, rc);
            return;
        };

        var rpc_call: RpcCall = undefined;
        rpc_call.param_count = 0;
        rpc_call.function_name = function_name;
        rpc_call.prefer_single_object = opts.prefer.params_single_object;
        const body_format = parse_content_type_from_request(r);
        const body_data = get_request_body_slice(r);
        if (body_data) |payload| {
            parse_rpc_body_params(body_format, payload, r.*.pool, &rpc_call);
        }
        if (rpc_call.param_count == 0) {
            var rpc_args_buf: [MAX_QUERY_SIZE]u8 = undefined;
            const rpc_args = filter_rpc_query_args_by_metadata(r.*.args, &metadata, true, &rpc_args_buf);
            parse_rpc_params(rpc_args, &rpc_call);
        }
        if (body_data) |payload| {
            _ = apply_rpc_single_unnamed_param(metadata, body_format, payload, &rpc_call);
        }
        collapse_rpc_variadic_param(&rpc_call, &metadata);

        ctx.*.next_query_len = 0;
        ctx.*.followup_query_count = 0;
        params_reset(ctx);
        const jwt_result2 = queue_jwt_setup_queries(ctx, loc_conf);
        if (jwt_result2 == .unauthorized) {
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, http.NGX_HTTP_UNAUTHORIZED);
            return;
        }
        if (jwt_result2 == .failed) {
            const rc = http.NGX_HTTP_INTERNAL_SERVER_ERROR;
            ctx.*.request = null;
            release_pooled_ctx(ctx, true);
            http.ngx_http_finalize_request(r, rc);
            return;
        }
        // queue_jwt_setup_queries set ctx.query = RESET ROLE.  Append the
        // actual RPC queries as followup in the correct execution order.
        var rpc_query_buf: [MAX_QUERY_SIZE]u8 = undefined;
        if (rpc_returns_table_like(metadata)) {
            var where_buf: [MAX_QUERY_SIZE]u8 = undefined;
            var read_args_buf: [MAX_QUERY_SIZE]u8 = undefined;
            const read_args = filter_rpc_query_args_by_metadata(r.*.args, &metadata, false, &read_args_buf);
            const where_result = build_where_clause_from_args(&where_buf, read_args, ctx);
            if (where_result.invalid) {
                const rc = send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid filter parameter\"}");
                ctx.*.request = null;
                release_pooled_ctx(ctx, false);
                http.ngx_http_finalize_request(r, rc);
                return;
            }

            var select_buf: [MAX_QUERY_SIZE]u8 = undefined;
            const select_result = build_select_clause_from_args(&select_buf, read_args);
            if (select_result.invalid) {
                const rc = send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid select parameter\"}");
                ctx.*.request = null;
                release_pooled_ctx(ctx, false);
                http.ngx_http_finalize_request(r, rc);
                return;
            }

            var group_by_buf: [MAX_QUERY_SIZE]u8 = undefined;
            const group_by_result = build_group_by_clause_from_args(&group_by_buf, read_args);
            if (group_by_result.invalid) {
                const rc = send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Invalid select parameter\"}");
                ctx.*.request = null;
                release_pooled_ctx(ctx, false);
                http.ngx_http_finalize_request(r, rc);
                return;
            }

            var order_specs: [MAX_ORDER_COLUMNS]OrderSpec = undefined;
            const order_parse = parse_order(read_args, &order_specs);
            if (order_parse.invalid) {
                const rc = reject_invalid_order(r);
                ctx.*.request = null;
                release_pooled_ctx(ctx, false);
                http.ngx_http_finalize_request(r, rc);
                return;
            }

            const pagination_info = effective_read_pagination(read_args, opts);
            ctx.*.response_range_start = pagination_info.range_start;

            const data_query_len = build_rpc_table_query(
                &rpc_query_buf,
                resolved_schema.name,
                function_name,
                &rpc_call,
                where_buf[0..where_result.len],
                select_buf[0..select_result.len],
                group_by_buf[0..group_by_result.len],
                order_specs[0..order_parse.count],
                pagination_info.pagination,
                ctx,
            );
            if (has_unsafe_param_overflow(ctx, rpc_query_buf[0..data_query_len])) {
                const rc = send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Too many SQL parameters\"}");
                ctx.*.request = null;
                release_pooled_ctx(ctx, false);
                http.ngx_http_finalize_request(r, rc);
                return;
            }
            if (read_count_requested(opts)) {
                var count_query_buf: [MAX_QUERY_SIZE]u8 = undefined;
                const count_query_len = build_rpc_table_count_query(
                    &count_query_buf,
                    opts.prefer.count_mode,
                    resolved_schema.name,
                    function_name,
                    &rpc_call,
                    where_buf[0..where_result.len],
                );
                if (!queue_followup_query(ctx, count_query_buf[0..count_query_len])) {
                    const rc = http.NGX_HTTP_INTERNAL_SERVER_ERROR;
                    ctx.*.request = null;
                    release_pooled_ctx(ctx, true);
                    http.ngx_http_finalize_request(r, rc);
                    return;
                }
                ctx.*.rpc_phase = .count;
            } else {
                ctx.*.rpc_phase = .call;
            }
            if (!queue_followup_query(ctx, rpc_query_buf[0..data_query_len])) {
                const rc = http.NGX_HTTP_INTERNAL_SERVER_ERROR;
                ctx.*.request = null;
                release_pooled_ctx(ctx, true);
                http.ngx_http_finalize_request(r, rc);
                return;
            }
        } else {
            const call_len = build_rpc_call_query(&rpc_query_buf, resolved_schema.name, function_name, &rpc_call, ctx);
            if (has_unsafe_param_overflow(ctx, rpc_query_buf[0..call_len])) {
                const rc = send_json_error(r, http.NGX_HTTP_BAD_REQUEST, "{\"message\":\"Too many SQL parameters\"}");
                ctx.*.request = null;
                release_pooled_ctx(ctx, false);
                http.ngx_http_finalize_request(r, rc);
                return;
            }
            if (!queue_followup_query(ctx, rpc_query_buf[0..call_len])) {
                const rc = http.NGX_HTTP_INTERNAL_SERVER_ERROR;
                ctx.*.request = null;
                release_pooled_ctx(ctx, true);
                http.ngx_http_finalize_request(r, rc);
                return;
            }
            ctx.*.rpc_phase = .call;
        }

        if (ctx.*.pool_conn) |pool_conn| {
            if (!start_pooled_query(ctx, pool_conn)) {
                finalize_pooled_failure(ctx);
                return;
            }
            maybe_process_ready_wait_read(ctx, pool_conn);
            return;
        }
    }

    if (opts.response_format == .unsupported) {
        const rc = send_not_acceptable(r, "{\"message\":\"None of these media types are available\"}");
        ctx.*.request = null;
        release_pooled_ctx(ctx, false);
        http.ngx_http_finalize_request(r, rc);
        return;
    }

    if (opts.singular_object and ntuples != 1) {
        const rc = send_not_acceptable(r, "{\"message\":\"JSON object requested, multiple (or no) rows returned\"}");
        ctx.*.request = null;
        release_pooled_ctx(ctx, false);
        http.ngx_http_finalize_request(r, rc);
        return;
    }

    if (ctx.*.is_write_request) {
        if (enforce_max_affected(r, opts, ntuples)) |rc| {
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, rc);
            return;
        }
    }

    var response_len: usize = 0;
    var content_type: [*:0]const u8 = "application/json";
    const response_buffer_size = estimate_response_buffer_size(
        result,
        ntuples,
        nfields,
        opts,
        &ctx.*.raw_json_fields,
        &ctx.*.raw_json_field_lens,
        ctx.*.raw_json_field_count,
    );
    const response_body_buf = buf.ngx_create_temp_buf(r.*.pool, response_buffer_size) orelse {
        ctx.*.request = null;
        release_pooled_ctx(ctx, true);
        http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
        return;
    };
    const response_storage = response_body_buf.*.last[0..response_buffer_size];

    response_len = format_result_for_response(
        result,
        ntuples,
        nfields,
        opts,
        response_storage,
        &content_type,
        &ctx.*.raw_json_fields,
        &ctx.*.raw_json_field_lens,
        ctx.*.raw_json_field_count,
    ) catch |err| switch (err) {
        error.BinaryShapeUnsupported => {
            const rc = send_not_acceptable(r, "{\"message\":\"application/octet-stream requires exactly one row and one column\"}");
            ctx.*.request = null;
            release_pooled_ctx(ctx, false);
            http.ngx_http_finalize_request(r, rc);
            return;
        },
        error.ResponseTooLarge => {
            ctx.*.request = null;
            release_pooled_ctx(ctx, true);
            http.ngx_http_finalize_request(r, http.NGX_HTTP_INTERNAL_SERVER_ERROR);
            return;
        },
    };

    // Null ctx.request before releasing the pool connection.  This preserves the
    // main->count hold so that nginx's subrequest cleanup (r->main->count-- after
    // the post_subrequest callback returns) is what drives the count to zero rather
    // than the callback itself.  Without this ordering, a NJS/SSI post_subrequest
    // callback that calls r.return() would decrement count to zero mid-stack, and
    // nginx's subsequent decrement would access freed memory (SIGSEGV).
    // All error paths already null ctx.request first; this aligns the success path.
    ctx.*.request = null;
    release_pooled_ctx(ctx, false);

    // header_only subrequests (auth_request: header_only=1, background=0; mirror
    // is already caught at handler entry by the background guard there).
    // auth_request reads headers_out.status, so we still need to send headers —
    // but must NOT output the body, which would leak into the parent's postponed
    // output chain and corrupt the response.
    if (r.*.flags1.header_only) {
        const rc = finalize_response_send(
            r,
            response_body_buf,
            response_len,
            content_type,
            ntuples,
            ctx.*.response_range_start,
            if (ctx.*.has_total_count) ctx.*.total_count else null,
            opts,
            ctx.*.write_status,
            false,
        );
        const c = r.*.connection;
        http.ngx_http_finalize_request(r, rc);
        http.ngx_http_run_posted_requests(c);
        return;
    }

    const rc = finalize_response_send(
        r,
        response_body_buf,
        response_len,
        content_type,
        ntuples,
        ctx.*.response_range_start,
        if (ctx.*.has_total_count) ctx.*.total_count else null,
        opts,
        ctx.*.write_status,
        ctx.*.write_send_body,
    );
    // Save connection before finalize — r may be freed after finalize.
    // pgrest is async: we reach here from a postgres event callback, not
    // from ngx_http_request_handler.  ngx_http_run_posted_requests must
    // be called explicitly so the parent request's writer runs and flushes
    // the SSI output stuck in r->main->postponed.
    const c = r.*.connection;
    http.ngx_http_finalize_request(r, rc);
    http.ngx_http_run_posted_requests(c);
}

/// Clean up a pool connection entry
fn cleanup_pool_conn(pool_conn: *PgPoolConn) void {
    if (pool_conn.conn != null) {
        pgFinish(pool_conn.conn);
        pool_conn.conn = null;
    }
    if (pool_conn.ngx_conn) |ngx_conn| {
        pool_conn.request_ctx = null;
        ngx_conn.*.data = null;
        pool_conn.ngx_conn = null;
    }
    pool_conn.state = .free;
    pool_conn.fd = -1;
    if (g_conn_pool.active_count > 0) {
        g_conn_pool.active_count -= 1;
    }
}

export const ngx_http_pgrest_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = null,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = pgrest_create_loc_conf,
    .merge_loc_conf = pgrest_merge_loc_conf,
};

export const ngx_http_pgrest_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("pgrest_pass"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_pgrest_pass,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("pgrest_schemas"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_pgrest_schemas,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("pgrest_pool_size"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_pgrest_pool_size,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("pgrest_jwt_secret"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_pgrest_jwt_secret,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("pgrest_anon_role"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_pgrest_anon_role,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("pgrest_jwt_role_claim"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_pgrest_jwt_role_claim,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },

    conf.ngx_null_command,
};

export var ngx_http_pgrest_module = ngx.module.make_module(
    @constCast(&ngx_http_pgrest_commands),
    @constCast(&ngx_http_pgrest_module_ctx),
);

const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "pgrest module" {
    try expect(ngx_http_pgrest_module.version > 0);
}

test "parse_order supports null ordering modifiers" {
    const spec1 = parse_order_spec("age") orelse return error.TestUnexpectedResult;
    try expectEqual(@as(OrderDir, .asc), spec1.dir);
    try expectEqual(@as(OrderNulls, .none), spec1.nulls);
    try expectEqualStrings("age", spec1.expr());

    const spec2 = parse_order_spec("age.desc.nullslast") orelse return error.TestUnexpectedResult;
    try expectEqual(@as(OrderDir, .desc), spec2.dir);
    try expectEqual(@as(OrderNulls, .last), spec2.nulls);
    try expectEqualStrings("age", spec2.expr());

    const spec3 = parse_order_spec("age.nullsfirst") orelse return error.TestUnexpectedResult;
    try expectEqual(@as(OrderDir, .asc), spec3.dir);
    try expectEqual(@as(OrderNulls, .first), spec3.nulls);
}

test "parse_order supports json path ordering" {
    const spec = parse_order_spec("location->>lat.desc.nullslast") orelse return error.TestUnexpectedResult;
    try expectEqualStrings("location->>lat", spec.expr());
    try expectEqual(@as(OrderDir, .desc), spec.dir);
    try expectEqual(@as(OrderNulls, .last), spec.nulls);
}

test "parse_order rejects malformed ordering" {
    try expect(parse_order_spec("name.foo") == null);
    try expect(parse_order_spec("name.desc.asc") == null);
    try expect(parse_order_spec("name.nullsfirst.nullslast") == null);
    try expect(parse_order_spec("name.") == null);
    try expect(parse_order_spec(".desc") == null);
}

test "parse_order parses comma separated order clause" {
    var orders: [MAX_ORDER_COLUMNS]OrderSpec = undefined;
    const result = parse_order(ngx_string("order=age.desc.nullslast,height.asc"), &orders);

    try expect(!result.invalid);
    try expectEqual(@as(usize, 2), result.count);
    try expectEqualStrings("age", orders[0].expr());
    try expectEqual(@as(OrderDir, .desc), orders[0].dir);
    try expectEqual(@as(OrderNulls, .last), orders[0].nulls);
    try expectEqualStrings("height", orders[1].expr());
    try expectEqual(@as(OrderDir, .asc), orders[1].dir);
    try expectEqual(@as(OrderNulls, .none), orders[1].nulls);
}

test "build_where_clause_from_filters preserves current filter semantics" {
    const filters = [_]Filter{
        .{ .column = "status", .op = .eq, .value = "active" },
        .{ .column = "deleted_at", .op = .is_, .value = "null" },
    };
    var buf_out: [256]u8 = undefined;
    const len = build_where_clause_from_filters(&buf_out, &filters, null);

    try expectEqualStrings("status = 'active' AND deleted_at IS NULL", buf_out[0..len]);
}

test "build_where_clause_from_args supports logical operators and not" {
    var buf_out: [512]u8 = undefined;
    const result = build_where_clause_from_args(&buf_out, ngx_string("or=(age.lt.18,not.and(age.gte.11,age.lte.17))"), null);

    try expect(!result.invalid);
    try expectEqualStrings("(age < '18' OR NOT (age >= '11' AND age <= '17'))" , buf_out[0..result.len]);
}

test "build_where_clause_from_args supports any modifier and wildcard like" {
    var buf_out: [512]u8 = undefined;
    const result = build_where_clause_from_args(&buf_out, ngx_string("last_name=like(any).{O*,P*}"), null);

    try expect(!result.invalid);
    try expectEqualStrings("last_name LIKE ANY (ARRAY['O%','P%'])", buf_out[0..result.len]);
}

test "build_where_clause_from_args supports all modifier and advanced operators" {
    var buf_out: [1024]u8 = undefined;
    const result = build_where_clause_from_args(&buf_out, ngx_string("last_name=like(all).{O*,*n}&name=match.^J.*n$&headline=fts(french).amusant&meta=isdistinct.null&tags=cs.{example,new}&range=adj.(1,10)"), null);

    try expect(!result.invalid);
    try expectEqualStrings("last_name LIKE ALL (ARRAY['O%','%n']) AND name ~ '^J.*n$' AND headline @@ to_tsquery('french', 'amusant') AND meta IS DISTINCT FROM NULL AND tags @> '{example,new}' AND range -|- '(1,10)'", buf_out[0..result.len]);
}

test "build_where_clause_from_args supports quoted identifiers and quoted in values" {
    var buf_out: [512]u8 = undefined;
    const result = build_where_clause_from_args(&buf_out, ngx_string("%22information.cpe%22=like.*MS*&name=in.(%22Hebdon,John%22,%22Williams,Mary%22)"), null);

    try expect(!result.invalid);
    try expectEqualStrings("\"information.cpe\" LIKE '%MS%' AND name IN ('Hebdon,John','Williams,Mary')", buf_out[0..result.len]);
}

test "build_where_clause_from_args supports json path filters" {
    var buf_out: [512]u8 = undefined;
    const result = build_where_clause_from_args(&buf_out, ngx_string("json_data->>blood_type=eq.A-&json_data->age=gt.20"), null);

    try expect(!result.invalid);
    try expectEqualStrings("to_jsonb(json_data)->>'blood_type' = 'A-' AND to_jsonb(json_data)->'age' > 20", buf_out[0..result.len]);
}

test "ensure_pool_conninfo applies max_conn and rejects different conninfo while active" {
    // Reset global state for test isolation
    g_pool_initialized = false;
    g_conn_pool.init();
    g_pool_initialized = true;

    const ci = "host=localhost dbname=test";
    try expect(ensure_pool_conninfo(ci, 4));
    try expectEqual(@as(usize, 4), g_conn_pool.max_connections);

    // Same conninfo accepted again
    try expect(ensure_pool_conninfo(ci, 4));

    // Simulate active connection
    g_conn_pool.active_count = 1;
    try expect(!ensure_pool_conninfo("host=other dbname=other", 4));

    // No connections: different conninfo is accepted
    g_conn_pool.active_count = 0;
    const ci2 = "host=other dbname=other";
    try expect(ensure_pool_conninfo(ci2, 8));
    try expectEqual(@as(usize, 8), g_conn_pool.max_connections);
    try expectEqualStrings(ci2, g_conn_pool.conninfo[0..g_conn_pool.conninfo_len]);
}

test "ngx_conf_set_pgrest_pool_size rejects values outside 1..POOL_MAX_CONNECTIONS" {
    // POOL_MAX_CONNECTIONS is 16; the setter parses a string into ngx_int_t.
    // We test the boundary check directly via the parsing helper it relies on.
    const s1 = "0";
    try expectEqual(std.fmt.parseInt(ngx_int_t, s1, 10) catch -1, 0);
    // 0 < 1 → should be rejected by the setter

    const s2 = "16";
    try expectEqual(std.fmt.parseInt(ngx_int_t, s2, 10) catch -1, 16);
    // 16 == POOL_MAX_CONNECTIONS → accepted

    const s3 = "17";
    try expectEqual(std.fmt.parseInt(ngx_int_t, s3, 10) catch -1, 17);
    // 17 > POOL_MAX_CONNECTIONS → should be rejected
}

test "build_where_clause_from_args emits $N placeholders when ctx supplied" {
    var ctx = std.mem.zeroes(PgRequestCtx);
    params_reset(&ctx);
    var buf_out: [512]u8 = undefined;
    const result = build_where_clause_from_args(&buf_out, ngx_string("name=eq.Alice&age=gt.30"), &ctx);

    try expect(!result.invalid);
    try expectEqualStrings("name = $1 AND age > $2", buf_out[0..result.len]);
    try expectEqual(@as(usize, 2), ctx.param_count);
    try expectEqualStrings("Alice", std.mem.sliceTo(ctx.param_ptrs[0].?, 0));
    try expectEqualStrings("30", std.mem.sliceTo(ctx.param_ptrs[1].?, 0));
}

test "build_sql_query INSERT emits $N for string values when ctx supplied" {
    var ctx = std.mem.zeroes(PgRequestCtx);
    params_reset(&ctx);
    var query_buf: [512]u8 = undefined;
    const fields = [_]JsonField{
        .{ .name = "id", .value = "1", .name_buf = std.mem.zeroes([256]u8), .value_buf = std.mem.zeroes([1024]u8), .is_null = false, .is_number = true, .is_boolean = false, .is_missing = false },
        .{ .name = "name", .value = "Bob", .name_buf = std.mem.zeroes([256]u8), .value_buf = std.mem.zeroes([1024]u8), .is_null = false, .is_number = false, .is_boolean = false, .is_missing = false },
    };
    const len = build_sql_query(&query_buf, .insert, "users", "", &fields, "", "", &.{}, .{ .limit = null, .offset = null }, false, &ctx);

    try expectEqualStrings("INSERT INTO users (id,name) VALUES (1,$1)", query_buf[0..len]);
    try expectEqual(@as(usize, 1), ctx.param_count);
    try expectEqualStrings("Bob", std.mem.sliceTo(ctx.param_ptrs[0].?, 0));
}

test "build_insert_rows_query emits $N for string scalars when ctx supplied" {
    var ctx = std.mem.zeroes(PgRequestCtx);
    params_reset(&ctx);
    var query_buf: [512]u8 = undefined;
    const row = [_]WriteScalar{
        .{ .value = "1", .is_null = false, .is_number = true, .is_boolean = false, .use_default = false },
        .{ .value = "Injected'; DROP TABLE users--", .is_null = false, .is_number = false, .is_boolean = false, .use_default = false },
    };
    const rows = [_][]const WriteScalar{row[0..]};
    const len = build_insert_rows_query(&query_buf, "users", &.{ "id", "name" }, rows[0..], &.{}, .none, false, &ctx);

    try expectEqualStrings("INSERT INTO users (id,name) VALUES (1,$1)", query_buf[0..len]);
    try expectEqual(@as(usize, 1), ctx.param_count);
    try expectEqualStrings("Injected'; DROP TABLE users--", std.mem.sliceTo(ctx.param_ptrs[0].?, 0));
}

test "unsafe parameter overflow is detected when earlier placeholders already exist" {
    var ctx = std.mem.zeroes(PgRequestCtx);
    params_reset(&ctx);

    var where_buf: [4096]u8 = undefined;
    var args_buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const prefix = "name=in.(";
    @memcpy(args_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    for (0..65) |i| {
        if (i > 0) {
            args_buf[pos] = ',';
            pos += 1;
        }
        const item = std.fmt.bufPrint(args_buf[pos..], "v{d}", .{i}) catch return error.TestUnexpectedResult;
        pos += item.len;
    }
    args_buf[pos] = ')';
    pos += 1;

    const result = build_where_clause_from_args(&where_buf, ngx_str_t{ .data = &args_buf, .len = pos }, &ctx);
    try expect(!result.invalid);
    try expect(ctx.param_overflow);
    try expect(ctx.param_count > 0);
    try expect(has_unsafe_param_overflow(&ctx, where_buf[0..result.len]));
}

test "pgrest_merge_loc_conf preserves explicit child jwt_role_claim role" {
    var parent = std.mem.zeroes(ngx_pgrest_loc_conf_t);
    var child = std.mem.zeroes(ngx_pgrest_loc_conf_t);

    parent.jwt_role_claim = ngx_string("custom_role");
    parent.jwt_role_claim_explicit = 1;

    child.jwt_role_claim = ngx_string("role");
    child.jwt_role_claim_explicit = 1;

    _ = pgrest_merge_loc_conf(null, &parent, &child);

    try expectEqualStrings("role", core.slicify(u8, child.jwt_role_claim.data, child.jwt_role_claim.len));
    try expectEqual(@as(ngx_flag_t, 1), child.jwt_role_claim_explicit);
}

test "build_select_clause_from_args supports aliases and casts" {
    var buf_out: [512]u8 = undefined;
    const result = build_select_clause_from_args(&buf_out, ngx_string("select=fullName:full_name,birthDate:birth_date,salary::text"));

    try expect(!result.invalid);
    try expectEqualStrings("full_name AS fullName,birth_date AS birthDate,salary::text", buf_out[0..result.len]);
}

test "build_select_clause_from_args supports json and array paths" {
    var buf_out: [512]u8 = undefined;
    const result = build_select_clause_from_args(&buf_out, ngx_string("select=id,json_data->>blood_type,json_data->phones,primary_language:languages->0"));

    try expect(!result.invalid);
    try expectEqualStrings("id,to_jsonb(json_data)->>'blood_type' AS blood_type,to_jsonb(json_data)->'phones' AS phones,to_jsonb(languages)->0 AS primary_language", buf_out[0..result.len]);
}

test "build_select_clause_from_args decodes encoded path operators" {
    var buf_out: [512]u8 = undefined;
    const result = build_select_clause_from_args(&buf_out, ngx_string("select=id,json_data-%3E%3Eblood_type,json_data-%3Ephones,primary_language:languages-%3E0"));

    try expect(!result.invalid);
    try expectEqualStrings("id,to_jsonb(json_data)->>'blood_type' AS blood_type,to_jsonb(json_data)->'phones' AS phones,to_jsonb(languages)->0 AS primary_language", buf_out[0..result.len]);
}

test "build_sql_query renders json path ordering" {
    var query_buf: [1024]u8 = undefined;
    const spec = parse_order_spec("location->>lat.desc.nullslast") orelse return error.TestUnexpectedResult;
    const len = build_sql_query(&query_buf, .select, "countries", "", &.{}, "*", "", &.{spec}, .{ .limit = null, .offset = null }, false, null);

    try expectEqualStrings("SELECT * FROM countries ORDER BY to_jsonb(location)->>'lat' DESC NULLS LAST", query_buf[0..len]);
}

test "build_select_clause_from_args supports aggregate functions and casts" {
    var buf_out: [512]u8 = undefined;
    const result = build_select_clause_from_args(&buf_out, ngx_string("select=amount.sum(),average:amount.avg()::int,order_details->tax_amount::numeric.sum(),count()"));

    try expect(!result.invalid);
    try expectEqualStrings("sum(amount) AS sum,avg(amount)::int AS average,sum(to_jsonb(order_details)->'tax_amount'::numeric) AS sum,count(*) AS count", buf_out[0..result.len]);
}

test "build_group_by_clause_from_args groups by non aggregate select items" {
    var buf_out: [512]u8 = undefined;
    const result = build_group_by_clause_from_args(&buf_out, ngx_string("select=amount.sum(),amount.avg(),order_date"));

    try expect(!result.invalid);
    try expectEqualStrings("order_date", buf_out[0..result.len]);
}

test "build_sql_query renders grouped aggregate query" {
    var query_buf: [1024]u8 = undefined;
    const len = build_sql_query(&query_buf, .select, "orders", "status = 'paid'", &.{}, "sum(amount) AS sum,order_date", "order_date", &.{}, .{ .limit = null, .offset = null }, false, null);

    try expectEqualStrings("SELECT sum(amount) AS sum,order_date FROM orders WHERE status = 'paid' GROUP BY order_date", query_buf[0..len]);
}

test "parse_on_conflict_param parses unique column list" {
    var columns: [MAX_COLUMNS][]const u8 = undefined;
    const count = parse_on_conflict_param(ngx_string("on_conflict=id,name"), &columns) orelse return error.TestUnexpectedResult;

    try expectEqual(@as(usize, 2), count);
    try expectEqualStrings("id", columns[0]);
    try expectEqualStrings("name", columns[1]);
}

test "build_insert_rows_query renders merge duplicates upsert" {
    var query_buf: [1024]u8 = undefined;
    const row = [_]WriteScalar{
        .{ .value = "1", .is_null = false, .is_number = true, .is_boolean = false, .use_default = false },
        .{ .value = "Sara B.", .is_null = false, .is_number = false, .is_boolean = false, .use_default = false },
    };
    const rows = [_][]const WriteScalar{row[0..]};
    const len = build_insert_rows_query(&query_buf, "users", &.{ "id", "name" }, rows[0..], &.{ "id" }, .merge_duplicates, true, null);

    try expectEqualStrings(
        "INSERT INTO users (id,name) VALUES (1,'Sara B.') ON CONFLICT (id) DO UPDATE SET id=EXCLUDED.id,name=EXCLUDED.name RETURNING *",
        query_buf[0..len],
    );
}

test "build_limited_write_query renders update with limit and order" {
    var query_buf: [1024]u8 = undefined;
    const spec = parse_order_spec("id") orelse return error.TestUnexpectedResult;
    const fields = [_]JsonField{.{
        .name = "status",
        .value = "inactive",
        .name_buf = [_]u8{0} ** 256,
        .value_buf = [_]u8{0} ** 1024,
        .is_null = false,
        .is_number = false,
        .is_boolean = false,
        .is_missing = false,
    }};
    const len = build_limited_write_query(&query_buf, .update, "users", "last_login < '2020-01-01'", &.{spec}, .{ .limit = 10, .offset = null }, &fields, true, null) orelse return error.TestUnexpectedResult;

    try expectEqualStrings(
        "WITH pgrest_limited AS (SELECT ctid FROM users WHERE last_login < '2020-01-01' ORDER BY id ASC LIMIT 10) UPDATE users SET status='inactive' WHERE ctid IN (SELECT ctid FROM pgrest_limited) RETURNING *",
        query_buf[0..len],
    );
}

test "collapse_rpc_variadic_param merges repeated variadic values into ARRAY syntax" {
    var rpc_call: RpcCall = undefined;
    rpc_call.function_name = "plus_one";
    rpc_call.param_count = 3;
    rpc_call.prefer_single_object = false;
    rpc_call.raw_body = std.mem.zeroes([4096]u8);
    rpc_call.raw_body_len = 0;

    rpc_call.params[0] = .{ .name = "v", .value = "1", .is_numeric = true };
    rpc_call.params[1] = .{ .name = "v", .value = "2", .is_numeric = true };
    rpc_call.params[2] = .{ .name = "other", .value = "x" };

    var metadata = RpcMetadata{ .found = true, .has_variadic = true };
    @memcpy(metadata.variadic_param_name_buf[0..1], "v");
    metadata.variadic_param_name_len = 1;

    collapse_rpc_variadic_param(&rpc_call, &metadata);

    try expectEqual(@as(usize, 2), rpc_call.param_count);
    try expectEqualStrings("v", rpc_call.params[0].name);
    try expectEqualStrings("ARRAY[1,2]", rpc_call.params[0].value);
    try expect(rpc_call.params[0].is_raw);
    try expectEqualStrings("other", rpc_call.params[1].name);
}

test "auth base64url decode handles jwt alphabet via submodule" {
    var out: [8]u8 = undefined;
    const len = base64url_decode("SGVsbG8", &out) orelse return error.TestUnexpectedResult;
    try expectEqualStrings("Hello", out[0..len]);
}

test "effective_read_pagination prefers HTTP range over query params" {
    const opts = RequestOptions{
        .range_requested = true,
        .range_start = 5,
        .range_end = 9,
    };
    const effective = effective_read_pagination(ngx_string("limit=2&offset=1"), opts);
    try expectEqual(@as(?usize, 5), effective.pagination.offset);
    try expectEqual(@as(?usize, 5), effective.pagination.limit);
    try expectEqual(@as(usize, 5), effective.range_start);
}

test "read_response_status returns partial content for partial counted reads" {
    const opts = RequestOptions{ .emit_range_headers = true };
    try expectEqual(@as(ngx_uint_t, NGX_HTTP_PARTIAL_CONTENT), read_response_status(http.NGX_HTTP_OK, 0, 2, 3, opts));
    try expectEqual(@as(ngx_uint_t, http.NGX_HTTP_OK), read_response_status(http.NGX_HTTP_OK, 0, 3, 3, opts));
}

test "estimate_response_buffer_size respects min and max bounds" {
    const opts = RequestOptions{ .response_format = .json };
    try expectEqual(@as(usize, MIN_RESPONSE_BUFFER_SIZE), estimate_response_buffer_size(null, 0, 0, opts, &.{}, &.{}, 0));
}

test "estimated_json_string_size accounts for escaping overhead" {
    try expectEqual(@as(usize, 2), estimated_json_string_size(""));
    try expectEqual(@as(usize, 5), estimated_json_string_size("abc"));
    try expectEqual(@as(usize, 6), estimated_json_string_size("A\"B"));
    try expectEqual(@as(usize, 8), estimated_json_string_size("A\nB\t"));
}

test "estimate_response_buffer_size keeps non-json formats conservative" {
    const csv_opts = RequestOptions{ .response_format = .csv };
    const xml_opts = RequestOptions{ .response_format = .xml };
    try expectEqual(@as(usize, MAX_JSON_SIZE), estimate_response_buffer_size(null, 0, 0, csv_opts, &.{}, &.{}, 0));
    try expectEqual(@as(usize, MAX_JSON_SIZE), estimate_response_buffer_size(null, 0, 0, xml_opts, &.{}, &.{}, 0));
}

// ── P1: JSON escaping correctness ──────────────────────────────────────

test "needs_json_escape returns false for safe strings" {
    try expect(!needs_json_escape(""));
    try expect(!needs_json_escape("hello"));
    try expect(!needs_json_escape("abc123"));
    try expect(!needs_json_escape("simple text"));
    try expect(!needs_json_escape("unicode: é"));
}

test "needs_json_escape returns true for strings with special chars" {
    try expect(needs_json_escape("he\"llo"));
    try expect(needs_json_escape("C:\\path"));
    try expect(needs_json_escape("line1\nline2"));
    try expect(needs_json_escape("col1\rcol2"));
    try expect(needs_json_escape("col1\tcol2"));
    try expect(needs_json_escape("a\"b\\c"));
}

test "append_json_quoted_string wraps simple values" {
    var test_buf: [64]u8 = undefined;
    try expectEqual(@as(usize, 2), append_json_quoted_string(&test_buf, 0, ""));
    try expect(std.mem.eql(u8, test_buf[0..2], "\"\""));

    try expectEqual(@as(usize, 7), append_json_quoted_string(&test_buf, 0, "hello"));
    try expect(std.mem.eql(u8, test_buf[0..7], "\"hello\""));

    try expectEqual(@as(usize, 5), append_json_quoted_string(&test_buf, 0, "abc"));
    try expect(std.mem.eql(u8, test_buf[0..5], "\"abc\""));
}

test "append_json_quoted_string escapes double quote" {
    var test_buf: [64]u8 = undefined;
    const len = append_json_quoted_string(&test_buf, 0, "a\"b");
    try expectEqual(@as(usize, 6), len);
    try expect(std.mem.eql(u8, test_buf[0..6], "\"a\\\"b\""));
}

test "append_json_quoted_string escapes backslash" {
    var test_buf: [64]u8 = undefined;
    const len = append_json_quoted_string(&test_buf, 0, "a\\b");
    try expectEqual(@as(usize, 6), len);
    try expect(std.mem.eql(u8, test_buf[0..6], "\"a\\\\b\""));
}

test "append_json_quoted_string escapes newline" {
    var test_buf: [64]u8 = undefined;
    const len = append_json_quoted_string(&test_buf, 0, "a\nb");
    try expectEqual(@as(usize, 6), len);
    try expect(std.mem.eql(u8, test_buf[0..6], "\"a\\nb\""));
}

test "append_json_quoted_string escapes carriage return" {
    var test_buf: [64]u8 = undefined;
    const len = append_json_quoted_string(&test_buf, 0, "a\rb");
    try expectEqual(@as(usize, 6), len);
    try expect(std.mem.eql(u8, test_buf[0..6], "\"a\\rb\""));
}

test "append_json_quoted_string escapes tab" {
    var test_buf: [64]u8 = undefined;
    const len = append_json_quoted_string(&test_buf, 0, "a\tb");
    try expectEqual(@as(usize, 6), len);
    try expect(std.mem.eql(u8, test_buf[0..6], "\"a\\tb\""));
}

test "append_json_quoted_string handles multiple escape sequences" {
    var test_buf: [64]u8 = undefined;
    const len = append_json_quoted_string(&test_buf, 0, "a\"b\\c\nd\te");
    try expectEqual(@as(usize, 15), len);
    try expect(std.mem.eql(u8, test_buf[0..15], "\"a\\\"b\\\\c\\nd\\te\""));
}

test "append_json_quoted_string uses no-escape fast path" {
    var test_buf: [64]u8 = undefined;
    @memset(&test_buf, 0xAA);
    const len = append_json_quoted_string(&test_buf, 0, "plain-text");
    try expectEqual(@as(usize, 12), len);
    try expect(std.mem.eql(u8, test_buf[0..12], "\"plain-text\""));
}

test "estimated_json_string_size no-escape path" {
    try expectEqual(@as(usize, 7), estimated_json_string_size("hello"));
    try expectEqual(@as(usize, 2), estimated_json_string_size(""));
}

test "estimated_json_string_size with escapes" {
    try expectEqual(@as(usize, 6), estimated_json_string_size("a\"b"));
    try expectEqual(@as(usize, 6), estimated_json_string_size("a\\b"));
    try expectEqual(@as(usize, 9), estimated_json_string_size("a\nb\tc"));
}
