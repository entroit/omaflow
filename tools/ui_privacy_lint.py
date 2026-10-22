#!/usr/bin/env python3
"""Keep clipboard access and desktop notifications behind their UI boundaries."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check_source(path, source):
    source = re.sub(r"//.*$", "", source, flags=re.M)
    if re.search(r"\b(?:TextInput|TextField)\b", source):
        raise ValueError(f"{path}: use LineEdit, not TextInput or TextField; Qt reads their clipboard without bounds")
    editors = len(re.findall(r"^\s*(?:\w+\.)?(?:TextArea|TextEdit) \{", source, re.M))
    controls = len(re.findall(r"^\s*Controls\.TextArea \{", source, re.M))
    if source.count("PasteGuard {") != editors or source.count("ContextMenu.menu: null") != controls:
        raise ValueError(f"{path}: give each text field a PasteGuard and each Controls one ContextMenu.menu: null")
    if re.search(r'''["']notify-send["']''', source):
        raise ValueError(f"{path}: use hosts/omarchy/Notifications.js fixed messages; private text must stay in OmaFlow")


def check():
    for path in sorted([*(ROOT / "ui").glob("*.qml"), *(ROOT / "hosts").rglob("*.qml")]):
        check_source(path.relative_to(ROOT), path.read_text())
    print("PASS UI clipboard access uses PasteGuard and desktop notifications use fixed messages", flush=True)


if __name__ == "__main__":
    try:
        check()
    except ValueError as error:
        raise SystemExit(str(error))
