//! `omaflow journal …`: reads and edits the journal for the panel. These run
//! without the daemon and print JSON, so the window can ask for a day, a
//! month or a search the moment it needs one.
use crate::config::Config;
use omaflow_core::{
    date::Date,
    journal::{Journal, MoveError, NewEntry},
};
use serde_json::{Value, json};
use std::{
    env,
    io::IsTerminal,
    path::PathBuf,
    process::ExitCode,
    time::{SystemTime, UNIX_EPOCH},
};

pub fn run(mut args: impl Iterator<Item = String>) -> ExitCode {
    let result = Config::load().and_then(|config| {
        let journal = Journal::new(config.journal.folder_path());
        journal.forget_stale_trash();
        let command = args.next().unwrap_or_default();
        dispatch(&journal, &command, &mut args)
    });
    match result {
        Ok(value) => {
            println!("{value}");
            ExitCode::SUCCESS
        }
        // The window reads the JSON; a person at a terminal needs only the words.
        Err(error) => {
            if !std::io::stdout().is_terminal() {
                println!("{}", json!({ "error": error }));
            }
            eprintln!("omaflow: {error}");
            ExitCode::FAILURE
        }
    }
}

fn dispatch(
    journal: &Journal,
    command: &str,
    args: &mut impl Iterator<Item = String>,
) -> Result<Value, String> {
    let mut next = |what: &str| args.next().ok_or_else(|| format!("Missing {what}"));
    match command {
        "day" => {
            let date = parse_date(&next("date")?)?;
            to_value(journal.day(date)?)
        }
        "month" => {
            let month = next("month like 2026-09")?;
            let date = parse_date(&format!("{month}-01"))?;
            Ok(json!({
                "month": month,
                "days": to_value(journal.month(date.year, date.month)?)?,
            }))
        }
        "stats" => Ok(json!({
            "days": journal.dates()?.len(),
            "recordings": journal.recording_count(),
        })),
        "search" => {
            let (today, _) = omaflow_platform::clock::local_now();
            to_value(journal.search(&next("words to search for")?, today)?)
        }
        "year-ago" => {
            let date = parse_date(&next("date")?)?;
            Ok(match journal.a_year_ago(date)? {
                Some((day, entry)) => json!({ "date": day.date, "entry": entry }),
                None => Value::Null,
            })
        }
        "add" => {
            let text = next("text")?;
            let (today, now) = omaflow_platform::clock::local_now();
            // A later day makes the entry a note to yourself for that day; a
            // past day gets it added, saying when it really was written.
            let (date, time) = match args.next().map(|day| parse_date(&day)).transpose()? {
                Some(day) if day > today => (day, omaflow_core::journal::note_heading(today, &now)),
                Some(day) if day < today => (day, omaflow_core::journal::added_heading(&now, today)),
                _ => (today, now),
            };
            let id = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as u64;
            let entry = journal.add(
                date,
                NewEntry {
                    id,
                    time: &time,
                    text: &text,
                    typed: true,
                    raw_text: "",
                    duration_ms: 0,
                    peaks: Vec::new(),
                    recording: None,
                },
            )?;
            Ok(json!({ "date": date.to_string(), "entry": entry }))
        }
        "edit" => {
            let date = parse_date(&next("date")?)?;
            let id = parse_id(&next("entry id")?)?;
            journal.edit(date, id, &next("text")?)?;
            Ok(json!({ "ok": true }))
        }
        "delete" => {
            let date = parse_date(&next("date")?)?;
            let id = parse_id(&next("entry id")?)?;
            journal.delete(date, id)?;
            Ok(json!({ "ok": true }))
        }
        "due" => {
            // Notes written ahead to today that have not been announced yet.
            // Each is announced once, however often the shell asks.
            let (today, _) = omaflow_platform::clock::local_now();
            let path = crate::state_dir().join("delivered-notes.json");
            let mut delivered: Vec<u64> = std::fs::read(&path)
                .ok()
                .and_then(|bytes| serde_json::from_slice(&bytes).ok())
                .unwrap_or_default();
            let due: Vec<_> = journal
                .day(today)?
                .entries
                .into_iter()
                .filter(|entry| !entry.written.is_empty() && !delivered.contains(&entry.id))
                .collect();
            if !due.is_empty() {
                delivered.extend(due.iter().map(|entry| entry.id));
                let keep = delivered.len().saturating_sub(500);
                delivered.drain(..keep);
                let bytes = serde_json::to_vec(&delivered).map_err(|error| error.to_string())?;
                omaflow_core::fsutil::private_dir(&crate::state_dir())?;
                omaflow_core::fsutil::write_private(&path, &bytes)?;
            }
            Ok(json!({ "date": today.to_string(), "notes": due }))
        }
        "move-folder" => {
            // Run by the window, which can write both folders; the sandboxed
            // daemon can only write the folder it was given. The days and
            // the setting move together, so the journal never points at a
            // folder its days have left.
            let folder = next("folder")?.trim().to_string();
            if !(folder.starts_with('/') || folder.starts_with('~')) {
                return Err("Enter a full folder path, such as ~/Documents/Journal".into());
            }
            let destination = omaflow_core::config::expand_home(&folder);
            // Days whose originals could not be removed have still moved:
            // the copies are checked, so the folder changes with them.
            match journal.move_to(&destination) {
                Ok(moved) => match Config::save_setting("journal_folder", json!(folder)) {
                    Ok(_) => Ok(json!({
                        "days": moved.days,
                        "moved": moved.days,
                        "folder": folder,
                        "left_behind": moved.left_behind,
                    })),
                    Err(error) => Err(match Journal::new(&destination).move_to(journal.folder()) {
                        Ok(_) => format!("Could not save the new folder: {error}. Nothing was moved."),
                        Err(_) => format!(
                            "Your days are in {folder}, but the setting could not be saved: {error}. Choose {folder} again in Journal settings."
                        ),
                    }),
                },
                Err(MoveError::Clash(days)) => Err(format!(
                    "{} already {} in {folder}: {}. Nothing was moved. Move or rename those files in {folder}, or choose another folder.",
                    plural(days.len(), "day"),
                    if days.len() == 1 { "exists" } else { "exist" },
                    days.join(", ")
                )),
                Err(MoveError::Failed(error)) => Err(format!(
                    "Could not move your days to {folder}: {error}. Nothing was moved."
                )),
            }
        }
        "forget-deleted" => {
            journal.empty_trash();
            Ok(json!({ "ok": true }))
        }
        "restore" => {
            let date = parse_date(&next("date")?)?;
            let id = parse_id(&next("entry id")?)?;
            journal.restore(date, id)?;
            Ok(json!({ "ok": true }))
        }
        "export" => {
            let (today, _) = omaflow_platform::clock::local_now();
            let destination = export_folder().join(format!("Journal {today}.md"));
            let days = journal.export(&destination)?;
            Ok(json!({ "path": destination, "days": days }))
        }
        _ => Err(
            "Usage: omaflow journal day DATE | month YYYY-MM | stats | search WORDS | year-ago DATE | \
             add TEXT [DATE] | due | edit DATE ID TEXT | delete DATE ID | restore DATE ID | forget-deleted | \
             move-folder FOLDER | export"
                .into(),
        ),
    }
}

fn plural(count: usize, word: &str) -> String {
    if count == 1 {
        format!("1 {word}")
    } else {
        format!("{count} {word}s")
    }
}

fn to_value(value: impl serde::Serialize) -> Result<Value, String> {
    serde_json::to_value(value).map_err(|error| error.to_string())
}

fn parse_date(value: &str) -> Result<Date, String> {
    value.parse()
}

fn parse_id(value: &str) -> Result<u64, String> {
    value
        .parse()
        .map_err(|_| format!("{value} is not an entry id"))
}

/// Downloads, where people look for a file they just exported.
fn export_folder() -> PathBuf {
    let home = PathBuf::from(env::var_os("HOME").unwrap_or_default());
    let downloads = env::var_os("XDG_DOWNLOAD_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join("Downloads"));
    if downloads.is_dir() { downloads } else { home }
}
