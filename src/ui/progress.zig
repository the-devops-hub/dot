const std = @import("std");
const output = @import("output.zig");
const io_ctx = @import("../io_ctx.zig");

/// Minimum milliseconds between redraws. Prevents flickering on fast connections.
const redraw_interval_ms: i64 = 50; // 20 fps max
const progress_bar_width: usize = 67;
const bytes_per_mb: u64 = 1024 * 1024;
const bytes_per_kb: u64 = 1024;

/// Download progress: brew-style `###...100.0%` fill bar.
///
/// Call `update(current, total, detail)` each chunk, then `finish()` when done.
/// finish() is also called automatically from update() the moment current >= total.
pub const ProgressBar = struct {
    /// Tracked by update(); used by finish() for pipe-mode summary.
    bytes_done: u64 = 0,
    bytes_total: ?u64 = null,
    /// Set by finish() to make it idempotent.
    finished: bool = false,
    /// Set to true once renderLine() has drawn at least one frame.
    rendered: bool = false,
    /// Timestamp (ms) of last redraw, for rate limiting.
    last_draw_ms: i64 = 0,

    pub fn update(self: *ProgressBar, current: u64, total: ?u64, detail: []const u8) void {
        if (self.finished) return;

        self.bytes_done = current;
        self.bytes_total = total;

        const mode = output.getRenderMode();
        if (mode == .rich or mode == .plain) {
            const now = std.Io.Timestamp.now(io_ctx.get(), .real).toMilliseconds();
            const at_100 = if (total) |t| current >= t else false;
            if (at_100 or now - self.last_draw_ms >= redraw_interval_ms) {
                self.last_draw_ms = now;
                self.renderLine(current, total, detail);
            }
        }

        if (total) |t| {
            if (current >= t) self.finish();
        }
    }

    fn renderLine(self: *ProgressBar, current: u64, total: ?u64, detail: []const u8) void {
        _ = detail;
        self.rendered = true;
        const mode = output.getRenderMode();
        const line_start: []const u8 = if (mode == .rich) "\r\x1b[2K" else "\r";

        var buf: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);

        if (total) |t| {
            // pct in tenths of a percent (0–1000) so we can print "X.Y%"
            const pct: u64 = if (t > 0) @min(current * 1000 / t, 1000) else 0;
            const bar_width = progress_bar_width;
            const filled: usize = @intCast(pct * bar_width / 1000);
            writer.print("{s}   ", .{line_start}) catch return;
            var i: usize = 0;
            while (i < bar_width) : (i += 1) {
                writer.writeByte(if (i < filled) '#' else ' ') catch return;
            }
            writer.print(" {d}.{d}%", .{ pct / 10, pct % 10 }) catch return;
        } else {
            // Unknown content-length: show bytes transferred only
            var done_buf: [32]u8 = undefined;
            writer.print("{s}   {s}", .{ line_start, fmtBytes(current, &done_buf) }) catch return;
        }

        output.printFmt("{s}", .{writer.buffered()});
    }

    /// Lock the line in place and move to the next line so subsequent output
    /// doesn't overwrite it. In pipe mode, prints a single summary line.
    /// Safe to call multiple times — only acts on the first call.
    pub fn finish(self: *ProgressBar) void {
        if (self.finished) return;
        self.finished = true;

        switch (output.getRenderMode()) {
            .silent => {},
            .pipe => {
                // In pipe mode renderLine is never called; print a one-line summary.
                const final_bytes = self.bytes_total orelse self.bytes_done;
                var bytes_buf: [32]u8 = undefined;
                output.printFmt("   {s}\n", .{fmtBytes(final_bytes, &bytes_buf)});
            },
            // rich/plain: renderLine already drew the final 100% bar; just end the line.
            .rich, .plain => {
                if (self.rendered) output.printFmt("\n", .{});
            },
        }
    }
};

pub fn fmtBytes(bytes: u64, buf: []u8) []const u8 {
    if (bytes >= bytes_per_mb) {
        const megabytes = bytes / bytes_per_mb;
        const frac = (bytes % bytes_per_mb) * 10 / bytes_per_mb;
        return std.fmt.bufPrint(buf, "{d}.{d} MB", .{ megabytes, frac }) catch "???";
    } else if (bytes >= bytes_per_kb) {
        const kilobytes = bytes / bytes_per_kb;
        const frac = (bytes % bytes_per_kb) * 10 / bytes_per_kb;
        return std.fmt.bufPrint(buf, "{d}.{d} KB", .{ kilobytes, frac }) catch "???";
    } else {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "???";
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "fmtBytes: byte range" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", fmtBytes(0, &buf));
    try std.testing.expectEqualStrings("1 B", fmtBytes(1, &buf));
    try std.testing.expectEqualStrings("1023 B", fmtBytes(1023, &buf));
}

test "fmtBytes: kilobyte range" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.0 KB", fmtBytes(1024, &buf));
    try std.testing.expectEqualStrings("1.5 KB", fmtBytes(1536, &buf));
    try std.testing.expectEqualStrings("10.0 KB", fmtBytes(10240, &buf));
    try std.testing.expectEqualStrings("1023.9 KB", fmtBytes(1024 * 1024 - 1, &buf));
}

test "fmtBytes: megabyte range" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.0 MB", fmtBytes(1024 * 1024, &buf));
    try std.testing.expectEqualStrings("15.2 MB", fmtBytes(15 * 1024 * 1024 + 256 * 1024, &buf));
    try std.testing.expectEqualStrings("100.0 MB", fmtBytes(100 * 1024 * 1024, &buf));
}

test "ProgressBar: update stores bytes" {
    output.setRenderModeForTesting(.silent);
    defer output.setRenderModeForTesting(.rich);
    var bar = ProgressBar{};
    bar.update(1024, 10240, "");
    try std.testing.expectEqual(@as(u64, 1024), bar.bytes_done);
    try std.testing.expectEqual(@as(?u64, 10240), bar.bytes_total);
    try std.testing.expect(!bar.finished);
}

test "ProgressBar: auto-finish triggers at 100%" {
    output.setRenderModeForTesting(.silent);
    defer output.setRenderModeForTesting(.rich);
    var bar = ProgressBar{};
    bar.update(50, 100, "");
    try std.testing.expect(!bar.finished);
    bar.update(100, 100, "");
    try std.testing.expect(bar.finished);
}

test "ProgressBar: auto-finish triggers when current exceeds total" {
    output.setRenderModeForTesting(.silent);
    defer output.setRenderModeForTesting(.rich);
    var bar = ProgressBar{};
    bar.update(27_000_000, 27_000_000, "");
    try std.testing.expect(bar.finished);
    try std.testing.expectEqual(@as(u64, 27_000_000), bar.bytes_done);
}

test "ProgressBar: update is no-op after finish" {
    output.setRenderModeForTesting(.silent);
    defer output.setRenderModeForTesting(.rich);
    var bar = ProgressBar{};
    bar.update(100, 100, "");
    try std.testing.expect(bar.finished);
    bar.update(200, 200, "");
    try std.testing.expectEqual(@as(u64, 100), bar.bytes_done);
}

test "ProgressBar: explicit finish is idempotent" {
    output.setRenderModeForTesting(.silent);
    defer output.setRenderModeForTesting(.rich);
    var bar = ProgressBar{};
    bar.finish();
    bar.finish();
    try std.testing.expect(bar.finished);
}

test "ProgressBar: finish without any update leaves rendered=false" {
    output.setRenderModeForTesting(.silent);
    defer output.setRenderModeForTesting(.rich);
    var bar = ProgressBar{};
    try std.testing.expect(!bar.rendered);
    bar.finish();
    try std.testing.expect(!bar.rendered);
}

test "fill bar: 0% shows empty bar" {
    const pct: u64 = 0;
    const bar_width = progress_bar_width;
    const filled: usize = @intCast(pct * bar_width / 1000);
    try std.testing.expectEqual(@as(usize, 0), filled);
}

test "fill bar: 50% fills half the bar" {
    const pct: u64 = 500; // tenths — 500 = 50.0%
    const bar_width = progress_bar_width;
    const filled: usize = @intCast(pct * bar_width / 1000);
    try std.testing.expectEqual(@as(usize, 33), filled);
}

test "fill bar: 100% fills full bar" {
    const pct: u64 = 1000; // tenths — 1000 = 100.0%
    const bar_width = progress_bar_width;
    const filled: usize = @intCast(pct * bar_width / 1000);
    try std.testing.expectEqual(@as(usize, 67), filled);
}

test "fill bar: percentage format" {
    // 52.7% → pct=527 → pct/10=52, pct%10=7
    const pct: u64 = 527;
    try std.testing.expectEqual(@as(u64, 52), pct / 10);
    try std.testing.expectEqual(@as(u64, 7), pct % 10);
}
