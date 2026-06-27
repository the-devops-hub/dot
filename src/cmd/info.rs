use crate::state::State;
use crate::tool::Tool;
use crate::ui::output;
use clap::Args;
use console::style;

#[derive(Debug, Args)]
pub struct InfoArgs {
    /// Tool ID to show info for
    pub tool: String,
}

pub fn run(args: &InfoArgs, state: &State, tools: &[Tool]) -> anyhow::Result<()> {
    let query = &args.tool;

    // Find by id or alias
    let found = tools
        .iter()
        .find(|t| t.id == query.as_str() || t.aliases.iter().any(|a| a == query));

    let t = match found {
        Some(t) => t,
        None => {
            output::print_unknown_tool(query);
            // Suggest closest
            if let Some(suggestion) = closest_tool(query, tools) {
                eprintln!("Did you mean '{suggestion}'?");
            }
            return Ok(());
        }
    };

    let colored = output::get_render_mode() == output::RenderMode::Rich;
    let bold_label = |s: &str| -> String {
        if colored {
            style(s).bold().to_string()
        } else {
            s.to_string()
        }
    };

    // Header: "Name - Description" (or just "Name" if no description)
    if t.description.is_empty() {
        output::print_section_header(&t.name);
    } else {
        output::print_section_header(&format!("{} - {}", t.name, t.description));
    }
    eprintln!();
    if !t.homepage.is_empty() {
        eprintln!("  {}     {}", bold_label("Homepage:"), t.homepage);
    }

    let groups_str = t
        .groups
        .iter()
        .map(|g| g.name())
        .collect::<Vec<_>>()
        .join(", ");
    if !groups_str.is_empty() {
        eprintln!("  {}       {groups_str}", bold_label("Groups:"));
    }

    if !t.aliases.is_empty() {
        eprintln!("  {}      {}", bold_label("Aliases:"), t.aliases.join(", "));
    }

    // Status section
    output::print_section_header("Status");
    eprintln!();

    let entry = state.get_entry(&t.id);
    if let Some(e) = entry {
        let home = dirs::home_dir().unwrap_or_default();
        let bin_path = home.join(".local/bin").join(&t.id);

        let version_str = if colored {
            style(&e.version).green().to_string()
        } else {
            e.version.clone()
        };
        eprintln!("  {}    {version_str}", bold_label("Installed:"));
        eprintln!("  {}       {}", bold_label("Binary:"), bin_path.display());

        if !e.installed_at.is_empty() {
            let date = output::fmt_timestamp(&e.installed_at);
            eprintln!("  {} {date}", bold_label("Installed at:"));
        }
        eprintln!("  {}       {}", bold_label("Method:"), e.method);
        eprintln!(
            "  {}       {}",
            bold_label("Pinned:"),
            if e.pinned { "yes" } else { "no" }
        );

        // Resolve latest version (non-fatal)
        if let Ok(latest) = t.version_source.resolve() {
            if latest == e.version {
                let up_str = if colored {
                    style("up to date").green().to_string()
                } else {
                    "up to date".to_string()
                };
                eprintln!("  {}       {up_str}", bold_label("Latest:"));
            } else {
                let avail_str = if colored {
                    format!("{latest} {}", style("(update available)").yellow())
                } else {
                    format!("{latest} (update available)")
                };
                eprintln!("  {}       {avail_str}", bold_label("Latest:"));
            }
        }
    } else {
        eprintln!("  not installed");
        eprintln!("\n  Run 'dot install {}'  to install.", t.id);
    }

    // Quick start
    if !t.quick_start.is_empty() {
        output::print_section_header("Quick Start");
        eprintln!();
        for line in &t.quick_start {
            eprintln!("  {line}");
        }
    }

    // Resources
    if !t.resources.is_empty() {
        output::print_section_header("Resources");
        eprintln!();
        for r in &t.resources {
            let label_str = if colored {
                style(&r.label).bold().to_string()
            } else {
                r.label.clone()
            };
            eprintln!("  {label_str}: {}", r.url);
        }
    }

    eprintln!();
    Ok(())
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
