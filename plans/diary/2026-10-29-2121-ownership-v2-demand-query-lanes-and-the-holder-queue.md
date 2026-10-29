## 2026-10-29 21:21 CET — Ownership v2: demand-query lanes and the holder queue

**What I did**

- #1198 (the source continuation, K·I_f with K = 1 024), merged: §4.4 is now `[O 2026-10-29]`, and B_f ≤ 11 328·S_f is stated.
- #1200 (#1193), merged: `dump --stage=ownership --ownership=v2` prints the check's own reports, so v2 runs once and every ownership dump test takes half the time.
- #1234 (#1191), merged: a wide literal's time was quadratic, though its records were linear. `stamped.Column` makes a slot per id up to the highest it is given, and `Shape.reach`, `rank` and `reachAgg` made fresh columns per call. They take pooled columns now, emptied by generation. A `scratch_slots` profile counter pins it.
- #1212 (#1201), merged: the demand query's lane keeps one direct holder at one hold path. Everything past that is growth: more holders, radix nodes, hold paths, live-refinement members, the walk of a holder's value, and a deep demand's walk below its base.
- #1230 (#1223, a soundness fix), merged: `holdPaths` stamped only the node, so a second route through a shared record was dropped, and v2 accepted a push that v1 refuses. The walk is keyed by node, path and route flags now.
- #1233 (#1225), in review: a demand's path steps each have their own lane. `Lane` has a `step` word, `(base instruction, direct_demand_query, slot · depth)`. No step lane is entered once the query is in growth, and a several-cells base is decided before its cells are read.
- #1241 (#1236), in review: `Place.extend` looks for re-entry only along a shared cycle, and each path node keeps its nearest cycle-anchor prefix, so a long path below a list element is no longer k².
- #1214: the frontier design stopped on registration-side detection. The winner memo was approved, then Astra showed it doesn't help: rank₂ differs at every point, and the winner expires at every site. The measurement agreed. The revised spec is a holder queue: lazy discovery of holders registered since the cell's last demand, lazy re-asking of a stale top, and §2.5's compatibility makes every entry a lower bound. It's waiting for review.

**What I learned**

- "Unchanged rank₂" is never true between two points: rank₂ orders points, not regions. Monotonicity comes from compatibility, rank₂(p₀) < rank₂(p), which gives a subset of compatible uses. A cache keyed by a value that changes at every step is invalid by construction. Measure the motivating case before believing a memo.
- A fix that charges per path node, not per written step, can break the bound it exists for (#1233's review). Key lanes by the written atom and its depth.
- A tie broken by discovery order can't be reproduced by any structure. The canonical order is better anyway: a message's name shouldn't depend on radix registration order.
- On a loaded machine (load 36 on 32 cores), test wall times are noise. Measure CPU time or records instead.

**Questions for the owner**

- None of mine; the holder queue is with Astra.
