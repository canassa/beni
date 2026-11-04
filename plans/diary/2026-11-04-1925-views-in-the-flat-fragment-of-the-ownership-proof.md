## 2026-11-04 19:25 CET — Views in the flat fragment of the ownership proof

### What I did

- Added `view` to the flat fragment of the Lean ownership proof (#169, part
  of #165), in three pull requests that build on each other.
- First, a heap typing in the flat relation (`FlatInvariant.heapKinds`): a
  map from arrays to source types. The representation types cannot tell a
  dictionary of `t` from a list of `{Int, t}` records, so without the map
  the relation could not prove that `dictRemove`, the one writer that
  shortens an array, never writes a linked array.
- Second, the link clauses in the relation: `links = []` became
  `linkClosed`, `push` and `set` became linked writes over the whole link
  component, and `dictInsert` and `dictRemove` stay plain writes through
  the heap typing. The new module `LinkedWriteRun.lean` proves that a
  linked write on a state with valid links succeeds, leaves the stored list
  in the written array, and changes only the link component.
  `LinkedWriteValid.lean` moved before the flat fragment in the import
  chain.
- Third, `FlatANF0.view` with `view_preserved`, the naming that names a
  view by its source's origins, the certificates over a sublist of the
  source's elements, and six probes.

### What I learned

- The flat relation types values at their representation, so a fact that
  needs the source type (a dictionary is never linked) needs a typing of
  the heap, not of the values. A map from arrays to types is shared by
  every binding and the result, so it also gives the bound on every array a
  dead binding reaches after a linked write, which one hole's contents
  could not give.
- The naming and the abstracts cannot carry the kind of an array: `shared`
  puts `.shared` on lists and dictionaries alike.
- `LinkClosed` in the relation is easier than `LinkNamed`: every case keeps
  it with the same naming or an extension at a fresh address, and the
  Dead, Disjoint and Unescaped tests reach the whole link component through
  it at once.
- A name in `rw [h]` rewrites the links field inside a structure literal
  too (`{cur with heap := h}` holds `links := cur.links`); match on
  `cur.links.find? ...` directly instead.
- `refine ih ...` takes the state from the first hypothesis it unifies
  with; name the state (`(cur := ...)`) when the hypothesis is a
  definitional variant.
