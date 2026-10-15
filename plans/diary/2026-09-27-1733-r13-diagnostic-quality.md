## 2026-09-27 — R13: diagnostic quality

**What I did**

- Every message finding closed spec-first (`checker.md` §8.7, spike §10.13 and amendments):
  CK-49, 50, 52, 53, 54, 55, 56, 58, 59, 60, 86/129, 94 (`number` variables named by kind, in
  messages and interfaces), 116 (a failed payload requirement is reported as itself, not as "a
  function anywhere inside", carried on answers and a new published `requirement` row;
  interface format 6), and the deferred-record redraw R11 noted. All 12 pending message fixtures
  promoted; `tests/pending/` now holds only CK-126 (schema slices). CK-115 did not reproduce; a
  guard fixture holds it. Each re-blessed `.diag` names its CK.
- Committed on my own gate run; R15's audit covers this slice's checker changes.
- Open doubt: articles are chosen by the first letter ("an `url`"), as the spec now says.
