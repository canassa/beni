## 2026-11-02 22:33 CET — own2: the loan rule at cell callbacks

**What I did** (#1729, part of #1685; branch `own2-ref-loans` on `own2-ref-once`)

- A `Ref.update`/`Ref.modify` callback is now a label of the row: called once, its one supply `π1◆` slot for
  slot, kept by nothing (`Rows.fromWords`). Before, it escaped as unknown code, so every edit it made in place was
  refused `unknown (approx)` and no loan was ever consulted. Now the edit is a callsite demand on the contents: a
  live `Ref.get`/`Ref.modify` loan (or a record or closure holding one) refuses it by name, and with none live it
  is accepted `callback-param`.
- The edit is deep at `π1◆` (`writes π1◆*`), so it is never a cell operation: `bump r` with a live loan is refused
  at the call, and a closure that makes the edit stays `once` (§2.11.4 amended: the #1727 sentence "however often
  the closure runs" was unsound, see below).
- The barrier in holders: a hold whose path steps through `◆` is no holder of the contents (`Cells.behindCell`, one
  line in `Resolve`'s Dead loop). Without it, the handle's own later use refused every edit.
- What the callback stores back: at a slot where something other than the supply or a fresh object arrives (a
  capture, a top-level value, an unknown or passed-on answer), the contents there escape at the call
  (`Eval.cellAnswer`), so a later edit in place is refused `escaped`.
- A cell operation's target is a `◆` position also where the projection names the cell by a slot below it, so an
  escape of the contents (now possible) never refuses a cell operation.
- The cell helpers moved from `Eval` to a new L7 file `Cells.zig` (Eval was 83 lines over its target; no target
  raised; §5 table and `rules_test` list it).
- Harness: under v2, an accepted `callback-param` line is a callsite demand, not a list write, so
  `checkSanitisedSites` skips it (v1 unchanged).
- Fixtures: `run/SanitiserCellLoan` (8 refusals: direct, modify loan, record, closure, record field, callee, stored
  capture, another cell's loan) and `run/SanitiserCellEdit` (the twins, accepted, sanitised run prints the same;
  its `List.map` closure with a cell op fails the old harness). `SanitiserCellCaptureList`'s refusals moved to the
  `once` closure.

**What I learned**

- The `once` exemption for contents edits would be unsound: `List.map [1,2] λk → (Ref.update r push; Ref.get r)`
  (an earlier run's answer is a loan) and a `Task.forever` fiber editing a cell that `main` loans across a sleep
  both trap under the sanitiser when it is exempted (`loan/once/`). Loans across suspensions are not checked by v2
  at all; Esc going through `◆` and `once` are what protect them today.
- Without the taint of stored answers, `Ref.update r λ_ → ys` then an edit in place traps: v2 keeps no slot state,
  so the supply names the cell's first contents, not `ys`.
- Loans are `⊤` in v2: a live loan of any cell refuses any edit, and a `Ref.get` result kept live refuses unrelated
  list writes too. That precision gap is old and is not this slice's.
- A `.beni-cache` left in `tests/corpus/run` by a stray build there is a corpus failure of its own.
