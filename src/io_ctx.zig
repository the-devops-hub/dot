const std = @import("std");
const builtin = @import("builtin");

var g_io: std.Io = undefined;

/// Call once at startup with the io from std.process.Init.
pub fn init(io: std.Io) void {
    g_io = io;
}

/// Returns the process Io context. In tests, returns std.testing.io.
pub fn get() std.Io {
    if (builtin.is_test) return std.testing.io;
    return g_io;
}
