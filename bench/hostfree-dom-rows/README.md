# Typed row correctness probe

This driver supplies the frozen private Protocol/RowRecipe ABI from JavaScript
and runs the compiler-built row library in happy-dom. It is correctness evidence,
not a producer fixture or a performance benchmark. PR performance results must
use report 29's harness with the wired producer.

Build the ordinary library clients from the repository root:

```sh
beni build --library --platform=browser --root=bench/hostfree-dom-rows --out=zig-out/rows-dev bench/hostfree-dom-rows/RowsClient.beni
beni build --library --release --platform=browser --root=bench/hostfree-dom-rows --out=zig-out/rows-release bench/hostfree-dom-rows/RowsClient.beni
beni build --library --platform=browser --root=bench/hostfree-dom-rows --out=zig-out/rows-legacy bench/hostfree-dom-rows/LegacyClient.beni
node bench/hostfree-dom-rows/correctness.mjs zig-out/rows-dev zig-out/rows-legacy --single-node
node bench/hostfree-dom-rows/correctness.mjs zig-out/rows-dev zig-out/rows-legacy --typed-only
node bench/hostfree-dom-rows/correctness.mjs zig-out/rows-release zig-out/rows-legacy --typed-only
```

`--single-node` compares all DOM snapshots and mutation traces with legacy.
`--typed-only` checks every typed snapshot against the expected list, including
multi-node rows. Without either option the comparison exposes legacy #1833;
`--swap-only` reduces it to two adjacent multi-node rows swapping once. The real
producer regression is `tests/corpus/browser/dom/MultiNodeKeyedSwap.beni`.

The matrix includes keyed insertion/removal/moves/swaps/reverse/clear/replacement,
duplicates and deterministic mixed updates; positional growth/shrink; Show
updates/toggles; item/environment epochs, key-type changes and retained-site
operation/scope retargeting. It varies markers, multi-node ranges, live rows,
position reads and immutable-item skipping. Generic markup keys are refused by
the language, so key-type mismatch is defensive ABI coverage only.

The trace counts public insertion, removal and text writes once, suppressing
DOM implementation calls nested inside them. `remove` and `removeChild` are the
same removal. On key-type changes the typed contract deliberately disposes via
the old callbacks before mounting; legacy has no type guard and mounts before
reconciling. That required order is checked separately from normal trace equality.

The literal optMatch arms allocate no callbacks in either output mode. The two
remaining trimmed-pass closures, keyAt and hit, are each created once per pass,
outside the row loops. The driver's JS adapters are test inputs and are not used
for allocation counts or performance claims.
