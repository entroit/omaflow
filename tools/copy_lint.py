#!/usr/bin/env python3
"""Fail when shipped text breaks the house wording rules.

One term per concept and no em dashes, checked in every shipped file that holds
user-facing text, so a change cannot quietly bring back wording that reviews
already removed. Comment lines are skipped; they are read by maintainers.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RULES = [
    (re.compile("—"), "an em dash; use a full stop, comma or colon"),
    (re.compile(r"plugin folder|plugin checkout|OmaFlow checkout", re.I), 'name it "the OmaFlow folder"'),
    (re.compile(r'"Ctrl Z"'), 'write keys as "Ctrl+Z"'),
    (re.compile(r"Settings, (Advanced, )?Updates(?! and app)"), 'the page is "Updates and app"'),
]
COMMENT = re.compile(r"^\s*(//|#|/\*|\*)")


def shipped_files():
    listed = subprocess.run(["git", "ls-files", "ui", "hosts", "src", "crates", "config", "README.md", "docs",
                             "install", "uninstall", "scripts"], cwd=ROOT, capture_output=True, text=True,
                            check=True).stdout.split()
    return [ROOT / name for name in listed if not name.startswith("docs/v2-")]


def main():
    problems = []
    for path in shipped_files():
        if not path.is_file():
            continue
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            if COMMENT.match(line):
                continue
            for pattern, why in RULES:
                if pattern.search(line):
                    problems.append(f"{path.relative_to(ROOT)}:{number}: {why}: {line.strip()[:100]}")
    for problem in problems:
        print(problem)
    if problems:
        sys.exit(f"{len(problems)} wording problems")
    print("PASS shipped wording keeps one term per concept and no em dashes")


if __name__ == "__main__":
    main()
