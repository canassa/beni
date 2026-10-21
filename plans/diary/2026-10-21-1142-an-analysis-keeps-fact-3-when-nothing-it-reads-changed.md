## 2026-10-21 11:42 CEST — an analysis keeps fact 3 when nothing it reads changed

**What I did.** Issue #575: `Mod.fact3`, set by every `Mod.changed` and
`namesChanged`, cleared when fact 3 solves; `Spec.fact3Kept` lets the next
analysis keep `Pts`' state when no module set it and none grew a node or a
name. The one write that does not set it is an identifier written as a
number, string or boolean whose fact-3 value was the primitive alone, not in
object position, not `__proto__`, with no type key (`fact3Neutral`). A safety
build re-solves every kept state of a program of at most 1 500 nodes and
compares it fact by fact, site numbers included (`Pts.checkKept`).
`spec_points_to_reused` counts the kept analyses. Two unit tests (a literal
fold keeps, a dropped parameter re-solves) and a `build_test` case on
`run/ReleaseReadAcrossWrite`, red before.

**What I learned.** The case the issue measured does not take the skip under
the rule as specified: on today's master the rewrite between analyses 2 and 3
of N = 64 folds `"root"` (neutral) but also drops that function's parameter
and its call's argument, and `prune` trims an `import`. N = 16, N = 64 and
`nowd` keep nothing (7/0, 6/0, 6/0 runs/reused), times unchanged. Only 3 of
453 `run/` release builds keep a state, all at the analysis after
`releaseKeeps`. In a sample of 123 within-`rounds` analyses, a parameter drop
was among the changes in 79 and the only one in 24: that is the change worth
making exact next (remove the parameter from the site's `params`, reset the
dropped arguments' values, drop the local). Making `prune`'s `import`/`export`
edits neutral (fact 3 never walks them) was tried and moved no build, so it is
not in. With the flag never set, the safety check panics across
`run/Specialize*`, so the check does guard the rule.
