## 2026-10-17 16:56 CEST — apply the naming step at a real linked write

**What I did.** Follow-up of the review of PR #285 (finding 1, note 2), stacked on #308. `StatementChecks/LinkedWriteInstance.lean` is the reviewer's `Probe285b` as a package module: a reachable state with two link components, the pre-state `Invariant` as a kernel proof, the real demand and the real `writeLinked` of the push, `after_named` by `LinkedWriteStep.linkNamed_after_writeLinked_liveCells`, and `second_constrained` for a conclusion that is not vacuous. The plan's *View links* open line no longer lists the written-storage premise and its derivation as open; it lists what is. Build: 93 jobs, 9,523 constants, 60 files, 3 `sorry`.

**What I learned.** The three instance modules add about 850 constants and 3 jobs to the build and cost nothing in the campaigns: every count of `ownership ci` and the falsifier stayed master's on A and B, as a proof-only change must.
