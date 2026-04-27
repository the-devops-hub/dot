const std = @import("std");
const state_mod = @import("../state.zig");
const output = @import("../ui/output.zig");
const unpin_cmd = @import("unpin.zig");

const help =
    \\Usage: dot pin <tool>
    \\
    \\Pin a tool at its current version so it is skipped by 'dot upgrade'.
    \\Use 'dot upgrade --force' to upgrade a pinned tool anyway.
    \\
    \\Options:
    \\  --help, -h    Show this help
    \\
    \\Examples:
    \\  dot pin kubectl
    \\  dot unpin kubectl
    \\
;

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    state: *state_mod.State,
) !void {
    _ = allocator;
    var tool_id: ?[]const u8 = null;

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            output.printRaw(help);
            return;
        }
        if (!std.mem.startsWith(u8, a, "-")) tool_id = a;
    }

    const id = tool_id orelse {
        output.printError("no tool specified — usage: dot pin <tool>");
        return;
    };

    const entry = state.tools.getPtr(id) orelse {
        output.printFmt("{s}Error:{s} '{s}' is not installed\n", .{ output.red, output.reset, id });
        return;
    };

    if (entry.pinned) {
        output.printFmt("  {s} is already pinned at {s}\n", .{ id, entry.version });
        return;
    }

    entry.pinned = true;
    try state.save();
    output.printFmt("  Pinned {s} at {s} — it will not be upgraded automatically\n", .{ id, entry.version });
}

// ─── Tests ────────────────────────────────────────────────────────────────────

fn tmpStatePath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const dir = buf[0..n];
    return std.fmt.allocPrint(allocator, "{s}/state.json", .{dir});
}

test "pin: not installed returns without error" {
    output.setRenderModeForTesting(.silent);
    defer output.setRenderModeForTesting(.rich);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpStatePath(std.testing.allocator, tmp);
    defer std.testing.allocator.free(path);
    var state = try state_mod.State.initAt(std.testing.allocator, path);
    defer state.deinit();

    try run(std.testing.allocator, &.{"helm"}, &state);
    try std.testing.expect(!state.isInstalled("helm"));
}

test "pin: sets pinned=true" {
    output.setRenderModeForTesting(.silent);
    defer output.setRenderModeForTesting(.rich);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpStatePath(std.testing.allocator, tmp);
    defer std.testing.allocator.free(path);
    var state = try state_mod.State.initAt(std.testing.allocator, path);
    defer state.deinit();

    try state.addTool("helm", "3.15.0", "github_release", false);
    try std.testing.expect(!state.isPinned("helm"));
    try run(std.testing.allocator, &.{"helm"}, &state);
    try std.testing.expect(state.isPinned("helm"));
}

test "pin: already pinned is idempotent" {
    output.setRenderModeForTesting(.silent);
    defer output.setRenderModeForTesting(.rich);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpStatePath(std.testing.allocator, tmp);
    defer std.testing.allocator.free(path);
    var state = try state_mod.State.initAt(std.testing.allocator, path);
    defer state.deinit();

    try state.addTool("helm", "3.15.0", "github_release", true);
    try run(std.testing.allocator, &.{"helm"}, &state);
    try std.testing.expect(state.isPinned("helm"));
}

test "pin: survives save/load round-trip" {
    output.setRenderModeForTesting(.silent);
    defer output.setRenderModeForTesting(.rich);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpStatePath(std.testing.allocator, tmp);
    defer std.testing.allocator.free(path);

    {
        var state = try state_mod.State.initAt(std.testing.allocator, path);
        defer state.deinit();
        try state.addTool("helm", "3.15.0", "github_release", false);
        try run(std.testing.allocator, &.{"helm"}, &state);
    }
    {
        var state = try state_mod.State.initAt(std.testing.allocator, path);
        defer state.deinit();
        try std.testing.expect(state.isPinned("helm"));
    }
}

test "unpin: sets pinned=false" {
    output.setRenderModeForTesting(.silent);
    defer output.setRenderModeForTesting(.rich);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpStatePath(std.testing.allocator, tmp);
    defer std.testing.allocator.free(path);
    var state = try state_mod.State.initAt(std.testing.allocator, path);
    defer state.deinit();

    try state.addTool("helm", "3.15.0", "github_release", true);
    try std.testing.expect(state.isPinned("helm"));
    try unpin_cmd.run(std.testing.allocator, &.{"helm"}, &state);
    try std.testing.expect(!state.isPinned("helm"));
}

test "unpin: not pinned is idempotent" {
    output.setRenderModeForTesting(.silent);
    defer output.setRenderModeForTesting(.rich);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpStatePath(std.testing.allocator, tmp);
    defer std.testing.allocator.free(path);
    var state = try state_mod.State.initAt(std.testing.allocator, path);
    defer state.deinit();

    try state.addTool("helm", "3.15.0", "github_release", false);
    try unpin_cmd.run(std.testing.allocator, &.{"helm"}, &state);
    try std.testing.expect(!state.isPinned("helm"));
}
