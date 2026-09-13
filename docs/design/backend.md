# Backend implementation contract (M3)

**Status:** normative for M3. [`fast-compiler.md`](fast-compiler.md) §9 says *why* the backend is
shaped this way and §2 what it must measure; [`boundary.md`](boundary.md) says how emitted code
meets JavaScript; [`research/12-js-output-and-chunking.md`](research/12-js-output-and-chunking.md)
is the evidence for every size claim below. This document says what the code looks like.

M3 ends when `beni build` produces JavaScript that runs, the emitted output is measurably close to
what a dedicated minifier would produce, and the share of call sites emitted as direct calls is high
enough to justify keeping currying (§9.3).

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
- **M3c — the optimiser.** Reachability elimination, saturated-call specialisation, local
  dead-binding elimination, renaming, field ambiguation, compact printing. *Acceptance: §9's size
  and throughput numbers, and the direct-call share that decides §9.3.*
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

## 4. Codegen, construct by construct

Representation decisions are §9.4's and are not reopened here. What this section fixes is the
mapping.

| beni | JavaScript |
|---|---|
| top-level value | one `const` per declaration, module-qualified name in dev, short name in release |
| function of *n* parameters | one function expression of arity *n*, plus its arity tag (§6) |
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

## 6. The calling convention

§9.3 keeps currying **on the condition** that saturated calls at statically known arity become
direct calls. That condition is now a deliverable with a number attached.

**M3a found a better scheme than §9.3 specified, and it removes the adapter entirely.** The arity
tag exists so a call site can *ask* a value its arity. Make every function-typed value that is in
flight curried, and the question never arises:

- A call site whose callee's arity is statically known and whose argument count matches emits a
  **direct n-ary call** `f(a, b)`. The declaration graph resolves every top-level reference, so this
  is the overwhelming majority.
- Everything else applies one argument at a time to something that is always curried, with the
  curry wrapper emitted at the site.

So there is **no arity tag and no `A2`/`F2` adapter** — and therefore no runtime library, which
matters beyond size: the only hand-written JavaScript in a build stays core's siblings, and a
codegen helper would have been neither that nor beni. Elm pays roughly 49% on Chrome for routing
saturated calls through its adapter; we pay nothing, because there is no adapter to route through.
Indicative direct-call share on the compiler's own output at M3a: about 87%.

**M3a shipped this and dropped the arity tag**, which the other two bullets turn out not to need.
The tag exists so that a call site can *ask* a value what arity it has, and the only reason to ask
is that some function-typed values are n-ary and some are not. Make them all the same and the
question disappears: **every function-typed value in flight is curried**, and n-ary forms exist only
where the callee is statically known. A saturated call to a known callee is then `f(a, b)` with no
adapter at all; everything else applies one argument at a time to something that is always curried.
The curry wrapper is emitted at the site that needs it — `((x) => (y) => f(x, y))` — so there is no
runtime library, which matters because `boundary.md`'s wall means the only hand-written JavaScript
in a build is core's siblings and a codegen helper would be neither that nor beni.

**M3c measures the share of call sites emitted as direct calls and records it here.** §9.3 says
plainly that if the share is low the currying decision was wrong. The missing-argument diagnostic
already discharged its half of that bargain at 37 of 38; this is the other half. An indicative count
over M3a's own output (core plus a small program, counting `name(` against `)(`): 391 direct calls
against 58 curried applications, so roughly 87%. That is a grep and not the measurement; M3c owns
the real one.

## 7. Pattern matching

Decision trees, Scott and Ramsey's heuristics, compiled to a native `switch` for multi-way tests on
a constructor tag. Single-use branches inline; multi-use branches are shared through a labelled
loop. The checker has already proved exhaustiveness (`checker.md` §6.6), so **the tree needs no
default arm for a well-typed match** and the absence of one is not a latent crash.

## 8. Tail calls

Direct self-recursion lowers to `label: while (true)` with parameters reassigned through temporaries.
**This is mandatory, not an optimisation**: no JavaScript engine reliably provides tail-call
elimination, V8 shipped and reverted it, SpiderMonkey never shipped it. Mutual recursion remains a
real stack frame and ships as a stated limitation (§14 question 5).

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
the first line written**, because dart2js measured 2.9 million import-sets and a five-gigabyte heap
without interning, and both GWT and Rollup found the same late.

A **merge pass** follows, budgeted by compression rather than request count: four chunks cost about
6.6% of compressed bytes and sixteen about 18%, before any chunk has saved anything. A chunk whose
private content does not repay that is folded back.

The assigner **synthesises the cross-chunk `import`/`export` bindings itself**. Closure is the only
system doing declaration-granular chunking with an ES-module mode and the combination is broken
there, because it relocates declarations without emitting the bindings.

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

A bug that changes emitted shape but not behaviour must not fail a `run/` test; a bug that changes
behaviour must. That is the whole point of preferring it.

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
