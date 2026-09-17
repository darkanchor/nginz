# Project instructions

Read `CLAUDE.md` for the project's architecture, binding conventions, and build and test commands.

## Zig standard library restrictions

These hard restrictions apply to nginx modules and their wrappers. Standalone Zig daemons and build tooling are excluded. In all Zig code, avoid unnecessary dependence on unstable standard-library APIs, especially `std.Io`.

1. **No `std.Io`.** Use C I/O APIs or nginx's built-in I/O APIs through the project wrappers.
2. **No Zig allocators.** All allocation must use nginx pools with the correct request, configuration, or cache lifetime. Do not use `std.heap` allocators. Containers requiring `std.mem.Allocator` must use the nginx-pool-backed `ngx.core.poolAllocator` adapter. Persistent data must not outlive its pool.
3. **No `std.json` or `std.crypto`.** Use the nginx-pool-backed cJSON wrapper, the SSL bindings, or corresponding APIs exposed by nginx. Avoid `std.hash` except for pure helpers such as Wyhash, which is allowed and should be kept where it preserves existing IDs or formats. Use SSL/nginx APIs for cryptographic hashing. Preserve protocol and persisted-format compatibility.
4. **Zig standard library usage is restricted.** Avoid it unless using pure helpers or C/POSIX bindings, such as `std.mem`, `std.fmt`, `std.c`, and `std.posix`; `std.testing` is allowed for tests. These exceptions do not permit Zig-managed I/O, allocators, JSON, or cryptography. Pure hashing helpers such as Wyhash are allowed.
