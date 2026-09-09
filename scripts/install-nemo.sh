#!/usr/bin/env bash
# Install the NeMo-Speech ASR runtime into ~/.local/lib/nemo-speech.
#
# This used to live inside ./install. It moved out because the runtime is only
# worth installing once a managed speech model is actually being downloaded:
# `omaflow model-install speech <id>` calls this script, and a person repairing
# a broken runtime can call it by hand.
#
# Non-interactive and unprivileged by design: it prompts for nothing, needs no
# sudo, and writes only under $HOME, so it is safe to run from the daemon.
# Safe to re-run: a working runtime is left alone.

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${1:-$HOME/.local/lib/nemo-speech}"
binary="$prefix/bin/nemo-speech"
# Upstream v0.1.0. Review the new installer before changing either pin.
readonly installer_commit="4f9676226f667d14608487df744f375db87127f8"
readonly installer_sha256="95da6acd4cfa91a00026bb9769cd773d85af0035c6b2ccd9042fb5c40d397774"
readonly installer_max_bytes=262144
readonly installer_url="https://raw.githubusercontent.com/NVIDIA/NeMo-Speech.cpp/$installer_commit/scripts/install.sh"

if "$binary" --version >/dev/null 2>&1; then
  printf 'NeMo-Speech runtime already installed at %s\n' "$prefix"
  exit 0
fi

# Only a prefix we created ourselves may be removed by ./uninstall, so record
# absence before the installer makes the directory exist.
was_absent=0
[[ -e $prefix || -L $prefix ]] || was_absent=1

installer="$(mktemp -t nemo-speech-install-XXXXXX.sh)"
trap 'rm -f "$installer"' EXIT

if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --fail --silent --show-error --location \
  --max-filesize "$installer_max_bytes" \
  --output "$installer" \
  "$installer_url"; then
  printf 'Could not download the NeMo-Speech installer. Check the network and\n' >&2
  printf 'that github.com is reachable, then run scripts/install-nemo.sh again.\n' >&2
  exit 1
fi

downloaded_bytes="$(wc -c < "$installer")"
if ((downloaded_bytes > installer_max_bytes)); then
  printf 'The NeMo-Speech installer is larger than the reviewed %d-byte limit.\n' \
    "$installer_max_bytes" >&2
  printf 'Refusing to execute it. Update OmaFlow before trying again.\n' >&2
  exit 1
fi

downloaded_sha256="$(sha256sum "$installer" | cut -d ' ' -f 1)"
if [[ $downloaded_sha256 != "$installer_sha256" ]]; then
  printf 'The NeMo-Speech installer failed checksum verification.\n' >&2
  printf 'Refusing to execute it. Update OmaFlow before trying again.\n' >&2
  exit 1
fi

# --prefix is mandatory: the installer defaults to ~/.local/share, which the
# systemd unit does not look at.
if ! sh "$installer" --backend cuda --prefix "$prefix" --no-modify-path; then
  printf 'The NeMo-Speech installer failed. Review its output above, fix the\n' >&2
  printf 'reported problem, then run scripts/install-nemo.sh again.\n' >&2
  exit 1
fi

if [[ ! -x $binary ]]; then
  printf 'The NeMo-Speech install did not produce %s.\n' "$binary" >&2
  exit 1
fi

if ((was_absent)); then
  # Bookkeeping must never fail a runtime that is already in place; the worst
  # case is that ./uninstall leaves the prefix behind for the user to delete.
  python3 "$repo_dir/tools/install_receipt.py" nemo-runtime "$prefix" || true
fi
printf 'NeMo-Speech runtime installed at %s\n' "$prefix"
