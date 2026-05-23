use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::error::DotError;

fn default_status() -> String {
    "installed".to_string()
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct ToolEntry {
    pub version: String,
    pub installed_at: String,
    pub method: String,
    pub source: String,
    #[serde(default = "default_status")]
    pub status: String,
    #[serde(default)]
    pub pinned: bool,
}

#[derive(Debug, Default, Deserialize, Serialize)]
struct StateFile {
    version: String,
    tools: HashMap<String, ToolEntry>,
}

pub struct State {
    path: PathBuf,
    data: StateFile,
}

impl State {
    pub fn load_default() -> Result<Self, DotError> {
        let path = crate::paths::dot_config_dir()?.join("state.json");
        Self::load(&path)
    }

    pub fn load(path: &Path) -> Result<Self, DotError> {
        let data = if path.exists() {
            let bytes = std::fs::read(path)?;
            serde_json::from_slice(&bytes).unwrap_or_default()
        } else {
            StateFile {
                version: "1.0".to_string(),
                tools: HashMap::new(),
            }
        };
        Ok(Self {
            path: path.to_owned(),
            data,
        })
    }

    pub fn save(&self) -> Result<(), DotError> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let tmp = self.path.with_extension("json.new");
        let json = serde_json::to_string_pretty(&self.data)?;
        std::fs::write(&tmp, json)?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }

    pub fn is_installed(&self, id: &str) -> bool {
        self.data.tools.contains_key(id)
    }

    pub fn get_version(&self, id: &str) -> Option<&str> {
        let entry = self.data.tools.get(id)?;
        if entry.version.is_empty() {
            None
        } else {
            Some(&entry.version)
        }
    }

    pub fn is_pinned(&self, id: &str) -> bool {
        self.data.tools.get(id).map(|e| e.pinned).unwrap_or(false)
    }

    pub fn get_entry(&self, id: &str) -> Option<&ToolEntry> {
        self.data.tools.get(id)
    }

    pub fn tools(&self) -> &HashMap<String, ToolEntry> {
        &self.data.tools
    }

    pub fn add_tool(
        &mut self,
        id: &str,
        version: &str,
        method: &str,
        pinned: bool,
    ) -> Result<(), DotError> {
        let installed_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
            .to_string();
        let source = format!("~/.local/bin/{id}");
        self.data.tools.insert(
            id.to_string(),
            ToolEntry {
                version: version.to_string(),
                installed_at,
                method: method.to_string(),
                source,
                status: "installed".to_string(),
                pinned,
            },
        );
        self.save()
    }

    pub fn remove_tool(&mut self, id: &str) -> Result<(), DotError> {
        self.data.tools.remove(id);
        self.save()
    }

    pub fn set_pinned(&mut self, id: &str, pinned: bool) -> Result<(), DotError> {
        if let Some(entry) = self.data.tools.get_mut(id) {
            entry.pinned = pinned;
            self.save()
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn make_state() -> (State, tempfile::TempDir) {
        let dir = tempdir().unwrap();
        let path = dir.path().join("state.json");
        let state = State::load(&path).unwrap();
        (state, dir)
    }

    #[test]
    fn empty_state_has_no_tools() {
        let (state, _dir) = make_state();
        assert!(!state.is_installed("helm"));
        assert!(state.get_version("helm").is_none());
        assert_eq!(state.data.tools.len(), 0);
    }

    #[test]
    fn add_tool_and_is_installed() {
        let (mut state, _dir) = make_state();
        assert!(!state.is_installed("helm"));
        state
            .add_tool("helm", "3.15.0", "github_release", false)
            .unwrap();
        assert!(state.is_installed("helm"));
        assert_eq!(state.get_version("helm"), Some("3.15.0"));
    }

    #[test]
    fn remove_tool() {
        let (mut state, _dir) = make_state();
        state
            .add_tool("kubectl", "1.29.0", "direct_binary", false)
            .unwrap();
        assert!(state.is_installed("kubectl"));
        state.remove_tool("kubectl").unwrap();
        assert!(!state.is_installed("kubectl"));
    }

    #[test]
    fn save_and_load_round_trip() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("state.json");
        {
            let mut state = State::load(&path).unwrap();
            state
                .add_tool("terraform", "1.7.0", "hashicorp_release", false)
                .unwrap();
        }
        {
            let state = State::load(&path).unwrap();
            assert!(state.is_installed("terraform"));
            assert_eq!(state.get_version("terraform"), Some("1.7.0"));
        }
    }

    #[test]
    fn pinned_true_stored_and_returned() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("state.json");
        let mut state = State::load(&path).unwrap();
        state
            .add_tool("terraform", "1.8.0", "hashicorp_release", true)
            .unwrap();
        assert!(state.is_pinned("terraform"));
    }

    #[test]
    fn pinned_false_not_pinned() {
        let (mut state, _dir) = make_state();
        state
            .add_tool("terraform", "1.14.6", "hashicorp_release", false)
            .unwrap();
        assert!(!state.is_pinned("terraform"));
    }

    #[test]
    fn pinned_survives_round_trip() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("state.json");
        {
            let mut state = State::load(&path).unwrap();
            state
                .add_tool("terraform", "1.8.0", "hashicorp_release", true)
                .unwrap();
        }
        {
            let state = State::load(&path).unwrap();
            assert!(state.is_pinned("terraform"));
            assert_eq!(state.get_version("terraform"), Some("1.8.0"));
        }
    }

    #[test]
    fn multiple_tools() {
        let (mut state, _dir) = make_state();
        state
            .add_tool("helm", "3.15.0", "github_release", false)
            .unwrap();
        state
            .add_tool("kubectl", "1.29.0", "direct_binary", false)
            .unwrap();
        state
            .add_tool("k9s", "0.32.0", "github_release", false)
            .unwrap();
        assert_eq!(state.data.tools.len(), 3);
        assert!(state.is_installed("helm"));
        assert!(state.is_installed("kubectl"));
        assert!(state.is_installed("k9s"));
        assert!(!state.is_installed("terraform"));
    }
}
