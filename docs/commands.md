# Command reference

`omaflow` is one binary. The daemon and the speech server run as user
services; most other commands talk to the running daemon over its socket and
return immediately. The Hyprland binding, the bar widget and the installer use
the same commands, so anything the panel does can be scripted.

## Recording

| Command | Effect |
|---|---|
| `press` | Start recording. A second press within one second locks it. |
| `release` | Finish a held recording and deliver the text. |
| `stop` | Finish a locked recording. `toggle` is an alias. |
| `cancel` | Discard the current recording without delivering anything. |
| `close` | Dismiss the result or error card. This is what Esc runs, so it does nothing while a to-do on the card is being edited. |
| `dismiss` | Dismiss the card even mid-edit. Its Esc button runs this. |
| `retry` | After a failed transcription, send the same recording again. The recording is kept in memory only until this, the card closing, or the next take. |
| `card-hold` / `card-edit` / `card-resume` | Stop a self-closing card's clock while it is pointed at, or while a to-do on it is edited (when Esc ends the edit, not the card); resume gives it its whole time again. |
| `journal-press` / `journal-release` | The journal shortcut, down and up: the same as `press` and `release`, but the words go to today's journal. |
| `journal-toggle [LATER_DATE]` | Start a hands-free journal entry, or save the one being taken. With a later date, a note to yourself for that day. |
| `todo-press` / `todo-release` | The to-do shortcut, down and up: the words become tasks on the to-do list. |
| `todo-toggle [JSON]` | Start a hands-free to-do take, or add the one being taken. With `{"list":"Infra","due":"2026-10-02"}`, the take goes to that list, and to-dos that name no date get that one. |
| `todo-list LIST` | Make LIST the current list, where new to-dos go; `""` is the Inbox. During a take, the take goes there too. |
| `todo-move LIST` | Move the to-dos the card announces to LIST, and make it current. |
| `todo-discard` | Throw away the journal entry or to-do take in progress. `journal-discard` is the same. |
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
| `todos list` | Every task, open and done, with its list and due date, the lists, the current list and the file's path. |
| `todos add TEXT [LIST [DUE]]` | Add open tasks to LIST, one per line of TEXT. A line ending in a deadline such as "by Friday" or "Friday at 3pm" gets that date and time; DUE is the date for lines without one. |
| `todos due I TEXT DATE [HH:MM]` | Set when a task is due, as `2026-10-02`, and at what time, or `""` for no date. |
| `todos reminders` | The open tasks whose time has come, each listed once. The shell shows them as notifications. |
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
| `history-edit ID TEXT` | Replace the saved text. |
| `history-delete ID` | Delete one entry. Undoable until the daemon exits. |
| `history-undo` | Restore the last deleted entry or cleared list. |
| `history-clear` | Delete every entry. Undoable until the daemon exits. |
| `erase-data` | Delete the history file and the training log. Not undoable. |

## Settings

| Command | Effect |
|---|---|
| `configure KEY JSON` | Write one setting to `~/.config/omaflow/config.toml` and apply it. This is what the panel calls. Pass `-` instead of JSON to read the value from one line of stdin. |
| `vocabulary-add TERM` / `vocabulary-remove TERM` | Edit the custom vocabulary. |
| `reload-config` | Re-read `config.toml` and regenerate the Hyprland shortcut. |
| `effective-config` | Print the merged configuration the daemon is using. |
| `config-init` | Fill in any missing keys in the personal config. |

## Microphone

| Command | Effect |
|---|---|
| `meter-gate DB` | Set the dBFS threshold for the meter's Voice detected indicator. It does not filter recorded audio. |
| `meter-gate-preview DB` | Try a threshold without saving it. |

## Models

| Command | Effect |
|---|---|
| `model-catalog` | Print the built-in catalog as JSON, with an `installed` and a `selected` flag per entry. |
| `model-select speech\|cleanup ID` | Switch to a catalog model whose weights are already on disk. |
| `model-install speech\|cleanup ID` | Download a catalog model, then switch to it. Reports progress to the panel. The first managed speech model also installs the NeMo-Speech runtime. |
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

The panel does the same.

## Evaluation

| Command | Effect |
|---|---|
| `cleanup < text` | Run the cleanup model over stdin and print the result. |
| `evaluate < JSON` | Run the production cleanup path over one JSON case (`transcript`, optional `clipboard`, `window`, `prompt`, `model`, `vocabulary`) and print the result. |
| `evaluate-todos < JSON` | Run the to-do take's path over one JSON case (`transcript`, optional `todo_prompt`, `model`, `today`, `now`) and print the tasks with their dates and times. Nothing is added to the list. |
| `transcribe-file FILE.wav` | Transcribe one complete 16 kHz mono 16-bit WAV with the configured speech backend. Used for regression checks and benchmarks. |

## Lifecycle and updates

| Command | Effect |
|---|---|
| `launch` | Open the panel. |
| `quit` | Unload the cleanup model and stop the daemon and speech server. |
| `version` | Print the version compiled into the binary. `--json` also prints the plugin and target identities. |
| `check-update` | Check the official marketplace for an exact reviewed snapshot. A daily timer runs this. |

Normal updates use **Update** in the OmaFlow panel. The panel shows the summary
and changes bundled with the reviewed release.

## Internal

Used by the services, the installer and the panel; not needed from a shell.

| Command | Used by |
|---|---|
| `daemon` | The `omaflow` service. Runs the daemon in the foreground. |
| `serve-asr` | The `omaflow-asr` service. Runs the managed speech server. |
| `model-setup pending\|ready` | `link-local --no-models` / `--with-models`, to record whether a speech model is ready to use. |
| `config-shortcut JSON` | `tools/set_hotkey.py`, to write `[shortcut]` keys and consumed keys. |
| `meter-preview-start` / `meter-preview-stop` | The panel, to stream the input level while it is open. |
| `update check` | Fetch the official marketplace catalog and save a verified offer. |
| `update request` / `update later` | Queue the displayed offer or defer its home card for one day. |
| `update run` / `update reconcile` | Install a queued release or recover an interrupted update. |
| `health --expect-commit SHA` | Confirm that a versioned release binary matches the activated commit. |
