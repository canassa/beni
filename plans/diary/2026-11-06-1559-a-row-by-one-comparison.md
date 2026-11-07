## 2026-11-06 15:59 CET — a row by one comparison

**What I did.** Finished #2135. A `⟲` through a row stays at the record's place. A kept row now meets a field written through it. Every compare of a slot's words moved to `SlotWords`, and `rules_test` refuses a plain compare of `u32` runs anywhere else, and a new file reading a tree's kid by a word. `MovedReq` reads a callee's row at the frame's record instead of copying the words. `OneSet` lets a call's one-entry result at a row go to expansion. `BlockStep` takes concrete types from `BlockWords`.

**What I learned.** The 31 "closed twins that pass" were three causes, not one. Rows in `rf`'s `nondup no` came from the #1710 rule, which read a row as a type variable's slot. `mid`'s refusal came from `movedReq` copying `…{a,z}` beside the `.b` it holds, so one object was asked apart from itself. Seven `fold_cbw_*` remain, and they were never twins: `c = []` has a free element type in the open program and `L` in the closed one. A closed record with `c : List t` is refused on master too.

Relaxing a subtree held whole in the same rule looked harmless and pushed the 32-wide callback product past `ownership_summary_size`. The row alone is enough, so the subtree stays one set.

Same-layer imports are refused, so `SlotWords` could not sit under `Slots` or `Replay`: `WordRun` (L0) holds the literal compares and `StepWord` the row test.
