# 82 — The first external port: ohanhi/bike-wars, raw, under the ownership checker

*2026-10-12. This note reports what `beni dump --stage=ownership` says about the first application of
thesis §12.4's external corpus: an Elm program written by someone else, ported to beni and frozen
before any repair. The application is Ossi Hanhinen's Bike Wars (<https://github.com/ohanhi/bike-wars>,
commit `ed263780`, Elm 0.19.0, BSD-3-Clause). It is a two-player light-cycle game of 1 413 lines of Elm in
11 modules, and the port adds the parts of three packages it uses. The port is
`examples/bike-wars` (`PORTING.md` lists every change beni forced). The frozen raw port is commit
`51739633e`, and every count below is taken on it. The checker is master's at `7405633c2`, through slice
3d (research 80). Every figure is **[measured]** with the commands in §6. The probes of §4 are
hypothetical edits made in a scratch copy, and none of them is applied.*

---

## 0. The answer

1. **82 demand lines: 51 accepted, 0 pending, 31 rejected.** The figures are the same on `browser-tea`
   and `browser-direct`, line for line. The direct row has no `platform` line to add, because no
   entry line is accepted. The idiomatic error rate of this one application is therefore **31/82 =
   38 %**, against the thesis's criterion of under 2 %. **The application is not accepted.**
2. **By kind.**
   - 11 exact: `later-use` 6, `alias` 4, `disjoint` 1.
   - 19 approximate: `element` 5, `call` 5, `exclusive` 5, `escaped` 4.
   - 1 position: `top-level` 1.
3. **Seven root causes explain all 31** (§3). Each has its own line count:

   | Root cause | Lines | Kind |
   |---|---|---|
   | R1, the checker's reading of a suffix rebuild | 9 | a checker limit |
   | R2, `current.trail ++ other.trail` in `Bike.shoot` | 4 | correct |
   | R3, the cons onto `omitLastSections current.trail` | 4 | correct |
   | R4, the cons onto `List.map explosions …` | 4 | a checker limit, O2's identity promise read type-blind |
   | R5, `Maybe.map (handleInput model _) ▷ Maybe.withDefault model` | 4 | reported exact, a path-sensitivity limit in substance |
   | R6, the game stepping both bikes from the previous state | 2 | correct, intended sharing |
   | R7, the entry | 4 | a stack of `escaped` (Change 5), then `top-level` (Change 4, the top-level model), then `exclusive` (approximate) |

4. **Classification.**
   - **Correct rejections:** 10, from R2, R3 and R6. Each is real sharing that an in-place compile would
     get wrong.
   - **Limits of the checker:** 17. R1 and R4 are 13 lines. R5 is 4 more: it is reported as exact, but
     it is a limit.
   - **Cleared by a change already decided or required:** the 4 entry lines of R7. They need Change 5
     (required) for `String.join`, and the port must apply Change 4 (decided) to `initModel`. Behind
     both stands an `exclusive` rejection that §4 could not yet place.
5. **What a repair would need.** §4 makes seven edits in a scratch copy. Four of them put a fresh value
   where the base of a construction, `++` or call was shared; one is a `case`; two make `init`,
   `initModel` and `initBikes` functions of `⊤`. Together they clear 25 of the 31 rejections and still
   leave 6.
   - **2 are correct.** The simultaneous step needs one `List.copy` of a trail.
   - **4 are the entry's `exclusive` (approximate).** No program edit reached them.

   The repaired port is the separate step that thesis §12.4 counts; nothing is repaired here.
6. **The headline for the external corpus is not one checker defect.** Elm's `x :: xs` never touches
   `xs`, but its mechanical port `[ x, …xs ]` makes `xs` the base the construction consumes (Change 1).
   An Elm `xs ++ ys` likewise makes `xs` the base. Three of the seven root causes (R2–R4, 12 lines)
   are such a translation. In each case the program reads the base again, or the base is a call result
   that may be shared. Two of the three are what the thesis means by a correct rejection. They cost an
   Elm programmer nothing in Elm.

## 1. The port, and what was measured

`examples/bike-wars/PORTING.md` is the full account. In short:

- Each module is the Elm module with the same declarations, names, model, messages and logic.
- `linear-algebra`'s `Math.Vector2`, the used part of `ohanhi/keyboard` and `elm/core`'s two `Tuple`
  functions are ported with their licences.
- The changes beni forced are listed by kind:
  - saturated calls and `_`;
  - named arguments in place of `>>`;
  - subject-first core with pipe-first `▷`;
  - `[ x, …xs ]` for `::`;
  - Unicode notation and `init ⊤`;
  - parenthesised negative arguments;
  - renames where Elm shadowed an import or the prelude's `e`;
  - markup with SVG's names.
- The port builds and plays on **`browser-tea` only**. `browser-direct` refuses markup held as a value
  (every `view` helper returning `Html`, its slice S4) and `Tea.document` (its slice S5). The checker,
  however, evaluates any program under the direct row (`ownership-checker.md` §20.2), so both rows are
  reported.

`tests/corpus/browser/tea/BikeWars` plays a game on the page driver's virtual frames, in development and
release, and with the page fuzzer. The case uses 3 786 million instructions when Node runs, which is 88 %
of the 4 300 million budget; with its run hashes
recorded, so that Node is skipped, the builds of 1 515 lines of beni alone use 2 372 million. It shows these behaviours:

- red steers with `a`;
- a shifted `A` turns nothing;
- green steers with the arrows;
- both fire;
- red rides into its own blast and green wins;
- the game keeps stepping while the blast burns, green reaches the border, and the win becomes a draw;
- the space bar starts a new game.

The draw, and the trail lagging the bike by a frame, are the original's behaviour, kept.

**The red player's controls work.** The brief said red could not steer. That is wrong: it came from
this report's author misreading `ohanhi/keyboard`. `Keyboard.Arrows.arrowKey` reads `w`, `a`, `s` and
`d` as `Character`s, so `a`, `d` and `w` reach red. Only the case is kept, so a shifted key does
nothing, and the test shows it.

## 2. Every rejection

Lines are `module line:col`, in the frozen commit's formatting. *Kind* is the dump's (`ownership-checker.md`
§8.3). *Verdict* is this report's hand classification: correct, a checker limit, or cleared by a change.

| # | Line | Cause | Kind | Root | Verdict |
|---|---|---|---|---|---|
| 1 | Bike 56:28 construction `<omitLastSections …>` | alias | exact | R3 | correct: `omitLastSections` may return its argument (the `other → other` arm), and `current.trail` is read at 76 |
| 2 | Bike 56:29 call `omitLastSections current.trail` | later-use | exact | R3 | correct: `[ List.drop first 2, …rest ]` writes the trail it is handed (its base `rest` is a view of it) |
| 3 | Bike 56:62 `++ <construction>` | alias | exact | R3 | correct, as 1 |
| 4 | Bike 59:9 call `collision walls[*]` | top-level | position | R1 | limit: `collision` "writes" its walls' sections only through R1, and `Constants.gameBounds` is among them |
| 5 | Bike 60:33 construction `<List.map …>` | call | approx | R4 | limit: an `Explosion → Obstacle` map can never return its input |
| 6 | Bike 76:13 call `breakIfNecessary current.trail[*]` | exclusive | approx | R1 | limit |
| 7 | Bike 78:13 call `breakIfNecessary <swapPosition …>[*]` | exclusive | approx | R1 | limit |
| 8 | Bike 78:48 call `swapPosition current.trail` | exclusive | approx | R3 | the trail's exclusivity is lost to the `walls` construction of R3 (it goes with R3's fix) |
| 9 | Bike 91:33 call `Weapon.shoot <++>[*]` | disjoint | exact | R1 | exact against R1's write, which is itself a limit |
| 10 | Bike 91:69 `++ current.trail` | later-use | exact | R2 | correct: the append's base is `current.trail`, read at 92 |
| 11–14 | Game 127:30 call `handleInput` ×4 (`red`/`green` `.trail`, `.trail[*]`) | later-use | exact | R5 | limit in substance: `Maybe.withDefault model` reads `model` only when `Maybe.map` did not call `handleInput` |
| 15 | Game 136:39 call `Bike.shoot <record>.current.trail` | alias | exact | R2 | correct: red's `shoot` would append in place onto `red.trail`, which green's `shoot` reads |
| 16 | Game 136:39 `….current.trail[*]` | element | approx | R1 | limit |
| 17 | Game 136:39 `….other.trail[*]` | element | approx | R1 | limit |
| 18 | Game 137:43 `….other.trail[*]` | element | approx | R1 | limit |
| 19 | Game 142:35 call `Bike.turn redUpdated.trail` | exclusive | approx | R2 | `shoot`'s `++` loses the trail's exclusivity (goes with R2's fix) |
| 20 | Game 142:69 call `Bike.turn greenUpdated.trail` | exclusive | approx | R2 | as 19 |
| 21 | Game 159:11 call `Bike.update <record>.current.trail` | alias | exact | R6 | **correct, intended**: the first update would rewrite red's trail in place, and the second reads it as `other` |
| 22 | Game 159:11 `….current.trail[*]` | element | approx | R6 | correct in substance: `swapPosition` really writes red's first section, which the second update reads |
| 23 | Game 159:11 `….other.trail[*]` | element | approx | R1 | limit |
| 24 | Game 159:11 call `Bike.update explosions` | call | approx | R4 | limit |
| 25 | Game 160:11 `….other.trail[*]` | call | approx | R1 | limit |
| 26 | Game 160:11 call `Bike.update explosions` | call | approx | R4 | limit |
| 27–30 | Main 12:5 `entry Game.update` red/green `.trail`, `.trail[*]` | escaped | approx | R7 | Change 5; then Change 4's top-level model; then `exclusive` (approximate) |
| 31 | Main 12:5 `entry Game.update model.explosions` | call | approx | R4 | the write is R4's; "`Game.initModel` is a top-level value" |

**Totals.**

| Cause | Lines | Root causes |
|---|---|---|
| `later-use` | 6 | 1 R3, 1 R2, 4 R5 |
| `alias` | 4 | 2 R3, 1 R2, 1 R6 |
| `disjoint` | 1 | R1 |
| `element` | 5 | 4 R1, 1 R6 |
| `call` | 5 | 4 R4, 1 R1 |
| `exclusive` | 5 | 2 R1, 1 R3, 2 R2 |
| `escaped` | 4 | R7 |
| `top-level` | 1 | R1 |

By root cause: R1 9, R2 4, R3 4, R4 4, R5 4, R6 2, R7 4, total 31.

**Thesis counts.**

- Top-level models (§12.5's own line): 4. These are R7's second layer, masked by `escaped`.
- Kept copies: 0. Once-closure rejections: 0.
- Prepend warnings: 2 (`prepend_in_loop`, `linesToTrail`'s `foldr` and `trailToLines`' `recurse`). They
  are warnings and count nowhere.

## 3. The root causes

**R1: a suffix rebuild is read as a write (9 lines; a checker limit).** `Helpers.trailToLines` walks each
section with the Elm idiom `a :: b :: tail -> recurse … (b :: tail)`. The port writes it
`[ a, b, …tail ] → recurse … [ b, …tail ]`. §3.2 exempts a rebuild of exactly the shape a pattern
matched, but `[ b, …tail ]` is only a suffix of it. The pass therefore reads it as a construction that
consumes `tail`, which is a view of the section, and so as a write of the section:

- `trailToLines` writes `π1[*]`;
- through it `collision`, `Weapon.shoot` and `Bike.update` write every trail's sections;
- every caller that still reads a trail is rejected.

Under value semantics `[ b, …tail ]` is the view that starts at `b`, and writing `b` before `tail` writes
what is already there. A probe confirms the reading: `f l = case l of [ a, b, …tail ] → [ b, …tail ]`
gives `5:18 construction tail: accepted param` and `summary f: π1 RAW`, while `[ a, …rest ] → rest`
gives `π1 RA`. Extending §3.2's exemption to a suffix of the matched items would clear all 9. Without
that, the program must be rewritten to `[ a, …rest ] → case rest of [ b, …_ ] → recurse … rest`.

**R2: `current.trail ++ other.trail` (4 lines; correct).** An Elm `++` copies. beni's makes its left
operand the base (Change 1), and `Bike.shoot` returns `{ current | weapon = … }`, which still holds that
trail. Its callers read it as well: green's `shoot` takes `red` as `other`. An in-place append would make
red's trail grow by green's sections. A fresh base clears it (`[ …[], …current.trail, …other.trail ]`,
as `Sub.both` writes it), and so does a `List.copy`.

**R3: `[ frontWall other, …omitLastSections current.trail ] ++ …` (4 lines; correct).** This is the port of
`frontWall other :: omitLastSections current.trail ++ …`. The base is `omitLastSections current.trail`.
That function writes the trail it is handed, because `[ List.drop first 2, …rest ]` is a construction on
the view `rest`, and it may return its argument. `Bike.update` reads `current.trail` again at line 76.
The repair copies the trail first.

**R4: `[ toObstacle other, …List.map explosions Explosion.toObstacle ]` (4 lines; a checker limit).** The
base is `map`'s result. Under O2's identity promise (decided), `map` may return its input when every
result is the element it was given. A map from `Explosion` to `Obstacle` can never do so, but the
summary is read without the types. The write then reaches `explosions`, which `stepGame` passes to both
updates, and the model's `explosions` at the entry. Writing the obstacles as
`[ toObstacle other ] ++ List.map …` clears all 4. A type-aware reading of the `kept` row would clear
them without an edit.

**R5: `maybeKey ▷ Maybe.map (handleInput model _) ▷ Maybe.withDefault model` (4 lines).** The dump says
`later-use`, which is exact, but nothing is read after the edit. `Maybe.withDefault` returns its default
only when the `Maybe` is `Nothing`, which is exactly when `handleInput` did not run. The checker cannot
see that through two library calls. Writing it as a `case` clears it. This is the thesis's "avoidable"
class, and a case for a path-sensitive join over `Maybe`'s two functions.

**R6: both bikes step from the previous state (2 lines; correct, intended).** `stepGame` calls
`Bike.update` for red and then for green, each with the other bike as `other`. The first call rewrites
red's trail (`swapPosition` replaces its head point) and the second reads it. Elm's semantics give green
the old red. An in-place compile would give green the new red, a different game. This is a version kept
on purpose, the thesis's intended sharing, and the repair is one `List.copy`.

**R7: the entry (4 lines; three layers).** `entry Game.update` is rejected at the model's two trails, at
`trail` and `trail[*]`. The layers are found by removing each one in turn (§4):

1. **`escaped`.** `Bike.view` draws each section with `String.join (List.map section …) " "`. `map` may
   return the section itself, and `String.join` hands its list to a `Js.pure` lambda that §18.6 takes to
   keep it. The section therefore escapes from `view`, which is `E` on `trail[*]` in `view`'s summary
   (`J` before the callback). This is research 79's `String.join` again, and Change 5's words on
   `String.join` (and on `List.copy`, which is over `Js` too) are what clear it. No program edit short
   of avoiding `String.join` does.
2. **`top-level`.** `Game.init`, `initModel` and `initBikes` are top-level values, and `handleInput`'s
   `{ initModel | status = Running }` returns that shared model. This is the "top-level model" case of
   Change 4 (decided): the port made `init` a function as `PORTING.md` says, and left `initModel` as
   written, exactly as §12.8 says a port does.
3. **`exclusive` (approximate).** With both layers removed, the entry needs the trails' elements not to
   share, and the checker cannot show that. Removing the `walls` construction or the trail-breaking
   calls in a further probe did not clear it, so its origin is not placed here. It is left to the
   repair step, which must find it before claiming the application is accepted.

## 4. The probe chain (not applied)

These edits were made in a scratch copy, one at a time and cumulatively, to place each root cause.
Each step is dumped under `browser-direct`. They are evidence for §3, not a repair; the repaired port
will be counted separately.

| Step | Edit | Rejected after |
|---|---|---|
| 0 | the frozen raw port | 31 |
| 1 | R1: `trailToLines`' `recurse` matches `[ a, …rest ]` and recurses on `rest` | 22 |
| 2 | R2: `Weapon.shoot current [ …[], …current.trail, …other.trail ]` | 18 |
| 3 | R3: `omitLastSections (List.copy current.trail)` | 14 |
| 4 | R4: `([ toObstacle other ] ++ List.map explosions Explosion.toObstacle)` | 10 |
| 5 | R5: `case maybeKey of Just key → handleInput model key; Nothing → model` | 6 |
| 6 | R7.1: the polyline's points by `List.foldl` instead of `String.join` (not a faithful repair: it only shows the layer) | 6 (the entry now says `top-level`) |
| 7 | R7.2: `initBikes ⊤`, `initModel ⊤` and `init ⊤` | 6 (the entry now says `exclusive`) |

What remains after step 7 is R6's 2 lines and R7.3's 4. The repair effort the thesis counts (§12.5:
iterations, lines changed outside the reported function, `List.copy` calls) belongs to the repaired port.
Steps 1–5 change about 10 lines and add one `List.copy`; step 6 is not a repair a programmer could
reasonably make.

## 5. What this says for the evaluation

- **The rate.** One application, 82 sites. The decision needs at least 500 sites from at least ten
  applications (§12.8), so this is a first point, not a verdict. Still, 38 % is far from 2 %, and the
  causes are not exotic.
- **The `::` and `++` translation.** It turns every Elm cons and append into a demand on what used to
  be the tail. Where the tail is read again (R2, R3) the rejection is correct, and the Elm programmer's
  code was right. The repair is a fresh base or a `List.copy`, a cost the thesis's people study (§12.7)
  should measure.
- **Two checker extensions are cheap and named by this program.** A suffix rebuild as an alias (R1) is
  §3.2's exemption widened. A `map` across types never returning its input (R4) is the `kept` row read
  with the types. Together they clear 13 of 31.
- **R5** is the path-sensitive join of §12.8 item 4 in its smallest form.
- **The entry.** It is Change 5 (`String.join`), the top-level model Change 4 predicts, and an
  `exclusive` the repair step must place.

## 6. Commands

```sh
git checkout 51739633e                       # the frozen raw port
zig build                                    # the beni of master at 7405633c2
cd examples/bike-wars
../../zig-out/bin/beni dump --stage=ownership --platform=browser-tea src
../../zig-out/bin/beni dump --stage=ownership --platform=browser-direct src
../../zig-out/bin/beni build --platform=browser-direct src   # refused: markup as a value (S4), Tea.document (S5)
zig build test-blackbox -Dcorpus=BikeWars    # the game, played (3 786 M instructions with Node)
```

The two dumps are byte-identical.
