# Checker implementation contract (M2)

**Status:** normative for M2. [`fast-compiler.md`](fast-compiler.md) §7 says *why* the checker is
shaped this way and §3.1 what it must not do; [`language.md`](language.md) §5–§8 and Appendix A
say what names and forms reach it; [`frontend.md`](frontend.md) is the contract it extends
(same CLI, same corpus discipline, same data rules). This document says what the code looks
like. The four decisions that gated M2 are settled in `fast-compiler.md` §3.1: annotations are
optional, primitives are `foreign` declarations in an embedded core package, the language is
pure with one arrow, and a project is one root plus core with package-qualified module identity.

M2 ends when `beni check` type-checks a multi-module project against core, reports Elm-quality
type errors, measures above the §2 throughput target, and the missing-argument diagnostic has
its fixture suite — the condition on which §9.3 kept currying.

## 1. Scope

In: the module graph and cycle detection; the core package (source, embedded); cross-module
name resolution against interfaces; type inference (constrain → solve); the interface record;
the ad-hoc obligations of §3.1 (`number`, `appendable`, equatable, interpolatable); `?` typing;
pattern exhaustiveness and redundancy; every diagnostic in §8; the `check` corpus kinds; a
type-correct synthetic corpus for measurement.

Out: codegen, the runtime, `main`'s type (a platform fact, M3), the JavaScript half of `foreign`
(M3), caching of anything (M4), the daemon (M4).

## 2. CLI surface (additions to `frontend.md` §1)

```
beni check [options] <path>...           now: parse, lower, resolve, type-check every module
beni dump --stage=interface <file>       the module's interface as text (§7)
beni dump --stage=types <file>           every top-level declaration with its inferred scheme,
                                         and every local binding with its type, as text
```

| Flag | Meaning | Default |
|---|---|---|
| `--core-root=<dir>` | use this directory as the core package instead of the embedded one; for developing core | embedded |

`check` on a directory is the project: every `.beni` under it is a module of the package
`app`; core is the package `core`. **A source file at a core module's path is that core
module** — the bytes on disk win and the package stays `core`, so `beni check core` compiles the
library as itself with no flag. `core/` is therefore a reserved directory name at the source
root. Imports resolve in `app` first, then `core`. A module of
`app` named like a core module shadows it for the whole project — no diagnostic, same as a
top-level name shadowing a prelude name. Exit codes and streams are unchanged.

## 3. Repository layout (additions)

```
core/                       the core package, in beni (language.md §5.4)
  Basics.beni  List.beni  Maybe.beni  Result.beni  String.beni  Char.beni  Debug.beni
  Dict.beni  Set.beni      (ordinary beni over a comparator-taking core; §3.1 of the design)
src/
  resolve/
    Graph.zig               module graph: index by (package, module symbol), edges, topo order
    Resolve.zig             import checking against interfaces; produces the per-module Env
    Interface.zig           the flat interface record (§7) and its builder
  check/
    TypeStore.zig           descriptors, union-find, levels, undo journal (§5)
    Constrain.zig           Bir → constraint tree per binding group (§6.1)
    Solve.zig               the solver: unify, generalise, instantiate, obligations (§6.2–6.4)
    Exhaustive.zig          pattern usefulness (§6.6)
    Render.zig              type → text for diagnostics and dumps (§8.2)
    Diagnostics.zig         the M2 items and their prose
  dump/interface.zig  dump/types.zig
tests/corpus/
  check/good/<Name>.beni + <Name>.iface        single module, checks clean; interface golden
  check/good/<Name>/ (directory) + _expected.iface   multi-module project; golden is the
                                               concatenated interfaces of every module, in path order
  check/bad/<Name>.beni + .diag  (and directories with _expected.diag)
  check/args/<Name>.beni + .diag               the missing-argument suite (§8.3): its own kind
                                               so its size and pass rate are visible on their own
```

Core is embedded into the binary with `@embedFile` from `build.zig` (one anonymous import per
file, the list generated from the directory at build time), and parsed on every cold start
until M4 caches it. `--core-root` reads the directory instead.

## 4. The module graph and resolution

1. **Enumerate** app modules (existing) and core modules (embedded). A module's identity is
   `(package, module name)`; the `SourceStore` gains a `package` column. Module names are
   interned symbols.
2. **Lower** every module per file on the workers (existing). Each Bir's import table names
   modules by symbol.
3. **Build the graph** serially: for each module, for each explicit import, look up
   `(app, name)` then `(core, name)`. Missing → `unknown_module` at the import. A **prelude row
   is an edge only when the module actually resolves a name through it** — lowering records that
   in `refs`, so the information is already there. Giving every file all seven prelude rows
   unconditionally makes the standard library cyclic with itself before either module is read
   (`Basics → List → Basics`), which is why the edge is conditional; an explicit `import` is
   always an edge, whether or not anything uses it.

   **The prelude always targets package `core`**, never an app module of the same name. The
   prelude is a constant inside the compiler (`language.md` Appendix A), so an app module called
   `Basics.beni` shadows core's `Basics` for *explicit* imports only and leaves `Int`, `True` and
   the rest resolving as always. Without this rule a user file with an unlucky name silently
   disables the whole prelude. Import cycles → `import_cycle` reported once per cycle on the lexically
   first module of the cycle, naming the whole cycle in order; the modules of a cycle are
   marked poisoned: their declarations get `error` types and no further diagnostics.
   A module resolves against **itself** like any other: the operators of `language.md` §6.5
   desugar to core functions, so `core/Basics.beni`'s own `negate` contains a reference to
   `Basics.sub`. Such a self-reference resolves to the module's own declaration (`top`, not an
   import), contributes no graph edge, and is never an `import_cycle`. `Resolve` rewrites it
   before anything else looks at the reference, so no later phase sees a module importing
   itself.

   `::` desugars to `List.cons` and `++` to `Basics.append`, matching Elm; every other operator
   maps to `Basics`. Lowering emits the home module per operator rather than assuming `Basics`.

4. **Topological order**, stable (ties by `(package, path)`), gives the check order. Modules
   whose imports are all checked are checked in parallel — one worker per module, a bounded
   pool, the DAG scheduling of `fast-compiler.md` §10 — with the interface of every dependency
   immutable by construction once produced. M2 may ship the serial order first and add DAG
   parallelism last, but the data must be laid out for it from the start: a module's check
   reads only its own Bir, the interfaces of its imports, and the `TypeStore` it owns.

   M2c's scheduler (`check/Check.zig`'s `Driver`) is a ready queue over that order: a module
   is ready when every dependency of it that comes EARLIER in the order has finished, results
   land in the slot of a module index assigned before any thread started, diagnostics are
   collected per module and concatenated in the graph's order afterwards, and the counters are
   a commutative sum — so nothing is keyed by completion (§10's rule). **A project with an
   import cycle runs serially**: a cycle has no topological order, so a member could read a
   co-member's interface while it is being written, which is a data race and not merely a
   wrong answer. The members are poisoned and report nothing anyway (§4.3), so the fallback
   costs nothing worth a second scheduling rule. Every worker is spawned with an explicit
   64 MiB stack: constraint generation walks an expression tree and the parser will hand it
   one `Parse.max_depth` levels deep, which does not fit in a default thread stack.
5. **Resolve** each module's references against the interfaces: `import_value(M, x)` must be a
   `pub` value of `M` (`unknown_import_name` / `private_name`), `import_ctor(M, C)` a
   constructor of a non-opaque `pub` type (`opaque_constructor` when the type is `pub opaque`),
   `import_type`/`type_qualified` a `pub` type or alias, `qualified` likewise. The resolved
   target is `(module index, decl index)` or `(module index, ctor index)` — dense ids into the
   interface tables, so the checker never looks a name up again.

## 5. The type store

Elm's `Type.Variable` + Roc's `types/store.zig`, in the design's data rules:

```zig
pub const Var = enum(u32) { _ };                         // a union-find node
pub const Descriptor = struct {                          // MultiArrayList column set
    parent: Var,          // union-find; self when a root
    rank: u32,            // Rémy level; `generalised` = 0 sentinel after generalisation
    content: Content,     // see below; meaningful on roots only
    mark: Mark,           // instantiation memo / occurs-check colour; cleared after each use
    copy: Var.Optional,   // the sharing-preserving instantiation memo (design §7 #4)
};
pub const Content = union(enum) {            // tag + u32 payload into `extra` where needed
    flex: Flex,                              // { name: Symbol.Optional, kind: Kind, equatable: bool }
    rigid: Rigid,                            // from an annotation: { name: Symbol, kind, equatable }
    structure: Structure,                    // fn | app(TypeId, args) | tuple(args) | record(fields, ext) | unit
    alias: Alias,                            // { alias: TypeId, args, actual: Var } — interned, never expanded (§3.1)
    err,                                     // poisoned: unifies with anything, silently
};
pub const Kind = enum(u8) { any, number, appendable };   // the closed set of §3.1
pub const TypeId = enum(u32) { _ };                      // (module, decl) of a type or alias, dense
```

- **Union-find with path compression and union by rank of the tree**, separate from the
  Rémy `rank`. `find` is the only place that walks; every other operation works on roots.
- **The undo journal** (Roc's `SlotUndo`/`DescUndo`): every mutation of `parent`, `rank`,
  `content` pushes the old value; `mark`/`commit` brackets a speculative unification (used for
  error rendering's "which of these two did you mean" and for `try`'s shape choice, §6.5).
  Nothing else in M2 speculates; the journal exists because retrofitting it is the rework
  `fast-compiler.md` §13 warns about.
- **Structures live in `extra`**: `fn` is two vars; `app` is a `TypeId` + range of vars;
  `record` is a sorted range of `(field Symbol, Var)` pairs + an extension var (`unit`-like
  `closed` content for closed records); `tuple` a range of vars.
- **Aliases are interned, never expanded**: an `alias` content carries the alias id, its
  argument vars and the `actual` var of its expansion, created once when the alias is
  instantiated; unification looks through to `actual` but error rendering prints the alias
  name. This is the Roc behaviour §3.1 adopts.
- **Type ids are dense**: `TypeId` indexes a session-wide table of `(module, decl)` type
  declarations filled in topological order, so type identity is one integer compare.
- **One `TypeStore` per module being checked**, owned by the worker checking it, arena-backed,
  reset after the interface is extracted. Imported schemes live in interfaces (§7) in a flat
  form and are instantiated into the local store on demand.

## 6. Inference

### 6.1 Constraint generation

One pass over a binding group's Bir producing a constraint tree (Elm's `Type/Constrain`):
`equal(expected, actual, region, category)`, `let(rigid vars, flex vars, header constraints,
body)`, `and`, `pattern` constraints for bindings, and the **obligations**: `equatable(var,
region)`, `interpolatable(var, region)`, `tuple_index(var, index, region)`, `try(var, enclosing
result var, region)`. Regions are the Bir instruction index; positions are looked up only when
a diagnostic is rendered (design §7, "good messages off the happy path").

Binding groups: top-level values are SCC-decomposed over the module's `refs` (the `top_value`
edges), and the SCC order is the generation order; a `let` is SCC-decomposed over its bindings'
local references (recorded by lowering as part of `let_def`). Only a genuinely mutually
recursive group shares a generalisation (design §7 #5). A declaration with an annotation is
checked against its annotation's rigid scheme and its *annotation* is what dependents see,
which also breaks recursion through annotated names.

What each Bir form generates is Elm's, with the beni-specific rules:

| Bir | Constraint |
|---|---|
| `int` | flex var of kind `number` |
| `float`, `char`, `string`, `interp` | `Float` / `Char` / `String`; `interp` adds `interpolatable(t)` per expression part |
| `call(import_value(Basics, add), [a, b])` etc. | ordinary application of the core function's scheme — the `number` kind comes from Basics' own annotation `add : number -> number -> number`; the checker has no operator table |
| `call(import_value(Basics, eq), [a, b])` | `a = b` plus `equatable(a)`: `eq : a -> a -> Bool` in Basics is annotated with the `equatable` marker (Appendix B) |
| `call(f, args)` | `f = arg1 -> … -> argN -> result`; on mismatch inside a function type, the arity diagnostics of §8.3 |
| `lambda` | fresh vars per parameter pattern, `fn` chain |
| `let` | SCC groups, `let` constraint with generalisation per group |
| `case` / `branch` | scrutinee = every pattern; every body = result; then §6.6 |
| `try(e, target)` | §6.5 |
| `record`, `record_update`, `field_access` | Elm's row rules: access creates `{ ext | field : t }`; update requires the base to have every updated field; literals are closed |
| `tuple_index(e, i)` | `e = (t0, …, ti, ext?)` cannot be expressed with a row — so an obligation `tuple_index(e, i)` discharged post-solve: `e` must then be a tuple of arity > i (`tuple_index_out_of_range` / `not_a_tuple`) |
| `type_var` in an annotation | rigid var, scoped to the annotation, implicitly quantified |
| `error` | `err` content |

### 6.2 Solving

Elm's `Type/Solve.hs` on the store above: walk the tree; `equal` calls `unify`; `let`
introduces a new rank, solves the headers, **generalises** by scanning only the pool of
variables allocated at the current rank (design §7 #2) and adjusting ranks of variables that
escaped, then runs the **deferred occurs check** once per generalised binding (design §7 #3:
`infinite_type` at the binding, not inside unification), then the obligations registered at
that rank whose variables are now concrete (§6.4), then solves the body.

`unify(a, b)`: find both roots; equal → done; either `err` → merge silently (design §7, "errors
never stop the build"); flex vs anything → bind, merging kinds by the lattice `any ⊒ number`,
`any ⊒ appendable`, and `number ⊓ appendable = ⊥` (`kind_mismatch`), and OR-ing `equatable`
onto the surviving var (a flex var marked equatable that meets a structure registers an
`equatable(structure)` obligation instead of walking — the walk happens once at discharge);
rigid vs non-identical → `rigid_mismatch`; structure vs structure → same head and arity, then
pairwise, records by Elm's four-way field partition with fresh extension vars; alias vs
anything → through `actual`. On failure both roots are poisoned to `err` after the diagnostic
is recorded, so one mistake yields one message.

Instantiation copies a scheme with the `copy` memo so internal sharing is preserved (design
§7 #4), clearing the memo through a scratch list afterwards.

### 6.3 Generalisation and the ad-hoc kinds

A generalised scheme records, per quantified variable, its kind and equatable flag. That is
the entire mechanism of §3.1: `number` and `appendable` are closed sets tested by a flat
membership check at unification; `equatable` propagates through generalisation exactly as
`number` does, so `member : a -> List a -> Bool` in core is `∀(a: equatable)`, and a call
`member f fs` with `f : Int -> Int` fails at *that* call with `not_equatable` naming the
function type. No dictionary exists at runtime because equality is structural in the emitted
JavaScript; the flag is purely a compile-time check. Nothing else may be added to `Kind`
without revisiting `fast-compiler.md` §3.1.

Unresolved `number` variables at top level stay polymorphic in the scheme (Elm's behaviour);
M3 decides how a literal of type `number` is emitted.

### 6.4 Obligations, discharged post-solve

Each obligation is `(kind, var, region)` in a per-rank list. At generalisation time, for each
obligation whose variable's root is:

- a **structure**: walk it once with a mark as the cycle guard (`equatable`: no `fn` anywhere,
  every `app`'s type must be equatable — foreign types declare it, see Appendix B — and
  records/tuples recurse; `interpolatable`: exactly `String | Int | Float | Bool | Char`, no
  recursion; `tuple_index`: a tuple of sufficient arity) and report on failure;
- a **flex var** being generalised: fold the obligation into the variable's flags (equatable)
  or report (`interpolatable` and `tuple_index` cannot be deferred to callers:
  `ambiguous_interpolation` / `ambiguous_tuple` naming the annotation that would fix it);
- a **rigid var**: report unless the annotation declared the flag (Appendix B).

### 6.5 `?`

`try(e, target)` where the enclosing function's declared or inferred result type is `r`:
speculatively unify `e` with `Result x a` and `r` with `Result x b` (journal mark); if that
fails, roll back and try `Maybe a` / `Maybe b`; if both fail, `try_shape` naming what `e` is.
The instruction's type is `a`. The enclosing result is the `let_def` or declaration named by
`target`, whose result var is the one after peeling its parameter count from its type. No
conversion between the two shapes and no `From` (language.md §6.6).

### 6.6 Exhaustiveness

After a module is solved, every `case` (including the ones `if` lowered to) is checked with
Maranget's usefulness algorithm over the *solved* types: constructors of an ADT come from its
type declaration (through the interface for imported types), literals are infinite (`_`
required), lists are `[]`/`::`, tuples and records are products. Missing patterns →
`missing_patterns` at the `case` with up to three example patterns rendered; a branch that can
never match → `redundant_pattern` at the branch. `let` patterns are irrefutable by grammar.
This runs only on modules with no type errors in that declaration, so it never sees `err`.

What M2c built (`check/Exhaustive.zig`), and where it reads this paragraph more narrowly than
it is written:

- The gate is per **declaration**, not per module: a module with one bad function still has
  good ones worth checking.
- Nothing reads a solved `Var`. The only question the algorithm asks about a column is "what is
  the full set of alternatives here?", and it asks it only of a column that already contains a
  constructor pattern — from which the union is known exactly, through the declaring `type`'s
  constructor list (its own module's Bir, or an imported module's interface). A column of
  wildcards is exhaustive whatever its type is and a column of literals is not, so the
  scrutinee's type changes no answer, and reading it would mean instantiating every
  constructor's argument types at every nested position for nothing. The solved types are the
  *precondition* — they are why a column is one type's constructors — and that is what the
  per-declaration gate buys.
- An opaque imported type needs no special case: its constructors cannot be named by the
  importer at all, so the only patterns it can write are variables and wildcards, and those are
  exhaustive.
- The search stops at three counterexamples, and — as in Elm — when some constructors of the
  first column are missing it names those and does not also recurse into the ones that are
  present. So a `case` can need two rounds to be made exhaustive. That is Elm's behaviour and
  the message is honest about being a sample ("Missing possibilities include:").
- **The algorithm is exponential in the worst case** (Maranget §3.3), so every recursive step
  and every specialised row spends from a fixed budget and a `case` that exhausts it reports
  NOTHING. A missed warning is a far smaller bug than a compiler that does not terminate.
  `Session.Options.pattern_budget` sets it, so the bound has a test rather than an absence of
  one.

## 7. The interface record

Per module, flat, index-based, session-owned, immutable once built — designed so M4 can hash
it and map it from disk unchanged (`fast-compiler.md` §8.1, §8.3):

```
Interface
  values:   [] { name: Symbol, scheme: SchemeIndex, is_foreign: bool }        sorted by name
  types:    [] { name: Symbol, arity: u8, kind: adt|alias|foreign, opaque: bool,
                 ctors: range into ctors, alias_body: TermIndex?, equatable: bool }  sorted by name
  ctors:    [] { name: Symbol, type: index into types, arg_terms: range }
  schemes:  [] { quantified: range of (kind, equatable), body: TermIndex }
  terms:    MultiArrayList { tag, lhs, rhs }   the flat type term language: var(i), fn, app(TypeId, range),
                                               tuple(range), record(range, ext), unit, alias(TypeId, range)
  extra:    []u32
  symbols:  []Symbol                            remapped like Bir's
```

`dump --stage=interface` prints it: one line per value `name : scheme`, one per type with its
constructors or `opaque`, types rendered by `Render.zig` in the same form diagnostics use, so
the goldens double as documentation. The interface of a module with type errors still exists:
erroneous declarations appear with `<error>` so dependents check against the rest.

## 8. Diagnostics

Every code below joins the catalogue in `language.md` §10 (append there first, then in
`diagnostic.Code`), with a `bad/` fixture each. Messages follow Elm's `Reporting/Error/Type.hs`
in register and structure: the title, what the compiler was looking at, the two types laid out
one under the other with the differing part highlighted, then a hint when there is a known one
(Elm's hints for `number` vs `String`, missing `toFloat`, function equality, comparison of
strings needing `String.compare`, and record field typos by edit distance).

### 8.1 Codes

```
unknown_module  import_cycle  unknown_import_name  private_name  opaque_constructor
wrong_type_arity  recursive_alias  duplicate_module
type_mismatch  rigid_mismatch  infinite_type  kind_mismatch
too_few_args  too_many_args  not_a_function
missing_field  unknown_field  record_not_closed
not_equatable  not_interpolatable  ambiguous_interpolation  ambiguous_tuple
tuple_index_out_of_range  not_a_tuple  try_shape
missing_patterns  redundant_pattern
```

`wrong_type_arity` covers both under- and over-application of a type constructor: there are no
higher-kinded types, every type constructor is fully applied (language.md gains this line).
`recursive_alias` is Elm's rule: an alias may not mention itself, directly or through other
aliases. `duplicate_module` is two files mapping to one module name across packages other than
the app-over-core shadowing rule (cannot happen with one root; exists for M4).

### 8.2 Rendering types

`Render.zig` prints a type from a store or an interface term: variables named `a`, `b`, … in
order of first appearance per diagnostic (fresh names allocated only when rendering, design
§7), kinds as `number`/`appendable`, aliases by name, records as `{ a : Int, b : String }` with
`{ r | … }` for open ones, functions with the minimal parentheses. The same renderer produces
`dump --stage=types` and `--stage=interface`, so every diagnostic's type text is corpus-tested
through the dumps.

### 8.3 The missing-argument suite

`fast-compiler.md` §9.3 keeps currying on the condition that a localised `TOO FEW ARGS`
diagnostic lands convincingly. The rule: when unifying the callee's type with the call's
`arg1 -> … -> argN -> result` shape, a mismatch where the callee has more arrows than the call
supplied and the *result* was expected to be a non-function is `too_few_args` at the call,
naming the function, how many arguments it takes and how many it got, and the type of the
missing ones; the mirror is `too_many_args`; a non-function callee is `not_a_function`. These
fire before the generic `type_mismatch` and suppress it. `tests/corpus/check/args/` holds at
least thirty fixtures taken from real mistakes (forgetting `model` in an `update` call, a
pipeline missing its subject, `List.map` with one argument passed on, a partially applied
constructor where a value was expected, a lambda with too few parameters passed to `foldl`),
each asserting the whole diagnostic. If fewer than 90% of those read as *the* right message on
review, the currying decision is revisited before M3 (design §9.3).

## 9. Measurement

- `bench` gains a `check` phase: whole-project check throughput (LOC/s) on the generated
  corpus, which `bench/gen.zig` must now produce **type-correct** (it emits its own annotations
  and only calls functions it defined or core functions with known types); a type error in the
  generated corpus is a generator bug.
- Target (design §2): > 250k LOC/s cold per core for checking alone; the whole cold pipeline
  for 100k lines under 800 ms including core.
- `--self-profile` gains `resolve`, `check` and `exhaustive` events per module and counters
  `unifications`, `generalisations`, `instantiations`, `obligations` — the numbers M4's
  incrementality tests will assert did *not* move. `check` is split into `constrain` and
  `solve` events, one pair per module, because the constraint/solve separation is the
  architecture (research/02 §1) and a trace that could not tell the halves apart would hide
  which one a regression is in. All five are per module and none is per run: "this module was
  not re-checked" is only visible in a trace that has a row per module. `check` is recorded on
  the worker that took the module, so a trace also shows the DAG schedule of §4.4.

## 10. Milestones

- **M2a — core and resolve.** `core/*.beni` per Appendix B; embedding; `--core-root`; module
  graph; cycles; interfaces with the *skeleton* only (no types yet); `unknown_module`,
  `import_cycle`, `unknown_import_name`, `private_name`, `opaque_constructor`; `dump
  --stage=interface` (names only); corpus `check/good` directories checking clean on names.
- **M2b — the store and single-module inference.** `TypeStore`, `Constrain`, `Solve`,
  generalisation, kinds, obligations, `try`, annotations vs inferred, all §8.1 type codes
  except exhaustiveness; `dump --stage=types`; interfaces with schemes; single-module
  `check/good` + `.iface` goldens; the missing-argument suite's first fixtures.
- **M2c — cross-module and exhaustiveness.** Instantiation from interfaces; DAG-parallel
  checking; `Exhaustive.zig`; multi-module fixtures; the full `check/args` suite and its review.
- **M2d — measurement and review.** Type-correct generator; `check` bench line; profile
  counters; a house-rules review; `fast-compiler.md` §9.3's revisit decision recorded.

## Appendix A — rules added to `language.md` by M2

- Type constructors are fully applied; there are no higher-kinded types (`wrong_type_arity`).
- A type alias may not refer to itself, directly or through other aliases (`recursive_alias`).
- An annotation's type variable may be marked for equality with the `equatable` prefix, in
  core only (Appendix B); user annotations obtain the mark by inference, never by spelling.
  The prefix marks the **variable at its first occurrence**, not an argument: `eq : equatable a
  -> a -> Bool` is a function of two arguments, and `pub equatable foreign type List a`
  means "equatable when every parameter is". The parser accepts the prefix only before a type
  variable's first occurrence in an annotation, and only before `foreign type` in a declaration
  (`equatable_outside_core` elsewhere).

## Appendix B — the core package

Written in beni, `pub` per declaration, doc comments on everything public. The signatures are
Elm 0.19's `elm/core` minus `comparable`, `compappend` and the effect modules, plus the
explicit-ordering replacements (`fast-compiler.md` §3.1):

- `Basics`: `foreign type Int`, `Float`, `Char`, `String` (declared here so the prelude's types
  have one home); `type Bool = True | False`; `type Order = LT | EQ | GT`; `type Never =
  JustOneMore Never`; the arithmetic, comparison and logic foreigns with `number` annotations
  (`add : number -> number -> number`, `lt : number -> number -> Bool`, …); `eq : equatable a
  -> a -> Bool`; `append : appendable -> appendable -> appendable`; `compare : number ->
  number -> Order`; `max`, `min`, `clamp` on `number`; the numeric functions; `identity`,
  `always`, `never`, `not`, `xor`, `modBy`, `remainderBy`, `negate`, `abs`, `toFloat`, `round`,
  `floor`, `ceiling`, `truncate`, `isNaN`, `isInfinite`, `e`, `pi`, trigonometry.
- `List`: `foreign type List a`; `foreign` only for `cons`, `head`/`tail`-free primitives and
  `foldr`/`foldl` if the representation needs it — everything else in beni; `sortWith : (a ->
  a -> Order) -> List a -> List a`, `sortBy : (a -> number) -> List a -> List a`, `sort :
  List number -> List number`; `member : equatable a -> List a -> Bool`.
- `Maybe`, `Result`: entirely beni.
- `String`: `foreign` primitives (`length`, `slice`, `fromInt`, `toInt`, `fromFloat`,
  `toFloat`, `fromChar`, `toList`, `fromList`, `append`, `compare : String -> String ->
  Order`, `toUpper`, `toLower`, …); the rest in beni.
- `Char`: `foreign` classification and conversion.
- `Debug`: `foreign log : String -> a -> a`, `foreign todo : String -> a`, `foreign toString :
  a -> String`.
- `Dict`, `Set`: beni, keyed by an explicit comparator (`Dict.empty : (k -> k -> Order) -> Dict
  k v`) with `Dict.String`/`Dict.Int` modules as sugar, per `fast-compiler.md` §3.1 point 4.

The `equatable` annotation marker is the only spelling in the language that user code may not
write; the parser accepts it under `--core` only (`equatable_outside_core`, joining §10's
catalogue). Foreign types declare equality by a doc-visible attribute: `foreign type Int`
is equatable; a `foreign type` is equatable only when declared with `equatable` before
`foreign`. `List a` is equatable when `a` is.
