# Beni language specification — surface syntax (M1 scope)

**Status:** normative for M1 — what the lexer, parser, formatter and BIR lowering implement, and
what the corpus tests assert. Decisions are taken from [`fast-compiler.md`](fast-compiler.md) §3,
§3.1, §3.2; where this document is more specific, this one wins for the front end. Semantics (types,
evaluation) are out of scope until M2/M3: this is the grammar, the lexical structure, and the
per-file name-resolution rules that a single file's text fully determines.

The language is Elm 0.19 with the changes listed in §0. A reader who knows Elm needs only §0 and the
indentation rules in §4.

## 0. Differences from Elm, in one place

**No automatic currying.** Decided 2026-09-14, specified here 2026-09-15: every call is saturated,
function types are n-ary and written `Int, Int -> Int`, `_` is the partial-application placeholder,
`|>` is pipe-first syntax, `>>` and `<<` are removed, and `let x <- e` binds the rest of the block.
The decision and its evidence are in [`fast-compiler.md`](fast-compiler.md) §9.3; the rules are
normative here, in §3, §6.5, §6.7, §8 and §9.

**Static dispatch.** Decided 2026-09-18, after a spike that built it and measured it
([`research/19-static-dispatch-spike-results.md`](research/19-static-dispatch-spike-results.md)).
A type's **methods** are the `pub` values of the module that declares it; `x.m a b` calls one;
a top-level annotation may carry a `where` clause constraining a type variable's methods; and the
six comparison operators are calls of the receiver type's `eq` or `compare`, which the compiler
derives where it can. The contract is [`static-dispatch-spike.md`](static-dispatch-spike.md) — the
file name is historical, the document is normative — and the sections below point into it where it
extends them. It reverses two decisions of [`fast-compiler.md`](fast-compiler.md) §3.1, which
records the reversal in place.

**Layout record declarations.** Adopted 2026-09-22: a record `type alias` body
and a `schema` body accept aligned fields without braces or commas, and tagged
schema variants accept aligned heads with indented payload fields. Both spellings
parse to the same nodes; the formatter always emits layout for nonempty closed
declaration record bodies. Inline types, extensible and empty records, ordinary
`type` declarations and record values keep their existing forms (§3–§4, §9;
[`schema.md`](schema.md) §2/A.5).

**Markup (JSX).** Specified 2026-09-29, not built: `<div class="a">{name}</div>` is an expression of
the platform's markup type, with bare text, typed holes, capitalised components, a `For` list form
and a keyed `Show`, typed against an element vocabulary a platform package declares — the language
knows no HTML vocabulary, only the character references JSX text decodes (§11). With it comes the
promise that a record update keeps the identity of every field it does not name (§11.12).

| Elm | Beni | Where |
|---|---|---|
| `module Foo exposing (..)` header | none; module name from path; `pub` per declaration | §5.1 |
| `import M exposing (T(..))` | `exposing (T, Ctor1, Ctor2)` — constructors listed by name, no wildcard | §5.2 |
| `{- -}` block comments, `{-\| -}` docs | none; `--` comment, `--\|` doc, `--!` module doc | §2.3 |
| `"""…"""` multiline strings | Zig-style `\\` line-prefixed raw strings | §2.7 |
| `"a" ++ String.fromInt n` | `"a ${n}"` interpolation, primitives only | §2.6 |
| `Result.andThen` pyramids | `expr?` postfix, desugared to `case` | §6.6 |
| — which to reach for | `?` for `Result` and `Maybe`; `<-` for everything else that takes a callback last | §6.6, §6.7 |
| `Tuple.first`, arity ≤ 3 | `t.0`, `t.1`, any arity ≥ 2 | §6.4 |
| user-defined operators, `infix` | fixed operator set, fixed fixities | §6.5 |
| shadowing is an error | same | §7 |
| `comparable`, `<` on strings | `comparable` is gone as a *mechanism*, but `<` accepts anything whose type has a `compare`, `"a" < "b"` included | §6.5, spec §3 |
| `x.m a` is a field access applied | `x.m a` is a **method call** on `x`'s type; `(x.m) a` opts out | §6.3, spec §1 |
| no way to constrain a type variable | `where a.compare : a, a -> Order` on a top-level annotation | §3, spec §2 |
| `==` and `<` are `Basics.eq`/`Basics.lt` calls | they are calls of the receiver type's `eq` / `compare`, derived when the type declares none | §6.5, §8, spec §3 |
| type classes name methods globally | a type's methods are the `pub` values of the module declaring it — the **module rule** | spec §1.2 |
| — | `a.decode s` dispatches on the *return* type, inside an annotated declaration | §6.2, spec §4 |
| tabs | syntax error everywhere | §2.1 |
| Kernel modules | `foreign` declarations, core root only | §5.4 |
| `a -> b -> c` curried, partial application everywhere | `a, b -> c` n-ary; every call saturated | §3, §6.7 |
| partial application by leaving arguments off | `f a _` placeholder, at most one per call | §3, §6.7 |
| `x \|> f` an ordinary operator | `\|>` is syntax: `e \|> f a` is `f e a`, subject first | §6.5, §6.7 |
| `f >> g`, `f << g` composition | removed; name the argument | §6.5 |
| `andThen` pyramids in a `let` | `let x <- f a` binds the rest of the block | §3, §6.7 |
| `div [ class "a" ] [ text name ]` | `<div class="a">{name}</div>`, typed against a platform's vocabulary; an untouched record field keeps its identity | §11 |

Everything else — application by juxtaposition, `\x ->` lambdas, `case … of`, `let … in`,
`if … then … else`, records, record update, lists, tuples, type aliases, custom types, `as`
patterns, `::` patterns, `.field` accessors — is Elm's.

## 1. Files and modules

| Rule | Detail |
|---|---|
| the file | extension `.beni`, UTF-8. A byte sequence that is not valid UTF-8 is `invalid_utf8` at the first offending byte; lexing continues from the next valid boundary. |
| the module name | one file is one module, named by its path relative to the source root with `/` replaced by `.` and the extension dropped: `src/Json/Decode.beni` is `Json.Decode`. Each segment must be a valid upper identifier (§2.4); otherwise the file is rejected before parsing (`invalid_module_path`). |
| no module header | a file is optional `--!` documentation, then imports, then declarations |

## 2. Lexical structure

### 2.1 Characters, whitespace and line structure

| Concept | Rule |
|---|---|
| newline, whitespace | whitespace is the space character and newlines. Newline is `\n`; `\r\n` is accepted as a single newline; a `\r` not followed by `\n` is `bare_carriage_return`. |
| tab, other control characters | **a tab byte anywhere in the file is an error** (`tab_in_source`), inside string and character literals and inside comments included. Use `\t` in ordinary strings; raw multiline strings therefore cannot contain a tab. Any other control character outside a string or comment is `invalid_character`. |
| column, line | both 1-based; column counts *bytes* from the line start. Tabs are forbidden and indentation is always leading spaces, so byte column equals visual column for every token that starts after ASCII-only indentation. Diagnostics report `{line, col}` pairs, derived from token offsets and the file's line-start table. |

### 2.2 Tokens

The lexer produces a flat array of `{tag, start, line}` records (`fast-compiler.md` §5; the line
number lets the parser decide indentation without a layout pass, §4). Token text is re-derived from
`start` and the tag. The token kinds:

```
lower_ident        foo  fooBar  foo_1
upper_ident        Foo  Maybe
qualified_lower    List.map  Json.Decode.string      (no whitespace anywhere inside)
qualified_upper    Json.Decode  Maybe.Just            (module path, or a qualified constructor)
dot_lower          .field                              (a `.` immediately followed by lower_ident)
dot_index          .0  .12                             (a `.` immediately followed by digits)
int                12  0x1F
float              1.5  1e10  1.5e-3
str_start str_chunk interp_start interp_end str_end   (§2.6)
multiline_line     \\ …to end of line                 (§2.7)
char               'a'  '\n'  '\u{1F600}'
keywords           if then else case of let in type alias pub opaque import as exposing foreign
symbols            ( ) [ ] { } , : = -> <- \ | _ ? ..
operators          + - * / // ^ ++ :: == /= < > <= >= && || |> <|
eof
```

| Rule | Detail |
|---|---|
| comments are **not** tokens | they go into a parallel `comments` array (§2.3), so the parser's token stream carries only significant tokens and the formatter re-attaches them by position |
| **longest match among operators** | `\|>` not `\|` `>`; `//` not `/` `/`; `->` not `-` `>`; `<-` not `<` `-`. So `x <-1`, `x <-y`, `x <-(a + b)` and `x <-r.value` all lex as `<-`: a comparison whose right operand is negated needs the space, `x < -1`. |
| `--` after `<` | `--` always begins a comment **except after `<`**: `x <-- c` lexes as `<-`, `-`, `c`. No operator contains `--`. |
| `<-` | legal only in a `let` binding (§6.7), and `unexpected_token` anywhere else |
| markup | inside markup the lexer has four more modes and eight more token kinds, and `<` before a letter opens a tag only where no operand has just ended (§11.2; `frontend.md` §9.1–§9.3) |
| `..` | one token that no construct uses: it exists so that Elm's `exposing (T(..))` is one diagnostic (§5.2) rather than one per dot. Anywhere else it is `unexpected_token` |

### 2.3 Comments

Three line comments. All run to the end of the line; nothing nests; there is no block comment.

| Spelling | Meaning | Rule |
|---|---|---|
| `-- text` | ordinary comment | anywhere |
| `--\| text` | doc comment | documents the declaration that follows it (attachment rules below) |
| `--! text` | module doc | only at the top of the file, before any import or declaration |

Attachment rules, taken from Zig:

| Rule | Detail |
|---|---|
| doc blocks | consecutive `--\|` lines form one block, and two runs separated only by blank lines are one block too (blank lines are invisible to attachment, as in Zig). The block must be followed on the next non-blank line by a declaration (§5.3), by the `pub` that starts one, or by a record-type/schema field (§3 and `schema.md` §2); blank lines between are allowed. Field docs attach in both brace and layout spellings. Ordinary record-type field docs remain comments rather than adding semantic AST/BIR payload. |
| `doc_comment_unattached` | anything else — an import, an ordinary comment, another construct, end of file — and so is an ordinary `--` comment between a doc block and its declaration, which splits the block from its target |
| `module_doc_not_at_top` | `--!` lines must appear before the first import or declaration; anywhere else is this. Consecutive lines form one block, and a second block after a blank line merges with the first. Ordinary `--` comments and blank lines may appear before, between and after `--!` lines freely — they are trivia and attach to nothing. |
| spelling | `--\|x` and `--!x` with no space are still doc comments; the formatter inserts the space. `---` (three or more dashes) is an ordinary comment; `--\|` cannot be produced accidentally, so no carve-out exists. |

The comment record is `{kind, start, before_token}`: which significant token it precedes. Length is
re-derived to end of line.

### 2.4 Identifiers and keywords

```
lower_ident := [a-z] [A-Za-z0-9_]*
upper_ident := [A-Z] [A-Za-z0-9_]*
```

| Rule | Detail |
|---|---|
| ASCII only | a non-ASCII byte outside a string, char or comment is `invalid_character` |
| keywords, never identifiers | `if then else case of let in type alias pub opaque import as exposing foreign`. `True`, `False`, `Nothing`, `Just`, `Ok`, `Err` are ordinary constructors, not keywords. |
| `_` and `_foo` | `_` alone is the wildcard symbol; `_foo` is a lower identifier (the formatter and checker may warn later; the lexer does not care) |
| **qualified names** | single tokens with no whitespace inside: `Upper(.Upper)*.lower` is `qualified_lower`, `Upper(.Upper)+` is `qualified_upper`. The lexer decides greedily — after an `upper_ident`, if the next byte is `.` and the byte after that is a letter, the token continues — so `Foo.bar` is *always* a qualified name, never a field access on a constructor. |

### 2.5 Numbers

```
int   := [0-9]+  |  0x [0-9A-Fa-f]+
float := [0-9]+ '.' [0-9]+ exponent?  |  [0-9]+ exponent
exponent := [eE] [+-]? [0-9]+
```

| Rule | Detail |
|---|---|
| a float only before a digit | numeric lexing continues past `.` **only if the next byte is a digit**: `1.e5` lexes as `int` `dot_lower` (a field access on a literal, rejected by the checker), not as a float. (`fast-compiler.md` §3.2 mentions `e`/`E` after the dot as well; the grammar above has no such form, so the lexer does not take it.) `x.0` never starts a float because it starts with a lower identifier (§2.4). |
| not accepted | underscores, a leading `+`, octal/binary, a trailing `.`; a `-` is never part of a literal (§6.5, negation). An identifier character immediately after a number (`12abc`, `0x1G`) is `invalid_number`. |

**Three numeric types, two of them written as literals.** An `int` literal is `number`-kinded and
resolves to `Int` or `Float`; a `float` literal is `Float`. `Int` is a **double** — exact to
9007199254740991 and silently inexact past it — which is the right default and the wrong tool for
hashing, checksums, PRNGs and binary formats. Those get **`Int32`**, `core/Int32.beni`'s
`pub equatable foreign type`: a signed 32-bit integer in two's-complement whose arithmetic wraps.
Every one of its operations is total — a result is always a 32-bit value, nothing throws, and
division by zero is zero, as it is for `Basics.idiv`, `modBy` and `remainderBy`
(`fast-compiler.md` §3.1, `checker.md` Appendix B).

| About `Int32` | |
|---|---|
| literals | **there is none**. `Int32.fromInt 7`, or `Int32.fromInt 0xdeadbeef` for a bit pattern: `fromInt` truncates to 32 bits, so a literal past 2147483647 is its low 32 bits and never an error. `Int32.toInt` and `Int32.toUnsignedInt` go back, signed and unsigned. |
| `+` `-` `*` `/` `//` `^` | **do not work on it, by design.** They are `number`-kinded — `Int` or `Float` — and `Int32` is neither, so `a + b` on two of them is `kind_mismatch`. An operator that read like `Int`'s would hide the one thing the type exists to say. Write `Int32.add`, `sub`, `mul`, `div`, `rem`, `mod`, or call one as a method: `a.add b`. The diagnostic names them. |
| `==` `/=` `<` `<=` `>` `>=` | **do work.** `core/Int32.beni` declares its own `pub eq` and `pub compare`, and the module rule (`static-dispatch-spike.md` §1.2, §3.3) makes them the type's methods — so an `Int32` is a `Dict` key, a `Set` member and sortable, and a record or custom type holding one derives its own `eq`/`compare` from them. The order is **signed**: `minValue < zero < maxValue`, and `Int32.fromInt 0xffffffff` is -1. |
| overflow | **two's-complement wrap, always, and never an exception** — that is the guarantee the type buys: no runtime error and no silent inexactness. `minValue` has no negation in the type and `neg minValue` is `minValue`. |
| prelude | **not in it** (Appendix A). `import Int32` is required, and no other module's meaning changes. |

### 2.6 Strings and interpolation

```
"chunk ${expr} chunk"
```

| Construct | Rule |
|---|---|
| `"` … `"` | `"` starts a string. Inside: any byte except `"`, `\`, `$` followed by `{`, a newline, or a tab. Strings are single-line, so a newline (or end of file) inside one is `unterminated_string`, spanning the opening quote to the newline; use a multiline string. The lexer then leaves string mode, so the next line lexes normally. |
| escapes | `\n`, `\r`, `\t`, `\\`, `\"`, `\$`, `\'`, `\u{H+}` (1–6 hex digits, a valid Unicode scalar value). Anything else after `\` is `invalid_escape`. `$` not followed by `{` is a literal dollar. |
| `${` … `}` | opens an interpolation: the lexer switches to expression mode with brace depth 1, `{` and `}` adjust the depth, and the `}` that brings it back to 0 closes it. **A `"` inside an interpolation is `nested_string_in_interpolation`**, and the diagnostic says to bind the inner string to a name; a multiline-string marker `\\` there is the same error. |
| token stream | `str_start` (at the opening `"`), then zero or more `str_chunk` (a maximal run of literal text, escapes included, never empty) and `interp_start`/…tokens…/`interp_end` segments, then `str_end` (at the closing `"`). A string with no chunks and no interpolations is `str_start str_end`. |
| what may be interpolated, and `ambiguous_interpolation` | only expressions of type `String`, `Int`, `Float`, `Bool`, `Char`, checked in M2; the front end lowers `${e}` to an explicit `interp` node so the obligation is visible. **The type must be known**, because the compiler inserts the conversion: `f name = "${name}"` with `name` used nowhere else is `ambiguous_interpolation`, fixed by an annotation. A `number`-typed expression is accepted without resolving to `Int` or `Float`, because both stringify identically on the JavaScript target — a property of the target, not of the type system, and what lets `f n = "n: ${n}"` compile. |

### 2.7 Multiline strings

| Rule | Detail |
|---|---|
| form | Zig's. A line whose first non-space characters are `\\` is one line of a multiline string, raw to the end of the line — no escapes, no interpolation, `${` and `\` are literal. |
| one literal | consecutive `multiline_line` tokens (no non-blank line in between) form one string literal: each line's text is what follows the `\\`, lines are joined with `\n`, and the final line has no trailing newline |
| a blank line ends it | **a blank line between two `\\` lines ends the literal** — the second starts a new one, which is then a syntax error where it stands |
| layout, and vs a lambda | column rules (§4) apply to the `\\` marker like any other token. One byte of lookahead separates it from a lambda: `\` followed by `\` is a multiline line, `\` followed by anything else is the lambda backslash. |

```
sql =
    \\SELECT *
    \\FROM users
```

### 2.8 Characters

`'x'` with the same escapes as strings. Exactly one Unicode scalar value between the quotes;
otherwise `invalid_char_literal`, as is `''`.

## 3. Grammar

Notation: `x?` optional, `x*` zero or more, `x+` one or more, `'tok'` literal token, `|`
alternatives. Layout constraints from §4 are implicit in every rule.

```
Module      := ModuleDoc? Import* Decl*

Import      := 'import' qualified_upper_or_upper ('as' upper_ident)? Exposing?
Exposing    := 'exposing' '(' Exposed (',' Exposed)* ')'
Exposed     := lower_ident | upper_ident

Decl        := DocComment? Visibility? (TypeAlias | TypeDecl | Annotation | Definition | Foreign)
Foreign     := 'foreign' lower_ident ':' Type                 -- core root only, §5.4
             | 'equatable'? 'foreign' 'type' upper_ident lower_ident*   -- 'equatable' core only
Visibility  := 'pub' | 'pub' 'opaque'            -- 'opaque' only before 'type'
TypeAlias   := 'type' 'alias' upper_ident lower_ident* '=' (Type | FieldBlock)
FieldBlock  := LayoutField+                                  -- aligned, §4 rule 3
LayoutField := DocComment? lower_ident ':' (Type | FieldBlock)
TypeDecl    := 'type' upper_ident lower_ident* '=' Ctor ('|' Ctor)*
Ctor        := upper_ident TypeAtom*
Annotation  := lower_ident ':' Type
Definition  := lower_ident Param* '=' Expr                       -- irrefutable only (§7)

Type        := TypeParams '->' Type                              -- n-ary, right assoc in result
             | TypeApp
TypeParams  := TypeApp (',' TypeApp)*                            -- no comma is a 1-ary function
TypeApp     := (upper_ident | qualified_upper) TypeAtom+
             | 'equatable' lower_ident                           -- core only, §3 Types
             | TypeAtom
TypeAtom    := lower_ident                                       -- type variable
             | upper_ident | qualified_upper                     -- nullary type
             | '(' ')'                                           -- unit
             | '(' Type ')'                                      -- grouping, function type included
             | '(' TypeApp (',' TypeApp)+ ')'                    -- tuple, arity ≥ 2, no '->' inside
             | '{' '}'                                           -- empty record
             | '{' RecordTypeFields '}'
             | '{' lower_ident '|' RecordTypeFields '}'          -- extensible record
RecordTypeFields := DocComment? lower_ident ':' Type (',' DocComment? lower_ident ':' Type)*
                                                                 -- the comma rule, §3 Types

Expr        := 'let' LetBinding+ 'in' Expr
             | 'if' Expr 'then' Expr 'else' Expr
             | 'case' Expr 'of' Branch+
             | '\' Param+ '->' Expr                              -- irrefutable only (§7)
             | BinOp
LetBinding  := Annotation? Definition
             | LetPattern '=' Expr                               -- pattern binds have no args
             | LetPattern '<-' App                               -- rest-of-block bind, §6.7
Branch      := Pattern '->' Expr

BinOp       := Postfix (operator Postfix)* (operator Block)?     -- Pratt, table in §6.5
Block       := 'let' … | 'if' … | 'case' … | '\' …               -- the four Expr forms above
Postfix     := App '?'*
App         := Atom Arg*
Arg         := Atom | '_'                                        -- at most one '_' per App, §6.7
Atom        := literal                                           -- int float char string
             | lower_ident | qualified_lower
             | upper_ident | qualified_upper                     -- constructor
             | dot_lower                                         -- accessor function .field
             | '-' Atom                                          -- negation, no space (§6.5)
             | '(' ')'                                           -- unit
             | '(' Expr ')'
             | '(' Expr (',' Expr)+ ')'                          -- tuple
             | '(' operator ')'                                  -- operator as function
             | '[' ']' | '[' Expr (',' Expr)* ']'
             | '{' '}' | '{' Field (',' Field)* '}'              -- record
             | '{' lower_ident '|' Field (',' Field)* '}'        -- record update
             | Atom dot_lower                                    -- field access, no space
             | Atom dot_index                                    -- tuple access, no space
Field       := lower_ident '=' Expr

Pattern     := PatCons ('as' lower_ident)?                       -- `as` binds loosest
PatCons     := PatCtor ('::' PatCons)?                           -- right assoc
PatCtor     := (upper_ident | qualified_upper) PatAtom+ | PatAtom
PatAtom     := '_' | lower_ident
             | upper_ident | qualified_upper                     -- nullary constructor
             | int | char | string-without-interpolation | '-' int
             | '(' ')' | '(' Pattern ')' | '(' Pattern (',' Pattern)+ ')'
             | '[' ']' | '[' Pattern (',' Pattern)* ']'
             | '{' lower_ident (',' lower_ident)* '}'            -- record pattern
LetPattern  := '_' | lower_ident | '(' ')' | '(' LetPattern ')'  -- irrefutable only (§7)
             | '(' LetPattern (',' LetPattern)+ ')'
             | '{' lower_ident (',' lower_ident)* '}'
             | (upper_ident | qualified_upper) LetPattern*       -- if its type has ONE ctor
             | LetPattern 'as' lower_ident
Param       := PatAtom, restricted to LetPattern's shapes        -- irrefutable (§7)
```

`Param` and `LetPattern` are the same restriction in two places, and it is **not purely
syntactic**: the constructor line above is admitted by the grammar and settled by the checker,
because "does `Box x` match every `Box`?" is a question about `Box`'s type. §7 states the rule, the
parser enforces the half of it that needs no types, and `checker.md` §6.6 decides the rest. A
`Param` is the `PatAtom` spelling of the same set, so `as` reaches it only inside the parenthesised
form — already the only place a `PatAtom` can carry one.

There is **no float pattern**: a float's `==` is not something a `case` should promise, and
`0.1 + 0.2` would miss a `0.3` branch. A float literal where a pattern is expected (`-1.5` too) is
`unexpected_token` at the literal with a message of its own, suggesting a comparison, and the
`case` goes on with its other branches (the owner's decision on float patterns, `checker-v2.md` §21).

The rest of this section constrains the grammar above. Rules belonging to one construct are stated
where it is: records §6.3, operators and negation §6.5, `?` §6.6, `_`, `|>` and `<-` §6.7, §7
scoping.

**Static dispatch extends this grammar in two places** (§0;
[`static-dispatch-spike.md`](static-dispatch-spike.md) §1.1, §2.1). A **top-level** `Annotation`,
and a `Foreign` value declaration, may end with an optional `WhereClause` — `'where' Constraint (','
Constraint)*` where a `Constraint` is `lower_ident dot_lower ':' Type`; a `let` annotation may not.
`where` is a **contextual word**, not a keyword, recognised by three tokens of lookahead exactly as
`equatable` is, and the comma inside a clause is settled by the same lookahead rule the record-type
body uses. No production for expressions changes: `App := Atom Arg*` over `Atom dot_lower` already
parses `x.m a b`, and what is new is that BIR lowering reads it as a method call (§6.3).
→ `static-dispatch-spike.md` §2.1–§2.4 for the grammar, the lookahead rules and well-formedness.

**Markup extends this grammar in two places** (2026-09-29, §11): `Atom` gains `Markup`, admitted
only where an operand starts, never as a bare argument (§11.2–§11.3); and `Decl` gains the
vocabulary declarations a platform package writes, `pub element`, `pub attribute`, `pub event` and
`pub markup` (§11.14), whose leading words are contextual.

**Declarations**

| Construct | Constraint |
|---|---|
| `Annotation`, `Definition` | an `Annotation` must be immediately followed by the `Definition` of the same name — blank lines and comments may intervene, nothing else — otherwise `annotation_without_definition`; a definition has at most one annotation. A `Definition` at top level always has a `lower_ident` head; destructuring definitions exist only in `let`, where a pattern binding has no annotation and no arguments. A definition with *n* parameter atoms has an *n*-ary function type (§6.7). |
| `pub`, `pub opaque` | `pub` goes before `type alias`, `type`, an `Annotation`, or a `Definition` that has no annotation — on the annotation when there is one; `pub` on both, or only on the definition, is `pub_on_definition`. `pub opaque` is legal only before `type`, else `opaque_not_on_type`. Meaning: §5.1. |
| `TypeDecl` | needs at least one constructor. A leading `\|` before the first is allowed (`type T = \| A \| B`) and the formatter removes it. |

**Types**

**The comma in a type is the parameter separator, and it binds looser than everything except `->`.
Inside parentheses, the token after the items decides what they were**: `->` makes them a parameter
list, `)` makes them a tuple at two or more items and a grouping at one.

| Written | Is |
|---|---|
| `Int, Int -> Int` | a 2-ary function |
| `a, b -> c -> d` | a 2-ary function returning a 1-ary one — `->` is right-associative in its result |
| `List.map : List a, (a -> b) -> List b` | a function-typed parameter, which takes parentheses |
| `(Int, Int) -> Int` | a 1-ary function over a pair |
| `(Int, Int -> Int)` | a parenthesised 2-ary function; it does not unify with the row above |
| `((Int, Int) -> Int, String)` | a 2-ary function, **not** a pair whose first element is a function — a tuple item may not contain a bare `->`, which would be read as the parameter list's arrow. That is `arrow_in_tuple_element`, and the message has to carry this example, the one that traps people. Write `(((Int, Int) -> Int), String)`. |
| `{ a : Int, b : Int }`, `{ f : Int, Int -> Int, g : Bool }` | two fields each: **a comma inside a record-type body ends the field's type** when the next two tokens are `lower_ident ':'`, and the same rule governs an extensible record's body. Without it `, b` would read as a second parameter of the field's type; one token of lookahead settles it with no backtracking, because `:` can never follow a type item. So a field of n-ary function type needs no parentheses and reads as the parser reads it — parenthesising is always available, and the formatter leaves it alone. |
| type application | **type constructors are fully applied**; there are no higher-kinded types, and too few or too many arguments is `wrong_type_arity`, checked in M2 against the declaring module's interface. A type alias may not refer to itself, directly or through other aliases: `recursive_alias`. |

**`equatable` is a contextual word, not a keyword.** It is an ordinary identifier everywhere except
directly before `foreign` in a declaration, and directly before a type variable where a `Type`
starts. Elsewhere — a module outside the core package — it is `equatable_outside_core`; a second
marker on the same variable, or one on a later occurrence of it, is
`equatable_not_first_occurrence`. User annotations obtain the mark by inference, never by spelling
([`checker.md`](checker.md) Appendix A and B).

| Written | Means |
|---|---|
| `eq : equatable a, a -> Bool` | a function of **two** arguments: the marker marks the *variable*, not the argument in front of which it stands |
| `member : List (equatable a), a -> Bool`, `(equatable a, Int)` | a `TypeApp` starts after every comma as well as at the head of a type, so the marker may stand on any parameter; to mark a variable that first occurs as an *argument*, parenthesise it. A tuple element is a `TypeApp` too, so the second is grammatical and marks `a`. |
| `pub equatable foreign type List a` | "equatable when every parameter is" |
| `List equatable` | a list of a variable *named* `equatable`: the word is recognised only where a whole `Type` starts, so an *argument* keeps its old reading |

**Declaration field blocks.** A `FieldBlock` desugars to the brace-form record
with the same ordered fields and nested record types, producing the same
`type_record` AST nodes and byte-identical AST/BIR dumps. It is available only
as a `type alias` body and recursively as a whole field body there; inline
annotations, extensible records `{ r | name : String }`, ordinary `type`
constructor payloads, the empty record `{}` and every record value retain
braces. Schema field blocks use the parallel grammar in `schema.md` §2.
After a field's `:`, a next token on a later line at a greater column opens a
nested field block exactly when the next two tokens are `lower_ident ':'`;
otherwise the field body is a type. This test is exact because `:` never
follows a type item. A field head encountered after a type has already begun
is a sibling only at the field column; an indented `street : String` after
`address : Maybe` is an error, not an implicit record argument to `Maybe`.

**Expressions**

| Construct | Rule |
|---|---|
| `case`, lambda, leading operator | `case` needs at least one branch (`case_without_branches`); a lambda is `\x y -> e`, one or more pattern atoms; an expression may not begin with an operator, except `-` for negation (§6.5) |
| a `let`, `if`, `case` or lambda | **may be the *last* operand of an operator chain** (`f <\| \x -> x + 1`, `text <\| if a then b else c`), as in Elm; it extends as far as the layout allows, so nothing can follow it in the chain. It may not be a bare application argument: `f \x -> x` is an error, write `f (\x -> x)`. `\|>` is the exception and takes no block (§6.7). |
| access chains | **must abut their atom**: `(f x).name`, `r.a.b`, `t.0.1`, `xs.0` — the `dot_lower` / `dot_index` token must start at the byte right after the atom's last byte. With whitespace, `.field` is an accessor-function atom and application applies: `f .name` is `f` applied to `.name`. |
| trailing commas | not allowed anywhere. Empty `( )`, `[ ]`, `{ }` may contain whitespace. |

## 4. Layout: indentation is the block structure

There is no layout pre-pass and no virtual semicolon. The parser carries one integer, the **indent**
of the current block, and a token belongs to the current construct only if its **column is greater
than the indent**. Blocks are:

| Block | Its indent is the column of… | Sibling starts at | Ends when |
|---|---|---|---|
| top-level declaration | the declaration's first token, which **must be column 1** | column 1 | a token at column 1, or EOF |
| `let` binding list | the first binding's first token | exactly that column | `in`, or any token not at that column that the current binding could not consume |
| a `let` binding's body | the binding's first token | — | a token at column ≤ that, or one the expression cannot continue with |
| `case` branch list | the first branch's pattern | exactly that column | any token not at that column that the current branch could not consume |
| a branch's body | the branch's pattern | — | a token at column ≤ that, or one the expression cannot continue with |
| declaration field block (`FieldBlock` or `SchemaFieldBlock`) | the first field's name | exactly that column, on a later line | a smaller column, or EOF |
| a layout field's type/operand and modifiers | the field's name | — | a token at column ≤ that, or one the type/operand cannot continue with |
| layout schema variants | the first variant's name | exactly that column, on a later line | a smaller column, or EOF |

Rules:

| # | Rule |
|---|---|
| 1 | **Top-level declarations begin at column 1**, so everything belonging to a declaration — the rest of its first line, and every continuation line — is at column ≥ 2. A token at column 1 always starts a new import or declaration; if it cannot, `expected_declaration`. |
| 2 | **Every token of a block body has column > the block's indent.** This is checked on every token, not only the first of a line, and is trivially true on the head's own line. When the check fails, the parser sees the end of that block, and nothing peeks beyond it. |
| 3 | **`let` bindings are aligned.** The first binding sets the column; a token at exactly that column begins the next binding; `in` ends the list and may sit at any column greater than the *enclosing* block's indent, so `in` aligned with `let`, or on the same line, is fine. |
| 4 | **`case` branches are aligned** the same way. The first branch may be on the same line as `of`, wherever that is, and later branches must match it. The branch column is constrained only by the enclosing block, not by the `case` keyword: branches at the same column as `case` are legal, as in Elm (the formatter indents them). When a branch body's expression stops at a token it cannot continue with — a `)` closing an enclosing group, a `,`, an `in` — the branch list ends there too, whatever that token's column, and the enclosing construct decides whether the token is legal. So `(case x of A -> y)` and `[ case x of A -> y, 2 ]` are both fine. |
| 5 | **`then`, `else`, `of`, `->`, `in`, operators, arguments, `\|` in a type declaration** follow rule 2 and nothing more: any of them may start a line as long as it is right of the enclosing block's indent. |
| 6 | **Brackets do not suspend layout.** Inside `( [ {` rule 2 applies against the enclosing block's indent, which is what makes an unclosed bracket unable to swallow the file: a token at column 1 ends every open construct and reports `unclosed_delimiter` at the opening bracket. |
| 7 | **Interpolation follows the string.** Tokens inside `${…}` are on the string's line by construction, so rule 2 holds automatically. |

**Declaration field blocks reuse rule 3's `let` mechanism.** The first field
sets the block column; exactly that column begins a sibling, a smaller column
ends the block, and a field's type/operand and modifiers continue only to its
right. The first field follows `=` on a later line right of the declaration;
nested blocks follow `:` on a later line right of their field. A lower
identifier at a column that is neither a sibling column nor right of the field
is a diagnostic, never silently consumed as a continuation. A dedent to an
outer field column is valid; a dedent to no enclosing sibling column is not.
A field head to the right after a type has started is likewise an error (§3).
Tagged schema variants use the same aligned-list rule, with payload fields
right of the variant. Brackets set no column: rule 6 still checks against the
field's enclosing block, never the opening bracket's column.

**Recovery:** a malformed layout field resumes at the next token at exactly
its field column, or ends the block at a smaller column; column 1 ends all
open constructs. Reuse `unexpected_token` for a malformed/misaligned field
and `expected_token` for a missing required token, with field context; no new
code is introduced. An aligned `age Int` is a field missing `:`. When written
to the right of a preceding field it can instead be consumed as that type's
application continuation, as in the brace form; a missing colon supplies no
field-head lookahead. EOF ends a complete block normally; an incomplete field
still diagnoses its missing type or token.

**A `where` clause (§3) needs no rule of its own**: it is rule 2 and nothing more. `where` and every
token of the clause belong to the declaration's block, so each must be at column ≥ 2; a `where` at
column 1 starts a new declaration and the annotation above it simply has no clause.
→ `static-dispatch-spike.md` §2.5.

Worked example, columns shown:

```
1        10
view model =
    case model.page of
        Home ->
            let
                title = "Hi"
                body =
                    text title
            in
            div [] [ body ]

        About ->
            text "about"
```

`case` body indent is 1 (the declaration). Branches at column 9; `Home` body is anything at column >
9. `let` bindings at column 17; `body`'s body continues at column > 17; `in` at column 13 is left of
17 (ends the bindings) and right of 9 (still inside the branch). `About` at column 9 starts the next
branch; the blank line is trivia. The rules are lexically decidable: the only inputs are each
token's column (from its offset and the line-start table) and one integer of parser state, and no
token's meaning depends on a later line.

## 5. Modules, imports, visibility

### 5.1 Visibility

- `pub` marks a declaration as part of the module's interface; unmarked declarations are private,
  and a private declaration used by a public one is fine — visibility is about names, not
  reachability.
- `pub type T = A | B` exposes the type *and* its constructors; `pub opaque type T = …` exposes the
  name only, its constructors usable in this file and nowhere else; `pub type alias` exposes the
  alias. Where the `pub` and `opaque` words may stand is §3.

### 5.2 Imports

```
import Json.Decode
import Json.Decode as D
import Json.Decode exposing (Decoder, string, int)
import Dict as D exposing (Dict)
```

| Construct | Rule | Diagnostic |
|---|---|---|
| module path, `as` | the path is one `qualified_upper` or `upper_ident` token; `as` gives the alias used for qualification in this file, and without it the alias is the full path (`Json.Decode.string`) | two imports sharing an alias, `duplicate_import_alias`; the same module imported twice, `duplicate_import` |
| `exposing` | lists names, each exactly once across the whole file, since an unqualified use would otherwise be ambiguous | a name exposed twice in one list, or by two different imports, `duplicate_exposed_name` at the second occurrence |
| lower vs upper names | lower names are values; upper names are types **or constructors** — the file cannot tell which and does not need to: in a type position an upper name is a type, in an expression or pattern a constructor. Whether the imported module actually exposes it is checked in M2. | — |
| ordering, self-import | all imports precede all declarations, and the formatter sorts imports by path. Importing the current module is a cycle of length one, detectable per file; longer cycles are M2. | an import after a declaration, `import_after_declaration`; the self-import, `self_import` |
| Elm's `T(..)` | not beni: there is no wildcard, and constructors are listed by name beside the type (`exposing (T, A, B)`). Written anyway it is ONE diagnostic at the `(`, and an unknown constructor anywhere in the file stays quiet — lowering cannot tell which are `T`'s, and the file already fails (the owner's decision on `T(..)`, as amended in `checker-v2.md` §21.1) | `expected_token`, whose message spells the `exposing` list to write with the constructors the imported module exposes (named by resolution, which has its interface; `fmt` and the dumps, which do not, write `…`) |

### 5.3 What is a declaration

Type alias, custom type, annotation + definition, or a bare definition. Each declares exactly one
name at top level (the type or the value); constructors additionally declare their names in the
file's constructor namespace. Names are unique per namespace per file:

| Collision | Diagnostic |
|---|---|
| two value declarations with the same name | `duplicate_declaration` |
| two types, alias or custom, with the same name | `duplicate_type` |
| two constructors with the same name, across all types in the file | `duplicate_constructor` |
| a declared name against an `exposing` import of the same namespace | `shadows_import` |

`Dict` the type and `Dict` the module alias live in different namespaces and may coexist, as in Elm.

### 5.4 Foreign declarations (core only)

The standard library is written in beni. The few functions and types that cannot be — arithmetic,
string primitives, the list representation — are declared without a body, implemented in JavaScript:

```elm
--| Add two numbers.
pub foreign add : number, number -> number

pub foreign type List a
```

| Rule | Detail |
|---|---|
| shape | `foreign name : Type` declares a value with that type and no definition. `foreign type T a…` declares a type with no constructors, so it is opaque by construction; `opaque` before `foreign` is `unexpected_token`. Both take `pub` and may carry a doc comment. |
| `foreign_outside_platform` | `foreign` is **legal only under the core root**, which is embedded in the compiler (`fast-compiler.md` §3.1, "Primitives"); a `foreign` declaration in any other module is this, reported by lowering. User code reaches JavaScript through the effects model (open), never through `foreign`. |
| which types | the primitive types are foreign: `Int`, `Float`, `Char`, `String`, `List a`. `Bool`, `Maybe`, `Result` and `Order` are ordinary declared types in core. `Char` and `String` are declared in `Char` and `String`, not in `Basics`: under the module rule a type's methods are its declaring module's `pub` values, and `String.compare` is the method `String` should always have had (spec §5.1). Both stay prelude types, so no module gains an import. |
| a `foreign` with a `where` clause | a `pub foreign` may carry a `where` clause (§3), and the sibling export's arity is then **evidence count + declared arity** — `core/List.beni`'s `eq` is declared 2-ary and is written `(m0, xs, ys)` in `core/List.js`. **This rule is documented and not enforced**: [`boundary.md`](boundary.md) §4's checks are export coverage and import coverage, and neither looks at arity. → `static-dispatch-spike.md` §5.2. |
| binding, lowering | each core module that declares foreigns has a sibling JavaScript file exporting one function per foreign value, under the same name, in the emitted calling convention; binding is by name, and a missing export is a build error of the core package, not a user diagnostic. Lowering emits a `foreign` declaration into the interface skeleton like any other `pub` name, and the interface records that it is foreign so M3's printer can key its peephole on the module-qualified name. |

**Schemas** add a declaration and a schema namespace to this section. The
normative delta is [`schema.md`](schema.md) §2–§4: the schema is the defined
thing, its types are `User.Type` and `User.Encoded`, and explicit exposure brings
only `User`. Its open choices are listed first; no schema syntax has landed.
The diagnostic additions at the end of §10's catalogue are specified there in §8.

## 6. Expression details

### 6.1 Literals

`Int`, `Float`, `Char`, `String` literals as lexed. `()` is unit. `[a, b]` is a list literal.
`(a, b, c)` is a tuple literal; `(a)` is grouping.

### 6.2 Names

| Name | Resolves, in this order, to | If none |
|---|---|---|
| unqualified `lower_ident` in expression position | the innermost local binding (lambda parameter, let binding, pattern variable, function parameter), a top-level value in this file, a name in some import's `exposing` list, a name in the **prelude** (Appendix A) | `unbound_variable` |
| `qualified_lower` | its module part against the import aliases and then the prelude's module aliases; the value part is checked in M2 | `unknown_module_alias` |
| `upper_ident` or `qualified_upper` in expression or pattern position | a constructor: declared in this file, else in an `exposing` list, else a prelude constructor; a `qualified_upper` resolves like `qualified_lower` | `unbound_constructor` |
| an upper name in type position | a type: declared in this file, else exposed, else prelude | `unbound_type` |

Imports are explicit and per-file and the prelude is a fixed table inside the compiler, so this
resolution needs no other file. A top-level declaration or an `exposing` entry may reuse a prelude
name; the prelude entry is then not visible in this file (no diagnostic). A top-level declaration
may **not** reuse an `exposing` name (`shadows_import`), and locals may shadow nothing (§7) —
including prelude names.

**One reading is added to the table above, and only inside an annotated declaration**
(§0): an application whose head is `v.m`, where `v` resolves to *no* value binding by the rules
above but **is** a type variable that the declaration's own `where` clause constrains, is a
**return-type dispatch** rather than `unbound_variable`. `a.decode s` is the shape. Shadowing is an
error (§7), so no value binding can ever be hidden by this rule and the two readings never overlap;
with no `where` clause naming the method, or no annotation at all, it stays an error.
→ `static-dispatch-spike.md` §4.

### 6.3 Records

`{ a = 1, b = 2 }`, `{ r | a = 1 }`, `r.a`, `.a`. Field names are unique within a literal
(`duplicate_field`); update with zero fields (`{ r | }`) is a syntax error. The update target is a
plain name, as in Elm, resolved by §6.2 (local, top-level, or exposed import); `{ r.a | … }` is not
allowed. Access is a chain on any atom and must abut it (§3): `r.a.b`, `(f x).name`.

**Field access and the method call share a spelling, and the argument list separates them** (§0).
`x.m` alone is a field access, always — an application with no arguments is not an application, so
even a nullary method is out of reach and is written `M.m x`. `x.m a b` is a **method call**: the
checker resolves `m` against the methods of `x`'s *type* and, when that type turns out to be a
record, falls back to the field call `(x.m) a b` with the record's own diagnostics. Parentheses opt
out explicitly, and `M.f x` on a qualified *name* is an ordinary call and never a method call.
→ `static-dispatch-spike.md` §1.1, §1.2.

**A record update keeps the identity of every field it does not name** (2026-09-29, W27): the
untouched fields of `{ r | a = x }` are the very values `r` held, and no optimiser may break that.
The promise and its reason are §11.12.

### 6.4 Tuples

`(a, b)`, arity ≥ 2, unbounded. `t.0` is the first element, and chains like `t.0.1` follow §3's
adjacency rule. The index is a literal decimal integer with no leading zeros beyond `0` itself
(`.00` is `invalid_tuple_index`). Arity checks are M2.

### 6.5 Operators

Fixed table. Binding power in Pratt terms; left/right associativity via asymmetric powers;
non-associative operators reject a second operator of the same precedence without parentheses
(`non_associative_chain`).

| Prec | Operators | Assoc |
|---|---|---|
| 0 | `<\|` | right, syntactic (§6.7) |
| 0 | `\|>` | left, syntactic (§6.7) |
| 2 | `\|\|` | right |
| 3 | `&&` | right |
| 4 | `==` `/=` `<` `>` `<=` `>=` | non-assoc |
| 5 | `++` `::` | right |
| 6 | `+` `-` | left |
| 7 | `*` `/` `//` | left |
| 8 | `^` | right |
| — | `?` postfix, application, `.field`, `.0` | tighter than all of the above, in that order (tightest last) |

| Rule | Detail |
|---|---|
| mixing `<\|` and `\|>` | at precedence 0 without parentheses it is `non_associative_chain`: they associate in opposite directions, so a mixed chain has no predictable reading, and Elm rejects the same pair. `<<` and `>>` are removed, and with them the precedence-9 case of this rule and the composition idiom, which is replaced by naming the argument. |
| **negation** | `-` directly followed (no whitespace) by an atom, where the parser expects the *start* of an operand: `-x`, `-(a + b)`, `-1`, `[ -1, -2 ]`. The operand is one atom with its access chain, so `-r.value` is `-(r.value)` and `-f x` is `(-f) x`, as in Elm. Negation of an integer literal in a *pattern* is a literal pattern (`-1 ->`). `- x` with a space in prefix position is `negation_with_space`; `a - -b` is allowed. |
| `f -1` | **not** negation: in argument position the parser has parsed `f` and sees `-` where either an argument or an operator may follow, and **it is the binary operator**, as in Elm, so `f -1` is `f - 1`. Write `f (-1)`. |
| **operators as functions** | `(+)`, `(::)`, `(==)` and so on: any operator from the table that lowers to a call or to a method call, each being the 2-ary function it lowers to. The six comparison operators lower to a lambda over a marked method call, not to a reference to `Basics.eq` — so `(==)` is `\a b -> a.eq b` with the operator's own pinning rule, not structural equality (spec §3.1). Whitespace inside the parentheses is allowed and the formatter removes it. Sections such as `(+ 1)` do not exist; `(-)` is the binary minus function and there is no negation function. `\|>` and `<\|` are syntax, not calls, so `(\|>)` and `(<\|)` do not exist and are `operator_not_a_function`. |

**The six comparison operators are method calls, not `Basics` calls** (§0). `a == b` and `a /= b`
lower to a call of `eq` on `a`'s type; `a < b`, `a <= b`, `a > b`, `a >= b` to a call of `compare`,
whose `Order` result the backend tests. The operator form **pins both operands to one type** — which
a hand-written `a.eq b` does not — and the compiler **derives** `eq` and `compare` for a type whose
module declares none, structurally and recursively, so `==` on a record of lists of user types keeps
working and `"a" < "b"` now compiles. `Basics.eq`, `neq`, `lt`, `gt`, `le`, `ge` and `compare` stay
declared, exported and callable by name; they are simply no longer what the operators mean. Nothing
in the precedence table above changes. → `static-dispatch-spike.md` §3.

### 6.6 `?`

`e?` where `e : Result x a` yields `a` or returns `Err x` from the enclosing function; where
`e : Maybe a`, yields `a` or returns `Nothing`. The front end enforces precedence and scope:

| Rule | Detail |
|---|---|
| precedence, `args_after_question` | **application binds tighter than `?`, which binds tighter than every binary operator** (§6.5), so `parse s? \|> f` is `((parse s)?) \|> f` and `f (a?) b` is how `?` is applied to one argument. `f a? b` is `args_after_question`: after `?` no further arguments may follow. An adjacent access chain may: `x?.field` is `(x?).field`, `x.field?` is `(x.field)?`, and `r??` applies `?` twice. |
| what it returns from | **the nearest enclosing definition that has parameters**, top-level or `let`. A `let f x = g x?` inside `view` returns from `f`; a `let y = g x?` (no parameters) inside `view model` returns from `view`, as `let y = g(x)?;` does in Rust. |
| `question_outside_function`, `question_in_lambda` | the first when no enclosing definition has parameters — a top-level constant, or constants all the way up; the second when a lambda sits between the `?` and that definition, a `_` placeholder and a `<-` callback both counting as lambdas here (§6.7) |
| lowering | each `e?` becomes one `try` instruction standing for the `case` it means (§8), carrying the subject and the definition it returns from; the Maybe/Result choice and the "same shape as the enclosing function" rule are M2, decided on that instruction (`checker.md` §6.5) |

### 6.7 Saturated calls, `_` and `<-`

One decision (`fast-compiler.md` §9.3) in four parts: calls are saturated, `_` replaces partial
application, `|>` inserts at the first argument, and `<-` binds the rest of a block.

**Every call is saturated.** A definition with *n* parameter atoms has an *n*-ary function type, and
a call of it supplies exactly *n* arguments. Too few is `too_few_args`, too many is `too_many_args`,
and neither has a partial-application reading. Function types of different arity do not unify, so an
arity mistake is reported where it is written, including inside a lambda passed to a higher-order
function — the reason currying went.

**`_` is the placeholder.** In argument position of an application, `_` stands for the argument the
call does not supply: `f a _ c` is `\x -> f a x c` for a fresh `x`.

| Rule | Detail |
|---|---|
| `placeholder_outside_argument`, `multiple_placeholders` | `_` is an argument, never an expression of its own: `let y = _`, `_ + 1` and `f (_)` are `placeholder_outside_argument`, which takes precedence over the generic `unexpected_token` that §10 would otherwise give. At most one `_` per application (`multiple_placeholders`), as in Gleam; two omitted arguments are written as a lambda. |
| position, and what the lambda wraps | a placeholder may fill any position, the first included. The lambda wraps the **innermost enclosing application**: in `f (g _) b` the placeholder belongs to `g`, and what `f` receives is `\x -> g x`. |
| order against pipes | **pipes rewrite before placeholders lift** (§8): `e \|> f a _` is `f e a _` and then `\x -> f e a x`. Lifting first would leave a lambda as the pipe's right operand and reject the program. |
| `f _.name` | applies `f` to the placeholder **and** to the accessor `.name`, because a `dot_lower` must abut an `Atom` and `_` is not one. Write `f (\r -> r.name)` for the other reading. |
| in patterns, and against §6.6 | `_` keeps its pattern meaning (§3, `PatAtom`) everywhere a pattern is expected, and the two positions never overlap. **A placeholder is a lambda** for §6.6, so a `?` inside the application it lifts is `question_in_lambda`: `f a? _` is rejected. |

**`|>` is pipe-first syntax.** `e |> f a b` rewrites to `f e a b` and `e |> f` to `f e`: the left
operand becomes the callee's **first** argument. `<|` keeps Elm's meaning: `f <| e` is `f e`.

| Rule | Detail |
|---|---|
| `pipe_rhs_not_application` | the right operand of `\|>` must be an **application**, and nothing else. A `let`, `if`, `case` or lambda has no head application to insert into, so §3's rule admitting a block as the last operand of a chain does not extend to `\|>`. `<\|` carries blocks and the trailing-lambda idiom, and is unaffected. |
| grouping, and not calls | **parentheses around the right operand are looked through**, as lowering already does: `x \|> (f a)` is `f x a`, not a call of the value `(f a)`. `\|>` and `<\|` are syntax, not calls, so neither has a parenthesised form (§6.5). |
| library convention | because the pipeline inserts at the first argument, **the standard library is subject first and function last**: `List.map xs f`, `String.split s sep`, `Dict.insert d k v`, `Result.andThen r f` — the convention that makes a pipeline read and lets `<-` reach every callback-taking function |

**`let x <- e` binds the rest of the block.** `let x <- f a b in rest` desugars to
`f a b (\x -> rest)`: the remaining bindings and the body become the callee's last argument. It is
purely syntactic — no type-constructor table, no dispatch, nothing that depends on inference.

```elm
let
    scope <- Task.scope
    conn <- Task.bracket (\() -> Db.open url) Db.close
    h <- Result.andThen (readHeader s)
in
render scope conn h
```

| Rule | Detail |
|---|---|
| right-hand side | **the callee applied to all but its final argument.** For a callee of arity one that is the bare name: `scope <- Task.scope` is `Task.scope (\scope -> rest)`, the shape the form was generalised for (`fast-compiler.md` §9.3 item 7). A qualified name, a field access, a parenthesised operator and a parenthesised application are legal heads for the same reason. |
| `bind_rhs_not_application` | anything that is not a call once the rest of the block is appended — a `case`, an `if`, a lambda, a `let`, a `?`, an arithmetic expression |
| pipes | a `\|>`/`<\|` chain is legal in principle, because pipes rewrite before the bind does (the order rule above), so `let x <- File.read path \|> Task.mapError f` means `Task.mapError (File.read path) f (\x -> rest)`. The chain's head application is what receives the callback, so the bind attaches to `Task.mapError`, not to the pipe. |
| no `_`, no annotation | a bind is a call missing exactly its final argument, not a partial application, so a `_` among the bind's own arguments is `placeholder_outside_argument`; a `_` in a nested application inside one of those arguments lifts over that application as usual. `let x : T` may only precede a `Definition`, so an annotation above a bind is `annotation_without_definition`. Whether the callee's last parameter is in fact a function is a type question, reported in M2 as `bind_not_callback`. |
| what `rest` is, and the bound pattern | `rest` is every binding after this one together with the `in` body. A `<-` may appear anywhere in the binding list, last included, where `rest` is the body alone. A bind inside a `case` arm or an `if` branch opens its own `let` and cannot reach past the branch it sits in. The bound pattern is a `LetPattern`, so irrefutable, and is in scope only in `rest` (§7). Because the desugaring makes it the callback's **parameter**, that is what it is called when it breaks the rule: `refutable_parameter_pattern`, from the parser and from the checker alike — the checker only ever sees it as a `lambda` parameter, and one position may not have two names. A `_` placeholder's lambda needs no rule at all: its parameter is a name lowering invents, never a written pattern. |
| against §6.6 | **the callback is a lambda**, so a `?` anywhere in `rest` is `question_in_lambda`. The restriction is conservative and reversible: letting `?` return from the callback is correct only when the callee passes its result through unchanged, which the front end cannot know. Same question as `transparent-effects-proposal.md` §11 Q5, to be settled there. |

### Evaluation order

*Unnumbered on purpose: this belongs inside §6, and a numbered §6.8 would renumber nothing but would
invite one.* **beni is strict, and it evaluates left to right in source order.** An expression is
evaluated exactly once, when control reaches it, and control moves through a declaration in the
order that declaration is written.

That sentence lived only in [`transparent-effects-proposal.md`](transparent-effects-proposal.md) §5
until 2026-09-18, which is a proposal and therefore normative nowhere — while three landed things
already depended on it. `checker.md` Appendix B's callback-order rule ("a core function that takes a
callback … calls it first element first") is *only* a rule if argument order is fixed. `core/Dict.beni`
gets `mapTree`'s ascending walk from its `let` bindings and `foldlTree`'s from its arguments. And
`backend.md` §9's optimiser needs to know what it may not move. `Debug.log` makes every row below
observable today; effects will make them observable in what a program *does*.

| Construct | What is evaluated, and in what order |
|---|---|
| application `f a b` | **the callee, then the arguments left to right.** The callee is an expression like any other, so `(pick k) a b` evaluates `pick k` first |
| method call `x.m a` | the receiver, then the arguments left to right. The evidence parameters a constraint adds are leading (`backend.md` §4) but are not expressions the program wrote, and no order is observable through them |
| binary operator `a ⊕ b` | **the left operand, then the right**, whatever the operator desugars to — a `Basics` call (`+`), a method call (`==`, `<`, §6.5) or `List.cons` (`::`). The desugaring is an application, so this is the row above and not a separate rule |
| `&&`, `\|\|` | the left operand, then the right **only when the left does not decide it**. This is why `Basics.and` and `Basics.or` are `foreign`: a call would evaluate both (`backend.md` §4, correction 3). A right operand that needs statements of its own gets them inside the branch |
| `\|>`, `<\|` | **pipes rewrite before anything runs** (§6.7, §8), and the rewritten form's order is what holds. For `\|>` the two agree: `e \|> f a` is `f e a`, so `e` — written first — is evaluated first. For `<\|`, `f a <\| e` is `f a e` and `a` precedes `e`, which is again source order |
| `_` placeholder | **the lambda evaluates nothing when it is built.** `f (g x) _` is `\p -> f (g x) p` (§6.7), so `g x` runs on *every* call of that lambda, and after that call's own argument. Bind `g x` to a name first if it should run once |
| `let x <- e` | `let x <- f a in rest` is `f a (\x -> rest)`: `f`, then `a`, then the call; `rest` runs if and when and as often as `f` calls the callback |
| tuple literal, list literal | element by element, left to right |
| constructor | argument by argument, left to right |
| **record literal** | **field by field, in the order the fields are written** — `{ z = p, a = q }` evaluates `p` then `q`. `backend.md` §4 sorts the emitted object's *keys* so that one record type has one hidden class; that is a representation decision, and it does not move an evaluation |
| record update `{ r \| a = p, b = q }` | `r`, then the updated fields in written order |
| field access `r.a`, tuple index `t.0`, accessor `.a` applied | the subject alone, once |
| string interpolation | segment by segment, left to right; a literal chunk evaluates nothing |
| `if` | the condition, then **exactly one** branch |
| `case` | **the scrutinee exactly once**, then exactly one branch body. A scrutinee that is a tuple literal evaluates each element once, left to right, before any test is made |
| `e?` | the subject once — `?` is a `case` on it (§6.6) |
| `let` bindings | **in the order written.** A binding whose right-hand side is a *function* is available throughout the block, so mutual recursion among `let` functions is unrestricted; a binding whose right-hand side is a *value* may only name bindings written before it — and one that does not is `let_forward_reference` (§7), which is the error that makes "in the order written" a total rule rather than an aspiration |
| a self tail call | the new arguments in parameter order, all of them evaluated before any parameter is rebound (`backend.md` §8) |
| top-level constants | each before its own first use, at module load |
| a top-level value with a `where` clause and no parameters | **its initialiser runs once per evidence, at the first use that needs it** (2026-09-26). It takes its evidence as hidden arguments (`static-dispatch-spike.md` §8.1), so it cannot run at load; the emitter keeps the value the last evidence gave, and a read or call with the same evidence reuses it (`static-dispatch-spike.md` A.85 *as amended 2026-09-26*). The memo is ONE slot keyed on the IDENTITY of every evidence argument, so what "the same evidence" means is what the emitter builds: a primitive's evidence, a context-free nominal type's derived function and a `where`-free method are module-level names, and a use whose evidence arguments are all such names runs it once, like the same value without the `where`, only at its first use rather than at load. Evidence built AT the use — a structural type (`List Int`, a record, a tuple) or a nominal type whose derived context is not empty — is a fresh closure at each read, so such a use computes again at each read, as before; so does one instantiation read from two modules, each with its own evidence names. A use with other evidence computes again, and evicts the slot. Hoisting closed evidence to module level, which would make it once per instantiation, is recorded, not done (narrowed 2026-09-26). A body that is itself a reference to a constrained function (`h = maxOf`) computes nothing and is called straight through. `run/EvidenceFunctionBodyPerCall.beni`, `run/EvidenceThunkOncePerEvidence.beni`. *Until 2026-09-26 it ran at EACH read or call.* |
| *markup (the next five rows were added on 2026-09-29 with §11; §11.11 says what a render may skip)* | |
| an element or fragment | **its attributes and events, then its children, in source order**, attributes and events interleaved as written, each once; a hole inside a child element is reached when that element is. A constant attribute or a text run evaluates nothing (§11.5) |
| a component | its props in source order, the spread first where there is one, `children` where the children are written; then the call, **unless it is skipped** (§11.8) |
| `For` | its attributes in source order; then the row function once per row, first row first, **except for rows that are skipped** (§11.9) |
| `Show` | its attributes in source order; then, on `Just v`, the key function once and the body once, **unless the body is skipped** (§11.18) |
| an event handler | the handler *value* is evaluated with the markup; calling a function handler, or an `Html.map` function, happens when the event fires, never during a render |

**Two rows the emitter did not honour, found on 2026-09-18 by writing the fixtures for this
table.** The document is what is right and the code is the bug, per the two rows themselves.
Both were fixed the same day:

1. ~~A **record literal** evaluates its fields in *sorted field-name order*.~~ **Fixed** the same
   day. `Lower.recordNode` sorted the fields and then lowered each one, so the key sort dragged the
   initialiser with it and `{ zed = p, alpha = q }` ran `q` first. It now sorts a *permutation* of
   the fields, lowers the initialisers in written order, and pins one to a `const` exactly when the
   key order — or a later initialiser's hoisted statements — would otherwise move it
   (`backend.md` §4). `run/EvalOrderRecordFields.beni` proves the order and
   `emit/RecordFieldOrder.js` proves that a literal which moves nothing buys no temporary. Record
   *update* was already right, because a spread does not move anything.
2. A **`let` value binding that names a later `let` value binding** was accepted by the checker and
   emitted as a `const` in written order, so it trapped at run time with a JavaScript
   `ReferenceError`. **Fixed on 2026-09-18 by refusing the program, not by reordering it**:
   re-sorting the bindings by their dependencies would make evaluation order depend on which names
   a right-hand side happens to mention, which is exactly what this table says it does not. The
   diagnostic is `let_forward_reference` and the rule it enforces is §7's. Function bindings are
   emitted as hoisted `function` declarations and are unaffected, which is what makes the mutual
   recursion §7 promises work.

**A third row the emitter did not honour, found the same way on 2026-09-18 and
fixed the same day.** The `top-level constants` row promises each constant is initialised
before its own first use, and `backend.md` §5's `emissionOrder` delivers that by emitting in
dependency order — but only while the dependencies form a DAG. A **cycle between top-level VALUES**
fell back to source order and crashed exactly as the `let` case did, with the build exiting 0:
`x = y + 1` with `y = x` emits `const A$y = A$x;` above `const A$x = Basics$add(A$y, 1);` and throws
`ReferenceError: Cannot access 'A$x' before initialization`, and so does a cycle that runs through a
function (`a = f 1`, `f n = n + b`, `b = a` emits `const B$b = B$a;` first and throws the same way).
**Fixed by refusing the program**, as `let` was — there is nothing to reorder, because dependency
order is already the rule here and a circle has no order — with the shape of §7's one scope out: a
top-level value may not be reachable from itself, following an edge into a function's body because
naming a function may call it. The diagnostic is **`cyclic_value`** (§7, §10) and the pass is the
checker's (`checker.md` §6.7), not lowering's, because the graph it must walk is not BIR's `refs`
alone: a `method_call` adds no `refs` edge (`static-dispatch-spike.md` §1.4) and the checker's
dispatch table carries those edges, the same three legs `emissionOrder` and `js/Reach.zig` read.
That is also why it was its own slice.

**Tests are not evaluations, and that is what a decision tree trades on.** `backend.md` §7 compiles
a whole `case` to one tree, which may test the parts of the scrutinee in whatever order it likes,
test one part on several paths, and skip a test it has already made. All of that is reading a value
that is already there. What the tree may not do is evaluate a written expression twice, or in an
order this table does not give — which is why it binds the scrutinee at most once and rebuilds
*occurrences* rather than re-evaluating subjects.

**Deliberately unspecified.** Three things, each because pinning it would buy nothing and cost an
implementation:

- **How often, and in what order, `sort`, `sortBy` and `sortWith` call the function they are given.**
  The merge sort reaches elements as it reaches them; `sortBy`'s key function may run once per
  element or many times (`checker.md` Appendix B says the same, and is the place this is owned).
  Every *other* callback-taking core function has its order fixed there.
- **The order in which one module's top-level constants are initialised**, beyond each preceding its
  own first use. The backend emits them in dependency order today. Nothing can observe the
  difference except a top-level `Debug.log`, and `backend.md` §9 may drop that declaration whole.
- **Which of two modules that do not depend on each other is loaded first.**

**What an optimiser may assume** (`backend.md` §9 is where it is spent). Every beni expression is
**pure**: evaluating it produces a value and changes nothing an observer can see. The exceptions are
exactly two — `Debug.log`, which writes a line, and a platform package's `foreign` values, which
`boundary.md` §4 confines to a total pure function over admitted types or an effect *value*. So:

- **A binding whose value is never used may be dropped whole**, everything inside it included, a
  `Debug.log` among it. That is `backend.md` §9's dead-binding elimination and its reachability
  pass, and purity is why neither needs a bundler's `sideEffects` guesswork. **The `Debug.log`
  clause is no longer a licence any build a user can run will spend, and it is kept because it is
  the reason the pass may ask nothing about a right-hand side.** Amended 2026-09-19: dead-BINDING
  elimination is `--release`'s alone — a development build eliminates whole declarations and never
  looks inside a body — and a `--release` build that reaches `Debug` is now refused outright
  (`backend.md` §9's *`Debug` is refused, not pinned*). So the two never meet outside the corpus
  harness, where the hidden `--allow-debug` flag puts them back together to keep
  `run/ReleaseDeadDebug` asserting the rule. What the clause still settles is the shape of the
  pass: it drops a binding on its use count alone and asks nothing about the initialiser, rather
  than testing "does this call a `foreign`?", which is the `sideEffects` guesswork one sentence
  up.
- **Two evaluations that both survive may not be reordered against each other**, and neither may be
  duplicated into a position where it runs more often than the table above says. Inlining
  substitutes a *body*, never an argument expression: an argument is evaluated once, at the call,
  however many times the parameter is mentioned.
- A `let` binding may be sunk into the one branch that uses it, or dropped, but not lifted out of a
  branch into a position where it runs when that branch does not.

When effects land, `transparent-effects-proposal.md` §5 adds one clause on top of this and changes
none of it: a call carrying the `impure` bit may not be eliminated, duplicated, reordered across
another `impure` call, or memoised, *even when its result is unused* — the first bullet above stops
applying to it.

## 7. Scoping and shadowing

| Rule | Detail |
|---|---|
| **irrefutable positions**, and what irrefutable means | **one rule for five positions**: the parameters of a top-level definition, of a `let`-bound function and of a lambda, a `let` pattern, and the pattern of a `let p <- e` — in all five, the pattern must **match every value of its type**. It is Elm's rule, and it keeps exhaustiveness out of everything but `case`. A pattern qualifies when it is a name, `_`, `()`, a record, a tuple of qualifying patterns, one of those with `as`, or **a constructor of a type that has only that one constructor**, whose arguments all qualify (`LetPattern` in §3). So `unwrap (Box x) = x` and `let (Box x) = b` are both legal and `un (Just n) = n` is not. |
| how it is decided, and by whom | **the rule is type-directed, so it is enforced in two places and they cannot disagree.** A literal, a list and a `::` fail it whatever the types are, so the **parser** refuses those, early and cheaply. A **constructor** is admitted by the parser and settled by the **checker**, which runs the pattern through the same usefulness analysis a `case` gets, as a one-row match (`checker.md` §6.6) — so nesting (`Pair (Box a) b`), a type with no constructors, and an opaque imported type all fall out of one algorithm rather than a second single-constructor test that could drift from the first. |
| the two codes | `refutable_let_pattern` for a `let` pattern, `refutable_parameter_pattern` for the other four. **A `<-` bound pattern is a parameter**, because §6.7 desugars it into the callback's parameter; naming it that way is what keeps the parser and the checker from labelling one position two ways. Each code has a parse-time and a check-time source (§10); only the check-time one can name the constructors that are missing. The backend may therefore destructure any of these positions with no test (`backend.md` §4). |
| provenance | Manager decision of 2026-09-18, owner offline; reversible. The alternative considered and rejected was the purely **syntactic** rule — refuse every constructor in these positions, as the parser alone can — which is simpler and needs no checker pass. It was built first and withdrawn: it rejected 40 existing declarations, 27 of them in `core` (`Dict`, `Set`, `Never` unwrapping their one constructor), none of them a real refutability risk, and it left beni with no way to unwrap an opaque newtype except `case`. |
| what binds, and where | every binding introduces a name into a lexical scope: function parameters, lambda parameters, `let` bindings (all bindings of a `let` are in scope in all its bodies and its `in` expression — mutual recursion is allowed), pattern variables in `case` branches and destructuring. Top-level names are all in scope in every body; order does not matter. **Being in scope is not being initialised**, which is the next row. |
| **initialisation**, and what being in scope does not buy | A `let` **value** binding is evaluated where it is written (§6, *Evaluation order*), so its right-hand side may not read a value binding of the same `let` that is written **below** it, nor itself. Nor may it read one **through a `let` function** of that block: naming a function may call it — passing it to `List.map` calls it — so whatever that function's body reads is read here too (`a = f 1` above `f x = x + b` above `b = 2` is the same mistake one hop away, and a function written before `b` but only *called* after it is fine). All three are **`let_forward_reference`**, whose region is the reference that runs too soon and whose message names the binding it reaches and the line it is on. The name still **resolves** — that is what the row above means — so the error is never `unbound_variable`. A `let` **function** is untouched in the other direction: `backend.md` §4 emits it as a hoisted `function` declaration, so naming one above its own line is legal and mutual recursion between `let` functions is unrestricted. A TOP-LEVEL declaration has no written-order rule, because the backend emits constants in dependency order rather than in written order — the next row is what it has instead. |
| **initialisation at the top level** | A top-level **value** is computed once, when the module is loaded, so it **may not be reachable from its own initialiser** (a value with a `where` clause is computed at each use instead, §6 *Evaluation order*, and the rule applies to it unchanged: a `where` is a type annotation and never makes a value a function — only parameters or a `lambda` body do) — directly (`x = x + 1`), through other values (`x = y + 1` with `y = x`), or through the functions those initialisers name (`a = f 1`, `f n = n + b`, `b = a`). That is **`cyclic_value`**, and it is the same mistake as the row above with dependency order in place of written order: `backend.md` §5 emits a constant after everything it depends on, which orders every shape except a circle, and a circle falls back to source order and throws a JavaScript `ReferenceError` at load (§6, *Evaluation order*). There is nothing to reorder and nothing written-order could rescue, so the program is refused. **Order alone is never wrong at the top level**: `first = second * 2` above `second = 3` is fine and must run, which is what makes this rule about cycles and not about position. A **function** is untouched, so mutual recursion between top-level functions is unrestricted; what a function may not be is a step on a circle that a *value*'s initialisation closes. One diagnostic per circle, at the first VALUE on it in source order, naming the whole circle in the order it runs and the first function in between — `import_cycle`'s shape one scope down. Enforced by the **checker** and not by lowering (`checker.md` §6.7), because a `method_call` adds no `refs` edge (§8) and only the checker's dispatch table has that half of the graph. |
| how far the analysis reaches, and where it stops | **conservative, and deliberately so.** Mentioning a `let` function counts as calling it, whether or not it is called. A value whose right-hand side **is a lambda** (`g = \_ -> later`, and `g = f a _`, whose placeholder wraps the whole application in one) is the single exception: nothing runs when it is bound, so it may name a later value, and calling it is what reads that value — so mentioning `g` counts as calling `g`, exactly as for a function, and `h = g ()` above `later` is refused. A lambda anywhere else inside a value's right-hand side is **not** deferred, because whatever it was passed to may call it at once (`List.map xs (\_ -> later)` does), and a nested `let` inside a value's right-hand side is not deferred either. Those two refuse programs that would have run; the alternative is a call graph that has to be right about every higher-order function, and a wrong answer there is a `ReferenceError` a user cannot see coming. **The top-level rule reaches exactly as far, and stops in the same places**: mentioning a top-level function counts as running it, a declaration whose right-hand side is a lambda defers (so it may name a value that is written anywhere, and calling it is what reads that value — `seed = deferred ()` with `deferred = \_ -> seed + 1` is refused), a lambda anywhere else does not defer, and a reference that leaves the module is not an edge at all, because the module graph is a DAG and an import circle is already `import_cycle`. |
| provenance of the initialisation rule | Decided 2026-09-18, owner offline; reversible. The alternative considered and rejected was to **re-sort** a `let`'s bindings into dependency order, the way the backend already sorts top-level constants. It was rejected because §6's table is normative and says `let` bindings evaluate in written order: sorting would make the order of two `Debug.log`s — and, when effects land, the order of two effects — depend on which names one initialiser happens to mention. `core/Dict.beni`'s `mapTree` already depends on the written order it has. The TOP-LEVEL half was decided the same day, on the same terms; there the rejected alternative was to leave it to the backend — emit a circle's members as `let` bindings, or wrap each in a thunk — which buys a program nobody can read a run it cannot explain, and costs every constant an indirection to rescue the shapes that are mistakes. |
| `shadowing`, `duplicate_pattern_variable` | **shadowing is an error**: a binding may not reuse a name already bound in an enclosing scope, including top-level names of this file and names in `exposing` lists. Two sibling scopes may reuse a name (`\x -> …` twice). A pattern may not bind the same name twice: `duplicate_pattern_variable`. |
| order | `let` bindings are in scope throughout their `let`, **except that a `<-` splits the block** (§6.7): a name bound at or before a `<-` is in scope in the whole block, the `<-`-bound name itself only in `rest` because the desugaring puts it inside a lambda, and a `<-` right-hand side may not reference a binding that appears after it (`bind_rhs_forward_reference`). Mutual recursion through a `<-` is therefore not available — what the desugaring means, not a restriction on top of it. |
| type variables | scoped to their annotation; annotations may mention free variables, which are implicitly quantified. A type declaration's parameters must be distinct (`duplicate_type_parameter`); a declared parameter unused in the body is fine; an unbound type variable in a `type` or `type alias` body is `unbound_type_variable`. |

## 8. What lowering produces (BIR), and what it desugars

BIR is the per-file, untyped, name-resolved IR (`fast-compiler.md` §6), a pure function of the
file's bytes: nothing in it depends on another module. Lowering:

| Step | What it does |
|---|---|
| 1 | Resolves every name per §6.2 into one of `local(index)`, `top(index)` (this module), `import_value(module, name)`, `import_ctor(module, name)`, `ctor(index)` (this module), `qualified(alias → module, name)`, and records the set of top-level names each declaration references (§9.1 of the design doc: the DCE graph is a byproduct). |
| 2, ordered | Desugars operators into calls of the corresponding core functions (`a + b` → `add a b`, marked as a `number`-typed builtin — the M2 checker resolves the builtin) — **except the six comparison operators, which become method calls** carrying the operator they were written as, and are resolved by the checker rather than by lowering (§6.5). Then, **in this order**, because the readings disagree otherwise (§6.7): `\|>` into a call whose **first** argument is the left operand (`e \|> f a` → `f e a`, looking through grouping parentheses) and `<\|` into direct application, so every pipeline is a saturated call; then `_` into a lambda over the innermost enclosing application; then `x <- e` into a call of `e` whose last argument is a lambda over the rest of the block. |
| 2, order-independent | `?` into a `try` instruction, which STANDS FOR `case e of Ok v -> v; Err x -> return (Err x)` without being one: the choice between that shape and the `Maybe` one is the checker's (§6.6), and it needs an instruction of its own to hang on. `backend.md` §4 emits the test and the early `return` from it directly. String interpolation into an `interp` node listing chunks and expressions; `if` into a two-branch `case` on `True`/`False`; `.field` accessor functions into one-parameter lambdas. Multi-parameter lambdas stay n-ary; record update, tuples and lists stay as nodes; field access and tuple index stay as nodes (the checker needs them). Calls are n-ary in BIR and always were; what the spec pass changes is that a `call` node is now the *only* reading of an application. |
| 3 | Emits the module's **interface skeleton**: the `pub` names, aliases, types, and constructor lists — lexically computable, no inference (§8.1 of the design doc). |
| 4 | Reports the diagnostics of §5.3, §6.2 and §7. |

**Static dispatch adds two instructions and one declaration field, and takes one edge away** (§0).
An application whose head is a field access lowers to `method_call` rather than to
`call(field_access(…), args)`, carrying the surface operator it came from so the dump can show it;
an application whose head names a constrained type variable lowers to `type_dispatch` (§6.2). A
declaration stores its `where` clause beside its annotation, and step 4 reports the clause's
well-formedness. What lowering **cannot** record is the reference a method call will become — that
is not known until the checker runs, and step 1 is a pure function of the file — so `refs` gains no
edge for one and the checker's dispatch table carries those edges instead, for emission order and
for the future DCE. → `static-dispatch-spike.md` §1.4, §2.4, §7.

A textual dump of BIR (`beni dump --stage=bir`) is part of the CLI contract, so it is testable as an
output rather than an internal.

## 9. Formatting

`beni fmt` produces the canonical form; the corpus is kept in it. Tested properties: **idempotent**,
`fmt(fmt(s)) == fmt(s)`; **structure-preserving**, in that `parse(fmt(s))` and `parse(s)` produce
the same AST modulo positions and the same comments in the same order; **total on valid input**, in
that every file that parses formats, while one with syntax errors is reported and left untouched
(exit 1, no bytes written).

Style is elm-format's, with the changes the syntax forces. The governing rule is elm-format's, not
gofmt's: **the formatter never joins lines the author broke.** For every multi-element construct —
lists, records, record updates, tuples, record types, applications, constructor argument lists,
annotation arrow chains, operator chains — the construct is printed on one line when it fits in 100
columns *and* the source has no line break between its elements; a source break between elements
keeps it vertical even when it would fit; a construct that does not fit is broken. `if`, `case` and
`let` are always vertical. Nonempty closed record bodies of `type alias` and
`schema` declarations, and tagged schema variants, are also always vertical
layout: this overrides the one-line/source-break choice for these bodies.

| Construct | Rule |
|---|---|
| **Whitespace and file shape** | |
| indentation, endings | 4-space indentation. LF line endings. One trailing newline. No trailing whitespace. |
| file shape | module doc block, blank line, imports sorted by module path one per line, two blank lines, declarations separated by two blank lines. Blank lines between `let` bindings and between `case` branches: at most one, kept if present. |
| comments | stay attached to the token they precede; a comment on its own line stays on its own line; a trailing comment stays at the end of its line; doc blocks get a space after `--\|` |
| literals | strings, numbers and chars are printed as written, with no escape normalisation; the formatter never changes bytes inside a literal |
| **Declarations and types** | |
| annotation, `=` | the annotation goes on its own line directly above its definition, with `pub` on the annotation line. `=` goes at the end of the head line and the body on the next line indented 4 — always, for top-level definitions and `let` bindings alike, as elm-format does. |
| declaration record bodies | Always print `type alias Name =` or `schema Name =` with fields on following lines, no braces or commas, even when the input fits on one line. Use four spaces per level, recursively for a whole nonempty closed record field body; put its doc comment directly above it at its column. Preserve field order; schema modifiers have one space between them. Tagged schemas print aligned variant heads and indented payload fields (`schema.md` §2). Empty/extensible records and inline record types retain braces and their existing formatting; ordinary `type` declarations and all record values are unchanged. |
| annotations, non-record `type alias`, `type` | an annotation or `type alias` prints `name :` … on one line if the type fits in 100 columns, otherwise broken at `->` with the arrows leading continuation lines. A `type` declaration puts `=` and each `\|` at the start of their own lines, indented 4. |
| **`where` clauses** (§3) | **never joined to the annotation's line**, however short. One constraint shares the `where` line, indented 4; two or more put `where` alone on a continuation line indented 4 and one constraint per line indented 8, each after the first led by its comma — elm-format's vertical form. **Source order is kept, never sorted**, and a constraint's own type is printed flat, so a clause the author broke is joined; a constraint that does not fit overflows the guide rather than breaking, as a pattern does. The renderer that prints a *type* for a diagnostic or a `.iface` golden is a different thing and prints the suffix on one line, sorted — the two legitimately differ. → `static-dispatch-spike.md` §2.5, §6.6. |
| **function types** | print as `A, B -> C`: one space after each comma, one space either side of `->`. The parameter list is a multi-element construct like any other, so it goes on one line when it fits *and* the author wrote no break between parameters. When a type breaks, the parameters move to the line below `name :` indented 4, one per line with the comma leading each continuation as lists do, and the `->` leads the result's line. |
| **patterns** | **never broken across lines.** A `case` pattern, a definition's parameter list or a `let` pattern that does not fit overflows the 100-column guide rather than wrapping: there is no wrapped form a reader could tell from the `->` that follows. The same holds for the head line of a definition. |
| **Blocks** | no blank line before `then`, `else`, `in`, or between the last binding and `in` |
| `let` | `let` alone on a line, bindings indented 4 relative to `let`, `in` aligned with `let`, body aligned with `let` |
| `case` | `case x of` alone on a line; branches indented 4; `->` at line end; body indented 4 more |
| `if` | `if c then` / `a` / `else` / `b`, always vertical; `else if` chains continue at the same indentation |
| **Expressions** | |
| lists, records, tuples | on one line when they fit and were written on one line, with elm-format's inner spaces — `[ a, b ]`, `{ a = 1, b = 2 }`, `( a, b )`, `{ r \| a = 1 }`, empty ones as `[]`, `{}`, `()` — else elm-format's vertical form `[ a`, `, b`, `]` with the delimiter leading each line |
| operator chains | those that do not fit, or that the author broke, break before the operator, one operator per line, operands indented 4. A chain flattens one precedence level only. |
| applications | the arguments written on the head line stay there when they fit (`div [ class "app" ]`, `Decode.map4 User`); from the first source line break onward every remaining argument goes on its own line indented 4; an application with no source break that does not fit breaks after the function, every argument on its own line. Constructor argument lists in `type` declarations follow the same rule. **`_`** is an ordinary argument that takes ordinary application spacing; it never forces a break. |
| **a trailing `<\|` followed by a lambda** | **does not indent**: the lambda's body continues at the indentation of the line the `<\|` is on. This is the one elm-format rule research 14 found to be the binding constraint in Elm (`14/elm` §0.2). |
| **`<-` bindings** | **print on one line and are never broken**: `x <- f a b`, single spaces around the operator. This is *not* the `=` rule, which always puts the body on the next line: a bind's right-hand side is a call whose last argument is the rest of the block, and breaking after `<-` would indent a body that is not there. A bind that exceeds the guide overflows it, as a pattern does. **`<-` operators are never aligned**, in a block of binds or a mixed one; nothing else in this section aligns anything. |
| **markup** | §11.15, and its governing rule: the formatter never changes what a page says — a run of whitespace between children keeps its newlines and its emptiness, and text is re-indented, never re-flowed |

## 10. Diagnostics named in this document

Every diagnostic has a stable snake_case code, a severity, a file, a `{line, col}` start and end
(end exclusive, same line or later), a title in `SHOUTING CASE` in Elm's style, and a message. The
codes named above are the M1 catalogue; each has at least one fixture under
`tests/corpus/parse/bad/` or `tests/corpus/check/bad/`.

```
invalid_utf8  invalid_module_path  bare_carriage_return  tab_in_source  invalid_character
invalid_number  unterminated_string  invalid_escape  nested_string_in_interpolation
invalid_char_literal  doc_comment_unattached  module_doc_not_at_top
expected_declaration  expected_token  unexpected_token  unclosed_delimiter
annotation_without_definition  pub_on_definition  opaque_not_on_type  case_without_branches
args_after_question  non_associative_chain  negation_with_space  invalid_tuple_index
refutable_let_pattern  refutable_parameter_pattern  nesting_too_deep
placeholder_outside_argument  multiple_placeholders  operator_not_a_function
pipe_rhs_not_application  bind_rhs_not_application  bind_rhs_forward_reference
arrow_in_tuple_element  bind_not_callback
duplicate_import  duplicate_import_alias  duplicate_exposed_name  import_after_declaration  self_import
duplicate_declaration  duplicate_type  duplicate_constructor  shadows_import  duplicate_field
foreign_outside_platform  equatable_outside_core  equatable_not_first_occurrence
unbound_variable  unbound_constructor  unbound_type  unknown_module_alias
question_in_lambda  question_outside_function
shadowing  duplicate_pattern_variable  duplicate_type_parameter  unbound_type_variable
unknown_module  duplicate_module  import_cycle  unknown_import_name  private_name
opaque_constructor  wrong_type_arity  recursive_alias
type_mismatch  rigid_mismatch  infinite_type  kind_mismatch
too_few_args  too_many_args  not_a_function
missing_field  unknown_field  record_not_closed
not_equatable  not_interpolatable  ambiguous_interpolation  ambiguous_tuple
tuple_index_out_of_range  not_a_tuple  try_shape
missing_patterns  redundant_pattern
foreign_bad_shape  foreign_sibling_missing  foreign_export_mismatch  foreign_unbound_reference
missing_main  main_not_program  not_implemented
where_variable_unbound  duplicate_where_constraint
unknown_method  private_method  no_methods_on_shape  missing_where_constraint
method_constraint_mismatch  type_dispatch_needs_annotation  ambiguous_method_receiver
constrained_constant
too_many_inferred_constraints
foreign_arity_mismatch
pattern_budget_exhausted
let_forward_reference
cyclic_value
duplicate_main
debug_in_release
output_path_collision  invalid_entry_file
schema_used_as_type  schema_used_as_value  schema_name_collision
unknown_schema_member  expected_schema  duplicate_schema_key
duplicate_schema_tag  duplicate_schema_modifier  schema_conversion_mismatch
method_needs_annotation
too_many_type_parameters
unknown_output_record
unclosed_element  mismatched_closing_tag  element_as_argument  duplicate_attribute
spread_on_element  spread_not_first  invalid_form_children  vocabulary_outside_platform
no_markup_vocabulary  unknown_element  unknown_attribute  child_not_renderable
void_element_with_children  invalid_keyed  key_not_primitive
unkeyed_for  raw_markup_attribute
markup_restructured  unknown_markup_lowering
unknown_form_attribute  missing_form_attribute  markup_type_in_foreign
untyped_event_attribute
invalid_attribute_name  untyped_srcdoc_attribute
```

**Two of these codes have two sources.** `refutable_let_pattern` and `refutable_parameter_pattern`
are raised by the **parser** for the shapes no type can rescue and by the **checker** for a
constructor whose type has more than one (§7; [`checker.md`](checker.md) §6.6, §8.1). One rule, one
code per position, two places that enforce it — the message differs, because only the checker's can
name the constructors that are missing. `nesting_too_deep` is shared the same way (§5).

**How the catalogue is laid out.** After the front end's catalogue:

| Lines | Added with | What they are |
|---|---|---|
| the next three | name resolution | the module graph and cross-module name resolution |
| then | type checking | type errors, defined in [`checker.md`](checker.md) §8 |
| then | exhaustiveness | the exhaustiveness pair — `missing_patterns` is a `case` with no branch for some possibility, `redundant_pattern` a branch no value can reach ([`checker.md`](checker.md) §6.6), both reported only for a declaration that type-checked, so the patterns they judge are known to be well typed. A third code, `pattern_budget_exhausted`, joined them on the last line of the catalogue |
| the next two | the backend | about the JavaScript boundary rather than beni: the four `foreign_*` codes here are build-time checks of [`boundary.md`](boundary.md) §4, and a fifth is the last line of the catalogue; `missing_main` and `main_not_program` are §5's "`main` is a platform-owned opaque `Program`"; `not_implemented` is what the code generator says about a construct it does not compile yet — a diagnostic rather than a panic, because [`backend.md`](backend.md) §1 ships the language in halves and the missing half has to say so |
| the next five | static dispatch | ten codes appended on 2026-09-18, never inserted, so no line above moved, and an eleventh appended the same day. The first two are reported by lowering, from a `where` clause that names a variable the annotation does not have or the same `(variable, method)` twice; the rest are the checker's, about a method that does not exist, is private, has nowhere to live, was used without being constrained, was constrained twice at different types, needs an annotation to dispatch on a return type, is a constraint that reached an inferred `pub` interface (a `warning`, on by default and only for the root package), survived onto a declaration with no parameters, or — the eleventh — is one of more than 64 constraints an unannotated declaration inferred, which is refused so that neither the interface suffix nor the checker's own bookkeeping is unbounded. Four existing codes are reused rather than duplicated: `not_equatable`, `unbound_variable`, `unexpected_token` and `nesting_too_deep`. → `static-dispatch-spike.md` §10 |
| `foreign_arity_mismatch` | the backend again | `foreign_arity_mismatch`, appended on 2026-09-18 rather than filed with its four siblings above, so that no line moved. It is [`boundary.md`](boundary.md) §4's **check 4**: a sibling export's parameter count must be the declaration's evidence count plus its declared arity, and the two export forms whose parameter list cannot be counted — a bare name and a rest parameter — are refused under the same code (`static-dispatch-spike.md` A.84) |
| `pattern_budget_exhausted` | exhaustiveness again | `pattern_budget_exhausted`, appended on 2026-09-18 rather than filed with the exhaustiveness pair above, so that again no line moved. It is the one code of the three that is about the compiler and not the program: deciding a `case` can cost exponentially much, so the analysis spends a bounded amount of work on it (`--pattern-budget=<n>`), and a `case` it could not decide is **refused** rather than passed over in silence. Silence there was an exit-0 miscompile, because [`backend.md`](backend.md) §7 compiles a `case` to a decision tree with no default arm on the strength of the checker having proved it exhaustive. The message names the budget in force and says the two ways past it: split the match, or raise the flag |
| `let_forward_reference`, `cyclic_value` | M3 again | the two halves of §7's **initialisation** rule, appended on 2026-09-18 and again never inserted. `let_forward_reference` is lowering's, about a `let` value binding that reads one written below it; `cyclic_value` is the checker's (`checker.md` §6.7), about a top-level value reachable from its own initialiser. They are one defect at two scopes: a name that is in scope but has no value yet, emitted as a JavaScript `const` and read inside its temporal dead zone. Both were exit-0 paths from a well-typed program to a `ReferenceError` at load, and both are refusals rather than reorderings — the first because §6's table says `let` bindings run in written order, the second because a circle has no order to be put into |
| `duplicate_main` | the backend again | `duplicate_main`, appended on 2026-09-19, again never inserted. A project with more than one `main` was refused under `missing_main`, whose title — MISSING MAIN — says the opposite of the message printed under it, and whose code told a tool routing on it that a project with two entry points had none. A build is a pair of ONE entry point and ONE platform ([`boundary.md`](boundary.md) §5.3), so two `main`s are two builds, which is a different edit from the one "MISSING MAIN" asks for. The message names both modules and both locations, and which of the two it calls the first is the lower module index — the sorted path, never argument or completion order (CLAUDE.md rule 5). `--library` turns the whole rule off, `missing_main` with it |
| `debug_in_release` | the optimiser | `debug_in_release`, appended on 2026-09-19, again never inserted. It is the **one code in this catalogue a development build cannot produce**: a `--release` build in which any `pub` value of `core/Debug` — `log`, `toString`, `todo`, which is the whole module — survives [`backend.md`](backend.md) §9's reachability elimination is refused, exit 1, nothing written. That is Elm 0.19's rule for `--optimize`, taken by the owner on 2026-09-19 once the optimiser's first release slice had landed, and its reasons are §9's *`Debug` is refused, not pinned*: `Debug.toString` reflects on the runtime representation a release optimiser must stay free to change, a `Debug.log` inside a dead binding is dropped whole by §9 item 1 (§6's *What an optimiser may assume*), and a `Debug` call in a shipped build is almost always an accident. The rule is **reachability** and nothing softer — a `Debug.log` in a declaration the walk drops does not refuse the build, because the build does not ship it. The message names the use sites, at most five and then a count, in module-index then source order (CLAUDE.md rule 5) |
| `output_path_collision`, `invalid_entry_file` | the backend again | `output_path_collision` and `invalid_entry_file`, appended on 2026-09-21, again never inserted. They are one guarantee, [`backend.md`](backend.md) §2's *The output tree does not depend on the file system's case sensitivity*: **a build's output is the same set of files on every file system**. macOS and Windows fold case, so two output paths differing only by case are one file there — the entry file `main.mjs` and the module `Main`'s `Main.mjs` were exactly that, and every program built on a Mac threw `SyntaxError` at load with the build having exited 0. The compiler's reserved output names now begin with `_` (`_main.mjs`, `_core/`, `_platform/`), which a module path cannot reach because every segment is an upper identifier (§5); `output_path_collision` is the backstop for what that does not cover — two modules named `Json.Decode` and `JSON.Decode`, say — and is checked over the files a build is about to write, folded by simple ASCII lower-casing, before the first byte is written, naming both paths and both source files. `invalid_entry_file` is the other half: a platform may now declare the entry file's name in its manifest ([`boundary.md`](boundary.md) §5.2, `"entry"`), and a declared name that does not obey the `_` rule is refused when the platform is loaded, because a manifest key that could reintroduce the defect is worse than a hardcoded name |
| `method_needs_annotation` | static dispatch again | `method_needs_annotation`, appended on 2026-09-23 after the schema codes, again never inserted. Under checker v1 (the default until the cut-over, 2026-09-27): a comparison — or any method use — on a module's own type needs that module's method, the method has no annotation, and its binding group is checked after the use, so it has no type there yet. It was a silent wrong answer: the site compiled to `undefined`, or a derived comparison's part to a structural walk that ignored the method. The message says which method to annotate → `static-dispatch-spike.md` §10.12. **Amended 2026-09-26: checker v2 never emits it for that ordering case** — the use checks the method's group nested at the use ([`checker-v2.md`](checker-v2.md) §10.2) — **and emits it only for [`checker-v2.md`](checker-v2.md) §11.2's case**, a derived context entry indexed by a type parameter that depends on an in-flight inferred method (`checker-v2.md` §21.1). The code stays in this catalogue |
| `too_many_type_parameters` | the checker rewrite | `too_many_type_parameters`, appended on 2026-09-25, again never inserted. It is lowering's, at the 65 536th parameter of a `type`, `type alias`, `foreign type` or `schema` (whose parameters go through the same lowering): an arity is a 16-bit count in the interface record ([`checker-v2.md`](checker-v2.md) §14.2), and a count that saturated there imported the type at the wrong width — an 8-bit count was exactly that at 255, and it built a program that threw a `TypeError` once run. A refusal and not a clamp, because the clamp is the defect. The declaration keeps its first 65 535 parameters, so a body naming a later one is also an `unbound_type_variable` |
| `unknown_output_record` | the backend again | `unknown_output_record`, appended on 2026-09-28, again never inserted. `--out` holds a `_manifest.txt` that is not beni's record — its first line is not `beni-manifest 1`, or a line is not `<16 hex digits> <path>` — and the build would otherwise overwrite it ([`backend.md`](backend.md) §2, *The output directory holds what the last build wrote*). Reported against that file, before the first byte is written, and nothing is written. *Amended 2026-09-29:* the same code refuses a symbolic link on the way to any path the build writes in `--out` — the manifest, an output, or a directory it writes into — which beni never makes and would otherwise write through, named the same way |
| the seven before the last | markup | twenty codes appended on 2026-09-29 with the markup specification, again never inserted, on the first six of these lines; §11.17 says which phase reports each. *Revised the same day by the specification review, before anything was built:* three were renamed because `Show` shares them with `For` (`invalid_for_children` → `invalid_form_children`, `invalid_for_keyed` → `invalid_keyed`, `for_key_not_primitive` → `key_not_primitive`); the warning `html_entity_in_text` was withdrawn with the rule it enforced, because text now decodes character references (§11.4); and the seventh line was appended — `unknown_form_attribute` and `missing_form_attribute` for a built-in form's own attributes (§11.9, §11.18), and `markup_type_in_foreign` for a `foreign` that would build or read one lowering's representation of markup under another (`boundary.md` §9.3). Two are `warning`s, on by default for the root package only — `unkeyed_for` and `raw_markup_attribute` — and each names the escape that silences it. `markup_restructured` is the one code a platform's markup lowering reports rather than the compiler (`boundary.md` §9.4.7), and `unknown_markup_lowering` is a manifest's (`boundary.md` §9.2) |
| `untyped_event_attribute` | markup again | appended on 2026-09-29, when markup was typed, again never inserted: the owner's refusal of a quoted attribute name beginning with `on`, in any case (§11.5). `"onclick"={text}` would write an event handler the page runs as script, the one route besides `raw` by which a `view` could inject one, so it is an error rather than a warning — a guarantee (rule 7), with the typed event attribute as the escape. Reported at the quoted name, and its hint names the events the element accepts whose name is the quoted one in another case |
| the last line | markup again | appended on 2026-09-29, again never inserted, with the owner's decision to close the escape's other script sinks (§11.5). `invalid_attribute_name` is lowering's: a quoted name holding whitespace, a quote, `=`, `/`, `>` or a control character, or empty, which a page would end early and follow with an attribute the vocabulary never sees (`"x onclick"`); `untyped_srcdoc_attribute` is the checker's, beside `untyped_event_attribute`: a quoted `srcdoc`, in any case, a whole document the page runs, scripts included |

> **Checker v2 (2026-09-24).** `method_needs_annotation` is retired as an ordering refusal by the owner's
> decision that an own untyped method is checked at its use. A use of a module's own untyped method checks that method's group nested at the moment
> of the use instead ([`checker-v2.md`](checker-v2.md) §10). The code survives for one non-ordering
> case: a derived context entry, indexed by a type parameter, that depends on an in-flight inferred
> method (§11.2, as amended in §21.1).
> The row above was amended on 2026-09-26; the code is never removed from this catalogue.
> **Superseded** for the ordering case since the cut-over
> (2026-09-27): v2 is the default checker, and v1's refusal survived only under `--checker=v1` until
> both were deleted the same day.

**The three generic syntax codes**, all carrying Elm-style prose — what the parser was in the middle
of, what it saw, and what it expected, e.g. *I was parsing the branches of this `case` and ran into
`else` at column 9, but the branches of this `case` start at column 13.*

| Code | When |
|---|---|
| `expected_token` | exactly one token can come next: `)`, `]`, `}`, `->`, `of`, `then`, `else`, `in`, `=`, `:` |
| `unexpected_token` | the start of a construct — an expression, a pattern, a type, an exposing entry — was needed and the token cannot start one. A misaligned `let` binding or `case` branch — a token inside the block, at a column other than the first sibling's, that could start a binding or branch — is reported with this code, quoting both columns, and then parsed as a sibling, so one misalignment yields one message. A token that cannot start a sibling ends the list silently and the enclosing construct decides. |
| `expected_declaration` | the top-level form of `unexpected_token` |

**Depth limits**, every one reporting `nesting_too_deep`:

| Limit | Where | Rule |
|---|---|---|
| nesting deeper than 4096 levels | the parser, over expressions, types and patterns | reported at the point where the limit is crossed; the file is otherwise parsed. It is the one limit the parser imposes, so hostile input cannot overflow the stack. |
| 512 levels | the type checker reading a type, reported at the declaration (`checker.md` §5) | lower on purpose — an annotation is one tree among many and reading it also spends a level per alias expansion — so a file the parser accepts can still be refused here. What the checker may not do is refuse it silently: past the limit the type is poisoned, and a poisoned type unifies with anything, so a declaration truncated without a message would be a hole a caller's mistake falls through. |
| charged per declaration | the iteratively built spines — an operator chain, an access chain, a `?` chain | they hold their charge until the declaration ends, so a declaration whose chains total more than 4096 links is refused even when no single path is that deep. Accounting each spine exactly would mean a depth per node through the AST — four bytes on every node, to buy a case no real program reaches; revisit it if one does. |
| 2 048 units and 128 scopes of emitted JavaScript | `build`, per top-level declaration, after lowering (`backend.md` §4, *Emitted JavaScript nests only as deep as the source*) | a declaration whose JavaScript would nest past what browser engines parse — about 512 nested calls, or 128 nested scopes, SpiderMonkey's own limit being 251 — is refused at the declaration, naming both measures, and nothing is written. Every form the source writes flat is emitted flat whatever its length (lists, operator chains, pipelines, `else if` chains), so only nesting the program writes itself reaches it: functions inside functions (about 120, or a `view` with a `List.map` at every level about 65 deep), or `case`s and `if`s inside one another through the arguments of calls. `check` does not report it; only `build` lowers. |

## 11. Markup (JSX)

*Specified 2026-09-29; not built.* This section is the surface of markup: what a program may
write, what it means, and what is refused. It takes as given the owner's answers of 2026-09-29 in
[`plans/browser-decisions.md`](../../plans/browser-decisions.md) — W25 (The Elm Architecture), W26
(compiled templates, never a virtual DOM), W27 (the identity promise, §11.12), W28 (Solid 2's
render loop), W29–W34 (Solid 2's answers for JSX), the *JSX compiler*, *JSX targets* and *Layers*
rows, research 36's seven questions, and the *Spec review answers* row — and it copies Solid 2's
JSX wherever those answers point to it ([`research/36`](research/36-solid-jsx-compiler-for-beni.md),
[`research/27`](research/27-solid-2-as-built.md)). Where beni departs from Solid 2, the rule says so
and says why.

*Revised 2026-09-29, after the specification review.* The owner's answers to it changed four things:
text decodes HTML character references and collapses whitespace exactly as Solid 2 does (§11.4);
the keyed `Show` is kept (§11.18); `class` and `style` take typed lists, Solid 2's object and array
forms (§11.19); and the lowering interface is stable under additive change (`boundary.md` §9.4.6).
The review's findings are fixed in place: the row function may be any function (§11.9), a vocabulary
may declare markup primitives, which is how `Html.map` and `Html.text` serve every lowering
(§11.13–§11.14), and the evaluation rows are now in §6's table (§11.11).

Four other documents carry the rest, and each owns its part once:

| Part | Owner |
|---|---|
| lexer modes, tokens, parser, recovery, formatter mechanics, BIR | [`frontend.md`](frontend.md) §9 |
| typing against the platform's vocabulary, hole kinds, what the interface publishes | [`checker-v2.md`](checker-v2.md) §25 |
| platform layering, the vocabulary declarations' contract, the markup lowering interface | [`boundary.md`](boundary.md) §9 |
| what the `dom` and `ssr` lowerings emit, the runtime each needs, and the browser's render loop | [`backend.md`](backend.md) §15 |

### 11.1 What markup is

A markup expression — an **element** `<div class="a">…</div>`, a **fragment** `<>…</>`, a
**component** `<TodoItem todo={t} />`, a **list** `<For each={rows}>…</For>` or a **keyed
conditional** `<Show when={x} keyed>…</Show>` — is an ordinary expression of the platform's markup
type, `Html msg` in the browser platform. It may appear wherever an operand may start (§11.2), be
bound by `let`, returned from a `case` branch, stored in a list or a record, passed to a function and
returned from one. It is a value like any other; what is special is only what the compiler can do
with it, because the markup is syntax the compiler reads rather than calls it must guess about.

**The language knows no HTML vocabulary.** Which elements exist, which attributes each takes and at
what type, which events exist and what they carry — all of it is declared in beni source by a
platform package (§11.14), never known to the compiler. What the language owns is the shape — tags,
attributes, children, holes — the typing rules against whatever vocabulary is declared, and the
guarantees. **One HTML table is the language's**: the character references that text and quoted
attribute values decode (§11.4). That is JSX's text syntax, the way `\u{…}` is a string's, and not a
fact about any page — it is why the table lives in the compiler and not in a platform. What markup
compiles to is the platform's markup lowering (`boundary.md` §9): templates in the browser, strings
under Node, anything a platform author writes.

### 11.2 Where markup may start: the operand-start rule

`language.md` §6.5 has no prefix `<`: an expression may not begin with an operator. So at the start
of an operand, `<` is an error in every program written before markup existed, and the position is
free. **A `<` opens markup exactly when the token before it cannot end an operand, and the byte after
it is an ASCII letter or `>`.** Otherwise it is the operator `<`, or the longest-match `<=`, `<-`,
`<|` as today.

| Before the `<` | Reading | Example |
|---|---|---|
| a token that can end an operand: a name, a literal, `_`, `)`, `]`, `}`, a string's closing `"`, a multiline string's line, `?`, a `dot_lower`/`dot_index`, and the end of a markup expression (`/>`, or the `>` of a closing tag) | the operator | `a <b`, `f a <b`, `(x) <y` — comparisons, exactly as today |
| anything else: `=`, `(`, `[`, `{`, `,`, `->`, `<-`, `if`, `then`, `else`, `in`, `of`, `case`, any binary operator, `<|`, `|>`, the start of a markup hole or attribute | markup | `x = <b />`, `f (<b />)`, `[ <li />, <li /> ]`, `\r -> <tr />`, `f <| <b />` |

Between the tags of an element, `<` always begins a child or the closing tag, and must be followed by
a letter, `/` or `>` (§11.4); inside an opening tag it is an error.

The consequence is one restriction, and it is the one `language.md` §3 already has for `let`, `if`,
`case` and lambdas: **markup is an operand, never a bare application argument.** `f <div />` is `f`
compared with `div` and then a syntax error; write `f (<div />)`, `f <| <div />` or pipe it. The
diagnostic for the shape — an `<` that abuts a name and is followed by what can only be markup — is
`element_as_argument`, and it says exactly that.

Inside a string interpolation `${…}`, `<` is always the operator: markup is not interpolatable
(§2.6), and admitting it there would need the lexer's string mode to nest, which §2.6 refuses for
the same reason it refuses a nested string.

### 11.3 Grammar

```
Atom        := … | Markup                                        -- §3; operand start only (§11.2)
Markup      := Element | Fragment
Element     := '<' TagName Attr* '/>'
             | '<' TagName Attr* '>' Child* '</' TagName '>'      -- names equal, §11.5
Fragment    := '<' '>' Child* '</' '>'
TagName     := markup_name                                       -- div, my-widget, TodoItem, Ui.Card, Card.header, For, Show
Attr        := AttrName ('=' AttrValue)?                         -- a bare name means `={True}`
             | string '=' AttrValue                              -- the untyped escape, §11.5
             | '{' '...' Expr '}'                                -- spread; components only, §11.8
AttrName    := markup_attr                                       -- class, aria-label, xlink:href, onClick, type
AttrValue   := string                                            -- a string literal, §2.6, whose literal text decodes references (§11.4)
             | '{' Expr '}'
Child       := markup_text                                       -- bare text, §11.4
             | '{' Expr? '}'                                     -- a hole, §11.6; empty is a comment holder
             | Markup
```

**A tag name is classified by its spelling**, which is Solid 2's rule (research 36 §2.5) with the
characters beni has:

| Spelling | Is | Resolves in |
|---|---|---|
| lower-case first letter: `div`, `input`, `my-widget` | an **element** | the platform's vocabulary (§11.5) |
| capital first letter, no lower-case segment: `TodoItem`, `Ui.Card` | a **component**, the module's `view` | the module aliases of this file (§11.8) |
| a module path then a lower-case name: `Card.header` | a **component**, that value | the module aliases of this file (§11.8) |
| exactly `For` or exactly `Show` | a **built-in form**: the list (§11.9) or the keyed conditional (§11.18) | the language; a module named `For` or `Show` is a component only by a call |

The closing tag must repeat the opening tag's name byte for byte (`mismatched_closing_tag`
otherwise, recovered by accepting it, so one mistake is one message). A self-closing tag and an
opening tag followed at once by its closing tag are the same tree; the formatter writes the first
(§11.15). A fragment has no attributes.

**A comment inside markup** is an ordinary `--` comment in a hole or between attributes. It runs to
the end of the line (§2.3), so a hole that holds only a comment closes on a later line —
`{-- note` then `}` — and `{-- note}` is an unclosed hole, whose message says why (`frontend.md`
§9.5). Between tags, `--` is text.

### 11.4 Text children

Text between tags is written **bare**, as in Solid 2 (W30): `<p>Hello, {name}!</p>` is a text run,
a hole and a text run. A text run is every byte from the `>` or `}` before it to the next `<` or
`{`. Three characters may not stand in text, each `unexpected_token` with the spelling that writes
it: `>` (`{">"}`) and `}` (`{"}"}`), which is the JSX specification's own rule, and a `<` that is not
followed by a letter, `/` or `>` (`{"<"}`), because `a < b` in text would otherwise read as the start
of a tag. `--` in text is text, not a comment, and `'` and `"` are ordinary characters. A tab is
`tab_in_source` there as everywhere, and another control character `invalid_character` (§2.1).

**A text run is read in two steps, exactly as Solid 2's compiler reads it**
(`references/dom-expressions/packages/compiler/src/shared/utils.rs:210-242` and `:267-269`, called in
that order at `shared/fragment.rs:24`, `shared/component_children.rs:66` and
`ssr/transform.rs:1085`):

1. **Whitespace is collapsed** by `trim_jsx_text`, a port of Babel's rule, where *whitespace* is
   every character with the Unicode `White_Space` property — Rust's `char::is_whitespace`, the 25
   characters U+0009–U+000D, U+0020, U+0085, U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F,
   U+205F and U+3000 — and only `\n` splits lines:
   1. if the run contains a `\n`, split it at every `\n`; remove the leading whitespace of every line
      but the first; drop every line that is now empty or all whitespace, the first included; join
      what is left with one space;
   2. replace every run of whitespace with one space;
   3. a run that is now empty contributes no child.
2. **Character references are decoded**, by the WHATWG HTML rules for text outside an attribute
   (HTML's *character reference state*), which is what `htmlize::unescape` implements for Solid:
   every named reference of HTML's table of 2 231 names, with or without its `;` where HTML accepts
   it (`&copy;` and `&copy` are both ©, and of two names that match, the longer wins: `&notit;` is
   `¬it;`); decimal and hexadecimal references (`&#169;`, `&#xA9;`), `&#0;`, a surrogate or a value
   past U+10FFFF becoming U+FFFD and U+0080–U+009F mapping through HTML's windows-1252 table
   (`&#x80;` is €); anything that is no reference (`AT&T`, `&nosuch;`) left as written.

So `<li>\n    <b>x</b>\n    done\n</li>` has two children, `<b>x</b>` and `done`; `<b>a</b> <i>b</i>`
keeps the space between its two elements, because that whitespace has no newline in it; and
`Fish &amp; chips` is `Fish & chips`. **The order is the point**: a no-break space typed as a
character is whitespace and collapses like any other, while `&nbsp;` is decoded *after* collapsing
and survives — which is how HTML authors already write a space that must not move. A literal
reference is written as a hole holding a string, `{"&amp;"}`, since a hole's value is never decoded.

**The decoded text is what every lowering receives** (`frontend.md` §9.7), so what a page says does
not depend on which lowering compiles it: the `dom` lowering re-escapes it into its template and the
`ssr` lowering into its string (`backend.md` §15.3, §15.6), and both yield the same characters. The
table is the compiler's, generated from WHATWG's `entities.json` (`frontend.md` §9.7), and it is the
one piece of HTML the language knows (§11.1).

The formatter may re-indent a text run's continuation lines and nothing more (§11.15); rules 1–3
are what make that safe, and they are why it cannot re-flow text.

### 11.5 Elements and attributes

**An element's tag resolves in the vocabulary of the build's platform** (§11.14, `boundary.md` §9)
— an exact declaration first, then the most specific pattern declaration (`"*-*"` for custom
elements, say). There is no import: markup in a module is an implicit use of the vocabulary module,
and a program whose platform declares no vocabulary cannot contain markup (`no_markup_vocabulary`,
which names `--platform` when none was given). An undeclared tag is `unknown_element`, with "did you
mean" over the declared names.

**An attribute resolves in the element's declarations**: one declared for that element (`on
"input"`) before one declared for every element, and an exact name before a pattern (`"aria-*"`,
`"data-*"`). An undeclared attribute is `unknown_attribute`, with "did you mean" over the names this
element accepts. The name is a markup name: letters, digits, `_`, `-`, and `:` after the first
character, so `aria-label`, `data-row-id`, `xlink:href`, `type` and `as` are all attribute names —
keywords are not keywords inside a tag. There are no namespaced prefixes (`on:`, `attr:`, `prop:`,
`use:`): Solid 2 keeps only `prop:` (research 36 §2.11), and here a platform declares a property
write by declaring the attribute so (§11.14).

| Written | Means |
|---|---|
| `class="row"` | the declared attribute `class` with the constant `"row"` |
| `title="Fish &amp; chips"` | the constant `"Fish & chips"`: the literal text of a quoted value decodes references (below) |
| `class="row ${size}"` | a string literal with interpolation (§2.6): a dynamic `String` |
| `tabindex={0}` | a constant too: a hole holding only a literal (below) |
| `tabindex={n}` | the value of `n`, checked against the declared type |
| `disabled` | `disabled={True}` |
| `class={[ ( "row", True ), ( "danger", sel ) ]}` | a class list (§11.19) |
| `"hx-get"="/items"`, `"hx-get"={url}` | **the untyped escape**: a quoted name is written as a plain attribute with a `String` value and is never checked against the vocabulary — except that a name beginning with `on`, in any case, is `untyped_event_attribute`: it would write an event handler the page runs as script, and the typed event attribute is the way to handle an event; and a name that is `srcdoc`, in any case, is `untyped_srcdoc_attribute` (*amended 2026-09-29*) |

**The value's type is the declared type**, and the declared types a lowering is required to write
are `String`, `Int`, `Float`, `Bool` and `Maybe String`, plus the two list forms `class` and `style`
admit (§11.19; `boundary.md` §9.3). A `Maybe` attribute is removed on `Nothing`. The two syntactic
forms are sugar with a fixed reading, and `{e}` is an expression like any other:

| Form | Type |
|---|---|
| a quoted value, `a="…"` | `String`; for a `Maybe String` attribute, `Just` of it — the one place a string is read as a `Maybe`, because `a="x"` can only mean "present, with this text" |
| a bare name, `a` | `Bool`, `True` |
| `a={e}` | whatever `e` has, unified with the declared type: `{"x"}` for a `Maybe String` attribute is a `type_mismatch`, as it would be anywhere |

**A constant attribute** is one the compiler can write into a template, so it costs nothing at run
time: a quoted value without interpolation, a bare name, or a hole holding only a number literal
(negated or not), a string literal without interpolation, or `True` or `False` (the prelude's).
Everything else is dynamic. Which it is changes nothing about typing; it is what `frontend.md` §9.7
records and a lowering uses.

**A quoted attribute value is a beni string whose literal text also decodes character references**,
by §11.4's step 2 — Solid 2's rule, which decodes every JSX attribute string
(`shared/attr_plan.rs:374`) and every string prop (`shared/component.rs:87`) with the same function
as text. Escapes and `${…}` work as in any string; a reference is recognised only in the characters
the source spells, so a character an escape produces never begins one (`"\u{26}amp;"` is the five
characters `&amp;`), and nothing an interpolation yields is decoded. Whitespace is **not** collapsed in
an attribute value, as in Solid. `class="btn ${size}"` is the idiom this form buys. A `{"…"}` value
is an ordinary expression and decodes nothing, which is the way to write a literal reference.

**The escape's other script sinks are closed** (*amended 2026-09-29*, the owner's decision; Elm's
rules, research 24 §6.3). A quoted name is an attribute name and nothing more: one that holds
whitespace, a quote, `=`, `/`, `>` or a control character, or is empty, is
`invalid_attribute_name` — a page would end the name there and read what follows as another
attribute, so `"x onclick"` would write an event handler. A quoted `srcdoc`, in any case, is
`untyped_srcdoc_attribute`: it writes a whole document the page runs, scripts included, and a
frame's document is loaded from a URL instead. And a quoted `href`, `src`, `action`,
`formaction` or `xlink:href`, in any case, is a URL like the attribute a vocabulary declares
`url`: a lowering refuses a script URL in it exactly as it does there (`checker-v2.md` §25.7
records which escapes are URLs, `backend.md` §15).

**Each attribute may be written once** (`duplicate_attribute`). *Amended 2026-09-29:* on an
element, names are compared as HTML compares them, ASCII case folded, so `title` and `"TITLE"`
are one attribute written twice; a component's props are record fields and compare exactly.
**Order is source order**, for
evaluation (§11.11) and for what a lowering writes, attributes and events interleaved as written —
`<input type="range" value={v} />` sets `type` before `value`, which a range input needs.

**An element with no children, whose declaration says `void`, is written self-closing**; giving one
children is `void_element_with_children`. Which elements the HTML parser itself treats as void is a
different fact and belongs to the `dom` lowering (research 36 question 2, accepted; `backend.md`
§15.3).

**Spread on an element** (`<div {...attrs}>`) is **not in this specification** and is
`spread_on_element`. It is a capability that is **deferred, not refused**: Solid 2 moves every
attribute of a spread element to run time (research 36 §2.6; about 4 900 brotli bytes of runtime,
research 27 §6.11 D), and the form that keeps templates — a record of known attributes spread in —
needs a design of its own. An element whose tag is chosen at run time (`Html.node`, Solid's
`<Dynamic>`) waits on the same design, because its attributes cannot be typed against a row either.

### 11.6 Holes: what a `{…}` child may hold

A hole's expression must have one of these types, which the checker knows before any code is
emitted, so the compiler chooses the update and **no conversion is ever written** (research 28 §4.4):

| Hole type | Renders as |
|---|---|
| `String`, `Int`, `Float`, `Bool`, `Char` | a text node, stringified exactly as `"${e}"` stringifies it (§2.6) |
| `Html msg` | the markup it holds |
| `Maybe (Html msg)` | the markup, or nothing |
| `List (Html msg)` | the markups in order, matched **by position** from one render to the next |

Anything else is `child_not_renderable`, naming the type and the five shapes. The set is closed on
purpose: every hole then has a known update, so nothing renders through a generic conversion the
optimiser is free to change (the `debug_in_release` argument, `backend.md` §9). **A `List` hole is
positional and is never warned about**: it is the explicit spelling of "these are positions", and a
list whose rows move is written with `For`, which has keys (§11.9). An empty hole `{}` — or one
holding only comments — contributes nothing and exists to carry a comment. A hole's string is never
decoded (§11.4).

`if` and `case` are expressions, so they work in a hole with no rule of their own: `{if done then
"✓" else ""}` is a `String` hole and `{case status of …}` an `Html msg` hole whose branches are
separate markups — two branches are two templates, so a changed branch remounts and an unchanged one
patches, which is Solid's non-keyed `Show` with no `memo` (research 36 §4.5). **So there is no
non-keyed `Show`, and no `Switch` or `Match`**: Solid needs them because a Solid component runs once
and JavaScript is eager (research 27 §8.2), and a beni `view` re-runs with the expressions already in
the language (`plans/browser-decisions.md`, *What is forced*). **The keyed `Show` is kept** (the
owner's answer), because it says something `if` and `case` cannot: remount when a value's identity
changes (§11.18).

### 11.7 Events

An event attribute — `onClick`, `onInput`, whatever the vocabulary declares with `pub event` — takes
a **handler**, which is one of two things (research 36 question 5, accepted):

| Handler | Type | When the event fires |
|---|---|---|
| a message, `onClick={Clicked}` | `msg` | the message is sent |
| a function to one, `onInput={Typed}` | `payload -> msg` | it is called with the event's payload, and its result is sent |

`msg` is the element's own message type, shared by every handler and every `Html msg` hole in the
markup; `payload` is the type the declaration names — a `String` for an `onInput` whose platform
extracts the input's value, the platform's raw event type otherwise (§11.14). **Which form a handler
is, is decided by its type**: a function type is the second form and anything else the first; a
handler whose type is still a variable when its declaration is generalised is the first. So a
message that is itself a function is written as a lambda returning it, `onClick={\_ -> f}` — the one
corner the rule leaves, and it is loud, never silent (`checker-v2.md` §25.4).

A handler returns a message and does nothing else. **Once effects land, a handler is `sync`** (W8)
and may call the event's `preventDefault` itself, which is Solid 2's spelling (W34); until then an
event's `preventDefault` and `stopPropagation` are facts of its declaration (§11.14), so a platform
can offer the forms a program needs. Delegation is also the declaration's fact, never the
program's: one listener on the document for the events a platform delegates, a listener on the
element for the rest, exactly as Solid 2 does (research 36 §2.7). A message produced inside markup
that `Html.map` wraps is passed through the map's function on its way out (§11.13).

### 11.8 Components

**A capitalised tag names a module, and the component is that module's `view`; a module path
followed by a lower-case name is that value.** `<TodoItem todo={t} done />` means
`TodoItem.view { todo = t, done = True }`, and `<Card.header title="x" />` means
`Card.header { title = "x" }`. The module part resolves through this file's imports exactly as a
qualified name does (§6.2), so `import Ui.TodoItem as TodoItem` is what makes `<TodoItem …/>`
reachable.

Why this and not the alternatives:

- **A capitalised tag naming a value in scope**, JSX's reading, is not available: a capitalised
  name in a beni expression is a constructor (§6.2), no value can have one, and giving the tag
  position a third reading of capitals is the cost research 28 §6.1 rejected.
- **A lower-case tag naming a function** (`<todoItem …/>`) contradicts W31, which the owner answered
  with Solid 2's rule: lower case is an element.
- **The module's `view`** is ReScript's shape (`<Foo.Bar/>` is `Foo.Bar.make`, research 28 §6.1), it
  needs no new namespace, because a capitalised name before `.` is already a module alias, and it
  gives a component's props type and helpers a home. **The member form `<Card.header …/>`** is what
  Solid 2 does with a member expression (a component, research 36 §2.5), and it removes the
  "one component per module" cost that research 28 charged the module form with.

**The callee must take exactly one parameter, a record, and return the platform's markup type.**
Each attribute is one field, named as written — so a component's attribute names are lower
identifiers, and a hyphenated one is `unexpected_token` — and a bare attribute is `True`. A quoted
value is a `String` with its references decoded, as on an element. **The record is closed**, exactly
the fields written, unless the first attribute is a spread:
`<Card {...Card.defaults} title="x" />` means `Card.view { Card.defaults | title = "x" }`, record
update over the spread value — which, unlike a written `{ r | … }` (§6.3), may be any expression —
and that is how a component has optional props without a new language
feature (research 28 §6.3). A spread anywhere but first is `spread_not_first`, and a second is the
same error; the rule-7 check is in §11.16. A missing prop is the record's own `missing_field`, an
extra one `unknown_field`, both with the checker's existing "did you mean".

**Children are the `children` field**, and what it holds depends on what is written between the
tags:

| Between the tags, after §11.4's trimming | `children` is |
|---|---|
| nothing | absent: the component's type decides whether that is `missing_field` |
| exactly one hole `{e}` | `e` itself, at whatever type `e` has — a render function included |
| anything else | one `Html msg`: the children as a fragment |

So `<List>{\item -> <li>{item}</li>}</List>` passes a function, and `<Card><h1>Hi</h1>text</Card>`
passes one markup value. Writing `children` as an attribute as well as between the tags is
`duplicate_attribute`.

**Children are evaluated before the call, like every argument** — forced, not chosen: beni is strict
(§6, *Evaluation order*), and Solid's lazy `get children()` getter is laziness a strict language has
no counterpart for. Nothing a program computes can tell the difference, because evaluation is pure;
what it costs is work a component that does not show its children still pays. A component that wants
its children evaluated only when it shows them takes a function and is written with one hole:
`<Lazy>{\() -> <Expensive />}</Lazy>`.

**A component call may be skipped.** When every prop is identical (`===`, not `==`) to the previous
render's, the platform may reuse the previous result instead of calling the component again, because
a beni function given the same arguments returns the same value (research 36 §4.3). That is the
`lazy` W27 retired, applied at the boundary the program already drew; §11.11 says what it means for
evaluation. A message built during the render (`onPick={Picked item.id}`) is a new value each time
and defeats the skip, and so does a whole record passed where the component reads one field of it
(`model={model}` where `selected={model.selected}` would do); comparing such props structurally is
not done (research 36 question 7, accepted: identity first, measured before anything more).

### 11.9 Lists: `For`

```elm
<table>
    <For each={model.rows} keyed={.id}>
        {\row -> <tr class={rowClass model row}><td>{row.label}</td></tr>}
    </For>
</table>
```

`For` is Solid 2's list form (W33; research 27 §7.1, research 36 §4.4). **Its attributes** are
`each`, the list — `List a`, and `Array a` once `core/` has one (W35) — which is required; `keyed`,
the keying mode; and `fallback`, an optional `Html msg` shown when the list is empty. An attribute
`For` does not take is `unknown_form_attribute`, with "did you mean" over the three (`key=` is
answered with `keyed=`), and a missing `each` is `missing_form_attribute`. Its only child is one hole
holding the **row function**, of type `a -> Html msg` or `a, Int -> Html msg`, whose second parameter
is the row's current position. Anything else between the tags is `invalid_form_children`.

**The row function is any expression of a function type**, as any argument is: a lambda
(`{\row -> <tr>…</tr>}`), a function (`{viewRow}`), a placeholder application (`{viewRow model _}`,
which is a lambda, §6.7) or any other expression. Which of the two types it has is decided by its
type — by the lambda's parameter count when it is one — and a function of another arity is the
ordinary `type_mismatch`. What the shape changes is only what a lowering can compile away
(`backend.md` §15.5): a lambda whose body is markup — after any `let` bindings it opens, so
`\r -> let label = … in <tr>…</tr>` counts — becomes a row compiled in place, and anything else is
called per row and its result placed like any markup value (§11.6).

**The keying mode says which DOM rows survive a change**, and it is Solid 2's three modes on one
`keyed` attribute (research 27 §7.1):

| Written | Mode | A row keeps its DOM — its focus, its text selection, its scroll — when |
|---|---|---|
| `keyed={f}`, `f : a -> k` | by key | its key is in both lists, wherever it moved |
| `keyed={False}` | by position | it is at the same position; the item there may be different |
| `keyed={True}`, or bare `keyed` | by reference | the very same item value is in both lists |
| *(absent)* | by reference | as the row above |

**A key must be a type whose `==` is identity on the JavaScript value**: `String`, `Int`, `Float`,
`Char`, `Bool`, `Order` — the types whose `eq` is `strict_eq` in `static-dispatch-spike.md` §3.2's
table (an `Int32` key is written `Int32.toInt k`).
Anything else is `key_not_primitive`, because a record key compared by identity would treat two
equal keys as two rows, which is a silent wrong answer; `keyed={\r -> r.id}` or a `String` built from
the record is the way through. `keyed` given as anything other than a key function or a literal
`True` or `False` is `invalid_keyed`. **Two items with the same key are both rendered**: rows are
matched by the key and the item's rank among the items sharing it, so a duplicate is never dropped
and never shares a row.

**By reference is Solid's default, and it misbehaves in an immutable language.** A row whose record
was updated is a new object, so under reference keying it is a new row: the old one is destroyed and
a new one built, and focus and input state inside it are lost. Solid does not see this because its
stores keep a proxy's identity across edits (research 36 §0 item 5, §4.4). So **a `For` whose item
type is not a primitive-`eq` type and that does not say how it is keyed is the warning
`unkeyed_for`** (research 36 question 4, accepted), which names `keyed={…}` and `keyed={True}` as
the two ways to silence it. An explicit `keyed={True}` is a statement and is never warned about.
**Over a primitive-`eq` item type the absent mode is not a silent default**: identity on a `String`
or an `Int` *is* equality, so by reference is by value there — the same rows survive as under
`keyed={\x -> x}` — and there is no second mode for the silence to hide.

**A row may be skipped**: when its item, its position (if the function reads it) and its **inputs**
are all identical (`===`) to the previous render's, the platform keeps the row as it is without
calling the function (§11.11). A row's inputs are what its function reads from outside the item:

| Row function | Its inputs |
|---|---|
| a lambda | for each local it uses from the enclosing scope, the **fields it reads** from that local — `model.selected`, not `model` — when every use of the local is a field access, or an argument to a function of the same module that itself only reads fields of that parameter (`rowClass model row` reads what `rowClass` reads); the local itself otherwise. A top-level value is not an input: it is the same on every render |
| anything else | the function value itself |

That is research 29's *field dependencies* (P3's rung 3, §7.2), applied at the row: an edit to the
model that does not touch what a row reads skips every row, so **an unchanged row costs a few pointer
comparisons and no call** — for the idiomatic `rowClass model row` as for `rowClass model.selected
row`. What defeats it is passing a whole record where the analysis cannot see which fields are read:
to a function of another module, into a record, into a `case` on a custom type. Such a row is still
correct, and re-runs whenever that record changes; `--self-profile` counts rows whose inputs hold a
whole local (`backend.md` §15.4), so the cost is a number.

### 11.10 Fragments

`<>…</>` is markup with no element of its own: its children, in order, where it stands. A fragment
of one child is that child.

### 11.11 Evaluation, and what a render may skip

§6's *Evaluation order* table has five rows for markup (an element or fragment, a component, `For`,
`Show`, an event handler), written there with the rest; they follow from its existing ones.

**A skipped component, row or `Show` body is not evaluated.** That is the one place markup relaxes
§6's "an expression is evaluated exactly once, when control reaches it": a render may evaluate a
component body, a row function or a `Show` body zero times or once. Nothing a program computes can
tell, because every beni expression is pure (§6, *What an optimiser may assume*); `Debug.log` in a
component body can, and logs only for the calls that happen. **A row's inputs are read before the
row is reached** — `model.selected`, read so the skip can compare it — and that is not an evaluation
a program can observe either: a field read of a record cannot fail and computes nothing. **When
effects land, a hole, prop, row or `Show` body whose expression is `impure` is never skipped**
(`transparent-effects-proposal.md` §5's rule, applied here), so the skip stays unobservable in what a
program does.

### 11.12 Identity: an untouched field keeps its identity

**A record update `{ r | a = x }` produces a record whose every field other than `a` is the very
same value that field of `r` held — not a copy, not an equal value, the same one — and no compiler
pass may break this.** The same holds for every value a program does not rebuild: a variable, a
field read, a list tail. (W27, decided 2026-09-29.)

It is true today by construction — a record update is emitted as a spread, `({ ...r, a: x })`
(`backend.md` §4) — and it was promised nowhere. It is promised now because the rendering strategy
rests on it: a template compares a hole's new value with its old one by reference, and an unchanged
row costs a pointer comparison per input **only** because an unchanged input is the same object
(`plans/browser-decisions.md` W27). A pass that rebuilt an untouched field would make that
comparison fail silently, and only on some builds. So the promise constrains every optimiser
forever, `--release` included — and the passes it forbids are ones nobody wants, since they would
add allocations. `lazy` is not added: the per-hole reference check is the memoisation it provided
(W27).

beni has no reference equality a program can call, so the promise is observable only through what a
platform does with it; it is pinned by fixtures in both builds (`backend.md` §15.8).

### 11.13 The plain-call form, and markup primitives

JSX is the template compiler (W32): markup is not sugar for calls, and nothing in the compiler
recognises calls as markup. What stays true is that **markup is a value of an ordinary type**, so a
platform may also ship functions returning it, and a program may build markup with them and mix the
result into holes freely. The exact equivalence the language keeps is the component one:
**`<M.c a={x}>k</M.c>` and `M.c { a = x, children = <>k</> }` are the same program** (with a single
hole child `{e}`, `children = e`), up to the skip of §11.8, which no program can observe.

**A function that builds markup at run time is a markup primitive** (§11.14): declared by the
vocabulary, implemented by each lowering's runtime, so one vocabulary serves every lowering that
compiles it — a `dom` block in the browser, a string under Node — and a view module that calls one
builds under both (`boundary.md` §9.3). It cannot be an ordinary `foreign`, whose one sibling would
have to build one lowering's representation and hand it to the other (`markup_type_in_foreign`,
`boundary.md` §9.3). The `html` platform declares two:

| Primitive | Type | Is |
|---|---|---|
| `Html.text` | `String -> Html msg` | the text, as a text hole shows it; `Html.text s` and `<>{s}</>` render alike |
| `Html.map` | `Html a, (a -> b) -> Html b` | Elm's `Html.map`: the same markup, with every message its handlers produce passed through the function before it is sent |

**`Html.map` composes.** A message produced inside nested maps passes through the innermost function
first and the outermost last, and a map whose function changed between renders sends through the new
one from then on without rebuilding anything inside it. That is Elm's semantics exactly, and what The
Elm Architecture needs to nest a child's `view` under a parent's `Msg`: `Html.map (Counter.view
model.counter) CounterMsg`. What it costs, in the `dom` lowering, is one property write per event
node inside a mapped subtree at mount and a short walk when an event fires there; markup outside any
map pays nothing (`backend.md` §15.3).

*This withdraws research 28's rule 19* — that JSX desugars to `Html.div [ … ] [ … ]` and an `emit/`
golden proves the two emit the same bytes. It was written for sugar-first, and W32 answered
templates-first. **A tag chosen at run time** (`Html.node`) is deferred with element spread (§11.5):
its attributes cannot be typed against a vocabulary row.

### 11.14 Vocabulary declarations (platform packages only)

A platform package declares its markup vocabulary in beni, with three declaration forms that carry
no JavaScript and a fourth that binds to the markup runtime (research 36 question 1, accepted). They
are legal only in a platform package, like `foreign` (`vocabulary_outside_platform` elsewhere), and
always `pub`. **An element's, attribute's or event's name is a string**, because a markup name is not
a beni identifier (`aria-label`) and may be a pattern (`data-*`); a primitive's is a lower name,
because it is a value a program calls:

```
VocabDecl := 'pub' 'element'   string ElementFact*
           | 'pub' 'attribute' string AttrFact*  ':' Type
           | 'pub' 'event'     string EventFact* ':' Type
           | 'pub' 'markup'    lower_ident       ':' Type          -- a markup primitive, §11.13
```

`element`, `attribute`, `event` and `markup` are **contextual words**, recognised only between `pub`
and a string — or, for `markup`, between `pub` and a lower name followed by `:` — where nothing else
can stand: a `Definition`'s head is one name followed by its parameters or `:`, so `pub markup : T`
still annotates a value named `markup`. They stay ordinary identifiers everywhere else, as
`equatable` does (§3). A name may contain `*`s, each of which matches a non-empty run of name
characters; an exact name beats a pattern, and of two patterns that match the longer literal part
(the characters that are not `*`) wins. Two declarations that would tie are `duplicate_declaration`.

*Amended 2026-09-29.* This paragraph said "one `*`", while §11.5 and §11.16 named `"*-*"` as the
custom-element pattern and `html` declares it: a name with a hyphen that is neither its first nor
its last character, which one `*` cannot say. The rule is now any number of `*`, and it stays
exact. **Matching**: a name matches a pattern when the pattern's literal characters appear in it in
order, each `*` standing for one or more characters in between, so `"*-*"` matches `my-widget` and
`x-a-b` but not `widget`, `-x` or `x-`; a `*` in a written name is an ordinary character. **Ranking**:
an exact declaration first; then, of the patterns that match, the one with the most literal
characters, so `"x-*"` (two) beats `"*-*"` (one) for `x-widget`. **Ties**: two patterns of one
literal length tie when some name matches both — `"x-*"` and `"*-y"` meet in `x-y`, `"a*-*"` and
`"*-b*"` in `ax-by`, while `"c*"` and `"d*"` meet nowhere — and a tie whose `on` sets overlap is
`duplicate_declaration`, so a name never has two answers and the answer never depends on
declaration order. `**` is legal and means a run of two or more.

| Form | Facts, each a contextual word | Type after `:` |
|---|---|---|
| `pub element "input" void` | `void` (no children), `svg`, `mathml` (namespace; HTML otherwise) | — |
| `pub attribute "value" property stateful on "input" "select" "textarea" : String` | `on` then element names (only those elements; every element otherwise), `property` with an optional JavaScript name (a property write; an attribute write otherwise), `stateful` (a property the user edits: compared with the live DOM value), `url` (the value is a URL: a lowering must refuse a script URL), `raw` (the value is markup text written unescaped), `classes` (the attribute also takes a class list, §11.19), `styles` (it also takes a style list, §11.19) | the value type: `String`, `Int`, `Float`, `Bool` or `Maybe String`; `String` for `classes` and `styles` |
| `pub event "onInput" delegated via targetValue : String` | `on` as above, `name` then the DOM event name (the lower-cased name after `on` otherwise), `delegated`, `preventDefault`, `stopPropagation`, `via` then a `foreign` value of this module (the payload extractor) | the payload type: the extractor's result, or, with no `via`, a `foreign type` the event object is handed as |
| `pub markup map : Html a, (a -> b) -> Html b` | — | a function type mentioning the markup type; the value is the build's markup runtime's export of that name (`boundary.md` §9.3) |

The facts are data for the platform's markup lowering, which is the only thing that interprets their
effect on the page (`boundary.md` §9.3, `backend.md` §15). **The checker reads `void`, `on`, the value
and payload types, `via`, `classes` and `styles`** for typing, and **`raw`** for the warning below;
nothing in the language depends on `property`, `stateful`, `url` or `delegated`.
**A `raw` attribute is the escape hatch for inserting markup text**, Solid's `innerHTML` (research 36
§4.8), and every use of one in the root package is the warning `raw_markup_attribute`, because it is
the one place a `view` can inject script. An unknown fact word is `unexpected_token`, naming the
facts its form accepts.

*Amended 2026-09-29, the owner's decision closing markup's other script sinks:* **the `html`
vocabulary declares no `script` element.** A page loads its scripts through its platform — its
runtime, its entry file — never through a `view`, so `<script>` is `unknown_element`, and no
value a view holds can become a script. A vocabulary of another platform may declare one; the
`html` platform, which `node` and `browser` share, does not.

The markup type itself is an ordinary `pub foreign type` of one parameter, named by the platform's
manifest (`boundary.md` §9.2). **The vocabulary module may write markup itself**, against its own
declarations: the markup edge of `frontend.md` §9.8 is never added from a module to itself, and a
module that the vocabulary module imports and that writes markup is an ordinary `import_cycle`,
whose message names the markup edge.

### 11.15 Formatting

§9's rules apply, plus these, and the governing one is new: **the formatter never changes what a
page says.** Formatting then rendering gives the same page as rendering, which is what makes bare
text safe to format (research 36 §6). *Whitespace* below is §11.4's.

| Construct | Rule |
|---|---|
| an opening tag's attributes | one line when it fits in 100 columns and the author wrote no break between attributes; otherwise one attribute per line, indented 4 from the `<`, with the `>` or `/>` alone on the line after the last, aligned with the `<` |
| children | on the element's line when the source has them there and they fit; otherwise each child line indented 4 from the `<` and the closing tag on its own line aligned with the `<`. An element whose opening tag broke is always vertical |
| **whitespace between children** | **the formatter never adds or removes a newline inside a run of whitespace between two children, and never makes a whitespace run empty or non-empty.** A run with no newline in it is a space the page shows (§11.4), so children the author wrote on one line with spaces between them stay on one line, past 100 columns if need be; a run with a newline shows nothing, so the formatter may change the indentation after the newline and the number of blank lines (at most one kept) |
| text | a run's continuation lines are re-indented to the children's column and their trailing whitespace dropped, both invisible under §11.4; the characters of a line are never touched, spaces between words and character references included |
| a hole holding only a comment | the `}` on its own line, aligned with the `{` |
| `<div></div>` | written `<div />`: one space before `/>`, which is the spelling JSX's formatters write |
| attribute values | a string is printed as written, as every literal is (§9); a `{e}` value follows the rules for `e`; a multi-line expression in a hole or attribute is indented 4 from the `{` |

### 11.16 What is refused, and why (rule 7)

| Refused | Guarantee or reason | Escape |
|---|---|---|
| markup as a bare argument, `f <b />` | forced: `f a <b` is a comparison today (§11.2) | `f (<b />)`, `<|`, a pipe |
| markup inside `${…}` | markup is not interpolatable, and allowing it would need the string mode to nest (§2.6) | bind it, then use a hole |
| `>`, `}` and a `<` not starting a tag, in text | a spelling, the JSX specification's; a stray `}` is almost always a hole's other half | `{">"}`, `{"}"}`, `{"<"}` |
| an unknown element or attribute | no silent wrong answer: a typo'd attribute is never written as nothing | the quoted-name escape for attributes; a platform's pattern declaration (`"*-*"`) for custom elements |
| an unknown or missing attribute of `For` or `Show` | the same: a misspelt `keyed` would silently key by reference | — |
| a hole of any other type | every hole has a known update and nothing renders through a conversion the optimiser may change (§11.6) | convert explicitly: `{String.fromX x}` |
| children of a `void` element | the platform declared the element takes none, so they would be dropped | — |
| a spread on an element, a tag chosen at run time | **not a guarantee: deferred capabilities** (§11.5, §11.13) | write the attributes |
| a component spread anywhere but first, or twice | a spread later than a prop would override it under JSX, and a closed record type makes that prop pointless; the rule is record update's, and nothing expressible is lost | move it first |
| a non-primitive key, for `For` or `Show` | two equal keys must be one row, and identity cannot say so (§11.9) | key by a field |
| a `Show` without `keyed`, or with `keyed={False}` | not a guarantee: non-keyed `Show` is `if`/`case`, which the language already has (§11.6) | write the `case` the message shows |
| duplicate attributes | the second would silently win | — |
| markup with no vocabulary | there is nothing to type it against | name a platform |
| a quoted attribute name beginning with `on`, in any case (`"onclick"=…`) | no script injection from a `view`: the page runs such an attribute's text as script (the owner's refusal, 2026-09-29) | the typed event attribute, `onClick={Clicked}` |
| a `foreign` building or reading markup in a platform that does not select the build's lowering | the value would be another lowering's representation (§11.13) | a markup primitive |

**Forced, not chosen**: children are evaluated eagerly (§11.8), because beni is strict. **Warned
about, not refused**: `unkeyed_for` (§11.9), and `raw_markup_attribute` at every use of the escape
hatch that bypasses escaping (§11.14). Both are `warning` severity, on by default, for the root
package only, in the shape `ambiguous_method_receiver` has. **Not refused, and never to be**: markup
in a `let`, a `case` branch, a list or a record field; a helper returning markup; recursion (a tree
view) — each of those takes the platform's general path (`backend.md` §15.4), and the fast path is a
property of the lowering, never a rule of the language. **Not in this specification**: portals
(rendering into a node outside the component's own place, Solid's `<Portal>`), which wait on the
browser platform's mount and after-render design; `ref` (research 36 question 6, W44).

### 11.17 Diagnostics

Appended to §10's catalogue, never inserted (§10). Syntax: `unclosed_element`,
`mismatched_closing_tag`, `element_as_argument` (the parser's, `frontend.md` §9.5). Lowering:
`duplicate_attribute`, `invalid_attribute_name`, `spread_on_element`, `spread_not_first`, `invalid_form_children`,
`unknown_form_attribute`, `missing_form_attribute`, `invalid_keyed` and `vocabulary_outside_platform`.
The checker's ([`checker-v2.md`](checker-v2.md) §25.9): `no_markup_vocabulary`, `unknown_element`,
`unknown_attribute`, `child_not_renderable`, `void_element_with_children`, `key_not_primitive`,
`markup_type_in_foreign`, `untyped_event_attribute`, `untyped_srcdoc_attribute`, and the warnings `unkeyed_for` and `raw_markup_attribute`. A lowering's
own, reported during `build` against a markup node (`boundary.md` §9.4.7): `markup_restructured`.
The manifest's (`boundary.md` §9.2): `unknown_markup_lowering`. Reused, not duplicated:
`unexpected_token`, `expected_token`, `unclosed_delimiter`, `missing_field`, `unknown_field`,
`type_mismatch`, `duplicate_declaration`, `import_cycle`, `nesting_too_deep`, and §4's `foreign_*`
codes for the markup runtime.

### 11.18 Keyed `Show`

```elm
<Show when={model.editing} keyed fallback={<p>Pick a user</p>}>
    {\user -> <UserEditor user={user} />}
</Show>
```

`Show` is Solid 2's keyed conditional (`<Show when={x} keyed>`, the owner's answer;
`references/solid/packages/solid/src/client/flow.ts:164-240`,
`references/solid/documentation/solid-2.0/03-control-flow.md:84-92`; research 36 §4.5). **It
remounts when its value's identity changes**: the DOM inside it — inputs' text, focus, scroll — is
thrown away and built afresh, which is how a view says "a different user is a different form".

**Attributes**, validated as `For`'s are (`unknown_form_attribute`, `missing_form_attribute`):

| Attribute | Type | Means |
|---|---|---|
| `when`, required | `Maybe a` | `Nothing` shows the fallback; `Just v` shows the body for `v`. `Maybe` rather than Solid's truthiness, which beni does not have |
| `keyed`, required | bare or `{True}`: by identity; `{f}`, `f : a -> k`: by key | when to remount (below) |
| `fallback`, optional | `Html msg` | shown on `Nothing`; nothing is shown without it |

Its only child is one hole holding the **body**, a function `a -> Html msg`, by the same rule as a
row function (§11.9): any expression of that type, `invalid_form_children` otherwise. It receives
`v`, which is Solid's keyed callback receiving the narrowed value.

**When it remounts.** Each render in which `when` is `Just v` computes the **key** — `v` itself, or
`f v` — and remounts when the previous render showed the fallback or its key is not identical
(`===`) to this one; otherwise the body's new markup patches the old like any markup value (§11.6).
By identity is Solid's semantics, and in an immutable language it inherits `For`'s hazard: an edit
to the very record the `Show` shows is a new object, so it remounts — which is why beni adds **by
key**, `keyed={.id}`, the spelling `For` already has. A key must be primitive-`eq`
(`key_not_primitive`), for §11.9's reason. By identity over a primitive-`eq` type is by value, as for
`For`.

**Non-keyed `Show` is not provided** (the owner's answer): `<Show when={x}>` without `keyed` is
`missing_form_attribute`, and `keyed={False}` is `invalid_keyed`; each message shows the `case` that
says the same thing, since a non-keyed conditional is exactly `case x of Just v -> … ; Nothing ->
…` (§11.6). *Amended 2026-09-29:* the `case` is written from the `Show`'s own `when`, body and
`fallback` (an empty fragment when it has none), not a fixed example.

**Evaluation and skipping**: the attributes in source order; then, on `Just v`, the key function
once, then the body — which **may be skipped**, like a row, when `v` and the body's inputs (§11.9's
table) are identical to the previous render's and the key did not change.

### 11.19 `class` and `style` lists

Solid 2 merged `classList` into `class`, which takes a string, an object or an array, and gives
`style` an object form beside the string (`references/solid/documentation/solid-2.0/07-dom.md:7-28`;
`references/dom-expressions/packages/runtime/src/client.js:333-417`). beni takes the same two forms,
typed, and on the same two attribute names — Solid 2 rejected keeping a second name as "two ways to
do the same thing" (`07-dom.md:158`):

| Attribute | Admits | Means |
|---|---|---|
| `class` | `String` | the attribute, as written |
| `class` | `List ( String, Bool )` | **a class list**: the element has exactly the classes whose entry is `True`. A name holding whitespace is several names; a name listed twice is present when any of its entries is `True`; order carries no meaning |
| `style` | `String` | the attribute, as written |
| `style` | `List ( String, String )` | **a style list**: each entry sets one CSS property — `background-color`, a custom property `--gap` — to its value, as `style.setProperty` does. An empty value removes the property; of two entries for one property the later wins |

Both are what a platform declares with the facts `classes` and `styles` (§11.14), so the language
knows neither name: which form a value is, is decided by its type — a `List` is the list form,
anything else the declared `String`, and a value whose type is still a variable at the declaration's
boundary is the `String` form (`checker-v2.md` §25.4). **A class or style that a list held on the
previous render and does not hold now is removed**, so the element shows exactly what this render's
list says, whatever the previous one said.

**Why lists, not records.** A class name is not a beni field name (`is-active`,
`hover:bg-blue`), a style property often is not either (`--gap`), and "a record whose every field is a
`Bool`" is not a type beni can write. `List ( String, Bool )` is Elm's own `classList`, needs nothing
new, and keeps every entry typed. **A list written in place is compiled away**: when the value is a
list literal of pair literals whose names are literal strings,
`class={[ ( "row", True ), ( "danger", row.id == sel ) ]}`, each entry is its own value, a constant
entry costs nothing at run time and a dynamic one is one guarded toggle — Solid's compile-time split
of an object literal (`shared/attr_plan.rs:587-895`, `dom/set_attr.rs:52-115`). Any other list goes
through the runtime's diff, a port of Solid's `className` and `style` helpers
(`backend.md` §15.3). Both agree on what the element ends up with.

## Appendix A. The prelude

These names are in scope in every module without an import. The table is a constant inside the
compiler, never read from another module at resolution time, which keeps per-file name resolution
independent of every other file. The set is Elm's default imports minus the effect-system modules
(`Platform`, `Cmd`, `Sub` — open, see `fast-compiler.md` §3.1) and minus `Tuple` (§0); operators are
syntax (§6.5) and are never imported or exposed.

Module aliases usable in qualified names: `Basics`, `List`, `Maybe`, `Result`, `String`, `Char`,
`Debug`. Exposed types: `Int Float Bool Char String List Maybe Result Order Never`. Exposed
constructors: `True False Just Nothing Ok Err LT EQ GT`. Exposed values (all from `Basics`):

```
toFloat round floor ceiling truncate max min compare not xor modBy remainderBy negate abs
clamp sqrt logBase e pi cos sin tan acos asin atan atan2 degrees radians turns toPolar
fromPolar isNaN isInfinite identity always never
```

Lowering resolves each to `import_value(Basics, name)` / `import_ctor(Maybe, Just)` etc., the same
form an explicit `import Basics exposing (max)` would produce, so nothing downstream knows the
prelude exists.

**`Int32` is deliberately absent from every row above** (§2.5). It is a core module like any other
and reaching for it is `import Int32`: it is the escape hatch of `fast-compiler.md` §3.1 rather
than part of the language everyone writes, and putting `Int32.add` a keystroke away from `+` would
make the type look like an alternative `Int` instead of the specialist it is. The absence is also
mechanical — the `InternPool.WellKnown` indices ARE the prelude membership test, so a name in that
enum is a prelude name, and `Int32` may not join it.

**Which module a prelude type belongs to moved for two of them, and the table above did not change.**
`String` and `Char` are declared in `String` and `Char` rather than in `Basics` (§5.4), because the
module rule makes a type's methods its declaring module's `pub` values. Both stay prelude *types*,
so every module still names them unqualified and no module gains an import; what changes is where
the conditional prelude *edge* points, and which module a string or character literal mints its type
from. → `static-dispatch-spike.md` §5.1.
