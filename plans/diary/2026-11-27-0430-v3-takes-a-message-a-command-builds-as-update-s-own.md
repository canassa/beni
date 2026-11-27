## 2026-11-27 04:30 CET — v3 takes a message a command builds as update's own

**What I did**

- Built the owner's decision of 2026-11-27 (#2657, group 4): a message whose constructor only the
  program's commands build is `update`'s own. Kernel §6 rule 13 has a new paragraph, *A message a
  command builds*, with six facts: `update` and the message type are the entry module's; every
  construction of the constructor is given up to a command's send (`send (C …)` of cells the
  function made, no cell twice in it), or is the tag of a platform function such as `Cmd.task` over
  work that answers new cells; no decoder; no function of the program keeps a message (published per
  module for its importers); the model holds no message; `update` gives the list up.
- v3 now accepts `OwnedCommandSend` and the four `Conduit*Errors` pages on `browser-inline` (and
  their `browser-tea` twins). The five pages carry a `.sanitize-lists-v3` file, so the gates run
  them under v3 and the list sanitiser today.
- One adversarial reviewer found two fault classes, both fixed with a commit each: one list at two
  locations of one sent message (`Pair xs xs`, a tuple, a record a helper built), and a send of what
  a function parameter answers (`send (Items (mk ⊤))`), which the send's demand reads as the
  function's own.

**What I learned**

- A send's demands are per location: nothing compared the locations of one message. And a demand on
  the answer of a function parameter is grounded `fresh` in the sender: what the caller hands is not
  checked against it. Both were harmless while the message was never `own`.
- The message can reach program functions after the send: `Cmd.map`'s tag, a fake sender, a generic
  helper in another module. Only a fact over every function value of the program closes that, and a
  module's must reach its importers (`Published.keeps_messages`), read only from its dependencies so
  the verdict does not depend on the schedule.
- Group 1 (view handlers) needs a per-event-item fact from the `inline` lowering: root events with
  no captured helper arguments are evaluated at the event, row and region ops keep the closure made
  at render, and three of the five pages are pieces of another module's root, a third path.
