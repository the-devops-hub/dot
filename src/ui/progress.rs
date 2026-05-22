use indicatif::{ProgressBar, ProgressStyle};

pub struct DownloadProgress {
    bar: ProgressBar,
}

impl DownloadProgress {
    pub fn new(total: Option<u64>) -> Self {
        let bar = if let Some(total) = total {
            let b = ProgressBar::new(total);
            b.set_style(
                ProgressStyle::default_bar()
                    .template("  {bytes}/{total_bytes} [{bar:30}] {percent}%")
                    .unwrap_or_else(|_| ProgressStyle::default_bar())
                    .progress_chars("##-"),
            );
            b
        } else {
            let b = ProgressBar::new_spinner();
            b.set_style(
                ProgressStyle::default_spinner()
                    .template("  {bytes} downloaded {spinner}")
                    .unwrap_or_else(|_| ProgressStyle::default_spinner()),
            );
            b
        };
        Self { bar }
    }

    pub fn update(&self, done: u64, _total: Option<u64>) {
        self.bar.set_position(done);
    }

    pub fn finish(&self) {
        self.bar.finish_and_clear();
    }
}

impl Drop for DownloadProgress {
    fn drop(&mut self) {
        self.bar.finish_and_clear();
    }
}

/// Format bytes into a human-readable string (B, KB, MB, GB).
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
}
