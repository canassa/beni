## 2026-10-30 20:05 CET — ownership v2: a type variable's place instantiated at a call

**What I did**

- #1350. Under `--ownership=v2`, `List.length (pick g.x).c` with an unannotated
  `pick r = r` lost `pick`'s caller's read of `g.x.c`; so did `(ans { b = g.x }).c`
  with `ans r = r.b`, `(ansU { b = g }).x.c` and `(choose b l r)`'s field. v1
  refused all of them.
- Cause: `Calls.Grafter.argAt` answered the actual at the template's `var`
  place as a place-only recast. A `var` place has no steps, so `Shape.recastPart`
  found no part and the projection was `recastWhole`, `~π1.x`.
- Fix, in `Calls` and `Shape` only:
  - `argAt`: at a `var` place, the actual stands at its own place (the call
    instantiates the variable to the actual's type). No recast.
  - `viewLeaf`: a leaf of parameter cells only, at a `var` place, stands at the
    place its exact parts' actuals share (`instantiatedAt`), so `choose`'s raw
    union projects.
  - `Shape.projOne`: a view projects as its answer does, before its own place's
    step is looked up.
- Spec: `ownership-v2.md` §2.11 *Re-rooting at a parameter*, three sub-items.
- Fixtures `ownership/CallTyvarProjection` and `CallTyvarProjectionImported`
  (v1's verdicts; on master v2 accepts all 15 refusals).

**What I learned**

- The spec already said the answer at a parameter position *is* the actual's
  node. The recast at a `var` place was the code's, not the design's.
- Over every `ownership/` fixture and `run/` program, no verdict changes. Four
  dumps change, all in precision: `OpaqueUseShape.heldIntoPoly` now publishes
  what `List.push` publishes directly (`~π1` before), and `WideResult`,
  `EvidenceDagBuildDepth32` and `NestingEvidence`'s tuple and list towers keep
  their exact structure. `WideResult`'s refusal now has v1's cause, `alias`
  (it was `element (approx)`). These towers cost fewer records than before
  (`w6` 1 717 → 1 458 baseline).
- `nd g = List.length (pick g.y).c` with `nd` unannotated is still refused
  (#1327, not this issue), so the accepted control is annotated.
- A fresh worktree's first `zig build gates` took 1 min 52 s.
