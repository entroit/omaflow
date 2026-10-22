//! File helpers shared by settings, history, the journal and the to-dos.
use std::{
    fs,
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
};

pub const DOCUMENT_LIMIT: u64 = 8 * 1024 * 1024;

/// Holds the parent directory open while an operation uses its final name.
/// Only the selected root may be a symlink; its descendants are opened relative
/// to directory descriptors with O_NOFOLLOW.
pub(crate) struct AnchoredPath {
    _directory: fs::File,
    path: PathBuf,
}

impl AsRef<Path> for AnchoredPath {
    fn as_ref(&self) -> &Path {
        &self.path
    }
}

impl AnchoredPath {
    fn new(directory: fs::File, name: &std::ffi::OsStr) -> Self {
        let path = PathBuf::from(format!("/proc/self/fd/{}", directory.as_raw_fd())).join(name);
        Self {
            _directory: directory,
            path,
        }
    }
}

pub(crate) fn anchored(root: &Path, path: &Path, create: bool) -> io::Result<AnchoredPath> {
    anchored_with(root, path, create, None)
}

fn anchored_with(
    root: &Path,
    path: &Path,
    create: bool,
    mut made: Option<&mut Made>,
) -> io::Result<AnchoredPath> {
    let relative = path.strip_prefix(root).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "path is outside its selected folder",
        )
    })?;
    let components: Vec<_> = relative.components().collect();
    if components.is_empty()
        || components
            .iter()
            .any(|part| !matches!(part, std::path::Component::Normal(_)))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid path inside selected folder",
        ));
    }
    if create {
        fs::create_dir_all(root)?;
    }
    let mut directory = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY)
        .open(root)?;
    for component in &components[..components.len() - 1] {
        let name = std::ffi::CString::new(component.as_os_str().as_encoded_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid file name"))?;
        if create {
            // SAFETY: the directory descriptor and terminated name remain live.
            let result = unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) };
            if result != 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::AlreadyExists {
                    return Err(error);
                }
            } else if let Some(made) = made.as_mut() {
                made.folders.push(AnchoredPath::new(
                    directory.try_clone()?,
                    component.as_os_str(),
                ));
            }
        }
        // SAFETY: openat returns a fresh descriptor or -1; no symlink is followed.
        let descriptor = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW,
            )
        };
        if descriptor < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: ownership of this successful openat result moves into File once.
        directory = unsafe { fs::File::from_raw_fd(descriptor) };
        if create {
            let _ = directory.set_permissions(fs::Permissions::from_mode(0o700));
        }
    }
    Ok(AnchoredPath::new(
        directory,
        components.last().unwrap().as_os_str(),
    ))
}

pub fn open_regular_at(root: &Path, path: &Path) -> io::Result<fs::File> {
    open_regular(anchored(root, path, false)?.as_ref())
}

pub(crate) fn directory_names(root: &Path, path: &Path) -> io::Result<Vec<std::ffi::OsString>> {
    let directory = anchored(root, &path.join(".entries"), false)?;
    fs::read_dir(directory.path.parent().unwrap())?
        .map(|entry| entry.map(|entry| entry.file_name()))
        .collect()
}

pub(crate) fn read_document_at(root: &Path, path: impl AsRef<Path>) -> io::Result<Vec<u8>> {
    read_document(anchored(root, path.as_ref(), false)?)
}

pub(crate) fn read_text_at(root: &Path, path: impl AsRef<Path>) -> io::Result<String> {
    read_text(anchored(root, path.as_ref(), false)?)
}

pub(crate) fn write_owned_at(root: &Path, path: &Path, bytes: &[u8]) -> Result<(), String> {
    let anchored =
        anchored(root, path, true).map_err(|error| format!("{}: {error}", path.display()))?;
    write_owned(anchored.as_ref(), bytes)
}

pub(crate) fn write_document_at(root: &Path, path: &Path, bytes: &[u8]) -> Result<(), String> {
    let anchored =
        anchored(root, path, true).map_err(|error| format!("{}: {error}", path.display()))?;
    write_document(anchored.as_ref(), bytes)
}

pub(crate) fn lock_at(root: &Path, path: &Path) -> Result<fs::File, String> {
    let anchored =
        anchored(root, path, true).map_err(|error| format!("{}: {error}", path.display()))?;
    lock(anchored.as_ref())
}

pub(crate) fn rename_at(root: &Path, from: &Path, to: &Path) -> io::Result<()> {
    let from = anchored(root, from, false)?;
    let to = anchored(root, to, true)?;
    fs::rename(from, to)
}

pub(crate) fn remove_file_at(root: &Path, path: &Path) -> io::Result<()> {
    fs::remove_file(anchored(root, path, false)?)
}

pub(crate) fn remove_dir_at(root: &Path, path: &Path) -> io::Result<()> {
    fs::remove_dir_all(anchored(root, path, false)?)
}

pub(crate) fn remove_empty_dir_at(root: &Path, path: &Path) -> io::Result<()> {
    fs::remove_dir(anchored(root, path, false)?)
}

/// Opens a regular input file without following its final path component.
/// Nonblocking open prevents a planted FIFO from holding the caller forever.
pub fn open_regular(path: &Path) -> io::Result<fs::File> {
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "expected a regular file",
        ));
    }
    Ok(file)
}

pub fn read_limited(path: &Path, limit: u64) -> io::Result<Vec<u8>> {
    let file = open_regular(path)?;
    if file.metadata()?.len() > limit {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("file exceeds the {limit}-byte limit"),
        ));
    }
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("file exceeds the {limit}-byte limit"),
        ));
    }
    Ok(bytes)
}

pub fn read_document(path: impl AsRef<Path>) -> io::Result<Vec<u8>> {
    read_limited(path.as_ref(), DOCUMENT_LIMIT)
}

pub fn read_text(path: impl AsRef<Path>) -> io::Result<String> {
    String::from_utf8(read_document(path)?)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "file is not UTF-8 text"))
}

pub(crate) fn write_document(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if bytes.len() as u64 > DOCUMENT_LIMIT {
        return Err("The document exceeds the 8 MiB limit".into());
    }
    write_owned(path, bytes)
}

/// Shared-folder edits wait briefly for another OmaFlow writer, never forever.
pub(crate) fn lock(path: &Path) -> Result<fs::File, String> {
    let file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|error| format!("could not open {}: {error}", path.display()))?;
    if !file
        .metadata()
        .map_err(|error| error.to_string())?
        .is_file()
    {
        return Err(format!("{} must be a regular file", path.display()));
    }
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    loop {
        match file.try_lock() {
            Ok(()) => return Ok(file),
            Err(std::fs::TryLockError::WouldBlock) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(std::fs::TryLockError::WouldBlock) => {
                return Err("Another writer is still using this folder. Try again shortly.".into());
            }
            Err(std::fs::TryLockError::Error(error)) => {
                return Err(format!("could not lock {}: {error}", path.display()));
            }
        }
    }
}

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

/// Opens an existing private file for in-place updates without following links.
pub fn open_private(path: &Path) -> Result<fs::File, String> {
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|error| format!("could not open {}: {error}", path.display()))?;
    check_private_file(&file, path)?;
    Ok(file)
}

/// Appends bytes only to an owner-held regular file with no other links.
pub fn append_private(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", path.display()))?;
    private_dir(parent)?;
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|error| format!("could not open {}: {error}", path.display()))?;
    check_private_file(&file, path)?;
    file.write_all(bytes)
        .map_err(|error| format!("could not append {}: {error}", path.display()))
}

fn check_private_file(file: &fs::File, path: &Path) -> Result<(), String> {
    let metadata = file
        .metadata()
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.mode() & 0o077 != 0
        || metadata.uid() != unsafe { libc::geteuid() }
    {
        return Err(format!(
            "{} must be an owner-only regular file with one link",
            path.display()
        ));
    }
    Ok(())
}

fn write_atomic(path: &Path, bytes: &[u8], strict: bool) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", path.display()))?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("could not create {}: {error}", parent.display()))?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent).map_err(|error| {
        format!(
            "could not create a temporary file in {}: {error}",
            parent.display()
        )
    })?;
    if let Err(error) = temporary
        .as_file()
        .set_permissions(fs::Permissions::from_mode(0o600))
        && strict
    {
        return Err(format!(
            "could not protect {}: {error}",
            temporary.path().display()
        ));
    }
    temporary
        .write_all(bytes)
        .and_then(|_| temporary.as_file().sync_all())
        .map_err(|error| format!("{}: {error}", temporary.path().display()))?;
    temporary
        .persist(path)
        .map(|_| ())
        .map_err(|error| format!("could not replace {}: {}", path.display(), error.error))
}

/// Creates `path` and makes it private to the owner.
pub fn private_dir(path: &Path) -> Result<(), String> {
    check_private_ancestors(path)?;
    fs::create_dir_all(path)
        .map_err(|error| format!("could not create {}: {error}", path.display()))?;
    let directory = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY)
        .open(path)
        .map_err(|error| {
            format!(
                "could not open private directory {}: {error}",
                path.display()
            )
        })?;
    let metadata = directory.metadata().map_err(|error| error.to_string())?;
    if metadata.uid() != unsafe { libc::geteuid() } {
        return Err(format!("{} belongs to another user", path.display()));
    }
    if metadata.mode() & 0o022 != 0 {
        return Err(format!("{} is writable by another user", path.display()));
    }
    directory
        .set_permissions(fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("could not protect {}: {error}", path.display()))
}

fn check_private_ancestors(path: &Path) -> Result<(), String> {
    let mut proof = None;
    check_private_ancestors_with(path, &mut proof)
}

fn check_private_ancestors_with(
    path: &Path,
    proof: &mut Option<Option<crate::storage_proof::Proof>>,
) -> Result<(), String> {
    let trusted = |path: &Path,
                   metadata: &fs::Metadata,
                   proof: &mut Option<Option<crate::storage_proof::Proof>>| {
        metadata.uid() == 0
            || metadata.uid() == unsafe { libc::geteuid() }
            || proof
                .get_or_insert_with(crate::storage_proof::Proof::load)
                .as_ref()
                .is_some_and(|proof| proof.accepts(path, metadata))
    };
    for ancestor in path.ancestors().skip(1) {
        let mut metadata = match fs::symlink_metadata(ancestor) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(format!("could not inspect {}: {error}", ancestor.display())),
        };
        let mut inspected = ancestor.to_path_buf();
        if metadata.is_symlink() {
            if !trusted(ancestor, &metadata, proof) {
                return Err(format!("{} belongs to another user", ancestor.display()));
            }
            let resolved = ancestor.canonicalize().map_err(|error| error.to_string())?;
            check_private_ancestors_with(&resolved, proof)?;
            metadata = fs::metadata(&resolved).map_err(|error| error.to_string())?;
            inspected = resolved;
        }
        let trusted_owner = trusted(&inspected, &metadata, proof);
        let replaceable = metadata.mode() & 0o022 != 0 && metadata.mode() & 0o1000 == 0;
        if !trusted_owner || replaceable {
            return Err(format!(
                "{} permits another user to replace private storage",
                ancestor.display()
            ));
        }
    }
    Ok(())
}

/// Folders and files a move created, so a failed one can take them back.
#[derive(Default)]
pub(crate) struct Made {
    roots: Vec<PathBuf>,
    folders: Vec<AnchoredPath>,
    files: Vec<AnchoredPath>,
}

impl Made {
    /// The selected destination keeps its existing permissions.
    fn root(&mut self, path: &Path) -> Result<(), String> {
        let missing: Vec<PathBuf> = path
            .ancestors()
            .take_while(|folder| !folder.exists())
            .map(Path::to_path_buf)
            .collect();
        for folder in missing.into_iter().rev() {
            fs::create_dir(&folder)
                .map_err(|error| format!("could not create {}: {error}", folder.display()))?;
            self.roots.push(folder);
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
        for folder in self.roots.iter().rev() {
            let _ = fs::remove_dir(folder);
        }
    }
}

/// Copies each file to where it goes, never over an existing one, and reads
/// each copy back to make sure it holds the same bytes.
pub(crate) fn copy_all<'a>(
    files: impl IntoIterator<Item = (&'a Path, &'a Path)>,
    source: &Path,
    destination: &Path,
    made: &mut Made,
) -> Result<(), String> {
    for (from, to) in files {
        // One hour of 16 kHz mono recording fits below this bound.
        let source_path = anchored(source, from, false)
            .map_err(|error| format!("could not read {}: {error}", from.display()))?;
        let bytes = read_limited(source_path.as_ref(), 128 * 1024 * 1024)
            .map_err(|error| format!("could not read {}: {error}", from.display()))?;
        made.root(destination)?;
        let target = anchored_with(destination, to, true, Some(made))
            .map_err(|error| format!("could not create {}: {error}", to.display()))?;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&target)
            .map_err(|error| format!("could not create {}: {error}", to.display()))?;
        made.files.push(target);
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|error| format!("could not write {}: {error}", to.display()))?;
        let matches = read_limited(made.files.last().unwrap().as_ref(), 128 * 1024 * 1024)
            .ok()
            .as_deref()
            == Some(&bytes[..]);
        if !matches {
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
        if let Err(error) = remove_file_at(folder, from) {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anchored_io_keeps_the_open_directory_after_its_name_is_replaced() {
        let base = tempfile::tempdir().unwrap();
        let folder = base.path().join("journal");
        let outside = base.path().join("outside");
        fs::create_dir_all(folder.join(".omaflow")).unwrap();
        fs::create_dir(&outside).unwrap();
        fs::write(outside.join("day.json"), "private outside content").unwrap();
        let anchored = anchored(&folder, &folder.join(".omaflow/day.json"), true).unwrap();
        fs::rename(folder.join(".omaflow"), folder.join("original")).unwrap();
        std::os::unix::fs::symlink(&outside, folder.join(".omaflow")).unwrap();
        write_owned(anchored.as_ref(), b"saved metadata").unwrap();
        assert_eq!(
            fs::read(folder.join("original/day.json")).unwrap(),
            b"saved metadata"
        );
        assert_eq!(
            fs::read(outside.join("day.json")).unwrap(),
            b"private outside content"
        );
        assert!(read_document_at(&folder, folder.join(".omaflow/day.json")).is_err());
    }

    #[test]
    fn bounded_inputs_reject_links_fifos_and_oversized_files() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("document");
        fs::write(&path, "private source").unwrap();
        let link = directory.path().join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(read_text(&link).is_err());
        assert!(read_limited(&path, 3).is_err());
        let fifo = directory.path().join("fifo");
        let name = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: name is a live, terminated path in this test's private directory.
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        assert!(read_text(&fifo).is_err());
        assert!(lock(&fifo).is_err());
        assert!(lock(&link).is_err());
        let folder_link = directory.path().join("folder-link");
        std::os::unix::fs::symlink(directory.path(), &folder_link).unwrap();
        assert_eq!(
            read_text(folder_link.join("document")).unwrap(),
            "private source"
        );
    }

    #[test]
    fn a_shared_folder_lock_times_out_then_recovers_when_released() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("lock");
        let first = lock(&path).unwrap();
        let started = std::time::Instant::now();
        assert!(lock(&path).is_err());
        assert!(started.elapsed() < std::time::Duration::from_secs(3));
        drop(first);
        assert!(lock(&path).is_ok());
    }

    #[test]
    fn private_appends_refuse_links_and_leave_targets_and_permissions_unchanged() {
        for symbolic in [false, true] {
            let directory = tempfile::tempdir().unwrap();
            let target = directory.path().join("shared.txt");
            fs::write(&target, b"keep this file").unwrap();
            fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
            let path = directory.path().join("training.jsonl");
            if symbolic {
                std::os::unix::fs::symlink(&target, &path).unwrap();
            } else {
                fs::hard_link(&target, &path).unwrap();
            }

            assert!(append_private(&path, b"private transcript\n").is_err());
            assert!(open_private(&path).is_err());
            assert_eq!(fs::read(&target).unwrap(), b"keep this file");
            assert_eq!(
                fs::metadata(&target).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn private_directories_refuse_symlinks_without_changing_target_permissions() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("shared");
        fs::create_dir(&target).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o755)).unwrap();
        let path = directory.path().join("runtime");
        std::os::unix::fs::symlink(&target, &path).unwrap();

        assert!(private_dir(&path).is_err());
        assert_eq!(
            fs::metadata(&target).unwrap().permissions().mode() & 0o777,
            0o755
        );
    }

    #[test]
    fn private_appends_refuse_files_other_users_could_already_have_open() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("training.jsonl");
        fs::write(&path, b"existing public data\n").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        let mut reader = fs::File::open(&path).unwrap();

        assert!(append_private(&path, b"private transcript\n").is_err());
        let mut bytes = Vec::new();
        std::io::Read::read_to_end(&mut reader, &mut bytes).unwrap();
        assert_eq!(bytes, b"existing public data\n");
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o644
        );
    }

    #[test]
    fn private_directories_refuse_ancestors_other_users_can_replace() {
        let directory = tempfile::tempdir().unwrap();
        let shared = directory.path().join("shared");
        fs::create_dir(&shared).unwrap();
        fs::set_permissions(&shared, fs::Permissions::from_mode(0o777)).unwrap();
        let path = shared.join("runtime");

        assert!(private_dir(&path).is_err());
        assert!(!path.exists());
        assert_eq!(
            fs::metadata(&shared).unwrap().permissions().mode() & 0o777,
            0o777
        );
    }

    #[test]
    fn private_directories_refuse_existing_shared_contents() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("runtime");
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o777)).unwrap();
        fs::write(path.join("planted"), b"untrusted").unwrap();

        assert!(private_dir(&path).is_err());
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o777
        );
        assert_eq!(fs::read(path.join("planted")).unwrap(), b"untrusted");
    }

    #[test]
    fn atomic_writes_leave_preexisting_temporary_hardlinks_untouched() {
        for write in [write_private, write_owned] {
            let directory = tempfile::tempdir().unwrap();
            let private = directory.path().join("config.toml");
            fs::write(&private, "private settings").unwrap();
            let destination = directory.path().join("day.md");
            fs::hard_link(&private, directory.path().join("day.md.tmp")).unwrap();

            write(&destination, b"first entry").unwrap();
            write(&destination, b"second entry").unwrap();

            assert_eq!(fs::read(&private).unwrap(), b"private settings");
            assert_eq!(fs::read(&destination).unwrap(), b"second entry");
            assert_eq!(
                fs::metadata(&destination).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn replacing_a_destination_symlink_does_not_write_to_its_target() {
        let directory = tempfile::tempdir().unwrap();
        let private = directory.path().join("config.toml");
        fs::write(&private, "private settings").unwrap();
        let destination = directory.path().join("day.md");
        std::os::unix::fs::symlink(&private, &destination).unwrap();

        write_owned(&destination, b"journal entry").unwrap();

        assert_eq!(fs::read(&private).unwrap(), b"private settings");
        assert_eq!(fs::read(&destination).unwrap(), b"journal entry");
        assert!(!destination.is_symlink());
    }

    #[test]
    fn a_failed_replacement_preserves_the_destination_and_removes_the_temporary_file() {
        let directory = tempfile::tempdir().unwrap();
        let destination = directory.path().join("day.md");
        fs::create_dir(&destination).unwrap();
        let existing = destination.join("existing.md");
        fs::write(&existing, "keep this entry").unwrap();

        assert!(write_owned(&destination, b"new entry").is_err());

        assert_eq!(fs::read(&existing).unwrap(), b"keep this entry");
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 1);
    }
}
