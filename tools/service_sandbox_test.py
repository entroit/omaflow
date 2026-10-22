#!/usr/bin/env python3
"""Run private storage operations in the deployed systemd user sandbox."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
import uuid
import wave

from speech_identity_test import KEY, PCM, serving


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "target/release/omaflow"
REQUIRE_SYSTEMD = False


def available():
    if os.geteuid() == 0 or not shutil.which("systemd-run"):
        return False
    return subprocess.run(
        ["systemctl", "--user", "show", "basic.target", "--property=ActiveState", "--value"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10,
    ).stdout.strip() == "active"


class ServiceSandboxTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not available():
            if REQUIRE_SYSTEMD:
                raise AssertionError("A running, unprivileged systemd user manager is required")
            raise unittest.SkipTest("No unprivileged systemd user manager")
        if not BINARY.is_file():
            raise AssertionError(f"Build the test binary first: {BINARY}")

    def setUp(self):
        # PrivateTmp hides /tmp. A fixture beneath HOME also exercises the
        # root-owned /home that the user's service namespace cannot identify.
        self.temporary = tempfile.TemporaryDirectory(prefix=".omaflow-sandbox-", dir=Path.home())
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.runtime = self.home / "runtime"
        self.state = self.home / ".local/state/omaflow"
        for path in [self.runtime, self.state, self.home / ".config/omaflow",
                     self.home / ".config/omarchy/plugins/entroit.omaflow/.git",
                     self.home / ".local/lib/omaflow"]:
            path.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.runner = self.home / ".local/lib/omaflow/trusted-runner"
        shutil.copyfile(BINARY, self.runner)
        self.runner.chmod(0o700)
        current = self.runner.parent / "current"
        current.mkdir()
        shutil.copyfile(BINARY, current / "omaflow")
        (current / "omaflow").chmod(0o700)
        self.env = {"HOME": str(self.home), "XDG_RUNTIME_DIR": str(self.runtime),
                    "XDG_STATE_HOME": str(self.home / ".local/state"),
                    "XDG_CONFIG_HOME": str(self.home / ".config")}
        self.unit = "omaflow-sandbox-test-" + uuid.uuid4().hex
        self.helper_units = set()

    def service_command(self, unit_file="omaflow-update-reconcile.service", preflight=True,
                        before=None, stop_cleanup=True, arguments=None):
        command = ["systemd-run", "--user", "--wait", "--pipe", "--collect", "--quiet",
                   "--expand-environment=no",
                   "--unit=" + self.unit]
        for name, value in self.env.items():
            command.append("--setenv=" + name + "=" + value)
        in_service = False
        for line in (ROOT / "dist" / unit_file).read_text().splitlines():
            if line.startswith("["):
                in_service = line == "[Service]"
            if not in_service or "=" not in line:
                continue
            key = line.split("=", 1)[0]
            value = line.replace("%h", str(self.home)).replace("%t", str(self.runtime))
            if key == "ExecStart":
                entrypoint = shlex.split(value.split("=", 1)[1])
                continue
            if key == "ExecStartPre" and not preflight:
                continue
            if key == "ExecStopPost" and not stop_cleanup:
                continue
            if key == "ExecStartPre" and before:
                # The helper alters only synthetic proof data after the real
                # preflight, before the production command enters its sandbox.
                script = self.home / "before.py"
                script.write_text(before)
                helper = self.home / "preflight.sh"
                helper.write_text("#!/bin/sh\nset -eu\n" +
                                  shlex.quote(str(self.runner)) + " storage-preflight\n" +
                                  "/usr/bin/python3 " + shlex.quote(str(script)) + "\n")
                helper.chmod(0o700)
                value = "ExecStartPre=+" + str(helper)
            command.extend(["--property", value])
        if arguments is not None:
            command.extend(["--property", "Restart=no"])
            entrypoint = [str(self.runner.parent / "current/omaflow"), *arguments]
        return command + entrypoint

    def stop_service(self):
        subprocess.run(["systemctl", "--user", "stop", self.unit],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)

    def run_service(self, **options):
        watching = threading.Event()
        stopped = threading.Event()

        def observe_helpers():
            while not stopped.is_set():
                self.helper_units.update(path.name + ".service"
                                         for path in self.runtime.glob("omaflow-http-*")
                                         if re.fullmatch(r"omaflow-http-[0-9a-f]{32}", path.name))
                watching.set()
                stopped.wait(.001)

        observer = threading.Thread(target=observe_helpers)
        observer.start()
        watching.wait(timeout=2)
        try:
            return subprocess.run(self.service_command(**options), text=True,
                                  capture_output=True, timeout=30)
        finally:
            # Only this test's uniquely named unit may be stopped on timeout.
            self.stop_service()
            stopped.set()
            observer.join(timeout=2)

    def assert_helpers_finished(self):
        self.assertTrue(self.helper_units, "The sandbox did not start its connection helper")
        remaining = []
        deadline = time.monotonic() + 7
        while time.monotonic() < deadline:
            listed = subprocess.run(
                ["/usr/bin/systemctl", "--user", "list-units", "--all", "--output=json",
                 "--no-pager", *sorted(self.helper_units)],
                capture_output=True, text=True, timeout=3, check=True,
            )
            remaining = [unit["unit"] for unit in json.loads(listed.stdout)
                         if unit["unit"] in self.helper_units]
            directories = list(self.runtime.glob("omaflow-http-*"))
            if not remaining and not directories:
                return
            time.sleep(.02)
        self.fail(f"Fixture connection helpers remained: {remaining}, {directories}")

    def test_reconcile_runs_with_deployed_sandbox(self):
        result = self.run_service()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lock = self.state / "update/runner.lock"
        self.assertEqual(lock.read_text(), "flock\n")
        self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
        self.assertFalse(list(self.runtime.glob("omaflow-storage-*.json")))

    def test_recovery_works_when_current_binary_is_missing(self):
        (self.runner.parent / "current/omaflow").unlink()
        result = self.run_service()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.state / "update/runner.lock").read_text(), "flock\n")

    def test_activation_accepts_retained_runner_without_preflight_command(self):
        current = self.runner.parent / "current/omaflow"
        self.runner.write_text(
            '#!/bin/sh\n[ "$1" = update ] || exit 64\nexec '
            + shlex.quote(str(current)) + ' "$@"\n'
        )
        result = self.run_service()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.state / "update/runner.lock").read_text(), "flock\n")

    def test_hidden_owners_require_preflight(self):
        result = self.run_service(preflight=False, stop_cleanup=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("permits another user", result.stdout + result.stderr)
        self.assertFalse((self.state / "update/runner.lock").exists())

    def test_preflight_rejects_writable_ancestor(self):
        self.home.chmod(0o777)
        result = self.run_service()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.state / "update/runner.lock").exists())

    def test_missing_proof_fails_closed(self):
        result = self.run_service(before=(
            "import os,pathlib\n"
            "for path in pathlib.Path(os.environ['XDG_RUNTIME_DIR']).glob('omaflow-storage-*.json'):\n"
            " path.unlink()\n"
        ))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.state / "update/runner.lock").exists())

    def test_altered_proofs_fail_closed(self):
        mutations = {
            "public": "path.chmod(0o644)",
            "hardlink": "os.link(path, path.with_suffix('.linked'))",
            "symlink": "target=path.with_suffix('.target'); path.rename(target); path.symlink_to(target)",
            "stale": "record=json.loads(path.read_text()); record['invocation']='0'*32; path.write_text(json.dumps(record))",
            "wrong_inode": "record=json.loads(path.read_text()); [item.update(inode=0) for item in record['roots']]; path.write_text(json.dumps(record))",
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                result = self.run_service(before=(
                    "import json,os,pathlib\n"
                    "path=pathlib.Path(os.environ['XDG_RUNTIME_DIR'])/('omaflow-storage-'+os.environ['INVOCATION_ID']+'.json')\n"
                    + mutate + "\n"
                ))
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("permits another user", result.stdout + result.stderr)
                self.assertFalse((self.state / "update/runner.lock").exists())

    def test_daemon_starts_with_deployed_sandbox(self):
        commands = self.home / "bin"
        commands.mkdir()
        for name in ["curl", "systemctl", "wl-copy", "wl-paste", "hyprctl", "ollama",
                     "nvidia-smi", "wpctl", "pw-cat", "notify-send"]:
            command = commands / name
            command.write_text("#!/bin/sh\nexit 1\n")
            command.chmod(0o700)
        self.env["PATH"] = str(commands) + ":/usr/bin"
        config = self.home / ".config/omaflow/config.toml"
        config.write_text("[behavior]\nmodels_configured=false\nkeep_models_loaded=false\n"
                          "[cleanup]\nenabled=false\n")
        process = subprocess.Popen(self.service_command(unit_file="omaflow.service"),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        snapshot = None
        try:
            deadline = time.monotonic() + 5
            while process.poll() is None and time.monotonic() < deadline:
                try:
                    snapshot = json.loads((self.runtime / "omaflow-state.json").read_text())
                    if snapshot.get("phase") == "idle":
                        break
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                time.sleep(.02)
        finally:
            self.stop_service()
            stdout, stderr = process.communicate(timeout=10)
        self.assertIsNotNone(snapshot, stdout + stderr)
        self.assertEqual(snapshot["phase"], "idle", stdout + stderr)
        self.assertEqual((self.runtime / "omaflow.sock").stat().st_mode & 0o777, 0o600)
        self.assertFalse(list(self.runtime.glob("omaflow-storage-*.json")))

    def transcribe(self, service, expected_pid, stall_lookup=False):
        commands = self.home / "bin"
        commands.mkdir(exist_ok=True)
        systemctl = commands / "systemctl"
        systemctl.write_text("#!/usr/bin/python3\nimport time\n" +
                             ("time.sleep(30)\n" if stall_lookup else "") +
                             f"print({expected_pid})\n")
        systemctl.chmod(0o700)
        self.env["PATH"] = str(commands) + ":/usr/bin"
        model = self.home / "model.gguf"
        model.touch()
        recording = self.home / "synthetic.wav"
        with wave.open(str(recording), "wb") as stream:
            stream.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            stream.writeframes(PCM)
        (self.home / ".config/omaflow/config.toml").write_text(
            '[behavior]\nmodels_configured=' + str(not stall_lookup).lower() + '\n[backend]\nengine="nemo"\n'
            f'model={json.dumps(str(model))}\n'
            f'endpoint="http://127.0.0.1:{service["port"]}/v1/audio/transcriptions"\n'
            f'api_key="{KEY}"\nstatus_timeout_ms=2000\n[cleanup]\nenabled=false\n'
        )
        return self.run_service(unit_file="omaflow.service",
                                arguments=["transcribe-file", str(recording)])

    def test_sandbox_authenticates_managed_speech_before_synthetic_audio(self):
        with serving(os.geteuid()) as (service, events):
            result = self.transcribe(service, service["pid"])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.strip(), "Synthetic recording.")
            self.assertTrue(any(event.get("audio") and event.get("credential") for event in events), events)
            self.assert_helpers_finished()

    def test_sandbox_refuses_an_unmanaged_listener_without_private_bytes(self):
        with serving(os.geteuid()) as (service, events):
            result = self.transcribe(service, os.getpid())
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any(event.get("audio") or event.get("credential") for event in events), events)
            self.assert_helpers_finished()

    def test_sandbox_rechecks_replacement_after_successful_health(self):
        with serving(os.geteuid(), replace=True) as (service, events):
            result = self.transcribe(service, service["pid"])
            self.assertTrue(any("replacement" in event for event in events), result.stdout + result.stderr)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any(event.get("pid") != service["pid"] and
                                 (event.get("audio") or event.get("credential")) for event in events), events)
            self.assert_helpers_finished()

    def test_stalled_service_lookup_is_bounded_and_leaves_no_helper(self):
        with serving(os.geteuid()) as (service, events):
            started = time.monotonic()
            result = self.transcribe(service, service["pid"], stall_lookup=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertLess(time.monotonic() - started, 8)
            self.assertFalse(any(event.get("audio") or event.get("credential") for event in events), events)
            self.assert_helpers_finished()

    def test_sandbox_ollama_connection_uses_the_verified_helper(self):
        with serving(os.geteuid()) as (service, events):
            (self.home / ".config/omaflow/config.toml").write_text(
                '[cleanup]\nengine="ollama"\nmodel="synthetic-cleanup"\n'
                f'endpoint="http://127.0.0.1:{service["port"]}/api/chat"\n'
                f'api_key="{KEY}"\ntimeout_seconds=2\n'
            )
            result = self.run_service(unit_file="omaflow.service", arguments=["test-cleanup"])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(json.loads(result.stdout)["ok"])
            self.assertTrue(any(event.get("path") == "/api/chat" and event.get("credential")
                                for event in events), events)
            self.assert_helpers_finished()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=BINARY)
    parser.add_argument("--require-systemd", action="store_true")
    args, remaining = parser.parse_known_args()
    BINARY = args.binary.resolve()
    REQUIRE_SYSTEMD = args.require_systemd
    unittest.main(argv=[__file__, *remaining])
