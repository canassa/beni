## 2026-10-31 15:40 CET — own2: a join's sides, not the join, as ⟲ re-entries

**What I did.** I fixed the re-review findings on PR #1469 (#1439).

- **The false refusals.** `frontierMax` counts written positions per arm. It walks a join's sides as edges. Under a `⟲` it then took a `positions` node and its sides both as re-entries. So in `Rose [ Rose [ Rose [], Rose [] ] ]`, behind an `if`, each inner `[]` had two routes in one arm: once from its own `Rose []`, and once from the join's projection. Two routes made it another path. A join or a view is no longer a re-entry by itself: its sides or its answer are. The reviewer guessed that the two `Rose []` shared a node. They do not: the cells are distinct, and the double count came from the join.
- **Parameter arms.** `keptAll` kept every parameter cell whatever its run. It now keeps one only where an end of the write's path reaches it in a run that the node shares, as for any other cell. `swap`, `same`, `nestp` and their pair-of-pairs twins are accepted again, and `both` is still refused.
- **The read node's edge.** The `defer` that sets `.from` no longer overwrites a read state's own node.
- **Fixtures.** `twoLeaves`, `leafBesideK`, `leafBesideKTwice` and `sameArms` go in `ChoiceArmsApart` and its imported twin. `ChoiceArmsParams` has a `.v2.ownership`. All of them fail on the previous head.
- **Sweeps.** I wrote a random generator of `Rose` and `B` programs: lets, shared values, `if`s on two conditions, and `incAll` on the result. A concrete oracle evaluates every condition assignment, and calls a program unsafe if a written list is at two or more positions. Over 8 000 `Rose` and 8 000 `B` programs, the first head and this head agree on every program, and neither accepts an unsafe one (300 and 788 unsafe programs). The same sweep finds 15 of 2 000 `Rose` programs where the previous head refused what the first head accepted, so it has the power to catch this bug.
- **Corpus.** The first head and this head give the same verdict on every demand of all 2 047 roots.

**What I learned.** Treating a join as transparent in one walk (routes) means treating it as transparent everywhere that walk picks nodes out. Here that was the re-entries of a `⟲`.
