## 2026-09-27 — R9b: tuple comparisons back within budget (CK-131)

**What I did**

- `s_tup6000` (`( a, [ b ] ) < ( b, [ a ] )` × 6 000) went from 1.60× v1 to 1.06–1.10×: table
  primitives answered at once, v1's plain-method fast path ported, a dense ground-derivability
  memo, a per-module derivability memo keyed by type structure, P6's small-unit memo inline. A
  byte-for-byte differential over 656 fixtures, `core` and both bench corpora matched 919f8be. I
  had a cycle-test skip reverted (≈1 %, resting on an argument) and a rollback guard added to the
  two memos keyed by variable ids.
- R9's review leftovers: filtered determinism binaries assert their test counts; a
  `v2-expected.md` fixture that starts passing fails the step; one statement of the §3.2 table.

**What I learned**

- The last few percent after a round of real wins tend to come from shortcuts that rest on
  arguments; decline them unless the walk itself proves them.
