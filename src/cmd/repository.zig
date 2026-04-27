const std = @import("std");
const state_mod = @import("../state.zig");
const loader = @import("../repository/loader.zig");
const http = @import("../http.zig");
const output = @import("../ui/output.zig");
const io_ctx = @import("../io_ctx.zig");

const help =
    \\Usage: dot repository <subcommand> [args]
    \\
    \\Manage external tool repositories.
    \\
    \\Subcommands:
    \\  add <url>          Add a repository from a URL
    \\  list               List registered repositories
    \\  remove <name>      Remove a repository by name
    \\  update [name]      Force-refresh one or all repositories
    \\
    \\Examples:
    \\  dot repository add https://raw.githubusercontent.com/me/dot-repo/main/repository.json
    \\  dot repository list
    \\  dot repository remove mytools
    \\  dot repository update
    \\  dot repository update mytools
    \\
;

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, state: *state_mod.State) !void {
    _ = state;

    if (args.len == 0) {
        output.printRaw(help);
        return;
    }

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            output.printRaw(help);
            return;
        }
    }

    const subcmd = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, subcmd, "add")) {
        return cmdAdd(allocator, rest);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        return cmdList(allocator);
    } else if (std.mem.eql(u8, subcmd, "remove") or std.mem.eql(u8, subcmd, "rm")) {
        return cmdRemove(allocator, rest);
    } else if (std.mem.eql(u8, subcmd, "update")) {
        return cmdUpdate(allocator, rest);
    } else {
        output.printFmt("Unknown repository subcommand: {s}\nRun 'dot repository --help' for usage.\n", .{subcmd});
    }
}

fn cmdAdd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        output.printError("Usage: dot repository add <url>");
        return;
    }
    const url = args[0];

    output.printStep("Fetching", output.sym_arrow, url);

    const body = http.get(allocator, url) catch |e| {
        output.printFmt("{s}Error:{s} could not fetch repository: {s}\n", .{ output.red, output.reset, @errorName(e) });
        return;
    };
    defer allocator.free(body);

    // Parse name from JSON
    const name = loader.parseNameFromJson(allocator, body) catch |e| {
        output.printFmt("{s}Error:{s} repository JSON missing 'name' field ({s})\n", .{ output.red, output.reset, @errorName(e) });
        return;
    };
    defer allocator.free(name);

    const tool_count = loader.countToolsInJson(allocator, body);

    // Load existing sources and check for duplicates
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const existing = loader.loadRepositories(arena_alloc, allocator) catch &.{};
    for (existing) |s| {
        if (std.mem.eql(u8, s.name, name)) {
            output.printFmt("{s}Error:{s} repository '{s}' already added\n", .{ output.red, output.reset, name });
            return;
        }
    }

    // Write cache file
    const dir = try loader.configDir(allocator);
    defer allocator.free(dir);
    const io = io_ctx.get();
    try std.Io.Dir.cwd().createDirPath(io, dir);

    const cache_filename = try std.fmt.allocPrint(allocator, "repository-{s}.json", .{name});
    defer allocator.free(cache_filename);
    const cache_path = try std.fs.path.join(allocator, &.{ dir, cache_filename });
    defer allocator.free(cache_path);

    const cache_file = try std.Io.Dir.cwd().createFile(io, cache_path, .{});
    defer cache_file.close(io);
    var cache_write_buf: [4096]u8 = undefined;
    var cache_writer = cache_file.writerStreaming(io, &cache_write_buf);
    try cache_writer.interface.writeAll(body);
    try cache_writer.interface.flush();

    // Append to repositories.json
    const now = std.Io.Timestamp.now(io_ctx.get(), .real).toSeconds();
    const now_str = try std.fmt.allocPrint(arena_alloc, "{d}", .{now});

    var new_sources: std.ArrayList(loader.RepositorySource) = .empty;
    try new_sources.appendSlice(arena_alloc, existing);
    try new_sources.append(arena_alloc, .{
        .name = try arena_alloc.dupe(u8, name),
        .url = try arena_alloc.dupe(u8, url),
        .added_at = now_str,
        .fetched_at = now_str,
    });

    try loader.saveRepositories(allocator, new_sources.items);

    var added_buf: [128]u8 = undefined;
    const added_detail = std.fmt.bufPrint(&added_buf, "'{s}' — {d} tool{s} available", .{
        name, tool_count, if (tool_count == 1) @as([]const u8, "") else "s",
    }) catch name;
    output.printStep("Added", output.sym_ok, added_detail);
}

fn cmdList(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const sources = loader.loadRepositories(arena_alloc, allocator) catch &.{};

    if (sources.len == 0) {
        output.printFmt("No external repositories configured.\nAdd one with: dot repository add <url>\n\n", .{});
        return;
    }

    output.printSectionHeader("External Repositories");
    output.printFmt("\n{s}{s:<20} {s:<8} {s:<24} {s}{s}\n", .{
        output.bold, "Name", "Tools", "Last Fetched", "URL", output.reset,
    });

    for (sources) |s| {
        // Count tools from cache
        const tool_count = blk: {
            const filename = std.fmt.allocPrint(allocator, "repository-{s}.json", .{s.name}) catch break :blk 0;
            defer allocator.free(filename);
            const dir = loader.configDir(allocator) catch break :blk 0;
            defer allocator.free(dir);
            const path = std.fs.path.join(allocator, &.{ dir, filename }) catch break :blk 0;
            defer allocator.free(path);
            const list_io = io_ctx.get();
            const file = std.Io.Dir.cwd().openFile(list_io, path, .{}) catch break :blk 0;
            defer file.close(list_io);
            var list_read_buf: [4096]u8 = undefined;
            var list_reader = file.readerStreaming(list_io, &list_read_buf);
            const content = list_reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024)) catch break :blk 0;
            defer allocator.free(content);
            break :blk loader.countToolsInJson(allocator, content);
        };

        // Format fetched time
        const fetched_at_n = std.fmt.parseInt(i64, s.fetched_at, 10) catch 0;
        var date_buf: [32]u8 = undefined;
        const fetched_str: []const u8 = if (fetched_at_n == 0) "never" else blk: {
            const secs: u64 = @intCast(fetched_at_n);
            const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
            const year_day = epoch.getEpochDay().calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            break :blk std.fmt.bufPrint(&date_buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
                year_day.year, month_day.month.numeric(), month_day.day_index + 1,
            }) catch "?";
        };

        const url_trunc = s.url[0..@min(s.url.len, 40)];
        output.printFmt("{s:<20} {d:<8} {s:<24} {s}\n", .{
            s.name[0..@min(s.name.len, 19)], tool_count, fetched_str, url_trunc,
        });
    }

    output.printFmt("\n{d} repositor{s} configured\n\n", .{
        sources.len, if (sources.len == 1) "y" else "ies",
    });
}

fn cmdRemove(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        output.printError("Usage: dot repository remove <name>");
        return;
    }
    const name = args[0];

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const sources = loader.loadRepositories(arena_alloc, allocator) catch &.{};

    var found = false;
    var new_sources: std.ArrayList(loader.RepositorySource) = .empty;
    for (sources) |s| {
        if (std.mem.eql(u8, s.name, name)) {
            found = true;
        } else {
            try new_sources.append(arena_alloc, s);
        }
    }

    if (!found) {
        output.printFmt("{s}Error:{s} repository '{s}' not found\n", .{ output.red, output.reset, name });
        return;
    }

    try loader.saveRepositories(allocator, new_sources.items);

    // Delete cache file
    const dir = loader.configDir(allocator) catch null;
    if (dir) |d| {
        defer allocator.free(d);
        const filename = try std.fmt.allocPrint(allocator, "repository-{s}.json", .{name});
        defer allocator.free(filename);
        const path = try std.fs.path.join(allocator, &.{ d, filename });
        defer allocator.free(path);
        std.Io.Dir.cwd().deleteFile(io_ctx.get(), path) catch {};
    }

    output.printStep("Removed", output.sym_ok, name);
}

fn cmdUpdate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const sources = loader.loadRepositories(arena_alloc, allocator) catch &.{};

    if (sources.len == 0) {
        output.printFmt("No repositories configured.\n", .{});
        return;
    }

    const target: ?[]const u8 = if (args.len > 0) args[0] else null;

    for (sources) |s| {
        if (target) |t| {
            if (!std.mem.eql(u8, s.name, t)) continue;
        }

        output.printStep("Updating", output.sym_arrow, s.name);
        loader.fetchAndCache(allocator, s.name, s.url) catch |e| {
            output.printFmt("{s}{s}{s} {s}: fetch failed ({s}) — using cached\n", .{
                output.red, output.sym_fail, output.reset, s.name, @errorName(e),
            });
            continue;
        };

        // Count tools in updated cache
        const tool_count = blk: {
            const filename = std.fmt.allocPrint(allocator, "repository-{s}.json", .{s.name}) catch break :blk 0;
            defer allocator.free(filename);
            const dir = loader.configDir(allocator) catch break :blk 0;
            defer allocator.free(dir);
            const path = std.fs.path.join(allocator, &.{ dir, filename }) catch break :blk 0;
            defer allocator.free(path);
            const rm_io = io_ctx.get();
            const file = std.Io.Dir.cwd().openFile(rm_io, path, .{}) catch break :blk 0;
            defer file.close(rm_io);
            var rm_read_buf: [4096]u8 = undefined;
            var rm_reader = file.readerStreaming(rm_io, &rm_read_buf);
            const content = rm_reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024)) catch break :blk 0;
            defer allocator.free(content);
            break :blk loader.countToolsInJson(allocator, content);
        };

        var updated_buf: [64]u8 = undefined;
        const updated_detail = std.fmt.bufPrint(&updated_buf, "'{s}' — {d} tool{s}", .{
            s.name, tool_count, if (tool_count == 1) @as([]const u8, "") else "s",
        }) catch s.name;
        output.printStep("Updated", output.sym_ok, updated_detail);
    }
}
