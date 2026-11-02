# Contracts plus S6d: the experiment

Agent lane `contracts-s6d` on dagon, 2026-11-02, approved by the owner as "contracts plus S6d". Base: `origin/master` `8d14b80c60` (with S0 and S1 of the data-oriented plan). The prototype is `exp-recursive-contracts` rebased onto it, plus S6d, on branch `exp-contracts-s6d`. Nothing is merged; master is unchanged.

Builds: self-hosted ReleaseSafe only (`use_llvm = false` on the default exe), safety allocator off; one build for the measurements, one with `-Downership-full-cross-check` for the reference check. All runs `dump --stage=ownership --ownership=v2 --ownership-everywhere --jobs=1`, except core (`--jobs=4`).

| Name | Flags |
|---|---|
| master | v2 as on master |
| master + S6d | `--ownership-s6d=1` |
| contracts | `--ownership-contracts=2` (the last experiment's stage 2: recursive groups only) |
| contracts + S6d | `--ownership-contracts=2 --ownership-s6d=1` |
| helper contracts | `--ownership-contracts=8` (stage 8: first-order helpers get contracts too, κ `lost`) |
| helper contracts + S6d | `--ownership-contracts=8 --ownership-s6d=1` |

## Verdict

**Refuted.** S6d does not make a `case` join over `balance`'s summary about linear in I_f, and contracts + S6d bring neither generic `removeMin`, nor `removeMinL` (`List Int` payloads), nor core's `Dict.removeMin` under the default allowance, in any configuration.

- **S6d is exact, and small.** It gives the same snapshot ids as fold-first and as the reference on every call checked, and changes no verdict line in the corpus. It removes 15 % of `removeMin`'s records (2.01M → 1.71M) and 20 % of `removeMinL`'s (3.73M → 2.98M).
- **It cannot be large.** Fold-first already reads each state of Σ once. A DP in position order does at least one transfer per (position, state), so ordering positions can only replace `Propagate`'s own keyed memos: 10 % of the join (3,448 of 33,788 records on walk 1's largest join). The rest is the readers one state calls: the κ machine (22–29 % of the join), `frontierWith` (32–39 %), `side` and `proj` (18–33 %).
- **The cheapest sound configuration** is helper contracts + S6d: `removeMin` 1.15M records (1.05M growth, 16× the default), at the price of the stage-8 ledger (143 accept→refuse lines).
- **The per-walk cost is not c·I_f with a small c.** Contracts + S6d: 1,151 records per written instruction on walk 1, 7,400–7,960 on walks 3–4 (K = 1,024).
- **The pairwise term in payload fields stays**; S6d only scales it down.

**Why: the local value model, not arms that callers can tell apart.** On walk 3's largest join, 1,194 states produce 153 distinct (node, κ) entries over only **2 distinct κ conditions**. Walk 1's largest: 109 states, 55 entries, 2 κ. Nearly all the work makes no observable distinction, yet the states cannot be merged exactly in v2's domain:
- each state is a different set of the members' possible contents (atoms: the non-union nodes under a member's union DAG), and normalising union DAGs merges none of the 1,194;
- splitting runs into single atoms makes more states (3,024 (node, atom, position) triples), not fewer;
- the joined value folds at period 1 (a union of leaves at `Tree`'s knot), while the members, lazy unions of leaves, views and recasts, project to distinct nodes for many levels before they cycle;
- each state costs 230–280 records, 90 % of them dictionary operations (`memo`, `inspection`) in the lazy readers.

What a different local domain would need is §6. That question is the owner's and Astra's.

## 1. Attribution: one `case` join over `balance`'s summary

`%210`: `case moveRedLeft tree of Node … → balance nColor nKey nValue (removeMin nLeft) nRight; Leaf → Leaf`, contracts (stage 2), generic `removeMin`. `%223`, the enclosing join, is the same.

**The arms.** Each outer join has **2 arms**. The "many-armed summary" is not the `case`: it is the `choice` DAG inside one arm's value, `balance`'s 5-arm `res` instantiated lazily as views under the call's environment, with the port's knot where `removeMin nLeft` stands.

| | walk 1 (port from 20 empty slots) | walk 3 (port: 113 nodes) | master, walk 1 (port ⊥) |
|---|---|---|---|
| records: shape join / κ merge / `propagate` | 117 / 258 / 34,299 | 292 / 257 / 304,124 | 92 / 10 / 7,936 |
| `propagate` pass 1 / 2 / 3 | 30,727 / 815 / 2,246 | 274,888 / 14,248 / 13,905 | 7,426 / 75 / 252 |
| states of Σ / edges | 109 / 259 | 1,194 / 6,019 | 19 / 19 |
| output positions: open sets / folds | 54 / 4 | 45 / 5 | 16 / 0 |
| distinct joined nodes (max states per node) | 70 (6) | 118 (56) | |
| joined nodes by kind, per state | choice 52, view 50, union 7 | union 501, recast 272, leaf 235, view 131, choice 55 | |
| distinct runs / run members | 95 / 161 | 289 / 2,093 | |
| members by kind | choice 51, view 49, union 42, leaf 18, node 1 | union 1,547, leaf 457, choice 54, view 34, node 1 | |
| states storing an entry | 56 | 1,076 | |
| **distinct (node, κ) entries** | **55** | **153** | |
| **distinct κ conditions** | **2** | **2** | |
| states after normalising member union DAGs | 109 (none merge) | 1,194 (none merge) | |
| distinct atoms / (node, atom, position) triples | 121 / 240 | 173 / 3,024 | |

**Pass 1 by phase (records).**

| phase | walk 1 | walk 3 | what it is |
|---|---|---|---|
| head | 995 | 5,153 | link test, kept entry, clean memo |
| κ of the run | 10,038 | 65,679 | `kappaOf` per member: the κ machine through views, choices, unions |
| fold condition | 0 | 4,275 | `foldCondOf` |
| redundant test | 91 | 1,442 | `force`, `kappaRead`, `leq` |
| frontier | 13,447 | 97,466 | `cursorSteps`, `frontierWith`: `proj` of the joined node at each named and linked step, and recast inners |
| below | 6,067 | 99,680 | `side` and `proj` of each member along each edge, the run interned |

**By category (whole call).**

| category | walk 1 | walk 3 |
|---|---|---|
| memo (dictionary operations, hits included, as §4.1 charges them) | 18,161 | 140,080 |
| inspection | 12,035 | 142,050 |
| objects made (shape, cond, set, path, cell) | 3,592 (10.6 %) | 20,911 (6.9 %) |
| `Propagate`'s own bookkeeping (memo + inspection) | 1,310 + 2,138 = 3,448 (10.2 %) | |

**Inherent, and representation.**
- *Inherent, what a caller can observe:* the output snapshot, 58 / 50 positions with 55 / 153 (node, κ) entries over 2 κ values. Building that alone would cost hundreds of records.
- *Inherent to v2's domain, not observable here:* the states. Each is a distinct set of member atoms reaching a joined node by some route; the output only joins their κ per node. κ of a union is its sides' join (O15), so a state's κ is set by its atoms, but the sets are not equal (normalising merges none) and splitting per atom gives 3,024 > 1,194. The set is the product of the members' structure (the size of the callee summaries `balance`'s `res` and the port, not of `removeMin`) with the joined value's positions.
- *Representation:* ~250 records per state, 90 % dictionary operations, through lazy views (forced one step at a time), choices (projected arm by arm) and recast inners (#1620's `via` fan-out: 272 of walk 3's 1,194 states are recasts). And the contract's port: its 20 empty slots already have the knot structure, so walk 1's join has 109 states, where master's walk 1 (port ⊥) has 19 and 7,936 records. "Even walk 1 costs 100k" is the contract's port: master's whole walk 1 is 34,680 records.

## 2. S6d: what was built, and why it gives the same snapshots

**Statement.** In one `propagate` call, fold-first's pass 1 computes, for each state `(n, bits, run)`, four functions:
- `K(c, m, msummary) = kappaOf(c, m, msummary)` per member `(m, c)` of the run, joined (alternatives) or conjoined (together) in run order;
- `CS(ctxs) = cursorSteps(ctxs)`: the sorted, distinct steps the run's cursors link, and whether one is a fold;
- `F(n, summary, CS) = frontierWith(n, summary, CS)`;
- `P(m, step, place) = proj(side(m, via), step)`, where `side` reads only `place(via)`; the child run is `[(P(mᵢ, s, place), kappaChild(cᵢ, s))]` over the members whose `P` is not null.

Fold-first caches `K`'s join per run, `CS` per run, `F` per `(n, summary, run)` and `P` per `(run, step, place, summary)`. S6d computes each once per distinct argument tuple in the call, in tables keyed by those arguments: `K` per `(c, m, msummary)`, `CS` per ctx list (interned to one id per step set), `F` per `(n, summary, CS id)`, `P` per `(m, step, place)`. Each lookup is one `memo` record, as fold-first's are. Positions are still built by pass 3, post-order over the sets, each set once.

**Same snapshot.** Each of `K`, `CS`, `F`, `P` is evaluated on the arguments fold-first passes, and within one call each is a function of them: no `tie` happens inside `propagate`, and a crossed κ read is redone at `C` when `base_epoch` moves (§2.11 *A read in flight*, *Argument 1*). So every state reads the same κ, frontier and child runs as the same ids; runs intern to the same ids (`prop_runs`); Σ, its edges, cycle bits, sets, entries, links and merges are the same, so the snapshot is fold-first's id. Fold-first equals the reference (§2.9 *It is exact*); S6d needs nothing beyond that purity.

**Why it cannot be large.** Fold-first reads each state of Σ once. A position-ordered DP whose unit is one transfer per (position, state) does at least |Σ| reads. So ordering positions only replaces `Propagate`'s keyed memos (`index`, `slice_at`, `front_at`, `below_at`, `node_edge_at`) by dense tables: 10.2 % of walk 1's join. The rest of a state's cost is in readers not keyed by position.

**Checks.** S6d against the plain rule (no S6d, no memo, both frontier orders):
- `--ownership-order-check` on `RemoveMinBig`, `TestSetBig`, `Controls`, `Reversed`, contracts + S6d: no call differs.
- `-Downership-full-cross-check`: every call's S6d rule equals the plain rule in both orders and the reference in both orders, on `Controls`, `TestSet`, `RemoveMinProbe` (master + S6d, contracts, contracts + S6d), `RemoveMinBig` (contracts + S6d, 42 s) and `Reversed` (contracts + S6d, 615 s). No call differs; no reference walk passed its 2²² frames.
- The ledger (§5): every verdict line identical with and without S6d, for master, contracts and helper contracts; core, the probes and `TestSetBig` too, summaries and block hashes included.

*Found on the way, not caused by S6d:* under `-Downership-full-cross-check`, the contract prototype trips `KappaRead.derivedCells`' flat/indexed cross-check on `RemoveMinBig`, with and without S6d (master reached its 300 s budget first, unchecked). In all 810 differing reads (24,533 on `Reversed`) the indexed read, the one used, is `lost` and the flat one stronger: precision, not soundness. The branch prints it instead of panicking, so the reference check could run.

Item 3 of the brief (contracts at helper boundaries) was measured as the existing stage 8, with and without S6d, not rebuilt.

## 3. Measurements

### `removeMin`, by walk (cumulative total records; the group's second solve, whose account is printed)

| walk | master | master + S6d | contracts | contracts + S6d | helper contracts | helper contracts + S6d |
|---|---|---|---|---|---|---|
| 1 | 34,680 | 34,755 | 109,181 | 107,073 | 128,374 | 112,825 |
| 2 | 221,395 | 211,336 | 279,209 | 273,334 | 815,016 | 617,153 |
| 3 | 1,011,332 | 861,115 | 1,168,453 | 1,013,372 | 1,537,163, settled | 1,145,642, settled |
| 4 | 4,173,011 | 3,269,051 | 2,006,153, settled | 1,701,866, settled | | |
| 5 | 15,310,015 | 11,346,001 | | | | |
| end | limit at 20M | limit at 20M | growth 1,915,859 / total 2,012,652 | 1,611,572 / 1,708,365 | 1,445,917 / 1,542,835 | 1,054,396 / 1,151,314 |
| fits 65,536 | no | no | no | no | no | no |

### `removeMinL` (`List Int` payloads; `Fields1Big`, `TestSetBig`'s body)

| walk | master | contracts | contracts + S6d | helper contracts | helper contracts + S6d |
|---|---|---|---|---|---|
| 1 | 33,043 | 136,823 | 133,086 | 140,847 | 127,666 |
| 2 | 217,386 | 345,913 | 334,333 | 1,148,119 | 856,835 |
| 3 | 939,451 | 2,085,352 | 1,702,532 | 2,183,750, settled | 1,602,911, settled |
| 4 | 3,727,249 | 3,721,158, settled | 2,968,969, settled | | |
| end | 13.7M, 45.9M (walks 5–6), limit at 50M | 3,733,069 | 2,980,880 | 2,193,111 | 1,612,272 |

### The other functions (total records; allowance 20M unless said)

| function | master | contracts | contracts + S6d | helper contracts | helper contracts + S6d |
|---|---|---|---|---|---|
| `balance` (1 walk; helper contracts 2) | 8,123 | 8,123 | 8,356 | 35,650 | 35,127 |
| `moveRedLeft` | 6,197 | 6,197 | 6,385 | 18,169 | 18,439 |
| `balanceL` / `moveRedLeftL` | | 7,877 / 6,195 | 8,097 / 6,383 | 36,808 / 19,435 | 36,272 / 19,705 |
| `descend` (`TestSetBig`) | 82,179, growth 41,937: fits (default) | 806,946, 6 walks: limit at default | 807,538 | 664,324 | 664,898 |
| `removeMinDup` | limit | 1,916,162 | 1,595,882 | 1,628,079 | 1,220,850 |
| core `Dict.removeMin` (default) | limit | limit | limit | limit | limit |
| core `Dict.descend` (default) | growth 42,044: fits (master + S6d 39,905) | limit | limit | limit | limit |

S6d adds about 3 % to a one-walk helper (`balance` 8,123 → 8,356): its tables are charged per lookup and rarely hit in one short walk. `descend`: +0.07 %.

### Records against I_f (`removeMin` I_f = 93; K = 1,024)

| configuration | walk 1 | walk 2 | walk 3 | walk 4 |
|---|---|---|---|---|
| master | 373 | 2,008 | 8,494 | 33,997 |
| contracts | 1,174 | 1,828 | 9,562 | 9,008 |
| **contracts + S6d** | **1,151** | **1,788** | **7,957** | **7,403** |
| helper contracts + S6d | 1,213 | 5,423 | 5,683 | |

Not c·I_f with a small c: walk 1 is already 1.1 K, a walk over a settled port 5.7–8 K, so four walks are about 18 K·I_f against the budget of K·I_f + 65,536 ≈ 1.7 K·I_f.

### Scaling (allowance 50M; `removeMin*` total records)

| family | n | contracts | contracts + S6d | helper contracts + S6d |
|---|---|---|---|---|
| independent copies | 1 | 3,733,069 | 2,980,880 | 1,612,272 |
| | 2 | 7,466,138 | 5,961,760 | 3,224,544 |
| | 4 | 14,932,276 | 11,923,520 | 6,449,088 |
| | 8 | 29,864,552 | 23,847,040 | 12,898,176 |
| payload fields | 1 | 3,733,069 | 2,980,880 | 1,612,272 |
| | 2 | 6,879,354 | 5,382,104 | 2,948,271 |
| | 3 | 11,280,989 | 8,641,021 | 4,804,743 |
| | 4 | 17,162,363 | 12,920,573 | 7,182,425 |

Copies: exactly linear. Fields: +3.15M, +4.40M, +5.88M (contracts); +2.40M, +3.26M, +4.28M (contracts + S6d); +1.34M, +1.86M, +2.38M (helper contracts + S6d). A constant second difference: quadratic in fields in every configuration, scaled down by S6d, not removed. It is atoms × positions: each field adds atoms (callee summaries' cells) and positions (the result's paths).

### Time (task-clock, self-hosted ReleaseSafe, safety allocator off)

| run | contracts | contracts + S6d | helper contracts | helper contracts + S6d |
|---|---|---|---|---|
| `RemoveMinBig` | 2,041 ms | 1,961 ms | 1,226 ms | 1,003 ms |
| `Fields1Big` (`List Int`) | 4,105 ms | 3,573 ms | 1,829 ms | 1,417 ms |
| core, `--jobs=4` | 3,640 ms | 3,458 ms | 6,879 ms | 7,340 ms |

Master on `RemoveMinBig` takes 27.5 s user to its 20M limit, master + S6d 38.9 s; core 3,624 / 3,575 ms. `TestSetBig`: 50.3 / 46.8 / 21.7 / 25.6 s; master did not finish in its 300 s budget. Copies 8: 64 s / 57 s / 20 s. Every `removeMin` run had a 180–300 s budget. The slow runs: master to its 20M limit (32–47 s) and the full cross-check of `Reversed` (615 s of a 900 s budget).

## 4. Soundness controls

| control | contracts | contracts + S6d | helper contracts + S6d |
|---|---|---|---|
| `Controls` probe: #1516 (`pushOnce` accepted), #1530 recursive readers, alias, old tree kept, duplicating helper, repeated payload | the last experiment's verdicts | identical lines | identical lines |
| `TestSetBig`'s callers (`useful`, `rebuild`, `keepOld`, `extAlias`, `allDup`, `repeated`, `allParam`) | as before | identical | identical |
| corpus `LevelFresh.pushDup`, `CombinePositions.aliased`/`twice`/`mixed`, `FoldCertificate.twoViews` | refused | identical | identical |
| `Useful.beni` built and run | `[5,9] [10,9] [22,7]` | the same, plain and `--sanitize-lists`, 0 traps | the same, `--sanitize-lists` |
| `Dup.beni` | refused, rc 1 | refused, rc 1 | |
| forced-unsafe control (stage 4, with S6d) | | builds; `--sanitize-lists` traps "a stale read of a list (read 0), which `List.push` in Dup … changed in place" | |
| reference cross-check | | every call of `RemoveMinBig` and `Reversed` equals the reference | |

## 5. Precision ledger

All 478 fixture tokens of `tests/corpus/ownership/`, every verdict line, one binary.

| against | same | accept→refuse | refuse→accept | lines gone / added | limit-line changes | crashes |
|---|---|---|---|---|---|---|
| master + S6d vs master | 4,030 | 0 | 0 | 0 / 0 | 0 | 0 |
| contracts + S6d vs contracts | 4,065 | 0 | 0 | 0 / 0 | 0 | 0 |
| helper contracts + S6d vs helper contracts | 4,063 | 0 | 0 | 0 / 0 | 0 | 0 |
| contracts vs master | 3,963 | 65 | 2 | 0 / 35 | 10 | 0 |
| contracts + S6d vs master | 3,963 | 65 | 2 | 0 / 35 | 10 | 0 |
| helper contracts vs master | 3,878 | 143 | 4 | 5 / 38 | 12 | 0 |
| helper contracts + S6d vs master | 3,878 | 143 | 4 | 5 / 38 | 12 | 0 |

S6d changes no line, so the contracts + S6d ledger is the last experiment's stage 2, reproduced line for line on the rebased master (`ledger/diff.m.c2.txt` and `ledger/diff.m.c26.txt` are identical).

- **65 accept→refuse**, all to "rejected disjoint: another path of the same argument reaches it", the fold-certificate witnesses: `FoldCertificate` 32 (`twoTrees`, `oneView`, `row1`, `row6`, `row8`, `row9`, `row14`, `row14List`, `row18`, `row19`), `FoldCertificateImported` 17, `FoldCertificateImportedPair` 4, `FoldCertificateWrapper` 4, `FoldedKnotCall` 8 (`incAll`, `incBelow`). The certificate's readers read certified classes through `widen`'s fold classes, and a contract's knots are one node per slot.
- **2 refuse→accept**: `FoldCertificateImported` 86, `row4 = incAll (Lib.deeper t)`. Sound: the validated predicate puts each input list at most once in `deeper`'s answer.
- **10 limit-line changes**: `FoldedPreimageCall` is checked (7 `unchecked`/`limit` lines go; its 22 added lines agree with v1's golden); `InitializationLimit.rotate` becomes a limit and `seed` "not built: call", because the prototype re-walks each round where v2 delivers along the recursive edges.
- **23 cause-text changes**: refusals whose reason gains or loses "(approx)"; same verdicts.
- **Helper contracts (143 / 4)** reproduce the last experiment's stage 8 in 31 fixtures (the certificate family, `CycleLinkRooting`, `JoinFoldChoice`, `LinkedJoinCertificate`, `RefinementFoldMultiplicity`, `ViewFoldRoute`, `CrossDepthKids` and others); the 4 refuse→accept are `CombinePositions.bump`'s call sites, with a new refusal inside `bump`.

## 6. What a different local domain would need

The joins stay superlinear while their states differ in nothing a caller reads (2 κ values a join, ≤ 153 entries for 1,194 states; copies linear, fields quadratic). The states are distinct sets of member atoms that v2's value model keeps apart along every route. So v2's local value model is the limit. From the measurements, a linear local domain needs:

1. **Values keyed by canonical result paths (slots), not by shape nodes and routes**, so a join is O(slots × arms). The contract does this at recursive boundaries: 20 slots, 2,870 α visits and 1,066 validation operations, under 1 % of the account. At every boundary this is the review's "compact summaries", whose measured price at non-recursive helpers is the stage-8 ledger (143 lines).
2. **κ per slot as atoms over arrivals**, so a join is a join of atoms. A state's κ is already a function of its atoms (O15); v2 recomputes it per atom set through the lazy machine.
3. **Callee summaries instantiated once per call site as per-slot facts**, not read lazily as views at each position of each join. On walk 1, 49 of 161 run members are views and 51 choices; the κ machine and `frontierWith` force them one step at a time, about 100–120 records a state each.
4. **An empty contract's port as ⊥**, not a knot over 20 empty slots. That alone puts walk 1 back at master's 34,680 records (from 107,073); it does not touch walks 2–4.

What stays to be paid, if v2's precision is to be kept: the certificate readers (65 lines) need slot knots or fold classes (the last experiment's item 4), and the positional precision of helper summaries (143 lines) is what a slot-keyed local domain gives up unless its slots carry the co-occurrence v2's arms carry. The other choice is v2's precision with `Dict` a known limit. This experiment does not decide between them.

## Files

Under `~/.cache/beni-agents/contracts-s6d/`: `base/` (instrumented dumps: every `propagate` line, Σ dumps, statistics), `m/` (probes per configuration), `tc/` (task-clock runs and walk traces), `scale/`, `core/`, `chk/` and `xchk/` (order and reference checks), `ledger/` (dumps and `diff.*.txt`), `runp/` (runtime oracle). Scripts `run.sh`, `ledger.sh`, `diff.mjs`, `scalerun.sh`, `scalesum.mjs`, also under `experiments/contracts-s6d/` on the branch.

Branch `exp-contracts-s6d`:
- S6d: `--ownership-s6d=N` (hidden); its tables are in `src/own2/Propagate.zig` (`memberKappa`, `memberBelow`, `cursorsOf`, `front2_at`), off while a check walks a call again (`Cond.s6d_off`).
- Instrumentation under `--ownership-propagate`: per call, records by pass, phase and category, and Σ's statistics; per `case` join and per call, its records.
- `derivedCells`' cross-check prints instead of panicking; `build.zig` builds the default exe self-hosted.
