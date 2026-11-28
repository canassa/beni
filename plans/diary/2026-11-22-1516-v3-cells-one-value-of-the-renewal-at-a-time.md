## 2026-11-22 15:16 CET — v3 cells: one value of the renewal at a time

**What I did**

- Lane prec179, the third precision lane of v3's cells, on `ownership-v2-design-review` at 9a7679f82a.
- Checked the second lane's reviewer note that acceptance changes with unused imports: 71 cell
  fixtures of `run/`, each with 17 unused imports added one at a time, give dumps equal to the
  fixture's own (line numbers shifted). No determinism defect on that head; the reviewer's own program
  was not found, so the sweep is the evidence.
- **BN's undo app, its `disjoint` half** (kernel §13 items 3 and 5, amended). A renewal is the union
  of what each arm leaves in the cell, and a run leaves one of them. A walked body now publishes
  `Contract.renew_shared` (one run can leave one cell at two locations of a renewed parameter), read
  per value of the join (`renewTwice`); a caller reads it where it makes the version, on a result's
  grounds. A `Ref.update` callback's own `!nonlinear` is read the same way (`answerClaim`). The first
  adversarial reviewer found eleven wholly accepted programs that trapped: the callback answered one
  list twice through a function it called or captured (`( g ⊤, g ⊤ )`, `( second v, v.1 )`). Those
  entries are now tested by their atoms; the second reviewer (46 programs) found no fault.
  `run/CellRenewalArmsApart` and its live twin; `cells.mjs` gains the `move*` writers (728 programs).
- Evidence: root dumps of 2 526 roots, base and head, differ only in the two new fixtures; the
  ledger is 309 of 319; a twelfth of `cells.mjs` and a fortieth of the blind rounds BC to BN dumped
  on both: only `move*` programs and refusal causes change, none accepted to refused; the `move*`
  family under the four legs: 36 refused → SAME, 0 faults; a mutant (claims read with no test) traps
  12 `move*` live twins and 27 reviewer programs.

**What I learned**

- The claim alone moves few programs: the caller also reads the callee's writes and renewal as one
  union, so after `apply r Undo` (whose `Add` arm writes `present`) a later read of `future` still
  reads the old `present` as written. Keeping a callee's arms apart in its caller needs per-arm
  writes and renewals joined with contexts, and every test of two atoms made context-aware (with its
  indexed twins and the safe-build cross-checks). That is the next step for BN's undo.
- A callee's claim about its result never covers the answer of a function it calls: the frame sees it
  as an opaque root. Every reader of such a claim must test those entries by atoms.
- Left: (b) and (c) of the lane's list (`noteParked`, the `park.*` programs) sit beside #2604's fix;
  (d), (e), #2580, #2587, #2582, #2589 untouched.
