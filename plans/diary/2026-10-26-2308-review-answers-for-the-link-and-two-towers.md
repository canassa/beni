## 2026-10-26 23:08 CET — review answers for the link, and two towers

**What I did**

- #1114: `Cond.side()` now joins every inner of a member at a recast's place, not only the first. The test uses two inners with different `[*]` nodes, and a second case stores at both.
- #1115: the one-alternative link was unsound for `[ ( a, b ) ]`, `[ ( xs, x ) ]` and a recast member. The link now keeps a root entry, `κ(member) ∧ summaryExcl ∧ apart(arrivals(member))`, and `Shape.arrivals` is memoised per node. At a summary position, the reader derives `summaryExcl` and `apart` for a built node, a delta and a recast. The proof is in §2.9. The tower stays n log n (1 051 / 11 389 / 131 035).
- I measured the review's two towers and filed an issue for each: #1119 (the join memo) and #1120 (`widen`). I corrected the PR body's claim and answered the review. The LLVM gates are green on #1115.

**What I learned**

- `r_k = if c then Rose [ r ] else r` costs n^2.6, all in `inspection`, while the shapes and the block stay linear. A memo is the fix.
- `r_k = Rose [ r, Rose [] ]` is different. The published block itself is quadratic, and every entry reads `lost`. The cause is the result's `widen`, which keeps `positions` sides beside the knot. With that widen removed, the block is linear and exact. No change in `Cond` can repair a tower whose output is quadratic, so first measure the output's size, then the cost.
- The summary printer walks a DAG as a tree, through each union side. The text dump can therefore look larger than the block. Compare the block's bytes, not the number of printed lines.
