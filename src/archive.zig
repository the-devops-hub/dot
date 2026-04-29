const std = @import("std");
const io_ctx = @import("io_ctx.zig");

/// Extract a .tar.gz archive to a destination directory.
/// strip_components: number of leading path components to strip (like tar --strip-components).
pub fn extractTarGz(archive_path: []const u8, dest_path: []const u8, strip_components: u32) !void {
    const io = io_ctx.get();
    try std.Io.Dir.cwd().createDirPath(io, dest_path);
    const dest_dir = try std.Io.Dir.cwd().openDir(io, dest_path, .{});
    defer dest_dir.close(io);

    const file = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
    defer file.close(io);

    var file_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, &decomp_buf);

    try std.tar.pipeToFileSystem(io, dest_dir, &decomp.reader, .{
        .strip_components = strip_components,
    });
}

/// Extract a .tar.xz archive using the Zig standard library (no system `tar` required).
pub fn extractTarXz(archive_path: []const u8, dest_path: []const u8, strip_components: u32, allocator: std.mem.Allocator) !void {
    const io = io_ctx.get();
    try std.Io.Dir.cwd().createDirPath(io, dest_path);
    const dest_dir = try std.Io.Dir.cwd().openDir(io, dest_path, .{});
    defer dest_dir.close(io);

    const file = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
    defer file.close(io);

    var file_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    const decomp_buf = try allocator.alloc(u8, 64 * 1024);
    var decomp = try std.compress.xz.Decompress.init(&file_reader.interface, allocator, decomp_buf);
    defer decomp.deinit();

    try std.tar.pipeToFileSystem(io, dest_dir, &decomp.reader, .{
        .strip_components = strip_components,
    });
}

/// Extract a .zip archive using the Zig standard library (no system `unzip` required).
pub fn extractZip(archive_path: []const u8, dest_path: []const u8) !void {
    const io = io_ctx.get();
    try std.Io.Dir.cwd().createDirPath(io, dest_path);
    const dest_dir = try std.Io.Dir.cwd().openDir(io, dest_path, .{});
    defer dest_dir.close(io);

    const file = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
    defer file.close(io);

    var file_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    try std.zip.extract(dest_dir, &file_reader, .{});
}

// ─── Tests ────────────────────────────────────────────────────────────────────
//
// Archive tests use system `tar`/`zip` to create fixtures. Both are available
// on any system this tool targets. If not found, the test is skipped via
// `return error.SkipZigTest`.

/// Run a shell command, return false if it fails or is not found.
fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) bool {
    const result = std.process.run(allocator, io_ctx.get(), .{ .argv = argv }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

test "extractTarGz: single file, strip_components=0" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a source file and pack it with system tar
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hello.txt", .data = "hello world\n" });
    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    const archive = try std.fmt.allocPrint(allocator, "{s}/test.tar.gz", .{tmp_path});
    defer allocator.free(archive);

    if (!runCmd(allocator, &.{ "tar", "-czf", archive, "-C", tmp_path, "hello.txt" }))
        return error.SkipZigTest;

    // Extract into a subdirectory and verify
    const out = try std.fmt.allocPrint(allocator, "{s}/out", .{tmp_path});
    defer allocator.free(out);
    try extractTarGz(archive, out, 0);

    const content = try tmp.dir.readFileAlloc(std.testing.io, "out/hello.txt", allocator, .limited(4096));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("hello world\n", content);
}

test "extractTarGz: strip_components=1 strips top-level directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "pkg");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pkg/binary", .data = "#!/bin/sh\n" });
    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    const archive = try std.fmt.allocPrint(allocator, "{s}/pkg.tar.gz", .{tmp_path});
    defer allocator.free(archive);

    if (!runCmd(allocator, &.{ "tar", "-czf", archive, "-C", tmp_path, "pkg" }))
        return error.SkipZigTest;

    const out = try std.fmt.allocPrint(allocator, "{s}/out", .{tmp_path});
    defer allocator.free(out);
    try extractTarGz(archive, out, 1); // strip "pkg/" prefix

    // "binary" should be at out/binary, not out/pkg/binary
    const content = try tmp.dir.readFileAlloc(std.testing.io, "out/binary", allocator, .limited(4096));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("#!/bin/sh\n", content);
}

test "extractTarXz: single file, strip_components=0" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hello.txt", .data = "hello xz\n" });
    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    const archive = try std.fmt.allocPrint(allocator, "{s}/test.tar.xz", .{tmp_path});
    defer allocator.free(archive);

    if (!runCmd(allocator, &.{ "tar", "-cJf", archive, "-C", tmp_path, "hello.txt" }))
        return error.SkipZigTest;

    const out = try std.fmt.allocPrint(allocator, "{s}/out", .{tmp_path});
    defer allocator.free(out);
    try extractTarXz(archive, out, 0, allocator);

    const content = try tmp.dir.readFileAlloc(std.testing.io, "out/hello.txt", allocator, .limited(4096));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("hello xz\n", content);
}

test "extractTarXz: strip_components=1 strips top-level directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "pkg");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pkg/binary", .data = "xz binary\n" });
    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    const archive = try std.fmt.allocPrint(allocator, "{s}/pkg.tar.xz", .{tmp_path});
    defer allocator.free(archive);

    if (!runCmd(allocator, &.{ "tar", "-cJf", archive, "-C", tmp_path, "pkg" }))
        return error.SkipZigTest;

    const out = try std.fmt.allocPrint(allocator, "{s}/out", .{tmp_path});
    defer allocator.free(out);
    try extractTarXz(archive, out, 1, allocator);

    const content = try tmp.dir.readFileAlloc(std.testing.io, "out/binary", allocator, .limited(4096));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("xz binary\n", content);
}

test "extractZip: single file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data.txt", .data = "zip content\n" });
    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_path);

    const archive = try std.fmt.allocPrint(allocator, "{s}/test.zip", .{tmp_path});
    defer allocator.free(archive);
    const src = try std.fmt.allocPrint(allocator, "{s}/data.txt", .{tmp_path});
    defer allocator.free(src);

    if (!runCmd(allocator, &.{ "zip", "-j", archive, src }))
        return error.SkipZigTest;

    const out = try std.fmt.allocPrint(allocator, "{s}/out", .{tmp_path});
    defer allocator.free(out);
    try extractZip(archive, out);

    const content = try tmp.dir.readFileAlloc(std.testing.io, "out/data.txt", allocator, .limited(4096));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("zip content\n", content);
}
