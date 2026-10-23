## 2026-10-23 08:08 CEST — removing the path cut stops at a ten times slower core (§16.7 (c))

**What I did.** Built (c) on `ownership-remove-path-cut`. `k_limit` is gone, and paths keep
their nodes and steps as run-long slices. The depth is a `u32`, the block's path length is a
`u32` (summary 36, interface 17), and the growth mark has a 30-bit pending boundary and a 33-bit
guard. Two routes that the cut had hidden needed fixes. A forwarded supply now composes at a call
that grows its parameter's variable (`GrowingFunctionSlot` grew `[*]` in every round). The
canonical form works again across casts (`shapeOf` had passed `entries`). `ownership/PathCut`
pins #286's hole, red on master. No ownership verdict changed, and core checks clean. I stopped
under rule 10. Core's check as user code is about ten times slower (2.2 s to 23.5 s, safe build),
so a `build_test` case exceeds its 120 s hang guard under the gates. The cause is F2's cast
boundaries, which end a region: `Schema.shapeOf`'s `Node` and cast alternations grow from under
300 entries to about 5 100. Recorded as a dated stop amendment in §16.7. The owner decides how to
bound the alternation.

**What I learned.** A `u128` growth mark copied through an optional struct read as `0xAA…` in a
self-hosted safe build. A `u64` layout avoided it, and I did not reduce the case further. The old
`gMake` clamp at 126 had hidden any such garbage. On a loaded dagon, `OwnershipAnnotationDag`
on master took 76 s of mostly system time (#845).
