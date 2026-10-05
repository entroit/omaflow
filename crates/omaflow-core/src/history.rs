//! The dictation history: the last few transcripts, newest first.
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
    entries.retain(|entry| !entry.text.trim().is_empty());
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
