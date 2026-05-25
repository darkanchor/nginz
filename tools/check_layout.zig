const std = @import("std");
const ngx = @import("ngx");

const core = ngx.core;
const http = ngx.http;
const buf = ngx.buf;
const log_ = ngx.log;
const file = ngx.file;
const conf = ngx.conf;
const module_ = ngx.module;
const array = ngx.array;
const list = ngx.list;
const queue = ngx.queue;
const hash = ngx.hash;
const rbtree = ngx.rbtree;
const string = ngx.string;
const vx = ngx.vx;

const SizeEntry = struct { name: []const u8, zig_size: usize };
const OffsetEntry = struct { name: []const u8, field: []const u8, zig_offset: usize };
// BitfieldEntry: the C side cannot use offsetof() on a bitfield (UB), so it
// measures the byte offset at runtime via memset+scan and prints lines of the
// form `bitfield <struct> <field> <C_offset>`.  The Zig side derives the
// expected offset from the binding itself via `flag_byte_offset(Parent,
// "<packed_field>", "<sub_field>")`, so the check fails whenever translate-c
// produces a `packed struct(uN)` whose alignment shifts the first bitfield
// away from where C placed it.
const BitfieldEntry = struct {
    name: []const u8,
    field: []const u8,
    zig_offset: usize,
    note: []const u8,
};

/// Compute the byte offset of `sub` (first bitfield in a packed struct) as
/// seen by the Zig binding.  Resolves the packed-struct type through the
/// parent's field so we never have to make the (translate-c, private) flag
/// types public just to reference them here.
inline fn flag_byte_offset(
    comptime Parent: type,
    comptime flag_field: []const u8,
    comptime sub: []const u8,
) usize {
    const FlagType = @TypeOf(@field(@as(Parent, undefined), flag_field));
    return @offsetOf(Parent, flag_field) + @bitOffsetOf(FlagType, sub) / 8;
}

const sizeof_table = [_]SizeEntry{
    // Core structs
    .{ .name = "ngx_str_t", .zig_size = @sizeOf(core.ngx_str_t) },
    .{ .name = "ngx_keyval_t", .zig_size = @sizeOf(string.ngx_keyval_t) },
    .{ .name = "ngx_dir_t", .zig_size = @sizeOf(core.ngx_dir_t) },
    .{ .name = "ngx_process_t", .zig_size = @sizeOf(core.ngx_process_t) },
    .{ .name = "ngx_pool_t", .zig_size = @sizeOf(core.ngx_pool_t) },
    .{ .name = "ngx_cycle_t", .zig_size = @sizeOf(core.ngx_cycle_t) },
    .{ .name = "ngx_output_chain_ctx_t", .zig_size = @sizeOf(core.ngx_output_chain_ctx_t) },
    .{ .name = "ngx_listening_t", .zig_size = @sizeOf(core.ngx_listening_t) },
    .{ .name = "ngx_connection_t", .zig_size = @sizeOf(core.ngx_connection_t) },
    .{ .name = "ngx_ext_rename_file_t", .zig_size = @sizeOf(core.ngx_ext_rename_file_t) },
    .{ .name = "ngx_url_t", .zig_size = @sizeOf(core.ngx_url_t) },
    .{ .name = "ngx_open_file_info_t", .zig_size = @sizeOf(core.ngx_open_file_info_t) },
    .{ .name = "ngx_cached_open_file_t", .zig_size = @sizeOf(core.ngx_cached_open_file_t) },
    .{ .name = "ngx_resolver_node_t", .zig_size = @sizeOf(core.ngx_resolver_node_t) },
    .{ .name = "ngx_resolver_t", .zig_size = @sizeOf(core.ngx_resolver_t) },
    .{ .name = "ngx_resolver_ctx_t", .zig_size = @sizeOf(core.ngx_resolver_ctx_t) },
    .{ .name = "ngx_slab_pool_t", .zig_size = @sizeOf(core.ngx_slab_pool_t) },
    .{ .name = "ngx_variable_value_t", .zig_size = @sizeOf(core.ngx_variable_value_t) },
    .{ .name = "ngx_syslog_peer_t", .zig_size = @sizeOf(core.ngx_syslog_peer_t) },
    .{ .name = "ngx_event_t", .zig_size = @sizeOf(core.ngx_event_t) },
    .{ .name = "ngx_peer_connection_t", .zig_size = @sizeOf(core.ngx_peer_connection_t) },
    .{ .name = "ngx_event_pipe_t", .zig_size = @sizeOf(core.ngx_event_pipe_t) },
    .{ .name = "ngx_pool_cleanup_t", .zig_size = @sizeOf(core.ngx_pool_cleanup_t) },
    .{ .name = "ngx_open_file_t", .zig_size = @sizeOf(core.ngx_open_file_t) },
    .{ .name = "ngx_path_t", .zig_size = @sizeOf(core.ngx_path_t) },
    .{ .name = "ngx_shm_t", .zig_size = @sizeOf(core.ngx_shm_t) },
    .{ .name = "ngx_shm_zone_t", .zig_size = @sizeOf(core.ngx_shm_zone_t) },

    // Buf / Chain structs
    .{ .name = "ngx_buf_t", .zig_size = @sizeOf(buf.ngx_buf_t) },
    .{ .name = "ngx_chain_t", .zig_size = @sizeOf(buf.ngx_chain_t) },
    .{ .name = "ngx_chain_writer_ctx_t", .zig_size = @sizeOf(buf.ngx_chain_writer_ctx_t) },

    // Log / File structs
    .{ .name = "ngx_log_t", .zig_size = @sizeOf(log_.ngx_log_t) },
    .{ .name = "ngx_file_t", .zig_size = @sizeOf(file.ngx_file_t) },
    .{ .name = "ngx_temp_file_t", .zig_size = @sizeOf(file.ngx_temp_file_t) },

    // Config / Module structs
    .{ .name = "ngx_conf_t", .zig_size = @sizeOf(conf.ngx_conf_t) },
    .{ .name = "ngx_command_t", .zig_size = @sizeOf(conf.ngx_command_t) },
    .{ .name = "ngx_module_t", .zig_size = @sizeOf(module_.ngx_module_t) },

    // Container structs
    .{ .name = "ngx_array_t", .zig_size = @sizeOf(array.ngx_array_t) },
    .{ .name = "ngx_list_t", .zig_size = @sizeOf(list.ngx_list_t) },
    .{ .name = "ngx_queue_t", .zig_size = @sizeOf(queue.ngx_queue_t) },
    .{ .name = "ngx_hash_t", .zig_size = @sizeOf(hash.ngx_hash_t) },
    .{ .name = "ngx_hash_init_t", .zig_size = @sizeOf(hash.ngx_hash_init_t) },
    .{ .name = "ngx_table_elt_t", .zig_size = @sizeOf(hash.ngx_table_elt_t) },
    .{ .name = "ngx_rbtree_t", .zig_size = @sizeOf(rbtree.ngx_rbtree_t) },
    .{ .name = "ngx_rbtree_node_t", .zig_size = @sizeOf(rbtree.ngx_rbtree_node_t) },

    // HTTP core structs
    .{ .name = "ngx_http_module_t", .zig_size = @sizeOf(http.ngx_http_module_t) },
    .{ .name = "ngx_http_request_t", .zig_size = @sizeOf(http.ngx_http_request_t) },
    .{ .name = "ngx_http_request_body_t", .zig_size = @sizeOf(http.ngx_http_request_body_t) },
    .{ .name = "ngx_http_headers_in_t", .zig_size = @sizeOf(http.ngx_http_headers_in_t) },
    .{ .name = "ngx_http_header_out_t", .zig_size = @sizeOf(http.ngx_http_header_out_t) },
    .{ .name = "ngx_http_connection_t", .zig_size = @sizeOf(http.ngx_http_connection_t) },
    .{ .name = "ngx_http_cleanup_t", .zig_size = @sizeOf(http.ngx_http_cleanup_t) },
    .{ .name = "ngx_http_log_ctx_t", .zig_size = @sizeOf(http.ngx_http_log_ctx_t) },
    .{ .name = "ngx_http_posted_request_t", .zig_size = @sizeOf(http.ngx_http_posted_request_t) },
    .{ .name = "ngx_http_post_subrequest_t", .zig_size = @sizeOf(http.ngx_http_post_subrequest_t) },
    .{ .name = "ngx_http_status_t", .zig_size = @sizeOf(http.ngx_http_status_t) },
    .{ .name = "ngx_http_variable_t", .zig_size = @sizeOf(http.ngx_http_variable_t) },
    .{ .name = "ngx_http_variable_value_t", .zig_size = @sizeOf(http.ngx_http_variable_value_t) },
    .{ .name = "ngx_http_complex_value_t", .zig_size = @sizeOf(http.ngx_http_complex_value_t) },
    .{ .name = "ngx_http_regex_t", .zig_size = @sizeOf(http.ngx_http_regex_t) },
    .{ .name = "ngx_http_upstream_rr_peer_data_t", .zig_size = @sizeOf(http.ngx_http_upstream_rr_peer_data_t) },

    // HTTP config structs
    .{ .name = "ngx_http_listen_opt_t", .zig_size = @sizeOf(http.ngx_http_listen_opt_t) },
    .{ .name = "ngx_http_core_main_conf_t", .zig_size = @sizeOf(http.ngx_http_core_main_conf_t) },
    .{ .name = "ngx_http_core_srv_conf_t", .zig_size = @sizeOf(http.ngx_http_core_srv_conf_t) },
    .{ .name = "ngx_http_core_loc_conf_t", .zig_size = @sizeOf(http.ngx_http_core_loc_conf_t) },
    .{ .name = "ngx_http_addr_conf_t", .zig_size = @sizeOf(http.ngx_http_addr_conf_t) },
    .{ .name = "ngx_http_conf_addr_t", .zig_size = @sizeOf(http.ngx_http_conf_addr_t) },

    // HTTP cache structs
    .{ .name = "ngx_http_file_cache_node_t", .zig_size = @sizeOf(http.ngx_http_file_cache_node_t) },
    .{ .name = "ngx_http_cache_t", .zig_size = @sizeOf(http.ngx_http_cache_t) },

    // HTTP script structs
    .{ .name = "ngx_http_script_engine_t", .zig_size = @sizeOf(http.ngx_http_script_engine_t) },
    .{ .name = "ngx_http_script_compile_t", .zig_size = @sizeOf(http.ngx_http_script_compile_t) },
    .{ .name = "ngx_http_compile_complex_value_t", .zig_size = @sizeOf(http.ngx_http_compile_complex_value_t) },
    .{ .name = "ngx_http_script_regex_code_t", .zig_size = @sizeOf(http.ngx_http_script_regex_code_t) },
    .{ .name = "ngx_http_script_regex_end_code_t", .zig_size = @sizeOf(http.ngx_http_script_regex_end_code_t) },

    // HTTP upstream structs
    .{ .name = "ngx_http_upstream_t", .zig_size = @sizeOf(http.ngx_http_upstream_t) },
    .{ .name = "ngx_http_upstream_conf_t", .zig_size = @sizeOf(http.ngx_http_upstream_conf_t) },
    .{ .name = "ngx_http_upstream_server_t", .zig_size = @sizeOf(http.ngx_http_upstream_server_t) },
    .{ .name = "ngx_http_upstream_srv_conf_t", .zig_size = @sizeOf(http.ngx_http_upstream_srv_conf_t) },
    .{ .name = "ngx_http_upstream_main_conf_t", .zig_size = @sizeOf(http.ngx_http_upstream_main_conf_t) },
    .{ .name = "ngx_http_upstream_local_t", .zig_size = @sizeOf(http.ngx_http_upstream_local_t) },
    .{ .name = "ngx_http_upstream_resolved_t", .zig_size = @sizeOf(http.ngx_http_upstream_resolved_t) },
    .{ .name = "ngx_http_upstream_state_t", .zig_size = @sizeOf(http.ngx_http_upstream_state_t) },
    .{ .name = "ngx_http_upstream_headers_in_t", .zig_size = @sizeOf(http.ngx_http_upstream_headers_in_t) },
    .{ .name = "ngx_http_upstream_header_t", .zig_size = @sizeOf(http.ngx_http_upstream_header_t) },
    .{ .name = "ngx_http_upstream_rr_peer_t", .zig_size = @sizeOf(http.ngx_http_upstream_rr_peer_t) },
    .{ .name = "ngx_http_upstream_rr_peers_t", .zig_size = @sizeOf(http.ngx_http_upstream_rr_peers_t) },

    // SSL structs
    .{ .name = "ngx_ssl_connection_t", .zig_size = @sizeOf(http.ngx_ssl_connection_t) },
    .{ .name = "ngx_ssl_ticket_key_t", .zig_size = @sizeOf(http.ngx_ssl_ticket_key_t) },

    // HTTP/2 structs
    .{ .name = "ngx_http_v2_header_t", .zig_size = @sizeOf(vx.ngx_http_v2_header_t) },
    .{ .name = "ngx_http_v2_state_t", .zig_size = @sizeOf(vx.ngx_http_v2_state_t) },
    .{ .name = "ngx_http_v2_hpack_t", .zig_size = @sizeOf(vx.ngx_http_v2_hpack_t) },
    .{ .name = "ngx_http_v2_connection_t", .zig_size = @sizeOf(vx.ngx_http_v2_connection_t) },
    .{ .name = "ngx_http_v2_node_t", .zig_size = @sizeOf(vx.ngx_http_v2_node_t) },
    .{ .name = "ngx_http_v2_stream_t", .zig_size = @sizeOf(vx.ngx_http_v2_stream_t) },
    .{ .name = "ngx_http_v2_out_frame_t", .zig_size = @sizeOf(vx.ngx_http_v2_out_frame_t) },
    .{ .name = "ngx_http_v2_srv_conf_t", .zig_size = @sizeOf(vx.ngx_http_v2_srv_conf_t) },

    // HTTP/3 parse structs
    .{ .name = "ngx_http_v3_parse_varlen_int_t", .zig_size = @sizeOf(vx.ngx_http_v3_parse_varlen_int_t) },
    .{ .name = "ngx_http_v3_parse_prefix_int_t", .zig_size = @sizeOf(vx.ngx_http_v3_parse_prefix_int_t) },
    .{ .name = "ngx_http_v3_parse_settings_t", .zig_size = @sizeOf(vx.ngx_http_v3_parse_settings_t) },
    .{ .name = "ngx_http_v3_parse_field_section_prefix_t", .zig_size = @sizeOf(vx.ngx_http_v3_parse_field_section_prefix_t) },
    .{ .name = "ngx_http_v3_parse_literal_t", .zig_size = @sizeOf(vx.ngx_http_v3_parse_literal_t) },
    .{ .name = "ngx_http_v3_parse_field_t", .zig_size = @sizeOf(vx.ngx_http_v3_parse_field_t) },
    .{ .name = "ngx_http_v3_parse_field_rep_t", .zig_size = @sizeOf(vx.ngx_http_v3_parse_field_rep_t) },
    .{ .name = "ngx_http_v3_parse_headers_t", .zig_size = @sizeOf(vx.ngx_http_v3_parse_headers_t) },
    .{ .name = "ngx_http_v3_parse_data_t", .zig_size = @sizeOf(vx.ngx_http_v3_parse_data_t) },

    // HTTP/3 structs
    .{ .name = "ngx_http_v3_field_t", .zig_size = @sizeOf(vx.ngx_http_v3_field_t) },
    .{ .name = "ngx_http_v3_dynamic_table_t", .zig_size = @sizeOf(vx.ngx_http_v3_dynamic_table_t) },
    .{ .name = "ngx_http_v3_parse_t", .zig_size = @sizeOf(vx.ngx_http_v3_parse_t) },
    .{ .name = "ngx_http_v3_session_t", .zig_size = @sizeOf(vx.ngx_http_v3_session_t) },
    .{ .name = "ngx_http_v3_srv_conf_t", .zig_size = @sizeOf(vx.ngx_http_v3_srv_conf_t) },
    .{ .name = "ngx_quic_conf_t", .zig_size = @sizeOf(vx.ngx_quic_conf_t) },

    // Stream core structs
    .{ .name = "ngx_stream_session_t", .zig_size = @sizeOf(vx.ngx_stream_session_t) },
    .{ .name = "ngx_stream_module_t", .zig_size = @sizeOf(vx.ngx_stream_module_t) },
    .{ .name = "ngx_stream_conf_ctx_t", .zig_size = @sizeOf(vx.ngx_stream_conf_ctx_t) },
    .{ .name = "ngx_stream_core_srv_conf_t", .zig_size = @sizeOf(vx.ngx_stream_core_srv_conf_t) },
    .{ .name = "ngx_stream_phase_handler_t", .zig_size = @sizeOf(vx.ngx_stream_phase_handler_t) },
    .{ .name = "ngx_stream_upstream_main_conf_t", .zig_size = @sizeOf(vx.ngx_stream_upstream_main_conf_t) },
    .{ .name = "ngx_stream_complex_value_t", .zig_size = @sizeOf(vx.ngx_stream_complex_value_t) },

    // Stream upstream structs
    .{ .name = "ngx_stream_upstream_t", .zig_size = @sizeOf(vx.ngx_stream_upstream_t) },
    .{ .name = "ngx_stream_upstream_server_t", .zig_size = @sizeOf(vx.ngx_stream_upstream_server_t) },
    .{ .name = "ngx_stream_upstream_srv_conf_t", .zig_size = @sizeOf(vx.ngx_stream_upstream_srv_conf_t) },
    .{ .name = "ngx_stream_upstream_state_t", .zig_size = @sizeOf(vx.ngx_stream_upstream_state_t) },
    .{ .name = "ngx_stream_upstream_resolved_t", .zig_size = @sizeOf(vx.ngx_stream_upstream_resolved_t) },
    .{ .name = "ngx_stream_upstream_peer_t", .zig_size = @sizeOf(vx.ngx_stream_upstream_peer_t) },
    .{ .name = "ngx_stream_upstream_rr_peer_t", .zig_size = @sizeOf(vx.ngx_stream_upstream_rr_peer_t) },
    .{ .name = "ngx_stream_upstream_rr_peers_t", .zig_size = @sizeOf(vx.ngx_stream_upstream_rr_peers_t) },
    .{ .name = "ngx_stream_upstream_rr_peer_data_t", .zig_size = @sizeOf(vx.ngx_stream_upstream_rr_peer_data_t) },
};

const offsetof_table = [_]OffsetEntry{
    // ngx_http_request_t
    .{ .name = "ngx_http_request_t", .field = "connection", .zig_offset = @offsetOf(http.ngx_http_request_t, "connection") },
    .{ .name = "ngx_http_request_t", .field = "upstream", .zig_offset = @offsetOf(http.ngx_http_request_t, "upstream") },
    .{ .name = "ngx_http_request_t", .field = "pool", .zig_offset = @offsetOf(http.ngx_http_request_t, "pool") },
    .{ .name = "ngx_http_request_t", .field = "header_in", .zig_offset = @offsetOf(http.ngx_http_request_t, "header_in") },
    .{ .name = "ngx_http_request_t", .field = "headers_in", .zig_offset = @offsetOf(http.ngx_http_request_t, "headers_in") },
    .{ .name = "ngx_http_request_t", .field = "headers_out", .zig_offset = @offsetOf(http.ngx_http_request_t, "headers_out") },
    .{ .name = "ngx_http_request_t", .field = "cleanup", .zig_offset = @offsetOf(http.ngx_http_request_t, "cleanup") },
    .{ .name = "ngx_http_request_t", .field = "main", .zig_offset = @offsetOf(http.ngx_http_request_t, "main") },
    .{ .name = "ngx_http_request_t", .field = "parent", .zig_offset = @offsetOf(http.ngx_http_request_t, "parent") },
    .{ .name = "ngx_http_request_t", .field = "state", .zig_offset = @offsetOf(http.ngx_http_request_t, "state") },

    // ngx_http_upstream_t
    .{ .name = "ngx_http_upstream_t", .field = "conf", .zig_offset = @offsetOf(http.ngx_http_upstream_t, "conf") },
    .{ .name = "ngx_http_upstream_t", .field = "upstream", .zig_offset = @offsetOf(http.ngx_http_upstream_t, "upstream") },
    .{ .name = "ngx_http_upstream_t", .field = "headers_in", .zig_offset = @offsetOf(http.ngx_http_upstream_t, "headers_in") },
    .{ .name = "ngx_http_upstream_t", .field = "resolved", .zig_offset = @offsetOf(http.ngx_http_upstream_t, "resolved") },
    .{ .name = "ngx_http_upstream_t", .field = "create_request", .zig_offset = @offsetOf(http.ngx_http_upstream_t, "create_request") },
    .{ .name = "ngx_http_upstream_t", .field = "process_header", .zig_offset = @offsetOf(http.ngx_http_upstream_t, "process_header") },
    .{ .name = "ngx_http_upstream_t", .field = "finalize_request", .zig_offset = @offsetOf(http.ngx_http_upstream_t, "finalize_request") },
    .{ .name = "ngx_http_upstream_t", .field = "cleanup", .zig_offset = @offsetOf(http.ngx_http_upstream_t, "cleanup") },

    // ngx_connection_t
    .{ .name = "ngx_connection_t", .field = "ssl", .zig_offset = @offsetOf(core.ngx_connection_t, "ssl") },
    .{ .name = "ngx_connection_t", .field = "fd", .zig_offset = @offsetOf(core.ngx_connection_t, "fd") },
    .{ .name = "ngx_connection_t", .field = "log", .zig_offset = @offsetOf(core.ngx_connection_t, "log") },
    .{ .name = "ngx_connection_t", .field = "read", .zig_offset = @offsetOf(core.ngx_connection_t, "read") },
    .{ .name = "ngx_connection_t", .field = "write", .zig_offset = @offsetOf(core.ngx_connection_t, "write") },

    // ngx_peer_connection_t
    .{ .name = "ngx_peer_connection_t", .field = "connection", .zig_offset = @offsetOf(core.ngx_peer_connection_t, "connection") },
    .{ .name = "ngx_peer_connection_t", .field = "local", .zig_offset = @offsetOf(core.ngx_peer_connection_t, "local") },
    .{ .name = "ngx_peer_connection_t", .field = "log", .zig_offset = @offsetOf(core.ngx_peer_connection_t, "log") },

    // ngx_event_t
    .{ .name = "ngx_event_t", .field = "data", .zig_offset = @offsetOf(core.ngx_event_t, "data") },
    .{ .name = "ngx_event_t", .field = "handler", .zig_offset = @offsetOf(core.ngx_event_t, "handler") },

    // ngx_cycle_t
    .{ .name = "ngx_cycle_t", .field = "conf_ctx", .zig_offset = @offsetOf(core.ngx_cycle_t, "conf_ctx") },
    .{ .name = "ngx_cycle_t", .field = "pool", .zig_offset = @offsetOf(core.ngx_cycle_t, "pool") },
    .{ .name = "ngx_cycle_t", .field = "log", .zig_offset = @offsetOf(core.ngx_cycle_t, "log") },
    .{ .name = "ngx_cycle_t", .field = "modules", .zig_offset = @offsetOf(core.ngx_cycle_t, "modules") },

    // ngx_http_upstream_conf_t
    .{ .name = "ngx_http_upstream_conf_t", .field = "upstream", .zig_offset = @offsetOf(http.ngx_http_upstream_conf_t, "upstream") },

    // ngx_stream_session_t
    .{ .name = "ngx_stream_session_t", .field = "connection", .zig_offset = @offsetOf(vx.ngx_stream_session_t, "connection") },
    .{ .name = "ngx_stream_session_t", .field = "upstream", .zig_offset = @offsetOf(vx.ngx_stream_session_t, "upstream") },
    .{ .name = "ngx_stream_session_t", .field = "status", .zig_offset = @offsetOf(vx.ngx_stream_session_t, "status") },

    // ngx_stream_upstream_t
    .{ .name = "ngx_stream_upstream_t", .field = "peer", .zig_offset = @offsetOf(vx.ngx_stream_upstream_t, "peer") },
    .{ .name = "ngx_stream_upstream_t", .field = "upstream", .zig_offset = @offsetOf(vx.ngx_stream_upstream_t, "upstream") },
    .{ .name = "ngx_stream_upstream_t", .field = "resolved", .zig_offset = @offsetOf(vx.ngx_stream_upstream_t, "resolved") },
};

// Bitfield byte-offset checks.  One entry per field we want to verify.
// The C side measures the real byte offset at runtime; the Zig side
// derives it from the binding through flag_byte_offset().  A mismatch
// means the packed struct layout doesn't match C.
const bitfield_table = [_]BitfieldEntry{
    // flags0: 2 storage units
    .{ .name = "ngx_http_request_t", .field = "count", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags0", "count"), .note = "flags0 unit1 start" },
    .{ .name = "ngx_http_request_t", .field = "aio", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags0", "aio"), .note = "flags0 unit2 start" },
    .{ .name = "ngx_http_request_t", .field = "subrequest_in_memory", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags0", "subrequest_in_memory"), .note = "flags0 unit2 near end" },
    .{ .name = "ngx_http_request_t", .field = "cached", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags0", "cached"), .note = "flags0 unit2 last bit" },

    // flags1: 2 storage units
    .{ .name = "ngx_http_request_t", .field = "gzip_tested", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags1", "gzip_tested"), .note = "flags1 unit1 start" },
    .{ .name = "ngx_http_request_t", .field = "gzip_vary", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags1", "gzip_vary"), .note = "flags1 unit1 early" },
    .{ .name = "ngx_http_request_t", .field = "realloc_captures", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags1", "realloc_captures"), .note = "flags1 unit1 interior" },
    .{ .name = "ngx_http_request_t", .field = "limit_conn_status", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags1", "limit_conn_status"), .note = "flags1 unit1 interior" },
    .{ .name = "ngx_http_request_t", .field = "limit_req_status", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags1", "limit_req_status"), .note = "flags1 unit1 interior" },
    .{ .name = "ngx_http_request_t", .field = "chunked", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags1", "chunked"), .note = "flags1 unit1 before header_only" },
    .{ .name = "ngx_http_request_t", .field = "header_only", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags1", "header_only"), .note = "flags1 unit1 middle" },
    .{ .name = "ngx_http_request_t", .field = "internal", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags1", "internal"), .note = "flags1 unit1 near end" },
    .{ .name = "ngx_http_request_t", .field = "done", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags1", "done"), .note = "flags1 unit1 last?" },
    .{ .name = "ngx_http_request_t", .field = "logged", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags1", "logged"), .note = "flags1 unit boundary" },
    .{ .name = "ngx_http_request_t", .field = "buffered", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags1", "buffered"), .note = "flags1 unit2 start" },
    .{ .name = "ngx_http_request_t", .field = "allow_ranges", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags1", "allow_ranges"), .note = "flags1 unit2 middle" },
    .{ .name = "ngx_http_request_t", .field = "background", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags1", "background"), .note = "flags1 unit2 near end" },

    // flags2: 1 storage unit
    .{ .name = "ngx_http_request_t", .field = "http_minor", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags2", "http_minor"), .note = "flags2 unit start" },
    .{ .name = "ngx_http_request_t", .field = "http_major", .zig_offset = flag_byte_offset(http.ngx_http_request_t, "flags2", "http_major"), .note = "flags2 unit end" },

    .{
        .name = "ngx_http_addr_conf_t",
        .field = "ssl",
        .zig_offset = flag_byte_offset(http.ngx_http_addr_conf_t, "flags", "ssl"),
        .note = "preceded by virtual_names pointer",
    },
    .{
        .name = "ngx_connection_t",
        .field = "buffered",
        .zig_offset = flag_byte_offset(core.ngx_connection_t, "flags", "buffered"),
        .note = "preceded by requests: ngx_uint_t",
    },
    .{
        .name = "ngx_listening_t",
        .field = "open",
        .zig_offset = flag_byte_offset(core.ngx_listening_t, "flags", "open"),
        .note = "preceded by worker: ngx_uint_t",
    },
    .{
        .name = "ngx_buf_t",
        .field = "temporary",
        .zig_offset = flag_byte_offset(buf.ngx_buf_t, "flags", "temporary"),
        .note = "preceded by shadow pointer",
    },
    .{
        .name = "ngx_event_t",
        .field = "write",
        .zig_offset = flag_byte_offset(core.ngx_event_t, "flags", "write"),
        .note = "preceded by data pointer",
    },
    .{
        .name = "ngx_http_upstream_t",
        .field = "store",
        .zig_offset = flag_byte_offset(http.ngx_http_upstream_t, "flags", "store"),
        .note = "preceded by cleanup pointer",
    },
    .{
        .name = "ngx_http_upstream_t",
        .field = "keepalive",
        .zig_offset = flag_byte_offset(http.ngx_http_upstream_t, "flags", "keepalive"),
        .note = "upstream flags interior (crosses byte boundary)",
    },
    .{
        .name = "ngx_http_upstream_t",
        .field = "response_received",
        .zig_offset = flag_byte_offset(http.ngx_http_upstream_t, "flags", "response_received"),
        .note = "upstream flags end",
    },
    .{
        .name = "ngx_resolver_ctx_t",
        .field = "async",
        .zig_offset = flag_byte_offset(core.ngx_resolver_ctx_t, "flags", "async"),
        .note = "preceded by timeout: ngx_msec_t",
    },
    .{
        .name = "ngx_http_upstream_conf_t",
        .field = "store",
        .zig_offset = flag_byte_offset(http.ngx_http_upstream_conf_t, "flags", "store"),
        .note = "preceded by store_values pointer",
    },
    .{
        .name = "ngx_http_upstream_conf_t",
        .field = "preserve_output",
        .zig_offset = flag_byte_offset(http.ngx_http_upstream_conf_t, "flags", "preserve_output"),
        .note = "upstream conf flags end",
    },
    .{
        .name = "ngx_http_upstream_headers_in_t",
        .field = "connection_close",
        .zig_offset = flag_byte_offset(http.ngx_http_upstream_headers_in_t, "flags", "connection_close"),
        .note = "preceded by last_modified_time",
    },
    .{
        .name = "ngx_http_upstream_headers_in_t",
        .field = "expired",
        .zig_offset = flag_byte_offset(http.ngx_http_upstream_headers_in_t, "flags", "expired"),
        .note = "upstream headers_in flags end",
    },
    .{
        .name = "ngx_http_upstream_server_t",
        .field = "backup",
        .zig_offset = flag_byte_offset(http.ngx_http_upstream_server_t, "flags", "backup"),
        .note = "upstream server flags",
    },

    // Every remaining packed struct: first-field probes
    .{ .name = "ngx_file_t", .field = "valid_info", .zig_offset = flag_byte_offset(file.ngx_file_t, "flags", "valid_info"), .note = "file flags" },
    .{ .name = "ngx_variable_value_t", .field = "len", .zig_offset = flag_byte_offset(http.ngx_http_variable_value_t, "flags", "len"), .note = "variable value flags" },
    .{ .name = "ngx_dir_t", .field = "type", .zig_offset = flag_byte_offset(core.ngx_dir_t, "flags", "type"), .note = "dir flags" },
    .{ .name = "ngx_process_t", .field = "respawn", .zig_offset = flag_byte_offset(core.ngx_process_t, "flags", "respawn"), .note = "process flags" },
    .{ .name = "ngx_output_chain_ctx_t", .field = "sendfile", .zig_offset = flag_byte_offset(core.ngx_output_chain_ctx_t, "flags", "sendfile"), .note = "output chain ctx flags" },
    .{ .name = "ngx_temp_file_t", .field = "log_level", .zig_offset = flag_byte_offset(file.ngx_temp_file_t, "flags", "log_level"), .note = "temp file flags" },
    .{ .name = "ngx_ext_rename_file_t", .field = "create_path", .zig_offset = flag_byte_offset(core.ngx_ext_rename_file_t, "flags", "create_path"), .note = "ext rename file flags" },
    .{ .name = "ngx_url_t", .field = "listen", .zig_offset = flag_byte_offset(core.ngx_url_t, "flags", "listen"), .note = "url flags" },
    .{ .name = "ngx_resolver_t", .field = "ipv4", .zig_offset = flag_byte_offset(core.ngx_resolver_t, "flags", "ipv4"), .note = "resolver flags" },
    .{ .name = "ngx_resolver_node_t", .field = "tcp", .zig_offset = flag_byte_offset(core.ngx_resolver_node_t, "flags", "tcp"), .note = "resolver node flags" },
    .{ .name = "ngx_ssl_ticket_key_t", .field = "size", .zig_offset = flag_byte_offset(http.ngx_ssl_ticket_key_t, "flags", "size"), .note = "ssl ticket key flags" },
    .{ .name = "ngx_open_file_info_t", .field = "disable_symlinks", .zig_offset = flag_byte_offset(core.ngx_open_file_info_t, "flags", "disable_symlinks"), .note = "open file info flags" },
    .{ .name = "ngx_cached_open_file_t", .field = "disable_symlinks", .zig_offset = flag_byte_offset(core.ngx_cached_open_file_t, "flags", "disable_symlinks"), .note = "cached open file flags (u64)" },
    .{ .name = "ngx_syslog_peer_t", .field = "busy", .zig_offset = flag_byte_offset(core.ngx_syslog_peer_t, "flags", "busy"), .note = "syslog peer flags" },
    .{ .name = "ngx_http_cache_t", .field = "lock", .zig_offset = flag_byte_offset(http.ngx_http_cache_t, "flags", "lock"), .note = "http cache flags" },
    .{ .name = "ngx_peer_connection_t", .field = "cached", .zig_offset = flag_byte_offset(core.ngx_peer_connection_t, "flags", "cached"), .note = "peer connection flags" },
    .{ .name = "ngx_event_pipe_t", .field = "read", .zig_offset = flag_byte_offset(core.ngx_event_pipe_t, "flags", "read"), .note = "event pipe flags" },
    .{ .name = "ngx_http_headers_in_t", .field = "connection_type", .zig_offset = flag_byte_offset(http.ngx_http_headers_in_t, "flags", "connection_type"), .note = "http headers in flags" },
    .{ .name = "ngx_http_connection_t", .field = "ssl", .zig_offset = flag_byte_offset(http.ngx_http_connection_t, "flags", "ssl"), .note = "http connection flags" },
    .{ .name = "ngx_http_script_engine_t", .field = "flushed", .zig_offset = flag_byte_offset(http.ngx_http_script_engine_t, "flags", "flushed"), .note = "script engine flags" },
    .{ .name = "ngx_http_script_compile_t", .field = "compile_args", .zig_offset = flag_byte_offset(http.ngx_http_script_compile_t, "flags", "compile_args"), .note = "script compile flags" },
    .{ .name = "ngx_http_compile_complex_value_t", .field = "zero", .zig_offset = flag_byte_offset(http.ngx_http_compile_complex_value_t, "flags", "zero"), .note = "compile complex value flags" },
    .{ .name = "ngx_http_script_regex_code_t", .field = "test", .zig_offset = flag_byte_offset(http.ngx_http_script_regex_code_t, "flags", "test"), .note = "script regex code flags" },
    .{ .name = "ngx_http_script_regex_end_code_t", .field = "uri", .zig_offset = flag_byte_offset(http.ngx_http_script_regex_end_code_t, "flags", "uri"), .note = "script regex end code flags" },
    .{ .name = "ngx_http_upstream_rr_peer_t", .field = "route", .zig_offset = flag_byte_offset(http.ngx_http_upstream_rr_peer_t, "flags", "route"), .note = "upstream rr peer flags" },
    .{ .name = "ngx_http_upstream_rr_peers_t", .field = "single", .zig_offset = flag_byte_offset(http.ngx_http_upstream_rr_peers_t, "flags", "single"), .note = "upstream rr peers flags" },
    .{ .name = "ngx_http_conf_addr_t", .field = "protocols", .zig_offset = flag_byte_offset(http.ngx_http_conf_addr_t, "flags", "protocols"), .note = "http conf addr flags" },
    .{ .name = "ngx_http_v2_state_t", .field = "incomplete", .zig_offset = flag_byte_offset(vx.ngx_http_v2_state_t, "flags", "incomplete"), .note = "http v2 state flags" },
    .{ .name = "ngx_http_v2_connection_t", .field = "blocked", .zig_offset = flag_byte_offset(vx.ngx_http_v2_connection_t, "flags", "blocked"), .note = "http v2 connection flags" },
    .{ .name = "ngx_http_v2_stream_t", .field = "initialized", .zig_offset = flag_byte_offset(vx.ngx_http_v2_stream_t, "flags", "initialized"), .note = "http v2 stream flags" },
    .{ .name = "ngx_http_v2_out_frame_t", .field = "fin", .zig_offset = flag_byte_offset(vx.ngx_http_v2_out_frame_t, "flags", "fin"), .note = "http v2 out frame flags" },
    .{ .name = "ngx_http_v3_session_t", .field = "goaway", .zig_offset = flag_byte_offset(vx.ngx_http_v3_session_t, "flags", "goaway"), .note = "http v3 session flags" },

    .{
        .name = "ngx_http_request_body_t",
        .field = "filter_need_buffering",
        .zig_offset = flag_byte_offset(http.ngx_http_request_body_t, "flags", "filter_need_buffering"),
        .note = "preceded by post_handler pointer",
    },
    .{
        .name = "ngx_http_core_loc_conf_t",
        .field = "lmt_excpt",
        .zig_offset = flag_byte_offset(http.ngx_http_core_loc_conf_t, "flags", "lmt_excpt"),
        .note = "preceded by regex pointer",
    },
    .{
        .name = "ngx_http_listen_opt_t",
        .field = "set",
        .zig_offset = flag_byte_offset(http.ngx_http_listen_opt_t, "flags", "set"),
        .note = "preceded by addr_text: ngx_str_t",
    },
    .{
        .name = "ngx_http_core_srv_conf_t",
        .field = "listen",
        .zig_offset = flag_byte_offset(http.ngx_http_core_srv_conf_t, "flags", "listen"),
        .note = "preceded by underscores_in_headers: ngx_flag_t",
    },

    // Boundary-risk entries: packed struct(u32/u64) after sub-aligned preceding field.
    // See BITFIELDS.md audit table entries #5, #13, #47.
    .{
        .name = "ngx_ssl_connection_t",
        .field = "handshaked",
        .zig_offset = flag_byte_offset(http.ngx_ssl_connection_t, "flags", "handshaked"),
        .note = "packed struct(u32) after u_char early_buf; Zig inserts 3B padding",
    },
    .{
        .name = "ngx_slab_pool_t",
        .field = "log_nomem",
        .zig_offset = flag_byte_offset(core.ngx_slab_pool_t, "flags", "log_nomem"),
        .note = "packed struct(u32) after u_char zero; Zig inserts 3B padding",
    },
    .{
        .name = "ngx_http_file_cache_node_t",
        .field = "count",
        .zig_offset = flag_byte_offset(http.ngx_http_file_cache_node_t, "flags", "count"),
        .note = "packed struct(u64) after [8]u_char key; Zig inserts up to 7B padding",
    },
};

fn lookupZigSize(name: []const u8) ?usize {
    for (sizeof_table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.zig_size;
    }
    return null;
}

fn lookupZigOffset(struct_name: []const u8, field_name: []const u8) ?usize {
    for (offsetof_table) |entry| {
        if (std.mem.eql(u8, entry.name, struct_name) and std.mem.eql(u8, entry.field, field_name)) {
            return entry.zig_offset;
        }
    }
    return null;
}

fn lookupBitfieldEntry(struct_name: []const u8, field_name: []const u8) ?BitfieldEntry {
    for (bitfield_table) |entry| {
        if (std.mem.eql(u8, entry.name, struct_name) and std.mem.eql(u8, entry.field, field_name)) {
            return entry;
        }
    }
    return null;
}

const print = std.debug.print;

pub fn main(init: std.process.Init) !void {
    var args_iter = init.minimal.args.iterate();
    defer args_iter.deinit();

    var args = std.array_list.Managed([]const u8).init(init.gpa);
    defer args.deinit();

    while (args_iter.next()) |arg| {
        try args.append(arg);
    }

    if (args.items.len < 2) {
        print("Usage: check_layout <c_output_file>\n", .{});
        std.process.exit(1);
    }

    const content_buf = try init.gpa.alloc(u8, 1024 * 1024);
    defer init.gpa.free(content_buf);
    const content = try std.Io.Dir.cwd().readFile(init.io, args.items[1], content_buf);

    var mismatches: u32 = 0;
    var checked: u32 = 0;
    var lines = std.mem.splitSequence(u8, content, "\n");
    var label_buf: [128]u8 = undefined;

    print("\n  {s:<48} {s:>6}  {s:>6}  {s}\n", .{ "struct", "C", "Zig", "status" });
    print("  {s:-<48} {s:->6}  {s:->6}  {s:-<10}\n", .{ "", "", "", "" });

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "sizeof ")) {
            const rest = line["sizeof ".len..];
            if (parseSizeofLine(rest)) |entry| {
                if (lookupZigSize(entry.name)) |zig_size| {
                    checked += 1;
                    if (entry.size != zig_size) {
                        const diff: i64 = @as(i64, @intCast(entry.size)) - @as(i64, @intCast(zig_size));
                        const abs_diff = @abs(diff);
                        if (abs_diff % 8 == 0) {
                            print("  {s:<48} {d:>6}  {d:>6}  MISMATCH (diff={d}, {d} spare slot(s))\n", .{ entry.name, entry.size, zig_size, diff, @divExact(abs_diff, 8) });
                        } else {
                            print("  {s:<48} {d:>6}  {d:>6}  MISMATCH (diff={d})\n", .{ entry.name, entry.size, zig_size, diff });
                        }
                        mismatches += 1;
                    } else {
                        print("  {s:<48} {d:>6}  {d:>6}  OK\n", .{ entry.name, entry.size, zig_size });
                    }
                }
            }
        } else if (std.mem.startsWith(u8, line, "offsetof ")) {
            const rest = line["offsetof ".len..];
            if (parseOffsetofLine(rest)) |entry| {
                if (lookupZigOffset(entry.struct_name, entry.field_name)) |zig_offset| {
                    checked += 1;
                    const label = std.fmt.bufPrint(&label_buf, "{s}.{s}", .{ entry.struct_name, entry.field_name }) catch "???";
                    if (entry.offset != zig_offset) {
                        const diff: i64 = @as(i64, @intCast(entry.offset)) - @as(i64, @intCast(zig_offset));
                        print("  {s:<48} {d:>6}  {d:>6}  MISMATCH (diff={d})\n", .{ label, entry.offset, zig_offset, diff });
                        mismatches += 1;
                    } else {
                        print("  {s:<48} {d:>6}  {d:>6}  OK\n", .{ label, entry.offset, zig_offset });
                    }
                }
            }
        } else if (std.mem.startsWith(u8, line, "bitfield ")) {
            // Format: "bitfield <struct_name> <field_name> <c_byte_offset>"
            const rest = line["bitfield ".len..];
            if (parseBitfieldLine(rest)) |parsed| {
                if (lookupBitfieldEntry(parsed.struct_name, parsed.field_name)) |be| {
                    checked += 1;
                    const label = std.fmt.bufPrint(&label_buf, "{s}.{s}", .{ be.name, be.field }) catch "???";
                    if (parsed.offset != be.zig_offset) {
                        const diff: i64 = @as(i64, @intCast(parsed.offset)) - @as(i64, @intCast(be.zig_offset));
                        print("  {s:<48} {d:>6}  {d:>6}  MISMATCH (diff={d}) [{s}]\n", .{ label, parsed.offset, be.zig_offset, diff, be.note });
                        mismatches += 1;
                    } else {
                        print("  {s:<48} {d:>6}  {d:>6}  OK\n", .{ label, parsed.offset, be.zig_offset });
                    }
                }
            }
        }
    }

    print("\n  {d} checked, {d} mismatches\n\n", .{ checked, mismatches });

    if (mismatches > 0) {
        std.process.exit(1);
    }
}

const ParsedSizeof = struct { name: []const u8, size: usize };
const ParsedOffsetof = struct { struct_name: []const u8, field_name: []const u8, offset: usize };

fn parseSizeofLine(line: []const u8) ?ParsedSizeof {
    if (std.mem.lastIndexOfScalar(u8, line, ' ')) |sep| {
        const size = std.fmt.parseInt(usize, line[sep + 1 ..], 10) catch return null;
        return .{ .name = line[0..sep], .size = size };
    }
    return null;
}

fn parseOffsetofLine(line: []const u8) ?ParsedOffsetof {
    const first_sep = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const rest = line[first_sep + 1 ..];
    const second_sep = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse return null;
    const offset = std.fmt.parseInt(usize, rest[second_sep + 1 ..], 10) catch return null;
    return .{
        .struct_name = line[0..first_sep],
        .field_name = rest[0..second_sep],
        .offset = offset,
    };
}

// Parse "bitfield" lines emitted by check_layout.c (one per bitfield byte
// offset probe).  Format: "<struct_name> <field_name> <byte_offset>".
const ParsedBitfield = struct { struct_name: []const u8, field_name: []const u8, offset: usize };

fn parseBitfieldLine(line: []const u8) ?ParsedBitfield {
    const first_sep = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const rest = line[first_sep + 1 ..];
    const second_sep = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse return null;
    const offset = std.fmt.parseInt(usize, rest[second_sep + 1 ..], 10) catch return null;
    return .{
        .struct_name = line[0..first_sep],
        .field_name = rest[0..second_sep],
        .offset = offset,
    };
}
