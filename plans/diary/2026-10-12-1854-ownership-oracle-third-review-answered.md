## 2026-10-12 18:54 CEST — ownership oracle: third review answered

**What I did.** Answered the third review of PR #65. The core now refuses shadowing and a let pins its
continuation's uses of a rebound name to the outer binding (both checkers had accepted a mismatching
program); the step lemma assumes the abstract environment covers the live uses and both checkers refuse
an unresolvable live variable; the axiom audit kernel-replays every constant and refuses skipKernelTC,
addDecl, run_cmd, implemented_by and extern anywhere under the package; the falsifier checks Lemma 6.7
on the real interpreter's call log and is two-thirds write-heavy; writes count only when they change an
array. A forked agent made generated declarations run (96 %), write the caller's arrays (33-35 %) and
see one array twice (15 %), and made the generator catch branch-closure, shared-roots, shadowing and the
third review's source holes; the older source sweep was not re-run on the final generator (time bound).

**What I learned.** A liveness set of variable names is only as good as the scoping it assumes: shadowing
silently re-pointed a live use. A crash in the shrinker had been counting a caught hole as missed.
