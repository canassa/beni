## 2026-11-17 21:28 CET — a defect stops the page on three more paths

**What I did**

- Reproduced #1994's three paths on master `e72a8bfd80`, each as a page fixture written with the
  right answer first: a plain `Browser.program` whose `Task.spawnDetached` fiber throws, a
  top-level value that throws while its module loads (`browser`, `browser-tea`,
  `browser-inline`), and a fiber that resumes under a program-made `Task.scheduler` and throws.
  All three left the page running or showed no crash screen.
- Plain program: `Rt.beni`'s `run` gives `Task.onDefect` the page's stop for every page, and
  `stop` calls `Task.shutdown` for every page. `browser/dom/DefectCancelsFibers` pins the second
  part: a handler defect cancels a plain program's sleeping fiber.
- Program-made scheduler: a scheduler record has `contains`; `Task.scheduler` makes `False`,
  `Task.schedulerWith` `True`. `failedS` stops the program after the scheduler when it does not
  contain. Amended `transparent-effects-proposal.md` §17.5, which still said "that scheduler
  alone".
- Module load: by the owner's choice, a development entry loads the program with `await
  import()` inside `try … finally` and calls the runtime module's new `loadFailed`. Release keeps
  its static import.
- Proved every new fixture red by putting master's four source files back.

**What I learned**

- A throw under `Task.withScheduler` before the first park leaves the program's drain, not the
  scheduler's: the first scheduler fixture passed on master. The fiber must park first (a
  `Time.sleep`) to reach `failedS`.
- `Rt.stop`'s "a page of `Browser.program`s never calls `shutdown`" was false since
  `Task.spawnDetached` is callable from a plain `update`. Dropping the test cost no byte on a
  plain page with no fiber: no `emit/release/dom` golden moved.
- Both crash screens take their message from the window `error` event, and a rejected top-level
  `await` in the entry fires it, in happy-dom too.
- Master `2e4d2ef064` is red on `build/bad/inline/WrappedSuspendingCommand` (#2553), not from
  this branch.
