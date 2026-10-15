## 2026-10-12 18:58 CEST — fact 5's null test decided from final facts only

**What I did.** Confirmed the last entry's suspicion: it was a real `--release` miscompile. `combine`
put a conditional into `decided_conds` whenever an evaluation found `x.p === null ? f : x.p` with
`x.p` nonnull, and nothing ever took the entry out, though the facts climb from ⊥ and a later sweep
can make the read ⊤. `run/SpecializeLateNull` (a platform module: `mk a = { p = a }`, `pick` testing
`p` against `null`, a `null` that reaches `mk` a sweep late through a recursive `pass`) printed
`x`/`none` in development and `x`/(empty) in release — `pick` became `a=>a.p`. Fixed at the root:
each evaluation of a conditional records its decision or removes it (`KeyMap.remove`, backward-shift
deletion, with a unit test), so what stays is the last walk's, from the final facts, as `memo` is.
`backend.md` §9 *As built — the worklist* amended. Every other output byte for byte (goldens, every
run hash); ApiItems' release build +0.1 M instructions safe (1 817.0 → 1 817.1 M), +0.04 M ReleaseFast.

**What I learned.** The safety build's worklist-versus-sweep-everything check cannot catch a stale
decision: both fixpoints climb through the same intermediate facts and keep the same entry. Every
other fact of facts 1, 2, 4 and 5 is a join that only rises, and `rewrite` reads it final; a stored
*decision* is the one kind of state a rising fact can invalidate, so any new one needs the same
take-back. The repro needed a maybe-`null` receiver (`choose`), or fact 6's identity folds the test
to a literal before the second case is reached.
