## 2026-09-29 18:55 CEST — parallel emit and parallel resolve

**What I did**

- Emit runs on one pool of threads per build: reachability's edge lists, lowering, printing
  and the writes, each module into its own slot, results read back in module order. A
  lowering invents names in a per-module `InternPool.Overlay` over the session's pool, which
  the workers only read; the fixed names are interned before the fan-out. `--release` lowers
  and plans in parallel, lists each module's whole-program names in print order
  (`Rename.collectGlobals`), moves them into the session's pool and numbers them serially in
  module order, then renames and prints in parallel — the ordinals are the serial walk's.
  Output directories are made once each, and printed bytes are handed over, not copied.
- Resolution runs on the module DAG (`Resolve.Schedule`), per-module diagnostics joined in the
  graph's order with their `available` ranges rebased.
- A build test where three modules name another module's derived functions, dev and
  `--release`, twice at `--jobs=1` and `--jobs=8`, and the program runs.
- Measured (plain 100k corpus, `--jobs=8`, min of 11 interleaved, load 1.5–2.5): `build
  --library` 68.7 → 50.2 ms, `--release` 79.3 → 59.7, warm build 52.4 → 31.0, cold check 40.4
  → 37.9, warm check 22.6 → 19.1; instructions +0.3 % (`--release` +1.8 %). Skipping the
  rewrite for cache hits was not done: see the perf study's item 5.

**What I learned**

- A persistent pool that spawns threads lazily must start a new thread as having done the
  current round: one spawned before the round's announcement ran the job early and
  decremented a busy count that was not set yet. Only the 16 400-branch abuse test, the one
  default-`--jobs` build big enough to spawn in a later round, reached it.
- Threads are not free for a tiny program: an explicit `--jobs=8` on one file cost 2.6 ms until
  each round's thread count was bounded by its work, keeping two so tests still run parallel.
