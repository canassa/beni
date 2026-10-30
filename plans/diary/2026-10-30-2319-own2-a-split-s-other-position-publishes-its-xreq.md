## 2026-10-30 23:19 CET — own2: a split's other position publishes its xreq

**What I did.** Fixed #1386. `t8 bs = case bs of [ a, c ] → rightLeft (Pair a c)`
relied on `a` and `c` being apart and published nothing, so v2 accepted
`t8 [ b, b ]` and `t8c b = t8 [ b, b ]`. The cause is in `Transfer.otherPaths`:
the base of the write into `c` is `π1[*]#Box.0`, because a projection forgets
the split, and `keepBeside` dropped the held `a` (cell `elem bs·ι` at position
0) as "another path of this frame's parameter", which it is not: both
positions are the one summary path `π1[*]`. Now the refinements the write's
path meets in the actual along its exact prefix are compared by `Cell.alias`
with each refinement beside the write whose canonical position holds the
base's. Another side of the split adds the split's κ to the demand's
reliance, and so `xreq excl π1[*]` to the class (§2.11 step 7, the existing
machinery). The same side keeps the base's cell, so `rightLeft (Pair a a)` is
refused `disjoint` as v1 refuses it (master accepted that too, and #1382's
branch does not change it). Spec: a paragraph in §2.11 item 3 (c), and
Transfer's §5 line target 1 810 → 1 890. Fixtures `ElementsApart` and
`ElementsApartImported` (fresh, parameter, distinct twins, three elements,
distinct by construction, transitivity through `pass`/`relay`) fail on
master and pass here.

**What I learned.** The v2 summary diff over all 1 985 roots of the
whole-corpus diff changed nothing but the new fixtures: no existing program
binds two pattern positions and passes them into one call that writes one
and holds the other. A refused callee publishes no `xreq` in v2 (only
accepted demands' reliances join it), while v1's refused `same` still
carries `xreq excl π1` to its callers; the fixtures leave such callers out.
The gates ran 1 770 of 3 097 programs under Node for want of a recorded
hash, which made them take two minutes.

**After rebasing onto #1382.** #1382's `holdsCanonical` reads each held cell
at its canonical cell, so it read `a` as `π1[*]` and refused `t8` itself
`disjoint` (v1 accepts it with `xreq excl π1`). `holdsCanonical` now skips a
refinement on another side of a split the write's path met (`otherSide`),
and `splitBeside` publishes that split's κ for it. Over the 1 992 roots, master
with #1382 and this branch differ only in the new fixtures: `t8`, `t3` and
`pass` are accepted with `xreq excl π1[*]`, and their shared callers are
refused. `ApartPaths*` and `ApartPathsBound*` hold. Transfer's line target is
now 1 940.
