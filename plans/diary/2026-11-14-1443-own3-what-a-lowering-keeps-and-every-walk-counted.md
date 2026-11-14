## 2026-11-14 14:43 CET — own3: what a lowering keeps, and every walk counted

**What I did**

- Fixed both faults of research report 133 as whole rules, and wrote report 134.
  - **Kept values.** A lowering now says which `let`s of a grouped root it keeps beyond the call
    (`Lowering.keeps_let`, interface 1.26; the default keeps every one). The check builds the markup
    tree with the emitter's own `MarkupTree.build` and escapes each kept `let` where it is bound.
    `dom` keeps a `let` unless it reads a path that is not identity-safe; `inline` keeps none.
  - **Charges.** The runs of new names (`markAtom`, `groundOf`, `atomSrcs`) are walked with a work
    list, once per entry, and counted; the pair tests count what they pass over; `finish` and the rows
    do not run past the budget. 400 writes: 17.6 s → 53 ms.
- The adversarial review found a root made of a component call alone (no dispatch markup row, so the
  check skipped the module) and an uncounted context climb in `compatible`. Both fixed, with tests.
- Gates: sweeps 25 traps → 0 in 82 714 programs; sanitiser corpus unchanged (0 traps); real writes
  287 of 308, line for line; `zig build gates` green.

**What I learned**

- A per-call `run_seen` set does not bound a chain: each write walks the whole chain again. A fact
  that never changes once made can be kept for the whole walk.
- Hash maps keyed per atom cost more than the walk they memoised; an array beside `rents` is enough.
- A shortcut on "this module has no markup rows" is a negative fact without a positive one: the
  emitter does not read that table.
- Open: the counted work of a chain is quadratic, and a chain of `case` projections over a recursive
  type grows it exponentially (20 levels pass the budget, about 20 s before the limit at 400).
