## 2026-11-24 14:44 CET — Manager: v3 rounds, inline retirement lanes, and a pause

**What I did**

I ran the ownership v3 loop and the browser-tea retirement lanes from the manager seat, then paused at the owner's request.

v3 (branch `ownership-v2-design-review`, draft PR #2585, never merged):
- **Round set CE–CH on `87e622129c`:** the four blind rounds found 0 faults, but code reader CR7 found #2653.
- **#2653:** lane fix206 fixed it (forks before a mask; no `send` exempt; `Task.scope` counts as masking; a code-derived list of the ways the runtime masks, lends or runs a stored function). Lane fix205 fixed the safe-build panic #2651. Head `44a25c6b38`.
- **Round set CI–CL on `44a25c6b38`:** the four blind rounds found 0 faults, but code reader CR8 found #2674, the seventh hole in a row in kernel §13 item 12 (d).
- **#2674:** lane fix213 fixed the class, not the path: a started closure may run a hosting function only where nothing else it runs, at any depth and in any order, can mask or lend the fiber. Its reviewer found an older hole of the same kind (a masker in cell-free top-level data), also fixed.
- **Precision:** lane prec211 won `SubscriptionTapFold`, `Debug.todo` arms and kept closures without adding a single copy. 60 root lines went from refused to accepted, none the other way.
- **Oracle:** lane harn214 made `run.mjs` set aside log clock fields, and report a TRAP only when the plain build does not throw the same error.
- **Head at the pause:** `2e4ddf9559`, not yet tested by a round set.

Master:
- **Records written in place:** #2656 (release kept a call that writes a record in its callee), #2659 and #2665 (captured-field reads of local functions and lambdas), #2668 (a closure that names a local declared after a suspension), #2678 (the release renamer refuses an undeclared name).
- **browser-inline:** #2655, #2660, #2664, #2666, #2670, #2673, #2680 and #2683. TodoMVC builds. Pages that build: 192 → 200 of 364.

**What I learned**
- **Don't ask for the seventh point fix.** Seven rounds in a row found a new path into item 12 (d). Asking for a class fix with a single summary per closure was the right brief earlier; I should have written it at the third hole.
- **The owner's line on safe programs is the checker, always.** "I don't want you working around safe programs with .copy(), fix the checker instead", and v1 is not to be changed because it is being removed.
- **Check a premise before handing a lane a decision.** I told fix205 to copy master's v1 words for `Dict`, and master's `Dict` has none. Since #2657's real path is v3 judging `browser-inline` on the branch, the master merge waits for that.
- **A decision delegated under the decide-what-follows rule should be written on the issue.** That way the owner can reverse it; #2662 was taken that way.

Decisions waiting for the owner: #2654 (page teardown and masked fibers), #2657 (the four inline pages on the branch), #2681 (an effectful choice of arm).
