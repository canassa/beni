## 2026-10-30 17:17 CET — Ownership v2: a view's cycle read at its fixed point

**What I did.** Fixed #1314. A knot whose cycle has no `node` on it,
`U = union(leaf{π0}, delta(U, {[*]: site}))`, made `Shape.cellsOf` of a
call's view of it loop forever. The view's union answer has a delta side,
and that delta's base is the same interned view. `cellsOf` gave a record
its cells only after its sides had cells, so the cycle never closed.
`namedSteps` looped in the same way. `Shape.cycleWalk` is now one Tarjan
walk on explicit stacks, with its marks in a pooled column. It gives each
record on such a cycle the join of what enters the cycle from outside, the
cycle's least fixed point. `cellsOf` and `namedSteps` use it. §2.11
*Cycles, links and folds* now states the rule, in its own commit. The
repro is back in #1219's unit test. A new Calls test reads the knot's
view with every lazy reader: cells, reach, arrivals, rank, named steps,
proj, leq, eq, widen, join, `recastWhole`, κ and `deep`, and the view as
an actual of two more calls. Each read is bounded by the allowance, so a
loop fails and does not hang. Both tests fail on master. The verdict diff
(`bench/ownership-everywhere.mjs --diff=v1,v2`, 1 934 roots) is byte for
byte the same on master and on the branch.

**What I learned.** The rule that gives the same answer as `eager` is the
least fixed point. `eager` keeps a cycle as it is, and a knot's tie gives a
union the cells of its other side. A runtime-safety check of every
record's fixed point made a 1 000-deep positions chain quadratic
(125 ms → 990 ms), so the check runs only on real cycles. No source
program reaches the case today. Widen's emit and a block's knots close
every cycle through a `node`, and `cellsOf` stops at a node. So there is
no corpus fixture. `Holders`' same-path closure has the same loop and has
no unit-test harness. I opened it as #1335 for slice 4. Shape's §5 size
target went from 3 120 to 3 220 for the walk.
