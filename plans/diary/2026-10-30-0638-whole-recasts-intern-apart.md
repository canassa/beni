## 2026-10-30 06:38 CET — whole recasts intern apart and stay whole

**What I did**

- Found one cause for #1311 (an edit through a cast in a callee was
  accepted) and #1310 (a cast's κ depended on declaration order).
  `Shape.recastWhole` made a recast that stands for some value inside its
  inner, with the inner's reach as its cells. But `Shape.make` keys a recast
  without its cells, so it was the same node as `Shape.recast` of the same
  inner at the same place, whose cells are the inner's own. The declaration
  that made the node first decided its cells for both (#1310). Every rebuild
  (`Calls.graftOne`, `graftRaw`, `Shape.map`, `expandView`, `BlockRead`, a
  cast of a whole recast) also made a plain recast. At a call, a parameter
  cell in it then took the actual's root cells and not what the actual
  reaches (#1311).
- A recast's `b` is now 1 for a whole recast. It interns apart, and every
  rebuild keeps it (`recastAs`, `wholeOver`). A call's image of its cells
  reads the argument's reach (`Calls.imageReach`). The block writes the mark
  (version 11).
- Fixtures: `core/CastCallHolds` (four shapes that master's v2 accepts and
  v1 refuses, with fresh twins), `core/CastOrder` and its ordering scenario
  (`lost` in both orders), and a BlockRead round trip. Each one fails on
  master. The §2.13.9 rule is in `ownership-v2.md`.

**What I learned**

- Every ownership fixture keeps its v2 verdicts. Only summaries changed, and
  each one got wider. Two were unsound on master: `genericPair`'s `res` was
  empty and `exactExtended`'s did not name `π1`.
- `beni check` on a fixture in the corpus tree leaves a `.beni-cache`
  there, and then the corpus walker fails. Remove it before the gates.
