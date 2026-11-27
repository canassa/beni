## 2026-11-27 04:40 CET — v3: one cell at two places is decided on cells

**What I did**

- Fix lane fix224 on `ownership-v2-design-review` (base 945ba6f4be), for #2710 (blind round DD's
  `writersAfterMove`, 254 TRAPs of 2 400 generated programs; blind round DF's `writersBeforeDup`,
  the same class) and #2709 (code reader CR13's U1 and U2).
- Kernel §13 item 12, amendment of 2026-11-27, (e): every check that asks whether one cell is at two
  places compares cells by the cell they name, never by an atom's name; (b): the fixed point compares
  the map from each location to its cells; (d): both ways a closure can leave a write in its cell are
  covered (`kept_written` where no way renews, item 7 in the closure's own walk where one does).
  Item 11 points to (e).
- Code (`src/own3/Frame.zig`): `heldAtOther` refuses a writer's run, and a closure run within a call,
  that writes a location whose cell another location of the contents holds now (`sameCell`: origin,
  entry, path; `cellsMeet`, sorted, linear in the atoms); `heldTwiceAfterRuns` also meets where two
  entries hold one cell now (`StartCells`); `cellAtoms` keys each atom by its location; and
  `runWritersFix` reads each root's state once between two runs (#2711).
- Fixtures: `run/CellOneCellTwoPlaces` and its live twin (16 shapes: the frame's tuple and record
  renewal, a third writer made after and before, two race shapes, a store of `( a, b, a )` directly,
  in a helper and in a fold, a record fold, three writers, one writer of both parts, a fold within, a
  fold rotation, CR13's `condStore`, and the adversarial reviewer's race mover that writes a third
  part). The base accepts 12 of the 16 live shapes, whose blind-round versions trap. `CellFixedPointRunsLive` names the same
  shapes refused earlier, at the writers. `cells.mjs` has `twice.*` (192 programs): the base has 56
  TRAPs there, the fix refuses every live program, and no dead twin changes.
- #2711 (timing, not soundness): reading each root's state once between two runs halves the
  writer-heavy worst cases (ReleaseFast LLVM, alternating, same minute: 60 swapping writers 2 526 and
  2 529 ms → 1 041 and 1 057 ms; 300 writers of a 4-tuple 2 310 and 2 760 → 1 096 and 1 105; #981's
  shape, 12 writers and 40 switch points, 512 and 529 → 419 and 479). All three still end at the work
  limit, as on the base, and blind round DF measured the head before the fixed point about 4x faster
  than the base, so #2711 stays open.
- Evidence: root dumps of 2 586 roots differ only in `run/CellFixedPointRunsLive` and the two new
  fixtures (no accepted root refused). Ledger 309 of 319 before and after, line for line. Sweep
  dump-diff of 13 151 programs (`cells` and `folds-callbacks` sampled, the rest whole, the corpus as a
  sweep): 160 differ, 128 go from accepted to refused, all live `twice.*` programs, no dead twin; the
  160 under all four legs: 0 faults. v3 on the real roots: 2 056 and 2 254 ms on the base, 1 953 and
  2 126 ms with the fix. DD's 31, DF's 13 and CR13's 32 programs: every TRAP refused, no dead twin
  changed. The adversarial reviewer ran 3 808 programs: 0 faults, and a use-after-free in
  `StartCells.shared` (two slices of one buffer that the second read can move) that crashed six
  programs; fixed, the six are refused, its 780-program batch has 0 faults and no crash, and its
  smallest program is a shape of the live fixture.

**What I learned**

- The writers at one switch point all run at one time, so a read by one writer's run of what another
  wrote there is no later read: the later-use test cannot see it. A writer whose write changes a
  location another one holds must be refused at the write.
- A version keeps the old contents beside a run's renewal (`maybe`), so after a writer that moves
  parts, every part holds both cells. That union is the pessimistic side, and the new test refuses
  writers of the moved parts after it; it found no safe real program among them.
