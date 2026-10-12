# Bike Wars in beni: what the port changed

Bike Wars is Ossi Hanhinen's two-player light-cycle game,
<https://github.com/ohanhi/bike-wars>. This directory ports it from commit
`ed263780fb6262d652e70f72a937477aaa0f55f3` (2019-01-13, Elm 0.19.0), under its
BSD-3-Clause licence (`LICENSE`). Each Elm module is a beni module of the same
name, with the same declarations in the same order, the same names, model,
messages and logic. The only changes are the ones beni's syntax, semantics or
platform force, and every kind of change is listed below. Nothing was rewritten
to be more idiomatic, simplified or dropped.

**The raw port is frozen.** The commit that adds this file is the raw port, and
the ownership counts in `docs/design/research/82-external-port-bike-wars.md` are
taken on it. It was written without regard to the ownership rule: every list
operation is written the way the Elm program writes it. Any later repair is a
separate commit and is counted separately.

It builds for `browser-tea`: `beni build` in this directory, or
`tests/corpus/browser/tea/BikeWars`, which plays a game on the page driver's
virtual frames. It does not build for `browser-direct` yet. That platform
refuses markup held as a value (every `view` helper that returns `Html`, its
slice S4) and `Tea.document` (its slice S5).

## Packages ported

Only the parts the game uses. Each file names its origin and licence, and the
licence texts are in `licenses/`.

| Package | Version | Ported | Where |
|---|---|---|---|
| `elm-explorations/linear-algebra` | 1.0.3 | `Math.Vector2`: `Vec2`, `vec2`, `getX`, `getY`, `setX`, `setY`, `toRecord`, `add` | `src/Math/Vector2.beni` |
| `ohanhi/keyboard` | 1.0.0 | `Keyboard`: `RawKey`, `KeyParser`, `rawValue`, `downs`, `oneOf`, `whitespaceKey`, and `Key` with every constructor; `Keyboard.Arrows`: `arrowKey` | `src/Keyboard.beni`, `src/Keyboard/Arrows.beni` |
| `elm/core` | 1.0.0 | `Tuple.mapFirst`, `Tuple.mapSecond` | `src/Tuple.beni` |

- **`Vec2`.** linear-algebra's kernel stores a vector as a two-element
  `Float64Array`. Here it is `Vec2 Float Float`. Both hold the same doubles, and
  `==` compares them component by component, as Elm's `==` does for the array.
- **`Keyboard.downs`.** The package decodes the event with
  `Json.field "key" Json.string`. The port reads the same field with
  `Browser.Events.onKeyDown` and `Html.key`.
- **`Tuple`.** beni's core has no `Tuple` module; a tuple's parts are `t.0` and
  `t.1` (`language.md` §0). The two functions `Trail` calls are ported as
  written, so the call sites keep `Tuple.mapSecond`.

These capabilities come from beni's platform, not from a port:

- `Browser.Events.onAnimationFrameDelta` (`boundary.md` §9.8.18);
- `Browser.Events.onKeyDown` and `Html.key` (§9.8.10);
- `Tea.document` (§9.8.1);
- the SVG vocabulary (§9.9).

## Every kind of change

1. **No module headers.**
   - `module M exposing (…)` is gone: a module is named by its path, and
     exactly the names the Elm module exposed are `pub`.
   - `import M exposing (..)` and `T(..)` do not exist in beni (§5.2). Each
     such import lists the names the module uses, with constructors by name.
   - Imports of `Svg`, `Svg.Attributes` and `Html.Attributes` become
     `import Html exposing (Html)`.
   - Imports that were unused in Elm (`Browser` in `Game`, `getX`/`getY` in
     `Weapon`, …) are kept.
2. **n-ary functions, saturated calls.**
   - Annotations are written `A, B → C`.
   - A curried annotation that returns a function its definition consumes is
     written with every parameter: `Keyboard.oneOf : List KeyParser, RawKey →
     Maybe Key`, whose Elm type was `List KeyParser -> KeyParser`.
   - Partial application becomes a `_` placeholder:
     - `tryObstacleCollision points _`, `horizontalOrthogonal points _`,
       `cutWith explosion _`, `handleInput model _`, `setX e _`, `setY s _`;
     - `keyParser = Keyboard.oneOf [ … ] _`.
3. **No `>>` / `<<` (§6.5): the argument is named instead.**
   - Point-free definitions get their argument:
     - `turnLeft dir = turnRight (turnRight (turnRight dir))`;
     - `Explosion.view`, `Explosion.update` and `linesToTrail`.
   - Composed function arguments become lambdas:
     - `List.reverse << recurse []` in `trailToLines`;
     - the polyline builder in `Bike.view`;
     - `keyParser >> KeyDown`;
     - `.ticksLeft >> (/=) 0`, which is `λexplosion → 0 ≠ explosion.ticksLeft`.
4. **Subject-first core and pipe-first `▷` (§6.7).**
   - Core's functions take their subject first: `List.map list f`,
     `List.foldr list acc f`, `List.filterMap list f`, `List.drop list n`,
     `String.join list sep`, `Maybe.map m f`, `Maybe.withDefault m d`.
     A pipeline into a core function keeps its `▷`.
   - A pipeline into a function whose subject is its last parameter becomes a
     nested call, because `▷` would put the subject first. This applies to the
     author's own functions and to `List.append`:
     - `Trail.breakIfNecessary explosions (swapPosition current.position
       current.trail)`;
     - `cons bike.position (swapPosition bike.position bike.trail)`;
     - `breakTrail`'s and `breakIfNecessary`'s own pipelines;
     - `tryCollision (horizontalOrthogonal points _) (lines ▷ …)`;
     - `List.append (List.filterMap … identity) explosions`.
   - The author's parameter orders are kept.
5. **Lists use brackets and `…` (§6.8).**
   - `x :: xs` and `x :: rest ->` become `[ x, …xs ]` and `[ x, …rest ] →`.
   - `_ :: []` becomes `[ _ ]`, and `(head :: tail) :: rest` becomes
     `[ [ head, …tail ], …rest ]`.
   - `frontWall other :: omitLastSections current.trail ++ …` becomes
     `[ frontWall other, …omitLastSections current.trail ] ++ …`.
6. **Unicode notation (§12.7–§12.10).**
   - The operators: `→`, `≠`, `≤`, `≥`, `▷`, `…`.
   - Tuple types are written `Vec2 × Vec2`.
   - `\x ->` becomes `λx →`.
   - Main's `\_ -> init` becomes `λ⊤ → init`: `init` is a function of `⊤` on
     every platform (§9.8.16).
7. **Blocks instead of `let … in` (§12.2).** Doc comments become `--|`, and
   `breakLines`' elm-verify-examples text is kept verbatim in its doc comment.
   `beni fmt` lays out the result, as the gate requires.
8. **Negative arguments are parenthesised.** Elm 0.19 reads `vec2 0 -c` and
   `makeOverlay "Red wins!" -50` as negation. beni reads `f -1` as `f - 1`
   (§6.5), so these become `vec2 0 (-c)` and `makeOverlay "Red wins!" (-50)`.
9. **No shadowing of the prelude or of an import (§7).** Elm lets a local
   binding shadow an imported name. beni does not:
   - `Basics.e` is in the prelude, so the record patterns `{ n, e, s, w }`
     (`Helpers.tryObstacleCollision`) and `{ n, w, s, e }`
     (`Trail.horizontalPairs`, `verticalPairs`) become
     `({ n, s, w } as obstacle)` / `({ n, w, s } as bounds)`, and `e` is read
     as `obstacle.e` / `bounds.e`;
   - `Bike.bikeForm`'s parameter `bikeSize`, which shadowed the imported
     `Constants.bikeSize`, is `bikeSize_`.
10. **Markup instead of `Svg` / `Html` calls (§11, §9.9).**
    - `rect [ width w, … ] []` is `<rect width={w} … />`, attribute by
      attribute in the author's order.
    - elm/svg's attribute functions are SVG's own attribute names:

      | elm/svg | beni |
      |---|---|
      | `strokeWidth` | `stroke-width` |
      | `strokeLinecap` | `stroke-linecap` |
      | `fontSize` | `font-size` |
      | `fontFamily` | `font-family` |
      | `viewBox`, `points`, `transform`, `d`, `x`, `y`, `width`, `height`, `fill`, `stroke` | unchanged |
      | `Svg.Attributes.style` | `style` |

    - `text_` is `<text>`, `Svg.path` is `<path>`, and `Svg.text s` is
      `{Html.text s}`, or literal markup text when `s` is a literal.
    - `Html.Attributes.style "p" v` is one entry of a style list
      (`style={[ ( "p", v ) ]}`, §11.19). The three on the game's `<svg>` are
      one list.
    - A child list `(svgView model)` is a `{svgView model}` hole.
11. **Platform names.**
    - `Browser.document` is `Tea.document`, and `main : Tea.Program`.
    - The `Document`'s `body` is one `Html msg`, so `body = [ view model ]` is
      `body = view model`.
    - `Browser.Events.onAnimationFrameDelta` keeps its name.
    - `Cmd` and `Sub` are imported (`Cmd exposing (Cmd)`, `Sub exposing (Sub)`).
    - `modBy 10 ticksLeft` is `Int.mod ticksLeft 10` (§12.4).

## What differs on the page

- **Number formatting.** beni's `String.fromFloat` writes a whole float with
  its point (`20.0`), where Elm writes `20` (`core/String.beni`). Every
  coordinate the game writes into an SVG attribute therefore reads `20.0`
  (`points="20.0,120.0 …"`, `viewBox="0.0 0.0 400.0 300.0"`). SVG parses both
  as the same number, so the drawing and the game do not change.
- **Release builds.** `Helpers.toLine` calls `Debug.log` for a diagonal line.
  As `elm make --optimize` refuses it, `beni build --release` refuses it
  (`debug_in_release`).

## Behaviour the port keeps

These are the original's own behaviours, and the corpus test shows each:

- **Steering keys are case-sensitive.** Red steers with `a`, `d` and `w`.
  `Keyboard.Arrows.arrowKey` reads them as `Character "a"` and so on, keeping
  the key's case, so a shifted `A` turns nothing.
- **A win can become a draw.** After a crash the game goes on stepping while
  an explosion burns. The surviving bike keeps riding, so it can crash too,
  and the status recomputed each frame turns `GameWon` into `Draw`.
- **The trail lags the bike by a frame.** `Bike.update` writes the bike's
  previous position into its trail, so the polyline ends a frame behind the
  bike.

## Not ported

- **The test suites** under `tests/` (`HelpersSpec`, `BikePhysicsSpec`, and
  the elm-verify-examples config). They need elm-explorations/test's fuzzers.
- **The page shell** (`index.html`, `watch.sh`, `package.json`), which
  `Tea.document` replaces.
- **The README's GIF and `img/bike.svg`**, which the game never loads.
