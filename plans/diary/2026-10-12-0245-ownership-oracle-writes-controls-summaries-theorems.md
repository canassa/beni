## 2026-10-12 02:45 CEST — Ownership oracle: writes, controls, summaries, theorems

**What I did.** Answered the read-only review of `proofs/ownership/` in five commits. Generator
v4 replaces the v3 `anf-chain` (0 accepted programs with a write) by a general family: 3173 of
4918 accepted general programs now write in place over three seeds. The review's seven missed
mutants and five summary-row mutants are `--mutant=` flags and required controls
(`ownership controls`, `ownership ci`), each caught by the generator alone on seeds 20261011,
17 and 271828, each with a fixture. The checker now publishes per-function summaries (§3.7:
use, res, xres, xreq, calls, supplies, guards), symbolic in function-typed inputs, reused only
where every guard answers the same; the per-call checker stays as `Reinfer.lean` for
`--cross-check`. `Soundness.lean` states summary soundness (clause 2 repaired), map's derived
summary and the main theorem with a configuration invariant; the demand tests and the builder
allocation are proved, three named `sorry`s remain.

**What I learned.** The per-call checker had a real defect: a recursive call inside a
traversal step used an empty summary and accepted a program that prints 8 by value and 11 in
place; it is a limit now, with a fixture. Under summaries the review's `borrowed-supply` rule
is subsumed (the caller re-checks translated writes and supplies), so that control runs
against the per-call checker. Supply bits must be re-checked where a step ends — the thesis
does not say where an accumulator's bit is established. Forwarding a callback to another
declaration is still untested by the generator.
