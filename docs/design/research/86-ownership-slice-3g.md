# 86 — The ownership checker's slice 3g: binders, `?`'s early return, a prepend of fresh lists, `Result`'s default

*2026-10-13. What `beni dump --stage=ownership` says once a `?` returns its `Err` payload (`ownership-checker.md`
§26.2), a prepend whose front item is a list made after its base no longer aliases the base (§26.3), and
`Result.withDefault (Result.map m f) d` is walked as two arms (§26.4); and the argument that no compiler-made
binding can make a later read resolve to the wrong binding (§26.1). The programs are research 82's frozen raw Bike
Wars port (commit `51739633e`, unchanged on master), Conduit, the four TodoMVC programs, the table app, core and
the corpus. The baseline is master at `9a5276a06` (slice 3f and its review); the branch is that plus this slice.
Every figure is **[measured]** with §7's commands; there are no timings here.*

---

## 0. The answer

1. **The Zig checker is not vulnerable to the Lean model's shadowing defect.** It names a variable by its BIR
   local index, never by its name; lowering hands every binder — written or compiler-made — an index of its own
   (`Lower.bindLocal` appends), and the walk keys every value, read, holder and capture by that index, matching a
   holder against later reads of the same index. There is no backward live set for an inner scope to inherit. A
   run-time assertion that each index is bound once per walk ran over 10 965 dumps (core, every corpus file under
   five platforms, the applications) without tripping (§2).
2. **The review found a real defect beside it: `?` dropped its early return.** `e?` returns `Err x` from its
   definition; the walk modelled only the `Ok` half, so a caller could write a list in place while reading the
   `Err` that held it, and was accepted. Fixed; `ownership/Question` was accepted on master (§1.2).
3. **Bike Wars: 6 of 19 demand lines rejected → 4 of 15 (27 %).** Both approximate lines are gone: the `++` onto
   `[ frontWall other, …omitLastSections current.trail ]` is accepted `fresh`, and `Game.stepGame`'s line through
   `Bike.update` disappears with the write it came from. What is left is **2 correct and 2 position; no limits**
   (§3).
4. **`Result.withDefault (Result.map …)` is built; `andThen` is refused.** Research 85 §6 and §25.7 said §25.4's
   argument covers `Maybe.andThen` and `Result`. It covers `Result.map`; it does not cover `andThen` of either
   module, whose `f` may run, edit, and then answer `Nothing` or `Err` — after which the default is read. No
   measured program uses either shape, so neither moves a line outside its fixture (§1.4).
5. **No acceptance became a rejection, anywhere, and no line changed outside Bike Wars and the four new
   fixtures.** Conduit, TodoMVC, the table app and core print the same lines; the corpus sweep is identical line
   for line on both rows. Three corpus summaries gain the `Err` payload in `res` (§4).

## 1. The four items

### 1.1 Binders (§26.1)

The Lean model's probe, `let 0=[1]; let 6=(let 5=0; let 0=[]; push 5 1); length 0`, is `ownership/Binders.nested`
in beni (renamed, since beni refuses shadowing): rejected `alias`, `kept` read at 29:9. The fixture puts every
binder kind lowering makes between a write and a later read of the original — a block, a statement, a `case` arm
and its `…rest`, the `_` placeholder's lambda, `.field`, `(==)`, a local recursive function (whose group the walk
re-walks per round), a pipeline, a record update and a `←` bind — and each is rejected naming the original. Every
line is the same on master: the checker was already right; the fixture keeps it so.

What the argument rests on, each checked in the code:

- `Lower.bindLocal` returns `locals.len − cur_locals_start` and appends: an index is never reused within a
  declaration. `freshLocal` (the placeholder, `.field`, operator sections) goes through it.
- `local`, `pat_var`, `pat_as`, `pat_record` and `let_def` carry that index; `Ownership.zig` reads no symbol of
  a local except to print it.
- The Dead check (`resolveRaw`) matches `Use.local == Holder.local`, same frame, later point, compatible branch.
  Holders are read off `local_av` at the demand, so a binding made after the demand is no holder of it.
- The only re-walk, `walkGroup`, restores `local_av`, `local_frame` and `local_ctx` from its snapshot.
- The assertion added to `bindLocal` (`local_av[l] == null`) holds on 10 965 runs.

Inlining and pattern compilation happen on JsIr, after the checker; slice 5 inherits the obligation to keep each
read's order against the write it was checked with (§26.1).

### 1.2 `?` (§26.2)

```
pick r =
    n = r?
    Ok (n + 1)

keepsErr xs =
    r = pick (Err xs)
    ys = List.push xs 4
    …  -- reads r's Err payload
```

On master `pick`'s summary was `π1 R` — no result — and `List.push xs` was `accepted param`. On the branch
`pick` is `π1 R, π1#Err.0 A; res #Err.0 π1#Err.0` and the push is `rejected alias: r#Err.0 holds it`. The same
holds through a statement `?` (`check r = r?; Ok 0`). Through a local function's `?` master already rejected the
push, but only because the local function's result held `xs` at a `⋆` under `Ok`; it now names the `Err`.
`Maybe` (`Nothing` holds nothing) and a `String` error stay accepted.

### 1.3 A prepend of a fresh list (§26.3)

A re-cons answers the base's array only when the front item is `Js.same` as the element stored before the base's
view, or in a trie head's slack slot; both are elements the domain names at the base's cells' `[*]`. A list made
by a literal or a callee's fresh result, exact, not escaped and not reachable from the base, is not that element.

`ownership/PrependFresh`: a literal front (`literalFront`), a callee's fresh list (`calledFront`) and the Bike
Wars line (`bikeWars`) go from `call (approx)` to `accepted fresh`. Rejected as before: `storedBefore` (a list
stored in the base first; `List.drop base 1` is a view whose previous element *is* that list, so the re-cons
really happens), `baseHolds` (the item handed to the call that builds the base), `elementFront` (an element of
the base) and `intFront` (`0` is `Js.same` as any stored `0`). With the reach check removed, `storedBefore` and
`baseHolds` are accepted: the check is what keeps them out (verified by building the branch without it).

### 1.4 `Result`'s default, and `andThen` (§26.4)

`ownership/ResultDefault`: `m ▷ Result.map (handle model _) ▷ Result.withDefault model` and the lambda form go
from `later-use` to `accepted once`; `readAfter` now names the real later read (49:30, master named the default,
48:12). `resultAndThen` and `maybeAndThen`, each with an `f` that edits the model and then answers `Err` or
`Nothing`, stay `later-use`, and must: on that run the default is read after the edit. `mixed` (a `Maybe.map`
converted with `Result.fromMaybe` first) is an ordinary call.

## 2. The sweep behind §1.1

`dump --stage=ownership` with the assertion on, over core; Bike Wars and Conduit on `browser-tea` and
`browser-direct`; the table app and the four TodoMVC programs on `browser-direct`; and every `.beni` file under
`tests/corpus` with no platform and with `node`, `tests/platforms/page`, `browser-tea` and `browser-direct`:
10 965 runs, no trap.

## 3. Bike Wars, line by line

Research 85's six rejections and the lines that changed:

| Line | Master | Branch | By |
|---|---|---|---|
| Bike 56:62 `++ <construction>` | call (approx) | **accepted fresh** | §26.3: `frontWall other` is a fresh list `omitLastSections current.trail` cannot reach |
| Game 159:11 `Bike.update <record>.current.trail` | call (approx) | — | `Bike.update` no longer writes `π3.current.trail`: its only write was line 56's append onto it |
| Game 160:11 `Bike.update <record>.current.trail` | accepted param | — | the same |
| Game 123:13 `Game.stepGame model.bikes.green.trail`, `….red.trail` | accepted param | — | `stepGame` no longer writes the trails, through `Bike.update` |
| Bike 91:69 `++ current.trail` | later-use | later-use | correct (R2) |
| Game 136:39 `Bike.shoot <record>.current.trail` | alias | alias | correct (R2) |
| Main 12:5 entry `model.bikes.green.trail`, `….red.trail` | top-level | top-level | position (R7) |

Both platforms give the same lines. **15 lines: 11 accepted (3 `fresh`, 3 `call`, 3 `param`, 2 `once`), 4
rejected — 2 correct, 2 position, 0 limits.** The repair thesis §12.5 counts is now two edits: R2's fresh base and
Change 4's `initModel ⊤`; research 85 §6 item 3's rewrite of line 56 is no longer needed.

## 4. Every verdict change

| Program | Master | Branch | Change |
|---|---|---|---|
| Bike Wars (both platforms) | 19 lines: 13 accepted, 6 rejected | 15: 11, 4 | §3: one rejection accepted, one rejection and three acceptances gone with their demands |
| Conduit (both platforms) | 26: 22, 4 | 26: 22, 4 | none |
| TodoMVC, four programs | 2 each | 2 each | none |
| table app | 5 | 5 | none |
| core | 117 accepted | 117 accepted | none; no summary changes either |
| corpus, first platform | 461: 291 accepted, 1 pending, 169 rejected | the same | none |
| corpus, TEA targets on `browser-direct` | 366: 299, 4, 63 | the same | none |
| `ownership/` fixtures | — | four new | `Binders` (unchanged against master), `Question` (2 acceptances → rejections, 1 rejection's cause from `⋆` to exact), `PrependFresh` (3 approximate rejections → accepted), `ResultDefault` (2 rejections → accepted) |

The corpus rows count every target outside `tests/corpus/ownership/` (whose fixtures are counted by their goldens)
under the first platform it checks with, and every `browser-tea` target again under `browser-direct`. They differ
from research 85's counts (459 and 282) because that sweep's target set and grouping differ; both binaries here ran
over the same tree, so the comparison is line for line.

Summaries that changed outside Bike Wars and the fixtures, all by §26.2: `check/good/NestAfterDefault` and
`run/MergeAtBoundary` (`f` gains `res #Err.0 π1#Err.0`), and `run/TryTargetKeepsItsSuccessType`, whose
`g k = k (u?)` returns from the local function `g`, so each call of `g` may answer `u`'s `Err` (`res .0#Err.0
π1#Err.0, .1#Err.0 π1#Err.0`). None holds a list a demand writes, so no line moves.

The only acceptance that became a rejection is in a new fixture, `Question`, and it is the defect.

## 5. Against the Lean model

The model has no list patterns, constructors, records, early return or prepend (`Syntax.lean`), so none of the
four rules runs there; §26.7 lists them, with the rules of slices 3b–3f the model also lacks, for the sync round.
The shadowing probe is `Binders.nested`, rejected here as the corrected model rejects it. As before, the model was
not run (no Lean toolchain in the environment).

## 6. Open questions

1. **`List.cons x xs` written as a call** keeps its approximate row (§26.8).
2. **Fresh non-list items** — a record or constructor value — cannot be seen to be new: the domain gives them no
   cell (§26.8).
3. **`andThen` with an `f` that never fails** is `map`; recognising it would mean reading `f`'s body for a
   constructor in every result position. No program needs it.

## 7. How to reproduce

```sh
zig build test-blackbox-corpus -Dcorpus=ownership   # builds zig-out/safe/bin/beni
B=./zig-out/safe/bin/beni
$B dump --stage=ownership --platform=browser-tea examples/bike-wars/src     # and browser-direct
$B dump --stage=ownership --platform=browser-direct examples/conduit/src    # and browser-tea
$B dump --stage=ownership --platform=browser-direct bench/ui/apps/beni
$B dump --stage=ownership --platform=browser-direct bench/todomvc/apps/beni/Sandbox.beni   # and the other three
$B dump --stage=ownership core
```

The corpus sweep: every project directory under `tests/corpus` (one holding an `_expected.*` file) and every
`.beni` file outside one, dumped under the first of none, `node`, `tests/platforms/page`, `browser-tea`,
`browser-direct`, `browser`, `html` it checks with, and, when that is `browser-tea`, again under
`browser-direct`; master's binary and the branch's over the branch's tree; lines matched by module, position,
operation, base and verdict.
