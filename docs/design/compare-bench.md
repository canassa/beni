# Cross-language type-checking benchmark — generated programs

**Status.** Normative from the slice that lands `bench/compare/gen/` (§18). Written 2026-09-27. It
replaces the earlier method of `bench/compare/`: five
hand-written ports of three programs, copied N times. That method's measurement half worked and is
kept (§10). Its program half is what this document replaces. Hand-written ports cannot scale
without repeating names, cannot be shown to be equal, and cannot be varied along the axis a
question is about.

**What it measures.** For beni, Elm, Gleam, Roc, PureScript and TypeScript (7, the Go compiler): the cold, single-core cost of
type-checking one unit of generated code, reported per family of type-checking problem and in
total. Every language gets the same program, from one source.

## 1. Requirements

The owner's requirements (O1–O9) are binding. The rest of the document implements them.

| # | Requirement | Where |
|---|---|---|
| O1 | The program need not do anything: a large body of generated functions. | §3, §4 |
| O2 | The lowest common denominator of the languages. Nothing that exists in only one. | §2 |
| O3 | Many modules, and each family of modules focuses on one part of the type-checking problem. | §4 |
| O4 | One Zig command generates every language from one source. | §3, §12 |
| O5 | The codebase is large, and loops produce many variations of functions. | §3.5, §5 |
| O6 | Both the hard parts of type checking and ordinary everyday code. | §4 |
| O7 | Generated code is not committed. Results are. | §12, §13 |
| O8 | Every compiler runs single-threaded. | §9, §10 |
| O9 | No language sees a type error. | §2.4, §3.7, §11 |

Non-goals: measuring code generation, run-time speed, incremental rebuilds, error-message quality,
or multi-core scaling. A `--multi` run may exist, but it is indicative only and never headline
(§10.6).

## 2. The common subset

### 2.1 In and out

A construct is **in** only if the five ML-family languages (beni, Elm, Gleam, Roc, PureScript) all have it, all five check it with the same kind of
work, and each language can print it from one language-neutral tree node. "The same kind of work"
means unification, instantiation, generalisation and exhaustiveness over the same types. TypeScript, added by the owner on 2026-09-27, can express the whole subset, so it neither adds nor removes a construct. How it maps, and where its work differs, is §2.6.

| In | Notes |
|---|---|
| `Int`, `Float`, `String`, `Bool` | Literals are typed in the tree, so an `Int` literal prints as `1` and a `Float` literal as `1.0` everywhere. |
| custom types with **positional** constructor fields, parametric and recursive, mutually recursive within a module | See §2.2 on field names. |
| pairs | Only arity 2. Elm stops at 3, and PureScript's `Tuple` is a pair. |
| built-in lists | Literals, plus three library functions used by the everyday family only (§2.3). There are no list patterns. |
| `if`/`else`, `case` with nested constructor, tuple, literal, variable and `_` patterns | No guards. No `as`. No list patterns. |
| `let` bindings of values and of non-recursive lambdas | There are no local recursive functions, because Gleam cannot write one. |
| lambdas, functions as arguments and as results, saturated calls | There is no partial application. Every call passes exactly the declared parameters (§2.2). |
| parametric polymorphism of top-level functions and types | The program is HM-inferable: there is no polymorphic recursion and no higher rank (§6.2). |
| mutual recursion between top-level functions of one module | Imports form a DAG in every language. |
| the operators `+ - *` on `Int` and on `Float`, `++`/`<>` on `String`, `&& \|\| not`, `==` on `Int`/`String`/`Bool`, `<` on `Int`/`Float` | Nothing else. Comparison is never applied at a type variable or a custom type. |
| pipelines of unary stages | See §2.2. |
| qualified cross-module references, exported (`pub`) declarations | Every declaration is exported (§2.4). |

**Out:** records of every kind (Gleam has none), extensible records and row polymorphism, labelled
constructor fields, type classes, abilities, `where` clauses, `comparable`/`number` used as
constraints, `Maybe`/`Option`/`Result` from the libraries (the program declares its own types),
division, negation, guards, `as`, list patterns, local recursion, let-polymorphism (§19 V3),
tuples wider than 2, string interpolation, effects, and every beni-only form (`?`, `<-`, `_`
placeholders, dot-calls, static dispatch). The out list is closed: adding a construct means editing
this section first.

### 2.2 Same work, different spelling

The printers own every difference below (§3.8). The tree has one node for each.

| Construct | beni | Elm | Gleam | Roc (the Zig compiler, `a3ce7f1`) | PureScript | Why it still counts as the same work |
|---|---|---|---|---|---|---|
| n-ary function type | `A, B -> C` | `A -> B -> C` | `fn(A, B) -> C` | `A, B -> C` | `A -> B -> C` | Elm and PureScript curry, but every call is saturated, so each checker unifies the same n argument types. |
| call | `f a b` | `f a b` | `f(a, b)` | `f(a, b)` | `f a b` | |
| `if` | `if … then … else` | same | `case c { True -> … False -> … }` | `if c { … } else { … }` | `if … then … else` | Gleam has no `if`. A two-way `case` on `Bool` adds one trivial exhaustiveness check, which is disclosed in §10.7. |
| custom type | `type T a = C a Int` | same | `pub type T(a) { C(a, Int) }` | `T(a) := [C(a, I64)]`, nested in the module's void type | `data T a = C a Int` | Roc's type is nominal (§2.5). |
| field access | `case t of C x _ -> x` | same | same shape | `match t { T.C(x, _) => x }` | same | Field access is a one-branch `case` everywhere, which every language can express. |
| pair | `( a, b )` | same | `#(a, b)` | `(a, b)` | `Tuple a b` | PureScript's pair is an ordinary constructor, so checking it is constructor application. |
| list literal | `[ a, b ]` | same | `[a, b]` | `[a, b]` | `a : b : Nil` | PureScript's literal syntax builds arrays. `Data.List`'s `:` is constructor application. |
| string append | `++` | `++` | `<>` | `Str.concat(a, b)` | `<>` | PureScript resolves a `Semigroup String` instance at a known type (§10.7). |
| Float `+` | `+` | `+` | `+.` | `+` | `+` | |
| `Int` → `String` | `String.fromInt` | `String.fromInt` | `int.to_string` | `I64.to_str` | `show` | |
| pipeline stage | `x \|> f` | `x \|> f` | `x \|> f` | `x \|> f` | `x # f` | Only **unary** stages are generated, because Elm and PureScript pipe into the last argument and the others pipe into the first. |
| qualified name | `Inf003.f12` | same | `inf003.f12` | `Inf003.f12`; tags through their type, `Base.Seq.SCons` | `Inf003.f12` | |
| type variable | implicit | implicit | implicit | implicit | `forall a.` | Printed only in annotations. |

### 2.3 Library surface

The only library functions the program calls are:

- `Int` → `String`;
- the everyday family's `map`, `filter` and `foldl` over built-in lists.

`foldl`'s function argument is always a lambda, so the printer can reorder its parameters. The
parameter order is `(elem, acc)` in beni and Elm, and `(acc, elem)` in Gleam's `list.fold`, Roc's
`List.walk`, PureScript's `foldl` and TypeScript's `reduce`. Everything else the program needs is declared in the
program's own `Base` module (§7.1), so each standard library's cost lands in the intercept.

### 2.4 Well-formed in every language, beyond types

A program that type-checks can still be refused for other reasons. The generator makes each of
these impossible by construction.

- **Names.** Every name is a lower-case letter followed by digits (`f12`, `v3`) or an upper-case
  letter followed by digits (`T4`, `C4b`). These fit every language's case rules, including
  Gleam's snake_case and Roc's style. None of them can collide with the union of the six
  keyword lists (TypeScript's strict-mode reserved words included), which is checked in a unit test.
- **Distinct names.** No name is ever shadowed: Elm and beni refuse shadowing. Constructor names
  are unique across the whole program, because Roc's tags are global. Names are also distinct
  across units (they carry the family, unit and declaration index), so the name-repetition caveat
  of the earlier method does not recur.
- **Warnings.** `roc check` exits non-zero on warnings. Every declaration is exported, every import
  is used, every bound variable is used or is `_`, and no `case` branch is redundant. Elm and beni
  refuse redundant patterns outright. PureScript's `MissingTypeDeclaration` warning, in inferred
  mode, is the one expected warning.
- **Top-level declarations are functions of arity ≥ 1.** Gleam's top-level values are `const`s,
  and Roc's are evaluated at compile time.
- **Added 2026-09-27, from the printers' confirmations (§19 V2, V8–V10).** The compilers refuse, or
  warn on, more than type errors, and each rule below is one the generator obeys in every language,
  so all six still print one tree:
  - *No condition or scrutinee the compiler can decide.* Roc folds everything that does not depend
    on a run-time value and warns on a condition it can decide, and Gleam warns on a `case` over a
    literal or over a variable whose constructor it already knows. So a condition reads a parameter,
    a lambda parameter, a pattern variable or a binding computed from one (`Local.dynamic`), is never
    a bare local, a literal, or an operand chain with a literal operand (`false && e`), and a `case`
    never splits a local that an enclosing `case`, `if` or `let` already fixed (`Gen.known`). Roc
    also treats a call of a `let`-bound lambda with constant arguments as constant whatever the
    lambda captures, so such a call is run-time only through its arguments.
  - *No generated function is called with arguments all known at compile time.* Roc would evaluate
    the call while checking, and a generated function can overflow `I64` or fail to terminate. A
    product is written only with a run-time left factor, for the same reason.
  - *No redundant comparison*, `x == x`, and no `Bool` equality at all: Gleam warns on the first, and
    TypeScript narrows a `boolean` through aliases, after which `===` is an error.
  - *A pair scrutinee prints as two subjects in Gleam* (`case x, y`), which warns on a tuple built
    only to be matched.
  - *A mutually recursive group is used outside itself at one instantiation* (§6.2).
  - *A parameter is never only passed back to its own function*: Gleam reports it unused.
  - *An argument for a parameter its callee ignores is a leaf.* Nothing then fixes the argument's
    type, so an operator inside it (a lambda `\v -> v - x`) leaves a constrained type undetermined:
    ambiguous in PureScript, and defaulted to `Dec` in Roc, where it then fails to unify.

### 2.5 Roc: the Zig compiler, nominal types and static dispatch

**Amended 2026-09-27 (the owner):** the Roc measured is the **new compiler written in Zig**, built
from `roc-lang/roc` `main` at a pinned commit (§8.1), not the nixpkgs Rust alpha4, which is not run
at all. This section replaced one on alpha4's structural tag aliases.

The Zig compiler organises code in **type modules**: `Inf003.roc` must declare a type named
`Inf003`, and only that type's associated items are exported. Every generated module is therefore a
*void module*, `Inf003 :: [].{ … }`, whose block holds the module's types and functions, and
another module refers to them as `Inf003.f12` and `Inf003.T4`. A recursive type must be nominal
(`:=`), so every type of the program is a nominal tag union, `T4(a) := [C4a(a, I64), C4b]`, which
is the same work as the other languages' declared types. Its constructors are always written through
their type, `Inf003.T4.C4a(x, 1)` in an expression and in a pattern (§19 V1), because a bare tag
in an unannotated declaration is a structural tag and would not unify with the nominal type.

Two differences remain and are disclosed beside Roc's column (§10.7):

- **Operators are static dispatch.** `+`, `-`, `*`, `==` and `<` desugar to the operand type's
  `plus`, `minus`, `times`, `is_eq` and `is_lt` methods, and an unannotated numeric operand carries
  a method constraint until its type is known. The other ML-family checkers resolve these as fixed
  operators (or, in PureScript, as type classes).
- **Numeric literals default rather than generalise.** An unsuffixed literal whose type nothing
  fixes defaults to `Dec`. The program's own `Int` is `I64` and its `Float` is `F64`, which every
  annotation, and every inferred use that reaches one, fixes.

### 2.6 TypeScript

TypeScript is the one language outside the ML family. Its printer maps each node of the subset as
follows. The probe of 2026-09-27 (tsc 7.0.2, the settings of §9.1) accepted every shape below.

| Construct | TypeScript | Note |
|---|---|---|
| `Int`, `Float`, `String`, `Bool` | `number`, `number`, `string`, `boolean` | `Int` and `Float` collapse, so TypeScript never checks that distinction. |
| custom type | `export type T<a> = { readonly tag: "C4a"; readonly f0: a; readonly f1: number } \| { readonly tag: "C4b" }` | This is a discriminated union. Each tag is the globally unique constructor name (§2.4), so no two unions overlap. |
| constructor | a generic function per constructor: `export function C4a<a>(f0: a, f1: number): T<a> { return { tag: "C4a", f0, f1 }; }` | The constructor declarations belong to the program, as the other languages' type declarations do. |
| `case` | Nested `switch (v.tag)` statements printed straight from §3.6's split tree. Pattern variables become `const x = v.f0` inside the `case` block, and each switch ends with `default: return Base.absurd(v)`, where `absurd(x: never): never`. | TypeScript has no native exhaustiveness check, so narrowing to `never` is the idiomatic equivalent. It is the same work in kind: narrowing, then assignability to `never`. `Bool` splits print as `if`/`else`, and literal splits print as `switch (v)` with a `default` for the variable leaf. |
| pair | `readonly [A, B]`, with `v[0]` and `v[1]`; built by `Base.pair(a, b)` | **Amended 2026-09-27 (§19 V8):** an array literal with no contextual type is an array, not a tuple, and `as const` gives literal types that later comparisons trip on, so a pair is built by a generic helper in `Base`, which is constructor application, as PureScript's `Tuple` is. |
| list | `ReadonlyArray<A>` and array literals. `map`, `filter` and `reduce(fn, init)` stand in for `foldl`. | |
| `let` | `const`, and `let` for a `number`, `string` or `boolean` | **Amended 2026-09-27:** a `const` of a literal has the literal's type, and `let` widens it, with no annotation. A binding whose value reads a narrowed local writes its type (§19 V8). |
| `if` | `if`/`else` statements in tail position, a conditional expression elsewhere | |
| lambda | an arrow function | |
| function type | `(p0: A, p1: B) => C` | |
| generic function | `function f<a, b>(…)` | Type parameters are always declared, because parameters are always annotated (§6.3). |
| mutual recursion | `function` declarations | These are hoisted. |
| `++`, `Int` → `String`, pipeline | `+`, `String(n)`, a nested call | TypeScript has no pipe operator. A unary pipeline prints as nested calls, which the checker sees as the same calls. |
| qualified name | `import * as Inf003 from "./Inf003"`, then `Inf003.f12` and `Inf003.T4<number>` | |

**Statement form.** Function bodies are blocks that end in `return`. A `case` or `let` in
**non-tail** position prints as an immediately invoked arrow, `(() => { … })()`, because
TypeScript has no expression form for either. Families keep these rare: most `case` and `let`
nodes are generated in tail position, and each unit reports how many invoked arrows its TypeScript
text contains (§5.3).

**Explicit type arguments.** TypeScript does not infer a type argument from later uses. It
infers from the arguments and the contextual type only. Wherever the tree shows that a type
argument cannot come from either, the printer writes it: `Base.SNil<number>()`,
`[] as ReadonlyArray<number>`, and `xs.reduce<Seq<number>>(…)`. The generator knows exactly where
these are needed, and each unit reports how many it wrote.

**Caveats, always printed beside TypeScript's column (§10.7).**

- **Assignability is structural.** Two unions of the same shape are one type. Checking an
  argument compares shapes member by member, and TypeScript caches the result by type identity.
  None of the ML-family checkers does this work. Globally unique tags keep the program's unions
  disjoint, but the work is still a different kind.
- **The algorithm is different.** TypeScript does no global unification. It uses local,
  bidirectional inference: type arguments come from arguments and from contextual types, and a
  parameter's type is never inferred from how the body uses it. So "the same program" does not
  mean "the same algorithm". The comparison is the cost of checking the same program in each
  language's own idiom.
- **The spelling differs.** TypeScript has no `Int`/`Float` split, always carries parameter
  annotations (§6.3), writes the explicit type arguments above, and uses invoked arrows for
  non-tail `case` and `let`.

## 3. The generator

### 3.1 Where it lives

`bench/compare/gen/` is its own build target, separate from the compiler. It does not import
`src/` and `src/` does not import it.

| File | Role |
|---|---|
| `main.zig` | The CLI (§12): `gen`, `run`, `all`, `smoke`. |
| `Rng.zig` | A SplitMix64 PRNG, written here. `std.Random`'s algorithms may change between Zig releases, and the output must depend only on this directory. |
| `Type.zig` | The type store (§3.3). |
| `Tree.zig` | The typed program tree (§3.4). |
| `synth.zig` | Expression and pattern synthesis (§3.5, §3.6). |
| `families/*.zig` | One generator per family (§4), each producing modules into the tree. |
| `validate.zig` | The oracle (§3.7). |
| `print/{beni,elm,gleam,roc,purescript,typescript}.zig` | The printers (§3.8), plus `print/count.zig`, the token counter (§5.3). |
| `runner.zig`, `fit.zig`, `report.zig` | Process spawning and timing, the fit, and the JSON and README writers (§10, §13). |
| `templates/<lang>/` | Committed project scaffolding: `elm.json`, `gleam.toml` + `manifest.toml`, `spago.dhall` + `packages.dhall`, `tsconfig.json`. These are configuration, not generated code. |

The runner is written in Zig as well, so the whole benchmark needs one toolchain plus the tools
under test. `run.mjs`'s logic moves across unchanged (§10).

**As built (2026-09-27).** The layout differs from the table above in four places, none of which
changes a contract: the eight families are one file, `families/families.zig`, with what they share
in `families/common.zig`; the five ML-family printers are one layout engine, `print/ml.zig`, whose
per-language spelling is a `switch` on the language, beside `print/typescript.zig`, with
`print/print.zig` (headers, the entry forms of §7.2, projects) and `print/common.zig`; the goldens
of §15 live in `print/golden/`; and the runner is `runner.zig` (options) plus `runner_impl.zig`
(process spawning, preparation, warm-up, rounds). `base.zig` builds `Base`, `analyse.zig` is the
pass between synthesis and printing (unused bindings, recursion, imports, sizes), `names.zig` the
keyword lists, and `lib.zig` the module `tests/blackbox/compare_gen_test.zig` imports.

### 3.2 Determinism

`(seed, size, annotate, generator hash)` → byte-identical files in all six languages. Each module
is a pure function of `(seed, family, unit index)`. Its RNG stream is
`SplitMix64(hash(seed, family, unit))`. Consequences:

- **The project at size k is a prefix of the project at size 2k.** Units 1…k are identical, so the
  scaling is additive, as N copies were, but every unit has different content.
- **Families are independent,** so a family-only project contains exactly the modules that the
  total project contains for that family.
- **The generator hash** is a SHA-256 over `bench/compare/gen/**` (sources and templates),
  computed by `build.zig` and passed in as a build option. Every results file records it (§13).

### 3.3 Types

The type store interns types as indices:

- `Int`, `Float`, `String`, `Bool`;
- `Pair(a, b)`, `List(a)`, `Fn([params], ret)`;
- `Named(decl, [args])`;
- `Var(i)`, which occurs only inside a generic declaration's signature and body.

Every `Named` type records its **minimum constructible depth**: the fewest nested constructor
applications that build a value of it from literals. A type declaration is rejected at generation
time unless that depth is finite, which makes every generated type inhabited.

### 3.4 The typed tree

A `Program` is a list of `Module`s. A module holds:

- its imports;
- its type declarations (parameters, constructors, and each constructor's field types);
- its function declarations (parameters with types, a result type, generic variables, a body, and
  an `annotated: bool`).

Expressions are a flat `MultiArrayList`, in the house style. Each node carries its **type**, and
the variants are:

`lit_int · lit_float · lit_string · lit_bool · local · global(decl, type args) · call(fn, args) ·
lambda(params, body) · let(bindings, body) · if · case(scrutinee, branches) · ctor(ctor, args) ·
pair · list · binop(op) · not · int_to_string · list_map · list_filter · list_foldl · pipe(stages)`

`binop` ops are typed: `int_add`, `float_add`, `str_append`, `int_lt`, `str_eq` and so on. A
pattern is `wild · bind · lit_int · lit_string · lit_bool · ctor(ctor, pats) · pair`.

The tree has no syntax in it. Associativity, parentheses, layout and naming conventions belong to
the printers.

### 3.5 Expression synthesis

`synth(want: Type, scope, budget) → Expr` is type-directed. The target type is chosen first, and an
expression is then built only from productions that yield it:

1. an in-scope local of type `want`;
2. a global whose instantiated result unifies with `want`, with its arguments synthesised
   recursively;
3. a constructor of `want` (when `want` is `Named`), with its fields synthesised;
4. a literal (for a base type);
5. `pair`, `list`, or an operator;
6. a wrapping form: `if`, `case` on an in-scope value, or `let` that binds a fresh value and
   continues.

The weights come from the family (§4). `budget` falls with depth. At zero, only leaves are
allowed: locals, literals, nullary constructors, or the minimum-depth constructor path (§3.3). This
makes synthesis terminate.

A generic function's body sees values of type `Var(i)` only through its parameters. Literals never
produce one.

The variation of O5 comes from loops over shapes: each family iterates over arity, depth, width and
type choices, and draws the rest from the RNG.

### 3.6 Pattern synthesis

A `case` is generated as a **split tree**, so it is exhaustive and non-redundant by construction.
Starting from the scrutinee's type, each position either becomes a variable or `_`, or it splits
into every constructor of its type (or `True`/`False`), recursively up to the family's depth.

- The leaves become the branches, in order.
- A split on `Int` or `String` takes k literals plus a final variable.
- A branch that binds nothing and repeats an earlier branch is impossible, because every leaf is a
  distinct region of the value space.

The number of leaves is capped per family (§4) and recorded in the size counts.

### 3.7 The oracle

`validate.zig` re-checks the finished tree independently of synthesis. It checks that:

- every node's recorded type agrees with its children (calls against the instantiated signature,
  constructors against their fields, branch bodies against each other);
- every `case` is exhaustive and non-redundant, checked by the usefulness algorithm over the tree's
  own patterns;
- no name is shadowed and every name is unique where §2.4 requires it;
- every import is used, and the import graph is a DAG;
- no construct outside §2.1 appears;
- the tree would still type-check with every annotation removed. The oracle runs a small HM over
  each SCC, so the two modes of §6 print the same tree.

**Added 2026-09-27.** Two more HM runs over the same tree feed printers, not the verdict: one in
which a numeric literal is a fresh variable and an arithmetic operator unifies its operands
(Roc's view, `validate.rocDefaulted`, §19 V2), and one in which the operators of §2.1 constrain
their operand type instead of fixing it (PureScript's type classes, `validate.psAmbiguous`,
§19 V10). The oracle's own run also treats every use of a mutually recursive group's member
outside the group as one shared type (Elm's rule, §6.2, §19 V9).

The oracle runs before every print, and a failure aborts with the seed, family, unit and
declaration. It is the first line of defence. The six real compilers are the confirmation (§11).

### 3.8 Printers

One file per language. Each is a function `(Program, Module) → bytes`, plus project scaffolding
built from `templates/`. Each printer owns:

- syntax (§2.2);
- module headers and imports (Elm `module … exposing (..)`, Gleam's file paths, Roc's
  `module [...]`, PureScript `module … where` with `import Prelude`, TypeScript's `import * as M from "./M"`, beni's headerless files);
- operator spelling and precedence (it parenthesises from the tree's shape, never from the
  source);
- annotations (only where `annotated`, with PureScript's `forall`, and TypeScript's rule of §6.3);
- the entry module (§7.2).

The printers aim at each formatter's layout, but that is not required. Only acceptance is (§11).
Each printer also returns its token and non-blank-line counts (§5.3).

## 4. Families

Each family owns one concern. A **unit** of a family is one module of it (§5.1). Every family
imports `Base`. Within a family, unit k may import only units < k of the same family.

| Family | Prefix | The concern | One unit contains |
|---|---|---|---|
| inference | `Inf` | Long unannotated dependency chains. Types flow backwards from uses. | 3 chains of 12 functions, each calling its predecessor and passing lambdas whose parameter types are fixed only by the callee. Also let blocks of 6–10 bindings whose types come from later uses. |
| polymorphism | `Poly` | Generic functions and generic types instantiated at many types. | 8 generic functions (arity 1–4, 1–3 type variables, higher-order: apply, compose-by-hand, fold over `Base.Seq`) and 30 call sites at distinct instantiations, including nested ones such as `Seq (Pair Int (Seq String))`. |
| patterns | `Pat` | Exhaustiveness and nested patterns. | 2 wide types (16–32 constructors, 0–3 fields). Cases 3–4 deep over pairs of them and over `Seq`, with at most 64 leaves each (§3.6), plus literal splits on `Int` and `String`. |
| depth | `Deep` | Expression depth. | Operator chains of 50–200 operands, nested calls 20–40 deep, nested `if`/`let`/`case` 10–20 deep, and pipelines of 20–50 unary stages. |
| recursion | `Rec` | Large mutually recursive groups. | One SCC of 16–48 functions over `Seq` and `Int`, some generic (used only at their own variables, §6.2), plus two small SCCs. |
| data | `Data` | Many types, many fields, construction and access. | 10 types with 1–4 constructors of 2–12 fields. For each type: accessors (a one-branch `case`), "updates" (case and rebuild), and builders that nest them. |
| imports | `Imp` | A wide and deep import graph with many qualified references. | 6 small types and 12 small functions whose bodies make 40–80 qualified references into up to 8 earlier `Imp` units. Depth grows with k and fan-in stays constant, so the per-unit cost stays constant. |
| everyday | `Day` | A realistic mix at typical sizes. | 3 domain types (3–8 constructors), 15 functions of 5–30 lines, `map`/`filter`/`foldl` pipelines, string building, 2–6-branch cases, and a mix of annotated and inferred helpers under the global ratio (§6). |

The numbers above are the **initial calibration**. They are fixed in each family's source, and a
change to them changes the generator hash. Each family's unit is calibrated to about **1 500 tree
nodes**, measured and recorded, so that the families are comparable in weight. They are not
identical: the report normalises by nodes (§5.3).

## 5. Size

### 5.1 Units and sizes

`--size=k` means k units of every selected family. The benchmark measures at k ∈ {1, 2, 4, 8, 16}
(`--sizes`). `Base` and `Main` are the constant part and fall into the intercept, except that
`Main` grows by one import and one call per module. That growth is part of every language's slope
alike.

### 5.2 Projects measured

For each language, mode (§6) and size, the benchmark measures:

- one project per family, containing `Base`, that family's k units and `Main`;
- one **total** project, containing every family's k units.

### 5.3 Comparable size

The generator knows the program exactly, so size is counted from the tree, not from any one
language's text:

- **nodes**: expressions, patterns, type expressions and declarations, per module;
- declarations, annotated declarations, and `case` leaves.

The headline normaliser is **ms per 1 000 nodes**, which is identical for every language by
construction.

Each printer also reports **tokens** (one shared counting rule in `print/count.zig`: a literal, a
word, a run of operator characters, one bracket or comma; comments excluded) and non-blank lines.
These are recorded so the spelling cost of §2.2 stays visible, but they never normalise the
headline. The TypeScript printer also counts its explicit type arguments and invoked arrows
(§2.6). **Annotations** are counted per printer (2026-09-27): in the ML family, each declaration
printed with a signature, plus each binder PureScript types (§19 V10); in TypeScript, each
annotation site written: a parameter, a return type, a lambda parameter and a typed binding.

## 6. Annotations

### 6.1 The parameter

`--annotate=P` (0–100) is the percentage of generated top-level functions that carry a full
signature. The choice per declaration is a deterministic draw from the unit's stream, taken
**after** the body is built, so P never changes the tree, only which signatures are printed. Two
modes are published:

- **annotated**: P = 100. This is the headline, because top-level signatures are the convention in
  every one of the languages.
- **inferred**: P = 0, except for the entry declarations (§7.2).

Lambdas and `let` bindings are never annotated, in either mode, except in TypeScript (§6.3).

### 6.2 What makes P free

Because the same tree is printed with and without signatures, the tree must be inferable with none
of them. Two rules follow, both enforced by the oracle:

- **No polymorphic recursion:** inside an SCC, a generic member is used only at its own type
  variables.
- **No use of a generic `let`** (V3).
- **A mutually recursive group is used outside itself at one instantiation** (added 2026-09-27,
  §19 V9). Elm does not generalise an unannotated group of two or more mutually recursive
  functions: every use outside the group shares one type. A generic member of such a group
  therefore records the one instantiation it may be used at (`Fn.mono_targs`, `Int` for the
  recursion family), and the oracle's HM treats every outside use of such a member as that one
  shared type.

Inference may find a more general type than the generator chose, for example `a -> a` for an
`Int -> Int` identity, or `number` in Elm and `Num *` in Roc for arithmetic. That is still
well-typed at every use.

### 6.3 What annotation means in TypeScript

TypeScript does not infer a parameter's type from how the function body uses it. Under
`noImplicitAny` (§9.1), an unannotated parameter is an error. A return type that depends on a
recursive call is also an error, TS7023, which the 2026-09-27 probe confirmed for both
self-recursion and mutual recursion. In TypeScript, P therefore controls only what TypeScript can
infer:

| Position | P = 100 | P = 0 |
|---|---|---|
| top-level parameters and type parameters | written | written |
| top-level return type, non-recursive declaration | written | inferred |
| top-level return type, member of a recursive SCC | written | written |
| lambda parameter passed where a function type is expected | inferred from context | inferred from context |
| lambda bound by `let` (no context) | parameters written | parameters written |
| lambda anywhere else without a contextual type: returned from a function with no written return type, inside an invoked arrow, a pair or a list (amended 2026-09-27) | parameters written | parameters written |
| `const` locals | inferred | inferred |

This is a **documented asymmetry**. TypeScript's inferred mode carries more annotations than any
other language's, and its annotated-mode and inferred-mode runs differ less than the others' do.
The generator counts the annotations it wrote per mode and records them (§13). Both TypeScript
columns carry a footnote pointing here.

## 7. The project

### 7.1 `Base`

`Base` is one fixed module per project:

- `Seq a = SNil | SCons a (Seq a)`;
- `Opt a` and `Res e a` (the program's own `Maybe` and `Result`);
- a `Pair`-based helper or two;
- ten generic list functions over `Seq`, written by recursion.

It is identical in every size, so it is in the intercept.

### 7.2 `Main` and entry forms

Every module exports `entry : Int -> Int`, which calls a few of its own functions. `Main` imports
every module and sums their entries, so every module is reachable in the languages that check only
what `Main` reaches (Elm, Roc). The printers own the wrapper:

| Language | Wrapper |
|---|---|
| beni | The `node` platform's program. |
| Elm | `Platform.worker`, with elm/json in the template for flags. |
| Gleam | `pub fn main()` plus `io.println(int.to_string(…))`. gleam_stdlib 1.0.5 has no `io.debug` (§19 V2, 2026-09-27). |
| Roc | A void type module `Main :: [].{ total : I64 -> I64 … }`, so no platform is checked (amended 2026-09-27, §2.5). |
| PureScript | `main :: Effect Unit` plus `log`. |
| TypeScript | `Main.ts` exports `total`. There is no platform, and `lib` is `es5` only (§9.1). |

These are what the earlier method did. They are in the intercept and are disclosed.

### 7.3 Module names

Module names are flat: `Inf003`, `Pat012`, and `inf003` in Gleam. This avoids hierarchical module
semantics, and avoids Gleam's last-segment qualifier colliding across families.

## 8. Toolchains

### 8.1 A separate dev shell with its own pin

The compiler's toolchain is deliberately pinned to `nixos-26.05`, and it must not move for a
benchmark. `flake.nix` gains:

- an input `nixpkgs-compare`, a nixos-unstable revision (`b1b8759`, 2026-09-16, the host's own
  unstable pin, so every tool was already in the store), locked in `flake.lock`;
- an output `devShells.<system>.compare`, `inputsFrom = [ default ]`, adding
  `elmPackages.elm`, `gleam`, `purescript`, `spago` (the legacy 0.21 that reads
  `spago.dhall`), `typescript` and `util-linux` (`taskset`, `unshare`) from `nixpkgs-compare`.

**Roc is not from nixpkgs (amended 2026-09-27, the owner).** nixpkgs packages only the Rust
alpha4 compiler, which is not measured. The Zig compiler is built from source by `--prepare`
(§8.2): `roc-lang/roc` at the commit pinned in `bench/compare/gen/main.zig`
(`a3ce7f1bb784b6cb0c3f5f05acd2cd8a762ed3e0`, `main` on 2026-09-27), fetched with `git`, and built
with `zig build roc -Doptimize=ReleaseFast`. Its `build.zig.zon` requires Zig 0.16.0, which is
exactly the Zig of beni's own pin, so the compare shell's `zig` builds it and beni's pin does not
move. Zig's package hashes make the dependency fetch content-addressed. Roc's own flake
(`src/flake.nix`) was not used: it is a development shell, and packaging the build in nix would
fetch the LLVM archives of all eight of its targets. Bumping Roc means changing the pinned commit.
The results file records it and `roc version`.

`nix develop .#compare` enters it. `zig build compare` checks for every tool on `PATH` first, and
names the missing ones and that command if any are missing.

Upgrading a compiler under test means bumping `nixpkgs-compare` alone, and the results file records
the locked revision (§13). The flake lock is read from `flake.lock` by the runner.

### 8.2 Dependencies

Dependencies are fetched once, online, and never during a timed run.

`zig build compare -- --prepare` fills `bench/compare/work/deps/`, keyed on the templates' hash:

- `ELM_HOME` pointing there, not at `~/.elm`;
- Gleam's `build/packages`;
- PureScript's `.spago` and a deps-only `output/`;
- the Roc compiler of §8.1, in `work/deps/roc-src/`, keyed on its pinned commit.

Every template pins exact versions: `elm.json` exact, Gleam's committed `manifest.toml` with its
checksums, and `packages.dhall` with its hash. The later runs copy or link these into each
generated project.

## 9. Check-only commands

The table is part of the contract. A change is a new row version and a note in the results file.

| Tool | Timed command | Work it includes beyond parse + resolve + infer + exhaustiveness | Cleared before each run |
|---|---|---|---|
| beni | `beni check --no-cache --jobs=1 --platform=node .` | Also checks embedded `core/` and the node platform. Writes nothing. | `.beni-cache/` |
| Elm | `elm make src/Main.elm --output=/dev/null +RTS -N1 -RTS` | Writes `.elmi`/`.elmo` per module. No JS. Checks elm/core's artifacts. | `elm-stuff/` |
| Gleam | `gleam check` | Writes cache artefacts. JS target. No thread switch, so `taskset` alone limits it. | the project's `build/dev/javascript/compare/` |
| Roc (v2, 2026-09-27) | `roc check --no-cache --jobs=1 Main.roc` | Writes nothing: with `--no-cache` no `~/.cache/roc` is created. Builtins are in the binary. `--jobs=1` runs one OS thread (§19 V2). **Most of the command is not type checking** (amended 2026-09-28, after a CPU profile at `a3ce7f1` of the total project at size 16): about 33% is type inference and exhaustiveness (about 28 ms per unit, 5.5× beni), 39% publishes a hashed checked-module artifact for its monomorphising native backend (`CheckedTypeStore.fromModule` and its helpers, always on in `check`), 13% is canonicalisation, 10% lowering, native code generation and compile-time evaluation (the phase `--timings` calls *Shared Lowering and Compile-Time Evaluation*), and 2% parsing. In the recursion family canonicalisation, mostly its dependency graph, is 52% of Roc's time. `--timings` counts the publishing as *Type Checking*, so no figure is derived from it: the README reports Roc's row as what it is, the cost of Roc's `check` command, and gives the profile's split beside it (§10.7). The warm-up still runs with `--timings` and the results file keeps the *Shared Lowering* time per size, unreported. The measurement is fair: Roc is built as its releases are (ReleaseFast, musl, baseline CPU), and `--no-cache --jobs=1` is its fastest cold single-thread configuration. v1 was alpha4's `--max-threads 1`. | nothing |
| PureScript (v2, 2026-09-27) | `purs compile '<deps>' 'src/**/*.purs' -o output --codegen corefn +RTS -N1 -RTS` | CoreFn and externs for every project module, and re-parsing every dependency module. No JavaScript: V5 found `--codegen corefn` still type-checks every module. v1 was the default `js` codegen. | `output/`, then the deps-only `output/` is restored untimed |
| TypeScript | `GOMAXPROCS=1 tsc -p . --singleThreaded` (with `noEmit` in `tsconfig.json`) | Parses and binds `lib.es5.d.ts` (never checked: `skipLibCheck`). Unused-name analysis (`noUnusedLocals`/`Parameters`). Writes nothing. §9.1. | nothing: no `incremental`, so no `.tsbuildinfo` |

The beni under test is a **ReleaseFast** build made by the `compare` step itself. It is never
`zig-out/bin/beni`, which may be a Debug build.

### 9.1 TypeScript: which compiler, which switches, which settings

**The compiler.** This is TypeScript 7, the native port written in Go. It shipped as the ordinary
npm package `typescript`, whose `latest` tag is `7.0.2` (published 2026-07-08). Its binary is
`tsc`, a statically linked Go executable, with one platform package per OS and architecture.
`@typescript/native-preview` (binary `tsgo`) was the preview line. Its last version is
`7.0.0-dev.20260707.2`, and TypeScript 7 supersedes it. nixpkgs-unstable packages `typescript`
at 7.0.2, and its old `typescript-go` attribute is now an alias for the same package. The compiler
is therefore pinned like every other tool, through `nixpkgs-compare` (§8.1). No npm lockfile and
no Node are needed to check. The results file records `tsc --version`.

**Single thread.** 7.0.2's `tsc --all` lists three concurrency options:

- `--singleThreaded`: "Run in single threaded mode";
- `--checkers N`: "Set the number of checkers per project";
- `--builders N`: projects built concurrently. This is irrelevant for one project.

The timed run uses `--singleThreaded`, which turns off concurrent parsing and binding and the
checker pool. `GOMAXPROCS=1` limits the Go runtime, including its garbage collector's workers, to
one OS thread running Go code at a time, and `taskset` enforces the core. V7 confirms by thread
count and `--extendedDiagnostics` that this is one checker, the same as `--checkers 1`.

**`tsconfig.json`** is committed in `templates/typescript/`:

```json
{ "compilerOptions": {
    "strict": true, "noImplicitReturns": true, "noFallthroughCasesInSwitch": true,
    "noUnusedLocals": true, "noUnusedParameters": true,
    "noEmit": true, "skipLibCheck": true, "lib": ["es5"], "types": [],
    "target": "es2022", "module": "esnext", "moduleResolution": "bundler" },
  "include": ["src/**/*.ts"] }
```

Why each setting:

- **`strict`** is required, not a preference. Without `noImplicitAny`, an unannotated parameter
  silently becomes `any` and its uses go unchecked. That would time less work and would break O9
  in spirit: an `any` program is not a type-checked program. `strictNullChecks` and
  `strictFunctionTypes` (contravariant parameters) are the sound settings, and they match what
  the ML-family languages guarantee.
- **`noUnused*`** is on because Elm, Gleam, Roc and PureScript all analyse unused names, and the
  generator emits none (§2.4). Wildcard parameters print as `_1`, `_2` and so on, which the rule
  exempts.
- **`noImplicitReturns` and `noFallthroughCasesInSwitch`** hold for the printed statement form,
  and they make a printer bug an error rather than silent.
- **`skipLibCheck`** skips checking `lib.es5.d.ts`. That matches the others, whose standard
  libraries are precompiled or embedded and not re-checked. The file is still parsed and bound,
  which lands in the intercept.
- **`lib: ["es5"]`** is the smallest library that has `ReadonlyArray`'s `map`, `filter` and
  `reduce`.
- **`types: []`** keeps `@types` out.

## 10. Measurement protocol

These rules are kept from the earlier method, where they worked.

1. **Cold.** The cache is cleared before every sample (§9).
2. **Offline.** Every sample runs under `unshare -rn`. If that is unavailable, the run aborts unless
   `--online` is given, and the results file then records `offline: false`.
3. **Single core.** Every sample runs under `taskset -c <cpu>` (default 2), plus the tool's own
   switch (§9).
4. **Warm-up doubles as confirmation.** Every project is run once untimed. That run is also the
   §11 acceptance check.
5. **Interleaved.** Round i of every (language, mode, project, size) point is taken before round
   i+1 of any. The order within a round is a permutation drawn from `(seed, i)`.
6. **Statistics.**
   - Each point is the median of R samples (default 7; it was 5 until 2026-09-28).
   - The fit is an OLS fit over the medians at the sizes of §5.1: **slope = ms per unit**, and
     intercept = fixed cost. R² is recorded, along with the same fit over each point's minimum.
   - Per-family and total slopes are also given per 1 000 nodes (§5.3).
   - The **additivity check** divides the sum of the family slopes by the total slope. It is
     recorded, and a value outside 0.8–1.2 is flagged in the README.
   - Wall time is measured around the spawn, which includes the spawn itself. **CPU time is the
     headline** (amended 2026-09-28): user + sys from `wait4`'s rusage, which counts the compiler
     and every child it reaped (`unshare` and `taskset` exec the compiler rather than fork it). It
     is less sensitive to a shared machine than wall time, which is recorded beside it.
   - The sizes are spaced geometrically, so an OLS fit weights the largest size most: the slope is
     mostly the step from 8 to 16 units. Small sizes still anchor the intercept.
7. **Disclosed differences.** The README carries §9's work column, §2.2's Gleam-`case` and
   PureScript-instance notes, §2.5's Roc note, §2.6's TypeScript caveats and §6.3's annotation asymmetry (as a footnote on every TypeScript cell), the machine, and the load averages at the start
   and end. `--multi` drops rule 3 and is never headline. Added 2026-09-28: Roc's compile-time evaluation (§9) and Elm's `-A128m` runtime default, which inflates its single-family slopes and leaves its total row unaffected (§18 status). **Amended 2026-09-28, after a profile of Roc:** Roc's row is labelled as the cost of Roc's `check` command, never as its type checking; beside it the README gives §9's dated phase split (profiled at Roc `a3ce7f1`, the total project at size 16), flags Roc's recursion column, where canonicalisation is 52% of its time, and gives no figure derived from `--timings`, which counts Roc's artifact publishing as type checking. The side figure "less compile-time evaluation" that the README carried until then read as Roc's checking time and is withdrawn.

## 11. Confirmation, and a compiler that says no

The oracle (§3.7) guarantees well-typedness in the tree. The compilers confirm it. A non-zero exit,
or any error on stderr, during warm-up is a **generator bug**, by definition (O9). The runner then:

- stops at once and writes no results;
- keeps the project directory;
- prints the language, mode, family, size, seed, generator hash, the first failing module's path,
  the compiler's full output, and the exact reproduction command
  (`zig build compare-gen -- --seed … --size … --families … --annotate … --langs …`).

There is no retry, skip or partial table. A compiler bug found this way is fixed in the generator
by avoiding the construct, recorded in §19, and linked to an upstream issue.

**Acceptance, per language (2026-09-27).** A zero exit is required everywhere. Beyond it, Gleam,
which exits 0 with warnings, must print no line starting `warning`; PureScript may print only the
`MissingTypeDeclaration` warning (it names each warning by its documentation link); and beni may
print only `ambiguous_method_receiver` (*constraint in an inferred interface*), the warning on a
`pub` declaration without an annotation whose inferred type carries a method constraint, which the
inferred mode produces where `==` compares values nothing else fixes. Roc and TypeScript exit non-zero on anything, and Elm has no warnings.

A timeout counts the same way. The per-sample limit is 300 s by default (`--timeout`), and a run
over it fails loudly: an unmeasurable point is not silently dropped from a fit.

## 12. Commands

| Command | What it does |
|---|---|
| `zig build compare-gen -- --seed=S --size=K [--families=…] [--langs=…] [--annotate=P] [--out=DIR]` | Writes one project per (language, family set) into `DIR`, which defaults to `bench/compare/work/gen/`. Prints the node and token counts. |
| `zig build compare -- [--prepare] [--seed=S] [--sizes=1,2,4,8,16] [--runs=7] [--langs=…] [--modes=annotated,inferred] [--cpu=2] [--quick] [--label=…]` | Does everything: generate, prepare the dependencies if needed, warm up and confirm (§11), benchmark (§10), then write `bench/compare/results/<date>[-<label>].json` and rewrite the README table (§13). |
| `zig build compare-smoke` | Size 1, both modes, runs 1: acceptance by all six compilers and no timing. It lives in the compare shell and is not in the three gates. |
| `zig build compare -- --prepare` (amended 2026-09-27) | Fetches and builds the dependencies of §8.2, Roc included, and stops. A plain `zig build compare` also prepares whatever is missing first. |
| `zig build compare-gen -- --golden` (added 2026-09-27) | Rewrites the printer goldens of §15 in `gen/print/golden/`. |
| `zig build compare-render -- --from=bench/compare/results/<name>.json` (added 2026-09-28) | Rewrites the README block of §13.2 from a committed results file, with no compiler run. It prints the fits the run recorded, so a change to how the tables are worded reaches the published numbers without re-measuring; a figure recorded to one decimal more than the table prints can round differently in its last digit. |

- The default seed is fixed in `main.zig` (`0xBE11C0DE`), so the published tables are reproducible
  with no arguments.
- `--quick` means sizes {1, 2, 4} with runs 3.
- `bench/compare/work/` is added to `.gitignore`. Generated code never leaves it (O7).

## 13. Results

### 13.1 JSON

`bench/compare/results/<date>[-<label>].json` is committed:

```json
{
  "schema": 2,
  "date": "2026-10-01T12:00:00Z",
  "generator": { "hash": "sha256:…", "seed": "0xBE11C0DE", "sizes": [1,2,4,8,16], "runs": 5,
                 "unit_nodes": { "inference": 1512, "…": 0 } },
  "machine": { "cpu": "…", "nproc": 32, "kernel": "…", "cpu_pinned": 2,
               "loadavg": { "start": [0,0,0], "end": [0,0,0] } },
  "offline": true,
  "toolchain": { "nixpkgs_compare_rev": "…", "zig": "0.16.0", "beni_commit": "…", "beni_dirty": false },
  "lang_order": ["beni", "elm", "gleam", "roc", "purescript", "typescript"],
  "langs": {
    "elm": {
      "version": "0.19.2", "command": "elm make … (§9 row v1)",
      "modes": {
        "annotated": {
          "projects": {
            "inference": {
              "size": { "1": { "nodes": 0, "tokens": 0, "lines": 0, "modules": 0,
                               "annotations": 0, "explicit_type_args": 0, "invoked_arrows": 0 } },
              "samples": { "1": [0.0] }, "medians": { "1": 0.0 },
              "slope_ms_per_unit": 0.0, "slope_min": 0.0, "intercept_ms": 0.0, "r2": 1.0,
              "ms_per_1k_nodes": 0.0, "ms_per_1k_tokens": 0.0
            },
            "total": { "…": "same shape" }
          },
          "additivity": 1.0
        },
        "inferred": { "…": "same shape" }
      }
    },
    "typescript": {
      "version": "Version 7.0.2", "command": "GOMAXPROCS=1 tsc -p . --singleThreaded (§9 row v1)",
      "config_sha256": "…", "modes": { "…": "same shape as elm" }
    }
  }
}
```

The file records:

- `beni_dirty`, set when the tree had uncommitted paths;
- every raw sample, so any fit can be redone later;
- per size, the annotations each printer wrote. For TypeScript it also records the explicit type
  arguments and the invoked arrows (§2.6), which are 0 for the other languages.

Every language key in `lang_order` appears under `langs`, including `typescript`. A run with
`--langs` omits the others and records the omission in `lang_order`.

The schema number bumps on any incompatible change. **Schema 2** (2026-09-28) replaces a project's `samples`, `medians`, `slope_ms_per_unit`, `slope_min`, `intercept_ms`, `r2`, `ms_per_1k_nodes` and `ms_per_1k_tokens` by `cpu_samples` and `wall_samples`, and two fits, `cpu` and `wall`, each with those fields; adds `"headline": "cpu"`; makes `additivity` a `{ cpu, wall }` pair; and for Roc adds `compile_time_evaluation_ms` per size and a `cpu_less_compile_time_evaluation` fit. Both stay in the file and are not reported (§9, §10.7).

### 13.2 README

`bench/compare/README.md` holds the method (a short summary pointing here), the versions and the
caveats. Between the markers `<!-- compare:results:begin -->` and `<!-- compare:results:end -->`,
the runner writes three tables:

1. total slopes per language × mode (ms/unit, ms/1k nodes, and ratios to beni);
2. per-family slope in ms/1k nodes, one table for the annotated mode;
3. the same for the inferred mode.

Below the tables, a footnote on Roc's row gives §9's profile split, and Roc's recursion cells carry its mark (§10.7). `compare render` regenerates the block from a results file (§12); the block is never edited by hand.

Outside the markers the README is hand-written, and the runner never touches it.

## 14. Runtime budget

On the reference machine (the 5950X the earlier method ran on), the defaults are expected to need:

- **≤ 30 min** for all six languages and both modes, of which PureScript is expected to take most;
- **≤ 5 min** without PureScript;
- **≤ 3 min** for `--quick` without PureScript.

After warm-up, the runner prints its measured estimate. If the estimate is over twice the budget,
it prints a warning and continues. Budgets are recalibrated in this section when the family sizes
of §4 change.

At the defaults, a round is about 1 M nodes per language per mode: 9 projects × 31 unit-sizes × ~1
500 nodes × 2 for the total project. The earlier method's rates put beni well under a second per round.

**Measured 2026-09-27/28** (a first full run, since discarded: its results file had been edited by
hand, and the review that followed changed the headline to CPU time; on the 5950X shared with
other builds, load averages up to 45): generation of the 540 projects and the warm-up took about
20 minutes, 647 s of it compiling, and the five rounds 52 minutes, about 73 minutes in all against
the 30 of the budget. PureScript is most of it: at size 16 one inferred total project takes it
about 70 s, beni 0.3 s. Not recalibrated yet: the budget is exceeded mainly by PureScript and by
the load, and the family units are lighter than §4's calibration, not heavier.

## 15. Testing the generator

- **Unit tests** in `bench/compare/gen/`, run by `zig build test`, because they are hermetic, as
  `bench/gen.zig`'s are:
  - determinism (two generations hash equal) and the prefix property (§3.2);
  - the oracle accepts every family at sizes 1–4 over 16 seeds;
  - the oracle **rejects** hand-built bad trees, one per rule of §3.7;
  - the pattern split tree is exhaustive and non-redundant (§3.6);
  - every generated name lies outside the six keyword lists;
  - one small golden per printer, for a hand-built tree covering each node kind.
- **`zig build compare-smoke`** (§12), run before any published measurement and in CI where the
  compare shell exists.
- **beni's printer in the gates.** `test-blackbox` gains one case: generate seed 1, size 1, both
  modes, beni only, and require `beni check` to exit 0. beni is the language that changes under
  this repository. Without this case a language change would silently break the benchmark until
  the next manual run. A failure there is either a beni regression or a printer that must follow
  the language.

## 16. What is replaced

When the generator lands:

- `bench/compare/{beni,elm,gleam,roc,purescript}/`, `gen.mjs` and `run.mjs` are deleted;
- `results/2026-09-27-*.json` stay, as a historical record of the hand-written ports;
- the README keeps one paragraph on them, with their headline ratios, marked as a different method
  that cannot be compared with the new tables.

## 17. Later: the error path

`--errors=E` injects E type errors into a copy of the tree after the oracle has passed. Each error
replaces one leaf with a literal of a different base type, at a node chosen from the RNG.
Acceptance inverts: every compiler must exit non-zero and report at least one error. It measures
time-to-diagnostics over the same program. It is not built in the first slices, and its results
are a separate file label.

## 18. Slices

| Slice | Contents | Done when |
|---|---|---|
| C0 | Probes for §19 V1–V8, by hand, in the compare shell. Results are recorded in §19. | §19 has no "to verify". |
| C1 | `flake.nix` compare shell, `Rng`, `Type`, `Tree`, `synth`, the oracle, `Base`, and the everyday family. The beni and Elm printers. `compare-gen`. Unit tests. | The oracle and unit tests are green, and beni and Elm accept size 4 in both modes. |
| C2 | The Gleam, Roc, PureScript and TypeScript printers, templates and `--prepare`. `compare-smoke`. The `test-blackbox` case. | All six accept everyday at sizes 1–16. |
| C3 | The other seven families. | The smoke run is green for every family. |
| C4 | The runner, fit, JSON and README. The old ports are deleted (§16). The first published run. | `zig build compare` completes within §14's budget and the results are committed. |

**Status, 2026-09-28.** C0–C4 have landed together: §19 has no "to verify"; the generator, the
oracle, all six printers, the runner, the results file and the README tables exist;
`zig build compare-smoke` passes and a full `zig build compare` has run once; the three gates are
green. The published run is to be made from a clean commit. What is open: the family units are
lighter than §4's 1 500-node calibration (542–1 560 nodes), and §14's budget was exceeded (73
minutes on a loaded machine). Elm's additivity near 2 is explained by its runtime options: the
`elm` binary's `-A128m` nursery makes single-family projects pay first-touch faults (with
`+RTS -A4m` its inference slope falls from about 6 to 2.7 ms/unit while its total slope stays near
29), so its per-family figures are upper bounds and its total row is unaffected.

## 19. Verification items

Each is settled by a probe program in every language. The finding is recorded here, and the
generator follows it.

| # | Question | Finding (2026-09-27, the compare shell at `nixpkgs-compare` = `b1b8759`) |
|---|---|---|
| V1 | Roc's spellings: boolean operators, list functions, `Int` → `String`, pairs and pair patterns, recursive and mutually recursive types across modules. **Re-asked 2026-09-27 of the Zig compiler** (`a3ce7f1`), when the owner replaced alpha4. | **Settled for the Zig compiler.** Modules are void type modules, `M :: [].{ … }`, holding every type and function as associated items; `import Base`, then `Base.slen(s)` and `Base.Seq(I64)`. Types are nominal, `Seq(a) := [SNil, SCons(a, Seq(a))]`, applied with parentheses, `List(I64)`, `(I64, Str)`, `A, B -> C`; mutually recursive nominal types in one module, referring to another module's type, check. Constructors are qualified through their type in expressions **and patterns**, `Base.Seq.SCons(x, Base.Seq.SNil)`, `T2.C2a(1, s) =>`: the probe checked this in unannotated declarations too, where a bare tag would be structural. `match x { p => e }`, `if c { a } else { b }` (no `then`), blocks `{ v = e ⏎ body }`, `\|x, y\| e`, `f(a, b)`, `and`/`or`/`!` (there is no `&&`), `True`/`False`, `Str.concat(a, b)`, `I64.to_str(n)`, `List.map(xs, f)`, `List.keep_if(xs, f)`, `List.fold(xs, init, \|acc, x\| …)` (`List.walk` was renamed), `x \|> Base.srev \|> Base.slen` with bare function stages, pairs `(a, b)` and pair patterns, `==` on `I64` and `Str`, `<` on `I64` and `F64`. Nothing in §2.1 was found that the Zig compiler cannot check. (The alpha4 finding it replaced: `&&`/`\|\|`, `List.walk`, `Num.to_str`, structural aliases `T a : [C a I64]`, tags bare and unqualifiable.) |
| V2 | Does `roc check` exit non-zero on warnings, and which ones? Does Gleam's `check`? What are Roc's single-thread switch and cache? | **Settled.** The Zig compiler's `roc check` exits **2** on any warning; the probe raised *unused variable* (a `let`, a pattern variable, an unused parameter) and *redundant pattern*, all excluded by §2.4. An unused `import` raised nothing. `--jobs=1` gives one OS thread (peak `Threads` 1 in `/proc`, against 33 by default). Without `--no-cache` it writes `~/.cache/roc/<version>/`; with it, nothing. `gleam check` exits **0** with warnings (unused variable, unreachable pattern, unused import), so the runner treats a `warning:` line in Gleam's output as a failed confirmation, the same as an error (§11). Also found: gleam_stdlib 1.0.5 has no `io.debug`, so Gleam's entry prints with `io.println(int.to_string(…))` (§7.2 amended). **Found later, while writing the printers and families (2026-09-27), all warnings or errors on a well-typed program, all avoided by the generator for every language (§2.4):** Roc's *unconditional condition* (a condition or `match` value it can decide at compile time, including a pure function call on constants such as `Base.sany(Base.Seq.SNil, \|_\| False)`; it also calls a `let`-bound closure's result constant when the call's arguments are, ignoring what the closure captures, which looks like a Roc bug); Roc's *compile time crash* (it evaluates a constant call of a generated function and `v0 * v0` squared thirty times overflows `I64`); Roc's *literal defaulted* (a numeric literal whose type is not fixed where Roc resolves it: at the end of the enclosing `let` definition, when it is an operator's left operand, the receiver of the static dispatch, or in a mutually recursive group, which Roc solves member by member; the Roc printer suffixes those literals, `37.I64`, by a conservative second HM run, `validate.rocDefaulted`). Gleam's *unreachable pattern* (it tracks the constructor or value of a variable already matched, through `let` aliases), *match on a literal value*, *redundant comparison* (`x == x`), *redundant tuple* (a tuple built only to be matched) and *unused function argument* (a parameter only passed back to its own function). |
| V3 | Let-polymorphism in each language. Gleam is believed not to generalise `let`. | **Settled: out of the LCD.** Gleam does not generalise a `let` (`let id = fn(y) { y }` used at `Int` then `String` is a type mismatch), and neither does PureScript without a signature (the same probe fails with *Could not match type Int with type String*). Elm, beni and Roc do. It stays out, and the oracle keeps refusing a generic `let` (§6.2). |
| V4 | Does beni accept qualified constructors (`Base.SCons`) and qualified types in annotations, as Elm does? | **Settled: yes.** `Base.SCons 2.0 Base.SNil` in an expression, `Base.SCons 1 Base.SNil` in a pattern and `Base.Seq a` in an annotation and in a constructor field all check with a plain `import Base`, so the beni printer qualifies exactly as the Elm printer does. The same probe confirmed `(mk 2) 3` (calling a call's result) and `\x acc -> …` as a two-parameter lambda. |
| V5 | Does `purs compile --codegen corefn` (or another flag) cut non-checking work while still type-checking everything? | **Settled: yes, and the timed command changes.** With `--codegen corefn` every module is still type-checked: a probe with a type error in each of two modules reported both. It skips JavaScript generation, and on the hand-written `Tree` + `Data` ports it took 0.72 s against 0.81 s for `js` (three alternating runs each, pinned). §9's PureScript row is therefore **v2**: `--codegen corefn`, with the deps-only `output/` built with the same `--codegen corefn` (an `output/` built for `js` is not reused by a `corefn` run). Externs and CoreFn are still written; that remains in the work column. |
| V6 | Does Elm need `elm/json` for `Platform.worker` with `()` flags? Does `elm make` without `--output` check the whole graph? | **Settled.** Elm refuses a `Platform.worker` project without `elm/json` (*MISSING DEPENDENCY … It helps me handle flags and ports*), so it stays in the template. `elm make src/Main.elm` checks **only the modules `Main` reaches**: a module with a type error that `Main` does not import compiled "successfully". So §7.2's rule that `Main` imports every module is load-bearing for Elm. Without `--output`, Elm also generates `index.html`; `--output=/dev/null` stays. |
| V7 | TypeScript: does `--singleThreaded` alone give one checker and one parsing goroutine, the same as `--checkers 1`? Checked by `/proc/<pid>/status` thread counts and `--extendedDiagnostics` under `GOMAXPROCS=1`. | **Settled: keep §9.1's command.** On a 300-file probe (17 904 lines), `tsc` 7.0.2 is a statically linked Go ELF. Without `GOMAXPROCS`, peak OS threads were 37 under `--singleThreaded` (the Go runtime's GC workers), 56 under `--checkers 1` (parsing still fans out: total 0.43 s, against 0.54 s single-threaded) and 36 by default (check 0.11 s, four checkers). With `GOMAXPROCS=1`, every mode peaked at **5** OS threads (one running Go code, plus the runtime's system threads), and `--singleThreaded` reported the same `Files`/`Types`/`Instantiations` as `--checkers 1`. `--singleThreaded` is therefore the switch that makes parse, bind and check sequential, and `GOMAXPROCS=1` plus `taskset` confines the runtime. |
| V8 | TypeScript: which generated shapes need explicit type arguments (§2.6), beyond nullary generic constructors, empty lists and `reduce`? Found by printing the everyday and polymorphism families without them and reading the errors. | **Settled 2026-09-27, by printing every family at sizes 1–3 over 16 seeds and reading `tsc`'s errors.** The printer writes the type arguments of a generic call or constructor when (1) a type variable occurs in no parameter whose argument is not a lambda (nullary constructors, `RErr`); (2) a lambda is among the arguments and a variable's only other sources are literals or a conditional, whose literal types TypeScript would fix the variable at (`sfold(s, 0, (acc, x) => …)`); (3) a type argument contains a list, because an array literal infers as a mutable `T[]` that a later `ReadonlyArray` conflicts with (TS4104); (4) an argument is a `Bool` expression, because a `boolean` is narrowed to `true` or `false` by `if`, `&&`, `\|\|` and through aliases; (5) an argument is a local narrowed by an enclosing `switch` or `===` comparison, which would otherwise be inferred as the narrowed variant or literal. Empty lists print `[] as ReadonlyArray<T>`, and `reduce` always takes its type argument. Pairs are built by `Base.pair` rather than an array literal (§2.6). Narrowing also forces three more writes, counted as annotations: a pattern variable bound from a narrowed occurrence writes its type, a `let` whose value reads a narrowed local writes its type, and a single-constructor type is destructured without a `switch` (TypeScript does not narrow a type that is not a union). A pair scrutinee whose column no row tests leaves its local unread in the `switch` tree, and the parameter then prints as `_`. |
| V9 | *Found while writing the other families (2026-09-27).* Does every language generalise an unannotated mutually recursive group for later uses? | **No: Elm 0.19.2 does not.** A probe with `a` and `b` mutually recursive and unannotated, used by one function at `Bool` and another at `number`, fails (*This `a` call produces: Bool*); the same with `a` only self-recursive passes. The generator therefore uses a generic member of such a group outside it at one instantiation only (§6.2), and the oracle checks it. |
| V10 | *Found while writing the other families (2026-09-27).* PureScript's type classes in the inferred mode. | Two refusals that no other language makes, since in PureScript `&&`, `==`, `<`, `+`, `<>` and `show` are class methods. (1) *AmbiguousTypeVariables*: a lambda passed to a parameter its callee ignores (`\v -> v && v`) leaves a constrained type that nothing determines. (2) *CannotGeneralizeRecursiveFunction*: a recursive group whose inferred type is class-constrained (`Eq a =>`, from `==` on elements of a sequence whose type nothing else fixes). A second HM run in which operators constrain rather than fix their operand type (`validate.psAmbiguous`) finds both: the PureScript printer writes the type of each binder holding an ambiguous type (`\(v :: Boolean) -> …`), and the signatures of such a recursive group even in the inferred mode. Both count as annotations. |

## 20. Questions for the owner — decided 2026-09-27

The owner accepted every recommended answer on 2026-09-27, with one change to question 4. The
questions are kept as they were asked; each decision follows it.

1. **Which mode is the headline?** *Recommended:* annotated (P = 100), because all six
   communities annotate top-level functions. Inferred is published beside it as the stress figure.
   **Decided:** annotated is the headline, and inferred is published beside it.
2. **Does PureScript stay in the default run,** even though it dominates the §14 budget?
   *Recommended:* yes, at the same sizes, so no table has a hole. `--langs` covers quick runs.
   **Decided:** yes, in the default run at the same sizes.
3. **Standard-library calls in the everyday family** (§2.3): use each library's `map`, `filter`
   and `foldl`, or keep even the everyday family on `Base`? *Recommended:* the library calls. That
   is what everyday code does, and in PureScript it includes the class resolution idiomatic code
   pays. **Decided:** the everyday family uses each standard library's `map`, `filter` and `foldl`.
4. **Which Roc?** The nixpkgs Roc is the Rust alpha4 compiler, and Roc's new Zig compiler is a
   different checker. *Recommended:* measure whatever `roc` `nixpkgs-compare` ships, name it in
   every table, and add the new compiler as a further column once it is packaged and has a check
   command. **Decided, then changed the same day:** the recommendation was first accepted, and the
   owner then replaced it: Roc is **only** the new compiler written in Zig, built from
   `roc-lang/roc` `main` at a pinned commit (§8.1). The Rust alpha4 compiler is not run at all:
   no column, no secondary column, nothing in the schema or the flake ("it's dead"). §2.2, §2.5,
   §7.2, §8.1, §9 and §19 V1–V2 are amended accordingly.
5. **The beni generator case in `test-blackbox`** (§15) makes a benchmark printer part of the
   gates. *Recommended:* yes. It is one size-1 check that takes about 10 ms, and it keeps the only
   printer whose language changes weekly from rotting unnoticed. **Decided:** yes.
6. **Is TypeScript in the headline tables?** Its program differs more than the others' do: it
   always annotates parameters, it has no `Int`/`Float` split, and its assignability is structural.
   *Recommended:* yes, as the last column, with the footnote of §2.6 and §6.3 on every cell. Its
   ratio to beni is the number most readers will want, and hiding it would be less honest than
   qualifying it. **Decided:** yes, as the last column, footnoted on every cell.
