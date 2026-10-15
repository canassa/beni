## 2026-10-15 09:39 CEST — Rebase helper templates and answer the review

**What I did**

Rebased PR #98 onto current origin/master df04ca2db. Preserved every previous
diary block verbatim (checked against the pre-rebase tree). Kept master's
instruction-budget/reference-build rules and its stronger cache-pruning test;
the earlier CPU-fallback scaling is superseded. Removed conflicted hash records
and regenerated them with zorg build test-run-hashes, never hand-merged.

Answered all twelve Claude review points with comments, conservative handling
of missing dispatch metadata, a stronger finally scope, explicit oracle limits,
and paired/fuzz fixtures for a literal-then-path formal, a conditional choice
between two collection paths, Maybe Html/text transitions, and a volatile input
inside a helper-owned row. The row probe found a shared compiler bug: tea's
clock stayed stale because row effect facts were computed only for grouped
roots. Compute those facts independently of grouping, without enabling direct's
parameterised template protocol for tea. Specified the fix in backend.md first.

Final hash replay has 546 passes and only the two known macOS failures. Native
and LLVM unfiltered test/test-blackbox/fmt-check/beni-fmt-check each have 1,304
passes, 15 skips and those same two failures. The final helper and Conduit
Chrome scripts and paired value fuzz pass; master's driver fixes have removed
the old navigation-fuzz limitation. The hardware-budget gates deliberately
refuse this macOS host under master's new rule, so that gate remains owed on
a suitable x86-64 Linux host. No counter rule, budget or coverage was weakened.

Rebuilt and remeasured Conduit after the rebase/fix, retaining both batches.
Research 95's final tables use the rebased artifacts and include sample ranges.
The S0 series now has 102 programs; Conduit's 782/114 facts, 96/97 bounded keys,
zero value roots and 9/62 patchAll calls are unchanged. Every dispatch's actual
visits equal its independent prediction; criterion 7 does not fire.

**What I learned**

The final output is 38,030 B brotli versus before 32,411 and tea 31,389. Final
feed/favorite/editor medians are direct 0.395/0.315/0.365 ms, before
0.390/0.325/0.340, tea 0.295/0.250/0.315. Direct before/after sample ranges
overlap, so the small median differences alone are not a statistically
significant regression claim. Tea is faster in both measurement modes. The
parameter preparation/context/selection costs remain despite correct group
visits. There is no performance acceptance or post-measurement tuning. The
instruction-budget gate, earlier S0 tripwires and full second V3 campaign
remain open. The PR stays draft and unmerged; the user-owned review plan is
untouched.
