pub const __u_char = u8;
pub const __u_short = c_ushort;
pub const __dev_t = c_ulong;
pub const __uid_t = c_uint;
pub const __gid_t = c_uint;
pub const __ino_t = c_ulong;
pub const __ino64_t = c_ulong;
pub const __mode_t = c_uint;
pub const __nlink_t = c_ulong;
pub const __off_t = c_long;
pub const __off64_t = c_long;
pub const __pid_t = c_int;
pub const __time_t = c_long;
pub const __blksize_t = c_long;
pub const __blkcnt_t = c_long;
pub const __syscall_slong_t = c_long;
pub const __socklen_t = c_uint;
pub const u_char = __u_char;
pub const u_short = __u_short;
pub const ino_t = __ino64_t;
pub const off_t = __off64_t;
pub const pid_t = __pid_t;
pub const time_t = __time_t;
pub const struct_timespec = extern struct {
    tv_sec: __time_t = @import("std").mem.zeroes(__time_t),
    tv_nsec: __syscall_slong_t = @import("std").mem.zeroes(__syscall_slong_t),
};
pub const socklen_t = __socklen_t;
pub extern fn access(__name: [*c]const u8, __type: c_int) c_int;
pub extern fn close(__fd: c_int) c_int;
pub extern fn read(__fd: c_int, __buf: ?*anyopaque, __nbytes: usize) isize;
pub extern fn write(__fd: c_int, __buf: ?*const anyopaque, __n: usize) isize;
pub extern fn pipe(__pipedes: [*c]c_int) c_int;
pub extern fn link(__from: [*c]const u8, __to: [*c]const u8) c_int;
pub extern fn sync() void;
pub const struct___va_list_tag_5 = extern struct {
    gp_offset: c_uint = @import("std").mem.zeroes(c_uint),
    fp_offset: c_uint = @import("std").mem.zeroes(c_uint),
    overflow_arg_area: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    reg_save_area: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
};
pub const div_t = extern struct {
    quot: c_int = @import("std").mem.zeroes(c_int),
    rem: c_int = @import("std").mem.zeroes(c_int),
};
pub extern fn random() c_long;
pub extern fn free(__ptr: ?*anyopaque) void;
pub extern fn div(__numer: c_int, __denom: c_int) div_t;
pub extern fn index(__s: [*c]const u8, __c: c_int) [*c]u8;
pub const struct_passwd = extern struct {
    pw_name: [*c]u8 = @import("std").mem.zeroes([*c]u8),
    pw_passwd: [*c]u8 = @import("std").mem.zeroes([*c]u8),
    pw_uid: __uid_t = @import("std").mem.zeroes(__uid_t),
    pw_gid: __gid_t = @import("std").mem.zeroes(__gid_t),
    pw_gecos: [*c]u8 = @import("std").mem.zeroes([*c]u8),
    pw_dir: [*c]u8 = @import("std").mem.zeroes([*c]u8),
    pw_shell: [*c]u8 = @import("std").mem.zeroes([*c]u8),
};
pub const struct_dirent = extern struct {
    d_ino: __ino64_t = @import("std").mem.zeroes(__ino64_t),
    d_off: __off64_t = @import("std").mem.zeroes(__off64_t),
    d_reclen: c_ushort = @import("std").mem.zeroes(c_ushort),
    d_type: u8 = @import("std").mem.zeroes(u8),
    d_name: [256]u8 = @import("std").mem.zeroes([256]u8),
};
pub const struct___dirstream = opaque {};
pub const DIR = struct___dirstream;
pub const struct_stat = extern struct {
    st_dev: __dev_t = @import("std").mem.zeroes(__dev_t),
    st_ino: __ino_t = @import("std").mem.zeroes(__ino_t),
    st_nlink: __nlink_t = @import("std").mem.zeroes(__nlink_t),
    st_mode: __mode_t = @import("std").mem.zeroes(__mode_t),
    st_uid: __uid_t = @import("std").mem.zeroes(__uid_t),
    st_gid: __gid_t = @import("std").mem.zeroes(__gid_t),
    __pad0: c_int = @import("std").mem.zeroes(c_int),
    st_rdev: __dev_t = @import("std").mem.zeroes(__dev_t),
    st_size: __off_t = @import("std").mem.zeroes(__off_t),
    st_blksize: __blksize_t = @import("std").mem.zeroes(__blksize_t),
    st_blocks: __blkcnt_t = @import("std").mem.zeroes(__blkcnt_t),
    st_atim: struct_timespec = @import("std").mem.zeroes(struct_timespec),
    st_mtim: struct_timespec = @import("std").mem.zeroes(struct_timespec),
    st_ctim: struct_timespec = @import("std").mem.zeroes(struct_timespec),
    __glibc_reserved: [3]__syscall_slong_t = @import("std").mem.zeroes([3]__syscall_slong_t),
};
pub extern fn fstat(__fd: c_int, __buf: [*c]struct_stat) c_int;
pub extern fn open(__file: [*c]const u8, __oflag: c_int, ...) c_int;
pub extern fn wait(__stat_loc: [*c]c_int) __pid_t;
pub extern fn mmap(__addr: ?*anyopaque, __len: usize, __prot: c_int, __flags: c_int, __fd: c_int, __offset: __off64_t) ?*anyopaque;
pub const sa_family_t = c_ushort;
pub const struct_sockaddr = extern struct {
    sa_family: sa_family_t = @import("std").mem.zeroes(sa_family_t),
    sa_data: [14]u8 = @import("std").mem.zeroes([14]u8),
};
pub const struct_sockaddr_at_52 = opaque {};
pub const struct_sockaddr_ax25_53 = opaque {};
pub const struct_sockaddr_dl_54 = opaque {};
pub const struct_sockaddr_eon_55 = opaque {};
pub const in_port_t = u16;
pub const in_addr_t = u32;
pub const struct_in_addr = extern struct {
    s_addr: in_addr_t = @import("std").mem.zeroes(in_addr_t),
};
pub const struct_sockaddr_in = extern struct {
    sin_family: sa_family_t = @import("std").mem.zeroes(sa_family_t),
    sin_port: in_port_t = @import("std").mem.zeroes(in_port_t),
    sin_addr: struct_in_addr = @import("std").mem.zeroes(struct_in_addr),
    sin_zero: [8]u8 = @import("std").mem.zeroes([8]u8),
};
const union_unnamed_56 = extern union {
    __u6_addr8: [16]u8,
    __u6_addr16: [8]u16,
    __u6_addr32: [4]u32,
};
pub const struct_in6_addr = extern struct {
    __in6_u: union_unnamed_56 = @import("std").mem.zeroes(union_unnamed_56),
};
pub const struct_sockaddr_in6 = extern struct {
    sin6_family: sa_family_t = @import("std").mem.zeroes(sa_family_t),
    sin6_port: in_port_t = @import("std").mem.zeroes(in_port_t),
    sin6_flowinfo: u32 = @import("std").mem.zeroes(u32),
    sin6_addr: struct_in6_addr = @import("std").mem.zeroes(struct_in6_addr),
    sin6_scope_id: u32 = @import("std").mem.zeroes(u32),
};
pub const struct_sockaddr_inarp_57 = opaque {};
pub const struct_sockaddr_ipx_58 = opaque {};
pub const struct_sockaddr_iso_59 = opaque {};
pub const struct_sockaddr_ns_60 = opaque {};
pub const struct_sockaddr_un = extern struct {
    sun_family: sa_family_t = @import("std").mem.zeroes(sa_family_t),
    sun_path: [108]u8 = @import("std").mem.zeroes([108]u8),
};
pub const struct_sockaddr_x25_61 = opaque {};
pub const __SOCKADDR_ARG = extern union {
    __sockaddr__: [*c]struct_sockaddr,
    __sockaddr_at__: ?*struct_sockaddr_at_52,
    __sockaddr_ax25__: ?*struct_sockaddr_ax25_53,
    __sockaddr_dl__: ?*struct_sockaddr_dl_54,
    __sockaddr_eon__: ?*struct_sockaddr_eon_55,
    __sockaddr_in__: [*c]struct_sockaddr_in,
    __sockaddr_in6__: [*c]struct_sockaddr_in6,
    __sockaddr_inarp__: ?*struct_sockaddr_inarp_57,
    __sockaddr_ipx__: ?*struct_sockaddr_ipx_58,
    __sockaddr_iso__: ?*struct_sockaddr_iso_59,
    __sockaddr_ns__: ?*struct_sockaddr_ns_60,
    __sockaddr_un__: [*c]struct_sockaddr_un,
    __sockaddr_x25__: ?*struct_sockaddr_x25_61,
};
pub const __CONST_SOCKADDR_ARG = extern union {
    __sockaddr__: [*c]const struct_sockaddr,
    __sockaddr_at__: ?*const struct_sockaddr_at_52,
    __sockaddr_ax25__: ?*const struct_sockaddr_ax25_53,
    __sockaddr_dl__: ?*const struct_sockaddr_dl_54,
    __sockaddr_eon__: ?*const struct_sockaddr_eon_55,
    __sockaddr_in__: [*c]const struct_sockaddr_in,
    __sockaddr_in6__: [*c]const struct_sockaddr_in6,
    __sockaddr_inarp__: ?*const struct_sockaddr_inarp_57,
    __sockaddr_ipx__: ?*const struct_sockaddr_ipx_58,
    __sockaddr_iso__: ?*const struct_sockaddr_iso_59,
    __sockaddr_ns__: ?*const struct_sockaddr_ns_60,
    __sockaddr_un__: [*c]const struct_sockaddr_un,
    __sockaddr_x25__: ?*const struct_sockaddr_x25_61,
};
pub extern fn bind(__fd: c_int, __addr: __CONST_SOCKADDR_ARG, __len: socklen_t) c_int;
pub extern fn send(__fd: c_int, __buf: ?*const anyopaque, __n: usize, __flags: c_int) isize;
pub extern fn recv(__fd: c_int, __buf: ?*anyopaque, __n: usize, __flags: c_int) isize;
pub extern fn listen(__fd: c_int, __n: c_int) c_int;
pub extern fn accept(__fd: c_int, __addr: __SOCKADDR_ARG, noalias __addr_len: [*c]socklen_t) c_int;
pub extern fn time(__timer: [*c]time_t) time_t;
pub const sem_t = extern union {
    __size: [32]u8,
    __align: c_long,
};
pub extern fn sendfile(__out_fd: c_int, __in_fd: c_int, __offset: [*c]__off64_t, __count: usize) isize;
pub const ngx_int_t = isize;
pub const ngx_uint_t = usize;
pub const ngx_flag_t = isize;
pub const ngx_buf_tag_t = ?*anyopaque;
pub const ngx_fd_t = c_int;
pub const ngx_file_info_t = struct_stat;
pub const struct_ngx_open_file_s = extern struct {
    fd: ngx_fd_t = @import("std").mem.zeroes(ngx_fd_t),
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    flush: ?*const fn ([*c]ngx_open_file_t, [*c]ngx_log_t) callconv(.c) void = @import("std").mem.zeroes(?*const fn ([*c]ngx_open_file_t, [*c]ngx_log_t) callconv(.c) void),
    data: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
};
pub const ngx_open_file_t = struct_ngx_open_file_s;
pub const ngx_atomic_uint_t = c_ulong;
pub const ngx_log_handler_pt = ?*const fn ([*c]ngx_log_t, [*c]u_char, usize) callconv(.c) [*c]u_char;
pub const ngx_log_writer_pt = ?*const fn ([*c]ngx_log_t, ngx_uint_t, [*c]u_char, usize) callconv(.c) void;
pub const struct_ngx_log_s = extern struct {
    log_level: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    file: [*c]ngx_open_file_t = @import("std").mem.zeroes([*c]ngx_open_file_t),
    connection: ngx_atomic_uint_t = @import("std").mem.zeroes(ngx_atomic_uint_t),
    disk_full_time: time_t = @import("std").mem.zeroes(time_t),
    handler: ngx_log_handler_pt = @import("std").mem.zeroes(ngx_log_handler_pt),
    data: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    writer: ngx_log_writer_pt = @import("std").mem.zeroes(ngx_log_writer_pt),
    wdata: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    action: [*c]u8 = @import("std").mem.zeroes([*c]u8),
    next: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
    padding: [5]usize = @import("std").mem.zeroes([5]usize),
};
pub const ngx_log_t = struct_ngx_log_s;
const struct_ngx_file_flags_s = packed struct(u32) {
    valid_info: bool,
    directio: bool,
    padding: u30,
};
pub const struct_ngx_file_s = extern struct {
    fd: ngx_fd_t = @import("std").mem.zeroes(ngx_fd_t),
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    info: ngx_file_info_t = @import("std").mem.zeroes(ngx_file_info_t),
    offset: off_t = @import("std").mem.zeroes(off_t),
    sys_offset: off_t = @import("std").mem.zeroes(off_t),
    log: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
    thread_handler: ?*const fn ([*c]ngx_thread_task_t, [*c]ngx_file_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_thread_task_t, [*c]ngx_file_t) callconv(.c) ngx_int_t),
    thread_ctx: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    thread_task: [*c]ngx_thread_task_t = @import("std").mem.zeroes([*c]ngx_thread_task_t),
    aio: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    flags: struct_ngx_file_flags_s = @import("std").mem.zeroes(struct_ngx_file_flags_s),
};
pub const ngx_file_t = struct_ngx_file_s;
const struct_ngx_buf_flags_s = packed struct(u32) {
    temporary: bool,
    memory: bool,
    mmap: bool,
    recycled: bool,
    in_file: bool,
    flush: bool,
    sync: bool,
    last_buf: bool,
    last_in_chain: bool,
    last_shadow: bool,
    temp_file: bool,
    padding: u21,
};
pub const struct_ngx_buf_s = extern struct {
    pos: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    last: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    file_pos: off_t = @import("std").mem.zeroes(off_t),
    file_last: off_t = @import("std").mem.zeroes(off_t),
    start: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    end: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    tag: ngx_buf_tag_t = @import("std").mem.zeroes(ngx_buf_tag_t),
    file: [*c]ngx_file_t = @import("std").mem.zeroes([*c]ngx_file_t),
    shadow: [*c]ngx_buf_t = @import("std").mem.zeroes([*c]ngx_buf_t),
    flags: struct_ngx_buf_flags_s = @import("std").mem.zeroes(struct_ngx_buf_flags_s),
    num: c_int = @import("std").mem.zeroes(c_int),
};
pub const ngx_buf_t = struct_ngx_buf_s;
pub const struct_ngx_chain_s = extern struct {
    buf: [*c]ngx_buf_t = @import("std").mem.zeroes([*c]ngx_buf_t),
    next: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
};
pub const ngx_chain_t = struct_ngx_chain_s;
pub const struct_ngx_pool_large_s = extern struct {
    next: [*c]ngx_pool_large_t = @import("std").mem.zeroes([*c]ngx_pool_large_t),
    alloc: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
};
pub const ngx_pool_large_t = struct_ngx_pool_large_s;
pub const ngx_pool_cleanup_pt = ?*const fn (?*anyopaque) callconv(.c) void;
pub const struct_ngx_pool_cleanup_s = extern struct {
    handler: ngx_pool_cleanup_pt = @import("std").mem.zeroes(ngx_pool_cleanup_pt),
    data: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    next: [*c]ngx_pool_cleanup_t = @import("std").mem.zeroes([*c]ngx_pool_cleanup_t),
};
pub const ngx_pool_cleanup_t = struct_ngx_pool_cleanup_s;
pub const struct_ngx_pool_s = extern struct {
    d: ngx_pool_data_t = @import("std").mem.zeroes(ngx_pool_data_t),
    max: usize = @import("std").mem.zeroes(usize),
    current: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    chain: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    large: [*c]ngx_pool_large_t = @import("std").mem.zeroes([*c]ngx_pool_large_t),
    cleanup: [*c]ngx_pool_cleanup_t = @import("std").mem.zeroes([*c]ngx_pool_cleanup_t),
    log: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
};
pub const ngx_pool_t = struct_ngx_pool_s;
pub const ngx_event_handler_pt = ?*const fn ([*c]ngx_event_t) callconv(.c) void;
pub const ngx_rbtree_key_t = ngx_uint_t;
pub const struct_ngx_rbtree_node_s = extern struct {
    key: ngx_rbtree_key_t = @import("std").mem.zeroes(ngx_rbtree_key_t),
    left: [*c]ngx_rbtree_node_t = @import("std").mem.zeroes([*c]ngx_rbtree_node_t),
    right: [*c]ngx_rbtree_node_t = @import("std").mem.zeroes([*c]ngx_rbtree_node_t),
    parent: [*c]ngx_rbtree_node_t = @import("std").mem.zeroes([*c]ngx_rbtree_node_t),
    color: u_char = @import("std").mem.zeroes(u_char),
    data: u_char = @import("std").mem.zeroes(u_char),
};
pub const ngx_rbtree_node_t = struct_ngx_rbtree_node_s;
pub const struct_ngx_queue_s = extern struct {
    prev: [*c]ngx_queue_t = @import("std").mem.zeroes([*c]ngx_queue_t),
    next: [*c]ngx_queue_t = @import("std").mem.zeroes([*c]ngx_queue_t),
};
pub const ngx_queue_t = struct_ngx_queue_s;
const struct_ngx_event_flags_s = packed struct(u32) {
    write: bool,
    accept: bool,
    instance: bool,
    active: bool,
    disabled: bool,
    ready: bool,
    oneshot: bool,
    complete: bool,
    eof: bool,
    @"error": bool,
    timedout: bool,
    timer_set: bool,
    delayed: bool,
    deferred_accept: bool,
    pending_eof: bool,
    posted: bool,
    closed: bool,
    channel: bool,
    resovler: bool,
    cancelable: bool,
    padding: u12,
};
pub const struct_ngx_event_s = extern struct {
    data: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    flags: struct_ngx_event_flags_s = @import("std").mem.zeroes(struct_ngx_event_flags_s),
    available: c_int = @import("std").mem.zeroes(c_int),
    handler: ngx_event_handler_pt = @import("std").mem.zeroes(ngx_event_handler_pt),
    index: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    log: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
    timer: ngx_rbtree_node_t = @import("std").mem.zeroes(ngx_rbtree_node_t),
    queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
};
pub const ngx_event_t = struct_ngx_event_s;
pub const ngx_socket_t = c_int;
pub const ngx_recv_pt = ?*const fn ([*c]ngx_connection_t, [*c]u_char, usize) callconv(.c) isize;
pub const ngx_send_pt = ?*const fn ([*c]ngx_connection_t, [*c]u_char, usize) callconv(.c) isize;
pub const ngx_recv_chain_pt = ?*const fn ([*c]ngx_connection_t, [*c]ngx_chain_t, off_t) callconv(.c) isize;
pub const ngx_send_chain_pt = ?*const fn ([*c]ngx_connection_t, [*c]ngx_chain_t, off_t) callconv(.c) [*c]ngx_chain_t;
pub const ngx_connection_handler_pt = ?*const fn ([*c]ngx_connection_t) callconv(.c) void;
pub const ngx_rbtree_insert_pt = ?*const fn ([*c]ngx_rbtree_node_t, [*c]ngx_rbtree_node_t, [*c]ngx_rbtree_node_t) callconv(.c) void;
pub const struct_ngx_rbtree_s = extern struct {
    root: [*c]ngx_rbtree_node_t = @import("std").mem.zeroes([*c]ngx_rbtree_node_t),
    sentinel: [*c]ngx_rbtree_node_t = @import("std").mem.zeroes([*c]ngx_rbtree_node_t),
    insert: ngx_rbtree_insert_pt = @import("std").mem.zeroes(ngx_rbtree_insert_pt),
};
pub const ngx_rbtree_t = struct_ngx_rbtree_s;
const struct_ngx_listening_flags_s = packed struct(u32) {
    open: bool,
    remain: bool,
    ignore: bool,
    bound: bool,
    inherited: bool,
    nonblocking_accept: bool,
    listen: bool,
    nonblocking: bool,
    shared: bool,
    addr_ntop: bool,
    wildcard: bool,
    ipv6only: bool,
    reuseport: bool,
    add_reuseport: bool,
    keepalive: u2,
    quic: bool,
    change_protocol: bool,
    deferred_accept: bool,
    delete_deferred: bool,
    add_deferred: bool,
    padding: u11,
};
pub const struct_ngx_listening_s = extern struct {
    fd: ngx_socket_t = @import("std").mem.zeroes(ngx_socket_t),
    sockaddr: [*c]struct_sockaddr = @import("std").mem.zeroes([*c]struct_sockaddr),
    socklen: socklen_t = @import("std").mem.zeroes(socklen_t),
    addr_text_max_len: usize = @import("std").mem.zeroes(usize),
    addr_text: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    type: c_int = @import("std").mem.zeroes(c_int),
    protocol: c_int = @import("std").mem.zeroes(c_int),
    backlog: c_int = @import("std").mem.zeroes(c_int),
    rcvbuf: c_int = @import("std").mem.zeroes(c_int),
    sndbuf: c_int = @import("std").mem.zeroes(c_int),
    keepidle: c_int = @import("std").mem.zeroes(c_int),
    keepintvl: c_int = @import("std").mem.zeroes(c_int),
    keepcnt: c_int = @import("std").mem.zeroes(c_int),
    handler: ?*const fn ([*c]ngx_connection_t) callconv(.c) void = @import("std").mem.zeroes(ngx_connection_handler_pt),
    servers: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    log: ngx_log_t = @import("std").mem.zeroes(ngx_log_t),
    logp: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
    pool_size: usize = @import("std").mem.zeroes(usize),
    post_accept_buffer_size: usize = @import("std").mem.zeroes(usize),
    previous: [*c]ngx_listening_t = @import("std").mem.zeroes([*c]ngx_listening_t),
    connection: [*c]ngx_connection_t = @import("std").mem.zeroes([*c]ngx_connection_t),
    rbtree: ngx_rbtree_t = @import("std").mem.zeroes(ngx_rbtree_t),
    sentinel: ngx_rbtree_node_t = @import("std").mem.zeroes(ngx_rbtree_node_t),
    worker: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    flags: struct_ngx_listening_flags_s = @import("std").mem.zeroes(struct_ngx_listening_flags_s),
    fastopen: c_int = @import("std").mem.zeroes(c_int),
};
pub const ngx_listening_t = struct_ngx_listening_s;
pub const struct_ngx_proxy_protocol_s = extern struct {
    src_addr: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    dst_addr: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    src_port: in_port_t = @import("std").mem.zeroes(in_port_t),
    dst_port: in_port_t = @import("std").mem.zeroes(in_port_t),
    tlvs: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
};
pub const ngx_proxy_protocol_t = struct_ngx_proxy_protocol_s;
pub const struct_ssl_st = opaque {};
pub const SSL = struct_ssl_st;
pub const struct_ssl_ctx_st = opaque {};
pub const SSL_CTX = struct_ssl_ctx_st;
pub const struct_ssl_session_st = opaque {};
pub const SSL_SESSION = struct_ssl_session_st;
pub const struct_ngx_ssl_ocsp_s = opaque {};
pub const ngx_ssl_ocsp_t = struct_ngx_ssl_ocsp_s;
const struct_ngx_ssl_connection_flags_s = packed struct(u32) {
    handshaked: bool,
    handshake_rejected: bool,
    renegotiation: bool,
    buffer: bool,
    sendilfe: bool,
    no_wait_shutdown: bool,
    no_send_shutdown: bool,
    shutdown_without_free: bool,
    handshake_buffer_set: bool,
    session_timeout_set: bool,
    try_early_data: bool,
    in_early: bool,
    in_ocsp: bool,
    early_preread: bool,
    write_blocked: bool,
    padding: u17,
};
pub const struct_ngx_ssl_connection_s = extern struct {
    connection: ?*SSL = @import("std").mem.zeroes(?*SSL),
    session_ctx: ?*SSL_CTX = @import("std").mem.zeroes(?*SSL_CTX),
    last: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
    buf: [*c]ngx_buf_t = @import("std").mem.zeroes([*c]ngx_buf_t),
    buffer_size: usize = @import("std").mem.zeroes(usize),
    handler: ngx_connection_handler_pt = @import("std").mem.zeroes(ngx_connection_handler_pt),
    session: ?*SSL_SESSION = @import("std").mem.zeroes(?*SSL_SESSION),
    save_session: ngx_connection_handler_pt = @import("std").mem.zeroes(ngx_connection_handler_pt),
    saved_read_handler: ngx_event_handler_pt = @import("std").mem.zeroes(ngx_event_handler_pt),
    saved_write_handler: ngx_event_handler_pt = @import("std").mem.zeroes(ngx_event_handler_pt),
    ocsp: ?*ngx_ssl_ocsp_t = @import("std").mem.zeroes(?*ngx_ssl_ocsp_t),
    early_buf: u_char = @import("std").mem.zeroes(u_char),
    flags: struct_ngx_ssl_connection_flags_s = @import("std").mem.zeroes(struct_ngx_ssl_connection_flags_s),
};
pub const ngx_ssl_connection_t = struct_ngx_ssl_connection_s;
pub const struct_ngx_udp_connection_s = extern struct {
    node: ngx_rbtree_node_t = @import("std").mem.zeroes(ngx_rbtree_node_t),
    connection: [*c]ngx_connection_t = @import("std").mem.zeroes([*c]ngx_connection_t),
    buffer: [*c]ngx_buf_t = @import("std").mem.zeroes([*c]ngx_buf_t),
    key: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
};
pub const ngx_udp_connection_t = struct_ngx_udp_connection_s;
pub const ngx_msec_t = ngx_rbtree_key_t;
const struct_ngx_connection_flags_s = packed struct(u32) {
    buffered: u8,
    log_error: u3,
    timedout: bool,
    @"error": bool,
    destroyed: bool,
    pipeline: bool,
    idle: bool,
    resuable: bool,
    close: bool,
    shared: bool,
    snedfile: bool,
    sndlowat: bool,
    tcp_nodelay: u2,
    tcp_nopush: u2,
    need_last_buf: bool,
    need_flush_buf: bool,
    busy_count: u2,
    padding: u3,
};
pub const struct_ngx_connection_s = extern struct {
    data: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    read: [*c]ngx_event_t = @import("std").mem.zeroes([*c]ngx_event_t),
    write: [*c]ngx_event_t = @import("std").mem.zeroes([*c]ngx_event_t),
    fd: ngx_socket_t = @import("std").mem.zeroes(ngx_socket_t),
    recv: ngx_recv_pt = @import("std").mem.zeroes(ngx_recv_pt),
    send: ngx_send_pt = @import("std").mem.zeroes(ngx_send_pt),
    recv_chain: ngx_recv_chain_pt = @import("std").mem.zeroes(ngx_recv_chain_pt),
    send_chain: ngx_send_chain_pt = @import("std").mem.zeroes(ngx_send_chain_pt),
    listening: [*c]ngx_listening_t = @import("std").mem.zeroes([*c]ngx_listening_t),
    sent: off_t = @import("std").mem.zeroes(off_t),
    log: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
    pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    type: c_int = @import("std").mem.zeroes(c_int),
    sockaddr: [*c]struct_sockaddr = @import("std").mem.zeroes([*c]struct_sockaddr),
    socklen: socklen_t = @import("std").mem.zeroes(socklen_t),
    addr_text: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    proxy_protocol: [*c]ngx_proxy_protocol_t = @import("std").mem.zeroes([*c]ngx_proxy_protocol_t),
    quic: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    ssl: [*c]ngx_ssl_connection_t = @import("std").mem.zeroes([*c]ngx_ssl_connection_t),
    udp: [*c]ngx_udp_connection_t = @import("std").mem.zeroes([*c]ngx_udp_connection_t),
    local_sockaddr: [*c]struct_sockaddr = @import("std").mem.zeroes([*c]struct_sockaddr),
    local_socklen: socklen_t = @import("std").mem.zeroes(socklen_t),
    buffer: [*c]ngx_buf_t = @import("std").mem.zeroes([*c]ngx_buf_t),
    queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    number: ngx_atomic_uint_t = @import("std").mem.zeroes(ngx_atomic_uint_t),
    start_time: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    requests: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    flags: struct_ngx_connection_flags_s = @import("std").mem.zeroes(struct_ngx_connection_flags_s),
    sendfile_task: [*c]ngx_thread_task_t = @import("std").mem.zeroes([*c]ngx_thread_task_t),
};
pub const ngx_connection_t = struct_ngx_connection_s;
pub const ngx_module_t = struct_ngx_module_s;
pub const struct_ngx_cycle_s = extern struct {
    conf_ctx: [*c][*c][*c]?*anyopaque = @import("std").mem.zeroes([*c][*c][*c]?*anyopaque),
    pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    log: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
    new_log: ngx_log_t = @import("std").mem.zeroes(ngx_log_t),
    log_use_stderr: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    files: [*c][*c]ngx_connection_t = @import("std").mem.zeroes([*c][*c]ngx_connection_t),
    free_connections: [*c]ngx_connection_t = @import("std").mem.zeroes([*c]ngx_connection_t),
    free_connection_n: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    modules: [*c][*c]ngx_module_t = @import("std").mem.zeroes([*c][*c]ngx_module_t),
    modules_n: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    modules_used: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    reusable_connections_queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    reusable_connections_n: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    connections_reuse_time: time_t = @import("std").mem.zeroes(time_t),
    listening: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
    paths: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
    config_dump: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
    config_dump_rbtree: ngx_rbtree_t = @import("std").mem.zeroes(ngx_rbtree_t),
    config_dump_sentinel: ngx_rbtree_node_t = @import("std").mem.zeroes(ngx_rbtree_node_t),
    open_files: ngx_list_t = @import("std").mem.zeroes(ngx_list_t),
    shared_memory: ngx_list_t = @import("std").mem.zeroes(ngx_list_t),
    connection_n: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    files_n: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    connections: [*c]ngx_connection_t = @import("std").mem.zeroes([*c]ngx_connection_t),
    read_events: [*c]ngx_event_t = @import("std").mem.zeroes([*c]ngx_event_t),
    write_events: [*c]ngx_event_t = @import("std").mem.zeroes([*c]ngx_event_t),
    old_cycle: [*c]ngx_cycle_t = @import("std").mem.zeroes([*c]ngx_cycle_t),
    conf_file: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    conf_param: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    conf_prefix: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    prefix: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    error_log: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    lock_file: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    hostname: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
};
pub const ngx_cycle_t = struct_ngx_cycle_s;
pub const ngx_conf_handler_pt = ?*const fn ([*c]ngx_conf_t, [*c]ngx_command_t, ?*anyopaque) callconv(.c) [*c]u8;
pub const struct_ngx_conf_s = extern struct {
    name: [*c]u8 = @import("std").mem.zeroes([*c]u8),
    args: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    cycle: [*c]ngx_cycle_t = @import("std").mem.zeroes([*c]ngx_cycle_t),
    pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    temp_pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    conf_file: [*c]ngx_conf_file_t = @import("std").mem.zeroes([*c]ngx_conf_file_t),
    log: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
    ctx: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    module_type: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    cmd_type: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    handler: ngx_conf_handler_pt = @import("std").mem.zeroes(ngx_conf_handler_pt),
    handler_conf: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
};
pub const ngx_conf_t = struct_ngx_conf_s;
pub const struct_ngx_command_s = extern struct {
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    type: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    set: ?*const fn ([*c]ngx_conf_t, [*c]ngx_command_t, ?*anyopaque) callconv(.c) [*c]u8 = @import("std").mem.zeroes(?*const fn ([*c]ngx_conf_t, [*c]ngx_command_t, ?*anyopaque) callconv(.c) [*c]u8),
    conf: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    offset: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    post: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
};
pub const ngx_command_t = struct_ngx_command_s;
pub const struct_ngx_module_s = extern struct {
    ctx_index: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    index: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    name: [*c]u8 = @import("std").mem.zeroes([*c]u8),
    spare0: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    spare1: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    version: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    signature: [*c]const u8 = @import("std").mem.zeroes([*c]const u8),
    ctx: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    commands: [*c]ngx_command_t = @import("std").mem.zeroes([*c]ngx_command_t),
    type: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    init_master: ?*const fn ([*c]ngx_log_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_log_t) callconv(.c) ngx_int_t),
    init_module: ?*const fn ([*c]ngx_cycle_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_cycle_t) callconv(.c) ngx_int_t),
    init_process: ?*const fn ([*c]ngx_cycle_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_cycle_t) callconv(.c) ngx_int_t),
    init_thread: ?*const fn ([*c]ngx_cycle_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_cycle_t) callconv(.c) ngx_int_t),
    exit_thread: ?*const fn ([*c]ngx_cycle_t) callconv(.c) void = @import("std").mem.zeroes(?*const fn ([*c]ngx_cycle_t) callconv(.c) void),
    exit_process: ?*const fn ([*c]ngx_cycle_t) callconv(.c) void = @import("std").mem.zeroes(?*const fn ([*c]ngx_cycle_t) callconv(.c) void),
    exit_master: ?*const fn ([*c]ngx_cycle_t) callconv(.c) void = @import("std").mem.zeroes(?*const fn ([*c]ngx_cycle_t) callconv(.c) void),
    spare_hook0: usize = @import("std").mem.zeroes(usize),
    spare_hook1: usize = @import("std").mem.zeroes(usize),
    spare_hook2: usize = @import("std").mem.zeroes(usize),
    spare_hook3: usize = @import("std").mem.zeroes(usize),
    spare_hook4: usize = @import("std").mem.zeroes(usize),
    spare_hook5: usize = @import("std").mem.zeroes(usize),
    spare_hook6: usize = @import("std").mem.zeroes(usize),
    spare_hook7: usize = @import("std").mem.zeroes(usize),
};
pub const struct_ngx_event_aio_s = opaque {};
pub const ngx_event_aio_t = struct_ngx_event_aio_s;
pub const struct_ngx_thread_task_s = extern struct {
    next: [*c]ngx_thread_task_t = @import("std").mem.zeroes([*c]ngx_thread_task_t),
    id: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    ctx: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    handler: ?*const fn (?*anyopaque, [*c]ngx_log_t) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*anyopaque, [*c]ngx_log_t) callconv(.c) void),
    event: ngx_event_t = @import("std").mem.zeroes(ngx_event_t),
};
pub const ngx_thread_task_t = struct_ngx_thread_task_s;
pub const struct_ngx_ssl_s = extern struct {
    ctx: ?*SSL_CTX = @import("std").mem.zeroes(?*SSL_CTX),
    log: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
    buffer_size: usize = @import("std").mem.zeroes(usize),
    certs: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
    staple_rbtree: ngx_rbtree_t = @import("std").mem.zeroes(ngx_rbtree_t),
    staple_sentinel: ngx_rbtree_node_t = @import("std").mem.zeroes(ngx_rbtree_node_t),
};
pub const ngx_ssl_t = struct_ngx_ssl_s;
pub const ngx_err_t = c_int;
pub const ngx_atomic_t = ngx_atomic_uint_t;
pub extern fn ngx_rbtree_insert(tree: [*c]ngx_rbtree_t, node: [*c]ngx_rbtree_node_t) void;
pub extern fn ngx_rbtree_delete(tree: [*c]ngx_rbtree_t, node: [*c]ngx_rbtree_node_t) void;
pub const ngx_str_t = extern struct {
    len: usize = @import("std").mem.zeroes(usize),
    data: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
};
pub const ngx_keyval_t = extern struct {
    key: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    value: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
};
const ngx_variable_value_flags_t = packed struct(u32) {
    len: u28,
    valid: bool,
    no_cacheable: bool,
    not_found: bool,
    escape: bool,
};
pub const ngx_variable_value_t = extern struct {
    flags: ngx_variable_value_flags_t = @import("std").mem.zeroes(ngx_variable_value_flags_t),
    data: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
};
pub extern fn ngx_strlow(dst: [*c]u_char, src: [*c]u_char, n: usize) void;
pub extern fn ngx_sprintf(buf: [*c]u_char, fmt: [*c]const u8, ...) [*c]u_char;
pub extern fn ngx_snprintf(buf: [*c]u_char, max: usize, fmt: [*c]const u8, ...) [*c]u_char;
pub extern fn ngx_slprintf(buf: [*c]u_char, last: [*c]u_char, fmt: [*c]const u8, ...) [*c]u_char;
pub extern fn ngx_vslprintf(buf: [*c]u_char, last: [*c]u_char, fmt: [*c]const u8, args: [*c]struct___va_list_tag_5) [*c]u_char;
pub extern fn ngx_hex_dump(dst: [*c]u_char, src: [*c]u_char, len: usize) [*c]u_char;
pub extern fn ngx_encode_base64(dst: [*c]ngx_str_t, src: [*c]ngx_str_t) void;
pub extern fn ngx_decode_base64(dst: [*c]ngx_str_t, src: [*c]ngx_str_t) ngx_int_t;
pub extern fn ngx_escape_uri(dst: [*c]u_char, src: [*c]u_char, size: usize, @"type": ngx_uint_t) usize;
pub extern fn ngx_unescape_uri(dst: [*c][*c]u_char, src: [*c][*c]u_char, size: usize, @"type": ngx_uint_t) void;
pub const ngx_file_uniq_t = ino_t;
const ngx_dir_flags_t = packed struct(u32) {
    type: u8,
    valid_info: bool,
    padding: u23,
};
pub const ngx_dir_t = extern struct {
    dir: ?*DIR = @import("std").mem.zeroes(?*DIR),
    de: [*c]struct_dirent = @import("std").mem.zeroes([*c]struct_dirent),
    info: struct_stat = @import("std").mem.zeroes(struct_stat),
    flags: ngx_dir_flags_t = @import("std").mem.zeroes(ngx_dir_flags_t),
};
pub extern fn ngx_open_tempfile(name: [*c]u_char, persistent: ngx_uint_t, access: ngx_uint_t) ngx_fd_t;
pub extern fn ngx_read_file(file: [*c]ngx_file_t, buf: [*c]u_char, size: usize, offset: off_t) isize;
pub extern fn ngx_write_file(file: [*c]ngx_file_t, buf: [*c]u_char, size: usize, offset: off_t) isize;
pub const ngx_shm_t = extern struct {
    addr: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    size: usize = @import("std").mem.zeroes(usize),
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    log: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
    exists: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
pub const ngx_pid_t = pid_t;
pub const ngx_spawn_proc_pt = ?*const fn ([*c]ngx_cycle_t, ?*anyopaque) callconv(.c) void;
const ngx_process_flags_t = packed struct(u32) {
    respawn: bool,
    just_spawn: bool,
    detached: bool,
    exiting: bool,
    exited: bool,
    padding: u27,
};
pub const ngx_process_t = extern struct {
    pid: ngx_pid_t = @import("std").mem.zeroes(ngx_pid_t),
    status: c_int = @import("std").mem.zeroes(c_int),
    channel: [2]ngx_socket_t = @import("std").mem.zeroes([2]ngx_socket_t),
    proc: ngx_spawn_proc_pt = @import("std").mem.zeroes(ngx_spawn_proc_pt),
    data: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    name: [*c]u8 = @import("std").mem.zeroes([*c]u8),
    flags: ngx_process_flags_t = @import("std").mem.zeroes(ngx_process_flags_t),
};
pub extern fn ngx_log_error_core(level: ngx_uint_t, log: [*c]ngx_log_t, err: ngx_err_t, fmt: [*c]const u8, ...) void;
pub extern fn ngx_log_init(prefix: [*c]u_char, error_log: [*c]u_char) [*c]ngx_log_t;
pub const ngx_pool_data_t = extern struct {
    last: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    end: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    next: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    failed: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
pub extern fn ngx_create_pool(size: usize, log: [*c]ngx_log_t) [*c]ngx_pool_t;
pub extern fn ngx_destroy_pool(pool: [*c]ngx_pool_t) void;
pub extern fn ngx_palloc(pool: [*c]ngx_pool_t, size: usize) ?*anyopaque;
pub extern fn ngx_pnalloc(pool: [*c]ngx_pool_t, size: usize) ?*anyopaque;
pub extern fn ngx_pcalloc(pool: [*c]ngx_pool_t, size: usize) ?*anyopaque;
pub extern fn ngx_pmemalign(pool: [*c]ngx_pool_t, size: usize, alignment: usize) ?*anyopaque;
pub extern fn ngx_pfree(pool: [*c]ngx_pool_t, p: ?*anyopaque) ngx_int_t;
pub extern fn ngx_pool_cleanup_add(p: [*c]ngx_pool_t, size: usize) [*c]ngx_pool_cleanup_t;
pub const ngx_bufs_t = extern struct {
    num: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
    size: usize = @import("std").mem.zeroes(usize),
};
pub const ngx_output_chain_filter_pt = ?*const fn (?*anyopaque, [*c]ngx_chain_t) callconv(.c) ngx_int_t;
const struct_ngx_output_chain_ctx_flags_s = packed struct(u32) {
    sendfile: bool,
    directio: bool,
    unaligned: bool,
    need_in_memory: bool,
    need_in_temp: bool,
    aio: bool,
    padding: u26,
};
pub const ngx_output_chain_aio_pt = ?*const fn ([*c]ngx_output_chain_ctx_t, [*c]ngx_file_t) callconv(.c) void;
pub const struct_ngx_output_chain_ctx_s = extern struct {
    buf: [*c]ngx_buf_t = @import("std").mem.zeroes([*c]ngx_buf_t),
    in: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    free: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    busy: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    flags: struct_ngx_output_chain_ctx_flags_s = @import("std").mem.zeroes(struct_ngx_output_chain_ctx_flags_s),
    aio_handler: ngx_output_chain_aio_pt = @import("std").mem.zeroes(ngx_output_chain_aio_pt),
    thread_handler: ?*const fn ([*c]ngx_thread_task_t, [*c]ngx_file_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_thread_task_t, [*c]ngx_file_t) callconv(.c) ngx_int_t),
    thread_task: [*c]ngx_thread_task_t = @import("std").mem.zeroes([*c]ngx_thread_task_t),
    alignment: off_t = @import("std").mem.zeroes(off_t),
    pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    allocated: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
    bufs: ngx_bufs_t = @import("std").mem.zeroes(ngx_bufs_t),
    tag: ngx_buf_tag_t = @import("std").mem.zeroes(ngx_buf_tag_t),
    output_filter: ngx_output_chain_filter_pt = @import("std").mem.zeroes(ngx_output_chain_filter_pt),
    filter_ctx: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
};
pub const ngx_output_chain_ctx_t = struct_ngx_output_chain_ctx_s;
pub const ngx_chain_writer_ctx_t = extern struct {
    out: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    last: [*c][*c]ngx_chain_t = @import("std").mem.zeroes([*c][*c]ngx_chain_t),
    connection: [*c]ngx_connection_t = @import("std").mem.zeroes([*c]ngx_connection_t),
    pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    limit: off_t = @import("std").mem.zeroes(off_t),
};
pub extern fn ngx_create_temp_buf(pool: [*c]ngx_pool_t, size: usize) [*c]ngx_buf_t;
pub extern fn ngx_alloc_chain_link(pool: [*c]ngx_pool_t) [*c]ngx_chain_t;
pub extern fn ngx_chain_get_free_buf(p: [*c]ngx_pool_t, free: [*c][*c]ngx_chain_t) [*c]ngx_chain_t;
pub extern fn ngx_chain_update_chains(p: [*c]ngx_pool_t, free: [*c][*c]ngx_chain_t, busy: [*c][*c]ngx_chain_t, out: [*c][*c]ngx_chain_t, tag: ngx_buf_tag_t) void;
pub const ngx_array_t = extern struct {
    elts: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    nelts: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    size: usize = @import("std").mem.zeroes(usize),
    nalloc: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
};
pub extern fn ngx_array_create(p: [*c]ngx_pool_t, n: ngx_uint_t, size: usize) [*c]ngx_array_t;
pub extern fn ngx_array_destroy(a: [*c]ngx_array_t) void;
pub extern fn ngx_array_push(a: [*c]ngx_array_t) ?*anyopaque;
pub const ngx_list_part_t = struct_ngx_list_part_s;
pub const struct_ngx_list_part_s = extern struct {
    elts: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    nelts: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    next: [*c]ngx_list_part_t = @import("std").mem.zeroes([*c]ngx_list_part_t),
};
pub const ngx_list_t = extern struct {
    last: [*c]ngx_list_part_t = @import("std").mem.zeroes([*c]ngx_list_part_t),
    part: ngx_list_part_t = @import("std").mem.zeroes(ngx_list_part_t),
    size: usize = @import("std").mem.zeroes(usize),
    nalloc: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
};
pub extern fn ngx_list_create(pool: [*c]ngx_pool_t, n: ngx_uint_t, size: usize) [*c]ngx_list_t;
pub extern fn ngx_list_push(list: [*c]ngx_list_t) ?*anyopaque;
pub const ngx_hash_elt_t = extern struct {
    value: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    len: u_short = @import("std").mem.zeroes(u_short),
    name: [1]u_char = @import("std").mem.zeroes([1]u_char),
};
pub const ngx_hash_t = extern struct {
    buckets: [*c][*c]ngx_hash_elt_t = @import("std").mem.zeroes([*c][*c]ngx_hash_elt_t),
    size: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
pub const ngx_hash_wildcard_t = extern struct {
    hash: ngx_hash_t = @import("std").mem.zeroes(ngx_hash_t),
    value: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
};
pub const ngx_hash_key_t = extern struct {
    key: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    key_hash: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    value: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
};
pub const ngx_hash_key_pt = ?*const fn ([*c]u_char, usize) callconv(.c) ngx_uint_t;
pub const ngx_hash_combined_t = extern struct {
    hash: ngx_hash_t = @import("std").mem.zeroes(ngx_hash_t),
    wc_head: [*c]ngx_hash_wildcard_t = @import("std").mem.zeroes([*c]ngx_hash_wildcard_t),
    wc_tail: [*c]ngx_hash_wildcard_t = @import("std").mem.zeroes([*c]ngx_hash_wildcard_t),
};
pub const ngx_hash_init_t = extern struct {
    hash: [*c]ngx_hash_t = @import("std").mem.zeroes([*c]ngx_hash_t),
    key: ngx_hash_key_pt = @import("std").mem.zeroes(ngx_hash_key_pt),
    max_size: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    bucket_size: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    name: [*c]u8 = @import("std").mem.zeroes([*c]u8),
    pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    temp_pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
};
pub const ngx_hash_keys_arrays_t = extern struct {
    hsize: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    temp_pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    keys: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
    keys_hash: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    dns_wc_head: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
    dns_wc_head_hash: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    dns_wc_tail: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
    dns_wc_tail_hash: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
};
pub const ngx_table_elt_t = struct_ngx_table_elt_s;
pub const struct_ngx_table_elt_s = extern struct {
    hash: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    key: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    value: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    lowcase_key: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    next: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
};
pub extern fn ngx_hash_find(hash: [*c]ngx_hash_t, key: ngx_uint_t, name: [*c]u_char, len: usize) ?*anyopaque;
pub extern fn ngx_hash_init(hinit: [*c]ngx_hash_init_t, names: [*c]ngx_hash_key_t, nelts: ngx_uint_t) ngx_int_t;
pub extern fn ngx_hash_key(data: [*c]u_char, len: usize) ngx_uint_t;
pub extern fn ngx_hash_key_lc(data: [*c]u_char, len: usize) ngx_uint_t;
pub extern fn ngx_hash_keys_array_init(ha: [*c]ngx_hash_keys_arrays_t, @"type": ngx_uint_t) ngx_int_t;
pub extern fn ngx_hash_add_key(ha: [*c]ngx_hash_keys_arrays_t, key: [*c]ngx_str_t, value: ?*anyopaque, flags: ngx_uint_t) ngx_int_t;
pub const ngx_path_manager_pt = ?*const fn (?*anyopaque) callconv(.c) ngx_msec_t;
pub const ngx_path_purger_pt = ?*const fn (?*anyopaque) callconv(.c) ngx_msec_t;
pub const ngx_path_loader_pt = ?*const fn (?*anyopaque) callconv(.c) void;
pub const ngx_path_t = extern struct {
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    len: usize = @import("std").mem.zeroes(usize),
    level: [3]usize = @import("std").mem.zeroes([3]usize),
    manager: ngx_path_manager_pt = @import("std").mem.zeroes(ngx_path_manager_pt),
    purger: ngx_path_purger_pt = @import("std").mem.zeroes(ngx_path_purger_pt),
    loader: ngx_path_loader_pt = @import("std").mem.zeroes(ngx_path_loader_pt),
    data: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    conf_file: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    line: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
const ngx_temp_file_flags_t = packed struct(u32) {
    log_level: u8,
    persistent: bool,
    clean: bool,
    thread_write: bool,
    padding: u21,
};
pub const ngx_temp_file_t = extern struct {
    file: ngx_file_t = @import("std").mem.zeroes(ngx_file_t),
    offset: off_t = @import("std").mem.zeroes(off_t),
    path: [*c]ngx_path_t = @import("std").mem.zeroes([*c]ngx_path_t),
    pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    warn: [*c]u8 = @import("std").mem.zeroes([*c]u8),
    access: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    flags: ngx_temp_file_flags_t = @import("std").mem.zeroes(ngx_temp_file_flags_t),
};
const ngx_ext_rename_file_flags_t = packed struct(u32) {
    create_path: bool,
    delete_file: bool,
    padding: u30,
};
pub const ngx_ext_rename_file_t = extern struct {
    access: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    path_access: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    time: time_t = @import("std").mem.zeroes(time_t),
    fd: ngx_fd_t = @import("std").mem.zeroes(ngx_fd_t),
    flags: ngx_ext_rename_file_flags_t = @import("std").mem.zeroes(ngx_ext_rename_file_flags_t),
    log: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
};
pub const struct_pcre2_real_code_8 = opaque {};
pub const pcre2_code_8 = struct_pcre2_real_code_8;
pub const ngx_regex_t = pcre2_code_8;
pub const ngx_regex_compile_t = extern struct {
    pattern: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    options: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    regex: ?*ngx_regex_t = @import("std").mem.zeroes(?*ngx_regex_t),
    captures: c_int = @import("std").mem.zeroes(c_int),
    named_captures: c_int = @import("std").mem.zeroes(c_int),
    name_size: c_int = @import("std").mem.zeroes(c_int),
    names: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    err: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
};
pub extern fn ngx_regex_compile(rc: [*c]ngx_regex_compile_t) ngx_int_t;
pub extern fn ngx_regex_exec(re: ?*ngx_regex_t, s: [*c]ngx_str_t, captures: [*c]c_int, size: ngx_uint_t) ngx_int_t;
pub const ngx_time_t = extern struct {
    sec: time_t = @import("std").mem.zeroes(time_t),
    msec: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    gmtoff: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
};
pub extern fn ngx_time_init() void;
pub extern var ngx_cached_time: [*c]volatile ngx_time_t;
pub const ngx_shmtx_sh_t = extern struct {
    lock: ngx_atomic_t = @import("std").mem.zeroes(ngx_atomic_t),
    wait: ngx_atomic_t = @import("std").mem.zeroes(ngx_atomic_t),
};
pub const ngx_shmtx_t = extern struct {
    lock: [*c]volatile ngx_atomic_t = @import("std").mem.zeroes([*c]volatile ngx_atomic_t),
    wait: [*c]volatile ngx_atomic_t = @import("std").mem.zeroes([*c]volatile ngx_atomic_t),
    semaphore: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    sem: sem_t = @import("std").mem.zeroes(sem_t),
    spin: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
pub extern fn ngx_shmtx_lock(mtx: [*c]ngx_shmtx_t) void;
pub extern fn ngx_shmtx_unlock(mtx: [*c]ngx_shmtx_t) void;
pub const ngx_slab_page_t = struct_ngx_slab_page_s;
pub const struct_ngx_slab_page_s = extern struct {
    slab: usize = @import("std").mem.zeroes(usize),
    next: [*c]ngx_slab_page_t = @import("std").mem.zeroes([*c]ngx_slab_page_t),
    prev: usize = @import("std").mem.zeroes(usize),
};
pub const ngx_slab_stat_t = extern struct {
    total: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    used: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    reqs: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    fails: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
const ngx_slab_pool_flags_t = packed struct(u32) {
    log_nomem: bool,
    padding: u31,
};
pub const ngx_slab_pool_t = extern struct {
    lock: ngx_shmtx_sh_t = @import("std").mem.zeroes(ngx_shmtx_sh_t),
    min_size: usize = @import("std").mem.zeroes(usize),
    min_shift: usize = @import("std").mem.zeroes(usize),
    pages: [*c]ngx_slab_page_t = @import("std").mem.zeroes([*c]ngx_slab_page_t),
    last: [*c]ngx_slab_page_t = @import("std").mem.zeroes([*c]ngx_slab_page_t),
    free: ngx_slab_page_t = @import("std").mem.zeroes(ngx_slab_page_t),
    stats: [*c]ngx_slab_stat_t = @import("std").mem.zeroes([*c]ngx_slab_stat_t),
    pfree: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    start: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    end: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    mutex: ngx_shmtx_t = @import("std").mem.zeroes(ngx_shmtx_t),
    log_ctx: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    zero: u_char = @import("std").mem.zeroes(u_char),
    flags: ngx_slab_pool_flags_t = @import("std").mem.zeroes(ngx_slab_pool_flags_t),
    data: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    addr: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
};
pub extern fn ngx_slab_init(pool: [*c]ngx_slab_pool_t) void;
pub extern fn ngx_slab_alloc_locked(pool: [*c]ngx_slab_pool_t, size: usize) ?*anyopaque;
pub extern fn ngx_slab_calloc(pool: [*c]ngx_slab_pool_t, size: usize) ?*anyopaque;
pub extern fn ngx_slab_calloc_locked(pool: [*c]ngx_slab_pool_t, size: usize) ?*anyopaque;
pub extern fn ngx_slab_free_locked(pool: [*c]ngx_slab_pool_t, p: ?*anyopaque) void;
pub const ngx_sockaddr_t = extern union {
    sockaddr: struct_sockaddr,
    sockaddr_in: struct_sockaddr_in,
    sockaddr_in6: struct_sockaddr_in6,
    sockaddr_un: struct_sockaddr_un,
};
pub const ngx_in_cidr_t = extern struct {
    addr: in_addr_t = @import("std").mem.zeroes(in_addr_t),
    mask: in_addr_t = @import("std").mem.zeroes(in_addr_t),
};
pub const ngx_in6_cidr_t = extern struct {
    addr: struct_in6_addr = @import("std").mem.zeroes(struct_in6_addr),
    mask: struct_in6_addr = @import("std").mem.zeroes(struct_in6_addr),
};
const union_unnamed_81 = extern union {
    in: ngx_in_cidr_t,
    in6: ngx_in6_cidr_t,
};
pub const ngx_cidr_t = extern struct {
    family: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    u: union_unnamed_81 = @import("std").mem.zeroes(union_unnamed_81),
};
pub const ngx_addr_t = extern struct {
    sockaddr: [*c]struct_sockaddr = @import("std").mem.zeroes([*c]struct_sockaddr),
    socklen: socklen_t = @import("std").mem.zeroes(socklen_t),
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
};
const ngx_url_flags_t = packed struct(u32) {
    listen: bool,
    uri_part: bool,
    no_resolve: bool,
    no_port: bool,
    wildcard: bool,
    padding: u27,
};
pub const ngx_url_t = extern struct {
    url: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    host: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    port_text: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    uri: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    port: in_port_t = @import("std").mem.zeroes(in_port_t),
    default_port: in_port_t = @import("std").mem.zeroes(in_port_t),
    last_port: in_port_t = @import("std").mem.zeroes(in_port_t),
    family: c_int = @import("std").mem.zeroes(c_int),
    flags: ngx_url_flags_t = @import("std").mem.zeroes(ngx_url_flags_t),
    socklen: socklen_t = @import("std").mem.zeroes(socklen_t),
    sockaddr: ngx_sockaddr_t = @import("std").mem.zeroes(ngx_sockaddr_t),
    addrs: [*c]ngx_addr_t = @import("std").mem.zeroes([*c]ngx_addr_t),
    naddrs: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    err: [*c]u8 = @import("std").mem.zeroes([*c]u8),
};
pub extern fn ngx_ptocidr(text: [*c]ngx_str_t, cidr: [*c]ngx_cidr_t) ngx_int_t;
pub extern fn ngx_parse_url(pool: [*c]ngx_pool_t, u: [*c]ngx_url_t) ngx_int_t;
pub const ngx_shm_zone_t = struct_ngx_shm_zone_s;
pub const ngx_shm_zone_init_pt = ?*const fn ([*c]ngx_shm_zone_t, ?*anyopaque) callconv(.c) ngx_int_t;
pub const struct_ngx_shm_zone_s = extern struct {
    data: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    shm: ngx_shm_t = @import("std").mem.zeroes(ngx_shm_t),
    init: ngx_shm_zone_init_pt = @import("std").mem.zeroes(ngx_shm_zone_init_pt),
    tag: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    sync: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    noreuse: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
pub extern fn ngx_shared_memory_add(cf: [*c]ngx_conf_t, name: [*c]ngx_str_t, size: usize, tag: ?*anyopaque) [*c]ngx_shm_zone_t;
const struct_ngx_resolver_flags_s = packed struct(u32) {
    ipv4: bool,
    ipv6: bool,
    padding: u30,
};
pub const struct_ngx_resolver_s = extern struct {
    event: [*c]ngx_event_t = @import("std").mem.zeroes([*c]ngx_event_t),
    dummy: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    log: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
    ident: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
    connections: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
    last_connection: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    name_rbtree: ngx_rbtree_t = @import("std").mem.zeroes(ngx_rbtree_t),
    name_sentinel: ngx_rbtree_node_t = @import("std").mem.zeroes(ngx_rbtree_node_t),
    srv_rbtree: ngx_rbtree_t = @import("std").mem.zeroes(ngx_rbtree_t),
    srv_sentinel: ngx_rbtree_node_t = @import("std").mem.zeroes(ngx_rbtree_node_t),
    addr_rbtree: ngx_rbtree_t = @import("std").mem.zeroes(ngx_rbtree_t),
    addr_sentinel: ngx_rbtree_node_t = @import("std").mem.zeroes(ngx_rbtree_node_t),
    name_resend_queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    srv_resend_queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    addr_resend_queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    name_expire_queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    srv_expire_queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    addr_expire_queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    flags: struct_ngx_resolver_flags_s = @import("std").mem.zeroes(struct_ngx_resolver_flags_s),
    addr6_rbtree: ngx_rbtree_t = @import("std").mem.zeroes(ngx_rbtree_t),
    addr6_sentinel: ngx_rbtree_node_t = @import("std").mem.zeroes(ngx_rbtree_node_t),
    addr6_resend_queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    addr6_expire_queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    resend_timeout: time_t = @import("std").mem.zeroes(time_t),
    tcp_timeout: time_t = @import("std").mem.zeroes(time_t),
    expire: time_t = @import("std").mem.zeroes(time_t),
    valid: time_t = @import("std").mem.zeroes(time_t),
    log_level: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
pub const ngx_resolver_t = struct_ngx_resolver_s;
pub const ngx_resolver_ctx_t = struct_ngx_resolver_ctx_s;
pub const ngx_resolver_handler_pt = ?*const fn ([*c]ngx_resolver_ctx_t) callconv(.c) void;
const struct_ngx_resolver_ctx_flags_s = packed struct(u32) {
    quick: bool,
    @"async": bool,
    cancelable: bool,
    padding: u29,
};
pub const struct_ngx_resolver_ctx_s = extern struct {
    next: [*c]ngx_resolver_ctx_t = @import("std").mem.zeroes([*c]ngx_resolver_ctx_t),
    resolver: [*c]ngx_resolver_t = @import("std").mem.zeroes([*c]ngx_resolver_t),
    node: [*c]ngx_resolver_node_t = @import("std").mem.zeroes([*c]ngx_resolver_node_t),
    ident: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
    state: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    service: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    valid: time_t = @import("std").mem.zeroes(time_t),
    naddrs: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    addrs: [*c]ngx_resolver_addr_t = @import("std").mem.zeroes([*c]ngx_resolver_addr_t),
    addr: ngx_resolver_addr_t = @import("std").mem.zeroes(ngx_resolver_addr_t),
    sin: struct_sockaddr_in = @import("std").mem.zeroes(struct_sockaddr_in),
    count: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    nsrvs: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    srvs: [*c]ngx_resolver_srv_name_t = @import("std").mem.zeroes([*c]ngx_resolver_srv_name_t),
    handler: ngx_resolver_handler_pt = @import("std").mem.zeroes(ngx_resolver_handler_pt),
    data: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    flags: struct_ngx_resolver_ctx_flags_s = @import("std").mem.zeroes(struct_ngx_resolver_ctx_flags_s),
    recursion: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    event: [*c]ngx_event_t = @import("std").mem.zeroes([*c]ngx_event_t),
};
pub const ngx_resolver_addr_t = extern struct {
    sockaddr: [*c]struct_sockaddr = @import("std").mem.zeroes([*c]struct_sockaddr),
    socklen: socklen_t = @import("std").mem.zeroes(socklen_t),
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    priority: u_short = @import("std").mem.zeroes(u_short),
    weight: u_short = @import("std").mem.zeroes(u_short),
};
pub const ngx_resolver_srv_t = extern struct {
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    priority: u_short = @import("std").mem.zeroes(u_short),
    weight: u_short = @import("std").mem.zeroes(u_short),
    port: u_short = @import("std").mem.zeroes(u_short),
};
pub const ngx_resolver_srv_name_t = extern struct {
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    priority: u_short = @import("std").mem.zeroes(u_short),
    weight: u_short = @import("std").mem.zeroes(u_short),
    port: u_short = @import("std").mem.zeroes(u_short),
    ctx: [*c]ngx_resolver_ctx_t = @import("std").mem.zeroes([*c]ngx_resolver_ctx_t),
    state: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
    naddrs: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    addrs: [*c]ngx_addr_t = @import("std").mem.zeroes([*c]ngx_addr_t),
};
const union_unnamed_82 = extern union {
    addr: in_addr_t,
    addrs: [*c]in_addr_t,
    cname: [*c]u_char,
    srvs: [*c]ngx_resolver_srv_t,
};
const union_unnamed_83 = extern union {
    addr6: struct_in6_addr,
    addrs6: [*c]struct_in6_addr,
};
const ngx_resolver_node_flags_t = packed struct(u32) {
    tcp: bool,
    tcp6: bool,
    padding: u30,
};
pub const ngx_resolver_node_t = extern struct {
    node: ngx_rbtree_node_t = @import("std").mem.zeroes(ngx_rbtree_node_t),
    queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    name: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    addr6: struct_in6_addr = @import("std").mem.zeroes(struct_in6_addr),
    nlen: u_short = @import("std").mem.zeroes(u_short),
    qlen: u_short = @import("std").mem.zeroes(u_short),
    query: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    query6: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    u: union_unnamed_82 = @import("std").mem.zeroes(union_unnamed_82),
    code: u_char = @import("std").mem.zeroes(u_char),
    naddrs: u_short = @import("std").mem.zeroes(u_short),
    nsrvs: u_short = @import("std").mem.zeroes(u_short),
    cnlen: u_short = @import("std").mem.zeroes(u_short),
    u6: union_unnamed_83 = @import("std").mem.zeroes(union_unnamed_83),
    naddrs6: u_short = @import("std").mem.zeroes(u_short),
    expire: time_t = @import("std").mem.zeroes(time_t),
    valid: time_t = @import("std").mem.zeroes(time_t),
    ttl: u32 = @import("std").mem.zeroes(u32),
    flags: ngx_resolver_node_flags_t = @import("std").mem.zeroes(ngx_resolver_node_flags_t),
    last_connection: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    waiting: [*c]ngx_resolver_ctx_t = @import("std").mem.zeroes([*c]ngx_resolver_ctx_t),
};
pub const struct_stack_st = opaque {};
pub const OPENSSL_STACK = struct_stack_st;
pub const OPENSSL_sk_freefunc = ?*const fn (?*anyopaque) callconv(.c) void;
pub extern fn OPENSSL_sk_num(?*const OPENSSL_STACK) c_int;
pub extern fn OPENSSL_sk_value(?*const OPENSSL_STACK, c_int) ?*anyopaque;
pub extern fn OPENSSL_sk_pop_free(st: ?*OPENSSL_STACK, func: ?*const fn (?*anyopaque) callconv(.c) void) void;
pub const struct_asn1_string_st = extern struct {
    length: c_int = @import("std").mem.zeroes(c_int),
    type: c_int = @import("std").mem.zeroes(c_int),
    data: [*c]u8 = @import("std").mem.zeroes([*c]u8),
    flags: c_long = @import("std").mem.zeroes(c_long),
};
pub const ASN1_INTEGER = struct_asn1_string_st;
pub const ASN1_ENUMERATED = struct_asn1_string_st;
pub const ASN1_BIT_STRING = struct_asn1_string_st;
pub const ASN1_OCTET_STRING = struct_asn1_string_st;
pub const ASN1_PRINTABLESTRING = struct_asn1_string_st;
pub const ASN1_T61STRING = struct_asn1_string_st;
pub const ASN1_IA5STRING = struct_asn1_string_st;
pub const ASN1_GENERALSTRING = struct_asn1_string_st;
pub const ASN1_UNIVERSALSTRING = struct_asn1_string_st;
pub const ASN1_BMPSTRING = struct_asn1_string_st;
pub const ASN1_UTCTIME = struct_asn1_string_st;
pub const ASN1_TIME = struct_asn1_string_st;
pub const ASN1_GENERALIZEDTIME = struct_asn1_string_st;
pub const ASN1_VISIBLESTRING = struct_asn1_string_st;
pub const ASN1_UTF8STRING = struct_asn1_string_st;
pub const ASN1_STRING = struct_asn1_string_st;
pub const ASN1_BOOLEAN = c_int;
pub const struct_asn1_object_st = opaque {};
pub const ASN1_OBJECT = struct_asn1_object_st;
pub const struct_ASN1_VALUE_st = opaque {};
pub const ASN1_VALUE = struct_ASN1_VALUE_st;
const union_unnamed_84 = extern union {
    ptr: [*c]u8,
    boolean: ASN1_BOOLEAN,
    asn1_string: [*c]ASN1_STRING,
    object: ?*ASN1_OBJECT,
    integer: [*c]ASN1_INTEGER,
    enumerated: [*c]ASN1_ENUMERATED,
    bit_string: [*c]ASN1_BIT_STRING,
    octet_string: [*c]ASN1_OCTET_STRING,
    printablestring: [*c]ASN1_PRINTABLESTRING,
    t61string: [*c]ASN1_T61STRING,
    ia5string: [*c]ASN1_IA5STRING,
    generalstring: [*c]ASN1_GENERALSTRING,
    bmpstring: [*c]ASN1_BMPSTRING,
    universalstring: [*c]ASN1_UNIVERSALSTRING,
    utctime: [*c]ASN1_UTCTIME,
    generalizedtime: [*c]ASN1_GENERALIZEDTIME,
    visiblestring: [*c]ASN1_VISIBLESTRING,
    utf8string: [*c]ASN1_UTF8STRING,
    set: [*c]ASN1_STRING,
    sequence: [*c]ASN1_STRING,
    asn1_value: ?*ASN1_VALUE,
};
pub const struct_asn1_type_st = extern struct {
    type: c_int = @import("std").mem.zeroes(c_int),
    value: union_unnamed_84 = @import("std").mem.zeroes(union_unnamed_84),
};
pub const ASN1_TYPE = struct_asn1_type_st;
pub const struct_bio_st = opaque {};
pub const BIO = struct_bio_st;
pub const struct_bignum_st = opaque {};
pub const BIGNUM = struct_bignum_st;
pub const struct_evp_cipher_st = opaque {};
pub const EVP_CIPHER = struct_evp_cipher_st;
pub const struct_evp_cipher_ctx_st = opaque {};
pub const EVP_CIPHER_CTX = struct_evp_cipher_ctx_st;
pub const struct_evp_md_st = opaque {};
pub const EVP_MD = struct_evp_md_st;
pub const struct_evp_md_ctx_st = opaque {};
pub const EVP_MD_CTX = struct_evp_md_ctx_st;
pub const struct_evp_pkey_st = opaque {};
pub const EVP_PKEY = struct_evp_pkey_st;
pub const struct_evp_pkey_ctx_st = opaque {};
pub const EVP_PKEY_CTX = struct_evp_pkey_ctx_st;
pub const struct_hmac_ctx_st = opaque {};
pub const HMAC_CTX = struct_hmac_ctx_st;
pub const struct_rsa_st = opaque {};
pub const RSA = struct_rsa_st;
pub const struct_x509_st = opaque {};
pub const X509 = struct_x509_st;
pub const struct_X509_crl_st = opaque {};
pub const X509_CRL = struct_X509_crl_st;
pub const struct_X509_name_st = opaque {};
pub const X509_NAME = struct_X509_name_st;
pub const struct_X509_req_st = opaque {};
pub const X509_REQ = struct_X509_req_st;
pub const struct_stack_st_CONF_VALUE = opaque {};
pub const struct_X509V3_CONF_METHOD_st = extern struct {
    get_string: ?*const fn (?*anyopaque, [*c]const u8, [*c]const u8) callconv(.c) [*c]u8 = @import("std").mem.zeroes(?*const fn (?*anyopaque, [*c]const u8, [*c]const u8) callconv(.c) [*c]u8),
    get_section: ?*const fn (?*anyopaque, [*c]const u8) callconv(.c) ?*struct_stack_st_CONF_VALUE = @import("std").mem.zeroes(?*const fn (?*anyopaque, [*c]const u8) callconv(.c) ?*struct_stack_st_CONF_VALUE),
    free_string: ?*const fn (?*anyopaque, [*c]u8) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*anyopaque, [*c]u8) callconv(.c) void),
    free_section: ?*const fn (?*anyopaque, ?*struct_stack_st_CONF_VALUE) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*anyopaque, ?*struct_stack_st_CONF_VALUE) callconv(.c) void),
};
pub const X509V3_CONF_METHOD = struct_X509V3_CONF_METHOD_st;
pub const struct_v3_ext_ctx = extern struct {
    flags: c_int = @import("std").mem.zeroes(c_int),
    issuer_cert: ?*X509 = @import("std").mem.zeroes(?*X509),
    subject_cert: ?*X509 = @import("std").mem.zeroes(?*X509),
    subject_req: ?*X509_REQ = @import("std").mem.zeroes(?*X509_REQ),
    crl: ?*X509_CRL = @import("std").mem.zeroes(?*X509_CRL),
    db_meth: [*c]X509V3_CONF_METHOD = @import("std").mem.zeroes([*c]X509V3_CONF_METHOD),
    db: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    issuer_pkey: ?*EVP_PKEY = @import("std").mem.zeroes(?*EVP_PKEY),
};
pub const X509V3_CTX = struct_v3_ext_ctx;
pub const union_lh_CONF_VALUE_dummy_85 = extern union {
    d1: ?*anyopaque,
    d2: c_ulong,
    d3: c_int,
};
pub const struct_lhash_st_CONF_VALUE = extern struct {
    dummy: union_lh_CONF_VALUE_dummy_85 = @import("std").mem.zeroes(union_lh_CONF_VALUE_dummy_85),
};
pub const struct_ossl_init_settings_st = opaque {};
pub const OPENSSL_INIT_SETTINGS = struct_ossl_init_settings_st;
pub const struct_engine_st = opaque {};
pub const ENGINE = struct_engine_st;
pub const struct_stack_st_GENERAL_NAME = opaque {};
pub const GENERAL_NAMES = struct_stack_st_GENERAL_NAME;
pub const pem_password_cb = fn ([*c]u8, c_int, c_int, ?*anyopaque) callconv(.c) c_int;
pub const CRYPTO_malloc_fn = ?*const fn (usize, [*c]const u8, c_int) callconv(.c) ?*anyopaque;
pub const CRYPTO_realloc_fn = ?*const fn (?*anyopaque, usize, [*c]const u8, c_int) callconv(.c) ?*anyopaque;
pub const CRYPTO_free_fn = ?*const fn (?*anyopaque, [*c]const u8, c_int) callconv(.c) void;
pub extern fn CRYPTO_set_mem_functions(malloc_fn: CRYPTO_malloc_fn, realloc_fn: CRYPTO_realloc_fn, free_fn: CRYPTO_free_fn) c_int;
pub extern fn OPENSSL_init_crypto(opts: u64, settings: ?*const OPENSSL_INIT_SETTINGS) c_int;
pub const struct_bio_method_st = opaque {};
pub const BIO_METHOD = struct_bio_method_st;
pub extern fn BIO_new(@"type": ?*const BIO_METHOD) ?*BIO;
pub extern fn BIO_free(a: ?*BIO) c_int;
pub extern fn BIO_ctrl(bp: ?*BIO, cmd: c_int, larg: c_long, parg: ?*anyopaque) c_long;
pub extern fn BIO_s_mem() ?*const BIO_METHOD;
pub extern fn BIO_new_mem_buf(buf: ?*const anyopaque, len: c_int) ?*BIO;
pub extern fn BN_num_bits(a: ?*const BIGNUM) c_int;
pub extern fn BN_bn2bin(a: ?*const BIGNUM, to: [*c]u8) c_int;
pub extern fn ASN1_STRING_length(x: [*c]const ASN1_STRING) c_int;
pub extern fn ASN1_STRING_get0_data(x: [*c]const ASN1_STRING) [*c]const u8;
pub extern fn ASN1_TIME_diff(pday: [*c]c_int, psec: [*c]c_int, from: [*c]const ASN1_TIME, to: [*c]const ASN1_TIME) c_int;
pub extern fn EVP_MD_CTX_new() ?*EVP_MD_CTX;
pub extern fn EVP_MD_CTX_reset(ctx: ?*EVP_MD_CTX) c_int;
pub extern fn EVP_MD_CTX_free(ctx: ?*EVP_MD_CTX) void;
pub extern fn EVP_EncryptInit_ex(ctx: ?*EVP_CIPHER_CTX, cipher: ?*const EVP_CIPHER, impl: ?*ENGINE, key: [*c]const u8, iv: [*c]const u8) c_int;
pub extern fn EVP_EncryptUpdate(ctx: ?*EVP_CIPHER_CTX, out: [*c]u8, outl: [*c]c_int, in: [*c]const u8, inl: c_int) c_int;
pub extern fn EVP_EncryptFinal_ex(ctx: ?*EVP_CIPHER_CTX, out: [*c]u8, outl: [*c]c_int) c_int;
pub extern fn EVP_DecryptInit_ex(ctx: ?*EVP_CIPHER_CTX, cipher: ?*const EVP_CIPHER, impl: ?*ENGINE, key: [*c]const u8, iv: [*c]const u8) c_int;
pub extern fn EVP_DecryptUpdate(ctx: ?*EVP_CIPHER_CTX, out: [*c]u8, outl: [*c]c_int, in: [*c]const u8, inl: c_int) c_int;
pub extern fn EVP_DecryptFinal_ex(ctx: ?*EVP_CIPHER_CTX, outm: [*c]u8, outl: [*c]c_int) c_int;
pub extern fn EVP_DigestSignInit(ctx: ?*EVP_MD_CTX, pctx: [*c]?*EVP_PKEY_CTX, @"type": ?*const EVP_MD, e: ?*ENGINE, pkey: ?*EVP_PKEY) c_int;
pub extern fn EVP_DigestSignUpdate(ctx: ?*EVP_MD_CTX, data: ?*const anyopaque, dsize: usize) c_int;
pub extern fn EVP_DigestSignFinal(ctx: ?*EVP_MD_CTX, sigret: [*c]u8, siglen: [*c]usize) c_int;
pub extern fn EVP_DigestVerifyInit(ctx: ?*EVP_MD_CTX, pctx: [*c]?*EVP_PKEY_CTX, @"type": ?*const EVP_MD, e: ?*ENGINE, pkey: ?*EVP_PKEY) c_int;
pub extern fn EVP_DigestVerifyUpdate(ctx: ?*EVP_MD_CTX, data: ?*const anyopaque, dsize: usize) c_int;
pub extern fn EVP_DigestVerifyFinal(ctx: ?*EVP_MD_CTX, sig: [*c]const u8, siglen: usize) c_int;
pub extern fn EVP_EncodeBlock(t: [*c]u8, f: [*c]const u8, n: c_int) c_int;
pub extern fn EVP_DecodeBlock(t: [*c]u8, f: [*c]const u8, n: c_int) c_int;
pub extern fn EVP_CIPHER_CTX_new() ?*EVP_CIPHER_CTX;
pub extern fn EVP_CIPHER_CTX_reset(c: ?*EVP_CIPHER_CTX) c_int;
pub extern fn EVP_CIPHER_CTX_free(c: ?*EVP_CIPHER_CTX) void;
pub extern fn EVP_CIPHER_CTX_set_padding(c: ?*EVP_CIPHER_CTX, pad: c_int) c_int;
pub extern fn EVP_CIPHER_CTX_ctrl(ctx: ?*EVP_CIPHER_CTX, @"type": c_int, arg: c_int, ptr: ?*anyopaque) c_int;
pub extern fn EVP_sha256() ?*const EVP_MD;
pub extern fn EVP_aes_256_gcm() ?*const EVP_CIPHER;
pub extern fn EVP_PKEY_get0_RSA(pkey: ?*const EVP_PKEY) ?*const struct_rsa_st;
pub extern fn EVP_PKEY_free(pkey: ?*EVP_PKEY) void;
pub extern fn EVP_PKEY_CTX_new(pkey: ?*EVP_PKEY, e: ?*ENGINE) ?*EVP_PKEY_CTX;
pub extern fn EVP_PKEY_CTX_free(ctx: ?*EVP_PKEY_CTX) void;
pub extern fn EVP_PKEY_encrypt_init(ctx: ?*EVP_PKEY_CTX) c_int;
pub extern fn EVP_PKEY_encrypt(ctx: ?*EVP_PKEY_CTX, out: [*c]u8, outlen: [*c]usize, in: [*c]const u8, inlen: usize) c_int;
pub extern fn EVP_PKEY_decrypt_init(ctx: ?*EVP_PKEY_CTX) c_int;
pub extern fn EVP_PKEY_decrypt(ctx: ?*EVP_PKEY_CTX, out: [*c]u8, outlen: [*c]usize, in: [*c]const u8, inlen: usize) c_int;
pub extern fn EVP_PKEY_Q_keygen(libctx: ?*anyopaque, propq: ?*anyopaque, @"type": [*c]const u8, ...) ?*EVP_PKEY;
pub extern fn EVP_PKEY_public_check(ctx: ?*EVP_PKEY_CTX) c_int;
pub extern fn EVP_PKEY_private_check(ctx: ?*EVP_PKEY_CTX) c_int;
pub extern fn EVP_PKEY_CTX_set_rsa_padding(ctx: ?*EVP_PKEY_CTX, pad_mode: c_int) c_int;
pub extern fn RSA_get0_key(r: ?*const RSA, n: [*c]?*const BIGNUM, e: [*c]?*const BIGNUM, d: [*c]?*const BIGNUM) void;
pub const struct_X509_extension_st = opaque {};
pub const X509_EXTENSION = struct_X509_extension_st;
pub const struct_stack_st_X509_EXTENSION = opaque {};
pub const sk_X509_EXTENSION_freefunc = ?*const fn (?*X509_EXTENSION) callconv(.c) void;
pub fn ossl_check_X509_EXTENSION_sk_type(arg_sk: ?*struct_stack_st_X509_EXTENSION) callconv(.c) ?*OPENSSL_STACK {
    var sk = arg_sk;
    _ = &sk;
    return @as(?*OPENSSL_STACK, @ptrCast(sk));
}
pub fn ossl_check_X509_EXTENSION_freefunc_type(arg_fr: sk_X509_EXTENSION_freefunc) callconv(.c) OPENSSL_sk_freefunc {
    var fr = arg_fr;
    _ = &fr;
    return @as(OPENSSL_sk_freefunc, @ptrCast(@alignCast(fr)));
}
pub const X509_EXTENSIONS = struct_stack_st_X509_EXTENSION;
pub extern fn X509_REQ_sign(x: ?*X509_REQ, pkey: ?*EVP_PKEY, md: ?*const EVP_MD) c_int;
pub extern fn X509_REQ_new() ?*X509_REQ;
pub extern fn X509_REQ_free(a: ?*X509_REQ) void;
pub extern fn d2i_X509_REQ(a: [*c]?*X509_REQ, in: [*c][*c]const u8, len: c_long) ?*X509_REQ;
pub extern fn i2d_X509_REQ(a: ?*const X509_REQ, out: [*c][*c]u8) c_int;
pub extern fn X509_EXTENSION_free(a: ?*X509_EXTENSION) void;
pub extern fn X509_free(a: ?*X509) void;
pub extern fn X509_getm_notAfter(x: ?*const X509) [*c]ASN1_TIME;
pub extern fn X509_REQ_set_version(x: ?*X509_REQ, version: c_long) c_int;
pub extern fn X509_REQ_get_subject_name(req: ?*const X509_REQ) ?*X509_NAME;
pub extern fn X509_REQ_set_pubkey(x: ?*X509_REQ, pkey: ?*EVP_PKEY) c_int;
pub extern fn X509_REQ_get_extensions(req: ?*X509_REQ) ?*struct_stack_st_X509_EXTENSION;
pub extern fn X509_REQ_add_extensions(req: ?*X509_REQ, ext: ?*const struct_stack_st_X509_EXTENSION) c_int;
pub extern fn X509_NAME_get_text_by_NID(name: ?*const X509_NAME, nid: c_int, buf: [*c]u8, len: c_int) c_int;
pub extern fn X509_NAME_add_entry_by_txt(name: ?*X509_NAME, field: [*c]const u8, @"type": c_int, bytes: [*c]const u8, len: c_int, loc: c_int, set: c_int) c_int;
pub extern fn X509v3_add_ext(x: [*c]?*struct_stack_st_X509_EXTENSION, ex: ?*X509_EXTENSION, loc: c_int) ?*struct_stack_st_X509_EXTENSION;
pub extern fn PEM_read_bio_X509(out: ?*BIO, x: [*c]?*X509, cb: ?*const pem_password_cb, u: ?*anyopaque) ?*X509;
pub extern fn PEM_read_bio_PrivateKey(out: ?*BIO, x: [*c]?*EVP_PKEY, cb: ?*const pem_password_cb, u: ?*anyopaque) ?*EVP_PKEY;
pub extern fn PEM_write_bio_PrivateKey(out: ?*BIO, x: ?*const EVP_PKEY, enc: ?*const EVP_CIPHER, kstr: [*c]const u8, klen: c_int, cb: ?*const pem_password_cb, u: ?*anyopaque) c_int;
pub extern fn PEM_read_bio_PUBKEY(out: ?*BIO, x: [*c]?*EVP_PKEY, cb: ?*const pem_password_cb, u: ?*anyopaque) ?*EVP_PKEY;
pub extern fn HMAC_CTX_new() ?*HMAC_CTX;
pub extern fn HMAC_CTX_free(ctx: ?*HMAC_CTX) void;
pub extern fn HMAC_Init_ex(ctx: ?*HMAC_CTX, key: ?*const anyopaque, len: c_int, md: ?*const EVP_MD, impl: ?*ENGINE) c_int;
pub extern fn HMAC_Update(ctx: ?*HMAC_CTX, data: [*c]const u8, len: usize) c_int;
pub extern fn HMAC_Final(ctx: ?*HMAC_CTX, md: [*c]u8, len: [*c]c_uint) c_int;
pub extern fn ERR_get_error() c_ulong;
pub extern fn ERR_error_string_n(e: c_ulong, buf: [*c]u8, len: usize) void;
pub extern fn ERR_print_errors_cb(cb: ?*const fn ([*c]const u8, usize, ?*anyopaque) callconv(.c) c_int, u: ?*anyopaque) void;
pub extern fn RAND_bytes(buf: [*c]u8, num: c_int) c_int;
pub const struct_otherName_st = extern struct {
    type_id: ?*ASN1_OBJECT = @import("std").mem.zeroes(?*ASN1_OBJECT),
    value: [*c]ASN1_TYPE = @import("std").mem.zeroes([*c]ASN1_TYPE),
};
pub const OTHERNAME = struct_otherName_st;
pub const struct_EDIPartyName_st = extern struct {
    nameAssigner: [*c]ASN1_STRING = @import("std").mem.zeroes([*c]ASN1_STRING),
    partyName: [*c]ASN1_STRING = @import("std").mem.zeroes([*c]ASN1_STRING),
};
pub const EDIPARTYNAME = struct_EDIPartyName_st;
const union_unnamed_104 = extern union {
    ptr: [*c]u8,
    otherName: [*c]OTHERNAME,
    rfc822Name: [*c]ASN1_IA5STRING,
    dNSName: [*c]ASN1_IA5STRING,
    x400Address: [*c]ASN1_STRING,
    directoryName: ?*X509_NAME,
    ediPartyName: [*c]EDIPARTYNAME,
    uniformResourceIdentifier: [*c]ASN1_IA5STRING,
    iPAddress: [*c]ASN1_OCTET_STRING,
    registeredID: ?*ASN1_OBJECT,
    ip: [*c]ASN1_OCTET_STRING,
    dirn: ?*X509_NAME,
    ia5: [*c]ASN1_IA5STRING,
    rid: ?*ASN1_OBJECT,
    other: [*c]ASN1_TYPE,
};
pub const struct_GENERAL_NAME_st = extern struct {
    type: c_int = @import("std").mem.zeroes(c_int),
    d: union_unnamed_104 = @import("std").mem.zeroes(union_unnamed_104),
};
pub const GENERAL_NAME = struct_GENERAL_NAME_st;
pub fn ossl_check_const_GENERAL_NAME_sk_type(arg_sk: ?*const struct_stack_st_GENERAL_NAME) callconv(.c) ?*const OPENSSL_STACK {
    var sk = arg_sk;
    _ = &sk;
    return @as(?*const OPENSSL_STACK, @ptrCast(sk));
}
pub extern fn GENERAL_NAMES_free(a: ?*GENERAL_NAMES) void;
pub extern fn GENERAL_NAME_get0_value(a: [*c]const GENERAL_NAME, ptype: [*c]c_int) ?*anyopaque;
pub extern fn X509V3_EXT_conf_nid(conf: [*c]struct_lhash_st_CONF_VALUE, ctx: [*c]X509V3_CTX, ext_nid: c_int, value: [*c]const u8) ?*X509_EXTENSION;
pub extern fn X509V3_set_ctx(ctx: [*c]X509V3_CTX, issuer: ?*X509, subject: ?*X509, req: ?*X509_REQ, crl: ?*X509_CRL, flags: c_int) void;
pub extern fn X509V3_get_d2i(x: ?*const struct_stack_st_X509_EXTENSION, nid: c_int, crit: [*c]c_int, idx: [*c]c_int) ?*anyopaque;
const ngx_ssl_ticket_key_flags_t = packed struct(u32) {
    size: u8,
    shared: bool,
    padding: u23,
};
pub const ngx_ssl_ticket_key_t = extern struct {
    name: [16]u_char = @import("std").mem.zeroes([16]u_char),
    hmac_key: [32]u_char = @import("std").mem.zeroes([32]u_char),
    aes_key: [32]u_char = @import("std").mem.zeroes([32]u_char),
    expire: time_t = @import("std").mem.zeroes(time_t),
    flags: ngx_ssl_ticket_key_flags_t = @import("std").mem.zeroes(ngx_ssl_ticket_key_flags_t),
};
pub extern fn ngx_ssl_create(ssl: [*c]ngx_ssl_t, protocols: ngx_uint_t, data: ?*anyopaque) ngx_int_t;
pub extern fn ngx_ssl_client_session_cache(cf: [*c]ngx_conf_t, ssl: [*c]ngx_ssl_t, enable: ngx_uint_t) ngx_int_t;
pub extern fn ngx_ssl_cleanup_ctx(data: ?*anyopaque) void;
pub const ngx_conf_file_t = extern struct {
    file: ngx_file_t = @import("std").mem.zeroes(ngx_file_t),
    buffer: [*c]ngx_buf_t = @import("std").mem.zeroes([*c]ngx_buf_t),
    dump: [*c]ngx_buf_t = @import("std").mem.zeroes([*c]ngx_buf_t),
    line: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
pub extern fn ngx_conf_full_name(cycle: [*c]ngx_cycle_t, name: [*c]ngx_str_t, conf_prefix: ngx_uint_t) ngx_int_t;
pub extern fn ngx_conf_set_flag_slot(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, conf: ?*anyopaque) [*c]u8;
pub extern fn ngx_conf_set_str_slot(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, conf: ?*anyopaque) [*c]u8;
pub extern fn ngx_conf_set_str_array_slot(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, conf: ?*anyopaque) [*c]u8;
pub extern fn ngx_conf_set_keyval_slot(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, conf: ?*anyopaque) [*c]u8;
pub extern fn ngx_conf_set_num_slot(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, conf: ?*anyopaque) [*c]u8;
pub extern fn ngx_conf_set_size_slot(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, conf: ?*anyopaque) [*c]u8;
pub extern fn ngx_conf_set_off_slot(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, conf: ?*anyopaque) [*c]u8;
pub extern fn ngx_conf_set_msec_slot(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, conf: ?*anyopaque) [*c]u8;
pub extern fn ngx_conf_set_sec_slot(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, conf: ?*anyopaque) [*c]u8;
pub extern fn ngx_conf_set_bufs_slot(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, conf: ?*anyopaque) [*c]u8;
pub extern fn ngx_conf_set_enum_slot(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, conf: ?*anyopaque) [*c]u8;
pub extern fn ngx_conf_set_bitmask_slot(cf: [*c]ngx_conf_t, cmd: [*c]ngx_command_t, conf: ?*anyopaque) [*c]u8;
const ngx_open_file_info_flags_t = packed struct(u32) {
    disable_symlinks: u2,
    test_dir: bool,
    test_only: bool,
    log: bool,
    errors: bool,
    events: bool,
    is_dir: bool,
    is_file: bool,
    is_link: bool,
    is_exec: bool,
    is_directio: bool,
    padding: u20,
};
pub const ngx_open_file_info_t = extern struct {
    fd: ngx_fd_t = @import("std").mem.zeroes(ngx_fd_t),
    uniq: ngx_file_uniq_t = @import("std").mem.zeroes(ngx_file_uniq_t),
    mtime: time_t = @import("std").mem.zeroes(time_t),
    size: off_t = @import("std").mem.zeroes(off_t),
    fs_size: off_t = @import("std").mem.zeroes(off_t),
    directio: off_t = @import("std").mem.zeroes(off_t),
    read_ahead: usize = @import("std").mem.zeroes(usize),
    err: ngx_err_t = @import("std").mem.zeroes(ngx_err_t),
    failed: [*c]u8 = @import("std").mem.zeroes([*c]u8),
    valid: time_t = @import("std").mem.zeroes(time_t),
    min_uses: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    disable_symlinks_from: usize = @import("std").mem.zeroes(usize),
    flags: ngx_open_file_info_flags_t = @import("std").mem.zeroes(ngx_open_file_info_flags_t),
};
const struct_ngx_cached_open_file_flags_s = packed struct(u64) {
    disable_symlinks: u2,
    count: u24,
    close: bool,
    use_event: bool,
    is_dir: bool,
    is_file: bool,
    is_link: bool,
    is_exec: bool,
    is_directio: bool,
    padding: u31,
};
pub const struct_ngx_cached_open_file_s = extern struct {
    node: ngx_rbtree_node_t = @import("std").mem.zeroes(ngx_rbtree_node_t),
    queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    name: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    created: time_t = @import("std").mem.zeroes(time_t),
    accessed: time_t = @import("std").mem.zeroes(time_t),
    fd: ngx_fd_t = @import("std").mem.zeroes(ngx_fd_t),
    uniq: ngx_file_uniq_t = @import("std").mem.zeroes(ngx_file_uniq_t),
    mtime: time_t = @import("std").mem.zeroes(time_t),
    size: off_t = @import("std").mem.zeroes(off_t),
    err: ngx_err_t = @import("std").mem.zeroes(ngx_err_t),
    uses: u32 = @import("std").mem.zeroes(u32),
    disable_symlinks_from: usize = @import("std").mem.zeroes(usize),
    flags: struct_ngx_cached_open_file_flags_s = @import("std").mem.zeroes(struct_ngx_cached_open_file_flags_s),
    event: [*c]ngx_event_t = @import("std").mem.zeroes([*c]ngx_event_t),
};
pub const ngx_cached_open_file_t = struct_ngx_cached_open_file_s;
pub const ngx_open_file_cache_t = extern struct {
    rbtree: ngx_rbtree_t = @import("std").mem.zeroes(ngx_rbtree_t),
    sentinel: ngx_rbtree_node_t = @import("std").mem.zeroes(ngx_rbtree_node_t),
    expire_queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    current: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    max: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    inactive: time_t = @import("std").mem.zeroes(time_t),
};
pub extern fn ngx_get_connection(s: ngx_socket_t, log: [*c]ngx_log_t) [*c]ngx_connection_t;
const ngx_syslog_peer_flags_t = packed struct(u32) {
    busy: bool,
    nohostname: bool,
    padding: u30,
};
pub const ngx_syslog_peer_t = extern struct {
    facility: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    severity: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    tag: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    hostname: [*c]ngx_str_t = @import("std").mem.zeroes([*c]ngx_str_t),
    server: ngx_addr_t = @import("std").mem.zeroes(ngx_addr_t),
    conn: ngx_connection_t = @import("std").mem.zeroes(ngx_connection_t),
    log: ngx_log_t = @import("std").mem.zeroes(ngx_log_t),
    logp: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
    flags: ngx_syslog_peer_flags_t = @import("std").mem.zeroes(ngx_syslog_peer_flags_t),
};
pub const ngx_http_request_t = struct_ngx_http_request_s;
pub const ngx_http_event_handler_pt = ?*const fn ([*c]ngx_http_request_t) callconv(.c) void;
pub const struct_ngx_http_file_cache_s = extern struct {
    sh: [*c]ngx_http_file_cache_sh_t = @import("std").mem.zeroes([*c]ngx_http_file_cache_sh_t),
    shpool: [*c]ngx_slab_pool_t = @import("std").mem.zeroes([*c]ngx_slab_pool_t),
    path: [*c]ngx_path_t = @import("std").mem.zeroes([*c]ngx_path_t),
    min_free: off_t = @import("std").mem.zeroes(off_t),
    max_size: off_t = @import("std").mem.zeroes(off_t),
    bsize: usize = @import("std").mem.zeroes(usize),
    inactive: time_t = @import("std").mem.zeroes(time_t),
    fail_time: time_t = @import("std").mem.zeroes(time_t),
    files: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    loader_files: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    last: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    loader_sleep: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    loader_threshold: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    manager_files: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    manager_sleep: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    manager_threshold: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    shm_zone: [*c]ngx_shm_zone_t = @import("std").mem.zeroes([*c]ngx_shm_zone_t),
    use_temp_path: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
pub const ngx_http_file_cache_t = struct_ngx_http_file_cache_s;
const struct_ngx_http_cache_flags_s = packed struct(u32) {
    lock: bool,
    waiting: bool,
    updated: bool,
    updating: bool,
    exists: bool,
    temp_file: bool,
    purged: bool,
    reading: bool,
    secondary: bool,
    update_variant: bool,
    background: bool,
    stale_updating: bool,
    stale_error: bool,
    padding: u19,
};
pub const struct_ngx_http_cache_s = extern struct {
    file: ngx_file_t = @import("std").mem.zeroes(ngx_file_t),
    keys: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
    crc32: u32 = @import("std").mem.zeroes(u32),
    key: [16]u_char = @import("std").mem.zeroes([16]u_char),
    main: [16]u_char = @import("std").mem.zeroes([16]u_char),
    uniq: ngx_file_uniq_t = @import("std").mem.zeroes(ngx_file_uniq_t),
    valid_sec: time_t = @import("std").mem.zeroes(time_t),
    updating_sec: time_t = @import("std").mem.zeroes(time_t),
    error_sec: time_t = @import("std").mem.zeroes(time_t),
    last_modified: time_t = @import("std").mem.zeroes(time_t),
    date: time_t = @import("std").mem.zeroes(time_t),
    etag: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    vary: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    variant: [16]u_char = @import("std").mem.zeroes([16]u_char),
    buffer_size: usize = @import("std").mem.zeroes(usize),
    header_start: usize = @import("std").mem.zeroes(usize),
    body_start: usize = @import("std").mem.zeroes(usize),
    length: off_t = @import("std").mem.zeroes(off_t),
    fs_size: off_t = @import("std").mem.zeroes(off_t),
    min_uses: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    @"error": ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    valid_msec: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    vary_tag: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    buf: [*c]ngx_buf_t = @import("std").mem.zeroes([*c]ngx_buf_t),
    file_cache: [*c]ngx_http_file_cache_t = @import("std").mem.zeroes([*c]ngx_http_file_cache_t),
    node: [*c]ngx_http_file_cache_node_t = @import("std").mem.zeroes([*c]ngx_http_file_cache_node_t),
    thread_task: [*c]ngx_thread_task_t = @import("std").mem.zeroes([*c]ngx_thread_task_t),
    lock_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    lock_age: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    lock_time: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    wait_time: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    wait_event: ngx_event_t = @import("std").mem.zeroes(ngx_event_t),
    flags: struct_ngx_http_cache_flags_s = @import("std").mem.zeroes(struct_ngx_http_cache_flags_s),
};
pub const ngx_http_cache_t = struct_ngx_http_cache_s;
pub const ngx_http_upstream_handler_pt = ?*const fn ([*c]ngx_http_request_t, [*c]ngx_http_upstream_t) callconv(.c) void;
pub const ngx_event_get_peer_pt = ?*const fn ([*c]ngx_peer_connection_t, ?*anyopaque) callconv(.c) ngx_int_t;
pub const ngx_event_free_peer_pt = ?*const fn ([*c]ngx_peer_connection_t, ?*anyopaque, ngx_uint_t) callconv(.c) void;
pub const ngx_event_notify_peer_pt = ?*const fn ([*c]ngx_peer_connection_t, ?*anyopaque, ngx_uint_t) callconv(.c) void;
pub const ngx_event_set_peer_session_pt = ?*const fn ([*c]ngx_peer_connection_t, ?*anyopaque) callconv(.c) ngx_int_t;
pub const ngx_event_save_peer_session_pt = ?*const fn ([*c]ngx_peer_connection_t, ?*anyopaque) callconv(.c) void;
const struct_ngx_peer_connection_flags_s = packed struct(u32) {
    cached: bool,
    transparent: bool,
    so_keepalive: bool,
    down: bool,
    log_error: u2,
    padding: u26,
};
pub const struct_ngx_peer_connection_s = extern struct {
    connection: [*c]ngx_connection_t = @import("std").mem.zeroes([*c]ngx_connection_t),
    sockaddr: [*c]struct_sockaddr = @import("std").mem.zeroes([*c]struct_sockaddr),
    socklen: socklen_t = @import("std").mem.zeroes(socklen_t),
    name: [*c]ngx_str_t = @import("std").mem.zeroes([*c]ngx_str_t),
    tries: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    start_time: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    get: ngx_event_get_peer_pt = @import("std").mem.zeroes(ngx_event_get_peer_pt),
    free: ngx_event_free_peer_pt = @import("std").mem.zeroes(ngx_event_free_peer_pt),
    notify: ngx_event_notify_peer_pt = @import("std").mem.zeroes(ngx_event_notify_peer_pt),
    data: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    set_session: ngx_event_set_peer_session_pt = @import("std").mem.zeroes(ngx_event_set_peer_session_pt),
    save_session: ngx_event_save_peer_session_pt = @import("std").mem.zeroes(ngx_event_save_peer_session_pt),
    local: [*c]ngx_addr_t = @import("std").mem.zeroes([*c]ngx_addr_t),
    type: c_int = @import("std").mem.zeroes(c_int),
    rcvbuf: c_int = @import("std").mem.zeroes(c_int),
    log: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
    hint: [*c]ngx_str_t = @import("std").mem.zeroes([*c]ngx_str_t),
    sid: [*c]ngx_str_t = @import("std").mem.zeroes([*c]ngx_str_t),
    flags: struct_ngx_peer_connection_flags_s = @import("std").mem.zeroes(struct_ngx_peer_connection_flags_s),
    spare: [1]u64 = @import("std").mem.zeroes([1]u64),
};
pub const ngx_peer_connection_t = struct_ngx_peer_connection_s;
pub const ngx_event_pipe_input_filter_pt = ?*const fn ([*c]ngx_event_pipe_t, [*c]ngx_buf_t) callconv(.c) ngx_int_t;
pub const ngx_event_pipe_output_filter_pt = ?*const fn (?*anyopaque, [*c]ngx_chain_t) callconv(.c) ngx_int_t;
const struct_ngx_event_pipe_flags_s = packed struct(u32) {
    read: bool,
    cacheable: bool,
    single_buf: bool,
    free_bufs: bool,
    upstream_done: bool,
    upstream_error: bool,
    upstream_eof: bool,
    upstream_blocked: bool,
    downstream_done: bool,
    downstream_error: bool,
    cyclic_temp_file: bool,
    aio: bool,
    padding: u20,
};
pub const struct_ngx_event_pipe_s = extern struct {
    upstream: [*c]ngx_connection_t = @import("std").mem.zeroes([*c]ngx_connection_t),
    downstream: [*c]ngx_connection_t = @import("std").mem.zeroes([*c]ngx_connection_t),
    free_raw_bufs: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    in: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    last_in: [*c][*c]ngx_chain_t = @import("std").mem.zeroes([*c][*c]ngx_chain_t),
    writing: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    out: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    free: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    busy: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    input_filter: ngx_event_pipe_input_filter_pt = @import("std").mem.zeroes(ngx_event_pipe_input_filter_pt),
    input_ctx: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    output_filter: ngx_event_pipe_output_filter_pt = @import("std").mem.zeroes(ngx_event_pipe_output_filter_pt),
    output_ctx: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    thread_handler: ?*const fn ([*c]ngx_thread_task_t, [*c]ngx_file_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_thread_task_t, [*c]ngx_file_t) callconv(.c) ngx_int_t),
    thread_ctx: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    thread_task: [*c]ngx_thread_task_t = @import("std").mem.zeroes([*c]ngx_thread_task_t),
    flags: struct_ngx_event_pipe_flags_s = @import("std").mem.zeroes(struct_ngx_event_pipe_flags_s),
    allocated: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
    bufs: ngx_bufs_t = @import("std").mem.zeroes(ngx_bufs_t),
    tag: ngx_buf_tag_t = @import("std").mem.zeroes(ngx_buf_tag_t),
    busy_size: isize = @import("std").mem.zeroes(isize),
    read_length: off_t = @import("std").mem.zeroes(off_t),
    length: off_t = @import("std").mem.zeroes(off_t),
    max_temp_file_size: off_t = @import("std").mem.zeroes(off_t),
    temp_file_write_size: isize = @import("std").mem.zeroes(isize),
    read_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    send_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    send_lowat: isize = @import("std").mem.zeroes(isize),
    pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    log: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
    preread_bufs: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    preread_size: usize = @import("std").mem.zeroes(usize),
    buf_to_file: [*c]ngx_buf_t = @import("std").mem.zeroes([*c]ngx_buf_t),
    limit_rate: usize = @import("std").mem.zeroes(usize),
    start_sec: time_t = @import("std").mem.zeroes(time_t),
    temp_file: [*c]ngx_temp_file_t = @import("std").mem.zeroes([*c]ngx_temp_file_t),
    num: c_int = @import("std").mem.zeroes(c_int),
};
pub const ngx_event_pipe_t = struct_ngx_event_pipe_s;
pub const struct_ngx_http_upstream_srv_conf_s = extern struct {
    peer: ngx_http_upstream_peer_t = @import("std").mem.zeroes(ngx_http_upstream_peer_t),
    srv_conf: [*c]?*anyopaque = @import("std").mem.zeroes([*c]?*anyopaque),
    servers: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    flags: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    host: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    file_name: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    line: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    port: in_port_t = @import("std").mem.zeroes(in_port_t),
    no_port: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    shm_zone: [*c]ngx_shm_zone_t = @import("std").mem.zeroes([*c]ngx_shm_zone_t),
    resolver: [*c]ngx_resolver_t = @import("std").mem.zeroes([*c]ngx_resolver_t),
    resolver_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
};
pub const ngx_http_upstream_srv_conf_t = struct_ngx_http_upstream_srv_conf_s;
pub const ngx_http_cleanup_pt = ?*const fn (?*anyopaque) callconv(.c) void;
const struct_ngx_http_upstream_flags_s = packed struct(u32) {
    store: bool,
    cacheable: bool,
    accel: bool,
    ssl: bool,
    cache_status: u3,
    buffering: bool,
    keepalive: bool,
    upgrade: bool,
    @"error": bool,
    request_sent: bool,
    request_body_sent: bool,
    request_body_blocked: bool,
    header_sent: bool,
    response_received: bool,
    padding: u16,
};
pub const struct_ngx_http_upstream_s = extern struct {
    read_event_handler: ngx_http_upstream_handler_pt = @import("std").mem.zeroes(ngx_http_upstream_handler_pt),
    write_event_handler: ngx_http_upstream_handler_pt = @import("std").mem.zeroes(ngx_http_upstream_handler_pt),
    peer: ngx_peer_connection_t = @import("std").mem.zeroes(ngx_peer_connection_t),
    pipe: [*c]ngx_event_pipe_t = @import("std").mem.zeroes([*c]ngx_event_pipe_t),
    request_bufs: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    output: ngx_output_chain_ctx_t = @import("std").mem.zeroes(ngx_output_chain_ctx_t),
    writer: ngx_chain_writer_ctx_t = @import("std").mem.zeroes(ngx_chain_writer_ctx_t),
    conf: [*c]ngx_http_upstream_conf_t = @import("std").mem.zeroes([*c]ngx_http_upstream_conf_t),
    upstream: [*c]ngx_http_upstream_srv_conf_t = @import("std").mem.zeroes([*c]ngx_http_upstream_srv_conf_t),
    caches: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    headers_in: ngx_http_upstream_headers_in_t = @import("std").mem.zeroes(ngx_http_upstream_headers_in_t),
    resolved: [*c]ngx_http_upstream_resolved_t = @import("std").mem.zeroes([*c]ngx_http_upstream_resolved_t),
    from_client: ngx_buf_t = @import("std").mem.zeroes(ngx_buf_t),
    buffer: ngx_buf_t = @import("std").mem.zeroes(ngx_buf_t),
    length: off_t = @import("std").mem.zeroes(off_t),
    early_hints_length: off_t = @import("std").mem.zeroes(off_t),
    out_bufs: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    busy_bufs: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    free_bufs: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    input_filter_init: ?*const fn (?*anyopaque) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn (?*anyopaque) callconv(.c) ngx_int_t),
    input_filter: ?*const fn (?*anyopaque, isize) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn (?*anyopaque, isize) callconv(.c) ngx_int_t),
    input_filter_ctx: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    create_key: ?*const fn ([*c]ngx_http_request_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_http_request_t) callconv(.c) ngx_int_t),
    create_request: ?*const fn ([*c]ngx_http_request_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_http_request_t) callconv(.c) ngx_int_t),
    reinit_request: ?*const fn ([*c]ngx_http_request_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_http_request_t) callconv(.c) ngx_int_t),
    process_header: ?*const fn ([*c]ngx_http_request_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_http_request_t) callconv(.c) ngx_int_t),
    abort_request: ?*const fn ([*c]ngx_http_request_t) callconv(.c) void = @import("std").mem.zeroes(?*const fn ([*c]ngx_http_request_t) callconv(.c) void),
    finalize_request: ?*const fn ([*c]ngx_http_request_t, ngx_int_t) callconv(.c) void = @import("std").mem.zeroes(?*const fn ([*c]ngx_http_request_t, ngx_int_t) callconv(.c) void),
    rewrite_redirect: ?*const fn ([*c]ngx_http_request_t, [*c]ngx_table_elt_t, usize) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_http_request_t, [*c]ngx_table_elt_t, usize) callconv(.c) ngx_int_t),
    rewrite_cookie: ?*const fn ([*c]ngx_http_request_t, [*c]ngx_table_elt_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_http_request_t, [*c]ngx_table_elt_t) callconv(.c) ngx_int_t),
    start_time: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    state: [*c]ngx_http_upstream_state_t = @import("std").mem.zeroes([*c]ngx_http_upstream_state_t),
    method: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    schema: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    uri: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    ssl_name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    ssl_alpn_protocol: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    cleanup: [*c]ngx_http_cleanup_pt = @import("std").mem.zeroes([*c]ngx_http_cleanup_pt),
    flags: struct_ngx_http_upstream_flags_s = @import("std").mem.zeroes(struct_ngx_http_upstream_flags_s),
};
pub const ngx_http_upstream_t = struct_ngx_http_upstream_s;
pub const struct_ngx_http_postponed_request_s = extern struct {
    request: [*c]ngx_http_request_t = @import("std").mem.zeroes([*c]ngx_http_request_t),
    out: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    next: [*c]ngx_http_postponed_request_t = @import("std").mem.zeroes([*c]ngx_http_postponed_request_t),
};
pub const ngx_http_postponed_request_t = struct_ngx_http_postponed_request_s;
pub const struct_ngx_http_posted_request_s = extern struct {
    request: [*c]ngx_http_request_t = @import("std").mem.zeroes([*c]ngx_http_request_t),
    next: [*c]ngx_http_posted_request_t = @import("std").mem.zeroes([*c]ngx_http_posted_request_t),
};
pub const ngx_http_posted_request_t = struct_ngx_http_posted_request_s;
pub const ngx_http_handler_pt = ?*const fn ([*c]ngx_http_request_t) callconv(.c) ngx_int_t;
pub const ngx_http_variable_value_t = ngx_variable_value_t;
pub const struct_ngx_http_v2_stream_s = opaque {};
pub const ngx_http_v2_stream_t = struct_ngx_http_v2_stream_s;
pub const struct_ngx_http_v3_parse_s = opaque {};
pub const ngx_http_v3_parse_t = struct_ngx_http_v3_parse_s;
pub const ngx_http_log_handler_pt = ?*const fn ([*c]ngx_http_request_t, [*c]ngx_http_request_t, [*c]u_char, usize) callconv(.c) [*c]u_char;
pub const struct_ngx_http_cleanup_s = extern struct {
    handler: ngx_http_cleanup_pt = @import("std").mem.zeroes(ngx_http_cleanup_pt),
    data: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    next: [*c]ngx_http_cleanup_t = @import("std").mem.zeroes([*c]ngx_http_cleanup_t),
};
pub const ngx_http_cleanup_t = struct_ngx_http_cleanup_s;

const struct_ngx_http_request_flag0_s = packed struct(u64) {
    count: u16,
    subrequests: u8,
    blocked: u8,
    aio: bool,
    http_state: u4,
    complex_uri: bool,
    quoted_uri: bool,
    plus_in_uri: bool,
    empty_path_in_uri: bool,
    invalid_header: bool,
    add_uri_to_alias: bool,
    valid_location: bool,
    valid_unparsed_uri: bool,
    uri_changed: bool,
    uri_changes: u4,
    request_body_in_single_buf: bool,
    request_body_in_file_only: bool,
    request_body_in_persistent_file: bool,
    request_body_in_clean_file: bool,
    request_body_file_group_access: bool,
    request_body_file_log_level: u3,
    request_body_no_buffering: bool,
    subrequest_in_memory: bool,
    waited: bool,
    cached: bool,
    gzip_tested: bool,
    gzip_ok: bool,
};
const struct_ngx_http_request_flag1_s = packed struct(u64) {
    gzip_vary: bool,
    realloc_captures: bool,
    proxy: bool,
    bypass_cache: bool,
    no_cache: bool,
    limit_conn_status: u2,
    limit_req_status: u3,
    limit_rate_set: bool,
    limit_rate_after_set: bool,
    pipeline: bool,
    chunked: bool,
    header_only: bool,
    expect_trailers: bool,
    keepalive: bool,
    lingering_close: bool,
    discard_body: bool,
    reading_body: bool,
    internal: bool,
    error_page: bool,
    filter_finalize: bool,
    post_action: bool,
    request_complete: bool,
    request_output: bool,
    header_sent: bool,
    response_sent: bool,
    expect_tested: bool,
    root_tested: bool,
    done: bool,
    logged: bool,
    terminated: bool,
    buffered: u4,
    main_filter_need_in_memory: bool,
    filter_need_in_memory: bool,
    filter_need_temporary: bool,
    preserve_body: bool,
    allow_ranges: bool,
    subrequest_ranges: bool,
    single_range: bool,
    disable_not_modified: bool,
    stat_reading: bool,
    stat_writing: bool,
    stat_processing: bool,
    background: bool,
    health_check: bool,
    padding: u14,
};
const struct_ngx_http_request_flag2_s = packed struct(u32) {
    http_minor: u16,
    http_major: u16,
};
pub const struct_ngx_http_request_s = extern struct {
    signature: u32 = @import("std").mem.zeroes(u32),
    connection: [*c]ngx_connection_t = @import("std").mem.zeroes([*c]ngx_connection_t),
    ctx: [*c]?*anyopaque = @import("std").mem.zeroes([*c]?*anyopaque),
    main_conf: [*c]?*anyopaque = @import("std").mem.zeroes([*c]?*anyopaque),
    srv_conf: [*c]?*anyopaque = @import("std").mem.zeroes([*c]?*anyopaque),
    loc_conf: [*c]?*anyopaque = @import("std").mem.zeroes([*c]?*anyopaque),
    read_event_handler: ngx_http_event_handler_pt = @import("std").mem.zeroes(ngx_http_event_handler_pt),
    write_event_handler: ngx_http_event_handler_pt = @import("std").mem.zeroes(ngx_http_event_handler_pt),
    cache: [*c]ngx_http_cache_t = @import("std").mem.zeroes([*c]ngx_http_cache_t),
    upstream: [*c]ngx_http_upstream_t = @import("std").mem.zeroes([*c]ngx_http_upstream_t),
    upstream_states: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    pool: [*c]ngx_pool_t = @import("std").mem.zeroes([*c]ngx_pool_t),
    header_in: [*c]ngx_buf_t = @import("std").mem.zeroes([*c]ngx_buf_t),
    headers_in: ngx_http_headers_in_t = @import("std").mem.zeroes(ngx_http_headers_in_t),
    headers_out: ngx_http_headers_out_t = @import("std").mem.zeroes(ngx_http_headers_out_t),
    request_body: [*c]ngx_http_request_body_t = @import("std").mem.zeroes([*c]ngx_http_request_body_t),
    lingering_time: time_t = @import("std").mem.zeroes(time_t),
    start_sec: time_t = @import("std").mem.zeroes(time_t),
    start_msec: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    method: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    http_version: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    request_line: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    uri: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    args: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    exten: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    unparsed_uri: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    method_name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    http_protocol: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    schema: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    out: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    main: [*c]ngx_http_request_t = @import("std").mem.zeroes([*c]ngx_http_request_t),
    parent: [*c]ngx_http_request_t = @import("std").mem.zeroes([*c]ngx_http_request_t),
    postponed: [*c]ngx_http_postponed_request_t = @import("std").mem.zeroes([*c]ngx_http_postponed_request_t),
    post_subrequest: [*c]ngx_http_post_subrequest_t = @import("std").mem.zeroes([*c]ngx_http_post_subrequest_t),
    posted_requests: [*c]ngx_http_posted_request_t = @import("std").mem.zeroes([*c]ngx_http_posted_request_t),
    phase_handler: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
    content_handler: ?*const fn ([*c]ngx_http_request_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(ngx_http_handler_pt),
    access_code: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    variables: [*c]ngx_http_variable_value_t = @import("std").mem.zeroes([*c]ngx_http_variable_value_t),
    ncaptures: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    captures: [*c]c_int = @import("std").mem.zeroes([*c]c_int),
    captures_data: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    limit_rate: usize = @import("std").mem.zeroes(usize),
    limit_rate_after: usize = @import("std").mem.zeroes(usize),
    header_size: usize = @import("std").mem.zeroes(usize),
    request_length: off_t = @import("std").mem.zeroes(off_t),
    err_status: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    http_connection: [*c]ngx_http_connection_t = @import("std").mem.zeroes([*c]ngx_http_connection_t),
    stream: ?*ngx_http_v2_stream_t = @import("std").mem.zeroes(?*ngx_http_v2_stream_t),
    v3_parse: ?*ngx_http_v3_parse_t = @import("std").mem.zeroes(?*ngx_http_v3_parse_t),
    log_handler: ngx_http_log_handler_pt = @import("std").mem.zeroes(ngx_http_log_handler_pt),
    cleanup: [*c]ngx_http_cleanup_t = @import("std").mem.zeroes([*c]ngx_http_cleanup_t),
    port: in_port_t = @import("std").mem.zeroes(in_port_t),
    flags0: struct_ngx_http_request_flag0_s = @import("std").mem.zeroes(struct_ngx_http_request_flag0_s),
    flags1: struct_ngx_http_request_flag1_s = @import("std").mem.zeroes(struct_ngx_http_request_flag1_s),
    state: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    header_hash: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    lowcase_index: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    lowcase_header: [32]u_char = @import("std").mem.zeroes([32]u_char),
    header_name_start: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    header_name_end: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    header_start: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    header_end: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    uri_start: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    uri_end: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    uri_ext: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    args_start: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    request_start: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    request_end: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    method_end: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    schema_start: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    schema_end: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    host_start: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    host_end: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    flags2: struct_ngx_http_request_flag2_s = @import("std").mem.zeroes(struct_ngx_http_request_flag2_s),
};
pub const struct_ngx_http_log_ctx_s = extern struct {
    connection: [*c]ngx_connection_t = @import("std").mem.zeroes([*c]ngx_connection_t),
    request: [*c]ngx_http_request_t = @import("std").mem.zeroes([*c]ngx_http_request_t),
    current_request: [*c]ngx_http_request_t = @import("std").mem.zeroes([*c]ngx_http_request_t),
};
pub const ngx_http_log_ctx_t = struct_ngx_http_log_ctx_s;
pub const struct_ngx_http_chunked_s = extern struct {
    state: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    size: off_t = @import("std").mem.zeroes(off_t),
    length: off_t = @import("std").mem.zeroes(off_t),
};
pub const ngx_http_chunked_t = struct_ngx_http_chunked_s;
pub const ngx_http_header_handler_pt = ?*const fn ([*c]ngx_http_request_t, [*c]ngx_table_elt_t, ngx_uint_t) callconv(.c) ngx_int_t;
pub const ngx_http_set_variable_pt = ?*const fn ([*c]ngx_http_request_t, [*c]ngx_http_variable_value_t, usize) callconv(.c) void;
pub const ngx_http_get_variable_pt = ?*const fn ([*c]ngx_http_request_t, [*c]ngx_http_variable_value_t, usize) callconv(.c) ngx_int_t;
pub const struct_ngx_http_variable_s = extern struct {
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    set_handler: ngx_http_set_variable_pt = @import("std").mem.zeroes(ngx_http_set_variable_pt),
    get_handler: ngx_http_get_variable_pt = @import("std").mem.zeroes(ngx_http_get_variable_pt),
    data: usize = @import("std").mem.zeroes(usize),
    flags: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    index: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
pub const ngx_http_variable_t = struct_ngx_http_variable_s;
pub extern fn ngx_http_add_variable(cf: [*c]ngx_conf_t, name: [*c]ngx_str_t, flags: ngx_uint_t) [*c]ngx_http_variable_t;
pub extern fn ngx_http_get_variable_index(cf: [*c]ngx_conf_t, name: [*c]ngx_str_t) ngx_int_t;
pub extern fn ngx_http_get_flushed_variable(r: [*c]ngx_http_request_t, index: ngx_uint_t) [*c]ngx_http_variable_value_t;
pub const ngx_http_regex_variable_t = extern struct {
    capture: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    index: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
};
pub const ngx_http_regex_t = extern struct {
    regex: ?*ngx_regex_t = @import("std").mem.zeroes(?*ngx_regex_t),
    ncaptures: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    variables: [*c]ngx_http_regex_variable_t = @import("std").mem.zeroes([*c]ngx_http_regex_variable_t),
    nvariables: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
};
pub const ngx_http_conf_ctx_t = extern struct {
    main_conf: [*c]?*anyopaque = @import("std").mem.zeroes([*c]?*anyopaque),
    srv_conf: [*c]?*anyopaque = @import("std").mem.zeroes([*c]?*anyopaque),
    loc_conf: [*c]?*anyopaque = @import("std").mem.zeroes([*c]?*anyopaque),
};
pub const ngx_http_module_t = extern struct {
    preconfiguration: ?*const fn ([*c]ngx_conf_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_conf_t) callconv(.c) ngx_int_t),
    postconfiguration: ?*const fn ([*c]ngx_conf_t) callconv(.c) ngx_int_t = @import("std").mem.zeroes(?*const fn ([*c]ngx_conf_t) callconv(.c) ngx_int_t),
    create_main_conf: ?*const fn ([*c]ngx_conf_t) callconv(.c) ?*anyopaque = @import("std").mem.zeroes(?*const fn ([*c]ngx_conf_t) callconv(.c) ?*anyopaque),
    init_main_conf: ?*const fn ([*c]ngx_conf_t, ?*anyopaque) callconv(.c) [*c]u8 = @import("std").mem.zeroes(?*const fn ([*c]ngx_conf_t, ?*anyopaque) callconv(.c) [*c]u8),
    create_srv_conf: ?*const fn ([*c]ngx_conf_t) callconv(.c) ?*anyopaque = @import("std").mem.zeroes(?*const fn ([*c]ngx_conf_t) callconv(.c) ?*anyopaque),
    merge_srv_conf: ?*const fn ([*c]ngx_conf_t, ?*anyopaque, ?*anyopaque) callconv(.c) [*c]u8 = @import("std").mem.zeroes(?*const fn ([*c]ngx_conf_t, ?*anyopaque, ?*anyopaque) callconv(.c) [*c]u8),
    create_loc_conf: ?*const fn ([*c]ngx_conf_t) callconv(.c) ?*anyopaque = @import("std").mem.zeroes(?*const fn ([*c]ngx_conf_t) callconv(.c) ?*anyopaque),
    merge_loc_conf: ?*const fn ([*c]ngx_conf_t, ?*anyopaque, ?*anyopaque) callconv(.c) [*c]u8 = @import("std").mem.zeroes(?*const fn ([*c]ngx_conf_t, ?*anyopaque, ?*anyopaque) callconv(.c) [*c]u8),
};
pub const ngx_http_header_t = extern struct {
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    offset: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    handler: ngx_http_header_handler_pt = @import("std").mem.zeroes(ngx_http_header_handler_pt),
};
pub const ngx_http_header_out_t = extern struct {
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    offset: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
const ngx_http_headers_in_flags_t = packed struct(u32) {
    connection_type: u2,
    chunked: bool,
    multi: bool,
    multi_linked: bool,
    msie: bool,
    msie6: bool,
    opera: bool,
    gecko: bool,
    chrome: bool,
    safari: bool,
    konqueror: bool,
    padding: u20,
};
pub const ngx_http_headers_in_t = extern struct {
    headers: ngx_list_t = @import("std").mem.zeroes(ngx_list_t),
    count: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    host: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    connection: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    if_modified_since: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    if_unmodified_since: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    if_match: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    if_none_match: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    user_agent: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    referer: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    content_length: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    content_range: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    content_type: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    range: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    if_range: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    transfer_encoding: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    te: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    expect: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    upgrade: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    accept_encoding: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    via: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    authorization: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    proxy_authorization: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    keep_alive: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    x_forwarded_for: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    x_real_ip: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    accept: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    accept_language: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    depth: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    destination: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    overwrite: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    date: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    cookie: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    user: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    passwd: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    server: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    content_length_n: off_t = @import("std").mem.zeroes(off_t),
    keep_alive_n: time_t = @import("std").mem.zeroes(time_t),
    flags: ngx_http_headers_in_flags_t = @import("std").mem.zeroes(ngx_http_headers_in_flags_t),
};
pub const ngx_http_headers_out_t = extern struct {
    headers: ngx_list_t = @import("std").mem.zeroes(ngx_list_t),
    trailers: ngx_list_t = @import("std").mem.zeroes(ngx_list_t),
    status: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    status_line: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    server: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    date: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    content_length: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    content_encoding: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    location: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    refresh: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    last_modified: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    content_range: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    accept_ranges: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    www_authenticate: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    proxy_authenticate: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    expires: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    etag: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    cache_control: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    link: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    override_charset: [*c]ngx_str_t = @import("std").mem.zeroes([*c]ngx_str_t),
    content_type_len: usize = @import("std").mem.zeroes(usize),
    content_type: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    charset: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    content_type_lowcase: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    content_type_hash: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    content_length_n: off_t = @import("std").mem.zeroes(off_t),
    content_offset: off_t = @import("std").mem.zeroes(off_t),
    date_time: time_t = @import("std").mem.zeroes(time_t),
    last_modified_time: time_t = @import("std").mem.zeroes(time_t),
};
pub const ngx_http_client_body_handler_pt = ?*const fn ([*c]ngx_http_request_t) callconv(.c) void;
const ngx_http_request_body_flags_t = packed struct(u32) {
    filter_need_buffering: bool,
    last_sent: bool,
    last_saved: bool,
    padding: u29,
};
pub const ngx_http_request_body_t = extern struct {
    temp_file: [*c]ngx_temp_file_t = @import("std").mem.zeroes([*c]ngx_temp_file_t),
    bufs: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    buf: [*c]ngx_buf_t = @import("std").mem.zeroes([*c]ngx_buf_t),
    rest: off_t = @import("std").mem.zeroes(off_t),
    received: off_t = @import("std").mem.zeroes(off_t),
    free: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    busy: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    chunked: [*c]ngx_http_chunked_t = @import("std").mem.zeroes([*c]ngx_http_chunked_t),
    post_handler: ngx_http_client_body_handler_pt = @import("std").mem.zeroes(ngx_http_client_body_handler_pt),
    flags: ngx_http_request_body_flags_t = @import("std").mem.zeroes(ngx_http_request_body_flags_t),
};
const struct_ngx_http_addr_conf_flags_s = packed struct(u32) {
    ssl: bool,
    http2: bool,
    quic: bool,
    proxy_protocol: bool,
    padding: u28,
};
pub const struct_ngx_http_addr_conf_s = extern struct {
    default_server: [*c]ngx_http_core_srv_conf_t = @import("std").mem.zeroes([*c]ngx_http_core_srv_conf_t),
    virtual_names: [*c]ngx_http_virtual_names_t = @import("std").mem.zeroes([*c]ngx_http_virtual_names_t),
    flags: struct_ngx_http_addr_conf_flags_s = @import("std").mem.zeroes(struct_ngx_http_addr_conf_flags_s),
};
pub const ngx_http_addr_conf_t = struct_ngx_http_addr_conf_s;
const ngx_http_connection_flags_t = packed struct(u32) {
    ssl: bool,
    proxy_protocol: bool,
    padding: u30,
};
pub const ngx_http_connection_t = extern struct {
    addr_conf: [*c]ngx_http_addr_conf_t = @import("std").mem.zeroes([*c]ngx_http_addr_conf_t),
    conf_ctx: [*c]ngx_http_conf_ctx_t = @import("std").mem.zeroes([*c]ngx_http_conf_ctx_t),
    ssl_servername: [*c]ngx_str_t = @import("std").mem.zeroes([*c]ngx_str_t),
    ssl_servername_regex: [*c]ngx_http_regex_t = @import("std").mem.zeroes([*c]ngx_http_regex_t),
    busy: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    nbusy: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
    free: [*c]ngx_chain_t = @import("std").mem.zeroes([*c]ngx_chain_t),
    keepalive_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    flags: ngx_http_connection_flags_t = @import("std").mem.zeroes(ngx_http_connection_flags_t),
};
pub const ngx_http_post_subrequest_pt = ?*const fn ([*c]ngx_http_request_t, ?*anyopaque, ngx_int_t) callconv(.c) ngx_int_t;
pub const ngx_http_post_subrequest_t = extern struct {
    handler: ngx_http_post_subrequest_pt = @import("std").mem.zeroes(ngx_http_post_subrequest_pt),
    data: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
};
const ngx_http_script_engine_flags_t = packed struct(u32) {
    flushed: bool,
    skip: bool,
    quote: bool,
    is_args: bool,
    log: bool,
    padding: u27,
};
pub const ngx_http_script_engine_t = extern struct {
    ip: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    pos: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    sp: [*c]ngx_http_variable_value_t = @import("std").mem.zeroes([*c]ngx_http_variable_value_t),
    buf: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    line: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    args: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    flags: ngx_http_script_engine_flags_t = @import("std").mem.zeroes(ngx_http_script_engine_flags_t),
    status: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
    request: [*c]ngx_http_request_t = @import("std").mem.zeroes([*c]ngx_http_request_t),
};

const ngx_http_script_compile_flags_t = packed struct(u32) {
    compile_args: bool,
    complete_lengths: bool,
    complete_values: bool,
    zero: bool,
    conf_prefix: bool,
    root_prefix: bool,
    dup_capture: bool,
    args: bool,
    padding: u24,
};
pub const ngx_http_script_compile_t = extern struct {
    cf: [*c]ngx_conf_t = @import("std").mem.zeroes([*c]ngx_conf_t),
    source: [*c]ngx_str_t = @import("std").mem.zeroes([*c]ngx_str_t),
    flushes: [*c][*c]ngx_array_t = @import("std").mem.zeroes([*c][*c]ngx_array_t),
    lengths: [*c][*c]ngx_array_t = @import("std").mem.zeroes([*c][*c]ngx_array_t),
    values: [*c][*c]ngx_array_t = @import("std").mem.zeroes([*c][*c]ngx_array_t),
    variables: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    ncaptures: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    captures_mask: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    size: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    main: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    flags: ngx_http_script_compile_flags_t = @import("std").mem.zeroes(ngx_http_script_compile_flags_t),
};
const union_unnamed_259 = extern union {
    size: usize,
};
pub const ngx_http_complex_value_t = extern struct {
    value: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    flushes: [*c]ngx_uint_t = @import("std").mem.zeroes([*c]ngx_uint_t),
    lengths: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    values: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    u: union_unnamed_259 = @import("std").mem.zeroes(union_unnamed_259),
};
const ngx_http_compile_complex_value_flags_t = packed struct(u32) {
    zero: bool,
    conf_prefix: bool,
    root_prefix: bool,
    padding: u29,
};
pub const ngx_http_compile_complex_value_t = extern struct {
    cf: [*c]ngx_conf_t = @import("std").mem.zeroes([*c]ngx_conf_t),
    value: [*c]ngx_str_t = @import("std").mem.zeroes([*c]ngx_str_t),
    complex_value: [*c]ngx_http_complex_value_t = @import("std").mem.zeroes([*c]ngx_http_complex_value_t),
    flags: ngx_http_compile_complex_value_flags_t = @import("std").mem.zeroes(ngx_http_compile_complex_value_flags_t),
};
pub const ngx_http_script_code_pt = ?*const fn ([*c]ngx_http_script_engine_t) callconv(.c) void;
const ngx_http_script_regex_code_flags_t = packed struct(u32) {
    @"test": bool,
    negative_test: bool,
    uri: bool,
    args: bool,
    add_args: bool,
    redirect: bool,
    break_cycle: bool,
    padding: u25,
};
pub const ngx_http_script_regex_code_t = extern struct {
    code: ngx_http_script_code_pt = @import("std").mem.zeroes(ngx_http_script_code_pt),
    regex: [*c]ngx_http_regex_t = @import("std").mem.zeroes([*c]ngx_http_regex_t),
    lengths: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    size: usize = @import("std").mem.zeroes(usize),
    status: usize = @import("std").mem.zeroes(usize),
    next: usize = @import("std").mem.zeroes(usize),
    flags: ngx_http_script_regex_code_flags_t = @import("std").mem.zeroes(ngx_http_script_regex_code_flags_t),
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
};
const ngx_http_script_regex_end_code_flags_t = packed struct(u32) {
    uri: bool,
    args: bool,
    add_args: bool,
    redirect: bool,
    padding: u28,
};
pub const ngx_http_script_regex_end_code_t = extern struct {
    code: ngx_http_script_code_pt = @import("std").mem.zeroes(ngx_http_script_code_pt),
    flags: ngx_http_script_regex_end_code_flags_t = @import("std").mem.zeroes(ngx_http_script_regex_end_code_flags_t),
};
pub extern fn ngx_http_script_variables_count(value: [*c]ngx_str_t) ngx_uint_t;
pub extern fn ngx_http_script_compile(sc: [*c]ngx_http_script_compile_t) ngx_int_t;
pub extern fn ngx_http_script_run(r: [*c]ngx_http_request_t, value: [*c]ngx_str_t, code_lengths: ?*anyopaque, reserved: usize, code_values: ?*anyopaque) [*c]u_char;
pub extern fn ngx_handle_read_event(rev: [*c]ngx_event_t, flags: ngx_uint_t) ngx_int_t;
pub extern fn ngx_handle_write_event(wev: [*c]ngx_event_t, lowat: usize) ngx_int_t;
pub const ngx_http_upstream_state_t = extern struct {
    status: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    response_time: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    connect_time: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    header_time: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    queue_time: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    response_length: off_t = @import("std").mem.zeroes(off_t),
    bytes_received: off_t = @import("std").mem.zeroes(off_t),
    bytes_sent: off_t = @import("std").mem.zeroes(off_t),
    peer: [*c]ngx_str_t = @import("std").mem.zeroes([*c]ngx_str_t),
};
pub const ngx_http_upstream_main_conf_t = extern struct {
    headers_in_hash: ngx_hash_t = @import("std").mem.zeroes(ngx_hash_t),
    upstreams: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
};
pub const ngx_http_upstream_init_pt = ?*const fn ([*c]ngx_conf_t, [*c]ngx_http_upstream_srv_conf_t) callconv(.c) ngx_int_t;
pub const ngx_http_upstream_init_peer_pt = ?*const fn ([*c]ngx_http_request_t, [*c]ngx_http_upstream_srv_conf_t) callconv(.c) ngx_int_t;
pub const ngx_http_upstream_peer_t = extern struct {
    init_upstream: ngx_http_upstream_init_pt = @import("std").mem.zeroes(ngx_http_upstream_init_pt),
    init: ngx_http_upstream_init_peer_pt = @import("std").mem.zeroes(ngx_http_upstream_init_peer_pt),
    data: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
};
const ngx_http_upstream_server_flags_t = packed struct(u32) {
    backup: bool,
    padding: u31,
};
pub const ngx_http_upstream_server_t = extern struct {
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    addrs: [*c]ngx_addr_t = @import("std").mem.zeroes([*c]ngx_addr_t),
    naddrs: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    weight: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    max_conns: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    max_fails: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    fail_timeout: time_t = @import("std").mem.zeroes(time_t),
    slow_start: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    down: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    flags: ngx_http_upstream_server_flags_t = @import("std").mem.zeroes(ngx_http_upstream_server_flags_t),
    host: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    service: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    sid: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
};
pub const ngx_http_upstream_local_t = extern struct {
    addr: [*c]ngx_addr_t = @import("std").mem.zeroes([*c]ngx_addr_t),
    value: [*c]ngx_http_complex_value_t = @import("std").mem.zeroes([*c]ngx_http_complex_value_t),
    transparent: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
const ngx_http_upstream_conf_flags_t = packed struct(u32) {
    cache: i2,
    store: i2,
    intercept_404: bool,
    change_buffering: bool,
    preserve_output: bool,
    padding: u25,
};
pub const ngx_http_upstream_conf_t = extern struct {
    upstream: [*c]ngx_http_upstream_srv_conf_t = @import("std").mem.zeroes([*c]ngx_http_upstream_srv_conf_t),
    connect_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    send_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    read_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    next_upstream_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    send_lowat: usize = @import("std").mem.zeroes(usize),
    buffer_size: usize = @import("std").mem.zeroes(usize),
    limit_rate: [*c]ngx_http_complex_value_t = @import("std").mem.zeroes([*c]ngx_http_complex_value_t),
    busy_buffers_size: usize = @import("std").mem.zeroes(usize),
    max_temp_file_size: usize = @import("std").mem.zeroes(usize),
    temp_file_write_size: usize = @import("std").mem.zeroes(usize),
    busy_buffers_size_conf: usize = @import("std").mem.zeroes(usize),
    max_temp_file_size_conf: usize = @import("std").mem.zeroes(usize),
    temp_file_write_size_conf: usize = @import("std").mem.zeroes(usize),
    bufs: ngx_bufs_t = @import("std").mem.zeroes(ngx_bufs_t),
    ignore_headers: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    next_upstream: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    store_access: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    next_upstream_tries: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    buffering: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    request_buffering: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    pass_request_headers: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    pass_request_body: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    pass_trailers: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    pass_early_hints: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    ignore_client_abort: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    intercept_errors: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    cyclic_temp_file: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    force_ranges: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    temp_path: [*c]ngx_path_t = @import("std").mem.zeroes([*c]ngx_path_t),
    hide_headers_hash: ngx_hash_t = @import("std").mem.zeroes(ngx_hash_t),
    hide_headers: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    pass_headers: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    local: [*c]ngx_http_upstream_local_t = @import("std").mem.zeroes([*c]ngx_http_upstream_local_t),
    socket_keepalive: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    cache_zone: [*c]ngx_shm_zone_t = @import("std").mem.zeroes([*c]ngx_shm_zone_t),
    cache_value: [*c]ngx_http_complex_value_t = @import("std").mem.zeroes([*c]ngx_http_complex_value_t),
    cache_min_uses: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    cache_use_stale: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    cache_methods: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    cache_max_range_offset: off_t = @import("std").mem.zeroes(off_t),
    cache_lock: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    cache_lock_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    cache_lock_age: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    cache_revalidate: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    cache_convert_head: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    cache_background_update: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    cache_valid: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    cache_bypass: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    cache_purge: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    no_cache: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    store_lengths: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    store_values: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    flags: ngx_http_upstream_conf_flags_t = @import("std").mem.zeroes(ngx_http_upstream_conf_flags_t),
    ssl: [*c]ngx_ssl_t = @import("std").mem.zeroes([*c]ngx_ssl_t),
    ssl_session_reuse: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    ssl_name: [*c]ngx_http_complex_value_t = @import("std").mem.zeroes([*c]ngx_http_complex_value_t),
    ssl_server_name: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    ssl_verify: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    ssl_certificate: [*c]ngx_http_complex_value_t = @import("std").mem.zeroes([*c]ngx_http_complex_value_t),
    ssl_certificate_key: [*c]ngx_http_complex_value_t = @import("std").mem.zeroes([*c]ngx_http_complex_value_t),
    ssl_certificate_cache: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    ssl_passwords: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    module: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    spare: [6]u64 = @import("std").mem.zeroes([6]u64),
};
pub const ngx_http_upstream_header_t = extern struct {
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    handler: ngx_http_header_handler_pt = @import("std").mem.zeroes(ngx_http_header_handler_pt),
    offset: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    copy_handler: ngx_http_header_handler_pt = @import("std").mem.zeroes(ngx_http_header_handler_pt),
    conf: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    redirect: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
const ngx_http_upstream_headers_in_flags_t = packed struct(u32) {
    connection_close: bool,
    chunked: bool,
    no_cache: bool,
    expired: bool,
    padding: u28,
};
pub const ngx_http_upstream_headers_in_t = extern struct {
    headers: ngx_list_t = @import("std").mem.zeroes(ngx_list_t),
    trailers: ngx_list_t = @import("std").mem.zeroes(ngx_list_t),
    status_n: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    status_line: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    status: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    date: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    server: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    connection: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    expires: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    etag: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    x_accel_expires: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    x_accel_redirect: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    x_accel_limit_rate: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    content_type: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    content_length: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    last_modified: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    location: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    refresh: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    www_authenticate: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    transfer_encoding: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    vary: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    cache_control: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    set_cookie: [*c]ngx_table_elt_t = @import("std").mem.zeroes([*c]ngx_table_elt_t),
    content_length_n: off_t = @import("std").mem.zeroes(off_t),
    last_modified_time: time_t = @import("std").mem.zeroes(time_t),
    flags: ngx_http_upstream_headers_in_flags_t = @import("std").mem.zeroes(ngx_http_upstream_headers_in_flags_t),
};
pub const ngx_http_upstream_resolved_t = extern struct {
    host: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    port: in_port_t = @import("std").mem.zeroes(in_port_t),
    no_port: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    naddrs: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    addrs: [*c]ngx_resolver_addr_t = @import("std").mem.zeroes([*c]ngx_resolver_addr_t),
    sockaddr: [*c]struct_sockaddr = @import("std").mem.zeroes([*c]struct_sockaddr),
    socklen: socklen_t = @import("std").mem.zeroes(socklen_t),
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    ctx: [*c]ngx_resolver_ctx_t = @import("std").mem.zeroes([*c]ngx_resolver_ctx_t),
};
pub extern fn ngx_http_upstream_create(r: [*c]ngx_http_request_t) ngx_int_t;
pub extern fn ngx_http_upstream_init(r: [*c]ngx_http_request_t) void;
pub extern fn ngx_http_upstream_non_buffered_filter_init(data: ?*anyopaque) ngx_int_t;
pub extern fn ngx_http_upstream_non_buffered_filter(data: ?*anyopaque, bytes: isize) ngx_int_t;
pub extern fn ngx_http_upstream_hide_headers_hash(cf: [*c]ngx_conf_t, conf: [*c]ngx_http_upstream_conf_t, prev: [*c]ngx_http_upstream_conf_t, default_hide_headers: [*c]ngx_str_t, hash: [*c]ngx_hash_init_t) ngx_int_t;
const struct_ngx_http_upstream_rr_peer_flags_s = packed struct(u32) {
    route: bool,
    zombie: bool,
    padding: u30,
};
pub const struct_ngx_http_upstream_rr_peer_s = extern struct {
    sockaddr: [*c]struct_sockaddr = @import("std").mem.zeroes([*c]struct_sockaddr),
    socklen: socklen_t = @import("std").mem.zeroes(socklen_t),
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    server: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    current_weight: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
    effective_weight: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
    weight: ngx_int_t = @import("std").mem.zeroes(ngx_int_t),
    conns: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    max_conns: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    fails: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    accessed: time_t = @import("std").mem.zeroes(time_t),
    checked: time_t = @import("std").mem.zeroes(time_t),
    max_fails: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    fail_timeout: time_t = @import("std").mem.zeroes(time_t),
    slow_start: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    start_time: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    down: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    ssl_session: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    ssl_session_len: c_int = @import("std").mem.zeroes(c_int),
    flags: struct_ngx_http_upstream_rr_peer_flags_s = @import("std").mem.zeroes(struct_ngx_http_upstream_rr_peer_flags_s),
    lock: ngx_atomic_t = @import("std").mem.zeroes(ngx_atomic_t),
    refs: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    host: [*c]ngx_http_upstream_host_t = @import("std").mem.zeroes([*c]ngx_http_upstream_host_t),
    sid: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    next: [*c]ngx_http_upstream_rr_peer_t = @import("std").mem.zeroes([*c]ngx_http_upstream_rr_peer_t),
    spare: [13]u64 = @import("std").mem.zeroes([13]u64),
};
pub const ngx_http_upstream_rr_peer_t = struct_ngx_http_upstream_rr_peer_s;
pub const ngx_http_upstream_rr_peers_t = struct_ngx_http_upstream_rr_peers_s;
const struct_ngx_http_upstream_rr_peers_flags_s = packed struct(u32) {
    single: bool,
    weighted: bool,
    padding: u30,
};
pub const struct_ngx_http_upstream_rr_peers_s = extern struct {
    number: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    shpool: [*c]ngx_slab_pool_t = @import("std").mem.zeroes([*c]ngx_slab_pool_t),
    rwlock: ngx_atomic_t = @import("std").mem.zeroes(ngx_atomic_t),
    config: [*c]ngx_uint_t = @import("std").mem.zeroes([*c]ngx_uint_t),
    resolve: [*c]ngx_http_upstream_rr_peer_t = @import("std").mem.zeroes([*c]ngx_http_upstream_rr_peer_t),
    zone_next: [*c]ngx_http_upstream_rr_peers_t = @import("std").mem.zeroes([*c]ngx_http_upstream_rr_peers_t),
    total_weight: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    tries: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    flags: struct_ngx_http_upstream_rr_peers_flags_s = @import("std").mem.zeroes(struct_ngx_http_upstream_rr_peers_flags_s),
    name: [*c]ngx_str_t = @import("std").mem.zeroes([*c]ngx_str_t),
    next: [*c]ngx_http_upstream_rr_peers_t = @import("std").mem.zeroes([*c]ngx_http_upstream_rr_peers_t),
    peer: [*c]ngx_http_upstream_rr_peer_t = @import("std").mem.zeroes([*c]ngx_http_upstream_rr_peer_t),
};
pub const ngx_http_upstream_host_t = extern struct {
    event: ngx_event_t = @import("std").mem.zeroes(ngx_event_t),
    worker: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    service: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    valid: time_t = @import("std").mem.zeroes(time_t),
    peers: [*c]ngx_http_upstream_rr_peers_t = @import("std").mem.zeroes([*c]ngx_http_upstream_rr_peers_t),
    peer: [*c]ngx_http_upstream_rr_peer_t = @import("std").mem.zeroes([*c]ngx_http_upstream_rr_peer_t),
};
pub const ngx_http_upstream_rr_peer_data_t = extern struct {
    config: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    peers: [*c]ngx_http_upstream_rr_peers_t = @import("std").mem.zeroes([*c]ngx_http_upstream_rr_peers_t),
    current: [*c]ngx_http_upstream_rr_peer_t = @import("std").mem.zeroes([*c]ngx_http_upstream_rr_peer_t),
    tried: [*c]usize = @import("std").mem.zeroes([*c]usize),
    data: usize = @import("std").mem.zeroes(usize),
};
pub const ngx_http_location_tree_node_t = struct_ngx_http_location_tree_node_s;

const struct_ngx_http_core_loc_conf_flags_s = packed struct(u32) {
    noname: bool,
    lmt_excpt: bool,
    named: bool,
    exact_match: bool,
    noregex: bool,
    auto_redirect: bool,
    gzip_disable_msie6: u2,
    gzip_disalbe_degradation: u2,
    padding: u22,
};
pub const struct_ngx_http_core_loc_conf_s = extern struct {
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    escaped_name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    regex: [*c]ngx_http_regex_t = @import("std").mem.zeroes([*c]ngx_http_regex_t),
    flags: struct_ngx_http_core_loc_conf_flags_s = @import("std").mem.zeroes(struct_ngx_http_core_loc_conf_flags_s),
    static_locations: [*c]ngx_http_location_tree_node_t = @import("std").mem.zeroes([*c]ngx_http_location_tree_node_t),
    regex_locations: [*c][*c]ngx_http_core_loc_conf_t = @import("std").mem.zeroes([*c][*c]ngx_http_core_loc_conf_t),
    loc_conf: [*c]?*anyopaque = @import("std").mem.zeroes([*c]?*anyopaque),
    limit_except: u32 = @import("std").mem.zeroes(u32),
    limit_except_loc_conf: [*c]?*anyopaque = @import("std").mem.zeroes([*c]?*anyopaque),
    handler: ngx_http_handler_pt = @import("std").mem.zeroes(ngx_http_handler_pt),
    alias: usize = @import("std").mem.zeroes(usize),
    root: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    post_action: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    root_lengths: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    root_values: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    types: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    types_hash: ngx_hash_t = @import("std").mem.zeroes(ngx_hash_t),
    default_type: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    client_max_body_size: off_t = @import("std").mem.zeroes(off_t),
    directio: off_t = @import("std").mem.zeroes(off_t),
    directio_alignment: off_t = @import("std").mem.zeroes(off_t),
    client_body_buffer_size: usize = @import("std").mem.zeroes(usize),
    send_lowat: usize = @import("std").mem.zeroes(usize),
    postpone_output: usize = @import("std").mem.zeroes(usize),
    sendfile_max_chunk: usize = @import("std").mem.zeroes(usize),
    read_ahead: usize = @import("std").mem.zeroes(usize),
    subrequest_output_buffer_size: usize = @import("std").mem.zeroes(usize),
    limit_rate: [*c]ngx_http_complex_value_t = @import("std").mem.zeroes([*c]ngx_http_complex_value_t),
    limit_rate_after: [*c]ngx_http_complex_value_t = @import("std").mem.zeroes([*c]ngx_http_complex_value_t),
    client_body_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    send_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    keepalive_time: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    keepalive_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    keepalive_min_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    lingering_time: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    lingering_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    resolver_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    auth_delay: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    resolver: [*c]ngx_resolver_t = @import("std").mem.zeroes([*c]ngx_resolver_t),
    keepalive_header: time_t = @import("std").mem.zeroes(time_t),
    keepalive_requests: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    keepalive_disable: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    satisfy: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    lingering_close: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    if_modified_since: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    max_ranges: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    client_body_in_file_only: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    client_body_in_single_buffer: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    internal: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    sendfile: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    aio: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    aio_write: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    tcp_nopush: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    tcp_nodelay: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    reset_timedout_connection: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    absolute_redirect: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    server_name_in_redirect: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    port_in_redirect: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    msie_padding: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    msie_refresh: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    log_not_found: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    log_subrequest: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    recursive_error_pages: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    server_tokens: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    chunked_transfer_encoding: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    etag: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    gzip_vary: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    gzip_http_version: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    gzip_proxied: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    gzip_disable: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    thread_pool: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    thread_pool_value: [*c]ngx_http_complex_value_t = @import("std").mem.zeroes([*c]ngx_http_complex_value_t),
    disable_symlinks: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    disable_symlinks_from: [*c]ngx_http_complex_value_t = @import("std").mem.zeroes([*c]ngx_http_complex_value_t),
    early_hints: [*c]ngx_array_t =  @import("std").mem.zeroes([*c]ngx_array_t),
    error_pages: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    client_body_temp_path: [*c]ngx_path_t = @import("std").mem.zeroes([*c]ngx_path_t),
    open_file_cache: [*c]ngx_open_file_cache_t = @import("std").mem.zeroes([*c]ngx_open_file_cache_t),
    open_file_cache_valid: time_t = @import("std").mem.zeroes(time_t),
    open_file_cache_min_uses: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    open_file_cache_errors: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    open_file_cache_events: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    error_log: [*c]ngx_log_t = @import("std").mem.zeroes([*c]ngx_log_t),
    types_hash_max_size: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    types_hash_bucket_size: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    locations: [*c]ngx_queue_t = @import("std").mem.zeroes([*c]ngx_queue_t),
};
pub const ngx_http_core_loc_conf_t = struct_ngx_http_core_loc_conf_s;
pub const struct_ngx_http_location_tree_node_s = extern struct {
    left: [*c]ngx_http_location_tree_node_t = @import("std").mem.zeroes([*c]ngx_http_location_tree_node_t),
    right: [*c]ngx_http_location_tree_node_t = @import("std").mem.zeroes([*c]ngx_http_location_tree_node_t),
    tree: [*c]ngx_http_location_tree_node_t = @import("std").mem.zeroes([*c]ngx_http_location_tree_node_t),
    exact: [*c]ngx_http_core_loc_conf_t = @import("std").mem.zeroes([*c]ngx_http_core_loc_conf_t),
    inclusive: [*c]ngx_http_core_loc_conf_t = @import("std").mem.zeroes([*c]ngx_http_core_loc_conf_t),
    len: u_short = @import("std").mem.zeroes(u_short),
    auto_redirect: u_char = @import("std").mem.zeroes(u_char),
    name: [1]u_char = @import("std").mem.zeroes([1]u_char),
};
const ngx_http_listen_opt_flags_t = packed struct(u32) {
    set: bool,
    default_server: bool,
    bind: bool,
    wildcard: bool,
    ssl: bool,
    http2: bool,
    quic: bool,
    ipv6only: bool,
    deferred_accept: bool,
    reuseport: bool,
    so_keepalive: u2,
    proxy_protocol: bool,
    padding: u19,
};
pub const ngx_http_listen_opt_t = extern struct {
    sockaddr: [*c]struct_sockaddr = @import("std").mem.zeroes([*c]struct_sockaddr),
    socklen: socklen_t = @import("std").mem.zeroes(socklen_t),
    addr_text: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    flags: ngx_http_listen_opt_flags_t = @import("std").mem.zeroes(ngx_http_listen_opt_flags_t),
    backlog: c_int = @import("std").mem.zeroes(c_int),
    rcvbuf: c_int = @import("std").mem.zeroes(c_int),
    sndbuf: c_int = @import("std").mem.zeroes(c_int),
    type: c_int = @import("std").mem.zeroes(c_int),
    protocol: c_int = @import("std").mem.zeroes(c_int),
    fastopen: c_int = @import("std").mem.zeroes(c_int),
    tcp_keepidle: c_int = @import("std").mem.zeroes(c_int),
    tcp_keepintvl: c_int = @import("std").mem.zeroes(c_int),
    tcp_keepcnt: c_int = @import("std").mem.zeroes(c_int),
};
pub const NGX_HTTP_ACCESS_PHASE: c_int = 6;
pub const NGX_HTTP_CONTENT_PHASE: c_int = 9;
pub const ngx_http_phase_handler_t = struct_ngx_http_phase_handler_s;
pub const ngx_http_phase_handler_pt = ?*const fn ([*c]ngx_http_request_t, [*c]ngx_http_phase_handler_t) callconv(.c) ngx_int_t;
pub const struct_ngx_http_phase_handler_s = extern struct {
    checker: ngx_http_phase_handler_pt = @import("std").mem.zeroes(ngx_http_phase_handler_pt),
    handler: ngx_http_handler_pt = @import("std").mem.zeroes(ngx_http_handler_pt),
    next: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
pub const ngx_http_phase_engine_t = extern struct {
    handlers: [*c]ngx_http_phase_handler_t = @import("std").mem.zeroes([*c]ngx_http_phase_handler_t),
    server_rewrite_index: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    location_rewrite_index: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
pub const ngx_http_phase_t = extern struct {
    handlers: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
};
pub const ngx_http_core_main_conf_t = extern struct {
    servers: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
    phase_engine: ngx_http_phase_engine_t = @import("std").mem.zeroes(ngx_http_phase_engine_t),
    headers_in_hash: ngx_hash_t = @import("std").mem.zeroes(ngx_hash_t),
    variables_hash: ngx_hash_t = @import("std").mem.zeroes(ngx_hash_t),
    variables: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
    prefix_variables: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
    ncaptures: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    server_names_hash_max_size: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    server_names_hash_bucket_size: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    variables_hash_max_size: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    variables_hash_bucket_size: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    variables_keys: [*c]ngx_hash_keys_arrays_t = @import("std").mem.zeroes([*c]ngx_hash_keys_arrays_t),
    ports: [*c]ngx_array_t = @import("std").mem.zeroes([*c]ngx_array_t),
    phases: [11]ngx_http_phase_t = @import("std").mem.zeroes([11]ngx_http_phase_t),
};
const ngx_http_core_srv_conf_flags_t = packed struct(u32) {
    listen: bool,
    captures: bool,
    allow_connect: bool,
    padding: u29,
};
pub const ngx_http_core_srv_conf_t = extern struct {
    server_names: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
    ctx: [*c]ngx_http_conf_ctx_t = @import("std").mem.zeroes([*c]ngx_http_conf_ctx_t),
    file_name: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    line: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    server_name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
    connection_pool_size: usize = @import("std").mem.zeroes(usize),
    request_pool_size: usize = @import("std").mem.zeroes(usize),
    client_header_buffer_size: usize = @import("std").mem.zeroes(usize),
    large_client_header_buffers: ngx_bufs_t = @import("std").mem.zeroes(ngx_bufs_t),
    client_header_timeout: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
    max_headers: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    ignore_invalid_headers: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    merge_slashes: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    underscores_in_headers: ngx_flag_t = @import("std").mem.zeroes(ngx_flag_t),
    flags: ngx_http_core_srv_conf_flags_t = @import("std").mem.zeroes(ngx_http_core_srv_conf_flags_t),
    named_locations: [*c][*c]ngx_http_core_loc_conf_t = @import("std").mem.zeroes([*c][*c]ngx_http_core_loc_conf_t),
};
pub const ngx_http_server_name_t = extern struct {
    regex: [*c]ngx_http_regex_t = @import("std").mem.zeroes([*c]ngx_http_regex_t),
    server: [*c]ngx_http_core_srv_conf_t = @import("std").mem.zeroes([*c]ngx_http_core_srv_conf_t),
    name: ngx_str_t = @import("std").mem.zeroes(ngx_str_t),
};
pub const ngx_http_virtual_names_t = extern struct {
    names: ngx_hash_combined_t = @import("std").mem.zeroes(ngx_hash_combined_t),
    nregex: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    regex: [*c]ngx_http_server_name_t = @import("std").mem.zeroes([*c]ngx_http_server_name_t),
};
const ngx_http_conf_addr_flags_t = packed struct(u32) {
    protocols: u3,
    protocols_set: bool,
    protocols_changed: bool,
    padding: u27,
};
pub const ngx_http_conf_addr_t = extern struct {
    opt: ngx_http_listen_opt_t = @import("std").mem.zeroes(ngx_http_listen_opt_t),
    flags: ngx_http_conf_addr_flags_t = @import("std").mem.zeroes(ngx_http_conf_addr_flags_t),
    hash: ngx_hash_t = @import("std").mem.zeroes(ngx_hash_t),
    wc_head: [*c]ngx_hash_wildcard_t = @import("std").mem.zeroes([*c]ngx_hash_wildcard_t),
    wc_tail: [*c]ngx_hash_wildcard_t = @import("std").mem.zeroes([*c]ngx_hash_wildcard_t),
    nregex: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    regex: [*c]ngx_http_server_name_t = @import("std").mem.zeroes([*c]ngx_http_server_name_t),
    default_server: [*c]ngx_http_core_srv_conf_t = @import("std").mem.zeroes([*c]ngx_http_core_srv_conf_t),
    servers: ngx_array_t = @import("std").mem.zeroes(ngx_array_t),
};
pub extern fn ngx_http_core_run_phases(r: [*c]ngx_http_request_t) void;
pub extern fn ngx_http_subrequest(r: [*c]ngx_http_request_t, uri: [*c]ngx_str_t, args: [*c]ngx_str_t, psr: [*c][*c]ngx_http_request_t, ps: [*c]ngx_http_post_subrequest_t, flags: ngx_uint_t) ngx_int_t;
pub extern fn ngx_http_internal_redirect(r: [*c]ngx_http_request_t, uri: [*c]ngx_str_t, args: [*c]ngx_str_t) ngx_int_t;
pub extern fn ngx_http_named_location(r: [*c]ngx_http_request_t, name: [*c]ngx_str_t) ngx_int_t;
pub extern fn ngx_http_cleanup_add(r: [*c]ngx_http_request_t, size: usize) [*c]ngx_http_cleanup_t;
pub const ngx_http_output_header_filter_pt = ?*const fn ([*c]ngx_http_request_t) callconv(.c) ngx_int_t;
pub const ngx_http_output_body_filter_pt = ?*const fn ([*c]ngx_http_request_t, [*c]ngx_chain_t) callconv(.c) ngx_int_t;
pub const ngx_http_request_body_filter_pt = ?*const fn ([*c]ngx_http_request_t, [*c]ngx_chain_t) callconv(.c) ngx_int_t;
pub extern fn ngx_http_output_filter(r: [*c]ngx_http_request_t, chain: [*c]ngx_chain_t) ngx_int_t;
const ngx_http_file_cache_node_flags_t = packed struct(u64) {
    count: u20,
    uses: u10,
    valid_msec: u10,
    @"error": u10,
    exists: bool,
    updating: bool,
    deleting: bool,
    purged: bool,
    padding: u10,
};
pub const ngx_http_file_cache_node_t = extern struct {
    node: ngx_rbtree_node_t = @import("std").mem.zeroes(ngx_rbtree_node_t),
    queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    key: [8]u_char = @import("std").mem.zeroes([8]u_char),
    flags: ngx_http_file_cache_node_flags_t = @import("std").mem.zeroes(ngx_http_file_cache_node_flags_t),
    uniq: ngx_file_uniq_t = @import("std").mem.zeroes(ngx_file_uniq_t),
    expire: time_t = @import("std").mem.zeroes(time_t),
    valid_sec: time_t = @import("std").mem.zeroes(time_t),
    body_start: usize = @import("std").mem.zeroes(usize),
    fs_size: off_t = @import("std").mem.zeroes(off_t),
    lock_time: ngx_msec_t = @import("std").mem.zeroes(ngx_msec_t),
};
pub const ngx_http_file_cache_sh_t = extern struct {
    rbtree: ngx_rbtree_t = @import("std").mem.zeroes(ngx_rbtree_t),
    sentinel: ngx_rbtree_node_t = @import("std").mem.zeroes(ngx_rbtree_node_t),
    queue: ngx_queue_t = @import("std").mem.zeroes(ngx_queue_t),
    cold: ngx_atomic_t = @import("std").mem.zeroes(ngx_atomic_t),
    loading: ngx_atomic_t = @import("std").mem.zeroes(ngx_atomic_t),
    size: off_t = @import("std").mem.zeroes(off_t),
    count: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    watermark: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
};
pub const ngx_http_status_t = extern struct {
    http_version: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    code: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    count: ngx_uint_t = @import("std").mem.zeroes(ngx_uint_t),
    start: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
    end: [*c]u_char = @import("std").mem.zeroes([*c]u_char),
};
pub extern fn ngx_http_parse_request_line(r: [*c]ngx_http_request_t, b: [*c]ngx_buf_t) ngx_int_t;
pub extern fn ngx_http_parse_status_line(r: [*c]ngx_http_request_t, b: [*c]ngx_buf_t, status: [*c]ngx_http_status_t) ngx_int_t;
pub extern fn ngx_http_parse_unsafe_uri(r: [*c]ngx_http_request_t, uri: [*c]ngx_str_t, args: [*c]ngx_str_t, flags: [*c]ngx_uint_t) ngx_int_t;
pub extern fn ngx_http_parse_header_line(r: [*c]ngx_http_request_t, b: [*c]ngx_buf_t, allow_underscores: ngx_uint_t) ngx_int_t;
pub extern fn ngx_http_run_posted_requests(c: [*c]ngx_connection_t) void;
pub extern fn ngx_http_finalize_request(r: [*c]ngx_http_request_t, rc: ngx_int_t) void;
pub extern fn ngx_http_request_empty_handler(r: [*c]ngx_http_request_t) void;
pub extern fn ngx_http_send_special(r: [*c]ngx_http_request_t, flags: ngx_uint_t) ngx_int_t;
pub extern fn ngx_http_read_client_request_body(r: [*c]ngx_http_request_t, post_handler: ngx_http_client_body_handler_pt) ngx_int_t;
pub extern fn ngx_http_send_header(r: [*c]ngx_http_request_t) ngx_int_t;
pub extern fn ngx_http_discard_request_body(r: [*c]ngx_http_request_t) ngx_int_t;
pub const NULL = @import("std").zig.c_translation.helpers.cast(?*anyopaque, @as(c_int, 0));
pub const O_RDONLY = @as(c_int, 0o0);
pub const O_WRONLY = @as(c_int, 0o1);
pub const O_RDWR = @as(c_int, 0o2);
pub const NGX_CPU_CACHE_LINE = @as(c_int, 64);
pub const ngx_random = random;
pub const NGX_ALIGNMENT = @import("std").zig.c_translation.helpers.sizeof(c_ulong);
pub const NGX_OK = @as(c_int, 0);
pub const NGX_ERROR = -@as(c_int, 1);
pub const NGX_AGAIN = -@as(c_int, 2);
pub const NGX_BUSY = -@as(c_int, 3);
pub const NGX_DONE = -@as(c_int, 4);
pub const NGX_DECLINED = -@as(c_int, 5);
pub const NGX_ABORT = -@as(c_int, 6);
pub const NGX_INVALID_FILE = -@as(c_int, 1);
pub const NGX_FILE_ERROR = -@as(c_int, 1);
pub const NGX_FILE_RDONLY = O_RDONLY;
pub const NGX_FILE_WRONLY = O_WRONLY;
pub const NGX_FILE_RDWR = O_RDWR;
pub const NGX_FILE_OPEN = @as(c_int, 0);
pub const ngx_close_file = close;
pub inline fn ngx_fd_info(fd: anytype, sb: anytype) @TypeOf(fstat(fd, sb)) {
    _ = &fd;
    _ = &sb;
    return fstat(fd, sb);
}
pub inline fn ngx_file_size(sb: anytype) @TypeOf(sb.*.st_size) {
    _ = &sb;
    return sb.*.st_size;
}
pub const NGX_HASH_SMALL = @as(c_int, 1);
pub const NGX_HASH_LARGE = @as(c_int, 2);
pub const NGX_HASH_WILDCARD_KEY = @as(c_int, 1);
pub const NGX_HASH_READONLY_KEY = @as(c_int, 2);
pub const NGX_REGEX_CASELESS = @as(c_int, 0x00000001);
pub const NGX_REGEX_MULTILINE = @as(c_int, 0x00000002);
pub inline fn ngx_time() @TypeOf(ngx_cached_time.*.sec) {
    return ngx_cached_time.*.sec;
}
pub inline fn ngx_timeofday() [*c]ngx_time_t {
    return @import("std").zig.c_translation.helpers.cast([*c]ngx_time_t, ngx_cached_time);
}
pub const OPENSSL_INIT_LOAD_CRYPTO_STRINGS = @as(c_long, 0x00000002);
pub const OPENSSL_INIT_ADD_ALL_CIPHERS = @as(c_long, 0x00000004);
pub const OPENSSL_INIT_ADD_ALL_DIGESTS = @as(c_long, 0x00000008);
pub const BIO_CTRL_INFO = @as(c_int, 3);
pub inline fn BN_num_bytes(a: anytype) @TypeOf(@import("std").zig.c_translation.helpers.div(BN_num_bits(a) + @as(c_int, 7), @as(c_int, 8))) {
    _ = &a;
    return @import("std").zig.c_translation.helpers.div(BN_num_bits(a) + @as(c_int, 7), @as(c_int, 8));
}
pub const NID_commonName = @as(c_int, 13);
pub const NID_subject_alt_name = @as(c_int, 85);
pub const V_ASN1_IA5STRING = @as(c_int, 22);
pub const MBSTRING_FLAG = @as(c_int, 0x1000);
pub const MBSTRING_ASC = MBSTRING_FLAG | @as(c_int, 1);
pub const EVP_CTRL_AEAD_GET_TAG = @as(c_int, 0x10);
pub const EVP_CTRL_AEAD_SET_TAG = @as(c_int, 0x11);
pub const EVP_CTRL_GCM_GET_TAG = EVP_CTRL_AEAD_GET_TAG;
pub const EVP_CTRL_GCM_SET_TAG = EVP_CTRL_AEAD_SET_TAG;
pub const RSA_PKCS1_PADDING = @as(c_int, 1);
pub const RSA_NO_PADDING = @as(c_int, 3);
pub const RSA_PKCS1_OAEP_PADDING = @as(c_int, 4);
pub inline fn EVP_RSA_gen(bits: anytype) @TypeOf(EVP_PKEY_Q_keygen(NULL, NULL, "RSA", @import("std").zig.c_translation.helpers.cast(usize, @as(c_int, 0) + bits))) {
    _ = &bits;
    return EVP_PKEY_Q_keygen(NULL, NULL, "RSA", @import("std").zig.c_translation.helpers.cast(usize, @as(c_int, 0) + bits));
}
pub const SHA256_DIGEST_LENGTH = @as(c_int, 32);
pub inline fn sk_X509_EXTENSION_pop_free(sk: anytype, freefunc: anytype) @TypeOf(OPENSSL_sk_pop_free(ossl_check_X509_EXTENSION_sk_type(sk), ossl_check_X509_EXTENSION_freefunc_type(freefunc))) {
    _ = &sk;
    _ = &freefunc;
    return OPENSSL_sk_pop_free(ossl_check_X509_EXTENSION_sk_type(sk), ossl_check_X509_EXTENSION_freefunc_type(freefunc));
}
pub const X509_get_notAfter = X509_getm_notAfter;
pub const GEN_DNS = @as(c_int, 2);
pub inline fn sk_GENERAL_NAME_num(sk: anytype) @TypeOf(OPENSSL_sk_num(ossl_check_const_GENERAL_NAME_sk_type(sk))) {
    _ = &sk;
    return OPENSSL_sk_num(ossl_check_const_GENERAL_NAME_sk_type(sk));
}
pub inline fn sk_GENERAL_NAME_value(sk: anytype, idx: anytype) [*c]GENERAL_NAME {
    _ = &sk;
    _ = &idx;
    return @import("std").zig.c_translation.helpers.cast([*c]GENERAL_NAME, OPENSSL_sk_value(ossl_check_const_GENERAL_NAME_sk_type(sk), idx));
}
pub const NGX_SSL_TLSv1_2 = @as(c_int, 0x0020);
pub const NGX_SSL_TLSv1_3 = @as(c_int, 0x0040);
pub const NGX_SSL_DEFAULT_PROTOCOLS = NGX_SSL_TLSv1_2 | NGX_SSL_TLSv1_3;
pub const NGX_CONF_NOARGS = @as(c_int, 0x00000001);
pub const NGX_CONF_TAKE1 = @as(c_int, 0x00000002);
pub const NGX_CONF_TAKE2 = @as(c_int, 0x00000004);
pub const NGX_CONF_TAKE3 = @as(c_int, 0x00000008);
pub const NGX_CONF_TAKE4 = @as(c_int, 0x00000010);
pub const NGX_CONF_TAKE5 = @as(c_int, 0x00000020);
pub const NGX_CONF_TAKE6 = @as(c_int, 0x00000040);
pub const NGX_CONF_TAKE7 = @as(c_int, 0x00000080);
pub const NGX_CONF_TAKE12 = NGX_CONF_TAKE1 | NGX_CONF_TAKE2;
pub const NGX_CONF_TAKE13 = NGX_CONF_TAKE1 | NGX_CONF_TAKE3;
pub const NGX_CONF_TAKE23 = NGX_CONF_TAKE2 | NGX_CONF_TAKE3;
pub const NGX_CONF_TAKE123 = (NGX_CONF_TAKE1 | NGX_CONF_TAKE2) | NGX_CONF_TAKE3;
pub const NGX_CONF_TAKE1234 = ((NGX_CONF_TAKE1 | NGX_CONF_TAKE2) | NGX_CONF_TAKE3) | NGX_CONF_TAKE4;
pub const NGX_CONF_BLOCK = @as(c_int, 0x00000100);
pub const NGX_CONF_FLAG = @as(c_int, 0x00000200);
pub const NGX_CONF_ANY = @as(c_int, 0x00000400);
pub const NGX_CONF_1MORE = @as(c_int, 0x00000800);
pub const NGX_CONF_2MORE = @as(c_int, 0x00001000);
pub const NGX_CONF_UNSET = -@as(c_int, 1);
pub const NGX_CONF_UNSET_UINT = @import("std").zig.c_translation.helpers.cast(ngx_uint_t, -@as(c_int, 1));
pub const NGX_CONF_UNSET_PTR = @import("std").zig.c_translation.helpers.cast(?*anyopaque, -@as(c_int, 1));
pub const NGX_CONF_UNSET_SIZE = @import("std").zig.c_translation.helpers.cast(usize, -@as(c_int, 1));
pub const NGX_CONF_UNSET_MSEC = @import("std").zig.c_translation.helpers.cast(ngx_msec_t, -@as(c_int, 1));
pub const NGX_CONF_OK = NULL;
pub const NGX_CONF_ERROR = @import("std").zig.c_translation.helpers.cast(?*anyopaque, -@as(c_int, 1));
pub const NGX_HTTP_VAR_CHANGEABLE = @as(c_int, 1);
pub const NGX_HTTP_VAR_NOCACHEABLE = @as(c_int, 2);
pub const NGX_HTTP_VAR_INDEXED = @as(c_int, 4);
pub const NGX_HTTP_VAR_NOHASH = @as(c_int, 8);
pub const NGX_HTTP_VAR_WEAK = @as(c_int, 16);
pub const NGX_HTTP_VAR_PREFIX = @as(c_int, 32);
pub const NGX_HTTP_MODULE = @import("std").zig.c_translation.helpers.promoteIntLiteral(c_int, 0x50545448, .hex);
pub const NGX_HTTP_MAIN_CONF = @import("std").zig.c_translation.helpers.promoteIntLiteral(c_int, 0x02000000, .hex);
pub const NGX_HTTP_SRV_CONF = @import("std").zig.c_translation.helpers.promoteIntLiteral(c_int, 0x04000000, .hex);
pub const NGX_HTTP_LOC_CONF = @import("std").zig.c_translation.helpers.promoteIntLiteral(c_int, 0x08000000, .hex);
pub const NGX_HTTP_UPS_CONF = @import("std").zig.c_translation.helpers.promoteIntLiteral(c_int, 0x10000000, .hex);
pub const NGX_HTTP_GET = @as(c_int, 0x00000002);
pub const NGX_HTTP_HEAD = @as(c_int, 0x00000004);
pub const NGX_HTTP_POST = @as(c_int, 0x00000008);
pub const NGX_HTTP_PUT = @as(c_int, 0x00000010);
pub const NGX_HTTP_DELETE = @as(c_int, 0x00000020);
pub const NGX_HTTP_PATCH = @as(c_int, 0x00004000);
pub const NGX_HTTP_PARSE_HEADER_DONE = @as(c_int, 1);
pub const NGX_HTTP_PARSE_INVALID_HEADER = @as(c_int, 14);
pub const NGX_HTTP_OK = @as(c_int, 200);
pub const NGX_HTTP_ACCEPTED = @as(c_int, 202);
pub const NGX_HTTP_NO_CONTENT = @as(c_int, 204);
pub const NGX_HTTP_SPECIAL_RESPONSE = @as(c_int, 300);
pub const NGX_HTTP_BAD_REQUEST = @as(c_int, 400);
pub const NGX_HTTP_UNAUTHORIZED = @as(c_int, 401);
pub const NGX_HTTP_FORBIDDEN = @as(c_int, 403);
pub const NGX_HTTP_NOT_FOUND = @as(c_int, 404);
pub const NGX_HTTP_NOT_ALLOWED = @as(c_int, 405);
pub const NGX_HTTP_INTERNAL_SERVER_ERROR = @as(c_int, 500);
pub const NGX_HTTP_BAD_GATEWAY = @as(c_int, 502);
pub const NGX_HTTP_SERVICE_UNAVAILABLE = @as(c_int, 503);
pub const NGX_TIMER_LAZY_DELAY = @as(c_int, 300);
pub const NGX_HTTP_UPSTREAM_INVALID_HEADER = @as(c_int, 40);
pub const NGX_HTTP_LAST = @as(c_int, 1);
pub const NGX_HTTP_FLUSH = @as(c_int, 2);
pub const passwd = struct_passwd;
pub const sockaddr = struct_sockaddr;
pub const sockaddr_in = struct_sockaddr_in;
pub const sockaddr_in6 = struct_sockaddr_in6;
pub const sockaddr_un = struct_sockaddr_un;
