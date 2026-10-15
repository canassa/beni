#!/usr/bin/env python3
"""Issue #131: retain a 63,000-line, 60,000-read known-record workload.

Run: python3 bench/field-dense.py > .zig-cache/FieldDense.beni
The original review's generator was not retained; this is a replacement.
"""
import sys

for i in range(int(sys.argv[1]) if len(sys.argv) > 1 else 1000):
    print(f'read{i} : {{ a : Int, b : Int, c : Int }} → Int')
    print(f'read{i} r =')
    for j in range(58):
        print(f'    v{j} = r.{"abc"[j % 3]}')
    print('    r.a + r.b')
    print()
    print()
