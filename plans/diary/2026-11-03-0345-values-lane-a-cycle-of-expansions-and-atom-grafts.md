## 2026-11-03 03:45 CET — values lane: a cycle of expansions, a mechanical spelling check, atom grafts

**What I did**

- **A runaway (manager, high priority).** After the precision lane fixed #1745, `bench/corpus`'s `groupOrder` ran past an allowance of 10⁹. The cause was not `Routes.anyPair`. It was a cycle of expansions in `Distinct.distinct`: the fold's supply of `acc` expands to the step's answer, and the answer expands back to the supply. One new entry each round, with the atom's whole group read again, until the 4 096-round bound. Fix: an expansion's leaf that is on the entry's own `par` chain is not made an entry (the least fixpoint, charged one record a step). The fixture is `ownership/FoldSupplyCycle`. `groupOrder` costs 3 528. Controls that answer one list twice stay refused.
- **Step 0.** A hidden `--ownership-below` dump: each summary's parameter slots, each with its own `below` by index. With it, `covsum.mjs` reads a deep occurrence and its written-out spelling as one set. All 373 changed summaries are covered: 9 are #1748's `⇐ sel` → `no`, and every other one is equal.
- **Step 1.** `AtomGraft.zig`: where a settled callee says only atoms at and below a call's slot, the read-off grafts the callee's node instead of reading item by item. Each tree node has an "atoms only" bit, so the test costs nothing at a call's root. A cycle check guards the naming. `shapesOf`'s growth went from 5 622 to 3 119, every summary is identical, and no other row moved.
- **Not done:** steps 2 (CallChainShare, the `ident` control, the fold certificate), 3 (`meetRun`) and 4 (`described*` +11).

**What I learned**

- With `⟲` names, `below(p)` is not the slots whose names start with `p`: `below(#0.1[*]#0.1)` holds `#0.1[*]⟲#0.0`. A script that checks spellings needs each slot's own `below`. `Cond.weakerIn` uses the prefix rule as well, which is conservative but is the same blind spot.
- A node.js child's stdout read chunk by chunk splits UTF-8 code points into U+FFFD. Two core summaries "differed" for that reason only. Set the stream encoding.
- Any extra record on a test that fails shows as +1/+2 growth on `fieldList`, `boxOf` and the other rows. A per-node bit made with the node is what keeps a fast path free where it does not apply.
- The `ident` control's cost is the written-out res (#1715: small cyclic subtrees are written out). Each entry is instantiated at each call. A call whose callee is the identity on a parameter would have to return the argument's value. The walk builds call roots before contracts are known, so this needs a design step, not a patch.
- `shapesOf`'s remaining growth is in the rounds where `shapeOf` (one group with `shapesOf`) is a live draft. A graft there must keep the solver's deliveries.
