## 2026-10-25 01:46 CEST — fold an accumulator of an unnamed cyclic type

**What I did.** Measured O4's gate (#320) and found `check/good/CyclicArgumentsUnify` refused by
`ownership_limit` once enforcement is on: `List.foldr [] [] List.intersperse` never settles. I opened #955
and fixed it. `instFold` now folds the composed path when the callback answers a value whose type is a cycle
of the unifier's graph (`cyclicVar`). An entry nested once more below its own cell goes to `r⋆`, and the
first nesting stays exact, as with F3. The amendment is in §16.7. `ownership/CyclicAccumulator` is red on
master: four `limit` lines. With the fix, `twice`'s shared nesting is refused exact and `once` is accepted.
The O1 audit driver with `--ownership-everywhere` shows 0 verdict differences over 1 599 roots, and only
`CyclicArgumentsUnify`'s check now passes.

**What I learned.** A cyclic type can come only from instantiating a generalised function. A lambda or
binder of that type is `INFINITE TYPE`. So the fixpoints of recursive groups cannot meet one, and the only
site is a callback's accumulator fixpoint. No region marker can name such a type, because it has no
declaration. That is why the fold is F3's composed-path fold and not #853's region rule.
