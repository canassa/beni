# 106 — Rendering growth from real TEA source

*2026-10-15. Research for [#172](https://github.com/canassa/beni/issues/172), superseding
105. [Generator, source/output examples, protocols and data](../../../bench/rendering-design/README.md).
Compiler `3cca64d`, built ReleaseFast on azathoth; exact identities are retained.*

## 0. Answer

**For this catalogue, prioritize compiler-recognized factory sharing, using C's
local reducers as the starting point and B as the comparator.** At mixed **N=8,768**,
C is **478.85 kB brotli**, B **497.03 kB**, and handwritten-style vanilla
**48.43 kB**. C's advantage over B is only 3.7%; the 9.89× gap to vanilla is much
larger. Vanilla shares configurable factories; the prototypes still emit a
factory for each source component. C with factory sharing remains an unmeasured
compiler hypothesis; the references establish the opportunity, not its savings. Erasing messages is not automatically worth
duplicating arm-specific wiring, and explicit cells have no demonstrated size
advantage here.

The [standalone HTML report](../../../bench/rendering-design/report.html) contains
continuous lines joining actual measurements toward **512 kB brotli per curve**,
local slopes, range-specific intercept/slope/error fits, family comparisons and
downloadable data. The mixed-app crossings are measured: TEA **579.19 kB at
N3,888**, A **516.68 kB at N5,840**, D **553.70 kB at N5,840**, B **524.09 kB
at N9,264**, C **525.61 kB at N9,616**, and vanilla **525.74 kB at N100,352**. Different crossing counts are not
same-size application comparisons; the fixed-N comparison above is.

**The full family sweep is still in progress.** Direct exhausts host memory at
mixed N1,728 before the target ([#203](https://github.com/canassa/beni/issues/203));
no size is invented for that failed build. The webpage distinguishes crossings,
unfinished curves and compiler limits. This follow-up measures size only.

For the original three-seed mixed N32 sample, C costs **7.29 kB**, versus
**11.82 kB TEA, 17.06 kB direct, 3.89 kB vanilla, 8.39 kB A, 8.13 kB B and
8.82 kB D**. C removes 38% of TEA's rendering bytes there: runtime alone falls
3.51→1.79 kB, app increment 8.31→5.51 kB. This compares reachable platform
support with a pure-sandbox prototype, not full platform parity.

## 1. What was actually generated and proved

Ten structures have their own typed models, message types, reducers and views:
keyed action lists, validated forms, conditional tabs, nested helpers, recursive
comment trees, counter/toggle clusters, sortable tables, modals, input filters,
and derived summaries. Vary fields, labels, nesting, validation thresholds,
step values and which state a message changes. Compose shuffled prefixes at
**N=1,2,4,8,16,32, with seeds 17/101/2027**. Mixed and ten homogeneous families
produce **198 apps, 2,079 component instances and 396 real release builds**.
Both `browser-tea` and `browser-direct` compile exactly that source.

The experimental lowerer consumes the real compiler's public BIR. It computes
writes from reducer result records, reads through expressions/helper arguments,
and conservative recursive dependencies. No catalogue entry supplies dependency
sets. Root admission requires byte equality with the generator and a pure-call
allowlist: component separation comes from construction, not general ownership
analysis. Outside sources are rejected.
[Examples](../../../bench/rendering-design/examples/) retain source, BIR,
read/write witnesses, ownership witnesses and all four outputs.

| Direction | Actual executed mechanism |
|---|---|
| A: partial evaluation | Specialize reducer arms; DOM callbacks call local actions without constructing messages; schedule intersecting read/write consumers. |
| B: static reactivity | Keep TEA messages/reducers; instrument actual branch writes with dirty bits; emit static consumer calls. |
| C: local reducers | Keep TEA messages/reducers; closure routes directly to its instance; run that instance's guarded bindings. |
| D: explicit cells | Typed action/transaction proposal; owned cell setters and dynamically tracked binding reads. [Source form](../../../bench/rendering-design/examples/list/Shape0.cells-proposal.beni.txt). |

All four share a run-once DOM backend and inferred edit journal, so the direction
comparison isolates state/update wiring. Vanilla is independently written and
shares shape factories with configuration. Solid has independent list/form ports
using its actual JSX compiler, signals, projection selector and keyed `For`.

## 2. Growth, including which shapes hurt

All numbers below are **rendering bytes**, excluding core/List/Task/Schema/Http
and other core spans. Exact source-map attribution deletes core spans, including
inlined ones, then recompresses the rendering response. Full executable bundles,
not the resulting attribution fragments, are validated. Normalize every candidate
with Terser 5.51.2; retain original compiler-release prices too. Brotli quality 11;
raw/gzip and incremental prices are retained. Excluded owned-array helpers cost
137 B brotli standalone. Reclassifying all unmapped spans in a mixed N32 sample
changes prices by ≤164 B without changing rank ([sensitivity](../../../bench/rendering-design/results/sensitivity.json)).

![Mixed stress growth](../../../bench/rendering-design/results/stress/graphs/mixed-growth.png)

Large-range fits from the current measured endpoints, seed 17:

| Mixed direction | Actual N range | Fitted intercept, B | B/shape | RMSE, B |
|---|---:|---:|---:|---:|
| Today TEA | 512–3,888 | 1,241 | 147.77 | 2,777 |
| Today direct | 512–1,152 | 5,214 | 205.29 | 657 |
| Vanilla | 512–100,352 | 3,127 | 5.20 | 533 |
| A: partial | 512–5,840 | 10,737 | 86.77 | 985 |
| B: static | 512–9,264 | 5,616 | 55.96 | 1,005 |
| C: local | 512–9,616 | 6,170 | 53.70 | 2,437 |
| D: cells | 512–5,840 | 7,874 | 93.57 | 1,313 |

**The small-app Solid comparison reverses under growth.** For lists, C is smaller
at N512 (23.60 versus 24.79 kB), but Solid is smaller at N768 (26.11 versus
34.41 kB). At N9,632, C is **400.25 kB** versus Solid **71.21 kB**. The form
crossover lies between N336 and N512. Both Solid ports share factories; their
larger fixed runtime stops dominating these repeated-shape workloads.

Ranges differ because curves stop at their own target or compiler limit. The
HTML report also separates small, medium and large fits. These fits describe
observations; they do not supply missing points or predict a failed build.

**These slopes measure varied repetitions of ten templates, not new-feature
cost.** Ranking may change on real applications. An intercept is a fit, not the
runtime floor. Mixed curves flatten when all families appear. Seed ranges are
not confidence intervals. [Full fits](../../../bench/rendering-design/results/fits.md)
include residuals, which are large for the mixed linear approximation.

Original N≤32 per-family slopes, brotli bytes per added varied instance
(three seeds). The live HTML matrix updates the larger common measured windows:

| Shape | TEA | Direct | A | B | C | D | Vanilla |
|---|---:|---:|---:|---:|---:|---:|---:|
| Keyed list | 135 | 236 | 101 | 78 | 58 | 107 | 7 |
| Form | 121 | 206 | 97 | 74 | 55 | 98 | 7 |
| Tabs | 126 | 195 | 81 | 72 | 67 | 83 | 7 |
| Nested helpers | 136 | 265 | 92 | 91 | 65 | 94 | 7 |
| Recursive thread | 116 | 216 | 116 | 107 | 85 | 109 | 7 |
| Counter/toggle | 93 | 148 | 73 | 62 | 50 | 82 | 7 |
| Sortable table | 152 | 271 | 113 | 84 | 61 | 119 | 7 |
| Modal | 140 | 223 | 92 | 84 | 63 | 100 | 7 |
| Filter | 168 | 286 | 115 | 86 | 61 | 128 | 7 |
| Derived summary | 160 | 286 | 120 | 94 | 68 | 124 | 7 |

![Slope matrix](../../../bench/rendering-design/results/graphs/slopes.png)

In the original sample, filters/summaries drive today's growth: collection traversal, captures and
consumer wiring accumulate. A still pays for summary updates and recursive
helper dependencies; recursion barely improves over TEA. Recursion is C's
largest slope too. D adds subscriptions without eliminating the underlying
binding machinery. Vanilla's near-flat family slopes expose another missing
optimization: shared component factories parameterized by configuration.
These compiler candidates still emit distinct factories per source module.
[All family curves](../../../bench/rendering-design/results/graphs/family-growth.png)
include today's output; Solid appears only for its two actual ports.

## 3. Correctness and limits

The original campaign validated behavior before pricing the large extension.
The stress extension measures bundle size; it does not claim every enormous DOM
was exercised. Timing artifacts from the earlier campaign remain archived, but
are outside this size-only follow-up.

**1,422 minified pages were checked; 1,394 passed.** All four directions,
vanilla, TEA and the 36 Solid pages matched the exercised TEA observations.
Checks include first/last instances, every instance in mixed N32, rejected inputs,
batched edits and surviving row identity. Twenty-two separate lifetime probes and sixteen complete large-list
checks passed. **Direct fails 28 nested-helper/mixed pages**: its visit invariant stops
dispatch, [#189](https://github.com/canassa/beni/issues/189); failed interactions receive no speed result.

## 4. Proof obligations and the hard case

The compiler must prove message non-observability before A erases it; compose
`Html.map` routing; preserve update order and simultaneous record RHS semantics;
anchor helper reads to the correct instance; prove array uniqueness/no escaping
snapshots before mutation; prove key stability and operation provenance before
local DOM edits; and preserve controlled inputs, branch/row disposal and defect
stop behavior. Exhaustiveness and static types remain the real checker's job.
Factory sharing also needs equivalence modulo configuration, fresh instance
state/captures and preserved nominal boundaries. Effects must retain managed
lifetimes and typed host failures; these pure apps do not demonstrate that extension.

**Hardest: an edited row in a filtered, sorted, recursively nested view whose
parent derives a summary and whose callback outlives a branch.** A changed field
can change membership, order, ancestors and callback captures. Keep general reconciliation and conservative
consumer fallback when the proof is absent. Even a proven DOM edit does not make
a source `List.map` O(1); skipping that traversal needs a further key/index proof.

## 5. Prior art, migration and the confirming experiment

[Actual shared-example compiler outputs](../../../bench/rendering-design/prior-art/README.md)
show what to copy: Solid's run-once template and accessor consumers; Vapor's
`renderEffect`, `createIf` and controlled-input model; Marko's numbered instance
scopes, `_let` setters and statically wired consumers. Do not copy server
resumability into this browser-only comparison. Solid **2 rc.9** here costs about
21.9 kB for the list and 13.1 kB for the form; these are not the old Solid **1.3.3**
Conduit runtime's 5.4 kB.

From direct, first compare B and C within closed constructor-routing regions
using the same run-once factories. Retain the general fallback for escaping messages
and shared state; reuse ownership/edit analysis, controlled inputs and lifetime
checks. Price A/B specialization per region instead of assuming more static
analysis always means smaller output. No language change is required for C.

**One confirming experiment:** lower complete Conduit at six cumulative feature
stages with B, C, and C with factory sharing, retaining its typed host services.
Compare actual rendering bytes against today's TEA at every stage, with identical
minification and accounting. Require equivalent DOM/interaction transcripts,
including alias preservation and changing handler payloads. C must remain smaller
than B on the complete app, and factory sharing must reduce C's final app/wiring
account by at least 20% without increasing its runtime account. These are proposed
acceptance criteria, not estimates from repeated templates. Failure rejects the
corresponding bet; no new language surface is justified by these results alone.

The limits apply once: this is a finite catalogue of pure sandbox shapes, not a
feature-complete Conduit port or a general proof of the lowerer. Cross-component
writes, asynchronous effects and arbitrary stored messages remain unexercised;
Solid's older Conduit has feature differences. The proposed cell surface is not
implemented in beni. The extension measures large bundles directly; it does not
turn repeated templates into a prediction of real feature growth. Do not adopt a
design from these curves alone. No repository gates or suites were run.
