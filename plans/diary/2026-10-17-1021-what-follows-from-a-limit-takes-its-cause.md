## 2026-10-17 10:21 CEST — What follows from a limit takes its cause

**What I did.** Issues #233 and #272 (its first bullet). A declaration that reaches a §16.7 limit is one error,
and what rests on the limit should not be printed beside it. Two kinds still were. A call of a callee whose
summary is the pessimistic one printed its function arguments' `need` line (told as "list changed while still
in use") and a `pending` "keeps it" line: a walker flag, set while `applySummary` applies such a summary, now
gives those lines, and a borrowed supply's rejection, the `limit` cause. A condition lowered at a limit — a
fixpoint's seeds, a value past `value-cells`, a class with the pessimistic summary — was a plain `cond_lost`,
so a demand that relied on it was refused as `exclusive`: it is now `cond_limit`, which fails as `cond_lost`
does, and `rely` answers `.limit` for it (exact, then limit, then approximate). Fixtures
`check/bad/direct/OwnershipLimitPessimistic` and `OwnershipLimitValueCells`: master printed three and one
extra errors; now each build has the limit's error alone. Gates green, `bench/ownership-everywhere.mjs` 0 of
850.

**What I learned.** The `value-cells` limit is easy to reach on purpose (a list of 257 lists handed to a callee
that writes an element), which makes #233's shape testable, although no measured program reaches it. A
condition value that means "lost because of a limit" has to be threaded through every place that compares
with `cond_lost`; a switch with an `else` prong hides a missed one, so I listed them all with grep first.
