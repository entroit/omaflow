#!/usr/bin/env python3
"""Exercise shortcut rollback, bootstrap diagnostics, and installer trap safety."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
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
    for label in ['no Omarchy plugin directory', 'pw-cat is missing']:
        assert 'warn  '+label in bootstrap, bootstrap
        assert 'FAIL  '+label in ordinary, ordinary
    print("PASS fresh bootstrap treats installer-owned dependencies as repairable")
    # Models arrive after the install now, so preflight must never gate on a GPU,
    # on VRAM or on a running model server.
    for output in [bootstrap, ordinary]:
        assert not any(word in output for word in ['GPU', 'VRAM', 'CUDA', 'ollama', 'Ollama', 'speech port']), output
    print('PASS preflight checks only what an app-only install needs')


    for name in ["pacman", "ollama"]:
        path = commands / name
        path.write_text("#!/usr/bin/bash\nexit 0\n")
        path.chmod(0o755)
    plan = subprocess.run(
        [str(ROOT / 'install'), '--skip-preflight', '--dry-run'],
        env=dict(env, PATH=str(commands)+":/usr/bin", HOME=str(base)),
        capture_output=True, text=True, timeout=10,
    )
    assert plan.returncode == 0, plan.stderr
    assert 'download no models' in plan.stdout, plan.stdout
    assert 'ollama' not in plan.stdout.lower(), plan.stdout
    print("PASS the installer plans no model or Ollama work at all")

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
    # models_configured is explicit in both fixtures: a fresh install leaves it
    # false until the background download lands, and these cases are about a
    # machine that is already past that.
    alternate.write_text('[behavior]\nmodels_configured=true\n[backend]\nengine="openai"\nmodel="test-whisper"\nendpoint="http://127.0.0.1:18765/v1/audio/transcriptions"\n[cleanup]\nenabled=false\nmodel="alternate-cleanup"\n')
    alternate_env = dict(env, PATH=str(commands)+":/usr/bin", HOME=str(base), OMAFLOW_CONFIG=str(alternate))
    # The plan is the same whatever the models are: the installer ships the app.
    plan = subprocess.run([str(ROOT/'install'), '--skip-preflight', '--dry-run'], env=alternate_env, capture_output=True, text=True, timeout=10)
    assert plan.returncode == 0, plan.stderr
    for unwanted in ['ensure speech weights', 'download cleanup weights', 'enable the ollama system service']:
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
    alternate.write_text('[behavior]\nmodels_configured=true\n[backend]\nengine="nemo"\nmodel="another-speech-model"\nendpoint="http://127.0.0.1:18765/v1/audio/transcriptions"\ndevice="cpu"\n')
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
    print('PASS the configured model drives the managed server arguments')

    nemo_source = (ROOT/'scripts/install-nemo.sh').read_text()
    runtime_version = re.search(r'runtime_version="([0-9]+\.[0-9]+\.[0-9]+)"', nemo_source).group(1)
    runtime_bytes = int(re.search(r'runtime_bytes=([0-9]+)', nemo_source).group(1))
    runtime_sha256 = re.search(r'runtime_sha256="([0-9a-f]{64})"', nemo_source).group(1)
    runtime_archive = f'nemo-speech-{runtime_version}-linux-x86_64-cuda.tar.gz'
    runtime_root = runtime_archive.removesuffix('.tar.gz')
    assert runtime_version == '0.1.0'
    assert runtime_bytes == 107310946
    assert runtime_sha256 == 'e68628f396489c98fb353e070efaea5bc4977409ae7734fce56c251a79e29147'
    assert 'releases/download/v$runtime_version/$runtime_archive' in nemo_source
    for mutable_path in ['raw/main/', 'scripts/install.sh', 'git clone', '.tar.gz.sha256']:
        assert mutable_path not in nemo_source

    fixture_source = base/'nemo-fixture-source'/runtime_root
    fixture_binary = fixture_source/'bin/nemo-speech'
    fixture_binary.parent.mkdir(parents=True)
    fixture_binary.write_text(f'''#!/usr/bin/bash
: > "$TEST_RUNTIME_EXECUTED"
printf 'nemo-speech {runtime_version}\\n'
''')
    fixture_binary.chmod(0o755)
    (fixture_source/'share').mkdir()
    (fixture_source/'share/runtime.txt').write_text('verified fixture\n')
    fixture_archive = base/'runtime.tar.gz'
    with tarfile.open(fixture_archive, 'w:gz') as archive:
        archive.add(fixture_source, arcname=runtime_root)
    fixture_bytes = fixture_archive.stat().st_size
    fixture_sha256 = hashlib.sha256(fixture_archive.read_bytes()).hexdigest()

    fixture_repo = base/'nemo-fixture-repo'
    fixture_script = fixture_repo/'scripts/install-nemo.sh'
    fixture_script.parent.mkdir(parents=True)
    fixture_script.write_text(
        nemo_source
        .replace(f'runtime_bytes={runtime_bytes}', f'runtime_bytes={fixture_bytes}')
        .replace(runtime_sha256, fixture_sha256)
    )
    fixture_script.chmod(0o755)
    receipt_script = fixture_repo/'tools/install_receipt.py'
    receipt_script.parent.mkdir()
    receipt_script.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
Path(os.environ["TEST_RECEIPT"]).write_text(" ".join(sys.argv[1:]))
''')

    nemo_commands = base/'nemo-bin'; nemo_commands.mkdir()
    (nemo_commands/'curl').write_text(r'''#!/usr/bin/bash
set -euo pipefail
printf '%s\n' "$@" > "$TEST_CURL_ARGS"
output=''
while (($#)); do
  case "$1" in
    -o|--output) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n $output ]]
cp "$TEST_RUNTIME_ARCHIVE" "$output"
case "${TEST_CURL_MODE:-valid}" in
  valid) ;;
  tampered) printf X | dd of="$output" bs=1 seek=0 conv=notrunc status=none ;;
  oversized) printf X >> "$output" ;;
  fail) exit 7 ;;
esac
''')
    for path in nemo_commands.iterdir():
        path.chmod(0o755)

    curl_args = base/'curl-args'
    executed = base/'nemo-runtime-executed'
    receipt = base/'nemo-runtime-receipt'
    nemo_env = dict(
        os.environ,
        PATH=f'{nemo_commands}:/usr/bin',
        HOME=str(base),
        XDG_STATE_HOME=str(base/'state'),
        TEST_CURL_ARGS=str(curl_args),
        TEST_RUNTIME_ARCHIVE=str(fixture_archive),
        TEST_RUNTIME_EXECUTED=str(executed),
        TEST_RECEIPT=str(receipt),
    )
    prefix = base/'nemo-runtime-good'
    result = subprocess.run(
        [str(fixture_script), str(prefix)], env=nemo_env,
        capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 0, result.stderr
    assert executed.exists() and (prefix/'bin/nemo-speech').exists()
    assert (prefix/'.nemo-speech-install').read_text() == f'{runtime_version} linux x86_64 cuda\n'
    assert receipt.read_text() == f'nemo-runtime {prefix}'
    arguments = curl_args.read_text().splitlines()
    expected_url = f'https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v{runtime_version}/{runtime_archive}'
    assert expected_url in arguments
    assert arguments[arguments.index('--max-filesize')+1] == str(fixture_bytes)
    assert arguments[arguments.index('--proto')+1] == '=https'
    assert arguments[arguments.index('--proto-redir')+1] == '=https'
    assert '--tlsv1.2' in arguments
    assert arguments[arguments.index('--retry')+1] == '3'

    executed.unlink()
    fixture_binary.write_text('''#!/usr/bin/bash
: > "$TEST_RUNTIME_EXECUTED"
printf 'nemo-speech 9.9.9\\n'
''')
    fixture_binary.chmod(0o755)
    wrong_version_archive = base/'wrong-version.tar.gz'
    with tarfile.open(wrong_version_archive, 'w:gz') as archive:
        archive.add(fixture_source, arcname=runtime_root)
    wrong_version_bytes = wrong_version_archive.stat().st_size
    wrong_version_sha256 = hashlib.sha256(wrong_version_archive.read_bytes()).hexdigest()
    wrong_version_script = fixture_repo/'scripts/install-nemo-wrong-version.sh'
    wrong_version_script.write_text(
        nemo_source
        .replace(f'runtime_bytes={runtime_bytes}', f'runtime_bytes={wrong_version_bytes}')
        .replace(runtime_sha256, wrong_version_sha256)
    )
    wrong_version_script.chmod(0o755)
    wrong_version_env = dict(nemo_env, TEST_RUNTIME_ARCHIVE=str(wrong_version_archive))
    result = subprocess.run(
        [str(wrong_version_script), str(base/'nemo-runtime-wrong-version')],
        env=wrong_version_env, capture_output=True, text=True, timeout=10,
    )
    assert result.returncode != 0 and 'did not report version' in result.stderr
    assert executed.exists() and not (base/'nemo-runtime-wrong-version').exists()
    executed.unlink()

    bad_env = dict(nemo_env, TEST_CURL_MODE='tampered')
    result = subprocess.run(
        [str(fixture_script), str(base/'nemo-runtime-bad-hash')],
        env=bad_env, capture_output=True, text=True, timeout=10,
    )
    assert result.returncode != 0 and 'checksum verification' in result.stderr
    assert not executed.exists()

    oversized_env = dict(nemo_env, TEST_CURL_MODE='oversized')
    result = subprocess.run(
        [str(fixture_script), str(base/'nemo-runtime-oversized')],
        env=oversized_env, capture_output=True, text=True, timeout=10,
    )
    assert result.returncode != 0 and 'expected exactly' in result.stderr
    assert not executed.exists()

    traps = re.findall(r"trap '([^']+)' EXIT", nemo_source)
    target = next(trap for trap in traps if 'temporary' in trap)
    temporary = base/'nemo-temporary'; temporary.mkdir()
    program = 'temporary="$1"\ntrap '+"'"+target+"' EXIT\nexit 0\n"
    result = subprocess.run(['bash','-c',program,'test',str(temporary)], start_new_session=True, timeout=3)
    assert result.returncode == 0 and not temporary.exists()
    print("PASS the NeMo runtime uses one exact, bounded, verified release artifact with no source fallback")
