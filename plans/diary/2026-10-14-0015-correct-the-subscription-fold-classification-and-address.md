## 2026-10-14 00:15 CEST — correct the subscription-fold classification and address review

**What I did**

Rechecked the complete copied driver with Dict.update using the latest checker.
It still rejects the List.foldl call to want. Removed the platform List.copy,
restored browser-tea's original helper, and changed the isolated helper fixture
to destructive focus. The actual builder starts empty and threads replacements;
the generic aliased-input twin does not prove sharing in that builder.

Added a focused opaque-tap fold under tests/pending/browser/direct/SubscriptionTapFold,
with list_may_be_shared pinned, plus a browser-tea oracle. The pending suite,
isolated focus helper, oracle and unsafe alias variant pass their checks. Corrected
the dated design amendment and PR #87; it is now a draft with the fold limit explicit.

Addressed the review with condition-only instantiation, safety assertions for
unchanged demands/uses/escapes, named namespaces and Escape fields, exclusion of
initial and unknown callback cells from optimistic seeds, a rejected unknown-tree
result and a recursive escape twin. All existing ownership goldens stay unchanged.

Full run-hash recording passed the corpus, failing only the two known case-folding
tests. Restoring the platform source also restored all pre-existing corpus hashes.
Native unfiltered zorg build gates has exactly the four owner-acknowledged Mac
failures: 1 292 pass, 15 skip. LLVM validation is in progress.

**What I learned**

The earlier diary and PR statements that the tap copy fixed real runtime sharing
were incorrect. The complete copied driver is not fully accepted: two Concurrent
limits are fixed, while the focused subscription fold remains a checker limit.
A fresh outer dictionary does not establish deep exclusivity of opaque captures;
the intended proof must distinguish the written containers from those captures.
No platform copy may bypass that limitation. Direct subscriptions in S5 still wait
on it. The unknown-tree twin is defensive coverage, not a demonstrated pre-fix
bypass of the new unknown-cell guard.
