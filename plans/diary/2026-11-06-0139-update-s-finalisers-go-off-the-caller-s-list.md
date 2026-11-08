## 2026-11-06 01:39 CET — update's finalisers go off the caller's list

**What I did**

- #1154 and #921 have one cause: after a throw that the DOM reports, the finalisers that the
  handler's `update` left stayed on the list of the body that fired the event. A body in a fiber
  that then ended took them with it (#1154), and a scope that the body closed after the throw
  took `update`'s entry instead of its own, so its release ran twice (#921).
- `restoreSlots` (`core/Task.beni`) now takes them off the caller's list and keeps them apart on
  the same record (`stranded`), with an entry on top that keeps the slots and sets `update`'s,
  and one under them that puts the kept slots back. A fiber's unwinding and the teardown's run
  of the record outside any fiber take them first. When a fiber reaches its end while it holds
  them, `finished` puts them on the fiber's own stack, under one more call of `finished`, and the
  fiber runs them before it ends.
- `beginUpdate` and `endUpdate` read `finalising` as well as `slotted`, so a `bracket` in
  `update` on a page that sets no slot is covered too.
- Three page fixtures: `LogUpdateFinalisersAfterBodyEnds`, `UpdateBracketAfterBodyEnds` and
  `BodyReleaseOnceAfterReportedThrow`, each red with #1153's core and green with this one.
- Spec: a second amendment of 2026-11-06 to `boundary.md` §9.8.16 (b), and a note at
  §9.8.14 (a).
- Bytes against #1153's core, release: the pages that set a slot grow by 280 to 391 raw; the
  25 pages that register a finaliser and set no slot by 666 to 671 raw (146 to 233 brotli). I
  asked the owner (dashboard `dom-throw-body-q1`) whether those pages pay for it, and built the
  recommended answer, that they do.

**What I learned**

- A property that a function writes cannot be folded where it is read, even when only `null`
  is written. My first version wrote `stranded = null` in the readers, so every Node program with
  a `bracket` grew by about 170 raw bytes. A cell that only the writer sets (`stranding`), read
  before the property, folds the readers away in a build that reaches no code that sets it:
  every Node program, which has no `send`.
- Keep the statements of the teardown in their old order when you move code out of it: the
  specialiser writes a function called once where it is called, but a different order is
  different bytes.
- My first fix started a fiber of their own from `complete`. Its `newFiber` writes `fibered`,
  and that write kept the whole fiber runtime (+2 014 bytes) in a release `Tea.element` page
  whose commands never wait, although the code around it folds. The cell that gated it,
  `stranding`, does not fold either: its one write is in code that folds only later. The fix
  runs them in the ending fiber itself, which writes no cell.
- `Task.complete`, `cleanups`, `teardown` and `finished` carry pinned ownership words
  (`tests/corpus/ownership/word-bodies.txt`): a change to their bodies needs a re-reading in
  `ownership-checker.md` §24.8 and new hashes, and each new helper they run needs a pin.
