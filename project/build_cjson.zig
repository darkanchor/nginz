const std = @import("std");
const common = @import("build_common.zig");

pub const CJSON_C_FLAGS = [_][]const u8{
    // cJSON needs at least C99 so modern libc math macros (notably musl, but
    // also other strict toolchains) do not trip pedantic extension errors on
    // perfectly valid system-header expansions.
    "-std=c99",
    "-pedantic",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-Wstrict-prototypes",
    "-Wwrite-strings",
    "-Wshadow",
    "-Winit-self",
    "-Wcast-align",
    "-Wformat=2",
    "-Wmissing-prototypes",
    "-Wstrict-overflow=2",
    "-Wcast-qual",
    "-Wundef",
    "-Wswitch-default",
    "-Wconversion",
    "-Wc++-compat",
    "-fstack-protector-strong",
    "-Wcomma",
    "-Wdouble-promotion",
    "-Wparentheses",
    "-Wformat-overflow",
    "-Wunused-macros",
    "-Wmissing-variable-declarations",
    //"-Wused-but-marked-unused",
    "-Wswitch-enum",
    "-fno-sanitize=all",
};

const files = [_][]const u8{
    "src/c/cJSON.c",
};

pub fn build_cjson(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const cjson = b.addLibrary(.{
        .name = "cjson",
        .root_module = b.createModule(.{
            .pic = true,
            .target = target,
            .optimize = common.c_optimize(optimize),
            .link_libc = true,
        }),
    });

    cjson.root_module.addCSourceFiles(.{
        .files = &files,
        .flags = &CJSON_C_FLAGS,
    });

    b.installArtifact(cjson);
    return cjson;
}
