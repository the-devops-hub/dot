use crate::ui::output::{get_render_mode, RenderMode};
use console::Term;
use std::cell::Cell;
use std::time::{Duration, Instant};

const UPDATE_INTERVAL: Duration = Duration::from_millis(50);

pub struct DownloadProgress {
    term: Term,
    active: bool,
    rich: bool,
    last_update: Cell<Option<Instant>>,
    last_done: Cell<u64>,
    last_total: Cell<Option<u64>>,
}

impl DownloadProgress {
    pub fn new() -> Self {
        let term = Term::stderr();
        let active = term.is_term();
        let rich = get_render_mode() == RenderMode::Rich;
        Self {
            term,
            active,
            rich,
            last_update: Cell::new(None),
            last_done: Cell::new(0),
            last_total: Cell::new(None),
        }
    }

    pub fn update(&self, done: u64, total: Option<u64>) {
        self.last_done.set(done);
        self.last_total.set(total);
        if !self.active {
            return;
        }
        let now = Instant::now();
        if let Some(last) = self.last_update.get() {
            if now.duration_since(last) < UPDATE_INTERVAL {
                return;
            }
        }
        self.last_update.set(Some(now));
        let width = self.term.size().1 as usize;
        let line = render_line(done, total, width, self.rich);
        let _ = self.term.clear_line();
        let _ = self.term.write_str(&line);
    }

    pub fn finish(&self) {
        if !self.active {
            return;
        }
        let done = self.last_done.get();
        let total = self.last_total.get();
        // If total is known show it as 100%; if not, treat done bytes as the total.
        let display_total = total.or(if done > 0 { Some(done) } else { None });
        let width = self.term.size().1 as usize;
        let line = render_line(done, display_total, width, self.rich);
        let _ = self.term.clear_line();
        let _ = self.term.write_str(&line);
        let _ = self.term.write_line("");
    }
}

impl Drop for DownloadProgress {
    fn drop(&mut self) {
        // Safety net: if finish() was not called (e.g. on error), clear the partial line.
        if self.active && self.last_update.get().is_some() {
            let _ = self.term.clear_line();
        }
    }
}

fn render_line(done: u64, total: Option<u64>, term_width: usize, rich: bool) -> String {
    if let Some(total) = total.filter(|&t| t > 0) {
        let pct = ((done as f64 / total as f64) * 100.0).min(100.0) as u32;
        // Both columns use the same fixed-width format — bar position never shifts.
        let done_str = fmt_fixed(done, total);
        let total_str = fmt_fixed(total, total);
        let prefix = format!("  {} / {}  ", done_str, total_str);
        let suffix = format!("  {:>3}%", pct);
        let avail = term_width.saturating_sub(prefix.len() + suffix.len());
        let bar_w = avail.min(30);
        if bar_w > 2 {
            let filled = (pct as usize * bar_w / 100).min(bar_w);
            let empty = bar_w - filled;
            let bar = if rich {
                format!("{}{}", "━".repeat(filled), "░".repeat(empty))
            } else {
                format!("[{}{}]", "#".repeat(filled), "-".repeat(empty))
            };
            format!("{prefix}{bar}{suffix}")
        } else {
            format!("{prefix}{suffix}")
        }
    } else {
        format!("  {} downloaded", fmt_bytes(done))
    }
}

/// Format `bytes` in the same unit as `reference`, with a fixed-width numeric column so both
/// the `done` and `total` fields always occupy identical screen widths:
///   B  → "{:>4} B"       e.g. "   0 B" … "1023 B"   (6 chars)
///   KB → "{:>5.1} KB"    e.g. "  0.0 KB" … "999.9 KB" (8 chars)
///   MB → "{:>5.1} MB"    e.g. "  0.0 MB" … "999.9 MB" (8 chars)
///   GB → "{:>6.2} GB"    e.g. "  0.00 GB" … "999.99 GB" (9 chars)
fn fmt_fixed(bytes: u64, reference: u64) -> String {
    if reference < 1024 {
        format!("{:>4} B", bytes)
    } else if reference < 1024 * 1024 {
        format!("{:>5.1} KB", bytes as f64 / 1024.0)
    } else if reference < 1024 * 1024 * 1024 {
        format!("{:>5.1} MB", bytes as f64 / (1024.0 * 1024.0))
    } else {
        format!("{:>6.2} GB", bytes as f64 / (1024.0 * 1024.0 * 1024.0))
    }
}

pub fn fmt_bytes(bytes: u64) -> String {
    if bytes < 1024 {
        format!("{bytes} B")
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else if bytes < 1024 * 1024 * 1024 {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    } else {
        format!("{:.2} GB", bytes as f64 / (1024.0 * 1024.0 * 1024.0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fmt_bytes_ranges() {
        assert_eq!(fmt_bytes(0), "0 B");
        assert_eq!(fmt_bytes(1023), "1023 B");
        assert_eq!(fmt_bytes(1024), "1.0 KB");
        assert_eq!(fmt_bytes(1536), "1.5 KB");
        assert_eq!(fmt_bytes(1024 * 1024), "1.0 MB");
        assert_eq!(fmt_bytes(1024 * 1024 * 10), "10.0 MB");
        assert_eq!(fmt_bytes(1024 * 1024 * 1024), "1.00 GB");
    }

    #[test]
    fn render_line_with_known_total() {
        // 512 KB of 1 MB — both in MB unit, numeric field is always {:>5.1}.
        let line = render_line(512 * 1024, Some(1024 * 1024), 80, false);
        assert!(line.contains("  0.5 MB /   1.0 MB"), "got: {line}");
        assert!(line.contains("50%"), "got: {line}");
    }

    #[test]
    fn render_line_prefix_width_is_stable() {
        // prefix length must not change between first and last byte
        let total = 45 * 1024 * 1024u64;
        let first = render_line(0, Some(total), 80, false);
        let mid = render_line(total / 2, Some(total), 80, false);
        let last = render_line(total, Some(total), 80, false);
        // isolate the "NNN / NNN  " prefix (everything before the bar or suffix)
        let prefix_len = |s: &str| {
            s.find('[')
                .or_else(|| s.find('━'))
                .or_else(|| s.find('░'))
                .unwrap_or(s.len())
        };
        assert_eq!(prefix_len(&first), prefix_len(&mid), "prefix shifted mid");
        assert_eq!(prefix_len(&first), prefix_len(&last), "prefix shifted last");
    }

    #[test]
    fn render_line_without_total() {
        let line = render_line(2 * 1024 * 1024, None, 80, false);
        assert!(line.contains("2.0 MB downloaded"), "got: {line}");
    }

    #[test]
    fn render_line_at_100_pct() {
        let line = render_line(1024, Some(1024), 80, false);
        assert!(line.contains("100%"), "got: {line}");
    }

    #[test]
    fn render_line_zero_total_falls_back() {
        let line = render_line(4096, Some(0), 80, false);
        assert!(line.contains("downloaded"), "got: {line}");
    }

    #[test]
    fn fmt_fixed_always_same_width_within_unit() {
        // MB tier: every value must produce an 8-char string
        let mb = 1024 * 1024u64;
        for bytes in [0, mb / 100, mb / 2, mb - 1, mb] {
            let s = fmt_fixed(bytes, mb);
            assert_eq!(
                s.len(),
                8,
                "fmt_fixed({bytes}, {mb}) = \"{s}\" (len {})",
                s.len()
            );
        }
        // KB tier: every value must produce an 8-char string
        let kb = 1024u64;
        for bytes in [0, 512, 999 * kb / 10, kb - 1] {
            let s = fmt_fixed(bytes, kb);
            assert_eq!(
                s.len(),
                8,
                "fmt_fixed({bytes}, {kb}) = \"{s}\" (len {})",
                s.len()
            );
        }
    }
}
