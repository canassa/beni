# Ownership checker sync — 2026-10-15

The shipping differential bridge is recorded separately in
[BRIDGE-RESULTS.md](BRIDGE-RESULTS.md): 116,456 inputs, 43,066 translated/value-checked,
73,390 counted skips, 2,358 unconfirmed program verdict leads with typed minima,
and three caught Zig source controls. Both checkers' ownership policies are unchanged.

The executable core now models the applicable branch, model, fold and Conduit
rules from ownership-checker.md §26.7 and the amendments following §28.11.
There are **98 original + 44 sync verdict fixtures**, **204 sync products**
plus the original 144 targeted programs (**348 total**). `Sync.lean` and
COVERAGE.md map these to the Zig fixtures and describe the projections.
The compiler itself is unchanged.

## Rules and boundaries

- Branch arms start from the same incoming facts; their outgoing escape rows
  join. Earlier/joined escapes, calls and recursive escapes remain rejected.
- Model and fold conditions are greatest must-invariants over a finite
  provenance shape. Established incoming facts are retained; only discovered
  fresh result allocations receive optimistic facts. Condition rounds restore
  the outer facts, and an evaluation under the stable invariant publishes the
  effects. Exhaustion rejects.
- Container separation is distinct from deep ownership. Fresh tap containers
  can hold shared opaque callbacks; shared starts, duplicate containers,
  retained readers (including capture after append), escapes and nested writes
  through shared captures remain rejected. Empty-start folds and fresh model
  replacements have accepted/rejected twins.
- Markup render/event slots are positional records. General aliases see both;
  event projection sees only the event slot. Constructor callbacks retain
  their list-bearing arguments through higher-order calls. An explicit
  returns-owned boundary checks a retained tagger even when its calls are
  unseen; captured scalar messages pass while list captures fail. Forwarding
  a callback result carries the ordinary guarded result/supply obligations;
  fresh results pass and remain distinct across calls.
- Copying prepend reads its base; its abstract result conservatively includes
  the base's backing provenance. The withDefault/map rule is tested after
  integer-case lowering, with eager-handler and later-read rejected twins.
  Distinct numbered bindings were already enforced by round 6.

The remaining spec rows have explicit reasons: sum/early-return lowering,
re-cons views and made-after precision, foreign signature words, Expect/opaque
carriers, actual entry/render/event/fiber/navigation protocols, recursive data
types, dictionary representatives, wildcard markup encodings and summary-block
serialization have no corresponding runtime/syntax in this core. The
projections above do not prove equivalence to Zig lowering or platform code.
The withdrawn across-record map identity rule was removed as obsolete debt.

## Validation

Lean **4.29.1**, through `nix develop .#ownership`, on macOS. Logs:

- [Full Lean build](regressions/lean-build-sync.log).
- [`ownership ci` (20,000 trials, default seed 20261011)](regressions/ci-sync.log): passed. The corrected
  generator campaign had 20,000 typed programs, **2,850 accepted**, **1,789
  with writes** (62.8%), zero disagreements and zero execution errors.
  Enumeration bound 2 checked **55,966 typed programs**, accepted 31,680
  (10,468 with writes), with zero disagreements or inconclusive outcomes.
  The corrected targeted campaign accepted 112 of 348, with zero disagreements
  or inconclusive outcomes. Every required original generator control and
  every required sync enumerator control was caught.
- [Falsifier](regressions/falsify-sync.log): `ownership falsify 20000 17`
  reported `clean=true` with the strengthened concrete container predicate.
- [Authoritative audit](regressions/audit-sync.log): clean exported sources,
  parser checks, source/binary hashes and module-by-module kernel replay.
  The three unproved obligations and four sorry-dependent constants remain
  exactly the pinned set. No new proof hole is introduced.
- [`zorg build gates`](regressions/zorg-gates-final-sync.log): **1,297 passed,
  15 skipped, two failed**. Both failures are the known macOS case-folding
  stale-output tests. No ownership/compiler/runtime production source changed.

The initial compiler gate also found two cache-pruning fixtures whose 5,000
file setup exceeded macOS's 999 ms CPU fallback, including on a focused quiet
run ([before](regressions/cache-pruning-before-sync.log)). The bounded-deletion
fixture now uses 1,153 entries: one more than the 1,024 cap plus the 128-entry
examination budget, so a full prune to the cap still violates its assertion.
The recent-entry fixture uses 1,025 to enter pruning. The fixed budget and
asserted properties are unchanged; all three [focused cases pass](regressions/cache-pruning-sync.log).

## Required holes

Every row below is caught by a fixed accepted-disagreement probe **and** the
seed-independent targeted enumerator in CI. These are finite products of the
core templates, not additional random-generator families. Counts are actual
mutant-only accepted disagreements from the 348-program targeted campaign;
none was inconclusive.

| New mutant flag | Hole | Disagreements | Caught |
|---|---|---:|---|
| `branch-escapes` | Drop a compatible incoming escape at an arm | 3 | yes |
| `prepend-base` | Forget the base's later read | 4 | yes |
| `model-invariant` | Trust init/preservation conditions | 8 | yes |
| `fold-invariant` | Trust accumulator init/preservation conditions | 8 | yes |
| `result-positions` | Forget retained captures beside written result paths | 4 | yes |
| `event-capture` | Drop cells from the event projection | 16 | yes |
| `constructor-args` | Lose a constructor's retained payload | 40 | yes |
| `tagger-need` | Trust an unseen tagger's result | 8 | yes |
| `capture-empty` | Treat a nonempty retained capture as cell-free | 4 | yes |
| `forward-need` | Assume a forwarded callback result owned | 4 | yes |

The existing `branch-live` hole also catches the withDefault case projection
(three targeted disagreements). Both model/fold flags additionally have fixed
preservation probes; they cannot pass on a base-case probe alone.
`Mutant.enumeratorRequired` is checked against the probe table, and both `ci`
and `controls` run the required enumerator controls. They are not optional
merely because the older random generator lacks the new syntax.

Concrete result checks found three false certificates before the final fix
([append/focus](regressions/certificate-before-sync.log),
[canonical fold inputs](regressions/certificate-canonical-before-sync.log)):
a new record could capture a container from an earlier retained position.
All sharing constructions correctly stayed accepted, and both interpreters
agreed, but the advertised spine certificate was false. Append
and prepend now check old containers against every new path as well as the
reverse direction. Focus distinguishes its removed selected parameter from
external captures that may name retained positions. The `result-positions`
flag reintroduces all three false certificates; fixed certificate probes catch it.
Preservation also requires old containers owned in the canonical scope state:
different source/accumulator parameter names can denote the same actual array.
All accepted fixed fixtures, corrected targeted programs and accepted programs
of the falsifier now verify their advertised certificates against concrete heaps.

The first CI run exposed search sensitivity after the domain extension
([log](regressions/ci-sync-search-gap.log)): the old `keeps-shape` probe still
caught its hole, but seed 17's random stream did not. The existing element-move
now edits the moved container, while preserving the surrounding random draws
and binding counts. [The 20,000-program control campaign](regressions/keeps-shape-sync.log)
then found seven disagreements, first at index 655. The publishing-wrapper
move begins from a shallow copy so both calls have identical canonical
certificates; `forward-guards` is again caught, at index 761 in the seed-17
checkpoint. The final default-seed CI catches both required holes as well.
No original required control was downgraded to optional. Historical streams
require their historical source revisions.

The PR review found no blocking defect. Its `xres` readability suggestion is
applied as `ex.deep`; the separate spine query is unchanged. The escape mutant
now drops only incoming escapes, preserving prior calls and uses. The
[focused control](regressions/branch-escapes-review-sync.log) still catches
three disagreements among 348 typed programs. The
[full Lean build](regressions/lean-build-review-final-sync.log) was repeated
for these review changes. A fresh audit follows in the PR review response.
All 159 numbered headings of ownership-checker.md are unchanged from master.

The 65-source-edit matrix below is **historical round-6 evidence**, not a new
source-mutant sweep on this checker. The sync's current evidence is the runtime
flag campaigns and mandatory enumerator controls above. Finite campaigns and
kernel replay of conditional statements are not a completed soundness proof.

---

# Results after the sixth independent review

The prior round-6 results are historical (git revision `6513cfcb1`). They
counted `nofix1` and `oncethroughcall` twice and missed three new planted edits.
The current table counts **65 unique source edits**: the historical alias is
normalized to `oncethroughcall`, and all four sixth-review edits are included.
The final checker, interpreters, generator and search templates are the sources
of `1fc806e78`; later commits contain reports and retained evidence. Every
reported campaign uses those semantic sources. Heavy Linux work ran on `dagon`
with every descendant pinned to CPUs 0–7. Lean 4.29.1 is pinned.

## Changes per finding

1. **False summary statement:** `summary_sound` and `map_summary_sound` now
   require argument length = declaration parameter count, capture length =
   declaration capture count, and canonical input length = their sum. The
   regression actually evaluates the wrongly split bump call and demonstrates
   the old conclusion failure. Naming is independent of the split, and the
   falsifier tries every alternate boundary and checks its arity premises.
2. **Audit bypass:** command-node restrictions apply throughout the syntax
   tree, including `in` and `mutual`. `run_tac`, `run_cmd`, `run_meta`,
   `run_elab` and `by_elab` executable syntax is refused before elaboration.
   Root audit-file exceptions cannot be impersonated by a nested basename.
   The preflight injection was rejected before its IO wrote a marker; failure
   retained the exported work and logs. No `rec_*` name exempts an ordinary
   declaration. All `RecursorVal` metadata is compared with the kernel's
   regenerated recursors, including nested auxiliaries missing from Lean's
   higher-level replay metadata. The full current environment audit passes.
3. **Main theorem dependency:** agreed: only `invariant_preserved` is in
   `accepted_traces_agree`'s proof dependency chain. The step lemma carries
   the proof; the two summary statements remain separate unproved obligations.
   No artificial dependency or completed certification is claimed.
4. **Failure exits:** unknown commands/options, malformed numeric inputs,
   ignored `ci --mutant`, zero falsification and missing verdict-diff mutants
   fail before work. CI saves original/shrunk campaign witnesses, inconclusive
   program ASTs and failed fixture ASTs. Campaigns check every child status and
   publish logs only after all succeed. An injected worker failure returned 1,
   did not print done and preserved prior logs.
5. **Evidence/environment/counting:** failed audit directories survive;
   ownership supplies Node 24 and, on Linux, taskset. The source-mutant runner
   canonicalizes and deduplicates aliases. Failure probes and the actual
   source-mutated CI failure retain reproducing artifacts.
6. **Narrow grammar:** the original size-2 grammar remains 55,966 programs.
   CI additionally runs all 144 programs of a targeted Cartesian-product
   grammar: constants -1/0/1/2, both eq/lt outcomes, small first-order recur,
   captured once call counts 1/2/3, consumed captures, transitive capture
   revival, both function-join outcomes retained as data and set indices 0/1.
   The new source edits are exercised in supported shapes, without weakening
   the checker's documented `limit:` boundaries. This is still a finite small
   grammar, not exhaustive ownership-language coverage.

## Campaigns and falsification

20,000 generated programs per seed, with the per-call cross-check. All
accepted executions agree; precision differences are counted separately.

| Seed | Typed | Accepted | With write | Aliased write | Limits | Cross-only summary / per-call | Mismatches / execution errors |
|---|---:|---:|---:|---:|---:|---:|---:|
| 20261011 | 20000 | 3060 | 1967 | 1749 | 579 | 12 / 0 | 0 / 0 |
| 17 | 20000 | 3017 | 1905 | 1673 | 564 | 15 / 0 | 0 / 0 |
| 271828 | 20000 | 3052 | 1957 | 1736 | 546 | 18 / 0 | 0 / 0 |

100,000 configuration samples and calls of 100,000 generated programs per
seed; the full logs retain hypothesis, nested-capture, aliasing, low-fuel,
map-certificate and vacuity counts.

| Seed | Accepted configurations | With write | Actual calls | Checked pairs | Alternate splits tried / excluded | Split violations | Vacuity separation / description / other | Violations |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 20261011 | 66141 | 21248 | 42504 | 55908 | 103978 / 103978 | 0 | 1112 / 0 / 6 | 0 |
| 17 | 66143 | 21088 | 43013 | 56462 | 105383 / 105383 | 0 | 1182 / 1 / 11 | 0 |
| 271828 | 66247 | 21002 | 43282 | 57109 | 106103 / 106103 | 0 | 1105 / 0 / 7 | 0 |

Alternate boundaries are checked even though they are not real call records;
the naming follows the declaration, not the proposed split. The concrete
wrong-split regression meets the old premises and fails clause 1. New arity
premises exclude every wrong split above. These finite attempts still do not
cover arbitrary heaps, names or programs and do not prove the statement.
Vacuity fails above 0.5% for non-separation reasons or 5% for documented
input-alias separation. Remaining excluded calls are reported, not concealed.

## Unique planted-hole matrix

Each generator cell is **mismatches; newly accepted / newly rejected** versus
accepted indices supplied by the independent unedited executable. The full
20,000-program stream is visited on every seed, including after a mismatch.
Each newly accepted program runs at fuel 100,000. Original ASTs, per-seed
statuses and logs survive in `regressions/followup-evidence/`.

Enumeration is seed-independent and is run once per edit: its result applies
to all three seeded columns. Size-2 cells are **catch/miss; newly accepted**;
a catch stops at its first witness, so its verdict count is a prefix count.
Targeted cells are **catch/miss; newly accepted; mismatches**, for the entire
144-program space. Every source edit is built and exercised by both searches.
There are no source-mutant build failures, crashes or inconclusive runs.

| Unique source edit | Generator 20261011 | Generator 17 | Generator 271828 | Size 2 (all seeds) | Targeted (all seeds) | Verdict |
|---|---:|---:|---:|---|---|---|
| `disjoint` | 56; 92/0 | 65; 113/0 | 62; 103/0 | caught; 1 | miss; 0; 0 | caught |
| `borrowedsupply` | 0; 15/0 | 0; 18/0 | 0; 22/0 | miss; 98 | miss; 0; 0 | argued equivalent |
| `travexcl` | 31; 31/0 | 24; 26/0 | 24; 26/0 | caught; 2 | miss; 0; 0 | caught |
| `manycap` | 3; 9/0 | 10; 19/0 | 2; 4/0 | miss; 0 | miss; 0; 0 | caught |
| `copyexcl` | 10; 53/0 | 13; 59/0 | 18; 59/0 | miss; 4 | miss; 0; 0 | caught |
| `closesrc` | 62; 90/0 | 53; 82/0 | 63; 96/0 | caught; 11 | caught; 8; 8 | caught |
| `keepsshape` | 3; 13/0 | 3; 12/0 | 1; 12/0 | miss; 4 | miss; 0; 0 | caught |
| `xres` | 20; 41/0 | 24; 46/0 | 21; 39/0 | miss; 0 | miss; 0; 0 | caught |
| `separated` | 623; 682/0 | 601; 680/0 | 543; 587/0 | caught; 1 | miss; 0; 0 | caught |
| `dead` | 1731; 2179/0 | 1653; 2138/0 | 1822; 2303/0 | caught; 1 | caught; 96; 56 | caught |
| `escape` | 556; 556/0 | 555; 555/0 | 547; 549/0 | caught; 1 | miss; 0; 0 | caught |
| `focusexcl` | 626; 785/0 | 621; 805/0 | 559; 710/0 | caught; 17 | miss; 0; 0 | caught |
| `once` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | miss; 0; 0 | argued equivalent |
| `nestedsep` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | miss; 0; 0 | argued equivalent |
| `reqexcloutside` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | miss; 0; 0 | argued equivalent |
| `recvalidate` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | miss; 0; 0 | argued equivalent |
| `writeout` | 101; 153/0 | 112; 165/0 | 89; 146/0 | miss; 0 | caught; 8; 4 | caught |
| `tsupplyexcl` | 20; 41/0 | 24; 46/0 | 21; 39/0 | miss; 0 | miss; 0; 0 | caught |
| `escapeowned` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | miss; 0; 0 | argued equivalent |
| `guardreuse` | 15; 15/0 | 21; 25/0 | 15; 18/0 | miss; 0 | miss; 0; 0 | caught |
| `callbackxres` | 574; 592/0 | 553; 579/0 | 492; 504/0 | miss; 0 | miss; 0; 0 | caught |
| `supplyedge` | 25; 50/0 | 16; 46/0 | 19; 58/0 | caught; 79 | miss; 0; 0 | caught |
| `supplyrecheck` | 9; 33/0 | 7; 35/0 | 5; 42/0 | miss; 175 | miss; 0; 0 | caught |
| `callsedge` | 102; 143/0 | 114; 148/0 | 108; 145/0 | caught; 1 | miss; 0; 0 | caught |
| `requiresedge` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | miss; 0; 0 | argued equivalent |
| `callbackwrites` | 42; 88/0 | 47; 102/0 | 42; 98/0 | caught; 3 | caught; 4; 4 | caught |
| `callbackescapes` | 14; 14/0 | 21; 21/0 | 16; 17/0 | miss; 0 | miss; 0; 0 | caught |
| `callbackaliases` | 71; 112/0 | 86; 132/0 | 81; 131/0 | miss; 439 | miss; 0; 0 | caught |
| `callbackenv` | 111; 191/0 | 115; 204/0 | 103; 194/0 | caught; 1 | miss; 0; 0 | caught |
| `callbackrequires` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | miss; 0; 0 | argued equivalent |
| `forwardguards` | 11; 11/0 | 15; 15/0 | 12; 12/0 | miss; 0 | miss; 0; 0 | caught |
| `transfersupplies` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | miss; 0; 0 | argued equivalent |
| `oncethroughcall` | 188; 236/0 | 172; 225/0 | 184; 228/0 | caught; 2 | caught; 16; 16 | caught |
| `capturelive` | 85; 103/0 | 68; 81/0 | 81; 95/0 | caught; 1 | miss; 0; 0 | caught |
| `copyelems` | 1; 2/0 | 0; 1/0 | 0; 2/0 | caught; 1 | miss; 0; 0 | caught |
| `putexcl` | 69; 120/0 | 86; 138/0 | 68; 125/0 | miss; 0 | miss; 0; 0 | caught |
| `recwrites` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | miss; 0; 0 | argued equivalent |
| `recwritesown` | 21; 61/0 | 15; 74/0 | 17; 62/0 | miss; 0 | miss; 0; 0 | caught |
| `keepsany` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | miss; 0; 0 | argued equivalent |
| `symenv` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | miss; 0; 0 | argued equivalent |
| `branchlive` | 15; 25/0 | 12; 27/0 | 14; 26/0 | caught; 1 | miss; 0; 0 | caught |
| `branchclosure` | 25; 28/0 | 33; 34/0 | 28; 35/0 | caught; 24 | miss; 0; 0 | caught |
| `sharedroots` | 52; 52/0 | 56; 56/0 | 43; 43/0 | caught; 1 | miss; 0; 0 | caught |
| `sharedfn` | 13; 13/0 | 7; 7/0 | 10; 10/0 | miss; 0 | miss; 0; 0 | caught |
| `manyoff` | 13; 13/0 | 13; 13/0 | 18; 18/0 | caught; 1 | miss; 0; 0 | caught |
| `noscope` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | miss; 0; 0 | gap |
| `joinexcl` | 89; 161/0 | 110; 186/0 | 89; 165/0 | miss; 0 | miss; 0; 0 | caught |
| `resprov` | 93; 146/0 | 102; 169/0 | 93; 159/0 | caught; 1 | caught; 32; 20 | caught |
| `argrecheck2` | 143; 172/0 | 147; 186/0 | 176; 214/0 | miss; 0 | caught; 24; 16 | caught |
| `pushexcl` | 11; 12/0 | 10; 11/0 | 7; 7/0 | miss; 0 | miss; 0; 0 | caught |
| `nofix2` | 59; 87/0 | 47; 75/0 | 54; 84/0 | miss; 0 | caught; 8; 8 | caught |
| `hiddencopy` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | miss; 0; 0 | gap |
| `focuscontainer` | 4; 18/0 | 9; 19/0 | 6; 16/0 | caught; 1 | miss; 0; 0 | caught |
| `atelem` | 20; 22/0 | 26; 27/0 | 13; 15/0 | caught; 2 | caught; 8; 4 | caught |
| `shadowing` | 8; 8/0 | 14; 14/0 | 17; 19/0 | miss; 0 | miss; 0; 0 | caught |
| `setexcl` | 21; 21/0 | 17; 18/0 | 15; 16/0 | miss; 0 | caught; 8; 4 | caught |
| `oncelive` | 16; 16/0 | 5; 5/0 | 6; 6/0 | caught; 1 | miss; 0; 0 | caught |
| `envinst` | 91; 165/0 | 107; 190/0 | 90; 173/0 | caught; 1 | caught; 32; 12 | caught |
| `keepsep` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | miss; 0; 0 | gap |
| `ownedothers` | 0; 4/2 | 4; 10/0 | 2; 8/2 | miss; 0 | miss; 0; 0 | caught |
| `joindrops` | 7; 29/0 | 17; 42/0 | 10; 33/0 | miss; 0 | caught; 64; 32 | caught |
| `capturerecurse` | 33; 33/0 | 20; 20/0 | 18; 18/0 | miss; 0 | caught; 4; 4 | caught |
| `joinright` | 7; 29/0 | 16; 41/0 | 10; 32/0 | miss; 0 | caught; 32; 12 | caught |
| `capturecount` | 25; 44/0 | 14; 37/0 | 12; 26/0 | miss; 0 | caught; 8; 8 | caught |
| `captureconsume` | 11; 24/0 | 9; 21/0 | 15; 30/0 | miss; 0 | caught; 4; 4 | caught |

Generator catches 50 unique edits; size 2 catches 23; targeted catches 16. Union: **50 caught, 12 argued equivalent/masked, three search gaps**.

The [written masking arguments](COVERAGE.md#equivalent-argued) have current
changed-verdict counts; a zero delta alone is not an argument. `nofix1` is a
historical alias and has no additional row. The four sixth-review edits are
`capturerecurse`, `joinright`, `capturecount` and `captureconsume`.

Three remaining search gaps:

- `noscope`: typed syntax cannot produce an unbound live variable; CI's direct
  checker-configuration probe reaches it.
- `hiddencopy`: interpreter-only edits change no checker verdict; fixed
  aliasing probes fail. Direct in-place/write checks are needed in campaigns.
- `keepsep`: search lacks a focused list of records with two list fields
  returning one fresh list in both. The written probe shows a false
  exclusivity certificate, not a measured trace mismatch. Add that type shape
  and concrete certificate checking to the searches.

## Enumeration and final checks

The corrected baseline size-2 and targeted logs are retained alongside the
matrix. Size 2 is complete for its original displayed grammar; targeted
search is complete for its displayed template products. The old 20,965,567
size-3 run belongs to `6513cfcb1` and was **not rerun on this head**; it is
historical, not current evidence. Targeted enumeration now reaches the
set-exclusive and shape-join witnesses in CI without that larger run.

All 98 fixtures and required generator controls pass on each seeded stream
(CI supplies seed 20261011; standalone controls supply 17 and 271828). Final
committed-head Lean build, CI, clean-checkout audit and `zorg build gates`
results are recorded in the PR replies. At `0938cb136`, gates had four existing
macOS failures: two stale-path case-folding and two browser-driver cache
pruning CPU-budget tests. The audit-only follow-up run passed the two CPU-budget
tests and had just the same two case-folding failures (1,297 passed, 15 skipped).
Those tests and budgets are unchanged; no gate success is claimed.

Three sorries remain: `invariant_preserved` needs the configuration induction
from sound separating demands; `summary_sound` needs the induction from
validated fixed points and callback guards; `map_summary_sound` needs the
derived certificate proof from summary and builder contracts. Reasons and
limits are in COVERAGE.md. The main theorem remains conditional on the step
lemma. Summary clause 4 is unstated. No complete proof, unbounded search,
arbitrary declaration/type grammar, or merge is claimed.
