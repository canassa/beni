## 2026-10-30 01:17 CET — View readers after the review

**What I did**

- **#1261.** `leafDepth` takes no `[*]` prefix as evidence, the same as
  `⟲`. The ownership corpus does not change.
- **#1279, the review's findings:**
  - The chain join is `Cond.chainStored`, memoised per `(ctx, view)`.
    `kappaOf` and the recast inners (`storedAt`) read it.
  - These readers now force views:
    - `foldCondWalk`, `Shape.join` (its members), `recastPart` (the raw recast's inner) and `dagKappa`'s approx flag;
    - widen's emit root, and the fold walks' roots;
    - `put`, `withCells`, `materialize`, `recast`'s composition and `leafDepth`;
    - every empty-value test (`isNothing`).
  - `dagWalk` counts a view as a DAG walk.
  - A class is stored forced. `Summary.Table.add` checks it. A template, a
    block and a summary hold no view. `Block.Writer` refuses one as an
    invariant, and the Normalizer forces. §2.11 *Who holds a view* says so.
- **Tests with real views:**
  - every template kind through `map`, `join`, `eq` and `reach`;
  - widen with and without a merge;
  - a view of the empty value;
  - the chain join and a recast's inner view;
  - a union's view of a recast;
  - `reachAgg` and `widenValue` over a view;
  - a call whose argument is a view.

**What I learned**

- The tests with real views found three defects that no reading caught:
  - widen emitted from the unforced root;
  - the fold walks started at a view;
  - a test of my own made a view answer itself.
- When widen has nothing to merge it returns the view itself. That is
  correct, but a test that compares structure must allow it.
