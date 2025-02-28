const std = @import("std");
const common = @import("build_common.zig");
const ArrayList = std.array_list.Managed;

const lib_files = .{
    "submodules/nginx/objs/nginz.c",
};

const os_files = .{
    "submodules/nginx/src/os/unix/ngx_time.c",
    "submodules/nginx/src/os/unix/ngx_recv.c",
    "submodules/nginx/src/os/unix/ngx_send.c",
    "submodules/nginx/src/os/unix/ngx_user.c",
    "submodules/nginx/src/os/unix/ngx_errno.c",
    "submodules/nginx/src/os/unix/ngx_alloc.c",
    "submodules/nginx/src/os/unix/ngx_files.c",
    "submodules/nginx/src/os/unix/ngx_shmem.c",
    "submodules/nginx/src/os/unix/ngx_socket.c",
    "submodules/nginx/src/os/unix/ngx_daemon.c",
    "submodules/nginx/src/os/unix/ngx_dlopen.c",
    "submodules/nginx/src/os/unix/ngx_channel.c",
    "submodules/nginx/src/os/unix/ngx_process.c",
    "submodules/nginx/src/os/unix/ngx_udp_recv.c",
    "submodules/nginx/src/os/unix/ngx_udp_send.c",
    "submodules/nginx/src/os/unix/ngx_thread_id.c",
    "submodules/nginx/src/os/unix/ngx_posix_init.c",
    "submodules/nginx/src/os/unix/ngx_linux_init.c",
    "submodules/nginx/src/os/unix/ngx_readv_chain.c",
    "submodules/nginx/src/os/unix/ngx_setaffinity.c",
    "submodules/nginx/src/os/unix/ngx_thread_cond.c",
    "submodules/nginx/src/os/unix/ngx_writev_chain.c",
    "submodules/nginx/src/os/unix/ngx_setproctitle.c",
    "submodules/nginx/src/os/unix/ngx_thread_mutex.c",
    "submodules/nginx/src/os/unix/ngx_process_cycle.c",
    "submodules/nginx/src/os/unix/ngx_linux_aio_read.c",
    "submodules/nginx/src/os/unix/ngx_udp_sendmsg_chain.c",
    "submodules/nginx/src/os/unix/ngx_linux_sendfile_chain.c",
};

const event_files = .{
    "submodules/nginx/src/event/ngx_event.c",
    "submodules/nginx/src/event/ngx_event_udp.c",
    "submodules/nginx/src/event/ngx_event_pipe.c",
    "submodules/nginx/src/event/ngx_event_timer.c",
    "submodules/nginx/src/event/ngx_event_posted.c",
    "submodules/nginx/src/event/ngx_event_accept.c",
    "submodules/nginx/src/event/ngx_event_connect.c",
    "submodules/nginx/src/event/ngx_event_openssl.c",
    "submodules/nginx/src/event/ngx_event_openssl_cache.c",
    "submodules/nginx/src/event/modules/ngx_epoll_module.c",
    "submodules/nginx/src/event/ngx_event_openssl_stapling.c",
};

pub fn build_core(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const core = b.addLibrary(.{
        .name = "ngx_core",
        .root_module = b.createModule(.{
            .pic = true,
            .target = target,
            .optimize = common.c_optimize(optimize),
            .link_libc = true,
        }),
    });

    var files = ArrayList([]const u8).init(b.allocator);
    defer files.deinit();
    _ = try common.list(b.graph.io, "./submodules/nginx/src/core", 0, &common.BUILD_BUFFER, &files);

    try common.append(&files, &lib_files);
    try common.append(&files, &os_files);
    try common.append(&files, &event_files);

    for (common.NGX_INCLUDE_PATH) |p| {
        core.root_module.addIncludePath(b.path(p));
    }
    core.root_module.addCSourceFiles(.{
        .files = files.items[0..],
        .flags = &common.C_FLAGS,
    });

    // b.installArtifact(core);
    return core;
}
