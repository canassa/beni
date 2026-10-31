## 2026-10-31 18:27 CET — own2 4e: stable images measured, arm sets withdrawn

**What I did**

- Prototyped both pieces of 4e in a scratch copy of master `a4accd406` (4d and 5a merged), and
  measured each one alone and together. The pieces are arm sets (choice and union as canonical
  treaps over sorted arms, in the constructors and in `map`) and stable images (`map`'s knots and
  `widen`'s output interned by canonical form).
- Dumped every port and every `propagate` call. A node script counted the DAGs raw, as choice sets
  and as union sets, the knot images each walk made, and the states per position.
- Ran the 2 053 corpus roots and 1 200 random programs (a scratch generator) on every variant. Also
  measured #1289's tree-insert chain and #1489's two-branch insert, at the coordinator's request.
- Rewrote §2.3's 4e text in place, with the lemma per reader, the checks and the numbers. Updated
  §8's 4e row, the #1372 row and question 8.

**What I learned**

- Arm sets in a shape constructor are not exact. A published value's κ is carried node by node, so
  an entry at an interior choice node is lost (`CallOtherPathsSharedLeaf` drops an `excl`). Union
  sets also break convergence: the quadtree does not settle in 90 walks. The gain was at most 2.5 %.
- Stable images are exact on the corpus and on the sweep. Interning `widen`'s acyclic output, one
  component at a time, saves 29.5 % of the sweep. An accumulator `N [ n ] [ n ] t t` goes from
  1.7 M to 0.3 M records. On the corpus the saving is only 0.4 %.
- Neither piece touches `removeMin` or `descend`. Walk 2 of `removeMin` unfolds a 236-node DAG into
  74 134 positions, with only 161 distinct state sets. Even F2's lower bound leaves about 180 000
  records for that walk, so core needs a decision beyond F2.
- #1289's exponential is not port growth. It is one `propagate` call over n nested, distinct knots,
  where the positions multiply by about 3.7 per call and the runs grow linearly. #1489 has real port
  growth (raw unions over equal copies), but its rounds do not settle even when that growth is
  removed.
- `wa`/`wb` already settle on master in 6 / 7 walks. The divergence in 4d's report was on 5a's
  earlier branch.
- `pgrep -f` with a pattern also matches the shell loop that waits on it. Wait on a PID or a file.
