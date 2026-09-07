#!/usr/bin/env python3
"""Resolve OmaFlow's model settings the way the daemon does, and print them.

This used to feed shell variables into ./install and gate ./link-local. The
installer no longer installs models, so both of those callers are gone; what
remains is a way for tests and for a person debugging a machine to see the
merged bundled-plus-personal model configuration as JSON.
"""
import argparse
import json
import os
from pathlib import Path
import sys
import tomllib

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


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    try:
        print(json.dumps(configuration()))
    except (ValueError, KeyError, OSError) as error:
        print(f'Model configuration: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
