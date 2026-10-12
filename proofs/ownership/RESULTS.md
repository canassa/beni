# Results: generator v4, the summary layer, required negative controls

All runs: Lean 4.29.1, from `proofs/ownership`, logs in `regressions/`
(`scripts/campaigns.sh` regenerates them). Elapsed time is the oracle's
monotonic clock (generation, both checkers under `--cross-check`, both
interpreters, shrinking), measured while other work ran on the machine.

## What changed since the review

The review (2026-10-11) found that none of seven deliberate checker holes was
caught in 60 000 trials; that the only general family (`anf-chain`) ended
every program with a record of all its variables, so **0** of its accepted
programs wrote in place; and that the checker re-inferred each callee per
call, so the oracle never exercised the thesis's summary rows.

* Generator v4 replaces `anf-chain` by a general family (`Generator.lean`),
  including higher-order wrappers that pass their callback on.
* The checker publishes per-function summaries and uses them at call sites
  (`Checker.lean`); the per-call checker is kept as `Reinfer.lean`.
* Twenty mutants are `--mutant=` flags; fifteen are required controls with a
  fixed probe each, five are reported (two through a probe, three known gaps).

## Accepted programs that write in place

Corrected checker (summaries), 20 000 trials per seed. "With write" counts
accepted programs whose in-place run executed at least one `set`, `push` or
focus write-back (builder `put` excluded). Every accepted program ran in both
interpreters with identical traces. `ownership ci` fails below 30 %.

| Family | Accepted (3 seeds) | With write | Before (v3) |
|---|---:|---:|---|
| general (v4, replaces anf-chain) | 4784 | **3021** | anf-chain: 522 accepted, **0** with write (review: 0 of 166 on one seed; 0 of 186 on seed 20261011) |
| once-many-wrappers | 1544 | 178 | |
| fresh-tower | 1372 | 1372 | |
| identity-map | 1365 | 1365 | |
| branch-traversal | 1361 | 815 | |
| captures | 1341 | 0 | |
| fresh-nested | 897 | 897 | |
| indexed-chain | 765 | 765 | |
| recursion | 698 | 597 | |
| library-pipeline | 653 | 653 | |
| escape-traversal, recursive-higher-order-limit | 0 | 0 | |

| Seed | Typed | Distinct ASTs | Accepted | With write | Limits | Mismatches |
|---|---:|---:|---:|---:|---:|---:|
| 20261011 | 20000 | 12160 | 4903 | 3205 (65 %) | 913 | 0 |
| 17 | 20000 | 12193 | 5002 | 3315 (66 %) | 880 | 0 |
| 271828 | 20000 | 12239 | 4875 | 3143 (64 %) | 930 | 0 |

`--generator-version=3` on seed 20261011 reproduces v3 unchanged (6363
accepted, 4080 with write, 0 mismatches) under the summary checker.

## Rows exercised

Accepted programs that write and exercised each checker row (three seeds):

| Row | Programs |
|---|---:|
| callback called through its class; supply resolved at a known callback | 5871 |
| xres yes / xres no | 5865 / 46 |
| fresh in a callback's res | 3328 |
| a callback's argument in its res | 2995 |
| W on a callback argument; edge W ⇒ owned checked | 1252 |
| supply owned bit cleared at the caller | 981 |
| summary reused after re-asking its guards | 881 |
| env in a callback's res | 319 |
| supply owned bit cleared where a step ends | 237 |
| once callback's calls checked | 181 |
| guard forwarded / supply transferred to the caller's own input | 134 / 134 |
| xreq on a callback argument; edge xreq ⇒ exclusive checked | 99 |
| E on a callback argument; shared in its res | 95 |
| ⊤ in a callback's res; E on a callback's environment | 0 |

## Summary layer

* **No corrected-rule mismatch** in the 60 000 trials above, nor in the 78
  fixtures; both checkers agree with every intended verdict.
* **Computed once.** Per seed about 10 000 summaries were computed and about
  200 000 call sites (including class queries) served from the cache after
  re-asking their guards.
* **Cross-check** (`--cross-check`): the two checkers differ on 65 of 60 000
  programs, and in every one only the summary checker accepts (the per-call
  checker says Disjoint or "exclusive contents"); each ran with equal traces.
  Before the fix in "Findings" there were also 3 programs only the per-call
  checker accepted.
* `ownership summaries` prints the published rows of the accepted fixtures
  (`regressions/summaries-fixtures.log`).

## Negative controls

Every required control has a fixed probe in `Fixtures.lean`, required by
`ownership ci` and `ownership fixtures`. Separately, `ownership controls
20000 <seed>` reports the first index (0-based) at which the generator alone
finds an accepted disagreement that the corrected checker rejects:

| Control | 20261011 | 17 | 271828 | Required |
|---|---:|---:|---:|---|
| `--old-rule` (T59 freshness only) | 23 | 10 | 7 | yes |
| `--old-escape-rule` | 14 | 20 | 3 | yes |
| disjoint | 99 | 70 | 191 | yes |
| borrowed-supply, per-call checker | 249 | 1056 | 1692 | yes |
| borrowed-supply, summaries | not observable: 21 / 28 / 17 verdicts changed, 0 disagree | | | reported |
| traversal-exclusive | 236 | 688 | 2301 | yes |
| many-calls | 366 | 2232 | 366 | yes |
| copy-exclusive | 231 | 688 | 1548 | yes |
| close-source | 3315 | 179 | 379 | yes |
| keeps-shape | 3757 | 1228 | 2336 | yes |
| guard-reuse | 1649 | 471 | 5841 | yes |
| callback-xres | 23 | 10 | 7 | yes |
| supply-edge | 583 | 97 | 353 | yes |
| supply-recheck | 4741 | 537 | 353 | yes |
| calls-edge | 45 | 105 | 21 | yes |
| callback-writes | 400 | 34 | 1960 | yes |
| callback-aliases | 249 | 460 | 353 | yes |
| callback-env | 119 | 22 | 172 | yes |
| callback-escapes | — | 471 | 13816 | probe only |
| forward-guards | — | 471 | — | probe only |
| callback-requires, requires-edge, transfer-supplies | — | — | — | known gaps |

`callback-xres` and `old-rule` are caught at the same indices: the same
fresh-nested/fresh-tower program, not the callback families. Against the
per-call checker (`--reinfer`, seed 20261011) the review's seven are caught at
99, 249, 236, 366, 231, 3315, 3757.

## Source-level mutants

`scripts/run-mutants.sh` applies each edit of `scripts/mutate.mjs` to a copy
of the sources, builds it, and runs the unmodified `oracle 20000 <seed>` for
the three seeds (generator only). Results in `regressions/source-mutants-v4.log`
(the first 25 before the higher-order family, the callback ones and the
review's other seven re-run after it). First index per seed
(20261011 / 17 / 271828):

| Mutant | First index | Seeds |
|---|---|---:|
| disjoint, travexcl, manycap, copyexcl, closesrc, keepsshape | in the log (run before the higher-order family) | 3/3 |
| borrowedsupply | — | 0/3 (summaries; caught against the per-call checker) |
| separated | 13 / 4 / 18 | 3/3 |
| dead | 3 / 11 / 8 | 3/3 |
| escape | 33 / 42 / 5 | 3/3 |
| focusexcl | 13 / 4 / 18 | 3/3 |
| writeout | 125 / 219 / 88 | 3/3 |
| guardreuse, callbackxres, supplyedge, supplyrecheck, callsedge | in the log (run before the higher-order family) | 3/3 |
| callbackwrites | 400 / 34 / 1960 | 3/3 |
| callbackaliases | 249 / 460 / 353 | 3/3 |
| callbackenv | 119 / 22 / 172 | 3/3 |
| callbackescapes | — / 471 / 13816 | 2/3 |
| forwardguards | — / 471 / — | 1/3 |
| requiresedge, callbackrequires, transfersupplies | — | 0/3 |
| xres, once, nestedsep, reqexcloutside, recvalidate, tsupplyexcl, escapeowned | — | 0/3 |

Flag and source versions run on the same generator give identical first indices. COVERAGE.md lists the
uncaught ones as known gaps with what would reach them.

## Findings

* **Real defect, executable checker (not the thesis).** The per-call checker
  analysed a recursive call inside a traversal step with an empty summary and
  accepted a program whose value run returns 8 and in-place run 11. Fixture
  "recursion inside a step"; both checkers now refuse it as a limit. Found by
  reading while building the summary layer; no generated family produces it.
* **Precision defect, summary checker.** Three programs (seed 17 index 13951,
  seed 20261011 indices 8894 and 13920) were accepted by the per-call checker
  only. Common cause: all pass the once callback `capAppend` to
  `applyThenRead`, whose result is the callback's environment and is then
  written. The summary names that write `π_1.env` while the actual closure
  names the same cells under its `.capture` paths, and the caller's Disjoint
  test counted those as another operand. They are the same path; `otherPaths`
  now treats them so, and the closure's later uses remain the callee's Dead
  check. After the fix: no program is accepted by the per-call checker alone,
  no mismatch.
* No corrected-rule mismatch otherwise.

## Reproduction

```sh
nix develop .#ownership
cd proofs/ownership
lake build                                        # includes the AxiomCheck audit
.lake/build/bin/ownership ci                      # fixtures and probes, one campaign, controls reported
.lake/build/bin/ownership ci --strict             # also require every generator catch
.lake/build/bin/ownership oracle 20000 17 --cross-check
.lake/build/bin/ownership controls 20000 271828
.lake/build/bin/ownership verdict-diff 20000 17 --mutant=borrowed-supply
scripts/campaigns.sh                              # all logs above
scripts/run-mutants.sh /tmp/mutants 20000 20261011 17 271828
```
