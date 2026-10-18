## 2026-10-18 03:45 CEST — slice 1 rebased onto c8fbf8bc9; schema-part units filed as #349

**What I did**

- The independent (GLM) review of #332 came back READY TO MERGE: its own builds of master
  and the branch reproduced byte-identical output trees on all five of its fixtures, and it
  confirmed the `emissionOrder` refutation of its round-2 note. One Low finding: slice 1
  records one unit per schema declaration while §9's unit list promises a unit per part.
- Filed the finding as **#349**, with the code map (`Lower.declaration`'s `.schema` route at
  `src/js/Lower.zig:2213`, the units loop's `twin_at`/`lift_at` splits, and the `Part` doc
  comment that already claims "for a schema, whose parts are its own"), the "no embedded
  module declares a schema yet" premise, and the two fixes as the owner's choice —
  `SchemaLower` draws part boundaries, or the unit list's bullet moves. Linked from the PR
  body under *Debt*.
- Rebased the four slice commits (`40c6ec4fb..3ae52cff9`) onto current `master`
  `c8fbf8bc9`; clean — the 42 new `backend.md` lines sit near 891 and 9650–9880, nowhere
  near the §9 amendments, and the branch never touched `run-hashes.txt`. Head now
  `b574c2c85`.
- Re-ran the byte-identity evidence for the new base under the shared lock, fresh
  ReleaseSafe builds of both sides (`master-wt` checked out at `c8fbf8bc9`), medians of 5:
  - `diff -r` of the three dev trees, source maps included: **empty**, and the trees'
    sha256 sums equal — dict 16 files/151 094 B, apiitems 43/757 985 B, corpus 59/552 537 B;
  - medians (`perf stat -e instructions:u`): dict 154 659 826 → 155 191 510 (+0.34%);
    apiitems 498 407 987 → 502 545 344 (+0.83%); corpus 402 455 326 → 407 467 018 (+1.25%);
  - `zig build gates` green (rc 0, `zig-out/scratch/oc/rebase-gates.log`); the run-hash line
    is the same pre-existing scenario miss (1 of 2689; corpus and browser 0 of 2544).

**What I learned**

- Re-run the tree diff after a rebase that crosses an emission-affecting commit, never
  reuse it: the new master re-recorded one fixture's run hash, so the old diff would not
  have covered the base that merges. Here the sizes happened to come out identical — that
  is a result to state, not a shortcut to take.
- The job script's diff loop pointed at `$W/out.*` while `measure2.sh` keeps the trees
  under `$W/measure/out.*` — the same latent bug as round 1's script, whose diffs were run
  by hand afterwards. The three diffs and the checksums were run by hand again; the script
  loop is to be fixed before it is reused next time.
