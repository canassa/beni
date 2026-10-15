# Constructions, views and the function-valued skip — 2026-10-15

The oracle review of 2026-10-15 (PR #132's follow-up) let S7 proceed only on
conditions. This round answers C1, C2 and C5, puts the review's Zig mutations
into the bridge's controls, and corrects the bookkeeping. Neither checker is
weakened; the shipping compiler is unchanged.

## What is modelled now

- **Constructions** (C1, `ownership-checker.md` §3.2): `Prim.construct` is one
  construction of spreads and items, base the first spread. Value semantics
  concatenates; the in-place interpreter writes the base's own array from the
  base, left to right, items before the base first, and reads every later
  spread element by element while the base grows. `xs ++ xs` and a spread of a
  view or alias of the base never terminate in place, which counts as a
  divergence. The checker demands the base with every other operand path in
  Disjoint, reads the spreads, and certifies the result only when the base,
  every spread and the stored values pass the builder's tests.
- **Views** (C2): `Prim.view` is a pattern's `…rest` or `…init`. In place it is
  kept equal to its source's suffix or prefix at every write, both ways: the
  most aliased lowering. The checker gives it its source's cells.
- **Record updates**: no core change; the bridge prints a record of another
  record's fields as `{ r | f = y }` when the types agree.
- **Translator**: constructions rotate through `++` (main body only),
  `List.append` and spread literals; views are `case xs of [ _, …v ] → v; [] → []`
  (or `[ …v, _ ]`).
- **C5**: function-valued results are translated; both sides observe a function
  as `"<function>"`. The confirmation runner compares record fields by name
  (JavaScript orders `f10` before `f2`), the one mismatch the change exposed.

DESIGN.md's last section is the contract, including what stays out: `pop`,
`swap`, `insertAt`, `removeAt`, multi-item prepends, the re-cons rule, trie and
fixed-length runtime views, and evidence-dispatched `++`.

## Lean side

- 99 sync fixtures (21 new) and 740 targeted programs (232 new, all appended:
  every historical id keeps its program).
- Two new required holes, each with a fixed witness and caught by the targeted
  product through accepted interpreter disagreements: `construct-disjoint`
  (16 accepted disagreements) and `view-alias` (40).
- Generator v6 (opt-in, `--generator-version=6`): v5's general families with
  constructions, views and record updates three times as likely as each other
  move, and a table declaration that appends onto its parameter. At seed 17,
  20,000 programs: 1,666 accepted, 1,092 of them writing in place, 364 writing
  an array two names reach, **0 disagreements**. `ownership ci` now runs a v6
  campaign beside v5's.

## Shipping bridge: before and after

"Meaningful" counts the forward leads whose in-place run writes a list (the
review's F7): a lead that writes nothing cannot diverge.

| Campaign | Inputs | Translated | Forward leads (meaningful) | Reverse leads | Confirmed unsafe |
|---|---:|---:|---:|---:|---:|
| CI before (2026-10-15 baseline) | 960 | 467 | 6 (1) | 8 | 0 |
| CI after | 1,341 | 959 | 6 (1) | 43 | 0 |
| Long before | 116,650 | 43,185 | 1,725 (351) | 401 | 0 |
| Long after | 176,903 | 107,163 | 1,985 (515) | 6,239 | **1, pinned** |

The 351 is this round's count of the old leads that write when run in place
(364 contain a writer syntactically; the review counted 375).

| Long stream | Inputs | Translated | Forward (meaningful) | Reverse |
|---|---:|---:|---:|---:|
| Fixtures / sync / targeted | 937 | 703 | 0 | 21 |
| Bound-2 enumeration | 55,966 | 48,391 | 307 (307) | 4,154 |
| v5 seed 17 | 20,000 | 9,663 | 520 (31) | 278 |
| v5 seed 20261011 | 20,000 | 9,699 | 499 (43) | 288 |
| v5 seed 314159 | 20,000 | 9,634 | 501 (31) | 286 |
| v6 seed 17 | 20,000 | 9,637 | 56 (40) | 411 |
| v6 seed 20261011 | 20,000 | 9,731 | 48 (29) | 394 |
| v6 seed 314159 | 20,000 | 9,705 | 54 (34) | 407 |

The v5 and enumeration streams keep their program counts and SHA-256 hashes;
their translations grow because function-valued results are no longer skipped
(enumeration 27,769 → 48,391; each v5 seed about 5,000 → 9,700). The long run
translates 20,993 construction and 10,577 view occurrences.

### Forward leads (Zig accepts, Lean refuses)

All 1,985 originals were run in both Lean interpreters. **1,984 agree. One
diverges**: `v6-17-5271`, below. By Lean's first refusal: `limit` 1,473,
recursive entry 151, supply edge 133, container contents 133, exclusive
contents 64, Dead 31.

### The confirmed case: a callback that returns the callee's own parameter

```
pushReturned p f =
    b = f p
    List.push b 3

identity x = x

pub run ⊤ =
    xs = [ 1, 3, 2 ]
    r = pushReturned xs identity
    { f0 = r, f2 = xs }
```

The shipping checker accepts it. In place, `xs` reads `[1, 3, 2, 3]`; by value
`[1, 3, 2]`. `pushReturned`'s summary records `need owned` for its callback's
result and supplies `π1` owned; at the call, `returnsOwned`'s `.param` branch
(`src/own/Ownership.zig`, `returnsOwned`, the result-provenance switch) accepts
the supply because its owned bit, computed in the callee's frame, is set, and
`provOwned` returns true for any non-callback provenance. Nothing demands the
caller's argument `xs`, which the result reads afterwards. The supply-edge
branch of the same call (`An owned supply of the callee's own parameter`) does
make that call-site demand when the callback *writes* a supplied parameter;
the `need` path, where the callee writes what the callback *returns*, does not.
The red fixture (CK-233 in `plans/checker-findings.md`) is `tests/pending/check/bad/direct/BridgeCallbackReturnsParameter.beni`
(`exit=0 codes=none`; expected `list_still_used` at the call). The Zig checker
is not changed in this PR. Its Lean core is
`regressions/bridge/CallbackReturnsParameter.json`. It surfaced in a v6 stream
whose result held a function value, so neither C5 nor v6 alone would have
reached it on these seeds.

### Reverse leads (Zig refuses, Lean accepts)

Precision, not soundness. Assigned by each program's first refused demand:

| Pattern | Programs | What Zig loses |
|---|---:|---|
| `List.push: once` | 2,507 | a once closure stored or returned with its captured list; the single consumer is not known (the old 272-program pattern, now with closures in results) |
| `value: it is stored in a record` | 1,495 | a closure stored in a record field stays pending; its later call is not followed |
| `List.push: it is returned` | 1,104 | a writer closure returned by a helper stays pending |
| `List.push: it is stored in a record` | 683 | a writer closure kept in a record field |
| `List.update: exclusive` | 148 | independence of nested containers after constructions, wrappers and views |
| `value: it is returned` | 110 | as above, for a returned function value |
| `value: need` | 83 | a callback result edited by its callee cannot be shown owned |
| `List.push: exclusive` | 58 | a fresh inner list treated as possibly shared |
| `List.push: … loses sight of what calls it` | 24 | a function value whose caller is not seen |
| `List.set` / `value` / `call: exclusive` | 27 | as `List.push: exclusive` |

Almost all of the growth is the closure-in-result population that C5 brought
in (the review's 5,022 with v5 alone); the v6 streams add 1,212. The 401
historical reverse sources are all still refused, with identical details.

## Zig controls

`scripts/bridge-mutants.mjs` builds the baseline and each edit of
`src/own/Ownership.zig` in a clean worktree and runs the CI stream. A control
is caught by new Zig-accepts/Lean-refuses verdicts; every new lead of every
caught control was then judged by both Lean interpreters
(`evidence/constructions/mutants/judged.json`).

| Control | Edit | New program leads | Of them, diverging in place | Status |
|---|---|---:|---:|---|
| `dead` | Dead's holder loop removed | 315 | 252 | caught |
| `disjoint` | Disjoint's operand loop removed | 36 | 34 | caught |
| `shared` | top-level cause off | 9 | 9 | caught |
| `view` | a pattern's `…rest` binds no cells | 46 | 46 | **caught** (missed before) |
| `append` | later spreads dropped from Disjoint | 19 | 19 | **caught** (missed before) |
| `record` | a record update's base not used | 9 | 5 | **caught** (missed before) |
| `oncecall` | a once closure's later calls ignored | 13 | 13 | caught |
| `spreadcert` | a construction spreading a live list keeps the base's exclusivity | 5 | 5 | caught (new) |
| `foldret` | fold accumulator accepts a result from another parameter | 0 | — | equivalent (argued below) |
| `keepshape` | keep-shape drops the taken supply's condition | 0 | — | equivalent (argued below) |

`append`'s divergences are in-place runs that never end (the base is its own
spread), so they write no finished array.

**`foldret`.** `foldAccumulator` only decides whether a callback's fresh
allocations get optimistic container seeds in `instFold`; the result cells
themselves come from `instCbOnce` either way. `instFold` then re-runs the
callback until the conditions stop changing, conjoining each round's, so a seed
survives only if the callback re-establishes it whatever parameter its result
came from. Evidence: no verdict changes on the CI stream (1,332), on the 162
ownership/direct corpus fixtures and review probes, and none on the review's
long run (43,185 programs). Removing the fold-loan rule as well changes exactly
the 12 verdicts removing the fold-loan rule alone changes, so `foldret` is not
being masked by that rule on any program found.

**`keepshape`.** A `keep` atom is made only by the focus rows (`List.update`'s
and the dictionary focus's), whose supply is always a taken element with the
container's exclusivity as its condition. `keepShape` ends with the deep
condition of the callback's instantiated result, and a taken element's
condition is its container's (§18.5). So the dropped conjunct is implied by
the one that remains. Evidence: the same three populations, no verdict change.

## What this does not show

- Entry rows, sends, `pop`/`swap`/`insertAt`/`removeAt` and record field
  assignment (§7.4) are still outside the oracle (`ownership-checker.md` §26.7).
- The Lean in-place interpreter judges the checker's promise, not S7's emitted
  code (C3, C4): no tool here runs the real in-place lowering.
- Views are judged under the most aliased lowering; the shipping runtime's
  fixed-length view hides a push of its source that this model shows.
- Finite campaigns are evidence, not proofs; the three unproved soundness
  statements are unchanged.

## Evidence and reproduction

`evidence/constructions/{ci,long}/` hold each campaign's report (cases
counted), every lead's source and runtime outcome (`evidence.json.gz`, read with
`scripts/bridge-evidence.mjs case …`), the original-program audit and both
interpreters' traces for every forward lead. `evidence/constructions/mutants/`
holds the control report and the Lean judgment of every caught lead. Both
campaigns used one frozen ReleaseSafe compiler built from master `dd38d162e`
(SHA-256 in the reports), on CPUs 8–23 with eight workers.

Inside `nix develop .#ownership`, from `proofs/ownership`:

```sh
lake build && lake build triage
lake exe ownership ci 20000 17
lake exe ownership oracle 20000 17 --generator-version=6
node scripts/bridge.mjs --long --no-build --no-minimize \
  --compiler=../../zig-out/ownership-constructions-beni --out=../../zig-out/c1-long --jobs=8
node scripts/bridge-fix-audit.mjs ../../zig-out/c1-long \
  ../../zig-out/ownership-constructions-beni ../../zig-out/c1-audit-long
node scripts/bridge-mutants.mjs            # all ten controls; name some to run only those
```
