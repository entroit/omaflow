# Command reference

`omaflow` is one binary. The daemon and the speech server run as user
services; most other commands talk to the running daemon over its socket and
return immediately. The Hyprland binding, the bar widget and the installer use
the same commands, so anything the window does can be scripted.

## Recording

| Command | Effect |
|---|---|
| `press` | Start recording. A second press within one second locks it. With the daemon down, starts it and says to hold the key again. |
| `release` | Finish a held recording and deliver the text. |
| `stop` | Finish a locked recording. `toggle` is an alias. |
| `cancel` | Throw the current recording away without delivering anything. |
| `close` | Dismiss the result or error card. This is what Esc runs, so it does nothing while a to-do on the card is being edited, or while a failed dictation's recording is kept. |
| `dismiss` | Dismiss the card even mid-edit. Its Esc button runs this. A card with a kept recording stays. |
| `retry` | After a failed transcription, send the same recording again. The recording is kept in memory only until this, `discard`, or the next recording. |
| `discard` | Throw a failed dictation's kept recording away and close its card. |
| `card-hold` / `card-edit` / `card-resume` | Stop a self-closing card's clock while it is pointed at, or while a to-do on it is edited (when Esc ends the edit, not the card); resume gives it its whole time again. |
| `journal-press` / `journal-release` | The journal shortcut, down and up: the same as `press` and `release`, but the words go to today's journal. |
| `journal-toggle [DATE]` | Start a hands-free journal entry, or save the one being recorded. With a later date, a note to yourself for that day. With a past date, an entry added to that day, headed with its time and the day it was added (`## 21:53, added 2026-10-06`). |
| `todo-press` / `todo-release` | The to-do shortcut, down and up: the words become tasks on the to-do list. |
| `todo-toggle [JSON]` | Start recording to-dos hands-free, or add the ones being recorded. With `{"list":"Infra","due":"2026-10-02"}`, they go to that list, and to-dos that name no date get that one. |
| `todo-list LIST` | Make LIST the current list, where new to-dos go; `""` is the Inbox. While to-dos are being recorded, they go there too. |
| `todo-move LIST` | Move the to-dos the card announces to LIST, and make it current. |
| `todo-discard` | Throw away the journal entry or to-dos being recorded, or a failed one's kept recording. `journal-discard` is the same. |
| `todo-undo` | Take the last capture's tasks back out of the list. |
| `todo-card-edit INDEX TEXT NEW` | Change the words of one of the to-dos the card shows. |
| `todo-card-remove INDEX TEXT` | Take one of the to-dos the card shows back out; the last one closes the card. |

## To-dos

These read and edit `To-dos.md` directly, without the daemon, and print JSON.
A task is named by its place among the tasks, from 0, and its words, as
`todos list` prints them, so a list edited elsewhere is never changed in the
wrong place. A list is a `## Heading` in the file; `""` names the Inbox, the
tasks above the first heading.

| Command | Effect |
|---|---|
| `todos list` | Every task, open and done, with its list, due date, time and reminder, the lists, the current list, the file's path, and `reminded`: the open tasks whose reminder has gone off. |
| `todos add TEXT [LIST [DUE]]` | Add open tasks to LIST, one per line of TEXT. A line ending in a deadline such as "by Friday" or "Friday at 3pm" gets that date and time; DUE is the date for lines without one. |
| `todos due I TEXT DATE [HH:MM [REMIND]]` | Set when a task is due, as `2026-10-02`, and at what time, or `""` for no date. REMIND is as for `todos remind`; left out, a reminder set on the task moves with its time. |
| `todos remind I TEXT REMIND` | When a task with a time reminds you: `default` (`[todos] remind_before`), `off`, or a number of minutes before. |
| `todos snooze I TEXT MINUTES` | Remind again in that many minutes, or `tomorrow` at the same time. Prints `until`. |
| `todos reminders` | The open tasks whose reminder is due (at their time, `[todos] remind_before` minutes earlier, or when set on the task), each listed once. The shell asks just after every minute turns over and shows them as notifications. |
| `todos move I TEXT LIST` | Move a task to the end of another list. |
| `todos new-list NAME` / `todos rename-list LIST NAME` | Make a list, or rename one. |
| `todos delete-list LIST` | Delete a list; its tasks move to the Inbox. `todos restore` brings it back for ten seconds. |
| `todos done I TEXT` / `todos undone I TEXT` | Tick a task, or untick it. |
| `todos edit I TEXT NEW` | Change a task's words. |
| `todos delete I TEXT` | Delete a task. `todos restore` brings it back for ten seconds. |
| `todos clear-done [LIST]` | Take every ticked task out. `todos restore` brings them back for ten seconds. |
| `todos forget-deleted` | Drop what `restore` would bring back. |

## Delivery

| Command | Effect |
|---|---|
| `copy` | Copy the last result to the clipboard without pasting. |
| `paste-last` | Paste the most recent dictation into the focused window again. |
| `paste-mode auto\|ctrl-v\|shift-insert\|clipboard\|custom` | Choose how text reaches the focused window. `clipboard` copies only; `custom` uses the chord saved in Settings → Advanced → Hotkeys. |

## History

History is empty unless `history_limit` is above zero.

| Command | Effect |
|---|---|
| `history-paste ID` | Paste a saved dictation. |
| `history-copy ID` | Copy a saved dictation. |
| `history-raw ID` | Copy the original recognized text, before cleanup, to the clipboard. |
| `history-edit ID TEXT` | Replace the saved text. Undoable with `history-undo`. |
| `history-delete ID` | Delete one entry. Undoable until the daemon exits. |
| `history-retry ID` | Transcribe a dictation that failed again, from its saved recording. Its words show in History; nothing is pasted. |
| `history-undo` | Undo the last delete, clear or edit. |
| `history-clear` | Delete every entry. Undoable until the daemon exits. |
| `erase-data` | Delete the history file and the training log. Not undoable. |

## Settings

| Command | Effect |
|---|---|
| `configure KEY JSON` | Write one setting to `~/.config/omaflow/config.toml` and apply it. This is what the window calls. Pass `-` instead of JSON to read the value from one line of stdin. |
| `vocabulary-add TERM` / `vocabulary-remove TERM` | Edit the custom vocabulary. |
| `reload-config` | Re-read `config.toml` and regenerate the Hyprland shortcut. When the file is refused, prints why on stderr, as one line. With OmaFlow stopped, a valid file is left for its next start. |
| `effective-config` | Print the merged configuration the daemon is using. |
| `config-init` | Fill in any missing keys in the personal config. |

## Microphone

| Command | Effect |
|---|---|
| `configure meter_gate_auto true` | Place the meter's Voice detected threshold automatically, a little above the room's noise. This is the default. `false` uses the `meter-gate` value. |
| `meter-gate DB` | Set the manual dBFS threshold for the meter's Voice detected indicator, used when `meter_gate_auto` is off. It does not filter recorded audio. |
| `meter-gate-preview DB` | Try a manual threshold without saving it. |

## Models

| Command | Effect |
|---|---|
| `model-catalog` | Print the built-in catalog as JSON, with an `installed` and a `selected` flag per entry. |
| `model-select speech\|cleanup ID` | Switch to a catalog model whose weights are already on disk. |
| `model-install speech\|cleanup ID` | Download a catalog model, then switch to it. Reports progress to the window and the result as a notification. The first managed speech model also installs the NeMo-Speech runtime: the CUDA build when an NVIDIA driver is loaded, the CPU build otherwise. |
| `configure models JSON` | Save speech and cleanup model selections, including a model or server the catalog does not offer. |

Both `model-select` and `model-install` take an id from `model-catalog`; an
unknown one is refused with the list of valid ids. A model outside the catalog
goes in through `configure models` instead. See
[running your own model](custom-models.md).

An API key in the process arguments can be read by other users on the same
machine, so send it on stdin:

```sh
printf '%s\n' '{"cleanup_api_key":"sk-…"}' | omaflow configure models -
```

The window does the same.

## Evaluation

| Command | Effect |
|---|---|
| `cleanup < text` | Run the cleanup model over stdin and print the result. |
| `evaluate < JSON` | Run the production cleanup path over one JSON case (`transcript`, optional `clipboard`, `window`, `prompt`, `model`, `vocabulary`) and print the result. |
| `evaluate-todos < JSON` | Run the to-do take's path over one JSON case (`transcript`, optional `todo_prompt`, `model`, `today`, `now`) and print the tasks with their dates, times and reminders. Nothing is added to the list. |
| `transcribe-file FILE.wav` | Transcribe one complete 16 kHz mono 16-bit WAV with the configured speech backend. Used for regression checks and benchmarks. |

## Lifecycle and updates

| Command | Effect |
|---|---|
| `launch` | Start OmaFlow and open the window. If it cannot, it prints one sentence on stderr saying where to look. |
| `quit` | Unload the cleanup model and stop the daemon and speech server. |
| `restart-speech` | Start the managed speech server again after it stopped or failed. |
| `version` | Print the version compiled into the binary. `--json` also prints the plugin and target identities. `omaflow --version` does the same. |
| `check-update` | Check the official marketplace for an exact reviewed snapshot. A daily timer runs this. |

Normal updates use **Update and restart** in the OmaFlow window, under
Settings → Advanced → Updates and app. It shows the summary and changes bundled
with the reviewed release.
After `omarchy plugin update`, **Finish update** on the same page installs the
release that came with the OmaFlow folder.

## Setup

The installer is a script in the OmaFlow folder, not an `omaflow` command,
because it puts `omaflow` in place.

| Command | Effect |
|---|---|
| `./install` | Install missing packages with sudo, the bundled app after checking its size and SHA-256, its user services, the dictation key and the bar icon. Shows the plan and asks first; `--dry-run` only prints it. Safe to run again. |
| `./install --from-window` | What **Finish setup** and **Finish update** in the window run, in the `omaflow-setup` user unit, since the last step restarts the shell. The same steps without questions, sudo or preflight. A missing package stops it before anything changes. It writes its step and result to `$XDG_RUNTIME_DIR/omaflow-setup.json` (`state` is `running` with `step` `app`, `services` or `shell`, then `ok`, `failed` with `message` and `log`, or `needs-packages` with `command`; `from` is the version it started from) and its output to `omaflow-setup.log` beside it. |
| `./install --from-window --dry-run` | **Check again**: check the packages only, and change nothing. |

## Internal

Used by the services, the installer and the window; not needed from a shell.

| Command | Used by |
|---|---|
| `daemon` | The `omaflow` service. Runs the daemon in the foreground. |
| `serve-asr` | The `omaflow-asr` service. Runs the managed speech server. |
| `model-setup pending\|ready` | `link-local --no-models` / `--with-models`, to record whether a speech model is ready to use. |
| `config-shortcut JSON` | `tools/set_hotkey.py`, to write `[shortcut]` keys and consumed keys. |
| `meter-preview-start` / `meter-preview-stop` | The window, to stream the input level while it is open. |
| `journal day\|month\|search\|add\|edit\|delete\|restore …` | The window, to read and write the journal as JSON without the daemon. `journal add TEXT [DATE]` adds a typed entry: a later date makes a note, a past date adds to that day. |
| `journal move-folder FOLDER` | Journal settings, to move every day, sidecar and recording into a new folder and save it as the journal folder. Each file is copied, read back, and only then removed; if a day is already there, or a copy fails, nothing is moved. An original that cannot be removed after its copy is checked stays behind, and `left_behind` names it. |
| `todos move-folder FOLDER` | The to-dos folder setting, to move `To-dos.md` and OmaFlow's own files for it into a new folder and save it as the to-dos folder, the same way. If `To-dos.md` is already there, nothing is moved. |
| `update check` | Fetch the official marketplace catalog, save a verified offer and say what it found: an update ready to install, up to date, or why the check failed (exit status 1). Saved update progress that cannot be read is set aside when the OmaFlow folder is on the installed release, so dictation is no longer paused by it. |
| `update request` / `update later` | Queue the displayed offer (Update and restart), or put it off for one day (Later), and say so in one sentence. Either one that is refused prints why on stderr, as one sentence. |
| `update run` / `update reconcile` | Install a queued release or recover an interrupted update. A failed update sends a notification that opens Settings, Updates and app. `update request` on an update that still needs recovery starts that recovery, which puts the previous version back (Put back on the Updates and app page). |
| `update status` | Print the update in progress as JSON. One whose updater has stopped reads `interrupted`, with what to do next. |
| `health --expect-commit SHA` | Confirm that a versioned release binary matches the activated commit. |
