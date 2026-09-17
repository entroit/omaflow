use serde::{Serialize, de::DeserializeOwned};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
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
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("could not open {}: {error}", path.display())),
    };
    let metadata = file
        .metadata()
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
    if metadata.len() > limit as u64 {
        return Err(format!("{} is too large", path.display()));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.read_to_end(&mut bytes)
        .map_err(|error| format!("could not read {}: {error}", path.display()))?;
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|error| format!("could not parse {}: {error}", path.display()))
}

pub fn replace<T: Serialize>(path: &Path, value: &T) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("{} has no parent", path.display()))?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("could not create {}: {error}", parent.display()))?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("could not protect {}: {error}", parent.display()))?;
    let temporary = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("state"),
        std::process::id()
    ));
    let bytes = serde_json::to_vec(value).map_err(|error| error.to_string())?;
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|error| format!("could not create {}: {error}", temporary.display()))?;
    let result = (|| {
        file.write_all(&bytes)
            .map_err(|error| format!("could not write {}: {error}", temporary.display()))?;
        file.sync_all()
            .map_err(|error| format!("could not sync {}: {error}", temporary.display()))?;
        fs::rename(&temporary, path)
            .map_err(|error| format!("could not replace {}: {error}", path.display()))?;
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| format!("could not sync {}: {error}", parent.display()))
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

pub struct UpdateLock {
    path: PathBuf,
}

impl UpdateLock {
    pub fn acquire() -> Result<Self, String> {
        let path = update_dir().join("runner.lock");
        fs::create_dir_all(update_dir()).map_err(|error| error.to_string())?;
        fs::set_permissions(update_dir(), fs::Permissions::from_mode(0o700))
            .map_err(|error| error.to_string())?;
        for attempt in 0..2 {
            match OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(&path)
            {
                Ok(mut file) => {
                    writeln!(file, "{}", std::process::id()).map_err(|error| error.to_string())?;
                    return Ok(Self { path });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists && attempt == 0 => {
                    let stale = fs::read_to_string(&path)
                        .ok()
                        .and_then(|value| value.trim().parse::<u32>().ok())
                        .is_none_or(|pid| !Path::new("/proc").join(pid.to_string()).exists());
                    if stale {
                        fs::remove_file(&path).map_err(|error| {
                            format!("could not remove stale update lock: {error}")
                        })?;
                        continue;
                    }
                    return Err("another OmaFlow update is already running".into());
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    return Err("another OmaFlow update is already running".into());
                }
                Err(error) => return Err(format!("could not create {}: {error}", path.display())),
            }
        }
        unreachable!()
    }
}

impl Drop for UpdateLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
}
