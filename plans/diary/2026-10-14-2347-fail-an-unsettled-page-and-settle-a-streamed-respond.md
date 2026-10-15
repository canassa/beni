## 2026-10-14 23:47 CEST — fail an unsettled page, and settle a streamed respond

**What I did**

Rebased #103, #109 and #112 onto master `e2aed9171` (CI's workflow); the
hashes did not change, the gates and CI passed on all three. On #112: a
capped `settle` now fails the step at once, and the step fires no later
timer, frame or chunk; a `throws` step does not absorb it. A streamed
`respond` settles before each chunk; `browser/tea/RespondSettlesEachChunk`
showed 1 373 (happy-dom) and 1 437 (Chrome) of 2 000 messages late before,
0 after.

**What I learned**

The `RangeError: Invalid array length` of a page that never settles is
core's: `Task.schedule` pushes onto a queue that `drainNow` resets only
when it is empty, so a scheduler that never runs dry grows it until V8
refuses the array (8 s for one page in happy-dom). With a settle after
every timer, the driver paid a capped settle per timer before it got
there; now it stops at the first.
