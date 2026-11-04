## 2026-11-04 04:17 CET — Port typed browser row reconciliation

**What I did**

Ported keyed, positional and Show reconciliation to Rt.Rows against the frozen private ABI. Persistent state depends only on keys; Any.unpackOpt keeps lookups raw, retained sites retarget current operations and scope, and rows update their raw item payload before restating. Added a compiler-built library correctness driver, platform-module development/release emit goldens, and a generic-key refusal fixture. The real-producer browser regressions remain separate until the shared kernel is wired.

**What I learned**

Literal optMatch arms allocate no callbacks after #1830; the two existing trimmed-pass closures are each once per pass. The driver passes 5,792 typed steps in development and release and exposed #1833 in legacy and master: inserting a multi-node range before its own first node reverses it. The typed swap skips that invalid move. The real producer reproduces the bug in happy-dom and Chrome, development and release. Master's stale descriptor identity is #1834 and is assigned separately. A retained site's key type cannot change in source because generic markup keys are refused; the mismatch path is defensive ABI coverage, while item/environment and Show epochs need real-producer coverage. Performance claims await report 29's wired-producer harness.
