const MAX_ID_LEN: usize = 64;
const MAX_VERSION_LEN: usize = 64;

pub fn is_valid_tool_id(id: &str) -> bool {
    if id.is_empty() || id.len() > MAX_ID_LEN {
        return false;
    }
    id.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

pub fn is_valid_version(v: &str) -> bool {
    if v.is_empty() || v.len() > MAX_VERSION_LEN {
        return false;
    }
    v.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '+')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_tool_ids() {
        assert!(is_valid_tool_id("helm"));
        assert!(is_valid_tool_id("kubectl"));
        assert!(is_valid_tool_id("my-tool"));
        assert!(is_valid_tool_id("my_tool"));
        assert!(is_valid_tool_id("tool123"));
        assert!(is_valid_tool_id("k9s"));
    }

    #[test]
    fn invalid_tool_ids() {
        assert!(!is_valid_tool_id(""));
        assert!(!is_valid_tool_id("tool with spaces"));
        assert!(!is_valid_tool_id("tool;rm -rf /"));
        assert!(!is_valid_tool_id("../evil"));
        assert!(!is_valid_tool_id("tool/path"));
        assert!(!is_valid_tool_id("tool\x00null"));
        assert!(!is_valid_tool_id("$(evil)"));
        assert!(!is_valid_tool_id(&"a".repeat(65)));
    }

    #[test]
    fn valid_versions() {
        assert!(is_valid_version("3.15.0"));
        assert!(is_valid_version("latest"));
        assert!(is_valid_version("1.0.0-rc.1"));
        assert!(is_valid_version("1.0.0+build.1"));
        assert!(is_valid_version("v3.15.0"));
        assert!(is_valid_version("2024.01.15"));
    }

    #[test]
    fn invalid_versions() {
        assert!(!is_valid_version(""));
        assert!(!is_valid_version("3.0/../../evil"));
        assert!(!is_valid_version("1.0 && rm -rf /"));
        assert!(!is_valid_version("$(evil)"));
        assert!(!is_valid_version("1.0;evil"));
        assert!(!is_valid_version("1.0\nnewline"));
        assert!(!is_valid_version(&"a".repeat(65)));
    }
}
