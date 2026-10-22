#!/usr/bin/env python3
"""Keep downloader output out of diagnostics and bound queued progress data."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

from namespace_probe import namespace_available

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("OMAFLOW_TEST_BINARY", ROOT / "target/release/omaflow"))
NOTIFIER = Path("/usr/share/omarchy/bin/omarchy-notification-send")
SECRET = "SYNTHETIC_PRIVATE_DOWNLOAD_RESPONSE"


def notification_root(root):
    global BINARY
    for directory in ["usr", "proc", "dev", "tmp"]:
        (root / directory).mkdir()
    (root / "tmp").chmod(0o1777)
    (root / "lib").symlink_to("usr/lib")
    (root / "lib64").symlink_to("usr/lib")
    subprocess.run(["mount", "-t", "proc", "-o", "ro", "proc", str(root / "proc")],
                   check=True, capture_output=True)
    for source in [Path("/usr"), Path("/dev/null"), BINARY]:
        target = root / ("omaflow" if source == BINARY else str(source).lstrip("/"))
        if source.is_file() or source == Path("/dev/null"):
            target.touch()
        subprocess.run(["mount", "--bind", str(source), str(target)], check=True,
                       capture_output=True)
        subprocess.run(["mount", "-o", "remount,bind,ro", str(target)], check=True,
                       capture_output=True)
    os.chroot(root)
    os.chdir("/")
    BINARY = Path("/omaflow")


@contextmanager
def progress_socket(path):
    messages = []
    stopped = threading.Event()
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(str(path))
        listener.listen()
        listener.settimeout(.1)

        def receive():
            while not stopped.is_set():
                try:
                    stream, _ = listener.accept()
                except TimeoutError:
                    continue
                with stream:
                    stream.settimeout(1)
                    chunks = []
                    while chunk := stream.recv(65536):
                        chunks.append(chunk)
                    messages.append(b"".join(chunks).decode())

        worker = threading.Thread(target=receive, daemon=True)
        worker.start()
        try:
            yield messages
        finally:
            stopped.set()
            worker.join(timeout=2)


def peak_memory(env, mode):
    process = subprocess.Popen([str(BINARY), "model-install", "cleanup", "gemma4:e4b"],
                               env=env | {"TEST_DOWNLOAD_MODE": mode},
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               start_new_session=True)
    peak = 0
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            assert process.poll() is None, process.communicate()
            for line in Path(f"/proc/{process.pid}/status").read_text().splitlines():
                if line.startswith("VmRSS:"):
                    peak = max(peak, int(line.split()[1]))
            time.sleep(.02)
    finally:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=5)
    assert peak > 0
    return peak


def suite(isolate_notifier=False):
    with tempfile.TemporaryDirectory(prefix="omaflow-download-privacy-") as directory:
        home = Path(directory)
        runtime = home / "runtime"
        runtime.mkdir(mode=0o700)
        commands = home / "bin"
        commands.mkdir()
        config = home / "config.toml"
        config.write_text("")
        notifier = commands / "notify-send"
        notifier.write_text(
            '#!/usr/bin/python3\nimport json,os,sys\nfrom pathlib import Path\n'
            'Path(os.environ["TEST_NOTIFICATION"]).write_text(json.dumps(sys.argv))\n')
        notifier.chmod(0o755)
        ollama = commands / "ollama"
        ollama.write_text(
            '#!/usr/bin/python3\nimport os,sys,time\n'
            'mode=os.environ["TEST_DOWNLOAD_MODE"]\n'
            'if mode in ("quiet", "flood"):\n'
            '    if mode == "flood":\n'
            '        for _ in range(4096): os.write(2, b"x" * 8190 + b"\\n")\n'
            '    time.sleep(60)\n'
            f'print({SECRET!r}, file=sys.stderr)\n'
            'sys.exit(1 if mode == "failure" else 0)\n')
        ollama.chmod(0o755)
        env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(runtime),
                   XDG_CONFIG_HOME=str(home / "config"), XDG_CACHE_HOME=str(home / "cache"),
                   XDG_STATE_HOME=str(home / "state"), XDG_DATA_HOME=str(home / "data"),
                   OMAFLOW_CONFIG=str(config), TEST_NOTIFICATION=str(home / "notification.json"),
                   PATH=f"{commands}:/usr/bin")
        safe_notifications = not NOTIFIER.exists()
        if isolate_notifier:
            mounted = subprocess.run(["mount", "--bind", str(notifier), str(NOTIFIER.resolve())],
                                     capture_output=True, text=True)
            if mounted.returncode != 0:
                raise SystemExit(77)
            safe_notifications = True

        with progress_socket(runtime / "omaflow.sock") as messages:
            if safe_notifications:
                for mode in ["failure", "success"]:
                    messages.clear()
                    notification = home / "notification.json"
                    notification.unlink(missing_ok=True)
                    result = subprocess.run(
                        [str(BINARY), "model-install", "cleanup", "gemma4:e4b"],
                        env=env | {"TEST_DOWNLOAD_MODE": mode}, text=True,
                        capture_output=True, timeout=10)
                    assert (result.returncode != 0) == (mode == "failure"), result.stderr
                    assert SECRET not in result.stdout + result.stderr, "Downloader response leaked into CLI output"
                    assert notification.exists(), result.stderr
                    args = json.loads(notification.read_text())
                    assert SECRET not in json.dumps(args), args
                    deadline = time.monotonic() + 2
                    state = "failed" if mode == "failure" else "done"
                    while not any(f'"state":"{state}"' in item for item in messages):
                        assert time.monotonic() < deadline, messages
                        time.sleep(.02)
                    assert SECRET not in "\n".join(messages), messages
                print("PASS download success/failure omit child response text from logs, progress and notification arguments")
            else:
                print("SKIP notification cases: the installed sender could not be isolated")
                unit = subprocess.run(
                    ["cargo", "test", "--locked", "--bin", "omaflow",
                     "catalog::tests::download_output_queue_applies_backpressure", "--", "--exact"],
                    cwd=ROOT, check=True, text=True, capture_output=True)
                assert "1 passed" in unit.stdout, unit.stdout + unit.stderr

            quiet = peak_memory(env, "quiet")
            flooded = peak_memory(env, "flood")
            assert flooded < quiet + 16 * 1024, (quiet, flooded)
            print(f"PASS queued downloader output stays bounded with an undrained log pipe: {quiet} KiB quiet, {flooded} KiB flooded")


def main():
    assert BINARY.is_file(), "Build the release binary before running this test"
    if "--isolated-notifications" in sys.argv:
        try:
            notification_root(Path(sys.argv[-1]))
        except (subprocess.CalledProcessError, PermissionError):
            raise SystemExit(77)
        suite(isolate_notifier=True)
    elif NOTIFIER.exists():
        command = ["unshare", "--user", "--map-root-user", "--mount", "--net", "--pid", "--fork", "--"]
        available = namespace_available(command + ["true"])
        if available:
            with tempfile.TemporaryDirectory(prefix="omaflow-download-root-") as root:
                result = subprocess.run(command + [sys.executable, __file__, "--isolated-notifications", root],
                                        timeout=45)
            if result.returncode == 77:
                suite()
            else:
                result.check_returncode()
        else:
            suite()
    else:
        suite()


if __name__ == "__main__":
    main()
