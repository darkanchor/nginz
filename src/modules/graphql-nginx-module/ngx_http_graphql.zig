const std = @import("std");
const ngx = @import("ngx");

const buf = ngx.buf;
const core = ngx.core;
const conf = ngx.conf;
const log = ngx.log;
const http = ngx.http;
const cjson = ngx.cjson;
const CJSON = cjson.CJSON;

const NGX_OK = core.NGX_OK;
const NGX_DONE = core.NGX_DONE;
const NGX_AGAIN = core.NGX_AGAIN;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;

const ngx_str_t = core.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_pool_t = core.ngx_pool_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_buf_t = buf.ngx_buf_t;
const ngx_chain_t = buf.ngx_chain_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;

const ngx_string = ngx.string.ngx_string;
const NArray = ngx.array.NArray;

extern var ngx_http_core_module: ngx_module_t;

// Location config for graphql directives
const graphql_loc_conf = extern struct {
    enabled: ngx_flag_t,
    max_depth: ngx_uint_t,
    allow_introspection: ngx_flag_t,
};

// Request context for tracking validation state
const graphql_ctx = extern struct {
    done: ngx_flag_t,
    waiting_body: ngx_flag_t,
    lccf: [*c]graphql_loc_conf,
};

// GraphQL parse result
const ParseResult = struct {
    max_depth: u32,
    has_introspection: bool,
    is_valid: bool,
    error_message: []const u8,
};

// Parse GraphQL query - lightweight tokenizer approach
// Tracks brace depth and detects introspection queries
fn parseGraphQL(query: []const u8) ParseResult {
    var depth: u32 = 0;
    var max_depth: u32 = 0;
    var has_introspection = false;
    var in_string = false;
    var in_comment = false;
    var i: usize = 0;

    while (i < query.len) : (i += 1) {
        const c = query[i];

        // Handle comments (# to end of line)
        if (in_comment) {
            if (c == '\n') {
                in_comment = false;
            }
            continue;
        }

        // Handle strings (skip content inside quotes)
        if (in_string) {
            if (c == '"' and (i == 0 or query[i - 1] != '\\')) {
                in_string = false;
            }
            continue;
        }

        // Start of comment
        if (c == '#') {
            in_comment = true;
            continue;
        }

        // Start of string
        if (c == '"') {
            in_string = true;
            continue;
        }

        // Track brace depth for nesting
        if (c == '{') {
            depth += 1;
            if (depth > max_depth) {
                max_depth = depth;
            }
        } else if (c == '}') {
            if (depth == 0) {
                return ParseResult{
                    .max_depth = max_depth,
                    .has_introspection = has_introspection,
                    .is_valid = false,
                    .error_message = "Unmatched closing brace in query",
                };
            }
            depth -= 1;
        }

        // Check for introspection queries (__schema, __type)
        if (c == '_' and i + 1 < query.len and query[i + 1] == '_') {
            // Check for __schema
            if (i + 8 <= query.len) {
                const token = query[i..@min(i + 8, query.len)];
                if (std.mem.eql(u8, token, "__schema")) {
                    has_introspection = true;
                }
            }
            // Check for __type
            if (i + 6 <= query.len) {
                const token = query[i..@min(i + 6, query.len)];
                if (std.mem.eql(u8, token, "__type")) {
                    has_introspection = true;
                }
            }
        }
    }

    // Check for unclosed string first (may affect brace counting)
    if (in_string) {
        return ParseResult{
            .max_depth = max_depth,
            .has_introspection = has_introspection,
            .is_valid = false,
            .error_message = "Unclosed string in query",
        };
    }

    // Check for unclosed braces
    if (depth != 0) {
        return ParseResult{
            .max_depth = max_depth,
            .has_introspection = has_introspection,
            .is_valid = false,
            .error_message = "Unclosed braces in query",
        };
    }

    return ParseResult{
        .max_depth = max_depth,
        .has_introspection = has_introspection,
        .is_valid = true,
        .error_message = "",
    };
}

// Send GraphQL-formatted error response
fn sendGraphQLError(r: [*c]ngx_http_request_t, message: []const u8) ngx_int_t {
    // Set content type
    const content_type = ngx_string("application/json");
    r.*.headers_out.content_type = content_type;
    r.*.headers_out.content_type_len = content_type.len;
    r.*.headers_out.status = 400;

    // Build GraphQL error response: {"errors":[{"message":"..."}]}
    const prefix = "{\"errors\":[{\"message\":\"";
    const suffix = "\"}]}";
    const response_len = prefix.len + message.len + suffix.len;

    const buf_mem = core.ngx_pnalloc(r.*.pool, response_len) orelse return NGX_ERROR;
    const buf_ptr = core.castPtr(u8, buf_mem) orelse return NGX_ERROR;
    const response_buf = core.slicify(u8, buf_ptr, response_len);

    @memcpy(response_buf[0..prefix.len], prefix);
    @memcpy(response_buf[prefix.len..][0..message.len], message);
    @memcpy(response_buf[prefix.len + message.len ..][0..suffix.len], suffix);

    r.*.headers_out.content_length_n = @intCast(response_len);

    const header_rc = http.ngx_http_send_header(r);
    if (header_rc == NGX_ERROR or header_rc > NGX_OK) {
        return header_rc;
    }
    if (r.*.method == http.NGX_HTTP_HEAD or r.*.flags1.header_only) {
        return NGX_OK;
    }

    // Create output buffer
    const b = core.castPtr(ngx_buf_t, core.ngx_pcalloc(r.*.pool, @sizeOf(ngx_buf_t))) orelse return NGX_ERROR;

    b.*.pos = buf_ptr;
    b.*.last = buf_ptr + response_len;
    b.*.flags.memory = true;
    b.*.flags.last_buf = (r == r.*.main);
    b.*.flags.last_in_chain = true;

    var out: ngx_chain_t = undefined;
    out.buf = b;
    out.next = null;

    return http.ngx_http_output_filter(r, &out);
}

// Read request body and validate GraphQL query
export fn ngx_http_graphql_body_handler(r: [*c]ngx_http_request_t) callconv(.c) void {
    const rctx = core.castPtr(graphql_ctx, r.*.ctx[ngx_http_graphql_module.ctx_index]) orelse {
        http.ngx_http_finalize_request(r, NGX_ERROR);
        return;
    };
    rctx.*.waiting_body = 0;

    const lccf = rctx.*.lccf;

    // Check if request body exists
    if (r.*.request_body == null or r.*.request_body.*.bufs == null) {
        // No body - reject
        _ = sendGraphQLError(r, "Missing request body");
        http.ngx_http_finalize_request(r, NGX_DONE);
        return;
    }

    // Collect request body into a single buffer
    var body_len: usize = 0;
    var chain = r.*.request_body.*.bufs;
    while (chain != null) : (chain = chain.*.next) {
        if (chain.*.buf != null) {
            const b = chain.*.buf;
            body_len += @intFromPtr(b.*.last) - @intFromPtr(b.*.pos);
        }
    }

    if (body_len == 0) {
        _ = sendGraphQLError(r, "Empty request body");
        http.ngx_http_finalize_request(r, NGX_DONE);
        return;
    }

    // Allocate body buffer
    const body_buf = core.ngx_pnalloc(r.*.pool, body_len) orelse {
        http.ngx_http_finalize_request(r, NGX_ERROR);
        return;
    };
    const body_ptr = core.castPtr(u8, body_buf) orelse {
        http.ngx_http_finalize_request(r, NGX_ERROR);
        return;
    };

    // Copy body data
    var offset: usize = 0;
    chain = r.*.request_body.*.bufs;
    while (chain != null) : (chain = chain.*.next) {
        if (chain.*.buf != null) {
            const b = chain.*.buf;
            const chunk_len = @intFromPtr(b.*.last) - @intFromPtr(b.*.pos);
            if (chunk_len > 0) {
                @memcpy(body_ptr[offset..][0..chunk_len], core.slicify(u8, b.*.pos, chunk_len));
                offset += chunk_len;
            }
        }
    }

    const body = ngx_str_t{ .len = body_len, .data = body_ptr };

    // Parse request body as JSON
    var cj = CJSON.init(r.*.pool);
    const json_root = cj.decode(body) catch {
        _ = sendGraphQLError(r, "Invalid JSON body");
        http.ngx_http_finalize_request(r, NGX_DONE);
        return;
    };

    // Extract "query" field from JSON
    const query_node = cjson.cJSON_GetObjectItem(json_root, "query");
    if (query_node == core.nullptr(cjson.cJSON)) {
        _ = sendGraphQLError(r, "Missing query field");
        http.ngx_http_finalize_request(r, NGX_DONE);
        return;
    }

    const query_str = CJSON.stringValue(query_node) orelse {
        _ = sendGraphQLError(r, "Query field must be a string");
        http.ngx_http_finalize_request(r, NGX_DONE);
        return;
    };

    if (query_str.len == 0) {
        _ = sendGraphQLError(r, "Query cannot be empty");
        http.ngx_http_finalize_request(r, NGX_DONE);
        return;
    }

    const query_slice = core.slicify(u8, query_str.data, query_str.len);

    // Parse and validate GraphQL query
    const parse_result = parseGraphQL(query_slice);

    if (!parse_result.is_valid) {
        _ = sendGraphQLError(r, parse_result.error_message);
        http.ngx_http_finalize_request(r, NGX_DONE);
        return;
    }

    // Check depth limit
    const max_allowed_depth: u32 = @intCast(lccf.*.max_depth);
    if (parse_result.max_depth > max_allowed_depth) {
        // Build error message with depth info
        var depth_error: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&depth_error, "Query depth {d} exceeds maximum allowed {d}", .{
            parse_result.max_depth,
            max_allowed_depth,
        }) catch "Query depth exceeds limit";

        _ = sendGraphQLError(r, msg);
        http.ngx_http_finalize_request(r, NGX_DONE);
        return;
    }

    // Check introspection
    if (parse_result.has_introspection and lccf.*.allow_introspection != 1) {
        _ = sendGraphQLError(r, "Introspection queries are disabled");
        http.ngx_http_finalize_request(r, NGX_DONE);
        return;
    }

    // Validation passed - continue to content phase
    rctx.*.done = 1;
    r.*.write_event_handler = http.ngx_http_core_run_phases;
    http.ngx_http_core_run_phases(r);
}

// Access phase handler
export fn ngx_http_graphql_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        graphql_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_graphql_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) {
        return NGX_DECLINED;
    }

    // Only validate POST requests (GraphQL over HTTP spec)
    if (r.*.method != http.NGX_HTTP_POST) {
        return NGX_DECLINED;
    }

    // Get or create request context
    const rctx = http.ngz_http_get_module_ctx(
        graphql_ctx,
        r,
        &ngx_http_graphql_module,
    ) catch return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

    if (rctx.*.done == 1) {
        return NGX_DECLINED;
    }

    rctx.*.waiting_body = 1;
    rctx.*.lccf = lccf;
    r.*.flags1.discard_body = false;

    const rc = http.ngx_http_read_client_request_body(r, ngx_http_graphql_body_handler);
    if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) return rc;
    http.ngx_http_finalize_request(r, NGX_DONE);
    return NGX_DONE;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(graphql_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = conf.NGX_CONF_UNSET;
        p.*.max_depth = conf.NGX_CONF_UNSET_UINT;
        p.*.allow_introspection = conf.NGX_CONF_UNSET;
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
    const prev = core.castPtr(graphql_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(graphql_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.enabled == conf.NGX_CONF_UNSET) {
        c.*.enabled = if (prev.*.enabled == conf.NGX_CONF_UNSET) 0 else prev.*.enabled;
    }

    if (c.*.max_depth == conf.NGX_CONF_UNSET_UINT) {
        c.*.max_depth = if (prev.*.max_depth == conf.NGX_CONF_UNSET_UINT) 10 else prev.*.max_depth;
    }

    if (c.*.allow_introspection == conf.NGX_CONF_UNSET) {
        c.*.allow_introspection = if (prev.*.allow_introspection == conf.NGX_CONF_UNSET) 1 else prev.*.allow_introspection;
    }

    return conf.NGX_CONF_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    // Register access phase handler
    const cmcf = core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    var handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_ACCESS_PHASE].handlers,
    );
    const h = handlers.append() catch return NGX_ERROR;
    h.* = ngx_http_graphql_handler;

    return NGX_OK;
}

export const ngx_http_graphql_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_graphql_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("graphql"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_FLAG,
        .set = conf.ngx_conf_set_flag_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(graphql_loc_conf, "enabled"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("graphql_max_depth"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_num_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(graphql_loc_conf, "max_depth"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("graphql_introspection"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_FLAG,
        .set = conf.ngx_conf_set_flag_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(graphql_loc_conf, "allow_introspection"),
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_graphql_module = ngx.module.make_module(
    @constCast(&ngx_http_graphql_commands),
    @constCast(&ngx_http_graphql_module_ctx),
);

// Tests
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "graphql module" {
    try expect(ngx_http_graphql_module.version > 0);
}

test "parseGraphQL - simple query" {
    const result = parseGraphQL("{ user { name } }");
    try expect(result.is_valid);
    try expectEqual(result.max_depth, 2);
    try expect(!result.has_introspection);
}

test "parseGraphQL - nested query" {
    const result = parseGraphQL("{ user { profile { settings { theme { name } } } } }");
    try expect(result.is_valid);
    try expectEqual(result.max_depth, 5);
    try expect(!result.has_introspection);
}

test "parseGraphQL - introspection __schema" {
    const result = parseGraphQL("{ __schema { types { name } } }");
    try expect(result.is_valid);
    try expect(result.has_introspection);
}

test "parseGraphQL - introspection __type" {
    const result = parseGraphQL("{ __type(name: \"User\") { fields { name } } }");
    try expect(result.is_valid);
    try expect(result.has_introspection);
}

test "parseGraphQL - mixed query with introspection" {
    const result = parseGraphQL("{ user { name } __schema { types { name } } }");
    try expect(result.is_valid);
    try expect(result.has_introspection);
}

test "parseGraphQL - query with comments" {
    const result = parseGraphQL(
        \\# This is a comment
        \\{
        \\  user {
        \\    # Another comment
        \\    name
        \\  }
        \\}
    );
    try expect(result.is_valid);
    try expectEqual(result.max_depth, 2);
}

test "parseGraphQL - query with string literals" {
    const result = parseGraphQL("{ user(filter: \"{ nested: true }\") { name } }");
    try expect(result.is_valid);
    try expectEqual(result.max_depth, 2);
}

test "parseGraphQL - mutation" {
    const result = parseGraphQL("mutation { updateUser(id: \"1\", name: \"Test\") { id } }");
    try expect(result.is_valid);
    try expectEqual(result.max_depth, 2);
}

test "parseGraphQL - unclosed brace" {
    const result = parseGraphQL("{ user { name }");
    try expect(!result.is_valid);
    try expect(std.mem.indexOf(u8, result.error_message, "brace") != null);
}

test "parseGraphQL - unclosed string" {
    const result = parseGraphQL("{ user(name: \"test) { name } }");
    try expect(!result.is_valid);
    try expect(std.mem.indexOf(u8, result.error_message, "string") != null);
}

test "parseGraphQL - empty query" {
    const result = parseGraphQL("");
    try expect(result.is_valid);
    try expectEqual(result.max_depth, 0);
}

test "parseGraphQL - deeply nested" {
    const result = parseGraphQL("{ a { b { c { d { e { f { g { name } } } } } } } }");
    try expect(result.is_valid);
    try expectEqual(result.max_depth, 8);
}

test "parseGraphQL - escaped quote in string" {
    const result = parseGraphQL("{ user(name: \"test\\\"value\") { name } }");
    try expect(result.is_valid);
    try expectEqual(result.max_depth, 2);
}
