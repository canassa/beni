## 2026-10-15 10:52 CEST — rebase the ownership fix for merge

**What I did**

The owner authorized merging PR #124. Rebased it onto master's diary split,
converting its three appended entries into individual files without changing
their text. The only conflicts were modify/delete conflicts for the old diary.
Confirmed that compiler source, core, platforms, tests and bridge evidence are
identical to the reviewed and measured tree. Reran the four local test steps:
1,300 passed, 15 skipped, only the same two known macOS case-folding failures.
Pushed the reconciled branch for fresh hosted checks before the rebase merge.
The main workspace's unrelated work was left untouched.

**What I learned**

A PR prepared before the diary split must migrate only its added entries;
restoring its old diary would reintroduce the file master deliberately removed.
The ownership campaign remains applicable because none of its code or inputs
changed during the rebase. The supported-host hardware-budget gate remains owed.
