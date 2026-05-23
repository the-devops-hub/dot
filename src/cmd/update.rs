use crate::install::install_binary;
use crate::platform::{Arch, OperatingSystem};
use crate::state::State;
use crate::tool::{GithubSourceParams, VersionSource};
use crate::ui::output;
use clap::Args;

const GITHUB_REPO: &str = "the-devops-hub/dot";
const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Args)]
pub struct UpdateArgs {
    /// Install even if already up to date
    #[arg(long)]
    pub force: bool,
}

pub fn run(args: &UpdateArgs, state: &mut State) -> anyhow::Result<()> {
    output::print_step_start("Checking", "dot");

    let vs = VersionSource::GithubRelease(GithubSourceParams {
        repo: GITHUB_REPO.to_string(),
        filter: None,
        strip_prefix: None,
        require_asset: None,
    });

    let latest = match vs.resolve() {
        Ok(v) => v,
        Err(e) => {
            output::print_error(&format!("could not resolve latest version: {e}"));
            return Ok(());
        }
    };

    if !args.force && latest == CURRENT_VERSION {
        eprintln!("  dot {CURRENT_VERSION} is already up to date.");
        return Ok(());
    }

    output::print_step_start("Updating", &format!("{CURRENT_VERSION} → {latest}"));

    let os = OperatingSystem::current();
    let arch = Arch::current();
    let url = format!(
        "https://github.com/{GITHUB_REPO}/releases/download/v{latest}/dot-{}-{}.tar.gz",
        os.name(),
        arch.go_name()
    );

    let home = dirs::home_dir().unwrap_or_default();
    let tmp_dir = home.join(format!(".dot-tmp-update-{latest}"));
    std::fs::create_dir_all(&tmp_dir)?;
    let archive_path = tmp_dir.join("dot.tar.gz");

    let progress = crate::ui::progress::DownloadProgress::new();
    let mut cb = |done, total| progress.update(done, total);
    let dl = crate::http::download(
        &url,
        &archive_path,
        Some(&mut cb as &mut dyn FnMut(u64, Option<u64>)),
    );
    progress.finish();
    if let Err(e) = dl {
        let _ = std::fs::remove_dir_all(&tmp_dir);
        output::print_error(&format!("download failed: {e}\n  URL: {url}"));
        return Ok(());
    }

    let extract_dir = tmp_dir.join("extract");
    if let Err(e) = crate::archive::extract_tar_gz(&archive_path, &extract_dir, 0) {
        let _ = std::fs::remove_dir_all(&tmp_dir);
        output::print_error(&format!("extract failed: {e}"));
        return Ok(());
    }

    let src_bin = extract_dir.join("dot");
    let bin_dir = home.join(".local/bin");
    if let Err(e) = install_binary(&src_bin, "dot", &bin_dir) {
        let _ = std::fs::remove_dir_all(&tmp_dir);
        output::print_error(&format!("install failed: {e}"));
        return Ok(());
    }

    let _ = std::fs::remove_dir_all(&tmp_dir);

    state.add_tool("dot", &latest, "github_release", false)?;
    state.save()?;

    output::print_step_start("Updated", &format!("dot {latest}"));
    eprintln!("  {}", bin_dir.join("dot").display());
    Ok(())
}
