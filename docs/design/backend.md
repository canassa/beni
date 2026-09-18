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
  discharged, not measured (§6).*
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
| `--release` | chunks, elimination, renaming, integer tags, maps off | off |
| `--out=<dir>` | output directory | `out/` |
| `--source-maps` | emit `.map` files | on in dev, off in release |

Development output is **one ESM file per source module**, mirroring the source tree, with no
elimination and readable names. Release output is **reachability chunks**. Both read one declaration
graph (§9.1 of the design doc); nothing is built twice. §5.3 of `boundary.md` makes a build a pair of
entry point and platform, so a project with a client and a server runs `build` twice.

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

## 4. Codegen, construct by construct

Representation decisions are §9.4's and are not reopened here. What this section fixes is the
mapping.

| beni | JavaScript |
|---|---|
| top-level value | one `const` per declaration, module-qualified name in dev, short name in release |
| function of *n* parameters | one function expression of arity *n*; no arity tag (§6) |
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
loop. The checker has already proved exhaustiveness (`checker.md` §6.6), so **the tree needs no
default arm for a well-typed match** and the absence of one is not a latent crash.

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
shared-branch loop between the jump and this one. The label is the function's own emitted name —
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

## 10. Chunking

Entry points are `main` and every `lazy` declaration. Each declaration's colour is the set of entry
points that reach it; declarations sharing a colour share a chunk. The colour is **hash-consed from
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
