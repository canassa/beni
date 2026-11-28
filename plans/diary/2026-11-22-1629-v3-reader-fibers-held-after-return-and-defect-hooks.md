## 2026-11-22 16:29 CET — v3: reader fibers held after return, and code a defect runs

**What I did**

- Fix lane fix180 on `ownership-v2-design-review`, for #2604 (CR3's reader fibers) and, by the
  manager's order mid-lane, blind round BP's two shapes: a `Log.setSink` sink run inside
  `Ref.update`'s function (#2604's second comment) and a `Task.onDefect` hook that reads the cell
  after a throw (#2605).
- **A reader is held after the frame returns** (kernel §13 item 12, amended): what a reader fiber
  reads at each return point escapes where the walk ends (`readersHeld`), after every judgment,
  so the frame's own writes and writer fibers stay accepted and no handle is shared. An answered
  handle, loan, record, `Just`, a loan stored in a parameter's or captured cell, a `?` answer and
  the parameter list the cell was made with are refused at the caller's write.
  `run/CellReaderHeld` and its live twin.
- **A reader is revoked for the mark**, and **code a defect runs runs at any point**: `Fn.defect`
  on the function parameters of `Task.onDefect`, `scheduler`, `schedulerWith`, `onTurn`, the
  teardown's cleanups (`bracket`, `onExit`, `defer`, `start`) and `Log.setSink`, passed on through
  a helper's parameter. Such a function is neither a writer nor a reader, what it captured
  escapes where it is handed, and an opaque function value there is refused.
  `run/CellDefectHook`, `run/CellSinkReads` and their live twins.
- **The oracle**: `run.mjs` now compares what two failing runs printed (stack frames, locations and
  log times set aside) instead of calling them BOTHFAIL; a log line's time is no DIFF.
- `cells.mjs` gets `reader.*` (258), `marked.*` (24) and `defect.*` (27). On the base, 57 `reader`
  live, 8 `marked` live and 12 `defect` live programs TRAP; on the head none.
- Evidence: root dumps, 6 of 2 529 differ (the new fixtures and core's own `defect` words); the
  ledger 309 of 319 on both; 135 623 sweep programs dump-diffed, 223 changed (the new families and
  the two first fixtures), all run under the four legs: 0 faults. BP's families (1 017 programs):
  base 224 TRAP, head 0. v3 on the real roots 4 068 ms base, 3 919 ms head (ReleaseFast, noise).
  467 programs that blind rounds called BOTHFAIL, judged again: 11 DIFF, all a log line's time
  (fixed), 0 faults. One Opus reviewer: one fault (a hook that captures nothing but logs runs a
  sink reader at the throw), fixed by making the sink a defect hook; 264 programs, 0 faults after.

**What I learned**

- A "reader" is a holder like any other once the frame is gone: the precision lane argued only
  about what it does to others, never about what others do to it.
- A throw is a switch point the kernel never named. Every function the runtime keeps globally
  (hooks, sinks, cleanups) runs at any point, so it can never be a writer or a reader.
- Precision lost on purpose: a reader joined before the frame answers (`reader.joined`), a
  `Log.setSink` sink that reads a cell refuses every later in-place write of that cell, and a
  reader beside an update whose function only runs other fibers (`marked.span`).
