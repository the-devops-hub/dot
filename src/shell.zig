const std = @import("std");
const platform = @import("platform.zig");
const io_ctx = @import("io_ctx.zig");
const paths = @import("paths.zig");
const env = @import("env.zig");

pub const source_marker = "# dot: source shell integration";
pub const bash_rc_file = ".bashrc";
pub const zsh_rc_file = ".zshrc";
pub const fish_config_dir = "fish";
pub const fish_config_file = "config.fish";
const path_marker = "# dot: add local bin to PATH";

/// Ensure the centralized integration file is sourced from the shell's RC.
/// Idempotent.
pub fn ensureSourced(shell: platform.Shell, allocator: std.mem.Allocator) !void {
    const home = env.getenv("HOME") orelse return error.NoHome;

    const rc_path = switch (shell) {
        .bash => try std.fs.path.join(allocator, &.{ home, bash_rc_file }),
        .zsh => try std.fs.path.join(allocator, &.{ home, zsh_rc_file }),
        .fish => try std.fs.path.join(allocator, &.{ home, paths.config_dir, fish_config_dir, fish_config_file }),
        .unknown => return,
    };
    defer allocator.free(rc_path);

    const integration_path = try std.fs.path.join(
        allocator,
        &.{ home, paths.local_dir, paths.bin_dir, shell.integrationFileName() },
    );
    defer allocator.free(integration_path);

    // Ensure integration file exists (open without truncating; create only if absent)
    const integ_dir = std.fs.path.dirname(integration_path) orelse return error.InvalidIntegrationPath;
    {
        const io = io_ctx.get();
        try std.Io.Dir.cwd().createDirPath(io, integ_dir);
        const integ_file = std.Io.Dir.cwd().openFile(io, integration_path, .{}) catch |e| switch (e) {
            error.FileNotFound => try std.Io.Dir.cwd().createFile(io, integration_path, .{}),
            else => return e,
        };
        integ_file.close(io);
    }

    // Check if RC already sources our file
    const io = io_ctx.get();
    const rc_content = std.Io.Dir.cwd().openFile(io, rc_path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            // Create RC and add source line
            try appendToFile(rc_path, try buildSourceLine(shell, integration_path, allocator));
            return;
        },
        else => return e,
    };
    var rc_read_buf: [4096]u8 = undefined;
    var rc_reader = rc_content.readerStreaming(io, &rc_read_buf);
    const content = try rc_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    rc_content.close(io);
    defer allocator.free(content);

    if (std.mem.indexOf(u8, content, source_marker) != null) {
        // Already sourced — still normalize integration file to clean up any accumulated blank lines
        try normalizeIntegrationFile(integration_path, allocator);
        return;
    }

    const source_line = try buildSourceLine(shell, integration_path, allocator);
    defer allocator.free(source_line);
    try appendToFile(rc_path, source_line);

    // Also ensure PATH is set in integration file
    try ensurePathInIntegration(shell, integration_path, allocator, home);
}

/// Add (or update) a tool's shell config section in the integration file.
/// Uses # BEGIN TOOLNAME / # END TOOLNAME markers. Idempotent.
pub fn addSection(
    shell: platform.Shell,
    tool_name: []const u8,
    config: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const home = env.getenv("HOME") orelse return error.NoHome;
    const integration_path = try std.fs.path.join(
        allocator,
        &.{ home, paths.local_dir, paths.bin_dir, shell.integrationFileName() },
    );
    defer allocator.free(integration_path);

    // Normalize to uppercase for markers
    const upper_name = try allocator.dupe(u8, tool_name);
    defer allocator.free(upper_name);
    for (upper_name) |*c| c.* = std.ascii.toUpper(c.*);

    const begin_marker = try std.fmt.allocPrint(allocator, "# BEGIN {s}", .{upper_name});
    defer allocator.free(begin_marker);
    const end_marker = try std.fmt.allocPrint(allocator, "# END {s}", .{upper_name});
    defer allocator.free(end_marker);

    const io = io_ctx.get();
    const file = std.Io.Dir.cwd().openFile(io, integration_path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            const new_content = try std.fmt.allocPrint(allocator, "\n{s}\n{s}\n{s}\n", .{
                begin_marker,
                config,
                end_marker,
            });
            defer allocator.free(new_content);
            try writeFile(integration_path, new_content);
            return;
        },
        else => return e,
    };
    var add_read_buf: [4096]u8 = undefined;
    var add_reader = file.readerStreaming(io, &add_read_buf);
    const existing = try add_reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024));
    file.close(io);
    defer allocator.free(existing);

    const new_content = try rebuildWithSection(existing, begin_marker, end_marker, config, allocator);
    defer allocator.free(new_content);
    try writeFile(integration_path, new_content);
}

/// Remove a tool's section from the integration file.
pub fn removeSection(
    shell: platform.Shell,
    tool_name: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const home = env.getenv("HOME") orelse return error.NoHome;
    const integration_path = try std.fs.path.join(
        allocator,
        &.{ home, paths.local_dir, paths.bin_dir, shell.integrationFileName() },
    );
    defer allocator.free(integration_path);

    const upper_name = try allocator.dupe(u8, tool_name);
    defer allocator.free(upper_name);
    for (upper_name) |*c| c.* = std.ascii.toUpper(c.*);

    const begin_marker = try std.fmt.allocPrint(allocator, "# BEGIN {s}", .{upper_name});
    defer allocator.free(begin_marker);
    const end_marker = try std.fmt.allocPrint(allocator, "# END {s}", .{upper_name});
    defer allocator.free(end_marker);

    const io = io_ctx.get();
    const file = std.Io.Dir.cwd().openFile(io, integration_path, .{}) catch return;
    var rm_read_buf: [4096]u8 = undefined;
    var rm_reader = file.readerStreaming(io, &rm_read_buf);
    const existing = try rm_reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024));
    file.close(io);
    defer allocator.free(existing);

    const new_content = try rebuildWithoutSection(existing, begin_marker, end_marker, allocator);
    defer allocator.free(new_content);
    try writeFile(integration_path, new_content);
}

// ─── Pure text helpers (also used in tests) ───────────────────────────────────

/// Given existing file content, insert or replace the marked section with config.
/// Returns caller-owned slice.
pub fn rebuildWithSection(
    existing: []const u8,
    begin_marker: []const u8,
    end_marker: []const u8,
    config: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    if (std.mem.indexOf(u8, existing, begin_marker) != null) {
        // Replace existing section
        var lines = std.mem.splitScalar(u8, existing, '\n');
        var in_section = false;
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, begin_marker)) {
                try out.appendSlice(allocator, begin_marker);
                try out.append(allocator, '\n');
                try out.appendSlice(allocator, config);
                try out.append(allocator, '\n');
                in_section = true;
            } else if (std.mem.eql(u8, line, end_marker)) {
                try out.appendSlice(allocator, end_marker);
                try out.append(allocator, '\n');
                in_section = false;
            } else if (!in_section) {
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
            }
        }
    } else {
        // Append new section
        try out.appendSlice(allocator, existing);
        if (existing.len > 0 and existing[existing.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, begin_marker);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, config);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, end_marker);
        try out.append(allocator, '\n');
    }

    // Normalize: collapse multiple consecutive blank lines into one, strip trailing blank lines.
    return normalizeBlankLines(allocator, out.items);
}

/// Given existing file content, return new content with the marked section removed.
/// Returns caller-owned slice.
pub fn rebuildWithoutSection(
    existing: []const u8,
    begin_marker: []const u8,
    end_marker: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, existing, '\n');
    var in_section = false;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, begin_marker)) {
            in_section = true;
        } else if (std.mem.eql(u8, line, end_marker)) {
            in_section = false;
        } else if (!in_section) {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    }

    return normalizeBlankLines(allocator, out.items);
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Collapse runs of blank lines into a single blank line and strip trailing blank lines.
/// Returns a caller-owned slice.
fn normalizeBlankLines(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var consecutive_blank: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            consecutive_blank += 1;
        } else {
            if (consecutive_blank > 0) {
                // Emit exactly one blank line between non-blank content
                try out.appendSlice(allocator, "\n");
                consecutive_blank = 0;
            }
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    }
    // Strip trailing blank lines — out already ends with '\n' from last non-blank line
    return out.toOwnedSlice(allocator);
}

fn buildSourceLine(shell: platform.Shell, integration_path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    _ = shell;
    return std.fmt.allocPrint(allocator, "\n{s}\nsource {s}\n", .{ source_marker, integration_path });
}

fn ensurePathInIntegration(
    shell: platform.Shell,
    integration_path: []const u8,
    allocator: std.mem.Allocator,
    home: []const u8,
) !void {
    const io = io_ctx.get();
    const file = std.Io.Dir.cwd().openFile(io, integration_path, .{}) catch return;
    var path_read_buf: [4096]u8 = undefined;
    var path_reader = file.readerStreaming(io, &path_read_buf);
    const content = path_reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch {
        file.close(io);
        return;
    };
    file.close(io);
    defer allocator.free(content);

    if (std.mem.indexOf(u8, content, path_marker) != null) return;

    const bin_dir = try std.fs.path.join(allocator, &.{ home, paths.local_dir, paths.bin_dir });
    defer allocator.free(bin_dir);

    const path_line = try shell.pathAddSyntax(bin_dir, allocator);
    defer allocator.free(path_line);

    const addition = try std.fmt.allocPrint(allocator, "\n{s}\n{s}\n", .{ path_marker, path_line });
    defer allocator.free(addition);

    try appendToFile(integration_path, addition);
}

fn normalizeIntegrationFile(path: []const u8, allocator: std.mem.Allocator) !void {
    const io = io_ctx.get();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return; // not yet created — nothing to normalize
    var norm_read_buf: [4096]u8 = undefined;
    var norm_reader = file.readerStreaming(io, &norm_read_buf);
    const existing = try norm_reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024));
    file.close(io);
    defer allocator.free(existing);
    const cleaned = try normalizeBlankLines(allocator, existing);
    defer allocator.free(cleaned);
    try writeFile(path, cleaned);
}

fn appendToFile(path: []const u8, content: []const u8) !void {
    const io = io_ctx.get();
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const offset = try file.length(io);
    try file.writePositionalAll(io, content, offset);
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const io = io_ctx.get();
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var write_buf: [4096]u8 = undefined;
    var file_writer = file.writerStreaming(io, &write_buf);
    try file_writer.interface.writeAll(content);
    try file_writer.interface.flush();
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "rebuildWithSection: append to empty content" {
    const result = try rebuildWithSection(
        "",
        "# BEGIN HELM",
        "# END HELM",
        "source <(helm completion bash)",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "# BEGIN HELM") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "# END HELM") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "source <(helm completion bash)") != null);
}

test "rebuildWithSection: append to existing content without section" {
    const existing = "export PATH=$PATH:/usr/local/bin\n";
    const result = try rebuildWithSection(
        existing,
        "# BEGIN HELM",
        "# END HELM",
        "source <(helm completion bash)",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(result);
    // Original content preserved
    try std.testing.expect(std.mem.indexOf(u8, result, "export PATH") != null);
    // Section appended
    try std.testing.expect(std.mem.indexOf(u8, result, "# BEGIN HELM") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "source <(helm completion bash)") != null);
}

test "rebuildWithSection: replace existing section" {
    const existing =
        "export PATH=$PATH:/usr/local/bin\n" ++
        "# BEGIN HELM\n" ++
        "source <(helm completion bash)\n" ++
        "# END HELM\n" ++
        "export EDITOR=vim\n";

    const result = try rebuildWithSection(
        existing,
        "# BEGIN HELM",
        "# END HELM",
        "source <(helm completion zsh)",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(result);
    // New content present
    try std.testing.expect(std.mem.indexOf(u8, result, "source <(helm completion zsh)") != null);
    // Old content removed
    try std.testing.expect(std.mem.indexOf(u8, result, "source <(helm completion bash)") == null);
    // Surrounding content preserved
    try std.testing.expect(std.mem.indexOf(u8, result, "export PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "export EDITOR=vim") != null);
}

test "rebuildWithSection: idempotent on second apply" {
    const existing = "";
    const config = "source <(helm completion bash)";

    const first = try rebuildWithSection(existing, "# BEGIN HELM", "# END HELM", config, std.testing.allocator);
    defer std.testing.allocator.free(first);
    const second = try rebuildWithSection(first, "# BEGIN HELM", "# END HELM", config, std.testing.allocator);
    defer std.testing.allocator.free(second);

    // Marker appears exactly once
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, second, "# BEGIN HELM");
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count); // split produces n+1 parts for n occurrences
}

test "rebuildWithoutSection: removes section" {
    const existing =
        "export PATH=$PATH:/usr/local/bin\n" ++
        "# BEGIN HELM\n" ++
        "source <(helm completion bash)\n" ++
        "# END HELM\n" ++
        "export EDITOR=vim\n";

    const result = try rebuildWithoutSection(existing, "# BEGIN HELM", "# END HELM", std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "# BEGIN HELM") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "# END HELM") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "source <(helm completion bash)") == null);
    // Surrounding content preserved
    try std.testing.expect(std.mem.indexOf(u8, result, "export PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "export EDITOR=vim") != null);
}

test "rebuildWithoutSection: no-op if section absent" {
    const existing = "export PATH=$PATH:/usr/local/bin\nexport EDITOR=vim\n";
    const result = try rebuildWithoutSection(existing, "# BEGIN HELM", "# END HELM", std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "export PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "export EDITOR=vim") != null);
}

test "rebuildWithoutSection: empty content stays empty" {
    const result = try rebuildWithoutSection("", "# BEGIN HELM", "# END HELM", std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}
