//! Small file helpers shared by the history, the journal and the to-dos.
use std::{
    fs,
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
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

/// Folders and files a move created, so a failed one can take them back.
#[derive(Default)]
pub(crate) struct Made {
    folders: Vec<PathBuf>,
    files: Vec<PathBuf>,
}

impl Made {
    /// Creates `path` and any folder above it that is missing. OmaFlow's
    /// own hidden folders are made private, like `owned_dir` does; the
    /// folder you chose keeps the permissions it gets.
    fn folder(&mut self, path: &Path, destination: &Path) -> Result<(), String> {
        let missing: Vec<PathBuf> = path
            .ancestors()
            .take_while(|folder| !folder.exists())
            .map(Path::to_path_buf)
            .collect();
        for folder in missing.into_iter().rev() {
            fs::create_dir(&folder)
                .map_err(|error| format!("could not create {}: {error}", folder.display()))?;
            if folder != destination && folder.starts_with(destination) {
                let _ = fs::set_permissions(&folder, fs::Permissions::from_mode(0o700));
            }
            self.folders.push(folder);
        }
        Ok(())
    }

    pub(crate) fn undo(self) {
        for file in self.files.iter().rev() {
            let _ = fs::remove_file(file);
        }
        for folder in self.folders.iter().rev() {
            let _ = fs::remove_dir(folder);
        }
    }
}

/// Copies each file to where it goes, never over an existing one, and reads
/// each copy back to make sure it holds the same bytes.
pub(crate) fn copy_all<'a>(
    files: impl IntoIterator<Item = (&'a Path, &'a Path)>,
    destination: &Path,
    made: &mut Made,
) -> Result<(), String> {
    for (from, to) in files {
        let bytes = fs::read(from)
            .map_err(|error| format!("could not read {}: {error}", from.display()))?;
        if let Some(parent) = to.parent() {
            made.folder(parent, destination)?;
        }
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(to)
            .map_err(|error| format!("could not create {}: {error}", to.display()))?;
        made.files.push(to.to_path_buf());
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|error| format!("could not write {}: {error}", to.display()))?;
        if fs::read(to).ok().as_deref() != Some(&bytes[..]) {
            return Err(format!("{} did not read back the same", to.display()));
        }
    }
    Ok(())
}

/// Removes the originals of a move whose copies are all in place, and names
/// the ones that would not go, relative to `folder`. A file left behind is
/// still a copy, never a loss.
pub(crate) fn remove_moved<'a>(
    originals: impl IntoIterator<Item = &'a Path>,
    folder: &Path,
) -> Vec<String> {
    let mut stuck = Vec::new();
    for from in originals {
        if let Err(error) = fs::remove_file(from) {
            eprintln!("omaflow: could not remove {}: {error}", from.display());
            let name = from.strip_prefix(folder).unwrap_or(from);
            stuck.push(name.display().to_string());
        }
    }
    stuck
}

/// True when both paths name the same folder, written differently or not.
pub(crate) fn same_folder(one: &Path, other: &Path) -> bool {
    one == other
        || matches!(
            (one.canonicalize(), other.canonicalize()),
            (Ok(one), Ok(other)) if one == other
        )
}
