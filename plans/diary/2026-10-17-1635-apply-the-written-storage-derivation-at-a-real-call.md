## 2026-10-17 16:35 CEST — apply the written-storage derivation at a real call

**What I did.** Follow-up of the review of PR #276 (finding 1, note 2), stacked on #307. `StatementChecks/CallDerivationInstance.lean` is the reviewer's `Probe276` as a package module, reusing the control's program and cache entry: the call-site `Invariant` with the link is a kernel proof, the real `applyCall` run succeeds by `cbv` on `isOk`, and `covered` applies `CallDerivation.linkedWritesCovered_of_applyCall` with every hypothesis discharged. The plan's *Summary pre-state* open line, `COVERAGE.md` and `README.md` now name the all-variables limit of the derivation (a literal or a field argument is outside it). Build: 92 jobs, 9,307 constants, 59 files, 3 `sorry`.

**What I learned.** The instance built at the first try once its `open` lines followed the namespace: a reviewer's probe that compiled on the same tree ports as a module with only the namespace and the `#print` lines changed.
