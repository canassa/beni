## 2026-10-31 02:15 CET — Integrate validated worker metadata

**What I did**

Pushed eb89c341f on PR #1304 after independent source review, Debug and focused
validation, and full unfiltered gates. The private artifact retains symbolic
suspension-site types/effects and nominal declaration heads without changing
Task execution or ordinary emitted programs. The schema-conversion integration
regression exposed temporary annotation allocations being mistaken for formal
binders; the producer now records the actual P2/P3 lexical binder scopes.

Measured the existing optimized 100k-line plain and method-heavy projects on
Dagon. All twelve baseline/candidate rows retain equal input hashes and inference
counters, with no diagnostics. Candidate medians are 308,254 and 296,972 LOC/s,
and its minimum is 296,138, above the 250k floor. Debug command checks cost about
6–10% more; the slow development backend itself misses the optimized floor on
the unchanged baseline, so the normal LLVM timing build was used once. Routine
implementation builds remain development builds. Retrieved and hash-verified
the complete provenance bundle before the agent removed its three worktrees,
branches and owned cache lanes.

Master advanced while implementation continued. Resolved the printer merge
conflict by keeping its common 128-level explicit-stack fallback and upstream
stack-budget explanation, preserving dynamic-import support and deep tests.
The merged tree is being validated before its integration commit.

**What I learned**

Annotation allocation ranges include schema-reading temporaries; declaration
and annotation identity plus the actual lexical binder scope is the authority.
A partial continuation artifact supplies evidence, not a checked continuation
body. The tail probe must omit unused ownership/escape/command summaries rather
than repeat their unmetered work. The typed queue, public worker launch and
remaining realm/Wire proofs stay gated; no budget is waived.
