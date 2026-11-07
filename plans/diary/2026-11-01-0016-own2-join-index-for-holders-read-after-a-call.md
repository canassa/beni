## 2026-11-01 00:16 CET — own2: a join index for holders read after a call

**What I did**

- #1510. A holder still used after its demands (`incAll v`, then `ignore v`) read its value's closure once per
  target. Each read walked an `else if` chain down to the target's arm, and the `coverNaive` fallback walked it
  again with `holdsAll`. That cost Θ(D²) demand records.
- Added `src/own2/Joins.zig` (L5). A node whose closure walk entered more than 16 records is *deep*. Its joins at its
  path are flattened once: each member with its route-flag combinations, a balanced tree of reach unions over the
  nodes, deltas and lazy records, and the other members' cells folded into two sets by the hold they give.
  `Holders.closure` and `holdsAll` read a deep node from the index. A node whose joins meet a view keeps the walk:
  the walk forces each view it enters, and another force order would number the answers' nodes differently.
- The lemma is in `ownership-v2.md` §2.8 *As built*, *The join index*. Under runtime safety each indexed closure is
  compared with the walk on a fresh memo and account, and each indexed hold listing with the walk's.
- Demand records of the issue's program at D = 8 / 16 / 32 / 64: 1 676 / 3 994 / 11 099 / 34 837 →
  1 704 / 3 299 / 6 748 / 13 914. With `chosen`'s arms: 1 146 / 2 610 / 7 028 / 21 647 →
  1 214 / 2 265 / 4 544 / 9 337. Added a counted test in `build_test` (`chosen`'s arms, 0.67 s on the safe build;
  the issue's arms take 0.9 s). With the index switched off, the test fails with master's numbers.
- All 2 113 roots of `bench/ownership-roots.mjs`: 0 differ from master, `account` and `crossing` lines left out.
  This holds on the real build and on a build that indexes every node. That second build read 8 426 indexed
  closures and 4 914 indexed hold frames, all checked against the walk.
- Added `bench/ownership-cover-oracle.mjs`. It generates probes (chains, literals, nested positions, `rest` views,
  call results, and holders or `k` read after the call). It runs each probe in a small interpreter with copy
  semantics, and again with in-place writes where the call's verdict is accepted. At 1 000 probes: 159 accepted,
  0 unsafe runs among them. With every verdict forced to accepted, 1 243 of 5 001 runs differ. The branch's dumps
  are byte-identical with master's.

**What I learned**

- On the real threshold, no corpus root and no oracle probe makes a node deep. Only the build that indexes every
  node exercises the index widely, so that build is what the identity claim rests on.
- The index must not change which views are forced or in what order. A force numbers new nodes, and
  `Shape.answerOf` (the presence walk, `mapSource`) reads whether a view was forced. Leaving segments with a view to
  the walk keeps every side effect the walk's.
- The tests' `incAll` diverges at run time: it recurses into the `Rose []` it pushes. The oracle uses a `Leaf`
  constructor for the pushed value.
- In a refused call the per-path verdicts can accept a deeper path that a later read reaches: `w = v`, then
  `( incAll v, size w )` accepts `v#Rose.0[*]⟨Rose⟩#Rose.0` as `fresh`, while `w` reads it. The call is refused at
  the shallower paths, so nothing runs. This is the same on master.
