## 2026-10-30 20:43 CET — ownership v2: views stand at their answer's place

**What I did**

- PR #1359's review found two holes in the same class of defect as #1350. In
  both, v1 refuses the program and v2 accepted it.
  - A view as one of `choose`'s actuals: `(choose True (ans { b = g.x }) g.y).c`,
    a `choose` inside a `choose`, two views, a bound view,
    `(ans { b = choose True g.y g.x }).c`, and a write through a chosen view.
  - A view stored in a record literal and then projected:
    `{ b = ans { b = g.x } }.b.c`.
- Cause: a view keeps its template's `var` place. `instantiatedAt` and
  `argAt` compared that place, so the view did not match `g.y`'s place.
  `Transfer.fit` also recast the view to the record field's place. A step later,
  both were `recastWhole`.
- Fix: `Shape.standsAt` gives the place of the view's answer. `argAt`,
  `instantiatedAt` and `Transfer.fit` now compare that place.
  `ownership-v2.md` §2.11 has a new sub-item for this.
- Fixtures: `ownership/CallTyvarViews` and `CallTyvarViewsImported`. On the PR's
  head before this fix, v2 lost 10 refusals in each.

**What I learned**

- Over every `ownership/` and `run/` dump, the PR's head and this fix give the
  same output. The fix only reaches views at a `var` place.
- `Transfer.fit` is outside Calls and Shape. It is the one place where a record
  literal compares its field's place.
