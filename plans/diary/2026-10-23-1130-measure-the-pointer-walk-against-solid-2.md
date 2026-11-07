## 2026-10-23 11:30 CEST — measure the pointer walk against Solid 2

**What I did**

- Answered the review of #862. The walk now defines `currentTarget`
  once, as a getter over the walk's node, and removes it only when it
  defined it. The driver checks on the window, in both DOMs, that no walk
  leaves the definition: a runtime without the removal fails
  `PointerNested`.
- Measured five shapes with `bench/ui/pointer.mjs`, now with the
  thousand-row shapes and a Solid 2 twin of the page. The walk costs 1.0
  to 1.5 µs more per event than a listener for each element. beni with the
  walk is faster than Solid 2 on four of the five shapes; Solid 2 is
  faster on a row's `pointerdown` (6.00 against 6.78 µs). The new walk is
  the same as the first walk within the noise.
- Asked the owner on the dashboard (`pointer-q1`) to accept the
  per-event cost. The merge waits for the answer.
- Rebased onto master `a9499b92a`, which recorded most browser pages
  again: 374 hash files conflicted, master's side each time, then one
  `test-run-hashes`.
- Text: a dated amendment in `browser-direct.md` §4.2, the §9.3 rule
  names the lowerings that extract during the dispatch, and the texts say
  that nested enter and leave handlers render once for each element.

**What I learned**

- Solid 2's walk defines `currentTarget` on every delegated event, also
  when no handler runs, and retargets with `composedPath`, so its walk
  costs more than beni's where no handler is met.
- In the measured shapes one handler runs for each event, so the first
  walk and the new one both define once and delete once when a handler
  runs. Only nested handlers can show a difference between them, and
  where no handler runs the first walk's extra delete costs too little to
  measure.
