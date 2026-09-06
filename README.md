<p align="center">
  <img src="assets/icon.svg" width="64" height="64" alt="OmaFlow">
</p>

# OmaFlow

A Wispr Flow alternative for Omarchy. Hold a hotkey, speak, and release to
paste the cleaned text into your app. Speech recognition and cleanup run locally
with the default models.

<p align="center">
  <img src="assets/recording.png" width="400" alt="OmaFlow recording panel with a waveform, lock indicator, timer and Stop button">
</p>

## Try it

You need **Omarchy 4+**, Python 3.11+, and a working microphone. For the default
models, allow roughly **6.3 GB of free GPU memory** on an NVIDIA GPU with CUDA
and **10.4 GB of downloads**. Memory use varies with recording length and runtime.

```bash
omarchy plugin add https://github.com/entroit/omaflow.git
cd ~/.config/omarchy/plugins/entroit.omaflow
./install --hotkey F13
```

Replace `F13` with your preferred key. The installer shows its plan, asks for
confirmation, then installs dependencies and models and enables the widget.
Adding the plugin alone does not install the app.

Already have your own models? Use `./install --no-models`, then open
**Settings → Models → Configure models**. Prepare your models outside the app,
save their names or server addresses, and enable dictation.
[Model setup →](docs/models.md)

## Speak, then keep typing

| What you want | What to do |
|---|---|
| Dictate a sentence | Hold your hotkey, speak, then release. |
| Talk hands-free | Double-tap to lock. Press again or click **Stop** to finish. |
| Copy without pasting | Choose **Copy** delivery in Settings. |
| Check or correct a result | Open it in History to edit, compare the original, or copy again. |

Cleanup removes fillers, handles self-corrections, and formats spoken lists
and punctuation. Add names and technical terms to **Custom vocabulary** in
Settings. Turn cleanup off when you want the recognized wording.

<p align="center">
  <img src="assets/history-english.png" width="460" alt="OmaFlow History with English work messages and a Settings tab">
  <br>
  <sub>Current interface, shown with sample text.</sub>
</p>

## Make it yours

- **Models:** choose your speech and cleanup models. Defaults are Parakeet TDT
  0.6B v3 and Gemma 4 E4B. Other models have their own hardware requirements.
- **Memory:** turn off **Keep models loaded** to release them after five idle
  minutes. The next dictation takes longer while they load.
- **History:** keep recent dictations or set retention to zero. Training logging
  is off by default. OmaFlow processes microphone audio in memory.
- **One config:** all settings live in `~/.config/omaflow/config.toml`, including
  shortcuts, vocabulary and the cleanup prompt. You or an agent can edit it.

Recognition and cleanup can make mistakes, especially with names and numbers.
Long dictations can take several seconds to finish. If cleanup cannot complete,
OmaFlow keeps the recognized text and shows a warning. External model servers
receive the audio or text you send to them.

## Update or remove

Use **Update** in Settings when an update is available.

Run `./uninstall` for a clean removal, including settings, history, the
checkout, and models and runtimes installed by OmaFlow.
[Removal details →](docs/configuration.md#removing-omaflow)

## More

[Configuration](docs/configuration.md) · [Model setup](docs/models.md) ·
[Model benchmarks](docs/why-these-models.md) · [Commands for scripts and agents](docs/commands.md) ·
[Contributing](CONTRIBUTING.md)
