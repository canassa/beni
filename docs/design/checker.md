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
| `--pattern-budget=<n>` | work one `case` may spend proving exhaustiveness (§6.6) before it is refused; session-wide, so it applies to core too | 5 000 000 |
| `--platform=<name>` | enumerate a platform package too, exactly as `build` does (`frontend.md` §1, `boundary.md` §5.3); optional, and `dump` takes it for the stages that resolve imports | none |

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
    Cycles.zig              top-level value cycles (§6.7)
    Edges.zig               the declaration-edge walk (§6.7, backend.md §9), shared by
                            Cycles.zig and js/Reach.zig
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

*Amended 2026-09-27, when checker v1 was deleted.* The `check/` rows above are M2's.
`Constrain.zig` and `Solve.zig` were checker v1's generator and solver and were deleted with it,
together with v1's `Check.zig`; the rewrite's `src/check2/` took the directory's name, and the
files kept from before the rewrite stayed where they were. `src/check/` is now, by role:

```
src/check/
  Check.zig  Driver.zig  Incremental.zig    public API (run, Module, Options, Cutoff), the DAG
                                            scheduler and core gate, the cutoff protocol (§4.4)
  Module.zig  Context.zig                   one module's phases P0–P9 (checker-v2.md §5)
  constrain/Tree.zig Expr.zig Pattern.zig Decl.zig   Bir → constraint tree (checker-v2.md §6)
  Solve.zig  Walk.zig  Unify.zig  Generalize.zig  Instantiate.zig  Groups.zig
  Recursion.zig  Producers.zig  Obligations.zig  Decide.zig
                                            the solver (checker-v2.md §7–§10)
  Resolve.zig  Evidence.zig  Instances.zig  Marker.zig  Derivable.zig  Contexts.zig
  ContextUnits.zig  Eager.zig  Elaborate.zig  Unit.zig
                                            dispatch, derived contexts, elaboration (§9–§13)
  Publish.zig  Report.zig  Messages.zig     publication, the one emit path, v2's own texts
  TypeStore.zig  Types.zig  Schemes.zig  Render.zig  Diagnostics.zig  DispatchTexts.zig
  Dispatch.zig  Convention.zig  Cycles.zig  Edges.zig  Exhaustive.zig  PatternStore.zig
  Schema.zig  SchemaPlan.zig  SchemaPlanBuild.zig  Env.zig  Scc.zig  Category.zig
  reads.zig  Command.zig  InterfaceTerms.zig
                                            kept from before the rewrite (checker-v2.md §19)
  checker_test.zig                          the pipeline tests v1's `Check.zig` held, which ran
                                            under v2 from the cut-over
  rules_test.zig                            the structural fences (I2, the table's bits, size)
```

`checker-v2.md` §19.1 is the file-by-file record. No file is over 1 500 lines, which
`rules_test.zig` enforces: the deletion of v1 split `Diagnostics.zig` (`DispatchTexts.zig`), `Exhaustive.zig`
(`PatternStore.zig`) and `Contexts.zig` (`ContextUnits.zig`), each re-exporting what it moved.

The depth sweep is a kind of its own because its assertion is a PAIR rather than a file. Every
guard that can stop the checker reading a type gets a fixture one level under it, which must
check clean, and one level over it, which must produce a diagnostic; the walker enforces the
pairing by name, so a `…Ok` with a golden or a `…Deep` without one fails. It exists because
every one of those guards used to poison a type and report nothing — see §5 — and a guard is
otherwise asserted only by its absence. `tests/corpus/check/depth/generate.sh` rebuilds the
fixtures and records each guard's measured boundary.

Core is embedded into the binary with `@embedFile` from `build.zig` (one anonymous import per
file, the list generated from the directory at build time), and parsed on every cold start
until M4 caches it. `--core-root` reads the directory instead. *Amended 2026-10-01:* only the core
modules a build reaches are parsed and checked (§4, amended the same day).

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

   The scheduler (`check/Driver.zig`) is a ready queue over that order: a module
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

   Resolution runs on the same DAG schedule as item 4 (`resolve/Resolve.zig`, `Schedule`): a
   module is resolved once every module it imports has been, because what it reads of another
   module is that module's interface and its `Bir` declaration tables — which import it
   targets, and whether a missing name is private or absent — and every such target is one of
   its graph dependencies. It writes only its own `Bir`, its own interface and its own
   diagnostic list, which are concatenated in the graph's order afterwards, each item's
   `available` range moved onto the joined name list; so the result is the serial walk's at
   every `--jobs`. A cyclic project resolves on one thread, for item 4's reason. The pool is
   bounded by `--jobs`, by the DAG's width, and by the instructions to resolve
   (`insts_per_resolver`), with two threads kept whenever `--jobs` asked for more than one.
   Measured on the generated 100k-line corpus at `--jobs=8`: the phase went from 4.6 ms of one
   thread to 1.4 ms, and from 5.0 ms to 1.5 ms on a warm check, where it was the largest serial
   step left.

*Amended 2026-10-01: core is read, lowered and checked only as far as the build reaches it.*
Item 1 enumerates every core module, and until this amendment items 2–5 then lowered, resolved
and checked all of them in every process, whatever the program imported: a core module cost
every `beni` run its whole check. That made writing core in beni a tax on every test — the S3
engine's 1 300 lines took `Schema`'s check from 0.34 ms to 34 ms in every process and pushed four
tests over their instruction budget (`schema.md` §16, *As built — S3*). The rule now:

- **The roots** are every module of the root package, the platform modules `boundary.md` §9.1
  (amended the same day) makes roots — every module of a directory platform, and of an embedded
  one those its manifests name — every module whose file the command line named (`beni check
  core` checks all of core, and `dump --stage=… core/Dict.beni` dumps `Dict`), and the
  **implicit core modules** —
  the seven prelude modules and `Task`, the core modules the compiler itself names with no edge
  from the module that observes them (`Graph.implicit_core`: the prelude's names, the well-known
  types, `Lower`'s `Basics.eq`, `String.compare`, `Maybe.Nothing`, `Result.Err`, and the
  suspension protocol's `Task.andThen` and `Task.isWaiting`). `Schema` is not one of them: every
  construct that needs it mints an edge to it (§4 item 3, `static-dispatch-spike.md` §6.8).
- **The front end runs in waves** (`Session.firstWave`, `nextWave`): the first is every file
  but the core and platform modules that are not roots; each next one is the modules an explicit
  import of the last wave names, or whose type one of its files mints, until a wave adds nothing.
  A module no wave reaches is never lowered — and under `--core-root`, never read.
- **The graph keeps what an edge reaches** (`Graph.dropUnreached`). Item 3 builds it over the
  lowered files; every module no root reaches through the edges of item 3 — explicit imports,
  used prelude rows, the markup vocabulary, minted types — is left out, and the graph is built
  again without it. A module of the build is then exactly a module some root can observe, and
  resolution, the check, the persistent cache and emit see nothing else.
- **What does not change.** A program's diagnostics, interfaces, keys of the modules it has and
  emitted JavaScript are what they were: every module it can observe is checked as before, against
  the same interfaces. Which files a wave holds is a function of the input, and the interners are
  merged in file order after the last wave, so the output is identical at every `--jobs` (rule 5).
- **What does change, deliberately.** A core module nothing reaches reports nothing: a syntax or
  type error in an unreached module under `--core-root` is not the program's to hear, and is
  reported the moment a module imports it or the command line names it. `dump --stage=graph`,
  `--cache-keys`, `--frontend-keys` and the `modules`/`files` counters list the build's modules
  and files, not core's. `core_surface` is over the implicit core modules only
  (`fast-compiler.md` §8, amended the same day), so a program that begins importing `Dict` moves
  no other module's key.

*Measured* (ReleaseSafe `beni`, instructions per process, an empty `node` program / `run/Adt` /
`bench/corpus --library`): 338 M → 226 M, 349 M → 237 M, 938 M → 883 M. `zig build test-blackbox`
spends 985.6 G → 752.0 G instructions over its tests and fixtures (−24 %). Six copies of
`core/Dict.beni` added as unimported core modules (3 546 lines) cost the empty program 250 M
instructions and the suite 591 G and six tests over budget before; after, 0.3 M and 1 G and none.

*Measured and not built: a pre-checked core.* The other way to stop paying for core is to check it
when `beni` itself is built and embed the result — the persistent cache's entries and front-end
artifacts for every core module, keyed exactly as on disk, so a stale one is a miss. Its ceiling is
what a warm cache gives today: the empty program with every module but `Main` loaded from a cache is
112 M instructions against 226 M cold. It is not built here because reachability had to come first —
a pre-checked core still loads every core module unless the build knows which it reaches — and
because it puts a second compile of the compiler on the build graph's critical path (the entries
carry the build id of the binary that embeds them). It is the next step when the implicit core
modules, which every process still checks, grow in beni: they are now the whole of core's cost.

**Schema namespaces and endpoint elaboration** extend resolution here and the
interface of §7. [`schema.md`](schema.md) §3–§4 owns K13(b) exposure, the two
endpoint types, constructor/member lookup, explicit schema parameters and the
resolved schema plan; §8 owns its diagnostics. The backend receives resolved
plan data, not a TypeStore. Open questions there precede dependent implementation.

## 5. The type store

> **Checker v2 (2026-09-24).** [`checker-v2.md`](checker-v2.md) §4.1–§4.2 replaces the method-constraint set on `Flags` with references to *wanteds* whose method types are graph children for level adjustment and copying (`Walk.owned`), but not for the occurs check (`Walk.structural`), and replaces memo clearing with epoch marks. **Superseded** since the cut-over (2026-09-27): v2 is the default checker, and this section describes checker v1 only, which was deleted the same day: it is kept as the record of what v1 did.

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
  - `Exhaustive`'s depth and work budgets report `pattern_budget_exhausted` (§6.6). They reported
    **nothing** until 2026-09-18, on the argument that a half-searched pattern matrix can no more
    prove a branch redundant than prove one missing — which is true, and is why the refusal carries
    no partial result, but is not a reason to say nothing once `backend.md` §7 stopped emitting a
    default arm. This guard was the last one in the checker that gave up in silence.

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

> **Checker v2 (2026-09-24).** [`checker-v2.md`](checker-v2.md) §7–§8: `unify` merges and queues and never resolves or reports; the occurs check runs at every binder; an annotated binding's rigids are checked for generality (I1). **Superseded** since the cut-over (2026-09-27): v2 is the default checker, and this section describes checker v1 only, which was deleted the same day: it is kept as the record of what v1 did.

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

> **Checker v2 (2026-09-24).** The rule that a constrained `let` binding is not generalised is retired by the owner's decision that a constrained `let` function generalises ([`checker-v2.md`](checker-v2.md) §8.4). **Superseded 2026-09-27:** the decision is built and the `let_constrained_monomorphic` switch deleted. A `let` function binding generalises over what its requirements reach of its own and takes evidence parameters `$l<inst>$<k>`; a variable carrying only dot-calls' own requirements, and one a `let` value or pattern binding reaches, is still held at the enclosing rank ([`checker-v2.md`](checker-v2.md) §8.4). Rule (a) below is history, not the rule.

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
variable that survives onto a `pub` declaration with **no parameters** and a **non-function type** is
`constrained_constant`, because a constant with an evidence parameter would be a function across the
module boundary (narrowed 2026-09-24: one whose type IS a function is defined and
called as that function, `checker-v2.md` §12.5, `static-dispatch-spike.md` §10.10).
→ `static-dispatch-spike.md` §6.4.

Unresolved `number` variables at top level stay polymorphic in the scheme (Elm's behaviour);
M3 decides how a literal of type `number` is emitted.

### 6.4 Obligations, discharged post-solve

> **Checker v2 (2026-09-24).** An obligation whose variable escaped is kept for the enclosing boundary, not reported at the inner one ([`checker-v2.md`](checker-v2.md) §8.5, I3). **Superseded** since the cut-over (2026-09-27): v2 is the default checker, and this section describes checker v1 only, which was deleted the same day: it is kept as the record of what v1 did.

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

> **Checker v2 (2026-09-24), the owner's decision that `?` is a deferred obligation — effective since the cut-over (2026-09-27).** `?` becomes a deferred obligation decided when either side is concrete, defaulting to `Result` only at the boundary that owns its variables after rank adjustment (normally its target's own); a failure names the leg that failed ([`checker-v2.md`](checker-v2.md) §8.6; the texts are §8.6 below). `--checker=v2` has behaved so since 2026-09-25. **Superseded** since the cut-over: that decision replaced it, and this section describes checker v1 only, which was deleted on 2026-09-27: it is kept as the record of what v1 did.

`try(e, target)` where the enclosing function's declared or inferred result type is `r`:
speculatively unify `e` with `Result x a` and `r` with `Result x b` (journal mark); if that
fails, roll back and try `Maybe a` / `Maybe b`; if both fail, `try_shape` naming what `e` is.
The instruction's type is `a`. The enclosing result is the `let_def` or declaration named by
`target`, whose result var is the one after peeling its parameter count from its type. No
conversion between the two shapes and no `From` (language.md §6.6).

**The shape that wins is recorded for the backend**, in the dispatch table
(`static-dispatch-spike.md` §7.1's `tries`, one row per `?`, ascending by instruction). It is the
one thing about a `?` the emitter cannot work out for itself: the failure test it writes is the
`Nothing` tag for one shape and the `Err` tag for the other, `backend.md` §3 gives it no types, and
unlike a `case` there is no pattern at a `?` to read a constructor off. Only a **committed** guess
is recorded — the probe's rollback truncates the table with everything else, so a `?` inside
another `?`'s retracted guess leaves nothing behind — and a `?` that solved as neither shape is
`try_shape`, which refuses the build. So a `?` reaching the backend without a row is a compiler
bug, and the backend says so (`internal`) rather than guessing.

### 6.6 Exhaustiveness

> **Checker v2 (2026-09-24).** The per-declaration gate becomes a failure bit set only by **error** diagnostics, shared by every member of a binding group ([`checker-v2.md`](checker-v2.md) §15.2). The sentence below used to say the algorithm runs "over the *solved* types", which was drift; it was corrected on 2026-09-24 to the per-declaration gate `Exhaustive.zig`'s header argues for.

After a module is solved, every `case` (including the ones `if` lowered to) is checked with
Maranget's usefulness algorithm over its **patterns alone**, and only in a declaration that
produced no type error: the solved types are that gate's precondition and are not read by the
algorithm (the list below says why). Constructors of an ADT come from its
type declaration (through the interface for imported types), literals are infinite (`_`
required), lists are `[]`/`::`, tuples and records are products, and `()` is a product of no
fields — one alternative, matched by naming it, **at every depth**: `Just ()` covers `Just` exactly
as `Just ( a, b )` covers it, and leaves only `Nothing` missing. Missing patterns →
`missing_patterns` at the `case` with up to three example patterns rendered; a branch that can
never match → `redundant_pattern` at the branch.
This runs only on modules with no type errors in that declaration, so it never sees `err`.

*Amended 2026-10-01* (`language.md` §6.8, *The list syntax*). **A list column is split by length,
not into `[]`/`::`.** A list pattern may now name elements after its spread (`[ ...init, last ]`),
and no finite set of `[]`/`::` rows says "the last element is `0`", so the two-constructor union is
withdrawn and a list pattern is its own node in the simplified language: its *p* items before the
spread, its *s* items after it, and whether it has a spread at all (a pattern with none is *exact*,
of length *p*). The alternatives of a list column are computed **per column, when it is
specialised** — Rust's slice patterns, which are Maranget's constructors with a length for a name:

- Let *F* be the longest exact pattern in the column (−1 when there is none), and *P* and *S* the
  largest *p* and *s* among its patterns with a spread (0 when there are none). *L* =
  max(*P* + *S*, *F* + 1), and when *F* + 1 is the larger, *P* is raised to *L* − *S*.
- The alternatives are **`exact ℓ`** for ℓ = 0 … *L* − 1, of arity ℓ, and **`at least L`**, of
  arity *P* + *S* — its first *P* and its last *S* elements, which cannot overlap since *L* ≥
  *P* + *S*. Together they partition the lists.
- An exact pattern of length ℓ is `exact ℓ` and nothing else. A pattern with a spread covers every
  `exact ℓ` with ℓ ≥ *p* + *s* — its sub-patterns there are its *p* leading items, ℓ − *p* − *s*
  wildcards and its *s* trailing items — and covers `at least L`, with its *p* leading items, *P* −
  *p* wildcards, *S* − *s* wildcards and its *s* trailing items. A wildcard covers every
  alternative.
- `isUseful` with a list pattern first tries it against each alternative it covers, and with a
  wildcard first against each alternative of the column; `isExhaustive` recurses into every
  alternative and rebuilds each counterexample from the alternative's cells: `exact ℓ` prints as
  `[ _, _ ]`, `at least L` as `[ _, ..._, _ ]` with the spread after the first *P*. So `case xs of []
  -> …` is missing `[ _, ..._ ]`, as it was missing `_ :: _`.

Nothing else moves: a column is still one type's alternatives, the budget is charged per row visit
as before, and `Flat`'s lookup-table path declines a list pattern, whose alternatives depend on the
column. The results are the old ones wherever the old algorithm could state the question — `[]`
and `[ x, ...rest ]` are exhaustive, `[]`, `[ x ]`, `[ x, y, ...rest ]` are — and new where it could
not: `[]` and `[ ...init, last ]` are exhaustive, `[ ...init, 0 ]` alone is missing `[]` and
`[ ..._, _ ]`, and `[ x, ...rest ]` below `[ ...init, last ]` is `redundant_pattern`.

**The same analysis decides `language.md` §7's irrefutable positions** — the parameters of a
declaration, of a `let`-bound function and of a lambda, a `let` pattern, and a `<-` bound pattern,
which lowering has already turned into a lambda parameter. Each is run as a **one-row match**: is
this single pattern exhaustive on its own? Not exhaustive → `refutable_let_pattern` or
`refutable_parameter_pattern` (§8.1) at the pattern, with the missing constructors rendered exactly
as `missing_patterns` renders them. Reusing usefulness rather than asking "has this type one
constructor?" is deliberate: nesting (`Pair (Box a) b`), a type with no constructors, an opaque
imported type and the tuple/record/`as` shapes all fall out of the one algorithm, and there is no
second test that can drift from the first. The parser has already refused the literal, list and
`::` shapes, which no type can rescue, so only a pattern containing a constructor is analysed here.

**Budget exhaustion is a refusal wherever it happens.** An irrefutable position that exhausts the
budget reports the refutable-pattern error with no examples and says why, because the cost of
silence there is the guarantee `backend.md` §4's unchecked destructure stands on. A `case` that
exhausts it is `pattern_budget_exhausted` (§8.1) at the `case`, naming the budget that was in force
and the two ways past it: split the match, since the cost is in the combinations, or raise
`--pattern-budget=<n>`. The **depth** guard shares that code and not its sentence: a pattern nested
past `Exhaustive.max_depth` is equally a `case` that was not decided, but raising the budget would
not help it, so its message says how deep the analysis read and tells the author to give the inner
part a function of its own. One code, because to the author the fact is the same; two messages,
because a hint that would not work is worse than no hint. `tests/corpus/check/depth/PatternNestOk`
and `PatternNestDeep` are that guard's pair in the sweep of §5 — it was outside the sweep for as
long as it was silent.

Until 2026-09-18 a `case` reported **nothing** there, on the argument that the cost of silence was
one missed warning. That argument died with `backend.md` §7: a `case` now compiles to a decision
tree with **no default arm**, on the strength of "the checker proved exhaustiveness", so a `case`
the checker never decided does not lose a warning — it takes the tree's last edge and computes a
wrong answer at exit 0. Silence was the one remaining exit-0 path to a wrong answer in the whole
compiler, and it was reachable at the DEFAULT budget with no flag: a `case` over about 440 `Int`
literals, or about 310 constructors of one type, cost more than the 200 000 steps that were the
default then, because the per-branch work of `isUseful` against the matrix above it is quadratic in
the branch count long before the exponent of Maranget §3.3 appears. §5's rule — every guard that
gives up reports first — now holds here too, and it is the same rule that applies to `<error>`
in an interface. **Those two shapes no longer cost that**, and the next paragraph but three is why.

**Neither half reports a partial result.** Redundancy and exhaustiveness share the budget and share
this one diagnostic: a half-searched matrix can no more prove a branch redundant than prove one
missing, so whatever was found before the budget ran out is dropped with the rest. What is NOT
reported is a matrix the analysis cannot read — a poisoned constructor reference, an arity that
disagrees with the declaration, a column mixing literals with constructors. Those are precondition
failures that an earlier phase has already reported, and a second message about budget would point
at the wrong thing; they stay silent at a `case` and stay a refusal in an irrefutable position.

The **alternative that was rejected**: keep the silence and have the backend emit a throwing default
arm for budget-exhausted `case`s only. It turns a compile-time unknown into a runtime crash in code
that may well be correct, and it needs a checker→backend side channel saying which `case`s were
never decided — a new artifact out of a pass whose whole design (§6.6, `backend.md` §7) is that it
leaves nothing behind.

What was built (`check/Exhaustive.zig`), and where it reads this paragraph more narrowly than
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
  and every specialised row spends from a fixed budget and a `case` that exhausts it is
  **refused** — `pattern_budget_exhausted`, by the argument above; it reported NOTHING until
  2026-09-18. A compiler that does not terminate is still the thing being bought off, and the
  price is now a message rather than a hole. `Session.Options.pattern_budget` and
  `--pattern-budget=<n>` set it, so the bound has a test rather than an absence of one, and an
  author who meets it has a way through.
- **A LOOKUP TABLE skips both relations**, added on 2026-09-18, and the
  reason the paragraph above is past tense. A `case` whose every branch is a **key** — `_`, a
  literal, a nullary constructor, or a tuple or single-constructor wrapper of those, unwrapped
  (`as` is transparent already) — is a lookup table, and for one of those "is row k useful?" is set
  membership rather than a specialisation of the matrix above k. Exhaustiveness collapses with it:
  a full-wildcard row covers everything, and so does a key space whose every point is taken, which
  is `|keys| == ∏ alternatives` when every cell column is a constructor column. That is
  Maranget §4's observation for the one shape worth taking it on, and it is what OCaml and Elm
  rely on in practice. It decides nothing the general relation would decide otherwise, and it only
  ever answers what it can PROVE; everything else, including every witness, is handed straight
  back, for that branch and every one after.

  **The cut** is the one shape it refuses to decide: a row that is concrete in one cell and open in
  another. `( 1, _ )` covers a *slice* of the key space, and membership of a *point* cannot decide
  a slice — `( 1, _ )` above shadows `( 1, 3 )` below and no set of points says so. So a row is
  decided here when every cell is concrete (it matches exactly one value, so usefulness is "is its
  key absent?") or when every cell is a wildcard (it matches every value, so usefulness is "is
  anything above already complete?"); anything between is `isUseful`'s, from that row down. A table
  with a per-row default therefore stays quadratic, and a trailing `_ ->` — the shape essentially
  every table has — does not. Rows must also unwrap to the same spine, and a cell column that mixes
  literals with constructors is the general path's `error.Malformed` to keep. The budget is charged
  1 per node the walk visits, which is what building and probing the key costs, so
  `--pattern-budget=1` still refuses a `case`'s first branch.
- **What the default buys, re-measured 2026-09-18** by turning it down
  until the answers change. Per branch, a one-column table costs **2** and a pair **6**, where
  both used to cost a multiple of n² in TOTAL:

  | shape | before | now |
  |---|---|---|
  | 500 `Int` literals + `_` | 253 508 | **1 002** |
  | 2 000 `Int` literals + `_` | 4 014 008 | **4 002** |
  | 10 000 `Int` literals + `_` | ~100 000 000 | **20 002** |
  | 320 nullary constructors | 207 039 | **640** |
  | 2 000 nullary constructors | ~8 000 000 | **4 000** |
  | 500 `( Int, Int )` pairs + `_` | 757 514 | **3 002** |
  | 1 580 `( Int, Int )` pairs + `_` | 6 352 912 | **9 482** |
  | 5 000 `( Int, Int )` pairs + `_` | 55 075 006 | **30 002** |
  | 500 pairs of two 40-ctor enums + `_` | 527 090 | **3 002** |
  | 1 580 pairs of two 40-ctor enums + `_` | 5 343 192 | **9 482** |
  | 5 000 pairs of two 80-ctor enums + `_` | 50 473 290 | **30 002** |

  End to end in a Debug build that is **6.3 s → 0.15 s** for the 5 000-row literal pair and
  **6.8 s → 0.22 s** for the 5 000-row enum pair. (A 40×40 enum key has only 1 600 points, so the
  5 000-row enum table is two 80-constructor enums; the 500- and 1 580-row ones are 40×40.)

  What still squares is the CUT — one wildcard cell in an otherwise concrete row, which is
  `case ( a, b ) of ( 1, _ ) -> …`, a **table with a per-row default**: 2n², measured at
  **5 087 257** steps for 1 580 rows. And what this repository spends, leaving out the two fixtures
  that exist to BE tables: the costliest `case` in `core/` is **71**, in `bench/corpus` **402**, in
  `tests/corpus` **529** (`check/depth/PatternNestOk`, 511 levels of `Just`, which exists to sit
  one under the depth guard); `parse/good/ManyBranches.beni`, the old champion at ~10 500, spends
  **202**. The two tables themselves are `check/good/LookupTable.beni` at **922** and
  `check/good/PairLookupTable.beni` — 1 800 pair rows that the default REFUSED before pair tables became keys, at
  6 587 936 — at **10 802**. Each tree's maximum is one step above what the first lookup-table measurement read, because
  the key path now charges for the node it looks at before it finds it cannot read the shape; it
  used to peek for free.

  **The default is therefore 5 000 000**, by the rule *a budget a `case` a person wrote never
  meets, that still bounds an adversarial one to well under a second*. It is ~9 500× the costliest
  `case` here that is not a table; it admits a one-column table of 2.5 million branches, a
  pair-keyed one of 830 000, and a pair-keyed one with a per-row default of ~1 570; and a `case`
  that spends all of it takes **0.65 s in a Debug build and 0.07 s in ReleaseFast** (end to end on
  the 1 580-row open-pair table — about 9 M steps/s Debug, 90 M/s ReleaseFast). If the refusal
  starts firing on code people mean again, the ALGORITHM is what to fix before the number, and the
  next one to take is the cut itself: deciding slices against points needs a different structure
  than a hash set.

### 6.7 Top-level value cycles

> **Checker v2 (2026-09-24).** The "what defers" paragraph below was corrected on 2026-09-24:
> a zero-parameter declaration with evidence and no `lambda` body RUNS, at each read or call. One
> `Convention` decides it for `Cycles` and `Lower`
> ([`checker-v2.md`](checker-v2.md) §12.5; `Edges` and `Reach` do not depend on it).

`language.md` §7's initialisation rule, top-level half: a top-level **value** may not be reachable
from its own initialiser. The code is `cyclic_value` (§8.1) and the pass is `check/Cycles.zig`.

**Why it is the checker's and not lowering's.** The `let` half of the same rule is lowering's
(`let_forward_reference`), because a `let`'s references are all local and BIR knows
them. This half needs two graphs: `Bir.refs`, and the checker's **dispatch table** — a `method_call`
adds no `refs` edge at all, because which function it calls is not known until the checker has run
(`static-dispatch-spike.md` §1.4), so `bumped = (Counter 1).bump 2` with a `bump` that reads
`bumped` is a circle no `refs` walk can see. `backend.md` §5's `emissionOrder` and `js/Reach.zig`
read the same three legs for the same reason, and §8's "lowering cannot record the reference a
method call will become" is the rule all three obey.

**Where it runs, and what it costs.** Last in the module's check, after the dispatch table is
finished, inside §4.4's DAG-parallel walk. It reads only this module's `Bir` and this module's
dispatch table and writes only this module's diagnostics, so it adds no cross-thread state; a
cycle cannot cross a module, because the module graph is a DAG and an import circle is already
`import_cycle` (§4.3). Cost is one walk of the declaration table, one of the instruction range and
Tarjan over the result — O(declarations + instructions + edges), allocated in the module's scratch
arena — and a module with **no constant at all** answers before any of that, over the declaration
table alone, because nothing can be reported about one. Measured with
`bench --generate=100000 --iterations=5`, the pass off and on alternately, five runs each: the
`check` phase ran 74.5–76.6 ms with the pass off and 73.7–82.6 ms with it on, minima 74.52 and
73.73 ms, 1.34 and 1.36 M LOC/s. The spread of one configuration is larger than the difference
between them, so the honest statement is that the pass is **below this machine's noise floor**, not
that it is free.

**What is a node, and what defers.** A declaration is a node when it is a value with a body. It
**defers** — nothing of it runs at module load — when it has parameters, or when its entire body is a
`lambda`. **Evidence parameters alone do not defer** (corrected 2026-09-24): since 2026-09-22
a zero-parameter declaration with evidence is CALLED at every read, so its body runs then, and a
self-reference recurses. A zero-parameter value of **function** type with evidence
(`h = compose h g` under a `where`) is DEFINED as a function of its evidence and its type's
parameters, but it is still a value for this rule and RUNS: `language.md` §7 states
the rule over the source, where it is written as a value, and a `where` must not change which
programs are accepted — its twin without the `where` is refused. Only parameters or a `lambda` body
make a declaration defer. `js/Lower.declaration` splits on the same readings, and since the
checker rewrite one `check/Convention.zig` decides them for both (`checker-v2.md` §12.5). A strongly connected component with at least
one node that RUNS is refused; one made only of deferring nodes is mutual recursion between
functions and is fine. The analysis is conservative in exactly the shape §7 describes: mentioning
a function counts as running it.

**One diagnostic per component**, at the first node of it that runs, in source order, with the
circle printed in the order it is walked (shortest way round, breadth-first over edges in table
order) — so nothing in the output depends on visit order or on `--jobs` (CLAUDE.md rule 5).

`Cycles.zig` and `js/Reach.zig` walk the same three legs over the same tables, and they **share
`check/Edges.zig`**, which is that walk. It lives under `src/check/` because it is a pure function
of `Bir` and the dispatch table and because this pass runs per module inside the checker and may
not depend on the backend, where `js/Reach.zig` already depends on `check/`; the walk yields a
declaration's targets as a flat tagged stream — `top d | ext (module, value) | derived r |
ext_derived (module, type, kind) | primitive p | err` — into a buffer the caller owns, and each
consumer keeps the tags it can use. `Cycles.zig` keeps `top` alone, because a cycle cannot cross
a module; `js/Reach.zig` takes all six and resolves the cross-module ones against the provenance
and dispatch tables it has and this pass has not. *(It was written twice until 2026-09-19, with
nothing but review keeping the two in step. Sharing it costs `eliminate` about 0.2 ms on a
633-module build — the stream is materialised where the old code appended straight to its own
node list — which does not move the `emit` phase that contains it.)*

## 7. The interface record

Per module, flat, index-based, session-owned, immutable once built — designed so M4 can hash
it and map it from disk unchanged (`fast-compiler.md` §8.1, §8.3):

```
Interface
  values:   [] { name: SymbolIndex, scheme: SchemeIndex, is_foreign: bool }   sorted by name
  types:    [] { name: SymbolIndex, arity: u16, kind: adt|alias|foreign, opaque: bool,
                 ctors: range into ctors, equatable: bool,
                 payload_params: bitset range, eq: derived, compare: derived,
                 alias_body: TermIndex? }                                     sorted by name
  ctors:    [] { name: SymbolIndex, type: index into types, arity: u32,
                 arg_terms: range, quantified_start: u32,
                 result: nominal|record_alias, fields: range of SymbolIndex }
                                                             grouped by type, declaration order
  schemes:  [] { quantified: range of (kind, equatable, name, constraints), body: TermIndex }
  terms:    MultiArrayList { tag, lhs, rhs }   the flat type term language: var(i), fn(range, result),
                                               app(TypeRefIndex, range),
                                               tuple(range), record(range, ext), unit, empty_record,
                                               alias(TypeRefIndex, range), err
                                               `fn` spends `lhs` on a range in `extra` and `rhs` on
                                               the result, since an n-ary parameter list does not
                                               fit two operand words
  extra:    []u32
  type_refs:[] { package, module: SymbolIndex, name: SymbolIndex }   first mention order
  symbols:  []Symbol                            remapped like Bir's
```

`dump --stage=interface` prints it: one line per value `name : scheme`, one per type with its
constructors or `opaque`, types rendered by `Render.zig` in the same form diagnostics use, so
the goldens double as documentation. The interface of a module with type errors still exists:
erroneous declarations appear with `<error>` so dependents check against the rest.
`dump --stage=raw` prints the tables themselves (§2).

**`<error>` in the record is a statement about the program, never about the writer, and it always
travels with a message.** Every path in `fillInterface` that publishes `<error>` for a declaration
that *solved clean* — the scheme writer running out of `Schemes.Writer.max_depth`, or the poisoned-
type scan running out of budget — reports `nesting_too_deep` first, which is §5's rule applied to
the way out of the module. The alternative is the one failure mode a compiler may not have: `beni
check` exits 0, the interface entry is a hole, and every importer checks against it and compiles
clean. So no bound on the way out may be a silent one; a bound is either large enough that no
program reaches it, or it is a reported error and an exit code. The scan that decides whether a
solved type is poisoned carries **no** width bound for exactly that reason — it once carried a
fixed 256-entry worklist, which made an ordinary 256-link record extension chain `<error>` at exit
0 — and `check/good/DeepInferredScheme` is the fixture.

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

**The purity rule: an interface record is a function of its module's source and its imports'
interfaces, and of nothing else in the program.** Decided 2026-09-18, and it is what makes §8.1's
firewall a cutoff rather than a formality — "recompile a dependent only when the dependency's
interface changed" is worth nothing if the record moves for reasons that have nothing to do with
the dependency. No index assigned by walking the whole project may be written here.

The rule was broken by `app` and `alias`, which spent `lhs` on a `TypeStore.TypeId` — a
**whole-program** dense index, assigned by numbering every declared type of every module in
`Graph.Index` order (§5). So adding one type declaration to an alphabetically earlier module
rewrote the bytes of a module that did not import it: `term 4 app 15 10` became `term 4 app 16 10`
for three unrelated edits alike — a new `pub` type, a new **private** type, and a new file
containing a type. On a real project most of a record's `app` terms name a type numbered after
whatever was added, so the firewall would have fired on approximately every type-introducing edit
and the warm budgets of `fast-compiler.md` §2 would have been measured against a full rebuild.

**`type_refs` is the encoding.** `app` and `alias` spend `lhs` on an index into a table of this
module's own, each row `(package, declaring module's name, type's name)` — two `SymbolIndex`es and
a package tag, nothing a session assigned. The row's CONTENT is the type's identity; the row's
POSITION is first mention in the writer's walk, which is a function of the module's own source.
Four consequences, all deliberate:

- **The DECLARING module, not the module the reference came through.** An inferred scheme can name
  a type its module never imported — `C` uses `B.mk : A.T` without mentioning `A` — so a reference
  relative to the import edge would not exist. Being absolute, it is copied through `B`'s record
  unchanged, and `C`'s bytes move only when `B`'s do, which is what the firewall wants.
- **A NAME, not the declaring module's interface `TypeIndex`.** `pub make : Hidden` over a private
  `type Hidden` is legal, so a `pub` scheme can name a type that is in no interface's `types` table
  at all. An index into a table the type is not in cannot say which type it is.
- **Renaming a type a record names now moves that record's bytes**, which is correct and was not
  true before: the id of `Mid.Tag` does not change when it is renamed to `Mid.Label`, so the old
  record could not see a rename of a type it depended on.
- **Reading one stays O(1).** The session's translation of a module's `type_refs` into `TypeId`s
  lives in `Types.ref_ids`, built once per module at the end of that module's check by the thread
  that checked it — exactly as `Types.by_interface` translates an interface `TypeIndex` — so
  instantiating an imported scheme indexes an array and never resolves a name. Filling it is the
  only name lookup on the type table, it runs once per module per build, and §4.5's rule is about
  the per-use path, which stays free of names. Like `Provenance`, `ref_ids` is **not** part of the
  record and must never be hashed.

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

*Amended 2026-09-28 (`checker-v2.md` §14.2, interface format 7).* The record no longer writes an
alias's expansion inside each term that names it: an `alias` term holds its arguments, and its
`type_refs` row holds the alias's body once per record (`type_refs: [] { package, module, name,
body: TermIndex }`, 16 bytes serialized). That is `alias_body` moved onto the reference and
written for every alias a record names, whichever module declares it; the cross-module Bir read
for an alias an ANNOTATION names (`Types.Builder.aliasBody`) is unchanged, and the paragraph above
still describes it.

**`Interface.Provenance` is NOT part of the record.** `Interface.build` also returns, as a
separate value, the `Bir` declaration behind each value, type and constructor — the two places
that need to go interface entry → declaration (`Types`' `by_interface` and `Check`'s
`fillInterface`) were scanning the declaration table for a matching name, which is both the
lookup §4.5 forbids and quadratic in the module's public surface: 32 000 `pub` declarations
spent 12.8 s there against 73 ms for the same declarations without `pub`. It is kept out of the
interface because it is meaningless once the Bir is gone and must never be hashed with the
record M4 caches.

### The serialized form

*Specified 2026-09-18 for the first incrementality work (`plans/m4-slice-zero.md`); the hash over these bytes and
the acceptance test are `fast-compiler.md` §8.*

The record's bytes **are** its contract — §8.1's firewall compares them — so the on-disk form is
specified here beside the in-memory one and not wherever a cache happens to be written.

```
header    magic "BENIIFC\x00" (8)   format_version: u32   column_count: u32
table     column_count × { offset: u32, len: u32 }        offsets from byte 0
columns   in table order, each 4-byte aligned, gaps zero-filled
```

Eleven columns, in this order and no other: `values`, `types`, `ctors`, `schemes`, `term_tags`,
`term_lhs`, `term_rhs`, `extra`, `type_refs`, `symbols`, `strings`. `terms` is split into its three
SoA columns rather than written as a row of 12 bytes, because that is what the record already is and
what §8.3 wants to map. `len` is the element count except for `strings`, where it is a byte count.

| Column | Element | Bytes |
|---|---|---|
| `values` | `name: u32`, `scheme: u32`, `flags: u8` (bit 0 `is_foreign`), pad `[3]` | 12 |
| `types` | `name: u32`, `ctors_start: u32`, `ctors_end: u32`, `arity: u16`, `kind: u8`, `flags: u8` (bit 0 opaque, bit 1 equatable), `payload_params: u32`, `eq_context: u32`, `compare_context: u32`, `eq_status: u8`, `compare_status: u8`, pad `[2]` | 32 |
| `ctors` | `name`, `type`, `arity`, `arg_terms`, `quantified_start`, `fields`, all `u32`; `result: u8`, pad `[3]` | 28 |
| `schemes` | `quantified_start: u32`, `quantified_count: u32`, `body: u32`, `effects: u32` (since format 9) | 16 |
| `term_tags` / `term_lhs` / `term_rhs` | `u8` / `u32` / `u32` | 1 / 4 / 4 |
| `extra`, `symbols` | `u32` | 4 |
| `type_refs` | `module: u32`, `name: u32`, `package: u8`, pad `[3]` | 12 |
| `strings` | `len: u32` then `len` bytes, padded to 4 | — |

Padding exists because alignment demands it, is written as zeros and is hashed like everything else.
It is **not** a reserved field: an interface change is a `format_version` bump and a cache discard,
never a migration into spare bytes (`plans/m4-plan.md`).

**`format_version` 3 is interface v3** (2026-09-25; `checker-v2.md` §14.2 is the
contract and says why each change exists). The type row's `arity` is a `u16` (lowering
refuses a 65 536th parameter with `too_many_type_parameters`, so nothing saturates). A constructor
row says what it builds: `result` 0 `nominal`, 1 `record_alias`, and a `record_alias` row's `fields`
is an `extra` range of one `SymbolIndex` per argument, the alias's field names in declaration order
(`no_terms` for a nominal row) — lexical, so the resolve-time skeleton has them and a cache install
compares them against the shell. The type row's three new words are `extra` ranges, `no_terms`
where there is nothing to say: `payload_params` is ⌈arity / 32⌉ words of bits, parameter `i` at bit
`i % 32` of word `i / 32` (every bit for a `foreign type`; `no_terms` for an alias); each derived
row's status byte is 0 `unchecked`, 1 `present`, 2 `primitive`, 3 `own_method`, 4 `foreign`,
5 `function`, 6 `unanswerable`, 7 `alias` (their meanings are §14.2's *As built*), and only a `present` one has a context range, `(param, method SymbolIndex)`
pairs sorted by `(param, method text)`. Both are filled when the module is checked, from every
constructor of the declaration (an opaque type's hidden ones included); a record that was never
checked says `unchecked`. `iface_bytes.verify` refuses a bitset of the wrong length or with a bit
past the arity, a context entry naming a parameter the type does not have, a context on an absent
row, and a `record_alias` row whose names do not number its arguments.

**`format_version` 9** (2026-09-30) adds a scheme's `effects` word: the `extra` offset of its
effect block, or `no_terms` — the bits the checker infers for every function, in the layout
[`transparent-effects-proposal.md`](transparent-effects-proposal.md) §14.6 specifies. `verify`
refuses a block that leaves `extra`, names a class or a step kind that does not exist, or a field
step that is not a symbol slot.

**Every scalar is little-endian by definition of the format**, converted on write and on read, so the
bytes and therefore the hash are a function of the source on any host. What is host-specific is the
*cache*, not the record: §8.3's zero-copy map wants the host's own byte order and alignment, so a
cache directory is machine-local and its key says so.

**The one column that changes shape is `symbols`.** In memory it is `[]Symbol`, an index into the
session interner whose numbering depends on which worker interned which file (`InternPool`'s header,
`Session.zig:16-22`). On disk `symbols[i]` is instead a byte offset into `strings`, and loading
re-interns each string — through the non-mutating `InternPool.Global.find` when a record is round-tripped
inside a session (it runs on a worker and `Global` is thread-confined; every string was interned by that
session, so a miss is `internal`), and through `getOrPut` only on the cache's serial load, before workers start. The column keeps its length and its
order — every `SymbolIndex` in every other column means what it meant — and only its *contents* are
translated, which is `Global.merge` run backwards. Two slots holding the same text may share one
`strings` record; the blob is built in first-occurrence order over the column, so sharing does not
move a byte.

**What the bytes do not contain, and why each may be left out.** `Provenance` (above) — it is
`Bir.DeclIndex`es, and its only two readers, `Types.build` (`src/check/Types.zig:397`) and the
module's own `fillInterface` (`src/check/Check.zig:1036`), run only for a module whose Bir is
present; it is therefore not serialized at all rather than serialized unhashed. `Types.ref_ids`
(`src/check/Types.zig:120-135`) — recomputed by `resolveRefs` (`:286`) once per module per build,
which is where `Check.zig:1103` already does it. Any `Symbol` — replaced by text, above. Any
`Graph.Index` — the record holds none since `type_refs` landed.

**What must travel beside the record, unhashed**, when a dependency's Bir is absent: the interface
type slot → own declaration ordinal map `Types.build` reaches through `Provenance`
(`src/check/Types.zig:396-404`), and the module's whole declared-type table with its settled
`equatable`/`comparable`/`has_function` bits (`:476-524`). Both are functions of the module's source,
so both are pure — and both must still stay **out of the hashed bytes**, because adding a private
type to a module shifts its own declaration ordinals while changing nothing a dependent can see, and
a hash that moved for that would defeat the firewall exactly as the `TypeId` leak did. They are a
sidecar of the cache entry, not part of the record. The first incrementality work did not write one: its acceptance
test round-trips the record with every Bir still in memory. → `plans/m4-slice-zero.md` §4.

**Loading validates, and a bad record is a MISS, never a message.** A wrong magic, an unknown
`format_version`, a short file, a column whose offset or length leaves the file, or a `strings`
record that runs past the blob: each makes the load fail and the caller recompute from source. A
stale cache must be indistinguishable from a cold build, so none of these is a diagnostic and none
is an exit code. Past the header the record is taken as-is and every index is bounds-checked **at
use**, which is the posture `range`, `typeRef`, `quantified`, `quantifiedConstraint`,
`ctorQuantified` and `quantifiedSymbol` already take (`src/resolve/Interface.zig:411-467`) and
`Schemes.Reader` mirrors (`src/check/Schemes.zig:769`, `:818`, `:836`). Four accessors did not and
now do, because a loaded record reaches them: `term` (`Interface.zig:419`), `scheme` (`:432`) with
`valueScheme` (`:471`), and `symbol` (`:477`). A loaded record never reports: the module that wrote
it reported when it wrote it (`Schemes.zig:763-768`). A record that is structurally valid and
nevertheless *wrong* — written by a different compiler build, or edited — is the cache key's
problem (`fast-compiler.md` §8.1), not the reader's; the split is that a wrong answer is a key bug
and a crash is a reader bug.

**`dump --stage=raw` is the differ, not the format.** It resolves symbol indices to text and omits
`Scheme.quantified_start`, `Quantified.constraints_start` and the `symbols` column's identity — two
slots holding the same text print alike and the column's length is never stated — so it is not
lossless and must not be mistaken for a serialization. It stays what §2 says it is: the view that
can see a byte difference the two pretty printers hide.

### The cache entry, and the sidecar beside the record

*Specified 2026-09-19 for the on-disk cache (`plans/m4-1.md`); the key over these bytes, the directory and the
acceptance test are `fast-compiler.md` §8.*

One file per module, named by its cache key, holding the record verbatim and the two things a hit
cannot recompute. Same shape as the record's: magic, version, a column table, little-endian scalars,
4-byte alignment, gaps zero-filled, and **a bad entry is a MISS, never a message and never an exit
code**.

```
header    magic "BENICAC\x00" (8)   format_version: u32   section_count: u32
          key: [16]u8               the key this entry was written for
table     section_count × { offset: u32, len: u32 }        offsets from byte 0
sections  in table order, each 4-byte aligned
```

**This container is the compiler's, not this entry's.** The record uses it (above), the entry uses
it here, and the front-end artifact uses it a third time with its own magic, its own key and its
own section list (`fast-compiler.md` §8, *The front-end artifacts, and the file key*) — magic,
`format_version`, the key repeated in the header, a `{offset, len}` table from byte 0, 4-byte
alignment, zero-filled gaps, little-endian scalars, and a bad file a MISS. Three formats and one
shape is deliberate: a reader written against one is written against all three, and the validation
posture below is stated once.

Three sections, in this order and no other: `interface`, `dispatch`, `diagnostics`. **`interface` is
the bytes `iface_bytes.write` produced, verbatim**, so `iface_bytes.hash` over that section IS the
interface hash §8.1's firewall compares and the firewall re-derives nothing. The entry repeats its key in the
header because the file NAME is the key: a mismatch is the "wrong build id" case, and it must be
detectable without trusting a directory entry.

**`dispatch` is the sidecar.** It is the module's `Dispatch` table (`src/check/Dispatch.zig:227-242`)
and it is here because it is the one product of the solver the backend needs and nothing can
reconstruct without solving — every method call's target, every `?`'s shape, every evidence
parameter and every derived function the module emits. Same container, columns `sites`, `tries`,
`decl_evidence`, `evidence`, `derived`, `parts`, `symbols`, `module_refs`, `type_refs`, `strings`.
Two of its in-memory fields are session-relative and neither may reach the bytes, for the reason
§8.1's purity rule gives: `Target.Ext.module` and `Target.ExtDerivedUse.module` are a `Graph.Index`
(`:97`, `:119`) and become an index into `module_refs`, each row `(package, module name)`;
`Shape.nominal` and `ExtDerivedUse.type` are a `TypeId` (`:49`) and become an index into a
`type_refs` table with the record's own row shape, `(package, declaring module's name, type's
name)`. `symbols` becomes offsets into `strings`, exactly as the record's does. What stays as-is is
every `Bir.DeclIndex` and `Bir.Inst.Index`: they index the module's own `Bir`, which the key's
`source_hash` and option string pin, and an `Interface.ValueIndex`, which indexes an import whose key
the entry's key contains.

**Resolving those two tables needs `Types`, which does not exist when the entry is read**, so
loading is two steps and the split is part of the contract: the entry is read, validated and
re-interned **serially, before any worker starts** — `InternPool.Global` is thread-confined and this
is the load `iface_bytes`' header reserves `getOrPut` for — and `module_refs`/`type_refs` are
translated through `Graph.find` and `Types.find` on the DAG, in the hit path, where `Types` is built
and read-only.

**`diagnostics` is the module's own check diagnostics**, one row of
`{ code: u16, severity: u8, has_token: u8, region: u32, token: u32, message_start: u32,
message_len: u32 }` into a `messages` blob — `Diagnostics.Item` (`src/check/Diagnostics.zig:41-60`)
minus its `module`, which the entry is for. The message is stored as the prose the checker rendered,
because a checker's message is built from types that die with the store; the span is NOT stored and
is recomputed from this build's `SourceStore`, so a module that moved without changing its name still
points at the right file. `Code` is stored as its integer value, which is meaningful only for the
compiler build the key names — adding a diagnostic renumbers the enum and changes the build id, which
is the mechanism.

**Installing a loaded record is validated against the shell.** `Interface.build` has already run at
resolve time and produced this module's `values`, `types` and `ctors` tables and its `Provenance`
(`src/resolve/Interface.zig:570`); the loaded record replaces the shell wholesale, and the
counts and the name of every entry of all three tables must agree first — `Provenance` is
`Bir.DeclIndex`es indexed by slot, it is never serialized, and a record whose slots did not line up
with it would be a silent miscompile rather than a miss. On the 100k corpus that is ~2 500
comparisons for the whole project.

**What is NOT in the entry, and why each may be left out.** The `TypeStore` — one per module, dead
by design at the end of its check (`src/check/Check.zig:593-595`), and no dependent reads one.
`Types.ref_ids` — recomputed by `resolveRefs` (`src/check/Types.zig:286`), once per module per
build, which is where `Check.zig:1127-1129` already does it. `Provenance` — above. And the declared-
type table with its settled `equatable`/`comparable`/`has_function` bits, `declaresPubCompare` and
the interface-slot → declaration-ordinal map that *The serialized form* names as owing a sidecar:
**their disposition stands, they are not due with the cache entry, and it splits in two.** Every one of them
is a function of the declaring module's `Bir`, and the cache entry, the front-end artifact and the firewall all keep every module's `Bir`
present — the front-end artifact loads it from disk instead of rebuilding it, and `Types.build` walks all of them
either way (`src/check/Types.zig:364`, `:477`). So **the firewall needs their DEFINITION and their HASH** —
it keys an importer on its imports' records, the records do not carry these facts, and a hash it
recomputes from the `Bir` and compares is what closes that gap — and **an incremental `Types` needs their BYTES**, when
a module's `Bir` may be absent for the first time. Writing them with the cache entry
would be bytes nobody reads.

### The dependency digest

*Specified 2026-09-19 for the interface firewall (`plans/m4-3.md`); the key over it, the ordering and the acceptance
test are `fast-compiler.md` §8. It is the sidecar the paragraph above has been promising, and it is a
HASH today and bytes on disk once `Types` goes incremental.*

**One sentence: the record is what a module PUBLISHES, the digest is what a module's dependents
READ.** The two are different sets, and the gap between them is where a firewall keyed on the record
alone answers exit 0 to a program the compiler rejects. Two such gaps are demonstrated rather than
argued (`plans/m4-3.md` §6): a private type whose payload becomes a function stops being `equatable`
without moving one byte of its module's record, and a `pub type alias` whose body no scheme of its
own module mentions has its expansion nowhere in the record at all. *(Since interface v3: a
RECORD alias is not that case — it declares a constructor, whose argument types were already in the
record and whose field names now are. `digest_test.zig`'s row 13 therefore uses a tuple alias.)*

The digest is a 128-bit value over this byte string, in this order, every integer little-endian,
hashed with the same `std.hash.SipHash128(1, 3)` and the same all-zero key the record and the key
use — one hash function in the compiler:

```
header    magic "BENIDEP\x00" (8)   digest_version: u32
module    package: u8   name_len: u32, name          the DOTTED module name
types     type_count: u32, then per type NAMED BY THIS MODULE'S RECORD,
          sorted by name TEXT:
            name_len: u32, name
            arity: u16               (a `u8` until `digest_version` 2)
            kind: u8                 adt | alias | foreign
            flags: u8                bit 0 opaque, bit 1 equatable,
                                     bit 2 comparable, bit 3 has_function,
                                     bit 4 holds_markup (from `digest_version` 3)
            body_len: u32, body      the alias expansion as interface TERMS
                                     (tag, lhs, rhs triples and the `extra`
                                     words they reach, `var(i)` meaning the
                                     alias's own parameter i), or length 0
                                     when the type is not an alias
derived   derived_count: u32, then per NOMINAL row of this module's dispatch
          `derived` table, sorted by the emitted name text:
            kind: u8                 eq | compare
            module_len: u32, module  the DECLARING module's name
            name_len: u32, name      the type's name
imports   import_count: u32, then per direct import, sorted by
          (package, name), duplicates removed:
            package: u8, name_len: u32, name,
            iface_hash: [16]u8, digest: [16]u8
```

**"Named by this module's record" is a closed set, and that is the whole reason a private type stays
free.** It is this module's `types` table — its `pub` types — plus every `type_refs` row whose module
is this module, which is how a `pub` signature over a private type (`pub make : Hidden`) puts that
type's name into its own record. A dependent can reach a type of this module only by naming it, and
it can only name it through a `type_refs` row of some record it reads; every such row is absolute and
is copied through unchanged, so a name reachable from anywhere is a name this record already holds. A
private type nothing mentions is in no record, no dependent can name it, and it is in no digest —
which is what keeps `plans/m4-1.md` §6.1's row 5 and makes a private type's addition cost the leaf
alone.

**Sorted by name TEXT and keyed by NAME, never by ordinal and never by `TypeId`**, for the reason the
record's own orders exist: a `TypeId` is a whole-program dense index and a declaration ordinal moves
when a private declaration is added, and a digest that moved for either would defeat the firewall
exactly as the `TypeId` leak did. Nothing a dependent emits or reports carries a `TypeId` — `app` and
`alias` spend theirs on `type_refs`, `Shape.nominal` becomes a name in the sidecar, the `derived`
tables sort by emitted name text, and `Exhaustive` compares ids without ever printing one — so the
VALUES are not a dependency and only the `Entry` fields they index are.

**Why each row is there, and where it is read.**

| Row | Why a dependent can see it | Site |
|---|---|---|
| `arity`, `kind` | in the record for a `pub` type; for a private one the record has a `type_refs` row and no `types` row, so nothing states either | `src/check/Types.zig:186`, reached by `find` at `:303` |
| `equatable` | in the record for a `pub` type (`types` flag bit 1) and nowhere for a private one; `x == y` on an imported value reads it | `src/check/Solve.zig:3767`, `:1956-1963` |
| `comparable` | in the record for NO type. It is the fixpoint's second bit, and it folds `declaresPubCompare`, which reads the declaring module's WRITTEN annotation and so is not derivable from a published scheme | `src/check/Solve.zig:3768`, `:3456`; `src/check/Types.zig:591-602` |
| `has_function` | in the record for no type; §10.3 of the dispatch spec picks a different sentence by it | `src/check/Solve.zig:1962` |
| `holds_markup` (*added 2026-09-29*) | in the record for no type; a platform module's `markup_type_in_foreign` (`checker-v2.md` §25.2) reads it of every named type in a `foreign`'s signature, and a private constructor payload that gains the markup type moves no byte of the record | `src/check/Vocab.zig`, `mentionsType` |
| the alias expansion | in the record only where a term mentions the alias — an `alias` term's range is its arguments followed by its expansion — and absent when no scheme of the declaring module names it | `Types.Builder.aliasBody`, `src/check/Types.zig:969` |
| the nominal `derived` set | the declaring module emits these bodies and a dependent's cached dispatch table names them through `ext_derived`; it is not in the record because a derived row exists for a private type too, and putting it there would move the public hash for a private change | `src/check/Solve.zig:3375-3384` against `:3766-3773` |
| the imports' `(hash, digest)` | one level of terms carrying every level of type-reachability (`fast-compiler.md` §8) | the recipe itself |

**What is deliberately NOT in it**, each with the reason it may be left out. **Constructor names and
arities** — already the record for a `pub` type, and a dependent cannot see a private type's
constructors at all: `Exhaustive.ctorUnion` (`src/check/Exhaustive.zig:1151-1168`) and
`Solve.allNullary` (`src/check/Solve.zig:3002-3010`) both reach them through `Interface.findType`,
which a private type is not in. **The interface-slot → declaration-ordinal map** the paragraph above
names — its only consumer is `Types.build` filling `by_interface`, and what a dependent reads through
it is the type at interface slot `i`, which the record already states by name; the map is a session's
internal translation and not a fact about the module. **`Provenance`** — the same argument, and it is
`Bir.DeclIndex`es besides. **`declaresPubCompare` as a bit of its own** — it exists only to settle
`comparable`, which is here. **Module metadata** — `(package, name)` is in the key's import terms and
in every `type_refs` row.

**The error paths need nothing, because an erroring module is never cached.** `Solve.privateInOtherModule`
(`:3099-3107`), `Resolve.whyMissing` (`src/resolve/Resolve.zig:333-352`) and `Resolve.owningTypeName`
(`:354-360`) read the target module's `Bir` to tell `private_method` from `unknown_method` and
`private_name` from `unknown_import_name`. All three produce `error`-severity diagnostics, and
`fast-compiler.md` §8's clean-check rule refuses to write an entry for a module whose own check
produced one — so a stale choice between those messages can never be replayed. **Today nothing
degrades for a second reason as well**: the front-end artifact loads every module's `Bir` from disk, so a dependency's
`Bir` is present on every run, hit or miss. **Later incremental work inherits both**: the moment `Types` goes
incremental and a `Bir` may be absent, these three sites need the degradation their own comments
already specify, and the digest grows the private VALUE names the first of them reads.

**`alias_body` in the `Interface` layout above is withdrawn in favour of this.** It was declared and
never implemented, and the digest is the better home: a PRIVATE alias is reachable by name and has no
`types` row to carry one, so the record could not have covered the case at all; and keeping the
expansion out of the record means the digest bumps no `format_version`, re-blesses no `.iface` golden
and moves no `--stage=raw` byte.

**`--dep-digest` is the instrument**, `--iface-hash`'s twin: hidden, `check`-only, one
`<package>:<Module> <32 hex digits>` line per module including `core` and the platform, sorted by the
printed key. It lands before the key changes, for the reason `--cache-keys` and `--frontend-keys`
landed before their slices' writes — the whole edit-scenario table is fixtures against it, with no
cache directory in sight.

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

*Amended 2026-09-27.* The numbers-only hint is now printed **only where an
arithmetic operator's operand is the mismatch** (§8.7): `"a" < 1` is not arithmetic, so it gets the
conversion hint Elm gives for `number` against `String`, and the sentence above about a comparison
reaching the hint is history.

### 8.1 Codes

```
unknown_module  import_cycle  unknown_import_name  private_name  opaque_constructor
wrong_type_arity  recursive_alias  duplicate_module
type_mismatch  rigid_mismatch  infinite_type  kind_mismatch
too_few_args  too_many_args  not_a_function
missing_field  unknown_field  record_not_closed
not_equatable  not_interpolatable  ambiguous_interpolation  ambiguous_tuple
tuple_index_out_of_range  not_a_tuple  try_shape
missing_patterns  redundant_pattern  pattern_budget_exhausted
refutable_let_pattern  refutable_parameter_pattern   (shared with the parser; §6.6, language.md §7)
nesting_too_deep                                (shared with the parser; §5)
unknown_method  private_method  no_methods_on_shape  missing_where_constraint
method_constraint_mismatch  type_dispatch_needs_annotation  ambiguous_method_receiver
constrained_constant                            (static dispatch; two more are lowering's)
too_many_inferred_constraints                   (the cap of static-dispatch-spike.md §6.4)
cyclic_value                                    (§6.7, language.md §7)
method_needs_annotation                         (static-dispatch-spike.md §10.12)
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

`pattern_budget_exhausted` was appended the same day, after the static-dispatch
set and after `foreign_arity_mismatch`, so again no line above it moved. It is the third code of
§6.6's set and the only one that is about the CHECKER rather than about the program: the analysis
could not decide this `case` inside `--pattern-budget`, so it refuses it rather than passing an
unproven `case` to a decision tree that carries no default arm (`backend.md` §7).

`method_needs_annotation` was appended on 2026-09-23, after `cyclic_value` here and after the schema codes in `language.md` §10, so no line moved: a use of a module's own type reached that module's unannotated method before its group was checked (`static-dispatch-spike.md` §10.12).

`cyclic_value` was appended on 2026-09-18, last, so again no line above it moved.
It is §6.7's one code and the only one of this list that is about **when a value is computed**
rather than about its type: a top-level value reachable from its own initialiser, which
`backend.md` §5's dependency order cannot order and which therefore loaded and threw at run time
with the build exiting 0. Its message names the whole circle in the order it runs, as
`import_cycle` does one scope up; its fixtures are `check/bad/CyclicValue*` and its allowed
shapes are `run/EvalOrderTopLevelInit.beni`.

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
through the dumps. Disambiguation (`number`, `number2`, … `number65`) is amortised O(1) per name
— a per-stem next-suffix counter over a set of the names already handed out, never a rescan from
`2` — because one warning on a wide `where` clause used to cost milliseconds of the error path.

**The printer has two bounds, both of them truncations, and a truncation is always visible and
never a different type.** `Render.max_depth` (24) elides a nested type as `…`; `Render.max_ext_links`
(64) elides the rest of a record's extension chain — remaining fields and tail alike — as
`{ … | a : Int, … }`, with the `…` standing where the extension variable would. Both stop at a
width past which more text stops helping, and neither is an error: the diagnostic that asked for
this text is already decided and the bound changes only how much of one type the reader sees.
What a bound may **not** do is change the type it is printing. An extension chain that ran out
of links used to print `{ a : Int, … }` **closed**, and a closed record is not a truncation of an
open one — it refuses the extra fields the open one accepts, so the reader was shown a constraint
the program does not have, and a `--stage=interface` dump said so as an artifact. `… | ` is the
defined form for "open, and there is more here"; `check/depth/RecordExtTruncatedDeep` and
`check/good/RecordExtChain` pinned it in a diagnostic and in an interface respectively.
*Since the cut-over (2026-09-27)* those two print the whole 65-field record, open
(`{ r | … }`): checker v2 keeps a record as one node (`checker-v2.md` §4.1), so no chain
reaches `max_ext_links`, and no fixture reaches the `… | ` form any more. The bound and its rule
stand for any chain a later store can build.

*A third bound, added 2026-09-25.* A type is printed as a TREE, so a shared
or cyclic graph — `x = ( x, x )`, a doubling `let` — printed 2^24 leaves under `max_depth` alone:
300 MB of stderr from a two-line program, on both checkers. `Render.Namer.budget` bounds the nodes
one message prints (`message_budget`, 4 096); past it a node prints `…`, the same truncation as
`max_depth`. The dumps (`--stage=types`, `--stage=interface`), whose output is a type's whole text,
set the budget to `unlimited`, so no golden moves.

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

### 8.4 The 80-column rule, enforced after interpolation

Added 2026-09-19. **A diagnostic's prose is 80 columns wide, and the width is
measured on the message the reader gets, not on the format string the author wrote.** Every message
in the compiler is a multi-line string literal wrapped by hand around `{s}` holes, and the width of
what goes into a hole — a type, a path, a module, a name — is not known where the wrapping was
done. `main_not_program`'s second paragraph was written to fit and then spliced `Basics.Int` into
its first line, which came out at 85 columns; a sweep of `tests/corpus/**/*.diag` found 131 such
lines across 50 goldens, in codes as far apart as `shadowing` and `unclosed_delimiter`. Fixing the
prose fixes one message; the rule is enforced where the message is finished.

`render/wrap.zig` re-wraps every message on its way into a diagnostic — once, at
`Session.Worker.reportAs` for the check waves and at `Session.renderLate` for the emit wave. Four
properties make it safe to run over prose nobody re-read:

- **Only an over-wide paragraph moves.** A paragraph whose every line already fits is copied
  through byte for byte, so the pass is idempotent and a golden moves only where the rule was
  broken.
- **A backticked span is never broken.** `` `import x from "node:x";` `` is one unit however many
  spaces are inside it; a line break in the middle of code the reader is meant to copy is worse
  than an overrun, so a span wider than 80 is the one case that still overruns.
- **A paragraph with structure is left alone** — an indented block is a code sample, and a line
  beginning `-`, `|`, `#`, `>` or a digit is a list, a table or a quotation. This is also what
  keeps §8.2's business separate from this one: a 625-column record printed by `Render.zig` into
  an indented block is bounded by `max_depth` and `max_ext_links`, never by a wrap.
- **A column is a code point.** The messages are full of `§`, `—` and `…`, each one column wide
  and two or three bytes long, and the hand-wrapped prose this rule has to agree with was measured
  by eye.

### 8.5 Checker v2's texts: the annotation escape and the infinite type

Added 2026-09-25 (`checker-v2.md` §15.3), **before** the code that prints them. They
are what checker v2 prints; the old checker kept its own texts until the cut-over, since
which these are the default checker's. Everything else below is unchanged.

**The annotation escape (`checker-v2.md` §8.3).** Code `rigid_mismatch`, title
`TYPE MISMATCH`. An annotated `let` binding whose rigid variable the body tied to a type of the
enclosing definition:

```
The type annotation of `g` promises more than its body keeps:

    g : a -> a

The annotation says `a` can be ANY type, but the body ties `a` to a type that
comes from `f`, the definition `g` is written inside. That type is fixed for
each call of `f`, so `g` does not work for every `a`.

Hint: write the enclosing definition's type in the annotation instead of `a`,
or remove the annotation and let the type be inferred.
```

- `g` is the binding, `f` the top-level declaration the `let` is written in, `a` the variable
  that escaped (a row variable is named the same way: `r` for `{ r | x : Int }`), and the
  indented line the annotation as the binding's callers see it — the scheme, rendered by §8.2's
  printer before it is poisoned.
- **The span** is the first unification that tied the variable to an outer one (the *capture*
  of `checker-v2.md` §7.1: the `x` in `g y = x`, the `o` in `g y = o`), and the binding's
  annotation when no capture was recorded.
- The binding's scheme is then poisoned, so its callers are not checked against the promise and
  add no second message.

**The infinite type (`checker-v2.md` §8.2).** Code `infinite_type`, title
`INFINITE TYPE`. The structure is written down, with the repeated node named:

```
I am inferring a weird self-referential type for `y`:

Here is my best effort at writing it down, with `a` standing for the whole
type wherever it repeats inside itself:

    a = a -> b

Hint: the type would go on forever, so I gave up. This usually means a
definition is missing an argument, or is being used with one argument too
many, somewhere inside itself.
```

- `y` is the binder the check started from: a lambda or declaration parameter, a pattern
  variable of a `case` branch, or a `let` or top-level header. A cycle found from a unification
  rather than a binder says `here` instead: *"I am inferring a weird self-referential type
  here:"*.
- The indented line is the cycle's node — the variable the occurs walk met twice — named first,
  then its structure printed once with every inner occurrence of the node written as that name.
  `a` is whatever name §8.2's namer gives it (it is `a` unless the structure already uses `a`),
  and the paragraph says the name it used. `f r = { r | x = r }` prints `a = { r | x : a }`.
- **The span** is the binder: the parameter's pattern (`\y`), the `case` branch's pattern, the
  `let` definition, or a top-level declaration's body; for a unification, its expression.

### 8.6 Checker v2's texts: which leg of a `?` failed

Added 2026-09-25 (`checker-v2.md` §8.6, §15.3), **before** the code that prints
them. They are what checker v2 prints; v1 kept §6.5's one text until the cut-over. Code
`try_shape`, title `BAD QUESTION MARK`, region the `?` expression, in all three.

Deciding a `?` is three unifications (§6.5): the subject `e ~ Shape x a`, the enclosing result
`r ~ Shape x b`, and the instruction `~ a`. The shape comes from the subject when it has one, else
from the enclosing result, else from the default. The message says which leg failed.

**The subject is neither.** Only this case keeps §6.5's sentence, because only here is it true:

```
`?` needs a `Result` or a `Maybe`, and this is neither:

    Int

The enclosing definition returns:

    Result String Int

Hint: `e?` unwraps an `Ok`/`Just` and returns the `Err`/`Nothing` from the
enclosing definition, so both have to be the same shape. There is no
conversion between `Result` and `Maybe`.
```

**The enclosing result is not the subject's shape:**

```
This `?` returns early from the enclosing definition, which returns:

    Result String Int

but this is a `Maybe Int`, and `?` on a `Maybe` can only return from a
definition whose result is a `Maybe` too.

Hint: `e?` unwraps an `Ok`/`Just` and returns the `Err`/`Nothing` from the
enclosing definition, so both have to be the same shape. There is no
conversion between `Result` and `Maybe`.
```

- The first indented line is the enclosing result, the sentence after it names the subject, both
  printed by §8.2's printer with one namer. A `Result` subject reads the same with `Result`.

**The error types differ** (both are `Result`s):

```
This `?` returns the error of a `Result` from the enclosing definition, but
the error types differ: `Int` here, `String` in the enclosing result:

    Result Int Int

Hint: convert the error first, with `Result.mapError`, so that it has the type
the enclosing definition returns.
```

- `Int` is the subject's error type and `String` the enclosing result's, and the indented line is
  the subject, all three printed with one namer.

### 8.7 Checker v2's texts: context, hints, articles and names

Added 2026-09-27 (`checker-v2.md` §15.3, §15.4), **before**
the code that prints them. The dispatch texts added the same day are `static-dispatch-spike.md` §10's
(§10.3, §10.4, §10.11, §10.13). Everything not named here keeps its text. Elm is the bar
(`references/elm/compiler/src/Reporting/Error/Type.hs`, `Pattern.hs`); each item says what Elm
prints for the same mistake.

**A list's 1st element against its context.** Elements are checked left to right against
one element type that the context (an annotation, a parameter) may already have fixed, so the 1st
element can only fail against the context: there are no previous elements. Category `list_entry`
at index 1 reads:

```
The 1st element of this list is not what the list needs:

The 1st element is:

    number

But this list needs its elements to be:

    String
```

A later element keeps *"does not match all the previous elements"*, which is true of it. Elm
constrains a list's entries before the list meets its context, so it reports the whole list
instead: *"The body is a list of type: `List number` But the type annotation on `xs` says it
should be: `List String`"*.

**The numbers-only hint needs an arithmetic operator.** *"`+`, `-`, `*` and `/` work on
numbers only"* is printed only when the mismatch is an argument of `+`, `-`, `*`, `/`, `//` or `^`
(category `call_arg`, callee the operator). Elsewhere a `number` or `Int` against a `String` gets
the conversion in the direction the value has to go, as Elm's `badFlexSuper` and `problemToHint`
do (*"Try using `String.fromInt` to convert it to a string?"*, *"Want to convert a String into an
Int? Use the `String.toInt` function!"*):

```
Hint: want to turn a number into a `String`? Use `String.fromInt` or
`String.fromFloat`.
```

```
Hint: to read a number out of text, use `String.toInt` or `String.toFloat`.
```

The first when the `String` is what was needed, the second when the `String` is what was found. A
`number` against anything else keeps *"One of those has to be a number — an `Int` or a `Float` —
and it is not."* with no hint, where Elm says *"Only `Int` and `Float` values work as numbers."*

**An Elm-style curried annotation.** An annotated definition with *n* ≥ 2 parameters whose
annotation is *n* nested 1-ary functions (`Int -> Int -> Int` over `add a b`) is one mistake. The
mismatch keeps its layout and its place (the body) and replaces the arity hint with:

```
Hint: this annotation is in Elm's curried form. A beni function takes all
of its arguments at once, and its type lists them before one arrow:

    Int, Int -> Int
```

The indented line is the annotation's first *n* parameters, then its *n*th result, printed by
§8.2's printer. The condition is syntactic (the parameter count) and the annotation's shape, so it
is decided when the scheme is read (`checker-v2.md` P2, and a `let` binding's header), and **the
scheme is poisoned there**: a caller written `add 1 2`, beni's way, is not checked against a
promise the author did not mean, and adds no TOO MANY ARGS. Elm accepts the program — currying is
Elm's — so there is no Elm text; its nearest is the arity note of `Type.hs`'s `toFunctionReport`.

**A function where the subject goes.** A call's argument that is a function, where the
parameter is not one and another parameter of the callee is a function of as many arguments, is
Elm's argument order (`List.map String.fromInt [ 1, 2 ]`); it replaces *"this is a function, so it
may be missing an argument"*:

```
Hint: this function looks like it belongs in the 2nd argument, which takes
one. beni's functions take their subject first — `List.map list f`, where
Elm writes `List.map f list` — so the arguments may be the wrong way round.
```

`2nd` is the first such parameter. Elm has no subject-first convention and no such hint.

**Articles.** A backticked name after *a* takes *an* when it starts with a vowel letter:
*"This record does not have an `extra` field"*, *"This record has an `id` field I did not
expect"*, *"This is not a record with an `age` field"*, *"a `let` binding whose type needs an `eq`
method"*. The rule is the letter, not the sound, so it can misjudge a name like `url`; a name is
not a word, and the letter is what the reader sees. Elm prints *"a"* every time (`Type.hs` line
846: *"does not have a `extra` field"*).

**A cons pattern inside a constructor.** `missing_patterns` prints a constructor with
arguments in parentheses only in ARGUMENT position (`Just (Node a b)`), never at the head of a
`::`: `Group (Circle _ :: _)`, not `Group ((Circle _) :: _)`. This is Elm's `patternToDoc`, whose
`Head` context adds no parentheses to a constructor (`Pattern.hs` lines 139–165). *Amended
2026-10-01:* with `::` gone a list prints in brackets, `Group [ Circle _, ..._ ]`, and an item needs
no parentheses at all (`language.md` §6.8; `check/bad/MissingPatternConsRendering`).

**A constructor with its type's name.** The `exposing (T(..))` hint lists
the type and then every constructor the imported module exposes — except one that shares the
type's name, which naming the type already exposes (`language.md` §5.2). When that leaves none:

```
`Box(..)` is how Elm exposes every constructor of `Box`, and beni has no
wildcard: list the constructors you use by name, beside the type.

    exposing (Box)

Naming `Box` exposes the type and its constructor `Box` both.
```

The last sentence is printed whenever a constructor was left out for sharing the name. Elm accepts
`(..)`; there is no Elm text.

**A kinded variable prints as its kind.** A flex or rigid variable of kind `number` or
`appendable` prints as the kind (`number`, `number2`, …) unless its name already starts with the
kind's text; a name inherited through unification — `cons`'s `a` merged with a literal's unnamed
`number` — is dropped. So `1 :: []` is `List number` in a message and in `--stage=interface`, and
a message never says *"This argument is: `List a` … One of those has to be a number"*. The
interface's quantifier name hint follows the same rule (`Schemes.Writer` writes no name for such a
variable), which also makes its bytes independent of the order a recursive group's members are
written in. Elm's variables carry their kind in their name (`number`, `comparable`),
so it never has the case.

**A record a deferred requirement refused is printed as P4 left it.** A requirement
an instantiated scheme made on an argument (`f`'s `where a.combine`, readied when `{ combine = \z
-> z + 1 }` reaches `x`) is refused under eager draining (`checker-v2.md` §9.1) before the rest of
the argument is solved, so `no_methods_on_shape` printed the record as it met the receiver, `{
combine : a -> b }`. Its code, region and failure bit are still decided there; its TEXT is drawn
again when P4 ends, from the store as the whole module left it: `{ combine : number -> number }`,
what v1 printed. Elm has no methods; its messages are likewise written after solving.

**An argument after a failed one asks nothing.** A review saw an UNKNOWN METHOD
(*"I cannot tell which type `key` is being asked of"*) beside a TYPE MISMATCH at one call, and
the checker no longer prints it for any shape tried; `check/bad/CallArgMismatchNoUnknownMethod` pins
the one message. The rule it pins is `checker-v2.md` §7.1's: a call stops at its first reported
argument, and a requirement of the callee whose receiver no argument determined fails in silence.

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

**The doc examples are checked, and they are normative about behaviour.** A doc-comment line of
exactly `--|`, five spaces and a non-space character is an EXAMPLE, and a following `--|` line
indented further continues it; an example holding a `==` at bracket depth zero, outside string and
character literals, is an ASSERTION and everything else is prose. `tests/blackbox/docs_test.zig`
appends every assertion VERBATIM to a temp copy of its own module as `pub docExample_<line> : ()
-> Bool`, so it is read in the scope the reader of that doc comment reads it in — unqualified
names resolve to the module's own, and no qualifier is invented — then builds the temp core
against the node platform and runs it: every assertion must COMPILE as a `Bool` equality and must
be TRUE. An example the mechanism cannot take is named in that file's `skips` with a reason, the
list is printed on every run, and a skip matching no example fails the gate, so the excuse cannot
outlive the line. Fixing the example is preferred to excusing it: an example naming a value the
docs never define is a defect in the doc, not a candidate for the skip list.

**This appendix was rewritten on 2026-09-18 for static dispatch**, and
[`static-dispatch-spike.md`](static-dispatch-spike.md) §5 is what it defers to for the `Basics`,
`List`, `Dict` and `Set` rows: that section is the site-by-site record of the change and this one is
the inventory. Three things moved. `Char` and `String` are **declared by their own modules**, not by
`Basics`, so that the module rule gives each the methods it should have. `Dict`, `Set` and the
`List` sort family **lose their comparator parameter** and carry a `where` constraint instead. And
`core/Dict/String.beni` and `core/Dict/Int.beni` are **deleted**: they existed only to hide the
comparator argument, and there is nothing left to hide.

*Amended 2026-10-01; specified, not built.* **`List` gains Elm `Array`'s indexed operations and a
few more, and there is no `Array`** (`language.md` §6.8, the owner's one-sequence decision):
`initialize : Int, (Int -> a) -> List a`, `get : List a, Int -> Maybe a`, `last : List a -> Maybe a`,
`set : List a, Int, a -> List a`, `update : List a, Int, (a -> a) -> List a`,
`push : List a, a -> List a`, `pop : List a -> List a`, `slice : List a, Int, Int -> List a`,
`insertAt : List a, Int, a -> List a`, `removeAt : List a, Int -> List a` and
`swap : List a, Int, Int -> List a`, all `pub`. `List a` stays `pub equatable foreign type List a`
with no constructors, so nothing in the checker changes: the type is the same type, and only its
representation and its costs move (`backend.md` §4, *Lists are arrays*). The first slice of
`plans/list-arrays.md` adds the signatures, over today's cons cells.

- `Int32` (its own module, **built 2026-09-19**): the escape hatch of `fast-compiler.md` §3.1 —
  `Int` is a double, and exact 32-bit work has a type that says so. `*` is deliberately unavailable
  on it, which is what makes mask-after-multiply unreachable; `==` and `<` are available, because
  the module declares its own `pub eq` and `pub compare` and the module rule
  (`static-dispatch-spike.md` §1.2, §3.3) makes them the type's methods, exactly as `String`'s
  `compare` is `String`'s. It is **not** in the well-known method table of §3.2 and needs nothing
  from it. Not in the prelude (`language.md` Appendix A, §2.5): `import Int32`.

  The declaration is `pub equatable foreign type Int32`, not the `pub opaque type Int32` this
  bullet said before it was built. A `foreign type` is what a type with no beni representation is
  (`language.md` §5.4) — the value is an ordinary JavaScript number kept in int32 range by its
  operations (`backend.md` §4) — and `equatable` is what makes a record or custom type holding one
  derive its own `eq` (`Types.Entry.equatable`); `comparable` comes from the `pub compare`, through
  `declaresPubCompare`.

  Every function is **total**: every result is a 32-bit value, nothing throws, and division by zero
  is `zero` for all three of `div`, `rem` and `mod` — the answer `Basics.idiv`, `remainderBy` and
  `modBy` already give. `minValue / -1` wraps to `minValue`. A shift count is an `Int` and is taken
  **modulo 32**, which is what JavaScript's shift operators do with it.

  | | Signature | |
  |---|---|---|
  | `fromInt` | `Int -> Int32` | **`foreign`**. Truncating (`\| 0`), so it is total: a fraction goes towards zero, a NaN or an infinity is zero |
  | `toInt` | `Int32 -> Int` | **`foreign`**. Signed, so the top bit reads as negative; exact |
  | `toUnsignedInt` | `Int32 -> Int` | **`foreign`**. 0…4294967295, the form hash and checksum vectors are published in |
  | `add` `sub` `mul` | `Int32, Int32 -> Int32` | **`foreign`**. `mul` is `Math.imul`, and is the whole reason the module exists: a 32-bit product can exceed 2⁵³, so `(a * b) \| 0` is already wrong |
  | `div` `rem` `mod` | `Int32, Int32 -> Int32` | **`foreign`**. `div` truncates towards zero; `rem` takes the sign of the dividend (`remainderBy`), `mod` the sign of the divisor (`modBy`) |
  | `and` `or` `xor` | `Int32, Int32 -> Int32` | **`foreign`**. The native operators, already exactly 32-bit |
  | `shiftLeft` `shiftRight` `shiftRightZero` | `Int32, Int -> Int32` | **`foreign`**. Arithmetic `>>` and logical `>>>`; the logical one is brought back into signed range, because `>>>` in JavaScript answers unsigned |
  | `zero` `one` `minValue` `maxValue` | `Int32` | beni, over `fromInt` |
  | `neg` `complement` | `Int32 -> Int32` | beni. `neg` is `sub zero n`, `complement` is `xor n (fromInt -1)` |
  | `rotateLeft` `rotateRight` | `Int32, Int -> Int32` | beni, over the shifts and `or`. What xorshift and murmur mix with |
  | `eq` | `Int32, Int32 -> Bool` | beni. What `==` and `/=` mean on one |
  | `compare` | `Int32, Int32 -> Order` | beni, over `Basics.compare`. **Signed**, and what `<` and its three relatives mean |

  **Deliberately absent.** No `toString`/`fromString`: `String.fromInt (Int32.toInt n)` and
  `Int32.fromInt` over `String.toInt` are two obvious calls, and adding them would make `Int32`
  import `String` for nothing. No `min`/`max`/`abs`/`clamp`: `Basics`' are `number`-kinded and do
  not apply, and a hash, PRNG, checksum or binary-format author — the audience this module was
  sized for — needs none of them; `compare` is there when one is wanted. No `pow`, no `Int64`
  (`fast-compiler.md` §3.1 leaves that for BigInt), no bit-at-index accessors, no
  `fromBytes`/`toBytes` — those belong to a binary-format library written OVER this one, which is
  the point of shipping the primitive inside the wall.
**Two conventions govern every signature below** (`fast-compiler.md` §9.3 items 2 and 8,
`language.md` §6.7). Function types are **n-ary**, `A, B -> C`. Argument order is **subject first
and function last**, so that `|>` inserts at the first argument and `<-` reaches the last. Where a
variable's first occurrence is an argument of a type application, the `equatable` marker is
attached by parenthesising it: `List (equatable a)`.

**Callback order is part of every signature below, not an implementation detail.** The language is
strict and evaluates left to right in source order (`language.md` §6, *Evaluation order* — normative
there since 2026-09-18, and no longer the proposal it was cited from), so the
order in which a core function calls the function it was given is observable — through `Debug.log`
today, and through which request is sent first once effects land. The rule: **a core function that
takes a callback and produces its result in the order of its subject calls that callback in that
same order, first element first** — `List.foldl`, `map`, `indexedMap`, `filter`, `filterMap`,
`concatMap`, `map2`…`map5`, `partition`, `any` and `all` (both with early exit) walk the list front
to back; `Dict` and `Set`'s `map`, `filter`, `partition`, `foldl` and `merge` walk in ascending key
order; `String`'s walk the string left to right; `Maybe` and `Result`'s callbacks are called at most
once. **`foldr` is the exception, by definition**: `List.foldr`, `String.foldr`, `Dict.foldr` and
`Set.foldr` call their callback last element first, and that — not an accident of an implementation
built on `reverse` — is their contract. The sort family splits the question in two. A
**comparator** is outside the rule: `sort`, `sortBy` and `sortWith` call theirs in whatever order
the merge sort reaches, as many times as it needs, and that order and count are deliberately
unspecified, because they are inherent to a sort. A **key function** is not a comparator and is
inside it: **`List.sortBy` calls its key exactly once per element, in list order, first element
first**, which is what decorate–sort–undecorate buys — `map` to `( key x, x )` pairs with the
left-to-right `map`, sort the pairs on the first component with the evidence `compare`, `map` back.
It used to call the key once per comparison, six times for a three-element list and not at all for
a one-element one; an expensive key was recomputed, and once effects land an effectful one would
run its effect a number of times nobody can predict. All three sorts are **stable** — `mergeWith`
takes the left element on anything but `GT`, and `splitHalf` keeps the front half in front — and
that is a contract too, not an accident, because a record-keyed `sortBy` depends on it.

- `Basics`: `equatable foreign type Int`, `Float`; `type Bool = True | False`; `type Order =
  LT | EQ | GT`; `type Never = JustOneMore Never`; the arithmetic, comparison and logic foreigns
  with `number` annotations (`add : number, number -> number`, `lt : number, number -> Bool`, …);
  `eq : equatable a, a -> Bool`; `append : appendable, appendable -> appendable`; `compare :
  number, number -> Order`; `max`, `min`, `clamp` on `number`; the numeric functions; `identity`,
  `always`, `never`, `not`, `xor`, `modBy`, `remainderBy`, `negate`, `abs`, `toFloat`, `round`,
  `floor`, `ceiling`, `truncate`, `isNaN`, `isInfinite`, `e`, `pi`, trigonometry. **`eq`, `neq`,
  `lt`, `gt`, `le`, `ge` and `compare` are no longer what `language.md` §6.5's operators mean**
  (spec §3.1); all seven stay declared, exported and callable by name. *Amended 2026-10-02
  (`language.md` §12.4; specified, not built):* `Int` and `Float` move to `core/Int.beni` and
  `core/Float.beni`, `modBy` and `remainderBy` become `Int.mod` and `Int.rem`, `logBase` becomes
  `Float.log`, and `Debug.log` is `String, a -> a`.
- `List`: `equatable foreign type List a`; `foreign` for `cons` — `foldl` and `foldr` moved into
  beni with the tail-call loop (`backend.md` §8), which is what
  `research/17-platform-primitives.md` §3 says matters beyond tidiness — and for the two
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
