#!/usr/bin/env python3
"""Dictate into a real window on this desktop, start to finish.

A second OmaFlow daemon, built from this checkout, with its own config, state
and socket, records a known sentence from a virtual microphone, transcribes it
on the speech server already running here, and pastes it into a foot window,
which the shell's terminal rule pastes into with Shift+Insert. The test then
checks the text that arrived and that the clipboard came back.

It needs a Hyprland session and the speech server of the installed OmaFlow.
For a few seconds it opens a window that takes focus and owns the clipboard,
so leave the keyboard alone; the clipboard's text is put back afterwards.
Your own daemon, microphone and settings are not touched.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
# JFK's inaugural address, whisper.cpp's sample clip.
SPEECH_URL = "https://raw.githubusercontent.com/ggml-org/whisper.cpp/b0a11594aec50892a02cd8d129eee2dfe93a8bb8/samples/jfk.wav"
SPEECH_SHA256 = "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e"
EXPECTED = ["ask not what your country can do for you", "ask what you can do for your country"]
SENTINEL = "omaflow test clipboard"
# Reads the window's input byte by byte, so a paste without a newline still
# reaches the file.
READER = """
import os, sys, termios, tty
tty.setraw(0)
with open(sys.argv[1], "ab", buffering=0) as out:
    while chunk := os.read(0, 4096):
        out.write(chunk)
"""

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--binary", type=Path, default=ROOT / "target/release/omaflow")
parser.add_argument("--endpoint", help="speech server; default: the one in your OmaFlow config")
args = parser.parse_args()


def fail(message):
    raise SystemExit("FAIL " + message)


def run(*command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, text=True, timeout=30, **kwargs)


def copy(data):
    # wl-copy leaves a process serving the clipboard, which would hold a
    # captured output pipe open until the next copy.
    subprocess.run(["wl-copy"], input=data, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=5)


def wait_for(what, check, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if result := check():
            return result
        time.sleep(0.05)
    fail(f"timed out after {seconds} s waiting for {what}")


def words(text):
    return " ".join(re.findall(r"[a-z']+", text.lower()))


runtime = Path(os.environ.get("XDG_RUNTIME_DIR", ""))
signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
display = os.environ.get("WAYLAND_DISPLAY")
if not (runtime.is_dir() and signature and display):
    fail("run this inside a Hyprland session")
for command in ["foot", "pw-loopback", "pw-play", "wl-copy", "wl-paste", "hyprctl"]:
    if not shutil.which(command):
        fail(f"{command} is not installed")
if not args.binary.is_file():
    fail(f"{args.binary} is missing; run cargo build --release first")

endpoint = args.endpoint
if not endpoint:
    config_path = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "omaflow/config.toml"
    with open(config_path, "rb") as file:
        endpoint = tomllib.load(file).get("backend", {}).get("endpoint", "http://127.0.0.1:18103/v1/audio/transcriptions")
server = endpoint.split("/v1/")[0]
try:
    urllib.request.urlopen(server + "/health", timeout=3)
except OSError as error:
    fail(f"no speech server answers at {server}/health ({error}); start OmaFlow's, or pass --endpoint")
# NeMo-Speech 0.3.0 refuses a model name it does not serve.
try:
    model = json.load(urllib.request.urlopen(server + "/v1/models", timeout=3))["data"][0]["id"]
except (OSError, ValueError, LookupError):
    model = "test"

speech = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "omaflow/test-audio/jfk.wav"
if not speech.is_file() or hashlib.sha256(speech.read_bytes()).hexdigest() != SPEECH_SHA256:
    speech.parent.mkdir(parents=True, exist_ok=True)
    data = urllib.request.urlopen(SPEECH_URL, timeout=60).read()
    if hashlib.sha256(data).hexdigest() != SPEECH_SHA256:
        fail("the downloaded speech sample failed its checksum")
    speech.write_bytes(data)

previous_clipboard = subprocess.run(["wl-paste", "--no-newline"], capture_output=True, timeout=5)
children = []
work = Path(tempfile.mkdtemp(prefix="omaflow-e2e-"))
test_runtime = work
try:
    # The test daemon's own runtime folder, for its socket and state, with
    # the desktop's sockets linked in so it still reaches Wayland, PipeWire
    # and Hyprland. Its path stays short: Hyprland's socket inside it must fit
    # the 108 bytes a socket address holds.
    test_runtime = Path(tempfile.mkdtemp(prefix="of", dir="/tmp"))
    for name in [display, "pipewire-0", "hypr", "bus"]:
        if (runtime / name).exists():
            (test_runtime / name).symlink_to(runtime / name)
    config = work / "config/omaflow/config.toml"
    config.parent.mkdir(parents=True)
    config.write_text(f"""[behavior]
models_configured = true
duck_audio_percent = 0
paste_mode = "auto"
restore_clipboard = true
[backend]
engine = "openai"
endpoint = {json.dumps(endpoint)}
model = {json.dumps(model)}
[cleanup]
enabled = false
light = false
""")
    environment = dict(
        os.environ,
        XDG_RUNTIME_DIR=str(test_runtime),
        XDG_CONFIG_HOME=str(work / "config"),
        XDG_STATE_HOME=str(work / "state"),
        OMAFLOW_CONFIG=str(config),
        DBUS_SESSION_BUS_ADDRESS=f"unix:path={runtime / 'bus'}",
        # The daemon's microphone is the virtual one below, not yours.
        PIPEWIRE_NODE="omaflow_e2e_mic",
    )

    loopback = subprocess.Popen([
        "pw-loopback", "-n", "omaflow-e2e",
        "--capture-props=media.class=Audio/Sink node.name=omaflow_e2e_speaker audio.position=[MONO] priority.session=0 priority.driver=0",
        "--playback-props=media.class=Audio/Source node.name=omaflow_e2e_mic audio.position=[MONO] priority.session=0 priority.driver=0",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    children.append(loopback)
    wait_for("the virtual microphone", lambda: "omaflow_e2e_mic" in run("pw-cli", "ls", "Node").stdout, 5)

    daemon_log = open(work / "daemon.log", "w")
    daemon = subprocess.Popen([str(args.binary), "daemon"], env=environment, stdout=daemon_log, stderr=subprocess.STDOUT)
    children.append(daemon)
    wait_for("the test daemon", lambda: (test_runtime / "omaflow.sock").exists(), 10)

    pasted = work / "pasted.txt"
    pasted.touch()
    target = subprocess.Popen(["foot", "--title", "OmaFlow dictation test", "python3", "-I", "-c", READER, str(pasted)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    children.append(target)
    wait_for("the test window to take focus",
             lambda: json.loads(run("hyprctl", "activewindow", "-j").stdout or "{}").get("pid") == target.pid, 10)
    time.sleep(0.3)

    copy(SENTINEL.encode())

    def omaflow(command):
        run(str(args.binary), command, env=environment)

    omaflow("press")
    time.sleep(0.3)
    run("pw-play", "--target", "omaflow_e2e_speaker", str(speech))
    time.sleep(0.3)
    focused = json.loads(run("hyprctl", "activewindow", "-j").stdout or "{}")
    if focused.get("pid") != target.pid:
        fail(f"focus moved to {focused.get('class')!r} ({focused.get('title')!r}) while the test spoke; leave the keyboard alone and run it again")
    released = time.monotonic()
    omaflow("release")
    text = wait_for("the dictation in the test window",
                    lambda: (lambda content: content if all(phrase in words(content) for phrase in EXPECTED) else None)(
                        pasted.read_text(errors="replace")), 30)
    latency = time.monotonic() - released
    print(f"PASS a spoken sentence arrives in a terminal window, {latency * 1000:.0f} ms after release: {text.strip()!r}")

    restored = wait_for("the clipboard to come back",
                        lambda: run("wl-paste", "--no-newline").stdout == SENTINEL, 3)
    print("PASS the clipboard comes back after the paste")

    daemon.terminate()
    daemon.wait(timeout=10)
    if subprocess.run(["pw-cli", "ls", "Node"], capture_output=True, text=True).stdout.count("omaflow_e2e_mic") != 1:
        fail("the test left a stream on the virtual microphone")
except BaseException:
    for path in [work / "daemon.log", work / "pasted.txt", test_runtime / "omaflow-state.json"]:
        if path.exists():
            print(f"--- {path.name}\n" + path.read_text(errors="replace")[-4000:], file=sys.stderr)
    raise
finally:
    for child in reversed(children):
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
    if previous_clipboard.returncode == 0:
        copy(previous_clipboard.stdout)
    else:
        subprocess.run(["wl-copy", "--clear"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    shutil.rmtree(work, ignore_errors=True)
    shutil.rmtree(test_runtime, ignore_errors=True)
