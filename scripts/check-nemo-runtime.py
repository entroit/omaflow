#!/usr/bin/env python3
"""Check an installed runtime against OmaFlow's committed archive contents."""

import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def check_ancestors(prefix):
    ancestors = set(prefix.absolute().parents) | set(prefix.resolve().parents)
    for parent in ancestors:
        try:
            link = parent.lstat()
        except FileNotFoundError:
            continue
        info = parent.stat()
        if (link.st_uid not in (0, os.geteuid())
                or info.st_uid not in (0, os.geteuid())
                or (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX)):
            raise ValueError(f"another user can replace {parent}")


def check_file(info, path):
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
            or info.st_nlink != 1 or info.st_mode & 0o022):
        raise ValueError(f"{path} must be an owned regular file without links or shared write access")


def prepare_lock(path):
    check_ancestors(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    check_ancestors(path)
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(descriptor)
        check_file(info, path)
        if info.st_mode & 0o077:
            raise ValueError("the runtime lock must be owner-only")
    finally:
        os.close(descriptor)


def verify(prefix, manifest, archive_sha256):
    if manifest["archiveSha256"] != archive_sha256:
        raise ValueError("the runtime manifest does not identify the pinned archive")
    files, symlinks = manifest["files"], manifest["symlinks"]
    directories = {"."}
    for name in files.keys() | symlinks.keys():
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("the runtime manifest contains an unsafe path")
        directories.update(str(parent) for parent in path.parents)
    check_ancestors(prefix)
    found_files, found_symlinks, found_directories = set(), set(), set()
    pending = [prefix]
    while pending:
        directory = pending.pop()
        info = directory.lstat()
        name = str(directory.relative_to(prefix))
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_mode & 0o022 or name not in directories):
            raise ValueError(f"{directory} is not an expected owned runtime directory")
        found_directories.add(name)
        for path in directory.iterdir():
            info = path.lstat()
            name = str(path.relative_to(prefix))
            if stat.S_ISDIR(info.st_mode):
                pending.append(path)
            elif stat.S_ISLNK(info.st_mode):
                if info.st_uid != os.geteuid() or symlinks.get(name) != os.readlink(path):
                    raise ValueError(f"{path} is not an expected runtime link")
                found_symlinks.add(name)
            else:
                check_file(info, path)
                if name == ".nemo-speech-install":
                    continue
                if name not in files:
                    raise ValueError(f"{path} is not an expected runtime file")
                descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(descriptor, "rb") as stream:
                    check_file(os.fstat(stream.fileno()), path)
                    digest = hashlib.file_digest(stream, "sha256").hexdigest()
                if digest != files[name]:
                    raise ValueError(f"{path} does not match the pinned runtime")
                found_files.add(name)
    if (found_files != files.keys() or found_symlinks != symlinks.keys()
            or found_directories != directories):
        raise ValueError("the runtime is missing pinned files or directories")


if __name__ == "__main__":
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "--prepare-lock":
            prepare_lock(Path(sys.argv[2]))
        else:
            prefix, manifest_path, archive_sha256 = sys.argv[1:]
            verify(Path(prefix), json.loads(Path(manifest_path).read_text()), archive_sha256)
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.exit(f"NeMo-Speech runtime integrity check failed: {error}")
