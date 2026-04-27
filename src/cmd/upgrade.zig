const std = @import("std");
const tool_mod = @import("../tool.zig");
const state_mod = @import("../state.zig");
const install_cmd = @import("install.zig");
const output = @import("../ui/output.zig");
const io_ctx = @import("../io_ctx.zig");

pub const UpgradeArgs = struct {
    force: bool = false,
    target: ?[]const u8 = null,
};

pub fn parseUpgradeArgs(args: []const []const u8) UpgradeArgs {
    var result = UpgradeArgs{};
    for (args) |a| {
        if (std.mem.eql(u8, a, "--force")) {
            result.force = true;
        } else if (result.target == null) {
            result.target = a;
        }
    }
    return result;
}

const help =
    \\Usage: dot upgrade [tool|group] [--force]
    \\
    \\Upgrade installed tools to their latest available version.
    \\
    \\Arguments:
    \\  [tool]    Upgrade a single tool (e.g. helm)
    \\  [group]   Upgrade all installed tools in a group (e.g. k8s)
    \\  (none)    Upgrade all installed tools
    \\
    \\Options:
    \\  --force       Also upgrade pinned tools and force reinstall
    \\                even if already at the latest version
    \\  --help, -h    Show this help
    \\
    \\Groups:  k8s, cloud, iac, containers, utils, terminal, all
    \\
    \\Pinning:
    \\  Tools installed with an explicit version (dot install terraform 1.8.0)
    \\  are pinned and skipped by upgrade unless --force is used.
    \\
    \\Examples:
    \\  dot upgrade
    \\  dot upgrade helm
    \\  dot upgrade k8s
    \\  dot upgrade terraform --force
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

    const parsed = parseUpgradeArgs(args);
    const force = parsed.force;
    const target = parsed.target;

    if (target) |name| {
        // Group upgrade: only upgrade installed tools in the group
        if (install_cmd.parseGroup(name)) |group| {
            var candidates: std.ArrayList(tool_mod.Tool) = .empty;
            defer candidates.deinit(allocator);
            for (tools) |t| {
                if (!state.isInstalled(t.id)) continue;
                for (t.groups) |g| {
                    if (g == group) {
                        try candidates.append(allocator, t);
                        break;
                    }
                }
            }
            if (candidates.items.len == 0) return;
            output.printSectionHeaderFmt("Upgrading group '{s}' ({d} installed)", .{ name, candidates.items.len });
            try runBatch(allocator, candidates.items, force, state, tools);
            return;
        }

        // Single tool upgrade: dot upgrade helm
        var found = false;
        for (tools) |t| {
            if (std.mem.eql(u8, t.id, name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            output.printUnknownTool(name);
            return;
        }
        const argv: []const []const u8 = if (force) &.{ name, "--force" } else &.{name};
        try install_cmd.run(allocator, argv, state, tools);
    } else {
        // Upgrade all installed tools — iterate in registry order for determinism
        var candidates: std.ArrayList(tool_mod.Tool) = .empty;
        defer candidates.deinit(allocator);
        for (tools) |t| {
            if (state.isInstalled(t.id)) try candidates.append(allocator, t);
        }

        if (candidates.items.len == 0) {
            output.printRaw("No installed tools found.\n");
            return;
        }

        output.printSectionHeaderFmt("Upgrading {d} installed tool{s}", .{
            candidates.items.len,
            if (candidates.items.len == 1) @as([]const u8, "") else "s",
        });
        try runBatch(allocator, candidates.items, force, state, tools);
    }
}

/// Run a batch upgrade loop over `candidates`, print a summary at the end.
fn runBatch(
    allocator: std.mem.Allocator,
    candidates: []const tool_mod.Tool,
    force: bool,
    state: *state_mod.State,
    tools: []const tool_mod.Tool,
) !void {
    const start_ms = std.Io.Timestamp.now(io_ctx.get(), .real).toMilliseconds();
    var upgraded: usize = 0;
    var already_current: usize = 0;
    var failed: usize = 0;

    for (candidates, 0..) |t, i| {
        install_cmd.printGroupToolSeparator(t.name, i + 1, candidates.len);

        // Snapshot version before the run to detect an actual upgrade.
        const before = if (state.getVersion(t.id)) |v| allocator.dupe(u8, v) catch null else null;
        defer if (before) |b| allocator.free(b);

        const argv: []const []const u8 = if (force) &.{ t.id, "--force" } else &.{t.id};
        install_cmd.run(allocator, argv, state, tools) catch |e| {
            output.printFmt("Failed to upgrade {s}: {s}\n", .{ t.id, @errorName(e) });
            failed += 1;
            continue;
        };

        const after = state.getVersion(t.id);
        const changed = if (before) |b| if (after) |a| !std.mem.eql(u8, b, a) else true else false;
        if (changed) upgraded += 1 else already_current += 1;
    }

    const elapsed_ms: u64 = @intCast(@max(0, std.Io.Timestamp.now(io_ctx.get(), .real).toMilliseconds() - start_ms));
    output.printSummary(upgraded, already_current, failed, elapsed_ms);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "parseUpgradeArgs: no args → upgrade all, no force" {
    const args = parseUpgradeArgs(&.{});
    try std.testing.expect(args.target == null);
    try std.testing.expect(!args.force);
}

test "parseUpgradeArgs: tool name" {
    const args = parseUpgradeArgs(&.{"helm"});
    try std.testing.expectEqualStrings("helm", args.target.?);
    try std.testing.expect(!args.force);
}

test "parseUpgradeArgs: group name" {
    const args = parseUpgradeArgs(&.{"k8s"});
    try std.testing.expectEqualStrings("k8s", args.target.?);
    try std.testing.expect(!args.force);
    // group detection happens in run(), not here — parseGroup("k8s") should return non-null
    try std.testing.expect(install_cmd.parseGroup(args.target.?) != null);
}

test "parseUpgradeArgs: --force flag alone" {
    const args = parseUpgradeArgs(&.{"--force"});
    try std.testing.expect(args.target == null);
    try std.testing.expect(args.force);
}

test "parseUpgradeArgs: tool with --force" {
    const args = parseUpgradeArgs(&.{ "helm", "--force" });
    try std.testing.expectEqualStrings("helm", args.target.?);
    try std.testing.expect(args.force);
}

test "parseUpgradeArgs: --force before tool" {
    const args = parseUpgradeArgs(&.{ "--force", "helm" });
    try std.testing.expectEqualStrings("helm", args.target.?);
    try std.testing.expect(args.force);
}

test "parseUpgradeArgs: group with --force" {
    const args = parseUpgradeArgs(&.{ "iac", "--force" });
    try std.testing.expectEqualStrings("iac", args.target.?);
    try std.testing.expect(args.force);
    try std.testing.expect(install_cmd.parseGroup(args.target.?) != null);
}

test "parseUpgradeArgs: unknown target is not a group" {
    const args = parseUpgradeArgs(&.{"not-a-group"});
    try std.testing.expectEqualStrings("not-a-group", args.target.?);
    try std.testing.expect(install_cmd.parseGroup(args.target.?) == null);
}

test "group upgrade only touches installed tools" {
    // Build a k8s group tool list and verify that a tool NOT in state would be skipped.
    const k8s_tools = [_]tool_mod.Tool{
        .{
            .id = "kubectl",
            .name = "kubectl",
            .description = "test",
            .groups = &.{.k8s},
            .homepage = "https://kubernetes.io",
            .version_source = .{ .static = .{ .version = "1.30.0" } },
            .strategy = .{ .direct_binary = .{ .url_template = "https://example.com" } },
        },
        .{
            .id = "helm",
            .name = "Helm",
            .description = "test",
            .groups = &.{.k8s},
            .homepage = "https://helm.sh",
            .version_source = .{ .static = .{ .version = "3.0.0" } },
            .strategy = .{ .direct_binary = .{ .url_template = "https://example.com" } },
        },
    };
    const group_tools: []const tool_mod.Tool = &k8s_tools;
    try std.testing.expect(group_tools.len > 0);

    // Simulate an empty state — none of the k8s tools are installed.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..n];
    const state_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/state.json", .{dir_path});
    defer std.testing.allocator.free(state_path);

    var state = try state_mod.State.initAt(std.testing.allocator, state_path);
    defer state.deinit();

    // None installed → all would be skipped by the isInstalled() filter.
    var would_upgrade: usize = 0;
    for (group_tools) |t| {
        if (state.isInstalled(t.id)) would_upgrade += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), would_upgrade);

    // Mark one as installed → only that one would be upgraded.
    try state.addTool("helm", "3.0.0", "github_release", false);
    would_upgrade = 0;
    for (group_tools) |t| {
        if (state.isInstalled(t.id)) would_upgrade += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), would_upgrade);
}
