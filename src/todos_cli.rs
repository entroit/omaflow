//! `omaflow todos …`: reads and edits the to-do list for the panel. Like the
//! journal's, these run without the daemon and print JSON. A task is named by
//! its place in the list and its words, as `omaflow todos list` shows them.
use crate::config::Config;
use omaflow_core::{
    date::Date,
    journal::MoveError,
    todos::{self, NewTodo, TodoList},
};
use serde_json::{Value, json};
use std::{io::IsTerminal, process::ExitCode};

pub fn run(mut args: impl Iterator<Item = String>) -> ExitCode {
    let result = Config::load().and_then(|config| {
        let todos = TodoList::new(config.todos.folder_path());
        todos.forget_stale_trash();
        let command = args.next().unwrap_or_default();
        dispatch(&todos, &command, &mut args, config.todos.remind_before)
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
    todos: &TodoList,
    command: &str,
    args: &mut impl Iterator<Item = String>,
    remind_before: u32,
) -> Result<Value, String> {
    let mut next = |what: &str| args.next().ok_or_else(|| format!("Missing {what}"));
    match command {
        "list" => Ok(json!({
            "path": todos.path(),
            "today": today().to_string(),
            "lists": todos.lists()?,
            "current": todos.current_list(),
            "todos": serde_json::to_value(todos.list()?).map_err(|error| error.to_string())?,
            // Reminders that have gone off on to-dos still open: Today
            // offers to snooze them.
            "reminded": todos.reminded(remind_before)?,
            "remind_before": remind_before,
        })),
        // Typed, so one task per line, each with its own "by Friday at 3pm"
        // if it says one. LIST is "" for the Inbox; DUE is the date for lines
        // that name none, as when typing on Today.
        "add" => {
            let text = next("text")?;
            let list = args.next().unwrap_or_default();
            let default_due = match args.next().filter(|due| !due.is_empty()) {
                Some(due) => Some(parse_date(&due)?),
                None => None,
            };
            let (today, now) = omaflow_platform::clock::local_now();
            let items: Vec<NewTodo> = text
                .lines()
                .map(|line| {
                    let said = todos::due(line, today, &now);
                    NewTodo {
                        text: said.text,
                        due: said.date.or(default_due),
                        time: said.time,
                        remind: said.remind,
                    }
                })
                .collect();
            let added = todos.add(&items, &list)?;
            Ok(json!({ "added": serde_json::to_value(added).map_err(|error| error.to_string())? }))
        }
        "due" => {
            let index = parse_index(&next("index")?)?;
            let text = next("text")?;
            let due = match next("date, or \"\" for none")?.as_str() {
                "" => None,
                due => Some(parse_date(due)?),
            };
            let time = args.next().filter(|time| !time.is_empty());
            let remind = args
                .next()
                .map(|remind| parse_remind(&remind))
                .transpose()?;
            todos.set_due(index, &text, due, time.as_deref(), remind)?;
            Ok(json!({ "ok": true }))
        }
        // When a to-do reminds you: "default", "off", or minutes before.
        "remind" => {
            let index = parse_index(&next("index")?)?;
            let text = next("text")?;
            let remind = parse_remind(&next("default, off, or minutes before")?)?;
            todos.set_reminder(index, &text, remind)?;
            Ok(json!({ "ok": true }))
        }
        // Remind again in some minutes, or "tomorrow" at the same moment.
        "snooze" => {
            let index = parse_index(&next("index")?)?;
            let text = next("text")?;
            let (today, now) = omaflow_platform::clock::local_now();
            let now = format!("{today} {now}");
            let until = match next("minutes, or tomorrow")?.as_str() {
                "tomorrow" => todos::later(&now, 24 * 60),
                minutes => todos::later(
                    &now,
                    minutes
                        .parse()
                        .map_err(|_| format!("Not a number of minutes: {minutes}"))?,
                ),
            }
            .ok_or("Could not read the clock")?;
            todos.set_reminder(index, &text, todos::Remind::At(until.clone()))?;
            Ok(json!({ "until": until }))
        }
        // To-dos whose time has come, each once; the shell shows them.
        "reminders" => {
            let (today, now) = omaflow_platform::clock::local_now();
            let due = todos.reminders(today, &now, remind_before)?;
            Ok(
                json!({ "reminders": serde_json::to_value(due).map_err(|error| error.to_string())? }),
            )
        }
        "move" => {
            let index = parse_index(&next("index")?)?;
            let text = next("text")?;
            let moved = todos.move_to(&[(index, text)], &next("list, or \"\" for the Inbox")?)?;
            Ok(json!({ "moved": serde_json::to_value(moved).map_err(|error| error.to_string())? }))
        }
        "new-list" => Ok(json!({ "list": todos.create_list(&next("name")?)? })),
        "rename-list" => {
            let name = next("list")?;
            Ok(json!({ "list": todos.rename_list(&name, &next("new name")?)? }))
        }
        "delete-list" => Ok(json!({ "moved": todos.delete_list(&next("list")?)? })),
        "done" | "undone" => {
            let index = parse_index(&next("index")?)?;
            todos.set_done(index, &next("text")?, command == "done")?;
            Ok(json!({ "ok": true }))
        }
        "edit" => {
            let index = parse_index(&next("index")?)?;
            let text = next("text")?;
            todos.edit(index, &text, &next("new text")?)?;
            Ok(json!({ "ok": true }))
        }
        "delete" => {
            let index = parse_index(&next("index")?)?;
            let removed = todos.remove(&[(index, next("text")?)], true)?;
            Ok(json!({ "removed": removed }))
        }
        "clear-done" => {
            let list = args.next();
            Ok(json!({ "removed": todos.clear_done(list.as_deref())? }))
        }
        "restore" => Ok(json!({ "restored": todos.restore()? })),
        "move-folder" => {
            // Like the journal's: run by the window, which can write both
            // folders, and the list and the setting move together.
            let folder = next("folder")?.trim().to_string();
            if !(folder.starts_with('/') || folder.starts_with('~')) {
                return Err("Enter a full folder path, such as ~/Documents/To-dos".into());
            }
            let destination = omaflow_core::config::expand_home(&folder);
            match todos.move_folder(&destination) {
                Ok(left_behind) => match Config::save_setting("todos_folder", json!(folder)) {
                    Ok(_) => {
                        Ok(json!({ "moved": true, "folder": folder, "left_behind": left_behind }))
                    }
                    Err(error) => Err(
                        match TodoList::new(&destination).move_folder(todos.folder()) {
                            Ok(_) => format!(
                                "Could not save the new folder: {error}. Nothing was moved."
                            ),
                            Err(_) => format!(
                                "Your to-dos are in {folder}, but the setting could not be saved: {error}. Choose {folder} again for your to-dos."
                            ),
                        },
                    ),
                },
                Err(MoveError::Clash(_)) => Err(format!(
                    "To-dos.md already exists in {folder}. Nothing was moved. Move or rename it there, or choose another folder."
                )),
                Err(MoveError::Failed(error)) => Err(format!(
                    "Could not move your to-dos to {folder}: {error}. Nothing was moved."
                )),
            }
        }
        "forget-deleted" => {
            todos.empty_trash();
            Ok(json!({ "ok": true }))
        }
        "" => Err(USAGE.into()),
        other => Err(format!("Unknown todos command: {other}")),
    }
}

const USAGE: &str = "Usage: omaflow todos list|add TEXT [LIST [DUE]]|done I TEXT|undone I TEXT|edit I TEXT NEW|due I TEXT DATE [HH:MM [REMIND]]|remind I TEXT default|off|MINUTES|snooze I TEXT MINUTES|tomorrow|reminders|move I TEXT LIST|delete I TEXT|clear-done [LIST]|new-list NAME|rename-list LIST NAME|delete-list LIST|restore|forget-deleted|move-folder FOLDER";

fn today() -> Date {
    omaflow_platform::clock::local_now().0
}

fn parse_date(value: &str) -> Result<Date, String> {
    value
        .parse()
        .map_err(|_| format!("Not a date like 2026-10-02: {value}"))
}

fn parse_remind(value: &str) -> Result<todos::Remind, String> {
    match value {
        "default" | "" => Ok(todos::Remind::Default),
        "off" => Ok(todos::Remind::Off),
        minutes => minutes.parse().map(todos::Remind::Before).map_err(|_| {
            format!("Remind default, off, or a number of minutes before, not {minutes}")
        }),
    }
}

fn parse_index(value: &str) -> Result<usize, String> {
    value
        .parse()
        .map_err(|_| format!("Not a to-do number: {value}"))
}
