# `tests/corpus/dispatch/`

One `.beni` and one `.dispatch` golden each: the fixture must `check` clean,
and `dump --stage=dispatch` on it must equal the golden
(`docs/design/static-dispatch-spike.md` §7.3).

This kind exists for the reason `bir/` does. The dispatch table is the
checker's answer to "which function does this method call call?", and it is
the only place that answer is visible: a call resolved to the wrong function
type-checks exactly as well as the right one, so `--stage=types` and
`--stage=interface` cannot see the mistake and a `run/` fixture can only see
it once S4 and S5 emit the call. A golden here is the contract those two
slices lower against.

The format carries **no symbol ids, no positions and no module indices** —
every name is text — so reformatting a fixture leaves its golden untouched
and `--jobs` cannot move a byte. `site` lines are sorted by
`(inst, evidence_index)` and `derived` lines by the emitted name text, both
before anything indexes them (§7.1, A.29).

Both halves of a fixture matter. The `check` must be clean because a table
describing a program the compiler rejected describes nothing; the golden is
what says the table is right.

Bless with `BENI_WRITE_EXPECTED=1 zig build test-blackbox`, and read the
blessed golden against the fixture's intent comment before committing it —
a wrong golden here pins a wrong call.

## What each fixture is for

`MethodCall` and `Evidence` are §7.3's two worked examples. `Primitives` is
§3.2's table, one row per core type. `DerivedShapes` pins the shape key and
the emission-order sort; `DerivedShapesDistinctElements` pins that the
evidence is per USE and not per function (A.46) — with shape-keyed evidence
its second `t2` site loses its own `part` lines and orders strings with
JavaScript `<`. `ErrParts` is the `err` target — what a clean program makes
one for, and what `Lower.structuralEq` may assume when it reads one.
`AllNullaryEq` is A.18, `UserMethodWins` §3.3 step 1 and
`PrivateEqStillDerives` the half of that step a `pub` makes the difference to — a private `eq`
wins inside its own module and still leaves the derived row every dependent names (A.63),
`FieldCall` the `field` target S4 must keep, `ImportedMethod` the `ext` and
`ext_derived` targets across a module boundary, `ExtWithParts` §7.1's
amendment — an `ext` in a PART position carries its own evidence range, so
`Boxes.eq`, which takes one hidden argument, is not called one short
(A.64) — and `core/ForeignWithWhere` a `pub foreign` with a `where` clause
(§5.2, A.7), which has no body and so never reaches a binding group.
`NestedEvidenceIndices` is §7.2's other half of that amendment: the slots of
ONE instruction each have their own `evidence_index` however deep the
instantiation nests (A.68). It is the only fixture that can see it — the
emitted JavaScript is the same either way, because the walk reads the order
and not the numbers, and what a repeated index threatens is the two places
that deduplicate on `(inst, evidence_index)`.
