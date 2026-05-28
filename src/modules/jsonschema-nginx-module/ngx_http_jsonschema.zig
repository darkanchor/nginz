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

const jsonschema_loc_conf = extern struct {
    enabled: ngx_flag_t,
    schema: ngx_str_t, // inline schema JSON string
    schema_json: [*c]cjson.cJSON,
};

// Request context for tracking validation state
const jsonschema_ctx = extern struct {
    done: ngx_flag_t,
    waiting_body: ngx_flag_t,
    lccf: [*c]jsonschema_loc_conf,
};

// Validation result
const ValidationResult = struct {
    valid: bool,
    error_path: []const u8,
    error_message: []const u8,
};

// Maximum recursion depth to prevent stack overflow
const MAX_VALIDATION_DEPTH = 100;

// Validate JSON value against schema
fn validateValue(
    value: [*c]cjson.cJSON,
    schema: [*c]cjson.cJSON,
    path: []const u8,
    depth: usize,
) ValidationResult {
    // Prevent infinite recursion
    if (depth > MAX_VALIDATION_DEPTH) {
        return ValidationResult{ .valid = false, .error_path = path, .error_message = "schema too deep" };
    }
    if (value == core.nullptr(cjson.cJSON) or schema == core.nullptr(cjson.cJSON)) {
        return ValidationResult{ .valid = true, .error_path = "", .error_message = "" };
    }

    // Check type constraint
    const type_node = cjson.cJSON_GetObjectItem(schema, "type");
    if (type_node != core.nullptr(cjson.cJSON)) {
        if (CJSON.stringValue(type_node)) |type_str| {
            const type_slice = core.slicify(u8, type_str.data, type_str.len);

            if (std.mem.eql(u8, type_slice, "string")) {
                if (cjson.cJSON_IsString(value) != 1) {
                    return ValidationResult{ .valid = false, .error_path = path, .error_message = "must be a string" };
                }
            } else if (std.mem.eql(u8, type_slice, "number")) {
                if (cjson.cJSON_IsNumber(value) != 1) {
                    return ValidationResult{ .valid = false, .error_path = path, .error_message = "must be a number" };
                }
            } else if (std.mem.eql(u8, type_slice, "integer")) {
                if (cjson.cJSON_IsNumber(value) != 1) {
                    return ValidationResult{ .valid = false, .error_path = path, .error_message = "must be an integer" };
                }
                if (CJSON.floatValue(value)) |float_val| {
                    const truncated = @trunc(float_val);
                    if (float_val != truncated) {
                        return ValidationResult{ .valid = false, .error_path = path, .error_message = "must be an integer" };
                    }
                }
            } else if (std.mem.eql(u8, type_slice, "boolean")) {
                if (cjson.cJSON_IsBool(value) != 1) {
                    return ValidationResult{ .valid = false, .error_path = path, .error_message = "must be a boolean" };
                }
            } else if (std.mem.eql(u8, type_slice, "object")) {
                if (cjson.cJSON_IsObject(value) != 1) {
                    return ValidationResult{ .valid = false, .error_path = path, .error_message = "must be an object" };
                }
            } else if (std.mem.eql(u8, type_slice, "array")) {
                if (cjson.cJSON_IsArray(value) != 1) {
                    return ValidationResult{ .valid = false, .error_path = path, .error_message = "must be an array" };
                }
            } else if (std.mem.eql(u8, type_slice, "null")) {
                if (cjson.cJSON_IsNull(value) != 1) {
                    return ValidationResult{ .valid = false, .error_path = path, .error_message = "must be null" };
                }
            }
        }
    }

    // Check required fields for objects
    if (cjson.cJSON_IsObject(value) == 1) {
        const required_node = cjson.cJSON_GetObjectItem(schema, "required");
        if (required_node != core.nullptr(cjson.cJSON) and cjson.cJSON_IsArray(required_node) == 1) {
            var it = CJSON.Iterator.init(required_node);
            while (it.next()) |req| {
                if (CJSON.stringValue(req)) |field_name| {
                    var key_buf: [256]u8 = std.mem.zeroes([256]u8);
                    const key_len = @min(field_name.len, 255);
                    @memcpy(key_buf[0..key_len], core.slicify(u8, field_name.data, key_len));

                    const field_value = cjson.cJSON_GetObjectItem(value, &key_buf);
                    if (field_value == core.nullptr(cjson.cJSON)) {
                        return ValidationResult{ .valid = false, .error_path = path, .error_message = "missing required field" };
                    }
                }
            }
        }

        // Validate properties
        const props_node = cjson.cJSON_GetObjectItem(schema, "properties");
        if (props_node != core.nullptr(cjson.cJSON) and cjson.cJSON_IsObject(props_node) == 1) {
            var prop_it = CJSON.Iterator.init(props_node);
            while (prop_it.next()) |prop_schema| {
                if (prop_schema.*.string != core.nullptr(u8)) {
                    const prop_value = cjson.cJSON_GetObjectItem(value, prop_schema.*.string);
                    if (prop_value != core.nullptr(cjson.cJSON)) {
                        const result = validateValue(prop_value, prop_schema, path, depth + 1);
                        if (!result.valid) {
                            return result;
                        }
                    }
                }
            }
        }
    }

    // Check minLength for strings
    if (cjson.cJSON_IsString(value) == 1) {
        const min_len_node = cjson.cJSON_GetObjectItem(schema, "minLength");
        if (min_len_node != core.nullptr(cjson.cJSON)) {
            if (CJSON.intValue(min_len_node)) |min_len| {
                if (CJSON.stringValue(value)) |str_val| {
                    if (str_val.len < @as(usize, @intCast(min_len))) {
                        return ValidationResult{ .valid = false, .error_path = path, .error_message = "string too short" };
                    }
                }
            }
        }

        const max_len_node = cjson.cJSON_GetObjectItem(schema, "maxLength");
        if (max_len_node != core.nullptr(cjson.cJSON)) {
            if (CJSON.intValue(max_len_node)) |max_len| {
                if (CJSON.stringValue(value)) |str_val| {
                    if (str_val.len > @as(usize, @intCast(max_len))) {
                        return ValidationResult{ .valid = false, .error_path = path, .error_message = "string too long" };
                    }
                }
            }
        }
    }

    // Check minimum/maximum for numbers
    if (cjson.cJSON_IsNumber(value) == 1) {
        const min_node = cjson.cJSON_GetObjectItem(schema, "minimum");
        if (min_node != core.nullptr(cjson.cJSON)) {
            if (CJSON.floatValue(min_node)) |min_val| {
                if (CJSON.floatValue(value)) |val| {
                    if (val < min_val) {
                        return ValidationResult{ .valid = false, .error_path = path, .error_message = "number below minimum" };
                    }
                }
            }
        }

        const max_node = cjson.cJSON_GetObjectItem(schema, "maximum");
        if (max_node != core.nullptr(cjson.cJSON)) {
            if (CJSON.floatValue(max_node)) |max_val| {
                if (CJSON.floatValue(value)) |val| {
                    if (val > max_val) {
                        return ValidationResult{ .valid = false, .error_path = path, .error_message = "number above maximum" };
                    }
                }
            }
        }
    }

    return ValidationResult{ .valid = true, .error_path = "", .error_message = "" };
}

// Send error response
fn sendErrorResponse(r: [*c]ngx_http_request_t, message: []const u8) ngx_int_t {
    // Set content type
    const content_type = ngx_string("application/json");
    r.*.headers_out.content_type = content_type;
    r.*.headers_out.content_type_len = content_type.len;
    r.*.headers_out.status = 400;

    // Build error response
    const error_template = "{\"error\":\"validation_failed\",\"message\":\"";
    const error_suffix = "\"}";
    const response_len = error_template.len + message.len + error_suffix.len;

    const buf_mem = core.ngx_pnalloc(r.*.pool, response_len) orelse return NGX_ERROR;
    const buf_ptr = core.castPtr(u8, buf_mem) orelse return NGX_ERROR;
    const response_buf = core.slicify(u8, buf_ptr, response_len);

    @memcpy(response_buf[0..error_template.len], error_template);
    @memcpy(response_buf[error_template.len..][0..message.len], message);
    @memcpy(response_buf[error_template.len + message.len ..][0..error_suffix.len], error_suffix);

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

// Read request body and validate
export fn ngx_http_jsonschema_body_handler(r: [*c]ngx_http_request_t) callconv(.c) void {
    const rctx = core.castPtr(jsonschema_ctx, r.*.ctx[ngx_http_jsonschema_module.ctx_index]) orelse {
        http.ngx_http_finalize_request(r, NGX_ERROR);
        return;
    };
    rctx.*.waiting_body = 0;

    // Check if request body exists
    if (r.*.request_body == null or r.*.request_body.*.bufs == null) {
        rctx.*.done = 1;
        r.*.write_event_handler = http.ngx_http_core_run_phases;
        http.ngx_http_core_run_phases(r);
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
        rctx.*.done = 1;
        r.*.write_event_handler = http.ngx_http_core_run_phases;
        http.ngx_http_core_run_phases(r);
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
    const json_value = cj.decode(body) catch {
        _ = sendErrorResponse(r, "invalid JSON");
        http.ngx_http_finalize_request(r, NGX_DONE);
        return;
    };

    // Validate
    const result = validateValue(json_value, rctx.*.lccf.*.schema_json, "$", 0);
    if (!result.valid) {
        _ = sendErrorResponse(r, result.error_message);
        http.ngx_http_finalize_request(r, NGX_DONE);
        return;
    }

    // Validation passed - continue to content phase
    rctx.*.done = 1;
    //    http.ngx_http_finalize_request(r, NGX_DECLINED);
    r.*.write_event_handler = http.ngx_http_core_run_phases;
    http.ngx_http_core_run_phases(r);
}

// Access phase handler
export fn ngx_http_jsonschema_access_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        jsonschema_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_jsonschema_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) {
        return NGX_DECLINED;
    }

    // Only validate POST/PUT/PATCH requests with body
    if (r.*.method != http.NGX_HTTP_POST and
        r.*.method != http.NGX_HTTP_PUT and
        r.*.method != http.NGX_HTTP_PATCH)
    {
        return NGX_DECLINED;
    }

    // Check content-type is JSON
    if (r.*.headers_in.content_type != null) {
        const ct = r.*.headers_in.content_type.*.value;
        const ct_slice = core.slicify(u8, ct.data, ct.len);
        if (std.mem.indexOf(u8, ct_slice, "application/json") == null) {
            return NGX_DECLINED;
        }
    } else {
        return NGX_DECLINED;
    }

    const rctx = http.ngz_http_get_module_ctx(
        jsonschema_ctx,
        r,
        &ngx_http_jsonschema_module,
    ) catch return http.NGX_HTTP_FORBIDDEN;
    if (rctx.*.done == 1) {
        return NGX_DECLINED;
    }
    rctx.*.waiting_body = 1;
    rctx.*.lccf = lccf;
    r.*.flags1.discard_body = false;
    const rc = http.ngx_http_read_client_request_body(r, ngx_http_jsonschema_body_handler);
    if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) return rc;
    http.ngx_http_finalize_request(r, NGX_DONE);
    return NGX_DONE;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(jsonschema_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = conf.NGX_CONF_UNSET;
        p.*.schema = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
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
    const prev = core.castPtr(jsonschema_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(jsonschema_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (c.*.enabled == conf.NGX_CONF_UNSET) {
        c.*.enabled = if (prev.*.enabled == conf.NGX_CONF_UNSET) 0 else prev.*.enabled;
    }

    if (c.*.schema.len == 0 and prev.*.schema.len > 0) {
        c.*.schema = prev.*.schema;
    }

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_schema(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(jsonschema_loc_conf, loc)) |lccf| {
        lccf.*.enabled = 1;
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            lccf.*.schema = arg.*;
            var cj = CJSON.init(cf.*.pool);
            lccf.*.schema_json = cj.decode(lccf.*.schema) catch {
                return conf.NGX_CONF_ERROR;
            };
        }
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
    h.* = ngx_http_jsonschema_access_handler;

    return NGX_OK;
}

export const ngx_http_jsonschema_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_jsonschema_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("jsonschema"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_schema,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_jsonschema_module = ngx.module.make_module(
    @constCast(&ngx_http_jsonschema_commands),
    @constCast(&ngx_http_jsonschema_module_ctx),
);

// Tests
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

// Re-export test helper functions from ngx (like ngx_cjson does)
const ngx_log_init = ngx.core.ngx_log_init;
const ngx_create_pool = ngx.core.ngx_create_pool;
const ngx_destroy_pool = ngx.core.ngx_destroy_pool;

test "jsonschema module" {}

// Helper to create a test pool for JSON operations
fn createTestPool() [*c]core.ngx_pool_t {
    const leg = ngx_log_init(core.c_str(""), core.c_str(""));
    return ngx_create_pool(4096, leg);
}

// Test basic JSON schema validation with CJSON
test "validateValue - string type validation" {
    const pool = createTestPool();
    defer ngx_destroy_pool(pool);

    var cj = CJSON.init(pool);

    // Create a schema for string type
    const schema_json_str = "{\"type\": \"string\"}";
    const schema = try cj.decode(ngx_string(schema_json_str));

    // Create a valid string value
    const valid_json_str = "\"Hello World\"";
    const valid_value = try cj.decode(ngx_string(valid_json_str));

    const result = validateValue(valid_value, schema, "$", 0);
    try expect(result.valid == true);
}

// Test CJSON query and iteration
test "cjson usage - basic parse and query" {
    const pool = createTestPool();
    defer ngx_destroy_pool(pool);

    var cj = CJSON.init(pool);

    const json_str = "{\"name\": \"John\", \"age\": 30, \"active\": true}";
    const parsed = try cj.decode(ngx_string(json_str));

    // Query string field
    if (CJSON.query(parsed, "$.name")) |name_node| {
        if (CJSON.stringValue(name_node)) |name_str| {
            try expect(name_str.len == 4);
            try expect(std.mem.eql(u8, core.slicify(u8, name_str.data, name_str.len), "John"));
        }
    }

    // Query number field
    if (CJSON.query(parsed, "$.age")) |age_node| {
        if (CJSON.intValue(age_node)) |age_val| {
            try expect(age_val == 30);
        }
    }

    // Query boolean field
    if (CJSON.query(parsed, "$.active")) |active_node| {
        if (CJSON.boolValue(active_node)) |active_val| {
            try expect(active_val == true);
        }
    }
}

// Test CJSON array iteration
test "cjson usage - array iteration" {
    const pool = createTestPool();
    defer ngx_destroy_pool(pool);

    var cj = CJSON.init(pool);

    const json_str = "[1, 2, 3, 4, 5]";
    const parsed = try cj.decode(ngx_string(json_str));

    var it = CJSON.Iterator.init(parsed);
    var sum: i64 = 0;
    while (it.next()) |item| {
        if (CJSON.intValue(item)) |val| {
            sum += val;
        }
    }
    try expect(sum == 15);
}

// Test CJSON object iteration
test "cjson usage - object iteration" {
    const pool = createTestPool();
    defer ngx_destroy_pool(pool);

    var cj = CJSON.init(pool);

    const json_str = "{\"a\": 1, \"b\": 2, \"c\": 3}";
    const parsed = try cj.decode(ngx_string(json_str));

    var it = CJSON.Iterator.init(parsed);
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }
    try expect(count == 3);
}

// Test CJSON recursive iteration
test "cjson usage - recursive iteration" {
    const pool = createTestPool();
    defer ngx_destroy_pool(pool);

    var cj = CJSON.init(pool);

    const json_str = "{\"a\": {\"x\": 100}, \"b\": [1, 2, 3], \"c\": {\"x\": 1, \"y\": 42}}";
    const parsed = try cj.decode(ngx_string(json_str));

    var rt = CJSON.RecursiveIterator.init(parsed);
    var node_count: i32 = 0;
    while (rt.next()) |_| {
        node_count += 1;
    }
    try expect(node_count == 10);
}

// Test CJSON encode and decode
test "cjson usage - encode and decode" {
    const pool = createTestPool();
    defer ngx_destroy_pool(pool);

    var cj = CJSON.init(pool);

    // Create JSON object
    const obj = cjson.cJSON_CreateObject(&cj.alloc);
    _ = cjson.cJSON_AddStringToObject(obj, "name", "John", &cj.alloc);
    _ = cjson.cJSON_AddNumberToObject(obj, "age", 30, &cj.alloc);

    // Encode
    const encoded = try cj.encode(obj);
    try expect(encoded.len > 0);

    // Decode back
    const decoded = try cj.decode(encoded);
    const name = CJSON.query(decoded, "$.name").?;
    if (CJSON.stringValue(name)) |name_str| {
        try expect(std.mem.eql(u8, core.slicify(u8, name_str.data, name_str.len), "John"));
    }

    const age = CJSON.query(decoded, "$.age").?;
    if (CJSON.intValue(age)) |age_val| {
        try expect(age_val == 30);
    }
}

// Test nested object validation
test "validateValue - nested object validation" {
    const pool = createTestPool();
    defer ngx_destroy_pool(pool);

    var cj = CJSON.init(pool);

    const schema_json_str = "{\"type\": \"object\", \"properties\": {\"user\": {\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}, \"age\": {\"type\": \"number\"}}}}}";
    const schema = try cj.decode(ngx_string(schema_json_str));

    // Valid nested object
    const valid_json_str = "{\"user\": {\"name\": \"John\", \"age\": 30}}";
    const valid_value = try cj.decode(ngx_string(valid_json_str));
    const valid_result = validateValue(valid_value, schema, "$", 0);
    try expect(valid_result.valid == true);

    // Invalid: wrong type in nested field
    const invalid_json_str = "{\"user\": {\"name\": \"John\", \"age\": \"thirty\"}}";
    const invalid_value = try cj.decode(ngx_string(invalid_json_str));
    const invalid_result = validateValue(invalid_value, schema, "$", 0);
    try expect(invalid_result.valid == false);
    try expect(std.mem.eql(u8, invalid_result.error_message, "must be a number"));
}

// Test required fields validation
test "validateValue - required fields validation" {
    const pool = createTestPool();
    defer ngx_destroy_pool(pool);

    var cj = CJSON.init(pool);

    const schema_json_str = "{\"type\": \"object\", \"required\": [\"name\", \"email\"]}";
    const schema = try cj.decode(ngx_string(schema_json_str));

    // Valid: all required fields present
    const valid_json_str = "{\"name\": \"John\", \"email\": \"john@example.com\"}";
    const valid_value = try cj.decode(ngx_string(valid_json_str));
    const valid_result = validateValue(valid_value, schema, "$", 0);
    try expect(valid_result.valid == true);

    // Invalid: missing required field
    const invalid_json_str = "{\"name\": \"John\"}";
    const invalid_value = try cj.decode(ngx_string(invalid_json_str));
    const invalid_result = validateValue(invalid_value, schema, "$", 0);
    try expect(invalid_result.valid == false);
    try expect(std.mem.eql(u8, invalid_result.error_message, "missing required field"));
}

// Test minLength validation
test "validateValue - minLength validation" {
    const pool = createTestPool();
    defer ngx_destroy_pool(pool);

    var cj = CJSON.init(pool);

    const schema_json_str = "{\"type\": \"string\", \"minLength\": 5}";
    const schema = try cj.decode(ngx_string(schema_json_str));

    // Valid: string >= 5 chars
    const valid_json_str = "\"Hello\"";
    const valid_value = try cj.decode(ngx_string(valid_json_str));
    const valid_result = validateValue(valid_value, schema, "$", 0);
    try expect(valid_result.valid == true);

    // Invalid: string < 5 chars
    const invalid_json_str = "\"Hi\"";
    const invalid_value = try cj.decode(ngx_string(invalid_json_str));
    const invalid_result = validateValue(invalid_value, schema, "$", 0);
    try expect(invalid_result.valid == false);
    try expect(std.mem.eql(u8, invalid_result.error_message, "string too short"));
}

// Test maxLength validation
test "validateValue - maxLength validation" {
    const pool = createTestPool();
    defer ngx_destroy_pool(pool);

    var cj = CJSON.init(pool);

    const schema_json_str = "{\"type\": \"string\", \"maxLength\": 10}";
    const schema = try cj.decode(ngx_string(schema_json_str));

    // Valid: string <= 10 chars
    const valid_json_str = "\"Hello\"";
    const valid_value = try cj.decode(ngx_string(valid_json_str));
    const valid_result = validateValue(valid_value, schema, "$", 0);
    try expect(valid_result.valid == true);

    // Invalid: string > 10 chars
    const invalid_json_str = "\"This is too long\"";
    const invalid_value = try cj.decode(ngx_string(invalid_json_str));
    const invalid_result = validateValue(invalid_value, schema, "$", 0);
    try expect(invalid_result.valid == false);
    try expect(std.mem.eql(u8, invalid_result.error_message, "string too long"));
}

// Test minimum validation
test "validateValue - minimum validation" {
    const pool = createTestPool();
    defer ngx_destroy_pool(pool);

    var cj = CJSON.init(pool);

    const schema_json_str = "{\"type\": \"number\", \"minimum\": 18}";
    const schema = try cj.decode(ngx_string(schema_json_str));

    // Valid: number >= 18
    const valid_json_str = "25";
    const valid_value = try cj.decode(ngx_string(valid_json_str));
    const valid_result = validateValue(valid_value, schema, "$", 0);
    try expect(valid_result.valid == true);

    // Invalid: number < 18
    const invalid_json_str = "15";
    const invalid_value = try cj.decode(ngx_string(invalid_json_str));
    const invalid_result = validateValue(invalid_value, schema, "$", 0);
    try expect(invalid_result.valid == false);
    try expect(std.mem.eql(u8, invalid_result.error_message, "number below minimum"));
}

// Test maximum validation
test "validateValue - maximum validation" {
    const pool = createTestPool();
    defer ngx_destroy_pool(pool);

    var cj = CJSON.init(pool);

    const schema_json_str = "{\"type\": \"number\", \"maximum\": 100}";
    const schema = try cj.decode(ngx_string(schema_json_str));

    // Valid: number <= 100
    const valid_json_str = "50";
    const valid_value = try cj.decode(ngx_string(valid_json_str));
    const valid_result = validateValue(valid_value, schema, "$", 0);
    try expect(valid_result.valid == true);

    // Invalid: number > 100
    const invalid_json_str = "150";
    const invalid_value = try cj.decode(ngx_string(invalid_json_str));
    const invalid_result = validateValue(invalid_value, schema, "$", 0);
    try expect(invalid_result.valid == false);
    try expect(std.mem.eql(u8, invalid_result.error_message, "number above maximum"));
}

// Test null pointer safety
test "validateValue - null pointer safety" {
    const pool = createTestPool();
    defer ngx_destroy_pool(pool);

    var cj = CJSON.init(pool);

    const schema_json_str = "{\"type\": \"string\"}";
    const schema = try cj.decode(ngx_string(schema_json_str));

    // Test with null value (should pass gracefully)
    const result = validateValue(core.nullptr(cjson.cJSON), schema, "$", 0);
    try expect(result.valid == true);

    // Test with null schema (should pass gracefully)
    const valid_json_str = "\"test\"";
    const valid_value = try cj.decode(ngx_string(valid_json_str));
    const result2 = validateValue(valid_value, core.nullptr(cjson.cJSON), "$", 0);
    try expect(result2.valid == true);
}
