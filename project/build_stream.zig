const std = @import("std");
const common = @import("build_common.zig");
const ArrayList = std.array_list.Managed;

pub fn build_stream(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const stream = b.addLibrary(.{
        .name = "ngx_stream",
        .root_module = b.createModule(.{
            .pic = true,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    var files = ArrayList([]const u8).init(b.allocator);
    defer files.deinit();
    _ = try common.list(b.graph.io, "./submodules/nginx/src/stream", 0, &common.STREAM_BUILD_BUFFER, &files);

    for (common.NGX_INCLUDE_PATH) |p| {
        stream.root_module.addIncludePath(b.path(p));
    }
    stream.root_module.addCSourceFiles(.{
        .files = files.items[0..],
        .flags = &common.C_FLAGS,
    });

    return stream;
}
