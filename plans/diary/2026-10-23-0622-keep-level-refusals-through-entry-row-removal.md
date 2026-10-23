## 2026-10-23 06:22 CEST — Keep level refusals through entry row removal

**What I did**

Rebased the #319 worktree onto 1e4a56ec0 after the parallel #286 level
refusal change landed immediately before commit. Resolved the Cause and
Message conflicts by keeping the new level cause, approximation rule and
message, while removing only the platform cause. The eleven entry goldens
still pass the 284-transition audit against the rebased master. The Page
test retains its original enforced check and also checks an ordinary report.

**What I learned**

A final fetch before commit caught a change after the first green gates.
Keeping ownership-rule changes separate made the conflict precise: level
refusals remain real report data, and only the renderer override disappears.
The final locked gate must follow the rebase. No measurements were run.
