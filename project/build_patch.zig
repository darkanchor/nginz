const std = @import("std");
const Build = std.Build;
const Step = std.Build.Step;

const Error = error{
    PatchError,
};

var MAKEFILE: []const u8 = "project/nginz.makefile";

fn patchOp(step: *Step, _: Build.Step.MakeOptions) anyerror!void {
    const b = step.owner;
    const result = try std.process.run(b.allocator, b.graph.io, .{
        .argv = &[_][]const u8{ "make", "-f", MAKEFILE },
    });

    defer {
        b.allocator.free(result.stdout);
        b.allocator.free(result.stderr);
    }

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("Patch failed with exit code {}:\n", .{code});
            std.debug.print("STDOUT: {s}\n", .{result.stdout});
            std.debug.print("STDERR: {s}\n", .{result.stderr});
            return Error.PatchError;
        },
        else => {
            std.debug.print("Patch terminated abnormally\n", .{});
            std.debug.print("STDOUT: {s}\n", .{result.stdout});
            std.debug.print("STDERR: {s}\n", .{result.stderr});
            return Error.PatchError;
        },
    }

    // std.debug.print("Patch applied successfully: {s}\n", .{result.stdout});
}

pub fn patchStep(b: *Build, docker: bool) *Step {
    const patch = b.step("patch", "patch nginz");
    if (docker) {
        MAKEFILE = "project/nginz.docker.makefile";
    }
    patch.makeFn = patchOp;

    return patch;
}
