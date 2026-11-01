## 2026-11-01 16:52 CET — review native constructor emission

**What I did**

Retrieved and independently hashed all 118 handoff files, including final source,
compiled tests and the Debug compiler. Applied the patch to its exact 6bb3f0f7e
base and reproduced tree e151a5a4397442d7782cc223567dcba64a62d772. Replayed
17 focused tests with the unchanged 1000 ms unit budget and all 23 relevant
ordinary CLI cases using Node 24.19. All passed without skips or leaks.

Reviewed fresh native authority before lowering and packed-unit adoption, the
strict Unit argument contract, retained versus evaluated initializers and the
closed native ABI fact. Found noncanonical positive fact bytes in the draft;
the fix rejects bytes 2 and 255, with actual before/fix decoder controls.
Reviewed the allocation-failure column transfer fix and shared pack encoder.

Applied the reviewed patch cleanly on deb1b262b and documented the available
constructor and unresolved cases in the user skill. The complete unfiltered
gates validate this new integration before acceptance. No performance acceptance
for this new tree follows from earlier measurements.

**What I learned**

Warm ordinary builds alone did not prove emitted-unit reuse; the dedicated
control actually adopts a packed native unit and denies a changed application
before adoption even when the native cache key remains eligible. This supports
the closed zero-role Program case. Callback execution, whole-entry completion,
worker launch, storage ownership and Wire remain unfinished.
