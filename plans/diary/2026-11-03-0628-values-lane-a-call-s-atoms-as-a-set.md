## 2026-11-03 06:28 CET — values lane: a call's atoms as a set

**What I did**

- A leaf of a call's result whose expansion ends at atoms now keeps them as
  a hash-consed Patricia set (`AtomSets.zig`, over the resolve lane's
  `KeySets.zig`, copied byte for byte). Once a check, after its first
  expansion, the distinct check asks whether it is decided: every live
  entry is an atom, a parameter's object or a call's leaf with a set, every
  call's group has vouched for its own objects, and no atom is named twice.
  The last is a membership query in the largest set, never a listing.
- CallChainShare `merge` is 297 / 319 records a call at 10 / 40 (was
  328 / 534), and `indep` is 366 / 387 (was 397 / 601). Both pass. build_test
  has 1 failure left (the fold certificate through a shared DAG).
- On the ledger, every summary is identical, with 0 a2r and 0 r2a. Cost
  table growth is 0 on every row. Oracle: no new TRAP or DIFF.
- I traced step 2 to its cause and wrote the design on #1714. I did not
  build it. Steps 3 and 4 are not started.

**What I learned**

- A set of atoms loses multiplicity. A leaf at a type variable's or an
  opaque slot can be one object more than once (#1710), so such a leaf must
  have no set. The first version said `nondup yes` for `Storage.keys`, and
  the ledger diff found it.
- Asking "is it decided" once per round in a check is quadratic: 50 calls in
  one list scanned 49 others each. Asking once per check, with the
  membership query against the largest set, keeps the overhead to tens of
  records. The cost is set records on checks that the rounds would finish
  cheaply: totals rise by 50 or fewer records on most accounts, and growth
  rises by 18 on one program's `want`.
- The fold certificate DAG is cubic in the leaves themselves, not only in
  the walk. `t_{j,i}` and `t_{j',i}` are mutually exclusive tag lists, so
  one leaf per (leaf, tag list) cannot be linear. The fix is a leaf that
  carries a route set into the keys. Its readers are mostly in the resolve
  lane's files.
- The profiler counts a record twice when `reserve` falls through to
  `reserveGrowth`. Read its figures as relative only.
