/// ~/.local — user-local prefix (XDG_DATA_HOME base)
pub const local_dir = ".local";
/// ~/.local/bin — managed binary directory
pub const bin_dir = "bin";
/// ~/.config — XDG config base directory
pub const config_dir = ".config";
/// ~/.config/dot — dot's own config subdirectory
pub const dot_config_subdir = "dot";
/// Fallback path used when $HOME is not set
pub const fallback_home = "/tmp";
/// Suffix appended during atomic rename (write to .new, then rename over target)
pub const new_file_suffix = ".new";
/// Temporary file extension used during HTTP downloads
pub const tmp_file_ext = ".tmp";
