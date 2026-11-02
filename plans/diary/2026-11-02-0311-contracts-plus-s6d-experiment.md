## 2026-11-02 03:11 CET — contracts plus S6d: refuted, the local value model is the limit

**What I did**
- Rebased `exp-recursive-contracts` onto master and attributed `removeMin`'s outer `case` joins by pass, phase,
  record category and state graph.
- Built S6d as exact per-call tables: `kappaOf`, `cursorSteps`, `frontierWith` and `proj(side(…))`, once per
  distinct argument tuple. It is on branch `exp-contracts-s6d`.
- Checked it against the plain rule and the reference (`-Downership-full-cross-check`). Ran the 478-token
  ledger, the soundness controls, the sanitiser oracle, core, scaling and task-clock.
- Recorded the result in `ownership-v2.md` §8 Q8.

**What I learned**
- S6d is exact and removes 15–20 % of the records. It cannot remove much more: fold-first already reads each
  state once, and `Propagate`'s own memos are 10 % of a join.
- A join of 1 194 states stores 153 (node, κ) entries over 2 κ conditions. The states are distinct sets of
  member atoms, and normalising merges none, so the limit is v2's local value model.
- With contracts, walk 1's cost comes from the port: 20 empty slots still have a knot's structure. Master's
  walk 1 joins 19 states.
- The contract prototype trips `derivedCells`' flat/indexed cross-check. The indexed read is `lost`, so it
  costs precision, not soundness.
