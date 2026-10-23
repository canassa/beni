## 2026-10-23 15:49 CEST — record the owner's root-closure decisions

**What I did.** Took #668 (S1 fix 7). Recorded in `browser-inline.md` §8.4 the six decisions the
owner adopted on 2026-10-23 for the root-closure design amendment: slice or cell, which handlers
move into a root, the explicit retention and copy proof, one synchronous ordered runner, the
loader only for proved routes, and the whole shape landing at once. Docs only; no emitted byte
moves.

**What I learned.** Reading the current lowering against the amendment: the per-tail write sets and
split sites of `write-sets.md`'s 2026-10-17 amendment are specified but not built, a `node` write
says nothing about object identity (a record literal at ρ is `node ρ`), and the generated
`unique-components` app replaces each widget's slice on every push and the whole model on a
snapshot. So the retention proof must read terms (`Rec(p, …)` against `Rec(none, …)`) and
ownership's entry facts, not write sets, and the loader is what keeps the slices stable there.
