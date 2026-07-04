// ngx_vx.zig - HTTP/2 and HTTP/3 struct definitions
//
// These structs are opaque in the auto-generated ngx.zig because
// zig translate-c cannot handle C bit-fields. This file provides
// manual Zig definitions following the same packed struct pattern
// used elsewhere in the bindings.

const std = @import("std");
const ngx = @import("ngx.zig");

const u_char = ngx.u_char;
const off_t = ngx.off_t;

const ngx_int_t = ngx.ngx_int_t;
const ngx_uint_t = ngx.ngx_uint_t;
const ngx_str_t = ngx.ngx_str_t;
const ngx_flag_t = ngx.ngx_flag_t;
const ngx_msec_t = ngx.ngx_msec_t;
const ngx_pool_t = ngx.ngx_pool_t;
const ngx_buf_t = ngx.ngx_buf_t;
const ngx_chain_t = ngx.ngx_chain_t;
const ngx_event_t = ngx.ngx_event_t;
const ngx_queue_t = ngx.ngx_queue_t;
const ngx_array_t = ngx.ngx_array_t;
const ngx_ssl_t = ngx.ngx_ssl_t;
const ngx_connection_t = ngx.ngx_connection_t;
const ngx_http_request_t = ngx.ngx_http_request_t;
const ngx_http_connection_t = ngx.ngx_http_connection_t;

// =========================================================================
// HTTP/2
// =========================================================================

const NGX_HTTP_V2_STATE_BUFFER_SIZE = 16;

pub const ngx_http_v2_header_t = extern struct {
    name: ngx_str_t = .{ .len = 0, .data = null },
    value: ngx_str_t = .{ .len = 0, .data = null },
};

// ngx_http_v2_state_t bit-fields:
//   unsigned flags:8
//   unsigned incomplete:1
//   unsigned keep_pool:1
//   unsigned parse_name:1
//   unsigned parse_value:1
//   unsigned index:1
const ngx_http_v2_state_flags_s = packed struct(u32) {
    flags: u8,
    incomplete: bool,
    keep_pool: bool,
    parse_name: bool,
    parse_value: bool,
    index: bool,
    padding: u19,
};

pub const ngx_http_v2_state_t = extern struct {
    sid: ngx_uint_t = 0,
    length: usize = 0,
    padding: usize = 0,
    flags: ngx_http_v2_state_flags_s = @bitCast(@as(u32, 0)),
    header: ngx_http_v2_header_t = .{},
    header_limit: usize = 0,
    field_state: u8 = 0,
    field_start: [*c]u_char = null,
    field_end: [*c]u_char = null,
    field_rest: usize = 0,
    pool: [*c]ngx_pool_t = null,
    stream: [*c]ngx_http_v2_stream_t = null,
    buffer: [NGX_HTTP_V2_STATE_BUFFER_SIZE]u8 = .{0} ** NGX_HTTP_V2_STATE_BUFFER_SIZE,
    buffer_used: usize = 0,
    handler: ngx_http_v2_handler_pt = null,
};

pub const ngx_http_v2_hpack_t = extern struct {
    entries: [*c][*c]ngx_http_v2_header_t = null,
    added: ngx_uint_t = 0,
    deleted: ngx_uint_t = 0,
    reused: ngx_uint_t = 0,
    allocated: ngx_uint_t = 0,
    size: usize = 0,
    free: usize = 0,
    storage: [*c]u_char = null,
    pos: [*c]u_char = null,
};

// ngx_http_v2_connection_t bit-fields:
//   unsigned settings_ack:1
//   unsigned table_update:1
//   unsigned blocked:1
//   unsigned goaway:1
const ngx_http_v2_connection_flags_s = packed struct(u32) {
    settings_ack: bool,
    table_update: bool,
    blocked: bool,
    goaway: bool,
    padding: u28,
};

pub const ngx_http_v2_handler_pt = ?*const fn (
    h2c: [*c]ngx_http_v2_connection_t,
    pos: [*c]u_char,
    end: [*c]u_char,
) callconv(.c) [*c]u_char;

pub const ngx_http_v2_out_frame_handler_pt = ?*const fn (
    h2c: [*c]ngx_http_v2_connection_t,
    frame: [*c]ngx_http_v2_out_frame_t,
) callconv(.c) ngx_int_t;

pub const ngx_http_v2_connection_t = extern struct {
    connection: [*c]ngx_connection_t = null,
    http_connection: [*c]ngx_http_connection_t = null,
    total_bytes: off_t = 0,
    payload_bytes: off_t = 0,
    processing: ngx_uint_t = 0,
    frames: ngx_uint_t = 0,
    idle: ngx_uint_t = 0,
    new_streams: ngx_uint_t = 0,
    refused_streams: ngx_uint_t = 0,
    priority_limit: ngx_uint_t = 0,
    send_window: usize = 0,
    recv_window: usize = 0,
    init_window: usize = 0,
    frame_size: usize = 0,
    waiting: ngx_queue_t = .{ .prev = null, .next = null },
    state: ngx_http_v2_state_t = .{},
    hpack: ngx_http_v2_hpack_t = .{},
    pool: [*c]ngx_pool_t = null,
    free_frames: [*c]ngx_http_v2_out_frame_t = null,
    free_fake_connections: [*c]ngx_connection_t = null,
    streams_index: [*c][*c]ngx_http_v2_node_t = null,
    last_out: [*c]ngx_http_v2_out_frame_t = null,
    dependencies: ngx_queue_t = .{ .prev = null, .next = null },
    closed: ngx_queue_t = .{ .prev = null, .next = null },
    closed_nodes: ngx_uint_t = 0,
    last_sid: ngx_uint_t = 0,
    lingering_time: isize = 0, // time_t
    flags: ngx_http_v2_connection_flags_s = @bitCast(@as(u32, 0)),
};

pub const ngx_http_v2_node_t = extern struct {
    id: ngx_uint_t = 0,
    index: [*c]ngx_http_v2_node_t = null,
    parent: [*c]ngx_http_v2_node_t = null,
    queue: ngx_queue_t = .{ .prev = null, .next = null },
    children: ngx_queue_t = .{ .prev = null, .next = null },
    reuse: ngx_queue_t = .{ .prev = null, .next = null },
    rank: ngx_uint_t = 0,
    weight: ngx_uint_t = 0,
    rel_weight: f64 = 0,
    stream: [*c]ngx_http_v2_stream_t = null,
};

// ngx_http_v2_stream_t bit-fields:
//   unsigned initialized:1
//   unsigned waiting:1
//   unsigned blocked:1
//   unsigned exhausted:1
//   unsigned in_closed:1
//   unsigned out_closed:1
//   unsigned rst_sent:1
//   unsigned no_flow_control:1
//   unsigned skip_data:1
const ngx_http_v2_stream_flags_s = packed struct(u32) {
    initialized: bool,
    waiting: bool,
    blocked: bool,
    exhausted: bool,
    in_closed: bool,
    out_closed: bool,
    rst_sent: bool,
    no_flow_control: bool,
    skip_data: bool,
    padding: u23,
};

pub const ngx_http_v2_stream_t = extern struct {
    request: [*c]ngx_http_request_t = null,
    connection: [*c]ngx_http_v2_connection_t = null,
    node: [*c]ngx_http_v2_node_t = null,
    queued: ngx_uint_t = 0,
    send_window: isize = 0, // ssize_t (signed)
    recv_window: usize = 0,
    preread: [*c]ngx_buf_t = null,
    frames: ngx_uint_t = 0,
    free_frames: [*c]ngx_http_v2_out_frame_t = null,
    free_frame_headers: [*c]ngx_chain_t = null,
    free_bufs: [*c]ngx_chain_t = null,
    queue: ngx_queue_t = .{ .prev = null, .next = null },
    cookies: [*c]ngx_array_t = null,
    pool: [*c]ngx_pool_t = null,
    flags: ngx_http_v2_stream_flags_s = @bitCast(@as(u32, 0)),
};

// ngx_http_v2_out_frame_t bit-fields:
//   unsigned blocked:1
//   unsigned fin:1
const ngx_http_v2_out_frame_flags_s = packed struct(u32) {
    blocked: bool,
    fin: bool,
    padding: u30,
};

pub const ngx_http_v2_out_frame_t = extern struct {
    next: [*c]ngx_http_v2_out_frame_t = null,
    first: [*c]ngx_chain_t = null,
    last: [*c]ngx_chain_t = null,
    handler: ngx_http_v2_out_frame_handler_pt = null,
    stream: [*c]ngx_http_v2_stream_t = null,
    length: usize = 0,
    flags: ngx_http_v2_out_frame_flags_s = @bitCast(@as(u32, 0)),
};

pub const ngx_http_v2_srv_conf_t = extern struct {
    enable: ngx_flag_t = 0,
    pool_size: usize = 0,
    concurrent_streams: ngx_uint_t = 0,
    preread_size: usize = 0,
    streams_index_mask: ngx_uint_t = 0,
};

// =========================================================================
// HTTP/3 parse types (from ngx_http_v3_parse.h)
// =========================================================================

pub const ngx_http_v3_parse_varlen_int_t = extern struct {
    state: ngx_uint_t = 0,
    value: u64 = 0,
};

pub const ngx_http_v3_parse_prefix_int_t = extern struct {
    state: ngx_uint_t = 0,
    shift: ngx_uint_t = 0,
    value: u64 = 0,
};

pub const ngx_http_v3_parse_settings_t = extern struct {
    state: ngx_uint_t = 0,
    id: u64 = 0,
    vlint: ngx_http_v3_parse_varlen_int_t = .{},
};

pub const ngx_http_v3_parse_field_section_prefix_t = extern struct {
    state: ngx_uint_t = 0,
    insert_count: ngx_uint_t = 0,
    delta_base: ngx_uint_t = 0,
    sign: ngx_uint_t = 0,
    base: ngx_uint_t = 0,
    pint: ngx_http_v3_parse_prefix_int_t = .{},
};

pub const ngx_http_v3_parse_literal_t = extern struct {
    state: ngx_uint_t = 0,
    length: ngx_uint_t = 0,
    huffman: ngx_uint_t = 0,
    value: ngx_str_t = .{ .len = 0, .data = null },
    last: [*c]u_char = null,
    huffstate: u8 = 0,
};

pub const ngx_http_v3_parse_field_t = extern struct {
    state: ngx_uint_t = 0,
    index: ngx_uint_t = 0,
    base: ngx_uint_t = 0,
    dynamic: ngx_uint_t = 0,
    name: ngx_str_t = .{ .len = 0, .data = null },
    value: ngx_str_t = .{ .len = 0, .data = null },
    pint: ngx_http_v3_parse_prefix_int_t = .{},
    literal: ngx_http_v3_parse_literal_t = .{},
};

pub const ngx_http_v3_parse_field_rep_t = extern struct {
    state: ngx_uint_t = 0,
    field: ngx_http_v3_parse_field_t = .{},
};

pub const ngx_http_v3_parse_headers_t = extern struct {
    state: ngx_uint_t = 0,
    type: ngx_uint_t = 0,
    length: ngx_uint_t = 0,
    vlint: ngx_http_v3_parse_varlen_int_t = .{},
    prefix: ngx_http_v3_parse_field_section_prefix_t = .{},
    field_rep: ngx_http_v3_parse_field_rep_t = .{},
};

pub const ngx_http_v3_parse_encoder_t = extern struct {
    state: ngx_uint_t = 0,
    field: ngx_http_v3_parse_field_t = .{},
    pint: ngx_http_v3_parse_prefix_int_t = .{},
};

pub const ngx_http_v3_parse_decoder_t = extern struct {
    state: ngx_uint_t = 0,
    pint: ngx_http_v3_parse_prefix_int_t = .{},
};

pub const ngx_http_v3_parse_control_t = extern struct {
    state: ngx_uint_t = 0,
    type: ngx_uint_t = 0,
    length: ngx_uint_t = 0,
    vlint: ngx_http_v3_parse_varlen_int_t = .{},
    settings: ngx_http_v3_parse_settings_t = .{},
};

pub const ngx_http_v3_parse_uni_u = extern union {
    encoder: ngx_http_v3_parse_encoder_t,
    decoder: ngx_http_v3_parse_decoder_t,
    control: ngx_http_v3_parse_control_t,
};

pub const ngx_http_v3_parse_uni_t = extern struct {
    state: ngx_uint_t = 0,
    vlint: ngx_http_v3_parse_varlen_int_t = .{},
    u: ngx_http_v3_parse_uni_u = undefined,
};

pub const ngx_http_v3_parse_data_t = extern struct {
    state: ngx_uint_t = 0,
    type: ngx_uint_t = 0,
    length: ngx_uint_t = 0,
    vlint: ngx_http_v3_parse_varlen_int_t = .{},
};

// =========================================================================
// HTTP/3 table types (from ngx_http_v3_table.h)
// =========================================================================

pub const ngx_http_v3_field_t = extern struct {
    name: ngx_str_t = .{ .len = 0, .data = null },
    value: ngx_str_t = .{ .len = 0, .data = null },
};

pub const ngx_http_v3_dynamic_table_t = extern struct {
    elts: [*c][*c]ngx_http_v3_field_t = null,
    nelts: ngx_uint_t = 0,
    base: ngx_uint_t = 0,
    size: usize = 0,
    capacity: usize = 0,
    insert_count: u64 = 0,
    ack_insert_count: u64 = 0,
    send_insert_count: ngx_event_t = undefined,
};

// =========================================================================
// HTTP/3 session and parse (the formerly-opaque structs)
// =========================================================================

pub const ngx_http_v3_parse_t = extern struct {
    header_limit: usize = 0,
    headers: ngx_http_v3_parse_headers_t = .{},
    body: ngx_http_v3_parse_data_t = .{},
    cookies: [*c]ngx_array_t = null,
};

const NGX_HTTP_V3_MAX_KNOWN_STREAM = 6;

// ngx_http_v3_session_t bit-fields:
//   unsigned goaway:1
//   unsigned hq:1
const ngx_http_v3_session_flags_s = packed struct(u32) {
    goaway: bool,
    hq: bool,
    padding: u30,
};

pub const ngx_http_v3_session_t = extern struct {
    http_connection: [*c]ngx_http_connection_t = null,
    table: ngx_http_v3_dynamic_table_t = undefined,
    keepalive: ngx_event_t = undefined,
    nrequests: ngx_uint_t = 0,
    blocked: ngx_queue_t = .{ .prev = null, .next = null },
    nblocked: ngx_uint_t = 0,
    next_request_id: u64 = 0,
    total_bytes: off_t = 0,
    payload_bytes: off_t = 0,
    flags: ngx_http_v3_session_flags_s = @bitCast(@as(u32, 0)),
    known_streams: [NGX_HTTP_V3_MAX_KNOWN_STREAM][*c]ngx_connection_t =
        .{null} ** NGX_HTTP_V3_MAX_KNOWN_STREAM,
};

// =========================================================================
// QUIC types (dependencies for HTTP/3 srv_conf)
// =========================================================================

const NGX_QUIC_AV_KEY_LEN = 32;
const NGX_QUIC_SR_KEY_LEN = 32;

pub const ngx_quic_init_pt = ?*const fn (c: [*c]ngx_connection_t) callconv(.c) ngx_int_t;
pub const ngx_quic_shutdown_pt = ?*const fn (c: [*c]ngx_connection_t) callconv(.c) void;

pub const ngx_quic_conf_t = extern struct {
    ssl: [*c]ngx_ssl_t = null,
    retry: ngx_flag_t = 0,
    gso_enabled: ngx_flag_t = 0,
    disable_active_migration: ngx_flag_t = 0,
    handshake_timeout: ngx_msec_t = 0,
    idle_timeout: ngx_msec_t = 0,
    host_key: ngx_str_t = .{ .len = 0, .data = null },
    stream_buffer_size: usize = 0,
    max_concurrent_streams_bidi: ngx_uint_t = 0,
    max_concurrent_streams_uni: ngx_uint_t = 0,
    active_connection_id_limit: ngx_uint_t = 0,
    stream_close_code: ngx_int_t = 0,
    stream_reject_code_uni: ngx_int_t = 0,
    stream_reject_code_bidi: ngx_int_t = 0,
    init: ngx_quic_init_pt = null,
    shutdown: ngx_quic_shutdown_pt = null,
    av_token_key: [NGX_QUIC_AV_KEY_LEN]u8 = .{0} ** NGX_QUIC_AV_KEY_LEN,
    sr_token_key: [NGX_QUIC_SR_KEY_LEN]u8 = .{0} ** NGX_QUIC_SR_KEY_LEN,
};

pub const ngx_http_v3_srv_conf_t = extern struct {
    enable: ngx_flag_t = 0,
    enable_hq: ngx_flag_t = 0,
    max_table_capacity: usize = 0,
    max_blocked_streams: ngx_uint_t = 0,
    max_concurrent_streams: ngx_uint_t = 0,
    quic: ngx_quic_conf_t = .{},
};

// =========================================================================
// Stream types (from ngx_stream.h, ngx_stream_upstream.h, etc.)
//
// These are not auto-generated in ngx.zig because nginx is not
// configured with --with-stream by default.
// =========================================================================

const ngx_conf_t = ngx.ngx_conf_t;
const ngx_hash_t = ngx.ngx_hash_t;
const ngx_log_t = ngx.ngx_log_t;
const ngx_resolver_t = ngx.ngx_resolver_t;
const ngx_resolver_ctx_t = ngx.ngx_resolver_ctx_t;
const ngx_variable_value_t = ngx.ngx_variable_value_t;
const ngx_addr_t = ngx.ngx_addr_t;
const uintptr_t = usize;

// ngx_stream_variable_value_t is typedef'd to ngx_variable_value_t
pub const ngx_stream_variable_value_t = ngx_variable_value_t;

pub const ngx_stream_conf_ctx_t = extern struct {
    main_conf: [*c]?*anyopaque = null,
    srv_conf: [*c]?*anyopaque = null,
};

pub const ngx_stream_module_t = extern struct {
    preconfiguration: ?*const fn ([*c]ngx_conf_t) callconv(.c) ngx_int_t = null,
    postconfiguration: ?*const fn ([*c]ngx_conf_t) callconv(.c) ngx_int_t = null,
    create_main_conf: ?*const fn ([*c]ngx_conf_t) callconv(.c) ?*anyopaque = null,
    init_main_conf: ?*const fn ([*c]ngx_conf_t, ?*anyopaque) callconv(.c) [*c]u8 = null,
    create_srv_conf: ?*const fn ([*c]ngx_conf_t) callconv(.c) ?*anyopaque = null,
    merge_srv_conf: ?*const fn ([*c]ngx_conf_t, ?*anyopaque, ?*anyopaque) callconv(.c) [*c]u8 = null,
};

pub const ngx_stream_handler_pt = ?*const fn (
    s: [*c]ngx_stream_session_t,
) callconv(.c) ngx_int_t;

pub const ngx_stream_content_handler_pt = ?*const fn (
    s: [*c]ngx_stream_session_t,
) callconv(.c) void;

pub const ngx_stream_phase_handler_pt = ?*const fn (
    s: [*c]ngx_stream_session_t,
    ph: [*c]ngx_stream_phase_handler_t,
) callconv(.c) ngx_int_t;

pub const ngx_stream_phase_handler_t = extern struct {
    checker: ngx_stream_phase_handler_pt = null,
    handler: ngx_stream_handler_pt = null,
    next: ngx_uint_t = 0,
};

pub const ngx_stream_phase_engine_t = extern struct {
    handlers: [*c]ngx_stream_phase_handler_t = null,
};

pub const ngx_stream_phase_t = extern struct {
    handlers: ngx_array_t = undefined,
};

pub const NGX_STREAM_POST_ACCEPT_PHASE: usize = 0;
pub const NGX_STREAM_PREACCESS_PHASE: usize = 1;
pub const NGX_STREAM_ACCESS_PHASE: usize = 2;
pub const NGX_STREAM_SSL_PHASE: usize = 3;
pub const NGX_STREAM_PREREAD_PHASE: usize = 4;
pub const NGX_STREAM_CONTENT_PHASE: usize = 5;
pub const NGX_STREAM_LOG_PHASE: usize = 6;

pub const ngx_stream_core_main_conf_t = extern struct {
    servers: ngx_array_t = undefined,
    phase_engine: ngx_stream_phase_engine_t = .{},
    variables_hash: ngx_hash_t = undefined,
    variables: ngx_array_t = undefined,
    prefix_variables: ngx_array_t = undefined,
    ncaptures: ngx_uint_t = 0,
    server_names_hash_max_size: ngx_uint_t = 0,
    server_names_hash_bucket_size: ngx_uint_t = 0,
    variables_hash_max_size: ngx_uint_t = 0,
    variables_hash_bucket_size: ngx_uint_t = 0,
    variables_keys: ?*anyopaque = null,
    ports: [*c]ngx_array_t = null,
    phases: [NGX_STREAM_LOG_PHASE + 1]ngx_stream_phase_t = undefined,
};

pub const ngx_stream_variable_s = extern struct {
    name: ngx_str_t = .{ .len = 0, .data = null },
    set_handler: ?*const fn (
        s: [*c]ngx_stream_session_t,
        v: [*c]ngx_stream_variable_value_t,
        data: uintptr_t,
    ) callconv(.c) void = null,
    get_handler: ?*const fn (
        s: [*c]ngx_stream_session_t,
        v: [*c]ngx_stream_variable_value_t,
        data: uintptr_t,
    ) callconv(.c) ngx_int_t = null,
    data: uintptr_t = 0,
    flags: ngx_uint_t = 0,
    index: ngx_uint_t = 0,
};
pub const ngx_stream_variable_t = ngx_stream_variable_s;

pub const NGX_STREAM_VAR_CHANGEABLE: ngx_uint_t = 1;
pub const NGX_STREAM_VAR_NOCACHEABLE: ngx_uint_t = 2;
pub const NGX_STREAM_VAR_INDEXED: ngx_uint_t = 4;
pub const NGX_STREAM_VAR_NOHASH: ngx_uint_t = 8;
pub const NGX_STREAM_VAR_WEAK: ngx_uint_t = 16;
pub const NGX_STREAM_VAR_PREFIX: ngx_uint_t = 32;

pub const ngx_stream_upstream_main_conf_t = extern struct {
    upstreams: ngx_array_t = undefined,
};

pub const ngx_stream_upstream_init_pt = ?*const fn (
    cf: [*c]ngx_conf_t,
    us: [*c]ngx_stream_upstream_srv_conf_t,
) callconv(.c) ngx_int_t;

pub const ngx_stream_upstream_init_peer_pt = ?*const fn (
    s: [*c]ngx_stream_session_t,
    us: [*c]ngx_stream_upstream_srv_conf_t,
) callconv(.c) ngx_int_t;

pub const ngx_stream_upstream_peer_t = extern struct {
    init_upstream: ngx_stream_upstream_init_pt = null,
    init: ngx_stream_upstream_init_peer_pt = null,
    data: ?*anyopaque = null,
};

// ngx_stream_upstream_server_t bit-fields:
//   unsigned backup:1
const ngx_stream_upstream_server_flags_s = packed struct(u32) {
    backup: bool,
    padding: u31,
};

pub const ngx_stream_upstream_server_t = extern struct {
    name: ngx_str_t = .{ .len = 0, .data = null },
    addrs: [*c]ngx_addr_t = null,
    naddrs: ngx_uint_t = 0,
    weight: ngx_uint_t = 0,
    max_conns: ngx_uint_t = 0,
    max_fails: ngx_uint_t = 0,
    fail_timeout: isize = 0, // time_t
    slow_start: ngx_msec_t = 0,
    down: ngx_uint_t = 0,
    flags: ngx_stream_upstream_server_flags_s = @bitCast(@as(u32, 0)),
};

pub const ngx_stream_upstream_srv_conf_t = extern struct {
    peer: ngx_stream_upstream_peer_t = .{},
    srv_conf: [*c]?*anyopaque = null,
    servers: [*c]ngx_array_t = null,
    flags: ngx_uint_t = 0,
    host: ngx_str_t = .{ .len = 0, .data = null },
    file_name: [*c]u_char = null,
    line: ngx_uint_t = 0,
    port: u16 = 0, // in_port_t
    no_port: ngx_uint_t = 0,
};

pub const ngx_stream_upstream_state_t = extern struct {
    response_time: ngx_msec_t = 0,
    connect_time: ngx_msec_t = 0,
    first_byte_time: ngx_msec_t = 0,
    bytes_sent: off_t = 0,
    bytes_received: off_t = 0,
    peer: [*c]ngx_str_t = null,
};

pub const ngx_stream_upstream_resolved_t = extern struct {
    host: ngx_str_t = .{ .len = 0, .data = null },
    port: u16 = 0, // in_port_t
    no_port: ngx_uint_t = 0,
    naddrs: ngx_uint_t = 0,
    addrs: ?*anyopaque = null, // ngx_resolver_addr_t*
    sockaddr: ?*anyopaque = null, // struct sockaddr*
    socklen: u32 = 0, // socklen_t
    name: ngx_str_t = .{ .len = 0, .data = null },
    ctx: [*c]ngx_resolver_ctx_t = null,
};

// ngx_stream_upstream_t bit-fields:
//   unsigned connected:1
//   unsigned proxy_protocol:1
//   unsigned half_closed:1
const ngx_stream_upstream_flags_s = packed struct(u32) {
    connected: bool,
    proxy_protocol: bool,
    half_closed: bool,
    padding: u29,
};

const ngx_peer_connection_t = ngx.ngx_peer_connection_t;

pub const ngx_stream_upstream_t = extern struct {
    peer: ngx_peer_connection_t = undefined,
    downstream_buf: ngx_buf_t = undefined,
    upstream_buf: ngx_buf_t = undefined,
    free: [*c]ngx_chain_t = null,
    upstream_out: [*c]ngx_chain_t = null,
    upstream_busy: [*c]ngx_chain_t = null,
    downstream_out: [*c]ngx_chain_t = null,
    downstream_busy: [*c]ngx_chain_t = null,
    received: off_t = 0,
    start_sec: isize = 0, // time_t
    requests: ngx_uint_t = 0,
    responses: ngx_uint_t = 0,
    start_time: ngx_msec_t = 0,
    upload_rate: usize = 0,
    download_rate: usize = 0,
    ssl_name: ngx_str_t = .{ .len = 0, .data = null },
    upstream: [*c]ngx_stream_upstream_srv_conf_t = null,
    resolved: [*c]ngx_stream_upstream_resolved_t = null,
    state: [*c]ngx_stream_upstream_state_t = null,
    flags: ngx_stream_upstream_flags_s = @bitCast(@as(u32, 0)),
};

// ngx_stream_upstream_rr_peer_t - with NGX_COMPAT_BEGIN(14)
// Without NGX_STREAM_UPSTREAM_ZONE, spare slots remain at 14
const ngx_stream_upstream_rr_peer_flags_s = packed struct(u32) {
    padding: u32,
};

pub const ngx_stream_upstream_rr_peer_t = extern struct {
    sockaddr: ?*anyopaque = null, // struct sockaddr*
    socklen: u32 = 0, // socklen_t
    name: ngx_str_t = .{ .len = 0, .data = null },
    server: ngx_str_t = .{ .len = 0, .data = null },
    current_weight: ngx_int_t = 0,
    effective_weight: ngx_int_t = 0,
    weight: ngx_int_t = 0,
    conns: ngx_uint_t = 0,
    max_conns: ngx_uint_t = 0,
    fails: ngx_uint_t = 0,
    accessed: isize = 0, // time_t
    checked: isize = 0, // time_t
    max_fails: ngx_uint_t = 0,
    fail_timeout: isize = 0, // time_t
    slow_start: ngx_msec_t = 0,
    start_time: ngx_msec_t = 0,
    down: ngx_uint_t = 0,
    ssl_session: ?*anyopaque = null,
    ssl_session_len: c_int = 0,
    next: [*c]ngx_stream_upstream_rr_peer_t = null,
    spare: [14]u64 = .{0} ** 14,
};

// ngx_stream_upstream_rr_peers_t bit-fields:
//   unsigned single:1
//   unsigned weighted:1
const ngx_stream_upstream_rr_peers_flags_s = packed struct(u32) {
    single: bool,
    weighted: bool,
    padding: u30,
};

pub const ngx_stream_upstream_rr_peers_t = extern struct {
    number: ngx_uint_t = 0,
    total_weight: ngx_uint_t = 0,
    tries: ngx_uint_t = 0,
    flags: ngx_stream_upstream_rr_peers_flags_s = @bitCast(@as(u32, 0)),
    name: [*c]ngx_str_t = null,
    next: [*c]ngx_stream_upstream_rr_peers_t = null,
    peer: [*c]ngx_stream_upstream_rr_peer_t = null,
};

pub const ngx_stream_upstream_rr_peer_data_t = extern struct {
    config: ngx_uint_t = 0,
    peers: [*c]ngx_stream_upstream_rr_peers_t = null,
    current: [*c]ngx_stream_upstream_rr_peer_t = null,
    tried: [*c]usize = null,
    data: usize = 0,
};

// ngx_stream_core_srv_conf_t bit-fields:
//   unsigned listen:1
const ngx_stream_core_srv_conf_flags_s = packed struct(u32) {
    listen: bool,
    padding: u31,
};

pub const ngx_stream_core_srv_conf_t = extern struct {
    server_names: ngx_array_t = undefined,
    handler: ngx_stream_content_handler_pt = null,
    ctx: [*c]ngx_stream_conf_ctx_t = null,
    file_name: [*c]u_char = null,
    line: ngx_uint_t = 0,
    server_name: ngx_str_t = .{ .len = 0, .data = null },
    tcp_nodelay: ngx_flag_t = 0,
    preread_buffer_size: usize = 0,
    preread_timeout: ngx_msec_t = 0,
    error_log: [*c]ngx_log_t = null,
    resolver_timeout: ngx_msec_t = 0,
    resolver: [*c]ngx_resolver_t = null,
    proxy_protocol_timeout: ngx_msec_t = 0,
    flags: ngx_stream_core_srv_conf_flags_s = @bitCast(@as(u32, 0)),
};

pub const ngx_log_handler_pt = ?*const fn (
    log: [*c]ngx_log_t,
    buf: [*c]u_char,
    len: usize,
) callconv(.c) [*c]u_char;

// ngx_stream_session_t bit-fields:
//   unsigned ssl:1
//   unsigned stat_processing:1
//   unsigned health_check:1
//   unsigned limit_conn_status:2
const ngx_stream_session_flags_s = packed struct(u32) {
    ssl: bool,
    stat_processing: bool,
    health_check: bool,
    limit_conn_status: u2,
    padding: u27,
};

pub const ngx_stream_session_t = extern struct {
    signature: u32 = 0,
    connection: [*c]ngx_connection_t = null,
    received: off_t = 0,
    start_sec: isize = 0, // time_t
    start_msec: ngx_msec_t = 0,
    log_handler: ngx_log_handler_pt = null,
    ctx: [*c]?*anyopaque = null,
    main_conf: [*c]?*anyopaque = null,
    srv_conf: [*c]?*anyopaque = null,
    virtual_names: ?*anyopaque = null, // ngx_stream_virtual_names_t*
    upstream: [*c]ngx_stream_upstream_t = null,
    upstream_states: [*c]ngx_array_t = null,
    variables: [*c]ngx_stream_variable_value_t = null,
    phase_handler: ngx_int_t = 0,
    status: ngx_uint_t = 0,
    flags: ngx_stream_session_flags_s = @bitCast(@as(u32, 0)),
};

// ngx_stream_complex_value_t - has an embedded union
pub const ngx_stream_complex_value_u = extern union {
    size: usize,
};

pub const ngx_stream_complex_value_t = extern struct {
    value: ngx_str_t = .{ .len = 0, .data = null },
    flushes: [*c]ngx_uint_t = null,
    lengths: ?*anyopaque = null,
    values: ?*anyopaque = null,
    u: ngx_stream_complex_value_u = undefined,
};

const ngx_stream_compile_complex_value_flags_s = packed struct(u32) {
    zero: bool,
    conf_prefix: bool,
    root_prefix: bool,
    complete_lengths: bool,
    complete_values: bool,
    padding: u27,
};

pub const ngx_stream_compile_complex_value_t = extern struct {
    cf: [*c]ngx_conf_t = null,
    value: [*c]ngx_str_t = null,
    complex_value: [*c]ngx_stream_complex_value_t = null,
    flags: ngx_stream_compile_complex_value_flags_s = @bitCast(@as(u32, 0)),
};

pub extern fn ngx_stream_add_variable(
    cf: [*c]ngx_conf_t,
    name: [*c]ngx_str_t,
    flags: ngx_uint_t,
) [*c]ngx_stream_variable_t;
pub extern fn ngx_stream_complex_value(
    s: [*c]ngx_stream_session_t,
    val: [*c]ngx_stream_complex_value_t,
    value: [*c]ngx_str_t,
) ngx_int_t;
pub extern fn ngx_stream_compile_complex_value(
    ccv: [*c]ngx_stream_compile_complex_value_t,
) ngx_int_t;

// ngx_stream_filter_pt
pub const ngx_stream_filter_pt = ?*const fn (
    s: [*c]ngx_stream_session_t,
    chain: [*c]ngx_chain_t,
    from_upstream: ngx_uint_t,
) callconv(.c) ngx_int_t;

// =========================================================================
// Tests
// =========================================================================

const expectEqual = std.testing.expectEqual;

test "v2 structs" {
    try expectEqual(@sizeOf(ngx_http_v2_stream_t) > 0, true);
    try expectEqual(@sizeOf(ngx_http_v2_connection_t) > 0, true);
    try expectEqual(@sizeOf(ngx_http_v2_out_frame_t) > 0, true);
    try expectEqual(@sizeOf(ngx_http_v2_node_t) > 0, true);
}

test "v3 structs" {
    try expectEqual(@sizeOf(ngx_http_v3_parse_t) > 0, true);
    try expectEqual(@sizeOf(ngx_http_v3_session_t) > 0, true);
    try expectEqual(@sizeOf(ngx_quic_conf_t) > 0, true);
    try expectEqual(@sizeOf(ngx_http_v3_srv_conf_t) > 0, true);
}

test "stream structs" {
    try expectEqual(@sizeOf(ngx_stream_session_t) > 0, true);
    try expectEqual(@sizeOf(ngx_stream_upstream_t) > 0, true);
    try expectEqual(@sizeOf(ngx_stream_module_t) > 0, true);
    try expectEqual(@sizeOf(ngx_stream_upstream_srv_conf_t) > 0, true);
    try expectEqual(@sizeOf(ngx_stream_upstream_rr_peer_t) > 0, true);
    try expectEqual(@sizeOf(ngx_stream_upstream_rr_peers_t) > 0, true);
}
