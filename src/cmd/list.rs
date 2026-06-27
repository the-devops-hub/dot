use crate::state::State;
use crate::tool::{Group, Tool};
use crate::ui::output;
use clap::Args;
use console::style;

#[derive(Debug, Args)]
pub struct ListArgs {
    /// Filter by group name
    #[arg(short, long, value_name = "GROUP")]
    pub group: Option<String>,
    /// Show only installed tools
    #[arg(short, long)]
    pub installed: bool,
    /// Show only pinned tools
    #[arg(long)]
    pub pinned: bool,
    /// Show version/installed/method detail columns
    #[arg(short = 'l', long)]
    pub details: bool,
}

const COL_ID: usize = 16;
const COL_STATUS: usize = 14;
const COL_GROUPS: usize = 16;
// id(16) + sp(1) + status(14) + sp(1) + groups(16) + sp(1) = 49
const OVERHEAD: usize = 49;
const DESC_MIN: usize = 10;

pub fn run(args: &ListArgs, state: &State, tools: &[Tool]) -> anyhow::Result<()> {
    let group_filter: Option<Group> = match &args.group {
        Some(g) => {
            let parsed = parse_group(g);
            if parsed.is_none() {
                eprintln!("Unknown group '{g}'. Valid groups: k8s, cloud, iac, containers, utils, terminal, cm, security, dev");
                return Ok(());
            }
            parsed
        }
        None => None,
    };

    let installed_only = args.installed || args.pinned || args.details;
    let pinned_only = args.pinned;
    let details_mode = args.details;

    let term_width = output::terminal_width();
    let desc_width = if term_width > OVERHEAD {
        term_width - OVERHEAD
    } else {
        DESC_MIN
    };

    let home = dirs::home_dir().unwrap_or_default();
    let bin_dir = home.join(".local/bin");

    let colored = output::get_render_mode() == output::RenderMode::Rich;

    // Collect and filter
    let mut matched: Vec<&Tool> = tools
        .iter()
        .filter(|t| {
            if let Some(ref gf) = group_filter {
                if !t.groups.contains(gf) {
                    return false;
                }
            }
            if installed_only && !state.is_installed(&t.id) {
                return false;
            }
            if pinned_only && !state.is_pinned(&t.id) {
                return false;
            }
            true
        })
        .collect();

    // Sort: first group tag name (alphabetical), then tool name (case-insensitive)
    matched.sort_by(|a, b| {
        let ga = a.groups.first().map(|g| g.name()).unwrap_or("");
        let gb = b.groups.first().map(|g| g.name()).unwrap_or("");
        ga.cmp(gb)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    if details_mode {
        output::print_section_header("Installed Tools");
        if colored {
            eprintln!(
                "\n{} {} {} {} {}",
                output::pad_to(&style("Tool").bold().to_string(), 16),
                output::pad_to(&style("Version").bold().to_string(), 14),
                output::pad_to(&style("Installed At").bold().to_string(), 24),
                output::pad_to(&style("Method").bold().to_string(), 18),
                style("Pinned").bold(),
            );
        } else {
            eprintln!(
                "\n{:<16} {:<14} {:<24} {:<18} Pinned",
                "Tool", "Version", "Installed At", "Method"
            );
        }
        for t in &matched {
            let entry = match state.get_entry(&t.id) {
                Some(e) => e,
                None => continue,
            };
            let version = &entry.version;
            let installed_at = output::fmt_timestamp(&entry.installed_at);
            let method = &entry.method;
            let pin_str = if entry.pinned { "~" } else { "" };
            eprintln!(
                "{:<16} {:<14} {:<24} {:<18} {}",
                t.id, version, installed_at, method, pin_str
            );
        }
    } else {
        output::print_section_header("Available Tools");
        if colored {
            eprintln!(
                "\n{} {} {} {}",
                output::pad_to(&style("Tool").bold().to_string(), 16),
                output::pad_to(&style("Status").bold().to_string(), 14),
                output::pad_to(&style("Groups").bold().to_string(), 16),
                style("Description").bold(),
            );
        } else {
            eprintln!(
                "\n{:<16} {:<14} {:<16} Description",
                "Tool", "Status", "Groups"
            );
        }

        for t in &matched {
            let is_installed = state.is_installed(&t.id);
            let is_pinned = state.is_pinned(&t.id);
            let version = state.get_version(&t.id);

            // Detect system-installed (in PATH but outside ~/.local/bin) and unmanaged local
            let is_sys = if version.is_none() {
                is_system_installed(&t.id)
            } else {
                false
            };
            let is_unmanaged = if version.is_none() && !is_sys {
                bin_dir.join(&t.id).exists()
            } else {
                false
            };

            // Build id column with optional dim alias
            print_id_col(&t.id, &t.aliases, colored);

            // Build status column with manual visual-width padding
            print_status_col(
                version,
                is_installed,
                is_pinned,
                is_sys,
                is_unmanaged,
                colored,
            );

            // Groups column
            let groups_str: String = t
                .groups
                .iter()
                .map(|g| g.name())
                .collect::<Vec<_>>()
                .join(",");
            let g_trunc = &groups_str[..groups_str.len().min(COL_GROUPS)];
            eprint!("{g_trunc:<16} ");

            // Description - truncate to fit terminal, break at word boundary
            let desc_trunc = truncate_desc(&t.description, desc_width);
            eprintln!("{desc_trunc}");
        }
    }

    let filter_name = group_filter.as_ref().map(|g| g.name());
    print_footer(matched.len(), filter_name);

    Ok(())
}

fn is_system_installed(id: &str) -> bool {
    if let Some(found) = crate::util::find_in_path(id) {
        !found.contains(".local/bin")
    } else {
        false
    }
}

fn print_id_col(id: &str, aliases: &[String], colored: bool) {
    let id_trunc = &id[..id.len().min(COL_ID)];
    if aliases.is_empty() {
        eprint!("{id_trunc:<16} ");
    } else {
        let alias_str = format!("({})", aliases.join(","));
        let visual = id_trunc.len() + 1 + alias_str.len();
        let pad = (COL_ID + 1).saturating_sub(visual);
        if colored {
            eprint!("{id_trunc} {}{}", style(&alias_str).dim(), " ".repeat(pad));
        } else {
            eprint!("{id_trunc} {alias_str}{}", " ".repeat(pad));
        }
    }
}

fn print_status_col(
    version: Option<&str>,
    _is_installed: bool,
    is_pinned: bool,
    is_sys: bool,
    is_unmanaged: bool,
    colored: bool,
) {
    if let Some(v) = version {
        let v_trunc = &v[..v.len().min(12)];
        let pin_mark = if is_pinned { " ~" } else { "" };
        // visual: sym_ok(1 rich / 2 plain) + space(1) + version + pin_mark
        let (sym_w, sym_s) = if colored {
            (1usize, "✓")
        } else {
            (2usize, "ok")
        };
        let text_visual = sym_w + 1 + v_trunc.len() + pin_mark.len();
        let pad = COL_STATUS.saturating_sub(text_visual);
        if colored {
            eprint!(
                "{} {v_trunc}{pin_mark}{} ",
                style(sym_s).green(),
                " ".repeat(pad)
            );
        } else {
            eprint!("{sym_s} {v_trunc}{pin_mark}{} ", " ".repeat(pad));
        }
    } else if is_sys {
        // visual: sym_warn(1/4) + space(1) + "system"(6)
        let (sym_w, sym_s) = if colored {
            (1usize, "⚠")
        } else {
            (4usize, "WARN")
        };
        let text_visual = sym_w + 1 + "system".len();
        let pad = COL_STATUS.saturating_sub(text_visual);
        if colored {
            eprint!("{} system{} ", style(sym_s).yellow(), " ".repeat(pad));
        } else {
            eprint!("{sym_s} system{} ", " ".repeat(pad));
        }
    } else if is_unmanaged {
        // "~ local" = 7 visual; 14 - 7 = 7 padding + 1 sep = 8 spaces
        if colored {
            eprint!("{}        ", style("~ local").dim());
        } else {
            eprint!("~ local        ");
        }
    } else {
        // "not installed" = 13 visual; 14 - 13 = 1 padding + 1 sep = 2 spaces
        if colored {
            eprint!("{}  ", style("not installed").dim());
        } else {
            eprint!("not installed  ");
        }
    }
}

fn truncate_desc(desc: &str, max_visual: usize) -> String {
    if desc.len() <= max_visual {
        return desc.to_string();
    }
    // Walk back to find a word boundary
    let mut end = max_visual.saturating_sub(1);
    while end > 0 && !desc.is_char_boundary(end) {
        end -= 1;
    }
    let cut = if end > 0 {
        let mut space_pos = end;
        while space_pos > 0 && !desc.as_bytes()[space_pos].is_ascii_whitespace() {
            space_pos -= 1;
        }
        if space_pos == 0 {
            end
        } else {
            space_pos
        }
    } else {
        end
    };
    format!("{}…", &desc[..cut])
}

fn print_footer(count: usize, group_filter: Option<&str>) {
    eprint!("\n{count} tools total");
    if let Some(g) = group_filter {
        eprint!(" (filtered by group '{g}')");
    }
    eprintln!("\n");
}

pub fn parse_group(name: &str) -> Option<Group> {
    match name {
        "k8s" => Some(Group::K8s),
        "cloud" => Some(Group::Cloud),
        "iac" => Some(Group::Iac),
        "containers" => Some(Group::Containers),
        "utils" => Some(Group::Utils),
        "terminal" => Some(Group::Terminal),
        "cm" => Some(Group::Cm),
        "security" => Some(Group::Security),
        "dev" => Some(Group::Dev),
        "ai" => Some(Group::Ai),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_desc_fits_within_max() {
        assert_eq!(truncate_desc("hello world", 20), "hello world");
    }

    #[test]
    fn truncate_desc_exact_length_not_truncated() {
        assert_eq!(truncate_desc("hello world", 11), "hello world");
    }

    #[test]
    fn truncate_desc_breaks_at_word_boundary() {
        // "hello world foo" - last space before index 10 is at 5
        assert_eq!(truncate_desc("hello world foo", 10), "hello…");
    }

    #[test]
    fn truncate_desc_hard_cuts_when_no_space() {
        // no spaces in "abcdefghij", cuts at char boundary
        assert_eq!(truncate_desc("abcdefghij", 6), "abcde…");
    }
}
