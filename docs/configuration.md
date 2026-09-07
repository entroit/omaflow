# Configuration and removal

Application settings, vocabulary, model choices and the cleanup prompt share
one personal TOML file. The Settings panel writes to the same file you can
edit by hand.

| Location | Purpose |
|---|---|
| `config/config.toml` in the checkout | Bundled defaults, embedded when built |
| `~/.config/omaflow/config.toml` | Complete personal settings, including `[cleanup] custom_vocabulary` and `[behavior] models_configured` |
| `~/.config/omaflow/shortcut.lua` | Generated from `[shortcut]`; do not edit |
| `~/.config/hypr/omaflow-hotkey.lua` | Compatibility symlink to the generated shortcut |
| `~/.config/hypr/omaflow.lua` | Symlink to the Hyprland adapter `integrations/hyprland.lua` |
| `~/.config/systemd/user/omaflow*.service`, `omaflow-update-check.timer` | Symlinks to the units in `dist/` |
| `~/.local/bin/omaflow` | Symlink to the built binary |
| `~/.local/state/omaflow/` | Private history and optional training examples |
| `~/.local/state/omaflow-install/receipt.json` | Records the speech runtime when OmaFlow installed it, so `./uninstall` knows it may delete it |
| `$XDG_RUNTIME_DIR/omaflow.sock` and `omaflow-state.json` | Daemon communication and UI state |
| `$XDG_RUNTIME_DIR/duck-restore` | The output volume replaced by a duck, so a crash cannot leave your speakers turned down |
| `~/.local/lib/nemo-speech/` | The managed speech runtime, installed by `scripts/install-nemo.sh` with the first speech model you download |
| `~/.cache/nemo-speech/models/` | Managed speech weights |
| Ollama server storage | Cleanup weights, potentially shared with other applications |

To change a setting by hand, edit the personal TOML, then run
`omaflow reload-config` while idle. `omaflow effective-config` prints the
merged result. `omaflow config-init` fills every missing key, including the
cleanup prompt, without changing values already chosen; installation and
updates run it, so personal values survive changes to the bundled defaults.

## Keys and defaults

Some of these have a control in the panel; the note says where. All of them are
settable in the TOML.

| Key | Default | Effect |
|---|---:|---|
| `[cleanup] enabled` | `false` | Off pastes exactly what the speech model recognized. On needs Ollama and a cleanup model. Settings → Cleanup. |
| `[behavior] models_configured` | `false` | Whether a speech model is ready to use. Selecting or downloading a catalog model sets it from the weights actually on disk. |
| `[behavior] duck_audio_percent` | `70` | How far the default audio output is turned down while a recording is active, 0 to 100. The level found before the recording comes back on release. Settings → Audio. |
| `[behavior] keep_models_loaded` | `true` | Keep the models loaded between dictations. `false` unloads the cleanup model and stops the managed speech server after five minutes without dictation; the next dictation loads them first. External servers are not touched. Settings → General. |
| `[behavior] history_limit` | `30` | Entries kept, up to 1000; `0` saves nothing. Settings → Privacy. |
| `[behavior] training_log_enabled` | `false` | Append raw ASR and cleaned output to an owner-only JSONL file under `~/.local/state/omaflow/`. Settings → Privacy. |
| `[behavior] meter_gate_db` | `-60` | Voice threshold in dBFS. Below it the room counts as silence. Settings → Audio. |
| `[behavior] max_recording_seconds` | `1200` | A recording stops itself here. |
| `[behavior] reduced_motion` | `false` | Disable panel animation. |
| `[backend] api_key`, `[cleanup] api_key` | empty | Sent as an `Authorization: Bearer` header to a speech or cleanup server that wants one, and only when set. Never published to the panel or `effective-config`. Settings → Speech and Settings → Cleanup, as **API key (optional)**. See [running your own model](custom-models.md#if-your-server-needs-a-key). |
| `[cleanup] guard_retry` | `true` | Retry once with numbers locked when a safety guard rejects the cleanup. |
| `[cleanup] use_window_context` | `true` | Put the focused window's class and title into the cleanup prompt so tone follows the app. |
| `[cleanup] use_clipboard_context` | `false` | Put clipboard text into the cleanup prompt so copied names are spelled the same way. Off because clipboards hold passwords. |
| `[cleanup] num_ctx` | `16384` | Context window for cleanup. Prompt, transcript, spelling context and answer must fit. OmaFlow estimates token usage for each request, including retries, and removes clipboard then window context before rejecting it. Capacity and memory use depend on content, model and runtime; there is no fixed duration guarantee. |
| `[backend] live_segment_seconds` | `20` | Minimum audio before a pause can close a live transcription segment; `0` disables. |
| `[backend] live_segment_tiers` | `[]` | Experimental. Extra rules such as `[{ seconds = 35, pause_ms = 400 }]`: once a segment is that long, that shorter pause closes it. Judge a rule with `tools/segment_compare.py` first. |

Changing defaults never erases files already written; use Settings → Privacy →
Erase saved dictations to delete history and training data. Audio is processed
in memory. The panel keeps temporary text in the runtime directory, and the
clipboard and destination applications have their own retention.

## Hotkey

Edit `[shortcut] keys` and `consumed` in the TOML, then run
`omaflow reload-config`. It validates XKB names and conflicts, regenerates the
Lua file and reloads Hyprland. The Settings panel and `./install --hotkey`
write the same keys and roll back if the reload fails. The adapter is
registered by `require("omaflow")` in `~/.config/hypr/bindings.lua`, which
`./install` appends once, after backing the file up.

Personal settings are a real file, not a symlink, so removing or updating the
checkout does not erase them.

The CLI respects `OMAFLOW_CONFIG` for a custom TOML path, plus
`XDG_CONFIG_HOME` and `XDG_STATE_HOME`. The supplied service unit lists the
standard home paths in its write permissions; a nonstandard deployment must
also adjust its service environment and writable paths.

## Removing OmaFlow

Run `./uninstall` from the checkout in a working Omarchy session. It disables
the bar widget, stops and removes the user units, takes `require("omaflow")`
back out of `bindings.lua`, and erases the settings, history, installation
backups and the checkout itself.

An `omaflow-setup.service` link left by an older version is removed too; the
unit itself no longer ships.

It also removes what the receipt at `~/.local/state/omaflow-install/receipt.json`
records, which is the NeMo-Speech runtime when OmaFlow created that directory.
An older receipt can additionally list weights and cleanup models the installer
pulled back when it installed models; those are removed as well, the cleanup
ones with `ollama rm`. Models you downloaded yourself from the panel are not
recorded, so they stay in `~/.cache/nemo-speech/models` and in Ollama's storage
for you to delete. OmaFlow never installs or removes Ollama itself.

Anything that was already present stays, as do your own linked model files and
system tools such as Python, Git and GPU drivers. If a link OmaFlow expects to
own points somewhere else, or `bindings.lua` has a hand-written `require`
expression, `./uninstall` stops and says so rather than deleting a file it did
not create.
