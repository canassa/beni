## 2026-10-18 19:13 CEST — Add field atoms and records to the flat fragment

**What I did**

- Widened the flat fragment (`proofs/ownership/Ownership/FlatFragment/`, #165): `FlatANF0` now admits every atom (an integer, a variable, or a variable under a field path) where it admitted an integer or a variable, except the push receiver, and it contains the record constructor. A binding holds an integer, an integer list, or a record of such values, nested.
- `FlatType`, `FlatAbstract` and `AllocatedFlatValue` got a record constructor, indexed field by field. The two clauses `types` and `abstractShapes` keep their names; `heapInts` and `links = []` stay.
- New module `Fields.lean` between `Reach` and `Frame`: `atomRoot`, `tyAt`, the evaluation of an atom from its root binding on both sides and in the checker, records in `Corresponds`, `obsTyped`, `ValueTyped` and `Describes` field by field, the frame of a flat value by induction on its structure, the cells at a path, and the atom lemmas under the invariant. Three `cellsAt` lemmas moved here from `CallDerivation`, which imports the chain.
- `flatInvariant_bind` takes typed live paths instead of empty ones; the heap frame's separation hypothesis speaks of every array at every path of a live projected value; the push case discharges it through `inv.named` and the live cells.
- The `shared` case handles a value deeper than `observationDepth`: both interpreters fail at the observer epilogue (`shared_deep_failure`).
- Probe `recordOps` in `Trace.lean`; README, COVERAGE and PROOF-PLAN record the slice as built.

**What I learned**

- `Atom` has exactly three constructors, so a separate "flat path" predicate was redundant: typing alone refuses an integer under a field.
- The old `FlatLive` lemma (every live path is empty) was the one place the fragment leaned on the absence of records. Its replacement is a typing fact about uses, derived from the expression's own `exprType` run.
- A frame lemma by structural induction on the value is shorter than the integer-or-array case split it replaces, and the root's name comes from the old `Describes` itself (`Covers` at the empty path), so no invariant clause is needed inside the induction.
- The observer epilogue checks depth on the value side (`observable`), so a deep record shared is a both-fail case, not a divergence. The first fragment never met it because its values were shallow.
- Draft modules compiled with one `lean` run against the branch's oleans found every proof error in about a minute each; the ten-minute `lake build` then met only ordering and `open` slips.
