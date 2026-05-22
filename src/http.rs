use std::io::{Read, Write};
use std::path::Path;

use crate::error::DotError;

const USER_AGENT: &str = concat!("dot/", env!("CARGO_PKG_VERSION"));

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .user_agent(USER_AGENT)
        .build()
        .into()
}

/// Perform a GET request and return the body as a String.
pub fn get(url: &str) -> Result<String, DotError> {
    let mut response = agent().get(url).call().map_err(|e| match e {
        ureq::Error::StatusCode(code) => DotError::Http {
            url: url.to_string(),
            status: code,
        },
        other => DotError::from(other),
    })?;
    response.body_mut().read_to_string().map_err(DotError::from)
}

/// Download `url` to `dest` atomically (writes to `.tmp`, then renames on success).
/// Calls `on_progress(bytes_done, total_bytes)` after each chunk.
pub fn download(
    url: &str,
    dest: &Path,
    mut on_progress: Option<&mut dyn FnMut(u64, Option<u64>)>,
) -> Result<(), DotError> {
    let mut response = agent().get(url).call().map_err(|e| match e {
        ureq::Error::StatusCode(code) => DotError::Http {
            url: url.to_string(),
            status: code,
        },
        other => DotError::from(other),
    })?;

    let total = response.body().content_length();

    let tmp = dest.with_extension("tmp");
    if let Some(parent) = tmp.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut file = std::fs::File::create(&tmp)?;
    let mut reader = response.body_mut().as_reader();
    let mut buf = [0u8; 65536];
    let mut done = 0u64;

    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n])?;
        done += n as u64;
        if let Some(cb) = on_progress.as_deref_mut() {
            cb(done, total);
        }
    }
    drop(file);
    std::fs::rename(&tmp, dest)?;
    Ok(())
}
