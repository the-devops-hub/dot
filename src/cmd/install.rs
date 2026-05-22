use crate::install::InstallContext;
use crate::platform::{Arch, OperatingSystem, PackageManager, Shell};
use crate::shell as shell_mod;
use crate::state::State;
use crate::tool::{Group, Tool};
use crate::ui::output;
use crate::util;
use crate::validate;
use anyhow::Context;
use clap::Args;
use std::path::PathBuf;

#[derive(Debug, Args)]
pub struct InstallArgs {
    /// Tool ID or group name to install
    pub tool: Option<String>,
    /// Install all tools in a group
    #[arg(short, long, value_name = "GROUP")]
    pub group: Option<String>,
    /// Specific version to install
    #[arg(short, long, value_name = "VERSION")]
    pub version: Option<String>,
    /// Force reinstall even if already installed / up to date
    #[arg(long)]
    pub force: bool,
}

pub fn run(args: &InstallArgs, state: &mut State, tools: &[Tool]) -> anyhow::Result<()> {
    // Determine what to install
    let tool_name = args.tool.as_deref().unwrap_or("");
    let group_flag = args.group.as_deref();
    let force = args.force;
    let version_arg = args.version.as_deref();

    if tool_name.is_empty() && group_flag.is_none() {
        output::print_error("no tool or group specified — usage: dot install <tool|group>");
        return Ok(());
    }

    // Validate version if provided
    if let Some(v) = version_arg {
        if !validate::is_valid_version(v) {
            output::print_error("invalid version string");
            return Ok(());
        }
    }

    let is_group =
        group_flag.is_some() || tool_name == "all" || super::list::parse_group(tool_name).is_some();

    if is_group {
        let grp_name = group_flag.unwrap_or(tool_name);
        install_group(grp_name, force, state, tools)
    } else {
        if !validate::is_valid_tool_id(tool_name) {
            output::print_error("invalid tool name");
            return Ok(());
        }
        install_tool(tool_name, version_arg, force, state, tools)
    }
}

fn install_group(
    group_name: &str,
    force: bool,
    state: &mut State,
    tools: &[Tool],
) -> anyhow::Result<()> {
    let is_all = group_name == "all";

    let group_tools: Vec<&Tool> = if is_all {
        tools.iter().collect()
    } else {
        let group = super::list::parse_group(group_name).ok_or_else(|| {
            eprintln!("Unknown group '{group_name}'. Valid groups: k8s, cloud, iac, containers, utils, terminal, cm, security, dev");
            anyhow::anyhow!("unknown group")
        })?;
        tools.iter().filter(|t| t.groups.contains(&group)).collect()
    };

    if group_tools.is_empty() {
        eprintln!("No tools found in group '{group_name}'");
        return Ok(());
    }

    let total = group_tools.len();
    eprintln!("\nInstalling group '{group_name}' ({total} tools)\n");

    for (i, t) in group_tools.iter().enumerate() {
        eprintln!("─── [{}/{total}] {} ───", i + 1, t.name);
        if let Err(e) = install_tool(t.id.as_str(), None, force, state, tools) {
            eprintln!("  Error installing {}: {e:#}", t.id);
        }
    }
    Ok(())
}

pub fn install_tool(
    id: &str,
    version_arg: Option<&str>,
    force: bool,
    state: &mut State,
    tools: &[Tool],
) -> anyhow::Result<()> {
    let tool = match find_tool(id, tools) {
        Some(t) => t,
        None => {
            output::print_unknown_tool(id);
            if let Some(sug) = closest_tool(id, tools) {
                eprintln!("Did you mean '{sug}'?");
            }
            return Ok(());
        }
    };

    // Resolve version
    let version = if let Some(v) = version_arg {
        v.to_string()
    } else {
        match tool.version_source.resolve() {
            Ok(v) => v,
            Err(e) => {
                eprintln!("Warning: could not fetch version (VersionFetchFailed), using 'latest'");
                "latest".to_string()
            }
        }
    };

    // Skip pinned unless forced
    if !force && version_arg.is_none() && state.is_pinned(&tool.id) {
        let pinned_ver = state.get_version(&tool.id).unwrap_or("pinned");
        eprintln!(
            "  ~ {} {} is pinned at {pinned_ver} — skipping",
            tool.name, tool.id
        );
        eprintln!("  To upgrade anyway: dot install {} --force", tool.id);
        return Ok(());
    }

    // Check for system install conflict (skip for system_package strategy)
    let is_sys_pkg = matches!(
        tool.strategy,
        crate::tool::InstallStrategy::SystemPackage(_)
    );
    if !force && !state.is_installed(&tool.id) && !is_sys_pkg {
        if let Some(sys_path) = check_system_install(&tool.id) {
            eprintln!(
                "  {} {} is already available at {}",
                tool.name,
                version,
                sys_path.display()
            );
            eprintln!("  Use --force to install via dot anyway.");
            return Ok(());
        }
    }

    let installed_ver = state.get_version(&tool.id).map(|s| s.to_string());

    // Already up to date?
    if !force {
        if let Some(ref iv) = installed_ver {
            if iv == &version {
                // Regenerate shell section in case integration file was lost
                let _ = write_shell_integration(tool, false);
                output::print_already_current(&tool.name, &version, &tool.id);
                return Ok(());
            }
        }
    }

    let os = OperatingSystem::current();
    let arch = Arch::current();

    // Brew path: preferred when available and tool has a formula
    let mut used_brew = false;
    if let Some(ref formula) = tool.brew_formula {
        if PackageManager::Brew.is_available() {
            output::print_step(formula, false, "");
            if let Err(e) = brew_install(formula, force) {
                output::print_error(&format!("brew install failed: {e}"));
                return Ok(());
            }
            used_brew = true;
        }
    }

    if !used_brew {
        let home = dirs::home_dir().unwrap_or_default();
        let bin_dir = home.join(".local/bin");
        let tmp_dir = home.join(format!(".dot-tmp-{}-{}", tool.id, version));

        std::fs::create_dir_all(&tmp_dir)?;

        let step_msg = match &installed_ver {
            Some(old) => format!(
                "Upgrading {} {} {} {}",
                tool.name,
                old,
                output::step_arrow(),
                version
            ),
            None => format!("Installing {} {}", tool.name, version),
        };
        output::print_step_start(&step_msg, "");

        let ctx = InstallContext {
            tool_id: tool.id.clone(),
            version: version.clone(),
            os,
            arch,
            bin_dir: bin_dir.clone(),
            tmp_dir: tmp_dir.clone(),
        };

        let install_result = tool.strategy.execute(&ctx);
        let _ = std::fs::remove_dir_all(&tmp_dir);

        if let Err(e) = install_result {
            output::print_step("Installation", true, &e.to_string());
            return Err(anyhow::anyhow!("Installation failed"));
        }

        eprintln!("  {}", bin_dir.join(&tool.id).display());
    }

    // Update state
    let method = if used_brew {
        "brew"
    } else {
        tool.strategy.method_name()
    };
    state.add_tool(&tool.id, &version, method, false)?;
    state.save()?;

    // Shell integration
    write_shell_integration(tool, true);

    // Caveats
    output::print_caveats(&tool.post_install);

    Ok(())
}

fn write_shell_integration(tool: &Tool, print_step: bool) -> bool {
    let shell = Shell::detect();
    if shell == Shell::Unknown {
        return false;
    }

    let section = build_shell_section(tool, shell);
    if let Some(content) = section {
        let _ = shell_mod::ensure_sourced(shell);
        let _ = shell_mod::add_section(shell, &tool.id, &content);
    } else {
        let _ = shell_mod::remove_section(shell, &tool.id);
    }

    if print_step {
        output::print_step_start("Shell", shell.name());
    }
    true
}

fn build_shell_section(tool: &Tool, shell: Shell) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();

    for env_str in &tool.shell_env {
        if let Some(eq) = env_str.find('=') {
            let key = &env_str[..eq];
            let val = &env_str[eq + 1..];
            let line = match shell {
                Shell::Fish => format!("set -gx {key} {val}"),
                _ => format!("export {key}={val}"),
            };
            parts.push(line);
        }
    }

    if let Some(ref completions) = tool.shell_completions {
        if let Some(cmd) = completions.for_shell(shell) {
            let guarded = guarded_completion(shell, &tool.id, cmd);
            parts.push(guarded);
        }
    }

    for alias_name in &tool.aliases {
        if !parts.is_empty() {
            parts.push(String::new());
        }
        parts.push(format!("alias {alias_name}={}", tool.id));

        // Completion delegation
        let delegation = match shell {
            Shell::Fish => Some(format!("complete -c {alias_name} -w {}", tool.id)),
            Shell::Zsh
                if tool
                    .shell_completions
                    .as_ref()
                    .and_then(|c| c.zsh_cmd.as_ref())
                    .is_some() =>
            {
                Some(format!("compdef {alias_name}={}", tool.id))
            }
            _ => None,
        };
        if let Some(line) = delegation {
            parts.push(line);
        }
    }

    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n"))
    }
}

fn guarded_completion(shell: Shell, id: &str, cmd: &str) -> String {
    match shell {
        Shell::Fish => format!("if command -q {id}\n    {cmd}\nend"),
        Shell::Bash | Shell::Zsh => format!("command -v {id} >/dev/null 2>&1 && {cmd}"),
        Shell::Unknown => cmd.to_string(),
    }
}

fn brew_install(formula: &str, force: bool) -> anyhow::Result<()> {
    let brew_cmd = if force { "reinstall" } else { "install" };
    let status = std::process::Command::new("brew")
        .args([brew_cmd, formula])
        .status()
        .context("spawn brew")?;
    if !status.success() {
        anyhow::bail!("brew {brew_cmd} {formula} failed");
    }
    Ok(())
}

fn check_system_install(id: &str) -> Option<PathBuf> {
    let home = dirs::home_dir()?;
    let our_path = home.join(".local/bin").join(id);
    let found = util::find_in_path(id)?;
    let found_path = std::path::PathBuf::from(&found);
    if found_path == our_path {
        None
    } else {
        Some(found_path)
    }
}

fn find_tool<'a>(id: &str, tools: &'a [Tool]) -> Option<&'a Tool> {
    tools
        .iter()
        .find(|t| t.id == id || t.aliases.iter().any(|a| a == id))
}

fn closest_tool<'a>(query: &str, tools: &'a [Tool]) -> Option<&'a str> {
    use crate::util::edit_distance;
    const THRESHOLD: usize = 3;
    let mut best_dist = usize::MAX;
    let mut best_id = None;
    for t in tools {
        let d = edit_distance(&t.id, query);
        if d < best_dist {
            best_dist = d;
            best_id = Some(t.id.as_str());
        }
    }
    if best_dist <= THRESHOLD {
        best_id
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::Shell;

    #[test]
    fn guarded_completion_fish_wraps_with_command_q() {
        let result = guarded_completion(Shell::Fish, "kubectl", "kubectl completion fish | source");
        assert_eq!(
            result,
            "if command -q kubectl\n    kubectl completion fish | source\nend"
        );
    }

    #[test]
    fn guarded_completion_bash_wraps_with_command_v() {
        let result =
            guarded_completion(Shell::Bash, "kubectl", "source <(kubectl completion bash)");
        assert_eq!(
            result,
            "command -v kubectl >/dev/null 2>&1 && source <(kubectl completion bash)"
        );
    }

    #[test]
    fn guarded_completion_zsh_wraps_with_command_v() {
        let result = guarded_completion(Shell::Zsh, "kubectl", "source <(kubectl completion zsh)");
        assert_eq!(
            result,
            "command -v kubectl >/dev/null 2>&1 && source <(kubectl completion zsh)"
        );
    }

    #[test]
    fn guarded_completion_unknown_passes_through() {
        let cmd = "kubectl completion sh";
        let result = guarded_completion(Shell::Unknown, "kubectl", cmd);
        assert_eq!(result, cmd);
    }
}
