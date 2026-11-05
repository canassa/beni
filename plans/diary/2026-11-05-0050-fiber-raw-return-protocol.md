# 2026-11-05 — raw-return fiber protocol

The owner approved landing the zero-allocation protocol with the remaining size
work in a separate follow-up (#1907). Suspendable calls now use ordinary args
and construct bound compiler-written frames only after returning the sentinel.
A reusable pending buffer transfers frames to the iterative kernel driver.
Raw finalizers and normally called hooks remain in separate typed stores while
#1917 tracks checker precision; the prototype checker is saved in evidence,
not committed. Host-wake identity and cancellation, including self-halt during
registration, retain their fixtures. No user work enters the D3 Slot.

Integrated a02b9c83cb. Both appended cache tests were retained and affected pin
bodies re-read; only the ten justified protocol/shared-region pins change.
Array/Any/Kernel/browser bridge operations and their fences stay intact.
Only the S3 cap changes, to its exact measured 4150 B. S5 is 4630 with its
4633 cap unchanged. The fast-path allocation assertion is zero, red on P5.

The isolated typed split costs about 10.21 B per active finalizer and 86 B on
S3. Parked-fiber retention falls 448 to 168 B, non-parking loop points 10.42 to
1.46 ns; spawn+join timing ranges overlap. Snapshot changes describe the new
calling convention, never absorb the unrelated inherited emit mismatches.
New core unchecked helpers are named and justified under #1927; v1 ownership
is unchanged. Gate/overlap evidence and measurements live in
~/worktree-evidence/wd-fiber/p6/. No PR is merged by this lane.

Final capture ordering follows structural source traversal, fixing a byte
mismatch between packed and freshly checked core. Existing comparison/cache
fixtures caught it. The final exact S3 measurement is 4148 B and that is its cap;
S5 remains 4630 B with 3 B margin. The one full candidate gate run found four
additional build-test failures; their determinism fix, retired-completion
assertion and two release-name snapshots pass targeted verification, as do the
whole run/browser corpora and fiber-cost suite. The five inherited test failures
are retained as the comparison baseline; no second candidate full run is used.
