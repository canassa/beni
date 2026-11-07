## 2026-10-31 17:35 CET — own2 5c review: a view of a call's answer

**What I did**

- The adversarial review of #1499 found an unsound accept that the first #1491 fix missed:
  `v = kidsOf t; case v of [ _, …rest ] → case t of Rose _ ks → ( List.push ks x, rest )`. Traced it in
  the holder index. A call's answer is relabelled to the canonical cell it answers, so `rest` is a side of
  the plain cell `t#Rose.1`, and the target `ks` is a match's refinement of it. The pair was found, but
  `samePosition` required the holder's cell to be the refinement. The review's guess, that `unrefined`
  returned null for a call-result cell, was not the cause. Either cell may now be the refinement.
- Added `ViewOfCallAnswer` and its imported twin: the answer bound first, matched in place, through a second
  call, through a choice, a writer call, a list from below the first return and a two-level second match.
  The first four fail on the previous head. v1 accepts the two-level match: a known entry for v1.
- Rebased onto master after #1494 and the 5d2 commits.

**What I learned**

- The holder index's cross-check against the naive scan runs only on frames of at most eight holders by
  default, and every frame of these shapes has more (the smallest has 15). So in the gates nothing tests the
  naive half alone. Reverting it alone makes `-Downership-full-cross-check` panic on both fixtures, and the
  full cross-check over the ownership corpus passes with the fix.
- A fix for a pairing rule must be checked in both directions: holder refined and target plain, and the
  reverse.
