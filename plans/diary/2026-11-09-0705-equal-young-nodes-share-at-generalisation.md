## 2026-11-09 07:05 CET — Equal young nodes share at generalisation

**What I did**

- Measured #2034 on master (ReleaseFast): the unannotated tuple form of
  `CallbackWrapperDag` took 0.22 s and 208 MB at depth 18, 3.3 s and 723 MB at
  depth 20.
- Callgrind at depth 16 named five walks: `Instantiate.copy`,
  `Generalize.adjustRanks`, `TypeKeys.build`, `Walk.Occurs.check` and
  `EffectsSummary.schemeNodes`. Each one marks a root once. The node count was
  the cause: each use of a scheme is a copy, so the type of `wk` had
  2^(k+1) − 1 tuple nodes.
- Added `Generalize.share` before `quantify`: equal young nodes (same head,
  same child roots) become one node, children first. A variable, an `err`, a
  function and a function-holding application keep their own node. A directed
  link, `TypeStore.share`, keeps the keyed root a root.
- Wrote `checker-v2.md` §38 and a pointer in §8.4.
- Raised the gate test of the tuple form from depth 10 to 24, and added a
  `test-perf` scenario (depth 12 against 24).
- Filed #2356: the `pub` form of the same program is exponential in
  `src/own/`, on master too.

**What I learned**

- All the checker's walks were already linear in nodes. A doubling program
  defeats them only through the node count, so the fix belongs where the
  nodes are made final (generalisation), not in each walk.
- An effect class is keyed by the node of a function type. A sharing pass
  must leave those nodes alone, or two functions of one shape share one class.
- The private and the `pub` forms of one generator have different costs: the
  `pub` form spends 97% in ownership v1. A test of the private form does not
  cover that pass.
