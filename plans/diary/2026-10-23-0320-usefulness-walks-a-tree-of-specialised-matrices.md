## 2026-10-23 03:20 CEST — Usefulness walks a tree of specialised matrices

**What I did**

- Took issue #812: a `case` of n branches `[ Just ( k, y ), …rest ] →` cost 128.3M
  instructions at 500 and 448.2M at 1 000, and 2 000 was refused by the default pattern
  budget. The cause: `Exhaustive.one` asks of each branch whether it is useful against the
  branches above it, and `isUseful` specialised those rows afresh every time. Each branch
  read every row above it three times (list, `Just`, tuple) before the literal dropped
  them. `ColumnIndex.Heads` saved the first step only, and only for a constructor column.
- Wrote `src/check/Useful.zig`. It keeps every matrix the relation specialises for the
  whole `case`: a node per matrix, a child per key, each child caught up with only the rows
  its parent gained since. The first child of a node by a head reads the node's rows in
  order. From the second, the node keeps a chain per head, so a child reads only the rows
  it keeps. Column facts (`collect`, `lenSplit`'s maxima, the `Malformed` heads) are kept
  as rows arrive. Literals get a dense id at `simplify`. `isExhaustive` is unchanged.
- Measured 27.2M / 42.4M / 72.9M / 133.8M / 255.6M at 500 … 8 000 branches; the cut
  `( k, _ )` is 22 144 steps at 1 580 rows, not 5 087 257. Added the `test-perf` scenario
  (n = 2 000, ratio about 1.84), the corpus fixture `check/good/NestedLiteralTable`
  (refused before, clean now), and the algorithm to `checker-v2.md` §16 and `checker.md`
  §6.6.
- Differential, base against new: every `.beni` of `tests/corpus` and `tests/pending`
  (3 190 files, every dump stage, `check` and `check --platform=node`) and 9 000 random
  `case`s over lists, `Maybe`, tuples, literals and a recursive type. All byte-identical,
  also under the Debug build's safety checks. Scripts in `~/worktree-evidence/beni-exh812/`.

**What I learned**

- A budget step must stay a bounded amount of work. The first tree indexed every row of
  every node in hash maps: a step cost about 1 000 instructions, and a `case` the old code
  refused at 287M instructions ran for 3G. A chain per head and an index built only from a
  node's second child brought it to about 140 instructions a step; a `case` that spends
  the whole budget takes 0.09 s in ReleaseFast.
- What still squares is a wildcard row under many distinct heads (`( k, 1 )` rows
  interleaved with `( _, k )`): each child copies every wildcard row above it. It is
  cheaper than before, and the fix is to share those rows between siblings (#831).
- On a loaded dagon an LLVM build of beni can take 20 minutes and can be killed with
  SIGTERM; check the binary's time stamp, not only that the build ended.
