# Contributing

## Setup

Install OmaFlow once as a user, then point it at your checkout:

```bash
git clone https://github.com/entroit/omaflow.git
cd omaflow
./install
./link-local
```

`link-local` builds the daemon, links `~/.local/bin/omaflow`, the systemd
units, the Hyprland adapter and the Omarchy plugin directory at your checkout,
then restarts the service, reloads Hyprland and restarts the shell. Saving a
`.qml` file reloads the panel in place; changing Rust needs another
`./link-local`.

## Layout

| Path | Owns |
|---|---|
| `src/main.rs` | The daemon: socket, session handling, delivery, history, published state. |
| `src/state.rs` | The recording state machine (hold, double-tap lock, limits). |
| `src/cleanup.rs` | Cleanup model requests and the output safety guards. |
| `src/vocabulary.rs` | Exact custom-vocabulary normalization. |
| `src/backend.rs` | Microphone capture, speech server client and the managed NeMo server. |
| `src/update.rs` | Version checks and the update/rebuild launcher. |
| `src/config.rs` | `config.toml` schema, defaults and atomic edits. |
| `src/cli.rs` | Every `omaflow` command. |
| `OmaFlow.qml` | The bar widget, panel and recording overlay. |
| `integrations/hyprland.lua` | Hotkey adapter; reads the generated shortcut file. |
| `config/config.toml` | Bundled defaults and the cleanup prompt, embedded in the binary. |
| `tools/` | Evaluation gates and regression tests. |

Rust owns state, audio and delivery. QML only renders the state file the
daemon publishes and calls commands back. Lua only maps key state to
`omaflow press` and `omaflow release`.

## Before you push

```bash
scripts/check-local.sh
```

That runs `cargo fmt --check`, clippy with warnings denied, the Rust tests,
a release build, the Python and Lua regression suites, shellcheck, `bash -n`
and `git diff --check`. `scripts/check-local.sh --full` adds the model
evaluation gates, the QML smoke test and `omarchy plugin validate .`, which
need the models installed. There is no hosted
CI; the checks run on your machine.

## Changes that need extra care

- **The cleanup prompt** in `config/config.toml`. Run the four gates below and
  include the numbers in the commit message.
- **The state file contract** between daemon and panel. Bump `STATE_VERSION`
  in `src/update.rs` and the `supportedState` check in `OmaFlow.qml` together;
  the panel refuses a mismatched daemon rather than rendering it wrong.
- **Defaults.** They are embedded in the binary and only fill missing keys, so
  a changed default reaches new installs, not existing personal configs.

## Model gates

After a prompt or model change, build the release binary and run:

```bash
tools/cleanup_bench.py          # 32 cases, release gate
tools/cleanup_probe.py          # 88 cases
tools/cleanup_generalization.py # 21 cases
tools/cleanup_itn_gate.py       # 180 spoken-to-written pairs
tools/dictation_modes_gate.py   # natural, verbatim, vocabulary, obsolete keys
```

The first four take an optional prompt file (`-` keeps the installed one) and
honor `OMAFLOW_BINARY`; the modes gate always uses `target/release/omaflow`.
All exit nonzero on failure. They go through `omaflow evaluate`, so a guarded
raw fallback is counted separately from a successful cleanup. Set
`OMAFLOW_EVAL_JSONL=path` to keep every input, candidate and output. What the
gates measure and the current results are in
[why these models](docs/why-these-models.md).

## Live segment rules

`[backend] live_segment_tiers` changes where a recording is cut for live
transcription. Before enabling a rule by default, record continuous fast
speech, quiet speech, a list of numbers and names, and a self-correction that
spans a cut, each 60 to 90 s, as 16 kHz mono WAV under `tools/data/local/`
(ignored by git) with a checked transcript next to each, then run:

```bash
tools/segment_compare.py tools/data/local/fast.wav tools/data/local/fast.txt
```

It reports the word error rate of the whole-file and segmented transcripts
against the reference, the words either side of each cut, peak speech-server
VRAM and wall time. A rule is a candidate for the default only if its WER
matches the whole-file result on every recording; passing them supports more
testing, not a guarantee.

## Desktop checks

```bash
python3 tools/ui_smoke.py --output /tmp/omaflow-ui-review   # 19 rendered views
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
