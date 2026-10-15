## 2026-10-14 19:51 CEST — set the owner's limits on the direct JSON budgets

**What I did**

Applied the review of PR #106 and the owner's answers. The limits are
now 6 300M and 6 400M, not the 8 500M and 8 800M of my previous entry:
each case's count with Node running on the gate's host, plus 10%. The
rule in CLAUDE.md and the corpus README now lets the owner grant a case
whose cost comes from a compiler defect with an open issue, until the
case fits 4 300M; these two grants cite #105. A `.budget` file now sets
the budget of the page case only, so a page's `[value fuzz]` case keeps
4 300M. Added the print side (`Http.jsonBody`, 705M of `specialise` per
release build) to issue #105. `zig build gates` is green.

**What I learned**

I sized the first limits on a baseline-CPU build, but that build fails
the gate on six other cases, so it can never be the host that holds
these two. A limit must be sized on a host where the gate can pass. A
file grant applied to every case of its fixture, so it also covered a
case that nobody asked the owner about; `-Dtest-budget=1000` showed it,
because an own budget stays absolute under that flag.
