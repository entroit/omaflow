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
| `close` | Dismiss the result or error card. |

## Delivery

| Command | Effect |
|---|---|
| `copy` | Copy the last result to the clipboard without pasting. |
| `paste-last` | Paste the most recent dictation into the focused window again. |
| `paste-mode auto\|ctrl-v\|shift-insert\|clipboard\|custom` | Choose how text reaches the focused window. `clipboard` copies only; `custom` uses the chord saved in Settings → General. |

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
| `configure KEY JSON` | Write one setting to `~/.config/omaflow/config.toml` and apply it. This is what the panel calls. |
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

## Evaluation

| Command | Effect |
|---|---|
| `cleanup < text` | Run the cleanup model over stdin and print the result. |
| `evaluate < JSON` | Run the production cleanup path over one JSON case (`transcript`, optional `clipboard`, `window`, `prompt`, `model`, `vocabulary`) and print the result. |
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
