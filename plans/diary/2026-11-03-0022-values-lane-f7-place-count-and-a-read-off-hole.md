## 2026-11-03 00:22 CET — Values lane: F7's place count, and a read-off hole it exposes

**What I did**
- Cherry-picked the resolve lane's deep-apart read (`af3171d18`, with `ownership/DeepApartPlainBelow`) onto `own2-cost-values`, on a new branch `own2-cost-values-f7`.
- Built F7 as decided. `Place.objectsBelow` is a column of the place graph, set in `settleCycles`: a place on no cycle sums its children's counts, and a cycle that holds an object saturates past `below_min`. `Subtree.below` reads it instead of walking or counting per call. §2.3.1 is amended in place. Tests 132 and 245 flip. The ledger has 0 verdict changes, and the 29 positions that once moved stay accepted.
- The coverage check of the summary diff led to a soundness hole (#1740): an open below-key item read wide was described at its own slot only, so a fold's result with a known lambda's answer lost the argument's objects. It is on the base too, for wide types. F7 makes it reachable for every recursive type (`Dict.filter`). I fixed it (one widen) and pinned it with `run/SanitiserFoldAnswerWide`, which fails with the fix reverted.
- Did not fast-forward `own2-cost-values`. With the fix, `Schema.shapeOf` costs 577 882 records, past its limit (base 256 826 rests on the unsound read). The cherry-pick puts `Distinct.zig` over its line target without the resolve lane's `Entries` split. The R-7.4 ring floor falls to 1.47. I weakened no test and raised no target.

**What I learned**
- `sumcmp.mjs` compares raw A with normalised B. When A prints shared subtrees, it reports thousands of diffs that are not there. Compare raw lines, then check coverage per part.
- A sound reader can cost more than the base's figure: an unsound read can be the reason a cost row is low. Measure a soundness fix alone on the base before you blame the slice it was found in.
- The black-box build reuses a cached safe binary by content. A revert to a state built earlier is not rebuilt, so check the binary's output before you trust a "fails before the fix" run.
