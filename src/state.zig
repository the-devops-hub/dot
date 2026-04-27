const std = @import("std");
const io_ctx = @import("io_ctx.zig");
const paths = @import("paths.zig");

const state_filename = "state.json";
const default_tool_status = "installed";
const json_key_tools = "tools";
const json_key_version = "version";
const json_key_installed_at = "installed_at";
const json_key_method = "method";
const json_key_source = "source";
const json_key_status = "status";
const json_key_pinned = "pinned";

pub const ToolEntry = struct {
    version: []const u8 = "",
    installed_at: []const u8 = "",
    method: []const u8 = "",
    source: []const u8 = "",
    status: []const u8 = default_tool_status,
    pinned: bool = false,
};

/// In-memory representation of state.json.
pub const State = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    path: []u8,
    tools: std.StringHashMap(ToolEntry),

    pub fn init(allocator: std.mem.Allocator) !State {
        const home = @import("env.zig").getenv("HOME") orelse paths.fallback_home;
        const config_dir = try std.fs.path.join(allocator, &.{ home, paths.config_dir, paths.dot_config_subdir });
        defer allocator.free(config_dir);
        try std.Io.Dir.cwd().createDirPath(io_ctx.get(), config_dir);

        const path = try std.fs.path.join(allocator, &.{ config_dir, state_filename });
        defer allocator.free(path); // initAt dupes it, so free our copy
        return initAt(allocator, path);
    }

    /// Like init but with an explicit state file path. Used in tests to avoid
    /// touching $HOME/.config/dot/state.json.
    pub fn initAt(allocator: std.mem.Allocator, state_path: []const u8) !State {
        const path = try allocator.dupe(u8, state_path);
        const arena = std.heap.ArenaAllocator.init(allocator);
        const tools = std.StringHashMap(ToolEntry).init(allocator);

        var state = State{
            .allocator = allocator,
            .arena = arena,
            .path = path,
            .tools = tools,
        };

        // Try to load existing state; ignore if missing or unreadable
        state.load() catch {};

        return state;
    }

    pub fn deinit(self: *State) void {
        self.tools.deinit();
        self.arena.deinit();
        self.allocator.free(self.path);
    }

    fn load(self: *State) !void {
        const io = io_ctx.get();
        const file = try std.Io.Dir.cwd().openFile(io, self.path, .{});
        defer file.close(io);

        var state_read_buf: [4096]u8 = undefined;
        var state_reader = file.readerStreaming(io, &state_read_buf);
        const content = try state_reader.interface.allocRemaining(self.arena.allocator(), .limited(4 * 1024 * 1024));

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.arena.allocator(),
            content,
            .{},
        );
        // parsed is owned by arena

        const root = parsed.value;
        if (root != .object) return;

        // Load tools
        if (root.object.get(json_key_tools)) |tools_val| {
            if (tools_val == .object) {
                var it = tools_val.object.iterator();
                while (it.next()) |kv| {
                    const tool_name = kv.key_ptr.*;
                    const tv = kv.value_ptr.*;
                    if (tv != .object) continue;

                    const entry = ToolEntry{
                        .version = if (tv.object.get(json_key_version)) |v| if (v == .string) v.string else "" else "",
                        .installed_at = if (tv.object.get(json_key_installed_at)) |v| if (v == .string) v.string else "" else "",
                        .method = if (tv.object.get(json_key_method)) |v| if (v == .string) v.string else "" else "",
                        .source = if (tv.object.get(json_key_source)) |v| if (v == .string) v.string else "" else "",
                        .status = if (tv.object.get(json_key_status)) |v| if (v == .string) v.string else default_tool_status else default_tool_status,
                        .pinned = if (tv.object.get(json_key_pinned)) |v| if (v == .bool) v.bool else false else false,
                    };

                    try self.tools.put(tool_name, entry);
                }
            }
        }
    }

    pub fn save(self: *State) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "{\n  \"version\": \"1.0\",\n  \"tools\": {\n");

        var first_tool = true;
        var tool_it = self.tools.iterator();
        while (tool_it.next()) |kv| {
            if (!first_tool) try buf.appendSlice(self.allocator, ",\n");
            first_tool = false;

            const tool_entry = kv.value_ptr.*;
            const line = try std.fmt.allocPrint(self.allocator,
                \\    "{s}": {{
                \\      "version": "{s}",
                \\      "installed_at": "{s}",
                \\      "method": "{s}",
                \\      "source": "{s}",
                \\      "status": "{s}",
                \\      "pinned": {s}
                \\    }}
            , .{
                kv.key_ptr.*,
                tool_entry.version,
                tool_entry.installed_at,
                tool_entry.method,
                tool_entry.source,
                tool_entry.status,
                if (tool_entry.pinned) "true" else "false",
            });
            defer self.allocator.free(line);
            try buf.appendSlice(self.allocator, line);
        }

        try buf.appendSlice(self.allocator, "\n  }\n}\n");

        const io = io_ctx.get();
        const file = try std.Io.Dir.cwd().createFile(io, self.path, .{});
        defer file.close(io);
        var state_write_buf: [4096]u8 = undefined;
        var state_writer = file.writerStreaming(io, &state_write_buf);
        try state_writer.interface.writeAll(buf.items);
        try state_writer.interface.flush();
    }

    pub fn isInstalled(self: *State, id: []const u8) bool {
        return self.tools.contains(id);
    }

    pub fn getVersion(self: *State, id: []const u8) ?[]const u8 {
        const entry = self.tools.get(id) orelse return null;
        return if (entry.version.len > 0) entry.version else null;
    }

    pub fn isPinned(self: *State, id: []const u8) bool {
        const entry = self.tools.get(id) orelse return false;
        return entry.pinned;
    }

    pub fn addTool(self: *State, id: []const u8, version: []const u8, method: []const u8, pinned: bool) !void {
        const arena_alloc = self.arena.allocator();

        // ISO 8601 timestamp
        const timestamp = std.Io.Timestamp.now(io_ctx.get(), .real).toSeconds();
        const installed_at = try std.fmt.allocPrint(arena_alloc, "{d}", .{timestamp});

        const source = try std.fmt.allocPrint(
            arena_alloc,
            "~/.local/bin/{s}",
            .{id},
        );

        const key = try arena_alloc.dupe(u8, id);
        try self.tools.put(key, .{
            .version = try arena_alloc.dupe(u8, version),
            .installed_at = installed_at,
            .method = try arena_alloc.dupe(u8, method),
            .source = source,
            .status = default_tool_status,
            .pinned = pinned,
        });
        try self.save();
    }

    pub fn removeTool(self: *State, id: []const u8) !void {
        _ = self.tools.remove(id);
        try self.save();
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "State: empty state has no tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..n];
    const state_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/state.json", .{dir_path});
    defer std.testing.allocator.free(state_path);

    var state = try State.initAt(std.testing.allocator, state_path);
    defer state.deinit();

    try std.testing.expect(!state.isInstalled("helm"));
    try std.testing.expect(state.getVersion("helm") == null);
    try std.testing.expectEqual(@as(usize, 0), state.tools.count());
}

test "State: addTool and isInstalled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..n];
    const state_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/state.json", .{dir_path});
    defer std.testing.allocator.free(state_path);

    var state = try State.initAt(std.testing.allocator, state_path);
    defer state.deinit();

    try std.testing.expect(!state.isInstalled("helm"));
    try state.addTool("helm", "3.15.0", "github_release", false);
    try std.testing.expect(state.isInstalled("helm"));
    try std.testing.expectEqualStrings("3.15.0", state.getVersion("helm").?);
}

test "State: removeTool" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..n];
    const state_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/state.json", .{dir_path});
    defer std.testing.allocator.free(state_path);

    var state = try State.initAt(std.testing.allocator, state_path);
    defer state.deinit();

    try state.addTool("kubectl", "1.29.0", "direct_binary", false);
    try std.testing.expect(state.isInstalled("kubectl"));
    try state.removeTool("kubectl");
    try std.testing.expect(!state.isInstalled("kubectl"));
}

test "State: save and load round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..n];
    const state_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/state.json", .{dir_path});
    defer std.testing.allocator.free(state_path);

    // Write state
    {
        var state = try State.initAt(std.testing.allocator, state_path);
        defer state.deinit();
        try state.addTool("terraform", "1.7.0", "hashicorp_release", false);
    }

    // Reload and verify
    {
        var state = try State.initAt(std.testing.allocator, state_path);
        defer state.deinit();
        try std.testing.expect(state.isInstalled("terraform"));
        try std.testing.expectEqualStrings("1.7.0", state.getVersion("terraform").?);
    }
}

test "State: multiple tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..n];
    const state_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/state.json", .{dir_path});
    defer std.testing.allocator.free(state_path);

    var state = try State.initAt(std.testing.allocator, state_path);
    defer state.deinit();

    try state.addTool("helm", "3.15.0", "github_release", false);
    try state.addTool("kubectl", "1.29.0", "direct_binary", false);
    try state.addTool("k9s", "0.32.0", "github_release", false);

    try std.testing.expectEqual(@as(usize, 3), state.tools.count());
    try std.testing.expect(state.isInstalled("helm"));
    try std.testing.expect(state.isInstalled("kubectl"));
    try std.testing.expect(state.isInstalled("k9s"));
    try std.testing.expect(!state.isInstalled("terraform"));
}

test "State: pinned=true is stored and returned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..n];
    const state_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/state.json", .{dir_path});
    defer std.testing.allocator.free(state_path);

    var state = try State.initAt(std.testing.allocator, state_path);
    defer state.deinit();

    try state.addTool("terraform", "1.8.0", "hashicorp_release", true);
    try std.testing.expect(state.isPinned("terraform"));
    try std.testing.expectEqualStrings("1.8.0", state.getVersion("terraform").?);
}

test "State: pinned=false is not pinned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..n];
    const state_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/state.json", .{dir_path});
    defer std.testing.allocator.free(state_path);

    var state = try State.initAt(std.testing.allocator, state_path);
    defer state.deinit();

    try state.addTool("terraform", "1.14.6", "hashicorp_release", false);
    try std.testing.expect(!state.isPinned("terraform"));
}

test "State: pinned survives save/load round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..n];
    const state_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/state.json", .{dir_path});
    defer std.testing.allocator.free(state_path);

    {
        var state = try State.initAt(std.testing.allocator, state_path);
        defer state.deinit();
        try state.addTool("terraform", "1.8.0", "hashicorp_release", true);
    }
    {
        var state = try State.initAt(std.testing.allocator, state_path);
        defer state.deinit();
        try std.testing.expect(state.isPinned("terraform"));
        try std.testing.expectEqualStrings("1.8.0", state.getVersion("terraform").?);
    }
}
