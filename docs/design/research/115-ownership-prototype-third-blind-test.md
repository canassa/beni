# 115 — The ownership prototype: a third blind test

*Research report, 2026-11-12. A test of the prototype checker `src/own3/` (`--ownership=v3`) on pull
request #2451 at `418b816171`. The tester read `src/own3/`, the place graph it uses, `core/List.beni`,
`core/Dict.beni`, the sweep runner and the generators that are not blind tests. The tester did not read
reports 110 to 114, `blind.mjs`, `blind2.mjs` or their fault folders. This report is not normative.*

## 1. Summary

The prototype accepts programs that then read a list after an in-place write. This test found three
classes of such programs. Each class has many members, and v1 and v2 refuse every member that this test
made, except one shape (§4.4).

1. **A new list has no name.** A source `fresh` gives no atom. So when one new list reaches a caller by
   two ways, through the answer of a function parameter, the caller sees two lists. It also loses the
   escape of a new list that the callee hands to a function that keeps it. 86 programs trap.
2. **`eq` and `compare` with no annotation.** The walk takes `==`, `<` and a dot call named `eq` or
   `compare` to only read. The check that makes that true skips an `eq` or `compare` that has no
   annotation. 34 programs trap.
3. **The comparator of `List.sortWith`.** Its worded row hands the comparator `shared`. An escape of
   `shared` escapes nothing, so a comparator that keeps an element in a cell is not seen. 3 programs trap.

## 2. What was probed, and how

The tester read the checker for places where its model and the run time differ, wrote one probe for each
idea by hand (about 40 programs), and then put the shapes that mattered in a generator.

- `bench/ownership-sweeps/blind3.mjs` writes 417 programs in seven families (its header lists them).
- `bench/ownership-sweeps/blind3-faults/` has one minimal program per fault and its safe twin (10 programs).

The commands, with a ReleaseSafe beni:

```sh
node bench/ownership-sweeps/blind3.mjs <out>/b3
node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v3 --jobs=16 --tmp=<disk> <out>/b3
node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v2 --jobs=16 --tmp=<disk> <out>/b3
node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v1 --jobs=16 --tmp=<disk> <out>/b3
node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v3 --tmp=<disk> bench/ownership-sweeps/blind3-faults
```

The oracle is the runner's: a plain build against a build with `--ownership=<checker>
--ownership-everywhere --sanitize-lists`. Today `List.set` and `List.push` copy a short list in both
builds, so an unsanitised v3 build prints the same as the plain one. The sanitiser poisons the old array
at each accepted write, so a TRAP is exactly a read that an in-place write makes stale.

## 3. Verdicts

By family and twin. `live`: a read after the write sees the old list (must be refused). `dead`: the same
shape with no such read (safe). `none`: a read after the write that sees no change (safe).

| Family | Twin | v3 | v2 | v1 |
|---|---|---|---|---|
| `answer` | live | **72 TRAP**, 50 REFUSED | 122 REFUSED | 122 REFUSED |
| `answer` | dead | 46 SAME, 15 REFUSED | 61 SAME | 49 SAME, 12 REFUSED |
| `supply` | live | **8 TRAP** | 8 REFUSED | 8 REFUSED |
| `supply` | dead | 8 SAME | 8 SAME | 8 SAME |
| `supply` | none | 8 SAME | 8 SAME | 4 SAME, 4 REFUSED |
| `handon` | live | **6 TRAP**, 3 REFUSED | 9 REFUSED | **3 TRAP**, 6 REFUSED |
| `handon` | dead | 9 SAME, 3 REFUSED | 2 SAME, 10 REFUSED | 6 SAME, 6 REFUSED |
| `handon` | none | 3 SAME | 2 SAME, 1 REFUSED | 3 SAME |
| `compare` | live | **34 TRAP**, 20 REFUSED | 54 REFUSED | **3 TRAP**, 51 REFUSED |
| `compare` | dead | 61 SAME, 20 REFUSED | 27 SAME, 54 REFUSED | 54 SAME, 27 REFUSED |
| `compare` | none | 27 SAME | 27 SAME | 27 SAME |
| `sortwith` | live | **3 TRAP** | 2 REFUSED, **1 TRAP** | 2 REFUSED, **1 TRAP** |
| `sortwith` | dead | 4 SAME | 2 SAME, 2 REFUSED | 2 SAME, 2 REFUSED |
| `sortwith` | none | 1 SAME | 1 SAME | 1 SAME |
| `dict` | live | 5 REFUSED | 5 REFUSED | 5 REFUSED |
| `dict` | dead | 5 REFUSED | 5 REFUSED | 5 REFUSED |
| `front` | live | 1 REFUSED | 1 REFUSED | 1 REFUSED |
| `front` | dead | 3 SAME | 3 SAME | 3 SAME |
| `front` | none | 2 SAME | 2 SAME | 1 SAME, 1 REFUSED |

No program gave DIFF, CRASH or PLAINFAIL. v3 traps on 123 programs; the five minimal programs of §4 trap
too, and their five safe twins print the same.

## 4. Faults

### 4.1 One new list at two places, through an answer (a class)

`blind3-faults/answer-twice.live`:

```text
twoOf : (⊤ → a) → a × a
twoOf g =
    x = g ⊤
    ( x, x )

main =
    p = twoOf λ_ → [ 1 ]
    w = List.set p.0 0 9
    Node.print (String.fromInt (List.sum w + List.sum p.1))
```

`p.0` and `p.1` are one array. v3 accepts the write and the read of `p.1` traps.

**Why v3 accepts it.**

1. `twoOf`'s contract is right: both result entries have the source `answer`, and `nonlinear` is set.
2. In the caller, `apply` expands each entry (`expandSrcs`, then `answerOfParam` and `answerOfCode`). The
   lambda answers a new list, so the source is `.fresh => st.fresh = true` (`Frame.zig:4003`). That makes
   no atom. Each entry gets only the result root's own atom at its own entry: `(root, path.0, e0)` and
   `(root, path.1, e1)`. Two atoms with two entries never overlap (`overlap`, `Frame.zig:452`).
3. `nonlinear` only sets the root's `linear` to false (`Frame.zig:2766`). `linear` matters for atoms read
   through the root (`dupOverlap`), not for the root's own entries. And step 2 of `sourcesApart` skips a
   pair at two entries when the root is not linear (`Frame.zig:2933`), on the reading that nonlinearity is
   already handled. Its own overlap test would find nothing either: the answers have no atom.
4. A callee that makes the list itself is safe: `finish` adds the source `also` for a cell of the frame at
   two entries (`Frame.zig:2383`). But that loop skips any atom whose root is not `local`
   (`Frame.zig:2377`), and an answer's root is `answer`. So no `also` is written for an answer.

**The same gap, two more shapes.**

- `blind3-faults/answer-supply.live`: the callee makes `x = [ 1 ]` and answers `( g x, x )`, and `g` is
  `λl → l`. The supply of `g` is `fresh` (`atomSrcs` of an own local), so the answer resolves to `fresh`
  with no atom (`FlatSink.fresh`, `Frame.zig:3560`). `x` itself is `fresh` too. The two halves look apart.
  `( g x, g x )` traps the same way.
- `blind3-faults/answer-escape.live`: the callee makes `x`, calls `h x` and answers `x`; `h` keeps its
  parameter in a cell. In the caller, the escape of `h`'s parameter is resolved through `h`'s supply,
  which is `fresh`, and `EscSink.fresh` does nothing (`Frame.zig:3596`). The cell keeps the array, the
  caller writes it in place, and the read of the cell traps. With `x = g ⊤` instead of a literal, the
  supply is `answer`, `EscSink.answer` asks `answerOfParam`, and that gives `fresh` with no atom again.

**A class, not a one-off.** In the sweep it traps for a pair, a record, a `Maybe` beside the value, a pair
one level down; for a lambda, a lambda over an argument and a named function; for a generic, a monomorphic
and a local callee; and for a write of either place. The list holder `[ x, x ]` is refused, because a
summary location gets `twice`. The control where the callback answers a captured list is refused (its
answer is `shared`). The root cause is one rule: `fresh` is a fact with no name, so nothing can say that
two `fresh` sources are one cell or that a `fresh` cell escaped. v1 and v2 refuse every live program of
`answer` and `supply`, and v2 refuses every live program of `handon`.

### 4.2 `eq` and `compare` with no annotation (a class)

`blind3-faults/compare-unannotated.live`:

```text
type Bag
    = Bag (List Int)

eq a b =
    case a of
        Bag xs →
            List.length (List.set xs 0 9) == 0

main =
    q = [ 1 ]
    t = Bag q == Bag []
    Node.print (if t then "y" else String.fromInt (List.sum q))
```

**Why v3 accepts it.**

1. `methodCall` treats a call as a read when it is an operator or its name is `eq` or `compare`
   (`Frame.zig:2582`). It only calls `readAll` on the operands: no write, no escape.
2. That rests on `Check.zig:1031–1042`, which refuses an `eq` or `compare` whose contract writes or lets
   an operand escape. It only looks at a declaration whose `method_of` role is set.
3. `own2/Prepass.zig:163–168` sets the role only for a `pub` value with an annotation of a function type.
   An `eq` with no annotation, public or not, has no role and is never checked. The language still uses
   it for `==` (a private `eq` is used too).
4. In `eq`'s own frame, `List.set xs 0 9` writes a parameter, so it is accepted and leaves the duty to the
   callers. The one caller does not take it.

**A class.** It traps for `==`, `≠`, `<`, `≤`, `>`, `≥`, `.eq` and `.compare`; for a public and a private
method; and for a method that writes its operand or keeps it in a cell. An annotated method is refused
(`refused: comparison`). The hole reaches evidence too, for a method that keeps its operand: `[ Bag q ] ==
[ Bag [] ]` with an `eq` that puts `xs` in a cell, then a write of `q` and a read of the cell, traps.
`evidence` (`Frame.zig:2630`) refuses a method that writes, but not one that lets its operand escape. (A
method that writes, reached as evidence, is refused; so is one reached by `List.sort`.) v2 refuses every
live program (`comparison`, or `later`). v1 refuses the others with `later` or `shared`, but traps on the three `listeq.keep` programs (§4.4).

### 4.3 The comparator of `List.sortWith` (one row; a class of worded rows)

`blind3-faults/sortwith-keep.live`:

```text
main =
    cell = Ref.make [ 0 ]
    xss = [ [ 1 ], [ 2 ] ]
    s = List.sortWith xss λa _ →
        Ref.set cell a
        EQ
    n = List.length s
    w = List.update xss 0 λm → List.set m 0 9
    w2 = List.update w 1 λm → List.set m 0 9
    Node.print (String.fromInt (n + List.length w2 + List.sum (Ref.get cell)))
```

**Why v3 accepts it.**

1. `sortWith : borrowed List a, many (a, a → Order) → copyof List a` is worded. `wordedFn` gives a
   function parameter that is not `taken` the supply `shared` (`Check.zig:628`): "no claim".
2. The comparator lets its parameter escape into the cell. `flowCode` resolves each source of that supply
   to find what escapes (`Frame.zig:3331–3339`). `EscSink.shared` does nothing (`Frame.zig:3597`).
3. So the elements of `xss` are never marked as escaped. The later `List.update` writes them in place, and
   the read of the cell traps.

`shared` is the right answer for a write (`OwnSink.shared` refuses). It is the wrong one for an escape:
"no claim" is not "no cell". In today's `core/`, `sortWith` is the one worded function that hands a
function parameter list elements without `taken`; `Ref.update` and `Ref.modify` hand a cell's contents,
which are never `own`. So the fault is one row today, and a class for any future worded row.

v1 and v2 refuse `sortwith-keep.live`. They trap on one shape that v3 also traps on: the comparator keeps
the element by `Ref.update cell λ_ → a` (§4.4).

### 4.4 Holes of v1 and v2 that this test met

These are not faults of v3, and v3 refuses the two direct forms.

- v1 accepts `Ref.update cell λ_ → q` followed by a write of `q` and a read of the cell (direct, or
  through a function that takes `q`): v1 does not let the answer of `Ref.update`'s callback escape. It
  traps on `handon.keepUpd.*.live` too.
- v1 and v2 accept `sortwith.keepUpd.live`: the `sortWith` comparator keeps an element by
  `Ref.update cell λ_ → a`.
- v1 accepts `[ Bag q ] == [ Bag [] ]` where `eq` keeps its operand in a cell, then a write of `q` and a
  read of the cell, also when `eq` is annotated.

## 5. Precision losses

- **`Dict.update` never writes in place.** Each `dict` program is refused by all three checkers, also
  the safe control (`d = Dict.insert Dict.empty 1 [ n, 1 ]`, then `Dict.update d 1` with a callback that
  writes the value). v3 says `disjoint`, v2 says `call`, v1 says `shared`.
- **A captured list that comes back as an answer.** v3 refuses the 15 `answer.*.cap.*.dead` programs:
  the callback answers a list that the caller captured, and the caller writes it with no read after. v2
  accepts them. This rests on `answerOfCode` making a captured answer `shared`.
- v3 accepts more safe twins than v2 in `compare`, `handon` and `sortwith`, but each of those families
  has a soundness hole in v3 at the same place, so the figures say nothing about precision there.

## 6. Not covered

- Browser programs, `Tea` entries (`entryCall`) and markup. The node platform was the only one run.
- Programs of more than one module. Contracts cross modules as label paths (`Contract.publish`); no
  probe tested that path.
- The release build, and `--jobs` above one.
- Recursive types, folds, nested callbacks and evaluation order of single constructs, beyond what the
  earlier generators cover: the tester read them only for their format.
- Suspending functions and fibers, other than `Ref` cells.
- `where` clauses other than `eq` and `compare`.
