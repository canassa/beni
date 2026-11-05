## 2026-11-05 05:59 CET — answer the adversarial review of #1954

**What I did**

- Fixed the review's soundness hole: a helper passing `List.update`'s callback on over tuple elements was accepted, and the sanitised run trapped. The cause was not the pass jobs in `Resolve`. It was `RowEnv.takenOccs`, which read the `taken` row's condition off the supply's root. A supply passed on by structure names only a tuple's parts at its root, or nothing. Now the condition asks every parameter arrival of the supply deep and apart, and asks the written slot plain from the deepest entry on its path. Spec amended after the #1760 paragraph. Fixtures: `run/SanitiserPassedTupleRow` (refused, six shapes) and `run/SanitiserPassedTupleRowApart` (accepted).
- Restored the five size targets to master's values. `Ancestry` is split from `Liveness` into a new L6 file. The unused `Chunks`, `Tasks` and five ids are cut from `Ids`. Dumps are byte-identical on all 2 259 ledger roots.
- Evidence: oracle of 1 425 probes, 14 TRAP on the head, 0 TRAP and 0 DIFF after. Ledger a2r: only the 6 fixture positions vs the head, and nothing new vs master's v2. Cost table unchanged. Reply on the PR; v1's own copy of the hole filed as #1959.

**What I learned**

- The hole was wider than tuples: constructors, `Maybe`, three-tuples and a lambda that swaps the parts trapped too. Any element with no object of its own has this supply shape.
- v1 (the shipped checker) traps on the forwarding-lambda shape as well.
- Virtual demands were named from the shortest prefix, which gave a garbage path for tuple supplies. Naming from the longest prefix also matches v1's names.
