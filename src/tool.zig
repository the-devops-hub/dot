const std = @import("std");
const http = @import("http.zig");
const platform = @import("platform.zig");
const archive = @import("archive.zig");
const output = @import("ui/output.zig");
const io_ctx = @import("io_ctx.zig");
const paths = @import("paths.zig");
const env = @import("env.zig");

pub const Group = enum { k8s, cloud, iac, containers, utils, terminal, cm, security, dev };

// ─── Install method names (serialized into state.json) ────────────────────────
pub const method_github_release = "github_release";
pub const method_direct_binary  = "direct_binary";
pub const method_hashicorp      = "hashicorp_release";
pub const method_system_package = "system_package";
pub const method_pip_venv       = "pip_venv";
pub const method_tarball        = "tarball";
pub const method_brew           = "brew";

// ─── Version-source API endpoints ─────────────────────────────────────────────
const github_api_releases_url  = "https://api.github.com/repos/{s}/releases";
const github_api_tags_url      = "https://api.github.com/repos/{s}/tags";
const hashicorp_checkpoint_url = "https://checkpoint-api.hashicorp.com/v1/check/{s}";
const k8s_stable_txt_url       = "https://dl.k8s.io/release/stable.txt";
const pypi_json_url            = "https://pypi.org/pypi/{s}/json";
const gcloud_components_url    = "https://dl.google.com/dl/cloudsdk/channels/rapid/components-2.json";
const ziglang_index_url        = "https://ziglang.org/download/index.json";
const go_downloads_url         = "https://go.dev/dl/?mode=json";
/// Key in the Zig download index that represents the development build; excluded from version resolution
const ziglang_master_key       = "master";
/// Prefix stripped from Go version strings (e.g. "go1.22.0" → "1.22.0")
const go_version_prefix        = "go";

// ─── Version resolution ───────────────────────────────────────────────────────

pub const VersionSource = union(enum) {
    github_release: GithubRelease,
    hashicorp: Hashicorp,
    k8s_stable_txt: void,
    pypi: Pypi,
    static: Static,
    gcloud_sdk: void,
    github_tags: GithubRelease,
    ziglang: void,
    go_dl: void,

    pub const GithubRelease = struct {
        repo: []const u8,
        /// If non-null, only tags that start with this prefix are considered.
        filter: ?[]const u8 = null,
        /// If non-null, strip this prefix from the tag to form the version string.
        /// e.g. strip_prefix = "jq-" turns tag "jq-1.8.1" into version "1.8.1".
        strip_prefix: ?[]const u8 = null,
        /// If non-null, skip releases that have no asset whose name contains this substring.
        /// Useful when a project publishes binary-less patch releases for older branches.
        require_asset: ?[]const u8 = null,
    };

    pub const Hashicorp = struct {
        product: []const u8,
    };

    pub const Pypi = struct {
        package: []const u8,
    };

    pub const Static = struct {
        version: []const u8,
    };

    /// Fetch the latest version string. Caller owns the returned slice.
    pub fn resolve(self: VersionSource, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .github_release => |gh| resolveGithub(allocator, gh),
            .hashicorp => |h| resolveHashicorp(allocator, h),
            .k8s_stable_txt => resolveK8sStableTxt(allocator),
            .pypi => |p| resolvePypi(allocator, p),
            .static => |s| allocator.dupe(u8, s.version),
            .gcloud_sdk => resolveGcloudSdk(allocator),
            .github_tags => |gh| resolveGithubTags(allocator, gh),
            .ziglang => resolveZiglang(allocator),
            .go_dl => resolveGoDl(allocator),
        };
    }

    fn resolveGithub(allocator: std.mem.Allocator, gh: GithubRelease) ![]u8 {
        const url = try std.fmt.allocPrint(
            allocator,
            github_api_releases_url,
            .{gh.repo},
        );
        defer allocator.free(url);

        const body = http.get(allocator, url) catch {
            return error.VersionFetchFailed;
        };
        defer allocator.free(body);

        // Parse JSON array of release objects
        const Asset = struct { name: []const u8 = "" };
        const Release = struct {
            tag_name: []const u8 = "",
            prerelease: bool = false,
            draft: bool = false,
            assets: []Asset = &.{},
        };
        const parsed = std.json.parseFromSlice(
            []Release,
            allocator,
            body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.VersionParseFailed;
        defer parsed.deinit();

        for (parsed.value) |rel| {
            if (rel.prerelease or rel.draft) continue;
            const tag = rel.tag_name;
            if (gh.filter) |prefix| {
                if (!std.mem.startsWith(u8, tag, prefix)) continue;
            }
            if (gh.require_asset) |required| {
                var has_asset = false;
                for (rel.assets) |asset| {
                    if (std.mem.indexOf(u8, asset.name, required) != null) {
                        has_asset = true;
                        break;
                    }
                }
                if (!has_asset) continue;
            }
            const ver = tagToVersion(tag, gh.strip_prefix);
            return allocator.dupe(u8, ver);
        }
        return error.VersionNotFound;
    }

    fn resolveHashicorp(allocator: std.mem.Allocator, h: Hashicorp) ![]u8 {
        const url = try std.fmt.allocPrint(
            allocator,
            hashicorp_checkpoint_url,
            .{h.product},
        );
        defer allocator.free(url);

        const body = http.get(allocator, url) catch return error.VersionFetchFailed;
        defer allocator.free(body);

        const Resp = struct {
            current_version: []const u8 = "",
        };
        const parsed = std.json.parseFromSlice(
            Resp,
            allocator,
            body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.VersionParseFailed;
        defer parsed.deinit();

        return allocator.dupe(u8, parsed.value.current_version);
    }

    fn resolveK8sStableTxt(allocator: std.mem.Allocator) ![]u8 {
        const body = http.get(allocator, k8s_stable_txt_url) catch
            return error.VersionFetchFailed;
        defer allocator.free(body);

        const trimmed = std.mem.trim(u8, body, " \n\r\t");
        const ver = if (trimmed.len > 0 and trimmed[0] == 'v') trimmed[1..] else trimmed;
        return allocator.dupe(u8, ver);
    }

    fn resolvePypi(allocator: std.mem.Allocator, p: Pypi) ![]u8 {
        const url = try std.fmt.allocPrint(
            allocator,
            pypi_json_url,
            .{p.package},
        );
        defer allocator.free(url);

        const body = http.get(allocator, url) catch return error.VersionFetchFailed;
        defer allocator.free(body);

        const Resp = struct {
            info: struct {
                version: []const u8 = "",
            } = .{},
        };
        const parsed = std.json.parseFromSlice(
            Resp,
            allocator,
            body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.VersionParseFailed;
        defer parsed.deinit();

        return allocator.dupe(u8, parsed.value.info.version);
    }

    fn resolveGcloudSdk(allocator: std.mem.Allocator) ![]u8 {
        const body = http.get(allocator, gcloud_components_url) catch
            return error.VersionFetchFailed;
        defer allocator.free(body);

        const Resp = struct { version: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Resp, allocator, body, .{ .ignore_unknown_fields = true }) catch
            return error.VersionParseFailed;
        defer parsed.deinit();

        return allocator.dupe(u8, parsed.value.version);
    }

    fn resolveGithubTags(allocator: std.mem.Allocator, gh: GithubRelease) ![]u8 {
        const url = try std.fmt.allocPrint(allocator, github_api_tags_url, .{gh.repo});
        defer allocator.free(url);

        const body = http.get(allocator, url) catch return error.VersionFetchFailed;
        defer allocator.free(body);

        const Tag = struct { name: []const u8 = "" };
        const parsed = std.json.parseFromSlice([]Tag, allocator, body, .{ .ignore_unknown_fields = true }) catch
            return error.VersionParseFailed;
        defer parsed.deinit();

        for (parsed.value) |tag| {
            const name = tag.name;
            if (gh.filter) |prefix| {
                if (!std.mem.startsWith(u8, name, prefix)) continue;
            }
            const ver = tagToVersion(name, gh.strip_prefix);
            return allocator.dupe(u8, ver);
        }
        return error.VersionNotFound;
    }

    fn resolveZiglang(allocator: std.mem.Allocator) ![]u8 {
        const body = http.get(allocator, ziglang_index_url) catch
            return error.VersionFetchFailed;
        defer allocator.free(body);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
            return error.VersionParseFailed;
        defer parsed.deinit();

        if (parsed.value != .object) return error.VersionParseFailed;
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, ziglang_master_key)) continue;
            return allocator.dupe(u8, entry.key_ptr.*);
        }
        return error.VersionNotFound;
    }

    fn resolveGoDl(allocator: std.mem.Allocator) ![]u8 {
        const body = http.get(allocator, go_downloads_url) catch
            return error.VersionFetchFailed;
        defer allocator.free(body);

        const Entry = struct {
            version: []const u8 = "",
            stable: bool = false,
        };
        const parsed = std.json.parseFromSlice(
            []Entry,
            allocator,
            body,
            .{ .ignore_unknown_fields = true },
        ) catch return error.VersionParseFailed;
        defer parsed.deinit();

        for (parsed.value) |entry| {
            if (!entry.stable) continue;
            const ver = if (std.mem.startsWith(u8, entry.version, go_version_prefix))
                entry.version[go_version_prefix.len..]
            else
                entry.version;
            return allocator.dupe(u8, ver);
        }
        return error.VersionNotFound;
    }
};

// ─── Install strategies ───────────────────────────────────────────────────────

pub const InstallContext = struct {
    allocator: std.mem.Allocator,
    tool_id: []const u8,
    version: []const u8,
    operating_system: platform.OperatingSystem,
    architecture: platform.Arch,
    bin_dir: []const u8,
    tmp_dir: []const u8,
    progress: ?http.ProgressCallback = null,
};

pub const InstallStrategy = union(enum) {
    github_release: GithubRelease,
    direct_binary: DirectBinary,
    hashicorp_release: HashicorpRelease,
    system_package: SystemPackage,
    pip_venv: PipVenv,
    tarball: Tarball,

    pub const GithubRelease = struct {
        /// URL with {version}, {os}, {arch} placeholders
        url_template: []const u8,
        /// Path within the archive to the binary, e.g. "{os}-{arch}/helm"
        binary_in_archive: []const u8,
        /// Optional checksum URL template
        checksum_url_template: ?[]const u8 = null,

        pub fn execute(self: GithubRelease, ctx: *InstallContext) !void {
            const url = try renderTemplate(ctx.allocator, self.url_template, ctx);
            defer ctx.allocator.free(url);

            const filename = std.fs.path.basename(url);
            const archive_path = try std.fs.path.join(ctx.allocator, &.{ ctx.tmp_dir, filename });
            defer ctx.allocator.free(archive_path);

            try http.download(ctx.allocator, url, archive_path, ctx.progress);

            // Verify checksum if available
            if (self.checksum_url_template) |tmpl| {
                const csum_url = try renderTemplate(ctx.allocator, tmpl, ctx);
                defer ctx.allocator.free(csum_url);
                verifyChecksum(ctx.allocator, archive_path, csum_url) catch |e| {
                    output.printChecksumWarning(@errorName(e));
                };
            }

            // Extract
            const extract_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.tmp_dir, "extract" });
            defer ctx.allocator.free(extract_dir);

            output.printStepStart("Extracting", filename);
            if (std.mem.endsWith(u8, archive_path, ".tar.gz") or
                std.mem.endsWith(u8, archive_path, ".tgz"))
            {
                try archive.extractTarGz(archive_path, extract_dir, 0);
            } else if (std.mem.endsWith(u8, archive_path, ".tar.xz")) {
                try archive.extractTarXz(archive_path, extract_dir, 0, ctx.allocator);
            } else if (std.mem.endsWith(u8, archive_path, ".zip")) {
                try archive.extractZip(archive_path, extract_dir, ctx.allocator);
            }

            // Locate the binary in the extracted tree
            const bin_subpath = try renderTemplate(ctx.allocator, self.binary_in_archive, ctx);
            defer ctx.allocator.free(bin_subpath);

            const src_bin = try std.fs.path.join(ctx.allocator, &.{ extract_dir, bin_subpath });
            defer ctx.allocator.free(src_bin);

            try installBinary(ctx, src_bin);
        }
    };

    pub const DirectBinary = struct {
        /// URL with {version}, {os}, {arch} placeholders; download IS the binary
        url_template: []const u8,

        pub fn execute(self: DirectBinary, ctx: *InstallContext) !void {
            const url = try renderTemplate(ctx.allocator, self.url_template, ctx);
            defer ctx.allocator.free(url);

            const tmp_bin = try std.fs.path.join(ctx.allocator, &.{ ctx.tmp_dir, ctx.tool_id });
            defer ctx.allocator.free(tmp_bin);

            try http.download(ctx.allocator, url, tmp_bin, ctx.progress);

            try installBinary(ctx, tmp_bin);
        }
    };

    pub const HashicorpRelease = struct {
        product: []const u8,

        pub fn execute(self: HashicorpRelease, ctx: *InstallContext) !void {
            const url = try std.fmt.allocPrint(
                ctx.allocator,
                "https://releases.hashicorp.com/{s}/{s}/{s}_{s}_{s}_{s}.zip",
                .{
                    self.product,
                    ctx.version,
                    self.product,
                    ctx.version,
                    ctx.operating_system.name(),
                    ctx.architecture.goName(),
                },
            );
            defer ctx.allocator.free(url);

            const archive_path = try std.fmt.allocPrint(
                ctx.allocator,
                "{s}/{s}.zip",
                .{ ctx.tmp_dir, self.product },
            );
            defer ctx.allocator.free(archive_path);

            try http.download(ctx.allocator, url, archive_path, ctx.progress);

            const extract_dir = try std.fmt.allocPrint(ctx.allocator, "{s}/extract", .{ctx.tmp_dir});
            defer ctx.allocator.free(extract_dir);

            const hc_filename = std.fs.path.basename(archive_path);
            output.printStepStart("Extracting", hc_filename);
            try archive.extractZip(archive_path, extract_dir, ctx.allocator);

            const src_bin = try std.fs.path.join(ctx.allocator, &.{ extract_dir, self.product });
            defer ctx.allocator.free(src_bin);

            try installBinary(ctx, src_bin);
        }
    };

    pub const SystemPackage = struct {
        pacman: ?[]const u8 = null,
        apt: ?[]const u8 = null,
        dnf: ?[]const u8 = null,
        yum: ?[]const u8 = null,
        zypper: ?[]const u8 = null,
        apk: ?[]const u8 = null,
        brew: ?[]const u8 = null,
        flatpak: ?[]const u8 = null,
        snap: ?[]const u8 = null,

        pub fn execute(self: SystemPackage, ctx: *InstallContext) !void {
            const pkg_manager = platform.PackageManager.detect();
            const pkg_name = self.packageFor(pkg_manager) orelse {
                output.printNoPackageManager(@tagName(pkg_manager));
                return error.NoPackageForManager;
            };

            const install_args = pkg_manager.installArgs();
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(ctx.allocator);

            try argv.appendSlice(ctx.allocator, install_args);
            try argv.append(ctx.allocator, pkg_name);

            output.printRunningCmd(pkg_manager.command() orelse "unknown", pkg_name);

            // Use spawn+wait (not run) so stdin/stdout/stderr are inherited —
            // this lets sudo reach the TTY to prompt for a password.
            const io = io_ctx.get();
            var child = try std.process.spawn(io, .{
                .argv = argv.items,
                .stdin = .inherit,
                .stdout = .inherit,
                .stderr = .inherit,
            });
            const term = try child.wait(io);

            if (term != .exited or term.exited != 0) {
                output.printDetail("Package install failed");
                return error.PackageInstallFailed;
            }
        }

        fn packageFor(self: SystemPackage, pm: platform.PackageManager) ?[]const u8 {
            return switch (pm) {
                .pacman => self.pacman,
                .apt => self.apt,
                .dnf => self.dnf,
                .yum => self.yum,
                .zypper => self.zypper,
                .apk => self.apk,
                .brew => self.brew,
                .flatpak => self.flatpak,
                .snap => self.snap,
                .unknown => null,
            };
        }
    };

    pub const PipVenv = struct {
        package: []const u8,
        /// Installation directory, e.g. "~/.local/opt/oci-cli"
        install_dir_rel: []const u8,
        /// Name of the binary inside the venv's bin/
        binary_name: []const u8,
        /// Additional binaries in the venv's bin/ to symlink alongside binary_name.
        extra_binaries: []const []const u8 = &.{},

        pub fn execute(self: PipVenv, ctx: *InstallContext) !void {
            const home = env.getenv("HOME") orelse paths.fallback_home;
            // Expand ~ manually
            const install_dir = if (std.mem.startsWith(u8, self.install_dir_rel, "~/"))
                try std.fs.path.join(ctx.allocator, &.{ home, self.install_dir_rel[2..] })
            else
                try ctx.allocator.dupe(u8, self.install_dir_rel);
            defer ctx.allocator.free(install_dir);

            // Create venv
            output.printStepStart("Venv", install_dir);
            const venv_result = try std.process.run(ctx.allocator, io_ctx.get(), .{
                .argv = &.{ "python3", "-m", "venv", install_dir },
                .stdout_limit = .limited(64 * 1024),
                .stderr_limit = .limited(64 * 1024),
            });
            defer ctx.allocator.free(venv_result.stdout);
            defer ctx.allocator.free(venv_result.stderr);
            if (venv_result.term != .exited or venv_result.term.exited != 0) {
                const msg = std.mem.trim(u8, venv_result.stderr, " \n\r\t");
                if (msg.len > 0) output.printDetail(msg);
                output.printDetail("Ensure python3 and the venv module are installed (e.g. python3-venv on Debian/Ubuntu, python3 on AlmaLinux/RHEL)");
                return error.VenvCreationFailed;
            }

            // pip install
            const pip = try std.fs.path.join(ctx.allocator, &.{ install_dir, "bin", "pip" });
            defer ctx.allocator.free(pip);

            output.printStepStart("pip install", self.package);
            const pip_result = try std.process.run(ctx.allocator, io_ctx.get(), .{
                .argv = &.{ pip, "install", "--upgrade", self.package },
                .stdout_limit = .limited(256 * 1024),
                .stderr_limit = .limited(256 * 1024),
            });
            defer ctx.allocator.free(pip_result.stdout);
            defer ctx.allocator.free(pip_result.stderr);
            if (pip_result.term != .exited or pip_result.term.exited != 0) {
                const msg = std.mem.trim(u8, pip_result.stderr, " \n\r\t");
                if (msg.len > 0) output.printDetail(msg);
                return error.PipInstallFailed;
            }

            const io = io_ctx.get();
            std.Io.Dir.cwd().createDirPath(io, ctx.bin_dir) catch {};

            // Symlink primary binary to bin_dir
            const src = try std.fs.path.join(ctx.allocator, &.{ install_dir, "bin", self.binary_name });
            defer ctx.allocator.free(src);

            const dst = try std.fs.path.join(ctx.allocator, &.{ ctx.bin_dir, self.binary_name });
            defer ctx.allocator.free(dst);

            std.Io.Dir.cwd().deleteFile(io, dst) catch {};
            try std.Io.Dir.cwd().symLink(io, src, dst, .{});

            // Symlink any extra binaries (e.g. ansible-playbook, ansible-vault, …)
            for (self.extra_binaries) |extra| {
                const extra_src = try std.fs.path.join(ctx.allocator, &.{ install_dir, "bin", extra });
                defer ctx.allocator.free(extra_src);
                const extra_dst = try std.fs.path.join(ctx.allocator, &.{ ctx.bin_dir, extra });
                defer ctx.allocator.free(extra_dst);
                std.Io.Dir.cwd().deleteFile(io, extra_dst) catch {};
                try std.Io.Dir.cwd().symLink(io, extra_src, extra_dst, .{});
            }
        }
    };

    pub const Tarball = struct {
        url_template: []const u8,
        /// strip_components for tar extraction
        strip_components: u32 = 1,
        /// Relative path within extracted dir to find the binary, or null for manual
        binary_rel_path: ?[]const u8 = null,
        /// If non-null, run this script relative to the effective_dir instead
        install_script: ?[]const u8 = null,
        /// If set, after extraction the subdirectory matching `sdk_dir` (supports {version},
        /// {os_zig}, {arch_uname} etc.) inside the extract dir is moved to
        /// ~/.local/opt/<sdk_name>. The install_script (if any) is run from that persistent
        /// directory. Useful for SDKs like gcloud or zig.
        sdk_dir: ?[]const u8 = null,
        /// Name of the directory under ~/.local/opt/ to install into. Defaults to sdk_dir
        /// when sdk_dir is a simple name, required when sdk_dir contains template variables.
        sdk_name: ?[]const u8 = null,
        /// Arguments for install_script, space-separated. Supports {bin_dir} and {opt_dir}
        /// placeholders, where {opt_dir} = ~/.local/opt/<tool-id>.
        install_script_args: ?[]const u8 = null,
        /// Paths relative to sdk_dir (or extract_dir if no sdk_dir) to symlink into bin_dir.
        symlinks: []const []const u8 = &.{},

        pub fn execute(self: Tarball, ctx: *InstallContext) !void {
            const url = try renderTemplate(ctx.allocator, self.url_template, ctx);
            defer ctx.allocator.free(url);

            const filename = std.fs.path.basename(url);
            const archive_path = try std.fs.path.join(ctx.allocator, &.{ ctx.tmp_dir, filename });
            defer ctx.allocator.free(archive_path);

            try http.download(ctx.allocator, url, archive_path, ctx.progress);

            const extract_dir = try std.fmt.allocPrint(ctx.allocator, "{s}/extract", .{ctx.tmp_dir});
            defer ctx.allocator.free(extract_dir);

            output.printStepStart("Extracting", filename);
            if (std.mem.endsWith(u8, archive_path, ".tar.gz") or
                std.mem.endsWith(u8, archive_path, ".tgz"))
            {
                try archive.extractTarGz(archive_path, extract_dir, self.strip_components);
            } else if (std.mem.endsWith(u8, archive_path, ".tar.xz")) {
                try archive.extractTarXz(archive_path, extract_dir, self.strip_components, ctx.allocator);
            } else if (std.mem.endsWith(u8, archive_path, ".zip")) {
                try archive.extractZip(archive_path, extract_dir, ctx.allocator);
            }

            // Determine the working directory: either a persistent SDK dir or the temp extract dir
            const home = env.getenv("HOME") orelse paths.fallback_home;
            const effective_dir: []const u8 = if (self.sdk_dir) |sd_tmpl| blk: {
                // sdk_dir supports template variables (e.g. zig uses version in dir name)
                const sd = try renderTemplate(ctx.allocator, sd_tmpl, ctx);
                defer ctx.allocator.free(sd);
                // sdk_name is the fixed install dir name; falls back to sdk_dir if simple
                const install_name = self.sdk_name orelse sd;
                const sdk_path = try std.fs.path.join(ctx.allocator, &.{ home, paths.local_dir, "opt", install_name });
                // Remove old installation and move new one into place
                std.Io.Dir.cwd().deleteTree(io_ctx.get(), sdk_path) catch {};
                const src = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ extract_dir, sd });
                defer ctx.allocator.free(src);
                const opt_parent = try std.fs.path.join(ctx.allocator, &.{ home, paths.local_dir, "opt" });
                defer ctx.allocator.free(opt_parent);
                std.Io.Dir.cwd().createDirPath(io_ctx.get(), opt_parent) catch {};
                const mv_res = try std.process.run(ctx.allocator, io_ctx.get(), .{
                    .argv = &.{ "mv", src, sdk_path },
                });
                ctx.allocator.free(mv_res.stdout);
                ctx.allocator.free(mv_res.stderr);
                if (mv_res.term != .exited or mv_res.term.exited != 0) return error.MoveFailed;
                break :blk sdk_path;
            } else try ctx.allocator.dupe(u8, extract_dir);
            defer ctx.allocator.free(effective_dir);

            if (self.install_script) |script| {
                const script_path = try std.fs.path.join(ctx.allocator, &.{ effective_dir, script });
                defer ctx.allocator.free(script_path);

                const chmod_res = try std.process.run(ctx.allocator, io_ctx.get(), .{
                    .argv = &.{ "chmod", "+x", script_path },
                });
                ctx.allocator.free(chmod_res.stdout);
                ctx.allocator.free(chmod_res.stderr);

                var argv: std.ArrayList([]const u8) = .empty;
                defer argv.deinit(ctx.allocator);
                try argv.append(ctx.allocator, script_path);

                if (self.install_script_args) |args_tmpl| {
                    const opt_dir = try std.fs.path.join(ctx.allocator, &.{ home, paths.local_dir, "opt", ctx.tool_id });
                    defer ctx.allocator.free(opt_dir);

                    var it = std.mem.splitScalar(u8, args_tmpl, ' ');
                    while (it.next()) |token| {
                        if (token.len == 0) continue;
                        const step1 = try std.mem.replaceOwned(u8, ctx.allocator, token, "{bin_dir}", ctx.bin_dir);
                        defer ctx.allocator.free(step1);
                        const step2 = try std.mem.replaceOwned(u8, ctx.allocator, step1, "{opt_dir}", opt_dir);
                        try argv.append(ctx.allocator, step2);
                    }
                }
                // Free expanded args (index 1+) after the run call; runs before deinit (LIFO)
                defer {
                    for (argv.items[1..]) |arg| ctx.allocator.free(arg);
                }

                const res = try std.process.run(ctx.allocator, io_ctx.get(), .{
                    .argv = argv.items,
                });
                ctx.allocator.free(res.stdout);
                ctx.allocator.free(res.stderr);
                if (res.term != .exited or res.term.exited != 0) return error.InstallScriptFailed;
            } else if (self.binary_rel_path) |rel| {
                const src = try std.fs.path.join(ctx.allocator, &.{ effective_dir, rel });
                defer ctx.allocator.free(src);
                try installBinary(ctx, src);
            }

            // Create symlinks from effective_dir into bin_dir
            const symlink_io = io_ctx.get();
            for (self.symlinks) |sym| {
                const src = try std.fs.path.join(ctx.allocator, &.{ effective_dir, sym });
                defer ctx.allocator.free(src);
                const dst = try std.fs.path.join(ctx.allocator, &.{ ctx.bin_dir, std.fs.path.basename(sym) });
                defer ctx.allocator.free(dst);
                std.Io.Dir.cwd().createDirPath(symlink_io, ctx.bin_dir) catch {};
                std.Io.Dir.cwd().deleteFile(symlink_io, dst) catch {};
                try std.Io.Dir.cwd().symLink(symlink_io, src, dst, .{});
            }
        }
    };

    pub fn execute(self: InstallStrategy, ctx: *InstallContext) !void {
        return switch (self) {
            .github_release => |s| s.execute(ctx),
            .direct_binary => |s| s.execute(ctx),
            .hashicorp_release => |s| s.execute(ctx),
            .system_package => |s| s.execute(ctx),
            .pip_venv => |s| s.execute(ctx),
            .tarball => |s| s.execute(ctx),
        };
    }
};

// ─── Tool definition ──────────────────────────────────────────────────────────

pub const ShellCompletions = struct {
    bash_cmd: ?[]const u8 = null,
    zsh_cmd: ?[]const u8 = null,
    fish_cmd: ?[]const u8 = null,

    pub fn forShell(self: ShellCompletions, shell: platform.Shell) ?[]const u8 {
        return switch (shell) {
            .bash => self.bash_cmd,
            .zsh => self.zsh_cmd,
            .fish => self.fish_cmd,
            .unknown => null,
        };
    }
};

pub const Resource = struct {
    label: []const u8,
    url: []const u8,
};

pub const Tool = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    groups: []const Group,
    homepage: []const u8,
    version_source: VersionSource,
    strategy: InstallStrategy,
    /// If set and brew is available, install via `brew install <formula>` instead
    /// of the native strategy. Use tap-prefixed names for third-party taps,
    /// e.g. "hashicorp/tap/terraform".
    brew_formula: ?[]const u8 = null,
    shell_completions: ?ShellCompletions = null,
    /// Short shell aliases written to the integration file, e.g. "k" → alias k=kubectl
    aliases: []const []const u8 = &.{},
    /// Shell commands to run after a fresh install (e.g. `helm plugin install ...`).
    /// Each entry is passed to `sh -c`. Failures are non-fatal.
    post_install: []const []const u8 = &.{},
    /// Shell commands to run after an upgrade (tool was already installed).
    /// Each entry is passed to `sh -c`. Failures are non-fatal.
    post_upgrade: []const []const u8 = &.{},
    quick_start: []const []const u8 = &.{},
    resources: []const Resource = &.{},
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Convert a GitHub tag_name to a clean version string.
/// Strips a leading 'v' unconditionally, then strips strip_prefix if provided.
/// e.g. "v3.15.0" → "3.15.0", "jq-1.8.1" with strip_prefix="jq-" → "1.8.1"
pub fn tagToVersion(tag: []const u8, strip_prefix: ?[]const u8) []const u8 {
    var ver = tag;
    if (ver.len > 0 and ver[0] == 'v') ver = ver[1..];
    if (strip_prefix) |pfx| {
        if (std.mem.startsWith(u8, ver, pfx)) ver = ver[pfx.len..];
    }
    return ver;
}

/// Replace {version}, {os}, {arch} placeholders in a template string.
pub fn renderTemplate(allocator: std.mem.Allocator, tmpl: []const u8, ctx: *const InstallContext) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < tmpl.len) {
        if (tmpl[i] == '{') {
            const end = std.mem.indexOf(u8, tmpl[i..], "}") orelse {
                try result.append(allocator, tmpl[i]);
                i += 1;
                continue;
            };
            const key = tmpl[i + 1 .. i + end];
            const replacement: []const u8 = if (std.mem.eql(u8, key, "version"))
                ctx.version
            else if (std.mem.eql(u8, key, "os"))
                ctx.operating_system.name()
            else if (std.mem.eql(u8, key, "arch"))
                ctx.architecture.goName()
            else if (std.mem.eql(u8, key, "arch_uname"))
                ctx.architecture.unameName()
            else if (std.mem.eql(u8, key, "arch_alt"))
                ctx.architecture.altName()
            else if (std.mem.eql(u8, key, "os_title"))
                ctx.operating_system.titleName()
            else if (std.mem.eql(u8, key, "os_zig"))
                ctx.operating_system.zigName()
            else
                tmpl[i .. i + end + 1]; // keep unchanged

            try result.appendSlice(allocator, replacement);
            i += end + 1;
        } else {
            try result.append(allocator, tmpl[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Copy src_path binary to ctx.bin_dir/ctx.tool_id and make it executable.
/// Uses a copy-then-rename pattern so replacing the running binary is safe.
fn installBinary(ctx: *InstallContext, src_path: []const u8) !void {
    const io = io_ctx.get();
    std.Io.Dir.cwd().createDirPath(io, ctx.bin_dir) catch {};

    const dest = try std.fs.path.join(ctx.allocator, &.{ ctx.bin_dir, ctx.tool_id });
    defer ctx.allocator.free(dest);

    const tmp_dest = try std.fmt.allocPrint(ctx.allocator, "{s}" ++ paths.new_file_suffix, .{dest});
    defer ctx.allocator.free(tmp_dest);

    try std.Io.Dir.cwd().copyFile(src_path, std.Io.Dir.cwd(), tmp_dest, io, .{});

    const chmod = try std.process.run(ctx.allocator, io_ctx.get(), .{
        .argv = &.{ "chmod", "+x", tmp_dest },
    });
    ctx.allocator.free(chmod.stdout);
    ctx.allocator.free(chmod.stderr);

    try std.Io.Dir.cwd().rename(tmp_dest, std.Io.Dir.cwd(), dest, io);
}

/// Fetch and verify SHA256 checksum from url against local file.
fn verifyChecksum(allocator: std.mem.Allocator, file_path: []const u8, checksum_url: []const u8) !void {
    const csum_body = try http.get(allocator, checksum_url);
    defer allocator.free(csum_body);

    // Parse "HASH  filename" format
    const first_space = std.mem.indexOf(u8, csum_body, " ") orelse return error.BadChecksumFormat;
    const expected_hex = std.mem.trim(u8, csum_body[0..first_space], " \n\r\t");

    if (expected_hex.len != 64) return error.BadChecksumFormat;

    // Hash the local file
    const io = io_ctx.get();
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    while (true) {
        const num_read = try file_reader.interface.readSliceShort(&buf);
        if (num_read == 0) break;
        hasher.update(buf[0..num_read]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var actual_hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        actual_hex[i * 2] = hex_chars[byte >> 4];
        actual_hex[i * 2 + 1] = hex_chars[byte & 0xf];
    }

    if (!std.mem.eql(u8, expected_hex, &actual_hex)) return error.ChecksumMismatch;
}

test "renderTemplate" {
    const allocator = std.testing.allocator;

    var ctx = InstallContext{
        .allocator = allocator,
        .tool_id = "helm",
        .version = "3.15.0",
        .operating_system = .linux,
        .architecture = .x86_64,
        .bin_dir = "/home/user/.local/bin",
        .tmp_dir = "/tmp/dot-helm",
    };

    const result = try renderTemplate(allocator, "helm-v{version}-{os}-{arch}.tar.gz", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("helm-v3.15.0-linux-amd64.tar.gz", result);
}

test "tagToVersion: strips leading v" {
    try std.testing.expectEqualStrings("3.15.0", tagToVersion("v3.15.0", null));
}

test "tagToVersion: no v prefix unchanged" {
    try std.testing.expectEqualStrings("3.15.0", tagToVersion("3.15.0", null));
}

test "tagToVersion: strip_prefix removes custom prefix" {
    try std.testing.expectEqualStrings("1.8.1", tagToVersion("jq-1.8.1", "jq-"));
}

test "tagToVersion: strip_prefix not present leaves tag unchanged" {
    try std.testing.expectEqualStrings("1.8.1", tagToVersion("1.8.1", "jq-"));
}

test "tagToVersion: v prefix stripped before strip_prefix applied" {
    // hypothetical: tag "vjq-1.0" with strip_prefix="jq-" → "1.0"
    try std.testing.expectEqualStrings("1.0", tagToVersion("vjq-1.0", "jq-"));
}

test "tagToVersion: empty tag" {
    try std.testing.expectEqualStrings("", tagToVersion("", null));
    try std.testing.expectEqualStrings("", tagToVersion("", "jq-"));
}
