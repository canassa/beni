# Ownership sweeps

Eleven systematic generators of small beni programs, and one runner that judges a checker on them. Four were
written while ownership checker v2 was built. Each one sweeps one corner where v2 had soundness holes. The
last four, `function-values.mjs`, `wider-functions.mjs`, `answers-beside.mjs` and `aliased-arguments.mjs`,
were written for research report 112 (below). Report
111's prototype (`--ownership=v3`) never ran them. The first time it did, they found 153 programs that it
accepts and that then read a list after an in-place write (below).

## Use

```sh
node bench/ownership-sweeps/folds-callbacks.mjs /path/to/out/folds        # writes the programs and out/folds/LIST
node bench/ownership-sweeps/run.mjs --beni=zig-out/safe/bin/beni --checker=v3 --jobs=16 --tmp=/path/on/disk /path/to/out/folds
```

- The runner builds each program twice: plain (the oracle, no list edited in place) and with
  `--ownership=<checker> --ownership-everywhere --sanitize-lists`. It runs both outputs and compares them.
  Results go to `<outdir>.<checker>.txt`, one line per program. A rerun skips the programs that already have
  a line.
- A program with a `PLATFORM` file is built for the platform it names (a directory below the repository root), and one with a `steps` file is run as a page: `tests/browser/driver.mjs` drives it under happy-dom, and its transcript is the output.
- A generator takes an optional second argument, a filter: only the programs whose name contains it.
- Use a ReleaseSafe or ReleaseFast beni. A Debug one is several times slower. Point `--tmp` at a disk, not a
  RAM file system: each program writes two builds.

## Verdicts

| Verdict | Meaning |
|---|---|
| `SAME` | the checker accepts, and the output is the plain build's |
| `REFUSED` | the checker refuses (its first code and position follow) |
| `LIMIT` | the checker stops at its size limit |
| **`TRAP`** | the checker accepts, and the in-place build throws: a stale read. **A soundness hole** |
| **`DIFF`** | the checker accepts, and the output differs. **A soundness hole** |
| `CRASH` | the compiler fails |
| `PLAINFAIL` | the generated program does not build: a fault of the generator, not of the checker |
| `BOTHFAIL` | both runs fail |

The last part of a program's name is its twin kind:

- `live` and `kept`: the program reads the written list, or something that holds it, after the write. An
  in-place write is wrong, so the checker must refuse or print the same.
- `dead` and `none`: nothing reads it after the write. These programs are safe, and a refusal of one is a
  precision loss.

## The generators

| File | Programs | Corner |
|---|---:|---|
| `recursive-levels.mjs` | 16 131 | reads across recursive types: shape (one type, a cycle with a middle type, two or three types, a generic instantiated recursively, list, tuple and record holders inside the cycle) × holder (local, parameter, call result, capture, fold accumulator, field) × reader (point, deep, walker, call that returns a part, rest view) × live/dead |
| `folds-callbacks.mjs` | 30 300 | folds and callbacks: fold kind (`List.foldl`/`foldr`, hand-written tail and non-tail folds and loops, `Dict` folds, nested folds, `List.map`/`indexedMap`/`filter`, `Maybe.map`/`andThen`) × accumulator shape and edit × what the callback does (push, keep in `Task.soon`/`spawn`, a view, a `Ref`, hand it on, capture it) × callback origin (lambda, top-level, partial application, a generic call, a composition) × live/kept/dead |
| `callbacks-keep.mjs` | 720 | a function hands a value to a callback that its caller gives, then edits the value in place, while the callback kept it |
| `handed-back.mjs` | 2 592 | a callee runs a callback that writes what it captures, then hands it back (directly, in a record, tuple or `Maybe`, through `ident`), and the caller runs it again or passes it on |
| `function-values.mjs` | 1 960 | the ways a function value travels: carrier (compositions two and three deep, a type variable, a record, a tuple, a list, a `Maybe`, a cell, one of two functions, partial application, a function that answers the callback, a callback that answers a callback, a fold in a callback, mutual recursion, a local function that calls itself, hands itself on, or is called before it is bound) × runner (one call, two calls, two runs on one list, `List.foldl`, a hand-written fold, a nested fold, `List.map`) × act (write the handed list, write and keep it, hand a captured list to a captured writer, answer a captured list, answer the handed list) × live/dead |
| `wider-functions.mjs` | 354 | a function value whose type and its holder's type are two readings of one type: a function over a type variable (`a → a`, `List a → List a`, `x, a → a`; top-level, local, lambda) × holder (a parameter of a concrete type, run one time, two times or by a fold; a parameter of a type variable) × shape (a list of lists, a list of lists of lists, a pair, a record, a `Maybe`) × how the innermost list of the answer is written (`List.update`, or through a pattern) × live/dead |
| `answers-beside.mjs` | 240 | two sources of one result that can be one cell: callee (a pair of the answer of a function and the argument, of two calls, of two functions; a record; the elements of a list; through one more function; one level down; over a type variable; a handed function that makes the pair with a captured function; the elements of a list from two parts of one answer, from two functions and two arguments, or from two calls of one function) × what the function answers (its parameter, a new list, a captured list) × what the caller does with the two parts (both into one list and a write of one element; a write of one and a read of the other). Four callees have no function: the argument has one list at two places |
| `aliased-arguments.mjs` | 5 160 | one list at two places of what a call takes: how (two arguments; two items of a tuple, a record or a list; a local; a projection; an element of a list and an argument; a tuple that is one of several values; a tuple ten levels down; the control, two lists that are apart) × the callee's result (a pair, a swapped pair, a record, a `Maybe` and a list, a list, `List.append`, a spread, a list of lists) × the function between an input and a part (none; one or two functions that answer their parameter, a new list, or a captured list) × what the caller does (a write of one part and a read of the other, of the argument, or of nothing) |
| `blind2.mjs` | 1 202 | research report 114, a second blind test of first-order values: one list at two places of 19 shapes × 14 makers; a pipe `x ▷ e` whose callee or receiver writes; one list twice in the deep level of four recursive types; callbacks of `core/` that write an element; answers of `core/` made from a list. Its faults and their safe twins are in `blind2-faults/` |
| `blind3.mjs` | 417 | research report 115, a third blind test: one fresh list that reaches two places of a result through the answer of a function parameter (`answer`, `supply`), or reaches a function that keeps it (`handon`); a type's `eq` or `compare` that writes or keeps its operand; a `List.sortWith` comparator that keeps an element; one list at two places of a `Dict`; a prepend whose item is a literal. Its faults and their safe twins are in `blind3-faults/` |
| `evaluation-order.mjs` | 440 | research report 114 §7: one read and one write of a list in two parts of one construct that JavaScript evaluates in a known order: 42 constructs (the arguments of a call and of a constructor, tuple, list, record and record update literals, interpolation, operators, `&&`, a `case` and an `if`, `let` bindings, a lambda applied, a computed callee, `?` in three places, markup and `For`, pipes into a computed callee or receiver, spreads, `++`, methods) × write first or read first × `List.set` or `List.push` × two reads × live/dead |
| `blind4a.mjs` | 160 | research report 118, a fourth blind test (reader A): a derived `eq` or `compare` that calls the writing method of a part's type (8 shapes × 5 ops); a fold callback that answers a new list it let escape into a `Ref` (5 folds × 3 escapes × 2 writes); a page program whose `update` gets a model or a message that another holder keeps (10 cases, on `tests/platforms/page`). Its faults and their safe twins are in `blind4a-faults/` |
| `blind4b.mjs` | 6 596 | research report 119, a fourth blind test (reader B): one list and a holder of it made in 40 ways × 8 writers × which name is written; a list in a `Ref`; callbacks of `core/` that write the element they are handed; one array at two places of a list, made in 50 ways × 8 writers; the same through generic helpers of a second module; chains of writes and a type with repeated halves (`size`, two of them never end under v3); and seeded random blocks (`BLIND4B_RANDS`, `BLIND4B_FROM`). Its faults and their safe twins are in `blind4b-faults/` |
| `blind5c.mjs` | 226 | research report 121, a fifth blind test (reader C): the entry rule when `update` answers a pair and the model is a tuple; a function of the program's record with no known code (one of two functions, a call's answer, …) as `view` or `settle`; a closure made inside a hole of markup; a `For` row's or a `Show` body's parameter kept by an event; derived `eq`/`compare` through generic types of other modules; folds that answer one list at two places; a type at the location limit. Its faults and their safe twins are in `blind5c-faults/` |
| `blind5d.mjs` | 1 234 | research report 122, a fifth blind test (reader D), written as applications: The Elm Architecture on `browser` and `browser-tea` (`Tea.element`, `sandbox`, `document`, `Browser.program`, `hosted`), where a message, a handler, a row of `For`, a `Show`, a helper, `Html.map`, a subscription, `settle`, a command, the history or `init` holds a list of the model, and the record's function is given in nine ways; the model as a record, a pair, a triple or a constructor; markup rendered on `node` whose row function keeps its item; fibers, `Dict`, `Random`, `Ref`, `Json` and a type with methods in a second module. Its faults and their safe twins are in `blind5d-faults/` |
| `blind6e.mjs` | 238 | research report 124, a sixth blind test (reader E), written as applications: the entry where a function of the record takes the model as an extensible record or a type variable and keeps it (a bubbling handler, a `Sub.listen` body, a `Browser.hosted` `update` or `settle`, `Tea.document`); The Elm Architecture on `browser`, `browser-tea` and `browser-inline` with in-place writes and holders in rows, handlers, helpers, text holes and `Show`; markup on `node`; fibers that wait; a function that writes a list after it handed the list to its function parameter, reached through a `Ref` or as a command's body. Its faults and their twins are in `blind6e-faults/` |
| `blind7f.mjs` | 4 160 | research report 126, a seventh blind test (reader F): seeded typed random chains of 39 helpers (generic, row, tree, fold, `Ref`, `Dict`, a second module) between a list and its write (`BLIND7F_CHAINS`, `BLIND7F_FROM`); `Tree T` where `T` holds `List (Tree T)`; a function that writes a list after it handed it to its function parameter, run directly or from a default holder; The Elm Architecture on `browser-tea` with the model as a record, a row, a triple and a generically written triple against seven holders; a DAG of closures that the checker walks path by path (`BLIND7F_LEVELS`). Its fault and its twin are in `blind7f-faults/` |
| `bounded-walk.mjs` | 34 | research report 127: shapes that make a walk of the checker reach one thing by many paths, 24 levels deep (`BOUNDED_LEVELS`): a DAG of closures, two or three per level, called directly, from a `Ref` or by `List.map`; the same with a leaf that writes; closures that hand their parameter down one of three captured closures; closures that hand a new list down; closures that answer one of three captured closures' answers; the DAG of top-level functions, of records of functions and of `Ref`s of functions; a ring of mutually recursive local or top-level functions (`BOUNDED_GROUP`); a list under `Just` nested many times (`BOUNDED_DEPTH`). A checker bounded by design ends each in well under a second. The siblings that hung, and their twins, are in `bounded-walk-faults/` |
| `blind8g.mjs` | 121 | research report 128, an eighth blind test (reader G): a function that a `schema` declaration names in a `via` conversion (top-level, of another module, a partial application, both directions, a lambda, a walked value) and writes the list it is handed, then a print of a value read after or not, and the same in a page whose `update` saves its model; in-place model writes in pages on `browser`, `browser-tea` and `browser-inline` seen through `For` rows, class lists, helpers, arm `let`s and text holes; fibers, finalisers, `Ref`, `Queue` and `Dict` holders; non-regular and row types in recursive types; one list at many places of a list made by 18 functions of `core/`; two slow shapes (`BLIND8G_FIELDS`, `BLIND8G_ROUNDS`). Its fault, its twin and the slow programs with their controls are in `blind8g-faults/` |
| `blind9h.mjs` | 1 500 + 1 500 + 144 + 69 by default | research report 132, a ninth blind test (reader H): seeded typed random programs over ten types and about 110 operations, helpers in a second module for half (`BLIND9H_RANDS`, `BLIND9H_FROM`); one value of a type written with nested generic aliases, read and written at two paths, with decoys that read the aliases at other arguments (`BLIND9H_ALIASES`); 144 `browser-tea` pages whose `update` writes `model.items` in place after 24 ways of keeping it in `model.saved`; 69 hand-written probes (a schema's constructor, a `via` that writes, a derived `eq`, one cell at two positions of a list of `core/`, `Ref`, fibers, deep answers, code no call reaches). It found no fault; there is no faults folder |
| `blind10i.mjs` | 474 | research report 133, a tenth blind test (reader I), at the boundary: The Elm Architecture on `browser` with 26 holders of a list of the model (holes, helpers, `For` in four modes, `Show`, class and style lists, `Html.map`, components); the same pages on `browser-inline`, against a copy of the platform whose plain build copies; `browser-tea` commands and subscriptions that hold a list of the model; a `let` of a view, a helper's root or a component's root that the `dom` lowering keeps across renders, written in place; markup on `node` rendered before or after a write; codecs and schemas whose answer may share an array with their input; chains of writes (`BLIND10I_CHAINS`). Its two faults (a kept `let` written in place; a chain of writes slow past the budget) and their twins are in `blind10i-faults/` |

## Baseline: report 111's prototype

On pull request #2451 at `1692066993`, with `--ownership=v3`, a run of all four generators found 153 distinct
programs that the prototype accepts and that trap. `master`'s v2 refuses each of them. The names are in
`traps-v3-1692066993.txt`. They form two classes:

1. **129 programs: a nested fold whose callback is a composition.** The callback is built with `comp` and
   edits the accumulator: a push, a keep in `Task.soon`/`spawn`, a view (`List.drop`, `[ _, …rest ]`), a
   hand-on, a `Ref`, a capture. The edit is in place while the outer fold still holds the accumulator.
   (`folds-callbacks.mjs`, names `nest.acc.*.comp.*`.)
2. **24 programs: a closure handed back without a run, then run twice.** A callee answers a closure that
   writes a captured list through a local function, inside a `Maybe`, record or tuple. The caller runs it two
   times. (`handed-back.mjs`, names `zero.*.via`.)

Of the safe (`dead`) twins, the prototype refuses 48 %, and `master`'s v2 a little more on the same programs.

## Round 2: research report 112

The prototype was rebuilt around one rule for function values (`docs/design/research/112-ownership-prototype-function-values.md`).
On the rebuilt prototype each of the eight generators has 0 `TRAP`, 0 `DIFF` and 0 `CRASH`, and each of the 153
programs above is `REFUSED`. Report 112 §5 and §6 have the figures, the comparison with v2 by twin, and the
controls: report 111's prototype traps on 371 programs of `function-values.mjs`, and the prototype as it was
before the fixes of report 112 §6.3 traps on 38 programs of `wider-functions.mjs`, on 27 of
`answers-beside.mjs` and on 230 of `aliased-arguments.mjs`.

`function-values.mjs` and the first nine alias forms of `aliased-arguments.mjs` (3 870 programs) are blind
tests: each ran one time on a prototype that had not seen its programs (report 112 §6.2, §6.4). The other
two generators and the last three alias forms were written after the faults that they pin (§6.3, §6.5).
