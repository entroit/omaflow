#!/usr/bin/env python3
"""Let the sandboxed daemon write the journal and to-do folders.

omaflow.service keeps the home folder read-only apart from OmaFlow's own
config and state. The journal and to-do folders can be anywhere the user
picks, so they are added with a drop-in, which is only honoured for folders
that already exist when the service starts. This creates the folders, writes
the drop-in, and restarts the daemon when a folder changed.

  tools/journal_folder.py              sync after the folder setting changed
  tools/journal_folder.py --write-only create and write, no reload or restart
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tomllib

DEFAULTS = {"journal": "~/Documents/Journal", "todos": "~/Documents/To-dos"}


def config_home():
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))


def config_path():
    return Path(os.environ.get("OMAFLOW_CONFIG", str(config_home() / "omaflow/config.toml")))


def drop_in_path():
    return config_home() / "systemd/user/omaflow.service.d/journal-folder.conf"


def folders():
    try:
        config = tomllib.loads(config_path().read_text())
    except FileNotFoundError:
        config = {}
    paths = []
    for section, default in DEFAULTS.items():
        folder = str(config.get(section, {}).get("folder") or default).strip()
        if any(ord(char) < 32 for char in folder) or not folder.startswith(("/", "~")):
            name = "journal" if section == "journal" else "to-do"
            raise ValueError(f"The {name} folder must be a full path, not {folder!r}")
        paths.append(Path(os.path.expanduser(folder)))
    return paths


def drop_in(folders):
    # systemd reads a quoted path; a backslash or quote in it must be escaped.
    quoted = " ".join('"' + str(folder).replace("\\", "\\\\").replace('"', '\\"') + '"' for folder in folders)
    return ("# Written by OmaFlow (tools/journal_folder.py): the journal and to-do\n"
            "# folders the sandboxed daemon may write. Change them in OmaFlow, not here.\n"
            "[Service]\n"
            f"ReadWritePaths={quoted}\n")


def sync(write_only):
    paths = []
    for folder in folders():
        folder.mkdir(parents=True, exist_ok=True)
        if folder.resolve() not in paths:
            paths.append(folder.resolve())
    folder = " and ".join(str(path) for path in paths)
    path = drop_in_path()
    wanted = drop_in(paths)
    if path.exists() and path.read_text() == wanted:
        return f"The daemon can already write {folder}"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(wanted)
    temporary.replace(path)
    if not write_only:
        subprocess.run(["systemctl", "--user", "daemon-reload"], check=True, timeout=20)
        # A running daemon only sees the new folder after a restart.
        subprocess.run(["systemctl", "--user", "try-restart", "omaflow.service"], check=True, timeout=30)
    return f"The daemon can now write {folder}"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--write-only", action="store_true", help="create the folder and drop-in without reloading systemd")
    args = parser.parse_args()
    try:
        print(sync(args.write_only))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Could not open the journal and to-do folders to OmaFlow: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
