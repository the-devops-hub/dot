use crate::platform::Shell;
use crate::shell as shell_mod;
use crate::state::State;
use crate::tool::Tool;
use crate::ui::output;
use clap::Args;

#[derive(Debug, Args)]
pub struct UninstallArgs {
    /// Tool ID to uninstall
    pub tool: String,
}

pub fn run(args: &UninstallArgs, state: &mut State, tools: &[Tool]) -> anyhow::Result<()> {
    let id = &args.tool;

    if !state.is_installed(id) {
        // Check if it's a known tool
        let known = tools.iter().any(|t| &t.id == id);
        if !known {
            output::print_unknown_tool(id);
        } else {
            output::print_error(&format!("'{id}' is not installed"));
        }
        return Ok(());
    }

    let method = state
        .get_entry(id)
        .map(|e| e.method.clone())
        .unwrap_or_default();

    // Remove binary (skip for system_package)
    if method != "system_package" {
        let home = dirs::home_dir().unwrap_or_default();
        let bin_path = home.join(".local/bin").join(id);
        if bin_path.exists() {
            output::print_step_start("Removing binary", bin_path.to_str().unwrap_or(""));
            let _ = std::fs::remove_file(&bin_path);
        }
    }

    // Remove shell section
    let shell = Shell::detect();
    if shell != Shell::Unknown {
        let _ = shell_mod::remove_section(shell, id);
    }

    // Remove from state
    state.remove_tool(id)?;
    state.save()?;

    eprintln!("  Uninstalled {id}");
    Ok(())
}
