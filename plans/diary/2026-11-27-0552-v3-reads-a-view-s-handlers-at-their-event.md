## 2026-11-27 05:52 CET — v3 reads a view's handlers at their event

**What I did**

- Built the precision rule for the view-handler group of #2657 (kernel §6 rule 12, *A handler read at the event*). The `inline` lowering now reports, for each event, whether it reads the handler where the event fires (markup interface 1.43, `Lowering.reads_handler_at_event`). It answers yes for an element that the root reaches through elements and fragments alone, in a root with no `let`.
- v3 asks the question only in a root that is the whole body of a function that its module names only as an entry record's markup field (`Mod.viewRoot`). No other reference, method call or evidence may name that function, and the build may not be `--library`. Such a handler is applied as a call with the event's payload, and only its message escapes (`Frame.eventCall`).
- Won `KeptHandlerSameField`, `PointerInput`, `PieceHandler`, `PieceHandlerCell` and `PieceHandlerReplaced`. Each one now has a `.sanitize-lists-v3` file. `KeptHandlerSameField`'s refusal pin is gone. A new page, `KeptHandlerNamedTwice`, pins the refusal when the `view` is named somewhere else.
- Sweep of all `browser-inline` pages: only those 5 move, from refused to accepted. Dumps of all roots: 0 accepted → refused. The `--mode=both` oracle gives SAME on all of them. The adversarial reviewer found no fault.

**What I learned**

- `browser-inline` keeps a render's closure in three places:
  - rows and regions keep `$row.h…`;
  - a helper's call keeps its arguments (`Event.captures`);
  - a `let` of the view that a handler reads becomes a memo slot.

  Only an element on the skeleton of a view root with no `let` is read wholly at the event.
- For another module's root, the only guard is the lowering's own claim. It shows that root only as a piece at context 0. A lowering that later puts pieces in rows or arms must change its answer.
- The shared gates lock can block a build for many minutes. A build that "finished" with an empty log had only been waiting on the lock.
