## 2026-10-12 01:15 CEST — lean slice: the queue back on every page

**What I did.** On the owner's decisions on PR #55, reverted the page analysis that shipped the
dispatch queue only where a send could arrive mid-dispatch (`Direct.reentrant`, `mayReenter`):
the guard queues on every page again. Kept the short release mount errors, which the owner
approved. Amended `browser-direct.md` (dated) and research 73; re-measured the bytes.

**What I learned.** The queue costs the table app 30 B: 4 110 B (3 898 with the markup in the
HTML), against 4 080 without it. A guarantee that rests on an event list being complete is the
kind the owner refuses; a page must not stop because the list missed an event.
