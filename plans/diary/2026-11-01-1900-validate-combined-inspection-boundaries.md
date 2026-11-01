## 2026-11-01 19:00 CET — validate combined inspection boundaries

**What I did**

Retained the first combined gate failure. Two content failures were exact old
expectations: a legacy-plan writer now appends the specified empty role section,
and a realm-source corruption test still expected private format 21 instead of
22. Updated the full expected empty section and that version literal. The
corruption test still targets and verifies the same realm-source column and
retains every mutation, repair and warm-cache assertion.

Two unit CPU limits also failed in that run. Replayed the identical failed ELF
and shard with the unchanged 1000 ms limit: both shards passed 97 tests with one
skip; the fixed-Slot test used 455 ms CPU and native attestation 518 ms CPU.
No budget, body or assertion changed for those tests. The full unfiltered gate
must pass before accepting the new source tree.

Finished independent component replays. Solved-provenance main13 plus seven
infrastructure checks and all52 CLI checks pass. The convenience wrapper's
standard-runner argument and injected blackbox unit-budget errors are retained;
corrected invocations follow the pinned runner and actual build recipe. Role
component nine standalone checks and32CLI cases pass without failures or leaks.

**What I learned**

Appending diagnostic evidence requires complete validation and precise legacy
expectations, not suffix truncation. A wrapper failure is not a compiler defect
or permission to waive a budget. Frozen source/binary mapping and the original
build graph determine which invocation is valid.
