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
# This is the published upstream v0.1.0 Linux x86_64 CUDA artifact. Changing
# any value requires reviewing and hashing the replacement archive first.
readonly runtime_version="0.1.0"
readonly runtime_archive="nemo-speech-$runtime_version-linux-x86_64-cuda.tar.gz"
readonly runtime_root="${runtime_archive%.tar.gz}"
readonly runtime_bytes=107310946
readonly runtime_sha256="e68628f396489c98fb353e070efaea5bc4977409ae7734fce56c251a79e29147"
readonly runtime_url="https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v$runtime_version/$runtime_archive"

if "$binary" --version >/dev/null 2>&1; then
  printf 'NeMo-Speech runtime already installed at %s\n' "$prefix"
  exit 0
fi

# Only a prefix we created ourselves may be removed by ./uninstall, so record
# absence before the installer makes the directory exist.
was_absent=0
[[ -e $prefix || -L $prefix ]] || was_absent=1

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
  printf 'The managed NeMo-Speech runtime supports Linux x86_64 only.\n' >&2
  printf 'Install a compatible runtime yourself and link it in Speech settings.\n' >&2
  exit 1
fi

parent="$(dirname "$prefix")"
mkdir -p "$parent"
temporary="$(mktemp -d "$parent/.nemo-speech-install-XXXXXX")"
archive="$temporary/$runtime_archive"
extract="$temporary/extract"
trap 'rm -rf -- "$temporary"' EXIT

if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --fail --silent --show-error --location --retry 3 \
  --max-filesize "$runtime_bytes" \
  --output "$archive" \
  "$runtime_url"; then
  printf 'Could not download the NeMo-Speech runtime. Check the network and\n' >&2
  printf 'that github.com is reachable, then run scripts/install-nemo.sh again.\n' >&2
  exit 1
fi

downloaded_bytes="$(wc -c < "$archive")"
if ((downloaded_bytes != runtime_bytes)); then
  printf 'The NeMo-Speech runtime size is %d bytes; expected exactly %d.\n' \
    "$downloaded_bytes" "$runtime_bytes" >&2
  printf 'Refusing to extract it. Update OmaFlow before trying again.\n' >&2
  exit 1
fi

downloaded_sha256="$(sha256sum "$archive" | cut -d ' ' -f 1)"
if [[ $downloaded_sha256 != "$runtime_sha256" ]]; then
  printf 'The NeMo-Speech runtime failed checksum verification.\n' >&2
  printf 'Refusing to extract it. Update OmaFlow before trying again.\n' >&2
  exit 1
fi

if ! tar -tzf "$archive" | awk -v root="$runtime_root" \
  '$0 != root && index($0, root "/") != 1 { exit 1 }'; then
  printf 'The NeMo-Speech runtime has an unexpected archive layout.\n' >&2
  printf 'Refusing to extract it. Update OmaFlow before trying again.\n' >&2
  exit 1
fi

mkdir "$extract"
if ! tar --extract --gzip --file "$archive" --directory "$extract" --no-same-owner; then
  printf 'Could not extract the verified NeMo-Speech runtime.\n' >&2
  exit 1
fi

staged="$extract/$runtime_root"
staged_binary="$staged/bin/nemo-speech"
if [[ ! -x $staged_binary ]]; then
  printf 'The verified NeMo-Speech runtime does not contain its executable.\n' >&2
  exit 1
fi
if ! installed_version="$("$staged_binary" --version 2>/dev/null)" ||
  [[ $installed_version != "nemo-speech $runtime_version" ]]; then
  printf 'The verified NeMo-Speech runtime did not report version %s.\n' \
    "$runtime_version" >&2
  exit 1
fi
printf '%s linux x86_64 cuda\n' "$runtime_version" > "$staged/.nemo-speech-install"

next="$prefix.new"
previous="$prefix.old"
rm -rf -- "$next" "$previous"
mv "$staged" "$next"
had_previous=0
if [[ -e $prefix || -L $prefix ]]; then
  mv "$prefix" "$previous"
  had_previous=1
fi
if ! mv "$next" "$prefix"; then
  if ((had_previous)); then mv "$previous" "$prefix"; fi
  printf 'Could not activate the NeMo-Speech runtime.\n' >&2
  exit 1
fi
rm -rf -- "$previous"

if ((was_absent)); then
  # Bookkeeping must never fail a runtime that is already in place; the worst
  # case is that ./uninstall leaves the prefix behind for the user to delete.
  python3 "$repo_dir/tools/install_receipt.py" nemo-runtime "$prefix" || true
fi
printf 'NeMo-Speech runtime installed at %s\n' "$prefix"
