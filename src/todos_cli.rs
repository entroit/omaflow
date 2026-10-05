//! `omaflow todos …`: reads and edits the to-do list for the panel. Like the
//! journal's, these run without the daemon and print JSON. A task is named by
//! its place in the list and its words, as `omaflow todos list` shows them.
use crate::config::Config;
use omaflow_core::{
    date::Date,
    todos::{self, NewTodo, TodoList},
};
use serde_json::{Value, json};
use std::process::ExitCode;

pub fn run(mut args: impl Iterator<Item = String>) -> ExitCode {
    let result = Config::load().and_then(|config| {
        let todos = TodoList::new(config.todos.folder_path());
        todos.forget_stale_trash();
        let command = args.next().unwrap_or_default();
        dispatch(&todos, &command, &mut args)
    });
    match result {
        Ok(value) => {
            println!("{value}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            println!("{}", json!({ "error": error }));
            eprintln!("omaflow: {error}");
            ExitCode::FAILURE
        }
    }
}

fn dispatch(
    todos: &TodoList,
    command: &str,
    args: &mut impl Iterator<Item = String>,
) -> Result<Value, String> {
    let mut next = |what: &str| args.next().ok_or_else(|| format!("Missing {what}"));
    match command {
        "list" => Ok(json!({
            "path": todos.path(),
            "today": today().to_string(),
            "lists": todos.lists()?,
            "current": todos.current_list(),
            "todos": serde_json::to_value(todos.list()?).map_err(|error| error.to_string())?,
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
                    let (text, due, time) = todos::due(line, today, &now);
                    NewTodo {
                        text,
                        due: due.or(default_due),
                        time,
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
            todos.set_due(index, &text, due, time.as_deref())?;
            Ok(json!({ "ok": true }))
        }
        // To-dos whose time has come, each once; the shell shows them.
        "reminders" => {
            let (today, now) = omaflow_platform::clock::local_now();
            let due = todos.reminders(today, &now)?;
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
        "forget-deleted" => {
            todos.empty_trash();
            Ok(json!({ "ok": true }))
        }
        "" => Err(USAGE.into()),
        other => Err(format!("Unknown todos command: {other}")),
    }
}

const USAGE: &str = "Usage: omaflow todos list|add TEXT [LIST [DUE]]|done I TEXT|undone I TEXT|edit I TEXT NEW|due I TEXT DATE [HH:MM]|reminders|move I TEXT LIST|delete I TEXT|clear-done [LIST]|new-list NAME|rename-list LIST NAME|delete-list LIST|restore|forget-deleted";

fn today() -> Date {
    omaflow_platform::clock::local_now().0
}

fn parse_date(value: &str) -> Result<Date, String> {
    value
        .parse()
        .map_err(|_| format!("Not a date like 2026-10-02: {value}"))
}

fn parse_index(value: &str) -> Result<usize, String> {
    value
        .parse()
        .map_err(|_| format!("Not a to-do number: {value}"))
}
