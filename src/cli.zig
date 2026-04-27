const std = @import("std");
const state_mod = @import("state.zig");
const install_cmd = @import("cmd/install.zig");
const list_cmd = @import("cmd/list.zig");
const doctor_cmd = @import("cmd/doctor.zig");
const upgrade_cmd = @import("cmd/upgrade.zig");
const update_cmd = @import("cmd/update.zig");
const uninstall_cmd = @import("cmd/uninstall.zig");
const repository_cmd = @import("cmd/repository.zig");
const info_cmd = @import("cmd/info.zig");
const search_cmd = @import("cmd/search.zig");
const outdated_cmd = @import("cmd/outdated.zig");
const groups_cmd = @import("cmd/groups.zig");
const pin_cmd = @import("cmd/pin.zig");
const unpin_cmd = @import("cmd/unpin.zig");
const output = @import("ui/output.zig");
const repo = @import("repository/loader.zig");
const tool_mod = @import("tool.zig");
const util = @import("util.zig");

const version = @import("version.zig");
const version_str = "dot version " ++ version.current ++ "\n";

const help =
    \\Usage: dot <command> [options]
    \\
    \\Commands:
    \\  doctor      Check system health
    \\  groups      List all tool groups
    \\  info        Show detailed info about a tool
    \\  install     Install a tool or group of tools
    \\  list        List available tools
    \\  outdated    List installed tools with updates available
    \\  pin         Pin a tool to prevent automatic upgrades
    \\  repository  Manage external repositories
    \\  search      Search tools by name or description
    \\  uninstall   Remove a tool
    \\  unpin       Unpin a tool to resume automatic upgrades
    \\  update      Update dot itself to the latest release
    \\  upgrade     Upgrade installed tools
    \\  version     Show version
    \\
    \\Options:
    \\  --help, -h  Show this help
    \\
    \\Run 'dot <command> --help' for more information on a specific command.
    \\
;

pub fn run(allocator: std.mem.Allocator, argv: []const [:0]const u8) !void {
    output.initCaps(); // detect terminal capabilities before any output

    if (argv.len < 2) {
        output.printRaw(help);
        return;
    }

    const command: []const u8 = argv[1];

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        output.printRaw(version_str);
        return;
    }

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        output.printRaw(help);
        return;
    }

    // Convert argv[2..] to [][]const u8
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(allocator);
    for (argv[2..]) |a| {
        try rest.append(allocator, @as([]const u8, a));
    }
    const args = rest.items;

    // Commands that don't need the tool repository
    if (std.mem.eql(u8, command, "repository")) {
        var state = try state_mod.State.init(allocator);
        defer state.deinit();
        return repository_cmd.run(allocator, args, &state);
    }

    if (std.mem.eql(u8, command, "update")) {
        var state = try state_mod.State.init(allocator);
        defer state.deinit();
        return update_cmd.run(allocator, args, &state);
    }

    if (std.mem.eql(u8, command, "pin")) {
        var state = try state_mod.State.init(allocator);
        defer state.deinit();
        return pin_cmd.run(allocator, args, &state);
    }

    if (std.mem.eql(u8, command, "unpin")) {
        var state = try state_mod.State.init(allocator);
        defer state.deinit();
        return unpin_cmd.run(allocator, args, &state);
    }

    // Commands that need the merged tool list (builtins + external)
    var builtin = try repo.loadBuiltinTools(allocator);
    defer builtin.deinit();

    var external = try repo.loadExternalTools(allocator);
    defer external.deinit();

    const tools = try mergeTools(allocator, builtin.tools, external.tools);
    defer allocator.free(tools);

    if (std.mem.eql(u8, command, "doctor")) {
        var state = try state_mod.State.init(allocator);
        defer state.deinit();
        return doctor_cmd.run(allocator, args, &state, tools);
    }

    if (std.mem.eql(u8, command, "list")) {
        var state = try state_mod.State.init(allocator);
        defer state.deinit();
        return list_cmd.run(allocator, args, &state, tools);
    }

    if (std.mem.eql(u8, command, "info")) {
        var state = try state_mod.State.init(allocator);
        defer state.deinit();
        return info_cmd.run(allocator, args, &state, tools);
    }

    if (std.mem.eql(u8, command, "search")) {
        return search_cmd.run(allocator, args, tools);
    }

    if (std.mem.eql(u8, command, "outdated")) {
        var state = try state_mod.State.init(allocator);
        defer state.deinit();
        return outdated_cmd.run(allocator, args, &state, tools);
    }

    if (std.mem.eql(u8, command, "groups")) {
        return groups_cmd.run(allocator, args, tools);
    }

    if (std.mem.eql(u8, command, "install")) {
        var state = try state_mod.State.init(allocator);
        defer state.deinit();
        return install_cmd.run(allocator, args, &state, tools);
    }

    if (std.mem.eql(u8, command, "upgrade")) {
        var state = try state_mod.State.init(allocator);
        defer state.deinit();
        return upgrade_cmd.run(allocator, args, &state, tools);
    }

    if (std.mem.eql(u8, command, "uninstall") or std.mem.eql(u8, command, "remove")) {
        var state = try state_mod.State.init(allocator);
        defer state.deinit();
        return uninstall_cmd.run(allocator, args, &state, tools);
    }

    // Suggest the closest known command if the edit distance is small enough.
    const known = [_][]const u8{ "list", "install", "uninstall", "upgrade", "update", "doctor", "repository", "info", "search", "outdated", "groups", "pin", "unpin", "version" };
    var best_dist: usize = std.math.maxInt(usize);
    var best_cmd: []const u8 = "";
    for (known) |known_cmd| {
        const dist = util.editDistance(command, known_cmd);
        if (dist < best_dist) {
            best_dist = dist;
            best_cmd = known_cmd;
        }
    }
    if (best_dist <= 3) {
        output.printFmt("Unknown command: {s}\nDid you mean '{s}'?\nRun 'dot --help' for usage.\n", .{ command, best_cmd });
    } else {
        output.printFmt("Unknown command: {s}\nRun 'dot --help' for usage.\n", .{command});
    }
}

/// Merge builtin tools with external tools. External tools override builtins with the same ID.
/// Caller owns the returned slice.
fn mergeTools(allocator: std.mem.Allocator, builtins: []const tool_mod.Tool, externals: []const tool_mod.Tool) ![]tool_mod.Tool {
    var list: std.ArrayList(tool_mod.Tool) = .empty;
    defer list.deinit(allocator);

    try list.appendSlice(allocator, builtins);

    for (externals) |ext| {
        var replaced = false;
        for (list.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.id, ext.id)) {
                list.items[i] = ext;
                replaced = true;
                break;
            }
        }
        if (!replaced) try list.append(allocator, ext);
    }

    return list.toOwnedSlice(allocator);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "mergeTools: external overrides builtin with same ID" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const builtin_tools = [_]tool_mod.Tool{
        .{
            .id = "helm",
            .name = "Helm",
            .description = "builtin",
            .groups = &.{.k8s},
            .homepage = "https://helm.sh",
            .version_source = .{ .static = .{ .version = "3.0.0" } },
            .strategy = .{ .direct_binary = .{ .url_template = "https://example.com" } },
        },
        .{
            .id = "kubectl",
            .name = "Kubectl",
            .description = "builtin",
            .groups = &.{.k8s},
            .homepage = "https://k8s.io",
            .version_source = .{ .static = .{ .version = "1.0.0" } },
            .strategy = .{ .direct_binary = .{ .url_template = "https://example.com" } },
        },
    };

    const ext_tools = [_]tool_mod.Tool{
        .{
            .id = "helm",
            .name = "Helm (external)",
            .description = "external override",
            .groups = &.{.k8s},
            .homepage = "https://helm.sh",
            .version_source = .{ .static = .{ .version = "4.0.0" } },
            .strategy = .{ .direct_binary = .{ .url_template = "https://example.com" } },
        },
        .{
            .id = "mytool",
            .name = "MyTool",
            .description = "external only",
            .groups = &.{.utils},
            .homepage = "https://example.com",
            .version_source = .{ .static = .{ .version = "1.0.0" } },
            .strategy = .{ .direct_binary = .{ .url_template = "https://example.com" } },
        },
    };

    const merged = try mergeTools(alloc, &builtin_tools, &ext_tools);
    defer alloc.free(merged);

    // Should have 3 tools: helm (overridden), kubectl, mytool
    try std.testing.expectEqual(@as(usize, 3), merged.len);

    // Find helm — should be the external version
    for (merged) |t| {
        if (std.mem.eql(u8, t.id, "helm")) {
            try std.testing.expectEqualStrings("external override", t.description);
        }
    }
}
