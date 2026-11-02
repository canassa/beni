# Recursive contracts for ownership v2: the experiment

Agent lane `contracts-exp` on dagon, 2026-11-01/02. It was approved by the owner, as the test of the astra review's §4 A and §7. Base: `origin/master` `99f9dc078c`. Builds: self-hosted Debug only. The code is a scratch prototype on branch `exp-recursive-contracts`. Nothing is merged, and master is unchanged.

## Verdict

**Refuted on cost, and only partly confirmed on the domain.**

The fixed-slot contract behaves as the hypothesis says on four counts:
- Its inventory is fixed by the typed interface: 20 slots and 18 origins for `removeMin`, the same in every round.
- It converges in 4 rounds, with no annotation and no copy of an earlier round's answer.
- The non-duplication predicate is inferred and validated from the BIR, and its validator rejects false contracts.
- Every soundness control stays refused: #1516, #1530, alias, old tree kept, duplicating helper, repeated payload, `pushDup`, `aliased`/`twice`/`mixed`.

But **`removeMin` fits the default account (65,536 growth) in no sound configuration**, and the cost is not in the contract:
- One walk of `removeMin`'s body by v2's local checker costs 100–900k records.
- That cost is in the body's `case` joins over the many-armed summaries of `balance`/`moveRedLeft`, with `propagate` over them.
- Even walk 1, against an empty port, costs about 100k records.

The review's §7 confirm criteria, one by one:

| Criterion | Result |
|---|---|
| The helpers need no annotations | **Yes** |
| The contract inventory stays fixed across solver rounds | **Yes**: the port is rebuilt from 20 fixed slots every round |
| The helpers fit the default account (65,536 growth) | **No**: generic `removeMin` 1.92M growth at stage 2 (sound); `removeMinL` (`List Int` payloads) 3.64M; core's `Dict.removeMin` is still a limit |
| The useful owned-payload caller passes | **Yes**, with the allowance raised. It is also built and run, and the sanitiser agrees |
| The alias and duplication controls fail | **Yes**, all of them |
| The precision ledger is as predicted or better | **Mostly**: no unsound acceptance; 65 accept→refuse lines, all fold-certificate witnesses (`FoldCertificate.oneView` family); `descend` and `InitializationLimit.rotate` become limits; `FoldedPreimageCall` gains a check |

The refutation conditions, one by one:

| Refutation condition | Result |
|---|---|
| The fixed contract needs expanding co-occurrence histories again | **No** |
| Preservation needs trusted per-case assertions | **No** |
| The useful callers need the positional graph that was removed | **Partly**. Writing every payload of `removeMin`'s answer, or putting the edited payload back beside the surviving subtrees (`rebuild`), is refused, because the merged slots let every payload slot alias every other. Master cannot check those callers either. |

**#1516 and #1530 controls: they pass**, in their corpus forms and in recursive variants written for this experiment.

**`WriteOneLevel`: no loss.**

What this means:
- The review is right that a recursive boundary can be a fixed, finite, checked contract.
- The removed history accounts for master's explosion from walk 3 on (0.91M → 4.05M → 15.1M growth for walks 3–5). The contract replaces it with a constant ~0.85M per walk.
- But walk 2 is no cheaper (master 124,682, contract 182,740), and 0.85M per walk is 13× the default.
- To reach the budget, the *body* walk must get cheaper. Compact summaries at non-recursive boundaries (stage 8) are the only measured lever, and they cost 143 corpus lines of precision.
- Even stage 8 is a limit for `removeMin` once the port is sound.

## What was built (branch `exp-recursive-contracts`)

The flag is `--ownership-contracts=N` (hidden). The code is at the end of `src/own2/Groups.zig`, with `solveGroup` routing to it and five lines of plumbing. It consumes typed BIR through v2's own adapters: Place canonical paths, cells, Shape, Cond, Summary, Walk, Liveness and Holders, all unchanged. Only a recursive call's port is replaced.

- **Slots.** For each member, the canonical paths of its result place (`Place.extend` over every step). This is a finite graph with the place graph's own cycles, and nothing else is inventory.
- **A round.**
  1. The port is built **afresh from the slots alone**: a node per slot, children per step, tied into the place graph's cycles. A place with no steps (a type variable) is a leaf. Approximate cells become a recast over a leaf, joined with the exact part.
  2. Every member is walked once by v2's walk against these ports.
  3. α maps the read-off onto the slots. It visits `(slot, node)` pairs through `Shape.proj`, takes join sides one by one, and keeps the approximate bits. Parameter cells, v2 fresh cells and `⊤` stay as they are; anything else becomes `⊤`.
  4. Use marks, `xreq`, `refs` and `writes` are joined.
  5. Stop when nothing grows. The last walks read the ports as they stand, so they are the validation walks, and their lines are reported.
- **Stage 1.** No stored κ: a built node reads `lost`, so the answer is never exclusive.
- **Stage 2.** One predicate per member, *occurrence tokens* over the BIR:
  - per parameter, the most times one of its objects occurs in the answer (0, 1 or 2 = repeated), and whether fresh objects repeat;
  - tokens are pattern paths from parameters, sites, and parts of opaque values (call results and choices);
  - aliases share a token; parts of a clean value are disjoint;
  - components built together add, arms take the maximum, and a call's answer expands to the callee's multiplicities;
  - imported callees are read off their v2 class and κ.

  The candidate is a least fixed point from 0. A **separate validator** evaluates each body once more under the candidate (base and step in one evaluation) and refuses a candidate the body exceeds. A slot whose origins all occur at most once stores its arrivals' summary condition as atoms (`summaryExcl ∧ apart`): "if the caller separates them, the answer keeps it". A member that preserves everything publishes the fold certificate.
- **Stage 3** (false-contract control). The validator alone faces the forced claim "every object at most once".
- **Stage 4** (forced-unsafe control). The claim is published whatever the validator says.
- **Stages 5 and 8** (diagnostic variants). First-order non-recursive helpers get contracts too: 5 with the predicate, 8 without.
- **Out of scope; v2 keeps them:** groups with a function in a parameter or result, or a lambda in a body.

Three soundness defects of the prototype were found by the controls and fixed before the final numbers. Each one is a constraint the spec must state:
1. **Fresh identity.** Per-slot fresh renaming lost cross-position aliasing (`LevelFresh.pushDup` was accepted). One allocation must be one cell at every slot.
2. **Stored atoms, not derived reads.** A stored `yes` read through the instantiated cell set collapsed two arrivals into one (`CombinePositions.mixed` was accepted). κ must be atoms over the callee's own arrivals.
3. **Leaves and recasts.** A built node at a type-variable place dropped every read below it (stage 8 `CallTyvarViews`). Approximate cells copied into nodes dropped a builder's stored values (core `List.repeat` lost `A`). Type-variable slots are leaves, and approximate cells keep recast semantics.

The earlier, cheaper numbers were not sound.

## Test set (review §7)

The final binary at stage 2, with the allowance raised to 20M where `removeMin` needs it. "Master" is v2 on `99f9dc078c`.

| # | Case | Master v2 | Contract (stage 2) | Expected | Note |
|---|---|---|---|---|---|
| 1 | generic `removeMin`/`balance`/`moveRedLeft` | limit; 31.8 s to its limit at 20M | checks at 20M: 4 rounds, 1.92M growth, 4.4 s; limit at default | — | multiplicity 1, validated, certified |
| 1 | scalar payloads | checks | checks (trivial) | — | |
| 1 | `List Int` payloads (`removeMinL`) | limit | checks at 20M, 3.64M growth; limit at default | — | 25 slots, 23 origins |
| 1 | `Dict.descend` | checks (41,937 growth) | **limit**: 87 slots, 6 rounds | — | **regression**: the `Cursor` × `Tree` slot product |
| 2 | `useful`: tree built, old tree gone, payload edited | not built | **accepted fresh**; runs `[5,9]` plain and sanitised | accept | |
| 2b | the same on a parameter | not built | accepted param; runs `[10,9]` | accept | |
| 2c | `rebuild`: edited payload beside `l`, `r` | not built | refused (`r` holds it) | — | **precision loss**: merged slots |
| 3 | old tree kept and read | not built | **refused** alias `t#NodeL.2` | refuse | |
| 3b | external alias | not built | **refused** alias `xs` | refuse | |
| 4 | `removeMinDup` contract | limit | multiplicity 2, fresh repeat | fail | |
| 4 | dependent writers `rebuildDup`, `allDup` | not built | **refused** | refuse | `usefulDup` (payload of a *dead* answer) is accepted, and is safe |
| 5 | repeated payload, every payload written | not built | **refused** disjoint | refuse | so is `allParam` |
| 6 | `ChoiceArmsParams.same`/`both` | accepted/refused | same | golden | not recursive |
| 6 | `WriteOneLevel.runFresh`/`c1` | accepted/golden | same | golden | **no loss** |
| 6 | `FoldCertificate.oneView`/`twoViews` | accepted/refused | **4 of 5 lines refused**/refused | golden | **loss**: certificate readers |
| 6 | `LevelFresh.pushRoot`/`pushDup` | accepted/refused | same | golden | |
| 7 | #1516, and a recursive `wrapN` variant | refused (`pushOnce` accepted) | same | refuse | |
| 7 | #1530 recursive readers, and a `deepLen` variant | refused | same, through the contract | refuse | |
| 8 | imported caller | Lib limit | Main: `usefulImported` accepted, `keepOldImported` refused | | the contract crosses the block |
| 8 | declarations reversed | — | identical verdicts and statistics | identical | |
| V | stage 3: forced claim "every object once" | — | accepted for `removeMinL`, **refused for `removeMinDup`** | reject false | |
| U | stage 4 forced-unsafe (`dupEach`/`bumpFirst`) | refused at stage 2 | accepted; **the sanitiser traps** "stale read of a list … `List.push` changed in place" | detected | |

## Measurements

Separate from dump printing: the account lines are the checker's own counters. Debug, `--jobs=1`.

Walk by walk, generic `removeMin` at 20M (cumulative growth / total records):

| Walk | Master v2 | Stage 1 | Stage 2 | Stage 8 |
|---|---|---|---|---|
| 1 | 0 / 34,667 | 10,206 / 106,237 | 13,143 / 109,174 | |
| 2 | **124,682 / 221,414** | **172,463 / 269,256** | **182,740 / 279,533** | |
| 3 | 911,838 | 1,063,673 | 1,074,627 | |
| 4 | 4,051,238 | 1,895,618 (settled) | 1,908,265 (settled) | 1,445,917 (3 walks) |
| 5 | 15,121,701 | | | |
| end | limit at 20M; 31.8–44.5 s; 150 MB | 4.1 s, 78 MB | 4.4 s, 81 MB | 5.1 s, 59 MB |

**For the coordinator's 236,025 (#1620):** on this probe, master's walk 2 is 124,682 growth (221,414 total). The contract's walk 2 is 182,740 (279,533 total). It removes none of walk 2's cost and adds about 58k, from the stored atoms and the recast/union parts of the sound port. Walk 2's cost is the body walk: the outer `case` joins `%74` and `%87` cost about 35k each, already in walk 1 against an empty port.

Contract work at stage 2, generic `removeMin`:

| Measure | Value |
|---|---|
| Slots | 20 |
| Slot cells | 235 |
| Origins | 18 |
| Port nodes | 45, fixed |
| α visits | 2,870 |
| Tokens | 130 |
| Token inference ops | 1,268 (2 rounds) |
| Validation ops | 1,066 |
| Fact deliveries | 0: it re-walks instead |

That is under 1% of the account.

**Core** (`--jobs=4`): master 1.7–2.1 s and 83 MB; stage 2 2.0 s and 87 MB; stage 8 6.5 s and 114 MB. Verdict lines 48/48 identical. `Dict.removeMin` stays a limit; `Dict.descend` becomes one.

**Scaling** (allowance 20M; the contract converges in 4 rounds at stage 2 and 3 at stage 8, whatever the size):

| Family | n | Stage 2 total records | Stage 2 time | Stage 8 total | Stage 8 time |
|---|---|---|---|---|---|
| Independent copies | 1 | 3.75M | 7.7 s | 2.25M | 3.5 s |
| | 2 | 7.49M | 17.5 s | 4.50M | 7.8 s |
| | 4 | 14.99M | 43.2 s | 9.00M | 18.2 s |
| | 8 | 29.98M | 125 s | 17.99M | 47.5 s |
| Payload fields | 1 | 3.75M | 7.4 s | 2.25M | 3.3 s |
| | 2 | 6.90M | 13.9 s | 4.10M | 6.0 s |
| | 3 | 11.30M | 23.7 s | 6.69M | 10.9 s |
| | 4 | 17.19M | 38.3 s | 10.06M | 17.7 s |

- **Copies:** records are exactly linear.
- **Fields:** +3.15M, +4.41M, +5.89M per field, a pairwise term in the body walk.
- The contract's own slots and origins are linear (+10 per field).
- At the default allowance every row is a limit for master, stage 2 and stage 8.

**Runtime.** Stage 2, stage 2 with `--sanitize-lists`, and stage 8 with `--sanitize-lists` all print `[5,9] [10,9] [22,7]`. All 3 accepted writes are wrapped and none traps. The forced-unsafe control traps.

**Seeded variant (negative result).** Slots seeded at the top of the vocabulary: `descend` grew to 790k and `removeMinL` tripped a `call_view` lane invariant. Dropped.

## Precision ledger

All 477 fixture-tokens of `tests/corpus/ownership/`, every verdict line diffed against master on the same binary:

| Stage | Same | Accept→refuse | Refuse→accept | New limits | Limits gone | Crashes |
|---|---|---|---|---|---|---|
| 1 | 3,956 | 67 | 4 | `InitializationLimit.rotate` | `FoldedPreimageCall.incAs` | 0 |
| **2** | **3,960** | **65** | **2** | `InitializationLimit.rotate` | `FoldedPreimageCall.incAs` | **0** |
| 5 | 3,652 | 97 | 6 | 11 | 1 | 7 (C7, #1485) |
| 8 | 3,875 | 143 | 4 | 2 | 1 | 0 |

**Stage 2, every accept→refuse change** (65 lines; all become `rejected disjoint: another path of the same argument reaches it`):

| Fixture and line | Declaration | Lines |
|---|---|---|
| `FoldCertificate` 168 | `twoTrees` | 8 |
| `FoldCertificate` 172 | `oneView` | 4 |
| `FoldCertificate` 195 | `row1` | 4 |
| `FoldCertificate` 215 | `row6` | 1 |
| `FoldCertificate` 223 | `row8` | 4 |
| `FoldCertificate` 227 | `row9` | 4 |
| `FoldCertificate` 240 | `row14` | 2 |
| `FoldCertificate` 255 | `row14List` | 2 |
| `FoldCertificate` 268 | `row18` | 1 |
| `FoldCertificate` 278 | `row19` | 2 |
| `FoldCertificateImported` 48, 52, 74, 94 | the same witnesses | 8, 4, 4, 1 |
| `FoldCertificateImportedPair` 23 | | 4 |
| `FoldCertificateWrapper` 39 | | 4 |
| `FoldedKnotCall` 76 | `incAll` | 4 |
| `FoldedKnotCall` 88 | `incBelow` | 4 |

*Reason:* master accepts these through the fold certificate's readers: rule 4, reader 3 and item 3 (d). They read certified classes through `widen`'s fold classes, and the contract's knots are one node per slot. Publishing the certificate bit, which the validated predicate justifies, recovers none of them. It is an integration gap, and a measured loss.

**Stage 2, every refuse→accept change** (2 lines): `FoldCertificateImported` 86, `row4 = incAll (Lib.deeper t)`, at `#Node.2⟨Tree⟩#Node.1` and `#Node.2#Node.1`: "rejected disjoint (approx)" becomes "accepted param".

*Soundness:* `deeper` builds its answer from five pairwise disjoint parts of its input, each once. The validated predicate gives every input list at most once in the answer. `incAll` writes each list once, which is safe when the caller's lists are separate, and "param" passes exactly that obligation to `row4`'s callers.

**Stage 2, the other changes:**
- `FoldedPreimageCall`: a limit on master; checked, agreeing with v1's golden per call site.
- `InitializationLimit.rotate` becomes a limit, because the prototype re-walks once per round (about 40 rounds) where master delivers cells along the recursive edges.
- 35 added lines, all extra paths of declarations already refused.

**Stages 1 and 8, the 4 refuse→accept lines:** `CombinePositions.bump`'s call sites, which come with a new refusal *inside* `bump` (36:26). The module stays refused.

**Stages 5 and 8** (diagnostic): 143 accept→refuse lines at stage 8 in 31 fixtures (the certificate family, `CycleLinkRooting`, `JoinFoldChoice`, `LinkedJoinCertificate`, `RefinementFoldMultiplicity`, `ViewFoldRoute`, `CrossDepthKids` and others): the positional precision of non-recursive helper summaries. Stage 5's certified helper contracts trip C7 in 7 fixtures.

## Spec amendment and build: what it would involve

**What could be deleted for recursive groups:**
- the port-side machinery: arm sets and choice ports for group ports, `dropCovered`/4d over ports, round-to-round `widen` of ports and `shapeMove`/the wake rule;
- the knot-image transport across rounds (#1590);
- most of `runGroup`'s whole-class deliver/propagate.

**What stays:**
- the local checker: Transfer, liveness, holders, demands, diagnostics, accounting and blocks;
- the place graph (the slots are its paths);
- κ atoms;
- v2's walk, as the step function and as the validator of origins and marks.

The prototype adds about 1,460 lines. No net deletion can be promised before the readers below are reworked.

**What the amendment must add:**
1. Slots are canonical result paths. A slot with no steps is a leaf; approximate cells keep recast semantics; one allocation is one cell at every slot.
2. A preserved slot stores atoms over its own arrivals.
3. The predicate and its separate validator. The certificate is published only when every multiplicity ≤ 1 and fresh objects do not repeat.
4. The certificate readers must accept slot knots, or the slots must be widened into fold classes (65 lines depend on it).
5. Rounds must deliver facts, not re-walk (`rotate`).
6. Product slot graphs (`Cursor` over `Tree`) need a quotient.

**What it would not fix: the body walk.** The decision left is the review's last paragraph:
- either coarser summaries at every boundary (the stage-8 ledger) plus a cheaper body walk (`propagate` over the case joins, #1620);
- or v2's precision with `Dict` as a limit.

The contract alone does neither.

## Files

- `probes/`: `TestSet`, `Controls`, `Imported/`, `RemoveMinProbe`/`Big`, `Reversed`.
- `runp/`: `Useful.beni`, `Dup.beni`.
- `scale/` and `gen.mjs`: the scaling families.
- `ledger/`: the dumps and `diff{1,2,5,8}.txt`.
- `final/`: the final probe and core dumps.
- Branch `exp-recursive-contracts`: the prototype, plus the probes and scripts under `experiments/recursive-contracts/`.
