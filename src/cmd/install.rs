use crate::install::InstallContext;
use crate::platform::{Arch, OperatingSystem, PackageManager, Shell};
use crate::shell as shell_mod;
use crate::state::State;
use crate::tool::Tool;
use crate::ui::output;
use crate::util;
use crate::validate;
use anyhow::Context;
use clap::Args;
use std::path::PathBuf;

#[derive(Debug, Args)]
pub struct InstallArgs {
    /// Tool ID(s) or a group name to install
    pub tools: Vec<String>,
    /// Install all tools in a group
    #[arg(short, long, value_name = "GROUP")]
    pub group: Option<String>,
    /// Specific version to install
    #[arg(short, long, value_name = "VERSION")]
    pub version: Option<String>,
    /// Force reinstall even if already installed / up to date
    #[arg(long)]
    pub force: bool,
    /// Install a named alternate strategy (see `dot info <tool>`), or "default" to
    /// force the primary strategy even if a variant would normally be auto-detected
    #[arg(long, value_name = "NAME")]
    pub variant: Option<String>,
}

pub fn run(args: &InstallArgs, state: &mut State, tools: &[Tool]) -> anyhow::Result<()> {
    let group_flag = args.group.as_deref();
    let force = args.force;
    let version_arg = args.version.as_deref();

    if args.tools.is_empty() && group_flag.is_none() {
        output::print_error("no tool or group specified - usage: dot install <tool|group>");
        return Ok(());
    }

    // Validate version if provided
    if let Some(v) = version_arg {
        if !validate::is_valid_version(v) {
            output::print_error("invalid version string");
            return Ok(());
        }
    }

    // --group always wins, matching the pre-existing precedence
    if let Some(grp_name) = group_flag {
        return install_group(grp_name, force, state, tools);
    }

    // A single bare positional that names "all" or a group is still a group install
    if args.tools.len() == 1 {
        let tool_name = &args.tools[0];
        if tool_name == "all" || super::list::parse_group(tool_name).is_some() {
            return install_group(tool_name, force, state, tools);
        }
    }

    let variant_arg = args.variant.as_deref();
    let total = args.tools.len();
    for (i, tool_name) in args.tools.iter().enumerate() {
        if total > 1 {
            eprintln!("─── [{}/{total}] {} ───", i + 1, tool_name);
        }
        if !validate::is_valid_tool_id(tool_name) {
            output::print_error(&format!("invalid tool name '{tool_name}'"));
            continue;
        }
        if let Err(e) = install_tool(
            tool_name,
            version_arg,
            force,
            false,
            variant_arg,
            state,
            tools,
        ) {
            eprintln!("  Error installing {tool_name}: {e:#}");
        }
    }
    Ok(())
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
            eprintln!("Unknown group '{group_name}'. Valid groups: k8s, cloud, iac, containers, utils, terminal, cm, security, dev, ai");
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
        if let Err(e) = install_tool(t.id.as_str(), None, force, false, None, state, tools) {
            eprintln!("  Error installing {}: {e:#}", t.id);
        }
    }
    Ok(())
}

pub fn run_post_commands(commands: &[String], version: &str) {
    for cmd in commands {
        let rendered = cmd.replace("{version}", version);
        let status = std::process::Command::new("sh")
            .arg("-c")
            .arg(&rendered)
            .status();
        if let Err(e) = status {
            eprintln!("  Warning: post-install command failed to start: {e}");
        } else if let Ok(s) = status {
            if !s.success() {
                eprintln!("  Warning: post-install command exited with {s}");
            }
        }
    }
}

pub fn install_tool(
    id: &str,
    version_arg: Option<&str>,
    force: bool,
    is_upgrade: bool,
    variant_arg: Option<&str>,
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

    // Require a graphical display for GUI tools
    if tool.requires_display && !has_display() {
        output::print_error(&format!(
            "{} requires a graphical display (X11 or Wayland), not available in this environment",
            tool.name
        ));
        return Ok(());
    }

    let (chosen_variant, strategy) = select_variant(tool, variant_arg, state);

    // For system_package tools, prefer the package manager's own candidate version
    // over the upstream GitHub tag - the two are unrelated version schemes, and the
    // GitHub tag is often well ahead of what the distro repo can actually install.
    let is_sys_pkg = matches!(strategy, crate::tool::InstallStrategy::SystemPackage(_));
    let sys_pkg_name: Option<(PackageManager, String)> = if is_sys_pkg {
        if let crate::tool::InstallStrategy::SystemPackage(s) = strategy {
            let pm = PackageManager::detect();
            s.package_for(pm).map(|p| (pm, p.to_string()))
        } else {
            None
        }
    } else {
        None
    };

    let resolve_upstream_version = || match tool.version_source.resolve() {
        Ok(v) => v,
        Err(_) => {
            eprintln!("Warning: could not fetch version (VersionFetchFailed), using 'latest'");
            "latest".to_string()
        }
    };

    // Resolve version
    let version = if let Some(v) = version_arg {
        v.to_string()
    } else if let Some((pm, pkg)) = &sys_pkg_name {
        pm.candidate_version(pkg)
            .unwrap_or_else(resolve_upstream_version)
    } else {
        resolve_upstream_version()
    };

    // Skip pinned unless forced
    if !force && version_arg.is_none() && state.is_pinned(&tool.id) {
        let pinned_ver = state.get_version(&tool.id).unwrap_or("pinned");
        eprintln!(
            "  ~ {} {} is pinned at {pinned_ver} - skipping",
            tool.name, tool.id
        );
        eprintln!("  To upgrade anyway: dot install {} --force", tool.id);
        return Ok(());
    }

    // Check for system install conflict. For system_package tools, only warn if
    // the package manager doesn't already own this package - if it does, whatever
    // is on PATH is presumably that very package (dot just hasn't adopted it into
    // its own state yet), not a real shadow conflict.
    let already_pkg_installed = sys_pkg_name
        .as_ref()
        .map(|(pm, pkg)| pm.installed_version(pkg).is_some())
        .unwrap_or(false);
    if !force && !state.is_installed(&tool.id) && !already_pkg_installed {
        if let Some(sys_path) = check_system_install(&tool.id) {
            if is_sys_pkg {
                eprintln!(
                    "  Warning: {} on PATH currently resolves to {}, not a system package location.",
                    tool.id,
                    sys_path.display()
                );
                eprintln!(
                    "  Installing {} via apt will not change what '{}' runs - that other binary will keep shadowing it.",
                    tool.name, tool.id
                );
            } else {
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

        let install_result = strategy.execute(&ctx);
        let _ = std::fs::remove_dir_all(&tmp_dir);

        if let Err(e) = install_result {
            output::print_step("Installation", true, &e.to_string());
            return Err(anyhow::anyhow!("Installation failed"));
        }

        if !is_sys_pkg {
            eprintln!("  {}", bin_dir.join(&tool.id).display());
        }
    }

    // Update state - for system_package tools, record what the package manager
    // actually installed rather than the (possibly unrelated) candidate/GitHub
    // version, falling back to `version` only if that query fails.
    let recorded_version = match &sys_pkg_name {
        Some((pm, pkg)) => pm.installed_version(pkg).unwrap_or_else(|| version.clone()),
        None => version.clone(),
    };
    let method = if used_brew {
        "brew"
    } else {
        strategy.method_name()
    };
    state.add_tool(&tool.id, &recorded_version, method, false)?;
    state.set_variant(&tool.id, chosen_variant.as_deref())?;
    state.save()?;

    // Shell integration
    write_shell_integration(tool, true);

    // Post-install / post-upgrade hooks
    let post_cmds = if is_upgrade {
        &tool.post_upgrade
    } else {
        &tool.post_install
    };
    if !post_cmds.is_empty() {
        output::print_step_start("Post", if is_upgrade { "upgrade" } else { "install" });
        run_post_commands(post_cmds, &version);
    }

    Ok(())
}

pub fn write_shell_integration(tool: &Tool, print_step: bool) -> bool {
    let shell = Shell::detect();
    if shell == Shell::Unknown {
        return false;
    }
    write_shell_integration_for(tool, shell);
    if print_step {
        output::print_step_start("Shell", shell.name());
    }
    true
}

pub fn write_shell_integration_for(tool: &Tool, shell: Shell) {
    let section = build_shell_section(tool, shell);
    if let Some(content) = section {
        let _ = shell_mod::ensure_sourced(shell);
        let _ = shell_mod::add_section(shell, &tool.id, &content);
    } else {
        let _ = shell_mod::remove_section(shell, &tool.id);
    }
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

    for dir in &tool.shell_path_dirs {
        parts.push(shell.path_add_syntax(dir));
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
                // compdef only exists after compinit has run
                Some(format!(
                    "command -v compdef >/dev/null 2>&1 && compdef {alias_name}={}",
                    tool.id
                ))
            }
            Shell::Bash
                if tool
                    .shell_completions
                    .as_ref()
                    .and_then(|c| c.bash_cmd.as_ref())
                    .is_some() =>
            {
                // Re-register the tool's completion spec with the alias appended;
                // bash does not complete through aliases on its own
                Some(format!(
                    "complete -p {id} >/dev/null 2>&1 && eval \"$(complete -p {id}) {alias_name}\"",
                    id = tool.id
                ))
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
        Shell::Bash => format!("command -v {id} >/dev/null 2>&1 && {cmd}"),
        // Completion scripts call compdef, which only exists after compinit
        Shell::Zsh => format!(
            "command -v compdef >/dev/null 2>&1 && command -v {id} >/dev/null 2>&1 && {cmd}"
        ),
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

/// Checks for a pre-existing binary that `dot` doesn't yet know about. The only
/// caller gates this on `!state.is_installed(id)`, so a match here - even at the
/// path `dot` would itself install to - can never be `dot`'s own prior install; it
/// must be something else (a manual install, another tool's installer, etc.).
fn check_system_install(id: &str) -> Option<PathBuf> {
    let found = util::find_in_path(id)?;
    Some(std::path::PathBuf::from(&found))
}

fn has_display() -> bool {
    std::env::var_os("DISPLAY").is_some() || std::env::var_os("WAYLAND_DISPLAY").is_some()
}

/// Picks which install strategy applies for this run: an explicit `--variant` flag
/// wins outright; otherwise an already-tracked tool stays on whatever variant it
/// last used (so upgrades never silently switch strategies); otherwise, on a fresh
/// install, each variant's `auto_detect` condition gets a chance to opt in, falling
/// back to the tool's primary strategy (optionally printing a variant's `hint` first
/// if its broader `context_detect` condition matched but `auto_detect` didn't).
fn select_variant<'a>(
    tool: &'a Tool,
    variant_arg: Option<&str>,
    state: &mut State,
) -> (Option<String>, &'a crate::tool::InstallStrategy) {
    if let Some(name) = variant_arg {
        if name == "default" || name == "primary" {
            return (None, &tool.strategy);
        }
        if let Some(v) = tool.variants.get(name) {
            return (Some(name.to_string()), &v.strategy);
        }
        let known: Vec<&str> = tool.variants.keys().map(|s| s.as_str()).collect();
        eprintln!(
            "  Warning: {} has no variant '{name}' - using the primary strategy. Known variants: {}",
            tool.id,
            if known.is_empty() {
                "(none)".to_string()
            } else {
                known.join(", ")
            }
        );
        return (None, &tool.strategy);
    }

    if state.is_installed(&tool.id) {
        let recorded = state.get_variant(&tool.id).map(|s| s.to_string());
        if let Some(name) = &recorded {
            if let Some(v) = tool.variants.get(name.as_str()) {
                return (Some(name.clone()), &v.strategy);
            }
            // Stale variant name no longer defined on this tool - fall back to
            // the primary strategy below.
        } else if !state.variant_hint_shown(&tool.id) {
            // Sticky on the primary strategy. If a variant's auto_detect now
            // matches this environment, surface a one-time hint instead of
            // silently switching strategies out from under an existing install.
            for (name, v) in &tool.variants {
                if let Some(cond) = &v.auto_detect {
                    if shell_condition_true(cond) {
                        eprintln!(
                            "  Note: a '{name}' variant of {} matches your environment, but this install is still using the primary strategy (from before variants existed, or a deliberate choice). Switch anytime with: dot install {} --variant {name} --force",
                            tool.name, tool.id
                        );
                        let _ = state.mark_variant_hint_shown(&tool.id);
                        break;
                    }
                }
            }
        }
        return (None, &tool.strategy);
    }

    for (name, v) in &tool.variants {
        if let Some(cond) = &v.auto_detect {
            if shell_condition_true(cond) {
                eprintln!(
                    "  Detected a matching environment for '{name}' - installing that variant of {} instead of the default.",
                    tool.name
                );
                return (Some(name.clone()), &v.strategy);
            }
        }
    }
    for v in tool.variants.values() {
        if let Some(cond) = &v.context_detect {
            if shell_condition_true(cond) {
                if let Some(hint) = &v.hint {
                    eprintln!("  {hint}");
                }
                break;
            }
        }
    }
    (None, &tool.strategy)
}

fn shell_condition_true(cmd: &str) -> bool {
    std::process::Command::new("sh")
        .args(["-c", cmd])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
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
            "command -v compdef >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1 && source <(kubectl completion zsh)"
        );
    }

    #[test]
    fn guarded_completion_unknown_passes_through() {
        let cmd = "kubectl completion sh";
        let result = guarded_completion(Shell::Unknown, "kubectl", cmd);
        assert_eq!(result, cmd);
    }

    fn kubectl_tool() -> Tool {
        serde_json::from_str(
            r#"{
                "id": "kubectl",
                "name": "kubectl",
                "groups": ["k8s"],
                "aliases": ["k"],
                "version_source": {"type": "k8s_stable_txt"},
                "strategy": {"type": "direct_binary", "url_template": "https://example.com/kubectl"},
                "shell_completions": {
                    "bash_cmd": "source <(kubectl completion bash)",
                    "zsh_cmd": "source <(kubectl completion zsh)",
                    "fish_cmd": "kubectl completion fish | source"
                }
            }"#,
        )
        .unwrap()
    }

    #[test]
    fn shell_section_bash_delegates_alias_completion() {
        let section = build_shell_section(&kubectl_tool(), Shell::Bash).unwrap();
        assert!(section.contains("alias k=kubectl"));
        assert!(section
            .contains("complete -p kubectl >/dev/null 2>&1 && eval \"$(complete -p kubectl) k\""));
    }

    #[test]
    fn shell_section_zsh_guards_compdef() {
        let section = build_shell_section(&kubectl_tool(), Shell::Zsh).unwrap();
        assert!(section.contains("alias k=kubectl"));
        assert!(section.contains("command -v compdef >/dev/null 2>&1 && compdef k=kubectl"));
    }

    #[test]
    fn shell_section_fish_wraps_alias() {
        let section = build_shell_section(&kubectl_tool(), Shell::Fish).unwrap();
        assert!(section.contains("alias k=kubectl"));
        assert!(section.contains("complete -c k -w kubectl"));
    }

    #[test]
    fn shell_section_no_bash_delegation_without_completions() {
        let mut tool = kubectl_tool();
        tool.shell_completions = None;
        let section = build_shell_section(&tool, Shell::Bash).unwrap();
        assert!(section.contains("alias k=kubectl"));
        assert!(!section.contains("complete -p"));
    }
}
