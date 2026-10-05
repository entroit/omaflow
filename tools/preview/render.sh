#!/usr/bin/env bash
# Render preview screens of the shared UI to PNGs, without Quickshell.
#   tools/preview/render.sh OUTPUT_DIR [MODE...]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output="${1:?Usage: render.sh OUTPUT_DIR [MODE...]}"
shift
mkdir -p "$output"
modes=("$@")
if ((${#modes[@]} == 0)); then
  modes=(history history-empty history-setup history-undo journal journal-hover journal-playing journal-talking
    journal-first journal-empty journal-search journal-settings todos todos-empty todos-editing todos-settling todos-undo
    todos-list todos-hover todos-today todos-upcoming todos-all todos-done todos-move todos-due todos-picker todos-listmenu
    todos-newlist todos-talking settings-basics settings-words settings-privacy
    settings-models settings-ownmodel settings-cleanup settings-hotkeys settings-audio settings-updates
    overlay-holding overlay-locked overlay-processing overlay-success overlay-result overlay-notice
    overlay-error overlay-error-kept overlay-journal overlay-journal-saved overlay-todo overlay-todo-menu overlay-todos-saved overlay-todos-saved-editing overlay-todos-saved-menu
    overlay-todo-inbox overlay-todos-saved-inbox)
fi
failed=0
for mode in "${modes[@]}"; do
  log="$output/$mode.log"
  if QT_FORCE_STDERR_LOGGING=1 timeout 20 qml6 -platform offscreen "$here/Preview.qml" -- "$mode" "$output/$mode.png" >"$log" 2>&1 \
    && [[ -s "$output/$mode.png" ]] && ! grep -qE "Error|TypeError|ReferenceError|Unable to assign|unavailable|not a type|is not defined|Binding loop" "$log"; then
    printf 'PASS %s\n' "$mode"
  else
    printf 'FAIL %s\n' "$mode"
    sed 's/^/  /' "$log" | head -20
    failed=1
  fi
done
exit "$failed"
