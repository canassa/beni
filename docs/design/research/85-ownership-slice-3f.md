# 85 — The ownership checker's slice 3f: a prepend copies, `map` across records, the default read

*2026-10-12. What `beni dump --stage=ownership` says once a prepend is no demand (`ownership-checker.md` §25.2,
on the owner's decision that `[ x, …xs ]` copies), `map`'s identity promise is read with the record types
(§25.3), and `Maybe.withDefault (Maybe.map m f) d` is walked as the two arms it means (§25.4). The programs are
research 82's frozen raw Bike Wars port (commit `51739633e`, unchanged on master), Conduit, the four TodoMVC
programs, the table app and research 81's corpus sweep. The baseline is master at `c9ccb53c2` (slice 3e and the
precise `Http` failure, PR #76); the branch is that plus this slice. Every figure is **[measured]** with §7's
commands; there are no timings here.*

---

## 0. The answer

1. **Bike Wars: 31 of 82 demand lines rejected (38 %) → 6 of 19 (32 %).** 25 rejections are gone, 2 changed
   cause, 4 stand. The denominator fell too: 63 lines were demands only because a prepend was one, and most of
   them were acceptances at `[*]` paths that existed only because a callee "wrote" a list by prepending onto it.
   Against research 82's 82 sites, 6 rejections are 7 %; the thesis's measure is rejected over demanded, so the
   rate of record is **6/19**. The program is still not accepted (§3).
2. **The remaining six**: 2 correct (R2, `current.trail ++ other.trail`), 2 by the position rule (R7, the
   top-level `initModel`, which Change 4's port fix clears), and 2 approximate (§25.7 item 1: an append onto a
   prepend's result, which may be its base only through a re-cons that a fresh item can never trigger).
3. **Rule 1, a prepend copies**, clears 23 lines — R1 9 of 9, R4 4 of 4, R3 3 of 4, R2 2 of 4, R5 2 of 4, R7 2
   of 4, R6 1 of 2 — and turns R3's and R6's last lines from exact to approximate: each was a write a prepend made
   in place on its base, or a requirement that write imposed. **Rule 3, the default on the other path**, turns
   R5's two list-level lines into `accepted once` (their two `[*]` lines vanish with rule 1). **Rule 2, records**,
   changes no Bike Wars line: R4's construction was a prepend, which rule 1 already clears. Rule 2 was a real
   defect nonetheless (§1.2) and `MapAcrossTypes` pins it.
4. **The backend copies on every prepend shape** (§2): `[ x, …xs ]`, `List.cons`, several items, a
   tail-modulo-cons result, a loop's accumulator, a fold callback, a suffix re-built in a scalar-view walk, and an
   exact re-cons. None writes an array that existed before it. No correctness finding.
5. **No acceptance became a rejection**, in any program measured, on any platform (§4). Every rejection that
   changed either disappeared (its demand no longer exists), became `accepted once` (R5), or moved from exact to
   approximate (two Bike Wars lines, §3).
6. **Conduit: 29 lines, 5 rejected → 26, 4.** A `payload` rejection at the entry goes, with the write it guarded
   (`ArticlePage`'s `[ comment, …comments ]`). TodoMVC and the table app do not move. The corpus TEA targets on
   `browser-direct`: 321 lines, 42 rejected → 282, 36 (`platform` 12 → 8, `call` 4 → 2); on the first platform
   736, 195 → 459, 169. Every line that changed is a line that went (§4).

## 1. The three rules

### 1.1 A prepend copies (§25.2)

Change 1 made `[ x, …acc ]` consume `acc`. The owner's decision of 2026-10-11 took the room in front of a list
away: `cons` builds a new array every time (`backend.md` §4). A copy cannot make an old version observable, so
the prepend reads its base and writes nothing. The rule is positional, as Change 1's is: a construction whose
items all come before its one spread, and `List.cons`. Anything after the first spread still appends onto the
base, so `[ x, …xs, y ]` stays a demand (`Prepend.between`, rejected `later-use`).

*Soundness.* The result is a new cell and **the base's cells, approximately**, because the runtime re-conses: onto
a view `(b, o)` whose element `b[o − 1]` is the item put in front, `cons` answers `(b, o − 1)` or `b` itself
(`core/List.beni`, `cons`). The suffix re-built in R1, `[ b, …tail ]` after `[ a, b, …tail ]`, is exactly that
case: it answers a view of the scrutinee's array. So writing the result in place while the base is read later is
still rejected (`Prepend.grownAfter`), as `call`, because the text does not show when the re-cons happens. The
result's elements are the base's, exactly; the new cell's contents are exclusive when the items are, are apart
from the base's elements, and the base's contents are. `List.cons`'s asserted row says the same.

### 1.2 `map` across records (§25.3)

The brief asked whether research 82's R4 was a type that really may share, or the rule not applied. **The rule
was applied, and answered wrongly.** §16.4 item 6's type filter drops an approximate entry at the result's `ε`
whose argument's type the result's type cannot be; it is in `instRes` and in `applySummary`'s tail. But it asks
§6.1's "may be one object", and that answered *yes* for any two record types. `Explosion` (`center`, `size`,
`ticksLeft`) and `Obstacle` (`n`, `e`, `s`, `w`) are closed records with different fields, which never share an
object. Two closed records now share only when they name the same fields, each pair of which may share; an open
row still may be any record, and a one-field nominal type still may be its field (the release representation).

What it changes: `MapAcrossTypes.obstacles` (an append onto `List.map explosions toObstacle` with `explosions`
read afterwards) goes from `call` to accepted; a map from a record type to itself, and from a one-field wrapper to
its field, stay rejected. In core, `Schema.describe`'s and `shapeOf`'s summaries lose `π₁.node#NRecord.0` and
`π₁.node#NTagged.1` at `.root#RecordOf.0` and `.root#TaggedOf.1`: `List.map (fieldList fs) λf → { name, key,
optional, shape }` maps the engine's field records to `FieldShape`s, different records. No line's verdict in any
program measured moves with it.

### 1.3 The default read on the other path (§25.4)

R5 is `maybeKey ▷ Maybe.map (handleInput model _) ▷ Maybe.withDefault model`. `model` is read at `withDefault`'s
call, after `Maybe.map` called `handleInput`, which edits it: `later-use`. But `withDefault` answers `model` only
when `Maybe.map` answered `Nothing`, which is when it did not call `handleInput`. The narrowest sound rule: when
`m` and `d` are variable paths and `f` a lambda (the `_` placeholder lowers to one) or a top-level value, the
`Maybe.map` call is arm `Just` of a `case` of its own, and `d`'s use arm `Nothing`. The restrictions keep anything
but the call of `f` and the read of `d` out of the arms: `MaybeDefault` rejects an eager handler, a default that
is an expression, an edit while computing `m`, `Maybe.andThen`, and a read of the old model after the whole
expression — each `later-use`, as on master. `readAfter`'s line now names the real later read (54:30) where master
named the default (53:12).

## 2. The backend: every prepend shape copies

Built with `--library --platform=browser-direct` (the platform slice 5 will write in place on) from a probe of
ten shapes; the emitted JavaScript, function by function:

| Shape | Emitted | Writes its base? |
|---|---|---|
| `[ x, …xs ]`, `List.cons x xs` | `List$cons(x, xs)` | no: `pushFrom` onto a new `[ x ]`, or one `concat` into a new array, or a re-cons header (`core/List.beni`, `cons`) |
| `[ a, b, …xs ]` | `List$cons(a, List$cons(b, xs))` | no |
| `[ x, …go rest ys ]` (tail modulo cons, base case `ys`) | a loop that `push`es onto its own `$root`, then `List$close($root, ys)` | no: `close` copies `ys`'s elements after `$root`, or answers `ys` itself when `$root` is empty |
| `[ x + 1, …go rest ]` (base case `[]`) | the same loop, returning `$root` | no |
| `go rest [ x, …acc ]` (accumulator) | `acc = List$cons(x, acc)` in the loop | no |
| `List.foldl xs [] λx acc → [ x, …acc ]` | `List$cons(x, acc)` in the callback | no |
| `[ a, b, …tail ] → [ b, …tail ]` | `List$cons(b, List$view(list, 2))` | no: a re-cons answers a view of `list`'s array |
| the same in a scalar-view loop | `list = tail - 1` | no: an offset |
| `[ h, …t ] → [ h, …t ]` | `List$cons(h, List$view(list, 1))` | no: answers `list` |

The re-cons answers alias the base, which §25.2 item 2 models. `close` answering `ys` is why `Recursion.appendTo`'s
summary keeps `res π₂`. Slice 5 must keep every row of this table a copy (§25.2); `emit/PrependShapes` pins them, so a change shows as a golden diff.

## 3. Bike Wars, line by line

Research 82's 31 rejections, by its numbering:

| # | Line | Was | Now | By |
|---|---|---|---|---|
| 1 | Bike 56:28 construction `<omitLastSections …>` | alias (R3) | — | rule 1: a prepend |
| 2 | Bike 56:29 call `omitLastSections current.trail` | later-use (R3) | — | rule 1: `[ List.drop first 2, …rest ]` writes nothing |
| 3 | Bike 56:62 `++ <construction>` | alias (R3) | **call (approx)** | the `++`'s base is the prepend's result, which may be `omitLastSections`' result only by a re-cons |
| 4 | Bike 59:9 `collision walls[*]` | top-level (R1) | — | rule 1: `trailToLines` writes nothing |
| 5 | Bike 60:33 construction `<List.map …>` | call (R4) | — | rule 1 |
| 6, 7 | Bike 76:13, 78:13 `breakIfNecessary …[*]` | exclusive (R1) | — | rule 1 |
| 8 | Bike 78:48 `swapPosition current.trail` | exclusive (R3) | — | rule 1: `[ [ point, …tail ], …rest ]` writes nothing |
| 9 | Bike 91:33 `Weapon.shoot <++>[*]` | disjoint (R1) | — | rule 1 |
| 10 | Bike 91:69 `++ current.trail` | later-use (R2) | later-use | correct |
| 11, 13 | Game 127:30 `handleInput model.….trail` | later-use (R5) | **accepted once** | rule 3 |
| 12, 14 | Game 127:30 `….trail[*]` | later-use (R5) | — | rule 1 |
| 15 | Game 136:39 `Bike.shoot <record>.current.trail` | alias (R2) | alias | correct |
| 16–18 | Game 136:39, 137:43 `…trail[*]` | element (R1) | — | rule 1 |
| 19, 20 | Game 142:35, 142:69 `Bike.turn ….trail` | exclusive (R2) | — | rule 1: `cons` and `swapPosition` write nothing |
| 21 | Game 159:11 `Bike.update <record>.current.trail` | alias (R6) | **call (approx)** | `Bike.update` writes the trail only through line 3's append |
| 22, 23 | Game 159:11 `…trail[*]` | element (R6, R1) | — | rule 1 |
| 24, 26 | Game 159:11, 160:11 `Bike.update explosions` | call (R4) | — | rule 1 |
| 25 | Game 160:11 `….other.trail[*]` | call (R1) | — | rule 1 |
| 27, 29 | Main 12:5 entry `….trail` | top-level (R7) | top-level | position |
| 28, 30 | Main 12:5 entry `….trail[*]` | top-level (R7) | — | rule 1 |
| 31 | Main 12:5 entry `model.explosions` | call (R4) | — | rule 1 |

R6 deserves a sentence: research 82 called it correct and intended, since `swapPosition` rewrote red's first
section in place and green's step read it. Under the decided semantics `swapPosition` copies, so an in-place
compile gives green the old red as Elm does, and the sharing is gone; what remains of line 21 is line 3's
approximation.

**What is left**, 6 of 19:

| Line | Cause | Verdict | What clears it |
|---|---|---|---|
| Bike 91:69 `++ current.trail` | later-use | correct (R2) | a fresh base, or `List.copy` |
| Game 136:39 `Bike.shoot <record>.current.trail` | alias | correct (R2) | the same edit |
| Bike 56:62 `++ <construction>` | call | limit | §25.7 item 1, or writing `[ frontWall other ] ++ omitLastSections current.trail ++ …` |
| Game 159:11 `Bike.update <record>.current.trail` | call | limit | the same |
| Main 12:5 entry `model.bikes.green.trail`, `….red.trail` | top-level | position | Change 4: `initModel ⊤` (research 82 §4 step 7) |

Classified as research 82 did: **2 correct, 2 limits, 2 position**. The 13 accepted lines: 2 `fresh`, 3 `call`,
6 `param`, 2 `once`.

## 4. Every verdict change

**Applications** (both platforms give the same lines for each):

| Program | Lines | Accepted | Rejected | Change |
|---|---|---|---|---|
| Bike Wars | 82 → 19 | 51 → 13 | 31 → 6 | §3 |
| Conduit | 29 → 26 | 24 → 22 | 5 → 4 | `ArticlePage` 141:76 construction `comments` (accepted) and `Main` 234:47 `ArticlePage.update article.comments…` (accepted) go: a prepend; with them `Main` 254:5's `payload` rejection on `model#Article.0.comments#Loaded.0.1`. The other four `payload` lines stand (O6) |
| TodoMVC, four programs | 2 each | unchanged | unchanged | — |
| table app | 5 | unchanged | unchanged | — |
| core | 123 → 117 | 123 → 117 | 0 | six acceptances go: `Task` 2402:12 and 2410:41 (`raceAll`'s prepend onto `rest`, and the call that supplied it), and `Url.Parser` 289:13 ×2, 298:21, 298:66 (`addParam`'s `[ value, …Maybe.withDefault … ]` under `Dict.update`, and its fold) |

**The corpus**, research 81's sweep re-run on both binaries (§7):

| Row | Master | Branch |
|---|---|---|
| first platform | 736 lines: 537 accepted, 4 pending, 195 rejected (`platform` 75, `top-level` 57, `call` 17, `later-use` 15, `payload` 9, `need` 6, `alias` 4, `unknown` 3, `supply` 3, `disjoint` 3, `escaped` 2, `exclusive` 1) | 459: 289, 1, 169 (`platform` 68, `top-level` 55, `call` 9, `later-use` 9, `alias` 1, the rest unchanged) |
| TEA targets, browser-direct | 321: 278, 1, 42 (`platform` 12, `payload` 9, `need` 6, `call` 4, `top-level` 4, `unknown` 3, `escaped` 2, `disjoint` 1, `supply` 1) | 282: 245, 1, 36 (`platform` 8, `call` 2, the rest unchanged) |

**No line changed verdict and no line appeared**: 281 acceptances, 3 `pending` lines and 32 rejections went,
each because its demand is no longer one (a prepend, or a callee that wrote only by prepending). The 32
rejections, both rows:

- `browser/dom/Blocks`, `Events`, `Keyed`, `SvgDrawing` (both rows each), `browser/direct/DuplicateKeys`, `Keyed`,
  `KeyedOriginal` (browser-tea): the entry's `platform` line on a model list `update` prepends onto — 11.
- `browser/dom/KeyedEnds`, `browser/direct/KeyedEnds` (both rows each): `[ x, …List.drop … ]`, `call` — 4.
- `run/ListPrepend`: 11 (`later-use` 5, `alias` 3, `call` 2, `top-level` 1), every one a prepend onto a version read
  afterwards — the fixture prints that the old versions survive, which is now what the checker says too.
- `run/ListPersistence` 3 (`call`), `run/ListPrependDeep` 1 (`call`), `run/ListSpreadPatterns` 1 (`later-use`),
  `run/ListForms` 1 (`top-level`, a prepend onto a top-level list).

The three `pending` lines that went: `browser/ControlledInput`'s `update` (`tests/platforms/page`),
`run/ConstrainedFunctionConstantRoutes`' prepend onto `clampAll`'s result, and `check/good/PrependInLoop`'s
returned accumulator (54:70) — the fixture of the `prepend_in_loop` warning, whose 17 lines all go.

**The ownership fixtures** move as their goldens show: `Differential` (T33's prepend accepted, `t33Pushed`
added; `t57`'s spine no longer written, so its `[*]` lines go), `Recursion` (`appendTo` reads `ys`: the call line
goes and `t12`'s push is rejected `call` instead of `alias`), `Split` (`bumpHead` writes `π₁[*]` only: `repeated`'s
`exclusive` moves from the list's line to its `[*]` line, and two acceptances go).

## 5. Against the Lean model

The model (`proofs/ownership/`) has no prepend, no list pattern and no `Maybe` (its `Prim`s are `set`, `push`,
`copy`, the builder and `close`), so no Table 6.2 program runs any of the three rules there. T33 is the one program
the rules touch that both run: the model runs it projected onto a push (`Fixtures.lean`, `retained`), kept version
rejected and copied accepted. `Differential.t33Pushed` is that projection, and the branch gives the model's
verdicts. T33 as the thesis writes it, a prepend, is now accepted with no `List.copy`: thesis Change 1
(*Recorded decisions it touches*) said it needs one at the version it keeps, because a prepend consumed its
base; the owner's decision that a prepend copies is why it does not. As
before, the model was not run here (no Lean toolchain in the environment); the comparison is with its fixtures'
recorded verdicts.

## 6. Open questions

1. **A prepend of fresh items** (§25.7 item 1): Bike Wars' two approximate lines. A re-cons needs the item put in
   front to be the element before the view; an item made after the base cannot be. The domain has no "made
   after".
2. **`Maybe.andThen`, `Result.map` with `withDefault`, a `case` on `Maybe.map`'s result**: the same argument as
   §25.4, not built until a program needs it.
3. **The repaired port.** Research 82 §4's probe chain is now mostly unnecessary: steps 1, 3, 4 and 5 are
   cleared by the checker, and R6's `List.copy` is not needed. The repair thesis §12.5 counts is two edits (R2's
   fresh base, Change 4's `initModel ⊤`) and, unless §25.7 item 1 is built, one rewrite of line 56.

## 7. How to reproduce

```sh
zig build test-blackbox-corpus -Dcorpus=ownership   # builds zig-out/safe/bin/beni
B=./zig-out/safe/bin/beni
$B dump --stage=ownership --platform=browser-tea examples/bike-wars/src     # and browser-direct
$B dump --stage=ownership --platform=browser-direct examples/conduit/src    # and browser-tea
$B dump --stage=ownership --platform=browser-direct bench/ui/apps/beni
$B dump --stage=ownership --platform=browser-direct bench/todomvc/apps/beni/Sandbox.beni   # and the other three
$B dump --stage=ownership core
$B build --library --no-source-maps --platform=browser-direct --out=out Prepends.beni      # §2's probe
```

The corpus sweep: every project directory under `tests/corpus` (one holding an `_expected.*` file) and every
`.beni` file outside one, dumped under the first platform it checks with — none, `node`, `tests/platforms/page`,
`browser-tea`, `browser-direct`, `browser`, `html` — and, when that is `browser-tea`, again under
`browser-direct`; master's binary and the branch's over the branch's tree, the `ownership/` fixtures counted by
their goldens instead. Lines are matched by unit, row, module, position, operation and base.
