## 2026-10-29 19:46 CET — ownership v2: symbolic projections through the fold

**What I did**

- #1199, stacked on #1196. A symbolic leaf's projections are occurrences again in a folded call
  read. The read now owes `summaryExcl` (`excl c`) for each symbolic arrival at a summary path.
- A caller's `apart` or `sep` through `⟲` now reads that side's cells from the actual's preimage,
  never from a recast's shallow cells.
- Repro A and Repro B are now two-level calls: they refuse at the caller and accept with distinct
  lists. Added the probe #1196's decision 1 owed: a callee that writes deep and answers shallow
  rests on its `sep`, which the shared `k` refutes.
- Each of the two pieces, removed alone, fails a witness.

**What I learned**

- One-level probes cannot show this fix. The vacuous pass was in the caller's instantiation, so
  the witnesses have to make the second call.
- The deleted scratch directory came back once more mid-task. Every write to scratch now starts
  with `mkdir -p`.
