//! The journal: one Markdown file per day in a folder the user owns.
//!
//! The Markdown file is the source of truth for the words, so an entry
//! edited in any text editor is what OmaFlow shows next time. Each entry is a
//! `## HH:MM` section. OmaFlow marks its own entries with an HTML comment
//! (`<!-- omaflow:ID -->`), which Markdown renderers hide, so an edit can find
//! the entry again. What a text editor has no use for (the words as spoken,
//! the recording's length and waveform) lives in a small sidecar file under
//! `.omaflow/`, and recordings under `.recordings/`. Both are hidden folders,
//! so notes apps that open the journal folder skip them.
use crate::{
    date::Date,
    fsutil::{Made, copy_all, owned_dir, remove_moved, same_folder, write_owned},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    io::ErrorKind,
    path::{Path, PathBuf},
};

/// Waveform resolution kept per entry. The row draws as many bars as fit and
/// samples this list, so it only has to be finer than the widest row.
pub const PEAKS: usize = 96;
/// Search stops collecting here; more hits than this is a query to refine.
const SEARCH_LIMIT: usize = 200;
/// Ids below this were given to hand-written entries, by position.
const FIRST_REAL_ID: u64 = 1_000_000_000;
/// How long a deleted entry can be brought back: the Undo toast's ten
/// seconds, after which the words and the recording are really gone. The
/// window empties the trash itself when the toast ends; this bound covers a
/// window closed before that.
const TRASH_KEEP_MS: u64 = 10 * 1000;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Entry {
    pub id: u64,
    /// The section heading, normally the time the entry was saved.
    pub time: String,
    pub text: String,
    pub typed: bool,
    /// The words as spoken, before cleanup. Empty for typed entries.
    pub raw_text: String,
    pub duration_ms: u64,
    pub peaks: Vec<u8>,
    /// True when a recording is on disk for this entry.
    pub audio: bool,
    /// For a note written ahead to this day, the day it was written
    /// (YYYY-MM-DD). Empty for an ordinary entry.
    pub written: String,
    /// For an entry added to a past day, the day it was really written
    /// (YYYY-MM-DD). Empty for an entry written on its own day.
    pub added: String,
}

/// The heading of a note written today for a later day: it says when it was
/// written, in the file itself. "Note from 2026-09-30, 21:53".
pub fn note_heading(written: Date, time: &str) -> String {
    format!("Note from {written}, {time}")
}

/// The day a note was written, from its heading; None for an ordinary entry.
pub fn written_on(heading: &str) -> Option<Date> {
    heading.strip_prefix("Note from ")?.get(..10)?.parse().ok()
}

/// The heading of an entry added later to a past day: its time, and the day
/// it was really written, in the file itself. "21:53, added 2026-10-06".
pub fn added_heading(time: &str, added: Date) -> String {
    format!("{time}, added {added}")
}

/// The day an entry was added to a past day, and the time before it; None
/// for an entry written on its own day.
pub fn added_on(heading: &str) -> Option<(&str, Date)> {
    let (time, added) = heading.rsplit_once(", added ")?;
    Some((time, added.parse().ok()?))
}

/// What the page shows as an entry's time: the heading without the day an
/// added entry was written, which shows under its words instead.
fn shown_time(heading: &str) -> String {
    added_on(heading)
        .map_or(heading, |(time, _)| time)
        .to_string()
}

/// The minutes past midnight of a heading that starts with a time, such as
/// "07:42" or "21:53, added 2026-10-06".
fn minutes(heading: &str) -> Option<u32> {
    let clock = heading.get(..5)?;
    let (hours, minutes) = clock.split_once(':')?;
    if hours.len() != 2 || !clock.bytes().all(|b| b.is_ascii_digit() || b == b':') {
        return None;
    }
    Some(hours.parse::<u32>().ok()? * 60 + minutes.parse::<u32>().ok()?)
}

#[derive(Debug, Clone, Serialize)]
pub struct Day {
    pub date: String,
    pub title: String,
    pub file: String,
    pub exists: bool,
    pub entries: Vec<Entry>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DayCount {
    pub date: String,
    pub entries: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct SearchHit {
    pub date: String,
    pub time: String,
    pub id: u64,
    /// The entry, or the sentence around the first match when it is long.
    /// Empty for a sealed note.
    pub snippet: String,
    /// `[start, length]` in characters of `snippet`, one pair per match.
    pub matches: Vec<[usize; 2]>,
    /// A note for a day that has not come yet: it stays sealed until then,
    /// so search says it is there but not what it says.
    pub sealed: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct SearchResult {
    pub query: String,
    pub days: Vec<String>,
    pub hits: Vec<SearchHit>,
    pub truncated: bool,
}

/// A spoken or typed entry about to be written.
pub struct NewEntry<'a> {
    pub id: u64,
    pub time: &'a str,
    pub text: &'a str,
    pub typed: bool,
    pub raw_text: &'a str,
    pub duration_ms: u64,
    pub peaks: Vec<u8>,
    /// A complete WAV file, or None to keep no recording.
    pub recording: Option<&'a [u8]>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct Sidecar {
    #[serde(default)]
    entries: BTreeMap<u64, Meta>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
struct Meta {
    #[serde(default)]
    raw_text: String,
    #[serde(default)]
    duration_ms: u64,
    #[serde(default)]
    peaks: Vec<u8>,
}

#[derive(Debug, Clone, Default, PartialEq)]
struct Document {
    /// YAML frontmatter, delimiters included, kept verbatim at the very top.
    front: String,
    title: Option<String>,
    preamble: String,
    sections: Vec<Section>,
}

/// The last deleted entry, kept so the delete can be undone: its place in the
/// day, its words exactly as they were in the file, and what the sidecar knew.
/// Only one is kept, and not for long; see `TRASH_KEEP_MS`.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Trashed {
    date: String,
    id: u64,
    index: usize,
    heading: String,
    marked: bool,
    typed: bool,
    body: String,
    meta: Option<Meta>,
    deleted_at_ms: u64,
}

#[derive(Debug, Clone, PartialEq)]
struct Section {
    heading: String,
    id: u64,
    marked: bool,
    typed: bool,
    body: String,
}

pub struct Journal {
    folder: PathBuf,
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or(0)
}

impl Journal {
    pub fn new(folder: impl Into<PathBuf>) -> Self {
        Self {
            folder: folder.into(),
        }
    }

    pub fn folder(&self) -> &Path {
        &self.folder
    }

    pub fn day_path(&self, date: Date) -> PathBuf {
        self.folder.join(format!("{date}.md"))
    }

    pub fn recording_path(&self, date: Date, id: u64) -> PathBuf {
        self.folder
            .join(".recordings")
            .join(date.to_string())
            .join(format!("{id}.wav"))
    }

    /// How many entries have a kept recording, so turning recordings off
    /// can say what it deletes.
    pub fn recording_count(&self) -> usize {
        let Ok(days) = fs::read_dir(self.folder.join(".recordings")) else {
            return 0;
        };
        days.flatten()
            .filter_map(|day| fs::read_dir(day.path()).ok())
            .flat_map(|files| files.flatten())
            .filter(|file| file.path().extension().is_some_and(|ext| ext == "wav"))
            .count()
    }

    /// Deletes every kept recording. The words and waveform outlines stay.
    pub fn delete_recordings(&self) -> Result<(), String> {
        let _ = fs::remove_file(self.trash_dir().join("recording.wav"));
        let recordings = self.folder.join(".recordings");
        match fs::remove_dir_all(&recordings) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!("{}: {error}", recordings.display())),
        }
    }

    fn sidecar_path(&self, date: Date) -> PathBuf {
        self.folder.join(".omaflow").join(format!("{date}.json"))
    }

    pub fn day(&self, date: Date) -> Result<Day, String> {
        let path = self.day_path(date);
        let (document, exists) = match fs::read_to_string(&path) {
            Ok(text) => (parse(&text), true),
            Err(error) if error.kind() == ErrorKind::NotFound => (Document::default(), false),
            Err(error) => return Err(format!("could not read {}: {error}", path.display())),
        };
        let sidecar = self.read_sidecar(date);
        let entries = document
            .sections
            .iter()
            .map(|section| {
                let meta = sidecar
                    .entries
                    .get(&section.id)
                    .cloned()
                    .unwrap_or_default();
                Entry {
                    id: section.id,
                    time: shown_time(&section.heading),
                    text: unescape_body(&section.body),
                    typed: section.typed,
                    raw_text: meta.raw_text,
                    duration_ms: meta.duration_ms,
                    peaks: meta.peaks,
                    audio: section.marked && self.recording_path(date, section.id).is_file(),
                    written: written_on(&section.heading)
                        .map(|day| day.to_string())
                        .unwrap_or_default(),
                    added: added_on(&section.heading)
                        .map(|(_, day)| day.to_string())
                        .unwrap_or_default(),
                }
            })
            .collect();
        Ok(Day {
            date: date.to_string(),
            title: document.title.unwrap_or_else(|| date.long()),
            file: path.to_string_lossy().into_owned(),
            exists,
            entries,
        })
    }

    /// Every day in the given month that has at least one entry.
    pub fn month(&self, year: i32, month: u8) -> Result<Vec<DayCount>, String> {
        let prefix = format!("{year:04}-{month:02}-");
        let mut days = Vec::new();
        for date in self.dates()? {
            let name = date.to_string();
            if !name.starts_with(&prefix) {
                continue;
            }
            let count = fs::read_to_string(self.day_path(date))
                .map(|text| parse(&text).sections.len())
                .unwrap_or(0);
            if count > 0 {
                days.push(DayCount {
                    date: name,
                    entries: count,
                });
            }
        }
        Ok(days)
    }

    /// Dates of every day file in the folder, oldest first.
    pub fn dates(&self) -> Result<Vec<Date>, String> {
        let entries = match fs::read_dir(&self.folder) {
            Ok(entries) => entries,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(format!("could not read {}: {error}", self.folder.display())),
        };
        let mut dates: Vec<Date> = entries
            .flatten()
            .filter_map(|entry| {
                let name = entry.file_name().to_string_lossy().into_owned();
                name.strip_suffix(".md")?.parse().ok()
            })
            .collect();
        dates.sort();
        Ok(dates)
    }

    pub fn add(&self, date: Date, entry: NewEntry<'_>) -> Result<Entry, String> {
        let text = entry.text.trim();
        if text.is_empty() {
            return Err("The entry has no words to save".into());
        }
        // The folder is yours, often a notes vault or a synced folder: create
        // it if needed, never change its permissions.
        fs::create_dir_all(&self.folder).map_err(|error| match error.kind() {
            // The daemon is sandboxed; a folder it was never given reads as
            // read-only. Choosing it again in Journal settings opens it.
            ErrorKind::ReadOnlyFilesystem | ErrorKind::PermissionDenied => format!(
                "OmaFlow is not allowed to write {}. Choose the folder again in Journal settings.",
                self.folder.display()
            ),
            _ => format!("could not create {}: {error}", self.folder.display()),
        })?;
        let _lock = self.lock()?;
        let path = self.day_path(date);
        let mut document = match fs::read_to_string(&path) {
            Ok(text) => parse(&text),
            Err(error) if error.kind() == ErrorKind::NotFound => Document::default(),
            Err(error) => return Err(format!("could not read {}: {error}", path.display())),
        };
        let mut id = entry.id.max(FIRST_REAL_ID);
        while document.sections.iter().any(|section| section.id == id) {
            id += 1;
        }
        let audio = match entry.recording {
            Some(wav) => {
                let recording = self.recording_path(date, id);
                if let Some(parent) = recording.parent() {
                    owned_dir(parent)?;
                }
                write_owned(&recording, wav)?;
                true
            }
            None => false,
        };
        if !entry.typed {
            let mut sidecar = self.read_sidecar(date);
            sidecar.entries.insert(
                id,
                Meta {
                    raw_text: entry.raw_text.trim().to_string(),
                    duration_ms: entry.duration_ms,
                    peaks: entry.peaks.clone(),
                },
            );
            self.write_sidecar(date, &sidecar)?;
        }
        // An entry added to a past day goes in among that day's entries by
        // its time; one written on its own day is the latest anyway.
        let index = match (added_on(entry.time), minutes(entry.time)) {
            (Some(_), Some(at)) => document
                .sections
                .iter()
                .position(|section| minutes(&section.heading).is_some_and(|other| other > at))
                .unwrap_or(document.sections.len()),
            _ => document.sections.len(),
        };
        document.sections.insert(
            index,
            Section {
                heading: entry.time.to_string(),
                id,
                marked: true,
                typed: entry.typed,
                body: escape_body(text),
            },
        );
        write_owned(&path, render(&document, date).as_bytes())?;
        Ok(Entry {
            id,
            time: shown_time(entry.time),
            text: text.to_string(),
            typed: entry.typed,
            raw_text: entry.raw_text.trim().to_string(),
            duration_ms: entry.duration_ms,
            peaks: entry.peaks,
            audio,
            written: written_on(entry.time)
                .map(|day| day.to_string())
                .unwrap_or_default(),
            added: added_on(entry.time)
                .map(|(_, day)| day.to_string())
                .unwrap_or_default(),
        })
    }

    pub fn edit(&self, date: Date, id: u64, text: &str) -> Result<(), String> {
        let text = text.trim();
        if text.is_empty() {
            return Err("An entry needs words. Use Delete to remove it.".into());
        }
        let _lock = self.lock()?;
        self.rewrite(date, |document| {
            let section = document
                .sections
                .iter_mut()
                .find(|section| section.id == id)
                .ok_or("That entry is no longer in the file")?;
            section.body = escape_body(text);
            Ok(())
        })
    }

    /// Removes an entry, its sidecar data and its recording. They go to a
    /// one-entry trash first, so `restore` can undo it for ten seconds.
    pub fn delete(&self, date: Date, id: u64) -> Result<(), String> {
        let _lock = self.lock()?;
        self.empty_trash();
        let mut removed = None;
        self.rewrite(date, |document| {
            let index = document
                .sections
                .iter()
                .position(|section| section.id == id)
                .ok_or("That entry is no longer in the file")?;
            removed = Some((index, document.sections.remove(index)));
            Ok(())
        })?;
        let (index, section) = removed.expect("rewrite found the entry");
        let mut sidecar = self.read_sidecar(date);
        let meta = sidecar.entries.remove(&id);
        if meta.is_some() {
            self.write_sidecar(date, &sidecar)?;
        }
        let trash = self.trash_dir();
        owned_dir(&trash)?;
        let trashed = Trashed {
            date: date.to_string(),
            id,
            index,
            heading: section.heading,
            marked: section.marked,
            typed: section.typed,
            body: section.body,
            meta,
            deleted_at_ms: now_ms(),
        };
        let record = serde_json::to_vec(&trashed).map_err(|error| error.to_string())?;
        write_owned(&trash.join("entry.json"), &record)?;
        match fs::rename(self.recording_path(date, id), trash.join("recording.wav")) {
            Err(error) if error.kind() != ErrorKind::NotFound => Err(format!(
                "The entry is gone but its recording is not: {error}"
            )),
            _ => Ok(()),
        }
    }

    /// Puts the last deleted entry back where it was, with its recording.
    pub fn restore(&self, date: Date, id: u64) -> Result<(), String> {
        let _lock = self.lock()?;
        self.forget_stale_trash();
        let trash = self.trash_dir();
        let trashed: Trashed = fs::read(trash.join("entry.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .filter(|trashed: &Trashed| trashed.date == date.to_string() && trashed.id == id)
            .ok_or("That entry can no longer be brought back")?;
        let path = self.day_path(date);
        let mut document = match fs::read_to_string(&path) {
            Ok(text) => parse(&text),
            Err(error) if error.kind() == ErrorKind::NotFound => Document::default(),
            Err(error) => return Err(format!("could not read {}: {error}", path.display())),
        };
        if document.sections.iter().any(|section| section.id == id) {
            return Err("That entry is already back".into());
        }
        let index = trashed.index.min(document.sections.len());
        document.sections.insert(
            index,
            Section {
                heading: trashed.heading,
                id,
                marked: trashed.marked,
                typed: trashed.typed,
                body: trashed.body,
            },
        );
        write_owned(&path, render(&document, date).as_bytes())?;
        if let Some(meta) = trashed.meta {
            let mut sidecar = self.read_sidecar(date);
            sidecar.entries.insert(id, meta);
            self.write_sidecar(date, &sidecar)?;
        }
        let recording = trash.join("recording.wav");
        if recording.exists() {
            let destination = self.recording_path(date, id);
            if let Some(parent) = destination.parent() {
                owned_dir(parent)?;
            }
            fs::rename(&recording, &destination)
                .map_err(|error| format!("The entry is back but its recording is not: {error}"))?;
        }
        self.empty_trash();
        Ok(())
    }

    fn trash_dir(&self) -> PathBuf {
        self.folder.join(".omaflow").join("trash")
    }

    /// Deletes the last deleted entry for good, words and recording.
    pub fn empty_trash(&self) {
        let _ = fs::remove_dir_all(self.trash_dir());
    }

    /// Deleted entries are only kept for Undo; after that they are gone.
    pub fn forget_stale_trash(&self) {
        let deleted_at = fs::read(self.trash_dir().join("entry.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Trashed>(&bytes).ok())
            .map(|trashed| trashed.deleted_at_ms);
        match deleted_at {
            Some(at) if now_ms().saturating_sub(at) < TRASH_KEEP_MS => {}
            _ => self.empty_trash(),
        }
    }

    fn rewrite(
        &self,
        date: Date,
        change: impl FnOnce(&mut Document) -> Result<(), String>,
    ) -> Result<(), String> {
        let path = self.day_path(date);
        let text = fs::read_to_string(&path)
            .map_err(|error| format!("could not read {}: {error}", path.display()))?;
        let mut document = parse(&text);
        change(&mut document)?;
        write_owned(&path, render(&document, date).as_bytes())
    }

    /// The first entry written on this day a year ago.
    pub fn a_year_ago(&self, date: Date) -> Result<Option<(Day, Entry)>, String> {
        let day = self.day(date.a_year_earlier())?;
        Ok(day.entries.first().cloned().map(|entry| (day, entry)))
    }

    /// Case-insensitive search through every entry, newest day first.
    /// Notes for days after `today` are found but their words stay out.
    pub fn search(&self, query: &str, today: Date) -> Result<SearchResult, String> {
        let query = query.trim();
        let mut result = SearchResult {
            query: query.to_string(),
            days: Vec::new(),
            hits: Vec::new(),
            truncated: false,
        };
        let needle = fold(query);
        if needle.is_empty() {
            return Ok(result);
        }
        for date in self.dates()?.into_iter().rev() {
            let Ok(text) = fs::read_to_string(self.day_path(date)) else {
                continue;
            };
            let mut matched_day = false;
            for section in parse(&text).sections.into_iter().rev() {
                let haystack: Vec<char> = section.body.chars().collect();
                let matches = find_all(&fold_chars(&haystack), &needle);
                if matches.is_empty() {
                    continue;
                }
                if result.hits.len() == SEARCH_LIMIT {
                    result.truncated = true;
                    if matched_day {
                        result.days.push(date.to_string());
                    }
                    return Ok(result);
                }
                let sealed = date > today && written_on(&section.heading).is_some();
                let (snippet, matches) = if sealed {
                    (String::new(), Vec::new())
                } else {
                    snippet(&haystack, &matches, needle.len())
                };
                matched_day = true;
                result.hits.push(SearchHit {
                    date: date.to_string(),
                    time: shown_time(&section.heading),
                    id: section.id,
                    snippet,
                    matches,
                    sealed,
                });
            }
            if matched_day {
                result.days.push(date.to_string());
            }
        }
        Ok(result)
    }

    /// Writes every day into one Markdown file, oldest first, without the
    /// markers OmaFlow uses to find its own entries.
    pub fn export(&self, destination: &Path) -> Result<usize, String> {
        let dates = self.dates()?;
        let mut out = String::new();
        for &date in &dates {
            let Ok(text) = fs::read_to_string(self.day_path(date)) else {
                continue;
            };
            let document = parse(&text);
            if document.sections.is_empty() && document.preamble.trim().is_empty() {
                continue;
            }
            out.push_str(&render_plain(&document, date));
            out.push('\n');
        }
        write_owned(destination, out.trim_end().as_bytes())?;
        Ok(dates.len())
    }

    /// Moves every day OmaFlow keeps here, with its sidecar and recordings,
    /// into `destination`. Nothing is ever overwritten: if a day is already
    /// there, nothing moves. Each file is copied and read back first; the
    /// originals go only once every copy is right, and any failure before
    /// that removes the copies again. An original that will not go after
    /// that is named in `left_behind`: the days have moved all the same.
    /// Other files in the folder, such as notes or the to-do list, stay
    /// where they are.
    pub fn move_to(&self, destination: &Path) -> Result<Moved, MoveError> {
        let failed = |error: String| MoveError::Failed(error);
        // Nothing to move, and the lock would create the folder just left.
        if same_folder(&self.folder, destination) || !self.folder.is_dir() {
            return Ok(Moved::default());
        }
        let lock = self.lock().map_err(failed)?;
        self.empty_trash();
        let target = Journal::new(destination);
        let days = self.dates().map_err(failed)?;
        let mut files: Vec<(Date, PathBuf, PathBuf)> = days
            .iter()
            .map(|&date| (date, self.day_path(date), target.day_path(date)))
            .collect();
        for date in dated(&self.folder.join(".omaflow"), ".json") {
            files.push((date, self.sidecar_path(date), target.sidecar_path(date)));
        }
        for date in dated(&self.folder.join(".recordings"), "") {
            let folder = self.folder.join(".recordings").join(date.to_string());
            let Ok(recordings) = fs::read_dir(&folder) else {
                continue;
            };
            for recording in recordings.flatten() {
                let name = recording.file_name();
                let into = target.folder.join(".recordings").join(date.to_string());
                files.push((date, recording.path(), into.join(name)));
            }
        }
        let mut clashes: Vec<String> = files
            .iter()
            .filter(|(_, _, to)| to.symlink_metadata().is_ok())
            .map(|(date, _, _)| date.to_string())
            .collect();
        clashes.sort();
        clashes.dedup();
        if !clashes.is_empty() {
            return Err(MoveError::Clash(clashes));
        }

        let mut made = Made::default();
        let pairs = files
            .iter()
            .map(|(_, from, to)| (from.as_path(), to.as_path()));
        if let Err(error) = copy_all(pairs, destination, &mut made) {
            made.undo();
            return Err(failed(error));
        }
        // Every copy is in place and checked, so the originals can go.
        let left_behind = remove_moved(
            files.iter().map(|(_, from, _)| from.as_path()),
            &self.folder,
        );
        for date in dated(&self.folder.join(".recordings"), "") {
            let _ = fs::remove_dir(self.folder.join(".recordings").join(date.to_string()));
        }
        let _ = fs::remove_dir(self.folder.join(".recordings"));
        // The lock is ours; the folder it is in may hold the to-do list's too.
        drop(lock);
        let own = self.folder.join(".omaflow");
        let left = fs::read_dir(&own)
            .map(|names| names.flatten().count())
            .unwrap_or(0);
        if left == 1 && fs::remove_file(own.join("lock")).is_ok() {
            let _ = fs::remove_dir(&own);
        }
        Ok(Moved {
            days: days.len(),
            left_behind,
        })
    }

    /// Held while a day is read, changed and written back. The daemon saves
    /// spoken entries while the window may be saving a typed one.
    fn lock(&self) -> Result<fs::File, String> {
        let directory = self.folder.join(".omaflow");
        owned_dir(&directory)?;
        let path = directory.join("lock");
        let file = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&path)
            .map_err(|error| format!("{}: {error}", path.display()))?;
        file.lock()
            .map_err(|error| format!("could not lock {}: {error}", path.display()))?;
        Ok(file)
    }

    fn read_sidecar(&self, date: Date) -> Sidecar {
        fs::read(self.sidecar_path(date))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn write_sidecar(&self, date: Date, sidecar: &Sidecar) -> Result<(), String> {
        let path = self.sidecar_path(date);
        if let Some(parent) = path.parent() {
            owned_dir(parent)?;
        }
        let bytes = serde_json::to_vec(sidecar).map_err(|error| error.to_string())?;
        write_owned(&path, &bytes)
    }
}

/// A finished move: how many days moved, and the originals that could not
/// be removed from the old folder, by their names there.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Moved {
    pub days: usize,
    pub left_behind: Vec<String>,
}

/// Why the journal, or the to-do list, could not move to another folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MoveError {
    /// These days (YYYY-MM-DD), or the to-do file, are already in the new
    /// folder. Nothing moved.
    Clash(Vec<String>),
    /// A copy failed or did not read back the same. Nothing moved.
    Failed(String),
}

/// Dates named by the entries of `folder` that end in `suffix`, such as the
/// sidecars "2026-09-24.json" or the recording folders "2026-09-24".
fn dated(folder: &Path, suffix: &str) -> Vec<Date> {
    let Ok(names) = fs::read_dir(folder) else {
        return Vec::new();
    };
    let mut dates: Vec<Date> = names
        .flatten()
        .filter_map(|name| {
            let name = name.file_name().to_string_lossy().into_owned();
            name.strip_suffix(suffix)?.parse().ok()
        })
        .collect();
    dates.sort();
    dates
}

fn parse(text: &str) -> Document {
    let mut document = Document::default();
    let mut lines = text.lines().peekable();
    // Frontmatter stays where notes apps look for it: the first lines.
    if lines.peek().is_some_and(|line| line.trim_end() == "---") {
        let mut front = vec![lines.next().unwrap_or_default()];
        for line in lines.by_ref() {
            front.push(line);
            if line.trim_end() == "---" || line.trim_end() == "..." {
                break;
            }
        }
        document.front = front.join("\n");
    }
    let mut preamble = Vec::new();
    let mut fenced = false;
    for line in lines {
        let fence = line.trim_start().starts_with("```") || line.trim_start().starts_with("~~~");
        if !fenced && let Some(heading) = line.strip_prefix("## ") {
            document.sections.push(Section {
                heading: heading.trim().to_string(),
                id: 0,
                marked: false,
                typed: false,
                body: String::new(),
            });
            continue;
        }
        if fence {
            fenced = !fenced;
        }
        if let Some(section) = document.sections.last_mut() {
            match marker(line).filter(|_| !fenced && !section.marked) {
                Some((id, typed)) => {
                    section.id = id;
                    section.marked = true;
                    section.typed = typed;
                }
                None => {
                    section.body.push_str(line);
                    section.body.push('\n');
                }
            }
            continue;
        }
        match line.strip_prefix("# ") {
            Some(title)
                if !fenced
                    && document.title.is_none()
                    && preamble.iter().all(|l: &&str| l.trim().is_empty()) =>
            {
                document.title = Some(title.trim().to_string());
            }
            _ => preamble.push(line),
        }
    }
    document.preamble = trim_blank_lines(&preamble.join("\n"));
    for section in &mut document.sections {
        section.body = trim_blank_lines(&section.body);
    }
    // Sections OmaFlow did not write get an id from their own content, so it
    // stays with the section when another is inserted above it, and an edit
    // made in another editor is noticed instead of landing on the wrong one.
    let mut taken: Vec<u64> = document
        .sections
        .iter()
        .filter(|s| s.marked)
        .map(|s| s.id)
        .collect();
    for section in document.sections.iter_mut().filter(|s| !s.marked) {
        let mut id = content_id(&section.heading, &section.body);
        while taken.contains(&id) {
            id = id % (FIRST_REAL_ID - 1) + 1;
        }
        taken.push(id);
        section.id = id;
    }
    document
}

/// Drops blank lines at both ends and keeps the indentation of the rest.
fn trim_blank_lines(text: &str) -> String {
    let lines: Vec<&str> = text.lines().collect();
    let first = lines.iter().position(|line| !line.trim().is_empty());
    let last = lines.iter().rposition(|line| !line.trim().is_empty());
    match (first, last) {
        (Some(first), Some(last)) => lines[first..=last]
            .iter()
            .map(|line| line.trim_end())
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

fn content_id(heading: &str, body: &str) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in heading.bytes().chain([0]).chain(body.bytes()) {
        hash = (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3);
    }
    hash % (FIRST_REAL_ID - 1) + 1
}

/// Words you wrote can hold a line that looks like a section heading. It is
/// escaped on the way into the file, so it stays part of the entry.
fn escape_body(text: &str) -> String {
    trim_blank_lines(text)
        .lines()
        .map(|line| {
            if line.starts_with("## ") || line.starts_with("\\## ") {
                format!("\\{line}")
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn unescape_body(text: &str) -> String {
    text.lines()
        .map(|line| {
            line.strip_prefix('\\')
                .filter(|rest| rest.starts_with("## "))
                .unwrap_or(line)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn marker(line: &str) -> Option<(u64, bool)> {
    let inner = line
        .trim()
        .strip_prefix("<!-- omaflow:")?
        .strip_suffix("-->")?
        .trim();
    let mut words = inner.split_whitespace();
    let id = words
        .next()?
        .parse()
        .ok()
        .filter(|id| *id >= FIRST_REAL_ID)?;
    Some((id, words.any(|word| word == "typed")))
}

fn render(document: &Document, date: Date) -> String {
    let mut out = String::new();
    if !document.front.is_empty() {
        out.push_str(&document.front);
        out.push('\n');
    }
    // A file that had no title keeps having none; a new day gets one.
    let title = match &document.title {
        Some(title) => Some(title.clone()),
        None if document.front.is_empty() && document.preamble.is_empty() => Some(date.long()),
        None => None,
    };
    if let Some(title) = title {
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(&format!("# {title}\n"));
    }
    if !document.preamble.is_empty() {
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(&document.preamble);
        out.push('\n');
    }
    for section in &document.sections {
        out.push_str(&format!("\n## {}\n", section.heading));
        if section.marked {
            let typed = if section.typed { " typed" } else { "" };
            out.push_str(&format!("<!-- omaflow:{}{typed} -->\n", section.id));
        }
        if !section.body.is_empty() {
            out.push_str(&section.body);
            out.push('\n');
        }
    }
    out
}

fn render_plain(document: &Document, date: Date) -> String {
    let marked = Document {
        sections: document
            .sections
            .iter()
            .cloned()
            .map(|section| Section {
                marked: false,
                ..section
            })
            .collect(),
        ..document.clone()
    };
    render(&marked, date)
}

/// Lowercases one character at a time, so positions in the folded text are
/// positions in the original.
fn fold_chars(chars: &[char]) -> Vec<char> {
    chars
        .iter()
        .map(|character| character.to_lowercase().next().unwrap_or(*character))
        .collect()
}

fn fold(text: &str) -> Vec<char> {
    fold_chars(&text.chars().collect::<Vec<_>>())
}

fn find_all(haystack: &[char], needle: &[char]) -> Vec<usize> {
    let mut found = Vec::new();
    let mut start = 0;
    while start + needle.len() <= haystack.len() {
        if haystack[start..start + needle.len()] == *needle {
            found.push(start);
            start += needle.len();
        } else {
            start += 1;
        }
    }
    found
}

/// Around 180 characters starting at the sentence that holds the first
/// match. Short entries come back whole.
fn snippet(text: &[char], matches: &[usize], length: usize) -> (String, Vec<[usize; 2]>) {
    const WIDTH: usize = 180;
    if text.len() <= WIDTH {
        let positions = matches.iter().map(|&start| [start, length]).collect();
        return (text.iter().collect(), positions);
    }
    let first = matches[0];
    let mut start = first.saturating_sub(60);
    // Begin at the sentence the match is in, when that is close enough.
    if let Some(boundary) = (start..first).rev().find(|&index| {
        index > 0 && matches!(text[index - 1], '.' | '!' | '?') && text[index] == ' '
    }) {
        start = boundary + 1;
    }
    let end = (start + WIDTH).min(text.len());
    let prefix = if start > 0 { "…" } else { "" };
    let suffix = if end < text.len() { "…" } else { "" };
    let body: String = text[start..end].iter().collect();
    let offset = prefix.chars().count();
    let positions = matches
        .iter()
        .filter(|&&position| position >= start && position + length <= end)
        .map(|&position| [position - start + offset, length])
        .collect();
    (format!("{prefix}{}{suffix}", body.trim_end()), positions)
}

/// A coarse loudness outline of 16 kHz signed 16-bit mono PCM, `count` values
/// from 0 to 100. Speech sits in the upper half, room noise near the floor.
pub fn peaks(pcm: &[u8], count: usize) -> Vec<u8> {
    let samples: Vec<i16> = pcm
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| i16::from_le_bytes(*pair))
        .collect();
    if samples.is_empty() || count == 0 {
        return Vec::new();
    }
    let window = samples.len().div_ceil(count).max(1);
    samples
        .chunks(window)
        .map(|chunk| {
            let power = chunk
                .iter()
                .map(|&sample| {
                    let value = f32::from(sample) / 32768.0;
                    value * value
                })
                .sum::<f32>()
                / chunk.len() as f32;
            let dbfs = if power > 0.0 {
                10.0 * power.log10()
            } else {
                -96.0
            };
            (((dbfs + 60.0) / 60.0).clamp(0.0, 1.0) * 100.0).round() as u8
        })
        .collect()
}

const FILLERS: &[&str] = &[
    "umm", "uh", "uhh", "uhm", "erm", "hm", "äh", "ähm", "öhm", "ehm", "euh",
];
/// Words that are fillers in English and real words in German: "um 8 Uhr",
/// "er kommt". They only go when nothing suggests the German reading.
const AMBIGUOUS_FILLERS: &[&str] = &["um", "er"];
/// What follows a German "um": a time, an article, a pronoun.
const AFTER_GERMAN_UM: &[&str] = &[
    "die",
    "der",
    "das",
    "den",
    "dem",
    "des",
    "ein",
    "eine",
    "einen",
    "einem",
    "einer",
    "mich",
    "dich",
    "sich",
    "uns",
    "euch",
    "ihn",
    "sie",
    "es",
    "zu",
    "halb",
    "viertel",
    "mitternacht",
    "jeden",
    "mein",
    "meine",
    "meinen",
    "dein",
    "deine",
    "ihre",
    "seine",
    "eins",
    "zwei",
    "drei",
    "vier",
    "fünf",
    "sechs",
    "sieben",
    "acht",
    "neun",
    "zehn",
    "elf",
    "zwölf",
    "zwanzig",
    "dreißig",
];
/// Short words a stutter doubles. Words that are correctly doubled in normal
/// grammar ("that that", "die die") are not on the list.
const REPEATABLE: &[&str] = &[
    "the", "a", "an", "to", "of", "and", "i", "is", "in", "it", "we", "you", "und", "ich",
];

fn is_filler(token: &str, core: &str, next: Option<&str>) -> bool {
    if FILLERS.contains(&core) {
        return true;
    }
    if !AMBIGUOUS_FILLERS.contains(&core) {
        return false;
    }
    let punctuated = token.ends_with([',', '.', '!', '?', ';']);
    match core {
        // "er" as a filler comes with a pause: "er," or "er.".
        "er" => punctuated,
        _ => {
            punctuated
                || next.is_none_or(|next| {
                    let next = next
                        .trim_matches(|c: char| !c.is_alphanumeric())
                        .to_lowercase();
                    !(next.starts_with(|c: char| c.is_ascii_digit())
                        || AFTER_GERMAN_UM.contains(&next.as_str()))
                })
        }
    }
}

/// The journal's light cleanup: drops fillers such as "um" and stutters such
/// as "the the", and keeps every other word exactly as spoken.
pub fn tidy(text: &str) -> String {
    let mut words: Vec<String> = Vec::new();
    let mut capitalize_next = false;
    let tokens: Vec<&str> = text.split_whitespace().collect();
    for (index, token) in tokens.iter().copied().enumerate() {
        let core: String = token
            .trim_matches(|c: char| !c.is_alphanumeric())
            .to_lowercase();
        let sentence_start = words
            .last()
            .is_none_or(|previous| previous.ends_with(['.', '!', '?']));
        if is_filler(token, &core, tokens.get(index + 1).copied()) {
            // "…the plan, um. Then" keeps the full stop on the word before.
            if let Some(end) = token
                .chars()
                .last()
                .filter(|c| matches!(c, '.' | '!' | '?'))
                && let Some(previous) = words.last_mut()
                && !previous.ends_with(['.', '!', '?'])
            {
                previous.truncate(previous.trim_end_matches([',', ';', ':']).len());
                previous.push(end);
            }
            // ", uh," leaves one comma behind, not two.
            if token.ends_with(',')
                && let Some(previous) = words.last_mut()
                && previous.ends_with(',')
            {
                previous.pop();
            }
            capitalize_next |= sentence_start;
            continue;
        }
        let previous_core = words.last().map(|previous| {
            previous
                .trim_matches(|c: char| !c.is_alphanumeric())
                .to_lowercase()
        });
        if REPEATABLE.contains(&core.as_str())
            && previous_core.as_deref() == Some(core.as_str())
            && words
                .last()
                .is_some_and(|previous| previous.chars().last().is_some_and(char::is_alphanumeric))
        {
            continue;
        }
        let mut word = token.to_string();
        if capitalize_next || words.is_empty() {
            word = capitalize(&word);
            capitalize_next = false;
        }
        words.push(word);
    }
    words.join(" ")
}

fn capitalize(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn temp_journal(name: &str) -> Journal {
        let folder =
            std::env::temp_dir().join(format!("omaflow-journal-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&folder);
        Journal::new(folder)
    }

    fn spoken<'a>(id: u64, time: &'a str, text: &'a str, wav: Option<&'a [u8]>) -> NewEntry<'a> {
        NewEntry {
            id,
            time,
            text,
            typed: false,
            raw_text: "so um I slept badly",
            duration_ms: 48_000,
            peaks: vec![10, 80, 40],
            recording: wav,
        }
    }

    #[test]
    fn a_note_for_a_later_day_says_when_it_was_written() {
        let journal = temp_journal("note");
        let written: Date = "2026-09-30".parse().unwrap();
        let due: Date = "2027-09-30".parse().unwrap();
        let heading = note_heading(written, "21:53");
        assert_eq!(heading, "Note from 2026-09-30, 21:53");
        journal
            .add(
                due,
                spoken(1_790_000_000_000, &heading, "Did you keep running?", None),
            )
            .unwrap();
        let day = journal.day(due).unwrap();
        assert_eq!(day.entries[0].written, "2026-09-30");
        assert_eq!(day.entries[0].time, heading);
        assert!(
            fs::read_to_string(journal.day_path(due))
                .unwrap()
                .contains("## Note from 2026-09-30, 21:53")
        );
        // An ordinary entry is not a note, whatever it says.
        assert_eq!(written_on("07:42"), None);
        assert_eq!(written_on("Note from nowhere"), None);
    }

    #[test]
    fn an_entry_added_to_a_past_day_goes_in_by_time_and_says_when() {
        let journal = temp_journal("added");
        let day: Date = "2026-09-24".parse().unwrap();
        let today: Date = "2026-10-06".parse().unwrap();
        for (id, time) in [(1_758_700_000_000, "07:42"), (1_758_720_000_000, "18:30")] {
            journal
                .add(day, spoken(id, time, "Same day.", None))
                .unwrap();
        }
        let heading = added_heading("12:15", today);
        assert_eq!(heading, "12:15, added 2026-10-06");
        let added = journal
            .add(
                day,
                spoken(1_759_780_000_000, &heading, "Lunch with Mira.", None),
            )
            .unwrap();
        assert_eq!(
            (added.time.as_str(), added.added.as_str()),
            ("12:15", "2026-10-06")
        );

        let entries = journal.day(day).unwrap().entries;
        let times: Vec<&str> = entries.iter().map(|entry| entry.time.as_str()).collect();
        assert_eq!(
            times,
            vec!["07:42", "12:15", "18:30"],
            "filed in time order"
        );
        assert_eq!(entries[1].added, "2026-10-06");
        assert!(entries[0].added.is_empty() && entries[1].written.is_empty());
        let file = fs::read_to_string(journal.day_path(day)).unwrap();
        assert!(
            file.contains("## 12:15, added 2026-10-06\n<!-- omaflow:"),
            "{file}"
        );

        // Like any entry: searched, counted, a year on, deleted and back.
        assert_eq!(journal.search("mira", day).unwrap().hits[0].time, "12:15");
        assert_eq!(journal.month(2026, 9).unwrap()[0].entries, 3);
        let later = journal.a_year_ago("2027-09-24".parse().unwrap()).unwrap();
        assert_eq!(later.unwrap().1.time, "07:42");
        journal.delete(day, added.id).unwrap();
        journal.restore(day, added.id).unwrap();
        assert_eq!(journal.day(day).unwrap().entries, entries);
        assert_eq!(added_on("Morning"), None);
        let _ = fs::remove_dir_all(journal.folder());
    }

    /// Every file under `folder`, with its bytes, to compare a folder before
    /// and after.
    fn snapshot(folder: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
        let mut files = BTreeMap::new();
        let mut folders = vec![folder.to_path_buf()];
        while let Some(next) = folders.pop() {
            for entry in fs::read_dir(&next).into_iter().flatten().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    folders.push(path);
                } else {
                    let name = path.strip_prefix(folder).unwrap().to_path_buf();
                    files.insert(name, fs::read(&path).unwrap());
                }
            }
        }
        files
    }

    fn journal_with_two_days(name: &str) -> Journal {
        let journal = temp_journal(name);
        for date in ["2026-09-24", "2026-09-25"] {
            journal
                .add(
                    date.parse().unwrap(),
                    spoken(1_758_700_000_000, "07:42", "Slept badly.", Some(b"RIFF")),
                )
                .unwrap();
        }
        // Not the journal's: a note of yours and the to-do list's own file.
        fs::write(journal.folder().join("ideas.md"), "Mine.").unwrap();
        fs::write(journal.folder().join(".omaflow/todos.lock"), "").unwrap();
        journal
    }

    #[test]
    fn moving_the_journal_takes_its_days_recordings_and_nothing_else() {
        let journal = journal_with_two_days("move");
        let destination = journal.folder().with_extension("moved");
        let _ = fs::remove_dir_all(&destination);
        let date: Date = "2026-09-25".parse().unwrap();
        let before = journal.day(date).unwrap();

        assert_eq!(
            journal.move_to(&destination),
            Ok(Moved {
                days: 2,
                left_behind: Vec::new()
            })
        );
        let moved = Journal::new(&destination);
        assert_eq!(moved.dates().unwrap().len(), 2);
        assert_eq!(
            moved.day(date).unwrap().entries,
            before.entries,
            "words, waveform and recording"
        );
        assert!(moved.recording_path(date, before.entries[0].id).is_file());
        assert!(journal.dates().unwrap().is_empty());
        assert_eq!(
            snapshot(journal.folder()).into_keys().collect::<Vec<_>>(),
            vec![
                PathBuf::from(".omaflow/lock"),
                PathBuf::from(".omaflow/todos.lock"),
                PathBuf::from("ideas.md")
            ],
            "your own files stay"
        );
        assert_eq!(
            moved.move_to(&destination),
            Ok(Moved::default()),
            "the same folder is no move"
        );
        let _ = fs::remove_dir_all(journal.folder());
        let _ = fs::remove_dir_all(&destination);
    }

    #[test]
    fn moving_onto_days_already_there_moves_nothing() {
        let journal = journal_with_two_days("move-clash");
        let destination = journal.folder().with_extension("clash");
        let _ = fs::remove_dir_all(&destination);
        fs::create_dir_all(&destination).unwrap();
        fs::write(destination.join("2026-09-25.md"), "# Theirs\n").unwrap();
        let (source, target) = (snapshot(journal.folder()), snapshot(&destination));

        assert_eq!(
            journal.move_to(&destination),
            Err(MoveError::Clash(vec!["2026-09-25".into()]))
        );
        assert_eq!(snapshot(journal.folder()), source);
        assert_eq!(snapshot(&destination), target);
        let _ = fs::remove_dir_all(journal.folder());
        let _ = fs::remove_dir_all(&destination);
    }

    #[test]
    fn a_move_that_fails_halfway_takes_its_copies_back() {
        let journal = journal_with_two_days("move-fails");
        let destination = journal.folder().with_extension("fails");
        let _ = fs::remove_dir_all(&destination);
        fs::create_dir_all(&destination).unwrap();
        // The day files copy, then the recordings cannot: a file is in the way.
        fs::write(destination.join(".recordings"), "").unwrap();
        let (source, target) = (snapshot(journal.folder()), snapshot(&destination));

        let result = journal.move_to(&destination);
        assert!(matches!(result, Err(MoveError::Failed(_))), "{result:?}");
        assert_eq!(snapshot(journal.folder()), source, "the originals stay");
        assert_eq!(snapshot(&destination), target, "and the copies are gone");
        assert!(!destination.join(".omaflow").exists());
        let _ = fs::remove_dir_all(journal.folder());
        let _ = fs::remove_dir_all(&destination);
    }

    #[test]
    fn a_move_whose_originals_will_not_go_still_moves_and_names_them() {
        let journal = journal_with_two_days("move-stuck");
        let destination = journal.folder().with_extension("stuck");
        let _ = fs::remove_dir_all(&destination);
        // The day files can be read and copied, but not removed from here.
        fs::set_permissions(journal.folder(), fs::Permissions::from_mode(0o555)).unwrap();

        let result = journal.move_to(&destination);
        fs::set_permissions(journal.folder(), fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(
            result,
            Ok(Moved {
                days: 2,
                left_behind: vec!["2026-09-24.md".into(), "2026-09-25.md".into()]
            })
        );
        assert_eq!(Journal::new(&destination).dates().unwrap().len(), 2);
        let _ = fs::remove_dir_all(journal.folder());
        let _ = fs::remove_dir_all(&destination);
    }

    #[test]
    fn a_deleted_entry_comes_back_whole_and_in_place() {
        let journal = temp_journal("restore");
        let date: Date = "2026-09-25".parse().unwrap();
        let first = journal
            .add(
                date,
                spoken(1_758_778_920_000, "07:42", "Slept badly.", Some(b"RIFF")),
            )
            .unwrap();
        journal
            .add(
                date,
                spoken(1_758_795_300_000, "12:15", "Lunch with Mira.", None),
            )
            .unwrap();
        let before = journal.day(date).unwrap();
        let file = fs::read_to_string(journal.day_path(date)).unwrap();

        journal.delete(date, first.id).unwrap();
        assert_eq!(journal.day(date).unwrap().entries.len(), 1);
        assert!(!journal.recording_path(date, first.id).exists());

        journal.restore(date, first.id).unwrap();
        let after = journal.day(date).unwrap();
        assert_eq!(
            after.entries, before.entries,
            "words, spoken text, waveform, recording and place"
        );
        assert_eq!(fs::read_to_string(journal.day_path(date)).unwrap(), file);
        assert!(journal.recording_path(date, first.id).is_file());
        assert!(journal.restore(date, first.id).is_err(), "undo only once");
    }

    #[test]
    fn deleted_entries_are_only_kept_for_undo() {
        let journal = temp_journal("trash");
        let date: Date = "2026-09-25".parse().unwrap();
        let one = journal
            .add(
                date,
                spoken(1_758_778_920_000, "07:42", "One.", Some(b"RIFF")),
            )
            .unwrap();
        let two = journal
            .add(
                date,
                spoken(1_758_795_300_000, "12:15", "Two.", Some(b"RIFF")),
            )
            .unwrap();
        journal.delete(date, one.id).unwrap();
        // The next delete empties the trash: only the last one can come back.
        journal.delete(date, two.id).unwrap();
        assert!(journal.restore(date, one.id).is_err());
        // And after a while nothing can: the words and the recording are gone.
        let record = journal.trash_dir().join("entry.json");
        let mut trashed: Trashed = serde_json::from_slice(&fs::read(&record).unwrap()).unwrap();
        trashed.deleted_at_ms -= TRASH_KEEP_MS + 1;
        fs::write(&record, serde_json::to_vec(&trashed).unwrap()).unwrap();
        journal.forget_stale_trash();
        assert!(!journal.trash_dir().exists());
        assert!(journal.restore(date, two.id).is_err());
    }

    #[test]
    fn deleting_recordings_keeps_the_words() {
        let journal = temp_journal("delete-recordings");
        let date: Date = "2026-09-25".parse().unwrap();
        let entry = journal
            .add(date, spoken(1, "07:42", "Slept badly.", Some(b"RIFF")))
            .unwrap();
        assert!(journal.recording_path(date, entry.id).is_file());
        assert_eq!(journal.recording_count(), 1);

        journal.delete_recordings().unwrap();
        assert_eq!(journal.recording_count(), 0);
        journal.delete_recordings().unwrap();
        let day = journal.day(date).unwrap();
        assert_eq!(day.entries[0].text, "Slept badly.");
        assert_eq!(day.entries[0].peaks, vec![10, 80, 40]);
        assert!(!day.entries[0].audio);
    }

    #[test]
    fn spoken_and_typed_entries_round_trip_through_markdown() {
        let journal = temp_journal("round-trip");
        let date: Date = "2026-09-25".parse().unwrap();
        let first = journal
            .add(
                date,
                spoken(1_758_778_920_000, "07:42", "Slept badly.", Some(b"RIFF")),
            )
            .unwrap();
        let typed = journal
            .add(
                date,
                NewEntry {
                    id: 1_758_778_920_000,
                    time: "18:30",
                    text: "Ran 5 km along the river.",
                    typed: true,
                    raw_text: "",
                    duration_ms: 0,
                    peaks: Vec::new(),
                    recording: None,
                },
            )
            .unwrap();
        assert_ne!(first.id, typed.id, "ids stay unique within a day");

        let text = fs::read_to_string(journal.day_path(date)).unwrap();
        assert!(text.starts_with("# Friday, 25 September 2026\n\n## 07:42\n<!-- omaflow:"));
        assert!(text.contains("typed -->\nRan 5 km along the river.\n"));

        let day = journal.day(date).unwrap();
        assert!(day.exists);
        assert_eq!(day.entries.len(), 2);
        assert_eq!(day.entries[0].raw_text, "so um I slept badly");
        assert_eq!(day.entries[0].peaks, vec![10, 80, 40]);
        assert!(day.entries[0].audio);
        assert!(day.entries[1].typed && !day.entries[1].audio);

        journal
            .edit(date, first.id, "Slept badly, light was lovely.")
            .unwrap();
        assert_eq!(
            journal.day(date).unwrap().entries[0].text,
            "Slept badly, light was lovely."
        );
        journal.delete(date, first.id).unwrap();
        assert!(!journal.recording_path(date, first.id).exists());
        assert_eq!(journal.day(date).unwrap().entries.len(), 1);
        let _ = fs::remove_dir_all(journal.folder());
    }

    #[test]
    fn hand_written_days_keep_their_own_words_and_headings() {
        let journal = temp_journal("hand-written");
        let date: Date = "2026-09-24".parse().unwrap();
        fs::create_dir_all(journal.folder()).unwrap();
        fs::write(
            journal.day_path(date),
            "# Thursday\n\nA quiet day.\n\n## Morning\nTea.\n\nSecond paragraph.\n\n## 21:00\nBed.\n",
        )
        .unwrap();
        let day = journal.day(date).unwrap();
        assert_eq!(day.title, "Thursday");
        assert_eq!(day.entries.len(), 2);
        assert_eq!(day.entries[0].time, "Morning");
        assert_eq!(day.entries[0].text, "Tea.\n\nSecond paragraph.");

        journal.edit(date, day.entries[1].id, "Bed early.").unwrap();
        let text = fs::read_to_string(journal.day_path(date)).unwrap();
        assert_eq!(
            text,
            "# Thursday\n\nA quiet day.\n\n## Morning\nTea.\n\nSecond paragraph.\n\n## 21:00\nBed early.\n"
        );
        let _ = fs::remove_dir_all(journal.folder());
    }

    #[test]
    fn notes_app_files_survive_edits_intact() {
        let journal = temp_journal("notes-app");
        let date: Date = "2026-09-24".parse().unwrap();
        fs::create_dir_all(journal.folder()).unwrap();
        let original = "---\ntags: [daily]\n---\n# My day\n\n## Code\n```\n## not a heading\n```\n\n## Evening\n    indented first line\nsecond\n";
        fs::write(journal.day_path(date), original).unwrap();
        let day = journal.day(date).unwrap();
        assert_eq!(day.title, "My day");
        assert_eq!(
            day.entries.len(),
            2,
            "a heading inside a code fence is not a section"
        );
        assert_eq!(day.entries[1].text, "    indented first line\nsecond");

        // An entry that holds a heading-looking line stays one entry.
        journal
            .edit(
                date,
                day.entries[1].id,
                "line one\n## Not a heading\nline two",
            )
            .unwrap();
        let text = fs::read_to_string(journal.day_path(date)).unwrap();
        assert!(
            text.starts_with("---\ntags: [daily]\n---\n\n# My day\n"),
            "{text}"
        );
        let day = journal.day(date).unwrap();
        assert_eq!(day.entries.len(), 2);
        assert_eq!(day.entries[1].text, "line one\n## Not a heading\nline two");

        // A section added above in another editor does not shift the ids.
        let evening = day.entries[1].id;
        let text = fs::read_to_string(journal.day_path(date))
            .unwrap()
            .replace("## Code", "## Lunch\nSoup.\n\n## Code");
        fs::write(journal.day_path(date), text).unwrap();
        journal.delete(date, evening).unwrap();
        let left: Vec<String> = journal
            .day(date)
            .unwrap()
            .entries
            .into_iter()
            .map(|e| e.time)
            .collect();
        assert_eq!(left, vec!["Lunch", "Code"]);
        let _ = fs::remove_dir_all(journal.folder());
    }

    #[test]
    fn search_finds_words_across_days_newest_first() {
        let journal = temp_journal("search");
        for (date, text) in [
            ("2026-09-09", "Signed up to help at the workshop next week."),
            (
                "2026-09-16",
                "Mira's Omarchy Workshop tonight. Twelve people.",
            ),
            ("2026-09-20", "Nothing to see here."),
        ] {
            journal
                .add(
                    date.parse().unwrap(),
                    spoken(1_758_000_000_000, "08:10", text, None),
                )
                .unwrap();
        }
        let result = journal
            .search("workshop", "2026-09-20".parse().unwrap())
            .unwrap();
        assert_eq!(result.days, vec!["2026-09-16", "2026-09-09"]);
        assert_eq!(result.hits[0].matches, vec![[15, 8]]);
        assert_eq!(
            journal.month(2026, 9).unwrap().len(),
            3,
            "every day with an entry gets a dot"
        );
        let _ = fs::remove_dir_all(journal.folder());
    }

    #[test]
    fn search_finds_a_sealed_note_without_showing_its_words() {
        let journal = temp_journal("sealed-search");
        let today: Date = "2026-09-20".parse().unwrap();
        let later: Date = "2026-10-02".parse().unwrap();
        let heading = note_heading(today, "21:10");
        journal
            .add(
                later,
                spoken(
                    1_758_000_000_000,
                    &heading,
                    "Ask Mira about the lease.",
                    None,
                ),
            )
            .unwrap();
        let hit = &journal.search("mira", today).unwrap().hits[0];
        assert!(hit.sealed && hit.snippet.is_empty() && hit.matches.is_empty());
        assert_eq!(hit.date, "2026-10-02");
        // Once the day comes, it reads like any entry.
        let hit = &journal.search("mira", later).unwrap().hits[0];
        assert!(!hit.sealed && hit.snippet.contains("Mira"));
        let _ = fs::remove_dir_all(journal.folder());
    }

    #[test]
    fn long_entries_are_cut_to_the_sentence_holding_the_match() {
        let text: Vec<char> = format!(
            "{} She asked if I'd take over the Omarchy workshop. I said yes. {}",
            "Lunch with Mira and a long story about the studio.".repeat(3),
            "More words follow here.".repeat(6)
        )
        .chars()
        .collect();
        let matches = find_all(&fold_chars(&text), &fold("workshop"));
        let (snippet, positions) = snippet(&text, &matches, 8);
        assert!(snippet.starts_with("…She asked"), "{snippet}");
        let chars: Vec<char> = snippet.chars().collect();
        let [start, length] = positions[0];
        assert_eq!(
            chars[start..start + length].iter().collect::<String>(),
            "workshop"
        );
    }

    #[test]
    fn light_cleanup_drops_fillers_and_stutters_only() {
        assert_eq!(
            tidy("um so I think the the plan is, uh, fine. Um, no no no."),
            "So I think the plan is fine. No no no."
        );
        assert_eq!(tidy("Ähm ich ich weiß nicht"), "Ich weiß nicht");
        assert_eq!(tidy("It was good, um."), "It was good.");
        assert_eq!(tidy("so um I slept badly"), "So I slept badly");
        // German, where "um" and "er" are words and doubles are grammar.
        assert_eq!(tidy("Er kommt um acht Uhr"), "Er kommt um acht Uhr");
        assert_eq!(tidy("Ich komme um 8 Uhr"), "Ich komme um 8 Uhr");
        assert_eq!(
            tidy("die Frau, die die Blumen kauft"),
            "Die Frau, die die Blumen kauft"
        );
        assert_eq!(
            tidy("I said that that was fine"),
            "I said that that was fine"
        );
        assert_eq!(tidy("It was, er, fine"), "It was fine");
    }

    #[test]
    fn peaks_follow_loudness() {
        let mut pcm = Vec::new();
        for index in 0..32_000 {
            let sample: i16 = if index < 16_000 { 0 } else { 12_000 };
            pcm.extend_from_slice(&sample.to_le_bytes());
        }
        let peaks = peaks(&pcm, 4);
        assert_eq!(peaks.len(), 4);
        assert_eq!(peaks[0], 0);
        assert!(peaks[3] > 80);
    }
}
