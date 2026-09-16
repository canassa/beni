# Static dispatch spike — implementation plan

**Status:** plan, 2026-09-16. Not yet started.
**Branch:** `spike/static-dispatch`, cut from `master` at `f466aac`. The spike never merges to
`master` on its own; it produces numbers and a research report, and the decision whether to adopt
is taken on those.
**Commissioned by:** the objection behind
[`research/18-static-dispatch-revisited.md`](../docs/design/research/18-static-dispatch-revisited.md),
which re-tested `fast-compiler.md` §3.1 and found three of its four reasons wrong. What remains is
one *reasoned* argument (the cost lands on inference and on the §8.1 interface) and one unmeasured
claim (the runtime and size trade of derived versus structural operations). This spike measures
both on the real compiler.

---

## 0. Decisions already taken (2026-09-16)

| Decision | Choice | Notes |
|---|---|---|
| Call syntax | **Dot-call, type-directed.** `x.m a b` is a method call resolved on the type of `x`. `x.m` with no arguments stays a field access. `(x.m) a` is always a field call. | Roc-faithful. The receiver-unknown case produces a `where` constraint; that deferral is one of the costs being measured. |
| Method set | **Module rule.** A method of type `T` is any `pub` value in the module that declares `T`. | Roc's original design (2024-11 → 2025-09). Roc moved to a `.{ }` block in 2025-10 mainly so that two types in one module can each have a `to_str`; see §9. **We may need to change this later.** The checker keys every lookup on `(TypeId, name)` so a block form is a front-end change only. |
| Scope | All four: `where` constraints + dot-call; `==` as a well-known `eq` with derivation; `compare` as a well-known method (Dict/Set/sort lose their comparator argument, `<` works on strings); return-type dispatch. | Return-type dispatch is last and may be cut if the budget runs out; the other three are the spike. |
| Polymorphic-site encoding | **N hidden function arguments**, one per constraint, in canonical scheme order. | Roc's evidence-param order (`references/roc/src/check/dispatch_evidence.zig:1-30`). Record encoding is not built. |
| Where it lives | A normative spec on the branch, `docs/design/static-dispatch-spike.md`. `fast-compiler.md` §3.1 is not edited and no section is renumbered. | CLAUDE.md rule 1 and rule 2. |
| Measurement | Everything in §7, baselines captured **before** the first checker change, both corpora built from the same sources. | `fast-compiler.md` §12: the number is on every step. |

---

## 1. Context

beni has no ad-hoc polymorphism beyond `number`, `appendable` and the post-solve `equatable`
obligation. Ordering is passed explicitly (`Dict.empty String.compare`), equality is one shared
structural walk in `core/Basics.js:93-111`, and the pre-bound `Dict.String` / `Dict.Int` modules
exist only to hide the comparator argument. Report 18 counted the ergonomic tax and found the
runtime argument *mildly favours* dispatch on a JS target, but that the real cost lands on
inference: an unannotated `pub` function's inferred scheme would carry accumulated method
constraints, and that scheme *is* beni's interface (`fast-compiler.md` §3.1 "Top-level annotations
are optional", §8.1).

Nobody has measured any of that on a real compiler. This spike builds the feature end to end,
Roc's shipped semantics on beni's checker and backend, and measures: check throughput with and
without dispatch in the source, constraint accumulation in unannotated code, interface churn under
realistic edits, output size raw and compressed, runtime of the emitted JavaScript for the
operations dispatch replaces, and the quality of the diagnostics. The deliverable is
`docs/design/research/19-static-dispatch-spike.md` with the numbers, plus the branch.

---

## 2. What exists and is reused (from the four read-only maps)

The mechanism is mostly already there under other names. Nothing in this list is new work.

**Checker**
- Type variables carry a payload struct shared by flex and rigid: `TypeStore.Flags { name, kind, equatable }` (`src/check/TypeStore.zig:148-158`). Constraints attach here, exactly as Roc's `Flex.constraints` (`references/roc/src/types/types.zig:301-350`).
- Post-solve obligations: `Solve.Obligation { kind, v, region }` per rank (`src/check/Solve.zig:72-82`), drained by `dischargeObligations` (`Solve.zig:1222-1244`) which already re-reads its list because discharge can register more, and already has a "fold into the flex var and let the caller carry it" path (`dischargeEquatable`, `Solve.zig:1253`). That is the accumulate-until-nominal shape.
- `equatable` obligations are registered *from inside unification* when a flagged flex meets a structure or alias (`Solve.zig:395, 456, 509`). Method constraints register at the same three sites.
- `Types.Entry.module` gives the declaring module of every `TypeId` (`src/check/Types.zig:56-67`), and `Interface.findValue` binary-searches a module's `pub` values (`src/resolve/Interface.zig:416-429`). Method lookup is those two calls.
- `Solver.schemeOf` (`Solve.zig:916-930`) is the one reference-to-type function; `importedValue` (`Solve.zig:1013-1023`) instantiates an interface scheme.
- Schemes cross modules as `Interface.Scheme { quantified_start, quantified_count, body }` with `Quantified { kind, equatable, name }` packed into `Quantified.words = 2` (`Interface.zig:105-143`); `Schemes.Writer.quantifierOf` records a quantifier (`src/check/Schemes.zig:341-364`), `Schemes.instantiate` reads one (`:382-407`).
- `Render.writeScheme` (`src/check/Render.zig:152-154`) is the single choke point for printing a scheme, used by both dumps and every diagnostic.
- `Constrain.Node.Tag.equatable` is declared and solved but never emitted (`src/check/Constrain.zig:137`, `Solve.zig:228`).

**Front end**
- `x.m a b` already parses as `apply(field_access(x, m), [a, b])` (`src/parse/Parse.zig:1532-1557`); no grammar change for the call form.
- The record-field disambiguation rule "a comma ends the field's type when the next tokens are `lower_ident ':'`" (`language.md` §3, line 288) is the rule a `where` clause needs, with `lower_ident dot_lower ':'` as the lookahead.
- Lowering desugars `|>` to first-argument-first (`src/bir/Lower.zig:1289-1300`), and core is subject-first, so `d.insert k v` is `Dict.insert d k v` with no reshuffling.
- `==` is a front-end desugar to `call(import_value(Basics, eq), [a, b])` (`src/bir/Lower.zig:1360-1381`); `<` etc. likewise to `Basics.lt` and friends.

**Backend**
- `Lower.functionOf` (`src/js/Lower.zig:533-557`) is the one place parameter lists are built; hidden leading parameters are a two-line change there. `Lower.callExpr` (`:910-945`) is the one call-site lowering.
- The backend sees no types (`Lower.Input`, `src/js/Lower.zig:85-105`). The checker has a per-instruction slot table `inst_result` (`src/check/Check.zig:564-566`) that is filled only for `let_def` and freed at the end of the check. The dispatch side table copies its shape and survives.
- `externalName` / `need` / `importStatements` (`src/js/Lower.zig:462-526`) build cross-module references and imports; derived functions use the same path with synthesised names.
- Record keys are emitted sorted by name text, constructors are `{ $: "Tag", a, b, … }` padded to the widest constructor, all-nullary types are bare tag strings, lists are `{ $: 1, a, b }` / `{ $: 0, a: null, b: null }` (`backend.md` §4; `src/js/Lower.zig:170-200, 703-745`). Derived `eq` and `compare` are written against exactly this.

**Harness**
- `zig build bench` prints one JSON line per phase, best of N after one warm-up, `--generate=N` from `bench/gen.zig`, always `jobs = 1` (`bench/bench.zig`). `check` carries `Solve.Counters` (`src/check/Solve.zig:63-68`); a new counter added there flows to bench and to `--self-profile` for free.
- `dump --stage=raw` prints the interface record's bytes (`src/dump/interface.zig:116-185`), the surface the determinism test at `tests/blackbox/blackbox_test.zig:2347` byte-compares across `--jobs`. It is also the interface-change detector for §7 M3.
- `tests/corpus/run/` builds and runs under Node and compares stdout (`tests/blackbox/corpus_test.zig:393-419`); `World.spawnAndCapture` (`tests/blackbox/world.zig:280`) is the process runner.
- No gzip/brotli, no JS runtime timing, no CI. Node 24 has `zlib.brotliCompressSync` built in, so compressed size needs no new toolchain.

---

## 3. Surface language (what goes into `docs/design/static-dispatch-spike.md`)

The spec on the branch is normative for the branch. It is written first, in full, before S2 starts,
and every slice below cites it. It is a delta on `language.md` and `checker.md`; it does not edit
either, and it does not renumber anything.

### 3.1 Method calls

`Atom '.' lower_ident Arg+` is a **method call** when it is the head of an application. It is
lowered to a new BIR node `method_call { receiver, name, args }`. Rules:

| Form | Meaning |
|---|---|
| `x.m a b` | method call: receiver `x`, method `m`, arguments `a b` |
| `x.m` | field access, unchanged (`language.md` §6.3) |
| `(x.m) a` | field call, unchanged: parentheses opt out |
| `x.m a \|> f` | `f (x.m a)`; pipes are unaffected |
| `x.a.m b` | receiver is `x.a` (a field access), method `m` |
| `.m` | accessor lambda, unchanged |

Resolution, decided in the solver when the receiver's type is known:

| Receiver type | `x.m a b` becomes |
|---|---|
| nominal `T` declared in module `M` (custom type, `opaque type`, `foreign type`) | `M.m x a b`; `unknown_method` if `M` has no `pub m`; `private_method` if `m` exists but is not `pub` |
| an alias | looked through to what it names (aliases are transparent, `fast-compiler.md` §3.1) |
| a record | field call `(x.m) a b`, unchanged behaviour |
| a tuple, a function, `()` | `no_methods_on_shape` |
| a type variable | a constraint `a.m : a, A, B -> R` is added to the variable (§4.1) and the call is typed `R`; resolution is deferred |

The same-module case (`T` declared in the current module) resolves against the module's own
declarations, including private ones, and a method in the current binding group is used at its
monomorphic type like any recursive reference.

### 3.2 `where` clauses on annotations

```
Annotation := lower_ident ':' Type ('where' Constraint (',' Constraint)*)?
Constraint := lower_ident '.' lower_ident ':' Type
```

The comma rule is the record-field rule: a comma ends a constraint's type when the next three
tokens are `lower_ident dot_lower ':'`. The variable must occur in the annotated type
(`where_variable_unbound`). Two constraints on the same variable and name are
`duplicate_where_constraint`. Layout: `where` follows rule 2 of `language.md` §4 (may start a
continuation line right of the declaration's indent); the formatter puts one constraint per line
when there is more than one.

Example, in core after S6:

```elm
pub insert : Dict k v, k, v -> Dict k v
    where k.compare : k, k -> Order
```

### 3.3 Well-known methods

| Operator / use | Method | Type | Where it resolves for core types |
|---|---|---|---|
| `a == b`, `a /= b` | `eq` | `T, T -> Bool` | `Int`/`Float`/`Char`/`String`/`Bool`: `===`; records, tuples, custom types: derived (§6); `List a`: derived, with `a`'s `eq` as evidence |
| `a < b` etc., `Dict`, `Set`, `List.sort` | `compare` | `T, T -> Order` | `Int`/`Float`: JS `<`/`>`; `String`: `String.compare`; `Char`: code-unit compare; records, tuples, custom types: derived (§6), lexicographic in field-name order / constructor declaration order; `List a`: derived |

A user type gets a well-known method by declaring a `pub` value of that name in its module;
otherwise the derived one is used. `eq` on a function type is `not_equatable` as today. The
`equatable` marker stays in core and keeps meaning what it means; it becomes redundant with the
`eq` constraint and that redundancy is a finding, not something the spike removes.

`==` lowers to `method_call(a, eq, [b])` marked `well_known`; `<` to
`method_call(a, compare, [b])` followed by the `Order` test (the backend emits the primitive
comparison directly for `Int`/`Float`). `Basics.eq`/`neq`/`lt`/`gt`/`le`/`ge` stay declared and
callable as functions; `==` no longer routes through them.

### 3.4 Return-type dispatch

Roc's `module(a).decode(bytes)` with no receiver value. beni spelling: inside a declaration whose
annotation has a `where` constraint on type variable `a`, the expression `a.m args` where `a`
resolves to **no value binding** but is a variable of that `where` clause is a **type dispatch**
`type_dispatch { var, name, args }`. Shadowing is an error in beni (`language.md` §7), so this is
unambiguous. Without such an annotation it is `unbound_variable` as today. This requires the
annotation, as Roc does.

```elm
pub decode : String -> Result String a
    where a.decode : String -> Result String a
decode s =
    a.decode s
```

### 3.5 Core changes

- `foreign type String` moves from `Basics` to `String`; `foreign type Char` to `Char`. The prelude
  table (`src/bir/prelude.zig`) is updated so `String` and `Char` still resolve unqualified.
- `Dict k v` drops its comparator field. `Dict.empty : Dict k v`; every function that compares
  keys carries `where k.compare : k, k -> Order`. `Set` likewise. `List.sort : List a -> List a
  where a.compare : …`; `sortWith`/`sortBy` stay. `Dict.String` and `Dict.Int` are deleted.
- `List.member : List a, a -> Bool` (the constraint is inferred from the `==` inside).

---

## 4. Checker design

### 4.1 Representation

```zig
// TypeStore.zig
pub const Flags = struct {
    name: Symbol.Optional = .none,
    kind: Kind = .any,
    equatable: bool = false,
    constraints: ConstraintSet.Optional = .none,   // NEW, u32
};

pub const MethodConstraint = struct {
    name: Symbol,        // method name
    fn_var: Var,         // the method's type at this use, e.g. `a, A, B -> R`
    region: Bir.Inst.Index,
    origin: enum(u8) { dot_call, well_known, where_clause, type_dispatch },
};
```

`ConstraintSet` is a range into a per-store `constraints: std.ArrayList(MethodConstraint)`,
sets are append-only, and merging two sets appends a new set (so the journal's rollback of
speculation stays a length truncation, `TypeStore.zig:394-404`). `Kind` is **not** extended
(`TypeStore.zig:100-106`).

The `Descriptor` grows by 4 bytes. M1(a) in §7 measures what that costs code that never uses
dispatch; if it is measurable, the fallback is a side table keyed by root `Var`, moved on merge.

### 4.2 Unification (`Solve.zig`)

- **flex ⊓ flex** (`Solve.zig:372-381`): union the two sets. Same name on both sides: unify the
  two `fn_var`s; on failure report `method_constraint_mismatch` at the younger region. (Roc's
  August-2026 fix keeps both and instantiates per use; that is §10 stretch item 1.)
- **flex vs rigid** (`:386`): every constraint on the flex must be present by name on the rigid
  (from its `where` clause), else `missing_where_constraint`; the `fn_var`s unify.
- **flex vs structure/alias** (`:391-398, 452-459, 505-512`): register one obligation
  `.method{ constraint }` on the concrete var per constraint in the set, at `s.region`, exactly as
  `equatable` does at `:395`.

### 4.3 Discharge (`Solve.zig:1222-1244`, new arm)

`dischargeMethod(ob)` resolves the obligation's var and switches on its content:

| Content | Action |
|---|---|
| `flex` | fold the constraint into the variable's set (the `dischargeEquatable :1253` path); it will be promoted at generalisation |
| `rigid` with the name in its set | unify `fn_var`s; record target `evidence_param(k)` (§4.6) |
| `rigid` without | `missing_where_constraint` |
| `app T args` | look up `(T, name)`: own module → `env.decl_scheme` by name via the Bir; other module → `Interface.findValue`; not found → `unknown_method` with a did-you-mean over the module's values; found → instantiate the scheme (`importedValue` / `makeCopy`), unify with `fn_var`; record target `value(module, index)` or `top(decl)`. Instantiation of a constrained scheme creates new obligations, which the drain loop already handles. Well-known names on core primitives take the table in §3.3 first. |
| `alias` | discharge on `actual` |
| record / tuple | well-known `eq`/`compare`: record target `derived(shape)`; any other name → `no_methods_on_shape`. For `eq`/`compare` on a record, register the same obligation on every field type. |
| `func`, `unit` | `no_methods_on_shape` (`eq` on a function keeps `not_equatable`) |
| `err` | silence |

Budget: the drain loop's `1 << 20` bound and the `walkEquatable` worklist shape (`Solve.zig:1275-1328`)
apply; a new `check/depth/` pair pins the constraint-chain guard (`checker.md` §5).

### 4.4 Generalisation and schemes

Constraints ride on `Flags`, so `generalize` (`Solve.zig:1173-1218`) and `makeCopy`
(`:1029-1093`) carry them for free within a module; `copyHelp` must copy each constraint's `fn_var`
through the same memo. Across modules:

```zig
// Interface.zig
pub const Quantified = struct {
    kind: u8, equatable: bool, name: SymbolIndex.Optional,
    constraints_start: u32, constraints_len: u32,   // NEW: range in `extra` of pairs (name SymbolIndex, TermIndex)
    pub const words = 4;                             // was 2
};
```

Constraint pairs are written **sorted by name text** (`Interface.zig:26-30`; `checker.md` §"names
in interfaces"). `Schemes.Writer.quantifierOf` writes them, `Schemes.instantiate` reads them into
fresh flex vars with fresh constraint sets. `writeRaw` prints them (`src/dump/interface.zig:162-168`)
so the `--jobs` byte-comparison covers them. `Render.writeScheme` appends `where a.m : …` clauses
after the body, one per constraint, sorted by variable name then method name, so
`dump --stage=types`, `--stage=interface` and every diagnostic show them.

### 4.5 Return-type dispatch

`type_dispatch { var, name, args }`: the generator looks the variable up in the declaration's
annotation (rigid var), adds `name` to its constraint set if absent with `fn_var : args -> result`,
and types the expression `result`. At a call site the callee's instantiated constraint has a
fresh flex `a` that unification with the expected result type makes concrete; discharge then works
as §4.3. No new mechanism.

### 4.6 The dispatch table (checker → backend)

The backend needs, per module, the answer the checker computed. A flat side table in the shape of
`Bir.refs` (`src/bir/Bir.zig:68-69, 549-566`):

```zig
pub const Dispatch = struct {
    pub const Target = union(enum(u8)) {
        top: Bir.DeclIndex,                                  // this module's value
        ext: struct { module: Graph.Index, value: Interface.ValueIndex },
        evidence: u16,                                       // the k-th hidden parameter of the enclosing declaration
        primitive: enum(u8) { strict_eq, num_lt, num_compare, char_compare, string_compare },
        derived: struct { kind: enum(u8) { eq, compare }, shape: DerivedShape },
        field,                                               // method_call on a record: plain field call
        err,
    };
    pub const Site = struct { inst: Bir.Inst.Index, evidence_index: u16, target: Target };
    sites: []Site,                       // sorted by (inst, evidence_index)
    decl_evidence: []struct { start: u32, len: u32 },        // per declaration: its evidence params, canonical order
    evidence: []struct { quantified: u16, name: SymbolIndex },
};
```

- A `method_call` / `type_dispatch` instruction has one site with `evidence_index = 0`.
- A `call` (or `method_call`) whose callee scheme has `n` evidence params has `n` sites, one per
  param in canonical order; each comes from the obligation created when that callee scheme was
  instantiated at this instruction. Instantiation therefore tags each created constraint with
  `(inst, evidence_index)`.
- **Canonical order** = quantifier discovery order (what `Schemes.Writer` already assigns, first
  appearance in the body) then constraint name text. Callee and caller both derive it from the
  scheme, never from var identity, which is Roc's contract (`dispatch_evidence.zig:12-19`).
- `Check.Module` gains `dispatch: Dispatch`; it is filled at the end of `ModuleCheck.run` while the
  store is alive, kept regardless of `keep_stores`, and handed to `Lower.Input` beside `interfaces`
  (`src/js/Emit.zig:531-540`; `bench/bench.zig:631-639`).
- `dump --stage=dispatch` prints it, so it is corpus-testable (`tests/corpus/dispatch/`).

### 4.7 Diagnostics (new codes, all in `check/Diagnostics.zig`, each with a `check/bad/` fixture)

`unknown_method`, `private_method`, `no_methods_on_shape`, `missing_where_constraint`,
`method_constraint_mismatch`, `where_variable_unbound`, `duplicate_where_constraint`,
`type_dispatch_needs_annotation`, `ambiguous_method_receiver` (a constraint that is still on a
flex var at the top of an *unannotated non-`pub`* declaration is fine; on a `pub` declaration it
is promoted to the scheme and reported as an informational note only under `--explain`, which
is how the churn measurement observes it). The Roc error-location complaint (report 18 §2.4) is
tested by a fixture where the missing constraint is on the caller: the message must point at the
call, not into the callee.

### 4.8 Parallel checking

`x.m` reaches the module declaring `x`'s type, which need not be an import edge of the current
module (`Check.zig:270-282`). At resolve time, add an implicit graph edge for every `ext_type`
occurrence in the module's Bir and every `ext_type` reachable through an imported scheme's terms;
`Graph.referencedModules` (`src/resolve/Graph.zig:304-316`) already does this shape for prelude
rows. The DAG driver is otherwise untouched.

---

## 5. Front-end and backend changes

### 5.1 Parser, AST, formatter, dumps

- `Annotation` gains an optional `where` list (`Ast.DeclHeader`); `parseType` untouched; a new
  `parseWhere` using the three-token lookahead (§3.2).
- `method_call` is not a parse node: lowering recognises an `apply` whose head is a
  `field_access` (`src/bir/Lower.zig:1440-1500`, `lowerApplication`) and emits the new tag.
  `type_dispatch` is emitted from `resolveValue` (`Lower.zig:986-1008`) when the name is unbound
  as a value and bound in the annotation's `where`.
- `fmt` prints `where` clauses; `dump --stage=ast|bir` print the new nodes; corpus goldens for
  `parse/good`, `bir`, `fmt`.

### 5.2 BIR

```zig
method_call: lhs = receiver inst, rhs = ExtraIndex of { name: SymbolIndex, args: SubRange }, flag well_known
type_dispatch: lhs = SymbolIndex of the type variable, rhs = ExtraIndex of { name, args }
```

`Bir.Decl` gains `where_start/where_end` into `extra` (pairs of `(var SymbolIndex, type inst)`)
alongside `annotation`. `Bir.refs` does not gain edges for method calls (the checker cannot be
run before refs exist); the dispatch table carries the edges for the future DCE.

### 5.3 Backend (`src/js/Lower.zig`)

- **Declarations**: `functionOf` prepends `$m$0 … $m$n-1` for a declaration with `n` evidence
  params (from `dispatch.decl_evidence`). A zero-parameter `pub` value with constraints (e.g.
  `Dict.empty`) becomes a function of its evidence params; the checker rejects that in the spike
  (`constrained_constant`) and core writes `Dict.empty : () -> Dict k v` — noted as a finding.
- **Calls**: `callExpr` looks up `dispatch.sites` for the instruction and prepends one argument per
  site: `Module$name`, `M$name`, `$m$k`, `$eq$Point` etc.
- **`method_call`**: target `top`/`ext` → `Callee(receiver, args…)` plus evidence; `evidence` →
  `$m$k(receiver, args…)`; `field` → `receiver.m(args…)` as today; `primitive` → the JS operator
  inline (`===`, `<`); `derived` → the derived function.
- **`type_dispatch`**: as `method_call` without the receiver.
- **Derived functions** (§6) are emitted as top-level `const` in the declaring module and exported;
  structural shapes (records, tuples) are derived per shape in the consuming module under a name
  keyed by the shape (`$eq$r$x$y` for `{ x, y }`), deduplicated per file.
- Emission order (`emissionOrder`, `Lower.zig:354-387`) treats derived functions as declared before
  everything else in the module.
- `tests/corpus/emit/` (the shape corpus `backend.md` §12 specifies but which does not exist) is
  created in S4 for the evidence-parameter and direct-call shapes.

---

## 6. Derived `eq` and `compare`

Generated per type in its declaring module, once, from the type's constructor table
(`Bir.ctors`, `Interface.ctors[].arity`), against the representation contract in `backend.md` §4:

```js
// pub type Shape = Circle Float | Rect Float Float
const Shape$eq = (x, y) => x.$ === y.$ && (x.$ === "Circle" ? x.a === y.a : x.a === y.a && x.b === y.b);
const Shape$compare = (x, y) => x.$ !== y.$ ? (SHAPE_ORDER[x.$] < SHAPE_ORDER[y.$] ? "LT" : "GT") : …;

// pub type Maybe a = Nothing | Just a — parametric: element evidence first
const Maybe$eq = ($m$0, x, y) => x.$ === y.$ && (x.$ === "Nothing" || $m$0(x.a, y.a));
```

Rules: padding `null`s are compared (they are equal on both sides, so it is safe and keeps the
function total); primitives use `===`/`<`; `Float` NaN behaves as today (`NaN === NaN` is false);
all-nullary types compare the bare tag string, with an order table for `compare`; records compare
fields in name-text order; lists are a loop, not recursion; a user `pub eq` in the module wins
over derivation. `List$eq`/`List$compare` live in `core/List.js` as foreigns since the list
representation is foreign (`boundary.md` §4).

---

## 7. Measurements

Every number is best-of-5 after a warm-up on an idle machine, load average checked first,
before/after runs interleaved (`bench/README.md:15-18, 60-64`). Baselines are captured on `master`
at `f466aac` **before S2** and written to `plans/static-dispatch-spike-results.md`, which is
append-only like the diary. Two corpora are used throughout:

- **C0**, the current sources: `bench/corpus`, `tests/corpus`, `core/`, `--generate=100000`.
- **C1**, the same programs rewritten to use dispatch: comparator arguments removed, `Dict.String`
  uses replaced, `x |> f` left alone, plus `gen.zig --dispatch` generating the same modules with
  method calls and `where`-constrained helpers.

| # | Question | Instrument | Corpus | Reported as |
|---|---|---|---|---|
| M1a | What does the feature cost code that never uses it? | `zig build bench -- --generate=100000`, `check` line, plus `Solve.Counters` | C0 on `master` vs C0 on the branch | ms, LOC/s, Δ%, and the four counters |
| M1b | What does using it cost? | same | C1 on the branch vs C0 on the branch | ms, LOC/s, Δ%, new counters `constraints_created / merged / deferred / discharged / promoted` |
| M2 | Constraint accumulation in unannotated code | `gen.zig --pathological=constraint-chain=N`: an unannotated chain of N `pub` functions, each adding one method call on its polymorphic parameter and calling the previous one | branch | check ms vs N for N ∈ {10, 100, 1000, 5000}; max constraints per scheme; rendered scheme length |
| M3 | Interface churn: how often does a body edit change the interface? | `bench/churn.sh`: for every `pub` declaration in the corpus apply three edit classes and byte-diff `dump --stage=raw` before/after. E1: change a literal. E2: add a second use of an operation already constrained. E3: add a new operation on a polymorphic parameter. Run for annotated and unannotated variants of the same module. | C0 on `master`, C1 on branch | fraction of edits that change the interface, per class × annotated/unannotated. E3 is the load-bearing row: in C0 the equivalent edit adds a parameter, so both worlds change the interface; the claim in report 18 §2.3 is measured, not argued |
| M4 | Output size | `bench/size.mjs`: builds every `run/` fixture and `bench/corpus` with `beni build`, reports raw, gzip and brotli bytes (Node `zlib`) | C0 on `master` vs C1 on branch | bytes per program, totals, Δ%; also **per-type derived-function bytes** so the "grows per type × method" row in report 18 §1.5 gets a number. Caveat recorded: no DCE exists yet, so all sizes are upper bounds |
| M5 | Runtime of emitted JS | `bench/runtime/*.beni` + `bench/runtime.mjs`: builds each program both ways and runs it under Node, 20 runs, best-of and median, ns/op. Programs: (R1) `Dict` insert then get of 100k `String` keys; (R2) `Dict` with a record key `{ x, y }`; (R3) `List.sort` of 100k `Int`, 100k `String`, 100k records; (R4) `==` on 1M records of 5 fields, on a 1k-element list of ADTs, on nested `Maybe (List Int)`; (R5) a `where`-constrained generic called through three levels of generic functions (evidence forwarding) vs the C0 closure-passing version; (R6) the same as R5 with three different types at the same call site in one loop (the inline-cache question) | both | ns/op per program, Δ×; plus `node --cpu-prof` on R4 and R6 to see whether V8 inlines the direct call |
| M6 | Diagnostic quality | the `check/bad/` fixtures of §4.7, rendered with `--diagnostics=text` | branch | the messages themselves, in the report, next to Roc's for the same programs (report 18 §2.4) |
| M7 | Compiler cost | `git diff --stat master`, per directory; `zig build` wall time; `zig-out/bin/beni` size; `zig build test` time | branch | numbers |
| M8 | Ergonomics | count of comparator arguments removed from C0 → C1; `Dict.String`/`Dict.Int` call sites removed; number of modules in `core/`, `bench/corpus`, `tests/corpus` that declare two or more types and would collide under the module rule (§0) | C0/C1 | counts, with the file list |
| M9 | Determinism | the existing gates plus a new `writeRecordShapes`-style module set with `where` constraints under the `--stage=raw` comparison (`blackbox_test.zig:2347`) | branch | pass/fail |

Deliverable: `docs/design/research/19-static-dispatch-spike.md` with every table, the raw JSON
lines under `plans/static-dispatch-spike-results.md`, and a §"Could not determine" listing
whatever the budget did not reach.

---

## 8. Slices, in order

Each slice: spec section written or confirmed → implement (agents, ≤5 at once, Opus) → fixtures
that fail before and pass after → the three gates green → read-only review → commit on the branch
→ diary entry. A slice that cannot be finished is not half-landed.

| Slice | Work | Fixtures / gates | Est. |
|---|---|---|---|
| **S0 spec + branch** | `git checkout -b spike/static-dispatch`; write `docs/design/static-dispatch-spike.md` (§3–§6 above, in full, with the diagnostic catalogue and the derived-function shapes); write the C1 rewrite plan for core | review of the spec only | 1 session |
| **S1 harness + baselines** | `bench/size.mjs`, `bench/runtime/` + `bench/runtime.mjs`, `bench/churn.sh`, `gen.zig --dispatch` and `--pathological=constraint-chain`, new `Solve.Counters` fields (zero on `master`); capture M1a/M3/M4/M5/M8 baselines on `master` into `plans/static-dispatch-spike-results.md` | `gen.zig` determinism tests extended; harness scripts have a smoke test in `build_test.zig` | 1 session |
| **S2 front end** | `where` parsing, `Ast`, formatter, `method_call` + `type_dispatch` lowering, `Bir.Decl.where_*`, dumps; move `String`/`Char` foreign types (no semantic change yet) | `parse/good`, `parse/bad` (`where_variable_unbound`, `duplicate_where_constraint`, `arrow`/comma cases), `bir`, `fmt` goldens | 1 session |
| **S3 checker** | §4.1–§4.4, §4.7, §4.8: constraints on `Flags`, unify merge, obligations, discharge with module lookup, promotion, interface `Quantified.words = 4`, instantiation, rendering, dispatch table + `dump --stage=dispatch` | `check/good` (single-module and project fixtures; `.iface` goldens showing `where`), `check/bad` for every code in §4.7, `check/depth/ConstraintChain{Ok,Deep}`, `--stage=raw` determinism module set, hermetic `Schemes` round-trip test extended | 2 sessions |
| **S4 backend** | §5.3 minus derivation: evidence params, evidence args, `method_call` lowering for `top`/`ext`/`evidence`/`field`; `tests/corpus/emit/` kind | `run/` fixtures: method call on own type, on imported type, through a generic, through three generics; `emit/` shape fixtures; `build_test` determinism at every `--jobs` | 1 session |
| **S5 well-known `eq`** | `==` desugar, primitive fast path, derived `eq` for records/tuples/ADTs/lists, `Maybe`/`Result` evidence, `List.member` | `run/` fixtures for every shape incl. NaN, padding, nested parametric; M5 R4 numbers | 1 session |
| **S6 well-known `compare` + core rewrite** | `<` family on `compare`, derived `compare`, `Dict`/`Set`/`List.sort` rewritten with `where`, `Dict.String`/`Dict.Int` deleted, C1 corpus produced (bench/corpus and tests/corpus/run rewritten by hand, goldens re-blessed and read), `Dict.empty` as `() -> Dict k v` | `run/Dictionaries`, `run/Sorting`, `run/LibraryArgumentOrder` updated; new `run/StringOrdering`; `check/bad/CompareOnFunction`; M5 R1–R3, M8 | 2 sessions |
| **S7 return-type dispatch** | §3.4/§4.5: `type_dispatch` in the checker and backend, `type_dispatch_needs_annotation` | `run/DecodeInto` (JSON-ish decode into two types), `check/bad/TypeDispatchUnannotated` | 1 session, cut first if over budget |
| **S8 measure + report** | run every row of §7 on the branch, interleaved with `master`; write research report 19; final diary entry; note in `fast-compiler.md` is **not** made on the branch (the decision is taken on `master` after reading the report) | all three gates on the branch | 1 session |

Rough total: 10–11 sessions.

---

## 9. Known limits and where the design may change

- **Module rule namespace clash.** Two types declared in one module cannot both have a method
  named `m`, because `pub` values are one namespace per module. Roc hit this and moved to a
  per-type block (2025-10; Jared Ramirez's summary, #ideas › static dispatch revisions, 2025-10-05,
  <https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/static.20dispatch.20revisions/near/543198691>;
  Feldman's earlier flag, #ideas › static dispatch - proposal, 2024-11-23,
  <https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/static.20dispatch.20-.20proposal/near/484067349>).
  **We may need to change this later.** M8 counts how often it would bite. Because every lookup is
  keyed on `(TypeId, name)` and the interface already records which module a value lives in, a
  block form is a front-end change: the block becomes the method table for that type instead of
  the module's `pub` values.
- **Deferred receiver.** `x.m a` with `x` unknown is a method constraint, never a field call, so
  `\r -> r.f 1` on a record-typed `r` that is only discovered later is `no_methods_on_shape`
  with a hint to write `(r.f) 1`. This is the ambiguity report 18 §2.1 and Roc's `->` operator both
  live with; M6 shows the message.
- **Same-name constraints unify.** The rank-2 example from Roc's August-2026 thread is a fixture
  that fails with `method_constraint_mismatch`; Roc's multi-constraint fix is stretch item 1.
- **No DCE yet.** Every derived function ships (M4 is an upper bound). `--release` stays refused.
- **Constrained constants.** `Dict.empty` becomes `() -> Dict k v` because a value with evidence
  parameters is a function. Roc has the same shape.
- **Interface hashing does not exist**, so M3 measures interface *bytes changed*, which is
  exactly what M4's hash will be over (`src/dump/interface.zig:37-45`).
- **`equatable` and `eq` overlap** after S5. Left in place; recorded.

### Stretch, only after S8

1. Multiple same-name constraints per variable, instantiated per use (Roc's principality fix).
2. The per-type method block, measuring how much of `core/` must opt in.
3. Record-per-variable evidence encoding behind a flag, for the inline-cache row of report 18 §1.4.

---

## 10. Verification

- `zig build test && zig build test-blackbox && zig build fmt-check` green on the branch after every
  slice; `master` untouched.
- Every new diagnostic has a `check/bad/` fixture; every runtime-visible behaviour has a `run/`
  fixture; the interface shape has `check/good` project fixtures with `.iface` goldens and a
  `--stage=raw` determinism module set.
- Each fixture is proven to fail before its slice by stashing the slice (CLAUDE.md rule 3).
- The measurement scripts are themselves tested by a `build_test.zig` smoke scenario that runs them
  on one tiny program and checks the JSON shape.
- The research report cites every number to a line in `plans/static-dispatch-spike-results.md`.
