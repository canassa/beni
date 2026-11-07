## 2026-10-31 17:43 CET — own2: the matrix rows of 4a, 5a and 4c

**What I did**

Issue #1498, for 5c's done line (every S3b row of Appendix B's matrix has a fixture with its
refusal and its control, same-module and imported).

- 4a: imported twins of `RecursiveCallView`, `RecursiveSummaryGeneration`, `FoldedWriteCall`,
  `FoldSymbolicCall` and `CycleJoinRankWriter`. Both checkers give each twin the same verdicts as its
  same-module form. The known entries copy the same-module ones.
- 5a: `ViewLinkedSnapshot`, `LinkedJoinCertificate`, `RepeatedPathCall` (the caller half of #1122)
  and `JoinedCallContexts`, each with its imported twin. v2 gives v1's verdicts, except two copies
  that v1 reads `lost`, and a second argument's demand that v1 prints as one line.
- 4c: no file of its five row names was on master, so I wrote their S3b halves with
  `CycleJoinRankWriter`'s recursive kids writer: `CrossDepthKids`, `ViewFoldRoute`, `JoinFoldChoice`,
  `LinkedFoldCoverage`, `RefinementFoldMultiplicity`, each with its imported twin. I named them on
  #1498 so that 4c's rule 3 work avoids them.
- The matrix in Appendix B names each path. §8 has an *As built (#1498)* note with the findings.
- Verdict diff (`--diff=v1,v2`, 2 077 roots): no difference outside the known file, except twelve
  one-sided demands in `check/good/OwnershipAnnotationDag` and `RequirementBelowDepth512`. These are
  not from this branch, and the gates do not compare `check/good`.

**What I learned**

- v1 is unsound for a parameter that is linked below a new node and written through the fold. Its
  summary of `twoTrees t u = incAll (Rose [ t, u ])` is `π1 R, π2 R`. `( twoTrees t u, t )` passes
  `--ownership-everywhere`, and `--sanitize-lists` traps on the stale read. v2 refuses it. The fixtures
  carry known entries for v1 (`treeReadAfter`, `takenOneBeside`).
- v2, precision: a builder three `Rose` levels deep publishes its parameter `lost` (#1501). A call's
  choice of one list at two depths is refused over a fresh literal (#1502). Two distinct taken
  elements read as one, in both checkers (#1503).
- The fixtures' `incAll` diverges at run time, because it walks the leaf it pushed. A sanitizer demo
  needs a writer that skips `Rose []`. The sanitizer keeps `length`, so the demo must read an element.
- A three-member mutual group passes the default growth allowance (#1372's class). The fixture
  carries a raised allowance, the measured value plus a tenth.
- `beni check` run inside `tests/corpus/ownership/` writes a `.beni-cache` there, and the corpus walk
  then fails on it. Use `dump` there, or pass `--no-cache`.
