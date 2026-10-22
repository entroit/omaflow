#!/usr/bin/env python3
"""Exercise private state writes against planted links with an isolated daemon."""
import contextlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest

from namespace_probe import namespace_available


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "target/release/omaflow"


def wait_until(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.02)
    raise AssertionError("Daemon did not reach the expected state")


@contextlib.contextmanager
def daemon(plant):
    with tempfile.TemporaryDirectory(prefix="omaflow-private-storage-") as directory:
        home = Path(directory)
        runtime = home / "runtime"
        runtime.mkdir(mode=0o700)
        state = home / "state/omaflow"
        state.mkdir(parents=True, mode=0o700)
        commands = home / "bin"
        commands.mkdir()
        for name, source in {
            "curl": "exit 1",
            "systemctl": "exit 1",
            "wl-copy": "cat >/dev/null",
            "wl-paste": "exit 1",
            "notify-send": "exit 0",
            "hyprctl": "echo '{}'",
            "ollama": "echo 'NAME ID SIZE'",
            "nvidia-smi": "exit 1",
            "wpctl": "echo 'Volume: 0.8'",
        }.items():
            command = commands / name
            command.write_text("#!/bin/sh\n" + source + "\n")
            command.chmod(0o755)
        config = home / "config.toml"
        config.write_text(
            '[cleanup]\nenabled=false\n[behavior]\nmodels_configured=true\n'
            'keep_models_loaded=false\ntraining_log_enabled=true\nhistory_limit=10\n'
            f'double_tap_ms=30\n[journal]\nfolder="{home / "Journal"}"\n'
            f'[todos]\nfolder="{home / "To-dos"}"\n'
        )
        plant(home, runtime, state)
        env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(runtime),
                   XDG_CONFIG_HOME=str(home / "config"), XDG_CACHE_HOME=str(home / "cache"),
                   XDG_DATA_HOME=str(home / "data"),
                   XDG_STATE_HOME=str(home / "state"), OMAFLOW_CONFIG=str(config),
                   OMAFLOW_FAKE_TRANSCRIPT="Private dictation for the storage regression.",
                   PATH=f"{commands}:/usr/bin")
        with (home / "daemon.log").open("w") as log:
            process = subprocess.Popen([str(BINARY), "daemon"], env=env,
                                       stdout=log, stderr=log, start_new_session=True)
            def snapshot():
                return json.loads((runtime / "omaflow-state.json").read_text())
            def send(command):
                with socket.socket(socket.AF_UNIX) as stream:
                    stream.connect(str(runtime / "omaflow.sock"))
                    stream.sendall(command.encode())
            try:
                wait_until(lambda: (runtime / "omaflow-state.json").exists())
                yield home, runtime, state, snapshot, send
            finally:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()


class PrivateStorageTests(unittest.TestCase):
    def test_download_cancellation_rejects_untrusted_markers(self):
        for planted in ("writable-directory", "symlink", "hardlink", "public-file", "fifo", "oversized", "valid"):
            with self.subTest(planted=planted), tempfile.TemporaryDirectory(prefix="omaflow-cancel-") as directory:
                home = Path(directory)
                runtime = home / "runtime"
                runtime.mkdir(mode=0o700)
                process = subprocess.Popen(["sleep", "30"], start_new_session=True)
                try:
                    target = home / "target"
                    target.write_text(f"{process.pid}\nfalse\n")
                    target.chmod(0o600)
                    marker = runtime / "omaflow-download-speech-nvidia_parakeet_tdt_0_6b_v3"
                    if planted == "symlink":
                        marker.symlink_to(target)
                    elif planted == "hardlink":
                        os.link(target, marker)
                    elif planted == "fifo":
                        os.mkfifo(marker, 0o600)
                    else:
                        marker.write_text(target.read_text() + ("x" * 128 if planted == "oversized" else ""))
                        marker.chmod(0o644 if planted == "public-file" else 0o600)
                    if planted == "writable-directory":
                        runtime.chmod(0o777)
                    result = subprocess.run(
                        [str(BINARY), "model-cancel", "speech", "nvidia/parakeet-tdt-0.6b-v3"],
                        env=dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(runtime)),
                        capture_output=True, text=True, timeout=3,
                    )
                    if planted == "valid":
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(process.wait(timeout=2), -signal.SIGTERM)
                        self.assertFalse(marker.exists())
                    else:
                        self.assertNotEqual(result.returncode, 0, result.stderr)
                        time.sleep(.05)
                        self.assertIsNone(process.poll(), "an untrusted marker killed an unrelated process")
                        self.assertTrue(marker.exists())
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait()

    def test_meter_and_audio_restore_preserve_link_targets(self):
        for link in (os.symlink, os.link):
            with self.subTest(link=link.__name__):
                def plant(home, runtime, _state):
                    victim = home / "private.txt"
                    victim.write_text("Keep this private file intact.")
                    for name in ("omaflow-level", "duck-restore"):
                        link(victim, runtime / name)
                with daemon(plant) as (home, runtime, _state, snapshot, send):
                    send("press")
                    wait_until(lambda: snapshot()["phase"] == "recording")
                    wait_until(lambda: (runtime / "duck-restore").read_text() == "0.8000")
                    self.assertEqual((home / "private.txt").read_text(),
                                     "Keep this private file intact.")
                    self.assertEqual((runtime / "omaflow-level").stat().st_mode & 0o777, 0o600)

    def test_state_publication_preserves_planted_temporary_link_targets(self):
        for link in (os.symlink, os.link):
            with self.subTest(link=link.__name__):
                def plant(home, runtime, _state):
                    victim = home / "private.txt"
                    victim.write_text("Keep this private file intact.")
                    victim.chmod(0o640)
                    link(victim, runtime / "omaflow-state.json.tmp")
                with daemon(plant) as (home, runtime, _state, snapshot, send):
                    send("press")
                    time.sleep(.08)
                    send("release")
                    wait_until(lambda: snapshot()["phase"] == "result")
                    self.assertEqual((home / "private.txt").read_text(),
                                     "Keep this private file intact.")
                    self.assertEqual((home / "private.txt").stat().st_mode & 0o777, 0o640)
                    self.assertEqual((runtime / "omaflow-state.json").stat().st_mode & 0o777, 0o600)
                    self.assertIn("Private dictation", snapshot()["text"])

    def test_training_rejects_linked_files_without_writing_private_words(self):
        for link in (os.symlink, os.link):
            with self.subTest(link=link.__name__):
                def plant(home, _runtime, state):
                    victim = home / "shared.txt"
                    victim.write_text("Shared file stays unchanged.\n")
                    victim.chmod(0o644)
                    link(victim, state / "training.jsonl")
                with daemon(plant) as (home, _runtime, _state, snapshot, send):
                    send("press")
                    time.sleep(.08)
                    send("release")
                    wait_until(lambda: snapshot()["phase"] == "result")
                    self.assertEqual((home / "shared.txt").read_text(),
                                     "Shared file stays unchanged.\n")
                    self.assertEqual((home / "shared.txt").stat().st_mode & 0o777, 0o644)
                    self.assertIn("could not append fine-tuning sample", (home / "daemon.log").read_text())

    def test_training_appends_complete_private_samples(self):
        with daemon(lambda *_: None) as (_home, _runtime, state, snapshot, send):
            for count in (1, 2):
                send("press")
                time.sleep(.08)
                send("release")
                wait_until(lambda: len(snapshot()["history"]) == count)
            samples = [json.loads(line) for line in (state / "training.jsonl").read_text().splitlines()]
            self.assertEqual(len(samples), 2)
            self.assertTrue(all(sample["raw_asr"] == "Private dictation for the storage regression."
                                for sample in samples))
            self.assertEqual((state / "training.jsonl").stat().st_mode & 0o777, 0o600)


class PrivateIpcTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.foreign = ["unshare", "--user", "--map-auto", "--map-root-user", "python3", "-c"]
        cls.drop_user = "import os; os.setgid(1); os.setuid(1); "
        if not namespace_available(cls.foreign + [cls.drop_user + "assert os.getuid() == 1"]):
            raise unittest.SkipTest("the different-user IPC checks require delegated subordinate UIDs")

    def test_daemon_rejects_other_users_even_if_socket_permissions_are_relaxed(self):
        with daemon(lambda *_: None) as (home, runtime, _state, snapshot, _send):
            home.chmod(0o755)
            runtime.chmod(0o755)
            (runtime / "omaflow.sock").chmod(0o666)
            attack = self.drop_user + (
                "import socket, sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); "
                "print('connected', flush=True)\n"
                "try: s.sendall(b'press'); s.shutdown(socket.SHUT_WR); s.recv(1)\n"
                "except (BrokenPipeError, ConnectionResetError): pass\n"
            )
            result = subprocess.run(self.foreign + [attack, str(runtime / "omaflow.sock")],
                                    capture_output=True, text=True, timeout=5, check=True)
            self.assertEqual(result.stdout.strip(), "connected")
            time.sleep(.1)
            self.assertEqual(snapshot()["phase"], "idle")

    def test_daemon_refuses_a_foreign_runtime_directory_without_changing_it(self):
        with tempfile.TemporaryDirectory(prefix="omaflow-foreign-runtime-") as directory:
            home = Path(directory)
            home.chmod(0o777)
            runtime = home / "runtime"
            subprocess.run(self.foreign + [self.drop_user +
                           "import sys; os.mkdir(sys.argv[1]); os.chmod(sys.argv[1], 0o777)",
                           str(runtime)], capture_output=True, timeout=5, check=True)
            home.chmod(0o755)
            result = subprocess.run([str(BINARY), "daemon"],
                                    env=dict(os.environ, XDG_RUNTIME_DIR=str(runtime), HOME=str(home)),
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("belongs to another user", result.stderr)
            self.assertEqual(runtime.stat().st_mode & 0o777, 0o777)
            self.assertEqual(list(runtime.iterdir()), [])

    def test_client_sends_no_private_text_to_a_socket_owned_by_another_user(self):
        with tempfile.TemporaryDirectory(prefix="omaflow-foreign-ipc-") as directory:
            runtime = Path(directory)
            runtime.chmod(0o777)
            listener = self.drop_user + (
                "import socket, sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); "
                "os.chmod(sys.argv[1], 0o666); s.listen(); print('ready', flush=True); "
                "c,_=s.accept(); print(len(c.recv(65536)), flush=True)"
            )
            process = subprocess.Popen(self.foreign + [listener, str(runtime / "omaflow.sock")],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertEqual(process.stdout.readline().strip(), "ready")
                result = subprocess.run([str(BINARY), "--stdin"],
                                        env=dict(os.environ, XDG_RUNTIME_DIR=str(runtime)),
                                        input=json.dumps(["history-edit", "42", "Private clipboard and journal words."]), capture_output=True,
                                        text=True, timeout=5)
                output, errors = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, errors)
                self.assertEqual(output.strip(), "0")
                self.assertNotEqual(result.returncode, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    unittest.main()
