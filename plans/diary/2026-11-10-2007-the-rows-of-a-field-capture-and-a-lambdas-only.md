## 2026-11-10 20:07 CET — the rows of a field capture, and a lambda's only

**What I did**

- The second part of S5b of #1018, on branch `own2-record-capture-rows`, stacked on #2453.
- A lambda that reads a field of a captured record reads it when it is made. v2 now keeps a row for each such
  read and prints it as v1 does (`capture p.x: read 34:23; before 34:13`).
- The comparison with v1 over the corpus: 329 rows the same. 1 441 capture rows are only in v1, because v2
  makes a field capture only where its record pass runs. Four capture rows were only in v2, and all four were
  local functions.
- v1 has no capture row for a local function, and the emitter has never bound one. I restricted v2's field
  capture to a lambda. No verdict of the corpus moved.
- The probe for that decision found a defect of v1 (#2455): a local function that reads `p.x`, an update of
  `x` in place, and a call of the function. v1 accepts it, and `--records-in-place` prints a wrong number.
  The record sanitiser sees it. v2 refuses the update.

**What I learned**

- "Only in v2" was the small list, and it was the one to read: four rows, one cause, and behind it a path
  of the emitter that no row had ever taken.
- A feature that the corpus does not need (a local function's field capture) is a cost with no test behind
  it. Taking it away moved nothing, and it removed a case from the next step.
- The frozen checker is still the reference, and it is still wrong in places. A difference where v2 refuses
  and v1 accepts is not always v2's loss: run the program with the sanitiser before deciding.
- A local function and a lambda look the same in the source and are two things in the checker: one reads
  when it is called, the other when it is made. The fixture has both, side by side.
