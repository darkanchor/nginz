const std = @import("std");
const common = @import("build_common.zig");
const ArrayList = std.array_list.Managed;

pub fn build_http(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const http = b.addLibrary(.{
        .name = "ngx_http",
        .root_module = b.createModule(.{
            .pic = true,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    var files = ArrayList([]const u8).init(b.allocator);
    defer files.deinit();
    const n = try common.list(b.graph.io, "./submodules/nginx/src/http", 0, &common.BUILD_BUFFER, &files);
    _ = try common.list(b.graph.io, "./submodules/nginx/src/event/quic", n, &common.BUILD_BUFFER, &files);

    for (common.NGX_INCLUDE_PATH) |p| {
        http.root_module.addIncludePath(b.path(p));
    }
    http.root_module.addCSourceFiles(.{
        .files = files.items[0..],
        .flags = &common.C_FLAGS,
    });

    // b.installArtifact(http);
    return http;
}
