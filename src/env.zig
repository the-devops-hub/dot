const std = @import("std");

var g_environ: std.process.Environ = .empty;

/// Call once at startup with the environ from std.process.Init.Minimal.
pub fn init(environ: std.process.Environ) void {
    g_environ = environ;
}

/// Scan the process environment for `key`. Returns the value slice or null.
/// Equivalent to the old std.posix.getenv.
pub fn getenv(key: []const u8) ?[]const u8 {
    const view = g_environ.block.view();
    for (view.slice) |entry| {
        const pair = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}
