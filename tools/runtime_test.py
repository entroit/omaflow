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
        "hyprctl": "print('{\"address\":\"0xtest\",\"class\":\"test\"}')",
        "systemctl": "import os; from pathlib import Path; (Path(os.environ[\"XDG_RUNTIME_DIR\"])/\"model-command\").touch()",
        "ollama": "print('NAME ID SIZE')",
        "nvidia-smi": "pass",
        "curl": "import os; from pathlib import Path; (Path(os.environ[\"XDG_RUNTIME_DIR\"])/\"model-command\").touch(); print('{}')",
        "pw-cat": "import time; time.sleep(120)",
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

    def run_case(name, fake, test, pending=False):
        case = base / str(len(list(base.iterdir())))
        case.mkdir()
        runtime = case / "runtime"
        runtime.mkdir()
        config = case / "config.toml"
        # models_configured is explicit here: a fresh install now defaults it to
        # false, waiting on the background weights download, and every case but
        # the pending one is about a machine that is past that point.
        configured = "false" if pending else "true"
        config.write_text(f'[cleanup]\nenabled=false\n[behavior]\nmodels_configured={configured}\nhistory_limit=30\ndouble_tap_ms=30\n[backend]\nstatus_timeout_ms=300\n')
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
        update = {"speech_engine":"openai", "speech_model":"test-whisper", "speech_endpoint":"http://127.0.0.1:18765/v1/audio/transcriptions", "cleanup_model":"test-cleanup"}
        send('configure:' + json.dumps({"key":"models","value":update}))
        wait_until(lambda: state()["model_settings"]["speech_model"] == "test-whisper")
        assert state()["cleanup_model"] == "test-cleanup"
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

    run_case("history changes survive failed storage without false success", True, failed_history_write)
    run_case("dictation ducks the sink and always restores it", False, audio_ducking)
    run_case("clipboard-only delivery never reports a paste", True, clipboard_only)
    run_case("clipboard failure retains text; clear undo; copy errors", True, delivery)
    run_case("incomplete IPC client cannot block controls", True, ipc)
    run_case("cancel stalled capture then record again", False, stalled_capture)
    run_case("validated dictation preferences; unknown settings and commands rejected", True, settings)

    run_case("atomic model switching and busy-session rejection", True, models)

    run_case("deferred models block recording until explicitly enabled", True, pending_models, pending=True)

    run_case("history disabled writes no dictated text or training sample", True, no_saved_dictation)
