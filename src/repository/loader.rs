use crate::error::DotError;
use crate::tool::Tool;

static BUILTIN_REPO_BYTES: &[u8] = include_bytes!("builtin-repository.json");

#[derive(Debug, serde::Deserialize)]
struct RepoJson {
    #[serde(default)]
    tools: Vec<serde_json::Value>,
}

/// Parse a `&[u8]` repository JSON blob into a `Vec<Tool>`.
pub fn parse_repository_json(bytes: &[u8]) -> Result<Vec<Tool>, DotError> {
    let repo: RepoJson = serde_json::from_slice(bytes)?;
    let mut tools = Vec::new();
    for v in repo.tools {
        if let Ok(t) = serde_json::from_value::<Tool>(v) {
            tools.push(t);
        }
    }
    Ok(tools)
}

/// Load the built-in tool list from the bytes compiled into the binary.
pub fn load_builtin_tools() -> Result<Vec<Tool>, DotError> {
    parse_repository_json(BUILTIN_REPO_BYTES)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tool::Group;

    #[test]
    fn parse_empty_tools_array() {
        let tools = parse_repository_json(br#"{"tools":[]}"#).unwrap();
        assert_eq!(tools.len(), 0);
    }

    #[test]
    fn parse_single_github_release_tool() {
        let json = br#"{
            "tools": [{
                "id": "mytool",
                "name": "MyTool",
                "description": "Does stuff",
                "groups": ["utils"],
                "homepage": "https://example.com",
                "version_source": {"type": "github_release", "repo": "me/mytool"},
                "strategy": {"type": "github_release", "url_template": "https://example.com/v{version}/mytool.tar.gz", "binary_in_archive": "mytool"}
            }]
        }"#;
        let tools = parse_repository_json(json).unwrap();
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0].id, "mytool");
        assert_eq!(tools[0].name, "MyTool");
        assert!(matches!(tools[0].groups[0], Group::Utils));
    }

    #[test]
    fn parse_invalid_tool_is_skipped() {
        let tools = parse_repository_json(br#"{"tools":[{"id":"bad"}]}"#).unwrap();
        assert_eq!(tools.len(), 0);
    }

    #[test]
    fn builtin_repo_parses_all_tools() {
        let tools = parse_repository_json(BUILTIN_REPO_BYTES).unwrap();
        assert_eq!(tools.len(), 33);
    }
}
