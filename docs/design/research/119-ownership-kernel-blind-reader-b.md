# 119. A blind test of the ownership kernel: reader B

*2026-11-13. Commit tested: `ca2fc63410` (branch `ownership-v2-design-review`, pull request #2451), with
`--ownership=v3`. This is the second of two independent blind readings of `ownership-v3-kernel.md`. It
did not read the earlier testers' reports, generators or fault folders, the other reader's work, or
the black-box tests of v3.*

## 1. Result

**No soundness fault was found.** In about 47 800 programs, v3 accepted 6 182, and each of them printed
what the plain build printed. No program trapped on a stale read.

**Two faults of another kind were found.** In each, v3 does not finish. A compile that never ends is a
`CRASH` in the runner's table. Neither fault is a wrong verdict. The first blocks an ordinary program. The
kernel's §8 says that every limit of the checker falls to the pessimistic side; these two have no limit.

1. **A chain of writes costs time that doubles with each write.** A function that writes one list 30
   times in a row, each write on the version that the last one answered, takes 35 seconds. With 32
   writes it takes more than two minutes. v1 and v2 take 20 ms.
2. **A type whose parts repeat costs time that grows with the number of its paths.** The corpus
   program `tests/corpus/run/EvidenceDagBuildDepth32` never finishes under v3. It has no list in it.
   v1 refuses it with its loud size limit. v2 takes 13 ms.

Beside the test, the sweeps found two shapes that **v1**, the production checker, accepts and that then
read a stale list (§4.3). v2 and v3 refuse both.

## 2. What was probed

The work started from the language, not the code. Each way that two names can reach one list, or a read
can move past a write, got a family of programs. The generator is
`bench/ownership-sweeps/blind4b.mjs`. Every program has a twin: `live` reads the old value after the
write (v3 must refuse it or print the same), `dead` does not (it is safe, so a refusal is a precision
loss). The random family has one kind, `any`: whatever v3 accepts must print what the plain build
prints.

| Family | Programs | What it probes |
|---|---:|---|
| `hold` | 1 280 | one list `xs` and a holder `h` of it, made in 40 ways: a constructor; a tuple; a record; a record with a row variable (`{ r \| k }` set, and a getter over `{ r \| l }`); `Maybe.map`, `Maybe.andThen`, `withDefault`; `?` on a `Result`; `Result.andThen`; a `Dict` (`get`, `values`); a closure; a partial application `pick xs _`; a closure in a record; a method of a user type (`b.items`); a `where` method; a type of another module, open and opaque; a recursive tree; a list of a recursive type; `foldl` and `foldr` accumulators; `List.map` with an identity; `sortBy`; `filter`; `reverse`; `concat`; `if`; `case`; a top-level and a local recursive function; the pipes `▷` and `◁`; `drop 0`; a prepend and its rest view; `[ x, …r ]` after a match of `[ x, …r ]`; an init view `[ …i, _ ]`; a function that answers `( l, l )`. Eight writers (`push`, `set`, a spread, `++`, a callee that writes, a pipe, a method `t.push 9`, `List.update`), on `xs` or on the list `h` gives back |
| `cell` | 32 | a list put in a `Ref` (`make`, `set`, the answer of `update` and `modify`) and edited through the cell (`update`, `modify`, `get`) while its first name is read |
| `cb` | 264 | callbacks of `core/` that write the element they are handed: `List.map`, `indexedMap`, `filterMap`, `foldl`, `foldr`, `update` at 0 and 1, `Maybe.map`, `Dict.map`, `Dict.foldl`, `sortBy`; each over a list with one array at two places, a list beside an outer name, and a list of apart arrays |
| `dup` | 800 | one array at two places of a list, made in 50 ways: a literal; `concat`; `++`; spreads; `push`; a prepend; `insertAt`; `set`; `swap`; `pop`; `removeAt`; `slice`; `take`; `drop`; `reverse`; `sortBy`; `sortWith`; `filter`; `filterMap`; `map`; `indexedMap`; `foldl`; `foldr`; `intersperse`; `concatMap`; `map2`; `initialize` and a fold whose callback answers a captured list; `Dict.values` after `insert`, `fromList`, `map`, `update` and `union`; `Maybe.map`, `Maybe.map2`; `Result.combine`, `Result.map2`; `partition`; `unzip`; a generic pair function; a record with a row variable; local and top-level recursion; `case`; `List.update` whose callback answers a captured list; a tuple and a `Maybe` taken apart by `case`. Eight writers edit the elements (`update` at 0 and 1, `map`, `indexedMap`, `foldl`, and three list patterns) |
| `mod` | 192 | the same through generic helpers of another module, so that each contract crosses the module as label paths: pairs, a swap, a two-field constructor, a tree, a record with a row variable, a recursion, `repeat`, and functions that run a callback once or twice |
| `size` | 28 | one list written 11, 19, 23 and 39 times in a row by six writers; a type with repeated halves, 3 to 6 levels |
| `rand` | 4 000 | seeded random blocks of 6 to 14 bindings over lists, lists of lists, pairs, records, `Maybe`s and functions, built by writes, constructions, projections, patterns, branches, helpers, lambdas, partial applications and callbacks of `core/`; each prints a random subset of its names |

Beside the generator:

- the whole `tests/corpus/run/` corpus, 1 110 programs, built plain and under v3 (§3.2);
- two more random runs of 20 000 programs each, seeds 1 to 20 000 and 20 001 to 40 000 (the second
  with seven more makers: list patterns that bind two elements, a `case` on a pair, callbacks that capture,
  `sortBy` and `filterMap` over lists of lists);
- about 100 programs written by hand, for the rules that the families do not reach: `Deferred`,
  `Random.Pcg` generators (a generator that answers one captured list three times), top-level function
  values, partial application at the top level, forward references in a block, a recursive type that
  holds its own list (`[ …a, T a ]`), the empty literal `[]` in a function, predicates that write their
  element (`filter`, `filterMap`, `partition`, `sortBy`, `any`, `all`, `sortWith`, `concatMap`, `map2`,
  `Dict.filter`).

Commands (the generator writes the programs and a `LIST`; the runner is the folder's `run.mjs`):

```sh
node bench/ownership-sweeps/blind4b.mjs <out>/all
BLIND4B_FROM=1 BLIND4B_RANDS=20000 node bench/ownership-sweeps/blind4b.mjs <out>/r2 rand.
BLIND4B_FROM=20001 BLIND4B_RANDS=20000 node bench/ownership-sweeps/blind4b.mjs <out>/r3 rand.
node bench/ownership-sweeps/run.mjs --beni=<ReleaseSafe beni> --checker=v3 --jobs=16 --tmp=<disk> <out>/all
```

`BLIND4B_RANDS` (default 4 000) and `BLIND4B_FROM` (default 1) set the random family. The beni was a
ReleaseSafe build of `ca2fc63410`.

## 3. The verdict table

### 3.1 The generator

| Family | Twin | Programs | SAME | REFUSED | CRASH | TRAP or DIFF |
|---|---|---:|---:|---:|---:|---:|
| `hold` | live | 640 | 0 | 640 | 0 | 0 |
| `hold` | dead | 640 | 616 | 24 | 0 | 0 |
| `cell` | live | 16 | 0 | 16 | 0 | 0 |
| `cell` | dead | 16 | 0 | 16 | 0 | 0 |
| `cb` | live | 132 | 0 | 132 | 0 | 0 |
| `cb` | dead | 132 | 68 | 64 | 0 | 0 |
| `dup` | live | 400 | 0 | 400 | 0 | 0 |
| `dup` | dead | 400 | 165 | 235 | 0 | 0 |
| `mod` | live | 96 | 0 | 96 | 0 | 0 |
| `mod` | dead | 96 | 45 | 51 | 0 | 0 |
| `size` | any | 28 | 18 | 3 | 7 | 0 |
| `rand` | any | 4 000 | 374 | 3 626 | 0 | 0 |
| **all** | | **6 596** | **1 286** | **5 303** | **7** | **0** |

The seven `CRASH` lines are the runner's 120 s limit: the six chains of 39 writes (fault 1) and the type of
six levels (fault 2). The three `size` refusals are the chains with a branch at 11, 19 and 23 writes,
refused rightly: a branch can leave the older version in place. Of the `cb` dead twins, the 44 of shape
`dup` hold one array at two places and are not safe; v3 refuses 40 of them and accepts the 4 that write
only the head.

The first three families ran under v1 and v2 too, on an earlier copy of the generator (`dup` with two
broken makers, and with the 88 `cb.dup` programs in its set):

| Set | Programs | v1 SAME / REFUSED / TRAP | v2 SAME / REFUSED / TRAP | v3 SAME / REFUSED / TRAP |
|---|---:|---|---|---|
| `hold`, `cell`, `cb` | 1 576 | 668 / 908 / 0 | 663 / 913 / 0 | 684 / 892 / 0 |
| `dup` and `cb.dup` | 872 | 251 / 608 / **13** | 173 / 699 / 0 | 164 / 708 / 0 |
| `mod` | 192 | 72 / 120 / 0 | 67 / 125 / 0 | 45 / 147 / 0 |

v1 traps on 13 programs that v2 and v3 refuse (§4.3).

### 3.2 The corpus and the random runs

| Set | Programs | SAME | REFUSED | PLAINFAIL | BOTHFAIL | CRASH | TRAP | DIFF |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `tests/corpus/run/` | 1 110 | 673 | 304 | 106 | 26 | 1 | 0 | 0 |
| random, seeds 1–20 000 | 20 000 | 2 390 | 17 610 | 0 | 0 | 0 | 0 | 0 |
| random, seeds 20 001–40 000 | 20 000 | 1 833 | 18 167 | 0 | 0 | 0 | 0 | 0 |

A corpus `PLAINFAIL` is a program that needs another platform or flag than the runner gives
(`--platform=node`); a `BOTHFAIL` is a program whose expected output is a failure. The one `CRASH` is
fault 2.

## 4. The faults

### 4.1 Fault 1: a chain of writes costs time that doubles with each write

```beni
go : Int → String
go n =
    v0 = [ n ]
    v1 = List.push v0 1
    v2 = List.push v1 2
    -- … one line for each write, 40 in all
    v40 = List.push v39 40
    String.fromInt (List.length v40)
```

The full program is `blind4b-faults/version-chain.hang/Main.beni`; its twin with 12 writes,
`version-chain.ok`, builds in 50 ms and prints the same as the plain build.

| Writes in a row | 18 | 22 | 26 | 30 | 32 |
|---|---:|---:|---:|---:|---:|
| v3, `List.push` | 57 ms | 191 ms | 2.2 s | 35 s | more than 120 s |

The time doubles for each added write. Every writer does it: `List.set`, a spread `[ …v, i ]`, `++`, and
a user function that writes its parameter, each 600 ms at 24 writes. A chain with a branch,
`v = if c then List.push u i else w`, takes 18 s at 26 bindings. A chain broken by `List.copy`, `reverse`
or a plain alias takes 50 ms. A chain of 30 writes in one function is an ordinary program: a list built
step by step, or a model updated field by field.

**Rule.** §5.1 (new names) and §8 (resource limits). §5.1 is right: a callee that writes a location and
answers it gives the result a new name, and the old names carry the time of that call. §8 says that each
limit falls to the pessimistic side. Here the work has no limit and no bound.

**Code.** The run of a `version` entry is closed already: `listOf` (Frame.zig:2068–2076) and `apply`
(through `expandSrcs` and `oldNames`, Frame.zig:3221–3296) copy into the run of each new version the
leaves of its base, and `rootLeaves` (Frame.zig:737) gives a version's own atom with its whole run. So
the run of write *n* holds the names of writes *n − 1*, *n − 2*, … 0. Three functions then recurse into the
run of each atom of a run, though the run holds those atoms already:

- `markAtom` (Frame.zig:1220), which `demand` calls for each written atom and `finish` for each read one;
  its comment says "the run of a `version` or `taken` entry holds atoms of roots made before its own, so
  the recursion ends", and it ends, after 2ⁿ steps;
- `groundOf` (Frame.zig:1444), for each accepted line;
- `atomSrcs` (Frame.zig:2674), for each atom of the result in `finish`.

The cost of one call on write *n* is T(n) = 1 + T(n − 1) + … + T(0) = 2ⁿ. **The code is wrong, not the
rule.** Since the run is closed, one level of the run is enough; a visited set would do as well.

A check on a scratch copy (not committed, nothing under `src/` changed): with the recursion of `markAtom`
alone cut to the run's non-local atoms, 30 writes still take 44 s in a Debug build; with that of
`groundOf` cut too, they take 270 ms. So `groundOf` carries most of the cost. `atomSrcs` has the same
shape and runs when a chain's last version is the function's result.

**v1 and v2.** Both accept the program and print the same as the plain build, in 16 ms (v1) and 15 ms
(v2), at 30 writes and at 250.

### 4.2 Fault 2: a type with repeated halves costs time that grows with its paths

```beni
import Node exposing (Program)


w1 x = ( x, x )


w2 x = w1 (w1 x)


w3 x = w2 (w2 x)


w4 x = w3 (w3 x)


w5 x = w4 (w4 x)


w6 x = w5 (w5 x)


main : Program
main = Node.print "F"
```

This is `blind4b-faults/dag-type.hang/Main.beni`, cut down from the corpus program
`tests/corpus/run/EvidenceDagBuildDepth32`. `w6`'s result is a tuple 32 levels deep whose two halves are
one type at each level: 63 distinct types, 2³² paths. No function is called and no list is made. The twin
`dag-type.ok` stops at `w4`.

| Definitions | `w4` | `w5` | `w6` |
|---|---:|---:|---:|
| levels, paths | 8, 256 | 16, 65 536 | 32, 2³² |
| v3 | 51 ms | 8.3 s | more than 5 minutes |

**Rule.** §4.1 and §8. §4.1 gives a location to each path of labels through the place graph. A type
whose parts repeat has a number of paths that grows as two to the power of its depth, though its place
graph is small. §8 lists no limit on the number of locations, so nothing stops the walk. **The rule's
argument is incomplete**: a location per path has no bound, and §8 needs a loud limit for it. v1 has
one.

**Code.** `Loc.Table.layoutOf` (Loc.zig:301) builds the layout of a place with `visit` (Loc.zig:336),
which goes down every step of every place, so it walks the place graph as a tree. `addEntry`
(Loc.zig:324) then looks for the location in all the entries made so far, so each layout costs the
square of its size: 2³² entries at `w6`.

**v1 and v2.** v1 refuses the program in 2.7 s with its loud limit:
`Main.w5's ownership summary needs 1276786 entries, more than the checker's limit of 262144`. v2 builds
it in 13 ms.

### 4.3 Beside the test: two holes in v1

v1 (`src/own/`) is not under test, but the family `dup` found two shapes that it accepts and that then
trap on a stale read. v2 and v3 refuse both.

```beni
e0 = [ n ]
r = List.update [ e0, [] ] 1 λ_ → e0
s = List.update r 0 λl → List.push l 9
```

`List.update`'s callback answers `e0`, which the list holds at index 0 already, so `r` holds one array at
two places; the write of element 0 changes both. The second shape is the same with
`Dict.values (Dict.map (Dict.fromList [ ( 1, 0 ), ( 2, 0 ) ]) λ_ _ → e0)`. The programs are
`blind4b-faults/v1-update-answer.live` and `v1-dict-map.live`, with safe twins that answer a new list
(`.dead`; v1, v2 and v3 accept `v1-update-answer.dead`, only v1 accepts `v1-dict-map.dead`). In the
generator they are `dup.updateTo.*.live` (5 writers) and `dup.dictMap.*.live` (8 writers).

## 5. Precision

These safe programs are refused. Each is a real-looking shape.

- **Two elements bound by one list pattern are one location.** `case r of [ x, y ] → [ List.push x 9, y ]`
  is refused (`later-use`), and so is `[ x, …rest ]` with the rest kept, though `r`'s two elements are
  two arrays. 150 of the `dup` family's dead twins (each of 50 makers, with 3 pattern writers) and 36 of
  `mod`'s.
- **The result of a `core/` function that builds a list from parts has every element at two places.**
  A write of an element of the result of `concat`, `intersperse`, `initialize`, `concatMap`, `map2`,
  `partition`, `unzip`, `sortBy`, `Result.combine` and `Dict.values` (after `insert`, `fromList`, `map`,
  `update`, `union`), and of a fold whose callback answers a captured list, is refused (`element`), with
  the parts apart. 85 of the `dup` family's dead twins (17 makers, 5 writers). Through a module, the
  same for a tree's values, a recursion that pushes one of two arguments, and a callback that answers a
  captured list.
- **A callback of `Dict.map` or `Dict.foldl` that writes its value is refused** (`disjoint`), with the
  values apart.
- **A list in a `Ref` is never edited in place**: `Ref.update r λl → List.push l 9` is refused
  (`supply`), and the answer of `Ref.get` and `Ref.modify` is never `own`. The kernel's §0 leaves cells to
  a later stage, so this is expected.
- **The answer of a `where` method, or of a function a call answered, is `unknown`.** A write of
  `itemsOf b` (`where a.items : a → List Int`) or of `g 0` where `g = mk [ n ]` is refused.
- **Random blocks**: 9 to 12 % of the random programs are accepted. Most refusals there are right (the block
  prints a name it wrote); the share of the rest was not measured.

## 6. What was not covered

- The browser platforms: the entry (`Browser.program`, kernel §6.13), `send` and markup in a page. The
  runner builds for `node` only. Markup on `node` (`Ssr.render`) was not probed, and the markup rule's
  open decision was left alone as asked.
- Fibers that really wait: `Io.run`, `Task.spawn` with `sleep`, `Deferred.wait`, `Queue`, `Semaphore`.
  A program whose `main` waits does not build on `node` without `Io.run`, and none was written.
- Schemas, `Json` codecs and `Binary`.
- Local functions that call each other in a cycle of more than two, a recursive group of declarations
  past its 64 rounds, a flow deeper than 16, and evidence nested past 8: the limits of §8 were read, not
  driven.
- Release builds (`--release`).
- More than two modules, and a module whose contract is read through a third.

## 7. A note on blindness

All the families and every run above were made before this note. While preparing the push, a diff of the
branch showed the new row that reader A added to `bench/ownership-sweeps/README.md`, which names the
corners of that reader's generator. Nothing was probed after that, and no file of reader A was opened.

## 8. Files

- `bench/ownership-sweeps/blind4b.mjs`: the generator.
- `bench/ownership-sweeps/blind4b-faults/version-chain.hang`, `version-chain.ok`: fault 1 and its twin.
- `bench/ownership-sweeps/blind4b-faults/dag-type.hang`, `dag-type.ok`: fault 2 and its twin.
- `bench/ownership-sweeps/blind4b-faults/v1-update-answer.live`, `.dead`, `v1-dict-map.live`, `.dead`:
  the two holes of v1 (§4.3) and their twins.
