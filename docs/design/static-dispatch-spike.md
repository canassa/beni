# Static dispatch — specification

**Status:** normative. **Adopted whole on 2026-09-18** — option (b) of
[`research/19-static-dispatch-spike-results.md`](research/19-static-dispatch-spike-results.md) §15:
`where` constraints, dot-call, well-known `eq` and `compare` with derivation, return-type dispatch
and the C1 core rewrite are the language. It was written 2026-09-17 as slice S0 of
[`../../plans/static-dispatch-spike.md`](../../plans/static-dispatch-spike.md), when it was
normative for the branch `spike/static-dispatch` alone. **The file name is historical** and is kept
deliberately: roughly a hundred Zig comments, corpus fixture headers and bench programs cite this
file by name and by its own `§N` and `A.N` numbers, and CLAUDE.md rule 2 forbids disturbing them.

It is a **delta** on [`language.md`](language.md) and on the four phase contracts —
[`frontend.md`](frontend.md), [`checker.md`](checker.md), [`backend.md`](backend.md),
[`boundary.md`](boundary.md). It renumbers nothing anywhere (CLAUDE.md rule 2), and where it extends
a section it cites the section it extends; each of those sections now carries a short pointer back
here. **The detail lives here and only here.** Where this document and one of them disagree, this
one wins; where this document and the plan disagree, this one wins too, and every such disagreement
is listed in Appendix A.

What the adoption did to the other documents is A.82. What it left **owed** — dead-code
elimination, the unenforced `foreign` arity rule of §5.2, the two `master` printer defects, a cap on
the inferred `where` suffix and a position on the n² obligation count — is report 19 §14, carried in
CLAUDE.md as "Owed after the static-dispatch adoption". The arity rule is discharged (A.84), as are
the cap and the n² position (A.83).

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
| §8 backend | `backend.md` §4, §5, §6 | hidden leading parameters; four call shapes; **§6's "a function-typed value in flight is always a closure of known arity" (`backend.md:216`) is extended**: evidence in value position is an eta-expanded closure, §8.2 |
| §9 derived functions | `backend.md` §4 | the exact JavaScript for `eq` and `compare` per representation |
| §10 diagnostics | `language.md` §10, `checker.md` §8.1 | ten new codes, appended to the catalogue; one new flag, `--explain` |
| §5.2 `foreign` with a `where` clause | `boundary.md` §4 | the sibling export's arity becomes evidence count + declared arity, which is `boundary.md` §4's **check 4** since 2026-09-18 (A.84). It was documented and unenforced for a day, which §11 records as a widening of the `foreign` surface and report 19 §14 item 2 as an owed item; both are discharged |
| §11 known limits | — | what the spike knowingly does not solve |

[`research/20-roc-static-dispatch-implementation.md`](research/20-roc-static-dispatch-implementation.md)
walks Roc's Zig implementation of all of this and its §9 maps every mechanism to a section here;
where this document cites `references/roc/…` it is following that report's evidence. Appendix A.30
onward records the amendments it produced.

**Plan section → spec section**, so the slice table in `plans/static-dispatch-spike.md` §8 stays
usable: plan §3.1 → §1; §3.2 → §2; §3.3 → §3; §3.4 → §4; §3.5 → §5; §4.1 → §6.1; §4.2 → §6.2;
§4.3 → §6.3; §4.4 → §6.4–§6.6; §4.5 → §6.7; §4.6 → §7; §4.7 → §10; §4.8 → §6.8; §5.1–§5.2 → §1.4,
§2.5, §8.0; §5.3 → §8; §6 → §9; §9 → §11.

**Two `fast-compiler.md` §3.1 decisions are superseded by this document.** They were suspended on
the branch while the spike ran; the 2026-09-18 adoption makes the reversal permanent.
`fast-compiler.md` §3.1 records it in place — same section number, its own history kept, points 3
and 4 marked superseded with a pointer here (A.82). The two are listed here as well, so a reader of
either document knows which statements this one replaces:

| `fast-compiler.md` §3.1 | Said (*Decision*, points 3 and 4) | Now |
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
| `M.v.m a` | receiver is the qualified value `M.v`; method `m`. The head of the application is a field access on a qualified name, so this is a method call, unlike `M.f x` above | `method_call { import_value(M, v), m, [a] }` |

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
| an alias declared in **another** module | looked through as well: the interface's own `alias` term carries the expansion, so no `Interface.alias_body` is needed (A.48) | as the expansion |
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

### 1.3 `well_known`: the surface origin

A `method_call` carries a **surface origin**, not a boolean. It is an enum over the syntax the call
was written as:

```zig
pub const WellKnown = enum(u8) { none, eq, neq, lt, le, gt, ge };
```

`none` means the author wrote a dot-call; the other six name the operator of `language.md` §6.5 that
desugared into this node (§3.1). This is Roc's `Expression.SurfaceOrigin`
(`references/roc/src/canonicalize/Expression.zig:756-770`), whose own comment is the argument for
recording it as data rather than as a flag: *"Operator forms carry contracts the method-call form
does not … so re-emitting them as `.method()` calls would weaken the program."* beni's reasons are
the same two, minus Roc's third:

| Why an enum | Detail |
|---|---|
| **the typing rule differs** | `a == b` pins both operands to one type and the result to `Bool`; `a.eq b` does not (§3.1, report 20 §9 row X-4). A flag cannot express which rule applies, and the two are not interchangeable |
| **diagnostics name the operator** | every message about a well-known call says `==` or `<`, not `eq` or `compare`. Roc keeps a `getOperatorForMethod` map for this (`references/roc/src/check/report.zig:2605-2611`); the enum makes the map unnecessary |
| **(Roc only) re-emission** | Roc canonicalises operators into dispatch nodes and must print them back. **beni does not**: `fmt` is an Ast pass (`language.md` §9) and never sees BIR, so the round-trip is not at risk here. What beni needs the enum for is `dump --stage=bir`, which is a tested output and must show which operator produced a node |

Four rules hang on it:

1. A `method_call` whose origin is not `none` is **never** rewritten into a field call, so `r == s`
   on a record with a field named `eq` still means structural equality.
2. Only such a call may derive (§9) — `x.eq y` written by hand on a type with no `eq` is
   `unknown_method`, not a silent derivation.
3. The backend emits a JavaScript operator for such a call when the target is `primitive`, choosing
   which operator from the origin (§8.3).
4. The constraint it raises is the pinned one of §3.1, not the loose dot-call one.

### 1.4 BIR

```
method_call  lhs = receiver Inst.Index
             rhs = ExtraIndex of { name: SymbolIndex, origin: WellKnown, args: SubRange }

type_dispatch lhs = SymbolIndex of the type variable (§4)
              rhs = ExtraIndex of { name: SymbolIndex, args: SubRange }
```

`origin` is stored as its own `u32` word of `extra`, not packed into `name`: the dump prints it and
a packed field would make the golden depend on a bit layout.

**`dump --stage=bir`** prints the origin as the operator the author wrote, or omits it for a
dot-call, so a golden distinguishes `a == b` from `a.eq b`:

```
%4 = method_call %2 .eq [%3] (==)
%10 = method_call %8 .compare [%9] (<)
%6 = method_call %3 .insert [%4, %5]
%14 = type_dispatch a.decode [%13]
```

The method name is printed with its dot, as the source writes it and as `field_access` already
prints it, and the origin is parenthesised after the arguments. It is absent exactly when `origin`
is `none`. `tests/corpus/bir/ComparisonOperators.beni` and its `.bir` golden assert all six
spellings, including the parenthesised operator forms of §3.1 which lower to a lambda over a marked
`method_call`; `tests/corpus/bir/MethodCalls.beni` asserts every form of §1.1.

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
is `unexpected_token` — the three-token lookahead of §2.2 fails, so `where` stays a type variable and
the tokens after it cannot continue the declaration. `k.Compare` never reaches the parser as a
constraint at all: the lexer makes a `dot_lower` only out of `.` followed by a LOWER letter, so `.C`
is `invalid_character` ("I found a `.` that does not start a field access"), and the rest of the line
is reported against the tokens that survive.

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
| `where a.eq : a, a -> Bool, b.x` | `expected_token` at `.x`, expecting `->`: the lookahead matched `lower_ident dot_lower` but not `':'`, so the comma stayed a parameter separator, `Bool, b` became a parameter LIST, and a parameter list needs the arrow that never came. The diagnostic names the arrow rather than the offending token because that is what the parser was waiting for — `unexpected_token` would name `.x` without saying what was missing |

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

| Operator | Lowers to | Constraint raised | Instruction's type |
|---|---|---|---|
| `a == b` | `method_call { a, eq, [b], origin = eq }` | `eq : t, t -> Bool` | `Bool` |
| `a /= b` | `method_call { a, eq, [b], origin = neq }` | `eq : t, t -> Bool` | `Bool` |
| `a < b` | `method_call { a, compare, [b], origin = lt }` | `compare : t, t -> Order` | `Bool` |
| `a <= b` | `method_call { a, compare, [b], origin = le }` | `compare : t, t -> Order` | `Bool` |
| `a > b` | `method_call { a, compare, [b], origin = gt }` | `compare : t, t -> Order` | `Bool` |
| `a >= b` | `method_call { a, compare, [b], origin = ge }` | `compare : t, t -> Order` | `Bool` |

**The operator form pins both operands to one type**, and this is deliberately *tighter* than the
constraint a hand-written dot-call raises. Constraint generation unifies the receiver's variable
with the argument's variable and the instruction's type with `Bool` **before** the constraint is
attached, so `t` is one variable in all three positions:

| Written | Inferred |
|---|---|
| `same a b = a == b` | `a, a -> Bool where a.eq : a, a -> Bool` |
| `same a b = a.eq b` | `a, b -> c where a.eq : a, b -> c` |

Roc takes the same rule and states the reason (`references/roc/design.md:3002-3012`): *"These
contracts let inference propagate information before a method has been selected. Either comparison
operand can determine the other's type … A plain method call cannot assume these relationships."*
Report 20 §9 row X-4 is the finding that the spike's first draft omitted it.

**Why it matters to the measurement, not only to ergonomics.** The spike exists partly to measure
report 18 §2.3's claim that an unannotated `pub` function's inferred scheme carries its accumulated
constraints into the interface, so a body edit re-checks every importer. A looser scheme is a bigger
scheme: `a, b -> c where a.eq : a, b -> c` is three quantifiers and a three-parameter constraint
term where the pinned form is one quantifier and a two-parameter one. Had `==` lowered to the
dot-call constraint, **M3 would have measured churn caused by the spec's own lowering rather than by
static dispatch**, and the number would have been wrong in the direction that flatters the
objection. The four ordering operators pin the same way, with `Order` in place of `Bool` inside the
constraint and `Bool` as the instruction's type.

**The operator-as-function form** (`language.md` §6.5, "operators as functions", `language.md:532`;
the live fixture is `tests/corpus/parse/good/OperatorsAll.beni:30`, `[ (==), (/=), (<), (>), (<=), (>=) ]`)
gets the same dispatch as the operator, because it lowers to a lambda over it:

| Written | Lowers to |
|---|---|
| `(==)` | `\a b -> method_call { a, eq, [b], origin = eq }` |
| `(/=)` | `\a b -> method_call { a, eq, [b], origin = neq }` |
| `(<)` `(<=)` `(>)` `(>=)` | `\a b -> method_call { a, compare, [b], origin = lt \| le \| gt \| ge }` |
| `(+)` `(::)` and the rest | unchanged: still `\a b -> call(import_value(Basics, add), [a, b])` and friends |

So `(==)` is a closure of arity two whose *body* carries the constraint, and the constraint lands on
the enclosing declaration's scheme like any other. It is not a reference to `Basics.eq`, which would
be structural equality and the wrong answer. The pinning rule applies inside the lambda too, so
`(==) : a, a -> Bool where a.eq : a, a -> Bool`. Appendix A.22.

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

**One exception, and it expired with S6** (A.50). A `foreign type` marked `equatable` answers `eq`
through the marker, which §3.4 says means exactly "has an `eq`": `xs == ys` on a `List a` resolved
while `core/List.beni` still had no `pub foreign eq`. `compare` got no such bridge — there is no
marker for it — so `xs < ys` was `unknown_method` until §5.2 landed. §5.2 has landed, `List` answers
both names at step 1, and `tests/corpus/check/bad/CompareOnForeignType.beni`, which pinned the
`compare` half, is retired with it. What still pins the rule for a `foreign type` with no `pub
compare` is `check/bad/core/CompareOnWrappedForeign` and `check/bad/core/PrivateForeignCompare`;
`equatable` is core's alone (`language.md` §3), so after §5.2 no declarable type reaches the marker
bridge at all and the backend's side of it is gone (A.72).

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
dispatched type exists ([`research/18`](research/18-static-dispatch-revisited.md) §3). beni spells it
`a.decode bytes`.

**What Roc actually ships**, because report 18 §3 described a syntax that is not in the vendored
tree: `module(a).decode(bytes)` is gone. The shipped form binds an uppercase name to an
annotation's type variable with a **statement** — `s_type_var_alias`
(`references/roc/src/canonicalize/Statement.zig:222-240`) — and `Thing.something(arg)` then
canonicalises to `e_type_method_call`, which the checker rewrites into `e_type_dispatch_call` with
a `constraint_fn_var` (`references/roc/src/check/Check.zig:20237`). That is **closer** to
`type_dispatch { var, name, args }` than to anything report 18 described: beni's form is Roc's
design minus the binding statement, which Roc needs only because the alias is a scope entry its
formatter must round-trip, while beni resolves the variable straight out of the annotation
([`research/20`](research/20-roc-static-dispatch-implementation.md) §5.4).

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
| `v` unbound as a value, `v` **is** a type variable of the annotation but the annotation has no `where` clause at all | `type_dispatch_needs_annotation` — unless `v` is spelled `number` and `m` is `eq` or `compare`, which the A.53 bridge answers first (A.77) |
| `v` unbound as a value, `v` is not a type variable of the annotation | `unbound_variable`, as today |
| the declaration has no annotation | `unbound_variable`, as today — the feature requires the annotation, as it does in Roc |
| `v.m` with no arguments | `unbound_variable`: an application with no arguments is not an application (§1.1) |

Giving `type_dispatch_needs_annotation` the second and third rows is what makes the code
reachable; the plan left it with no trigger. See Appendix A.5.

**A dispatch can never appear inside a derived `eq` or `compare`, by construction**, so there is no
interaction between §4 and §9 to specify and no fixture that could show one. Rule 1 above requires
an application the author wrote in a declaration body, and a derived function has no body in the
source at all: §9 generates it from the type's shape, and the only methods it ever asks for are the
two the compiler owns, by NAME and never through a `where` clause on a rigid (A.56, §3.3 step 2).
The nearest thing to the case — evidence whose own answer needs evidence — is the `part` nesting of
A.46, which is a `Target` tree and not an instruction.

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

**The result type arrives by two routes and can also be deferred, and the checker treats all three
alike.** An *annotation* on the caller is the first, and the only one report 18 described. The
second is a **later use**: nothing says the flex has to be made concrete by the expression that
created it, and `let t = decodeInto "zz" in label t` is pinned by `label`, one line down, because
§6.4 rule (a) holds a constrained `let` binding at the enclosing rank instead of generalising it —
the succeeding half of the rule that `check/bad/LetConstrainedTwice` shows the failing half of.
Underneath both sits the third: a caller that is *itself* constrained on the same variable
**forwards** its evidence rather than choosing, so `decodeTwo : String, String -> ( a, a ) where
a.fromList : …` gives each inner `decodeInto` call a site targeting `evidence 0` and pushes the
choice out to ITS caller — the return-position analogue of the capture in §6.4's
`run/EvidenceCapture`. All three work across a module boundary, where the constraint travels
through `Schemes.Writer.quantifierOf` into the interface and back through `Schemes.instantiate`; a
quantifier that occurs **only in the result** is the case where callee and caller could most easily
have computed §7.2's canonical order differently, and they do not, because both derive it from the
scheme record alone. Fixtures: `run/DecodeInto`, `dispatch/DecodeInto`,
`dispatch/DecodeIntoAcrossModules`.

Report 18 §3 records the three costs Roc accepted with this feature — it requires an annotation, it
is the only place a type is named in an expression, and it is weaker than the abilities it replaced
(decode-then-transform cannot be written). The spike inherits all three unchanged.

---

## 5. Core package changes

This section **replaces** the `Dict`, `Set`, `List` and `Basics` rows of `checker.md` Appendix B;
that appendix points here. Line numbers in the `master` column below are `master` at `f466aac`. The rewrite itself is slice S6 and its
site-by-site plan is [`../../plans/static-dispatch-c1-rewrite.md`](../../plans/static-dispatch-c1-rewrite.md).

**One constraint governs every edit below, and it is new with §6.8.** The checker mints a type for
instructions that name nothing — a number is a `Basics.Int`, a list literal a `List.List`, a string
literal a `String.String`, a `'c'` a `Char.Char`, an `e?` a `Maybe` *or* a `Result` — and §6.8 turns
each of those into a graph edge into `core`. Outside `core` that can never make a project cyclic.
**Inside `core` it can**: a string literal written in `core/Basics.beni` would make `Basics` depend
on `String`, which already depends on `Basics`, and the author would get an `import_cycle` for
writing `"…"`. No core module mints a type from a module that names it back today
(`tests/corpus/check/good/TypeOwnerEdges/_expected.graph` shows `core:Basics` with no outgoing edge
at all). **S6 must keep it that way**: no literal of a kind whose owning module depends, directly or
transitively, on the module being edited. If a rewrite genuinely needs one, §6.8 needs a stated
exemption **before** the rewrite lands, not after. §11 carries the row.

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
`src/resolve/Graph.zig:277-297` makes a prelude row an edge only when the module actually resolves
a name through it, so `core/Debug.beni` — whose `log:19`, `todo:28` and `toString:37` all name
`String` — gains a graph edge to `String` instead of to `Basics`, and `core/String.beni` gains an
edge to nothing (it declares the type itself). §6.8's **minted** edges then cover the modules that
never name `String` at all: a file containing a string literal gains a `core:String` edge whether or
not it writes the word, and after the move that edge is to the module that declares the type rather
than to `Basics`. Both halves are visible in
`tests/corpus/check/good/TypeOwnerEdges/_expected.graph`.

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
in `core/List.js`. This rule is **[`boundary.md`](boundary.md) §4's check 4** and is enforced since
2026-09-18 (A.84). It was documented and unenforced on the branch and for one day after the
adoption, which was a widening of the `foreign` surface against CLAUDE.md rule 6, forced by the
list representation being the emitter's rather than beni's; §11 records the finding and report 19
§14 item 2 the owed item, and both are now discharged. The check needs no JavaScript parser: it
counts the parameter list lexically and refuses the two forms that reading cannot settle — a bare
name and a rest parameter, neither of which appears in `core/` or `platforms/node`. `boundary.md`
§4 has the accepted forms; Appendix A.7 and A.84 record the decision.

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
| 2 | **Every table written during discharge is an append-only list that rollback truncates by length.** Merging two sets appends a third and leaves both originals; nothing written during discharge is ever mutated in place, removed out of order, or keyed by anything but its own index. See below | the undo journal rolls speculation back by truncating lengths, exactly as it truncates the descriptor journal (`checker.md` §5). Roc does the same and for the same reason (`references/roc/src/types/store.zig:515`, a `shrinkRetainingCapacity`) |
| 3 | A set holds **at most one constraint per name**, and two uses of that name unify through it (§6.2 Rule U1) | the spike's simplification. It is *correct* for a `where` clause and for an operator desugaring, and *too strong* for two independent dot-calls — which is exactly report 18 §2.2's program. Roc's shipped fix is a partition by origin class, not "several per name"; it is stretch item 1 and §11 costs it |
| 4 | Constraints are stored in **insertion order** and sorted only when written to an interface or rendered | sorting on every merge would be quadratic; sorting at the two boundaries is what determinism needs (§6.5) |
| 5 | `Kind` is **not** extended | `fast-compiler.md` §3.1 closes that set, and a method constraint is not an ad-hoc kind |

**What invariant 2 covers, and why it is not only about the store.** `checker.md` §5's journal
brackets a speculative unification, and the spike gives the checker a second speculator: `?`
(`checker.md` §6.5) was the only one, and now `dischargeMethod` can run inside a probe because §6.2's
rules register obligations from *inside* `unify`. Roc hit this and its probe rollback shrinks
twenty-four checker side tables, not just the store (report 20 §9 row S3-5,
`references/roc/src/check/Check.zig:25285-25340`). So `TypeStore.Snapshot`
(`src/check/TypeStore.zig:240-244`, today `{ journal_len, vars, extra }`) gains one length per new
append-only table:

```zig
pub const Snapshot = struct {
    journal_len: u32,
    vars: u32,
    extra: u32,
    constraints: u32,        // NEW: MethodConstraint table
    constraint_sets: u32,    // NEW: the Range table
    sites: u32,              // NEW: Dispatch.sites builder      (§7.1)
    derived: u32,            // NEW: Dispatch.derived builder    (§7.1)
    parts: u32,              // NEW: Dispatch.parts builder      (§7.1)
    evidence: u32,           // NEW: Dispatch.evidence builder   (§7.1)
};
```

`rollback` truncates each to the snapshot's length; `commit` leaves them. Two details that are easy
to get wrong:

- **The truncation is per snapshot, not a single saved length.** beni's journal *nests* — it carries
  a `depth` (`src/check/TypeStore.zig:229`, `:530`, `:541`, `:565`) — whereas Roc asserts savepoints
  never nest (`references/roc/src/types/store.zig:425`). A single "length at the start of
  speculation" would be wrong for an inner probe.
- **A loop over a constraint set must be index-based and re-fetch the slice each iteration.**
  Unifying a pair can recursively grow the very list being walked, so a held `[]MethodConstraint`
  slice is a use-after-realloc. Roc writes it this way in six places and says so
  (`references/roc/src/check/unify.zig:3509-3520`); the spike's implementation is required to.

**`Descriptor` does not grow.** `Flags` goes from 8 bytes to 12 (`name: u32`, `kind: u8`,
`equatable: bool`, 2 bytes of padding, `constraints: u32`), and the largest `Content` payload is
already `Alias` at 16 bytes (`TypeId`, `Range`, `Var` — `src/check/TypeStore.zig:186-192`), so the
union's payload is unchanged and `Descriptor` stays 40 bytes. Measurement **M1a therefore measures
time, not memory**: what dispatch costs code that never uses it is the extra branch in `unify` and
the extra arm in the drain loop, not a wider store. If that is measurable, the fallback recorded in
the plan is a side table keyed by root `Var` and moved on merge, which changes nothing in this
section but `Flags`.

### 6.2 Unification, and when the method is resolved

Three sites in `unify` gain a rule; everything else in `checker.md` §6.2 is unchanged. Before them,
one rule about *ordering*, because it decides the quality of every message inside a lambda argument.

**Rule U0 — resolve the method before the arguments, when the receiver is already concrete.**

Roc does this and says why (`references/roc/src/check/Check.zig:20045-20054`):

> *"A receiver whose type is already known has its method resolved before the arguments are checked,
> so each argument is checked against the parameter type the method declares for it, as a plain
> call's arguments are. A closure argument then has its parameters seeded before its body is
> checked."*

Without it, `xs.map (\x -> x.field)` checks the lambda against a fresh variable, the lambda's
parameter type is unknown while its body is checked, and `x.field` becomes a second deferred
constraint that fails somewhere else — report 20 §9 row S3-9.

**beni can do this, and the ordering lives in constraint generation, not in the solver.**
`Constrain` builds a tree and `Solve` walks it, so at *generation* time no receiver type is known
and Roc's `varResolvesToKnownType` test has no meaning. What beni has instead is that
`Constrain.Node.Tag.and_` solves its children **left to right**
(`src/check/Constrain.zig:128-130`), which is all the ordering this needs. So:

1. `Constrain` gains one node tag, `method` — `a` = the receiver `Var`, `b` = an `extra` index of a
   `Method { name, origin, args_start, args_len, result }` — beside `call`
   (`src/check/Constrain.zig:135-136`), and one `Node.Tag` entry `method_call` for its category.
2. For a `method_call` instruction, the generator emits, **in this order** inside one `and_`: the
   receiver's own constraints, then the `method` node, then the `call_arg` constraints for the
   arguments and the constraints of the argument expressions themselves.
3. `Solve`'s arm for `method` resolves the receiver to its root and switches:
   - the root is **not** `flex` — a structure, an alias, or a rigid: run `dischargeMethod` (§6.3)
     **now**, inline, so the argument variables are already unified with the method's declared
     parameter types by the time the `call_arg` constraints are reached;
   - the root **is** `flex`: attach the constraint (§6.1) and register the obligation, exactly as
     Rule U3 does, and the arguments check against fresh variables as they do today.

A lambda argument is seeded by *unification*, not by generation, so it does not matter that its body
constraints were already built: they are solved after the `method` node, against parameter variables
that are no longer fresh. The concrete-receiver case is the common one — every `d.insert k v` on a
known `Dict`, every `==` on an annotated type — so this covers the messages that matter.

**What it does not buy.** A receiver that is still a variable at this point behaves as before;
there is no second attempt. That is the same limit Roc has (`resolve_method_first` is a test, not a
retry), and §11 records it beside the deferred-receiver row rather than pretending otherwise.

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
`.method{ constraint }` on the concrete variable per constraint in the flex's set, exactly as a
flagged-`equatable` flex does today (`checker.md` §6.2, "a flex var marked equatable that meets a
structure registers an obligation instead of walking"). The walk happens once, at discharge (§6.3).
Against `err` nothing is registered and nothing is reported.

**The obligation carries two regions, and that is the fix for report 18 §2.4.**
`Solve.Obligation` (`src/check/Solve.zig:106-116`, today `{ kind, v, region, index, result }`) gains
one field:

```zig
pub const Obligation = struct {
    kind: Kind,
    v: Var,
    region: Bir.Inst.Index,     // where the CONSTRAINT was written
    origin: Bir.Inst.Index,     // NEW: the instruction whose instantiation created THIS obligation
    index: u32 = 0,
    result: Var.Optional = .none,
};
```

`region` is the constraint's own: the `x.m` call, the operator, or the `where` clause the constraint
was declared in — and for a constraint that arrived by instantiating an imported scheme, that region
is **inside the callee**. `origin` is the instruction in *this* module that instantiated the scheme
and thereby created the obligation. Roc records the same thing —
`DeferredConstraintCheck.failure_expr`, *"the expression whose instantiation created this
obligation"* (`references/roc/src/check/unify.zig:3950-3956`) — and report 20 §7.2's finding is that
Roc's reports never read it, which is precisely why a missing `to_hash` on a caller is reported
inside the callee. §10 makes `origin` the **primary** region of the three diagnostics that can carry
one, so the spike beats Roc on the thing report 18 said was worst about it.

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
| `alias` declared in another module | the same: `TypeStore.resolved` already followed it, because the interface's `alias` term carries the expansion (A.48) |
| `Structure.record { fields, ext }` where `find(ext)` is `Structure.empty_record` — a **closed** record | well-known name (§1.3): target `derived { kind, shape = record(sorted field names) }`, and register the same obligation on **every field type**. Any other name: `no_methods_on_shape`, with the hint "write `(x.m) a` for a field call" |
| `Structure.record { fields, ext }` where `find(ext)` is `Content.flex` — an **open** record whose extension is still unsolved | `no_methods_on_shape`. See below |
| `Structure.record { fields, ext }` where `find(ext)` is `Content.rigid` — an open record from an annotation, `{ r \| a : Int }` | `no_methods_on_shape`. See below |
| `Structure.tuple(args)` | well-known name: target `derived { kind, shape = tuple(arity) }`, and register the same obligation on every element type. Any other name: `no_methods_on_shape` |
| `Structure.unit` | well-known name: target `derived { kind, shape = unit }`. Any other name: `no_methods_on_shape` |
| `func` | `eq`: **`dischargeMethod` reports `not_equatable` itself**, directly. Today that code fires off `Flags.equatable`, which is set by instantiating `Basics.eq`'s `equatable a` marker — and after §3.1 nothing instantiates `Basics.eq` for `==` any more, so the code would become unreachable if this arm did not raise it. Anything else, `compare` included: `no_methods_on_shape` |
| `err` | silence (`checker.md` §6.2) |

**Only a closed record derives**, and the two open cases are refused for the same reason by two
different routes. beni's record content is `Structure.record { fields: Range, ext: Var }` with
`Structure.empty_record` as the closed end of the extension chain
(`src/check/TypeStore.zig:180-183`, `:194-199`), so "closed" is a content test on the resolved
extension and not a flag. A **flex** extension means more fields may still arrive, so the shape key
of §9.2 is not yet determined and a field turning up later would silently change which derived
function ran. A **rigid** extension means the annotation promised to work for *every* extension, so
no shape key exists at all — deriving against the known fields would be deriving against a type the
caller never named. Appendix A.28 records the decision; this row records which `Content` and
`Structure` variants it is a test on.

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
| unannotated, `pub` | promoted into the **interface** (§6.5), which is what makes report 18 §2.3's churn question measurable | `ambiguous_method_receiver`, severity **`warning`**, **on by default** and only in the root package (§10.9) |
| unannotated, `pub` or not, whose promoted set would exceed `max_inferred_constraints` | **rejected**, and the set is dropped (below) | `too_many_inferred_constraints` (§10.11) |
| a `pub` value of **zero parameters** whose promoted scheme has at least one constraint | rejected | `constrained_constant` |

`constrained_constant` exists because a value with evidence parameters is a function (§8.1), and
silently turning a declared constant into a function would change its type across the module
boundary. The author's fix is to give it a parameter or an annotation that pins the type.

**The cap, and what the declaration becomes after it.** `Solver.max_inferred_constraints = 64`.
An **unannotated** declaration whose promoted set would hold more than that is
`too_many_inferred_constraints` (§10.11), `pub` or not — the quadratic report 19 §3 measures does
not care about `pub`, and neither does the n(n+1)/2 that produces it. An **annotated** declaration
is never capped: a `where` clause the author wrote is the whole set (Rule U2), it is bounded by the
text of the annotation, and it may carry any number.

> **Recovery.** After the report, the declaration is generalised with **no promoted constraints**:
> every quantified variable the promotion walked has its `Flags.constraints` reset to `.none`, it is
> entered in the solver's `promoted` list so §6.4's `settleUndetermined` does not then ask about the
> constraints a second time, and the declaration gets **no evidence list and no dispatch sites**.
> Its root type is untouched — the declaration keeps the shape it inferred, it simply keeps no
> requirements — so its interface entry has no `where` suffix and a caller instantiates a scheme
> with nothing to accumulate.

That last clause is the point: the cap is not only a bound on one message, it is what stops the
accumulation feeding the next link. On report 19 §3's chain — n unannotated declarations, link k
calling link k−1 on its own parameter — link 65 is reported and promotes nothing, so link 66 starts
again from one constraint. The chain therefore costs **⌊n/65⌋ errors and a constant 65·66/2
constraints per segment**: the whole run is linear in n in both time and memory, where before the
cap it was n(n+1)/2 constraints and 3.7 GB at n = 3000 (report 19 §3, §14 item 5). §10.11 has the
measurements.

**Why 64, and why no program loses.** `master`'s pre-dispatch checker already refused the same
chain past ≈64 links — `Render.writeRecord` flattens at most 64 extension links and the chain was a
row-polymorphic open record before it was a constraint set, so the 65th link is `UNKNOWN FIELD`
there, quoted verbatim at report 19 `results:152-167`. **No program that checked before the
2026-09-18 adoption is newly refused by this cap.** It is also the same 64 the record printer uses,
so the two bounds on "how wide may one inferred type get" agree. A.83.

**The outer-rank receiver, and why the spike does not build Roc's side table.**

Roc found that "constraints ride on the variable, so generalisation carries them" is not enough. A
generalised scheme there is a **pair** — the root type plus an explicit side table of promoted
requirements — because *"the callable relation can contain scheme-owned argument, result, and
literal variables even though traversing the root type alone cannot reach them"*
(`references/roc/design.md:5461-5468`; `captureSchemeDispatchRequirements`,
`references/roc/src/check/Check.zig:28361-28471`). The case is an inner declaration whose constraint
sits on an **outer-rank** receiver but whose `fn_var` mentions the inner declaration's own
quantifiers: §7.2's canonical order walks the scheme's quantifiers and never sees that constraint,
so two instantiations of the inner scheme share one method type and are wrongly unified — the same
failure `copyHelp` guards against, one scope out. Report 20 §9 row S3-4.

**The spike does not build the side table.** It removes the case instead, with two rules:

> **(a) A `let` binding is never generalised over a variable that carries a method constraint.**
> At a `let` generalisation boundary, a variable in the young pool whose `Flags.constraints` is not
> `.none` is **not** quantified: its rank is adjusted to the enclosing rank and it stays there, to be
> generalised (or promoted, or reported) at the enclosing declaration's boundary instead. So a
> constraint never straddles a boundary, and every constraint that reaches promotion sits on a
> variable the *declaration* quantifies — which is exactly what §7.2's walk requires.
>
> **(b) `generalize` checks it.** After a declaration's rank is generalised, every promoted
> constraint's `fn_var` is walked; reaching a variable quantified by a *different* scheme is an
> `std.debug.assert` failure in a debug build and an internal `nesting_too_deep`-class diagnostic at
> the declaration in a release build, never a silent miscompile. If that assert ever fires on real
> code, the answer is Roc's side table and the spike has found the thing report 20 says nobody has
> measured (§10, "Roc's own measurement of what the side table costs").

**What rule (a) costs**, stated plainly because it is a real restriction and not a free win: a `let`
binding whose type carries a method constraint is **monomorphic within its declaration**. Two uses
at different types are `method_constraint_mismatch` (§10.5), not two instantiations.

```elm
-- tests/corpus/check/bad/LetConstrainedTwice.beni
pub report : Int, String -> String
report n s =
    let
        show x =
            "${x.render}"
    in
    show n ++ show s
```

`show`'s parameter carries a `render` constraint, so `show` is not generalised over it; the first
use pins it to `Int` and the second is `method_constraint_mismatch` at `show s`. Writing `show` as a
top-level declaration with an annotation is the fix, and the message says so. §11 carries the limit
row. Appendix A.30.

**One level of evidence is therefore enough**, which settles report 20 §9 row S4-1. Roc's
`EvidenceChainIndex { depth, index }`
(`references/roc/src/check/static_dispatch_registry.zig:1336-1339`) exists because a nested
lambda is itself a callable that may need evidence re-passed into it. In beni it cannot be, for two
reasons that together close the case:

- a `let` binding never has evidence parameters, by rule (a), so the only things that do are
  top-level declarations (§8.1);
- a lambda inside a declaration lowers to a JavaScript closure, so a reference to `$m$k` in its body
  is an ordinary lexical capture and needs no re-passing at all.

`Target.evidence: u16` (§7.1) is therefore one number — the index of the *enclosing declaration's*
evidence parameter — with no depth, and no declaration ever needs another declaration's evidence.
`tests/corpus/run/EvidenceCapture.beni` is the fixture: a `pub` declaration with a `where`
constraint whose body uses the constrained method inside a lambda **inside another lambda**, passed
to `List.map` and then to `List.foldl`, so `$m$0` is read two closure levels below the parameter
list; it must print the right answer and its emitted JavaScript must contain exactly one `$m$0`
parameter.

`--explain` is a flag on `beni check` and `beni build` that emits informational diagnostics
otherwise suppressed. It adds **no new severity**: `diagnostic.Severity` stays
`{ error, warning }` (`src/diagnostic.zig:17`), `ambiguous_method_receiver` is a `warning`, and a
warning does not change the exit code (`frontend.md:50-51`), so nothing here can turn a passing
build into a failing one. **Amended 2026-09-18 (A.83): the warning is on by default and the flag
governs nothing.** `ambiguous_method_receiver` was the only diagnostic `--explain` ever controlled;
now that it is emitted without it, `--explain` is accepted, parsed and documented as redundant, and
it is kept rather than removed so no invocation that passes it starts failing with a usage error.
§10's preamble has the full contract; Appendix A.10, amended by A.83.

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

### 6.8 Parallel checking, and the edges the checker needs

`x.m` resolves in the module that **declares** `x`'s type, so a module that can see a type has to be
checked after that type's module — otherwise the lookup reads a half-built interface, which is a
data race and not merely a wrong answer. `checker.md` §4 builds the graph from explicit imports plus
*used* prelude rows, and the question this section answers is what else that misses.

**The first draft of this section was wrong twice**, and the rule below replaces it. It said a
module gains an edge to the declaring module of every `TypeId` in its own Bir and of every `TypeId`
reachable through the terms of any scheme it imports. That rule is:

- **not computable where it was placed.** `Graph.build` runs *before* `Resolve.run`, and
  `Interface.build` writes no schemes and no terms at all — `Value.scheme` is `.none` until the
  checker fills it (`src/resolve/Interface.zig`). There are no terms to walk at graph-build time.
- **a no-op even if it were.** A type a module *writes* is already an edge: a `type_import` or a
  `type_qualified` records an `import_type` ref, which `Graph.referencedModules`
  (`src/resolve/Graph.zig:333-340`) already turns into a dependency. A type that reaches a module
  through a dependency's interface is already covered by the driver's transitivity — a module starts
  only when every dependency has *finished*, and inductively those only started when theirs had.

**The real hole is the type an instruction mints without naming anything.** `1` is a `Basics.Int`,
`[ … ]` a `List.List`, `"…"` a `String.String`, `'c'` a `Char.Char`, `e?` a `Maybe` or a `Result`
— and, because §1.4 gives `method_call` no `refs` edge, `a < b` is a `Basics.Bool` written without
the word `Basics`. A module of nothing but literals had **no import, no ref and no dependency at
all**: `pub sizes = [ 1, 2 ]` in a module with no imports was scheduled beside `core/List` itself at
`--jobs=8`. Dispatch made this worse rather than creating it — before §3.1, `a < b` lowered to a call
of `Basics.lt` and *did* record a ref.

**The rule that ships.** One pass over each module's Bir instruction-tag column, in `Graph.build`
step 2 after the import edges (`src/resolve/Graph.zig:298-312`, `mintedModules` at `:386-396` and
its bit table at `:400-435`):

| Instruction tag | Module the type is minted from |
|---|---|
| `int`, `float`, `pat_int`, `method_call`, `type_dispatch` | `core:Basics` — `Int`, `Float` and `Bool` all live there, and a comparison is a `method_call` whose result is `Bool` (§3.1) with no `refs` edge of its own (§1.4) |
| `list`, `pat_list`, `pat_cons` | `core:List` |
| `string`, `chunk`, `interp`, `pat_string` | `core:String` |
| `char`, `pat_char` | `core:Char` |
| `try` | **both** `core:Maybe` and `core:Result` — which of the two a `?` is, is the checker's decision on that instruction (`checker.md` §6.5), so a file that writes one depends on both |

Four rules govern the edges this produces:

1. **Resolved with `g.lookup(.core, …)`**, against the `core` package and never against the module's
   own. That is where `check/Types.findWellKnown` resolves these types, and the two must not
   disagree: an app module named `List` shadows the *name* for its dependents (`checker.md` §4.3)
   and does not move the type a list literal has out from under the checker, so it must not take the
   edge either.
2. **Self-edges are skipped**, so `core/List` does not depend on `core/List` for its own list
   literals — the same rule the header already applies to a module's references to itself.
3. **Duplicates are skipped**, against the edges already appended for this module.
4. **Appended in fixed order after the import edges**, iterating the table
   `{ Basics, List, String, Char, Maybe, Result }`, so the edge list is a function of the source and
   not of a traversal (CLAUDE.md rule 5).

Everything else in `checker.md` §4 is untouched: the order is still the stable topological one, ties
still broken by `(package, path)`, a project with a cycle still runs serially, and ids are still
assigned before any thread starts.

**The invariant the three edge sources buy together**, by induction over the order:

> Every nominal type visible while a module is checked is declared by the module itself or by a
> transitive dependency of it.

**Cost, measured.** On `zig build bench -- --generate=100000` (635 modules, 202k instructions):
**3837 edges before, 3938 after — +2.6 %** — and `resolve` **4.93 ms before, 4.85 ms after**,
best-of-twelve interleaved ABBA against a build of the parent commit. The scan does not show. The
first draft of this paragraph claimed the DAG narrows because "any module using `Dict String Int`
now depends on `Dict`, `String` and `Basics`"; that was always an edge — writing `Dict String Int`
is an `import_type` ref — and the claim was over-stated. M1 still reports the number, but it is not
one of the costs the spike was commissioned to weigh.

**Inside `core` this rule bites, and S6 must keep it from biting.** A minted edge always points into
`core`, so a user project can never be made cyclic by one. Inside `core` it can: a string literal in
`core/Basics.beni` would make `Basics` depend on `String`, which already depends on `Basics`, and
the author would get an `import_cycle` for writing `"…"`. No core module mints a type from a module
that names it back today — `core:Basics` has no outgoing edge at all in
`tests/corpus/check/good/TypeOwnerEdges/_expected.graph`. §5's rewrite has to keep it that way, or
§6.8 needs a stated exemption **first**. §11 carries the constraint.

**Observable surface.** `dump --stage=graph` (`src/dump/graph.zig`) prints the graph's edges, one
per line as `package:Module -> package:Module`, sorted by the printed line. A module's identity is
`(package, name)` and not the name alone, because the user's package and `core` may each have a
`List`. The edges are dumped rather than the order: `order` is a topological sort of exactly these
edges, so a golden over the edges pins the schedule *and says why*, while a golden over the order
alone would move for either of two unrelated reasons — and what this section needs asserted is that
the module declaring a type is an ancestor of every module that can see it, which is a statement
about edges. There are no positions, symbol ids or file indices in the output, so it is a function
of the sources alone.

- `tests/corpus/check/good/TypeOwnerEdges/` is the fixture: `Literals.beni` (literals only, no
  imports), `Owner.beni` (declares a type), `Middle.beni` (imports `Owner`), `User.beni` (imports
  `Middle` and never names `Owner`), with `_expected.graph` beside `_expected.iface`.
- A `--jobs=1` / `--jobs=8` byte-comparison scenario over `--stage=graph` joins the determinism test.

---

## 7. The dispatch table

The backend sees no types (`backend.md` §3; `Lower.Input` carries interfaces and a graph, never a
store). Everything the checker decided about a method call therefore has to cross as data. The
dispatch table is that data: one per module, flat, index-based, immutable once built, in the shape
of `Bir.refs`.

**It carries one decision that is not about a method call**, added when M3b emitted `?`: which of
`language.md` §6.6's two shapes each `?` turned out to be. `checker.md` §6.5 settles it by
speculation, the emitted failure test is the `Nothing` tag for one shape and the `Err` tag for the
other, and there is no pattern at a `?` to read either off — so it is exactly the kind of decision
this table exists for, and giving it a second channel would have meant a second thing to keep
sorted, roll back and dump.

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
        top: struct { decl: Bir.DeclIndex, parts: Range },        // a value of this module, and the
                                                                  // evidence a PART position hands it
        ext: struct { module: Graph.Index, value: Interface.ValueIndex,
                      parts: Range },                             // likewise (A.64)
        evidence: u16,                                            // the k-th evidence parameter of the
                                                                  // ENCLOSING DECLARATION. One level, no
                                                                  // depth — §6.4 proves why
        primitive: enum(u8) { strict_eq, num_compare, char_compare, string_compare },
        derived: struct { index: u32, parts: Range },             // a function THIS module emits, and the
                                                                  // evidence this USE passes it (A.46)
        ext_derived: struct { module: Graph.Index, type: Types.TypeId,
                              kind: Derived.Kind, parts: Range }, // another module's nominal type (A.47)
        field,                                                    // a record: a plain field call
        err,
    };

    pub const Site = struct {
        inst: Bir.Inst.Index, evidence_index: u16,
        parent: u16,                   // the slot of the SAME instruction this one hangs
                                       // under, or `no_parent`. The ORDER of the list is the
                                       // tree; the index is only the identity (§7.2, A.68)
        target: Target,
    };
    pub const Evidence = struct { quantified: u16, var_name: SymbolIndex, method: SymbolIndex };
    pub const Try = struct {                                      // one per `?` (ADDED with M3b's
        inst: Bir.Inst.Index,                                     // `?` codegen: `backend.md` §4,
        shape: enum(u8) { maybe, result },                        // `checker.md` §6.5)
    };
    pub const Derived = struct {
        kind: enum(u8) { eq, compare },
        shape: Shape,
        evidence_count: u16,   // one per field, element or type parameter, in shape order
        parts: Range,          // NOMINAL only: the body's per-constructor-argument targets.
                               // Empty for a record, a tuple or `()` — such a body is
                               // `$m$0 … $m$n-1` applied position by position (§9.2, §9.3)
    };

    sites: []Site,                     // grouped by `inst`, and within one instruction in the
                                       // PRE-ORDER of §7.2's evidence tree
    tries: []Try,                      // ascending by `inst`, one row per `?`
    decl_evidence: []Range,            // per declaration, into `evidence`
    evidence: []Evidence,              // canonical order within each declaration
    derived: []Derived,                // SORTED by emitted name text (§8.5). Exactly what this
                                       // module EMITS: another module's nominal method is an
                                       // `ext_derived` target and has no row (A.47)
    parts: []Target,                   // the evidence arguments of every `derived`/`ext_derived`
                                       // target, and the body positions of every nominal
                                       // `Derived`. Ranges into it NEST
    symbols: []Symbol,                 // the field names a `Shape.record` ranges over
};

**A structural derived function is keyed on its shape and on nothing else, and is parameterised by
element evidence** (A.11, A.46). `{ x : Int, y : Int }` and `{ x : String, y : String }` are one
`r$x$y`; what tells them apart is the two arguments each use hands it, which is why `parts` hangs off
the **`Target`** and not off the `Derived`. Baking the first requester's element targets into the
function is a miscompile and not a detail: the second use of a `t2` would then order `String`s with
JavaScript `<`, which is the UTF-16 order A.26 refuses, and a record whose second field is a tuple
would compare that tuple with `===`.
```

**A `top` or an `ext` carries a `parts` range too, and it is EMPTY at a call site** (A.64). At a
call site the evidence of a constrained value rides on the sites that follow it, because §7.2
numbers every evidence slot of one instruction into one flat list and §8.2's eta-expansion reads
them back. Inside a `parts` tree there is no instruction to number a site against, so the tree has
to carry it: `{ p : { x : Int }, q : List Int } == …` writes `part 1 ext List eq`, and `List.eq`
takes one hidden argument. The two are never both used — `partsOf()` is consulted first, and a
target that has parts consumes no site — and the checker fills the range from the same rule
`derived` uses: one target per constraint the named value's scheme puts on a type parameter, in the
canonical order of §7.2. A scheme whose quantifier count does not match the type's arity gets no
parts, and the backend refuses the call rather than pass evidence for the wrong parameter.

`derived` is sorted **before** anything indexes it: `Target.derived: u32` and `Derived.parts` are
indices into the *sorted* arrays, so the table a dump prints and the table the emitter walks are the
same table in the same order, and `--jobs` cannot move a byte of either. A builder that appends
while discharging must therefore sort and remap once, at the end of `ModuleCheck.run`, together
with the ordering of `sites`.

**`sites` is ordered by the TREE, not by the index.** The list is sorted by `(inst,
evidence_index)` first — `Lower.siteRangeOf` binary-searches one instruction's run, so the
instructions have to stay contiguous — and each instruction's run is then put into the pre-order of
§7.2's evidence tree, which is the order §8.2 reads it in. The two disagree: the cursor that numbers
slots runs in ALLOCATION order, and allocation is breadth-first, because one instantiation numbers
every slot of its own `where` clause before any of them is discharged. `Site.parent` is what closes
the gap, and the ordering is a forward pass over it — a slot's parent, numbered before it was, is
always earlier in the run, so each slot's path from its root is its parent's path with its own index
appended, and sorting a run by that path lexicographically *is* the pre-order. Appendix A.68.

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

**One instruction numbers its slots once, and an index is never reused.** Resolving a slot can
instantiate the scheme that ANSWERS it — `[ [ [ Box "a" "b" ] ] ] == …` resolves `List.eq`, whose
`where a.eq` resolves `List.eq` again, four levels of one `==` — and every level is a slot of the
same instruction. So the numbering is a running cursor per instruction (`Solve.evidence_next`), and
a nested instantiation continues it rather than starting again at 1. The pair
`(inst, evidence_index)` is a key, and two of the checker's own tables treat it as one:
`joinConstraint`, when two constraints of a name meet on a variable, and `appendSite`, which
forwards a mutually recursive group's shared constraint. Both drop a row they have already seen, so
a repeated index is a dropped argument. Appendix A.68.

**The flat list is a PRE-ORDER walk of that tree, and the numbering is not.** §8.2 reads the list
with a cursor — a slot answered by a function that takes evidence of its own consumes the slots that
follow it — so the list has to be the tree written down depth-first. The cursor above numbers in
allocation order, which is breadth-first: an instantiation numbers `a`'s slot and `b`'s slot
together, and only then is `a` discharged and `a`'s child numbered, *after* `b`. With one chain of
nesting the two orders coincide and nothing shows; with two slots that each nest they do not, and
`pair [ [ 1 ] ] [ [ 2 ] ]` under `pair : a, b -> Bool where a.eq : …, b.eq : …` read `a`'s child as
`a`'s grandchild and gave `b` whatever was left. So every site records its PARENT slot — the slot of
the same instruction whose own resolution asked for it, or `no_parent` — and `Dispatch.finish`
orders each instruction's run by it (§7.1). The order is the tree; `evidence_index` is only the
identity the two deduplicating tables key on. Appendix A.68.

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

**The closure rule of §2.4 is what makes this rule total, and it is why there is no second phase.**
Roc's enumerator walks the resolved root type and then **drains a queue over the constraints' own
function types**, because a `fn_var` can bind further constrained variables the root walk never
reaches — `where [a.iter : a -> i, i.next : …]`, with `i` introduced by the constraint
(`references/roc/src/check/dispatch_evidence.zig:211-241`; report 20 §0 and §3.5). beni's §2.4
forbids exactly that shape: every type variable mentioned anywhere in a constraint's type must occur
in the annotated type, so `i` would have to be a parameter or result of the declaration and would
therefore be a quantifier the root walk already visits. One phase suffices **because** A.21 refused
the programs that need two. If A.21 is ever relaxed, this rule needs Roc's queue.

`Dispatch.Evidence` records the `(quantified, method)` pair each slot came from so the dump can
name it and so a mismatch is a caught bug rather than a silent miscompile.

### 7.3 `dump --stage=dispatch`

`Cli.Stage` gains `dispatch`, and §6.8 adds `graph`, so the CLI reads
`tokens, ast, bir, interface, raw, types, graph, dispatch` (`src/Cli.zig:66`). Like
`--stage=interface` it accepts a directory as well as a file. The format is line-oriented, one fact per line, with **no symbol ids,
no positions and no module indices** — every name is text, so reformatting the input leaves a
golden untouched and `--jobs` cannot move a byte (the rule `dump/types.zig` already states).

```
module <ModuleName>
  decl <name> evidence=<n>
    evidence <k> quantified=<q> var=<varName> method=<methodName>
  try <inst> <maybe|result>
  derived <i> <eq|compare> <shape> evidence=<n>
    part <j> <target>
  site <inst> <evidence_index> <target>
    part <j> <target>
```

- `decl` lines are in **source order** and there is one per value declaration; a declaration with no
  evidence prints `evidence=0` and no `evidence` lines. A module with no dispatch at all prints its
  `module` line and nothing else.
- `try` lines are one per `?`, ascending by Bir instruction index, and say which of
  `language.md` §6.6's two shapes the speculation of `checker.md` §6.5 committed to. A module with
  no `?` prints none, and a module whose ONLY dispatch is a `?` still prints them — the shape is
  what the emitter's failure test is built from, so it is printed for the same reason a site is.
- `derived` lines are in the emission order of §8.5 (by emitted name text). Their `part` lines are
  the **body's** positions — every constructor argument of a nominal type, in declaration order
  (§9's parts contract). A record, a tuple and `()` have none: `evidence=<n>` is the whole of it.
- `site` lines are grouped by `inst`, printed as the decimal Bir instruction index, and within one
  instruction they are in the **pre-order** of §7.2's evidence tree — the order §8.2 reads them in,
  a target taking the slots that follow it. The indices of one instruction are **distinct** and
  cover its whole nest, so `[ [ [ 1 ] ] ] == …` prints `0 1 2 3` and not `0 1 1 1`
  (`tests/corpus/dispatch/NestedEvidenceIndices`), but they are not in ASCENDING order when two
  slots each nest: the numbering is breadth-first and the rows are depth-first, so
  `pair [ [ 1 ] ] [ [ 2 ] ]` prints `0 2 4 1 3 5`
  (`tests/corpus/dispatch/TwoSlotsNested`). Read down the rows, not across the column. Their `part` lines are the **evidence this use passes**, one per evidence
  parameter in shape order, and they NEST: a position that is itself a derived function has its own
  underneath it, indented two more spaces (A.46). A `top` or `ext` position prints its `part` lines
  the same way when it is a constrained value inside a parts tree (A.64); at a call site it has
  none, and the evidence is the `site` lines that follow instead.
- Like `--stage=interface`, the stage accepts a **directory** as well as a file, and then prints
  every module under it in path order.

Target spellings, exhaustive:

| `Target` | Printed |
|---|---|
| `top` | `top <declName>` |
| `ext` | `ext <ModuleName> <valueName>` |
| `evidence` | `evidence <k>` |
| `primitive` | `primitive strict_eq` \| `primitive num_compare` \| `primitive char_compare` \| `primitive string_compare` |
| `derived` | `derived <i>` |
| `ext_derived` | `ext_derived <ModuleName>.<TypeName> <eq\|compare>` |
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

A site whose target takes evidence prints it underneath, one `part` line per evidence parameter.
`xs == ys` at `List (List Int)` is one `ext_derived` naming `List`'s `eq`, whose single argument is
itself `List`'s `eq` at `Int`:

```
  site 9 0 ext_derived List.List eq
    part 0 ext_derived List.List eq
      part 0 primitive strict_eq
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
  decl wider evidence=0
  decl bigger evidence=0
  derived 0 compare Shapes.Shape evidence=0
    part 0 primitive num_compare
  derived 1 eq Shapes.Shape evidence=0
    part 0 primitive strict_eq
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

**Only a top-level declaration has evidence parameters**, and a lambda never does. §6.4 rule (a)
keeps a `let` binding from being generalised over a constrained variable, so no nested binding
acquires its own evidence list, and a lambda in a declaration's body lowers to a JavaScript closure
that reads `$m$k` by ordinary lexical capture:

```js
// pub tally : List a -> List ( a, Int ) where a.eq : a, a -> Bool
export const Tally$tally = ($m$0, xs) =>
  List$map(xs, (x) => ({ a: x, b: List$foldl(xs, 0, (y, n) => ($m$0(x, y) ? n + 1 : n)) }));
//                                                              ^^^^^ two closures down, captured
```

That is why `Target.evidence` is a single `u16` and not Roc's `EvidenceChainIndex { depth, index }`
(`references/roc/src/check/static_dispatch_registry.zig:1336-1339`, resolved by walking out
through enclosing callables at `monotype/lower.zig:992-1001`): Roc's nested callables are separate
functions that must have evidence re-passed into them, and beni's are closures that already see it.
Report 20 §9 row S4-1 asks for this to be stated rather than assumed, and
`tests/corpus/run/EvidenceCapture.beni` (§6.4) is the fixture that holds it.

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
until its evidence is bound; `backend.md` §6 (`backend.md:216`) requires every function-typed value
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

A `primitive` target combines with the surface origin of §1.3 to give the operator directly.
This is the only place the marking reaches the backend, and it is why the marking exists:

| origin | `strict_eq` | `num_compare` | `char_compare` | `string_compare` |
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

**Which makes most of `Lower.typeDispatchExpr`'s arms unreachable, and they stay.** The
constraint's root is a rigid (§6.7), so the only three answers §6.3 can give a `type_dispatch` are
`evidence k`, a `primitive` where the A.53 bridge answered a well-known method on a `number` or
flagged-`equatable` rigid (A.77), and §10.8's error, which the site carries as `err`. `top`, `ext`,
`derived`, `ext_derived` and `field` cannot arrive at this instruction from any beni program — only
from a table that disagrees with the solver — and each is kept for a different reason: `top` and
`ext` cost nothing, sharing the ordinary call path with `evidence` and `primitive`; `derived` and
`ext_derived` have a real lowering, §8.3's minus the receiver, because the shape of that call is
decided here and not at the point it would first be needed; `field` is an explicit wall, because
there is no receiver for a field to be read from. Fixture: `dispatch/TypeDispatch`, which is the
only place a receiver-less site is visible at all — `run/` and `emit/` see the emitted call, not
the target that produced it.

### 8.5 Naming and emission order

A derived function is an ordinary module-level `const`, exported, referenced through the same
`externalName` / `need` / `importStatements` path as any other value. Its `JsIr.Name` has the
emitting module as `module` and an interned base, so the printer spells it `Module$base` as usual.

| What | Emitted in | When | Base | Printed |
|---|---|---|---|---|
| well-known method of a nominal type `T` in module `M` | `M`, always — even when the only use is elsewhere, and even when `T` is `pub opaque`, which is what makes derivation legal for an opaque type | **eagerly**: one `eq` and one `compare` per declared nominal type, used or not, unless a payload contains a function type (§6.3.1 step 4) | `<T>$$eq`, `<T>$$compare` | `Shapes$Shape$$eq` |
| the tag-order table of a type with two or more constructors | `M` | with its `compare` | `<T>$$order` | `Shapes$Colour$$order` |
| a record shape | the **consuming** module, deduplicated per file | on demand: a shape is not declared anywhere, so there is no module to derive it in ahead of time | `eq$r$<f1>$<f2>$…` | `Main$eq$r$x$y` |
| a tuple shape | the consuming module | on demand | `eq$t<n>` | `Main$compare$t2` |
| `unit` | the consuming module | on demand | `eq$unit` | `Main$eq$unit` |
| a primitive, as a **value** (§9.1) | the consuming module | on demand | `eq$prim`, `compare$prim`, `compare$char` | `Main$compare$prim` |

**Why the nominal base takes a DOUBLE separator.** A printed name is the module path with its dots
turned into `$`, then `$`, then the base, so a nominal base of `<T>$eq` puts the synthesised
namespace and the module namespace in one flat space — and they collide. Module `Shapes` with a
`pub type Box` spells its derived method `Shapes$Box$eq`; the submodule `Shapes.Box` with a
`pub eq` of its own spells that value `Shapes$Box$eq` too, and a module importing both emits two
`import`s of one name: `SyntaxError: Identifier 'Shapes$Box$eq' has already been declared`, after a
build that exited 0. `<T>$$eq` has an empty segment between its two `$`, which no module path has
— a path has no empty segment — and which no beni identifier can contain, so the two namespaces
can no longer meet. The structural bases need no such guard: `eq$r$…`, `eq$t<n>`, `eq$unit`,
`eq$prim`, `compare$prim` and `compare$char` all begin lower-case, and a module path segment is
upper-case. Appendix A.61.

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
reference is fine — and the `<T>$$order` table is the one exception: it is a plain object literal,
so it must precede the `compare` that indexes it. Sorting by name gives `Shapes$Colour$$compare`
before `Shapes$Colour$$order`, which is the wrong way round, so the pass emits **every `$$order`
table first**, sorted by name, then every function, sorted by name. Two sorted runs, both
byte-stable.

**This table is what governs the spelling.** The listings elsewhere in this document — §8.3's
`Shapes$Shape$eq(a, b)`, §9.4's and §9.6's worked examples — were written before A.61 and still
show the single separator and the operand names `x` and `y` where the emitter writes `$x` and `$y`.
They are illustrations of SHAPE and are left as they were written; where one disagrees with the row
above, the row above is the contract.

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

**The evidence is a property of the USE and not of the function** (A.46). `Main$eq$r$x$y` above is
one function whatever the two fields hold, and the two arguments it is handed come from the
`Target.derived`'s own `parts` range (§7.1). This is the half the table has to get right: a
`Derived` row carries `evidence_count` and, for a nominal shape, the body's positions — never a
use's arguments.

### 9.3 Tuples and unit

Shape key is the arity; positions are the slot names `a`, `b`, `c`, … of `backend.md` §4.

Tuples are keyed on their arity alone, so `( Int, Int )` and `( String, String )` share
`Main$compare$t2` and differ only in the evidence they are given (A.46).

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
is what derives; a `Point` imported from elsewhere would be `no_methods_on_shape`
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

An **eleventh** was appended on 2026-09-18 with the cap of §6.4, in the same way — at the end of
this section as §10.11, and at the end of both catalogues, so nothing above it moves (A.83):

```
too_many_inferred_constraints
```

Four existing codes are reused rather than duplicated: `not_equatable` for `eq` on a function type
(§3.4), `unbound_variable` for a dotted name that is neither a value nor an annotated type variable
(§4.1), `unexpected_token` for a `where` in a position the grammar does not allow (§2.1, §2.3), and
`nesting_too_deep` for the constraint-chain guard (§6.3).

**Severity, and `--explain`.** `diagnostic.Severity` stays `{ error, warning }`
(`src/diagnostic.zig:17`); this document adds no third value. Ten of the eleven codes are `error`.
`ambiguous_method_receiver` is a **`warning`**, and **since 2026-09-18 it is emitted by default**
(A.83) — by `check` and `build`, the two subcommands that act on informational diagnostics;
`dump` and `fmt` leave a dump's stderr for problems with the input rather than advice about it
(`Session.Options.informational`). The row below records what `--explain` was and what it is now:

| | |
|---|---|
| Flag | `--explain`, a field on `Cli.Common` (`src/Cli.zig:68-79`), so `check`, `build`, `dump` and `fmt` all parse it |
| Default | off |
| Effect | **none, since 2026-09-18.** `ambiguous_method_receiver` was the only diagnostic it ever gated and that gate is gone, so the flag is accepted and does nothing. It is kept, not removed, so no script that passes it starts exiting `2` |
| Exit code | **none.** `frontend.md`'s exit codes are `0` no errors, `1` at least one `error`-severity diagnostic, `2` usage or I/O (`docs/design/frontend.md:50-51`), so a warning cannot change the exit code |
| Stream | `stderr`, sorted with every other diagnostic by file, position, code |

**Warnings are for code the author owns.** A diagnostic that an author cannot act on is noise, and
`core/` is compiled into the binary while a platform package is somebody else's dependency
(`boundary.md` §2) — nobody can annotate `Dict.foldl` from their own project. So
`ambiguous_method_receiver` is raised **only for a module of the root package**
(`SourceStore.Package.app`, `src/SourceStore.zig:65`; the checker reads it through
`Graph.module(m).package`). Errors are not restricted this way: an `error` in a dependency stops the
build whoever wrote it, and `too_many_inferred_constraints` (§10.11) is an error in every package.
A.83.

**Two regions, and which is primary.** Three of the ten codes are raised while discharging an
obligation, and an obligation carries two instructions (§6.2): `origin`, the instruction in *this*
module whose instantiation created the obligation, and `region`, where the constraint itself was
written — which for a constraint that arrived on an imported scheme is **inside the callee**. The
rule, for `unknown_method` (§10.1), `missing_where_constraint` (§10.4) and
`method_constraint_mismatch` (§10.5):

> The **primary** span — the one the message points at, the one the exit code is attributed to, the
> one a `.diag` golden lists first — is `origin`: the call the author wrote. The **secondary** span
> is `region`: the annotation, `where` clause or earlier use the requirement came from, rendered as
> a follow-on note. When the two are the same instruction, only one span is printed.

This is the whole of report 18 §2.4's complaint and report 20 §7.2's confirmation of it. Roc records
the same instruction — `DeferredConstraintCheck.failure_expr`
(`references/roc/src/check/unify.zig:3950-3956`) — and its reports never read it, highlighting
`constraint.fn_var`'s region instead (`references/roc/src/check/report.zig:2494-2500`), which for a
`where`-clause constraint is the *callee's* annotation node
(`references/roc/src/check/Check.zig:15100-15110`) and survives being copied to a caller
(`:6845-6858`). The spike's cheapest win over Roc is to print both and put the caller first.

Every message follows Elm's register as `checker.md` §8 requires: the title in SHOUTING CASE, what
the compiler was looking at, the types laid out, then a hint. The templates below show the shape,
not the final wording; `<…>` is filled in.

### 10.1 `unknown_method`

**Severity** error. **Primary** the obligation's `origin` — the call whose instantiation made the
receiver concrete. **Secondary** the constraint's `region`, the `.m` token that asked for the
method; omitted when it is the same instruction.

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

Here the two coincide — the `.volume` call is both the constraint and what made `s` concrete — so
the `.diag` golden has **one** span, at `.volume` on line 7. The two-span form is exercised by
`tests/corpus/check/bad/UnknownMethodThroughGeneric/`: `Lib.beni` has
`pub render : a -> String where a.draw : a -> String`, `Main.beni` calls `Lib.render shape` on a
`Shape` with no `draw`. Primary is `Lib.render shape` in `Main.beni`; secondary is the `where`
clause in `Lib.beni`, as *"`draw` was required by `Lib.render`'s annotation"*.

**The undetermined-receiver arm.** Same code, and the receiver rather than the name is what could
not be found. `Solve.settleUndetermined` answers a well-known method on a type nothing ever
determines with the A.53 bridge (A.66); a name that is not well known has no such answer, and the
slot it leaves empty is an emitted call one argument short. **Region** the instruction of the
constraint's first site — the call the author wrote.

> **UNKNOWN METHOD** — I cannot tell which type `<m>` is being asked of here.
>
> A method is resolved in the module that declares its receiver's type, and nothing in this program
> ever says what that type is:
>
>     `number` — a literal I never had to choose between `Int` and `Float` for
>
> `eq` and `compare` I could still answer, because they mean the same thing at every type. `<m>` I
> cannot — it is declared for some type, and there is no type here to look it up in.
>
> Hint: annotate the value at the type you mean.

Fixture: `tests/corpus/check/bad/WhereNonWellKnownAtLiteral.beni`.

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

**Severity** error. **Primary** the obligation's `origin` — the call in the body, or in the
*caller*, that needs the method. **Secondary** the annotation or `where` clause the requirement came
from. Never the other way round: this is the direct answer to report 18 §2.4's complaint that Roc
reports a caller's missing constraint inside the callee, and report 20 §7.2 confirms Roc still does.

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

The two spans here are `List.sort xs` on line 4 (primary) and `List.sort`'s own `where` clause in
`core/List.beni` (secondary), rendered as *"`compare` is required by `List.sort`"* — so the golden
shows a span in a **different file** below the one in this one.

A second fixture, `tests/corpus/check/bad/MissingWhereCaller/`, puts the constraint on a *caller*:
`Lib.beni` declares `pub top : List a -> Maybe a where a.compare : a, a -> Order`, and `Main.beni`
calls it from an annotated function with no constraint. The assertion is that the **primary** span
is in `Main.beni`, at the call, and the secondary is in `Lib.beni`. Reversing them is the Roc bug,
so the fixture asserts the order and not merely the set.

### 10.5 `method_constraint_mismatch`

**Severity** error. **Primary** the **younger** of the two uses — the larger Bir instruction index,
which is the later occurrence in the file. **Secondary** the older use, or, when the older
"use" is a `where` clause rather than an expression, that clause. Both come from the two
constraints' own `region`s; when one of them arrived by instantiation the obligation's `origin` is
used for it instead, by the preamble's rule.

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
unify; `a, Int -> b` against `a, String -> c` does not. The golden has two spans on line 2: primary
at `x.render "two"`, secondary at `x.render 1` with *"here it was used at `a, Int -> b`"*.

This is Roc's rank-2 limitation (report 18 §2.2) reproduced deliberately; §11 records that the fix
is stretch item 1, and report 20 §2.3 is what that item actually costs.

**§6.4 rule (a)'s boundary does NOT reach this code, and `LetConstrainedTwice` asserts what it does
reach** (A.49). A `let` binding is not generalised over a constrained variable, so the first use
pins the type and the second arrives as an ordinary `type_mismatch` at the argument — by which
point the constraint has been discharged against the first use's type and nothing in the store says
why the binding was monomorphic. That message therefore carries a hint of its own, which names the
binding, names the method, and says to lift it to a top-level declaration with a `where` clause. The
ordinary numeric hints would have told the author to check their arithmetic.

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
> This constraint mentions `<w>`, but `<w>` is not a variable of
>
>     <the annotated type>
>
> A constraint may only mention variables the annotation quantifies, because those are the ones a
> caller gets to choose.
>
> Hint: give the declaration a parameter or a result that mentions `<w>`.

The constraint is identified by the SPAN, which points at `<w>`'s occurrence inside it, rather than
by quoting `<v>.<m> : <the constraint's type>` above the annotated type: a lowering diagnostic
carries one secondary byte range (`src/bir/Diagnostics.zig`, `Item.other_start/other_end`), and the
annotated type is the more useful of the two — it is what the reader must change. The hint says "the
declaration" for the same reason: naming it would need a third range.

```elm
-- tests/corpus/parse/bad/WhereConstraintFreeVariable.beni
pub total : List a -> a
    where a.fold : a, (x, s -> s), s -> s
total xs =
    List.foldl xs
```

Here `x` and `s` occur only inside the constraint; the message fires once per offending variable, at
its first occurrence. A variable that trigger (a) has already reported is **not** reported again by
(b) — in `where a.show : a -> String` under `render : Int -> String` the head `a` and the `a` inside
the type are one mistake, and one mistake gets one message.

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

**Severity** **warning**, emitted **by default** by `check` and `build`, and only for a module of
the **root package** (see the preamble; before 2026-09-18 it needed `--explain` and ignored the
package — A.83). **Region** the declaration's name. It is the only `warning` this document adds, and
it never changes the exit code.

> **CONSTRAINT IN AN INFERRED INTERFACE** — `<decl>` is `pub`, has no annotation, and its inferred
> type carries `<n>` method constraint(s):
>
>     <the rendered scheme, where clause included>
>
> Editing the body can change this, and changing it re-checks every importer.
>
> Hint: an annotation pins it.

It is not an error and does not fail a build. It exists so that plan §7's M3 churn measurement has
something to count, and so the cost report 18 §2.3 predicts is observable rather than argued —
and, since it is on by default, so that the author of the declaration is told at the moment the
interface acquires the suffix rather than only when somebody goes looking with a flag.

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

### 10.11 `too_many_inferred_constraints`

Appended 2026-09-18, after §10.10 and after both catalogues, so no number above it moves (A.83).

**Severity** error. **Region** the declaration's name. It applies to every **unannotated**
declaration, `pub` or not, in every package, and it fires when the promoted set of §6.4 would hold
more than `Solver.max_inferred_constraints = 64`.

> **TOO MANY INFERRED CONSTRAINTS** — `<decl>` has no annotation, and the type I inferred for it
> needs `<n>` methods. I stop at 64.
>
> The first five are `<m1>`, `<m2>`, `<m3>`, `<m4>` and `<m5>`.
>
> Each one is an argument I have to pass at every call to `<decl>`, and a line in this module's
> interface that every importer is checked against. A list this long is almost always a chain of
> unannotated helpers, each one inheriting what the one before it needed.
>
> Hint: annotate `<decl>`. An annotation pins the type, and a `where` clause you write yourself may
> name as many methods as you like.

**Only the first few names are printed** — five, and a count of how many are left — because bounding
the output is half the point: report 19 §3.1 reaches a 6.4 kB rendered scheme for one declaration,
and a message that printed all of them would be the same 6.4 kB with a title on it. The rendered
scheme is *not* printed for the same reason; §10.9 prints it because it is short enough to read.

**Recovery is §6.4's**: the declaration promotes nothing, so its interface has no `where` suffix and
the next link in the chain starts from zero. The bound this buys, measured 2026-09-18 on report 19
§3's own generator (`zig build bench -- --pathological=constraint-chain=n --iterations=3`, then
`command time` over `beni check --jobs=1 .zig-cache/bench-pathological`, ReleaseFast):

| n | this error | `obligations` | `constraints_promoted` | `check` wall | peak RSS | before the cap (report 19 §3) |
|---:|---:|---:|---:|---:|---:|---|
| 1 000 | 15 | 32 549 | 31 525 | 0.14 s | 35.1 MB | 0.44 s, 411 MB, 500 500 promoted |
| 3 000 | 46 | 98 774 | 95 735 | 0.39 s | 91.5 MB | 4.44 s, 3 754 MB, 4 501 500 promoted |

⌊n / 65⌋ errors, and time and obligations linear in n rather than quadratic. This is the answer
report 19 §14 item 5 asks for — the checker does **not** ship a quadratic on a shape a user can
write by accident, because the shape stops being accepted at 64 — and item 4's cap on the inferred
`where` suffix falls out of it: a promoted suffix is now at most 64 clauses, ~2 kB at §3.1's
measured 31 characters per clause, where an annotated one is bounded by the annotation's own text.

**The total diagnostic count is still one per declaration**, and that is §10.9's warning, not this
error: every link of the chain is an unannotated `pub` declaration whose interface really did
acquire a suffix, so n = 3000 prints 2 954 warnings and 46 errors. One message per declaration is
the ordinary rate for a per-declaration diagnostic and it is what makes the pathological input
finish at all; what the cap removes is the n² *under* it. `bench/bench.zig`'s own `diagnostics:`
figure counts **only the errors** — 15 and 46 — because the bench harness is not `check` or
`build` and so emits no informational warning; that column is what report 19 §3's C0 rows read,
and it is comparable to them again.

**The warning's rendering is the expensive part**: it prints the whole scheme, and report 19 §16
listed its cost at scale as never measured. Measured now, at the pathological extreme where every
scheme is at the 64-clause ceiling: ~0.1 ms per warning in ReleaseFast (0.39 s wall for a run that
prints 3 000 of them) and **~23 ms** per warning in a **Debug** build, where `Render.Namer.allocate`
pays an allocation and a linear scan per candidate suffix while it numbers `number`, `number2`, …
`number65`. Debug is not a shipping configuration and no real scheme is 64 clauses wide, so it is
recorded rather than fixed.

Fixtures: `tests/corpus/check/bad/TooManyInferredConstraints.beni` (65 distinct methods on one
unannotated declaration), `tests/corpus/check/good/SixtyFourConstraints.beni` (64, clean) and
`tests/corpus/check/good/AnnotatedManyConstraints.beni` (the annotated 65-constraint twin, clean),
plus the bounded-recovery scenario in `tests/blackbox/abuse_test.zig`.

---

## 11. Known limits, and where the design may change

Everything here is a limit the design **accepts on purpose**. None of it is a bug to be filed; each
was either measured (§7 of the plan) or recorded in report 19, and the 2026-09-18 adoption took them
with the feature. The five that the adoption left as work rather than as accepted limits are report
19 §14's owed list, not this section.

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

**A constrained `let` binding is monomorphic.** §6.4 rule (a) refuses to generalise a `let` over a
variable carrying a method constraint, which is how the spike avoids Roc's promoted-requirements
side table (`references/roc/design.md:5461-5468`, report 20 §9 row S3-4). The price is that a helper
defined in a `let` and used at two types is a `type_mismatch` at the second use
(`tests/corpus/check/bad/LetConstrainedTwice.beni`, §10.5, A.49) where an unconstrained helper would
have been fine. The fix the message suggests — lift it to a top-level declaration with an annotation —
always works, because a top-level boundary has no enclosing rank to escape to. Whether this bites in
real code is a finding for report 19: if §6.4 rule (b)'s assert ever fires, or if the corpus rewrite
trips over rule (a), the side table is the answer and the spike will have measured the thing report
20 §10 says Roc has never measured.

**Resolve-method-first only fires on a concrete receiver.** §6.2 Rule U0 seeds a lambda argument's
parameter types from the method when the receiver's type is already known at that point in the
constraint tree. When it is not, the arguments check against fresh variables and a mistake inside
the lambda surfaces later and further away. Roc has the same limit — `resolve_method_first` is a
test, not a retry (`references/roc/src/check/Check.zig:20054`) — and the spike does not add a second
pass.

**Deferred receiver.** `x.m a` with `x`'s type still unknown is a method constraint, never a field
call, so `\r -> r.f 1` where `r` turns out to be a record is `no_methods_on_shape` with a hint to
write `(r.f) 1`. This is the ambiguity report 18 §2.1 names and the one Roc's `->` operator lives
with; M6 shows the message.

**Same-name constraints unify.** One constraint per `(variable, name)` (§6.1 invariant 3), so the
rank-2 example from Roc's August-2026 thread fails with `method_constraint_mismatch` (§10.5). That
is right for a `where` clause and for an operator desugaring, and too strong for two independent
dot-calls. Roc's principality fix **shipped**, and report 20 §2.3 establishes that it is not what
the Zulip thread described: see stretch item 1 below for what it actually is.

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

**M4 reports `eq` bytes and `compare` bytes as two numbers, never their sum.**
`dump --stage=dispatch` already distinguishes them (`derived <i> eq|compare`, §7.3), so the split
costs nothing to collect. It is required because Roc derives six methods and **`compare` is not one
of them** (`references/roc/src/check/static_dispatch_registry.zig:1315-1322`): the spike's
derivation surface is strictly larger than anything Roc has ever shipped, and the extra half comes
from a *separate* decision — making `compare` well-known, plan §0 — which report 18 §5 said should
be argued on its own merits. A single summed figure would charge static dispatch for the cost of
dropping `comparable`, and report 19 must not let it (report 20 §9 row S6-1).

**`String` and `Char` ordering costs a call.** `primitive string_compare` emits `String$compare` and
`char_compare` emits a code-point comparison, not `<` (§3.2, §9.1). `<` on JavaScript strings is
UTF-16 code-unit order and `core/String.js:40-57` is Unicode scalar order; they differ for astral
characters, and a language where `"a" < "b"` and `String.compare a b` disagree is worse than one
with neither. This is correctness chosen over speed **with the speed cost known and unmeasured**:
M5 R3 (`List.sort` of 100k `String`) is where it shows up, and if it is large the honest options are
to change the order (a language change, not a spike decision) or to inline the loop at the call
site, not to quietly use `<`.

**A literal inside `core` can make `core` cyclic.** §6.8 gives every module an edge to the module
that owns each type its instructions mint — `core:Basics` for a number or a comparison, `core:List`
for a list literal, `core:String` for a string, `core:Char` for a char, both `core:Maybe` and
`core:Result` for a `?`. A minted edge always points *into* `core`, so no user project can be made
cyclic by one; inside `core` there is nothing below to point at, and a string literal in
`core/Basics.beni` would make `Basics` depend on `String`, which depends on `Basics`. The author's
diagnostic would be `import_cycle`, for writing `"…"`. No core module does this today, and §5's
preamble makes keeping it so a condition on the S6 rewrite. The alternatives, if one is ever
genuinely needed, are an exemption stated in §6.8 (a named list of literal kinds that mint no edge
inside `core`, at the cost of the invariant holding only outside it), or moving the offending
declaration into a module lower in the core graph. Neither is taken now.

**A cross-module alias is transparent after all** — this row said the opposite and was wrong
(A.48). Looking an alias through does **not** need `Interface.alias_body`: the interface's own
`alias` term already carries the expansion as the last word of its range
(`Interface.Term.Tag.alias`, `checker.md` §7), so `TypeStore.resolved` walks a cross-module alias
exactly as it walks a same-module one and `store.resolved` is all §6.3's alias row ever needed.
`tests/corpus/check/good/AliasAcrossModulesMethod/` pins it: `==` on an imported record alias
derives over the record shape, and `p.field` is the field access it always was.

**The `foreign` surface was wider, and is not any more.** §5.2 lets a `pub foreign` carry a `where`
clause, which makes the sibling export's arity depend on the checker's answer rather than on the
declaration's text. `boundary.md` §4's automated checks were export coverage and import coverage;
neither checked arity, so the rule was documented and **not enforced**, and a `core/List.js` whose
`eq` forgot its leading evidence parameter failed at runtime rather than at build time. CLAUDE.md
rule 6 says not to widen that surface for convenience; this widening was not for convenience — the
list representation is the emitter's, so `List.eq` cannot be written in beni — but it was a
widening, and the adoption decision weighed it and left it owed. **Closed on 2026-09-18** as
`boundary.md` §4's check 4 (A.84): the third alternative this row did not consider turned out to be
the answer — count the parameter list lexically, as check 3 already reads imports, and refuse the
two forms that reading cannot settle. No JavaScript parser, and neither of the alternatives this row
named (an approximate arity check, or refusing `where` on `foreign` and giving `List` an uncons
primitive) was taken.

**Cross-module recursive derivation is refused before it can happen.** The shape this row was
written for — a type in module `A` whose payload mentions a type in module `B` whose payload
mentions `A`'s, making `A$$eq` and `B$$eq` mutually recursive across an ESM cycle — cannot be
written: `A` mentioning `B`'s type and `B` mentioning `A`'s is an `import_cycle`, which the module
graph rejects before a single declaration is checked. The language has no mutual recursion across
a module boundary for types, so derivation has none either. What remains is the SAME-module case
(`type Tree = Leaf | Node Tree Int Tree`, whose `Tree$$eq` names itself), and that is one `const`
arrow naming itself from inside its own body, which JavaScript has always allowed and which
`emit/DerivedEqNominal` pins. The temporal-dead-zone worry the earlier text raised was therefore a
hazard of a program the compiler does not accept. It is recorded here rather than deleted because
a future module system with recursive imports would bring it back, and this is where it would land.

**Constrained constants** are refused (`constrained_constant`, §6.4) rather than silently turned
into functions. `Dict.empty` is unaffected — it has no constraint (§5.3).

**An inferred set of more than 64 method constraints is refused** (`too_many_inferred_constraints`,
§6.4, §10.11), which is a real ceiling on inference and is taken deliberately: it is what bounds
both the interface suffix report 19 §3.1 found unbounded and the n² of §3, and no program that
checked on pre-dispatch `master` is inside the range it removes (report 19 `results:152-167`). An
annotation lifts it entirely, so nothing is unwritable — only uninferable. If a real program ever
wants 65 inferred constraints, the number is one constant. A.83.

**Interface hashing does not exist**, so plan §7's M3 measures interface *bytes changed* through
`dump --stage=raw`, which is exactly what M4's hash will be taken over.

**`equatable` and `eq` overlap** after S5. Left in place, recorded (§3.4).

**A part is written when the RECEIVER is resolved, not when both operands are.** `Ok 1 == Err "a"`
is a `Result String Int`, so the `x` position is `String` and not a variable at all — and the table
records `err` for it. The reason is §6.2's Rule U0: the constraint is discharged from inside the
unification that made the receiver concrete, and the receiver (`Ok 1`) pins only `a`; the `String`
arrives from the argument afterwards, by which time `nominalTarget` has already written the range.
Fixing it means resolving a target's parts in a second pass at the end of the declaration rather
than at discharge, which is a change to §6.3 and §7.1 together and not a local one, so S6a left it.
It is harmless for the same reason an unconstrained position is: the receiver always pins the
position its OWN constructor carries, so the position left `err` is the one the tag test rejects
before either side is read. `dispatch/ErrParts` is the pin, and A.67 is what the backend does with
the `err` it sees.

**Two constraints joined on one variable emitted one instruction's slot twice — now FIXED**
(A.75). This was a DEFECT and not an accepted limit; the row stays because §11 is where a reader
looks. `Solve.unionConstraints` and `Solve.attachConstraint` rebuild a constraint set onto a FRESH
range (§6.1 invariant 2), so each input is copied to a new index and left behind at the old one —
and the obligation's `index`, `resolved_methods` and `deferred` are all keyed on that index. The
superseded constraint and its replacement were therefore two live obligations over one site list:
each called `emitSites` over the list it held and the joined one over the union, so one
instruction's slot 0 was written twice and `Lower.evidenceShapeOk` refused the call as `internal`.
It bit when two nested calls of a constrained function had their receiver variables unified *after*
both were instantiated, which is exactly `Dict.insert (Dict.insert d k v) k v`:

```elm
pub type Box k = Box k
pub put : Box k, k -> Box k where k.compare : k, k -> Order

nested : Int
nested = size (put (put (Box "z") "a") "b")     -- two sites per instruction, one expected
```

Pinning the outer result with an annotation (`annotated : Box String`) hid it, because each
constraint was discharged and marked before the join happened. It was pre-existing on `8081b5f`,
reproduced with no core change, and `tests/corpus/run/Dictionaries.beni` is the program that found
it. The fix is A.75: a rebuild REDIRECTS every index it superseded to the constraint that replaced
it, and everything keyed on a constraint index reads through the redirect, so the replacement is
what answers and it answers exactly once (A.57). Pinned by
`tests/corpus/dispatch/JoinedConstraintSites` and `tests/corpus/run/NestedConstrainedCalls`.

**A `where` constraint that meets a record only after a field access is refused.** §6.2's Rule U0
resolves a method against a receiver that is already concrete and never retries one that was still
a variable; §6.3 refuses an OPEN record, and reading a field off a lambda parameter is what opens
one. So `List.foldl points Dict.empty (\p d -> Dict.insert d p (p.x + p.y))` is
`no_methods_on_shape` on a record the author wrote closed, while the same fold with the value
behind an annotated helper compiles. This is A.28 and §6.2's "what it does not buy" meeting in a
program a user would plausibly write, and `bench/runtime/c1/R2DictRecord.beni` is the first
program in the tree to hit it — its `weight` helper is the workaround, written out and explained
in the file.

**`Dict` and `Set` now derive both methods, and nothing calls them.** `Dict k v` held a comparator
before §5.3, so §6.3.1 step 4's function-payload exclusion gave it neither `eq` nor `compare`, and
`Set t = Set (Dict t ())` inherited the exclusion. Taking the comparator out makes both derivable,
so core ships four more nominal functions plus the two structural ones `Set` needs for the `()`
inside its `Dict` — six, none of them called, on top of the seventeen that were there. That is the
eager rule of §8.5 meeting the "no DCE yet" row, it is the sharpest single number M4 has, and
`tests/blackbox/build_test.zig`'s `bench/size.mjs` scenario is what counts it.

**`==` on a `Dict` is a comparison of red-black trees.** Module `Dict` declares no `pub eq`, so
§3.3 falls through to derivation over the shape, and two dictionaries holding the same four pairs
answer `False` to `==` while their `toList`s answer `True`. Giving `Dict` and `Set` methods of
their own is out of the spike's scope (S6 decision O-5); `tests/corpus/run/DictStructuralEquality.beni`
prints the answer so that the finding is a fact rather than an argument, and report 19 is where it
goes.

### Stretch, only after S8

1. **Partition same-name constraints by origin class** — Roc's shipped principality fix, and not
   the "keep several constraints per name" the Zulip thread described (report 18 §2.2, corrected by
   report 20 §2.3 and §9 row S3-3). `partitionStaticDispatchConstraints`
   (`references/roc/src/check/unify.zig:3599-3607`) states the rule: *"When a same-name group
   contains any declarative relation (where clause, literal, or operator), the whole group unifies
   through one representative declarative; a group of dot calls alone stays separate so each use can
   instantiate a selected rank-1 method scheme independently."* Per same-name group: a
   **declarative** constraint — `origin` of `where_clause` or `well_known` in §6.1's enum — makes the
   whole group unify through one representative, which is today's invariant 3; a group of
   `dot_call` constraints alone keeps **every member separate**, one per use
   (`references/roc/src/check/unify.zig:3807-3824`). The cost is a sort by origin plus an
   arity-and-effect pre-check (`:3709-3746`), not a new representation — estimate the item from
   that, not from the Zulip description.

   It has a backend half, which must be costed with it: **evidence slots dedupe by method name, not
   by constraint.** `emitConstraints`
   (`references/roc/src/check/dispatch_evidence.zig:510-543`) emits one evidence parameter per
   `(dispatcher var, method name)` even when the variable carries several same-name constraints, and
   pushes each constraint's `fn_var` onto a queue for further walking; the call whose constraint is
   not the representative is marked `independent_callable`
   (`references/roc/src/check/static_dispatch_registry.zig:1344-1357`). §7.2's canonical order
   would need the same two rules — dedupe by name, and a second phase over the constraints' own
   function types — and §7.1's `Site` would need to record which constraint of a name it used.
   Report 20 §9 row S3-12.
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
parser to do properly, the dependency the wall exists to avoid. **Superseded 2026-09-18 by A.84:**
the arity check landed and needed no parser, so the rule is `boundary.md` §4's check 4 and this
row's "not enforced" is history.

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
the exit code (`frontend.md:50-51`), so `--explain` can never turn a passing build into a failing
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
reference to a constrained value. *Why:* `backend.md` §6 (`backend.md:216`) requires a
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

---

The rows below were added on 2026-09-17 after
[`research/20-roc-static-dispatch-implementation.md`](research/20-roc-static-dispatch-implementation.md)
walked Roc's Zig implementation. Bracketed numbers are that report's §9 rows.

**A.30 — a `let` binding is never generalised over a constrained variable, and there is no
promoted-requirements side table** (§6.4, §11) [S3-4]. Roc's generalised scheme is a pair — root
type plus an explicit table of promoted requirements — because a requirement's receiver can belong
to an enclosing scope while its callable mentions scheme-owned variables
(`references/roc/design.md:5461-5468`). The spike removes the case rather than representing it:
a constrained variable is held at the enclosing rank at a `let` boundary, so every constraint that
reaches promotion sits on a variable the declaration itself quantifies, and `generalize` asserts
(debug) or reports (release) if one ever does not. *Why:* the side table is a second artifact to
build, hash, serialise and instantiate, for a case report 20 §10 records that Roc has never
measured the frequency of. *Alternative:* build it, which is Roc's answer and the right one if the
assert fires. *Cost:* a constrained `let` helper used at two types is refused rather than
instantiated twice; §11 carries the row and
`tests/corpus/check/bad/LetConstrainedTwice.beni` the fixture. **Amended by A.49**: the refusal is a
`type_mismatch` at the second use with a hint of its own, not `method_constraint_mismatch`.

**A.31 — `Target.evidence` is one number, with no depth** (§6.4, §7.1, §8.1) [S4-1]. Roc carries
`EvidenceChainIndex { depth, index }` and resolves it by walking out through enclosing callables.
beni does not need `depth` because A.30 means only a top-level declaration has evidence parameters,
and a lambda in its body is a JavaScript closure that captures `$m$k` lexically. *Why:* it is true,
and leaving it unsaid would have made a later reader add `depth` defensively. *Alternative:* carry
`depth` anyway, which costs a field and an unused walk. `tests/corpus/run/EvidenceCapture.beni`
holds it.

**A.32 — the well-known marking is a surface-origin enum, not a flag** (§1.3, §1.4) [S3-10]. It
records *which* operator desugared into the node. *Why:* the typing rule differs between `a == b`
and `a.eq b` (A.33), diagnostics must say `==` rather than `eq`, and `dump --stage=bir` is a tested
output that has to show it. Roc's third reason — re-emitting operator forms from canonical IR
(`references/roc/src/canonicalize/Expression.zig:756-770`) — **does not apply to beni**, because
`fmt` is an Ast pass and never sees BIR; the enum is justified here on the first three grounds only.
*Alternative:* a boolean plus a lookup from method name to operator, which is Roc's
`getOperatorForMethod` and is ambiguous for `eq` (`==` or `/=`?).

**A.33 — `a == b` pins both operands to one type and the result to `Bool`** (§3.1) [X-4]. Deliberately
tighter than the constraint `a.eq b` raises. *Why:* Roc's stated reason — comparison operands
determine each other's type before a method is selected
(`references/roc/design.md:3002-3012`) — plus one of beni's own: a looser scheme is a bigger scheme,
and M3 measures interface churn, so lowering `==` to the dot-call constraint would have made the
spike measure churn caused by its own lowering rule. *Alternative:* one lowering for both forms,
which is simpler to implement and corrupts the measurement the spike exists for.

**A.34 — the method is resolved before its arguments when the receiver is already concrete**
(§6.2 Rule U0) [S3-9]. Implemented as a constraint-*generation* ordering — a new `method` node
emitted before the `call_arg` nodes inside one `and_`, which `Constrain` already solves left to
right (`src/check/Constrain.zig:128-130`) — plus an inline discharge in `Solve` when the receiver's
root is not `flex`. *Why:* without it a lambda argument checks against a fresh variable and every
mistake in its body cascades. *Alternative:* leave it out and accept the cascade, which is what the
first draft did silently; §11 records the residual limit (a receiver still unknown at that point
gets no second attempt).

**A.35 — every table written during discharge is journaled by length** (§6.1 invariant 2) [S3-5].
`TypeStore.Snapshot` grows from `{ journal_len, vars, extra }` to include the constraint tables and
all four `Dispatch` builders, and the truncation is **per snapshot** because beni's journal nests
(`src/check/TypeStore.zig:229`) where Roc's asserts it does not
(`references/roc/src/types/store.zig:425`). *Why:* §6.2 registers obligations from inside `unify`,
so `dischargeMethod` can run under a `?` probe, and a rolled-back probe that left sites behind would
emit a call the checker retracted. *Alternative:* forbid discharge under a probe — which is what Roc
asserts for promotion (`references/roc/src/check/Check.zig:28368-28370`) — but beni's `?` probe runs
before the shape is known, so the obligation is registered before anyone could check.

**A.36 — only a closed record derives, and the test names the content variants** (§6.3) [A.28
refined]. `Structure.record { fields, ext }` derives when `find(ext)` is `Structure.empty_record`;
a `Content.flex` extension means more fields may arrive, and a `Content.rigid` one means the
annotation promised to work for every extension, so neither has a shape key. *Alternative:* defer
until the extension closes, a third deferral mechanism beside constraints and obligations.

**A.37 — an obligation carries the instantiating instruction, and it is the primary span**
(§6.2, §10 preamble, §10.1, §10.4, §10.5) [S3-11]. `Solve.Obligation` gains `origin`; the message
points at the call the author wrote and names the annotation it came from as a secondary span.
*Why:* this is report 18 §2.4's complaint, and report 20 §7.2 shows Roc records the same instruction
(`DeferredConstraintCheck.failure_expr`) and never reads it. *Alternative:* one span at the
constraint's own region, which for an imported scheme is inside the callee — the Roc behaviour the
spike exists to beat. The fixtures assert span *order*, not just the set.

**A.38 — M4 reports derived `eq` bytes and derived `compare` bytes separately** (§11) [S6-1]. *Why:*
Roc derives six methods and `compare` is not among them, so the spike's extra half belongs to the
independent decision to make `compare` well-known (plan §0), not to static dispatch. *Alternative:*
one number, which would charge dispatch for the cost of dropping `comparable` and would make report
19 wrong in the direction that flatters the objection.

---

The rows below were added on 2026-09-17, after the read-only review of S2 (the front end). Each is a
**text correction**: the code S2 landed is what the row now describes, and the earlier wording was
written before the code existed. Nothing here changes a decision.

**A.39 — `dump --stage=bir` prints `method_call %2 .eq [%3] (==)`** (§1.4) [m13]. The method name
carries its dot, as `field_access` already prints it and as the source writes it, and the origin is
parenthesised after the arguments. *Why:* the spec's `method_call %5 eq [%6] from \`==\`` was
invented before the dumper existed and reads worse — a bare `eq` where every other name-carrying
instruction shows the dot, and a `from` clause the eye has to parse. The code is better and the
goldens are the contract. *Alternative:* change the dumper to the spec's spelling and re-bless.

**A.40 — the operator goldens are `tests/corpus/bir/ComparisonOperators.beni` and
`tests/corpus/bir/MethodCalls.beni`** (§1.4) [m13]. The spec named a file
`tests/corpus/bir/OperatorsAsFunctions.beni` that was never written. *Why:* the two fixtures split on
the claim they pin — every row of §1.1, and every spelling of §3.1 — which is the corpus's "one idea
per fixture" rule. *Alternative:* one fixture with both, under the spec's name.

**A.41 — `where a.eq : a, a -> Bool, b.x` is `expected_token` expecting `->`, at `.x`** (§2.3)
[m13]. *Why:* it is what the rule the section specifies actually produces — the comma stayed a
parameter separator, so `Bool, b` is a parameter list and the arrow it needs never came — and naming
the missing arrow is more useful than naming the token that is not it. The spec's `unexpected_token`
was a guess at the consequence. *Alternative:* special-case the lookahead to report the constraint
head it half-matched, which is a rule with no other purpose.

**A.42 — `k.Compare` is `invalid_character` from the LEXER** (§2.1) [m13]. A `dot_lower` is `.`
followed by a lower letter (`src/lex/Tokenizer.zig`), so `.C` never becomes one and the constraint
never reaches the parser. *Why:* the spec said `unexpected_token`, which is what `k . compare`
gets — a different path with a different message. *Alternative:* none; this is a lexical fact.

**A.43 — §10.6 (b) shows the annotated type and says "the declaration"** (§10.6) [m13]. It does not
quote `<v>.<m> : <the constraint's type>`, and the hint does not name the declaration. *Why:* a
lowering diagnostic carries exactly one secondary byte range, and the annotated type is the half the
reader has to change; the span already points into the constraint. *Alternative:* widen
`bir/Diagnostics.Item` to three ranges for one sentence in one message.

**A.44 — trigger (a) of §10.6 suppresses trigger (b) for the same variable** (§10.6) [m13]. *Why:*
the section's own example — `where a.show : a -> String` under `render : Int -> String` — trips both,
and two messages for one mistake is the thing `fast-compiler.md` §5 and every `check/bad` golden
exist to prevent. *Alternative:* report both and let the reader work out that they are one.

**A.45 — §6.8's implicit-edge rule is replaced by a minted-type scan** (§6.8, §5 preamble, §7.3,
§11). The first draft — "an edge to the declaring module of every `TypeId` in the Bir and of every
`TypeId` reachable through the terms of any scheme it imports" — is **not computable where it was
placed** (`Graph.build` runs before `Resolve.run`, and `Interface.build` writes no schemes and no
terms: `Value.scheme` is `.none` until the checker fills it) and is **a no-op even if it were** (a
type a module writes is already an `import_type` ref and therefore already an edge; a type arriving
through a dependency's interface is already covered by the driver's transitivity, since a module
starts only once every dependency has finished). What ships instead is one pass over each module's
instruction-tag column mapping the five literal/desugar families to `core:Basics`, `core:List`,
`core:String`, `core:Char` and `{core:Maybe, core:Result}`, resolved with `g.lookup(.core, …)` and
appended in fixed order after the import edges (`src/resolve/Graph.zig:298-312`, `:386-396`,
`:400-435`). *Why:* that is the actual hole — `pub sizes = [ 1, 2 ]` in a module with no imports had
**zero** dependencies and ran beside `core/List` at `--jobs=8`, and §1.4's removal of the `refs`
edge for `method_call` took away the `Basics` edge that `Basics.lt` used to give `a < b`. *Cost,
measured:* edges 3837 → 3938 (+2.6 %), `resolve` 4.93 → 4.85 ms best-of-twelve ABBA on
`--generate=100000`; not measurable, and the first draft's "the DAG narrows" paragraph was
over-stated. *Alternative:* have `Lower` record the six-bit set per file during the parallel phase
and hand it to `Graph.build`, which removes the serial scan entirely — worth doing if that scan ever
shows in a profile, and not worth the extra field in `Bir` before it does. *New obligation:* a
minted edge inside `core` can create an `import_cycle` from a literal, which §5's preamble makes a
condition on the S6 rewrite and §11 records.

---

The rows below were added on 2026-09-17, after the read-only review of S3 (the checker). Three of
them fix a miscompile the first implementation shipped; the rest are decisions the review asked to
be written down rather than left in the code.

**A.46 — a structural derived function is keyed on its SHAPE and parameterised by element
evidence** (§7.1, §9.2, §9.3) [B1, M4]. `Derived` carries `evidence_count` and, for a nominal shape
only, the body's per-constructor-argument positions; the evidence a use passes rides on the
`Target` as its own `parts` range, and those ranges nest. *Why:* the first implementation keyed the
function on the shape — which A.11 requires — but baked the FIRST requester's element targets into
it, so a second `( String, String ) < …` reused `part 0 primitive num_compare` and ordered strings
with JavaScript `<`, which is the UTF-16 order A.26 refuses; `{ x : Int, y : ( Int, Int ) }` shared
`r$x$y` with `strict_eq` on the tuple. It also made `partTarget` return a silent `err` for a nested
record or tuple, so no nested shape was ever derived at all. *Alternative:* monomorphise per
concrete field-type vector, which A.11 already refused for needing a total mangling of arbitrary
types into a name; or key the function on `(shape, element targets)`, which is that mangling under
another name and makes M4's shape count meaningless.

**A.47 — another module's nominal method is `Target.ext_derived`, not a row in this module's
`derived` table** (§7.1, §7.3) [M11]. *Why:* derivation for a nominal type is eager and happens in
the DECLARING module (A.23), so `derived` means exactly "the functions this module emits" and S5 can
walk it without asking which rows are really references. The name is `<Module>$<Type>$<kind>` by
§8.5, which the `TypeId` and its `Types.Entry.module` already determine; the variant carries the
module explicitly so the table stays self-describing for a backend that holds no type store.
*Alternative:* a `derived` row with an `owner` flag, which makes `derived <i>` mean two things and
puts rows S5 must skip in the middle of the list it emits.

**A.48 — a cross-module alias is TRANSPARENT** (§1.2, §6.3, §11). The earlier rows said it was
`no_methods_on_shape` "because looking it through needs `Interface.alias_body`, which is not
implemented". That is wrong: the interface's own `alias` term carries the expansion as the last word
of its range (`checker.md` §7), so `TypeStore.resolved` follows a cross-module alias exactly as it
follows a same-module one and nothing had to be built. *Why the correction rather than the code:*
the behaviour is strictly better and matches §1.2's own rule that an alias is transparent;
`tests/corpus/check/good/AliasAcrossModulesMethod/` pins it. The fixture the old row named,
`check/bad/MethodThroughImportedAlias/`, was never written and is not needed.

**A.49 — §6.4 rule (a)'s boundary surfaces as `type_mismatch`, with a hint of its own** (§10.5,
§11, A.30) [M7]. A `let` binding that is not generalised over a constrained variable has its type
fixed by its first use, so the second use is an ordinary argument mismatch and never reaches
`method_constraint_mismatch`. *Why not make it reach that code:* by then the constraint has been
discharged against the first use's type, and re-raising it would mean keeping a second, parallel
record of what a variable used to carry. The checker remembers one thing instead — which variable
rule (a) held back, and which method held it — and the mismatch's hint names the binding, the
method, and the fix. *Alternative:* leave the generic hint, which told the author that `<` and the
arithmetic operators work on numbers only.

**A.50 — `compare` on a `foreign type` with no `pub compare` is `unknown_method`; `eq` on an
`equatable` one is not** (§3.3) [M1]. Derivation needs constructors to walk and a `foreign type`
has none, so §3.3's last clause applies — except that §3.4 makes the `equatable` marker mean
exactly "has an `eq`", which is the bridge `core/List.beni` leans on until §5.2 gives it a
`pub foreign eq`. *Why:* without the bridge every program comparing a list stops compiling, and
§5.2 is S6; with it applied to `compare` as well, `xs < ys` would derive over a representation the
compiler cannot see. *Alternative:* land §5.2 in S3, which is a `core/` signature change and a
different slice. §11 carries it as S6's obligation.

**A.51 — the S4 shim REFUSES what it cannot honour** (§8) [B2]. `Lower.Input` gains
`dispatch`, and the shim reports `not_implemented` for any site it cannot emit correctly: it keeps
`field`, `==`/`/=` against a structural answer (`primitive strict_eq`, a derived function, or
`Basics.eq` through the `equatable` bridge — `core/Basics.js`'s `eq` IS that structural walk), and
`<` and friends against `primitive num_compare`. Everything else — `char_compare`,
`string_compare`, a derived `compare`, a user `pub eq`, and every evidence site — refuses. *Why:*
S3 made `T 1 < T 2`, `( a, b ) < ( c, d )` and `"a" < "b"` CHECK, and the shim emitted `Basics$lt`
on objects and strings for all three; `master` rejected them and printing a wrong answer is worse
than either. `backend.md` §1 ships the language in two halves and the missing half must say so.
*Alternative:* the reviewer's narrower list (`field`, `strict_eq`, `num_compare` only), which also
refuses `==` on records, ADTs and lists — programs `master` compiled correctly through the same
`Basics$eq`.

**A.52 — there is no `check/depth/ConstraintChain` pair** (§6.3) [M10]. The derivation recursion is
guarded, but every route to that guard is cut off at `Types.Builder.max_depth` (512) first, which
`AnnotationOk`/`AnnotationDeep` already pin — and §6.3's guard is written at `Parse.max_depth + 104`
for the same reason `Constrain`'s and `Solve`'s are: the parser refuses the file before the checker
can reach it, which `generate.sh` has recorded since M2b. *Why:* a pair named for the 4200 guard
that actually measured the 512 one is worse than none. *Alternative:* lower the derivation guard to
something reachable, which would refuse programs for being deep rather than for being wrong.

**A.53 — a `number` or `equatable` variable discharges a well-known constraint with no `where`
clause** (§6.2, §6.3). Not a `where` clause and not the table: a third row on the rigid and flex
arms. *Why:* `number` is `Int` or `Float` and §3.2 gives both the same answer, and §3.4 says
`equatable` means exactly "has an `eq`" — and without it `core/Basics.beni`'s `compare`, `max`,
`min` and `clamp` and `core/List.beni`'s `member` stop checking the moment `<` and `==` become
methods, while their rewrite is §5 and slice S6. The constraint is DETACHED when the bridge answers
it, so `isEven n = n < 1` still publishes `number -> Bool` and not
`number -> Bool where number.compare : …`. *Alternative:* rewrite those five declarations in S3,
which is the `core/` signature change S6 owns.

**A.54 — `compare` has a transitive gate of its own, and a `foreign type` passes it only on a
`pub compare` of its own whose FIRST PARAMETER is that type** (§3.3, §6.3, A.50) [S3]. `Types.Entry`
grows a `comparable` bit beside `equatable`, settled by the same fixpoint over the same edges: an
`adt` or `alias` is comparable when every named type its body reaches is, and a `foreign type` is
comparable when §3.2's table answers for it or its module declares that `pub compare`. The gate is
asked in three places that must agree — the eager pass of A.23, `derivesForNominal`, and the walk
`derivable` makes at a use. *Why:* `equatable` says nothing about ordering, so without it
`type Wraps = Wraps Handle` over a plain `foreign type Handle` derived a `compare` whose one part
was `err` and `a < b` on it compiled clean. **`pub`** because this is one bit on a session-wide
table that every module reads, and a private `compare` is invisible to all but one of them; **the
first parameter** because a module's `pub` values are one namespace (§11), so
`pub compare : Tag, Tag -> Order` beside an unrelated `pub foreign type Handle` is `Tag`'s method,
and taking it for `Handle`'s emitted a call to it with a `Handle` in hand — no diagnostic, an
unsound `part 0 top compare`. *Alternative:* key the gate on the use site instead, so a private
`compare` still orders its own module's types; rejected because the property is one bit per type,
read from everywhere, and a per-module answer is a different data structure. *Known behaviour
change:* a same-module `<` that reached a private `compare` on a `foreign type` is now refused, and
`type W = W Fn` whose `Fn` holds a function but whose module supplies a `pub compare` is refused
too (HEAD accepted it with `part 0 ext Fns compare`) — consistent with `equatable`, and a change.
Fixtures: `check/bad/core/CompareOnWrappedForeign`, `check/bad/core/CompareOnForeignWithUnrelatedCompare`,
`check/bad/PrivateForeignCompare/`, and the positive `dispatch/core/ForeignPubCompare`.

**A.55 — a NULLARY `foreign type` never gets a derived row** (§6.3, §8.5, A.50, A.60) [S3]. Neither
the eager pass nor a use mints `derived <i> eq|compare <Foreign>` for one: there are no constructors
to walk and nothing underneath it, so the row would name a function S5 has nothing to emit for. A
parametric one is A.60 and keeps its row. What answers `eq` on an `equatable` one is
`core/Basics.beni`'s `eq`, the one structural walk, which is what the `equatable`-rigid bridge
already uses and what the S4 shim emits for every `==` (A.53). *Why:* a table that names a function
nobody writes is worse than one that says `err`, and §3.4's marker is a promise about a
representation the compiler cannot see. *Alternative:* emit a stub that throws, which trades a
build-time hole for a runtime one. Fixture: `dispatch/core/NoForeignDerivedRow`.

**A.56 — a constraint derives by its NAME, not by the surface it came from** (§3.3 step 2, §1.3
rule 2) [S3]. `isWellKnown` is `name ∈ { eq, compare }` and `origin != .dot_call`: an operator, a
`where` clause and a return-type dispatch are all declarative — the author asked for the method by
the name the compiler owns — and all three derive, while a hand-written `x.eq y` stays
`unknown_method`, which is the one exclusion §1.3 rule 2 makes. *Why:* testing `origin ==
.well_known` alone meant a constraint instantiated from a `where` clause never derived at a user
type, so `eqGen Red Green` under `eqGen : a, a -> Bool where a.eq : …` was `unknown_method` and
§5's `Dict`/`Set`/`List.sort` rewrite — every one of which reaches its method through a `where`
clause — could not have compiled at all. *Alternative:* let a `dot_call` derive too, which is §1.3
rule 2 reversed and makes `x.eq y` silently mean something the module never declared. Fixture:
`dispatch/WhereClauseDerives`.

**A.57 — every instantiation's constraints get an obligation, and a constraint is answered exactly
once** (§6.2, §6.3) [S3]. Both halves are one decision. **Every instantiation**: a local copy
(`tagInstantiated`) and an imported scheme (`Schemes.instantiate`, through `importedValue`) each
register one obligation per constraint they create, instead of waiting for Rule U3 to carry one in
when the variable meets a structure. **Exactly once**: the solver records which constraints have
been answered, and the second answer — whichever route brings it — is a no-op. *Why:* a `number`
literal is a flex that never meets a structure, so U3 never fires for it and `Gen.before 1 2` got
NO evidence site at all while `1.5` and `"a"` got one each; the emitted call was one argument short
and Node threw `$m$0 is not a function` at load. And once every route registers, two of them can
answer the same constraint: a failing one printed its diagnostic twice (`Reporter.emit` has no
dedup) and a succeeding one passed the same evidence argument twice
(`inner($m$0, $m$0, x, factor)`). *Alternative:* collapse duplicate rows in `Dispatch.finish`, which
was tried and removed — it hides a disagreement as readily as a repetition, and the rows it
collapsed were a symptom. Fixtures: `dispatch/LiteralEvidence`,
`dispatch/LiteralEvidenceAcrossModules/`, `check/bad/WhereCallOnUnorderableType`.

**A.58 — `has_function` is a third bit, because §10.3 has two sentences and the gates have one
answer** (§10.3, A.23) [S3]. `Types.Entry` carries "a function is reachable inside this type",
settled by the same fixpoint the other two use and spreading the other way: false by default, true
along the edges from any type whose own body holds a function. `equatable` and `comparable` each
fold several causes into one bit and cannot say which fired; this one can, so §10.3 keeps its
sentence about the function ("there is a function inside it, and functions have no ordering") for
the types that have one and says "something it holds has no ordering of its own" only for the rest.
*Why:* the exclusion of A.23 is transitive — `type Indirect = Indirect HasFn` holds a function as
surely as `HasFn` does, through another nominal type that a walk over one body's `app` arguments
would miss — and until the bit existed the `contains_function` arm was unreachable for any `app`
receiver, so a type that directly held a function got the vaguer sentence and a type wrapping a
`foreign type` got a hint about a `pub compare` that had nothing to do with it. *Alternative:* have
the walk report which type failed and re-derive the reason at the message, which asks the question
again at every use instead of once per session. Fixtures: `check/bad/CompareOnTypeHoldingFunction`,
`check/bad/IndirectFunctionPayload`, `check/bad/IndirectFunctionAcrossModules/`.

**A.59 — the A.53 bridge reaches inside a derived shape** (§6.3, A.53) [S3]. `targetFor`'s `.flex`
arm asks `builtinRigidTarget` before it falls back to a fresh constraint, so a `number` position of
a derived tuple or record answers `num_compare` and a `equatable`-marked one answers `Basics.eq` —
the same two answers §3.2 and §3.4 give at the top level. *Why:* without it every literal position
of a derived shape was a hole: `( 1, 2.5 ) == ( 3, 4 )` derived a structural `eq` whose part 0 was
`err`, which is a table naming nothing at the exact position the author wrote a number.
*Alternative:* default an undecided `number` position to `Int`, which is a decision the checker has
no business making inside a shape it derived. Fixture: `dispatch/LiteralEvidence` (`site 54 0
derived 0`, parts `num_compare`).

**A.60 — a PARAMETRIC `foreign type` keeps its derived row; A.55's bridge is for the nullary ones**
(§6.3, §8.5, A.51, A.55) [S3]. `List a` gets `ext_derived List.List eq` with one part per argument,
exactly as it did before A.55; only a `foreign type` with no arguments answers `eq` through
`Basics.eq` directly. *Why:* the row is the only place an argument's method is NAMED, and an
argument may be a type with a user `pub eq`. Sending `List Id` to the structural walk compared
`Id`'s payloads and ignored the method its module declared, so `[ Id 1 2 ] == [ Id 1 99 ]` compiled,
ran and printed `False` where `Id.eq` — which compares the first field only — says `True`; and it
did so silently, because the backend consults `structuralEq` for a `derived`/`ext_derived` target
and never for a bare `ext`. Whether the structural walk will do is a question about the PARTS, so
the backend asks it, and refuses what it cannot honour (A.51). *Alternative:* have the checker
inspect the parts and bridge when they are all structural, which moves the backend's decision into
the checker and duplicates it. Fixture: `dispatch/UserEqInsideParametric` (and `c5` of
`dispatch/WhereClauseDerives`, which moved back to the row shape `master` had).

**A.61 — the synthesised nominal base takes a DOUBLE separator: `<T>$$eq`, `<T>$$compare`,
`<T>$$order`** (§8.5) [S5 fix]. A printed name is the module path with its dots turned into `$`,
then `$`, then the base, so `<T>$eq` puts the synthesised names and the module's own values in one
flat namespace. Module `Shapes` with a `pub type Box` and the submodule `Shapes.Box` with a
`pub eq` then both spell `Shapes$Box$eq`, and a consumer importing both emits two `import`s of one
name — `SyntaxError: Identifier 'Shapes$Box$eq' has already been declared`, after a build that
exited 0. *Why the double separator rather than a reserved word or a prefix:* the empty segment
between the two `$` is unspellable from beni — a module path has no empty segment and an identifier
holds no `$` — so the guarantee is structural and needs no list of names to avoid. The structural
bases (`eq$r$…`, `eq$t<n>`, `eq$unit`, `eq$prim`, `compare$prim`, `compare$char`) keep their single
separator: they begin lower-case and a module path segment is upper-case, so they could never
collide. *Alternative:* a `$D$` infix or a leading `$`, both of which are just as safe and read
worse in a stack trace. Fixture: `blackbox_test`, "a derived method of a submodule's namesake type
does not collide with its values". Every `emit/*.js` golden was re-blessed for it and nothing but
the names moved.

**A.62 — `Lower.Input.types` is a name, declaration AND derivability service** (§8.0, §8.5, A.51,
A.55) [S5 fix]. §8.0 says the lowerer reads targets and never types, and that remains true of every
DECISION about which function a call runs. But `Lower.derivedBodyExists` reads `Types.Entry.kind`
and `Types.Entry.equatable` to answer whether the module owning an `ext_derived` target actually
wrote a body for it — a `foreign type` has no constructors, so no module did — and that is the
refusal A.51 requires, not a lookup. *Why record it:* the field's own doc comment claimed the
backend asked `Types` for names alone, which was the strongest claim in the file and the one that
was false; a reader checking §3's ignorance against the code would have found the discrepancy and
had nothing to read. *Alternative:* have the CHECKER decide it and carry a bit on the target, which
is A.60's rejected alternative under a different name — the question is about the parts, so the
backend is where it is asked.

**A.63 — the eager pass's step-1 exclusion requires `pub`, and §3.2's table is consulted before it**
(§3.2, §3.3, §8.5, A.23, A.47) [S5 fix]. Two corrections to `Solve.deriveOne`, both of them the
same mistake: it asked a narrower question than a USE asks.

A use in another module resolves `(T, name)` through `Interface.findValue`, which maps only the
`pub` entries — so a private `eq` in `T`'s module wins for that module's own uses (§3.3 step 1
says "`pub` (or any, in the same module)") and for nobody else's. The eager pass excluded the row
on any declaration of the name, `pub` or not, so the dependent derived, named `<T>$$eq` in the
declaring module, and imported a name no module had exported: exit 0, `SyntaxError` at load. The
exclusion now tests `is_pub`; the declaring module's own uses still take the private `top`.

And §3.2's table is consulted before §3.3's module rule, which is the order §3.2 itself states and
the order resolution already used. `core/Basics.beni` declares `Bool`, `Order` and `Never` over a
`pub foreign eq` and a `pub compare` of its own — which is precisely why the table exists — so
asking the module rule first let those two suppress every row the table asks Basics for:
`dump --stage=dispatch --core core/Basics.beni` printed no `derived` line at all while every other
module's `<` on an `Order` named `ext_derived Basics.Order compare` (A.47), a target pointing at a
row that was not there. Basics now carries `Order`'s `compare` and both of `Never`'s. `Order`'s
`eq` and `Bool`'s pair stay absent: the table answers `primitive` for them and a primitive is not a
function anyone emits (A.18).

*Why both in one row:* they are one question — "who else can see this name?" — asked of a user
declaration and of the compiler's own table. *Alternative for the first:* make the private value
invisible to its own module too, which would change what §3.3 step 1 means for a reason that has
nothing to do with derivation. Fixtures: `dispatch/PrivateEqStillDerives`, and in `blackbox_test`
"a private eq wins inside its module and still lets every other module derive" and "core/Basics
carries the derived rows §3.2's table asks it for".

**A.64 — `Target.top` and `Target.ext` carry a `parts` range, EMPTY at a call site** (§7.1, §7.3,
§8.2) [S6a]. A constrained value named from inside a `parts` tree has nowhere to put its own
evidence: §7.2 numbers evidence slots against an INSTRUCTION, and a part position has none.
`{ p : { x : Int }, q : List Int } == …` wrote `part 1 ext List eq` with nothing under it, and once
§5.2 gave `List` a `pub foreign eq … where a.eq` the emitted call to `List$eq` was one argument
short — which JavaScript runs, binding `undefined`. The range is filled by the same rule
`nominalTarget` uses: one target per constraint the named value's scheme puts on a type parameter,
in the canonical order of §7.2, which for a method of `T a1 … an` is the application's own argument
order because the scheme's body meets the parameters there. *Why not extend the SITE list instead:*
a site is keyed on `(inst, evidence_index)` and a part has no instruction, so the flat list would
need a second numbering space; the tree already nests. *Limit, deliberate:* a scheme whose
quantifier count does not match the type's arity — a `where` clause over a variable the receiver
does not supply — gets no parts, and the backend refuses the call rather than pass evidence for the
wrong parameter. Fixtures: `dispatch/ExtWithParts`, `run/ConstrainedPartEvidence`,
`run/ListElementEq`, and in `blackbox_test` "a constrained value in a part position is handed its
own evidence".

**A.65 — the intermediate `Order` of a lexicographic body is numbered per FUNCTION, not per block**
(§9.2, §9.3, §9.4) [S6a]. §9's listings write `const o0` in each `switch` arm and brace the arms;
the printer gives a `switch` arm no braces (`js/Print.zig`'s `switch_case`), so two arms of one
`switch` are one block scope in JavaScript and `const $o$0` in each is
`SyntaxError: Identifier '$o$0' has already been declared` — after a build that exited 0. A counter
the whole arrow shares gives `$o$0`, `$o$1`, … across arms and needs no braces. *Alternative:*
teach the printer to brace a `switch` arm whose body declares anything, which is a change to
`backend.md` §7's shape for one caller's benefit. Fixtures: `emit/DerivedCompareNominal`,
`run/DerivedOrdering`.

**A.66 — an evidence slot whose receiver type nothing ever determines is answered by the A.53
bridge** (§6.4, §7.2, §8.2) [S6a]. `[] == []` is the whole of it. Once `List` declares
`pub foreign eq … where a.eq`, §7.2 numbers a site for the element's `eq` — and the element type of
two empty lists is a variable no use constrains, so the constraint is neither DISCHARGED, there
being no type to discharge it against, nor PROMOTED, the declaration's own type not mentioning it.
The site stayed empty and the emitted call was one argument short. `Solve.settleUndetermined` runs
after `promote`, because "generalisation did not quantify it" is not knowable before then — the
RANK cannot say it, since `generalize` marks every young variable `generalized` whether or not the
declaration's type mentions it — and gives the slot `core/Basics.js`'s structural `eq` for `eq` and
§9.1's comparator for `compare`. It is answerable BECAUSE the type is undetermined: the function
handed over can only be called on a value of that type, and no such value exists in any execution
that gets there. *Alternative:* report the program as ambiguous, which would reject `[] == []`.
*Not done for a name that is not well known:* a user's own `where` clause on an undetermined
receiver gets nothing, because inventing a function for it would be inventing a meaning. Fixtures:
`run/ListElementEq` (the `[] == []` line), `dispatch/ErrParts`. **It gets a MESSAGE, though** [S6b]:
"nothing" was a silent `null`, so `pub eq : Box a, Box a -> Bool where a.describe : a, Int -> String`
applied at `Box 1 2` checked clean and emitted a call one argument short, and the only wall left was
`Lower.evidenceShapeOk`'s `internal` — a compiler bug reported about a program whose only fault is
that it never says which type it means. It is now §10.1's undetermined-receiver arm. Fixture:
`check/bad/WhereNonWellKnownAtLiteral`.

**A.67 — an `err` part is answered by KIND, and `compare` has no structural walk to fall back on**
(§9, A.51, A.53, A.59) [S6a]. `err` means a position nothing ever inhabits, and S5 answered one
with `Basics.eq` everywhere — a `Bool` where a `compare` body promised an `Order`, and a function
of the wrong result type in an evidence slot. Inside a `compare` body an `err` position is the
string `"EQ"`, which is what leaves a lexicographic sequence reading the position after it; in
value position it is §9.1's `compare$prim`, a total function of two arguments returning an `Order`.
The second half is the asymmetry that follows: a `derived`/`ext_derived` `eq` with no body may fall
back on `core/Basics.js`'s one structural walk when every part says the walk would answer the same
thing (A.51's door), and a `compare` may not, because core has no function that ORDERS
structurally. So the `compare` arm refuses outright. Fixture: `run/DerivedOrdering`'s `Outcome`
lines, whose `x` slot is an `err` the program never reaches.

**A.68 — one instruction's evidence slots are numbered by a running cursor, never restarted**
(§7.2, §7.3) [S6a]. A nested instantiation used to begin again at a hard-coded 1, so
`[ [ [ Box "a" "b" ] ] ] == …` wrote five `site N 1` rows on one instruction. The EMISSION was
right: `Lower.evidenceArguments` walks the sorted list as a pre-order tree and reads no index but
the callee's 0, and the sort is stable over an insertion order that happened to be pre-order. What
was wrong is the KEY. `Solve.joinConstraint` and `Solve.appendSite` both deduplicate on
`(inst, evidence_index)` — the first when two constraints of one name meet on a variable, the
second when a mutually recursive group forwards its shared constraint — so either could have
dropped a DIFFERENT slot's site as a repeat of this one and emitted a call an argument short.
`Schemes.Site` therefore carries the instruction's cursor rather than a base, and
`Solve.evidence_next` owns one per instruction. *Why record it:* the defect was invisible in every
`run/` and `emit/` golden and pre-existing on `cb63a46`; what made it worth fixing now is that
§5.2's `pub foreign eq … where a.eq` on `List` made it reachable from every list equality with a
constrained element, which is most of them. *Owed, and NOT fixed here:* the numbering is a running
cursor and therefore ALLOCATION order, which is breadth-first — an instruction with two top-level
slots that each nest, `pair [ [ 1 ] ] [ [ 2 ] ]` under
`pair : a, b -> Bool where a.eq : a, a -> Bool, b.eq : b, b -> Bool`, numbers `a`'s children after
`b` instead of between `a` and `b`, and the pre-order walk then reads them as `a`'s grandchildren.
Distinct indices make that visible in `--stage=dispatch` where the repeated `1`s hid it; the fix is
a depth-first discharge, which is a change to the obligation drain and not to the numbering.
Fixture: `dispatch/NestedEvidenceIndices`. **Now fixed, and not by the drain** [S6b]: the drain is
pre-order where it counts — each site records its PARENT slot and `Dispatch.finish` orders one
instruction's run by the path from its root, so the flat list is the pre-order §8.2 reads however
the cursor numbered it (§7.1, §7.2). A depth-first discharge would NOT have been enough on its own,
which is what reading the repro's dump showed: `pair`'s two slots are numbered `0` and `1` by ONE
instantiation, before either is discharged, so `a`'s child is `2` whatever order the drain then
runs in and the ascending list still reads `b` as `a`'s child. Ordering by the parent is
independent of the drain, needs no change to the numbering the two deduplicating tables key on, and
is deterministic by construction — the paths are a function of the site list alone. What it does
cost is that the dump's index column is no longer ascending; §7.3 says so, and that is the
breadth-first numbering made visible rather than hidden. The wrong program was silent: `pair [ [ 1 ] ]
[ [ 2 ] ]` emitted a four-deep `List$eq` for `a` and a bare `===` for `b`, exit 0, and the answers
came out `False` where the language says `True` — or, where a slot's evidence was applied to a
number, `TypeError: Cannot read properties of undefined` from inside `core/List.js`. Fixtures:
`dispatch/TwoSlotsNested`, `run/TwoSlotsNested`.

**A.69 — `List`'s `compare` is a hand-written loop in `core/List.js`, and its sibling takes
evidence count + declared arity** (§5.2, §9.5) [S6b]. *Why:* `List a` is a `foreign type` with no
constructors, so there is nothing to derive a body from, and the shape of a cons cell is the
emitter's. The loop rather than recursion is `foldr`'s reason: a list long enough to be interesting
is longer than the JavaScript stack. *The risk this row stated because nothing checked it* — the
export is written `(m0, xs, ys)`, and a forgotten leading parameter used to compile and then compare
a function against a list — **is checked since 2026-09-18** (`boundary.md` §4 check 4, A.84).
`tests/corpus/run/ListOrdering.beni` still catches it at run time, as `run/ListElementEq.beni` does
for `eq`, and the build now refuses it first. *Alternative rejected:* deriving `compare` for `List` from a synthetic two-constructor shape,
which would put the emitter's cons-cell layout into the checker's table.

**A.70 — `Dict.empty` is a constant and `Dict.singleton` is unconstrained** (§5.3, O-1) [S6b].
*Why:* neither compares anything, so neither raises `k.compare`, and §6.4's `constrained_constant`
— which is what the plan's `Dict.empty : () -> Dict k v` was a precaution against — never applies.
The same holds for `Set.empty` and `Set.singleton`. *What it buys:* `Dict.empty` reads as a value
in a `foldl` seed, which is where the corpus uses it eight times over.

**A.71 — `Dict`'s private helpers keep their annotations and spell the `where` clause out**
(§5.3, O-3) [S6b]. `getHelp`, `insertHelp`, `removeHelp` and `removeHelpEQGT` could have dropped
their annotations and let the constraint arrive by inference, as §5.3's prose suggests. They keep
them. *Why:* `removeHelp` and `removeHelpEQGT` are mutually recursive and both constrained, which
is the case `run/ConstrainedMutualRecursion.beni` exists for — an inferred `where` on a binding
group is the least-tested path in §6.4, and core is not where to exercise it. A written clause is
also what a reader needs: the four helpers are where the comparator argument used to be threaded,
and the clause is what replaced it.

**A.72 — the backend's derived-method refusals and A.51's bridge are deleted** (§8, O-8) [S6b].
`Lower.refuseDerived`, `Lower.structuralEq` and their two `not_implemented` messages are gone, and
every site that called them reports `internal` with one message instead. *Why:* both existed for a
derived target no module writes a function for, and after §5.2 there is none. Every shape §9
describes has a body for both methods; `List a` has its own `pub foreign eq` and `pub foreign
compare`; and `equatable` — the marker that let a `foreign type` answer `eq` without one — is
core's alone (`language.md` §3), so core was the only place that could declare such a type and core
no longer does. *What went with it:* the recursive test of whether `core/Basics.js`'s structural
walk happens to agree with the table, which was the subtlest code in the file and which existed
only to decide that question. The one position still answered by that walk is `partEq`'s `err` arm,
the slot nothing ever inhabits (A.66), and the `--core-root` scenario in `blackbox_test.zig` reaches
it through `None == None` now rather than through a list.

**A.73 — the nested-module build assertion moved into the test's own world** (O-12) [S6b].
`build_test.zig` asserted `out/core/Dict/Int.mjs` to prove that a module in a subdirectory comes out
in a subdirectory of `out/`; §5.7 deletes that module. *Why a new test rather than a new path in the
old one:* the claim is about the emitter and not about core, and the old assertion never had a
subject — nothing in the project imported `Dict.Int`, so it proved only that core was copied out
whole. The replacement builds `src/Util/Math.beni` and `src/Main.beni` with `--root=src src`,
imports ACROSS the subdirectory boundary, and asserts both the output path and the relative
specifier the importer reaches it by. `build.zig`'s comment about why embedded core paths keep their
subdirectories is left standing and made hypothetical: the mechanism outlives the modules that used
it.

**A.74 — `Dict` and `Set` get no `eq` and no `compare` of their own** (§11, O-5) [S6b]. *Why:* a
`pub eq` comparing `toList` would be correct and is two lines, but it is a change to what the
language's standard library promises rather than to static dispatch, and the spike is measuring the
latter. The derived answer — a walk of the red-black tree, insertion order and all — is left in
place and printed by `tests/corpus/run/DictStructuralEquality.beni`, so the adoption decision is
made against a number rather than against a guess. §11 carries the row and report 19 is where it
goes.

**A.75 — a rebuilt constraint set REDIRECTS the indices it superseded** (§6.2, §6.3, A.57) [S6b].
A set is a half-open range of an append-only table and is never edited (§6.1 invariant 2), so Rule
U1's union, an attach that joins two constraints of one name, and an extend that cannot append in
place all COPY their inputs onto a fresh range. Everything that answers a constraint is keyed on
its INDEX — the obligation's own `index`, `resolved_methods`, `deferred` — so a copy left its input
behind as a live obligation over the same sites, and "answered exactly once" was answered twice:
`put (put (Box "z") "a") "b"` wrote `site 46 0` and `site 48 0` twice each, and
`Lower.evidenceShapeOk` then refused the call as `internal` — a compiler bug reported about a
program whose only fault is that it nests. `Solve.superseded` maps each superseded index to the
constraint that took its place; `dischargeMethod` and `settleUndetermined` follow it BEFORE they
read or mark anything; and it is journalled by length exactly as `resolved_methods` is, so a
`tryShape` probe that joins and then rolls back leaves no redirect pointing at an index the
rollback has already handed to something else (A.35). *Two halves of it are not obvious.* The
ANSWER is carried across as well as the obligation: a replacement whose every input was already
answered is marked answered itself, and `joinConstraint` drops the sites of an input that was,
so a join of an answered constraint with an unanswered one answers the second alone. And a COPY is
as dangerous as a join — `put`'s `k.compare` and `tag`'s `k.eq` are different names on different
variables, so nothing is joined, and the union that copies both onto one range stranded both
inputs just the same. *Alternative rejected:* collapsing duplicate rows at `emitSites` or in
`Dispatch.finish`, which hides a disagreement as readily as a repetition — the same alternative
A.57 rejected and the same dedup S3 removed. *One more defect it closed:* the obligation a `method`
node registers named `lastConstraintIndex`, the last constraint of the rebuilt SET, which is the
one just attached only when its name happens to sort last; `attachConstraint` now returns the index
its constraint's sites live at and the obligation names that. Fixtures:
`dispatch/JoinedConstraintSites`, `run/NestedConstrainedCalls`, and `run/Dictionaries`, which is
where it was found. *Two corners of the journalling, added on review:* the journal records the
PREVIOUS value and not only the key, because a key a second rebuild re-points inside a probe was
already pointing somewhere before it and removing it would lose a redirect the probe never made;
and `detachConstraint` redirects what it KEEPS, because dropping one constraint rebuilds the set
and copies the others exactly as a join does.

**A.76 — a resolution instantiates the callee's `where` clause once per INSTRUCTION the constraint
answers** (§6.3.1, §7.2, A.68, A.75) [S6b]. `methodOnApp`'s two instantiating arms — the module
rule's `top` and the interface's `ext` — used to take the single `origin` the obligation was
registered at and number one set of evidence slots against it. That was right while a constraint
answered one instruction, and A.75 is exactly the change that made one constraint answer several:
Rule U1 joins the two calls of `size (put (put seed [ 1, 2 ]) [ 3 ])` onto one `k.compare` whose
sites are on both instructions, and `List.compare` has a `where a.compare` of its own whose slot is
numbered by a cursor the INSTRUCTION owns (§7.2). One instantiation therefore gave one instruction
a nested slot and left the other an argument short — `site 73 0 ext List compare` with no
`site 73 1` — and `Lower.evidenceShapeOk` refused the build as `internal`: a compiler bug reported
about a program whose only fault is that it nests twice over a constrained element. The loop runs
in SITE order, so the numbering is a function of the input and not of the drain (`fast-compiler.md`
§10), and the copies it makes unify with one another through the constraint's own `fn_var`, which
is what lets their nested constraints join and answer both instructions at once. *Why not carry a
list of origins into `tagInstantiated` instead:* the slots of one instruction are numbered by that
instruction's cursor and parented on that instruction's slot, so there is nothing shared between
two origins to hoist — the loop IS the shared part. *An annotation hides it*, which is why the
fixture carries `annotatedDict` beside `nestedDict`: pinning `k` discharges each constraint before
any join happens. Fixtures: `dispatch/JoinedConstraintNested`, `run/NestedConstrainedListKeys`.

**A.77 — the A.53 bridge is tested BEFORE §10.8, so a `number` variable dispatches with no `where`
clause** (§4.1, §6.3, §8.4, A.53) [S7]. The rigid arm of `resolveMethod` runs `findConstraint`,
then `builtinRigidTarget`, then the `.type_dispatch` check, so `pub sameNum : number, number ->
Bool` with body `number.eq x y` and no clause at all resolves to `primitive strict_eq` and
`evidence=0` — it does **not** take §4.1's third table row to `type_dispatch_needs_annotation`.
*Why leave it:* the answer is right. `number` is `Int` or `Float`, §3.2 gives both `===`, and
refusing the program would mean asking for a `where` clause whose only possible content is the
answer the compiler already has. It is also not a case anyone writes on purpose — `x == y` is the
spelling — so the order is worth a row rather than a code change. *What it costs:* §4.1's table is
not the whole rule for the two well-known names on a `number` (or flagged-`equatable`) rigid, and a
reader who trusts the table alone will predict an error that does not come. *Alternative:* move the
`.type_dispatch` test above `builtinRigidTarget`, which makes the table total and rejects a correct
program to do it. Fixtures: `run/DecodeInto`'s `sameNum` line and `dispatch/DecodeInto`, which shows
the `primitive strict_eq` site beside the `evidence 0` ones.

**A.78 — `run/` is single-file, so `run/DecodeInto`'s second dispatch target is a core type** (§4,
§11, §7.3) [S7]. The corpus walker gives projects to `check/good`, `check/bad` and `dispatch` only
(`Kind.hasProjects`), and §11's module rule forbids two types in one module from both declaring a
`fromList`, so a single-file fixture cannot hold two user targets for one method. The second target
is `core/String.beni`'s `fromList : List Char -> String`, against the fixture's own
`fromList : List Char -> Tag`. *Why it matters that there are two:* with one target the whole of §4
is a rename — the emitted code would be correct however the checker resolved the site — and the
fixture would assert nothing. *Alternative:* teach `run/` projects, which is a harness change with
no dispatch content, or split the second target into a `dispatch/` project and lose the EXECUTION
of the second arm. `dispatch/DecodeIntoAcrossModules` is that project, and it is a complement rather
than a replacement: it sees the interface round trip, it does not see the answer come out.

**A.79 — `typeDispatchExpr` keeps five arms no beni program can reach** (§8.4, §6.7) [S7]. The
constraint root of a `type_dispatch` is always a rigid, so the solver can only ever hand it
`evidence k`, a `primitive` (A.77) or `err`; the lowerer nevertheless has `top`, `ext`, `derived`,
`ext_derived` and `field` as well. S7 read them rather than exercising them, because there is no
program that gets there — the only way in is a table that disagrees with the solver. *Why keep
them:* `top` and `ext` are free, on the same path as `evidence`; `field` is a wall that names the
bug (`field_without_receiver`) where a narrowed `switch` would have to crash without a region; and
`derived`/`ext_derived` carry a real lowering, §8.3's with the receiver removed and the use's
evidence taken off the target's own `parts` (A.46), which is worth having written down beside the
`method_call` case it mirrors rather than reconstructed later from memory. *Alternative:* delete
them and make the `switch` exhaustive over a narrower `Target`, which means a second `Target` type
for one instruction — the cost §7.1 already refused for `Derived`. *Recorded, not fixtured:* the
spike's rule is that every defect gets a fixture, and this is the complement — a reading that says
why an absence of fixtures is correct.

**A.80 — the `.any` arm of §10.1's undetermined-receiver message belongs to return-position
dispatch** (§10.1, §6.4, A.66) [S7]. `undeterminedMethodReceiver` names the receiver's flex `kind`,
and the three arms have very different reach: `.number` is a literal (`WhereNonWellKnownAtLiteral`),
`.appendable` is a `String`-or-`List`, and `.any` is "a type variable no use of this value
determines" — which an ARGUMENT-position constraint can hardly produce, because passing a value is
usually what determines it. A constraint on the RESULT is the natural producer: nothing inside the
declaration can pin it and only a caller can, so a caller that throws the result away leaves it
unpinned. The fixture has to keep the constraint off the caller's own interface as well —
`ignored : Int` does not mention `a`, so `promote` does not claim it and `settleUndetermined` is
what is left to answer. *Why it is an error and not an invented answer:* A.66's line — `eq` and
`compare` mean the same thing at every type and the bridge answers them, a user's method does not.
Fixture: `check/bad/TypeDispatchUnpinnedResult`.

**A.81 — folding a constraint back onto the set it is already in costs nothing** (§6.3, §7 M2,
A.57, A.75) [S8-fix]. §6.3's `flex` row ends every method obligation whose receiver is still a
variable by re-attaching its constraint to that variable, and `attachConstraint` saw a name its set
already carried and took the JOIN path: the whole set copied onto a fresh range, `joinConstraint`
merging a site list with itself, and `adopt` redirecting every index to the copy of itself. The
result of all of it is the set it started from. That is O(set) per obligation, and the unannotated
chain of §7 M2 is the input built to walk into it — link k defers k constraints over a set of k, so
`beni check` was **cubic in the chain's length in time and in memory**: 51 ms / 53 MB at n = 100,
382 ms / 403 MB at n = 200, 3 114 ms / 3 307 MB at n = 400, and at n = 1000 a process killed at
29.2 GiB with no diagnostic where `master`'s checker does the same 3 008 lines in 0.25 s. The guard
is three comparisons at the top of `attachConstraint` — the caller's index lies inside the root's
current range and carries `c`'s name — and it returns that index untouched. *Why the quadratic
UNDER it is not a defect:* link k of an unannotated chain genuinely accumulates k constraints, so
the chain carries n(n+1)/2 of them and `constraints_promoted` has read n(n+1)/2 since S3; the fix
takes n = 1000 from killed to 440 ms and n = 2000 to 1.96 s, which is at or under the S3 row
(483 ms and 2 061 ms) for the first time. *Where the bisect points and why it is not the whole
story:* `git bisect` lands on S6b (`5dfc082`) because A.75's redirect map made each of those futile
rebuilds ~3.3x more expensive, but the same three n at `8081b5f` — the commit before it — read
21 / 132 / 935 ms, which is already cubic. **S6b multiplied the constant; it did not introduce the
exponent**, and A.75 is not the cause and is not weakened: nothing moves, so nothing needs
redirecting, and the `answered` bookkeeping `adopt` carries across a rebuild is carried across
nothing. A.76 is untouched — the loop it added is in `methodOnApp`, which a chain never reaches
(`constraints_discharged` is 0 on this input). *The counters say it and a clock does not:*
`constraints_merged` counts set rebuilds and was n(n+1)/2 + n - 1 on the chain, against n - 1 after
the fix, while `obligations`, `constraints_deferred` and `constraints_promoted` are unchanged to the
unit at every n — which is the assertion that no obligation was dropped to buy the speed (A.57).
Fixture: the `abuse_test.zig` scenario "an unannotated constraint chain costs one merge per link,
not one per constraint", which reads those counters back out of `--self-profile` at 64 links and
128 and pins all six.

**A.82 — the spike is adopted whole, and this document is promoted in place** (front matter, §0)
[L1, 2026-09-18]. After [`research/19-static-dispatch-spike-results.md`](research/19-static-dispatch-spike-results.md),
the owner took §15 option (b) — the whole feature — on three grounds: `where` is the extension point
library authors need (codecs, UI, user containers); the code is already written, reviewed and
measured; and pre-1.0 it can still be withdrawn. `master` had not moved since the branch was cut, so
the code landed by fast-forward and only the documents needed work. *Why promote this file rather
than re-slice it into the four phase contracts:* it is larger than `frontend.md`, `checker.md`,
`backend.md` and `boundary.md` together, and ~100 files cite it by name and by its own `§N` / `A.N`
numbers, which CLAUDE.md rule 2 protects. So it keeps its file name, its title's subject and every
section number, and the other documents gain pointers. What changed elsewhere:

| Document | What |
|---|---|
| [`fast-compiler.md`](fast-compiler.md) | §3.1's *Decision* points 3 and 4 marked **superseded** in place with the evidence (report 19 §6, §9, §15) and the replacement (§3, §5 here); points 1, 2 and 5 restated as standing; *Decision: no static dispatch* reopened and closed the other way; §3 and §3.2's derived claims corrected; §8.1 gains the inferred-`where`-suffix consequence; §13 records where the adoption landed in M3 |
| [`language.md`](language.md) | §0 gains four departures (dot-call, `where`, well-known `eq`/`compare`, return-type dispatch) and its `comparable` row is corrected; pointer paragraphs at §3, §4, §5.4, §6.2, §6.3, §6.5, §8, §9, §10 and Appendix A |
| [`checker.md`](checker.md) | pointers at §1, §2, §3, §5, §6.1–§6.4, §7, §8.1; Appendix B's `Basics`, `List`, `String`, `Char`, `Dict` and `Set` rows brought in line with `core/` |
| [`backend.md`](backend.md) | pointers at §3, §4, §5, §6; §6's "a function-typed value in flight is always a closure of known arity" recorded as extended by §8.2 here |
| [`boundary.md`](boundary.md) | §4 carries the `foreign` + `where` arity rule as **check 4**, enforced since 2026-09-18 with the accepted export forms and the refused ones (A.84); it was recorded there as documented-and-not-enforced and as an owed item until then |
| [`frontend.md`](frontend.md) | §1, §1.2, §2 and §8 pointers: the `where` tail, the two new BIR tags, the formatter rule, the new dump stages |
| CLAUDE.md | the language bullet, the M3 status, rule 1's contract list, and an "Owed after the static-dispatch adoption" list (report 19 §14 items 1–5) |

*Alternative:* the re-slice report 19 §14 describes — folding §1–§10 into the four contracts without
renumbering. It is the tidier end state and it was declined here because the citation surface makes
it a mechanical rewrite of ~100 files for no change in what any document says. It stays available:
nothing in this document depends on living in one file.

**A.83 — the inferred-interface warning is on by default, and an inferred set is capped at 64**
(§6.4, §10 preamble, §10.9, new §10.11, §11) [queue slice 3, 2026-09-18]. Report 19 §14 items 4 and
5 left two questions open — nothing bounds what one unannotated declaration writes into its
interface (a 6.4 kB entry is reachable, §3.1), and nothing takes a position on the n² obligation
count of an unannotated chain (§3). **Manager decisions of 2026-09-18**, taken on the owner's behalf
while he was offline, and reversible by editing this row:

| | Decision | Why | *Alternative* |
|---|---|---|---|
| 1 | `ambiguous_method_receiver` is emitted **by default** by `check` and `build`. It stays a `warning` and still cannot change the exit code | the whole point of the warning is that the author learns when a body edit made the interface churnable (report 19 §4); a warning nobody runs the flag for is not a mitigation | leave it behind `--explain`, and accept that it warns nobody by default |
| 1b | `--explain` is **kept, accepted, and governs nothing**. It was the only diagnostic the flag ever controlled | removing a flag breaks any invocation that passes it, and the flag is the natural home for the next informational diagnostic | delete the flag, at the cost of a new usage error in anything scripted against it |
| 2 | the warning fires **only for modules of the root package** (`SourceStore.Package.app`) | `core/` is embedded and a platform package is a dependency: a user cannot annotate `Dict.foldl`, so a warning about it is noise they cannot act on. Measured at the time of the change: `core/` and `platforms/` together would have produced **0** warnings — every `pub` declaration in both is annotated — so the restriction changes no output today and is implemented for the dependency packages M4 brings | warn everywhere, and have the first `pub` declaration anybody leaves unannotated in a library spray the warning across every consumer |
| 3 | an unannotated declaration whose inferred scheme would carry **more than 64** method constraints is `too_many_inferred_constraints`, an **error**, `pub` or not; an annotated one may carry any number | it answers both owed items with one rule: the promoted suffix is bounded, and the quadratic is bounded with it. 64 because pre-dispatch `master` already refused the same chain at ≈64 links (report 19 `results:152-167`), so **no program that checked before the adoption is newly refused** | a `warning` instead of an error (bounds nothing — the interface is still written), or a much larger cap (bounds the interface but not the n²), or no cap and a documented limit |
| 3b | the capped declaration **promotes nothing**: constraints dropped, no evidence list, no sites, root type untouched | an error has to recover the way the rest of `Solve.zig` recovers, and this recovery is what stops the accumulation reaching the next link. Measured: ⌊n/65⌋ errors, linear time and memory, 46 errors / 0.39 s / 91 MB at n = 3000 against 4.44 s / 3 754 MB before (§10.11) | poison the declaration's root type to `err` instead, which gives one diagnostic for the whole chain and hides every unrelated error downstream of it |

Three consequences worth stating. **`tests/blackbox/abuse_test.zig`'s A.81 scenario moves from 64
and 128 links to 32 and 64**, because 128 now hits the cap; it still pins all six counters and still
fails without A.81's guard. **`bench/gen.zig --pathological=constraint-chain` is unchanged** and now
reports diagnostics past 64 links, which is what C0 did and what the 64 was chosen to match.
**`check/good` corpus fixtures may now carry a `.diag` golden**: a good fixture is one that exits 0,
and a `warning` is legitimate output, so the walker compares warnings against a golden instead of
requiring silence.

**And one latent defect in `beni build` had to be fixed to land it.** `build` renders diagnostics in
two waves — the check's, and the emit phase's, which runs after `Session.run` has returned because
it must not run at all when the check failed. Two renders are two JSON arrays on one stream, which
is not the format (`frontend.md` §1.1), and `build` guarded that with
`assert(session.diagnostics.items.len == 0)` plus a comment saying *"the moment a warning exists,
this has to become one collected list rendered once"*. This is that moment: `build` now runs with
`Session.Options.defer_render`, `run` collects and renders nothing, and `renderLate` sorts both
waves into one array. Without it, `beni build` **panicked** on a program whose only faults were a
missing `main` and an unannotated `pub` declaration — reachable under `--explain` since the
adoption, and unconditionally after it. Fixture: the `blackbox_test.zig` scenario "a build that
warns and then fails in the emit phase prints one diagnostics array, not two".

**A.84 — the `foreign` + `where` arity rule becomes `boundary.md` §4's check 4** (§5.2, §11, A.7)
[queue slice 4, 2026-09-18]. Report 19 §14 item 2 left the rule of §5.2 documented and unenforced:
a sibling whose `eq` forgot its leading evidence parameter built cleanly, exited 0, and compared
the evidence function against a list at run time. A.7 named two alternatives, both unattractive —
withdraw `where` on `foreign`, or write an arity check that "needs a JavaScript parser to do
properly, the dependency the wall exists to avoid". **Decision: neither. The check lands, and it
counts rather than parses.**

| | Decision | Why | *Alternative* |
|---|---|---|---|
| 1 | every `foreign` is checked, not only a constrained one: the export's parameter count must equal **evidence count + declared arity** | a plain arity mismatch is the same defect class and the same exit-0 wrongness. `foreign say : String, String -> Program` bound to `(line)` built, ran, and dropped its second argument silently; there is no reason to catch one and not the other | check only the declarations that carry a `where` clause, which would leave the larger and older hole open |
| 2 | a `foreign` whose type is **not** a function must export a value, not a `() => …` | the other half of the same rule, and it is reachable: `foreign tau : Float` bound to `() => 6.28…` built and printed the function's own source text | say nothing about non-functions, and let a constant that is secretly a thunk through |
| 3 | the parameter list must be written **at the export**. `export const f = g;` and a re-exported import are refused, because neither says how many parameters `f` has | this is what lets the check be a count instead of a parse, and it is the restriction CLAUDE.md rule 6 asks for rather than forbids: a sibling is privileged first-party code, so a rule about how it spells an export costs a platform author one line — `export const f = (a, b) => g(a, b);` — and buys a check that cannot be fooled. Nothing in `core/` or `platforms/node` uses the refused form | accept it as "arity unknown" and wave it through, which reopens the hole for exactly the files most likely to be written carelessly |
| 4 | a **rest parameter** is refused for the same reason; a destructuring or defaulted parameter is one POSITION and is counted | `(...args)` has no fixed count, so there is nothing to compare. A destructured or defaulted parameter does have a position, and the emitted call fills positions | count `(...args)` as its fixed prefix, which is a guess the call site does not share |
| 5 | the diagnostic is one new code, `foreign_arity_mismatch`, appended to the catalogue, and it points at the beni DECLARATION | `foreign_export_mismatch` is already one code with two messages for the same reason: the code names the rule, the message names the case. The declaration is where the expected count is written down, and a sibling has no beni span | a code per case, which multiplies the catalogue for no reader's benefit |

**Where it lives.** Split, like check 1: `src/js/Sibling.zig` counts what each export is WRITTEN
with (a `Sibling.Arity` of `function n`, `opaque_value` or `uncountable`) because that is the file
that reads JavaScript, and `src/js/Emit.zig`'s `checkArity` compares it against evidence count +
declared arity, because only the `Bir` annotation and `Dispatch.declEvidence` know the second
number. The arity table is the one place the scanner tracks brace depth — a `const eq` inside a body
must not answer for the `eq` the module exports — and that is a deliberate exception to the header's
"not a scope analysis", cheap because it is one counter.

**Every sibling in the repository passed unchanged**: five in `core/` and one in `platforms/node`,
65 foreign values, including `List.eq` and `List.compare` with their evidence parameter. No `.js`
file was edited to land this.
