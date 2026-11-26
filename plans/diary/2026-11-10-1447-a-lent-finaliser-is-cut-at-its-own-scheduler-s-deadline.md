## 2026-11-10 14:47 CET — A lent finaliser is cut at its own scheduler's deadline

**What I did**

- Issue #2093. A fiber of scheduler `s` ran a `bracket` release that entered
  `Task.withScheduler s2` and waited. `stopScheduler s 1 done` did not cut it:
  `expireS` and `expiredFor` in `core/Task.beni` read only the fiber's slot,
  and the slot named `s2`. The repro failed on master with the deadlock exit.
- I asked the owner which deadline cuts such a finaliser
  (`scheduler-stop-lent-q1`). Cesar decided on 2026-11-10: both deadlines cut,
  the first that passes.
- `expiredFor` now also asks the deadline of the scheduler the fiber belongs
  to (new helper `expiredOf`). `expireS` selects the fibers that belong to the
  scheduler as well as the fibers lent to it. `countCut` counts the cut
  against the scheduler the fiber belongs to once its deadline has passed.
- Amendments: `transparent-effects-proposal.md` §17.5, `boundary.md`
  §9.8.14 (f), and the re-reading note in `ownership-checker.md` §24.8.
- Fixtures: `run/SchedulerStopLent` (red on master, green after, proved by
  taking out the fix) and `run/SchedulerStopLentBoth`.

**What I learned**

- When both schedulers stop, the stop of `s2` cancels the lent wait at once
  in its sweep (`boundary.md` §9.8.14 (d) step 1). Thus no deadline cuts
  and each `done` gets 0. The deadline rule matters only when `s` stops and
  `s2` does not.
- A change to a body under ownership words fails `check_test` until its hash
  in `tests/corpus/ownership/word-bodies.txt` is set again. A new helper that
  a worded body calls must be pinned too.
- A change to `core/Task.beni` moves the worker fingerprints of
  `emit/*/dedicated/` and the line ranges in `ownership/core.v2.unchecked`.
  A `-Dcorpus=ownership` bless does not rewrite `core.v2.unchecked`. Copy the
  new ranges from the gate log by hand.
