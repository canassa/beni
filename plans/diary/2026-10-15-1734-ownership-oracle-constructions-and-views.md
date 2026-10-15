# 2026-10-15 17:34 CEST — Constructions and views in the ownership oracle

## What I did

Answered the oracle review's conditions C1, C2 and C5. The Lean core gained
`construct` (a `++` chain or spread literal, base the first spread) and `view`
(a pattern's `…rest`/`…init`), in the checker and both interpreters. In place,
a construction writes its base's array from the base, left to right, and reads
later spreads while the base grows, so `xs ++ xs` never ends; a view is a heap
array kept equal to its source's suffix or prefix at every write, both ways.
Two new required holes (`construct-disjoint`, `view-alias`), 21 sync fixtures,
232 appended targeted programs, and an opt-in generator v6 that draws
constructions, views and record updates. The bridge translates all three (a
record of another record's fields prints as `{ r | f = y }`), translates
function-valued results with functions observed as `"<function>"`, and runs a
v6 stream beside v5. `bridge-mutants.mjs` now has the review's six edits plus a
construction one; the view, append and record holes the bridge missed are
caught, and every caught lead was judged by both interpreters. §26.7 lists the
writers, sends, re-cons, multi-item prepends, evidence `++` and record
assignment that stay unmodelled, and says what "zero confirmed" covers.

## What I learned

The long campaign found one confirmed unsafe program: a callee pushes what its
callback returns, the callback returns the callee's parameter, and the caller
reads its list afterwards. `returnsOwned`'s `.param` branch trusts the
callee-frame owned bit and demands nothing of the caller's argument. It is
pinned red in `tests/pending/check/bad/direct/` and the audit now fails only
on confirmed leads without such a fixture. It needed both C5 (a function in
the result) and v6's mix to surface.

A `++` in an unannotated declaration is generic (`appendable`), dispatched
through evidence, and the shipping checker treats it as an escaping
conservative call rather than a construction — the bridge must spell `++` only
where the operands are known lists, or it manufactures leads. `foldret` and
`keepshape` change no verdict anywhere; both are implied by a condition the
same code computes later, which is the argument recorded for them.
