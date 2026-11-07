## 2026-10-31 03:13 CET — own2: two calls on split positions need parts

**What I did.** Took #1409 (`bumpAll xs = case xs of [ a, b ] → [ inner a, inner b ]`).
On master the report's symptom has a different shape from the one in the issue:
v2 refuses both calls inside `bumpAll` (`alias`: `b` holds `a[*]`; then
`held-operand`: `inner a`'s result holds `b[*]`). A refused demand publishes no
reliance, so `bumpAll` has no `xreq`, and every caller (`bumpAll [ x, x ]`) is
accepted. Even one call beside a held position (`( inner a, b )`) is refused. The
head-and-rest form (`[ ys, …rest ] → [ inner ys, …bumpOne rest ]`, from the 4a
agent) is the same. Wrote `TwoCallsApart` and `TwoCallsApartImported` with v1's
goldens. They cover two calls, three calls, the calls in a `let`, a call beside a
direct push, and a head beside its rest. Each has a doubled caller (refused), a
fresh doubled caller, two lists that share an element, a distinct twin and a
distinct fresh caller. Both fixtures are red on master.

**What I learned.** The cause is #1390's: a projection of a split position forgets
the split (§2.2, `Shape.projectLeaf` through `Cell.unrefined`). So `a[*]` and `b[*]`
are both the canonical `π1[*][*]`. The holder index and a pending result then
compare two equal symbolic cells. #1387's `splitBeside` cannot help, because it
reads refinements only on the actual's own spine, and here the holder is another
local or another call's result. `discharge` and `xreq` publication are correct.
They never run, because the demands are refused before condition 6. The #1390
branch (`own2-pattern-positions`, commit `3c09eb99f`: `part r·q` cells, and a
match on a rest splits the rest's positions) turns both new fixtures green with
every verdict v1's. It also turns 4a's pending `GroupSplitXreq` green on a scratch
merge. So #1409 needs no `src/` change of its own. It needs #1390 first, then
these fixtures.

**After #1411.** #1390's work merged as #1411. Rebased onto it, both fixtures
pass with no `src/` change. Every demand line has v1's verdict. One line has
a different cause: `rf` (one fresh list as both items) is refused `disjoint`
by v2 and `exclusive` by v1. This is allowed by §2.8 as #1410 amended it, and
the fixture comments say so.
