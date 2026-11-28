# 150 — Ownership v3: a location placed nowhere, or over a part of no location

*Research report, 2026-11-16. A blind round (S) found that the checker v3 (`--ownership=v3`, `src/own3/`)
accepted an in-place write of a list that a platform row had answered at a type of no location
(`returned a → Int`), and that a cast read back. This report traces the mistake to its root, finds it at
five more places, fixes each, and measures what the fix costs. It revises the kernel's
(`ownership-v3-kernel.md`) §3.4, §6 rule 10 and §9. Issue #2542; the precision cost is parked in #2543.*

---

## 1. Result

- **The fault** (§2): a contract that put a parameter's cells at "every location of the result", where
  the result had none, put them nowhere: neither answered nor escaped. Then the answer, a value of a type
  of no location, holds `outside` (§3.4), and a cast that reads it back names nobody's cells.
- **The same mistake, in six places** (§3), all on the base (`c3863aeb6c`) too:
  1. a worded row's words (`returned`, `stored`, `aliased`, `elementof`, `taken`, the elements of
     `copyof`, `builderdone`, and a function parameter's answer) at a result of no location;
  2. a call that reads a callee's result at an instance of fewer locations than the contract's
     (`g : a, Int → b` at `Int`, `Maybe b` at `Maybe Int`, `a → List Int × b` at a pair);
  3. a function value whose result locations its holder's answer type does not have
     (`cast : a → b` handed to `apply : (a → Int), a → Int`);
  4. (the review) a cast whose reading has some locations but none at the value's: `Js.to (Js.from ( x,
     x ))` read as `List Int × Int`. Kernel §3.4 said such a location is held "at every entry of the
     reading, and nothing is lost"; the second part, read out as an `Int`, is `outside`;
  5. (the review) a cast behind a type variable: `g : a → b`, `g x = Js.to (Js.from ( x, x ))`, read by
     its caller as a pair, a record with an `Int` field, a `Maybe` of a pair; through a function value, a
     partial application, a lambda, `List.map`, a second module, recursion;
  6. (the review) a row that places a wide parameter where the result has a part of no location below
     it (`returned a → a × Int` whose JavaScript answers `{a: a, b: a}`), and a `Js.Value` read as
     `List Int`, whose elements are a part of no location;
  7. (the review's second and third passes) a type variable answered from inside its argument
     (`Maybe a → b`, `List a → b`, `{ r | v : a } → b`, `a × Int → b`, `List Js.Value → b`) and cast,
     directly, through a function value, and inside a closure that captured the value.
- **The rule** (kernel §3.4, §6 rule 10): **a cell whose place in the reading has no location at or
  above it escapes, and a wide location (a type variable, a `Js.Value`) whose reading has a part of no
  location below it escapes**, wherever a value or a contract is read at another type than its own: at a
  cast (`narrowed`), at a call (`escapeUnplaced`, `escapeHidden`, `escapeWide`), where a function meets
  its holder (`escapeUnplacedAnswer`) and in a worded row (`placedSafely`, `placedAnywhere`). A
  contract that casts at a type variable says so (`Contract.casts`).
- **Eighteen `run/` fixtures** (§5), each a `TRAP` on the base and refused on the fix.
- **A safe-build check** (§6, kernel §9): each location a row's word puts in the result is a source of a
  result location or escapes, and a wide `returned` location is not held over a part of no location.
  With the escape of `returned` turned off, the first program with `returned a → Int` panics.
- **Verdicts** (§7): of the 2 796 ownership roots, **no demand goes from refused to accepted**. 35 roots
  change verdict lines: the 18 fixtures, and 17 roots of casts, folded types and `Basics.eq` handed as a
  value (§7.1), none of them real. **The
  real-writes ledger is 294 of 308 before and after**, and every demand of the 32 real roots has the same
  verdict.
- **Sweeps** (§8): every generator of the folder, its fault folders, the corpus and the new family
  `worded-no-location.mjs` (156 programs, 72 faults on the base) under the four legs: **0 new faults**.
- **Speed** (§9): v3 on the 32 real roots +0.1 %. **The review** (§10): three passes, 29 faults found (all on the base too), all but one fixed; the one left (a `Js.Value` in a container cast inside a closure) is parked in #2544.

## 2. The fault

```beni
-- platform: pub foreign pure stash : returned a → Int     -- JavaScript (a) => a
x0 = [ n ]
h = Pun.stash x0          -- h : Int, the same array
z : List Int
z = Pun.conv h            -- Js.to (Js.from h)
x = List.length (List.push x0 9)    -- accepted fresh: written in place
v = List.length z         -- plain 1, in place 2
```

`Check.wordedContract` put the `returned` location "at the result's location of the same place, or else
at every one of them" (rule 10). `Int` has none, so the source went nowhere, and the flags said only
`read`. The walked twin, `Js.to (Js.from x0)` read at `Int`, escapes by §3.4's `narrowed`; the row had no
such rule. The trigger is a result layout that is empty, or that has no location at the parameter's
place, **after the type is filled in**: `returned a → b` read at `Int` was refused (an identity, which
`narrowed` reads), `returned a → Int` and `returned a → Tok a` (a phantom) were not.

## 3. Where the same mistake was

| # | Where | What went nowhere | Fixed by |
|---|---|---|---|
| 1 | `Check.wordedContract`, `intoElems`, `elemsToElems`, `selfToSelf`, `builderdone`, `elementof`/`taken`, `Record.copy`, `undescribed` | a parameter location a word puts in a result of no location | its escape flag (`placedSafely`, `placedAnywhere`) |
| 1 | `Check.wordedFn` | a function parameter's answer that `returned`, `stored`, `aliased` puts there | `Fn.ans_escapes` |
| 2 | `Frame.applyAt` | a contract result location that no location of the caller's reading is paired with; `if (es.len == 0) return v_outside` dropped every source | `escapeUnplaced` |
| 3 | `Frame.answerOfCode` ("the function's type is wider here than the holder's: no cell is there") | a function's result location its holder's answer does not have | `escapeUnplacedAnswer` in `flowCode` |
| 4 | `Frame.narrowed` (`Loc.all` read as "held at every entry") and the punned identity (`unknownOf` alone) | a value's location with no reading location at or above it | `none` and `Loc.all` both escape; a punned identity narrows too |
| 5 | `Frame.applyAt`, `flowCode` | a wide result location of a callee that cast at a type variable, read with a part of no location below it | `Contract.casts`, `escapeHidden`, `escapeWide` |
| 6 | `Check.wordedContract` (`holdsAt` found a location, so the rest was ignored), `narrowed` (a wide own location covered by a non-wide reading) | a wide location over a part of no location | `placedSafely`, `Loc.holeAt` |
| 7 | `Frame.applyAt`, `flowCode` (`pairedLeaves` took the part a reading names, `answerOfCode` the holder's) | a wide parameter answered from inside its argument at a wide result | `escapeWide` (`hides`), `escapeUnplacedAnswer`, a cast mark for a frame that answers a value of another type at its own type variable |

A `borrowed` parameter of a row with no result word (`List.length : borrowed List a → Int`) is not one:
the word is the positive fact that it is not in the result, and a first version that escaped it refused
every `List.length` (§4). The row's result word `unknown` makes every parameter escape where the result
has no wide root to hold it.

## 4. The fix

The kernel text is §3.4's three paragraphs *A value read at a type with fewer places than its own*, *A
contract's location that the caller's reading does not have* and *A cast hidden behind a type
variable*, and rule 10's last paragraph. In code:

- `Loc.placeAt`, `Loc.holeBelow`, `Loc.holeAt`: the place a location names in another reading, and
  whether a place has a part of no location below it before a wide place (memoised per place; counted).
- `Frame.narrowed`: escapes own locations at `none` or `Loc.all`, and wide own locations whose reading
  is not wide and has a hole below; a reading of a type variable marks `casts` unless the value is a
  `Js.Value` (core keeps values in JavaScript arrays and reads them back at `a`: marking those made the
  whole of `core/List` cast, and refused real writes of `bench/ui` and the `jfb` app).
- `Frame.applyAt`: `escapeUnplaced` (unpaired contract locations), `escapeHidden` (a casting callee, or
  one handed a casting function, whose wide location is read over a hole; it escapes every cell of a
  parameter at its entry, `allSrcs`), `escapeWide` (a wide result location that holds a wide parameter
  location: at the roots the argument is read at the caller's type as `narrowed` reads it; elsewhere the
  argument's own type at the parameter's place is compared with the caller's at the result's, `hides`,
  and a frame that answers a value of another type at its own type variable casts). A punned identity
  narrows too. The identical-layout test (`hides`, `narrowed`) keeps one type read at itself free.
- `Frame.flowCode`: `escapeUnplacedAnswer` (a function result location the holder's answer does not
  have, a casting function's wide location the holder reads at a location that is not wide, and a wide
  parameter answered at a wide location the holder reads so, unless the holder's parameter and answer
  are one layout and the two locations one place; a location placed nowhere whose sources name no cell the holder gives, `holderGivesNone`, is skipped).
- `Check.wordedContract`/`wordedFn`: `placedSafely`, `placedAnywhere`, `castsAt`; `checkWordedPlaced`.
- `bench/ownership-sweeps/run.mjs` decodes the child's output as a stream (`setEncoding('utf8')`): a
  chunk that ended inside a character of several bytes gave two `U+FFFD`, a false `DIFF`.

## 5. Fixtures

Each fails on the base (`--sanitize-lists` traps, the in-place run prints `2 2`) and is refused at the
named push on the fix, with a test platform of its own (`platform/`):

| Fixture | Shape |
|---|---|
| `run/WordedReturnedNoLocation` | `returned a → Int` |
| `run/WordedStoredNoLocation` | `stored a → ⊤` |
| `run/WordedElementNoLocation` | `elementof Int` |
| `run/WordedTakenNoLocation` | `taken Int` |
| `run/WordedCopyNoLocation` | `copyof Int`, an inner list written through `List.update` |
| `run/WordedAnswerNoLocation` | `once returned sync (⊤ → a) → Int` |
| `run/WordedMaybeInstance` | `returned a → Maybe b` read at `Maybe Int` |
| `run/WordedReturnedPair` | `returned a → a × Int`, JavaScript `{a: a, b: a}` |
| `run/GenericAnswerAtInt` | `g : a, Int → b` read at `Int` |
| `run/GenericAnswerInPair` | `g : a → List Int × b` read as `List Int × Int` |
| `run/FunctionAnswerAtInt` | `cast : a → b` handed to `apply : (a → Int), a → Int` |
| `run/MapAnswerAtInt` | `List.map xs cast` read as `List Int` |
| `run/CastPairNoLocation` | `Js.to (Js.from ( x, x ))` read as `List Int × Int` |
| `run/GenericCastInPair` | `g : a → b` that casts a pair, read as `List Int × Int` |
| `run/FunctionCastInPair` | the same `g` handed to `apply : (a → List Int × Int), …` |
| `run/MapCastInPair` | `List.map xs g` read as `List (List Int × Int)` |
| `run/ValueReadAsInts` | a `Js.Value` of a list of lists read as `List Int` |
| `run/GenericCastFromMaybe` | `fm : Maybe a → b` that casts the value inside, read as `List Int × Int` |

## 6. The safe-build check

`Check.checkWordedPlaced` (kernel §9) reads each row's words again, apart from the code that placed
them, and asserts that every location a placing word names is a source of a result location or has the
escape flag, that a placed function answer is a source or `ans_escapes`, and that a wide `returned`
location that does not escape is held by a wide result location at or above it, or at its place where
the result has no hole below. With the line that makes `returned`'s location escape removed, the first
program with `returned a → Int` panics in `want.at`.

## 7. Verdicts

`dump --stage=ownership --ownership=v3 --ownership-everywhere` of every ownership root
(`bench/ownership-roots.mjs`, all of them), base against fix: 2 796 roots (the 18 fixtures included).
171 roots change their dump, 35 their verdict lines; **no line goes from refused to accepted**. The 18
fixtures go from accepted to refused. The other 17:

### 7.1 The cost

| Root | Lines newly refused | Cause |
|---|---:|---|
| `run/SanitiserFamilyBaseApart`, `SanitiserFamilyDepthCallback`, `SanitiserFamilyDepthRun`, `SanitiserFamilyDepthRunApart`, `SanitiserFamilyJoinBelow`, `SanitiserFamilyJoinBelowApart`, `SanitiserFoldedType`, `SanitiserFoldedTypeApart` | 3, 1, 1, 1, 19, 19, 3, 1 | a folded payload of a non-regular type is one wide location; a callee that reads it at `List Int`, whose elements are a part of no location, lets the whole payload escape. `SanitiserFoldedTypeApart` and `SanitiserFamilyDepthRunApart` were accepted whole and are now refused (one line each); the others were refused already on other lines |
| `ownership/core/FullCast`, `CastAcross`, `CastCallHolds` | 4, 3, 2 | a `Js.Value` (or a list of one) read at a concrete type with a part of no location (`exactPair`'s `unpack` at `List Int × Int`, `ints` at `List Int`) |
| `ownership/core/CallTyvarCastJoin`, `CallTyvarCastJoinImported` | 1, 1 | `mix3` casts a list literal to its type variable `a`; its caller reads `a` at a record with a part of no location: a cast, correctly refused |
| `ownership/Words` | 4 | `Schema.print` reads the printed value through `Js.Value` at such types (core's engine), so the list it printed escapes, and the spread after it is refused |
| `run/BasicsEqOwnEq`, `run/DictSetEquality` | 4, 5 (new lines) | `Basics.eq` and `Basics.neq` handed as values, with a type's own `eq` as evidence, now let a parameter escape (`value Basics.eq … keeps its parameter`); each program was accepted whole and is refused. Both are `run/` programs with no `--ownership=v3` golden |
| `browser/tea/BallMachine` (`browser-tea`, out of scope) | 17 | `List.foldl` over a tuple accumulator whose model records the step writes: the fold's wide result read over a record with parts of no location |

None is one of the 32 real roots. Two shapes are ones a real program could have: print a list with
`Schema` and then write it in place (`Words`), and hand `Basics.eq` as a value (`BasicsEqOwnEq`). Both
are named here and in #2543, with the rest of the cost.

**The real-writes ledger** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): of the 308
list writes v1 judges, v3 accepts **294**, refuses 11 and has no line for 3, before and after, and every
row of the 32 real roots has the same demands, accepted and refused, with the same causes.

## 8. Sweeps

`bench/ownership-sweeps/run.mjs --checker=v3 --mode=both --jobs=28` (plain, sanitised, in place, and the
release pair), the self-hosted ReleaseSafe compiler of the base and of the fix, every program of the 28
generators of the folder (`corpus.mjs` and `build-read` included), its 13 fault folders, the blind
round's 34 programs (`blindS-faults`, its 17 pairs) and the new family `worded-no-location.mjs` (`wnl`).
Faults are `TRAP`, `DIFF`, `IPTRAP`, `IPDIFF`, `RIPTRAP` and `RIPDIFF`; "base faults" are the same
programs' faults on the base.

| Sweep | Programs | SAME | REFUSED | LIMIT | Faults | Base faults | Other |
|---|---:|---:|---:|---:|---:|---:|---|
| `alias-ctors` | 188 | 79 | 109 | 0 | 0 | 0 | — |
| `aliased-arguments` | 5160 | 1216 | 3944 | 0 | 0 | 0 | — |
| `answers-beside` | 240 | 79 | 161 | 0 | 0 | 0 | — |
| `answers-sends` | 54 | 19 | 35 | 0 | 0 | 0 | — |
| `blind` | 9792 | 1675 | 8117 | 0 | 0 | 0 | — |
| `blind-faults` | 24 | 11 | 13 | 0 | 0 | 0 | — |
| `blind10i` | 474 | 151 | 209 | 0 | 0 | 0 | 114 PLAINFAIL |
| `blind10i-faults` | 16 | 7 | 9 | 0 | 0 | 0 | — |
| `blind2` | 1202 | 501 | 701 | 0 | 0 | 0 | — |
| `blind2-faults` | 20 | 7 | 13 | 0 | 0 | 0 | — |
| `blind3` | 417 | 160 | 257 | 0 | 0 | 0 | — |
| `blind3-faults` | 10 | 3 | 7 | 0 | 0 | 0 | — |
| `blind4a` | 160 | 24 | 136 | 0 | 0 | 0 | — |
| `blind4a-faults` | 12 | 1 | 11 | 0 | 0 | 0 | — |
| `blind4b` | 6596 | 1188 | 5406 | 2 | 0 | 0 | — |
| `blind4b-faults` | 8 | 4 | 3 | 1 | 0 | 0 | — |
| `blind5c` | 226 | 77 | 147 | 2 | 0 | 0 | — |
| `blind5c-faults` | 10 | 5 | 5 | 0 | 0 | 0 | — |
| `blind5d` | 1234 | 449 | 785 | 0 | 0 | 0 | — |
| `blind5d-faults` | 10 | 5 | 5 | 0 | 0 | 0 | — |
| `blind6e` | 238 | 91 | 140 | 0 | 0 | 0 | 7 PLAINFAIL |
| `blind6e-faults` | 12 | 4 | 8 | 0 | 0 | 0 | — |
| `blind7f` | 960 | 396 | 564 | 0 | 0 | 0 | — |
| `blind7f-faults` | 2 | 0 | 0 | 0 | 0 | 0 | 2 TIMEOUT |
| `blind8g` | 121 | 21 | 99 | 1 | 0 | 0 | — |
| `blind8g-faults` | 8 | 4 | 3 | 1 | 0 | 0 | — |
| `blind9h` | 3213 | 849 | 2364 | 0 | 0 | 0 | — |
| `blindS-faults` | 34 | 0 | 34 | 0 | 0 | 17 | — |
| `bounded-walk` | 34 | 5 | 7 | 4 | 0 | 0 | 18 TIMEOUT |
| `bounded-walk-faults` | 12 | 2 | 4 | 2 | 0 | 0 | 4 TIMEOUT |
| `build-read` | 1050 | 248 | 802 | 0 | 0 | 0 | — |
| `callbacks-keep` | 720 | 108 | 612 | 0 | 0 | 0 | — |
| `corpus` | 1709 | 1187 | 502 | 1 | 3 | 14 | 12 BOTHFAIL, 1 TIMEOUT, 3 PLAINFAIL |
| `evaluation-order` | 440 | 276 | 164 | 0 | 0 | 0 | — |
| `folds-callbacks` | 30300 | 5152 | 25148 | 0 | 0 | 0 | — |
| `function-values` | 1960 | 300 | 1660 | 0 | 0 | 0 | — |
| `handed-back` | 2592 | 0 | 2592 | 0 | 0 | 0 | — |
| `host-values` | 81 | 4 | 77 | 0 | 0 | 0 | — |
| `records` | 1876 | 353 | 1523 | 0 | 0 | 0 | — |
| `recursive-levels` | 16131 | 3869 | 12262 | 0 | 0 | 0 | — |
| `runtime-calls-faults` | 8 | 2 | 5 | 1 | 0 | 0 | — |
| `wider-functions` | 354 | 144 | 210 | 0 | 0 | 0 | — |
| `wnl` | 156 | 0 | 156 | 0 | 0 | 72 | — |
| **total** | **87864** | **18676** | **69009** | **15** | **3** | **103** | 124 PLAINFAIL, 25 TIMEOUT, 12 BOTHFAIL |

- **Faults**: the corpus's three `TRAP`s are the known ones (`run/ListSanitiserTrieHolder`, as its golden
  says; `dom/ShowAndBranches` and `tea/ShowAndBranches`, #2504, out of scope), on the base too. **0 new.**
- **Against the base, program by program**: none goes from `REFUSED` to `SAME`. 100 base faults are
  refused (`TRAP`/`DIFF` → `REFUSED`: `wnl` 72, `blindS-faults` 17, the corpus's 11 new fixtures run
  as programs). 273 go from `SAME` to `REFUSED`: 271 `dead` twins or safe programs — `recursive-levels`
  165 (folded payloads read over a part of no location), `wnl` 73, `blindS-faults` 17, `host-values` 9, `function-values` 2, `blind2` 1, and the corpus's 4 of §7.1 — and 2 `live` twins
  the base printed right by chance (`wnl`'s `inst.maybeRow.live`, whose JavaScript `Maybe` reads the
  array as `Nothing`; `blind5d`'s one).

## 9. Speed

`bench/ownership-v2-review.mjs --checkers=v3 --runs=1 --jobs=1 --roots=real` on ReleaseFast LLVM compilers
of the base and of the fix, seven rounds alternated, the least of each root kept (load average about 1).

| Measure | Base | Fix | Change |
|---|---:|---:|---:|
| v3 on the 32 real roots | 1 256.5 ms | 1 257.6 ms | +0.1 % |
| the largest rise, `bench/todomvc/apps/beni/Sandbox.beni` | 19.5 ms | 20.3 ms | +0.8 ms |

The work the fix adds is counted (kernel §8): the scans of a call map in `escapeUnplaced`,
`escapeHidden`, `escapeWide` and `escapeUnplacedAnswer`, and the place graph walks of `Loc.holeBelow`
(kept for each place) and `Loc.placeAt`.

## 10. The review

One fresh adversarial reader (Opus), given the diff, the compilers and a test platform, told to find a
word or a placement that still loses a parameter by writing and running programs. Three passes, each on
the fix of the one before:

- **Pass 1** (34 programs): 17 faults on the first fix, all on the base too: a reading with some
  locations that hides a cell at a part of no location (§3 rows 4 and 5: `Js.to (Js.from ( x, x ))` read
  as `List Int × Int`, a generic `a → b` that casts, through a function value, `List.map`, a partial
  application, a lambda, recursion, a second module), and rows that place a wide parameter over such a
  part (row 6). **Fixed** (the second commit).
- **Pass 2** (14 programs): 8 faults, a type variable answered from inside its argument (`Maybe a → b`,
  `List a → b`, `{ r | v : a } → b`, `a × Int → b`, and `Js.Value` in such containers), and 2 of their
  carriers. **Fixed** (the third commit), but for `lambdaMaybeV`, a `Js.Value` in a `Maybe` cast inside
  a closure: **answered**, a residual (§11, #2544).
- **Pass 3** (14 programs): 4 faults, the same cast of a captured value inside a closure, without
  `Js.Value`. **Fixed** (the fourth commit).
- **Precision**: one safe program newly refused, an honest `returned a → a × Int` row (`safeHonP`):
  **answered**, the words cannot tell it from a row whose JavaScript answers the parameter twice (§11).
  No program was accepted by the fix and refused by the base.

On the final compiler, of the 62 programs, 55 are refused, the six safe probes are accepted with the
plain output, and `lambdaMaybeV` traps, as on the base.

## 11. What stays open

- **Soundness residuals** (#2544), each accepted on the base too: a `Js.Value` inside a container cast at
  a type variable inside a frame whose own result is that variable (the review's `lambdaMaybeV`:
  `λ⊤ → fromMaybeV (Just (wrapV ( x0, x0 )))` read as a pair). Marking a `Js.Value` read at a type
  variable as a cast closes it, and makes every function of `core/List` cast: `bench/ui` and the `jfb`
  app then lose real writes, which the owner's rule forbids. And `escapeWide` skips a path no place step
  names (a deep level of a cycle, a row, the inside of a `Dict`), an argument of the caller's own type
  variable, and a function value. The fact that would close both is a cast fact for each result location,
  or the shape a `Js.Value` was made from.
- **Precision** (#2543): a wide value whose shape the writer knows (`core/Schema`'s engine, a folded
  payload) escapes where it is read over a part of no location; `Basics.eq` handed as a value with a
  type's own `eq`; an honest `returned a → a × Int` row (JavaScript `{a: a, b: 0}`) is refused like a
  lying one (the review's `safeHonP`): the words cannot tell them apart.

## 12. Reproduce

```sh
node bench/ownership-sweeps/worded-no-location.mjs <dir>/wnl
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=24 --tmp=<disk> <dir>/wnl
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
zig build test-blackbox-corpus -Dcorpus=NoLocation     # and Instance, AnswerAtInt, AnswerInPair, CastInPair, CastPair, ReturnedPair, ValueReadAsInts
```
