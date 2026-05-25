use crate::state::State;
use crate::tool::Tool;
use crate::ui::output;
use clap::Args;
use std::time::Instant;

#[derive(Debug, Args)]
pub struct UpgradeArgs {
    /// Tool ID or group to upgrade (upgrades all if omitted)
    pub target: Option<String>,
    /// Force upgrade even for pinned tools
    #[arg(long)]
    pub force: bool,
}

pub fn run(args: &UpgradeArgs, state: &mut State, tools: &[Tool]) -> anyhow::Result<()> {
    let force = args.force;

    if let Some(ref target) = args.target {
        // Group upgrade
        if let Some(group) = super::list::parse_group(target) {
            let candidates: Vec<&Tool> = tools
                .iter()
                .filter(|t| t.groups.contains(&group) && state.is_installed(&t.id))
                .collect();
            if candidates.is_empty() {
                return Ok(());
            }
            let n = candidates.len();
            let s = if n == 1 { "" } else { "s" };
            output::print_section_header(&format!(
                "Upgrading group '{target}' ({n} installed tool{s})"
            ));
            run_batch(&candidates, force, state, tools);
            return Ok(());
        }

        // Single tool upgrade
        if !tools.iter().any(|t| t.id == target.as_str()) {
            output::print_unknown_tool(target);
            return Ok(());
        }
        super::install::install_tool(target, None, force, state, tools)?;
        return Ok(());
    }

    // Upgrade all installed tools
    let candidates: Vec<&Tool> = tools.iter().filter(|t| state.is_installed(&t.id)).collect();

    if candidates.is_empty() {
        eprintln!("No installed tools found.");
        return Ok(());
    }

    let n = candidates.len();
    let s = if n == 1 { "" } else { "s" };
    output::print_section_header(&format!("Upgrading {n} installed tool{s}"));
    run_batch(&candidates, force, state, tools);
    Ok(())
}

fn run_batch(candidates: &[&Tool], force: bool, state: &mut State, tools: &[Tool]) {
    let total = candidates.len();
    let start = Instant::now();
    let mut upgraded = 0usize;
    let mut already_current = 0usize;
    let mut failed = 0usize;

    for (i, t) in candidates.iter().enumerate() {
        output::print_section_header(&format!("{} ({}/{})", t.name, i + 1, total));

        // Snapshot version before to detect real upgrade vs already-current
        let before = state.get_version(&t.id).map(|v| v.to_string());

        match super::install::install_tool(&t.id, None, force, state, tools) {
            Ok(_) => {
                let after = state.get_version(&t.id).map(|v| v.to_string());
                let changed = match (&before, &after) {
                    (Some(b), Some(a)) => b != a,
                    (None, Some(_)) => true,
                    _ => false,
                };
                if changed {
                    upgraded += 1;
                } else {
                    already_current += 1;
                }
            }
            Err(_) => {
                // Error details already printed by install_tool
                eprintln!("Failed to upgrade {}: CommandFailed", t.id);
                failed += 1;
            }
        }
    }

    let elapsed = start.elapsed().as_millis() as u64;
    output::print_summary(upgraded, already_current, failed, elapsed);
}
