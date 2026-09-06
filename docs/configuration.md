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
| `~/.local/state/omaflow/` | Private history and optional training examples |
| `$XDG_RUNTIME_DIR/omaflow.sock` and `omaflow-state.json` | Daemon communication and UI state |
| `~/.cache/nemo-speech/` | Managed speech model cache |
| Ollama server storage | Cleanup weights, potentially shared with other applications |

To change a setting by hand, edit the personal TOML, then run
`omaflow reload-config` while idle. `omaflow effective-config` prints the
merged result. `omaflow config-init` fills every missing key, including the
cleanup prompt, without changing values already chosen; installation and
updates run it, so personal values survive changes to the bundled defaults.

Keys the panel does not expose, all settable in the TOML:

| Key | Default | Effect |
|---|---:|---|
| `[cleanup] enabled` | `true` | `false` delivers raw recognition. |
| `[cleanup] guard_retry` | `true` | Retry once with numbers locked when a safety guard rejects the cleanup. |
| `[cleanup] use_window_context` | `true` | Put the focused window's class and title into the cleanup prompt so tone follows the app. |
| `[cleanup] use_clipboard_context` | `false` | Put clipboard text into the cleanup prompt so copied names are spelled the same way. Off because clipboards hold passwords. |
| `[backend] live_segment_seconds` | `20` | Minimum audio before a pause can close a live transcription segment; `0` disables. |
| `[backend] live_segment_tiers` | `[]` | Experimental. Extra rules such as `[{ seconds = 35, pause_ms = 400 }]`: once a segment is that long, that shorter pause closes it. Judge a rule with `tools/segment_compare.py` first. |
| `[behavior] keep_models_loaded` | `true` | Keep the models loaded between dictations. `false` unloads the cleanup model and stops the managed speech server after five minutes without dictation; the next dictation loads them first (about 2.5 s with the default models on the reference machine). External servers are not touched. Settings → Memory. |
| `[cleanup] num_ctx` | `16384` | Context window for cleanup. Prompt, transcript, spelling context and answer must fit. OmaFlow estimates token usage for each request, including retries, and removes clipboard then window context before rejecting it. Capacity and memory use depend on content, model and runtime; there is no fixed duration guarantee. |
| `[behavior] history_limit` | `30` | Entries kept, up to 1000; `0` saves nothing. |
| `[behavior] training_log_enabled` | `false` | Append raw ASR and cleaned output to an owner-only JSONL file under `~/.local/state/omaflow/`. |
| `[behavior] reduced_motion` | `false` | Disable panel animation. |

Changing defaults never erases files already written; use Settings → Erase
saved dictations to delete history and training data. Audio is processed in
memory. The panel keeps temporary text in the runtime directory, and the
clipboard and destination applications have their own retention.

Edit `[shortcut] keys` and `consumed` in the TOML, then run
`omaflow reload-config`. It validates XKB names and conflicts, regenerates the
Lua file and reloads Hyprland. The Settings panel and `./install --hotkey`
write the same keys and roll back if the reload fails. The adapter is
registered by `require("omaflow")` in `~/.config/hypr/bindings.lua`.

Personal settings are a real file, not a symlink, so removing or updating the
checkout does not erase them.

The CLI respects `OMAFLOW_CONFIG` for a custom TOML path, plus
`XDG_CONFIG_HOME` and `XDG_STATE_HOME`. The supplied service unit lists the
standard home paths in its write permissions; a nonstandard deployment must
also adjust its service environment and writable paths.

## Removing OmaFlow

Run `./uninstall` from the checkout in a working Omarchy session. It removes
OmaFlow's desktop integration, services, settings, history, installation backups
and the checkout itself, plus models and runtimes recorded as installed by
OmaFlow.

Models and runtimes that were already present stay, as do your own linked model
files and system tools such as Python, Git and GPU drivers.
