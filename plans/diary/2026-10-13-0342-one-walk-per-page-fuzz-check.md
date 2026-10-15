## 2026-10-13 03:42 CEST — one walk per page-fuzz check

**What I did.** Merged the page fuzzer's three walks of the body (the driver's `serialise`,
`fuzzState`'s properties, `fuzzOffer`'s targets and shown values) into `serialise`, which gathers
them when the fuzzer asks; `fuzzState` keeps the title, address, storages and pending requests.
The walk now follows siblings instead of spreading `childNodes` and reads each getter once.
Proved identity with a throwaway trace patch (hashes of every compared view, every action line,
every report) over a 20-seed, 60-step sweep of the browser corpus run straight from the
`corpus_test` binary: 126 fuzz runs, 269 868 checks, identical record sets before and after.
Re-recorded the browser run hashes (only hashes moved).

**What I learned.** Per check on sternhalma's board: 12.5M → 7.3M instructions (serialise
alone 6.6M → 4.9M; settle is ~0.1M, not 2.2M). The fuzz part of sternhalma's case fell
~2 190M → ~1 820M, but the case as a whole only 5 197M → 4 790M: two builds (1 827M), Node and
happy-dom, five loads of the 121-cell board and the program's own work make up the rest, so it
still does not fit 4 300M and stays in `examples/sternhalma/play/`. Conduit's cases moved within
noise and the whole browser corpus with every page run 516.6G → 512.1G: most pages are small.
Skipping a check after a step that "did nothing" was not done — a mutation observer misses
`.value`, `.checked`, selection, focus, title, storage and logs. `zig build fuzz`'s sweep times
out 22 `browser/tea` cases at the 60 s case limit under load: their driver run is not given the
ten-fold timeout the value-fuzz path gets. In Chrome 1xx here, `BikeWars` (style colours as
`rgb()`) and `SettlesManyFibers` (fibers done in one turn) differ on master as well.
