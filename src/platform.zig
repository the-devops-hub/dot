const std = @import("std");
const builtin = @import("builtin");
const io_ctx = @import("io_ctx.zig");

pub const OperatingSystem = enum {
    linux,
    macos,

    pub fn current() OperatingSystem {
        return switch (builtin.os.tag) {
            .macos => .macos,
            else => .linux,
        };
    }

    pub fn name(self: OperatingSystem) []const u8 {
        return switch (self) {
            .linux => "linux",
            .macos => "darwin",
        };
    }

    /// Title-cased OS name, e.g. "Linux", "Darwin" — used by tools like trivy.
    pub fn titleName(self: OperatingSystem) []const u8 {
        return switch (self) {
            .linux => "Linux",
            .macos => "macOS",
        };
    }

    pub fn goName(self: OperatingSystem) []const u8 {
        return switch (self) {
            .linux => "linux-amd64",
            .macos => "darwin-amd64",
        };
    }

    /// OS name as used by ziglang.org downloads: "linux" or "macos".
    pub fn zigName(self: OperatingSystem) []const u8 {
        return switch (self) {
            .linux => "linux",
            .macos => "macos",
        };
    }
};

pub const Arch = enum {
    x86_64,
    aarch64,
    arm,
    i386,

    pub fn current() Arch {
        return switch (builtin.cpu.arch) {
            .aarch64 => .aarch64,
            .arm => .arm,
            .x86 => .i386,
            else => .x86_64,
        };
    }

    /// Name used in most Go-based tool URLs (amd64/arm64)
    pub fn goName(self: Arch) []const u8 {
        return switch (self) {
            .x86_64 => "amd64",
            .aarch64 => "arm64",
            .arm => "arm",
            .i386 => "386",
        };
    }

    /// Debian/Ubuntu package arch name
    pub fn debName(self: Arch) []const u8 {
        return switch (self) {
            .x86_64 => "amd64",
            .aarch64 => "arm64",
            .arm => "armhf",
            .i386 => "i386",
        };
    }

    /// Raw uname -m name
    pub fn unameName(self: Arch) []const u8 {
        return switch (self) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .arm => "armv7l",
            .i386 => "i686",
        };
    }

    /// Hybrid arch name used by tools like lazygit (x86_64 for Intel, arm64 for ARM)
    pub fn altName(self: Arch) []const u8 {
        return switch (self) {
            .x86_64 => "x86_64",
            .aarch64 => "arm64",
            .arm => "arm",
            .i386 => "386",
        };
    }
};

pub const Shell = enum {
    bash,
    zsh,
    fish,
    unknown,

    pub fn detect() Shell {
        const shell_env = @import("env.zig").getenv("SHELL") orelse return .unknown;
        const shell_name = std.fs.path.basename(shell_env);
        if (std.mem.eql(u8, shell_name, "bash")) return .bash;
        if (std.mem.eql(u8, shell_name, "zsh")) return .zsh;
        if (std.mem.eql(u8, shell_name, "fish")) return .fish;
        return .unknown;
    }

    pub fn name(self: Shell) []const u8 {
        return switch (self) {
            .bash => "bash",
            .zsh => "zsh",
            .fish => "fish",
            .unknown => "unknown",
        };
    }

    /// Name of centralized integration file
    pub fn integrationFileName(self: Shell) []const u8 {
        return switch (self) {
            .bash => "shell-integration.bash",
            .zsh => "shell-integration.zsh",
            .fish => "shell-integration.fish",
            .unknown => "shell-integration.sh",
        };
    }

    /// Shell-specific syntax to add a directory to PATH
    pub fn pathAddSyntax(self: Shell, dir: []const u8, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .fish => std.fmt.allocPrint(allocator, "set -gx PATH {s} $PATH", .{dir}),
            else => std.fmt.allocPrint(allocator, "export PATH=\"{s}:$PATH\"", .{dir}),
        };
    }
};

pub const PackageManager = enum {
    pacman,
    apt,
    dnf,
    yum,
    zypper,
    apk,
    brew,
    flatpak,
    snap,
    unknown,

    /// Detect the primary native package manager in priority order
    pub fn detect() PackageManager {
        const native = [_]PackageManager{ .pacman, .apt, .dnf, .yum, .zypper, .apk };
        for (native) |pm| {
            if (pm.isAvailable()) return pm;
        }
        if (PackageManager.brew.isAvailable()) return .brew;
        if (PackageManager.flatpak.isAvailable()) return .flatpak;
        if (PackageManager.snap.isAvailable()) return .snap;
        return .unknown;
    }

    /// Check if a package manager binary exists in PATH
    pub fn isAvailable(self: PackageManager) bool {
        const cmd = self.command() orelse return false;
        // Use std.process to check
        const result = std.process.run(std.heap.page_allocator, io_ctx.get(), .{
            .argv = &.{ "sh", "-c", std.fmt.allocPrint(
                std.heap.page_allocator,
                "command -v {s}",
                .{cmd},
            ) catch return false },
        }) catch return false;
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
        return result.term == .exited and result.term.exited == 0;
    }

    pub fn command(self: PackageManager) ?[]const u8 {
        return switch (self) {
            .pacman => "pacman",
            .apt => "apt",
            .dnf => "dnf",
            .yum => "yum",
            .zypper => "zypper",
            .apk => "apk",
            .brew => "brew",
            .flatpak => "flatpak",
            .snap => "snap",
            .unknown => null,
        };
    }

    /// Install command prefix (without package name)
    pub fn installArgs(self: PackageManager) []const []const u8 {
        return switch (self) {
            .pacman => &.{ "sudo", "pacman", "-S", "--noconfirm" },
            .apt => &.{ "sudo", "apt-get", "install", "-y" },
            .dnf => &.{ "sudo", "dnf", "install", "-y" },
            .yum => &.{ "sudo", "yum", "install", "-y" },
            .zypper => &.{ "sudo", "zypper", "install", "-y" },
            .apk => &.{ "sudo", "apk", "add" },
            .brew => &.{ "brew", "install" },
            .flatpak => &.{ "flatpak", "install", "-y" },
            .snap => &.{ "snap", "install" },
            .unknown => &.{},
        };
    }

    /// Remove command prefix (without package name)
    pub fn removeArgs(self: PackageManager) []const []const u8 {
        return switch (self) {
            .pacman => &.{ "sudo", "pacman", "-R" },
            .apt => &.{ "sudo", "apt-get", "remove", "-y" },
            .dnf => &.{ "sudo", "dnf", "remove", "-y" },
            .yum => &.{ "sudo", "yum", "remove", "-y" },
            .zypper => &.{ "sudo", "zypper", "remove", "-y" },
            .apk => &.{ "sudo", "apk", "del" },
            .brew => &.{ "brew", "uninstall" },
            .flatpak => &.{ "flatpak", "uninstall", "-y" },
            .snap => &.{ "snap", "remove" },
            .unknown => &.{},
        };
    }
};

test "OperatingSystem.current does not panic" {
    _ = OperatingSystem.current();
}

test "Arch.current does not panic" {
    _ = Arch.current();
}

test "Shell.detect does not panic" {
    _ = Shell.detect();
}

test "PackageManager command names" {
    try std.testing.expectEqualStrings("pacman", PackageManager.pacman.command().?);
    try std.testing.expectEqualStrings("apt", PackageManager.apt.command().?);
}
