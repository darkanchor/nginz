const std = @import("std");
const ngx = @import("ngx");

const core = ngx.core;
const conf = ngx.conf;
const http = ngx.http;
const shm = ngx.shm;

const NGX_OK = core.NGX_OK;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;

const ngx_str_t = core.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_msec_t = core.ngx_msec_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;
const ngx_http_handler_pt = http.ngx_http_handler_pt;
const ngx_http_core_main_conf_t = http.ngx_http_core_main_conf_t;
const ngx_http_variable_value_t = http.ngx_http_variable_value_t;
const ngx_array_t = ngx.array.ngx_array_t;

const ngx_string = ngx.string.ngx_string;
const ngx_null_str = ngx.string.ngx_null_str;
const concat_string_from_pool = ngx.string.concat_string_from_pool;
const NArray = ngx.array.NArray;

extern var ngx_http_core_module: ngx_module_t;
extern var ngx_current_msec: ngx_msec_t;

// TODO: nftset_ratelimit — shared-worker per-IP rate window with optional autoban to a named set

// ──────────────────────────────────────────────────────────────────────────
// Linux socket / Netlink / nftables kernel ABI constants
// ──────────────────────────────────────────────────────────────────────────

// Client IP address family (stable Linux kernel ABI)
const AF_INET: u16 = 2;
const AF_INET6: u16 = 10;

// Netlink socket constants
const AF_NETLINK_SOCK: c_int = 16;
const SOCK_RAW_C: c_int = 3;
const NETLINK_NETFILTER_PROT: c_int = 12;
const SOL_SOCKET_C: c_int = 1;
const SO_RCVTIMEO_C: c_int = 20;
// Netlink runs synchronously in the access phase. Keep each receive bounded to
// a single-digit worker-latency budget; a confirmed miss may require two
// exchanges (GETSETELEM followed by GETSET), so worst-case lookup blocking is
// bounded to roughly twice this value.
const NFTSET_NETLINK_RECV_BUDGET_US: i64 = 10_000;

// nftables Netlink subsystem and message types
const NFNL_SUBSYS_NFTABLES: u16 = 10;
const NFT_MSG_NEWSET: u16 = 9; // response: set found
const NFT_MSG_GETSET: u16 = 10; // request: get set metadata
const NFT_MSG_GETSETELEM: u16 = 13; // request: get set element(s)
const NFT_MSG_NEWSETELEM: u16 = 12; // response: element found
const NLMSG_ERROR_TYPE: u16 = 2; // standard Netlink error / ACK
const NLMSG_DONE_TYPE: u16 = 3;

// Netlink message flags
const NLM_F_REQUEST: u16 = 0x01;
const NLM_F_ACK: u16 = 0x04;
const NLM_F_CREATE: u16 = 0x400;
const NFNL_MSG_BATCH_BEGIN: u16 = 16;
const NFNL_MSG_BATCH_END: u16 = 17;

// nftables protocol families (nfgenmsg.nfgen_family)
const NFNETLINK_V0: u8 = 0;
const NFPROTO_INET: u8 = 1; // dual-stack inet table
const NFPROTO_IPV4: u8 = 2;
const NFPROTO_IPV6: u8 = 10;

// nftables set-element attribute types
const NLA_F_NESTED: u16 = 0x8000; // kernel flag: attribute contains nested attrs
const NFTA_SET_ELEM_LIST_TABLE: u16 = 1;
const NFTA_SET_ELEM_LIST_SET: u16 = 2;
const NFTA_SET_ELEM_LIST_ELEMENTS: u16 = 3;
const NFTA_SET_TABLE: u16 = 1;
const NFTA_SET_NAME: u16 = 2;
const NFTA_LIST_ELEM: u16 = 1; // one element in the list
const NFTA_SET_ELEM_KEY: u16 = 1; // key nested under NFTA_LIST_ELEM
const NFTA_SET_ELEM_TIMEOUT: u16 = 4;
const NFTA_DATA_VALUE: u16 = 1; // raw bytes under NFTA_SET_ELEM_KEY

// Fixed sizes matching Linux kernel ABI
const NLMSG_HDR_SZ: usize = 16; // sizeof(struct nlmsghdr)
const NFGENMSG_SZ: usize = 4; // sizeof(struct nfgenmsg)
const NLATTR_HDR_SZ: usize = 4; // sizeof(struct nlattr)

// ──────────────────────────────────────────────────────────────────────────
// Kernel ABI structs
// ──────────────────────────────────────────────────────────────────────────

const Nlmsghdr = extern struct {
    len: u32,
    type_: u16,
    flags: u16,
    seq: u32,
    pid: u32,
};

const Nfgenmsg = extern struct {
    family: u8,
    version: u8,
    res_id: u16, // big-endian; 0 for unicast
};

const Nlattr = extern struct {
    len: u16,
    type_: u16,
};

const SockaddrNl = extern struct {
    family: u16,
    pad: u16,
    pid: u32,
    groups: u32,
};

const Timeval = extern struct {
    tv_sec: c_long,
    tv_usec: c_long,
};

fn writeStruct(buf: []u8, pos: usize, value: anytype) void {
    const bytes = std.mem.asBytes(&value);
    @memcpy(buf[pos .. pos + bytes.len], bytes);
}

fn readStruct(comptime T: type, buf: []const u8, pos: usize) T {
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), buf[pos .. pos + @sizeOf(T)]);
    return value;
}

// Minimal sockaddr_in layout (IPv4 — size must match Linux kernel ABI)
const Sockaddr4 = extern struct {
    family: u16,
    port: u16,
    addr: u32, // network byte order IPv4 address
    zero: [8]u8,
};

// Minimal sockaddr_in6 layout (IPv6 — used for both native and IPv4-mapped)
const Sockaddr6 = extern struct {
    family: u16,
    port: u16,
    flowinfo: u32,
    addr: [16]u8, // sin6_addr as flat byte array
    scope_id: u32,
};

// ──────────────────────────────────────────────────────────────────────────
// C runtime function declarations
// ──────────────────────────────────────────────────────────────────────────

extern fn socket(domain: c_int, type_: c_int, protocol: c_int) c_int;
extern fn bind(fd: c_int, addr: *const anyopaque, addrlen: u32) c_int;
extern fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: u32) c_int;
extern fn send(fd: c_int, buf: *const anyopaque, len: usize, flags: c_int) isize;
extern fn sendto(fd: c_int, buf: *const anyopaque, len: usize, flags: c_int, dest_addr: *const anyopaque, addrlen: u32) isize;
extern fn recv(fd: c_int, buf: *anyopaque, len: usize, flags: c_int) isize;
extern fn close(fd: c_int) c_int;

// ──────────────────────────────────────────────────────────────────────────
// Per-worker Netlink socket state (each worker gets its own after fork)
// ──────────────────────────────────────────────────────────────────────────

var netlink_fd: c_int = -1;
var netlink_seq: u32 = 0;

const NFTSET_CACHE_SIZE: usize = 128;
const NFTSET_CACHE_KEY_MAX: usize = 512;
const NFTSET_SHARED_CACHE_SIZE: usize = 256;
const NFTSET_SHARED_CACHE_ZONE_SIZE: usize = 256 * 1024;
const NFTSET_RATELIMIT_MAX_ENTRIES: usize = 1024;
const NFTSET_RATELIMIT_STATUS: ngx_int_t = 429;
const NFTSET_RATELIMIT_ZONE_SIZE: usize = 128 * 1024;

const CacheMembership = enum(u8) {
    in_set,
    not_in_set,
};

const CacheLookup = union(enum) {
    hit: CacheMembership,
    miss,
};

const CacheEntry = struct {
    valid: bool,
    key_len: u16,
    key: [NFTSET_CACHE_KEY_MAX]u8,
    membership: CacheMembership,
    expires_at: ngx_msec_t,
    last_used_at: ngx_msec_t,
};

var nftset_cache = std.mem.zeroes([NFTSET_CACHE_SIZE]CacheEntry);
var nftset_cache_generation_seen: u64 = 0;

const SharedCacheEntry = extern struct {
    key_hash: u64,
    key_len: u16,
    membership: CacheMembership,
    expires_at: ngx_msec_t,
    last_used_at: ngx_msec_t,
    key: [NFTSET_CACHE_KEY_MAX]u8,
};

const nftset_lookup_cache_store = extern struct {
    initialized: ngx_flag_t,
    generation: u64,
    entry_count: ngx_uint_t,
    entries: [NFTSET_SHARED_CACHE_SIZE]SharedCacheEntry,
};

const RateLimitEntry = extern struct {
    key: u64,
    count: u32,
    window_start_ms: u64,
    last_used_ms: u64,
};

const nftset_ratelimit_store = extern struct {
    initialized: ngx_flag_t,
    entry_count: ngx_uint_t,
    entries: [NFTSET_RATELIMIT_MAX_ENTRIES]RateLimitEntry,
};

var ngx_http_nftset_ratelimit_zone: [*c]core.ngx_shm_zone_t = core.nullptr(core.ngx_shm_zone_t);
var ngx_http_nftset_lookup_cache_zone: [*c]core.ngx_shm_zone_t = core.nullptr(core.ngx_shm_zone_t);

const nftset_spec = extern struct {
    table: ngx_str_t,
    set: ngx_str_t,
};

// ──────────────────────────────────────────────────────────────────────────
// Netlink message construction helpers
// ──────────────────────────────────────────────────────────────────────────

fn nla_align(len: usize) usize {
    return (len + 3) & ~@as(usize, 3);
}

fn ensureSpace(buf_len: usize, pos: usize, need: usize) bool {
    return pos <= buf_len and need <= buf_len - pos;
}

// Write a null-terminated string as a netlink attribute. Returns new pos.
fn put_nla_str(buf: []u8, pos: usize, nla_type: u16, s: []const u8) usize {
    const payload = s.len + 1;
    const total: u16 = @intCast(NLATTR_HDR_SZ + payload);
    const aligned = nla_align(total);
    @memset(buf[pos .. pos + aligned], 0);
    writeStruct(buf, pos, Nlattr{ .len = total, .type_ = nla_type });
    @memcpy(buf[pos + NLATTR_HDR_SZ .. pos + NLATTR_HDR_SZ + s.len], s);
    return pos + aligned;
}

// Write raw bytes as a netlink attribute. Returns new pos.
fn put_nla_raw(buf: []u8, pos: usize, nla_type: u16, data: []const u8) usize {
    const total: u16 = @intCast(NLATTR_HDR_SZ + data.len);
    const aligned = nla_align(total);
    @memset(buf[pos .. pos + aligned], 0);
    writeStruct(buf, pos, Nlattr{ .len = total, .type_ = nla_type });
    @memcpy(buf[pos + NLATTR_HDR_SZ .. pos + NLATTR_HDR_SZ + data.len], data);
    return pos + aligned;
}

fn put_nla_u64_be(buf: []u8, pos: usize, nla_type: u16, value: u64) usize {
    const total: u16 = @intCast(NLATTR_HDR_SZ + @sizeOf(u64));
    const aligned = nla_align(total);
    @memset(buf[pos .. pos + aligned], 0);
    writeStruct(buf, pos, Nlattr{ .len = total, .type_ = nla_type });
    const be_value = std.mem.nativeToBig(u64, value);
    writeStruct(buf, pos + NLATTR_HDR_SZ, be_value);
    return pos + aligned;
}

// Begin a nested attribute. Returns the position of the content (after header).
// Caller must remember `pos` (before this call) as `header_pos` for nla_nest_end.
fn nla_nest_start(buf: []u8, pos: usize, nla_type: u16) usize {
    writeStruct(buf, pos, Nlattr{ .len = 0, .type_ = nla_type | NLA_F_NESTED });
    return pos + NLATTR_HDR_SZ;
}

// Finish a nested attribute: write the total length into the header.
fn nla_nest_end(buf: []u8, header_pos: usize, content_end: usize) void {
    const h = readStruct(Nlattr, buf, header_pos);
    writeStruct(buf, header_pos, Nlattr{ .len = @intCast(content_end - header_pos), .type_ = h.type_ });
}

// Build a NFT_MSG_GETSETELEM query into buf[0..512].
// Returns the total message length.
fn build_query(
    buf: *[512]u8,
    seq: u32,
    table_fam: u8,
    table: []const u8,
    set_name: []const u8,
    ip_bytes: []const u8,
) ?usize {
    @memset(buf, 0);
    var pos: usize = 0;

    // nlmsghdr — filled in at end once we know total length
    if (!ensureSpace(buf.len, pos, NLMSG_HDR_SZ)) return null;
    pos += NLMSG_HDR_SZ;

    // nfgenmsg: table protocol family, nfnetlink v0, res_id=0
    if (!ensureSpace(buf.len, pos, NFGENMSG_SZ)) return null;
    writeStruct(buf, pos, Nfgenmsg{ .family = table_fam, .version = NFNETLINK_V0, .res_id = 0 });
    pos += NFGENMSG_SZ;

    // NFTA_SET_ELEM_LIST_SET: set name
    if (!ensureSpace(buf.len, pos, nla_align(NLATTR_HDR_SZ + set_name.len + 1))) return null;
    pos = put_nla_str(buf, pos, NFTA_SET_ELEM_LIST_SET, set_name);

    // NFTA_SET_ELEM_LIST_TABLE: table name
    if (!ensureSpace(buf.len, pos, nla_align(NLATTR_HDR_SZ + table.len + 1))) return null;
    pos = put_nla_str(buf, pos, NFTA_SET_ELEM_LIST_TABLE, table);

    // NFTA_SET_ELEM_LIST_ELEMENTS (nested)
    //   └─ NFTA_LIST_ELEM (nested)
    //       └─ NFTA_SET_ELEM_KEY (nested)
    //           └─ NFTA_DATA_VALUE: raw IP bytes
    const nested_need = (NLATTR_HDR_SZ * 4) + nla_align(NLATTR_HDR_SZ + ip_bytes.len);
    if (!ensureSpace(buf.len, pos, nested_need)) return null;
    const elements_hdr = pos;
    pos = nla_nest_start(buf, pos, NFTA_SET_ELEM_LIST_ELEMENTS);
    const list_elem_hdr = pos;
    pos = nla_nest_start(buf, pos, NFTA_LIST_ELEM);
    const key_hdr = pos;
    pos = nla_nest_start(buf, pos, NFTA_SET_ELEM_KEY);
    pos = put_nla_raw(buf, pos, NFTA_DATA_VALUE, ip_bytes);
    nla_nest_end(buf, key_hdr, pos);
    nla_nest_end(buf, list_elem_hdr, pos);
    nla_nest_end(buf, elements_hdr, pos);

    // Fill in nlmsghdr now that total length is known
    writeStruct(buf, 0, Nlmsghdr{
        .len = @intCast(pos),
        .type_ = (NFNL_SUBSYS_NFTABLES << 8) | NFT_MSG_GETSETELEM,
        .flags = NLM_F_REQUEST | NLM_F_ACK,
        .seq = seq,
        .pid = 0,
    });

    return pos;
}

fn build_getset_query(
    buf: *[256]u8,
    seq: u32,
    table_fam: u8,
    table: []const u8,
    set_name: []const u8,
) ?usize {
    @memset(buf, 0);
    var pos: usize = 0;

    if (!ensureSpace(buf.len, pos, NLMSG_HDR_SZ)) return null;
    pos += NLMSG_HDR_SZ;

    if (!ensureSpace(buf.len, pos, NFGENMSG_SZ)) return null;
    writeStruct(buf, pos, Nfgenmsg{ .family = table_fam, .version = NFNETLINK_V0, .res_id = 0 });
    pos += NFGENMSG_SZ;

    if (!ensureSpace(buf.len, pos, nla_align(NLATTR_HDR_SZ + table.len + 1))) return null;
    pos = put_nla_str(buf, pos, NFTA_SET_TABLE, table);

    if (!ensureSpace(buf.len, pos, nla_align(NLATTR_HDR_SZ + set_name.len + 1))) return null;
    pos = put_nla_str(buf, pos, NFTA_SET_NAME, set_name);

    writeStruct(buf, 0, Nlmsghdr{
        .len = @intCast(pos),
        .type_ = (NFNL_SUBSYS_NFTABLES << 8) | NFT_MSG_GETSET,
        .flags = NLM_F_REQUEST | NLM_F_ACK,
        .seq = seq,
        .pid = 0,
    });

    return pos;
}

fn build_add_query(
    buf: *[512]u8,
    seq: u32,
    table_fam: u8,
    table: []const u8,
    set_name: []const u8,
    ip_bytes: []const u8,
    timeout_ms: ngx_msec_t,
) ?usize {
    @memset(buf, 0);
    var pos: usize = 0;

    if (!ensureSpace(buf.len, pos, NLMSG_HDR_SZ)) return null;
    pos += NLMSG_HDR_SZ;

    if (!ensureSpace(buf.len, pos, NFGENMSG_SZ)) return null;
    writeStruct(buf, pos, Nfgenmsg{ .family = table_fam, .version = NFNETLINK_V0, .res_id = 0 });
    pos += NFGENMSG_SZ;

    if (!ensureSpace(buf.len, pos, nla_align(NLATTR_HDR_SZ + table.len + 1))) return null;
    pos = put_nla_str(buf, pos, NFTA_SET_ELEM_LIST_TABLE, table);

    if (!ensureSpace(buf.len, pos, nla_align(NLATTR_HDR_SZ + set_name.len + 1))) return null;
    pos = put_nla_str(buf, pos, NFTA_SET_ELEM_LIST_SET, set_name);

    const timeout_need: usize = if (timeout_ms > 0) nla_align(NLATTR_HDR_SZ + @sizeOf(u64)) else 0;
    const nested_need = (NLATTR_HDR_SZ * 3) + nla_align(NLATTR_HDR_SZ + ip_bytes.len) + timeout_need;
    if (!ensureSpace(buf.len, pos, nested_need)) return null;

    const elements_hdr = pos;
    pos = nla_nest_start(buf, pos, NFTA_SET_ELEM_LIST_ELEMENTS);
    const list_elem_hdr = pos;
    pos = nla_nest_start(buf, pos, NFTA_LIST_ELEM);
    const key_hdr = pos;
    pos = nla_nest_start(buf, pos, NFTA_SET_ELEM_KEY);
    pos = put_nla_raw(buf, pos, NFTA_DATA_VALUE, ip_bytes);
    nla_nest_end(buf, key_hdr, pos);
    if (timeout_ms > 0) {
        pos = put_nla_u64_be(buf, pos, NFTA_SET_ELEM_TIMEOUT, timeout_ms);
    }
    nla_nest_end(buf, list_elem_hdr, pos);
    nla_nest_end(buf, elements_hdr, pos);

    writeStruct(buf, 0, Nlmsghdr{
        .len = @intCast(pos),
        .type_ = (NFNL_SUBSYS_NFTABLES << 8) | NFT_MSG_NEWSETELEM,
        .flags = NLM_F_REQUEST | NLM_F_CREATE | NLM_F_ACK,
        .seq = seq,
        .pid = 0,
    });

    return pos;
}

fn build_batch_marker(
    buf: *[20]u8,
    seq: u32,
    msg_type: u16,
) usize {
    @memset(buf, 0);
    writeStruct(buf, 0, Nlmsghdr{
        .len = @intCast(NLMSG_HDR_SZ + NFGENMSG_SZ),
        .type_ = msg_type,
        .flags = NLM_F_REQUEST,
        .seq = seq,
        .pid = 0,
    });
    writeStruct(buf, NLMSG_HDR_SZ, Nfgenmsg{
        .family = 0,
        .version = 0,
        .res_id = std.mem.nativeToBig(u16, NFNL_SUBSYS_NFTABLES),
    });
    return NLMSG_HDR_SZ + NFGENMSG_SZ;
}

// ──────────────────────────────────────────────────────────────────────────
// IP address family helpers
// ──────────────────────────────────────────────────────────────────────────

// Detect the element IP family from the client connection.
// Returns "ip" for IPv4 (and IPv4-mapped IPv6), "ip6" for native IPv6.
fn detect_client_family(r: [*c]ngx_http_request_t) ngx_str_t {
    const sa = r.*.connection.*.sockaddr orelse return ngx_string("ip");
    if (sa.*.sa_family != AF_INET6) return ngx_string("ip");

    // Check for IPv4-mapped ::ffff:a.b.c.d
    // Layout: 10 zero bytes, 0xFF, 0xFF, then 4 IPv4 bytes
    const sa6: *Sockaddr6 = @ptrCast(@alignCast(sa));
    const a = sa6.*.addr;
    const is_mapped = a[0] == 0 and a[1] == 0 and a[2] == 0 and a[3] == 0 and
        a[4] == 0 and a[5] == 0 and a[6] == 0 and a[7] == 0 and
        a[8] == 0 and a[9] == 0 and a[10] == 0xFF and a[11] == 0xFF;
    return if (is_mapped) ngx_string("ip") else ngx_string("ip6");
}

// Map a configured family string to the nfgenmsg protocol family byte.
fn table_family_num(family_str: []const u8) u8 {
    if (std.mem.eql(u8, family_str, "ip")) return NFPROTO_IPV4;
    if (std.mem.eql(u8, family_str, "ip6")) return NFPROTO_IPV6;
    return NFPROTO_INET; // "inet" or any unknown value defaults to dual-stack
}

// Extract binary IP bytes from the request's remote address.
// is_ipv6=false → 4 bytes (IPv4 network byte order)
// is_ipv6=true  → 16 bytes (IPv6 network byte order)
// Returns null if the sockaddr type does not match the requested family.
fn get_client_ip_bytes(
    r: [*c]ngx_http_request_t,
    is_ipv6: bool,
    buf: *[16]u8,
) ?[]const u8 {
    const sa = r.*.connection.*.sockaddr orelse return null;
    const sa_fam: u16 = @intCast(sa.*.sa_family);

    if (!is_ipv6) {
        if (sa_fam == AF_INET) {
            const sa4: *const Sockaddr4 = @ptrCast(@alignCast(sa));
            // nft get element emits IPv4 keys as 7f 00 00 01 for 127.0.0.1.
            // Copy the sockaddr bytes as-is to match that request encoding.
            const addr_bytes: *const [4]u8 = @ptrCast(&sa4.*.addr);
            @memcpy(buf[0..4], addr_bytes);
            return buf[0..4];
        }
        if (sa_fam == AF_INET6) {
            // IPv4-mapped ::ffff:a.b.c.d — last 4 bytes are the IPv4 address
            const sa6: *const Sockaddr6 = @ptrCast(@alignCast(sa));
            @memcpy(buf[0..4], sa6.*.addr[12..16]);
            return buf[0..4];
        }
        return null;
    } else {
        if (sa_fam != AF_INET6) return null;
        const sa6: *const Sockaddr6 = @ptrCast(@alignCast(sa));
        @memcpy(buf[0..16], &sa6.*.addr);
        return buf[0..16];
    }
}

// Read a host-endian i32 from an unaligned byte slice.
fn read_i32_native(buf: []const u8, off: usize) i32 {
    return readStruct(i32, buf, off);
}

fn fnv1a64(seed: u64, bytes: []const u8) u64 {
    var hash = seed;
    for (bytes) |b| {
        hash ^= b;
        hash *%= 1099511628211;
    }
    return hash;
}

fn currentWindowMs() u64 {
    return @intCast(ngx_current_msec);
}

fn buildRateLimitKey(scope: []const u8, table_fam: u8, ip_bytes: []const u8) u64 {
    var hash: u64 = 1469598103934665603;
    hash = fnv1a64(hash, scope);
    hash = fnv1a64(hash, &[_]u8{table_fam});
    hash = fnv1a64(hash, ip_bytes);
    return if (hash == 0) 1 else hash;
}

fn getRateLimitStore() ?[*c]nftset_ratelimit_store {
    if (ngx_http_nftset_ratelimit_zone == core.nullptr(core.ngx_shm_zone_t)) return null;
    return core.castPtr(nftset_ratelimit_store, ngx_http_nftset_ratelimit_zone.*.data);
}

fn getLookupCacheStore() ?[*c]nftset_lookup_cache_store {
    if (ngx_http_nftset_lookup_cache_zone == core.nullptr(core.ngx_shm_zone_t)) return null;
    return core.castPtr(nftset_lookup_cache_store, ngx_http_nftset_lookup_cache_zone.*.data);
}

fn getLookupCacheShpool() ?[*c]core.ngx_slab_pool_t {
    const zone = ngx_http_nftset_lookup_cache_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.shm.addr == null or zone.*.data == null) {
        return null;
    }
    return core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr);
}

fn getRateLimitShpool() ?[*c]core.ngx_slab_pool_t {
    const zone = ngx_http_nftset_ratelimit_zone;
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.shm.addr == null or zone.*.data == null) {
        return null;
    }
    return core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr);
}

fn ngx_http_nftset_ratelimit_zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        zone.*.data = data;
        return NGX_OK;
    }

    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        zone.*.data = shpool.*.data;
        return NGX_OK;
    }

    const store_mem = shm.ngx_slab_calloc(shpool, @sizeOf(nftset_ratelimit_store)) orelse return NGX_ERROR;
    const store = core.castPtr(nftset_ratelimit_store, store_mem) orelse return NGX_ERROR;
    store.* = std.mem.zeroes(nftset_ratelimit_store);
    store.*.initialized = 1;
    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

fn ngx_http_nftset_lookup_cache_zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        zone.*.data = data;
        return NGX_OK;
    }

    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        zone.*.data = shpool.*.data;
        return NGX_OK;
    }

    const store_mem = shm.ngx_slab_calloc(shpool, @sizeOf(nftset_lookup_cache_store)) orelse return NGX_ERROR;
    const store = core.castPtr(nftset_lookup_cache_store, store_mem) orelse return NGX_ERROR;
    store.* = std.mem.zeroes(nftset_lookup_cache_store);
    store.*.initialized = 1;
    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

fn rateLimitWindowExpired(window_start_ms: u64, current_ms: u64) bool {
    return current_ms < window_start_ms or current_ms - window_start_ms >= 1000;
}

fn getOrCreateRateLimitEntry(store: *nftset_ratelimit_store, rate_key: u64, current_ms: u64) *RateLimitEntry {
    var empty_slot: ?*RateLimitEntry = null;
    var reusable_slot: ?*RateLimitEntry = null;
    var oldest_slot: ?*RateLimitEntry = null;

    for (&store.entries) |*entry| {
        if (entry.key == 0) {
            if (empty_slot == null) empty_slot = entry;
            continue;
        }
        if (entry.key == rate_key) return entry;
        if (rateLimitWindowExpired(entry.window_start_ms, current_ms) and reusable_slot == null) reusable_slot = entry;
        if (oldest_slot == null or entry.last_used_ms < oldest_slot.?.last_used_ms) oldest_slot = entry;
    }

    const slot = empty_slot orelse reusable_slot orelse oldest_slot orelse unreachable;
    if (slot.key == 0) store.entry_count += 1;
    slot.* = .{
        .key = rate_key,
        .count = 0,
        .window_start_ms = current_ms,
        .last_used_ms = current_ms,
    };
    return slot;
}

fn checkRateLimit(store: *nftset_ratelimit_store, rate_key: u64, rate: ngx_uint_t, burst: ngx_uint_t) bool {
    const current_ms = currentWindowMs();
    const entry = getOrCreateRateLimitEntry(store, rate_key, current_ms);

    if (rateLimitWindowExpired(entry.window_start_ms, current_ms)) {
        entry.window_start_ms = current_ms;
        entry.count = 0;
    }

    entry.last_used_ms = current_ms;
    const limit = @as(u64, @intCast(rate)) + @as(u64, @intCast(burst));
    if (@as(u64, entry.count) < limit) {
        entry.count += 1;
        return true;
    }

    return false;
}

fn initRateLimitScope(cf: [*c]ngx_conf_t, lcf: *nftset_loc_conf) [*c]u8 {
    const clcf = core.castPtr(
        http.ngx_http_core_loc_conf_t,
        conf.ngx_http_conf_get_module_loc_conf(cf, &ngx_http_core_module),
    ) orelse return conf.NGX_CONF_ERROR;
    const cscf = core.castPtr(
        http.ngx_http_core_srv_conf_t,
        conf.ngx_http_conf_get_module_srv_conf(cf, &ngx_http_core_module),
    ) orelse return conf.NGX_CONF_ERROR;

    const server_name = if (cscf.*.server_name.len > 0 and cscf.*.server_name.data != null)
        core.slicify(u8, cscf.*.server_name.data, cscf.*.server_name.len)
    else
        "_";
    const location_name = if (clcf.*.name.len > 0 and clcf.*.name.data != null)
        core.slicify(u8, clcf.*.name.data, clcf.*.name.len)
    else
        "/";

    const buf_len = server_name.len + location_name.len + 2;
    const scope_buf = core.castPtr(u8, core.ngx_pnalloc(cf.*.pool, buf_len)) orelse return conf.NGX_CONF_ERROR;
    const scope_slice = core.slicify(u8, scope_buf, buf_len);
    const rendered = std.fmt.bufPrint(scope_slice, "{s}|{s}", .{ server_name, location_name }) catch return conf.NGX_CONF_ERROR;
    lcf.*.ratelimit_scope = ngx_str_t{ .data = scope_buf, .len = rendered.len };
    return conf.NGX_CONF_OK;
}

fn parseRateLimitRate(value: []const u8) ?ngx_uint_t {
    if (value.len == 0) return null;
    if (std.mem.endsWith(u8, value, "r/s")) {
        if (value.len <= 3) return null;
        return std.fmt.parseInt(ngx_uint_t, value[0 .. value.len - 3], 10) catch null;
    }
    return std.fmt.parseInt(ngx_uint_t, value, 10) catch null;
}

// ──────────────────────────────────────────────────────────────────────────
// nftables kernel lookup via raw Netlink (NFT_MSG_GETSETELEM)
// ──────────────────────────────────────────────────────────────────────────

const LookupResult = union(enum) {
    in_set,
    not_in_set,
    lookup_error: i32,
};

const AutoaddResult = union(enum) {
    added,
    exists,
    add_error: i32,
};

const LookupOutcome = struct {
    lookup: LookupResult,
    matched_set: ngx_str_t,
};

const SetExistenceProbe = enum(u8) {
    exists,
    missing,
    unknown,
};

fn cacheMembershipToLookup(membership: CacheMembership) LookupResult {
    return switch (membership) {
        .in_set => .in_set,
        .not_in_set => .not_in_set,
    };
}

fn lookupToCacheMembership(lookup: LookupResult) ?CacheMembership {
    return switch (lookup) {
        .in_set => .in_set,
        .not_in_set => .not_in_set,
        .lookup_error => null,
    };
}

fn appendKeyPart(dst: []u8, pos: *usize, part: []const u8) bool {
    if (part.len > std.math.maxInt(u8)) return false;
    if (!ensureSpace(dst.len, pos.*, 1 + part.len)) return false;
    dst[pos.*] = @intCast(part.len);
    pos.* += 1;
    @memcpy(dst[pos.* .. pos.* + part.len], part);
    pos.* += part.len;
    return true;
}

fn buildCacheKey(
    key_buf: *[NFTSET_CACHE_KEY_MAX]u8,
    table: []const u8,
    set_name: []const u8,
    table_fam: u8,
    ip_bytes: []const u8,
) ?[]const u8 {
    var pos: usize = 0;
    if (!ensureSpace(key_buf.len, pos, 2)) return null;
    key_buf[pos] = table_fam;
    pos += 1;
    key_buf[pos] = @intCast(ip_bytes.len);
    pos += 1;
    if (!ensureSpace(key_buf.len, pos, ip_bytes.len)) return null;
    @memcpy(key_buf[pos .. pos + ip_bytes.len], ip_bytes);
    pos += ip_bytes.len;
    if (!appendKeyPart(key_buf, &pos, table)) return null;
    if (!appendKeyPart(key_buf, &pos, set_name)) return null;
    return key_buf[0..pos];
}

fn buildCacheKeyHash(key: []const u8) u64 {
    const hash = fnv1a64(1469598103934665603, key);
    return if (hash == 0) 1 else hash;
}

fn clearLocalCache() void {
    nftset_cache = std.mem.zeroes([NFTSET_CACHE_SIZE]CacheEntry);
}

fn syncLocalCacheGeneration() void {
    const store = getLookupCacheStore() orelse return;
    const generation = @atomicLoad(u64, &store.*.generation, .acquire);
    if (generation == nftset_cache_generation_seen) return;
    clearLocalCache();
    nftset_cache_generation_seen = generation;
}

fn cacheLookup(key: []const u8, now: ngx_msec_t) CacheLookup {
    for (&nftset_cache) |*entry| {
        if (!entry.valid) continue;
        if (entry.expires_at < now) {
            entry.valid = false;
            continue;
        }
        if (entry.key_len != key.len) continue;
        if (!std.mem.eql(u8, entry.key[0..entry.key_len], key)) continue;
        entry.last_used_at = now;
        return .{ .hit = entry.membership };
    }
    return .miss;
}

fn cacheStore(key: []const u8, membership: CacheMembership, now: ngx_msec_t, ttl: ngx_msec_t) void {
    if (ttl == 0 or key.len == 0) return;

    var target: ?*CacheEntry = null;
    var oldest: ?*CacheEntry = null;

    for (&nftset_cache) |*entry| {
        if (!entry.valid) {
            target = entry;
            break;
        }
        if (entry.expires_at < now) {
            target = entry;
            break;
        }
        if (entry.key_len == key.len and std.mem.eql(u8, entry.key[0..entry.key_len], key)) {
            target = entry;
            break;
        }
        if (oldest == null or entry.last_used_at < oldest.?.last_used_at) oldest = entry;
    }

    const slot = target orelse oldest orelse return;
    slot.valid = true;
    slot.key_len = @intCast(key.len);
    @memcpy(slot.key[0..key.len], key);
    slot.membership = membership;
    slot.last_used_at = now;
    slot.expires_at = now + ttl;
}

fn sharedCacheLookup(key: []const u8, now: ngx_msec_t) CacheLookup {
    const shpool = getLookupCacheShpool() orelse return .miss;
    const store = getLookupCacheStore() orelse return .miss;
    const cache_store: *nftset_lookup_cache_store = @ptrCast(store);
    const key_hash = buildCacheKeyHash(key);

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.*.mutex);

    for (&cache_store.entries) |*entry| {
        if (entry.key_hash == 0) continue;
        if (entry.expires_at < now) {
            entry.* = std.mem.zeroes(SharedCacheEntry);
            continue;
        }
        if (entry.key_hash != key_hash or entry.key_len != key.len) continue;
        if (!std.mem.eql(u8, entry.key[0..entry.key_len], key)) continue;
        entry.last_used_at = now;
        return .{ .hit = entry.membership };
    }

    return .miss;
}

fn sharedCacheStoreLocked(store: *nftset_lookup_cache_store, key: []const u8, membership: CacheMembership, now: ngx_msec_t, ttl: ngx_msec_t) void {
    if (ttl == 0 or key.len == 0) return;

    const key_hash = buildCacheKeyHash(key);
    var target: ?*SharedCacheEntry = null;
    var oldest: ?*SharedCacheEntry = null;

    for (&store.entries) |*entry| {
        if (entry.key_hash == 0) {
            target = entry;
            break;
        }
        if (entry.expires_at < now) {
            target = entry;
            break;
        }
        if (entry.key_hash == key_hash and entry.key_len == key.len and std.mem.eql(u8, entry.key[0..entry.key_len], key)) {
            target = entry;
            break;
        }
        if (oldest == null or entry.last_used_at < oldest.?.last_used_at) oldest = entry;
    }

    const slot = target orelse oldest orelse return;
    if (slot.key_hash == 0) store.entry_count += 1;
    slot.key_hash = key_hash;
    slot.key_len = @intCast(key.len);
    @memcpy(slot.key[0..key.len], key);
    slot.membership = membership;
    slot.last_used_at = now;
    slot.expires_at = now + ttl;
}

fn sharedCacheStore(key: []const u8, membership: CacheMembership, now: ngx_msec_t, ttl: ngx_msec_t) void {
    const shpool = getLookupCacheShpool() orelse return;
    const store = getLookupCacheStore() orelse return;

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.*.mutex);

    const cache_store: *nftset_lookup_cache_store = @ptrCast(store);
    sharedCacheStoreLocked(cache_store, key, membership, now, ttl);
}

fn sharedCacheStoreAndBumpGeneration(key: []const u8, membership: CacheMembership, now: ngx_msec_t, ttl: ngx_msec_t) ?u64 {
    const shpool = getLookupCacheShpool() orelse return null;
    const store = getLookupCacheStore() orelse return null;
    const cache_store: *nftset_lookup_cache_store = @ptrCast(store);

    shm.ngx_shmtx_lock(&shpool.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.*.mutex);

    sharedCacheStoreLocked(cache_store, key, membership, now, ttl);
    const next_generation = cache_store.generation + 1;
    @atomicStore(u64, &cache_store.generation, next_generation, .release);
    return next_generation;
}

fn updateLookupCacheForSet(
    table: []const u8,
    set_name: []const u8,
    table_fam: u8,
    ip_bytes: []const u8,
    ttl: ngx_msec_t,
) void {
    if (ttl == 0) return;
    var key_buf: [NFTSET_CACHE_KEY_MAX]u8 = undefined;
    const cache_key = buildCacheKey(&key_buf, table, set_name, table_fam, ip_bytes) orelse return;
    const now = ngx_current_msec;
    if (sharedCacheStoreAndBumpGeneration(cache_key, .in_set, now, ttl)) |generation| {
        clearLocalCache();
        nftset_cache_generation_seen = generation;
    }
    cacheStore(cache_key, .in_set, now, ttl);
}

// Query whether ip_bytes is a member of the named set in the named table.
//
// Protocol: send NFT_MSG_GETSETELEM | NLM_F_REQUEST | NLM_F_ACK.
// Responses (each a separate Netlink datagram):
//   element found  → NFT_MSG_NEWSETELEM, then NLMSG_ERROR(error=0)
//   element absent → NLMSG_ERROR(error=-ENOENT)   → not_in_set
//   other error    → NLMSG_ERROR(error=<negative>) → lookup_error
fn nftset_probe_set_exists(
    table: []const u8,
    set_name: []const u8,
    table_fam: u8,
) SetExistenceProbe {
    if (netlink_fd < 0) return .unknown;

    var qbuf: [256]u8 = undefined;
    netlink_seq +%= 1;
    const probe_seq = netlink_seq;
    const msg_len = build_getset_query(&qbuf, probe_seq, table_fam, table, set_name) orelse return .unknown;

    const kernel_addr = SockaddrNl{ .family = AF_NETLINK_SOCK, .pad = 0, .pid = 0, .groups = 0 };
    const sent = sendto(netlink_fd, &qbuf, msg_len, 0, &kernel_addr, @sizeOf(SockaddrNl));
    if (sent < 0) return .unknown;

    var rbuf: [4096]u8 = undefined;
    var saw_newset = false;
    var iters: u8 = 0;
    while (iters < 4) : (iters += 1) {
        const rcvd = recv(netlink_fd, &rbuf, rbuf.len, 0);
        if (rcvd <= 0) return .unknown;

        const rcvd_sz: usize = @intCast(rcvd);
        var off: usize = 0;

        while (off + NLMSG_HDR_SZ <= rcvd_sz) {
            const nlh = readStruct(Nlmsghdr, &rbuf, off);
            if (nlh.len < NLMSG_HDR_SZ) break;
            if (nlh.len > rcvd_sz - off) return .unknown;

            const step = nla_align(@intCast(nlh.len));
            if (step == 0 or step > rcvd_sz - off) return .unknown;

            if (nlh.seq != probe_seq) {
                off += step;
                continue;
            }

            if (nlh.type_ == NLMSG_ERROR_TYPE) {
                if (off + NLMSG_HDR_SZ + 4 > rcvd_sz) return .unknown;
                const err_val = read_i32_native(&rbuf, off + NLMSG_HDR_SZ);
                if (err_val == 0) return if (saw_newset) .exists else .unknown;
                if (err_val == -2) return .missing;
                return .unknown;
            }

            const newset_type: u16 = (NFNL_SUBSYS_NFTABLES << 8) | NFT_MSG_NEWSET;
            if (nlh.type_ == newset_type) saw_newset = true;

            off += step;
        }
    }

    return .unknown;
}

fn nftset_ip_in_set(
    table: []const u8,
    set_name: []const u8,
    table_fam: u8,
    ip_bytes: []const u8,
) LookupResult {
    if (netlink_fd < 0) return .{ .lookup_error = -1 };

    var qbuf: [512]u8 = undefined;
    netlink_seq +%= 1;
    const msg_len = build_query(&qbuf, netlink_seq, table_fam, table, set_name, ip_bytes) orelse return .{ .lookup_error = -2 };

    const kernel_addr = SockaddrNl{ .family = AF_NETLINK_SOCK, .pad = 0, .pid = 0, .groups = 0 };

    const sent = sendto(netlink_fd, &qbuf, msg_len, 0, &kernel_addr, @sizeOf(SockaddrNl));
    if (sent < 0) return .{ .lookup_error = -3 };

    var rbuf: [4096]u8 = undefined;
    var found = false;

    // Receive loop: found case requires 2 datagrams (NEWSETELEM + ACK).
    // Socket has a strict receive budget set in init_process.
    var iters: u8 = 0;
    while (iters < 4) : (iters += 1) {
        const rcvd = recv(netlink_fd, &rbuf, rbuf.len, 0);
        if (rcvd <= 0) return .{ .lookup_error = -4 }; // timeout or socket error

        const rcvd_sz: usize = @intCast(rcvd);
        var off: usize = 0;

        while (off + NLMSG_HDR_SZ <= rcvd_sz) {
            const nlh = readStruct(Nlmsghdr, &rbuf, off);
            if (nlh.len < NLMSG_HDR_SZ) break;
            if (nlh.len > rcvd_sz - off) return .{ .lookup_error = -5 };

            const step = nla_align(@intCast(nlh.len));
            if (step == 0 or step > rcvd_sz - off) return .{ .lookup_error = -6 };

            if (nlh.seq != netlink_seq) {
                off += step;
                continue;
            }

            const msg_type = nlh.type_;

            if (msg_type == NLMSG_ERROR_TYPE) {
                if (off + NLMSG_HDR_SZ + 4 > rcvd_sz) return .{ .lookup_error = -7 };
                const err_val = read_i32_native(&rbuf, off + NLMSG_HDR_SZ);
                if (err_val == 0) {
                    // Explicit ACK (NLM_F_ACK response with error=0)
                    return if (found) .in_set else .not_in_set;
                }
                if (err_val == -2) {
                    return switch (nftset_probe_set_exists(table, set_name, table_fam)) {
                        .exists => .not_in_set,
                        .missing => .{ .lookup_error = err_val },
                        .unknown => .not_in_set,
                    };
                }
                return .{ .lookup_error = err_val };
            }

            const newsetelem_type: u16 = (NFNL_SUBSYS_NFTABLES << 8) | NFT_MSG_NEWSETELEM;
            if (msg_type == newsetelem_type) found = true;

            if (msg_type == NLMSG_DONE_TYPE) {
                return if (found) .in_set else .not_in_set;
            }

            off += step;
        }
    }

    return if (found) .in_set else .{ .lookup_error = -8 };
}

fn nftset_add_ip_to_set(
    table: []const u8,
    set_name: []const u8,
    table_fam: u8,
    ip_bytes: []const u8,
    timeout_ms: ngx_msec_t,
) AutoaddResult {
    if (netlink_fd < 0) return .{ .add_error = -1 };

    var qbuf: [512]u8 = undefined;
    var begin_buf: [20]u8 = undefined;
    var end_buf: [20]u8 = undefined;
    var send_buf: [768]u8 = undefined;

    netlink_seq +%= 1;
    const begin_seq = netlink_seq;
    netlink_seq +%= 1;
    const add_seq = netlink_seq;
    netlink_seq +%= 1;
    const end_seq = netlink_seq;

    const begin_len = build_batch_marker(&begin_buf, begin_seq, NFNL_MSG_BATCH_BEGIN);
    const msg_len = build_add_query(&qbuf, add_seq, table_fam, table, set_name, ip_bytes, timeout_ms) orelse return .{ .add_error = -2 };
    const end_len = build_batch_marker(&end_buf, end_seq, NFNL_MSG_BATCH_END);

    const total_len = begin_len + msg_len + end_len;
    if (total_len > send_buf.len) return .{ .add_error = -10 };
    @memcpy(send_buf[0..begin_len], begin_buf[0..begin_len]);
    @memcpy(send_buf[begin_len .. begin_len + msg_len], qbuf[0..msg_len]);
    @memcpy(send_buf[begin_len + msg_len .. total_len], end_buf[0..end_len]);

    const kernel_addr = SockaddrNl{ .family = AF_NETLINK_SOCK, .pad = 0, .pid = 0, .groups = 0 };
    const sent = sendto(netlink_fd, &send_buf, total_len, 0, &kernel_addr, @sizeOf(SockaddrNl));
    if (sent < 0) return .{ .add_error = -3 };

    var rbuf: [4096]u8 = undefined;
    var iters: u8 = 0;
    var saw_done = false;
    while (iters < 4) : (iters += 1) {
        const rcvd = recv(netlink_fd, &rbuf, rbuf.len, 0);
        if (rcvd <= 0) return .{ .add_error = -4 };

        const rcvd_sz: usize = @intCast(rcvd);
        var off: usize = 0;
        while (off + NLMSG_HDR_SZ <= rcvd_sz) {
            const nlh = readStruct(Nlmsghdr, &rbuf, off);
            if (nlh.len < NLMSG_HDR_SZ) break;
            if (nlh.len > rcvd_sz - off) return .{ .add_error = -5 };

            const step = nla_align(@intCast(nlh.len));
            if (step == 0 or step > rcvd_sz - off) return .{ .add_error = -6 };

            if (nlh.seq != add_seq) {
                off += step;
                continue;
            }

            if (nlh.type_ == NLMSG_ERROR_TYPE) {
                if (off + NLMSG_HDR_SZ + 4 > rcvd_sz) return .{ .add_error = -7 };
                const err_val = read_i32_native(&rbuf, off + NLMSG_HDR_SZ);
                if (err_val == 0) return .added;
                if (err_val == -17) return .exists;
                return .{ .add_error = err_val };
            }

            if (nlh.type_ == NLMSG_DONE_TYPE) saw_done = true;

            off += step;
        }
    }

    return .{ .add_error = if (saw_done) -9 else -8 };
}

// ──────────────────────────────────────────────────────────────────────────
// Per-worker init / exit (open/close the Netlink socket once per worker)
// ──────────────────────────────────────────────────────────────────────────

fn nftset_init_process(cycle: [*c]core.ngx_cycle_t) callconv(.c) ngx_int_t {
    clearLocalCache();
    nftset_cache_generation_seen = 0;
    netlink_fd = socket(AF_NETLINK_SOCK, SOCK_RAW_C, NETLINK_NETFILTER_PROT);
    if (netlink_fd < 0) {
        // Socket failed (e.g. no CAP_NET_ADMIN) — module operates in
        // lookup_error mode; fail_open policy controls the outcome.
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, cycle.*.log, 0, "nftset: failed to open netlink socket", .{});
        return NGX_OK;
    }

    const tv = Timeval{ .tv_sec = 0, .tv_usec = NFTSET_NETLINK_RECV_BUDGET_US };
    if (setsockopt(netlink_fd, SOL_SOCKET_C, SO_RCVTIMEO_C, &tv, @sizeOf(Timeval)) < 0) {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, cycle.*.log, 0, "nftset: failed to set netlink receive timeout", .{});
    }

    var nl_addr = SockaddrNl{ .family = AF_NETLINK_SOCK, .pad = 0, .pid = 0, .groups = 0 };
    if (bind(netlink_fd, &nl_addr, @sizeOf(SockaddrNl)) < 0) {
        ngx.log.ngz_log_error(ngx.log.NGX_LOG_ERR, cycle.*.log, 0, "nftset: failed to bind netlink socket", .{});
        _ = close(netlink_fd);
        netlink_fd = -1;
    }

    return NGX_OK;
}

fn nftset_exit_process(_: [*c]core.ngx_cycle_t) callconv(.c) void {
    clearLocalCache();
    nftset_cache_generation_seen = 0;
    if (netlink_fd >= 0) {
        _ = close(netlink_fd);
        netlink_fd = -1;
    }
}

// ──────────────────────────────────────────────────────────────────────────
// Module configuration types
// ──────────────────────────────────────────────────────────────────────────

const nftset_loc_conf = extern struct {
    enabled: ngx_flag_t,
    // nftables table name (e.g. "filter")
    table: ngx_str_t,
    // nftables set name (e.g. "blocklist")
    set: ngx_str_t,
    // Optional multi-set OR list. When present, it overrides table/set.
    sets: NArray(nftset_spec),
    // nftables table family: "inet", "ip", "ip6"; null = auto-detect
    family: ngx_str_t,
    // deny=1: block IPs found in set; deny=0: block IPs NOT in set (allowlist)
    deny: ngx_flag_t,
    // HTTP status code returned when blocking (default 403)
    status: ngx_int_t,
    // fail_open=1: allow on lookup error; fail_open=0: deny on lookup error
    fail_open: ngx_flag_t,
    // dryrun=1: log block decision but do not actually block
    dryrun: ngx_flag_t,
    // cache_ttl: how long to cache set membership per worker (ms, default 60000)
    cache_ttl: ngx_msec_t,
    // autoadd: add the client IP to a target set on request handling
    autoadd: ngx_flag_t,
    autoadd_table: ngx_str_t,
    autoadd_set: ngx_str_t,
    autoadd_family: ngx_str_t,
    autoadd_timeout: ngx_msec_t,
    ratelimit_rate: ngx_uint_t,
    ratelimit_burst: ngx_uint_t,
    ratelimit_burst_set: ngx_flag_t,
    ratelimit_status: ngx_int_t,
    autoban_table: ngx_str_t,
    autoban_set: ngx_str_t,
    autoban_family: ngx_str_t,
    autoban_timeout: ngx_msec_t,
    ratelimit_scope: ngx_str_t,
};

// Per-request context — carries the access decision and resolved family
const nftset_ctx = extern struct {
    result: ngx_str_t,
    // Resolved element family: "ip" or "ip6" (always auto-detected)
    client_family: ngx_str_t,
    matched_set: ngx_str_t,
};

const result_allow = ngx_string("allow");
const result_deny = ngx_string("deny");
const result_dryrun = ngx_string("dryrun");
const result_error = ngx_string("error");

fn make_matched_set(r: [*c]ngx_http_request_t, table: ngx_str_t, set_name: ngx_str_t) ngx_str_t {
    return concat_string_from_pool(&.{ table, set_name }, ":", r.*.pool) catch ngx_null_str;
}

fn make_matched_set_from_slice(r: [*c]ngx_http_request_t, table: []const u8, set_name: []const u8) ngx_str_t {
    const table_str = ngx_string(table);
    const set_str = ngx_string(set_name);
    return concat_string_from_pool(&.{ table_str, set_str }, ":", r.*.pool) catch ngx_null_str;
}

fn parse_set_spec(spec: []const u8) ?struct { table: []const u8, set_name: []const u8 } {
    const sep = std.mem.indexOfScalar(u8, spec, ':') orelse return null;
    if (sep == 0 or sep + 1 >= spec.len) return null;
    return .{
        .table = spec[0..sep],
        .set_name = spec[sep + 1 ..],
    };
}

fn cfgError(cf: [*c]ngx_conf_t, statement: []const u8) [*c]u8 {
    ngx.log.ngz_log_error(ngx.log.NGX_LOG_EMERG, cf.*.log, 0, statement.ptr, .{});
    return conf.NGX_CONF_ERROR;
}

fn ngx_conf_set_nftset_ratelimit_rate(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lcf = core.castPtr(nftset_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return cfgError(cf, "nftset_ratelimit_rate requires a value");
    const raw = core.slicify(u8, arg.*.data, arg.*.len);
    const parsed = parseRateLimitRate(raw) orelse return cfgError(cf, "nftset_ratelimit_rate must be a positive integer or Nr/s");
    if (parsed == 0) return cfgError(cf, "nftset_ratelimit_rate must be greater than zero");

    lcf.*.ratelimit_rate = parsed;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_nftset_ratelimit_burst(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lcf = core.castPtr(nftset_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;

    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return cfgError(cf, "nftset_ratelimit_burst requires a value");
    const raw = core.slicify(u8, arg.*.data, arg.*.len);
    lcf.*.ratelimit_burst = std.fmt.parseInt(ngx_uint_t, raw, 10) catch return cfgError(cf, "nftset_ratelimit_burst must be an integer");
    lcf.*.ratelimit_burst_set = 1;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_nftset_set(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lcf = core.castPtr(nftset_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    var i: ngx_uint_t = 1;
    const arg = ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i) orelse return cfgError(cf, "nftset_set requires a value");
    const raw = arg.*.data[0..arg.*.len];
    if (parse_set_spec(raw)) |parsed| {
        lcf.*.table = ngx.string.ngx_string_from_pool(@constCast(parsed.table.ptr), parsed.table.len, cf.*.pool) catch return conf.NGX_CONF_ERROR;
        lcf.*.set = ngx.string.ngx_string_from_pool(@constCast(parsed.set_name.ptr), parsed.set_name.len, cf.*.pool) catch return conf.NGX_CONF_ERROR;
    } else {
        lcf.*.set = arg.*;
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_nftset_sets(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    const lcf = core.castPtr(nftset_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    if (!lcf.*.sets.inited()) {
        lcf.*.sets = NArray(nftset_spec).init(cf.*.pool, 1) catch return conf.NGX_CONF_ERROR;
    }

    var i: ngx_uint_t = 1;
    while (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const raw = arg.*.data[0..arg.*.len];
        const parsed = parse_set_spec(raw) orelse return cfgError(cf, "nftset_sets entries must use table:set syntax");
        const spec = lcf.*.sets.append() catch return conf.NGX_CONF_ERROR;
        spec.*.table = ngx.string.ngx_string_from_pool(@constCast(parsed.table.ptr), parsed.table.len, cf.*.pool) catch return conf.NGX_CONF_ERROR;
        spec.*.set = ngx.string.ngx_string_from_pool(@constCast(parsed.set_name.ptr), parsed.set_name.len, cf.*.pool) catch return conf.NGX_CONF_ERROR;
    }

    if (lcf.*.sets.size() == 0) return cfgError(cf, "nftset_sets requires at least one table:set entry");
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_nftset_list(
    cf: [*c]ngx_conf_t,
    loc: ?*anyopaque,
    deny: ngx_flag_t,
) [*c]u8 {
    const lcf = core.castPtr(nftset_loc_conf, loc) orelse return conf.NGX_CONF_ERROR;
    if (!lcf.*.sets.inited()) {
        lcf.*.sets = NArray(nftset_spec).init(cf.*.pool, 1) catch return conf.NGX_CONF_ERROR;
    }
    var i: ngx_uint_t = 1;
    while (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
        const raw = arg.*.data[0..arg.*.len];
        const parsed = parse_set_spec(raw) orelse return cfgError(cf, "nftset_blacklist / nftset_whitelist require table:set syntax");
        const spec = lcf.*.sets.append() catch return conf.NGX_CONF_ERROR;
        spec.*.table = ngx.string.ngx_string_from_pool(@constCast(parsed.table.ptr), parsed.table.len, cf.*.pool) catch return conf.NGX_CONF_ERROR;
        spec.*.set = ngx.string.ngx_string_from_pool(@constCast(parsed.set_name.ptr), parsed.set_name.len, cf.*.pool) catch return conf.NGX_CONF_ERROR;
    }
    if (lcf.*.sets.size() == 0) return cfgError(cf, "nftset_blacklist / nftset_whitelist require at least one table:set entry");
    lcf.*.enabled = 1;
    lcf.*.deny = deny;
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_nftset_blacklist(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    return ngx_conf_set_nftset_list(cf, loc, 1);
}

fn ngx_conf_set_nftset_whitelist(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    return ngx_conf_set_nftset_list(cf, loc, 0);
}

fn set_ctx(r: [*c]ngx_http_request_t, result: ngx_str_t, client_family: ngx_str_t, matched_set: ngx_str_t) void {
    const ctx = core.ngz_pcalloc_c(nftset_ctx, r.*.pool) orelse return;
    ctx.*.result = result;
    ctx.*.client_family = client_family;
    ctx.*.matched_set = matched_set;
    r.*.ctx[ngx_http_nftset_module.ctx_index] = ctx;
}

fn lookup_single_set(
    r: [*c]ngx_http_request_t,
    table: []const u8,
    set_name: []const u8,
    table_str: ngx_str_t,
    set_str: ngx_str_t,
    table_fam: u8,
    ip_bytes: []const u8,
    cache_ttl: ngx_msec_t,
) LookupResult {
    const now = ngx_current_msec;
    var key_buf: [NFTSET_CACHE_KEY_MAX]u8 = undefined;
    const cache_key = if (cache_ttl > 0)
        buildCacheKey(&key_buf, table, set_name, table_fam, ip_bytes)
    else
        null;

    return blk: {
        if (cache_ttl > 0) {
            syncLocalCacheGeneration();
            if (cache_key) |key| {
                switch (cacheLookup(key, now)) {
                    .hit => |membership| {
                        ngx.log.ngz_log_debug(
                            ngx.log.NGX_LOG_DEBUG_HTTP,
                            r.*.connection.*.log,
                            0,
                            "nftset: cache hit client=%V table=%V set=%V",
                            .{ &r.*.connection.*.addr_text, &table_str, &set_str },
                        );
                        break :blk cacheMembershipToLookup(membership);
                    },
                    .miss => {},
                }

                switch (sharedCacheLookup(key, now)) {
                    .hit => |membership| {
                        cacheStore(key, membership, now, cache_ttl);
                        ngx.log.ngz_log_debug(
                            ngx.log.NGX_LOG_DEBUG_HTTP,
                            r.*.connection.*.log,
                            0,
                            "nftset: shared cache hit client=%V table=%V set=%V",
                            .{ &r.*.connection.*.addr_text, &table_str, &set_str },
                        );
                        break :blk cacheMembershipToLookup(membership);
                    },
                    .miss => {},
                }
            }
        }

        const fresh = nftset_ip_in_set(table, set_name, table_fam, ip_bytes);
        if (cache_ttl > 0) {
            if (cache_key) |key| {
                if (lookupToCacheMembership(fresh)) |membership| {
                    cacheStore(key, membership, now, cache_ttl);
                    sharedCacheStore(key, membership, now, cache_ttl);
                }
            }
        }
        break :blk fresh;
    };
}

fn perform_lookup(
    r: [*c]ngx_http_request_t,
    lcf: *nftset_loc_conf,
    table_fam: u8,
    ip_bytes: []const u8,
) LookupOutcome {
    var matched_set = ngx_null_str;
    const table_slice: []const u8 = if (lcf.*.table.data != null) lcf.*.table.data[0..lcf.*.table.len] else "filter";
    const set_slice: []const u8 = if (lcf.*.set.data != null) lcf.*.set.data[0..lcf.*.set.len] else "blocklist";

    const lookup = blk: {
        if (lcf.*.sets.inited() and lcf.*.sets.size() > 0) {
            var it = lcf.*.sets.iterator();
            while (it.next()) |spec| {
                const spec_table = spec.*.table.data[0..spec.*.table.len];
                const spec_set = spec.*.set.data[0..spec.*.set.len];
                const spec_lookup = lookup_single_set(
                    r,
                    spec_table,
                    spec_set,
                    spec.*.table,
                    spec.*.set,
                    table_fam,
                    ip_bytes,
                    lcf.*.cache_ttl,
                );
                switch (spec_lookup) {
                    .in_set => {
                        matched_set = make_matched_set(r, spec.*.table, spec.*.set);
                        break :blk .in_set;
                    },
                    .lookup_error => break :blk spec_lookup,
                    .not_in_set => {},
                }
            }
            break :blk .not_in_set;
        }

        const single_lookup = lookup_single_set(
            r,
            table_slice,
            set_slice,
            lcf.*.table,
            lcf.*.set,
            table_fam,
            ip_bytes,
            lcf.*.cache_ttl,
        );
        if (single_lookup == .in_set) {
            matched_set = make_matched_set_from_slice(r, table_slice, set_slice);
        }
        break :blk single_lookup;
    };

    return .{ .lookup = lookup, .matched_set = matched_set };
}

fn lookupUsesTarget(lcf: *nftset_loc_conf, table: []const u8, set_name: []const u8) bool {
    if (lcf.*.sets.inited() and lcf.*.sets.size() > 0) {
        var it = lcf.*.sets.iterator();
        while (it.next()) |spec| {
            const spec_table = spec.*.table.data[0..spec.*.table.len];
            const spec_set = spec.*.set.data[0..spec.*.set.len];
            if (std.mem.eql(u8, spec_table, table) and std.mem.eql(u8, spec_set, set_name)) return true;
        }
        return false;
    }

    const table_slice: []const u8 = if (lcf.*.table.data != null) lcf.*.table.data[0..lcf.*.table.len] else "filter";
    const set_slice: []const u8 = if (lcf.*.set.data != null) lcf.*.set.data[0..lcf.*.set.len] else "blocklist";
    return std.mem.eql(u8, table_slice, table) and std.mem.eql(u8, set_slice, set_name);
}

fn refreshLookupCacheIfTargeted(
    lcf: *nftset_loc_conf,
    lookup_enabled: bool,
    table_fam: u8,
    target_table_fam: u8,
    table: []const u8,
    set_name: []const u8,
    ip_bytes: []const u8,
) void {
    if (!lookup_enabled) return;
    if (target_table_fam != table_fam) return;
    if (!lookupUsesTarget(lcf, table, set_name)) return;
    updateLookupCacheForSet(table, set_name, table_fam, ip_bytes, lcf.*.cache_ttl);
}

fn applyAutoadd(
    r: [*c]ngx_http_request_t,
    lcf: *nftset_loc_conf,
    lookup_enabled: bool,
    table_fam: u8,
    is_ipv6: bool,
    elem_family: ngx_str_t,
    table_slice: []const u8,
    set_slice: []const u8,
    ip_bytes: []const u8,
) void {
    const autoadd_family_slice = if (lcf.*.autoadd_family.data != null and lcf.*.autoadd_family.len > 0)
        lcf.*.autoadd_family.data[0..lcf.*.autoadd_family.len]
    else if (lcf.*.family.data != null and lcf.*.family.len > 0)
        lcf.*.family.data[0..lcf.*.family.len]
    else
        "inet";
    const autoadd_family_mismatch = (std.mem.eql(u8, autoadd_family_slice, "ip") and is_ipv6) or
        (std.mem.eql(u8, autoadd_family_slice, "ip6") and !is_ipv6);
    if (autoadd_family_mismatch) {
        ngx.log.ngz_log_error(
            ngx.log.NGX_LOG_ERR,
            r.*.connection.*.log,
            0,
            "nftset: autoadd client family %V does not match nftset_autoadd_family=%V (table=%V set=%V)",
            .{ &elem_family, &lcf.*.autoadd_family, &lcf.*.autoadd_table, &lcf.*.autoadd_set },
        );
        return;
    }

    const autoadd_table_slice: []const u8 = if (lcf.*.autoadd_table.data != null) lcf.*.autoadd_table.data[0..lcf.*.autoadd_table.len] else table_slice;
    const autoadd_set_slice: []const u8 = if (lcf.*.autoadd_set.data != null) lcf.*.autoadd_set.data[0..lcf.*.autoadd_set.len] else set_slice;
    const autoadd_table_fam = table_family_num(autoadd_family_slice);
    switch (nftset_add_ip_to_set(autoadd_table_slice, autoadd_set_slice, autoadd_table_fam, ip_bytes, lcf.*.autoadd_timeout)) {
        .added => {
            ngx.log.ngz_log_debug(
                ngx.log.NGX_LOG_DEBUG_HTTP,
                r.*.connection.*.log,
                0,
                "nftset: autoadd inserted %V into table=%V set=%V",
                .{ &r.*.connection.*.addr_text, &lcf.*.autoadd_table, &lcf.*.autoadd_set },
            );
            refreshLookupCacheIfTargeted(lcf, lookup_enabled, table_fam, autoadd_table_fam, autoadd_table_slice, autoadd_set_slice, ip_bytes);
        },
        .exists => {
            ngx.log.ngz_log_debug(
                ngx.log.NGX_LOG_DEBUG_HTTP,
                r.*.connection.*.log,
                0,
                "nftset: autoadd found existing element for %V in table=%V set=%V",
                .{ &r.*.connection.*.addr_text, &lcf.*.autoadd_table, &lcf.*.autoadd_set },
            );
            refreshLookupCacheIfTargeted(lcf, lookup_enabled, table_fam, autoadd_table_fam, autoadd_table_slice, autoadd_set_slice, ip_bytes);
        },
        .add_error => |err_code| {
            ngx.log.ngz_log_error(
                ngx.log.NGX_LOG_ERR,
                r.*.connection.*.log,
                0,
                "nftset: autoadd failed for %V (table=%V set=%V err=%d)",
                .{ &r.*.connection.*.addr_text, &lcf.*.autoadd_table, &lcf.*.autoadd_set, err_code },
            );
        },
    }
}

fn maybeApplyAutoban(
    r: [*c]ngx_http_request_t,
    lcf: *nftset_loc_conf,
    lookup_enabled: bool,
    table_fam: u8,
    is_ipv6: bool,
    elem_family: ngx_str_t,
    table_slice: []const u8,
    ip_bytes: []const u8,
) void {
    if (lcf.*.autoban_set.data == null or lcf.*.autoban_set.len == 0) return;

    const autoban_family_slice = if (lcf.*.autoban_family.data != null and lcf.*.autoban_family.len > 0)
        lcf.*.autoban_family.data[0..lcf.*.autoban_family.len]
    else if (lcf.*.family.data != null and lcf.*.family.len > 0)
        lcf.*.family.data[0..lcf.*.family.len]
    else
        "inet";
    const autoban_family_mismatch = (std.mem.eql(u8, autoban_family_slice, "ip") and is_ipv6) or
        (std.mem.eql(u8, autoban_family_slice, "ip6") and !is_ipv6);
    if (autoban_family_mismatch) {
        ngx.log.ngz_log_error(
            ngx.log.NGX_LOG_ERR,
            r.*.connection.*.log,
            0,
            "nftset: autoban client family %V does not match nftset_autoban_family=%V (table=%V set=%V)",
            .{ &elem_family, &lcf.*.autoban_family, &lcf.*.autoban_table, &lcf.*.autoban_set },
        );
        return;
    }

    const autoban_table_slice: []const u8 = if (lcf.*.autoban_table.data != null) lcf.*.autoban_table.data[0..lcf.*.autoban_table.len] else table_slice;
    const autoban_set_slice: []const u8 = lcf.*.autoban_set.data[0..lcf.*.autoban_set.len];
    const autoban_table_fam = table_family_num(autoban_family_slice);
    switch (nftset_add_ip_to_set(autoban_table_slice, autoban_set_slice, autoban_table_fam, ip_bytes, lcf.*.autoban_timeout)) {
        .added => {
            ngx.log.ngz_log_error(
                ngx.log.NGX_LOG_NOTICE,
                r.*.connection.*.log,
                0,
                "nftset: autoban inserted %V into table=%V set=%V",
                .{ &r.*.connection.*.addr_text, &lcf.*.autoban_table, &lcf.*.autoban_set },
            );
            refreshLookupCacheIfTargeted(lcf, lookup_enabled, table_fam, autoban_table_fam, autoban_table_slice, autoban_set_slice, ip_bytes);
        },
        .exists => {
            ngx.log.ngz_log_debug(
                ngx.log.NGX_LOG_DEBUG_HTTP,
                r.*.connection.*.log,
                0,
                "nftset: autoban found existing element for %V in table=%V set=%V",
                .{ &r.*.connection.*.addr_text, &lcf.*.autoban_table, &lcf.*.autoban_set },
            );
            refreshLookupCacheIfTargeted(lcf, lookup_enabled, table_fam, autoban_table_fam, autoban_table_slice, autoban_set_slice, ip_bytes);
        },
        .add_error => |err_code| {
            ngx.log.ngz_log_error(
                ngx.log.NGX_LOG_ERR,
                r.*.connection.*.log,
                0,
                "nftset: autoban failed for %V (table=%V set=%V err=%d)",
                .{ &r.*.connection.*.addr_text, &lcf.*.autoban_table, &lcf.*.autoban_set, err_code },
            );
        },
    }
}

// ──────────────────────────────────────────────────────────────────────────
// Access phase handler
// ──────────────────────────────────────────────────────────────────────────

fn ngx_http_nftset_access_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lcf = core.castPtr(
        nftset_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_nftset_module),
    ) orelse return NGX_DECLINED;

    const lookup_enabled = lcf.*.enabled == 1;
    const autoadd_enabled = lcf.*.autoadd == 1;
    const ratelimit_enabled = lcf.*.ratelimit_rate > 0;
    if (!lookup_enabled and !autoadd_enabled and !ratelimit_enabled) return NGX_DECLINED;

    // Element IP family: always derived from the actual client address.
    // "ip" for IPv4 (or IPv4-mapped IPv6), "ip6" for native IPv6.
    const elem_family = detect_client_family(r);
    const elem_fam_slice = elem_family.data[0..elem_family.len];
    const is_ipv6 = std.mem.eql(u8, elem_fam_slice, "ip6");

    // Table protocol family for the nfgenmsg header.
    // Uses the configured nftset_family; defaults to NFPROTO_INET when unset.
    const table_fam: u8 = if (lcf.*.family.data != null and lcf.*.family.len > 0)
        table_family_num(lcf.*.family.data[0..lcf.*.family.len])
    else
        NFPROTO_INET;

    ngx.log.ngz_log_debug(
        ngx.log.NGX_LOG_DEBUG_HTTP,
        r.*.connection.*.log,
        0,
        "nftset: client=%V elem_family=%V table=%V set=%V deny=%d dryrun=%d autoadd=%d",
        .{ &r.*.connection.*.addr_text, &elem_family, &lcf.*.table, &lcf.*.set, lcf.*.deny, lcf.*.dryrun, lcf.*.autoadd },
    );

    const table_slice: []const u8 = if (lcf.*.table.data != null) lcf.*.table.data[0..lcf.*.table.len] else "filter";
    const set_slice: []const u8 = if (lcf.*.set.data != null) lcf.*.set.data[0..lcf.*.set.len] else "blocklist";
    const configured_family = if (lcf.*.family.data != null and lcf.*.family.len > 0)
        lcf.*.family.data[0..lcf.*.family.len]
    else
        "inet";

    var ip_buf: [16]u8 = undefined;
    const ip_bytes = get_client_ip_bytes(r, is_ipv6, &ip_buf) orelse {
        if (lookup_enabled) {
            ngx.log.ngz_log_error(
                ngx.log.NGX_LOG_ERR,
                r.*.connection.*.log,
                0,
                "nftset: cannot extract client IP bytes (sa_family=%d)",
                .{@as(c_int, if (r.*.connection.*.sockaddr != null) @intCast(r.*.connection.*.sockaddr.?.*.sa_family) else 0)},
            );
            set_ctx(r, result_error, elem_family, ngx_null_str);
            if (lcf.*.fail_open == 1) return NGX_DECLINED;
            return lcf.*.status;
        }

        ngx.log.ngz_log_error(
            ngx.log.NGX_LOG_ERR,
            r.*.connection.*.log,
            0,
            "nftset: autoadd cannot extract client IP bytes (sa_family=%d)",
            .{@as(c_int, if (r.*.connection.*.sockaddr != null) @intCast(r.*.connection.*.sockaddr.?.*.sa_family) else 0)},
        );
        return NGX_DECLINED;
    };

    var response: ngx_int_t = NGX_DECLINED;
    var ctx_result = ngx_null_str;
    var ctx_matched_set = ngx_null_str;

    if (lookup_enabled) {
        const family_mismatch = (std.mem.eql(u8, configured_family, "ip") and is_ipv6) or
            (std.mem.eql(u8, configured_family, "ip6") and !is_ipv6);
        if (family_mismatch) {
            ngx.log.ngz_log_error(
                ngx.log.NGX_LOG_ERR,
                r.*.connection.*.log,
                0,
                "nftset: client family %V does not match configured nftset_family=%V (table=%V set=%V)",
                .{ &elem_family, &lcf.*.family, &lcf.*.table, &lcf.*.set },
            );
            ctx_result = result_error;
            response = if (lcf.*.fail_open == 1) NGX_DECLINED else lcf.*.status;
        } else {
            const outcome = perform_lookup(r, lcf, table_fam, ip_bytes);
            ctx_matched_set = outcome.matched_set;

            if (lcf.*.dryrun == 1) {
                const would_block = switch (outcome.lookup) {
                    .in_set => lcf.*.deny == 1,
                    .not_in_set => lcf.*.deny == 0,
                    .lookup_error => false,
                };
                if (would_block) {
                    ngx.log.ngz_log_error(
                        ngx.log.NGX_LOG_NOTICE,
                        r.*.connection.*.log,
                        0,
                        "nftset: dryrun would block %V (table=%V set=%V)",
                        .{ &r.*.connection.*.addr_text, &lcf.*.table, &lcf.*.set },
                    );
                }
                ctx_result = result_dryrun;
                response = NGX_DECLINED;
            } else if (outcome.lookup == .lookup_error) {
                const err_code = outcome.lookup.lookup_error;
                ngx.log.ngz_log_error(
                    ngx.log.NGX_LOG_ERR,
                    r.*.connection.*.log,
                    0,
                    "nftset: kernel lookup failed for %V (table=%V set=%V fail_open=%d err=%d)",
                    .{ &r.*.connection.*.addr_text, &lcf.*.table, &lcf.*.set, lcf.*.fail_open, err_code },
                );
                ctx_result = result_error;
                ctx_matched_set = ngx_null_str;
                response = if (lcf.*.fail_open == 1) NGX_DECLINED else lcf.*.status;
            } else {
                const blocked = if (outcome.lookup == .in_set) lcf.*.deny == 1 else lcf.*.deny == 0;
                if (blocked) {
                    ngx.log.ngz_log_error(
                        ngx.log.NGX_LOG_NOTICE,
                        r.*.connection.*.log,
                        0,
                        "nftset: blocking %V (table=%V set=%V status=%d)",
                        .{ &r.*.connection.*.addr_text, &lcf.*.table, &lcf.*.set, lcf.*.status },
                    );
                    ctx_result = result_deny;
                    response = lcf.*.status;
                } else {
                    ctx_result = result_allow;
                    response = NGX_DECLINED;
                }
            }
        }
    }

    if (ratelimit_enabled and response == NGX_DECLINED) {
        const rate_key = buildRateLimitKey(core.slicify(u8, lcf.*.ratelimit_scope.data, lcf.*.ratelimit_scope.len), table_fam, ip_bytes);
        const shpool = getRateLimitShpool() orelse return NGX_DECLINED;
        const store = getRateLimitStore() orelse return NGX_DECLINED;
        shm.ngx_shmtx_lock(&shpool.*.mutex);
        const allowed = checkRateLimit(store, rate_key, lcf.*.ratelimit_rate, lcf.*.ratelimit_burst);
        shm.ngx_shmtx_unlock(&shpool.*.mutex);
        if (!allowed) {
            maybeApplyAutoban(r, lcf, lookup_enabled, table_fam, is_ipv6, elem_family, table_slice, ip_bytes);
            ngx.log.ngz_log_error(
                ngx.log.NGX_LOG_NOTICE,
                r.*.connection.*.log,
                0,
                "nftset: ratelimit exceeded for %V (rate=%ui burst=%ui status=%d)",
                .{ &r.*.connection.*.addr_text, lcf.*.ratelimit_rate, lcf.*.ratelimit_burst, lcf.*.ratelimit_status },
            );
            if (lookup_enabled and ctx_result.len == 0) ctx_result = result_allow;
            if (lookup_enabled) {
                set_ctx(r, ctx_result, elem_family, ctx_matched_set);
            }
            return lcf.*.ratelimit_status;
        }
    }

    if (autoadd_enabled) {
        applyAutoadd(r, lcf, lookup_enabled, table_fam, is_ipv6, elem_family, table_slice, set_slice, ip_bytes);
    }

    if (lookup_enabled) {
        set_ctx(r, ctx_result, elem_family, ctx_matched_set);
        return response;
    }

    return NGX_DECLINED;
}

// ──────────────────────────────────────────────────────────────────────────
// $nftset_result variable getter
// ──────────────────────────────────────────────────────────────────────────

fn ngx_http_nftset_result_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = core.castPtr(nftset_ctx, r.*.ctx[ngx_http_nftset_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    if (ctx.*.result.len == 0) {
        v.*.flags.not_found = true;
        return NGX_OK;
    }
    v.*.data = ctx.*.result.data;
    v.*.flags.len = @intCast(ctx.*.result.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = false;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn ngx_http_nftset_matched_set_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    const ctx = core.castPtr(nftset_ctx, r.*.ctx[ngx_http_nftset_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    if (ctx.*.matched_set.len == 0) {
        v.*.flags.not_found = true;
        return NGX_OK;
    }
    v.*.data = ctx.*.matched_set.data;
    v.*.flags.len = @intCast(ctx.*.matched_set.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = false;
    v.*.flags.not_found = false;
    return NGX_OK;
}

// ──────────────────────────────────────────────────────────────────────────
// Config callbacks
// ──────────────────────────────────────────────────────────────────────────

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    const lcf = core.ngz_pcalloc_c(nftset_loc_conf, cf.*.pool) orelse return null;
    lcf.*.enabled = conf.NGX_CONF_UNSET;
    lcf.*.deny = conf.NGX_CONF_UNSET;
    lcf.*.status = conf.NGX_CONF_UNSET;
    lcf.*.fail_open = conf.NGX_CONF_UNSET;
    lcf.*.dryrun = conf.NGX_CONF_UNSET;
    lcf.*.cache_ttl = conf.NGX_CONF_UNSET_MSEC;
    lcf.*.autoadd = conf.NGX_CONF_UNSET;
    lcf.*.autoadd_timeout = conf.NGX_CONF_UNSET_MSEC;
    lcf.*.ratelimit_burst_set = conf.NGX_CONF_UNSET;
    lcf.*.ratelimit_status = conf.NGX_CONF_UNSET;
    lcf.*.autoban_timeout = conf.NGX_CONF_UNSET_MSEC;
    lcf.*.ratelimit_scope = ngx_str_t{ .len = 0, .data = null };
    return lcf;
}

fn merge_loc_conf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    const prev = core.castPtr(nftset_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const curr = core.castPtr(nftset_loc_conf, child) orelse return conf.NGX_CONF_OK;

    if (curr.*.enabled == conf.NGX_CONF_UNSET) {
        curr.*.enabled = if (prev.*.enabled == conf.NGX_CONF_UNSET) 0 else prev.*.enabled;
    }
    if (curr.*.deny == conf.NGX_CONF_UNSET) {
        curr.*.deny = if (prev.*.deny == conf.NGX_CONF_UNSET) 1 else prev.*.deny;
    }
    if (curr.*.status == conf.NGX_CONF_UNSET) {
        curr.*.status = if (prev.*.status == conf.NGX_CONF_UNSET) 403 else prev.*.status;
    }
    if (curr.*.fail_open == conf.NGX_CONF_UNSET) {
        curr.*.fail_open = if (prev.*.fail_open == conf.NGX_CONF_UNSET) 0 else prev.*.fail_open;
    }
    if (curr.*.dryrun == conf.NGX_CONF_UNSET) {
        curr.*.dryrun = if (prev.*.dryrun == conf.NGX_CONF_UNSET) 0 else prev.*.dryrun;
    }
    if (curr.*.cache_ttl == conf.NGX_CONF_UNSET_MSEC) {
        curr.*.cache_ttl = if (prev.*.cache_ttl == conf.NGX_CONF_UNSET_MSEC) 60000 else prev.*.cache_ttl;
    }
    if (curr.*.autoadd == conf.NGX_CONF_UNSET) {
        curr.*.autoadd = if (prev.*.autoadd == conf.NGX_CONF_UNSET) 0 else prev.*.autoadd;
    }
    if (curr.*.autoadd_timeout == conf.NGX_CONF_UNSET_MSEC) {
        curr.*.autoadd_timeout = if (prev.*.autoadd_timeout == conf.NGX_CONF_UNSET_MSEC) 0 else prev.*.autoadd_timeout;
    }
    if (curr.*.ratelimit_rate == 0 and prev.*.ratelimit_rate != 0) {
        curr.*.ratelimit_rate = prev.*.ratelimit_rate;
    }
    if (curr.*.ratelimit_burst_set == conf.NGX_CONF_UNSET) {
        if (prev.*.ratelimit_burst_set != conf.NGX_CONF_UNSET) {
            curr.*.ratelimit_burst = prev.*.ratelimit_burst;
            curr.*.ratelimit_burst_set = prev.*.ratelimit_burst_set;
        } else {
            curr.*.ratelimit_burst = 0;
            curr.*.ratelimit_burst_set = 0;
        }
    }
    if (curr.*.ratelimit_status == conf.NGX_CONF_UNSET) {
        curr.*.ratelimit_status = if (prev.*.ratelimit_status == conf.NGX_CONF_UNSET) NFTSET_RATELIMIT_STATUS else prev.*.ratelimit_status;
    }
    if (curr.*.autoban_timeout == conf.NGX_CONF_UNSET_MSEC) {
        curr.*.autoban_timeout = if (prev.*.autoban_timeout == conf.NGX_CONF_UNSET_MSEC) 0 else prev.*.autoban_timeout;
    }
    if (!curr.*.sets.inited() and prev.*.sets.inited()) {
        curr.*.sets = prev.*.sets;
    }
    conf.ngx_conf_merge_str_value(&curr.*.table, &prev.*.table, ngx_string("filter"));
    conf.ngx_conf_merge_str_value(&curr.*.set, &prev.*.set, ngx_string("blocklist"));
    // family: no hardcoded default — null signals auto-detect (use NFPROTO_INET).
    // Inherit from parent only if parent was explicitly set.
    if (curr.*.family.data == null and prev.*.family.data != null) {
        curr.*.family = prev.*.family;
    }
    if (curr.*.autoadd_table.data == null) {
        if (prev.*.autoadd_table.data != null) {
            curr.*.autoadd_table = prev.*.autoadd_table;
        } else {
            curr.*.autoadd_table = curr.*.table;
        }
    }
    if (curr.*.autoadd_set.data == null) {
        if (prev.*.autoadd_set.data != null) {
            curr.*.autoadd_set = prev.*.autoadd_set;
        } else {
            curr.*.autoadd_set = curr.*.set;
        }
    }
    if (curr.*.autoadd_family.data == null) {
        if (prev.*.autoadd_family.data != null) {
            curr.*.autoadd_family = prev.*.autoadd_family;
        } else {
            curr.*.autoadd_family = curr.*.family;
        }
    }
    if (curr.*.autoban_table.data == null) {
        if (prev.*.autoban_table.data != null) {
            curr.*.autoban_table = prev.*.autoban_table;
        } else {
            curr.*.autoban_table = curr.*.table;
        }
    }
    if (curr.*.autoban_set.data == null and prev.*.autoban_set.data != null) {
        curr.*.autoban_set = prev.*.autoban_set;
    }
    if (curr.*.autoban_family.data == null) {
        if (prev.*.autoban_family.data != null) {
            curr.*.autoban_family = prev.*.autoban_family;
        } else {
            curr.*.autoban_family = curr.*.family;
        }
    }

    if (curr.*.ratelimit_scope.len == 0 and prev.*.ratelimit_scope.len > 0) {
        curr.*.ratelimit_scope = prev.*.ratelimit_scope;
    }

    if (curr.*.ratelimit_rate > 0 and curr.*.ratelimit_scope.len == 0) {
        return initRateLimitScope(cf, curr);
    }

    return conf.NGX_CONF_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    var lookup_zone_name = ngx_string("nftset_lookup_cache_zone");
    const lookup_zone = shm.ngx_shared_memory_add(cf, &lookup_zone_name, NFTSET_SHARED_CACHE_ZONE_SIZE, @constCast(&ngx_http_nftset_module));
    if (lookup_zone == core.nullptr(core.ngx_shm_zone_t)) return NGX_ERROR;
    lookup_zone.*.init = ngx_http_nftset_lookup_cache_zone_init;
    ngx_http_nftset_lookup_cache_zone = lookup_zone;

    var zone_name = ngx_string("nftset_ratelimit_zone");
    const zone = shm.ngx_shared_memory_add(cf, &zone_name, NFTSET_RATELIMIT_ZONE_SIZE, @constCast(&ngx_http_nftset_module));
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return NGX_ERROR;
    zone.*.init = ngx_http_nftset_ratelimit_zone_init;
    ngx_http_nftset_ratelimit_zone = zone;

    // Register $nftset_result and $nftset_matched_set variables
    var vs = [_]http.ngx_http_variable_t{
        http.ngx_http_variable_t{
            .name = ngx_string("nftset_result"),
            .set_handler = null,
            .get_handler = ngx_http_nftset_result_variable,
            .data = 0,
            .flags = http.NGX_HTTP_VAR_NOCACHEABLE,
            .index = 0,
        },
        http.ngx_http_variable_t{
            .name = ngx_string("nftset_matched_set"),
            .set_handler = null,
            .get_handler = ngx_http_nftset_matched_set_variable,
            .data = 0,
            .flags = http.NGX_HTTP_VAR_NOCACHEABLE,
            .index = 0,
        },
    };
    for (&vs) |*v| {
        if (http.ngx_http_add_variable(cf, &v.name, v.flags)) |x| {
            x.*.get_handler = v.get_handler;
            x.*.data = v.data;
        }
    }

    // Register access phase handler
    const cmcf = core.castPtr(
        ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    var handlers = NArray(ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_ACCESS_PHASE].handlers,
    );
    const h = handlers.append() catch return NGX_ERROR;
    h.* = ngx_http_nftset_access_handler;

    return NGX_OK;
}

// ──────────────────────────────────────────────────────────────────────────
// Directive table
// ──────────────────────────────────────────────────────────────────────────

// All directives accept http{} / server{} / location{} contexts so settings
// can be inherited: http → server → location via merge_loc_conf.
const CTX = conf.NGX_HTTP_MAIN_CONF | conf.NGX_HTTP_SRV_CONF | conf.NGX_HTTP_LOC_CONF;

export const ngx_http_nftset_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("nftset"),
        .type = CTX | conf.NGX_CONF_FLAG,
        .set = conf.ngx_conf_set_flag_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "enabled"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_table"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "table"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_set"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_nftset_set,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_sets"),
        .type = CTX | conf.NGX_CONF_1MORE,
        .set = ngx_conf_set_nftset_sets,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_blacklist"),
        .type = CTX | conf.NGX_CONF_1MORE,
        .set = ngx_conf_set_nftset_blacklist,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_whitelist"),
        .type = CTX | conf.NGX_CONF_1MORE,
        .set = ngx_conf_set_nftset_whitelist,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_family"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "family"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_deny"),
        .type = CTX | conf.NGX_CONF_FLAG,
        .set = conf.ngx_conf_set_flag_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "deny"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_status"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_num_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "status"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_fail_open"),
        .type = CTX | conf.NGX_CONF_FLAG,
        .set = conf.ngx_conf_set_flag_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "fail_open"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_dryrun"),
        .type = CTX | conf.NGX_CONF_FLAG,
        .set = conf.ngx_conf_set_flag_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "dryrun"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_autoadd"),
        .type = CTX | conf.NGX_CONF_FLAG,
        .set = conf.ngx_conf_set_flag_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "autoadd"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_autoadd_table"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "autoadd_table"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_autoadd_set"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "autoadd_set"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_autoadd_family"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "autoadd_family"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_autoadd_timeout"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_msec_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "autoadd_timeout"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_ratelimit_rate"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_nftset_ratelimit_rate,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_ratelimit_burst"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_nftset_ratelimit_burst,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_ratelimit_status"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_num_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "ratelimit_status"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_autoban_table"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "autoban_table"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_autoban_set"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "autoban_set"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_autoban_family"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_str_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "autoban_family"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_autoban_timeout"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_msec_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "autoban_timeout"),
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("nftset_cache_ttl"),
        .type = CTX | conf.NGX_CONF_TAKE1,
        .set = conf.ngx_conf_set_msec_slot,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = @offsetOf(nftset_loc_conf, "cache_ttl"),
        .post = null,
    },
    conf.ngx_null_command,
};

export const ngx_http_nftset_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

// Module export — set init_process/exit_process for the per-worker Netlink socket.
pub export var ngx_http_nftset_module = blk: {
    var m = ngx.module.make_module(
        @constCast(&ngx_http_nftset_commands),
        @constCast(&ngx_http_nftset_module_ctx),
    );
    m.init_process = nftset_init_process;
    m.exit_process = nftset_exit_process;
    break :blk m;
};

// Tests
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "parse_set_spec accepts valid table:set syntax" {
    const parsed = parse_set_spec("filter:blocklist") orelse return error.TestUnexpectedResult;
    try expectEqualStrings("filter", parsed.table);
    try expectEqualStrings("blocklist", parsed.set_name);
}

test "parse_set_spec rejects malformed values" {
    try expect(parse_set_spec("noscope") == null);
    try expect(parse_set_spec(":set") == null);
    try expect(parse_set_spec("table:") == null);
}

test "parse_set_spec: plain name (no colon) returns null — backward compat path" {
    try expect(parse_set_spec("blocklist") == null);
}

test "parse_set_spec: combined token sets both table and set fields" {
    const parsed = parse_set_spec("nginz_test:blocklist") orelse return error.TestUnexpectedResult;
    try expectEqualStrings("nginz_test", parsed.table);
    try expectEqualStrings("blocklist", parsed.set_name);
}

test "table_family_num maps configured families" {
    try expectEqual(@as(u8, NFPROTO_IPV4), table_family_num("ip"));
    try expectEqual(@as(u8, NFPROTO_IPV6), table_family_num("ip6"));
    try expectEqual(@as(u8, NFPROTO_INET), table_family_num("inet"));
    try expectEqual(@as(u8, NFPROTO_INET), table_family_num("unexpected"));
}

test "parseRateLimitRate accepts valid formats and rejects malformed ones" {
    try expectEqual(@as(ngx_uint_t, 10), parseRateLimitRate("10") orelse return error.TestUnexpectedResult);
    try expectEqual(@as(ngx_uint_t, 25), parseRateLimitRate("25r/s") orelse return error.TestUnexpectedResult);
    try expect(parseRateLimitRate("") == null);
    try expect(parseRateLimitRate("r/s") == null);
    try expect(parseRateLimitRate("10r/sx") == null);
    try expect(parseRateLimitRate("10foo") == null);
}

test "buildCacheKey encodes family ip and set identity" {
    var key_buf: [NFTSET_CACHE_KEY_MAX]u8 = undefined;
    const ip = [_]u8{ 0x7f, 0x00, 0x00, 0x01 };
    const key = buildCacheKey(&key_buf, "nginz_test", "blocklist", NFPROTO_IPV4, &ip) orelse return error.TestUnexpectedResult;

    try expectEqual(@as(u8, NFPROTO_IPV4), key[0]);
    try expectEqual(@as(u8, 4), key[1]);
    try expect(std.mem.eql(u8, key[2..6], &ip));
}

test "buildCacheKey differs across sets" {
    var first_buf: [NFTSET_CACHE_KEY_MAX]u8 = undefined;
    var second_buf: [NFTSET_CACHE_KEY_MAX]u8 = undefined;
    const ip = [_]u8{ 0x7f, 0x00, 0x00, 0x01 };
    const first = buildCacheKey(&first_buf, "nginz_test", "blocklist", NFPROTO_IPV4, &ip) orelse return error.TestUnexpectedResult;
    const second = buildCacheKey(&second_buf, "nginz_test", "allowlist", NFPROTO_IPV4, &ip) orelse return error.TestUnexpectedResult;

    try expect(!std.mem.eql(u8, first, second));
}

test "build_query emits get setelem message" {
    var buf: [512]u8 = undefined;
    const ip = [_]u8{ 0x7f, 0x00, 0x00, 0x01 };
    const msg_len = build_query(&buf, 42, NFPROTO_IPV4, "nginz_test", "blocklist", &ip) orelse return error.TestUnexpectedResult;
    const nlh = readStruct(Nlmsghdr, &buf, 0);
    const nfgen = readStruct(Nfgenmsg, &buf, NLMSG_HDR_SZ);

    try expectEqual(msg_len, nlh.len);
    try expectEqual(@as(u16, (NFNL_SUBSYS_NFTABLES << 8) | NFT_MSG_GETSETELEM), nlh.type_);
    try expectEqual(@as(u16, NLM_F_REQUEST | NLM_F_ACK), nlh.flags);
    try expectEqual(@as(u32, 42), nlh.seq);
    try expectEqual(@as(u8, NFPROTO_IPV4), nfgen.family);
    try expectEqual(@as(u8, NFNETLINK_V0), nfgen.version);
}

test "build_getset_query emits get set message" {
    var buf: [256]u8 = undefined;
    const msg_len = build_getset_query(&buf, 77, NFPROTO_IPV4, "nginz_test", "blocklist") orelse return error.TestUnexpectedResult;
    const nlh = readStruct(Nlmsghdr, &buf, 0);
    const nfgen = readStruct(Nfgenmsg, &buf, NLMSG_HDR_SZ);
    const msg_slice = buf[0..msg_len];

    try expectEqual(msg_len, nlh.len);
    try expectEqual(@as(u16, (NFNL_SUBSYS_NFTABLES << 8) | NFT_MSG_GETSET), nlh.type_);
    try expectEqual(@as(u16, NLM_F_REQUEST | NLM_F_ACK), nlh.flags);
    try expectEqual(@as(u32, 77), nlh.seq);
    try expectEqual(@as(u8, NFPROTO_IPV4), nfgen.family);
    try expect(std.mem.indexOf(u8, msg_slice, "nginz_test") != null);
    try expect(std.mem.indexOf(u8, msg_slice, "blocklist") != null);
}

test "build_add_query emits new setelem message with timeout" {
    var buf: [512]u8 = undefined;
    const ip = [_]u8{ 0x7f, 0x00, 0x00, 0x01 };
    const msg_len = build_add_query(&buf, 7, NFPROTO_IPV4, "nginz_test", "honeypot_timeout", &ip, 1200) orelse return error.TestUnexpectedResult;
    const nlh = readStruct(Nlmsghdr, &buf, 0);
    const nfgen = readStruct(Nfgenmsg, &buf, NLMSG_HDR_SZ);
    const msg_slice = buf[0..msg_len];

    try expectEqual(msg_len, nlh.len);
    try expectEqual(@as(u16, (NFNL_SUBSYS_NFTABLES << 8) | NFT_MSG_NEWSETELEM), nlh.type_);
    try expectEqual(@as(u16, NLM_F_REQUEST | NLM_F_CREATE | NLM_F_ACK), nlh.flags);
    try expectEqual(@as(u8, NFPROTO_IPV4), nfgen.family);
    try expect(std.mem.indexOf(u8, msg_slice, "nginz_test") != null);
    try expect(std.mem.indexOf(u8, msg_slice, "honeypot_timeout") != null);
    try expect(std.mem.indexOf(u8, msg_slice, &[_]u8{ 0x7f, 0x00, 0x00, 0x01 }) != null);
    try expect(std.mem.indexOf(u8, msg_slice, &std.mem.toBytes(std.mem.nativeToBig(u64, 1200))) != null);
}

test "build_batch_marker emits nftables batch control message" {
    var buf: [20]u8 = undefined;
    const msg_len = build_batch_marker(&buf, 9, NFNL_MSG_BATCH_BEGIN);
    const nlh = readStruct(Nlmsghdr, &buf, 0);
    const nfgen = readStruct(Nfgenmsg, &buf, NLMSG_HDR_SZ);

    try expectEqual(@as(usize, NLMSG_HDR_SZ + NFGENMSG_SZ), msg_len);
    try expectEqual(@as(u16, NFNL_MSG_BATCH_BEGIN), nlh.type_);
    try expectEqual(@as(u16, NLM_F_REQUEST), nlh.flags);
    try expectEqual(@as(u32, 9), nlh.seq);
    try expectEqual(@as(u8, 0), nfgen.family);
    try expectEqual(std.mem.nativeToBig(u16, NFNL_SUBSYS_NFTABLES), nfgen.res_id);
}

test "cacheStore and cacheLookup roundtrip membership" {
    nftset_cache = std.mem.zeroes([NFTSET_CACHE_SIZE]CacheEntry);

    var key_buf: [NFTSET_CACHE_KEY_MAX]u8 = undefined;
    const ip = [_]u8{ 0x7f, 0x00, 0x00, 0x01 };
    const key = buildCacheKey(&key_buf, "nginz_test", "blocklist", NFPROTO_IPV4, &ip) orelse return error.TestUnexpectedResult;

    cacheStore(key, .in_set, 100, 50);

    switch (cacheLookup(key, 120)) {
        .hit => |membership| try expectEqual(CacheMembership.in_set, membership),
        .miss => return error.TestUnexpectedResult,
    }

    switch (cacheLookup(key, 151)) {
        .hit => return error.TestUnexpectedResult,
        .miss => {},
    }
}

test "nftset module" {}

fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
    try expect(std.mem.eql(u8, expected, actual));
}
