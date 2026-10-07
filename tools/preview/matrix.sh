#!/usr/bin/env bash
# Render preview screens in the three conditions a change must hold in: the
# built-in dark theme, a light theme, and the narrowest window.
#   tools/preview/matrix.sh OUTPUT_DIR [MODE...]
# Each lands in OUTPUT_DIR/dark, OUTPUT_DIR/light and OUTPUT_DIR/narrow.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output="${1:?Usage: matrix.sh OUTPUT_DIR [MODE...]}"
shift
light="${MATRIX_LIGHT_THEME:-/usr/share/omarchy/themes/catppuccin-latte/colors.toml}"
failed=0
"$here/render.sh" "$output/dark" "$@" || failed=1
PREVIEW_THEME="$light" "$here/render.sh" "$output/light" "$@" || failed=1
PREVIEW_NARROW=1 "$here/render.sh" "$output/narrow" "$@" || failed=1
exit "$failed"
