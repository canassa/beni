## 2026-11-21 08:56 CET — v3: a failed `?` answers at the frame's own type

**What I did**

- Lane fix171, a fix lane of v3's cells and fibers, for #2595 (blind round BB): a safe build panicked
  in `Frame.checkPlaced` from `Frame.finish` on a `?` in a function that answers a cell inside a
  `Maybe` or a `Result`, when the operand is a `Maybe`/`Result` of another type.
- Cause: a failed `?` put the whole operand into the frame's answers, which `finish` reads at the
  answer's layout. The operand's success part (a list) sat at the answer's cell handle, and the
  contents below the handle had no location in the operand. `Frame.tryFailure` now builds the
  failure at the frame's answer place (`answer_place`, set before each body walk): `Nothing` holds
  nothing, and `Err e` holds the operand's `e` at the answer's `Err`. Equal layouts keep the old
  value. Kernel §13's walk list, item 6.
- Paths checked: the `?` failure (the only value of another type that enters `returns`); the end of
  the body and `case` arms (the answer's own type); `writersAtReturn` and `revokeWriters` (read at
  the value's own layout); `noteReturnCells` and `publishRenew` (a parameter's own place); local
  functions and lambdas (`solveCodes`); `walkHeld` and `walkExported` (no body answer).
- `run/CellTryAnswer` (accepted) and `run/CellTryAnswerLive` (refused, each write), both panic
  before; a payload-dropping mutant turns the live twin's `Err` read into a TRAP. `cells.mjs` gets
  the `try.` family (400 programs; base 80 crashes, fix 0; the ownSupply mutant 80 traps).
- Dumps of all 2 500 roots: no verdict change outside the two fixtures; answers of `core`,
  `bench/corpus` and three `run/` programs lose sources the operand's success part put there, and a
  module of `platforms/browser` no longer passes its work limit. Ledger 309 of 319. Dump-diff of
  every sweep (127 909 programs): only the `try.` family and five corpus programs changed; all of
  them SAME or REFUSED under the four legs. v3 on the real roots 1 812 → 1 759 ms. One reviewer
  found nothing.

**What I learned**

- `leavesSet`'s other-layout reading is for one type read two ways. A value of another type in the
  answers is not a reading; it is a value that must be rebuilt at the answer's place.
- The same mismatch was silent where the layouts happened to line up (a `Dict` operand read as a
  cell): a wrong claim, not a crash. A dump diff of the roots shows such fixes as precision.
