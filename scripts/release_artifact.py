#!/usr/bin/env python3
"""Acquire a release executable and verify its source-bound attestation."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


REPOSITORY = "entroit/omaflow"
WORKFLOW = f"{REPOSITORY}/.github/workflows/release-binary.yml"
ASSET = "omaflow-x86_64-unknown-linux-gnu"
BUNDLE_LIMIT = 4 * 1024 * 1024


class ArtifactError(Exception):
    pass


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--bytes", required=True, type=int)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        raise ArtifactError("The release source commit is invalid.")
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", args.version):
        raise ArtifactError("The release version is invalid.")
    if not 0 < args.bytes <= 128 * 1024 * 1024:
        raise ArtifactError("The release executable size is invalid.")
    if not re.fullmatch(r"[0-9a-f]{64}", args.sha256):
        raise ArtifactError("The release executable checksum is invalid.")
    args.destination = args.destination.absolute()
    return args


def check_destination(directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ArtifactError("The release directory must be a private directory owned by you.")
    for name in ("omaflow", "omaflow.sigstore.json"):
        try:
            info = (directory / name).lstat()
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise ArtifactError("Release output must be an owned regular file without links.")


def check_bytes(binary, release):
    if binary.stat().st_size != release.bytes:
        raise ArtifactError("The release executable has the wrong size.")
    with binary.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if digest != release.sha256:
        raise ArtifactError("The release executable checksum does not match.")


def download(url, destination, limit, label):
    destination.touch(mode=0o600, exist_ok=False)
    try:
        result = subprocess.run(
            ["/usr/bin/curl", "--disable", "--fail", "--silent", "--show-error",
             "--location", "--proto", "=https", "--proto-redir", "=https",
             "--tlsv1.2", "--max-redirs", "3", "--connect-timeout", "10",
             "--max-time", "60", "--max-filesize", str(limit),
             "--output", str(destination), url],
            env={"PATH": "/usr/bin", "LC_ALL": "C"},
            capture_output=True, timeout=75, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ArtifactError(f"Could not download the release {label}.") from error
    if result.returncode != 0:
        raise ArtifactError(f"Could not download the release {label}.")
    size = destination.stat().st_size
    if not 0 < size <= limit:
        raise ArtifactError(f"The release {label} size is invalid.")


def verify(binary, bundle, release, scratch):
    check_bytes(binary, release)
    if not 0 < bundle.stat().st_size <= BUNDLE_LIMIT:
        raise ArtifactError("The release attestation size is invalid.")
    environment = {"PATH": "/usr/bin", "LC_ALL": "C", "GH_PROMPT_DISABLED": "1",
                   "GH_NO_UPDATE_NOTIFIER": "1", "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1",
                   "GH_CONFIG_DIR": str(scratch / "gh"),
                   "XDG_CACHE_HOME": str(scratch / "cache"), "TMPDIR": str(scratch)}
    try:
        result = subprocess.run(
            ["/usr/bin/gh", "attestation", "verify", str(binary), "--bundle", str(bundle),
             "--repo", REPOSITORY, "--signer-workflow", WORKFLOW,
             "--signer-digest", release.commit, "--source-digest", release.commit,
             "--source-ref", f"refs/tags/commit-{release.commit}",
             "--cert-oidc-issuer", "https://token.actions.githubusercontent.com",
             "--deny-self-hosted-runners"],
            env=environment, capture_output=True, timeout=90, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ArtifactError("Could not verify the release provenance. Install github-cli if it is missing.") from error
    if result.returncode != 0:
        raise ArtifactError("The release provenance could not be verified.")
    check_bytes(binary, release)


def acquire(release):
    directory = release.destination
    check_destination(directory)
    binary = directory / "omaflow"
    bundle = directory / "omaflow.sigstore.json"
    with tempfile.TemporaryDirectory(prefix=".artifact-", dir=directory) as temporary:
        scratch = Path(temporary)
        if binary.exists() and bundle.exists():
            try:
                verify(binary, bundle, release, scratch)
            except (ArtifactError, OSError):
                pass
            else:
                binary.chmod(0o700)
                return
        base = f"https://github.com/{REPOSITORY}/releases/download/commit-{release.commit}"
        downloaded = scratch / "omaflow"
        downloaded_bundle = scratch / "omaflow.sigstore.json"
        download(f"{base}/{ASSET}", downloaded, release.bytes, "executable")
        check_bytes(downloaded, release)
        download(f"{base}/{ASSET}.sigstore.json", downloaded_bundle, BUNDLE_LIMIT, "attestation")
        verify(downloaded, downloaded_bundle, release, scratch)
        downloaded.chmod(0o700)
        for source, destination in ((downloaded, binary), (downloaded_bundle, bundle)):
            with source.open("rb") as file:
                os.fsync(file.fileno())
            os.replace(source, destination)
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def main():
    os.umask(0o077)
    try:
        acquire(arguments())
    except (ArtifactError, OSError) as error:
        print(f"OmaFlow release: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
