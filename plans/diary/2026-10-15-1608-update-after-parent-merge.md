## 2026-10-15 16:08 CEST — update after the parent merge

### What I did

The owner merged #135 while the follow-up was under review. Its rebased commits
made #140 conflict with current master. Merged master dd38d162e into the feature
branch, retaining the existing follow-up changes in the four conflicting hunks.
No checker implementation file differs from the already reviewed 36a879521 tree;
the update incorporates master's other cache, ownership, example and test changes.
This is a branch update, not a merge of PR #140.

Full self-hosted checks pass with case-sensitive temporary files, and LLVM unit,
corpus, ordering, determinism and formatting checks pass. Updated the comparison
worktree to actual master including #135 and rebuilt both LLVM ReleaseSafe
binaries, each with a separate cache. The final timing comparison will use that
post-#135 master, the pre-#126 compiler, and this branch.

### What I learned

The review's optional frame question is now measured: both dots in
NullaryLateOrder begin at rank 2; site 9 resolves first at rank 3, then site 7
at rank 2. Both owners have rank 1. Retained the temporary counter patch and
trace; this counter binary is untimed. The mutation assertions check dependency
roots, not an independent transitive-closure proof; the construction invariant
and owning-boundary walk remain the basis of the shortcut.

The newly promoted Bike Wars case reports six stale recorded hashes on this
host on unmodified master too. Independently re-ran and recorded those six
cases under master and this branch, verified runtime transcripts, compared all
new hashes byte for byte, and restored the tracked hash files. All six match;
no hash update is retained. The rest of the corpus matches the recorded hashes.
New direct dumps and cold/warm late-dispatch replay also match actual master.
The Linux instruction-budget gate remains owed for this follow-up.
