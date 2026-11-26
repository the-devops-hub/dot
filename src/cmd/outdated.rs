use crate::platform::PackageManager;
use crate::state::{State, ToolEntry};
use crate::tool::{InstallStrategy, Tool};
use crate::ui::output;
use clap::Args;
use console::style;

/// For system_package tools, compare against the package manager's own candidate
/// version instead of the upstream GitHub tag - the two are unrelated version
/// schemes, and the tag is often well ahead of what the distro repo can install.
/// Uses whichever variant (see `Tool::variants`) the tool was actually installed
/// under, so this matches what `dot upgrade` would actually do.
fn resolve_latest(tool: &Tool, state: &State) -> Option<String> {
    let strategy = match state
        .get_variant(&tool.id)
        .and_then(|n| tool.variants.get(n))
    {
        Some(v) => &v.strategy,
        None => &tool.strategy,
    };
    if let InstallStrategy::SystemPackage(s) = strategy {
        let pm = PackageManager::detect();
        if let Some(pkg) = s.package_for(pm) {
            if let Some(v) = pm.candidate_version(pkg) {
                return Some(v);
            }
        }
    }
    tool.version_source.resolve().ok()
}

/// Maximum concurrent version checks: enough to hide latency without hammering
/// the GitHub API (unauthenticated requests are rate limited).
const MAX_WORKERS: usize = 8;

/// Map `f` over `items` on up to `MAX_WORKERS` threads, returning results in the
/// original order.
fn parallel_map<T: Sync, R: Send>(items: &[T], f: impl Fn(&T) -> R + Sync) -> Vec<R> {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Mutex;

    let next = AtomicUsize::new(0);
    let results: Mutex<Vec<Option<R>>> = Mutex::new((0..items.len()).map(|_| None).collect());
    std::thread::scope(|scope| {
        for _ in 0..MAX_WORKERS.min(items.len()) {
            scope.spawn(|| loop {
                let i = next.fetch_add(1, Ordering::Relaxed);
                let Some(item) = items.get(i) else { break };
                let r = f(item);
                results.lock().unwrap()[i] = Some(r);
            });
        }
    });
    results
        .into_inner()
        .unwrap()
        .into_iter()
        .map(|r| r.expect("every item is processed"))
        .collect()
}

#[derive(Debug, Args)]
pub struct OutdatedArgs {}

pub fn run(_args: &OutdatedArgs, state: &State, tools: &[Tool]) -> anyhow::Result<()> {
    struct OutdatedEntry<'a> {
        name: &'a str,
        installed: String,
        latest: String,
        pinned: bool,
    }

    // Installed tools only; the version command and the upstream lookup for each one
    // are slow (a subprocess and a network call), so they run on a small worker pool.
    let installed_tools: Vec<(&Tool, &ToolEntry)> = tools
        .iter()
        .filter_map(|t| match state.get_entry(&t.id) {
            Some(e) if !e.version.is_empty() => Some((t, e)),
            _ => None,
        })
        .collect();
    let checked = installed_tools.len();
    let checks = parallel_map(&installed_tools, |(t, entry)| {
        let installed = t
            .installed_version(Some(&entry.version))
            .unwrap_or_else(|| entry.version.clone());
        let latest = resolve_latest(t, state);
        (installed, latest)
    });

    let mut outdated: Vec<OutdatedEntry> = Vec::new();
    for ((t, entry), (installed, latest)) in installed_tools.iter().zip(checks) {
        let Some(latest) = latest else { continue };
        if latest == installed {
            continue;
        }
        outdated.push(OutdatedEntry {
            name: &t.name,
            installed,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parallel_map_keeps_order_and_runs_concurrently() {
        let items: Vec<u64> = (0..20).collect();
        let start = std::time::Instant::now();
        let out = parallel_map(&items, |n| {
            std::thread::sleep(std::time::Duration::from_millis(100));
            n * 2
        });
        assert_eq!(out, (0..20).map(|n| n * 2).collect::<Vec<_>>());
        // 20 x 100ms sequentially is 2s; with 8 workers it is about 300ms.
        assert!(start.elapsed() < std::time::Duration::from_millis(1200));
    }

    #[test]
    fn parallel_map_handles_empty_input() {
        let out: Vec<u8> = parallel_map(&Vec::<u8>::new(), |n| *n);
        assert!(out.is_empty());
    }
}
