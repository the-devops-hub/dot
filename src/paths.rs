use crate::error::DotError;
use std::path::PathBuf;

pub const LOCAL_DIR: &str = ".local";
pub const BIN_DIR: &str = "bin";
pub const CONFIG_DIR: &str = ".config";
pub const DOT_CONFIG_SUBDIR: &str = "dot";

pub fn home_dir() -> Result<PathBuf, DotError> {
    dirs::home_dir().ok_or(DotError::NoHome)
}

pub fn dot_config_dir() -> Result<PathBuf, DotError> {
    let home = home_dir()?;
    Ok(home.join(CONFIG_DIR).join(DOT_CONFIG_SUBDIR))
}

pub fn local_bin_dir() -> Result<PathBuf, DotError> {
    let home = home_dir()?;
    Ok(home.join(LOCAL_DIR).join(BIN_DIR))
}

pub fn shell_integration_file(shell: crate::platform::Shell) -> Result<PathBuf, DotError> {
    Ok(local_bin_dir()?.join(shell.integration_file_name()))
}
