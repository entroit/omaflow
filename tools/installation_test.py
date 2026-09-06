#!/usr/bin/env python3
"""Exercise complete installer/linker and uninstall flows in an isolated home."""
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import tomllib

ROOT = Path(__file__).resolve().parents[1]

class Models(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(json.dumps({'models': [{'name': 'test-cleanup'}]}).encode())
    def log_message(self, *_):
        pass

with tempfile.TemporaryDirectory(prefix='omaflow-install-') as directory:
    base = Path(directory); repo = base/'checkout'; repo.mkdir()
    home = base/'home'; home.mkdir(); commands = base/'bin'; commands.mkdir()
    config = home/'.config'; (config/'hypr').mkdir(parents=True)
    (config/'hypr/omaflow-hotkey.lua').write_text('local omaflow_hotkey = { "F13" }\nlocal omaflow_consumed_keys = { "F13" }\nreturn { hotkey = omaflow_hotkey, consumed = omaflow_consumed_keys }\n')
    (config/'hypr/bindings.lua').write_text('-- unrelated settings\n')
    for name in ['install', 'link-local', 'uninstall', 'manifest.json', 'Cargo.toml']:
        shutil.copy2(ROOT/name, repo/name)
    for name in ['config', 'dist', 'integrations', 'assets']:
        shutil.copytree(ROOT/name, repo/name)
    (repo/'tools').mkdir(); shutil.copy2(ROOT/'tools/model_config.py', repo/'tools/model_config.py'); shutil.copy2(ROOT/'tools/set_hotkey.py', repo/'tools/set_hotkey.py')
    shutil.copy2(ROOT/'tools/install_receipt.py', repo/'tools/install_receipt.py')
    (repo/'target/release').mkdir(parents=True)
    shutil.copy2(ROOT/'target/release/omaflow', repo/'target/release/omaflow')
    log = base/'commands.log'
    for name in ['cargo','pacman','systemctl','hyprctl','omarchy','omarchy-shell','pw-cat','wl-copy','wl-paste','git','update-desktop-database','ollama','curl']:
        body = f'printf "%s\\n" "{name} $*" >> "$TEST_LOG"\n'
        if name == 'hyprctl': body += '''if [[ $* == '-j binds' ]]; then echo '[]'; fi\n'''
        if name == 'omarchy': body += '''if [[ $* == 'plugin list --json' ]]; then echo '[{"id":"entroit.omaflow","enabled":true}]'; fi\n'''
        path = commands/name; path.write_text('#!/usr/bin/bash\n'+body+'exit 0\n'); path.chmod(0o755)
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(config), XDG_CACHE_HOME=str(home/".cache"), XDG_STATE_HOME=str(home/'.local/state'),
               XDG_RUNTIME_DIR=str(base/'runtime'), PATH=f'{commands}:/usr/bin', TEST_LOG=str(log),
               OMAFLOW_CONFIG=str(config/'omaflow/config.toml'), HYPRLAND_INSTANCE_SIGNATURE='test')
    (base/'runtime').mkdir()
    def run(*args):
        result = subprocess.run([str(repo/args[0]), *args[1:]], env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stdout + result.stderr
        return result.stdout
    plan = run('install', '--no-models', '--skip-preflight', '--dry-run')
    assert not (config/'omaflow/config.toml').exists()
    assert 'defer model setup' in plan
    output = run('install', '--no-models', '--skip-preflight', '--yes')
    personal = config/'omaflow/config.toml'
    assert tomllib.loads(personal.read_text())['behavior']['models_configured'] is False
    complete = tomllib.loads(personal.read_text())
    defaults = tomllib.loads((ROOT/'config/config.toml').read_text())
    for section, values in defaults.items():
        assert set(values) <= set(complete[section]), section
    assert complete['shortcut'] == {'keys':['F13'], 'consumed':['F13']}
    assert complete['cleanup']['system_prompt'] == defaults['cleanup']['system_prompt']
    assert (config/'hypr/omaflow-hotkey.lua').is_symlink()
    assert 'F13' in (config/'omaflow/shortcut.lua').read_text()

    assert not (home/'.local/state/omaflow-install/receipt.json').exists()
    assert 'Models not configured' in output
    assert not any(word in log.read_text() for word in ['ollama ', 'nemo-speech', 'curl ']), log.read_text()
    assert (home/'.local/bin/omaflow').is_symlink()
    result = subprocess.run([str(home/'.local/bin/omaflow'), 'serve-asr'], env=env, capture_output=True, timeout=3)
    assert result.returncode == 0 and not result.stdout
    print('PASS complete model-free install links app without model commands; speech service stays dormant')
    with (base/'daemon.log').open('w') as daemon_log:
        daemon = subprocess.Popen([str(repo/'target/release/omaflow'), 'daemon'], env=env, stdout=daemon_log, stderr=daemon_log)
        try:
            deadline = time.monotonic()+5
            while not (base/'runtime/omaflow.sock').exists() and time.monotonic() < deadline:
                time.sleep(.02)
            personal.write_text(personal.read_text().replace('"F13"', '"F14"'))
            run('target/release/omaflow', 'reload-config')
            deadline = time.monotonic()+5
            while time.monotonic() < deadline:
                surface = json.loads((base/'runtime/omaflow-state.json').read_text())
                if surface['shortcut_settings']['keys'] == ['F14']:
                    break
                time.sleep(.02)
            assert surface['shortcut_settings']['keys'] == ['F14']
            assert 'F14' in (config/'omaflow/shortcut.lua').read_text()
        finally:
            daemon.terminate(); daemon.wait(timeout=5)
    print('PASS agent TOML edits reload into the daemon and generated Hyprland shortcut')


    saved = personal.read_text()
    old_target = base/'old-preferences.toml'; personal.rename(old_target); personal.symlink_to(old_target)
    run('link-local')
    assert not personal.is_symlink() and personal.read_text() == saved
    assert old_target.read_text() == saved
    assert personal.stat().st_mode & 0o777 == 0o600
    print('PASS relinking pending setup preserves every override from a symlinked config')

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Models)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}'
    personal.write_text(f'[behavior]\nmodels_configured=false\n[backend]\nmodel="test-speech"\ndevice="cpu"\nendpoint="{url}/v1/audio/transcriptions"\n[cleanup]\nmodel="test-cleanup"\nendpoint="{url}/api/chat"\ncustom_vocabulary=["KeepMe"]\n')
    nemo = home/'.local/lib/nemo-speech/bin/nemo-speech'; nemo.parent.mkdir(parents=True)
    nemo.write_text('#!/usr/bin/bash\nprintf "%s\\n" "nemo-speech $*" >> "$TEST_LOG"\n'); nemo.chmod(0o755)
    run('install', '--skip-preflight', '--yes')
    server.shutdown()
    settings = tomllib.loads(personal.read_text())
    assert settings['behavior']['models_configured'] is True
    assert settings['cleanup']['custom_vocabulary'] == ['KeepMe']
    assert 'nemo-speech pull test-speech' in log.read_text()
    print('PASS normal install completes deferred setup using saved models and preserving vocabulary')

    state = home/'.local/state/omaflow'; state.mkdir(parents=True, exist_ok=True)
    (state/'history.json').write_text('["private"]')
    before = (config/'hypr/bindings.lua').read_text()
    (config/'omarchy/plugins/entroit.omaflow').unlink()
    foreign = config/'omarchy/plugins/entroit.omaflow'; foreign.parent.mkdir(parents=True, exist_ok=True); foreign.symlink_to(base)
    result = subprocess.run([str(repo/'uninstall')], env=env, capture_output=True, text=True)
    assert result.returncode != 0 and foreign.is_symlink()
    assert personal.exists() and repo.exists()
    print('PASS foreign-link protection preserves the installation')

    foreign.unlink()
    run('tools/install_receipt.py', 'cleanup-model', 'owned-cleanup')
    run('tools/install_receipt.py', 'cleanup-model', 'owned-cleanup')
    saved_receipt = home/'.local/state/omaflow-install/receipt.json'
    assert json.loads(saved_receipt.read_text()).count({'kind':'cleanup-model', 'value':'owned-cleanup'}) == 1
    assert not any(entry['kind'] == 'nemo-runtime' for entry in json.loads(saved_receipt.read_text()))

    # Exercise the documented plugin-add layout, where the plugin is the checkout.
    plugin_repo = config/'omarchy/plugins/entroit.omaflow'
    repo.rename(plugin_repo)
    repo = plugin_repo
    run('link-local', '--no-models')
    owned_cache = home/'.cache/nemo-speech/models/test/owned'
    owned_cache.mkdir(parents=True); (owned_cache/'weights.gguf').write_text('owned')
    shared_cache = home/'.cache/nemo-speech/models/test/shared'
    shared_cache.mkdir(); (shared_cache/'weights.gguf').write_text('shared')
    receipt = home/'.local/state/omaflow-install/receipt.json'
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps([
        {'kind':'speech-cache', 'value':str(owned_cache)},
        {'kind':'nemo-runtime', 'value':str(nemo.parent.parent)},
        {'kind':'cleanup-model', 'value':'owned-cleanup'},
        {'kind':'package', 'value':'ollama-vulkan'},
    ]))
    sudo = commands/'sudo'
    sudo.write_text('#!/usr/bin/bash\nprintf "%s\\n" "sudo $*" >> "$TEST_LOG"\n')
    sudo.chmod(0o755)
    assert repo.exists() and owned_cache.exists() and receipt.exists()
    run('uninstall')
    assert not repo.exists() and not owned_cache.exists() and not nemo.exists()
    assert not personal.exists() and not receipt.exists() and not state.exists()
    assert (config/'hypr/bindings.lua').read_text() == '-- unrelated settings\n'
    assert not (home/'.local/bin/omaflow').is_symlink()
    assert shared_cache.exists()
    assert 'ollama rm owned-cleanup' in log.read_text()
    assert 'sudo pacman -R --noconfirm ollama-vulkan' in log.read_text()
    assert not (base/'runtime/omaflow-state.json').exists()
    print('PASS complete removal of direct plugin checkout and recorded resources; shared model retained')
