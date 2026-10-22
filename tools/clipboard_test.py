#!/usr/bin/env python3
"""Exercise clipboard reads through the real CLI with an isolated wl-paste."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("OMAFLOW_BINARY", str(ROOT / "target/release/omaflow"))).resolve()
TEXT = "Private clipboard fixture: café 🐈\nSecond line\n"

with tempfile.TemporaryDirectory(prefix="omaflow-clipboard-test-") as temporary:
    stage = Path(temporary)
    helper = stage / "wl-paste"
    helper.write_text('''#!/usr/bin/python3
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["XDG_RUNTIME_DIR"], "calls.jsonl").open("a") as calls:
    calls.write(json.dumps(args) + "\\n")
mode = os.environ["CLIPBOARD_CASE"]
types = "--list-types" in args
if mode == "slow-types" and types or mode == "slow-data" and not types:
    time.sleep(20)
elif types:
    print("image/png" if mode == "binary" else "text/plain;charset=utf-8")
elif mode == "large":
    sys.stdout.write("x" * (1024 * 1024 + 1))
else:
    sys.stdout.write(''' + repr(TEXT) + ''')
''')
    helper.chmod(0o700)
    environment = dict(os.environ, HOME=str(stage), XDG_CONFIG_HOME=str(stage / "config"),
        XDG_STATE_HOME=str(stage / "state"), XDG_RUNTIME_DIR=str(stage),
        PATH=f"{stage}:/usr/bin")

    def read(mode, primary=False):
        calls = stage / "calls.jsonl"
        calls.unlink(missing_ok=True)
        result = subprocess.run([str(BINARY), "clipboard-text", *(["--primary"] if primary else [])],
            env=dict(environment, CLIPBOARD_CASE=mode), capture_output=True, text=True, timeout=6)
        return result, [json.loads(line) for line in calls.read_text().splitlines()]

    for primary in (False, True):
        result, calls = read("text", primary)
        assert result.returncode == 0 and result.stdout == TEXT, result
        prefix = ["--primary"] if primary else []
        assert calls == [prefix + ["--list-types"],
            prefix + ["--no-newline", "--type", "text/plain;charset=utf-8"]], calls
    result, calls = read("binary")
    assert result.returncode == 0 and result.stdout == "" and calls == [["--list-types"]], (result, calls)
    for mode in ("slow-types", "slow-data", "large"):
        result, _ = read(mode)
        assert result.returncode != 0 and result.stdout == "", (mode, result)
        assert "too much text" in result.stderr if mode == "large" else "did not answer" in result.stderr, result
    print("PASS clipboard and primary reads preserve Unicode, ignore binary offers and reject slow or oversized data")
