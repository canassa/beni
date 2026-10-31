## 2026-10-31 01:15 CET — own2: a taken element keeps what it holds below it

**What I did**

- I fixed the HIGH finding of the review of #1397. `Grafter.takenImage`
  built the element from the contents' cells at `ε` only. So an element
  `Node b` taken out of `[ Node b ]` lost `#Node.0 → b`, and
  `List.set b 0 (takeAt [ Node b ] 0)` was accepted. Done in place, that
  write makes `b` hold itself.
- `takenImage` now returns a node. It is the leaf of the refinements joined
  with `Shape.without(contents, drop, true)`, as `Transfer.bindList` does
  for a pattern. `viewLeaf` and `eagerParts` take that node whole, and
  `reachImage` reads its reach. A reader that wants a set (`imageCells`,
  an atom's side) gets the cells at `ε` and, when the node is built below,
  also `⊤` approximately.
- New fixture `ownership/core/TakenTree`. Each of these is refused, as v1
  refuses it: a literal, a let-bound node, a pushed list, a branch, a
  pattern's rest and a spread. `apartNode` is accepted. All six refusals
  fail on the earlier head. §2.11 item 6 now says this. `Calls.zig`'s §5
  line target is now 1 710.
- The MEDIUM finding: `TakenStoredImported`'s callers are checked by the
  corpus. The harness runs `--ownership=v2`, and with it Main's five calls
  are built. If Main were unchecked, the missing `.v2.unchecked` would fail
  the case. The review saw `not built: call` under `--ownership-both`. That
  mode leaves calls into another project module unbuilt for every imported
  fixture and for three core declarations: #1398.

**What I learned**

- `Shape.cellsOf` is the cells at `ε`. A set cannot stand for a value, so
  a value made from one, such as a leaf, must be its node, or `⊤` below.
- v1 refuses the tree cases `escaped`, and v2 refuses them `disjoint`. The
  parity check compares only whether a demand is refused.
