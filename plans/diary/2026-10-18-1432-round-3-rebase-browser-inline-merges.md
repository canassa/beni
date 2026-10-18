## 2026-10-18 14:32 CEST — round-3 rebase: the browser-inline merge

**What I did**

- The owner asked for a rebase after `master` moved past the slice again (#333, #346 and #334
  merged; #332 showed DIRTY, so CI did not run). Rebased the five commits from `c8fbf8bc9`
  onto `31958c4d9`; one conflict, in `src/js/Lower.zig`.
- The conflict resolution, both halves: master's **new code** stays — the `try l.viewPieces()`
  call between `declarations` and `exports`, and the `!l.name_used[index]` condition on the
  skip of an inlined declaration — and this slice's refactor is re-expressed through it: the
  `declarations(&declarations, &decl_units)` signature, the separate `tail` list for
  `exports`, and the unit-splitting body that reads `part.items` and splits at
  `twin_at`/`lift_at`. The other four commits replayed clean.
- Re-proved byte identity for the new base, one locked job, fresh ReleaseSafe builds of both
  sides (`master-wt` checked out at `31958c4d9`), medians of 5:
  - `diff -r` of the three dev trees, source maps included: **empty**, tree sha256 equal —
    dict 16 files/151 094 B, apiitems 43/757 985 B, corpus 59/552 537 B;
  - medians (`perf stat -e instructions:u`): dict 154 753 757 → 155 298 257 (+0.35%);
    apiitems 498 495 907 → 502 659 539 (+0.84%); corpus 402 649 995 → 407 700 010 (+1.25%);
  - `zig build gates` green (rc 0, `zig-out/scratch/oc/rebase3-gates.log`); the run-hash line
    has no new misses (corpus and browser 0 of 2610; the same pre-existing scenario miss, 1 of
    145), so no hash re-record was needed.
- The round's job script diffs the trees under `measure/` directly this time (the round-2 loop
  pointed at the wrong directory and the diffs had to be re-run by hand); the checksums are
  computed in the job.

**What I learned**

- Resolving a both-sides-changed function is two questions, not one: what did master CHANGE
  (semantics — here, a new call and a new condition, both to keep), and what did this branch
  REFACTOR (shape — signatures, list targets, unit splitting, all to keep). The conflict
  markers show both but do not say which is which; the answer came from reading what each
  side does with the lists, not from the merge.
- The `name_used` skip condition and the unit splitting touch the same loop, so a resolution
  that took either side whole would have silently dropped a master fix or a slice guarantee.
  A clean compile would not have caught it; the byte-identity diff and the emit goldens are
  what stand behind that claim.
