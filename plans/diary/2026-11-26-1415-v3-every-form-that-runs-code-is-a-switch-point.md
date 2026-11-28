## 2026-11-26 14:15 CET — v3: every form that runs code is a switch point

**What I did**

- Fix lane fix217 on `ownership-v2-design-review` (base 838fe33645), for #2697 (code reader
  CR10): a return-type dispatch `a.make n` ran the bound method, which can sleep, and never asked
  whether another fiber could run there. In a generic that held a loan of a cell across it, no
  writer ran, no handle was probed, and the loan saw a writer fiber's push (two live TRAPs).
- Fixed the class, not the one form. Every form that runs code now asks the same question
  through one helper: `switchPoint`, with `runBegin`/`runEnd` (the writers made in the call run
  after it) and `knownRuns` (a callee contract's `runs_on`, `hosts`, `hosts_forked`). The forms:
  a call, a method call and an operator, a return-type dispatch, an entry, a component that the
  markup renders, and a `For`/`Show` function where the markup renders (no effect site there:
  `fnSwitches`, or the frame's own function parameter). Interpolation and patterns run no code.
- Safe builds now check the class: `Check.checkCovered` fails on an effect site that a walk
  evaluated and no form asked about (`Mod.routed`). Its first run found that a lambda's own arrow
  is an effect site too; those are skipped.
- `fnSwitches` reads an `outside` function value as code that can switch (CR10's U1). I found no
  program where it changes a verdict: `Ref.update r later` with a computed `later` is refused
  already, because its contents go to code the walk does not know.
- Kernel §13 item 12: amendments to *A switch point* and *Marks reach the frame*.
- Fixtures: `run/CellTypeDispatchSwitch` and its live twin (six shapes: the generic makes the
  cell, is handed it, stores its own list there, is of another module, is reached through a
  second generic, dispatches in a `List.map` closure). `cells.mjs` gets `switch.*` (38 programs:
  dispatch, pipe, method and call forms, and the `outside` pair). Base: 6 live TRAP, and both live
  pipe programs accepted; fix: every live refused, every dead twin SAME, the method and call
  controls unchanged.
- Evidence: root dumps, 2 580 roots, 2 differ (the two new fixtures). Sweep dump-diff of 3 150
  selected programs (13 generators and the corpus): 11 differ, all new `switch.*` programs and
  the new fixtures. Browser-inline pages: 318 checked, 295 accepted before and after, 0 differ.
  Ledger 309 of 319 before and after. v3 on the real roots 2 867.7 → 2 890.5 ms (ReleaseFast,
  loaded machine). Reviewer: 0 faults; one concern (a row function that is the frame's own
  parameter) fixed.

**What I learned**

- A rule a form must remember to call is a rule a new form forgets. A check that every effect
  site went through the rule catches the next one on its first program.
- `beni dump` takes one file or a directory, and a directory's walk skips symbolic links:
  `corpus.mjs` links its sources, so a dump of a program of several modules needs a copy. My first
  dump-diff read 697 such programs as "same" because both dumps failed.
