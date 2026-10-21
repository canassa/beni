## 2026-10-21 10:04 CEST — the worklist batches per var, and values carry set ids

**What I did.** Issue #563, from the per-run profile (`plans/pts-per-run-profile.md`, causes 2
and 3, committed with this slice). `Pts.pending` is now a FIFO of vars, each with one batch
(flags, a set id, and the part no linking edge brought, which its summary folds); `join` merges
into it and the queue drains at the end of a constraint's evaluation, of `copy`, of `makeTop` and
of each sweep step, never inside a join. `VSet` and `Val` carry their set's id, so `setOf` is a
field read, `difference`, `filterSites` and `Load.done` are ids, a one-site set is found by site,
and `Sets.by_slice` is gone. Two counters, `spec_pts_joins` and `spec_pts_joins_empty`. Unit
tests for the batch, the kept slice and id, and the order on a cycle; the corpus case
`emit/release/inline/SpreadCopiesBatched` (51 children) was 4 556M instructions on master and is
3 988M now. Rebased once onto #566, #567 and #569 before building; their alias split moved into
the new fold step unchanged.

**What I learned.** The empty joins went from about a third of all joins to almost none, and the
joins halved, but on today's master that is a 3–9% gain in `specialise`, not the halving the
profile predicted: the profile was taken before #562/#564/#568 cut the edges 4.5×, and the
worklist is now about 15% of the build. A shared scratchpad directory is shared: another
agent's files sat next to mine and my working copy of `Spec.zig` vanished from it, so work in a
directory of your own. And Perl with `|` as the substitution delimiter turns an escaped `\|` back
into alternation; use braces.
