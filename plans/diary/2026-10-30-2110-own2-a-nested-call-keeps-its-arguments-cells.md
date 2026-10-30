## 2026-10-30 21:10 CET — own2: a nested call keeps its argument's cells

**What I did**

- Worked on #1364: `w2 x = w1 (w1 x)` published `res .1 = .0` under v2 and lost `π1` at `.0.0` … `.1.1`. So
  `case w2 xs of ((a, _), _) → touch0 a + List.length xs` was accepted `fresh`. v1 refuses it.
- Found the cause. `Calls.Grafter.argAt` answered the actual at the template's `var` place as a place-only
  recast. A tuple's own cells are empty, and a `var` place has no steps. So the caller's `.0` of that recast was
  `Transfer.projectAt`'s fallback, a plain recast of the whole tuple, with no cells. The same loss happens for
  `idn (w1 x)` (everything lost) and `w1 [ x ]` (`.0[*]` lost). A leaf actual (`w1 x`) was not affected, because a
  recast of a leaf keeps the leaf's cells.
- This is #1359's defect (#1350), and #1359's branch fixes it: `argAt` answers the actual unrecast at a `var`
  place. I stacked the fixtures on #1359. `ownership/CallNestedResult` has the issue's program, `w3`,
  `idn (w1 x)`, `w1 [ x ]` written by an annotated callee, `pair (w1 x) x`, `sw (w2 x)`, `t2 (w2 xs)` and an
  accepted control. It holds v1's verdicts on #1359. With master's `src/` it has 10 refusals that v2 accepts.
- `ownership/CallNestedResultImported` (the callees in `Pairs`) showed a new defect in #1359 (#1374). A view of
  a `node` template is published at the template's place, while its children now stand at the actual's place.
  `BlockRead.verify` refuses that edge, so `Pairs`' block does not decode and every call into `Pairs` is
  `not built: call`. A plain `g : List Int → List Int × List Int; g xs = w1 xs` in a module is enough to cause
  it. The fixture's `_expected.v2.unchecked` records this until #1374 is fixed. With master's `src/` the fixture
  fails.
- Opened #1375: a list pattern over a call's result at a `var` place is `not built: pat_list`, on master and
  on #1359 (`Transfer.bindList` reads the view's place).
- Corpus diff, v2 dumps of `ownership/` and `run/`, master against #1359 plus the fixtures: only #1359's own
  changes and the two new fixtures. No other fixture becomes unchecked.

**What I learned**

- A view's place is its template's place. #1359 makes leaves stand at the actual's place, so the published
  node is not consistent with its children any more. In a module nothing checks this. Only the block reader of an
  importer does, so a single-module fixture cannot catch it. Every fix that moves a place needs an imported twin.
- `Transfer.projectAt`'s fallback for a missing step is a plain `recast`, whose cells are the inner's own. For
  a built inner that is empty. #1359 removes the way this case was reached here, but the fallback stays a
  place where cells can be lost.
