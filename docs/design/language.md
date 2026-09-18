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
symbols            ( ) [ ] { } , : = -> <- \ | _ ?
operators          + - * / // ^ ++ :: == /= < > <= >= && || |> <|
eof
```

| Rule | Detail |
|---|---|
| comments are **not** tokens | they go into a parallel `comments` array (§2.3), so the parser's token stream carries only significant tokens and the formatter re-attaches them by position |
| **longest match among operators** | `\|>` not `\|` `>`; `//` not `/` `/`; `->` not `-` `>`; `<-` not `<` `-`. So `x <-1`, `x <-y`, `x <-(a + b)` and `x <-r.value` all lex as `<-`: a comparison whose right operand is negated needs the space, `x < -1`. |
| `--` after `<` | `--` always begins a comment **except after `<`**: `x <-- c` lexes as `<-`, `-`, `c`. No operator contains `--`. |
| `<-` | legal only in a `let` binding (§6.7), and `unexpected_token` anywhere else |

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
| doc blocks | consecutive `--\|` lines form one block, and two runs separated only by blank lines are one block too (blank lines are invisible to attachment, as in Zig). The block must be followed on the next non-blank line by a declaration (§5.3) or by the `pub` that starts one; blank lines between are allowed. |
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
TypeAlias   := 'type' 'alias' upper_ident lower_ident* '=' Type
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
RecordTypeFields := lower_ident ':' Type (',' lower_ident ':' Type)*
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

**A third row the emitter did not honour, found the same way on 2026-09-18 (queue slice 21) and
fixed by queue slice 23.** The `top-level constants` row promises each constant is initialised
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
  pass, and purity is why neither needs a bundler's `sideEffects` guesswork.
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
| **initialisation at the top level** | A top-level **value** is computed once, when the module is loaded, so it **may not be reachable from its own initialiser** — directly (`x = x + 1`), through other values (`x = y + 1` with `y = x`), or through the functions those initialisers name (`a = f 1`, `f n = n + b`, `b = a`). That is **`cyclic_value`**, and it is the same mistake as the row above with dependency order in place of written order: `backend.md` §5 emits a constant after everything it depends on, which orders every shape except a circle, and a circle falls back to source order and throws a JavaScript `ReferenceError` at load (§6, *Evaluation order*). There is nothing to reorder and nothing written-order could rescue, so the program is refused. **Order alone is never wrong at the top level**: `first = second * 2` above `second = 3` is fine and must run, which is what makes this rule about cycles and not about position. A **function** is untouched, so mutual recursion between top-level functions is unrestricted; what a function may not be is a step on a circle that a *value*'s initialisation closes. One diagnostic per circle, at the first VALUE on it in source order, naming the whole circle in the order it runs and the first function in between — `import_cycle`'s shape one scope down. Enforced by the **checker** and not by lowering (`checker.md` §6.7), because a `method_call` adds no `refs` edge (§8) and only the checker's dispatch table has that half of the graph. |
| how far the analysis reaches, and where it stops | **conservative, and deliberately so.** Mentioning a `let` function counts as calling it, whether or not it is called. A value whose right-hand side **is a lambda** (`g = \_ -> later`, and `g = f a _`, whose placeholder wraps the whole application in one) is the single exception: nothing runs when it is bound, so it may name a later value, and calling it is what reads that value — so mentioning `g` counts as calling `g`, exactly as for a function, and `h = g ()` above `later` is refused. A lambda anywhere else inside a value's right-hand side is **not** deferred, because whatever it was passed to may call it at once (`List.map xs (\_ -> later)` does), and a nested `let` inside a value's right-hand side is not deferred either. Those two refuse programs that would have run; the alternative is a call graph that has to be right about every higher-order function, and a wrong answer there is a `ReferenceError` a user cannot see coming. **The top-level rule reaches exactly as far, and stops in the same places**: mentioning a top-level function counts as running it, a declaration whose right-hand side is a lambda defers (so it may name a value that is written anywhere, and calling it is what reads that value — `seed = deferred ()` with `deferred = \_ -> seed + 1` is refused), a lambda anywhere else does not defer, and a reference that leaves the module is not an edge at all, because the module graph is a DAG and an import circle is already `import_cycle`. |
| provenance of the initialisation rule | Manager decision of 2026-09-18 (queue slice 21), owner offline; reversible. The alternative considered and rejected was to **re-sort** a `let`'s bindings into dependency order, the way the backend already sorts top-level constants. It was rejected because §6's table is normative and says `let` bindings evaluate in written order: sorting would make the order of two `Debug.log`s — and, when effects land, the order of two effects — depend on which names one initialiser happens to mention. `core/Dict.beni`'s `mapTree` already depends on the written order it has. The TOP-LEVEL half is queue slice 23 of 2026-09-18, on the same terms; there the rejected alternative was to leave it to the backend — emit a circle's members as `let` bindings, or wrap each in a thunk — which buys a program nobody can read a run it cannot explain, and costs every constant an indirection to rescue the shapes that are mistakes. |
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
`let` are always vertical.

| Construct | Rule |
|---|---|
| **Whitespace and file shape** | |
| indentation, endings | 4-space indentation. LF line endings. One trailing newline. No trailing whitespace. |
| file shape | module doc block, blank line, imports sorted by module path one per line, two blank lines, declarations separated by two blank lines. Blank lines between `let` bindings and between `case` branches: at most one, kept if present. |
| comments | stay attached to the token they precede; a comment on its own line stays on its own line; a trailing comment stays at the end of its line; doc blocks get a space after `--\|` |
| literals | strings, numbers and chars are printed as written, with no escape normalisation; the formatter never changes bytes inside a literal |
| **Declarations and types** | |
| annotation, `=` | the annotation goes on its own line directly above its definition, with `pub` on the annotation line. `=` goes at the end of the head line and the body on the next line indented 4 — always, for top-level definitions and `let` bindings alike, as elm-format does. |
| annotations, `type alias`, `type` | an annotation or `type alias` prints `name :` … on one line if the type fits in 100 columns, otherwise broken at `->` with the arrows leading continuation lines. A `type` declaration puts `=` and each `\|` at the start of their own lines, indented 4. |
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
```

**Two of these codes have two sources.** `refutable_let_pattern` and `refutable_parameter_pattern`
are raised by the **parser** for the shapes no type can rescue and by the **checker** for a
constructor whose type has more than one (§7; [`checker.md`](checker.md) §6.6, §8.1). One rule, one
code per position, two places that enforce it — the message differs, because only the checker's can
name the constructors that are missing. `nesting_too_deep` is shared the same way (§5).

**How the catalogue is laid out.** After the M1 catalogue:

| Lines | Milestone | What they are |
|---|---|---|
| the next three | M2a | the module graph and cross-module name resolution |
| then | M2b | type errors, defined in [`checker.md`](checker.md) §8 |
| then | M2c | the exhaustiveness pair — `missing_patterns` is a `case` with no branch for some possibility, `redundant_pattern` a branch no value can reach ([`checker.md`](checker.md) §6.6), both reported only for a declaration that type-checked, so the patterns they judge are known to be well typed. A third code, `pattern_budget_exhausted`, joined them on the last line of the catalogue |
| the next two | M3a | about the JavaScript boundary rather than beni: the four `foreign_*` codes here are build-time checks of [`boundary.md`](boundary.md) §4, and a fifth is the last line of the catalogue; `missing_main` and `main_not_program` are §5's "`main` is a platform-owned opaque `Program`"; `not_implemented` is what the code generator says about a construct it does not compile yet — a diagnostic rather than a panic, because [`backend.md`](backend.md) §1 ships the language in halves and the missing half has to say so |
| the next five | static dispatch | ten codes appended on 2026-09-18, never inserted, so no line above moved, and an eleventh appended the same day. The first two are reported by lowering, from a `where` clause that names a variable the annotation does not have or the same `(variable, method)` twice; the rest are the checker's, about a method that does not exist, is private, has nowhere to live, was used without being constrained, was constrained twice at different types, needs an annotation to dispatch on a return type, is a constraint that reached an inferred `pub` interface (a `warning`, on by default and only for the root package), survived onto a declaration with no parameters, or — the eleventh — is one of more than 64 constraints an unannotated declaration inferred, which is refused so that neither the interface suffix nor the checker's own bookkeeping is unbounded. Four existing codes are reused rather than duplicated: `not_equatable`, `unbound_variable`, `unexpected_token` and `nesting_too_deep`. → `static-dispatch-spike.md` §10 |
| the fifth-from-last line | M3a again | `foreign_arity_mismatch`, appended on 2026-09-18 rather than filed with its four siblings above, so that no line moved. It is [`boundary.md`](boundary.md) §4's **check 4**: a sibling export's parameter count must be the declaration's evidence count plus its declared arity, and the two export forms whose parameter list cannot be counted — a bare name and a rest parameter — are refused under the same code (`static-dispatch-spike.md` A.84) |
| the fourth-from-last line | M2c again | `pattern_budget_exhausted`, appended on 2026-09-18 (queue slice 14) rather than filed with the exhaustiveness pair above, so that again no line moved. It is the one code of the three that is about the compiler and not the program: deciding a `case` can cost exponentially much, so the analysis spends a bounded amount of work on it (`--pattern-budget=<n>`), and a `case` it could not decide is **refused** rather than passed over in silence. Silence there was an exit-0 miscompile, because [`backend.md`](backend.md) §7 compiles a `case` to a decision tree with no default arm on the strength of the checker having proved it exhaustive. The message names the budget in force and says the two ways past it: split the match, or raise the flag |
| the third- and second-from-last lines | M3 again | the two halves of §7's **initialisation** rule, appended on 2026-09-18 (queue slices 21 and 23) and again never inserted. `let_forward_reference` is lowering's, about a `let` value binding that reads one written below it; `cyclic_value` is the checker's (`checker.md` §6.7), about a top-level value reachable from its own initialiser. They are one defect at two scopes: a name that is in scope but has no value yet, emitted as a JavaScript `const` and read inside its temporal dead zone. Both were exit-0 paths from a well-typed program to a `ReferenceError` at load, and both are refusals rather than reorderings — the first because §6's table says `let` bindings run in written order, the second because a circle has no order to be put into |
| the last line | M3a again | `duplicate_main`, appended on 2026-09-19 (queue slice 37), again never inserted. A project with more than one `main` was refused under `missing_main`, whose title — MISSING MAIN — says the opposite of the message printed under it, and whose code told a tool routing on it that a project with two entry points had none. A build is a pair of ONE entry point and ONE platform ([`boundary.md`](boundary.md) §5.3), so two `main`s are two builds, which is a different edit from the one "MISSING MAIN" asks for. The message names both modules and both locations, and which of the two it calls the first is the lower module index — the sorted path, never argument or completion order (CLAUDE.md rule 5). `--library` turns the whole rule off, `missing_main` with it |

**The three generic syntax codes**, all carrying Elm-style prose — what the parser was in the middle
of, what it saw, and what it expected, e.g. *I was parsing the branches of this `case` and ran into
`else` at column 9, but the branches of this `case` start at column 13.*

| Code | When |
|---|---|
| `expected_token` | exactly one token can come next: `)`, `]`, `}`, `->`, `of`, `then`, `else`, `in`, `=`, `:` |
| `unexpected_token` | the start of a construct — an expression, a pattern, a type, an exposing entry — was needed and the token cannot start one. A misaligned `let` binding or `case` branch — a token inside the block, at a column other than the first sibling's, that could start a binding or branch — is reported with this code, quoting both columns, and then parsed as a sibling, so one misalignment yields one message. A token that cannot start a sibling ends the list silently and the enclosing construct decides. |
| `expected_declaration` | the top-level form of `unexpected_token` |

**Depth limits**, both reporting `nesting_too_deep`:

| Limit | Where | Rule |
|---|---|---|
| nesting deeper than 4096 levels | the parser, over expressions, types and patterns | reported at the point where the limit is crossed; the file is otherwise parsed. It is the one limit the parser imposes, so hostile input cannot overflow the stack. |
| 512 levels | the type checker reading a type, reported at the declaration (`checker.md` §5) | lower on purpose — an annotation is one tree among many and reading it also spends a level per alias expansion — so a file the parser accepts can still be refused here. What the checker may not do is refuse it silently: past the limit the type is poisoned, and a poisoned type unifies with anything, so a declaration truncated without a message would be a hole a caller's mistake falls through. |
| charged per declaration | the iteratively built spines — an operator chain, an access chain, a `?` chain | they hold their charge until the declaration ends, so a declaration whose chains total more than 4096 links is refused even when no single path is that deep. Accounting each spine exactly would mean a depth per node through the AST — four bytes on every node, to buy a case no real program reaches; revisit it if one does. |

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

**Which module a prelude type belongs to moved for two of them, and the table above did not change.**
`String` and `Char` are declared in `String` and `Char` rather than in `Basics` (§5.4), because the
module rule makes a type's methods its declaring module's `pub` values. Both stay prelude *types*,
so every module still names them unqualified and no module gains an import; what changes is where
the conditional prelude *edge* points, and which module a string or character literal mints its type
from. → `static-dispatch-spike.md` §5.1.
