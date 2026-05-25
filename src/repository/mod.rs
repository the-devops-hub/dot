pub mod loader;
pub use loader::load_builtin_tools;

use crate::tool::Tool;

pub fn load_all_tools() -> anyhow::Result<Vec<Tool>> {
    Ok(load_builtin_tools()?)
}
