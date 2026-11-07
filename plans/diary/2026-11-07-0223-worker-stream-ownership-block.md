## 2026-11-07 02:23 CET — Worker streams and ownership boundary

**What I did.** Specified owned Trusted Types policies, the cycle-free Worker
stream operations and event-only cancellation before implementing them. Built
the raw-ABI streaming prototype and Chrome fixtures for policies, release-driven
credits, concurrent writers, list-view normalization, application/transport
failure, cancellation during admission and forEach, and event unsubscribe while
calls remain live. Kept and fixed two release failures: cross-module private
queue-field encoding and receiver-only Options field renaming. All targeted
runtime cases passed. All 23 ordinary scoreboard rows are unchanged; worker
page/download grow 7243→8115 / 3649→4209 B brotli, recorded on #1679.

The full gate run completed red: ownership catalogue/pin work remains, the
runtime's affine chunk consumption hits Task/host-summary precision gaps, and
13 browser cases have 15 new v2 verdict differences. I did not bless the valid-
call rejections or add an exemption. Tried the one Task.onExit factoring; its
captured work closure gives held-operand instead. Saved the reduced case and
options in evidence/ownership-decision.md and the prototype patch. Stopped the
full Chrome run and its orphan driver groups to release the lock; Workers had
not started. Targeted saved-master runs reproduce both ChildProcess sleep
failures, so those are inherited host failures. No PR opened while blocked.

**What I learned.** The raw Task ABI's callback summaries cannot currently show
the scoped lease lifetime that Task.bracket enforces. Declaring a consumed
chunk makes that gap observable; runtime success alone does not justify
weakening the ownership contract. Worker protocol fields also need to stay with
their representation owner; separately compiled Options projections cannot
assume identical private field names.
