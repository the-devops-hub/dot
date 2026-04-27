const std = @import("std");

const max_id_len = 64;
const max_version_len = 64;

/// Tool IDs: lowercase alphanumeric, hyphens, underscores only. Max 64 chars.
pub fn isValidToolId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// Version strings: alphanumeric, dots, hyphens, plus. No path separators or spaces.
pub fn isValidVersion(v: []const u8) bool {
    if (v.len == 0 or v.len > max_version_len) return false;
    for (v) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '+') return false;
    }
    return true;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "isValidToolId: valid IDs" {
    try std.testing.expect(isValidToolId("helm"));
    try std.testing.expect(isValidToolId("kubectl"));
    try std.testing.expect(isValidToolId("my-tool"));
    try std.testing.expect(isValidToolId("my_tool"));
    try std.testing.expect(isValidToolId("tool123"));
    try std.testing.expect(isValidToolId("k9s"));
}

test "isValidToolId: invalid IDs" {
    try std.testing.expect(!isValidToolId(""));
    try std.testing.expect(!isValidToolId("tool with spaces"));
    try std.testing.expect(!isValidToolId("tool;rm -rf /"));
    try std.testing.expect(!isValidToolId("../evil"));
    try std.testing.expect(!isValidToolId("tool/path"));
    try std.testing.expect(!isValidToolId("tool\x00null"));
    try std.testing.expect(!isValidToolId("$(evil)"));
    // 65 chars — one over the limit
    try std.testing.expect(!isValidToolId("a" ** 65));
}

test "isValidVersion: valid versions" {
    try std.testing.expect(isValidVersion("3.15.0"));
    try std.testing.expect(isValidVersion("latest"));
    try std.testing.expect(isValidVersion("1.0.0-rc.1"));
    try std.testing.expect(isValidVersion("1.0.0+build.1"));
    try std.testing.expect(isValidVersion("v3.15.0"));
    try std.testing.expect(isValidVersion("2024.01.15"));
}

test "isValidVersion: invalid versions" {
    try std.testing.expect(!isValidVersion(""));
    try std.testing.expect(!isValidVersion("3.0/../../evil"));
    try std.testing.expect(!isValidVersion("1.0 && rm -rf /"));
    try std.testing.expect(!isValidVersion("$(evil)"));
    try std.testing.expect(!isValidVersion("1.0;evil"));
    try std.testing.expect(!isValidVersion("1.0\nnewline"));
    try std.testing.expect(!isValidVersion("a" ** 65));
}

