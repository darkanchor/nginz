const std = @import("std");
const package = @import("build_package.zig");

const DEFAULT_SIGNATURE = "8,4,8,0011111111010111011111111111111111";

/// Compile and run a tiny C probe against a configured nginx source tree to
/// extract NGX_MODULE_SIGNATURE.  The probe is written to /tmp, compiled with
/// cc, and executed; stdout is the signature string.
fn computeSignature(allocator: std.mem.Allocator, io: std.Io, nginx_src: []const u8) ![]const u8 {
    const probe_src =
        \\#include <ngx_config.h>
        \\#include <ngx_core.h>
        \\#include <stdio.h>
        \\int main(void) { printf("%s\n", NGX_MODULE_SIGNATURE); return 0; }
    ;

    const probe_c = "/tmp/nginz_sig_probe.c";
    const probe_exe = "/tmp/nginz_sig_probe";

    {
        const f = try std.Io.Dir.createFileAbsolute(io, probe_c, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, probe_src);
    }

    const objs = try std.fs.path.join(allocator, &.{ nginx_src, "objs" });

    const compile_argv = [_][]const u8{
        "cc",
        "-I", try std.fs.path.join(allocator, &.{ nginx_src, "src/core" }),
        "-I", try std.fs.path.join(allocator, &.{ nginx_src, "src/event" }),
        "-I", try std.fs.path.join(allocator, &.{ nginx_src, "src/event/quic" }),
        "-I", try std.fs.path.join(allocator, &.{ nginx_src, "src/http" }),
        "-I", try std.fs.path.join(allocator, &.{ nginx_src, "src/http/v2" }),
        "-I", try std.fs.path.join(allocator, &.{ nginx_src, "src/http/v3" }),
        "-I", try std.fs.path.join(allocator, &.{ nginx_src, "src/os/unix" }),
        "-I", try std.fs.path.join(allocator, &.{ nginx_src, "src/stream" }),
        "-I", objs,
        probe_c, "-o", probe_exe,
    };

    const compile_res = try std.process.run(allocator, io, .{ .argv = &compile_argv });
    defer allocator.free(compile_res.stdout);
    defer allocator.free(compile_res.stderr);
    switch (compile_res.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("dynmod sig_probe compile failed:\n{s}\n", .{compile_res.stderr});
            return error.SigProbeCompileFailed;
        },
        else => return error.SigProbeCompileFailed,
    }

    const run_res = try std.process.run(allocator, io, .{ .argv = &.{probe_exe} });
    defer allocator.free(run_res.stderr);
    errdefer allocator.free(run_res.stdout);
    switch (run_res.term) {
        .exited => |code| if (code != 0) return error.SigProbeRunFailed,
        else => return error.SigProbeRunFailed,
    }

    const sig = std.mem.trim(u8, run_res.stdout, " \n\r\t");
    return try allocator.dupe(u8, sig);
}

/// Register the "dynmod" build step.  Each module in module_infos gets its own
/// .so installed to zig-out/dynmod/<name>/<base>_module.so.
///
/// By default the nginz signature is used, making the .so files loadable by
/// the bundled nginz binary.  Pass -Dnginx-src=/path/to/nginx to produce .so
/// files whose signature matches a separately-built stock nginx binary.
pub fn createDynmodSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    nginx: *std.Build.Module,
    cjson_lib: *std.Build.Step.Compile,
    libinjection_lib: *std.Build.Step.Compile,
    nginx_src: ?[]const u8,
) !*std.Build.Step {
    // nginx is unused here: dynmod builds get their own ngx module so the
    // signature embedded by ngx_opts can differ from the nginz build.
    _ = nginx;

    const dynmod_step = b.step("dynmod", "Build nginx dynamic module .so files (load_module compatible)");

    const signature: []const u8 = if (nginx_src) |src|
        computeSignature(b.allocator, b.graph.io, src) catch |err| blk: {
            std.debug.print("dynmod: signature probe failed ({s}), falling back to default\n", .{@errorName(err)});
            break :blk DEFAULT_SIGNATURE;
        }
    else
        DEFAULT_SIGNATURE;

    const dynmod_opts = b.addOptions();
    dynmod_opts.addOption([]const u8, "nginx_signature", signature);

    // A dedicated ngx module that carries the dynmod signature.
    const dynmod_nginx = b.addModule("ngx_dynmod", .{
        .root_source_file = b.path("src/ngx/nginx.zig"),
        .target = target,
        .optimize = optimize,
    });
    dynmod_nginx.addImport("ngx_opts", dynmod_opts.createModule());

    const ngx_libinjection = b.createModule(.{
        .root_source_file = b.path("src/ngx/ngx_libinjection.zig"),
        .target = target,
        .optimize = optimize,
    });

    inline for (package.module_infos) |info| {
        @setEvalBranchQuota(10000);
        const obj_base = comptime package.getObjectBaseName(info.source);
        const module_name = comptime package.getModuleName(info.source);
        const module_dir = comptime blk: {
            var last_slash: usize = 0;
            for (info.source, 0..) |c, i| {
                if (c == '/') last_slash = i;
            }
            break :blk info.source[0..last_slash];
        };

        // Shared library: Zig module source is the root.
        const so = b.addLibrary(.{
            .name = obj_base,
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .pic = true,
                .root_source_file = b.path(info.source),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        so.root_module.addIncludePath(b.path(module_dir));
        so.root_module.addImport("ngx", dynmod_nginx);
        so.root_module.addImport("ngx_libinjection", ngx_libinjection);
        so.bundle_compiler_rt = true;
        if (info.needs_cjson) so.root_module.linkLibrary(cjson_lib);
        if (info.needs_libinjection) so.root_module.linkLibrary(libinjection_lib);
        for (info.libs) |lib| so.root_module.linkSystemLibrary(lib, .{});

        // Generate a C translation unit that exports ngx_modules[] and
        // ngx_module_names[] — the two symbols nginx's dlopen loader requires.
        var aw: std.Io.Writer.Allocating = .init(b.allocator);
        defer aw.deinit();
        for (info.modules) |mod| {
            try aw.writer.print("extern char {s};\n", .{mod});
        }
        try aw.writer.writeAll("\nvoid *ngx_modules[] = {\n");
        for (info.modules) |mod| {
            try aw.writer.print("    (void *)&{s},\n", .{mod});
        }
        try aw.writer.writeAll("    (void *)0\n};\n");
        try aw.writer.writeAll("\nconst char *ngx_module_names[] = {\n");
        for (info.modules) |mod| {
            try aw.writer.print("    \"{s}\",\n", .{mod});
        }
        try aw.writer.writeAll("    (void *)0\n};\n");

        const wf = b.addWriteFiles();
        const wrap_lazy = wf.add(obj_base ++ "_dynwrap.c", try aw.toOwnedSlice());
        so.root_module.addCSourceFile(.{ .file = wrap_lazy, .flags = &.{} });

        const install_so = b.addInstallFile(
            so.getEmittedBin(),
            "dynmod/" ++ module_name ++ "/" ++ obj_base ++ "_module.so",
        );
        dynmod_step.dependOn(&install_so.step);
    }

    return dynmod_step;
}
