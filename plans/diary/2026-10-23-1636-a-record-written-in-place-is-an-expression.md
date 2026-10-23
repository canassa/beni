## 2026-10-23 16:36 CEST — a record written in place is an expression again (#889)

**What I did.** Since R6 and R7 of #315 an accepted record update lowered to statements, so every
update helper became a block body, `a=>{a.b=4;return a}`, and slice 8 of the specialiser stopped
writing it in at its call. S1 grew by about 9 B/widget. The update is now an expression wherever
its spread was one: `(b.f = v, …, b)`, built from two new `JsIr` expression tags, `assign` and
`sequence` (`ownership-checker.md` §31.10, *The form*, amended). `Lower.recordUpdateInPlace` binds a
value to a temporary only when a store could come between it and a later value that reads memory,
and puts a literal's store last, which needs no temporary. Where a statement can stand before the
update (a binding, a handler's arm, a value bound to a temporary), `Lower.settleStores` writes the
stores as statements and keeps the object. The printer writes `t = (s, v)` as `s, t = v` when `t` is
a name or a property of one.

Every pass that walks `JsIr` handles the two tags. In `Opt`, a store is a write (`mayWriteIn`), and
a binding or a discarded statement that holds a store is never dropped (`JsIr.holdsStore`). A
single-use binding of a name is now folded past a write of a property of that name. In `Spec`, a
store's target is no read: `patchStmt` does not fold it, and the copy writes neither a projection
nor a known value in its place. Facts 3, 4 and 5 join what the store writes (`Pts.combineNow`,
`Spec.combine`, the extractor's `store`). A store's value is never a literal (`Op.effect`), and an
object written in place is never scalar-replaced (`NameUse.in_place`). `returnExpr` reads
`o.f = v; return R` as `(o.f = v, R)`. The tidy pass splits `const x = (s, v)` into `s; const x = v`.

S1 (n16 s1, brotli): 6849 before R6, 7061 on master, 6790 now. n256: 62212, 64539, 61094. The
corpus harness builds each `.in-place` fixture a third time, as a release ships it
(`release-stores`). `zig build test-records-in-place` therefore runs the specialiser over every `run/`
program written in place.

**What I learned.** That third pass found two of my own defects that every golden missed:
- `patchStmt` folded a store's target as a read (`"walk"="stroll"`).
- The new name fold took a name's substituted member read past a call. Only a run hash moved, in
  `run/CustomEqTupleHead`, whose answer was still right.

A new expression node is cheap in the printer and expensive in the specialiser. Every walker there
that classifies a `member` as a read has to be told about a target. A run-hash diff on a fixture
that has nothing to do with the change is a finding, even when every test passes.
