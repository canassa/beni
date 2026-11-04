## 2026-11-04 18:15 CET — Model records written in place in the Lean oracle

**What I did**

Slice 1 of #316. The ownership oracle (`proofs/ownership/`) gets record objects: `Ty.object`, the primitives `object`, `get` and `recordCopy`, and `Expr.assign` for `{ r | f = v }` written in place. Both interpreters and the checker hold an object as a one-slot array whose element is the record. The checker's update is a demand on the base's object: Known, Unescaped, Disjoint and Dead per field (`recordLiveCells`). The other walkers (the frozen checker, the aliasing and diagnostic interpreters, the shrinker, the falsifier, the bridge wire) read the new forms, and the bridge translator skips them. 28 probe programs check #316's three two-holder shapes and the other conditions with `#guard`s. No theorem changed; no form entered `FlatANF0`. The owner has one question: the hoist (`own-record-assign-q1`). Slices 2 and 3 are #1871 and #1872.

**What I learned**

- The box encoding (an object is `list [record fields]` at all three levels) made the change cheap. No constructor was added to `Observation`, `InPlaceSemantics.Value` or `Abstract`, so the 20 000 lines of flat-fragment proof needed only the object case in four representation lemmas.
- The update has to be an expression, not a primitive. Its Dead test reads the continuation's liveness per field, and `primitive` gets only the live cells; changing the `.prim` case of `inferExpr` would break `infer_primitive_equation` and its 38 uses.
- Disjoint for an update (§31.4 item 3) has no witness in this core. No finite type lets a field hold its own record except through a closure, and a closure that captures a record with a function field is a limit of the summaries.
- Without a hoist the oracle must refuse a later read of a written field. Its in-place run reads the new value there, and only a lowering makes that read old.
