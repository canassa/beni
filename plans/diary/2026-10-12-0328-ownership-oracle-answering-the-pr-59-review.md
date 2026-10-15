## 2026-10-12 03:28 CEST — Ownership oracle: answering the PR #59 review

**What I did.** One commit per review item:
- `ci` fails when fewer than 30 % of accepted programs write.
- The soundness theorems now take `check p = .ok _` under the corrected config (they were false for a mutant config), and `summary_sound` gains its uniqueness hypothesis.
- `lake build` audits the axioms of all 335 theorems against a pinned list of four `sorry`-dependent ones.
- `borrowed-supply` is reported under both checkers.
- Every required control has a fixed probe, so `ci` no longer depends on the RNG stream.
- A higher-order family (wrappers that pass their callback on, callbacks that escape or require exclusivity) and per-row hit counts reach the callback rows. Eight more mutants became flags: three are required, two are probe-only, three are known gaps.
- COVERAGE claims softened as listed.

**What I learned.** Under summaries the `borrowed-supply` line is live — it rejects about 20 programs per seed — yet none of those disagree; liveness in verdicts and observability are different questions. After the generator change the cross-check finds 68 differing verdicts, 3 of them in the per-call checker's favour, none unsound. The xreq rows are covered three times over: published xreq, the edge, and the callee's own exclusivity check under σ. So their mutants change no verdict.
