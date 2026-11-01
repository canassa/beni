## 2026-11-01 23:10 CET — Generic entry review fixes

**What I did**

Updated the boundary and backend contracts for entryKinds and synchronous beni
entry runtimes. Fixed library builds that incorrectly required a runtime for the
top Program, with a corpus fixture shown failing before the fix. Removed unused
entry-plan state and stale worker-design pointers, and corrected the developer
skill. Added development and release entry goldens and a root-fiber fixture whose
init yields before printing.

**What I learned**

A nominal Program callback invoked as a discarded binding before a unit result
can lose its suspension continuation. The reduced case and emitted output are
saved on dagon under ~/worktree-evidence/wd-basefix/ and tracked separately in
#1618. The requested unit init with a direct invocation resumes correctly.
