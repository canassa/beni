## 2026-10-31 03:33 CET — own2: a block reads a projection with its sides swapped

**What I did**

- I worked on the review of #1408 (#1399). With the joined κ now keyed below a choice, a recursive group's port did not decode in an importer. `BlockRead.verify` re-projects each projection that the block writes, and requires the reader's `proj` to give the very node the block decoded. The block orders a DAG's two sides by its records, so the decoded projection of a positions node can name its sides the other way round from the reader's own `proj`. The trial read failed, `importedClass` gave null, and the importer left the call unbuilt: `Builds.h3`/`Main.r3` was unchecked. The defect was latent on master, and any class with κ keyed on the projection of a positions node hits it.
- The fix: `verify` accepts a decoded projection that is the same DAG as the reader's up to the order of sides (`sameDag`), and takes it as the reader's projection (`Shape.setProj`), so a reader meets the node the κ is keyed on. §3.6 says so. On 4a with the fix, `r3` gets v1's refusal. A unit round trip in `BlockRead.zig` pins it on master, and it fails without the fix.
- `leafEntries` is memoised by `(d, run, class)`. The key carries the versions of `fold_cond`, the bases and the knots only when the walk read a recast, because no other read depends on them (a view's chain is memoised by position and node). A built node is set to `lost` only where one member holds it with no entry and another member stores one; elsewhere its absence already reads `lost`.
- 4a growth with the fix: `incAll` 15 122 (8 842 before #1399, 15 924 without the memo), `incAll2` 11 912 (5 556 / 12 701), `incLeft` 18 070 (10 312 / 18 739). On the corpus, master gains 1.7% in records and 4a gains 4.1%. There are no verdict or summary changes on master. On 4a the verdicts are unchanged and the summary lines are the same as the first PR round's.

**What I learned**

- Within one κ table, exact repeats of `(d, members, positions)` are rare: 12 hits in 150 calls for `MarkerAcross.incAll`. Counting repeats across tables (or across modules with a global counter) gives about 50%, because the ids happen to collide. Most of the extra cost is not `leafEntries` itself (about 3.8k records there) but the later reads of the extra entries.
- Carrying a member's DAG-node entries down onto the leaves, instead of keying the DAG nodes, made the group rounds diverge again. So the DAG nodes stay keyed, and the codec now carries them.
