const std = @import("std");

pub const ModuleType = enum {
    HTTP,
    HTTP_FILTER,
    HTTP_AUX_FILTER,
    STREAM,
};

pub const ModuleInfo = struct {
    /// Source file path relative to project root
    source: []const u8,
    /// List of nginx module names exported by this source file
    modules: []const []const u8,
    /// Module types corresponding to each module name
    types: []const ModuleType,
    /// System libraries required (e.g., "pq", "ssl")
    libs: []const []const u8 = &.{},
    /// Whether this module requires cjson
    needs_cjson: bool = false,
    /// Whether this module requires vendored libinjection
    needs_libinjection: bool = false,
};

/// Module definitions with their exported nginx modules
pub const module_infos = [_]ModuleInfo{
    // Core modules
    .{
        .source = "src/modules/hello-nginx-module/ngx_http_hello.zig",
        .modules = &.{"ngx_http_hello_module"},
        .types = &.{.HTTP},
    },
    .{
        .source = "src/modules/echoz-nginx-module/ngx_http_echoz.zig",
        .modules = &.{ "ngx_http_echoz_module", "ngx_http_echoz_filter_module" },
        .types = &.{ .HTTP, .HTTP_FILTER },
    },
    .{
        .source = "src/modules/wechatpay-nginx-module/ngx_http_wechatpay.zig",
        .modules = &.{ "ngx_http_wechatpay_module", "ngx_http_wechatpay_filter_module" },
        .types = &.{ .HTTP, .HTTP_FILTER },
        .needs_cjson = true,
    },

    // Data Storage & Upstream Modules
    .{
        .source = "src/modules/pgrest-nginx-module/ngx_http_pgrest.zig",
        .modules = &.{"ngx_http_pgrest_module"},
        .types = &.{.HTTP},
        .libs = &.{"pq"},
        .needs_cjson = true,
    },
    .{
        .source = "src/modules/redis-nginx-module/ngx_http_redis.zig",
        .modules = &.{"ngx_http_redis_module"},
        .types = &.{.HTTP},
    },
    .{
        .source = "src/modules/consul-nginx-module/ngx_http_consul.zig",
        .modules = &.{"ngx_http_consul_module"},
        .types = &.{.HTTP},
        .needs_cjson = true,
    },
    .{
        .source = "src/modules/upstream-balancer-nginx-module/ngx_http_upstream_balancer.zig",
        .modules = &.{"ngx_http_upstream_balancer_module"},
        .types = &.{.HTTP},
    },
    .{
        .source = "src/modules/dynamic-upstreams-nginx-module/ngx_http_dynamic_upstreams.zig",
        .modules = &.{"ngx_http_dynamic_upstreams_module"},
        .types = &.{.HTTP},
    },

    // Security & Auth Modules
    .{
        .source = "src/modules/jwt-nginx-module/ngx_http_jwt.zig",
        .modules = &.{"ngx_http_jwt_module"},
        .types = &.{.HTTP},
        .needs_cjson = true,
    },
    .{
        .source = "src/modules/oidc-nginx-module/ngx_http_oidc.zig",
        .modules = &.{ "ngx_http_oidc_module", "ngx_http_oidc_filter_module" },
        .types = &.{ .HTTP, .HTTP_FILTER },
        .needs_cjson = true,
    },
    .{
        .source = "src/modules/waf-nginx-module/ngx_http_waf.zig",
        .modules = &.{ "ngx_http_waf_module", "ngx_http_waf_filter_module" },
        .types = &.{ .HTTP, .HTTP_FILTER },
        .needs_libinjection = true,
    },
    .{
        .source = "src/modules/acme-nginx-module/ngx_http_acme.zig",
        .modules = &.{"ngx_http_acme_module"},
        .types = &.{.HTTP},
        .needs_cjson = true,
    },
    .{
        .source = "src/modules/jsonschema-nginx-module/ngx_http_jsonschema.zig",
        .modules = &.{"ngx_http_jsonschema_module"},
        .types = &.{.HTTP},
        .needs_cjson = true,
    },

    // Traffic Management Modules
    .{
        .source = "src/modules/healthcheck-nginx-module/ngx_http_healthcheck.zig",
        .modules = &.{"ngx_http_healthcheck_module"},
        .types = &.{.HTTP},
    },
    .{
        .source = "src/modules/canary-nginx-module/ngx_http_canary.zig",
        .modules = &.{"ngx_http_canary_module"},
        .types = &.{.HTTP},
    },
    .{
        .source = "src/modules/ratelimit-nginx-module/ngx_http_ratelimit.zig",
        .modules = &.{"ngx_http_ratelimit_module"},
        .types = &.{.HTTP},
    },
    .{
        .source = "src/modules/requestid-nginx-module/ngx_http_requestid.zig",
        .modules = &.{"ngx_http_requestid_filter_module"},
        .types = &.{.HTTP_FILTER},
    },
    .{
        .source = "src/modules/circuit-breaker-nginx-module/ngx_http_circuit_breaker.zig",
        .modules = &.{"ngx_http_circuit_breaker_module"},
        .types = &.{.HTTP},
    },
    .{
        .source = "src/modules/worker-events-nginx-module/ngx_http_worker_events.zig",
        .modules = &.{"ngx_http_worker_events_module"},
        .types = &.{.HTTP},
    },

    // Advanced Processing Modules
    .{
        .source = "src/modules/graphql-nginx-module/ngx_http_graphql.zig",
        .modules = &.{"ngx_http_graphql_module"},
        .types = &.{.HTTP},
        .needs_cjson = true,
    },
    .{
        .source = "src/modules/transform-nginx-module/ngx_http_transform.zig",
        .modules = &.{"ngx_http_transform_filter_module"},
        .types = &.{.HTTP_FILTER},
        .needs_cjson = true,
    },
    .{
        .source = "src/modules/cache-tags-nginx-module/ngx_http_cache_tags.zig",
        .modules = &.{"ngx_http_cache_tags_filter_module"},
        .types = &.{.HTTP_FILTER},
    },
    .{
        .source = "src/modules/cache-purge-nginx-module/ngx_http_cache_purge.zig",
        .modules = &.{"ngx_http_cache_purge_module"},
        .types = &.{.HTTP},
    },
    .{
        .source = "src/modules/prometheus-nginx-module/ngx_http_prometheus.zig",
        .modules = &.{"ngx_http_prometheus_module"},
        .types = &.{.HTTP},
    },
};

/// Extract module short name from source path
/// e.g., "src/modules/echoz-nginx-module/ngx_http_echoz.zig" -> "echoz"
pub fn getModuleName(source: []const u8) []const u8 {
    // Find the module directory name
    var start: usize = 0;
    var end: usize = 0;
    var slash_count: usize = 0;

    for (source, 0..) |c, i| {
        if (c == '/') {
            slash_count += 1;
            if (slash_count == 2) {
                start = i + 1;
            } else if (slash_count == 3) {
                end = i;
                break;
            }
        }
    }

    // Extract name before "-nginx-module"
    const dir_name = source[start..end];
    const suffix = "-nginx-module";
    if (std.mem.endsWith(u8, dir_name, suffix)) {
        return dir_name[0 .. dir_name.len - suffix.len];
    }
    return dir_name;
}

/// Get the object file base name from source path
/// e.g., "src/modules/echoz-nginx-module/ngx_http_echoz.zig" -> "ngx_http_echoz"
pub fn getObjectBaseName(source: []const u8) []const u8 {
    // Find last slash
    var last_slash: usize = 0;
    for (source, 0..) |c, i| {
        if (c == '/') {
            last_slash = i;
        }
    }

    // Find .zig extension
    const filename = source[last_slash + 1 ..];
    if (std.mem.endsWith(u8, filename, ".zig")) {
        return filename[0 .. filename.len - 4];
    }
    return filename;
}

/// Generate nginx config file content for a module
pub fn generateConfig(info: ModuleInfo, writer: anytype) !void {
    const module_name = getModuleName(info.source);
    const obj_base = getObjectBaseName(info.source);

    try writer.print(
        \\# nginz module: {s}
        \\# Auto-generated config for nginx's ./configure --add-module=
        \\#
        \\# Usage:
        \\#   cd nginx-source
        \\#   ./configure --add-module=/path/to/nginz/zig-out/modules/{s}
        \\#   make
        \\
        \\ngx_addon_name="{s}"
        \\
        \\
    , .{ module_name, module_name, info.modules[0] });

    // Check if using new-style module system
    try writer.writeAll(
        \\if test -n "$ngx_module_link"; then
        \\
    );

    // Write each module
    for (info.modules, info.types) |mod_name, mod_type| {
        const type_str = switch (mod_type) {
            .HTTP => "HTTP",
            .HTTP_FILTER => "HTTP_FILTER",
            .HTTP_AUX_FILTER => "HTTP_AUX_FILTER",
        };

        try writer.print(
            \\    ngx_module_type={s}
            \\    ngx_module_name="{s}"
            \\    ngx_module_srcs=""
            \\
        , .{ type_str, mod_name });
    }

    // Add the pre-compiled object file as a library
    try writer.print(
        \\    ngx_module_libs="$ngx_addon_dir/{s}_module.o"
        \\
    , .{obj_base});

    // Add additional library dependencies
    if (info.needs_cjson) {
        try writer.writeAll(
            \\    ngx_module_libs="$ngx_module_libs $ngx_addon_dir/libcjson.a"
            \\
        );
    }

    if (info.needs_libinjection) {
        try writer.writeAll(
            \\    ngx_module_libs="$ngx_module_libs $ngx_addon_dir/liblibinjection.a"
            \\
        );
    }

    for (info.libs) |lib| {
        try writer.print(
            \\    ngx_module_libs="$ngx_module_libs -l{s}"
            \\
        , .{lib});
    }

    try writer.writeAll(
        \\
        \\    . auto/module
        \\
    );

    // Fallback for old-style configure
    try writer.writeAll(
        \\else
        \\    # Old-style module registration (nginx < 1.9.11)
        \\
    );

    for (info.modules, info.types) |mod_name, mod_type| {
        const var_name = switch (mod_type) {
            .HTTP => "HTTP_MODULES",
            .HTTP_FILTER => "HTTP_FILTER_MODULES",
            .HTTP_AUX_FILTER => "HTTP_AUX_FILTER_MODULES",
        };

        try writer.print(
            \\    {s}="${s} {s}"
            \\
        , .{ var_name, var_name, mod_name });
    }

    try writer.print(
        \\    NGX_ADDON_DEPS="$NGX_ADDON_DEPS $ngx_addon_dir/{s}_module.o"
        \\
    , .{obj_base});

    if (info.needs_cjson) {
        try writer.writeAll(
            \\    CORE_LIBS="$CORE_LIBS $ngx_addon_dir/libcjson.a"
            \\
        );
    }

    if (info.needs_libinjection) {
        try writer.writeAll(
            \\    CORE_LIBS="$CORE_LIBS $ngx_addon_dir/liblibinjection.a"
            \\
        );
    }

    for (info.libs) |lib| {
        try writer.print(
            \\    CORE_LIBS="$CORE_LIBS -l{s}"
            \\
        , .{lib});
    }

    try writer.writeAll(
        \\fi
        \\
    );
}

/// Generate module type strings for new-style config
fn moduleTypeStr(comptime mod_type: ModuleType) []const u8 {
    return switch (mod_type) {
        .HTTP => "HTTP",
        .HTTP_FILTER => "HTTP_FILTER",
        .HTTP_AUX_FILTER => "HTTP_AUX_FILTER",
        .STREAM => "STREAM",
    };
}

/// Generate module variable name for old-style config
fn moduleVarStr(comptime mod_type: ModuleType) []const u8 {
    return switch (mod_type) {
        .HTTP => "HTTP_MODULES",
        .HTTP_FILTER => "HTTP_FILTER_MODULES",
        .HTTP_AUX_FILTER => "HTTP_AUX_FILTER_MODULES",
        .STREAM => "STREAM_MODULES",
    };
}

/// Generate new-style module declarations - each module gets its own . auto/module call
fn genNewStyleDecls(comptime info: ModuleInfo) []const u8 {
    @setEvalBranchQuota(10000);
    const obj_base = comptime getObjectBaseName(info.source);

    comptime {
        var result: []const u8 = "";
        for (info.modules, info.types, 0..) |mod_name, mod_type, i| {
            result = result ++
                "    ngx_module_type=" ++ moduleTypeStr(mod_type) ++ "\n" ++
                "    ngx_module_name=\"" ++ mod_name ++ "\"\n" ++
                "    ngx_module_srcs=\"\"\n";

            // Only set libs on first module to avoid duplicates
            if (i == 0) {
                result = result ++
                    "    ngx_module_libs=\"$ngx_addon_dir/" ++ obj_base ++ "_module.o\"\n";
            } else {
                result = result ++
                    "    ngx_module_libs=\"\"\n";
            }

            result = result ++
                "\n" ++
                "    . auto/module\n" ++
                "\n";
        }
        return result;
    }
}

/// Generate old-style module declarations
fn genOldStyleDecls(comptime info: ModuleInfo) []const u8 {
    @setEvalBranchQuota(10000);
    comptime {
        var result: []const u8 = "";
        for (info.modules, info.types) |mod_name, mod_type| {
            const var_name = moduleVarStr(mod_type);
            result = result ++
                "    " ++ var_name ++ "=\"$" ++ var_name ++ " " ++ mod_name ++ "\"\n";
        }
        return result;
    }
}

/// Generate library dependencies for new-style (uses CORE_LIBS after module registration)
fn genLibDeps(comptime info: ModuleInfo) []const u8 {
    @setEvalBranchQuota(10000);
    comptime {
        var result: []const u8 = "";
        for (info.libs) |lib| {
            result = result ++ "    CORE_LIBS=\"$CORE_LIBS -l" ++ lib ++ "\"\n";
        }
        return result;
    }
}

/// Generate library dependencies for old-style
fn genOldLibDeps(comptime info: ModuleInfo) []const u8 {
    @setEvalBranchQuota(10000);
    comptime {
        var result: []const u8 = "";
        for (info.libs) |lib| {
            result = result ++ "    CORE_LIBS=\"$CORE_LIBS -l" ++ lib ++ "\"\n";
        }
        return result;
    }
}

/// Generate config content at comptime for a module
fn generateConfigComptime(comptime info: ModuleInfo) []const u8 {
    @setEvalBranchQuota(10000);
    const module_name = comptime getModuleName(info.source);
    const obj_base = comptime getObjectBaseName(info.source);

    const cjson_old = if (info.needs_cjson)
        "    CORE_LIBS=\"$CORE_LIBS $ngx_addon_dir/libcjson.a\"\n"
    else
        "";

    const libinjection_old = if (info.needs_libinjection)
        "    CORE_LIBS=\"$CORE_LIBS $ngx_addon_dir/liblibinjection.a\"\n"
    else
        "";

    // For new-style, cjson and libs are added after first module registration
    const cjson_new = if (info.needs_cjson)
        "    # Additional libraries for all modules in this addon\n" ++
            "    CORE_LIBS=\"$CORE_LIBS $ngx_addon_dir/libcjson.a\"\n"
    else
        "";

    const libinjection_new = if (info.needs_libinjection)
        "    CORE_LIBS=\"$CORE_LIBS $ngx_addon_dir/liblibinjection.a\"\n"
    else
        "";

    return "# nginz module: " ++ module_name ++ "\n" ++
        "# Auto-generated config for nginx's ./configure --add-module=\n" ++
        "#\n" ++
        "# Usage:\n" ++
        "#   cd nginx-source\n" ++
        "#   ./configure --add-module=/path/to/nginz/zig-out/modules/" ++ module_name ++ "\n" ++
        "#   make\n" ++
        "\n" ++
        "ngx_addon_name=\"" ++ info.modules[0] ++ "\"\n" ++
        "\n" ++
        "if test -n \"$ngx_module_link\"; then\n" ++
        genNewStyleDecls(info) ++
        cjson_new ++
        libinjection_new ++
        genLibDeps(info) ++
        "else\n" ++
        "    # Old-style module registration (nginx < 1.9.11)\n" ++
        genOldStyleDecls(info) ++
        "    NGX_ADDON_DEPS=\"$NGX_ADDON_DEPS $ngx_addon_dir/" ++ obj_base ++ "_module.o\"\n" ++
        cjson_old ++
        libinjection_old ++
        genOldLibDeps(info) ++
        "fi\n";
}

/// Create package build steps
pub fn createPackageSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    nginx: *std.Build.Module,
    cjson_lib: *std.Build.Step.Compile,
    libinjection_lib: *std.Build.Step.Compile,
) !*std.Build.Step {
    const package_step = b.step("package", "Create nginx module packages");
    const ngx_libinjection = b.createModule(.{
        .root_source_file = b.path("src/ngx/ngx_libinjection.zig"),
        .target = target,
        .optimize = optimize,
    });

    inline for (module_infos) |info| {
        const module_name = comptime getModuleName(info.source);
        const obj_base = comptime getObjectBaseName(info.source);

        // Find the module directory path
        const module_dir = comptime blk: {
            var last_slash: usize = 0;
            for (info.source, 0..) |c, i| {
                if (c == '/') {
                    last_slash = i;
                }
            }
            break :blk info.source[0..last_slash];
        };

        // Create the module object
        const obj = b.addObject(.{
            .name = obj_base,
            .root_module = b.createModule(.{
                .pic = true,
                .root_source_file = b.path(info.source),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        obj.root_module.addIncludePath(b.path(module_dir));
        obj.root_module.addImport("ngx", nginx);
        obj.root_module.addImport("ngx_libinjection", ngx_libinjection);
        obj.bundle_compiler_rt = true;

        // Install object file to modules/<name>/
        const install_obj = b.addInstallFile(obj.getEmittedBin(), "modules/" ++ module_name ++ "/" ++ obj_base ++ "_module.o");
        package_step.dependOn(&install_obj.step);

        // If module needs cjson, install libcjson.a
        if (info.needs_cjson) {
            const install_cjson = b.addInstallFile(cjson_lib.getEmittedBin(), "modules/" ++ module_name ++ "/libcjson.a");
            package_step.dependOn(&install_cjson.step);
        }

        if (info.needs_libinjection) {
            const install_libinjection = b.addInstallFile(libinjection_lib.getEmittedBin(), "modules/" ++ module_name ++ "/liblibinjection.a");
            package_step.dependOn(&install_libinjection.step);
        }

        // Generate and install config file
        const config_content = comptime generateConfigComptime(info);
        const gen_config = b.addWriteFiles();
        _ = gen_config.add("config", config_content);
        const install_config = b.addInstallDirectory(.{
            .source_dir = gen_config.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "modules/" ++ module_name,
        });
        package_step.dependOn(&install_config.step);
    }

    return package_step;
}
