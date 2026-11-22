## 2026-11-22 08:49 CET — v3: an outside or moved cell a body leaves across a park

**What I did**

- Lane fix176, #2600 (a soundness fault the code reader CR2 found at 42627c252c). A body that stored a
  top-level list in its parameter's cell and parked, or swapped the cell's two parts, parked and swapped
  them back, put no mark on the handle. A writer fiber its caller spawned then pushed onto the top-level
  list, or onto the moved part that a caller's loan held, in place during the park.
- Cause: `noteParked` and `escapeStored` dropped every `outside` atom and every atom of the cell's own
  old contents, at any location. Fix: `storedAt` reads each location of the contents on its own; an old
  cell is passed over only at its own location (or one `sameCellAt` says cannot hold it), and `outside`
  is noted. Noted, the value marks the handle (`flag_m`), and the caller's writers are refused. The
  markup path uses the same function. `escapeStored` still passes over `outside`: no in-place write of
  it is accepted in the frame, and the refused probe marks the handle there.
- Kernel §13 item 12 amended (the "old contents" claim holds only at their own locations); item 11's
  garbled repeated half-sentence repaired.
- Fixtures: `run/CellParkedOutside` and `run/CellParkedMoved` (accepted, run in place: no writer fiber,
  so the mark refuses nothing) and their live twins (4 and 3 refusals); reverting the outside half fails
  only `CellParkedOutsideLive`, reverting the moved half only `CellParkedMovedLive`. `cells.mjs` gets
  `park.*` (800: what is stored × five parks × four runners × writer fiber or none × twin).
- One read-only Opus reviewer: no fault in 150 programs; 17 of them fault on the base binary (a callee's
  answer, two helper levels, `body r r`, a polymorphic swap, a 3-tuple rotation, the operand path,
  swaps between two parks), all refused now.
- Evidence: root dumps, 4 of 2 515 differ (the new fixtures only); ledger 309 of 319 both; 134 868 sweep
  programs dump-diffed: 316 changed (308 `park.*`, the 4 fixtures, 4 `nested-arms` LIMIT programs whose
  limit line names another read position), under the four legs: base 120 `park.*` TRAP, fix 0 faults; 80
  `park.*` dead twins with a writer fiber newly refused. v3 on the real roots 3 683/3 722 ms base,
  3 652/3 781 ms fix (ReleaseFast, noise). Gates: a first run under load 50 timed out two `check_test`
  tests whose programs take the same time on both binaries; the rerun passed.

**What I learned**

- A filter by root ("not the cell's own") is a claim about locations: an old cell is "the caller's" only
  where it still is. Reading the leaves location by location, before `uniqueTail` merges them, is what
  keeps the location.
- The precision loss is the designed one: a body that parks with a top-level value or a moved part
  marks the handle even when it puts its own value back before it returns, so a writer fiber of the
  caller is refused although nothing reads what it wrote.
