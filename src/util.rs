use std::path::Path;

const MAX_EDIT_LEN: usize = 64;

/// Levenshtein distance. Inputs longer than 64 chars are truncated.
/// Single-row DP — O(n) space.
pub fn edit_distance(a: &str, b: &str) -> usize {
    let a = &a.as_bytes()[..a.len().min(MAX_EDIT_LEN)];
    let b = &b.as_bytes()[..b.len().min(MAX_EDIT_LEN)];
    let la = a.len();
    let lb = b.len();
    if la == 0 {
        return lb;
    }
    if lb == 0 {
        return la;
    }

    let mut row = vec![0usize; lb + 1];
    for j in 0..=lb {
        row[j] = j;
    }
    for i in 0..la {
        let mut diag = row[0];
        row[0] = i + 1;
        for j in 0..lb {
            let above = row[j + 1];
            let cost = if a[i] == b[j] { 0 } else { 1 };
            row[j + 1] = (row[j] + 1).min((above + 1).min(diag + cost));
            diag = above;
        }
    }
    row[lb]
}

/// Walk $PATH and return the first directory where `name` is an executable.
pub fn find_in_path(name: &str) -> Option<String> {
    let path_env = std::env::var("PATH").ok()?;
    find_in_path_str(name, &path_env)
}

pub fn find_in_path_str(name: &str, path_str: &str) -> Option<String> {
    for dir in path_str.split(':') {
        if dir.is_empty() {
            continue;
        }
        let full = Path::new(dir).join(name);
        if full.is_file() {
            use std::os::unix::fs::PermissionsExt;
            if let Ok(meta) = full.metadata() {
                if meta.permissions().mode() & 0o111 != 0 {
                    return Some(full.to_string_lossy().into_owned());
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edit_distance_identical() {
        assert_eq!(edit_distance("list", "list"), 0);
        assert_eq!(edit_distance("", ""), 0);
    }

    #[test]
    fn edit_distance_empty() {
        assert_eq!(edit_distance("", "list"), 4);
        assert_eq!(edit_distance("list", ""), 4);
    }

    #[test]
    fn edit_distance_one_substitution() {
        assert_eq!(edit_distance("lisT", "list"), 1);
    }

    #[test]
    fn edit_distance_one_insertion() {
        assert_eq!(edit_distance("ist", "list"), 1);
    }

    #[test]
    fn edit_distance_one_deletion() {
        assert_eq!(edit_distance("listt", "list"), 1);
    }

    #[test]
    fn edit_distance_transposition_costs_2() {
        assert_eq!(edit_distance("lsit", "list"), 2);
    }

    #[test]
    fn edit_distance_completely_different() {
        assert!(edit_distance("xyz", "list") > 3);
    }

    #[test]
    fn edit_distance_tool_id_examples() {
        assert_eq!(edit_distance("helms", "helm"), 1);
        assert_eq!(edit_distance("kubctl", "kubectl"), 1);
    }

    #[test]
    fn find_in_path_str_finds_sh() {
        let found = find_in_path_str("sh", "/bin:/usr/bin")
            .or_else(|| find_in_path_str("sh", "/usr/bin:/bin"));
        if let Some(p) = found {
            assert!(p.ends_with("/sh"));
        }
    }

    #[test]
    fn find_in_path_str_nonexistent() {
        assert!(
            find_in_path_str("this-binary-does-not-exist-dot-toolbox", "/bin:/usr/bin").is_none()
        );
    }
}
