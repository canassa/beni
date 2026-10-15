## 2026-10-14 12:52 CEST — Finish the ownership oracle's closure checks

**What I did**

Combined the two ownership branches with current master in an isolated
worktree. Fixed transitive once-capture demands through higher-order calls,
added its failing-before fixture and search moves, and repaired recursive
closure description/honesty and actual heap typing in the step premises.
Rebuilt the independent-baseline mutant runner and retained counts and
original witnesses. On dagon, pinned every descendant to CPUs 0–7: all 62
source edits on three 20,000-program streams, bound 2 on every edit, and
bound 3 on four targeted edits. The union catches 47; 12 have written masking
arguments; three remain search gaps. The 20,965,567-program corrected bound-3
run, CI, all seeded controls and three 100,000-sample falsifiers pass.
Injected a crash after the first mismatch and verified failure plus evidence
retention. Replaced stale coverage/results counts and prepared the committed
head for the authoritative audit and final checks. Used zorg for the compiler
gates: only the four owner-identified macOS failures remain.

**What I learned**

Matching an outer closure does not describe its inner code or affinity. A
higher-order call must demand captured callbacks' own writes recursively,
not only the outer callback's capture row. A dead close source still needs
its actual heap type. Random generation's call of an unknown function join
masks a lost-cell defect; enumeration retaining the join as data reaches it.
A trace-only oracle cannot expose every false exclusivity certificate, and
an unchanged checker verdict cannot test an interpreter-copy edit. These
limits and the three remaining sorries are explicit in the reports.
