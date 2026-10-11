# Step 4: repaired oracle and expanded core exploration

The final suite has **74 fixed verdict fixtures**, all independently ordinarily
typed and matching their intended verdict. The 19 accepted fixtures run both
interpreters and compare the complete `Trace`: final value, ordinary reads, and
external observer snapshots after every completed expression. All agree. Three
frozen freshness-rule counterexamples and two frozen traversal-escape controls
also require acceptance plus an actual disagreement under their respective old
rule, and rejection under the corrected checker. No expected verdict was changed
and no expected-failure routing was added.

The prior traversal defect was real implementation failure: a step could publish
a captured cell without returning it, and traversal discarded that escape.
`shared` now keeps actual values/references as program-lifetime external roots.
The corrected checker propagates escapes and rejects the write. With
`dropTraversalEscapes=true`, final values agree but **externalReads differ**:
the value observer still sees the old list and the in-place observer sees the
push. The minimized generated regression is
`regressions/old-escape-20261011-1.txt` and its frozen executable is
`GeneratedRegressions.escapeSeed20261011Index1`. The historical
`regressions/escape-traversal.log` documents discovery before the repair; its
red verdict and old observation limitation are superseded by these results.

## Corrected campaigns

All campaigns below used final generator v3, Lean 4.29.1, seeds listed explicitly,
and independently typechecked each generated candidate before ownership checking.
All accepted candidates executed successfully with identical complete traces.
Elapsed time is the generator's monotonic clock and includes generation, AST
uniqueness accounting, checking and evaluation, excluding process startup/build.

| Seed | Candidates/typed | Distinct ASTs within seed | Accepted | Rejected | Limits | Type/execution errors | Mismatches | Elapsed |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 20261011 | 20000/20000 | 4789 | 6363 | 13637 | 1665 | 0/0 | 0 | 5060 ms |
| 17 | 20000/20000 | 4816 | 6328 | 13672 | 1683 | 0/0 | 0 | 5368 ms |
| 271828 | 20000/20000 | 4783 | 6414 | 13586 | 1609 | 0/0 | 0 | 5126 ms |
| Total | 60000/60000 | not a union count | 19105 | 40895 | 4957 | 0/0 | 0 | 15554 ms |

Full per-seed metrics are retained in `regressions/campaign-v3-{seed}.log`.
Limits are a subset of rejected candidates, not additional candidates. All
observed limits are the deliberate higher-order recursive argument family,
`limit: higher-order recursive argument`. Type errors, execution errors and
interpreter fuel exhaustion fail a run rather than count as agreement.

Per-family totals below combine the three campaigns. Distinct ASTs are **summed
within-seed counts**, so overlap across seeds remains counted repeatedly. The
low distinct counts of shallow controls are explicit: total trials are not a
claim of 60,000 different programs. Depth is main-expression AST depth, not
recursion iterations or declaration-body depth.

| Family | Candidates | Summed distinct | Accepted | Rejected | Limits | Depth |
|---|---:|---:|---:|---:|---:|---:|
| anf-chain | 5074 | 5009 | 522 | 4552 | 0 | 3–27 |
| branch-traversal | 4963 | 30 | 2547 | 2416 | 0 | 5–5 |
| captures | 4985 | 60 | 2489 | 2496 | 0 | 5–5 |
| escape-traversal | 5000 | 45 | 0 | 5000 | 0 | 5–5 |
| fresh-nested | 4914 | 1568 | 1629 | 3285 | 0 | 6–6 |
| fresh-tower | 5083 | 2199 | 2468 | 2615 | 0 | 6–9 |
| identity-map | 4966 | 24 | 2548 | 2418 | 0 | 8–8 |
| indexed-chain | 5048 | 3594 | 1529 | 3519 | 0 | 6–19 |
| library-pipeline | 4952 | 1181 | 1268 | 3684 | 0 | 13–17 |
| once-many-wrappers | 5056 | 240 | 2856 | 2200 | 0 | 6–9 |
| recursion | 5002 | 420 | 1249 | 3753 | 0 | 4–4 |
| recursive-higher-order-limit | 4957 | 18 | 0 | 4957 | 4957 | 3–3 |

The ANF generator extends a typed environment at every binding and selects
existing cells below records and nested containers. Later operations can focus,
set, copy, publish, read or reuse those generated values. Chains vary from 1 to
24 extensions. Fresh towers independently construct cells down 1–4 nested
layers, optionally repeating internal references at each layer, then consume
through every layer. The pipeline family composes ordinary initialize, zero to
four conditional map stages, foldl and update on records containing lists. Input
records are fresh per callback or repeatedly capture the same cell; retained
source variants stress cross-stage sharing. Function factories return closures,
wrappers capture them, and direct call counts (1–4) contrast with map's many-call
position. Scalar recursive functions vary iteration counts, consumed accumulators,
consuming captures and retained original arguments. Indexed chains include empty
lists and negative/in-range/out-of-range indices. All these library operations
remain ordinary declarations; no map/fold/update-specific checking rule exists.

## Negative controls and reduction

| Final v3 seed 20261011 | Candidates | Accepted | Rejected | Actual disagreements | Elapsed |
|---|---:|---:|---:|---:|---:|
| `--old-escape-rule` | 20 | 12 | 8 | 5 | 19 ms |
| `--old-rule` | 20 | 8 | 12 | 1 | 12 ms |
| frozen v1 `--generator-version=1 --old-rule` | 100 | 55 | 45 | 16 | 92 ms |

The final frozen v1 campaign rediscovered 16 sharing failures through both map
and initialize. Reports use `legacy-old-...` names so the original indices 8/10
reports remain unchanged; the complete campaign is `negative-fresh-v1.log`.

Each disagreeing candidate was minimized while retaining ordinary typing,
ownership acceptance under the selected old configuration, and observational
disagreement. The corrected checker rejects each minimized result. The new
freshness counterexample is a deeper shared tower, not an imported T59 fixture;
it is frozen as `oldTowerSeed20261011Index7` and saved in
`regressions/old-v3-20261011-7.txt`. The original frozen v1 map/initialize ASTs and
reports at indices 8/10 are retained unchanged. The legacy low-bit generator is
explicitly frozen in `OracleLegacy.lean`; new exploration uses v3 high-bit draws.

The reducer is total and fuel bounded (1000 accepted reductions). It removes
lets/list elements, selects branch arms, simplifies traversal/focus, reduces
integers and indices towards zero, shortens traversal/recursive call counts,
and applies the same transformations inside declaration bodies. Every reduction
is independently typechecked and checked for accepted disagreement. This is a
bounded greedy reduction, not a global minimality claim. Corrected-rule findings
persist an AST/trace report immediately and stop that campaign; none occurred.

Corrected mode exits 1 on any accepted observational mismatch. Negative-control
flags intentionally exit 0 only when at least one typed, old-rule-accepted
program actually disagrees and every minimized disagreement is rejected by the
corrected checker. A corrected-accepted negative-control disagreement, absence
of any disagreement, typing error or execution failure exits 1.

## Fixed coverage and limitations

`COVERAGE.md` audits all T1–T59 identifiers and each named variant. Applicable
pending core examples from the prior audit are now implemented, including
returned/captured once wrappers, scalar recursion, independent initialization,
conditional record map edits, construction/reverse folds, history restoration,
empty-accumulator borrow, transparent wrappers, nested ordinary update calls and
scalar read-before-write ordering. Full runtime, TEA, opaque/module, dictionary,
schema, renderer and release protocols remain explicitly excluded; these tests
do not reproduce a full application. The reverse fold rejects earlier under a
conservative captured-consumption/many-call rule, rather than reaching the
thesis's final Dead edge. Other precise exclusions and shared projections are
listed in the coverage table.

The checker and interpreters have finite depth/fuel/summary bounds, and higher-
order recursive actuals and changing recursive shape/exclusivity are rejected
implementation limits. These campaigns are bounded and biased, not exhaustive
and not a universal soundness or library proof. There is no random recursive
data type, effects/runtime entry protocol, renderer or dictionary generation.

## Reproduction and validation

From `proofs/ownership`, with the pinned Lean 4.29.1 toolchain:

```sh
lake build
.lake/build/bin/ownership fixtures
.lake/build/bin/ownership oracle 20000 20261011
.lake/build/bin/ownership oracle 20000 17
.lake/build/bin/ownership oracle 20000 271828
.lake/build/bin/ownership oracle 20 20261011 --old-escape-rule
.lake/build/bin/ownership oracle 20 20261011 --old-rule
# all runs the fixed suite followed by generation:
.lake/build/bin/ownership all 1000 20261011
# frozen v1 is explicitly opt-in:
.lake/build/bin/ownership oracle 100 20261011 --generator-version=1 --old-rule
```

The executable and owned oracle/fixture modules build successfully; the fixture
log is `regressions/fixtures-v3.log`. Proof-module validation is recorded by the
parent's step 1–3 work. No Mathlib, paid tool, production compiler modification,
or Zig command was used for this repair, as directed by the owner. Historical
Zig gate crashes remain historical and are not represented as a green gate.
