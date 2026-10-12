# Results: generator v5, the summary layer, negative controls

All runs: Lean 4.29.1, from `proofs/ownership`, logs in `regressions/`
(`scripts/campaigns.sh` regenerates the campaign and control logs,
`scripts/run-mutants.sh` the source-level ones). Elapsed time is the oracle's
monotonic clock, measured while other work ran on the machine (heavy jobs
pinned to 24 of its 32 cores).

"Generator v5" below is the generator as of this branch's last generator
commit (`d94b3dd0a`, after the fourth review); `--generator-version=5` names
it. **Every number in this file was measured on it** — campaigns, flag
controls, every source-level edit, and the verdict counts behind the
equivalence arguments. Earlier rounds' numbers are in the git history.

## What changed since the fourth review

The fourth review planted four holes the generator did not catch
(`manyoff`, `sharedfn`, `noscope`, and `joinexcl`, which the fixtures
caught), found that a crash while shrinking (stack overflow) turned caught
holes into misses or errors (`argrecheck2`, `recwritesown`), and listed
sixteen source-level edits caught on no seed. Changes:

* **Shrinking keeps its evidence** (parent work, `b613f3233`): candidates run
  with fuel 5 000, stdout is flushed and the unshrunk program written before
  shrinking, and `run-mutants.sh` flags a crashed run (`CRASH`) instead of
  counting it a miss. No run below crashed.
* **New controls**: `many-off` (a traversal step's single call of a once
  callback counted as one call), `shared-fn` (`shared` not escaping a list
  captured by a closure held in a record field), both reached by new moves
  (a once closure handed to `foldl` or `map` over two rows; a record holding a
  closure over a list, published, then the list pushed) and required;
  `no-scope` (an unbound live variable read as dead), required through a
  checker-level probe — no typed program has an unbound live variable, so no
  generated program can reach it (COVERAGE.md).
* **Moves for the 0/3 edits**: a loop over a nested list repeating a row that
  keeps a row as its accumulator and edits it (catches the first review's
  `xres` and `tsupplyexcl`); one wrapper called twice, the second time with a
  callback that publishes its argument, then the row written (catches
  `callback-escapes` and `forward-guards`, both now required); a shallow copy
  of a nested list repeating a row, edited (the new moves had diluted
  `copy-exclusive` and `copyelems` below one catch per seed).
* `ownership accepted <count> <seed>` lists the programs a build accepts, so
  a source-level edit's changed verdicts are counted against the unmutated
  build (`regressions/verdicts-round5.log`).

## Accepted programs

Corrected checker (summaries), 20 000 trials per seed, summed over seeds
20261011, 17 and 271828. "Distinct" counts each AST once per seed. "With
write": the in-place run changed an array at least once (`set`, `push` or a
focus write-back). "Aliased": accepted programs whose in-place run changes
an array that two or more names reach (bindings of any frame, or `shared`
roots). "Agreeing": typed programs (accepted or not) whose two runs give
equal traces (rejected programs run with fuel 5 000; one that needs more is
not counted). Every accepted program ran in both interpreters with
identical traces.

| Family | Drawn | Accepted | Distinct accepted | With write | Distinct with write | Aliased | Accepted / agreeing | Limits |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| declarations (v5) | 25985 | 2797 | 2796 | 1960 | 1960 | 1485 | 2797 / 6013 | 436 |
| general (v5) | 18943 | 2042 | 2011 | 1008 | 1008 | 644 | 2042 / 3085 | 0 |
| once-many-wrappers | 1365 | 779 | 135 | 80 | 15 | 80 | 779 / 1107 | 0 |
| fresh-tower | 1393 | 681 | 625 | 681 | 625 | 681 | 681 / 681 | 0 |
| captures | 1359 | 666 | 30 | 0 | 0 | 0 | 666 / 666 | 0 |
| identity-map | 1344 | 665 | 12 | 665 | 12 | 665 | 665 / 665 | 0 |
| branch-traversal | 1313 | 637 | 15 | 367 | 9 | 367 | 637 / 916 | 0 |
| fresh-nested | 1362 | 444 | 329 | 444 | 329 | 444 | 444 / 444 | 0 |
| indexed-chain | 1339 | 375 | 306 | 375 | 306 | 375 | 375 / 444 | 0 |
| recursion | 1423 | 345 | 102 | 285 | 87 | 285 | 345 / 452 | 0 |
| library-pipeline | 1367 | 328 | 204 | 328 | 204 | 328 | 328 / 746 | 0 |
| recursive-higher-order-limit | 1386 | 0 | 0 | 0 | 0 | 0 | 0 / 1386 | 1386 |
| escape-traversal | 1421 | 0 | 0 | 0 | 0 | 0 | 0 / 0 | 0 |

| Seed | Accepted | Distinct | With write | Distinct with write | Aliased | Precision | Limits | Shadowing refused | Mismatches | Elapsed |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 20261011 | 3301 | 2243 | 2108 | 1574 | 1812 (54.8 %) | 3301 / 5581 = 59.1 % | 599 | 285 | 0 | 115 s |
| 17 | 3209 | 2120 | 2041 | 1483 | 1773 (55.2 %) | 3209 / 5531 = 58.0 % | 651 | 282 | 0 | 116 s |
| 271828 | 3249 | 2202 | 2044 | 1498 | 1769 (54.4 %) | 3249 / 5493 = 59.1 % | 572 | 294 | 0 | 111 s |
| total | 9759 | 6565 | 6193 | 4555 | 5354 (54.9 %) | 9759 / 16605 = 58.8 % | 1822 | 861 | 0 | |

(Elapsed includes `--cross-check`.) After the third review's changes the
same seeds gave 10 681 accepted and precision 58.1 %. The general family's
acceptance fell (2 042 of 18 943): most of the new moves build programs the
corrected checker must refuse — a list written after a closure over it was
published, an element of a non-exclusive source edited, a once closure
called on every row — which is what makes them reach the holes. The v4 and
v3 baselines (seed 20261011) ran with no mismatch.

**Precision** counts every typed program whose two runs agree, so the limit
family (refused by design), the shadowing move (refused by design, and
agreeing when it runs) and programs that write nothing anyone reads again
are in the denominator: it is a lower bound on how often the checker
accepts a program that is in fact safe, not a false-alarm rate on realistic
code.

### Generated declarations exercised

Over the declaration family's accepted programs, from the in-place run's
call log (calls of declarations past the fixed table):

| Seed | Accepted (family) | Run a generated declaration | A generated call changes an array its inputs reach | Generated calls | Pass one array at two argument positions |
|---|---:|---:|---:|---:|---:|
| 20261011 | 953 | 919 (96.4 %) | 315 (33.0 %) | 1459 | 231 (15.8 %) |
| 17 | 886 | 846 (95.4 %) | 291 (32.8 %) | 1402 | 235 (16.7 %) |
| 271828 | 958 | 931 (97.1 %) | 314 (32.7 %) | 1496 | 243 (16.2 %) |

The third review measured 18 % / 2.2 % / 11 of 377 calls on the generator
before its round (seed 17, 1 500 programs). What moved them: the
declaration family's chain ends by calling its own declarations; writer
declarations are called on fresh arguments so that the call is accepted
and its write is visible to the caller's later read; half of all generated
calls repeat an argument, which writers skip (Disjoint would refuse them)
and readers and higher-order declarations accept. The programs that run no
generated declaration are those whose table is a mutual pair alone, which
is always a limit.

## Cross-check

The two checkers differ on 16 + 20 + 19 programs that only the summary
checker accepts (each ran with equal traces) and on none that only the
per-call checker accepts. The per-call checker alone (`--reinfer`) accepts
3 285 / 3 189 / 3 230 programs with no mismatch.

## Rows exercised

Accepted programs that write and exercised each checker row (three seeds):

| Row | Programs |
|---|---:|
| callback called through its class; supply resolved at a known callback | 3418 |
| xres yes / xres no | 3412 / 50 |
| a callback's argument in its res | 1879 |
| fresh in a callback's res | 1720 |
| W on a callback argument; edge W ⇒ owned checked | 887 |
| summary reused after re-asking its guards | 603 |
| supply owned bit cleared at the caller | 559 |
| env in a callback's res | 193 |
| supply owned bit cleared where a step ends | 182 |
| E on a callback argument; shared in its res | 119 |
| xreq on a callback argument; edge xreq ⇒ exclusive checked | 106 |
| once callback's calls checked | 92 |
| guard forwarded / supply transferred to the caller's own input | 86 / 86 |
| ⊤ in a callback's res; E on a callback's environment | 0 |

## Negative controls (flags)

Every required control has a fixed probe in `Fixtures.lean` (89 verdict
fixtures, 27 program probes and the checker-level `no-scope` probe), checked
by `ownership fixtures` and `ci`. Separately, `ownership controls 20000
<seed>` reports the first index (0-based) at which the generator alone finds
an accepted disagreement that the corrected checker rejects
(`regressions/controls-v5-*.log`):

| Control | 20261011 | 17 | 271828 | Required |
|---|---:|---:|---:|---|
| `--old-rule` (T59 freshness only) | 20 | 43 | 11 | yes |
| `--old-escape-rule` | 57 | 15 | 4 | yes |
| disjoint | 229 | 121 | 150 | yes |
| borrowed-supply, per-call checker | 1556 | 413 | 1326 | yes |
| borrowed-supply, summaries | not observable: 28 / 23 / 31 verdicts changed, 0 disagree | | | reported |
| traversal-exclusive | 411 | 68 | 514 | yes |
| many-calls | 1447 | 5187 | 29 | yes |
| copy-exclusive | 29 | 304 | 2790 | yes |
| close-source | 2565 | 177 | 352 | yes |
| keeps-shape | 9830 | 2286 | 7381 | yes |
| guard-reuse | 499 | 267 | 236 | yes |
| callback-xres | 20 | 43 | 11 | yes |
| supply-edge | 2346 | 923 | 317 | yes |
| supply-recheck | 4601 | 2492 | 4787 | yes |
| calls-edge | 218 | 3 | 217 | yes |
| callback-writes | 230 | 1316 | 225 | yes |
| callback-aliases | 129 | 220 | 68 | yes |
| callback-env | 579 | 472 | 47 | yes |
| callback-escapes | 499 | 267 | 2728 | yes (new: was probe only) |
| forward-guards | 499 | 267 | 2728 | yes (new: was probe only) |
| once-through-call | 46 | 535 | 1034 | yes |
| branch-live | 291 | 2936 | 558 | yes |
| branch-closure | 56 | 109 | 1102 | yes |
| shared-roots | 485 | 713 | 590 | yes |
| shadowing | 347 | 2899 | 471 | yes |
| many-off (new) | 1450 | 72 | 399 | yes |
| shared-fn (new) | 822 | 5336 | 590 | yes |
| no-scope (new) | — | — | — | probe only: unreachable by a typed program |
| callback-requires, requires-edge, transfer-supplies | — | — | — | argued equivalent (COVERAGE.md) |

Against the per-call checker (seed 20261011) the first review's seven are
caught at 229, 1556, 411, 364, 29, 2565, 9830
(`regressions/controls-v5-reinfer-20261011.log`). `ownership ci` (fixtures,
probes, one campaign, every required control on seed 20261011) passed in
5 min 20 s.

## Source-level mutants

`scripts/run-mutants.sh` applies each edit of `scripts/mutate.mjs` (55 of
them: the first review's nineteen and the summary rows', the second,
third and fourth reviews' holes, and the once-through-call fixes undone) to
a copy of the sources, builds it, and runs the unmodified `oracle 20000
<seed>` (generator only) on the three seeds side by side. All on the final
generator, no crash (`regressions/source-mutants-round5.log`). First index
per seed (20261011 / 17 / 271828):

| Edit | First index | Seeds |
|---|---|---:|
| disjoint | 229 / 121 / 150 | 3/3 |
| travexcl | 411 / 68 / 514 | 3/3 |
| manycap | 1447 / 5187 / 29 | 3/3 |
| copyexcl | 29 / 304 / 2790 | 3/3 |
| closesrc | 2565 / 177 / 352 | 3/3 |
| keepsshape | 9830 / 2286 / 7381 | 3/3 |
| xres | 215 / 44 / 769 | 3/3 (new) |
| separated | 20 / 43 / 11 | 3/3 |
| dead | 7 / 39 / 28 | 3/3 |
| escape | 21 / 15 / 4 | 3/3 |
| focusexcl | 20 / 43 / 11 | 3/3 |
| writeout | 411 / 68 / 47 | 3/3 |
| tsupplyexcl | 215 / 44 / 769 | 3/3 (new) |
| guardreuse | 499 / 267 / 236 | 3/3 |
| callbackxres | 20 / 43 / 11 | 3/3 |
| supplyedge | 2346 / 923 / 317 | 3/3 |
| supplyrecheck | 4601 / 2492 / 4787 | 3/3 |
| callsedge | 218 / 3 / 217 | 3/3 |
| callbackwrites | 230 / 1316 / 225 | 3/3 |
| callbackescapes | 499 / 267 / 2728 | 3/3 (new) |
| callbackaliases | 129 / 220 / 68 | 3/3 |
| callbackenv | 579 / 472 / 47 | 3/3 |
| forwardguards | 499 / 267 / 2728 | 3/3 (new) |
| oncethroughcall | 46 / 535 / 1034 | 3/3 |
| capturelive | 1324 / 295 / 3361 | 3/3 |
| copyelems | 16452 / 10046 / 8912 | 3/3 |
| putexcl | 579 / 524 / 47 | 3/3 |
| recwritesown | 826 / 310 / 2276 | 3/3 |
| branchlive | 291 / 2936 / 558 | 3/3 |
| branchclosure | 56 / 109 / 1102 | 3/3 |
| sharedroots | 485 / 713 / 590 | 3/3 |
| sharedfn | 822 / 5336 / 590 | 3/3 (new) |
| manyoff | 1450 / 72 / 399 | 3/3 (new) |
| joinexcl | 215 / 44 / 47 | 3/3 (new) |
| resprov | 579 / 121 / 47 | 3/3 |
| argrecheck2 | 75 / 203 / 357 | 3/3 (was a crash) |
| pushexcl | 411 / 68 / 514 | 3/3 |
| nofix1 | 46 / 535 / 1034 | 3/3 |
| nofix2 | 2588 / 535 / 2312 | 3/3 |
| focuscontainer | 1017 / 5137 / 3655 | 3/3 |
| atelem | 2536 / 202 / 322 | 3/3 |
| once, nestedsep, reqexcloutside, recvalidate, escapeowned | — | 0/3, argued equivalent |
| requiresedge, callbackrequires, transfersupplies | — | 0/3, argued equivalent |
| recwrites, symenv | — | 0/3, masked (equivalent given the masking rule) |
| keepsany | — | 0/3, argued equivalent |
| borrowedsupply | — | 0/3 under summaries; not observable (changes verdicts, none disagree) |
| noscope | — | 0/3 by the generator, unreachable by a typed program; caught by `ci`'s checker-level probe |
| hiddencopy (interpreter) | — | 0/3; no program can separate the runs; caught by the fixtures |

`recwritesown` removes `recwrites` together with the rule that masks it,
and is caught on all three seeds. `regressions/verdicts-round5.log` counts
the verdicts each 0/3 checker edit changes on the final generator: none,
except `escapeowned` (2 programs on seed 20261011, both running equal) and
`borrowed-supply` (23–31 per seed, none disagreeing). COVERAGE.md
("Equivalent (argued)" and "Gaps") gives the argument for each.

## Findings

* No corrected-rule mismatch in the 60 000 trials on the final generator,
  the per-call checker's 60 000, the v4 and v3 baselines, or the 89
  fixtures; no source-level run crashed.
* **Earlier findings** (see git history): the third review's shadowing
  defect (both checkers; refused in `typecheck`, liveness pinned to the
  outer binding); two summary-checker defects for a once callback a callee
  calls (second review, control `once-through-call`); the per-call
  checker's recursion inside a step and a precision defect of the Disjoint
  test through a callback's environment (first review).

## Reproduction

```sh
nix develop .#ownership
cd proofs/ownership
lake build                                        # includes the AxiomCheck audit
.lake/build/bin/ownership ci                      # fixtures, probes, one campaign, every required control
.lake/build/bin/ownership oracle 20000 17 --cross-check
.lake/build/bin/ownership controls 20000 271828
.lake/build/bin/ownership verdict-diff 20000 17 --mutant=borrowed-supply
.lake/build/bin/ownership accepted 20000 17       # programs this build accepts (compare two builds)
scripts/campaigns.sh                              # all campaign and control logs above
scripts/check-mutants.sh                          # every source edit still applies
scripts/run-mutants.sh ~/.cache/mutants 20000 20261011 17 271828
```
