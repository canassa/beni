## 2026-11-03 08:26 CET — Resolve lane: knot arm index and cycle walk, both filed

**What I did**

- Continued #1714 on `own2-cost-joined` (`f64845ef08`) with two items, each to land only if complete, exact and green. Neither met its bar. Both are filed with their patches: #1767 and #1768. The branch did not move.
- Knot chain (#1767): built `DagArms.zig`, an arm index of a holder DAG. It folds an `alt` under an `alt` into its parent, labels each exit with the merged arm tags, keeps a `TagTree` over a node's exits when there are more than eight, and keeps the hold-below flags once a holder. A DAG holder also skips the hold-tag forest. With the classification "a value met under a second tag list is a DAG", the knot chain is linear: 14 111 records at n = 64. The chain read after the call fell from 244 642 to 8 670 at D = 32, linear, but its bound is 5 700.
- `fullAt` on cycles (#1768): wrote the §2.11.2 text and built `CycleFull` and `CycleWalk`, a walk of the callee's tree at the caller's own paths. It cut demand lines from 803 to 38 at k = 16, but records rose from 919 647 to 1 191 643.

**What I learned**

- A holder DAG pays its whole listing and route settlement on every target. A plain holder pays only for the holds its tag tree hands it. After the arm index, about 51 records a descent remain against about 5. The next step is per-holder items with an index over their route sets.
- A deep write in a contract is consumption to the callers (`x.deep` → `.consumed`). A whole subtree's target must be written out as `below(q)`'s object slots, never `↓q` turned into a deep write. The #1714 design text was wrong on this point.
- k `⟲` writes that name one set of level lists by k join ids cost k² a call to compare, whatever the comparison. A cut needs one name for that level set.
- `Slots.replay` gives a join path where `below` gives its expanded level paths. A comparison of the two must expand the join first (`Place.expandLevels`).
