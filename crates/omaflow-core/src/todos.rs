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
use crate::fsutil::{owned_dir, write_owned};
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
    /// `HH:MM` on the due day, if it has one: when to be reminded.
    pub time: Option<String>,
}

/// A task to add: its words and, if it has one, when it is due.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewTodo {
    pub text: String,
    pub due: Option<Date>,
    /// `HH:MM`; only kept with a date.
    pub time: Option<String>,
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

/// A task's words, due date and time, from what follows the checkbox.
fn words_and_due(rest: &str) -> (&str, Option<&str>, Option<String>) {
    let (mut words, mut due) = (rest, None);
    if let Some(at) = rest.rfind(DUE_MARK) {
        let date = rest[at + DUE_MARK.len()..].trim();
        let date = date.get(..10).unwrap_or(date);
        if date.parse::<Date>().is_ok() {
            (words, due) = (rest[..at].trim_end(), Some(date));
        }
    }
    // `⏰ 2026-10-03 15:00`, the reminder, just before the date.
    if let Some(at) = words.rfind(TIME_MARK) {
        let mut parts = words[at + TIME_MARK.len()..].split_whitespace();
        if let (Some(date), Some(time), None) = (parts.next(), parts.next(), parts.next())
            && date.parse::<Date>().is_ok()
            && let Some(time) = clock_time(time)
        {
            return (words[..at].trim_end(), due.or(Some(date)), Some(time));
        }
    }
    (words, due, None)
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

fn task_line(done: bool, text: &str, due: Option<&str>, time: Option<&str>) -> String {
    let mut line = format!("- [{}] {text}", if done { "x" } else { " " });
    if let Some(due) = due {
        if let Some(time) = time {
            line.push_str(&format!(" {TIME_MARK} {due} {time}"));
        }
        line.push_str(&format!(" {DUE_MARK} {due}"));
    }
    line
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
            let (text, due, time) = words_and_due(rest);
            let index = found.len();
            found.push((
                line,
                Todo {
                    index,
                    text: text.to_string(),
                    done,
                    list: list.clone(),
                    due: due.map(str::to_string),
                    time,
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
                "OmaFlow is not allowed to write {}. Choose the folder again in the To-dos settings.",
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
        let items: Vec<(String, Option<String>, Option<String>)> = items
            .iter()
            .map(|item| {
                let due = item.due.map(|due| due.to_string());
                let time = item
                    .time
                    .as_deref()
                    .and_then(clock_time)
                    .filter(|_| due.is_some());
                (clean(&item.text), due, time)
            })
            .filter(|(text, _, _)| !text.is_empty())
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
        for (offset, (text, due, time)) in items.iter().enumerate() {
            lines.insert(
                at + offset,
                task_line(false, text, due.as_deref(), time.as_deref()),
            );
        }
        self.write(&lines)?;
        Ok(items
            .into_iter()
            .enumerate()
            .map(|(offset, (text, due, time))| Todo {
                index: before + offset,
                text,
                done: false,
                list: list.clone(),
                due,
                time,
            })
            .collect())
    }

    /// Rewrites one task's line, keeping its indentation and bullet.
    fn rewrite(
        &self,
        index: usize,
        text: &str,
        change: impl FnOnce(bool, &str, Option<&str>, Option<&str>) -> Result<String, String>,
    ) -> Result<(), String> {
        let _lock = self.lock()?;
        let mut lines = self.lines()?;
        let line = Self::existing(&lines, index, text)?;
        let content = lines[line].clone();
        let (done, rest) = task(&content).ok_or("That to-do is no longer in the list")?;
        let (words, due, time) = words_and_due(rest);
        let prefix = &content[..content.find('[').unwrap_or(0)];
        let next = change(done, words, due, time.as_deref())?;
        lines[line] = format!("{prefix}{}", next.trim_start_matches("- "));
        self.write(&lines)
    }

    pub fn set_done(&self, index: usize, text: &str, done: bool) -> Result<(), String> {
        self.rewrite(index, text, |_, words, due, time| {
            Ok(task_line(done, words, due, time))
        })
    }

    pub fn edit(&self, index: usize, text: &str, new_text: &str) -> Result<(), String> {
        let new_text = clean(new_text);
        if new_text.is_empty() {
            return Err("A to-do needs words. Use Delete to remove it.".into());
        }
        self.rewrite(index, text, |done, _, due, time| {
            Ok(task_line(done, &new_text, due, time))
        })
    }

    /// Sets or clears when a task is due, and at what time; no date clears
    /// the time too.
    pub fn set_due(
        &self,
        index: usize,
        text: &str,
        due: Option<Date>,
        time: Option<&str>,
    ) -> Result<(), String> {
        let due = due.map(|due| due.to_string());
        let time = match time {
            Some(value) => Some(clock_time(value).ok_or("Write the time as HH:MM, such as 15:00")?),
            None => None,
        }
        .filter(|_| due.is_some());
        self.rewrite(index, text, |done, words, _, _| {
            Ok(task_line(done, words, due.as_deref(), time.as_deref()))
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
            return Err("Those to-dos are no longer in the list".into());
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
            return Err("Those to-dos are no longer in the list".into());
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

    /// Open to-dos whose time has come, each handed out once: what to remind
    /// you of now. One missed while the computer was off still comes, if it
    /// is less than a day late. `now` is the local date and `HH:MM`.
    pub fn reminders(&self, today: Date, now: &str) -> Result<Vec<Todo>, String> {
        let key = |todo: &Todo| {
            format!(
                "{} {} {}",
                todo.due.as_deref().unwrap_or(""),
                todo.time.as_deref().unwrap_or(""),
                todo.text
            )
        };
        let yesterday = Date::from_days_since_epoch(today.days_since_epoch() - 1).to_string();
        let today = today.to_string();
        let todos = self.list()?;
        let waiting: Vec<&Todo> = todos
            .iter()
            .filter(|todo| !todo.done)
            .filter(|todo| match (todo.due.as_deref(), todo.time.as_deref()) {
                (Some(due), Some(time)) => {
                    (due == today && time <= now) || (due == yesterday && time > now)
                }
                _ => false,
            })
            .collect();
        let mut reminded: Vec<String> = fs::read(self.reminded_path())
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        let due: Vec<Todo> = waiting
            .iter()
            .filter(|todo| !reminded.contains(&key(todo)))
            .map(|todo| (*todo).clone())
            .collect();
        // Keep only what is still waiting, so the file never grows.
        let still: Vec<String> = waiting.iter().map(|todo| key(todo)).collect();
        reminded.retain(|entry| still.contains(entry));
        reminded.extend(due.iter().map(key));
        if !due.is_empty() || reminded.len() != still.len() {
            owned_dir(&self.folder.join(".omaflow"))?;
            let bytes = serde_json::to_vec(&reminded).map_err(|error| error.to_string())?;
            write_owned(&self.reminded_path(), &bytes)?;
        }
        Ok(due)
    }
}

/// A deadline said at the end of a to-do, such as "before Friday", "by the
/// 9th" or "Friday at 3pm": the words without it, the date and the time
/// (`HH:MM`). Only the end is read, where people put a deadline, so "Review
/// what Friday's call decided" keeps its words and gets no date. A time with
/// no day is today, or tomorrow once it has passed; `now` is `HH:MM`.
pub fn due(text: &str, today: Date, now: &str) -> (String, Option<Date>, Option<String>) {
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
    (rest, date, time)
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
        let hours: u8 = hours.parse().ok()?;
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
    for sentence in text.split(['.', '!', '?', ';', '\n']) {
        for part in sentence.split(" and then ") {
            let part = clean(part.trim().trim_matches(','));
            if !part.is_empty() {
                items.push(part);
            }
        }
    }
    items
}

#[cfg(test)]
mod tests {
    use super::*;

    fn items(texts: &[&str]) -> Vec<NewTodo> {
        texts
            .iter()
            .map(|text| NewTodo {
                text: text.to_string(),
                due: None,
                time: None,
            })
            .collect()
    }

    fn temp_list(name: &str) -> TodoList {
        let folder =
            std::env::temp_dir().join(format!("omaflow-todos-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&folder);
        TodoList::new(folder)
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
            assert_eq!(
                due(text, today, "10:00"),
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
            assert_eq!(
                due(text, today, "10:00"),
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
        list.set_due(0, "Call Mira back", Some(friday), Some("9:05"))
            .unwrap();
        assert_eq!(list.list().unwrap()[0].time.as_deref(), Some("09:05"));
        list.set_due(0, "Call Mira back", None, Some("9:05"))
            .unwrap();
        let todo = &list.list().unwrap()[0];
        assert_eq!((todo.due.as_deref(), todo.time.as_deref()), (None, None));
        assert!(
            list.set_due(0, "Call Mira back", Some(friday), Some("noonish"))
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
                }],
                "",
            )
            .unwrap();
        };
        add("Call Mira", "15:00");
        add("Stand-up", "09:00");
        assert!(list.reminders(thursday, "08:59").unwrap().is_empty());
        let now: Vec<String> = list
            .reminders(thursday, "15:00")
            .unwrap()
            .into_iter()
            .map(|todo| todo.text)
            .collect();
        assert_eq!(now, vec!["Call Mira", "Stand-up"]);
        assert!(
            list.reminders(thursday, "15:01").unwrap().is_empty(),
            "each only once"
        );
        // Done before its time: no reminder.
        add("Water the plants", "16:00");
        list.set_done(2, "Water the plants", true).unwrap();
        assert!(list.reminders(thursday, "16:30").unwrap().is_empty());
    }
}
