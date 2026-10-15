# Conduit measurements

The 2026-10-14 artifacts retain the built-platform measurements and the
criterion-7 stop. [Research 94](../../../docs/design/research/94-browser-direct-conduit.md)
explains the subjects, units, limits and generating commands (§6).

- `analysis.json`: `BENI=zig-out/safe/bin/beni node bench/writesets/stats.mjs --json`
- `counts.json`: `node bench/conduit/measure.mjs`
- `timing.json`: `node bench/conduit/time.mjs --chrome="$BENI_CHROME"`
- `floor.jsonl`: `node bench/size.mjs --beni=zig-out/safe/bin/beni --pages-only`
- `budgets.json`: fresh corpus runs and grant-removal probes described in §5.

Run commands from the repository root with `direnv exec .`. Counts use
instrumented copies; bytes and timings use clean output. The CPU fallback
records CPU spending and scales grant ratios; it does not count instructions.

The 2026-10-15 artifacts measure parameterised helper templates against the
exact research-94 compiler binary and current browser-tea. [Research 95](../../../docs/design/research/95-parameterised-markup-templates.md)
records the general rule, corpus-wide visit invariant, precise/fallback shapes,
validation and remaining cost. `counts.json` adds predicted versus actual
instance/group counts and template work counters; timing remains uninstrumented.
Use `BASELINE_BENI=<research-94 compiler>` for `measure.mjs`, then
`time.mjs --baseline=browser-direct-before-release --samples=15`.

The `2026-10-15-rebased-*` files are the final post-review batch on master
`df04ca2db`, including the shared volatile-row fact repair. They supersede the
first 2026-10-15 batch for the final PR measurements; both batches are retained.
Master's hardware-budget gate now refuses this macOS host; research 95 §7
separates the local native/LLVM suites from the still-owed Linux budget gate.

The [2026-10-15 profile archive](2026-10-15-profiles/README.md) and
[research 97](../../../docs/design/research/97-conduit-dispatch-profiles.md)
retain Chrome CPU/heap profiles, code and compressed-byte attribution,
shared-code before/after measurements and the full report-87 sweeps.
