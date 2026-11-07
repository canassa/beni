## 2026-11-01 23:25 CET — attribute the fold certificate's cost

**What I did.** Measured #1560 on master `212f366bb` with a self-hosted ReleaseSafe beni (safety allocator off, the default since #1611), `perf` from nixpkgs, and instruction counts so that load did not matter. FoldCertificate's harness passes were v1 check 0.21 s, v1 dump 0.37 s, v2 dump with `--ownership-rewalk-check` 6.4 s, and v2 check 1.3 s. The v2 dump alone was 4.6 s. Of the flagged dump, cold runs were ~72 %, and ~53 % was cold runs solving callee groups again. Re-walks were ~27 %. `assertRewalks` and `checkInduction` cost the same. The warm solve was ~19 %. Then I fixed three slow primitives, with records, verdicts and dumps unchanged:
- `Shape.Widen` grew a dense union-find to the highest node id on every widen, which is uncharged O(node table) work. It now takes pooled tables.
- `Calls` and `Shape.closure` made fresh stamped columns per call. They now use the pools.
- `FixedDict` stored MultiArrayList nodes. It now stores whole nodes.

Result: 36.5G → 27.3G instructions for the flagged dump, and 6.5G → 4.6G for the v2 check. 372 of 372 single-file ownership fixtures dump byte-identical. The cold-run design is #1623.

**What I learned.** Under the self-hosted backend, `MultiArrayList.items` and `get` are real calls that compute every column pointer. So a hot loop that reads a column per iteration pays for the whole slice each time. A fresh `stamped.Column` or dense array per call is #1191's quadratic again, and `--self-profile`'s `scratch_slots` showed it: 54.6M slots made for one check, 21.9M after. Most of the rest is `KappaRead.dagFacts`, which is in #1545's lane. The 1 s budget is reachable for a one-producer fold fixture, but not for FoldCertificate itself: its v2 check alone is 0.92 s for 743k records.
