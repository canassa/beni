## 2026-11-04 19:30 CET — Land the review fixes of the record oracle slice

**What I did**

#1874 (slice 1 of #316, record objects in the Lean oracle) merged before its review fixes were pushed. I moved the fix commit onto `master` with a cherry-pick, on branch `ownership-record-assign-review`, and opened #1880 for it. The commit makes the checker's field read refuse an index past the record's fields, adds two doc comments, and adds two probes for an update that writes every field: `allFields` (accepted) and `allFieldsCaptured` (the old holder captured whole afterwards: refused, runs 7 and 11). I answered the nine review points on #1874. I opened #1871 and #1872 for slices 2 and 3, and I summarised the slice on #316.

**What I learned**

- A rebase merge on GitHub gives the branch's commits new hashes on `master`. A local `git rebase origin/master` of the old branch then tried to replay a Markdown commit that conflicted with a later edit of the same lines. A cherry-pick of only the new commit was clean.
- The review's main point was a misreading: `liveCellsWith` filters capture paths only under the `once-live` negative control. The corrected checker reads `liveCells`, which `recordLiveCells` mirrors. It is worth reading the control flag before reading a filter as a rule.
