use crate::state::State;
use crate::tool::Tool;
use crate::ui::output;
use clap::Args;
use console::style;

#[derive(Debug, Args)]
pub struct OutdatedArgs {}

pub fn run(_args: &OutdatedArgs, state: &State, tools: &[Tool]) -> anyhow::Result<()> {
    struct OutdatedEntry<'a> {
        name: &'a str,
        installed: &'a str,
        latest: String,
        pinned: bool,
    }

    let mut outdated: Vec<OutdatedEntry> = Vec::new();
    let mut checked = 0usize;

    for t in tools {
        let entry = match state.get_entry(&t.id) {
            Some(e) if !e.version.is_empty() => e,
            _ => continue,
        };
        checked += 1;

        let latest = match t.version_source.resolve() {
            Ok(v) => v,
            Err(_) => continue,
        };

        if latest == entry.version {
            continue;
        }

        outdated.push(OutdatedEntry {
            name: &t.name,
            installed: &entry.version,
            latest,
            pinned: entry.pinned,
        });
    }

    if outdated.is_empty() {
        let s = if checked == 1 { "" } else { "s" };
        output::print_section_header(&format!("All {checked} installed tool{s} are up to date."));
        eprintln!();
        return Ok(());
    }

    let s = if outdated.len() == 1 { "" } else { "s" };
    output::print_section_header(&format!(
        "{} tool{s} have updates available",
        outdated.len()
    ));

    let colored = output::get_render_mode() == output::RenderMode::Rich;
    if colored {
        eprintln!(
            "\n{} {} {} {}",
            output::pad_to(&style("Tool").bold().to_string(), 18),
            output::pad_to(&style("Current").bold().to_string(), 14),
            output::pad_to(&style("Latest").bold().to_string(), 14),
            style("Pinned").bold(),
        );
    } else {
        eprintln!("\n{:<18} {:<14} {:<14} Pinned", "Tool", "Current", "Latest");
    }

    for e in &outdated {
        let name_trunc = &e.name[..e.name.len().min(17)];
        let cur_trunc = &e.installed[..e.installed.len().min(13)];
        let lat_trunc = &e.latest[..e.latest.len().min(13)];
        if e.pinned {
            if colored {
                eprintln!(
                    "{name_trunc:<18} {cur_trunc:<14} {lat_trunc:<14} {}",
                    style("~").dim()
                );
            } else {
                eprintln!("{name_trunc:<18} {cur_trunc:<14} {lat_trunc:<14} ~");
            }
        } else {
            eprintln!("{name_trunc:<18} {cur_trunc:<14} {lat_trunc:<14}");
        }
    }

    eprintln!("\nRun 'dot upgrade' to upgrade all (pinned skipped unless --force).\n");
    Ok(())
}
