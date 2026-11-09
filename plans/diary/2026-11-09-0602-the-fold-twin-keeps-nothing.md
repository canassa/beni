## 2026-11-09 06:02 CET — The fold twin keeps nothing

**What I did.** PR #2344's review found that the twin of a fold's accumulator accepted a callback that
also puts a part of its answer in a captured `Ref`: the next run edits that part in place and the cell
sees the edit (plain prints `3`, v2 `4`; the sanitiser does not trap). The twin now needs a known code that
keeps nothing a later run writes (`SelfFed.keepsNothing`): no store, cell write or label handed anything,
no escape but of the accumulator, and none at or above a slot it writes (or below one it writes open).
§2.11.3's amendment says so and its induction uses it. Two red `run/` fixtures with `-refuses` goldens:
`SanitiserFoldAnswerFedKept` (lambda and helper) and `SanitiserFoldAnswerFedSlot` (a pair swapped, a
record's fields swapped, a tree's depth 1 lifted to its root), and the mutants `self_fed_keeps_ok` and
`self_fed_slot_off`, both killed. A generator of 8 232 fold programs with captured cells and swapped
answers gives no DIFF and no TRAP among the accepted.

**What I learned.** A blanket "no escape" refused `FoldKeepsInner`'s `grandchild`, which keeps
`acc[0][0]` and pushes onto `acc[0]`: what matters is whether a later run writes what was kept. The
same-slot condition needs no recursive type: a tuple swap is enough. v1 accepts the cell program and
prints the wrong cell, because it reads no cell (#2349). A `-refuses` golden fails the case on acceptance
whatever the sanitised run prints, so it pins a defect the sanitiser cannot see.
