## 2026-10-22 01:08 CEST — Omit imported unit arguments

**What I did**

Tracked #651 and changed JavaScript call lowering to read imported callees' immutable
BIR patterns through interface provenance. Direct calls now omit the same trailing
unit literals as local calls. Foreign siblings and function values keep their meaning.
Added development and release corpus goldens, proved both fail with the implementation
stashed, and added a runtime companion. Reviewed the affected goldens and added a
dated amendment to backend.md §6. All editing and validation used the dagon worktree.

**What I learned**

The build already holds the complete declaration facts before parallel lowering;
no interface format change or type-based guess is needed. A release fixture that only
reads a constant record field can fold even with the bad call arity. Passing the whole
record to a platform sibling exposes whether the initializer call itself was inlined.
