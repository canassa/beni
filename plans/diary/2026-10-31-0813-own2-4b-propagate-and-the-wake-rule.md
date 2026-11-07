## 2026-10-31 08:13 CET — own2 4b: propagate and the wake rule

**What I did**
- Built S3b slice 4b (#1440, part of #1016) on the 4a driver in `Groups.zig`. Each walk records its
  group calls through a new `Transfer.Context.onCall` hook: the callee, the port version the call
  saw, and the arguments. A call in tail position also has a result edge.
- `propagate` keeps a queue of the members whose port moved. Each edge gets each version of its
  callee's class once. Marks go backwards along the argument edges (`Walk.argumentMarks`: the
  read-off's graft and `Transfer`'s write and escape routes). At a tail call, the class is applied
  over the arguments and read off as a walk's value (`Walk.delivered`, which shares `resOf` with
  the read-off).
- The wake rule: a port's `shape` version moves only when `res` holds a cell at a new path. The
  read vector holds it, and the read check walks every other stale member.
- `Calls.positionsAt` and `Calls.reentries` are moved out of `Transfer`.
- Counted tests: `GroupRotate` (2 walks at 4/16/64, 1 of them an inference walk) and
  `GroupMutualRing` (2 per member). `GroupSelfFold` is now 2 walks and `GroupFieldShift` at n = 4
  is 2. The mutual failure twin moves to 24 fields, because 16 now settles.
- Amended the S3b row's "never a full frame replay" to the owner's Q1 decision. Added *As built,
  4b* to slice 4's plan. Opened #1448 for the debt.

**What I learned**
- Deltas, as the plan says ("each (edge, fact) once"), are cheap. But they gave a strictly weaker
  fixpoint than 4a's in nine corpus fixtures, because κ and widen's folds do not distribute over a
  join. I checked this in one process: 4a's rounds ran again over the same tables, and the two
  classes were compared with `Summary.leq` in both directions.
- The whole class per version matches 4a's semantics everywhere, but a delivery costs a read-off.
  #1423's `wa`/`wb` take fewer walks (7/8 against 9) for about 10–16% more growth.
- A projection's image put alone at its path is a partial alternative, and it weakened
  `incLeft`'s κ. So only tail calls carry result edges, and `GroupFieldShiftMatched` stays at
  n + 3 walks.
- `Summary.eq` is stricter than `leq` in both directions. Use `leq` both ways for "same meaning".
- The summary lines that changed (twelve fixtures) are representational: fewer rounds keep fewer
  choice alternatives, and a per-call graft spells out a `⟲` path's mark.
