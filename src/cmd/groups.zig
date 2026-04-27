const std = @import("std");
const tool_mod = @import("../tool.zig");
const output = @import("../ui/output.zig");

const help =
    \\Usage: dot groups
    \\
    \\List all tool groups with their tool counts.
    \\
    \\Options:
    \\  --help, -h    Show this help
    \\
    \\Examples:
    \\  dot groups
    \\  dot list -g k8s        # filter list by group
    \\  dot install -g k8s     # install all tools in a group
    \\
;

const GroupDesc = struct { group: tool_mod.Group, desc: []const u8 };

const group_descs = [_]GroupDesc{
    .{ .group = .k8s, .desc = "Kubernetes ecosystem" },
    .{ .group = .cloud, .desc = "Public cloud CLIs" },
    .{ .group = .iac, .desc = "Infrastructure as Code" },
    .{ .group = .containers, .desc = "Container engines" },
    .{ .group = .cm, .desc = "Configuration management" },
    .{ .group = .security, .desc = "Security scanning & secrets" },
    .{ .group = .utils, .desc = "General-purpose CLI utilities" },
    .{ .group = .terminal, .desc = "Terminal & shell UX" },
};

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    tools: []const tool_mod.Tool,
) !void {
    _ = allocator;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            output.printRaw(help);
            return;
        }
    }

    output.printSectionHeader("Groups");
    output.printFmt("\n{s}{s:<16} {s:<7} Description{s}\n", .{ output.bold, "Group", "Tools", output.reset });

    for (group_descs) |gd| {
        var count: usize = 0;
        for (tools) |t| {
            for (t.groups) |g| {
                if (g == gd.group) { count += 1; break; }
            }
        }
        output.printFmt("{s:<16} {d:<7} {s}\n", .{ @tagName(gd.group), count, gd.desc });
    }

    output.printFmt("\n{s}Tip:{s} 'dot list -g <group>'  ·  'dot install -g <group>'\n\n", .{ output.dim, output.reset });
}
