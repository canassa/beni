## 2026-10-14 21:07 CEST — close the stray-message gap in the Chrome settle count

**What I did**

Answered the second review of PR #109. A `message` event that is not
trusted no longer changes the count, and a post that transfers a counted
port fails the step at once, through a port, a worker, a window (also a
frame's, whose prelude reports to the page that made the port) or
`structuredClone`. The contract now names only what core's scheduler
queued, and the README lists the five ways a message stays undelivered.
The PR body says that the happy-dom cap went from 1 001 turns to 1 000.

**What I learned**

`Symbol.for` keys are shared across realms, so a port can carry its maker's
record into any frame's wrapper. A probe of the driver's own `prelude`
must not wait on `setTimeout`: the prelude replaces it with the virtual
clock, and the probe hangs.
