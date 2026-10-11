# Step 4: executable oracle results and stopping finding

The core checker was not changed. Exploration stopped at a core implementation
bug: `inferExpr`'s traversal case drops the step summary's `escapes`. This is
**not a demonstrated thesis soundness counterexample**. It contradicts the
implemented primitive's permanent-holder contract and gives an unexpected
accepted verdict. The independent interpreters currently implement `shared` as
identity, without an external observer, so this example's traces agree. That
observation limitation must not be mistaken for discharge of Unescaped.

`Fixtures.escapeTraversal` is the retained red test, expected **rejected**:

```text
xs = [0]
ignored = traverse range 1 initial 0 (i, x, acc =>
  published = shared xs
  acc)
push xs 9
```

Ordinary typing succeeds; the checker accepts. `Fixtures.escapeCall` performs the
same publishing through an ordinary declaration-table callback and is rejected,
showing the difference is traversal propagation. The fixed fixture's rejection
expectation is retained. `regressions/escape-traversal.log` records the failure.
The default CLI exits 1 before generation. No checker repair, rule weakening,
fuel increase, test deletion, or generator weakening was made.

## Runs completed before stopping

| Generator | Seed | Candidates/typed | Accepted | Rejected | Limits | Type/execution errors | Trace mismatches | Generator elapsed |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| v1 corrected | 20261011 | 1000/1000 | 415 | 585 | 0 | 0/0 | 0 | 61 ms |
| v1 old rule | 20261011 | 100/100 | 55 | 45 | 0 | 0/0 | 16 expected | 54 ms |
| v2 corrected | 20261011 | 1000/1000 | 519 | 481 | 0 | 0/0 | 0 | 60 ms |

The first fixed suite had 39 verdict tests, all passed, and every accepted case
had equal final values **and every read**. The final suite has 43 tests: 42
expected verdicts agree and the traversal escape regression is red. Two frozen
old-rule regressions additionally require acceptance+disagreement under the old
rule and rejection under the corrected rule. These checks are independent of
the random generator's future evolution. No additional exploration was run after
the escape finding. `lake build` compiles the final sources successfully.

## Reproduction

Enter `nix develop .#ownership` from the repository root, then run the following
from `proofs/ownership` with Lean 4.29.1.

```sh
lake build
.lake/build/bin/ownership 1000 20261011
# Expected exit 1: retained escape-traversal fixed regression.

.lake/build/bin/ownership 1000 20261011 --generator-only --generator-version=1
.lake/build/bin/ownership 100 20261011 --generator-only --generator-version=1 --old-rule
.lake/build/bin/ownership 1000 20261011 --generator-only
```

`--generator-only` explicitly skips the known-red fixed suite; it is not the
default and does not mean the complete suite passes. Version 1 is frozen in
`Ownership/OracleLegacy.lean` (LCG low-bit draws, five families); version 2 in
`Ownership/Oracle.lean` uses high-bit draws to avoid correlated Boolean choices
and includes publishing callbacks as a sixth family. The CLI arguments above
were used for generation before the finding; the explicit historical-version
and generator-only routing were subsequently compiled, not newly explored.

Generated old-rule counterexamples were not imported from T59. Independent
choices construct callback cells, sharing versus distinct cells, range length,
focus index, push value and map versus initialize. Sixteen candidates disagreed;
the two distinct structural failures (map and initialize) are preserved as full
AST and trace text in `regressions/old-20261011-{8,10}.txt` and as executable
programs in `Ownership/GeneratedRegressions.lean`. The other fourteen reports
were equivalent sharing failures with different constants/lengths. Both saved
programs are rejected by the corrected checker.

The reducer greedily deletes lets, chooses branch arms, removes list elements,
and simplifies traversal/focus, including inside declarations. Every accepted
reduction is independently ordinarily typed, ownership-accepted and
observationally disagreeing. It yields a local minimum for these reductions,
not a claim of globally smallest syntax. The frozen AST avoids depending on a
future generator version. Trace errors and fuel exhaustion are explicit failures,
never equality. A corrected observational mismatch immediately persists a
regression and stops exploration; an old-rule mismatch is expected only when
the corrected checker rejects the minimized program.

## Precision and completeness limits

The random grammar varies straight ANF chains, fresh/duplicate cells under nested
containers/records, captures shared by two closures, identity map callbacks,
branch/range accumulator loops and publishing callbacks. Acceptance exceeds 40%
in both completed corrected runs, so the oracle is not vacuous. It is a bounded,
biased grammar, not an exhaustive typed-program enumerator. General terminating
self-recursion, higher-order combinations and arbitrarily deep types are not yet
randomly generated. No claim is made about behaviors beyond this grammar.

`COVERAGE.md` audits every T1–T59 identifier, distinguishes projections from
full examples, lists all named variants and marks unimplemented applicable cases
as pending. Work on those pending cases stopped at the finding; they have not
been silently classified as impossible. Rejection can also be an inference limit
(`limit:`), separately counted in the generator. The fixed suite keeps its
intended verdict rather than adopting the checker's verdict. No hand-asserted
library rule was added: map, initialize, foldl and update remain ordinary core
declarations.

## Repository validation after the machine crash

`lake build` completed before the crash. The required `zig build gates` did not:
the unchanged `src/build_id_main.zig` compilation was killed while building with
the pinned self-hosted Zig backend. Its log reports 44 completed tests passed,
with the remaining graph blocked by that compilation. A retry reached 31 GB of
used swap and was terminated to protect the machine. A separate-cache compile
of the same helper, with no source edits, was stopped automatically after memory
pressure rose again. `-Dllvm` does not select LLVM for this helper; its backend
is hardwired in `build.zig`. No test or build rule was changed to bypass this.

Thus the production gate is **unverified**, not reported green. Local logs are
`zig-out/gates-crash.log`, `zig-out/gates.log`, and
`zig-out/build-id-isolated.log`. They are build artifacts, not committed files.

The owner subsequently directed that this is Lean work and no further Zig builds
are to be run. Delivery therefore uses the completed Lean validation; the Zig
gate is not a prerequisite for this PR under that instruction.
