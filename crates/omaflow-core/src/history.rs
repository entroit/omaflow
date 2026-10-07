//! The dictation history: the last few transcripts, newest first, and the
//! dictations whose transcription failed, kept with their recording until
//! they are transcribed again.
use crate::fsutil::{private_dir, write_private};
use serde::{Deserialize, Serialize};
use std::{fs, path::Path};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub id: u64,
    pub created_at_ms: u64,
    pub text: String,
    #[serde(default)]
    pub raw_text: String,
    #[serde(default)]
    pub cleanup_model: String,
    pub pasted: bool,
    #[serde(default)]
    pub cleanup_warning: String,
    /// True when the recording is kept next to the history file.
    #[serde(default)]
    pub audio: bool,
    /// True once the text was changed in History, including Keep the raw
    /// text, so it is no longer what cleanup produced.
    #[serde(default)]
    pub edited: bool,
    /// Files written before failed dictations were kept have no status: every
    /// entry in them was transcribed.
    #[serde(default, skip_serializing_if = "Status::is_transcribed")]
    pub status: Status,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Status {
    #[default]
    Transcribed,
    /// The speech engine failed it. The recording waits beside the history
    /// file, and `reason` says in a sentence what went wrong.
    NotTranscribed { reason: String },
}

impl Status {
    pub fn is_transcribed(&self) -> bool {
        matches!(self, Self::Transcribed)
    }
}

/// What a dictation transcribed again fills its entry with.
#[derive(Debug, Clone)]
pub struct Filled {
    pub text: String,
    pub raw_text: String,
    pub cleanup_model: String,
    pub cleanup_warning: String,
    pub pasted: bool,
    /// Whether dictation audio is kept, so the recording stays once it has
    /// done its job.
    pub keep_audio: bool,
}

impl HistoryEntry {
    /// A dictation that could not be transcribed, with its recording kept.
    pub fn not_transcribed(id: u64, created_at_ms: u64, reason: &str) -> Self {
        Self {
            id,
            created_at_ms,
            text: String::new(),
            raw_text: String::new(),
            cleanup_model: String::new(),
            pasted: false,
            cleanup_warning: String::new(),
            audio: true,
            edited: false,
            status: Status::NotTranscribed {
                reason: reason.into(),
            },
        }
    }

    pub fn transcribed(&self) -> bool {
        self.status.is_transcribed()
    }

    /// Not transcribed yet, and its recording is still there to try again.
    pub fn retryable(&self) -> bool {
        !self.transcribed() && self.audio
    }
}

/// Fills in a dictation that was not transcribed. False when there is
/// nothing to fill: the entry is gone or was transcribed already, so running
/// it twice changes nothing.
pub fn fill(history: &mut [HistoryEntry], id: u64, filled: Filled) -> bool {
    let Some(entry) = history
        .iter_mut()
        .find(|entry| entry.id == id && !entry.transcribed())
    else {
        return false;
    };
    entry.text = filled.text;
    entry.raw_text = filled.raw_text;
    entry.cleanup_model = filled.cleanup_model;
    entry.cleanup_warning = filled.cleanup_warning;
    entry.pasted = filled.pasted;
    entry.audio = entry.audio && filled.keep_audio;
    entry.status = Status::Transcribed;
    true
}

/// A dictation that failed again: it stays, with the latest reason. False
/// when the entry is gone or was transcribed meanwhile.
pub fn still_not_transcribed(history: &mut [HistoryEntry], id: u64, reason: &str) -> bool {
    let Some(entry) = history
        .iter_mut()
        .find(|entry| entry.id == id && !entry.transcribed())
    else {
        return false;
    };
    entry.status = Status::NotTranscribed {
        reason: reason.into(),
    };
    true
}

pub fn load(path: &Path, limit: usize) -> Vec<HistoryEntry> {
    if limit == 0 {
        return Vec::new();
    }
    let Ok(text) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut entries: Vec<HistoryEntry> = match serde_json::from_str(&text) {
        Ok(entries) => entries,
        Err(error) => {
            eprintln!("omaflow: ignoring invalid {}: {error}", path.display());
            return Vec::new();
        }
    };
    entries.retain(|entry| !entry.transcribed() || !entry.text.trim().is_empty());
    entries.truncate(limit);
    entries
}

pub fn write(path: &Path, history: &[HistoryEntry]) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", path.display()))?;
    private_dir(parent)?;
    let bytes = serde_json::to_vec(history).map_err(|error| error.to_string())?;
    write_private(path, &bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn filled(text: &str, keep_audio: bool) -> Filled {
        Filled {
            text: text.into(),
            raw_text: text.to_lowercase(),
            cleanup_model: "gemma4:e4b".into(),
            cleanup_warning: String::new(),
            pasted: false,
            keep_audio,
        }
    }

    fn temp_file(name: &str) -> std::path::PathBuf {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir()
            .join(format!(
                "omaflow-history-{name}-{}-{nonce}",
                std::process::id()
            ))
            .join("history.json")
    }

    #[test]
    fn a_failed_dictation_is_kept_and_a_retry_fills_it_once() {
        let mut history = vec![HistoryEntry::not_transcribed(
            7,
            1_000,
            "Transcription stalled and was stopped.",
        )];
        assert!(history[0].retryable());
        assert!(fill(&mut history, 7, filled("Ship it on Friday.", false)));
        assert_eq!(history[0].text, "Ship it on Friday.");
        assert_eq!(history[0].raw_text, "ship it on friday.");
        assert_eq!(history[0].status, Status::Transcribed);
        // With dictation audio off, the recording goes once it is transcribed.
        assert!(!history[0].audio);
        // A second retry of the same dictation, from the card or History,
        // finds it done and leaves it alone.
        assert!(!fill(&mut history, 7, filled("Something else.", true)));
        assert_eq!(history[0].text, "Ship it on Friday.");
        assert!(!fill(&mut history, 8, filled("No such entry.", true)));
    }

    #[test]
    fn a_retry_that_fails_again_keeps_the_entry_with_the_new_reason() {
        let mut history = vec![HistoryEntry::not_transcribed(
            7,
            1_000,
            "The speech model is still starting.",
        )];
        assert!(still_not_transcribed(
            &mut history,
            7,
            "Transcription stalled and was stopped."
        ));
        assert_eq!(
            history[0].status,
            Status::NotTranscribed {
                reason: "Transcription stalled and was stopped.".into()
            }
        );
        assert!(history[0].retryable());
        fill(&mut history, 7, filled("Done.", true));
        assert!(!still_not_transcribed(&mut history, 7, "Too late."));
        assert_eq!(history[0].status, Status::Transcribed);
        assert!(history[0].audio, "kept, with dictation audio on");
    }

    #[test]
    fn a_failed_dictation_survives_a_restart() {
        let path = temp_file("restart");
        let mut history = vec![
            HistoryEntry::not_transcribed(6, 1_000, "Transcription stalled and was stopped."),
            HistoryEntry::not_transcribed(5, 900, ""),
        ];
        fill(&mut history, 5, filled("Earlier words.", false));
        write(&path, &history).unwrap();
        let loaded = load(&path, 30);
        assert_eq!(
            loaded.iter().map(|entry| entry.id).collect::<Vec<_>>(),
            [6, 5]
        );
        assert_eq!(
            loaded[0].status,
            Status::NotTranscribed {
                reason: "Transcription stalled and was stopped.".into()
            }
        );
        assert!(loaded[0].retryable());
        assert_eq!(loaded[1].text, "Earlier words.");
        // Only a failed entry carries a status on disk.
        let written: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(written[0]["status"]["state"], "not_transcribed");
        assert!(written[1].get("status").is_none());
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn older_history_files_read_as_transcribed_and_drop_empty_text() {
        let path = temp_file("older");
        private_dir(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            r#"[{"id":2,"created_at_ms":2,"text":"Kept words.","pasted":true},
                {"id":1,"created_at_ms":1,"text":"  ","pasted":true}]"#,
        )
        .unwrap();
        let loaded = load(&path, 30);
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].text, "Kept words.");
        assert_eq!(loaded[0].status, Status::Transcribed);
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_failed_dictation_without_its_recording_cannot_be_retried() {
        let mut history = vec![HistoryEntry::not_transcribed(
            3,
            1,
            "Transcription stalled and was stopped.",
        )];
        assert!(history[0].retryable());
        // Privacy deleted the recording: the entry stays, with nothing to send.
        history[0].audio = false;
        assert!(!history[0].retryable());
        // A late result from a retry already under way still fills it.
        assert!(fill(&mut history, 3, filled("Late words.", true)));
        assert_eq!(history[0].text, "Late words.");
        assert!(!history[0].audio);
    }
}
