//! Duck other applications' audio while a dictation is recording.
//!
//! WirePlumber's `wpctl` is the control surface: it ships with PipeWire on
//! Omarchy and needs no session state of our own. Every failure here is
//! silent — quieter speakers are never worth losing a dictation over.
use crate::process::CommandExt;
use std::{
    fs,
    path::PathBuf,
    process::Command,
    sync::{Mutex, OnceLock, mpsc},
    thread,
};

const SINK: &str = "@DEFAULT_AUDIO_SINK@";
/// wpctl accepts more than 100%; keep restores inside the same range.
const MAX_VOLUME: f32 = 1.5;

/// What `wpctl get-volume` reported for the default sink.
#[derive(Debug, Clone, Copy, PartialEq)]
struct SinkVolume {
    volume: f32,
    muted: bool,
}

/// Remembers the volume that was replaced by a ducked one, so the exact
/// value comes back on release.
#[derive(Debug, Default)]
pub struct Ducker {
    saved: Option<f32>,
}

impl Ducker {
    pub const fn new() -> Self {
        Self { saved: None }
    }

    /// Attenuate the default sink by `percent`. A no-op at 0%, while already
    /// ducked, when the sink is muted, or when wpctl is unavailable.
    pub fn duck(&mut self, percent: u8) {
        if percent == 0 || self.saved.is_some() {
            return;
        }
        let Some(current) = read_volume() else { return };
        if current.muted {
            return;
        }
        // The restore file goes down before the volume does. Written after, it
        // would leave a window where a crash has already quieted the speakers
        // and nothing on disk remembers what they were set to — which is the
        // one failure this file exists to prevent.
        write_restore_file(current.volume);
        if set_volume(duck_target(current.volume, percent)) {
            self.saved = Some(current.volume);
        } else {
            clear_restore_file();
        }
    }

    /// Put the remembered volume back. Idempotent: a no-op with nothing saved.
    pub fn restore(&mut self) {
        let Some(saved) = self.saved.take() else {
            return;
        };
        set_volume(saved);
        clear_restore_file();
    }
}

/// The volume a `percent` duck should leave behind.
fn duck_target(saved: f32, percent: u8) -> f32 {
    let factor = 1.0 - f32::from(percent.min(100)) / 100.0;
    (saved * factor).clamp(0.0, MAX_VOLUME)
}

/// Parse `Volume: 0.65` or `Volume: 0.65 [MUTED]`.
fn parse_volume(output: &str) -> Option<SinkVolume> {
    let line = output
        .lines()
        .find_map(|line| line.trim().strip_prefix("Volume:"))?;
    let volume: f32 = line.split_whitespace().next()?.parse().ok()?;
    if !volume.is_finite() || volume < 0.0 {
        return None;
    }
    Some(SinkVolume {
        volume,
        muted: line.contains("[MUTED]"),
    })
}

fn read_volume() -> Option<SinkVolume> {
    let output = Command::new("wpctl")
        .args(["get-volume", SINK])
        .bounded_output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    parse_volume(&String::from_utf8_lossy(&output.stdout))
}

fn set_volume(volume: f32) -> bool {
    Command::new("wpctl")
        .args([
            "set-volume",
            SINK,
            &format!("{:.4}", volume.clamp(0.0, MAX_VOLUME)),
        ])
        .bounded_status()
        .is_ok_and(|status| status.success())
}

/// A crash or a kill between duck and restore must not leave the speakers
/// turned down, so the saved volume also lives in a file on disk.
fn restore_file() -> PathBuf {
    crate::runtime_dir().join("duck-restore")
}

fn write_restore_file(volume: f32) {
    let path = restore_file();
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(&path, format!("{volume:.4}"));
}

fn clear_restore_file() {
    let _ = fs::remove_file(restore_file());
}

/// Undo a duck left behind by a previous run. Call this before the daemon
/// publishes anything, so a crashed recording never costs the user their audio.
pub fn recover() {
    let path = restore_file();
    let Ok(text) = fs::read_to_string(&path) else {
        return;
    };
    if let Ok(volume) = text.trim().parse::<f32>()
        && volume.is_finite()
        && volume >= 0.0
    {
        set_volume(volume);
    }
    let _ = fs::remove_file(&path);
}

enum Request {
    Duck(u8),
    Restore,
}

static DUCKER: Mutex<Ducker> = Mutex::new(Ducker::new());
static REQUESTS: OnceLock<mpsc::Sender<Request>> = OnceLock::new();

/// Recover any interrupted duck, then start the worker that keeps wpctl calls
/// off the message loop. Requests are served in order on one thread.
pub fn start() {
    recover();
    let (tx, rx) = mpsc::channel();
    if REQUESTS.set(tx).is_err() {
        return;
    }
    thread::spawn(move || {
        while let Ok(request) = rx.recv() {
            let Ok(mut ducker) = DUCKER.lock() else {
                return;
            };
            match request {
                Request::Duck(percent) => ducker.duck(percent),
                Request::Restore => ducker.restore(),
            }
        }
    });
}

fn request(request: Request) {
    if let Some(sender) = REQUESTS.get() {
        let _ = sender.send(request);
    }
}

/// Attenuate other audio; returns immediately.
pub fn duck(percent: u8) {
    request(Request::Duck(percent));
}

/// Put the volume back; returns immediately. Idempotent.
pub fn restore() {
    request(Request::Restore);
}

/// Put the volume back on this thread, for the shutdown path where a worker
/// thread would not outlive the process.
pub fn restore_now() {
    if let Ok(mut ducker) = DUCKER.lock() {
        ducker.restore();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_plain_volume_line() {
        let parsed = parse_volume("Volume: 0.65\n").unwrap();
        assert!((parsed.volume - 0.65).abs() < 1e-6);
        assert!(!parsed.muted);
    }

    #[test]
    fn parses_a_muted_volume_line() {
        let parsed = parse_volume("Volume: 0.65 [MUTED]\n").unwrap();
        assert!((parsed.volume - 0.65).abs() < 1e-6);
        assert!(parsed.muted);
    }

    #[test]
    fn rejects_output_that_is_not_a_volume() {
        assert!(parse_volume("").is_none());
        assert!(parse_volume("Node 42 not found\n").is_none());
        assert!(parse_volume("Volume: loud\n").is_none());
        assert!(parse_volume("Volume:\n").is_none());
        assert!(parse_volume("Volume: -0.5\n").is_none());
    }

    #[test]
    fn duck_target_scales_between_untouched_and_silent() {
        assert!((duck_target(0.8, 0) - 0.8).abs() < 1e-6);
        assert!((duck_target(0.8, 50) - 0.4).abs() < 1e-6);
        assert_eq!(duck_target(0.8, 100), 0.0);
    }

    #[test]
    fn duck_target_stays_inside_the_accepted_range() {
        assert_eq!(duck_target(9.0, 0), MAX_VOLUME);
        assert_eq!(duck_target(0.0, 70), 0.0);
    }

    #[test]
    fn a_zero_percent_duck_saves_nothing_to_restore() {
        let mut ducker = Ducker::new();
        ducker.duck(0);
        assert!(ducker.saved.is_none());
        ducker.restore();
        assert!(ducker.saved.is_none());
    }
}
