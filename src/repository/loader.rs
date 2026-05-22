use serde::{Deserialize, Serialize};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::error::DotError;
use crate::tool::Tool;

static BUILTIN_REPO_BYTES: &[u8] = include_bytes!("builtin-repository.json");

const CACHE_STALENESS_SECS: u64 = 86400;
const BUILTIN_REPO_NAME: &str = "the-devops-hub";
const BUILTIN_REPO_URL: &str =
    "https://raw.githubusercontent.com/the-devops-hub/dot/main/src/repository/builtin-repository.json";

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RepositorySource {
    pub name: String,
    pub url: String,
    pub added_at: String,
    pub fetched_at: String,
}

#[derive(Debug, Default, Deserialize, Serialize)]
struct RepoFile {
    #[serde(default)]
    sources: Vec<RepositorySource>,
}

#[derive(Debug, Deserialize)]
struct RepoJson {
    #[serde(default)]
    tools: Vec<serde_json::Value>,
    #[serde(default)]
    name: Option<String>,
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn cache_stale(path: &Path) -> bool {
    if let Ok(meta) = std::fs::metadata(path) {
        if let Ok(modified) = meta.modified() {
            if let Ok(age) = SystemTime::now().duration_since(modified) {
                return age.as_secs() > CACHE_STALENESS_SECS;
            }
        }
    }
    true
}

/// Parse a `&[u8]` repository JSON blob into a `Vec<Tool>`.
pub fn parse_repository_json(bytes: &[u8]) -> Result<Vec<Tool>, DotError> {
    let repo: RepoJson = serde_json::from_slice(bytes)?;
    let mut tools = Vec::new();
    for v in repo.tools {
        match serde_json::from_value::<Tool>(v) {
            Ok(t) => tools.push(t),
            Err(_) => {} // skip malformed tool entries
        }
    }
    Ok(tools)
}

/// Count tools in a JSON blob without full deserialization.
pub fn count_tools_in_json(bytes: &[u8]) -> usize {
    if let Ok(repo) = serde_json::from_slice::<RepoJson>(bytes) {
        repo.tools.len()
    } else {
        0
    }
}

/// Parse the `name` field from a repository JSON blob. Caller owns the result.
pub fn parse_name_from_json(bytes: &[u8]) -> Result<String, DotError> {
    let repo: RepoJson = serde_json::from_slice(bytes)?;
    repo.name
        .ok_or_else(|| DotError::InvalidRepoJson("missing 'name' field".to_string()))
}

fn load_cached_tools(name: &str) -> Result<Vec<Tool>, DotError> {
    let path = crate::paths::repo_cache_file(name)?;
    let bytes = std::fs::read(&path)?;
    parse_repository_json(&bytes)
}

/// Fetch `url` and write to the cache file for `name`.
pub fn fetch_and_cache(name: &str, url: &str) -> Result<(), DotError> {
    let body = crate::http::get(url)?;
    let config_dir = crate::paths::dot_config_dir()?;
    std::fs::create_dir_all(&config_dir)?;
    let path = config_dir.join(format!("repository-{name}.json"));
    std::fs::write(&path, body.as_bytes())?;
    update_fetched_at(name)?;
    Ok(())
}

fn update_fetched_at(name: &str) -> Result<(), DotError> {
    let mut sources = load_repositories().unwrap_or_default();
    let ts = now_secs().to_string();
    for s in &mut sources {
        if s.name == name {
            s.fetched_at = ts.clone();
        }
    }
    save_repositories(&sources)
}

/// Load external repository sources from `repositories.json`.
pub fn load_repositories() -> Result<Vec<RepositorySource>, DotError> {
    let path = crate::paths::repositories_config_file()?;
    if !path.exists() {
        return Ok(vec![]);
    }
    let bytes = std::fs::read(&path)?;
    let file: RepoFile = serde_json::from_slice(&bytes).unwrap_or_default();
    Ok(file.sources)
}

/// Persist external repository sources to `repositories.json`.
pub fn save_repositories(sources: &[RepositorySource]) -> Result<(), DotError> {
    let config_dir = crate::paths::dot_config_dir()?;
    std::fs::create_dir_all(&config_dir)?;
    let path = config_dir.join("repositories.json");
    let file = RepoFile {
        sources: sources.to_vec(),
    };
    let json = serde_json::to_string_pretty(&file)?;
    std::fs::write(&path, json)?;
    Ok(())
}

/// Load the built-in tool list. Tries a 24h-refreshed cache first, falls back
/// to the bytes compiled into the binary.
pub fn load_builtin_tools() -> Result<Vec<Tool>, DotError> {
    let cache = crate::paths::repo_cache_file(BUILTIN_REPO_NAME)?;
    if cache_stale(&cache) {
        let _ = fetch_and_cache(BUILTIN_REPO_NAME, BUILTIN_REPO_URL);
    }
    if let Ok(tools) = load_cached_tools(BUILTIN_REPO_NAME) {
        return Ok(tools);
    }
    parse_repository_json(BUILTIN_REPO_BYTES)
}

/// Load tools from all registered external repositories.
pub fn load_external_tools() -> Result<Vec<Tool>, DotError> {
    let sources = load_repositories().unwrap_or_default();
    let mut all = Vec::new();
    for source in sources {
        let ts: u64 = source.fetched_at.parse().unwrap_or(0);
        if now_secs().saturating_sub(ts) > CACHE_STALENESS_SECS {
            let _ = fetch_and_cache(&source.name, &source.url);
        }
        if let Ok(tools) = load_cached_tools(&source.name) {
            all.extend(tools);
        }
    }
    Ok(all)
}

/// Merge builtin and external tools. Externals override builtins with the same ID.
pub fn merge_tools(builtins: Vec<Tool>, externals: Vec<Tool>) -> Vec<Tool> {
    let mut merged = builtins;
    for ext in externals {
        if let Some(pos) = merged.iter().position(|t| t.id == ext.id) {
            merged[pos] = ext;
        } else {
            merged.push(ext);
        }
    }
    merged
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tool::{Group, InstallStrategy, VersionSource};

    #[test]
    fn parse_empty_tools_array() {
        let json = br#"{"name":"test","tools":[]}"#;
        let tools = parse_repository_json(json).unwrap();
        assert_eq!(tools.len(), 0);
    }

    #[test]
    fn parse_single_github_release_tool() {
        let json = br#"{
            "name": "myrepo",
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
        assert_eq!(tools[0].groups.len(), 1);
        assert!(matches!(tools[0].groups[0], Group::Utils));
    }

    #[test]
    fn parse_invalid_tool_is_skipped() {
        let json = br#"{"name":"test","tools":[{"id":"bad"}]}"#;
        let tools = parse_repository_json(json).unwrap();
        assert_eq!(tools.len(), 0);
    }

    #[test]
    fn parse_name_from_json_valid() {
        let name = parse_name_from_json(br#"{"name":"myrepo","tools":[]}"#).unwrap();
        assert_eq!(name, "myrepo");
    }

    #[test]
    fn count_tools_in_json_correct() {
        let count = count_tools_in_json(br#"{"name":"r","tools":[{},{},{}]}"#);
        assert_eq!(count, 3);
    }

    #[test]
    fn builtin_repo_parses_all_tools() {
        let tools = parse_repository_json(BUILTIN_REPO_BYTES).unwrap();
        assert_eq!(tools.len(), 33);
    }

    #[test]
    fn merge_tools_external_overrides_builtin() {
        let builtins = vec![
            make_tool("helm", "builtin"),
            make_tool("kubectl", "builtin"),
        ];
        let externals = vec![
            make_tool("helm", "external"),
            make_tool("mytool", "external"),
        ];
        let merged = merge_tools(builtins, externals);
        assert_eq!(merged.len(), 3);
        let helm = merged.iter().find(|t| t.id == "helm").unwrap();
        assert_eq!(helm.description, "external");
    }

    fn make_tool(id: &str, desc: &str) -> crate::tool::Tool {
        crate::tool::Tool {
            id: id.to_string(),
            name: id.to_string(),
            description: desc.to_string(),
            groups: vec![Group::Utils],
            homepage: String::new(),
            version_source: VersionSource::Static(crate::tool::StaticSourceParams {
                version: "1.0.0".to_string(),
            }),
            strategy: InstallStrategy::DirectBinary(crate::tool::DirectBinaryStrategy {
                url_template: "https://example.com".to_string(),
            }),
            brew_formula: None,
            shell_completions: None,
            aliases: vec![],
            post_install: vec![],
            post_upgrade: vec![],
            quick_start: vec![],
            resources: vec![],
            shell_env: vec![],
        }
    }
}
