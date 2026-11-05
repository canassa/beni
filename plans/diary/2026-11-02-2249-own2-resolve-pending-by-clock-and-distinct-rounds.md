## 2026-11-02 22:49 CET — own2 resolve lane: pending operands by clock, distinct rounds kept

**What I did**

- Issue #1714, resolve lane, branch `own2-cost-resolve` (no PR). Three commits:
  - `f267cb3d2`: the walk records each operand on its stack once, with the
    clock of its push and its removal, and a call records only the clock. The
    old walk copied the stack at every call. A new L8 file, `Stack.zig`, lists
    the pending leaves once, in lists sorted by push. Each list has two trees:
    the latest removal and the least `rank₂`. A demand reads the leaves in
    push order and stops at the witness. A parameter's target aggregates the
    leaves that have a parameter key, as the operand index does.
  - `8aaf1b2e1`: the distinct check keeps its groups across its rounds. A new
    L6 file, `Entries.zig`, was split from `Distinct` at the seam between the
    entries and the relation. A round places only the new entries and checks
    again only the groups that they changed. The roots to expand are on two
    heaps. A duplicate in a vouched block keeps the first entry in the inline
    order (each entry knows the expansion it came from).
  - `67d842598`: the changed groups are listed when they change, not found
    by a scan.
- Test 148 (live sibling positions) now passes: 136 538 → 26 029 records at
  n = 80, about 320 a position. build_test failures: 27 → 26.
- After each step: the ledger had 0 verdict changes, the limit lines and the
  summaries were equal, the oracle (1 245 runs) was equal, and the cost table
  showed growth 0.

**What I learned**

- A charge per item can make a data structure cost more than the copy it
  replaces. The copy was not charged. The first version of the pending index
  made `WideModel.step` reach `ownership_summary_size`, because it reached
  the incompatible operands of earlier arms. The fix was to prune the descent
  by `rank₂` (for an operand before the point, compatible ⇔ `rank₂` below). A
  second fix was a pointer over the writes in `finish`.
- The witness rule (the earliest pending operand) lets a visitor stop at
  the first `may`. A version that read every item and then took the minimum
  made the `pending` family 4× more expensive.
- GroupRotate n = 64: growth is 56 946 of 65 536. Neither change gives it
  headroom, because the cost is the recursive call's operand check in each
  round.
- The manager's `↓p` item is not fixed. The 29 positions that refuse with F7
  are caused by `atomTwice`. A deep apart occurrence `ε*~` reads every object
  below `ε` (the projection stops at `ε`), so an object that is also asked
  plain at `[*]#0.0` is an entry twice. The two entries have different routes.
  When the slots are written out, `Cond.of` drops `[*]#0.0~`. To drop the
  entry by its leaf alone is unsound, because the deep projection loses
  multiplicity. The exact reading projects the deep occurrence without the
  slots that are asked plain, by canonical paths. That is not built.
- Several remaining failures in this lane come from tag merges along choice
  chains: `Routes.merge` walks the common front of two lists for every pair
  (tests 8 and 21, in `Within` and in `Sweep.holdsAt`). Tests 5 and 26 list
  one hold per path of a doubling DAG.
