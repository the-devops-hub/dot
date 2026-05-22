use thiserror::Error;

#[derive(Debug, Error)]
pub enum DotError {
    #[error("HTTP {status} fetching {url}")]
    Http { url: String, status: u16 },

    #[error("network error: {0}")]
    Network(Box<ureq::Error>),

    #[error("JSON parse error: {0}")]
    JsonParse(#[from] serde_json::Error),

    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("version not found")]
    VersionNotFound,

    #[error("version fetch failed")]
    VersionFetchFailed,

    #[error("version parse failed")]
    VersionParseFailed,

    #[error("checksum mismatch — download may be corrupted")]
    ChecksumMismatch,

    #[error("bad checksum format")]
    BadChecksumFormat,

    #[error("archive extraction failed: {0}")]
    Archive(String),

    #[error("install script failed with exit code {0}")]
    InstallScriptFailed(i32),

    #[error("installer process failed")]
    InstallerFailed,

    #[error("python3 not found — install it to use pip-based tools")]
    PythonNotFound,

    #[error("venv creation failed")]
    VenvCreationFailed,

    #[error("pip install failed")]
    PipInstallFailed,

    #[error("package install failed")]
    PackageInstallFailed,

    #[error("no package defined for this package manager")]
    NoPackageForManager,

    #[error("no home directory found")]
    NoHome,

    #[error("unknown template key '{0}'")]
    UnknownTemplateKey(String),

    #[error("state file corrupt: {0}")]
    StateCorrupt(String),

    #[error("unknown tool: {0}")]
    UnknownTool(String),

    #[error("missing repository URL")]
    MissingRepoUrl,

    #[error("invalid repository JSON: {0}")]
    InvalidRepoJson(String),
}

impl From<ureq::Error> for DotError {
    fn from(e: ureq::Error) -> Self {
        DotError::Network(Box::new(e))
    }
}
