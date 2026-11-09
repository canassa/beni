## 2026-11-09 14:57 CET — a fold callback that keeps its answer

**What I did**
- #2367 (lane s6n, PR #2382): `FedCall.at` now asks that a known code's run keeps nothing of its fed argument a later run writes (`RunKeeps.nothing`, split from `SelfFed`), so a fold whose callback pushes onto its accumulator and keeps the answer in a task, a view or a handed function is refused at the fold.
- Narrowed the twin's whole-code test to the objects a later run writes: an `Int` cell, another argument's escape and a label handed a fresh object where none sits at a written slot keep nothing.
- Fixtures `run/SanitiserFoldKeepsAnswer` (traps on master) and `run/SanitiserFoldKeepsAnswerApart`; spec amendment in §2.11.3.

**What I learned**
- The plain path and the twin each decided `fed` on their own; the keep test belongs where the occurrence is decided, so both read it.
- A first, whole-code version refused `SanitiserAnswerFoldCycle` and 19 probes (a label handed another label's answer): the test must ask what reaches a written slot, not what the code does at all.
- The review found a callback that hands its accumulator to a predicate is refused now (#2386): the label's code is only known at the caller.
