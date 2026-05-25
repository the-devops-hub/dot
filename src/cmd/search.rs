use crate::tool::Tool;
use crate::ui::output;
use crate::util::edit_distance;
use clap::Args;

#[derive(Debug, Args)]
pub struct SearchArgs {
    /// Search query
    pub query: Option<String>,
}

const RANK4_DISTANCE: usize = 1;
const SUGGESTION_DISTANCE: usize = 3;

pub fn run(args: &SearchArgs, tools: &[Tool]) -> anyhow::Result<()> {
    let query = match &args.query {
        Some(q) => q.as_str(),
        None => {
            output::print_error("no query specified — usage: dot search <query>");
            return Ok(());
        }
    };
    let q = query.to_lowercase();

    let mut ranked: Vec<(u8, &Tool)> = tools
        .iter()
        .filter_map(|t| {
            let r = rank(t, &q);
            if r < 255 {
                Some((r, t))
            } else {
                None
            }
        })
        .collect();
    ranked.sort_by_key(|(r, t)| (*r, t.id.as_str()));

    if ranked.is_empty() {
        // Find closest by edit distance for suggestion
        let mut best_dist = usize::MAX;
        let mut best: Option<&Tool> = None;
        for t in tools {
            let d = edit_distance(query, &t.id);
            if d < best_dist {
                best_dist = d;
                best = Some(t);
            }
        }
        if best_dist <= SUGGESTION_DISTANCE {
            if let Some(b) = best {
                output::print_section_header(&format!(
                    "No exact match for \"{query}\". Did you mean:"
                ));
                let label = format_label(b);
                let label_trunc = &label[..label.len().min(14)];
                eprintln!("\n  {label_trunc:<14}  {}\n", b.description);
            }
        } else {
            output::print_section_header(&format!("No tools match \"{query}\""));
            eprintln!("\nRun 'dot list' to see all available tools.\n");
        }
        return Ok(());
    }

    output::print_section_header(&format!("Results for \"{query}\" ({})", ranked.len()));

    let colored = output::get_render_mode() == output::RenderMode::Rich;
    if colored {
        use console::style;
        eprintln!(
            "\n{} {} {}",
            output::pad_to(&style("Tool").bold().to_string(), 18),
            output::pad_to(&style("Groups").bold().to_string(), 10),
            style("Description").bold(),
        );
    } else {
        eprintln!("\n{:<18} {:<10} Description", "Tool", "Groups");
    }

    for (_, t) in &ranked {
        let label = format_label(t);
        let label_trunc = &label[..label.len().min(17)];
        let grp = format_groups(t);
        let grp_trunc = &grp[..grp.len().min(9)];
        let desc_max = 50;
        let desc = &t.description;
        let desc_trunc = &desc[..desc.len().min(desc_max)];
        if desc.len() > desc_max {
            eprintln!("{label_trunc:<18} {grp_trunc:<10} {desc_trunc}…");
        } else {
            eprintln!("{label_trunc:<18} {grp_trunc:<10} {desc_trunc}");
        }
    }
    eprintln!();
    Ok(())
}

fn rank(t: &Tool, q: &str) -> u8 {
    if t.id == q {
        return 0;
    }
    if t.aliases.iter().any(|a| a == q) {
        return 0;
    }
    if t.id.starts_with(q) {
        return 1;
    }
    if t.aliases.iter().any(|a| a.starts_with(q)) {
        return 1;
    }
    if contains_ignore_case(&t.id, q) {
        return 2;
    }
    if t.aliases.iter().any(|a| contains_ignore_case(a, q)) {
        return 2;
    }
    if t.groups.iter().any(|g| g.name() == q) {
        return 3;
    }
    if contains_ignore_case(&t.description, q) {
        return 4;
    }
    if edit_distance(&t.id, q) <= RANK4_DISTANCE {
        return 5;
    }
    255
}

fn contains_ignore_case(haystack: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return true;
    }
    let h = haystack.to_lowercase();
    let n = needle.to_lowercase();
    h.contains(&n)
}

fn format_label(t: &Tool) -> String {
    if t.aliases.is_empty() {
        t.id.clone()
    } else {
        format!("{} ({})", t.id, t.aliases.join(","))
    }
}

fn format_groups(t: &Tool) -> String {
    t.groups
        .iter()
        .map(|g| g.name())
        .collect::<Vec<_>>()
        .join(",")
}
