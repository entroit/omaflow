#!/usr/bin/env python3
"""Render and load the real UI without touching the desktop.

1. Renders every screen of the shared UI (ui/) with sample data on plain Qt,
   no Quickshell, and saves PNGs.
2. Loads the Omarchy host (hosts/omarchy) in an offscreen Quickshell with a
   fake daemon state, and fails on any QML warning.
3. Runs the connection tester's result handling against stubbed replies.

Layer-shell placement, the real keyboard and audio remain desktop checks.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path)
args = parser.parse_args()
output = (args.output or Path(tempfile.mkdtemp(prefix="omaflow-ui-images-"))).resolve()
output.mkdir(parents=True, exist_ok=True)

# 0. Quickshell only sees shared components listed in ui/qmldir.
listed = {line.split()[-1] for line in (ROOT / "ui/qmldir").read_text().splitlines() if line.endswith(".qml")}
missing = sorted(path.name for path in (ROOT / "ui").glob("*.qml") if path.name not in listed)
if missing:
    raise SystemExit("Add these to ui/qmldir: " + ", ".join(missing))

# 1. Every screen, rendered.
result = subprocess.run([str(ROOT / "tools/preview/render.sh"), str(output)], text=True)
if result.returncode:
    raise SystemExit("A preview failed to render cleanly; see the logs in " + str(output))

# 2. The Omarchy host, loaded the way the shell loads it.
shell = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell"
if not shell.is_dir():
    raise SystemExit("The host check needs an installed Omarchy shell")
with tempfile.TemporaryDirectory(prefix="omaflow-host-") as staging:
    stage = Path(staging)
    for directory in shell.iterdir():
        if directory.is_dir():
            (stage / directory.name).symlink_to(directory, target_is_directory=True)
    (stage / "ui").symlink_to(ROOT / "ui", target_is_directory=True)
    host = stage / "hosts/omarchy"
    host.mkdir(parents=True)
    shutil.copy(ROOT / "hosts/omarchy/Job.qml", host)
    # Offscreen Qt has no layer shell, so the overlay window becomes an Item;
    # everything inside it is still created and bound.
    source = (ROOT / "hosts/omarchy/OmaFlow.qml").read_text()
    start = source.index("  PanelWindow {")
    card = source.index("    OverlayCard {", start)
    source = source[:start] + "  Item {\n    id: overlayWindow\n" + source[card:]
    source = source.replace("    mask: Region { item: card; Region { item: card.menuArea } }\n", "")
    (host / "OmaFlow.qml").write_text(source)
    (stage / "shell.qml").write_text('''import QtQuick
import Quickshell
import "hosts/omarchy" as Host
ShellRoot {
  Host.OmaFlow { id: plugin }
  Timer { interval: 900; running: true; onTriggered: plugin.showWindow("journal") }
  Timer { interval: 1200; running: true; onTriggered: plugin.showWindow("todos") }
  Timer { interval: 1500; running: true; onTriggered: plugin.showWindow("settings/models") }
  Timer { interval: 2100; running: true; onTriggered: { plugin.showWindow("history"); console.log("OMAFLOW_HOST_OK") } }
  Timer { interval: 2600; running: true; onTriggered: Qt.quit() }
  // A secret goes to the command on stdin, not in its arguments.
  Host.Job { command: ["omaflow", "configure", "models", "-"]; input: '{"cleanup_api_key":"sk-host"}\\n'; running: true }
}
''')
    runtime = stage / "runtime"
    runtime.mkdir()
    fixture = json.loads(subprocess.run(
        ["qml6", "-platform", "offscreen", str(ROOT / "tools/preview/State.qml")],
        env=dict(os.environ, QT_FORCE_STDERR_LOGGING="1"), capture_output=True, text=True, timeout=20
    ).stderr.split("STATE ", 1)[1].splitlines()[0])
    import time
    fixture["published_at_ms"] = int(time.time() * 1000) + 60000
    (runtime / "omaflow-state.json").write_text(json.dumps(fixture))
    (runtime / "omaflow-level").write_text("0.4 -30 1" + " 0.3" * 13 + "\n")
    bin_dir = stage / "bin"
    bin_dir.mkdir()
    stub = bin_dir / "omaflow"
    stub.write_text("#!/bin/sh\ncase \"$1 $2\" in\n  'journal day') echo '{\"date\":\"'$3'\",\"title\":\"\",\"file\":\"\",\"exists\":false,\"entries\":[]}';;\n  'journal month') echo '{\"month\":\"'$3'\",\"days\":[]}';;\n  'journal stats') echo '{\"days\":0}';;\n  'journal year-ago') echo null;;\n  'configure models') read -r line; echo \"$* $line\" > \"$XDG_RUNTIME_DIR/configure-stdin\";;\n  'todos list') echo '{\"path\":\"\",\"todos\":[{\"index\":0,\"text\":\"Buy milk\",\"done\":false}]}';;\n  *) true;;\nesac\n")
    stub.chmod(0o755)
    headless = {key: value for key, value in os.environ.items() if key not in ("WAYLAND_DISPLAY", "DISPLAY")}
    run = subprocess.run(
        ["quickshell", "-p", str(stage)],
        env=dict(headless, QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", XDG_RUNTIME_DIR=str(runtime),
                 PATH=f"{bin_dir}:" + os.environ["PATH"]),
        capture_output=True, text=True, timeout=20,
    )
    log = run.stdout + run.stderr
    (output / "host.log").write_text(log)
    problems = [line for line in log.splitlines()
                if ("WARN" in line or "ERROR" in line)
                and "--- WARNING ---" not in line and "setting window masks" not in line]
    if "OMAFLOW_HOST_OK" not in log or problems:
        raise SystemExit("The Omarchy host did not load cleanly:\n" + "\n".join(problems or [log]))
    received = (runtime / "configure-stdin").read_text().strip() if (runtime / "configure-stdin").exists() else ""
    if received != 'configure models - {"cleanup_api_key":"sk-host"}':
        raise SystemExit("A secret did not reach the command on stdin: " + repr(received))
    print("PASS Omarchy host loads, shows each place, no QML warnings, and sends secrets on stdin", flush=True)

# 3. The shortcut recorder, driven by synthetic key presses.
recorder = subprocess.run(["/usr/lib/qt6/bin/qmltestrunner", "-input", str(ROOT / "tools/key_recorder_test.qml")],
                          env=dict(os.environ, QT_QPA_PLATFORM="offscreen"), capture_output=True, text=True, timeout=30)
if recorder.returncode != 0:
    raise SystemExit("The shortcut recorder test failed:\n" + recorder.stdout + recorder.stderr)
print("PASS the shortcut recorder records Super Shift J and F13, and refuses a bare J", flush=True)
table = subprocess.run(["/usr/lib/qt6/bin/qmltestrunner", "-input", str(ROOT / "tools/hotkeys_table_test.qml")],
                       env=dict(os.environ, QT_QPA_PLATFORM="offscreen"), capture_output=True, text=True, timeout=60)
if table.returncode != 0:
    raise SystemExit("The Hotkeys table test failed:\n" + table.stdout + table.stderr)
print("PASS a shortcut is recorded in its row while the daemon republishes its state", flush=True)
talk = subprocess.run(["/usr/lib/qt6/bin/qmltestrunner", "-input", str(ROOT / "tools/journal_talk_test.qml")],
                      env=dict(os.environ, QT_QPA_PLATFORM="offscreen"), capture_output=True, text=True, timeout=60)
if talk.returncode != 0:
    raise SystemExit("The journal Talk button test failed:\n" + talk.stdout + talk.stderr)
print("PASS Talk starts a hands-free entry on click and records while held", flush=True)
todos = subprocess.run(["/usr/lib/qt6/bin/qmltestrunner", "-input", str(ROOT / "tools/todos_test.qml")],
                       env=dict(os.environ, QT_QPA_PLATFORM="offscreen"), capture_output=True, text=True, timeout=60)
if todos.returncode != 0:
    raise SystemExit("The to-do page test failed:\n" + todos.stdout + todos.stderr)
print("PASS to-dos tick in place, delete and clear with Undo, and Talk starts a to-do take", flush=True)
overlay = subprocess.run(["/usr/lib/qt6/bin/qmltestrunner", "-input", str(ROOT / "tools/overlay_test.qml")],
                         env=dict(os.environ, QT_QPA_PLATFORM="offscreen"), capture_output=True, text=True, timeout=60)
if overlay.returncode != 0:
    raise SystemExit("The card test failed:\n" + overlay.stdout + overlay.stderr)
print("PASS cards count down in an Esc ring, wait while pointed at, and edit to-dos in place", flush=True)

# 3. The connection tester's handling of real replies.
probe = ROOT / "tools/preview/Probe.qml"
for payload, failed in [
    (json.dumps({"ok": True, "message": "Saved model accepted"}), False),
    (json.dumps({"ok": False, "message": "Credentials denied"}), True),
    ("not-json", True),
]:
    run = subprocess.run(["qml6", "-platform", "offscreen", str(probe), "--", payload],
                         env=dict(os.environ, QT_FORCE_STDERR_LOGGING="1"),
                         capture_output=True, text=True, timeout=20)
    log = run.stdout + run.stderr
    reports = [line.split("PROBE_RESULT ", 1)[1] for line in log.splitlines() if "PROBE_RESULT " in line]
    assert reports, log
    report = json.loads(reports[-1])
    assert report["failed"] == failed, report
    if payload != "not-json":
        assert report["status"] == json.loads(payload)["message"], report
    print("PASS saved-model test", payload, flush=True)
print(output)
