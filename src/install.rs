use crate::platform::{Arch, OperatingSystem};
use crate::template::{render, TemplateContext};
use crate::ui::{output, progress::DownloadProgress};
use anyhow::Context;
use std::path::{Path, PathBuf};

// ─── InstallContext ───────────────────────────────────────────────────────────

pub struct InstallContext {
    pub tool_id: String,
    pub version: String,
    pub os: OperatingSystem,
    pub arch: Arch,
    pub bin_dir: PathBuf,
    pub tmp_dir: PathBuf,
}

impl InstallContext {
    pub fn opt_dir(&self) -> PathBuf {
        dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("/root"))
            .join(".local/opt")
            .join(&self.tool_id)
    }

    fn tctx<'a>(&'a self, opt_dir_str: &'a str) -> TemplateContext<'a> {
        TemplateContext {
            version: &self.version,
            os: self.os,
            arch: self.arch,
            bin_dir: self.bin_dir.to_str().unwrap_or(""),
            opt_dir: opt_dir_str,
        }
    }
}

// ─── execute() dispatch ───────────────────────────────────────────────────────

pub fn execute(
    strategy: &crate::tool::InstallStrategy,
    ctx: &InstallContext,
) -> anyhow::Result<()> {
    use crate::tool::InstallStrategy;
    match strategy {
        InstallStrategy::GithubRelease(s) => execute_github_release(s, ctx),
        InstallStrategy::DirectBinary(s) => execute_direct_binary(s, ctx),
        InstallStrategy::HashicorpRelease(s) => execute_hashicorp(s, ctx),
        InstallStrategy::SystemPackage(s) => execute_system_package(s, ctx),
        InstallStrategy::PipVenv(s) => execute_pip_venv(s, ctx),
        InstallStrategy::Npm(s) => execute_npm(s, ctx),
        InstallStrategy::Tarball(s) => execute_tarball(s, ctx),
        InstallStrategy::ScriptInstaller(s) => execute_script_installer(s, ctx),
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

pub fn install_binary(src: &Path, tool_id: &str, bin_dir: &Path) -> anyhow::Result<()> {
    std::fs::create_dir_all(bin_dir)
        .with_context(|| format!("create bin dir {}", bin_dir.display()))?;
    let dest = bin_dir.join(tool_id);
    let tmp_dest = bin_dir.join(format!("{tool_id}.new"));
    std::fs::copy(src, &tmp_dest)
        .with_context(|| format!("copy {} to {}", src.display(), tmp_dest.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o755);
        std::fs::set_permissions(&tmp_dest, perms)?;
    }
    std::fs::rename(&tmp_dest, &dest)?;
    Ok(())
}

fn verify_checksum(file_path: &Path, checksum_url: &str) -> anyhow::Result<()> {
    use sha2::{Digest, Sha256};
    let csum_body = crate::http::get(checksum_url)
        .with_context(|| format!("fetch checksum from {checksum_url}"))?;
    let first_space = csum_body
        .find(' ')
        .ok_or_else(|| anyhow::anyhow!("bad checksum format"))?;
    let expected = csum_body[..first_space].trim();
    if expected.len() != 64 {
        anyhow::bail!("bad checksum format: expected 64 hex chars");
    }
    let data = std::fs::read(file_path).with_context(|| format!("read {}", file_path.display()))?;
    let mut hasher = Sha256::new();
    hasher.update(&data);
    let actual = hex::encode(hasher.finalize());
    if actual != expected {
        anyhow::bail!("checksum mismatch: expected {expected}, got {actual}");
    }
    Ok(())
}

fn download_with_progress(url: &str, dest: &Path) -> anyhow::Result<()> {
    let progress = DownloadProgress::new();
    let mut cb = |done, total| progress.update(done, total);
    crate::http::download(url, dest, Some(&mut cb as &mut dyn FnMut(u64, Option<u64>)))
        .with_context(|| format!("download {url}"))?;
    progress.finish();
    Ok(())
}

fn extract_archive(archive_path: &Path, dest_dir: &Path, strip: u32) -> anyhow::Result<()> {
    let p = archive_path.to_str().unwrap_or("");
    if crate::archive::is_tar_gz(archive_path) {
        crate::archive::extract_tar_gz(archive_path, dest_dir, strip)?;
    } else if crate::archive::is_tar_xz(archive_path) {
        crate::archive::extract_tar_xz(archive_path, dest_dir, strip)?;
    } else if crate::archive::is_zip(archive_path) {
        crate::archive::extract_zip(archive_path, dest_dir)?;
    } else {
        anyhow::bail!("unrecognised archive format: {p}");
    }
    Ok(())
}

/// Create `bin_dir/<link_name>` as a relative symlink to a sibling binary
/// `bin_dir/<target_name>`. Used for tools that must appear under more than one
/// name on PATH, such as the kubectl plugin link `kubectl-oidc_login` -> `kubelogin`.
pub fn link_alias_in_bin(bin_dir: &Path, link_name: &str, target_name: &str) -> anyhow::Result<()> {
    std::fs::create_dir_all(bin_dir)?;
    let dst = bin_dir.join(link_name);
    let _ = std::fs::remove_file(&dst);
    #[cfg(unix)]
    std::os::unix::fs::symlink(target_name, &dst)
        .with_context(|| format!("symlink {} -> {target_name}", dst.display()))?;
    Ok(())
}

fn symlink_into_bin(src: &Path, bin_dir: &Path) -> anyhow::Result<()> {
    let name = src
        .file_name()
        .ok_or_else(|| anyhow::anyhow!("symlink source has no filename: {}", src.display()))?;
    let dst = bin_dir.join(name);
    std::fs::create_dir_all(bin_dir)?;
    let _ = std::fs::remove_file(&dst);
    #[cfg(unix)]
    {
        // Ensure the target is executable - zips built without Unix attributes land as 0o644.
        if src.exists() {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(src, std::fs::Permissions::from_mode(0o755));
        }
        std::os::unix::fs::symlink(src, &dst)
            .with_context(|| format!("symlink {} -> {}", src.display(), dst.display()))?;
    }
    Ok(())
}

// ─── Strategy impls ───────────────────────────────────────────────────────────

fn execute_github_release(
    s: &crate::tool::GithubReleaseStrategy,
    ctx: &InstallContext,
) -> anyhow::Result<()> {
    let opt_dir_buf = ctx.opt_dir();
    let opt_dir_str = opt_dir_buf.to_str().unwrap_or("").to_string();
    let tctx = ctx.tctx(&opt_dir_str);

    let url = render(&s.url_template, &tctx)?;
    let filename = Path::new(&url)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(&ctx.tool_id)
        .to_string();
    let archive_path = ctx.tmp_dir.join(&filename);

    output::print_step_start("Downloading", &filename);
    download_with_progress(&url, &archive_path)?;

    if let Some(ref tmpl) = s.checksum_url_template {
        let csum_url = render(tmpl, &tctx)?;
        if let Err(e) = verify_checksum(&archive_path, &csum_url) {
            output::print_checksum_warning(&e.to_string());
        }
    }

    let extract_dir = ctx.tmp_dir.join("extract");
    output::print_step_start("Extracting", &filename);
    extract_archive(&archive_path, &extract_dir, 0)?;

    let bin_subpath = render(&s.binary_in_archive, &tctx)?;
    let src_bin = extract_dir.join(&bin_subpath);
    install_binary(&src_bin, &ctx.tool_id, &ctx.bin_dir)?;

    for link_name in &s.extra_symlinks {
        link_alias_in_bin(&ctx.bin_dir, link_name, &ctx.tool_id)?;
    }
    Ok(())
}

fn execute_direct_binary(
    s: &crate::tool::DirectBinaryStrategy,
    ctx: &InstallContext,
) -> anyhow::Result<()> {
    let opt_dir_buf = ctx.opt_dir();
    let opt_dir_str = opt_dir_buf.to_str().unwrap_or("").to_string();
    let tctx = ctx.tctx(&opt_dir_str);

    let url = render(&s.url_template, &tctx)?;
    let filename = ctx.tool_id.clone();
    let tmp_bin = ctx.tmp_dir.join(&filename);

    output::print_step_start("Downloading", &filename);
    download_with_progress(&url, &tmp_bin)?;
    install_binary(&tmp_bin, &ctx.tool_id, &ctx.bin_dir)?;
    Ok(())
}

fn execute_hashicorp(
    s: &crate::tool::HashicorpReleaseStrategy,
    ctx: &InstallContext,
) -> anyhow::Result<()> {
    let url = format!(
        "https://releases.hashicorp.com/{0}/{1}/{0}_{1}_{2}_{3}.zip",
        s.product,
        ctx.version,
        ctx.os.name(),
        ctx.arch.go_name()
    );
    let archive_name = format!("{}.zip", s.product);
    let archive_path = ctx.tmp_dir.join(&archive_name);

    output::print_step_start("Downloading", &archive_name);
    download_with_progress(&url, &archive_path)?;

    let extract_dir = ctx.tmp_dir.join("extract");
    output::print_step_start("Extracting", &archive_name);
    crate::archive::extract_zip(&archive_path, &extract_dir)?;

    let src_bin = extract_dir.join(&s.product);
    install_binary(&src_bin, &ctx.tool_id, &ctx.bin_dir)?;
    Ok(())
}

fn execute_system_package(
    s: &crate::tool::SystemPackageStrategy,
    ctx: &InstallContext,
) -> anyhow::Result<()> {
    let _ = ctx;
    use crate::platform::PackageManager;
    let pm = PackageManager::detect();
    let pkg_name = s.package_for(pm).ok_or_else(|| {
        let pm_name = pm.command().unwrap_or("unknown");
        output::print_no_package_manager(pm_name);
        anyhow::anyhow!(crate::error::DotError::NoPackageForManager)
    })?;

    // For an already-installed package some managers (dnf5) need `upgrade`, as
    // `install` quietly does nothing and still exits 0.
    let base_args = match pm.upgrade_args() {
        Some(upgrade) if pm.installed_version(pkg_name).is_some() => upgrade,
        _ => pm.install_args(),
    };
    let mut args: Vec<&str> = base_args.to_vec();
    args.push(pkg_name);

    let cmd_name = pm.command().unwrap_or("unknown");
    output::print_running_cmd(cmd_name, pkg_name);

    let status = std::process::Command::new(args[0])
        .args(&args[1..])
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .with_context(|| format!("spawn {cmd_name}"))?;

    if !status.success() {
        output::print_detail("Package install failed");
        anyhow::bail!(crate::error::DotError::PackageInstallFailed);
    }
    Ok(())
}

fn python3_install_hint() -> &'static str {
    use crate::platform::PackageManager;
    match PackageManager::detect() {
        PackageManager::Apt => "sudo apt install python3 python3-venv",
        PackageManager::Dnf | PackageManager::Yum => "sudo dnf install python3",
        PackageManager::Pacman => "sudo pacman -S python",
        PackageManager::Apk => "sudo apk add python3",
        PackageManager::Brew => "brew install python3",
        _ => "install python3 from https://python.org",
    }
}

fn python_devel_hint() -> &'static str {
    use crate::platform::PackageManager;
    match PackageManager::detect() {
        PackageManager::Apt => "sudo apt install python3-dev build-essential",
        PackageManager::Dnf | PackageManager::Yum => "sudo dnf install python3-devel gcc",
        PackageManager::Pacman => "sudo pacman -S base-devel",
        PackageManager::Apk => "sudo apk add python3-dev build-base",
        PackageManager::Zypper => "sudo zypper install python3-devel gcc",
        PackageManager::Brew => "xcode-select --install",
        _ => "install the Python development headers and a C compiler",
    }
}

/// `major.minor` from a venv's `pyvenv.cfg` (`version = 3.14.2`).
fn venv_cfg_python(cfg: &str) -> Option<String> {
    let v = cfg.lines().find_map(|l| {
        l.strip_prefix("version")
            .and_then(|r| r.trim_start().strip_prefix('='))
    })?;
    let mut parts = v.trim().split('.');
    Some(format!("{}.{}", parts.next()?, parts.next()?))
}

/// `major.minor` of the `python3` on PATH.
fn system_python_version() -> Option<String> {
    let out = std::process::Command::new("python3")
        .args(["-c", "import sys; print('%d.%d' % sys.version_info[:2])"])
        .output()
        .ok()
        .filter(|o| o.status.success())?;
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// True if `site_packages` holds an installed distribution of `package`.
fn has_dist(site_packages: &Path, package: &str) -> bool {
    // dist-info directories use the normalised name: lowercase, `-`/`.` as `_`.
    let prefix = format!("{}-", package.to_lowercase().replace(['-', '.'], "_"));
    std::fs::read_dir(site_packages)
        .into_iter()
        .flatten()
        .flatten()
        .any(|e| {
            let name = e
                .file_name()
                .to_string_lossy()
                .to_lowercase()
                .replace(['-', '.'], "_");
            e.file_name().to_string_lossy().ends_with(".dist-info")
                && name.starts_with(&prefix.replace('-', "_"))
        })
}

/// True when an existing venv was built for a different Python than the one on
/// PATH now (after an OS upgrade). Its installed packages are invisible to the new
/// interpreter, so it has to be rebuilt rather than upgraded in place.
fn venv_is_stale(install_dir: &Path, system_python: &str, package: &str) -> bool {
    let Ok(cfg) = std::fs::read_to_string(install_dir.join("pyvenv.cfg")) else {
        return false; // not a venv (or nothing there yet): nothing to rebuild
    };
    if venv_cfg_python(&cfg).is_some_and(|v| v != system_python) {
        return true;
    }
    // An earlier run may already have rewritten pyvenv.cfg for the new Python while
    // the tool itself stayed behind in lib/python<old>/site-packages.
    let lib = install_dir.join("lib");
    let current = lib.join(format!("python{system_python}"));
    !has_dist(&current.join("site-packages"), package)
        && std::fs::read_dir(&lib)
            .into_iter()
            .flatten()
            .flatten()
            .any(|e| e.path() != current && has_dist(&e.path().join("site-packages"), package))
}

/// The few lines of pip output that explain a failure: error lines, de-duplicated,
/// or the last lines when none look like errors.
fn summarize_pip_failure(text: &str) -> Vec<String> {
    let mut errors: Vec<String> = Vec::new();
    for line in text.lines().map(str::trim) {
        let lower = line.to_lowercase();
        let interesting = lower.contains("fatal error")
            || lower.starts_with("error:")
            || lower.starts_with("error ")
            || lower.contains("failed to build")
            || lower.contains("no matching distribution")
            || lower.contains("could not find a version");
        if interesting && !errors.iter().any(|e| e == line) {
            errors.push(line.to_string());
        }
    }
    if errors.is_empty() {
        let tail: Vec<&str> = text
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .collect();
        return tail[tail.len().saturating_sub(8)..]
            .iter()
            .map(|l| l.to_string())
            .collect();
    }
    errors.truncate(8);
    errors
}

/// Save the full pip output under the user's cache dir so it can be inspected.
fn write_pip_log(tool_id: &str, text: &str) -> Option<PathBuf> {
    let dir = dirs::cache_dir()?.join("dot");
    std::fs::create_dir_all(&dir).ok()?;
    let path = dir.join(format!("{tool_id}-pip.log"));
    std::fs::write(&path, text).ok()?;
    Some(path)
}

fn execute_pip_venv(s: &crate::tool::PipVenvStrategy, ctx: &InstallContext) -> anyhow::Result<()> {
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/root"));
    let install_dir = if s.install_dir_rel.starts_with("~/") {
        home.join(&s.install_dir_rel[2..])
    } else {
        PathBuf::from(&s.install_dir_rel)
    };

    if crate::util::find_in_path("python3").is_none() {
        output::print_detail(&format!("python3 is required: {}", python3_install_hint()));
        anyhow::bail!(crate::error::DotError::PythonNotFound);
    }

    if let Some(py) = system_python_version() {
        if venv_is_stale(&install_dir, &py, &s.package) {
            output::print_detail(&format!(
                "venv was built for a different Python than {py}: rebuilding it"
            ));
            std::fs::remove_dir_all(&install_dir)
                .with_context(|| format!("remove stale venv {}", install_dir.display()))?;
        }
    }

    output::print_step_start("Venv", install_dir.to_str().unwrap_or(""));
    let venv_status = std::process::Command::new("python3")
        .args(["-m", "venv", install_dir.to_str().unwrap_or("")])
        .status()
        .context("spawn python3 -m venv")?;
    if !venv_status.success() {
        output::print_detail(&format!(
            "python3-venv is required: {}",
            python3_install_hint()
        ));
        anyhow::bail!(crate::error::DotError::VenvCreationFailed);
    }

    let pip = install_dir.join("bin/pip");
    output::print_step_start("pip install", &s.package);
    // Capture pip's output: it can run to hundreds of lines (compiler invocations,
    // build logs) that bury the actual error. Show a short summary on failure and
    // keep the full log on disk.
    let pip_out = std::process::Command::new(&pip)
        .args([
            "install",
            "--upgrade",
            "--disable-pip-version-check",
            "--no-input",
            &s.package,
        ])
        .stdin(std::process::Stdio::null())
        .output()
        .context("spawn pip install")?;
    if !pip_out.status.success() {
        let text = format!(
            "{}\n{}",
            String::from_utf8_lossy(&pip_out.stdout),
            String::from_utf8_lossy(&pip_out.stderr)
        );
        output::print_detail("pip install failed:");
        for line in summarize_pip_failure(&text) {
            output::print_detail(&format!("  {line}"));
        }
        if let Some(log) = write_pip_log(&ctx.tool_id, &text) {
            output::print_detail(&format!("full pip output: {}", log.display()));
        }
        let lower = text.to_lowercase();
        if lower.contains("failed to build")
            || lower.contains("failed building wheel")
            || lower.contains("fatal error")
        {
            output::print_detail(&format!(
                "a package failed to build: install the Python headers and a C compiler: {}",
                python_devel_hint()
            ));
        }
        anyhow::bail!(crate::error::DotError::PipInstallFailed);
    }

    std::fs::create_dir_all(&ctx.bin_dir)?;

    // Symlink primary binary
    let src = install_dir.join("bin").join(&s.binary_name);
    let dst = ctx.bin_dir.join(&s.binary_name);
    let _ = std::fs::remove_file(&dst);
    #[cfg(unix)]
    std::os::unix::fs::symlink(&src, &dst)?;

    // Symlink extra binaries
    for extra in &s.extra_binaries {
        let extra_src = install_dir.join("bin").join(extra);
        let extra_dst = ctx.bin_dir.join(extra);
        let _ = std::fs::remove_file(&extra_dst);
        #[cfg(unix)]
        std::os::unix::fs::symlink(&extra_src, &extra_dst)?;
    }
    Ok(())
}

fn node_install_hint() -> &'static str {
    use crate::platform::PackageManager;
    match PackageManager::detect() {
        PackageManager::Apt => "sudo apt install nodejs npm",
        PackageManager::Dnf | PackageManager::Yum => "sudo dnf install nodejs npm",
        PackageManager::Pacman => "sudo pacman -S nodejs npm",
        PackageManager::Apk => "sudo apk add nodejs npm",
        PackageManager::Brew => "brew install node",
        _ => "install Node.js from https://nodejs.org",
    }
}

/// Major version from `node --version` output such as "v20.11.1".
fn node_major(version: &str) -> Option<u32> {
    version
        .trim()
        .trim_start_matches('v')
        .split('.')
        .next()?
        .parse()
        .ok()
}

fn execute_npm(s: &crate::tool::NpmStrategy, ctx: &InstallContext) -> anyhow::Result<()> {
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/root"));
    let install_dir = if s.install_dir_rel.starts_with("~/") {
        home.join(&s.install_dir_rel[2..])
    } else {
        PathBuf::from(&s.install_dir_rel)
    };

    if crate::util::find_in_path("node").is_none() || crate::util::find_in_path("npm").is_none() {
        output::print_detail(&format!(
            "node and npm are required: {} (or: dot install node)",
            node_install_hint()
        ));
        anyhow::bail!(crate::error::DotError::NodeNotFound);
    }

    if let Some(required) = s.min_node_major {
        let out = std::process::Command::new("node")
            .arg("--version")
            .output()
            .context("run node --version")?;
        if !out.status.success() {
            output::print_detail("`node --version` failed: is node on PATH working?");
            anyhow::bail!(crate::error::DotError::NodeNotFound);
        }
        let found = String::from_utf8_lossy(&out.stdout).trim().to_string();
        // An unparseable version is let through: npm itself will still complain if
        // the package really cannot run.
        if node_major(&found).is_some_and(|m| m < required) {
            output::print_detail("upgrade with: dot install node --force");
            anyhow::bail!(crate::error::DotError::NodeTooOld {
                found: found.trim_start_matches('v').to_string(),
                required,
            });
        }
    }

    std::fs::create_dir_all(&install_dir)?;
    let spec = format!("{}@{}", s.package, ctx.version);
    output::print_step_start("npm install", &spec);
    let status = std::process::Command::new("npm")
        .args(["install", "--prefix"])
        .arg(&install_dir)
        .args(["--no-fund", "--no-audit", "--loglevel=error", &spec])
        .status()
        .context("spawn npm install")?;
    if !status.success() {
        anyhow::bail!(crate::error::DotError::NpmInstallFailed);
    }

    std::fs::create_dir_all(&ctx.bin_dir)?;
    let npm_bin = install_dir.join("node_modules/.bin");
    for name in std::iter::once(&s.binary_name).chain(s.extra_binaries.iter()) {
        let src = npm_bin.join(name);
        if !src.exists() {
            anyhow::bail!(
                "npm package {} did not provide the '{name}' binary",
                s.package
            );
        }
        let dst = ctx.bin_dir.join(name);
        let _ = std::fs::remove_file(&dst);
        #[cfg(unix)]
        std::os::unix::fs::symlink(&src, &dst)?;
    }
    Ok(())
}

fn execute_tarball(s: &crate::tool::TarballStrategy, ctx: &InstallContext) -> anyhow::Result<()> {
    let opt_dir_buf = ctx.opt_dir();
    let opt_dir_str = opt_dir_buf.to_str().unwrap_or("").to_string();
    let tctx = ctx.tctx(&opt_dir_str);

    let url = render(&s.url_template, &tctx)?;
    let filename = Path::new(&url)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(&ctx.tool_id)
        .to_string();
    let archive_path = ctx.tmp_dir.join(&filename);

    output::print_step_start("Downloading", &filename);
    download_with_progress(&url, &archive_path)?;

    // For sdk_dir installs, extract inside ~/.local/opt so rename is same-filesystem.
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/root"));
    let opt_parent = home.join(".local/opt");

    let extract_dir: PathBuf = if s.sdk_dir.is_some() {
        std::fs::create_dir_all(&opt_parent)?;
        let tmp = opt_parent.join(format!(".tmp-{}", ctx.tool_id));
        let _ = std::fs::remove_dir_all(&tmp);
        tmp
    } else {
        ctx.tmp_dir.join("extract")
    };

    output::print_step_start("Extracting", &filename);
    extract_archive(&archive_path, &extract_dir, s.strip_components)?;

    // Determine the working directory
    let effective_dir: PathBuf = if let Some(ref sd_tmpl) = s.sdk_dir {
        let sd = render(sd_tmpl, &tctx)?;
        let install_name = s.sdk_name.as_deref().unwrap_or(&sd);
        let sdk_path = opt_parent.join(install_name);
        // Remove previous install and rename extracted subdir into place
        let _ = std::fs::remove_dir_all(&sdk_path);
        let src = extract_dir.join(&sd);
        std::fs::rename(&src, &sdk_path)
            .with_context(|| format!("rename {} to {}", src.display(), sdk_path.display()))?;
        let _ = std::fs::remove_dir_all(&extract_dir);
        sdk_path
    } else {
        extract_dir.clone()
    };

    if let Some(ref script_rel) = s.install_script {
        let script_path = effective_dir.join(script_rel);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(0o755);
            std::fs::set_permissions(&script_path, perms)?;
        }
        let mut argv: Vec<String> = vec![script_path.to_str().unwrap_or("").to_string()];
        if let Some(ref args_tmpl) = s.install_script_args {
            for token in args_tmpl.split(' ') {
                if token.is_empty() {
                    continue;
                }
                let expanded = render(token, &tctx)?;
                argv.push(expanded);
            }
        }
        let status = std::process::Command::new(&argv[0])
            .args(&argv[1..])
            .status()
            .with_context(|| format!("run install script {}", script_path.display()))?;
        if !status.success() {
            anyhow::bail!(crate::error::DotError::InstallScriptFailed(
                status.code().unwrap_or(-1)
            ));
        }
    } else if let Some(ref rel) = s.binary_rel_path {
        let src = effective_dir.join(rel);
        install_binary(&src, &ctx.tool_id, &ctx.bin_dir)?;
    }

    for sym in &s.symlinks {
        let src = effective_dir.join(sym);
        symlink_into_bin(&src, &ctx.bin_dir)?;
    }
    Ok(())
}

fn execute_script_installer(
    s: &crate::tool::ScriptInstallerStrategy,
    ctx: &InstallContext,
) -> anyhow::Result<()> {
    let opt_dir_buf = ctx.opt_dir();
    let opt_dir_str = opt_dir_buf.to_str().unwrap_or("").to_string();
    let tctx = ctx.tctx(&opt_dir_str);

    let url = render(&s.url_template, &tctx)?;
    let installer_name = Path::new(&url)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("installer")
        .to_string();
    let installer_path = ctx.tmp_dir.join(&installer_name);

    output::print_step_start("Downloading", &installer_name);
    download_with_progress(&url, &installer_path)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o755);
        std::fs::set_permissions(&installer_path, perms)?;
    }

    // Build shell command: [KEY=VAL ...] installer args...
    let mut cmd_parts: Vec<String> = Vec::new();
    for ev in &s.env_vars {
        cmd_parts.push(render(ev, &tctx)?);
    }
    cmd_parts.push(installer_path.to_str().unwrap_or("").to_string());
    for arg in &s.args {
        cmd_parts.push(arg.clone());
    }
    let cmd_str = cmd_parts.join(" ");

    output::print_step_start("Running", &installer_name);
    let status = std::process::Command::new("sh")
        .args(["-c", &cmd_str])
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .context("spawn sh -c installer")?;
    if !status.success() {
        anyhow::bail!(crate::error::DotError::InstallerFailed);
    }

    for sym_tmpl in &s.symlinks {
        let src_str = render(sym_tmpl, &tctx)?;
        let src = PathBuf::from(&src_str);
        symlink_into_bin(&src, &ctx.bin_dir)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn summarize_pip_failure_picks_error_lines() {
        let text = "Collecting x\n  gcc -O3 -c foo.c\n      src/_c.c:28:10: fatal error: Python.h: No such file or directory\n      src/_c.c:28:10: fatal error: Python.h: No such file or directory\n  ERROR: Failed building wheel for crc32c\nFailed to build crc32c python-pkcs11\n";
        let got = summarize_pip_failure(text);
        assert_eq!(got.len(), 3);
        assert!(got[0].contains("Python.h"));
        assert!(got[1].starts_with("ERROR:"));
        assert!(got[2].starts_with("Failed to build"));
        // No recognisable error: fall back to the last lines.
        let got = summarize_pip_failure("a\nb\nc\n");
        assert_eq!(got, ["a", "b", "c"]);
    }

    #[test]
    fn venv_cfg_python_reads_major_minor() {
        let cfg = "home = /usr/bin\ninclude-system-site-packages = false\nversion = 3.14.2\n";
        assert_eq!(venv_cfg_python(cfg).as_deref(), Some("3.14"));
        assert_eq!(venv_cfg_python("home = /usr/bin\n"), None);
    }

    #[test]
    fn venv_is_stale_detects_python_upgrade() {
        let tmp = TempDir::new().unwrap();
        let venv = tmp.path().join("v");
        // Not a venv yet: never stale.
        assert!(!venv_is_stale(&venv, "3.15", "oci-cli"));
        let old = venv.join("lib/python3.14/site-packages");
        std::fs::create_dir_all(old.join("oci_cli-3.97.1.dist-info")).unwrap();
        std::fs::create_dir_all(old.join("pip-26.1.2.dist-info")).unwrap();
        std::fs::write(venv.join("pyvenv.cfg"), "version = 3.14.2\n").unwrap();
        // Same Python: fine.
        assert!(!venv_is_stale(&venv, "3.14", "oci-cli"));
        // Config says an older Python than PATH has.
        assert!(venv_is_stale(&venv, "3.15", "oci-cli"));
        // Config already rewritten, a fresh venv holds only pip, the tool is stranded.
        std::fs::write(venv.join("pyvenv.cfg"), "version = 3.15.2\n").unwrap();
        let new = venv.join("lib/python3.15/site-packages");
        std::fs::create_dir_all(new.join("pip-26.1.2.dist-info")).unwrap();
        assert!(venv_is_stale(&venv, "3.15", "oci-cli"));
        // Once the tool is installed for the current Python it is healthy again.
        std::fs::create_dir_all(new.join("oci_cli-3.97.1.dist-info")).unwrap();
        assert!(!venv_is_stale(&venv, "3.15", "oci-cli"));
    }

    #[test]
    fn node_major_parses_versions() {
        assert_eq!(super::node_major("v20.11.1\n"), Some(20));
        assert_eq!(super::node_major("18.0.0"), Some(18));
        assert_eq!(super::node_major("garbage"), None);
    }

    #[cfg(unix)]
    #[test]
    fn link_alias_creates_relative_symlink() {
        let tmp = TempDir::new().unwrap();
        let bin = tmp.path();
        std::fs::write(bin.join("kubelogin"), b"#!/bin/sh\n").unwrap();

        link_alias_in_bin(bin, "kubectl-oidc_login", "kubelogin").unwrap();

        let link = bin.join("kubectl-oidc_login");
        let target = std::fs::read_link(&link).unwrap();
        assert_eq!(target, Path::new("kubelogin"));
        assert!(link.exists(), "link should resolve to the sibling binary");
    }

    #[cfg(unix)]
    #[test]
    fn link_alias_replaces_stale_symlink() {
        let tmp = TempDir::new().unwrap();
        let bin = tmp.path();
        std::fs::write(bin.join("kubelogin"), b"#!/bin/sh\n").unwrap();
        std::os::unix::fs::symlink("gone", bin.join("kubectl-oidc_login")).unwrap();

        link_alias_in_bin(bin, "kubectl-oidc_login", "kubelogin").unwrap();

        assert_eq!(
            std::fs::read_link(bin.join("kubectl-oidc_login")).unwrap(),
            Path::new("kubelogin")
        );
    }
}
