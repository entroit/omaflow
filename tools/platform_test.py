#!/usr/bin/env python3
"""Exercise shortcut rollback, bootstrap diagnostics, and installer trap safety."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
from unittest.mock import patch
import set_hotkey

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="omaflow-platform-") as directory:
    base = Path(directory)
    # The checkout's own build, not whichever OmaFlow is installed here.
    with patch.dict(os.environ, {"XDG_CONFIG_HOME":str(base), "OMAFLOW_CONFIG":str(base/"omaflow/config.toml"),
                                 "OMAFLOW_BINARY":str(ROOT/"target/release/omaflow")}):
        def healthy(*args):
            return "[]" if args[-1] == "binds" else ""
        with patch.object(set_hotkey, "run", healthy):
            assert set_hotkey.parse_keys("Control_L + F13") == ["Control_L", "F13"]
            set_hotkey.save(["F13"], ["F13"])
        saved = base / "omaflow/shortcut.lua"
        before = saved.read_bytes()
        # The shell syncs after every change to config.toml; with the shortcuts
        # already in effect it writes nothing and never reloads Hyprland, so
        # a sync cannot set off another sync.
        import contextlib, io, sys as system
        stamp = (saved.stat().st_mtime_ns, (base/"omaflow/config.toml").stat().st_mtime_ns)
        def untouched(*args):
            raise AssertionError(f"An unchanged sync ran {args}")
        with patch.object(set_hotkey, "run", untouched), patch.object(system, "argv", ["set_hotkey.py", "--sync"]):
            printed = io.StringIO()
            with contextlib.redirect_stdout(printed):
                assert set_hotkey.main() == 0
        assert "unchanged" in printed.getvalue()
        assert stamp == (saved.stat().st_mtime_ns, (base/"omaflow/config.toml").stat().st_mtime_ns)
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
        # The window and journal shortcuts: normalised, clash-checked, and
        # written into the generated file next to the dictation hotkey.
        assert set_hotkey.parse_binding("super+shift+v") == "SUPER + SHIFT + V"
        assert set_hotkey.parse_binding(" shift + win + F13 ") == "SUPER + SHIFT + F13"
        assert set_hotkey.parse_binding("") == ""
        for text in ["V", "SUPER + SHIFT", "HYPER + V", "SUPER + SUPER + V", 'SUPER + V"); os.execute("x']:
            try:
                set_hotkey.parse_binding(text)
                raise AssertionError("Invalid binding accepted: " + text)
            except ValueError:
                pass
        with patch.object(set_hotkey, "run", healthy):
            set_hotkey.save_binding("journal", "super + alt + j")
            set_hotkey.save_binding("window", "")
        generated = saved.read_text()
        assert 'journal = "SUPER + ALT + J"' in generated and 'window = ""' in generated and '"F13"' in generated
        before, before_config = saved.read_bytes(), (base/"omaflow/config.toml").read_bytes()
        taken = [{"key":"J", "description":"Existing action", "modmask":72},
                 {"key":"V", "description":"OmaFlow window", "modmask":65}]
        with patch.object(set_hotkey, "run", lambda *args: json.dumps(taken) if args[-1] == "binds" else ""):
            try:
                set_hotkey.save_binding("window", "SUPER + ALT + J")
                raise AssertionError("Conflicting binding accepted")
            except ValueError as error:
                assert "Existing action" in str(error)
            set_hotkey.save_binding("window", "SUPER + SHIFT + V")
        assert 'window = "SUPER + SHIFT + V"' in saved.read_text()
        with patch.object(set_hotkey, "run", broken):
            try:
                set_hotkey.save_binding("window", "SUPER + SHIFT + B")
                raise AssertionError("Broken reload accepted")
            except ValueError:
                pass
        assert 'window = "SUPER + SHIFT + V"' in saved.read_text()
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
    assert 'Download no models' in plan.stdout, plan.stdout
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
    nemo.write_text('''#!/usr/bin/python3
import json, os, sys
if 'doctor' in sys.argv:
    gpu = os.environ.get('TEST_GPU') == '1'
    devices = [{'type': 'integrated-gpu', 'description': 'Test Radeon'}] if gpu else []
    print(json.dumps({'accelerator_available': gpu, 'devices': devices + [{'type': 'cpu', 'description': 'Test CPU'}]}))
else:
    print(json.dumps(sys.argv[1:]))
''')
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
    # The Vulkan build knows no `cuda`, which the window saves for its GPU
    # choice, and stops rather than use the CPU when no GPU answers.
    (nemo.parent.parent/'.nemo-speech-install').write_text('0.3.0 linux x86_64 vulkan\n')
    alternate.write_text(alternate.read_text().replace('device="cpu"', 'device="cuda"'))
    for gpu, device in [('1', 'vulkan'), ('0', 'cpu')]:
        result = subprocess.run([str(binary), 'serve-asr'], env=dict(alternate_env, TEST_GPU=gpu), capture_output=True, text=True, timeout=5)
        assert result.returncode == 0, result.stderr
        arguments = json.loads(result.stdout)
        assert arguments[arguments.index('--backend')+1] == device, (gpu, arguments)
    (nemo.parent.parent/'.nemo-speech-install').unlink()
    cached.unlink()
    result = subprocess.run([str(binary), 'serve-asr'], env=alternate_env, capture_output=True, text=True, timeout=5)
    assert result.returncode == 78 and not result.stdout, result.stderr
    assert 'Install it separately' in result.stderr
    print('PASS the configured model drives the managed server arguments')

    nemo_source = (ROOT/'scripts/install-nemo.sh').read_text()
    def pinned_table(name):
        table = re.search(name + r'=\(([^)]*)\)', nemo_source).group(1)
        return dict(re.findall(r'\[(\w+)\]="?([0-9a-f.]+)"?', table))
    runtime_versions = pinned_table('runtime_versions')
    runtime_bytes = {name: int(value) for name, value in pinned_table('runtime_bytes').items()}
    runtime_sha256 = pinned_table('runtime_sha256')
    assert runtime_versions == {'cuda': '0.1.0', 'vulkan': '0.3.0', 'cpu': '0.3.0'}
    assert runtime_bytes == {'cuda': 107310946, 'vulkan': 19482397, 'cpu': 9605101}
    assert runtime_sha256 == {
        'cuda': 'e68628f396489c98fb353e070efaea5bc4977409ae7734fce56c251a79e29147',
        'vulkan': '2a8b2ca4610b6ea5d659ba10794526f6e5a77fb1623d52c35272a9fd1f74abac',
        'cpu': '255f12b722ab15b2a38a51cf125d56e3fa97058b528f7e895b39d6a473deb06e',
    }
    assert 'releases/download/v$runtime_version/$runtime_archive' in nemo_source
    for mutable_path in ['raw/main/', 'scripts/install.sh', 'git clone', '.tar.gz.sha256']:
        assert mutable_path not in nemo_source

    def runtime_root(variant, version):
        return f'nemo-speech-{version}-linux-x86_64-{variant}'

    def url(variant):
        version = runtime_versions[variant]
        return f'https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v{version}/{runtime_root(variant, version)}.tar.gz'

    def marker(variant):
        return f'{runtime_versions[variant]} linux x86_64 {variant}\n'

    # The fixture reports the version it was built with, and its GPU answers
    # `doctor` only when TEST_ACCELERATOR says so.
    def fixture_archive(variant, reported_version):
        source = base/f'nemo-fixture-source-{variant}-{reported_version}'/runtime_root(variant, runtime_versions[variant])
        (source/'bin').mkdir(parents=True)
        (source/'bin/nemo-speech').write_text(f'''#!/usr/bin/bash
: > "$TEST_RUNTIME_EXECUTED"
if [[ $* == *doctor* ]]; then
  printf '{{"accelerator_available": %s}}\\n' "${{TEST_ACCELERATOR:-false}}"
  exit 0
fi
printf 'nemo-speech {reported_version}\\n'
''')
        (source/'bin/nemo-speech').chmod(0o755)
        (source/'share').mkdir()
        (source/'share/runtime.txt').write_text(f'verified {variant} fixture\n')
        (source/'lib').mkdir()
        (source/'lib/libnemo.so.1').write_text(f'verified {variant} library\n')
        (source/'lib/libnemo.so').symlink_to('libnemo.so.1')
        (source/'share/nemo-speech').mkdir()
        (source/'share/nemo-speech/model-index.json').write_text('{"models": []}\n')
        archive_path = base/f'runtime-{variant}-{reported_version}.tar.gz'
        with tarfile.open(archive_path, 'w:gz') as archive:
            archive.add(source, arcname=runtime_root(variant, runtime_versions[variant]))
        return archive_path

    def pinned_to(archives, name):
        script = fixture_repo/'scripts'/name
        text = nemo_source
        for variant, archive_path in archives.items():
            text = (text
                .replace(f'[{variant}]={runtime_bytes[variant]}', f'[{variant}]={archive_path.stat().st_size}')
                .replace(runtime_sha256[variant], hashlib.sha256(archive_path.read_bytes()).hexdigest()))
        manifests = fixture_repo/'scripts'/(name + '-integrity')
        manifests.mkdir()
        for variant, archive_path in archives.items():
            files, symlinks = {}, {}
            with tarfile.open(archive_path) as archive:
                for member in archive.getmembers():
                    relative = str(Path(member.name).relative_to(runtime_root(variant, runtime_versions[variant])))
                    if member.isfile():
                        files[relative] = hashlib.sha256(archive.extractfile(member).read()).hexdigest()
                    elif member.issym():
                        symlinks[relative] = member.linkname
            (manifests/(variant + '.json')).write_text(json.dumps({
                'archiveSha256': hashlib.sha256(archive_path.read_bytes()).hexdigest(),
                'files': files, 'symlinks': symlinks,
            }))
        text = text.replace('$repo_dir/scripts/nemo-runtime/$2.json',
                            '$repo_dir/scripts/' + manifests.name + '/$2.json')
        script.write_text(text)
        script.chmod(0o755)
        return script

    archives = {variant: fixture_archive(variant, runtime_versions[variant]) for variant in ['cuda', 'vulkan', 'cpu']}
    fixture_repo = base/'nemo-fixture-repo'
    (fixture_repo/'scripts').mkdir(parents=True)
    shutil.copy2(ROOT/'scripts/check-nemo-runtime.py', fixture_repo/'scripts/check-nemo-runtime.py')
    fixture_script = pinned_to(archives, 'install-nemo.sh')
    receipt_script = fixture_repo/'tools/install_receipt.py'
    receipt_script.parent.mkdir()
    receipt_script.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
Path(os.environ["TEST_RECEIPT"]).write_text(" ".join(sys.argv[1:]))
''')

    nemo_commands = base/'nemo-bin'; nemo_commands.mkdir()
    # The archive served is the one the URL names, so a wrong choice of build
    # shows up as a wrong marker rather than passing by accident. Every URL
    # asked for is kept, in order.
    (nemo_commands/'curl').write_text(r'''#!/usr/bin/bash
set -euo pipefail
printf '%s\n' "$@" > "$TEST_CURL_ARGS"
if [[ -n ${TEST_CURL_CALLS:-} ]]; then
  printf 'download\n' >> "$TEST_CURL_CALLS"
  sleep 0.3
fi
output=''
url=''
while (($#)); do
  case "$1" in
    -o|--output) output="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n $output ]]
printf '%s\n' "$url" >> "$TEST_CURL_URLS"
case "$url" in
  *-cuda.tar.gz) cp "$TEST_RUNTIME_ARCHIVE_CUDA" "$output" ;;
  *-vulkan.tar.gz) cp "$TEST_RUNTIME_ARCHIVE_VULKAN" "$output" ;;
  *-cpu.tar.gz) cp "$TEST_RUNTIME_ARCHIVE_CPU" "$output" ;;
  *) exit 22 ;;
esac
case "${TEST_CURL_MODE:-valid}" in
  valid) ;;
  tampered) printf X | dd of="$output" bs=1 seek=0 conv=notrunc status=none ;;
  oversized) printf X >> "$output" ;;
  fail) exit 7 ;;
esac
''')
    # Stands in for the dynamic linker cache, the half of the NVIDIA check a
    # test can control; the other half is this machine's own kernel driver.
    (nemo_commands/'ldconfig').write_text(r'''#!/usr/bin/bash
printf '1 libs found in cache `/etc/ld.so.cache'"'"'\n'
if [[ ${TEST_LIBCUDA:-} == 1 ]]; then
  printf '\tlibcuda.so.1 (libc6,x86-64) => /usr/lib/libcuda.so.1\n'
fi
''')
    for path in nemo_commands.iterdir():
        path.chmod(0o755)

    curl_args = base/'curl-args'
    curl_urls = base/'curl-urls'
    executed = base/'nemo-runtime-executed'
    receipt = base/'nemo-runtime-receipt'
    nemo_env = dict(
        os.environ,
        PATH=f'{nemo_commands}:/usr/bin',
        HOME=str(base),
        XDG_STATE_HOME=str(base/'state'),
        TEST_CURL_ARGS=str(curl_args),
        TEST_CURL_URLS=str(curl_urls),
        TEST_RUNTIME_ARCHIVE_CUDA=str(archives['cuda']),
        TEST_RUNTIME_ARCHIVE_VULKAN=str(archives['vulkan']),
        TEST_RUNTIME_ARCHIVE_CPU=str(archives['cpu']),
        TEST_RUNTIME_EXECUTED=str(executed),
        TEST_RECEIPT=str(receipt),
    )
    def install(prefix, script=fixture_script, **extra):
        curl_urls.unlink(missing_ok=True)
        return subprocess.run(
            [str(script), str(prefix)], env=dict(nemo_env, **extra),
            capture_output=True, text=True, timeout=10,
        )
    def downloaded():
        return curl_urls.read_text().splitlines() if curl_urls.exists() else []

    # The other half of each driver check is this machine's own hardware.
    has_nvidia_kernel_driver = Path('/proc/driver/nvidia/version').exists()
    has_vulkan_driver = bool(list(Path('/dev/dri').glob('renderD*'))) and any(
        not driver.name.startswith('lvp_icd')
        for folder in [Path('/usr/share/vulkan/icd.d'), Path('/etc/vulkan/icd.d')] if folder.is_dir()
        for driver in folder.glob('*.json'))
    gpu_build = 'vulkan' if has_vulkan_driver else 'cpu'

    # Without NVIDIA's driver library the CUDA build cannot even start, so a
    # machine without it gets the Vulkan build when a GPU answers through
    # Vulkan, and the CPU build otherwise.
    prefix = base/'nemo-runtime-good'
    result = install(prefix, TEST_ACCELERATOR='true')
    assert result.returncode == 0, result.stderr
    assert executed.exists() and (prefix/'bin/nemo-speech').exists()
    assert (prefix/'.nemo-speech-install').read_text() == marker(gpu_build)
    assert (prefix/'share/runtime.txt').read_text() == f'verified {gpu_build} fixture\n'
    assert receipt.read_text() == f'nemo-runtime {prefix}'
    assert downloaded() == [url(gpu_build)]
    arguments = curl_args.read_text().splitlines()
    assert arguments[arguments.index('--max-filesize')+1] == str(archives[gpu_build].stat().st_size)
    assert arguments[arguments.index('--proto')+1] == '=https'
    assert arguments[arguments.index('--proto-redir')+1] == '=https'
    assert '--tlsv1.2' in arguments
    assert arguments[arguments.index('--retry')+1] == '3'

    concurrent = base/'nemo-runtime-concurrent'
    calls = base/'runtime-concurrent-downloads'
    concurrent_env = dict(nemo_env, TEST_CURL_CALLS=str(calls), TEST_ACCELERATOR='true')
    first = subprocess.Popen([str(fixture_script), str(concurrent)], env=concurrent_env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    deadline = time.monotonic() + 5
    while not calls.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert calls.exists(), 'The first runtime download never started'
    second = subprocess.Popen([str(fixture_script), str(concurrent)], env=concurrent_env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for process in [first, second]:
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, stdout + stderr
    assert calls.read_text().splitlines() == ['download'], 'Concurrent runtime installers both acquired an archive'
    assert not Path(str(concurrent) + '.new').exists()
    assert not Path(str(concurrent) + '.old').exists()
    print('PASS concurrent model downloads share one serialized runtime installation')

    lock_victim = base/'runtime-lock-victim'
    lock_victim.write_text('keep this file\n'); lock_victim.chmod(0o600)
    for symbolic in [False, True]:
        locked_prefix = base/('nemo-linked-lock-' + str(symbolic))
        lock = Path(str(locked_prefix) + '.lock')
        if symbolic:
            lock.symlink_to(lock_victim)
        else:
            os.link(lock_victim, lock)
        result = install(locked_prefix)
        assert result.returncode != 0 and not locked_prefix.exists(), result.stdout + result.stderr
        assert lock_victim.read_text() == 'keep this file\n'
        lock.unlink()
    print('PASS runtime installer locking refuses planted links without changing their targets')

    # Running it again on the same machine downloads nothing.
    receipt.unlink()
    result = install(prefix, TEST_ACCELERATOR='true')
    assert result.returncode == 0, result.stderr
    assert result.stdout == f'NeMo-Speech runtime ({gpu_build}) already installed at {prefix}\n'
    assert downloaded() == [] and not receipt.exists()

    # A Vulkan driver whose GPU does not answer gets the CPU build instead.
    # A Vulkan build already in place stays: the server starts it on the CPU.
    if has_vulkan_driver:
        no_gpu = base/'nemo-runtime-no-gpu'
        result = install(no_gpu)
        assert result.returncode == 0, result.stderr
        assert 'No GPU answered through Vulkan' in result.stdout
        assert downloaded() == [url('vulkan'), url('cpu')]
        assert (no_gpu/'.nemo-speech-install').read_text() == marker('cpu')
        assert (no_gpu/'share/runtime.txt').read_text() == 'verified cpu fixture\n'
        receipt.unlink()

    for name, relative in [('executable', 'bin/nemo-speech'),
                           ('library', 'lib/libnemo.so.1'),
                           ('model-index', 'share/nemo-speech/model-index.json')]:
        damaged = base/('nemo-tampered-' + name)
        shutil.copytree(prefix, damaged, symlinks=True)
        (damaged/relative).write_text('unverified bytes\n')
        executed.unlink(missing_ok=True)
        result = install(damaged, TEST_CURL_MODE='fail')
        assert result.returncode != 0 and not executed.exists(), result.stdout + result.stderr
    for name in ['library-link', 'extra-library', 'linked-prefix', 'shared-parent']:
        damaged = base/('nemo-tampered-' + name)
        if name == 'linked-prefix':
            damaged.symlink_to(prefix, target_is_directory=True)
        elif name == 'shared-parent':
            shared = base/'shared-runtime-parent'; shared.mkdir(); shared.chmod(0o777)
            damaged = shared/'runtime'
            shutil.copytree(prefix, damaged, symlinks=True)
        else:
            shutil.copytree(prefix, damaged, symlinks=True)
            if name == 'library-link':
                (damaged/'lib/libnemo.so').unlink()
                (damaged/'lib/libnemo.so').symlink_to(prefix/'lib/libnemo.so.1')
            else:
                (damaged/'lib/injected.so').write_text('unverified library\n')
        executed.unlink(missing_ok=True)
        result = install(damaged, TEST_CURL_MODE='fail')
        assert result.returncode != 0 and not executed.exists(), result.stdout + result.stderr
    executed.unlink(missing_ok=True)
    forged = base/'nemo-forged-marker'; (forged/'bin').mkdir(parents=True)
    (forged/'.nemo-speech-install').write_text('0.1.0 linux x86_64 cpu\n')
    forged_binary = forged/'bin/nemo-speech'
    forged_binary.write_text('#!/bin/sh\n: > "$TEST_RUNTIME_EXECUTED"\necho "nemo-speech 0.1.0"\n')
    forged_binary.chmod(0o755)
    result = install(forged, TEST_CURL_MODE='fail')
    assert result.returncode != 0 and not executed.exists(), result.stdout + result.stderr
    print('PASS forged markers, changed runtime bytes, added libraries and unsafe links fail before existing code executes')

    # With the driver library present, the build follows the kernel driver:
    # a machine with an NVIDIA GPU switches to the CUDA build, one without
    # keeps the build it has.
    result = install(prefix, TEST_LIBCUDA='1', TEST_ACCELERATOR='true')
    assert result.returncode == 0, result.stderr
    if has_nvidia_kernel_driver:
        assert (prefix/'.nemo-speech-install').read_text() == marker('cuda')
        assert (prefix/'share/runtime.txt').read_text() == 'verified cuda fixture\n'
        assert downloaded() == [url('cuda')]
        assert not (base/'nemo-runtime-good.old').exists() and not (base/'nemo-runtime-good.new').exists()
        # Losing the driver switches back.
        result = install(prefix, TEST_ACCELERATOR='true')
        assert result.returncode == 0, result.stderr
        assert (prefix/'.nemo-speech-install').read_text() == marker(gpu_build)
    else:
        assert (prefix/'.nemo-speech-install').read_text() == marker(gpu_build)
    # Switching builds keeps the prefix OmaFlow created, so no second receipt.
    assert not receipt.exists()

    executed.unlink(missing_ok=True)
    wrong = {variant: fixture_archive(variant, '9.9.9') for variant in ['vulkan', 'cpu']}
    wrong_version_script = pinned_to(wrong, 'install-nemo-wrong-version.sh')
    result = install(base/'nemo-runtime-wrong-version', script=wrong_version_script, TEST_ACCELERATOR='true',
                     TEST_RUNTIME_ARCHIVE_VULKAN=str(wrong['vulkan']), TEST_RUNTIME_ARCHIVE_CPU=str(wrong['cpu']))
    assert result.returncode != 0 and 'did not report version' in result.stderr
    assert executed.exists() and not (base/'nemo-runtime-wrong-version').exists()
    executed.unlink()

    result = install(base/'nemo-runtime-bad-hash', TEST_CURL_MODE='tampered')
    assert result.returncode != 0 and 'checksum verification' in result.stderr
    assert not executed.exists()

    result = install(base/'nemo-runtime-oversized', TEST_CURL_MODE='oversized')
    assert result.returncode != 0 and 'expected exactly' in result.stderr
    assert not executed.exists()

    traps = re.findall(r"trap '([^']+)' EXIT", nemo_source)
    target = next(trap for trap in traps if 'temporary' in trap)
    temporary = base/'nemo-temporary'; temporary.mkdir()
    program = 'temporary="$1"\ntrap '+"'"+target+"' EXIT\nexit 0\n"
    result = subprocess.run(['bash','-c',program,'test',str(temporary)], start_new_session=True, timeout=3)
    assert result.returncode == 0 and not temporary.exists()
    print("PASS the NeMo runtime is one exact, bounded, verified release artifact per build, chosen by the NVIDIA or Vulkan driver, with no source fallback")

    # Call the real catalog module without CLI notifications or a desktop session.
    # Only its checkout lookup and unused daemon callback need adapters here.
    fallback_home = base/'runtime-fallback-home'
    unverified = fallback_home/'.local/lib/nemo-speech/bin/nemo-speech'
    unverified.parent.mkdir(parents=True)
    unverified.write_text('#!/bin/sh\n: > "$TEST_RUNTIME_EXECUTED"\necho "nemo-speech 0.1.0"\n')
    unverified.chmod(0o755)
    fallback_source = base/'runtime-fallback.rs'
    fallback_source.write_text('''
mod config { pub use omaflow_core::config::*; }
mod process { pub use omaflow_platform::process::CommandExt; }
mod update {
    pub fn repo_root() -> Option<std::path::PathBuf> {
        Some(std::path::PathBuf::from(ROOT_PATH))
    }
}
fn send_command_quiet(_: &str) -> bool { false }
#[path = CATALOG_PATH] mod catalog;
fn main() {
    let entry = catalog::find(catalog::Kind::Speech, "nvidia/parakeet-tdt-0.6b-v3").unwrap();
    assert!(catalog::download(catalog::Kind::Speech, entry, |_, _| {}).is_err());
}
'''.replace('ROOT_PATH', json.dumps(str(ROOT)))
       .replace('CATALOG_PATH', json.dumps(str(ROOT/'src/catalog.rs'))))
    fallback_runner = base/'runtime-fallback'
    build = ['rustc', '--edition=2024', '-A', 'dead_code', str(fallback_source),
             '-L', 'dependency=' + str(ROOT/'target/debug/deps'), '-o', str(fallback_runner)]
    for name in ['serde', 'serde_json', 'omaflow_core', 'omaflow_platform']:
        library = max((ROOT/'target/debug/deps').glob('lib' + name + '-*.rlib'),
                      key=lambda path: path.stat().st_mtime_ns)
        build += ['--extern', name + '=' + str(library)]
    result = subprocess.run(build, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    executed.unlink(missing_ok=True)
    result = subprocess.run([str(fallback_runner)],
        env=dict(nemo_env, HOME=str(fallback_home), TEST_CURL_MODE='fail'),
        capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and not executed.exists(), result.stdout + result.stderr
    print('PASS a failed verified runtime installation never falls back to an existing executable')

# The sandboxed daemon can only write a journal folder opened to it: the tool
# creates the folder, writes the drop-in once, and leaves it alone after.
import journal_folder
with tempfile.TemporaryDirectory(prefix="omaflow-journal-") as directory:
    base = Path(directory)
    folder = base / 'My "Notes" Vault' / "Journal"
    (base / "omaflow").mkdir()
    (base / "omaflow/config.toml").write_text(f"[journal]\nfolder = {json.dumps(str(folder))}\n")
    with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(base), "OMAFLOW_CONFIG": str(base / "omaflow/config.toml")}):
        assert "now write" in journal_folder.sync(write_only=True)
        drop_in = base / "systemd/user/omaflow.service.d/journal-folder.conf"
        assert folder.is_dir()
        assert 'ReadWritePaths="' + str(folder).replace('"', '\\"') + '"' in drop_in.read_text()
        assert "already write" in journal_folder.sync(write_only=True)
        (base / "omaflow/config.toml").write_text("[journal]\nfolder = \"relative/path\"\n")
        try:
            journal_folder.sync(write_only=True)
            raise AssertionError("Relative journal folder accepted")
        except ValueError:
            pass
print("PASS the journal folder is created and opened to the sandboxed daemon once")

# AltGr is Hyprland's MOD5, and a key recorded by its physical code (because
# AltGr or Shift changed what it types) is named as Hyprland matches it.
assert set_hotkey.parse_binding("altgr + code:60") == "MOD5 + period"   # the same key on US and German layouts
assert set_hotkey.label("MOD5 + period") == "AltGr+."
assert set_hotkey.label(" + ".join(["ISO_Level3_Shift", "Menu"])) == "AltGr+Menu"
assert set_hotkey.parse_binding("super + mod5 + j") == "SUPER + MOD5 + J"
print("PASS AltGr bindings and physical keys are named the way Hyprland matches them")
