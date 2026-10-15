## 2026-10-14 00:19 CEST — corrected ownership PR validation completed

**What I did**

Completed LLVM unfiltered zorg build gates on the corrected tree: exactly the
four known Mac failures, 1 292 passing and 15 skipped, matching native. Kept PR #87
as a draft because the subscription fold remains pending. Prepared the correction
commit and answers to all review findings; no merge.

**What I learned**

Both code generators agree on the resolved cases and rejected unsafe variants.
The copy-free subscription fold remains a pinned checker limit, not evidence of
real sharing. The final PR diff restores the platform and pre-existing hashes.
