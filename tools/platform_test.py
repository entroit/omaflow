#!/usr/bin/env python3
"""Exercise shortcut rollback, bootstrap diagnostics, and installer trap safety."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from unittest.mock import patch
import set_hotkey

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="omaflow-platform-") as directory:
    base = Path(directory)
    with patch.dict(os.environ, {"XDG_CONFIG_HOME":str(base), "OMAFLOW_CONFIG":str(base/"omaflow/config.toml")}):
        def healthy(*args):
            return "[]" if args[-1] == "binds" else ""
        with patch.object(set_hotkey, "run", healthy):
            assert set_hotkey.parse_keys("Control_L + F13") == ["Control_L", "F13"]
            set_hotkey.save(["F13"], ["F13"])
        saved = base / "omaflow/shortcut.lua"
        before = saved.read_bytes()
        before_config = (base/"omaflow/config.toml").read_bytes()
        def broken(*args):
            return "[]" if args[-1] == "binds" else "bad configuration" if args[-1] == "configerrors" else ""
        with patch.object(set_hotkey, "run", broken):
            try:
                set_hotkey.save(["F9"], [])
                raise AssertionError("Broken reload accepted")
            except ValueError:
                pass
        assert saved.read_bytes() == before
        assert (base/"omaflow/config.toml").read_bytes() == before_config
        with patch.object(set_hotkey, "run", lambda *args: json.dumps([{"key":"F9", "description":"Existing action", "modmask":0}])):
            try:
                set_hotkey.save(["F9"], [])
                raise AssertionError("Conflicting key accepted")
            except ValueError:
                pass
        assert saved.read_bytes() == before
        assert (base/"omaflow/config.toml").read_bytes() == before_config
        for text in ['F13\"; os.execute("bad")', "NotARealKeysym", "F9+F9"]:
            try:
                set_hotkey.parse_keys(text)
                raise AssertionError("Invalid keys accepted")
            except ValueError:
                pass
    print("PASS shortcut validation, conflict rejection and rollback")

    commands = base / "bin"; commands.mkdir()
    for name in ["python3","dirname","bash","head","cut","grep","sed","awk","tail","timeout","wc","ss","ldconfig"]:
        (commands/name).symlink_to(Path('/usr/bin')/name)
    for name, body in {
        "hyprctl": 'case "$1" in version) echo Hyprland-test;; esac',
        "quickshell": 'exit 0', "omarchy": 'exit 0', "omarchy-shell": 'exit 0',
        "nvidia-smi": 'case "$*" in -L) echo "GPU 0: Test";; *memory.free*) echo 16000;; *compute-apps*) true;; -q) echo "CUDA Version : 13.0";; *) echo "Test GPU";; esac',
        "systemctl": 'case "$*" in *ollama*) exit 1;; *is-system-running*) echo running;; *) exit 0;; esac',
        "curl": 'exit 7', "pactl": 'echo "1 TestMicrophone"', "wpctl": 'echo "Volume: 0.5"',
    }.items():
        path=commands/name; path.write_text("#!/usr/bin/bash\n"+body+"\n"); path.chmod(0o755)
    env = dict(os.environ, PATH=str(commands)+":"+str(Path.home()/'.local/bin'),
               XDG_CONFIG_HOME=str(base/'fresh'), XDG_CACHE_HOME=str(base/'.cache'), XDG_RUNTIME_DIR=str(base), HYPRLAND_INSTANCE_SIGNATURE="test")
    bootstrap = subprocess.run([str(ROOT/'scripts/preflight.sh'), '--bootstrap'], env=env, capture_output=True, text=True, timeout=10).stdout
    ordinary = subprocess.run([str(ROOT/'scripts/preflight.sh')], env=env, capture_output=True, text=True, timeout=10).stdout
    for label in ['no Omarchy plugin directory', 'ollama is not running', 'pw-cat is missing']:
        assert 'warn  '+label in bootstrap, bootstrap
        assert 'FAIL  '+label in ordinary, ordinary
    print("PASS fresh bootstrap treats installer-owned dependencies as repairable")
    deferred = subprocess.run([str(ROOT/'scripts/preflight.sh'), '--bootstrap', '--no-models'], env=env, capture_output=True, text=True, timeout=10)
    assert deferred.returncode == 0, deferred.stdout + deferred.stderr
    assert 'NVIDIA checks skipped' in deferred.stdout and 'ollama is not running' not in deferred.stdout
    print('PASS model-free preflight does not require GPU or model servers')


    for name in ["pacman", "ollama"]:
        path = commands / name
        path.write_text("#!/usr/bin/bash\nexit 0\n")
        path.chmod(0o755)
    for active in [False, True]:
        (commands / "systemctl").write_text(
            '#!/usr/bin/bash\ncase "$1" in is-enabled) exit 0;; is-active) exit '
            + ('0' if active else '1') + ';; esac\n'
        )
        plan = subprocess.run(
            [str(ROOT / 'install'), '--skip-preflight', '--dry-run'],
            env=dict(env, PATH=str(commands)+":/usr/bin", HOME=str(base)),
            capture_output=True, text=True, timeout=10,
        )
        assert plan.returncode == 0, plan.stderr
        assert ('enable the ollama system service' in plan.stdout) == (not active), plan.stdout
    print("PASS bootstrap starts an enabled but stopped Ollama service")

    for arguments in [["--hotkey"], ["--consume"], ["--hotkey", "--yes"], ["--consume", "Menu"]]:
        result = subprocess.run([str(ROOT/'install'), *arguments], capture_output=True, text=True, timeout=3)
        assert result.returncode != 0 and ('requires' in result.stderr or 'together' in result.stderr), result.stderr
    print("PASS installer rejects incomplete or orphaned shortcut arguments")

    linker = (ROOT/'link-local').read_text()
    section = linker[linker.index('shell_ready=0'):linker.index('if [[ -f "$config_home/hypr/bindings.lua"')]
    stubs = """set -euo pipefail
sleep() { :; }
timeout() { shift; "$@"; }
omarchy-shell() { return "$TEST_SHELL_STATUS"; }
omarchy() {
  if [[ $* == 'plugin list --json' ]]; then
    printf '%s\n' '[{"id":"entroit.omaflow","enabled":false}]'
  else
    return "$TEST_ENABLE_STATUS"
  fi
}
"""
    for shell_status, enable_status in [(1, 0), (0, 1), (0, 0)]:
        result = subprocess.run(['bash', '-c', stubs+section],
            env=dict(os.environ, TEST_SHELL_STATUS=str(shell_status), TEST_ENABLE_STATUS=str(enable_status)),
            capture_output=True, text=True, timeout=3)
        assert (result.returncode == 0) == (shell_status == 0 and enable_status == 0), result.stderr
    print("PASS link-local fails on shell readiness or widget activation errors")

    alternate = base/'alternate.toml'
    alternate.write_text('[backend]\nengine="openai"\nmodel="test-whisper"\nendpoint="http://127.0.0.1:18765/v1/audio/transcriptions"\n[cleanup]\nenabled=false\nmodel="alternate-cleanup"\n')
    alternate_env = dict(env, PATH=str(commands)+":/usr/bin", HOME=str(base), OMAFLOW_CONFIG=str(alternate))
    plan = subprocess.run([str(ROOT/'install'), '--skip-preflight', '--dry-run'], env=alternate_env, capture_output=True, text=True, timeout=10)
    assert plan.returncode == 0, plan.stderr
    for unwanted in ['NeMo-Speech runtime', 'ensure speech weights', 'download cleanup weights', 'enable the ollama system service']:
        assert unwanted not in plan.stdout, plan.stdout
    result = subprocess.run(['python3', str(ROOT/'tools/model_config.py')], env=alternate_env, capture_output=True, text=True, check=True)
    assert json.loads(result.stdout)['cleanup']['model'] == 'alternate-cleanup'
    nemo = base/'.local/lib/nemo-speech/bin/nemo-speech'
    nemo.parent.mkdir(parents=True)
    nemo.write_text('#!/usr/bin/python3\nimport json,sys; print(json.dumps(sys.argv[1:]))\n')
    nemo.chmod(0o755)
    binary = ROOT/'target/release/omaflow'
    result = subprocess.run([str(binary), 'serve-asr'], env=alternate_env, capture_output=True, text=True, timeout=5)
    assert result.returncode == 0 and not result.stdout, result.stderr
    alternate.write_text('[backend]\nengine="nemo"\nmodel="another-speech-model"\nendpoint="http://127.0.0.1:18765/v1/audio/transcriptions"\ndevice="cpu"\n')
    cached = base/'.cache/nemo-speech/models/another-speech-model/revision/model.gguf'
    cached.parent.mkdir(parents=True); cached.touch()
    result = subprocess.run([str(binary), 'serve-asr'], env=alternate_env, capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, result.stderr
    arguments = json.loads(result.stdout)
    assert arguments[arguments.index('--asr-model')+1] == str(cached)
    assert arguments[arguments.index('--backend')+1] == 'cpu'
    assert arguments[arguments.index('--port')+1] == '18765'
    cached.unlink()
    result = subprocess.run([str(binary), 'serve-asr'], env=alternate_env, capture_output=True, text=True, timeout=5)
    assert result.returncode == 78 and not result.stdout, result.stderr
    assert 'Install it separately' in result.stderr
    print('PASS configured models drive install planning and managed server arguments')

    traps = re.findall(r"trap '([^']+)' EXIT", (ROOT/'install').read_text())
    target = next(trap for trap in traps if 'installer' in trap)
    installer = base/'installer'; installer.touch()
    program = 'installer="$1"\ntrap '+"'"+target+"' EXIT\nexit 0\n"
    result = subprocess.run(['bash','-c',program,'test',str(installer)], start_new_session=True, timeout=3)
    assert result.returncode == 0 and not installer.exists()
    print("PASS installer cleanup without keepalive leaves its process group alive")
