## 2026-09-18 13:04 CEST — S8 closed on a second machine: rows, A.81, report 19

**What I did**

- Resumed from `plans/static-dispatch-resume.md` on a new machine (`dagon`,
  Ryzen 9 5950X, 32 threads, 31 GiB) and took §2's option (b): a "machine 2"
  heading in the results file, every C0 side re-taken here, M1a/M1b left
  N100-only. A rebuilt at `c870e9a` is 13 253 080 B here against 13 317 664 on
  the N100; nobody has explained the difference and report 19 §16 says so.
- **S8a** (`d9e1b02`): M2–M5, M7–M9, the `eq`/`compare`/`order` split in
  `bench/size.mjs`, `c1/R5` and `c1/R6` with checksums agreeing. Validated by
  re-running M2 at n = 200 and both runtime variants myself before committing.
- **S8-fix** (`98fe87a`, A.81; the implementer's own entry is the one above):
  M2 found the branch cubic on the unannotated chain. Stash-proved the counter
  test (`expected 63, found 2143`) before committing.
- **S8a′** (`0680e08`): M2 re-taken ABBA on the fixed binary — exponent down by
  exactly one in time and space, n = 1000 441 ms / 411 MB — plus the correction
  of S8a's "regression since S3" reading, and M3/M4/M5-checksum identity across
  the fix established by diff rather than asserted.
- **S8b**: report 19 (`docs/design/research/19-static-dispatch-spike-results.md`,
  1 025 lines). Validated by a script that checks every number on a
  `results:NNNN`-citing line against the cited range (82 checked, 5 unmatched,
  all five false positives or cited elsewhere on the page), a hand trace of
  seventeen headline figures, and a read of §0 and §15. One edit of mine: the
  closing question said "5–6×" from the brief's draft where §4 measures
  4.4–6.5×.
- Filename discrepancy owed by the S8 brief's decision (1): plan §7 names
  `19-static-dispatch-spike.md`; the report is `19-static-dispatch-spike-results.md`.
- The spike is complete. **The branch does not merge**; the adoption decision is
  taken on `master` after the report is read. `../beni-s1` and `/tmp/rf` are
  left in place on this machine.

**What I learned**

- **My bisect was wrong and the implementer's curve-fit was right.** I bisected
  on an RSS threshold, got S6b, and briefed the fix as "a regression since S3
  in A.75". The implementer built the "good" parent, found it already cubic,
  and corrected the brief. A manager's diagnosis in a brief is a hypothesis;
  the brief should say so, and "confirm the cause before you fix" is the line
  that saved this one.
- **A measurement slice earns its keep by being allowed to fail.** S8a's rule
  was "no `src/` change, stop and report" and it reported a 29 GiB kill rather
  than working around it. Had M2 been re-taken only at the n the N100 rows
  used, with the S3-era numbers cited for the rest, report 19 would have
  priced a bookkeeping bug as the design's cost — or missed it.
- **Re-taking the C0 side on a new machine was cheap and paid twice**: M3 and
  M4 came out byte-identical across machines, which the report can now state
  as machine-independence instead of assuming it.
- The manager-workflow memory did not travel with the repo; the resume
  document's §5 was enough to rebuild it. Anything a future session needs to
  drive the work belongs under `plans/`, not only in a per-machine memory.
