## 2026-10-31 05:59 CET — own2: witnesses for the home and the submap relabel

**What I did.** I answered the review of PR #1431. The review found that disabling `memoAt`'s home lookup, or `relabelMap`'s memo, left every v2 build test and the corpus green, because K, their only witness, is not counted (#1428). I added three unit tests in `Cond.zig`:

- A correctness twin. `union(a, b)` is read at a position that differs from its home only outside the region, and takes the home's entry. It is also read at one that binds `a` and `b` otherwise, and must be read there. When `readsAlike` is skipped, the test fails.
- A counted union tower read at a position one level larger each time. It is linear with the home and quadratic without it.
- A counted relabel of 16 and 64 linked positions that share one 128-entry map. It fails when the `maps` memo is removed.

I checked each failure by hand on a scratch edit. `chainStored` now skips `memo_chain` and `home_chain` under `no_memo`, so the full cross-check walks the whole chain. I ran the ownership corpus once with `-Downership-full-cross-check`. Its only failures are v1's three known ones (`LevelPlacesKinds`, `QuadChildren`, `QuadChildrenImported`; #1307, #1432), and they fail the same way on master. I also amended Appendix B and the 5d1 row: the gates count at 10 / 40 / 160, and 1 000 is measured in the PR (the manager's decision).

**What I learned.** A counted family test is a bad witness for a memo when the one family that needs the memo is left out. A small unit-level count of the same shape pins the memo, and it does not depend on that family's other defects.
