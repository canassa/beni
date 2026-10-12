# Results: generator v5, the summary layer, negative controls

All runs: Lean 4.29.1, from `proofs/ownership`, logs in `regressions/`
(`scripts/campaigns.sh` regenerates the campaign and control logs,
`scripts/run-mutants.sh` the source-level ones). Elapsed time is the oracle's
monotonic clock, measured while other work ran on the machine.

"Generator v5" below is the generator as of this branch's last generator
commit (`d8c9e8077`); `--generator-version=5` names it. It changed after the
third review (2026-10-12), so numbers measured before those changes are not
comparable and are marked where they are kept.

## What changed since the third review

The third review found that the checker let a shadowing `let` hide a live
variable, that generated declarations were rarely run (18 % of the
declaration family's accepted programs called one, 2.2 % had such a call
change an array the caller passed), that `shared` was applied only to flat
lists and no closure was built in a conditional arm, and that five planted
holes went uncaught (`resprov`, `argrecheck2`, `pushexcl`, `branchclosure`,
`sharedroots`). Generator changes:

* **Declarations are run.** The declaration family's chain now ends by
  calling one or two of its own declarations (a writer half the time, on
  fresh arguments two times in three), chains are 1–6 moves, and two new
  kinds join the table: *writers*, which write one of their parameters
  (push, set, element edit or spine push) before anything else, and
  *readers*, which only read two lists of one type. Half of all generated
  calls repeat an earlier argument of the same type at a later position.
* **Shadowing is generated.** A move rebinds a list variable inside a
  `let`'s right-hand side after pushing it through an alias, then reads the
  outer variable (the review's P2), in main and in declaration bodies. The
  corrected checker refuses it as shadowing.
* **Shared nested values and closures in arms.** `shared` on a nested list
  then a push onto an element read out of it; `shared` on a record then a
  push onto a field; a conditional choosing between two closures over a
  list pushed just before or just after, then a call.
* **Moves for the remaining holes.** A list pushed twice onto a nested list,
  then a traversal pushing onto each element (`pushexcl`); an empty list a
  once closure appends to, aliased by `close` over an empty builder, the
  closure called by a callee (new fixed `apply1`), the alias read
  (`nofix2`); a shallow copy of a nested list whose element is edited, then
  the original's element read (`copy-exclusive`, which the other new moves
  had diluted below one catch per seed).
* **Counts.** Writes are counted only when they change an array (the
  interpreter's count and the aliased-write instrument). A mismatch's index
  is printed before it is shrunk, and `run-mutants.sh` lifts the stack limit:
  shrinking a deep program had overflowed the stack, so a caught hole was
  reported as missed.

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
| declarations (v5) | 26065 | 3252 | 3251 | 2328 | 2328 | 1798 | 3252 / 7098 | 519 |
| general (v5) | 19013 | 2389 | 2338 | 1191 | 1189 | 750 | 2389 / 3689 | 0 |
| once-many-wrappers | 1352 | 771 | 134 | 94 | 15 | 94 | 771 / 1091 | 0 |
| fresh-tower | 1423 | 719 | 662 | 719 | 662 | 719 | 719 / 719 | 0 |
| captures | 1382 | 697 | 30 | 0 | 0 | 0 | 697 / 697 | 0 |
| branch-traversal | 1338 | 667 | 15 | 413 | 9 | 413 | 667 / 966 | 0 |
| identity-map | 1331 | 654 | 12 | 654 | 12 | 654 | 654 / 654 | 0 |
| fresh-nested | 1324 | 439 | 343 | 439 | 343 | 439 | 439 / 439 | 0 |
| indexed-chain | 1322 | 381 | 310 | 381 | 310 | 381 | 381 / 449 | 0 |
| library-pipeline | 1368 | 360 | 203 | 360 | 203 | 360 | 360 / 746 | 0 |
| recursion | 1371 | 352 | 102 | 299 | 88 | 299 | 352 / 447 | 0 |
| recursive-higher-order-limit | 1400 | 0 | 0 | 0 | 0 | 0 | 0 / 1400 | 1400 |
| escape-traversal | 1311 | 0 | 0 | 0 | 0 | 0 | 0 / 0 | 0 |

| Seed | Accepted | Distinct | With write | Distinct with write | Aliased | Precision | Limits | Shadowing refused | Mismatches | Elapsed |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 20261011 | 3687 | 2544 | 2373 | 1756 | 2032 (55.1 %) | 3687 / 6206 = 59.4 % | 609 | 335 | 0 | 103 s |
| 17 | 3520 | 2446 | 2293 | 1746 | 1973 (56.1 %) | 3520 / 6137 = 57.3 % | 643 | 320 | 0 | 103 s |
| 271828 | 3474 | 2410 | 2212 | 1657 | 1902 (54.8 %) | 3474 / 6052 = 57.4 % | 667 | 306 | 0 | 103 s |
| total | 10681 | 7400 | 6878 | 5159 | 5907 (55.3 %) | 10681 / 18395 = 58.1 % | 1919 | 961 | 0 | |

(Elapsed includes `--cross-check`.) Before the third review's generator
changes (same seeds): 12 077 accepted, 8 718 distinct, 7 687 with write,
precision 62.3 %. The accepted count fell because the shadowing move is
always refused and the declaration family's programs now end in calls,
many of which the checker refuses. The declaration family's accepted
programs fell too (seed 17: 1 284 → 1 090), but those that run a generated
declaration rose from 228 to 1 045 (below). The v4 mix on seed 20261011:
4 903 accepted, 2 526 distinct, 3 113 with write, 2 806 aliased (57.2 %),
precision 64.4 %. The v3 generator: 6 363 accepted, 1 532 distinct,
precision 65.6 %.

**Precision** counts every typed program whose two runs agree, so the limit
family (1 400 programs refused by design), the shadowing move (refused by
design, and agreeing when it runs) and programs that write nothing anyone
reads again are in the denominator: it is a lower bound on how often the
checker accepts a program that is in fact safe, not a false-alarm rate on
realistic code.

### Generated declarations exercised

Over the declaration family's accepted programs, from the in-place run's
call log (calls of declarations past the fixed table):

| Seed | Accepted (family) | Run a generated declaration | A generated call changes an array its inputs reach | Generated calls | Pass one array at two argument positions |
|---|---:|---:|---:|---:|---:|
| 20261011 | 1109 | 1070 (96.4 %) | 392 (35.3 %) | 1721 | 274 (15.9 %) |
| 17 | 1090 | 1045 (95.8 %) | 384 (35.2 %) | 1721 | 253 (14.7 %) |
| 271828 | 1053 | 1009 (95.8 %) | 339 (32.1 %) | 1625 | 285 (17.5 %) |

The third review measured 18 % / 2.2 % / 11 of 377 calls on the earlier
generator (seed 17, 1 500 programs). What moved them: the forced final
calls (nearly every accepted program now ends in one; the rest are those
whose table is a mutual pair alone, which is never called at the end
because it is always a limit); writer declarations, called on fresh
arguments so that the call is accepted and its write is visible to the
caller's later read of the list; and argument repetition, which a writer
skips (it would be rejected for Disjoint) but readers and higher-order
declarations accept. Most repeated-argument calls the checker refuses: the
15 % counts accepted ones. "Changes an array its inputs reach" compares
each array reachable from the call's arguments and captures before and
after the call.

## Cross-check

The two checkers differ on 28 + 25 + 20 programs that only the summary
checker accepts (each ran with equal traces) and on none that only the
per-call checker accepts. The per-call checker alone (`--reinfer`) accepts
3 659 / 3 495 / 3 454 programs with no mismatch.

## Rows exercised

Accepted programs that write and exercised each checker row (three seeds):

| Row | Programs |
|---|---:|
| callback called through its class; supply resolved at a known callback | 3720 |
| xres yes / xres no | 3714 / 59 |
| a callback's argument in its res | 2042 |
| fresh in a callback's res | 1876 |
| W on a callback argument; edge W ⇒ owned checked | 1008 |
| summary reused after re-asking its guards | 724 |
| supply owned bit cleared at the caller | 657 |
| env in a callback's res | 223 |
| supply owned bit cleared where a step ends | 203 |
| E on a callback argument; shared in its res | 155 |
| xreq on a callback argument; edge xreq ⇒ exclusive checked | 120 |
| guard forwarded / supply transferred to the caller's own input | 112 / 112 |
| once callback's calls checked | 102 |
| ⊤ in a callback's res; E on a callback's environment | 0 |

## Negative controls (flags)

Every required control has a fixed probe in `Fixtures.lean` (86 verdict
fixtures, 25 probes), checked by `ownership fixtures` and `ci`. Separately,
`ownership controls 20000 <seed>` reports the first index (0-based) at which
the generator alone finds an accepted disagreement that the corrected
checker rejects (`regressions/controls-v5-*.log`), all on the final
generator:

| Control | 20261011 | 17 | 271828 | Required |
|---|---:|---:|---:|---|
| `--old-rule` (T59 freshness only) | 18 | 9 | 36 | yes |
| `--old-escape-rule` | 50 | 60 | 9 | yes |
| disjoint | 104 | 8 | 30 | yes |
| borrowed-supply, per-call checker | 268 | 1499 | 1446 | yes |
| borrowed-supply, summaries | not observable: 22 / 34 / 32 verdicts changed, 0 disagree | | | reported |
| traversal-exclusive | 540 | 22 | 987 | yes |
| many-calls | 477 | 2214 | 3368 | yes |
| copy-exclusive | 2216 | 4438 | 8047 | yes |
| close-source | 19 | 543 | 309 | yes |
| keeps-shape | 1808 | 548 | 10265 | yes |
| guard-reuse | 3340 | 1251 | 679 | yes |
| callback-xres | 18 | 9 | 36 | yes |
| supply-edge | 0 | 153 | 346 | yes |
| supply-recheck | 1890 | 1070 | 346 | yes |
| calls-edge | 38 | 67 | 260 | yes |
| callback-writes | 418 | 3674 | 903 | yes |
| callback-aliases | 146 | 160 | 154 | yes |
| callback-env | 192 | 8 | 152 | yes |
| once-through-call | 19 | 390 | 191 | yes |
| branch-live | 145 | 891 | 1985 | yes |
| branch-closure (new) | 202 | 41 | 241 | yes |
| shared-roots (new) | 293 | 106 | 792 | yes |
| shadowing (new) | 2273 | 673 | 284 | yes |
| callback-escapes | 102 | — | — | probe only |
| forward-guards | — | — | — | probe only |
| callback-requires, requires-edge, transfer-supplies | — | — | — | known gaps |

Against the per-call checker (seed 20261011) the first seven are caught at
104, 268, 540, 477, 2216, 19, 1808 (`regressions/controls-v5-reinfer-20261011.log`).
`callback-escapes` is caught on one seed of three (two before the third
review's changes); it stays required through its probe (COVERAGE.md, "Known
gaps"). `ci` took 4 min 18 s on the generator before the last two generator
commits and 6 min 18 s on the final one.

## Source-level mutants

`scripts/run-mutants.sh` applies each edit of `scripts/mutate.mjs` to a copy
of the sources, builds it, and runs the unmodified `oracle 20000 <seed>`
(generator only) on each seed.

**On the final generator** (`regressions/source-mutants-v5.log`): the third
review's holes and the once-through-call fixes undone. First index per seed:

| Hole | 20261011 | 17 | 271828 | Seeds | Third review (its generator) |
|---|---:|---:|---:|---:|---|
| resprov (a call's result forgets its second parameter's provenance) | 192 | 31 | 152 | 3/3 | 3/3 |
| argrecheck2 (writes to a call's second parameter not demanded) | 13 | 109 | 50 | 3/3 | 3/3 |
| pushexcl (a push keeps its list exclusive whatever it stores) | 540 | 4298 | 1828 | 3/3 | 2/3 |
| branchclosure | 202 | 41 | 241 | 3/3 | 0/3 |
| sharedroots | 293 | 106 | 792 | 3/3 | 0/3 |
| nofix1 (both once-through-call demands removed) | 19 | 390 | 191 | 3/3 | — |
| nofix2 (only the written-captures demand removed) | 93 | 64 | 198 | 3/3 | — (fixtures only) |
| hiddencopy (interpreter: every write allocates instead) | — | — | — | 0/3 | — |

`nofix2`'s scratch build failed in the final run (two runs were building at
once); its row is from the generator of commit `0723d842c`, which differs
from the final one only by the copy-then-edit move — not re-run on the
final generator. `hiddencopy` is a hole in the in-place interpreter, not the
checker: an interpreter that copies on every write computes the value
semantics, so no program can make the two runs disagree and the generator
cannot catch it by construction. The fixtures catch it — their expected
in-place observations (the aliasing probes) fail — as the third review
found (its fixtures log: `passed=false`).

**Not re-run on the final generator.** The other 43 edits (the first
review's, the summary rows', and the second review's nine with
`recwritesown`) were last run on the generator of commit `7f9783f71` (after
the declaration, shadowing, shared and branch-closure changes, before the
moves for `pushexcl`, `nofix2` and `copy-exclusive`):
`regressions/source-mutants-v5-shadowing-generator.log`. That run did not yet
record a mismatch before shrinking, so a "none" there may be a catch lost to
a stack overflow (two of `argrecheck2`'s three were). On that generator:

| Mutant | First index (20261011 / 17 / 271828) | Seeds |
|---|---|---:|
| disjoint | 571 / 139 / 140 | 3/3 |
| travexcl | 3092 / 237 / 1963 | 3/3 |
| manycap | 2438 / 1313 / 2456 | 3/3 |
| copyexcl | 1562 / 9256 / 3611 | 3/3 |
| closesrc | 824 / 1085 / 2551 | 3/3 |
| keepsshape | 312 / 2676 / 8054 | 3/3 |
| separated | 34 / 43 / 1 | 3/3 |
| dead | 8 / 2 / 3 | 3/3 |
| escape | 96 / 60 / 39 | 3/3 |
| focusexcl | 34 / 29 / 1 | 3/3 |
| writeout | 62 / 1 / 180 | 3/3 |
| guardreuse | 2333 / 996 / 18 | 3/3 |
| callbackxres | 34 / 43 / 1 | 3/3 |
| supplyedge | 384 / 141 / 1141 | 3/3 |
| supplyrecheck | 3189 / 141 / 8693 | 3/3 |
| callsedge | 58 / 17 / 42 | 3/3 |
| callbackwrites | 1638 / 773 / 63 | 3/3 |
| callbackaliases | 283 / 141 / 18 | 3/3 |
| callbackenv | 0 / 1 / 180 | 3/3 |
| oncethroughcall | 6922 / 9635 / 8398 | 3/3 |
| callbackescapes | 6276 / — / 6075 | 2/3 |
| borrowedsupply | — | 0/3 (summaries; the flag is caught against the per-call checker) |
| requiresedge, callbackrequires, forwardguards, transfersupplies | — | 0/3 |
| xres, once, nestedsep, reqexcloutside, recvalidate, tsupplyexcl, escapeowned | — | 0/3 |

The second review's nine, same generator:

| Hole | 20261011 | 17 | 271828 | Seeds | Before (review, v4) |
|---|---:|---:|---:|---:|---|
| capturelive | 252 | 417 | 1244 | 3/3 | 3/3 |
| copyelems | 732 | 3294 | 5508 | 3/3 | 3/3 |
| putexcl | 62 | 1 | 180 | 3/3 | 3/3 |
| focuscontainer | 2847 | 825 | 202 | 3/3 | 3/3 |
| atelem | 66 | 251 | 858 | 3/3 | 3/3 |
| branchlive | 267 | 116 | 1275 | 3/3 | 0/3 |
| recwrites | — | — | — | 0/3 | 0/3 — masked (COVERAGE.md) |
| keepsany | — | — | — | 0/3 | 0/3 — argued equivalent |
| symenv | — | — | — | 0/3 | 0/3 — masked |
| recwritesown (recwrites with its mask removed) | 360 | — | 1021 | 2/3 | — |

Flag and source versions of a control run on the same generator give the
same first index. COVERAGE.md ("Known gaps") analyses each miss.

## Findings

* **The third review's shadowing defect** (both checkers; fixed on this
  branch by the parent work: shadowing refused in `typecheck`, a `let`'s live
  uses of the name it rebinds pinned to the outer binding). With the rule
  and the pin removed (`--mutant=shadowing`) the generator alone finds it on
  all three seeds.
* **Earlier findings**: two summary-checker defects for a once callback a
  callee calls (second review, fixed, control `once-through-call`); the
  per-call checker's recursion inside a step and a precision defect of the
  Disjoint test through a callback's environment (first review). See git
  history of this file.
* No corrected-rule mismatch in the 60 000 trials on the final generator,
  the per-call checker's 60 000, the v4 and v3 baselines, or the 86
  fixtures.

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
