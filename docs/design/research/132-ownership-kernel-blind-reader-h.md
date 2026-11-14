# 132 — The ownership checker v3: a ninth blind test (reader H)

*Research report, 2026-11-14. A blind soundness test of the prototype ownership checker v3
(`src/own3/`, `--ownership=v3`) at commit `f632c907b5` (branch `ownership-v2-design-review`, pull
request #2451). The reader did not read research reports 110 to 131, the earlier blind generators,
their fault folders, the v3 black-box tests, the corpus fixtures with a `.sanitize-lists-v3` file,
or the diary from 2026-11-12 on. Nothing under `src/` was changed. This report is not normative.*

## 1. The verdict

**No fault was found.** No program that v3 accepted printed something other than the plain build,
and none trapped under `--sanitize-lists`. No build panicked a ReleaseSafe compiler. No v3 check
took more than 0.3 s. The same corpus programs gave the same bytes at `--jobs=1` and `--jobs=8`.

| Probe | Programs | SAME | REFUSED | LIMIT | TRAP | DIFF | CRASH | PLAINFAIL |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `rand.*`, first version (seeds 1000–3999) | 3 000 | 467 | 2 533 | 0 | 0 | 0 | 0 | 0 |
| `rand.*` (seeds 10000–13999) | 4 000 | 741 | 3 259 | 0 | 0 | 0 | 0 | 0 |
| `rand.*` (seeds 20000–25999) | 6 000 | 1 082 | 4 918 | 0 | 0 | 0 | 0 | 0 |
| `alias.*` (seeds 0–2999) | 3 000 | 1 055 | 1 945 | 0 | 0 | 0 | 0 | 0 |
| `alias.*` (seeds 20000–22999) | 3 000 | 1 071 | 1 929 | 0 | 0 | 0 | 0 | 0 |
| `tea.*` (`browser-tea` pages), first run | 144 | 18 | 120 | 0 | 0 | 0 | 0 | 6 |
| `tea.*`, final run | 144 | 18 | 126 | 0 | 0 | 0 | 0 | 0 |
| `hand.*` | 69 | 15 | 54 | 0 | 0 | 0 | 0 | 0 |
| corpus, one v3 build each (no run) | 2 243 | — | — | — | — | — | 0 | — |
| corpus `run/`, `--jobs=1` against `--jobs=8` | 1 110 | 1 110 equal | | | | | | |

The six `PLAINFAIL` pages were a fault of the generator (an event written with brackets that the
parser does not take). It is fixed, and in the final run the six pages are refused, as a message
is never `own` (kernel §6.13).

In all, 19 357 generated and hand-written programs were judged: 4 467 accepted, 14 884 refused
and 6 not built, with no fault.

`blind9h-faults/` is not made: there is no fault to put in it.

## 2. What was probed

The beni used is a ReleaseSafe build of `f632c907b5` (`zig build -Doptimize=ReleaseSafe`, Zig
0.17.0), and Node 24.19.0. Each program went through `bench/ownership-sweeps/run.mjs` with
`--checker=v3`: a plain build, then a build with `--ownership=v3 --ownership-everywhere
--sanitize-lists`, both run and compared.

```sh
node bench/ownership-sweeps/blind9h.mjs <out> [filter]
BLIND9H_RANDS=6000 BLIND9H_FROM=20000 BLIND9H_ALIASES=3000 node bench/ownership-sweeps/blind9h.mjs <out>
node bench/ownership-sweeps/run.mjs --beni=<safe beni> --checker=v3 --jobs=16 --tmp=<dir> <out>
```

### 2.1 Random typed programs (`rand.*`)

One function `go` binds 6 to 14 values, each made by one of about 110 operations from the values
before it. The types are a list, a list of lists, a record of two lists, a pair, a `Maybe`, a
function of `⊤`, a constructor with methods, a recursive tree, a record that holds a function and a
generic record. The operations are the writes of `core/`, about 45 helpers (generic identity and
choice, folds, recursion that swaps its two lists, closures that keep a list, a callback runner, a
rest view, `Dict`, `Ref`, functions over a row, a tree walker, methods by dot-call), lambdas, `if`,
`case` and record update. A value is used by one later operation, except with a seeded chance of
5, 15 or 30 %. A random subset of the names is printed at the end. Half the programs keep the
helpers in a second module.

The first sweep used an earlier version, with seven types and 70 operations, so seeds 1000–3999
of the generator in the folder are not its programs. The two later sweeps use the generator as it
is in the folder.

### 2.2 Generic aliases (`alias.*`)

This family is for the adapter memo of `own2/Groups.zig` that v3 calls (kernel §8, *The code of
own2 that v3 calls*): a kept reading of an alias for one list of arguments. One value has a type
written with nested generic aliases — `Box a`, `Pair a b`, `Twin a = Pair a a`, `Deep a = Box (Twin
(Box a))`, `Tri a b c`, and a row alias `Holds r = { r | held : List Int }` — up to five deep, with
leaves `List Int`, `List (List Int)` and `Int`. Three decoy functions read the same aliases at other
arguments before `go`. The program reads one list at a path, writes one list at a path, and prints.
The write is direct, through a generic identity, through a join of two values of the type, or
through a pair. Half keep the aliases and the generic functions in a second module.

A layout that a wrong reading made too small would hold no cell at the written path. The write
would then have no atom, and the read at the same path would trap. Every `live` program (the read
path meets the written one) was refused, and every `apart` and `dead` one was accepted.

### 2.3 Pages (`tea.*`)

144 `browser-tea` sandbox pages. `update` writes `model.items` in place on `Add` (a push, a set or
a pop). `Save` first keeps a value made from `model.items` in `model.saved`, by one of 24 savers: the
list itself, a helper of a second module, a generic identity, `List.drop` at 0, a
prepend of a rest view, a spread, a fold, a `Dict`, a `Maybe`, a record, a pair, a closure, a
choice, a pattern that rebuilds the list, a `Ref`, the list from `init`, the model in a pair, the
message, and three that copy (`List.copy`, `List.map`, `List.take`). The steps press Save, then Add
two times. Every saver that shares the array is refused at the entry; the three copies are accepted
and print the same.

### 2.4 Hand-written probes (`hand.*`, and by hand)

- **A schema's constructor** (kernel §6.14, the newest table): called, with `_`, as a value through
  a generic `apply`, mapped by `List.map`, and in a print; then a write of the payload's list.
  Each write is refused (`unknown`, or `escaped` after the print).
- **One cell at two positions** of a list made by 16 functions of `core/` (`map`, `repeat`,
  `initialize`, `indexedMap`, `filterMap`, `foldl`, `foldr`, `concatMap`, `Dict.values`,
  `Dict.map`, `sortBy`, `reverse`, `++`, `Dict.foldl`, `map` over `range`, `map2`), then
  `List.update` of one position with a writing callback. Each is refused.
- **The exception of kernel §4.4 (`alternatives`)**: a `List.update` whose callback answers
  another element of the same list, so that one cell is at two positions; then a write of one.
  Refused (`element`).
- **`Ref`**: `update` and `modify` with a writing callback, with and without a holder of the old
  content. Refused.
- **Fibers**: `Task.spawn` and `Task.scope` whose body reads a list after a wait, while the main
  fiber writes it; `Task.par` of a writer and a reader of one list; `Task.forEach` over one list
  at two positions. Each is refused (`forEach` for its own cause, §4 item 3); `par` of two writers
  of new lists is accepted.
- **The lost answer of kernel §8** (`answerOfCode`, `resolve`): closures that answer the closure
  before them, 4, 8, 9, 10, 13 and 20 deep, with a write of the first one's list. Refused at
  every depth.
- **The check of kernel §6.14** (`Check.checkCovered`): code that no call reaches — an unused
  local function, two that call each other, an unused lambda, a lambda in an arm no value takes,
  a local function inside a lambda and inside a constant, return-type dispatch. No build
  panicked.
- **A schema's `via`** whose conversion's `backward` writes its list (a top-level function and a
  lambda), then a print and a read of the list: refused at `Schema.conversion` (`call`).
- **A derived `eq`** of a record that holds a type of a second module whose own `eq` writes its
  operand's list, then a read of the list: refused (`later-use`).
- **A prepend that gives back its base's array** (`List.cons` when the element is the one before
  a view): refused.
- **`--library`** (by hand, not in the generator: `run.mjs` runs no library): an exported writer,
  a constant record of functions that holds a writer, and a function that answers a writer. All
  three refused at the export.
- **Shared empty lists** (by hand): two calls of a function that answers `[]`, and two `List.drop`
  past the end, then a write of one. Accepted and the same: each `[]` is a new array.

### 2.5 The final sweep

The final sweep is the generator as it is in the folder, with `BLIND9H_RANDS=6000
BLIND9H_FROM=20000 BLIND9H_ALIASES=3000`: 6 000 `rand.*`, 3 000 `alias.*` and the 144 `tea.*` pages,
9 144 programs, at `--jobs=16`. The 69 `hand.*` probes ran on their own. Of the
safe twins, 36 of 553 `rand.*` programs were refused, and none of the 1 071 `alias.*` programs.

### 2.6 Crashes, time and determinism

- **Every corpus program**, one v3 build each with the ReleaseSafe compiler: `run/`, `regress/`,
  `writes/`, `ownership/`, `emit/`, and `browser/` (`tea/` on `browser-tea`, `inline/` on
  `browser-inline`, `dom/` on `browser`, the rest on `tests/platforms/page`), 2 243 programs.
  No panic, no exit code above 1, no build above 289 ms.
- **Determinism**: the 1 110 programs of `run/` built at `--jobs=1` and at `--jobs=8`. The
  diagnostics and every output file were equal.
- **Examples**: `bike-wars`, `steer` and `sternhalma` are accepted whole; `conduit` has 16
  refusals (§4). v3 took at most 85 ms of each build.
- **The step budget** (kernel §8): one function with N statements that each write a new list
  literal in one arm, and N reads in the other arm, nested 2 to 100 levels deep. The pairs of a
  write and a read in two arms are not counted (`compatible` is tested before the step), but they
  cost little: N = 1 000 at depth 40 took 69 ms of v3. At N = 2 000 the declaration passes
  33 554 432 units and is a loud `ownership_limit`: the pairs of writes and later reads inside one
  arm are counted, and they are N²/2.

## 3. Rules against the code

I read the kernel and these parts of the code: `Check.walkDecl`, `walkSchema`, `walkExports`,
`solveGroup`, `namesCode`, `checkCovered`, `wordedContract`, `wordedFn`; `Frame.flow`, `FlowKey`,
`judge`, `flowCode`, `defaultParams`, `mention`, `walkHeld`, `walkExported`, `compatible`,
`escape`, `noteEscape`, `otherReaches`, `demand`, `finishDemands`, `alternatives`, `lostAnswer`;
`Enforce.checkModule`; `own2/Hoists.zig`; the channel in `js/Emit.zig`. For each, I looked for a
negative fact that is assumed. Each one I found has a positive source:

- **`mention`** (`Frame.zig:1973`) sends every function value that an expression gives in value
  mode to the `top` use. So a function that a constant, a record, a pair, a non-function
  parameter, a tail position or `Schema.mapping`'s `toHost` receives is judged at `top`, and a
  writer there is refused. This is what makes `walkExports` skip a constant soundly, and what
  makes the `Js.from` in `Schema.conversion` lose its functions.
- **`Js.from` and `Js.to`** (`returned`) through `Js.Value`, which has no location, give an
  `outside` answer and no escape. A walked function of the form `Js.to (Js.from x)` would hide an
  alias. `Js` is fenced to core and the platforms, and I found no public function of either that
  answers its argument this way: each public cast I found (`Ref.get`, `Debug.log`, `toFloat`) is
  worded or carries no list.
- **The flow memo** (`Frame.zig:4292`) is cleared when the outer `flow` returns, so a kept
  judgment never crosses two points of the walk, and the escapes it would have recorded are at
  the same time and context.
- **Escapes have no time**: a write is refused for an escape before or after it, in any
  compatible context (`demand`, `Frame.zig:1738`). Only reads use the clock.
- **A module past a limit** publishes no write (`Hoists.Builder.finish`), and under
  `--ownership-everywhere` its limit line is an error. So a callee's write that rests on a caller
  in a stopped module is never used: the build fails first. The same holds for a module that
  `walkSchema` or `walkExports` did not reach.
- **`checkCovered`** skips a declaration that gave up, and a module past the layout limit; both
  publish nothing.

## 4. Precision

These safe programs are refused. They are real-looking shapes, not generated ones:

1. **`Dict.update` with a callback that writes the value** (`Maybe.map m (λz → List.push z 3)`),
   on a dictionary that nothing else holds: `supply: the function writes a parameter that the
   callee reads again or does not hand as its own`. This is the idiomatic edit of the keyed
   collection. `hand.dictupdate.precision.dead`, `hand.dictupdate2.precision.dead`.
2. **`Ref.update` and `Ref.modify` with a writing callback**, with no other holder: the same
   cause. `hand.ref.updold.dead`.
3. **`Task.forEach` with a callback that writes its element**, over new lists: `call: a function
   that writes its parameter goes where the checker does not follow it`. `hand.task.foreach.dead`.
4. **A write of a list read out of a schema constructor's payload**, just built: `unknown`.
   `hand.schemactor.*.dead`.
5. **`List.update` whose callback answers a copy of another element**: `element`, though the copy
   is new. `hand.alt.update.dead`.
6. **A long function**: 2 000 statements that each write a new literal list pass the step budget
   (§2.6), so the module authorises no write.
7. **`examples/conduit`**: 16 refusals, 12 of them a `send` of a constructor (`unknown`) and 4 the
   entry's model locations (`the runtime does not hand this as the function's own`).
8. **The random families**: 30 of 377 `dead` twins of `rand.*` in the second sweep and 36 of 553
   in the final one were refused; every `apart` and `dead` program of `alias.*` was accepted. A
   `rand.*` twin is `dead` by a test of names, so some of these may read the list through another
   name, and those are not safe.

## 5. What I did not cover

- `browser-inline` pages under the oracle: its plain build runs the v1 checker, which refuses a
  page that writes its model in place, so `run.mjs` reports `PLAINFAIL` for them.
- A `--library` build under the oracle: `run.mjs` runs `_main.mjs`, which a library build does not
  write. The three library probes were judged by their diagnostics only.
- `browser`'s `dom` lowering, `Browser.programs`, `Tea.element` with commands and subscriptions,
  `Html.map` and components in generated pages; markup on `node` (`Ssr.render`).
- `Json.decode` with a derived `codec`, and runtime schema composition (`Schema.record`,
  `Schema.converted`) under the oracle; I read the code paths instead (§3). A schema's `via` and a
  derived `eq` have two probes each (§2.4), not a family.
- Determinism across `--jobs` outside `tests/corpus/run/`.
- The LLVM build of the compiler.
