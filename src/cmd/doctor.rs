use crate::platform::{Arch, OperatingSystem, PackageManager, Shell};
use crate::state::State;
use crate::tool::Tool;
use crate::ui::output;
use clap::Args;
use console::style;

#[derive(Debug, Args)]
pub struct DoctorArgs {}

pub fn run(_args: &DoctorArgs, state: &State, tools: &[Tool]) -> anyhow::Result<()> {
    let colored = output::get_render_mode() == output::RenderMode::Rich;
    let mut pass = 0usize;
    let mut warn = 0usize;
    let mut fail = 0usize;

    let home = dirs::home_dir().unwrap_or_default();
    let local_bin = home.join(".local/bin");

    output::print_section_header("System Health Check");

    // ─── System ───────────────────────────────────────────────────────────────
    output::print_section_header("System");

    let os = OperatingSystem::current();
    let arch = Arch::current();
    print_pass("OS", os.name(), colored);
    pass += 1;
    print_pass("Arch", arch.go_name(), colored);
    pass += 1;

    let shell = Shell::detect();
    print_pass("Shell", shell.name(), colored);
    pass += 1;

    let pm = PackageManager::detect();
    if pm != PackageManager::Unknown {
        print_pass(
            "Package Manager",
            pm.command().unwrap_or("unknown"),
            colored,
        );
        pass += 1;
    } else {
        print_warn("Package Manager", "none detected", colored);
        warn += 1;
    }

    // Check ~/.local/bin in PATH
    let path_env = std::env::var("PATH").unwrap_or_default();
    let lb_str = local_bin.to_str().unwrap_or("");
    if path_env.contains(lb_str) {
        print_pass("~/.local/bin in PATH", "yes", colored);
        pass += 1;
    } else {
        print_warn(
            "~/.local/bin in PATH",
            "not found — tools may not be accessible",
            colored,
        );
        warn += 1;
    }

    // ─── Installed Tools ──────────────────────────────────────────────────────
    output::print_section_header("Installed Tools");

    for (tool_id, _entry) in state.tools() {
        let bin_path = local_bin.join(tool_id);
        if bin_path.exists() {
            print_pass(tool_id, bin_path.to_str().unwrap_or(""), colored);
            pass += 1;
        } else if let Some(found) = crate::util::find_in_path(tool_id) {
            print_pass(tool_id, &found, colored);
            pass += 1;
        } else {
            print_fail(
                tool_id,
                &format!("not found — run: dot install {tool_id} --force"),
                colored,
            );
            fail += 1;
        }
    }

    // ─── Orphaned state entries ────────────────────────────────────────────────
    let mut has_orphan = false;
    for (tool_id, _) in state.tools() {
        if tool_id == "dot" {
            continue;
        }
        if !tools.iter().any(|t| &t.id == tool_id) {
            if !has_orphan {
                output::print_section_header("Orphaned Entries");
                has_orphan = true;
            }
            print_warn(
                tool_id,
                &format!("not in any repository — run: dot uninstall {tool_id}"),
                colored,
            );
            warn += 1;
        }
    }

    // ─── Shell integration ────────────────────────────────────────────────────
    output::print_section_header("Shell Integration");

    let shells_to_check = [Shell::Bash, Shell::Zsh, Shell::Fish];
    for check_sh in &shells_to_check {
        let integ_path = match crate::paths::shell_integration_file(*check_sh) {
            Ok(p) => p,
            Err(_) => continue,
        };
        if !integ_path.exists() {
            print_warn(check_sh.name(), "integration file not found", colored);
            warn += 1;
            continue;
        }
        print_pass(check_sh.name(), integ_path.to_str().unwrap_or(""), colored);
        pass += 1;
    }

    // ─── Summary ─────────────────────────────────────────────────────────────
    output::print_section_header("Summary");
    if colored {
        eprintln!(
            "\n  {}  {}  {}\n",
            style(format!("{pass} passed")).green().bold(),
            style(format!("{warn} warnings")).yellow(),
            if fail > 0 {
                style(format!("{fail} failed")).red().bold().to_string()
            } else {
                style(format!("{fail} failed")).dim().to_string()
            }
        );
    } else {
        eprintln!("\n  {pass} passed  {warn} warnings  {fail} failed\n");
    }
    Ok(())
}

fn print_pass(label: &str, detail: &str, colored: bool) {
    if colored {
        eprintln!("  {} {label:<24} {detail}", style("✓").green().bold());
    } else {
        eprintln!("  ok {label:<24} {detail}");
    }
}

fn print_warn(label: &str, detail: &str, colored: bool) {
    if colored {
        eprintln!("  {}  {label:<24} {detail}", style("⚠").yellow().bold());
    } else {
        eprintln!("  WARN  {label:<24} {detail}");
    }
}

fn print_fail(label: &str, detail: &str, colored: bool) {
    if colored {
        eprintln!("  {} {label:<24} {detail}", style("✗").red().bold());
    } else {
        eprintln!("  FAIL {label:<24} {detail}");
    }
}
