## 2026-10-12 15:50 CEST — The page driver's cache pruning is bounded

**What I did.** Queue row 80. The driver listed and statted every entry of its compile cache on each
start, so after a fuzz sweep (about 116 000 entries) every page spent over a billion instructions on it
(measured: 1 534 M on 116 000 young entries) and the gates' pages went over budget for an hour. Pruning
moved to `tests/browser/compile-cache.mjs`: it reads at most 1 025 names of a version's directory and
stats at most 128, so its cost no longer depends on the cache (about 20 M above Node's start-up, which is
118 M). A cache of 1 024 or fewer is untouched. Three scenarios in `browser_test.zig` pin the bound, the
small-cache case and the one-hour rule; the first fails if a prune looks at the whole directory. Gates
green with the 116 000-entry cache present and with it deleted.

**What I learned.** `readdirSync` of a huge directory is the cost, not the unlinking; `opendirSync` with
a buffer size reads in batches and can stop early. The sandbox's `/tmp` can be full, so a synthetic cache
belongs under `zig-out/`.
