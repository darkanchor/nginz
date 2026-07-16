const std = @import("std");
const common = @import("build_common.zig");

const CHECK_C_FLAGS = common.C_FLAGS ++ [_][]const u8{
    "-D_GNU_SOURCE",
    "-DNGX_STREAM=1",
};

pub fn addCheckLayoutSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    nginx: *std.Build.Module,
    patch_step: *std.Build.Step,
) *std.Build.Step {
    // Step 1: Build the C sizeof checker as a native executable
    const c_checker = b.addExecutable(.{
        .name = "check_layout_c",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    c_checker.root_module.addCSourceFiles(.{
        .files = &.{"tools/check_layout.c"},
        .flags = &CHECK_C_FLAGS,
    });
    for (common.NGX_INCLUDE_PATH) |p| {
        c_checker.root_module.addIncludePath(b.path(p));
    }
    c_checker.root_module.addIncludePath(b.path("submodules/nginx/src/event/quic"));
    c_checker.root_module.addIncludePath(b.path("submodules/nginx/src/http/v2"));
    c_checker.root_module.addIncludePath(b.path("submodules/nginx/src/http/v3"));
    c_checker.root_module.addIncludePath(b.path("submodules/nginx/src/stream"));
    c_checker.root_module.linkSystemLibrary("ssl", .{});
    c_checker.root_module.linkSystemLibrary("crypto", .{});
    c_checker.root_module.linkSystemLibrary("pcre2-8", .{});
    c_checker.step.dependOn(patch_step);

    // Step 2: Run the C checker and capture its output
    const run_c = b.addRunArtifact(c_checker);
    const c_output = run_c.captureStdOut(.{});

    // Step 3: Build the Zig comparator
    const zig_checker = b.addExecutable(.{
        .name = "check_layout_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_layout.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    zig_checker.root_module.addImport("ngx", nginx);

    // Step 4: Run the Zig comparator with the C output file as argument
    const run_zig = b.addRunArtifact(zig_checker);
    run_zig.addFileArg(c_output);

    return &run_zig.step;
}
