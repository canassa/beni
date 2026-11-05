## 2026-11-05 01:10 CET — Record objects written in place in the flat fragment

**What I did**

I put the four record forms of #316 into the Lean oracle's flat fragment and proved them (#1871): `object`, `get`, `recordCopy` and the update `Expr.assign` are in `FlatANF0`, and `flat_preserved` proves each one in the new module `FlatFragment/Objects.lean`. `FlatType`, `FlatAbstract`, `AllocatedFlatValue` and the heap typing have a record object: a one-slot array whose slot is a record. The flat relation has three new clauses: `observationsTyped`, `objectsCertified` (the certificate of an object over the fields that a live use reads through its slot) and `liveTags`. The heap frame takes a new premise, `projected`: every live projection reads the same value in the next heap. Eleven probes in `FlatFragment/Trace.lean` get trace theorems from `accepted_flat_anf_traces_agree`, and seven refused controls show differing runs. The statements of `accepted_flat_anf_traces_agree` and `accepted_traces_agree` did not change, and the pinned `sorryAx` set did not change.

**What I learned**

- No `Invariant` could hold while a field read of a bound object was still to come. `Invariant.bindings` read live paths with `projectVal`, which stops at an `.element` step, and `fieldUses` gives a field read the path `p ++ [.element, .field f]`. Cesar chose to fix the relation (`own-record-flat-q1`, option A). The dashboard first filed his answer under another question id.
- The first fix read through any one-element array. Cesar's answer asked for a record object's one slot only, and a one-element list of integers passed that first fix. The projection now reads only an array `[.record xs]`. The heap cannot tell a one-record list from an object; the typing can, because `tyAt` takes `.element` only at `Ty.object`.
- An update's result keeps the old certificate over the kept fields. The relation had no fact for that: a description of the whole old object is false after the write, and a join of `object [xs, ys]` with `object [ys, xs]` has exclusive abstracts with overlapping fields. So the certificate went into the relation as `objectsCertified`, over the live fields only.
- The update's kept fields frame without `live_path_apart`. A live path through the written array goes into a kept field (the Dead test per field), and `assignFields` keeps that field's value.
- After a change to `projectHeap`, a match on a one-element list has to name every value constructor: Lean does not reduce the catch-all arm while the head is unknown, so `rfl` fails on `a :: b :: t` until `cases a`.
