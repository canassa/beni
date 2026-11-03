## 2026-11-03 07:50 CET — Resolve lane: joined cost branches and routed DAG holds

**What I did**

- Joined the two cost branches into `own2-cost-joined`, twice: first `own2-s3b-closeout` with `own2-cost-values` at `e50e6bbfd`, then the values lane's route-set step (`2aa8a316e`). Duplicated files were reconciled (`KeySets`, `BelowSize`, `ApartParts` against `ApartPlain`), and the over-target files were split: `PlaceIdentity` out of `Place`, and the arrival-path fast path into `Routed.paramLeaves`. Place's object count and family bit now share one byte, so `Place` stays 24 bytes.
- Found and fixed one join regression. The values lane's twin-demand test compared a demand's written-path steps, which my side had split out of the path, so twins were judged again. Fixed one harness overflow in `chainDump`.
- Step 2: a holder DAG's nodes are values with arm tags on edges. The descent lists its items once, unites their routes in decreasing value id (`DagRoutes`) and judges holds under them. `Holders` reads a key's kids through `expandRouted`. The fold certificate through a shared DAG passes, and build_test has 0 failures. Ledger, summaries, oracle and cost table are unchanged.
- Not done: the shared-link knot chain (it needs an arm-tag index for the DAG descent) and `Graft.fullAt` on cycles (it needs a re-canonicalizing graft). Both are designed on #1714.

**What I learned**

- A field added on one side can break an equality on the other side. `std.meta.eql` over a struct compares every field, so a field split out of another field must be cleared wherever the old field was.
- A three-way account check (join vs both heads) finds join regressions that a two-way diff hides.
- Moving work from tag lists to route sets loses `TagTree`'s arm filter. A tagless hold met through every arm costs as much as the exponential walk it replaced, but on another family. Every reader that switches to sets needs the same index over the sets.
- A callee's tree is canonical only from the callee's root. Grafting it under a caller slot is exact only while no step can fold differently there.
