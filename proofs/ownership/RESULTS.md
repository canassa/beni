# Results: generator v5, the summary layer, negative controls

All runs: Lean 4.29.1, from `proofs/ownership`, logs in `regressions/`
(`scripts/campaigns.sh` regenerates the campaign and control logs,
`scripts/run-mutants.sh` the source-level ones). Elapsed time is the oracle's
monotonic clock, measured while other work ran on the machine.

## What changed since the second review

The second review (2026-10-12) planted nine checker holes of its own; four
were caught by nothing (`branchlive`, `recwrites`, `keepsany`, `symenv`),
and it found that the generator never built declarations or recursion of
its own (each family was hand-written for particular mutants), that
duplicate programs inflated the accepted counts, and that `ci` did not
require any generator catch.

* **Generator v5** is the default (`--generator-version=4` reproduces v4).
  The general generator's conditionals take chains of moves as arms, and a
  move reads a list again in one arm after pushing it. Half of its programs
  first generate a table of one to three declarations of their own:
  functions over lists, nested lists and records that return a fresh value,
  a parameter or a capture; higher-order functions that call their
  callback; self-recursive functions on a decreasing counter (half with
  flat bodies, half reading after the recursive call the lists they passed
  to it); factories that return closures; rarely a mutually recursive pair.
  Bodies are chains of the same moves and call earlier generated
  declarations. Main chains call them, with existing or fresh arguments and
  callbacks (fixed or generated, often capturing the list they are passed),
  and call any function value in scope, including closures a factory
  returned. The eleven template families together are drawn a quarter of
  the time (11/44); before, half.
* **Counts.** Each campaign reports distinct accepted programs and distinct
  ones that write (by AST), the share of accepted programs whose in-place
  run writes an array two names reach (the review's instrumentation, now
  `Aliasing.lean`), and precision.
* **Controls.** `branch-live` and `once-through-call` are new flag controls,
  required through a probe and through the generator. `ci` now requires the
  generator to catch every required control (it took 3 min 25 s on seed
  20261011); `--strict` changes nothing. The review's nine holes are in
  `scripts/mutate.mjs`.

## Accepted programs

Corrected checker (summaries), 20 000 trials per seed, summed over seeds
20261011, 17 and 271828. "Distinct" counts each AST once per seed. "With
write": the in-place run executed at least one `set`, `push` or focus
write-back. "Aliased": accepted programs whose in-place run writes an array
that two or more names reach (bindings of any frame, or `shared` roots).
"Agreeing": typed programs (accepted or not) whose two runs give equal
traces (rejected programs run with fuel 5 000; one that needs more is not
counted). Every accepted program ran in both interpreters with identical
traces.

| Family | Drawn | Accepted | Distinct accepted | With write | Distinct with write | Aliased | Accepted / agreeing | Limits |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| declarations (v5) | 25720 | 3873 | 3872 | 2343 | 2343 | 1490 | 3873 / 6780 | 513 |
| general (v5) | 19208 | 3064 | 3011 | 1911 | 1909 | 1202 | 3064 / 4987 | 0 |
| once-many-wrappers | 1365 | 804 | 135 | 89 | 15 | 89 | 804 / 1096 | 0 |
| fresh-tower | 1377 | 702 | 648 | 702 | 648 | 702 | 702 / 702 | 0 |
| identity-map | 1374 | 680 | 12 | 680 | 12 | 680 | 680 / 680 | 0 |
| branch-traversal | 1350 | 677 | 15 | 401 | 9 | 401 | 677 / 953 | 0 |
| captures | 1347 | 676 | 30 | 0 | 0 | 0 | 676 / 676 | 0 |
| fresh-nested | 1408 | 494 | 359 | 494 | 359 | 494 | 494 / 494 | 0 |
| indexed-chain | 1377 | 418 | 328 | 418 | 328 | 418 | 418 / 485 | 0 |
| recursion | 1393 | 354 | 102 | 314 | 90 | 314 | 354 / 449 | 0 |
| library-pipeline | 1383 | 335 | 206 | 335 | 206 | 335 | 335 / 736 | 0 |
| escape-traversal | 1357 | 0 | 0 | 0 | 0 | 0 | 0 / 0 | 0 |
| recursive-higher-order-limit | 1341 | 0 | 0 | 0 | 0 | 0 | 0 / 1341 | 1341 |

The template families are where the duplicates were: identity-map's 680
accepted programs are 12 ASTs, branch-traversal's 677 are 15, captures' 676
are 30. Under v4 (seed 20261011, `regressions/campaign-v4-baseline-20261011.log`)
2 526 of 4 903 accepted programs were distinct; under v5 2 897 of 4 003.

| Seed | Accepted | Distinct | With write | Distinct with write | Aliased | Precision | Limits | Mismatches | Elapsed |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 20261011 | 4003 | 2897 | 2552 | 1964 | 1992 (49.7 %) | 4003 / 6392 = 62.6 % | 594 | 0 | 89 s |
| 17 | 3965 | 2860 | 2504 | 1950 | 1996 (50.3 %) | 3965 / 6473 = 61.2 % | 641 | 0 | 91 s |
| 271828 | 4109 | 2961 | 2631 | 2005 | 2137 (52.0 %) | 4109 / 6514 = 63.0 % | 619 | 0 | 88 s |
| total | 12077 | 8718 | 7687 | 5919 | 6125 (50.7 %) | 12077 / 19379 = 62.3 % | 1854 | 0 | |

(Elapsed includes `--cross-check`.) The v4 mix on seed 20261011: 4 903
accepted, 2 526 distinct, 3 205 with write (1 879 distinct), 2 858 aliased
(58.2 %), precision 64.4 %. The v3 generator: 6 363 accepted, 1 532 distinct,
precision 65.6 %.

**Precision** counts every typed program whose two runs agree, so the limit
family (1 341 programs refused by design) and programs that write nothing
anyone reads again are in the denominator: it is a lower bound on how often
the checker accepts a program that is in fact safe, not a false-alarm rate on
realistic code.

**Generated declarations.** Of programs that call a generated recursive
declaration (about 500 per seed), the corrected checker accepts few inside a
whole program; called alone on fresh values (`callGeneratedFresh`), about a
third are accepted. Every program that calls a mutually recursive pair
(101–136 per seed) is rejected: as `limit: inference depth` or `limit:
summary inference depth` when the checker reaches the cycle, otherwise by
an earlier rule. None is accepted.

## Cross-check

The two checkers differ on 32 + 29 + 25 programs that only the summary
checker accepts (each ran with equal traces), and on one (seed 20261011,
index 19411, family declarations) that only the per-call checker accepts —
the summary checker says "exclusive contents"; it runs with equal traces
under the per-call verdict, so it is a precision difference, not a finding.
The per-call checker alone (`--reinfer`) accepts 3 972 / 3 936 / 4 084
programs with no mismatch.

## Rows exercised

Accepted programs that write and exercised each checker row (three seeds):

| Row | Programs |
|---|---:|
| callback called through its class; supply resolved at a known callback | 4217 |
| xres yes / xres no | 4211 / 75 |
| a callback's argument in its res | 2420 |
| fresh in a callback's res | 2063 |
| W on a callback argument; edge W ⇒ owned checked | 1214 |
| summary reused after re-asking its guards | 856 |
| supply owned bit cleared at the caller | 770 |
| supply owned bit cleared where a step ends | 323 |
| env in a callback's res | 279 |
| guard forwarded / supply transferred to the caller's own input | 194 / 194 |
| xreq on a callback argument; edge xreq ⇒ exclusive checked | 187 |
| E on a callback argument; shared in its res | 162 |
| once callback's calls checked | 99 |
| ⊤ in a callback's res; E on a callback's environment | 0 |

## Negative controls (flags)

Every required control has a fixed probe in `Fixtures.lean` (82 verdict
fixtures, 21 probes), checked by `ownership fixtures` and `ci`. Separately,
`ownership controls 20000 <seed>` reports the first index (0-based) at which
the generator alone finds an accepted disagreement that the corrected
checker rejects (`regressions/controls-v5-*.log`):

| Control | 20261011 | 17 | 271828 | Required |
|---|---:|---:|---:|---|
| `--old-rule` (T59 freshness only) | 26 | 35 | 5 | yes |
| `--old-escape-rule` | 32 | 50 | 39 | yes |
| disjoint | 227 | 13 | 480 | yes |
| borrowed-supply, per-call checker | 182 | 830 | 749 | yes |
| borrowed-supply, summaries | not observable: 33 / 40 / 35 verdicts changed, 0 disagree | | | reported |
| traversal-exclusive | 1322 | 889 | 374 | yes |
| many-calls | 2270 | 349 | 3340 | yes |
| copy-exclusive | 5886 | 3139 | 1458 | yes |
| close-source | 23 | 3518 | 2711 | yes |
| keeps-shape | 1322 | 3027 | 1581 | yes |
| guard-reuse | 542 | 1699 | 365 | yes |
| callback-xres | 26 | 35 | 5 | yes |
| supply-edge | 84 | 175 | 300 | yes |
| supply-recheck | 168 | 1564 | 641 | yes |
| calls-edge | 434 | 136 | 77 | yes |
| callback-writes | 929 | 60 | 3449 | yes |
| callback-aliases | 2 | 433 | 41 | yes |
| callback-env | 604 | 84 | 279 | yes |
| once-through-call (new) | 712 | 1841 | 5249 | yes |
| branch-live (new) | 472 | 219 | 1389 | yes |
| callback-escapes | — | 3184 | 2735 | probe only |
| forward-guards | — | — | — | probe only |
| callback-requires, requires-edge, transfer-supplies | — | — | — | known gaps |

Against the per-call checker (seed 20261011) the review's first seven are
caught at 227, 182, 1322, 2270, 5886, 23, 1322.

`forward-guards` was caught on one seed of three under v4 and changes no
verdict in 20 000 v5 trials (`verdict-diff`, seed 20261011), although the
row is hit 194 times: v5 dilutes the `mapVia`/`publish` programs that
reached it. Its probe still requires it. `callback-requires`,
`requires-edge` and `transfer-supplies` change no verdict either.

## Source-level mutants

`scripts/run-mutants.sh` applies each edit of `scripts/mutate.mjs` to a copy
of the sources, builds it, and runs the unmodified `oracle 20000 <seed>`
(generator only) on each seed. `regressions/source-mutants-v5.log`; first
index per seed (20261011 / 17 / 271828):

| Mutant | First index | Seeds |
|---|---|---:|
| disjoint | 227 / 13 / 480 | 3/3 |
| travexcl | 1322 / 889 / 374 | 3/3 |
| manycap | 2270 / 349 / 3340 | 3/3 |
| copyexcl | 5886 / 3139 / 1458 | 3/3 |
| closesrc | 23 / 3518 / 2711 | 3/3 |
| keepsshape | 1322 / 3027 / 1581 | 3/3 |
| separated | 26 / 35 / 5 | 3/3 |
| dead | 15 / 28 / 19 | 3/3 |
| escape | 32 / 50 / 39 | 3/3 |
| focusexcl | 26 / 35 / 5 | 3/3 |
| writeout | 923 / 129 / 279 | 3/3 |
| guardreuse | 542 / 1699 / 365 | 3/3 |
| callbackxres | 26 / 35 / 5 | 3/3 |
| supplyedge | 84 / 175 / 300 | 3/3 |
| supplyrecheck | 168 / 1564 / 641 | 3/3 |
| callsedge | 434 / 136 / 77 | 3/3 |
| callbackwrites | 929 / 60 / 3449 | 3/3 |
| callbackaliases | 2 / 433 / 41 | 3/3 |
| callbackenv | 604 / 84 / 279 | 3/3 |
| oncethroughcall | 712 / 1841 / 5249 | 3/3 |
| callbackescapes | — / 3184 / 2735 | 2/3 |
| borrowedsupply | — | 0/3 (summaries; caught against the per-call checker) |
| requiresedge, callbackrequires, forwardguards, transfersupplies | — | 0/3 |
| xres, once, nestedsep, reqexcloutside, recvalidate, tsupplyexcl, escapeowned | — | 0/3 |

The second review's nine holes, generator only:

| Hole | 20261011 | 17 | 271828 | Seeds | Before (review, v4) |
|---|---:|---:|---:|---:|---|
| capturelive | 63 | 1126 | 1900 | 3/3 | 3/3 |
| copyelems | 3927 | 464 | 5770 | 3/3 | 3/3 |
| putexcl | 923 | 129 | 279 | 3/3 | 3/3 |
| focuscontainer | 736 | 415 | 194 | 3/3 | 3/3 |
| atelem | 2436 | 1107 | 12849 | 3/3 | 3/3 |
| branchlive | 472 | 219 | 1389 | 3/3 | **0/3** |
| recwrites | — | — | — | 0/3 | 0/3 — masked (below) |
| keepsany | — | — | — | 0/3 | 0/3 — argued equivalent (below) |
| symenv | — | — | — | 0/3 | 0/3 — masked (below) |
| recwritesown (recwrites with its mask removed) | 2717 | — | 1176 | 2/3 | — |

Flag and source versions of a control run on the same generator give the
same first index. COVERAGE.md ("Known gaps") analyses each miss.

## Findings

* **Two summary-checker soundness defects** (fixed on this branch by the
  parent work, not by the generator): a once callback that a callee calls
  was neither consumed nor its written captures demanded at the call
  (fixtures "once closure called by a callee, then observed" and "close
  returns a once closure's capture, a callee calls it"; control
  `once-through-call`). The v4 generator never built the shape; v5 reaches
  it on all three seeds.
* **Earlier findings** (the review of 2026-10-11): the per-call checker's
  recursion inside a step (now a limit for both checkers), and a precision
  defect of the summary checker's Disjoint test through a callback's
  environment (fixed). See git history of this file.
* No corrected-rule mismatch in the 60 000 v5 trials, the v4 and v3
  baselines, or the 82 fixtures.

## Reproduction

```sh
nix develop .#ownership
cd proofs/ownership
lake build                                        # includes the AxiomCheck audit
.lake/build/bin/ownership ci                      # fixtures, probes, one campaign, every required control
.lake/build/bin/ownership oracle 20000 17 --cross-check
.lake/build/bin/ownership controls 20000 271828
.lake/build/bin/ownership verdict-diff 20000 17 --mutant=borrowed-supply
scripts/campaigns.sh                              # all campaign and control logs above
scripts/run-mutants.sh .mutants 20000 20261011 17 271828
```
