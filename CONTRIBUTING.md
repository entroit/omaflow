# Contributing

## Setup

Install OmaFlow from your own checkout; the desktop then points at it.

```bash
git clone https://github.com/entroit/omaflow.git
cd omaflow
./link-local
```

`./link-local` builds the daemon from the contributor checkout, writes the hotkey,
registers the Hyprland adapter and links that development build directly. It downloads no
models: you pick a speech model in Settings → Advanced → Models afterwards, and the first
one you download installs the NeMo-Speech runtime with it.

`link-local` builds the daemon, links `~/.local/bin/omaflow`, the systemd
units, the Hyprland adapter and the Omarchy plugin directory at your checkout,
then restarts the service, reloads Hyprland and restarts the shell. Saving a
`.qml` file reloads the window in place; changing Rust needs another
`./link-local`. It leaves the model state alone unless you pass `--no-models`
or `--with-models`, because a relink is not a statement about which weights
exist.

## Layout

| Path | Owns |
|---|---|
| `crates/omaflow-core/` | Everything without a desktop: `config.rs` (schema, defaults, atomic edits), `state.rs` (the recording state machine), `vocabulary.rs`, `history.rs`, `journal.rs` (Markdown days, recordings, search, light cleanup) and `date.rs`. |
| `crates/omaflow-platform/` | The desktop adapters: `desktop.rs` (clipboard, focused window and paste through Hyprland), `ducking.rs` (`wpctl`), `sound.rs` (journal playback through `pw-cat`), `clock.rs` and `process.rs` (bounded child processes, the API key's owner-only curl config). Another platform replaces this crate. |
| `src/main.rs` | The daemon: socket, session handling, delivery, journal takes, published state. |
| `src/backend.rs` | Microphone capture, speech server client and the managed NeMo server. |
| `src/cleanup.rs` | Cleanup model requests and transport-completeness checks. |
| `src/catalog.rs` | The built-in model catalog, the downloader and what selecting an entry writes. |
| `src/update.rs`, `src/update/` | Marketplace verification, durable update state, activation and recovery. |
| `src/cli.rs`, `src/journal_cli.rs` | Every `omaflow` command; `omaflow journal …` reads and edits the journal for the window. |
| `ui/` | The whole interface as plain Qt Quick: `App.qml` (state and actions), `Theme.qml` (colours from the Omarchy theme, fonts, shapes), the History, Journal and Settings screens and the overlay card. It never imports Quickshell, so another host can run it. Every file must be listed in `ui/qmldir`. |
| `hosts/omarchy/` | The Omarchy shell plugin: bar icon, window and overlay, and the only QML that imports Quickshell. |
| `tools/preview/` | Renders any screen of `ui/` with sample data on plain Qt: `tools/preview/render.sh OUT [MODE…]`. |
| `scripts/` | Preflight, the release installer, the status file of the window's Finish setup, the NeMo-Speech runtime installer and the local check runner. |
| `dist/` | The bundled binary, release manifest, user units and desktop entry. |
| `integrations/hyprland.lua` | Hotkey adapter; reads the generated shortcut file. |
| `config/config.toml` | Bundled defaults and the cleanup prompt, embedded in the binary. |
| `tools/` | Evaluation gates and regression tests. |

Rust owns state, audio, delivery and the journal files. QML only renders the
state file the daemon publishes and calls commands back. Lua only maps key state to
`omaflow press` and `omaflow release`.

## Before you push

```bash
scripts/check-local.sh
```

That runs `cargo fmt --check`, clippy with warnings denied, the Rust tests,
a release build, the Python and Lua regression suites, shellcheck, `bash -n`
and `git diff --check`. `scripts/check-local.sh --full` adds the model
evaluation gates, the QML smoke test and `omarchy plugin validate .`; those
need the cleanup model downloaded and an installed Omarchy shell. Release
verification runs on the maintainer machine; this repository does not use
GitHub Actions.

## Changes that need extra care

- **The cleanup prompt** in `config/config.toml`. Run the model gates below
  locally. Keep research results and model comparisons out of the repository.
- **The state file contract** between daemon and panel. Additive fields must
  have panel defaults and keep `STATE_VERSION`, so a cached panel and a newly
  restarted daemon remain compatible while Omarchy reloads the shell. Bump the
  version in `src/update.rs` and `ui/App.qml` together only for a genuinely
  breaking change, and provide an explicit staged migration for that update.
- **Defaults.** They are embedded in the binary and only fill missing keys, so
  a changed default reaches new installs, not existing personal configs.
- **Release binary.** Run `scripts/package-release` after the source and version
  are final, then run `scripts/package-release --verify`. Commit
  `dist/release.json` and the binary together. The script records the size and
  SHA-256 digest that both the installer and updater require.

## Model gates

After a prompt or model change, build the release binary and run:

```bash
tools/cleanup_bench.py          # 32 cases, release gate
tools/cleanup_probe.py          # 88 cases
tools/cleanup_generalization.py # 21 cases
tools/cleanup_itn_gate.py       # 180 spoken-to-written pairs
tools/dictation_modes_gate.py   # natural, verbatim, vocabulary, obsolete keys
tools/todo_bench.py             # 80 spoken to-do takes: splitting, cleanup, dates, times, reminders
```

The to-do bench runs the to-do prompt, not the dictation prompt: a spoken take
through `omaflow evaluate-todos`, the task splitter and the date reader, on a
fixed day. `--prompt FILE` tries a candidate and `--repeat N` runs each case N
times. The last cases were written after the prompt was tuned, to check that
it generalizes.

The first four take an optional prompt file (`-` keeps the installed one) and
honor `OMAFLOW_BINARY`; the modes gate always uses `target/release/omaflow`.
All exit nonzero on failure. They go through `omaflow evaluate`, so a raw
fallback is counted separately from a successful cleanup. Set
`OMAFLOW_EVAL_JSONL=path` to keep every input, candidate and output. What the
gates measure is documented in each script. Store result files outside the
repository.

## Desktop checks

```bash
python3 tools/ui_smoke.py --output /tmp/omaflow-ui-review   # 26 rendered views
omarchy plugin validate .
hyprctl configerrors
systemctl --user is-active omaflow.service omaflow-asr.service
scripts/preflight.sh
```

The render check catches load errors and layout regressions. It does not prove
physical key behavior, paste acceptance in a given application or microphone
quality; those need the real desktop.

## Commits

One change per commit, with a subject that says what changed and a body that
says why.
