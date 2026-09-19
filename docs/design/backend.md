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
  foreign values are implemented, not only the ones the subset reaches. `?` was the one construct
  of §4's table M3a did not compile, and it said so with a diagnostic rather than emitting
  something wrong.
- **M3b — the whole language.** Tail-call loops, decision trees, interpolation, `?`, tuples, record
  update, `Int32`, everything remaining. *Acceptance: the corpus compiles and runs.* **Four of the
  seven were stale when the list was written** and one is not a backend item at all: interpolation,
  tuples and record update worked in M3a (`plans/m3b-audit.md` measured every row of §4 against the
  code), tail-call loops landed in `bbfc869` (§8), decision trees in `cf7806f` (§7), and `?` with
  this slice (§4). What is left is **`Int32`**, which is a *language* gap and not a codegen one —
  no type, no `core` module, no paragraph in `language.md` — and needs an owner decision rather
  than an emitter.
- **M3c — the optimiser.** Reachability elimination, reachability-driven inlining, local
  dead-binding elimination, renaming, field ambiguation, compact printing. *Acceptance: §9's size
  and throughput numbers, and §9's size and throughput numbers alone; the direct-call share that used to decide §9.3 is
  discharged, not measured (§6).* **Reachability elimination is built first and is not optional**:
  static dispatch derives eagerly, so an empty program ships 3 159 bytes of `eq`/`compare` that
  nothing calls, and `fast-compiler.md` §13 moved this pass from an optimisation to a prerequisite
  on that evidence. Its own acceptance is separate and exact: the floor's `derived_bytes` is **0**
  for a program that compares nothing (§9).

  **M3c ships in two slices, and the first one is what `--release` means.** The first is §9 items
  **1, 2, 3 and 5** — local dead-binding elimination, short names, compact printing and variable
  joining — together with the flag itself; it is one pass over `JsIr`, one name table and one
  printer boolean, and it stands alone because none of the four needs anything the backend does not
  already have. The second is item **4**, type-directed field ambiguation, which needs an artifact
  §3 says the backend does not receive, plus anything chunk-facing (§10). Sliced that way because
  the first is worth a measured **31% of `bench/corpus`'s compressed bytes** and the second is
  worth report 12's 4% (§9), and because a `--release` that is refused is worse than a `--release`
  that is not yet perfect. The one entry in this bullet's own list that is in neither slice is
  **"reachability-driven inlining"**, which was never a §9 item and has no measurement behind it;
  what §9 now specifies under item 1 is single-use inlining of the temporaries §4, §7 and §8
  generate, which is a different and measured thing.
- **M3d — chunking and `lazy`.** The keyword, entry-set colouring, the merge pass, cross-chunk
  bindings. *Acceptance: a two-route program splits and both routes run.*

  **The two halves have a dependency between them and it is not small.** §10 specifies the chunker;
  the keyword is PENDING an owner decision, because a deferred load is asynchronous, the language is
  synchronous, and `fast-compiler.md` §9.5's type rewrite names a `Task` that
  `transparent-effects-proposal.md` removes. [`plans/m3d-plan.md`](../../plans/m3d-plan.md) §2 is the
  argument, §6 the decisions — including what "route" means on a platform whose only entry point is
  `main`, and whether the chunker ships against multiple entry points before `lazy` exists.

`boundary.md`'s B1 and B2 fold into M3a; B3 through B5 follow M3d.

## 2. CLI surface

```
beni build [options] <entry>...      compile to JavaScript
```

| Flag | Meaning | Default |
|---|---|---|
| `--platform=<name>` | which platform package supplies `main`'s type and the runtime | required |
| `--release` | dead bindings out, short names, compact printing, joined `const`s (§9); later chunks (§10), integer tags, maps off | off |
| `--library` | no `main` is required and no entry file is written; every name the root package's modules export is a reachability root (§9) | off |
| `--out=<dir>` | output directory | `out/` |
| `--source-maps` | emit `.map` files | M5; refused today, on in dev and off in release once §11 lands |

**`--source-maps` is refused, not ignored.** It is not implemented — the encoder is M5 (§11) — and a
flag that is accepted while doing nothing makes a user believe they asked for something: a silent,
successful `--source-maps` build sends them looking for a `.map` that was never written, exactly as a
silent `--release` build would have shipped development output. It exits `2` with `frontend.md` §1's
one-line usage message naming the milestone. The defaults in the table above are what M5 will do;
until then the only way to build is without that flag. `--release` was refused on the same argument
and no longer is, because M3c's first slice implements it.

**`--release` stopped being refused with M3c's first slice, and `--source-maps` did not.** The
refusal was one branch (`src/Cli.zig:362-364`); it went, the `release: bool` already parsed at
`:338-341` reaches `Emit.Options`, and the usage line at `:46` states what the flag does rather than
what it does not. Nothing else about the command changed: `--release` takes no value, composes with
`--library` and `--out` and `--jobs` exactly as `--library` does, and **implies nothing** — in
particular it does not switch elimination on, because elimination is always on (§9), and it does not
switch source maps off, because there are none to switch. `--source-maps` keeps its own refusal at
`:369-371` and keeps it in a `--release` build too, so the pair `--release --source-maps` exits 2 on
the source-map line. The one thing it changes beyond §9's four passes: the entry file's two-line
header comment goes, which is 135 bytes of the floor's 2 009. `dump --stage=…` is untouched for the same reason §9 gives: every stage is
before the backend. **Development output does not move by one byte** — every `emit/` golden, every
`run/` `.expected` and every `bench/size.mjs` figure in this document is a dev-build figure and stays
one — which is what makes "a golden moved" a finding rather than a blessing for the whole slice.

**`--library` is not in that company**: it lands with §9 and does something the day it lands. It
turns off exactly two things — the REQUIREMENT for a `main` (`missing_main` does not fire, a second
`main` is not a `duplicate_main`, and a `main` that is there is not checked against the platform's
`Program`)
and the entry file — and turns on one, the root rule. A `main` that happens to exist is still
exported and still a root, because §5's export list has the entry declaration in it and §9 roots a
library at its export list; §9's "Roots" says why at length. It is not a second output mode; a
library build emits the same `.mjs` per module as any other.

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
| record | object literal, keys in a canonical sorted order so one hidden class per record type — the sort moves the **keys** and never an initialiser (below) |
| constructor | `{$: tag, a, b}` padded to a uniform shape per type; tag is a string in dev, an integer in release |
| nullary constructor | the bare tag |
| tuple | fixed-shape object per arity, no runtime tag |
| list | cons cells (`{$:1, a, b}` / the empty singleton), pending M3c's benchmark of a vector trie |
| string | native JavaScript string; core's API exposes codepoints where the UTF-16 mismatch would show |
| `Int` | a number; `Int32` a number kept in range by its operations (§3.1) |
| `case` | a decision tree (§7) |
| `if` | conditional expression when both arms are expressions, else `if`/`else` |
| `let` | a VALUE binding is a `const` in the enclosing statement list, in written order; a binding whose right-hand side is a **function** is a `function` declaration, which JavaScript **hoists** — every one of them, not only the mutually recursive ones. The hoisting is what makes mutual recursion between `let` functions work, and `language.md` §7's initialisation rule is stated in terms of it: a value may not read a `const` below it, and may read a `function` anywhere |
| string interpolation | template literal |
| `?` | a test and an early `return` of the failure, in statements, over the subject bound once (below) |
| `foreign` | an `import` from the sibling file, one binding per foreign value (`boundary.md` §4). Its **arity is its annotation's**, carried on the declaration's `params` by lowering (`frontend.md` §3.6): the backend reads targets and never types (§3), so a `foreign` in value position eta-expands over that number like any other target |
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

### A record literal's keys move; its initialisers do not

The sorted key order above is a **representation** decision and `language.md` §6's *Evaluation
order* is a **semantic** one, and where they meet the semantics wins: `{ zed = p, alpha = q }`
emits `{alpha: …, zed: …}` and runs `p` before `q`. So the emitter sorts a permutation of the
fields, lowers the initialisers in the order they are **written**, and binds one to a `const $t$<n>`
before the object literal whenever leaving it in place would move its evaluation. M3a sorted the
fields and then lowered each one, which ran them in key order; the fixtures are
`run/EvalOrderRecordFields.beni` and `emit/RecordFieldOrder.js`.

**A temporary is bought only where one is needed**, because an unnecessary one is bytes in every
record literal in the program. Two things can move an evaluation, and an **atom** — a literal, a
name, or the `$t$<n>` a `case` has already assigned — is moved by neither, since re-reading one
repeats no work and shows nothing:

| The literal | What is pinned |
|---|---|
| already in key order, no initialiser hoisting statements | nothing: the initialisers stay inside the object literal, byte for byte as before |
| the sort moves the fields, and **at most one** initialiser is not an atom | nothing: one evaluation cannot be reordered against values that are only read |
| the sort moves the fields, and two or more initialisers are not atoms | every non-atom, to a `const` in written order; the object reads the names |
| some initialiser lowers to **statements** (a `case`, an `?`) | every non-atom written before the last such initialiser — its statements run before the object literal is built, so what is written in front of it has to have run already |

The rule is deliberately conservative: it pins by the *shape* of the lowered value and never asks
whether a particular expression could be observed. The same rule holds wherever an emitted order
can differ from a written one, which is why §7's tree rebuilds occurrences rather than re-evaluating
subjects, and why record **update** needed nothing: a spread moves no initialiser.

### `?` is a test and a `return`, and the statements around it

`language.md` §6.6's `e?` yields the payload of an `Ok`/`Just` and returns the `Err`/`Nothing` from
the enclosing function. It is three pieces of JavaScript, and no `case`:

```js
const $t$1 = String$toInt(text);            // the subject, evaluated exactly once
if ($t$1.$ === "Nothing") return $t$1;      // the failure test, and the early return
…$t$1.a…                                    // the value of the expression
```

| Piece | What it is |
|---|---|
| the subject | evaluated **once** (`language.md` §6) and bound to a `$t$<n>`, because the test and the payload both read it. A subject that is already an atom — a name, a literal — is read twice instead and nothing is bound |
| the test | `<subject>.$ === "<failure tag>"` for §4's padded representation, `<subject> === "<failure tag>"` for a bare tag. The failing constructor is `Nothing` for the `Maybe` shape and `Err` for the `Result` one, and its representation is looked up like any other constructor's, from the declaring module's interface |
| **which shape** | the CHECKER's, carried in the dispatch table (`checker.md` §6.5, `static-dispatch-spike.md` §7.1). The emitter sees no types (§3) and a `?` carries no pattern, so this is the one thing about it the backend cannot work out; a `?` with no row is `internal` and stops the build |
| the failure | **the subject itself, returned unchanged.** Nothing is rebuilt and nothing new is named |
| the value | the payload slot, which is slot 0 — `a` — for `Just` and for `Ok` alike |

**Returning the subject is sound because neither failure carries the type that changed.** `?` takes
a `Result e a` inside a function answering `Result e b`: an `Err` holds an `e` and never an `a`, so
the object that came in is already the object that goes out, and re-wrapping it would allocate a
second one with the same two fields. `Maybe a` to `Maybe b` is the same argument with an empty
hand: §4's padding makes `Nothing` a `{$:"Nothing",a:null}` whatever `a` was. This is also what
keeps §9 honest — the failure path names no declaration, imports nothing and adds no edge, so a
`?` cannot keep anything alive.

**The `return` is the enclosing function's, wherever the statement lands.** `language.md` §6.6 says
a `?` returns from the nearest enclosing *definition with parameters* and makes a lambda in between
`question_in_lambda`, so there is no case where the beni answer and the JavaScript answer could
differ: a `let` definition with parameters is its own emitted `function` (§8's cases table), a
parameterless `let` binding is a `const` in the enclosing one, and a lambda cannot be reached. A
`return` inside §7's labelled block or `switch` leaves the function and not the block — that is
what distinguishes it from a leaf's `break $c$<d>`, which is how a leaf delivers the `case`'s own
value — and inside §8's `while (true)` it leaves the loop with the function.

**Everything written before a `?` must have run before it.** The early `return` is a statement, so
it runs where the statements go, ahead of the expression it was written inside; an expression
written to its left that is still sitting in that expression would run *after* it, or — if the `?`
fails — not at all. This is the record literal's rule above, generalised: **a run of
sub-expressions in written order pins to a `const` every non-atomic value written before the last
one that hoists statements.** It applies to every position that holds more than one written
expression — a call's arguments *together with its callee*, a method call's receiver and
arguments, a constructor's arguments, a list, a tuple, an interpolation's segments, a record
literal's initialisers, a record update's base and fields — and it is the same machinery, so a
`case` in the same position was fixed by the same change. Short-circuit `&&`/`||` need nothing
extra: correction 3 above already gives the right operand its own branch, and statements hoisted
there run only when it does.

Two consequences worth stating, because they are what the emitted shape looks like:

- **In a `case` (§7)**, a `?` in a branch body hoists into *that branch* and nowhere else, so the
  other branch does not run its test; a `?` in the scrutinee hoists before the tree, once. A leaf
  that hoists statements is why the conditional-expression shape is chosen only after the bodies
  are lowered: `a ? b : c` cannot hold a `return`, and the tree falls back to the statement form.
- **In a looping function (§8)**, a `?` in a **tail-call argument** is not in tail position — the
  operand of a `?` never is — so it is evaluated with the other arguments, before any parameter is
  rebound, and its failure returns out of the loop rather than continuing it.

## 5. Module output and linking

Dev: one `.mjs` per module, ESM `import`/`export` between them, names as `Module$name` so a stack
trace is readable; each module's sibling JavaScript beside it as `<Module>.foreign.mjs`, and the
platform's runtime as `platform/<name>.foreign.mjs` (§2). Release: chunks (§10), every surviving declaration emitted into its chunk with a
short name, and the cross-chunk bindings synthesised by the assigner — and with one entry point and
no `lazy`, that is one file.

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
reachable at the DEFAULT budget and with no flag: a `case` over about 440 `Int` literals cost more
than the 200 000 steps that were the default then (queue slice 22 made a flat table linear and the
default 5 000 000, so that shape costs ~880 now), and one written without its wildcard compiled and
printed the last branch's answer for every unmatched input. Queue slice 14 closed it at the checker,
where it belonged: an
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

`if` needs nothing of its own: it is a `case` by the time the backend sees it (`language.md` §8), a
two-alternative boolean fan-out, which the ≥3 threshold keeps as the `if`/`else` it is today.

**`?` turned out not to be a `case` at all.** This section predicted it would be "a two-branch
`case` whose first arm returns from the enclosing function", and what it needed from §7 was the
tail-position statement form. What landed is smaller: `Bir` keeps `?` as its own instruction, so
the emitter writes one `if` and one `return` with no tree, no scrutinee binding it does not need
and no branch bodies (§4). Two things this section owns still hold for it, and they are worth
naming here because a leaf is where a reader will look for them: a `?` in a **branch body** hoists
its test and its `return` into that branch, so the other branch never runs them; and a leaf that
hoists any statement at all is why the `cond` chain of the last row is chosen only after the
bodies are lowered — `a ? b : c` cannot hold a `return`.

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
position — which covers `if`, a `case` by the time the backend sees it (`language.md` §8); and the
`in` body of a `let` in tail position. Nothing else is: not an operand, not an argument, not a
`let`'s bound value, not a lambda body, not the left of a `|>` (a pipe is a call before the backend
sees it, §6), not the operand of `?`, and not a `?` itself — it is its own instruction in `Bir`
(§4), its subject has to be tested before anything can be done with it, and what follows the test
is an ordinary expression that may or may not be a tail call of its own. Parentheses do not exist
in `Bir`, so looking through them is free.

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
not in tail position: `List.sortWith`, `Dict.insertHelp`, `removeHelp`, `removeMin`, `mapTree`,
`foldlTree`, `foldrTree`. And `Basics.and`/`or` are `foreign` for short-circuiting (§4), `String`'s
twenty-two for the native representation, not for this.

*Amended 2026-09-19.* `List.map2`–`map5` were on that second list and are no longer. The others on
it recurse to the depth of a balanced red-black tree or of a merge-sort split, both O(log n), and
measurement found none of them overflowing at 4 000 000 elements; `map2`–`map5` recursed to the
depth of the LIST and overflowed at about 5 700, 4 900, 4 200 and 3 700 elements respectively,
taking `indexedMap` (which is a `map2`) with them. They are now the accumulator loop `map` itself
became — a tail-recursive `mapNHelp` consing onto an accumulator, then one `reverse` — which keeps
the callback order Appendix B of [`checker.md`](checker.md) states, keeps the walk stopping at the
shortest list without calling the callback for the unmatched tail, and adds no traversal `map` does
not already pay. `tests/corpus/run/ListMapNDeep.beni` is the fixture, at a million elements each.

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
   (`:524`). **`refs` is not enough on its own, and leg 2's instruction walk reads `.top` as well.**
   `refs` records a reference by the NAME the source wrote, and an operator writes none: `0 - n`
   lowers to `call(import_value Basics.sub, …)` with an `import_value` row, and inside `core/Basics`
   itself `Resolve` rewrites that instruction to a plain `top` while the row stays symbolic — the
   same asymmetry leg 2 is about, one module further in. Reading `refs` alone leaves `Basics.negate`
   naming a `Basics.sub` this pass deleted; six `run/` fixtures fail without it. *(Found in
   implementation; the `refs` walk stays, being the cheaper half, and a duplicate edge costs one
   bitset test.)*
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
   kind}` → that module's `Derived` row for the pair; `evidence k` and `field`
   add no edge, because each is a parameter or a property read.

   **`primitive` and `err` DO add one, and that is a correction to this list.** Both were written
   here as edgeless, "an operator" and "a poisoned table". That holds for `strict_eq`,
   `num_compare` and `char_compare`, which the module synthesises for itself — but `primitive
   string_compare` lowers to a CALL of core's hand-written `String.compare` (`Lower.stringCompare`
   → `Lower.coreValue`; §3.2 and A.26 route it there on purpose, because `<` on JavaScript strings
   is UTF-16 code-unit order and `String.compare` is Unicode scalar order and the two must agree),
   and `err` lowers to a call of `Basics.eq` (`Lower.partEq`'s `err` arm, the position A.66 names).
   Each is a reference to another module's declaration that no `refs` row and no `top`/`ext` target
   records. So: `primitive string_compare` → core `String`'s `compare`; `err` → core `Basics`' `eq`.
   Twelve `run/` fixtures fail without the first — every program that puts a `String` in a `Dict` —
   with a `ReferenceError` at load, after a build that exited 0. *(Found in implementation.)*

Out of a **derived function** row `r` of `m`: every target in `partsAt(r.parts)`, recursively, by the
same mapping — that is how a derived `eq` for `type T = T (Maybe U)` reaches `Maybe`'s row and `U`'s.
Out of a **foreign binding**: nothing; its body is in a sibling file this pass does not read.

This is `collectTops` (`:555-562`) widened from `top` to all four target kinds and given a
cross-module leg, so the eta-expanded evidence closures of §6 need no rule of their own: an
eta-expansion is built from a site's targets, and the targets are the edges.

**Where it runs.** A new whole-program pass in `src/js/`, called from `Emit.run` between `findEntry`
and `emitModules` (`src/js/Emit.zig:147`, `:155`), producing one bitset per module over each of the
three node kinds — **two bitsets, not three**: a value declaration and a foreign binding are both
`(Graph.Index, Bir.DeclIndex)` and cannot collide, so the count above is of KINDS and not of sets.
`Lower.Input` gains that per-module pair; nothing else about lowering
changes. It runs **before lowering, not after**, for three reasons: an unreachable declaration is
then never lowered at all, which makes the pass pay for itself in emit time rather than cost
anything; the graph is a function of `Bir` and the dispatch table, both of which M4 can cache per
module, where `JsIr` is the emit unit itself; and §10's colouring wants the same graph, before
anything has been assigned to a file.

**Determinism and parallelism.** Per-module edge lists are built **in parallel**, one job per
module, each writing only its own slot — the same shape as every other per-file phase. *(As landed
they are built the way that asks for — each list is a pure function of that module's `Bir` and
dispatch table and is written only into its own slot — but the jobs are not dispatched to workers:
`Emit` is serial end to end today, lowering included, and this pass is microseconds. The fan-out is
a drop-in when emit itself parallelises.)* The
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
  list §5 already computes: `pub` values with a body, every nominal `derived` row, **and the entry
  declaration when a module happens to have one**. `--library` also makes `main` optional and writes
  no `main.mjs`.

  **That last clause is a correction, and §2's "a `main` that happens to exist is not special" is
  wrong as written.** §5's export list has three sources and the entry declaration is the third; a
  library build roots at the export list, so it roots at all three. What `--library` turns off is
  the REQUIREMENT for a `main` — `missing_main` does not fire, a second one is not a
  `duplicate_main`, and the
  type is not checked against the platform's `Program` — and the entry file. It does not turn off
  finding one. The evidence is this section's own acceptance: `main` is not `pub` in a single
  fixture of the corpus, so a rule that excluded it would take `main` and its `import Node` out of
  every `emit/` golden, against the measured and thrice-stated "0 of 14 change". *(Found in
  implementation.)*

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

*As landed: the `emit/` corpus had grown to seventeen by the time the pass was written (decision
trees added `MatchNested`, `MatchSharedLeaf` and `MatchSwitch`) and **0 of 17 moved**. Two rows
above read differently from their intent, honestly rather than by construction. `DceEvidenceDepth`'s
three generic levels are numbered into ONE flat site list by §7.2, so what it isolates is leg 3
entire and not the nested-`parts` recursion; `DceEtaEvidence` is the row that isolates the
recursion, every `==` in it being written on a `Maybe` or a record so that the module's own `eq`
sits one level down inside another target's `parts`. And `DceOrderTable` reaches its `compare`
through its own `where`-constrained helpers rather than through `List.sortWith`, which takes a
comparator as an ordinary argument and would have made the edge an ordinary one.*

### The release optimiser — items 1, 2, 3 and 5

**One slice, four passes, one flag** (§1). Everything here runs **only under `--release`**; the dev
build is byte-identical to today's. The measurements are
[`plans/release-notes.md`](../../plans/release-notes.md), taken by hand-applying each candidate to
the emitted `.mjs` of the corpus built at `e407c10` and re-compressing — and by running every one of
the 100 `run/` programs afterwards to prove the transformed output still prints its `.expected`.

| | dev | release | |
|---|---:|---:|---|
| floor (`Empty`), raw / brotli | 2 147 / 833 | 1 874 / 783 | −6.0% |
| `run/Dictionaries.beni` | 31 495 / 7 008 | 19 971 / 5 847 | **−16.6%** |
| `bench/corpus` (`--library`) | 126 436 / 21 840 | 57 069 / 15 055 | **−31.1%**, raw −55% |

**Why the floor barely moves is the one number to read first.** A sibling is hand-written JavaScript
copied verbatim (§2) and **is never minified — not renamed, not reprinted, not parsed**, because
reading it exactly needs a JavaScript parser and that is the dependency `boundary.md` §4's wall
exists to avoid. It costs **1 643 of the floor's 2 147 bytes (76%)**, **13 773 of `Dictionaries`'
31 495 (44%)** and 14 980 of `bench/corpus`' 126 436 (12%). After this slice the generated half of
`Dictionaries` has fallen 17 722 → 6 198 bytes, −65%, and the siblings are **69% of what ships** —
the same answer §9's *Purity* paragraph reached about sibling-level elimination, for the same reason.

#### Item 1 — local dead bindings, and the single use that follows them

One pass over `JsIr`, **per function body**, after lowering and before printing. `Reach` decided
which declarations exist; this decides what is left inside one. Two rules, one walk.

**A use count per binding.** Walk a function's statements once, counting `ident` reads of every
`NameIndex` a `const_decl` or `let_decl` introduces in that body, nested functions included — a
closure reading an outer binding is a use. `JsIr` names are `NameIndex`es and two names are equal
exactly when their indices are (`src/js/JsIr.zig:300-330`), so the count is an array indexed by
name and needs no map and no scope stack.

**The array is per TOP-LEVEL DECLARATION and not per module**, and the sentence above was written
as if it were per module, which does not work. `localName` gives every local of ONE declaration a
distinct disambiguator (`src/js/Lower.zig:1255-1271`) and then **restarts**, so `a$2` of `sum` and
`a$2` of `square` are one `NameIndex`; counted module-wide that reads as two declarations and four
uses and every fold in the module is declined. The compiler-made names are positional or
depth-derived and repeat for the same reason (`$m$k` `:447`, `$in$i` `:463`, `$t$n`/`$p$n` through
`fresh` `:365`, `$j$<d>$<b>` and `$c$<d>` `:4494`, `:4503`). The counters are therefore reset per
declaration, by a stamp rather than a `@memset`, which keeps the reset O(1) and the pass linear.

**The substitution is keyed by the USE SITE and not by the name**, for the same reason pointing the
other way, and getting this wrong is a wrong answer rather than a missed byte: with a name-keyed
table `run/MatchRowOrder`'s two functions overwrite each other's `n$2`, and the emitted code reads
`xs$1.a` where it meant `xs$1.b.a` and exits 0. So the plan is one slot per `ident` NODE.

**Zero uses: the binding is dropped WHOLE, initialiser included, whatever the initialiser is.**
`language.md` §6's *What an optimiser may assume* is the licence, in so many words: "a binding whose
value is never used may be dropped whole, everything inside it included, a `Debug.log` among it".
The pass therefore asks nothing about the right-hand side. **A call of a `foreign` is droppable**,
and the reason is not a special case: `boundary.md` §4 confines a `foreign` to a total pure function
over admitted types or an effect *value*, and an effect value is data — `Node.printLines` returns
`{code, out}` having written nothing, and the write happens in `platform/runtime.foreign.mjs`'s
`run`, which only the entry file reaches. The two values that *can* notice are `Debug.log`, which
writes when called, and `Debug.todo`, which throws when called; both are the violations
`boundary.md` §4 names, and `language.md` §6 spends exactly this licence on them. *Alternative
rejected: a "does the initialiser call a `foreign`?" test, which would pin `Node.done` in every
platform module and is the `sideEffects: false` guesswork §9's purity paragraph exists to replace.*
Measured: **39 raw bytes across the whole corpus, in one declaration** — `bench/corpus`'s
`ExprParser.tokenizeChars`, where a `c :: rest` row binds `rest` and the body reads the list whole.
Nearly worthless today and specified anyway: it is the half that is about correctness rather than
bytes, and §7's leaf bindings are the construct that makes more of them.

**Exactly one use: the binding is inlined**, under a rule that is narrow on purpose.

| Condition | Why |
|---|---|
| the initialiser is an **atom or a member chain** — a name, a literal, or `a.b.c` on one | re-reading one repeats no work and shows nothing (§4's record-literal rule, §7's "an occurrence is a member chain, not a name") |
| the use is in the **same statement list** as the binding | crossing into a nested `if`, `switch` case or block would sink an evaluation into a branch, and crossing out is worse |
| every statement **between** them is another such binding | `language.md` §6: two evaluations that both survive may not be reordered against each other. Nothing that survives is evaluated in between, so nothing is reordered |
| no `assign_stmt` in the body targets the chain's base name | the base may be an `$in$<i>` slot, which §8 reassigns per iteration; a read of it is not a stable read |
| the use is **not inside an `arrow` or `func_decl`** nested below the binding, and not inside a `while_true` the binding sits outside of | a closure or a loop body evaluates its contents a different number of times than the table in `language.md` §6 gives |

That is the whole rule, and it is what §7's and §8's temporaries were shaped for:
`const $t$1 = $p$1.a; return f($m$0, $t$1, k$2);` becomes `return f($m$0, $p$1.a, k$2);`, and
`const key$2 = t$1.b; const value$3 = t$1.c; … return {…b: key$2, c: value$3…};` folds the whole
prologue into the literal.

**This reopens §9's "explicitly not built" list, and the measurement is why.** That list retired
`inlining` and `collapse_vars` on report 12 §2.5, where they were worth −87 and **+60** brotli bytes
on Elm's output. Elm's output had no such temporaries; §7's decision trees, §8's loop prologue and
§4's written-order record temporaries all landed afterwards and all generate them. Measured on the
stack, everything else held equal: **−412 brotli on `bench/corpus` (−2.7%)**, −123 on `Dictionaries`
(−2.1%), −1 856 over all 102 trees; before renaming and compaction it is −4.8% on its own. It is in.
**What stays out is the wider licence**: allowing any initialiser and requiring the use on the very
next statement buys −90 brotli on `bench/corpus` and **loses 15 on `Dictionaries`**, at the cost of
the one condition above that is easy to state and hard to get wrong. So the rule stays "an atom or a
member chain", and `collapse_vars`, constant evaluation and body inlining stay off the list.

**Determinism.** The pass reads only `JsIr`, visits statements in emission order, and its output is
a subset of its input with substitutions at fixed positions; no map is iterated and no counter is
shared. **Cost:** two linear walks of each function body and no sort. **No fixpoint either**, as long
as the rewriting walk runs backwards: a substitution never raises anyone's use count, and a chain —
`const x = p.a; const y = x.b; return f(y);` — collapses in one backward pass because `y` is
resolved before `x` is looked at.
**Where:** inside `Emit.emitModules`, between `Lower.lower` and `Print.print`
(`src/js/Emit.zig:760-786`), on the `JsIr` the lowering just produced.

#### Item 2 — short names, emitted directly

Identifiers are 66.8% of unminified bytes and qualified globals 26.6% (report 12 §5.2), and this is
the largest single win in the slice: **−4 941 brotli on `bench/corpus` alone, −22.6%.** Names in
`JsIr` are `Name` records in one column (`src/js/JsIr.zig:52-54`, `:300-330`) and the printer is the only
thing that turns one into bytes (`src/js/Print.zig:172-192`), so this is a rewrite of that column
and of nothing else — no second traversal, no mangler, no string building on the hot path.

**Two namespaces, and the split is measured, not assumed.**

- **One whole-program namespace for names that cross a file**: every top-level declaration, every
  derived function, every synthesised comparator. They appear in an `import` or `export` specifier
  and the two files must agree, so one table for the build assigns them and both ends read it.
- **One namespace per top-level declaration for its locals**: parameters, `let` `const`s, leaf
  bindings, `$t$n`, `$p$n`, `$in$<i>`, `$m$k`, and the `$j$<d>$<b>` / `$c$<d>` / loop labels. The
  alphabet restarts in every declaration, skipping only the short names the globals *this
  declaration mentions* were given. Labels share the binding namespace rather than getting their own
  — JavaScript keeps them apart, and giving a label the same letter as a binding is legal and one
  table simpler.

Reusing the alphabet per declaration is worth **4 878 brotli bytes** over a single flat namespace
across the corpus. *Alternative rejected: one namespace for the whole program, which is simpler and
measurably worse, because it pushes locals into two-character names for no reason.*

**Assignment is in emission order, not frequency order, and that is a departure from the list
above.** §9 item 2 says "frequency-ranked", after report 12 §5.2, where Closure, dart2js, Scala.js
and Elm all sort by frequency. Measured on our own output, frequency ranking **loses**: 409 338
brotli against 408 538 for emission order over the corpus, 17 086 against 16 899 on `bench/corpus`,
and the same sign inside the full stack. Closure's own source says why — `RenameVars` assigns
same-length names in source order so that *"symbols declared close together are assigned names that
are quite similar. With this heuristic, the output is more compressible"* — and that effect
dominates once a local namespace is small enough that everything gets one character either way.
Emission order also discharges report 12 §5.2's stability obligation for free, where dart2js
over-allocates its pool 3× and hashes into preferred slots to buy the same property.
**What is promised is exactly this:** a name is a function of the declaration's
position in `emissionOrder` (§5) and of the binding's position inside it, both input-derived
(CLAUDE.md rule 5), so `--jobs=1` and `--jobs=8` agree and two builds of one tree agree. What is
**not** promised is that an edit renames nothing else: inserting a declaration shifts the global
names after it. That is the honest guarantee, it is what §10's cross-chunk naming needs, and
buying more is dart2js's 3× pool, which costs bytes for a property no test asserts.

**The alphabet** is 54 first characters — `a`–`z`, `A`–`Z`, `$`, `_` — and those 54 plus `0`–`9`
afterwards, ordered so the two sets stay as close as possible (`DefaultNameGenerator`'s reason, quoted
in report 12 §2.2: putting digits first in the non-first set *"would end up balancing the huffman
tree"*). A generated name that is a reserved word is skipped, using `Print.isReservedWord`
(`src/js/Print.zig:584`) plus `eval`/`arguments`, which that list already carries. No global to
avoid: the emitted module references no host global at all — `boundary.md` §4's third check is what
keeps the siblings from reaching one and the generated half never had any.

**What is NOT renamed**, and the list is closed:

| | Why |
|---|---|
| the `imported` half of a sibling specifier — `add` in `import { add as Basics$add } from "./Basics.foreign.mjs"` | it is the sibling's own export name, fixed by `language.md` §5.4 and enforced by `boundary.md` §4's second check. The `local` half moves freely, which is the whole point of the `as` |
| `run` in the entry file | the platform manifest's `runtime` export (`boundary.md` §5.2), read by hand-written JavaScript; `Emit.emitEntry` writes both ends (`src/js/Emit.zig:840-857`) and the `main` side of it is an ordinary global that renames |
| every property name — the `$` tag, the `a`/`b`/`c`… slots, record fields | item 4's territory, and the second slice's. `runtime.foreign.mjs` reads `program.out` and `program.code`, and `Node.foreign.mjs` walks `.$`/`.a`/`.b`, so a field can cross into hand-written code and the rule that decides which is the artifact item 4 is waiting for |
| anything inside a `*.foreign.mjs` | copied verbatim, never parsed |

Cross-module agreement needs no new machinery: both the `import` specifier and the `export` list are
built from the same `NameIndex`es the declaration uses (`Lower.exports`, `src/js/Lower.zig:637-680`;
`need`/`needDerived`, `:743-759`), so renaming the column renames both ends. **Emission order and
grouping do not change** — report 12 §2.1 measures up to 7% of gzipped bytes for keeping related
declarations adjacent, at identical raw size, and this slice must not spend it.

M5's source maps read the mapping the other way: `addSourceMappingForName` carries the *original*
name in the fifth VLQ field, which is what makes a minified stack trace readable, and the printer
already asks for a name at print time — so §11's "fused into the print pass" is what keeps this
free (report 12 §6.2). Pointer only.

#### Item 3 — compact printing

One boolean on `Print.Printer`, threaded to the places that push whitespace — esbuild does it in 35
branch points and measures it as free at run time (report 12 §6.1). Worth **−1 426 brotli on
`bench/corpus` (−6.5%)** and −24% of raw. What goes:

- `indent` emits nothing (`src/js/Print.zig:162-166`).
- `" = "` → `"="`, `", "` → `","`, `" ? "`/`" : "` → `"?"`/`":"`, `": "` → `":"` in a `property`,
  `" => "` → `"=>"`, `"{ "`/`" }"` → `"{"`/`"}"` in an `object`, and the space either side of a
  `binary`'s operator (`:230-232`, `:439-449`, `:472-475`, `:482-487`).
- `"} else {"` → `"}else{"`; a keyword keeps exactly the space that separates it from what follows —
  `return x`, `const x`, `case 1:`, `typeof x`, `throw x`, `break L`, `continue L`.
- The newline after every statement goes, **except one**: a newline after each top-level statement
  stays. Measured cost: **21 brotli bytes on `bench/corpus`, 40 over the corpus, ~0.1%** — for which
  a stack trace still names a declaration by line and a diff of two builds is readable. Closure
  places newlines in similar contexts for the same reason (report 12 §2.2).

**Two adjacencies must not close up, and they are the whole of the tokenisation risk.** An
identifier, keyword or number followed by another is one token when the space goes, which is what
the keyword rule above is; and `a - -1` closing to `a--1` is a decrement. So the printer keeps one
space between two tokens whose last and first characters are both identifier characters, and between
a `binary` `+`/`-` and a `unary` `+`/`-` that follows it. Nothing else in `BinaryOp.text` or
`UnaryOp.text` (`src/js/JsIr.zig:263-298`) can merge — `typeof ` already carries its own space.

**Built as one guard on one function and not as a rule at each branch point**, because the branch
points are where it gets forgotten: every byte goes through `Printer.push`, which keeps the last
byte emitted and asks `merges` about the join. Then `return x`, `const a`, `case 1:`, `break L` and
`a - -1` are the same rule, and a construct added later cannot miss it. `/` before `/` or `*` rides
along at no cost.

**A token written in several pieces must open ONCE.** A string literal reaches the joiner as its
runs and its escapes, a template as its chunks and its interpolations, a long name as
`Module`, `$`, `base`, `$tag` — and a guard asked per piece sees `n` beside `t` inside `"one\ntwo"`
and puts a space in the middle of the string. `run/StringOps` caught exactly that. So those three
open with the first byte and continue without the guard.

**Semicolons stay, all of them.** Every newline the release printer emits comes immediately after a
`;`, so no newline is ever in a position where ASI could stand in for a semicolon and there is
nothing to elide. Dropping the last semicolon of a block would save one byte per block and
reintroduce the whole question. *Alternative rejected: omitting a semicolon before `}`, which is what
every general minifier does and what obliges it to know that a statement beginning `(`, `[`,
`` ` ``, `+`, `-` or `/` must be prefixed.* The corpus still gets fixtures for the traps, because the
claim being pinned is that the printer never creates one (below).

**Number and string literal forms do not change.** A `number` node is the source spelling verbatim
(`src/js/JsIr.zig:170-174`) and beni's numeric syntax is a subset of JavaScript's, so nothing in the
compiler re-formats a number; turning `1000` into `1e3` would touch a value the front end promised
not to, for a family report 12 measured at noise. Strings keep `Print.quoted`'s escapes (`:527-557`)
and templates `templateChunk` (`:561-577`): picking a quote character by content is worth a byte per
apostrophe and costs a scan.

**Parenthesisation is already minimal and must stay that way.** The printer computes brackets from a
precedence table and carries no `paren` node (`src/js/Print.zig:368-385`, the header at `:20-24`),
bracketing a child strictly below its parent and a left-associative operator's right operand at
`prec + 1`. There is nothing to remove. **Arrow bodies are already concise too**: `arrowBody`
(`:502-520`) prints `(a) => a` when the body is one `return`, and brackets an object literal so the
brace does not read as a block. Neither is item 5's conditional lowering and neither is new work —
they are recorded here so the implementer does not go looking.

*What compact printing must not do: reorder anything, merge adjacent `switch` labels (§7 files that
under "a printer-level win, and M3c's" — it is item 5's family and measured with it), or change
which node is printed. It is a whitespace decision and nothing else.*

#### Item 5 — variable joining, and the three rewrites that did not earn their place

All four are printer decisions over statement runs, measured marginally against the rest of the
slice over all 102 trees. Report 12's discipline is to drop anything that does not clearly earn its
bytes after compression, and three of the four do not.

| Rewrite | Δ raw | Δ gzip | Δ brotli | verdict |
|---|---:|---:|---:|---|
| a run of `const_decl`s at one level → `const a=1,b=2;` | −3 024 | −229 | **−274** | **in** |
| `if (c) { return a; } else { return b; }` → `return c?a:b;` | −446 | +30 | **+38** | out |
| `if (c) { x = a; } else { x = b; }` → `x = c?a:b;` | −13 | −10 | −8 | out |
| `if (c) { return a; } return b;` → `return c?a:b;` (`if_return`) | −359 | −4 | **+18** | out |

**Variable joining is in**, and it is what §8 reserved: the loop prologue deliberately emits one
`const` per carried parameter and points here, so `const xs$1 = $in$0; const acc$2 = $in$1;` becomes
`const xs$1=$in$0,acc$2=$in$1;`. The rule: a maximal run of adjacent `const_decl` nodes in one
statement list, each with an initialiser, joins into one. It reorders nothing — the run keeps its
order and a comma declaration evaluates left to right, which is the `let` bindings row of
`language.md` §6 unchanged — and it is a printing decision, so no `JsIr` node moves. A `let_decl`
does not join a `const` run and an uninitialised `let_decl` does not join at all: §7's `let $t$n;`
sits above an `if`/`else` chain and joining it with a later `const` would move a declaration past
the statements between them.

**The module body is a statement list too, and it joins**, which reads at first as a conflict with
item 3's newline after every top-level declaration and is not: the run is printed
`const a=1,\nb=2;`, so the `const ` and the `;` are saved while the line break still falls after
each declaration and a stack trace still names one. Worth 23 brotli bytes on `bench/corpus` over
joining inside bodies alone, which is the whole of the gap between the implementation and the
hand-applied figure above. Evaluation order is unchanged — a comma declaration runs left to right,
exactly as the separate statements did — and so is the temporal dead zone, since the members keep
their order.

**The three conditional rewrites are out.** The return form measures **worse** after compression on
every reading — +38 over the corpus, +18 on `bench/corpus`, +7 on `Dictionaries` — and the reason it
loses here while report 12 §2.5 measured `conditionals` at a small win is §7: a tail-position `case`
now lowers straight into statements, so the arms it would collapse routinely hold a `const` prologue
or a `return` that a ternary cannot take, and what is left is the handful where it fires and costs
entropy. The assign form is indistinguishable from zero — 13 raw bytes — because it **fires three
times in the whole corpus**, §7 having deleted the `let $t$n` / assign / `return $t$n` triple it
used to live in; building a rewrite for three sites is how a printer grows a pass nobody can retire.
`if_return` loses in both measurements, ours at +18 and report 12's at +6, and `booleans`
(`true` → `!0`), `sequences`, `comparisons` and `switches` were never on the list. Merging adjacent
`switch` labels that reach one body (§7's last bullet) is measured with this family and is **not
built**: §7's `default:` rule already removes the case that would fire most.

#### Throughput, and where the four passes sit

Measured today on this machine, `bench -- --generate=100000`, ReleaseFast: emit is **54.15 ms for
633 modules and 3 086 421 bytes of JavaScript — 54.4 MB/s, 1 914 880 lines/s** — inside a **179.6 ms**
cold build of 100 159 lines, against §13's 5 MB/s and 800 ms. The budget for `--release` is that it
**stays above §13's 5 MB/s with a factor of five in hand** — a ceiling of roughly 4× today's emit
time, which is not a real constraint: the dead-binding pass is two linear walks per body, renaming
is one pass to count and one to assign over a column already built, compact printing is strictly
less work than indented printing, and joining is a lookahead of one node. Report 12 §6.1 measured
esbuild's `--minify` as *not slower than plain printing*. **What would breach it is a sort per
function or a fixpoint**, and neither is specified. Read `--self-profile`'s `emitted_bytes` (§2)
rather than `mb_per_s`: §7 records why that metric reads backwards when output shrinks, and here it
shrinks by 55%.

#### Testing

§12 is the rule and this is its release half. **A `run/` fixture is only a behaviour guard if it is
built under `--release` too**, so the whole `run/` corpus gets a second pass: the same fixture, built
with `--release`, run under Node, asserted against the same `.expected`. Not a marked subset — the
failure mode of a minifier is a wrong answer in a program nobody thought to mark, and the corpus is
the asset precisely because nobody has to guess in advance (CLAUDE.md rule 3). **Measured cost:** one
serial pass of all 100 programs is 15.4 s (11.1 s compiler, 4.3 s Node); `zig build test-blackbox` is
67 s wall at about 2.1× parallelism, so the second pass adds roughly **7 s, +11%**. That is the price
and it is worth it.

- **`emit/release/`** is the new golden directory, for shape claims about the optimiser itself, by
  the same per-fixture mechanism `emit/app/` uses for `--library` (`tests/blackbox/corpus_test.zig:193-205`,
  `:531`): a `release: bool` on `Fixture`, set for anything collected under `emit/release/`, appending
  `--release`. Everything under `emit/` keeps `--library` and its dev golden, and **none of the
  seventeen may move**.
- **Determinism** covers `--release`: `tests/blackbox/build_test.zig:292` and `:417` build the same
  project at `--jobs=1` and `--jobs=8` and compare the whole output tree file for file; each gains a
  `--release` pair. The pass-level arguments are above; this is the machinery that proves them.

The fixtures, by intent:

| Fixture | Intent | Observable |
|---|---|---|
| `run/ReleaseDeadDebug` | a `Debug.log` in a binding nothing reads, beside one in a binding that is read, beside one in a dropped declaration (`run/DceDebugLog`'s other half) | exactly the live lines, in order — pins that the dead binding goes whole and that the surviving order did not move |
| `run/ReleaseNameCollision` | locals whose source names are JavaScript reserved words (`new`, `class`, `let`, `eval`); more than 54 locals in one declaration, so the alphabet spills to two characters; two sibling `case` branches binding the same source name; a §8 loop label beside a binding of the same source name; a declaration that mentions enough globals to push its locals past the ones they may not take | the answers; a collision is a `SyntaxError` at load or a silently wrong value |
| `run/ReleaseAsiTraps` | expressions whose printed form starts with `(`, `[`, `` ` ``, `+`, `-` and `/`, in statement position and after a `return`; `a - -1` and `a + +b` in one expression | the values; pins that the printer never needs ASI and never merges two operators |
| `run/ReleaseInlineOrder` | the inliner's own hazard: a binding whose one use is behind a surviving `Debug.log`, one whose use is inside a lambda, one whose use is inside a §8 loop body while the binding is outside it, and one reading an `$in$<i>` slot that the loop reassigns | the printed order and the values; each is a wrong answer if a condition of item 1's table is dropped |
| `run/ReleaseEverything` | one big program using every construct — reuse `bench/corpus`'s `ExprParser` or `Dictionaries` rather than writing a new one | its `.expected`, unchanged |
| the whole existing `EvalOrder*` and `CallbackOrder*` set | the regression half, run again under the flag rather than copied | unchanged `.expected`; an optimiser that reorders two surviving evaluations moves one of them |
| `emit/release/ReleaseNames` | the shape: short names, the sibling specifier's `imported` half untouched, `import`/`export` agreeing across two modules | golden |
| `emit/release/ReleaseCompact` | the shape: one line per top-level declaration, no indentation, every semicolon present, joined `const` run | golden |
| `emit/release/ReleaseInline` | the shape: a leaf prologue folded into the literal that reads it, and a binding read twice NOT folded | golden |

Fail-first is ordinary: every `emit/release/` golden does not exist before the slice and every `run/`
row above either throws, prints the wrong thing, or fails to build today (`--release` exits 2). The
`run/` rows that are re-runs of existing fixtures are the regression half, and one that moves is a
finding.

#### Acceptance

§1's M3c acceptance is §9's size and throughput numbers alone. For this slice, all five:

1. **`bench/corpus` under `--release` is at or below 15 055 brotli bytes** and `Dictionaries` at or
   below 5 847, against 21 840 and 7 008 today — the hand-applied predictions above. A real
   implementation may beat them (the measurement's renamer is conservative about scope reuse) and
   must not lose to them by more than noise.
2. **Every `run/` fixture passes under `--release` with no `.expected` change**, and every `emit/`
   golden and every `run/` fixture built without the flag is **byte-identical to today**.
3. **Sizes are reported through `bench/size.mjs`**, which gains a `--release` column measured in the
   same run as the dev one — both directions recorded whichever way they come out.
4. **Emit throughput stays above 5 MB/s of JavaScript** (§13) with the margin above; `emitted_bytes`
   is the counter that should fall.
5. **The determinism test is green** at `--jobs=1` and `--jobs=8`, twice each, byte-compared, with
   `--release` in the matrix.

Report 12 §7 item 7's exit criterion is the outer one and is not this slice's: beni's own brotli
within ~10% of beni's output piped through `esbuild --minify`. Neither `esbuild` nor `terser` is in
the flake today, so that comparison wants a pinned binary and is the measurement to run once
`--release` exists.

#### What the second slice owes

**Item 4, type-directed field ambiguation** — two fields that never co-occur on a type share one
short name, shrinking the *alphabet* rather than the lengths, which is the quantity the compressor
charges for (report 12 §2.2, §5.4). Report 12 §5.3 bounds it at **~4% of brotli'd bytes**, from
`terser --mangle-props` on Elm's bundle, and Evan's own 5–10% for Elm's field shortening.

*This paragraph and the two after it are what the first slice expected of item 4, kept because the
expectation is what the measurement had to beat. It did not: **item 4 is specified and declined**
below, under* Item 4 — field ambiguation, specified and then declined*, which also withdraws the
checker artifact and corrects the `program.out` constraint. Read that before acting on this.*

It needs something the backend does not have. §3 is explicit: the backend sees no types, and static
dispatch did not change that — `Lower.Input` carries a *dispatch table* of resolved targets, not
solved types. What item 4 wants is a **per-build field-interference artifact**: for each record field
name, the set of record types it occurs on, so that two names may share a colour iff their type sets
are disjoint. That is a checker product, computed where the record types are, delivered the way the
dispatch table is delivered — flat, index-based, one per module, merged whole-program before
lowering, exactly as `Reach` merges edge lists. Two constraints it must respect and this section
records now rather than discovering later: **a field that a sibling reads by name may not be
renamed at all** (`runtime.foreign.mjs` reads `program.out` and `program.code`; `Node.foreign.mjs`
walks `.$`, `.a`, `.b`), and the `$` tag and the positional `a`/`b`/`c`… slots are the emitter's own
representation (`slotName`, `src/js/Lower.zig:430-437`) and are already one character.

**Integer constructor tags** (§4: "tag is a string in dev, an integer in release") ride with item 4,
because both are a representation change under the flag and both are visible to a sibling —
`core/List.js` and `Node.foreign.mjs` already build and walk `{$:0}`/`{$:1}` by contract (§4's *where
the empty list comes from*), so a `$` that means something different under `--release` is a change to
that contract and needs the same artifact-shaped answer.

**Everything chunk-facing is §10's**, and it inherits two things from this slice rather than
inventing them: the whole-program name table, which is what makes a cross-chunk binding nameable at
all (report 12 §8 item 10 — stable names are what Elm gave up), and §9's graph with more than one
seed. §10 is where that lives. Chunking waits on owner decisions that are not this section's:
[`plans/m3d-plan.md`](../../plans/m3d-plan.md) §6 holds them, §10 marks each as PENDING, and nothing
here unblocks any of them.

#### Item 4 — field ambiguation, specified and then declined

**It is not worth building, and this is the measurement that says so.** Item 4 is worth **0.71% of
brotli on `bench/corpus`, 0.00% on `Dictionaries` and 0.07% over the whole corpus** — against report
12 §5.3's predicted ~4%, which was `terser --mangle-props` on *Elm's* bundle and has now been
measured on beni's. Numbers, method and the rejected variants are
[`plans/release-notes.md`](../../plans/release-notes.md) K–N; the same hand-applied discipline as the
first slice, on the release trees this binary emits today.

| tree (release) | brotli | (i) frequency | (ii) colouring | field bytes / generated bytes |
|---|---:|---:|---:|---:|
| floor (`Empty`) | 789 | 789 | 789 | 0 of 237 |
| `run/Dictionaries.beni` | 5 860 | 5 860 | 5 860 | **0 of 6 063** — it has no record at all |
| `bench/corpus` (`--library`) | 15 017 | **14 910** (−0.71%) | 14 931 (−0.57%) | 495 of 40 613 (**1.2%**) |
| 109 trees, summed | 436 547 | 436 230 (−0.07%) | 436 227 (−0.07%) | — |
| synthetic, 24 records × 10 fields | 6 734 | 5 599 (−16.9%) | **4 999 (−25.8%)** | 10 604 of 18 810 (**56%**) |

**The transformation works; the corpus has nothing for it to do.** The last row is the control: a
generated library of 24 record types with 120 realistic field names, where colouring is worth a
quarter of the delivered bytes. beni's own corpus is ADT-shaped — `Dictionaries` is 6 kB of generated
code containing **not one record literal**, and all 25 files of `bench/corpus` hold 18 distinct field
names in 96 occurrences. **The predictor is the field-name byte share of the generated half**, which
is 1.2% here and 56% there, and the win tracks it almost linearly. *The revisit trigger is a real
program above ~5%*; `bench/size.mjs` is where that number belongs when someone wants it.

**Between the two schemes, take the one with no graph.** (i) gives every distinct field name its own
short name, frequency-ranked, and needs nothing but the name. (ii) is item 4 proper — two names share
a short name iff no record carries both. Over the corpus they tie (436 230 against 436 227) and on
`bench/corpus` (i) **wins by 21 brotli**, because with 18 names and a widest record of 8 the
colouring saves no characters and only scatters the token stream. (ii) pulls ahead only where the
alphabet actually overflows: 600 brotli on the synthetic, where (i) captures 65% of its win. *So if
anyone builds this, build (i); (ii) is rejected with numbers until a program's field share earns it.*

**The unit is the source field NAME, whole-program, and never a (type, field) pair.** One name, one
spelling, everywhere. That single choice disposes of row polymorphism: `getX : { r | x : Float } ->
Float` reads `.x` on every record that has an `x`, and it stays correct without knowing which record
it was handed, because there is only one spelling of `x` in the build. *Alternative rejected: one
spelling per (record type, field), which is what "fields that never co-occur **on a type**" literally
asks for — it needs the equivalence classes of field occurrences joined by unification, those joins
happen inside whichever module unified the rows, and two modules that never meet can both unify with
a third module's open row and pick different spellings. It buys shorter names on a surface that is
1.2% of the bytes, and it is the only version of item 4 that could ever be wrong.*

**The interference graph needs no checker artifact, and §3 stands.** Nodes are field names; an edge
joins two names that appear in one record; colour greedily in descending frequency with the source
text as tie-break (rule 5). The graph is exactly the set of **record-literal key lists already in
`JsIr`**: a beni record is closed (`checker.md` §6.1), a literal names every field, record update
bottoms out at a literal, and **no `foreign` signature in `core/` or `platforms/node` mentions a
record type**, so no record enters a program from JavaScript. Every inhabited record type therefore
has a literal in a whole-program build. *That is the paragraph above this one withdrawn: the
per-build field-interference artifact it asked the checker for is not needed, the backend still sees
no types, and static dispatch's dispatch table remains the only thing `Lower.Input` carries.*

**The alphabet is `a`–`z`, `A`–`Z`, `_`, digits from the second character — and `$` is excluded.**
`core/Debug.js`'s `show` decides "constructor or record" by `typeof value.$ === "string"` and "list
or not" by `value.$ === 0 || value.$ === 1`, so a field spelled `$` changes what a value *is* to a
sibling. **A field may be `a`**: a record is a `$`-free object of fields and a constructor
(`{$:"Tag",a,b,…}`) and a tuple (`{a,b,…}`) are objects of positional slots, and no object is ever
both, so `slotName` (`src/js/Lower.zig:430-437`) costs the field alphabet nothing. Start at `a`.

**What may not be renamed, and the list is closed.**

| | Why |
|---|---|
| `program.out` / `program.code` | **not a record and never were.** `Program` is a `foreign type` (`platforms/node/Node.beni:24`); the object is built in `Node.js` and read in `runtime.js`, and **no generated `.mjs` in any of the 109 trees mentions either name**. The first slice recorded this as item 4's hard constraint; it is not one |
| the `$` tag and the `a`/`b`/`c`… slots | not fields, and already one character |
| a `<T>$$order` key | it is a **constructor tag name**, read dynamically as `M$T$$order[x]` (`Lower.orderTable`, `src/js/Lower.zig:2229-2272`; `orderLookup`, `:2282-2286`). Not item 4's — but it is worth recording that report 12 §5.4's "no `obj[dynamicString]` exists" is **false of today's output**, and the integer-tag item is where that is paid |
| anything inside a `*.foreign.mjs` | copied verbatim, never parsed |
| **every field, if `Debug` survives** | below |

**`Debug` is the whole of the pinned set, and the corpus proves it.** With every field renamed, **103
of the 107 `run/` programs still print their `.expected` byte for byte**. The four that do not —
`DebugLog`, `EvalOrderLiterals`, `EvalOrderRecordFields`, `QuestionOrder` — each turn a
`{ name = "Ada" }` into `{ a = "Ada" }`. Nothing else notices: `Basics.eq`'s `Object.keys` walk
(`core/Basics.js:93-108`) compares two values of **one** type, which carry one colouring, and
`List.eq`/`List.compare` touch only `.$`/`.a`/`.b`. The record-reaching `foreign` positions are the
closed list `Basics.eq`/`neq`, `List.cons`/`eq`/`compare` and `Debug.log`/`todo`/`toString`, and only
the last two read a field **name**.

There is no per-type answer available: `Debug.log : a, String -> a` is a type variable and the record
can arrive through any number of generic frames, so "which records reach Debug" is not a question the
backend can ask. **The conservative rule needs no decision and is one membership test**: if `core/Debug`'s
`log` or `toString` survives §9's reachability walk — a *foreign binding* node, §9's table — field
renaming is off for the whole build. **The other rule is the owner's**: Elm 0.19 refuses `Debug` under
`--optimize`, beni does not, and §9's own `run/ReleaseDeadDebug` asserts a `Debug.log` line under
`--release` through a `.release-expected` of its own (`tests/blackbox/corpus_test.zig:481-498`).
Taking Elm's rule would delete the pin; **this section does not take it.**

**Every order stays SOURCE-name order, and that is what makes this a print-time substitution.** Three
places read a record's fields sorted by name and all three keep sorting on the source text:

- the record literal's key permutation (§4). Sorting on the short name is a *different* permutation,
  which changes which initialisers need a `$t$<n>`, which means dev and release would differ in
  evaluation order — the thing §4's rule exists to prevent. Hidden-class stability wants *a*
  consistent order, not a particular one, so nothing is lost.
- the derived `eq`/`compare` of a record shape: one evidence parameter per field, fields in name-text
  order, positional (`static-dispatch-spike.md` §9.2; `src/js/Lower.zig:2351-2360`). `compare` is
  lexicographic in that order, so re-sorting on short names would make `<` answer differently in
  release than in dev.
- `Debug.toString` prints in `Object.keys` order, which is insertion order, which is the literal's.

So `Lower` does not move. The two `.fixed` name slots in `Print.zig` that carry a **property** —
`.member` at `:736` and `.property` at `:758`, the third being a sibling's own export name at `:474` —
gain a `.field` role and a table, exactly as item 2 rewrote a column.
**`Lower` must mark which of those nodes are a record's**: the printer cannot tell a field from a
tuple slot, because a tuple is a `$`-free object too (§4). The hand-applied measurement got this
wrong first and `run/Tuples` caught it in one run, which is why it heads the fixture list.

**Separate compilation, `--library`, M4.** A short name is a whole-program decision, like item 2's
global namespace, and a release build is not M4's warm path (§9) — restated, not re-argued.
`--library` is the one place the closed world fails: an exported record type can be inhabited only by
the consumer, so its literal is not in this build and the graph is incomplete, and a `--library`
build's consumer is hand-written JavaScript — a beni consumer recompiles from source — which reads
the fields by name. **`--library` pins every field.** Which means the one tree in this repository with
records worth counting is a library, and the −107 brotli in the table above is what item 4 *would*
deliver there if the rule did not apply. It would deliver **zero**.

**Fixtures, if it is ever built**, by intent: `run/Tuples` and `run/MatchRecordsTuples` unchanged (a
tuple slot is not a field); a record reaching `Debug.log` and `Debug.toString` (identical dev and
release output, or the documented rule applied); a row-polymorphic accessor over two record types
that share only the read field; one field name on two unrelated records; a record of more than 54
fields (alphabet rollover); fields spelled `a`, `b` and `$`; a derived `compare` on a record whose
source-name order differs from its short-name order, asserted through `List.sort`; a record crossing a
module boundary and one crossing into a `Dict` key; the same program under `--library`, asserting
**no** renaming. The self-check, in `Rename.verify`'s spirit: no two properties of one object literal
share a spelling (a linear scan of a property list the printer already holds), every `.field` slot
resolves, and no spelling is `$`. That an access names a field the record has is **not** checkable
here and never will be — the backend has no types, which is §3 and not a gap.

**Acceptance, if it is ever built**: `bench/corpus` at or below **14 910** brotli with the library
rule off and **byte-identical** with it on; every `run/` fixture unchanged under `--release`; emit
throughput within noise of today's **48.08 ms / 61.2 MB/s for 633 modules** (`bench -- --generate=100000`,
ReleaseFast, this machine), which a print-time table lookup cannot move.

## 10. Chunking

**Release output is chunks; development output is not.** §9.5 of the design doc settles that with
"two build modes, one graph", and M3d is what makes the second half true. A chunk is a file; a
declaration's chunk is decided by which entry points reach it; and **with one entry point and no
`lazy`, a release build is exactly one file**, which is the degenerate case of everything below and
the part of this section worth the most bytes.

**What is PENDING an owner decision, and nothing here quietly assumes an answer.** The `lazy` marker
is specified in `fast-compiler.md` §9.5 as rewriting a declaration's type to `Task LoadError a`, and
that section's own block quote says the type is gone. A deferred load is asynchronous, this language
is synchronous and has no effect system yet, and there is therefore **no way to express a deferred
value in the language as it stands**. [`plans/m3d-plan.md`](../../plans/m3d-plan.md) §2 is the
argument and §6 the decisions: whether `lazy` is a keyword, a contextual word or neither; whether it
waits for `plans/effects-plan.md`'s E1–E3; whether a build may carry more than one entry point. Until
those are taken, this section specifies the chunker and **not** the trigger. Everywhere below, "an
entry" means a declaration in the seed set, and how a declaration gets there is PENDING.

### The colouring

Entry points are **the entry declarations of the build** — today `main`, and whatever §6's decisions
add. Each node's colour is the set of entries that reach it; nodes sharing a colour share a chunk.
**"Reaches" is §9's walk with more than one seed, over §9's graph** — the colouring adds a lattice,
not a second graph. Declaration granularity is proven in four whole-program compilers and Closure's
four safety guards for it are vacuous in a pure language (report 12 §3.2).

Mechanically it is §9's pass run once per entry and transposed: `Reach.run` already returns two
bitsets per module over input-derived node identities (`src/js/Reach.zig:103-123`), so node *n*'s
colour is the `|E|`-bit vector of which runs marked it, and **§9's liveness is the OR of those bits**
— one machine, both answers, no second walk. Colours are **interned**: dart2js measured 401 deferred
imports producing 2.9 million import-sets and a five-gigabyte heap without it, and GWT and Rollup
found the same late. At `|E| ≤ 64` a `u64` key into a hash map is `ImportSetLattice` at a thousandth
of the code; the trie is what is needed past that, and the cost of the walks is `|E| × O(nodes)`
against a pass §9 measures in microseconds.

**Every colour containing the main entry IS the main chunk.** dart2js's rule and its reason, quoted
in report 12 §3.1: code reachable from `main` is loaded "possibly synchronously", so splitting it out
buys a chunk that is always fetched. One consequence is worth stating because it removes a whole
class of bug: **the main chunk has no outgoing cross-chunk edge.**

**The chunk graph is a DAG by construction.** If `d → e` then every entry reaching `d` reaches `e`,
so `colour(e) ⊇ colour(d)` and a chunk imports only from chunks whose colour is a strict superset.
Rollup's `CIRCULAR_CHUNK`, Scala.js's `maxExcludedHopCount` and its two-of-three "(unproven)" lemmas
(report 12 §3.3) are all repairing a property the colour order gives here for free.

### The merge

A merge pass follows, budgeted by compression rather than by request count: four chunks cost about
6.6% of compressed bytes and sixteen about 18% before any chunk has saved anything (report 12 §2.6).

**Folding a chunk is promoting its entry, never moving its declarations.** Moving them breaks the DAG
property, because relocated code still references colours the destination does not contain and the
repair cascades — which is precisely why *"every fixup demotes the atom to leftovers"* in GWT. So: an
entry whose chunk does not repay a split is **added to the main entry's seed set and the colouring is
re-run**, to a fixpoint, candidates considered in canonical entry order. That is dart2js's
`ImportSetTransition` (report 12 §4.2) used as the merge mechanism, and it cannot produce a cycle.

**The threshold is provisional and says so.** A candidate chunk is kept iff its private content is at
least **4 096 raw bytes and 5% of the program's raw bytes**. Both numbers are inferred from report
12 §2.6's table and dart2js's 1 080-byte empty part, not measured here: report 12's open question 2
— *"the biggest unquantified risk in the chunking plan"* — is that nobody has measured what
declaration-granular colouring produces, and there is still no beni program large enough to say.
Re-derive from `bench/size.mjs` on the first one that is.

### Assembly, and what a chunk file contains

Lowering does not change. A module is lowered to `JsIr` exactly as today and a chunk is assembled
from the result: `JsIr.body` is *"the `import`s first, then one declaration per emitted value, then
one `export`"* (`src/js/JsIr.zig:57-62`), and `import_stmt` and `export_stmt` are their own tags
(`:117`, `:119`), so the assembler **drops them and writes its own**. `Print.print` gains an entry
point that prints a given list of statements into a caller's buffer; it prints `ir.body` today
(`src/js/Print.zig:73-78`).

- **Order within a chunk is module-topological, then `emissionOrder`.** In separate files ESM orders
  the modules; in one file nothing does, and a `const` read before its initialiser is a temporal-dead
  zone `ReferenceError` at load — the failure §9's own `run/` fixtures exist to catch. The module
  graph is acyclic and a cross-module reference only exists along an import edge, so the two orders
  compose. Emission order is otherwise unchanged: report 12 §2.1 measures up to 7% of compressed
  bytes for keeping related declarations adjacent, and §9's namer already spent that.
- **Nothing is renamed by chunk assignment, and that is the whole reason this is cheap.** §9's namer
  puts every name that can cross a file in one whole-program namespace, assigned before any chunk
  exists, so a declaration's name does not depend on where it lands. Rollup pays `deconflictChunk.ts`
  (266 lines) for this and Elm's LCI-plus-renaming is what report 12 §3.3 identifies as *"Elm's actual
  blocker"*. Confirmed on today's dev output too, where names are `Module$name` and already unique.
- **Cross-chunk bindings are synthesised by the assigner, inside the pass.** Closure is the only
  other system doing declaration-granular chunking with an ES-module mode and the combination is
  broken there because it relocates declarations without emitting the bindings
  (closure-compiler#4264, open); esbuild's `computeCrossChunkDependencies` is the model. By the DAG
  property, every such binding is a static `import` from a less-shared chunk into a more-shared one.

### Where everything else goes

| Thing | Chunk | Why |
|---|---|---|
| the main chunk | **`out/main.mjs`**, with the platform's `run(main)` call last | it is already the file `Emit.emitEntry` writes (`src/js/Emit.zig:840-858`), so the artifact path does not move |
| a colour that is one entry | `out/chunk/<Module>.<name>.mjs` | input-derived and readable: it names the declaration the author marked |
| a colour of two or more | `out/chunk/shared.<i>.mjs`, `i` the colour's index in canonical colour order | input-derived; **no content hash**, so a golden is stable and rule 5 is met by construction |
| a derived `eq` / `compare` | coloured like any other node (`Reach.Kind.derived`) | §9 already makes it a node |
| a `$$order` table | its `compare`'s chunk | *"lives and dies with its `compare`"* (§9); not a node |
| `eq$prim`, `compare$prim`, `compare$char` | emitted per chunk that wants one | discovered by `Lowerer.needs` during lowering, not nodes (§9); three small functions, and duplicating beats a cross-chunk edge |
| an eta-expanded evidence closure | the chunk of the declaration whose site built it | not a node; *"an eta-expansion is built from a site's targets, and the targets are the edges"* (§9) |
| a `*.foreign.mjs` sibling | **its own file, unchunked**, at today's path; every chunk using one of its exports imports it | a sibling is copied whole and never parsed (`boundary.md` §4). ESM evaluates a module once, so duplicate imports cost specifiers and nothing else. Measured cost of not folding siblings into the bundle: 1 215 brotli bytes on `run/Dictionaries`, where the seven siblings are **54% of compressed output** — left on the table deliberately, because separating two siblings' scopes needs a JavaScript parser |
| `platform/runtime.foreign.mjs` | its own file, imported by the main chunk | *"copied whole, so it needs no root of its own"* (§9) |
| a `--library` build | **one chunk** | a library's callers are not in the build, so there is no entry set to colour by; §9 already measures that elimination barely shrinks a library |

### Determinism, M4 and M5

**Determinism needs no new machinery.** Entry order, node identity, colour order and chunk names are
all functions of sorted paths and source order (CLAUDE.md rule 5), and the colouring's output is a
*set*. `--jobs=1` against `--jobs=8` covers it exactly as it covers §9, with `--release` in the
matrix.

**M4 and chunking never meet.** Chunking is release-only and release is not the 15 ms warm path, so
"one edit rewrites one small file" (`src/js/Emit.zig:6-10`) remains true of the mode that promises
it. The cacheable unit is what §9 says — per-module edge lists, per-module `JsIr` — and a chunk file
is a concatenation of already-lowered statements. What a release build cannot cache is the name
table: §9 promises only that a name is a function of position in `emissionOrder`, so inserting a
declaration shifts every name after it. That is a stated non-guarantee and not a regression.

**M5 needs nothing new either.** §11's *"per-file chunks rebased once at join time"* is chunk
assembly: mappings are recorded at print time and rebased by the chunk's running line offset, one
`.map` per chunk file.

### Measurement, acceptance and fixtures

**`bench/size.mjs` cannot see chunking today and must be changed first.** `measureTree` concatenates
every `.mjs` under `out/` and compresses the concatenation (`bench/size.mjs:255-279`), so its
headline `brotli_bytes` is *already* the idealised single-file number. It gains **`split_brotli_bytes`
— the sum of per-file brotli — and `files`**, and chunking's win is the distance between them
closing. Measured today on dev builds: `run/Dictionaries` is 20 files, 11 908 brotli summed against
9 290 concatenated (**−22.0%**, −26.5% once module headers go); hello world is 5 files, 1 152 against
835 (**−27.5%**). Those are the numbers the single-chunk case has to reach.

Acceptance:

1. **A release build of a single-entry program writes one `.mjs` plus siblings and the runtime**, and
   its `split_brotli_bytes` equals its `brotli_bytes`.
2. **Every `run/` fixture passes under `--release` with no `.expected` change**, which §9's release
   testing already runs; a chunked build is a third pass over the same corpus, not a new one.
3. **Every `emit/` and dev golden is byte-identical**: chunking is release-only.
4. **The determinism test is green** at `--jobs=1` and `--jobs=8`, twice each, byte-compared, with
   `--release` in the matrix.
5. **Emit throughput stays above §13's 5 MB/s.** Assembly is a copy per statement and an interning
   pass over `|E| × nodes` bits; what would breach it is a fixpoint per declaration, and none is
   specified.

Fixtures, and the failure each one is about. `emit/release/ChunkSingleFile` — one file, no `import`
of a generated module, sibling imports hoisted, `run(main)` last. `emit/release/ChunkOrder` — a
three-module diamond that throws a temporal-dead-zone `ReferenceError` at load if assembly order is
not module-topological; it is `run/`-shaped rather than golden-shaped for the reason §12 gives.
`run/ChunkCrossBinding` and a two-entry `run/` project prove that a shared chunk is imported by both
entries and that both print — **PENDING the multi-entry decision**, which is what gives the colouring
a second seed at all; until then every fixture here exercises the one-colour case, and a pass whose
only test is the degenerate case is a pass that will be wrong the first time it has two.

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

A third arrives with §9's release optimiser, and it is the same mechanism a third time:
**`emit/release/` builds with `--release`**, for shape claims about names, whitespace and inlining.
The behaviour half is bigger and is stated there rather than here — **the whole `run/` corpus is
built and run a second time under `--release`**, not a marked subset, because the failure mode of a
minifier is a wrong answer in a program nobody thought to mark. Measured cost: about 7 seconds of
wall clock, +11% of `zig build test-blackbox`. §9's *Testing* has the fixture list and the number.

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
