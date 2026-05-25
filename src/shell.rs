use std::path::Path;

use crate::error::DotError;
use crate::platform::Shell;

pub const SOURCE_MARKER: &str = "# dot: source shell integration";
const PATH_MARKER: &str = "# dot: add local bin to PATH";

/// Ensure the shell integration file is sourced from the user's RC file. Idempotent.
pub fn ensure_sourced(shell: Shell) -> Result<(), DotError> {
    if shell == Shell::Unknown {
        return Ok(());
    }
    let home = crate::paths::home_dir()?;
    let rc_path = match shell {
        Shell::Bash => home.join(".bashrc"),
        Shell::Zsh => home.join(".zshrc"),
        Shell::Fish => home.join(".config").join("fish").join("config.fish"),
        Shell::Unknown => return Ok(()),
    };

    let integration_path = crate::paths::shell_integration_file(shell)?;

    // Ensure integration file exists
    if let Some(parent) = integration_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if !integration_path.exists() {
        std::fs::write(&integration_path, "")?;
    }

    // Read RC content
    let rc_content = match std::fs::read_to_string(&rc_path) {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let source_line = build_source_line(&integration_path);
            append_to_file(&rc_path, &source_line)?;
            return Ok(());
        }
        Err(e) => return Err(DotError::Io(e)),
    };

    if rc_content.contains(SOURCE_MARKER) {
        normalize_integration_file(&integration_path)?;
        return Ok(());
    }

    let source_line = build_source_line(&integration_path);
    append_to_file(&rc_path, &source_line)?;
    ensure_path_in_integration(shell, &integration_path)?;
    Ok(())
}

/// Add or replace a tool's shell section in the integration file. Idempotent.
pub fn add_section(shell: Shell, tool_name: &str, config: &str) -> Result<(), DotError> {
    let integration_path = crate::paths::shell_integration_file(shell)?;
    if let Some(parent) = integration_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let upper = tool_name.to_uppercase();
    let begin_marker = format!("# BEGIN {upper}");
    let end_marker = format!("# END {upper}");

    let existing = if integration_path.exists() {
        std::fs::read_to_string(&integration_path)?
    } else {
        String::new()
    };

    let new_content = rebuild_with_section(&existing, &begin_marker, &end_marker, config);
    write_file(&integration_path, &new_content)?;
    Ok(())
}

/// Remove a tool's section from the integration file.
pub fn remove_section(shell: Shell, tool_name: &str) -> Result<(), DotError> {
    let integration_path = crate::paths::shell_integration_file(shell)?;
    if !integration_path.exists() {
        return Ok(());
    }

    let upper = tool_name.to_uppercase();
    let begin_marker = format!("# BEGIN {upper}");
    let end_marker = format!("# END {upper}");

    let existing = std::fs::read_to_string(&integration_path)?;
    let new_content = rebuild_without_section(&existing, &begin_marker, &end_marker);
    write_file(&integration_path, &new_content)?;
    Ok(())
}

// ─── Pure text helpers ────────────────────────────────────────────────────────

/// Insert or replace the marked section. Returns the new file content.
pub fn rebuild_with_section(
    existing: &str,
    begin_marker: &str,
    end_marker: &str,
    config: &str,
) -> String {
    let mut out = String::new();

    if existing.contains(begin_marker) {
        let mut in_section = false;
        for line in existing.split('\n') {
            if line == begin_marker {
                out.push_str(begin_marker);
                out.push('\n');
                out.push_str(config);
                out.push('\n');
                in_section = true;
            } else if line == end_marker {
                out.push_str(end_marker);
                out.push('\n');
                in_section = false;
            } else if !in_section {
                out.push_str(line);
                out.push('\n');
            }
        }
    } else {
        out.push_str(existing);
        if !existing.is_empty() && !existing.ends_with('\n') {
            out.push('\n');
        }
        out.push('\n');
        out.push_str(begin_marker);
        out.push('\n');
        out.push_str(config);
        out.push('\n');
        out.push_str(end_marker);
        out.push('\n');
    }

    normalize_blank_lines(&out)
}

/// Remove the marked section and return the new file content.
pub fn rebuild_without_section(existing: &str, begin_marker: &str, end_marker: &str) -> String {
    let mut out = String::new();
    let mut in_section = false;

    for line in existing.split('\n') {
        if line == begin_marker {
            in_section = true;
        } else if line == end_marker {
            in_section = false;
        } else if !in_section {
            out.push_str(line);
            out.push('\n');
        }
    }

    normalize_blank_lines(&out)
}

// ─── Private helpers ─────────────────────────────────────────────────────────

fn normalize_blank_lines(content: &str) -> String {
    let mut out = String::new();
    let mut consecutive_blank = 0usize;

    for line in content.split('\n') {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            consecutive_blank += 1;
        } else {
            if consecutive_blank > 0 {
                out.push('\n');
                consecutive_blank = 0;
            }
            out.push_str(line);
            out.push('\n');
        }
    }
    out
}

fn build_source_line(integration_path: &Path) -> String {
    format!("\n{SOURCE_MARKER}\nsource {}\n", integration_path.display())
}

fn ensure_path_in_integration(shell: Shell, integration_path: &Path) -> Result<(), DotError> {
    let content = if integration_path.exists() {
        std::fs::read_to_string(integration_path)?
    } else {
        String::new()
    };

    if content.contains(PATH_MARKER) {
        return Ok(());
    }

    let bin_dir = crate::paths::local_bin_dir()?;
    let path_line = shell.path_add_syntax(&bin_dir.to_string_lossy());
    let addition = format!("\n{PATH_MARKER}\n{path_line}\n");
    append_to_file(integration_path, &addition)?;
    Ok(())
}

fn normalize_integration_file(path: &Path) -> Result<(), DotError> {
    if !path.exists() {
        return Ok(());
    }
    let existing = std::fs::read_to_string(path)?;
    let cleaned = normalize_blank_lines(&existing);
    write_file(path, &cleaned)
}

fn append_to_file(path: &Path, content: &str) -> Result<(), DotError> {
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    file.write_all(content.as_bytes())?;
    Ok(())
}

fn write_file(path: &Path, content: &str) -> Result<(), DotError> {
    std::fs::write(path, content)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rebuild_with_section_append_to_empty() {
        let result = rebuild_with_section(
            "",
            "# BEGIN HELM",
            "# END HELM",
            "source <(helm completion bash)",
        );
        assert!(result.contains("# BEGIN HELM"));
        assert!(result.contains("# END HELM"));
        assert!(result.contains("source <(helm completion bash)"));
    }

    #[test]
    fn rebuild_with_section_append_to_existing_without_section() {
        let existing = "export PATH=$PATH:/usr/local/bin\n";
        let result = rebuild_with_section(
            existing,
            "# BEGIN HELM",
            "# END HELM",
            "source <(helm completion bash)",
        );
        assert!(result.contains("export PATH"));
        assert!(result.contains("# BEGIN HELM"));
        assert!(result.contains("source <(helm completion bash)"));
    }

    #[test]
    fn rebuild_with_section_replaces_existing() {
        let existing = "export PATH=$PATH:/usr/local/bin\n# BEGIN HELM\nsource <(helm completion bash)\n# END HELM\nexport EDITOR=vim\n";
        let result = rebuild_with_section(
            existing,
            "# BEGIN HELM",
            "# END HELM",
            "source <(helm completion zsh)",
        );
        assert!(result.contains("source <(helm completion zsh)"));
        assert!(!result.contains("source <(helm completion bash)"));
        assert!(result.contains("export PATH"));
        assert!(result.contains("export EDITOR=vim"));
    }

    #[test]
    fn rebuild_with_section_idempotent() {
        let config = "source <(helm completion bash)";
        let first = rebuild_with_section("", "# BEGIN HELM", "# END HELM", config);
        let second = rebuild_with_section(&first, "# BEGIN HELM", "# END HELM", config);
        // marker appears exactly once
        assert_eq!(second.matches("# BEGIN HELM").count(), 1);
    }

    #[test]
    fn rebuild_without_section_removes() {
        let existing = "export PATH=$PATH:/usr/local/bin\n# BEGIN HELM\nsource <(helm completion bash)\n# END HELM\nexport EDITOR=vim\n";
        let result = rebuild_without_section(existing, "# BEGIN HELM", "# END HELM");
        assert!(!result.contains("# BEGIN HELM"));
        assert!(!result.contains("# END HELM"));
        assert!(!result.contains("source <(helm completion bash)"));
        assert!(result.contains("export PATH"));
        assert!(result.contains("export EDITOR=vim"));
    }

    #[test]
    fn rebuild_without_section_noop_if_absent() {
        let existing = "export PATH=$PATH:/usr/local/bin\nexport EDITOR=vim\n";
        let result = rebuild_without_section(existing, "# BEGIN HELM", "# END HELM");
        assert!(result.contains("export PATH"));
        assert!(result.contains("export EDITOR=vim"));
    }

    #[test]
    fn rebuild_without_section_empty_content() {
        let result = rebuild_without_section("", "# BEGIN HELM", "# END HELM");
        assert_eq!(result, "");
    }
}
