#!/usr/bin/env python3
"""Record resources added by the installer, independently of personal settings."""
import json
import os
from pathlib import Path
import sys
import tempfile


def receipt_path():
    return Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state')) / 'omaflow-install/receipt.json'


def read_receipt():
    path = receipt_path()
    return json.loads(path.read_text()) if path.exists() else []


def record(kind, value):
    entries = read_receipt()
    entry = {'kind': kind, 'value': value}
    if entry in entries:
        return
    entries.append(entry)
    save_receipt(entries)


def save_receipt(entries):
    path = receipt_path()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as file:
        json.dump(entries, file)
        temporary = Path(file.name)
    temporary.replace(path)


if __name__ == '__main__':
    record(*sys.argv[1:])
