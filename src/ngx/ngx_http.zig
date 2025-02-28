const std = @import("std");
const ngx = @import("ngx.zig");
const nginx = @import("nginx.zig");

const log = nginx.log;
const core = nginx.core;
const conf = nginx.conf;
const hash = nginx.hash;
const array = nginx.array;
const string = nginx.string;
const module = nginx.module;
const expectEqual = std.testing.expectEqual;

pub const ngx_http_cache_t = ngx.ngx_http_cache_t;
pub const ngx_http_header_t = ngx.ngx_http_header_t;
pub const ngx_http_status_t = ngx.ngx_http_status_t;
pub const ngx_http_module_t = ngx.ngx_http_module_t;
pub const ngx_http_request_t = ngx.ngx_http_request_t;
pub const ngx_http_cleanup_t = ngx.ngx_http_cleanup_t;
pub const ngx_http_log_ctx_t = ngx.ngx_http_log_ctx_t;
pub const ngx_http_variable_t = ngx.ngx_http_variable_t;
pub const ngx_http_upstream_t = ngx.ngx_http_upstream_t;
pub const ngx_http_handler_pt = ngx.ngx_http_handler_pt;
pub const ngx_http_addr_conf_t = ngx.ngx_http_addr_conf_t;
pub const ngx_http_conf_addr_t = ngx.ngx_http_conf_addr_t;
pub const ngx_ssl_connection_t = ngx.ngx_ssl_connection_t;
pub const ngx_ssl_ticket_key_t = ngx.ngx_ssl_ticket_key_t;
pub const ngx_http_listen_opt_t = ngx.ngx_http_listen_opt_t;
pub const ngx_http_header_out_t = ngx.ngx_http_header_out_t;
pub const ngx_http_headers_in_t = ngx.ngx_http_headers_in_t;
pub const ngx_http_connection_t = ngx.ngx_http_connection_t;
pub const ngx_http_request_body_t = ngx.ngx_http_request_body_t;
pub const ngx_http_set_variable_pt = ngx.ngx_http_set_variable_pt;
pub const ngx_http_get_variable_pt = ngx.ngx_http_get_variable_pt;
pub const ngx_http_core_srv_conf_t = ngx.ngx_http_core_srv_conf_t;
pub const ngx_http_core_loc_conf_t = ngx.ngx_http_core_loc_conf_t;
pub const ngx_http_script_engine_t = ngx.ngx_http_script_engine_t;
pub const ngx_http_upstream_conf_t = ngx.ngx_http_upstream_conf_t;
pub const ngx_http_core_main_conf_t = ngx.ngx_http_core_main_conf_t;
pub const ngx_http_script_compile_t = ngx.ngx_http_script_compile_t;
pub const ngx_http_variable_value_t = ngx.ngx_http_variable_value_t;
pub const ngx_http_event_handler_pt = ngx.ngx_http_event_handler_pt;
pub const ngx_http_posted_request_t = ngx.ngx_http_posted_request_t;
pub const ngx_http_upstream_state_t = ngx.ngx_http_upstream_state_t;
pub const ngx_http_file_cache_node_t = ngx.ngx_http_file_cache_node_t;
pub const ngx_http_upstream_server_t = ngx.ngx_http_upstream_server_t;
pub const ngx_http_post_subrequest_t = ngx.ngx_http_post_subrequest_t;
pub const ngx_http_upstream_header_t = ngx.ngx_http_upstream_header_t;
pub const ngx_http_upstream_rr_peer_t = ngx.ngx_http_upstream_rr_peer_t;
pub const ngx_http_post_subrequest_pt = ngx.ngx_http_post_subrequest_pt;
pub const ngx_http_upstream_resolved_t = ngx.ngx_http_upstream_resolved_t;
pub const ngx_http_script_regex_code_t = ngx.ngx_http_script_regex_code_t;
pub const ngx_http_upstream_rr_peers_t = ngx.ngx_http_upstream_rr_peers_t;
pub const ngx_http_upstream_srv_conf_t = ngx.ngx_http_upstream_srv_conf_t;
pub const ngx_http_upstream_main_conf_t = ngx.ngx_http_upstream_main_conf_t;
pub const ngx_http_upstream_local_t = ngx.ngx_http_upstream_local_t;
pub const ngx_http_complex_value_t = ngx.ngx_http_complex_value_t;
pub const ngx_http_regex_t = ngx.ngx_http_regex_t;
pub const ngx_http_upstream_rr_peer_data_t = ngx.ngx_http_upstream_rr_peer_data_t;
pub const ngx_http_output_body_filter_pt = ngx.ngx_http_output_body_filter_pt;
pub const ngx_http_upstream_headers_in_t = ngx.ngx_http_upstream_headers_in_t;
pub const ngx_http_request_body_filter_pt = ngx.ngx_http_request_body_filter_pt;
pub const ngx_http_client_body_handler_pt = ngx.ngx_http_client_body_handler_pt;
pub const ngx_http_script_regex_end_code_t = ngx.ngx_http_script_regex_end_code_t;
pub const ngx_http_compile_complex_value_t = ngx.ngx_http_compile_complex_value_t;
pub const ngx_http_output_header_filter_pt = ngx.ngx_http_output_header_filter_pt;

pub extern var ngx_http_max_module: ngx_uint_t;
pub extern var ngx_cycle: [*c]core.ngx_cycle_t;
pub extern var ngx_http_top_body_filter: ngx_http_output_body_filter_pt;
pub extern var ngx_http_top_header_filter: ngx_http_output_header_filter_pt;
pub extern var ngx_http_top_request_body_filter: ngx_http_request_body_filter_pt;
pub extern fn ngx_http_upstream_finalize_request(r: [*c]ngx_http_request_t, u: [*c]ngx_http_upstream_t, rc: ngx_int_t) callconv(.C) void;

const NError = core.NError;
const NGX_OK = core.NGX_OK;

const ngx_int_t = core.ngx_int_t;
const ngx_str_t = core.ngx_str_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_array_t = array.ngx_array_t;
const ngx_module_t = module.ngx_module_t;

pub inline fn ngz_http_get_module_ctx(
    comptime T: type,
    r: [*c]ngx_http_request_t,
    m: [*c]ngx_module_t,
) ![*c]T {
    if (core.castPtr(T, r.*.ctx[m.*.ctx_index])) |ctx| {
        return ctx;
    }
    if (core.ngz_pcalloc_c(T, r.*.pool)) |ctx| {
        r.*.ctx[m.*.ctx_index] = ctx;
        return ctx;
    }
    return core.NError.OOM;
}

pub inline fn ngz_http_getor_module_ctx(
    comptime T: type,
    r: [*c]ngx_http_request_t,
    m: [*c]ngx_module_t,
    ctx: [*c]T,
) [*c]T {
    if (core.castPtr(T, r.*.ctx[m.*.ctx_index])) |ctx0| {
        return ctx0;
    }
    r.*.ctx[m.*.ctx_index] = ctx;
    return ctx;
}

pub fn ngz_set_upstream_header(
    h: [*c]hash.ngx_table_elt_t,
    r: [*c]ngx_http_request_t,
    umcf: [*c]ngx_http_upstream_main_conf_t,
    pass: [*c]const ngx_str_t,
) ngx_int_t {
    h.*.hash = r.*.header_hash;
    h.*.key.len = core.ngz_len(r.*.header_name_start, r.*.header_name_end);
    h.*.value.len = core.ngz_len(r.*.header_start, r.*.header_end);
    const total = h.*.key.len + 1 + h.*.value.len + 1 + h.*.key.len;
    if (core.castPtr(u8, core.ngx_pnalloc(r.*.pool, total))) |p| {
        h.*.key.data = p;
        core.ngz_memcpy(h.*.key.data, r.*.header_name_start, h.*.key.len);
        h.*.key.data[h.*.key.len] = 0;

        h.*.value.data = p + h.*.key.len + 1;
        core.ngz_memcpy(h.*.value.data, r.*.header_start, h.*.value.len);
        h.*.value.data[h.*.value.len] = 0;

        h.*.lowcase_key = p + h.*.key.len + 1 + h.*.value.len + 1;
        if (h.*.key.len == r.*.lowcase_index) {
            core.ngz_memcpy(h.*.lowcase_key, &r[0].lowcase_header, h.*.key.len);
        } else {
            string.ngx_strlow(h.*.lowcase_key, h.*.key.data, h.*.key.len);
        }
        var i: usize = 0;
        while (pass[i].len > 0) : (i += 1) {
            if (string.eql(pass[i], h.*.key)) {
                return NGX_OK;
            }
        }
        const hh = hash.ngx_hash_find(&umcf.*.headers_in_hash, h.*.hash, h.*.lowcase_key, h.*.key.len);
        if (core.castPtr(ngx_http_upstream_header_t, hh)) |h0| {
            if (h0.*.handler) |handle| {
                return handle(r, h, h0.*.offset);
            }
        }
    }
    h.*.hash = 0;
    return core.NGX_ERROR;
}

pub const NGX_HTTP_ACCESS_PHASE = ngx.NGX_HTTP_ACCESS_PHASE;
pub const NGX_HTTP_CONTENT_PHASE = ngx.NGX_HTTP_CONTENT_PHASE;

pub const NGX_HTTP_OK = ngx.NGX_HTTP_OK;
pub const NGX_HTTP_ACCEPTED = ngx.NGX_HTTP_ACCEPTED;
pub const NGX_HTTP_FORBIDDEN = ngx.NGX_HTTP_FORBIDDEN;
pub const NGX_HTTP_NOT_FOUND = ngx.NGX_HTTP_NOT_FOUND;
pub const NGX_HTTP_NO_CONTENT = ngx.NGX_HTTP_NO_CONTENT;
pub const NGX_HTTP_BAD_REQUEST = ngx.NGX_HTTP_BAD_REQUEST;
pub const NGX_HTTP_BAD_GATEWAY = ngx.NGX_HTTP_BAD_GATEWAY;
pub const NGX_HTTP_NOT_ALLOWED = ngx.NGX_HTTP_NOT_ALLOWED;
pub const NGX_HTTP_UNAUTHORIZED = ngx.NGX_HTTP_UNAUTHORIZED;
pub const NGX_HTTP_SPECIAL_RESPONSE = ngx.NGX_HTTP_SPECIAL_RESPONSE;
pub const NGX_HTTP_SERVICE_UNAVAILABLE = ngx.NGX_HTTP_SERVICE_UNAVAILABLE;
pub const NGX_HTTP_INTERNAL_SERVER_ERROR = ngx.NGX_HTTP_INTERNAL_SERVER_ERROR;
pub const NGX_HTTP_UPSTREAM_INVALID_HEADER = ngx.NGX_HTTP_UPSTREAM_INVALID_HEADER;

pub const NGX_HTTP_GET = ngx.NGX_HTTP_GET;
pub const NGX_HTTP_PUT = ngx.NGX_HTTP_PUT;
pub const NGX_HTTP_HEAD = ngx.NGX_HTTP_HEAD;
pub const NGX_HTTP_POST = ngx.NGX_HTTP_POST;
pub const NGX_HTTP_PATCH = ngx.NGX_HTTP_PATCH;
pub const NGX_HTTP_DELETE = ngx.NGX_HTTP_DELETE;

pub const NGX_HTTP_LAST = ngx.NGX_HTTP_LAST;
pub const NGX_HTTP_FLUSH = ngx.NGX_HTTP_FLUSH;

pub const NGX_HTTP_VAR_CHANGEABLE = ngx.NGX_HTTP_VAR_CHANGEABLE;
pub const NGX_HTTP_VAR_NOCACHEABLE = ngx.NGX_HTTP_VAR_NOCACHEABLE;
pub const NGX_HTTP_VAR_INDEXED = ngx.NGX_HTTP_VAR_INDEXED;
pub const NGX_HTTP_VAR_NOHASH = ngx.NGX_HTTP_VAR_NOHASH;
pub const NGX_HTTP_VAR_WEAK = ngx.NGX_HTTP_VAR_WEAK;
pub const NGX_HTTP_VAR_PREFIX = ngx.NGX_HTTP_VAR_PREFIX;

pub const NGX_HTTP_PARSE_HEADER_DONE = ngx.NGX_HTTP_PARSE_HEADER_DONE;
pub const NGX_HTTP_PARSE_INVALID_HEADER = ngx.NGX_HTTP_PARSE_INVALID_HEADER;

pub const ngx_parse_url = ngx.ngx_parse_url;
pub const ngx_get_connection = ngx.ngx_get_connection;
pub const ngx_http_subrequest = ngx.ngx_http_subrequest;
pub const ngx_http_script_run = ngx.ngx_http_script_run;
pub const ngx_http_cleanup_add = ngx.ngx_http_cleanup_add;
pub const ngx_http_send_header = ngx.ngx_http_send_header;
pub const ngx_http_add_variable = ngx.ngx_http_add_variable;
pub const ngx_http_get_variable_index = ngx.ngx_http_get_variable_index;
pub const ngx_http_get_flushed_variable = ngx.ngx_http_get_flushed_variable;
pub const ngx_http_send_special = ngx.ngx_http_send_special;
pub const ngx_handle_read_event = ngx.ngx_handle_read_event;
pub const ngx_handle_write_event = ngx.ngx_handle_write_event;
pub const ngx_http_output_filter = ngx.ngx_http_output_filter;
pub const ngx_http_upstream_init = ngx.ngx_http_upstream_init;
pub const ngx_http_named_location = ngx.ngx_http_named_location;
pub const ngx_http_upstream_create = ngx.ngx_http_upstream_create;
pub const ngx_http_core_run_phases = ngx.ngx_http_core_run_phases;
pub const ngx_http_finalize_request = ngx.ngx_http_finalize_request;
pub const ngx_http_parse_unsafe_uri = ngx.ngx_http_parse_unsafe_uri;
pub const ngx_http_internal_redirect = ngx.ngx_http_internal_redirect;
pub const ngx_http_parse_header_line = ngx.ngx_http_parse_header_line;
pub const ngx_http_parse_status_line = ngx.ngx_http_parse_status_line;
pub const ngx_http_parse_request_line = ngx.ngx_http_parse_request_line;
pub const ngx_http_run_posted_requests = ngx.ngx_http_run_posted_requests;
pub const ngx_http_request_empty_handler = ngx.ngx_http_request_empty_handler;
pub const ngx_http_read_client_request_body = ngx.ngx_http_read_client_request_body;
pub const ngx_http_discard_request_body = ngx.ngx_http_discard_request_body;
pub const ngx_http_upstream_hide_headers_hash = ngx.ngx_http_upstream_hide_headers_hash;
pub const ngx_http_upstream_non_buffered_filter = ngx.ngx_http_upstream_non_buffered_filter;
pub const ngx_http_upstream_non_buffered_filter_init = ngx.ngx_http_upstream_non_buffered_filter_init;

pub inline fn ngx_http_clear_content_length(r: [*c]ngx_http_request_t) void {
    r.*.headers_out.content_length_n = -1;
    if (r.*.headers_out.content_length != core.nullptr(hash.ngx_table_elt_t)) {
        r.*.headers_out.content_length.*.hash = 0;
        r.*.headers_out.content_length = core.nullptr(hash.ngx_table_elt_t);
    }
}

pub inline fn ngx_http_clear_accept_ranges(r: [*c]ngx_http_request_t) void {
    r.*.flags1.allow_ranges = false;
    if (r.*.headers_out.accept_ranges != core.nullptr(hash.ngx_table_elt_t)) {
        r.*.headers_out.accept_ranges.*.hash = 0;
        r.*.headers_out.accept_ranges = core.nullptr(hash.ngx_table_elt_t);
    }
}

pub inline fn ngx_http_clear_last_modified(r: [*c]ngx_http_request_t) void {
    r.*.headers_out.last_modified_time = -1;
    if (r.*.headers_out.last_modified != core.nullptr(hash.ngx_table_elt_t)) {
        r.*.headers_out.last_modified.*.hash = 0;
        r.*.headers_out.last_modified = core.nullptr(hash.ngx_table_elt_t);
    }
}

pub inline fn ngx_http_clear_location(r: [*c]ngx_http_request_t) void {
    if (r.*.headers_out.location != core.nullptr(hash.ngx_table_elt_t)) {
        r.*.headers_out.location.*.hash = 0;
        r.*.headers_out.location = core.nullptr(hash.ngx_table_elt_t);
    }
}

pub inline fn ngx_http_clear_etag(r: [*c]ngx_http_request_t) void {
    if (r.*.headers_out.etag != core.nullptr(hash.ngx_table_elt_t)) {
        r.*.headers_out.etag.*.hash = 0;
        r.*.headers_out.etag = core.nullptr(hash.ngx_table_elt_t);
    }
}

pub const NSubrequest = extern struct {
    const Self = @This();

    pub fn create(
        r: [*c]ngx_http_request_t,
        location: [*c]ngx_str_t,
        args: [*c]ngx_str_t,
    ) ![*c]ngx_http_request_t {
        var sr: [*c]ngx_http_request_t = core.nullptr(ngx_http_request_t);
        if (ngx_http_subrequest(r, location, args, &sr, core.nullptr(ngx_http_post_subrequest_t), 0) == NGX_OK) {
            return sr;
        }
        return core.NError.REQUEST_ERROR;
    }
};

test "http" {
    try expectEqual(@sizeOf(ngx_http_file_cache_node_t), 120);
    try expectEqual(@sizeOf(ngx_http_cache_t), 648);
    try expectEqual(@sizeOf(ngx_http_listen_opt_t), 72);
    try expectEqual(@sizeOf(ngx_http_core_srv_conf_t), 176);
    try expectEqual(@sizeOf(ngx_http_addr_conf_t), 24);
    try expectEqual(@sizeOf(ngx_http_conf_addr_t), 176);
    try expectEqual(@sizeOf(ngx_http_core_loc_conf_t), 736);
    try expectEqual(@sizeOf(ngx_http_headers_in_t), 384);
    try expectEqual(@sizeOf(ngx_http_request_body_t), 80);
    try expectEqual(@sizeOf(ngx_http_connection_t), 72);
    try expectEqual(@sizeOf(ngx_http_header_out_t), 24);

    try expectEqual(@sizeOf(ngx_http_request_t), 1408);
    try expectEqual(@offsetOf(ngx_http_request_t, "connection"), 8);
    try expectEqual(@offsetOf(ngx_http_request_t, "cleanup"), 1192);
    try expectEqual(@offsetOf(ngx_http_request_t, "flags0"), 1208);
    try expectEqual(@offsetOf(ngx_http_request_t, "flags1"), 1216);
    try expectEqual(@offsetOf(ngx_http_request_t, "state"), 1224);
    try expectEqual(@offsetOf(ngx_http_request_t, "host_end"), 1392);
    try expectEqual(@offsetOf(ngx_http_request_t, "flags2"), 1400);

    try expectEqual(@sizeOf(ngx_http_script_engine_t), 88);
    try expectEqual(@sizeOf(ngx_http_script_compile_t), 88);
    try expectEqual(@sizeOf(ngx_http_compile_complex_value_t), 32);
    try expectEqual(@sizeOf(ngx_http_script_regex_code_t), 72);
    try expectEqual(@sizeOf(ngx_http_script_regex_end_code_t), 16);

    try expectEqual(@sizeOf(ngx_http_upstream_server_t), 136);
    try expectEqual(@sizeOf(ngx_http_upstream_conf_t), 584);
    try expectEqual(@sizeOf(ngx_http_upstream_headers_in_t), 312);
    try expectEqual(@sizeOf(ngx_http_upstream_t), 1096);
    try expectEqual(@sizeOf(ngx_http_upstream_rr_peer_t), 320);
    try expectEqual(@sizeOf(ngx_http_upstream_rr_peers_t), 96);

    try expectEqual(@sizeOf(ngx_ssl_connection_t), 96);
    try expectEqual(@sizeOf(ngx_ssl_ticket_key_t), 96);
    try expectEqual(@sizeOf(ngx_http_module_t), 64);
}
