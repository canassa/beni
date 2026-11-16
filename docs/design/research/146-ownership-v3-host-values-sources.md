# 146 — Ownership v3: a value read at a type with more places than its own

*Research report, 2026-11-16. A blind round found a soundness fault in the checker v3 (`--ownership=v3`,
`src/own3/`): a record offered to a `Queue` and taken back by `Queue.takeAll` was written in place while
the program still read it. This report finds the cause, fixes the class at its root, lists every place
the same mistake was found, and measures the change. The kernel is `ownership-v3-kernel.md`; this report
adds its §3.4 and revises §6 rule 10, §8 and §9.*

---

## 1. Result

- **The cause** (§2): a value can be read at a place whose type has more locations than the value's own
  layout has. A `Js.Value` that `Js.to` gives the type `List R` has one location; the answer has a list
  and its elements. The reading went through the call map (`Loc.cover`), which sends the value's one wide
  entry to the reading's entry at the same place, so every location below it read as holding **no
  cell**. Kernel §3 says that no state may read "unknown" as "empty"; this one did.
- **The fix** (§3): a wide entry of a value's own layout holds the cells of every location of another
  reading below it, and is read there (`Loc.holes`, kernel §3.4), by each reader that goes through a
  call map: `leavesSet`, `argEntries`, `readBy`, `otherReaches`. Locations below one wide entry are no
  two places of it: a summary there is `twice`, and four facts that rested on "apart" no longer do
  (the callee's claim, the apart-arguments rule, test 2 of §5, the part of a result that `pairedLeaves`
  reads). Worded rows follow the same rule (`Check.holdsAt`). A safe-build check (`Frame.checkEmpty`,
  §9) refuses a published result location with no source where the wide entry above it holds a cell.
- **Same mistake, found** (§4): in `core/`, `Queue.takeAll`, `takeN`, `takeList`; `Schema.describe`'s
  definitions, the engine's `fieldList`, `variantList`, `ctorList`, `finish`, and the `input` of every
  issue of `Schema`'s and `Json`'s decoders, encoders and runners (21 declarations); a value of a type
  variable read at a finer type; a local that the type check generalises; the folded payload of a
  non-regular type (`T (List a)`); and, found by the review, one value at two single places of an answer
  (`Js.to (Js.from ( x, x ))` read as a pair). **Five run fixtures** fail before the fix and pass after.
  No platform in scope (`node`, `html`, `browser-inline`) had one: their contracts do not change.
- **Verdicts** (§5): of the 2 752 ownership roots, 10 change a verdict, every one from accepted to
  refused, none the other way. Five of those fixtures say in their own text that the write must be
  refused (the old acceptance was the fault); the rest are precision losses on folded and row types,
  named. **Real-writes ledger: 294 of 308 before and after**, line for line; every v3 demand of the 32
  real roots has the same verdict.
- **Sweeps** (§6): every generator, every fault folder, the blind round's programs, the review's
  programs and the corpus under the four legs: **0 faults**. A new generator, `host-values.mjs` (81
  programs), finds 22 faults on the base and none on the fix.
- **Speed** (§7): v3 on the 32 real roots +0.6 % without one root; with it +15.8 %, all of it
  `platforms/browser`'s `Gpu.Engine`, whose walk now goes past a declaration that passed its budget on the
  base (the memo of §3; the same verdicts; #2539).
- **Review** (§8): one fresh adversarial reader found a fault the first version left open (one value at
  two single places); fixed, with a fixture, a generator family and kernel text.

## 2. The fault and its cause

The program (`blindQ/faults/queue-takeall/record.live`, now `run/QueueTakeAllElement`):

```text
r0 = { x = n, y = 2 }
q = Queue.unbounded ⊤
_ = Queue.offer q r0
w = case Queue.takeAll q of
        [ v, …_ ] → { v | x = 99 }
        [] → r0
Node.print "${w.x} ${r0.x}"              -- plain 99 1; in place 99 99
```

v3 said `update v: accepted fresh`. `takeAll` calls `takeList`, which answers `Js.to got`, where `got` is
a `Js.Value`. `Js.to : returned Value → a` is an identity (`Frame.isIdentity`), so the answer is `got`
itself, a value whose own layout is `Value`'s: **one opaque entry**. `finish` read it at the result's
place, `List a`, through `leavesSet`: the call map `cover(List a, Value)` sends the opaque entry to the
list's own entry, and the element location `[*]` hit nothing. The contract said
`res [ outside fresh112! … π1@0] [[*]]`: the elements hold no cell. In the caller an element of the
answer was then a cell nobody else held.

A record field in the same position was not affected (`boxed`, in the blind round's mechanism): the
projection of a step that a value's own layout does not have makes `unknown` over the value (`project`),
which reads everything. The list's element was read by `finish` and by calls, not by a projection.

**The class.** The same reading happens wherever a value's own layout is coarser than the place it is
read at, and a type variable can be coarser too: a value of type `a` read at `List (List b)`; a local
whose type the type check generalised (`got = Task.callback …`, `x = Js.to v`: `∀c. c`), read at an
instance; a payload that the place graph folds onto a variable (`type T a = Leaf a | Wrap (T (List a))`,
kernel §8's folded types). Each of them read the locations below the variable through the map and found
nothing there.

## 3. The fix

**A wide entry stands for every location below it** (kernel §3.4). `Loc.Table.holes(view, own)` gives,
for each location `j` of a reading `view` of a value of layout `own`:

- `above[j]`: the wide entry of `own` strictly above `j` that holds its cells (`cover(own, view)[j]`, when
  it is wide and at another location), or none;
- `read[j]`: the same entry where the map `cover(view, own)` puts it at another entry of `view`, so that a
  reading through the map alone would miss it.

Every reading through a map reads `read[j]` with what the map gives: `leavesSet` (a frame's result in
`finish`, the parts of a construction, the arms of a join), `argEntries` (what a call reads, writes, lets
escape and answers of an argument), and the flags that `readBy` and `otherReaches` compare
(`holeFlags`). Where `pairedLeaves` asks for a part that is below a wide entry, a `var` or `opaque` entry
above it is read too. The fallback is what kernel §4.1 already named ("all of the entry as the
fallback"); the readers had not taken it.

**Below one wide entry, nothing is apart.** A wide location holds one value, and that value can hold one
cell at two of the locations below it. So:

1. a summary location below a wide entry is `dup` (`twice` in a contract);
2. the callee's claim (`!Contract.nonlinear`, kernel §4.4) covers two locations of the caller only where
   they are at two locations of the callee: two locations at one wide callee location, or at all of them
   (`Loc.all`), are tested by their atoms, each pair that can hold one cell (`canShare`)
   (`deriveLinearSplit`);
3. an argument read through a wide entry of its own that is above two locations of the parameter, or above
   a summary, is not apart (`argsSplit`), so the contract's claims about two sources do not hold;
4. a written location below a wide entry of the operand's own layout is that entry; any other location
   of the signature below it or at it that the callee reads or answers is the written cells (`otherReaches`);
5. a part that `pairedLeaves` reads, which is no location of the argument's own layout, is no single place
   (`suffix_fallback`);
6. a contract that holds a cell of its parameter at two places of its answer (`nonlinear`) is no identity
   (`isIdentity`), and is applied as a call.

Points 2 to 6 come from the review (§8). **Worded rows** (`Check.wordedContract`, kernel §6 rule 10): a
word that puts a parameter's location in the result (`returned`, `stored`, `elementof`, `taken`,
`builderdone`, the elements of `copyof`) matched the location alone; a wide parameter entry now reaches
every result location below it (`holdsAt`). No row of `core/` or of a platform has such a pair today: a
debug build that printed each use of the new branch printed nothing over the 2 752 ownership roots, `core/`
included.

**The safe-build check** (kernel §9): `finish` asks, for each result location with no source but
`twice`, whether the entry of the result value's own layout that holds its cells (the wide entry above it)
holds an atom (`Frame.checkEmpty`). The check counts no units, so a safe build's budget is a release
build's. With the fallback taken out of `leavesSet` (a build not committed), the first fixture panics:
`own3: result location 1 of a contract has no source, and the wide entry 0 above it holds 1 cells`.

**A cost found on the way** (kernel §8). With the fix, `core/Schema`'s `shapeOf` passed its budget:
17.2 million units against the 8.7 million it earns, 1.4 million before. 95 % of it was `freshSrc`, which
asks for each atom of a result that names a cell the frame made whether an escape holds it, by comparing
the atom with every atom of every escape. `shapeOf`'s result now holds the same cells at each of its
hundreds of locations, and each asked again. Escapes only grow, so the answer for the escapes tested is
kept for each cell (root, path, entry), and a later question tests only the escapes made since, at a
lookup's cost and never more than the scan it replaces. `shapeOf` now takes 2.8 million units. The
answers are the ones the scan gives.

## 4. Every place the same mistake was found

The contracts of every declaration of `core/` (the `core` root of `bench/ownership-roots.mjs`) and of
the in-scope platforms, base against the fix. A location was **empty** when it had no source. "After"
gives the new sources of the location that was empty.

| Where | Declarations | Location before | After | Program-visible? |
|---|---|---|---|---|
| `core/Queue` | `takeList`, `takeAll`, `takeN` | `[*]` empty | `outside`, the queue's cells, `π1@0`, `twice` | **yes**: `run/QueueTakeAllElement`, `run/QueueTakeNElement` (TRAP, `ip=DIFF` before) |
| `core/Queue` | `take`, `poll` | no empty location (`#Just.0` is single) | unchanged | no |
| `core/Queue` | `offerAll` | none (its other branch answers its parameter's elements) | `[*]` gains `twice` | no |
| `core/Markdown` | `finish`, `blocksOf`, `closeSegments` | none | locations of the deep level of its recursive blocks gain `twice` (a summary below a wide entry) | no: no verdict of a real root moves |
| `core/Schema` | `describe` | `.definitions[*]…` (26 locations) empty | `outside`, the engine's cells, `twice` | **yes**: `run/SchemaDescribeDefinition` (TRAP before) |
| `core/Schema` | engine: `fieldList`, `variantList`, `ctorList` | every location below `[*]` | `π1@0`, `twice` | through `describe` |
| `core/Schema` | `finish` | `#Err.0[*]…` | `π1@17`, `twice` | through the decoders |
| `core/Schema` | `decode`, `decodeWith`, `encode`, `encodeWith`, `parse`, `parseWith`, `read`, `readWith`, `write`, `writeWith`, `readValid`, `compiledRun`, `compiledParse`, `compiledPrint`, `compiledParseReady`, `compiledPrintReady` | `#Err.0[*].input#Just.0` | `outside`, the engine's cells, `twice` | no write of a `Js.Value` exists; the issue's slots now hold `outside` too, so an update of an issue is refused (§5) |
| `core/Json` | `decode`, `decodeWith`, `decodeValue`, `encodeValue` | `#Err.0[*].input#Just.0` | same | as `Schema` |
| `core/Task`, `Deferred`, `Semaphore`, `Ref`, `Latch` | `join`, `callback`, `wait`, `poll`, `get`, `modify`, … | none: each answers at a type variable, which the caller reads through the map below it | unchanged | no |
| every other module of `core/` (`Dict`, `List`, `String`, `Random/Pcg`, `Url`, `Binary`, …) | all | none | unchanged | no |
| `platforms/node` (`Random`, `Io`, `Http`, `WebSocket`, …), `html`, `browser-inline` | all | none | unchanged (no summary changes) | no |
| out of scope | `platforms/cloudflare` (`WebSocket.attachment`, `Worker.Object.ask`), `browser`, `browser-tea` | `Schema`'s issues | as `Schema` | — |
| a platform function of `a → b` | `Js.to (Js.from x)` read at `List R` | `[*]` | the argument's cells, `twice` | **yes**: `run/HostValueElements` (TRAP before) |
| a generalised local | `got = Js.to (Js.from x)`, read at `List b` | `[*]` | same | **yes**: `run/HostValueElements` |
| one value at two single places | `Js.to (Js.from ( x, x ))` read as a pair | the pair's parts apart | not apart | **yes**: `run/HostValueSplit` (TRAP before) |
| folded payloads (polymorphic recursion) | the corpus's `SanitiserFoldedType`, `SanitiserFamilyRead`, `OneListTwoLevels` | a write below the fold read nothing | read whole | **yes**: each fixture says the write is of a list another holder reads (§5) |

The remaining empty locations of `core/` and of the platforms were read one by one; each is empty by a
rule: a function value that captured nothing (`Random.step = Pcg.step`, `Rt.rows`), another constructor's
argument (`Cmd.none`'s `#Perform.0`, `Http.Server.refuse`'s `#Accept.2`), an answer that never returns
(`Task.forever`), a part a construction does not name (`Schema.describedList`'s other variants).

## 5. Verdicts

`dump --stage=ownership --ownership=v3 --ownership-everywhere` of every ownership root
(`bench/ownership-roots.mjs`, all fixtures), base `0d1d5c21c8` against the fix: 2 752 roots, **10 change
a verdict, 22 lines from accepted to refused, none from refused to accepted.** 52 more roots change only
a contract (a location gains sources or `twice`).

| Root | Lines | Before → after | Judgement |
|---|---:|---|---|
| `run/SanitiserFoldedType` | 5 (+1 new line) | accepted → refused (`later-use`) | **the old acceptance was the fault**: the fixture says "each write here is of a list another holder reads, and is refused"; `y` is `k11`, which `show k11` reads after |
| `run/SanitiserFamilyRead` | 2 | accepted → refused | **the fault**: "each list read here is `k`, and is refused" |
| `ownership/OneListTwoLevels` | 1 (`throughWrap`) | accepted `fresh` → refused | **the fault**: the fixture says v1 and v2 refuse it; `f` writes the level-1 list that is inside the level-2 list |
| `run/SchemaDepth` | 6 | accepted → refused (`unknown`) | the issues' slots came back through a `Js` array, where they escaped; the old acceptance rested on the empty location. The program was refused before (another line) |
| `run/SanitiserRowWider` | 2 | accepted → refused (`disjoint`) | a row's one location read at a record that names `.b`; the program was refused before (61:10) |
| `ownership/PolyRec` (`pushInner`), `PolyRecBranch` (`br3`), `FoldedPreimageCall` | 3 | accepted → refused | precision: the write is below a folded payload, whose one location holds the list and its elements; the program is safe (#2538) |
| `run/SanitiserFamilyCallApart`, `run/SanitiserFamilyJoinBelowApart` | 3 | accepted → refused (`element`) | precision: a summary below a folded payload is `twice`. Both were `SAME` under the four legs and are `REFUSED` now: **the two corpus programs newly refused**, both fixtures written as the safe twins of v2's family tests (#2538) |

**The real-writes ledger** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`, as report
143): of the 308 list writes v1 judges, v3 accepts **294** and refuses 11 (3 with no line) before and
after, line for line. Every v3 demand of the 32 real roots has the same verdict before and after (1 477
demands, 1 370 accepted, 107 refused, as report 145 counts). No real program is newly refused.

## 6. Sweeps

`bench/ownership-sweeps/run.mjs --checker=v3 --mode=both --jobs=24`, the self-hosted ReleaseSafe compiler of the
fix, every program of the 26 generators of the folder (the new `host-values` and the corpus included), its 13
fault folders, the blind round's programs and fault folder (`blindQ-*`) and the review's ten folders
(`review-*`): 88 574 programs.

| Sweep | Programs | SAME | REFUSED | LIMIT | Faults | Other |
|---|---:|---:|---:|---:|---:|---|
| `aliased-arguments` | 5160 | 1216 | 3944 | 0 | 0 | 0 |
| `answers-beside` | 240 | 79 | 161 | 0 | 0 | 0 |
| `answers-sends` | 54 | 19 | 35 | 0 | 0 | 0 |
| `blind10i-faults` | 16 | 7 | 9 | 0 | 0 | 0 |
| `blind10i` | 474 | 151 | 209 | 0 | 0 | 114 PLAINFAIL |
| `blind2-faults` | 20 | 7 | 13 | 0 | 0 | 0 |
| `blind2` | 1202 | 502 | 700 | 0 | 0 | 0 |
| `blind3-faults` | 10 | 3 | 7 | 0 | 0 | 0 |
| `blind3` | 417 | 160 | 257 | 0 | 0 | 0 |
| `blind4a-faults` | 12 | 1 | 11 | 0 | 0 | 0 |
| `blind4a` | 160 | 24 | 136 | 0 | 0 | 0 |
| `blind4b-faults` | 8 | 4 | 3 | 1 | 0 | 0 |
| `blind4b` | 6596 | 1188 | 5406 | 2 | 0 | 0 |
| `blind5c-faults` | 10 | 5 | 5 | 0 | 0 | 0 |
| `blind5c` | 226 | 79 | 145 | 2 | 0 | 0 |
| `blind5d-faults` | 10 | 5 | 5 | 0 | 0 | 0 |
| `blind5d` | 1234 | 450 | 784 | 0 | 0 | 0 |
| `blind6e-faults` | 12 | 4 | 8 | 0 | 0 | 0 |
| `blind6e` | 238 | 91 | 140 | 0 | 0 | 7 PLAINFAIL |
| `blind7f-faults` | 2 | 0 | 0 | 0 | 0 | 2 TIMEOUT |
| `blind7f` | 960 | 396 | 564 | 0 | 0 | 0 |
| `blind8g-faults` | 8 | 4 | 3 | 1 | 0 | 0 |
| `blind8g` | 121 | 21 | 99 | 1 | 0 | 0 |
| `blind9h` | 3213 | 849 | 2364 | 0 | 0 | 0 |
| `blind-faults` | 24 | 11 | 13 | 0 | 0 | 0 |
| `blind` | 9792 | 1675 | 8117 | 0 | 0 | 0 |
| `blindQ-faults` | 6 | 0 | 6 | 0 | 0 | 0 |
| `blindQ-g1` | 204 | 80 | 124 | 0 | 0 | 0 |
| `blindQ-g2` | 86 | 29 | 57 | 0 | 0 | 0 |
| `blindQ-g3` | 86 | 8 | 78 | 0 | 0 | 0 |
| `blindQ-g4` | 44 | 14 | 28 | 0 | 0 | 2 PLAINFAIL |
| `blindQ-g5b` | 700 | 133 | 567 | 0 | 0 | 0 |
| `blindQ-g5` | 600 | 54 | 546 | 0 | 0 | 0 |
| `blindQ-m10` | 17 | 6 | 10 | 0 | 0 | 1 PLAINFAIL |
| `blindQ-m1` | 6 | 0 | 6 | 0 | 0 | 0 |
| `blindQ-m2` | 4 | 0 | 4 | 0 | 0 | 0 |
| `blindQ-m3` | 18 | 3 | 15 | 0 | 0 | 0 |
| `blindQ-m4` | 22 | 6 | 16 | 0 | 0 | 0 |
| `blindQ-m5` | 5 | 0 | 5 | 0 | 0 | 0 |
| `blindQ-m6` | 8 | 0 | 8 | 0 | 0 | 0 |
| `blindQ-m7` | 18 | 18 | 0 | 0 | 0 | 0 |
| `blindQ-m8` | 8 | 0 | 7 | 0 | 0 | 1 PLAINFAIL |
| `blindQ-m9` | 4 | 0 | 4 | 0 | 0 | 0 |
| `bounded-walk-faults` | 12 | 2 | 4 | 2 | 0 | 4 TIMEOUT |
| `bounded-walk` | 34 | 5 | 7 | 4 | 0 | 18 TIMEOUT |
| `callbacks-keep` | 720 | 108 | 612 | 0 | 0 | 0 |
| `corpus` | 1671 | 1192 | 459 | 1 | 0 (3 known TRAP) | 1 TIMEOUT, 3 PLAINFAIL, 12 BOTHFAIL |
| `evaluation-order` | 440 | 276 | 164 | 0 | 0 | 0 |
| `folds-callbacks` | 30300 | 5152 | 25148 | 0 | 0 | 0 |
| `function-values` | 1960 | 304 | 1656 | 0 | 0 | 0 |
| `handed-back` | 2592 | 0 | 2592 | 0 | 0 | 0 |
| `host-values` | 81 | 13 | 68 | 0 | 0 | 0 |
| `records` | 1876 | 353 | 1523 | 0 | 0 | 0 |
| `recursive-levels` | 16131 | 4034 | 12097 | 0 | 0 | 0 |
| `review-g1` | 76 | 24 | 52 | 0 | 0 | 0 |
| `review-g2` | 60 | 17 | 43 | 0 | 0 | 0 |
| `review-g3` | 62 | 25 | 37 | 0 | 0 | 0 |
| `review-g4` | 24 | 0 | 24 | 0 | 0 | 0 |
| `review-g5` | 28 | 5 | 23 | 0 | 0 | 0 |
| `review-g6` | 26 | 0 | 26 | 0 | 0 | 0 |
| `review-g7` | 26 | 1 | 20 | 0 | 0 | 5 BOTHFAIL |
| `review-g7t` | 26 | 6 | 20 | 0 | 0 | 0 |
| `review-g8` | 8 | 2 | 6 | 0 | 0 | 0 |
| `review-g9` | 4 | 0 | 3 | 0 | 0 | 1 BOTHFAIL |
| `runtime-calls-faults` | 8 | 2 | 5 | 1 | 0 | 0 |
| `wider-functions` | 354 | 144 | 210 | 0 | 0 | 0 |
| **total** | **88574** | **18967** | **69418** | **15** | **0** (3 known TRAP) | 25 TIMEOUT, 128 PLAINFAIL, 18 BOTHFAIL |

- **No fault.** The three `TRAP`s are the corpus's known ones, as in reports 144 and 145:
  `run/ListSanitiserTrieHolder` traps as its golden says, and `dom/ShowAndBranches` and
  `tea/ShowAndBranches` are #2504 (`dom` and `browser-tea`, out of scope). The `TIMEOUT`s are `TIMEOUT
  plain` (the DAGs of `bounded-walk`, `blind7f-faults`) and `run/TailModConsMerge` under the sanitiser, as
  before; `PLAINFAIL` and `BOTHFAIL` are the generators' and the fixtures' own.
- **On the base**, the same folders hold the faults this report fixes: `host-values` 22 `TRAP` (every
  `live` twin of `cast.*` but `maybe` and `mapTo`, `twice.*`, `queue.*`, `describe.*`,
  `split.twinT.direct`), `blindQ-faults` 3 `TRAP`, and the round's own results 9 more (`g3` 1, `m1` 4, `m2` 2, `m3` 1,
  `m9` 1: every queue `take*` and every conversion probe), and the review's `g7t` (4) and `g8` (2).
  Each is `REFUSED` on the fix.
- **Precision on the six largest generators** (`folds-callbacks`, `recursive-levels`, `blind4b`, `blind5d`,
  `blind7f`, `blind9h`: 58 434 programs), by `check --ownership=v3 --ownership-everywhere` on the base and on the
  fix: **no program is accepted that the base refused**; 123 that the base accepted are refused, every one a
  `dead` twin (`recursive-levels` 103, `blind4b` 20): a type variable that names its container again
  (`type R = RL (List Int) | RW (G R)` under `G a`), whose deep level is one wide location, so its places are
  no longer apart (§3, #2538).
- **`host-values`** on the fix: 13 `SAME` (all `dead`) and 68 `REFUSED`; 25 `dead` twins are refused, a
  precision cost of reading a converted value whole, where its type cannot say which cells are where.

## 7. Speed

`bench/ownership-v2-review.mjs --checkers=v3 --runs=3 --jobs=1 --roots=real` on ReleaseFast LLVM compilers of
the base and of the fix, three rounds, alternated, the least of each root kept. The machine was shared (load
average 15 to 22).

| Measure | Base | Fix | Change |
|---|---:|---:|---:|
| v3 on the 32 real roots | 1 052.4 ms | 1 219.1 ms | +15.8 % |
| the same without `platforms/browser` | 811.7 ms | 816.6 ms | +0.6 % |
| `platforms/browser` | 240.7 ms | 402.5 ms | +67 % |
| verdicts of the 32 real roots | 1 477 demands, 1 370 accepted, 107 refused | the same, line for line | — |

**The rise is one root, and it is the memo of §3, not the fix.** `Gpu.Engine` passed its budget at
`checkedMaking` on the base. With `freshSrc`'s memo that declaration costs less and passes, so the walk goes
on to `checkedAwaitIn`, ten declarations later, which takes all 10.5 million units it earns. The module
authorises no write either way, and every verdict is the same. On the gates' ReleaseSafe compiler the
`platforms/browser` root takes 3 013.6 ms on the base, 3 722.4 ms on the base with the memo alone, and
3 781.5 ms on the fix (+1.6 % against the base with the memo). Why `checkedAwaitIn` costs its whole budget
is #2539. Every other root moves by less than 2.5 ms; `node`, `cloudflare`, `browser-inline`, `core` and
`todo/server` by 2.2 to 2.4 ms each, the contracts of `Schema` and `Json`, which now hold the cells of
their issues at every location.

`core/Schema`'s `shapeOf` (§3): 1.4 million units on the base, 17.2 million with the fix and no memo (past its
budget of 8.7 million: `Schema` would have published no contract), 2.8 million with the memo.

## 8. The review

One fresh adversarial reader (Opus), given the diff and the kernel, not this report, wrote 340
programs in ten folders and ran each through `run.mjs --mode=both` on the base and the fix.

- **Found, fixed: one value at two single places.** A platform function `twinT x = Js.to (Js.from ( x,
  x ))` has a contract of one location (`res [ π1@0]`). A caller that read its answer as a pair (or a
  record of two fields, or through a generalised local) wrote one part in place and read the other: TRAP
  and `ip=DIFF` on the base **and on the first version of the fix**. The fix's `dup` covered summary
  locations only; the callee's claim covered the two parts, the coarse argument was apart by its own
  layout, and test 2 skipped the written entry's own wide entry. Points 2 to 6 of §3 close each; the
  reader's five programs are `REFUSED`, its twins `SAME`; the shape is `run/HostValueSplit` and the
  generator's `split.*` family. One version of the fix made a conversion whose layout differs from the
  answer's go through the call rule instead of the identity; it moved 38 verdict lines over the
  ownership roots, three of them toward acceptance, and was taken out.
- **Held**: patterns at many depths, rest views, tuples, records and nested records, constructors,
  recursive and non-regular types, `Maybe`, `Result`, `?`, `Dict`, `Ref`, `Deferred`, `Queue`, core list
  functions over a converted list (head, reverse, foldl, map, filterMap, indexedMap, sortWith, concat,
  get, update, set, append, spreads), callbacks, captures, functions cast to function types, answers of
  function parameters, `Js.from` then `Js.to` twice, `List.map` of a conversion, joins, generalised
  locals read at one or two types, top-level values cast at concrete and generic types. Three base faults
  among them (`List.filter` of a cast list of lists, one value twice nested, `Queue.takeAll` of a cast
  queue) are refused on the fix.
- **Real programs**: every example, `bench/corpus` and the four `todomvc` apps print the same verdict
  lines on both binaries.

## 9. Reproduce

```sh
node bench/ownership-sweeps/host-values.mjs <dir>/host-values
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=24 --tmp=<disk> <dir>/host-values
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
zig build test-blackbox -Dcorpus=HostValue      # and QueueTake, SchemaDescribeDefinition
```

The units of a declaration need the measuring line of report 145 §8.
