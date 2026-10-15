#!/usr/bin/env python3
"""Byte-compare valid dump invocations: BEFORE AFTER INPUT [INPUT ...].

Run from the repository root. Includes every standalone interface/dispatch
fixture, then types/interface/dispatch/raw for files and interface/dispatch/raw
for projects. Unlike check, dump does not accept --no-cache; types needs a file.
Contextual core/markup fixtures stay with the corpus harness, which supplies
their privileged/platform context. Every compared invocation must succeed;
matching usage errors or missing-context diagnostics are never evidence.
"""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess
import sys

before, after, *inputs = sys.argv[1:]
requests = []
for suffix, stage in [('iface', 'interface'), ('dispatch', 'dispatch')]:
    for golden in sorted(Path('tests/corpus').rglob('*.' + suffix)):
        if 'core' in golden.parts or 'markup' in golden.parts:
            continue
        source = golden.with_suffix('.beni')
        if source.exists():
            requests.append(('dump', '--diagnostics=json', '--stage=' + stage, str(source)))
for source in inputs:
    stages = ['interface', 'dispatch', 'raw']
    if Path(source).is_file():
        stages.insert(0, 'types')
    for stage in stages:
        requests.append(('dump', '--diagnostics=json', '--stage=' + stage, source))
requests = list(dict.fromkeys(requests))


def compare(args):
    runs = [subprocess.run([binary, *args], capture_output=True) for binary in [before, after]]
    for run in runs:
        assert run.returncode == 0, (args, run.returncode, run.stderr[:1000])
        assert run.stdout, (args, 'successful dump was empty')
    a, b = runs
    assert (a.returncode, a.stdout, a.stderr) == (b.returncode, b.stdout, b.stderr), (args, 'output changed')
    return {'args': args, 'exit': a.returncode,
            'stdout_sha256': hashlib.sha256(a.stdout).hexdigest(),
            'stderr_sha256': hashlib.sha256(a.stderr).hexdigest()}


with ThreadPoolExecutor(max_workers=3) as pool:
    rows = list(pool.map(compare, requests))
print(json.dumps({'before': before, 'after': after, 'commands': len(rows),
                  'differences': [], 'runs': rows}, indent=2))
