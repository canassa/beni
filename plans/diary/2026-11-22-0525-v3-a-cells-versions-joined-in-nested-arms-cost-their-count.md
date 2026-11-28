## 2026-11-22 05:25 CET — v3: a cell's versions joined in nested arms cost their count

**What I did**

- Lane fix175, #2599 (a bound fault the blind round BH found). One function makes a `Ref`, nests an
  `if` 9 deep and writes the cell in every arm: v3 ran out of memory past 9 GB, and depth 8 held
  4.4 GB before its step limit. Present at cb0b57f8e1 too.
- Measured with counters of the frame's stores: at depth 6, `reroot` made 262 143 joins and the frame
  533 360 values; values grew 8 times for each level, and at depth 8 the walk held 33.7 million values
  for 11 million units. Two causes. `reroot` made the whole join of the cell's versions again at each
  reading, uncounted. And `cellsNowIn` read a join whose every arm read now as one value as a join of
  copies of it: `apply` reads its arguments twice, so each reading was a level deeper.
- Fix: `reroot_memo` (as `proj_memo`), counted; the one-value join is that value (kernel §13 item 6,
  amended: as pessimistic or more). Depth 9 is judged in 0.5 s at 61 MB.
- The class: a backstop in `Frame.tick`, every build: the items a walk holds (every list and map of
  `quiet_parts`, over the frame chain and the ended frames) never pass the units it counted and
  `decl_floor`; past it, a limit line of its own. Lengths, not bytes, so the same on every target.
  Measured over the 2 510 roots first: at most 0.21 of it. A mutation (an uncounted 65 536 items for
  each join) ends in that limit in 0.4 s. Counts added where the audit of per-arm, per-join, run and
  renewal builders found none: `joinCells`'s key scan, `saveCells`, `noteReturnCells`,
  `backfillCapture`, `runWriter`'s operands. Kernel §8 has the rule and the audit list.
- `bench/ownership-sweeps/nested-arms.mjs` (480 programs: depth 1 to 10, `if`/`case`, cell made or
  handed, write or read, a local function or not, dead/live/liveArm). Base: 18 OOM, 72 limits. Fix: no
  OOM, at most 0.94 s and 110 MB each (self-hosted ReleaseSafe); 8 dead programs newly accepted.
- Fixtures: `run/CellNestedArms` (depth 6, accepted, runs in place; a limit on the base) and four
  `check_test.zig` tests that generate the shape at depths 8, 9 (a live twin: 9 refusals) and 10
  (`if` and `case`: a limit), each within 10 s. Run fixtures at depths 8 to 10 needed 9 000 lines of
  v1/v2 known differences, so the test generates them instead.
- One read-only Opus reviewer: no fault; every acceptance it built ran the same in plain, sanitised
  and in-place builds. It found the backstop slow: `heldItems` at every call unit made lambdas
  nested 199 deep ten times slower. It now runs at every 512th call unit (the mutation still ends in
  the limit). Older costs it found, all ending in limits: a chain of `?` returns and arms reaches the
  step limit at about 700 MB (memo copies of atoms, a unit each), records in a cell are exponential
  in depth but counted, spawned fibers reach the limit near 900 MB.
- Evidence: root dumps, 3 of 2 513 differ (the new fixture's roots only); ledger 309 of 319 both;
  134 158 sweep programs dump-diffed: 35 changed (`nested-arms` and the new fixtures), 0 faults
  under the four legs; `row-words` 5 016 rows, 0 crashes; v3 on the 33 real roots 1 811.5 to
  1 857.3 ms (ReleaseFast, +2.5 %).

**What I learned**

- A frame's value store is an arena and a DAG: any function that rebuilds values recursively must
  either be memoized by value or count each node, or it grows past the budget unseen. The quickest
  diagnosis was counting node tags and join builders, not reasoning about the rules.
- A byte count of the walk's arena is a poor bound: safe-build checks and temporaries made real roots
  reach 62 bytes for each unit. A count of held items is deterministic and sits far below its bound.
