## 2026-10-14 00:24 CEST — finish review coverage and prepare the authorised merge

**What I did**

The follow-up review found no checker blocker. Added its requested non-recursive
callee/caller twin: fork may escape in one arm, and afterCall still rejects the
subsequent append. Moved entryRes documentation below the namespace constants and
made the pending README explicitly describe why both runtime builder forms block S5.

Native gates found the four known Mac failures plus a time-report CPU-budget
overrun at 1 005 ms against 999; the isolated time-report test passed unchanged.
The owner explicitly said to ignore that overrun, skip more LLVM gates, and merge
once review is done. Preparing that merge with the subscription fold still pending.

**What I learned**

Both the recursive and non-recursive twins now pin conservative escape summaries
across calls. The remaining fold limitation stays explicit after the scoped fixes
land; merging them does not make direct subscriptions ready.
