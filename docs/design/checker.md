# Checker implementation contract (M2)

**Status:** normative for M2. [`fast-compiler.md`](fast-compiler.md) §7 says *why* the checker is
shaped this way and §3.1 what it must not do; [`language.md`](language.md) §5–§8 and Appendix A
say what names and forms reach it; [`frontend.md`](frontend.md) is the contract it extends
(same CLI, same corpus discipline, same data rules). This document says what the code looks
like. The four decisions that gated M2 are settled in `fast-compiler.md` §3.1: annotations are
optional, primitives are `foreign` declarations in an embedded core package, the language is
pure with one arrow, and a project is one root plus core with package-qualified module identity.

M2 ends when `beni check` type-checks a multi-module project against core, reports Elm-quality
type errors, measures above the §2 throughput target, and the arity diagnostics have their
fixture suite (§8.3). The suite was originally the condition on which §9.3 kept currying; §9.3
dropped currying on 2026-09-14 and the suite is re-cut around the arity errors that replace it.

## 1. Scope

In: the module graph and cycle detection; the core package (source, embedded); cross-module
name resolution against interfaces; type inference (constrain → solve); the interface record;
the ad-hoc obligations of §3.1 (`number`, `appendable`, equatable, interpolatable); `?` typing;
pattern exhaustiveness and redundancy; every diagnostic in §8; the `check` corpus kinds; a
type-correct synthetic corpus for measurement.

**Static dispatch, adopted 2026-09-18, is in as well**, and it is the largest single addition this
document has taken: method constraints on a type variable, a method obligation kind beside the four
above, resolution of `x.m a` against the receiver's type, derivation of `eq` and `compare`, the
`where` suffix in the interface record, and the checker→backend dispatch table. Every rule of it is
in [`static-dispatch-spike.md`](static-dispatch-spike.md) §6 and §7, which extend §5, §6.1–§6.4 and
§7 below; each of those sections points back. The detail is not repeated here.

Out: codegen, the runtime, `main`'s type (a platform fact, M3), the JavaScript half of `foreign`
(M3), caching of anything (M4), the daemon (M4).

## 2. CLI surface (additions to `frontend.md` §1)

```
beni check [options] <path>...           now: parse, lower, resolve, type-check every module
beni dump --stage=interface <file>       the module's interface as text (§7)
beni dump --stage=raw <file>             the same interface as the RECORD: term tags and
                                         operands, `extra` words, quantifier blocks, constructor
                                         argument ranges
beni dump --stage=types <file>           every top-level declaration with its inferred scheme,
                                         and every local binding with its type, as text
beni dump --stage=graph <file>           the module graph's edges, one `package:Module ->
                                         package:Module` per line, sorted by the printed line
beni dump --stage=dispatch <file>        the dispatch table: what every method call resolved to,
                                         every declaration's evidence list, every derived function
```

The last two arrived with static dispatch. `--stage=graph` exists because §4's order is a
topological sort of exactly those edges, so a golden over the edges pins the schedule *and* says
why; `--stage=dispatch` is the checker→backend side table of
[`static-dispatch-spike.md`](static-dispatch-spike.md) §7, made an output so it is testable rather
than internal. `--stage=dispatch` takes a directory as well as a file and has a corpus kind of its
own, `tests/corpus/dispatch/` (§3); `--stage=graph` is asserted by a black-box scenario over
`check/good/TypeOwnerEdges/_expected.graph`, at `--jobs=1` and `--jobs=8`.
→ `static-dispatch-spike.md` §6.8, §7.3.

`--stage=raw` exists for one assertion and is not meant to be read for pleasure. Both other
views of an interface go through `check/Render.zig`, which re-sorts a record's fields by name
text — so neither can see whether the BYTES of `terms`, `extra` and the quantifier blocks
depend on which worker interned which file. `fast-compiler.md` §8.1 has M4 hashing exactly
those bytes, so "identical at every `--jobs`" has to be assertable about them and not about a
printer that would hide a difference. Like `--stage=interface` it takes a directory as well as
a file.

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
  Dict.beni  Set.beni      (ordinary beni; `where k.compare` since 2026-09-18, Appendix B)
src/
  resolve/
    Graph.zig               module graph: index by (package, module symbol), edges, topo order
    Resolve.zig             import checking against interfaces; produces the per-module Env
    Interface.zig           the flat interface record (§7) and its builder
  check/
    TypeStore.zig           descriptors, union-find, levels, undo journal (§5)
    Constrain.zig           Bir → constraint tree per binding group (§6.1)
    Solve.zig               the solver: unify, generalise, instantiate, obligations (§6.2–6.4)
    Dispatch.zig            the checker→backend dispatch table (static-dispatch-spike.md §7)
    Exhaustive.zig          pattern usefulness (§6.6)
    Render.zig              type → text for diagnostics and dumps (§8.2)
    Diagnostics.zig         the M2 items and their prose
  dump/interface.zig  dump/types.zig  dump/graph.zig  dump/dispatch.zig
tests/corpus/
  dispatch/<Name>.beni + <Name>.dispatch       (or a directory) — `dump --stage=dispatch`
                                               golden; its own kind, per static dispatch
  check/good/<Name>.beni + <Name>.iface        single module, checks clean; interface golden
  check/good/<Name>/ (directory) + _expected.iface   multi-module project; golden is the
                                               concatenated interfaces of every module, in path order
  check/bad/<Name>.beni + .diag  (and directories with _expected.diag)
  check/args/<Name>.beni + .diag               the missing-argument suite (§8.3): its own kind
                                               so its size and pass rate are visible on their own
  check/depth/<Name>Ok.beni                   the depth sweep: one level UNDER a guard, checks clean
  check/depth/<Name>Deep.beni + .diag         one level OVER it, and says so
```

The depth sweep is a kind of its own because its assertion is a PAIR rather than a file. Every
guard that can stop the checker reading a type gets a fixture one level under it, which must
check clean, and one level over it, which must produce a diagnostic; the walker enforces the
pairing by name, so a `…Ok` with a golden or a `…Deep` without one fails. It exists because
every one of those guards used to poison a type and report nothing — see §5 — and a guard is
otherwise asserted only by its absence. `tests/corpus/check/depth/generate.sh` rebuilds the
fixtures and records each guard's measured boundary.

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
   that desugars to a call maps to `Basics`. Lowering emits the home module per operator rather
   than assuming `Basics`. **The six comparison operators desugar to no call at all** since static
   dispatch: they are method calls whose target the solver picks, so they name no module and
   contribute no import edge. What does contribute one is a *minted* type — a literal, or an `e?` —
   whose owning core module becomes an edge of the module that wrote it, which is a fourth edge
   source beside explicit imports, prelude rows and self-references.
   → [`static-dispatch-spike.md`](static-dispatch-spike.md) §3.1, §6.8.

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

**Static dispatch adds a constraint set to a variable, and nothing to `Kind`.** A `flex` or `rigid`
carries, beside its kind and its equatable flag, a set of **method constraints** — "whatever type
ends up here has a method of this name at this type" — one per `(variable, method name)`, each
recorded with the origin that raised it. `Kind` is untouched and still the closed set of §3.1, which
is what §6.3's "nothing else may be added to `Kind`" was protecting. The store gains the set, its
merge rule and the speculator the `?` journal already provides. → `static-dispatch-spike.md` §6.1.

- **Union-find with path compression and union by rank of the tree**, separate from the
  Rémy `rank`. `find` is the only place that walks; every other operation works on roots.
- **The undo journal** (Roc's `SlotUndo`/`DescUndo`): every mutation of `parent`, `rank`,
  `content` pushes the old value; `mark`/`commit` brackets a speculative unification (used for
  error rendering's "which of these two did you mean" and for `try`'s shape choice, §6.5).
  Nothing else in M2 speculates; the journal exists because retrofitting it is the rework
  `fast-compiler.md` §13 warns about.
- **Structures live in `extra`**: `fn` is a **range of parameter vars plus a result var**
  (`language.md` §6.7 — function types are n-ary and unify only at equal arity); `app` is a
  `TypeId` + range of vars;
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
- **A guard that poisons must report first.** Reading a written type is bounded
  (`Types.Builder.max_depth`, 512 levels) and so is writing a solved one into the interface
  (`Schemes.Writer.max_depth`), because neither walk belongs on the C stack unbounded. Past the
  bound the result is an `err` — and an `err` unifies with anything, so a declaration truncated
  in silence becomes a hole and a caller's mistake against it compiles clean. `fast-compiler.md`
  §5's "errors never stop the build" means a poisoned variable **after** a message, never
  instead of one, and the message is `nesting_too_deep`: the same code the parser uses, because
  it is the same problem and the same fix. M2 shipped these two guards silent; the band between
  512 and the parser's own `Parse.max_depth` (4096) was eight times wide, and a 511-deep
  annotation type-checked to `<error>` with no output at all.

  Every other guard in the checker either reports or carries a written argument for why silence
  is right there, at the guard itself. The two that matter:

  - `Constrain`'s and `Solve`'s recursion guards are written as `Parse.max_depth + 104`, not as
    a constant. A file the parser accepted cannot reach them and a file that could was reported
    before the checker ran — deriving the number from the parser's is what keeps that argument
    from rotting.
  - `Exhaustive`'s depth and work budgets report **nothing** on purpose (§6.6): a half-searched
    pattern matrix can no more prove a branch redundant than prove one missing.

  `tests/corpus/check/depth/` sweeps all of them, one fixture per guard at guard − 1 and
  guard + 1 (§3).

## 6. Inference

### 6.1 Constraint generation

One pass over a binding group's Bir producing a constraint tree (Elm's `Type/Constrain`):
`equal(expected, actual, region, category)`, `let(rigid vars, flex vars, header constraints,
body)`, `and`, `pattern` constraints for bindings, and the **obligations**: `equatable(var,
region)`, `interpolatable(var, region)`, `tuple_index(var, index, region)`, `try(var, enclosing
result var, region)` — and, since static dispatch, a **method** obligation, the one new kind
(→ [`static-dispatch-spike.md`](static-dispatch-spike.md) §6.2, §6.3). It differs from the four
above in one respect that reaches §6.4: discharging it can register further obligations, so the
discharge loop's budget is reachable by input rather than only by a compiler bug. Regions are the Bir instruction index; positions are looked up only when
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
| `call(import_value(Basics, add), [a, b])` etc. | ordinary application of the core function's scheme — the `number` kind comes from Basics' own annotation `add : number, number -> number`; the checker has no operator table |
| `call(import_value(Basics, eq), [a, b])` | an explicit call of `Basics.eq` by name, which still exists: `a = b` plus `equatable(a)`, from the `equatable` marker on its annotation (Appendix B). **This is no longer what `a == b` lowers to** — see `method_call` below |
| `method_call(recv, m, args, origin)` | a method constraint `m : <the type at this use>` on the receiver's variable, and the instruction typed by the constraint's result. When `origin` names an operator, the receiver and the argument are unified and the result pinned first, so `==` and `<` are tighter than a hand-written dot-call. Resolution is deferred to the solver (§6.2) |
| `type_dispatch(v, m, args)` | the same, against the rigid annotation variable `v` and its declared `where` constraint |
| `call(f, args)` | `f = (arg1, …, argN) -> result` — **one n-ary function type with exactly N parameters**; an arity difference is §8.3's diagnostics and never a partial application |
| `lambda` | fresh vars per parameter pattern, one n-ary function type |
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

**Function types carry their parameter count and unify only at equal arity** (`language.md`
§6.7). `Structure.Func` is a parameter range plus a result rather than a param/result pair, so an
arity difference is an ordinary structure mismatch inside `unify`, caught by the same "same head
and arity" test as a type constructor's. What makes it a *good* message rather than a
`type_mismatch` is the call site: constraint generation knows it built that function type from an
application, so the mismatch is reported as §8.3's `too_few_args` or `too_many_args`. Everywhere
else — a function value assigned to a differently-shaped parameter, say — it stays a
`type_mismatch`, because there is no call to name.

Instantiation copies a scheme with the `copy` memo so internal sharing is preserved (design
§7 #4), clearing the memo through a scratch list afterwards.

**Two additions from static dispatch, both inside `unify`'s flex case.** Merging two variables
merges their constraint sets, with at most one constraint per `(variable, method name)` and a
`method_constraint_mismatch` when two uses of one name disagree about the type. And a variable
carrying constraints that meets a **concrete** receiver resolves each of them there and then,
against the receiver type's methods — the module rule, the well-known table, then derivation —
which is what turns a constraint into a call target and an evidence slot.
→ `static-dispatch-spike.md` §6.2, §6.3, §1.2.

### 6.3 Generalisation and the ad-hoc kinds

A generalised scheme records, per quantified variable, its kind and equatable flag. That is
the entire mechanism of §3.1: `number` and `appendable` are closed sets tested by a flat
membership check at unification; `equatable` propagates through generalisation exactly as
`number` does, so `member : a -> List a -> Bool` in core is `∀(a: equatable)`, and a call
`member f fs` with `f : Int -> Int` fails at *that* call with `not_equatable` naming the
function type. No dictionary exists at runtime because equality is structural in the emitted
JavaScript; the flag is purely a compile-time check. Nothing else may be added to `Kind`
without revisiting `fast-compiler.md` §3.1.

**That last sentence still holds, and static dispatch obeyed it.** `Kind` is unchanged. What a
generalised scheme also records, since 2026-09-18, is each quantified variable's **method
constraints**, which live in their own set beside the kind and the equatable flag (§5) and are
written into the interface as a `where` suffix (§7). Two rules of generalisation follow and are not
obvious: a constrained `let` binding is **not** generalised — it is held at the enclosing rank, so
a constrained helper used at two types is a `type_mismatch` at the second use — and a constrained
variable that survives onto a declaration with **no parameters** is `constrained_constant`, because
a constant with an evidence parameter would be a function across the module boundary.
→ `static-dispatch-spike.md` §6.4.

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

A **method** obligation is discharged here too, by the same three cases — resolve against a concrete
receiver, fold onto a flex variable being generalised, or check a rigid variable's own `where`
clause and report `missing_where_constraint` when it does not name the method. What is new is that
discharging one can register more, so the loop is bounded, and **reaching the bound reports**
`nesting_too_deep` and poisons what is left rather than clearing the list in silence — §5's "a
guard that poisons must report first", applied here. → `static-dispatch-spike.md` §6.3.

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
  values:   [] { name: SymbolIndex, scheme: SchemeIndex, is_foreign: bool }   sorted by name
  types:    [] { name: SymbolIndex, arity: u8, kind: adt|alias|foreign, opaque: bool,
                 ctors: range into ctors, equatable: bool,
                 alias_body: TermIndex? }                                     sorted by name
  ctors:    [] { name: SymbolIndex, type: index into types, arity: u32,
                 arg_terms: range, quantified_start: u32 }   grouped by type, declaration order
  schemes:  [] { quantified: range of (kind, equatable, name, constraints), body: TermIndex }
  terms:    MultiArrayList { tag, lhs, rhs }   the flat type term language: var(i), fn(range, result),
                                               app(TypeId, range),
                                               tuple(range), record(range, ext), unit, empty_record,
                                               alias(TypeId, range), err
                                               `fn` spends `lhs` on a range in `extra` and `rhs` on
                                               the result, since an n-ary parameter list does not
                                               fit two operand words
  extra:    []u32
  symbols:  []Symbol                            remapped like Bir's
```

`dump --stage=interface` prints it: one line per value `name : scheme`, one per type with its
constructors or `opaque`, types rendered by `Render.zig` in the same form diagnostics use, so
the goldens double as documentation. The interface of a module with type errors still exists:
erroneous declarations appear with `<error>` so dependents check against the rest.
`dump --stage=raw` prints the tables themselves (§2).

**`arg_terms` is the firewall for constructors**, and M2 shipped without it. `var(i)` inside a
constructor's argument terms is the owning TYPE's parameter `i` — they are quantified first and
in declaration order, `quantified_start` says where their flags are — so a dependent rebuilds
`(arg1, …, argN) -> T p0 … pk`, **one n-ary function**, from this record alone and the result half
needs no storage. A constructor applied to the wrong number of fields is therefore §8.3's
`too_few_args` or `too_many_args` like any other call.
Without it the solver reached into the declaring module's `Bir` and found the constructor **by
name**, which breaks §4.5 and which M4 cannot do at all: a dependency's Bir may not be in
memory.

**A quantifier grew from two words to four**, and the two new ones are the `where` suffix: a range
into `extra` of `(method SymbolIndex, type TermIndex)` pairs, sorted by name text, with `var(i)`
inside a constraint's term meaning quantifier `i` of the same scheme — so a dependent rebuilds the
constraint from this record alone, exactly as `arg_terms` lets it rebuild a constructor. Both rules
below apply to them unchanged, and so does §8.1 of the design doc: these bytes are part of what M4
hashes, which is why **an unannotated `pub` declaration's interface now changes far more often**
than an annotated one's. → `static-dispatch-spike.md` §6.5; `fast-compiler.md` §8.1 for the cost.

**Every name in the record is a `SymbolIndex`, never a `Symbol`**, including a quantifier's.
A `Symbol` is an index into the session's interner, whose numbering depends on which worker
interned which file (`InternPool`'s header), so a `Symbol` written into `extra` would put a
scheduling-dependent word into the bytes §8.1 has M4 hashing. For the same reason a record's
fields are written **sorted by name text**, not in the store's own order, which is by symbol id
so that unification can merge-join two field sets in one pass. The two orders are different and
both are deliberate: the store's is for speed inside one module, the interface's is for a hash
that has to be a function of the source.

**`alias_body` is still not implemented, and that is now a stated gap rather than an omission.**
Expanding a cross-module alias reads the DECLARING module's `Bir`
(`Types.Builder.aliasBody`), which is the same hole `Ctor.arg_terms` closed for constructors.
It is left open on purpose: it is one of exactly TWO cross-module Bir reads left on the
checking path, and the other is `Types.build` itself — numbering every declared type and
settling equatability walks every module's declarations (§5). Closing the smaller one while the
larger stands would buy nothing M4 can use, so what M4 needs is a story for the whole type
table, at which point `alias_body` falls out of it. Both sites say so in the code; neither
claims a firewall it does not have, which is what went wrong the first time.

**`Interface.Provenance` is NOT part of the record.** `Interface.build` also returns, as a
separate value, the `Bir` declaration behind each value, type and constructor — the two places
that need to go interface entry → declaration (`Types`' `by_interface` and `Check`'s
`fillInterface`) were scanning the declaration table for a matching name, which is both the
lookup §4.5 forbids and quadratic in the module's public surface: 32 000 `pub` declarations
spent 12.8 s there against 73 ms for the same declarations without `pub`. It is kept out of the
interface because it is meaningless once the Bir is gone and must never be hashed with the
record M4 caches.

## 8. Diagnostics

Every code below joins the catalogue in `language.md` §10 (append there first, then in
`diagnostic.Code`), with a `bad/` fixture each. Messages follow Elm's `Reporting/Error/Type.hs`
in register and structure: the title, what the compiler was looking at, the two types laid out
one under the other with the differing part highlighted, then a hint when there is a known one
(Elm's hints for `number` vs `String`, missing `toFloat`, function equality, and record field typos
by edit distance). **The numbers-only hint names arithmetic and nothing else**: since `<`, `<=`,
`>` and `>=` became the receiver's `compare` (static-dispatch-spike.md §3.1) they are not
numbers-only and `"a" < "b"` compiles, so neither they nor "to order text use `String.compare`"
belong in it. A comparison still reaches the hint — `"a" < 1` pins both operands to one type
(spike A.33), so the `number` meets a `String` and `kindNotSatisfied` reports it — and there the
hint is true of the `number` kind while the message's own opening line, *"(<) needs the 2nd
argument to be `String`"*, carries the real cause. `<` on a type with no `compare` is
`no_methods_on_shape` (spike §10.3) and never reaches here.

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
nesting_too_deep                                (shared with the parser; §5)
unknown_method  private_method  no_methods_on_shape  missing_where_constraint
method_constraint_mismatch  type_dispatch_needs_annotation  ambiguous_method_receiver
constrained_constant                            (static dispatch; two more are lowering's)
too_many_inferred_constraints                   (the cap of static-dispatch-spike.md §6.4)
```

The last nine arrived with static dispatch on 2026-09-18, appended to `language.md` §10's
catalogue and never inserted. Two more of that set — `where_variable_unbound` and
`duplicate_where_constraint` — are reported by lowering and live under `tests/corpus/parse/bad/`.
Four existing codes are reused rather than duplicated: `not_equatable` for `eq` on a function type,
`unbound_variable` for a dotted name that is neither a value nor a constrained annotation variable,
`unexpected_token` for a `where` the grammar does not allow, and `nesting_too_deep` for the
constraint-chain guard (§6.4). Three of the nine carry **two** regions — the call the author wrote
and the annotation the requirement came from — and the author's call is the primary one.
The last of the nine, `too_many_inferred_constraints`, is the 64-constraint cap on an **unannotated**
declaration's promoted set: over it the set is dropped and the declaration promotes nothing, which
is what bounds both the inferred `where` suffix and the n(n+1)/2 an unannotated chain would
otherwise accumulate. `ambiguous_method_receiver` is the one `warning` of the set, emitted by
default and only for a module of the root package.
→ `static-dispatch-spike.md` §10.

`nesting_too_deep` is the front end's code and the checker reuses it rather than inventing a
second one: a type the checker cannot read to the bottom and an expression the parser cannot
nest any further are the same problem to the author, and the same fix — give the inner part a
name. Its `bad/` fixtures live in `check/depth/`, paired with the ones that must stay clean
(§3).

`wrong_type_arity` covers both under- and over-application of a type constructor: there are no
higher-kinded types, every type constructor is fully applied (language.md gains this line).
`recursive_alias` is Elm's rule: an alias may not mention itself, directly or through other
aliases. `duplicate_module` is two files mapping to one module name across packages other than
the app-over-core shadowing rule (cannot happen with one root; exists for M4).

### 8.2 Rendering types

`Render.zig` prints a type from a store or an interface term: variables named `a`, `b`, … in
order of first appearance per diagnostic (fresh names allocated only when rendering, design
§7), kinds as `number`/`appendable`, aliases by name, records as `{ a : Int, b : String }` with
`{ r | … }` for open ones, functions with the minimal parentheses. **Minimal, for an n-ary
function type, is a specific rule** and every diagnostic and dump golden depends on it: a
function-typed *parameter* is always parenthesised (`List a, (a -> b) -> List b`), a function-typed
*result* never is (`a, b -> c -> d`, right-associative), and a 1-ary function over a tuple prints
`(Int, Int) -> Int` so that it is distinguishable from the 2-ary `Int, Int -> Int`. The rule mirrors
`language.md` §3's grammar notes. The same renderer produces
`dump --stage=types` and `--stage=interface`, so every diagnostic's type text is corpus-tested
through the dumps.

### 8.3 The arity suite

Currying is gone (`fast-compiler.md` §9.3, `language.md` §6.7), so arity is a property of the type
and an arity mistake is a local one. Three diagnostics carry the class, and all three fire before
the generic `type_mismatch` and suppress it:

- **`too_few_args`** — a call supplies fewer arguments than the callee's type takes. The message
  names the function, how many arguments it takes, how many it got, and the types of the missing
  ones. Nothing is deferred, because there is no partial-application reading to keep open.
- **`too_many_args`** — the mirror.
- **`not_a_function`** — the callee's type is not a function at all.

**Why this is better than what currying could do, and it is the whole reason for the change.**
Under currying a one-parameter lambda in a two-parameter callback position is not an error at the
lambda: `\x -> x` unifies with `a -> b -> b` by making the accumulator a function, and the failure
surfaces two arguments later on the list. That displaced class is what re-opened the decision
(`fast-compiler.md` §9.3), and with arity in the type it does not exist — the lambda is wrong where
it is written.

`tests/corpus/check/args/` is **re-cut around that**, not adapted: a lambda of the wrong arity in
higher-order position, a call one argument short, a call with one too many, a constructor applied
to the wrong number of fields, a call through a parameter of function type, and a pipeline whose
subject is already supplied. Each fixture asserts the whole diagnostic. The direct-case fixtures
that scored 37 of 38 under currying are re-cut rather than kept, because a different rule now
produces their message, and `ComposeMissingArg` goes with `>>` and `<<`.

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
- **Every phase that can dominate a build has a row.** `types` — numbering every declared type
  of every module and settling equatability (§5) — is serial and once per run, and it had no
  event at all: on a project of long alias chains it was 1.3 s of a 1.35 s compile and the
  trace showed 46 ms. `fast-compiler.md` §12 makes the trace the instrument of record, so a
  phase that is invisible in it is a phase nobody will find. The same argument applies to work
  that sits BETWEEN events rather than outside them: writing the interface is inside `check`
  but outside `constrain`/`solve`/`exhaustive`, and at M2 it was 750 ms of an 8 000-declaration
  module's 761 ms with `constrain + solve + exhaustive` reading 10.6 ms. A gap that large
  between a parent event and its children is itself the finding.
- **`instantiations` counts one thing.** A scheme goes through `makeCopy`, which counts it;
  nothing that produces a scheme counts it again. M4's incrementality tests assert this counter
  did not move, so an imported call reading as two would make the assertion meaningless.

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
  counters; a house-rules review; `fast-compiler.md` §9.3's revisit decision recorded. Acting on
  that review is what added: the reporting rule for depth guards and the `check/depth` sweep
  (§5); `Ctor.arg_terms` and the text-sorted, `SymbolIndex`-only interface record (§7);
  `Interface.Provenance`; `dump --stage=raw` (§2); and the `types` trace event (§9).

## Appendix A — rules added to `language.md` by M2

- Type constructors are fully applied; there are no higher-kinded types (`wrong_type_arity`).
- A type alias may not refer to itself, directly or through other aliases (`recursive_alias`).
- An annotation's type variable may be marked for equality with the `equatable` prefix, in
  core only (Appendix B); user annotations obtain the mark by inference, never by spelling.
  The prefix marks the **variable at its first occurrence**, not an argument: `eq : equatable a,
  a -> Bool` is a function of two arguments, and `pub equatable foreign type List a`
  means "equatable when every parameter is". The parser accepts the prefix only before a type
  variable's first occurrence in an annotation, and only before `foreign type` in a declaration
  (`equatable_outside_core` elsewhere).

## Appendix B — the core package

Written in beni, `pub` per declaration, doc comments on everything public. The signatures are
Elm 0.19's `elm/core` minus `comparable`, `compappend` and the effect modules
(`fast-compiler.md` §3.1).

**This appendix was rewritten on 2026-09-18 for static dispatch**, and
[`static-dispatch-spike.md`](static-dispatch-spike.md) §5 is what it defers to for the `Basics`,
`List`, `Dict` and `Set` rows: that section is the site-by-site record of the change and this one is
the inventory. Three things moved. `Char` and `String` are **declared by their own modules**, not by
`Basics`, so that the module rule gives each the methods it should have. `Dict`, `Set` and the
`List` sort family **lose their comparator parameter** and carry a `where` constraint instead. And
`core/Dict/String.beni` and `core/Dict/Int.beni` are **deleted**: they existed only to hide the
comparator argument, and there is nothing left to hide.

- `Int32` (its own module): `pub opaque type Int32`, with total wrapping arithmetic — `mul` bound
  to `Math.imul`, `add`/`sub` to the truncating form, `and`/`or`/`xor`/shifts to the native
  operators, plus `fromInt` (truncating) and `toInt` (identity). The escape hatch of
  `fast-compiler.md` §3.1: `Int` is a double, and exact 32-bit work has a type that says so. `*` is
  deliberately unavailable on it, which is what makes mask-after-multiply unreachable.
**Two conventions govern every signature below** (`fast-compiler.md` §9.3 items 2 and 8,
`language.md` §6.7). Function types are **n-ary**, `A, B -> C`. Argument order is **subject first
and function last**, so that `|>` inserts at the first argument and `<-` reaches the last. Where a
variable's first occurrence is an argument of a type application, the `equatable` marker is
attached by parenthesising it: `List (equatable a)`.

- `Basics`: `equatable foreign type Int`, `Float`; `type Bool = True | False`; `type Order =
  LT | EQ | GT`; `type Never = JustOneMore Never`; the arithmetic, comparison and logic foreigns
  with `number` annotations (`add : number, number -> number`, `lt : number, number -> Bool`, …);
  `eq : equatable a, a -> Bool`; `append : appendable, appendable -> appendable`; `compare :
  number, number -> Order`; `max`, `min`, `clamp` on `number`; the numeric functions; `identity`,
  `always`, `never`, `not`, `xor`, `modBy`, `remainderBy`, `negate`, `abs`, `toFloat`, `round`,
  `floor`, `ceiling`, `truncate`, `isNaN`, `isInfinite`, `e`, `pi`, trigonometry. **`eq`, `neq`,
  `lt`, `gt`, `le`, `ge` and `compare` are no longer what `language.md` §6.5's operators mean**
  (spec §3.1); all seven stay declared, exported and callable by name.
- `List`: `equatable foreign type List a`; `foreign` for `cons`, `foldl`, `foldr` — the last two
  move into beni as soon as the code generator emits a tail-call loop (`backend.md` §8), and
  `research/17-platform-primitives.md` §3 is why that matters beyond tidiness — and for the two
  methods `List a` answers by the module rule rather than by derivation, since a list has no
  constructors to walk: `eq : List a, List a -> Bool where a.eq : a, a -> Bool` and `compare :
  List a, List a -> Order where a.compare : a, a -> Order`. Everything else in beni.
  `map : List a, (a -> b) -> List b`, `sortWith : List a, (a, a -> Order) -> List a`,
  `sortBy : List a, (a -> b) -> List a where b.compare : b, b -> Order`,
  `sort : List a -> List a where a.compare : a, a -> Order`,
  `member : List a, a -> Bool where a.eq : a, a -> Bool`. `maximum` and `minimum` stay `number`.
- `Maybe`, `Result`: entirely beni. `Result.andThen : Result x a, (a -> Result x b) -> Result x b`.
- `String`: declares `pub equatable foreign type String`; `foreign` primitives (`length`, `slice`,
  `fromInt`, `toInt`, `fromFloat`, `toFloat`, `fromChar`, `toList`, `fromList`, `append`,
  `compare : String, String -> Order`, `toUpper`, `toLower`, …); the rest in beni.
  `split : String, String -> List String`. `compare` is `String`'s own `compare` method, so
  `"a" < "b"` compiles and means what it reads as.
- `Char`: declares `pub equatable foreign type Char`; `foreign` classification and conversion.
  Its `compare` comes from the well-known table and is a **code-point** comparison (spec §3.2).
- `Debug`: `foreign log : a, String -> a` (subject first, so `value |> Debug.log "label"` reads),
  `foreign todo : String -> a`, `foreign toString : a -> String`.
- `Dict`, `Set`: beni, with the key's ordering taken from its own `compare` method rather than from
  a parameter. `Dict.empty : Dict k v` and `Dict.singleton : k, v -> Dict k v` are unconstrained —
  neither compares anything; `Dict.get`, `member`, `insert`, `remove`, `update`, `union`,
  `intersect`, `diff`, `filter`, `partition`, `merge` and `fromList` carry
  `where k.compare : k, k -> Order`; `size`, `isEmpty`, `map`, `foldl`, `foldr`, `keys`, `values`
  and `toList` carry nothing. `Set` mirrors it on `t`, with `Set.map : Set a, (a -> b) -> Set b
  where b.compare : b, b -> Order`. **There are no `Dict.String`/`Dict.Int` sugar modules.**
  → `static-dispatch-spike.md` §5.3–§5.5, §5.7.

The argument order of every remaining signature is settled by the same rule when `core/` is
rewritten; that rewrite is the deliverable, and this appendix is its specification rather than its
inventory.

The `equatable` annotation marker is the only spelling in the language that user code may not
write; the parser accepts it under `--core` only (`equatable_outside_core`, joining §10's
catalogue). Foreign types declare equality by a doc-visible attribute: `foreign type Int`
is equatable; a `foreign type` is equatable only when declared with `equatable` before
`foreign`. `List a` is equatable when `a` is.
