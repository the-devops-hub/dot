const std = @import("std");
const state_mod = @import("../state.zig");
const output = @import("../ui/output.zig");

const help =
    \\Usage: dot unpin <tool>
    \\
    \\Unpin a tool so it is included in 'dot upgrade' again.
    \\
    \\Options:
    \\  --help, -h    Show this help
    \\
    \\Examples:
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
        output.printError("no tool specified — usage: dot unpin <tool>");
        return;
    };

    const entry = state.tools.getPtr(id) orelse {
        output.printFmt("{s}Error:{s} '{s}' is not installed\n", .{ output.red, output.reset, id });
        return;
    };

    if (!entry.pinned) {
        output.printFmt("  {s} is not pinned\n", .{id});
        return;
    }

    entry.pinned = false;
    try state.save();
    output.printFmt("  Unpinned {s} — it will be upgraded with 'dot upgrade'\n", .{id});
}
