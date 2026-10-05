//! Everything OmaFlow needs from the desktop it runs on. Today that is
//! Hyprland on Wayland with PipeWire; another platform replaces these modules
//! and leaves `omaflow-core` and the daemon alone.
pub mod clock;
pub mod desktop;
pub mod ducking;
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
