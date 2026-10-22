#!/usr/bin/env python3
"""Check the production UI transport with isolated argv and stdin recorders."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TEXT = "Private journal fixture: café 🐈\nSecond line\n"
TODO = "Private to-do fixture"
CONFIG_VALUE = "sk-private-config-fixture"


def function(source, name):
    start = source.index(f"function {name}(")
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


with tempfile.TemporaryDirectory(prefix="omaflow-private-transport-") as temporary:
    stage = Path(temporary)
    (stage / "ui").symlink_to(ROOT / "ui", target_is_directory=True)
    (stage / "Job.qml").write_bytes((ROOT / "hosts/omarchy/Job.qml").read_bytes())
    (stage / "Notifications.js").write_bytes((ROOT / "hosts/omarchy/Notifications.js").read_bytes())
    host = (ROOT / "hosts/omarchy/OmaFlow.qml").read_text()
    runtime = stage / "runtime"
    runtime.mkdir(mode=0o700)
    binary = Path(os.environ.get("OMAFLOW_BINARY", str(ROOT / "target/release/omaflow"))).resolve()
    home = stage / "home"
    home.mkdir()
    configuration = stage / "config.toml"
    cli_environment = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
        XDG_STATE_HOME=str(home / ".local/state"), XDG_RUNTIME_DIR=str(runtime), OMAFLOW_CONFIG=str(configuration))
    plugin = home / ".config/omarchy/plugins/entroit.omaflow"
    plugin.parent.mkdir(parents=True)
    plugin.symlink_to(ROOT, target_is_directory=True)
    configuration.write_text('[cleanup]\nenabled=' + json.dumps(CONFIG_VALUE) + '\n')
    invalid_config = subprocess.run([str(binary), "reload-config"], env=cli_environment,
        capture_output=True, text=True, timeout=10)
    assert invalid_config.returncode != 0 and CONFIG_VALUE not in invalid_config.stderr, invalid_config
    assert "Invalid configuration field type or value" in invalid_config.stderr, invalid_config
    # Even an unexpected private diagnostic must stay out of notification argv.
    (runtime / "config-error").write_text(invalid_config.stderr + CONFIG_VALUE)
    tools = stage / "bin"
    tools.mkdir()
    recorder = '''#!/usr/bin/python3
import json, os, sys
name = os.path.basename(sys.argv[0])
data = sys.stdin.read() if name in ("omaflow", "wl-copy") else ""
with open(os.environ["XDG_RUNTIME_DIR"] + "/calls.jsonl", "a") as target:
    target.write(json.dumps({"tool": name, "argv": sys.argv[1:], "stdin": data}, ensure_ascii=False) + "\\n")
args = json.loads(data) if name == "omaflow" else sys.argv[1:]
if args[:2] == ["journal", "due"]:
    print(json.dumps({"date":"2026-10-22", "notes":[{"written":"2026-10-20", "text": "Private journal fixture"}]}))
elif args[:2] == ["todos", "reminders"]:
    print(json.dumps({"reminders":[{"index":42, "text":"Private to-do fixture", "list":"Private list"}]}))
elif args[:2] == ["todos", "done"]:
    print(json.dumps({"error":"Private journal fixture"}))
elif args == ["reload-config"]:
    from pathlib import Path
    print(Path(os.environ["XDG_RUNTIME_DIR"], "config-error").read_text(), file=sys.stderr)
    sys.exit(1)
elif name == "notify-send":
    print("done" if "done=Done" in args else "default" if "default=Open settings" in args else "")
else:
    print('{"ok":true}')
'''
    for name in ("omaflow", "wl-copy", "notify-send"):
        tool = tools / name
        tool.write_text(recorder)
        tool.chmod(0o755)
    (stage / "shell.qml").write_text('''import QtQuick
import Quickshell
import "ui"
import "Notifications.js" as Notifications
ShellRoot {
  id: root
  property string shownPage: ""
  property string configError: ""
  function showWindow(page) { shownPage = page }
  ''' + "\n".join(function(host, name) for name in ("deliverNotes", "deliverReminders", "reloadConfig")) + '''
  App {
    id: flow
    onToast: function(message, error) { if (error) root.configError = message }
    host: QtObject {
      ''' + function(host, "spawn") + "\n" + function(host, "copy") + '''
    }
  }
  Component { id: jobComponent; Job {} }
  Timer {
    interval: 100; running: true
    onTriggered: {
      var text = ''' + json.dumps(TEXT, ensure_ascii=True) + '''
      flow.copy(text)
      flow.query(["journal", "edit", "2026-10-22", "42", text], function() {})
      flow.query(["journal", "add", text], function() {})
      flow.editHistory(42, text)
      root.deliverNotes()
      root.deliverReminders()
      root.reloadConfig()
    }
  }
  Timer {
    interval: 1800; running: true
    onTriggered: {
      if (root.shownPage === "settings" && root.configError.indexOf("sk-private-config-fixture") >= 0)
        console.log("OMAFLOW_PRIVATE_SETTINGS_ERROR_OK")
      Qt.quit()
    }
  }
}
''')
    environment = {key: value for key, value in os.environ.items() if key not in ("WAYLAND_DISPLAY", "DISPLAY")}
    result = subprocess.run(["quickshell", "-p", str(stage)], env=dict(environment,
        QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="", XDG_RUNTIME_DIR=str(runtime),
        XDG_STATE_HOME=str(stage / "state"), PATH=f"{tools}:/usr/bin"), capture_output=True, text=True, timeout=15)
    calls_path = runtime / "calls.jsonl"
    if result.returncode or not calls_path.exists():
        raise AssertionError(result.stdout + result.stderr)
    calls = [json.loads(line) for line in calls_path.read_text().splitlines()]
    leaked = [call["tool"] for call in calls if any("Private journal fixture" in arg or "Private to-do fixture" in arg or "Private list" in arg or CONFIG_VALUE in arg for arg in call["argv"])]
    assert not leaked, "Private fixture text appeared in process arguments: " + ", ".join(leaked)
    assert len(calls) == 12, (calls, result.stdout, result.stderr)
    copy = next(call for call in calls if call["tool"] == "wl-copy")
    assert copy["argv"] == ["--"] and copy["stdin"] == TEXT, copy
    requests = [call for call in calls if call["tool"] == "omaflow"]
    for call in requests:
        assert call["argv"] == ["--stdin"], call
    assert sorted(json.loads(call["stdin"]) for call in requests) == sorted([
        ["journal", "edit", "2026-10-22", "42", TEXT], ["journal", "add", TEXT], ["history-edit", "42", TEXT],
        ["journal", "due"], ["todos", "reminders"], ["todos", "done", "42", TODO], ["reload-config"]])
    notifications = [call for call in calls if call["tool"] == "notify-send"]
    assert len(notifications) == 4, notifications
    assert all(call["argv"][-3] == "--" for call in notifications), notifications
    assert sorted(call["argv"][-2:] for call in notifications) == sorted([
        ["A journal note is ready", "Open OmaFlow to read your note."],
        ["A to-do needs your attention", "Open OmaFlow to see your reminder."],
        ["A to-do is still open", "Open OmaFlow to try again."],
        ["config.toml was not applied", "Open OmaFlow to check your settings. The previous settings stay in use."]])
    assert "OMAFLOW_PRIVATE_SETTINGS_ERROR_OK" in result.stdout + result.stderr, result
    assert CONFIG_VALUE not in result.stdout + result.stderr, result
    print("PASS UI copy, journal add/edit and history edits keep exact Unicode text on stdin, outside argv; notifications omit private text and rejected configuration values")

    configuration.write_text('[journal]\nfolder=' + json.dumps(str(home / "Journal")) + '\n[todos]\nfolder=' + json.dumps(str(home / "To-dos")) + '\n')

    def command(arguments):
        completed = subprocess.run([str(binary), "--stdin"], input=json.dumps(arguments, ensure_ascii=False),
            env=cli_environment, capture_output=True, text=True, timeout=10)
        assert completed.returncode == 0, completed.stderr
        return json.loads(completed.stdout) if completed.stdout.strip() else None

    added = command(["journal", "add", TEXT, "2026-10-22"])
    assert added["entry"]["text"] == TEXT.strip(), added
    edited = "Edited café 🐈\nLast line"
    command(["journal", "edit", added["date"], str(added["entry"]["id"]), edited])
    day = command(["journal", "day", added["date"]])
    assert day["entries"][0]["text"] == edited, day
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(str(runtime / "omaflow.sock"))
        listener.listen()
        listener.settimeout(3)
        command(["history-edit", "42", TEXT])
        with listener.accept()[0] as connection:
            received = bytearray()
            while chunk := connection.recv(65536):
                received.extend(chunk)
    operation, payload = received.decode().split(":", 1)
    assert operation == "history-edit" and json.loads(payload) == {"id":42, "text":TEXT}, received
    for invalid in ("[]", "{}", '"not arguments"', "x" * (4 * 1024 * 1024 + 1)):
        refused = subprocess.run([str(binary), "--stdin"], input=invalid, env=cli_environment,
            capture_output=True, text=True, timeout=10)
        assert refused.returncode != 0 and "private command" in refused.stderr, refused
    print("PASS private CLI input preserves journal edits and exact history text over IPC; malformed and oversized inputs fail")
