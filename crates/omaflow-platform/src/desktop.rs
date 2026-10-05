//! Hyprland and Wayland adapters: the clipboard, the focused window and the
//! paste shortcut. Everything that reaches outside OmaFlow to deliver text
//! lives here, so another desktop only has to replace this module.
use crate::process::CommandExt;
use omaflow_core::config::{PasteDelivery, PasteMode, PasteModifier, PasteShortcut};
use serde_json::Value;
use std::{
    process::{Command, Stdio},
    sync::atomic::AtomicBool,
    thread,
    time::Duration,
};

/// Serializes clipboard ownership and the paste shortcut, so two deliveries
/// never interleave their clipboard write and key chord.
pub static DELIVERY_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[derive(Debug, Default)]
pub enum ClipboardSnapshot {
    #[default]
    Empty,
    Content {
        mime_type: String,
        data: Vec<u8>,
    },
}

impl ClipboardSnapshot {
    pub fn text_context(&self) -> &str {
        match self {
            Self::Content { mime_type, data } if is_text_mime(mime_type) => {
                std::str::from_utf8(data).unwrap_or("")
            }
            _ => "",
        }
    }
}

pub fn copy_text(text: &str) -> Result<(), String> {
    let _guard = DELIVERY_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    set_clipboard(text.as_bytes(), None)
}

pub fn paste_text_now(text: &str, delivery: &PasteDelivery) -> Result<(), String> {
    let _guard = DELIVERY_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
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

pub fn read_clipboard() -> Result<ClipboardSnapshot, String> {
    let types_output = Command::new("wl-paste")
        .arg("--list-types")
        .bounded_output()
        .map_err(|error| format!("could not inspect clipboard: {error}"))?;
    if !types_output.status.success() {
        return Ok(ClipboardSnapshot::Empty);
    }
    let types_text = String::from_utf8_lossy(&types_output.stdout);
    let types: Vec<&str> = types_text
        .lines()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .collect();
    let Some(mime_type) = preferred_clipboard_type(&types) else {
        return Ok(ClipboardSnapshot::Empty);
    };
    if !is_text_mime(mime_type) {
        return Ok(ClipboardSnapshot::Empty);
    }
    let output = Command::new("wl-paste")
        .args(["--type", mime_type])
        .bounded_output()
        .map_err(|error| format!("could not read clipboard as {mime_type}: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "could not read clipboard as {mime_type}: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(ClipboardSnapshot::Content {
        mime_type: mime_type.to_string(),
        data: output.stdout,
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
    use super::{ClipboardSnapshot, paste_shortcut, preferred_clipboard_type};
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
    fn clipboard_context_reads_text_and_ignores_binary() {
        let types = ["text/plain", "image/jpeg", "image/png"];
        assert_eq!(preferred_clipboard_type(&types), Some("text/plain"));
        assert_eq!(preferred_clipboard_type(&["image/png"]), None);
        let snapshot = ClipboardSnapshot::Content {
            mime_type: "image/png".into(),
            data: vec![0, 159, 146, 150],
        };
        assert_eq!(snapshot.text_context(), "");
    }
}
