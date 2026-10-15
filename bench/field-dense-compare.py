#!/usr/bin/env python3
"""Interleaved cold checks; retain wall time, phase trace and output equality.

Usage: python3 bench/field-dense-compare.py BEFORE AFTER FIELD_FILE CORPUS
Build both binaries with zorg build -Doptimize=ReleaseFast; generate the corpus
with zorg build bench -- --generate=100000 --iterations=1, then migrate its
removed names: BEFORE fmt --migrate-names .zig-cache/bench-gen.
"""
import json
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time

before, after, *inputs = sys.argv[1:]
results = []
with tempfile.TemporaryDirectory(prefix='beni-fields-') as tmp:
    for source in inputs:
        rows = {'before': [], 'after': []}
        output = None
        for round in range(9):
            order = [('before', before), ('after', after)]
            if round % 2:
                order.reverse()
            for label, binary in order:
                trace = Path(tmp) / 'trace.json'
                start = time.perf_counter()
                run = subprocess.run([binary, 'check', '--jobs=1', '--no-cache',
                                      f'--self-profile={trace}', source], capture_output=True)
                wall = (time.perf_counter() - start) * 1000
                assert run.returncode == 0, run.stderr.decode()[:2000]
                streams = (run.stdout, run.stderr)
                if output is None:
                    output = streams
                assert output == streams, (source, label, 'output changed')
                phases = {}
                for event in json.loads(trace.read_text())['traceEvents']:
                    if event.get('ph') == 'X':
                        name = event['name']
                        phases[name] = phases.get(name, 0) + event['dur'] / 1000
                if round:  # first pair warms files and executable pages
                    rows[label].append({'wall_ms': wall, **phases})
        summary = {label: {phase: statistics.median(row[phase] for row in samples)
                           for phase in samples[0]} for label, samples in rows.items()}
        results.append({'input': source, 'summary_ms': summary, 'runs_ms': rows})
print(json.dumps(results, indent=2))
