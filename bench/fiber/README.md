# Fiber benchmarks and cost ratchets

Build the development benchmark library, then use the existing Node or Chrome
runner. All suspendable workloads enter through Beni `run*` functions. JavaScript
supplies the completion callback, not the work thunk: a JavaScript thunk does not
forward a parked Beni function's resumed result under the completion convention.
The same `workloads.mjs` drives both hosts.

```sh
zig build
./zig-out/bin/beni build --library --platform=node --out=zig-out/fiber bench/fiber/Bench.beni
node bench/fiber/node.mjs zig-out/fiber
```

Time remains outside the gates. The runners check every completed answer before
reporting their warm-up/median timing results. Their comparisons use Effect v4
from this directory's pinned package.json.

`zig build test-blackbox-fiber-cost` runs the benchmark bridge check and all cost
ratchets. It is included in `zig build gates`. To print the full measurements:

```sh
node bench/fiber/cost.mjs ./zig-out/bin/beni zig-out/fiber-cost
node bench/size.mjs --fibers-only
```

`budgets.json` contains today's values as ceilings, not the redesign's targets.
The fast path currently allocates about 208 bytes/point under the controlled
measurement. Zero is its target; setting its current cap to zero correctly fails.
Tighten caps after improvements. Do not bless a growth merely to pass the gate.

The memory and allocation programs use only public Task, Deferred, List and Io
APIs. A test/benchmark platform supplies count and measurement markers. It reads
process heap usage and forces GC; it never inspects Task internals.

Each program runs in a fresh pinned Node process with `--jitless --predictable
--expose-gc --trace-gc --max-semi-space-size=512 --min-semi-space-size=512`.
Disabling JIT removes tiering and allocation-elision variance. Retained bytes are
sampled after GC; allocated bytes are sampled before GC. Forced GC trace records
must surround each interval, and allocation intervals must contain no GC.
The completed-fiber case holds handles in a Beni List, as in the review.

Each cap is the exact integer difference between two counts, not a rounded
bytes-per-unit number. Memory, spawn/join and yield use 2,048 and 4,096; the fast
path uses 500,000 and 1,000,000 points. Three independent initial rounds produced
identical raw deltas; one complete round took about 2.3–2.4 seconds on the rebased head (4.2–4.5 in the initial loaded run).
Display values are rounded, but the gate checks every byte of the delta.
These controlled interpreter measurements differ from normal-JIT timing and
heap measurements; compare like with like.

The black-box run hashes cover emitted programs, the cost script, the budget
literals, the test target architecture and the pinned Node version. Unchanged
verified output skips the measurement processes. Changed caps also invalidate
the record. Refresh with `zig build test-run-hashes -Dtest-filter='fiber '`.

S0–S5 live under `tests/corpus/emit/release/app/FiberS*`. Their release goldens pin
the whole hoisted module, and the cost suite runs each program to check its answer.
Brotli-11 caps use a size hint and count the whole emitted `.mjs` graph,
concatenated in sorted order as bench/size.mjs does. S0–S5 currently each emit
one hoisted `_main.mjs`; maps are excluded.
`bench/size.mjs` also enforces these caps on its new S-program fiber rows; its
other existing fiber rows remain informational. `--dev-only` omits the release
column, while the gated cost suite always builds release.
