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
# alone, and a machine that gained or lost its GPU driver gets the other one.

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${1:-$HOME/.local/lib/nemo-speech}"
binary="$prefix/bin/nemo-speech"
marker="$prefix/.nemo-speech-install"
# These are published upstream Linux x86_64 artifacts, one per build.
# Changing any value requires reviewing and hashing the replacement archive
# first. CUDA stays on 0.1.0: 0.3.0 is as fast here but bundles cuBLAS, which
# makes the download 704 MB instead of 107 MB. 0.2.0 is the first Vulkan build
# that loads Mesa's AMD and Intel drivers, and 0.3.0's CPU build is about 1.5x
# faster than 0.1.0's.
declare -rA runtime_versions=(
  [cuda]=0.1.0
  [vulkan]=0.3.0
  [cpu]=0.3.0
)
declare -rA runtime_bytes=(
  [cuda]=107310946
  [vulkan]=19482397
  [cpu]=9605101
)
declare -rA runtime_sha256=(
  [cuda]="e68628f396489c98fb353e070efaea5bc4977409ae7734fce56c251a79e29147"
  [vulkan]="2a8b2ca4610b6ea5d659ba10794526f6e5a77fb1623d52c35272a9fd1f74abac"
  [cpu]="255f12b722ab15b2a38a51cf125d56e3fa97058b528f7e895b39d6a473deb06e"
)

# The CUDA build links libcuda.so.1 and will not start without it, and it is
# only faster when the NVIDIA kernel driver has a GPU to give it.
nvidia_driver_present() {
  local libraries
  libraries="$(PATH="$PATH:/usr/sbin:/sbin" ldconfig -p 2>/dev/null || true)"
  [[ -e /proc/driver/nvidia/version && $libraries == *'libcuda.so.1 (libc6,x86-64)'* ]]
}

# A GPU render node and a Vulkan driver other than lavapipe, which runs on the
# CPU. Whether the GPU actually answers is asked of the staged build below.
vulkan_driver_present() {
  local driver
  compgen -G '/dev/dri/renderD*' >/dev/null || return 1
  for driver in /usr/share/vulkan/icd.d/*.json /etc/vulkan/icd.d/*.json; do
    [[ -f $driver && ${driver##*/} != lvp_icd* ]] && return 0
  done
  return 1
}

# Checks a runtime folder against the committed contents of one build.
verify_runtime() {
  python3 -I "$repo_dir/scripts/check-nemo-runtime.py" "$1" \
    "$repo_dir/scripts/nemo-runtime/$2.json" "${runtime_sha256[$2]}"
}

# The checked parent prevents another Unix user replacing this stable lock
# between validation and open. Every model download holds the same inode.
python3 -I "$repo_dir/scripts/check-nemo-runtime.py" --prepare-lock "$prefix.lock"
exec {runtime_lock}<>"$prefix.lock"
flock --exclusive "$runtime_lock"

if nvidia_driver_present; then
  variant=cuda
elif vulkan_driver_present; then
  variant=vulkan
else
  variant=cpu
fi

runtime_marker() {
  printf '%s linux x86_64 %s' "${runtime_versions[$1]}" "$1"
}

if [[ -f $marker && $(<"$marker") == "$(runtime_marker "$variant")" ]] &&
  verify_runtime "$prefix" "$variant" 2>/dev/null &&
  installed_version="$("$binary" --version 2>/dev/null)" &&
  [[ $installed_version == "nemo-speech ${runtime_versions[$variant]}" ]]; then
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
trap 'rm -rf -- "$temporary"' EXIT

# Downloads, verifies and extracts one build into the temporary directory,
# leaving its root in $staged.
stage() {
  local build="$1"
  local runtime_version="${runtime_versions[$build]}"
  local runtime_archive="nemo-speech-$runtime_version-linux-x86_64-$build.tar.gz"
  local runtime_root="${runtime_archive%.tar.gz}"
  local runtime_url="https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v$runtime_version/$runtime_archive"
  local expected_bytes="${runtime_bytes[$build]}"
  local expected_sha256="${runtime_sha256[$build]}"
  local archive="$temporary/$runtime_archive"
  local extract="$temporary/extract-$build"
  local downloaded_bytes downloaded_sha256 staged_binary installed_version
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
  verify_runtime "$staged" "$build"
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
  printf '%s\n' "$(runtime_marker "$build")" > "$staged/.nemo-speech-install"
}

stage "$variant"
# A Vulkan driver can be installed for a GPU that is not there or cannot run
# compute, and the Vulkan build then refuses to start rather than use the CPU.
if [[ $variant == vulkan ]] &&
  [[ $("$staged/bin/nemo-speech" --quiet doctor --json 2>/dev/null || true) != *'"accelerator_available": true'* ]]; then
  printf 'No GPU answered through Vulkan, so speech will run on the CPU.\n'
  variant=cpu
  stage "$variant"
fi

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
