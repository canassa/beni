# 151 — Ownership v3: casts at type variables, and what a value was made from

*Research report, 2026-11-17. A blind round (T) found three faults of the checker v3 (`--ownership=v3`,
`src/own3/`) with one cause: when a caller fills in `a → b` with two types of the same layout, v3 took the
answer to be the argument itself, while the JavaScript could put the argument one level down, at a part of no
location. This report traces the cause to its root, finds it in ten places, closes the residuals that
research report 150 left in issue #2544, and measures what the fix costs. It revises the kernel's
(`ownership-v3-kernel.md`) §3.4, §6 rules 10 and 11 and §9.*

---

## 1. Result

- **The cause** (§2): **every type variable is one place of the place graph** (`a` and `b`, `List a` and
  `List b`). Each test of v3 that asked "is this value read at its own type?" compared places, so a value
  of one type variable read at another was one type read at itself, and nothing marked it. Three facts
  were missing, and each is now written in the kernel (§3.4, *What a value was made from*):
  1. a type variable is a type, not a place: two places that are one are one type only where the store's
     types are one;
  2. an identity is what the build writes, not what the words say: `returned a → b` is as true of `(a) =>
     [a]` as of `(a) => a`;
  3. a `Js.Value` is what it was made from: `Js.from x` is `x`, and a `Js.Value` the frame made of parts
     (`Js.array [ Js.from x ]`) holds them below its place.
- **The same mistake, in ten places** (§3), all on the base (`dbf151c2de`) too, among them the blind
  round's three faults (F1, F2, F3), both residuals of #2544, and two the review found: a cast that a
  callee hands to a function parameter instead of answering it.
- **Thirteen `run/` fixtures** (§5), each a `TRAP` on the base and refused on the fix.
- **Two safe-build checks** (§6, kernel §9): a row that puts a wide location at a place of another type
  casts (`Check.checkWordedCasts`), and every cell of a `Js.Value` made of parts and read at a type
  variable escaped (`Frame.checkMadeEscaped`). Each panics on the first program of its fault when the fix
  is turned off.
- **Verdicts** (§7): of the 2 809 ownership roots (the 13 fixtures included), **no demand goes from refused
  to accepted**; the 13 fixtures go from accepted to refused, and no other verdict, nor the cause of a
  refusal, moves. **The real-writes ledger is 294 of 308 before and after**, row for row.
- **Sweeps** (§8): every generator of the folder, its fault folders, the corpus, the blind round's programs
  and a new family `casts-at-vars.mjs` (222 programs, 59 faults on the base) under the four legs: **0
  new faults** in 89 156 programs (the corpus's three known ones as before).
- **Speed** (§9): v3 on the 32 real roots +0.5 %.
- **The review** (§10): two passes of one fresh adversarial reader (Opus), 15 faults found, every one on the
  base too; all fixed, with two fixtures.

## 2. The faults and their cause

The blind round's programs need a platform: no shipped `core/` or platform function has the shape.

```beni
-- platform: pub foreign pure wrap : returned a → b      -- JavaScript (a) => [a]
x0 = [ n ]
h : List Int
h = Pun.wrap x0                                           -- [x0]: x0 at an Int element
z : List Int
z = Pun.conv (Maybe.withDefault (List.head h) 0)          -- reads x0 back
x = List.length (List.push x0 9)                          -- accepted: written in place
v = List.length z                                         -- plain 1, in place 2
```

- **F1** (`WordedVarAtList`, `WordedVarSameRecord`): `Check.castsAt` compared the place of the parameter's
  wide location with the place of the result's at the same path. Both are the one place of a type
  variable, so `returned a → b` was no cast; its contract was an identity's (`isIdentity`), the call
  answered `x0`'s own value (`applyAt`), and `narrowed` read `List Int` at `List Int`. The same held for
  `stored a → List b`, and `aliased a → b` had no cast rule at all.
- **F3** (`WordedCastMapped`, `WordedCastGeneric`): the row handed as a function value carried no `casts`
  mark into `argsCast`, for the same reason; and a generic `g q = Pun.wrapPair q` did not cast either,
  since the identity answered `q` as it was.
- **F2** (`JsArrayAtVar`, `JsArrayAtVarOtherModule`): `box x = Js.to (Js.array [ Js.from x ])` is walked
  code. `Js.array` answers a root of `Js.Value` that holds `x`'s cells (`aliased`), and `narrowed`
  exempted a `Js.Value` read at a type variable from `casts` (research report 150: `core/` reads its
  arrays back so). The contract of `box` was then `x`'s location at the answer's, and `escapeWide` read
  the argument at the caller's type, which was its own.

With two types of different layouts the same programs were refused (`hides`), which is why the earlier
sweeps did not see it.

## 3. Where the same mistake was

| # | Where | What read "one place" as "one type" | Fixed by |
|---|---|---|---|
| 1 | `Check.castsAt` (`returned`, `stored`, `builderdone`, `elementof`, `taken`, a function parameter's answer) | a row that puts `a` at `b` | the store's types at the location (`typeAt`, `sameType`) |
| 2 | `Check.wordedContract` (`aliased`) | a row that puts `a` anywhere in `b` | `aliasedCasts` |
| 3 | `Frame.applyAt` (`isIdentity`) | a casting row's call read as the argument itself | `identityCall`: no cast, or the build writes the call as its argument (`Mod.emitsArgument`) |
| 4 | `Frame.call` (the argument of an identity evaluated as a function argument) | the same | `identityCall` |
| 5 | `Frame.narrowed`, a `Js.Value` read at a type variable | a `Js.Value` made of parts | `readAtVar`, `madeOfParts`: its cells escape |
| 6 | `Frame.narrowed`, `own == place` | a value of `a` read at `b` (`Js.to (Js.from v)`, `fm : Maybe a → b`, a deep level's payload) | `varAtVar`, `valIs` |
| 7 | `Frame.narrowed`, a type variable inside the reading | a pair or a `Js.Value` made of parts read at `List b` | the reading's variables are read as one at its root |
| 8 | `Frame.escapeWide` (#2544) | a `Js.Value` inside a construction read by the construction's type (`Maybe Js.Value`), not by what it was made from; and the paths it skips (a cycle's deep level, a `Dict`, a row), an argument of the caller's own type variable, a function value | `partAt` and the opaque branch; #6 makes the skipped paths safe |
| 9 | `Frame.applyAt` (the review) | a walked callee that casts hands the cast value to a function parameter (`feed x g = g (Js.to (Js.from x))`), or answers or hands on a function argument's answer (`ans g = Js.to (Js.from (g ⊤))`, `feedA h g = g (Js.to (Js.from (h ⊤)))`): the cast mark read only the answer as the caller's reading names it | `escapeHandedOff`: its supplies and the answers it answers or hands on escape |
| 10 | `Check.wordedFn` (the review) | a row's function parameter: a cast placement of its answer (`once returned (⊤ → a) → b`), an `aliased` answer, a supply of `a` at the function's `b` (`borrowed a, once returned (b → c) → c`), and a constructor's argument the type test could not read (`returned (T a b) → T a c`) | the answer escapes (`ans_escapes`), the supplied location escapes, `aliasedCasts` for answers, `Mod.ctorArgType` |

Places 6 and 8 are #2544. Its first residual (`λ⊤ → fromMaybeV (Just (wrapV ( x0, x0 )))`) is place 8:
`Just` of `wrapV ( x0, x0 )` has the type `Maybe Js.Value`, and `escapeWide` read the place of that type at
`.Just.0`, a `Js.Value`, which it exempted; the value there is the pair. Its second (`escapeWide` skips a
path no step names, an argument of the caller's own type variable, a function value) was safe only where
every cast of the callee marked it, and a callee that cast `a` to `b` did not (place 6): with that mark,
a callee that does not cast answers at its type variable only values of that variable, and the instance
types say where their cells are. The one skip that still needed a rule is a `Js.Value` below such a path
(`fromTreeV : Tree Js.Value → b`, the second node's payload): an argument the caller made of parts lets its
cells there escape where the reading has a type variable or a part of no location (`escapeWide`'s opaque
branch; the sweep's `residual.treeV`, a `TRAP` on the base).

## 4. The fix

The kernel text is §3.4's new paragraph *What a value was made from* (with the closing sentence of *A
wide parameter answered at a wide result location* and of *A cast hidden behind a type variable*), rule
10's cast rule and rule 11's one exception, and two rows of §9. In code:

- `Check.castsAt` takes the parameter's and the result's types; equal places are one type only where
  `typeAt` (an element, a tuple's index, a record's field by its rank) reaches one store type on both
  sides (`sameType`: one variable, or one structure; anything else is another type). `aliasedCasts`
  marks a row whose `aliased` location meets a type variable of the result of another type.
- `Mod.emitsArgument`: a call of `Js.from` or `Js.to` of the core package, the key of
  `js/JsIntrinsic.zig`, which compiles them to nothing. `Frame.identityCall`: an identity's contract that
  does not cast, or such a call. A casting row is a call, so `escapeHidden`, `argsCast` and
  `escapeUnplacedAnswer` read it.
- `Frame.narrowedAs` / `varAtVar` / `valIs` / `patType`: a value read at its own place, where the place has
  a type variable, is of the reading's type when the walk knows it is (a parameter by its pattern's type —
  the scheme's variables are other variables of the store —, a capture by its local's, a root the frame
  made by its instruction's, each followed by the steps of the path, `Mod.typeAtPath`; a tuple or a
  record built of parts of the right types; a join; or the type of the expression read: a value has the
  type of its expression unless an identity read it at another type, and each identity is judged so where
  it is). Else the frame casts.
- `Frame.readAtVar` / `madeOfParts`: a value of another type read at a type variable casts, as before; a
  `Js.Value` read at one escapes the cells it holds when the frame made it of parts (a call's root, a
  construction, an `unknown`, a function value), and is read as it is when the caller handed it (a
  parameter, a capture). `narrowed` reads a type variable inside the reading as one at its root.
- `Contract.exact`: every answer of a walked body is its parameter 0 itself, whole (`answersParam0`); a
  direct call of such a body is an identity even where the body casts (`conv v = Js.to (Js.from v)` at
  `a → b`), and a function value of it keeps the mark.
- `Frame.escapeHandedOff` (the review): at a call of a walked callee that casts, its supplies to function
  parameters escape, and so does every cell a function argument's answer can hold where the callee
  answers it or hands it on (`escapeAnswer`). Rows: a cast placement of a function parameter's answer
  sets `ans_escapes`, an `aliased` answer has `aliasedCasts`, and a supply of a type variable's or a
  `Js.Value`'s location at a function parameter location of another type sets the location's escape
  flag. `Mod.ctorArgType` reads a constructor's argument written as one of the type's parameters.
- `Frame.escapeWide`: a `Js.Value` at the parameter's location is read as the value it was made from
  (`partAt`: the argument's part, step by step from the place of each part reached, `Loc.stepOf`, which
  checks the type a constructor's argument belongs to); where no step names it, an argument made of parts
  escapes there where the reading can hide it.
- The work each adds is counted (kernel §8): the scans of a layout and the leaves of `madeOfParts`, the
  labels of `partAt`, `Loc.stepOf`'s steps. The type tests read the store, a constant-depth walk of at most
  16 levels, and are not counted, as `Mod.fnType` and `isView` are not.

## 5. Fixtures

Each is a `TRAP` on the base (`--sanitize-lists` traps; plain output in the table) and refused at the named
write on the fix, with a test platform of its own (`platform/`):

| Fixture | Shape | Plain |
|---|---|---|
| `run/CastRowSameLayout` | `returned a → b`, JavaScript `[a]`, read at `List Int` (F1) | `2 1` |
| `run/CastRowSameRecord` | `returned a → b`, `{p: [], q: a}` (with the argument's own property names, which `--release` shortens), read at the argument's record, an update (F1) | `50 1` |
| `run/CastRowAliased` | `aliased a → b`, `[a]`, read at `List Int` | `2 1` |
| `run/CastRowMapped` | the cast row handed to `List.map` (F3) | `2 1` |
| `run/CastRowGeneric` | a generic `g` that calls the cast row, handed to `apply` (F3) | `2 1` |
| `run/JsArrayAtVar` | `Js.to (Js.array [ Js.from x ])` at `a → b`, read at `List Int` (F2) | `2 1` |
| `run/JsObjectAtVar` | `Js.to (Js.object …)` read at the argument's record, an update (F2) | `50 1` |
| `run/JsArrayAtListVar` | `Js.to (Js.array [ Js.from x ])` at `a → List b`, through `apply` | `2 1` |
| `run/JsValueMaybeInThunk` | `λ⊤ → fromMaybeV (Just (wrapV ( x0, x0 )))` (#2544, first residual) | `2 1` |
| `run/CastVarDeepLevel` | `Tree a → b` that casts the second node's payload (#2544, a deep level) | `2 1` |
| `run/CastVarFunctionValue` | `fm : Maybe a → b` handed to `apply` (#2544, a function value) | `2 1` |
| `run/CastHandedToCallback` | `feed x g = g (Js.to (Js.from x))` (the review) | `2 1` |
| `run/CastAnswerHandedOn` | `feedA h g = g (Js.to (Js.from (h ⊤)))` (the review) | `2 1` |

## 6. The safe-build checks

`Check.checkWordedCasts` reads each row's words again and the store's types at each wide location a word
places (`returned` and `builderdone` at the same place, `stored` at that place of the elements, `elementof`
and `taken` an element, `aliased` at any type variable of the result), and panics where they are two types
and the row does not cast. With `castsAt`'s type test turned off (the places alone, the fault), the first
program with `returned a → b` panics (`run/CastRowSameLayout`, and the sweep's `wrap.direct`).

`Frame.checkMadeEscaped` reads the leaves of a `Js.Value` that the frame made of parts and read at a type
variable (`readAtVar`, `narrowed`) and panics where one is held by no escape of the frame. With the escape
turned off, the first program the gates build panics (a module of `core/` reads one so already; then the
sweep's `box.direct`).

Neither counts work: each saves and restores the budgets, as `Frame.checkEmpty` does.

## 7. Verdicts

`dump --stage=ownership --ownership=v3 --ownership-everywhere` of every ownership root
(`bench/ownership-roots.mjs`, all of them), base against fix: 2 809 roots, the 13 fixtures included. 27 roots change their dump and 13 their verdict
lines: the 13 fixtures, each write accepted on the base and refused on the fix. **No line goes from refused
to accepted, and no other verdict or cause moves.**

Fourteen roots change a summary and no verdict: a parameter or a fresh cell escapes that did not, where a
cast is now seen. The `Multipart` body of `browser-tea`'s `Http` requests (so `examples/conduit`,
`writes/Conduit`, `ownership/Conduit` and seven `browser-tea` pages, out of scope), `run/JsonDerivedValues`,
`examples/todo/page`, `platforms/browser` and `tests/platforms/gpu`. `core/`'s contracts are the base's.
`Task.raceOk` (`many aliased List (⊤ → Result e a)`) casts by its words now and changes no summary.

Three versions of the fix refused more and were corrected before the last: (1) a first `escapeWide` that
compared the layouts of the argument and of the reading escaped `Dict`'s values (`Dict.get` of a list
refused `ownership/DictValueWritten`) and ran `Markdown` past its budget: the made-from part is read only
for a `Js.Value`, the rest by the base's rule, which every cast now makes safe; (2) the review's first fix
escaped every supply of a casting callee, rows included: `Ref.update` casts by its words, so a fold whose
callback updates a `Ref` escaped its accumulator (`run/SanitiserFoldAnswerFedKept`,
`run/SanitiserCellStaleLength`, three writes): a row says in its words which hand-off is a cast, and the
escape is for walked callees; (3) `conv v = Js.to (Js.from v)` at `a → b` casts by its types, and a direct
call of it was no identity: 46 safe `build-read` probes and four refusals' causes moved; a body that
answers its parameter itself is an identity (`Contract.exact`), and all moved back.

**The real-writes ledger** (`bench/ownership-v2-review.mjs --checkers=v1,v3 --roots=real`): of the 308 list
writes v1 judges, v3 accepts **294**, refuses 11 and has no line for 3, before and after, row for row. No
safe real program is newly refused.

**The precision cost** is on probes alone: every `dead` twin of the new family is refused with its `live`
twin (a cast that hides the list lets it escape whether or not the program reads it back), and so are the
blind round's `dead` twins. Two `dead` twins of `host-values.mjs` (`cast.mapTo.list`, `cast.mapTo.record`)
are refused: a walked cast `a → b` handed to `List.map` keeps its cast mark (`Contract.exact` is for direct
calls), and the review's contrived row `borrowed a, once (b → c) → c` (JavaScript `f([a])`) is refused with
its dead twin. A row of a type variable whose JavaScript is an honest identity at two types
(`returned a → b` answering `a`) is refused like a lying one where the caller writes the argument: the words
cannot tell them apart.

## 8. Sweeps

`bench/ownership-sweeps/run.mjs --checker=v3 --mode=both --jobs=24` (plain, sanitised, in place, and the release
pair) with the self-hosted ReleaseSafe compiler of the fix: every program of the 30 generators of the folder
(`corpus.mjs`, `build-read` and the new `casts-at-vars.mjs` included), its 13 fault folders, the blind round
T's six fault folders (its `JsArrayAtVarRecord` is in `JsArrayAtVar`) and its families `layers`, `wvar`,
`jswrap`, `combo` and `deepvar`. Faults are `TRAP`, `DIFF`, `IPTRAP`, `IPDIFF`, `RIPTRAP`, `RIPDIFF` and
`CRASH`.

| Sweep | Programs | SAME | REFUSED | LIMIT | Faults | Other |
|---|---:|---:|---:|---:|---:|---|
| `alias-ctors` | 188 | 79 | 109 | 0 | 0 | — |
| `aliased-arguments` | 5160 | 1216 | 3944 | 0 | 0 | — |
| `answers-beside` | 240 | 79 | 161 | 0 | 0 | — |
| `answers-sends` | 54 | 19 | 35 | 0 | 0 | — |
| `blind10i-faults` | 16 | 7 | 9 | 0 | 0 | — |
| `blind10i` | 474 | 151 | 209 | 0 | 0 | 114 PLAINFAIL |
| `blind2-faults` | 20 | 7 | 13 | 0 | 0 | — |
| `blind2` | 1202 | 501 | 701 | 0 | 0 | — |
| `blind3-faults` | 10 | 3 | 7 | 0 | 0 | — |
| `blind3` | 417 | 160 | 257 | 0 | 0 | — |
| `blind4a-faults` | 12 | 1 | 11 | 0 | 0 | — |
| `blind4a` | 160 | 24 | 136 | 0 | 0 | — |
| `blind4b-faults` | 8 | 4 | 3 | 1 | 0 | — |
| `blind4b` | 6596 | 1188 | 5406 | 2 | 0 | — |
| `blind5c-faults` | 10 | 5 | 5 | 0 | 0 | — |
| `blind5c` | 226 | 77 | 147 | 2 | 0 | — |
| `blind5d-faults` | 10 | 5 | 5 | 0 | 0 | — |
| `blind5d` | 1234 | 449 | 785 | 0 | 0 | — |
| `blind6e-faults` | 12 | 4 | 8 | 0 | 0 | — |
| `blind6e` | 238 | 91 | 140 | 0 | 0 | 7 PLAINFAIL |
| `blind7f-faults` | 2 | 0 | 0 | 0 | 0 | 2 TIMEOUT |
| `blind7f` | 960 | 396 | 564 | 0 | 0 | — |
| `blind8g-faults` | 8 | 4 | 3 | 1 | 0 | — |
| `blind8g` | 121 | 21 | 99 | 1 | 0 | — |
| `blind9h` | 3213 | 849 | 2364 | 0 | 0 | — |
| `blind-faults` | 24 | 11 | 13 | 0 | 0 | — |
| `blind` | 9792 | 1675 | 8117 | 0 | 0 | — |
| `bounded-walk-faults` | 12 | 2 | 4 | 2 | 0 | 4 TIMEOUT |
| `bounded-walk` | 34 | 5 | 7 | 4 | 0 | 18 TIMEOUT |
| `build-read` | 1050 | 248 | 802 | 0 | 0 | — |
| `callbacks-keep` | 720 | 108 | 612 | 0 | 0 | — |
| `casts-at-vars` | 222 | 0 | 222 | 0 | 0 | — |
| `combo` | 14 | 1 | 13 | 0 | 0 | — |
| `corpus` | 1727 | 1187 | 520 | 1 | 3 | 12 BOTHFAIL, 3 PLAINFAIL, 1 TIMEOUT |
| `deepvar` | 104 | 44 | 60 | 0 | 0 | — |
| `evaluation-order` | 440 | 276 | 164 | 0 | 0 | — |
| `folds-callbacks` | 30300 | 5152 | 25148 | 0 | 0 | — |
| `function-values` | 1960 | 300 | 1660 | 0 | 0 | — |
| `handed-back` | 2592 | 0 | 2592 | 0 | 0 | — |
| `host-values` | 81 | 2 | 79 | 0 | 0 | — |
| `JsArrayAtVarOtherModule` | 2 | 0 | 2 | 0 | 0 | — |
| `JsArrayAtVar` | 4 | 0 | 4 | 0 | 0 | — |
| `jswrap` | 154 | 0 | 150 | 0 | 0 | 4 PLAINFAIL |
| `layers` | 624 | 2 | 598 | 0 | 0 | 24 PLAINFAIL |
| `records` | 1876 | 353 | 1523 | 0 | 0 | — |
| `recursive-levels` | 16131 | 3869 | 12262 | 0 | 0 | — |
| `runtime-calls-faults` | 8 | 2 | 5 | 1 | 0 | — |
| `wider-functions` | 354 | 144 | 210 | 0 | 0 | — |
| `WordedCastGeneric` | 2 | 0 | 2 | 0 | 0 | — |
| `WordedCastMapped` | 2 | 0 | 2 | 0 | 0 | — |
| `worded-no-location` | 156 | 0 | 156 | 0 | 0 | — |
| `WordedVarAtList` | 2 | 0 | 2 | 0 | 0 | — |
| `WordedVarSameRecord` | 2 | 0 | 2 | 0 | 0 | — |
| `wvar` | 176 | 0 | 144 | 0 | 0 | 32 PLAINFAIL |
| **total** | **89156** | **18721** | **70196** | **15** | **3** | |

- **Faults**: the corpus's three `TRAP`s are the known ones (`run/ListSanitiserTrieHolder`, as its golden
  says; `dom/ShowAndBranches` and `tea/ShowAndBranches`, #2504, out of scope), on the base too. **0 new.**
- **Against the base**: `casts-at-vars` has 59 faults on the base (every `live` twin that the place collapse
  let through: rows, `Js` containers, the residuals; `TRAP` with `ip=DIFF`), refused on the fix with their
  59 `dead` twins; the blind round's six fault folders and its families `layers`, `wvar`, `jswrap` and `combo`
  had 103 faults (its report), all refused. `build-read` (248 `SAME`, 802 `REFUSED`) is the base's, program
  by program; `host-values` refuses two `dead` twins more (§7).
- The review's 112 programs (§10) are not in the table: on the fix, 108 are refused, two plain builds fail
  and two safe probes print the same; on the base, 28 `live` twins trap.

## 9. Speed

`bench/ownership-v2-review.mjs --checkers=v3 --runs=1 --jobs=1 --roots=real` on ReleaseFast LLVM compilers
of the base and of the fix, five rounds alternated, the least of each root kept (load average about 1).

| Measure | Base | Fix | Change |
|---|---:|---:|---:|
| v3 on the 32 real roots | 1 261.2 ms | 1 268.1 ms | +0.5 % |
| the largest rise, `platforms/browser` | 406.6 ms | 409.5 ms | +2.9 ms |

The work the fix adds is counted (kernel §8): `madeOfParts`'s leaves, `partAt`'s labels and steps, the
layouts `narrowed` scans for a type variable, `escapeHandedOff`'s supplies. The type tests read the store
at a depth of at most 16 and are not counted, as `Mod.fnType` and `isView` are not.

## 10. The review

One fresh adversarial reader (Opus), given the diff, both compilers and a test platform, told to find a
cast, a `Js` construction, a worded row or a function value that still hides a list or record cell, by
writing and running programs under the four legs. Two passes, the second on the fix of the first:

- **Pass 1** (68 programs): 12 faults, all `TRAP` on the base too, in two groups. A cast answer of a
  function parameter: a row `once returned (⊤ → a) → b` (JavaScript `(g) => g()`), and walked `ans g =
  Js.to (Js.from (g ⊤))`: `escapeHidden` read the answer only as the caller's reading names it. And a cast
  value handed to a callback's parameter, not answered: walked `feed x g = g (Js.to (Js.from x))` (in
  `Js.pure`, through `apply`, `Maybe.map`, `List.map`, a second function), and rows `borrowed a, once
  returned (b → c) → c`, `once taken returned (b → c)`, `taken returned (b → c)` with JavaScript `f([a])`.
  It also noted that `wordedFn`'s `aliased` answer had no cast test. **Fixed** (§3 rows 9 and 10),
  with a precision correction (§7: the escape of hand-offs is for walked callees).
- **Pass 2** (44 programs on the fix of pass 1): 3 faults, all on the base too: one function argument's
  answer handed to another (`feedA h g = g (Js.to (Js.from (h ⊤)))`, also through `conv` and `apply`):
  the supply was an answer, not a parameter. **Fixed** (`escapeHandedOff` escapes every cell such an
  answer can hold), with `run/CastAnswerHandedOn`. The other 38 programs of the pass were refused:
  values handed in a `Just`, a record, a thunk, by a local function or through `taken`; answers in a
  join, a tuple, a returned closure; rows of a custom type whose constructor wraps an argument
  (`returned (T a b) → T a c`), in declaration order and not; walked reads of a constructor's argument.
- **Precision**: one contrived row newly refused (`borrowed a, once (b → c) → c`, JavaScript `f([a])`,
  dead twin); every other dead twin the fix refuses has a live twin that traps on the base. No safe real
  program newly refused.
- **Not reached**: whether `ctorArgType` picks the right constructor where declaration order and the
  order of names differ. It indexes the declaration's constructors by the ordinal the place graph gives
  them (`Groups.Adapter`: the declaration's order), the same one the labels carry.

On the final compiler, the reader's 112 programs are refused (but two plain-build failures and two safe
probes that print the same).

## 11. What stays open

- **#2540** does not share this cause. It is `slotHeld`'s test of a label path inside a cycle's deep level,
  where the call map pairs two levels; this report's facts are about type variables and `Js.Value`s. Where
  the cast is at a type variable read over a part of no location, the cast now lets every cell of the
  parameter escape (`escapeHidden`), which covers the slot too; where the reading has no such part (a
  recursive record of lists), the slot test is the one #2540 names. It stays open, as its text says, until
  a fixture shows the shape or shows that the cover map rules it out.
- **The one name the kernel reads** (rule 11): `Js.from` and `Js.to` are identities because the build
  writes their calls as the argument (`js/JsIntrinsic.zig`). A word that says "the result is the argument
  itself" would carry the fact in the row, but `Ast.OwnWord` is an `enum(u5)` that is full; the decision is
  parked in #2545.
- **Precision** (#2543 and the dead twins above).

## 12. Reproduce

```sh
node bench/ownership-sweeps/casts-at-vars.mjs <dir>/cav
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --mode=both --jobs=24 --tmp=<disk> <dir>/cav
TMPDIR=<disk> node bench/ownership-v2-review.mjs --beni=zig-out/safe/bin/beni --checkers=v1,v3 --runs=1 --roots=real
zig build test-blackbox-corpus -Dcorpus=CastRow     # and CastVar, JsArrayAt, JsObjectAtVar, JsValueMaybeInThunk
```
