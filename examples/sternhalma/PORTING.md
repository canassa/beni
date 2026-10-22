# Sternhalma in beni: what the port changed

> Test policy, 2026-10-22: per-test instruction limits, grants and reference CPU
> requirements were removed (#740). Each test or corpus case now has a
> 120-second wall-clock hang guard. Older counts and budget references below
> describe historical evidence, not a current gate or an outstanding grant.
> Performance remains the job of `test-perf` and `bench`.


Sternhalma is Lucas's (rvcas) Chinese Checkers for two, three, four or six
players, <https://github.com/rvcas/sternhalma>. This directory ports it from
commit `ffb3f91bd1b2be28015f4c69beaadbb5763bb0f4` (2025-12-18, Elm 0.19.1),
under its BSD-3-Clause licence (`LICENSE`, copied unchanged; the original's
`package.json` says `"license": "MIT"`, but the repository's licence file is
BSD-3-Clause and that is the one kept). Each Elm module — `Hex`, `Board`,
`Move`, `Main` — is a beni module of the same name, with the same
declarations in the same order, the same names, model, messages and logic.
The only changes are the ones beni's syntax, semantics or platform force, and
every kind of change is listed below. Nothing was rewritten to be more
idiomatic, simplified or dropped. The program uses no package beyond
`elm/core`, `elm/html`, `elm/browser` and `elm/json`, so nothing else is
ported.

**The raw port is frozen.** The commit that adds this file is the raw port,
and the ownership counts in
`docs/design/research/88-external-port-sternhalma.md` are taken on it. It was
written without regard to the ownership rule: every list operation is written
the way the Elm program writes it. Any later repair is a separate commit and
is counted separately.

It builds and plays for `browser-tea`: `beni build` in this directory writes
`out/`, whose `index.html` is this directory's page shell (below). It does not
build for `browser-direct` yet, which refuses `Tea.document` (its slice S5)
and markup held as a value — every `view` helper that returns `Html`, such as
`viewPlayerSelect` and `viewPlayerButton` (its slice S4).

## `Array` is `List`

beni has no `Array`: `List` is the one sequence type, array-backed, with
Elm's `Array` operations on it (`language.md` §6.8, *`core/List`*). The board's
`cells` and the game's `players` are therefore `List Cell` and `List Player`,
and each operation maps to the `List` function of the same meaning:

| Elm | beni | Meaning kept |
|---|---|---|
| `Array Cell`, `Array Player` | `List Cell`, `List Player` | |
| `Array.fromList xs` | `xs` | the list is already the array |
| `xs \|> Array.toList \|> …` | `xs ▷ …` | the step is dropped |
| `Array.get i a` | `List.get a i` | `Nothing` out of range, as Elm's |
| `Array.set i v a` | `List.set a i v` | out of range, the list unchanged, as Elm's |

The two imports `import Array exposing (Array)` (in `Board` and `Main`) go
with it. The costs differ in one place: Elm's `Array.set` copies a path of
its tree, and beni's `List.set` copies a list of up to 256 elements whole, so
each `Board.setOccupant` copies the 121 cells. `get` is O(1) in both.

## The drag events

The game is played by drag and drop. Elm's `Html.Events` has no drag events,
and the program writes them with `Events.on "dragstart"` and
`Events.preventDefaultOn "dragover"`, each over a `Json.Decode.succeed`.
beni has neither a general `on` nor a decoder library: a handler is a typed
function of the event, declared by the platform's vocabulary
(`language.md` §11.7, `boundary.md` §9.8.10). **The vocabulary had no drag
events**, so this change adds `onDragStart`, `onDragEnd`, `onDragOver` and
`onDrop` to `platforms/html/Html.beni`, `delegated` since all four bubble —
as `onMouseMove` was added for a drawing that Elm writes with
`on "mousemove"` (`boundary.md` §9.8.10, amended 2026-10-13). The page
driver gains a `drag` step to fire them (`tests/corpus/README.md`).

The author's four helpers keep their names and their meaning. Since an
attribute is not a value in beni's markup, each returns the handler instead
of an `Html.Attribute msg`:

| Elm | beni |
|---|---|
| `onDragStart msg = Events.on "dragstart" (Decode.succeed msg)` | `onDragStart : msg → (Event → msg)`, `λ_ → msg` |
| `onDragEnd msg = Events.on "dragend" (Decode.succeed msg)` | the same |
| `onDragOver msg = Events.preventDefaultOn "dragover" (Decode.succeed ( msg, True ))` | `λevent →` `Html.preventDefault event`, then `msg` |
| `onDrop msg = Events.preventDefaultOn "drop" (Decode.succeed ( msg, True ))` | the same |
| `onDragStart (DragStart cell)` in an attribute list | `onDragStart={onDragStart (DragStart cell)}` |

Elm's `True` in `( msg, True )` is "prevent the default"; a beni handler calls
`Html.preventDefault` itself (`boundary.md` §9.8.10). `import Json.Decode as
Decode` goes, with nothing left to import.

## Every other kind of change

1. **No module headers.**
   - `module M exposing (…)` is gone: a module is named by its path, and
     exactly the names the Elm module exposed are `pub` (`Hex.y`,
     `Board.PlayerId`, `Board.centralHexagon` and the rest of the unexposed
     names stay private).
   - `Direction(..)`, `Triangle(..)` and `MoveType(..)` are `pub type`s, whose
     constructors come with them.
   - `Hex`'s module comment, a `{-| … -}` after its header, is a `--!`
     module doc.
   - `import Html exposing (Html, button, div, main_, p, text)`,
     `import Html.Attributes exposing (class, draggable, style)` and
     `import Html.Events as Events exposing (onClick)` become
     `import Html exposing (Event, Html)`: elements and attributes are markup
     names, not imports (`p` was unused in Elm).
   - `import Browser exposing (Document)` is `import Tea exposing (Document)`.
   - `Cmd` and `Sub` are imported (`Cmd exposing (Cmd)`, `Sub exposing (Sub)`).
   - An import that was unused in Elm (`Triangle` in `Move`) is kept, and so
     is the unused `MoveType`.
2. **n-ary functions, saturated calls.**
   - Annotations are written `A, B → C`.
   - Partial application becomes a `_` placeholder:
     `checkWinnerHelp playerId board _`, and
     `List.concatMap (List.map (viewCell model hexSize)) rows` is
     `List.concatMap rows (List.map _ (viewCell model hexSize _))`.
   - A call may leave only one argument open (`two_placeholders`), so
     `List.foldl (placePlayerPieces totalPlayers) board playerIds`, whose
     callback takes two, is `List.foldl playerIds board λplayerId b →
     placePlayerPieces totalPlayers playerId b`.
3. **Subject-first core and pipe-first `▷` (§6.7).**
   - Core's functions take their subject first: `List.map xs f`,
     `List.indexedMap`, `List.concatMap`, `List.filter`, `List.filterMap`,
     `List.partition`, `List.sortBy`, `List.foldl list acc f`,
     `List.member list x`, `Dict.insert dict k v`, `Dict.get dict k`,
     `Dict.member dict k`, `Set.member set x`, `Set.insert set x`,
     `Maybe.map m f`, `Maybe.andThen m f`, `Maybe.withDefault m d`. A pipeline
     into a core function keeps its `▷`.
   - A pipeline into the author's function whose subject is its last
     parameter becomes a nested call: `state.board |> Board.setOccupant
     fromCell.index Nothing |> Board.setOccupant targetCell.index (Just
     state.currentPlayer)` is `Board.setOccupant targetCell.index (Just
     state.currentPlayer) (Board.setOccupant fromCell.index Nothing
     state.board)`. `▷ groupByRow`, of one parameter, stays a pipe.
   - The author's parameter orders are kept.
4. **Lists use brackets and `…` (§6.8).** `current :: rest ->` and
   `first :: rest ->` become `[ current, …rest ] →` and `[ first, …rest ] →`,
   and `(first :: sameRow) :: groupByRow remaining` becomes
   `[ [ first, …sameRow ], …groupByRow remaining ]`.
5. **Unicode notation (§12.7–§12.10).**
   - The operators `→`, `≠`, `▷`, `…`; `\x ->` is `λx →`.
   - Tuple types are written `Int × Int`, `Float × Float`, `Model × Cmd Msg`.
   - `()` is `⊤`: `init : ⊤ → Model × Cmd Msg`, still `init _ = …`.
6. **Blocks instead of `let … in` (§12.2).** Doc comments become `--|`, and
   every comment is kept where it was. `beni fmt` lays out the result, as the
   gate requires: it puts one-line bodies on the `=` line, and each
   `triangleCoords` list one element to a line (the author wrote them in rows
   of 4, 3, 2 and 1).
7. **Negative arguments are parenthesised.** Elm reads `coord 1 -5`,
   `List.range -radius radius` and `max -radius (…)` as negation; beni reads
   `f -1` as `f - 1` (§6.5), so these are `coord 1 (-5)`,
   `List.range (-radius) radius` and `max (-radius) (…)`.
8. **`modBy` is `Int.mod`, subject first (§12.4).** `modBy 2 mx` is
   `Int.mod mx 2`, and `modBy state.totalPlayers (state.currentPlayer + 1)` is
   `Int.mod (state.currentPlayer + 1) state.totalPlayers`.
9. **Markup instead of `Html` calls (§11).**
   - `div [ class "a" ] [ … ]` is `<div class="a">…</div>`, attribute by
     attribute in the author's order; `main_` is `<main>`; an element with no
     children is written `<div … />`.
   - `text "literal"` is literal markup text; `text e` is `{Html.text e}`.
   - A child list, `(List.map viewPlayerButton [ 2, 3, 4, 6 ])`, and the
     `case` expressions in child position are holes, `{…}`.
   - `class ("a " ++ b)` is `class={"a " ++ b}`.
   - `viewPlayerButton` puts two `class` attributes on its button. Elm's
     virtual DOM joins two `className`s with a space; beni's markup takes one
     `class`, so the button's is `class="… transition-transform
     ${playerColor (count - 2)}"`, the same string.
   - `style "width" "600px"` is one entry of a style list
     (`style={[ ( "width", "600px" ), ( "height", "600px" ) ]}`, §11.19).
   - `draggable (boolToString isDraggable)` is
     `draggable={boolToString isDraggable}`; `onClick msg` is
     `onClick={msg}`.
10. **Platform names.**
    - `Browser.document` is `Tea.document`, and `main : Tea.Program`.
    - The `Document`'s `body` is one `Html msg`, so `body = [ main_ … ]` is
      `body = <main …>`.
    - `subscriptions = \_ -> Sub.none` is `λ_ → Sub.none`.

## The page shell

The original is built by Vite: `index.html` holds `<div id="root">`, and
`src/main.js` imports `src/styles.css` (`@import "tailwindcss"`, Tailwind
4.1.18) and mounts `Elm.Main` there. `Browser.document` takes the whole body
whatever node it is given, and so does `Tea.document`. beni has no CSS
pipeline, so `index.html` here is the original's head — its `lang`, meta
tags and title — with the program's entry (`{{entry}}`, `boundary.md` §5)
and Tailwind's own browser build of the same version, which writes the same
classes' CSS in the page, pinned by its SHA-384 (`integrity`). The page
therefore needs the network to be styled; the play script below does not
load the shell, so it does not. It is named by `beni.json`'s `"html"`. Without it
the game still plays, but every class, `absolute` (which places each cell)
among them, is unstyled. `main.js`, `styles.css`, `vite.config.js`,
`package.json` and `bun.lock` are not ported.

## What differs on the page

- **Number formatting.** beni's `String.fromFloat` writes a whole float with
  its point (`300.0`), where Elm writes `300`. The cells' `left` and `top`
  are written with `style.setProperty`, which reads both as the same length,
  so the page does not change.

## The play script

`play/sternhalma.steps` plays the game on the page driver: two players, a
piece of the wrong player that does not start a drag, red's step with its two
cells ringed, a drop out of reach that moves nothing, a drag let go off the
board, purple's step, and red's multi-jump — (4,-5) over (3,-5) and then over
(2,-4) to (2,-3), which no single hop reaches — then New Game.
`play/sternhalma.expected` is its transcript under happy-dom, the same for a
development and a `--release` build; the replay command is in the script's
header.

The original port was held out because its tea-only replay cost about 5 000M
instructions against the default 4 300M; even one click cost 4 592M, so reducing
the script did not solve the cost of loading the board.

**Promoted on 2026-10-15.** `tests/corpus/browser/direct/Sternhalma/` now points
at `examples/sternhalma/src` and runs the original script on both browser-direct
and browser-tea, development and release, against one golden. The fresh-board
repair changes no transcript. The paired page measured 9 031M instructions and
its separate value fuzz 11 387M. The owner explicitly granted 10 000M and
12 600M respectively; the `.budget` and `.fuzz-budget` files keep those grants
separate and state when they can be removed. The gates now replay this case.

The original `play/sternhalma.expected` remains byte-identical. The command
above is also available for a manual replay; transcript changes still require
an explained behavior change.

## Not ported

- **The page shell's build** (Vite, `main.js`, `styles.css`), replaced by
  `index.html` above.
- **`README.md`**, two lines naming the game.

Dict keys are Int or String in beni. The board's coordinate lookup encodes its
integer x/z pair as a colon-separated String; the board still exposes the same
coordinates and cell indices.
