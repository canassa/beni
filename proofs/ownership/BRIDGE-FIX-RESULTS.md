# Ownership result soundness fixes — 2026-10-15

> Test policy, 2026-10-22: per-test instruction limits, grants and reference CPU
> requirements were removed (#740). Each test or corpus case now has a
> 120-second wall-clock hang guard. Older counts and budget references below
> describe historical evidence, not a current gate or an outstanding grant.
> Performance remains the job of `test-perf` and `bench`.


The subsequent [Lean oracle extension campaign](ORACLE-EXTENSION-RESULTS.md)
adds Result, recursive payloads and initialization projections while retaining
zero confirmed unsafe leads. The measurements below are the pre-extension fix campaign.

PR #115 is merged. This follow-up changes `src/own/`, with the rules specified
first in the dated §29 amendment of `docs/design/ownership-checker.md`. Neither
the type checker nor the Lean checker, generator, translation policy or either
interpreter changes. It fixes all six interpreter-confirmed defect clusters,
promotes their six pending fixtures with complete diagnostics, and adds class
coverage including accepted twins.

## Rules behind the clusters

| Cluster | Confirmed originals before | Missing rule and correction |
|---|---:|---|
| Case-result liveness | 170 | Consume every arm's terminal result in its own branch context. `if` lowers to BIR `case`; mutually exclusive arms remain separate. |
| Later capture returns | 16 | Creating a lambda reads its captured outer paths. Returning a capture from a later callback keeps the outer holder live across an earlier write. Named closures still resolve captures at their consumers. |
| Block-result liveness | 8 | Consume a block's terminal expression; consuming only the compound block cannot recover its terminal variable path. |
| Fold accumulator ownership | 5 | A taken item is a conditional loan. Returning it onto a written feedback edge retains its source-container exclusivity condition and requires the caller's input holder to be dead for that lifetime. |
| Recursive captured result | 1 | Preserve symbolic environment provenance while solving recursive local classes; an unbound capture is never an empty abstract value. Instantiate it against the enclosing binding when the class is called. |
| Argument / callee-capture aliasing | 1 | Include the callee environment in Disjoint, alongside explicit arguments and other argument paths. This also covers an environment containing another returned closure. |

Ownership summary blocks advance from version 4 to 5, invalidating cached older
rules. The diagnostic harness now actually passes the platform selected for
`check/bad/direct/` to the compiler; selecting it alone previously affected only
build/page command paths. The six pre-fix witnesses were also explicitly checked
with browser-direct and all six were accepted, independently of that harness gap.

`tests/corpus/ownership/BridgeResultPaths.beni` covers projected and nested results,
returned/stored/named readers, both fold directions, retained input containers,
mutual and nested recursive captures, nested callback loans, carried captures and
`?` over a result-producing case. Accepted twins include disjoint case arms,
fresh callback results and transferred accumulators through nested folds.
Existing once, early-return and carried-class fixtures retain their verdicts.
With the ownership fix set aside, all six promoted diagnostic tests fail with
expected exit 1 / got 0; restored they pass with their full `.diag` goldens.

## Campaign results

| Campaign | Inputs / translated | Total Zig-accepts / Lean-refuses, before → after | Interpreter-confirmed originals, before → after | Zig-refuses / Lean-accepts, before → after |
|---|---:|---:|---:|---:|
| CI bound (fixtures, bound 1, seed 17 × 128) | 766 / 348 | 15 → 6 | 7 → 0 | 8 → 8 |
| Full bound 2 and three seeds × 20,000 | 116,456 / 43,066 | 2,358 → 1,725 | 201 → 0 | 401 → 401 |

The full campaign has exactly 73,390 counted skips and 43,066 value checks,
unchanged from the baseline. Both checkers accept 18,346 programs; both refuse
22,594 (before: 21,961). Agreements rise from 40,307 to 40,940. Of the 633 old
program-level leads now refused, 201 were interpreter-confirmed divergences and
432 agreed on their executed input. A concrete agreement does not remove the
static rule's obligation to protect all paths and later uses.

| Full-run stream | Translated | Total leads, before → after | Confirmed originals, before → after |
|---|---:|---:|---:|
| Fixtures / sync / targeted | 224 | 9 → 0 | 7 → 0 |
| Bound-2 enumeration | 27,769 | 835 → 294 | 156 → 0 |
| Seed 17, 20,000 inputs | 5,006 | 520 → 491 | 11 → 0 |
| Seed 20261011, 20,000 inputs | 5,054 | 493 → 470 | 13 → 0 |
| Seed 314159, 20,000 inputs | 5,013 | 501 → 470 | 14 → 0 |

A separate supplementary replay also refuses all **220** historical minima
whose interpreter traces diverged, using only ownership diagnostics. These
include changed programs whose original agreed, so they are not added to the
headline original-program counts. Their sources are retained in the baseline
bundle, and the [replay diagnostics](evidence/bridge-fix/historical-minima.json.gz)
are recorded separately.

All **401 reverse leads remain refused: 0 moved**, and their complete refusal
details are unchanged. The full run's total reverse count also stays 401, so
there are no new reverse-direction program leads.


Every remaining original whole-program Zig-accepts / Lean-refuses lead is
executed by **both** unchanged Lean interpreters, comparing the complete final
value, intermediate reads and external-reader observations. Errors abort the
audit. An agreeing finite execution remains a precision lead on that input,
not a proof of safety for other inputs. The direct JavaScript library still
uses persistent lists; its execution is not the in-place judge.

The fix runs disable only the optional historical persistent-runtime reducer
(`--no-minimize`). Original source translation, dump/enforcement span agreement,
whole-population browser-tea value checking, paired direct executions, coverage
floors, counted skips and failure accounting remain active. No minimum is used
to classify an original as safe or unsafe. The audit checks original-source
fidelity through the Lean wire reader and requires exact baseline stream hashes
and input/translated/skipped/value-checked counts for the canonical CI (766)
and long (116,456) populations. Custom population sizes still run the judge
and reverse replay, but do not assert baseline equality. It uses a frozen compiler
binary whose SHA-256 is checked before and after the audit.

[Complete before/after interpreter judgments and reverse-lead replays](evidence/bridge-fix/README.md)
retain the programs, full traces and compiler hashes. The historical long-run
baseline, including all 201 original cluster memberships, is unchanged in
[evidence/bridge-triage](evidence/bridge-triage/report.json).
The Lean oracle's three pre-existing unproved soundness statements are unchanged;
these finite campaigns are evidence, not a proof of global soundness.

## Application impact and validation

Four TodoMVC variants (`Sandbox`, `NoEditing`, `NoStorage`, `NoRouting`) and
`browser/direct/TodoRouting` remain clean under browser-direct. Sternhalma's
three existing top-level-list sharing errors are byte-identical: constructing
`allCoords` by appending to shared `centralHexagon`, and editing the model's
`Board.init` cells through the entry and initialization fold. These are existing
shared top-level lists, not new checker errors. No application was modified.
[Complete app diagnostics before and after](evidence/bridge-fix/app-impact.json)
record the comparison. The existing corpus gains no new refusal; changed old
ownership goldens record additional reads and more precise existing diagnostics.

`zorg build test test-blackbox fmt-check beni-fmt-check -j4` completed with
**1,300 passed, 15 skipped and only the two known macOS case-folding failures**
in `build_test`: the stale-path different-file removal assertion and the
same-file hard-link setup (`PathAlreadyExists`). The added review coverage and
formatting checks pass. No budget or exemption changes.
`zorg build gates` refuses Apple Silicon macOS because it cannot count the
reference x86-64 Linux instruction budget. The hardware-budget gate remains owed
on a supported x86-64 Linux host. Hosted Linux CI passed all four test steps with
no hardware budget.

The explicit `@claude review` found no blocking defect. Every review point was
answered on PR #124; additional fixtures cover its early-return, nested-recursion,
nested-loan and carried-environment questions. The PR remains unmerged.

## Reproduce

Use the pinned ownership environment and run from the repository root:

```sh
zorg build test-blackbox-corpus -Dcorpus=Bridge
# In proofs/ownership: lake build ownership triage
cp zig-out/safe/bin/beni zig-out/ownership-fixed-beni
node proofs/ownership/scripts/bridge.mjs --ci --no-build --no-minimize \
  --compiler=zig-out/ownership-fixed-beni --out=zig-out/bridge-fixed-ci
node proofs/ownership/scripts/bridge.mjs --long --no-build --no-minimize \
  --compiler=zig-out/ownership-fixed-beni --out=zig-out/bridge-fixed-long --jobs=8
node proofs/ownership/scripts/bridge-fix-audit.mjs zig-out/bridge-fixed-ci \
  zig-out/ownership-fixed-beni zig-out/audit-ci
node proofs/ownership/scripts/bridge-fix-audit.mjs zig-out/bridge-fixed-long \
  zig-out/ownership-fixed-beni zig-out/audit-long
```
