# Schema prototype runner

This is the runner for the dated 2026-09-22 research artifact, not a build or CI
gate. `results.json` is a captured run, not a golden performance budget.

`run.mjs` is a black-box probe. It copies the ordinary library and scenario
sources into a fresh temporary source root, invokes the installed compiler,
runs emitted JavaScript, and removes the whole temporary tree in a `finally`
block. It does not import compiler internals.

Run it with the repository's pinned Node 24 and compiler:

```sh
nix develop --command node bench/schema-prototype/run.mjs
```

The runner performs development and release builds at `--jobs=1` and
`--jobs=8`, byte-compares each mode's two complete output trees, and executes
all four entry modules. Every execution must produce exactly one JSON line and
the complete ordered label list in `cases/expected-labels.json`; duplicate,
missing, unexpected, malformed, or false results fail the run.

Directories under `cases/negative/` are separate compiler projects. Each is
built from all its `.beni` files plus the shared library, must exit 1, must write
no output or cache file (`--no-cache` is explicit), and must exactly match its
whole `expected.diag.json` array.

Output size is all emitted `.mjs` source, both raw and concatenated before
Brotli quality 11. It is reported independently for every build.

The browser pass launches the pinned machine's headless Chrome through the
DevTools protocol with a bounded startup, command, and shutdown lifetime. It
first checks the entire structured result against Node. It then imports the
emitted `Benchmark.mjs`, requires exactly one function export, and times that
function's explicit repeated Beni workload. The report includes every sample,
the median for one call, and the median divided by the workload's iteration
count. Its checksum is checked against `cases/benchmark-expected.json`. This is
a measurement of that named mixed workload only: it is not a claim of Effect
parity, it is not generic parsing throughput, and separate per-schema-operation
medians remain deferred.

Use `--no-browser` for a semantics-only run, or `--beni=/absolute/path` to test
another installed compiler. Host Node 22 is deliberately refused so the
compiler boundary and emitted-program boundary use the pinned Node 24.
