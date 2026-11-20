## 2026-11-20 16:52 CET — v3: the loan rule for a cell fibers share

**What I did**

- Lane ref168, the checker lane of v3's cells and fibers. First #2586 (blind round AS, three fault
  classes in kernel §13 item 11), `b3e7f99705`: a closure run within a call reads what it writes
  there, before its renewal; a later run writes what an earlier one stored (the write covers the
  renewal's sources at the written location); a callee that answers or keeps the function does not
  run it within (`keepsFn`). Fixtures `run/CellClosureReadsAtRun`, `CellClosureRunsTwiceLive`,
  `CellClosureWrappedLive`; precision debt #2587.
- Then #2581, the owner's loan rule (#981), kernel §13 item 12, `9c62bf83bc`: switch points (impure or
  suspending calls), writers (a closure that writes a frame-made cell's contents and goes out of
  sight), writer runs at switch points and returns, probes and the `flag_m` mark with a probe-only
  rename (`Atom.ren`), marks through callees and through a supply to a function that switches, and
  revocation. #981's shape runs in place (`run/CellFibersInPlace`); `run/CellFibersInPlaceLive`.
- Two adversarial reviews found two more classes, both fixed: a closure operand that answers a loan
  or the handle (`keepsCapture`, `0500cdac57`) and a handle handed at a type variable
  (`followedOps`, `416da9b705`). `bede007022` widens a fixture's sleeps.
- `cells.mjs` grew to 12 012 programs (new writers and fiber shapes), 0 faults in four legs; 9 other
  sweeps 0 new faults; v3 dumps of 2 491 roots 0 verdict changes; ledger 309 of 319; v3 +4.3% on
  the real roots. #2584 tried (`List.length` `borrowed shallow`) and not landed: two pinned tests.

**What I learned**

- A rename at a switch point must not reuse `dead`: a loan taken after the switch would hide the
  frame's own earlier write. A separate, probe-only stamp keeps `dead` the write rule's alone.
- "A handle read through itself" is only safe where the callee follows it: a callee's walk probes a
  parameter only when its layout has a cell, so a handle at a type variable, or a closure that
  answers what it captured, carries a loan where no probe looks.
- Registering a closure that only stores into the cell, then revoking it, refused a program that
  sharing had accepted (`blind5d-faults/for-row-keeps.dead`): register writers only.
- Sweep programs ordered by 1 ms sleeps are nondeterministic under load, plain builds included;
  confirm every DIFF on a plain build run many times.
