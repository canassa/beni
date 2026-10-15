## 2026-09-18 12:16 CEST — S8-fix: the constraint chain was cubic, and the bisect lied

**What I did**

- Found and fixed the M2 defect S8a measured (`beni check` cubic in time *and*
  memory on `--pathological=constraint-chain=n`, killed at 29 GiB at n = 1000).
  The cause is `Solve.attachConstraint`: §6.3's `flex` row re-attaches every
  deferred constraint to the variable it is already on, the name is already in
  the set, so the JOIN path rebuilt the whole set — copying it, joining a site
  list with itself, and redirecting every index to the copy of itself — to
  produce the set it started from. O(set) per obligation, and link k of the
  chain defers k constraints over a set of k. The fix is a three-comparison
  guard that returns the caller's index when it already lies inside the root's
  range under `c`'s name (A.81).
- Test: `tests/blackbox/abuse_test.zig`, "an unannotated constraint chain costs
  one merge per link, not one per constraint" — two chains (64 and 128 links,
  `--core-root=nocore`, so no core number is in it), counters read back out of
  `--self-profile`. Fail-first proved by stashing the fix: `expected 63, found
  2143`. It pins all six dispatch counters, not just the merges, because the
  cheap way to make merges linear is to stop registering obligations.
- Evidence (ReleaseFast, `--iterations=5`): n = 100 **51.2 → 6.4 ms**, n = 1000
  **killed → 459.9 ms**, n = 2000 **never attempted → 1 967.7 ms**. `beni check`
  peak RSS n = 400 **3 307 → 70 MB**, n = 1000 **29.2 GiB → 388 MB**. The
  100 159-line corpus is unmoved (73.2 → 72.2 ms check). Four gates green,
  `test-blackbox` twice.

**What I learned**

- **The bisect pointed at the wrong commit and the counters said so.** S6b
  (`5dfc082`) is where RSS crosses whatever threshold you bisect on, but
  `8081b5f` — its parent, "good" — already reads 21 / 132 / 935 ms at
  n = 100 / 200 / 400, which is cubic too. A.75's redirect map multiplied the
  constant by ~3.3; it did not introduce the exponent. A bisect over a
  *continuous* quantity finds where it crossed your threshold, not where its
  growth rate changed — for a complexity defect, fit the curve on both sides of
  the "good" commit before believing the bisect.
- The brief's other framing was wrong the same way: obligations did not go
  linear → quadratic at S6b. `8081b5f` reports 5 064 at n = 100 against HEAD's
  5 099. n(n+1)/2 obligations is what A.57 asks for on this input and matches
  `constraints_promoted`, which has been n(n+1)/2 since S3. The S3 row's 1 014
  is a *different* checker, and reading two counters from two commits as one
  series is what made a correct quadratic look like a regression.
- The counter that actually localises this defect is `constraints_merged`: it
  counts set rebuilds, and on the chain it was n(n+1)/2 + n − 1 where the honest
  number is n − 1. A rate that should be per-declaration and reads
  per-constraint-per-declaration is the whole signature, and it is visible from
  outside the binary through `--self-profile` — which is why the test is a
  counter assertion and not a timeout.
