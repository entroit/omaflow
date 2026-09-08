#!/usr/bin/env bash
# Run from any directory. --full also exercises the local models and QML.
set -euo pipefail

full=0
case "${1:-}" in
  --full) full=1 ;;
  '') ;;
  -h|--help)
    printf 'Usage: scripts/check-local.sh [--full]\n'
    printf 'Default: build, lint and isolated regression tests.\n'
    printf -- '--full: also run model gates, QML rendering and plugin validation.\n'
    exit 0 ;;
  *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
esac
if (($# > 1)); then
  printf 'Expected at most one option.\n' >&2
  exit 1
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
cargo build --locked --release
python3 tools/runtime_test.py
python3 tools/platform_test.py
python3 tools/installation_test.py
python3 tools/scoring_test.py
lua tools/hotkey_test.lua
shellcheck install link-local scripts/preflight.sh scripts/install-nemo.sh scripts/check-local.sh
for script in install link-local scripts/preflight.sh scripts/install-nemo.sh scripts/check-local.sh; do
  bash -n "$script"
done
git diff --check

if ((full)); then
  tools/cleanup_bench.py
  tools/cleanup_probe.py
  tools/cleanup_generalization.py
  tools/cleanup_itn_gate.py
  tools/dictation_modes_gate.py
  python3 tools/ui_smoke.py
  omarchy plugin validate .
fi

printf '\nLocal checks passed.\n'
