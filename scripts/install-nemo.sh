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
# Safe to re-run: a working runtime of the build this machine needs is left
# alone, and a machine that gained or lost its NVIDIA driver gets the other one.

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${1:-$HOME/.local/lib/nemo-speech}"
binary="$prefix/bin/nemo-speech"
marker="$prefix/.nemo-speech-install"
# These are the published upstream v0.1.0 Linux x86_64 artifacts, one per
# build. Changing any value requires reviewing and hashing the replacement
# archive first.
readonly runtime_version="0.1.0"
declare -rA runtime_bytes=(
  [cuda]=107310946
  [cpu]=4583913
)
declare -rA runtime_sha256=(
  [cuda]="e68628f396489c98fb353e070efaea5bc4977409ae7734fce56c251a79e29147"
  [cpu]="0f74131d631ad2c694cf0ec53490866bb6461147959589a69fb6fc231944065b"
)

# The CUDA build links libcuda.so.1 and will not start without it, and it is
# only faster when the NVIDIA kernel driver has a GPU to give it.
nvidia_driver_present() {
  local libraries
  libraries="$(PATH="$PATH:/usr/sbin:/sbin" ldconfig -p 2>/dev/null || true)"
  [[ -e /proc/driver/nvidia/version && $libraries == *'libcuda.so.1 (libc6,x86-64)'* ]]
}

if nvidia_driver_present; then variant=cuda; else variant=cpu; fi
readonly variant
readonly runtime_archive="nemo-speech-$runtime_version-linux-x86_64-$variant.tar.gz"
readonly runtime_root="${runtime_archive%.tar.gz}"
readonly runtime_url="https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v$runtime_version/$runtime_archive"
readonly runtime_marker="$runtime_version linux x86_64 $variant"
readonly expected_bytes="${runtime_bytes[$variant]}"
readonly expected_sha256="${runtime_sha256[$variant]}"

if [[ -f $marker && $(<"$marker") == "$runtime_marker" ]] &&
  "$binary" --version >/dev/null 2>&1; then
  printf 'NeMo-Speech runtime (%s) already installed at %s\n' "$variant" "$prefix"
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
  --max-filesize "$expected_bytes" \
  --output "$archive" \
  "$runtime_url"; then
  printf 'Could not download the NeMo-Speech runtime. Check the network and\n' >&2
  printf 'that github.com is reachable, then run scripts/install-nemo.sh again.\n' >&2
  exit 1
fi

downloaded_bytes="$(wc -c < "$archive")"
if ((downloaded_bytes != expected_bytes)); then
  printf 'The NeMo-Speech runtime size is %d bytes; expected exactly %d.\n' \
    "$downloaded_bytes" "$expected_bytes" >&2
  printf 'Refusing to extract it. Update OmaFlow before trying again.\n' >&2
  exit 1
fi

downloaded_sha256="$(sha256sum "$archive" | cut -d ' ' -f 1)"
if [[ $downloaded_sha256 != "$expected_sha256" ]]; then
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
printf '%s\n' "$runtime_marker" > "$staged/.nemo-speech-install"

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
printf 'NeMo-Speech runtime (%s) installed at %s\n' "$variant" "$prefix"
