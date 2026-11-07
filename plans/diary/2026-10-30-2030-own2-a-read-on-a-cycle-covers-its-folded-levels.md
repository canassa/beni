## 2026-10-30 20:30 CET — own2: a read on a cycle covers its folded levels

**What I did**

- #1345. Spec first (`ownership-v2.md` §2.7, *A read that leaves its path
  on a cycle*; §2.10's Liveness bullet; §5's table): a use counts for the
  subtrees of its *exits*, the paths outside its subtree where `extend`
  puts what it reads. A read of every path below `p` exits at `Up(p)`, the
  fold targets of `p`'s levels above it, closed. A `call` use's node is
  replayed in the caller's place graph as `Walk.Graft` replays it: a folded
  step and a callee `⟲` (`levels`) are exits with the node they lead to.
- `Place.foldsUp` (`hits` per path from the plain children's, on an
  explicit stack, then closed over the targets) and `Place.levelsOf`, both
  memoised per path in the module's table. New `Exits.zig` (L5): the exits
  of `(path, use node)`, memoised per frame, and the cover. `Holders.covers`
  calls it; the descent lists the holds when a group has an exit. The graft
  needs no change: it already replays `⟲` and folds, and copies `D` at its
  path, where every reader now applies the rule.
- Fixtures `ownership/DeepReadCycle` and `DeepReadCycleImported` (v1's
  refusals, all red on master): `inlineField`, the `showKids`/`Rose` twin,
  mutual types (`Leaf`/`Wood`), a deep read two levels below the entry, a
  whole use (`case r.kids of`, which then reads the stale `k.v`), a
  callee's non-deep `⟲` read (`grand`), and an accepted control with the
  hold at the root's own field. A counted build test: depth 50 → 100, ten
  fields a level, 101 deep reads: 37 940 → 77 033 records (2.03×), 130
  records over master; 0.42 s.
- Across the ownership and run corpus, v2's verdict and summary lines
  differ from master's only in the two new fixtures. Records +0.16% in
  total, hold listings unchanged (26); the largest change is
  `ViewBelowSweep`, +684 of 77 116.

**What I learned**

- The hole was wider than the issue's deep reads: a `whole` use (a
  scrutinee, a comparison, a return) at a path on a cycle, and a callee's
  plain `⟲` read whose argument sits below the cycle's entry, missed the
  same holds. Both are the same rule.
- `⟲` names levels, not routes, so a deep read of `r.kids` also covers a
  tree that a sibling field of `r` leads to. That is a precision cost only
  where two fields of one record reach one cycle, and no fixture has one.
- v2 refuses these `element` (approximate) where v1 says `alias`: the
  hold under `⟲` is a summary position. That was already so at a root deep
  read on master (`showRose t`); the parity is by verdict, not cause.
- A ring of n mutually recursive types is quadratic on master already:
  `extend` walks the cycle's suffix of a path, which is the whole path on
  a ring. Not touched here.
