## 2026-10-24 04:49 CEST — Lean: arrays of flat values in the flat fragment (#522 slice 2b)

**What I did**

- `FlatType.list t` takes an `ElementType t` (an integer, a record of element types or a list of element types); `FlatAbstract.list` holds no unknown root; `AllocatedFlatValue.list root ws t` types its elements; the literal builds a list of any element type.
- The invariant types and shapes a binding at its live paths and bounds the arrays of every binding. The write step and the array-types clause of the design note are gone: a dead alias of a written array keeps no type.
- Every list form over values. The first proved exclusivity certificate: after a push, a set, a prepend or a literal, the `deep` and `spine` bits of the new list follow from `storeExclusive` and `storeSpines` through the naming.
- Five probe programs on lists of lists and a list of records.
- #932 for lists of results and chains (an element's tags need an invariant clause). The finding and the two departures from the plan are on #522.

**What I learned**

- A per-live-path typing clause removes a whole family of obligations. Typing every binding, dead aliases included, needs agreement between the element types of every two bindings that reach one array, and that agreement needs its own conclusion in every case theorem. Typing only the live paths needs nothing: a live path does not reach the written array.
- A slice that widens a type must also widen a constructor of that type, or no program reaches the new theorems. The plan deferred the nested literal; without it the slice was vacuous.
- `List.count` reasoning over footprints: the count of a container array in a list's footprint is the sum over the elements, one element holds it once (the unique-path bound `count_le_one_of_container_unique`) and the others not at all (the store tests). The index-based `separatedPaths` is stronger than a pairwise relation by value, since equal entries at distinct indices fail it.
- Lean: `Bool.and_eq_true` is an equation, `Bool.and_eq_true_iff` the iff; `by_contra` is Mathlib (`Classical.byContradiction`); a lemma instance passed to `simp` must name the exact state (`valueTicked vs` and `{vs with fuel := vs.fuel - 1}` both); `<+` is `List`-scoped.
