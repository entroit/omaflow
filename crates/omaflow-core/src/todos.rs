//! To-dos: one Markdown checklist the user owns, `To-dos.md` in a folder of
//! their choosing.
//!
//! Each task is a standard task-list line, `- [ ] Buy milk` or `- [x] Call
//! Mira`, which Obsidian, GitHub and most notes apps already show as a
//! checkbox. A `## Heading` starts a list; tasks above the first one are the
//! Inbox. A due date is written the way Obsidian's Tasks plugin reads it,
//! `📅 2026-10-03`, at the end of the line. A time goes just before it the way
//! the Obsidian Reminder plugin reads one, `⏰ 2026-10-03 15:00 📅 2026-10-03`,
//! and is when OmaFlow reminds you. Every other line in the file (the
//! title, notes, blank lines) is kept exactly as it is. A task is addressed
//! by its place among the tasks and its words, so a file edited in another
//! app since it was read is never changed in the wrong place.
use crate::date::Date;
use crate::fsutil::{Made, copy_all, owned_dir, remove_moved, same_folder, write_owned};
use crate::journal::MoveError;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::ErrorKind,
    path::{Path, PathBuf},
};

/// How long deleted or cleared tasks can be brought back: the Undo bar's ten
/// seconds, then they are gone.
const TRASH_KEEP_MS: u64 = 10 * 1000;
const FILE_NAME: &str = "To-dos.md";
const DUE_MARK: &str = "📅";
const TIME_MARK: &str = "⏰";
/// The to-do's own time, written only when its reminder was set by hand.
const CLOCK_MARK: &str = "🕒";
/// `reminder` for a to-do whose time has no reminder.
pub const REMINDER_OFF: &str = "off";

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Todo {
    /// The task's place among the tasks in the file, from 0.
    pub index: usize,
    /// The words, without the due date.
    pub text: String,
    pub done: bool,
    /// The list's heading; empty for the Inbox.
    pub list: String,
    /// `YYYY-MM-DD`, if it has one.
    pub due: Option<String>,
    /// `HH:MM` on the due day, if it has one.
    pub time: Option<String>,
    /// How a to-do with a time reminds you: `None` follows the default,
    /// `"off"` doesn't, and `"YYYY-MM-DD HH:MM"` is a moment set by hand.
    pub reminder: Option<String>,
}

/// How a to-do's reminder is set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Remind {
    /// Whatever the default says, at the time or earlier.
    Default,
    Off,
    /// This many minutes before the to-do's time.
    Before(u32),
    /// At this moment, `YYYY-MM-DD HH:MM`, as a snooze sets it.
    At(String),
}

/// A task to add: its words and, if it has one, when it is due.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewTodo {
    pub text: String,
    pub due: Option<Date>,
    /// `HH:MM`; only kept with a date.
    pub time: Option<String>,
    pub remind: Remind,
}

/// A time of day as `HH:MM`, from `15:00` or `9:05`. Minutes take two
/// digits, so "the 1:1" is not a time.
pub fn clock_time(value: &str) -> Option<String> {
    let (hours, minutes) = value.trim().split_once(':')?;
    let hours: u8 = hours
        .parse()
        .ok()
        .filter(|_| (1..=2).contains(&hours.len()))?;
    let minutes: u8 = minutes.parse().ok().filter(|_| minutes.len() == 2)?;
    (hours < 24 && minutes < 60).then(|| format!("{hours:02}:{minutes:02}"))
}

/// Taken out of the file, kept so the change can be undone.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Trashed {
    /// (line number, the line exactly as it was), in file order.
    lines: Vec<(usize, String)>,
    /// For a deleted list: the whole file before and after, put back only if
    /// nothing else changed it since.
    #[serde(default)]
    snapshot: Option<(String, String)>,
    deleted_at_ms: u64,
}

pub struct TodoList {
    folder: PathBuf,
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or(0)
}

/// The task on a line, if it is one: `- [ ] text`, `* [x] text`, `+ [X] text`.
fn task(line: &str) -> Option<(bool, &str)> {
    let rest = line.trim_start();
    let rest = rest.strip_prefix(['-', '*', '+'])?.strip_prefix(' ')?;
    let done = match rest.get(..3)? {
        "[ ]" => false,
        "[x]" | "[X]" => true,
        _ => return None,
    };
    Some((done, rest[3..].trim()))
}

/// What follows a task's checkbox: the words, and when it is due.
struct Fields<'a> {
    words: &'a str,
    due: Option<String>,
    time: Option<String>,
    reminder: Option<String>,
}

/// A task's words, date, time and reminder, from what follows the checkbox.
fn read_fields(rest: &str) -> Fields<'_> {
    let (mut words, mut due) = (rest, None);
    if let Some(at) = rest.rfind(DUE_MARK) {
        let date = rest[at + DUE_MARK.len()..].trim();
        let date = date.get(..10).unwrap_or(date);
        if date.parse::<Date>().is_ok() {
            (words, due) = (rest[..at].trim_end(), Some(date.to_string()));
        }
    }
    // `⏰ 2026-10-03 15:00`, when to notify, just before the date.
    let mut alarm = None;
    if let Some(at) = words.rfind(TIME_MARK) {
        let mut parts = words[at + TIME_MARK.len()..].split_whitespace();
        if let (Some(date), Some(time), None) = (parts.next(), parts.next(), parts.next())
            && date.parse::<Date>().is_ok()
            && let Some(time) = clock_time(time)
        {
            alarm = Some((date.to_string(), time));
            words = words[..at].trim_end();
        }
    }
    // `🕒 15:00`, the to-do's own time, when its reminder was set by hand.
    let mut clock = None;
    if let Some(at) = words.rfind(CLOCK_MARK)
        && let Some(time) = clock_time(words[at + CLOCK_MARK.len()..].trim())
    {
        clock = Some(time);
        words = words[..at].trim_end();
    }
    let (time, reminder) = match (clock, alarm) {
        (Some(clock), Some((date, time))) => (Some(clock), Some(format!("{date} {time}"))),
        (Some(clock), None) => (Some(clock), Some(REMINDER_OFF.to_string())),
        (None, Some((date, time))) => {
            due = due.or(Some(date));
            (Some(time), None)
        }
        (None, None) => (None, None),
    };
    Fields {
        words,
        due,
        time,
        reminder,
    }
}

/// The list a `## Heading` line starts, if it is one.
fn heading(line: &str) -> Option<&str> {
    let name = line.strip_prefix("## ")?.trim();
    (!name.is_empty()).then_some(name)
}

/// A task's words as one line: no line breaks, no checkbox of its own.
fn clean(text: &str) -> String {
    let words = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let words = words.trim_start_matches(['-', '*', '•']).trim();
    let words = words.strip_prefix("[ ]").unwrap_or(words).trim();
    let mut chars = words.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

fn task_line(
    done: bool,
    text: &str,
    due: Option<&str>,
    time: Option<&str>,
    reminder: Option<&str>,
) -> String {
    let mut line = format!("- [{}] {text}", if done { "x" } else { " " });
    if let Some(due) = due {
        match (time, reminder) {
            (None, _) => {}
            (Some(time), None) => line.push_str(&format!(" {TIME_MARK} {due} {time}")),
            (Some(time), Some(REMINDER_OFF)) => line.push_str(&format!(" {CLOCK_MARK} {time}")),
            (Some(time), Some(moment)) => {
                line.push_str(&format!(" {CLOCK_MARK} {time} {TIME_MARK} {moment}"))
            }
        }
        line.push_str(&format!(" {DUE_MARK} {due}"));
    }
    line
}

/// A moment as minutes since the epoch day, back to `YYYY-MM-DD HH:MM`.
fn moment_text(minutes: i64) -> String {
    let day = Date::from_days_since_epoch(minutes.div_euclid(24 * 60));
    let minute = minutes.rem_euclid(24 * 60);
    format!("{day} {:02}:{:02}", minute / 60, minute % 60)
}

/// `YYYY-MM-DD HH:MM` as minutes since the epoch day.
fn moment_minutes(moment: &str) -> Option<i64> {
    let (day, time) = moment.split_once(' ')?;
    minute_of(day.parse().ok()?, time)
}

/// What a reminder choice is stored as, for a to-do due `due` at `time`.
fn stored_reminder(remind: &Remind, due: Option<&str>, time: Option<&str>) -> Option<String> {
    let at = due
        .and_then(|due| due.parse::<Date>().ok())
        .zip(time)
        .and_then(|(day, time)| minute_of(day, time))?;
    match remind {
        Remind::Default => None,
        Remind::Off => Some(REMINDER_OFF.to_string()),
        Remind::Before(minutes) => Some(moment_text(at - i64::from(*minutes))),
        Remind::At(moment) => moment_minutes(moment).map(moment_text),
    }
}

/// A list name as it can be written as a heading.
fn list_name(name: &str) -> Result<String, String> {
    let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
    if name.is_empty() {
        return Err("A list needs a name".into());
    }
    if name.eq_ignore_ascii_case("inbox") {
        return Err("Inbox is already a list".into());
    }
    if name.chars().count() > 40 {
        return Err("Keep the list name under 40 characters".into());
    }
    Ok(name)
}

/// Every task with its line and list, in file order.
fn tasks_in(lines: &[String]) -> Vec<(usize, Todo)> {
    let mut list = String::new();
    let mut found = Vec::new();
    for (line, content) in lines.iter().enumerate() {
        if let Some(name) = heading(content) {
            list = name.to_string();
        } else if let Some((done, rest)) = task(content) {
            let fields = read_fields(rest);
            let index = found.len();
            found.push((
                line,
                Todo {
                    index,
                    text: fields.words.to_string(),
                    done,
                    list: list.clone(),
                    due: fields.due,
                    time: fields.time,
                    reminder: fields.reminder,
                },
            ));
        }
    }
    found
}

/// Where tasks for a list go: after its last task, or under its heading. A
/// list that has no heading yet gets one at the end of the file.
fn insertion_point(lines: &mut Vec<String>, list: &str) -> usize {
    if lines.is_empty() {
        lines.push("# To-dos".into());
        lines.push(String::new());
    }
    let first_heading = lines.iter().position(|line| heading(line).is_some());
    let (start, end) = if list.is_empty() {
        (0, first_heading.unwrap_or(lines.len()))
    } else {
        match lines.iter().position(|line| heading(line) == Some(list)) {
            Some(at) => {
                let end = lines[at + 1..]
                    .iter()
                    .position(|line| heading(line).is_some())
                    .map_or(lines.len(), |offset| at + 1 + offset);
                (at + 1, end)
            }
            None => {
                if lines.last().is_some_and(|line| !line.trim().is_empty()) {
                    lines.push(String::new());
                }
                lines.push(format!("## {list}"));
                lines.push(String::new());
                return lines.len();
            }
        }
    };
    if let Some(last) = lines[start..end]
        .iter()
        .rposition(|line| task(line).is_some())
    {
        return start + last + 1;
    }
    // An empty section: after the title or heading and one blank line, and
    // keep a blank line before the next heading.
    let mut at = start;
    if list.is_empty() {
        at = lines[..end]
            .iter()
            .rposition(|line| !line.trim().is_empty())
            .map_or(0, |line| line + 1);
    }
    if at < lines.len() && lines[at].trim().is_empty() {
        at += 1;
    } else {
        lines.insert(at, String::new());
        at += 1;
    }
    if at < lines.len() && heading(&lines[at]).is_some() {
        lines.insert(at, String::new());
    }
    at
}

/// Why nothing was done to `count` to-dos: someone changed the file.
fn gone(count: usize) -> String {
    if count == 1 {
        "That to-do is no longer in the list".into()
    } else {
        "Those to-dos are no longer in the list".into()
    }
}

impl TodoList {
    pub fn new(folder: impl Into<PathBuf>) -> Self {
        Self {
            folder: folder.into(),
        }
    }

    pub fn path(&self) -> PathBuf {
        self.folder.join(FILE_NAME)
    }

    pub fn folder(&self) -> &Path {
        &self.folder
    }

    fn lines(&self) -> Result<Vec<String>, String> {
        match fs::read_to_string(self.path()) {
            Ok(text) => Ok(text.lines().map(str::to_string).collect()),
            Err(error) if error.kind() == ErrorKind::NotFound => Ok(Vec::new()),
            Err(error) => Err(format!("could not read {}: {error}", self.path().display())),
        }
    }

    fn write(&self, lines: &[String]) -> Result<(), String> {
        let mut text = lines.join("\n");
        text.push('\n');
        write_owned(&self.path(), text.as_bytes())
    }

    fn lock(&self) -> Result<fs::File, String> {
        fs::create_dir_all(&self.folder).map_err(|error| match error.kind() {
            // The daemon is sandboxed; a folder it was never given reads as
            // read-only. Choosing it again in the to-do settings opens it.
            ErrorKind::ReadOnlyFilesystem | ErrorKind::PermissionDenied => format!(
                "OmaFlow is not allowed to write {}. Choose it again under ⋯, Reminders and folder.",
                self.folder.display()
            ),
            _ => format!("could not create {}: {error}", self.folder.display()),
        })?;
        let directory = self.folder.join(".omaflow");
        owned_dir(&directory)?;
        let path = directory.join("todos.lock");
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

    pub fn list(&self) -> Result<Vec<Todo>, String> {
        Ok(tasks_in(&self.lines()?)
            .into_iter()
            .map(|(_, todo)| todo)
            .collect())
    }

    /// The lists, in the order of their headings. The Inbox is not one of them.
    pub fn lists(&self) -> Result<Vec<String>, String> {
        let mut names: Vec<String> = Vec::new();
        for line in self.lines()? {
            if let Some(name) = heading(&line)
                && !names.iter().any(|known| known == name)
            {
                names.push(name.to_string());
            }
        }
        Ok(names)
    }

    /// The line number of the task at `index` with these words, or failing
    /// that the first task with these words (the file may have changed).
    fn find(lines: &[String], index: usize, text: &str) -> Option<usize> {
        let tasks = tasks_in(lines);
        if let Some((line, todo)) = tasks.get(index)
            && todo.text == text
        {
            return Some(*line);
        }
        tasks
            .iter()
            .find(|(_, todo)| todo.text == text)
            .map(|(line, _)| *line)
    }

    fn existing(lines: &[String], index: usize, text: &str) -> Result<usize, String> {
        Self::find(lines, index, text).ok_or_else(|| "That to-do is no longer in the list".into())
    }

    /// Adds open tasks at the end of a list, `""` for the Inbox, making the
    /// list if it does not exist yet. Returns them as now listed.
    pub fn add(&self, items: &[NewTodo], list: &str) -> Result<Vec<Todo>, String> {
        let list = if list.is_empty() {
            String::new()
        } else {
            list_name(list)?
        };
        type Item = (String, Option<String>, Option<String>, Option<String>);
        let items: Vec<Item> = items
            .iter()
            .map(|item| {
                let due = item.due.map(|due| due.to_string());
                let time = item
                    .time
                    .as_deref()
                    .and_then(clock_time)
                    .filter(|_| due.is_some());
                let reminder = stored_reminder(&item.remind, due.as_deref(), time.as_deref());
                (clean(&item.text), due, time, reminder)
            })
            .filter(|(text, ..)| !text.is_empty())
            .collect();
        if items.is_empty() {
            return Err("There were no to-dos to add".into());
        }
        let _lock = self.lock()?;
        let mut lines = self.lines()?;
        let at = insertion_point(&mut lines, &list);
        let before = lines[..at]
            .iter()
            .filter(|line| task(line).is_some())
            .count();
        for (offset, (text, due, time, reminder)) in items.iter().enumerate() {
            lines.insert(
                at + offset,
                task_line(
                    false,
                    text,
                    due.as_deref(),
                    time.as_deref(),
                    reminder.as_deref(),
                ),
            );
        }
        self.write(&lines)?;
        Ok(items
            .into_iter()
            .enumerate()
            .map(|(offset, (text, due, time, reminder))| Todo {
                index: before + offset,
                text,
                done: false,
                list: list.clone(),
                due,
                time,
                reminder,
            })
            .collect())
    }

    /// Rewrites one task's line, keeping its indentation and bullet.
    fn rewrite(
        &self,
        index: usize,
        text: &str,
        change: impl FnOnce(bool, &Fields) -> Result<String, String>,
    ) -> Result<(), String> {
        let _lock = self.lock()?;
        let mut lines = self.lines()?;
        let line = Self::existing(&lines, index, text)?;
        let content = lines[line].clone();
        let (done, rest) = task(&content).ok_or("That to-do is no longer in the list")?;
        let fields = read_fields(rest);
        let prefix = &content[..content.find('[').unwrap_or(0)];
        let next = change(done, &fields)?;
        lines[line] = format!("{prefix}{}", next.trim_start_matches("- "));
        self.write(&lines)
    }

    pub fn set_done(&self, index: usize, text: &str, done: bool) -> Result<(), String> {
        self.rewrite(index, text, |_, line| {
            Ok(task_line(
                done,
                line.words,
                line.due.as_deref(),
                line.time.as_deref(),
                line.reminder.as_deref(),
            ))
        })
    }

    pub fn edit(&self, index: usize, text: &str, new_text: &str) -> Result<(), String> {
        let new_text = clean(new_text);
        if new_text.is_empty() {
            return Err("A to-do needs words. Use Delete to remove it.".into());
        }
        self.rewrite(index, text, |done, line| {
            Ok(task_line(
                done,
                &new_text,
                line.due.as_deref(),
                line.time.as_deref(),
                line.reminder.as_deref(),
            ))
        })
    }

    /// Sets or clears when a task is due, and at what time; no date clears
    /// the time too. A reminder set by hand keeps its distance from the
    /// time, so "30 minutes before" stays 30 minutes before; `remind`
    /// replaces it instead when given.
    pub fn set_due(
        &self,
        index: usize,
        text: &str,
        due: Option<Date>,
        time: Option<&str>,
        remind: Option<Remind>,
    ) -> Result<(), String> {
        let due = due.map(|due| due.to_string());
        let time = match time {
            Some(value) => Some(clock_time(value).ok_or("Write the time as HH:MM, such as 15:00")?),
            None => None,
        }
        .filter(|_| due.is_some());
        self.rewrite(index, text, |done, line| {
            let remind = remind.unwrap_or_else(|| match line.reminder.as_deref() {
                None => Remind::Default,
                Some(REMINDER_OFF) => Remind::Off,
                Some(moment) => {
                    let was = line
                        .due
                        .as_deref()
                        .and_then(|due| due.parse::<Date>().ok())
                        .zip(line.time.as_deref())
                        .and_then(|(day, time)| minute_of(day, time));
                    match (was, moment_minutes(moment)) {
                        (Some(was), Some(at)) if at <= was => Remind::Before((was - at) as u32),
                        _ => Remind::Default,
                    }
                }
            });
            let reminder = stored_reminder(&remind, due.as_deref(), time.as_deref());
            Ok(task_line(
                done,
                line.words,
                due.as_deref(),
                time.as_deref(),
                reminder.as_deref(),
            ))
        })
    }

    /// Changes only when a to-do reminds you; its date and time stay.
    pub fn set_reminder(&self, index: usize, text: &str, remind: Remind) -> Result<(), String> {
        self.rewrite(index, text, |done, line| {
            if line.time.is_none() {
                return Err("Give the to-do a time first; a reminder comes at a time".into());
            }
            let reminder = stored_reminder(&remind, line.due.as_deref(), line.time.as_deref());
            Ok(task_line(
                done,
                line.words,
                line.due.as_deref(),
                line.time.as_deref(),
                reminder.as_deref(),
            ))
        })
    }

    /// Moves tasks to the end of another list. Returns them as now listed.
    pub fn move_to(&self, tasks: &[(usize, String)], list: &str) -> Result<Vec<Todo>, String> {
        let list = if list.is_empty() {
            String::new()
        } else {
            list_name(list)?
        };
        let _lock = self.lock()?;
        let mut lines = self.lines()?;
        let mut taken: Vec<usize> = tasks
            .iter()
            .filter_map(|(index, text)| Self::find(&lines, *index, text))
            .collect();
        taken.sort_unstable();
        taken.dedup();
        if taken.is_empty() {
            return Err(gone(tasks.len()));
        }
        let moved: Vec<String> = taken
            .iter()
            .map(|line| lines[*line].trim().to_string())
            .collect();
        for line in taken.iter().rev() {
            lines.remove(*line);
        }
        let at = insertion_point(&mut lines, &list);
        let before = lines[..at]
            .iter()
            .filter(|line| task(line).is_some())
            .count();
        for (offset, content) in moved.iter().enumerate() {
            lines.insert(at + offset, content.clone());
        }
        self.write(&lines)?;
        let listed = tasks_in(&lines);
        Ok((0..moved.len())
            .filter_map(|offset| listed.get(before + offset).map(|(_, todo)| todo.clone()))
            .collect())
    }

    /// Makes an empty list at the end of the file.
    pub fn create_list(&self, name: &str) -> Result<String, String> {
        let name = list_name(name)?;
        let _lock = self.lock()?;
        let mut lines = self.lines()?;
        if lines
            .iter()
            .any(|line| heading(line).is_some_and(|known| known.eq_ignore_ascii_case(&name)))
        {
            return Err(format!("There is already a list called {name}"));
        }
        if lines.is_empty() {
            lines.push("# To-dos".into());
        }
        if lines.last().is_some_and(|line| !line.trim().is_empty()) {
            lines.push(String::new());
        }
        lines.push(format!("## {name}"));
        self.write(&lines)?;
        Ok(name)
    }

    pub fn rename_list(&self, name: &str, new_name: &str) -> Result<String, String> {
        let new_name = list_name(new_name)?;
        let _lock = self.lock()?;
        let mut lines = self.lines()?;
        if new_name != name
            && lines.iter().any(|line| {
                heading(line).is_some_and(|known| known.eq_ignore_ascii_case(&new_name))
            })
        {
            return Err(format!("There is already a list called {new_name}"));
        }
        let at = lines
            .iter()
            .position(|line| heading(line) == Some(name))
            .ok_or("That list is no longer in the file")?;
        lines[at] = format!("## {new_name}");
        self.write(&lines)?;
        if fs::read_to_string(self.current_path()).is_ok_and(|current| current.trim() == name) {
            self.set_current_list(&new_name)?;
        }
        Ok(new_name)
    }

    /// Deletes a list; its tasks move to the Inbox. Undo puts it all back.
    pub fn delete_list(&self, name: &str) -> Result<usize, String> {
        let _lock = self.lock()?;
        let mut lines = self.lines()?;
        let before = lines.clone();
        let at = lines
            .iter()
            .position(|line| heading(line) == Some(name))
            .ok_or("That list is no longer in the file")?;
        let end = lines[at + 1..]
            .iter()
            .position(|line| heading(line).is_some())
            .map_or(lines.len(), |offset| at + 1 + offset);
        let section: Vec<String> = lines.drain(at..end).collect();
        let moved: Vec<String> = section[1..]
            .iter()
            .filter(|line| task(line).is_some())
            .map(|line| line.trim().to_string())
            .collect();
        // Notes under the heading stay in the file, at the end of the Inbox.
        let notes: Vec<String> = section[1..]
            .iter()
            .filter(|line| task(line).is_none() && !line.trim().is_empty())
            .cloned()
            .collect();
        while lines.last().is_some_and(|line| line.trim().is_empty()) {
            lines.pop();
        }
        let count = moved.len();
        if count + notes.len() > 0 {
            let at = insertion_point(&mut lines, "");
            for (offset, content) in moved.into_iter().chain(notes).enumerate() {
                lines.insert(at + offset, content);
            }
        }
        self.empty_trash();
        let joined = |lines: &[String]| lines.join("\n") + "\n";
        self.save_trash(Trashed {
            lines: Vec::new(),
            snapshot: Some((joined(&before), joined(&lines))),
            deleted_at_ms: now_ms(),
        })?;
        self.write(&lines)?;
        Ok(count)
    }

    fn save_trash(&self, trash: Trashed) -> Result<(), String> {
        let directory = self.folder.join(".omaflow");
        owned_dir(&directory)?;
        let record = serde_json::to_vec(&trash).map_err(|error| error.to_string())?;
        write_owned(&directory.join("todo-trash.json"), &record)
    }

    /// Takes tasks out of the file. With `undoable`, they wait in the trash
    /// for ten seconds; without (taking back a capture), they are just gone.
    pub fn remove(&self, tasks: &[(usize, String)], undoable: bool) -> Result<usize, String> {
        let _lock = self.lock()?;
        let mut lines = self.lines()?;
        let mut taken: Vec<usize> = tasks
            .iter()
            .filter_map(|(index, text)| Self::find(&lines, *index, text))
            .collect();
        taken.sort_unstable();
        taken.dedup();
        if taken.is_empty() {
            return Err(gone(tasks.len()));
        }
        let removed: Vec<(usize, String)> = taken
            .iter()
            .map(|line| (*line, lines[*line].clone()))
            .collect();
        for line in taken.iter().rev() {
            lines.remove(*line);
        }
        if undoable {
            self.empty_trash();
            self.save_trash(Trashed {
                lines: removed.clone(),
                snapshot: None,
                deleted_at_ms: now_ms(),
            })?;
        }
        self.write(&lines)?;
        Ok(removed.len())
    }

    /// Every finished task, in one list or in all of them, out of the file
    /// and into the trash for Undo.
    pub fn clear_done(&self, list: Option<&str>) -> Result<usize, String> {
        let done: Vec<(usize, String)> = self
            .list()?
            .into_iter()
            .filter(|todo| todo.done && list.is_none_or(|list| todo.list == list))
            .map(|todo| (todo.index, todo.text))
            .collect();
        if done.is_empty() {
            return Ok(0);
        }
        self.remove(&done, true)
    }

    /// Puts back the last deleted or cleared tasks, or the last deleted list.
    pub fn restore(&self) -> Result<usize, String> {
        let _lock = self.lock()?;
        self.forget_stale_trash();
        let trash: Trashed = fs::read(self.trash_path())
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .ok_or("Those to-dos can no longer be brought back")?;
        if let Some((before, after)) = &trash.snapshot {
            let now = fs::read_to_string(self.path()).unwrap_or_default();
            if &now != after {
                self.empty_trash();
                return Err(
                    "The list changed since it was deleted, so it can't be brought back".into(),
                );
            }
            write_owned(&self.path(), before.as_bytes())?;
            self.empty_trash();
            return Ok(1);
        }
        let mut lines = self.lines()?;
        for (line, content) in &trash.lines {
            lines.insert((*line).min(lines.len()), content.clone());
        }
        self.write(&lines)?;
        self.empty_trash();
        Ok(trash.lines.len())
    }

    fn trash_path(&self) -> PathBuf {
        self.folder.join(".omaflow").join("todo-trash.json")
    }

    /// Deletes the last deleted tasks for good.
    pub fn empty_trash(&self) {
        let _ = fs::remove_file(self.trash_path());
    }

    /// Deleted tasks are only kept for Undo; after that they are gone.
    pub fn forget_stale_trash(&self) {
        let deleted_at = fs::read(self.trash_path())
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Trashed>(&bytes).ok())
            .map(|trash| trash.deleted_at_ms);
        match deleted_at {
            Some(at) if now_ms().saturating_sub(at) < TRASH_KEEP_MS => {}
            _ => self.empty_trash(),
        }
    }

    fn current_path(&self) -> PathBuf {
        self.folder.join(".omaflow").join("current-list")
    }

    /// Where a new to-do goes when nothing says otherwise: the list last
    /// added to or picked, if it still exists, or the Inbox.
    pub fn current_list(&self) -> String {
        let name = fs::read_to_string(self.current_path()).unwrap_or_default();
        let name = name.trim();
        if !name.is_empty()
            && self
                .lists()
                .is_ok_and(|lists| lists.iter().any(|list| list == name))
        {
            name.to_string()
        } else {
            String::new()
        }
    }

    pub fn set_current_list(&self, name: &str) -> Result<(), String> {
        let directory = self.folder.join(".omaflow");
        fs::create_dir_all(&self.folder).map_err(|error| error.to_string())?;
        owned_dir(&directory)?;
        write_owned(&self.current_path(), name.trim().as_bytes())
    }

    fn reminded_path(&self) -> PathBuf {
        self.folder.join(".omaflow").join("reminded.json")
    }

    /// Open to-dos whose reminder is due, each handed out once: at the
    /// to-do's time, or `before` minutes earlier. One missed while the
    /// computer was off still comes, if it is less than a day late. `now` is
    /// the local date and `HH:MM`.
    pub fn reminders(&self, today: Date, now: &str, before: u32) -> Result<Vec<Todo>, String> {
        let Some(now) = minute_of(today, now) else {
            return Err(format!("Not a time: {now}"));
        };
        let todos = self.list()?;
        let waiting: Vec<(&Todo, String)> = todos
            .iter()
            .filter(|todo| !todo.done)
            .filter_map(|todo| {
                let at = reminder_moment(todo, before)?;
                (at <= now && now - at < 24 * 60).then(|| (todo, reminder_key(todo, at)))
            })
            .collect();
        let mut reminded = self.reminded_keys();
        let due: Vec<Todo> = waiting
            .iter()
            .filter(|(_, key)| !reminded.contains(key))
            .map(|(todo, _)| (*todo).clone())
            .collect();
        // Keep only what is still waiting, so the file never grows.
        let still: Vec<String> = waiting.iter().map(|(_, key)| key.clone()).collect();
        reminded.retain(|entry| still.contains(entry));
        reminded.extend(
            waiting
                .iter()
                .filter(|(todo, _)| due.iter().any(|d| d.index == todo.index))
                .map(|(_, key)| key.clone()),
        );
        reminded.dedup();
        owned_dir(&self.folder.join(".omaflow"))?;
        let bytes = serde_json::to_vec(&reminded).map_err(|error| error.to_string())?;
        write_owned(&self.reminded_path(), &bytes)?;
        Ok(due)
    }

    fn reminded_keys(&self) -> Vec<String> {
        fs::read(self.reminded_path())
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    /// The open to-dos whose reminder has gone off and that are still
    /// waiting to be done: Today offers to snooze them.
    pub fn reminded(&self, before: u32) -> Result<Vec<usize>, String> {
        let keys = self.reminded_keys();
        Ok(self
            .list()?
            .iter()
            .filter(|todo| !todo.done)
            .filter(|todo| {
                reminder_moment(todo, before)
                    .is_some_and(|at| keys.contains(&reminder_key(todo, at)))
            })
            .map(|todo| todo.index)
            .collect())
    }

    /// Moves `To-dos.md` and OmaFlow's own files for it into `destination`,
    /// the way the journal moves: nothing is overwritten, every copy is read
    /// back before the originals go, and a failure before that takes the
    /// copies back. Returns the originals that could not be removed, by
    /// their names here. Anything else in the folder stays.
    pub fn move_folder(&self, destination: &Path) -> Result<Vec<String>, MoveError> {
        let failed = |error: String| MoveError::Failed(error);
        if same_folder(&self.folder, destination) || !self.folder.is_dir() {
            return Ok(Vec::new());
        }
        let target = TodoList::new(destination);
        if target.path().symlink_metadata().is_ok() {
            return Err(MoveError::Clash(vec![FILE_NAME.into()]));
        }
        let lock = self.lock().map_err(failed)?;
        let own = |list: &TodoList| {
            [
                list.path(),
                list.trash_path(),
                list.current_path(),
                list.reminded_path(),
            ]
        };
        // A file of OmaFlow's own already there belongs to that folder and
        // is kept; only the list itself counts as a clash.
        let files: Vec<(PathBuf, PathBuf)> = own(self)
            .into_iter()
            .zip(own(&target))
            .filter(|(from, to)| from.is_file() && to.symlink_metadata().is_err())
            .collect();
        let mut made = Made::default();
        let pairs = files
            .iter()
            .map(|(from, to)| (from.as_path(), to.as_path()));
        if let Err(error) = copy_all(pairs, destination, &mut made) {
            made.undo();
            return Err(failed(error));
        }
        let left_behind = remove_moved(files.iter().map(|(from, _)| from.as_path()), &self.folder);
        // The lock is ours; the folder it is in may hold the journal's too.
        drop(lock);
        let own = self.folder.join(".omaflow");
        let _ = fs::remove_file(own.join("todos.lock"));
        let _ = fs::remove_dir(&own);
        Ok(left_behind)
    }
}

/// `minutes` after a `YYYY-MM-DD HH:MM` moment, in the same form.
pub fn later(moment: &str, minutes: i64) -> Option<String> {
    moment_minutes(moment).map(|at| moment_text(at + minutes))
}

/// When a to-do reminds you, as minutes since the epoch day: at its time,
/// `before` minutes earlier when it follows the default, at the moment set
/// by hand, or never.
pub fn reminder_moment(todo: &Todo, before: u32) -> Option<i64> {
    let at = todo
        .due
        .as_deref()
        .and_then(|due| due.parse::<Date>().ok())
        .zip(todo.time.as_deref())
        .and_then(|(day, time)| minute_of(day, time))?;
    match todo.reminder.as_deref() {
        None => Some(at - i64::from(before)),
        Some(REMINDER_OFF) => None,
        Some(moment) => moment_minutes(moment),
    }
}

/// Which reminder of which to-do has gone off; a snooze is a new one.
fn reminder_key(todo: &Todo, at: i64) -> String {
    format!("{} {}", moment_text(at), todo.text)
}

/// A local date and `HH:MM` as minutes since the epoch day, for comparing
/// moments across midnight.
fn minute_of(day: Date, time: &str) -> Option<i64> {
    let time = clock_time(time)?;
    let hours: i64 = time[..2].parse().ok()?;
    let minutes: i64 = time[3..].parse().ok()?;
    Some(day.days_since_epoch() * 24 * 60 + hours * 60 + minutes)
}

/// "Remind me at 3:30" for a to-do at 16:00 means 15:30: a morning time
/// that is still before the to-do twelve hours later is taken in the
/// afternoon.
fn afternoon_before(at: &str, time: Option<&str>) -> String {
    let later = at[..2]
        .parse::<u8>()
        .ok()
        .filter(|hours| *hours < 12)
        .map(|hours| format!("{:02}{}", hours + 12, &at[2..]));
    match (later, time) {
        (Some(later), Some(time)) if later.as_str() <= time => later,
        _ => at.to_string(),
    }
}

/// A deadline said at the end of a to-do, such as "before Friday", "by the
/// 9th" or "Friday at 3pm": the words without it, the date and the time
/// (`HH:MM`). Only the end is read, where people put a deadline, so "Review
/// what Friday's call decided" keeps its words and gets no date. A time with
/// no day is today, or tomorrow once it has passed; `now` is `HH:MM`.
pub fn due(text: &str, today: Date, now: &str) -> Deadline {
    let (text, said) = reminder_at_end(text);
    let text = text.as_str();
    let (rest, time) = time_at_end(text);
    let (rest, date) = date_at_end(&rest, today);
    // "at 3pm on Friday": the time before the day.
    let (rest, time) = match time {
        Some(time) => (rest, Some(time)),
        None if date.is_some() => time_at_end(&rest),
        None => (rest, None),
    };
    let date = match (date, &time) {
        (None, Some(time)) => Some(if time.as_str() > now {
            today
        } else {
            Date::from_days_since_epoch(today.days_since_epoch() + 1)
        }),
        (date, _) => date,
    };
    // The whole to-do was a deadline: keep the words.
    let rest = if rest.trim().is_empty() {
        text.trim().to_string()
    } else {
        rest
    };
    let remind = match said {
        Some(Said::Off) => Remind::Off,
        Some(Said::Before(minutes)) => Remind::Before(minutes),
        Some(Said::At(at)) => date.map_or(Remind::Default, |day| {
            Remind::At(format!("{day} {}", afternoon_before(&at, time.as_deref())))
        }),
        None => Remind::Default,
    };
    Deadline {
        text: rest,
        date,
        time,
        remind,
    }
}

/// What a to-do said about when it is due and when to be reminded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Deadline {
    /// The words without the deadline.
    pub text: String,
    pub date: Option<Date>,
    /// `HH:MM`.
    pub time: Option<String>,
    pub remind: Remind,
}

enum Said {
    Off,
    Before(u32),
    /// `HH:MM` on the to-do's day.
    At(String),
}

/// A reminder said at the very end: "remind me 30 minutes before", "half an
/// hour early", "an hour before", "remind me at 2:45", "no reminder".
fn reminder_at_end(text: &str) -> (String, Option<Said>) {
    // Some models put the reminder in brackets: "(remind me at 3:30)".
    let trimmed = text
        .trim()
        .trim_end_matches(['.', '!', ',', ')'])
        .trim_end();
    let words: Vec<&str> = trimmed.split_whitespace().collect();
    let lower: Vec<String> = words
        .iter()
        .map(|word| word.trim_matches([',', '.', '(', ')']).to_lowercase())
        .collect();
    let n = lower.len();
    let last = |k: usize| {
        lower
            .get(n.wrapping_sub(k))
            .map(String::as_str)
            .unwrap_or("")
    };
    let ends = |phrase: &[&str]| {
        phrase.len() <= n
            && phrase
                .iter()
                .rev()
                .enumerate()
                .all(|(k, word)| last(k + 1) == *word)
    };
    let mut found: Option<(usize, Said)> = None;
    for phrase in [
        &["no", "reminder"][..],
        &["without", "a", "reminder"],
        &["without", "reminder"],
        &["don't", "remind", "me"],
        &["do", "not", "remind", "me"],
    ] {
        if ends(phrase) {
            found = Some((phrase.len(), Said::Off));
        }
    }
    // "<amount> <unit> before|early|earlier|ahead|in advance"
    if found.is_none() {
        let tail = if ends(&["in", "advance"]) {
            2
        } else if matches!(last(1), "before" | "early" | "earlier" | "ahead") {
            1
        } else {
            0
        };
        if tail > 0 {
            let unit = last(tail + 1);
            let per = match unit.trim_end_matches('s') {
                "minute" | "min" => Some(1),
                "hour" | "h" | "hr" => Some(60),
                _ => None,
            };
            if let Some(per) = per {
                let amount = last(tail + 2);
                let (minutes, taken) = match amount {
                    "an" | "a" if last(tail + 3) == "half" => (Some(per / 2), 3),
                    "an" | "a" if last(tail + 3) == "of" && last(tail + 4) == "quarter" => {
                        (Some(per / 4), if last(tail + 5) == "a" { 5 } else { 4 })
                    }
                    "an" | "a" | "one" => (Some(per), 2),
                    word => (spoken_number(word).map(|count| count * per), 2),
                };
                if let Some(minutes) = minutes.filter(|minutes| (1..=24 * 60).contains(minutes)) {
                    let mut taken = tail + taken;
                    if last(taken + 1) == "me" && last(taken + 2) == "remind" {
                        taken += 2;
                    } else if last(taken + 1) == "remind" {
                        taken += 1;
                    }
                    found = Some((taken, Said::Before(minutes)));
                }
            }
        }
    }
    // "remind me at 2:45" / "remind me at 2:45 pm"
    if found.is_none()
        && let Some(at) = (0..n.saturating_sub(2)).rev().find(|&i| {
            lower[i] == "remind"
                && lower.get(i + 1).map(String::as_str) == Some("me")
                && lower.get(i + 2).map(String::as_str) == Some("at")
        })
    {
        let (left, time) = time_at_end(&words[at + 2..].join(" "));
        if let Some(time) = time.filter(|_| left.trim().is_empty()) {
            found = Some((n - at, Said::At(time)));
        }
    }
    let Some((mut taken, said)) = found else {
        return (text.trim().to_string(), None);
    };
    if matches!(last(taken + 1), "and" | "but") {
        taken += 1;
    }
    let rest = words[..n.saturating_sub(taken)].join(" ");
    (
        rest.trim_end_matches([',', ' ', '(']).to_string(),
        Some(said),
    )
}

/// "5", "five", "fifteen", "forty-five": a count of minutes or hours.
fn spoken_number(word: &str) -> Option<u32> {
    if let Ok(number) = word.parse() {
        return Some(number);
    }
    let tens = |word: &str| match word {
        "twenty" => Some(20),
        "thirty" => Some(30),
        "forty" => Some(40),
        "fifty" => Some(50),
        _ => None,
    };
    let ones = |word: &str| {
        [
            "one",
            "two",
            "three",
            "four",
            "five",
            "six",
            "seven",
            "eight",
            "nine",
            "ten",
            "eleven",
            "twelve",
            "thirteen",
            "fourteen",
            "fifteen",
            "sixteen",
            "seventeen",
            "eighteen",
            "nineteen",
        ]
        .iter()
        .position(|name| *name == word)
        .map(|at| at as u32 + 1)
    };
    if let Some((ten, one)) = word.split_once('-') {
        return Some(tens(ten)? + ones(one).filter(|one| *one < 10)?);
    }
    ones(word)
        .or_else(|| tens(word))
        .or((word == "sixty").then_some(60))
}

/// A time of day said at the end: "3pm", "3:30 p.m.", "at 15:00", "at noon".
fn time_at_end(text: &str) -> (String, Option<String>) {
    let trimmed = text.trim().trim_end_matches(['.', '!', ',']).trim_end();
    let words: Vec<&str> = trimmed.split_whitespace().collect();
    let lower: Vec<String> = words
        .iter()
        .map(|word| word.trim_matches(',').replace('.', "").to_lowercase())
        .collect();
    let n = lower.len();
    let last = |k: usize| {
        lower
            .get(n.wrapping_sub(k))
            .map(String::as_str)
            .unwrap_or("")
    };
    let hour_minute = |value: &str| -> Option<(u8, u8)> {
        let (hours, minutes) = value.split_once(':').unwrap_or((value, "00"));
        // "six pm" as well as "6pm", when a model leaves the number spoken.
        let hours: u8 = hours
            .parse()
            .ok()
            .or_else(|| spoken_number(hours).and_then(|hours| u8::try_from(hours).ok()))?;
        let minutes: u8 = minutes.parse().ok().filter(|_| minutes.len() == 2)?;
        (minutes < 60).then_some((hours, minutes))
    };
    let twelve = |value: &str, half: &str| -> Option<String> {
        let (hours, minutes) = hour_minute(value)?;
        if !(1..=12).contains(&hours) {
            return None;
        }
        let hours = match half {
            "am" => hours % 12,
            _ => hours % 12 + 12,
        };
        Some(format!("{hours:02}:{minutes:02}"))
    };
    let mut found: Option<(usize, String)> = None;
    let word = last(1);
    if matches!(word, "noon" | "midday") {
        found = Some((1, "12:00".into()));
    } else if let Some(half) = ["am", "pm"].into_iter().find(|half| word.ends_with(half)) {
        let number = &word[..word.len() - 2];
        found = if number.is_empty() {
            twelve(last(2), half).map(|time| (2, time))
        } else {
            twelve(number, half).map(|time| (1, time))
        };
    } else if word.contains(':') {
        found = clock_time(word).map(|time| (1, time));
    }
    let Some((mut taken, time)) = found else {
        return (text.trim().to_string(), None);
    };
    if matches!(last(taken + 1), "at" | "by" | "around" | "before") {
        taken += 1;
    }
    let rest = words[..n.saturating_sub(taken)].join(" ");
    (rest.trim_end_matches([',', ' ']).to_string(), Some(time))
}

fn date_at_end(text: &str, today: Date) -> (String, Option<Date>) {
    let trimmed = text.trim().trim_end_matches(['.', '!', ',']).trim_end();
    let words: Vec<&str> = trimmed.split_whitespace().collect();
    let lower: Vec<String> = words
        .iter()
        .map(|word| word.trim_matches([',', '.']).to_lowercase())
        .collect();
    let plus = |days: i64| Date::from_days_since_epoch(today.days_since_epoch() + days);
    let weekday = |name: &str| {
        [
            "monday",
            "tuesday",
            "wednesday",
            "thursday",
            "friday",
            "saturday",
            "sunday",
        ]
        .iter()
        .position(|day| name.len() >= 3 && day.starts_with(name))
    };
    let month = |name: &str| {
        [
            "january",
            "february",
            "march",
            "april",
            "may",
            "june",
            "july",
            "august",
            "september",
            "october",
            "november",
            "december",
        ]
        .iter()
        .position(|month| *month == name || (name.len() >= 3 && month.starts_with(name)))
        .map(|month| month as u8 + 1)
    };
    let ordinal = |word: &str| {
        let digits = word.trim_end_matches(|c: char| c.is_ascii_alphabetic());
        digits
            .parse::<u8>()
            .ok()
            .filter(|day| (1..=31).contains(day))
    };
    let n = lower.len();
    let last = |k: usize| {
        lower
            .get(n.wrapping_sub(k))
            .map(String::as_str)
            .unwrap_or("")
    };
    // (how many words the date takes at the end, the date)
    let mut found: Option<(usize, Date)> = None;
    match last(1) {
        "today" | "tonight" => found = Some((1, today)),
        "tomorrow" => found = Some((1, plus(1))),
        "week" if last(2) == "next" => found = Some((2, plus(7 - today.weekday() as i64))),
        "weekend" if matches!(last(2), "this" | "the") => {
            found = Some((2, plus((5 + 7 - today.weekday() as i64) % 7)))
        }
        word => {
            if let Some(day) = weekday(word) {
                let ahead = (day as i64 - today.weekday() as i64).rem_euclid(7);
                let next = last(2) == "next";
                found = Some((
                    1 + usize::from(next || last(2) == "this"),
                    plus(if next && ahead == 0 { 7 } else { ahead }),
                ));
            } else if let Some(day) = ordinal(word) {
                if let Some(month) = month(last(2)) {
                    // "October 9th"
                    found = date_ahead(today, month, day).map(|date| (2, date));
                } else if last(2) == "the" {
                    // "the 9th": this month, or next if it has passed.
                    let this =
                        Date::new(today.year, today.month, day).filter(|date| *date >= today);
                    let next_month = if today.month == 12 {
                        (today.year + 1, 1)
                    } else {
                        (today.year, today.month + 1)
                    };
                    found = this
                        .or_else(|| Date::new(next_month.0, next_month.1, day))
                        .map(|date| (2, date));
                }
            } else if let Some(month) = month(word)
                && let Some(day) = ordinal(last(2))
            {
                // "9 October"
                found = date_ahead(today, month, day)
                    .map(|date| (2 + usize::from(last(3) == "the"), date));
            }
        }
    }
    let Some((mut taken, date)) = found else {
        return (text.trim().to_string(), None);
    };
    // "Move the meeting to Thursday": a day the task is about, not when it
    // is due.
    if matches!(
        last(taken + 1),
        "to" | "from" | "since" | "after" | "than" | "about" | "of"
    ) {
        return (text.trim().to_string(), None);
    }
    // "by", "before", "on", "until", "due" belong to the date.
    if matches!(
        last(taken + 1),
        "by" | "before" | "on" | "until" | "till" | "due" | "for"
    ) {
        taken += 1;
    }
    if taken >= n {
        // The whole to-do was a date: keep the words, set the date.
        return (text.trim().to_string(), Some(date));
    }
    let rest = words[..n - taken].join(" ");
    (rest.trim_end_matches([',', ' ']).to_string(), Some(date))
}

/// The next time a month and day come round, this year or next.
fn date_ahead(today: Date, month: u8, day: u8) -> Option<Date> {
    Date::new(today.year, month, day)
        .filter(|date| *date >= today)
        .or_else(|| Date::new(today.year + 1, month, day))
}

/// What the cleanup model returned, or plain speech, as tasks: one per line
/// when the model wrote lines; otherwise one per sentence and per "and then",
/// which keeps working with no model at all.
pub fn split(text: &str) -> Vec<String> {
    // The model answered with task lines: those are the tasks, even when
    // there is only one, so "john.smith@example.com" is never cut apart.
    let listed: Vec<String> = text
        .lines()
        .filter_map(task_or_bullet)
        .map(|line| clean(line).trim_end_matches('.').to_string())
        .filter(|line| !line.is_empty())
        .collect();
    if !listed.is_empty() {
        return listed;
    }
    let lines: Vec<String> = text
        .lines()
        .map(|line| match task(line) {
            Some((_, words)) => words.to_string(),
            None => line
                .trim()
                .trim_start_matches(|c: char| c.is_ascii_digit())
                .trim_start_matches(['.', ')'])
                .to_string(),
        })
        .map(|line| clean(&line))
        .filter(|line| !line.is_empty())
        .collect();
    if lines.len() > 1 {
        return lines
            .into_iter()
            .map(|line| line.trim_end_matches('.').to_string())
            .collect();
    }
    let mut items = Vec::new();
    for sentence in sentences(text) {
        for part in sentence.split(" and then ") {
            let part = clean(part.trim().trim_matches(','));
            if !part.is_empty() {
                items.push(part);
            }
        }
    }
    items
}

/// A "- task" or "* task" line, with or without a checkbox.
fn task_or_bullet(line: &str) -> Option<&str> {
    if let Some((_, words)) = task(line) {
        return Some(words);
    }
    let rest = line.trim_start();
    rest.strip_prefix(['-', '*', '•'])?
        .strip_prefix(' ')
        .map(str::trim)
}

/// Plain speech cut at the ends of sentences: a full stop, question or
/// exclamation mark or semicolon followed by a space or the end, so an
/// address, a decimal or a file name stays whole.
fn sentences(text: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut start = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((at, c)) = chars.next() {
        let ends = match c {
            '\n' => true,
            '.' | '!' | '?' | ';' => chars.peek().is_none_or(|(_, next)| next.is_whitespace()),
            _ => false,
        };
        if ends {
            parts.push(&text[start..at]);
            start = at + c.len_utf8();
        }
    }
    parts.push(&text[start..]);
    parts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_single_task_line_or_an_address_is_never_cut_apart() {
        assert_eq!(
            split("- Email john.smith@example.com about the contract"),
            vec!["Email john.smith@example.com about the contract"]
        );
        assert_eq!(
            split("Email john.smith@example.com about version 3.5. Then call Mira."),
            vec![
                "Email john.smith@example.com about version 3.5",
                "Then call Mira"
            ]
        );
    }

    fn items(texts: &[&str]) -> Vec<NewTodo> {
        texts
            .iter()
            .map(|text| NewTodo {
                text: text.to_string(),
                due: None,
                time: None,
                remind: Remind::Default,
            })
            .collect()
    }

    fn temp_list(name: &str) -> TodoList {
        let folder =
            std::env::temp_dir().join(format!("omaflow-todos-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&folder);
        TodoList::new(folder)
    }

    impl TodoList {
        /// Files beside the list that are not its own: a note and the
        /// journal's lock.
        fn journal_and_notes(&self) {
            fs::write(self.folder.join("ideas.md"), "Mine.").unwrap();
            fs::write(self.folder.join(".omaflow/lock"), "").unwrap();
        }
    }

    #[test]
    fn moving_the_list_takes_its_own_files_and_nothing_else() {
        let list = temp_list("move-folder");
        list.add(&items(&["buy milk"]), "").unwrap();
        list.create_list("Work").unwrap();
        list.set_current_list("Work").unwrap();
        list.journal_and_notes();
        let destination = list.folder().with_extension("moved");
        let _ = fs::remove_dir_all(&destination);
        let before = fs::read_to_string(list.path()).unwrap();

        assert_eq!(list.move_folder(&destination), Ok(Vec::new()));
        let moved = TodoList::new(&destination);
        assert_eq!(fs::read_to_string(moved.path()).unwrap(), before);
        assert_eq!(moved.current_list(), "Work");
        assert!(!list.path().exists());
        assert!(!list.current_path().exists());
        assert!(
            list.folder().join("ideas.md").is_file(),
            "your own files stay"
        );
        assert!(
            list.folder().join(".omaflow/lock").is_file(),
            "and the journal's"
        );
        assert_eq!(moved.move_folder(&destination), Ok(Vec::new()));
        let _ = fs::remove_dir_all(list.folder());
        let _ = fs::remove_dir_all(&destination);
    }

    #[test]
    fn moving_onto_a_list_already_there_moves_nothing() {
        let list = temp_list("move-folder-clash");
        list.add(&items(&["buy milk"]), "").unwrap();
        let destination = list.folder().with_extension("clash");
        let _ = fs::remove_dir_all(&destination);
        fs::create_dir_all(&destination).unwrap();
        fs::write(destination.join(FILE_NAME), "- [ ] Theirs\n").unwrap();

        assert_eq!(
            list.move_folder(&destination),
            Err(MoveError::Clash(vec![FILE_NAME.into()]))
        );
        assert!(list.path().is_file());
        assert_eq!(
            fs::read_to_string(destination.join(FILE_NAME)).unwrap(),
            "- [ ] Theirs\n"
        );
        let _ = fs::remove_dir_all(list.folder());
        let _ = fs::remove_dir_all(&destination);
    }

    #[test]
    fn tasks_are_added_ticked_and_edited_in_a_plain_checklist() {
        let list = temp_list("basics");
        list.add(&items(&["buy milk", "Call Mira about the workshop"]), "")
            .unwrap();
        list.set_done(0, "Buy milk", true).unwrap();
        list.edit(1, "Call Mira about the workshop", "Call Mira before Friday")
            .unwrap();
        assert_eq!(
            fs::read_to_string(list.path()).unwrap(),
            "# To-dos\n\n- [x] Buy milk\n- [ ] Call Mira before Friday\n"
        );
        let todos = list.list().unwrap();
        assert!(todos[0].done && !todos[1].done);
    }

    #[test]
    fn other_lines_in_the_file_are_left_alone() {
        let list = temp_list("others");
        fs::create_dir_all(list.folder()).unwrap();
        fs::write(
            list.path(),
            "# Mine\n\nSome notes.\n\n* [X] Old thing\n\nMore notes.\n",
        )
        .unwrap();
        list.add(&items(&["New thing"]), "").unwrap();
        assert_eq!(
            fs::read_to_string(list.path()).unwrap(),
            "# Mine\n\nSome notes.\n\n* [X] Old thing\n- [ ] New thing\n\nMore notes.\n"
        );
    }

    #[test]
    fn a_task_moved_by_another_app_is_still_found_by_its_words() {
        let list = temp_list("moved");
        list.add(&items(&["One", "Two"]), "").unwrap();
        fs::write(
            list.path(),
            "# To-dos\n\n- [ ] Zero\n- [ ] One\n- [ ] Two\n",
        )
        .unwrap();
        list.set_done(1, "Two", true).unwrap();
        assert!(
            list.list()
                .unwrap()
                .iter()
                .any(|todo| todo.text == "Two" && todo.done)
        );
        assert!(
            list.list()
                .unwrap()
                .iter()
                .any(|todo| todo.text == "One" && !todo.done)
        );
    }

    #[test]
    fn deleted_and_cleared_tasks_come_back_in_place_for_ten_seconds() {
        let list = temp_list("undo");
        list.add(&items(&["One", "Two", "Three"]), "").unwrap();
        let before = fs::read_to_string(list.path()).unwrap();
        list.remove(&[(1, "Two".into())], true).unwrap();
        list.restore().unwrap();
        assert_eq!(fs::read_to_string(list.path()).unwrap(), before);
        list.set_done(0, "One", true).unwrap();
        list.set_done(2, "Three", true).unwrap();
        let ticked = fs::read_to_string(list.path()).unwrap();
        assert_eq!(list.clear_done(None).unwrap(), 2);
        assert_eq!(list.list().unwrap().len(), 1);
        list.restore().unwrap();
        assert_eq!(fs::read_to_string(list.path()).unwrap(), ticked);
        assert!(list.restore().is_err(), "undo only once");
    }

    #[test]
    fn spoken_lists_split_into_tasks() {
        assert_eq!(
            split("- Buy milk\n- Call Mira before Friday"),
            vec!["Buy milk", "Call Mira before Friday"]
        );
        assert_eq!(
            split("1. buy milk\n2) call Mira"),
            vec!["Buy milk", "Call Mira"]
        );
        assert_eq!(
            split("Buy milk. Then call Mira and then renew the passport."),
            vec!["Buy milk", "Then call Mira", "Renew the passport"]
        );
        assert_eq!(
            split("Buy milk, eggs and bread"),
            vec!["Buy milk, eggs and bread"]
        );
    }

    #[test]
    fn lists_are_headings_and_tasks_keep_their_due_dates() {
        let list = temp_list("lists");
        let friday = Date::new(2026, 10, 2).unwrap();
        list.add(&items(&["Buy oat milk"]), "").unwrap();
        list.add(
            &[NewTodo {
                text: "Renew the certs".into(),
                due: Some(friday),
                time: None,
                remind: Remind::Default,
            }],
            "Infra",
        )
        .unwrap();
        list.add(&items(&["Fix the AltGr binding"]), "Dev").unwrap();
        list.add(&items(&["Call Mira"]), "").unwrap();
        assert_eq!(
            fs::read_to_string(list.path()).unwrap(),
            "# To-dos\n\n- [ ] Buy oat milk\n- [ ] Call Mira\n\n## Infra\n\n- [ ] Renew the certs 📅 2026-10-02\n\n## Dev\n\n- [ ] Fix the AltGr binding\n"
        );
        let todos = list.list().unwrap();
        assert_eq!(todos[2].list, "Infra");
        assert_eq!(todos[2].text, "Renew the certs");
        assert_eq!(todos[2].due.as_deref(), Some("2026-10-02"));
        list.set_done(2, "Renew the certs", true).unwrap();
        list.edit(2, "Renew the certs", "Renew the TLS certs")
            .unwrap();
        assert!(
            fs::read_to_string(list.path())
                .unwrap()
                .contains("- [x] Renew the TLS certs 📅 2026-10-02")
        );
        assert_eq!(list.lists().unwrap(), vec!["Infra", "Dev"]);
    }

    #[test]
    fn tasks_move_between_lists_and_a_deleted_list_comes_back() {
        let list = temp_list("move");
        list.add(&items(&["One", "Two"]), "Infra").unwrap();
        list.create_list("Dev").unwrap();
        let moved = list.move_to(&[(1, "Two".into())], "Dev").unwrap();
        assert_eq!(moved[0].list, "Dev");
        assert_eq!(moved[0].text, "Two");
        let before = fs::read_to_string(list.path()).unwrap();
        assert_eq!(list.delete_list("Infra").unwrap(), 1);
        let todos = list.list().unwrap();
        assert_eq!(
            (todos[0].text.as_str(), todos[0].list.as_str()),
            ("One", "")
        );
        assert_eq!(list.lists().unwrap(), vec!["Dev"]);
        list.restore().unwrap();
        assert_eq!(fs::read_to_string(list.path()).unwrap(), before);
        list.rename_list("Dev", "Development").unwrap();
        assert_eq!(list.lists().unwrap(), vec!["Infra", "Development"]);
        assert!(list.create_list("inbox").is_err());
        assert!(list.create_list("infra").is_err());
    }

    #[test]
    fn the_current_list_falls_back_to_the_inbox() {
        let list = temp_list("current");
        assert_eq!(list.current_list(), "");
        list.create_list("Infra").unwrap();
        list.set_current_list("Infra").unwrap();
        assert_eq!(list.current_list(), "Infra");
        list.delete_list("Infra").unwrap();
        assert_eq!(list.current_list(), "");
    }

    #[test]
    fn a_deadline_at_the_end_becomes_a_date() {
        // Thursday 1 October 2026.
        let today = Date::new(2026, 10, 1).unwrap();
        let date = |y, m, d| Some(Date::new(y, m, d).unwrap());
        let check = |text: &str, words: &str, when: Option<Date>| {
            let said = due(text, today, "10:00");
            assert_eq!(
                (said.text, said.date, said.time),
                (words.to_string(), when, None),
                "{text}"
            );
        };
        check(
            "Move the backups before Friday",
            "Move the backups",
            date(2026, 10, 2),
        );
        check("Call Mira tomorrow.", "Call Mira", date(2026, 10, 2));
        check(
            "Renew the certs by Thursday",
            "Renew the certs",
            date(2026, 10, 1),
        );
        check(
            "Book the train next Thursday",
            "Book the train",
            date(2026, 10, 8),
        );
        check(
            "Send the invoice by the 9th",
            "Send the invoice",
            date(2026, 10, 9),
        );
        check("Pay rent on the 1st", "Pay rent", date(2026, 10, 1));
        check(
            "Renew the passport by March 3",
            "Renew the passport",
            date(2027, 3, 3),
        );
        check(
            "Plan the trip next week",
            "Plan the trip",
            date(2026, 10, 5),
        );
        check(
            "Clean the garage this weekend",
            "Clean the garage",
            date(2026, 10, 3),
        );
        check("Buy oat milk", "Buy oat milk", None);
        check(
            "Review what Friday's call decided",
            "Review what Friday's call decided",
            None,
        );
        check("Tomorrow", "Tomorrow", date(2026, 10, 2));
        check("Prep for the 1:1", "Prep for the 1:1", None);
        check(
            "Move the meeting to Thursday",
            "Move the meeting to Thursday",
            None,
        );
        check("Ask about Friday", "Ask about Friday", None);
    }

    #[test]
    fn a_time_said_with_the_deadline_becomes_a_reminder() {
        // Thursday 1 October 2026, 10:00.
        let today = Date::new(2026, 10, 1).unwrap();
        let at = |y, m, d, time: &str| (Some(Date::new(y, m, d).unwrap()), Some(time.to_string()));
        let check = |text: &str, words: &str, when: (Option<Date>, Option<String>)| {
            let said = due(text, today, "10:00");
            assert_eq!(
                (said.text, said.date, said.time),
                (words.to_string(), when.0, when.1),
                "{text}"
            );
        };
        check(
            "Call Mira tomorrow at 3pm",
            "Call Mira",
            at(2026, 10, 2, "15:00"),
        );
        check(
            "Call Mira at 3:30 p.m. on Friday",
            "Call Mira",
            at(2026, 10, 2, "15:30"),
        );
        check("Stand-up at 9 am", "Stand-up", at(2026, 10, 2, "09:00"));
        check(
            "Lunch with Jonas at noon",
            "Lunch with Jonas",
            at(2026, 10, 1, "12:00"),
        );
        check("Deploy at 17:45", "Deploy", at(2026, 10, 1, "17:45"));
        check(
            "Midnight release at 12am",
            "Midnight release",
            at(2026, 10, 2, "00:00"),
        );
    }

    #[test]
    fn a_time_is_written_for_tasks_and_reminders_and_read_back() {
        let list = temp_list("time");
        let friday = Date::new(2026, 10, 2).unwrap();
        list.add(
            &[NewTodo {
                text: "Call Mira".into(),
                due: Some(friday),
                time: Some("15:00".into()),
                remind: Remind::Default,
            }],
            "",
        )
        .unwrap();
        assert!(
            fs::read_to_string(list.path())
                .unwrap()
                .contains("- [ ] Call Mira ⏰ 2026-10-02 15:00 📅 2026-10-02\n")
        );
        let todo = &list.list().unwrap()[0];
        assert_eq!(
            (
                todo.text.as_str(),
                todo.due.as_deref(),
                todo.time.as_deref()
            ),
            ("Call Mira", Some("2026-10-02"), Some("15:00"))
        );
        // Ticking and editing keep the time; a new day without one drops it.
        list.set_done(0, "Call Mira", true).unwrap();
        list.edit(0, "Call Mira", "Call Mira back").unwrap();
        assert_eq!(list.list().unwrap()[0].time.as_deref(), Some("15:00"));
        list.set_due(0, "Call Mira back", Some(friday), Some("9:05"), None)
            .unwrap();
        assert_eq!(list.list().unwrap()[0].time.as_deref(), Some("09:05"));
        list.set_due(0, "Call Mira back", None, Some("9:05"), None)
            .unwrap();
        let todo = &list.list().unwrap()[0];
        assert_eq!((todo.due.as_deref(), todo.time.as_deref()), (None, None));
        assert!(
            list.set_due(0, "Call Mira back", Some(friday), Some("noonish"), None)
                .is_err()
        );
    }

    #[test]
    fn a_reminder_comes_once_when_its_time_does() {
        let list = temp_list("remind");
        let thursday = Date::new(2026, 10, 1).unwrap();
        let add = |text: &str, time: &str| {
            list.add(
                &[NewTodo {
                    text: text.into(),
                    due: Some(thursday),
                    time: Some(time.into()),
                    remind: Remind::Default,
                }],
                "",
            )
            .unwrap();
        };
        add("Call Mira", "15:00");
        add("Stand-up", "09:00");
        assert!(list.reminders(thursday, "08:59", 0).unwrap().is_empty());
        let now: Vec<String> = list
            .reminders(thursday, "15:00", 0)
            .unwrap()
            .into_iter()
            .map(|todo| todo.text)
            .collect();
        assert_eq!(now, vec!["Call Mira", "Stand-up"]);
        assert!(
            list.reminders(thursday, "15:01", 0).unwrap().is_empty(),
            "each only once"
        );
        // Done before its time: no reminder.
        add("Water the plants", "16:00");
        list.set_done(2, "Water the plants", true).unwrap();
        assert!(list.reminders(thursday, "16:30", 0).unwrap().is_empty());
    }

    #[test]
    fn a_reminder_can_come_early_even_across_midnight() {
        let list = temp_list("remind-early");
        let thursday = Date::new(2026, 10, 1).unwrap();
        let friday = Date::new(2026, 10, 2).unwrap();
        list.add(
            &[NewTodo {
                text: "Call the bank".into(),
                due: Some(thursday),
                time: Some("15:00".into()),
                remind: Remind::Default,
            }],
            "",
        )
        .unwrap();
        list.add(
            &[NewTodo {
                text: "Catch the night train".into(),
                due: Some(friday),
                time: Some("00:10".into()),
                remind: Remind::Default,
            }],
            "",
        )
        .unwrap();
        assert!(list.reminders(thursday, "14:44", 15).unwrap().is_empty());
        let early: Vec<String> = list
            .reminders(thursday, "14:45", 15)
            .unwrap()
            .into_iter()
            .map(|todo| todo.text)
            .collect();
        assert_eq!(early, vec!["Call the bank"]);
        // Fifteen minutes before 00:10 on Friday is 23:55 on Thursday.
        assert!(list.reminders(thursday, "23:54", 15).unwrap().is_empty());
        let night: Vec<String> = list
            .reminders(thursday, "23:55", 15)
            .unwrap()
            .into_iter()
            .map(|todo| todo.text)
            .collect();
        assert_eq!(night, vec!["Catch the night train"]);
    }

    #[test]
    fn a_reminder_said_with_the_to_do_is_kept_and_its_words_dropped() {
        let today = Date::new(2026, 10, 1).unwrap();
        let check = |text: &str, words: &str, time: &str, remind: Remind| {
            let said = due(text, today, "10:00");
            assert_eq!(
                (said.text.as_str(), said.time.as_deref(), said.remind),
                (words, Some(time), remind),
                "{text}"
            );
        };
        check(
            "Call the bank at 3pm, remind me 30 minutes before",
            "Call the bank",
            "15:00",
            Remind::Before(30),
        );
        check(
            "Call the bank at 3pm remind me half an hour early",
            "Call the bank",
            "15:00",
            Remind::Before(30),
        );
        check(
            "Pick up Lina at 6pm an hour before",
            "Pick up Lina",
            "18:00",
            Remind::Before(60),
        );
        check(
            "Stand-up at 9:30 tomorrow, remind me fifteen minutes before",
            "Stand-up",
            "09:30",
            Remind::Before(15),
        );
        check(
            "Dentist at 4pm, remind me a quarter of an hour before",
            "Dentist",
            "16:00",
            Remind::Before(15),
        );
        check(
            "Call Mira at 11am, remind me at 10:45",
            "Call Mira",
            "11:00",
            Remind::At("2026-10-01 10:45".into()),
        );
        check(
            "Stand-up at 9:30 tomorrow, no reminder",
            "Stand-up",
            "09:30",
            Remind::Off,
        );
        check(
            "Dentist on Friday at 4pm (remind me at 3:30)",
            "Dentist",
            "16:00",
            Remind::At("2026-10-02 15:30".into()),
        );
        check(
            "Pick up Lina at six pm, remind me an hour before",
            "Pick up Lina",
            "18:00",
            Remind::Before(60),
        );
        check(
            "Water the plants at 7pm but don't remind me",
            "Water the plants",
            "19:00",
            Remind::Off,
        );
        // "before" belonging to the task is left alone.
        let said = due("Move the backups before Friday", today, "10:00");
        assert_eq!(
            (said.text.as_str(), said.remind),
            ("Move the backups", Remind::Default)
        );
    }

    #[test]
    fn a_reminder_set_by_hand_is_written_and_read_back_and_follows_the_time() {
        let list = temp_list("remind-hand");
        let friday = Date::new(2026, 10, 2).unwrap();
        list.add(
            &[NewTodo {
                text: "Pick up Lina".into(),
                due: Some(friday),
                time: Some("18:00".into()),
                remind: Remind::Before(30),
            }],
            "",
        )
        .unwrap();
        list.add(
            &[NewTodo {
                text: "Stand-up".into(),
                due: Some(friday),
                time: Some("09:30".into()),
                remind: Remind::Off,
            }],
            "",
        )
        .unwrap();
        list.add(
            &[NewTodo {
                text: "Call the bank".into(),
                due: Some(friday),
                time: Some("15:00".into()),
                remind: Remind::Default,
            }],
            "",
        )
        .unwrap();
        let file = fs::read_to_string(list.path()).unwrap();
        assert!(
            file.contains("- [ ] Pick up Lina 🕒 18:00 ⏰ 2026-10-02 17:30 📅 2026-10-02\n"),
            "{file}"
        );
        assert!(
            file.contains("- [ ] Stand-up 🕒 09:30 📅 2026-10-02\n"),
            "{file}"
        );
        assert!(
            file.contains("- [ ] Call the bank ⏰ 2026-10-02 15:00 📅 2026-10-02\n"),
            "{file}"
        );
        let todos = list.list().unwrap();
        assert_eq!(
            (todos[0].time.as_deref(), todos[0].reminder.as_deref()),
            (Some("18:00"), Some("2026-10-02 17:30"))
        );
        assert_eq!(todos[1].reminder.as_deref(), Some(REMINDER_OFF));
        assert_eq!(todos[2].reminder, None);
        // A new time keeps "30 minutes before".
        list.set_due(0, "Pick up Lina", Some(friday), Some("19:00"), None)
            .unwrap();
        assert_eq!(
            list.list().unwrap()[0].reminder.as_deref(),
            Some("2026-10-02 18:30")
        );
        // Ticking and editing keep it.
        list.edit(0, "Pick up Lina", "Pick up Lina at the station")
            .unwrap();
        assert_eq!(
            list.list().unwrap()[0].reminder.as_deref(),
            Some("2026-10-02 18:30")
        );
        // Back to the default, and a reminder needs a time.
        list.set_reminder(0, "Pick up Lina at the station", Remind::Default)
            .unwrap();
        assert_eq!(list.list().unwrap()[0].reminder, None);
        list.add(&items(&["Renew the passport"]), "").unwrap();
        assert!(
            list.set_reminder(3, "Renew the passport", Remind::Before(15))
                .is_err()
        );
    }

    #[test]
    fn each_to_do_reminds_at_its_own_moment_and_a_snooze_comes_again() {
        let list = temp_list("remind-moment");
        let friday = Date::new(2026, 10, 2).unwrap();
        let add = |text: &str, time: &str, remind: Remind| {
            list.add(
                &[NewTodo {
                    text: text.into(),
                    due: Some(friday),
                    time: Some(time.into()),
                    remind,
                }],
                "",
            )
            .unwrap();
        };
        add("Call the bank", "15:00", Remind::Default);
        add("Pick up Lina", "18:00", Remind::Before(30));
        add("Stand-up", "09:30", Remind::Off);
        let texts = |now: &str, before: u32| -> Vec<String> {
            list.reminders(friday, now, before)
                .unwrap()
                .into_iter()
                .map(|todo| todo.text)
                .collect()
        };
        // The default moves "Call the bank"; Lina keeps 17:30; Stand-up never.
        assert_eq!(texts("14:45", 15), vec!["Call the bank"]);
        assert_eq!(texts("17:29", 15), Vec::<String>::new());
        assert_eq!(texts("17:30", 15), vec!["Pick up Lina"]);
        assert_eq!(texts("23:00", 15), Vec::<String>::new());
        assert_eq!(list.reminded(15).unwrap(), vec![0, 1]);
        // Snoozed to 18:30: it comes once more, at the new moment.
        list.set_reminder(1, "Pick up Lina", Remind::At("2026-10-02 18:30".into()))
            .unwrap();
        assert_eq!(texts("18:29", 15), Vec::<String>::new());
        assert_eq!(texts("18:30", 15), vec!["Pick up Lina"]);
    }
}
