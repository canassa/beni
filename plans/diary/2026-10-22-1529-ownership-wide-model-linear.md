## 2026-10-22 15:29 CEST — ownership: a wide model in its width, not its square

**What I did.** Took #716. Profiled the ownership phase on the research
dashboard (callgrind, ReleaseFast) at N = 64 and 256 and ranked lines by
their excess over linear growth. The 501M under `entryFn` was the walk of
`update`'s and `view`'s functions, not the entry: six separate width ×
width loops around a `case` whose arms each write one field of the model
(the closed split, the read-off of the base use, the arms' join, the holder
scan over locals and uses, the entry's demands against the model's other
paths, and construction pairs with `except` operands). Each is now done
once or skipped by an index that asks the same questions in the same order.
Phase against `master`: 621M → 202M at N = 256, 91.4M → 67.8M at N = 64;
every output hash, golden and verdict unchanged; core and Conduit tests
flat. Added `ownership/WideModelArms` (its report 4 438M → 2 517M). Found
and filed #754: `master`'s core ownership dump is 2.4× #693's.

**What I learned.** Interning order is part of the output: a memo must
compute each entry at the moment the unshared walk first did, and an index
may skip only queries that answer null and touch nothing. Forcing the
indexed paths everywhere under `-Downership-full-cross-check`, with an
assertion against the direct path, turned the whole corpus into the test.
A records-with-lists model is still quadratic through the per-entry spine
conditions of `update`'s result, which #693 already named as a format
change. The fast paths cost core +25M until they were limited to wide
declarations. A ReleaseFast build for the host CPU emits SSE4a, which
valgrind cannot run: measure with `-Dcpu=x86_64_v3+sha`.
