## 2026-10-15 20:33 CEST — Compile-to-vanilla research

**What I did**

Worked on #172 from origin/master, read research 100–104 and P3, and built
research 105 with runnable prototypes under `bench/compile-to-vanilla/`.
Compared six dispatch representations across six app families, repeated and
varied shapes at four feature counts: 306 generated pages verified in Chrome,
1,188 retained timing samples. Added an independent owned-array edit experiment,
four table operations using research 29's vanilla/Solid 2 harness, and its
static-heavy page. Recorded raw samples, brotli growth fits, source hashes,
figures, reproduction commands and the proposal's proof obligations.
Preparing a PR for the issue's requested Claude review; it must remain unmerged.
The Mac runs the documented non-budget test steps; the Linux instruction gate
remains owed and is called out in the PR.

**What I learned**

Shared local factories and exact array edits are worth the next full-feature
experiment. Expanding a repeated dashboard to 64 instances cost 3,732 B brotli
against 491 B for a shared factory. At 10,000 rows, 30 edits cost 49.385 ms
through this experiment's simple generic keyed pass versus 3.605 ms as exact
edits, including layout. That does not compare against an optimized reconciler.
Small indexed dispatch and a shared signal graph won some synthetic byte curves,
so eliminating every runtime edge is not the right unconditional objective.
Real-click results were mixed; the report does not claim a new Conduit floor or
full parity. It recommends an equivalent Conduit ladder and adversarial lifetime,
ownership and dependency cases before any language or platform adoption.
