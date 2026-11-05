## 2026-11-05 17:25 CET — A called contract for a returned closure

**What I did.** Closed #2028, #2029 and #2030 on `own2-fn-values`. A function slot of a declaration's result now has a
*called contract* `D@s`: a second walk of the body that ends in a call of the value at `s`, read off for that last call
only. Its parameters are the function's own, `D`'s, and `self`, the value. What the creation made is `self`, deep: what
the value holds. At a caller a value that is a call's result at such a slot is a closure of that code, so the existing
code-call and virtual-call machinery does the rest. `r.f x` on a record field is a call of the field's value. Blocks go to
version 23. §2.11.3 has the design and the soundness argument, and Appendix B's `ClosureTower` row is restated. Several
files were at their size targets, so `Once`, `CondsOff`, `CodeCaps`, `TypeVarParam` and `Construction` were split out.

**What I learned.** The brief's shape (a result arrival naming the code, with arrivals for its captures) has no finite
form on `grow`, whose capture is its own result, and doubles on `ClosureTower`; each fold would need its own soundness
argument. Closing the captures over `D`'s parameters and `self` is that fold, and it costs one more walk a function slot.
The tower is flat at 939 records a level, with no limit to trip. A sentinel bit me: `last.calls == 0` also describes a
called code with no creation calls, so `w0` read `fresh` for the list it made and `run/ClosureTower` was accepted for
one build. The gate caught it through the v1 comparison. A closure's writes stay refused where it leaves `D`, which is
what makes this only an answer's precision; reaching writers is #2039's neighbour, not this work.
