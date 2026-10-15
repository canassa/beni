## 2026-10-12 02:49 CEST — ownership checker, slice 1: report mode

**What I did.** Wrote `docs/design/ownership-checker.md`, the normative contract for the in-compiler
ownership checker the thesis argues for, and built its first slice: an intra-procedural pass over
BIR in evaluation order, behind the hidden `beni dump --stage=ownership`, that prints one verdict
per demand (writer, spread construction, `++` chain). The one checker hook is `inst_type`, each
expression instruction's solved type, kept only when a dump keeps the stores. Added `List.copy`
(Change 2), the `ownership/` corpus kind with eleven fixtures, a `--jobs` determinism test, and
research 74, the first measurement.

**What I learned.** Within one function idiomatic code is clean: Conduit 15/15 and the table app
2/2 accepted; outside the list-runtime tests 20 of 352 demands are rejected, 14 of them as the full
checker would (top-level lists, identity promises, `xs ++ xs`, a lookup then insert). TodoMVC's
four rejections are all the thesis's own I5 case, which only a summary accepts. The real question
is now inter-procedural: 362 of 391 acceptances rest on a caller or callee. Two traps: a type
variable must not "share" with a type that contains it (an element is never its list), or every
`List.set` inside core looks like Disjoint; and adding a `pub copy` to `List` collides with three
locals of that name under the shadowing rule, so dev JavaScript and every source map of `List`
move — release output does not.
