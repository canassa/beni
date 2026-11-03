## 2026-11-03 11:04 CET — own2: holes through lambdas and row callbacks

**What I did**

- Fixed four slot-domain soundness holes on `own2-holes-r2`, rebased onto `own2-final`. Each has a refused
  sanitiser fixture, an accepted twin and an in-place spec amendment.
  - #1758, a captured closure called by a closure. A capture label's site type now comes from its origin call. A
    known code read as unknown escapes at that call. A write relies on every label it is supplied through, outward
    (`Eval.supplyLevels`).
  - #1760. `List.update`'s taken mark survives a label passed on inside a lambda that the taken label runs.
  - #1721, the lambda variant. A label passed on inside a lambda takes its outer labels' count, conditions and
    kept slots. A fold's `fed` is read through the forwarding lambda.
  - #1759. An `aliased` row callback is a label whose answer reaches every result slot, so `Task.timeout`'s
    `Just` holds the work's answer.
- Oracle: 1 049 probes, 0 TRAP, 0 DIFF. Ledger vs `own2-final`: a2r 0, r2a 0. Cost growth unchanged.

**What I learned**

- The four holes share one cause. A callback called **inside** a lambda lost what the outer label knew: its type,
  count, marks, conditions and kept slots. The label chain (virtual call → `virtualOuter` → …) is the one place
  to recover all of it.
- An outer label's condition cannot be added blindly. A fold's `fed` occurrence asked of a forwarding lambda is
  `no` unless `Fed.at` reads a passed-on label's answer as `fed` of that label.
- A worded row's label origins are synthetic offsets (0, 1, 2, `taken`). Code that reads an origin as an
  instruction must check that the declaration is walked.
- The full gate was not run. `ownership/CapturedParam` fails on the base from a stale known list.
