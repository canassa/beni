## 2026-10-15 16:02 CEST — Gate the oracle review's three ownership mutations

**What I did**

The ownership oracle's adversarial review named three permissive mutations
of `src/own/Ownership.zig` with unsafe witnesses: a list pattern's
`…rest` binding no cells (view), later spreads left out of a
construction's disjoint check (append), and a record update no longer
using its base (record). Added three `tests/corpus/ownership/` fixtures,
each built for `browser-direct`: `ViewAliases` (both directions of the
view alias, a front spread, a parameter, and an accepted control),
`SelfSpreads` (`xs ++ xs`, `[ …xs, 4, …xs ]`, a chain ending in its base,
a renamed base, a view of the base, and an accepted control) and
`RecordUpdateUse` (the witness, a parameter, a nested record, a branch,
and an accepted update that replaces the field). No checker change.

Applied each mutation exactly as the review's `mutants.mjs` wrote it and
ran `test-blackbox-corpus` on each new fixture: all three fail, with
every rejected line turning into an accept. Ran full `zig build gates`
against the record mutation with the new fixtures set aside, then gates
green on the clean tree.

**What I learned**

On current master the gates already caught all three mutations before
these fixtures existed, though not all by a verdict. View changed
`Binders`' `spreadArm` verdict; append changed `Spreads`' `twice`
verdict. Record changed eleven ownership goldens, but only by a lost `R`
bit in summaries. No verdict pinned the unsafe accept, so a re-bless
would have hidden the hole. The review's counts (view 1, append 1,
record 0) are consistent with counting changed verdict lines only.
Pin a soundness rule with a rejected line, not with a summary bit.
