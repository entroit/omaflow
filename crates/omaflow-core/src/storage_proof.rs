//! Root-owned storage ancestors verified before systemd enters its user namespace.
//!
//! A user service cannot distinguish host root from another unmapped account.
//! Its unsandboxed preflight records root-owned nodes in a private, per-invocation
//! file. The sandbox accepts only the same nodes, never an overflow UID alone.
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, File, Metadata, OpenOptions},
    io::{Read, Write},
    os::{
        fd::AsRawFd,
        unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    },
    path::{Component, Path, PathBuf},
};

const LIMIT: u64 = 64 * 1024;
const ROOT_LIMIT: usize = 256;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Root {
    path: PathBuf,
    device: u64,
    inode: u64,
    symlink: bool,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Record {
    invocation: String,
    roots: Vec<Root>,
}

pub(crate) struct Proof(Record);

fn invocation() -> Result<String, String> {
    let value = std::env::var("INVOCATION_ID")
        .map_err(|_| "storage preflight needs a systemd invocation ID".to_string())?;
    if value.len() != 32 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("storage preflight has an invalid systemd invocation ID".into());
    }
    Ok(value)
}

fn absolute(path: &Path) -> bool {
    path.is_absolute()
        && path
            .components()
            .all(|part| matches!(part, Component::RootDir | Component::Normal(_)))
}

fn filename(invocation: &str) -> String {
    format!("omaflow-storage-{invocation}.json")
}

fn runtime_directory(runtime: &Path) -> Result<File, String> {
    if !absolute(runtime) {
        return Err("storage preflight needs an absolute runtime directory".into());
    }
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(runtime)
        .map_err(|error| format!("could not open the storage proof directory: {error}"))?;
    let metadata = directory.metadata().map_err(|error| error.to_string())?;
    if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o077 != 0 {
        return Err("the storage proof directory must be private to this user".into());
    }
    Ok(directory)
}

fn anchored(directory: &File, invocation: &str) -> PathBuf {
    PathBuf::from(format!("/proc/self/fd/{}", directory.as_raw_fd())).join(filename(invocation))
}

fn identity_map(mapping: &str) -> bool {
    let mut next = 0_u64;
    for line in mapping.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() != 3 {
            return false;
        }
        let (Ok(inside), Ok(outside), Ok(count)) = (
            fields[0].parse::<u64>(),
            fields[1].parse::<u64>(),
            fields[2].parse::<u64>(),
        ) else {
            return false;
        };
        if inside != next || outside != inside || count == 0 {
            return false;
        }
        let Some(end) = next.checked_add(count) else {
            return false;
        };
        next = end;
    }
    next == u64::from(u32::MAX)
}

fn unmapped(uid: u32, mapping: &str) -> bool {
    let mut saw_mapping = false;
    for line in mapping.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() != 3 {
            return false;
        }
        let (Ok(start), Ok(_outside), Ok(count)) = (
            fields[0].parse::<u64>(),
            fields[1].parse::<u64>(),
            fields[2].parse::<u64>(),
        ) else {
            return false;
        };
        let Some(end) = start.checked_add(count) else {
            return false;
        };
        if count == 0 || end > u64::from(u32::MAX) {
            return false;
        }
        if u64::from(uid) >= start && u64::from(uid) < end {
            return false;
        }
        saw_mapping = true;
    }
    saw_mapping
}

fn collect(
    path: &Path,
    include_self: bool,
    roots: &mut BTreeMap<PathBuf, Root>,
) -> Result<(), String> {
    if !absolute(path) {
        return Err(format!(
            "{} is not an absolute storage path",
            path.display()
        ));
    }
    for ancestor in path.ancestors().skip(usize::from(!include_self)) {
        let metadata = match fs::symlink_metadata(ancestor) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(format!("could not inspect {}: {error}", ancestor.display())),
        };
        if metadata.uid() != 0 && metadata.uid() != unsafe { libc::geteuid() } {
            return Err(format!("{} belongs to another user", ancestor.display()));
        }
        if metadata.is_symlink() {
            collect(
                &ancestor.canonicalize().map_err(|error| error.to_string())?,
                true,
                roots,
            )?;
        } else if !metadata.is_dir()
            || (metadata.mode() & 0o022 != 0 && metadata.mode() & 0o1000 == 0)
        {
            return Err(format!(
                "{} permits replacement of private storage",
                ancestor.display()
            ));
        }
        if metadata.uid() == 0 {
            // A writable parent could recycle a recorded inode. Root-owned
            // /tmp itself is safe to record; nodes beneath it are not.
            for parent in ancestor.ancestors().skip(1) {
                let parent = fs::metadata(parent).map_err(|error| error.to_string())?;
                if parent.mode() & 0o022 != 0 {
                    return Err(format!("{} has a writable parent", ancestor.display()));
                }
            }
            roots.insert(
                ancestor.to_path_buf(),
                Root {
                    path: ancestor.to_path_buf(),
                    device: metadata.dev(),
                    inode: metadata.ino(),
                    symlink: metadata.is_symlink(),
                },
            );
            if roots.len() > ROOT_LIMIT {
                return Err("too many root-owned storage ancestors".into());
            }
        }
    }
    Ok(())
}

/// Called by ExecStartPre with systemd's `+` prefix, before user namespacing.
pub fn prepare(runtime: &Path, paths: &[PathBuf]) -> Result<(), String> {
    let invocation = invocation()?;
    let mapping = fs::read_to_string("/proc/self/uid_map").map_err(|error| error.to_string())?;
    if !identity_map(&mapping) {
        return Err("storage preflight must run outside a restricted user namespace".into());
    }
    let mut roots = BTreeMap::new();
    collect(runtime, false, &mut roots)?;
    for path in paths {
        collect(path, false, &mut roots)?;
    }
    let record = Record {
        invocation: invocation.clone(),
        roots: roots.into_values().collect(),
    };
    let bytes = serde_json::to_vec(&record).map_err(|error| error.to_string())?;
    if bytes.len() as u64 > LIMIT {
        return Err("the storage proof exceeds its size limit".into());
    }
    let directory = runtime_directory(runtime)?;
    let destination = anchored(&directory, &invocation);
    let mut temporary = tempfile::NamedTempFile::new_in(destination.parent().unwrap())
        .map_err(|error| error.to_string())?;
    temporary
        .as_file()
        .set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|error| error.to_string())?;
    temporary
        .write_all(&bytes)
        .and_then(|_| temporary.as_file().sync_all())
        .map_err(|error| error.to_string())?;
    temporary
        .persist(destination)
        .map_err(|error| error.error.to_string())?;
    Ok(())
}

impl Proof {
    pub(crate) fn load() -> Option<Self> {
        let invocation = invocation().ok()?;
        let runtime = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR")?);
        Self::read(&runtime, &invocation).ok()
    }

    fn read(runtime: &Path, invocation: &str) -> Result<Self, String> {
        let directory = runtime_directory(runtime)?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(anchored(&directory, invocation))
            .map_err(|error| error.to_string())?;
        let metadata = file.metadata().map_err(|error| error.to_string())?;
        if !metadata.is_file()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.nlink() != 1
            || metadata.mode() & 0o7777 != 0o600
            || metadata.len() > LIMIT
        {
            return Err("invalid private storage proof file".into());
        }
        let mut bytes = Vec::new();
        file.take(LIMIT + 1)
            .read_to_end(&mut bytes)
            .map_err(|error| error.to_string())?;
        if bytes.len() as u64 > LIMIT {
            return Err("the storage proof exceeds its size limit".into());
        }
        let record: Record =
            serde_json::from_slice(&bytes).map_err(|_| "invalid storage proof".to_string())?;
        if record.invocation != invocation
            || record.roots.len() > ROOT_LIMIT
            || record.roots.iter().any(|root| !absolute(&root.path))
        {
            return Err("storage proof does not match this invocation".into());
        }
        Ok(Self(record))
    }

    pub(crate) fn accepts(&self, path: &Path, metadata: &Metadata) -> bool {
        let Ok(overflow) = fs::read_to_string("/proc/sys/kernel/overflowuid") else {
            return false;
        };
        let Ok(overflow) = overflow.trim().parse::<u32>() else {
            return false;
        };
        let Ok(mapping) = fs::read_to_string("/proc/self/uid_map") else {
            return false;
        };
        metadata.uid() == overflow
            && unsafe { libc::geteuid() } != overflow
            && unmapped(overflow, &mapping)
            && self.matches(path, metadata)
            && self.immutable_parents(path, overflow)
    }

    fn matches(&self, path: &Path, metadata: &Metadata) -> bool {
        self.0.roots.iter().any(|root| {
            root.path == path
                && root.device == metadata.dev()
                && root.inode == metadata.ino()
                && root.symlink == metadata.is_symlink()
                && (metadata.is_dir() || metadata.is_symlink())
        })
    }

    fn immutable_parents(&self, path: &Path, overflow: u32) -> bool {
        for parent in path.ancestors().skip(1) {
            let Ok(metadata) = fs::symlink_metadata(parent) else {
                return false;
            };
            if metadata.uid() != 0
                && metadata.uid() != unsafe { libc::geteuid() }
                && !(metadata.uid() == overflow && self.matches(parent, &metadata))
            {
                return false;
            }
            if metadata.is_symlink() {
                let Ok(resolved) = parent.canonicalize() else {
                    return false;
                };
                // Include the resolved directory itself in the immutable chain.
                if !self.immutable_parents(&resolved.join(".omaflow-storage-proof"), overflow) {
                    return false;
                }
            } else if !metadata.is_dir() || metadata.mode() & 0o022 != 0 {
                return false;
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const INVOCATION: &str = "0123456789abcdef0123456789abcdef";

    fn record(path: &Path) -> Record {
        let metadata = fs::symlink_metadata(path).unwrap();
        Record {
            invocation: INVOCATION.into(),
            roots: vec![Root {
                path: path.into(),
                device: metadata.dev(),
                inode: metadata.ino(),
                symlink: metadata.is_symlink(),
            }],
        }
    }

    fn write_record(runtime: &Path, record: &Record) -> PathBuf {
        fs::set_permissions(runtime, fs::Permissions::from_mode(0o700)).unwrap();
        let path = runtime.join(filename(INVOCATION));
        fs::write(&path, serde_json::to_vec(record).unwrap()).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        path
    }

    #[test]
    fn proof_reads_reject_missing_stale_malformed_and_oversized_records() {
        let runtime = tempfile::tempdir().unwrap();
        assert!(Proof::read(runtime.path(), INVOCATION).is_err());
        let mut value = record(Path::new("/"));
        let path = write_record(runtime.path(), &value);
        assert!(Proof::read(runtime.path(), INVOCATION).is_ok());
        value.invocation = "fedcba9876543210fedcba9876543210".into();
        write_record(runtime.path(), &value);
        assert!(Proof::read(runtime.path(), INVOCATION).is_err());
        fs::write(&path, b"{broken").unwrap();
        assert!(Proof::read(runtime.path(), INVOCATION).is_err());
        fs::write(&path, vec![b' '; LIMIT as usize + 1]).unwrap();
        assert!(Proof::read(runtime.path(), INVOCATION).is_err());
        value = record(Path::new("/"));
        value.roots[0].path = PathBuf::from("/home/../tmp");
        write_record(runtime.path(), &value);
        assert!(Proof::read(runtime.path(), INVOCATION).is_err());
    }

    #[test]
    fn proof_reads_reject_links_shared_files_and_shared_runtime_directories() {
        let runtime = tempfile::tempdir().unwrap();
        let path = write_record(runtime.path(), &record(Path::new("/")));
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(Proof::read(runtime.path(), INVOCATION).is_err());
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let target = runtime.path().join("target");
        fs::hard_link(&path, &target).unwrap();
        assert!(Proof::read(runtime.path(), INVOCATION).is_err());
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(&target, &path).unwrap();
        assert!(Proof::read(runtime.path(), INVOCATION).is_err());
        fs::remove_file(&path).unwrap();
        fs::rename(&target, &path).unwrap();
        fs::set_permissions(runtime.path(), fs::Permissions::from_mode(0o755)).unwrap();
        assert!(Proof::read(runtime.path(), INVOCATION).is_err());
    }

    #[test]
    fn proof_matches_the_recorded_node_and_not_its_replacement() {
        let runtime = tempfile::tempdir().unwrap();
        let path = runtime.path().join("ancestor");
        fs::create_dir(&path).unwrap();
        let proof = Proof(record(&path));
        assert!(proof.matches(&path, &fs::symlink_metadata(&path).unwrap()));
        fs::rename(&path, runtime.path().join("old-ancestor")).unwrap();
        fs::create_dir(&path).unwrap();
        assert!(!proof.matches(&path, &fs::symlink_metadata(&path).unwrap()));
    }

    #[test]
    fn sticky_parents_cannot_preserve_root_inode_proofs() {
        let runtime = tempfile::tempdir().unwrap();
        let path = runtime.path().join("ancestor");
        fs::create_dir(&path).unwrap();
        let proof = Proof(record(&path));
        fs::set_permissions(runtime.path(), fs::Permissions::from_mode(0o1777)).unwrap();
        assert!(!proof.immutable_parents(&path, 65534));
        let link = runtime.path().join("linked");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(!proof.immutable_parents(&link.join("child"), 65534));
    }

    #[test]
    fn only_host_identity_maps_issue_proofs_and_only_unmapped_uids_consume_them() {
        assert!(identity_map("0 0 4294967295\n"));
        assert!(identity_map("0 0 65534\n65534 65534 4294901761\n"));
        assert!(!identity_map("1000 1000 1\n"));
        assert!(!identity_map("0 1000 1\n"));
        assert!(!identity_map(""));
        assert!(unmapped(65534, "1000 1000 1\n"));
        assert!(!unmapped(65534, "0 0 4294967295\n"));
        assert!(!unmapped(65534, "1000 1000 1\n65534 1001 1\n"));
        assert!(!unmapped(65534, ""));
        assert!(!unmapped(65534, "0 0 18446744073709551615\n"));
    }
}
