## 2026-10-22 15:00 CEST — Remove test instruction budgets

**What I did**

Implemented the owner's #740 decision on dagon: removed per-test instruction
counting, grants (including #720's), the test-budget option, host refusals and
the reference CPU pin. Added a 120-second watchdog for each test and each corpus
case, with named timeout failures and cleanup of child process groups. Updated
CI to run gates directly, the timing report to omit instruction columns, and
the active documentation and testing skill. Historical reports carry dated
supersession notices; earlier diary entries and recorded benchmark evidence stay
intact. All edits, builds, tests, commits and pushes for this work use the dagon
worktree. No performance measurements or local Zig commands were run.

**What I learned**

A corpus kind is a suite, so its workers must guard individual cases rather than
share a deadline. Hardware counts also served optional performance scenarios;
their independent counter now lives in test-perf, outside the runner and gates.
Algorithmic compiler work bounds, runtime scheduling limits, IR instructions and
benchmark measurements are separate from the removed test policy. Budget-only
tracking issues are superseded; independent compiler-performance defects remain.
