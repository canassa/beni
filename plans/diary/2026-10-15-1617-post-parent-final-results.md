## 2026-10-15 16:17 CEST — post-parent final results

### What I did

Repeated the complete three-way comparison with actual master including #135.
Measured dd38d162e and the updated feature implementation 86e237fc2; subsequent
master/feature documentation-only merges produce identical compiler binaries,
verified by SHA-256 after rebuild. The final report names d10749f70 and b9e227f9a
and retains the exact timing revisions and binary hashes. All compilers are
LLVM ReleaseSafe, jobs 1, no cache; twelve balanced runs after warming, with no
builds, tests or sampling during timing.

Kept both branches' concurrent benchmark documentation, leaving the PR diff
limited to the field-read work. The compiler implementation is unchanged by
the parent and documentation merges. Profiles remain labelled with their actual
36a879521 revision, whose checker source is identical to the final implementation.

### What I learned

Before/current-master/follow-up checking medians, milliseconds:
- Annotated 63k: 47.68 / 62.43 / 34.16.
- Unannotated 63k: 46.43 / 146.02 / 40.90.
- Original 100k: 67.20 / 68.28 / 67.62.
- Updated realistic corpus: 6.47 / 6.58 / 6.89.
- 100k plus TaskBoard: 66.56 / 68.02 / 68.50.

Both synthetic cases remain faster than pre-#126. Master now includes #135, so
191.6%/105.5% recovery refers to its remaining net overhead. The corpus ranges
overlap; the report does not turn their small differences into precise recovery.
All runs' exits and streams match. Full updated self-hosted and LLVM checks,
109 successful dump comparisons, and cold/warm late-dispatch replay pass.

Bike Wars's six stale recorded hashes are present on unmodified master on this
host too. Reverification produces identical hashes on master and this branch;
recorded files were restored and no existing golden/hash update is retained.
The nested counter confirms the rank-3 decision requested by the second review.
The assertion limitation is stated accurately as root postconditions, not an
independent transitive-closure proof. #135 is merged; #140 remains unmerged,
with its Linux instruction-budget gate still owed.
