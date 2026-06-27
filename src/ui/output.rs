use console::Term;
use std::sync::OnceLock;

// ─── Render mode ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RenderMode {
    Rich,
    Plain,
    Pipe,
    Silent,
}

static RENDER_MODE: OnceLock<RenderMode> = OnceLock::new();

pub fn init_caps() {
    let mode = detect_mode();
    let _ = RENDER_MODE.set(mode);
}

fn detect_mode() -> RenderMode {
    let no_color = std::env::var("NO_COLOR").is_ok();
    let dumb_term = std::env::var("TERM").map(|t| t == "dumb").unwrap_or(false);
    let is_tty = Term::stderr().is_term();
    if !is_tty {
        RenderMode::Pipe
    } else if no_color || dumb_term {
        RenderMode::Plain
    } else {
        RenderMode::Rich
    }
}

pub fn get_render_mode() -> RenderMode {
    *RENDER_MODE.get().unwrap_or(&RenderMode::Rich)
}

fn is_rich() -> bool {
    get_render_mode() == RenderMode::Rich
}

fn is_silent() -> bool {
    get_render_mode() == RenderMode::Silent
}

fn colored() -> bool {
    get_render_mode() == RenderMode::Rich
}

// ─── Symbols ─────────────────────────────────────────────────────────────────

fn sym_fail() -> &'static str {
    if is_rich() {
        "✗"
    } else {
        "FAIL"
    }
}
fn sym_arrow() -> &'static str {
    if is_rich() {
        "→"
    } else {
        "->"
    }
}
// ─── ANSI helpers ─────────────────────────────────────────────────────────────

use console::style;

// ─── Common print functions ───────────────────────────────────────────────────

pub fn print_error(msg: &str) {
    if is_silent() {
        return;
    }
    if colored() {
        eprintln!(
            "\n{} {} {msg}\n",
            style(sym_fail()).red().bold(),
            style("Error:").bold()
        );
    } else {
        eprintln!("\n{} Error: {msg}\n", sym_fail());
    }
}

pub fn print_unknown_tool(id: &str) {
    if is_silent() {
        return;
    }
    if colored() {
        eprintln!("{} unknown tool '{id}'", style("Error:").red().bold());
    } else {
        eprintln!("Error: unknown tool '{id}'");
    }
    eprintln!("Run 'dot list' to see available tools");
}

// ─── Step lines - brew style ─────────────────────────────────────────────────

pub fn print_step(step: &str, is_error: bool, detail: &str) {
    if is_silent() {
        return;
    }
    if colored() {
        if is_error {
            let arrow = style("==>").red().bold();
            let label = style("Error:").bold();
            if detail.is_empty() {
                eprintln!("{arrow} {label} {step}");
            } else {
                eprintln!("{arrow} {label} {step} {detail}");
            }
        } else {
            let arrow = style("==>").cyan().bold();
            let bold_step = style(step).bold();
            if detail.is_empty() {
                eprintln!("{arrow} {bold_step}");
            } else {
                eprintln!("{arrow} {bold_step} {detail}");
            }
        }
    } else if is_error {
        if detail.is_empty() {
            eprintln!("==> Error: {step}");
        } else {
            eprintln!("==> Error: {step} {detail}");
        }
    } else if detail.is_empty() {
        eprintln!("==> {step}");
    } else {
        eprintln!("==> {step} {detail}");
    }
}

pub fn print_step_start(step: &str, detail: &str) {
    print_step(step, false, detail);
}

pub fn print_running_cmd(cmd: &str, arg: &str) {
    if is_silent() {
        return;
    }
    eprintln!("   Running: {cmd} {arg}");
}

pub fn print_checksum_warning(err: &str) {
    if is_silent() {
        return;
    }
    if colored() {
        eprintln!(
            "   {} checksum verification failed: {err}",
            style("Warning:").yellow().bold()
        );
    } else {
        eprintln!("   Warning: checksum verification failed: {err}");
    }
}

pub fn print_no_package_manager(pm: &str) {
    if is_silent() {
        return;
    }
    eprintln!("   No package found for package manager: {pm}");
}

pub fn print_detail(msg: &str) {
    if is_silent() {
        return;
    }
    eprintln!("   {msg}");
}

pub fn print_section_header(title: &str) {
    if is_silent() {
        return;
    }
    if colored() {
        eprintln!("\n{} {}", style("==>").cyan().bold(), style(title).bold());
    } else {
        eprintln!("\n==> {title}");
    }
}

pub fn step_arrow() -> &'static str {
    sym_arrow()
}

pub fn print_already_current(tool_name: &str, version: &str, tool_id: &str) {
    if is_silent() {
        return;
    }
    if colored() {
        eprintln!(
            "{} {tool_name} {version} is already installed and up-to-date.",
            style("Warning:").yellow()
        );
    } else {
        eprintln!("Warning: {tool_name} {version} is already installed and up-to-date.");
    }
    eprintln!("To reinstall: dot install {tool_id} --force");
}

pub fn print_summary(upgraded: usize, uptodate: usize, failed: usize, elapsed_ms: u64) {
    if is_silent() {
        return;
    }
    let secs = elapsed_ms / 1000;
    let frac = (elapsed_ms % 1000) / 100;
    print_section_header("Summary");
    if colored() {
        eprintln!(
            "  {}  ·  {} already current  ·  {}  ·  {secs}.{frac}s",
            style(format!("{upgraded} upgraded")).green().bold(),
            uptodate,
            if failed > 0 {
                style(format!("{failed} failed")).red().bold().to_string()
            } else {
                style(format!("{failed} failed")).dim().to_string()
            }
        );
    } else {
        eprintln!("  {upgraded} upgraded  ·  {uptodate} already current  ·  {failed} failed  ·  {secs}.{frac}s");
    }
}

/// Format a Unix timestamp (decimal string) as "YYYY-MM-DD HH:MM:SS".
pub fn fmt_timestamp(ts_str: &str) -> String {
    use chrono::{TimeZone, Utc};
    if let Ok(secs) = ts_str.parse::<i64>() {
        if let Some(dt) = Utc.timestamp_opt(secs, 0).single() {
            return dt.format("%Y-%m-%d %H:%M:%S").to_string();
        }
    }
    ts_str.to_string()
}

/// Return the terminal width, defaulting to 80.
pub fn terminal_width() -> usize {
    Term::stdout().size().1 as usize
}

/// Pad `s` to `width` visible columns, ignoring ANSI escape codes when measuring.
pub fn pad_to(s: &str, width: usize) -> String {
    let visible = console::measure_text_width(s);
    let pad = width.saturating_sub(visible);
    format!("{}{}", s, " ".repeat(pad))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fmt_timestamp_epoch() {
        assert_eq!(fmt_timestamp("0"), "1970-01-01 00:00:00");
    }

    #[test]
    fn fmt_timestamp_invalid_returns_input() {
        assert_eq!(fmt_timestamp("notanumber"), "notanumber");
    }

    #[test]
    fn fmt_timestamp_known_date() {
        // 2024-06-15 10:00:00 UTC = 1718445600
        assert_eq!(fmt_timestamp("1718445600"), "2024-06-15 10:00:00");
    }
}
