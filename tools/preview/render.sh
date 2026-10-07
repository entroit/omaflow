#!/usr/bin/env bash
# Render preview screens of the shared UI to PNGs, without Quickshell.
#   tools/preview/render.sh OUTPUT_DIR [MODE...]
# PREVIEW_THEME=/usr/share/omarchy/themes/catppuccin-latte/colors.toml renders
# in that theme instead of the built-in dark one.
# PREVIEW_NARROW=1 renders the window at its narrowest, 760 px.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output="${1:?Usage: render.sh OUTPUT_DIR [MODE...]}"
shift
mkdir -p "$output"
modes=("$@")
if ((${#modes[@]} == 0)); then
  modes=(history history-empty history-setup history-undo history-off history-notinstalled history-setup-running history-setup-packages history-setup-failed history-raw history-dirty history-edited
    history-toast-error history-unloaded history-stopped journal journal-hover journal-playing journal-talking
    journal-first journal-empty journal-search journal-settings journal-unreadable journal-hit journal-past journal-typing
    journal-settings-confirm journal-past-empty journal-move journal-move-clash journal-playing-hover journal-narrow journal-search-fail journal-editing journal-deleted todos todos-empty todos-editing todos-settling todos-undo
    todos-list todos-inbox-empty todos-hover todos-today todos-upcoming todos-all todos-done todos-rowmenu todos-due todos-due-morning todos-picker todos-remindmenu todos-bubbled todos-later todos-reminder todos-settings todos-folder-move todos-listmenu
    todos-newlist todos-talking todos-editlists todos-folder-edit todos-picker-past todos-narrow settings-basics settings-words settings-privacy settings-privacy-off
    settings-models settings-ownmodel settings-cleanup settings-hotkeys settings-audio settings-audio-manual settings-updates settings-updates-later settings-updates-failed settings-updates-interrupted settings-updates-finish settings-updates-finish-running
    settings-privacy-audio settings-basics-recording settings-basics-custom settings-basics-light
    settings-models-missing settings-ownmodel-server settings-cleanup-server
    history-partly history-kept history-tabhint settings-updates-partly settings-models-downloading settings-models-cpu settings-cleanup-light settings-privacy-trim
    overlay-holding overlay-locked overlay-processing overlay-success overlay-result overlay-notice
    overlay-error overlay-error-kept overlay-journal overlay-journal-saved overlay-journal-note overlay-todo overlay-todo-menu overlay-todos-saved overlay-todos-saved-editing overlay-todos-saved-menu
    overlay-todo-inbox overlay-todos-saved-inbox overlay-copy-failed overlay-clipboard overlay-warning
    overlay-processing-journal overlay-processing-todos overlay-error-model overlay-nomic
    overlay-error-downloading overlay-error-saved overlay-journal-for-later overlay-journal-for-past
    history-failed history-failed-transcribing history-failed-gone overlay-journal-warning overlay-notice-update overlay-notice-update-failed
    history-skipped history-stopped-narrow settings-updates-paused
    history-long history-cleanupoff history-vocab history-firstdownload history-stoppedempty history-clipboard history-update history-update-failed history-restarting
    settings-basics-stopped settings-updates-folder settings-updates-checking
    settings-basics-cleanmissing settings-cleanup-cleanmissing settings-cleanup-serverdown settings-privacy-nohist settings-models-own
    settings-privacy-erase settings-ownmodel-whisper settings-hotkeys-window settings-hotkeys-dictate
    overlay-todos-saved-moved overlay-notice-long
    journal-search-note journal-other-year journal-hit-long journal-toast-error journal-writing journal-export-fail
    todos-uphover todos-keyboard todos-lastdelete todos-listerror todos-picker-keep todos-loaderror
    overlay-todos-saved-changed overlay-todos-saved-warning overlay-copy-failed-nohistory overlay-error-ready overlay-error-mic
    overlay-error-journal-save overlay-error-todos-save overlay-locked-busy overlay-locked-asking)
fi
failed=0
for mode in "${modes[@]}"; do
  log="$output/$mode.log"
  # The window remembers how you left it under XDG_STATE_HOME; previews start fresh.
  if QT_FORCE_STDERR_LOGGING=1 XDG_STATE_HOME="$output/state" timeout 20 qml6 -platform offscreen "$here/Preview.qml" -- ${PREVIEW_NARROW:+--narrow} ${PREVIEW_THEME:+"$(cat "$PREVIEW_THEME")"} "$mode" "$output/$mode.png" >"$log" 2>&1 \
    && [[ -s "$output/$mode.png" ]] && ! grep -qE "Error|TypeError|ReferenceError|Unable to assign|unavailable|not a type|is not defined|Binding loop" "$log"; then
    printf 'PASS %s\n' "$mode"
  else
    printf 'FAIL %s\n' "$mode"
    sed 's/^/  /' "$log" | head -20
    failed=1
  fi
done
exit "$failed"
