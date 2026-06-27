use std::env;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OperatingSystem {
    Linux,
    Macos,
}

impl OperatingSystem {
    pub fn current() -> Self {
        if cfg!(target_os = "macos") {
            OperatingSystem::Macos
        } else {
            OperatingSystem::Linux
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            OperatingSystem::Linux => "linux",
            OperatingSystem::Macos => "darwin",
        }
    }

    pub fn title_name(self) -> &'static str {
        match self {
            OperatingSystem::Linux => "Linux",
            OperatingSystem::Macos => "macOS",
        }
    }

    pub fn zig_name(self) -> &'static str {
        match self {
            OperatingSystem::Linux => "linux",
            OperatingSystem::Macos => "macos",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Arch {
    X86_64,
    Aarch64,
    Arm,
    I386,
}

impl Arch {
    pub fn current() -> Self {
        if cfg!(target_arch = "aarch64") {
            Arch::Aarch64
        } else if cfg!(target_arch = "arm") {
            Arch::Arm
        } else if cfg!(target_arch = "x86") {
            Arch::I386
        } else {
            Arch::X86_64
        }
    }

    pub fn go_name(self) -> &'static str {
        match self {
            Arch::X86_64 => "amd64",
            Arch::Aarch64 => "arm64",
            Arch::Arm => "arm",
            Arch::I386 => "386",
        }
    }

    pub fn uname_name(self) -> &'static str {
        match self {
            Arch::X86_64 => "x86_64",
            Arch::Aarch64 => "aarch64",
            Arch::Arm => "armv7l",
            Arch::I386 => "i686",
        }
    }

    pub fn alt_name(self) -> &'static str {
        match self {
            Arch::X86_64 => "x86_64",
            Arch::Aarch64 => "arm64",
            Arch::Arm => "arm",
            Arch::I386 => "386",
        }
    }

    pub fn x64_name(self) -> &'static str {
        match self {
            Arch::X86_64 => "x64",
            Arch::Aarch64 => "arm64",
            Arch::Arm => "arm",
            Arch::I386 => "x86",
        }
    }

    pub fn rust_target(self, os: OperatingSystem) -> &'static str {
        match os {
            OperatingSystem::Linux => match self {
                Arch::X86_64 => "x86_64-unknown-linux-gnu",
                Arch::Aarch64 => "aarch64-unknown-linux-gnu",
                Arch::Arm => "armv7-unknown-linux-gnueabihf",
                Arch::I386 => "i686-unknown-linux-gnu",
            },
            OperatingSystem::Macos => match self {
                Arch::X86_64 => "x86_64-apple-darwin",
                Arch::Aarch64 => "aarch64-apple-darwin",
                Arch::Arm => "arm-apple-darwin",
                Arch::I386 => "i686-apple-darwin",
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shell {
    Bash,
    Zsh,
    Fish,
    Unknown,
}

impl Shell {
    pub fn detect() -> Self {
        let shell_env = match env::var("SHELL") {
            Ok(v) => v,
            Err(_) => return Shell::Unknown,
        };
        let name = std::path::Path::new(&shell_env)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("");
        match name {
            "bash" => Shell::Bash,
            "zsh" => Shell::Zsh,
            "fish" => Shell::Fish,
            _ => Shell::Unknown,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Shell::Bash => "bash",
            Shell::Zsh => "zsh",
            Shell::Fish => "fish",
            Shell::Unknown => "unknown",
        }
    }

    pub fn integration_file_name(self) -> &'static str {
        match self {
            Shell::Bash => "shell-integration.bash",
            Shell::Zsh => "shell-integration.zsh",
            Shell::Fish => "shell-integration.fish",
            Shell::Unknown => "shell-integration.sh",
        }
    }

    pub fn path_add_syntax(self, dir: &str) -> String {
        match self {
            Shell::Fish => format!("set -gx PATH {dir} $PATH"),
            _ => format!("export PATH=\"{dir}:$PATH\""),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PackageManager {
    Pacman,
    Apt,
    Dnf,
    Yum,
    Zypper,
    Apk,
    Brew,
    Flatpak,
    Snap,
    Unknown,
}

impl PackageManager {
    pub fn detect() -> Self {
        let native = [
            PackageManager::Pacman,
            PackageManager::Apt,
            PackageManager::Dnf,
            PackageManager::Yum,
            PackageManager::Zypper,
            PackageManager::Apk,
        ];
        for pm in native {
            if pm.is_available() {
                return pm;
            }
        }
        if PackageManager::Brew.is_available() {
            return PackageManager::Brew;
        }
        if PackageManager::Flatpak.is_available() {
            return PackageManager::Flatpak;
        }
        if PackageManager::Snap.is_available() {
            return PackageManager::Snap;
        }
        PackageManager::Unknown
    }

    pub fn is_available(self) -> bool {
        let cmd = match self.command() {
            Some(c) => c,
            None => return false,
        };
        crate::util::find_in_path(cmd).is_some()
    }

    pub fn command(self) -> Option<&'static str> {
        match self {
            PackageManager::Pacman => Some("pacman"),
            PackageManager::Apt => Some("apt"),
            PackageManager::Dnf => Some("dnf"),
            PackageManager::Yum => Some("yum"),
            PackageManager::Zypper => Some("zypper"),
            PackageManager::Apk => Some("apk"),
            PackageManager::Brew => Some("brew"),
            PackageManager::Flatpak => Some("flatpak"),
            PackageManager::Snap => Some("snap"),
            PackageManager::Unknown => None,
        }
    }

    pub fn install_args(self) -> &'static [&'static str] {
        match self {
            PackageManager::Pacman => &["sudo", "pacman", "-S", "--noconfirm"],
            PackageManager::Apt => &["sudo", "apt-get", "install", "-y"],
            PackageManager::Dnf => &["sudo", "dnf", "install", "-y"],
            PackageManager::Yum => &["sudo", "yum", "install", "-y"],
            PackageManager::Zypper => &["sudo", "zypper", "install", "-y"],
            PackageManager::Apk => &["sudo", "apk", "add"],
            PackageManager::Brew => &["brew", "install"],
            PackageManager::Flatpak => &["flatpak", "install", "-y"],
            PackageManager::Snap => &["snap", "install"],
            PackageManager::Unknown => &[],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn os_current_does_not_panic() {
        let _ = OperatingSystem::current();
    }

    #[test]
    fn arch_current_does_not_panic() {
        let _ = Arch::current();
    }

    #[test]
    fn shell_detect_does_not_panic() {
        let _ = Shell::detect();
    }

    #[test]
    fn package_manager_command_names() {
        assert_eq!(PackageManager::Pacman.command(), Some("pacman"));
        assert_eq!(PackageManager::Apt.command(), Some("apt"));
        assert_eq!(PackageManager::Unknown.command(), None);
    }

    #[test]
    fn rust_target_linux_x86_64() {
        assert_eq!(
            Arch::X86_64.rust_target(OperatingSystem::Linux),
            "x86_64-unknown-linux-gnu"
        );
    }

    #[test]
    fn rust_target_macos_aarch64() {
        assert_eq!(
            Arch::Aarch64.rust_target(OperatingSystem::Macos),
            "aarch64-apple-darwin"
        );
    }
}
