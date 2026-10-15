# Ownership differential bridge — 2026-10-15

The corrected bridge covered **116,456 inputs**: 43,066 translated and
value-checked programs, and 73,390 explicitly counted skips. Both checkers
accepted 18,346 programs and refused 21,961; Zig refused 401 that Lean accepted,
and accepted 2,358 that Lean refused. **No shipping runtime defect was confirmed.**
All 2,358 program leads have typed minima and matching real runtime observations;
1,167 additional site-only leads cannot build directly because of other refusals.
Neither ownership policy was changed. No shipping-defect pending fixture was added.

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

One representative per class is linked below; all executions agree. The complete
bundle contains every case, including those with the same minimum.

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

The runtime confirmation caught **none** of these holes. The actual emitted
browser-direct library still calls persistent list functions. Matching runs are
therefore unconfirmed leads, not evidence that an in-place guarantee holds.
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
