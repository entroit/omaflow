<p align="center">
  <img src="assets/icon.svg" width="64" height="64" alt="OmaFlow">
</p>

# OmaFlow

**The free, open-source Wispr Flow for Omarchy.** Hold a key, speak, release.
Your words appear where your cursor is, in any app.

<!-- MEDIA 1 — HERO (missing, highest priority)
     10-12s MP4, native GitHub player: cursor in a real app -> hold the key
     (keypress overlay via showmethekey) -> speak -> release -> text lands.
       wl-screenrec -g "$(slurp)" -f raw.mp4
       ffmpeg -i raw.mp4 -vf scale=1280:-2 -c:v libx264 -crf 23 -preset slow \
              -movflags +faststart -an hero.mp4
     Drag hero.mp4 into the README editor on github.com once, paste the
     resulting user-attachments URL here alone on its own line. -->

<p align="center">
  <img src="assets/recording.png" width="400" alt="OmaFlow recording overlay: Listening, a lock indicator, a timer, a waveform and a Stop button">
</p>

Speaking is faster than typing, and the tools that prove it want your voice on
someone else's server. OmaFlow runs on your own machine. A 13.7-second
dictation transcribes in **48.8 ms**, two minutes in **373.6 ms** — 281× and
321× real time, with no network round trip in either.

<!-- MEDIA 2 — OFFLINE PROOF (missing)
     4-6s GIF: network switched off, same gesture, still works. Nobody else in
     this category demonstrates it; they only claim it.
       ffmpeg -i raw.mp4 -vf "fps=15,scale=800:-1:flags=lanczos,split[s0][s1];\
              [s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer" \
              -loop 0 offline.gif -->

## Install

```bash
omarchy plugin add https://github.com/entroit/omaflow.git
cd ~/.config/omarchy/plugins/entroit.omaflow
./install --hotkey F13
```

Replace `F13` with the key you want to hold.

The marketplace command downloads the plugin. `./install` installs its bundled
binary, user services, and hotkey integration. It shows the plan before it
changes your system and does not download a speech model. You do not need Rust
or Cargo.

## Updates stay inside OmaFlow

OmaFlow checks the official Omarchy plugin marketplace once a day. When the
marketplace publishes a verified OmaFlow commit, a desktop notification opens
the panel. The bar also keeps a dot visible, and the panel shows the release
summary and changes. Click **Update** to install it. Click **Later** to hide the
home card for one day. The bar dot and the Settings row remain.

An update waits for an active dictation to finish. OmaFlow then switches the
plugin and daemon together, checks the new service, and restores the previous
release if that check fails. It never installs the repository's current branch
or an unreviewed GitHub release.

OmaFlow 0.17 and older cannot perform this handoff automatically. After the
marketplace lists 0.18, use the exact 40-character verified commit shown there
for the one-time bridge below. Do not substitute a branch name such as `main`.

```bash
git -C ~/.config/omarchy/plugins/entroit.omaflow fetch --no-tags https://github.com/entroit/omaflow <FULL_VERIFIED_COMMIT>
git -C ~/.config/omarchy/plugins/entroit.omaflow merge --ff-only <FULL_VERIFIED_COMMIT>
cd ~/.config/omarchy/plugins/entroit.omaflow && ./install --yes
```

Automatic in-app updates begin only after that bridge installs the trusted
runner and release receipt.

## Nothing else is downloaded behind your back

No model weights come with the install. **Settings → Speech** lists every model
with its size, the hardware it needs and its licence. You pick one, and only
then does anything download.

<p align="center">
  <img src="assets/settings-models.png" width="460" alt="Settings → Speech: the running model, then catalog cards with size, hardware and licence and a Download button">
</p>

Your own model or server works too. [Details →](docs/custom-models.md)

## Speak, then keep typing

| What you want | What to do |
|---|---|
| Dictate a sentence | Hold your hotkey, speak, then release. |
| Talk hands-free | Double-tap to lock. Press again or click **Stop**. |
| Copy without pasting | Choose **Copy only** in Settings → General. |
| Use an app-specific paste key | Choose **Custom** in Settings → General, select the modifiers and enter the key. |
| Fix a result | Open it in History to edit or copy again. |

<!-- MEDIA 3 — WORKS EVERYWHERE (missing)
     6-8s GIF, one continuous take: same gesture in a terminal, a browser field
     and an editor. Proves it is not app-specific. -->

Your music ducks while you talk and comes back when you release. Adjustable in
Settings → Audio, down to off.

<p align="center">
  <img src="assets/history-english.png" width="460" alt="OmaFlow History with three saved dictations, each with Copy and Delete">
</p>

## Cleanup is opt-in

Off by default, OmaFlow pastes exactly what it heard. Turn on **Natural
cleanup** and a second local model strips fillers, applies the corrections you
speak out loud, and punctuates — keeping every language exactly as spoken. A
Rust guard rejects any cleanup that changes a number or a name.

Cleanup uses Ollama by default and also supports OpenAI-compatible chat
servers. The Cleanup tab hands you the Ollama command if it is missing.

## Yours to configure

Every setting is in `~/.config/omaflow/config.toml` — hotkeys, vocabulary, even
the cleanup prompt. One commented file, no telemetry, editable by you or by an
agent. [Every setting →](docs/configuration.md)

## Remove it

`./uninstall` takes everything back off your machine: settings, history, the
checkout, and the models and runtimes OmaFlow installed.

---

MIT licensed. [Contributing](CONTRIBUTING.md)
