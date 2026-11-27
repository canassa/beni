## 2026-11-27 15:17 CET — timed fixtures ordered without timer races

**What I did**

The branch CI was red at 127cce0419 on `run/CellRunsOnWays` (release), and
#2728's on `CellRunsOnWaysLive`, `SchedulerCloseRoot` and a timeout of
`EvidenceDagBuildDepth32`. I reproduced the first under load (1 bad run in
200 at 64 parallel Nodes), and with two `--import` preloads: one adds a
random delay to every `setTimeout`, one busy-waits 0–30 ms before each
`setTimeout` and at the start of some microtasks and immediates (a model of a
loaded machine). Over the 134 `run/` fixtures that sleep or use a timeout,
the stall model failed thirteen; I fixed them all by giving each an order the
runtime guarantees: the side that went first yields (`Task.yieldNow`), the
finaliser a stop must cut sleeps 10 s, and `SchedulerStopping`'s release
waits for a `Deferred`. The v3 dump of each is the same byte for byte; the
gates' v2 parity wanted one known line for the new `Deferred.complete`. After
the change: 0 bad of 20 runs each at 30 ms stalls, 0 of 10 at 60 ms.

`EvidenceDagBuildDepth32` is the checker v1: the parity pass's
`dump --ownership-both` takes 14–17 s there, v3 0.4 s (comment on #2715).

**What I learned**

- A Node timer's start is the time of the `setTimeout` call, so a 1 ms timer
  set 4 ms after a 5 ms one fires second. Timers of one duration keep the
  order they were set in. A fiber's `yieldNow` resumes on the microtask
  drain, before any timer, so "yield against a timer" is a guaranteed order
  and "1 ms against 5 ms" is not.
- `Task.stopScheduler` sets its deadline timer in the teardown microtask,
  after the caller's next `Task.sleep` has set its timer. Three fixtures
  depend on that window (19 ms and 49 ms); they are #2730.
- The random-delay preload is too harsh: it breaks the equal-duration order
  that Node keeps. The stall preload is the one that models load.
