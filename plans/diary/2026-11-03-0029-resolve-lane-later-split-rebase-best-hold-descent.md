## 2026-11-03 00:29 CET — resolve lane: Later split, rebase, best-hold descent

**What I did**

- Split `Later.zig` (L9 after the rebase) out of `Resolve`. It holds a holder's later uses: `liveOnce`, `liveAt`, `usedAfter`, `footprintReads`, and `effectMeets` from `Holders`. Nothing changed in the output: the ledger is byte-identical apart from paths, and the oracle and the cost table are identical.
- Rebased `own2-cost-resolve` (22 commits) onto `own2-cost-values` `51421cbf1` and force-pushed it. The layer table took the values lane's numbers, with this lane's files placed on them. Resolve's pass loop kept the values lane's `Forest.Entries` loop and appends jobs. `footprintReads` reads the reads by the tree (now charged) and the writes by binary search. Both lanes grew `Subtree` to 360 lines against a target of 350, so `PlaceBelow.zig` (L2: `slotsBelow`, `familyBelow`) was split out of it. The near-limit test keeps the values lane's bounds. `EvidenceDagBuildDepth32` has no v2 limit any more, so v1's artefacts at `w6`'s two `w5` arguments are now known entries.
- Built the best-hold descent (`Descent.zig`, L10). `Resolve` moved to L11 and every layer above it moved one place. A holder whose value is a DAG has one hold for each node, at the node's least path. A kid whose subtree has its own later uses answers for that subtree: liveness is asked once there, and each hold below it is met once. Test 5: 40 478 demands' records at d = 8 and a limit at 10. Now 249 / 281 / 313 at d = 8 / 10 / 12, with the witness `t_d.0…0`. Ledger: one witness changed (`HolderIndex`, now v1's text), and no verdict changed.
- Dropped 52 `ownership-v2-known.txt` entries that no longer occur. They are this lane's r2a gains. The run corpus failed on them once its other failure was gone.

**What I learned**

- A subtree answers for itself only when every use above it reads all of it or none of it. A call whose footprint reads part of the subtree (`readMB r = List.length r.m.b`) must be descended. Probes `scripts-cr6/oc/s6/N5CalleeField` and `N6Accepted` pin this.
- *Verdicts* puts an exact hold before an approximate one. Discovery order had been doing that by accident (`withinOne`'s `holder.z` against `holder.a[*]`). The descent now has to apply the rule explicitly at one use of one holder. Its memo must also tell a path below a `[*]` from one that is not below a `[*]`.
- Test 26 is not about holders: `callWrite` makes one demand for each written path. Test 20's generator `w12` no longer reaches the limit (growth 18 536), because result trees made `w_k` cheap. It needs a new generator, which is the values lane's work.
- `Forest.text` uses `std.heap.smp_allocator`, so the single-threaded `wasm_test` builds do not compile. That is the values lane's defect, posted on #1714.
- Not done: step 3 (projection by route sets). It changes how `Proj` holds tags, from one list to a set, in `Relation`, which is at 1 300 of its 1 300 lines, and in `Entries`. Steps 4 (25 passes, 20 goes to the values lane) and 5 (GroupRotate) are also not done.
