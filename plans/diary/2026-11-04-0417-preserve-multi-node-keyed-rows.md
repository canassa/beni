## 2026-11-04 04:17 CET — Preserve multi-node keyed rows

**What I did**

Fixed #1833 in master's browser runtime by skipping a range move before its
own first node. Kept the existing representation and lowering. Added browser
fixtures for two adjacent swaps and the reported append/rotate/remove/reverse
sequence. Both fail with the fix stashed and pass restored in happy-dom and
Chrome, development and release. Run hashes are now recorded automatically
by ordinary test runs (#875); this master has no test-run-hashes step.

Measured report 29's row operations against saved baseline and fixed output,
with 15 samples per operation and rotated development/release subject order.
Raw samples and validation logs are saved under
~/worktree-evidence/wd-master-rows/ on dagon.

Chrome Chrome/153.0.8010.36; Node v24.19.0; CPU AMD Ryzen 9 5950X 16-Core Processor. n=15 per subject/operation. Official report 29 throttles; rotated subject order. Script medians in ms [95% percentile bootstrap CI of median; 10,000 resamples, deterministic seed 1833].

| Operation | Dev before | Dev after | Release before | Release after |
|---|---:|---:|---:|---:|
| 01_run1k | 4.294 [4.189, 4.533] | 4.243 [4.215, 4.443] | 4.347 [4.325, 4.416] | 4.377 [4.314, 4.438] |
| 02_replace1k | 9.639 [9.357, 9.902] | 9.940 [9.419, 10.318] | 9.731 [9.655, 10.217] | 9.731 [9.517, 10.024] |
| 03_update10th1k_x16 | 1.706 [1.355, 1.970] | 1.645 [1.521, 1.792] | 1.871 [1.606, 2.006] | 2.020 [1.824, 2.137] |
| 05_swap1k | 1.376 [1.129, 1.497] | 1.402 [1.222, 1.656] | 1.356 [1.207, 1.456] | 1.500 [1.432, 1.899] |
| 06_remove-one-1k | 0.538 [0.523, 0.777] | 0.548 [0.518, 0.590] | 0.990 [0.958, 1.023] | 0.963 [0.842, 1.036] |
| 08_create1k-after1k_x2 | 5.424 [5.344, 5.573] | 5.448 [5.378, 5.664] | 4.905 [4.801, 4.918] | 4.888 [4.782, 5.280] |
| 09_clear1k_x8 | 21.858 [21.464, 22.613] | 22.911 [21.746, 24.983] | 21.461 [20.545, 22.664] | 22.000 [20.899, 22.643] |

**What I learned**

An adjacent swap can ask the row mover to insert a range before its own first
node. Doing so sequentially reverses its siblings; a later traversal then runs
past the range and throws. One node-identity comparison avoids the move.

All before/after median intervals overlap. Release swap's median nevertheless
rose from 1.356 to 1.500 ms (+10.6%); this run does not establish a speedup or
exclude a small regression. The new runtime work is one comparison per move,
with no new item-loop work. No geometric-mean parity claim is made.

#1834's direct-JavaScript probe changes row.j, which master neither emits nor
reads. Documented the ABI reasoning on the issue and left it to the typed port,
as the manager directed. No master ABI extension was needed.
