## 2026-11-26 23:00 CET — v3: repeated runs to a fixed point

**What I did**

- Fix lane fix221 on `ownership-v2-design-review` (base 2d2691dec9), for four soundness faults of
  one class: the checker followed the versions of a cell, and what each holds, by a fixed number
  of steps or from a fixed list of holders. #2701, #2702 and #2703 are code reader CR12's; #2708
  is blind round DA's.
- Kernel §13 item 12 amended (item 11 points to it): (a) a renewal that its holder can run again
  is read to its fixed point, the closure of its location-to-location map (`renewReach`,
  `storedAtoms`, `closedSrcs`, `handsContents`), and a cell that two locations hold after the
  same number of runs is a cell at two places (`heldTwiceAfterRuns`, a search of pairs); (b) the
  writers and readers that can run at one place run to a fixed point (`runWritersFix`, in
  `switchHere`, `writersAtReturn` and both passes of `runEnd`); (c) the callee value is an
  operand of the runs after a call; (d) a closure a call can run again may not write in place
  contents it never stores back (`kept_written`, `runsOnce`).
- #2701: an older writer now runs again on what a writer made in the call moved into its cell.
  #2702: rotations of three, four and five parts, a record's fields and a part moved through two
  others are refused where the frame holds a part that reaches the written place. #2703: `call`
  hands `runEnd` the callee value. #2708: `List.map [ 1, 2 ] λ_ → (l = Ref.get r; …; _ =
  List.push l 45; …)` is refused `later-use`.
- Fixtures: `run/CellFixedPointRuns` and its live twin (18 shapes, CR12's two unproven notes
  among them); six live goldens gain duplicate lines of refusals they had, two name the new refusal at the same place, and `ownership-v2-known.txt` gains the new fixtures' 363 v1/v2 lines. `cells.mjs` has
  `fixed.*` (94 programs). The base has 27 live TRAPs there; the fix refuses every live program,
  and every dead twin is SAME.
- Evidence: root dumps of 2 584 roots, no verdict changes outside `run/Cell*` fixtures and no
  accepted root refused. Sweep dump-diff of 8 453 programs (cells, folds, function values,
  callbacks, evidence, nested arms, answers, worded bodies): 886 differ, all in `cells`, and 12 go
  from accepted to refused, all live `fixed.*` programs. Ledger 309 of 319 before and after. v3 on
  the real roots is the same within the noise (ReleaseFast, alternating runs: 2 230 and 2 415 ms
  against 2 487 and 2 495). The adversarial reviewer wrote 165 live programs in two passes and
  found no fault.

**What I learned**

- One closed run of a writer was the wrong way to reach the closure: each version held the
  sources of every location, the next run read them again, and the atoms grew by the reach each
  run, past the budget for four fibers that rotate four parts. A run a step, again until nothing
  changes, reaches the same closure at the cost of the base.
- A fixed point needs a comparison that ignores names of the way: a version is a new name of its
  origin's cells, and the versions an atom was read through say nothing about the cell.
