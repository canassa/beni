## 2026-10-23 04:27 CEST — Eager arms call total declarations

### What I did

Built #618's consumer slice on master after #645 landed. `Lower`'s pure/total
classifier (`instSafeMode` in total mode, behind `Context.valuePureTotal`)
now accepts a saturated call, with no hidden evidence, of a declaration the
checker proved total — `Dispatch.EffectDecl.total` for this module's,
`Interface.Scheme.total` for an import's — when every argument is pure and
total too. The 4 096-node cutoff of the same walk is gone, as the owner
approved: the walk was already an iterative stack over a BIR tree, so
removing the counter leaves an uncapped iterative walk with no other limit.
Amended browser-inline.md §8 and the `valuePureTotal` doc comment;
checker-v2 §26 and effects §14.9 already specified the consumer.

Red first. The twin tests in `iface_test.zig` (local, imported, `foreign`
via `String.length`, callable alias, warm body drift) failed 2 guards to 0
on the old classifier. The wide case needed a rewrite: the first draft's
balanced tree of `+` hit the parser's per-declaration charge for operator
chains (language.md §10), so it failed with `nesting_too_deep` both before
and after — it was not a red. A balanced tree of prefix `Basics.add` calls,
8 000-odd nodes but 24 levels deep, is red with the cap and green without it.
The three page fixtures (`HelperTotalCalls`, `TotalCallBranchOwnership`,
`SelectedThrows` extended with an argument after the throwing one) print
the same transcript on the old and the new compiler. That is the point:
evaluation order, throws and hidden-arm behaviour are unchanged. Most of the
fixtures come from the earlier Codex worktree's uncommitted consumer work.

No existing `emit/` golden or run hash moved.

### What I learned

A source-level size test must fit the parser's limits first. Operator and
access chains charge their links to the whole declaration. Prefix calls
charge only the current path.
