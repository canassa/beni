#!/usr/bin/env python3
"""Compare pre-nullary, master and PR LLVM ReleaseSafe binaries on identical inputs.

Usage: python3 bench/field-dense-three-way.py PRE MASTER PR INPUT [INPUT ...]
Build each revision with `zorg build beni-fmt-check -Dllvm --verbose`; use
its zig-out/safe-llvm/bin/beni. Each worktree must have a separate local cache.
Generate the field file with field-dense.py and the 100k corpus with
`zorg build bench -- --generate=100000 --iterations=1`. Apply the existing
`beni fmt --migrate-names` to the generated corpus before measuring any binary.
"""
import hashlib
import itertools
import json
from pathlib import Path
import resource
import statistics
import subprocess
import sys
import tempfile
import time


def fingerprint(source):
    root = Path(source)
    files = sorted(root.rglob('*.beni')) if root.is_dir() else [root]
    digest = hashlib.sha256()
    lines = 0
    for path in files:
        name = str(path.relative_to(root)) if root.is_dir() else path.name
        data = path.read_bytes()
        digest.update(name.encode() + b'\0' + data + b'\0')
        lines += data.count(b'\n')
    return {'sha256': digest.hexdigest(), 'files': len(files), 'lines': lines}


pre, master, pr, *inputs = sys.argv[1:]
binaries = dict(zip(('pre_126', 'master', 'pr'), (pre, master, pr)))
orders = list(itertools.permutations(binaries))
results = []
with tempfile.TemporaryDirectory(prefix='beni-three-way-') as tmp:
    for source in inputs:
        rows = {name: [] for name in binaries}
        expected = None
        for round_index in range(13):
            # One warm-up triple, then two cycles through all six orders.
            order = orders[(round_index - 1) % len(orders)]
            for label in order:
                trace = Path(tmp) / 'trace.json'
                cpu_start = resource.getrusage(resource.RUSAGE_CHILDREN)
                start = time.perf_counter()
                run = subprocess.run([
                    binaries[label], 'check', '--jobs=1', '--no-cache',
                    '--diagnostics=json', f'--self-profile={trace}', source,
                ], capture_output=True)
                wall_ms = (time.perf_counter() - start) * 1000
                cpu_end = resource.getrusage(resource.RUSAGE_CHILDREN)
                cpu_ms = ((cpu_end.ru_utime + cpu_end.ru_stime)
                          - (cpu_start.ru_utime + cpu_start.ru_stime)) * 1000
                assert run.returncode == 0, (source, label, run.stderr[:2000])
                streams = (run.returncode, run.stdout, run.stderr)
                if expected is None:
                    expected = streams
                assert expected == streams, (source, label, 'output changed')
                phases = {}
                for event in json.loads(trace.read_text())['traceEvents']:
                    if event.get('ph') == 'X':
                        name = event['name']
                        phases[name] = phases.get(name, 0) + event['dur'] / 1000
                if round_index:
                    rows[label].append({'wall_ms': wall_ms, 'cpu_ms': cpu_ms, **phases})
        summary = {
            label: {phase: statistics.median(row[phase] for row in samples)
                    for phase in samples[0]}
            for label, samples in rows.items()
        }
        recovery = {}
        for phase in ('check', 'constrain', 'solve', 'wall_ms', 'cpu_ms'):
            baseline, current, fixed = (summary[label][phase] for label in binaries)
            overhead = current - baseline
            recovery[phase] = {
                'master_minus_pre_ms': overhead,
                'pr_minus_pre_ms': fixed - baseline,
                'removed_fraction': (current - fixed) / overhead if overhead > 0 else None,
            }
        results.append({
            'input': source, **fingerprint(source), 'runs_per_binary': 12,
            'stdout_sha256': hashlib.sha256(expected[1]).hexdigest(),
            'stderr_sha256': hashlib.sha256(expected[2]).hexdigest(),
            'summary_ms': summary, 'overhead': recovery, 'runs_ms': rows,
        })
print(json.dumps({'binaries': binaries, 'results': results}, indent=2))
