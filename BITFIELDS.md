# Nginx C Bitfield vs Zig `packed struct` Layout

## Background

`translate-c` emits each contiguous run of C bitfields as a Zig
`packed struct(uN)`. Zig aligns that struct to its backing integer
(`packed struct(u64)` → 8-byte align, `packed struct(u32)` → 4-byte align),
so when a C bitfield run is preceded by a sub-aligned field, the Zig
struct ends up at a *later* byte than the real C bitfield.

Commit `96632c3` ("important offset issue") found this for
`ngx_http_request_t.count`:

- C: `unsigned count:16;` at byte offset **1202** (packed into the
  4-byte storage unit shared with `port`)
- Zig: `flags0: packed struct(u64) { count: u16, … }` at byte offset
  **1208** (because `packed struct(u64)` is 8-byte aligned and Zig
  inserts 6 padding bytes after `port`)

That mismatch silently corrupted whatever sat at offset 1208 every time
the pgrest module did `r.main.flags0.count +=/-= 1`. The fix in the
commit (raw pointer arithmetic at offset 1202) works around the symptom,
but the binding itself is still wrong, and so are many other bindings
that follow the same pattern. This document catalogues them and the
recommended fixes.

## Root cause in one paragraph

C bitfields are packed into the storage unit of their declared type
(`unsigned int` → 4-byte units) and the compiler is free to share a
storage unit with an immediately preceding non-bitfield if the bits fit.
A Zig `packed struct(uN)` is an opaque integer of N bits with alignment
`N/8`. There is no analogue to C's "pack into the previous unit" — the
struct is just placed at the next aligned position. So:

| preceding field             | C bitfield byte     | `packed struct(u64)` byte | `packed struct(u32)` byte |
| --------------------------- | ------------------- | ------------------------- | ------------------------- |
| u_char (1B at offset X)     | X+1                 | X+7                       | X+3                       |
| in_port_t (2B at offset X)  | X+2                 | X+6                       | X+2                       |
| u32 (4B at offset X)        | X+4                 | X+4                       | X+4                       |
| pointer/u64 (8B at offset X)| X+8                 | X+8                       | X+8                       |

Mismatches happen whenever the preceding field's natural alignment is
smaller than the backing integer's alignment.

## Audit: every `packed struct` in the bindings

These tables come from `grep "packed struct" src/ngx/{ngx,ngx_vx}.zig`
plus inspection of the preceding field. "Risk" is the alignment delta
between Zig and C as inferred from the preceding field type:

- **bug**: known mismatch, verified at runtime
- **likely**: preceding field is narrower than the backing integer
  alignment → Zig will insert padding that C does not
- **ok**: preceding field is at least as wide as the backing integer
  alignment → the struct sits at the same byte in both languages

### `src/ngx/ngx.zig`

| # | Type (Zig)                                  | backing | preceding field         | risk      |
|---|---------------------------------------------|---------|-------------------------|-----------|
|  1| `struct_ngx_file_flags_s`                   | u32     | aio: pointer (8B)       | ok        |
|  2| `struct_ngx_buf_flags_s`                    | u32     | shadow: pointer (8B)    | ok        |
|  3| `struct_ngx_event_flags_s`                  | u32     | data: pointer (8B)      | ok        |
|  4| `struct_ngx_listening_flags_s`              | u32     | worker: ngx_uint_t (8B) | ok        |
|  5| `struct_ngx_ssl_connection_flags_s`         | u32     | early_buf: u_char (1B)  | **likely**|
|  6| `struct_ngx_connection_flags_s`             | u32     | requests: ngx_uint_t    | ok        |
|  7| `ngx_variable_value_flags_t`                | u32     | (first field)           | likely    |
|  8| `ngx_dir_flags_t`                           | u32     | info: struct_stat       | ok        |
|  9| `ngx_process_flags_t`                       | u32     | name: pointer (8B)      | ok        |
| 10| `struct_ngx_output_chain_ctx_flags_s`       | u32     | busy: pointer (8B)      | ok        |
| 11| `ngx_temp_file_flags_t`                     | u32     | access: ngx_uint_t      | ok        |
| 12| `ngx_ext_rename_file_flags_t`               | u32     | fd: ngx_fd_t (4B)       | ok        |
| 13| `ngx_slab_pool_flags_t`                     | u32     | zero: u_char (1B)       | **likely**|
| 14| `ngx_url_flags_t`                           | u32     | family: c_int (4B)      | ok        |
| 15| `struct_ngx_resolver_flags_s`               | u32     | addr_expire_queue: 16B  | ok        |
| 16| `struct_ngx_resolver_ctx_flags_s`           | u32     | timeout: ngx_msec_t (4B)| ok        |
| 17| `ngx_resolver_node_flags_t`                 | u32     | ttl: u32 (4B)           | ok        |
| 18| `ngx_ssl_ticket_key_flags_t`                | u32     | expire: time_t (8B)     | ok        |
| 19| `ngx_open_file_info_flags_t`                | u32     | disable_symlinks_from   | ok        |
| 20| `struct_ngx_cached_open_file_flags_s`       | **u64** | disable_symlinks_from   | ok        |
| 21| `ngx_syslog_peer_flags_t`                   | u32     | logp: pointer (8B)      | ok        |
| 22| `struct_ngx_http_cache_flags_s`             | u32     | wait_event: ngx_event_t | ok        |
| 23| `struct_ngx_peer_connection_flags_s`        | u32     | sid: pointer (8B)       | ok        |
| 24| `struct_ngx_event_pipe_flags_s`             | u32     | thread_task: pointer    | ok        |
| 25| `struct_ngx_http_upstream_flags_s`          | u32     | cleanup: pointer (8B)   | ok        |
| 26| `struct_ngx_http_request_flag0_s`           | **u64** | port: in_port_t (2B)    | **bug**   |
| 27| `struct_ngx_http_request_flag1_s`           | **u64** | flags0 (8B)             | **likely**|
| 28| `struct_ngx_http_request_flag2_s`           | u32     | host_end: pointer (8B)  | ok        |
| 29| `ngx_http_headers_in_flags_t`               | u32     | keep_alive_n: time_t    | ok        |
| 30| `ngx_http_request_body_flags_t`             | u32     | post_handler: pointer   | ok        |
| 31| `struct_ngx_http_addr_conf_flags_s`         | u32     | virtual_names: pointer  | ok        |
| 32| `ngx_http_connection_flags_t`               | u32     | keepalive_timeout (4B)  | ok        |
| 33| `ngx_http_script_engine_flags_t`            | u32     | args: pointer           | ok        |
| 34| `ngx_http_script_compile_flags_t`           | u32     | main: pointer           | ok        |
| 35| `ngx_http_compile_complex_value_flags_t`    | u32     | complex_value: pointer  | ok        |
| 36| `ngx_http_script_regex_code_flags_t`        | u32     | next: usize             | ok        |
| 37| `ngx_http_script_regex_end_code_flags_t`    | u32     | code: pointer           | ok        |
| 38| `ngx_http_upstream_server_flags_t`          | u32     | down: ngx_uint_t        | ok        |
| 39| `ngx_http_upstream_conf_flags_t`            | u32     | store_values: pointer   | ok        |
| 40| `ngx_http_upstream_headers_in_flags_t`      | u32     | last_modified_time      | ok        |
| 41| `struct_ngx_http_upstream_rr_peer_flags_s`  | u32     | ssl_session_len: c_int  | ok        |
| 42| `struct_ngx_http_upstream_rr_peers_flags_s` | u32     | tries: ngx_uint_t       | ok        |
| 43| `struct_ngx_http_core_loc_conf_flags_s`     | u32     | regex: pointer          | ok        |
| 44| `ngx_http_listen_opt_flags_t`               | u32     | addr_text: ngx_str_t    | ok        |
| 45| `ngx_http_core_srv_conf_flags_t`            | u32     | underscores_in_headers  | ok        |
| 46| `ngx_http_conf_addr_flags_t`                | u32     | opt: ngx_http_listen_opt_t | ok      |
| 47| `ngx_http_file_cache_node_flags_t`          | **u64** | key: [8]u_char (1-aligned) | **likely**|

### `src/ngx/ngx_vx.zig` (manual definitions, not translate-c)

| # | Type (Zig)                            | backing | preceding field     | risk |
|---|---------------------------------------|---------|---------------------|------|
| 48| `ngx_http_v2_state_flags_s`           | u32     | padding: usize      | ok   |
| 49| `ngx_http_v2_connection_flags_s`      | u32     | lingering_time      | ok   |
| 50| `ngx_http_v2_stream_flags_s`          | u32     | pool: pointer       | ok   |
| 51| `ngx_http_v2_out_frame_flags_s`       | u32     | length: usize       | ok   |
| 52| `ngx_http_v3_session_flags_s`         | u32     | payload_bytes: off_t| ok   |
| 53| `ngx_stream_upstream_server_flags_s`  | u32     | down: ngx_uint_t    | ok   |
| 54| `ngx_stream_upstream_flags_s`         | u32     | state: pointer      | ok   |
| 55| `ngx_stream_upstream_rr_peer_flags_s` | u32     | (not used)          | n/a  |
| 56| `ngx_stream_upstream_rr_peers_flags_s`| u32     | tries: ngx_uint_t   | ok   |
| 57| `ngx_stream_core_srv_conf_flags_s`    | u32     | proxy_protocol_timeout | ok|
| 58| `ngx_stream_session_flags_s`          | u32     | status: ngx_uint_t  | ok   |

### Confirmed C offsets (probe via `memset(0); a.field=1; scan`)

Run from a probe linked against the real nginx headers:

```
TYPE                                     FIRST_BITFIELD                    OFF
---------------------------------------------------------------------------------
ngx_http_request_t                       count                            1202
ngx_http_request_t                       gzip_vary                        1210
ngx_http_request_t                       http_minor                       1400
ngx_http_addr_conf_t                     ssl                                16
ngx_connection_t                         buffered                          232
ngx_listening_t                          open                              328
ngx_buf_t                                temporary                          72
ngx_event_t                              write                               8
ngx_http_upstream_t                      store                            1088
ngx_resolver_ctx_t                       async                             200
ngx_http_upstream_conf_t                 store                             440
ngx_http_upstream_headers_in_t           connection_close                  304
ngx_http_request_body_t                  filter_need_buffering              72
ngx_http_core_loc_conf_t                 lmt_excpt                          40
ngx_http_listen_opt_t                    set                                32
ngx_http_core_srv_conf_t                 listen                            160
```

Zig view of the same fields (computed from
`@offsetOf(parent, "flags") + @bitOffsetOf(Packed, sub)/8`) is currently
inferred from the binding by hand. The four with `risk = bug/likely` in
the table need to be filled in by the extended check-layout (see
"Verification" below). The known divergence:

```
ngx_http_request_t.count       C:1202   Zig:1208   delta=+6   (packed struct(u64) after u16 port)
ngx_http_request_t.gzip_vary   C:1210   Zig:1216   delta=+6   (cascades from flags0)
```

## Fix recipes (apply per-struct)

Three recipes, in decreasing order of preference. Use the simplest one
that produces a layout matching the C side.

### Recipe A — pull out byte-aligned wide bitfields as plain integers

Best when the C bitfield is a whole byte/half/word width (`count:16`,
`http_minor:16`, `buffered:8`). After extraction, the field is just a
regular integer at the right offset and you get the native field
semantics (`r.count = 1` Just Works).

```zig
// Before
flags0: packed struct(u64) {
    count: u16,
    subrequests: u8,
    blocked: u8,
    aio: bool,
    http_state: u4,
    ...
},

// After
count: u16,                       // formerly count:16
subrequests: u8,                  // formerly subrequests:8
blocked: u8,                      // formerly blocked:8
flags_a: packed struct(u32) {     // remaining sub-byte bits, one C storage unit
    aio: u1,
    http_state: u4,
    complex_uri: u1,
    quoted_uri: u1,
    plus_in_uri: u1,
    empty_path_in_uri: u1,
    invalid_header: u1,
    add_uri_to_alias: u1,
    valid_location: u1,
    valid_unparsed_uri: u1,
    uri_changed: u1,
    uri_changes: u4,
    request_body_in_single_buf: u1,
    request_body_in_file_only: u1,
    request_body_in_persistent_file: u1,
    request_body_in_clean_file: u1,
    request_body_file_group_access: u1,
    request_body_file_log_level: u3,
    request_body_no_buffering: u1,
    subrequest_in_memory: u1,
    waited: u1,
    cached: u1,
    gzip_tested: u1,
    gzip_ok: u1,
} align(4),
```

Recommended for: `ngx_http_request_t.count` (16), `subrequests` (8),
`blocked` (8), `http_minor` (16), `http_major` (16),
`ngx_connection_t.buffered` (8), `ngx_connection_t.log_error` (3 →
keep in packed since not byte-aligned).

This also lets the pgrest module drop its `main_count_ptr` raw pointer
helper and just do `r.main.*.count +%= 1` again.

### Recipe B — `align(N)` override on the packed struct

Use when the bitfields are all sub-byte and the only problem is the
backing integer is over-aligned for the preceding field. The override
forces Zig to place the packed struct at a smaller alignment so it can
share a unit with the preceding scalar.

```zig
// Before — packed struct(u32) after u_char early_buf:
//   early_buf at offset X (1 byte aligned)
//   flags at offset X+3 (4-byte aligned padding hole)
early_buf: u_char,
flags: packed struct(u32) { ... },

// After
early_buf: u_char,
flags: packed struct(u32) align(1) { ... },
```

For a u16-preceded packed struct (the ngx_http_request_t case if you
keep `count` inside it), use `align(2)`. C will pack starting at offset
X+2; `packed struct(u32) align(2)` places the struct at the same byte.

Recommended for: `struct_ngx_ssl_connection_flags_s` (after u_char),
`ngx_slab_pool_flags_t` (after u_char), and anywhere Recipe A is
overkill.

### Recipe C — drop `packed struct(u64)` to `packed struct(u32)`

The `u64`-backed packed structs in the bindings exist purely because
translate-c picked the smallest backing integer that holds all the bits
in a single C storage unit run. They were never reflecting reality: C
uses **separate** `unsigned int` storage units per 32 bits of bitfields,
not one giant 64-bit unit. Splitting into multiple `packed struct(u32)`
matches the C layout.

```zig
// Before
flags0: packed struct(u64) {
    count: u16,        // first 32 bits — one C storage unit
    subrequests: u8,
    blocked: u8,
    aio: bool,         // next 32 bits — second C storage unit
    http_state: u4,
    ... (more sub-byte bits totalling 32)
},

// After
flags0_a: packed struct(u32) align(2) { count: u16, subrequests: u8, blocked: u8 },
flags0_b: packed struct(u32) align(4) { aio: u1, http_state: u4, ... },
```

This is what Recipe A produces, just keeping `count`/etc. as bitfields
instead of plain integers. Prefer A when fields are byte-multiples
because the access syntax is cleaner.

Recommended for: `struct_ngx_http_request_flag0_s`,
`struct_ngx_http_request_flag1_s`,
`struct_ngx_cached_open_file_flags_s`,
`ngx_http_file_cache_node_flags_t`.

## Verification — extend `tools/check_layout.{c,zig}` to catch the rest

Today the runtime probe at `tools/check_layout.c:204-217` runs only for
`ngx_http_request_t.count`. Generalise it:

1. **C side**: one macro per bitfield, called for every entry in the
   suspect list.

```c
#define PRINT_BITFIELD_OFFSET(type, field) do {                              \
    type a, b;                                                                \
    memset(&a, 0, sizeof a); memset(&b, 0, sizeof b);                         \
    b.field = 1;                                                              \
    size_t o = (size_t)-1;                                                    \
    for (size_t i = 0; i < sizeof a; i++)                                     \
        if (((unsigned char*)&a)[i] != ((unsigned char*)&b)[i]) { o = i; break; } \
    printf("bitfield " #type " " #field " %zu\n", o);                         \
} while (0)
```

Call it for every "first bitfield" in every flag group:

```c
PRINT_BITFIELD_OFFSET(ngx_http_request_t, count);
PRINT_BITFIELD_OFFSET(ngx_http_request_t, gzip_vary);
PRINT_BITFIELD_OFFSET(ngx_http_request_t, http_minor);
PRINT_BITFIELD_OFFSET(ngx_http_addr_conf_t, ssl);
PRINT_BITFIELD_OFFSET(ngx_connection_t, buffered);
PRINT_BITFIELD_OFFSET(ngx_listening_t, open);
PRINT_BITFIELD_OFFSET(ngx_buf_t, temporary);
PRINT_BITFIELD_OFFSET(ngx_event_t, write);
PRINT_BITFIELD_OFFSET(ngx_http_upstream_t, store);
PRINT_BITFIELD_OFFSET(ngx_resolver_ctx_t, async);
PRINT_BITFIELD_OFFSET(ngx_http_upstream_conf_t, store);
PRINT_BITFIELD_OFFSET(ngx_http_upstream_headers_in_t, connection_close);
PRINT_BITFIELD_OFFSET(ngx_http_request_body_t, filter_need_buffering);
PRINT_BITFIELD_OFFSET(ngx_http_core_loc_conf_t, lmt_excpt);
PRINT_BITFIELD_OFFSET(ngx_http_listen_opt_t, set);
PRINT_BITFIELD_OFFSET(ngx_http_core_srv_conf_t, listen);
// ... one per row in the audit table that is not "ok"
```

2. **Zig side**: derive the expected offset from the binding itself, so
   the check fails when the binding diverges from C (not when we forget
   to update a hardcoded number).

```zig
const BitfieldEntry = struct {
    name: []const u8,
    field: []const u8,
    zig_offset: usize,
    note: []const u8,
};

inline fn flag_byte_offset(
    comptime Parent: type,
    comptime flag_field: []const u8,
    comptime sub: []const u8,
) usize {
    const FlagType = @TypeOf(@field(@as(Parent, undefined), flag_field));
    return @offsetOf(Parent, flag_field) + @bitOffsetOf(FlagType, sub) / 8;
}

const bitfield_table = [_]BitfieldEntry{
    .{ .name = "ngx_http_request_t", .field = "count",
       .zig_offset = flag_byte_offset(ngx_http_request_t, "flags0", "count"),
       .note = "bitfield byte offset of count:16" },
    .{ .name = "ngx_http_request_t", .field = "gzip_vary",
       .zig_offset = flag_byte_offset(ngx_http_request_t, "flags1", "gzip_vary"),
       .note = "first bit of flags1 storage unit" },
    // ...
};
```

The comparator that already exists for the `custom` lines just needs to
also match `bitfield ` lines and look entries up in `bitfield_table`.

3. **Expected output after extension, before any fixes**:

```
bitfield ngx_http_request_t.count          C:1202   Zig:1208   MISMATCH (+6)
bitfield ngx_http_request_t.gzip_vary      C:1210   Zig:1216   MISMATCH (+6)
bitfield ngx_http_addr_conf_t.ssl           C:  16   Zig:  16   OK
... (the rest of the table)
```

Each "MISMATCH" is a binding bug. Each "OK" is a free regression
guarantee for future nginx upgrades.

## Phased work plan

### Phase 0 — already done

- Document this (this file).
- `96632c3` worked around `r->main->count` via raw pointer arithmetic.
  The workaround stays until Phase 2 fixes the binding itself.

### Phase 1 — extend check-layout (one PR)

- Add `PRINT_BITFIELD_OFFSET` macro and probes for every entry in the
  audit table (≈ 30 distinct flag groups when one probe per group).
- Add `flag_byte_offset` helper and `bitfield_table` to
  `tools/check_layout.zig`.
- Extend the comparator to parse `bitfield ` lines.
- Run `zig build check-layout`. Record every MISMATCH.
- Land the extension even though some entries fail — the failures are
  what we want to track.

### Phase 2 — fix bindings, one struct per PR

Priority order (most-used first):

1. **`ngx_http_request_t`** — Recipe A for `count`, `subrequests`,
   `blocked`, `http_minor`, `http_major`; Recipe C for the remaining
   sub-byte runs. This lets pgrest drop the `main_count_ptr` workaround.
2. **`ngx_http_request_t.flags1`** — same recipes.
3. **`ngx_ssl_connection_t`** — Recipe B (`align(1)`).
4. **`ngx_slab_pool_t`** — Recipe B (`align(1)`).
5. **`ngx_http_file_cache_node_t`** — Recipe C.
6. **`ngx_cached_open_file_t`** — Recipe C.

After each PR, `zig build check-layout` should turn one MISMATCH into
OK. Keep all the workaround code (e.g. `main_count_ptr` in pgrest)
until the corresponding binding is fixed AND check-layout is green for
that field; then remove the workaround in the same PR.

### Phase 3 — keep it that way

`check-layout` is already part of CI per `build.zig`. The new bitfield
checks make sure the next nginx version bump (1.32, 1.34, ...) cannot
silently shift a bitfield without our noticing — a MISMATCH there will
fail the build before any module gets to corrupt memory.

## Field-semantic access — the user-visible payoff

After Recipe A is applied to `ngx_http_request_t`:

```zig
// Today (commit 96632c3 workaround)
main_count_inc(r.*.main);                 // raw pointer + 1202

// After Phase 2
r.*.main.*.count +%= 1;                   // native field, no helpers
```

For sub-byte bitfields (kept in `packed struct(u32) align(N)`):

```zig
r.*.flags_a.internal = true;              // C: r->internal = 1
if (r.*.flags_a.keepalive) { ... }        // C: if (r->keepalive)
```

Same syntax as C. No helpers, no raw pointer math, and the byte offset
is guaranteed correct by check-layout.
