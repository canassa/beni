## 2026-11-27 10:32 CET — v3 reads a fold's accumulator at the same place

**What I did.** Won `browser/inline/FoldRight`, `DictFoldLeft` and `DictFoldRight` under v3 (#2657), on top
of the unreviewed step that keeps a call's claims where no duplicate reaches (1aba5ff3d0), which I reviewed and
gave its own reviewer. Kernel §3.4, *a walked body's own type variables*: a walked body that does not cast makes
no value of its own type variable, so where no call of it can answer a new value of one (`Frame.taintCall`,
`taintType`, `taintHanded`), its result and supply sources at that variable's location are marked
`Src.same_place`, and a caller reads them as a cell's row's (`paired_exact`, `resolve_exact`,
`SrcState.below`). New fixtures `run/FoldIntoDictInPlace` (and its live twin); the three pages carry
`.sanitize-lists-v3`. Merged `origin/ownership-v2-design-review` (e22c75218e, fix224) in.

**What I learned.** The wide reading had three readers, not one: the param source of the result at the
variable's own location (empty suffix), the resolve of what a fold hands its callback, and, for a callback
parameter at a closure or opaque location (`Loc.Kind.wide`), the answer of earlier runs read whole, every
entry of it. Only the three together win the pages. Both reviewers found no fault; each found one unchecked
path (a frame function parameter's opaque answer under the duplicate rule; an `unknown` of parts at a type
variable's location), both closed on the pessimistic side with no page lost. The ownership oracle cannot judge
a page that v1 refuses: its plain leg uses the default checker, so these pages need a manual legs run until the
switch.
