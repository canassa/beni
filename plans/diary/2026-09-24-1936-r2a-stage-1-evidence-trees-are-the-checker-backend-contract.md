## 2026-09-24 — R2a stage 1: evidence trees are the checker→backend contract

**What I did**

- `checker-v2.md` §13 is live on v1: `Dispatch.finish` converts v1's flat pre-order sites and
  parts into evidence trees (the one place that order is interpreted), and `Lower`, `Edges` and
  `Reach` read trees. `Lower`'s counting (`targetEvidence`, `externalEvidence`, `ownEvidence`,
  `valueEvidence`, the cursor) is deleted; counts live in `Dispatch`. The I7 assert runs last in
  `ModuleCheck.run` and reports `internal`, never a panic. Dispatch dump v2, dispatch bytes v2
  (verified acyclic on load), cache entry v3. CK-61 closed.
- Emitted JavaScript byte-identical: no `run/` or `emit/` golden moved, and the reviewer compared
  1 998 programs in four build modes against 9a931d7. The 27 `dispatch/` goldens were
  re-blessed in the new format and read one by one.
- The review caught a silent wrong answer the new converter introduced: past a 1 024-level cap it
  wrote `undetermined`, which `Lower` answers with structural `Basics.eq`. The cap is gone; only
  a cycle guard remains, and it becomes `internal`. Also moved the assert after every other
  error pass (a real `cyclic_value` gained a spurious `internal`).
- My decision, recorded in `checker-v2.md` §13.1 and `tests/pending/run/DeadMiscount.beni`:
  `check` now refuses v1's CK-30 miscount even in unreachable code that used to build and run.
  v2 removes the miscount at R7.
- Pending perf scenarios now judge on the child's CPU time: a concurrent build had made CK-40
  read GREEN on wall time (87 s / 162 s).
- Gates: 474/474 unit, 293/293 black-box, fmt-check; `test-pending` 75 RED, 0 GREEN. Bench check
  +1.3–1.5 %, emit −2 %.

**What I learned**

- Removing a guard exposes what it was hiding. The old depth-32 caps in `Reach` and `Edges` were
  why 9a931d7 refused the deep case at all; the new converter needed its own answer for depth,
  and "undetermined" was the wrong one because the backend treats it as permission to guess.
- Wall-clock ratios are not evidence on a shared machine. Measure the thing's own CPU time.
