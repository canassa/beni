## 2026-10-24 01:00 CEST — A body goes on after update throws

**What I did**

- Fixed #859, R2-F1 of #830's review. A command body that calls
  `Dom.focus` goes on after the input's handler runs an `update` that
  throws: the DOM reports the throw, and the call returns. The rest of the
  body had `update`'s log context, not its own.
- The fixtures come first: `browser/tea/LogContextAfterReportedThrow` (a
  body in a fiber) and `…Soon` (a body with no fiber), from the reviewer's
  probes. On `master`, the body's line after the focus has
  `{"update":"u"}`; with the fix, `{"request":"r1"}`.
- The fix is in `restoreSlots`: the caller's slots go back at once, and
  when `update` leaves finalisers, an entry on top of them sets `update`'s
  slots again, so the teardown still runs them with `update`'s context. A
  mutant without that entry fails `LogUpdateDefect`.
- Opened #921. A probe shows that such a body's `bracket` release runs
  twice, on `master` too.

**What I learned**

- A throw is not always the end of the code above it. An event that the
  page's own code fires, such as a focus, runs its handler inside that
  call, and the DOM reports the handler's throw and returns. So "the
  teardown runs next" is not true there.
- `popFinalizer` takes the last entry, not its own one. That holds only
  while every push is matched by a pop, and a throw that the DOM reports
  breaks that: a later pop then takes another entry (#921).
