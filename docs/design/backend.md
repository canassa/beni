# Backend implementation contract (M3)

**Status:** normative for M3. [`fast-compiler.md`](fast-compiler.md) §9 says *why* the backend is
shaped this way and §2 what it must measure; [`boundary.md`](boundary.md) says how emitted code
meets JavaScript; [`research/12-js-output-and-chunking.md`](research/12-js-output-and-chunking.md)
is the evidence for every size claim below. This document says what the code looks like.

M3 ends when `beni build` produces JavaScript that runs and the emitted output is measurably close
to what a dedicated minifier would produce. The third condition this line used to carry — a direct
call share high enough to justify keeping currying — is discharged rather than met: §9.3 dropped
currying on 2026-09-14, so the share is 100% by construction (§6).

## 1. Scope and order

The order is not negotiable and one rule sets it: **nothing is optimised before it can be run.**
`boundary.md` §8 puts the Node platform before the optimiser for this reason — the test suite's
second boundary is compiling a program, running it under Node and asserting what it printed, and a
backend that cannot be executed is a backend whose bugs survive a green suite.

- **M3a — emit and run.** *Shipped.* `JsIr`, the printer, codegen for the pure subset, core's
  foreign JavaScript for what that subset uses, a minimal Node platform, and the harness boundary
  that runs emitted code. *Acceptance: a beni program computes something and prints the right
  answer* — `tests/corpus/run/` is 26 programs that do, executed under Node. All 65 of core's
  foreign values are implemented, not only the ones the subset reaches. `?` is the one construct
  of §4's table M3a does not compile, and it says so with a diagnostic rather than emitting
  something wrong.
- **M3b — the whole language.** Tail-call loops, decision trees, interpolation, `?`, tuples, record
  update, `Int32`, everything remaining. *Acceptance: the corpus compiles and runs.*
- **M3c — the optimiser.** Reachability elimination, reachability-driven inlining, local
  dead-binding elimination, renaming, field ambiguation, compact printing. *Acceptance: §9's size
  and throughput numbers, and §9's size and throughput numbers alone; the direct-call share that used to decide §9.3 is
  discharged, not measured (§6).* **Reachability elimination is built first and is not optional**:
  static dispatch derives eagerly, so an empty program ships 3 159 bytes of `eq`/`compare` that
  nothing calls, and `fast-compiler.md` §13 moved this pass from an optimisation to a prerequisite
  on that evidence. Its own acceptance is separate and exact: the floor's `derived_bytes` is **0**
  for a program that compares nothing (§9).
- **M3d — chunking and `lazy`.** The keyword, entry-set colouring, the merge pass, cross-chunk
  bindings. *Acceptance: a two-route program splits and both routes run.*

`boundary.md`'s B1 and B2 fold into M3a; B3 through B5 follow M3d.

## 2. CLI surface

```
beni build [options] <entry>...      compile to JavaScript
```

| Flag | Meaning | Default |
|---|---|---|
| `--platform=<name>` | which platform package supplies `main`'s type and the runtime | required |
| `--release` | chunks, renaming, integer tags, maps off | off |
| `--library` | no `main` is required and no entry file is written; every name the root package's modules export is a reachability root (§9) | off |
| `--out=<dir>` | output directory | `out/` |
| `--source-maps` | emit `.map` files | M5; refused today, on in dev and off in release once §11 lands |

**`--release` and `--source-maps` are refused, not ignored.** Neither is implemented — the optimiser
is M3c (§1) and the source-map encoder is M5 (§11) — and a flag that is accepted while doing nothing
makes a user believe they asked for something: a silent, successful `--source-maps` build sends them
looking for a `.map` that was never written, exactly as a silent `--release` build would ship
development output. Both exit `2` with `frontend.md` §1's one-line usage message naming the
milestone. The defaults in the table above are what M5 will do; until then the only way to build is
without the flag.

**`--library` is not in that company**: it lands with §9 and does something the day it lands. It
turns off exactly two things — the search for `main` (`missing_main` does not fire, and a `main`
that happens to exist is not special) and the entry file — and turns on one, the root rule. It is
not a second output mode; a library build emits the same `.mjs` per module as any other.

Development output is **one ESM file per source module**, mirroring the source tree, with readable
names — but not with everything the source declared. Release output is **reachability chunks**. Both
read one declaration graph (§9.1 of the design doc) and **both eliminate against it**: a dev build
and a release build ship the same set of declarations and differ in how those are named, laid out
and grouped into files. Nothing is built twice. §5.3 of `boundary.md` makes a build a pair of entry
point and platform, so a project with a client and a server runs `build` twice.

**Elimination is not behind a flag**, and §9 gives the reason: eager derivation makes it the
difference between an empty program shipping 70 kB and shipping 2 kB, and a development build that
ships fifty times what it needs is not a development build anyone would run. What `--library`
changes is the root SET and never whether the pass runs.

A successful build prints **nothing, on either stream**. `frontend.md` §1 gives stdout to the product
and stderr to diagnostics and nothing else; a build's product is the files it wrote, so there is no
stream left for a summary line, and `check` already sets the precedent. How much was written is a
`--self-profile` counter (`emitted_files`, `emitted_bytes`), which is also where M4's incrementality
tests read "this edit rewrote one file".

File extension is `.mjs`, so nothing depends on a `package.json` the user owns. **That applies to
every file a build writes, the hand-written ones included** — M3a shipped copying core's siblings
and the platform's runtime out as `.js`, and Node then reparsed each one and warned
`MODULE_TYPELESS_PACKAGE_JSON` on every start, whose own suggested remedy is adding `"type":
"module"` to a `package.json`. That is the dependency this rule exists to avoid, arriving through
the back door. A copied file cannot simply keep its stem, because `out/core/List.mjs` is already the
generated module, so it takes **`.foreign.mjs`**: it says which half of the module it is, and it
cannot collide — a generated file is named for its module, every segment of a module name is an
upper identifier, so no generated file has two dots in its base name. The `.js` names in `core/` and
`platforms/` on disk are unchanged; `language.md` §5.4 fixes the sibling's NAME and not its
extension, and only the copy is executed.

The rename has one consequence M3a refuses rather than gets wrong: **a sibling may not import
another FILE.** `import { cons } from "./List.js"` is written against a name the copy no longer has,
and rewriting the specifier is M3b's. A bare specifier — `node:process`, a package — survives the
copy untouched and is what `boundary.md` §4's third check is really about, so nothing that check
blesses is lost today except sharing a helper file between two siblings.

**No `package.json` is written into the output, and that is deliberate.** `.mjs` already makes every
file an ES module whatever any `package.json` says, so one would add nothing — and it would put back
exactly the file the extension was chosen to avoid, inside a directory the user chose (`--out` may
well point at something they own). A build writes only files it named itself.

## 3. `JsIr` — the second IR

§9.2 settles that there are two IRs and not one: lowering the typed IR straight to a byte buffer was
measured as neutral in Elm and loses the ability to pattern-match on generated structure, which is
what the peephole and specialisation passes need.

`JsIr` is a `MultiArrayList` of fixed-size nodes with one `extra: []u32` sidecar and `enum(u32)`
indices, exactly as every other IR here (§5). It is JavaScript-shaped, not beni-shaped: statements
and expressions, `var`/`const` declarations, function expressions, calls, member access, object and
array literals, `switch`, labelled `while`, `return`, conditional expressions. It carries **source
positions from the start** even while maps are off (§9.6), because retrofitting them touches every
pass.

Names in `JsIr` are `Symbol`s, never strings, so renaming in M3c is a table swap rather than a
rewrite.

**The backend still sees no types, and static dispatch did not change that.** `Lower.Input` gains
one field beside `interfaces`: a **dispatch table**, one per module, flat and index-based in the
shape of `Bir.refs`, in which the checker has already written what every method call resolved to,
what evidence every declaration takes, and which functions must be derived. The lowerer reads
targets, never types. → [`static-dispatch-spike.md`](static-dispatch-spike.md) §7, §8.0.

**The elimination graph is not `JsIr`'s.** §9's reachability walk runs over `Bir` and the dispatch
table *before* lowering, so an unreachable declaration never becomes `JsIr` nodes at all and `JsIr`
holds only what survives. That is the opposite of §9 item 1, the local dead-binding pass, which is a
use-count walk over `JsIr` after lowering and removes bindings *inside* a declaration that is being
emitted. Two passes, two IRs, and neither is a fallback for the other. `Lower.Input` gains one more
field for it (§9).

## 4. Codegen, construct by construct

Representation decisions are §9.4's and are not reopened here. What this section fixes is the
mapping.

| beni | JavaScript |
|---|---|
| top-level value | one `const` per declaration, module-qualified name in dev, short name in release |
| function of *n* parameters | one function expression of arity *n*; no arity tag (§6) |
| a pattern in an irrefutable position | a fresh name plus a destructuring statement, **with no test** — a parameter, a `let` pattern and a `<-` bound pattern alike. Correct by construction: `language.md` §7 makes all of them irrefutable, the parser refusing the shapes no type can rescue and `checker.md` §6.6 refusing a constructor whose type has more than one, so a pattern that could fail never reaches lowering. A single-constructor type destructures through whichever shape §9.4 gave it — `{$: "Tag", a, b}`, or the bare tag when its one constructor is nullary |
| saturated call at known arity | direct call `f(a, b)` (§6) |
| record | object literal, keys in a canonical sorted order so one hidden class per record type |
| constructor | `{$: tag, a, b}` padded to a uniform shape per type; tag is a string in dev, an integer in release |
| nullary constructor | the bare tag |
| tuple | fixed-shape object per arity, no runtime tag |
| list | cons cells (`{$:1, a, b}` / the empty singleton), pending M3c's benchmark of a vector trie |
| string | native JavaScript string; core's API exposes codepoints where the UTF-16 mismatch would show |
| `Int` | a number; `Int32` a number kept in range by its operations (§3.1) |
| `case` | a decision tree (§7) |
| `if` | conditional expression when both arms are expressions, else `if`/`else` |
| `let` | `const` in the enclosing statement list; a `let` whose bindings are mutually recursive becomes function declarations |
| string interpolation | template literal |
| `?` | the `case` it desugars to, over the enclosing function's early return |
| `foreign` | an `import` from the sibling file, one binding per foreign value (`boundary.md` §4) |
| method call, resolved to a declaration | a direct call of that declaration, receiver first: `x.m a` is `M$m(x, a)` |
| method call on a `primitive` target | the JavaScript operator the surface origin names — `===` for `==`, and the `Order` result of `compare` tested in place rather than built |
| return-type dispatch | a direct call of whatever the constrained variable resolved to, or of the evidence parameter standing in for it |
| a declaration that carries constraints | hidden **leading** parameters, one per constraint in canonical order, invisible in beni and fixed at every call site by the checker |
| a derived `eq` / `compare` | a generated top-level function per type or per structural shape, emitted sorted by printed name |

The last five are static dispatch's, and
[`static-dispatch-spike.md`](static-dispatch-spike.md) §8 and §9 are the contract: §8 for the four
call shapes and the evidence convention, §9 for the exact JavaScript of every derived function.
Nothing here reopens a representation decision — §9.4's shapes are what derivation walks.

### Corrections from M3a

Three rows of that table did not survive contact with the code. Each is a
decision the implementation had to make and §4 did not:

1. **`Basics.Bool` is JavaScript's `true`/`false`.** §4 has no row for it and its general rule —
   a nullary constructor is the bare tag — would make `True` the string `"True"`, so `if` would
   compare strings and `&&` could not be `&&`. The special case is keyed on core's `Basics.Bool`,
   not on a name, so a user's own `type Bool = True | False` is an ordinary ADT.
2. **"Nullary constructor → the bare tag" and "padded to a uniform shape per type" cannot both
   hold**, and §9.4 states both. For `Maybe`, a bare `"Nothing"` beside `{$:"Just",a}` is exactly
   the shape inconsistency §9.4 measures 11% on Firefox for. M3a splits on the TYPE: a type whose
   constructors are *all* nullary is a bare tag string (`Order` is `"LT"`), and a type with any
   argument-taking constructor pads every constructor (`Nothing` is `{$:"Nothing",a:null}`).
3. **`&&` and `||` are lowered here, not at print time.** §9.4 files the primitive peephole under
   optimisation. For these two it is not one: `language.md` §6.5 desugars them into calls of
   `Basics.and`/`Basics.or`, a call evaluates both arguments, and `Basics.and` is `foreign`
   precisely so that it does not. A saturated call of either becomes `&&`/`||`, and when the right
   side needs statements of its own it becomes the `if`/`else` a short circuit really is.
   Arithmetic and comparison stay calls in M3a; that peephole really is M3c's.

And one thing §4's table is silent on that the emitter had to settle: **where the empty list comes
from.** "cons cells (`{$:1, a, b}` / the empty singleton)" does not say who owns the singleton, and
it cannot be a sibling export because `boundary.md` §4's second check forbids a sibling from
exporting anything that is not a declared `foreign` value. M3a emits `{$:0,a:null,b:null}` inline,
and `core/List.js` and `core/String.js` build the same shape by contract. That contract is the one
piece of the representation that is written down in two places.

Two more rows the table states and M3a did not need: a **`Char`** is a one-scalar JavaScript string
(§4 says strings are native and core's API exposes code points; a `Char` is the one-character case
of that), and **`()`** is `null`. Neither is contentious; both are recorded because the table did
not say.

**Lists and strings are the two representation questions §14 left open.** M3a ships cons cells and
native strings, which are Elm's answers and the ones pattern matching and interop respectively push
toward. M3c benchmarks a 32-way persistent vector trie against cons cells on real idiomatic code, as
open question 2 requires, and records the result here either way.

## 5. Module output and linking

Dev: one `.mjs` per module, ESM `import`/`export` between them, names as `Module$name` so a stack
trace is readable; each module's sibling JavaScript beside it as `<Module>.foreign.mjs`, and the
platform's runtime as `platform/<name>.foreign.mjs` (§2). Release: chunks (§8), every surviving declaration emitted into its chunk with a
short name, and the cross-chunk bindings synthesised by the assigner.

A platform declares its output shape (`boundary.md` §5.2) — what the artifact looks like and how
`main` is invoked. The emitter is parameterised by it.

**Derived functions are module-local and named by the compiler**: `<Module>$<Type>$eq` for a
nominal type, `<Module>$eq$<shape>` for a structural one, emitted **sorted by printed name text**
rather than in the order the checker asked for them, so a reader can check determinism without
reasoning about discharge order (CLAUDE.md rule 5). Derivation is **eager** — every declared
nominal type ships both, called or not — which is why §9's reachability elimination stopped being
an optimisation and became a prerequisite (`fast-compiler.md` §13). And `Lower.emissionOrder` must
walk the dispatch table's sites **as well as** `bir.refs`: a method call is a reference the file
does not record, and without those edges a constant whose initialiser is a method call on this
module's own type is a temporal-dead-zone throw in a well-typed program.
→ [`static-dispatch-spike.md`](static-dispatch-spike.md) §8.5, §1.4.

### What a module looks like after elimination

§9 decides *what* survives; this is what the file shape does about it. Four consequences, and none
of them is a new mechanism:

- **An unreachable declaration is not lowered, not printed and not exported.** `Lower.exports`
  (`src/js/Lower.zig:637-680`) builds its list from `bir.interface`, the dispatch table's nominal
  `derived` rows and the entry declaration; each of the three is filtered by the surviving set, so
  an export list shrinks to exactly the surviving names it used to hold. It does **not** shrink to
  what someone imports: a `pub` value that survives because something reaches it stays exported
  under its own name, because an export costs the name once and a consumer-driven export list would
  make one module's bytes depend on another's, which is a determinism hazard for nothing.
- **Import lists shrink for free on one leg and need one line on the other.** Cross-module imports
  are already use-driven — `need` / `needDerived` collect them as lowering discovers them
  (`src/js/Lower.zig:743-759`) — so a dropped declaration takes its imports with it and a module
  with no surviving reference to another emits no `import` of it. The **sibling** import is not:
  `importStatements` walks `bir.decls` and imports every `foreign_value` whether used or not
  (`src/js/Lower.zig:688-695`). That loop gains the surviving-set test, so an unreachable `foreign`
  is not imported.
- **A module with nothing reachable is not written at all**, and nothing imports it because imports
  are use-driven. `emitModules` (`src/js/Emit.zig:673-717`) skips producing it. A **sibling file**
  is copied iff the module has a *surviving* `foreign_value`, which replaces `copyAssets`' current
  "declares any `foreign`" test (`src/js/Emit.zig:725-729`). The platform's runtime is still copied
  unconditionally: `main.mjs` imports its `run` (§2), so it is a root by construction.
- **Emission order is unchanged and still correct.** `emissionOrder` (`src/js/Lower.zig:496-538`)
  post-orders `bir.refs` plus the dispatch sites; its outer loop is restricted to surviving
  declarations, and it can reach nothing else, because every edge it walks is also a reachability
  edge. So the survivors come out in the same relative order they have today and the temporal dead
  zone stays closed. The derived pass (`synthesisedValues`, `:1886`) keeps its two sorted runs and
  iterates only surviving rows.

**Elimination decides what is written, never what is checked.** `checkForeignShapes` and
`checkSiblings` run before the entry is even found (`src/js/Emit.zig:145-146`) and keep running over
every module of the graph, reachable or not: `boundary.md` §4's four checks are a contract on
privileged code, not an optimisation, and a sibling that grew an extra export must fail the build
whether or not anything imports it. What *does* go quiet is a **lowering** diagnostic in a
declaration nobody reaches — it is not lowered, so it is not raised. That is deliberate and is the
one behaviour change a user can see: a program whose only use of `?` is in dead code now builds
(§1's `not_implemented`). Code that is not emitted cannot miscompile.

## 6. The calling convention

**There isn't one.** `fast-compiler.md` §9.3 dropped automatic currying on 2026-09-14 and
`language.md` §6.7 specifies the result: every call is saturated, arity is part of the function
type, and function types of different arity do not unify. So a beni application of *n* arguments
emits a JavaScript call of *n* arguments, `f(a, b)`, and there is nothing else to emit.

**What leaves this document.** The arity tag, the `A2`/`F2` adapter, the saturated-call
specialiser, the call-site curry wrapper `((x) => (y) => f(x, y))`, the `Arity.unknown` path, and
M3c's obligation to measure the direct-call share. The share is 100% by construction, so there is
no number left to decide anything. Elm pays roughly 49% on Chrome for routing saturated calls
through its adapter; there is no adapter here to route through.

**Why the backend never meets a partial application.** The two ways to write one are both
front-end rewrites that are gone by the time BIR exists (`language.md` §8): `f a _` lowers to a
lambda over the innermost enclosing application, and `e |> f a` lowers to the call `f e a`. A
function-typed value in flight is therefore always a closure of known arity, never a partially
applied thing waiting for more arguments, and a call through a parameter is a call of that
parameter's arity, which the checker knows.

**Static dispatch extends that invariant and does not break it.** Evidence is a function value in
flight, and a piece of evidence that itself takes evidence has a *hidden* arity the receiving
parameter's beni type does not show — so passing it by bare name would be a partial application by
the back door. It is passed **eta-expanded** instead: a closure of exactly the beni arity that
supplies its own evidence inside. Evidence with no evidence of its own is passed by bare name. So
the sentence above still holds as written, with "known arity" meaning the beni arity at every
point. The hidden leading parameters are a *calling convention for a declaration*, fixed by the
checker at every site, and never something the backend has to discover.
→ [`static-dispatch-spike.md`](static-dispatch-spike.md) §8.1, §8.2.

**What this does not remove.** The absence of a runtime library still holds and still matters:
`boundary.md`'s wall means the only hand-written JavaScript in a build is core's siblings, and a
codegen helper would be neither that nor beni. Dropping the adapter makes that easier to keep, not
harder — it was the one helper this section had ever needed.

## 7. Pattern matching

Decision trees, Scott and Ramsey's heuristics, compiled to a native `switch` for multi-way tests on
a constructor tag. Single-use branches inline; multi-use branches are shared through a labelled
block. The checker has already proved exhaustiveness (`checker.md` §6.6), so **the tree needs no
default arm for a well-typed match** and the absence of one is not a latent crash.

Today's lowering is not a tree. `caseExpr` (`src/js/Lower.zig:3573`) walks the branches in source
order and, per branch, builds the whole conjunction of tests that branch needs from the root
(`patternTest`, `:3683`) and then all of its bindings (`bindings`, `:3788`), so every branch
re-tests what the branches above it already disproved. What follows replaces that with one tree over
all branches at once. **§8's loop does not depend on this section and landed first**; what this
section inherits from it is `tailStmts`/`tailCase` (`:1099`, `:1120`), a lowering of an instruction
in tail position straight into a statement list.

### What today's lowering costs, measured

Three programs, compiled with the binary at `889c4fa`. "Tests" counts `===` operands in the emitted
function; "worst path" counts the comparisons one call executes on its slowest input.

| Program | Tests emitted | Distinct | Worst path | `if` nesting | The tree emits |
|---|---|---|---|---|---|
| `describe : Shape, Colour -> String`, 5 rows over a 2-tuple of ADTs | 6 | 4 | 4 | 4 | one 3-label `switch` + 3 `if`s; worst path 2 |
| `classify : List Int -> String`, 5 rows mixing `[]`, `[ 1 ]`, `[ x ]`, `1 :: 2 :: rest`, `x :: y :: rest` | 10 | 6 | 7 | 4 | 5 tests total; worst path 4 |
| `run : List Token, Int -> Int`, 10 rows over a 9-constructor enum inside a cons | 17 | 10 | 17 | 9 | one `if` + one 9-label `switch`; worst path 2 |

The last column was a prediction when this was written and is the **measurement** now
(`tests/corpus/run/Match*.beni` are the three programs). Two of the three landed as predicted; the
`classify` row did not, and the prediction was wrong rather than the tree. Distinguishing `[ 1 ]`
from `[ x ]` from `1 :: 2 :: rest` from `x :: y :: rest` needs four questions of a two-cell list —
is there a first cell, is there a second, is the first `1`, is the second `2` — so four is the
floor for its worst path and no column order reaches three.

In the third, `ts$1.$ === 1` is written **eight** times, and the `case` is the body of a §8 loop, so
that is up to eight comparisons per list element. In the first, the scrutinee is a tuple literal and
the lowering allocates `{ a: shape$1, b: colour$2 }` per call purely to read both fields back out.
Two costs the table cannot show: `day : Int -> String`, five integer literal rows, emits a four-deep
`===` ternary chain where a `switch` is one dispatch; and building
`tests/corpus/run/Dictionaries.beni` writes 69,566 bytes over sixteen `.mjs` files holding 175
`===`, **41 scrutinee temporaries** (`const $t$n = …`, from `bindSubject` at `:3669`, which binds
any non-name scrutinee even when the tree reads it once — every `if` in the language pays this, both
in `emit/TailCallLoop.js` included) and **76 result temporaries** (`let $t$n;`, an assignment per
arm and a `return $t$n`, from a `case` that is a whole function body and could have returned from
each arm).

### The matrix, and what a column is

A `case` of *m* branches is a matrix of *m* rows and one column, the scrutinee; each row carries its
branch's pattern, its body and a binding list. Compilation is Maranget's: pick a column, ask which
constructors occur in it, and for each one **specialise** — keep the rows whose pattern there is
that constructor or a wildcard, replacing the constructor's with its argument sub-patterns in place,
so the column becomes *arity* columns. A column of wildcards everywhere is dropped; a matrix whose
first row is all wildcards is a leaf. Pattern forms are simplified exactly as `check/Exhaustive.zig`
simplifies them, and the vocabulary is deliberately shared with it:

| Form | In the matrix | Emitted test |
|---|---|---|
| `_`, `x` | *anything*; `x` adds a binding of this occurrence | none |
| `p as x` | `p`, plus a binding of this occurrence to `x` | `p`'s |
| constructor | a constructor of the declaring `type`'s union, in declaration order | `ctorRepOf` (`:1278`): `subj` for `.boolean`, `subj` for `.bare_tag`, `subj.$` for `.tagged` |
| tuple, `()` | the sole constructor of a one-constructor union — **always matches**, so it never becomes a test; it expands into *n* columns (0 for `()`) | none |
| record `{ a, b }` | *anything*, with one binding per named field: a record type has no alternatives | none |
| `[]`, `x :: xs` | the two constructors of the list union on the emitter's `{$:0}`/`{$:1}` shape (§4) | `subj.$ === 0` / `=== 1` |
| `[ a, b, c ]` | **normalised to `a :: b :: c :: []`** before the matrix is built | the cons tests |
| `Int`, `Char`, `String` literal | a literal with infinitely many alternatives, so the node always keeps a default edge | `===` against the literal |

The matrix is `js/Decision.zig`, which reads those forms off `Bir` and knows no representation at
all; `js/Lower.zig` turns the tree it returns into the JavaScript of the third column. A literal
edge carries the pattern instruction that spells it and a constructor edge the reference that names
it, which is what the emitter reads `ctorRepOf` from — so the representation is decided in exactly
one place, as it was before.

`-1` is an `Int` literal, and **there are no `Float` patterns and no guards** — `language.md` §3's
`PatAtom` admits `int | char | string-without-interpolation | '-' int` and nothing else — so a
literal node is always a `===` fan-out with a default and never a range test or a side condition.
A `Char` is a one-scalar string (§4), so its test and a `String` literal's are the same `===`.

**The checker leaves nothing behind to reuse.** `check/Exhaustive.zig` is a usefulness analysis over
`Bir` patterns returning diagnostics and no artifact, and it reads no solved type. So the backend
builds its own matrix from `Bir`.

**"The checker proved exhaustiveness" now holds without a hole.** It did not when decision trees
landed: usefulness is exponential (`checker.md` §6.6), and a `case` that exhausted `pattern_budget`
reported **nothing**, so it could reach the backend non-exhaustive, take the default-free last edge
and compute a wrong answer rather than throw — at exit 0, with no diagnostic anywhere. That hole was
reachable at the DEFAULT budget and with no flag: a `case` over about 440 `Int` literals costs more
than 200 000 steps, and one written without its wildcard compiled and printed the last branch's
answer for every unmatched input. Queue slice 14 closed it at the checker, where it belonged: an
undecided `case` is now `pattern_budget_exhausted`, an error, so nothing the backend receives is a
`case` the checker declined to decide. The tree still carries no default arm, and it still needs
none.

### Choosing a column

Among the columns that are **relevant** — those in which at least one row has anything other than a
wildcard — apply these in order and stop at the first that leaves one column:

1. **d, small default** (Scott & Ramsey; Elm's `pickPath` uses it first): fewest rows whose pattern
   in that column is a wildcard. A wildcard row is copied into *every* specialisation, so this is
   the heuristic that directly minimises duplicated rows.
2. **b, small branching**: fewest distinct constructors or literals present.
3. **leftmost**: the lowest column index.

Rule 3 is not a formality: it is what makes the choice **input-derived** (CLAUDE.md rule 5). Column
index is the pattern's structural position, the constructor set at a column is enumerated in the
declaring `type`'s declaration order — `Bir.ctors` or the interface, the source `Exhaustive.zig`
already uses — and nothing here consults a hash map's iteration order or a thread, so `--jobs=1` /
`--jobs=8` covers the section with no new machinery.
*Alternatives rejected: necessity-first (Maranget 2008 §8), a fixpoint per node for a gain Scott &
Ramsey measured as noise against d; and Elm's d-then-b with no positional tie-break, which leaves
the choice to whatever order the constructor set happened to be built in.*

### The emitted shape

**A node with three or more case labels is a `switch`; two or fewer is `if`/`else`.** `JsIr` has
held `switch_stmt` and `switch_case` since M3a (`src/js/JsIr.zig:146`) and the printer emits them
(`src/js/Print.zig:302`). At two alternatives there is nothing to dispatch and `if (x.$ === "A")` is
shorter than a `switch` naming the discriminant and adding two labels; at three the `switch` is both
shorter and one dispatch. The threshold is representation-independent, so it survives M3c turning
tags into integers and the dense cases into a jump table, and it removes every special case:
**a boolean node and a list node have exactly two alternatives and are therefore always `if`**,
which is why `if` keeps emitting what it emits today.

- The discriminant is `subj` for `.boolean` and `.bare_tag`, `subj.$` for `.tagged`, and the
  scrutinee itself for a literal node. `switch` compares with `===`, which is what every one of
  these tests already is.
- **Each `case` body is a block**, `case "A": { … }`. Two sibling cases may both bind — local
  indices keep the names apart (`localName`, `:1193`) so a redeclaration is impossible today, but a
  `switch`'s cases share one scope and one block per case ends that class of bug for two bytes that
  compress to nothing.
- **Every case body ends in a terminator** — `return`, `continue <label>` or `break` — because
  `switch` falls through. This is not a rule the tree has to remember: the leaf shapes below all
  terminate.
- **The last alternative of an exhaustive constructor fan-out is `default:`**, not `case "C":`, and
  nothing is emitted for the impossible arm — it saves a label and a `throw` per `switch`, and it is
  byte-for-byte what today's chain does when it emits the last branch unconditionally (`:3630`).
  Which one: the one declared **last** in the type among those present at the node, input-derived
  with no tie-break. When the node has a genuine default edge that edge is `default:` and every
  present constructor gets its own `case`; a literal node always has one, since a literal column is
  never exhaustive without a wildcard row. **A wildcard row is not by itself a default edge**: a row
  that is a wildcard in this column is copied into *every* specialisation already, so once the
  alternatives present are all the type has, the default arm is unreachable — it is the impossible
  arm this rule refuses, and emitting it would cost a second copy of whatever the wildcard rows
  decide. So the edge exists only when the present set is *incomplete*, which is Maranget's
  condition and is what makes `( Circle, Red ) | ( Circle, _ ) | …` two `if`s over a two-constructor
  `Colour` rather than two `switch`es. *Alternative rejected:
  `default: throw new Error(…)`, a diagnosis for a state the checker excludes, at a string per
  `switch` in every program.*
- Adjacent `case` labels reaching the same body are **not** merged into `case "A": case "B":` — a
  printer-level win, and M3c's.

**Bindings are emitted at the leaf, and an occurrence is a member chain, not a name.** A pattern
variable's occurrence — `subj.a.b` — is fixed by its position in the pattern and is therefore the
same expression on every path that reaches its leaf, which is what lets the leaf own its bindings
even when it is shared. The chain is rebuilt at each use: every value is immutable and every
occurrence is a property read on a `{$, a, b}` object, so re-reading costs and risks nothing, and
the one expression that must be evaluated exactly once is the scrutinee. *Alternative rejected: a
`const $p$k` per tree edge, Maranget's usual presentation — it makes "evaluated once" literal and
costs one live binding per edge that M3c's dead-binding pass cannot remove, for a property read V8
already inline-caches.*

Two changes to how the scrutinee itself is bound. **`bindSubject` binds unless the tree reads the
root exactly once**: a two-alternative boolean node reads it once, so `const $t$1 = n$1 <= 0; if
($t$1)` becomes `if (n$1 <= 0)`, and every `if` in the language is a `case` (`language.md` §8), so
that is the 41 scrutinee temporaries above. Exactly once, and not "at most once", because a tree
that reads the root ZERO times — `case f x of _ ->` — would otherwise not evaluate `f x` at all,
and deciding that a beni expression is dead is the optimiser's job and not this one's. The count is
one fan-out per test of that root plus one per `const` its leaves bind, over the branches the tree
actually reaches; a root read once is therefore read on every path, because a tree with any fan-out
over it tests it before any leaf binds it. And **a `case` on a tuple literal starts as an
*n*-column matrix over the tuple's elements**, each bound by `bindSubject` in source order, with no
tuple object built at all. The condition is syntactic — the scrutinee is a `Bir` `tuple` node and
**every** row's pattern is a tuple pattern or a bare `_`; a row binding the tuple as a whole, by
name or by `as`, needs the object and turns the rule off. There is no `case a, b of` syntax, so a
tuple scrutinee *is* how this language writes a multi-column match, and the matrix gets it for free.

### Sharing a leaf reached from two paths

A leaf reached from exactly one path is **inlined** where it is reached. A leaf reached from two or
more is written **once**, and every path reaches it by `break`ing out of a labelled block that ends
immediately before it:

```js
$j$0$4: { <the tree; a path reaching branch 4 emits `break $j$0$4;`> }
<branch 4's bindings>
return <branch 4's body>;              // tail position: no wrapper needed

let $t$1;                              // expression position: one `$c$<d>` wrapper,
$c$0: {                                // and shared leaves nest lowest-index-innermost,
  $j$0$4: {                            // so their bodies read in source order
    $j$0$2: { <the tree> }
    <branch 2>  $t$1 = …; break $c$0;
  }
  <branch 4>  $t$1 = …;
}
```

`$j$<d>$<b>` labels the block whose exit is branch *b*, *d* being the number of enclosing `case`
instructions in the function being lowered; `$c$<d>` wraps an expression-position tree that needs
one. Both are structural, so a golden does not renumber when an unrelated declaration is added above
it, and two cases at one depth are siblings and never nested, so the names cannot collide. The
`break $c$<d>` on the textually last leaf is omitted.

**This composes with §8 by construction, verified by hand on Node 24.19.0.** `break <label>` leaves
a labelled block from inside a `switch` case, and `continue <label>` targets the nearest enclosing
*iteration statement* with that label — a labelled block is not one — so a tail self-call inside a
shared leaf inside a `switch` inside a shared block still reaches the function's `while (true)`.
That is what §8's "the `continue` is labelled, not bare" was reserved for.

*Alternatives rejected. A local arrow per shared leaf, `const $j$4 = (x, y) => …`: it reads better
and it is disqualifying, because `continue <function label>` cannot cross a function boundary, so
§8's loop would silently stop applying to exactly the matches that need it most. Duplicating a
shared leaf below a size threshold: duplication is what a decision tree is exponential in, and the
counted rule — one path inline, two or more shared — is Elm's `Optimize/Case.hs`
`countTargets`/`createChoices`, by report 03 §5.4 (`references/elm` is a submodule pointer and is
not initialised on this machine, so that is the report's reading of it and not mine). And Elm's own
`label: while (true) { … break label; }`, a labelled block wearing a loop's clothes, which would put
a second `while` between a `continue` and §8's.*

### Where the `case` sits

| Position | Leaf shape | Wrapper |
|---|---|---|
| tail (the function body, or through `let`/`case` from it) | `return <expr>;`, or §8's assignments and `continue <label>` for a tail self-call | none needed: both terminate a `switch` case and escape every labelled block |
| expression, and the tree has a `switch` or a shared leaf | `$t$n = <expr>; break $c$<d>;` | `let $t$n;` above one `$c$<d>` block |
| expression, pure `if`/`else` chain | `$t$n = <expr>;` and fall out of the arm | `let $t$n;`, exactly as today (`:3620`) |
| expression, no `switch`, no shared leaf, every leaf one expression and no bindings | the value | a `cond` chain — `a ? b : c`, exactly as today (`:3599`) |

**§8's gate on the statement form is removed.** §8 used `tailStmts` "only inside a function that has
at least one tail self-call, so every existing `emit/` golden stays byte-identical"; M3b lowers a
`case` in tail position into statements whether or not the function loops, deleting the `let $t$n;`
/ assign / `return $t$n` triple from every function whose body is a `case` — the 76 result
temporaries above. `Maybe.withDefault` becomes

```js
if (maybe$1.$ === "Just") {
  const value$3 = maybe$1.a;
  return value$3;
} else {
  return $default$2;
}
```

— an `if`/`else` and not an `if` with the last arm behind it, because a two-alternative node is
`if`/`else` by the rule above and nothing here special-cases the shape of its second arm; and the
binding is a `const` at the leaf, because that is where §7 puts bindings.

`if` and `?` need nothing of their own: both are a `case` by the time the backend sees them
(`language.md` §8, §6.6). An `if` is a two-alternative boolean fan-out, which the ≥3 threshold keeps
as the `if`/`else` it is today; `?` is a two-branch `case` whose first arm returns from the
enclosing function, which is what the tail-position statement form makes expressible at all. §7 is
the machinery `?` has been waiting for, and lifting its `not_implemented` diagnostic is a slice of
its own, not this one.

**Irrefutable patterns keep their own path.** A `let` pattern is irrefutable by grammar
(`language.md` §7) and a function or lambda parameter pattern is *intended* to be. Both are a
one-row matrix with no relevant column, so the tree is one leaf whose output is that leaf's bindings
— byte-identical to what `letBindings` (`:3497`) and `functionOf`'s destructuring prologue (`:745`)
emit today by calling `bindings` directly, and they keep calling it. `language.md` §3's `Definition
:= lower_ident PatAtom* '=' Expr` does in fact admit a *refutable* parameter pattern, nothing
rejects it, and `un (Just n) = n` applied to `Nothing` returns `null` today; that is a front-end or
checker defect (`plans/m3b-audit.md` M1) and §7 must not be extended to paper over it, because the
tree would have nowhere to send the failing value either.

### What must not change

- **Behaviour.** Every `tests/corpus/run/` fixture stays green with **no `.expected` change**. A
  decision tree computes what a linear chain computes; if a `.expected` moves, the tree is wrong.
- **Determinism.** `--jobs=1` and `--jobs=8`, twice each, byte-identical.
- **Derived `eq` and `compare` are out of scope.** They are emitted by `nominalArrow` /
  `structuralArrow` (`:2186`, `:2090`), which build their own `switch` from the dispatch table and
  never touch a `Bir` pattern (`static-dispatch-spike.md` §9). `emit/Derived*.js` must not move.
- **Five existing `emit/` goldens change, and no sixth.** This bullet said "exactly one" and was
  wrong on its own terms: `emit/TailCallLoop.js` loses two `const $t$n = n$1 <= 0;` temporaries into
  the `if` and the ternary that read them once — and `emit/ConstantMethodCall.js`,
  `emit/EvidenceParameters.js`, `emit/EvidenceValue.js` and `emit/MethodTargets.js` each hold a
  function whose whole body is a `case` over a **one-constructor** type, which is the `let $t$n` /
  assign / `return $t$n` triple this section deletes, not a `case` over a boolean. (`EvidenceValue`
  renumbers two `$p$n` besides, because the module-wide counter behind every compiler-made name no
  longer spends a tag on the temporary that went.) The rest of the corpus is untouched, so a sixth
  that moves is a finding and not a blessing.

### Fixtures

`run/` unless the row says otherwise; §12's rule that behaviour is proved by running still holds.

| Fixture | Intent | Observable |
|---|---|---|
| `MatchNested` | constructors inside constructors, and a tuple scrutinee whose rows overlap — `describe` above | the strings; wrong specialisation picks the wrong arm |
| `MatchRowOrder` | rows that overlap and whose order decides, swapped in a second function. Not "a specific row above a general one", which this row said and the checker refuses as `redundant_pattern`: two rows that overlap where neither shadows the other — `1 :: n :: _` and `n :: 2 :: _` — and which bind the same NAME at different occurrences | the two differ; a tree that loses source order makes them equal, and one that carries a binding down an edge instead of rebuilding it at the leaf gets the right string with the wrong number |
| `MatchLiteralFallthrough` | `Int`, `String` and `Char` literal rows with a `_` fallback, enough of each to cross the `switch` threshold | every literal and one miss per type |
| `MatchSharedLeaf` | a leaf reached from two paths, binding pattern variables, exercised down both | the same answer from both, with the bindings right on each |
| `MatchInLoop` | a `case` inside a §8 tail-recursive loop deep enough to overflow without it, where the `continue` crosses a `switch` **and** a shared leaf's labelled block | the sum at a depth of 1 000 000 (and see below: this one passes before the change too, because §8 landed first) |
| `MatchListDepth` | `[]`, `[ x ]`, `[ 1 ]`, `x :: y :: rest`, `1 :: 2 :: rest` in one match — `classify` above | one line per shape, including the ones the current chain gets right only by luck |
| `MatchRecordsTuples` | records and tuples nested inside constructors, and a tuple scrutinee with a row that binds the whole tuple (so the object *is* built) | the values; proves the tuple rule's off-switch |
| `MatchAsPattern` | `as` at the top of a row, on a nested sub-pattern, and on a shared leaf | the bound whole and the bound part |
| `MatchBigEnum` | a nine-constructor enum inside a cons, in a loop — `run` above | the fold's answer |
| `emit/MatchSwitch` | the shape: one `switch`, blocks per case, the last constructor as `default:`, no `throw` | golden |
| `emit/MatchSharedLeaf` | the shape: `$j$<d>$<b>`, the `break`, the leaf written once | golden |
| `emit/MatchNested` | the shape: no test appears twice on any path, and no tuple object is allocated | golden |

§12's fail-first discipline applies to every `run/` row: each is written so the current chain either
gives a different answer or is pinned by an `emit/` golden that changes.

**What that came to, honestly, and it is not what the paragraph above predicted.** Run against the
binary at `ebacb5b`, with every fixture of this table in place, **eight `emit/` goldens fail and no
`run/` fixture does** — the three new ones, and the five §7 knew it would move. Every `run/` row
passes before *and* after, by design and not by accident: a decision tree computes what a linear
chain computes, which is the first line of "what must not change", so a behaviour fixture for this
slice guards the rewrite rather than reproducing a defect. That includes `MatchInLoop`, which this
section expected to overflow without the fix and does not: §8's loop landed FIRST, so the `continue`
was already a jump before the tree put a `switch` between it and the `while` — what `MatchInLoop`
proves is that it still is. The fail-first rows are the `emit/` goldens, and `MatchRowOrder` is the
one written to tell a wrong tree from a right one rather than to document a shape — overlapping
rows, source order deciding, and one name bound at two different occurrences. It is the row to read
first when this lowering is next changed.

### Measurement

`bench/size.mjs` and `bench/runtime.mjs` are the instruments, and each claim is a **direction, not a
promise**; both are recorded here whichever way they come out. Compressed size should fall — fewer
tests, fewer temporaries, one mention of a discriminant per fan-out instead of *n*, and `switch` and
`case` are as compressible as tokens get — against shared-leaf labels and rows a wildcard column
duplicates. Runtime should fall on anything that matches in a loop, where the third program above
runs up to eight comparisons per element that a tree never runs. **Emit throughput must not regress
beyond noise** (§13, 85.5 MB/s at M3a): the tree is built per `case` over a matrix of branches ×
columns, the same input the linear chain already walks once per branch, and the exponential case is
the checker's usefulness relation and not this one. If a corpus module's emit time moves, a
heuristic is being recomputed where it should be cached — an implementation bug, not a design cost.

**Measured**, `ebacb5b` against the slice, on the same corpus both times (80 programs, the fixtures
of the table above included), five iterations of `bench --generate=100000`:

| | before | after | |
|---|---|---|---|
| `bench` emit, wall clock | 53.92 ms | 46.92 ms | −13% |
| `bench` emit, JavaScript written | 3,872,156 B | 3,045,688 B | **−21%** |
| `bench` emit, MB/s | 68.5 | 61.9 | −9.6% |
| `size.mjs` raw, 80 programs | 268,916 B | 268,707 B | −0.1% |
| `size.mjs` gzip | 52,443 B | 50,911 B | −2.9% |
| `size.mjs` brotli | 46,160 B | 45,938 B | −0.5% |
| `size.mjs` floor (core + platform) gzip | 16,880 B | 16,215 B | −3.9% |
| `runtime.mjs --variant=c1`, ns/op | — | — | −12% to −23%, every program, checksums identical |

Two of those read the wrong way round unless the denominators are read with them. **Emit MB/s
falls while emit gets faster**: the metric is output bytes over time, the slice removes a fifth of
the output bytes, and the same 100k lines are lowered in 13% less wall clock — 1.92M to 2.21M
lines/s. §13's budget is "> 5 MB/s of JavaScript", which this is 12× over; the throughput this
section told the implementer not to regress is the one per line of input, and it improved. And
**raw size barely moves while compressed size falls**: the block per `switch` case and the labelled
block per shared leaf cost braces that the temporaries and repeated tests paid for elsewhere, and
braces are the cheapest bytes a compressor ever sees. The direction §7 predicted — compressed size
down, runtime down on anything that matches in a loop — holds; the size win is smaller than the
runtime one, and the runtime one is larger than expected because `Dict` and `List` match in every
inner loop `bench/runtime` has.

## 8. Tail calls

Direct self-recursion lowers to `label: while (true)`. **This is mandatory, not an optimisation**:
no JavaScript engine reliably provides tail-call elimination, V8 shipped and reverted it,
SpiderMonkey never shipped it. Node 24 overflows a two-parameter accumulator between 5 000 and
10 000 frames, which is why `bench/runtime/c1/R1DictString.beni:11` builds its key list out of two
small ranges and why `core/List.beni:71,77` said `foreign` until this slice. Mutual recursion
remains a real stack frame and ships as a stated limitation (§14 question 5).

`JsIr` has held `while_true`, `break_stmt`, `continue_stmt` and `assign_stmt` since M3a
(`src/js/JsIr.zig:141`) and the printer already emits them (`src/js/Print.zig:284`); what M3b adds
is the lowering.

### What a tail call is

Over `Bir`, a **tail position** of a function is its body; every branch body of a `case` in tail
position — which covers `if` and `?`, both of which are a `case` by the time the backend sees them
(`language.md` §8, §4); and the `in` body of a `let` in tail position. Nothing else is: not an
operand, not an argument, not a `let`'s bound value, not a lambda body, not the left of a `|>` (a
pipe is a call before the backend sees it, §6), not the operand of `?`. Parentheses do not exist in
`Bir`, so looking through them is free.

A **tail self-call** is a `call` instruction in tail position whose callee is, syntactically, the
reference that names the function being lowered — a `top` for a declaration, a `local` for a
`let`-bound one — with argument count and evidence count equal to that function's own. Both
equalities hold by construction (calls are saturated, `language.md` §6.7, and the checker fixes
evidence at every site) and are still checked: a mismatch emits the ordinary call and no loop,
because a wrong loop is a wrong answer and a missing one is only a deep stack.

The cases, decided:

| Case | Loops? | Why |
|---|---|---|
| `f x acc = … f x' acc'` | yes | the case this exists for |
| `let go i acc = … go i' acc'` | **yes** | a `let_def` with parameters is already its own hoisted `function` (`src/js/Lower.zig:3135`), so the loop is contained; excluding it would leave the language's most natural loop idiom overflowing |
| `f = \x -> … f x'` | **yes** | `f x = e` and `f = \x -> e` emit byte-identical JavaScript today, and two spellings of one program must not differ in stack behaviour. The rule is narrow: a `lambda` that is the **entire** body of a parameterless declaration or `let_def` inherits that name; a lambda anywhere else never does |
| a self-call inside a nested lambda | no | a different function |
| a self-call through an alias, or `f` passed as a value | no | the callee must be the name itself, in callee position |
| the function's name shadowed | can't happen | shadowing is an error (`language.md` §7); `tests/corpus/parse/bad/ShadowingParam.beni` pins exactly a parameter named like a top-level value. The backend needs no scope test |
| a function with both tail and non-tail self-calls | yes | only the tail ones become jumps. `core/Dict.beni:128`'s `sizeHelp (sizeHelp (n + 1) right) left` is this shape in core today |
| a function with no tail self-call | no | its emitted shape is unchanged, byte for byte |

### The emitted shape

A parameter is **carried** when some tail self-call passes it anything other than a reference to
that same parameter. A carried parameter is renamed to `$in$<i>` in the JavaScript parameter list,
*i* being its position counting evidence first; the loop's prologue re-binds it to its ordinary
name with a `const`, one statement per carried slot — joining the run into a single
comma-separated declaration is §9 item 5's variable joining, a printer decision and M3c's, not
this slice's. A parameter that is not carried keeps its ordinary name and gets
neither slot nor copy. The test is syntactic and conservative — when in doubt, carried. A parameter
whose pattern is not a bare variable already has a compiler-made name and a destructuring prologue
(`functionOf`, `src/js/Lower.zig:745`); it takes a slot by the same rule, and **its destructuring
statements go inside the loop**, because they read this iteration's value.

```js
const List$foldl = ($in$0, $in$1, func$3) => {
  List$foldl: while (true) {
    const xs$1 = $in$0;
    const acc$2 = $in$1;
    if (xs$1.$ === 0) {
      return acc$2;
    } else {
      const x$4 = xs$1.a;
      const rest$5 = xs$1.b;
      $in$0 = rest$5;
      $in$1 = func$3(x$4, acc$2);
      continue List$foldl;
    }
  }
};
```

```js
const Main$count = ($in$0, $in$1) => {          // count n acc = if n <= 0 then acc
  Main$count: while (true) {                     //              else count (n - 1) (acc + n)
    const n$1 = $in$0;
    const acc$2 = $in$1;
    const $t$1 = n$1 <= 0;
    if ($t$1) { return acc$2; } else {
      $in$0 = Basics$sub(n$1, 1);
      $in$1 = Basics$add(acc$2, n$1);
      continue Main$count;
    }
  }
};
```

**There are no temporaries, and that is the load-bearing invariant.** `$in$<i>` is written in the
assignments and read in the prologue `const` and nowhere else; every argument expression is written
against the ordinary names, which hold this iteration's values and are never assigned. So the
assignments may run in parameter order with no `$temp$` in sight, and an argument swap is right by
construction. Elm reassigns the parameters in place and needs one `$temp$` per argument per call
site to do it; this scheme pays *n* copies once per function and *n* assignments per site against
Elm's 2*n* per site, so it ties at one tail call and wins at two, and the prologue line is the most
compressible kind of text there is (§9). *Alternative rejected: Elm's in-place scheme, fewer
bindings and correct only with a capture analysis — see below.*

Control leaves by `return` or by `continue <label>`; there is no `break` and nothing follows the
loop. The `continue` is **labelled**, not bare, because §7's decision trees put a `switch` and a
shared-branch block between the jump and this one. The label is the function's own emitted name —
`List$foldl`, `go$2` — input-derived, no counter, and it cannot collide because labels are a
separate namespace from bindings. `$in$<i>` is positional for the same reason (CLAUDE.md rule 5),
and two nested loops both using `$in$0` are safe precisely because neither ever reads the other's.
The parameter list keeps its count and order, so `.length` is unchanged and §6's eta-expansion of
evidence still sees the beni arity it expects.

### Closures, and the one way to get this wrong

This is the defect the design above exists to make impossible, and it exits 0.

```elm
build n acc =
    if n <= 0 then acc else build (n - 1) ((\x -> x + n) :: acc)
```

Each iteration conses a closure over `n`. Reassign `n` in place and every closure reads the last
value: `build 3 []`, then applying each to `0`, prints `0 0 0` instead of `1 2 3` — measured on Node
24 from both shapes written by hand. The per-iteration `const` fixes it because a `while` body block
gets a fresh declarative environment on every evaluation, so iteration *i*'s closures capture
iteration *i*'s binding. The copies are therefore **unconditional**: the answer has to be right for
lambdas, `f a _` placeholders, `<-` continuations and §6's eta-expanded evidence alike, and a
capture analysis that is wrong once is wrong silently.

`<-` is both at once. `let x <- f a in rest` is
`f a (\x -> rest)` (`language.md` §6.7), so when `f` is the enclosing function the **call** is a
tail self-call and loops, while the continuation is a different function and its body is **not** a
tail position of the outer one. The continuation closes over this iteration's parameters, including
over the callback parameter it is replacing — in-place reassignment there does not merely read a
stale value, it builds a closure that calls itself.

### Evidence parameters

The hidden leading parameters of §4 and `static-dispatch-spike.md` §8.1 are **ordinary parameters of
the loop**, carried or not by the same syntactic test. In the overwhelming case a self-call forwards
`$m$k` unchanged, so no evidence parameter is carried, none is renamed and none is assigned:
`countEq xs value acc` compiles to `($m$0, $in$1, value$2, $in$3)` with `$m$0` untouched —
the slot numbers count evidence first, so the first beni parameter is `$in$1` and not `$in$0`.

**"Evidence is loop-invariant" is not a rule, though, and stating it as one would be a miscompile.**
Polymorphic recursion is typeable here with an annotation and is accepted today: a `where`-constrained
declaration may call itself in tail position at a different instantiation, and the checker then writes
a *different* evidence expression at that site rather than `$m$k` — verified against the M3a binary,
where `f : List a, Int -> Int where a.eq` calling `f [ Red, Blue, Red ] (n - 1)` emitted
`Main$f(Main$eq$prim, …)`. The syntactic test catches it: the argument is not a reference to `$m$0`,
so `$m$0` is carried, gets a slot and is reassigned like anything else. A fixture is required.

### What this needs from `case`, and what it does not need from §7

**The loop does not depend on decision trees and must land before them.** What it does need is a
statement form of tail-position lowering, because `continue` cannot appear in a ternary or in an
IIFE and today's lowering produces both: `src/js/Lower.zig`'s `expr` returns an expression, and a
`case` becomes either one `cond` node or a `let $t$n;` above an `if`/`else` chain whose arms assign
it. Neither can hold a jump.

M3b adds a second entry point beside `expr`: one that lowers an instruction **in tail position**
directly into a statement list, emitting `return <expr>;` for everything that is not a tail
self-call, an `if`/`else` chain with each arm lowered the same way for a `case`, the bindings
followed by the body for a `let`, and the assignments plus `continue <label>` for a tail self-call.
It is used **only inside a function that has at least one tail self-call**, so every existing
`emit/` golden stays byte-identical and `a ? b : c` survives wherever it is still correct. §7 later
replaces the `if`/`else` chain with a tree; the contract this section needs from it is only that a
tail position be reachable as a statement.

### `foldl` and `foldr` leave `foreign`

The two of them are the reason this slice is scheduled where it is
([`research/17-platform-primitives.md`](research/17-platform-primitives.md) §3,
[`transparent-effects-proposal.md`](transparent-effects-proposal.md) §10 item 0): they are the only
`foreign` values in the repository with a function type anywhere in them, and a JavaScript loop
cannot park when its beni callback suspends. **They land in the same commit as the loop** — `core/`
is compiled into the binary, so a beni `foldl` without the loop is a stack bomb in core itself.

```elm
pub foldl : List a, b, (a, b -> b) -> b
foldl xs acc func =
    case xs of
        [] -> acc
        x :: rest -> foldl rest (func x acc) func

pub foldr : List a, b, (a, b -> b) -> b
foldr xs acc func =
    foldl (reverse xs) acc func
```

`foldr` is **reverse then `foldl`**, exact for this argument order, and `reverse` is
`foldl xs [] cons`, so there is no cycle. It costs one extra list of *n* cells per call, which is
not a regression: today's `core/List.js:30` already materialises the whole list into a JavaScript
array to fold it backwards. *Alternative recorded and not taken: Elm's `foldrHelper` (read at
`references/elm-core/src/List.elm:172` by report 17 §3.3; the submodule is not initialised here)
unrolls four elements per frame and falls back past 500, avoiding the allocation for short lists at
twenty-five lines and a magic number. Revisit if `List.map`, built on `foldr`, shows up in a
`bench/runtime` profile.*

`core/List.js` loses exactly the `foldl` and `foldr` exports, which `boundary.md` §4's second check
— the sibling exports exactly the declared names, no more — is what enforces; the other two checks
are unaffected. `core/List.beni`'s header list goes from five `foreign` declarations to three:
`cons` stays (`::` desugars to it), and `eq`/`compare` stay for a reason the loop does not touch,
that `List a` has no constructors for the compiler to walk. **Report 17 §3.4 counted 66 first-order
`foreign` values and exactly two that are not; after this slice the count of higher-order `foreign`
values in the repository is zero**, which discharges the first half of
`transparent-effects-proposal.md` §10 item 0 in fact and not only on paper.
*Corrected 2026-09-18: zero in a **signature**, not zero. `List.eq` and `List.compare` are `foreign`
with a `where` clause, so their siblings are JavaScript loops that call a beni function — the evidence
`m0` — and under the effects proposal's lowering that is the same hazard `foldl` was. It harms nothing
today, because a well-known `eq`/`compare` cannot suspend; [`plans/effects-plan.md`](../../plans/effects-plan.md)
§2 carries it.*

**Everything else stays where it is**, and the list is short because most of it needs no source
change at all. These are already beni self tail calls and simply stop overflowing: `List.rangeHelp`
(`core/List.beni:145` — the one `bench/runtime/c1/*` works around), `repeatHelp` (`:128`), `any`
(`:252`, and `all` and `member` through it), `takeHelp` (`:566`), `drop` (`:582`),
`splitHalfHelp` (`:472`), `mergeWithHelp` (`:496`), `Dict.getHelp` (`:92`), `Dict.getMin` (`:314`),
`Dict.sizeHelp` (`:128`, its outer call only). These stay real frames because their self-calls are
not in tail position: `List.map2`–`map5`, `List.sortWith`, `Dict.insertHelp`, `removeHelp`,
`removeMin`, `mapTree`, `foldlTree`, `foldrTree`. And `Basics.and`/`or` are `foreign` for
short-circuiting (§4), `String`'s twenty-two for the native representation, not for this.

### Fixtures

Every one of these is `tests/corpus/run/` unless it says otherwise; §12's rule that behaviour is
proved by running still holds, and the shape claim gets exactly one golden.

| Fixture | Intent | Observable |
|---|---|---|
| `TailCallDeep` | **the fail-first one.** A two-parameter accumulator counting to 1 000 000 | `500000500000`; overflows the stack before the fix |
| `TailCallSwap` | argument order: `swap a b n = … swap b a (n - 1)` | `2,1` then `1,2` for odd and even *n*; naive in-place assignment prints `2,2` |
| `TailCallClosures` | the capture hazard: cons a `\x -> x + n` each iteration, then apply each to `0` | `1`, `2`, `3`; in-place reassignment prints `0`, `0`, `0` |
| `TailCallNesting` | a tail call reached through `case` inside `let` inside `if`, and a nested `case` | any deep result, run at a depth that overflows without the loop |
| `TailCallNotTail` | `f n = if n <= 0 then 0 else 1 + f (n - 1)` must NOT loop, and a function with one tail and one non-tail self-call must still be right | small depths, exact answers |
| `TailCallBind` | `let m <- f (n - 1)`: the call loops, the continuation does not | `sumTo 3 (\x -> x)` is `1` |
| `TailCallEvidence` | a `where`-constrained function looping deep with evidence forwarded, **and** a tail self-call at a different instantiation whose evidence therefore changes | exact counts; the second half is the polymorphic-recursion case above |
| `TailCallLetFunction` | a `let`-bound helper counting to 1 000 000 | as `TailCallDeep` |
| `TailCallLambdaBody` | `f = \n acc -> … f …` counting to 1 000 000 | as `TailCallDeep` |
| `ListFoldDeep` | `List.foldl` over `List.range 1 1000000` and `List.foldr` over a list of 200 000 | the sums; proves the beni folds and `range` all survive |
| `emit/TailCallLoop` | the shape: label, `$in$<i>` slots, the prologue `const`, `continue`, and one loop-invariant parameter keeping its own name | the golden of §12 |

Shadowing needs no new fixture: `tests/corpus/parse/bad/ShadowingParam.beni` already refuses a
parameter named like a top-level value, which is the only way a self-call's name could be captured.

Determinism (CLAUDE.md rule 5) falls out: the label is the declaration's name, the slot names are
parameter positions, and nothing in the loop consults a counter that parallel work could reorder.
The `--jobs=1` / `--jobs=8` comparison covers it with no new machinery.

### Measurement

`bench/runtime.mjs` is the instrument. The visible effect is a follow-up rather than part of this
slice: `bench/runtime/c0/` and `c1/` split their workloads into blocks of 500 because
`List.range 1 2000` is near the stack limit, and once the loop lands those headers and their
`concatMap` scaffolding can go, which makes the R-programs shorter and their `ns_per_op` comparable
to a plain range. **What must not regress is §13's emit throughput** — the loop adds one walk of
each function body's tail positions, O(body), once — and no `run/` or `emit/` fixture that does not
involve a self tail call may change at all.

## 9. The optimiser, ranked by compressed bytes

Report 12 ranked these by what they are worth **after compression**, which inverts the raw-byte
ranking. Build them in this order:

1. **Local dead-binding elimination** over `JsIr` before printing — one use-count pass, and alone
   worth 66% of the entire compress layer's compressed win.
2. **Short, frequency-ranked names**, emitted directly rather than mangled afterwards. Identifiers
   are 66.8% of unminified bytes.
3. **Whitespace and punctuation**, one boolean on the printer, about 19% of delivered bytes.
4. **Type-directed field ambiguation** — fields that never co-occur on a type share one short name,
   cutting the count of distinct identifiers, which is what the compressor charges for. This needs
   exactly what the checker already built and Elm cannot do it.
5. **Variable joining and conditional lowering**, both printer decisions rather than passes.
6. **Reachability elimination** (§9.1) — a traversal of a graph that already exists.

**Explicitly not built**, because they measured zero or negative after compression: boolean
shortening (`true` → `!0` makes brotli output *larger*), `if_return`, `collapse_vars`, inlining,
constant evaluation, sequence joining, comparison and switch rewriting.

**Emission order matters and is free.** Declarations are emitted in module-grouped reachability
order and names are stable across builds; a size-sorted order costs up to 7% of compressed bytes at
identical raw size.

### Reachability elimination

**Ranked sixth by compressed bytes and built first.** The ranking is right and the order is not a
contradiction: the list measures what each pass is worth *on code that is going to ship*, and this
pass decides what that is. Static dispatch made it a prerequisite rather than a win
(`fast-compiler.md` §13), and the measurement says how far: an empty program emits **188** top-level
declarations of which **2** are reachable from `main`, 47 821 bytes of declarations of which **93**
are reachable, and **22** derived functions of which **none** is. Predicted output after the pass is
about **2.1 kB in 5 files against 70 684 bytes in 19** — and `derived_bytes` exactly 0.
`tests/corpus/run/Dictionaries.beni` keeps 28 of 188 declarations and 14 472 of 48 486 bytes.
Raw figures, method and the approximation's limits are in [`plans/dce-notes.md`](../../plans/dce-notes.md).

#### The unit, and the graph

**The unit is a top-level declaration**, as `boundary.md` §7.1 requires and for the reason it gives:
Elm solved this and then lost it by keying a whole kernel file to one node. There are exactly three
kinds of node, all of them things that occupy bytes in an emitted `.mjs`:

| Node | Identity | Emitted by |
|---|---|---|
| a value declaration | `(Graph.Index, Bir.DeclIndex)` for a `Decl` of kind `.value` with a body | `Lower.declaration` (`src/js/Lower.zig:564`) |
| a foreign binding | `(Graph.Index, Bir.DeclIndex)` for a `Decl` of kind `.foreign_value` | the sibling `import` (`:688-695`) |
| a derived function | `(Graph.Index, Dispatch.Derived index)` | `synthesisedValues` (`:1886`) |

And four things that are **not** nodes, each because it has no separate existence in the output. A
`type`, a `type alias` and a `foreign type` emit nothing (`:571-575`). **A constructor is not a
node**: it is an object literal at its use site, so there is nothing to keep or drop and a
constructor mentioned only in a pattern needs no edge to survive. A **`$$order` table** is not a
node: `orderTable` is reached only for a row whose arrow was built (`:1911`), so it lives and dies
with its `compare`. The three **primitive comparators as values** — `eq$prim`, `compare$prim`,
`compare$char` — are not nodes either: `Lowerer.needs` discovers them during lowering, which now
runs over survivors only, so they are emitted iff a surviving body wanted one.

**The edges.** Out of a value declaration `d` of module `m`:

1. every `Bir.refs` row of `d` whose kind is `top_value` → `(m, ref.a)`. This is the §9.1 byproduct,
   already deduplicated per declaration and in source order, already walked by `emissionOrder`
   (`:524`).
2. every `ext_value` instruction in `bir.insts[d.inst_start .. d.inst_end]` → the declaration behind
   that interface value: `Resolve` has already rewritten the instruction to carry
   `(Graph.Index, Interface.ValueIndex)` (`src/resolve/Resolve.zig:303-309`), and
   `Interface.Provenance.valueDecl` (`src/resolve/Interface.zig:309-313`) turns the second half into
   a `Bir.DeclIndex`. A declaration's instructions are contiguous (`Bir.Decl.inst_start`/`inst_end`,
   the same fact `declSiteRange` rests on at `:1612-1617`), so this is a slice walk.
   *Alternative rejected: reading `refs`' `import_value` rows, which are symbolic `(module symbol,
   name symbol)` pairs that `Resolve` never rewrites — re-deriving that lookup in the backend is a
   second copy of resolution, and a copy that drifts drops an edge, and a dropped edge is a
   `ReferenceError`.*
3. every **dispatch site** of `d` — `declSiteRange(d)` (`:1614`) — and, recursively through
   `Dispatch.partsAt`, every target nested in one. **These are the edges `Bir` deliberately does not
   have** (`frontend.md` §3.6, `static-dispatch-spike.md` §1.4): a method call's callee is not known
   until the checker runs, and evidence arguments are references that no source line spells. Target
   by target: `top {decl}` → `(m, decl)`; `ext {module, value}` → that module's declaration, through
   the same provenance as leg 2; `derived {index}` → `(m, index)`; `ext_derived {module, type,
   kind}` → that module's `Derived` row for the pair; `evidence k`, `primitive`, `field` and `err`
   add no edge, because each is a parameter, an operator, a property read or a poisoned table.

Out of a **derived function** row `r` of `m`: every target in `partsAt(r.parts)`, recursively, by the
same mapping — that is how a derived `eq` for `type T = T (Maybe U)` reaches `Maybe`'s row and `U`'s.
Out of a **foreign binding**: nothing; its body is in a sibling file this pass does not read.

This is `collectTops` (`:555-562`) widened from `top` to all four target kinds and given a
cross-module leg, so the eta-expanded evidence closures of §6 need no rule of their own: an
eta-expansion is built from a site's targets, and the targets are the edges.

**Where it runs.** A new whole-program pass in `src/js/`, called from `Emit.run` between `findEntry`
and `emitModules` (`src/js/Emit.zig:147`, `:155`), producing one bitset per module over each of the
three node kinds. `Lower.Input` gains that per-module triple; nothing else about lowering
changes. It runs **before lowering, not after**, for three reasons: an unreachable declaration is
then never lowered at all, which makes the pass pay for itself in emit time rather than cost
anything; the graph is a function of `Bir` and the dispatch table, both of which M4 can cache per
module, where `JsIr` is the emit unit itself; and §10's colouring wants the same graph, before
anything has been assigned to a file.

**Determinism and parallelism.** Per-module edge lists are built **in parallel**, one job per
module, each writing only its own slot — the same shape as every other per-file phase. The
**reachability walk is serial**, because a fixpoint over a whole-program graph is, and it is
nothing: 278 nodes for the null program, O(declarations) at any size, microseconds against §13's
800 ms budget. Node identity is input-derived end to end — `Graph.Index` comes from the sorted path
(CLAUDE.md rule 5), a declaration index is source order, a `Derived` index is the sorted-by-name
order §7.1 of the spike fixes before anything indexes it — and the pass's output is a *set*, so
visit order cannot reach the bytes. `--jobs=1` against `--jobs=8` covers it with no new machinery.

#### Roots

- **`main` of the entry module**, found as it is today (`Emit.findEntry`, `src/js/Emit.zig:541`).
  In an application build it is the **only** root.
- **Whatever the platform calls back into.** Today that is `main` and nothing else: the artifact is
  `main.mjs` handing `main` to the runtime's `run` export (`:763-781`), and the runtime sibling is
  copied whole, so it needs no root of its own. When ports land (`boundary.md` B3) every port is a
  root and this line grows; nothing else in `boundary.md` §5 imposes a signature the compiler must
  keep alive.
- **`--library`: every name the root package's modules export.** A library has no `main` and its
  callers are not in the build, so its public surface is its root set — which is exactly the export
  list §5 already computes: `pub` values with a body, every nominal `derived` row, and nothing else.
  `--library` also makes `main` optional and writes no `main.mjs`.

**`pub` means nothing to DCE in an application build, and that is a decision.** A `pub` declaration
that nothing in this program reaches is deleted, in `Main.beni` as much as in `core/List.beni`.
`pub` is a *module* boundary, not a *program* boundary; a whole-program compiler knows the program,
and treating `pub` as a root would pin all of core forever, since every core value is `pub`.
*Alternative rejected: rooting at the entry module's own exports, which would spare the `emit/`
corpus without a flag and cost a user every derived method of every type they happen to declare in
the module they named on the command line — the nominal rows are exported regardless of the type's
`pub` (`src/js/Lower.zig:639-660`), so that rule can never drop one.*

**What a library build cannot do, stated so nobody reports it as a bug.** Measured on
`bench/corpus`: under library roots **48 of 59** derived functions survive and **10 614 of 11 790**
derived bytes, because a `pub` type's `eq` and `compare` are exported and a consumer may call them.
Elimination shrinks a *program*; it barely shrinks a *library*. That is the correct answer and not a
limitation to fix.

#### Purity, and what may be dropped

**An unreachable declaration is dropped entirely, initialiser included, with no exceptions.** The
rule is total because the premise is: a top-level beni value is pure to evaluate.

`language.md` §6, *Evaluation order* is where purity and the licence it buys are now stated for the
language as a whole — what may be dropped, what may not be reordered, and what an inliner may
substitute. This section is that licence spent on top-level declarations.

Establishing that, rather than assuming it. A top-level constant *can* have a call in its
initialiser and one does — `platform/Node.mjs` emits `const Node$done = Node$printLines({$:0,…})`,
a call of a `foreign`. What makes it safe is `boundary.md` §4's two-shape rule and §7.2's reading of
it: a `foreign` is a total pure function over admitted types or an effect *value*, effects are data
until the platform interprets them, and `printLines` returns `{code, out}` having written nothing.
`Debug.log` is the one deliberate violation in the language and it is a **function**, so its effect
happens when it is called and a call is an edge; a `Debug.log` reachable from `main` keeps
everything it names. A platform `Program` is a value like any other. So there is no top-level
initialiser whose evaluation anyone can observe, and dropping one is unobservable by construction —
which is the proof `fast-compiler.md` §9.1 claims over a bundler's `sideEffects: false` guesswork,
written down.

**Sibling modules are the one place ES module semantics could bite, and the rule is: a sibling is
imported iff one of its exports survives.** An unreferenced `import` still *evaluates* the module,
so dropping the import is a semantic change wherever the sibling has top-level effects — and none
does. Checked over all seven siblings in the repository: every top-level statement is an `import`,
an `export`, a `const`/`function` declaration or a comment, and the only module import is
`platforms/node/runtime.js` taking `node:process`. `boundary.md` §4.1's recipe already forbids the
shape that would break this (address by value, marshal to data, no reference held across a
boundary), and §4's check 3 — a sibling's references must be covered by its own imports — is what
keeps a sibling from reaching a host global at load time. If a future platform wants load-time
setup it must put it inside an exported function, and that is a rule of §4.1 and not a new one.

**Sibling-level elimination is out of scope, and here is what it costs.** A sibling is hand-written
JavaScript copied whole, so a file survives entire as soon as one of its exports is reachable.
Measured on `Dictionaries`: two of six sibling files are dropped (2 922 B), and the four that stay
carry **12 925 bytes for six reachable exports out of sixty-one** — roughly as much again as
everything the pass saves on that program. Doing better needs to know which top-level helper in the
sibling is used by which export, and reading that exactly needs a JavaScript parser, which is the
dependency `boundary.md` §4's wall exists to avoid and which check 3 is already deliberately
approximate rather than acquire. Left on the table, deliberately, with the number. *Alternative
rejected: Elm's template dialect, which buys exactly this and is the reason its kernel files are
module-granular in the first place (`boundary.md` §7.1).*

#### When it runs, and what pins the corpus

**Always on, for every `beni build`.** Not release-only: `--release` is about chunking, renaming and
tags (§2), and answering "eager derivation is not shippable without DCE" for release builds alone
would leave every development build shipping fifty times its own size and every `run/` fixture
exercising a code path release does not. One pass, one behaviour, one set of goldens.

`dump --stage=…` is untouched. Every stage is `tokens`, `ast`, `bir`, `types`, `interface` or
`dispatch` — all of them before the backend — so nothing a dump prints moves, and `bir`'s `refs`
list in particular keeps printing the symbolic `import_value` rows it prints today, because this
pass reads instructions for that leg rather than rewriting `refs` (above).

**The `emit/` corpus builds with `--library`, and that is the whole pin.** Measured over all
fourteen fixtures: with `main` as the only root, **14 of 14 goldens change** and twelve also lose an
import; with the library rule, **0 of 14 change**. The difference is not cosmetic —
`emit/DerivedCompareNominal.js` is 115 lines of which 114 are derived code and one is `main`, and
its intent comment says in so many words that nothing below uses these and they are emitted anyway.
That claim is about eager derivation in the declaring module, it is still true, and a `main`-only
build would delete the evidence for it. So: `tests/corpus/emit/README.md` gains the rule that **an
`emit/` golden is a claim about the shape of a declaration and must not be contingent on something
calling it**, and the harness appends `--library` for the kind (`corpus_test.zig:472`), exactly as
it already appends `--core` for a fixture under `core/` (`:340-345`). Elimination's own `emit/`
goldens, which need an application build, go in a subdirectory the harness does not add the flag
for — `tests/corpus/emit/app/` — by the same per-fixture mechanism.

`run/` fixtures are unaffected in how they are built and **no `.expected` may change**: they assert
what the program printed, and elimination does not change that. A `run/` fixture that moves is
over-elimination, which is the failure this pass has to fear.

#### Incrementality (M4) and chunking (M3d)

`fast-compiler.md` §8.2's declaration-level graph and this one are **the same graph**, which is what
§9.1 means by "build once, use three times". Concretely, for M4:

- A module's **edge lists are cacheable per module**, keyed by the cache key §8.1 already defines —
  source bytes, module identity, compiler version, direct imports' interface hashes, and
  `boundary.md` §7.3's sibling content hash. Legs 1 and 2 are a function of that module's `Bir`
  after resolution; leg 3 is a function of its dispatch table, which is a function of its own check.
  Nothing in an edge list names a thread or a completion order.
- What **reruns on every build is the walk**, because reachability is whole-program by definition
  and an edit to one module can make another's declaration dead. It is the cheap half: 278 nodes for
  the null program, O(declarations) at scale, against a re-check that the firewall may skip
  entirely. §8.2's `emit` unit is invalidated by "a change to `decl_val`, or to any representation
  decision it depends on"; **a change to liveness is one more such input**, and a declaration whose
  liveness flipped is an `emit` unit to redo whether or not its own bytes would differ.

Chunking (§10) runs on this graph and not on one of its own: an entry set is a set of roots, a
colour is the set of entries that reach a declaration, and "reaches" is this walk with more than one
seed. Pointer only; §10 is where that lives.

#### Measurement and acceptance

`bench/size.mjs` is the instrument and it needs one change, because DCE breaks one of its
assumptions. The `run/` corpus and the floor are built as they are today and their numbers simply
start meaning what they say. The **synthesised `BenchMain`** does not: `bench/corpus` declares no
`main` and the entry the script writes only imports the modules, so under `main`-only roots the
build keeps **1 declaration of 336** and the benchmark silently stops measuring anything. That path
therefore passes `--library` — `bench/corpus` *is* a library — and its line records which rule it
used. Two meanings also shift and the header comment must say so: the **floor** stops being a shared
tree every program drags in and becomes the minimum a program can ship, so `net_*` is a subtraction
against a minimum rather than against common code; and `gross_*` becomes the number that matters,
since after elimination no two programs ship the same tree.

Acceptance, all five:

1. **`derived_bytes` is 0** on the floor line and on any program that uses no `==` and no `compare`.
2. **Every `run/` fixture's `.expected` is unchanged** and every one still exits 0.
3. **Size is reported through `bench/size.mjs`**, floor and total, both directions recorded whichever
   way they come out — though on the floor there is only one direction available.
4. **Emit throughput within noise or better.** It should be better: emit is 18.7 ms of a 101 ms
   Debug build of `Dictionaries` today and 70 % of the declaration bytes it prints are unreachable.
   If it regresses, an edge list is being rebuilt where it should be built once.
5. **The determinism test is green** at `--jobs=1` and `--jobs=8`, twice each, byte-compared.

#### Fixtures

**Over-elimination is a `ReferenceError` at load or a wrong answer at a call; under-elimination is
only bytes.** Every `run/` row below is therefore a program that crashes or lies if the pass drops
too much, which is why they are `run/` and not goldens (§12).

| Fixture | Intent | Observable |
|---|---|---|
| `emit/app/DceUnusedValue` | a `pub` value and a private helper that nothing reaches, beside one that `main` does | golden: the unreachable pair is gone, the export list and the `import` line shrank with them |
| `emit/app/DceDerived` | two types, one compared with `==` and one not; the compared one's payload is a third type | golden: the unused `$$eq`/`$$compare`/`$$order` are gone and the used one is there **with the payload type's own derived function**, which is the transitive edge |
| `emit/app/DceEvidenceOnly` | a function referenced **only** as an evidence argument — never called by name anywhere | golden: it is still emitted. This is the edge `Bir.refs` does not have; without leg 3 the golden loses it and `run/DceEvidenceDepth` throws |
| `emit/app/DceCtorPattern` | a constructor of a type used only as a `case` pattern, with the type's derived methods unreachable | golden: the match compiles unchanged and the derived methods are gone — pins that a constructor is not a node |
| `emit/app/DceModuleGone` | a two-module fixture whose second module nothing reaches | golden: the entry module has no `import` of it; the harness also asserts `out/<Other>.mjs` was not written |
| `run/DceEvidenceDepth` | evidence passed down through three generic levels, the innermost comparator reached only as a `parts` target | the comparison's answer; a missing nested-`parts` edge is a `ReferenceError` at the innermost call |
| `run/DceOrderTable` | a multi-constructor type whose `compare` is reached only through a generic `List.sortWith`-shaped path | the sorted order in declaration order; dropping the `$$order` table gives `undefined[tag]` and a wrong order, not a crash — the worst failure mode here |
| `run/DceEtaEvidence` | evidence that itself takes evidence, so §6 eta-expands it, reached from nowhere else | the answer; the closure names a function that must have survived |
| `run/DceForeignThroughCore` | a `foreign` reachable only through a core function that is itself reachable only through one user call | the value; a sibling dropped one file too far is a load-time `ReferenceError` |
| `run/DceUnusedFailsNothing` | a module full of `pub` declarations that nothing reaches, beside a `main` that prints | it prints; proves the build does not need what it deleted |
| `run/DceDebugLog` | `Debug.log` in a reachable branch and in an unreachable declaration | exactly one line of log output — pins that the effect follows the edge and not the declaration |

Each is fail-first in the ordinary way: every `emit/app/` golden differs before and after, and every
`run/` row above either throws or prints the wrong thing if the matching edge is missing. The
existing fourteen `emit/` goldens are the regression half — **none of them may move** (`--library`,
measured 0 of 14), and one that does is a finding.

## 10. Chunking

Entry points are `main` and every `lazy` declaration. Each declaration's colour is the set of entry
points that reach it; declarations sharing a colour share a chunk. **"Reaches" is §9's walk with
more than one seed, over §9's graph** — the colouring adds a lattice, not a second graph. The colour is **hash-consed from
the first line written**, because dart2js measured 401 deferred imports producing 2.9 million
import-sets and a five-gigabyte heap without interning, and both GWT and Rollup found the same late.
dart2js's `ImportSetLattice` is the structure to copy. Declaration granularity is proven in four
whole-program compilers, and Closure's four safety guards for it are vacuous in a pure language.

A **merge pass** follows, budgeted by compression rather than request count: four chunks cost about
6.6% of compressed bytes and sixteen about 18%, before any chunk has saved anything. A chunk whose
private content does not repay that is folded back.

The assigner **synthesises the cross-chunk `import`/`export` bindings itself**, and is budgeted with
the assigner rather than after it. Closure is the only other system doing declaration-granular
chunking with an ES-module mode and the combination is broken there, because it relocates
declarations without emitting the bindings (closure-compiler#4264, open). esbuild's
`computeCrossChunkDependencies` is the model.

## 11. Source maps

Fused into the print pass — a mapping recorded at each emit site, never a second traversal —
delta-encoded, per-file chunks rebased once at join time. On by default in dev, off in release.
Positions live in `JsIr` from M3a even while maps are off.

## 12. Testing

The boundary that matters is the second one: **compile, run under Node, assert what it printed.**
This is what Elm's deleted suite never had and it is why `boundary.md` puts the Node platform before
the optimiser.

New corpus kinds:

```
tests/corpus/run/<Name>.beni + <Name>.expected     compile, run, stdout must match
tests/corpus/emit/<Name>.beni + <Name>.js          the extracted declaration, for shape claims
```

`run/` is the default for anything about behaviour. `emit/` is for claims running cannot observe —
that a self-recursive function became a loop, that a constructor emits a uniform shape, that a
saturated call emitted a direct call and not an adapter. Goldens are **extracted and normalised, not
whole-file**, which is the discipline Elm's suite lacked and resented.

The one deviation, recorded rather than hidden: an `emit/` golden is the fixture's **own module**
whole — one deliberately tiny module holding nothing but the claim — because one module of one
tiny fixture *is* that extract, with no extractor of its own to get wrong, while core and the
platform stay out of the file (`tests/corpus/emit/README.md`).

A second deviation arrives with §9: **`emit/` builds with `--library`**, so a golden is a claim about
the shape of a declaration and not about whether the fixture's own `main` happens to call it, and
`emit/app/` is the subdirectory that does not — for the goldens whose claim *is* what elimination
removes. Same mechanism as `core/`, which already appends `--core`.

A bug that changes emitted shape but not behaviour must not fail a `run/` test; a bug that changes
behaviour must. That is the whole point of preferring it.

§8 lists the fixtures the tail-call loop owes, one row each, with the observable that separates a
right loop from a wrong one. Two of them are worth naming here because they are the pattern the rest
of M3b should copy: the loop's fail-first fixture overflows the stack without the change, and its
closure-capture fixture exits 0 with the wrong answer, which is the failure mode a `run/` fixture
exists to catch and an `emit/` golden cannot.

## 13. Measurement

`bench` gains `emit` (throughput in MB/s of JavaScript) and `build` (the whole cold pipeline).
Sizes are tracked **after compression**: brotli primary, gzip secondary, raw as a diagnostic only.
Zig's standard library has no brotli, so the benchmark shells out to an encoder pinned in the flake.

| What | Target |
|---|---|
| Emit throughput | > 5 MB/s of JavaScript — **measured 85.5 MB/s** at M3a (`bench/README.md`) |
| Whole cold build, 100k lines | < 800 ms including core |
| Output size | Elm's TodoMVC at 9KB compressed is the number to beat |
| Own output vs esbuild `--minify` | within ~10%; revisit before M5 if it approaches 1.58× |

That last row is report 12's exit criterion, and it exists because Scala.js built the type-aware half
of this and measured 1.58× for going without a generic minifier. The difference is that Scala.js
never built the generic half at all; if our number approaches theirs, the plan was wrong.

## 14. What M3 does not do

Ports (`boundary.md` B3), the browser platform (B4), `Intl` (B5), the daemon and any caching (M4),
and mutual-recursion trampolining (§14 question 5, a stated limitation).
