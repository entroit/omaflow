//! Small file helpers shared by the history and the journal.
use std::{
    fs,
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::Path,
};

/// Replaces `path` with `bytes` in one step, readable by the owner only. A
/// crash leaves either the old file or the new one, never half of each.
pub fn write_private(path: &Path, bytes: &[u8]) -> Result<(), String> {
    write_atomic(path, bytes, true)
}

/// Like `write_private`, for folders the user chose: owner-only where the
/// filesystem supports it, but a USB stick or network share that refuses
/// permissions still gets the file.
pub fn write_owned(path: &Path, bytes: &[u8]) -> Result<(), String> {
    write_atomic(path, bytes, false)
}

fn write_atomic(path: &Path, bytes: &[u8], strict: bool) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", path.display()))?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("could not create {}: {error}", parent.display()))?;
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let temporary = parent.join(format!("{name}.tmp"));
    let mut file = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|error| format!("{}: {error}", temporary.display()))?;
    if let Err(error) = file.set_permissions(fs::Permissions::from_mode(0o600))
        && strict
    {
        return Err(format!(
            "could not protect {}: {error}",
            temporary.display()
        ));
    }
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|error| format!("{}: {error}", temporary.display()))?;
    fs::rename(&temporary, path)
        .map_err(|error| format!("{} -> {}: {error}", temporary.display(), path.display()))
}

/// Creates `path` and makes it private to the owner.
pub fn private_dir(path: &Path) -> Result<(), String> {
    fs::create_dir_all(path)
        .map_err(|error| format!("could not create {}: {error}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("could not protect {}: {error}", path.display()))
}

/// Creates `path` and makes it private where the filesystem allows.
pub fn owned_dir(path: &Path) -> Result<(), String> {
    fs::create_dir_all(path)
        .map_err(|error| format!("could not create {}: {error}", path.display()))?;
    let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o700));
    Ok(())
}
