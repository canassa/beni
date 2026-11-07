## 2026-10-31 19:09 CET — own2: an else-if chain's call and demands linear in D

**What I did**

- Measured #1467 on master at D = 8 / 16 / 32 / 64. I used the account lines and a temporary charge profiler.
  The profiler walked the frame pointers at each reservation, and I symbolised its output with `addr2line`.
  The chain alone (`plain`) was already about linear on master: 13 210 / 27 163 / 55 932 / 115 637, ×2.06 a
  doubling. The issue's 14 292 … 324 048 came from an older master. Two parts of the call were quadratic.
- **The call's other-paths walk.** `wantOf` reads the reach of the chain's root. `Shape.Reach.run` unioned each
  join's own `ε` cells into its set. Its sides' reaches already hold them, and a chain of choices has D, D − 1, …
  of them. So the reach of the root cost 1 037 / 3 274 / 10 906 records at D = 16 / 32 / 64. Now a join with no
  view side leaves its own cells out. A view's reach is its template's image, and the corpus has a choice over a
  view whose `ε` cell is not in that image (`PositionsSaturate`, core, `platforms/browser`), so a join with a view
  side keeps its own cells. Under runtime safety, each component's set is checked to hold every own cell that was
  left out, at a value its `and` keeps.
- **The demand lane.** The argument `v` holds each arm's targets. Each pair `(v, target)` walked the cover from
  `v`'s root down the chain to the target's arm, and `v` has no use after the call, so the walk found nothing.
  Now a pair whose binding holder has no use after the pair's first demand returns before its cover. Every entry
  and heavy answer is a use after that demand, so the result is the same. The last point of each holder is
  memoised.
- Results at D = 8 / 16 / 32 / 64. Demands: 1 520 / 3 718 / 10 583 / 33 841 → 313 / 587 / 1 204 / 2 366. The
  call without its demands: 2 386 / 3 659 / 7 665 / 17 685 → 2 174 / 2 958 / 5 107 / 8 241. Total at D = 256:
  1 112 114 → 536 559.
- Verdicts and summaries are byte-identical on all 2 107 roots of `bench/ownership-roots.mjs`, with the
  `account` and `crossing` lines excluded. I checked this before and after the rebase onto
  `46ede32b6`.
- Added three counted tests in `build_test`, replacing #1439's D = 8 / 16 test. They are the chain alone, the
  call's records, and its demands, each at D = 8 / 16 / 32, with a ratio check and a ceiling at about 1.7 times
  the measured cost. The call tests use `chosen`'s arms, so one dump stays under a second (0.75 s). The old
  arms with `Rose []` siblings took 1.1 s. Mutation checks: turning off the holder skip fails the demands
  test (1 038 / 2 430 / 6 704). Turning off the reach skip fails the call test (1 314 / 1 583 / 2 548). A
  quadratic choice-cells union fails the chain test.
- Updated `ownership-v2.md` §2.3 (`reach`), §2.8's *As built*, the §2.11 item 3 measurement and §5's line
  targets (Shape 3 925, Holders 2 070). Opened #1510 for the part I did not fix.

**What I learned**

- The plain chain is D log D, not linear. It grows ×2.06 at every doubling from 8 to 512. Each arm inserts into
  persistent radix sets of O(D) members (the choice DAG's node set, κ's keys), and each insert copies a spine of
  O(log D) nodes.
- A holder that is still used after its demands still walks the chain once per target. An example is
  `incAll v` followed by `ignore v`, which is refused. Its demands cost 1 676 / 3 994 / 11 099 / 34 837 on
  master and on this branch. The holder index's closure memo is keyed by `(node, x, c)`, so D targets share
  nothing. The cost is not inherent: the fix is a per-holder index over the value's join DAG (#1510).
- Wall time is not records. In the safety build the plain chain's own time is 0.02 / 0.07 / 0.19 s at
  D = 8 / 16 / 32, while its records are linear. Some uncharged work under runtime safety grows faster. I did
  not look for it.
- `reach(view)` does not hold the view's own `ε` cells in every case. The spec's `reach(union) = reach(l) ∪
  reach(r)` is therefore exact only for sides that are not views.
