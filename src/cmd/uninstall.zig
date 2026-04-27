const std = @import("std");
const tool_mod = @import("../tool.zig");
const state_mod = @import("../state.zig");
const platform = @import("../platform.zig");
const shell_mod = @import("../shell.zig");
const output = @import("../ui/output.zig");
const validate = @import("../validate.zig");
const io_ctx = @import("../io_ctx.zig");
const paths = @import("../paths.zig");
const env = @import("../env.zig");

fn findInTools(id: []const u8, tools: []const tool_mod.Tool) bool {
    for (tools) |t| {
        if (std.mem.eql(u8, t.id, id)) return true;
    }
    return false;
}

const help =
    \\Usage: dot uninstall <tool>
    \\       dot remove <tool>
    \\
    \\Remove a tool installed by dot.
    \\
    \\Arguments:
    \\  <tool>    Tool ID to remove (e.g. helm, kubectl)
    \\
    \\Options:
    \\  --help, -h    Show this help
    \\
    \\What gets removed:
    \\  • Binary at ~/.local/bin/<tool>
    \\  • Shell completion section from the integration file
    \\  • Entry from ~/.config/dot/state.json
    \\
    \\Note: brew-installed tools are not removed from brew, only
    \\      unregistered from dot's state.
    \\
    \\Examples:
    \\  dot uninstall helm
    \\  dot remove terraform
    \\
;

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    state: *state_mod.State,
    tools: []const tool_mod.Tool,
) !void {
    if (args.len == 0) {
        output.printRaw(help);
        return;
    }

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            output.printRaw(help);
            return;
        }
    }

    const tool_id = args[0];

    if (!validate.isValidToolId(tool_id)) {
        output.printError("invalid tool name");
        return;
    }

    if (!findInTools(tool_id, tools)) {
        output.printUnknownTool(tool_id);
        return;
    }

    if (!state.isInstalled(tool_id)) {
        output.printFmt("{s} is not installed\n", .{tool_id});
        return;
    }

    const home = env.getenv("HOME") orelse return error.NoHome;

    // Remove binary from ~/.local/bin/
    const bin_path = try std.fs.path.join(allocator, &.{ home, paths.local_dir, paths.bin_dir, tool_id });
    defer allocator.free(bin_path);
    std.Io.Dir.cwd().deleteFile(io_ctx.get(), bin_path) catch |e| switch (e) {
        error.FileNotFound => {}, // already gone, that's fine
        else => output.printWarning("could not remove binary"),
    };
    output.printStep("Cleanup", output.sym_ok, bin_path);

    // Remove shell integration section from all known shells, not just the active one.
    // A tool may have been installed under a different shell than the one currently running.
    var any_removed = false;
    const all_shells = [_]platform.Shell{ .bash, .zsh, .fish };
    for (all_shells) |sh| {
        const integ_path = std.fs.path.join(allocator, &.{
            home, paths.local_dir, paths.bin_dir, sh.integrationFileName(),
        }) catch continue;
        defer allocator.free(integ_path);
        if (std.Io.Dir.cwd().access(io_ctx.get(), integ_path, .{})) |_| {
            shell_mod.removeSection(sh, tool_id, allocator) catch {};
            any_removed = true;
        } else |_| {}
    }
    if (any_removed) {
        output.printStep("Shell", output.sym_ok, "removed");
    }

    // For system_package installs, dot does not invoke the package manager —
    // print the exact command the user needs to run themselves.
    if (state.tools.get(tool_id)) |entry| {
        if (std.mem.eql(u8, entry.method, tool_mod.method_system_package)) {
            const pm = platform.PackageManager.detect();
            const rm_args = pm.removeArgs();
            if (rm_args.len > 0) {
                var cmd_buf: std.ArrayList(u8) = .empty;
                defer cmd_buf.deinit(allocator);
                for (rm_args, 0..) |arg, i| {
                    if (i > 0) try cmd_buf.append(allocator, ' ');
                    try cmd_buf.appendSlice(allocator, arg);
                }
                try cmd_buf.append(allocator, ' ');
                try cmd_buf.appendSlice(allocator, tool_id);
                output.printCaveats(&.{
                    "dot does not remove system packages. To fully uninstall, run:",
                    cmd_buf.items,
                });
            }
        }
    }

    // Update state
    try state.removeTool(tool_id);

    printToolUninstalled(tool_id);
}

// ─── Uninstall-specific print functions ───────────────────────────────────────

fn printToolUninstalled(id: []const u8) void {
    output.printSectionHeaderFmt("{s} uninstalled", .{id});
    output.printFmt("\n", .{});
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "uninstall: unknown tool is rejected before state check" {
    const tools = [_]tool_mod.Tool{.{
        .id = "helm",
        .name = "Helm",
        .description = "test",
        .groups = &.{.k8s},
        .homepage = "https://helm.sh",
        .version_source = .{ .static = .{ .version = "3.0.0" } },
        .strategy = .{ .direct_binary = .{ .url_template = "https://example.com" } },
    }};
    try std.testing.expect(!findInTools("not-a-tool", &tools));
    try std.testing.expect(findInTools("helm", &tools));
}

test "uninstall: not-installed tool is a no-op on state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..n];
    const state_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/state.json", .{dir_path});
    defer std.testing.allocator.free(state_path);

    var state = try state_mod.State.initAt(std.testing.allocator, state_path);
    defer state.deinit();

    try std.testing.expect(!state.isInstalled("helm"));
    // Calling removeTool on something not in state should not error
    try state.removeTool("helm");
    try std.testing.expect(!state.isInstalled("helm"));
}

test "uninstall: removes tool from state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..n];
    const state_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/state.json", .{dir_path});
    defer std.testing.allocator.free(state_path);

    var state = try state_mod.State.initAt(std.testing.allocator, state_path);
    defer state.deinit();

    try state.addTool("helm", "3.15.0", "github_release", false);
    try std.testing.expect(state.isInstalled("helm"));
    try state.removeTool("helm");
    try std.testing.expect(!state.isInstalled("helm"));
}
