## 2026-10-31 00:10 CET — own2: a part a callee answers is read below it

**What I did.** Fixed #1370. Under `--ownership=v2`, `Debug.toString (idl k)` with a
monomorphic `idl : List (List Int) → List (List Int)` was accepted after a push of a list
that `k[*]` holds. `wkids` (a record taken out of a constructor), `rkids` (a field), a
result bound first, a construction, `▷`, a deep-reading user callee and a pattern
(`case idl k of [ y ] → List.length y`, which reads the pushed list itself) were accepted in
the same way. v1 refuses all of them. The specification is in `ownership-v2.md` §2.7, under
*A part a callee answers*, with a line in §2.10's Liveness bullet. A node of a callee's use
that is marked `A` now reads every path below it for the caller's liveness, as `D` does. The
readers are `Holders.stepCursor` and `Exits.deep`, and both go through the new
`Cell.Table.readsBelow`. The fixtures are `ownership/AnsweredRead` and
`ownership/AnsweredReadImported`. On master's `src/`, 9 of their 10 demands each are accepted
where v1 refuses.

**What I learned.**
- The bug was not in `readsOf` or `Debug.toString`. A call is the last use of its argument's
  local, and the reads of the result that come after it are recorded against no local.
  Parameters were already right, because `readsOf` (#1352) grafts the result's param cells.
- Unannotated `idl x = x` was refused only by luck. Its `π1` has a type variable's place,
  where the holder cursor finds no step and is free. The reviewer's repro works only once
  `idl` is monomorphic.
- The v2 dumps of ownership/, ownership/core and run/ (1 005 roots after the rebase, master
  against the branch, summaries included) differ only in the two new fixtures. No corpus
  program had an answered node above a hold. Three dumps also differ in the addresses of a
  Debug-build leak that master has too (`Calls.prefixArg` under `foldedCells`), filed as #1391.
- The refusal on a cycle names `r⟨Outer⟩.v` for a `Tree` hold. That is #1371, and I left it.
- Once, the imported fixture showed every `Main` declaration as `not built: call` on both
  binaries. It did not happen again on any later run, at `--jobs=1` or `--jobs=8`. I am
  noting it here and have not chased it.
- `zig build gates` took 1 min 33 s to 1 min 54 s in this worktree, not the ~10 s that
  CLAUDE.md says. A sequential Debug-build dump of the whole corpus takes more than 2 minutes
  per binary.
