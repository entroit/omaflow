#!/usr/bin/env bash
# OmaFlow preflight. Every check prints the command that fixes it.
# Run as the desktop user, inside the Hyprland session, not with sudo.

fail=0
bootstrap=0
no_models=0
for option in "$@"; do
  case "$option" in
    --bootstrap) bootstrap=1 ;;
    --no-models) no_models=1 ;;
    *) printf 'Unknown option: %s\n' "$option" >&2; exit 1 ;;
  esac
done
ok()   { printf '  ok    %s\n' "$1"; }
warn() { printf '  warn  %s\n     -> %s\n' "$1" "$2"; }
bad()  { printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; fail=1; }

repairable() { if ((bootstrap)); then warn "$1" "The installer will repair this."; else bad "$@"; fi; }

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! model_values="$(python3 "$repo_dir/tools/model_config.py" --shell-values)"; then exit 1; fi
mapfile -t model_settings <<<"$model_values"
if ((bootstrap == 0 && ${model_settings[8]:-1} == 0)); then no_models=1; fi
managed_speech=0
[[ ${model_settings[0]} == nemo || ${model_settings[0]} == parakeet ]] && managed_speech=1
export OLLAMA_HOST="${model_settings[5]}"

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

if ((managed_speech && !no_models)) && [[ ${model_settings[3]} == cuda ]]; then
# 5. NVIDIA GPU present
if command -v nvidia-smi >/dev/null && nvidia-smi -L 2>/dev/null | grep -q '^GPU 0'; then
  ok "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
else
  bad "no NVIDIA GPU detected" \
      "The speech backend is configured for CUDA. Install: sudo pacman -S nvidia-open nvidia-utils   then reboot. Without an NVIDIA GPU, OmaFlow needs a different backend."
fi

# 6. CUDA usable by userspace (not just a driver on disk)
if [[ -e /dev/nvidiactl ]] && ldconfig -p | grep -q 'libcuda\.so\.1' \
   && nvidia-smi -q 2>/dev/null | grep -qi 'cuda version'; then
  ok "CUDA runtime reachable (driver CUDA $(nvidia-smi -q 2>/dev/null | sed -n 's/.*CUDA Version *: *\([0-9.]*\).*/\1/p' | head -1))"
else
  bad "CUDA is not usable" \
      "The driver is missing or was updated without a reboot. Run: sudo pacman -S nvidia-utils && sudo reboot"
fi

if [[ ${model_settings[1]} == nvidia/parakeet-tdt-0.6b-v3 && ${model_settings[4]} == gemma4:e4b ]] && ((model_settings[6])); then
# 7. Free VRAM for both models.
#    Measured on the dev PC: nemo-speech peaks at 1850 MiB after a 120 s clip
#    (868 MiB idle) and ollama's llama-server holds 4353 MiB for gemma4:e4b.
#    Already-resident OmaFlow processes count as available, not as used.
need_mib=6300
if command -v nvidia-smi >/dev/null; then
  free_mib=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1)
  mine_mib=$(nvidia-smi --query-compute-apps=process_name,used_memory --format=csv,noheader,nounits \
             | grep -E 'llama-server|nemo-speech' \
             | awk -F, '{s+=$2} END{print s+0}')
  avail_mib=$(( free_mib + mine_mib ))
  if (( avail_mib >= need_mib )); then
    ok "VRAM ${avail_mib} MiB available for models (${free_mib} free + ${mine_mib} already held by OmaFlow), need ${need_mib}"
  else
    bad "only ${avail_mib} MiB of VRAM available, both models need ~${need_mib} MiB" \
        "Close GPU applications, or run 'ollama stop gemma4:e4b' between sessions. A 16 GB card is comfortable; 8 GB is tight once a browser is open."
  fi
fi
else
  warn "Custom models selected; GPU memory requirement is unmeasured" "Check their model documentation and available VRAM."
fi

else
  ok "NVIDIA checks skipped for the configured speech backend"
fi

if ((model_settings[6] && !no_models)); then
# 8. Ollama running with GPU offload
if curl -fsS -o /dev/null --max-time 2 "${OLLAMA_HOST}/api/tags"; then
  ok "Ollama is answering at $OLLAMA_HOST"
else
  if [[ $OLLAMA_HOST == http://127.0.0.1:11434 || $OLLAMA_HOST == http://localhost:11434 ]]; then
    repairable "ollama is not running" "Run: sudo systemctl enable --now ollama"
  else
    bad "Configured Ollama server is unavailable: $OLLAMA_HOST" "Start that server before installing."
  fi
fi
if ollama ps 2>/dev/null | tail -n +2 | grep -q '.'; then
  if ollama ps | tail -n +2 | grep -qE '[0-9]+% +GPU'; then
    ok "ollama offloads to the GPU ($(ollama ps | tail -n +2 | grep -oE '[0-9]+% +(GPU|CPU)' | head -1))"
  else
    warn "Ollama is running the model on the CPU" "Cleanup may be slower; choose a suitable model or GPU backend."
  fi
else
  warn "no ollama model resident, GPU offload unverified" \
       "Check after first use with: ollama ps   The PROCESSOR column must read 100% GPU."
fi

fi

# 9. systemd user session
if [[ -n ${XDG_RUNTIME_DIR:-} && -d ${XDG_RUNTIME_DIR:-/nonexistent} ]] \
   && systemctl --user is-system-running 2>/dev/null | grep -qE 'running|degraded|starting'; then
  ok "systemd user session ($(systemctl --user is-system-running 2>/dev/null))"
else
  bad "no systemd user session" \
      "OmaFlow installs user units. Log in graphically as this user (not su/sudo) and confirm: systemctl --user is-system-running"
fi

# 10. PipeWire and a real microphone (monitor sources are loopbacks, not mics)
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

# 11. The capture actually yields PCM in OmaFlow's exact format
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

# 12. Speech port; only the managed server owns a local listening port.
if ((managed_speech && !no_models)); then
  speech_authority="${model_settings[2]#http://}"
  speech_port="${speech_authority%%/*}"
  speech_port="${speech_port##*:}"
  listener=$(ss -ltnpH "sport = :$speech_port" 2>/dev/null)
  if [[ -z $listener ]]; then
    ok "speech port $speech_port is free"
  elif grep -q 'nemo-speech' <<<"$listener"; then
    ok "speech port $speech_port is held by NeMo-Speech"
  else
    bad "speech port $speech_port is taken" "Stop the other listener or change backend.endpoint."
  fi
fi

# 13. ~/.local/bin on PATH (link-local puts the omaflow binary there)
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
