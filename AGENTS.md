# Project instructions

Read `CLAUDE.md` for the project's architecture, binding conventions, and build and test commands.

## Zig standard library restrictions

These rules apply to Zig module and wrapper code, including tests:

1. **No `std.Io`.** Use C I/O APIs or nginx's built-in I/O APIs through the project wrappers.
2. **No Zig allocators.** All allocation must use nginx pools with the correct request, configuration, or cache lifetime. Do not use `std.heap` allocators. Containers requiring `std.mem.Allocator` must use the nginx-pool-backed `ngx.core.poolAllocator` adapter. Persistent data must not outlive its pool.
3. **No `std.json`, `std.hash`, or `std.crypto`.** Use the pool-backed cJSON wrapper (`ngx.cjson`), the SSL wrapper (`ngx.ssl`), or the corresponding APIs exposed by nginx.
4. **Zig standard library usage is restricted.** Avoid it unless using pure helpers or C/POSIX bindings, such as `std.mem`, `std.fmt`, `std.c`, and `std.posix`; `std.testing` is allowed for tests. These exceptions do not permit Zig-managed I/O, allocators, JSON, hashing, or cryptography.
