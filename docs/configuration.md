# Configuration and removal

Application settings, vocabulary, model choices and the cleanup prompt share
one personal TOML file. The Settings page writes to the same file you can
edit by hand.

| Location | Purpose |
|---|---|
| `config/config.toml` in the OmaFlow folder | Bundled defaults, embedded when built |
| `~/.config/omaflow/config.toml` | Complete personal settings, including `[cleanup] custom_vocabulary` and `[behavior] models_configured` |
| `~/.config/omaflow/shortcut.lua` | Generated from `[shortcut]`; do not edit |
| `~/.config/hypr/omaflow-hotkey.lua` | Compatibility symlink to the generated shortcut |
| `~/.config/hypr/omaflow.lua` | Symlink to the Hyprland adapter `integrations/hyprland.lua` |
| `~/.config/systemd/user/omaflow*.service`, `omaflow-update-check.timer` | Symlinks to the units in `dist/` |
| `~/.local/bin/omaflow` | Symlink to the active versioned binary under `~/.local/lib/omaflow/current/` |
| `~/.local/state/omaflow/` | Private history and optional training examples |
| `~/.local/state/omaflow/update/` | Owner-only update offers, deferrals, receipts and recovery journal |
| `~/.local/lib/omaflow/` | Versioned bundled binaries, the atomic `current` link and trusted update runner |
| `~/.local/state/omaflow-install/receipt.json` | Records the speech runtime when OmaFlow installed it, so `./uninstall` knows it may delete it |
| `$XDG_RUNTIME_DIR/omaflow.sock` and `omaflow-state.json` | Daemon communication and UI state |
| `$XDG_RUNTIME_DIR/duck-restore` | The output volume replaced by a duck, so a crash cannot leave your speakers turned down |
| `~/.local/lib/nemo-speech/` | The managed speech runtime, installed by `scripts/install-nemo.sh` with the first speech model you download: the CUDA build when an NVIDIA driver is loaded, the CPU build otherwise. `.nemo-speech-install` in it names the build. Downloading a speech model, or running the script again, switches builds if the driver came or went |
| `~/.cache/nemo-speech/models/` | Managed speech weights |
| Ollama server storage | Cleanup weights, potentially shared with other applications |

To change a setting by hand, edit the personal TOML and save it. Every
setting is in the file, and the Omarchy shell applies a saved change within a
second, the same way Settings does, shortcuts and journal folder
included. A mistake in the file shows as a notification that names it, and
the previous settings stay in use. Without the shell running, apply it with
`omaflow reload-config`. `omaflow effective-config` prints the merged result. `omaflow config-init` fills every missing key, including the
cleanup prompt. It updates exact copies of earlier bundled prompts and
preserves prompts you edited yourself. Installation and relinking run it.

## Keys and defaults

Some of these have a control in the window; the note says where. All of them are
settable in the TOML.

| Key | Default | Effect |
|---|---:|---|
| `[cleanup] enabled` | `false` | Medium cleanup: sends the transcript to the configured cleanup server. Settings → Basics → Cleanup. |
| `[cleanup] light` | `false` | With `enabled` off, still drop fillers such as "um" and stutters such as "the the". No model runs. Settings → Basics → Cleanup, as **Light**. |
| `[cleanup] engine` | `"ollama"` | Cleanup protocol: `ollama` for `/api/chat`, or `openai` for `/v1/chat/completions`. |
| `[behavior] models_configured` | `false` | Whether a speech model is ready to use. Selecting or downloading a catalog model sets it from the weights actually on disk. |
| `[behavior] duck_audio_percent` | `70` | How far the default audio output is turned down while a recording is active, 0 to 100. The level found before the recording comes back on release. Settings → Advanced → Audio. |
| `[behavior] keep_models_loaded` | `true` | Keep the models loaded between dictations. `false` unloads the cleanup model and stops the managed speech server after five minutes without dictation; the next dictation loads them first. External servers are not touched. Settings → Advanced → Models. |
| `[behavior] history_limit` | `30` | Entries kept, up to 1000; `0` saves nothing. Settings → Privacy. |
| `[behavior] keep_dictation_audio` | `false` | Keep each saved dictation's recording in `~/.local/state/omaflow/audio/` so History can play it back. A recording is deleted with its dictation, and switching this off deletes all kept dictation audio. Settings → Privacy. |
| `[behavior] training_log_enabled` | `false` | Append raw ASR and cleaned output to an owner-only JSONL file under `~/.local/state/omaflow/`. Settings → Privacy. |
| `[behavior] meter_gate_auto` | `true` | Place the meter's Voice detected threshold automatically: OmaFlow follows the room's noise while the microphone is open and puts the threshold 12 dB above it, from -70 to -35 dBFS. `false` uses `meter_gate_db`. The threshold only decides when the card says it hears you; it never removes recorded audio. Settings → Advanced → Audio, as **Set the threshold automatically**. |
| `[behavior] meter_gate_db` | `-60` | Manual threshold in dBFS for the meter's Voice detected indicator, used when `meter_gate_auto` is off. It only decides when the card says it hears you; it never removes recorded audio. Settings → Advanced → Audio. |
| `[behavior] paste_mode` | `"auto"` | `auto`, `ctrl-v`, `shift-insert`, `clipboard` or `custom`. Auto uses Shift+Insert in terminal-tagged windows and Ctrl+V elsewhere. Settings → Basics. |
| `[behavior] paste_shortcut` | `{ modifiers = ["ctrl"], key = "V" }` | Chord used by `custom`. Choose one to four distinct `ctrl`, `shift`, `alt` or `super` modifiers and one XKB key name. Settings → Advanced → Hotkeys validates and saves the mode and chord together. |
| `[behavior] max_recording_seconds` | `1200` | A recording stops itself here. |
| `[backend] api_key`, `[cleanup] api_key` | empty | Sent as an `Authorization: Bearer` header to a speech or cleanup server that wants one, and only when set. Never published to the window or `effective-config`. Settings → Advanced → Your own model and Settings → Advanced → Cleanup, as **API key, optional**. See [running your own model](custom-models.md#if-your-server-needs-a-key). |
| `[cleanup] use_window_context` | `true` | Put the focused window's class and title into the cleanup prompt so tone follows the app. |
| `[cleanup] use_clipboard_context` | `false` | Put clipboard text into the cleanup prompt so copied names are spelled the same way. Off because clipboards hold passwords. |
| `[journal] folder` | `"~/Documents/Journal"` | Where the journal keeps one Markdown file per day. Recordings go in a hidden `.recordings` folder beside them. Journal → ⋯ → Journal settings, which offers to move your days, their sidecars and recordings into the new folder (`omaflow journal move-folder FOLDER`); it stops without moving anything if a day is already there. Editing this line by hand moves nothing. The daemon is sandboxed, so choosing a folder there also creates it and opens it to the daemon (`~/.config/systemd/user/omaflow.service.d/journal-folder.conf`); after editing this line by hand, run `tools/journal_folder.py`. |
| `[journal] cleanup` | `"light"` | `off` keeps every word as spoken, `light` drops fillers, `medium` also runs the cleanup model when `[cleanup] enabled` is on. |
| `[journal] keep_recordings` | `true` | Keep each spoken entry's recording so it can be played back. Off keeps only the words and the waveform outline, and deletes recordings already kept. |
| `[journal] empty_day_question` | `false` | Show one short question on a day with no entries yet. |
| `[todos] folder` | `"~/Documents/To-dos"` | Where the to-do list, `To-dos.md`, lives. To-dos → ⋯ → Reminders and folder → Change, which offers to move the list there (`omaflow todos move-folder FOLDER`). Opened to the sandboxed daemon the same way as the journal folder, by the same drop-in. |
| `[todos] prompt` | the bundled to-do prompt | The cleanup model's prompt for a to-do take, in place of `[cleanup] system_prompt`: one task per line, in your own words, with each task's timing at its end. Only used when cleanup is on; empty uses the dictation prompt. Check a change with `tools/todo_bench.py --prompt FILE`. |
| `[todos] remind_before` | `0` | Minutes before a to-do's time that its reminder comes: 0 (at the time), 5, 15, 30 or 60. To-dos → ⋯ → Reminders and folder. Each to-do can change its own in its date menu. |
| `[cleanup] num_ctx` | `16384` | Context window for cleanup. Prompt, transcript, spelling context and answer must fit. OmaFlow estimates token usage for each request and removes clipboard then window context before rejecting it. Capacity and memory use depend on content, model and runtime; there is no fixed duration guarantee. |

Changing defaults never erases files already written; use Settings → Privacy →
Delete saved dictations to delete history and training data. Dictation audio is
processed in memory and dropped after transcription unless you switch on
`keep_dictation_audio`. Journal recordings are kept in your journal folder, and
deleting an entry deletes its recording. The window keeps temporary text in the runtime directory, and the
clipboard and destination applications have their own retention.

## Hotkey

Edit `[shortcut] keys` and `consumed` in the TOML and save. The reload
validates XKB names and conflicts, regenerates the Lua file and reloads
Hyprland; when nothing about the shortcuts changed, it leaves Hyprland alone. Settings and `./install --hotkey`
write the same keys and roll back if the reload fails. The adapter is
registered by `require("omaflow")` in `~/.config/hypr/bindings.lua`, which
`./install` appends once, after backing the file up.

The other shortcuts are ordinary Hyprland bindings, written as modifiers then
one key. Settings → Advanced → Hotkeys changes them and refuses keys Omarchy
already uses; an empty value turns one off.

| Setting | Default | Does |
|---|---|---|
| `[shortcut] window` | `"SUPER + SHIFT + V"` | Opens the OmaFlow window where you left it, or closes it |
| `[shortcut] journal` | `""` | A journal entry from any app, like the dictation key: hold it while you talk, or double-tap to keep going and press again to save |
| `[shortcut] open_journal` | `""` | Opens the OmaFlow window on the journal, or closes it when the journal is showing |
| `[shortcut] todo` | `""` | Adds to-dos from any app, held or double-tapped like the journal shortcut |
| `[shortcut] open_todos` | `""` | Opens the OmaFlow window on the to-do list, or closes it when the list is showing |

The adapter also binds **Esc** to `omaflow close`, which dismisses a finished
card and never ends a take. A card you can act on shows its Esc button inside a
ring that fills as its time runs out, and pointing at the card stops the
clock; a passing "Pasted" or "Nothing heard" just goes. Every OmaFlow shortcut appears in Omarchy's
**Super+K** list; dictation is listed through its reserved key, so a chord
without one, such as plain F9, is not.

Personal settings are a real file, not a symlink, so removing or updating the
OmaFlow folder does not erase them.

The CLI respects `OMAFLOW_CONFIG` for a custom TOML path, plus
`XDG_CONFIG_HOME` and `XDG_STATE_HOME`. The supplied service unit lists the
standard home paths in its write permissions; a nonstandard deployment must
also adjust its service environment and writable paths.

## Removing OmaFlow

Run `./uninstall` from the OmaFlow folder in a working Omarchy session. It lists
what it will remove and asks first; `--yes` skips the question for scripts.
Then it disables the bar widget, stops and removes the user units, takes
`require("omaflow")` back out of `bindings.lua`, and erases the settings,
history, installation backups and the OmaFlow folder itself.

An `omaflow-setup.service` link left by an older version is removed too; the
unit itself no longer ships.

It also removes what the receipt at `~/.local/state/omaflow-install/receipt.json`
records, which is the NeMo-Speech runtime when OmaFlow created that directory.
An older receipt can additionally list weights and cleanup models the installer
pulled back when it installed models; those are removed as well, the cleanup
ones with `ollama rm`. Models you download in the OmaFlow window are recorded
there too, so `./uninstall` removes them from `~/.cache/nemo-speech/models` and
from Ollama's storage. OmaFlow never installs or removes Ollama itself. Your
journal and to-dos folders stay.

Anything that was already present stays, as do your own linked model files and
system tools such as Python, Git and GPU drivers. If a link OmaFlow expects to
own points somewhere else, or `bindings.lua` has a hand-written `require`
expression, `./uninstall` stops and says so rather than deleting a file it did
not create.
