## 2026-10-26 23:31 CET — the join memo and its wall

**What I did**

- I built #1119's join memo on `own2-join-memo`. A state is clean when every joined node on its way has a finite projection rank ≥ 1 (`Shape.rank`). Runs are interned across calls. A clean state that is alone at its position is memoised after the call, and a hit is linked.
- I added `Shape.namedSteps` (memoised per node), skipped `innersOf` when the rank is finite, and memoised union reads.
- The K tower went from cubic to about n^1.85, and every block is unchanged. I stopped there and reported the wall on #1119.
- Housekeeping after #1115 merged: I closed #1114, removed the two worktrees and branches, fixed #1115's baseline (3 584) and qualified §2.9's tower sentence.

**What I learned**

- `case` and `literal` set a join's κ to the merge of all members' snapshots. When the members are one tower at two depths, `kappaMerge` makes a new position at every overlapping depth: 2k + 2 new positions per level, none of them shared. A memo on the walk cannot remove records that the representation needs. Only a lazy merge (the κ counterpart of `Shape.union`) can.
- Instrumenting every `.inspection` charge with its `@src().line` found each hot spot in a few minutes: the charge sites are a ready-made profiler.
