#!/usr/bin/env python3
"""Read the same bundled defaults and personal model overrides as OmaFlow."""
import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]

def configuration():
    config = tomllib.loads((ROOT / 'config/config.toml').read_text())
    personal = Path(os.environ.get('OMAFLOW_CONFIG', str(Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home()/'.config'))) / 'omaflow/config.toml')))
    if personal.exists():
        overrides = tomllib.loads(personal.read_text())
        for section in ['backend', 'cleanup', 'behavior']:
            config.setdefault(section, {}).update(overrides.get(section, {}))
    backend, cleanup = config['backend'], config['cleanup']
    if backend['engine'] not in ['nemo', 'parakeet', 'openai', 'whisper-cpp']:
        raise ValueError('Unsupported speech engine')
    if backend['model'] == 'parakeet-tdt-0.6b-v3':
        backend['model'] = 'nvidia/parakeet-tdt-0.6b-v3'
    for value in [backend['model'], cleanup['model'], backend['endpoint'], cleanup['endpoint'], backend.get('health_endpoint', ''), backend['device']]:
        if not isinstance(value, str) or any(ord(c) < 32 for c in value):
            raise ValueError('Invalid model setting')
    if not cleanup['endpoint'].endswith('/api/chat'):
        raise ValueError('Ollama endpoint must end in /api/chat')
    return config

def check(config):
    backend, cleanup = config['backend'], config['cleanup']
    if not config['behavior'].get('models_configured', True):
        print('Models not configured; model checks deferred until setup.')
        return
    if backend['engine'] in ['nemo', 'parakeet']:
        if not os.access(Path.home()/'.local/lib/nemo-speech/bin/nemo-speech', os.X_OK):
            raise ValueError('NeMo-Speech is missing. Run ./install to install the configured speech runtime.')
        if backend['device'] == 'cuda' and not shutil.which('nvidia-smi'):
            raise ValueError('The configured CUDA speech backend needs an NVIDIA driver, or choose device="cpu".')
    if cleanup['enabled']:
        base = cleanup['endpoint'].removesuffix('/api/chat')
        with urllib.request.urlopen(base+'/api/tags', timeout=3) as response:
            models = json.load(response).get('models', [])
        if not any(m.get('name', '').removesuffix(':latest') == cleanup['model'].removesuffix(':latest') for m in models):
            raise ValueError(f"Cleanup model {cleanup['model']} is missing. Install it separately with OLLAMA_HOST={base} ollama pull {cleanup['model']}")
    print('Configured model prerequisites passed.')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shell-values', action='store_true')
    parser.add_argument('--check', action='store_true')
    args=parser.parse_args()
    try:
        config=configuration(); backend=config['backend']; cleanup=config['cleanup']
        if args.shell_values:
            for value in [backend['engine'], backend['model'], backend['endpoint'], backend['device'], cleanup['model'], cleanup['endpoint'].removesuffix('/api/chat'), int(cleanup['enabled']), backend.get('health_endpoint',''), int(config['behavior'].get('models_configured', True))]:
                print(value)
        elif args.check: check(config)
        else: print(json.dumps(config))
    except (ValueError, KeyError, OSError, urllib.error.URLError) as error:
        print(f'Model configuration: {error}', file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
