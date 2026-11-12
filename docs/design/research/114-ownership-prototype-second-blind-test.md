# 114 — Ownership prototype: a second blind test

*Research report, 2026-11-12. It is not normative. It tests the prototype of research report 111
(`src/own3/`, `--ownership=v3`) at `e7c695049b` on branch `ownership-v2-design-review` (pull request #2451).
The tester did not read reports 111 to 113, `bench/ownership-sweeps/blind.mjs` or
`bench/ownership-sweeps/blind-faults/`. The tester read `src/own3/` and wrote the probes from that reading.*

## 1. Summary

The prototype accepts two kinds of program that then read a list after an in-place write. Both are classes,
not one-off bugs. Each has a minimal program and a safe twin in `bench/ownership-sweeps/blind2-faults/`.

1. **A pipe into a computed callee.** In `x ▷ e`, the compiler numbers the instructions of `x` before those of
   `e`. JavaScript evaluates `e` first when `e` is not a plain name: a field of a call, an `if`, a `case`, a
   tuple item, or the receiver of a method call. The prototype uses instruction numbers as the order of
   evaluation. So a write in `e` and a read in `x` look like "read, then write", and the write is accepted.
   28 of 28 live programs trap. v2 accepts all 28. v1 refuses all 28.
2. **One list twice in the deep level of a recursive value.** The deep level of a recursive type is one
   summary location. When one constructor argument puts the same list at two places of that location, the
   prototype does not see the duplicate. A callee that writes one place and reads the other is accepted.
   102 live programs trap. v2 refuses all 102. v1 refuses 94 and accepts 8.

The probes found no fault in the other first-order shapes: tuples, records, record updates, constructors, a
record alias's constructor (also as a function value), list patterns, `as` patterns, `?`, joins of `if` and
`case`, row-polymorphic records, top-level constants, empty literals, views, `Dict`, `Random`, and the answers
and callbacks of 33 functions of `core/`.

The main precision loss: one list at two places of a value makes both places unwritable, even when nothing
reads the second place. v3 refuses 136 such safe programs, and v2 accepts 134 of them.

## 2. What was probed, and how

**Reading.** The tester read `src/own3/` in full (Loc, Contract, Frame, Check, Enforce). The search looked for
two things: places where a value's cells become "no object" or lose a fact, and places where the walk's
order and the order at run time can differ.

**Hand probes.** 43 programs under `~/.cache/beni-agents/blind2/p/` (not committed): record alias
constructors direct and as a local function value, `case` on a constructor, `as` patterns, tuple and record
destructuring, record update, joins, `?` on `Maybe`, recursion that swaps its parameters, top-level constants,
`[]` literals and constant literals in functions, `[ …q ]`, `Dict.get`, `Dict.update` and `Dict.insert`,
`Random.constant`, `Random.map` and `Random.uniform`, row-polymorphic records (one and two levels), a
two-module program, the order of record fields, of record update fields, of alias constructor arguments, of
`case`, blocks and `?` in arguments, and the order of pipes. Two of them found the two faults. An ownership
word in app code is refused by the parser, so a contract cannot be stated by a user.

**The generator.** `bench/ownership-sweeps/blind2.mjs` writes 1 202 programs in five families:

| Family | Programs | What it covers |
|---|---:|---|
| `two` | 798 | 19 shapes with two list places × 14 makers × 3 uses (`ab`, `ba`, `dead`). The shapes: tuple, tuple pattern, record, record pattern, constructor, record alias constructor, the same through `Maybe.map` and a lambda, generic constructor, list pattern, `List.get`, nested tuple, `Maybe` pair, join, record update, and five recursive types (entry level and deep level of a list type, a tree with a list of children, a record in a cycle, a generic recursive type). The makers: in `go`, a callee that makes the list, a callee that is handed it once or twice, a fresh argument, one function further, a generic identity, a tuple taken apart, a constructor taken apart, one of two `case` arms, a recursive maker, a lambda run at once, a local function, `?` |
| `order` | 56 | pipe `x ▷ e`: 5 callee forms (field of a call, `if`, `case`, tuple item, method receiver) × 2 writes (`List.set`, `List.push`) × 3 reads (`show`, `List.get`, `List.length`) × live/dead |
| `deep` | 88 | 4 recursive types × 6 makers (a literal in a callee, a recursive `rep`, `rep` of a fresh list, one function further, built in `go`, `rep` in `go`) × use in `go` or in a callee × live/dead |
| `hof` | 50 | 25 functions of `core/` that hand a callback the elements of a container (`List.map`, `filter`, `sortBy`, `sortWith`, `partition`, `map2`, `foldl`, `update`, `Maybe.map`, `Result.map`, `Dict.map`, `Dict.update`, …), with a callback that writes the element × live/dead |
| `result` | 210 | 35 answers of `core/` made from `q` (copies, views, `q` itself: `slice`, `reverse`, `drop`, `tail`, `concat`, `append`, `[ …q ]`, `List.cons`, `Set.toList`, `Dict.get`, …) × length 0, 1, 2 × live/dead |

**Commands.** A ReleaseSafe compiler built from `e7c695049b` (`zig build -Doptimize=ReleaseSafe`):

```sh
node bench/ownership-sweeps/blind2.mjs <out>
node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v3 --jobs=16 --tmp=<dir> <out>
node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v3 bench/ownership-sweeps/blind2-faults
```

The oracle is `run.mjs`: a plain build against `--ownership=v3 --ownership-everywhere --sanitize-lists`.
v1 and v2 ran on the 130 trapping programs and on the 149 refused safe twins.

## 3. Verdicts

| Family | Twin | SAME | REFUSED | TRAP | DIFF | CRASH |
|---|---|---:|---:|---:|---:|---:|
| `two` | live (`ab`, `ba`) | 0 | 468 | **64** | 0 | 0 |
| `two` | dead | 130 | 136 | 0 | 0 | 0 |
| `order` | live | 0 | 0 | **28** | 0 | 0 |
| `order` | dead | 28 | 0 | 0 | 0 | 0 |
| `deep` | live | 0 | 6 | **38** | 0 | 0 |
| `deep` | dead | 44 | 0 | 0 | 0 | 0 |
| `hof` | live | 0 | 25 | 0 | 0 | 0 |
| `hof` | dead | 12 | 13 | 0 | 0 | 0 |
| `result` | live | 69 | 36 | 0 | 0 | 0 |
| `result` | dead | 105 | 0 | 0 | 0 | 0 |

No program failed to build plain. The 69 live `result` programs that print the same output are correct: their
answer is a copy, so the write in place does not reach `q`.

The 130 traps are in two classes. Section 4 has each.

| Class | Traps | v2 accepts | v1 accepts |
|---|---:|---:|---:|
| 1. Pipe into a computed callee | 28 | 28 | 0 |
| 2. One list twice in a deep level | 102 | 0 | 8 |

## 4. The faults

### 4.1 A pipe into a computed callee

`blind2-faults/order-pipe-callee.live`:

```beni
go : Int → String
go n =
    q = [ n, 2 ]
    String.join (List.map ([ List.length q ] ▷ (List.push q 9).append) String.fromInt) ","
```

The plain build prints `0,2,9,2`. The checked build traps: `List.length q` reads `q` after the push changed it.
The safe twin reads `[ 4 ]` instead of `q`, and the prototype accepts it.

**Why v3 accepts it.**

1. The pipe makes a method call `(List.push q 9).append [ List.length q ]`. `Lower.zig` lowers the operand
   of `▷` where it is written, before the callee (`lowerApplication`, `src/bir/Lower.zig:3169-3171`, and the
   callee at 3193). So the read `List.length q` is instruction 12 and the write `List.push q 9` is
   instruction 17 (`beni dump --stage=bir`).
2. JavaScript evaluates the receiver first: `List.append(List.push(q, 9), [List.length(q)])`. The walk
   evaluates the receiver first too (`methodCall`, `src/own3/Frame.zig:2376-2380`; `call` evaluates the
   callee before its arguments at 2289).
3. But the write rule compares instruction numbers, not the walk's order: `finishDemands`,
   `src/own3/Frame.zig:1151`, skips each read with `u.point <= d.point`. The comment says "an instruction's
   number is after each of its operands'". That is true, but a number is not after everything that runs
   before it. The read at 12 is skipped as "before the write at 17", and the write is accepted.

**A class.** Each `x ▷ e` where `e` is not a plain name and runs code: a field of a call result, `if`, `case`,
a tuple item of a call, the receiver of a method. Each reader in `x` and each writer in `e` meet this way. All
28 live `order` programs trap. `isOld` (`Frame.zig:771-773`) compares the same numbers. The reverse case (a
write in `x`, a read in `e`) is refused although it is safe. `<|` lowers its operand last and is not affected.
v2 accepts all 28. v1 refuses all 28.

### 4.2 One list twice in the deep level of a recursive value

`blind2-faults/deep-summary-twice.live`:

```beni
type Lst
    = Cons (List Int) Lst
    | Nil


f : Lst → String
f t =
    case t of
        Cons _ (Cons a (Cons b _)) →
            w = List.set a 0 9
            show w ++ "/" ++ show b

        _ →
            "-"


go : Int → String
go n =
    q = [ n, 2 ]
    f (Cons [ 0 ] (Cons q (Cons q Nil)))
```

The plain build prints `9,2/0,2`. The checked build traps: `b` is `q`, which the write changed. The safe twin
drops the read of `b`, and the prototype accepts it.

**Why v3 accepts it.**

1. In `f`, `a` and `b` are both at the deep level of `Lst`: one summary location (`src/own3/Loc.zig:6-12`).
   They are one root with one entry and two paths, `.1.0` and `.1.1.0`. Neither path is a prefix of the other,
   so `overlap` (`Frame.zig:433-435`) says that they are two cells. `f` is accepted, and its contract says that
   it writes and reads the deep entry of its parameter.
2. At the call in `go`, `apply` (`Frame.zig:2499-2514`) collects the argument's cells at the deep entry with
   `leaves`. The outer `Cons` has one argument at `#Cons.1`. Two entries of that argument map up to the one
   deep entry of the parent: its own `#Cons.0` (the first `q`) and its own deep entry (the second `q`). So
   `pr.downOf(e)` has two entries (`Frame.zig:593-595`), and both give `q`.
3. The test for one cell twice runs only between two arguments of a constructor: `before > at` at
   `Frame.zig:599`. It never compares the entries of one argument. So `dup` is false, the demand has no
   `.element` refusal (`Frame.zig:1091`), and `otherReaches` skips the written entry of the written operand
   itself (`Frame.zig:1003-1006`). Nothing compares the two copies of `q`, and the write is accepted.

**A class.** The same loop is in `listOf` (`Frame.zig:1612-1621`), and `finish` reads its duplicates from
`leaves` (`Frame.zig:2145-2157`). So a callee that builds such a value, or a recursive function that puts its
parameter in each node (`rep k x = … Cons x (rep (k - 1) x)`), gets a contract whose deep result location
holds the list once, not `shared`. `apply` keeps that location `derived` (`Frame.zig:2556-2562`), and the
caller trusts it. The `two` and `deep` families trap through a built argument, a callee that builds the value,
a recursive maker, one function further, a generic identity, a tuple or a constructor taken apart, a `case`
arm, and `?`; in four recursive types (a list type, a tree with a list of children, a record in a cycle, a
generic type). In `go` itself, a built value is precise: the six live `deep` programs that match the value
where they build it are refused.

v2 refuses all 102. v1 refuses 94. v1 accepts the 8 programs of `two.*.tried.*`, where the value passes
through `?`.

## 5. Precision losses

1. **One list at two places of a value.** v3 refuses a write of one place when the same list is at another
   place, also when nothing reads that place later. 136 dead twins of `two` are refused; v2 accepts 134 of
   them. Example (`two.tup.fresh.dead`): `make` answers `( q, q )` for a fresh `q`; the caller writes `r.0`
   and never reads `r.1`. A cell at two places of a result, or twice in a summary location, gets the kind
   `shared` (`Frame.zig:2157` and `2168-2177` in `finish`, `2562` in `apply`, `1629` in `listOf`), and a
   `shared` atom refuses each write (`Frame.zig:1082`), whatever is read after.
2. **Callbacks that write an element.** 13 dead `hof` twins are refused, and v2 refuses the same 13. Most are
   odd code (a `filter` predicate that pushes), but `Dict.map d (λ_ l → List.push l 9)` and
   `Dict.update d "a" (λm → Maybe.map m (λl → List.push l 9))` with `d` dead are real-looking.
3. **Pipes.** A write in the operand of `▷` and a read in a computed callee is refused, though JavaScript
   reads first (the reverse of fault 4.1).

## 6. What was not covered

- Function values beyond a constructor as a function value, lambdas run at once and local functions. The
  earlier generators of this folder cover them.
- The browser platform, markup, the program entry (`Tea`), workers, `Task` and fibers, and `Ref` beyond the
  rows of `core/Ref.beni`.
- `--release` builds. The oracle is the development build.
- Contracts across modules: one hand probe, no sweep.
- Types past a limit of the place graph, and the fallback `Step.level` of `Mod.ctorStep`.
- The cover's fallback `all`. `otherReaches` skips each entry of the written operand that the fallback covers
  (`Frame.zig:1007-1009`). The tester read this and did not build a program that reaches it.
- Methods of user types and `where` evidence, beyond `List.append` as a method.
- v1 and v2 on the whole sweep. They ran on the 130 traps and on the 149 refused safe twins only.
