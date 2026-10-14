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
results are recorded in the PR reply. Gates have the same four existing
macOS failures: two stale-path case-folding and two browser-driver cache
pruning CPU-budget tests. Those tests are unchanged; no gate success is claimed.

Three sorries remain: `invariant_preserved` needs the configuration induction
from sound separating demands; `summary_sound` needs the induction from
validated fixed points and callback guards; `map_summary_sound` needs the
derived certificate proof from summary and builder contracts. Reasons and
limits are in COVERAGE.md. The main theorem remains conditional on the step
lemma. Summary clause 4 is unstated. No complete proof, unbounded search,
arbitrary declaration/type grammar, or merge is claimed.
