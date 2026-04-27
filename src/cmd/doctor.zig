const std = @import("std");
const state_mod = @import("../state.zig");
const tool_mod = @import("../tool.zig");
const platform = @import("../platform.zig");
const output = @import("../ui/output.zig");
const io_ctx = @import("../io_ctx.zig");
const shell_mod = @import("../shell.zig");
const install_mod = @import("install.zig");
const paths = @import("../paths.zig");
const env = @import("../env.zig");

const help =
    \\Usage: dot doctor
    \\
    \\Run a system health check. Reports:
    \\  • OS and architecture
    \\  • Detected shell and package manager
    \\  • Installed tool binaries and their locations
    \\  • Orphaned state entries (tools no longer in any repository)
    \\  • Unmanaged binaries in ~/.local/bin not registered with dot
    \\  • Shell integration file status and unguarded invocations
    \\
    \\Options:
    \\  --help, -h    Show this help
    \\
;

// ─── Doctor-specific print functions ──────────────────────────────────────────

fn printCheckPass(label: []const u8, detail: []const u8) void {
    output.printFmt("  {s}{s}{s} {s:<24} {s}\n", .{ output.green, output.sym_ok, output.reset, label, detail });
}

fn printCheckWarn(label: []const u8, detail: []const u8) void {
    output.printFmt("  {s}{s}{s}  {s:<24} {s}\n", .{ output.yellow, output.sym_warn, output.reset, label, detail });
}

fn printCheckFail(label: []const u8, detail: []const u8) void {
    output.printFmt("  {s}{s}{s} {s:<24} {s}\n", .{ output.red, output.sym_fail, output.reset, label, detail });
}

fn printDoctorSummary(pass: usize, warn: usize, fail: usize) void {
    output.printSectionHeader("Summary");
    output.printFmt("  {s}{d} passed{s}  ·  {s}{d} warnings{s}  ·  {s}{d} failed{s}\n\n", .{
        output.green,  pass,  output.reset,
        output.yellow, warn,  output.reset,
        if (fail > 0) output.red else output.dim, fail, output.reset,
    });
}

/// Extract the content between `# BEGIN <UPPER_ID>` and `# END <UPPER_ID>` markers.
/// Returns null if the section is absent. Caller owns the returned slice.
fn extractSection(content: []const u8, tool_id: []const u8, allocator: std.mem.Allocator) ?[]u8 {
    const upper = allocator.dupe(u8, tool_id) catch return null;
    defer allocator.free(upper);
    for (upper) |*c| c.* = std.ascii.toUpper(c.*);

    const begin_marker = std.fmt.allocPrint(allocator, "# BEGIN {s}", .{upper}) catch return null;
    defer allocator.free(begin_marker);
    const end_marker = std.fmt.allocPrint(allocator, "# END {s}", .{upper}) catch return null;
    defer allocator.free(end_marker);

    const begin_pos = std.mem.indexOf(u8, content, begin_marker) orelse return null;
    const after_begin = begin_pos + begin_marker.len;
    const start = if (after_begin < content.len and content[after_begin] == '\n') after_begin + 1 else after_begin;
    const end_pos = std.mem.indexOf(u8, content[start..], end_marker) orelse return null;
    return allocator.dupe(u8, content[start .. start + end_pos]) catch null;
}

/// Return true if the section contains a bare tool invocation not wrapped in a
/// shell existence guard (`if command -q` for fish, `command -v` for bash/zsh).
fn hasUnguardedInvocations(section: []const u8, tool_id: []const u8, shell: platform.Shell) bool {
    // depth tracks ALL if/end nesting. in_guard becomes true when we enter an
    // `if command -q` block at the top level and stays true until the matching `end`.
    var depth: usize = 0;
    var in_guard = false;
    var lines = std.mem.splitScalar(u8, section, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        switch (shell) {
            .fish => {
                if (std.mem.startsWith(u8, trimmed, "if ")) {
                    // Outer-level `if command -q` opens a guard; inner ifs just add depth.
                    if (depth == 0 and std.mem.startsWith(u8, trimmed, "if command -q ")) in_guard = true;
                    depth += 1;
                } else if (std.mem.eql(u8, trimmed, "end")) {
                    if (depth > 0) depth -= 1;
                    if (depth == 0) in_guard = false;
                } else if (!in_guard and isInvocation(trimmed, tool_id)) {
                    return true;
                }
            },
            .bash, .zsh => {
                if (isInvocation(trimmed, tool_id) and !std.mem.startsWith(u8, trimmed, "command -v ")) {
                    return true;
                }
            },
            .unknown => {},
        }
    }
    return false;
}

/// True if the line invokes the tool binary directly or via process substitution.
/// Excludes alias/complete/compdef lines.
fn isInvocation(line: []const u8, tool_id: []const u8) bool {
    if (std.mem.startsWith(u8, line, "alias ") or
        std.mem.startsWith(u8, line, "complete ") or
        std.mem.startsWith(u8, line, "compdef ")) return false;
    // Direct invocation: line starts with tool_id
    if (std.mem.startsWith(u8, line, tool_id)) {
        if (line.len == tool_id.len) return true;
        return line[tool_id.len] == ' ' or line[tool_id.len] == '|' or line[tool_id.len] == '\t';
    }
    // Process substitution: `source <(tool_id ...)` or `tool_id ... | source`
    const proc_sub = "source <(";
    if (std.mem.startsWith(u8, line, proc_sub)) {
        const after = line[proc_sub.len..];
        if (std.mem.startsWith(u8, after, tool_id)) {
            if (after.len == tool_id.len) return true;
            return after[tool_id.len] == ' ' or after[tool_id.len] == ')';
        }
    }
    return false;
}

/// Returns true if the shell's RC file contains the dot source marker.
fn rcHasSourceMarker(shell: platform.Shell, home: []const u8, allocator: std.mem.Allocator) bool {
    const rc_path: []u8 = switch (shell) {
        .bash => std.fs.path.join(allocator, &.{ home, shell_mod.bash_rc_file }) catch return false,
        .zsh => std.fs.path.join(allocator, &.{ home, shell_mod.zsh_rc_file }) catch return false,
        .fish => std.fs.path.join(allocator, &.{ home, paths.config_dir, shell_mod.fish_config_dir, shell_mod.fish_config_file }) catch return false,
        .unknown => return true,
    };
    defer allocator.free(rc_path);
    const io = io_ctx.get();
    const rc_file = std.Io.Dir.cwd().openFile(io, rc_path, .{}) catch return false;
    defer rc_file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = rc_file.readerStreaming(io, &buf);
    const content = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, shell_mod.source_marker) != null;
}

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

    output.printSectionHeader("System Health Check");

    var pass: usize = 0;
    var warn: usize = 0;
    var fail: usize = 0;

    const home = env.getenv("HOME") orelse paths.fallback_home;

    // System checks
    output.printSectionHeader("System");

    const os_type = platform.OperatingSystem.current();
    const arch_type = platform.Arch.current();
    printCheckPass("OS", os_type.name());
    pass += 1;
    printCheckPass("Arch", arch_type.goName());
    pass += 1;

    const shell_type = platform.Shell.detect();
    printCheckPass("Shell", shell_type.name());
    pass += 1;

    const pkg_mgr = platform.PackageManager.detect();
    if (pkg_mgr != .unknown) {
        printCheckPass("Package Manager", pkg_mgr.command() orelse "unknown");
        pass += 1;
    } else {
        printCheckWarn("Package Manager", "none detected");
        warn += 1;
    }

    const path_env = env.getenv("PATH") orelse "";
    const local_bin_abs = std.fs.path.join(allocator, &.{ home, paths.local_dir, paths.bin_dir }) catch null;
    if (local_bin_abs) |lb| {
        defer allocator.free(lb);
        if (std.mem.indexOf(u8, path_env, lb) != null) {
            printCheckPass("~/.local/bin in PATH", "yes");
            pass += 1;
        } else {
            printCheckWarn("~/.local/bin in PATH", "not found — tools may not be accessible");
            warn += 1;
        }
    }

    // Installed tools: binary check + orphan check + unmanaged check all in one section.
    output.printSectionHeader("Installed Tools");

    var tool_iter = state.tools.iterator();
    while (tool_iter.next()) |kv| {
        const tool_id = kv.key_ptr.*;
        const bin_path = std.fs.path.join(allocator, &.{ home, paths.local_dir, paths.bin_dir, tool_id }) catch continue;
        defer allocator.free(bin_path);

        if (std.Io.Dir.cwd().access(io_ctx.get(), bin_path, .{})) |_| {
            printCheckPass(tool_id, bin_path);
            pass += 1;
            continue;
        } else |_| {}

        // Not in ~/.local/bin — try `which` (covers system_package installs)
        const result = std.process.run(allocator, io_ctx.get(), .{
            .argv = &.{ "which", tool_id },
            .stdout_limit = .limited(512),
            .stderr_limit = .limited(512),
        }) catch {
            printCheckFail(tool_id, "not found — run: dot install <tool> --force");
            fail += 1;
            continue;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) {
            const found_path = std.mem.trimEnd(u8, result.stdout, "\n");
            printCheckPass(tool_id, found_path);
            pass += 1;
        } else {
            printCheckFail(tool_id, "not found — run: dot install <tool> --force");
            fail += 1;
        }
    }

    // State consistency: flag entries that are no longer in any repository.
    // "dot" is excluded — it is self-managed via `dot update`.
    var has_orphan = false;
    var state_iter = state.tools.iterator();
    while (state_iter.next()) |kv| {
        const tool_id = kv.key_ptr.*;
        if (std.mem.eql(u8, tool_id, "dot")) continue;
        var found = false;
        for (tools) |t| {
            if (std.mem.eql(u8, t.id, tool_id)) {
                found = true;
                break;
            }
        }
        if (!found) {
            const detail = std.fmt.allocPrint(allocator, "not in any repository — run: dot uninstall {s}", .{tool_id}) catch null;
            defer if (detail) |d| allocator.free(d);
            printCheckWarn(tool_id, detail orelse "not in any repository");
            warn += 1;
            has_orphan = true;
        }
    }
    if (!has_orphan) pass += 1;

    // Unmanaged tools: binaries present in ~/.local/bin but not registered in state.
    var unmanaged_count: usize = 0;
    for (tools) |t| {
        if (state.isInstalled(t.id)) continue;
        const bin_path = std.fs.path.join(allocator, &.{ home, paths.local_dir, paths.bin_dir, t.id }) catch continue;
        defer allocator.free(bin_path);
        std.Io.Dir.cwd().access(io_ctx.get(), bin_path, .{}) catch continue;
        const detail = std.fmt.allocPrint(allocator, "found in ~/.local/bin — run: dot install {s}", .{t.id}) catch null;
        defer if (detail) |d| allocator.free(d);
        printCheckWarn(t.id, detail orelse "found in ~/.local/bin but not managed by dot");
        warn += 1;
        unmanaged_count += 1;
    }
    if (unmanaged_count == 0) pass += 1;

    // Shell integration: for the active shell, check and auto-fix the integration
    // file and RC source block. For all shells, scan for unguarded invocations.
    output.printSectionHeader("Shell Integration");

    const all_shells = [_]platform.Shell{ .bash, .zsh, .fish };
    for (all_shells) |check_sh| {
        const integ_path = std.fs.path.join(allocator, &.{
            home, paths.local_dir, paths.bin_dir, check_sh.integrationFileName(),
        }) catch continue;
        defer allocator.free(integ_path);

        // For the active shell: check state before acting, then auto-fix.
        if (check_sh == shell_type) {
            const had_file = if (std.Io.Dir.cwd().access(io_ctx.get(), integ_path, .{})) |_| true else |_| false;
            const had_source = rcHasSourceMarker(check_sh, home, allocator);

            if (!had_file or !had_source) {
                // Fix both issues in one call — ensureSourced is idempotent.
                shell_mod.ensureSourced(check_sh, allocator) catch {};

                if (!had_file) {
                    printCheckWarn(check_sh.name(), "integration file missing — recreated");
                    warn += 1;
                }
                if (!had_source) {
                    printCheckWarn(check_sh.name(), "source block missing — added to RC (restart your shell)");
                    warn += 1;
                }
            }

            // Detect and restore any missing tool sections in the integration file.
            {
                const io2 = io_ctx.get();
                const integ_file_r = std.Io.Dir.cwd().openFile(io2, integ_path, .{}) catch null;
                const integ_content: ?[]u8 = if (integ_file_r) |f| blk: {
                    defer f.close(io2);
                    var ibuf: [4096]u8 = undefined;
                    var ireader = f.readerStreaming(io2, &ibuf);
                    break :blk ireader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024)) catch null;
                } else null;
                defer if (integ_content) |c| allocator.free(c);

                var restored: usize = 0;
                for (tools) |*t| {
                    if (!state.isInstalled(t.id)) continue;
                    // Skip if section already present in the file
                    if (integ_content) |c| {
                        const sec = extractSection(c, t.id, allocator);
                        if (sec != null) {
                            allocator.free(sec.?);
                            continue;
                        }
                    }
                    // Section missing — regenerate it silently
                    const section = install_mod.buildShellSection(t, check_sh, allocator) orelse continue;
                    defer allocator.free(section);
                    shell_mod.addSection(check_sh, t.id, section, allocator) catch {};
                    restored += 1;
                }
                if (restored > 0) {
                    const detail = std.fmt.allocPrint(allocator, "{d} tool section(s) restored", .{restored}) catch null;
                    defer if (detail) |d| allocator.free(d);
                    printCheckWarn(check_sh.name(), detail orelse "tool sections restored");
                    warn += 1;
                }
            }

            // A freshly recreated file has no unguarded invocations to scan.
            if (!had_file) continue;
        }

        // Read integration file for unguarded invocation scan.
        // Non-active shells: silently skip if the file doesn't exist.
        const content = blk: {
            const io3 = io_ctx.get();
            const integ_file = std.Io.Dir.cwd().openFile(io3, integ_path, .{}) catch break :blk null;
            defer integ_file.close(io3);
            var integ_read_buf: [4096]u8 = undefined;
            var integ_reader = integ_file.readerStreaming(io3, &integ_read_buf);
            break :blk integ_reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024)) catch null;
        };
        const c = content orelse continue;
        defer allocator.free(c);

        var unguarded_found = false;
        var state_iter2 = state.tools.iterator();
        while (state_iter2.next()) |kv| {
            const tool_id = kv.key_ptr.*;
            const section = extractSection(c, tool_id, allocator) orelse continue;
            defer allocator.free(section);
            if (hasUnguardedInvocations(section, tool_id, check_sh)) {
                const label = std.fmt.allocPrint(allocator, "{s} ({s})", .{ tool_id, check_sh.name() }) catch continue;
                defer allocator.free(label);
                const detail = std.fmt.allocPrint(allocator, "unguarded invocation — run: dot install {s} --force", .{tool_id}) catch null;
                defer if (detail) |d| allocator.free(d);
                printCheckWarn(label, detail orelse "unguarded invocation");
                warn += 1;
                unguarded_found = true;
            }
        }

        if (!unguarded_found) {
            printCheckPass(check_sh.name(), integ_path);
            pass += 1;
        }
    }

    printDoctorSummary(pass, warn, fail);
}

test "extractSection: present section" {
    const allocator = std.testing.allocator;
    const content = "# BEGIN HELM\nsome config\n# END HELM\n";
    const result = extractSection(content, "helm", allocator);
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings("some config\n", result.?);
}

test "extractSection: absent section" {
    const allocator = std.testing.allocator;
    const content = "no markers here";
    const result = extractSection(content, "helm", allocator);
    try std.testing.expect(result == null);
}

test "extractSection: end marker before begin" {
    const allocator = std.testing.allocator;
    const content = "# END HELM\n# BEGIN HELM\ncontent\n# END HELM\n";
    // Should find the BEGIN and extract correctly
    const result = extractSection(content, "helm", allocator);
    try std.testing.expect(result != null);
    defer allocator.free(result.?);
    try std.testing.expectEqualStrings("content\n", result.?);
}

test "isInvocation: exact match" {
    try std.testing.expect(isInvocation("helm version", "helm"));
}

test "isInvocation: prefix rejected" {
    try std.testing.expect(!isInvocation("kubectl completion bash", "kube"));
}

test "isInvocation: alias line rejected" {
    try std.testing.expect(!isInvocation("alias helm=helm3", "helm"));
}

test "isInvocation: tool alone" {
    try std.testing.expect(isInvocation("helm", "helm"));
}

test "hasUnguardedInvocations: fish guarded" {
    const section = "if command -q helm\n    source <(helm completion fish)\nend\n";
    try std.testing.expect(!hasUnguardedInvocations(section, "helm", .fish));
}

test "hasUnguardedInvocations: fish unguarded" {
    const section = "source <(helm completion fish)\n";
    try std.testing.expect(hasUnguardedInvocations(section, "helm", .fish));
}

test "hasUnguardedInvocations: fish nested end does not escape guard" {
    const section = "if command -q helm\n    if test -f foo\n    end\n    helm completion fish | source\nend\n";
    try std.testing.expect(!hasUnguardedInvocations(section, "helm", .fish));
}

test "hasUnguardedInvocations: bash guarded" {
    const section = "command -v helm >/dev/null 2>&1 && source <(helm completion bash)\n";
    try std.testing.expect(!hasUnguardedInvocations(section, "helm", .bash));
}

test "hasUnguardedInvocations: bash unguarded" {
    const section = "source <(helm completion bash)\n";
    try std.testing.expect(hasUnguardedInvocations(section, "helm", .bash));
}
