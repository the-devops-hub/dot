use serde::{Deserialize, Serialize};

// ─── Method name constants (serialized into state.json) ───────────────────────

pub const METHOD_GITHUB_RELEASE: &str = "github_release";
pub const METHOD_DIRECT_BINARY: &str = "direct_binary";
pub const METHOD_HASHICORP: &str = "hashicorp_release";
pub const METHOD_SYSTEM_PACKAGE: &str = "system_package";
pub const METHOD_PIP_VENV: &str = "pip_venv";
pub const METHOD_TARBALL: &str = "tarball";
pub const METHOD_SCRIPT_INSTALLER: &str = "script_installer";
pub const METHOD_BREW: &str = "brew";

// ─── Groups ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Group {
    K8s,
    Cloud,
    Iac,
    Containers,
    Utils,
    Terminal,
    Cm,
    Security,
    Dev,
}

impl Group {
    pub fn name(&self) -> &'static str {
        match self {
            Group::K8s => "k8s",
            Group::Cloud => "cloud",
            Group::Iac => "iac",
            Group::Containers => "containers",
            Group::Utils => "utils",
            Group::Terminal => "terminal",
            Group::Cm => "cm",
            Group::Security => "security",
            Group::Dev => "dev",
        }
    }
}

// ─── Version sources ──────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct GithubSourceParams {
    pub repo: String,
    #[serde(default)]
    pub filter: Option<String>,
    #[serde(default)]
    pub strip_prefix: Option<String>,
    #[serde(default)]
    pub require_asset: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct HashicorpSourceParams {
    pub product: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct PypiSourceParams {
    pub package: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct StaticSourceParams {
    pub version: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum VersionSource {
    GithubRelease(GithubSourceParams),
    GithubTags(GithubSourceParams),
    Hashicorp(HashicorpSourceParams),
    K8sStableTxt,
    Pypi(PypiSourceParams),
    Static(StaticSourceParams),
    GcloudSdk,
    Ziglang,
    GoDl,
    RustStable,
}

// ─── Version source API endpoints ────────────────────────────────────────────

const GITHUB_API_RELEASES: &str = "https://api.github.com/repos/{}/releases";
const GITHUB_API_TAGS: &str = "https://api.github.com/repos/{}/tags";
const HASHICORP_CHECKPOINT: &str = "https://checkpoint-api.hashicorp.com/v1/check/{}";
const K8S_STABLE_TXT: &str = "https://dl.k8s.io/release/stable.txt";
const PYPI_JSON: &str = "https://pypi.org/pypi/{}/json";
const GCLOUD_COMPONENTS: &str =
    "https://dl.google.com/dl/cloudsdk/channels/rapid/components-2.json";
const ZIGLANG_INDEX: &str = "https://ziglang.org/download/index.json";
const GO_DOWNLOADS: &str = "https://go.dev/dl/?mode=json";
const RUST_STABLE_CHANNEL: &str = "https://static.rust-lang.org/dist/channel-rust-stable.toml";

impl VersionSource {
    pub fn resolve(&self) -> Result<String, crate::error::DotError> {
        use crate::error::DotError;
        use crate::http;
        use crate::template::tag_to_version;

        match self {
            VersionSource::Static(p) => Ok(p.version.clone()),

            VersionSource::GithubRelease(p) => {
                let url = GITHUB_API_RELEASES.replace("{}", &p.repo);
                let body = http::get(&url).map_err(|_| DotError::VersionFetchFailed)?;
                resolve_github_release(&body, p)
            }

            VersionSource::GithubTags(p) => {
                let url = GITHUB_API_TAGS.replace("{}", &p.repo);
                let body = http::get(&url).map_err(|_| DotError::VersionFetchFailed)?;
                resolve_github_tags(&body, p)
            }

            VersionSource::Hashicorp(p) => {
                let url = HASHICORP_CHECKPOINT.replace("{}", &p.product);
                let body = http::get(&url).map_err(|_| DotError::VersionFetchFailed)?;
                #[derive(serde::Deserialize)]
                struct Resp {
                    #[serde(default)]
                    current_version: String,
                }
                let r: Resp =
                    serde_json::from_str(&body).map_err(|_| DotError::VersionParseFailed)?;
                if r.current_version.is_empty() {
                    return Err(DotError::VersionNotFound);
                }
                Ok(r.current_version)
            }

            VersionSource::K8sStableTxt => {
                let body = http::get(K8S_STABLE_TXT).map_err(|_| DotError::VersionFetchFailed)?;
                let trimmed = body.trim();
                let ver = trimmed.strip_prefix('v').unwrap_or(trimmed);
                Ok(ver.to_string())
            }

            VersionSource::Pypi(p) => {
                let url = PYPI_JSON.replace("{}", &p.package);
                let body = http::get(&url).map_err(|_| DotError::VersionFetchFailed)?;
                #[derive(serde::Deserialize)]
                struct Info {
                    #[serde(default)]
                    version: String,
                }
                #[derive(serde::Deserialize)]
                struct Resp {
                    info: Info,
                }
                let r: Resp =
                    serde_json::from_str(&body).map_err(|_| DotError::VersionParseFailed)?;
                if r.info.version.is_empty() {
                    return Err(DotError::VersionNotFound);
                }
                Ok(r.info.version)
            }

            VersionSource::GcloudSdk => {
                let body =
                    http::get(GCLOUD_COMPONENTS).map_err(|_| DotError::VersionFetchFailed)?;
                #[derive(serde::Deserialize)]
                struct Resp {
                    #[serde(default)]
                    version: String,
                }
                let r: Resp =
                    serde_json::from_str(&body).map_err(|_| DotError::VersionParseFailed)?;
                if r.version.is_empty() {
                    return Err(DotError::VersionNotFound);
                }
                Ok(r.version)
            }

            VersionSource::Ziglang => {
                let body = http::get(ZIGLANG_INDEX).map_err(|_| DotError::VersionFetchFailed)?;
                let map: serde_json::Map<String, serde_json::Value> =
                    serde_json::from_str(&body).map_err(|_| DotError::VersionParseFailed)?;
                // Pick the highest semver key (map may be BTreeMap-sorted, so don't rely on order)
                let best = map
                    .keys()
                    .filter(|k| k.as_str() != "master")
                    .max_by(|a, b| semver_cmp(a, b));
                best.cloned().ok_or(DotError::VersionNotFound)
            }

            VersionSource::GoDl => {
                let body = http::get(GO_DOWNLOADS).map_err(|_| DotError::VersionFetchFailed)?;
                #[derive(serde::Deserialize)]
                struct Entry {
                    #[serde(default)]
                    version: String,
                    #[serde(default)]
                    stable: bool,
                }
                let entries: Vec<Entry> =
                    serde_json::from_str(&body).map_err(|_| DotError::VersionParseFailed)?;
                for e in entries {
                    if !e.stable {
                        continue;
                    }
                    let ver = e
                        .version
                        .strip_prefix("go")
                        .unwrap_or(&e.version)
                        .to_string();
                    return Ok(ver);
                }
                Err(DotError::VersionNotFound)
            }

            VersionSource::RustStable => {
                let body =
                    http::get(RUST_STABLE_CHANNEL).map_err(|_| DotError::VersionFetchFailed)?;
                // Find [pkg.rust] section, parse the version = "..." line within it
                let pkg_marker = "[pkg.rust]\n";
                let ver_marker = "version = \"";
                let pkg_start = body.find(pkg_marker).ok_or(DotError::VersionParseFailed)?;
                let in_section = &body[pkg_start + pkg_marker.len()..];
                let ver_pos = in_section
                    .find(ver_marker)
                    .ok_or(DotError::VersionParseFailed)?;
                let after_quote = &in_section[ver_pos + ver_marker.len()..];
                let ver_len = after_quote
                    .find(|c| c == ' ' || c == '"')
                    .ok_or(DotError::VersionParseFailed)?;
                if ver_len == 0 {
                    return Err(DotError::VersionParseFailed);
                }
                Ok(after_quote[..ver_len].to_string())
            }
        }
    }
}

fn resolve_github_release(
    body: &str,
    p: &GithubSourceParams,
) -> Result<String, crate::error::DotError> {
    use crate::error::DotError;
    use crate::template::tag_to_version;

    #[derive(serde::Deserialize)]
    struct Asset {
        name: String,
    }
    #[derive(serde::Deserialize)]
    struct Release {
        tag_name: String,
        #[serde(default)]
        prerelease: bool,
        #[serde(default)]
        draft: bool,
        #[serde(default)]
        assets: Vec<Asset>,
    }

    let releases: Vec<Release> =
        serde_json::from_str(body).map_err(|_| DotError::VersionParseFailed)?;
    for rel in releases {
        if rel.prerelease || rel.draft {
            continue;
        }
        if let Some(ref prefix) = p.filter {
            if !rel.tag_name.starts_with(prefix.as_str()) {
                continue;
            }
        }
        if let Some(ref required) = p.require_asset {
            let has = rel
                .assets
                .iter()
                .any(|a| a.name.contains(required.as_str()));
            if !has {
                continue;
            }
        }
        let ver = tag_to_version(&rel.tag_name, p.strip_prefix.as_deref());
        return Ok(ver.to_string());
    }
    Err(DotError::VersionNotFound)
}

fn resolve_github_tags(
    body: &str,
    p: &GithubSourceParams,
) -> Result<String, crate::error::DotError> {
    use crate::error::DotError;
    use crate::template::tag_to_version;

    #[derive(serde::Deserialize)]
    struct Tag {
        name: String,
    }

    let tags: Vec<Tag> = serde_json::from_str(body).map_err(|_| DotError::VersionParseFailed)?;
    for tag in tags {
        if let Some(ref prefix) = p.filter {
            if !tag.name.starts_with(prefix.as_str()) {
                continue;
            }
        }
        let ver = tag_to_version(&tag.name, p.strip_prefix.as_deref());
        return Ok(ver.to_string());
    }
    Err(DotError::VersionNotFound)
}

// ─── Install strategies ───────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct GithubReleaseStrategy {
    pub url_template: String,
    #[serde(default)]
    pub binary_in_archive: String,
    #[serde(default)]
    pub checksum_url_template: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DirectBinaryStrategy {
    pub url_template: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct HashicorpReleaseStrategy {
    pub product: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SystemPackageStrategy {
    #[serde(default)]
    pub pacman: Option<String>,
    #[serde(default)]
    pub apt: Option<String>,
    #[serde(default)]
    pub dnf: Option<String>,
    #[serde(default)]
    pub yum: Option<String>,
    #[serde(default)]
    pub zypper: Option<String>,
    #[serde(default)]
    pub apk: Option<String>,
    #[serde(default)]
    pub brew: Option<String>,
    #[serde(default)]
    pub flatpak: Option<String>,
    #[serde(default)]
    pub snap: Option<String>,
}

impl SystemPackageStrategy {
    pub fn package_for(&self, pm: crate::platform::PackageManager) -> Option<&str> {
        use crate::platform::PackageManager;
        match pm {
            PackageManager::Pacman => self.pacman.as_deref(),
            PackageManager::Apt => self.apt.as_deref(),
            PackageManager::Dnf => self.dnf.as_deref(),
            PackageManager::Yum => self.yum.as_deref(),
            PackageManager::Zypper => self.zypper.as_deref(),
            PackageManager::Apk => self.apk.as_deref(),
            PackageManager::Brew => self.brew.as_deref(),
            PackageManager::Flatpak => self.flatpak.as_deref(),
            PackageManager::Snap => self.snap.as_deref(),
            PackageManager::Unknown => None,
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct PipVenvStrategy {
    pub package: String,
    pub install_dir_rel: String,
    pub binary_name: String,
    #[serde(default)]
    pub extra_binaries: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TarballStrategy {
    pub url_template: String,
    #[serde(default = "default_strip_components")]
    pub strip_components: u32,
    #[serde(default)]
    pub binary_rel_path: Option<String>,
    #[serde(default)]
    pub install_script: Option<String>,
    #[serde(default)]
    pub sdk_dir: Option<String>,
    #[serde(default)]
    pub sdk_name: Option<String>,
    #[serde(default)]
    pub install_script_args: Option<String>,
    #[serde(default)]
    pub symlinks: Vec<String>,
}

fn default_strip_components() -> u32 {
    1
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ScriptInstallerStrategy {
    pub url_template: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env_vars: Vec<String>,
    #[serde(default)]
    pub symlinks: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum InstallStrategy {
    GithubRelease(GithubReleaseStrategy),
    DirectBinary(DirectBinaryStrategy),
    HashicorpRelease(HashicorpReleaseStrategy),
    SystemPackage(SystemPackageStrategy),
    PipVenv(PipVenvStrategy),
    Tarball(TarballStrategy),
    ScriptInstaller(ScriptInstallerStrategy),
}

impl InstallStrategy {
    pub fn method_name(&self) -> &'static str {
        match self {
            InstallStrategy::GithubRelease(_) => METHOD_GITHUB_RELEASE,
            InstallStrategy::DirectBinary(_) => METHOD_DIRECT_BINARY,
            InstallStrategy::HashicorpRelease(_) => METHOD_HASHICORP,
            InstallStrategy::SystemPackage(_) => METHOD_SYSTEM_PACKAGE,
            InstallStrategy::PipVenv(_) => METHOD_PIP_VENV,
            InstallStrategy::Tarball(_) => METHOD_TARBALL,
            InstallStrategy::ScriptInstaller(_) => METHOD_SCRIPT_INSTALLER,
        }
    }

    pub fn execute(&self, ctx: &crate::install::InstallContext) -> anyhow::Result<()> {
        crate::install::execute(self, ctx)
    }
}

// ─── Tool definition ──────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ShellCompletions {
    #[serde(default)]
    pub bash_cmd: Option<String>,
    #[serde(default)]
    pub zsh_cmd: Option<String>,
    #[serde(default)]
    pub fish_cmd: Option<String>,
}

impl ShellCompletions {
    pub fn for_shell(&self, shell: crate::platform::Shell) -> Option<&str> {
        use crate::platform::Shell;
        match shell {
            Shell::Bash => self.bash_cmd.as_deref(),
            Shell::Zsh => self.zsh_cmd.as_deref(),
            Shell::Fish => self.fish_cmd.as_deref(),
            Shell::Unknown => None,
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Resource {
    pub label: String,
    pub url: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Tool {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub groups: Vec<Group>,
    #[serde(default)]
    pub homepage: String,
    pub version_source: VersionSource,
    pub strategy: InstallStrategy,
    #[serde(default)]
    pub brew_formula: Option<String>,
    #[serde(default)]
    pub shell_completions: Option<ShellCompletions>,
    #[serde(default)]
    pub aliases: Vec<String>,
    #[serde(default)]
    pub post_install: Vec<String>,
    #[serde(default)]
    pub post_upgrade: Vec<String>,
    #[serde(default)]
    pub quick_start: Vec<String>,
    #[serde(default)]
    pub resources: Vec<Resource>,
    /// Environment variables to export in the shell integration section.
    /// Each entry is `KEY=VALUE`; `$HOME` is expanded by the shell at runtime.
    #[serde(default)]
    pub shell_env: Vec<String>,
}

/// Compare two version strings like "0.16.0" > "0.1.1" semantically.
fn semver_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let parse = |s: &str| -> Vec<u64> { s.split('.').map(|p| p.parse().unwrap_or(0)).collect() };
    parse(a).cmp(&parse(b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deserialize_github_release_version_source() {
        let json = r#"{"type":"github_release","repo":"org/repo"}"#;
        let vs: VersionSource = serde_json::from_str(json).unwrap();
        assert!(matches!(vs, VersionSource::GithubRelease(_)));
    }

    #[test]
    fn deserialize_k8s_stable_txt() {
        let json = r#"{"type":"k8s_stable_txt"}"#;
        let vs: VersionSource = serde_json::from_str(json).unwrap();
        assert!(matches!(vs, VersionSource::K8sStableTxt));
    }

    #[test]
    fn deserialize_rust_stable() {
        let json = r#"{"type":"rust_stable"}"#;
        let vs: VersionSource = serde_json::from_str(json).unwrap();
        assert!(matches!(vs, VersionSource::RustStable));
    }

    #[test]
    fn deserialize_go_dl() {
        let json = r#"{"type":"go_dl"}"#;
        let vs: VersionSource = serde_json::from_str(json).unwrap();
        assert!(matches!(vs, VersionSource::GoDl));
    }

    #[test]
    fn deserialize_github_release_strategy() {
        let json = r#"{"type":"github_release","url_template":"https://example.com/v{version}/tool.tar.gz","binary_in_archive":"tool"}"#;
        let s: InstallStrategy = serde_json::from_str(json).unwrap();
        assert!(matches!(s, InstallStrategy::GithubRelease(_)));
    }

    #[test]
    fn deserialize_script_installer_strategy() {
        let json =
            r#"{"type":"script_installer","url_template":"https://sh.rustup.rs","args":["-y"]}"#;
        let s: InstallStrategy = serde_json::from_str(json).unwrap();
        assert!(matches!(s, InstallStrategy::ScriptInstaller(_)));
    }

    #[test]
    fn group_name_roundtrip() {
        let g = Group::K8s;
        let json = serde_json::to_string(&g).unwrap();
        assert_eq!(json, r#""k8s""#);
        let back: Group = serde_json::from_str(&json).unwrap();
        assert_eq!(back, Group::K8s);
    }
}
