# Results: generator v4, the summary layer, required negative controls

All runs: Lean 4.29.1, from `proofs/ownership`, logs in `regressions/`
(`scripts/campaigns.sh` regenerates them). Elapsed time is the oracle's
monotonic clock (generation, checking, both interpreters, shrinking), measured
while other campaigns ran on the same machine, so it is an upper bound.

## What changed since the review

The review (2026-10-11) found that none of seven deliberate checker holes was
caught in 60 000 trials; that the only general family (`anf-chain`) ended
every program with a record of all its variables, so **0** of its accepted
programs wrote in place; and that the checker re-inferred each callee per
call, so the oracle never exercised the thesis's summary rows.

* Generator v4 replaces `anf-chain` by a general family (`Generator.lean`).
* The checker publishes per-function summaries and uses them at call sites
  (`Checker.lean`); the per-call checker is kept as `Reinfer.lean`.
* Twelve mutants are `--mutant=` flags and required controls; each has a
  fixture that disagrees under it.

## Accepted programs that write in place

Corrected checker (summaries), 20 000 trials per seed. "With write" counts
accepted programs whose in-place run executed at least one `set`, `push` or
focus write-back (builder `put` excluded). Every accepted program ran in both
interpreters with identical traces.

| Family | Accepted (3 seeds) | With write | Before (v3) |
|---|---:|---:|---|
| general (v4, replaces anf-chain) | 4918 | **3173** | anf-chain: 522 accepted, **0** with write (review: 0 of 166 on one seed; 0 of 186 here on seed 20261011) |
| identity-map | 1413 | 1413 | |
| fresh-tower | 1308 | 1308 | |
| once-many-wrappers | 1502 | 176 | |
| branch-traversal | 1345 | 839 | |
| fresh-nested | 911 | 911 | |
| indexed-chain | 833 | 833 | |
| library-pipeline | 666 | 666 | |
| recursion | 665 | 573 | |
| captures | 1357 | 0 | |
| escape-traversal, recursive-higher-order-limit | 0 | 0 | |

| Seed | Typed | Distinct ASTs | Accepted | With write | Limits | Mismatches | Elapsed |
|---|---:|---:|---:|---:|---:|---:|---:|
| 20261011 | 20000 | 12166 | 4889 | 3202 | 933 | 0 | 72 s |
| 17 | 20000 | 12171 | 4995 | 3325 | 882 | 0 | 40 s |
| 271828 | 20000 | 12262 | 5034 | 3365 | 959 | 0 | 48 s |

Generator v3 on seed 20261011 is reproduced unchanged by
`--generator-version=3` (6363 accepted, 4080 with write, 0 mismatches) under
the summary checker, the same acceptance as the per-call checker gave.

## Summary layer

* **No corrected-rule mismatch** in the 60 000 trials above, nor in the 76
  fixtures (both checkers agree with every intended verdict).
* **Computed once.** Per seed about 9 700 summaries were computed and about
  183 000 call sites (including class queries) were served from the cache
  after re-asking their guards.
* **Cross-check** (`--cross-check`): the summary and per-call checkers differ
  on 2 of 60 000 programs (seed 17 index 9380, seed 271828 index 4830), both
  accepted only by the summaries and both with equal traces; the per-call
  checker rejected them with "exclusive contents". No program is accepted by
  the per-call checker alone.
* `ownership summaries` prints the published rows of the accepted fixtures
  (`regressions/summaries-fixtures.log`). For T43's construction fold, foldl
  publishes `use π1 = RAW`, `res ε = {π1} excl`, `calls slot 2 = many` and a
  supply `arg1 = {π1} owned excl`, under 14 class facts per argument state.

## Negative controls

`ownership controls 20000 <seed>`: one campaign per control, stopped at the
first accepted disagreement, which is shrunk and must be rejected by the
unmutated checker. First index caught (0-based), generator alone:

| Control | 20261011 | 17 | 271828 |
|---|---:|---:|---:|
| `--old-rule` (T59 freshness only) | 13 | 4 | 18 |
| `--old-escape-rule` | 33 | 42 | 5 |
| disjoint | 368 | 591 | 267 |
| borrowed-supply (per-call checker; COVERAGE.md) | 131 | 1809 | 2555 |
| traversal-exclusive | 1340 | 2159 | 1126 |
| many-calls | 424 | 1595 | 723 |
| copy-exclusive | 997 | 7568 | 11288 |
| close-source | 2417 | 311 | 759 |
| keeps-shape | 1099 | 19351 | 484 |
| guard-reuse | 1825 | 135 | 2499 |
| callback-xres | 13 | 4 | 18 |
| supply-edge | 458 | 202 | 664 |
| supply-recheck | 458 | 295 | 5432 |
| calls-edge | 55 | 9 | 136 |

Against the per-call checker (`--reinfer`, seed 20261011) the review's seven
are caught at 368, 131, 1340, 424, 997, 2417, 1099. `keeps-shape` on seed 17
(19 351 of 20 000) is the thinnest margin. The fixtures check each control's
probe: rejected by the checker, accepted under the mutant, traces differ.

## Source-level mutants

`scripts/run-mutants.sh` applies each edit of `scripts/mutate.mjs` to a copy
of the sources, builds it and runs the unmodified `oracle 20000 <seed>` for
the three seeds (generator only, no fixtures). Results are in
`regressions/source-mutants-v4.log`. First index caught per seed
(20261011 / 17 / 271828); "—" means not caught in 20 000 trials.

| Mutant (source edit) | First index | Seeds |
|---|---|---:|
| disjoint | 368 / 591 / 267 | 3/3 |
| borrowedsupply | — / — / — | 0/3 (subsumed under summaries; caught by the per-call checker, see controls) |
| travexcl | 1340 / 2159 / 1126 | 3/3 |
| manycap | 424 / 1595 / 723 | 3/3 |
| copyexcl | 997 / 7568 / 11288 | 3/3 |
| closesrc | 2417 / 311 / 759 | 3/3 |
| keepsshape | 1099 / 19351 / 484 | 3/3 |
| separated | 13 / 4 / 18 | 3/3 |
| dead | 3 / 11 / 8 | 3/3 |
| escape | 33 / 42 / 5 | 3/3 |
| focusexcl | 13 / 4 / 18 | 3/3 |
| writeout | 125 / 219 / 88 | 3/3 |
| xres, once, nestedsep, reqexcloutside, recvalidate, tsupplyexcl, escapeowned | — | 0/3 |
| guardreuse | 1825 / 135 / 2499 | 3/3 |
| callbackxres | 13 / 4 / 18 | 3/3 |
| supplyedge | 458 / 202 / 664 | 3/3 |
| supplyrecheck | 458 / 295 / 5432 | 3/3 |
| callsedge | 55 / 9 / 136 | 3/3 |
| callbackaliases | 59 / 77 / 336 | 3/3 |
| callbackenv | 125 / 8 / 17 | 3/3 |
| callbackwrites | 1763 / — / 3040 | 2/3 |
| requiresedge, callbackrequires, callbackescapes, forwardguards, transfersupplies | — | 0/3 |

The seven the review required are all caught in summary mode except
`borrowedsupply`, which is caught against the per-call checker (COVERAGE.md
argues it cannot be observed under summaries). The flag versions of the
first seven and the summary rows give identical first indices, so the flags
are the same edits. Not caught, and not claimed equivalent: the review's other
seven that it also reported missed (`once` and `xres` among them), the `xreq`
edge and the `xreq`/`E` guards of callbacks (no callback in the tables
requires its argument exclusive or publishes it), and the two forwarding
mechanisms (`forwardguards`, `transfersupplies`): no generated declaration
passes its own function-typed input to another declaration, so forwarding a
guard or a supply to the caller is untested.

## Findings

* **Real defect, executable checker (not the thesis).** The per-call checker
  analysed a recursive call inside a traversal step with an empty summary and
  accepted a program whose value run returns 8 and in-place run 11. Fixture
  "recursion inside a step"; both checkers now refuse it as a limit. Found by
  reading while building the summary layer; no generated family produces it.
* No corrected-rule mismatch otherwise.

## Reproduction

```sh
nix develop .#ownership
cd proofs/ownership
lake build
.lake/build/bin/ownership ci                      # fixtures, one campaign, every control
.lake/build/bin/ownership oracle 20000 17 --cross-check
.lake/build/bin/ownership controls 20000 271828
scripts/campaigns.sh                              # all logs above
scripts/run-mutants.sh /tmp/mutants 20000 20261011 17 271828
lake env lean Axioms.lean                         # axioms of each theorem
```
