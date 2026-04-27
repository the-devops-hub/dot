const std = @import("std");
const tool_mod = @import("../tool.zig");
const output = @import("../ui/output.zig");
const util = @import("../util.zig");

const rank_no_match: u8 = 255;
const suggestion_distance_threshold = 3;

const help =
    \\Usage: dot search <query>
    \\
    \\Search available tools by name, alias, or description.
    \\
    \\Options:
    \\  --help, -h    Show this help
    \\
    \\Examples:
    \\  dot search kube
    \\  dot search terraform
    \\
;

const RankedTool = struct {
    tool: *const tool_mod.Tool,
    rank: u8, // lower = better match
};

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
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

    var results: std.ArrayList(RankedTool) = .empty;
    defer results.deinit(allocator);

    for (tools) |*t| {
        const r = rank(t, query);
        if (r < rank_no_match) try results.append(allocator, .{ .tool = t, .rank = r });
    }

    // Sort: rank asc, then name asc
    std.mem.sort(RankedTool, results.items, {}, struct {
        fn lt(_: void, a: RankedTool, b: RankedTool) bool {
            if (a.rank != b.rank) return a.rank < b.rank;
            return std.mem.lessThan(u8, a.tool.id, b.tool.id);
        }
    }.lt);

    if (results.items.len == 0) {
        // Suggest closest match by editDistance
        var best_dist: usize = std.math.maxInt(usize);
        var best: ?*const tool_mod.Tool = null;
        for (tools) |*t| {
            const d = util.editDistance(query, t.id);
            if (d < best_dist) { best_dist = d; best = t; }
        }
        if (best_dist <= suggestion_distance_threshold) {
            if (best) |b| {
                output.printSectionHeaderFmt("No exact match for \"{s}\". Did you mean:", .{query});
                output.printFmt("\n  {s}{s:<14}{s}  {s}\n\n", .{ output.bold, b.id, output.reset, b.description });
            }
        } else {
            output.printSectionHeaderFmt("No tools match \"{s}\"", .{query});
            output.printFmt("\nRun 'dot list' to see all available tools.\n\n", .{});
        }
        return;
    }

    output.printSectionHeaderFmt("Results for \"{s}\" ({d})", .{ query, results.items.len });
    output.printFmt("\n{s}{s:<18} {s:<10} Description{s}\n", .{ output.bold, "Tool", "Groups", output.reset });

    for (results.items) |r| {
        const t = r.tool;

        // Build "id (alias)" label
        var label_buf: [32]u8 = undefined;
        var lw: std.Io.Writer = .fixed(&label_buf);
        lw.writeAll(t.id) catch {};
        if (t.aliases.len > 0) {
            lw.writeByte(' ') catch {};
            lw.writeByte('(') catch {};
            for (t.aliases, 0..) |a, i| {
                if (i > 0) lw.writeByte(',') catch {};
                lw.writeAll(a) catch {};
            }
            lw.writeByte(')') catch {};
        }
        const label = lw.buffered();
        const label_trunc = label[0..@min(label.len, 17)];

        // Groups string
        var grp_buf: [32]u8 = undefined;
        var gw: std.Io.Writer = .fixed(&grp_buf);
        for (t.groups, 0..) |g, i| {
            if (i > 0) gw.writeByte(',') catch {};
            gw.writeAll(@tagName(g)) catch {};
        }
        const grp = gw.buffered();
        const grp_trunc = grp[0..@min(grp.len, 9)];

        // Description (truncate to ~45 chars)
        const desc_max = 50;
        const desc_trunc = t.description[0..@min(t.description.len, desc_max)];

        output.printFmt("{s:<18} {s:<10} {s}", .{ label_trunc, grp_trunc, desc_trunc });
        if (t.description.len > desc_max) output.printFmt("…", .{});
        output.printFmt("\n", .{});
    }
    output.printFmt("\n", .{});
}

/// Returns a rank score for the tool against the query (lower = better).
/// 255 = no match.
fn rank(t: *const tool_mod.Tool, query: []const u8) u8 {
    const q_lower = query; // queries are usually already lowercase

    // Rank 0: exact id/alias match
    if (std.mem.eql(u8, t.id, q_lower)) return 0;
    for (t.aliases) |a| if (std.mem.eql(u8, a, q_lower)) return 0;

    // Rank 1: id/alias starts with query
    if (std.mem.startsWith(u8, t.id, q_lower)) return 1;
    for (t.aliases) |a| if (std.mem.startsWith(u8, a, q_lower)) return 1;

    // Rank 2: id/alias contains query
    if (containsIgnoreCase(t.id, q_lower)) return 2;
    for (t.aliases) |a| if (containsIgnoreCase(a, q_lower)) return 2;

    // Rank 3: description contains query
    if (containsIgnoreCase(t.description, q_lower)) return 3;

    // Rank 4: editDistance ≤ 2 on id
    if (util.editDistance(t.id, q_lower) <= 2) return 4;

    return rank_no_match;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) { match = false; break; }
        }
        if (match) return true;
    }
    return false;
}

