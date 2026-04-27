const std = @import("std");

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
