## 2026-10-23 13:30 CEST — records are written in place (R6 of #315)

**What I did.** A module checked under enforcement whose every demand was accepted now has a clean
hoist table, and `Lower` writes each of its record updates in place: the base and the values in
written order, the reads the table hoists (`placeHoists`, `hoistedRead`), then `b.f = t`. The
hidden, development-only `--sanitize-records` gives each version its own object and makes the
old object's written fields throw. `.in-place` fixtures (`run/RecordHoistValues` and the new
`run/RecordInPlaceValues`, both from the seeded generator) are built twice more in the gates, as
shipped and under the sanitiser; `zig build test-records-in-place` does it for every `run/`
program, and all print their goldens. The `wrong-placement` control is trapped by the sanitiser.
`./rr check` passes on `unique-components` and `big-component` (`--lists none`, N 1–256, seeds 1–3).

**What I learned.** Placements are BIR instructions that lowering meets by many routes: an
expression, a tail statement, a `let` item, a `let`-bound lambda, and a markup `For` row, whose
functions the markup lowering writes without going through the lambda's instruction. A read
lowered before its placement is the bug to watch for, so it panics instead of emitting the old
access; the panic found the `For` row on the first sweep of every program under
`--ownership-everywhere`. Stores as `assign_stmt`s made §9's optimiser barrier free: its
ordering rule already treats an assignment as a write.
