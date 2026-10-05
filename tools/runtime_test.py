#!/usr/bin/env python3
"""Exercise daemon failure recovery with isolated state and stub desktop commands."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "target/release/omaflow"


def wait_until(predicate, timeout=3):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            if predicate():
                return
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.02)
    raise AssertionError("Condition did not become true before timeout")


with tempfile.TemporaryDirectory(prefix="omaflow-runtime-test-") as directory:
    base = Path(directory)
    commands = base / "bin"
    commands.mkdir()
    for name, source in {
        "wl-paste": "import sys; sys.exit(1)",
        "wl-copy": "import sys, os; from pathlib import Path; runtime=Path(os.environ[\"XDG_RUNTIME_DIR\"]); (runtime/\"copy-attempt\").write_bytes(sys.stdin.buffer.read()); sys.exit(0 if (runtime/\"clipboard-ok\").exists() else 1)",
        "hyprctl": (
            "import json, os, sys; from pathlib import Path\n"
            "runtime = Path(os.environ['XDG_RUNTIME_DIR'])\n"
            "with (runtime / 'hyprctl-log').open('a') as log: log.write(json.dumps(sys.argv[1:]) + chr(10))\n"
            "print('{\"address\":\"0xtest\",\"class\":\"test\"}')\n"
        ),
        "systemctl": "import os; from pathlib import Path; (Path(os.environ[\"XDG_RUNTIME_DIR\"])/\"model-command\").touch()",
        "ollama": "print('NAME ID SIZE')",
        "nvidia-smi": "pass",
        "curl": (
            "import os, sys; from pathlib import Path\n"
            "runtime = Path(os.environ['XDG_RUNTIME_DIR'])\n"
            "(runtime / 'model-command').touch()\n"
            "if (runtime / 'capture-fixture').exists() and (runtime / 'asr-fail').exists():\n"
            "    sys.exit(7)\n"
            "elif (runtime / 'capture-fixture').exists() and (runtime / 'asr-empty').exists():\n"
            "    print('{\"text\":\"\"}')\n"
            "elif (runtime / 'capture-fixture').exists():\n"
            "    form = next((sys.argv[index + 1] for index, value in enumerate(sys.argv[:-1]) if value == '--form' and sys.argv[index + 1].startswith('file=@')), 'file=@-')\n"
            "    source = form.split('@', 1)[1].split(';', 1)[0]\n"
            "    audio = sys.stdin.buffer.read() if source == '-' else Path(source).read_bytes()\n"
            "    (runtime / 'asr-request').write_bytes(audio)\n"
            "    print('{\"text\":\"Complete fixture transcript.\"}')\n"
            "else:\n"
            "    print('{}')\n"
        ),
        "pw-cat": (
            "import os, signal, sys, time; from pathlib import Path\n"
            "runtime = Path(os.environ['XDG_RUNTIME_DIR'])\n"
            "if '--playback' in sys.argv:\n"
            "    (runtime / 'playback').write_text(str(len(sys.stdin.buffer.read())))\n"
            "elif not (runtime / 'capture-fixture').exists():\n"
            "    time.sleep(120)\n"
            "else:\n"
            "    sys.stdout.buffer.write(b'\\x01\\x00' * 1600)\n"
            "    sys.stdout.buffer.flush()\n"
            "    def finish(_signal, _frame):\n"
            "        sys.stdout.buffer.write(b'\\x02\\x00' * 320)\n"
            "        sys.stdout.buffer.flush()\n"
            "        sys.exit(1)\n"
            "    signal.signal(signal.SIGINT, finish)\n"
            "    while True: time.sleep(.02)\n"
        ),
        "wpctl": (
            "import os, sys; from pathlib import Path\n"
            "runtime = Path(os.environ['XDG_RUNTIME_DIR'])\n"
            "if sys.argv[1] == 'get-volume':\n"
            "    print('Volume: 0.80')\n"
            "else:\n"
            "    with (runtime / 'volume-log').open('a') as log: log.write(sys.argv[-1] + chr(10))\n"
        ),
    }.items():
        path = commands / name
        path.write_text("#!/usr/bin/python3\n" + source + "\n")
        path.chmod(0o755)

    def run_case(name, fake, test, pending=False, backend=""):
        case = base / str(len(list(base.iterdir())))
        case.mkdir()
        runtime = case / "runtime"
        runtime.mkdir()
        config = case / "config.toml"
        # models_configured is explicit here: a fresh install now defaults it to
        # false, waiting on the background weights download, and every case but
        # the pending one is about a machine that is past that point.
        configured = "false" if pending else "true"
        # The journal folder always points into the case, never at ~/Documents.
        config.write_text(f'[cleanup]\nenabled=false\n[behavior]\nmodels_configured={configured}\nhistory_limit=30\ndouble_tap_ms=30\n[backend]\nstatus_timeout_ms=300\n{backend}\n[journal]\nfolder="{case / "Journal"}"\n[todos]\nfolder="{case / "To-dos"}"\n')
        env = dict(os.environ, PATH=f"{commands}:/usr/bin", XDG_RUNTIME_DIR=str(runtime),
                   XDG_STATE_HOME=str(case / "state"), OMAFLOW_CONFIG=str(config))
        env.pop("OMAFLOW_FAKE_TRANSCRIPT", None)
        if fake:
            env["OMAFLOW_FAKE_TRANSCRIPT"] = "This completed dictation must remain recoverable."
        with (case / "daemon.log").open("w") as log:
            process = subprocess.Popen([str(BINARY), "daemon"], env=env, stdout=log,
                                       stderr=log, start_new_session=True)
            def state():
                return json.loads((runtime / "omaflow-state.json").read_text())
            def send(text):
                with socket.socket(socket.AF_UNIX) as stream:
                    stream.connect(str(runtime / "omaflow.sock"))
                    stream.sendall(text.encode())
            try:
                wait_until(lambda: (runtime / "omaflow-state.json").exists())
                test(case, runtime, state, send)
                print("PASS", name)
            except Exception:
                print((case / "daemon.log").read_text())
                raise
            finally:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()

    def delivery(case, runtime, state, send):
        send("press")
        time.sleep(.06)
        send("release")
        wait_until(lambda: state()["phase"] == "result")
        assert state()["text"].startswith("This completed")
        assert len(state()["history"]) == 1
        assert state()["error"]
        assert (case / "state/omaflow/history.json").exists()
        assert not (case / "state/omaflow/training.jsonl").exists()
        send("history-clear")
        wait_until(lambda: len(state()["history"]) == 0)
        assert state()["can_undo_delete"]
        send("history-undo")
        wait_until(lambda: len(state()["history"]) == 1)
        send("history-copy:" + str(state()["history"][0]["id"]))
        wait_until(lambda: state()["feedback_error"])
        assert "clipboard" in state()["feedback"].lower() or "wl-copy" in state()["feedback"]
        (runtime / "clipboard-ok").touch()
        send("copy")
        wait_until(lambda: state()["error"] == "" and state()["feedback"] == "Copied to clipboard")

    def ipc(case, runtime, state, send):
        with socket.socket(socket.AF_UNIX) as blocker:
            blocker.connect(str(runtime / "omaflow.sock"))
            time.sleep(.03)
            send("press")
            wait_until(lambda: state()["phase"] == "recording", timeout=1)

    def stalled_capture(case, runtime, state, send):
        send("press")
        time.sleep(.15)
        send("cancel")
        wait_until(lambda: state()["phase"] == "idle")
        send("press")
        time.sleep(.15)
        send("release")
        wait_until(lambda: state()["phase"] == "notice")

    def drained_capture(case, runtime, state, send):
        (runtime / "capture-fixture").touch()
        send("press")
        wait_until(lambda: state()["phase"] == "recording")
        time.sleep(.08)
        send("release")
        wait_until(lambda: state()["phase"] == "result")
        assert state()["text"] == "Complete fixture transcript."
        request = (runtime / "asr-request").read_bytes()
        assert request.startswith(b"RIFF")
        pcm_bytes = int.from_bytes(request[40:44], "little")
        assert pcm_bytes == 3840
        assert request[44:44 + pcm_bytes] == (
            b"\x01\x00" * 1600 + b"\x02\x00" * 320
        )
        assert not (case / "state/omaflow/audio").exists(), "dictation audio is off by default"
        assert state()["history"][0]["audio"] is False

    def retry_failed(case, runtime, state, send):
        # The speech engine fails a complete recording: it is kept, and the
        # card waits for Try again instead of closing on a timer.
        (runtime / "capture-fixture").touch()
        (runtime / "asr-fail").touch()
        send("press")
        wait_until(lambda: state()["phase"] == "recording")
        time.sleep(.08)
        send("release")
        wait_until(lambda: state()["phase"] == "error")
        assert state()["can_retry"] is True, state()["error"]
        assert state()["error"].endswith("Your recording is kept."), state()["error"]
        assert state()["card_timer"] is None
        # Try again sends the same recording, and this time it goes through.
        (runtime / "asr-fail").unlink()
        send("retry")
        wait_until(lambda: state()["phase"] == "result" and state()["text"] == "Complete fixture transcript.")
        request = (runtime / "asr-request").read_bytes()
        assert int.from_bytes(request[40:44], "little") == 3840, "the whole recording, sent again"
        # Closing a failed card lets the recording go: nothing to try again.
        send("close")
        wait_until(lambda: state()["phase"] == "idle")
        (runtime / "asr-fail").touch()
        send("press")
        wait_until(lambda: state()["phase"] == "recording")
        time.sleep(.08)
        send("release")
        wait_until(lambda: state()["phase"] == "error" and state()["can_retry"])
        send("close")
        wait_until(lambda: state()["phase"] == "idle" and not state()["can_retry"])
        send("retry")
        time.sleep(.2)
        assert state()["phase"] == "idle"
        # The engine answers but hears no words: not a failure, nothing to
        # try again, and the quiet card goes by itself.
        (runtime / "asr-fail").unlink()
        (runtime / "asr-empty").touch()
        send("press")
        wait_until(lambda: state()["phase"] == "recording")
        time.sleep(.08)
        send("release")
        wait_until(lambda: state()["phase"] == "notice")
        assert state()["can_retry"] is False and state()["card_timer"]["total_ms"] > 0

    def settings(case, runtime, state, send):
        send('configure:{"key":"style","value":"verbatim"}')
        wait_until(lambda: state()["style"] == "verbatim")
        send('configure:{"key":"style","value":"invalid"}')
        wait_until(lambda: state()["feedback_error"])
        assert state()["style"] == "verbatim"
        send('configure:{"key":"not_a_setting","value":{}}')
        wait_until(lambda: state()["feedback"] == "Unknown setting")
        send('configure:{"key":"enabled","value":true}')
        wait_until(lambda: state()["cleanup_enabled"] and state()["style"] == "natural")
        assert "style" not in __import__("tomllib").loads((case/"config.toml").read_text())["cleanup"]
        send('configure:{"key":"enabled","value":false}')
        wait_until(lambda: not state()["cleanup_enabled"])
        result = subprocess.run([str(BINARY), "not-a-command"], capture_output=True, text=True, timeout=2)
        assert result.returncode != 0 and "unknown command" in result.stderr


    def models(case, runtime, state, send):
        update = {"speech_engine":"openai", "speech_model":"test-whisper", "speech_endpoint":"http://127.0.0.1:18765/v1/audio/transcriptions", "cleanup_engine":"openai", "cleanup_model":"test-cleanup", "cleanup_endpoint":"http://127.0.0.1:18765/v1/chat/completions"}
        send('configure:' + json.dumps({"key":"models","value":update}))
        wait_until(lambda: state()["model_settings"]["speech_model"] == "test-whisper")
        assert state()["cleanup_model"] == "test-cleanup"
        assert state()["model_settings"]["cleanup_engine"] == "openai"
        # A key goes in on stdin, never in the arguments, and is never published.
        env = dict(os.environ, OMAFLOW_CONFIG=str(case / "config.toml"), XDG_RUNTIME_DIR=str(runtime))
        subprocess.run([str(BINARY), "configure", "models", "-"], env=env, input='{"cleanup_api_key":"sk-stdin"}\n',
                       text=True, capture_output=True, timeout=5, check=True)
        wait_until(lambda: state()["model_settings"]["cleanup_api_key_set"] is True)
        assert "sk-stdin" not in (runtime / "omaflow-state.json").read_text()
        assert "sk-stdin" in (case/'config.toml').read_text()
        before = (case/'config.toml').read_bytes()
        send('configure:' + json.dumps({"key":"models","value":{"speech_engine":"unsupported"}}))
        wait_until(lambda: state()["feedback_error"])
        assert (case/'config.toml').read_bytes() == before
        send('press')
        wait_until(lambda: state()["phase"] == "recording")
        send('configure:' + json.dumps({"key":"models","value":{"cleanup_model":"other"}}))
        wait_until(lambda: 'before changing models' in state()["feedback"])
        assert state()["cleanup_model"] == "test-cleanup"
        send('cancel')
        wait_until(lambda: state()["phase"] == "idle")

    def no_saved_dictation(case, runtime, state, send):
        send('configure:{"key":"history_limit","value":0}')
        wait_until(lambda: state()["history_limit"] == 0)
        before = (case/'state/omaflow/history.json').read_bytes()
        send('press'); time.sleep(.06); send('release')
        wait_until(lambda: state()["phase"] == "result")
        assert state()["text"] and not state()["history"]
        assert (case/'state/omaflow/history.json').read_bytes() == before
        assert not (case/'state/omaflow/training.jsonl').exists()

    def pending_models(case, runtime, state, send):
        time.sleep(.2)
        assert state()["model_settings"]["configured"] is False
        assert not (runtime/"model-command").exists()
        send('configure:{"key":"models_configured","value":false}')
        wait_until(lambda: state()["model_settings"]["configured"] is False)
        send('press')
        wait_until(lambda: 'Models not configured' in state()["error"])
        assert state()["phase"] != "recording"
        send('close')
        send('configure:{"key":"models","value":{"speech_model":"saved-but-not-started"}}')
        wait_until(lambda: state()["model_settings"]["speech_model"] == 'saved-but-not-started')
        assert state()["model_settings"]["configured"] is False
        send('configure:{"key":"models_configured","value":true}')
        wait_until(lambda: state()["model_settings"]["configured"] is True)
        send('press')
        wait_until(lambda: state()["phase"] == 'recording')
        send('cancel')

    def failed_history_write(case, runtime, state, send):
        send("press"); time.sleep(.06); send("release")
        wait_until(lambda: len(state()["history"]) == 1)
        before = state()["history"]
        (case / "state/omaflow/history.json.tmp").mkdir()
        send("history-clear")
        wait_until(lambda: state()["feedback_error"])
        assert state()["history"] == before
        serial = state()["serial"]
        send("history-edit:" + json.dumps({"id": before[0]["id"], "text": "Unsaved change"}))
        wait_until(lambda: state()["serial"] > serial)
        assert state()["history"] == before

    def clipboard_only(case, runtime, state, send):
        (runtime / "clipboard-ok").touch()
        send("paste-mode:clipboard")
        wait_until(lambda: state()["paste_mode"] == "clipboard")
        send("press"); time.sleep(.06); send("release")
        wait_until(lambda: state()["phase"] == "result")
        assert not state()["history"][0]["pasted"] and not state()["error"]
        send("paste-last")
        wait_until(lambda: state()["feedback"] == "Copied to clipboard")
        assert not state()["feedback_error"]

    def custom_paste(case, runtime, state, send):
        (runtime / "clipboard-ok").touch()
        update = {
            "key": "paste_delivery",
            "value": {
                "mode": "custom",
                "shortcut": {"modifiers": ["shift", "ctrl"], "key": "F8"},
            },
        }
        send("configure:" + json.dumps(update))
        wait_until(lambda: state()["paste_mode"] == "custom")
        assert state()["paste_shortcut"] == {"modifiers": ["shift", "ctrl"], "key": "F8"}
        stored = __import__("tomllib").loads((case / "config.toml").read_text())
        assert stored["behavior"]["paste_mode"] == "custom"
        assert stored["behavior"]["paste_shortcut"] == {
            "modifiers": ["shift", "ctrl"], "key": "F8"
        }

        before = (case / "config.toml").read_bytes()
        malicious = {
            "key": "paste_delivery",
            "value": {
                "mode": "custom",
                "shortcut": {"modifiers": ["ctrl"], "key": 'V\"}); os.execute("bad")--'},
            },
        }
        send("configure:" + json.dumps(malicious))
        wait_until(lambda: state()["feedback_error"])
        assert (case / "config.toml").read_bytes() == before

        send("press"); time.sleep(.06); send("release")
        wait_until(lambda: state()["phase"] == "success")
        dispatches = [
            json.loads(line) for line in (runtime / "hyprctl-log").read_text().splitlines()
            if "send_key_state" in line
        ]
        assert dispatches
        script = dispatches[-1][1]
        assert 'mods = "CTRL SHIFT"' in script
        assert 'key = "F8"' in script
        assert "os.execute" not in script

    def audio_ducking(case, runtime, state, send):
        log = runtime / "volume-log"
        assert state()["duck_audio_percent"] == 70
        send("press")
        wait_until(lambda: state()["phase"] == "recording")
        # 80% of the sink, turned down by 70%, is 24%.
        wait_until(lambda: log.exists() and log.read_text().split()[0].startswith("0.24"))
        assert (runtime / "duck-restore").exists()
        send("cancel")
        wait_until(lambda: state()["phase"] != "recording")
        # Whatever else happens, the level the daemon found has to come back and
        # the crash-restore file has to go: a missed restore leaves a person
        # wondering why their speakers went quiet an hour ago.
        wait_until(lambda: log.read_text().split()[-1].startswith("0.8"))
        wait_until(lambda: not (runtime / "duck-restore").exists())

    def journal_take(case, runtime, state, send):
        send("journal-toggle")
        wait_until(lambda: state()["phase"] == "recording" and state()["journal_take"] and state()["latched"])
        send("journal-toggle")
        wait_until(lambda: state()["phase"] == "journal-saved")
        saved = state()["journal_saved"]
        day = case / "Journal" / (saved["date"] + ".md")
        text = day.read_text()
        assert "This completed dictation must remain recoverable." in text, text
        assert text.startswith("# ") and "<!-- omaflow:" + str(saved["id"]) + " -->" in text
        assert saved["words"] == 6 and state()["journal_revision"] == 1
        assert not state()["history"], "a journal entry is not a dictation"
        log = runtime / "hyprctl-log"
        assert not log.exists() or "send_key_state" not in log.read_text(), "a journal entry is never pasted"
        assert not (runtime / "copy-attempt").exists(), "nor copied"
        # Esc is pressed in other apps all the time; it must not end a take.
        send("journal-toggle")
        wait_until(lambda: state()["phase"] == "recording")
        send("close")
        time.sleep(.2)
        assert state()["phase"] == "recording"
        # Discard throws the take away and writes nothing.
        send("journal-discard")
        wait_until(lambda: state()["phase"] == "idle")
        time.sleep(.2)
        assert day.read_text() == text
        # A typed entry from the window goes straight to the file.
        env = dict(os.environ, OMAFLOW_CONFIG=str(case / "config.toml"), XDG_RUNTIME_DIR=str(runtime))
        added = json.loads(subprocess.run([str(BINARY), "journal", "add", "Typed from the window."],
                                          env=env, capture_output=True, text=True, timeout=5).stdout)
        listed = json.loads(subprocess.run([str(BINARY), "journal", "day", added["date"]],
                                           env=env, capture_output=True, text=True, timeout=5).stdout)
        assert [entry["typed"] for entry in listed["entries"]] == [False, True]
        found = json.loads(subprocess.run([str(BINARY), "journal", "search", "window"],
                                          env=env, capture_output=True, text=True, timeout=5).stdout)
        assert found["days"] == [added["date"]] and found["hits"][0]["matches"] == [[15, 6]]

    def todo_take(case, runtime, state, send):
        send("todo-toggle")
        wait_until(lambda: state()["phase"] == "recording" and state()["todo_take"] and not state()["journal_take"])
        send("todo-toggle")
        wait_until(lambda: state()["phase"] == "todos-saved")
        items = state()["todos_saved"]["items"]
        assert [item["text"] for item in items] == ["This completed dictation must remain recoverable"], items
        listed = (case / "To-dos" / "To-dos.md").read_text()
        assert "- [ ] This completed dictation must remain recoverable\n" in listed, listed
        assert not state()["history"], "to-dos are not a dictation"
        assert not (runtime / "copy-attempt").exists(), "nor copied"
        # Undo on the card takes exactly the capture back out.
        revision = state()["todos_revision"]
        send("todo-undo")
        wait_until(lambda: state()["todos_revision"] > revision and state()["phase"] == "idle")
        assert "- [ ]" not in (case / "To-dos" / "To-dos.md").read_text()
        # Held like the dictation key: letting go adds them.
        send("todo-press")
        wait_until(lambda: state()["phase"] == "recording" and state()["todo_take"])
        time.sleep(.1)
        send("todo-release")
        wait_until(lambda: state()["phase"] == "todos-saved")
        # Cancel throws a take away and adds nothing.
        send("todo-toggle")
        wait_until(lambda: state()["phase"] == "recording")
        send("todo-discard")
        wait_until(lambda: state()["phase"] == "idle")
        assert (case / "To-dos" / "To-dos.md").read_text().count("- [ ]") == 1
        # With lists: a take goes to the current list, and the card's list
        # chip moves it to another one, which becomes current.
        env = dict(os.environ, OMAFLOW_CONFIG=str(case / "config.toml"), XDG_RUNTIME_DIR=str(runtime))
        for name in ("Infra", "Dev"):
            subprocess.run([str(BINARY), "todos", "new-list", name], env=env, capture_output=True, timeout=5, check=True)
        send("todo-list:Infra")
        wait_until(lambda: state()["todo_list"] == "Infra")
        send("todo-toggle")
        wait_until(lambda: state()["phase"] == "recording")
        send("todo-toggle")
        wait_until(lambda: state()["phase"] == "todos-saved")
        assert state()["todos_saved"]["items"][0]["list"] == "Infra"
        send("todo-move:Dev")
        wait_until(lambda: state()["todos_saved"]["moved"] and state()["todo_list"] == "Dev")
        listed = json.loads(subprocess.run([str(BINARY), "todos", "list"], env=env, capture_output=True, text=True, timeout=5).stdout)
        assert [todo["list"] for todo in listed["todos"]] == ["", "Dev"], listed
        assert listed["current"] == "Dev"
        # The To-dos tab's Talk button names its list.
        send('todo-toggle:{"list":"Infra","due":"2026-10-09"}')
        wait_until(lambda: state()["phase"] == "recording" and state()["todo_list"] == "Infra")
        send("todo-toggle")
        wait_until(lambda: state()["phase"] == "todos-saved")
        saved = state()["todos_saved"]["items"][0]
        assert saved["list"] == "Infra" and saved["due"] == "2026-10-09", saved
        # The card's clock is published, stops while the card is pointed at,
        # and starts over when it is let go.
        timer = state()["card_timer"]
        assert timer["total_ms"] >= 5000 and 0 < timer["remaining_ms"] <= timer["total_ms"], timer
        send("card-hold")
        wait_until(lambda: state()["card_timer"]["remaining_ms"] is None)
        # Editing a to-do on the card: Esc ends the edit, not the card.
        send("card-edit")
        time.sleep(.1)
        send("close")
        time.sleep(.2)
        assert state()["phase"] == "todos-saved"
        send("todo-card-edit:" + json.dumps({"index": saved["index"], "text": saved["text"], "new_text": "Renew the certs"}))
        wait_until(lambda: state()["todos_saved"]["items"][0]["text"] == "Renew the certs")
        edited = state()["todos_saved"]["items"][0]
        assert edited["due"] == "2026-10-09" and edited["list"] == "Infra", "an edit keeps the date and list"
        assert "- [ ] Renew the certs 📅 2026-10-09" in (case / "To-dos" / "To-dos.md").read_text()
        send("card-resume")
        wait_until(lambda: state()["card_timer"]["remaining_ms"] is not None)
        # Taking out the last to-do on the card closes it, like Undo.
        send("todo-card-remove:" + json.dumps({"index": edited["index"], "text": edited["text"]}))
        wait_until(lambda: state()["phase"] == "idle")
        assert "Renew the certs" not in (case / "To-dos" / "To-dos.md").read_text()
        # A time said with the deadline becomes a reminder, handed out once.
        added = json.loads(subprocess.run([str(BINARY), "todos", "add", "Call Mira tomorrow at 3pm"], env=env,
                                          capture_output=True, text=True, timeout=5, check=True).stdout)["added"][0]
        assert added["text"] == "Call Mira" and added["time"] == "15:00", added
        assert f"- [ ] Call Mira ⏰ {added['due']} 15:00 📅 {added['due']}" in (case / "To-dos" / "To-dos.md").read_text()
        clock = time.strftime("%H:%M")
        today = time.strftime("%Y-%m-%d")
        subprocess.run([str(BINARY), "todos", "due", str(added["index"]), "Call Mira", today, clock], env=env,
                       capture_output=True, timeout=5, check=True)
        reminders = lambda: json.loads(subprocess.run([str(BINARY), "todos", "reminders"], env=env, capture_output=True,
                                                      text=True, timeout=5, check=True).stdout)["reminders"]
        assert [todo["text"] for todo in reminders()] == ["Call Mira"]
        assert reminders() == [], "once"
        # The card's own close button closes it even mid-edit.
        send("todo-toggle")
        wait_until(lambda: state()["phase"] == "recording")
        send("todo-toggle")
        wait_until(lambda: state()["phase"] == "todos-saved")
        send("card-edit")
        time.sleep(.1)
        send("dismiss")
        wait_until(lambda: state()["phase"] == "idle")

    def journal_recording(case, runtime, state, send):
        (runtime / "capture-fixture").touch()
        send("journal-toggle")
        wait_until(lambda: state()["phase"] == "recording")
        time.sleep(.08)
        send("journal-toggle")
        wait_until(lambda: state()["phase"] == "journal-saved")
        saved = state()["journal_saved"]
        journal = case / "Journal"
        wav = (journal / ".recordings" / saved["date"] / f'{saved["id"]}.wav').read_bytes()
        assert wav.startswith(b"RIFF") and len(wav) == 44 + 3840
        meta = json.loads((journal / ".omaflow" / (saved["date"] + ".json")).read_text())["entries"][str(saved["id"])]
        assert meta["duration_ms"] == 120 and meta["peaks"] and meta["raw_text"] == "Complete fixture transcript."
        assert "Complete fixture transcript." in (journal / (saved["date"] + ".md")).read_text()
        send("journal-play:" + json.dumps({"date": saved["date"], "id": saved["id"], "offset_ms": 60}))
        wait_until(lambda: (runtime / "playback").exists())
        assert int((runtime / "playback").read_text()) == 1920, "playback starts at the offset"
        wait_until(lambda: state()["journal_playback"] is None)
        # Turning recordings off deletes them; the entry and its words stay.
        send('configure:{"key":"journal_keep_recordings","value":false}')
        wait_until(lambda: state()["journal_settings"]["keep_recordings"] is False)
        wait_until(lambda: not (journal / ".recordings").exists())
        assert "Complete fixture transcript." in (journal / (saved["date"] + ".md")).read_text()

    def dictation_audio(case, runtime, state, send):
        (runtime / "capture-fixture").touch()
        send('configure:{"key":"keep_dictation_audio","value":true}')
        wait_until(lambda: state()["keep_dictation_audio"])
        send("press"); time.sleep(.08); send("release")
        wait_until(lambda: state()["phase"] == "result")
        entry = state()["history"][0]
        audio = case / "state/omaflow/audio" / f'{entry["id"]}.wav'
        assert entry["audio"] and audio.read_bytes().startswith(b"RIFF")
        send("history-play:" + json.dumps({"id": entry["id"]}))
        wait_until(lambda: (runtime / "playback").exists())
        assert int((runtime / "playback").read_text()) == 3840
        # Deleting keeps the recording while Undo is offered.
        send("history-delete:" + str(entry["id"]))
        wait_until(lambda: not state()["history"])
        assert audio.exists()
        send("history-undo")
        wait_until(lambda: state()["history"] and state()["history"][0]["audio"])
        # Switching the setting off deletes what was kept.
        send('configure:{"key":"keep_dictation_audio","value":false}')
        wait_until(lambda: not state()["keep_dictation_audio"])
        wait_until(lambda: not audio.exists())
        assert state()["history"][0]["audio"] is False

    run_case(
        "dictation audio is kept only when asked, played back, and deleted with its dictation",
        False,
        dictation_audio,
        backend='engine="openai"\nendpoint="http://fixture.invalid/transcribe"\n',
    )
    run_case("a journal take is written to the day's file, never pasted", True, journal_take)
    run_case("a to-do take is added to the list, and Undo takes it back out", True, todo_take)
    run_case(
        "a spoken journal entry keeps its recording and plays it back",
        False,
        journal_recording,
        backend='engine="openai"\nendpoint="http://fixture.invalid/transcribe"\n',
    )
    run_case("history changes survive failed storage without false success", True, failed_history_write)
    run_case("dictation ducks the sink and always restores it", False, audio_ducking)
    run_case("clipboard-only delivery never reports a paste", True, clipboard_only)
    run_case("custom paste saves atomically and injects only a validated chord", True, custom_paste)
    run_case("clipboard failure retains text; clear undo; copy errors", True, delivery)
    run_case("incomplete IPC client cannot block controls", True, ipc)
    run_case("cancel stalled capture then record again", False, stalled_capture)
    run_case(
        "stop drains final recorder bytes into the transcription request",
        False,
        drained_capture,
        backend='engine="openai"\nendpoint="http://fixture.invalid/transcribe"\n',
    )
    run_case(
        "a failed transcription keeps its recording, and Try again sends it again",
        False,
        retry_failed,
        backend='engine="openai"\nendpoint="http://fixture.invalid/transcribe"\n',
    )
    run_case("validated dictation preferences; unknown settings and commands rejected", True, settings)

    run_case("atomic model switching and busy-session rejection", True, models)

    run_case("deferred models block recording until explicitly enabled", True, pending_models, pending=True)

    run_case("history disabled writes no dictated text or training sample", True, no_saved_dictation)
