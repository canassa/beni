## 2026-11-05 17:30 CET — a latched cancel reaches the child process

**What I did** (worker `node-process-spawn`, PR #2044)

- The `@claude` review of #2044 found that `ChildProcess.run`'s release relied on the wait's
  canceller to signal the child. I reproduced the gap: a fiber cancelled while masked, then
  restored around `run`, left a `sleep 1000` child running, and `Task.cancel` did not return.
- Fixed: the release calls `stop` itself (it sends the signals once, whoever comes first), and
  `stop` does nothing when `spawn` threw. Added `run/ChildProcessCancelledLatched`, which hung
  before the fix. Updated `boundary.md` §9.14 (d), (e), (h) and the effects amendment.

**What I learned**

- `Task.callback` does not call its function when an interrupt is already deliverable
  (`Task.suspend`, `deliverable fiber`): the fiber unwinds at once, and no canceller exists. A
  primitive that starts a host resource before it parks must release that resource in its
  finaliser, not only in its canceller.
- A plain cancel of a fiber that is ready after a `Deferred.wait` is delivered at that wait's
  return, before the next call. Only a mask, then `Task.restore`, carries a latched interrupt
  into a later wait.
- A new `run/` fixture that completes a `Deferred` needs a row in
  `tests/blackbox/ownership-v2-known.txt`: v2 checks the write into a cell and v1 makes no such
  demand (`OwnershipV2Differs` otherwise).
