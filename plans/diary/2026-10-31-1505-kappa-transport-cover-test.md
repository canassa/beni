## 2026-10-31 15:05 CET — κ transport: the cover test carries the join (#1459)

**What I did**

- `dropCovered`'s cover test now reads each arm with the choice's entries carried to it, at the root and below (`carryTo`), before any arm is dropped. The reviewer's repro is a `Summary.zig` test: on the PR head it read `yes` and dropped a real arm, and now it fails as it should.
- I corrected the cost text. The read-off filter's quadratic in K inside a recursive function is its own per-`(position, entry)` walk, not K's snapshot. K outside a group is linear. The rest of that group walk is also superlinear without the filter, and #1479 owns that.

**What I learned**

- After the cover-test fix, `mergeSort` still needs the filter: 136 350 records in 4 walks without it, 43 103 in 3 with it.
- Whether an entry is implied depends on its position, so the filter cannot share submaps as `relabelMap` does. A linear filter needs another formulation.
