## 2026-10-14 20:39 CEST — a Chrome page settles until core's scheduler has no turn left

**What I did**

Opened #108 and PR #109 (stacked on #103). The page driver's prelude now
counts, in Chrome, the `MessagePort` messages the page posted and that
were not yet delivered, and `settle` takes more turns while one is
pending, as it already did for a `setImmediate` under happy-dom. The
README and the driver's header say first that a step's page is the page
once everything the step set going has run, in both DOMs. With #103's
driver, `test-browser -Dcorpus=SettlesManyFibers` failed 5 of 5 runs;
with this one it passed 10 of 10, at loads from 1.2 to 7.1. After the
`@claude` review, a message that arrives uncounted fails the step, and
the cap is exactly 1 000 turns.

**What I learned**

A listener that `addEventListener` adds to a `MessagePort` does not start
the port, so the count can listen on both ports of every channel without
changing when the page's own `onmessage` starts delivery. The happy-dom
cap was 1 001 turns, not 1 000.
