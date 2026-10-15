## 2026-10-14 22:51 CEST — rebase the test budget change onto the direct JSON grants

**What I did**

Rebased PR #104 onto master a87b51193, which holds PR #106: the owner's
grants of 6 300M to `browser/direct/HttpJson` and 6 400M to `HttpJsonBody`
(compiler defect #105). `CLAUDE.md` and `tests/corpus/README.md` keep both
rules: the grant for a compiler defect with an open issue, and the one
reference build. `zig build gates` is green. With the grants set aside, the
reference build counts `HttpJson` at 4 809M and `HttpJsonBody` at 4 951M,
under load. The README now says that `-Dtest-budget=1` leaves a granted case
at its own limit. Added the blank line that the rebase took from in front of
my first entry. Marked the PR ready for review.

**What I learned**

A `.budget` file sets the case's limit in millions directly
(`timing.caseLimit`), so `-Dtest-budget` does not reach a granted case. To
count one, set its file aside for the run. Both counts are 13–14M above
the same command before the rebase (4 795M and 4 938M).
