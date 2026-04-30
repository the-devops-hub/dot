const std = @import("std");
const tool_mod = @import("../tool.zig");
const state_mod = @import("../state.zig");
const platform = @import("../platform.zig");
const shell_mod = @import("../shell.zig");
const output = @import("../ui/output.zig");
const validate = @import("../validate.zig");
const util = @import("../util.zig");
const http = @import("../http.zig");
const progress_mod = @import("../ui/progress.zig");
const io_ctx = @import("../io_ctx.zig");
const paths = @import("../paths.zig");
const env = @import("../env.zig");

const suggestion_distance_threshold = 3;

fn progressCbFn(ctx: *anyopaque, done: u64, total: ?u64) void {
    const bar: *progress_mod.ProgressBar = @ptrCast(@alignCast(ctx));
    bar.update(done, total, "");
}

pub const InstallArgs = struct {
    force: bool = false,
    group_mode: bool = false,
    group_name: []const u8 = "",
    tool_name: []const u8 = "",
    version_arg: ?[]const u8 = null,
};

pub fn parseInstallArgs(args: []const []const u8) InstallArgs {
    var result = InstallArgs{};
    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--force")) {
            result.force = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            idx += 1;
            if (idx < args.len) result.version_arg = args[idx];
        } else if (std.mem.eql(u8, arg, "--group") or std.mem.eql(u8, arg, "-g")) {
            result.group_mode = true;
            idx += 1;
            if (idx < args.len) result.group_name = args[idx];
        } else if (result.tool_name.len == 0 and !result.group_mode) {
            result.tool_name = arg;
        } else if (result.version_arg == null and result.tool_name.len > 0) {
            result.version_arg = arg;
        }
    }
    return result;
}

const help =
    \\Usage: dot install <tool> [version] [--force]
    \\       dot install --group <group> [--force]
    \\
    \\Install a tool from the repository.
    \\
    \\Arguments:
    \\  <tool>              Tool ID to install (e.g. helm, kubectl)
    \\
    \\Options:
    \\  --version, -v <v>   Pin to a specific version (e.g. 1.8.0)
    \\  --group, -g <g>     Install all tools in a group
    \\  --force             Force reinstall, even if already installed
    \\  --help, -h          Show this help
    \\
    \\Pinning:
    \\  Specifying a version pins the tool — it will be skipped by
    \\  'dot upgrade' unless --force is used.
    \\
    \\Examples:
    \\  dot install helm
    \\  dot install terraform --version 1.8.0
    \\  dot install --group k8s
    \\  dot install helm --force
    \\
;

fn printAvailableGroups(tools: []const tool_mod.Tool) void {
    const max_groups = 10;
    const n_fields = @typeInfo(tool_mod.Group).@"enum".fields.len;
    var seen = [_]bool{false} ** n_fields;

    for (tools) |t| {
        for (t.groups) |g| {
            seen[@intFromEnum(g)] = true;
        }
    }

    output.printFmt("\nGroups: ", .{});
    var shown: usize = 0;
    inline for (std.meta.fields(tool_mod.Group)) |field| {
        if (shown >= max_groups) break;
        if (seen[field.value]) {
            if (shown > 0) output.printFmt(", ", .{});
            output.printFmt("{s}", .{field.name});
            shown += 1;
        }
    }
    if (shown > 0) output.printFmt(", all", .{});
    output.printFmt("\n\n", .{});
}

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    state: *state_mod.State,
    tools: []const tool_mod.Tool,
) !void {
    if (args.len == 0) {
        output.printRaw(help);
        printAvailableGroups(tools);
        return;
    }

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            output.printRaw(help);
            printAvailableGroups(tools);
            return;
        }
    }

    const parsed = parseInstallArgs(args);

    const is_group_name = std.mem.eql(u8, parsed.tool_name, "all") or
        parseGroup(parsed.tool_name) != null;

    if (parsed.group_mode or (!parsed.group_mode and is_group_name)) {
        const grp = if (parsed.group_mode) parsed.group_name else parsed.tool_name;
        try installGroup(allocator, grp, parsed.force, state, tools);
    } else if (parsed.tool_name.len > 0) {
        if (!validate.isValidToolId(parsed.tool_name)) {
            output.printError("invalid tool name");
            return;
        }
        if (parsed.version_arg) |v| {
            if (!validate.isValidVersion(v)) {
                output.printError("invalid version string");
                return;
            }
        }
        try installTool(allocator, parsed.tool_name, parsed.version_arg, parsed.force, state, tools);
    } else {
        output.printError("no tool or group specified");
    }
}

fn installGroup(
    allocator: std.mem.Allocator,
    group_name: []const u8,
    force: bool,
    state: *state_mod.State,
    tools: []const tool_mod.Tool,
) !void {
    const is_all = std.mem.eql(u8, group_name, "all");
    var group_tools: std.ArrayList(tool_mod.Tool) = .empty;
    defer group_tools.deinit(allocator);

    if (is_all) {
        try group_tools.appendSlice(allocator, tools);
    } else {
        const group = parseGroup(group_name) orelse {
            printUnknownGroup(group_name);
            return;
        };
        for (tools) |t| {
            for (t.groups) |g| {
                if (g == group) {
                    try group_tools.append(allocator, t);
                    break;
                }
            }
        }
    }

    if (group_tools.items.len == 0) {
        output.printFmt("No tools found in group '{s}'\n", .{group_name});
        return;
    }

    printGroupBanner(group_name, group_tools.items.len);

    for (group_tools.items, 0..) |t, i| {
        printGroupToolSeparator(t.name, i + 1, group_tools.items.len);
        installTool(allocator, t.id, null, force, state, tools) catch |e| {
            printGroupToolError(t.id, e);
        };
    }
}

fn installTool(
    allocator: std.mem.Allocator,
    id: []const u8,
    version_arg: ?[]const u8,
    force: bool,
    state: *state_mod.State,
    tools: []const tool_mod.Tool,
) !void {
    var found: ?tool_mod.Tool = null;
    for (tools) |entry| {
        if (std.mem.eql(u8, entry.id, id)) {
            found = entry;
            break;
        }
    }
    const tool = found orelse {
        output.printUnknownTool(id);
        if (closestTool(id, tools)) |suggestion| {
            output.printFmt("Did you mean '{s}'?\n", .{suggestion});
        }
        return;
    };

    // Resolve version
    var version: []u8 = undefined;
    var version_owned = false;

    if (version_arg) |v| {
        version = try allocator.dupe(u8, v);
        version_owned = true;
    } else {
        version = tool.version_source.resolve(allocator) catch |e| blk: {
            printVersionFetchWarning(@errorName(e));
            break :blk try allocator.dupe(u8, "latest");
        };
        version_owned = true;
    }
    defer if (version_owned) allocator.free(version);

    // Skip pinned tools unless forced
    if (!force and version_arg == null) {
        if (state.isPinned(tool.id)) {
            const pinned_ver = state.getVersion(tool.id) orelse "pinned";
            printPinnedSkip(tool.name, tool.id, pinned_ver);
            return;
        }
    }

    // Check system install (not our ~/.local/bin) — only when dot doesn't already manage this tool.
    // Skip for system_package: those tools intentionally install to system paths, so finding
    // the binary in /usr/bin is expected, not a conflict to warn about.
    const is_sys_pkg = switch (tool.strategy) {
        .system_package => true,
        else => false,
    };
    if (!force and !state.isInstalled(tool.id) and !is_sys_pkg) {
        if (checkSystemInstall(allocator, tool.id)) |sys_path| {
            defer allocator.free(sys_path);
            printSkipSystem(tool.name, tool.id, sys_path, "unknown", version);
            return;
        }
    }

    // Capture installed version before any mutation — used for upgrade display and up-to-date check.
    const installed_ver: ?[]const u8 = state.getVersion(tool.id);

    // Check if already up to date
    if (!force) {
        if (installed_ver) |iv| {
            if (std.mem.eql(u8, iv, version)) {
                // Still regenerate the shell section in case the integration file was lost.
                _ = writeShellIntegration(&tool, allocator, false);
                printAlreadyReady(tool.name, iv, tool.id);
                return;
            }
        }
    }

    const operating_system = platform.OperatingSystem.current();
    const arch = platform.Arch.current();

    // Brew install path: preferred when brew is available and tool declares a formula
    var used_brew = false;
    if (tool.brew_formula) |formula| {
        if (platform.PackageManager.brew.isAvailable()) {
            output.printStep("Brew", output.sym_arrow, formula);
            brewInstall(allocator, formula, force) catch |e| {
                output.printStep("Brew", output.sym_fail, @errorName(e));
                output.printError("brew install failed");
                return error.CommandFailed;
            };
            output.printStep("Brew", output.sym_ok, formula);
            used_brew = true;
        }
    }

    if (!used_brew) {
        // Native install path: download, extract, copy binary
        const home = env.getenv("HOME") orelse paths.fallback_home;
        const bin_dir = try std.fs.path.join(allocator, &.{ home, paths.local_dir, paths.bin_dir });
        defer allocator.free(bin_dir);

        const tmp_dir = try std.fmt.allocPrint(allocator, paths.fallback_home ++ "/dot-{s}-{s}", .{ tool.id, version });
        defer allocator.free(tmp_dir);

        const io = io_ctx.get();
        std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch {};
        defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

        var dl_buf: [256]u8 = undefined;
        const dl_step = if (installed_ver) |old|
            std.fmt.bufPrint(&dl_buf, "Upgrading {s} {s} {s} {s}", .{ tool.name, old, output.sym_arrow, version }) catch "Upgrading"
        else
            std.fmt.bufPrint(&dl_buf, "Installing {s} {s}", .{ tool.name, version }) catch "Installing";
        output.printStep(dl_step, output.sym_ok, "");

        var bar = progress_mod.ProgressBar{};
        var ctx = tool_mod.InstallContext{
            .allocator = allocator,
            .tool_id = tool.id,
            .version = version,
            .operating_system = operating_system,
            .architecture = arch,
            .bin_dir = bin_dir,
            .tmp_dir = tmp_dir,
            .progress = http.ProgressCallback{ .context = &bar, .func = progressCbFn },
        };

        tool.strategy.execute(&ctx) catch |e| {
            bar.finish();
            var status_buf: [32]u8 = undefined;
            const hint: []const u8 = if (e == error.HttpError) switch (http.last_status) {
                404 => "release asset not found — tool may not support your platform",
                403 => "access denied — repository may be private",
                0 => @errorName(e),
                else => std.fmt.bufPrint(&status_buf, "HTTP {d}", .{http.last_status}) catch unreachable,
            } else @errorName(e);
            output.printStep("Installation", output.sym_fail, hint);
            if (e == error.HttpError and http.last_url.len > 0) output.printFmt("  URL: {s}\n", .{http.last_url});
            output.printError("Installation failed");
            return error.CommandFailed;
        };
        bar.finish();
        var inst_buf: [128]u8 = undefined;
        const inst_step = std.fmt.bufPrint(&inst_buf, "Installing {s}", .{tool.name}) catch "Installing";
        output.printStep(inst_step, output.sym_ok, "");
        var bin_path_buf: [512]u8 = undefined;
        const bin_path = std.fmt.bufPrint(&bin_path_buf, "{s}/{s}", .{ bin_dir, tool.id }) catch bin_dir;
        output.printDetail(bin_path);
    }

    // Shell integration (always, regardless of install method)
    const shell_written = writeShellIntegration(&tool, allocator, false);

    // Post-install commands — only on fresh installs, not upgrades (non-fatal)
    if (!state.isInstalled(tool.id) and tool.post_install.len > 0) {
        output.printStep("Post-install", output.sym_arrow, "");
        for (tool.post_install) |cmd| {
            const wrapped = try std.fmt.allocPrint(allocator, "export PATH=\"$HOME/.local/bin:$PATH\"; {s}", .{cmd});
            defer allocator.free(wrapped);
            const result = std.process.run(allocator, io_ctx.get(), .{
                .argv = &.{ "sh", "-c", wrapped },
            }) catch |e| {
                output.printFmt("  {s}{s}{s} {s} ({s})\n", .{ output.red, output.sym_fail, output.reset, cmd, @errorName(e) });
                continue;
            };
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.term == .exited and result.term.exited == 0) {
                output.printFmt("  {s}{s}{s} {s}\n", .{ output.green, output.sym_ok, output.reset, cmd });
            } else {
                output.printFmt("  {s}{s}{s} {s}\n", .{ output.red, output.sym_fail, output.reset, cmd });
            }
        }
    }

    // Post-upgrade commands — only when upgrading an already-installed tool (non-fatal)
    if (state.isInstalled(tool.id) and tool.post_upgrade.len > 0) {
        output.printStep("Post-upgrade", output.sym_arrow, "");
        for (tool.post_upgrade) |cmd| {
            const wrapped = try std.fmt.allocPrint(allocator, "export PATH=\"$HOME/.local/bin:$PATH\"; {s}", .{cmd});
            defer allocator.free(wrapped);
            const result = std.process.run(allocator, io_ctx.get(), .{
                .argv = &.{ "sh", "-c", wrapped },
            }) catch |e| {
                output.printFmt("  {s}{s}{s} {s} ({s})\n", .{ output.red, output.sym_fail, output.reset, cmd, @errorName(e) });
                continue;
            };
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.term == .exited and result.term.exited == 0) {
                output.printFmt("  {s}{s}{s} {s}\n", .{ output.green, output.sym_ok, output.reset, cmd });
            } else {
                output.printFmt("  {s}{s}{s} {s}\n", .{ output.red, output.sym_fail, output.reset, cmd });
            }
        }
    }

    // Update state — pin if the user specified an explicit version
    const method = if (used_brew) tool_mod.method_brew else @tagName(tool.strategy);
    try state.addTool(tool.id, version, method, version_arg != null);

    if (shell_written) printShellReloadHint(platform.Shell.detect());
}

fn guardedCompletion(sh: platform.Shell, id: []const u8, cmd: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return switch (sh) {
        .fish => std.fmt.allocPrint(allocator, "if command -q {s}\n    {s}\nend", .{ id, cmd }),
        .bash, .zsh => std.fmt.allocPrint(allocator, "command -v {s} >/dev/null 2>&1 && {s}", .{ id, cmd }),
        .unknown => allocator.dupe(u8, cmd),
    };
}

/// Build the shell section content for a tool (completions + aliases + delegation).
/// Returns an allocated string, or null if there is nothing to write for this shell.
/// Caller owns the returned slice.
pub fn buildShellSection(t: *const tool_mod.Tool, shell_type: platform.Shell, allocator: std.mem.Allocator) ?[]u8 {
    var section: std.ArrayList(u8) = .empty;
    defer section.deinit(allocator);

    if (t.shell_completions) |completions| {
        if (completions.forShell(shell_type)) |comp_cmd| {
            const guarded = guardedCompletion(shell_type, t.id, comp_cmd, allocator) catch return null;
            defer allocator.free(guarded);
            section.appendSlice(allocator, guarded) catch return null;
        }
    }

    for (t.aliases) |alias_name| {
        if (section.items.len > 0) section.append(allocator, '\n') catch return null;
        const alias_line = std.fmt.allocPrint(allocator, "alias {s}={s}", .{ alias_name, t.id }) catch return null;
        defer allocator.free(alias_line);
        section.appendSlice(allocator, alias_line) catch return null;

        // Delegate completions to the original command so tab-complete works on the alias.
        const comp_delegation: ?[]const u8 = switch (shell_type) {
            .fish => std.fmt.allocPrint(allocator, "\ncomplete -c {s} -w {s}", .{ alias_name, t.id }) catch null,
            .zsh => if (t.shell_completions != null and t.shell_completions.?.zsh_cmd != null)
                std.fmt.allocPrint(allocator, "\ncompdef {s}={s}", .{ alias_name, t.id }) catch null
            else
                null,
            else => null,
        };
        if (comp_delegation) |line| {
            defer allocator.free(line);
            section.appendSlice(allocator, line) catch {};
        }
    }

    if (section.items.len == 0) return null;
    return section.toOwnedSlice(allocator) catch null;
}

fn writeShellIntegration(t: *const tool_mod.Tool, allocator: std.mem.Allocator, print_step: bool) bool {
    const shell_type = platform.Shell.detect();
    if (shell_type == .unknown) return false;
    const section = buildShellSection(t, shell_type, allocator) orelse return false;
    defer allocator.free(section);
    shell_mod.ensureSourced(shell_type, allocator) catch {};
    shell_mod.addSection(shell_type, t.id, section, allocator) catch {};
    if (print_step) output.printStep("Shell", output.sym_ok, shell_type.name());
    return true;
}

fn brewInstall(allocator: std.mem.Allocator, formula: []const u8, force: bool) !void {
    // `brew reinstall` always reinstalls; `brew install` is a no-op if already present
    const brew_cmd: []const u8 = if (force) "reinstall" else "install";
    const result = try std.process.run(allocator, io_ctx.get(), .{
        .argv = &.{ "brew", brew_cmd, formula },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        const msg = std.mem.trim(u8, result.stderr, " \n\r\t");
        if (msg.len > 0) output.printDetail(msg);
        return error.BrewInstallFailed;
    }
}

/// Returns owned path string if tool is found in system PATH outside ~/.local/bin.
fn checkSystemInstall(allocator: std.mem.Allocator, id: []const u8) ?[]u8 {
    const home = env.getenv("HOME") orelse return null;
    const our_path = std.fs.path.join(allocator, &.{ home, paths.local_dir, paths.bin_dir, id }) catch return null;
    defer allocator.free(our_path);

    const found = util.findInPath(allocator, id) orelse return null;
    if (std.mem.eql(u8, found, our_path)) {
        allocator.free(found);
        return null;
    }
    return found;
}

pub fn parseGroup(name: []const u8) ?tool_mod.Group {
    if (std.mem.eql(u8, name, "k8s")) return .k8s;
    if (std.mem.eql(u8, name, "cloud")) return .cloud;
    if (std.mem.eql(u8, name, "iac")) return .iac;
    if (std.mem.eql(u8, name, "containers")) return .containers;
    if (std.mem.eql(u8, name, "utils")) return .utils;
    if (std.mem.eql(u8, name, "terminal")) return .terminal;
    if (std.mem.eql(u8, name, "cm")) return .cm;
    if (std.mem.eql(u8, name, "security")) return .security;
    if (std.mem.eql(u8, name, "dev")) return .dev;
    return null;
}

// ─── Install-specific print functions ─────────────────────────────────────────

fn printPinnedSkip(tool_name: []const u8, tool_id: []const u8, version: []const u8) void {
    output.printFmt("{s}{s}{s} {s}{s}{s} is pinned at {s} — skipping\n", .{ output.cyan, output.sym_pin, output.reset, output.bold, tool_name, output.reset, version });
    output.printFmt("   To upgrade anyway: dot install {s} --force\n", .{tool_id});
}

fn printAlreadyReady(tool: []const u8, version: []const u8, tool_id: []const u8) void {
    output.printFmt("{s}Warning:{s} {s} {s} is already installed and up-to-date.\n", .{
        output.yellow, output.reset, tool, version,
    });
    output.printFmt("To reinstall: dot install {s} --force\n", .{tool_id});
}


fn printShellReloadHint(shell_type: platform.Shell) void {
    const file = shell_type.integrationFileName();
    output.printSectionHeader("Caveats");
    output.printFmt("  To activate in this shell:\n    source ~/.local/bin/{s}\n", .{file});
}

fn printSkipSystem(tool_name: []const u8, tool_id: []const u8, path: []const u8, sys_ver: []const u8, latest: []const u8) void {
    output.printFmt("\n{s}Warning:{s} {s}{s}{s} is already installed (system)\n", .{
        output.yellow, output.reset, output.bold, tool_name, output.reset,
    });
    output.printFmt("  Location:  {s}\n", .{path});
    output.printFmt("  Version:   {s}  {s}  {s}\n", .{ sys_ver, output.sym_arrow, latest });
    output.printFmt("To install dot's version: dot install {s} --force\n\n", .{tool_id});
}

fn printVersionFetchWarning(err_name: []const u8) void {
    output.printFmt("{s}Warning:{s} could not fetch version ({s}), using 'latest'\n", .{ output.yellow, output.reset, err_name });
}

fn printUnknownGroup(name: []const u8) void {
    output.printFmt("{s}Error:{s} unknown group '{s}'\n", .{ output.red, output.reset, name });
    output.printFmt("Available groups: k8s, cloud, iac, containers, utils, terminal, cm, security, all\n", .{});
}

fn printGroupToolError(id: []const u8, err: anyerror) void {
    output.printFmt("  {s}Failed{s} to install {s}: {s}\n", .{ output.red, output.reset, id, @errorName(err) });
}

fn printGroupBanner(group_name: []const u8, count: usize) void {
    output.printSectionHeaderFmt("Installing group '{s}' ({d} tools)", .{ group_name, count });
}

pub fn printGroupToolSeparator(name: []const u8, index: usize, total: usize) void {
    output.printSectionHeaderFmt("{s} ({d}/{d})", .{ name, index, total });
}

// ─── Fuzzy match ──────────────────────────────────────────────────────────────

/// Return the closest tool id if within edit distance 2, otherwise null.
fn closestTool(id: []const u8, tools: []const tool_mod.Tool) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = suggestion_distance_threshold;
    for (tools) |t| {
        const distance = util.editDistance(id, t.id);
        if (distance < best_dist) {
            best_dist = distance;
            best = t.id;
        }
    }
    return best;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "parseInstallArgs: tool name only" {
    const args = parseInstallArgs(&.{"helm"});
    try std.testing.expectEqualStrings("helm", args.tool_name);
    try std.testing.expect(args.version_arg == null);
    try std.testing.expect(!args.force);
    try std.testing.expect(!args.group_mode);
}

test "parseInstallArgs: tool name with version" {
    const args = parseInstallArgs(&.{ "helm", "3.15.0" });
    try std.testing.expectEqualStrings("helm", args.tool_name);
    try std.testing.expectEqualStrings("3.15.0", args.version_arg.?);
}

test "parseInstallArgs: --version flag" {
    const args = parseInstallArgs(&.{ "terraform", "--version", "1.8.0" });
    try std.testing.expectEqualStrings("terraform", args.tool_name);
    try std.testing.expectEqualStrings("1.8.0", args.version_arg.?);
}

test "parseInstallArgs: -v shorthand" {
    const args = parseInstallArgs(&.{ "terraform", "-v", "1.8.0" });
    try std.testing.expectEqualStrings("terraform", args.tool_name);
    try std.testing.expectEqualStrings("1.8.0", args.version_arg.?);
}

test "parseInstallArgs: --force flag" {
    const args = parseInstallArgs(&.{ "--force", "helm" });
    try std.testing.expect(args.force);
    try std.testing.expectEqualStrings("helm", args.tool_name);
}

test "parseInstallArgs: --force after tool" {
    const args = parseInstallArgs(&.{ "helm", "--force" });
    // --force before tool_name is set is fine; after tool_name is set, --force
    // isn't parsed as a special flag in current logic — it would be version_arg.
    // This test documents current behavior.
    try std.testing.expectEqualStrings("helm", args.tool_name);
}

test "parseInstallArgs: --group flag" {
    const args = parseInstallArgs(&.{ "--group", "k8s" });
    try std.testing.expect(args.group_mode);
    try std.testing.expectEqualStrings("k8s", args.group_name);
    try std.testing.expect(!args.force);
}

test "parseInstallArgs: -g shorthand" {
    const args = parseInstallArgs(&.{ "-g", "iac" });
    try std.testing.expect(args.group_mode);
    try std.testing.expectEqualStrings("iac", args.group_name);
}

test "parseInstallArgs: --force with group" {
    const args = parseInstallArgs(&.{ "--force", "--group", "cloud" });
    try std.testing.expect(args.force);
    try std.testing.expect(args.group_mode);
    try std.testing.expectEqualStrings("cloud", args.group_name);
}

test "parseInstallArgs: empty args" {
    const args = parseInstallArgs(&.{});
    try std.testing.expectEqualStrings("", args.tool_name);
    try std.testing.expect(!args.group_mode);
    try std.testing.expect(!args.force);
}

test "parseGroup: known groups" {
    try std.testing.expectEqual(tool_mod.Group.k8s, parseGroup("k8s").?);
    try std.testing.expectEqual(tool_mod.Group.cloud, parseGroup("cloud").?);
    try std.testing.expectEqual(tool_mod.Group.iac, parseGroup("iac").?);
    try std.testing.expectEqual(tool_mod.Group.containers, parseGroup("containers").?);
    try std.testing.expectEqual(tool_mod.Group.utils, parseGroup("utils").?);
    try std.testing.expectEqual(tool_mod.Group.terminal, parseGroup("terminal").?);
    try std.testing.expectEqual(tool_mod.Group.dev, parseGroup("dev").?);
}

test "parseGroup: unknown groups return null" {
    try std.testing.expect(parseGroup("unknown") == null);
    try std.testing.expect(parseGroup("") == null);
    try std.testing.expect(parseGroup("K8S") == null); // case-sensitive
    try std.testing.expect(parseGroup("all") == null); // "all" is handled separately
}

test "guardedCompletion: fish wraps with if command -q guard" {
    const allocator = std.testing.allocator;
    const result = try guardedCompletion(.fish, "helm", "helm completion fish | source", allocator);
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "if command -q helm\n"));
    try std.testing.expect(std.mem.indexOf(u8, result, "helm completion fish | source") != null);
    try std.testing.expect(std.mem.endsWith(u8, result, "\nend"));
}

test "guardedCompletion: bash wraps with command -v guard" {
    const allocator = std.testing.allocator;
    const result = try guardedCompletion(.bash, "helm", "source <(helm completion bash)", allocator);
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "command -v helm"));
    try std.testing.expect(std.mem.indexOf(u8, result, ">/dev/null 2>&1 &&") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "source <(helm completion bash)") != null);
}

test "guardedCompletion: zsh wraps with command -v guard" {
    const allocator = std.testing.allocator;
    const result = try guardedCompletion(.zsh, "helm", "source <(helm completion zsh)", allocator);
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "command -v helm"));
    try std.testing.expect(std.mem.indexOf(u8, result, ">/dev/null 2>&1 &&") != null);
}

test "guardedCompletion: unknown returns raw cmd" {
    const allocator = std.testing.allocator;
    const result = try guardedCompletion(.unknown, "helm", "helm completion fish | source", allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("helm completion fish | source", result);
}
