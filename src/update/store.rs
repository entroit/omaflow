use serde::{Serialize, de::DeserializeOwned};
use std::{
    fs::{File, OpenOptions},
    io::Write,
    os::{
        fd::AsRawFd,
        unix::fs::{FileExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
};

pub fn update_dir() -> PathBuf {
    crate::state_dir().join("update")
}

pub fn offer_path() -> PathBuf {
    update_dir().join("offer.json")
}

pub fn transaction_path() -> PathBuf {
    update_dir().join("transaction.json")
}

pub fn installed_path() -> PathBuf {
    update_dir().join("installed.json")
}

pub fn notification_path() -> PathBuf {
    update_dir().join("notification.json")
}

pub fn deferral_path() -> PathBuf {
    update_dir().join("deferral.json")
}

pub fn read<T: DeserializeOwned>(path: &Path, limit: usize) -> Result<Option<T>, String> {
    let bytes = match omaflow_core::fsutil::read_limited(path, limit as u64) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("could not read {}: {error}", path.display())),
    };
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|error| format!("could not parse {}: {error}", path.display()))
}

pub fn replace<T: Serialize>(path: &Path, value: &T) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("{} has no parent", path.display()))?;
    omaflow_core::fsutil::private_dir(parent)?;
    let bytes = serde_json::to_vec(value).map_err(|error| error.to_string())?;
    omaflow_core::fsutil::write_private(path, &bytes)?;
    File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| format!("could not sync {}: {error}", parent.display()))
}

pub struct UpdateLock {
    _file: File,
}

fn lock_path() -> PathBuf {
    update_dir().join("runner.lock")
}

/// The kernel releases the lock when its holder exits, including after a crash.
pub fn runner_alive() -> bool {
    holder_alive(&lock_path())
}

fn legacy_holder_alive(file: &File) -> bool {
    let mut bytes = [0; 64];
    file.read_at(&mut bytes, 0)
        .ok()
        .and_then(|count| std::str::from_utf8(&bytes[..count]).ok())
        .and_then(|value| value.trim().parse::<u32>().ok())
        .is_some_and(|pid| Path::new("/proc").join(pid.to_string()).exists())
}

fn try_lock(file: &File) -> Result<bool, String> {
    // SAFETY: flock acts only on this open descriptor and touches no memory.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        return Ok(true);
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::WouldBlock {
        Ok(false)
    } else {
        Err(format!("could not lock the updater: {error}"))
    }
}

fn holder_alive(path: &Path) -> bool {
    let Ok(file) = omaflow_core::fsutil::open_private(path) else {
        return false;
    };
    !matches!(try_lock(&file), Ok(true)) || legacy_holder_alive(&file)
}

impl UpdateLock {
    pub fn acquire() -> Result<Self, String> {
        Self::acquire_at(&lock_path())
    }

    fn acquire_at(path: &Path) -> Result<Self, String> {
        let parent = path.parent().ok_or("the update lock has no parent")?;
        omaflow_core::fsutil::private_dir(parent)?;
        let mut file = match OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                omaflow_core::fsutil::open_private(path)?
            }
            Err(error) => return Err(format!("could not create {}: {error}", path.display())),
        };
        if !try_lock(&file)? || legacy_holder_alive(&file) {
            return Err("another OmaFlow update is already running".into());
        }
        // A live old updater still owns a numeric PID file. Migrate only after
        // it exits; new holders use flock and never unlink the shared inode.
        file.set_len(0).map_err(|error| error.to_string())?;
        file.write_all(b"flock\n")
            .map_err(|error| error.to_string())?;
        Ok(Self { _file: file })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::{fs, os::unix::fs::PermissionsExt};

    fn lock_directory() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "omaflow-lock-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&path).unwrap();
        path
    }

    #[test]
    fn atomic_store_replaces_a_complete_json_value() {
        let directory = std::env::temp_dir().join(format!("omaflow-store-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        let path = directory.join("state.json");
        replace(&path, &json!({"state":"queued"})).unwrap();
        replace(&path, &json!({"state":"succeeded"})).unwrap();
        let value: serde_json::Value = read(&path, 1024).unwrap().unwrap();
        assert_eq!(value, json!({"state":"succeeded"}));
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn update_state_reads_refuse_pipes_links_and_oversized_files() {
        let directory = lock_directory();
        let path = directory.join("transaction.json");
        assert!(
            std::process::Command::new("mkfifo")
                .arg(&path)
                .status()
                .unwrap()
                .success()
        );
        let (sender, receiver) = std::sync::mpsc::channel();
        let pipe = path.clone();
        std::thread::spawn(move || sender.send(read::<serde_json::Value>(&pipe, 256)).unwrap());
        assert!(
            receiver
                .recv_timeout(std::time::Duration::from_secs(1))
                .expect("the update reader blocked on a FIFO")
                .is_err()
        );
        fs::remove_file(&path).unwrap();
        let target = directory.join("target.json");
        fs::write(&target, b"{}").unwrap();
        std::os::unix::fs::symlink(&target, &path).unwrap();
        assert!(read::<serde_json::Value>(&path, 256).is_err());
        fs::remove_file(&path).unwrap();
        fs::write(&path, b"{}  ").unwrap();
        assert!(read::<serde_json::Value>(&path, 3).is_err());
        assert_eq!(
            read::<serde_json::Value>(&path, 4).unwrap(),
            Some(json!({}))
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn legacy_live_pid_blocks_until_exit_and_stale_files_recover() {
        let directory = lock_directory();
        let path = directory.join("runner.lock");
        assert!(!holder_alive(&path));
        let mut child = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .unwrap();
        fs::write(&path, format!("{}\n", child.id())).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(holder_alive(&path));
        assert!(UpdateLock::acquire_at(&path).is_err());
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(!holder_alive(&path));
        for contents in [fs::read(&path).unwrap(), Vec::new()] {
            fs::write(&path, contents).unwrap();
            let lock = UpdateLock::acquire_at(&path).unwrap();
            assert!(holder_alive(&path));
            assert!(UpdateLock::acquire_at(&path).is_err());
            drop(lock);
            assert!(path.is_file());
            assert!(!holder_alive(&path));
        }
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn concurrent_update_callers_never_hold_the_lock_together() {
        use std::sync::{
            Arc, Barrier,
            atomic::{AtomicUsize, Ordering},
        };
        let directory = lock_directory();
        let path = Arc::new(directory.join("runner.lock"));
        let barrier = Arc::new(Barrier::new(8));
        let holders = Arc::new(AtomicUsize::new(0));
        std::thread::scope(|scope| {
            for _ in 0..8 {
                let (path, barrier, holders) = (path.clone(), barrier.clone(), holders.clone());
                scope.spawn(move || {
                    barrier.wait();
                    for _ in 0..1000 {
                        if let Ok(_lock) = UpdateLock::acquire_at(&path) {
                            assert_eq!(holders.fetch_add(1, Ordering::SeqCst), 0);
                            std::thread::yield_now();
                            assert_eq!(holders.fetch_sub(1, Ordering::SeqCst), 1);
                        }
                    }
                });
            }
        });
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn a_crashed_process_releases_the_kernel_lock() {
        let directory = lock_directory();
        let path = directory.join("runner.lock");
        drop(UpdateLock::acquire_at(&path).unwrap());
        let mut child = std::process::Command::new("/usr/bin/python3")
            .args(["-c", "import fcntl,sys,time; f=open(sys.argv[1], 'r+'); fcntl.flock(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(30)"])
            .arg(&path)
            .stdout(std::process::Stdio::piped())
            .spawn().unwrap();
        let mut line = String::new();
        std::io::BufRead::read_line(
            &mut std::io::BufReader::new(child.stdout.take().unwrap()),
            &mut line,
        )
        .unwrap();
        assert_eq!(line, "locked\n");
        assert!(holder_alive(&path));
        assert!(UpdateLock::acquire_at(&path).is_err());
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(!holder_alive(&path));
        assert!(UpdateLock::acquire_at(&path).is_ok());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn updater_lock_rejects_linked_files_without_changing_them() {
        for symbolic in [false, true] {
            let directory = lock_directory();
            let target = directory.join("target");
            fs::write(&target, b"keep this file").unwrap();
            fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
            let path = directory.join("runner.lock");
            if symbolic {
                std::os::unix::fs::symlink(&target, &path).unwrap();
            } else {
                fs::hard_link(&target, &path).unwrap();
            }
            assert!(UpdateLock::acquire_at(&path).is_err());
            assert_eq!(fs::read(&target).unwrap(), b"keep this file");
            fs::remove_dir_all(directory).unwrap();
        }
    }
}
