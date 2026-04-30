const std = @import("std");
const builtin = @import("builtin");
const tool_mod = @import("../tool.zig");
const state_mod = @import("../state.zig");
const output = @import("../ui/output.zig");
const install_cmd = @import("install.zig");
const io_ctx = @import("../io_ctx.zig");
const paths = @import("../paths.zig");
const env = @import("../env.zig");
const util = @import("../util.zig");

const help =
    \\Usage: dot list [options]
    \\
    \\List all tools with their install status.
    \\
    \\Options:
    \\  --group, -g <g>   Show only tools in the given group
    \\  --installed, -i   Show only installed tools
    \\  --pinned          Show only pinned tools
    \\  --details, -l     Show version/installed/method columns (installed tools only)
    \\  --help, -h        Show this help
    \\
    \\Groups:  k8s, cloud, iac, containers, utils, terminal, cm, security, dev, all
    \\
    \\Examples:
    \\  dot list
    \\  dot list k8s
    \\  dot list --group k8s
    \\  dot list --installed
    \\  dot list --installed --details
    \\
;

// Fixed column widths (visual chars)
const col_id: usize = 16;
const col_groups: usize = 16;
// Overhead: id(16) + sp(1) + status(14) + sp(1) + groups(16) + sp(1) = 49
// Description is rightmost — no reserve needed, gets all remaining space
const overhead: usize = 49;
const desc_min: usize = 10;

fn getTermWidth() usize {
    if (comptime builtin.os.tag == .linux) {
        const Winsize = extern struct { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 };
        var winsize = std.mem.zeroes(Winsize);
        _ = std.os.linux.ioctl(1, 0x5413, @intFromPtr(&winsize)); // TIOCGWINSZ
        if (winsize.ws_col > 0) return @as(usize, winsize.ws_col);
    }
    if (env.getenv("COLUMNS")) |cols| return std.fmt.parseInt(usize, cols, 10) catch 80;
    return 80;
}

pub const ListArgs = struct {
    group_filter: ?tool_mod.Group = null,
    installed_only: bool = false,
    pinned_only: bool = false,
    details_mode: bool = false,
    /// Set when a positional argument is not a valid group name.
    unknown_group: ?[]const u8 = null,
};

pub fn parseListArgs(args: []const []const u8) ListArgs {
    var result = ListArgs{};
    var idx: usize = 0;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--group") or std.mem.eql(u8, arg, "-g")) {
            idx += 1;
            if (idx < args.len) result.group_filter = install_cmd.parseGroup(args[idx]);
        } else if (std.mem.eql(u8, arg, "--installed") or std.mem.eql(u8, arg, "-i")) {
            result.installed_only = true;
        } else if (std.mem.eql(u8, arg, "--pinned")) {
            result.pinned_only = true;
            result.installed_only = true;
        } else if (std.mem.eql(u8, arg, "--details") or std.mem.eql(u8, arg, "-l")) {
            result.details_mode = true;
            result.installed_only = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (install_cmd.parseGroup(arg)) |g| {
                result.group_filter = g;
            } else {
                result.unknown_group = arg;
            }
        }
    }
    return result;
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

    const parsed = parseListArgs(args);

    if (parsed.unknown_group) |ug| {
        output.printFmt("Unknown group '{s}'. Valid groups: k8s, cloud, iac, containers, utils, terminal, cm, security, dev\n", .{ug});
        return;
    }

    const group_filter = parsed.group_filter;
    const installed_only = parsed.installed_only;
    const pinned_only = parsed.pinned_only;
    const details_mode = parsed.details_mode;

    const term_width = getTermWidth();
    const desc_width = if (term_width > overhead) term_width - overhead else desc_min;

    const home = env.getenv("HOME") orelse "";

    // Collect matching tools, then sort by first group name (alphabetical), then by id.
    var matched: std.ArrayList(*const tool_mod.Tool) = .empty;
    defer matched.deinit(allocator);
    for (tools) |*t| {
        if (group_filter) |gf| {
            var in_group = false;
            for (t.groups) |g| {
                if (g == gf) { in_group = true; break; }
            }
            if (!in_group) continue;
        }
        if (installed_only) {
            const entry = state.tools.get(t.id);
            if (entry == null) continue;
        }
        if (pinned_only) {
            const entry = state.tools.get(t.id);
            if (entry == null or !entry.?.pinned) continue;
        }
        try matched.append(allocator, t);
    }

    const cmp = struct {
        fn ltName(a: []const u8, b: []const u8) bool {
            const len = @min(a.len, b.len);
            for (0..len) |i| {
                const ca = std.ascii.toLower(a[i]);
                const cb = std.ascii.toLower(b[i]);
                if (ca != cb) return ca < cb;
            }
            return a.len < b.len;
        }
        fn lt(_: void, a: *const tool_mod.Tool, b: *const tool_mod.Tool) bool {
            const ga = if (a.groups.len > 0) @tagName(a.groups[0]) else "";
            const gb = if (b.groups.len > 0) @tagName(b.groups[0]) else "";
            const gcmp = std.mem.order(u8, ga, gb);
            if (gcmp != .eq) return gcmp == .lt;
            return ltName(a.name, b.name);
        }
    };
    std.mem.sort(*const tool_mod.Tool, matched.items, {}, cmp.lt);

    if (details_mode) {
        printDetailsHeader(term_width);
        for (matched.items) |t| {
            const entry = state.tools.get(t.id) orelse continue;
            var date_buf: [24]u8 = undefined;
            const date = output.fmtTimestamp(entry.installed_at, &date_buf);
            const pin_str: []const u8 = if (entry.pinned) output.sym_pin else "";
            printDetailsRow(t.id, entry.version, date, entry.method, pin_str);
        }
    } else {
        printListHeader(term_width);
        for (matched.items) |t| {
            var groups_buf: [64]u8 = undefined;
            var groups_writer: std.Io.Writer = .fixed(&groups_buf);
            for (t.groups, 0..) |group, idx| {
                if (idx > 0) groups_writer.writeByte(',') catch {};
                groups_writer.writeAll(@tagName(group)) catch {};
            }

            const maybe_entry = state.tools.get(t.id);
            const version: ?[]const u8 = if (maybe_entry) |e| e.version else null;
            const sys = if (version == null) isSystemInstalled(allocator, t.id) else false;
            const unmanaged = if (version == null and !sys) isUnmanagedLocal(home, t.id, allocator) else false;
            printListRow(t.id, t.aliases, t.description, version, sys, unmanaged, groups_writer.buffered(), desc_width);
        }
    }

    const filter_name: ?[]const u8 = if (group_filter) |gf| @tagName(gf) else null;
    printListFooter(matched.items.len, filter_name);
}

// ─── List-specific print functions ────────────────────────────────────────────


fn printDetailsHeader(term_width: usize) void {
    _ = term_width;
    output.printSectionHeader("Installed Tools");
    output.printFmt("\n{s}{s:<16} {s:<14} {s:<24} {s:<18} {s}{s}\n", .{
        output.bold, "Tool", "Version", "Installed At", "Method", "Pinned", output.reset,
    });
}

fn printDetailsRow(id: []const u8, version: []const u8, installed_at: []const u8, method: []const u8, pin: []const u8) void {
    const v_trunc = version[0..@min(version.len, 13)];
    const at_trunc = installed_at[0..@min(installed_at.len, 23)];
    const m_trunc = method[0..@min(method.len, 17)];
    output.printFmt("{s:<16} {s}{s:<14}{s} {s:<24} {s:<18} {s}\n", .{
        id, output.green, v_trunc, output.reset, at_trunc, m_trunc, pin,
    });
}

fn printListHeader(term_width: usize) void {
    _ = term_width;
    output.printSectionHeader("Available Tools");
    output.printFmt("\n{s}{s:<16} {s:<14} {s:<16} Description{s}\n", .{
        output.bold, "Tool", "Status", "Groups", output.reset,
    });
}

/// Truncate desc to at most max_visual visual chars, breaking at a word boundary
/// and appending UTF-8 '…' if truncated. Returns the byte slice and its visual width.
fn truncDesc(desc: []const u8, max_visual: usize, buf: []u8) struct { str: []const u8, visual: usize } {
    if (desc.len <= max_visual) return .{ .str = desc, .visual = desc.len };
    // Walk back from max_visual-1 to find a space (leave room for …)
    var end: usize = max_visual - 1;
    while (end > 0 and desc[end] != ' ') : (end -= 1) {}
    const cut = if (end == 0) max_visual - 1 else end;
    @memcpy(buf[0..cut], desc[0..cut]);
    buf[cut] = 0xe2;
    buf[cut + 1] = 0x80;
    buf[cut + 2] = 0xa6; // UTF-8 '…'
    return .{ .str = buf[0 .. cut + 3], .visual = cut + 1 };
}

/// Returns true if ~/.local/bin/<id> exists but is not registered in dot's state.
fn isUnmanagedLocal(home: []const u8, id: []const u8, allocator: std.mem.Allocator) bool {
    const path = std.fs.path.join(allocator, &.{ home, paths.local_dir, paths.bin_dir, id }) catch return false;
    defer allocator.free(path);
    std.Io.Dir.cwd().access(io_ctx.get(), path, .{}) catch return false;
    return true;
}

/// Returns true if the tool binary is found in PATH outside ~/.local/bin.
fn isSystemInstalled(allocator: std.mem.Allocator, id: []const u8) bool {
    const found = util.findInPath(allocator, id) orelse return false;
    defer allocator.free(found);
    return !std.mem.containsAtLeast(u8, found, 1, ".local/bin");
}

fn printListRow(id: []const u8, aliases: []const []const u8, desc: []const u8, version: ?[]const u8, sys: bool, unmanaged: bool, groups: []const u8, desc_width: usize) void {
    // id column: "kubectl" or "kubectl (k)" dimmed, padded to col_id visual chars
    const id_trunc = id[0..@min(id.len, col_id)];
    if (aliases.len > 0) {
        // Build alias string e.g. "(k)" or "(k,tf)"
        var alias_buf: [32]u8 = undefined;
        var alias_writer: std.Io.Writer = .fixed(&alias_buf);
        alias_writer.writeByte('(') catch {};
        for (aliases, 0..) |alias_item, idx| {
            if (idx > 0) alias_writer.writeByte(',') catch {};
            alias_writer.writeAll(alias_item) catch {};
        }
        alias_writer.writeByte(')') catch {};
        const alias_str = alias_writer.buffered();

        // Visual width: id + 1 space + alias_str
        const visual = id_trunc.len + 1 + alias_str.len;
        const pad = if (col_id + 1 > visual) col_id + 1 - visual else 0;
        output.printFmt("{s} {s}{s}{s}", .{ id_trunc, output.dim, alias_str, output.reset });
        for (0..pad) |_| output.printFmt(" ", .{});
    } else {
        output.printFmt("{s:<16} ", .{id_trunc});
    }

    // status column: 14 visual chars + 1 trailing space = 15 total.
    // sym_ok and sym_warn have variable visual widths in plain mode ("ok"=2, "WARN"=4),
    // so padding is computed as: 13 - sym_width - text_len spaces after the text.
    if (version) |v| {
        const v_trunc = v[0..@min(v.len, 12)];
        const text_visual = output.sym_ok_w + 1 + v_trunc.len; // sym + space + text
        const pad = if (14 > text_visual) 14 - text_visual else 0;
        output.printFmt("{s}{s} {s}{s}", .{ output.green, output.sym_ok, v_trunc, output.reset });
        for (0..pad) |_| output.printFmt(" ", .{});
        output.printFmt(" ", .{});
    } else if (sys) {
        const text_visual = output.sym_warn_w + 1 + "system".len; // sym + space + text
        const pad = if (14 > text_visual) 14 - text_visual else 0;
        output.printFmt("{s}{s} system{s}", .{ output.yellow, output.sym_warn, output.reset });
        for (0..pad) |_| output.printFmt(" ", .{});
        output.printFmt(" ", .{});
    } else if (unmanaged) {
        // "~ local" = 7 visual chars; 14 - 7 = 7 padding + 1 separator = 8 spaces
        output.printFmt("{s}~ local{s}        ", .{ output.dim, output.reset });
    } else {
        output.printFmt("{s}not installed{s}  ", .{ output.dim, output.reset });
    }

    // groups column — ASCII, byte-pad fine; truncate if somehow over col_groups
    const g_trunc = groups[0..@min(groups.len, col_groups)];
    output.printFmt("{s:<16} ", .{g_trunc});

    // description — rightmost, no padding needed; truncate to fit terminal
    var desc_buf: [512]u8 = undefined;
    const res = truncDesc(desc, desc_width, &desc_buf);
    output.printFmt("{s}\n", .{res.str});
}

fn printListFooter(count: usize, group_filter: ?[]const u8) void {
    output.printFmt("\n{d} tools total", .{count});
    if (group_filter) |g| output.printFmt(" (filtered by group '{s}')", .{g});
    output.printFmt("\n\n", .{});
}

test "truncDesc" {
    var buf: [512]u8 = undefined;

    // Short string — returned as-is
    const res1 = truncDesc("hello", 20, &buf);
    try std.testing.expectEqualStrings("hello", res1.str);
    try std.testing.expectEqual(@as(usize, 5), res1.visual);

    // Exactly max_visual — no truncation
    const res2 = truncDesc("hello world", 11, &buf);
    try std.testing.expectEqualStrings("hello world", res2.str);
    try std.testing.expectEqual(@as(usize, 11), res2.visual);

    // Truncate at word boundary: "hello world foo", max=12
    // end=11 → desc[11]=' ' → cut=11 → "hello world…", visual=12
    const res3 = truncDesc("hello world foo", 12, &buf);
    try std.testing.expectEqualStrings("hello world\xe2\x80\xa6", res3.str);
    try std.testing.expectEqual(@as(usize, 12), res3.visual);

    // No space found — hard cut at max_visual-1
    // "helloworldfoo", max=5 → cut=4 → "hell…", visual=5
    const res4 = truncDesc("helloworldfoo", 5, &buf);
    try std.testing.expectEqualStrings("hell\xe2\x80\xa6", res4.str);
    try std.testing.expectEqual(@as(usize, 5), res4.visual);
}

test "parseListArgs: no args gives defaults" {
    const r = parseListArgs(&.{});
    try std.testing.expectEqual(@as(?tool_mod.Group, null), r.group_filter);
    try std.testing.expect(!r.installed_only);
    try std.testing.expect(!r.pinned_only);
    try std.testing.expect(!r.details_mode);
    try std.testing.expectEqual(@as(?[]const u8, null), r.unknown_group);
}

test "parseListArgs: --group flag" {
    const r = parseListArgs(&.{ "--group", "k8s" });
    try std.testing.expectEqual(tool_mod.Group.k8s, r.group_filter.?);
}

test "parseListArgs: -g shorthand" {
    const r = parseListArgs(&.{ "-g", "security" });
    try std.testing.expectEqual(tool_mod.Group.security, r.group_filter.?);
}

test "parseListArgs: positional group name" {
    const r = parseListArgs(&.{"k8s"});
    try std.testing.expectEqual(tool_mod.Group.k8s, r.group_filter.?);
    try std.testing.expectEqual(@as(?[]const u8, null), r.unknown_group);
}

test "parseListArgs: positional group security" {
    const r = parseListArgs(&.{"security"});
    try std.testing.expectEqual(tool_mod.Group.security, r.group_filter.?);
}

test "parseListArgs: unknown positional sets unknown_group" {
    const r = parseListArgs(&.{"badgroup"});
    try std.testing.expectEqual(@as(?tool_mod.Group, null), r.group_filter);
    try std.testing.expectEqualStrings("badgroup", r.unknown_group.?);
}

test "parseListArgs: --installed flag" {
    const r = parseListArgs(&.{"--installed"});
    try std.testing.expect(r.installed_only);
    try std.testing.expect(!r.details_mode);
}

test "parseListArgs: -i shorthand" {
    const r = parseListArgs(&.{"-i"});
    try std.testing.expect(r.installed_only);
}

test "parseListArgs: --pinned implies installed" {
    const r = parseListArgs(&.{"--pinned"});
    try std.testing.expect(r.pinned_only);
    try std.testing.expect(r.installed_only);
}

test "parseListArgs: --details implies installed" {
    const r = parseListArgs(&.{"--details"});
    try std.testing.expect(r.details_mode);
    try std.testing.expect(r.installed_only);
}

test "parseListArgs: -l shorthand implies installed" {
    const r = parseListArgs(&.{"-l"});
    try std.testing.expect(r.details_mode);
    try std.testing.expect(r.installed_only);
}

test "parseListArgs: positional with flags" {
    const r = parseListArgs(&.{ "k8s", "--installed" });
    try std.testing.expectEqual(tool_mod.Group.k8s, r.group_filter.?);
    try std.testing.expect(r.installed_only);
}

