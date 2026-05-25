use std::fs;
use std::io::BufReader;
use std::path::Path;

use crate::error::DotError;

/// Extract a `.tar.gz` or `.tgz` archive to `dest_dir`, stripping `strip_components` leading
/// path components from each entry.
pub fn extract_tar_gz(
    archive_path: &Path,
    dest_dir: &Path,
    strip_components: u32,
) -> Result<(), DotError> {
    fs::create_dir_all(dest_dir)?;
    let file = fs::File::open(archive_path)?;
    let gz = flate2::read::GzDecoder::new(BufReader::new(file));
    unpack_tar(gz, dest_dir, strip_components)
}

/// Extract a `.tar.xz` archive to `dest_dir`.
pub fn extract_tar_xz(
    archive_path: &Path,
    dest_dir: &Path,
    strip_components: u32,
) -> Result<(), DotError> {
    fs::create_dir_all(dest_dir)?;
    let file = fs::File::open(archive_path)?;
    let xz = xz2::read::XzDecoder::new(BufReader::new(file));
    unpack_tar(xz, dest_dir, strip_components)
}

/// Extract a `.zip` archive to `dest_dir`.
pub fn extract_zip(archive_path: &Path, dest_dir: &Path) -> Result<(), DotError> {
    fs::create_dir_all(dest_dir)?;
    let file = fs::File::open(archive_path)?;
    let mut archive = zip::ZipArchive::new(file).map_err(|e| DotError::Archive(e.to_string()))?;

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| DotError::Archive(e.to_string()))?;
        let name = entry.mangled_name();
        let dest = dest_dir.join(&name);
        if entry.is_dir() {
            fs::create_dir_all(&dest)?;
        } else {
            if let Some(parent) = dest.parent() {
                fs::create_dir_all(parent)?;
            }
            let mut out = fs::File::create(&dest)?;
            std::io::copy(&mut entry, &mut out)?;
            // Restore Unix executable bit if present
            #[cfg(unix)]
            if let Some(mode) = entry.unix_mode() {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&dest, fs::Permissions::from_mode(mode))?;
            }
        }
    }
    Ok(())
}

fn unpack_tar<R: std::io::Read>(
    reader: R,
    dest_dir: &Path,
    strip_components: u32,
) -> Result<(), DotError> {
    let mut archive = tar::Archive::new(reader);
    for entry in archive
        .entries()
        .map_err(|e| DotError::Archive(e.to_string()))?
    {
        let mut entry = entry.map_err(|e| DotError::Archive(e.to_string()))?;
        let path = entry.path().map_err(|e| DotError::Archive(e.to_string()))?;

        // Strip leading components
        let stripped: std::path::PathBuf =
            path.components().skip(strip_components as usize).collect();

        if stripped.as_os_str().is_empty() {
            continue;
        }

        let dest = dest_dir.join(&stripped);
        let header = entry.header();

        match header.entry_type() {
            tar::EntryType::Directory => {
                fs::create_dir_all(&dest)?;
            }
            tar::EntryType::Symlink => {
                if let Ok(Some(target)) = header.link_name() {
                    if let Some(parent) = dest.parent() {
                        fs::create_dir_all(parent)?;
                    }
                    #[cfg(unix)]
                    std::os::unix::fs::symlink(target, &dest)?;
                }
            }
            _ => {
                if let Some(parent) = dest.parent() {
                    fs::create_dir_all(parent)?;
                }
                entry
                    .unpack(&dest)
                    .map_err(|e| DotError::Archive(e.to_string()))?;
            }
        }
    }
    Ok(())
}

pub fn is_tar_gz(path: &Path) -> bool {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    name.ends_with(".tar.gz") || name.ends_with(".tgz")
}

pub fn is_tar_xz(path: &Path) -> bool {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    name.ends_with(".tar.xz")
}

pub fn is_zip(path: &Path) -> bool {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    name.ends_with(".zip")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::TempDir;

    fn make_tar_gz(dir: &std::path::Path, entries: &[(&str, &[u8])]) -> std::path::PathBuf {
        let path = dir.join("test.tar.gz");
        let file = fs::File::create(&path).unwrap();
        let enc = flate2::write::GzEncoder::new(file, flate2::Compression::default());
        let mut builder = tar::Builder::new(enc);
        for (name, data) in entries {
            let mut header = tar::Header::new_gnu();
            header.set_size(data.len() as u64);
            header.set_mode(0o644);
            header.set_cksum();
            builder.append_data(&mut header, name, *data).unwrap();
        }
        builder.finish().unwrap();
        path
    }

    fn make_tar_xz(dir: &std::path::Path, entries: &[(&str, &[u8])]) -> std::path::PathBuf {
        let path = dir.join("test.tar.xz");
        let file = fs::File::create(&path).unwrap();
        let enc = xz2::write::XzEncoder::new(file, 1);
        let mut builder = tar::Builder::new(enc);
        for (name, data) in entries {
            let mut header = tar::Header::new_gnu();
            header.set_size(data.len() as u64);
            header.set_mode(0o644);
            header.set_cksum();
            builder.append_data(&mut header, name, *data).unwrap();
        }
        builder.finish().unwrap();
        path
    }

    fn make_zip(dir: &std::path::Path, entries: &[(&str, &[u8])]) -> std::path::PathBuf {
        let path = dir.join("test.zip");
        let file = fs::File::create(&path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        for (name, data) in entries {
            zip.start_file(*name, options).unwrap();
            zip.write_all(data).unwrap();
        }
        zip.finish().unwrap();
        path
    }

    #[test]
    fn tar_gz_strip_0_preserves_path() {
        let tmp = TempDir::new().unwrap();
        let archive = make_tar_gz(tmp.path(), &[("topdir/tool", b"binary")]);
        let dest = tmp.path().join("out");
        extract_tar_gz(&archive, &dest, 0).unwrap();
        assert!(dest.join("topdir/tool").exists());
    }

    #[test]
    fn tar_gz_strip_1_removes_top_dir() {
        let tmp = TempDir::new().unwrap();
        let archive = make_tar_gz(tmp.path(), &[("topdir/tool", b"binary")]);
        let dest = tmp.path().join("out");
        extract_tar_gz(&archive, &dest, 1).unwrap();
        assert!(dest.join("tool").exists());
        assert!(!dest.join("topdir").exists());
    }

    #[test]
    fn tar_xz_strip_0_preserves_path() {
        let tmp = TempDir::new().unwrap();
        let archive = make_tar_xz(tmp.path(), &[("topdir/tool", b"binary")]);
        let dest = tmp.path().join("out");
        extract_tar_xz(&archive, &dest, 0).unwrap();
        assert!(dest.join("topdir/tool").exists());
    }

    #[test]
    fn tar_xz_strip_1_removes_top_dir() {
        let tmp = TempDir::new().unwrap();
        let archive = make_tar_xz(tmp.path(), &[("topdir/tool", b"binary")]);
        let dest = tmp.path().join("out");
        extract_tar_xz(&archive, &dest, 1).unwrap();
        assert!(dest.join("tool").exists());
        assert!(!dest.join("topdir").exists());
    }

    #[test]
    fn zip_extracts_single_file() {
        let tmp = TempDir::new().unwrap();
        let archive = make_zip(tmp.path(), &[("tool", b"binary")]);
        let dest = tmp.path().join("out");
        extract_zip(&archive, &dest).unwrap();
        assert!(dest.join("tool").exists());
    }
}
