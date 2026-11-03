## 2026-11-03 02:03 CET — Resolve lane: route-set projections, the holder's rest

**What I did**
- Reset `own2-cost-resolve` onto `own2-integrated` (`d4aa38289`, which holds my previous step). Base: build_test 15 failing; oracle over the 695 deduplicated probes has no TRAP or DIFF.
- Spec for the three walls of #1714, in place: route sets in a projection; write and `req` trees, the stop at a caller's parameter (one demand per state) and the exact fold of stored selections; judgements kept across a group's rounds.
- Built wall 2 in part. New `Routed.zig` (replaces `Paths.zig`): values are read in decreasing id, and arrivals at one value are united into a route set. The selection, a call's writes, a callee's reads at a use and a choice read deep all use it. New `Coexist.zig`: the exact meet of two sets.
- Result: "two positions of one image through a chain of n choices" flips (the `NoAccount` was `f` past its limit: exponential cost, not the harness). Ledger: no verdict and no summary changes.
- Fixed #1742: `Descent.holdsAt` asked a symbolic holder's rest against its own target, but `↓ε` keeps an excluded subtree. The rest is now asked apart. `browser/tea/ValuePath` 81:30 is accepted again. New fixture `ownership/HolderRestApart`.

**What I learned**
- The first version of the routed walk made every consumer slower: one charge an arrival, a set built for every arm, and quadratic `unite`. It became cheap after four changes:
  - an item keeps a plain tag list until a second arrival;
  - all arrivals are united once, when the item is read;
  - a one-route set stays a list;
  - written-out sets go into `anyPair`'s tail tree instead of being compared pairwise.
- A set walked from its earliest choices can drop every choice in the running list that comes before both remaining sets. That makes the meet of two chain-shaped sets polynomial.
- "Arms share a subtree" is no longer a projection problem. All of its growth is in `Leaves.arms`, which merges a shared tower once per arm. It needs a leaf-set node "set under a route set".
- The K-wide wall-1 test wants two demands, so the stop at a parameter is one demand per state, not one per subtree.
