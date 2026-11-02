## 2026-11-02 11:45 CET — Worker launch and cleanup review

**What I did**

Included suspendable twins in worker discovery, the unchecked launch gate,
static-entry checks and realm traversal. A nested twin now discovers its child
entry and refuses DOM access there. Worker Interrupt replies cancel awaiters;
close deadlines settle calls and event readers; native abort reports Abandoned
to close waiters, including an owner finalizer. Late load errors after a failed
open are ignored, and each worker defect is reported once without Chrome's
message wrapper.

Kept worker entry runtimes lazy, restored Rt's exact source, and wired its
private stop functions into each worker-bearing module instance. Ordinary
browser output is compared with the origin/workers binary, including release
source maps. Added explicit transport/bootstrap failure fixtures and observed
finalizer events before cancellation's terminal reply. Stashed the fixes and
ran the new regressions against the original compiler to prove them red.

**What I learned**

A declaration's direct-body live bit does not describe all emitted code. Entry
safety checks must visit the suspendable body as well. A native close timeout
also ends the heartbeat, so it must settle the transport itself. Public entry
hook and check-gate fencing remains #1678; no public Log API was added.
