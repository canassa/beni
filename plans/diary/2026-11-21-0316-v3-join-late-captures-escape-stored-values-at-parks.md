## 2026-11-21 03:16 CET — v3: join late captures, escape stored values at parks

**What I did**

- Lane fix170, a fix lane of v3's cells and fibers, for two blind-round faults.
- #2590 (round AW): a closure's store into a cell it captured was not joined across its paths. A
  capture's root is made where the body first names it, and every §13 hook that saves cells before
  a part of the walk that may not run was gated on `cells_any`, still false there: `caseOf`'s
  `saveCells` (no restore between arms, no join), the `&&`/`‖` join, and `noteReturnCells` at a `?`
  before the first mention. Lambda frames now always save cells at arms, keep their return points,
  and a capture made late is noted at each earlier one, and marked as at an earlier markup switch
  point (`backfillCapture`). `run/CellClosureJoinsPathsLive`. Commit 0495bacfb6.
- #2591 (round AX): a spawned writer that stores, parks and writes what it stored was judged as one
  unit; the stored value was a cell of its own run, which no holder judged, so a loan the frame
  took of it during the park went stale. At each switch point, what a body put in a tracked
  parameter's or capture's cell (not its own old contents) now escapes (`escapeStored`, also in
  the markup branch). `run/CellStoredParkedLive`. Commit a23577b274. Its cost is #2592.
- `cells.mjs`: ten conditional-store writers, four store-park-write writers and the `midPark` fiber
  shape; 28 672 programs.

**What I learned**

- A root that is made lazily misses every frame-wide event before it. The fix is to replay those
  events when it is made, not to find each hook that reads `cells_any`.
- "Every impure call is a switch point" makes any value a body stores into a parameter's cell
  escape at the next `Ref` operation, for the caller too. Sound, coarse: 804 earlier sweep
  acceptances and no real root. The precise form is a contract flag the holder judges (#2592).
- The two dump diffs of real roots that looked like changes were split UTF-8 bytes in
  `bench/ownership-v3-dumps.mjs` (it decodes chunks one by one).
- The full cells sweep, the neighbourhoods and one adversarial reader (about 5 600 programs) found
  no fault; real roots, the ledger (309/319) and v3 time (−0.8 %, noise) did not move.
