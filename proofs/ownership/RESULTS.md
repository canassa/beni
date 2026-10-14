# Round 6 results

The last Lean runtime change is `83b6dcf` (generator v5, checker, both interpreters,
falsifier and enumeration). All measurements below use those final runtime
sources; later commits contain reports and retained evidence. Lean 4.29.1 is
pinned. Linux runs used the isolated worktree on `dagon` under
`nix develop .#ownership`, with every descendant pinned to CPUs 0–7. The macOS
compiler gates used `zorg`, with Node 24 from Nix. Previous rounds' numbers
remain in git history and explicitly historical passages of COVERAGE.md.

## Findings addressed

1. **Nested closures and function-typed joins.** `namesAt` follows captures
   recursively; symbolic captures use the environment row. A mismatched-shape
   join retains every cell of both alternatives under unknown, so an unknown
   result used as data cannot hide its captured array. Unknown functions are
   still refused when called.
2. **Closure factories and callback vacuity.** Result descriptions name arrays
   through arbitrarily nested known captures and through symbolic environments.
   Summary clause 1 admits a called callback's environment writes, demanded at
   its caller. The unnecessary unique-holder premise is removed. Vacuity is
   counted per call and fails above 0.5% for non-separation reasons or 5% for
   separating-input aliasing; these are coverage budgets, not proofs.
3. **Quote character audit bypass.** The authoritative audit uses Lean's parser,
   builds its trusted executable before audited elaboration, checks a clean
   committed export and unchanged source/binary hashes, then replays Ownership
   and Main constants in the kernel. The ` '"' ` followed by a hidden sorry
   probe is rejected as four sorries. The in-build audit remains an extra check.
4. **Missed `setexcl` / `oncelive` holes.** Fixed probes and required controls
   cover both; generator moves reach both. The source sweep below records their
   independent baseline verdict differences and concrete disagreements.
5. **Randomly missed shapes.** A seed-independent bounded grammar enumerates
   syntax with typed operands, including joins returned as data, nested closures
   and last-two-result observations. CI uses bound 2; bound 3 is measured below.
   This is exhaustive only for that grammar, not for the ownership core.
6. **Crash evidence.** Source sweeps check every newly accepted program without
   shrinking, flush the first mismatch and save its original AST first. Every
   seed retains counts, status and logs. A deliberate SIGSEGV after the first
   mismatch was reported as `CRASH-after-mismatch` on all three seeds (indices
   321 / 284 / 156, exit 139), retained all originals, and failed the runner.
   This injection is separate from the source-mutant matrix; real sweeps did
   not crash.
7. **Additional defects found while finishing.** Recursive closure agreement
   excludes mislabelled inner code; recursive closure honesty excludes a falsely
   many-use inner closure; `WellTyped` checks actual heap values as well as
   value-side observations (including dead close sources). These premise fixes
   have build-time regression guards. A real accepted mismatch remained when
   a higher-order callee called an outer once closure capturing an inner once
   closure whose array had been revived by `close`. `demandCallbackCaptures`
   now recursively demands capture writes and roots, forwards symbolic call
   counts and checks multiplicity. The fixed verdict fixture failed before the
   fix and passes after it; both search grammars now contain the shape.

## Differential campaigns

20,000 programs per seed, summary checker plus per-call cross-check. Every
accepted program was executed in both interpreters. Cross-check verdict
precision differences are reported, not counted as semantic disagreement.

| Seed | Typed | Accepted | Distinct accepted | With write | Aliased write | Limits | Cross-check verdict differences | Mismatches / execution errors |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 20261011 | 20000 | 3064 | 2019 | 1960 | 1701 | 582 | 18 / 0 | 0 / 0 |
| 17 | 20000 | 3062 | 2001 | 1989 | 1765 | 601 | 16 / 0 | 0 / 0 |
| 271828 | 20000 | 3123 | 1988 | 1960 | 1714 | 570 | 10 / 0 | 0 / 0 |

Full family counts and summary reuse/hit counts are in
`regressions/campaign-round6-{20261011,17,271828}.log`.
`ownership ci` passes 93 verdict fixtures and all fixed control probes,
one 20,000-program campaign, all required generator controls and bound 2.
Standalone `controls 20000` passes on seeds 17 and 271828 as well. Optional
or equivalent controls are reported without being falsely required.

## Source-mutant matrix

All 62 planted source edits from the five reviews: 20,000 generated programs
on each of seeds 20261011, 17 and 271828. The unedited executable supplies
accepted indices; the mutated executable cannot supply its own baseline.
Every newly accepted program runs at fuel 100,000. The three baseline
accepted-index lists and runtime SHA-256 manifest are retained in regressions;
enumeration baseline hashes are in `enum-baseline-round6.sha256` (the full
90 MB bound-3 key list remains in the isolated Linux scratch checkout). There are no build failures,
crashes, or inconclusive executions in this matrix.

Generator cells are **mismatches; newly accepted / newly rejected** against
that independent baseline. A positive mismatch count catches a hole. The full
stream is visited even after its first mismatch. Enumeration cells are
**caught or miss; newly accepted**, at bounds 2 and 3. Enumeration stops at its
first witness, so a caught row is a prefix count, not a complete verdict total.
It has no seed: the same deterministic result applies to all three seeded
columns and is run once per edit, not three times under fictitious seeds.
A dash means bound 3 was not run for that edit. Raw counts include visited
programs and retained witness ASTs in `regressions/mutant-evidence/` and
`regressions/mutant-evidence-bound3/`.

| Source edit | Generator 20261011 | Generator 17 | Generator 271828 | Enum 2 (all seeds) | Enum 3 (all seeds) | Verdict |
|---|---:|---:|---:|---|---|---|
| `disjoint` | 63; 109/0 | 64; 98/0 | 64; 115/0 | caught; 1 | — | caught |
| `borrowedsupply` | 0; 18/0 | 0; 15/0 | 0; 12/0 | miss; 98 | — | argued equivalent |
| `travexcl` | 31; 34/0 | 35; 37/0 | 29; 32/0 | caught; 5 | — | caught |
| `manycap` | 5; 10/0 | 5; 17/0 | 6; 11/0 | miss; 0 | — | caught |
| `copyexcl` | 9; 56/0 | 19; 60/0 | 14; 62/0 | miss; 4 | — | caught |
| `closesrc` | 53; 76/0 | 53; 69/0 | 58; 90/0 | caught; 11 | — | caught |
| `keepsshape` | 1; 12/0 | 3; 9/0 | 1; 15/0 | miss; 4 | — | caught |
| `xres` | 33; 64/0 | 23; 47/0 | 29; 46/0 | miss; 0 | — | caught |
| `separated` | 625; 709/0 | 595; 657/0 | 626; 685/0 | caught; 1 | — | caught |
| `dead` | 1711; 2184/0 | 1709; 2155/0 | 1720; 2168/0 | caught; 1 | — | caught |
| `escape` | 561; 561/0 | 517; 518/0 | 547; 547/0 | caught; 1 | — | caught |
| `focusexcl` | 622; 813/0 | 612; 763/0 | 641; 812/0 | caught; 7 | — | caught |
| `once` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | — | argued equivalent |
| `nestedsep` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | — | argued equivalent |
| `reqexcloutside` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | — | argued equivalent |
| `recvalidate` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | — | argued equivalent |
| `writeout` | 106; 174/0 | 108; 162/0 | 110; 158/0 | miss; 0 | — | caught |
| `tsupplyexcl` | 33; 64/0 | 23; 47/0 | 29; 46/0 | miss; 0 | — | caught |
| `escapeowned` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | — | argued equivalent |
| `guardreuse` | 26; 28/0 | 22; 23/0 | 14; 14/0 | miss; 0 | — | caught |
| `callbackxres` | 555; 580/0 | 540; 561/0 | 571; 601/0 | miss; 0 | — | caught |
| `supplyedge` | 30; 50/0 | 26; 46/0 | 19; 51/0 | caught; 66 | — | caught |
| `supplyrecheck` | 8; 28/0 | 3; 21/0 | 7; 39/0 | miss; 175 | — | caught |
| `callsedge` | 112; 160/0 | 125; 162/0 | 107; 147/0 | caught; 1 | — | caught |
| `requiresedge` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | — | argued equivalent |
| `callbackwrites` | 9; 58/0 | 15; 54/0 | 8; 39/0 | caught; 1 | — | caught |
| `callbackescapes` | 25; 25/0 | 21; 21/0 | 20; 20/0 | miss; 0 | — | caught |
| `callbackaliases` | 87; 144/0 | 96; 128/0 | 99; 153/0 | miss; 439 | — | caught |
| `callbackenv` | 131; 216/0 | 103; 194/0 | 117; 216/0 | caught; 1 | — | caught |
| `callbackrequires` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | — | argued equivalent |
| `forwardguards` | 18; 18/0 | 16; 16/0 | 10; 10/0 | miss; 0 | — | caught |
| `transfersupplies` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | — | argued equivalent |
| `oncethroughcall` | 100; 121/0 | 117; 133/0 | 105; 135/0 | caught; 1 | caught; 1 | caught |
| `capturelive` | 101; 120/0 | 90; 103/0 | 90; 114/0 | caught; 1 | — | caught |
| `copyelems` | 1; 3/0 | 1; 2/0 | 2; 3/0 | caught; 1 | — | caught |
| `putexcl` | 83; 150/0 | 70; 123/0 | 78; 125/0 | miss; 0 | — | caught |
| `recwrites` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | — | argued equivalent |
| `recwritesown` | 19; 79/0 | 16; 85/0 | 27; 94/0 | miss; 0 | — | caught |
| `keepsany` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | — | argued equivalent |
| `symenv` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | — | argued equivalent |
| `branchlive` | 6; 23/0 | 15; 32/0 | 18; 33/0 | caught; 7 | — | caught |
| `branchclosure` | 36; 42/0 | 31; 37/0 | 38; 42/0 | caught; 1 | — | caught |
| `sharedroots` | 49; 49/0 | 57; 57/0 | 52; 52/0 | caught; 1 | — | caught |
| `sharedfn` | 3; 3/0 | 13; 13/0 | 13; 13/0 | miss; 0 | — | caught |
| `manyoff` | 18; 18/0 | 15; 15/0 | 16; 16/0 | caught; 1 | — | caught |
| `noscope` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | — | gap |
| `joinexcl` | 116; 215/0 | 93; 170/0 | 107; 172/0 | miss; 0 | — | caught |
| `resprov` | 113; 181/0 | 92; 154/0 | 100; 155/0 | caught; 1 | — | caught |
| `argrecheck2` | 164; 208/0 | 160; 207/0 | 176; 225/0 | miss; 0 | — | caught |
| `pushexcl` | 12; 12/0 | 19; 20/0 | 10; 11/0 | miss; 0 | — | caught |
| `nofix1` | 100; 121/0 | 117; 133/0 | 105; 135/0 | caught; 2 | — | caught |
| `nofix2` | 45; 66/0 | 48; 64/0 | 52; 82/0 | miss; 0 | caught; 17 | caught |
| `hiddencopy` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | — | gap |
| `focuscontainer` | 9; 25/0 | 6; 16/0 | 6; 16/0 | caught; 1 | — | caught |
| `atelem` | 29; 31/0 | 23; 25/0 | 32; 34/0 | caught; 2 | — | caught |
| `shadowing` | 25; 26/0 | 16; 18/0 | 17; 17/0 | miss; 0 | — | caught |
| `setexcl` | 13; 14/0 | 21; 22/0 | 23; 26/0 | miss; 0 | caught; 51 | caught |
| `oncelive` | 13; 13/0 | 9; 9/0 | 15; 15/0 | caught; 1 | — | caught |
| `envinst` | 96; 160/0 | 78; 138/0 | 89; 139/0 | caught; 1 | — | caught |
| `keepsep` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | — | gap |
| `ownedothers` | 5; 15/4 | 2; 7/2 | 1; 11/1 | miss; 0 | — | caught |
| `joindrops` | 0; 0/0 | 0; 0/0 | 0; 0/0 | miss; 0 | caught; 1 | caught |

Generator: 46 edits caught; bound 2: 24 edits caught. Union: 47 caught, 12 argued equivalent, 3 gaps.

The 12 equivalence/masking arguments and their changed-verdict counts are
written in [COVERAGE.md](COVERAGE.md#equivalent-argued). They are arguments,
not Lean proofs. No unchanged verdict is presented as an argument by itself.
The summary-checker `borrowedsupply` edit changes some verdicts without a
trace mismatch; the per-call checker still has a required borrowed-supply
control. `recwritesown` removes the second check masking `recwrites` and is
caught. `supplyrecheck` removes the check masking `symenv` and is caught.

Remaining gaps:

- **`noscope`:** typed programs cannot have an unbound live variable. CI's
  checker-level configuration probe reaches it; generated syntax cannot.
- **`hiddencopy`:** an interpreter-only edit changes no checker verdict, and
  changed-verdict sweeps do not execute it. The source-mutated fixed probes
  fail (`hiddencopy-fixtures-round6.log`). Add direct mutation/write-behaviour
  checks to campaigns to expose it there; do not claim universal equivalence.
- **`keepsep`:** the current grammars lack a focused list of two-list records
  whose body duplicates a fresh list across fields. `keepsep-probe.txt` and
  its corrected/mutated logs show the mutant returning an exclusive result
  with a repeated physical footprint; the corrected checker drops that
  certificate. Add that shape and concrete certificate checking to search.
  This is a certificate counterexample, not a measured trace mismatch.

## Bounded enumeration

```text
enumerate bound=2 enumerated=55966 typed=55966 accepted=31680 with-write=10468 mismatches=0 inconclusive=0 caught=false elapsed-ms=1262
```

```text
enumerate bound=3 enumerated=20965567 typed=20965567 accepted=7323438 with-write=2713330 mismatches=0 inconclusive=0 caught=false elapsed-ms=1218933
```

Bound 3 includes 20,965,567 programs. Its targeted edits are `joindrops`,
`setexcl`, `oncethroughcall` and `nofix2`; table results above state what it
actually catches. The generator's closure-join move calls the unknown join,
which both checkers refuse; keeping the result as data is why enumeration
can reach the lost-cells edit. Neither grammar is exhaustive over declarations,
types, recursion or arbitrary expression depth.

## Attempts to falsify the three unproved statements

100,000 random configurations and calls of 100,000 generated programs per
seed. Configuration hypotheses are tested; all uncovered configurations
are refused. Nested and deliberately mislabelled captures are exercised.

| Seed | Accepted configurations | With write | Nested accepted | Mislabelled closures excluded | Uncovered / accepted | Both runs fail at low fuel | Violations |
|---|---:|---:|---:|---:|---:|---:|---:|
| 20261011 | 66141 | 21248 | 22793 | 7377 | 10391 / 0 | 1290 | 0 |
| 17 | 66143 | 21088 | 22579 | 7304 | 10489 / 0 | 1298 | 0 |
| 271828 | 66247 | 21002 | 22868 | 7203 | 10413 / 0 | 1282 | 0 |

`checked` below counts satisfying summary/call pairs; `calls` and vacuity
count actual calls once. Separating vacuity means the same array occurs at
non-aliasing canonical input origins. The guard/other count includes calls
for which no cached summary's guards match, not a theorem violation.

| Seed | Calls | Checked pairs | Map pairs | Vacuous: separating | Vacuous: description | Vacuous: other | Violations |
|---|---:|---:|---:|---:|---:|---:|---:|
| 20261011 | 44111 | 57832 | 4270 | 1315 | 0 | 13 | 0 |
| 17 | 44328 | 57606 | 4237 | 1290 | 0 | 10 | 0 |
| 271828 | 43910 | 57619 | 4200 | 1221 | 2 | 7 | 0 |

There are no unique-holder exclusions. Two calls on seed 271828 are
classified under description by their first candidate summary. Diagnostic
replay (`vacuity-round6-described.log`) shows another candidate does describe
each captured array, but no candidate satisfies all hypotheses. The reason
counts classify the first non-guard exclusion, not every failing candidate. All non-separation exclusions
remain below 0.5% and separating exclusions below 5%. This is explicitly
incomplete coverage, not a claim that every accepted call meets the lemma's
premises. The fixed symbolic-capture and nested-factory cases now have
meaningful descriptions.

## Proof status and validation

Three `sorry`s remain in Soundness.lean:

- **`invariant_preserved`:** believed true because separating names plus
  Unescaped/Dead/Disjoint demands protect every live holder and observer;
  actual values are typed on both sides and captured code and once classes
  agree recursively. Calls need the summary lemma and scopes need an
  induction maintaining names and certificates. That induction is unfinished.
- **`summary_sound`:** believed true because inference computes a validated
  fixed point of canonical W/E/result rows and rechecks callback guards at
  calls. Called function environments and nested results are named. The
  separating-input premise and clause 4's missing invocation model remain
  explicit limitations; no universal proof is claimed.
- **`map_summary_sound`:** believed true from summary soundness plus builder
  put/close contracts: each stored row is exclusive and separated, and close
  records source provenance. The derived certificate proof is unfinished.

`accepted_traces_agree` is proved conditional on `invariant_preserved` and
therefore still depends on `sorryAx`. The audit pins exactly those four
dependent constants; it does not certify ownership soundness.

The Lean build and CI pass on these sources. `scripts/audit.sh` and the four
requested checks are rerun on the committed report head before push; the
final immutable head and exit results are recorded in the PR review reply.
`zorg build gates` has the four known macOS failures: both stale-path
case-folding tests and both browser-driver cache-pruning CPU-budget tests.
They are untouched; no gate success is claimed. No compiler/runtime code in
beni was changed, so no emitted-output hash refresh is needed.

Not completed: the three proofs, summary clause 4, the three search gaps above,
and unbounded enumeration. The sixth independent review is requested after
push; PR #65 is not merged.
