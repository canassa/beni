## 2026-11-05 12:59 CET — The review of the taken supply

**What I did.** Answered #1981's adversarial review. Eight probes trapped through a traversal inside `Ref.update`, so a
write through a `◆` then a `[*]` that came through a traversal's element now relies on `no` (`CellEdit.zig`,
`Flags.many_write`, `run/SanitiserTakenElementCell`). A fold that reads its own list had regressed, so each supply now
has its own condition. The older defect, without a traversal, is #1986.

**What I learned.** My first entry's "0 TRAP, 0 DIFF" held only for probes that did not attack cells: the oracle has no
power over a route nobody wrote a probe for, and the ledger cannot see a shape no root has. A contract flag needs its
own line in `join` and `within`: `many_write` was silently lost at a round's join, and the symptom was a rule that
appeared not to fire. A row that moves from accepted to rejected at a caller is worth checking in the callee first:
`BallMachine`'s was the same program refused both ways.
