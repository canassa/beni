## 2026-11-21 19:23 CET — v3: cells written in arms, at their place, stored before a switch

**What I did**

- Lane prec172, the first precision lane of v3's cells and fibers. Base cb0b57f8e1.
- #2594 (a): a cell written in one arm of an `if`/`case` and read after it was refused. An
  arm's join kept its context only while a write was judged; a call's answer or a version made
  of the join lost it. Each atom found through an arm now keeps the arm (`Atom.ctx`), and the
  later-read test passes over an atom of another arm of the write's `case`. The plain-list twin
  (`ys = if c then List.set xs 0 7 else xs` read through `idl ys`) had the same refusal.
- #2594 (b), #2580 item 1: a callee's type variable read at the same place took every cell
  below it, so `Ref.make [ [ 1 ] ]` held the inner list at the outer place and a helper that
  writes a cell's list and its elements was refused `disjoint`. A cell's row now reads the
  part at its place (`Contract.cell_row`, `paired_exact`), and a cell's callback runs once
  (`Fn.once`).
- #2594 (c): only `Basics.and`/`Basics.or` may skip a later argument (`shortCircuits`).
- #2592: what a body stored in a parameter's or capture's cell no longer escapes at a switch
  point. The body notes it, a later write of it in place puts `flag_p` on the handle, and the
  holder judges (`parkedHeld`): another operand of the call, a shared handle or an unfollowed
  one refuses; a parameter's or capture's handle passes the flag up. A body that parks with a
  stored value marks the handle, so writers of the cell are refused. Where an operand of the
  switching call can read the contents, the stored value still escapes.
- Fixtures: `run/CellWrittenInArm`, `CellContentsAtTheirPlace`, `CellWrittenInOperand`,
  `CellStoredThenSwitch`, each with its live twin. `cells.mjs` has seven `arm*` writers (34 448
  programs).

**What I learned**

- A coarse reading can protect a rule that is never stated. The exact reading through any
  generic callee let 28 `worded-twice` `elemG` programs trap: a row of no count builds a new value
  at the type variable. And it removed the `disjoint` that hid a missing test: a later run's write
  of a cell that an earlier run put at two places (17 programs, the first reviewer).
- "The holder judges" needs a complete list of who can see the stored value between the store
  and the write. Other fibers are not the only ones: code in the same call (a callback beside
  the cell, a closure the writing closure calls), the helper passed as a value, and a writer fiber
  that writes a stored value which the caller still holds. The second and third reviewers found
  52 programs before the list was complete.
- The dump-diff of every sweep (133 358 programs, dumped once on base, once per head) finds the
  changed programs in about 50 minutes; only those need the four legs.
