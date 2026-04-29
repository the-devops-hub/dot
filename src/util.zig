const std = @import("std");
const env = @import("env.zig");
const io_ctx = @import("io_ctx.zig");

const max_edit_len = 64;

// Thread-local so zwanzig's stack-escape analysis doesn't flag the return value.
// Safe for this CLI (single-threaded); thread-local is re-entrant per thread.
threadlocal var edit_row: [max_edit_len + 1]usize = undefined;

/// Levenshtein distance between a and b. Inputs longer than 64 chars are truncated.
/// Uses a single-row DP algorithm so memory cost is O(n) not O(n*m).
pub fn editDistance(a: []const u8, b: []const u8) usize {
    const la = @min(a.len, max_edit_len);
    const lb = @min(b.len, max_edit_len);
    if (la == 0) return lb;
    if (lb == 0) return la;

    for (0..lb + 1) |j| edit_row[j] = j;
    for (0..la) |i| {
        var diag = edit_row[0];
        edit_row[0] = i + 1;
        for (0..lb) |j| {
            const above = edit_row[j + 1];
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            edit_row[j + 1] = @min(edit_row[j] + 1, @min(above + 1, diag + cost));
            diag = above;
        }
    }
    return edit_row[lb];
}

/// Walk $PATH and return the first entry where `name` exists and is executable.
/// Returned slice is allocated by `allocator` — caller owns it.
pub fn findInPath(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    const path_env = env.getenv("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
        std.Io.Dir.cwd().access(io_ctx.get(), full, .{ .execute = true }) catch {
            allocator.free(full);
            continue;
        };
        return full;
    }
    return null;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "editDistance: identical strings" {
    try std.testing.expectEqual(@as(usize, 0), editDistance("list", "list"));
    try std.testing.expectEqual(@as(usize, 0), editDistance("", ""));
}

test "editDistance: empty string" {
    try std.testing.expectEqual(@as(usize, 4), editDistance("", "list"));
    try std.testing.expectEqual(@as(usize, 4), editDistance("list", ""));
}

test "editDistance: one substitution" {
    try std.testing.expectEqual(@as(usize, 1), editDistance("lisT", "list"));
}

test "editDistance: one insertion" {
    try std.testing.expectEqual(@as(usize, 1), editDistance("ist", "list"));
}

test "editDistance: one deletion" {
    try std.testing.expectEqual(@as(usize, 1), editDistance("listt", "list"));
}

test "editDistance: transposition costs 2" {
    try std.testing.expectEqual(@as(usize, 2), editDistance("lsit", "list"));
}

test "editDistance: completely different" {
    try std.testing.expect(editDistance("xyz", "list") > 3);
}

test "editDistance: tool id examples" {
    try std.testing.expectEqual(@as(usize, 1), editDistance("helms", "helm"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("kubctl", "kubectl"));
}

test "findInPath: finds sh in PATH" {
    // sh is present on every target system; if PATH is set, we should find it.
    const allocator = std.testing.allocator;
    const found = findInPath(allocator, "sh") orelse return error.SkipZigTest;
    defer allocator.free(found);
    try std.testing.expect(found.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, found, "/sh"));
}

test "findInPath: returns null for nonexistent binary" {
    const allocator = std.testing.allocator;
    const found = findInPath(allocator, "this-binary-does-not-exist-dot-toolbox");
    try std.testing.expectEqual(@as(?[]u8, null), found);
}
