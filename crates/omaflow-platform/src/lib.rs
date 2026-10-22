//! Everything OmaFlow needs from the desktop it runs on. Today that is
//! Hyprland on Wayland with PipeWire; another platform replaces these modules
//! and leaves `omaflow-core` and the daemon alone.
pub mod clock;
pub mod desktop;
pub mod ducking;
pub mod http;
pub mod ipc;
pub mod process;
pub mod sound;

use std::{env, path::PathBuf};

/// Per-session scratch space: the IPC socket, the meter and the surface state.
pub fn runtime_dir() -> PathBuf {
    env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            env::temp_dir().join(format!("omaflow-{}", env::var("USER").unwrap_or_default()))
        })
}

/// Creates session storage only when it is a directory owned by this user.
pub fn private_runtime_dir() -> Result<PathBuf, String> {
    let path = runtime_dir();
    if !path.is_absolute() {
        return Err("the runtime directory must be an absolute path".into());
    }
    omaflow_core::fsutil::private_dir(&path)?;
    Ok(path)
}
