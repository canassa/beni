## 2026-10-22 01:06 CEST — Enum cycle conditionals

**What I did**

Tracked #652, reproduced the pending EnumCycle golden as red, and added a
release-only path from flat literal decision fans to conditional expressions.
Promoted the pending golden, added a cross-module arm-piece golden and a run
fixture for strings, integers, characters, lazy leaves and single scrutinee
evaluation. Documented the narrow exception to §7's switch threshold.
All builds and checks run in the dedicated dagon worktree; no output-size or
speed measurements were taken.

**What I learned**

The switch's one discriminant read becomes several equality tests, so a
nontrivial scrutinee must be bound before the chain. Once the case is an
expression, existing single-use inlining fuses the cross-module arm piece
without another optimiser change. The historical pending golden also needed
refreshing for runtime output that had changed since it was written.
