const std = @import("std");
const http = @import("../http.zig");
const platform = @import("../platform.zig");
const archive = @import("../archive.zig");
const output = @import("../ui/output.zig");
const state_mod = @import("../state.zig");
const tool_mod = @import("../tool.zig");
const version_mod = @import("../version.zig");
const progress_mod = @import("../ui/progress.zig");
const io_ctx = @import("../io_ctx.zig");
const paths = @import("../paths.zig");
const env = @import("../env.zig");

const help =
    \\Usage: dot update [--force]
    \\
    \\Update dot itself to the latest release from GitHub.
    \\
    \\Options:
    \\  --force       Download and install even if already up to date
    \\  --help, -h    Show this help
    \\
    \\Examples:
    \\  dot update
    \\  dot update --force
    \\
;

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    state: *state_mod.State,
) !void {
    var force = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            output.printRaw(help);
            return;
        }
        if (std.mem.eql(u8, a, "--force")) force = true;
    }

    // Resolve latest version from GitHub
    output.printStep("Checking", output.sym_ok, "dot");
    const version_source = tool_mod.VersionSource{ .github_release = .{ .repo = version_mod.github_repo } };
    const latest = version_source.resolve(allocator) catch |e| {
        const api_url = "https://api.github.com/repos/" ++ version_mod.github_repo ++ "/releases";
        switch (e) {
            error.VersionFetchFailed => {
                output.printError("could not reach GitHub API");
                output.printFmt("  URL: {s}\n", .{api_url});
                output.printFmt("  The repository may be private, or you may be offline.\n", .{});
            },
            error.VersionNotFound => {
                output.printError("no stable releases found");
                output.printFmt("  URL: {s}\n", .{api_url});
                output.printFmt("  No releases have been published yet.\n", .{});
            },
            error.VersionParseFailed => {
                output.printError("unexpected response from GitHub API");
                output.printFmt("  URL: {s}\n", .{api_url});
            },
            else => output.printError(@errorName(e)),
        }
        return;
    };
    defer allocator.free(latest);

    const current = version_mod.current;

    if (!force and std.mem.eql(u8, current, latest)) {
        output.printFmt("{s}Warning:{s} dot {s} is already up to date.\n", .{
            output.yellow, output.reset, current,
        });
        output.printFmt("To reinstall: dot update --force\n", .{});
        return;
    }

    var dl_buf: [128]u8 = undefined;
    const dl_step = std.fmt.bufPrint(&dl_buf, "Downloading dot {s}", .{latest}) catch "Downloading dot";
    output.printStep(dl_step, output.sym_ok, "");

    const os_type = platform.OperatingSystem.current();
    const arch_type = platform.Arch.current();

    // Asset is a tarball named dot-{os}-{arch}.tar.gz (e.g. dot-linux-amd64.tar.gz).
    const url = try std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/releases/download/v{s}/dot-{s}-{s}.tar.gz",
        .{ version_mod.github_repo, latest, os_type.name(), arch_type.goName() },
    );
    defer allocator.free(url);

    // Temp directory for download and extraction
    const tmp_dir = try std.fmt.allocPrint(allocator, paths.fallback_home ++ "/dot-update-{s}", .{latest});
    defer allocator.free(tmp_dir);
    const io = io_ctx.get();
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    const archive_path = try std.fs.path.join(allocator, &.{ tmp_dir, "dot.tar.gz" });
    defer allocator.free(archive_path);

    // Download the tarball
    var bar = progress_mod.ProgressBar{};
    const progress = http.ProgressCallback{ .context = &bar, .func = progressCbFn };

    http.download(allocator, url, archive_path, progress) catch |e| {
        bar.finish();
        var status_buf: [32]u8 = undefined;
        const hint: []const u8 = switch (http.last_status) {
            404 => "release asset not found — the binary may not exist for your platform yet",
            403 => "access denied — repository may be private",
            0 => @errorName(e),
            else => std.fmt.bufPrint(&status_buf, "HTTP {d}", .{http.last_status}) catch unreachable,
        };
        output.printStep("Download", output.sym_fail, hint);
        output.printFmt("  URL: {s}\n", .{url});
        output.printError("Update failed");
        return error.CommandFailed;
    };
    bar.finish();

    // Extract
    const extract_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "extract" });
    defer allocator.free(extract_dir);

    archive.extractTarGz(archive_path, extract_dir, 0) catch |e| {
        output.printError(@errorName(e));
        return error.CommandFailed;
    };

    // The binary inside the tarball is named "dot"
    const src_bin = try std.fs.path.join(allocator, &.{ extract_dir, "dot" });
    defer allocator.free(src_bin);

    // Install path
    const home = env.getenv("HOME") orelse paths.fallback_home;
    const bin_dir = try std.fs.path.join(allocator, &.{ home, paths.local_dir, paths.bin_dir });
    defer allocator.free(bin_dir);
    std.Io.Dir.cwd().createDirPath(io, bin_dir) catch {};

    const dest = try std.fs.path.join(allocator, &.{ bin_dir, "dot" });
    defer allocator.free(dest);
    const tmp_dest = try std.fmt.allocPrint(allocator, "{s}" ++ paths.new_file_suffix, .{dest});
    defer allocator.free(tmp_dest);

    // Copy, set executable, atomic rename
    std.Io.Dir.cwd().copyFile(src_bin, std.Io.Dir.cwd(), tmp_dest, io, .{}) catch |e| {
        output.printStep("Install", output.sym_fail, @errorName(e));
        output.printError("Could not copy binary");
        return error.CommandFailed;
    };

    const tmp_file = try std.Io.Dir.cwd().openFile(io, tmp_dest, .{});
    defer tmp_file.close(io);
    try tmp_file.setPermissions(io, .executable_file);

    std.Io.Dir.cwd().rename(tmp_dest, std.Io.Dir.cwd(), dest, io) catch |e| {
        output.printStep("Install", output.sym_fail, @errorName(e));
        output.printError("Could not replace binary");
        return error.CommandFailed;
    };

    output.printStep("Installing dot", output.sym_ok, "");
    output.printDetail(dest);

    // Update state
    try state.addTool("dot", latest, tool_mod.method_github_release, false);
}

fn progressCbFn(ctx: *anyopaque, done: u64, total: ?u64) void {
    const bar: *progress_mod.ProgressBar = @ptrCast(@alignCast(ctx));
    bar.update(done, total, "");
}
