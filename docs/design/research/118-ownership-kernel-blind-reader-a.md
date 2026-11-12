# 118. The ownership kernel v3: a blind test, reader A

*Research report, 2026-11-13. A blind soundness test of `src/own3/` at commit `ca2fc63410` (branch
`ownership-v2-design-review`, PR #2451), against `docs/design/ownership-v3-kernel.md`. Reader A worked
from the code, the kernel text and the other sweep generators. It did not read reports 110 to 117, the
earlier blind generators, their fault folders or the black-box tests of v3.*

## 1. Summary

v3 accepts programs that then read a list after an in-place write. There are six distinct faults, in
three places:

1. **The entry rule (§6.13)** has four. The runtime hands `update` a model or a message that the checker
   calls `own`, but another holder keeps it: a `Ref` that `init` or `update` filled (two faults), a second
   field of the model that holds the same new list, or a top-level value in the message (or one message
   sent twice).
2. **The fold rule (§6.8, `answerOwn`)** has one. A callback's answer that the callback made is `own`
   even when the callback let it escape.
3. **The rule for derived methods (§6.11)** has one. A derived `eq` or `compare` calls the `eq` or
   `compare` that a part's type declares. No walk sees that call, and that method writes in place.

Each fault reproduces on the repository's own `page` test platform or on `node`. Each has a minimal
program and a safe twin in `bench/ownership-sweeps/blind4a-faults/`. v1 also accepts the derived-method
fault, and some fold variants. v2 also accepts two of the entry faults.

## 2. What I probed

| Probe | Programs | How |
|---|---:|---|
| `bench/ownership-sweeps/blind4a.mjs` | 160 | three families, each `live` and `dead` (§3) |
| `blind4a-faults/` | 12 | six faults, each with its safe twin |
| one list at two places through a helper, in one module and across two modules | 40 | a scratch generator, not kept: 0 faults |
| hand probes | about 60 | below |

The hand probes, all with 0 faults: lists from `List.repeat`, `List.intersperse`, `List.initialize`,
`List.concat` and `List.append` with one list at two places, handed to a writing `List.map` callback;
`rest` views and `List.drop` views written while the base is read; a list literal inside a function that
is called twice (whether the emitter shares it); the re-cons of `[ x, …rest ]` with `[]`, numbers and
constructors in front; a `schema`'s `via` conversion whose backward function writes; a chain of twelve
closures that answer a captured list (the depth limits of `answerOfCode`); `Js` from an application
(refused by the build). The fault families came out of reading the code (§4).

Commands, from the repository root:

```sh
zig build -Doptimize=ReleaseSafe --prefix <dir>
node bench/ownership-sweeps/blind4a.mjs <out>/b4
node bench/ownership-sweeps/run.mjs --beni=<dir>/bin/beni --checker=v3 --jobs=8 --tmp=<disk> <out>/b4
node bench/ownership-sweeps/run.mjs --beni=<dir>/bin/beni --checker=v1 --jobs=8 --tmp=<disk> <out>/b4
node bench/ownership-sweeps/run.mjs --beni=<dir>/bin/beni --checker=v2 --jobs=8 --tmp=<disk> <out>/b4
node bench/ownership-sweeps/run.mjs --beni=<dir>/bin/beni --checker=v3 --tmp=<disk> bench/ownership-sweeps/blind4a-faults
```

`run.mjs` now builds a program with a `PLATFORM` file for that platform, and runs a program with a
`steps` file under `tests/browser/driver.mjs` with happy-dom. The transcript is then the output. The
entry programs use this. Nothing else in `run.mjs` changed.

## 3. The verdict table

`blind4a.mjs`, 160 programs. `live` reads the other holder after the write; `dead` does not.

| Family | Checker | SAME live | SAME dead | REFUSED live | REFUSED dead | TRAP live |
|---|---|---:|---:|---:|---:|---:|
| `derived` (80) | v3 | 0 | 26 | 17 | 14 | **23** |
| | v1 | 0 | 26 | 17 | 14 | **23** |
| | v2 | 0 | 0 | 40 | 40 | 0 |
| `fold` (60) | v3 | 0 | 30 | 0 | 0 | **30** |
| | v1 | 0 | 20 | 10 | 10 | **20** |
| | v2 | 0 | 0 | 30 | 30 | 0 |
| `entry` (20) | v3 | 0 | 10 | 0 | 0 | **10** |
| | v1 | 0 | 0 | 10 | 10 | 0 |
| | v2 | 0 | 7 | 3 | 3 | **7** |

No program gave `DIFF`, `CRASH` or `LIMIT`. In `derived`, the shape `direct` (`T xs == T [ 5 ]`) is the
control: v3 refuses it, because there the call of `Tm.eq` is in sight. The `REFUSED` programs of
`derived` are `List.sort` and `List.member` over a tuple, a record, `Maybe` or `Result`: there the
evidence term names `Tm.compare` or `Tm.eq`. Over a type of the program (`W`), it does not, and they trap.

## 4. The faults

Each fault has `<name>.live` (it must be refused) and `<name>.dead` (it is safe) in
`bench/ownership-sweeps/blind4a-faults/`. Every `live` traps under v3 with `--sanitize-lists`, and every
`dead` gives `SAME`.

### 4.1 `entry-escaped-fresh`: `init` lets the model's list escape

```beni
init _ =
    xs = [ 1, 2 ]
    { items = xs, keep = Ref.make xs }

update n model =
    { model | items = List.push model.items n }
```

`view` shows `Ref.get model.keep`. After a click, the push edits the list that the `Ref` holds.

- **Rule:** §6.13: `update`'s model is `own` where `init` answers it `own`. A new list that `init` let
  escape is not `own`: the `Ref` holds it.
- **Code:** `Frame.zig:4626`, in `entryCall`: a result source `.fresh => {}` is accepted, and its
  `escaped` bit (`Src.e`, printed `fresh0!` in the summary) is not read. The code is wrong. The same hole
  is in `update`: a new list that `update` puts in a `Ref` and answers (`entry.updfreshref` in the sweep).
- **v1:** refuses. **v2:** refuses.

### 4.2 `entry-fresh-twice`: one new list at two places of the model

```beni
init _ =
    xs = [ 1, 2 ]
    { items = xs, other = xs }
```

`update` pushes onto `items`; `view` reads `other`.

- **Rule:** §6.13: "no location is answered twice".
- **Code:** `Frame.zig:4628-4639`. The test for one cell at two places of the model runs only for a
  `.param` source and only when `which != 0`, so never for `init` and never for a new list. Two
  locations with one `fresh(k)` both stay `own`. The code is wrong. The sweep has the same with a nested
  record, with `Maybe`, and with `update` answering one `List.copy` at two fields.
- **v1:** refuses. **v2:** also accepts it, and traps.

### 4.3 `entry-escaped-param`: `update` lets a model location escape

```beni
update n model =
    if n == 0 then
        Ref.set model.keep model.items
        model

    else
        { model | items = List.push model.items n }
```

The first click puts `items` in the `Ref`; the second pushes onto it in place.

- **Rule:** §6.13. A location that `update` lets escape, and answers, is held by the `Ref` after the call.
- **Code:** `Frame.zig:4641-4649`. A `.param` source is `own` when the model location it comes from is.
  The contract's `flag_e` on that parameter location is never read here. `answerOwn` has this test
  (`Frame.zig:3991`, "the function lets a value escape and answers it"); `entryCall` does not. The code
  is wrong.
- **v1:** refuses. **v2:** refuses.

### 4.4 `entry-message`: the message is not `update`'s own

```beni
base =
    [ 5 ]

update msg n =
    case msg of
        Add l →
            List.length (List.push l 9)

view n =
    Page.element "button" [ Page.attribute "id" "add", Page.onClick (Add base) ] [ … ]
```

The first click pushes onto `base` in place. The second click reads it.

- **Rule:** §6.13: "`update`'s message is `own` only when every location of the model is". The argument
  is that a `send` is checked and that a message built in `view` can hold a model cell only where `view`
  keeps the model. That covers the model's cells only. A message can also hold a top-level value (an
  outside cell), and the runtime can send one message more than once: a handler keeps its message until
  the next render, so two clicks in one task send one list twice (`entry.msgresend` in the sweep). Neither
  is a cell of the model. **The rule's argument is wrong.**
- **Code:** `Frame.zig:4691-4697`: `ok` for the message is the conjunction of the model's `own` bits.
  `Frame.zig:4636-4639` rests on the same argument: a model location that `update` answers from its
  message is `own` ("each send is checked"), so `Add l → { model | items = l }` puts `base` in the model
  as `own`.
- **v1:** refuses. **v2:** also accepts it, and traps.

### 4.5 `fold-escaped-answer`: a callback's escaped answer comes back as `own`

```beni
List.foldl [ 1, 2 ] [ 0 ] λx acc →
    _ = List.push acc x
    k = [ x ]
    if x == 1 then
        Ref.set r k

    k
```

The fold hands `k` back as `acc`; the second push edits the list that `r` holds.

- **Rule:** §6.8: where the callee hands the function its own answer, "the answer must be the function's
  own: made by it, or a parameter handed `free` that it did not let go". The text asks "did not let go"
  of a parameter only. A cell the function made and let escape is not its own either.
- **Code:** `Frame.zig:3954`, in `answerOwn`: `.fresh => {}`, the `escaped` bit not read. The `.param`
  case two lines below refuses on `flag_e`. **Both the rule's wording and the code are wrong.** It traps
  for `List.foldl`, `List.foldr`, `Dict.foldl`, `Set.foldl` and a fold the program writes, with `Ref.set`,
  `Ref.modify` and `Ref.update` as the escape, and with `List.push` and `List.set` as the write.
- **v1:** refuses this program (`Ref.set`). It accepts the `Ref.modify` and `Ref.update` variants and
  traps (20 programs). **v2:** refuses all.

### 4.6 `derived-method`: a derived method calls a writing method

```beni
-- Tm.beni
pub type T
    = T (List Int)

pub eq : T, T → Bool
eq x y =
    case ( x, y ) of
        ( T a, T b ) →
            List.length (List.push a 0) == List.length b

-- Main.beni
go n =
    xs = [ n ]
    r = if ( T xs, 1 ) == ( T [ 5 ], 1 ) then "eq" else "ne"
    r ++ "/" ++ show xs
```

`Tm.eq`'s push is accepted on ground `param`: it rests on its callers. Its caller is the tuple's derived
`eq`, which no walk sees. The push edits `xs` in place, and `show xs` reads it.

- **Rule:** §6.11: "a function the compiler derives (`eq`, `compare` of a type that declares none) reads
  its operands and calls its evidence". A derived method also calls, directly, the well-known method of
  each part's type (`static-dispatch-spike.md` §3.3: derivation is structural and recursive). Those calls
  are not evidence of the site. So the claim that every call of a writing method is judged somewhere is
  false here. **The rule's argument is wrong.**
- **Code:** `Frame.zig:2847`: `.derived, .ext_derived` give `target = .reads`, which reads the operands
  and stops. `Frame.zig:2892`, in `evidenceTerm`: a `.derived` term names no declaration, and the walk
  goes on only into the term's arguments. For a tuple, record, `Maybe` or `Result` handed to
  `List.sort` or `List.member`, those arguments name `Tm.compare` or `Tm.eq`, and the call is refused.
  For a type of the program (`type W = W T Int`) they do not, and `List.sort` and `List.member` trap too.
  Every `==`, `≠` and `<` on a tuple, a record, `Maybe`, `Result`, a nested shape or `W` traps.
- **v1:** also accepts it, and traps (the production checker). **v2:** refuses, at `Tm.eq` itself
  (`comparison`).

## 5. Precision

The `dead` twins of all six faults are accepted. Common writes that I tried are accepted: `List.update`
of a list of new lists, a push in a fold, a field update of a record, `List.set` after `List.map` and
`List.sort`, a fold over a pair of accumulators, a page model pushed by `update`. Losses seen:

- `List.intersperse [ [ 7 ], [ 8 ] ] inner`, then a writing `List.map`: refused (`element`), though `inner`
  is at one place. The contract of `intersperse` cannot count.
- `List.sort` and `List.member` over a value whose `eq` or `compare` writes are refused also when nothing
  reads the list later. That is right in spirit: such a method is a write the caller does not see.

## 6. What I did not cover

- Markup holes (excluded), and the `browser-inline` and `browser-tea` platforms in a real browser. The
  entry faults use `tests/platforms/page`, whose runtime does what §6.13 describes.
- `settle`, `subscriptions` and commands of `browser-tea`. A command that holds a new model list would
  meet §4.2.
- Fibers and suspension (`Task.spawn`, `Io.run`): no program here suspends.
- Schemas beyond one `via` conversion; `codec` as a well-known method (`methodCall` reads it as
  `.reads`, like a derived method, so it may have the hole of §4.6).
- Resource limits other than the closure depth: I did not build a group past 64 rounds or a `flow`
  past 16.
- Release builds.

## Sources

`docs/design/ownership-v3-kernel.md` §1, §5, §6.8, §6.11, §6.13; `src/own3/Frame.zig` (`entryCall`,
`answerOwn`, `methodCall`, `evidenceTerm`); `static-dispatch-spike.md` §3.3; `tests/platforms/page`;
`bench/ownership-sweeps/README.md`.
