const std = @import("std");
const cli = @import("cli.zig");
const env = @import("env.zig");
const io_ctx = @import("io_ctx.zig");

pub fn main(init: std.process.Init) !void {
    env.init(init.minimal.environ);
    io_ctx.init(init.io);

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    cli.run(init.gpa, argv) catch |e| switch (e) {
        // CommandFailed means the command already printed its own error message.
        // Exit with code 1 without printing anything — avoids the double "error: Foo" line.
        error.CommandFailed => std.process.exit(1),
        else => return e,
    };
}

// Pull in all tests from submodules
test {
    _ = @import("env.zig");
    _ = @import("io_ctx.zig");
    _ = @import("platform.zig");
    _ = @import("tool.zig");
    _ = @import("archive.zig");
    _ = @import("repository/loader.zig");
    _ = @import("validate.zig");
    _ = @import("util.zig");
    _ = @import("state.zig");
    _ = @import("shell.zig");
    _ = @import("ui/output.zig");
    _ = @import("ui/progress.zig");
    _ = @import("cmd/install.zig");
    _ = @import("cmd/upgrade.zig");
    _ = @import("cmd/uninstall.zig");
    _ = @import("cmd/list.zig");
    _ = @import("cmd/repository.zig");
    _ = @import("cmd/doctor.zig");
    _ = @import("cmd/groups.zig");
    _ = @import("cmd/info.zig");
    _ = @import("cmd/outdated.zig");
    _ = @import("cmd/search.zig");
    _ = @import("cmd/pin.zig");
    _ = @import("cmd/unpin.zig");
    _ = @import("cli.zig");
}
