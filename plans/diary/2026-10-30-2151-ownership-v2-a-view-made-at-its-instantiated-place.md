## 2026-10-30 21:51 CET — ownership v2: a view made at its instantiated place

**What I did**

- PR #1359's second review found that `024c26ece` lost a write. A list of a recursive
  type held a view, and `positionsAt` and `reentries` compared the view's `var`
  place, so the write through `⟲` vanished. It also found that an `if` join of
  record literals with a view field depended on the order of its branches. #1374:
  a block that published `g xs = w1 xs` did not decode, because a node stood at
  `a × a` over children at `List Int`.
- The fix is at the source, not at each reader. A view is made at the place its
  call instantiates the template's to (`Views.placeImage`):
  - a leaf at a `var` place: where its actuals are, read off the place graph
    (`argPlace`);
  - a join at a `var` place: where its sides are;
  - every structured template: from the caller's result place down, placed once
    per call (`Views.instantiate`).
  `standsAt` is gone. A `runtime_safety` build checks that a forced view's place
  is its answer's place.
- A join's place no longer depends on order (`joinPlace`). A side with no such
  step is read whole.
- `Transfer.projectAt`'s fallback reads a built value's reach whole
  (`recastWhole`). A leaf stays exact there.
- Fixtures: `CallTyvarJoins`(`Imported`), `CallTyvarPublishedImported` (cached),
  `core/CallTyvarCastJoin`(`Imported`, cached). Six known-list entries for v1's
  `⟨Tree⟩⁺` text.

**What I learned**

- The first version computed the view's place with `argAt`. That made nodes early,
  and the new node order alone dropped `build_test`'s escape-product term from 162
  to 19, with the same escape queries. Reading the place off the place graph gave
  back 162.
- A view relabelled by κ before its parent was made got another place, and so
  another id. That lost κ in the `w1` towers. Placing the whole template at
  `apply` fixed it.
- Over every `ownership/` and `run/` dump, this round gives the same output as
  the PR's previous head.
