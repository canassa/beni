## 2026-10-26 03:49 CET — core/Semaphore lands, with manual acquire and release

**What I did**

- Opened #1039 for `core/Semaphore`, the first part of effects slice P5. Before the implementer started, the owner decided to offer manual `acquire`/`release` next to `withPermits`.
- Opened #1040 (`Queue`, `Latch`, `Task.forever`) and #1041 (the beni-logo ball machine as an SVG playground sample).
- Briefed an Opus implementer, which opened PR #1042. Two adversarial reviewers then ran: one on cancellation semantics, one on spec, fixtures and rules. They found:
  - an oversize `acquire` could not be balanced by `release n`;
  - `tryWithPermits`'s guard was `== 0`, so the clamp in `make`/`resize` the PR had called unobservable was in fact observable;
  - no fixture cancelled a middle waiter, or cancelled inside a try's work.
- All of it was fixed with red-first fixtures (15 `run/Semaphore*` in all), and #1042 merged.
- Two findings reach beyond the PR, so they got their own issues:
  - #1043: `race`/`timeout` cancel losers only once the parent wakes, so a loser resumed on the winner's turn runs to `Done` and its permits leak. An implementer is on it, before #1040.
  - #1044: cancelling n waiters at once is O(n²), because of `indexOf` plus `splice`, shared with `Deferred`.
- The owner then said no more benchmarking on this work. #1040, #1041, #1043 and #1044 carry that note.

**What I learned**

- §17.9 said Effect documents `take`/`release` as not interruption-safe. It does not. `Semaphore.ts:541-545` only says "keep permit counts balanced". Read the source before citing a refusal's reason.
- Leaving out `acquire`/`release` bought no guarantee. `Ref`, `Deferred` and `Task.callback` are public, so any program could write a worse manual semaphore anyway. That is rule 7.
- A FIFO hand-off makes a waiter take its permits before it runs. Effect's waiters race and check again when they run. Every combinator that discards a branch's result is a leak path for a hand-off primitive. That is how #1043 surfaced, and `Queue` would hit the same thing.
- Changing one rule at a time in a copy of core (`--core-root`) is what found the fixture gaps. A reviewer who only reads the fixtures misses them.
- The beni-logo flow page draws with canvas 2D. Beni has no canvas drawing API, and only the `<canvas>` element exists. `jaysonsantos/beno-arena` shows a game drawn in SVG on `browser-tea`, so #1041 uses SVG.
