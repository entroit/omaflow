#!/usr/bin/env python3
"""Check natural and verbatim dictation through the production pipeline."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT/'target/release/omaflow'
failures = []
with tempfile.TemporaryDirectory(prefix='omaflow-modes-gate-') as directory:
    config = Path(directory)/'config.toml'
    env = dict(os.environ, OMAFLOW_CONFIG=str(config))
    def check(name, overrides, request, predicate, command='evaluate'):
        config.write_text(overrides)
        result = subprocess.run([str(BINARY),command], input=json.dumps(request), capture_output=True, text=True, env=env, timeout=40)
        value = json.loads(result.stdout) if result.returncode == 0 else {'text':'', 'error':result.stderr}
        passed = result.returncode == 0 and predicate(value)
        if not passed:
            failures.append(name)
        print(('PASS' if passed else 'FAIL'), name, json.dumps(value, ensure_ascii=False), flush=True)

    check('verbatim preserves raw wording', '[cleanup]\nstyle="verbatim"\n',
          {'transcript':'um send the report to Alice on Tuesday'}, lambda v:v['text']=='um send the report to Alice on Tuesday')
    check('natural preserves facts', '[cleanup]\nstyle="natural"\n',
          {'transcript':'hey uh please send Alice the report on Tuesday thanks'},
          lambda v: all(word.lower() in v['text'].lower() for word in ['Alice','report','Tuesday']) and not v['fallback'])
    check('verbatim still applies vocabulary', '[cleanup]\nstyle="verbatim"\ncustom_vocabulary=["OmaFlow"]\n',
          {'transcript':'um omaflow is ready'}, lambda v:v['text']=='um OmaFlow is ready')
    check('obsolete snippets and app overrides cannot expand dictation', '[cleanup]\nstyle="verbatim"\n[cleanup.snippets]\n"my signature"="UNWANTED EXPANSION"\n[cleanup.app_styles]\nbrowser="formal"\n',
          {'transcript':'my signature','window':{'class':'browser'}}, lambda v:v['text']=='my signature')
if failures:
    raise SystemExit('Failed: '+', '.join(failures))
