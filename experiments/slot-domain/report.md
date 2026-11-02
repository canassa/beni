# The slot-domain decision experiment

Agent lane `slot-exp` on dagon, 2026-11-02. The owner approved it on 2026-11-02, as the experiment of Astra's second review (§2, §4, §6). Base: `origin/master` `89e320851`. Builds: self-hosted Debug only (`zig build`), one worker for every measurement. The code is a scratch prototype on branch `exp-slot-domain`. Nothing is merged, and master is unchanged.

## Verdict

**PASS, within the first-order scope the review set.** Every pass criterion of review §6 holds, and no fail condition applies.

| §6 pass criterion | Result |
|---|---|
| The unchanged three helpers and the writing witnesses complete under 65,536 growth per declaration, with the source-lane caps unchanged | **Yes.** `removeMin` (generic): 20,214 records in all, growth 0. Core's own `Dict.removeMin`: 20,213. `balance`: 2,534. `moveRedLeft`: 1,207. Every writing witness is under 1,000 records. Each total is under 65,536 even if every record counted as growth. No cap or allowance was changed. |
| Every negative control refuses | **Yes.** Old tree kept, external alias, duplicate output payloads, a payload repeated from the start, #1516, #1530, `LevelFresh.pushDup`, `CombinePositions.aliased`/`twice`/`mixed`, `FoldCertificate.twoViews`. |
| The useful writers run with equal output under copy and in-place semantics, and the sanitizer is clean | **Yes.** `useful`, `usefulParam`, `rebuild` beside the surviving subtrees, a recursive writer over every payload of the answer (twice), and a generic-payload `rebuild`. The output is the same under copy, plain and `--sanitize-lists` builds, and no write traps. |
| The unsafe variant trips the observer | **Yes.** It traps: "a stale read of a list … which `List.push` … changed in place". |
| Repeated calls, aliases and fresh identity survive the import round-trip | **Yes.** All 61 imported contracts encode again to the same words. The verdicts across the module boundary match the same-module ones. |
| Independent copies cost proportionally; payload fields do not bring back the quadratic | **Yes.** Copies 1/2/4/8: exactly ×k (11,636·k). Fields 1/2/4/8: `removeMin*` 11,636 / 20,478 / 38,703 / 75,123 (×1.76, ×1.89, ×1.94 per doubling); relation work 819 / 835 / 1,421 / 2,904. |

| §6 fail condition | Result |
|---|---|
| Work moved into uncharged or source lanes | **No.** Every fact, scan, relation, substitution, projection, closure and validator step goes through `Ids.Account.reserve`. That is the same path v2's growth uses (the source continuation K·I_f first, then growth). Nothing is uncharged, and no lane cap moved. See *How it is charged*. |
| A trusted non-duplication assertion | **No.** The `Dict` helpers' contracts are inferred from their bodies and validated by a separate evaluation. Only core primitives with ownership words (`List.push`, `List.length`, `List.cons`, …) are read from their words, as v2 reads them. |
| A lazy v2 value reader left on the path | **No.** Every public function of `Shape`, `KappaRead` and `Propagate` bumps a counter. The slot path reads it as 0 in every run, all of core included. The instrument is live: v2 on the same `removeMin` module makes 605,664 such calls. |
| A raised limit | **No.** |
| `rebuild` still refused because every payload slot overlaps every other | **No.** `rebuild` is accepted `param`, under the selected separation of `t`'s payload slots. |
| An unsound accepted control | **None found.** All 17 refuse→accept lines against master (sample and family table) are documented false refusals or safe twins. Each was checked by hand; see *Precision*. |

The figure the review asked for: generic `removeMin`'s walks cost **421, 3,099, 5,110, 5,792 (settled) and 5,792 (validation)** records, **20,214 in all, against 65,536.** For comparison, the cheapest sound configuration of the earlier experiments needed 1,151,314 records (16× the allowance), and master reaches its limit.

What a PASS here does not establish:
- **Scope.** The evaluator is first-order. Lambdas, local functions, function values, record update, `try` and markup are reported `unsupported`; 748 of core's declarations are. So are three core rows it does not read (`copyof`, `concatenated`, the cell words).
- **The full ledger.** Precision was measured on the review's sample and family table: 22 fixtures, 280 demand positions. It was not measured on all 477 fixture tokens.
- **Speed.** The timings are Debug, so they say nothing about the 250k LOC/s target.

The review's next checkpoint (§6, last paragraph) is still owed: a callback traversal, an accumulator fold, retained values and loans, full core and platform checking, and the complete ledger.

## What was built (branch `exp-slot-domain`)

`--ownership-slots=N` is a hidden flag. `src/own2/Slots.zig` holds about 3,000 lines, and the plumbing touches a few lines in `Cli`, `Session`, `main`, `Enforce`, `Groups` (helpers made `pub`) and `Ownership` (the module is routed to the evaluator). Modes:
- 1: infer and validate;
- 2: forced claim, which the validator must refuse when it is false;
- 3: forced-unsafe, published whatever the validator says;
- 4: copy semantics, every write refused;
- +8: core modules too;
- +16: v2 checks the module first, which shows the reader counter fires.

**Reused from v2:**
- the typed BIR;
- `Place` (canonical paths, `extend`, `expandLevels`);
- `Groups.Module`'s place and callee adapters;
- `Prepass` groups for scheduling;
- `Ids.Account`, the one account;
- `Hoists.Builder`, the lowering channel, so the sanitizer judges these verdicts.

**Not reused:** v2's `Liveness`, `Holders`, `Demands`, `Shape`, `Cond`, `KappaRead`, `Propagate`, `Summary` and `Walk`. The evaluator has its own small evaluation-order liveness and its own holder query on slots; the brief allowed this ("or write the holder query for slots").

**The domain** (review §2):
- **Slots** are canonical paths of a place, fixed by the types. Join names (a `⟲` over several level paths, as in `B (List B) (List B)`) are expanded to their level paths (`expandLevels`), so two slots meet only when their canonical names meet.
- **Positions** are concrete pattern and field projections from a **root**: a parameter, or one call site's result. List steps are `[i]`, `[−j]` and slices, normalised so that a slice is only ever the last step. Names bound to one projection share its identity.
- **Leaves** are "the objects at these object slots inside the subtree at this position of this root". There are also fresh atoms (a literal's site, or a call's own fresh objects) and `⊤`. Storage and payloads are separate slots. Unknown provenance is `⊤` and refuses a write; it is never empty.
- **Separation.** `Sep(root)` restricted to a **selection**: a set of (parameter, slot) occurrences. Every object at one of them occurs once among all of them. This is the review's inductive predicate of a region. A conjunction is a union of selections: linear, never a table of pairs. Two disjoint positions of one root are apart under that root's selection. This is what lets `rebuild` write one payload beside `l` and `r`.
- **Non-duplication.** `Sep` of a built value is factored: components grouped by root; a conflict found through position ancestry indexed by (position, slot); one selection union per root. Coexisting parts must be apart; a choice's arms are taken each on its own. Reads observe and do not consume.
- **Calls.** Each call is instantiated once per call site per summary generation. Per caller result slot, the callee's arrivals are projected onto the arguments (`inst`), and its `res_cond` is instantiated on the arguments (`instCond`). One call's fresh objects are one atom, so one allocation keeps one identity at every slot.
- **Substitution keeps separation.** When two distinct callee occurrences reach one caller value by one literal route, they are distinct positions of it. They ask for that value's own separation; they are never a refusal. Two parameters handed one value are that value twice (routes are per parameter). `⟲` is projected into literals exactly: the values one or more levels below, at the same place. For a reference, the projection uses its descendant paths and never its own storage.
- **Choices.** A `case` value is an alternative tagged by its choice. Projections keep the tag, so two values of one choice are compared arm by arm, and two different choices never are.
- **⊥.** An empty recursive result is bottom, strict in constructions and calls.
- **Contracts.** Per object slot of the result, its arrivals (parameter slots, fresh, `⊤`), and `res_cond` (Sep of the result ⇐ a selection). Also the parameter slots written (W) and `req` (the selection the writes rely on). A recursive group starts from ⊥ and reaches a fixed point. Then a separate evaluation of each body, against the final candidates, must stay within them: provenance, writes, `req` and `res_cond`.
- **Demands.** A demand is a write: a `written` word, or a callee's W projected onto its arguments. It is resolved offline after the walk, against:
  - the pending operands at the point;
  - every local bound before it and used after it in an arm that runs with it;
  - the callee's `req` instantiated on the arguments.

  The causes are `unknown`, `shared`, `disjoint`, `alias`/`held-operand` and `exclusive`. The verdict is `fresh`, `call` or `param`. Param writes add to the declaration's W and `req`.
- **Imports.** A minimal canonical codec: constructor steps are written as (ordinal, arg) and re-interned by the importer. It is checked by encoding the decoded contract again and comparing the words. Field steps are not encoded (rank is module-local), so such a contract is not exported; the importer reports "no contract" (`ApartAcrossModules.boxed`).

**Bugs found by the controls and fixed during the run.** Each is a requirement for the real build:
1. A join of contracts must not drop result slots. A loop over an empty list skipped the append.
2. Pairwise region facts collapse under recursion. Two distinct callee families can fold into one caller family; the fix is the selection plus the route rule.
3. Routes must be per parameter (`both t t` was accepted).
4. A `⟲` replayed at a path that is not a first return invented a path no type has (`h2`'s duplicate escaped).
5. Each component of a value needs its own route, or one value placed twice looks like one entry (`moveRedLeftDup` escaped the factored check).
6. Join names must be canonicalised before slots are compared (`FoldedBCall`).
7. When a call's answer may repeat, compare where its two parts come from instead of refusing (`RepeatedPathCall.otherRead`).

## How it is charged

Each declaration has one `Ids.Account`, with `allowance = 65,536` (or the declaration's attribute) and `source = I_f`. Every record goes through `Account.reserve` with no lane, that is `reserveGrowth`. The source continuation K·I_f is taken first, then growth: the same order as every v2 growth reservation. Nothing about lanes or caps was changed. The tables print `total` (every record), `growth` (past the continuation) and `continuation` (the source-lane share). For the required helpers and witnesses, the **total** is under 65,536, so the verdict does not depend on the continuation.

## Checkpoint 1: the cost of a body walk

Generic `removeMin`/`balance`/`moveRedLeft` (`RemoveMinProbe`), `List Int` payloads (`TestSet`), and core's unchanged `Dict`. Walk 1 is against the ⊥ candidate, walks 2–4 against the candidates, and the last walk is the validation. Every record of helper inference and per-call instantiation is included. Debug, `--jobs=1`.

| Function | I_f | Rounds | Walks (records each) | Total | Growth | v2 reader calls |
|---|---|---|---|---|---|---|
| `removeMin` (generic probe) | 93 | 4 | 421 / 3,099 / 5,110 / 5,792 / 5,792 | **20,214** | 0 | 0 |
| `Dict.removeMin` (core, unchanged) | 93 | 4 | 421 / 3,098 / 5,110 / 5,792 / 5,792 | **20,213** | 0 | 0 |
| `removeMinL` (`List Int`) | 87 | 4 | 307 / 1,923 / 2,928 / 3,239 / 3,239 | 11,636 | 0 | 0 |
| `balance` (generic) / core | 125 | 1 | 2,534 / 2,375 | 2,534 / 2,375 | 0 | 0 |
| `moveRedLeft` (generic) / core | 92 | 1 | 1,207 | 1,207 | 0 | 0 |
| `removeMinS` (`Int` payloads) | 87 | 2 | 140 / 144 / 144 | 428 | 0 | 0 |

Earlier, for the same functions:

| | removeMin records |
|---|---|
| master v2 | limit at the default (0.11 s Debug); 15.3M by walk 5 at 20M |
| contracts (stage 2) | 1.92M growth |
| helper contracts + S6d (cheapest sound) | 1,151,314 total, 1,054,396 growth |
| **slot evaluator** | **20,214 total, 0 growth** |

The settled walk costs 5,792 / 93 ≈ **62 records per written instruction**, against 7,400–7,960 for contracts + S6d. The contract has 20 slots (10 parameter, 10 result) and 42 arrivals. `nondup ⇐ sel π1{` the ten payload and key slots `}`: the result keeps the separation of whatever the caller separates. All of core through the evaluator takes 0.38 s and 58 MB (v2 on core: 1.51 s, 75 MB); 1,089 contracts, 748 declarations reported unsupported, 0 v2 reader calls.

## Checkpoint 2: inference and validation

| Control | Result |
|---|---|
| Contract inventory | Fixed by the types: 20 slots for generic `removeMin` in every round. The arrivals only grow, and `res_cond` only weakens. |
| Separate validation | Every recursive group in every mode-1 run validates: probes, fixtures, families and all of core. |
| Duplicating helper (`moveRedLeftDup` → `removeMinDup`) | Inferred `nondup no`. The dependent writers stay refused: `rebuildDup` alias, `allDup` disjoint. `usefulDup` (the payload of a dead answer) is accepted, which is safe. |
| Forced claim (mode 2: "nondup under separated inputs") | The validator **refuses** it for `moveRedLeftDup` and `removeMinDup`, and accepts it for `removeMinL`, where it is true. The dependent writers stay refused. |
| Forced-unsafe (mode 3) | The false claim is published, `rebuildDup`/`allDup` are accepted, and the runtime observer traps (checkpoint 3). |
| Provenance and read/write/escape validation | Validated: arrivals per slot (provenance), W, `req` and `res_cond`. Reads are not a contract field: a call reads its arguments at the call, which liveness counts. A callee that keeps an argument is seen through provenance. Escapes are out of scope and reported `unsupported`. |
| No `Dict` names special-cased, no asserted row | Correct: the `Dict` helpers are inferred. |

## Checkpoint 3: useful separation

| Case | Expected | Slot evaluator |
|---|---|---|
| `useful` (tree built, old tree gone, payload edited) | accept | **accepted fresh** |
| `usefulParam` (the same on a parameter) | accept | **accepted param** (no requirement) |
| **`rebuild`** (the edited payload beside `l`, `r`) | accept | **accepted param ⇐ sel π1{payload slots}** |
| `allParam` (`incAll (removeMinL t)`, every distinct payload) | accept | **accepted param ⇐ sel π1{payload slots}** |
| `cursorPush` (`descend`'s cursor) | accept | accepted param |
| `keepOld` (old tree kept and read) | refuse | **refused** alias `t` |
| `extAlias` (external payload alias) | refuse | **refused** alias `xs` |
| `rebuildDup`, `allDup` (duplicate output payloads) | refuse | **refused** (alias `l`; disjoint) |
| `repeated` (a payload repeated from the start) | refuse | **refused** disjoint |
| A non-writing helper on shared input | legal | `removeMin` over any tree: no demand, contract only |
| #1516 `push`/`pushOnce` | refuse / accept | refused / accepted |
| #1530 `readAfter`/`readBefore` | refuse / accept | refused / accepted |
| `LevelFresh.pushRoot`/`pushDup` | accept / refuse | accepted call / refused |

The same verdicts hold across a module boundary (`probes/ImportRT`): `rebuildImported` is accepted and `keepOldImported` refused.

## Checkpoint 4: the precision sample, the import round-trip, declaration order

Each line is per demand position, master v2 against the slot evaluator, on the same binary. In the "other" column, "partial→refused" means v2 accepts some written paths of a call it refuses, and the evaluator refuses the call whole.

| Fixture | Same | A→R | R→A | Other |
|---|---|---|---|---|
| `ChoiceArmsParams` (`same` accepted, `both` refused) | 12 | 0 | 0 | 0 |
| `WriteOneLevel` (`runFresh`/`run` accepted, `c1`/`c2` refused) | 6 | 0 | 0 | 2 partial→refused (`c1`, `c2`) |
| `FoldCertificate` (`oneView`, `twoTrees`, rows 1/6/8/9 accepted; `twoViews`, rows 2/3/5/7/10/18/19 refused) | 30 | 0 | 3 | 6 partial→refused (negative rows) |
| `CombinePositions` (positive and negative witnesses) | 11 | 0 | 0 | 0 |
| `KappaAtView` (`twoFresh` accepted, `twoOf` refused) | 2 | 0 | 0 | 0 |
| `LinkedJoinCertificate` | 12 | 0 | 0 | 0 |
| `LevelFresh` | 2 | 0 | 0 | 0 |

- **Import round-trip** (`probes/ImportRT`, a helper module and its importer). Each case below matches its same-module twin.
  - `twoFresh` pair: accepted. `oneTwice`, one allocation at two slots: refused.
  - Two calls of `mk`: accepted. One call used twice: refused.
  - Alias through `idl`, kept: refused. Alias through `idl`, dead: accepted.
  - `pairOf xs xs`: refused. `pairOf xs ys`: accepted ⇐ sel.
  - `rebuildImported`: accepted. `keepOldImported`: refused.

  61 imported contracts across all runs encode again to the same words: 0 mismatches.
- **Declarations reversed.** `TestSet` against `Reversed` (the same module in reverse order), and `ImportRT` against its reversed importer, give identical verdicts and contracts: 34 and 13 verdict lines, 22 contracts. The selection is printed and encoded in a canonical order. The records differ only in which declaration pays a shared memo's first miss.

**The family table of review §4.** All of the review's targets were run against master. The table shows what was kept, what was recovered and what is not checked.

| Family | Same | R→A (all checked sound) | Other |
|---|---|---|---|
| `FoldCertificateImported`, `ImportedPair`, `Wrapper`, `FoldedKnotCall` | 37 | 4: `row4` (`deeper`); `Wrapper`'s safe `viaMid`, `viaLocal`, `apartMid` (the fixture names them the safe ones); `twoMid` stays refused | 4 partial→refused (negative) |
| `ApartAcrossModules` | 2 (four distinct accepted, one twice refused) | 0 | `boxed` unsupported (field steps not encoded) |
| `JoinedCallContexts` | 12 | 0 | 1 unsupported (`List.copy`) |
| `RepeatedPathCall` | 10 (`both x y` accepted, `both x x` refused, `otherRead` accepted) | 0 | 1 unsupported (`List.copy`) |
| `CycleLinkRooting` | 22 | 1: `underTwoApart`, a known false refusal (#1495/#1562) | 0 |
| `CrossDepthKids` | 21 (`gap6Apart` accepted, `gap1/2/6` refused) | 0 | 4 unsupported (`List.append` row), 1 partial→refused |
| `JoinFoldChoice` | 7 | 2: `depthArms`, `distinctArms` (#1502, the fixture says they should be accepted) | 0 |
| `FoldRelabelCall` | 6 | 4: the `…Apart` twins (#1495; v1 accepts them) | 5 partial→refused (the shared witnesses) |
| `LinkedFoldCoverage` | 11 | 0 | 3 partial→refused (`kidsOfItself`, `sameTree`, `sameTreeIdent`) |
| `ViewFoldRoute` | 8 | 1: `freshDeeper` (#1501, "should be accepted") | `copyRead` unsupported (`List.copy`) |
| `FoldedBCall` | 8 (`distinct`, `chosen` accepted; `shared`/`viaHelper`/`viaWrapper` refused) | 0 | 3 partial→refused |
| `RefinementFoldMultiplicity` | 10 | 2: `takenTwo`, `apartFresh` (#1503, "should be accepted") | 2 partial→refused (`takenTwice`, `regraftShared`) |

In all, the 22 fixtures have 280 demand positions:
- 229 are the same as master (172 accepted, 53 refused, 4 partial in both);
- **0 are accept→refuse**;
- 17 are refuse→accept, all documented safe;
- 26 are partial→refused, every one inside a call that master also refuses;
- 8 are not checked: their declarations are reported unsupported.

So the 126 "ordinary recovery targets" of review §4 that these fixtures hold are kept. Master accepts them, and so does the evaluator. The 17 "partial successes in negative witnesses" are refused whole, which is the stronger rejection the review allows.

## Checkpoint 5: cost families and a second recursion shape

All runs are Debug, one worker, at the default allowance. "Source lane" is the continuation share of the records; here it is all of them, since no family exceeds K·I_f. Peak bytes is the largest arena of one declaration's evaluation.

| Family | Time | Max RSS | Module total | `removeMin*` total (growth) | Settled walk | `balance*` | Slots | Arrivals | Relation facts | Deliveries | Substitutions | Validation | Peak bytes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Copies 1 | 0.03 s | 33 MB | 15,031 | 11,636 (0) | 3,239 | 1,817 | 46 | 74 | 819 | 4 | 752 | 3,239 | 52,376 |
| Copies 2 | 0.03 s | 34 MB | 30,056 | 23,272 (0) | 3,239 | 3,628 | 92 | 148 | 1,638 | 8 | 1,504 | 6,478 | 52,376 |
| Copies 4 | 0.04 s | 34 MB | 60,106 | 46,544 (0) | 3,239 | 7,250 | 184 | 296 | 3,276 | 16 | 3,008 | 12,956 | 52,376 |
| Copies 8 | 0.07 s | 35 MB | 120,206 | 93,088 (0) | 3,239 | 14,494 | 368 | 592 | 6,552 | 32 | 6,016 | 25,912 | 52,376 |
| Fields 1 | 0.02 s | 33 MB | 15,031 | 11,636 (0) | 3,239 | 1,817 | 46 | 74 | 819 | 4 | 752 | 3,239 | 52,376 |
| Fields 2 | 0.03 s | 34 MB | 26,125 | 20,478 (0) | 5,809 | 2,992 | 92 | 148 | 835 | 4 | 1,504 | 5,809 | 56,680 |
| Fields 4 | 0.04 s | 34 MB | 48,962 | 38,703 (0) | 11,098 | 5,198 | 184 | 296 | 1,421 | 4 | 3,008 | 11,098 | 111,528 |
| Fields 8 | 0.06 s | 35 MB | 95,860 | 75,123 (0) | 21,670 | 9,610 | 368 | 592 | 2,904 | 4 | 6,016 | 21,670 | 223,654 |

- **Copies are exactly proportional.**
- **Fields are linear.** Each doubling multiplies by 1.76, 1.89 and 1.94; the selection size is 5 per field; relation facts grow linearly. At 8 fields `removeMin` totals 75,123 records, with growth 0 because the source continuation grows with I_f. A first version checked every pair of leaves and was quadratic (relation facts 794 → 25,252). Factoring the check, as described above, removed that. **No dense relation was requested in these families.**
- **The second recursion shape, `Dict.descend` (the product control).** Generic, core: 7 rounds, 33,930 records, growth 0. The settled walk is 5,161, with 82 slots and 150 arrivals. This is the Cursor × Tree product: each `Step`'s tree slots take arrivals from every tree family of `π1`, and from `π2`'s matching cursor slots. It is reported here apart, as the review asked. It is O(result slots × parameter slots), the provenance the contract must state. `List Int` `descend` (`TestSet`) costs 20,442. Master's core `descend` is unchecked ("not built: call").
- **Repeated walks, the shortened `InitializationLimit.rotate`.** With N lists, it settles in N+1 rounds of O(N) walks.

  | N | Rounds | Total | Walks |
  |---|---|---|---|
  | 2 | 3 | 462 | 69…141 |
  | 4 | 5 | 960 | 83…207 |
  | 8 | 9 | 2,436 | 111…339 |
  | 15 | 16 | 6,559 | 160…570 |

  This is O(N²). The prototype re-walks the body once per round, where the review asks for deliveries. The 41-parameter original exceeds the prototype's 16-parameter limit and is reported unsupported. This is a known gap: the build must deliver facts along recursive edges instead of re-walking.

## Oracles

- **Runtime** (`oracle/Writers.beni`). The whole module is checked: no unsupported declaration, no refusal. It holds `useful`, `usefulParam`, `rebuild` (twice), `allParam` (twice) and a generic-payload `rebuildG`, all built from fresh trees by a checked `main`.
  - Copy semantics (mode 4: no write published), plain, and `--sanitize-lists`: the output is the same seven lines.
  - The sanitized build wraps all 5 accepted `List.push` sites, and no write traps.
- **Unsafe control** (`oracle/UnsafeDup.beni`: `rebuildDup` over a tree where `moveRedLeftDup` duplicates).
  - Mode 1: refused (`l` holds it), so the module publishes no write.
  - Mode 3 (forced-unsafe) with `--sanitize-lists`: it **traps**, "a stale read of a list …, which `List.push` in … changed in place", exit 1.
  - Mode 3 without the sanitizer, and mode 4, print the copy output.
- **Semantic obligations, not node ids.** The comparisons against master are per demand position and verdict. The contracts are compared as canonical text.

## Limits of this prototype

- **First-order only.** The following are reported `unsupported`, never routed into v2:
  - lambdas, local functions, function values, record update, `try`, markup;
  - core rows other than `borrowed`, `written`, `returned`, `stored`, `unused`, and the result words `prepended`, `fresh` and `exclusive`;
  - more than 16 parameters.
- **Liveness is a call-level use.** A call reads its arguments at the call. v2 knows which paths a callee reads (R-4.8.2's untouched fields); the evaluator does not, which costs precision and not soundness.
- **A selection is a union.** Needing `Apart(X, T)` also asks each region to be internally separate. A read-only holder region that repeats objects inside itself makes a write beside it refused, where v2 can accept. None of the sampled fixtures shows this.
- **The import codec** has no field steps.
- **`rotate` re-walks** each round (above).
- **Determinism** was checked by declaration reversal only, not with `--jobs=8`.

## What a spec amendment and a staged build would involve

**Amendment.** These would be new §2.x sections, replacing §2.3's shape nodes, §2.9's κ machinery and §2.11's lazy call views for the local value analysis. §2.7–§2.8's liveness, demand vocabulary and diagnostics stay.
1. **Slots, positions and roots.** Canonical slots expanded through `expandLevels`. Concrete positions per root, with the list-step algebra and normalised slices.
2. **Leaves and the one relation.** Same root: overlap at related positions with meeting slots, else apart under the root's separation. Different roots: the later call is expanded first. Two parameters are apart under both selections. Atoms are compared by identity.
3. **The selection** (Sep restricted to occurrences) as the only condition, a union. The factored distinctness check, its linear bound, and the routed rule with per-parameter routes.
4. **Contracts.** Arrivals per result slot, W, `req` and `res_cond`. Instantiation once per call site. ⊥ for an empty recursive result. The fixed point from ⊥, then a separate validation.
5. **Choices** as tags, compared arm by arm.
6. **Writes and demands.** The demand check on slots (pending operands, live locals, `req`), and the verdict grounds `fresh`/`call`/`param`.
7. **Block format v-next.** A slot contract with constructor steps as (ordinal, arg) and field steps by name text. It is validated by re-encoding, and incompatible cache entries are invalidated.

**Staged build.** Each stage keeps the current default until §8.2's switch-over criteria pass; there is no per-program fallback.
- **S1.** The slot evaluator behind a flag. Port the seven requirements above and the controls as corpus fixtures, each red first. Add field-step encoding and the remaining core rows.
- **S2.** Deliveries along recursive edges instead of re-walking (`rotate`). Measure `descend`'s product at scale.
- **S3.** Callbacks, accumulator folds, retained values and loans: the review's next checkpoint. Expect context growth to show here first.
- **S4.** Liveness reads with the callee's read footprint (R-4.8.2's precision), and v2's holder-index techniques on slots.
- **S5.** The complete ledger on all 477 fixture tokens, core and platforms whole, then a release-toolchain throughput measurement against R-7.1.
- **S6.** Switch-over and the deletion plan (§8.3).

## Files

Under `~/.cache/beni-agents/slot-exp/`:
- `report.md`;
- `final/`: every run of the last binary (probes, core, `fix/`, `fam/`, `scale/`, `oracle/`), each with its master twin;
- `probes/` (`TestSet`, `Controls`, `RemoveMinProbe`, `Reversed`, `Imported`, `ImportRT`, `ImportRev`, `Useful`, `Dup`), `oracle/` (`Writers.beni`, `UnsafeDup.beni`), `scale/`;
- the scripts `run.sh`, `final.sh`, `cmp.mjs`, `norm.mjs`, `gen.mjs`, `genrot.mjs`, `scalesum.mjs`.

On branch `exp-slot-domain`:
- the prototype, in `src/own2/Slots.zig`, `src/own2/ReaderProbe.zig` and the plumbing;
- the probes, scripts and this report under `experiments/slot-domain/`.
