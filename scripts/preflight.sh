#!/usr/bin/env bash
# OmaFlow preflight. Every check prints the command that fixes it.
# Run as the desktop user, inside the Hyprland session, not with sudo.

fail=0
bootstrap=0
for option in "$@"; do
  case "$option" in
    --bootstrap) bootstrap=1 ;;
    *) printf 'Unknown option: %s\n' "$option" >&2; exit 1 ;;
  esac
done
ok()   { printf '  ok    %s\n' "$1"; }
warn() { printf '  warn  %s\n     -> %s\n' "$1" "$2"; }
bad()  { printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; fail=1; }

repairable() { if ((bootstrap)); then warn "$1" "The installer will repair this."; else bad "$@"; fi; }

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"

# Nothing here reads the model configuration any more: ./install ships the app
# and the models arrive later, so GPU, VRAM, Ollama and speech-port checks now
# belong to the point where a model is actually downloaded, not to install time.

# 1. Hyprland session
if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && command -v hyprctl >/dev/null \
   && hyprctl version >/dev/null 2>&1; then
  ok "Hyprland session ($(hyprctl version 2>/dev/null | head -1 | cut -d' ' -f1-2))"
else
  bad "no Hyprland session" \
      "Log into Omarchy's Hyprland session and run this from a terminal inside it, not over SSH or from a TTY."
fi

# 2. Hyprland accepts the Lua adapter
if ! hyprctl configerrors 2>/dev/null | grep -qv '^$'; then
  ok "hyprctl configerrors is empty"
else
  bad "Hyprland config has errors" "Run: hyprctl configerrors   and fix them before installing."
fi

# 3. Quickshell / Omarchy shell
if command -v quickshell >/dev/null && command -v omarchy >/dev/null \
   && command -v omarchy-shell >/dev/null; then
  ok "Quickshell and the Omarchy shell CLI are installed"
else
  bad "Quickshell or the Omarchy shell is missing" \
      "OmaFlow's panel is an Omarchy bar widget. Install Omarchy (https://omarchy.org) or: sudo pacman -S quickshell"
fi

# 4. Omarchy plugin directory
if [[ -d "$config_home/omarchy/plugins" ]] && omarchy plugin list >/dev/null 2>&1; then
  ok "plugin dir $config_home/omarchy/plugins"
else
  repairable "no Omarchy plugin directory" \
      "Run: mkdir -p $config_home/omarchy/plugins   then re-run, so link-local can link entroit.omaflow into it."
fi

# 5. systemd user session
if [[ -n ${XDG_RUNTIME_DIR:-} && -d ${XDG_RUNTIME_DIR:-/nonexistent} ]] \
   && systemctl --user is-system-running 2>/dev/null | grep -qE 'running|degraded|starting'; then
  ok "systemd user session ($(systemctl --user is-system-running 2>/dev/null))"
else
  bad "no systemd user session" \
      "OmaFlow installs user units. Log in graphically as this user (not su/sudo) and confirm: systemctl --user is-system-running"
fi

# 6. PipeWire and a real microphone (monitor sources are loopbacks, not mics)
if systemctl --user is-active --quiet pipewire && systemctl --user is-active --quiet wireplumber; then
  ok "PipeWire and WirePlumber are active"
else
  bad "PipeWire is not running" \
      "Run: sudo pacman -S pipewire-audio wireplumber && systemctl --user enable --now pipewire wireplumber"
fi
if command -v pw-cat >/dev/null; then
  ok "pw-cat present (OmaFlow records through it)"
else
  repairable "pw-cat is missing" "Run: sudo pacman -S pipewire-audio"
fi
if pactl list short sources 2>/dev/null | grep -v '\.monitor' | grep -q .; then
  ok "capture source: $(pactl get-default-source 2>/dev/null)"
else
  bad "no microphone source, only monitor loopbacks" \
      "Plug in or unmute a microphone, then pick it with: wpctl status   and   wpctl set-default <id>"
fi
if wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | grep -q MUTED; then
  bad "the default microphone is muted" "Run: wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0"
else
  ok "default microphone is unmuted"
fi

# 7. The capture actually yields PCM in OmaFlow's exact format
if command -v pw-cat >/dev/null; then
  captured=$(timeout 3 pw-cat --record --raw --format s16 --rate 16000 --channels 1 \
             --latency 32ms --media-category Capture --media-role Communication - 2>/dev/null \
             | head -c 32000 | wc -c)
  if (( captured >= 32000 )); then
    ok "captured ${captured} bytes (1.0 s of 16 kHz s16 mono)"
  else
    bad "microphone produced only ${captured} of 32000 bytes in 3 s" \
        "The device exists but delivers no audio. Check permissions and routing: wpctl status   and test by hand: pw-cat --record --raw --format s16 --rate 16000 --channels 1 - > /tmp/t.raw"
  fi
fi

# 8. ~/.local/bin on PATH (link-local puts the omaflow binary there)
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ok "\$HOME/.local/bin is on PATH" ;;
  *) bad "\$HOME/.local/bin is not on PATH" \
         "Add it: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc   then open a new terminal. Hyprland's exec_cmd needs it too, so re-log in after." ;;
esac

echo
if (( fail )); then
  echo "Preflight failed. Fix the FAIL lines above, then run it again."
elif (( bootstrap )); then
  echo "Preflight passed."
else
  echo "Preflight passed. Run ./link-local."
fi
exit $fail
