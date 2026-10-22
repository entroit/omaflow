#!/usr/bin/env python3
"""Replay cached update offers after a manual install in an isolated HOME."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "target/release/omaflow"


class Installation:
    def __init__(self, home):
        self.home = home
        self.runtime = home / "runtime"
        self.runtime.mkdir(mode=0o700)
        self.update = home / "state/omaflow/update"
        self.update.mkdir(parents=True, mode=0o700)
        self.repo = home / "config/omarchy/plugins/entroit.omaflow"
        self.repo.mkdir(parents=True)
        self.commands = home / "bin"
        self.commands.mkdir()
        for name, body in {
            "curl": "exit 1", "systemctl": "exit 1", "wl-paste": "exit 1",
            "wl-copy": "cat >/dev/null", "hyprctl": "echo '{}'",
            "ollama": "echo 'NAME ID SIZE'", "nvidia-smi": "exit 1",
            "wpctl": "echo 'Volume: 0.8'", "notify-send": "exit 0",
        }.items():
            command = self.commands / name
            command.write_text("#!/bin/sh\n" + body + "\n")
            command.chmod(0o755)
        config = home / "config.toml"
        config.write_text(
            '[cleanup]\nenabled=false\n[behavior]\nmodels_configured=true\n'
            'keep_models_loaded=false\n'
            f'[journal]\nfolder="{home / "Journal"}"\n'
            f'[todos]\nfolder="{home / "To-dos"}"\n'
        )
        self.env = dict(
            os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(self.runtime),
            XDG_STATE_HOME=str(home / "state"), XDG_CONFIG_HOME=str(home / "config"),
            XDG_DATA_HOME=str(home / "data"), XDG_CACHE_HOME=str(home / "cache"),
            OMAFLOW_CONFIG=str(config), PATH=f"{self.commands}:/usr/bin",
            DBUS_SESSION_BUS_ADDRESS=f"unix:path={self.runtime / 'test-bus'}",
        )
        self.env.pop("INVOCATION_ID", None)
        self.env.pop("OMAFLOW_FAKE_TRANSCRIPT", None)
        self.git("init", "-q", "-b", "main")
        self.git("remote", "add", "origin", "https://github.com/entroit/omaflow")
        self.old_commit = self.commit("0.21.1")
        self.current_commit = self.commit("0.21.6")
        self.new_commit = self.commit("0.21.7")
        self.git("checkout", "-q", self.current_commit)
        # The retained executable is never run by request(); its digest and
        # committed metadata must pass before a real service could be started.
        binary = b"#!/bin/sh\nexit 1\n"
        digest = hashlib.sha256(binary).hexdigest()
        release = home / ".local/lib/omaflow/releases" / self.current_commit
        release.mkdir(parents=True)
        (release / "omaflow").write_bytes(binary)
        (release / "omaflow").chmod(0o700)
        (release / "commit").write_text(self.current_commit + "\n")
        metadata = json.loads((ROOT / "dist/release.json").read_text())
        metadata["version"] = "0.21.6"
        metadata["binary"].update(sha256=digest, bytes=len(binary))
        (release / "release.json").write_text(json.dumps(metadata))
        (home / ".local/lib/omaflow/current").symlink_to(release)
        self.installed = {
            "schemaVersion": 1, "commit": self.current_commit, "version": "0.21.6",
            "binarySha256": digest, "installedAtMs": 200,
        }
        self.write("installed.json", self.installed)

    def git(self, *args):
        return subprocess.check_output(
            ["/usr/bin/git", "-C", str(self.repo), *args], env=self.env, text=True,
            stderr=subprocess.PIPE,
        ).strip()

    def commit(self, version):
        (self.repo / "manifest.json").write_text(json.dumps({"version": version}))
        self.git("add", "manifest.json")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "-qm", version)
        return self.git("rev-parse", "HEAD")

    def write(self, name, value):
        path = self.update / name
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    def offer(self, version="0.21.1", commit=None):
        target = {
            "commit": commit or self.old_commit, "version": version,
            "summary": "Fixture update.", "changes": ["Fixture change."],
            "repository": "https://github.com/entroit/omaflow",
            "verificationMethod": "manual", "binaryPath": "dist/bin/x86_64-unknown-linux-gnu/omaflow",
            "binaryBytes": 1, "binarySha256": "a" * 64,
        }
        self.write("offer.json", {"schemaVersion": 1, "checkedAtMs": 100,
                                 "target": target, "error": None,
                                 "externalCheckoutWarning": None})
        return target

    def transaction(self, target, state="rolled-back"):
        value = {
            "state": state, "schemaVersion": 1, "id": "100-fixture",
            "targetCommit": target["commit"], "targetVersion": target["version"],
            "originalCommit": self.current_commit, "originalRelease": self.installed,
            "createdAtMs": 100,
        }
        if state != "queued":
            value["message"] = "The verified release is not a fast-forward update."
        if state in ("rolled-back", "needs-recovery"):
            value["failedAtMs"] = 150
        self.write("transaction.json", value)
        return value

    def stop_transaction(self):
        stopped_at = time.time() - 60
        os.utime(self.update / "transaction.json", (stopped_at, stopped_at))

    def manual_install(self, commit, version):
        self.git("checkout", "-q", commit)
        install_root = self.home / ".local/lib/omaflow"
        release = install_root / "releases" / commit
        if commit != self.current_commit:
            shutil.copytree(install_root / "releases" / self.current_commit, release,
                            dirs_exist_ok=True)
        (release / "commit").write_text(commit + "\n")
        metadata_path = release / "release.json"
        metadata = json.loads(metadata_path.read_text())
        metadata["version"] = version
        metadata_path.write_text(json.dumps(metadata))
        current = install_root / "current"
        current.unlink(missing_ok=True)
        current.symlink_to(release)
        receipt = dict(self.installed, commit=commit, version=version, installedAtMs=300)
        self.write("installed.json", receipt)
        return receipt

    def cli(self, *args):
        return subprocess.run([str(BINARY), *args], env=self.env, capture_output=True,
                              text=True, timeout=5)

    @contextlib.contextmanager
    def bus_probe(self, on_attempt=None):
        """Record systemctl's bus connection without reaching the user's bus."""
        attempted = threading.Event()
        done = threading.Event()
        (self.runtime / "systemd").mkdir(exist_ok=True)
        paths = (self.runtime / "test-bus", self.runtime / "systemd/private")
        with contextlib.ExitStack() as stack:
            selector = stack.enter_context(selectors.DefaultSelector())
            for path in paths:
                listener = stack.enter_context(socket.socket(socket.AF_UNIX))
                listener.bind(str(path))
                listener.listen()
                selector.register(listener, selectors.EVENT_READ)
            def accept():
                while not done.is_set():
                    for key, _ in selector.select(timeout=.05):
                        stream, _ = key.fileobj.accept()
                        first_attempt = not attempted.is_set()
                        attempted.set()
                        if first_attempt and on_attempt:
                            on_attempt()
                        stream.close()
            worker = threading.Thread(target=accept)
            worker.start()
            try:
                yield attempted
            finally:
                done.set()
                worker.join(timeout=1)
                for path in paths:
                    path.unlink()

    @contextlib.contextmanager
    def daemon(self):
        with (self.home / "daemon.log").open("w") as log:
            process = subprocess.Popen([str(BINARY), "daemon"], env=self.env,
                                       stdout=log, stderr=log, start_new_session=True)
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    try:
                        state = json.loads((self.runtime / "omaflow-state.json").read_text())
                    except (FileNotFoundError, json.JSONDecodeError):
                        time.sleep(.02)
                        continue
                    break
                else:
                    raise AssertionError((self.home / "daemon.log").read_text())
                yield state
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()


class UpdateOfferTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="omaflow-update-offer-")
        self.addCleanup(self.directory.cleanup)
        self.installation = Installation(Path(self.directory.name))

    def test_daemon_does_not_offer_cached_older_release(self):
        self.installation.transaction(self.installation.offer())
        with self.installation.daemon() as state:
            self.assertEqual(state["update_remote_version"], "",
                             "installed 0.21.6 still offers cached 0.21.1")
            self.assertEqual(state["update_behind"], 0)

    def test_terminal_failure_for_older_release_is_not_retryable(self):
        self.installation.transaction(self.installation.offer())
        result = self.installation.cli("update", "status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {},
                         "an obsolete 0.21.1 failure still supplies the Try again card")

    def test_already_installed_offer_and_failure_are_hidden(self):
        target = self.installation.offer("0.21.6", self.installation.current_commit)
        self.installation.transaction(target)
        with self.installation.daemon() as state:
            self.assertEqual(state["update_remote_version"], "")
            self.assertEqual(state["update_behind"], 0)
        result = self.installation.cli("update", "status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {})

    def test_request_rejects_cached_older_release_before_starting_service(self):
        transaction = self.installation.transaction(self.installation.offer())
        with self.installation.bus_probe() as attempted:
            result = self.installation.cli("update", "request")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(attempted.is_set(), result.stderr)
        self.assertEqual(json.loads((self.installation.update / "transaction.json").read_text()),
                         transaction, "request queued a downgrade from cached state")
        self.assertEqual(self.installation.git("rev-parse", "HEAD"), self.installation.current_commit)

    def test_request_rejects_an_already_installed_offer(self):
        self.installation.offer("0.21.6", self.installation.current_commit)
        with self.installation.bus_probe() as attempted:
            result = self.installation.cli("update", "request")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(attempted.is_set(), result.stderr)
        self.assertFalse((self.installation.update / "transaction.json").exists())

    def test_later_does_not_defer_an_obsolete_offer(self):
        self.installation.offer()
        result = self.installation.cli("update", "later")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.installation.update / "deferral.json").exists())

    def test_newer_offer_is_visible_and_request_reaches_the_isolated_service(self):
        self.installation.offer("0.21.7", self.installation.new_commit)
        with self.installation.daemon() as state:
            self.assertEqual(state["update_remote_version"], "0.21.7")
            self.assertEqual(state["update_behind"], 1)
        with self.installation.bus_probe() as attempted:
            result = self.installation.cli("update", "request")
        self.assertTrue(attempted.is_set(), result.stderr)
        transaction = json.loads((self.installation.update / "transaction.json").read_text())
        self.assertEqual(transaction["targetCommit"], self.installation.new_commit)
        self.assertEqual(transaction["targetVersion"], "0.21.7")
        self.assertEqual(json.loads((self.installation.update / "installed.json").read_text()),
                         self.installation.installed)

    def test_a_failed_start_does_not_overwrite_newer_transaction_progress(self):
        for change in ("preparing", "replacement"):
            with self.subTest(change=change):
                transaction_path = self.installation.update / "transaction.json"
                transaction_path.unlink(missing_ok=True)
                self.installation.offer("0.21.7", self.installation.new_commit)
                observed = []

                def advance():
                    transaction = json.loads(transaction_path.read_text())
                    if change == "preparing":
                        transaction.update(state="preparing", message="Downloading the verified release")
                    else:
                        transaction.update(id="101-another-request", createdAtMs=101)
                    self.installation.write("transaction.json", transaction)
                    observed.append(transaction)

                with self.installation.bus_probe(on_attempt=advance) as attempted:
                    result = self.installation.cli("update", "request")
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(attempted.is_set(), result.stderr)
                self.assertEqual(len(observed), 1)
                self.assertEqual(json.loads(transaction_path.read_text()), observed[0])

    def test_same_version_at_a_different_commit_can_still_be_offered(self):
        self.installation.offer("0.21.6", self.installation.new_commit)
        with self.installation.daemon() as state:
            self.assertEqual(state["update_remote_version"], "0.21.6")
            self.assertEqual(state["update_behind"], 1)

    def test_same_version_ancestor_cannot_start_a_downgrade(self):
        self.installation.offer("0.21.6", self.installation.old_commit)
        with self.installation.bus_probe() as attempted:
            result = self.installation.cli("update", "request")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(attempted.is_set(), result.stderr)
        self.assertFalse((self.installation.update / "transaction.json").exists())

    def test_same_version_descendant_can_start_an_update(self):
        self.installation.offer("0.21.6", self.installation.new_commit)
        with self.installation.bus_probe() as attempted:
            result = self.installation.cli("update", "request")
        self.assertTrue(attempted.is_set(), result.stderr)

    def test_failed_newer_update_keeps_its_recovery_information(self):
        target = self.installation.offer("0.21.7", self.installation.new_commit)
        transaction = self.installation.transaction(target)
        result = self.installation.cli("update", "status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), transaction)

    def test_an_incomplete_recovery_is_not_hidden_as_a_stale_failure(self):
        transaction = self.installation.transaction(self.installation.offer(), "needs-recovery")
        result = self.installation.cli("update", "status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), transaction)

    def test_recovery_can_start_without_a_current_offer(self):
        transaction = self.installation.transaction(self.installation.offer(), "needs-recovery")
        (self.installation.update / "offer.json").unlink()
        with self.installation.bus_probe() as attempted:
            result = self.installation.cli("update", "request")
        self.assertTrue(attempted.is_set(), result.stderr)
        self.assertEqual(json.loads((self.installation.update / "transaction.json").read_text()),
                         transaction)

    def test_recovery_can_start_after_a_failed_marketplace_check(self):
        transaction = self.installation.transaction(self.installation.offer(), "needs-recovery")
        offer_path = self.installation.update / "offer.json"
        offer = json.loads(offer_path.read_text())
        offer.update(target=None, error="The marketplace is unavailable.")
        self.installation.write("offer.json", offer)
        with self.installation.bus_probe() as attempted:
            result = self.installation.cli("update", "request")
        self.assertTrue(attempted.is_set(), result.stderr)
        self.assertEqual(json.loads((self.installation.update / "transaction.json").read_text()),
                         transaction)

    def test_queued_stale_update_does_not_start_the_service(self):
        target = self.installation.offer()
        transaction = self.installation.transaction(target, "queued")
        with self.installation.bus_probe() as attempted:
            result = self.installation.cli("update", "request")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(attempted.is_set(), result.stderr)
        self.assertEqual(json.loads((self.installation.update / "transaction.json").read_text()),
                         transaction)

    def test_a_stopped_stale_transaction_does_not_block_a_newer_update(self):
        for state in ("queued", "preparing", "waiting-for-idle"):
            with self.subTest(state=state):
                self.installation.transaction(self.installation.offer(), state)
                self.installation.stop_transaction()
                self.installation.offer("0.21.7", self.installation.new_commit)
                with self.installation.bus_probe() as attempted:
                    result = self.installation.cli("update", "request")
                self.assertTrue(attempted.is_set(), result.stderr)
                transaction = json.loads((self.installation.update / "transaction.json").read_text())
                self.assertEqual(transaction["targetCommit"], self.installation.new_commit)
                self.assertEqual(transaction["targetVersion"], "0.21.7")
                self.assertEqual(self.installation.git("rev-parse", "HEAD"), self.installation.current_commit)

    def test_a_live_updater_keeps_its_transaction(self):
        transaction = self.installation.transaction(self.installation.offer(), "queued")
        self.installation.stop_transaction()
        self.installation.offer("0.21.7", self.installation.new_commit)
        lock_path = self.installation.update / "runner.lock"
        with lock_path.open("w") as lock:
            lock_path.chmod(0o600)
            lock.write("flock\n")
            lock.flush()
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.installation.bus_probe() as attempted:
                result = self.installation.cli("update", "request")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(attempted.is_set(), result.stderr)
        self.assertEqual(json.loads((self.installation.update / "transaction.json").read_text()),
                         transaction)

    def test_a_stopped_obsolete_update_is_cleared_without_another_offer(self):
        self.installation.transaction(self.installation.offer(), "queued")
        self.installation.stop_transaction()
        with self.installation.bus_probe() as attempted:
            result = self.installation.cli("update", "request")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(attempted.is_set(), result.stderr)
        status = self.installation.cli("update", "status")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertEqual(json.loads(status.stdout), {})

    def test_a_changed_checkout_keeps_the_stopped_transaction(self):
        transaction = self.installation.transaction(self.installation.offer(), "queued")
        self.installation.stop_transaction()
        self.installation.offer("0.21.7", self.installation.new_commit)
        manifest = self.installation.repo / "manifest.json"
        manifest.write_text('{"version":"0.21.6","localChange":true}')
        with self.installation.bus_probe() as attempted:
            result = self.installation.cli("update", "request")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(attempted.is_set(), result.stderr)
        self.assertEqual(json.loads((self.installation.update / "transaction.json").read_text()),
                         transaction)

    def test_another_checkout_commit_keeps_the_stopped_transaction(self):
        transaction = self.installation.transaction(self.installation.offer(), "queued")
        self.installation.stop_transaction()
        self.installation.offer("0.21.7", self.installation.new_commit)
        self.installation.git("checkout", "-q", self.installation.new_commit)
        with self.installation.bus_probe() as attempted:
            result = self.installation.cli("update", "request")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(attempted.is_set(), result.stderr)
        self.assertEqual(json.loads((self.installation.update / "transaction.json").read_text()),
                         transaction)

    def test_partway_recovery_survives_the_target_receipt_being_installed(self):
        for state in ("activating", "verifying", "needs-recovery"):
            with self.subTest(state=state):
                transaction = self.installation.transaction(
                    self.installation.offer("0.21.6", self.installation.current_commit), state)
                self.installation.stop_transaction()
                (self.installation.update / "offer.json").unlink()
                with self.installation.bus_probe() as attempted:
                    result = self.installation.cli("update", "request")
                self.assertTrue(attempted.is_set(), result.stderr)
                self.assertEqual(json.loads((self.installation.update / "transaction.json").read_text()),
                                 transaction)

    def test_updater_entrypoints_preserve_a_completed_manual_install(self):
        (self.installation.repo / "correction").write_text("same-version correction\n")
        self.installation.git("add", "correction")
        correction = self.installation.commit("0.21.6")
        future = self.installation.commit("0.22.0")
        scenarios = ((self.installation.new_commit, "0.21.7", self.installation.new_commit, "0.21.7"),
                     (future, "0.22.0", self.installation.new_commit, "0.21.7"),
                     (future, "0.22.0", correction, "0.21.6"))
        for entrypoint in ("run", "reconcile"):
            for state in ("queued", "preparing", "waiting-for-idle"):
                for target_commit, target_version, installed_commit, installed_version in scenarios:
                    with self.subTest(entrypoint=entrypoint, state=state,
                                      target=target_version, installed=installed_version):
                        target = self.installation.offer(target_version, target_commit)
                        self.installation.transaction(target, state)
                        self.installation.stop_transaction()
                        receipt = self.installation.manual_install(installed_commit, installed_version)
                        result = self.installation.cli("update", entrypoint)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(json.loads((self.installation.update / "installed.json").read_text()),
                                         receipt, "an old pre-install transaction rolled back the manual install")
                        self.assertEqual(self.installation.git("rev-parse", "HEAD"), installed_commit)
                        self.assertEqual((self.installation.home / ".local/lib/omaflow/current").resolve().name,
                                         installed_commit)
                        status = self.installation.cli("update", "status")
                        self.assertEqual(json.loads(status.stdout), {})

    def test_an_inconsistent_current_link_cannot_retire_or_roll_back_the_transaction(self):
        for entrypoint in ("request", "run", "reconcile"):
            with self.subTest(entrypoint=entrypoint):
                target = self.installation.offer("0.21.7", self.installation.new_commit)
                transaction = self.installation.transaction(target, "queued")
                self.installation.stop_transaction()
                receipt = self.installation.manual_install(self.installation.new_commit, "0.21.7")
                install_root = self.installation.home / ".local/lib/omaflow"
                (install_root / "current").unlink()
                (install_root / "current").symlink_to(install_root / "releases" / self.installation.current_commit)
                with self.installation.bus_probe() as attempted:
                    result = self.installation.cli("update", entrypoint)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(attempted.is_set(), result.stderr)
                self.assertEqual(json.loads((self.installation.update / "installed.json").read_text()), receipt)
                self.assertEqual(self.installation.git("rev-parse", "HEAD"), self.installation.new_commit)
                self.assertEqual(json.loads((self.installation.update / "transaction.json").read_text()), transaction)

    def test_a_new_request_uses_the_completed_manual_install_as_its_original_release(self):
        for version in ("0.21.6", "0.21.7"):
            with self.subTest(version=version):
                self.installation.git("checkout", "-q", self.installation.current_commit)
                (self.installation.repo / "correction").write_text("manual update\n")
                self.installation.git("add", "correction")
                manual_commit = self.installation.commit(version)
                future = self.installation.commit("0.22.0")
                target = self.installation.offer("0.22.0", future)
                self.installation.transaction(target, "queued")
                self.installation.stop_transaction()
                receipt = self.installation.manual_install(manual_commit, version)
                with self.installation.bus_probe() as attempted:
                    result = self.installation.cli("update", "request")
                self.assertTrue(attempted.is_set(), result.stderr)
                transaction = json.loads((self.installation.update / "transaction.json").read_text())
                self.assertEqual(transaction["targetCommit"], future)
                self.assertEqual(transaction["originalCommit"], manual_commit)
                self.assertEqual(transaction["originalRelease"], receipt)
                self.assertEqual(self.installation.git("rev-parse", "HEAD"), manual_commit)

    def test_reconciliation_preserves_real_partway_recovery(self):
        for state in ("activating", "verifying", "needs-recovery"):
            with self.subTest(state=state):
                target = self.installation.offer("0.21.7", self.installation.new_commit)
                self.installation.transaction(target, state)
                self.installation.manual_install(self.installation.new_commit, "0.21.7")
                result = self.installation.cli("update", "reconcile")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads((self.installation.update / "installed.json").read_text()),
                                 self.installation.installed)
                self.assertEqual(self.installation.git("rev-parse", "HEAD"), self.installation.current_commit)
                transaction = json.loads((self.installation.update / "transaction.json").read_text())
                self.assertEqual(transaction["state"], "needs-recovery",
                                 "recovery must wait for the original daemon to prove it is running")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=BINARY)
    arguments, remaining = parser.parse_known_args()
    BINARY = arguments.binary.resolve()
    unittest.main(argv=[__file__, *remaining], verbosity=2)
