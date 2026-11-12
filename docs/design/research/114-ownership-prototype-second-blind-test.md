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

*Added after the fix:* §7 says how each hole was fixed and what an audit of the order found, §8 how the 136
are won back, §9 the faults that a review of the fixes found, and §10 the measurements.

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

## 7. How the two holes were fixed

*Added after the fix, on branch `ownership-v2-design-review`. The commits are on the branch; the measurements
are in §10.*

### 7.1 The order of reads and writes

**The cause.** The write rule asked "is this read after the write?" by comparing instruction numbers. Lowering
numbers instructions in source order. That is not the order in which the program runs: in `x ▷ e` the operand
`x` is numbered first, and JavaScript evaluates `e` first when `e` is not a name.

**Where the order comes from.** `language.md` §6, *Evaluation order*, says that a pipe is rewritten before
anything runs, and that the rewritten form's order holds: the callee or the receiver, then the arguments. The
emitter does this. `orderedExprs` and `callExpr` in `src/js/Lower.zig` evaluate a call's head and then its
arguments in slot order, and they pin each value to a constant before a later operand hoists statements. The
checker's walk already goes in the same order: the callee, then the arguments; a `case`'s scrutinee, then one
arm; a `let`'s bindings in order. Only the numbers were wrong.

**The fix.** Each read, write, escape and new name now has a time from the walk's own clock (`Frame.timeOf`),
not an instruction number. What one operation records has one time. A record at another instruction, or after
the walk entered another expression, has a later time. The write rule and the rule of old names (`isOld`)
compare these times. This is the existing rule ("no read after the write"); only "after" changed. It needs no
new kind of fact.

**The audit.** Two checks.

1. A log of every pair of a read and a write whose order by number and by time differ, and where the read
   reaches the write. Over the 5 225 `.beni` files of `tests/corpus/` and the 22 020 programs of eight
   generators (all but `recursive-levels.mjs` and `folds-callbacks.mjs`), the only such pairs were the 28
   `order` programs of §4.1.
2. A new generator, `bench/ownership-sweeps/evaluation-order.mjs` (440 programs): one read and one write of `q`
   in two parts of 42 constructs, in both orders, run under the sanitiser. Before the fix, 20 programs trapped
   (16 pipes and 4 method receivers) and 20 safe programs were refused. After it, none traps, and the only safe
   programs refused are four where a lambda writes a list that it captured (refused by design).

| Construct | Number order = run order? |
|---|---|
| a call's arguments, a constructor's, a record alias's constructor | yes |
| tuple, list and record literals (a record's fields in written order), record update | yes |
| interpolation, `++`, `==`, `<`, `&&` | yes |
| `case` scrutinee (also a tuple), `if` condition, `let` bindings and body | yes |
| a lambda applied, a computed callee `(f a) b`, a field of a call `(mk a).f b` | yes |
| `?` alone, in an argument, after an argument | yes |
| `x ▷ f a` (a named callee), `e ◁ x` | yes |
| **`x ▷ e` with `e` a field of a call, an `if`, a `case`, a tuple item** | **no: fixed** |
| **`x ▷ r.m`, a method of a computed receiver** | **no: fixed** |
| spreads, `++` on lists, methods with arguments | yes |
| markup holes; a `For`'s list | yes before; see below |
| **a markup hole that calls a function of the top level** | **no: found by the review (§9)** |

Two more things the audit found.

- The first version of the fix read each markup value right after the hole that made it. The render reads
  the values after all holes, so a later hole that wrote a `For`'s list was accepted. Under numbers this was
  right by luck: the markup instruction comes after its holes. The walk now reads the values after all holes.
- Lowering numbers a `let` binding before its value (`findGroups` says so). The only read at a binding is a
  list pattern, and a list pattern in a `let` is refused as refutable. So no program reaches it.

`language.md` §6's row for pipes says that for `|>` "the two agree": `e |> f a` is `f e a`, so `e` is first.
That is true when the callee is a name. When it is a computed expression, the callee runs first. The emitter
does that, and so does the checker now. The row's sentence could say so; it was not changed.

### 7.2 One list twice in a deep level

**The cause.** `leaves` gave the cells of a value at one entry of its layout. A summary location can be fed by
two entries of one part: the entry level and the deep level of the value that a constructor holds. The test
for one cell at two places compared two parts of a construction, never two entries of one part.

**The fix.** `leaves` now takes a set of entries (`leavesOwn`, `leavesSet`). Each part of a construction is
asked once for its own set, so a list at two of its entries is found as a list in two parts, and the location
becomes `shared` (later: `twice`, §8). Two entries of one part of a root that are one entry of the root are
read once: the atom names each cell of that entry, at every depth. Two entries of a root that hold one cell of
another root count as two places unless the root says that it holds each cell once (`linear`).

The other places that fold now use the same sets: `leavesAs` (two readings of a type), `argLeaves` (a callee's
entry that covers two entries of the argument), and `listOf` (a list's entries, and the storage of a prepend's
or a spread's base). `finish` and `apply` read `leaves`, so they follow. This is the existing rule ("a list
reachable two ways makes its location `shared`"); it needed no new kind of fact. No program was found that
needs the sets in `listOf` and `argLeaves`; they apply the same rule.

## 8. The precision losses

**The 136 safe `two` programs.** All of them were refused because a location that holds one list at two places
was `shared`, and `shared` refuses each write. The fix of §7.2 made 88 more safe programs of `two` and `deep`
refused the same way. `shared` says two things at once: "no claim" (the checker does not know the cells) and
"not apart" (one cell can be at two places). These programs need only the second.

Two new kinds of fact say the second without the first.

- **`twice`** (`REntry.twice`, the source `twice` of a contract): a summary location that can hold one of its
  cells at two places. It keeps its claim and what it holds. Its parts are not apart: an atom of it names all
  of it, so a write of one part and a read of another overlap. A callee that writes such a location is
  refused (`leavesOwn` reports one cell at two places), so hole 2 stays closed. A root with such a location is
  not `linear`.
- **`also`** (the source `also` of a contract): a result location that holds a list that the body made and put
  at another result location too. Before, both locations were `shared`. Now the caller gives the two
  locations one atom, so a write of one and a read of the other overlap, as they do for a value built in the
  caller's own frame.

Where the checker cannot see the cells (the answer of a function value), the location stays `shared`. Where a
function value's answer has `twice` or `also`, it is read as before (`shared`).

**The result.** v3 accepts all 136 safe `two` programs now (v2 accepts 134). Of the 237 refused safe programs
of `blind2.mjs` after §7, 35 stay refused:

- 22 `deep.*.callee.dead`: a callee writes one place of a summary location, and the caller hands it a value
  with one list at two places of that location. To accept them, a contract would need a finer fact: which
  cells of a location the callee reads after it writes one. `twice` cannot say it; it is about the caller's
  value, not the callee's reads. This was not added.
- 13 `hof.*.dead`, as in §5.

The real writes stay at 299 of 308, and no other gate moved (§10).

## 9. A review of the fixes

A reviewer who did not write the fixes searched the code for another order mismatch and another merge without
`shared`. It found three faults. Each is fixed and has a black-box test and a program in `blind2-faults/`.

1. **A part of a `twice` location handed to a callee.** `mk3` answers a value whose deep level holds `q` twice.
   A part of it goes to `h`, which writes its own top level and reads its deep level. In the caller both are
   the one `twice` location. The test of the other operands took two locations of one part of a root as two
   sets of cells. It does not now for a `twice` location. (The old prototype trapped too, through hole 2.)
2. **A helper call in a markup hole.** `language.md` §6 and §11.6 say that a hole that calls a function of the
   top level is called where the platform renders, after the other holes. The emitter does that. The walk
   made the call where the hole is written, so `{item q}{show (List.push q 9)}` was accepted. The call stays
   where it is written, which is the earliest place its writes can run, and what it reads of its arguments is
   read again after the other holes. A hole of text is no helper. (The old prototype and v2 trapped too.)
3. **The browser platform keeps the values of a page's holes.** The `dom` lowering keeps them in the markup's
   value and reads them where it renders, after the frame. Report 113 §6.4 has the markup hold none of them,
   by a rule of the platforms. So a write after the markup was built, in the same frame, was accepted. Each
   hole's value is now read again at the end of the frame (`finish`). (The old prototype accepted it; v2
   refuses it.)

**Not fixed, and why.** Fault 3 has a second form: a local function builds the markup, and the caller writes
the list after the call. The frame's end is the local function's, which is too early. v1 and v2 refuse it.
To refuse it, the markup's value must hold its holes, and then a contract says so. That costs 12 of the 308 real
writes (each `entry` write of a page whose `view` answers markup that holds the model), and 4 more after the
entry rule ignores markup in an answer, because `Html.map` is a `foreign` with no word and lets what it is
handed escape. Rule 10 of `CLAUDE.md` applies: this is a decision about the platforms' rule for markup, not a
patch. The owner should decide it. A program: `view model` with `mk u = <ul><For each={q}>…</For></ul>`,
`v = mk 0`, `w = List.push q 9`, `<div>{v}<p>{show w}</p></div>`.

The reviewer also suspected that the release optimiser's single-use inlining (`src/js/Opt.zig`) could move a
pure read past an in-place write. A reading of its rule says no: a value that calls something moves only into
the next statement, and only past names, literals and field reads. It was not tested: `--sanitize-lists` runs
on development builds only.

## 10. Measurements

A ReleaseSafe compiler (self-hosted backend) of the base `db354a1de7` ("before"), of the order and hole 2 fixes
alone ("§7"), and of the branch with §8 and §9 ("after"). The same programs for each.

| Programs | n | SAME before → §7 → after | REFUSED before → after | TRAP / DIFF / CRASH before → after |
|---|---:|---|---|---|
| `evaluation-order.mjs` | 440 | 268 → 288 → 288 | 152 → 152 | 20 / 0 / 0 → 0 |
| `blind2-faults/` | 20 | 8 → 9 → 9 | 3 → 11 | 9 / 0 / 0 → 0 |
| `blind-faults/` | 24 | 11 → 11 → 11 | 13 → 13 | 0 → 0 |
| `blind2.mjs` | 1 202 | 388 → 300 → 502 | 684 → 700 | 130 / 0 / 0 → 0 |
| `blind.mjs` | 9 792 | 1 323 → 1 323 → 1 564 | 8 469 → 8 228 | 0 → 0 |
| `answers-beside.mjs` | 240 | 61 → 61 → 62 | 179 → 178 | 0 → 0 |
| `wider-functions.mjs` | 354 | 171 → 171 → 171 | 183 → 183 | 0 → 0 |
| `callbacks-keep.mjs` | 720 | 108 → 108 → 108 | 612 → 612 | 0 → 0 |
| `function-values.mjs` | 1 960 | 250 → 250 → 250 | 1 710 → 1 710 | 0 → 0 |
| `handed-back.mjs` | 2 592 | 0 → 0 → 0 | 2 592 → 2 592 | 0 → 0 |
| `aliased-arguments.mjs` | 5 160 | 861 → 861 → 963 | 4 299 → 4 197 | 0 → 0 |
| `recursive-levels.mjs` | 16 131 | 4 282 → 4 282 → 4 291 | 11 849 → 11 840 | 0 → 0 |
| `folds-callbacks.mjs` | 30 300 | 6 182 → 6 182 → 6 182 | 24 118 → 24 118 | 0 → 0 |

The 23 programs that were SAME before and are refused after are the safe twins of hole 2 that were accepted
through it: 22 `deep.*.callee.dead` of `blind2.mjs` (§8) and `deep-summary-twice.dead`.

| Gate | before | after |
|---|---|---|
| real writes (`--checkers=v1,v3`): accepted of the 308 that v1 judges | 299 | 299 (the same nine refused) |
| sanitiser corpus: same / refused / trap / differs | 101 / 246 / 0 / 0 | 101 / 246 / 0 / 0 |
| report 111's first family, 2 000: v3 same / trap | 502 / 0 | 502 / 0 |
| report 111's second family, 2 000: v3 same / trap | 705 / 0 | 705 / 0 |

The black-box tests are in `tests/blackbox/check_test.zig`: "the walk reads and writes in the order of the
program", "one list twice in a deep level makes the location shared", "one list at two places keeps its claim"
and "the faults of the review of report 114 are refused". The first two fail on the base.
