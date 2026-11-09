## 2026-11-09 23:15 CET — Add up the runs of a handed-back closure

### What I did

The review of #2410 found an unsound acceptance: a callee runs a capture writer once and hands it back, and the
caller runs it again (`g = runBack λ⊤ → List.push k 1`, then `g ⊤`). The branch accepted it in place, and the
sanitised run trapped. Master refused it only because it escaped every handed-back closure.

The cause: two runs of one closure under different calls of the walk are normally refused by liveness. The closure
is still held after the first run (a local or a value) and is used at the second. Here the only holder after the
first run is the first call's own answer, which a write at that call does not stale. The callee's label said "runs
once", and the caller's direct call (the `.site` route) was one more single run, so nothing added them up.

The fix: `CaptureRuns.handedAgain` marks a closure of the frame that runs under two calls of the walk, one of which
runs it and hands it back (`FnSite.handsBack`: the call's result reaches the closure's site through the callees'
results, a returned closure's captures included). Every capture write at a run of it, or at a run made under one,
is `many`, so it is refused `once`. `CaptureRuns.outward` now also reads a code call of the frame's closure as the
outermost code. Spec: §2.11.3 *a closure handed back* gains the *runs add up* bullet and a soundness paragraph,
§2.11.4's #2395 amendment points at it, and §5's rows for `CaptureRuns` and `FnSite` gain their new imports.

Fixtures: six shapes in `run/SanitiserHandedBackKept` (each trapped with the branch head), and four once-run twins
in `run/SanitiserHandedBackApart`. A new generator, `gen3.mjs` in lane s6y's copy of s6t's generators, enumerates
2 592 run-then-hand-back programs: 436 TRAP on the head, 0 with the fix, and the same 476 SAME.

### What I learned

- Liveness excuses the call's own answer as a holder of what the call writes. That is right for a list the call
  returns, but wrong for a closure it returns: the closure reads the written capture again at its next run.
- Several shapes that look safe on the head (`apply g` after a hand-back) were refused only by `disjoint`, because
  the operand holds the capture. With a writer that applies a known local (`λ⊤ → p k`) that refusal does not fire,
  so the generator needs that writer.
