## 2026-11-01 18:56 CET — Hand-pick the playground programs

**What I did**

- Measured CI from the last ~200 runs: `ci` takes a median of 14.6 min, and the `playground` job
  is the longest job of the run (14.7 min). `zig build test-playground` takes 14.5 min of that.
- Split it locally (32 cores): the LLVM `ReleaseSmall` `.wasm` compile is 1m36s on one thread.
  The run is 1m28s wall but 12 CPU-minutes, because ~930 programs make ~2 600 commands, and each
  command is a Node process that compiles the 13.8 MB module.
- The owner asked for seconds. I replaced the corpus sweep with 22 hand-picked programs in
  `tests/blackbox/playground_test.zig` and amended `playground.md` §6 (#1573, PR #1575). The run
  went from 1m28s to ~9 s wall. The slowest shard is the unchanged sweep test.
- Found master red: `src/own2/Enforce.zig` is 501 lines, over own2's 500-line target (#1574).

**What I learned**

- The CI log shows nothing during `test-playground`, so the split between the compile and the
  run had to be measured locally.
- After this change, the LLVM compile is the floor of the job whenever `src/` changes. That
  floor is minutes, not seconds, and only a change in where the shipped binary is built and
  tested can remove it.
