#!/usr/bin/env python3
"""Exercise managed speech identity with real sockets and synthetic audio."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import queue
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import wave

from namespace_probe import namespace_available

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("OMAFLOW_TEST_BINARY", ROOT / "target/release/omaflow"))
PCM = b"\x01\x40" * 1600
KEY = "synthetic-speech-credential"
TEXT = "Synthetic private cleanup input."


def listener(port, uid, replace, record_connections=False):
    if uid != os.geteuid():
        os.setgroups([])
        os.setgid(uid)
        os.setuid(uid)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.record()
            if replace:
                self.server.server_close()
                child = subprocess.Popen(
                    [sys.executable, __file__, "--listen", str(self.server.server_port),
                     str(uid), "0"], stdout=subprocess.PIPE, text=True)
                print(json.dumps({"replacement": child.pid,
                                  "ready": json.loads(child.stdout.readline())}), flush=True)
                threading.Thread(target=lambda: [print(line.strip(), flush=True)
                                                 for line in child.stdout], daemon=True).start()
            self.reply({"status": "ready"})

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.record(audio=PCM in body, transcript=TEXT.encode() in body, bytes=len(body))
            self.reply({"text": "Synthetic recording.",
                        "message": {"content": "Synthetic cleanup output."},
                        "done": True, "done_reason": "stop",
                        "choices": [{"message": {"content": "Synthetic cleanup output."},
                                     "finish_reason": "stop"}]})

        def record(self, **fields):
            print(json.dumps({"pid": os.getpid(),
                              "path": self.path,
                              "credential": self.headers.get("Authorization") == f"Bearer {KEY}",
                              **fields}), flush=True)

        def reply(self, body):
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)

    class Server(HTTPServer):
        def get_request(self):
            stream, address = super().get_request()
            if record_connections:
                stream.settimeout(5)
                print(json.dumps({"received_bytes": bool(stream.recv(1, socket.MSG_PEEK))}), flush=True)
            return stream, address

    server = Server(("127.0.0.1", port), Handler)
    print(json.dumps({"port": server.server_port, "pid": os.getpid()}), flush=True)
    if replace:
        # Keep the original service PID alive after replacing its listener.
        server.handle_request()
        time.sleep(30)
    else:
        server.serve_forever(poll_interval=.02)


@contextmanager
def serving(uid, replace=False, namespace=True, record_connections=False):
    command = [sys.executable, __file__, "--listen", "0", str(uid), str(int(replace)),
               str(int(record_connections))]
    if uid != os.geteuid() and namespace:
        command = ["unshare", "--user", "--map-auto", "--map-root-user", "--"] + command
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    events = []
    ready = queue.Queue()

    def read():
        for line in process.stdout:
            event = json.loads(line)
            events.append(event)
            if "port" in event:
                ready.put(event)

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    try:
        yield ready.get(timeout=5), events
    finally:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        reader.join(timeout=2)
        process.stdout.close()
        process.stderr.close()


def suite(cross_user):
    with tempfile.TemporaryDirectory(prefix="omaflow-speech-identity-") as directory:
        base = Path(directory)
        runtime = base / "runtime"
        runtime.mkdir(mode=0o700)
        commands = base / "bin"
        commands.mkdir()
        systemctl = commands / "systemctl"
        systemctl.write_text(
            "#!/usr/bin/python3\nimport os,sys\nfrom pathlib import Path\n"
            "if 'show' in sys.argv: print(Path(os.environ['TEST_SERVICE_PID']).read_text())\n"
            "else: sys.exit(1)\n")
        systemctl.chmod(0o755)
        for name in ["ollama", "hyprctl", "nvidia-smi", "pw-cat", "pw-play"]:
            command = commands / name
            command.write_text("#!/usr/bin/bash\nexit 1\n")
            command.chmod(0o755)
        wpctl = commands / "wpctl"
        wpctl.write_text('#!/usr/bin/bash\nprintf \' * node.description = "IdentityFixture"\\n\'\n')
        wpctl.chmod(0o755)
        model = base / "model.gguf"
        model.touch()
        recording = base / "recording.wav"
        with wave.open(str(recording), "wb") as wav:
            wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            wav.writeframes(PCM)
        config = base / "config.toml"
        pid_file = base / "service-pid"
        env = dict(os.environ, HOME=str(base), XDG_RUNTIME_DIR=str(runtime),
                   XDG_CONFIG_HOME=str(base / "config"), XDG_DATA_HOME=str(base / "data"),
                   XDG_CACHE_HOME=str(base / "cache"), XDG_STATE_HOME=str(base / "state"),
                   OMAFLOW_CONFIG=str(config), TEST_SERVICE_PID=str(pid_file),
                   PATH=f"{commands}:/usr/bin")

        def run(service, expected_pid, configured=True, engine="nemo"):
            pid_file.write_text(str(expected_pid))
            config.write_text(
                f'[behavior]\nmodels_configured={str(configured).lower()}\n'
                f'[backend]\nengine="{engine}"\nmodel={json.dumps(str(model))}\n'
                f'endpoint="http://127.0.0.1:{service["port"]}/v1/audio/transcriptions"\n'
                f'api_key="{KEY}"\n'
                'status_timeout_ms=2000\n[cleanup]\nenabled=false\n')
            return subprocess.run([str(BINARY), "transcribe-file", str(recording)],
                                  env=env, text=True, capture_output=True, timeout=10)

        def configure_cleanup(service, expected_pid, engine="ollama"):
            pid_file.write_text(str(expected_pid))
            path = "/api/chat" if engine == "ollama" else "/v1/chat/completions"
            config.write_text(
                '[behavior]\nmodels_configured=true\nkeep_models_loaded=false\n'
                '[backend]\nengine="openai"\nendpoint="http://127.0.0.1:9/transcribe"\n'
                f'[cleanup]\nenabled=true\nengine="{engine}"\n'
                f'endpoint="http://127.0.0.1:{service["port"]}{path}"\n'
                f'api_key="{KEY}"\ntimeout_seconds=2\n')

        def probe_cleanup(service, expected_pid):
            configure_cleanup(service, expected_pid)
            state = runtime / "omaflow-state.json"
            state.unlink(missing_ok=True)
            daemon = subprocess.Popen([str(BINARY), "daemon"], env=env,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    assert daemon.poll() is None, daemon.communicate()
                    if state.exists():
                        snapshot = json.loads(state.read_text())
                        if snapshot.get("input_device") == "IdentityFixture":
                            return snapshot
                    time.sleep(.02)
                raise AssertionError("The daemon did not complete a model status probe")
            finally:
                daemon.terminate()
                daemon.communicate(timeout=5)

        failures = []
        with serving(os.geteuid()) as (service, events):
            result = run(service, service["pid"])
            assert result.returncode == 0 and result.stdout.strip() == "Synthetic recording.", result.stderr
            assert any(event.get("audio") and event.get("credential") for event in events), events
        print("PASS the authenticated managed service receives the complete synthetic WAV")

        for configured in (True, False):
            with serving(os.geteuid()) as (service, events):
                result = run(service, os.getpid(), configured=configured)
                if result.returncode == 0 or any(event.get("audio") or event.get("credential") for event in events):
                    failures.append(f"unmanaged listener received private data, models_configured={configured}")
        if not failures:
            print("PASS neither health success nor incomplete setup bypasses managed service identity")

        with serving(os.geteuid(), replace=True) as (service, events):
            result = run(service, service["pid"])
            assert any("replacement" in event for event in events), (events, result.stderr)
            if result.returncode == 0 or any(
                    event.get("pid") != service["pid"] and (event.get("audio") or event.get("credential"))
                    for event in events):
                failures.append("replacement listener received audio after trusted health succeeded")
            else:
                print("PASS a replacement listener receives no WAV after trusted health succeeds")

        if cross_user:
            for engine in ("nemo", "openai"):
                with serving(1) as (service, events):
                    result = run(service, service["pid"], engine=engine)
                    if result.returncode == 0 or any(event.get("audio") or event.get("credential") for event in events):
                        failures.append(f"another Unix user received audio through {engine}")
                    else:
                        print(f"PASS {engine} refuses an actual different-UID listener before audio")

            for engine in ("ollama", "openai"):
                with serving(1) as (service, events):
                    configure_cleanup(service, os.getpid(), engine)
                    result = subprocess.run([str(BINARY), "cleanup"], input=TEXT, env=env,
                                            text=True, capture_output=True, timeout=6)
                    if result.returncode == 0 or any(event.get("transcript") or event.get("credential") for event in events):
                        failures.append(f"another Unix user received private cleanup data through {engine}")
                    else:
                        print(f"PASS {engine} refuses an actual different-UID listener before private cleanup data")

            with serving(1) as (service, events):
                configure_cleanup(service, service["pid"])
                result = subprocess.run([str(BINARY), "cleanup"], input=TEXT, env=env,
                                        text=True, capture_output=True, timeout=6)
                assert result.returncode == 0 and result.stdout == "Synthetic cleanup output.", result.stderr
                assert any(event.get("transcript") and event.get("credential") for event in events), events
            print("PASS the known system Ollama account receives the intended cleanup request")

            for trusted in (False, True):
                with serving(1) as (service, events):
                    snapshot = probe_cleanup(service, service["pid"] if trusted else os.getpid())
                    if trusted:
                        assert snapshot["cleanup_available"]
                        assert {event.get("path") for event in events if event.get("credential")} >= {"/api/tags", "/api/ps"}, events
                    elif snapshot["cleanup_available"] or any(event.get("credential") for event in events):
                        failures.append("background cleanup probes sent credentials to another Unix user")
            print("PASS background cleanup probes authenticate the server before sending credentials")
        else:
            print("SKIP different-UID listener cases: subordinate user namespaces unavailable")
        assert not failures, "; ".join(failures)


def uid_mapping_suite():
    with tempfile.TemporaryDirectory(prefix="omaflow-uid-identity-") as directory:
        base = Path(directory)
        commands = base / "bin"
        commands.mkdir()
        systemctl = commands / "systemctl"
        systemctl.write_text('#!/usr/bin/python3\nimport os\nprint(os.environ["TEST_SERVICE_PID"])\n')
        systemctl.chmod(0o755)
        config = base / "config.toml"
        env = dict(os.environ, HOME=str(base), OMAFLOW_CONFIG=str(config),
                   XDG_CONFIG_HOME=str(base / "config"), XDG_DATA_HOME=str(base / "data"),
                   XDG_CACHE_HOME=str(base / "cache"), XDG_STATE_HOME=str(base / "state"),
                   XDG_RUNTIME_DIR=str(base / "runtime"), PATH=f"{commands}:/usr/bin")
        # These nested namespace clients are not systemd service invocations.
        env.pop("INVOCATION_ID", None)
        overflow = int(Path("/proc/sys/kernel/overflowuid").read_text())
        cases = [
            ("unmapped accounts", [], False),
            ("explicit overflow mapping", ["--map-users", f"{overflow}:2:1"], False),
            ("distinct mapped accounts", ["--map-users", "1:1:2"], False),
            ("mapped service account", ["--map-users", "1:1:2"], True),
        ]
        for label, mapping, trusted in cases:
            with serving(1, namespace=False, record_connections=True) as (service, events), \
                    serving(2, namespace=False) as (other, _):
                config.write_text(
                    '[cleanup]\nenabled=true\nengine="ollama"\nmodel="fixture"\n'
                    f'endpoint="http://127.0.0.1:{service["port"]}/api/chat"\n'
                    f'api_key="{KEY}"\ntimeout_seconds=2\n')
                result = subprocess.run(
                    ["unshare", "--user", "--map-root-user", *mapping, "--", str(BINARY), "cleanup"],
                    input=TEXT, env=env | {"TEST_SERVICE_PID": str((service if trusted else other)["pid"])},
                    capture_output=True, text=True, timeout=6)
            received = [event["received_bytes"] for event in events if "received_bytes" in event]
            assert received, (label, result.stderr)
            if trusted:
                assert result.returncode == 0 and result.stdout == "Synthetic cleanup output.", result.stderr
                assert any(event.get("transcript") and event.get("credential") for event in events)
            else:
                assert result.returncode != 0 and not any(received), (label, result.returncode, received)
            print(f"PASS namespace connection identity: {label}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--listen":
        listener(int(sys.argv[2]), int(sys.argv[3]), bool(int(sys.argv[4])),
                 len(sys.argv) > 5 and bool(int(sys.argv[5])))
    elif "--uid-mapping" in sys.argv:
        uid_mapping_suite()
    else:
        namespace = ["unshare", "--user", "--map-auto", "--map-root-user", "--"]
        available = namespace_available(namespace + ["true"])
        suite(available)
        if available:
            subprocess.run(namespace + [sys.executable, __file__, "--uid-mapping"], check=True, timeout=30)
