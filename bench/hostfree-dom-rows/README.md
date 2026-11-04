# Row correctness through markup

The page exercises keyed insertion, removal, moves, clear and replacement,
positional growth/shrink and keyed Show updates through the real browser
producer. It imports no private renderer module and supplies no private ABI.
The browser corpus owns the larger epoch, multi-node and environment matrix.
Report 29 owns performance measurements.

Build and run from the repository root:

```sh
beni build --platform=browser --root=bench/hostfree-dom-rows --out=zig-out/rows-dev bench/hostfree-dom-rows/RowsClient.beni
beni build --release --platform=browser --root=bench/hostfree-dom-rows --out=zig-out/rows-release bench/hostfree-dom-rows/RowsClient.beni
node bench/hostfree-dom-rows/correctness.mjs zig-out/rows-dev
node bench/hostfree-dom-rows/correctness.mjs zig-out/rows-release
```
