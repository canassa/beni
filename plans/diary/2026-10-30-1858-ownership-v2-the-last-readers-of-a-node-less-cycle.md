## 2026-10-30 18:58 CET — Ownership v2: the last readers of a node-less cycle

**What I did.** Fixed #1335, before S3b slice 4. #1336 gave `cellsOf` and
`namedSteps` the least fixed point of a cycle with no `node` on it
(`Shape.cycleWalk`). Three readers still looped or refused on it:

- `Holders`' same-path closure now runs on `cycleWalk`. A record alone is
  computed as before, with the same charges and the same order of states. A
  cycle starts each member from its own hold and children, and then adds
  its sides' closures under their route flags until none grows. `under`
  only sets flags, so this ends. A `runtime_safety` build asserts that each
  member holds what it reads. `Holders.closureOf` is a frame-free read of
  the closure, for the test.
- `Cond.foldCondWalk` runs on `cycleWalk` too. A cycle of unions and views
  gives every member the conjunction of what every member owns and what
  enters the cycle. The charges on acyclic DAGs are unchanged: one per look,
  and one more for a record that waited.
- The block codec writes the cycle, and does not close it through a node. A
  node is a built value with its own cells, so closing through one would
  publish another value. The writer's knot order lets a member name an open
  member. The reader ties every member that names an unfinished member raw
  (`Shape.knot`), sets the parts when the knot is whole, checks them as the
  constructors do, and settles the cells with `cellsOf`. A cycle that
  nothing enters (`recast(x)` of `x`) is still refused on both sides
  (`Block.entered`), so the existing "a knot's member may name itself by a
  child step and by nothing else" test keeps its meaning. Block version 13.
  §2.11 and §3.6 state it, and the §5 size targets grew for four files.

Three tests, each fails on master (`OwnershipLimit` for the two readers,
`AccountingInvariant` for the codec): a Calls test of Holders' closure on a
knot view, a Cond test on a union/view-only cycle, and a BlockRead round
trip of `u` and of its mapped view. The round trip compares the printed
class, the re-written words, and the cells and κ at the root and at `[*]`.
The verdict diff (`--diff=v1,v2 --same`, 1 937 roots) is byte for byte the
same for the master binary and the branch binary.

**What I learned.** A strict-part cycle can enter the block's knot order
without an extra pass: the post-order already gives a canonical order. The
only new rule is to tie the members that read an unfinished member. The
diff takes about 90 s per binary on this machine.
