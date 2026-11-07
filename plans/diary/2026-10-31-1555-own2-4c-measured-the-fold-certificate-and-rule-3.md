## 2026-10-31 15:55 CET — own2 4c: measured the fold certificate, and rule 3

**What I did**

- Wrote the spec for S3b slice 4c (#1195) on 4d's head `74fbcc61e`. It is in `ownership-v2.md`: §2.9
  *Two positions of one image* gains rule 3, and §8 slice 4 gains *The fold certificate, specified*, an
  amended 4c row and 4c fixtures. No code changed.
- Measured before designing. I traced `FoldedBCall` 30:15 with prints in a scratch build. The refusal is
  not a cycle read `repeated`. `incAll`'s `apart [π1#B.0[*]⟲#B.0] [π1#B.0[*]⟲#B.1]` images both sides to
  one cell, `π1[*]#B.0⟲`, at `incList`'s actual `b`, and that reads as a repeat. `LevelsApartRoutes`
  23:15 and `FoldedBCallImported` 19:15 have the same cause.
- Counted saturation over the ownership corpus (324 files and 49 projects). `Calls.preimage` never
  meets a cycle. `arrivalAggs` saturates in 13 roots. An unsound oracle that reads every saturated cycle
  as once changes no verdict there and one summary.
- Wrote rule 3 as a scratch prototype (`Grafter.positionsThroughLevels`, about 130 lines). Three
  conditions must hold: the two callee paths are apart by route (their last steps are different named
  steps), the actual at their common prefix is one position (a leaf, or a union or choice of leaves, not
  under a repeating split), and the shared image is an exact symbolic summary cell. Then the pair owes
  `excl X`, not a repeat. The whole `test-blackbox` run fails only on the three 4c-owned known entries,
  which are now accepted `param` as in v1. The `runtime_safety` cross-check through the preimage never
  fired.
- Ran the plan's own certificate witnesses through v1, v2 and the oracle. The oracle turns none of them
  green. The loss is `recastWhole`'s approximate reach at a `⟲` graft, and for the parameter-derived knot
  a holder conflict. I opened #1483 for that one, because v1 accepts it.
- Reported the fork in the spec: (A) build rule 3 in 4c and give the certificate its own slice with a
  third reader (the graft through `⟲`), or (B) build everything in 4c. I recommend (A).

**What I learned**

- Measure the refusal before you design its cure. The known entries named 4c and "as #1429", but the
  mechanism was a coarser caller frame at a first return, and no cycle was involved. #1429 itself no
  longer reproduces on `74fbcc61e`.
- An oracle that is deliberately unsound is a cheap way to find a design's ceiling. It took one line in
  `arrivalAggs`. It showed that the certificate as planned buys zero corpus verdicts and none of its own
  witnesses.
- The first prototype walked a union DAG with no visited set, and `run/EvidenceDagBuildDepth32` ran past
  the 120-second guard. That is the same lesson as the last four slices: every new walk over a shape is
  memoised per node, or the representation decides its cost.
- Under `[ incAll b, …incList rest ]` the call's whole `xreq` rides on its first demand. A refusal shown
  at one write path can come from an atom about other paths. To find the atom, trace `resolveAtom`; do
  not trust the line's path.
