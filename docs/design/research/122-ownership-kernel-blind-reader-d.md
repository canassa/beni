# Research report 122: the ownership kernel, blind reader D

*2026-11-13. A blind soundness test of the ownership checker prototype (`src/own3/`, `--ownership=v3`) at
commit `a2c60aa2b7`, branch `ownership-v2-design-review`. Reader D. I did not read reports 110 to 120, the
other blind generators, their fault folders, the v3 black-box tests or the diary entries from 2026-11-12 on.
I worked from the code, `ownership-v3-kernel.md` and `boundary.md` §9.4.8. This is a finding, not a design
change: nothing under `src/` changed.*

## 1. Summary

v3 accepts programs that then read a stale list. I found **four faults**. Three are in the entry rule
(kernel §6.13), one is in the markup rule (kernel §6.12). All four are in plain application code: a TEA page
whose `view` is chosen by an `if`, a list row that you click to select, a model that is a pair.

| Fault | Shape | Rule | Wrong | v1 | v2 |
|---|---|---|---|---|---|
| 1 | a function of the program record that the walk has no code for (`view = if dark then viewDark else viewLight`) keeps a list of the model | §6.13 | code | refuses | traps |
| 2 | `settle` that the walk has no code for keeps a list of the model | §6.13 | code | refuses | traps |
| 3 | a function that `For` or `Show` runs with an item (the row, the key, the body) keeps the item | §6.12 | the rule's argument, and the code | traps (node, `--ownership-everywhere`) | refuses in a frame, traps at the entry |
| 4 | the model is a tuple and `update` answers `model × Cmd msg` | §6.13 | code | refuses | traps |

The sweep has 1 234 programs. v3 traps on 393 of them. Each of the 393 is one of the four faults. There is
no `DIFF`, no `CRASH` and no compile that does not end.

## 2. What I probed

The angle was real applications. I wrote the programs as an application developer writes them, on the real
platforms, and then looked for every way that two names reach one list, or a read moves past a write.

The generator is `bench/ownership-sweeps/blind5d.mjs`. It writes these families:

- **`entry`** (1 068 programs): a page on `browser-tea` (`Tea.element`, `Tea.sandbox`, `Tea.document`) or
  `browser` (`Browser.program`, `Browser.hosted`). Something other than the model holds a list of the
  model. Then `update` pushes onto that list. The holder ("keeper") is one of 16: a message in a handler, a
  message sent twice in one task, a handler lambda, a row of a positional `For`, a row of a keyed `For`, a
  row function by name, a `Show` body, a row through `Html.map`, a `For` inside a `For`, a helper that makes
  the button, `Html.map`'s function, a subscription's tagger, `settle`, a command that gives the list back
  later, the history (`update` pushes the list into another field), and `init` (one list at two fields).
  The record's function that holds the keeper is given in nine ways: by name, as a lambda, as an `if`, as a
  field of a top-level record, as a partial application, as a local, as the answer of a call, as a `case`
  arm, and through `Maybe.withDefault`.
- **`model`** (96): the model is a record, a pair, a triple or a constructor, on five entry functions; the
  list is kept at two places by `update`, by a command, or by a message.
- **`ssr`** (22) on `node`: markup that holds a list, rendered later; a row function or a `Show` body that
  keeps its item in a `Ref`.
- **`fiber`** (14): `Task.spawn`, `Task.race`, `Task.forEach`, `Deferred`, `Queue`, a helper that spawns,
  and fibers that sleep while the list is written.
- **`dict`**, **`random`**, **`ref`**, **`json`** (28): a list in a `Dict`, a `Random.Pcg` generator, a `Ref`
  cell, a JSON round trip.
- **`method`** (10): a `Stack` type with methods in a second module, called with dot syntax.

Each shape has a `live` twin (it keeps the list: v3 must refuse or print the same) and a `dead` twin (it
keeps a copy: safe).

I also wrote about 60 programs by hand while I looked for shapes. They covered folds that keep the
accumulator in a history, record updates whose fields read and write one list, `[ _, …rest ]` views, closures
in records and lists, partial application (`f (List.copy xs) _` copies when it is called), `Hosted.emit`,
markup cached in the model, markup that crosses a function boundary, and the `dom` runtime's row cache. v3 was
right on all of these, except the shapes of §3.

Commands:

```sh
zig build -Doptimize=ReleaseSafe --prefix <dir>
node bench/ownership-sweeps/blind5d.mjs <out>
node bench/ownership-sweeps/run.mjs --beni=<dir>/bin/beni --checker=v3 --jobs=8 --tmp=<disk> <out>
```

For the v1 and v2 columns, I ran `run.mjs` with `--checker=v1` and `--checker=v2` on the 393 programs that
trap under v3, and on the fault folder.

### 2.1 Verdicts

| Family | Programs | SAME | REFUSED | TRAP | DIFF, CRASH, LIMIT, PLAINFAIL |
|---|---:|---:|---:|---:|---:|
| `entry` live | 534 | 0 | 151 | **383** | 0 |
| `entry` dead | 534 | 534 | 0 | 0 | 0 |
| `model` live | 48 | 0 | 40 | **8** | 0 |
| `model` dead | 48 | 48 | 0 | 0 | 0 |
| `ssr` live | 11 | 2 | 7 | **2** | 0 |
| `ssr` dead | 11 | 11 | 0 | 0 | 0 |
| `fiber` live / dead | 7 / 7 | 0 / 6 | 7 / 1 | 0 | 0 |
| `dict` live / dead | 4 / 4 | 0 / 1 | 4 / 3 | 0 | 0 |
| `random` live / dead | 3 / 3 | 0 / 0 | 3 / 3 | 0 | 0 |
| `ref` live / dead | 3 / 3 | 0 / 1 | 3 / 2 | 0 | 0 |
| `json` live / dead | 2 / 2 | 1 / 1 | 1 / 1 | 0 | 0 |
| `method` live / dead | 5 / 5 | 0 / 5 | 5 / 0 | 0 | 0 |
| **all** | **1 234** | **610** | **231** | **393** | **0** |

Three `live` programs are `SAME`, and none is a fault. `json.encode.live` only encodes the list, which reads
it. `ssr.keykeep.live` and `ssr.showkeykeep.live` keep the item in a key function, and the `ssr` lowering
does not run key functions. The same key function in a page traps (fault 3).

The 393 traps by fault: fault 1, 108; fault 2, 5; fault 3, 272 (270 pages and 2 on `node`); fault 4, 8.

## 3. The faults

The minimal programs are in `bench/ownership-sweeps/blind5d-faults/`. Each has a `.live` program (v3 accepts
it and the in-place build reads a stale list; it must be refused) and a `.dead` twin (a copy where the live
one keeps the list; v3 accepts it, and it is safe).

### 3.1 Fault 1: a function of the record with no code is skipped

Program: `view-no-code.live`. The view puts the model's list in a message. `update` keeps the message's list
in `saved`, then pushes onto `items` in place:

```beni
view model =
    <main>
        <button id="add" onClick={Add}>add</button>
        <button id="snap" onClick={Snap model.items}>snap</button>
        <p>{List.length model.saved}</p>
    </main>


main =
    Browser.program
        { init = λ⊤ → { items = List.copy [ 1, 2 ], saved = [] }
        , update = update
        , view = if True then view else view
        }
```

With `view = view` v3 refuses (`entry Main.update model.items`). With the `if`, it accepts, and after `click
#snap`, `click #add` the page reads `saved`, which `List.push` changed.

**Rule.** Kernel §6.13: "The other functions of the record keep what they write, let escape, hand to a
function, or (except a view) answer; a location they keep is not `own`." A function that the walk cannot
read is the pessimistic case: it can keep everything it is handed.

**Code.** `entryCall`, `src/own3/Frame.zig:4803`. When `codeOf` of a field is null (a `join`, an `outside`
value, `unknown`, a `built` value), the field gets `flowTop` and `continue`. It is never put in `others`. So
the loop at `Frame.zig:4938`, which takes `own` away for each model location that another function keeps,
never sees it. `flowTop` refuses a function that *writes* its parameter, so a `view` with no code that writes
is refused. A `view` with no code that *keeps* is not. **The code is wrong; the rule is right.** The fix is
on the pessimistic side: a field with no code makes every model location that its type can reach not `own`.

Every way of giving a function that makes `codeOf` null shows it: `if`, `case`, a field of a top-level
record, `Maybe.withDefault`. A lambda, a local, a partial application and the answer of `pick view` give a
closure or a function reference, and are refused. The keeper can be a message, a message sent twice, a
handler lambda, `Html.map`'s function, a helper's button or a subscription's tagger (`sub.join`, `sub.proj`,
`sub.case`, `sub.maybe` on `Tea.element` and `Tea.document`).

This is a real shape. A page that picks its view by a setting or a route writes `view = if … then … else …`,
or keeps its views in a record.

**v1** refuses every program of this fault. **v2** traps on every one.

### 3.2 Fault 2: `settle` with no code is not a producer

Program: `settle-no-code.live`, on `Browser.hosted`. `settle` copies `items` into `saved` when a flag is set.
`update` then pushes onto `items`:

```beni
settle _ model = if model.mark then { model | saved = model.items, mark = False } else model


main =
    Browser.hosted
        { init = λ_ → { items = List.copy [ 1, 2 ], saved = [], mark = False }
        , update = update
        , settle = if True then settle else settle
        , view = view
        }
```

**Rule.** Kernel §6.13: a location is `own` only where each source of it is right in **each producer of the
model** (`init`, `update`, `settle`).

**Code.** `Frame.zig:4872`. In the loop over the producers, a producer with no code takes `own` away only
when it is `init` (`which == 0`). For `update` the walk returned earlier; for `settle` it does `continue`,
which reads "no code" as "answers nothing". **The code is wrong.** `settle` with no code must take every
location's `own` away, as `init` with no code does. The same fault happens with `settle = settleOf 0`, the
answer of a call.

**v1** refuses. **v2** traps.

### 3.3 Fault 3: what `For` and `Show` hand to a function

Program: `for-row-keeps.live`, on `node`, with no entry at all:

```beni
keep : Ref (List Int), List Int → Html msg
keep seen r =
    Ref.set seen r
    <li>{List.length r}</li>


main =
    rows = [ List.copy [ 1 ], List.copy [ 2 ] ]
    seen = Ref.make []
    list = <ul><For each={rows} keyed={False}>{λr → keep seen r}</For></ul>
    page = Ssr.render list
    edited = List.update rows 1 λr → List.push r 9
    Node.printLines [ page, String.fromInt (List.length (Ref.get seen)), … ]
```

The row function puts its row in a `Ref`. The render runs it on `rows[1]`. Then `List.update rows 1` pushes
onto that row in place, and the read through the `Ref` traps.

The same fault in an application is `for-row-message.live`: a row's button sends `Pick r`, `update` keeps the
row in `picked`, then edits the row in place. In the sweep it is every `row`, `keyrow`, `rowfn`, `rowmap`,
`nested` and `show` keeper, in all nine forms and on all five entry functions (270 pages). I also built it by
hand with a `For` key function that keeps its row in a `Ref` of the model: it traps.

**Rule.** Kernel §6.12 says what markup *holds* (the values of its holes, until it renders) and what
*escapes* (each value at an item that no row names as an attribute). It does not say that the runtime
*calls* some of those values: `For` calls its row function and its key function with each item of `each`,
`Show` calls its body and its key function with the value of `when`. What such a function keeps of its
parameter is in its contract (here the parameter escapes, `Ref.set` stores it), but nothing hands it the
items, so the escape never reaches `rows[*]`. The theorem of §5 needs "every holder the walk does not follow
records an escape of every atom it can hold"; the runtime is such a holder for each item, and records none.
**The rule's argument is wrong, and the code follows the rule.** The fix is the rule for a call: `For` and
`Show` are callees that hand the elements of `each` (or the payload of `when`) to their functions, so each
function flows with that supply (`flow`), and what it keeps escapes.

**Code.** `evalInner .markup`, `src/own3/Frame.zig:1910–1921`. A closure that answers markup is not `kept`
("a function that answers markup is a part of the view"), so it gets only `readAll`; a function reference
(a row function by name) gets `readAll` too. `keptItems` (`Frame.zig:2017`) has no case for the functions of
`For` and `Show`. A function that *writes* its parameter is refused there (it flows to the default use), so
only a function that *keeps* is missed.

**v1** traps on the two `node` programs under `--ownership-everywhere`, and refuses every page. `browser-inline`,
where v1 edits lists in place for users, does not compile `For` or `Show` yet, so this is not reachable in a
build of today. **v2** refuses the two `node` programs (`alias`), and traps on all 270 pages.

### 3.4 Fault 4: a model that is a tuple

Program: `pair-model.live`, on `Tea.element`:

```beni
type alias Model =
    List Int × List Int


update : Msg, Model → Model × Cmd Msg
update msg ( items, saved ) =
    case msg of
        Add →
            ( ( List.push items 3, saved ), Cmd.none )

        Snap →
            ( ( items, items ), Cmd.none )
```

`Snap` puts one list at both places of the model. `Add` then pushes onto the first, and the page reads the
second, which changed. The same model as a record or a constructor is refused. On `Tea.sandbox`,
`Browser.program` and `Browser.hosted`, where `update` answers the model alone, the pair is refused too.

**Rule.** Kernel §6.13: the place of the model is "the answer of each producer of the model". For
`Tea.element` that is the first of the pair that `update` answers.

**Code.** `entryCall`, `src/own3/Frame.zig:4884–4891`. The walk decides whether the answer *is* the model or
a pair whose first is the model by a guess on the locations: the answer is a pair if one of its locations is
below index 0; but then it is the model again if one of the *model's* locations is below index 0. A model
that is a tuple has its own index 0, so the guess says "the answer is the model". Then `want` is the model's
location without the pair's index, no result entry is at it, and every location stays `own`. **The code is
wrong.** The type of the producer's answer says which it is (the record's field type: `model × Cmd msg` or
`model`), and the walk should read that and not guess. A triple model fails the same way; a pair model with
a command that gives the list back later (`model.tea.pair.cmd`) fails too.

**v1** refuses. **v2** traps.

## 4. Precision

The `dead` twins of the entry are accepted: 534 of 534, and 48 of 48 for the model shapes. These are the
safe programs that v3 refuses, the real-looking ones first.

1. **A lambda that reads a field of the model, inside `update`.** `List.update model.rows 0 λr → List.push r
   model.n` is refused: `disjoint: another operand of the same operation reaches it`. The lambda captures the
   model, so the operand reaches `rows`. Binding `n = model.n` first is accepted. This is the most common way
   to write the line.
2. **A list in a `Dict`.** `Dict.update d k λm → Maybe.map m λl → List.push l x` is refused (`supply: the
   function writes a parameter`), even when nothing else holds `l`. This is how a program groups values by a
   key (`dict.update`, `dict.values`, `dict.fold` dead twins).
3. **A list in a `Ref`.** `Ref.update cell λl → List.push l x` is refused (`supply`), even when no one read the
   cell before (`ref.get.dead`, `ref.modify.dead`). This is how a program keeps a log or a buffer in a cell.
4. **A list from JSON.** A list decoded with `Json.decode` cannot be written (`unknown: the checker has no
   claim on this value`), so decode-then-append copies (`json.decode.dead`).
5. **A `Show` whose `when` is built in the hole.** `<Show when={Just model.rows} keyed={λ_ → 0}>` makes the
   page refuse a write to `model.rows`: a value built in a hole escapes. The corpus has this shape
   (`when={Just model.numbers}`).
6. **A list written after its fibers joined.** `Task.par` and `Task.forEach` let the lists they hand to their
   functions escape, so a write after the call returns is refused (`fiber.foreach.dead`, and `Task.par` by
   hand). The fibers are done when the call returns.
7. **A random value.** The answer of `Random.Pcg.step` is `unknown`, so a list made by a generator cannot be
   written (`random.*.dead`).
8. **Two writes in one expression.** `List.set (List.set xs 0 z) (List.length xs - 1) a` is refused: the
   length is read after the inner write. The length did not change.

Two `dead` twins of the first version of the generator were not safe, and v3 was right to refuse them: a
handler lambda that copies the list copies it when it runs, which can be after the push (two events in one
task); and `later (List.copy model.items) _` copies when the command runs. The generator now binds the copy
first.

## 5. What I did not cover

- `browser-inline` as the subject. Its plain build already edits in place under v1, so it is no oracle for
  v3, and it does not compile `For` or `Show`.
- `Tea.application` (`onUrlChange`, `onUrlRequest`), `Browser.programs`, Workers, WebSocket, `Http` and
  `Storage` commands, `Cmd.keyed` policies and `Cmd.afterRender`.
- Schemas (`schema` declarations), `Binary`, `Markdown`, and records written in place.
- `where` evidence written by the application; only methods by dot syntax in a second module.
- Recursive types in the model, and models whose type is over the layout limit.
- Whether `Html.map`'s function can be handed a list that a row function kept. It is fault 3 if it can; I did
  not build it.
- The `cloudflare` platform and the GPU platforms.
