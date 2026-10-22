## 2026-10-22 19:21 CEST — Capture the pointer handler scalar flag

**What I did**

The expanded O1 audit found two entry refusals in PointerEvents. Its pointer
handler passed the whole model to a helper that only needed track, retaining
the rows and log lists across dispatch. Bound the Bool outside the closure
and passed it to the helper. The checker is unchanged. The fixture passes
fresh-cache ownership enforcement, its existing DOM transcript is unchanged,
its run hashes are refreshed, and the locked full gate passes. The existing
scalar-message handler that really retains a written list remains refused.

**What I learned**

A crossing message type does not make a handler's retained environment
crossing. Capturing only the scalar a handler uses expresses the intended
value snapshot without retaining unrelated model lists.
