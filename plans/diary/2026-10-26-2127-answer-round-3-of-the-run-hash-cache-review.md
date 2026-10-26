## 2026-10-26 21:27 CET — Answer round 3 of the run-hash cache review

**What I did**

- Rebased #904 onto master d331cb7da (the ownership v2 differential in the
  gates). One conflict: master put `runV2Parity` between `runProgram`'s
  doc comment and `runProgram`, and the branch edits that comment. I moved
  the function above the comment, so the comment stays with its function.
- R3-1: added the reviewer's test, "a lists pass that does not crash as its
  golden says writes no digest". Under the `LISTS_EARLY` mutant (the lists
  pass records before its crash check) it is the one red test of the suite;
  on the clean head the suite is green.
- R3-3: the corpus walk names every record file and the index it meets,
  counts them, and fails once at the end of `fixturesOf` with the
  `git ls-files` command that lists them. The `differentialPages` doc says
  "run-hash cache".
- Gates green on the fix cache, 170 s, 0 misses.

**What I learned**

- The run-hash summary prints nothing when no program ran. A gates log with
  no counts line after a harness-only change is the design, not a lost line:
  read `tests/run_hash_summary.zig` before calling it missing.
- A mutation check belongs in the same job as the gates: apply it with a
  script, run the suite, `git checkout` the file, run the suite clean, then
  the gates. No edit may touch the mutated file while the job runs.
- A refusal that stops at the first file costs one walk per file after a
  rebase that leaves hundreds. Count and name them all, fail once.
