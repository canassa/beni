#!/usr/bin/env python3
"""Issue #131: retain a 63,000-line, 60,000-read field workload.

Run: python3 bench/field-dense.py > .zig-cache/FieldDense.beni
The original review's generator was not retained; this is a replacement.
Use --unannotated to leave receivers flexible when their reads are solved.
"""
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('functions', type=int, nargs='?', default=1000)
parser.add_argument('--unannotated', action='store_true')
args = parser.parse_args()
for i in range(args.functions):
    print(f'-- read{i}: receiver inferred' if args.unannotated else
          f'read{i} : {{ a : Int, b : Int, c : Int }} → Int')
    print(f'read{i} r =')
    for j in range(58):
        print(f'    v{j} = r.{"abc"[j % 3]}')
    print('    r.a + r.b')
    print()
    print()
