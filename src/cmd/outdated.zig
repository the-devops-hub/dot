const std = @import("std");
const tool_mod = @import("../tool.zig");
const state_mod = @import("../state.zig");
const output = @import("../ui/output.zig");

const help =
    \\Usage: dot outdated
    \\
    \\List installed tools that have a newer version available.
    \\Resolves latest versions from the registry (requires network).
    \\
    \\Options:
    \\  --help, -h    Show this help
    \\
    \\Examples:
    \\  dot outdated
    \\  dot upgrade            # upgrade all outdated tools
    \\
;

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    state: *state_mod.State,
    tools: []const tool_mod.Tool,
) !void {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            output.printRaw(help);
            return;
        }
    }

    const OutdatedEntry = struct {
        name: []const u8,
        installed: []const u8,
        latest: []u8,
        pinned: bool,
    };

    var outdated: std.ArrayList(OutdatedEntry) = .empty;
    defer {
        for (outdated.items) |e| allocator.free(e.latest);
        outdated.deinit(allocator);
    }

    var checked: usize = 0;
    for (tools) |t| {
        const entry = state.tools.get(t.id) orelse continue;
        if (entry.version.len == 0) continue;
        checked += 1;

        const latest = t.version_source.resolve(allocator) catch continue;
        if (std.mem.eql(u8, latest, entry.version)) {
            allocator.free(latest);
            continue;
        }

        try outdated.append(allocator, .{
            .name = t.name,
            .installed = entry.version,
            .latest = latest,
            .pinned = entry.pinned,
        });
    }

    if (outdated.items.len == 0) {
        output.printSectionHeaderFmt("All {d} installed tool{s} are up to date.", .{
            checked, if (checked == 1) @as([]const u8, "") else "s",
        });
        output.printFmt("\n", .{});
        return;
    }

    output.printSectionHeaderFmt("{d} tool{s} have updates available", .{
        outdated.items.len, if (outdated.items.len == 1) @as([]const u8, "") else "s",
    });

    output.printFmt("\n{s}{s:<18} {s:<14} {s:<14} {s}{s}\n", .{
        output.bold, "Tool", "Current", "Latest", "Pinned", output.reset,
    });

    for (outdated.items) |e| {
        const name_trunc = e.name[0..@min(e.name.len, 17)];
        const cur_trunc = e.installed[0..@min(e.installed.len, 13)];
        const lat_trunc = e.latest[0..@min(e.latest.len, 13)];
        if (e.pinned) {
            output.printFmt("{s:<18} {s:<14} {s:<14} {s}{s}{s}\n", .{
                name_trunc, cur_trunc, lat_trunc, output.dim, output.sym_ok, output.reset,
            });
        } else {
            output.printFmt("{s:<18} {s:<14} {s:<14}\n", .{ name_trunc, cur_trunc, lat_trunc });
        }
    }

    output.printFmt("\nRun '{s}dot upgrade{s}' to upgrade all (pinned skipped unless --force).\n\n", .{
        output.bold, output.reset,
    });
}
