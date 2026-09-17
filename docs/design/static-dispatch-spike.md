# Static dispatch — branch specification (spike)

**Status:** normative **for the branch `spike/static-dispatch` only**, written 2026-09-17 as slice
S0 of [`../../plans/static-dispatch-spike.md`](../../plans/static-dispatch-spike.md). It is a
**delta** on [`language.md`](language.md) and [`checker.md`](checker.md): it edits neither, it
renumbers nothing anywhere (CLAUDE.md rule 2), and where it extends one of them it cites the
section it extends. [`fast-compiler.md`](fast-compiler.md) §3.1 still records static dispatch as
excluded, and this document does not change that: the spike produces numbers and
`research/19-static-dispatch-spike.md`, and the decision is taken on `master` afterwards.

Where this document and the plan disagree, **this document wins for the branch**, and every such
disagreement is listed in Appendix A.

## 0. How to read this, and what it extends

| This spec | Extends | How |
|---|---|---|
| §1 method calls | `language.md` §3 (`App`, `Atom dot_lower`), §6.2, §6.3 | no grammar change; a new *reading* of an application whose head is a field access, decided in the checker |
| §2 `where` clauses | `language.md` §3 (`Annotation`), §4 rule 2, §9 | one new optional tail on a top-level annotation |
| §3 `eq` / `compare` | `language.md` §6.5, `checker.md` §6.1, Appendix B | `==`, `/=`, `<`, `<=`, `>`, `>=` stop being calls of `Basics` functions |
| §4 return-type dispatch | `language.md` §6.2 | one new reading of an unbound lower name |
| §5 core | `checker.md` Appendix B | new signatures, two type moves, two module deletions |
| §6 checker | `checker.md` §5, §6.2, §6.3, §6.4, §7 | constraints on a type variable's flags; one new obligation kind; `Quantified.words = 4` |
| §7 dispatch table | `checker.md` §2, `backend.md` §3 | a new checker→backend side table and a new `dump --stage` |
| §8 backend | `backend.md` §4, §5, §6 | hidden leading parameters; four call shapes; **§6's "a function-typed value in flight is always a closure of known arity" (`backend.md:189`) is extended**: evidence in value position is an eta-expanded closure, §8.2 |
| §9 derived functions | `backend.md` §4 | the exact JavaScript for `eq` and `compare` per representation |
| §10 diagnostics | `language.md` §10, `checker.md` §8.1 | ten new codes, appended to the catalogue; one new flag, `--explain` |
| §5.2 `foreign` with a `where` clause | `boundary.md` §4 | the sibling export's arity becomes evidence count + declared arity. `boundary.md` §4's checks are *export coverage* and *import coverage* (`src/js/Sibling.zig:1-33`); neither checks arity, so this rule is **documented and not enforced** on the branch — §11 records it as a widening of the `foreign` surface |
| §11 known limits | — | what the spike knowingly does not solve |

**Plan section → spec section**, so the slice table in `plans/static-dispatch-spike.md` §8 stays
usable: plan §3.1 → §1; §3.2 → §2; §3.3 → §3; §3.4 → §4; §3.5 → §5; §4.1 → §6.1; §4.2 → §6.2;
§4.3 → §6.3; §4.4 → §6.4–§6.6; §4.5 → §6.7; §4.6 → §7; §4.7 → §10; §4.8 → §6.8; §5.1–§5.2 → §1.4,
§2.5, §8.0; §5.3 → §8; §6 → §9; §9 → §11.

**Two `fast-compiler.md` §3.1 decisions are suspended on the branch**, and neither document is
edited (CLAUDE.md rules 1 and 2; plan §0). They are listed here so a reader of either document
knows which statements this branch contradicts:

| `fast-compiler.md` §3.1 | Says (`fast-compiler.md:111-115`) | On the branch |
|---|---|---|
| Decision point 3 | "Drop `comparable` and `compappend`. `<`, `>`, `<=`, `>=` are **numbers-only**. `"a" < "b"` does not compile; use `String.compare`." | the four operators call the receiver type's `compare` method (§3.1); `"a" < "b"` compiles. `comparable` is still not a `Kind`, so the *mechanism* the decision rejected is still absent |
| Decision point 4 | "Ordering is passed explicitly. `List.sortBy`, `List.sortWith`, and `Dict`/`Set` keyed by a concrete type (`Dict.String`, `Dict.Int`) as sugar over a comparator-taking core." | `Dict.String` and `Dict.Int` are deleted, `Dict`/`Set`/`List.sort` carry `where k.compare` (§5), and `sortWith` is the survivor |

Decision points 1, 2 and 5 (`number`, `appendable`, `==` as a post-solve obligation) are untouched;
§3.4 says what happens to `equatable`.

**Vocabulary.** A **method** is a `pub` value of the module that declares a type (§1.2). A
**method constraint** is the requirement, attached to a type variable, that whatever type ends up
there has a method of a given name at a given type. **Evidence** is the runtime value that
discharges a constraint at a polymorphic call: a function reference, passed as a hidden leading
argument (§8.1). A **well-known method** is one of the two names the compiler itself asks for,
`eq` and `compare` (§3). **Derivation** is the compiler writing a well-known method it could not
find (§9).

---

## 1. Method calls

### 1.1 The form

`Atom '.' lower_ident Arg+` is a **method call** when it is the head of an application. No grammar
rule changes: `language.md` §3 already parses `x.m a b` as `App` over `Atom dot_lower`, and the
adjacency rule ("access chains must abut their atom") already settles the lexing. What changes is
that BIR lowering, seeing an **Ast** `apply` whose head is a field access, emits the new BIR tag
`method_call` instead of `call(field_access(…), args)` (§1.4). `apply` is an Ast node; the BIR tag
for an application is `call` (`src/bir/Bir.zig:263`).

| Form | Meaning | Lowers to |
|---|---|---|
| `x.m a b` | method call: receiver `x`, method `m`, arguments `a`, `b` | `method_call { receiver = x, name = m, args = [a, b] }` |
| `x.m` | field access, unchanged (`language.md` §6.3) | `field_access(x, m)` |
| `(x.m) a` | field call, unchanged: parentheses opt out | `call(field_access(x, m), [a])` |
| `x.m a \|> f` | `f (x.m a)`; pipes rewrite first (`language.md` §8 step 2) | `call(f, [method_call{x, m, [a]}])` |
| `e \|> x.m a` | `x.m e a` — the pipe inserts at the **first argument**, which is the first argument *after* the receiver | `method_call { x, m, [e, a] }` |
| `x.a.m b` | receiver is `x.a`, a field access; method `m` | `method_call { field_access(x, a), m, [b] }` |
| `.m` | accessor lambda, unchanged (`language.md` §3 `Atom := dot_lower`) | `lambda` |
| `x.m _ b` | placeholder over the method call: `\y -> x.m y b` (`language.md` §6.7) | `lambda` over `method_call` |
| `x.0.m a` | receiver is the tuple element `x.0` | `method_call { tuple_index(x, 0), m, [a] }` |
| `M.f x` | qualified value call, **not** a method call: the head is a qualified name — a `qualified_lower` token, lowered to `import_value` or to the BIR tag `qualified` (`src/bir/Bir.zig:164`) — and not a field access | `call(import_value(M, f), [x])` |

`x.m` with **no** arguments is never a method call, even when `m` resolves to a nullary method:
`language.md` §6.3's field access wins, because an application with no arguments is not an
application. Write `(M.m) x` or `M.m x` to reach a nullary method of module `M`.

### 1.2 Resolution

Resolution happens in the solver, when the receiver's type is known (§6.3). Given `x.m a b` with
receiver type `R`:

| `R` | `x.m a b` becomes | Failure |
|---|---|---|
| a nominal type `T` declared in module `M` — `type`, `pub opaque type`, `foreign type` | `M.m x a b` | `unknown_method` when `M` has no value named `m`; `private_method` when `M` has a value `m` that is not `pub` and `M` is not the current module |
| an alias declared in **this** module | looked through to what it names — aliases are transparent (`fast-compiler.md` §3.1), so the method set is the *expansion's* | as the expansion |
| an alias declared in **another** module | `no_methods_on_shape` on the branch. Looking it through needs `Interface.alias_body`, which `checker.md` §7 records as not implemented; §11 says why the spike does not close it | `no_methods_on_shape`, with a hint naming the alias |
| a record | a **field call**: `(x.m) a b`, `language.md` §6.3 unchanged | the ordinary record diagnostics (`unknown_field`, `not_a_function`) |
| a tuple | well-known names only (§3): `eq`/`compare` derive (§9.3) | any other name: `no_methods_on_shape` |
| `()` | well-known names only: `eq` is constantly `True`, `compare` constantly `EQ` | any other name: `no_methods_on_shape` |
| a function type | nothing | `not_equatable` for `eq` (the existing code, `checker.md` §8.1); `no_methods_on_shape` for every other name including `compare` |
| a type variable | a method constraint `m : <the type at this use>` is added to the variable (§6.1) and the call is typed by the constraint's result; resolution is deferred | `missing_where_constraint` if the variable is rigid and its `where` clause does not name `m` |
| `err` | `err`, silently (`checker.md` §6.2, "errors never stop the build") | none |

**The module rule.** A method of type `T` is any `pub` value of the module that declares `T`. It is
keyed on `(TypeId, name)`, never on text, so a later move to a per-type block (§11) is a front-end
change and nothing else. `Types.Entry.module` gives the declaring module of every `TypeId`
(`checker.md` §5, "type ids are dense"), and `Interface.findValue` binary-searches that module's
`pub` values (`checker.md` §7).

**The same-module case.** When `T` is declared in the module being checked, lookup is against that
module's own declarations, `pub` and private alike — `private_method` cannot fire inside the
declaring module. A method in the current binding group is used at its monomorphic type, like any
other recursive reference (`checker.md` §6.1, "binding groups").

**No fallback to local functions.** `x.m` resolves only in `T`'s module. It does not fall back to a
local or imported function of the same name; that is Roc's rule and its reason is
[`research/18`](research/18-static-dispatch-revisited.md) §4.2 item 4. The receiver-first pipe
`e |> f a` is what reaches a function you do not own.

### 1.3 The `well_known` marking

A `method_call` carries an operator field, `well_known`, whose value is one of `none`, `eq`, `neq`,
`lt`, `le`, `gt`, `ge`. Only `language.md` §6.5's operators produce a non-`none` value (§3.1); the
dot-call form always produces `none`. Three rules hang on it:

1. A `method_call` marked non-`none` is **never** rewritten into a field call, so `r == s` on a
   record with a field named `eq` still means structural equality.
2. Only a marked call may derive (§9) — `x.eq y` written by hand on a type with no `eq` is
   `unknown_method`, not a silent derivation.
3. The backend may emit a JavaScript operator for a marked call whose target is `primitive` (§8.3).

### 1.4 BIR

```
method_call  lhs = receiver Inst.Index
             rhs = ExtraIndex of { name: SymbolIndex, well_known: u8, args: SubRange }

type_dispatch lhs = SymbolIndex of the type variable (§4)
              rhs = ExtraIndex of { name: SymbolIndex, args: SubRange }
```

`Bir.Decl` gains `where_start` / `where_end` into `extra`, a range of
`(variable SymbolIndex, method SymbolIndex, type Inst.Index)` triples, beside `annotation` (§2.4).

`Bir.refs` gains **no** edge for a method call. The reference a method call will turn into is not
known before the checker runs, and `refs` is a pure function of the file (`language.md` §8 step 1).
The dispatch table carries those edges instead (§7), and **two consumers must read it as well as
`refs`**:

- `Lower.emissionOrder` (`src/js/Lower.zig:354-374`), which is a temporal-dead-zone ordering and
  **not** the DCE graph: it post-orders `bir.refs` so that `const M$a = M$b + 1` is emitted after
  `M$b`. A `method_call` resolved to `top d` is exactly such a reference, so `emissionOrder` walks
  `dispatch.sites` with target `top d` as additional edges out of the declaration the instruction
  belongs to. Without it a constant whose initialiser is a method call on this module's own type is
  a TDZ throw in a well-typed program.
- the future DCE of `fast-compiler.md` §9.1, which needs the same edges for a different reason.

---

## 2. `where` clauses

### 2.1 Grammar

In `language.md` §3's notation, and replacing only the `Annotation` production **at top level**:

```
Decl        := DocComment? Visibility? (TypeAlias | TypeDecl | TopAnnotation | Definition | Foreign)
TopAnnotation := lower_ident ':' Type WhereClause?
Foreign     := 'foreign' lower_ident ':' Type WhereClause?      -- core only, §5.4 of language.md
             | 'equatable'? 'foreign' 'type' upper_ident lower_ident*

WhereClause := 'where' Constraint (',' Constraint)*
Constraint  := lower_ident dot_lower ':' Type
```

`lower_ident dot_lower` is `k.compare` written with no space: `dot_lower` must abut its atom
(`language.md` §3, "access chains"), and the same lexical rule is reused here unchanged. `k . compare`
and `k.Compare` are `unexpected_token`.

A `let` annotation (`language.md` §3 `LetBinding := Annotation? Definition`) takes **no** `where`
clause. Evidence parameters are a property of a declaration (§8.1) and `Bir.Decl` is where the
clause is stored; a `where` after a `let` annotation's type is `unexpected_token`. See Appendix A.1.

### 2.2 `where` is a contextual word, not a keyword

Exactly as `equatable` is (`language.md` §3, "`equatable` is a contextual word"). `where` is an
ordinary `lower_ident` — a variable, a field, a type variable — everywhere except one position,
decidable with **three tokens of lookahead and no backtracking**:

> While parsing the `Type` of a top-level annotation or `foreign` value, a `lower_ident` whose text
> is `where`, **followed by** a `lower_ident`, **followed by** an abutting `dot_lower`, ends the
> type and begins the `where` clause.

Without the rule, `pub insert : Dict k v, k, v -> Dict k v where k.compare : …` would read `where`
as a third type argument of `Dict`, because `TypeApp := upper_ident TypeAtom+` is greedy. With it:

| Written | Read as |
|---|---|
| `f : List a where a.eq : a, a -> Bool` | `List a`, then a `where` clause on `a` |
| `f : List where` | `List` applied to a type variable *named* `where` — the lookahead fails at the second token |
| `f : where.a` | `where` as a type variable with a field access, which is `unexpected_token` in type position |
| `where = 1` at column 1 | an ordinary declaration of a value called `where` |

### 2.3 The comma rule

A comma **inside** a `where` clause is ambiguous the same way a comma inside a record type is
(`language.md` §3, Types, the `{ f : Int, Int -> Int, g : Bool }` row): it could separate the
constraint's parameter list or start the next constraint. The record rule is reused verbatim with
one more token of lookahead:

> A comma ends a constraint's type when the next **three** tokens are `lower_ident`, an abutting
> `dot_lower`, and `':'`. Otherwise it is a parameter separator inside that constraint's type.

One token of lookahead cannot settle it (`, k` could begin either), three always can, and no
backtracking is needed, because `:` can never follow a type item.

| Written | Constraints |
|---|---|
| `where k.compare : k, k -> Order` | one: `k.compare : k, k -> Order` |
| `where a.eq : a, a -> Bool, b.eq : b, b -> Bool` | two |
| `where a.fold : a, (a, b -> b), b -> b` | one, whose type has three parameters. Both `a` and `b` must occur in the annotated type (§2.4), so this clause is well formed only under an annotation such as `sum : a, b -> b` |
| `where a.eq : a, a -> Bool, b.x` | `unexpected_token` at `b.x`: the lookahead matched `lower_ident dot_lower` but not `':'`, so the comma stayed a parameter separator and `b.x` is not a type |

### 2.4 Well-formedness

Checked in lowering, at the point the clause is stored, so every rule below is a pure function of
the file (`language.md` §8):

| Rule | Diagnostic |
|---|---|
| every constrained variable occurs in the annotated type | `where_variable_unbound` |
| **every type variable mentioned anywhere in a constraint's type also occurs in the annotated type** | `where_variable_unbound`, pointing at the offending variable inside the constraint |
| no two constraints share a `(variable, method)` pair | `duplicate_where_constraint` |
| the constrained name is a lower identifier, so never a constructor | `unexpected_token` |
| the constraint's type may mention the annotation's other variables and any type in scope | — |

**The closure rule** — the second row — is load-bearing and is not a tidiness rule. A scheme's
quantifiers are what §7.2's canonical evidence order is computed from, and they are discovered by
walking the **body** of the scheme (`Schemes.Writer`). A variable that occurs only inside a
constraint is therefore not a quantifier of the scheme the caller instantiates, has no index in the
canonical order, and would make caller and callee disagree about the evidence list silently. A
variable in that position is refused instead: `where a.fold : a, (x, s -> s), s -> s` under
`fold : List a -> a` is `where_variable_unbound` on `x` and on `s` (§10.6). Appendix A.21.

The constraint's type is **the whole type of the method**, receiver included where there is one:
`where k.compare : k, k -> Order` says that `k`'s module exports `compare` at two parameters. The
spec imposes **no shape requirement** on it — it need not be a function, and its first parameter
need not be the constrained variable — because return-type dispatch (§4) constrains a method that
never takes the receiver. What makes `x.m a` type-check is ordinary unification against that type
at the call, nothing more. See Appendix A.2.

A rigid variable introduced by an annotation carries exactly the constraints its `where` clause
declares, and no others: a body that needs a method the clause does not name is
`missing_where_constraint` (§6.2), which is the whole point of the clause.

### 2.5 Layout and formatting

**Layout** is `language.md` §4 rule 2 and nothing more: `where` and every token of the clause
belongs to the declaration's block, so each must be at column ≥ 2. A `where` at column 1 starts a
new declaration and the annotation ends without a clause.

**The formatter** (`language.md` §9) prints the clause on continuation lines, never joined to the
annotation's own line, and never reordered — the source order is kept, as everywhere else:

- one constraint: `where` and the constraint on one continuation line, indented 4.
- two or more: `where` alone on a continuation line indented 4, then one constraint per line
  indented 8, with a leading comma on every line after the first — elm-format's vertical form, the
  same shape lists and record types take.
- a constraint whose own type does not fit in 100 columns overflows the guide; it is never broken,
  for the same reason a pattern is never broken (`language.md` §9, "patterns").

```elm
pub insert : Dict k v, k, v -> Dict k v
    where k.compare : k, k -> Order


pub pairUp : List a, List b -> List ( a, b )
    where
        a.eq : a, a -> Bool
        , b.compare : b, b -> Order
```

The renderer that prints a *type* (§6.6) is a different thing and prints on one line with `, `
separators, sorted. A golden that shows both — a `fmt` golden and a `.iface` golden of the same
declaration — will legitimately differ in layout and in order.

---

## 3. Well-known methods: `eq` and `compare`

### 3.1 What the operators lower to

`language.md` §6.5's six comparison operators stop being calls of `Basics` functions. Lowering
emits one `method_call` each, marked per §1.3:

| Operator | Lowers to | Method type demanded | Instruction's type |
|---|---|---|---|
| `a == b` | `method_call { a, eq, [b], well_known = eq }` | `T, T -> Bool` | `Bool` |
| `a /= b` | `method_call { a, eq, [b], well_known = neq }` | `T, T -> Bool` | `Bool` |
| `a < b` | `method_call { a, compare, [b], well_known = lt }` | `T, T -> Order` | `Bool` |
| `a <= b` | `method_call { a, compare, [b], well_known = le }` | `T, T -> Order` | `Bool` |
| `a > b` | `method_call { a, compare, [b], well_known = gt }` | `T, T -> Order` | `Bool` |
| `a >= b` | `method_call { a, compare, [b], well_known = ge }` | `T, T -> Order` | `Bool` |

**The operator-as-function form** (`language.md` §6.5, "operators as functions", `language.md:485`;
the live fixture is `tests/corpus/parse/good/OperatorsAll.beni:30`, `[ (==), (/=), (<), (>), (<=), (>=) ]`)
gets the same dispatch as the operator, because it lowers to a lambda over it:

| Written | Lowers to |
|---|---|
| `(==)` | `\a b -> method_call { a, eq, [b], well_known = eq }` |
| `(/=)` | `\a b -> method_call { a, eq, [b], well_known = neq }` |
| `(<)` `(<=)` `(>)` `(>=)` | `\a b -> method_call { a, compare, [b], well_known = lt \| le \| gt \| ge }` |
| `(+)` `(::)` and the rest | unchanged: still `\a b -> call(import_value(Basics, add), [a, b])` and friends |

So `(==)` is a closure of arity two whose *body* carries the constraint, and the constraint lands on
the enclosing declaration's scheme like any other. It is not a reference to `Basics.eq`, which would
be structural equality and the wrong answer. Appendix A.22.

The four ordering operators are typed `Bool` while the method they call returns `Order`; the
backend supplies the test (§8.3). There is no desugaring to a `case` and no new core function for
"is this `LT`", because either would put a shape in BIR that the `primitive` peephole would then
have to pattern-match back out. See Appendix A.3.

`Basics.eq`, `neq`, `lt`, `le`, `gt`, `ge` and `compare` stay declared, exported and callable as
ordinary functions. They are simply no longer what the operators mean.

`String.compare` likewise stays: it is the method `compare` of `String` under §3.2, and code that
calls it by name keeps working.

### 3.2 The well-known method table

For a closed list of core types, `(TypeId, eq)` and `(TypeId, compare)` resolve from a **table
inside the compiler**, consulted **before** the module rule of §1.2. The table exists because the
module rule cannot serve these types: `Int`, `Float`, `Bool`, `Order` and `Never` are all declared
in `core/Basics.beni`, whose `pub compare : number, number -> Order` would be found for `Bool` and
then fail to unify.

| Type | `eq` | `compare` |
|---|---|---|
| `Int` | `primitive strict_eq` — `x === y` | `primitive num_compare` — `x < y ? "LT" : x > y ? "GT" : "EQ"` |
| `Float` | `primitive strict_eq`. **NaN**: `NaN === NaN` is `false`, so `nan == nan` is `False` and `nan /= nan` is `True`, which is today's behaviour and IEEE's | `primitive num_compare`. **NaN**: both `<` and `>` are false for any pair involving NaN, so `compare` returns `EQ`. A total order this is not; §11 records it |
| `Char` | `primitive strict_eq` — a `Char` is a one-scalar JavaScript string (`backend.md` §4, "Corrections from M3a") | `primitive char_compare` — a **code-point** comparison, `x.codePointAt(0) < y.codePointAt(0) ? "LT" : …`, never `<` on the strings: an astral `Char` is a surrogate pair and UTF-16 code-unit order puts it below U+E000 |
| `String` | `primitive strict_eq` | `primitive string_compare` — **a call to `String$compare`**, not `<`. `core/String.js:40-57` compares Unicode scalar values and says in its own comment that this is what `<` on JavaScript strings is *not*; `"a" < "b"` and `String.compare a b` must agree, so the operator takes the function's answer (§9.1, and §11 on what it costs) |
| `Bool` | `primitive strict_eq` — `true`/`false` are JavaScript booleans (`backend.md` §4 correction 1) | `primitive num_compare`, which on booleans is `False < True`. Note that this is **not** the constructor declaration order of `type Bool = True \| False`; see Appendix A.4 |
| `Order` | `primitive strict_eq` — an all-nullary type is a bare tag string | `derived compare` over the all-nullary shape, i.e. the order table `LT < EQ < GT` (§9.4). Alphabetic order on the tag strings would be wrong, which is why this row is not `strict_eq`'s partner |
| `Never` | `derived eq` | `derived compare` |
| `List a` | **not in the table** — module `List` declares `pub foreign eq`, found by the module rule (§5.2) | likewise `pub foreign compare` |
| every other type | not in the table — the module rule, then derivation (§3.3) | likewise |

The table covers only the two well-known names. `Int.toString`, were it ever written `n.toString`,
falls through to the module rule and finds `Basics.toString` or fails there.

### 3.3 Derivation, and who wins

For a name that is not in the table, resolution of `(T, name)` is:

1. the declaring module's own value `name`, `pub` (or any, in the same module) — **a user `pub eq`
   or `pub compare` in the declaring module always wins**;
2. otherwise, if the name is well-known **and** the call is marked (§1.3) **and** `T`'s shape
   supports it, the derived function (§9);
3. otherwise `unknown_method`, with a did-you-mean over the module's `pub` value names by edit
   distance (`checker.md` §8, "record field typos by edit distance").

"Shape supports it" is: a `type`, a `pub opaque type`, a record, a tuple, `()`, or a `foreign type`
that reaches the table. A function type never does (`not_equatable` for `eq`,
`no_methods_on_shape` for `compare`), and a `foreign type` that is neither in the table nor given a
`pub eq` by its module does not either — `unknown_method`.

Derivation is **structural and recursive**: each position inside `T` resolves the same well-known
name by the same three rules, so a record of `Maybe (List Point)` derives down to `Point`'s own
`eq`, whether that is derived or hand-written.

### 3.4 `equatable` after this change

The `equatable` marker (`language.md` §3, `checker.md` Appendix A and B) stays exactly as it is, is
still core-only, and still means what it meant. It becomes **redundant** with the `eq` constraint:
a type that has an `eq` is equatable, and a function type has neither. The spike does not remove it
and does not try to unify the two mechanisms — that redundancy is a finding for report 19, not work
(`plans/static-dispatch-spike.md` §9). `not_equatable` therefore survives as the diagnostic for
`eq` on a function type, because it is the better message.

---

## 4. Return-type dispatch

The one case that cannot be expressed with values, because at the dispatch point no value of the
dispatched type exists ([`research/18`](research/18-static-dispatch-revisited.md) §3). Roc spells it
`module(a).decode(bytes)`; beni spells it `a.decode bytes`.

### 4.1 The rule

Inside the body of a top-level declaration whose annotation carries a `where` clause (§2), an
application whose head is `v.m` where `v` is a `lower_ident` that

1. resolves to **no value binding** under `language.md` §6.2 — not a local, not a top-level value,
   not an exposed import, not a prelude value — **and**
2. is the name of a type variable constrained by that declaration's own `where` clause,

is a **type dispatch**, lowered to `type_dispatch { var = v, name = m, args }`. Shadowing is an
error in beni (`language.md` §7), so no value binding can ever be hidden by this rule and the two
readings never overlap.

```elm
pub decode : String -> Result String a
    where a.decode : String -> Result String a
decode s =
    a.decode s
```

| Situation | Result |
|---|---|
| `v` unbound as a value, the declaration has a `where` clause naming `v` and `m` | `type_dispatch` |
| `v` unbound as a value, the declaration has a `where` clause naming `v` but not `m` | `type_dispatch_needs_annotation`, naming the constraint to add |
| `v` unbound as a value, `v` **is** a type variable of the annotation but the annotation has no `where` clause at all | `type_dispatch_needs_annotation` |
| `v` unbound as a value, `v` is not a type variable of the annotation | `unbound_variable`, as today |
| the declaration has no annotation | `unbound_variable`, as today — the feature requires the annotation, as it does in Roc |
| `v.m` with no arguments | `unbound_variable`: an application with no arguments is not an application (§1.1) |

Giving `type_dispatch_needs_annotation` the second and third rows is what makes the code
reachable; the plan left it with no trigger. See Appendix A.5.

### 4.2 Typing

The generator looks `v` up among the declaration's rigid annotation variables, requires `m` in its
constraint set, unifies the constraint's recorded type with `(arg₁, …, argₙ) -> result` at this
use, and types the expression `result`. Nothing else is new: at a **call** site of `decode` the
callee's instantiated constraint sits on a fresh flex variable that unification with the expected
result type makes concrete, and §6.3 discharges it like any other.

```elm
config : Result String Config
config =
    decode text          -- `a` is forced to `Config` by this annotation
```

Report 18 §3 records the three costs Roc accepted with this feature — it requires an annotation, it
is the only place a type is named in an expression, and it is weaker than the abilities it replaced
(decode-then-transform cannot be written). The spike inherits all three unchanged.

---

## 5. Core package changes

This section replaces the `Dict`, `Set`, `List` and `Basics` rows of `checker.md` Appendix B **for
the branch**. Line numbers are `master` at `f466aac`. The rewrite itself is slice S6 and its
site-by-site plan is [`../../plans/static-dispatch-c1-rewrite.md`](../../plans/static-dispatch-c1-rewrite.md).

### 5.1 Two type moves

| Declaration | From | To | Why |
|---|---|---|---|
| `pub equatable foreign type Char` | `core/Basics.beni:58` | `core/Char.beni` | under the module rule, a type's methods are its declaring module's `pub` values; leaving `Char` in `Basics` makes `Basics.compare : number, number -> Order` its `compare` |
| `pub equatable foreign type String` | `core/Basics.beni:68` | `core/String.beni` | the same, and `core/String.beni` already has `pub foreign compare : String, String -> Order` (`core/String.beni:59`), which is the method it should have had all along |

`src/bir/prelude.zig`'s `typeModule` changes two rows — `.String => .String`, `.Char => .Char` —
and nothing else; both names stay unqualified in every module, the counts in its invariant test are
unchanged (7 modules, 10 types, 9 constructors, 36 values), and no `Basics` signature mentions
either type, so the move adds no import edge to `Basics`.

**No module gains an `import`.** `String` and `Char` are prelude *types* (`language.md` Appendix A),
so a module that names one already resolves it through the prelude table and needs no import line
before or after the move. What changes is which module the **conditional prelude edge** points at:
`Graph.zig:266-269` makes a prelude row an edge only when the module actually resolves a name
through it, so `core/Debug.beni` — whose `log:19`, `todo:28` and `toString:37` all name `String` —
gains a graph edge to `String` instead of to `Basics`, and `core/String.beni` gains an edge to
nothing (it declares the type itself). §6.8's implicit `ext_type` edges then add the same edge
wherever a `String` method is called.

`Int`, `Float`, `Bool`, `Order` and `Never` **stay in `Basics`**; the well-known table (§3.2) is
what serves them, and moving five more types is churn the spike does not need. Appendix A.6.

### 5.2 New declarations

```elm
-- core/List.beni
pub foreign eq : List a, List a -> Bool
    where a.eq : a, a -> Bool

pub foreign compare : List a, List a -> Order
    where a.compare : a, a -> Order
```

Implemented in `core/List.js` as loops, not recursion (§9.5). `List a`'s well-known methods are
therefore found by the ordinary module rule and need no table row.

**A `pub foreign` may carry a `where` clause**, and its sibling export's arity is then **evidence
count + declared arity** — `eq` above is declared 2-ary in beni and must be written `(m0, xs, ys)`
in `core/List.js`. This rule is **documented and not enforced**: [`boundary.md`](boundary.md) §4's
two automated checks are export coverage and import coverage (`src/js/Sibling.zig:1-33`) and
neither inspects arity, so a sibling that forgot the leading parameter fails at runtime rather than
at build time. That is a widening of the `foreign` surface against CLAUDE.md rule 6, forced by the
list representation being the emitter's rather than beni's; §11 records it as a finding the
adoption decision has to weigh, and Appendix A.7 records the alternatives.

### 5.3 `Dict` — the comparator leaves the data structure

`core/Dict.beni:40` becomes `pub opaque type Dict k v = Dict (Tree k v)`, the private
`comparatorOf : Dict k v -> k, k -> Order` (`:469`) is deleted, and the four private helpers that
thread the comparator — `getHelp :85`, `insertHelp :165`, `removeHelp :227`, `removeHelpEQGT :287`
— lose their `(k, k -> Order)` parameter and gain the constraint by inference. `mergeWith` and
`mergeWithHelp` are **not** Dict's: they are `core/List.beni:431,436`, the merge step of
`List.sortWith`, and they keep their comparator parameter (§5.5).

| `master` | Branch |
|---|---|
| `pub empty : (k, k -> Order) -> Dict k v` | `pub empty : Dict k v` |
| `pub singleton : k, v, (k, k -> Order) -> Dict k v` | `pub singleton : k, v -> Dict k v` |
| `pub fromList : List ( k, v ), (k, k -> Order) -> Dict k v` | `pub fromList : List ( k, v ) -> Dict k v where k.compare : k, k -> Order` |
| `pub get : Dict k v, k -> Maybe v` | `… where k.compare : k, k -> Order` |
| `pub member : Dict k v, k -> Bool` | `… where k.compare : k, k -> Order` |
| `pub insert : Dict k v, k, v -> Dict k v` | `… where k.compare : k, k -> Order` |
| `pub remove : Dict k v, k -> Dict k v` | `… where k.compare : k, k -> Order` |
| `pub update : Dict k v, k, (Maybe v -> Maybe v) -> Dict k v` | `… where k.compare : k, k -> Order` |
| `pub union`, `pub intersect`, `pub diff` | `… where k.compare : k, k -> Order` |
| `pub filter`, `pub partition` | `… where k.compare : k, k -> Order` (both rebuild through `insert`) |
| `pub merge` | `… where k.compare : k, k -> Order` — it reads the comparator out of the left dictionary today (`core/Dict.beni:444-445`) and walks both in key order |
| `pub size`, `isEmpty`, `map`, `foldl`, `foldr`, `keys`, `values`, `toList` | unchanged — none of them compares a key |

`empty` and `singleton` take **no** constraint and stay constants/plain functions: neither compares
anything. The plan's `Dict.empty : () -> Dict k v` was a precaution against a constrained constant
becoming a function (§8.1), and `empty` is not constrained, so the `()` is not needed. Appendix A.8.

### 5.4 `Set`

`core/Set.beni:29` is unchanged (`pub opaque type Set t = Set (Dict t ())`); the comparator
parameter leaves four signatures and the constraint arrives on nine.

| `master` | Branch |
|---|---|
| `pub empty : (t, t -> Order) -> Set t` | `pub empty : Set t` |
| `pub singleton : t, (t, t -> Order) -> Set t` | `pub singleton : t -> Set t` |
| `pub fromList : List t, (t, t -> Order) -> Set t` | `pub fromList : List t -> Set t where t.compare : t, t -> Order` |
| `pub map : Set a, (b, b -> Order), (a -> b) -> Set b` | `pub map : Set a, (a -> b) -> Set b where b.compare : b, b -> Order` — the ordering argument goes, the callback stays last |
| `pub insert`, `remove`, `member`, `union`, `intersect`, `diff`, `filter`, `partition` | `… where t.compare : t, t -> Order` |
| `pub isEmpty`, `size`, `toList`, `foldl`, `foldr` | unchanged |

### 5.5 `List`

| `master` | Branch |
|---|---|
| `pub sort : List number -> List number` (`:368`) | `pub sort : List a -> List a where a.compare : a, a -> Order` |
| `pub sortBy : List a, (a -> number) -> List a` (`:376`) | `pub sortBy : List a, (a -> b) -> List a where b.compare : b, b -> Order` |
| `pub sortWith : List a, (a, a -> Order) -> List a` (`:387`) | unchanged — an explicit ordering is still how you sort by something that is not the type's own |
| `pub member : List (equatable a), a -> Bool` (`:182`) | `pub member : List a, a -> Bool where a.eq : a, a -> Bool` |
| `pub maximum : List number -> Maybe number` (`:219`), `minimum` (`:233`) | unchanged, still `number` |

`sortBy` is generalised rather than left alone, because leaving it at `number` while `sort` is
generic makes `List.sortBy people .name` fail for no reason a reader could state. Appendix A.9.

### 5.6 `Basics`

Everything stays declared and exported. `eq`, `neq`, `lt`, `gt`, `le`, `ge` and `compare` are no
longer what `language.md` §6.5's operators mean (§3.1) but remain ordinary callable functions, so
`compare a b` in a `case` and `List.sortWith xs (\a b -> compare b a)` keep working unchanged.

### 5.7 Two deletions

`core/Dict/String.beni` and `core/Dict/Int.beni` are deleted. They exist only to hide the
comparator argument (their own doc comments say so, `core/Dict/String.beni:3-5`), and after §5.3
`Dict.empty` and `Dict.fromList` are exactly what they wrapped. `core/Dict.beni`'s module doc
loses its paragraph about them (`:24-25`) and `core/String.beni:11-12` loses its reference.

There are no `Set.String` / `Set.Int` modules to delete.

---

## 6. The checker

This section extends `checker.md` §5 (the type store), §6.2 (solving), §6.3 (generalisation), §6.4
(obligations) and §7 (the interface record). It is written as **rules**: an implementer building
slice S3 should need nothing else.

### 6.1 Representation

A method constraint rides on the payload struct that flex and rigid variables already share, beside
`equatable` — the same place Roc keeps `Flex.constraints`:

```zig
// check/TypeStore.zig
pub const Flags = struct {
    name: Symbol.Optional = .none,
    kind: Kind = .any,
    equatable: bool = false,
    constraints: ConstraintSet.Optional = .none,   // NEW: enum(u32), an index into `constraint_sets`
};

pub const MethodConstraint = struct {
    name: Symbol,                 // the method's name
    fn_var: Var,                  // the method's type AT THIS USE, e.g. `a, A, B -> R`
    region: Bir.Inst.Index,       // where it came from
    origin: enum(u8) { dot_call, well_known, where_clause, type_dispatch },
    site: Site,                   // (inst, evidence_index) — §7
};
```

Five invariants, each load-bearing:

| # | Invariant | Why |
|---|---|---|
| 1 | A `ConstraintSet` is an `enum(u32)` index into a per-store `constraint_sets: std.ArrayList(Range)`, each `Range` a half-open run of a per-store `constraints: std.ArrayList(MethodConstraint)` — two flat tables, never a pointer or a map | the house data rule (`fast-compiler.md` §5); it keeps `Flags` one word wider and makes rollback two truncations |
| 2 | Sets are **append-only**. Merging two sets appends a third and leaves both originals | the undo journal rolls speculation back by truncating `constraints.items.len`, exactly as it truncates the descriptor journal (`checker.md` §5) |
| 3 | A set holds **at most one constraint per name** | the spike's simplification; two uses at different types unify (§6.2). Roc's August-2026 principality fix is stretch item 1 (§11) |
| 4 | Constraints are stored in **insertion order** and sorted only when written to an interface or rendered | sorting on every merge would be quadratic; sorting at the two boundaries is what determinism needs (§6.5) |
| 5 | `Kind` is **not** extended | `fast-compiler.md` §3.1 closes that set, and a method constraint is not an ad-hoc kind |

**`Descriptor` does not grow.** `Flags` goes from 8 bytes to 12 (`name: u32`, `kind: u8`,
`equatable: bool`, 2 bytes of padding, `constraints: u32`), and the largest `Content` payload is
already `Alias` at 16 bytes (`TypeId`, `Range`, `Var` — `src/check/TypeStore.zig:186-192`), so the
union's payload is unchanged and `Descriptor` stays 40 bytes. Measurement **M1a therefore measures
time, not memory**: what dispatch costs code that never uses it is the extra branch in `unify` and
the extra arm in the drain loop, not a wider store. If that is measurable, the fallback recorded in
the plan is a side table keyed by root `Var` and moved on merge, which changes nothing in this
section but `Flags`.

### 6.2 Unification

Three sites in `unify` gain a rule; everything else in `checker.md` §6.2 is unchanged.

**Rule U1 — flex ⊓ flex.** Union the two constraint sets onto the surviving root, beside the
existing `equatable` OR and `Kind` meet:

- a name present on one side only is copied across;
- a name present on **both** sides unifies the two `fn_var`s. On failure the diagnostic is
  `method_constraint_mismatch`, reported at the **younger** region — the one with the larger
  `Bir.Inst.Index`, which is the later occurrence in the file, because that is the use the author
  most likely added last;
- the merged set is a fresh range; neither input range is mutated (invariant 2).

**Rule U2 — flex vs rigid.** The rigid's constraint set is what its `where` clause declared (§2.4)
and is never extended. For every constraint on the flex:

- present by name on the rigid: unify the two `fn_var`s; a failure is `method_constraint_mismatch`;
- absent: `missing_where_constraint`, reported **at the flex's region** — the call in the body that
  needs the method — naming the variable, the method, the type wanted, and the `where` clause that
  would fix it. It is deliberately not reported at the annotation: report 18 §2.4 records Roc's
  complaint that a missing constraint surfaces far from the code that needs it, and this rule is
  the answer to it.

The rigid keeps its own set; the flex is bound to the rigid as usual.

**Rule U3 — flex vs structure, alias or `err`.** Do **not** walk. Register one obligation
`.method{ constraint }` on the concrete variable per constraint in the flex's set, at the
constraint's own region, exactly as a flagged-`equatable` flex does today (`checker.md` §6.2, "a
flex var marked equatable that meets a structure registers an obligation instead of walking"). The
walk happens once, at discharge (§6.3). Against `err` nothing is registered and nothing is
reported.

**Rule U4 — rigid vs rigid.** Unchanged: non-identical rigids are `rigid_mismatch` and the
constraint sets are not consulted.

### 6.3 Discharge

`Solve.dischargeObligations` gains one arm. `dischargeMethod(ob)` resolves the obligation's
variable to its root and switches on the content:

| Content | Action |
|---|---|
| `flex` | **fold** the constraint into that variable's set by Rule U1 and stop. It will be promoted at generalisation (§6.4) or discharged later against a concrete type. This is the accumulate-until-nominal shape `dischargeEquatable` already has |
| `rigid` with the name in its set | unify `fn_var`s; record the site's target as `evidence k` where `k` is the enclosing declaration's canonical index for `(that rigid, name)` (§7.2) |
| `rigid` without the name | `missing_where_constraint` (Rule U2's message, at the constraint's region) |
| `app T args` | §6.3.1 |
| `alias` whose `actual` is available — every same-module alias, and any alias already instantiated in this store | discharge against `actual`. The alias is transparent (`fast-compiler.md` §3.1), so its methods are the expansion's |
| `alias` declared in another module, whose body cannot be read (`Interface.alias_body`, `checker.md` §7) | `no_methods_on_shape`, naming the alias. §11 records this as a spike gap that closes the moment `alias_body` lands |
| `record(fields, ext)` with `ext` **closed** (`empty_record`) | well-known name (§1.3 marked): target `derived { kind, shape = record(sorted field names) }`, and register the same obligation on **every field type**. Any other name: `no_methods_on_shape`, with the hint "write `(x.m) a` for a field call" |
| `record(fields, ext)` with `ext` still a variable — an **open** record | `no_methods_on_shape`. An open record's field set is not yet known, so neither the shape key (§9.2) nor the field obligations can be computed, and a later-arriving field would silently change which function ran |
| `tuple(args)` | well-known name: target `derived { kind, shape = tuple(arity) }`, and register the same obligation on every element type. Any other name: `no_methods_on_shape` |
| `unit` | well-known name: target `derived { kind, shape = unit }`. Any other name: `no_methods_on_shape` |
| `func` | `eq`: **`dischargeMethod` reports `not_equatable` itself**, directly. Today that code fires off `Flags.equatable`, which is set by instantiating `Basics.eq`'s `equatable a` marker — and after §3.1 nothing instantiates `Basics.eq` for `==` any more, so the code would become unreachable if this arm did not raise it. Anything else, `compare` included: `no_methods_on_shape` |
| `err` | silence (`checker.md` §6.2) |

**§6.3.1 — the `app T args` case, in order.**

1. **The well-known table (§3.2).** If the name is `eq` or `compare`, the call is marked (§1.3) and
   `T` is one of the seven core types, take the table's answer and stop.
2. **The module rule.** `Types.Entry.module` gives `T`'s declaring module.
   - It is the module being checked: look the name up among **all** its declarations, `pub` or not,
     in the module's own `Bir` declaration table. **Not** through `Interface.Provenance`: that maps
     only the `pub` entries of the interface back to their declarations
     (`src/resolve/Interface.zig:42,455` — `values` is "the `pub` values" and `build` skips
     everything else), so a private method would be invisible and `private_method` could never be
     distinguished from `unknown_method` inside the declaring module. The Bir is in memory for the
     module being checked by construction, so this is not the cross-module Bir read `checker.md`
     §4.5 forbids. Found → target `top(decl)`.
   - It is another module: `Interface.findValue` binary-searches that module's values. Found and
     `pub` → target `ext(module, value)`. Found and not `pub` → `private_method`.
3. **Instantiate and unify.** Instantiate the found scheme into the local store (`importedValue` /
   `makeCopy`) and unify it with the obligation's `fn_var`. Instantiating a *constrained* scheme
   creates fresh flex variables carrying fresh constraint sets, which register their own
   obligations; the drain loop already re-reads its list because discharge can register more
   (`checker.md` §6.4), so nothing new is needed for the recursion.
4. **Derive.** Not found, the name is well-known and the call is marked: target
   `derived { kind, shape = nominal(T) }`. A `foreign type` that reached here has no constructors
   and no table row, so it falls to 5.

   **Derivation for a nominal type is eager, and happens in the declaring module** (§8.5, §9.4). A
   use site therefore *names* `T`'s derived function; it does not request one. Nothing else works:
   `Dispatch` is per module and is filled at the end of that module's own `ModuleCheck.run`, `T`'s
   module is checked and lowered **before** the using module under §6.8's edges, and a request that
   travelled backwards would make `T`'s module's output depend on which other module got there
   first — output that varies with `--jobs`, which CLAUDE.md rule 5 forbids outright. So:

   > **Every nominal type declared in a module gets `eq` and `compare` derived in that module,
   > used or not**, with two exclusions. A type whose declaring module supplies a `pub` value of
   > that name gets that instead (step 2). A type **any** of whose constructor payloads contains a
   > function type, directly or through another type, gets **neither**; a use then reports
   > `not_equatable` (for `eq`) or `no_methods_on_shape` (for `compare`) at the use, exactly as the
   > `func` row of §6.3 says.

   The exclusion is computed by the same walk `equatable` already does (`checker.md` §6.4, "a
   structure: walk it once with a mark as the cycle guard"), so it costs one traversal per declared
   type and reuses the answer `Types.build` settles for `equatable` anyway. Appendix A.23.
5. **Fail.** `unknown_method`, listing the module's `pub` value names within edit distance 2 of the
   name (`checker.md` §8, "record field typos by edit distance").

**Budget.** The drain loop's `1 << 20` iteration bound applies unchanged in value, but **not in
behaviour**: today `dischargeObligations` (`src/check/Solve.zig:1256-1277`) falls out of the `while`
when the bound is reached and then clears the list, so an exhausted budget is silently a checked
module with unchecked obligations — the hole `checker.md` §5's "a guard that poisons must report
first" exists to close. Method obligations can register more obligations (step 3), so the bound is
now reachable by input rather than only by a compiler bug. The branch requires:

> Reaching the `1 << 20` bound reports `nesting_too_deep` at the declaration whose rank is being
> discharged and poisons every variable still carrying an undischarged obligation, before the list
> is cleared. In a debug build it additionally `@panic`s, because in a debug build it is a compiler
> bug and a message would hide it.

`tests/corpus/check/depth/` cannot reach `1 << 20` in a fixture of reasonable size, so this guard is
asserted by an in-source test that drives the drain loop directly — the one place where
`checker.md` §3's "in-source tests are a supplement" is the only option, and it is a supplement to
the two `ConstraintChain` fixtures below, not a replacement for them.

The constraint chain gets a guard of its own: derivation recursion and constraint-instantiation
recursion are both bounded at `Parse.max_depth + 104`, the value `checker.md` §5 requires such
guards to be *derived* from rather than to spell. Crossing either reports `nesting_too_deep` at the
declaration and poisons the variable — never silently, per `checker.md` §5's "a guard that poisons
must report first". `tests/corpus/check/depth/ConstraintChain{Ok,Deep}.beni` is the pair.

### 6.4 Generalisation and promotion

Constraints ride on `Flags`, so `generalize` and `makeCopy` carry them within a module for free,
with one addition: **`copyHelp` must copy each constraint's `fn_var` through the same memo** as the
rest of the scheme, or instantiation will share a method type between two instantiations and the
two uses will be wrongly unified.

At generalisation, a constraint still sitting on a flex variable of the generalised rank is
**promoted** into the scheme, becoming part of the declaration's type:

| Declaration | Promotion | Diagnostic |
|---|---|---|
| annotated | never — the annotation's `where` clause is the whole set (Rule U2), and anything else was already `missing_where_constraint` | — |
| unannotated, not `pub` | promoted silently; the scheme is local and nothing outside the module sees it | — |
| unannotated, `pub` | promoted into the **interface** (§6.5), which is what makes report 18 §2.3's churn question measurable | `ambiguous_method_receiver`, severity **`warning`**, emitted only under `--explain` |
| a `pub` value of **zero parameters** whose promoted scheme has at least one constraint | rejected | `constrained_constant` |

`constrained_constant` exists because a value with evidence parameters is a function (§8.1), and
silently turning a declared constant into a function would change its type across the module
boundary. The author's fix is to give it a parameter or an annotation that pins the type.

`--explain` is a new flag on `beni check` and `beni build` that emits informational diagnostics
otherwise suppressed. It adds **no new severity**: `diagnostic.Severity` stays
`{ error, warning }` (`src/diagnostic.zig:17`), `ambiguous_method_receiver` is a `warning`, and a
warning does not change the exit code (`frontend.md:44-45`), so `--explain` can never turn a
passing build into a failing one. It is the only diagnostic the flag controls in the spike, and the
churn measurement (plan §7 M3) is what reads it. §10's preamble has the flag's full contract;
Appendix A.10.

### 6.5 Interfaces

`Interface.Quantified` grows from two words to four:

```zig
pub const Quantified = struct {
    kind: u8,
    equatable: bool,
    name: SymbolIndex.Optional,
    constraints_start: u32,     // NEW: index into `extra`
    constraints_len: u32,       // NEW: number of CONSTRAINTS, not of words
    pub const words = 4;        // was 2
};
```

| Word | Contents |
|---|---|
| 0 | `kind \| (equatable << 8)` — the existing `flags()` packing, unchanged |
| 1 | `name`, a `SymbolIndex` into this interface's own `symbols` column |
| 2 | `constraints_start` |
| 3 | `constraints_len` |

Each constraint is **two words** in `extra` at `extra[constraints_start ..][0 .. 2 * constraints_len]`:
a `SymbolIndex` for the method name, then a `TermIndex` for its type. Rules:

1. **Sorted by name text**, never by symbol id, for the reason `checker.md` §7 already gives for
   record fields: a `Symbol` is an index into the session interner whose numbering depends on which
   worker interned which file, and the bytes of this record are what `fast-compiler.md` §8.1 has M4
   hashing.
2. **Every name is a `SymbolIndex`**, never a `Symbol`. Same reason.
3. `var(i)` inside a constraint's term means **quantifier `i` of the same scheme**, exactly as it
   does in the body, so a dependent rebuilds the constraint from this record alone.
4. A quantifier with no constraints writes `constraints_start = 0, constraints_len = 0` and
   consumes no `extra`.

`Schemes.Writer.quantifierOf` writes the block; `Schemes.instantiate` reads it, allocating a fresh
flex variable with a **fresh** constraint set whose `fn_var`s are built from the terms. Each
constraint created by an instantiation is tagged with the `(inst, evidence_index)` of the
instruction that caused it (§7.2).

`dump --stage=raw` prints them, so the `--jobs=1` vs `--jobs=8` byte comparison
(`tests/blackbox/blackbox_test.zig`'s determinism test) covers them:

```
scheme 3 body=17 quantified=2
  q 0 kind=0 equatable=false name=k constraints=1
    where compare term=11
  q 1 kind=0 equatable=false name=v constraints=0
```

### 6.6 Rendering

`Render.writeScheme` and `Render.writeVar` are today the **same function** under two names — both
are `write(w, cx, namer, v, .top \| prec, 0)` (`src/check/Render.zig:140-154`) — and the branch
separates them. `writeScheme` gains a body of its own: it calls `write` for the type and then
appends the suffix.

> After the body, if any quantified variable carries a constraint, write one space, `where`, one
> space, then the constraints separated by `, `, each written `<var>.<method> : <type>`.

Ordering is **by variable name as rendered, then by method name text** — a total order that is a
function of the scheme, not of the store. The whole thing is one line; it is the renderer, not the
formatter, and the two differ on purpose (§2.5).

```
Dict k v, k, v -> Dict k v where k.compare : k, k -> Order
List a, List b -> List ( a, b ) where a.eq : a, a -> Bool, b.compare : b, b -> Order
```

`writeVar` and `allocType` — the two entry points **every diagnostic** uses, since a diagnostic
builds prose out of type fragments rather than printing a scheme — are unchanged and print **no**
`where` suffix. A constraint belongs to a scheme, not to a type, and a two-type mismatch message is
already the busiest prose in the compiler. So the claim is narrow and exact:

| Consumer | Calls | Shows constraints |
|---|---|---|
| `dump --stage=types` (`src/dump/types.zig:55`) | `writeScheme` | yes, on the declaration line |
| `dump --stage=interface` | `writeScheme` | yes, on the `value` line |
| `dump --stage=raw` | neither — it prints the record (§6.5) | yes, as `where` lines under `q` |
| `type_mismatch`, `too_few_args`, and every other message that lays two types out | `writeVar` / `allocType` | **no** |
| `missing_where_constraint` (§10.4), `method_constraint_mismatch` (§10.5), `ambiguous_method_receiver` (§10.9) | `writeVar` for the method type, plus `writeScheme` for the whole scheme in §10.9 | yes, in their own prose: they name the variable, the method and the wanted type explicitly, which is what report 18 §2.4 says the caller needs |

**What `dump --stage=types` renders from.** It prints `decl_display[i]`, which for an **annotated**
declaration is the *rigid* reading of the annotation and not the generalised scheme
(`src/check/Check.zig:76-83`, `src/dump/types.zig:54`) — two structurally identical trees over
different variables. So the suffix there is built from the **rigid variables' own constraint sets**
(§2.4: exactly what the `where` clause declared), not from the scheme's `Quantified` blocks. For an
unannotated declaration `decl_display` is the scheme and the two agree by construction. Getting this
wrong prints an empty `where` on every annotated declaration, which is the most likely S3 golden
failure after §7.2's ordering.

```
module Dict
  value empty : Dict k v
  value insert : Dict k v, k, v -> Dict k v where k.compare : k, k -> Order
```

### 6.7 Return-type dispatch in the solver

`type_dispatch { var, name, args }` needs no new mechanism (§4.2). The generator resolves `var`
against the declaration's rigid annotation variables, requires `name` in that rigid's set —
absence is `type_dispatch_needs_annotation`, caught in lowering (§4.1) and re-checked here for a
poisoned annotation — unifies the constraint's `fn_var` with `(arg₁, …, argₙ) -> result`, types the
instruction `result`, and records the site's target as `evidence k` (§7.2). At a call site the
constraint instantiates to a flex, unification makes it concrete, and §6.3 takes over.

### 6.8 Parallel checking

`x.m` reaches the module that declares `x`'s type, which **need not be an import edge of the
current module**: a value can arrive through a third module without its type's home ever being
named. `checker.md` §4 builds the graph from explicit imports plus used prelude rows, so the DAG
would allow the declaring module to be checked concurrently with its use, and the use would read a
half-built interface. That is a data race, not a wrong answer.

The rule, applied at resolve time and to the graph only:

> A module gains an implicit edge to the declaring module of every `TypeId` that occurs in its own
> Bir as an `ext_type`, and of every `TypeId` reachable through the terms of any scheme it
> instantiates from an imported interface.

`Graph.referencedModules` already computes an edge set of exactly this shape for conditional
prelude rows (`checker.md` §4 step 3), so the addition is one more source of edges into a function
that exists. Everything else is untouched: the order is still the stable topological one, ties
still broken by `(package, path)`, a project with a cycle still runs serially, and ids are still
assigned before any thread starts (`fast-compiler.md` §10, CLAUDE.md rule 5).

**Cost.** The edge set grows, so the DAG's width shrinks: under the module rule, any module using
`Dict String Int` now depends on `Dict`, `String` and `Basics` whether or not it imports them.
Measurement M1 sees this as a throughput number, and it is one of the two costs the spike exists to
put a figure on.

---

## 7. The dispatch table

The backend sees no types (`backend.md` §3; `Lower.Input` carries interfaces and a graph, never a
store). Everything the checker decided about a method call therefore has to cross as data. The
dispatch table is that data: one per module, flat, index-based, immutable once built, in the shape
of `Bir.refs`.

### 7.1 The record

```zig
pub const Dispatch = struct {
    pub const Shape = union(enum(u8)) {
        nominal: Types.TypeId,          // a `type`, `opaque type` or `foreign type`
        record: SymbolRange,            // field names, sorted by name text
        tuple: u8,                      // arity
        unit,
    };                                  // there is no `prim` shape: a primitive is a `Target`

    pub const Target = union(enum(u8)) {
        top: Bir.DeclIndex,                                       // a value of this module
        ext: struct { module: Graph.Index, value: Interface.ValueIndex },
        evidence: u16,                                            // the k-th evidence parameter
        primitive: enum(u8) { strict_eq, num_compare, char_compare, string_compare },
        derived: u32,                                             // index into `derived`
        field,                                                    // a record: a plain field call
        err,
    };

    pub const Site = struct { inst: Bir.Inst.Index, evidence_index: u16, target: Target };
    pub const Evidence = struct { quantified: u16, var_name: SymbolIndex, method: SymbolIndex };
    pub const Derived = struct { kind: enum(u8) { eq, compare }, shape: Shape, parts: Range };

    sites: []Site,                     // sorted by (inst, evidence_index)
    decl_evidence: []Range,            // per declaration, into `evidence`
    evidence: []Evidence,              // canonical order within each declaration
    derived: []Derived,                // SORTED by emitted name text (§8.5)
    parts: []Target,                   // one Target per structural position of a derived function
};
```

`derived` is sorted **before** anything indexes it: `Target.derived: u32` and `Derived.parts` are
indices into the *sorted* arrays, so the table a dump prints and the table the emitter walks are the
same table in the same order, and `--jobs` cannot move a byte of either. A builder that appends
while discharging must therefore sort and remap once, at the end of `ModuleCheck.run`, together
with the `(inst, evidence_index)` sort of `sites`.

`Check.Module` gains `dispatch: Dispatch`. It is filled at the end of `ModuleCheck.run` while the
store is still alive, kept regardless of `keep_stores`, and handed to `Lower.Input` beside
`interfaces`.

### 7.2 What a site is, and canonical order

| Instruction | Sites |
|---|---|
| `method_call` or `type_dispatch` | one site at `evidence_index = 0`: **which function to call** |
| any instruction — `call`, `method_call`, a bare reference — that **instantiates** a scheme with `n` evidence parameters | `n` further sites, `evidence_index` running `1 … n` for a `method_call` and `0 … n-1` otherwise: **which value to pass** for each |

Every constraint created by an instantiation is tagged with the `(inst, evidence_index)` of the
instruction that created it, which is how a target found at discharge finds its way back to a site.

**Canonical order** is a function of the scheme record alone, never of variable identity, because
callee and caller compute it independently — Roc's contract:

> For the quantified variables of the scheme, **in the order `Schemes.Writer` records them**, and
> within each variable for its constraints in name-text order, emit one evidence slot. Number them
> from 0.

`Schemes.Writer`'s order is a discovery order over the written body, and it is **not** the
annotation's left-to-right source order, because the writer re-sorts a record's fields by name text
before descending into them (`src/check/Schemes.zig:295`) precisely so that the bytes of the record
do not depend on symbol ids. So `f : { b : x, a : y } -> x` discovers `y` before `x`. Caller and
callee both derive the order from the scheme record, never from the source and never from variable
identity, so they agree; a spec that said "left to right in the annotation" would have them disagree
silently, which is the worst failure mode this table has. Appendix A.24.

The closure rule of §2.4 is what makes the rule total: every variable a constraint can mention is a
quantifier of the scheme, so every constraint has a slot.

`Dispatch.Evidence` records the `(quantified, method)` pair each slot came from so the dump can
name it and so a mismatch is a caught bug rather than a silent miscompile.

### 7.3 `dump --stage=dispatch`

`Cli.Stage` gains `dispatch`, so the CLI reads
`tokens, ast, bir, interface, raw, types, dispatch`. Like `--stage=interface` it accepts a
directory as well as a file. The format is line-oriented, one fact per line, with **no symbol ids,
no positions and no module indices** — every name is text, so reformatting the input leaves a
golden untouched and `--jobs` cannot move a byte (the rule `dump/types.zig` already states).

```
module <ModuleName>
  decl <name> evidence=<n>
    evidence <k> quantified=<q> var=<varName> method=<methodName>
  derived <i> <eq|compare> <shape>
    part <j> <target>
  site <inst> <evidence_index> <target>
```

- `decl` lines are in **source order**; a declaration with no evidence prints `evidence=0` and no
  `evidence` lines. A module with no dispatch at all prints its `module` line and nothing else.
- `derived` lines are in the emission order of §8.5 (by emitted name text), `part` lines in
  structural order (§9).
- `site` lines are sorted by `(inst, evidence_index)`, `inst` printed as the decimal Bir
  instruction index.

Target spellings, exhaustive:

| `Target` | Printed |
|---|---|
| `top` | `top <declName>` |
| `ext` | `ext <ModuleName> <valueName>` |
| `evidence` | `evidence <k>` |
| `primitive` | `primitive strict_eq` \| `primitive num_compare` \| `primitive char_compare` \| `primitive string_compare` |
| `derived` | `derived <i>` |
| `field` | `field` |
| `err` | `err` |

Shape spellings, exhaustive, and the same strings §8.5 builds names out of:

| `Shape` | Printed |
|---|---|
| `nominal` | `<ModuleName>.<TypeName>` |
| `record` | `r$<field1>$<field2>$…`, fields sorted by name text |
| `tuple` | `t<arity>` |
| `unit` | `unit` |

Worked example. Source:

```elm
import Dict exposing (Dict)


pub tally : List String -> Dict String Int
tally names =
    List.foldl names Dict.empty (\n d -> Dict.insert d n 1)
```

```
module Tally
  decl tally evidence=0
  site 12 0 primitive string_compare
```

`Dict.insert` is an ordinary `call`, not a `method_call`, so §7.2 numbers its evidence sites from
**0** and there is no site naming the callee — a `call`'s callee is already in the Bir. `Dict.empty`
has no constraint (§5.3) and so no site at all. `Dict.insert`'s scheme quantifies `k` then `v`; only
`k` carries `compare`, so there is exactly one evidence slot, and `k` is `String`, whose `compare`
is `primitive string_compare` (§3.2). In *value* position that target is emitted as the eta-expanded
closure of §8.2, not as an inline operator.

A second example, with a `method_call`, where the callee site **is** present and the numbering
starts at 1:

```elm
pub bigger : Shape, Shape -> Bool
bigger a b =
    a.wider b
```

```
module Shapes
  decl bigger evidence=0
  derived 0 eq Shapes.Shape
    part 0 primitive strict_eq
  derived 1 compare Shapes.Shape
    part 0 primitive num_compare
  site 7 0 top wider
```

`derived 0` and `derived 1` are there even though nothing in the module uses `==` or `<` on
`Shape`: derivation for a nominal type is eager (§6.3.1 step 4, §8.5).

---

## 8. The backend

Extends `backend.md` §4 (codegen), §5 (module output) and §6 (the calling convention). §6's
"there isn't one" still holds for beni-level arity: what follows adds **hidden leading parameters**,
which are invisible in beni and fixed at every site by the checker.

### 8.0 What the lowerer receives

`Lower.Input` gains `dispatch: *const Dispatch` beside `interfaces`. Nothing else about the
backend's ignorance of types changes: it reads targets, never types.

### 8.1 Evidence parameters

`Lower.functionOf` — the one place parameter lists are built — prepends one parameter per entry of
`dispatch.decl_evidence[decl]`, **before** the declaration's own parameters, in canonical order
(§7.2). The k-th is named `$m$<k>`: a `JsIr.Name` with `module = .none`, `base` an interned
`"$m$k"`, and `no_tag`.

```js
// pub insert : Dict k v, k, v -> Dict k v where k.compare : k, k -> Order
export const Dict$insert = ($m$0, dict, key, value) => …;
```

A declaration of **zero** beni parameters that has evidence would become a function, changing its
type across the module boundary; the checker refuses it first (`constrained_constant`, §6.4), so
the backend never meets one.

Two consequences worth stating, because they are what M4 and M5 measure:

- the emitted arity of a `pub` value is now a function of its inferred scheme, so an edit that adds
  a constraint changes the emitted signature of every call site (report 18 §2.3);
- an evidence parameter is an ordinary JavaScript parameter holding a function reference, so a call
  through it is a direct call at a monomorphic site and V8 can inline it. That is report 18 §1.4's
  "N function arguments rather than one record", and the reason the record encoding is stretch
  item 3 and not the spike.

### 8.2 Call sites

`Lower.callExpr` — the one call-site lowering — looks the instruction up in `dispatch.sites` and
prepends one argument per site with `evidence_index > 0` for a `method_call`, or per site at all
for a `call`, in `evidence_index` order. The argument for each target:

| Target | Argument |
|---|---|
| `top d` | `Module$<name>` when that value takes no evidence of its own; otherwise the eta-expansion below |
| `ext (m, v)` | `<M>$<name>`, with `externalName` / `need` / `importStatements` adding the import exactly as for any other cross-module reference; likewise eta-expanded when it takes evidence |
| `evidence k` | `$m$<k>` — the enclosing declaration's own evidence, forwarded. Never eta-expanded: it is already a closure of the right arity |
| `primitive strict_eq` | `<Module>$eq$prim` (§9.1) |
| `primitive num_compare` / `char_compare` | `<Module>$compare$prim` / `<Module>$compare$char` (§9.1) — never an inline operator: an operator is not a value |
| `primitive string_compare` | `String$compare`, the core function itself (§3.2, §9.1) |
| `derived i` | the derived function's name (§8.5) when it takes no evidence; otherwise the eta-expansion below |
| `field`, `err` | cannot appear as evidence; a checker bug, and the emitter asserts |

**Evidence in value position is eta-expanded.** A target that itself takes evidence parameters — a
constrained `pub` value, or a derived function for a parametric type or a structural shape — is
**not** a function of the two arguments the evidence slot promises. Passing
`List$eq(Main$eq$r$x$y, …)` would pass the *result* of a call, and `List$eq` is not a value at all
until its evidence is bound; `backend.md` §6 (`backend.md:189`) requires every function-typed value
in flight to be a closure of known arity, and this is how that requirement is met here:

> A target with `n > 0` evidence parameters, in **value** position, is emitted as
> `(l, r) => <name>(<its own n evidence arguments…>, l, r)`, each of those arguments resolved by
> this same table, recursively. A target with `n = 0` is emitted as the bare name.

The same rule covers a **bare reference to a constrained value** — `List.sort` mentioned without
being called, `let f = Dict.insert` — which §7.2 already gives evidence sites: the reference is
lowered to `(a, b, c) => Dict$insert($m$…, a, b, c)` over the value's own beni arity, not to the
bare name, because the bare name has the wrong arity. Both cases are one rule: *a constrained value
used as a value is its eta-expansion.* Appendix A.25.

```js
// Dict.insert d name 1, where k = String
Dict$insert(String$compare, d, name, 1);

// inside a `where k.compare`-constrained function, forwarding
Dict$insert($m$0, dict, key, value);

// xs == ys at List (List Int): the inner List$eq takes evidence, so it is eta-expanded
List$eq((l, r) => List$eq(Main$eq$prim, l, r), xs, ys);

// `let cmp = Dict.insert` — a bare reference to a constrained value
const cmp = (a, b, c) => Dict$insert(String$compare, a, b, c);
```

### 8.3 `method_call`

| Target | Emitted |
|---|---|
| `top d` | `Module$m(receiver, args…)`, evidence first if the callee has any |
| `ext (m, v)` | `M$m(receiver, args…)`, likewise |
| `evidence k` | `$m$k(receiver, args…)` |
| `field` | `receiver.m(args…)` — exactly today's field call |
| `derived i` | the derived function's name applied to its evidence, then `(receiver, args…)` |
| `primitive p` | see below |
| `err` | `not_implemented` is not raised; the declaration already has a diagnostic and emits nothing |

A `primitive` target combines with the `well_known` marking of §1.3 to give the operator directly.
This is the only place the marking reaches the backend, and it is why the marking exists:

| `well_known` | `strict_eq` | `num_compare` | `char_compare` | `string_compare` |
|---|---|---|---|---|
| `eq` | `x === y` | — | — | — |
| `neq` | `x !== y` | — | — | — |
| `lt` | — | `x < y` | `CP(x) < CP(y)` | `String$compare(x, y) === "LT"` |
| `le` | — | `x <= y` | `CP(x) <= CP(y)` | `String$compare(x, y) !== "GT"` |
| `gt` | — | `x > y` | `CP(x) > CP(y)` | `String$compare(x, y) === "GT"` |
| `ge` | — | `x >= y` | `CP(x) >= CP(y)` | `String$compare(x, y) !== "LT"` |
| `none` | `x === y` (a hand-written `x.eq y` on a primitive) | `<M>$compare$prim(x, y)` | `<M>$compare$char(x, y)` | `String$compare(x, y)` |

`CP(e)` is `e.codePointAt(0)`, hoisted to a `const` when `e` is not already a name so that each
operand is evaluated once. Only `num_compare` becomes a bare JavaScript comparison: `<` on strings
is UTF-16 code-unit order and `String.compare` is Unicode scalar order, and the two must agree
(§3.2, §9.1, §11).

For a non-`primitive` target, an ordering operator wraps the `Order` result in a test:
`a < b` is `Shapes$Shape$compare(a, b) === "LT"`; `a <= b` is `… !== "GT"`; `a > b` is
`… === "GT"`; `a >= b` is `… !== "LT"`. `a == b` is `Shapes$Shape$eq(a, b)` and `a /= b` is
`!Shapes$Shape$eq(a, b)`. Both operands are evaluated exactly once, as they are today.

### 8.4 `type_dispatch`

Identical to §8.3 with no receiver: `type_dispatch { var, name, args }` emits the target applied to
`args` alone, evidence first. Its target is always `evidence k` inside a constrained declaration
(§6.7), so in practice it is `$m$k(args…)`.

### 8.5 Naming and emission order

A derived function is an ordinary module-level `const`, exported, referenced through the same
`externalName` / `need` / `importStatements` path as any other value. Its `JsIr.Name` has the
emitting module as `module` and an interned base, so the printer spells it `Module$base` as usual.

| What | Emitted in | When | Base | Printed |
|---|---|---|---|---|
| well-known method of a nominal type `T` in module `M` | `M`, always — even when the only use is elsewhere, and even when `T` is `pub opaque`, which is what makes derivation legal for an opaque type | **eagerly**: one `eq` and one `compare` per declared nominal type, used or not, unless a payload contains a function type (§6.3.1 step 4) | `<T>$eq`, `<T>$compare` | `Shapes$Shape$eq` |
| the tag-order table of a type with two or more constructors | `M` | with its `compare` | `<T>$order` | `Shapes$Colour$order` |
| a record shape | the **consuming** module, deduplicated per file | on demand: a shape is not declared anywhere, so there is no module to derive it in ahead of time | `eq$r$<f1>$<f2>$…` | `Main$eq$r$x$y` |
| a tuple shape | the consuming module | on demand | `eq$t<n>` | `Main$compare$t2` |
| `unit` | the consuming module | on demand | `eq$unit` | `Main$eq$unit` |
| a primitive, as a **value** (§9.1) | the consuming module | on demand | `eq$prim`, `compare$prim`, `compare$char` | `Main$compare$prim` |

**Why nominal derivation is eager.** A `Dispatch` table is per module and is built at the end of
that module's own check; `T`'s module is checked and lowered *before* any user of `T` under §6.8's
edges, so a use site cannot ask `T`'s module for anything. Deriving on demand would either put the
function in the consuming module — where an opaque type's constructors are not readable — or make
`T`'s module's bytes depend on which other module asked first, which varies with `--jobs`.
Deriving unconditionally removes the question. The price is that a type nobody compares still ships
two functions until DCE exists, which is what §11 records and M4 measures.

A structural shape has no owning module — `{ x : Int, y : Int }` can be mentioned by twelve modules
and is owned by none (report 18 §4.1) — so it is derived where it is used and duplicated across
files. That duplication is the other half of M4's per-type derived-function byte count.

**Emission order.** Derived functions are **not** `Bir.Decl`s: they have no declaration index, so
`emissionOrder` (`src/js/Lower.zig:354-374`), which post-orders the `bir.refs` graph over
declaration indices, cannot order them and is not asked to. Instead the lowerer emits them in a
**separate pass, before the declaration loop**, sorted by **printed name text ascending**:

```zig
// js/Lower.zig, in `lower`
try l.derivedFunctions(out);            // NEW: the sorted pass, §9
const order = try l.emissionOrder();    // unchanged, over Bir.Decl indices
for (order) |index| try l.declaration(out, index);
```

Sorted by name and not by request order because request order depends on which instruction was
discharged first: deterministic today, but not *obviously* so, and CLAUDE.md rule 5 asks for an
order a reader can check. Ordering *within* the pass never matters for correctness — every derived
function is an arrow, so a reference from one to another is resolved at call time and a forward
reference is fine — and the `<T>$order` table is the one exception: it is a plain object literal, so
it must precede the `compare` that indexes it. Sorting by name gives `Shapes$Colour$compare` before
`Shapes$Colour$order`, which is the wrong way round, so the pass emits **every `$order` table
first**, sorted by name, then every function, sorted by name. Two sorted runs, both byte-stable.

---

## 9. Derived `eq` and `compare`, in full

Written against the representation of `backend.md` §4 and its "Corrections from M3a": records are
objects with keys sorted by **name text**; a type with any argument-taking constructor pads every
constructor to `{$: "Tag", a, b, …}`; a type whose constructors are all nullary is a bare tag
string; `Basics.Bool` is `true`/`false`; a tuple is `{a, b, …}`; a list is `{$:1, a, b}` /
`{$:0, a:null, b:null}`; `()` is `null`; a `Char` is a one-scalar string.

**The `parts` contract.** Each `Dispatch.Derived` carries one `Target` per structural position, in
this order:

| Shape | Positions |
|---|---|
| `nominal` | every constructor argument, constructors in **declaration order**, arguments left to right. A position whose type is the type's own parameter `i` gets the target `evidence i` — the derived function's own evidence, not the enclosing declaration's |
| `record` | one per field, fields sorted by name text |
| `tuple` | one per element, 0 … n−1 |
| `unit` | none |

**Inside a derived body, a `primitive` part is emitted as the JavaScript operator**, not as a call
of the primitive comparator: there is a concrete pair of expressions to apply it to. That is the
difference from §8.2, where a primitive target is in *value* position and must be a function.

Throughout, `l` and `r` stand for the two expressions being compared at a position, and
`EQ(l, r)` / `CMP(l, r)` for what a part expands to:

| Part target | `EQ(l, r)` | `CMP(l, r)` |
|---|---|---|
| `primitive strict_eq` | `l === r` | — |
| `primitive num_compare` | — | `l < r ? "LT" : l > r ? "GT" : "EQ"` |
| `primitive char_compare` | — | `l.codePointAt(0) < r.codePointAt(0) ? "LT" : l.codePointAt(0) > r.codePointAt(0) ? "GT" : "EQ"`, hoisted into two `const`s when the operands are not already names |
| `primitive string_compare` | — | `String$compare(l, r)` — a call, never `<` (§3.2) |
| `top` / `ext` | `M$eq(l, r)` | `M$compare(l, r)` |
| `evidence k` | `$m$k(l, r)` | `$m$k(l, r)` |
| `derived i` | `<name>(<its evidence…>, l, r)` | likewise |

### 9.1 Primitives, as values

Emitted into any module that needs a primitive comparison **as a value** (§8.2), once per module:

```js
const Main$eq$prim = (x, y) => x === y;
const Main$compare$prim = (x, y) => (x < y ? "LT" : x > y ? "GT" : "EQ");
const Main$compare$char = (x, y) => {
  const a = x.codePointAt(0);
  const b = y.codePointAt(0);
  return a < b ? "LT" : a > b ? "GT" : "EQ";
};
```

| Type | `eq` as a value | `compare` as a value |
|---|---|---|
| `Int`, `Float` | `<M>$eq$prim` | `<M>$compare$prim` |
| `Bool` | `<M>$eq$prim` | `<M>$compare$prim` — `false < true` |
| `Order` and every other all-nullary type | `<M>$eq$prim` | its own derived function (§9.4) |
| `Char` | `<M>$eq$prim` | `<M>$compare$char` |
| `String` | `<M>$eq$prim` | **`String$compare`** — the core function, imported like any other cross-module value |

`$compare$prim` serves only the types JavaScript's `<` orders correctly: numbers and booleans.
`String` and `Char` are **not** among them. `core/String.js:40-57` compares Unicode scalar values
and its own comment says that is what `<` on JavaScript strings is not — an astral character sorts
below U+E000 under UTF-16 code-unit order — and a language where `"a" < "b"` and
`String.compare a b` could disagree would be worse than one with neither. So `String` routes to the
existing core function and `Char` gets a three-line code-point comparator of its own. §11 records
that this is a deliberate correctness-over-speed choice and M5 R3 is where its cost shows up.

### 9.2 Records

Shape key is the **sorted field-name list**, so one function serves every record with those field
names whatever the field types, with one evidence parameter per field in the same order. For
`{ x : Int, y : Int }` and for `{ x : String, y : List Int }` alike:

```js
const Main$eq$r$x$y = ($m$0, $m$1, x, y) => $m$0(x.x, y.x) && $m$1(x.y, y.y);

const Main$compare$r$x$y = ($m$0, $m$1, x, y) => {
  const o0 = $m$0(x.x, y.x);
  if (o0 !== "EQ") return o0;
  return $m$1(x.y, y.y);
};
```

`compare` on a record is **lexicographic in field-name order**, which is the order the object's
keys are already in. The empty record derives `() => true` and `() => "EQ"` (base
`eq$r`, `compare$r`).

Parameterising by field evidence rather than specialising per concrete field-type vector is a
decision, Appendix A.11: it bounds the number of emitted functions by the number of *shapes*
instead of the number of *instantiations*, which is what M4 is trying to measure, and it needs no
mangling of arbitrary types into a name.

### 9.3 Tuples and unit

Shape key is the arity; positions are the slot names `a`, `b`, `c`, … of `backend.md` §4.

```js
const Main$eq$t2 = ($m$0, $m$1, x, y) => $m$0(x.a, y.a) && $m$1(x.b, y.b);

const Main$compare$t3 = ($m$0, $m$1, $m$2, x, y) => {
  const o0 = $m$0(x.a, y.a);
  if (o0 !== "EQ") return o0;
  const o1 = $m$1(x.b, y.b);
  if (o1 !== "EQ") return o1;
  return $m$2(x.c, y.c);
};

const Main$eq$unit = (x, y) => true;
const Main$compare$unit = (x, y) => "EQ";
```

### 9.4 Nominal types

**All-nullary types** are bare tag strings, so `eq` is `===` and the checker gives the site
`primitive strict_eq` directly rather than a derived function (§6.3.1 step 4) — there is nothing to
derive. `compare` cannot be `<`, because the tags are compared alphabetically and the declaration
order is what the language means, so it takes an order table:

```js
// pub type Colour = Red | Green | Blue      (in module Colours)
const Colours$Colour$order = { Red: 0, Green: 1, Blue: 2 };
export const Colours$Colour$compare = (x, y) => {
  const a = Colours$Colour$order[x];
  const b = Colours$Colour$order[y];
  return a === b ? "EQ" : a < b ? "LT" : "GT";
};
```

`Order` itself is this case, which is why §3.2's table row for `Order.compare` is `derived` and not
a primitive: `"EQ" < "GT" < "LT"` alphabetically is not `LT < EQ < GT`.

**Types with a payload** pad every constructor, so the comparison switches on the tag and touches
only the arguments the live constructor has. Padding slots are `null` on both sides and are **not**
compared: comparing them would be harmless for `===` but wrong in general, because one slot can
hold different types in different constructors and a part's target is per-position, not per-slot.
The plan's "padding nulls are compared" is sharpened to this; Appendix A.12.

```js
// pub type Shape = Circle Float | Rect Float Float      (in module Shapes)
const Shapes$Shape$order = { Circle: 0, Rect: 1 };

export const Shapes$Shape$eq = (x, y) => {
  if (x.$ !== y.$) return false;
  switch (x.$) {
    case "Circle":
      return x.a === y.a;
    default:
      return x.a === y.a && x.b === y.b;
  }
};

export const Shapes$Shape$compare = (x, y) => {
  if (x.$ !== y.$) {
    return Shapes$Shape$order[x.$] < Shapes$Shape$order[y.$] ? "LT" : "GT";
  }
  switch (x.$) {
    case "Circle":
      return x.a < y.a ? "LT" : x.a > y.a ? "GT" : "EQ";
    default: {
      const o0 = x.a < y.a ? "LT" : x.a > y.a ? "GT" : "EQ";
      if (o0 !== "EQ") return o0;
      return x.b < y.b ? "LT" : x.b > y.b ? "GT" : "EQ";
    }
  }
};
```

Rules the two functions follow, and the reasons:

| Rule | Reason |
|---|---|
| the `switch` has no arm for the last constructor; it is the `default` | `backend.md` §7: a well-typed match needs no default arm, and `x.$` has been proved equal to `y.$` |
| a one-constructor type emits no `$order` table and no tag test | there is nothing to disagree about |
| a constructor with no arguments returns `true` / `"EQ"` for its arm | a padded nullary constructor carries only `null`s |
| `compare` orders constructors by **declaration order** | the language's rule everywhere else; the `$order` table is what makes it so |
| a recursive type's derived function calls itself by name | a top-level `const` arrow may reference itself from inside its body |
| the function is emitted in the **declaring** module, exported, and **eagerly** — once per declared nominal type whether anything uses it or not (§6.3.1 step 4, §8.5) | the declaring module is the only one that may read a `pub opaque type`'s constructors, and it is also the only one that can emit without its output depending on which *other* module asked first. Eager derivation is what makes the second half true |
| a type any of whose constructor payloads contains a function type gets **neither** derived function | there is nothing to emit; a use is `not_equatable` / `no_methods_on_shape` at the use (§6.3) |

**Parametric types** take one evidence parameter per type parameter, in declaration order, whether
or not the parameter is used — the uniform rule, which keeps the canonical order of §7.2 a function
of the type's own declaration:

```js
// pub type Maybe a = Nothing | Just a       (in module Maybe)
export const Maybe$Maybe$eq = ($m$0, x, y) => {
  if (x.$ !== y.$) return false;
  switch (x.$) {
    case "Nothing":
      return true;
    default:
      return $m$0(x.a, y.a);
  }
};

// pub type Result x a = Ok a | Err x        (in module Result)
export const Result$Result$compare = ($m$0, $m$1, x, y) => {
  if (x.$ !== y.$) {
    return Result$Result$order[x.$] < Result$Result$order[y.$] ? "LT" : "GT";
  }
  switch (x.$) {
    case "Ok":
      return $m$1(x.a, y.a);
    default:
      return $m$0(x.a, y.a);
  }
};
```

`Result x a` quantifies `x` then `a` (declaration order), so `$m$0` is `x`'s and `$m$1` is `a`'s,
and `Ok a` — which is declared first, hence `order.Ok = 0` — uses `$m$1`. Getting that pairing
wrong is the single most likely bug in S5, which is why the dump prints `part` lines.

**`Basics.Bool`** never reaches derivation: §3.2 gives it `primitive strict_eq` and
`primitive num_compare`, both of which are correct on JavaScript booleans, and `num_compare` orders
`False < True` (Appendix A.4).

### 9.5 `List`

`List a`'s methods are `pub foreign` values of module `List` (§5.2), so they are found by the
module rule and are not derived. They live in `core/List.js` because the list representation is the
emitter's, shared with core by contract (`backend.md` §4, "where the empty list comes from"), and
they are **loops**, because a long list would exhaust the JavaScript stack:

```js
// core/List.js
export const eq = (m0, xs, ys) => {
  let a = xs, b = ys;
  while (a.$ === 1 && b.$ === 1) {
    if (!m0(a.a, b.a)) return false;
    a = a.b;
    b = b.b;
  }
  return a.$ === b.$;
};

export const compare = (m0, xs, ys) => {
  let a = xs, b = ys;
  while (a.$ === 1 && b.$ === 1) {
    const o = m0(a.a, b.a);
    if (o !== "EQ") return o;
    a = a.b;
    b = b.b;
  }
  if (a.$ === b.$) return "EQ";
  return a.$ === 0 ? "LT" : "GT";
};
```

A shorter list is `LT` against a longer one with the same prefix, which is Elm's order and the
order `List.sort` on `List (List Int)` must produce.

### 9.6 Worked end-to-end example

```elm
-- Points.beni
pub type alias Point =
    { x : Int, y : Int }


pub type Shape
    = Circle Point Float
    | Rect Point Point


pub sorted : List Shape -> List Shape
sorted shapes =
    List.sort shapes
```

```js
// Points.mjs
import { List$sort } from "./List.mjs";

// --- the $order pass: every tag table, sorted by name (§8.5) ---
const Points$Shape$order = { Circle: 0, Rect: 1 };

// --- the derived-function pass: sorted by name (§8.5) ---
export const Points$Shape$compare = (x, y) => {
  if (x.$ !== y.$) {
    return Points$Shape$order[x.$] < Points$Shape$order[y.$] ? "LT" : "GT";
  }
  switch (x.$) {
    case "Circle": {
      const o0 = Points$compare$r$x$y(Points$compare$prim, Points$compare$prim, x.a, y.a);
      if (o0 !== "EQ") return o0;
      return x.b < y.b ? "LT" : x.b > y.b ? "GT" : "EQ";
    }
    default: {
      const o0 = Points$compare$r$x$y(Points$compare$prim, Points$compare$prim, x.a, y.a);
      if (o0 !== "EQ") return o0;
      return Points$compare$r$x$y(Points$compare$prim, Points$compare$prim, x.b, y.b);
    }
  }
};

export const Points$Shape$eq = (x, y) => {
  if (x.$ !== y.$) return false;
  switch (x.$) {
    case "Circle":
      return Points$eq$r$x$y(Points$eq$prim, Points$eq$prim, x.a, y.a) && x.b === y.b;
    default:
      return (
        Points$eq$r$x$y(Points$eq$prim, Points$eq$prim, x.a, y.a) &&
        Points$eq$r$x$y(Points$eq$prim, Points$eq$prim, x.b, y.b)
      );
  }
};

const Points$compare$prim = (x, y) => (x < y ? "LT" : x > y ? "GT" : "EQ");

const Points$compare$r$x$y = ($m$0, $m$1, x, y) => {
  const o0 = $m$0(x.x, y.x);
  if (o0 !== "EQ") return o0;
  return $m$1(x.y, y.y);
};

const Points$eq$prim = (x, y) => x === y;

const Points$eq$r$x$y = ($m$0, $m$1, x, y) => $m$0(x.x, y.x) && $m$1(x.y, y.y);

// --- the declaration pass, in `emissionOrder` (§1.4) ---
export const Points$sorted = (shapes) => List$sort(Points$Shape$compare, shapes);
```

Two things this shows that the source does not.

**`Points$Shape$eq` is emitted although nothing in the module uses `==`.** Derivation for a nominal
type is eager (§8.5), so `Shape` gets both methods and a use in any other module names them. So do
the two structural helpers `eq` needs.

**The order is the §8.5 order, not the dependency order.** `Points$Shape$compare` references
`Points$compare$r$x$y`, which is defined 20 lines below it, and `Points$Shape$eq` references
`Points$eq$prim` below that. Both are fine: every derived function is an arrow, so the reference is
resolved when it is called and not when it is defined. The one thing that must precede its user is
`Points$Shape$order`, a plain object literal, and that is why `$order` tables get a pass of their
own ahead of the functions.

`Point` is an alias **declared in this module**, so it is looked through (§1.2) and the record shape
is what derives; a `Point` imported from elsewhere would be `no_methods_on_shape` on the branch
(§11). `Float` and `Int` both reach `primitive num_compare` / `strict_eq`, which inside a derived
body is the inline operator and in the evidence position of `Points$compare$r$x$y` is
`Points$compare$prim`. `List.sort`'s one evidence parameter takes `Points$Shape$compare` — which
takes no evidence of its own, so it is passed by bare name and not eta-expanded (§8.2) — and the
whole chain is direct calls.

### 9.7 Worked example: evidence that is itself constrained

The case §8.2's eta-expansion exists for. Every evidence value here is a function that *takes*
evidence, so none of them can be passed by name.

```elm
-- Nested.beni
pub sameRows : List (List Int), List (List Int) -> Bool
sameRows a b =
    a == b


pub sorted : List { x : Int, y : Maybe Int } -> List { x : Int, y : Maybe Int }
sorted rows =
    List.sort rows
```

```js
// Nested.mjs
import { List$compare, List$eq, List$sort } from "./List.mjs";
import { Maybe$Maybe$compare } from "./Maybe.mjs";

// sorted by name (§8.5): compare$prim, compare$r$x$y, eq$prim
const Nested$compare$prim = (x, y) => (x < y ? "LT" : x > y ? "GT" : "EQ");

const Nested$compare$r$x$y = ($m$0, $m$1, x, y) => {
  const o0 = $m$0(x.x, y.x);
  if (o0 !== "EQ") return o0;
  return $m$1(x.y, y.y);
};

const Nested$eq$prim = (x, y) => x === y;

export const Nested$sameRows = (a, b) =>
  List$eq((l, r) => List$eq(Nested$eq$prim, l, r), a, b);

export const Nested$sorted = (rows) =>
  List$sort(
    (l, r) =>
      Nested$compare$r$x$y(
        Nested$compare$prim,
        (l2, r2) => Maybe$Maybe$compare(Nested$compare$prim, l2, r2),
        l,
        r,
      ),
    rows,
  );
```

Three layers, three eta-expansions, and every one of them is forced:

| Value | Arity it must have | Arity its name has | So |
|---|---|---|---|
| `List a`'s `eq` as evidence for the outer `List (List Int)` | 2 | `List$eq` is 3 (one evidence + two lists) | eta-expand, binding the inner element evidence |
| the record shape's `compare` as evidence for `List.sort` | 2 | `Nested$compare$r$x$y` is 4 (two fields' evidence + two records) | eta-expand |
| `Maybe a`'s `compare` as the `y` field's evidence | 2 | `Maybe$Maybe$compare` is 3 | eta-expand |
| `Int`'s `compare` as the `x` field's evidence | 2 | `Nested$compare$prim` is 2 | bare name |

`Maybe$Maybe$compare` is imported rather than derived here because `Maybe` is declared in
`core/Maybe.beni` and derivation for a nominal type happens in the declaring module, eagerly
(§8.5). Nothing in `core/Maybe.beni` uses `compare` on a `Maybe`; it is emitted anyway, and that is
the size cost M4 reports.

---

## 10. Diagnostics

Ten codes join the catalogue of `language.md` §10 and `checker.md` §8.1, appended **after** the M3a
lines and before nothing — appended, never inserted, so no existing line moves. Every one gets a
fixture: **eight** under `tests/corpus/check/bad/`, and the two that lowering reports —
`where_variable_unbound` and `duplicate_where_constraint` — under `tests/corpus/parse/bad/`.

```
unknown_method  private_method  no_methods_on_shape  missing_where_constraint
method_constraint_mismatch  where_variable_unbound  duplicate_where_constraint
type_dispatch_needs_annotation  ambiguous_method_receiver  constrained_constant
```

Four existing codes are reused rather than duplicated: `not_equatable` for `eq` on a function type
(§3.4), `unbound_variable` for a dotted name that is neither a value nor an annotated type variable
(§4.1), `unexpected_token` for a `where` in a position the grammar does not allow (§2.1, §2.3), and
`nesting_too_deep` for the constraint-chain guard (§6.3).

**Severity, and `--explain`.** `diagnostic.Severity` stays `{ error, warning }`
(`src/diagnostic.zig:17`); the branch adds no third value. Nine of the ten codes are `error`.
`ambiguous_method_receiver` is a **`warning`**, and it is emitted only when `--explain` is passed:

| | |
|---|---|
| Flag | `--explain`, a new field on `Cli.Common` (`src/Cli.zig:68-79`), so `check`, `build`, `dump` and `fmt` all parse it; only `check` and `build` act on it |
| Default | off |
| Effect | informational `warning`-severity diagnostics that are otherwise suppressed are emitted |
| Exit code | **none.** `frontend.md`'s exit codes are `0` no errors, `1` at least one `error`-severity diagnostic, `2` usage or I/O (`docs/design/frontend.md:44-45`), so a warning cannot change the exit code and `--explain` cannot turn a passing build into a failing one |
| Stream | `stderr`, sorted with every other diagnostic by file, position, code |

Every message follows Elm's register as `checker.md` §8 requires: the title in SHOUTING CASE, what
the compiler was looking at, the types laid out, then a hint. The templates below show the shape,
not the final wording; `<…>` is filled in.

### 10.1 `unknown_method`

**Severity** error. **Region** the `.m` token of the method call — the `dot_lower`, not the whole
application, because that is the name that is wrong.

> **UNKNOWN METHOD** — `<Type>` has no method called `<m>`.
>
> I resolve `x.<m>` in the module that declares `x`'s type, which is `<Module>`, and `<Module>`
> has no `pub` value called `<m>`.
>
> Hint: did you mean `<nearest>`? / Hint: `<Module>` exposes: `<names>`.

```elm
-- tests/corpus/check/bad/UnknownMethod.beni
pub type Shape
    = Circle Float


pub area : Shape -> Float
area s =
    s.volume 2
```

### 10.2 `private_method`

**Severity** error. **Region** the `.m` token.

> **PRIVATE METHOD** — `<Module>.<m>` is not `pub`.
>
> `<Module>` declares `<m>`, but without `pub` it is private to that module, so `x.<m>` cannot
> reach it from here.
>
> Hint: add `pub` to `<m>` in `<Module>`.

Fixture: a two-module project under `tests/corpus/check/bad/PrivateMethod/`, a type `Token` in
`Token.beni` with a private `bump`, used as `t.bump 1` in `Main.beni`.

### 10.3 `no_methods_on_shape`

**Severity** error. **Region** the `.m` token for a dot-call; the operator token for `<` and
friends.

> **NO METHODS HERE** — a `<tuple / function / ()>` has no methods.
>
> Methods are resolved in the module that declares a type, and `<shape>` is declared nowhere.
>
> Hint (record receiver): write `(x.<m>) a` to call the field `<m>`.
> Hint (`compare` on a function): functions have no ordering. Pass an ordering function instead.

```elm
-- tests/corpus/check/bad/CompareOnFunction.beni
pub later : (Int -> Int), (Int -> Int) -> Bool
later f g =
    f < g
```

### 10.4 `missing_where_constraint`

**Severity** error. **Region** the **call in the body** that needs the method — never the
annotation. This is the direct answer to report 18 §2.4's complaint that Roc reports a caller's
missing constraint inside the callee.

> **MISSING CONSTRAINT** — I need `<v>.<m>` here, and the annotation does not allow it.
>
> This call needs `<v>` to have a method `<m>`:
>
>     <m> : <the type wanted>
>
> but `<decl>`'s annotation says `<v>` is any type at all.
>
> Hint: add it to the annotation:
>
>     where <v>.<m> : <the type wanted>

```elm
-- tests/corpus/check/bad/MissingWhereConstraint.beni
pub biggest : List a -> List a
biggest xs =
    List.sort xs
```

A second fixture, `tests/corpus/check/bad/MissingWhereCaller/`, puts the constraint on a *caller*:
`Lib.beni` declares `pub top : List a -> Maybe a where a.compare : a, a -> Order`, and `Main.beni`
calls it from an annotated function with no constraint. The assertion is that the span is in
`Main.beni`.

### 10.5 `method_constraint_mismatch`

**Severity** error. **Region** the **younger** of the two uses — the larger Bir instruction index,
which is the later occurrence in the file.

> **CONFLICTING METHOD TYPES** — `<v>.<m>` is used at two different types.
>
> Here it is used at:
>
>     <younger type>
>
> and earlier it was used at:
>
>     <older type>
>
> One variable carries one constraint per method name, so these have to agree.
>
> Hint: give the two uses different type variables, or annotate.

```elm
-- tests/corpus/check/bad/MethodConstraintMismatch.beni
pub widen x =
    ( x.render 1, x.render "two" )
```

Both uses are on one flex variable, so Rule U1 merges them and the two `render` types have to
unify; `a, Int -> b` against `a, String -> c` does not.

This is Roc's rank-2 limitation (report 18 §2.2) reproduced deliberately; §11 records that the fix
is stretch item 1.

### 10.6 `where_variable_unbound`

**Severity** error. **Region** the offending variable — the constraint's head variable for the
first trigger, the occurrence inside the constraint's type for the second.

Two triggers, both from §2.4.

**(a) The constrained variable is not a variable of the annotated type.**

> **UNKNOWN CONSTRAINED VARIABLE** — `<v>` is not a type variable of this annotation.
>
> A `where` clause constrains a variable of the type above it, and `<v>` does not appear in
>
>     <the annotated type>

```elm
-- tests/corpus/parse/bad/WhereVariableUnbound.beni
pub render : Int -> String
    where a.show : a -> String
render n =
    "x"
```

**(b) A variable inside a constraint's type is not a variable of the annotated type** — the closure
rule. The message is different, because the mistake is different and the fix is not "delete the
clause":

> **UNKNOWN CONSTRAINED VARIABLE** — `<w>` appears in a constraint but not in the type.
>
> This constraint mentions `<w>`:
>
>     <v>.<m> : <the constraint's type>
>
> but `<w>` is not a variable of
>
>     <the annotated type>
>
> A constraint may only mention variables the annotation quantifies, because those are the ones a
> caller gets to choose.
>
> Hint: give `<decl>` a parameter or a result that mentions `<w>`.

```elm
-- tests/corpus/parse/bad/WhereConstraintFreeVariable.beni
pub total : List a -> a
    where a.fold : a, (x, s -> s), s -> s
total xs =
    List.foldl xs
```

Here `x` and `s` occur only inside the constraint; the message fires once per offending variable,
at its first occurrence.

### 10.7 `duplicate_where_constraint`

**Severity** error. **Region** the second constraint's `<v>.<m>` head.

> **DUPLICATE CONSTRAINT** — `<v>.<m>` is constrained twice.
>
> One variable carries one constraint per method name.

```elm
-- tests/corpus/parse/bad/DuplicateWhereConstraint.beni
pub pick : a, a -> Bool
    where
        a.eq : a, a -> Bool
        , a.eq : a, a -> Bool
pick x y =
    x == y
```

### 10.8 `type_dispatch_needs_annotation`

**Severity** error. **Region** the `v.m` head of the application.

> **TYPE DISPATCH NEEDS AN ANNOTATION** — `<v>` is a type, not a value, and I need to be told what
> `<v>.<m>` is.
>
> `<v>` is a type variable of this declaration's annotation, so `<v>.<m>` is a dispatch on the
> type. That needs a `where` clause naming it:
>
>     where <v>.<m> : <the type this use wants>

```elm
-- tests/corpus/check/bad/TypeDispatchUnannotated.beni
pub decode : String -> Result String a
decode s =
    a.decode s
```

### 10.9 `ambiguous_method_receiver`

**Severity** **warning**, emitted only under `--explain` (see the preamble). **Region** the
declaration's name. It is the only `warning` the branch adds, and it never changes the exit code.

> **CONSTRAINT IN AN INFERRED INTERFACE** — `<decl>` is `pub`, has no annotation, and its inferred
> type carries `<n>` method constraint(s):
>
>     <the rendered scheme, where clause included>
>
> Editing the body can change this, and changing it re-checks every importer.
>
> Hint: an annotation pins it.

It is not an error and does not fail a build. It exists so that plan §7's M3 churn measurement has
something to count, and so the cost report 18 §2.3 predicts is observable rather than argued.

### 10.10 `constrained_constant`

**Severity** error. **Region** the declaration's name.

> **CONSTRAINED CONSTANT** — `<decl>` takes no arguments but needs `<v>.<m>`.
>
> A value that needs a method has to receive it, which would make `<decl>` a function of one hidden
> argument, and that is not what its type says.
>
> Hint: give it a parameter, or annotate it at a concrete type.

```elm
-- tests/corpus/check/bad/ConstrainedConstant.beni
import Dict


pub blank =
    Dict.fromList []
```

It must be **unannotated**. With `pub blank : Dict k v` the annotation declares `k` rigid with an
empty constraint set, so the body's `compare` requirement is `missing_where_constraint` (§10.4)
instead, and the fixture would assert the wrong code. `constrained_constant` is about a constraint
that survived generalisation of an *inferred* scheme (§6.4).

---

## 11. Known limits, and where the design may change

Everything here is a limit the spike **accepts on purpose**. None of it is a bug to be filed; each
is either measured (§7 of the plan) or recorded for report 19.

**Module-rule namespace clash.** Two types declared in one module cannot both have a method named
`m`, because a module's `pub` values are one namespace. Roc hit this and moved to a per-type block
in October 2025 — Jared Ramirez's summary, #ideas › static dispatch revisions, 2025-10-05,
<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/static.20dispatch.20revisions/near/543198691>;
Richard Feldman's earlier flag, #ideas › static dispatch - proposal, 2024-11-23,
<https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/static.20dispatch.20-.20proposal/near/484067349>.
**We may need to change this later.** M8 counts how often it would bite. Because every lookup is
keyed on `(TypeId, name)` (§1.2) and the interface already records which module a value lives in, a
block form is a front-end change: the block becomes the method table for that type instead of the
module's `pub` values.

In `core/` the clash is two modules. `core/Basics.beni` declares **seven** types (`Int`, `Float`,
`Char`, `String`, `Bool`, `Order`, `Never`) over 51 `pub` values, which is why §3.2's table exists
and why §5.1 moves two of them out. `core/Dict.beni` declares three (`Dict`, and the private `Tree`
and `NColor`), so `Dict`'s 22 `pub` values are nominally also `Tree`'s and `NColor`'s methods; both
are private and never receive a dot-call, so nothing breaks, but it is the clash in miniature.

**A nullary method is unreachable by dot-call.** `x.m` with no arguments is a field access (§1.1),
so a method whose only parameter is the receiver — `t.toString`, `s.length` — must be written
`M.toString t`. This is the price of keeping `language.md` §6.3 unchanged, and it is why §5 adds no
zero-argument methods to core.

**Deferred receiver.** `x.m a` with `x`'s type still unknown is a method constraint, never a field
call, so `\r -> r.f 1` where `r` turns out to be a record is `no_methods_on_shape` with a hint to
write `(r.f) 1`. This is the ambiguity report 18 §2.1 names and the one Roc's `->` operator lives
with; M6 shows the message.

**Same-name constraints unify.** One constraint per `(variable, name)` (§6.1 invariant 3), so the
rank-2 example from Roc's August-2026 thread fails with `method_constraint_mismatch` (§10.5). Roc's
multi-constraint principality fix is stretch item 1.

**`Float` ordering is not total.** `compare` on `Float` returns `EQ` for any pair involving `NaN`,
because both `<` and `>` are false; `==` on `NaN` is `False`. `Dict Float v` and `List.sort` on a
list containing `NaN` are therefore ill-behaved. This is today's behaviour for `==` and Elm's for
`compare`, and the spike does not fix it.

**No DCE yet, and derivation is eager.** Every nominal type declared anywhere in the program ships
one `eq` and one `compare` (§8.5), whether or not anything compares it, plus one structural derived
function per shape per consuming module. M4's per-type figure is therefore exact rather than
sampled — **one `eq` + one `compare` per declared nominal type** — which is precisely the number
report 18 §1.5's "grows per type × derived method" row asked for and could not supply. It is also an
upper bound on what a program with DCE would ship, and `--release` stays refused.

**`String` and `Char` ordering costs a call.** `primitive string_compare` emits `String$compare` and
`char_compare` emits a code-point comparison, not `<` (§3.2, §9.1). `<` on JavaScript strings is
UTF-16 code-unit order and `core/String.js:40-57` is Unicode scalar order; they differ for astral
characters, and a language where `"a" < "b"` and `String.compare a b` disagree is worse than one
with neither. This is correctness chosen over speed **with the speed cost known and unmeasured**:
M5 R3 (`List.sort` of 100k `String`) is where it shows up, and if it is large the honest options are
to change the order (a language change, not a spike decision) or to inline the loop at the call
site, not to quietly use `<`.

**A cross-module alias is opaque to dispatch.** §1.2 looks an alias through to its expansion, which
needs the alias's body. `checker.md` §7 records that `alias_body` is **not implemented**: expanding
a cross-module alias reads the declaring module's `Bir`, one of exactly two cross-module Bir reads
left on the checking path, and closing it alone buys M4 nothing. So on the branch a method call or a
derivation whose receiver is an alias **declared in another module** is `no_methods_on_shape`, with
a hint naming the alias and suggesting the expansion be written out. A same-module alias is looked
through normally. `tests/corpus/check/bad/MethodThroughImportedAlias/` is the fixture. This is a
gap in the spike, not in the design: the moment `alias_body` lands, the rule of §1.2 applies
unchanged.

**The `foreign` surface is wider.** §5.2 lets a `pub foreign` carry a `where` clause, which makes the
sibling export's arity depend on the checker's answer rather than on the declaration's text.
`boundary.md` §4's two automated checks are export coverage and import coverage
(`src/js/Sibling.zig:1-33`); neither checks arity, so the rule is documented and **not enforced**,
and a `core/List.js` whose `eq` forgot its leading evidence parameter would fail at runtime rather
than at build time. CLAUDE.md rule 6 says not to widen that surface for convenience; this widening
is not for convenience — the list representation is the emitter's, so `List.eq` cannot be written in
beni — but it is a widening, and the adoption decision has to weigh it. The alternatives are to add
an arity check to `Sibling.zig` (real work, and it needs a JavaScript parser to do properly, which
is the dependency the wall exists to avoid) or to refuse `where` on `foreign` and give `List` an
uncons primitive instead.

**Cross-module recursive derivation.** A type in module `A` whose payload mentions a type in module
`B` whose payload mentions `A`'s makes `A$eq` and `B$eq` mutually recursive across an ESM cycle.
Top-level `const` arrows in an import cycle can hit the temporal dead zone if one is *called*
during module evaluation; nothing in a beni module calls a derived function at evaluation time, so
it is safe today, and the spike records it rather than defending against it.

**Constrained constants** are refused (`constrained_constant`, §6.4) rather than silently turned
into functions. `Dict.empty` is unaffected — it has no constraint (§5.3).

**Interface hashing does not exist**, so plan §7's M3 measures interface *bytes changed* through
`dump --stage=raw`, which is exactly what M4's hash will be taken over.

**`equatable` and `eq` overlap** after S5. Left in place, recorded (§3.4).

### Stretch, only after S8

1. Multiple same-name constraints per variable, instantiated per use — Roc's principality fix.
2. The per-type method block, measuring how much of `core/` must opt in.
3. Record-per-variable evidence encoding behind a flag, for the inline-cache row of report 18 §1.4.

---

## Appendix A. Decisions made while writing

The plan left each of these open or under-specified. Each row is reversible by editing this
document; the alternative is recorded so the manager can take it.

**A.1 — `where` is a top-level-only clause.** A `let` annotation takes none, and a `where` after one
is `unexpected_token` rather than a code of its own. *Why:* evidence parameters are a property of a
declaration and `Bir.Decl` is where the clause lives; a `let` binding is not a `Decl`.
*Alternative:* allow it, give `let` bindings their own evidence lists, and add
`where_on_let_annotation`.

**A.2 — a constraint's type has no required shape.** It need not be a function and its first
parameter need not be the constrained variable. *Why:* return-type dispatch (§4) constrains a
method that never takes the receiver, so any shape rule would have to carve it out.
*Alternative:* require a function whose first parameter is the variable, and spell return-type
dispatch differently.

**A.3 — the ordering operators emit a test, not a `case`.** `a < b` is a `method_call` marked `lt`
whose result the backend tests (§8.3), rather than a front-end desugar to
`case a.compare b of LT -> True; _ -> False`. *Why:* the desugared form would put a shape into BIR
that the `primitive` peephole would have to pattern-match back out to emit `a < b`.
*Alternative:* the `case`, plus a peephole on it.

**A.4 — `Bool.compare` is `False < True`.** §3.2 gives `Bool` `primitive num_compare`, and JS
coerces `false` to 0. *Why:* `Bool` is a JavaScript boolean, the primitive is correct and free, and
`False < True` is what every other language means. *Alternative:* derive it by constructor
declaration order, which for `type Bool = True | False` gives `True < False` — consistent with
every other ADT and surprising to everyone.

**A.5 — `type_dispatch_needs_annotation` has two triggers** (§4.1): the declaration's `where` clause
names the variable but not the method, or the variable is an annotation variable and there is no
`where` clause at all. *Why:* the plan says the unannotated case is `unbound_variable`, which left
the code with no trigger at all. *Alternative:* `unbound_variable` everywhere and delete the code.

**A.6 — `Int`, `Float`, `Bool`, `Order` and `Never` stay in `core/Basics.beni`**, served by the
well-known table of §3.2; only `String` and `Char` move, as plan §3.5 says. *Why:* `Int` and
`Float` need the table anyway (they must emit `===` and `<` inline and they share a module), so
moving the other three buys nothing the spike measures. *Alternative:* give each its own module and
delete the table, at the cost of five more moves and five more prelude rows.

**A.7 — a `pub foreign` may carry a `where` clause** (§5.2), and its sibling export's arity is
evidence count + declared arity. **Amended 2026-09-17:** this does *not* extend a build-time check,
because `boundary.md` §4's two automated checks are export coverage and import coverage
(`src/js/Sibling.zig:1-33`) and neither looks at arity. The arity rule is **documented and not
enforced** on the branch, which widens the `foreign` surface against CLAUDE.md rule 6; §11 records
it as a finding the adoption decision must weigh. *Alternative:* forbid it and write `List.eq` in
beni over a `foreign` uncons, or add an arity check to `Sibling.zig` — which needs a JavaScript
parser to do properly, the dependency the wall exists to avoid.

**A.8 — `Dict.empty : Dict k v` stays a constant**, against the plan's `() -> Dict k v`. *Why:* it
has no constraint, so it has no evidence parameter and `constrained_constant` does not apply. The
plan's `()` was a precaution against a case that does not arise. *Alternative:* the `()`, at the
cost of every `Dict.empty` call site in the corpus.

**A.9 — `List.sortBy` is generalised** to `List a, (a -> b) -> List a where b.compare : b, b -> Order`
(§5.5), where the plan says it "stays". *Why:* `sort` is generic and `sortBy` at `number` would fail
on `List.sortBy people .name` for no reason a reader could state. *Alternative:* leave it at
`number` and let `sortWith` cover the rest.

**A.10 — `--explain` is a new flag** on `check` and `build` (§6.4, §10 preamble). The plan names the
flag without specifying it. **Amended 2026-09-17:** there is no new severity.
`diagnostic.Severity` stays `{ error, warning }` (`src/diagnostic.zig:17`) and
`ambiguous_method_receiver` is a **`warning`** emitted only under the flag; warnings do not affect
the exit code (`frontend.md:44-45`), so `--explain` can never turn a passing build into a failing
one. *Alternative:* emit it always (noisy) or never (M3 has nothing to count), or add a third
severity (a change to a schema three tools read).

**A.11 — structural derived functions are parameterised by element evidence**, keyed on the field-
name list or the arity, not specialised per concrete field-type vector (§9.2). *Why:* a concrete
key needs a total deterministic mangling of arbitrary types, which does not exist here, and the
shape key bounds the emitted-function count by shapes rather than instantiations — which is what M4
measures. *Alternative:* monomorphise, which is faster at runtime (M5 R4) and larger (M4).

**A.12 — padding slots are not compared** (§9.4), where plan §6 says "padding `null`s are compared
… so it is safe". *Why:* one padded slot can hold different types in different constructors, so a
per-position target cannot be applied to it; the tag switch makes comparing it unnecessary anyway.
*Alternative:* compare padding with `===` in addition to the switch, which is dead work.

**A.13 — `where` is a contextual word, not a keyword** (§2.2), recognised by three tokens of
lookahead. *Why:* `equatable` is already handled this way, and reserving `where` would break any
program with a variable, field or type variable of that name. *Alternative:* reserve it, which
deletes §2.2 entirely.

**A.14 — derived-function names are `<Module>$<Type>$eq` for a nominal type and
`<Module>$eq$<shape>` for a structural one** (§8.5). The plan writes `Shape$eq` and `$eq$r$x$y`;
both are those two spellings with the module prefix the `JsIr.Name` printer always adds.
*Alternative:* one uniform order, `<Module>$eq$<Type>`, at the cost of matching neither plan
spelling.

**A.15 — derived functions are emitted sorted by printed name text** (§8.5), not in request order.
*Why:* determinism a reader can check without reasoning about discharge order (CLAUDE.md rule 5).
*Alternative:* request order, which is also deterministic but only by argument.

**A.16 — tuples and `()` get the well-known methods** (§1.2, §9.3), where plan §3.1's resolution
table says "a tuple, a function, `()` → `no_methods_on_shape`" while plan §4.3's discharge table
says tuples derive. The two disagree; this spec takes §4.3's reading and extends it to `()`, so
that `( 1, 2 ) == ( 1, 2 )` and `() == ()` keep working. *Alternative:* plan §3.1's reading, which
makes tuple and unit equality a compile error the spike did not intend.

**A.17 — the dispatch table carries `derived` and `parts`** (§7.1). The plan's `Target.derived`
holds a `DerivedShape` and nothing else, which is not enough to generate a body: the backend sees no
types, so the per-position targets have to cross with it. *Alternative:* give the backend the type
store, which `backend.md` §3 forbids.

**A.18 — `eq` on an all-nullary type is `primitive strict_eq`, not a derived function** (§9.4).
*Why:* the representation is a bare tag string. *Alternative:* derive it for uniformity, and pay a
call. Note that the `<T>$eq` function is emitted anyway under A.23's eager rule; what this decision
settles is that a *use site* gets `===` rather than a call.

**A.19 — `List`'s well-known methods are `pub foreign` values of module `List`** (§5.2), found by
the ordinary module rule, rather than a row of §3.2's table as plan §3.3 implies. *Why:* `List` has
its own module, so the module rule already works, and a table row would be a special case with no
purpose. *Alternative:* a table row plus a hard-coded name.

**A.20 — a parametric type's derived function takes one evidence parameter per type parameter**,
used or not (§9.4). *Why:* it makes the canonical order a function of the type's declaration alone,
which is what §7.2 needs. *Alternative:* only the parameters that occur in a payload, which is
smaller and makes the order depend on inference.

---

The rows below were added on 2026-09-17, after a read-only review of the first draft. B-numbers and
M-numbers in brackets are that review's.

**A.21 — a `where` constraint's type may mention only variables of the annotated type** (§2.4,
§10.6 trigger (b)) [B4]. *Why:* a scheme's quantifiers are discovered by walking its **body**, so a
variable occurring only inside a constraint has no index in §7.2's canonical evidence order, and
caller and callee would disagree about the evidence list with no diagnostic anywhere.
*Alternative:* quantify constraint-only variables too, which means the evidence order depends on
constraint text as well as body text and makes every interface wider; or allow them and reject the
program later at the first call, which is the error-location failure report 18 §2.4 already
complains about.

**A.22 — the operator-as-function form dispatches** (§3.1) [M1]. `(==)`, `(/=)`, `(<)`, `(<=)`,
`(>)`, `(>=)` lower to a lambda over the corresponding `method_call`, so they carry the same
constraint the operator does. *Why:* the live fixture
`tests/corpus/parse/good/OperatorsAll.beni:30` builds a list of all six, and the only two other
readings are worse — a reference to `Basics.eq` would silently be structural equality, and refusing
the form would delete a documented part of `language.md` §6.5. *Alternative:* refuse the six
comparison operators in parenthesised form (`operator_not_a_function`), which is a language change.

**A.23 — derivation for a nominal type is eager** (§6.3.1 step 4, §8.5, §9.4) [B2]. Every declared
nominal type gets `eq` and `compare` derived in its declaring module, used or not, unless a
constructor payload contains a function type. *Why:* `Dispatch` is per module and built at the end
of that module's own check, and the declaring module is checked and lowered first, so a use site
cannot request anything from it; deriving on demand would make the declaring module's bytes depend
on which other module asked first, which varies with `--jobs` (CLAUDE.md rule 5). *Alternative:*
emit the derived function in the **consuming** module, which is impossible for a `pub opaque type`
(the consumer cannot see its constructors) and duplicates it per consumer for everything else; or
add a second checking pass over already-checked modules, which is a scheduling change M4 would
inherit. *Cost:* every type ships two functions until DCE exists — which is what makes M4's per-type
number exact (§11).

**A.24 — canonical evidence order follows `Schemes.Writer`'s recorded order, not the annotation's
source order** (§7.2) [B4]. *Why:* the writer sorts a record's fields by name text before descending
(`src/check/Schemes.zig:295`), so discovery order and source order differ for any scheme with a
record in it; both sides must compute the order from the same artifact, and the scheme record is the
only artifact both sides have. *Alternative:* record an explicit evidence order in the interface as
its own list, which is more bytes in the record M4 hashes and one more thing to keep in sync.

**A.25 — a constrained value used as a value is its eta-expansion** (§8.2) [B1]. Evidence whose
target itself takes evidence — a constrained `pub` value, a derived function for a parametric or
structural type — is emitted as `(l, r) => <name>(<its evidence…>, l, r)`, and so is a bare
reference to a constrained value. *Why:* `backend.md` §6 (`backend.md:189`) requires a
function-typed value in flight to be a closure of known arity; the bare name has the wrong arity and
a call in that position passes a result, not a function. *Alternative:* a runtime partial-application
helper, which is exactly the adapter `backend.md` §6 deleted and the one helper `boundary.md`'s wall
would have to readmit.

**A.26 — `String` and `Char` ordering is a call, not `<`** (§3.2, §9.1) [B5]. `primitive
string_compare` emits `String$compare` and `primitive char_compare` a code-point comparison.
*Why:* `core/String.js:40-57` orders by Unicode scalar value and says in its own comment that this
is what `<` on JavaScript strings is not; `"a" < "b"` and `String.compare a b` must agree.
*Alternative:* use `<` and change `String.compare` to match it — faster, and it makes an astral
character sort below U+E000, which is a language-level decision and not a spike's to take.

**A.27 — the obligation drain loop must report when it exhausts its budget** (§6.3) [m10]. Today it
falls out of the `while` and clears the list (`src/check/Solve.zig:1256-1277`). *Why:* method
obligations can register more obligations, so the bound is reachable by input and not only by a
compiler bug, and `checker.md` §5 requires a guard that poisons to report first. *Alternative:*
raise the bound and keep the silence, which is the hole §5 exists to close.

**A.28 — an open (extensible) record receiver is `no_methods_on_shape`** (§6.3) [m12]. *Why:* the
field set is not final, so neither the shape key (§9.2) nor the per-field obligations can be
computed, and a field arriving later would silently change which function ran. *Alternative:* defer
the obligation until the extension variable is closed, which is a third deferral mechanism beside
constraints and obligations.

**A.29 — `dispatch.derived` is sorted before anything indexes it** (§7.1) [m11]. `Target.derived`
and `Derived.parts` index the sorted arrays, so the dump and the emitter walk one table in one
order. *Alternative:* sort only at print time, which makes the dump and the emitted file disagree
about which function is `derived 0`.
