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
