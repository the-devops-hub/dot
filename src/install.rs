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

    let mut args: Vec<&str> = pm.install_args().to_vec();
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
    let pip_status = std::process::Command::new(&pip)
        .args(["install", "--upgrade", &s.package])
        .status()
        .context("spawn pip install")?;
    if !pip_status.success() {
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
