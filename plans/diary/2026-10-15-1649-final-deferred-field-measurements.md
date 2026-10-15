# Final deferred-field validation and measurements

After preserving numeric-alias bridge ordering, the full self-hosted and LLVM
`zorg build test test-blackbox fmt-check beni-fmt-check` runs both pass. Their
temporary files used case-sensitive APFS; the normal cache directory was
restored. The complete successful dump comparison and cold/warm dispatch
replay still match master. No existing golden or run hash changed.

Fresh balanced LLVM ReleaseSafe medians (12 runs, jobs=1) for pre-#126,
master including #135, and the final checker bf6ccdde4 respectively:

- Annotated 63k: 49.64 / 64.51 / 35.55 ms checking.
- Unannotated 63k: 47.81 / 147.50 / 42.60 ms.
- Original generated 100k: 67.87 / 69.94 / 69.02 ms.
- Updated realistic corpus: 7.35 / 8.36 / 8.17 ms.
- Generated 100k plus TaskBoard: 67.77 / 69.06 / 69.41 ms.

The synthetic cases beat pre-#126 by 28.4% and 10.9%. Corpus ranges overlap;
no precise recovery fraction is claimed for them. Fresh native sampling of
the final source puts unknown-receiver rank adjustment at 98/1328 checker
samples (7.4%), versus the earlier profile's 55.4%. Real obligation attachment
and draining remain; eager record assumptions would still change results.

The third Claude review found no blocking defect in the numeric bridge fix.
Both optional points have answers: the duplicated guard remains identical,
and bare numeric eq/compare cannot have a passing saturated nullary call
because each requires another operand. Existing explicit-call cases cover
successful numeric comparisons. The final report retains samples, source and
binary hashes, profile limits and regression proofs.

PR #140 stays open and unmerged. Its x86-64 Linux instruction-budget gate is
still owed; this Mac cannot run it.
