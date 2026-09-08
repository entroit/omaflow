//! Update awareness for a plugin installed from a git checkout.
//!
//! OmaFlow is installed from a Git checkout, so the panel reports when that
//! checkout is behind its remote or ahead of the running binary. Update checks
//! never modify or execute the checkout. Users review updates through Omarchy's
//! plugin updater and run `link-local` themselves to rebuild the daemon.
//!
//! This module gives the panel three facts: whether the checkout is newer than
//! the running binary, whether the remote is ahead of the checkout, and when
//! that was last checked.

use crate::process::CommandExt;
use serde::{Deserialize, Serialize};
use std::{
    env, fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};

/// Shape of the JSON the daemon publishes for the panel. The panel refuses to
/// render a version it does not know, which is the failure a partial update
/// produces: new QML, old daemon.
pub const STATE_VERSION: u32 = 2;

pub const RUNNING_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RemoteStatus {
    pub behind: u32,
    pub remote_version: String,
    pub checked_at_ms: u64,
    pub error: String,
}

#[derive(Debug, Clone, Default)]
pub struct UpdateStatus {
    pub checkout_version: String,
    pub needs_rebuild: bool,
    pub remote: RemoteStatus,
}

/// The repository root, resolved from the running binary
/// (`<repo>/target/release/omaflow`) and verified by its manifest. Falls back
/// to the plugin symlink that `link-local` creates.
pub fn repo_root() -> Option<PathBuf> {
    let from_exe = env::current_exe()
        .ok()
        .and_then(|exe| fs::canonicalize(exe).ok())
        .and_then(|exe| exe.ancestors().nth(3).map(Path::to_path_buf));
    let from_plugin = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .map(|base| base.join("omarchy/plugins/entroit.omaflow"))
        .and_then(|link| fs::canonicalize(link).ok());

    [from_exe, from_plugin]
        .into_iter()
        .flatten()
        .find(|root| root.join("manifest.json").is_file() && root.join("Cargo.toml").is_file())
}

/// The version recorded in the checkout's manifest. When it differs from the
/// compiled-in version, the working tree moved but nothing rebuilt.
pub fn checkout_version(root: &Path) -> Option<String> {
    manifest_version(&fs::read_to_string(root.join("manifest.json")).ok()?)
}

fn manifest_version(manifest: &str) -> Option<String> {
    serde_json::from_str::<serde_json::Value>(manifest)
        .ok()?
        .get("version")?
        .as_str()
        .map(ToOwned::to_owned)
}

pub fn remote_status_path() -> PathBuf {
    crate::state_dir().join("update.json")
}

pub fn read_remote_status() -> RemoteStatus {
    fs::read_to_string(remote_status_path())
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

pub fn status() -> UpdateStatus {
    let checkout_version = repo_root()
        .and_then(|root| checkout_version(&root))
        .unwrap_or_default();
    let mut remote = read_remote_status();
    if let Some(root) = repo_root()
        && let Ok(count) = git(&root, &["rev-list", "--count", "HEAD..@{upstream}"])
        && let Ok(behind) = count.parse()
    {
        remote.behind = behind;
    }
    UpdateStatus {
        needs_rebuild: !checkout_version.is_empty() && checkout_version != RUNNING_VERSION,
        checkout_version,
        remote,
    }
}

/// Fetch and record how far the checkout is behind its upstream. Run from a
/// systemd timer; it never touches the working tree.
pub fn check_remote() -> Result<RemoteStatus, String> {
    let root = repo_root().ok_or_else(|| "could not locate the OmaFlow checkout".to_string())?;
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;

    // A failed fetch must not erase a pending update the user already knows
    // about; only the timestamp and the error are fresh information.
    let previous = read_remote_status();
    let mut status = RemoteStatus {
        checked_at_ms: now_ms,
        behind: previous.behind,
        remote_version: previous.remote_version,
        ..RemoteStatus::default()
    };

    let fetched = git(&root, &["fetch", "--quiet", "origin"]);
    if let Err(error) = fetched {
        status.error = error;
        write_remote_status(&status)?;
        return Ok(status);
    }

    let upstream = git(&root, &["rev-parse", "--abbrev-ref", "@{upstream}"])
        .unwrap_or_else(|_| "origin/main".to_string());
    match git(
        &root,
        &["rev-list", "--count", &format!("HEAD..{upstream}")],
    ) {
        Ok(count) => status.behind = count.trim().parse().unwrap_or(0),
        Err(error) => status.error = error,
    }
    if status.behind > 0
        && let Ok(manifest) = git(&root, &["show", &format!("{upstream}:manifest.json")])
        && let Some(version) = manifest_version(&manifest)
    {
        status.remote_version = version;
    }

    write_remote_status(&status)?;
    Ok(status)
}

fn write_remote_status(status: &RemoteStatus) -> Result<(), String> {
    let path = remote_status_path();
    let parent = path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", path.display()))?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("could not create {}: {error}", parent.display()))?;
    let temporary = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec(status).map_err(|error| error.to_string())?;
    fs::write(&temporary, bytes)
        .map_err(|error| format!("could not write {}: {error}", temporary.display()))?;
    fs::rename(&temporary, &path)
        .map_err(|error| format!("could not replace {}: {error}", path.display()))
}

fn git(root: &Path, args: &[&str]) -> Result<String, String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_SSH_COMMAND", "ssh -oBatchMode=yes")
        .stdin(Stdio::null())
        .bounded_output()
        .map_err(|error| format!("could not run git: {error}"))?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        // The panel renders this verbatim, so turn an authentication failure
        // into a sentence the user can act on.
        let stderr = String::from_utf8_lossy(&output.stderr);
        let first = stderr.trim().lines().next().unwrap_or("git failed");
        let lowered = first.to_lowercase();
        if lowered.contains("permission denied")
            || lowered.contains("authentication failed")
            || lowered.contains("could not read username")
        {
            Err("no access to the OmaFlow repository".into())
        } else {
            Err(first.to_string())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{RUNNING_VERSION, manifest_version};

    #[test]
    fn reads_the_version_from_the_plugin_manifest() {
        assert_eq!(
            manifest_version(include_str!("../manifest.json")).as_deref(),
            Some(RUNNING_VERSION),
            "manifest.json and Cargo.toml must be bumped together"
        );
        assert_eq!(manifest_version("not json"), None);
    }
}
