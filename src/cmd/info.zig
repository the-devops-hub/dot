const std = @import("std");
const tool_mod = @import("../tool.zig");
const state_mod = @import("../state.zig");
const output = @import("../ui/output.zig");

const help =
    \\Usage: dot info <tool>
    \\
    \\Show detailed information about a tool.
    \\
    \\Options:
    \\  --help, -h    Show this help
    \\
    \\Examples:
    \\  dot info kubectl
    \\  dot info helm
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

    if (args.len == 0) {
        output.printRaw(help);
        return;
    }

    const query = args[0];

    // Find tool by id or alias
    var found: ?*const tool_mod.Tool = null;
    for (tools) |*t| {
        if (std.mem.eql(u8, t.id, query)) { found = t; break; }
        for (t.aliases) |a| {
            if (std.mem.eql(u8, a, query)) { found = t; break; }
        }
        if (found != null) break;
    }

    if (found == null) {
        output.printUnknownTool(query);
        return;
    }

    const t = found.?;
    const entry = state.tools.get(t.id);

    // Header: "==> name — description"
    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "{s} — {s}", .{ t.name, t.description }) catch t.name;
    output.printSectionHeader(hdr);

    // Details block
    output.printFmt("\n", .{});
    output.printFmt("  {s}Homepage:{s}     {s}\n", .{ output.bold, output.reset, t.homepage });

    // Groups
    var grp_buf: [64]u8 = undefined;
    var gw: std.Io.Writer = .fixed(&grp_buf);
    for (t.groups, 0..) |g, i| {
        if (i > 0) gw.writeByte(',') catch {};
        gw.writeAll(@tagName(g)) catch {};
    }
    const grp = gw.buffered();
    if (grp.len > 0) {
        output.printFmt("  {s}Groups:{s}       {s}\n", .{ output.bold, output.reset, grp });
    }

    // Aliases
    if (t.aliases.len > 0) {
        var alias_buf: [64]u8 = undefined;
        var aw: std.Io.Writer = .fixed(&alias_buf);
        for (t.aliases, 0..) |a, i| {
            if (i > 0) aw.writeAll(", ") catch {};
            aw.writeAll(a) catch {};
        }
        output.printFmt("  {s}Aliases:{s}      {s}\n", .{ output.bold, output.reset, aw.buffered() });
    }

    // Status section
    output.printSectionHeader("Status");
    output.printFmt("\n", .{});

    if (entry) |e| {
        const home = @import("../env.zig").getenv("HOME") orelse "";
        var bin_buf: [512]u8 = undefined;
        const bin_path = std.fmt.bufPrint(&bin_buf, "{s}/.local/bin/{s}", .{ home, t.id }) catch "";
        const pin_str: []const u8 = if (e.pinned) "yes" else "no";
        output.printFmt("  {s}Installed:{s}    {s}{s}{s}\n", .{ output.bold, output.reset, output.green, e.version, output.reset });
        output.printFmt("  {s}Binary:{s}       {s}\n", .{ output.bold, output.reset, bin_path });
        if (e.installed_at.len > 0) {
            var date_buf: [24]u8 = undefined;
            const date = output.fmtTimestamp(e.installed_at, &date_buf);
            output.printFmt("  {s}Installed at:{s} {s}\n", .{ output.bold, output.reset, date });
        }
        output.printFmt("  {s}Method:{s}       {s}\n", .{ output.bold, output.reset, e.method });
        output.printFmt("  {s}Pinned:{s}       {s}\n", .{ output.bold, output.reset, pin_str });

        // Resolve latest version (non-fatal)
        const latest = t.version_source.resolve(allocator) catch null;
        defer if (latest) |l| allocator.free(l);
        if (latest) |l| {
            if (std.mem.eql(u8, l, e.version)) {
                output.printFmt("  {s}Latest:{s}       {s}up to date{s}\n", .{ output.bold, output.reset, output.green, output.reset });
            } else {
                output.printFmt("  {s}Latest:{s}       {s} {s}(update available){s}\n", .{ output.bold, output.reset, l, output.yellow, output.reset });
            }
        }
    } else {
        output.printFmt("  {s}not installed{s}\n", .{ output.dim, output.reset });
        output.printFmt("\n  Run '{s}dot install {s}{s}' to install.\n", .{ output.bold, t.id, output.reset });
    }

    // Quick start
    if (t.quick_start.len > 0) {
        output.printSectionHeader("Quick Start");
        output.printFmt("\n", .{});
        for (t.quick_start) |line| {
            output.printFmt("  {s}\n", .{line});
        }
    }

    // Resources
    if (t.resources.len > 0) {
        output.printSectionHeader("Resources");
        output.printFmt("\n", .{});
        for (t.resources) |r| {
            output.printFmt("  {s}{s}{s}: {s}\n", .{ output.bold, r.label, output.reset, r.url });
        }
    }

    output.printFmt("\n", .{});
}

