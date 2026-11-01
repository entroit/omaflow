//! Hyprland and Wayland adapters: the clipboard, the focused window and the
//! paste shortcut. Everything that reaches outside OmaFlow to deliver text
//! lives here, so another desktop only has to replace this module.
use crate::process::CommandExt;
use omaflow_core::config::{PasteDelivery, PasteMode, PasteModifier, PasteShortcut};
use serde_json::Value;
use std::{
    process::{Command, Stdio},
    sync::{Mutex, atomic::AtomicBool},
    thread,
    time::Duration,
};

/// Serializes clipboard ownership and the paste shortcut, so two deliveries
/// never interleave their clipboard write and key chord.
pub static DELIVERY_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

pub fn copy_text(text: &str) -> Result<(), String> {
    let _guard = DELIVERY_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    forget_pending_restore();
    set_clipboard(text.as_bytes(), None)
}

pub fn paste_text_now(text: &str, delivery: &PasteDelivery) -> Result<(), String> {
    let _guard = DELIVERY_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    forget_pending_restore();
    set_clipboard(text.as_bytes(), None)?;
    if delivery.mode == PasteMode::Clipboard {
        return Ok(());
    }
    // The panel defers this command until its fade has released keyboard
    // focus. Keep one final compositor frame between clipboard ownership and
    // the synthetic paste shortcut.
    thread::sleep(Duration::from_millis(80));
    let window = active_window();
    let window = window.ok_or_else(|| "no focused window".to_string())?;
    focus_window(&window)?;
    // Layer-shell focus changes are asynchronous. Wait for Hyprland to
    // deliver the focus commit before injecting the paste chord.
    thread::sleep(Duration::from_millis(200));
    if !active_window_matches(Some(&window)) {
        return Err("Focus changed; text remains on the clipboard".into());
    }
    paste(delivery, Some(&window))
}

pub fn focus_window(window: &Value) -> Result<(), String> {
    let address = window
        .get("address")
        .and_then(Value::as_str)
        .filter(|address| !address.is_empty())
        .ok_or_else(|| "focused window has no address".to_string())?;
    let dispatcher = format!(r#"hl.dsp.focus({{ window = "address:{address}" }})"#);
    let output = Command::new("hyprctl")
        .args(["dispatch", &dispatcher])
        .bounded_output()
        .map_err(|error| format!("could not restore focused window: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err("Hyprland could not restore the focused window".into())
    }
}

pub fn set_clipboard(data: &[u8], mime_type: Option<&str>) -> Result<(), String> {
    let mut command = Command::new("wl-copy");
    if let Some(mime_type) = mime_type {
        command.args(["--type", mime_type]);
    }
    command.stdout(Stdio::null()).stderr(Stdio::null());
    let status = crate::process::run(
        &mut command,
        data,
        &AtomicBool::new(false),
        Duration::from_secs(3),
    )?
    .status;
    if status.success() {
        Ok(())
    } else {
        Err("wl-copy failed".into())
    }
}

/// The most text a paste takes. More than this is refused rather than cut,
/// so a paste is either whole or does not happen.
pub const PASTE_LIMIT: usize = 1024 * 1024;

/// The clipboard's text, or the primary selection's, read by `wl-paste` in its
/// own process with a time and size limit. The OmaFlow window pastes through
/// this so the shell never reads clipboard data itself: an app that offers
/// endless data stops here instead of filling the shell's memory.
pub fn read_clipboard_text(primary: bool) -> Result<String, String> {
    let selection: &[&str] = if primary { &["--primary"] } else { &[] };
    let types_output = Command::new("wl-paste")
        .args(selection)
        .arg("--list-types")
        .bounded_output_for(Duration::from_secs(2))
        .map_err(|_| "The clipboard did not answer.".to_string())?;
    if !types_output.status.success() {
        return Ok(String::new());
    }
    let types_text = String::from_utf8_lossy(&types_output.stdout);
    let types: Vec<&str> = types_text
        .lines()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .collect();
    let Some(mime_type) = preferred_clipboard_type(&types).filter(|t| is_text_mime(t)) else {
        return Ok(String::new());
    };
    let output = Command::new("wl-paste")
        .args(selection)
        .args(["--no-newline", "--type", mime_type])
        .bounded_output_for(Duration::from_secs(2))
        .map_err(|error| {
            if error.to_string().contains("exceeds") {
                "The clipboard holds too much text to paste.".to_string()
            } else {
                "The clipboard did not answer.".to_string()
            }
        })?;
    if !output.status.success() {
        return Ok(String::new());
    }
    if output.stdout.len() > PASTE_LIMIT {
        return Err("The clipboard holds too much text to paste.".into());
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// How long a pasted transcript stays on the clipboard before the previous
/// clipboard comes back. Nothing confirms the app has read the paste, so an
/// app slower than this pastes the restored clipboard instead.
const RESTORE_DELAY: Duration = Duration::from_millis(500);
/// A larger clipboard is not read back, and keeps the transcript.
const RESTORE_LIMIT: usize = 32 << 20;

/// What the clipboard held before a paste, in the one type wl-copy can offer
/// again.
pub enum SavedClipboard {
    Empty,
    Content { mime_type: String, data: Vec<u8> },
}

/// The clipboard a paste replaced, and what the paste put there.
struct Restore {
    generation: u64,
    pending: Option<(SavedClipboard, Vec<u8>)>,
}

static RESTORE: Mutex<Restore> = Mutex::new(Restore {
    generation: 0,
    pending: None,
});

/// Reads the clipboard to put back after a paste. Call it under
/// [`DELIVERY_LOCK`], before the transcript replaces the clipboard, and pass
/// the result to [`restore_clipboard_later`] once the paste is sent. A paste
/// before the previous one was put back keeps that one's original.
pub fn clipboard_to_restore() -> Option<SavedClipboard> {
    let mut restore = RESTORE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    restore.generation = restore.generation.wrapping_add(1);
    if let Some((original, inserted)) = restore.pending.take()
        && clipboard_holds(&inserted)
    {
        return Some(original);
    }
    match read_restorable_clipboard() {
        Ok(snapshot) => Some(snapshot),
        Err(error) => {
            eprintln!("omaflow: not restoring the clipboard after this paste: {error}");
            None
        }
    }
}

/// Puts `original` back after [`RESTORE_DELAY`], unless a later paste, a copy
/// or another app replaced `inserted` in the meantime.
pub fn restore_clipboard_later(original: SavedClipboard, inserted: &[u8]) {
    let generation = {
        let mut restore = RESTORE
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        restore.pending = Some((original, inserted.to_vec()));
        restore.generation
    };
    thread::spawn(move || {
        thread::sleep(RESTORE_DELAY);
        let _guard = DELIVERY_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut restore = RESTORE
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if restore.generation != generation {
            return;
        }
        let Some((original, inserted)) = restore.pending.take() else {
            return;
        };
        if !clipboard_holds(&inserted) {
            return;
        }
        let result = match original {
            SavedClipboard::Empty => clear_clipboard(),
            SavedClipboard::Content { mime_type, data } => set_clipboard(&data, Some(&mime_type)),
        };
        if let Err(error) = result {
            eprintln!("omaflow: could not restore the clipboard after a paste: {error}");
        }
    });
}

/// A copy the user asked for is never replaced by a restore that was waiting,
/// even when it copies the same words the paste put there.
fn forget_pending_restore() {
    let mut restore = RESTORE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    restore.generation = restore.generation.wrapping_add(1);
    restore.pending = None;
}

/// Whether the clipboard still holds exactly `text`. wl-paste would otherwise
/// add a newline to text without one.
fn clipboard_holds(text: &[u8]) -> bool {
    Command::new("wl-paste")
        .args(["--no-newline", "--type", "text/plain;charset=utf-8"])
        .bounded_output_for(Duration::from_secs(2))
        .is_ok_and(|output| output.status.success() && output.stdout == text)
}

fn clear_clipboard() -> Result<(), String> {
    let status = Command::new("wl-copy")
        .arg("--clear")
        .bounded_status()
        .map_err(|error| format!("could not clear the clipboard: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err("wl-copy --clear failed".into())
    }
}

/// The clipboard in the one type wl-copy can offer again: its text, or else
/// its first image. Rich text comes back as plain text.
fn read_restorable_clipboard() -> Result<SavedClipboard, String> {
    let types_output = Command::new("wl-paste")
        .arg("--list-types")
        .bounded_output_for(Duration::from_secs(2))
        .map_err(|error| format!("could not inspect clipboard: {error}"))?;
    if !types_output.status.success() {
        return Ok(SavedClipboard::Empty);
    }
    let types_text = String::from_utf8_lossy(&types_output.stdout);
    let types: Vec<&str> = types_text
        .lines()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .collect();
    let mime_type =
        restorable_clipboard_type(&types).ok_or("the clipboard holds neither text nor an image")?;
    let output = Command::new("wl-paste")
        .args(["--no-newline", "--type", mime_type])
        .bounded_output_for(Duration::from_secs(2))
        .map_err(|error| format!("could not read clipboard as {mime_type}: {error}"))?;
    if !output.status.success() {
        return Err(format!("could not read clipboard as {mime_type}"));
    }
    if output.stdout.len() > RESTORE_LIMIT {
        return Err(format!(
            "the clipboard holds more than {} MiB",
            RESTORE_LIMIT >> 20
        ));
    }
    Ok(SavedClipboard::Content {
        mime_type: mime_type.to_string(),
        data: output.stdout,
    })
}

fn restorable_clipboard_type<'a>(types: &'a [&'a str]) -> Option<&'a str> {
    preferred_clipboard_type(types).or_else(|| {
        types
            .iter()
            .copied()
            .find(|mime_type| mime_type.starts_with("image/"))
    })
}

pub fn preferred_clipboard_type<'a>(types: &'a [&'a str]) -> Option<&'a str> {
    [
        "text/plain;charset=utf-8",
        "text/plain",
        "UTF8_STRING",
        "STRING",
        "TEXT",
        "text/uri-list",
    ]
    .into_iter()
    .find_map(|preferred| {
        types
            .iter()
            .copied()
            .find(|mime_type| mime_type.eq_ignore_ascii_case(preferred))
    })
}

pub fn is_text_mime(mime_type: &str) -> bool {
    mime_type.starts_with("text/")
        || ["UTF8_STRING", "STRING", "TEXT"]
            .iter()
            .any(|text_type| mime_type.eq_ignore_ascii_case(text_type))
}

pub fn paste(delivery: &PasteDelivery, window: Option<&Value>) -> Result<(), String> {
    let Some(shortcut) = paste_shortcut(delivery, window) else {
        return Ok(());
    };
    send_hyprland_shortcut(&shortcut)
}

fn send_hyprland_shortcut(shortcut: &PasteShortcut) -> Result<(), String> {
    // Keep down and delayed up in one Hyprland Lua evaluation. Separate
    // `hyprctl` calls lose the synthetic key between Lua contexts, which can
    // leave the shortcut pressed or make the release fail.
    let modifier = shortcut.hyprland_modifiers();
    let key = &shortcut.key;
    let dispatcher = format!(
        "function() \
         hl.dispatch(hl.dsp.send_key_state({{ mods = \"{modifier}\", key = \"{key}\", state = \"down\" }})); \
         hl.timer(function() \
           hl.dispatch(hl.dsp.send_key_state({{ mods = \"{modifier}\", key = \"{key}\", state = \"up\" }})) \
         end, {{ timeout = 50, type = \"oneshot\" }}) \
         end"
    );
    let output = Command::new("hyprctl")
        .args(["dispatch", &dispatcher])
        .bounded_output()
        .map_err(|error| format!("could not ask Hyprland to paste: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err("Hyprland could not send the paste shortcut".into())
    }
}

pub fn paste_shortcut(delivery: &PasteDelivery, window: Option<&Value>) -> Option<PasteShortcut> {
    let ctrl_v = || PasteShortcut {
        modifiers: vec![PasteModifier::Ctrl],
        key: "V".into(),
    };
    let shift_insert = || PasteShortcut {
        modifiers: vec![PasteModifier::Shift],
        key: "Insert".into(),
    };
    match delivery.mode {
        PasteMode::Clipboard => None,
        PasteMode::CtrlV => Some(ctrl_v()),
        PasteMode::ShiftInsert => Some(shift_insert()),
        PasteMode::Auto if window_has_tag(window, "terminal") => Some(shift_insert()),
        PasteMode::Auto => Some(ctrl_v()),
        PasteMode::Custom => Some(delivery.shortcut.clone()),
    }
}

fn window_has_tag(window: Option<&Value>, expected: &str) -> bool {
    window
        .and_then(|window| window.get("tags"))
        .and_then(Value::as_array)
        .is_some_and(|tags| {
            tags.iter()
                .filter_map(Value::as_str)
                .any(|tag| tag.trim_end_matches('*').eq_ignore_ascii_case(expected))
        })
}

pub fn active_window() -> Option<Value> {
    Command::new("hyprctl")
        .args(["activewindow", "-j"])
        .bounded_output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| serde_json::from_slice(&output.stdout).ok())
}

pub fn active_window_matches(expected: Option<&Value>) -> bool {
    let expected = expected
        .and_then(|window| window.get("address"))
        .and_then(Value::as_str)
        .filter(|address| !address.is_empty());
    let current = active_window();
    let current = current
        .as_ref()
        .and_then(|window| window.get("address"))
        .and_then(Value::as_str)
        .filter(|address| !address.is_empty());
    expected.is_some() && expected == current
}

#[cfg(test)]
mod tests {
    use super::{
        is_text_mime, paste_shortcut, preferred_clipboard_type, restorable_clipboard_type,
    };
    use omaflow_core::config::{PasteDelivery, PasteMode, PasteModifier, PasteShortcut};
    use serde_json::json;

    #[test]
    fn automatic_paste_matches_omarchy_terminal_behavior() {
        let terminal = json!({"tags": ["default-opacity*", "terminal*"]});
        let graphical = json!({"tags": ["browser*"]});
        let delivery = |mode| PasteDelivery {
            mode,
            shortcut: PasteShortcut::default(),
        };
        assert_eq!(
            paste_shortcut(&delivery(PasteMode::Auto), Some(&terminal)),
            Some(PasteShortcut {
                modifiers: vec![PasteModifier::Shift],
                key: "Insert".into(),
            })
        );
        assert_eq!(
            paste_shortcut(&delivery(PasteMode::Auto), Some(&graphical)),
            Some(PasteShortcut::default())
        );
        assert_eq!(
            paste_shortcut(&delivery(PasteMode::CtrlV), Some(&terminal)),
            Some(PasteShortcut::default())
        );
        assert_eq!(
            paste_shortcut(&delivery(PasteMode::ShiftInsert), Some(&graphical)),
            Some(PasteShortcut {
                modifiers: vec![PasteModifier::Shift],
                key: "Insert".into(),
            })
        );
        assert_eq!(
            paste_shortcut(&delivery(PasteMode::Clipboard), Some(&graphical)),
            None
        );
    }

    #[test]
    fn custom_paste_uses_the_saved_chord_in_every_window() {
        let shortcut = PasteShortcut {
            modifiers: vec![PasteModifier::Shift, PasteModifier::Ctrl],
            key: "F8".into(),
        };
        let delivery = PasteDelivery {
            mode: PasteMode::Custom,
            shortcut: shortcut.clone(),
        };
        let terminal = json!({"tags": ["terminal*"]});
        assert_eq!(paste_shortcut(&delivery, Some(&terminal)), Some(shortcut));
        assert_eq!(delivery.shortcut.hyprland_modifiers(), "CTRL SHIFT");
    }

    #[test]
    fn paste_takes_text_and_ignores_binary() {
        let types = ["text/plain", "image/jpeg", "image/png"];
        assert_eq!(preferred_clipboard_type(&types), Some("text/plain"));
        assert_eq!(preferred_clipboard_type(&["image/png"]), None);
        assert!(!is_text_mime("image/png"));
    }

    #[test]
    fn restore_puts_back_text_first_and_otherwise_an_image() {
        let html = ["text/html", "text/plain;charset=utf-8", "UTF8_STRING"];
        assert_eq!(
            restorable_clipboard_type(&html),
            Some("text/plain;charset=utf-8")
        );
        let screenshot = ["image/png", "image/jpeg"];
        assert_eq!(restorable_clipboard_type(&screenshot), Some("image/png"));
        assert_eq!(
            restorable_clipboard_type(&["application/x-kde-cutselection"]),
            None
        );
    }
}
