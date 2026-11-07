## 2026-11-01 12:17 CET — own2: fold first, specified, and the slice key that made propagate order-dependent

**What I did**

- Specified §2.9 *Fold first*. `propagate` builds no position that a fold collapses: a frame first
  marks the folds its children make, then walks its other children inside the highest fold target's
  region, so it never builds the positions that would collapse. It is prototyped in scratch on
  master `46ede32b6` with 4e.
  - #1289's published chain at 8 calls: 1 035 528 → 53 498 records, about linear in the calls.
  - `removeMin`'s walk-2 joins: 2.69 M → 141 k records each.
  - Corpus: no line changes.
- Measured what is left: 105 distinct sets of states over 1 706 positions, and 23 distinct regions
  over 1 626. The memos on top of fold first are therefore F2's memo by run and a memo per region.
  Their effect is a projection only.
- Pinned down the two `removeMin` calls where the rule and the depth-first walk differed. The
  depth-first walk itself is order-dependent: reversing every frontier changes its snapshot. The
  cause is `slice_at`, keyed by a run's start alone: an empty run and the next one share a slice.
  With the key fixed, both orders and the rule agree on every call checked. Filed as #1526; it also
  removes #1497's panic.

**What I learned**

- I ruled out first-arrival deduplication by position by experiment: keys with the whole route and
  the fold bit did not change the reversed walk.
- The quickest way to the divergence was to record each state with its parent and step in both
  orders, and look for a child that one order has and the other does not under the same parent.
- Disk: each saved build of beni is about 1.3 GB with its cache. Eighty of them filled the disk.
  Keep at most two, and delete each one as soon as its numbers are read.
