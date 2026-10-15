## 2026-09-27 — R8d: derived == and compare do not grow the native stack

**What I did**

- CK-128, the owner's decision: derived `eq`/`compare` must not throw on deep data (a user linked
  list threw `RangeError` at ~8 900 cells in node). Derived functions that can recurse carry a
  depth and, past 400 units, continue from a generator twin driven by a small per-module engine,
  so the native stack no longer grows with the data. Evaluation order and short-circuiting are
  exactly the recursive version's (a 4.6 M-line ordered-call-log fuzz against e86883a matched).
  3 × 10⁶-cell lists compare in Chrome, Firefox, WebKit and node. Stated exclusion: recursion
  THROUGH a hand-written parametric method still grows the stack, pinned by an abuse test.
- Black-box tests, red before: `run/DerivedDeepData`, `DerivedDeepPaths`, `DerivedDeepOrder/`,
  `DerivedDeepAcrossModules/`, and three abuse scenarios (a 4 095-deep record literal, 4 096- and
  4 097-parameter recursive types, the exclusion).
- Cost: shallow recursive-type comparisons 11–20 % slower in node; release brotli +2.5 % across
  the size corpus. The reviewer found a better shape (a tail self-call becomes a loop; depth only
  on real recursive cycles; one shared engine), which should make recursive types faster than
  before R8d and halve the size cost: the next small slice, R8e.

**What I learned**

- A fix can be correct and still be the wrong shape for a browser-first language. Asking the
  reviewer to price alternatives turned a 20 % regression into a likely net speed-up.
