#!/usr/bin/env python3
"""Exercise complete installer/linker and uninstall flows in an isolated home."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def commit(repo, message):
    subprocess.run(['/usr/bin/git', '-C', str(repo), 'add', '.'], check=True)
    subprocess.run(['/usr/bin/git', '-C', str(repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', message], check=True)


def checkout(repo):
    """A committed OmaFlow folder from github.com/entroit/omaflow, as plugin add leaves it."""
    repo.mkdir()
    for name in ['install', 'link-local', 'uninstall', 'manifest.json', 'Cargo.toml']:
        shutil.copy2(ROOT/name, repo/name)
    for name in ['config', 'dist', 'integrations', 'assets']:
        shutil.copytree(ROOT/name, repo/name)
    (repo/'tools').mkdir(); shutil.copy2(ROOT/'tools/set_hotkey.py', repo/'tools/set_hotkey.py')
    shutil.copytree(ROOT/'scripts', repo/'scripts')
    shutil.copy2(ROOT/'tools/install_receipt.py', repo/'tools/install_receipt.py')
    shutil.copy2(ROOT/'tools/journal_folder.py', repo/'tools/journal_folder.py')
    (repo/'target/release').mkdir(parents=True)
    shutil.copy2(ROOT/'target/release/omaflow', repo/'target/release/omaflow')
    subprocess.run(['/usr/bin/git', 'init', '-q', '-b', 'main', str(repo)], check=True)
    commit(repo, 'fixture')
    subprocess.run(['/usr/bin/git', '-C', str(repo), 'remote', 'add', 'origin', 'https://github.com/entroit/omaflow'], check=True)


def stub_commands(commands):
    """Desktop and system commands that only log what they were asked. TEST_MISSING
    names packages pacman says are not installed; sudo always fails."""
    commands.mkdir()
    for name in ['cargo','pacman','systemctl','hyprctl','omarchy','omarchy-shell','pw-cat','wl-copy','wl-paste','git','update-desktop-database','ollama','curl','sudo']:
        body = f'printf "%s\\n" "{name} $*" >> "$TEST_LOG"\n'
        if name == 'hyprctl': body += '''if [[ $* == '-j binds' ]]; then echo '[]'; fi\n'''
        if name == 'omarchy': body += '''if [[ $* == 'plugin list --json' ]]; then echo '[{"id":"entroit.omaflow","enabled":true}]'; fi\n'''
        if name == 'pacman': body += '''if [[ $1 == -Qq && " ${TEST_MISSING:-} " == *" $2 "* ]]; then exit 1; fi\n'''
        if name == 'sudo': body += 'exit 1\n'
        path = commands/name; path.write_text('#!/usr/bin/bash\n'+body+'exit 0\n'); path.chmod(0o755)


with tempfile.TemporaryDirectory(prefix='omaflow-install-') as directory:
    base = Path(directory); repo = base/'checkout'
    home = base/'home'; home.mkdir(); commands = base/'bin'
    config = home/'.config'; (config/'hypr').mkdir(parents=True)
    (config/'hypr/omaflow-hotkey.lua').write_text('local omaflow_hotkey = { "F13" }\nlocal omaflow_consumed_keys = { "F13" }\nreturn { hotkey = omaflow_hotkey, consumed = omaflow_consumed_keys }\n')
    (config/'hypr/bindings.lua').write_text('-- unrelated settings\n')
    checkout(repo)
    release_installer = repo/'scripts/install-release'
    direct_git = repo/'.git'; saved_git = repo/'.git.saved'
    direct_git.rename(saved_git); direct_git.write_text('gitdir: /tmp/not-trusted\n')
    rejected = subprocess.run([str(release_installer)], env=dict(os.environ, HOME=str(home)), capture_output=True, text=True)
    assert rejected.returncode != 0 and 'linked worktree' in rejected.stderr
    direct_git.unlink(); saved_git.rename(direct_git)
    manifest = repo/'manifest.json'; manifest_bytes = manifest.read_bytes(); manifest.rename(repo/'manifest.real')
    manifest.symlink_to(repo/'manifest.real')
    rejected = subprocess.run([str(release_installer)], env=dict(os.environ, HOME=str(home)), capture_output=True, text=True)
    assert rejected.returncode != 0 and 'regular in-repository file' in rejected.stderr
    manifest.unlink(); (repo/'manifest.real').rename(manifest)
    subprocess.run(['/usr/bin/git', '-C', str(repo), 'update-index', '--skip-worktree', 'manifest.json'], check=True)
    manifest.write_bytes(manifest_bytes + b'\n')
    rejected = subprocess.run([str(release_installer)], env=dict(os.environ, HOME=str(home)), capture_output=True, text=True)
    assert rejected.returncode != 0 and 'differs from HEAD' in rejected.stderr
    manifest.write_bytes(manifest_bytes)
    subprocess.run(['/usr/bin/git', '-C', str(repo), 'update-index', '--no-skip-worktree', 'manifest.json'], check=True)
    print('PASS production release install rejects linked worktrees, symlinks, and hidden byte drift')
    log = base/'commands.log'
    stub_commands(commands)
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(config), XDG_CACHE_HOME=str(home/".cache"), XDG_STATE_HOME=str(home/'.local/state'),
               XDG_RUNTIME_DIR=str(base/'runtime'), PATH=f'{commands}:/usr/bin', TEST_LOG=str(log),
               OMAFLOW_CONFIG=str(config/'omaflow/config.toml'), HYPRLAND_INSTANCE_SIGNATURE='test')
    (base/'runtime').mkdir()
    def run(*args):
        result = subprocess.run([str(repo/args[0]), *args[1:]], env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stdout + result.stderr
        return result.stdout
    plan = run('install', '--skip-preflight', '--dry-run')
    assert not (config/'omaflow/config.toml').exists()
    assert 'Download no models' in plan
    output = run('install', '--skip-preflight', '--yes')
    personal = config/'omaflow/config.toml'
    assert tomllib.loads(personal.read_text())['behavior']['models_configured'] is False
    complete = tomllib.loads(personal.read_text())
    defaults = tomllib.loads((ROOT/'config/config.toml').read_text())
    for section, values in defaults.items():
        assert set(values) <= set(complete[section]), section
    assert complete['shortcut'] == {'keys':['F13'], 'consumed':['F13'], 'window':'SUPER + SHIFT + V', 'journal':'', 'open_journal':'', 'todo':'', 'open_todos':''}
    assert complete['cleanup']['system_prompt'] == defaults['cleanup']['system_prompt']
    assert (config/'hypr/omaflow-hotkey.lua').is_symlink()
    assert 'F13' in (config/'omaflow/shortcut.lua').read_text()

    assert not (home/'.local/state/omaflow-install/receipt.json').exists()
    assert 'no speech model yet' in output
    assert 'choose a speech model in the OmaFlow window' in output
    assert not any(word in log.read_text() for word in ['ollama ', 'nemo-speech', 'curl ']), log.read_text()
    assert (home/'.local/bin/omaflow').is_symlink()
    for unit in ['omaflow.service', 'omaflow-update.service', 'omaflow-update-reconcile.service', 'omaflow-update-check.service', 'omaflow-update-check.timer']:
        assert (config/'systemd/user'/unit).is_symlink(), unit
    # The sandboxed daemon is given the default journal folder before it starts.
    assert (home/'Documents/Journal').is_dir()
    assert str(home/'Documents/Journal') in (config/'systemd/user/omaflow.service.d/journal-folder.conf').read_text()
    result = subprocess.run([str(home/'.local/bin/omaflow'), 'serve-asr'], env=env, capture_output=True, timeout=3)
    assert result.returncode == 0 and not result.stdout
    print('PASS app-only install links the app and downloads nothing; speech service stays dormant')
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
            transaction_id = 'installation-test'
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(str(base/'runtime/omaflow.sock'))
                client.sendall(f'prepare-update:{transaction_id}'.encode())
            daemon.wait(timeout=5)
            assert (base/f'runtime/omaflow-update-ready-{transaction_id}').read_text() == 'ready\n'
            print('PASS an idle daemon acknowledges the update gate and exits cleanly')
        finally:
            if daemon.poll() is None:
                daemon.terminate(); daemon.wait(timeout=5)
    print('PASS agent TOML edits reload into the daemon and generated Hyprland shortcut')

    # With OmaFlow stopped a valid file waits for its next start, so the shell
    # has nothing to warn about; a broken one says why on one line.
    run('target/release/omaflow', 'reload-config')
    good = personal.read_text()
    personal.write_text(good + '\n[cleanup]\nmodel = "unclosed\n')
    broken = subprocess.run([str(repo/'target/release/omaflow'), 'reload-config'], env=env, capture_output=True, text=True, timeout=30)
    personal.write_text(good)
    reason = broken.stderr.strip()
    assert broken.returncode != 0 and '\n' not in reason and 'TOML parse error at line' in reason, broken.stderr
    print('PASS reload-config with OmaFlow stopped succeeds, and a broken file says why')


    saved = personal.read_text()
    old_target = base/'old-preferences.toml'; personal.rename(old_target); personal.symlink_to(old_target)
    run('link-local')
    assert not personal.is_symlink() and personal.read_text() == saved
    assert old_target.read_text() == saved
    assert personal.stat().st_mode & 0o777 == 0o600
    print('PASS relinking pending setup preserves every override from a symlinked config')

    personal.write_text('[behavior]\nmodels_configured=false\n[backend]\nmodel="test-speech"\ndevice="cpu"\n[cleanup]\nmodel="test-cleanup"\ncustom_vocabulary=["KeepMe"]\n')
    nemo = home/'.local/lib/nemo-speech/bin/nemo-speech'; nemo.parent.mkdir(parents=True)
    nemo.write_text('#!/usr/bin/bash\nprintf "%s\\n" "nemo-speech $*" >> "$TEST_LOG"\n'); nemo.chmod(0o755)
    log.write_text('')
    reinstall_output = run('install', '--skip-preflight', '--yes')
    settings = tomllib.loads(personal.read_text())
    # A re-install must not claim the models are ready; only a model the user
    # actually downloaded in Settings may say that.
    assert settings['behavior']['models_configured'] is False
    assert settings['cleanup']['custom_vocabulary'] == ['KeepMe']
    assert 'existing model configuration is preserved' in reinstall_output
    assert 'OmaFlow is ready with your existing settings.' in reinstall_output
    assert 'no model configured yet' not in reinstall_output
    assert not any(word in log.read_text() for word in ['ollama ', 'nemo-speech', 'curl ']), log.read_text()
    print('PASS a re-install downloads nothing and preserves saved settings')

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
    ]))
    sudo = commands/'sudo'
    sudo.write_text('#!/usr/bin/bash\nprintf "%s\\n" "sudo $*" >> "$TEST_LOG"\n')
    sudo.chmod(0o755)
    assert repo.exists() and owned_cache.exists() and receipt.exists()
    # Without --yes it lists what goes and asks; no answer removes nothing.
    declined = subprocess.run([str(repo/'uninstall')], env=env, capture_output=True, text=True, input='', timeout=30)
    assert declined.returncode == 0 and 'Nothing was removed.' in declined.stdout, declined.stdout + declined.stderr
    assert repo.exists() and owned_cache.exists() and receipt.exists() and personal.exists()
    run('uninstall', '--yes')
    assert not repo.exists() and not owned_cache.exists() and not nemo.exists()
    assert not personal.exists() and not receipt.exists() and not state.exists()
    assert (config/'hypr/bindings.lua').read_text() == '-- unrelated settings\n'
    assert not (home/'.local/bin/omaflow').is_symlink()
    assert shared_cache.exists()
    assert 'ollama rm owned-cleanup' in log.read_text()
    # ./install no longer installs Ollama, so ./uninstall must not remove the package.
    assert 'pacman -R' not in log.read_text()
    assert not (base/'runtime/omaflow-state.json').exists()
    print('PASS complete removal of direct plugin checkout and recorded resources; shared model retained')


# Finish setup in the window runs ./install --from-window, detached: no
# questions, no sudo, and its progress and result in a status file.
with tempfile.TemporaryDirectory(prefix='omaflow-setup-') as directory:
    base = Path(directory); repo = base/'plugins/entroit.omaflow'; repo.parent.mkdir()
    home = base/'home'; config = home/'.config'; config.mkdir(parents=True)
    commands = base/'bin'; stub_commands(commands)
    runtime = base/'runtime'; runtime.mkdir()
    log = base/'commands.log'; log.write_text('')
    checkout(repo)
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(config), XDG_CACHE_HOME=str(home/'.cache'),
               XDG_STATE_HOME=str(home/'.local/state'), XDG_RUNTIME_DIR=str(runtime), PATH=f'{commands}:/usr/bin',
               TEST_LOG=str(log), OMAFLOW_CONFIG=str(config/'omaflow/config.toml'), HYPRLAND_INSTANCE_SIGNATURE='test')
    status_file = runtime/'omaflow-setup.json'

    def setup(*options, **extra):
        return subprocess.run([str(repo/'install'), '--from-window', *options], env=dict(env, **extra),
                              capture_output=True, text=True, timeout=60)

    def status():
        return json.loads(status_file.read_text())

    def snapshot():
        files = {}
        for path in sorted(home.rglob('*')):
            if path.is_symlink(): files[str(path)] = 'link ' + os.readlink(path)
            elif path.is_file(): files[str(path)] = path.read_bytes()
        return files

    # A missing package stops it before anything changes, with the command.
    untouched = snapshot()
    missing = setup(TEST_MISSING='jq wl-clipboard')
    assert missing.returncode != 0
    assert status()['state'] == 'needs-packages', status()
    assert status()['command'] == 'sudo pacman -S --needed jq wl-clipboard', status()
    assert status()['missing'] == 'jq wl-clipboard'
    assert 'sudo pacman -S --needed jq wl-clipboard' in (runtime/'omaflow-setup.log').read_text()
    assert snapshot() == untouched and not (home/'.local').exists()
    assert not any(line.split()[0] in ('sudo', 'systemctl', 'hyprctl', 'omarchy') for line in log.read_text().splitlines()), log.read_text()
    print('PASS a missing package stops the window setup before any change and names the command')

    # Check again only checks: still missing says so, present clears the way.
    checked = setup('--dry-run', TEST_MISSING='jq')
    assert checked.returncode != 0 and status()['command'] == 'sudo pacman -S --needed jq'
    checked = setup('--dry-run')
    assert checked.returncode == 0 and status()['state'] == 'checked', checked.stdout + checked.stderr
    assert snapshot() == untouched
    print('PASS Check again re-checks the packages and changes nothing')

    # A fresh home: the whole install, without sudo.
    log.write_text('')
    first = setup()
    assert first.returncode == 0, (runtime/'omaflow-setup.log').read_text()
    assert status()['state'] == 'ok' and status()['from'] == '', status()
    assert status()['message'] == 'OmaFlow is installed. Your dictation key is AltGr+Menu.', status()
    assert not any(line.startswith('sudo ') for line in log.read_text().splitlines())
    assert 'omarchy restart shell' in log.read_text() and 'systemctl --user restart omaflow.service' in log.read_text()
    assert (home/'.local/bin/omaflow').is_symlink()
    assert (config/'hypr/bindings.lua').read_text().count('require("omaflow")') == 1
    assert 'ISO_Level3_Shift' in (config/'omaflow/shortcut.lua').read_text()
    installed = json.loads((home/'.local/state/omaflow/update/installed.json').read_text())
    assert installed['version'] == json.loads((repo/'dist/release.json').read_text())['version']
    print('PASS the window setup installs a fresh home without sudo and reports the dictation key')

    # Run twice, same result: nothing is added, moved or backed up again.
    settled = snapshot()
    again = setup()
    assert again.returncode == 0 and status()['state'] == 'ok', (runtime/'omaflow-setup.log').read_text()
    changed = [path for path in set(settled) | set(snapshot()) if settled.get(path) != snapshot().get(path)]
    # Only the receipt's install time moves.
    assert changed == [str(home/'.local/state/omaflow/update/installed.json')], changed
    assert not (config/'omarchy/backups').exists()
    print('PASS a second window setup is a no-op')

    # A failing step leaves its own words as the reason, not "running".
    hyprctl = (commands/'hyprctl').read_text()
    (commands/'hyprctl').write_text('#!/usr/bin/bash\nif [[ $1 == configerrors ]]; then printf "bindings.lua:3: bad bind\\nbindings.lua:4: bad bind\\n"; fi\nexit 0\n')
    failed = setup()
    assert failed.returncode != 0 and status()['state'] == 'failed', status()
    assert status()['message'] == 'Hyprland rejected the configuration: bindings.lua:3: bad bind; bindings.lua:4: bad bind', status()
    assert status()['log'] == str(runtime/'omaflow-setup.log')
    (commands/'hyprctl').write_text(hyprctl)
    print('PASS a failed window setup says why')

    # omarchy plugin update brought a new release: the same setup installs it.
    release = json.loads((repo/'dist/release.json').read_text())
    bundled = repo/release['binary']['path']
    major, minor, _ = json.loads((ROOT/'manifest.json').read_text())['version'].split('.')
    newer = f"{major}.{int(minor) + 1}.0"
    bundled.write_text('#!/usr/bin/bash\nif [[ $1 == version ]]; then echo \'{"pluginId":"entroit.omaflow","version":"' + newer + '"}\'; exit 0; fi\n'
                       f'exec {ROOT/"target/release/omaflow"} "$@"\n')
    bundled.chmod(0o755)
    release['version'] = newer
    release['binary']['bytes'] = bundled.stat().st_size
    release['binary']['sha256'] = hashlib.sha256(bundled.read_bytes()).hexdigest()
    (repo/'dist/release.json').write_text(json.dumps(release, indent=2) + '\n')
    manifest = json.loads((repo/'manifest.json').read_text()); manifest['version'] = newer
    (repo/'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    commit(repo, 'release ' + newer)
    updated = setup()
    assert updated.returncode == 0, (runtime/'omaflow-setup.log').read_text()
    assert status() | {'updatedAtMs': 0} == {'updatedAtMs': 0, 'from': installed['version'], 'state': 'ok', 'message': f'OmaFlow is updated to {newer}.'}, status()
    assert (home/'.local/lib/omaflow/current/omaflow').read_bytes() == bundled.read_bytes()
    assert json.loads((home/'.local/state/omaflow/update/installed.json').read_text())['version'] == newer
    print('PASS after a plugin update the window setup installs the new bundled binary')
