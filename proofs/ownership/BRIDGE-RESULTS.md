# Ownership differential bridge — 2026-10-15

This is the pre-fix baseline. The ownership corrections and before/after counts
are recorded in [BRIDGE-FIX-RESULTS.md](BRIDGE-FIX-RESULTS.md); the six refusal
fixtures linked below have since been promoted to the gated corpus.

The corrected bridge covered **116,456 inputs**: 43,066 translated and
value-checked programs, and 73,390 explicitly counted skips. Both checkers
accepted 18,346 programs and refused 21,961; Zig refused 401 that Lean accepted,
and accepted 2,358 that Lean refused. **201 original programs expose shipping
ownership-checker defects, confirmed by the in-place interpreter**, in six
clusters. *Corrected 2026-10-15 (the oracle review):* this checks the shipping
checker's verdicts on the translated common subset, the writers the core then
modelled (`set`, `push`, focus, copy, prepend), against the Lean model. It does
not confirm the in-place ownership policy as a whole: constructions, views,
entry rows, sends and record assignment were outside it, and the emitted
JavaScript still uses persistent lists. The other **2,157 original programs are Lean precision leads**: the
oracle's value and in-place traces agree. Neither checker was changed or weakened.
Six minimal beni refusals are pinned under `tests/pending/check/bad/direct/`.
The emitted direct runtime still uses persistent lists; it cannot judge this
in-place guarantee. There are also 1,167 site-only leads blocked by other refusals.

The preliminary run and its minima are superseded: its translator could erase
unused explicit captures. The corrected translator snapshots capture atoms into
separate bindings and skips unrepresentable unused slots. The regression is
`regressions/bridge/UnusedCapture.json`; `CaptureField.json` exercises a field
capture without its ancestor and sibling. The CI self-test independently checks
them through the real Lean wire reader/checker and the browser-direct compiler.

## Streams and program verdicts

The oracle's existing v5 streams, not lookalike generators, were run under Lean
4.29.1, Node 24.19.0 and Zorg 0.17.1+zorg.1. The entire process tree was pinned to
CPUs 0–7, with eight bridge workers and one thread per compiler child.

| Stream | Inputs | Translated / value-checked | Skipped |
|---|---:|---:|---:|
| fixtures-0.jsonl | 490 | 224 | 266 |
| enumerate-0.jsonl | 55,966 | 27,769 | 28,197 |
| generator-17.jsonl | 20,000 | 5,006 | 14,994 |
| generator-20261011.jsonl | 20,000 | 5,054 | 14,946 |
| generator-314159.jsonl | 20,000 | 5,013 | 14,987 |

The SHA-256-verified exports establish eligibility per stream. The complete,
disjoint batches account for exactly one value check and verdict per translation.
[Stream coverage and verdict matrix](evidence/bridge-long/stream-coverage.json)
records that derivation; subsequent runs record the stream counters directly.

| | Lean accepts | Lean refuses |
|---|---:|---:|
| Zig accepts | 18,346 | 2,358 |
| Zig refuses or is pending | 401 | 21,961 |

## Construct and skip coverage

These are syntactic occurrences in the main expression and each reachable
declaration once, not dynamic invocation counts. The skipped column contains
whole skipped programs, including their otherwise supported constructs.

| Construct | In translated programs | In skipped programs |
|---|---:|---:|
| `add` | 2,016 | 16,860 |
| `app` | 52,076 | 284,858 |
| `at` | 5,112 | 26,772 |
| `atom` | 47,035 | 139,687 |
| `branch` | 12,495 | 41,435 |
| `builder` | 3,352 | 42,697 |
| `close` | 3,352 | 42,697 |
| `closure` | 57,080 | 336,808 |
| `copy` | 4,632 | 23,542 |
| `eq` | 24 | 33 |
| `events` | 0 | 38 |
| `focus` | 17,543 | 70,591 |
| `length` | 23,827 | 103,156 |
| `let` | 345,698 | 1,508,546 |
| `literal` | 167,665 | 494,527 |
| `lt` | 680 | 7,229 |
| `owned` | 0 | 43 |
| `prepend` | 10 | 0 |
| `push` | 41,390 | 204,653 |
| `put` | 3,352 | 37,403 |
| `record` | 27,155 | 89,572 |
| `recur` | 3,366 | 6,334 |
| `set` | 7,622 | 24,768 |
| `shared` | 1,708 | 22,206 |
| `sub` | 3,383 | 7,197 |
| `traverse-list` | 8,196 | 52,940 |
| `traverse-model` | 0 | 25 |
| `traverse-range` | 3,954 | 11,604 |

The 3,362 translated builder/put/close occurrences belong to recognized whole
library idioms. Arbitrary public builders are not supported. `events`, `owned`
and model traversals remain outside this bridge's public-platform contract.
Identity-preserving map/close cannot be implemented by shipping `List.map`.

| First skip reason per program | Programs |
|---|---:|
| `abstract-event-boundary` | 21 |
| `abstract-owned-boundary` | 20 |
| `conditional-shared-publication` | 1,421 |
| `dynamic-shared-root` | 298 |
| `function-valued-observation` | 60,672 |
| `identity-preserving-close` | 4,538 |
| `ill-typed-core` | 762 |
| `late-shared-publication` | 1,729 |
| `list-traversal-index` | 72 |
| `model-entry-protocol` | 20 |
| `private-builder` | 3,569 |
| `shared-field-root` | 40 |
| `shared-function-observation` | 18 |
| `unused-capture-slot` | 210 |

There are 210 unused-capture skips, including 42 programs already excluded by
another rule in the preliminary translator. The rule reduces the translated
population by 168. It does not change either ownership checker.

| Family | Inputs | Translated | Skipped | Skip ratio |
|---|---:|---:|---:|---:|
| `fixture` | 98 | 82 | 16 | 16.3% |
| `sync` | 44 | 14 | 30 | 68.2% |
| `targeted` | 348 | 128 | 220 | 63.2% |
| `enumerate` | 55,966 | 27,769 | 28,197 | 50.4% |
| `general` | 18,984 | 2,642 | 16,342 | 86.1% |
| `declarations` | 26,040 | 2,073 | 23,967 | 92.0% |
| `identity-map` | 1,308 | 0 | 1,308 | 100.0% |
| `library-pipeline` | 1,355 | 0 | 1,355 | 100.0% |
| `branch-traversal` | 1,400 | 1,400 | 0 | 0.0% |
| `fresh-tower` | 1,368 | 1,368 | 0 | 0.0% |
| `captures` | 1,337 | 1,337 | 0 | 0.0% |
| `once-many-wrappers` | 1,384 | 1,040 | 344 | 24.9% |
| `indexed-chain` | 1,347 | 1,097 | 250 | 18.6% |
| `recursive-higher-order-limit` | 1,350 | 1,350 | 0 | 0.0% |
| `recursion` | 1,371 | 1,371 | 0 | 0.0% |
| `fresh-nested` | 1,395 | 1,395 | 0 | 0.0% |
| `escape-traversal` | 1,361 | 0 | 1,361 | 100.0% |

Pinned CI floors require every currently supported family to retain its known
coverage. The canonical long run requires the same stream counts and at least
95% of each recorded family's translations (`bridge-coverage.json`). Custom
single-suite or alternate-budget experiments do not use that long-run baseline.

## Source sites

| Observed expression-group outcome | Groups |
|---|---:|
| Agreement | 37,431 |
| Lean success / Zig refusal | 426 |
| Lean refusal / Zig acceptance | 1,914 |
| Unknown | 43,850 |

There are zero unmapped demands and 713 pending Zig lines. A group may contain
multiple obligations; it accepts only if all accept. Successful main sites
before a later failure are local observations, not a global precision ordering.
Canonical declaration failures and unvisited sites are unknown.

Repeated closure instances cannot borrow another instance's successful visit.
A replay of every Lean-accepted translated program with duplicated emitted keys
(1,127 programs, using the same compiler and oracle hashes) conservatively moved
67 agreement groups and one precision group to unknown. Failed declaration
sites were already unknown; program verdicts and retained leads did not change.
The [audit report](evidence/bridge-long/duplicate-site-audit.json) and the main
report's `siteAccounting` record the replay and exact adjustment. The current
runner performs this censoring directly.

## Every verdict lead and its minimum

The complete [compressed evidence](evidence/bridge-long/evidence.json.gz) contains
all 3,525 retained cases, 1,980 original/minimal sources, and 102 deduplicated
declaration tables. Each case has original and final rejection messages, demand
spans, original and minimized paired runtime outputs, and the typed minimum when
execution was permitted. [Validation](evidence/bridge-long/validation.json)
checks source/table hashes and complete program-lead accounting.

| Original rejection class | Program leads |
|---|---:|
| Dead | 385 |
| Disjoint | 1 |
| container contents | 163 |
| exclusive contents | 78 |
| limit | 1,385 |
| once recursive closure | 1 |
| recursive call does not preserve entry ownership assumptions | 32 |
| supply edge | 313 |

The 1,385 explicit `limit:` cases are model boundaries, not confirmed ownership
counterexamples. Eighteen minima change the full message while retaining its
class; every one is flagged `reasonChanged`. Every explicit limit is flagged
`limitLead`. The full original and final messages remain available.

A minimum is one-step under `Oracle.reductions` over the main expression and
reachable declaration bodies, preserving ordinary typing, the rejection class,
Zig acceptance and the runtime outcome. Signatures are not minimized. Reduction
uses a 5,000-step evaluation budget. No compiler-rejected candidate was excluded.
The final one-step frontiers contain these counted translation/observation skips:

| Frontier skip | Candidates |
|---|---:|
| `unused-capture-slot` | 17 |
| `function-valued-observation` | 12 |
| `numeric-audit-execution-limit` | 1,399 |

These counts describe the final frontier, not historical search rounds. Retained
typed proposals reproduce them with `scripts/bridge-frontier.mjs`.

The following historical representatives compare the two persistent JavaScript
runs only. They do not establish in-place safety. The oracle triage below
supersedes their `unconfirmed` statuses; the original bundle is retained unchanged.

| Class | Case | Minimal source | Result / reads / shared of both runs |
|---|---|---|---|
| Dead | `enum-2-1302` | [Dead](evidence/bridge-long/examples/Dead.beni) | `{"result":[],"reads":[],"shared":{}}` |
| Disjoint | `seed-314159-9019` | [Disjoint](evidence/bridge-long/examples/Disjoint.beni) | `{"result":[],"reads":[],"shared":{}}` |
| container contents | `enum-2-10033` | [ContainerContents](evidence/bridge-long/examples/ContainerContents.beni) | `{"result":[[0]],"reads":[],"shared":{}}` |
| exclusive contents | `enum-2-10310` | [ExclusiveContents](evidence/bridge-long/examples/ExclusiveContents.beni) | `{"result":1,"reads":[1],"shared":{}}` |
| limit | `seed-17-10063` | [Limit](evidence/bridge-long/examples/Limit.beni) | `{"result":0,"reads":[],"shared":{}}` |
| once recursive closure | `fixture-24` | [OnceRecursiveClosure](evidence/bridge-long/examples/OnceRecursiveClosure.beni) | `{"result":[],"reads":[],"shared":{}}` |
| recursive call does not preserve entry ownership assumptions | `seed-17-10052` | [RecursiveEntry](evidence/bridge-long/examples/RecursiveEntry.beni) | `{"result":0,"reads":[],"shared":{}}` |
| supply edge | `enum-2-10095` | [SupplyEdge](evidence/bridge-long/examples/SupplyEdge.beni) | `{"result":[],"reads":[0],"shared":{}}` |

From `proofs/ownership`, inspect or materialize any case:

```sh
node scripts/bridge-evidence.mjs case evidence/bridge-long seed-314159-9019 report
node scripts/bridge-evidence.mjs case evidence/bridge-long seed-314159-9019 source > Minimal.beni
node scripts/bridge-evidence.mjs case evidence/bridge-long seed-314159-9019 original
node scripts/bridge-evidence.mjs case evidence/bridge-long seed-314159-9019 core > core.json
```

## Oracle triage: confirmed by the in-place interpreter

[Triage summary](evidence/bridge-triage/report.json),
[complete judgments](evidence/bridge-triage/judgments.json.gz) and
[cluster membership](evidence/bridge-triage/clusters.json) retain every lead's
original and minimum, both complete traces and the replayable core. The judge
runs `ValueSemantics.run` **and** `InPlaceSemantics.run`, regardless of the
ownership verdict, comparing final values, reads and permanent outside-reader
observations. Typing or execution errors fail the run. No lead failed execution.

The original programs are regenerated from the oracle's existing fixture,
targeted, bound-2 enumeration and three v5 streams. Every regenerated original
has the exact retained Lean refusal and translates to the exact retained beni
source. The complete membership table assigns each diverging original once,
by its minimal causal pattern rather than by Lean's first rejection message.
This is a **manual causal classification**: the replay checks its coverage and
disjointness, not a structural predicate for each cluster. Some originals contain
more than one defect; counts are program counts, not counts of independent writes.
The function/line citations below refer to the unchanged ownership source at
commit `2491cb6a4` (the source is identical in this triage commit).

| Minimal Zig pattern | Originals | Pending fixture | Zig rule/protocol at fault |
|---|---:|---|---|
| Return an old value through a case arm after an eager write | 170 | [BridgeCaseResult](../../tests/corpus/check/bad/direct/BridgeCaseResult.beni) | `src/own/Ownership.zig:5235`: `evalCase` evaluates arm results without consuming their variable paths; `refPath` cannot recover that use from the compound case. Dead misses the later arm read. |
| Return an earlier written capture from a later focus callback | 16 | [BridgeCaptureResult](../../tests/corpus/check/bad/direct/BridgeCaptureResult.beni) | `src/own/Ownership.zig:3965`, `:4909`, `:8342`: the returned capture is used in the callback frame, while the earlier demand resolves only uses in its own frame. Its later capture/return does not keep the outer holder live. |
| Return an old parameter/block result after writing or lending it, including recursive calls | 8 | [BridgeBlockResult](../../tests/corpus/check/bad/direct/BridgeBlockResult.beni) | `src/own/Ownership.zig:5040`, `:3168`: `evalLet` evaluates its final result without consuming it; consuming the compound body does not consume its terminal local. The summary can publish `W` and return the old `π` without the internal Dead refusal. |
| Reuse a borrowed input as a fold's written accumulator | 5 | [BridgeFoldBorrow](../../tests/corpus/check/bad/direct/BridgeFoldBorrow.beni) | `src/own/Ownership.zig:7174`, `:7436`, `:7530`: the callback-result guard accepts the item's owned supply without enforcing its taken-container condition/lifetime on the feedback edge. Returning an input can make the next written accumulator alias the retained input or a later input position. |
| Recursive return of a capture loses the write/once obligation | 1 | [BridgeRecursiveCapture](../../tests/corpus/check/bad/direct/BridgeRecursiveCapture.beni) | `src/own/Ownership.zig:6425`, `:4935`: `walkGroup` runs before value bindings; `instProv` turns an unresolved environment result into no cells, so the write through the recursive return contributes no captured write and the closure is not once. A second call mutates the first call's retained seed. |
| Written argument aliases the callee's returned capture | 1 | [BridgeCaptureOperand](../../tests/corpus/check/bad/direct/BridgeCaptureOperand.beni) | `src/own/Ownership.zig:6660`: `callSiteDemandDeep` includes other explicit arguments and paths but omits the callee environment from Disjoint. |
| **Total** | **201** | **6 fixtures** | **Shipping checker unchanged** |

All six fixtures currently check successfully with no diagnostics under
`browser-direct`, despite their pinned `list_still_used` refusal. Their `RED`
signature is `exit=0 codes=none`. The beni fixtures are **hand-transcribed**
from the small Lean twins, using readable names and public library calls.
Their semantic correspondence was reviewed; it is not an automated
translation-equality check. The Lean twins are
[regressions/bridge/Triage.json](regressions/bridge/Triage.json); all six diverge.
For example, the case and block twins return `[1]` by value versus `[1,2]` in
place; the capture operand returns `[0]` versus `[2]`; the recursive captured
seed returns `[0,1]` versus `[0,1,1]`. The fold twin's final result agrees but
its third item read is `[1]` versus `[1,9]`: comparing final values alone misses it.
The recursive block variant `seed-17-15713` returns `[2]` versus `[2,2]`.

The old reducer preserved persistent-runtime agreement, which cannot preserve
an in-place witness. Of the 2,358 old minima, 220 diverge: **94 erase an original
divergence and 113 introduce one**. These 113 changed programs are additional
unsafe minimized witnesses, not confirmations of their nondiverging originals.
They are recorded separately; the headline partition remains **201 + 2,157 =
2,358 original leads**. The six new witnesses were minimized by pattern and
confirmed in both Lean interpreters, rather than selected from the old minima.
No claim of a global or exhaustive minimum is made.

The 2,157 agreeing originals remain Lean precision leads for their executed
inputs, including 1,385 explicit model limits. Agreement on these finite
executions does not prove safety for other inputs or establish completeness.

To reproduce from the repository root:

```sh
nix develop .#ownership -c sh -c 'cd proofs/ownership && node scripts/bridge-triage.mjs'
zorg build test-pending -j1 -Dcorpus=check/bad/direct/Bridge
```

## The 401 Zig-refuses / Lean-accepts leads: top five patterns

A fresh dump replay of **all 18,747 translated Lean-accepted programs** using
the campaign compiler recovers exactly **401** Zig refusals/pending verdicts.
[Complete per-program sources and refusals](evidence/bridge-triage/precision.json.gz)
retain the evidence. This is a precision-direction comparison, not evidence
that Lean acceptance proves safety.

| Pattern | Programs assigned | What Zig loses |
|---|---:|---|
| `once` through a wrapper capturing another closure | 272 | A captured closure's single-use consumer is no longer known. |
| Returned writer closure remains pending (`it is returned`) | 95 | The summary loses the consumer of a closure returned by a helper. |
| Callback result `need` | 18 | A callback result, especially a captured result, cannot be shown owned where the caller edits it. |
| Nested focus `exclusive` | 11 | Independence of containers produced by initialize/constructor wrappers is not recovered for a later nested update. |
| Initialize-produced leaf `exclusive` (`push`/`set`) | 5 | Fresh per-call inner lists are still treated as possibly sharing. |
| **Total** | **401** | |

Assignment follows the table order. `seed-20261011-11679` has both `need` and
nested-focus failures and is counted under `need`; nested focus occurs in 12
programs before that deduplication. The leaf group has three `push` and three
`set` occurrences across five programs. The older `precisionPatterns` counts
**415 demand lines**, including two nested-update demands per call, and must not
be read as program counts.

Given the retained raw campaign on azathoth, reproduce its precision replay with:

```sh
node scripts/bridge-precision.mjs RAW-CAMPAIGN-DIR ORIGINAL-COMPILER precision.json.gz
```

The script verifies the original compiler and stream SHA-256 hashes before
replaying; it changes neither checker and does not execute JavaScript.

## Opt-in Zig holes

The baseline and all three source edits were built in the same clean detached
worktree. The control stream is the bounded CI stream: 490 fixed inputs,
148 bound-1 programs and 128 generated programs, of which 348 translate.
These catches do not establish mutant detectability over the long campaign.

| Source edit | New program verdict leads | New comparable site leads | Confirmed runtime disagreements | Verdict catch |
|---|---:|---:|---:|---|
| `dead` | 95 | 89 | 0 | caught |
| `disjoint` | 12 | 20 | 0 | caught |
| `shared` | 9 | 4 | 0 | caught |

`dead` removes the holder loop; `disjoint` removes the other-operand loop;
`shared` disables the top-level cause. Existing baseline leads never count as
new catches. [Control evidence](evidence/bridge-mutants/report.json) lists every
new program/site and its outcome; each subdirectory includes complete source and
runtime evidence. All three are permissive holes. A stricter-policy source
mutant is not included; ordinary precision differences are measured.

The historical persistent-runtime comparison caught **none** of these holes. The actual emitted
browser-direct library still calls persistent list functions. Matching JavaScript runs
therefore cannot judge the in-place guarantee. The oracle triage above supplies
that judge for the original baseline leads.
The bridge never substitutes a handwritten mutating runtime.

## Validation and limits

- Lean build passed; the three existing unproved statements are unchanged.
- `ownership ci` passed, including the corrected 348-translation bounded bridge,
  its capture regressions and failed-batch black-box control.
- The authoritative committed-source audit passed: 30 Lean files parsed,
  4,385 constants replayed, the pinned `sorryAx` dependency set unchanged.
- Linux `zorg build gates` passed. macOS `zorg build gates -j1` ran the complete
  unfiltered gate: 1,297 passed, 15 skipped, the two known case-folding failures.
  Parallel macOS runs also hit CPU-time fallback budgets; the isolated
  determinism test passed. No budget was raised or exemption added.
- Compiler/runtime/core sources were not changed, so no run-hash update or LLVM
  comparison was required.

The async failure control reproduced a false success in the pre-fix runner:
32 translations, zero value checks, exit 0 after a forced compiler failure.
The corrected runner preserves the first failure, publishes no completed report,
and requires complete per-stream value, verdict and lead accounting.

Value checks establish final-value fidelity under browser-tea. They do not prove
heap identity or alias preservation; capture snapshots and public-operation
contracts are separately reviewed and tested. Paired runs compare explicit
length/index reads, final values and exported shared roots, not the complete
Lean trace. Direct execution of 1,167 site-only leads is blocked by other
refusals. Arbitrary builders, identity-preserving close, abstract event/owned and
model protocols, used traversal indices, function observations and the other
counted skips remain unsupported. The proof model still has three unproved
soundness statements. No finite campaign proves either checker sound.

The corrected raw artifacts remain on `azathoth` under
`/tmp/beni-ownership-bridge-20261015/zig-out/ownership-bridge-faithful/`.
The final controls are `zig-out/ownership-bridge-mutants/`; full CI is
`zig-out/bridge-ci-faithful-full.log`. `bridge-gates-faithful-linux.log` records
the Linux gates. All builds use real pinned Zorg, not the handoff's old alias.

### This triage's validation (2026-10-15)

- `lake build` and unfiltered `lake exe ownership ci` passed. The final source
  scan still finds exactly three `sorry` declarations and the pinned four
  `sorryAx` dependencies; neither interpreter nor checker changed.
- The full original/minimum replay and all six minimal Lean twins passed.
- Unfiltered Linux `zorg build gates -j8` passed in a fresh source snapshot.
- Unfiltered macOS `zorg build gates -j1`: **1,297 passed, 15 skipped, the same
  two known case-folding failures**. No new gate failure or budget exemption.
- All six new pending refusals are red for the intended `exit=0 codes=none`
  signature. The full pending run also exposes an unrelated existing stale
  `ValueCommands` signature (`missing_field`, not its recorded
  `list_may_be_shared`); that fixture and signature were left unchanged.
- The only Zig change is teaching the corpus walker to use `browser-direct`
  for `check/bad/direct/`, as it already does for `build/bad/direct/`. This lets
  pending enforcement fixtures pin diagnostic codes without requiring a page.
