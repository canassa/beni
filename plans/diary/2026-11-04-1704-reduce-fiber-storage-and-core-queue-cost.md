## 2026-11-04 17:04 CET — Reduce fiber storage and core queue cost

**What I did**

Implemented fixed Cell storage for Task controls and runtime records, a typed
circular FIFO for Dispatch, scheduler/macrotask jobs and Queue items, private
array read/length/shared-write intrinsics, general allocation-only release
reachability, and a lazy platform hook bridge (#1719, #1857, #1858). Added
runtime, emit and ownership/capture-flip regressions. Saved the browser
integration patch separately for the DOM manager. Targeted checks pass.
No heavy jobs were started during the btrfs metadata incident. Candidate
gates and final measurements ran after the manager's disk all-clear.

**What I learned**

A shared array store must escape its payload; aliased describes a result
alias and does not describe storage retained after a unit-returning call.
Final reachability needed the allocation-only rule for unread top-level
mutable bindings too. The new guard exposed ownership v2's independent global
Ref.set discrepancy (#1866), preserved in the lane evidence. The manager
approved D3 and requested that this independent PR land before the intrusive
kernel/wait-list and continuation-protocol changes.

The disk all-clear arrived. The first measurements caught bundle growth, so
caps stayed unchanged while scheduler/slot/child facility guards were restored.
All existing cost and bundle caps now pass. Log-hook registration is separate
from runtime registration. The supplied exact-base gate log is reused. The candidate gate ran once;
added shape failures were reviewed and checked individually. The manager
allows either merge or rebase before the PR; this branch merges the tip.
Measurement details and the explicit 60-byte combined-harness bundle trade-off
are recorded in `plans/fiber-storage-evidence.md`.
