## 2026-10-31 17:01 CET — own2 S3b 5c: the matrix rows, and two holder fixes

**What I did**

- Built S3b slice 5c (#1486): the seven 5c rows of Appendix B's matrix (V×C ViewCycleHolder, V×R
  ViewSplitStoredBack, V×J ViewBranchJoin, V×A ViewCallArgument, C×R CycleSplitRefinement, C×L
  CycleLinkRooting, R×A SplitCallSupply), each same-module and imported, with its refusals and
  controls and no `.v2.unchecked`. Also `LevelLimitCallers`, `FoldRelabelCall` (the source-level
  relabel of a fold step through a call) and `AnsweredAboveElements`, each with an imported twin.
  `p/MutualListField` moved to `o/`. `CallOrderReversed` in `ordering_test.zig` reverses
  `CallOtherPaths` and each module of its imported project and compares v2's verdicts and summaries
  with positions dropped.
- Fixed a soundness defect (#1491). Two matches of one recursive value each refine it, and a call
  writes the canonical cell, which no match refines. The holder index paired the cells but `cover`
  found no hold, because `Cell.stepsTo` relates a cell only to its own chain. So `rest`, a view of the
  kids list, was no holder when that list was written. `Holders.samePosition` now reads such a
  candidate's hold as the target's, in the cover and in the naive scan.
- Fixed #1253's item 2 (precision): `reachBeside` dropped the path of the route down to the written
  positions on a place off a cycle, so an answer `~π1` above a `[*]` write held the written lists.
  The route toward a written path now keeps its path.
- #1272 needed no code: §2.9's rule 2 (#1473) already accepts two refinements of one split in a
  built record, and `SplitCallSupply` pins it.
- Opened #1492, #1493 and #1495 (precision, known entries) and #1498 (5a's four rows have no
  fixture, and 4a's rows have no imported twin except `FoldedBCall`).

**What I learned**

- v1 is unsound in five positions these fixtures pin: a view kept across a call that writes its base
  one level below a recursive root (Rose, mutual A/B, `Maybe`), two matches of one `A` written and
  held, and a head stored back and then written. `--sanitize-lists` shows the stale read of the
  first. Expected verdicts come from v1 only where v1 is sound.
- A callee whose parameter is unused (`f a _`) still counts as touching it at the caller, in both
  checkers. The row's "callee ignoring that subtree" is a callee that ignores a part of one argument.
- A function's result folds the levels below the first return onto one class. The same tree as a
  literal at the call stays exact. So a fresh tree returned by a function is refused where the
  literal is accepted (#1495).
- The A/B mutual list writers are #1372's loud groups. A traversal through `Maybe` (`P`/`Q`) is not
  loud, and it stands for one traversal across a mutual boundary.
- An ownership fixture's stale known entries show only in an unfiltered walk. A run with
  `-Dcorpus` skips that check.
