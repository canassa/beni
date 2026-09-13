# Beni language specification — surface syntax (M1 scope)

**Status:** normative for M1. Every rule here is what the lexer, parser, formatter and BIR
lowering implement, and what the corpus tests assert. Decisions are taken from
[`fast-compiler.md`](fast-compiler.md) §3, §3.1, §3.2; where this document is more specific than
that one, this one wins for the front end. Semantics (types, evaluation) are deliberately out of
scope until M2/M3 — this is the grammar, the lexical structure, and the per-file name-resolution
rules that a single file's text fully determines.

The language is Elm 0.19 with the changes listed in §0. A reader who knows Elm needs only §0
and the indentation rules in §4.

## 0. Differences from Elm, in one place

| Elm | Beni | Where |
|---|---|---|
| `module Foo exposing (..)` header | none; module name from path; `pub` per declaration | §5.1 |
| `import M exposing (T(..))` | `exposing (T, Ctor1, Ctor2)` — constructors listed by name, no wildcard | §5.2 |
| `{- -}` block comments, `{-\| -}` docs | none; `--` comment, `--\|` doc, `--!` module doc | §2.3 |
| `"""…"""` multiline strings | Zig-style `\\` line-prefixed raw strings | §2.7 |
| `"a" ++ String.fromInt n` | `"a ${n}"` interpolation, primitives only | §2.6 |
| `Result.andThen` pyramids | `expr?` postfix, desugared to `case` | §6.6 |
| `Tuple.first`, arity ≤ 3 | `t.0`, `t.1`, any arity ≥ 2 | §6.4 |
| user-defined operators, `infix` | fixed operator set, fixed fixities | §6.5 |
| shadowing is an error | same | §7 |
| `comparable`, `<` on strings | numbers only; not a front-end concern | M2 |
| tabs | syntax error everywhere | §2.1 |
| Kernel modules | `foreign` declarations, core root only | §5.4 |

Everything else — application by juxtaposition, `\x ->` lambdas, `case … of`, `let … in`,
`if … then … else`, records, record update, lists, tuples, type aliases, custom types, `as`
patterns, `::` patterns, `.field` accessors — is Elm's.

## 1. Files and modules

- A source file has the extension `.beni` and is UTF-8. A byte sequence that is not valid UTF-8
  is a diagnostic (`invalid_utf8`) at the first offending byte; lexing continues from the next
  valid boundary.
- One file is one module. The module's name is its path relative to the source root, with `/`
  replaced by `.` and the extension dropped: `src/Json/Decode.beni` is `Json.Decode`. Each path
  segment must be a valid upper identifier (§2.4); otherwise the file is rejected before parsing
  (`invalid_module_path`).
- There is no module header. The first thing in a file is optional `--!` documentation, then
  imports, then declarations.

## 2. Lexical structure

### 2.1 Characters, whitespace and line structure

- **Newline** is `\n`. `\r\n` is accepted and treated as a single newline. A `\r` not followed by
  `\n` is an error (`bare_carriage_return`).
- **Whitespace** is the space character and newlines. **A tab byte anywhere in the file is an
  error** (`tab_in_source`), including inside string and character literals and inside comments.
  Use `\t` in ordinary strings. (Consequence: raw multiline strings cannot contain a tab.)
- Any other control character outside a string or comment is an error (`invalid_character`).
- **Column** is 1-based and counts *bytes* from the line start. Because tabs are forbidden and
  layout is decided by ASCII whitespace only, byte column equals visual column for every token
  that starts after ASCII-only indentation; indentation is always leading spaces.
- **Line** is 1-based. Diagnostics report `{line, col}` pairs; both are derived from token
  offsets and the file's line-start table.

### 2.2 Tokens

The lexer produces a flat array of `{tag, start, line}` records (`fast-compiler.md` §5, plus a
line number so the parser can decide indentation without a layout pass — see §4). Token text is
re-derived from `start` and the tag. The token kinds:

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
symbols            ( ) [ ] { } , : = -> \ | _ ?
operators          + - * / // ^ ++ :: == /= < > <= >= && || |> <| << >>
eof
```

Comments are **not** tokens. They go into a parallel `comments` array (§2.3) so the parser's
token stream contains only significant tokens, and the formatter re-attaches them by position.

Longest match applies among operators (`|>` not `|` `>`; `//` not `/` `/`; `->` not `-` `>`).
`--` always begins a comment; no operator contains `--`.

### 2.3 Comments

Three line comments. All run to the end of the line; nothing nests; there is no block comment.

| Spelling | Meaning | Rule |
|---|---|---|
| `-- text` | ordinary comment | anywhere |
| `--\| text` | doc comment | documents the declaration that follows it (attachment rules below) |
| `--! text` | module doc | only at the top of the file, before any import or declaration |

Attachment rules, taken from Zig:

- Consecutive `--|` lines form one doc block. The block must be followed on the next non-blank
  line by a declaration (§5.3) or by the `pub` that starts one. Anything else — an import, an
  ordinary comment, another construct, end of file — is `doc_comment_unattached`. Blank lines
  between the doc block and its declaration are allowed.
- `--!` lines must appear before the first import or declaration. A `--!` anywhere else is
  `module_doc_not_at_top`. Consecutive lines form one block; a second block after a blank line is
  merged with the first.
- An ordinary `--` comment between a doc block and its declaration splits the block from its
  target and is `doc_comment_unattached`. One rule, no exceptions.
- `--|x` and `--!x` with no space are still doc comments; the formatter inserts the space.
- `---` (three or more dashes) is an ordinary comment. `--|` cannot be produced accidentally, so
  no carve-out exists.

The comment record is `{kind, start, before_token}`: which significant token it precedes.
Length is re-derived (to end of line).

### 2.4 Identifiers and keywords

```
lower_ident := [a-z] [A-Za-z0-9_]*
upper_ident := [A-Z] [A-Za-z0-9_]*
```

ASCII only. A non-ASCII byte outside a string, char or comment is `invalid_character`.

Keywords (never identifiers): `if then else case of let in type alias pub opaque import as
exposing foreign`. `_` alone is the wildcard symbol; `_foo` is a lower identifier (the formatter and
checker may warn later; the lexer does not care).

**Qualified names** are single tokens: `Upper(.Upper)*.lower` is `qualified_lower`,
`Upper(.Upper)+` is `qualified_upper`. There is no whitespace anywhere inside. The lexer decides
this greedily: after an `upper_ident`, if the next byte is `.` and the byte after that is a
letter, the token continues. This makes `Foo.bar` unambiguous — it is *always* a qualified name,
never a field access on a constructor, which is meaningless anyway.

`True`, `False`, `Nothing`, `Just`, `Ok`, `Err` are ordinary constructors, not keywords.

### 2.5 Numbers

```
int   := [0-9]+  |  0x [0-9A-Fa-f]+
float := [0-9]+ '.' [0-9]+ exponent?  |  [0-9]+ exponent
exponent := [eE] [+-]? [0-9]+
```

- Numeric lexing continues past `.` into a float **only if the next byte is a digit**. So `1.`
  followed by anything else is `int` then whatever follows, and `1.e5` is `int` `dot`… → a
  syntax error, not a float. (`fast-compiler.md` §3.2 mentions `e`/`E` after the dot as well;
  the grammar above has no such form, so the lexer does not take it.) `x.0` never starts a float
  because it starts with a lower identifier (§2.4).
- No underscores, no leading `+`, no octal/binary, no trailing `.`. An identifier character
  immediately after a number (`12abc`, `0x1G`) is `invalid_number`.
- A `-` is never part of a literal (§6.5, negation).

### 2.6 Strings and interpolation

```
"chunk ${expr} chunk"
```

- `"` starts a string. Inside: any byte except `"`, `\`, `$` followed by `{`, a newline, or a
  tab. A newline inside a string is `unterminated_string` at the newline (strings are
  single-line; use a multiline string).
- Escapes: `\n`, `\r`, `\t`, `\\`, `\"`, `\$`, `\'`, `\u{H+}` (1–6 hex digits, a valid Unicode
  scalar value). Anything else after `\` is `invalid_escape`. `$` not followed by `{` is a
  literal dollar.
- `${` opens an interpolation. The lexer switches to expression mode with brace depth 1; `{`
  and `}` adjust the depth; the `}` that brings it back to 0 closes the interpolation. **A `"`
  inside an interpolation is `nested_string_in_interpolation`**; the diagnostic says to bind the
  inner string to a name. A multiline-string marker `\\` inside an interpolation is the same
  error.
- Token stream: `str_start` (at the opening `"`), then zero or more `str_chunk` (a maximal run of
  literal text, escapes included, never empty) and `interp_start`/…tokens…/`interp_end`
  segments, then `str_end` (at the closing `"`). A string with no chunks and no interpolations is
  `str_start str_end`.
- Only expressions of type `String`, `Int`, `Float`, `Bool`, `Char` may be interpolated. That is
  checked in M2, not here; the front end lowers `${e}` to an explicit `interp` node so the
  obligation is visible.

### 2.7 Multiline strings

Zig's form. A line whose first non-space characters are `\\` is one line of a multiline string,
raw to the end of the line — no escapes, no interpolation, `${` and `\` are literal.

```
sql =
    \\SELECT *
    \\FROM users
```

- Consecutive `multiline_line` tokens (no non-blank line in between) form one string literal.
  Each line's text is what follows the `\\`; lines are joined with `\n`; the final line has no
  trailing newline. **A blank line between two `\\` lines ends the literal** (the second starts a
  new one, which is then a syntax error where it stands).
- Column rules (§4) apply to the `\\` marker like any other token; the marker's column is the
  token's column.
- The lexer distinguishes this from a lambda by one byte of lookahead: `\` followed by `\` is a
  multiline line; `\` followed by anything else is the lambda backslash.

### 2.8 Characters

`'x'` with the same escapes as strings. Exactly one Unicode scalar value between the quotes;
otherwise `invalid_char_literal`. `''` is `invalid_char_literal`.

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
             | 'foreign' 'type' upper_ident lower_ident*
Visibility  := 'pub' | 'pub' 'opaque'            -- 'opaque' only before 'type'
TypeAlias   := 'type' 'alias' upper_ident lower_ident* '=' Type
TypeDecl    := 'type' upper_ident lower_ident* '=' Ctor ('|' Ctor)*
Ctor        := upper_ident TypeAtom*
Annotation  := lower_ident ':' Type
Definition  := lower_ident PatAtom* '=' Expr

Type        := TypeApp ('->' Type)?                              -- right assoc
TypeApp     := (upper_ident | qualified_upper) TypeAtom+ | TypeAtom
TypeAtom    := lower_ident                                       -- type variable
             | upper_ident | qualified_upper                     -- nullary type
             | '(' ')'                                           -- unit
             | '(' Type ')'
             | '(' Type (',' Type)+ ')'                          -- tuple, arity ≥ 2
             | '{' '}'                                           -- empty record
             | '{' RecordTypeFields '}'
             | '{' lower_ident '|' RecordTypeFields '}'          -- extensible record
RecordTypeFields := lower_ident ':' Type (',' lower_ident ':' Type)*

Expr        := 'let' LetBinding+ 'in' Expr
             | 'if' Expr 'then' Expr 'else' Expr
             | 'case' Expr 'of' Branch+
             | '\' PatAtom+ '->' Expr
             | BinOp
LetBinding  := Annotation? Definition | Pattern '=' Expr         -- pattern binds have no args
Branch      := Pattern '->' Expr

BinOp       := Postfix (operator Postfix)*                       -- Pratt, table in §6.5
Postfix     := App '?'*
App         := Atom Atom*
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

Pattern     := PatCtor ('::' Pattern)?                           -- right assoc
PatCtor     := (upper_ident | qualified_upper) PatAtom* | PatAtom
PatAtom     := '_' | lower_ident
             | int | char | string-without-interpolation | '-' int
             | '(' ')' | '(' Pattern ')' | '(' Pattern (',' Pattern)+ ')'
             | '[' ']' | '[' Pattern (',' Pattern)* ']'
             | '{' lower_ident (',' lower_ident)* '}'            -- record pattern
             | PatAtom 'as' lower_ident
```

Notes:

- `Annotation` must be immediately followed by the `Definition` of the same name (blank lines
  and comments allowed, nothing else): otherwise `annotation_without_definition`. A definition
  has at most one annotation.
- A `Definition` at top level always has a `lower_ident` head; destructuring definitions exist
  only in `let`. A pattern binding in `let` has no annotation and no arguments.
- `Decl` visibility: `pub` before `type alias`, `type`, `Annotation`, or a `Definition` that has
  no annotation. When a definition has an annotation, `pub` goes on the annotation, not on the
  definition; `pub` on both or only on the definition is `pub_on_definition`. `pub opaque` is
  legal only before `type` (`opaque_not_on_type`).
- `TypeDecl` needs at least one constructor. A leading `|` before the first constructor is
  allowed (`type T = | A | B`) and the formatter removes it.
- Trailing commas are not allowed anywhere. Empty `( )`, `[ ]`, `{ }` may contain whitespace.
- An expression may not begin with an operator, except `-` for negation (§6.5).
- `case` needs at least one branch (`case_without_branches`).
- `lambda`: `\x y -> e` — one or more pattern atoms.
- Record update: the target is a plain name, as in Elm (`{ r | x = 1 }`). `{ r.a | … }` is not
  allowed.
- Parenthesised operators: `(+)`, `(::)`, `(|>)` etc. — any operator from §6.5. Sections such
  as `(+ 1)` do not exist. Negation `(-)` is the binary minus function; there is no negation
  function.
- Field access chains on any atom: `(f x).name`, `r.a.b`, `t.0.1`, `xs.0` — the `dot_lower` /
  `dot_index` token must start at the byte right after the atom's last byte (no whitespace).
  With whitespace, `.field` is an accessor-function atom and application applies: `f .name` is
  `f` applied to `.name`.
- Application binds tighter than `?`, which binds tighter than every binary operator. So
  `parse s? |> f` is `((parse s)?) |> f`, and `f (a?) b` is how `?` is applied to one argument.
  `f a? b` is a syntax error (`args_after_question`): after `?` no further arguments may follow.

## 4. Layout: indentation is the block structure

There is no layout pre-pass and no virtual semicolon. The parser carries one integer, the
**indent** of the current block, and a token is treated as belonging to the current construct
only if its **column is greater than the indent**. Blocks are:

| Block | Its indent is the column of… | Sibling starts at | Ends when |
|---|---|---|---|
| top-level declaration | the declaration's first token, which **must be column 1** | column 1 | a token at column 1, or EOF |
| `let` binding list | the first binding's first token | exactly that column | `in`, or a token left of that column |
| a `let` binding's body | the binding's first token | — | a token at column ≤ that |
| `case` branch list | the first branch's pattern | exactly that column | a token left of that column |
| a branch's body | the branch's pattern | — | a token at column ≤ that |

Rules:

1. **Top-level declarations begin at column 1.** Everything belonging to a declaration —
   the rest of its first line, and every continuation line — is at column ≥ 2. A token at
   column 1 always starts a new import or declaration; if it cannot, the diagnostic says so
   (`expected_declaration`).
2. **Every token of a block body has column > the block's indent.** This is checked on every
   token, not only the first token of a line; it is trivially true for tokens on the head's own
   line. When the check fails, the parser sees the end of that block. Nothing peeks beyond it.
3. **`let` bindings are aligned.** The first binding sets the column; a token at exactly that
   column begins the next binding; `in` ends the list and may sit at any column greater than the
   *enclosing* block's indent (so `in` aligned with `let` is fine, and so is `in` on the same
   line).
4. **`case` branches are aligned** the same way. The first branch may be on the same line as
   `of`; then its column is wherever it is, and later branches must match it.
5. **`then`, `else`, `of`, `->`, `in`, operators, arguments, `|` in a type declaration** —
   all follow rule 2 and nothing more. Any of them may start a line as long as it is right of
   the enclosing block's indent.
6. **Brackets do not suspend layout.** Inside `( [ {` the same rule 2 applies against the
   enclosing block's indent. This is what makes an unclosed bracket unable to swallow the file:
   a token at column 1 ends every open construct and reports `unclosed_delimiter` at the
   opening bracket.
7. **Interpolation follows the string.** Tokens inside `${…}` are on the string's line by
   construction (strings are single-line), so rule 2 holds automatically.

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

`case` body indent is 1 (the declaration). Branches at column 9; `Home` body is anything at
column > 9. `let` bindings at column 17; `body`'s body continues at column > 17; `in` at column
13 is left of 17 (ends the bindings) and right of 9 (still inside the branch). `About` at
column 9 starts the next branch. The blank line is trivia.

The rules are lexically decidable because the only inputs are the column of each token (from its
offset and the line-start table) and one integer of parser state. There is no token whose
meaning depends on a later line.

## 5. Modules, imports, visibility

### 5.1 Visibility

- `pub` marks a declaration as part of the module's interface. Unmarked declarations are private.
- `pub type T = A | B` exposes the type *and* its constructors. `pub opaque type T = …` exposes
  the name only; the constructors are usable in this file and nowhere else.
- `pub type alias` exposes the alias.
- A private declaration used by a public one is fine — visibility is about names, not
  reachability.

### 5.2 Imports

```
import Json.Decode
import Json.Decode as D
import Json.Decode exposing (Decoder, string, int)
import Dict as D exposing (Dict)
```

- The module path is one `qualified_upper` or `upper_ident` token.
- `as` gives the alias used for qualification in this file. Without `as`, the alias is the full
  path (`Json.Decode.string`). Two imports may not share an alias (`duplicate_import_alias`),
  and the same module may not be imported twice (`duplicate_import`).
- `exposing` lists names, each exactly once. Lower names are values; upper names are types **or
  constructors** — the file cannot tell which, and does not need to: in a type position an upper
  name is a type, in an expression or pattern it is a constructor. Whether the imported module
  actually exposes it is checked in M2.
- Order: all imports precede all declarations. An import after a declaration is
  `import_after_declaration`. The formatter sorts imports by path.
- Importing the current module itself is `self_import` (a cycle of length one, detectable per
  file). Longer cycles are M2.

### 5.3 What is a declaration

Type alias, custom type, annotation + definition, or a bare definition. Each declares exactly
one name at top level (the type or the value); constructors additionally declare their names in
the file's constructor namespace. Names are unique per namespace per file:

- two value declarations with the same name → `duplicate_declaration`
- two types (aliases or custom) with the same name → `duplicate_type`
- two constructors with the same name, across all types in the file → `duplicate_constructor`

A declared name may not collide with an `exposing` import of the same namespace
(`shadows_import`). Note `Dict` the type and `Dict` the module alias live in different
namespaces and may coexist, as in Elm.

### 5.4 Foreign declarations (core only)

The standard library is written in beni. The handful of functions and types that cannot be —
arithmetic, string primitives, the list representation — are declared without a body and
implemented in JavaScript:

```
--| Add two numbers.
pub foreign add : number -> number -> number

pub foreign type List a
```

- `foreign name : Type` declares a value with that type and no definition. `foreign type T a…`
  declares a type with no constructors, so it is opaque by construction; no `opaque` keyword
  is needed or allowed on it. Both take `pub` like any declaration and may carry a doc comment.
- **Legal only under the core root.** The core package is embedded in the compiler
  (`fast-compiler.md` §3.1, "Primitives"); a `foreign` declaration in any other module is
  `foreign_outside_core`, reported by lowering. User code reaches JavaScript through the effects
  model (open), never through `foreign`.
- Each core module that declares foreigns has a sibling JavaScript file exporting one function
  per foreign value, under the same name, in the emitted calling convention. Binding is by
  name; a missing export is a build error of the core package, not a user diagnostic.
- The primitive types are foreign: `Int`, `Float`, `Char`, `String`, `List a`. `Bool`, `Maybe`,
  `Result` and `Order` are ordinary declared types in core.

Lowering emits a `foreign` declaration into the interface skeleton like any other `pub` name;
the interface records that it is foreign so M3's printer can key its peephole on the
module-qualified name.

## 6. Expression details

### 6.1 Literals

`Int`, `Float`, `Char`, `String` literals as lexed. `()` is unit. `[a, b]` is a list literal.
`(a, b, c)` is a tuple literal; `(a)` is grouping.

### 6.2 Names

An unqualified `lower_ident` in expression position resolves, in this order, to the innermost
local binding (lambda parameter, let binding, pattern variable, function parameter), a
top-level value in this file, a name in some import's `exposing` list, or a name in the
**prelude** (Appendix A). If none, it is `unbound_variable`. Because imports are explicit and
per-file and the prelude is a fixed table inside the compiler, this resolution needs no other
file. A `qualified_lower` resolves its module part against the import aliases and then the
prelude's module aliases (`unknown_module_alias` if none); the value part is checked in M2.

An `upper_ident` in expression or pattern position is a constructor: a constructor declared in
this file, else one in an `exposing` list, else a prelude constructor, else
`unbound_constructor`. `qualified_upper` in expression position is a qualified constructor,
resolved like `qualified_lower`. In type position an upper name is a type: declared in this
file, else exposed, else prelude, else `unbound_type`.

A top-level declaration or an `exposing` entry may reuse a prelude name; the prelude entry is
then simply not visible in this file (no diagnostic). A top-level declaration may **not** reuse
an `exposing` name (`shadows_import`), and locals may shadow nothing (§7) — including prelude
names.

### 6.3 Records

`{ a = 1, b = 2 }`, `{ r | a = 1 }`, `r.a`, `.a`. Field names are unique within a literal
(`duplicate_field`). The update target is a plain name resolved by §6.2 (local, top-level, or
exposed import). Update with zero fields (`{ r | }`) is a syntax error.

### 6.4 Tuples

`(a, b)`, arity ≥ 2, unbounded. `t.0` is the first element. The index is a literal decimal
integer with no leading zeros beyond `0` itself (`.00` is `invalid_tuple_index`). Arity checks
are M2.

### 6.5 Operators

Fixed table. Binding power in Pratt terms; left/right associativity via asymmetric powers;
non-associative operators reject a second operator of the same precedence without parentheses
(`non_associative_chain`).

| Prec | Operators | Assoc |
|---|---|---|
| 0 | `<\|` | right |
| 0 | `\|>` | left |
| 2 | `\|\|` | right |
| 3 | `&&` | right |
| 4 | `==` `/=` `<` `>` `<=` `>=` | non-assoc |
| 5 | `++` `::` | right |
| 6 | `+` `-` | left |
| 7 | `*` `/` `//` | left |
| 8 | `^` | right |
| 9 | `<<` | right |
| 9 | `>>` | left |
| — | `?` postfix, application, `.field`, `.0` | tighter than all of the above, in that order (tightest last) |

Mixing `<|` and `|>` at precedence 0 without parentheses is `non_associative_chain`.

**Negation.** `-` directly followed (no whitespace) by an atom, in a position where the parser
expects the *start* of an operand, is negation: `-x`, `-(a + b)`, `-1`, `[ -1, -2 ]`. In
argument position it is not: in `f -1` the parser has parsed `f` and sees `-` where either an
argument or an operator may follow, and **it is the binary operator**, as in Elm, so `f -1` is
`f - 1`; write `f (-1)`. `- x` with a space in prefix position is `negation_with_space`.
`a - -b` is allowed. Negation of an integer literal in a *pattern* is a literal pattern
(`-1 ->`).

### 6.6 `?`

`e?` where `e : Result x a` yields `a` or returns `Err x` from the enclosing function; where
`e : Maybe a`, yields `a` or returns `Nothing`. The front end enforces the scope rules:

- `?` must be inside a named function's body — a top-level definition with ≥ 1 parameter or a
  `let` definition with ≥ 1 parameter. Inside a lambda it is `question_in_lambda`; in a
  parameterless definition (a constant) it is `question_outside_function`. The "nearest enclosing
  named function" is the innermost such definition, so a `let f x = g x?` inside `view` returns
  from `f`.
- Lowering desugars each `e?` to a `case` on a fresh local (§8); the Maybe/Result choice and the
  "same shape as the enclosing function" rule are M2, checked on the lowered form.

## 7. Scoping and shadowing

- Every binding introduces a name into a lexical scope: function parameters, lambda parameters,
  `let` bindings (all bindings of a `let` are in scope in all its bodies and its `in` expression —
  mutual recursion is allowed), pattern variables in `case` branches and destructuring.
- **Shadowing is an error** (`shadowing`): a binding may not reuse a name already bound in an
  enclosing scope, including top-level names of this file and names in `exposing` lists.
  Two sibling scopes may reuse a name (`\x -> …` twice). A pattern may not bind the same name
  twice (`duplicate_pattern_variable`).
- Top-level names are all in scope in every body; order does not matter. `let` bindings likewise
  within their `let`.
- Type variables in an annotation are scoped to that annotation. Type declarations' parameters
  must be distinct (`duplicate_type_parameter`) and a declared parameter not used in the body is
  fine; an unbound type variable in a `type` or `type alias` body is `unbound_type_variable`.
  (Annotations may mention free variables; they are implicitly quantified.)

## 8. What lowering produces (BIR), and what it desugars

BIR is the per-file, untyped, name-resolved IR (`fast-compiler.md` §6). It is a pure function of
the file's bytes: nothing in it depends on another module. Lowering:

1. Resolves every name per §6.2 into one of: `local(index)`, `top(index)` (this module),
   `import_value(module, name)`, `import_ctor(module, name)`, `ctor(index)` (this module),
   `qualified(alias → module, name)`. Records the set of top-level names each declaration
   references (§9.1 of the design doc: the DCE graph is a byproduct).
2. Desugars: operators into calls of the corresponding core functions (`a + b` → `add a b`,
   marked as a `number`-typed builtin — the M2 checker resolves the builtin); `<|` and `|>` into
   direct application (`x |> f` → `f x`; **this is the one place the front end changes call
   arity**, so that `|>` chains are saturated calls); `>>`/`<<` into lambdas; `?` into
   `case`; string interpolation into an `interp` node listing chunks and expressions; `if` into a
   two-branch `case` on `True`/`False`; multi-parameter lambdas stay n-ary; `.field` accessor
   functions into one-parameter lambdas; record update, tuples, lists stay as nodes. Field access
   and tuple index stay as nodes (the checker needs them).
3. Emits the module's **interface skeleton**: the `pub` names, aliases, types, and constructor
   lists — lexically computable, no inference (§8.1 of the design doc).
4. Reports the diagnostics of §5.3, §6.2 and §7.

A textual dump of BIR (`beni dump --stage=bir`) is part of the CLI contract so it can be tested
as an output, not an internal.

## 9. Formatting

`beni fmt` produces the canonical form; the corpus is kept in it. Properties that are tested:

- **Idempotent:** `fmt(fmt(s)) == fmt(s)`.
- **Structure-preserving:** `parse(fmt(s))` and `parse(s)` produce the same AST modulo
  positions, and the same comments in the same order.
- **Total on valid input:** every file that parses formats; a file with syntax errors is
  reported and left untouched (exit 1, no bytes written).

Style, elm-format's with the changes the syntax forces:

- 4-space indentation. LF line endings. One trailing newline. No trailing whitespace.
- Module doc block, blank line, imports sorted by module path with one per line, two blank
  lines, declarations separated by two blank lines. Blank lines between `let` bindings and
  between `case` branches: at most one, kept if present.
- Annotation on its own line directly above its definition. `pub` on the annotation line.
- `=` at the end of the head line; the body on the next line indented 4, **unless** the whole
  declaration fits on one line and the body is a single literal, name, or application without
  nested blocks — then one line. (The precise "fits" rule is the implementation's, must be
  deterministic, and is pinned by the corpus.)
- `let`: `let` alone on a line, bindings indented 4 relative to `let`, `in` aligned with `let`,
  body aligned with `let`.
- `case x of` alone on a line; branches indented 4; `->` at line end; body indented 4 more.
- `if c then` / `a` / `else` / `b`, unless it fits on one line.
- Lists, records and tuples: on one line if they fit in 100 columns, else elm-format's
  vertical form: `[ a`, `, b`, `]` with the delimiter leading each line.
- Binary operator chains that do not fit break before the operator, one operator per line,
  operands indented 4.
- Comments stay attached to the token they precede; a comment on its own line stays on its own
  line; a trailing comment stays at the end of its line. Doc blocks get a space after `--|`.
- Strings, numbers and chars are printed as written (no escape normalisation) except that the
  formatter never changes bytes inside a literal.

## 10. Diagnostics named in this document

Every diagnostic has a stable snake_case code, a severity, a file, a `{line, col}` start and end
(end exclusive, same line or later), a title in `SHOUTING CASE` in Elm's style, and a message. The
codes named above are the M1 catalogue; each has at least one `tests/corpus/bad/` fixture.

```
invalid_utf8  invalid_module_path  bare_carriage_return  tab_in_source  invalid_character
invalid_number  unterminated_string  invalid_escape  nested_string_in_interpolation
invalid_char_literal  doc_comment_unattached  module_doc_not_at_top
expected_declaration  expected_token  unexpected_token  unclosed_delimiter
annotation_without_definition  pub_on_definition  opaque_not_on_type  case_without_branches
args_after_question  non_associative_chain  negation_with_space  invalid_tuple_index
duplicate_import  duplicate_import_alias  import_after_declaration  self_import
duplicate_declaration  duplicate_type  duplicate_constructor  shadows_import  duplicate_field
foreign_outside_core
unbound_variable  unbound_constructor  unbound_type  unknown_module_alias
question_in_lambda  question_outside_function
shadowing  duplicate_pattern_variable  duplicate_type_parameter  unbound_type_variable
```

Syntax errors carry Elm-style prose: what the parser was in the middle of, what it saw, and what
it expected — e.g. *I was parsing the branches of this `case` and ran into `else`, which is
indented to column 9. Branches must be indented more than the `case` on column 5.*

## Appendix A. The prelude

These names are in scope in every module without an import. The table is a constant inside the
compiler — it is not read from another module at resolution time, which is what keeps per-file
name resolution independent of every other file. The set is Elm's default imports minus the
effect-system modules (`Platform`, `Cmd`, `Sub` — open, see `fast-compiler.md` §3.1) and minus
`Tuple` (§0). Operators are syntax (§6.5) and are never imported or exposed.

Module aliases usable in qualified names: `Basics`, `List`, `Maybe`, `Result`, `String`,
`Char`, `Debug`.

Exposed types: `Int Float Bool Char String List Maybe Result Order Never`.

Exposed constructors: `True False Just Nothing Ok Err LT EQ GT`.

Exposed values (all from `Basics`):

```
toFloat round floor ceiling truncate max min compare not xor modBy remainderBy negate abs
clamp sqrt logBase e pi cos sin tan acos asin atan atan2 degrees radians turns toPolar
fromPolar isNaN isInfinite identity always never
```

Lowering resolves each to `import_value(Basics, name)` / `import_ctor(Maybe, Just)` etc., the
same form an explicit `import Basics exposing (max)` would produce, so nothing downstream knows
the prelude exists.
