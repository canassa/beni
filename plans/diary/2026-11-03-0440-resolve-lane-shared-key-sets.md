## 2026-11-03 04:40 CET — resolve lane: base keys as shared sets

**What I did**

- Branch `own2-s3b-closeout` (#1714). I cherry-picked the values lane's hidden `--ownership-below` dump, for
  `covsum`. Its `Subtree.moreBelow` is not on this branch, so the commit adds `BelowSize.zig` with that one function.
- `Holders.Keys.close` copied each kid's run of base keys into its parent's run. A chain of n holders, each over the
  one below plus one key, therefore made n²/2 items. Now a run is a flat copy only while it has at most 32 keys
  from flat runs. Past that, a leaf's keys are a hash-consed Patricia set over dense key ids (`KeySets.zig`): the
  union of the leaf's own keys and its kids' sets, listed only when a reader asks for it. Two owed pins now pass
  with their original bounds: #1146's knot chain through calls, and the 400-call chain read at its end. The ledger,
  every summary and every account line in the corpus are identical, and the oracle has 0 TRAP / 0 DIFF.
- Step 2 (#1225's callee write paths, one grafted node) is not done. A root-slot read-off graft (`ArgGraft`,
  scratch patch `scripts-cr11/argraft-partial.patch`) takes `call256` only from 5 293 to 4 771. The rest is linear
  in three other places: the `[*]` deep arrival, the condition instantiation (`Distinct.instCond` → `Routed`), and
  the write demand's text path (`Eval.pathAt`).
- Step 3: profiled the call-free chains. Both quadratics are `ReadOff.factsOff`'s reads through
  `Routed.project`. The leaf iterator skips a node met before in a pass only where no wrap tags it, and every
  leaf of a chain of choices sits under a wrap.

**What I learned**

- A persistent set everywhere was worse in growth on 18 corpus accounts (`Ui.Html.map` +1 904). Each of its own
  keys paid one node and one union, where the old copy paid nothing per key. Keeping small runs flat removes that
  cost and still bounds the chain.
- Module tables charge an account for a memo's fill cost the first time the account reads it (`readEntry`). So the
  inverse index "a callee's path is already interned" cannot make a caller constant in the path length. Only a
  structural graft can: the callee's `Rel` or tree node taken as it is.
- Under `-Downership-full-cross-check`, the GroupRotate growth-0 pin fails on the base too (55 847). The
  cross-check judges every demand in full.
