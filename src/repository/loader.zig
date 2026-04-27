const std = @import("std");
const tool = @import("../tool.zig");
const http = @import("../http.zig");
const io_ctx = @import("../io_ctx.zig");
const paths = @import("../paths.zig");

const cache_staleness_secs = 86400;
const repositories_config_file = "repositories.json";
const cache_file_template = "repository-{s}.json";

// Version source type strings (used in parseVersionSource comparisons)
const vs_type_github_release = "github_release";
const vs_type_hashicorp = "hashicorp";
const vs_type_k8s_stable_txt = "k8s_stable_txt";
const vs_type_pypi = "pypi";
const vs_type_static = "static";
const vs_type_gcloud_sdk = "gcloud_sdk";
const vs_type_github_tags = "github_tags";
const vs_type_ziglang = "ziglang";
const vs_type_go_dl = "go_dl";

const builtin_repo_name = "the-devops-hub";
const builtin_repo_url = "https://raw.githubusercontent.com/the-devops-hub/dot/main/src/repository/builtin-repository.json";
const builtin_repo_bytes: []const u8 = @embedFile("builtin-repository.json");

/// Load built-in tools. Uses cached online version when fresh; falls back to
/// the embedded repository.json compiled into the binary.
pub fn loadBuiltinTools(allocator: std.mem.Allocator) !ExternalTools {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    // Determine staleness from cache file mtime
    const dir_path = try configDir(allocator);
    defer allocator.free(dir_path);
    const cache_filename = "repository-" ++ builtin_repo_name ++ ".json";
    const cache_path = try std.fs.path.join(allocator, &.{ dir_path, cache_filename });
    defer allocator.free(cache_path);

    const now = std.Io.Timestamp.now(io_ctx.get(), .real).toSeconds();
    const stale: bool = blk: {
        const stat_io = io_ctx.get();
        const cache_file = std.Io.Dir.cwd().openFile(stat_io, cache_path, .{}) catch break :blk true;
        defer cache_file.close(stat_io);
        const file_stat = cache_file.stat(stat_io) catch break :blk true;
        const mtime_s = file_stat.mtime.toSeconds();
        break :blk now - mtime_s > cache_staleness_secs;
    };

    if (stale) {
        // Try to refresh in the background; ignore network errors silently
        fetchAndCache(allocator, builtin_repo_name, builtin_repo_url) catch {};
    }

    // Try to use the cached file (freshly fetched or previously cached)
    if (loadCachedTools(arena_alloc, allocator, builtin_repo_name)) |tools| {
        return ExternalTools{ .arena = arena, .tools = tools };
    } else |_| {}

    // Fall back to the embedded JSON
    const tools = parseRepositoryJson(arena_alloc, allocator, builtin_repo_bytes) catch
        try arena_alloc.alloc(tool.Tool, 0);
    return ExternalTools{ .arena = arena, .tools = tools };
}

pub const RepositorySource = struct {
    name: []const u8,
    url: []const u8,
    added_at: []const u8,
    fetched_at: []const u8,
};

pub const ExternalTools = struct {
    arena: std.heap.ArenaAllocator,
    tools: []tool.Tool,

    pub fn deinit(self: *ExternalTools) void {
        self.arena.deinit();
    }
};

/// Return path to ~/.config/dot. Caller owns result.
pub fn configDir(allocator: std.mem.Allocator) ![]u8 {
    const home = @import("../env.zig").getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(allocator, &.{ home, paths.config_dir, paths.dot_config_subdir });
}

/// Load and return all external tools from registered repository sources.
/// Auto-refreshes sources whose cache is older than 24 h.
pub fn loadExternalTools(allocator: std.mem.Allocator) !ExternalTools {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const sources = loadRepositories(arena_alloc, allocator) catch |e| switch (e) {
        error.FileNotFound, error.NoHome => return ExternalTools{ .arena = arena, .tools = &.{} },
        else => return ExternalTools{ .arena = arena, .tools = &.{} },
    };

    var all_tools: std.ArrayList(tool.Tool) = .empty;

    for (sources) |source| {
        const now = std.Io.Timestamp.now(io_ctx.get(), .real).toSeconds();
        const fetched_at_n = std.fmt.parseInt(i64, source.fetched_at, 10) catch 0;

        if (now - fetched_at_n > cache_staleness_secs) {
            fetchAndCache(allocator, source.name, source.url) catch {};
        }

        const tools_slice = loadCachedTools(arena_alloc, allocator, source.name) catch continue;
        try all_tools.appendSlice(arena_alloc, tools_slice);
    }

    return ExternalTools{
        .arena = arena,
        .tools = try all_tools.toOwnedSlice(arena_alloc),
    };
}

/// Load repository sources from repositories.json.
/// Strings are duped into `arena`. Uses `allocator` for temporary JSON parse.
pub fn loadRepositories(arena: std.mem.Allocator, allocator: std.mem.Allocator) ![]RepositorySource {
    const dir = try configDir(allocator);
    defer allocator.free(dir);

    const path = try std.fs.path.join(allocator, &.{ dir, repositories_config_file });
    defer allocator.free(path);

    const repos_io = io_ctx.get();
    const file = std.Io.Dir.cwd().openFile(repos_io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    defer file.close(repos_io);

    var repos_read_buf: [4096]u8 = undefined;
    var repos_reader = file.readerStreaming(repos_io, &repos_read_buf);
    const content = try repos_reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(content);

    return parseRepositoriesJson(arena, allocator, content);
}

fn parseRepositoriesJson(arena: std.mem.Allocator, allocator: std.mem.Allocator, content: []const u8) ![]RepositorySource {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return &.{};

    const sources_val = root.object.get("sources") orelse return &.{};
    if (sources_val != .array) return &.{};

    var list: std.ArrayList(RepositorySource) = .empty;
    for (sources_val.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;

        const name_raw = if (obj.get("name")) |v| if (v == .string) v.string else "" else "";
        const url_raw = if (obj.get("url")) |v| if (v == .string) v.string else "" else "";
        if (name_raw.len == 0 or url_raw.len == 0) continue;

        try list.append(arena, .{
            .name = try arena.dupe(u8, name_raw),
            .url = try arena.dupe(u8, url_raw),
            .added_at = try arena.dupe(u8, if (obj.get("added_at")) |v| if (v == .string) v.string else "0" else "0"),
            .fetched_at = try arena.dupe(u8, if (obj.get("fetched_at")) |v| if (v == .string) v.string else "0" else "0"),
        });
    }
    return list.toOwnedSlice(arena);
}

/// Save sources to repositories.json. Uses `allocator` for temporary buffers.
pub fn saveRepositories(allocator: std.mem.Allocator, sources: []const RepositorySource) !void {
    const dir = try configDir(allocator);
    defer allocator.free(dir);

    const save_io = io_ctx.get();
    try std.Io.Dir.cwd().createDirPath(save_io, dir);

    const path = try std.fs.path.join(allocator, &.{ dir, repositories_config_file });
    defer allocator.free(path);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n  \"sources\": [\n");
    for (sources, 0..) |s, i| {
        if (i > 0) try buf.appendSlice(allocator, ",\n");
        const line = try std.fmt.allocPrint(allocator,
            \\    {{"name": "{s}", "url": "{s}", "added_at": "{s}", "fetched_at": "{s}"}}
        , .{ s.name, s.url, s.added_at, s.fetched_at });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }
    try buf.appendSlice(allocator, "\n  ]\n}\n");

    const file = try std.Io.Dir.cwd().createFile(save_io, path, .{});
    defer file.close(save_io);
    var save_write_buf: [4096]u8 = undefined;
    var save_writer = file.writerStreaming(save_io, &save_write_buf);
    try save_writer.interface.writeAll(buf.items);
    try save_writer.interface.flush();
}

/// Fetch URL and write to repository-<name>.json cache. Also updates fetched_at.
pub fn fetchAndCache(allocator: std.mem.Allocator, name: []const u8, url: []const u8) !void {
    const body = try http.get(allocator, url);
    defer allocator.free(body);

    const dir = try configDir(allocator);
    defer allocator.free(dir);

    const fetch_io = io_ctx.get();
    try std.Io.Dir.cwd().createDirPath(fetch_io, dir);

    const filename = try std.fmt.allocPrint(allocator, cache_file_template, .{name});
    defer allocator.free(filename);

    const path = try std.fs.path.join(allocator, &.{ dir, filename });
    defer allocator.free(path);

    const file = try std.Io.Dir.cwd().createFile(fetch_io, path, .{});
    defer file.close(fetch_io);
    var fetch_write_buf: [4096]u8 = undefined;
    var fetch_writer = file.writerStreaming(fetch_io, &fetch_write_buf);
    try fetch_writer.interface.writeAll(body);
    try fetch_writer.interface.flush();

    try updateFetchedAt(allocator, name);
}

fn updateFetchedAt(allocator: std.mem.Allocator, name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const sources = loadRepositories(arena_alloc, allocator) catch return;

    const now = std.Io.Timestamp.now(io_ctx.get(), .real).toSeconds();
    const ts_str = try std.fmt.allocPrint(arena_alloc, "{d}", .{now});

    for (sources) |*s| {
        if (std.mem.eql(u8, s.name, name)) {
            s.fetched_at = ts_str;
            break;
        }
    }

    try saveRepositories(allocator, sources);
}

fn loadCachedTools(arena: std.mem.Allocator, allocator: std.mem.Allocator, name: []const u8) ![]tool.Tool {
    const dir = try configDir(allocator);
    defer allocator.free(dir);

    const filename = try std.fmt.allocPrint(allocator, cache_file_template, .{name});
    defer allocator.free(filename);

    const path = try std.fs.path.join(allocator, &.{ dir, filename });
    defer allocator.free(path);

    const load_io = io_ctx.get();
    const file = try std.Io.Dir.cwd().openFile(load_io, path, .{});
    defer file.close(load_io);

    var repo_read_buf: [4096]u8 = undefined;
    var repo_reader = file.readerStreaming(load_io, &repo_read_buf);
    const content = try repo_reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(content);

    return parseRepositoryJson(arena, allocator, content);
}

/// Parse a repository JSON blob into a slice of tool.Tool. Strings are duped into `arena`.
pub fn parseRepositoryJson(arena: std.mem.Allocator, allocator: std.mem.Allocator, content: []const u8) ![]tool.Tool {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return &.{};

    const tools_val = root.object.get("tools") orelse return &.{};
    if (tools_val != .array) return &.{};

    var list: std.ArrayList(tool.Tool) = .empty;
    for (tools_val.array.items) |item| {
        if (item != .object) continue;
        const tool_item = parseTool(arena, item.object) catch continue;
        try list.append(arena, tool_item);
    }
    return list.toOwnedSlice(arena);
}

/// Count tools in a repository JSON blob without fully parsing them.
pub fn countToolsInJson(allocator: std.mem.Allocator, content: []const u8) usize {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return 0;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return 0;
    const tools_val = root.object.get("tools") orelse return 0;
    if (tools_val != .array) return 0;
    return tools_val.array.items.len;
}

/// Parse repository name from JSON. Result is duped into `allocator`. Caller frees.
pub fn parseNameFromJson(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.MissingName;
    const name_val = root.object.get("name") orelse return error.MissingName;
    if (name_val != .string) return error.MissingName;
    return allocator.dupe(u8, name_val.string);
}

fn parseTool(arena: std.mem.Allocator, obj: std.json.ObjectMap) !tool.Tool {
    const id_val = obj.get("id") orelse return error.MissingId;
    if (id_val != .string) return error.InvalidId;

    const name_val = obj.get("name") orelse return error.MissingName;
    if (name_val != .string) return error.InvalidName;

    // groups
    const groups_val = obj.get("groups") orelse return error.MissingGroups;
    if (groups_val != .array) return error.InvalidGroups;
    var groups_list: std.ArrayList(tool.Group) = .empty;
    for (groups_val.array.items) |g| {
        if (g != .string) continue;
        const group = parseGroupStr(g.string) orelse continue;
        try groups_list.append(arena, group);
    }
    const groups = try groups_list.toOwnedSlice(arena);

    // version_source
    const vs_val = obj.get("version_source") orelse return error.MissingVersionSource;
    if (vs_val != .object) return error.InvalidVersionSource;
    const version_source = try parseVersionSource(arena, vs_val.object);

    // strategy
    const strat_val = obj.get("strategy") orelse return error.MissingStrategy;
    if (strat_val != .object) return error.InvalidStrategy;
    const strat = try parseStrategy(arena, strat_val.object);

    // optional fields
    const desc = if (obj.get("description")) |v| if (v == .string) try arena.dupe(u8, v.string) else "" else "";
    const homepage = if (obj.get("homepage")) |v| if (v == .string) try arena.dupe(u8, v.string) else "" else "";
    const brew_formula = if (obj.get("brew_formula")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null;

    const shell_completions: ?tool.ShellCompletions = if (obj.get("shell_completions")) |sc_val| blk: {
        if (sc_val != .object) break :blk null;
        const shell_completions_val = sc_val.object;
        break :blk tool.ShellCompletions{
            .bash_cmd = if (shell_completions_val.get("bash_cmd")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
            .zsh_cmd = if (shell_completions_val.get("zsh_cmd")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
            .fish_cmd = if (shell_completions_val.get("fish_cmd")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
        };
    } else null;

    const aliases: []const []const u8 = if (obj.get("aliases")) |av| blk: {
        if (av != .array) break :blk &.{};
        var list: std.ArrayList([]const u8) = .empty;
        for (av.array.items) |item| {
            if (item != .string) continue;
            try list.append(arena, try arena.dupe(u8, item.string));
        }
        break :blk try list.toOwnedSlice(arena);
    } else &.{};

    const post_install: []const []const u8 = if (obj.get("post_install")) |piv| blk: {
        if (piv != .array) break :blk &.{};
        var list: std.ArrayList([]const u8) = .empty;
        for (piv.array.items) |item| {
            if (item != .string) continue;
            try list.append(arena, try arena.dupe(u8, item.string));
        }
        break :blk try list.toOwnedSlice(arena);
    } else &.{};

    const post_upgrade: []const []const u8 = if (obj.get("post_upgrade")) |piv| blk: {
        if (piv != .array) break :blk &.{};
        var list: std.ArrayList([]const u8) = .empty;
        for (piv.array.items) |item| {
            if (item != .string) continue;
            try list.append(arena, try arena.dupe(u8, item.string));
        }
        break :blk try list.toOwnedSlice(arena);
    } else &.{};

    return tool.Tool{
        .id = try arena.dupe(u8, id_val.string),
        .name = try arena.dupe(u8, name_val.string),
        .description = desc,
        .groups = groups,
        .homepage = homepage,
        .brew_formula = brew_formula,
        .version_source = version_source,
        .strategy = strat,
        .shell_completions = shell_completions,
        .aliases = aliases,
        .post_install = post_install,
        .post_upgrade = post_upgrade,
    };
}

fn parseVersionSource(arena: std.mem.Allocator, obj: std.json.ObjectMap) !tool.VersionSource {
    const type_val = obj.get("type") orelse return error.MissingType;
    if (type_val != .string) return error.InvalidType;
    const type_str = type_val.string;

    if (std.mem.eql(u8, type_str, vs_type_github_release)) {
        const repo_val = obj.get("repo") orelse return error.MissingRepo;
        if (repo_val != .string) return error.InvalidRepo;
        return .{ .github_release = .{
            .repo = try arena.dupe(u8, repo_val.string),
            .filter = if (obj.get("filter")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
            .strip_prefix = if (obj.get("strip_prefix")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
            .require_asset = if (obj.get("require_asset")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
        } };
    } else if (std.mem.eql(u8, type_str, vs_type_hashicorp)) {
        const prod = obj.get("product") orelse return error.MissingProduct;
        if (prod != .string) return error.InvalidProduct;
        return .{ .hashicorp = .{ .product = try arena.dupe(u8, prod.string) } };
    } else if (std.mem.eql(u8, type_str, vs_type_k8s_stable_txt)) {
        return .{ .k8s_stable_txt = {} };
    } else if (std.mem.eql(u8, type_str, vs_type_pypi)) {
        const pkg = obj.get("package") orelse return error.MissingPackage;
        if (pkg != .string) return error.InvalidPackage;
        return .{ .pypi = .{ .package = try arena.dupe(u8, pkg.string) } };
    } else if (std.mem.eql(u8, type_str, vs_type_static)) {
        const ver = obj.get("version") orelse return error.MissingVersion;
        if (ver != .string) return error.InvalidVersion;
        return .{ .static = .{ .version = try arena.dupe(u8, ver.string) } };
    } else if (std.mem.eql(u8, type_str, vs_type_gcloud_sdk)) {
        return .{ .gcloud_sdk = {} };
    } else if (std.mem.eql(u8, type_str, vs_type_ziglang)) {
        return .{ .ziglang = {} };
    } else if (std.mem.eql(u8, type_str, vs_type_go_dl)) {
        return .{ .go_dl = {} };
    } else if (std.mem.eql(u8, type_str, vs_type_github_tags)) {
        const repo_val = obj.get("repo") orelse return error.MissingRepo;
        if (repo_val != .string) return error.InvalidRepo;
        return .{ .github_tags = .{
            .repo = try arena.dupe(u8, repo_val.string),
            .filter = if (obj.get("filter")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
            .strip_prefix = if (obj.get("strip_prefix")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
            .require_asset = if (obj.get("require_asset")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
        } };
    } else {
        return error.UnknownVersionSourceType;
    }
}

fn parseStrategy(arena: std.mem.Allocator, obj: std.json.ObjectMap) !tool.InstallStrategy {
    const type_val = obj.get("type") orelse return error.MissingType;
    if (type_val != .string) return error.InvalidType;
    const type_str = type_val.string;

    if (std.mem.eql(u8, type_str, tool.method_github_release)) {
        const url_tmpl = obj.get("url_template") orelse return error.MissingUrlTemplate;
        if (url_tmpl != .string) return error.InvalidUrlTemplate;
        const bin = if (obj.get("binary_in_archive")) |v| if (v == .string) try arena.dupe(u8, v.string) else "" else "";
        const csum = if (obj.get("checksum_url_template")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null;
        return .{ .github_release = .{
            .url_template = try arena.dupe(u8, url_tmpl.string),
            .binary_in_archive = bin,
            .checksum_url_template = csum,
        } };
    } else if (std.mem.eql(u8, type_str, tool.method_direct_binary)) {
        const url_tmpl = obj.get("url_template") orelse return error.MissingUrlTemplate;
        if (url_tmpl != .string) return error.InvalidUrlTemplate;
        return .{ .direct_binary = .{ .url_template = try arena.dupe(u8, url_tmpl.string) } };
    } else if (std.mem.eql(u8, type_str, tool.method_hashicorp)) {
        const prod = obj.get("product") orelse return error.MissingProduct;
        if (prod != .string) return error.InvalidProduct;
        return .{ .hashicorp_release = .{ .product = try arena.dupe(u8, prod.string) } };
    } else if (std.mem.eql(u8, type_str, tool.method_system_package)) {
        return .{ .system_package = .{
            .pacman = if (obj.get("pacman")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
            .apt = if (obj.get("apt")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
            .dnf = if (obj.get("dnf")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
            .yum = if (obj.get("yum")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
            .zypper = if (obj.get("zypper")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
            .apk = if (obj.get("apk")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
            .brew = if (obj.get("brew")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
            .flatpak = if (obj.get("flatpak")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
            .snap = if (obj.get("snap")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null,
        } };
    } else if (std.mem.eql(u8, type_str, tool.method_pip_venv)) {
        const pkg = obj.get("package") orelse return error.MissingPackage;
        if (pkg != .string) return error.InvalidPackage;
        const dir = obj.get("install_dir_rel") orelse return error.MissingInstallDir;
        if (dir != .string) return error.InvalidInstallDir;
        const bin = obj.get("binary_name") orelse return error.MissingBinaryName;
        if (bin != .string) return error.InvalidBinaryName;
        const extra_binaries: []const []const u8 = if (obj.get("extra_binaries")) |ev| blk: {
            if (ev != .array) break :blk &.{};
            var list: std.ArrayList([]const u8) = .empty;
            for (ev.array.items) |item| {
                if (item != .string) continue;
                try list.append(arena, try arena.dupe(u8, item.string));
            }
            break :blk try list.toOwnedSlice(arena);
        } else &.{};
        return .{ .pip_venv = .{
            .package = try arena.dupe(u8, pkg.string),
            .install_dir_rel = try arena.dupe(u8, dir.string),
            .binary_name = try arena.dupe(u8, bin.string),
            .extra_binaries = extra_binaries,
        } };
    } else if (std.mem.eql(u8, type_str, tool.method_tarball)) {
        const url_tmpl = obj.get("url_template") orelse return error.MissingUrlTemplate;
        if (url_tmpl != .string) return error.InvalidUrlTemplate;
        const strip: u32 = if (obj.get("strip_components")) |v| switch (v) {
            .integer => |n| @intCast(@max(0, n)),
            else => 1,
        } else 1;
        const bin_rel = if (obj.get("binary_rel_path")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null;
        const script = if (obj.get("install_script")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null;
        const sdk_dir = if (obj.get("sdk_dir")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null;
        const sdk_name = if (obj.get("sdk_name")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null;
        const script_args = if (obj.get("install_script_args")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null;
        const symlinks: []const []const u8 = if (obj.get("symlinks")) |sv| blk: {
            if (sv != .array) break :blk &.{};
            var list: std.ArrayList([]const u8) = .empty;
            for (sv.array.items) |item| {
                if (item != .string) continue;
                try list.append(arena, try arena.dupe(u8, item.string));
            }
            break :blk try list.toOwnedSlice(arena);
        } else &.{};
        return .{ .tarball = .{
            .url_template = try arena.dupe(u8, url_tmpl.string),
            .strip_components = strip,
            .binary_rel_path = bin_rel,
            .install_script = script,
            .sdk_dir = sdk_dir,
            .sdk_name = sdk_name,
            .install_script_args = script_args,
            .symlinks = symlinks,
        } };
    } else {
        return error.UnknownStrategyType;
    }
}

fn parseGroupStr(name: []const u8) ?tool.Group {
    if (std.mem.eql(u8, name, "k8s")) return .k8s;
    if (std.mem.eql(u8, name, "cloud")) return .cloud;
    if (std.mem.eql(u8, name, "iac")) return .iac;
    if (std.mem.eql(u8, name, "containers")) return .containers;
    if (std.mem.eql(u8, name, "utils")) return .utils;
    if (std.mem.eql(u8, name, "terminal")) return .terminal;
    if (std.mem.eql(u8, name, "cm")) return .cm;
    if (std.mem.eql(u8, name, "security")) return .security;
    if (std.mem.eql(u8, name, "dev")) return .dev;
    return null;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "parseRepositoryJson: empty tools array" {
    const json =
        \\{"name":"test","tools":[]}
    ;
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var arena_inst = std.heap.ArenaAllocator.init(alloc);
    defer arena_inst.deinit();
    const tools = try parseRepositoryJson(arena_inst.allocator(), alloc, json);
    try std.testing.expectEqual(@as(usize, 0), tools.len);
}

test "parseRepositoryJson: single github_release tool" {
    const json =
        \\{
        \\  "name": "myrepo",
        \\  "tools": [{
        \\    "id": "mytool",
        \\    "name": "MyTool",
        \\    "description": "Does stuff",
        \\    "groups": ["utils"],
        \\    "homepage": "https://example.com",
        \\    "version_source": {"type": "github_release", "repo": "me/mytool", "filter": null, "strip_prefix": null},
        \\    "strategy": {"type": "github_release", "url_template": "https://example.com/v{version}/mytool.tar.gz", "binary_in_archive": "mytool", "checksum_url_template": null}
        \\  }]
        \\}
    ;
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var arena_inst = std.heap.ArenaAllocator.init(alloc);
    defer arena_inst.deinit();
    const tools = try parseRepositoryJson(arena_inst.allocator(), alloc, json);
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("mytool", tools[0].id);
    try std.testing.expectEqualStrings("MyTool", tools[0].name);
    try std.testing.expectEqual(@as(usize, 1), tools[0].groups.len);
    try std.testing.expectEqual(tool.Group.utils, tools[0].groups[0]);
}

test "parseRepositoryJson: invalid tool is skipped" {
    const json =
        \\{"name":"test","tools":[{"id":"","name":"","groups":[],"version_source":{},"strategy":{}}]}
    ;
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var arena_inst = std.heap.ArenaAllocator.init(alloc);
    defer arena_inst.deinit();
    const tools = try parseRepositoryJson(arena_inst.allocator(), alloc, json);
    try std.testing.expectEqual(@as(usize, 0), tools.len);
}

test "parseNameFromJson: valid" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const name = try parseNameFromJson(alloc, "{\"name\":\"myrepo\",\"tools\":[]}");
    defer alloc.free(name);
    try std.testing.expectEqualStrings("myrepo", name);
}

test "countToolsInJson: counts correctly" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const count = countToolsInJson(alloc, "{\"name\":\"r\",\"tools\":[{},{},{}]}");
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "builtin_repo_bytes: parses all built-in tools" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var arena_inst = std.heap.ArenaAllocator.init(alloc);
    defer arena_inst.deinit();
    const tools = try parseRepositoryJson(arena_inst.allocator(), alloc, builtin_repo_bytes);
    try std.testing.expectEqual(@as(usize, 31), tools.len);
}
