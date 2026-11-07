## 2026-10-31 07:39 CET — own2: a written position is one position

**What I did.** The review of #1438 found a hole. The other-paths walk skipped any arrival at a node
that the write's path reaches, on the assumption that the class owes `excl` there. `writeLL` writes
one position of `π1#Node.0⟲#Node.1` through constructor fields and owes no `excl`. So
`Node (Node s [ 2 ] s) [] Leaf` was accepted, because `s` stands at two positions of the path.
- **Built values.** Each node at the write's path now counts its routes along the path
  (`Transfer.routesBelow`: one walk of the value per `⟲`, then Kahn's order, capped at two, a knot
  two). Only a node with one route is a written position.
- **Symbolic values.** A hold through `atWritten` at a path of several positions now owes `excl` of
  the base's canonical cell upward.
- **Fixtures.** `FoldedOnePosition` and its imported twin: one subtree twice, a parameter's list in
  it, two equal subtrees over one parameter list, and a list projected from a literal. Each is refused
  as v1 refuses it, and each failed on the previous head.
- **Issues.** #1446 for the quadratic tower and #1445 for `pushLeftmost`.

**What I learned.**

- **Nothing of #1253 came back.** Every removed entry still holds, and so do `LevelsApart` and
  `LevelsApartRoutes`. Seven shared cases that were accepted at the `⟲` path are refused there now.
  Their positions were refused by v1 already.
- **Without the node skip, these become refused again:**
  - `LevelsApart`'s `three` and `four`, and `LevelsApartRoutes`' `distinct`
  - CycleJoinRank 44:16
  - FoldedBCall 66:5 and its import
  - FoldedPreimageCall 137, 143 and 153
  - FoldedWriteCall 35:11
  - FoldSymbolicCall 107:5
  - LevelRecursiveUpdates 64:5
  - `FoldedOnePosition`'s `apart`
- **Cause 1 alone holds** CycleJoinRank 36:16 and 40:16, and FoldSymbolicCall 46:12 and 63:12.
- **The walkers' own inner calls need `atWritten`.**
- **A shared join DAG must be counted, not walked per route.** My first version walked it per route
  and was exponential on `PatternWideCall`'s 1 000 shared rows, which reached `ownership_summary_size`.
- **The tower is quadratic.** It is not my walk: each write route below a `⟲` walks the actual below
  its path again. Master is worse (#1446).
