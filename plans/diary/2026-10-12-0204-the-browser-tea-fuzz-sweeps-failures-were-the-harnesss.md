## 2026-10-12 02:04 CEST — the browser/tea fuzz sweep's failures were the harness's

**What I did.** Ran `zig build fuzz` on `origin/master`: 21 `browser/tea` failures, none in
`browser-direct`. Every one was the test harness, not the platform or the compiler. Five
projects (Counters, TwoPrograms, TypedKeys, ConduitEditor, ConduitTour) failed their message
types dump, and ConduitReader listed five programs where it mounts one, because the sweep dumped
`.` in the worker's shared world, which holds the modules earlier cases left; the project's
modules are now dumped from a directory of their own. Fifteen `Defect*`/`Http*`/`StorageFaults`
pages "did not replay themselves": every happy-dom page shares Node's global object, and a
`--fuzz` build installs `__beniFuzzSend` only when none exists, so the replay sent `Boom`
through the first, already stopped, page and nothing happened. A closing page now deletes the
globals it set (`tests/blackbox/page_fuzz_test.zig`, *a page that stopped hands nothing to the
next*). Then DefectReleaseThrows seed 27 differed at the load: 33 bursts of `Start` leave 99
throwing releases, whose teardown ran past the fuzzer's five settle turns into the next page.
The root was `settle`: one real timer turn, while core's scheduler runs 64 tasks a turn and goes
on in a `setImmediate`, so under happy-dom what a step showed depended on where the timer fell.
`settle` now waits until no `setImmediate` is left (`browser/tea/SettlesManyFibers`: 2 000
fibers from one click, 128 shown before, 2 000 after; it passes in Chrome too). After the
fix the full sweep is green, development against release.

**What I learned.** A wrong verdict from the fuzzer looked like a platform defect each time,
and was the driver each time: shared global state, and a settle defined by wall-clock luck.
The driver's compile cache again reached 116 000 entries after one sweep, and pruning a
directory that size costs a page ~85 million instructions, which pushes `ClockStops` and the
page fuzz tests over budget whenever their records are stale — the cost I first blamed on my
own change. The pruning, not the sweep, is the thing to fix.
