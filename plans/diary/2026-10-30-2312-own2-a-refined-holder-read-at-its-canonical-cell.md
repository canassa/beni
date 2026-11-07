## 2026-10-30 23:12 CET — own2: a refined holder read at its canonical cell (#1385)

**What I did.** The second review of #1382 found #1385, which blocks it: `g p = case p of Pair _ x →
rightLeft (Pair x x)` was accepted, and v1 refuses it. With the B change, `b7`
(`case t of Br _ _ r → rightLeft (Br r [] r)`) and `a7` regressed from master's fold-only refusals. I
traced `Transfer.keepBeside` on `g`. The held `x` is a refinement of the caller's own `π1#Pair.1` (cell origin
`below`), so its reach had no `param`-origin cell, and neither the equality nor the #1383 hold-above
reading found the written `π1#Pair.1#Box.0` below it. Each held cell is now read at its `unrefined` cell
(`holdsCanonical`). I put spec and fix in two commits after #1383's and before the B change, with
`ApartPathsBound` (`g`, `gLeft`, `gMid`, `b7`, `a7`, the `Maybe Box` and tuple controls, distinct twins) and
`ApartPathsBoundImported`. Every line has v1's verdict at the tip; the fixtures fail at the old PR head and
on master.

**What I learned.**

- The suspected id collision between the caller's and the callee's `π1#Pair.0` is not the cause. Symbolic
  cells are keyed by `(origin, index, path)` on purpose, and a call maps the callee's through its
  actuals. The refinement hid the hold, the same identity gap as #1383's refined base, on the holder's
  side.
- Building a commit history ahead of a change already on a branch works with `cherry-pick -n` of a
  temporary commit. Each replay conflicts only in `ownership-v2-known.txt`, which is regenerated from the
  harness at each step.
