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

**One array-backed sequence type.** Decided by the owner on 2026-10-01, specified here the same
day, not built: `List` is array-backed and is beni's only sequence type. The syntax is Elm's; an
`x :: rest` pattern is an O(1) view, `x :: xs` as an expression copies, and a list grows at its end
with `List.push`. §6.8 is the surface, `backend.md` §4 *Lists are arrays* the representation.
*Amended 2026-10-01, the owner (W35, E1tp):* a list's trie has a claimable head as well as a
claimable tail, so `[ x, ...xs ]` is amortised O(1) like `List.push` and no longer a copy; it
grows at either end.

**Brackets and a spread, and no `::`.** Decided by the owner on 2026-10-01 (W35's second
amendment), specified and built the same day on today's cons cells: `::` leaves the language, as an
operator, as a pattern and as `(::)`. A list is written, built and matched with brackets and a `...`
spread, as in JavaScript — `[ x, ...rest ]` and `[ ...init, last ]` as patterns, `[ 0, ...xs ]`,
`[ ...xs, 4 ]` and `[ ...a, ...b ]` as expressions. §6.8, *The list syntax*, is the contract; where
the text of §6.8 and `backend.md` written before it still says `x :: rest`, read `[ x, ...rest ]`.

**Blocks, `λ` and trailing lambdas.** Decided by the owner on 2026-10-02, specified here the same
day, not built (§12): a lambda is written `λx -> e` and only so, `\` being removed; `let … in` leaves
the language, and a body written as lines is a **block** of bindings and statements whose last line
is its value, a statement being an expression of type `()`; an application's last argument may be a
lambda without parentheses; `modBy`, `remainderBy` and `logBase` become `Int.mod`, `Int.rem` and
`Float.log`, and `Debug.log` takes its label first again; and `beni fmt --check` joins the gates.
Where text written before §12 says `\x ->` or `let … in`, read `λx ->` and a block.

**Unicode notation.** Decided by the owner on 2026-10-01 (`plans/browser-decisions.md` S8),
specified the same day in §12.7–§12.9, not built: Lean 4's symbols, one spelling each — `→` for
`->`, `←` for `<-`, `≠` for `/=`, `≤` and `≥` for `<=` and `>=`, `▷` and `◁` for `|>` and `<|`,
`…` for the spread `...`, and `×` for a tuple **type** (`Int × String`; values and patterns keep
`( a, b )`). `&&`, `||`, `==` and `++` stay ASCII. Each ASCII form is removed with a diagnostic
naming the symbol, after a migration. Where text in this document says `->`, `<-`, `/=`, `<=`,
`>=`, `|>`, `<|`, `...` or a parenthesised tuple type, read the symbol; the text keeps the ASCII
until the migrate step rewrites the examples.

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
| `List` is a cons list, `Array` a separate type | `List` is the one sequence type, array-backed: O(1) `length`, indexed `get`/`set`, `push` at the end; `x :: rest` patterns are O(1) views, `x :: xs` as an expression is a copy (*2026-10-01, specified, not built*; *amended the same day, E1tp:* `[ x, ...xs ]` is amortised O(1), not a copy) | §6.8 |
| `x :: xs`, `x :: rest ->`, `(::)` | `[ x, ...xs ]`, `[ x, ...rest ] ->`, `List.cons`; and what Elm cannot write, `[ ...xs, x ]`, `[ ...a, ...b ]`, `[ ...init, last ] ->`, `[ first, ...middle, last ] ->` (*2026-10-01, built*) | §6.8 |
| `\x -> e` | `λx -> e`; `\` is `backslash_lambda_removed` (*2026-10-02, built*) | §12.1 |
| `let` / `x = 1` / `in` / `x + 1` | a block: `x = 1` / `x + 1`, with statements of type `()` between the lines (*2026-10-02, specified, not built*) | §12.2 |
| `f a (\x -> e)`, `f a <\| \x -> e` | `f a λx -> e` (*2026-10-02, specified, not built*) | §12.3 |
| `modBy 2 n`, `remainderBy 3 n`, `logBase 10 x`, `Debug.log "l" v` | `Int.mod n 2`, `Int.rem n 3`, `Float.log x 10`, `Debug.log "l" v` (*2026-10-02; built 2026-10-01, the types staying in `Basics`*) | §12.4 |
| `->`, `<-`, `/=`, `<=`, `>=`, `\|>`, `<\|`, `...` | `→`, `←`, `≠`, `≤`, `≥`, `▷`, `◁`, `…` — one spelling each; `&&`, `\|\|`, `==`, `++` unchanged (*2026-10-01, specified; built 2026-10-02*) | §12.7 |
| `( Int, String )` as a type | `Int × String`; `a × b × c` is a 3-tuple, and `Int × Int → Int` takes one pair where `Int, Int → Int` takes two arguments (*2026-10-01, specified; built 2026-10-02*) | §12.8 |
| `()`, the unit type and value; `Never` | `⊤` in both roles — `String → ⊤`, `else ⊤`, `λ⊤ → e`; `⊥` for the empty type (*2026-10-02, built*) | §12.10 |
| `if c then a else ()` | `if c then a`: an `if` whose `then` branch is `⊤` may leave out its `else` (*2026-10-02, built*) | §12.10 |

Everything else — application by juxtaposition, `case … of`, `if … then … else`, records, record
update, lists, tuples, type aliases, custom types, `as` patterns, `.field` accessors — is Elm's.
(`::` patterns were on this list until 2026-10-01, §6.8; `\x ->` lambdas and `let … in` until
2026-10-02, §12.)

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
| column, line | both 1-based; column counts *bytes* from the line start. Tabs are forbidden and indentation is always leading spaces, so byte column equals visual column for every token that starts after ASCII-only indentation. Diagnostics report `{line, col}` pairs, derived from token offsets and the file's line-start table. *Amended 2026-10-02:* a `λ` is two bytes and one column on screen; what that costs layout is §12.1's *columns* row. *Amended 2026-10-01 (§12.7), built 2026-10-02:* a column counts code points, not bytes — in diagnostics, excerpts and layout alike — so `λ`, `→` and the other symbols are one column each; byte offsets stay what spans are made of. |

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
symbols            ( ) [ ] { } , : = -> <- \ | _ ? .. ...
operators          + - * / // ^ ++ == /= < > <= >= && || |> <|
                   (and `::`, lexed only to be refused, §6.8)
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
| `...` | *Added 2026-10-01.* One token, `ellipsis`, wherever code is lexed — longest match, so `...` is never `..` and `.`. It is the spread of a list (§6.8) and, as the first token of a hole in a tag, the spread of a component's attributes (§11.5), which is where it was a token before. Anywhere else it is `unexpected_token`, with a message that says where a spread goes |
| `::` | *Amended 2026-10-01.* Still one token, `op_colon_colon`, but no construct uses it: it is lexed only so that the parser can report `cons_removed` with the bracket form in the message (§6.8, §10), once for a whole `a :: b :: rest` |
| `λ`, `\`, `let`, `in` | *Added 2026-10-02 (§12.1, §12.2).* `λ` (`CE BB`) is the symbol `lambda`, the one non-ASCII token. `\` stays the token `backslash` but no construct uses it: it is lexed only so that the parser can report `backslash_lambda_removed`. `let` and `in` stay keywords, used by no construct, so that a `let` can be reported as `let_removed` |
| `→ ← ≠ ≤ ≥ ▷ ◁ … ×` | *Added 2026-10-01 (§12.7, built 2026-10-02).* Nine more non-ASCII tokens, each the new spelling of a symbol or operator above with its grammar and binding power — `×` excepted, a type token of its own (§12.8). The ASCII `->`, `<-`, `/=`, `<=`, `>=`, `\|>`, `<\|` and `...` become `ascii_*` tokens, lexed after the enforce step only to be reported as `ascii_symbol_removed`, as `\` is. §12.7 lists the lookalikes the lexer refuses with a named suggestion |

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
| ASCII only | a non-ASCII byte outside a string, char or comment is `invalid_character`. *Amended 2026-10-02:* except the two bytes of `λ`, which are the `lambda` token (§12.1). *Amended 2026-10-01 (§12.7):* and the nine symbols `→ ← ≠ ≤ ≥ ▷ ◁ … ×`; a lookalike of one (`⇒`, `−`, `▹` …) is `invalid_character` with the symbol named in its message |
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
(`fast-compiler.md` §3.1, `checker.md` Appendix B). *Amended 2026-10-02:* `modBy` and `remainderBy`
become `Int.mod` and `Int.rem` (§12.4), the names `Int32` already uses, with the same signs and the
same zero.

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
| layout, and vs a lambda | column rules (§4) apply to the `\\` marker like any other token. One byte of lookahead separates it from a lambda: `\` followed by `\` is a multiline line, `\` followed by anything else is the lambda backslash. *Amended 2026-10-02 (§12.1):* the lambda is `λ`, and a lone `\` is lexed only to be reported as `backslash_lambda_removed`. In a block, consecutive `\\` lines are one literal whatever their column (§12.2 B3). |

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
Foreign     := 'foreign' Rung lower_ident ':' Type            -- core root only, §5.4
             | 'equatable'? 'foreign' 'type' upper_ident lower_ident*   -- 'equatable' core only
Rung        := 'pure' | 'impure' | 'suspends'                -- contextual words, §5.4
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
             | 'sync' '(' Type ')'                               -- a top-level signature only, §5.4
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
             | '[' ']' | '[' ListItem (',' ListItem)* ']'        -- list (§6.8)
             | '{' '}' | '{' Field (',' Field)* '}'              -- record
             | '{' lower_ident '|' Field (',' Field)* '}'        -- record update
             | Atom dot_lower                                    -- field access, no space
             | Atom dot_index                                    -- tuple access, no space
Field       := lower_ident '=' Expr
ListItem    := Expr | '...' Expr                                 -- a spread, any number (§6.8)

Pattern     := PatCtor ('as' lower_ident)?                       -- `as` binds loosest
PatCtor     := (upper_ident | qualified_upper) PatAtom+ | PatAtom
PatAtom     := '_' | lower_ident
             | upper_ident | qualified_upper                     -- nullary constructor
             | int | char | string-without-interpolation | '-' int
             | '(' ')' | '(' Pattern ')' | '(' Pattern (',' Pattern)+ ')'
             | '[' ']' | '[' PatItem (',' PatItem)* ']'          -- list (§6.8)
             | '{' lower_ident (',' lower_ident)* '}'            -- record pattern
PatItem     := Pattern | '...' (lower_ident | '_')              -- at most one spread (§6.8)
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

*Amended 2026-10-01* (§0, §6.8): `ListItem`, `PatItem` and the two list lines are new, and
`PatCons := PatCtor ('::' PatCons)?` is withdrawn with the `::` operator, so a `Pattern` is a
`PatCtor` with an optional `as`. A `::` where an operator or a pattern could continue is parsed as
it was and reported as `cons_removed` (§10); nothing else in the grammar changed.

*Amended 2026-10-02* (§12): `Definition`'s right-hand side, the four `Expr` forms, `LetBinding`,
`Branch` and `Block` are replaced by §12.2's productions — a body is a `Block` of items or an
`Expr`, the lambda is `'λ' Param+ '->' Body`, `let … in` is gone, §3's `Block` is renamed
`TailForm` without `let`, and `Atom` gains the parenthesised block — and `App` gains §12.3's
`TrailingLambda`. `LetPattern` keeps its name and its rule: it is the pattern of a block's pattern
binding and of a bind. The old `let` and `\` forms are still parsed, to be reported as `let_removed`
and `backslash_lambda_removed`.

*Amended 2026-10-01* (§12.7–§12.8, built 2026-10-02): every `'->'` above is `'→'`, `'<-'` is
`'←'` and `'...'` is `'…'`; `Type` and `TypeParams` are built from §12.8's `Product`, a `TypeApp`
chain joined by `'×'`, and `TypeAtom`'s tuple line is withdrawn — a parenthesised tuple type is
still parsed, to be reported as `tuple_type_removed`. The **Types** table below is §12.8's table
in the ASCII spelling: where they differ, §12.8 is the rule.

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
| `case`, lambda, leading operator | `case` needs at least one branch (`case_without_branches`); a lambda is `λx y -> e`, one or more pattern atoms; an expression may not begin with an operator, except `-` for negation (§6.5) |
| a `let`, `if`, `case` or lambda | **may be the *last* operand of an operator chain** (`f <\| λx -> x + 1`, `text <\| if a then b else c`), as in Elm; it extends as far as the layout allows, so nothing can follow it in the chain. It may not be a bare application argument: `f λx -> x` is an error, write `f (λx -> x)`. `\|>` is the exception and takes no block (§6.7). *Amended 2026-10-02:* `let` is gone and the lambda is `λ` (§12); a lambda **may** now be an application's last argument without parentheses (§12.3), and an `if` or `case` still may not. |
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
*Amended 2026-10-02:* the `let` binding list these rows and rule 3 describe is now the **block**
(§12.2): a body whose first token begins a line, with items aligned at that token's column, every
other token of an item right of it or — when it cannot start an expression, a leading `,` or a
closing bracket — at it. §12.2's B1–B6 are the rules; rule 3 and the two `let` rows above describe
the removed form, and the worked example below is §12.2's once `let`/`in` are deleted and the
bindings moved out to the `in` body's column.
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
            title = "Hi"
            body =
                text title
            div [] [ body ]

        About ->
            text "about"
```

`case` body indent is 1 (the declaration). Branches at column 9; `Home` body is anything at column >
9, and since it begins a later line it is a block (§12.2) whose items sit at column 13; `body`'s
body continues at column > 13; `div` at column 13 begins the block's last item, its value. `About`
at column 9 is left of 13 (ends the block) and starts the next branch; the blank line is trivia.
*Amended 2026-10-02:* the example was a `let … in` until blocks replaced it. The rules are lexically decidable: the only inputs are each
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
pub foreign pure add : number, number → number

pub foreign type List a
```

| Rule | Detail |
|---|---|
| shape | `foreign name : Type` declares a value with that type and no definition. `foreign type T a…` declares a type with no constructors, so it is opaque by construction; `opaque` before `foreign` is `unexpected_token`. Both take `pub` and may carry a doc comment. |
| rung | *Added 2026-09-30.* A `foreign` value states what calling it may do, between `foreign` and its name: `pub foreign pure add : number, number -> number`, `pub foreign impure log : String, a -> a`, and `suspends` for a primitive that may park its fiber. The word is contextual — an ordinary identifier everywhere else — and never omitted (`foreign_effect_missing`, `unknown_foreign_effect`). `pure` means total and non-throwing. The checker infers every other function's bits from these ([`transparent-effects-proposal.md`](transparent-effects-proposal.md) §14). |
| `sync` | *Added 2026-09-30.* A function type the sibling may call synchronously is marked `sync` where the `foreign` receives it: `pub foreign pure onInput : sync (String -> msg) -> Attribute msg`. The checker refuses a function that may suspend there (`sync_boundary`). The word is contextual — the marker only in a `foreign` value's signature, directly before `(`, and an ordinary type variable everywhere else — and it must mark a function type written out, in an argument position of the declaration's arrow (`misplaced_sync` otherwise). *Amended 2026-10-02 (R47-4):* a platform package may write it in the signature of any top-level declaration, not only a `foreign`'s — the word is the marker in every top-level annotation — and the checker then demands the marked function of every caller as it does a `foreign`'s; in a package that may not write `foreign` it is `misplaced_sync`. *Amended 2026-10-02 (research 48 decision 10):* core is a package that may (`boundary.md` §2), and `Ref.update` and `Ref.modify` mark their function parameter `sync` this way, so no other fiber runs between their read and their write ([`transparent-effects-proposal.md`](transparent-effects-proposal.md) §17.2). A `foreign`'s `where` evidence, a markup primitive's function parameters, markup's handlers and row and key functions, `main` and a type's `eq` and `compare` are `sync` with nothing written ([`transparent-effects-proposal.md`](transparent-effects-proposal.md) §15; `boundary.md` §4). |
| `foreign_outside_platform` | `foreign` is **legal only under the core root**, which is embedded in the compiler (`fast-compiler.md` §3.1, "Primitives"); a `foreign` declaration in any other module is this, reported by lowering. User code reaches JavaScript through the effects model (open), never through `foreign`. |
| which types | the primitive types are foreign: `Int`, `Float`, `Char`, `String`, `List a`. `Bool`, `Maybe`, `Result` and `Order` are ordinary declared types in core. `Char` and `String` are declared in `Char` and `String`, not in `Basics`: under the module rule a type's methods are its declaring module's `pub` values, and `String.compare` is the method `String` should always have had (spec §5.1). Both stay prelude types, so no module gains an import. |
| `Js` | *Added 2026-10-02* (the owner's S7). Core's `Js` module, JavaScript written from beni ([`boundary.md`](boundary.md) §4.2), may be imported by every core and platform module, `Basics` and `Char` included, and an import of it never closes a cycle: its signatures name no core type, so it depends on nothing, and a string or list literal that a `Js` call writes in place — a property name, an argument list — mints no edge to `String` or `List` (`static-dispatch-spike.md` §6.8, amended). Outside core and a platform package `import Js` is still `js_outside_platform`. |
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
`(a, b, c)` is a tuple literal; `(a)` is grouping. *Amended 2026-10-02 (§12.10; built the same
built):* unit is written `⊤`, the type and the value, and `()` is removed (`unit_spelling_removed`).

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
| 5 | `++` | right (`::` stood here until 2026-10-01, §6.8) |
| 6 | `+` `-` | left |
| 7 | `*` `/` `//` | left |
| 8 | `^` | right |
| — | `?` postfix, application, `.field`, `.0` | tighter than all of the above, in that order (tightest last) |

*Amended 2026-10-01 (§12.7, built 2026-10-02):* `◁` and `▷` are written for `<|` and `|>` at
precedence 0, and `≠`, `≤`, `≥` for `/=`, `<=`, `>=` at precedence 4, each with the binding power
and associativity of the operator it replaces; the ASCII spellings are removed
(`ascii_symbol_removed`). `||`, `&&`, `==`, `<`, `>`, `++` and the arithmetic operators do not
change.

| Rule | Detail |
|---|---|
| mixing `<\|` and `\|>` | at precedence 0 without parentheses it is `non_associative_chain`: they associate in opposite directions, so a mixed chain has no predictable reading, and Elm rejects the same pair. `<<` and `>>` are removed, and with them the precedence-9 case of this rule and the composition idiom, which is replaced by naming the argument. |
| **negation** | `-` directly followed (no whitespace) by an atom, where the parser expects the *start* of an operand: `-x`, `-(a + b)`, `-1`, `[ -1, -2 ]`. The operand is one atom with its access chain, so `-r.value` is `-(r.value)` and `-f x` is `(-f) x`, as in Elm. Negation of an integer literal in a *pattern* is a literal pattern (`-1 ->`). `- x` with a space in prefix position is `negation_with_space`; `a - -b` is allowed. |
| `f -1` | **not** negation: in argument position the parser has parsed `f` and sees `-` where either an argument or an operator may follow, and **it is the binary operator**, as in Elm, so `f -1` is `f - 1`. Write `f (-1)`. |
| **operators as functions** | `(+)`, `(++)`, `(==)` and so on (`(::)` went with `::` on 2026-10-01 and is `cons_removed`, whose message names `List.cons`): any operator from the table that lowers to a call or to a method call, each being the 2-ary function it lowers to. The six comparison operators lower to a lambda over a marked method call, not to a reference to `Basics.eq` — so `(==)` is `λa b -> a.eq b` with the operator's own pinning rule, not structural equality (spec §3.1). Whitespace inside the parentheses is allowed and the formatter removes it. Sections such as `(+ 1)` do not exist; `(-)` is the binary minus function and there is no negation function. `\|>` and `<\|` are syntax, not calls, so `(\|>)` and `(<\|)` do not exist and are `operator_not_a_function`. |

**The six comparison operators are method calls, not `Basics` calls** (§0). `a == b` and `a /= b`
lower to a call of `eq` on `a`'s type; `a < b`, `a <= b`, `a > b`, `a >= b` to a call of `compare`,
whose `Order` result the backend tests. The operator form **pins both operands to one type** — which
a hand-written `a.eq b` does not — and the compiler **derives** `eq` and `compare` for a type whose
module declares none, structurally and recursively, so `==` on a record of lists of user types keeps
working and `"a" < "b"` now compiles. `Basics.eq`, `neq`, `lt`, `gt`, `le`, `ge` and `compare` stay
declared, exported and callable by name; they are simply no longer what the operators mean. Nothing
in the precedence table above changes. → `static-dispatch-spike.md` §3.

*Amended 2026-10-02 (the owner):* `Basics.eq` and `Basics.neq` called by name **mean exactly what
`==` and `≠` mean**: `eq : a, a → Bool where a.eq : a, a → Bool`, whose body is `a == b`, so they
call the receiver type's own `eq` as the operator does. They were a structural walk that ignored a
type's own `eq` — a silent wrong answer. `lt`, `gt`, `le`, `ge` and `compare` take `number` only
and agree with the operators already (`static-dispatch-spike.md` §3.1, amended).

### 6.6 `?`

`e?` where `e : Result x a` yields `a` or returns `Err x` from the enclosing function; where
`e : Maybe a`, yields `a` or returns `Nothing`. The front end enforces precedence and scope:

| Rule | Detail |
|---|---|
| precedence, `args_after_question` | **application binds tighter than `?`, which binds tighter than every binary operator** (§6.5), so `parse s? \|> f` is `((parse s)?) \|> f` and `f (a?) b` is how `?` is applied to one argument. `f a? b` is `args_after_question`: after `?` no further arguments may follow. An adjacent access chain may: `x?.field` is `(x?).field`, `x.field?` is `(x.field)?`, and `r??` applies `?` twice. |
| what it returns from | **the nearest enclosing definition that has parameters**, top-level or `let`. A `let f x = g x?` inside `view` returns from `f`; a `let y = g x?` (no parameters) inside `view model` returns from `view`, as `let y = g(x)?;` does in Rust. |
| `question_outside_function`, `question_in_lambda` | the first when no enclosing definition has parameters — a top-level constant, or constants all the way up; the second when a lambda sits between the `?` and that definition, a `_` placeholder and a `<-` callback both counting as lambdas here (§6.7) |
| in a block | *Added 2026-10-02 (§12.2).* A block's definitions are what a `let`'s were for the two rows above. A statement `e?` yields the `()` a statement must be, so `validate input?` on a line of its own returns the error from the enclosing function or carries on |
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
call does not supply: `f a _ c` is `λx -> f a x c` for a fresh `x`.

| Rule | Detail |
|---|---|
| `placeholder_outside_argument`, `multiple_placeholders` | `_` is an argument, never an expression of its own: `let y = _`, `_ + 1` and `f (_)` are `placeholder_outside_argument`, which takes precedence over the generic `unexpected_token` that §10 would otherwise give. At most one `_` per application (`multiple_placeholders`), as in Gleam; two omitted arguments are written as a lambda. |
| position, and what the lambda wraps | a placeholder may fill any position, the first included. The lambda wraps the **innermost enclosing application**: in `f (g _) b` the placeholder belongs to `g`, and what `f` receives is `λx -> g x`. |
| order against pipes | **pipes rewrite before placeholders lift** (§8): `e \|> f a _` is `f e a _` and then `λx -> f e a x`. Lifting first would leave a lambda as the pipe's right operand and reject the program. |
| `f _.name` | applies `f` to the placeholder **and** to the accessor `.name`, because a `dot_lower` must abut an `Atom` and `_` is not one. Write `f λr -> r.name` for the other reading. |
| in patterns, and against §6.6 | `_` keeps its pattern meaning (§3, `PatAtom`) everywhere a pattern is expected, and the two positions never overlap. **A placeholder is a lambda** for §6.6, so a `?` inside the application it lifts is `question_in_lambda`: `f a? _` is rejected. |

**`|>` is pipe-first syntax.** `e |> f a b` rewrites to `f e a b` and `e |> f` to `f e`: the left
operand becomes the callee's **first** argument. `<|` keeps Elm's meaning: `f <| e` is `f e`.

| Rule | Detail |
|---|---|
| `pipe_rhs_not_application` | the right operand of `\|>` must be an **application**, and nothing else. A `let`, `if`, `case` or lambda has no head application to insert into, so §3's rule admitting a block as the last operand of a chain does not extend to `\|>`. `<\|` carries blocks and the trailing-lambda idiom, and is unaffected. |
| grouping, and not calls | **parentheses around the right operand are looked through**, as lowering already does: `x \|> (f a)` is `f x a`, not a call of the value `(f a)`. `\|>` and `<\|` are syntax, not calls, so neither has a parenthesised form (§6.5). |
| library convention | because the pipeline inserts at the first argument, **the standard library is subject first and function last**: `List.map xs f`, `String.split s sep`, `Dict.insert d k v`, `Result.andThen r f` — the convention that makes a pipeline read and lets `<-` reach every callback-taking function |

**`let x <- e` binds the rest of the block.** `let x <- f a b in rest` desugars to
`f a b (λx -> rest)`: the remaining bindings and the body become the callee's last argument. It is
purely syntactic — no type-constructor table, no dispatch, nothing that depends on inference.
*Amended 2026-10-02 (§12.2):* with `let` gone a bind is a block item, `x <- f a b`, and `rest` is
every item after it; a bind is never the last item (`block_ends_in_binding`). The table below holds
with "the remaining bindings and the body" read as "the remaining items".

```elm
scope ← Task.scope
conn ← Task.bracket (λ⊤ → Db.open url) Db.close
h ← Result.andThen (readHeader s)
render scope conn h
```

| Rule | Detail |
|---|---|
| right-hand side | **the callee applied to all but its final argument.** For a callee of arity one that is the bare name: `scope <- Task.scope` is `Task.scope (λscope -> rest)`, the shape the form was generalised for (`fast-compiler.md` §9.3 item 7). A qualified name, a field access, a parenthesised operator and a parenthesised application are legal heads for the same reason. |
| `bind_rhs_not_application` | anything that is not a call once the rest of the block is appended — a `case`, an `if`, a lambda, a `let`, a `?`, an arithmetic expression |
| pipes | a `\|>`/`<\|` chain is legal in principle, because pipes rewrite before the bind does (the order rule above), so `let x <- File.read path \|> Task.mapError f` means `Task.mapError (File.read path) f (λx -> rest)`. The chain's head application is what receives the callback, so the bind attaches to `Task.mapError`, not to the pipe. |
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
| binary operator `a ⊕ b` | **the left operand, then the right**, whatever the operator desugars to — a `Basics` call (`+`), a method call (`==`, `<`, §6.5) or `Basics.append` (`++`). The desugaring is an application, so this is the row above and not a separate rule |
| `&&`, `\|\|` | the left operand, then the right **only when the left does not decide it**. This is why `Basics.and` and `Basics.or` are `foreign`: a call would evaluate both (`backend.md` §4, correction 3). A right operand that needs statements of its own gets them inside the branch |
| `\|>`, `<\|` | **pipes rewrite before anything runs** (§6.7, §8), and the rewritten form's order is what holds. For `\|>` the two agree: `e \|> f a` is `f e a`, so `e` — written first — is evaluated first. For `<\|`, `f a <\| e` is `f a e` and `a` precedes `e`, which is again source order |
| `_` placeholder | **the lambda evaluates nothing when it is built.** `f (g x) _` is `λp -> f (g x) p` (§6.7), so `g x` runs on *every* call of that lambda, and after that call's own argument. Bind `g x` to a name first if it should run once |
| `let x <- e` | `let x <- f a in rest` is `f a (λx -> rest)`: `f`, then `a`, then the call; `rest` runs if and when and as often as `f` calls the callback |
| tuple literal, list literal | element by element, left to right. *Amended 2026-10-01:* a spread's operand is an element for this row — `[ a, ...f x, b ]` evaluates `a`, then `f x`, then `b` — and every element and operand is evaluated before the list is built (§6.8) |
| constructor | argument by argument, left to right |
| **record literal** | **field by field, in the order the fields are written** — `{ z = p, a = q }` evaluates `p` then `q`. `backend.md` §4 sorts the emitted object's *keys* so that one record type has one hidden class; that is a representation decision, and it does not move an evaluation |
| record update `{ r \| a = p, b = q }` | `r`, then the updated fields in written order |
| field access `r.a`, tuple index `t.0`, accessor `.a` applied | the subject alone, once |
| string interpolation | segment by segment, left to right; a literal chunk evaluates nothing |
| `if` | the condition, then **exactly one** branch |
| `case` | **the scrutinee exactly once**, then exactly one branch body. A scrutinee that is a tuple literal evaluates each element once, left to right, before any test is made |
| `e?` | the subject once — `?` is a `case` on it (§6.6) |
| `let` bindings | **in the order written.** A binding whose right-hand side is a *function* is available throughout the block, so mutual recursion among `let` functions is unrestricted; a binding whose right-hand side is a *value* may only name bindings written before it — and one that does not is `let_forward_reference` (§7), which is the error that makes "in the order written" a total rule rather than an aspiration |
| a block's items | *Added 2026-10-02 (§12.2).* The row above, with **statements** among the value bindings: each value binding and each statement once, in the order written, then the value. A statement's value is discarded and nothing else about it is special — `_ = e` and a statement `e` evaluate `e` at the same place |
| a self tail call | the new arguments in parameter order, all of them evaluated before any parameter is rebound (`backend.md` §8). *Amended 2026-10-02:* "before" is what a program can see: each argument reads the parameters as they were, and one that makes a call runs in parameter order, but the loop may rebind a parameter no argument still to come reads (§8, *In place, when nothing captures*) |
| top-level constants | each before its own first use, at module load |
| a top-level value with a `where` clause and no parameters | **its initialiser runs once per evidence, at the first use that needs it** (2026-09-26). It takes its evidence as hidden arguments (`static-dispatch-spike.md` §8.1), so it cannot run at load; the emitter keeps the value the last evidence gave, and a read or call with the same evidence reuses it (`static-dispatch-spike.md` A.85 *as amended 2026-09-26*). The memo is ONE slot keyed on the IDENTITY of every evidence argument, so what "the same evidence" means is what the emitter builds: a primitive's evidence, a context-free nominal type's derived function and a `where`-free method are module-level names, and a use whose evidence arguments are all such names runs it once, like the same value without the `where`, only at its first use rather than at load. Evidence built AT the use — a structural type (`List Int`, a record, a tuple) or a nominal type whose derived context is not empty — is a fresh closure at each read, so such a use computes again at each read, as before; so does one instantiation read from two modules, each with its own evidence names. A use with other evidence computes again, and evicts the slot. Hoisting closed evidence to module level, which would make it once per instantiation, is recorded, not done (narrowed 2026-09-26). A body that is itself a reference to a constrained function (`h = maxOf`) computes nothing and is called straight through. `run/EvidenceFunctionBodyPerCall.beni`, `run/EvidenceThunkOncePerEvidence.beni`. *Until 2026-09-26 it ran at EACH read or call.* |
| *markup (the next six rows were added on 2026-09-29 with §11, the helper call the same day; §11.11 says what a render may skip)* | |
| an element or fragment | **its attributes and events, then its children, in source order**, attributes and events interleaved as written, each once; a hole inside a child element is reached when that element is. A constant attribute or a text run evaluates nothing (§11.5) |
| a component | its props in source order, the spread first where there is one, `children` where the children are written; then the call, **unless it is skipped** (§11.8) |
| a call of a top-level function in an `Html msg` hole, `{f a b}` | *added 2026-09-29 with §11.6's helper skip:* the callee and the arguments, left to right, with the markup; then the call, with the platform's render, **unless it is skipped** (§11.6) — as a component's is, after the markup's other values |
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
**pure**: evaluating it produces a value and changes nothing an observer can see — **unless it
calls something the checker infers `impure` or `suspends`** (`transparent-effects-proposal.md`
§14). A `foreign` declares its rung (`foreign pure|impure|suspends`), and every other function's is
inferred from what it calls; `Debug.log` and `Debug.todo` are `foreign impure`, as are `Task.spawn`
and a platform's primitives that start or observe something. So:

- **A binding whose value is never used may be dropped whole — unless its right-hand side may be
  impure or may suspend**, in which case it is **evaluated for its effect** exactly where it is
  written, whatever its pattern binds and whether or not anything reads it. *May* is the checker's
  answer and nothing softer: the right-hand side reaches, outside any function it builds, a call
  whose callee is `impure` or `suspends`, or would be once the enclosing declaration is used with
  something that is — a call of a parameter `f` counts, because one body serves every caller
  (`transparent-effects-proposal.md` §16.2's `impure` answer). **`Debug.log` is kept under the same
  rule**: it is `foreign impure`, and one rule for every impure call is the point. A binding whose
  right-hand side is pure is still dropped whole, initialiser and all. That is `backend.md` §9's
  dead-binding elimination (item 1) and its reachability pass, and the inferred rung is why neither
  needs a bundler's `sideEffects` guesswork. *Amended 2026-09-30.* Until then this bullet read "may
  be dropped whole, everything inside it included, a `Debug.log` among it", and the pass asked
  nothing about a right-hand side. That was sound only while `Debug.log` was the one impure value
  and a `--release` build that reaches `Debug` was refused (2026-09-19, `backend.md` §9's *`Debug`
  is refused, not pinned*); once effects existed it made a release build skip a `Task.spawnIn` or
  an impure platform call its development build performs, which is exactly the difference between
  the two builds that no program may see. `let _ = e` had been kept since the fiber spike (§16.5);
  the rule is now the same for a named binding and for `_`, and `run/ReleaseDeadDebug` prints the
  same lines in both builds.
- **Two evaluations that both survive may not be reordered against each other**, and neither may be
  duplicated into a position where it runs more often than the table above says. Inlining
  substitutes a *body*, never an argument expression: an argument is evaluated once, at the call,
  however many times the parameter is mentioned. *Amended 2026-10-02:* **an evaluation that makes no
  call** — arithmetic on numbers, a comparison of two, a field read, building a record, a tuple or a
  string, a literal, a name — changes nothing and cannot fail, so where it runs against another
  such evaluation is not observable, and the backend may choose (`backend.md` §8, *In place, when
  nothing captures*, orders a tail call's assignments this way). An evaluation that makes a call —
  any call, pure or not — keeps its place.
- A `let` binding may be sunk into the one branch that uses it, or dropped, but not lifted out of a
  branch into a position where it runs when that branch does not.

`transparent-effects-proposal.md` §5 adds the clause the first bullet now states: a call carrying
the `impure` bit may not be eliminated, duplicated, reordered across another `impure` call, or
memoised, *even when its result is unused*. *(This paragraph said "when effects land … the first
bullet above stops applying to it" until 2026-09-30, when the first bullet was amended to say so
itself.)*

### 6.8 Lists

*Added 2026-10-01; specified, not built.* **`List` is beni's one sequence type, and it is
array-backed** — the owner's decision of 2026-10-01 (`plans/browser-decisions.md` W35, amended),
after research 38 §15–§17 and research 46. There is no `Array` and no cons list. The syntax is
Elm's and stays; what changes is what each piece costs, and the API, which gains indexed reads and
writes. The representation, its invariants and the runtime are [`backend.md`](backend.md) §4,
*Lists are arrays*; the migration and its slices are
[`plans/list-arrays.md`](../../plans/list-arrays.md). Until that plan's second slice lands, lists
are cons cells and the costs below that differ from Elm's do not hold yet. *Landed 2026-10-01: the
costs below hold. And by the manager's decision O6 (on the owner's delegation, reversible), `xs ++
ys` on two lists calls `List.append` and costs what `[ ...xs, ...ys ]` does; only a `++` over
`appendable` keeps `Basics.append`'s O(length of both).*

**The syntax, and what each form costs.** *Restated 2026-10-01 in the bracket spelling* (*The list
syntax*, below); the costs are the array's, after the flip.

| Written | Means | Cost |
|---|---|---|
| `[]`, `[ a, b, c ]` | a list of those elements, evaluated left to right | O(length) |
| `case xs of [] -> …` | `xs` is empty | O(1) |
| `[ x, ...rest ] ->`, `[ a, b, ...rest ] ->` | `xs` has at least one (two) elements; `x` (and `b`) are the first ones, `rest` is the list after them — a **view** of `xs`, not a copy | O(1) — a match never copies (*E1tp:* on a list that has been written to, `rest` shares its structure and copies at most 31 elements once every 32 steps of a walk) |
| `[ ...init, last ] ->` | `xs` has at least one element; `last` is the last one, `init` a view of the ones before it | O(1) |
| `[ x, y ] ->` | `xs` has exactly two elements | O(1) |
| `[ x, ...xs ]` as an expression | a **new list**: `x`, then every element of `xs` | *Amended 2026-10-01 (E1tp):* **amortised O(1)**, as `List.push` is at the other end; at most 31 elements copied when `xs` was prepended onto before; O(length of `xs`) once when `xs` is a list of 32 or more nothing has written to (it is converted, and everything built from it after is cheap). *Was, under E1t:* O(length of `xs`), a copy |
| `[ ...xs, x ]` as an expression | a new list: every element of `xs`, then `x` | *Amended 2026-10-01 (E1tp):* what `List.push xs x` costs — amortised O(1). *Was:* O(length of `xs`) |
| `[ ...xs, ...ys ]` | a new list: the elements of `xs`, then those of `ys`; `xs` itself when `ys` is empty and `ys` itself when `xs` is | *Amended 2026-10-01 (E1tp):* O(length of `ys`) when `xs` has been written to, or has 32 elements or more while `ys` has fewer — each of `ys` is pushed — and O(length of both) otherwise |
| `xs ++ ys` | the same list as `[ ...xs, ...ys ]` | O(length of both), always: `++` is `Basics.append`, which serves strings too and cannot reach the list's representation (`backend.md` §4). *Amended 2026-10-01 (O6, the manager on the owner's delegation, reversible):* a `++` on two lists calls `List.append` and costs what `[ ...xs, ...ys ]` does; this row still holds for a `++` over `appendable` |

**`[ x, ...xs ]` is cheap.** *Amended 2026-10-01, the owner (W35, E1tp). Under E1t this paragraph
read "`[ x, ...xs ]` is legal, and it copies" and told programs not to prepend in a loop.* A list
that has been written to is a trie with a **claimable head** as well as a claimable tail
(`backend.md` §4, *The claimable head: E1tp*), so prepending onto the list the last prepend
returned — an accumulator, a stack, the list a recursion hands back — is amortised O(1), as
`List.push` is at the other end. Prepending onto an *older* version, one that something else was
already prepended onto, copies at most 31 elements, never the list; prepending onto a list of 32 or
more that nothing has written to converts it once, O(n). So Elm's `x :: acc` then `List.reverse`,
`foldr` building a list, a persistent stack and a TEA list that gains rows at the top are all
linear, and **no way of building a list by prepending is quadratic**. It is a constant factor slower
than Elm's cons list (3–7× on research 46 §11's Elm-style scenarios), and `List.push acc x` — which
keeps the order the elements arrived in, so no `List.reverse` is needed, and hands back a list that
reads at O(1) — stays the fastest way to build and the one to teach. Two places where a leading
spread costs nothing at all, because the compiler sees what it means:

- **A function's result `[ f x, ...go rest ]`**, where `go` is the function itself, is compiled to a
  loop that builds the result front to back, O(1) per element and no stack (`backend.md` §8, *Tail
  calls modulo cons, onto an array*). Elm-shaped `map`, `filter` and `takeWhile` written by hand
  stay linear and stack-safe. *Amended 2026-10-01 (E1tp):* without the loop they would now be
  linear too, but a stack frame per element, which overflows at about 100 000 — so the loop stays,
  and it is what makes them **stack-safe**.
- **Re-consing what a pattern matched**, `[ h, ...t ]` right after matching `[ h, ...t ]`, is the
  list that was matched (`backend.md` §7, *List patterns over arrays*). *Amended 2026-10-01
  (E1tp):* the runtime also makes it O(1) on its own; the compiler's rule adds that the result is
  the very list matched.

(A third, "`e :: [ … ]` onto a literal is one literal", has nothing left to say: `[ e, … ]` is
written as the one literal it always was.) *The warning `prepend_in_loop` proposed here was
withdrawn by the owner on 2026-10-01 (W35's second amendment, O1).*

#### The list syntax: brackets and a spread

*Added 2026-10-01, the owner's decision (`plans/browser-decisions.md` W35, second amendment); built
the same day on today's cons cells.* **`::` leaves the language.** A list is written, built and
matched with brackets and a `...` **spread**, as in JavaScript. This holds whatever the prepend
benchmark finds: it is a decision about spelling, not about cost, and each form's cost on both
representations is in the table at the end of this subsection.

*Amended 2026-10-01 (§12.7, built 2026-10-02):* the spread is written `…` (U+2026), one
token, in expressions, patterns and a tag's attribute hole alike — `[ x, …rest ]`, `[ …init, last ]`,
`{…attrs}` — and `...` is removed (`ascii_symbol_removed`). Everything below holds with `…` read
for `...`.

**Expressions.** A list literal's items are expressions and **spreads**, `...e`, in any number and
any order. A spread's operand `e` is any expression (`[ ...f x, 0 ]`, `[ ...xs ++ ys ]` — the comma
ends it) whose type is `List a` for the literal's own element type `a`.

| Written | Is |
|---|---|
| `[ x, ...xs ]` | `x`, then the elements of `xs` — Elm's `x :: xs` |
| `[ a, b, ...xs ]` | Elm's `a :: b :: xs` |
| `[ ...xs, x ]` | the elements of `xs`, then `x` |
| `[ ...a, ...b ]` | `a ++ b` |
| `[ ...a, x, ...b ]` | the elements of `a`, then `x`, then those of `b` |
| `[ ...xs ]` | `xs` itself — not a copy of it |

**Evaluation** is §6's *Evaluation order* for a list literal: every item — an element, or a spread's
operand — is evaluated once, left to right, and then the list is built. What a literal with a spread
**means** is the calls lowering writes for it (§8), built from the right: the plain items after the
last spread are one literal (none, if the spread is last); going leftwards, a spread `...s` in front
of what is built so far is `List.append s <that>` (or `s` alone when nothing is built yet), and an
element `e` is `List.cons e <that>`. So `[ x, ...a, y ]` is `List.cons x (List.append a [ y ])` —
which evaluates `x`, `a`, `y` in that order, because a call evaluates its arguments left to right,
and builds nothing a program can observe before all three are known. The two functions are
`core/List`'s, named by the compiler and not by the file, so a module may declare its own `cons`.

**Patterns.** A list pattern's items are patterns and **at most one** spread, `...name` or `..._`.

| Written | Matches | Binds |
|---|---|---|
| `[]` | the empty list | — |
| `[ a, b ]` | a list of exactly two elements | the two elements |
| `[ x, ...rest ]` | a list of at least one element — Elm's `x :: rest` | the first element; the list after it |
| `[ a, b, ...rest ]` | at least two | the first two; the list after them |
| `[ x, ..._ ]` | at least one | the first element only |
| `[ ...init, last ]` | at least one | the list before the last element; the last element |
| `[ first, ...middle, last ]` | at least two | the first; the ones between; the last |
| `[ ...rest ]` | every list | the list itself, as `rest` would |

The rule behind the table: a list pattern with *n* items besides its spread matches lists of
**exactly** *n* elements when it has no spread and of **at least** *n* when it has one; the items
before the spread match the first elements in order, the items after it the last ones in order, and
the spread binds the elements in between. A long enough list is needed for both ends, so the two
ends never overlap. Every item except the spread is an ordinary pattern — `[ ( k, v ), ...rest ]`,
`[ Just x, ..._, 0 ]` — while **the spread's operand is a name or `_`**: the elements the spread
covers are matched by the items around it, so `[ x, ...[ y, z ] ]` would only be `[ x, y, z ]`
spelled twice. A second spread would make the split ambiguous (`[ ...a, x, ...b ]` has as many
readings as `x` has positions), so it is `two_spreads_in_pattern`. A list pattern is refutable, a
spread's included, so none may stand in an irrefutable position (§7) — `[ ...xs ]` there says
nothing `xs` does not.

**Exhaustiveness** (`checker.md` §6.6, *amended 2026-10-01*) reads a list column by length: `[]`
and `[ x, ...rest ]` cover every list, as `[]`/`::` did; so do `[]`, `[ x ]` and
`[ x, y, ...rest ]`; `[ ...init, last ]` covers every non-empty list, so `[]` and it are a complete
`case`, and `[ x, ...rest ]` below `[ ...init, last ]` is `redundant_pattern`. A missing example
prints in this syntax: `[ _, ..._ ]` for "a list of at least one element", `[ _, _ ]` for exactly
two.

**Diagnostics** (§10). `::` where an operator or a pattern could continue, and `(::)`, is
`cons_removed` — one error for a whole chain, reported at its first `::`, whose message is the
bracket form of what was written: `a :: b :: rest` as `[ a, b, ...rest ]`, `x :: []` as `[ x ]`,
`x :: [ y ]` as `[ x, y ]`, and `(::)` as `List.cons`. The parser reads the chain as it always did
and goes on, so one mistake is one message. `beni fmt --migrate-cons <path>…` (a hidden flag,
`frontend.md` §1) applies that rewrite to every `::` of a file and changes nothing else — an edit,
not a formatting, so the file keeps its layout; it is how the repository moved, and a chain it
cannot write (a comment between items, a pattern tail that is not a name, `_` or a list) is left
for a person. A second spread in a pattern is
`two_spreads_in_pattern` at the second one. A spread outside a list's brackets, or a spread operand
in a pattern that is not a name or `_`, is `unexpected_token` with a message that says where a spread
goes (`[ ...xs ]`, `...rest`, `..._`).

**Formatting** (§9). A spread is one item of the list for §9's one-line-or-vertical rule, printed
with `...` directly against its operand: `[ x, ...rest ]`, and vertically

    [ header
    , ...rows
    , footer
    ]

**What each form costs.** Today's list is cons cells; `plans/list-arrays.md`'s flip makes it an
array. *n* is the length of the list read or copied, *k* the number of items written.

| Form | Cons cells (today) | Arrays (after the flip) |
|---|---|---|
| `[ a, b ]` | O(k): k cells | O(k): one array literal |
| `[ x, ...xs ]`, `[ a, b, ...xs ]` | O(k): the cells share `xs` | O(n + k): a copy, except a cons step (`backend.md` §8) and a re-cons (§7). *Amended 2026-10-01 (E1tp):* amortised O(k) onto the newest version of `xs`; at most 31 elements copied onto an older one; O(n) once to convert an unwritten `xs` of 32 or more; O(n + k) only below 32, where n is small |
| `[ ...xs, x ]` | O(n): `xs` is copied | O(n): a fresh array (`List.push` is amortised O(1)). *Amended 2026-10-01 (E1tp):* `List.push`'s cost — a copy below 32, otherwise amortised O(1) after at most one conversion |
| `[ ...a, ...b ]`, `[ ...a, x, ...b ]` | O(length of `a`); `b` is shared | O(length of both). *Amended 2026-10-01 (E1tp):* `[ ...a, ...b ]` is O(length of `b`) when `a` is a trie, or has 32 elements or more while `b` has fewer (each of `b` is pushed), and O(length of both) otherwise; `[ ...a, x, ...b ]` is the sum of its two calls, `List.append a (List.cons x b)` |
| `[ ...xs ]` | O(1): `xs` | O(1): `xs` |
| pattern `[]`, `[ a, b ]` | O(k) tag reads | O(1): one length test |
| pattern `[ x, ...rest ]`, `[ x, ..._ ]` | O(k); `rest` is the shared tail | O(1); `rest` a view. *Amended 2026-10-01 (E1tp):* of a trie, `rest` is a trie sharing its tree, with a copy of at most 31 elements once every 32 steps |
| pattern `[ ...init, last ]`, `[ first, ...middle, last ]` | O(n): the length is counted and the last elements found by a walk, and `init`/`middle` is a copy of n − k elements | O(1): a length test and indexed reads; `init`/`middle` a view |

The O(n) row is the one place where the new syntax says something the cons list could only do by
walking, and it is honest about it: correct today, O(1) after the flip (`backend.md` §7, *List
patterns with elements after the spread*).

#### `core/List`

**`core/List`.** Elm's `List` module, subject first and uncurried as all of `core/` is, plus
the indexed operations Elm keeps in `Array`, plus `pop`, `insertAt`, `removeAt` and `swap`, which a
UI needs and Elm makes its users write badly (research 38 §12.3). `n` is the length of the list
argument, `k` the length of the result. **"Near O(1)"** is O(log₃₂ n) — at most four steps below a
million elements — and is what an indexed read costs on a list that has been written to with
`set`, `push`, `pop` or `swap` above their thresholds; on any other list it is O(1). *Amended
2026-10-01 (E1tp):* or by prepending onto a list of 32 or more, and on the tail of such a list.

| Function | Cost | What is guaranteed beyond Elm's meaning |
|---|---|---|
| `singleton`, `repeat`, `range` | O(k) | |
| `initialize : Int, (Int -> a) -> List a` | O(k) | *new*; the callback in index order |
| `length`, `isEmpty` | **O(1)** | `length` was O(n) |
| `head`, `last`, `get : List a, Int -> Maybe a` | near O(1) | `last` and `get` *new*; `get` is `Nothing` out of range |
| `tail`, `drop` | O(1) | a view of the list, sharing its elements (it keeps the whole list alive, as a substring may). *Amended 2026-10-01 (E1tp):* of a list that has been written to, the same list without its first elements, sharing its structure — O(1) and a copy of at most 31 elements — and prepending onto it is as cheap as onto the list itself |
| `take`, `slice : List a, Int, Int -> List a` | O(k) | `slice` *new*, Elm's `Array.slice`: a negative index counts from the end; the list itself when the result is all of it |
| `set : List a, Int, a -> List a`, `update : List a, Int, (a -> a) -> List a` | a copy up to 256 elements; above, near O(1) after one O(n) conversion per list | *new*; out of range, the list unchanged |
| `push : List a, a -> List a` | a copy below 32 elements; above, amortised O(1) after one O(n) conversion per list | *new*; the end is where a list grows. Pushing twice onto one version (after an undo) copies at most 31 elements, never the list |
| `pop : List a -> List a` | as `set` | *new*; the last element removed; `[]` unchanged |
| `swap : List a, Int, Int -> List a` | two `set`s | *new*; out of range, unchanged |
| `insertAt : List a, Int, a -> List a`, `removeAt : List a, Int -> List a` | O(n) | *new*; `insertAt` at `length` appends; out of range, unchanged |
| `cons` (`[ x, ...xs ]`), `append` (`++`, `[ ...xs, ...ys ]`), `concat`, `concatMap`, `intersperse` | O(total) | *Amended 2026-10-01 (E1tp):* `cons` is amortised O(1) and `append` pushes when it can, as the syntax tables above say; `++` stays O(total) |
| `map`, `indexedMap`, `filter`, `filterMap`, `map2`–`map5`, `partition`, `unzip` | O(n) | the result is fresh and reads at O(1) |
| `foldl`, `foldr`, `any`, `all`, `member`, `sum`, `product`, `maximum`, `minimum` | O(n) | `foldr` walks backwards and allocates nothing (it was `reverse` then `foldl`) |
| `reverse` | O(n) | |
| `sort`, `sortBy`, `sortWith` | O(n log n) | stable; the comparator's calls as today's merge sort |
| `==`, `compare` (`eq`, `compare`) | O(n) | element by element, as today |

Every function walks a list of any length without growing the stack, and `sortWith` recurses to a
depth of log₂ n. The costs are written into each function's doc comment in `core/List.beni`, and
`checker.md` Appendix B's inventory lists the signatures.

**What an operation returns unchanged.** A function whose result would equal its input returns the
input itself wherever `backend.md` §4, *Identity*, says so — `set` of the value already there, `swap
xs i i`, anything out of range, a `slice` or `take` of everything, `drop xs 0`, `filter` that keeps
everything, `map` whose every result is the element it was given, and `xs ++ []` among them — so a
view that shows the list skips it (§11.12). *The `map` rule costs one comparison per element and is
proposed as a guarantee (`plans/list-arrays.md` §1, O4).*

**Callbacks.** Every function that takes a callback calls it on the first element first, except
`foldr`, which calls it on the last first (`checker.md` Appendix B), and each is written in beni over
a first-order `foreign` sibling, so **a callback may suspend** (`transparent-effects-proposal.md`
§16): the loop parks with it and resumes where it stopped. The `foreign` half is `cons`, `length`,
`append` (*added 2026-10-01, E1tp*: it must reach the trie to push),
the single-element writes, `slice`, `insertAt`, `removeAt`, `swap`, and `eq` and `compare`, whose
`where` evidence is called from JavaScript and is `sync` (`boundary.md` §4); nothing that takes a
function is `foreign`.

## 7. Scoping and shadowing

| Rule | Detail |
|---|---|
| **irrefutable positions**, and what irrefutable means | **one rule for five positions**: the parameters of a top-level definition, of a `let`-bound function and of a lambda, a `let` pattern, and the pattern of a `let p <- e` — in all five, the pattern must **match every value of its type**. It is Elm's rule, and it keeps exhaustiveness out of everything but `case`. A pattern qualifies when it is a name, `_`, `()`, a record, a tuple of qualifying patterns, one of those with `as`, or **a constructor of a type that has only that one constructor**, whose arguments all qualify (`LetPattern` in §3). So `unwrap (Box x) = x` and `let (Box x) = b` are both legal and `un (Just n) = n` is not. |
| how it is decided, and by whom | **the rule is type-directed, so it is enforced in two places and they cannot disagree.** A literal and a list — a list with a spread included, and until 2026-10-01 a `::` — fail it whatever the types are, so the **parser** refuses those, early and cheaply. A **constructor** is admitted by the parser and settled by the **checker**, which runs the pattern through the same usefulness analysis a `case` gets, as a one-row match (`checker.md` §6.6) — so nesting (`Pair (Box a) b`), a type with no constructors, and an opaque imported type all fall out of one algorithm rather than a second single-constructor test that could drift from the first. |
| the two codes | `refutable_let_pattern` for a `let` pattern, `refutable_parameter_pattern` for the other four. **A `<-` bound pattern is a parameter**, because §6.7 desugars it into the callback's parameter; naming it that way is what keeps the parser and the checker from labelling one position two ways. Each code has a parse-time and a check-time source (§10); only the check-time one can name the constructors that are missing. The backend may therefore destructure any of these positions with no test (`backend.md` §4). |
| provenance | Manager decision of 2026-09-18, owner offline; reversible. The alternative considered and rejected was the purely **syntactic** rule — refuse every constructor in these positions, as the parser alone can — which is simpler and needs no checker pass. It was built first and withdrawn: it rejected 40 existing declarations, 27 of them in `core` (`Dict`, `Set`, `Never` unwrapping their one constructor), none of them a real refutability risk, and it left beni with no way to unwrap an opaque newtype except `case`. |
| what binds, and where | every binding introduces a name into a lexical scope: function parameters, lambda parameters, `let` bindings (all bindings of a `let` are in scope in all its bodies and its `in` expression — mutual recursion is allowed), pattern variables in `case` branches and destructuring. Top-level names are all in scope in every body; order does not matter. **Being in scope is not being initialised**, which is the next row. |
| **initialisation**, and what being in scope does not buy | A `let` **value** binding is evaluated where it is written (§6, *Evaluation order*), so its right-hand side may not read a value binding of the same `let` that is written **below** it, nor itself. Nor may it read one **through a `let` function** of that block: naming a function may call it — passing it to `List.map` calls it — so whatever that function's body reads is read here too (`a = f 1` above `f x = x + b` above `b = 2` is the same mistake one hop away, and a function written before `b` but only *called* after it is fine). All three are **`let_forward_reference`**, whose region is the reference that runs too soon and whose message names the binding it reaches and the line it is on. The name still **resolves** — that is what the row above means — so the error is never `unbound_variable`. A `let` **function** is untouched in the other direction: `backend.md` §4 emits it as a hoisted `function` declaration, so naming one above its own line is legal and mutual recursion between `let` functions is unrestricted. A TOP-LEVEL declaration has no written-order rule, because the backend emits constants in dependency order rather than in written order — the next row is what it has instead. |
| **initialisation at the top level** | A top-level **value** is computed once, when the module is loaded, so it **may not be reachable from its own initialiser** (a value with a `where` clause is computed at each use instead, §6 *Evaluation order*, and the rule applies to it unchanged: a `where` is a type annotation and never makes a value a function — only parameters or a `lambda` body do) — directly (`x = x + 1`), through other values (`x = y + 1` with `y = x`), or through the functions those initialisers name (`a = f 1`, `f n = n + b`, `b = a`). That is **`cyclic_value`**, and it is the same mistake as the row above with dependency order in place of written order: `backend.md` §5 emits a constant after everything it depends on, which orders every shape except a circle, and a circle falls back to source order and throws a JavaScript `ReferenceError` at load (§6, *Evaluation order*). There is nothing to reorder and nothing written-order could rescue, so the program is refused. **Order alone is never wrong at the top level**: `first = second * 2` above `second = 3` is fine and must run, which is what makes this rule about cycles and not about position. A **function** is untouched, so mutual recursion between top-level functions is unrestricted; what a function may not be is a step on a circle that a *value*'s initialisation closes. One diagnostic per circle, at the first VALUE on it in source order, naming the whole circle in the order it runs and the first function in between — `import_cycle`'s shape one scope down. Enforced by the **checker** and not by lowering (`checker.md` §6.7), because a `method_call` adds no `refs` edge (§8) and only the checker's dispatch table has that half of the graph. |
| how far the analysis reaches, and where it stops | **conservative, and deliberately so.** Mentioning a `let` function counts as calling it, whether or not it is called. A value whose right-hand side **is a lambda** (`g = λ_ -> later`, and `g = f a _`, whose placeholder wraps the whole application in one) is the single exception: nothing runs when it is bound, so it may name a later value, and calling it is what reads that value — so mentioning `g` counts as calling `g`, exactly as for a function, and `h = g ()` above `later` is refused. A lambda anywhere else inside a value's right-hand side is **not** deferred, because whatever it was passed to may call it at once (`List.map xs (λ_ -> later)` does), and a nested `let` inside a value's right-hand side is not deferred either. Those two refuse programs that would have run; the alternative is a call graph that has to be right about every higher-order function, and a wrong answer there is a `ReferenceError` a user cannot see coming. **The top-level rule reaches exactly as far, and stops in the same places**: mentioning a top-level function counts as running it, a declaration whose right-hand side is a lambda defers (so it may name a value that is written anywhere, and calling it is what reads that value — `seed = deferred ()` with `deferred = λ_ -> seed + 1` is refused), a lambda anywhere else does not defer, and a reference that leaves the module is not an edge at all, because the module graph is a DAG and an import circle is already `import_cycle`. |
| provenance of the initialisation rule | Decided 2026-09-18, owner offline; reversible. The alternative considered and rejected was to **re-sort** a `let`'s bindings into dependency order, the way the backend already sorts top-level constants. It was rejected because §6's table is normative and says `let` bindings evaluate in written order: sorting would make the order of two `Debug.log`s — and, when effects land, the order of two effects — depend on which names one initialiser happens to mention. `core/Dict.beni`'s `mapTree` already depends on the written order it has. The TOP-LEVEL half was decided the same day, on the same terms; there the rejected alternative was to leave it to the backend — emit a circle's members as `let` bindings, or wrap each in a thunk — which buys a program nobody can read a run it cannot explain, and costs every constant an indirection to rescue the shapes that are mistakes. |
| `shadowing`, `duplicate_pattern_variable` | **shadowing is an error**: a binding may not reuse a name already bound in an enclosing scope, including top-level names of this file and names in `exposing` lists. Two sibling scopes may reuse a name (`λx -> …` twice). A pattern may not bind the same name twice: `duplicate_pattern_variable`. |
| order | `let` bindings are in scope throughout their `let`, **except that a `<-` splits the block** (§6.7): a name bound at or before a `<-` is in scope in the whole block, the `<-`-bound name itself only in `rest` because the desugaring puts it inside a lambda, and a `<-` right-hand side may not reference a binding that appears after it (`bind_rhs_forward_reference`). Mutual recursion through a `<-` is therefore not available — what the desugaring means, not a restriction on top of it. |
| blocks | *Added 2026-10-02 (§12.2).* Every row above that says `let` holds for a block, item for item; a statement is a value binding that binds nothing, for the initialisation row; a parenthesised block is a block |
| type variables | scoped to their annotation; annotations may mention free variables, which are implicitly quantified. A type declaration's parameters must be distinct (`duplicate_type_parameter`); a declared parameter unused in the body is fine; an unbound type variable in a `type` or `type alias` body is `unbound_type_variable`. |

## 8. What lowering produces (BIR), and what it desugars

BIR is the per-file, untyped, name-resolved IR (`fast-compiler.md` §6), a pure function of the
file's bytes: nothing in it depends on another module. Lowering:

| Step | What it does |
|---|---|
| 1 | Resolves every name per §6.2 into one of `local(index)`, `top(index)` (this module), `import_value(module, name)`, `import_ctor(module, name)`, `ctor(index)` (this module), `qualified(alias → module, name)`, and records the set of top-level names each declaration references (§9.1 of the design doc: the DCE graph is a byproduct). |
| 2, ordered | Desugars operators into calls of the corresponding core functions (`a + b` → `add a b`, marked as a `number`-typed builtin — the M2 checker resolves the builtin) — **except the six comparison operators, which become method calls** carrying the operator they were written as, and are resolved by the checker rather than by lowering (§6.5). Then, **in this order**, because the readings disagree otherwise (§6.7): `\|>` into a call whose **first** argument is the left operand (`e \|> f a` → `f e a`, looking through grouping parentheses) and `<\|` into direct application, so every pipeline is a saturated call; then `_` into a lambda over the innermost enclosing application; then `x <- e` into a call of `e` whose last argument is a lambda over the rest of the block. |
| 2, order-independent | `?` into a `try` instruction, which STANDS FOR `case e of Ok v -> v; Err x -> return (Err x)` without being one: the choice between that shape and the `Maybe` one is the checker's (§6.6), and it needs an instruction of its own to hang on. `backend.md` §4 emits the test and the early `return` from it directly. String interpolation into an `interp` node listing chunks and expressions; `if` into a two-branch `case` on `True`/`False`; `.field` accessor functions into one-parameter lambdas. Multi-parameter lambdas stay n-ary; record update, tuples and lists stay as nodes; field access and tuple index stay as nodes (the checker needs them). *Amended 2026-10-01:* a list literal **with a spread** does not stay a node: it becomes the `List.cons` and `List.append` calls §6.8 spells out (`[ x, ...xs ]` is `call(import_value List.cons, x, xs)`, `[ ...xs ]` is `xs`), each call and its callee stamped with the spread's `...` token, so a cons step (`backend.md` §8) and every diagnostic about the call see the calls `::` and `++` gave them. A list **pattern** stays a node: `pat_list`, whose range may hold one `pat_spread` whose operand is the `pat_var` or `pat_wild` it binds (`frontend.md` §3.6). Calls are n-ary in BIR and always were; what the spec pass changes is that a `call` node is now the *only* reading of an application. |
| 2, blocks | *Added 2026-10-02 (§12.2, §12.3).* A block lowers to the `let` instruction step 2 already produces for a `let`, its items in written order; a statement to the new `let_stmt`, its operand the expression; a parenthesised block likewise. A trailing lambda is the `lambda` a parenthesised one is. Nothing in step 2's order changes: a bind in a block desugars at the same point, over the items after it |
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
`let` are always vertical. *Amended 2026-10-02 (§12.5):* `case` and blocks are always vertical; an
`if` written on one line stays there when it fits; and a hanging application's head arguments are
the one place a source break between elements does not pin the vertical form. Nonempty closed record bodies of `type alias` and
`schema` declarations, and tagged schema variants, are also always vertical
layout: this overrides the one-line/source-break choice for these bodies.
*Amended 2026-10-01 (§12.9, built 2026-10-02):* the formatter writes the Unicode symbols with the
spacing their ASCII spellings had, measures width in code points, breaks a product type before
each `×`, and until the enforce step prints each token in the spelling it read; it never converts
one spelling to the other.

| Construct | Rule |
|---|---|
| **Whitespace and file shape** | |
| indentation, endings | 4-space indentation. LF line endings. One trailing newline. No trailing whitespace. |
| file shape | module doc block, blank line, imports sorted by module path one per line, two blank lines, declarations separated by two blank lines. Blank lines between `let` bindings and between `case` branches: at most one, kept if present. |
| comments | stay attached to the token they precede; a comment on its own line stays on its own line; a trailing comment stays at the end of its line; doc blocks get a space after `--\|`. *Amended 2026-10-02 (§12.5):* one blank line between a standalone `--` comment and the next token is kept when the source has one |
| literals | strings, numbers and chars are printed as written, with no escape normalisation; the formatter never changes bytes inside a literal |
| **Declarations and types** | |
| annotation, `=` | the annotation goes on its own line directly above its definition, with `pub` on the annotation line; the amendment below leaves it alone. `=` goes at the end of the head line. *Amended 2026-10-02, the owner:* **the body goes on the `=` line when it is a single line that fits in 100 columns there, and on the next line indented 4 otherwise** — for top-level definitions, `let` definitions and `let` patterns (`( a, b ) = pair`) alike. "A single line" is the never-join rule applied to the body alone: the body has a one-line form — it is not, and holds no, `if`, `case` or `let`, is not a multiline string, holds no comment, and holds no multi-element construct the author broke between its elements (a list, record, application or operator chain written across lines stays vertical, and the body with it goes below the `=`). **The line break directly after `=` is not a break between elements** and never pins the vertical form: `x =` / `    f a` prints as `x = f a`. That is what migrates every file written before this amendment with an ordinary `beni fmt`, and it means a short body cannot be kept below its `=`. A comment between `=` and the body — trailing the `=` or on a line of its own — keeps the body on the next line, comment first, as before. Markup takes the same test: one-line markup that fits joins the `=` line, markup written across lines stays below (§11.15). Blank lines between `let` bindings do not change: at most one, kept if present, never added, so a run of one-line bindings stays as tight or as spaced as its author wrote it. A comment between the head and `=` still pushes `=` to a continuation line, and the body then follows the `=` by the same test. *Until 2026-10-02 the body always went on the next line, as elm-format does.* *Amended again 2026-10-02 (§12.5):* a body that is a block never joins the `=` line, and a body that is an application hanging a lambda keeps its head line on the `=` line when that line fits, the lambda's body below it: `todos = List.map model.todos λt ->` |
| declaration record bodies | Always print `type alias Name =` or `schema Name =` with fields on following lines, no braces or commas, even when the input fits on one line. Use four spaces per level, recursively for a whole nonempty closed record field body; put its doc comment directly above it at its column. Preserve field order; schema modifiers have one space between them. Tagged schemas print aligned variant heads and indented payload fields (`schema.md` §2). Empty/extensible records and inline record types retain braces and their existing formatting; ordinary `type` declarations and all record values are unchanged. |
| annotations, non-record `type alias`, `type` | an annotation or `type alias` prints `name :` … on one line if the type fits in 100 columns, otherwise broken at `->` with the arrows leading continuation lines. A `type` declaration puts `=` and each `\|` at the start of their own lines, indented 4. |
| **`where` clauses** (§3) | **never joined to the annotation's line**, however short. One constraint shares the `where` line, indented 4; two or more put `where` alone on a continuation line indented 4 and one constraint per line indented 8, each after the first led by its comma — elm-format's vertical form. **Source order is kept, never sorted**, and a constraint's own type is printed flat, so a clause the author broke is joined; a constraint that does not fit overflows the guide rather than breaking, as a pattern does. The renderer that prints a *type* for a diagnostic or a `.iface` golden is a different thing and prints the suffix on one line, sorted — the two legitimately differ. → `static-dispatch-spike.md` §2.5, §6.6. |
| **function types** | print as `A, B -> C`: one space after each comma, one space either side of `->`. The parameter list is a multi-element construct like any other, so it goes on one line when it fits *and* the author wrote no break between parameters. When a type breaks, the parameters move to the line below `name :` indented 4, one per line with the comma leading each continuation as lists do, and the `->` leads the result's line. *Amended 2026-10-02 (§12.5):* the first parameter is indented 6, so that it starts in the column of every parameter after a leading `, `. |
| **patterns** | **never broken across lines.** A `case` pattern, a definition's parameter list or a `let` pattern that does not fit overflows the 100-column guide rather than wrapping: there is no wrapped form a reader could tell from the `->` that follows. The same holds for the head line of a definition. |
| **Blocks** | no blank line before `then`, `else`, `in`, or between the last binding and `in` |
| `let` | `let` alone on a line, bindings indented 4 relative to `let`, `in` aligned with `let`, body aligned with `let`. *Superseded 2026-10-02:* `let` is removed (§12.2), and the next row is its replacement |
| **a block** | *Added 2026-10-02 (§12.5).* Items one per line at the block's column, 4 right of the indentation of the opener's line; never on the opener's line; at most one blank line between items, kept if present, never added. A parenthesised block: `(` ends its line, the items, `)` alone at the indentation of the line holding `(`. `--migrate-let` writes every `let` as a block (`frontend.md` §11.5) |
| `case` | `case x of` alone on a line; branches indented 4; `->` at line end; body indented 4 more |
| `if` | `if c then` / `a` / `else` / `b`, always vertical; `else if` chains continue at the same indentation. *Amended 2026-10-02 (§12.5):* an `if` written on one line stays on one line when it fits and its parts have one-line forms; one written across lines stays vertical |
| **Expressions** | |
| lists, records, tuples | on one line when they fit and were written on one line, with elm-format's inner spaces — `[ a, b ]`, `{ a = 1, b = 2 }`, `( a, b )`, `{ r \| a = 1 }`, empty ones as `[]`, `{}`, `()` — else elm-format's vertical form `[ a`, `, b`, `]` with the delimiter leading each line. *Amended 2026-10-01:* a spread is one item, printed with `...` against its operand, in expressions and patterns alike: `[ x, ...rest ]` (§6.8) |
| operator chains | those that do not fit, or that the author broke, break before the operator, one operator per line, operands indented 4. A chain flattens one precedence level only. |
| applications | the arguments written on the head line stay there when they fit (`div [ class "app" ]`, `Decode.map4 User`); from the first source line break onward every remaining argument goes on its own line indented 4; an application with no source break that does not fit breaks after the function, every argument on its own line. Constructor argument lists in `type` declarations follow the same rule. **`_`** is an ordinary argument that takes ordinary application spacing; it never forces a break. *Amended 2026-10-02 (§12.5):* an application whose last argument is a lambda, list, record, record update or markup **hangs** it — the callee and the other arguments on one line when they fit, whatever breaks the source has between them, a lambda's `λparams ->` ending that line and its body below as a block, a list, record or markup on the next line indented 4 |
| **a trailing lambda** | *Added 2026-10-02 (§12.3, §12.5).* A parenthesised last-argument lambda loses its parentheses unless a binary operator or `?` follows its `)` on the same line; its body stays on the `->` line only when it fits there and the lambda ends its line, and is otherwise a block below |
| **a trailing `<\|` followed by a lambda** | **does not indent**: the lambda's body continues at the indentation of the line the `<\|` is on. This is the one elm-format rule research 14 found to be the binding constraint in Elm (`14/elm` §0.2). *Superseded 2026-10-02 (§12.5):* `f a <\| λx -> e` is written `f a λx -> e`, the row above, which indents its body exactly so |
| **`<-` bindings** | **print on one line and are never broken**: `x <- f a b`, single spaces around the operator. This is *not* the `=` rule, which moves a body that does not fit to the next line: a bind's right-hand side is a call whose last argument is the rest of the block, and breaking after `<-` would indent a body that is not there. A bind that exceeds the guide overflows it, as a pattern does. **`<-` operators are never aligned**, in a block of binds or a mixed one; nothing else in this section aligns anything. |
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
foreign_effect_missing  unknown_foreign_effect
misplaced_sync  sync_boundary  must_not_suspend
cons_removed  two_spreads_in_pattern
invalid_html_shell
backslash_lambda_removed  let_removed  block_ends_in_binding  statement_not_unit
name_removed  suspicious_argument_order
ascii_symbol_removed  tuple_type_removed
core_contract_violation
invalid_js_object
unit_spelling_removed  never_spelling_removed  if_without_else_not_unit  unit_discarded
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
| `debug_in_release` | the optimiser | `debug_in_release`, appended on 2026-09-19, again never inserted. It is the **one code in this catalogue a development build cannot produce**: a `--release` build in which any `pub` value of `core/Debug` — `log`, `toString`, `todo`, which is the whole module — survives [`backend.md`](backend.md) §9's reachability elimination is refused, exit 1, nothing written. That is Elm 0.19's rule for `--optimize`, taken by the owner on 2026-09-19 once the optimiser's first release slice had landed, and its reasons are §9's *`Debug` is refused, not pinned*: `Debug.toString` reflects on the runtime representation a release optimiser must stay free to change, a `Debug.log` inside a dead binding was dropped whole by §9 item 1 (§6's *What an optimiser may assume*; since 2026-09-30 it is kept, as every impure call is, so this reason is history), and a `Debug` call in a shipped build is almost always an accident. The rule is **reachability** and nothing softer — a `Debug.log` in a declaration the walk drops does not refuse the build, because the build does not ship it. The message names the use sites, at most five and then a count, in module-index then source order (CLAUDE.md rule 5) |
| `output_path_collision`, `invalid_entry_file` | the backend again | `output_path_collision` and `invalid_entry_file`, appended on 2026-09-21, again never inserted. They are one guarantee, [`backend.md`](backend.md) §2's *The output tree does not depend on the file system's case sensitivity*: **a build's output is the same set of files on every file system**. macOS and Windows fold case, so two output paths differing only by case are one file there — the entry file `main.mjs` and the module `Main`'s `Main.mjs` were exactly that, and every program built on a Mac threw `SyntaxError` at load with the build having exited 0. The compiler's reserved output names now begin with `_` (`_main.mjs`, `_core/`, `_platform/`), which a module path cannot reach because every segment is an upper identifier (§5); `output_path_collision` is the backstop for what that does not cover — two modules named `Json.Decode` and `JSON.Decode`, say — and is checked over the files a build is about to write, folded by simple ASCII lower-casing, before the first byte is written, naming both paths and both source files. `invalid_entry_file` is the other half: a platform may now declare the entry file's name in its manifest ([`boundary.md`](boundary.md) §5.2, `"entry"`), and a declared name that does not obey the `_` rule is refused when the platform is loaded, because a manifest key that could reintroduce the defect is worse than a hardcoded name |
| `method_needs_annotation` | static dispatch again | `method_needs_annotation`, appended on 2026-09-23 after the schema codes, again never inserted. Under checker v1 (the default until the cut-over, 2026-09-27): a comparison — or any method use — on a module's own type needs that module's method, the method has no annotation, and its binding group is checked after the use, so it has no type there yet. It was a silent wrong answer: the site compiled to `undefined`, or a derived comparison's part to a structural walk that ignored the method. The message says which method to annotate → `static-dispatch-spike.md` §10.12. **Amended 2026-09-26: checker v2 never emits it for that ordering case** — the use checks the method's group nested at the use ([`checker-v2.md`](checker-v2.md) §10.2) — **and emits it only for [`checker-v2.md`](checker-v2.md) §11.2's case**, a derived context entry indexed by a type parameter that depends on an in-flight inferred method (`checker-v2.md` §21.1). The code stays in this catalogue |
| `too_many_type_parameters` | the checker rewrite | `too_many_type_parameters`, appended on 2026-09-25, again never inserted. It is lowering's, at the 65 536th parameter of a `type`, `type alias`, `foreign type` or `schema` (whose parameters go through the same lowering): an arity is a 16-bit count in the interface record ([`checker-v2.md`](checker-v2.md) §14.2), and a count that saturated there imported the type at the wrong width — an 8-bit count was exactly that at 255, and it built a program that threw a `TypeError` once run. A refusal and not a clamp, because the clamp is the defect. The declaration keeps its first 65 535 parameters, so a body naming a later one is also an `unbound_type_variable` |
| `unknown_output_record` | the backend again | `unknown_output_record`, appended on 2026-09-28, again never inserted. `--out` holds a `_manifest.txt` that is not beni's record — its first line is not `beni-manifest 1`, or a line is not `<16 hex digits> <path>` — and the build would otherwise overwrite it ([`backend.md`](backend.md) §2, *The output directory holds what the last build wrote*). Reported against that file, before the first byte is written, and nothing is written. *Amended 2026-09-29:* the same code refuses a symbolic link on the way to any path the build writes in `--out` — the manifest, an output, or a directory it writes into — which beni never makes and would otherwise write through, named the same way |
| the seven before the last | markup | twenty codes appended on 2026-09-29 with the markup specification, again never inserted, on the first six of these lines; §11.17 says which phase reports each. *Revised the same day by the specification review, before anything was built:* three were renamed because `Show` shares them with `For` (`invalid_for_children` → `invalid_form_children`, `invalid_for_keyed` → `invalid_keyed`, `for_key_not_primitive` → `key_not_primitive`); the warning `html_entity_in_text` was withdrawn with the rule it enforced, because text now decodes character references (§11.4); and the seventh line was appended — `unknown_form_attribute` and `missing_form_attribute` for a built-in form's own attributes (§11.9, §11.18), and `markup_type_in_foreign` for a `foreign` that would build or read one lowering's representation of markup under another (`boundary.md` §9.3). Two are `warning`s, on by default for the root package only — `unkeyed_for` and `raw_markup_attribute` — and each names the escape that silences it. `markup_restructured` is the one code a platform's markup lowering reports rather than the compiler (`boundary.md` §9.4.7), and `unknown_markup_lowering` is a manifest's (`boundary.md` §9.2) |
| `untyped_event_attribute` | markup again | appended on 2026-09-29, when markup was typed, again never inserted: the owner's refusal of a quoted attribute name beginning with `on`, in any case (§11.5). `"onclick"={text}` would write an event handler the page runs as script, the one route besides `raw` by which a `view` could inject one, so it is an error rather than a warning — a guarantee (rule 7), with the typed event attribute as the escape. Reported at the quoted name, and its hint names the events the element accepts whose name is the quoted one in another case |
| the last line | markup again | appended on 2026-09-29, again never inserted, with the owner's decision to close the escape's other script sinks (§11.5). `invalid_attribute_name` is lowering's: a quoted name holding whitespace, a quote, `=`, `/`, `>` or a control character, or empty, which a page would end early and follow with an attribute the vocabulary never sees (`"x onclick"`); `untyped_srcdoc_attribute` is the checker's, beside `untyped_event_attribute`: a quoted `srcdoc`, in any case, a whole document the page runs, scripts included |
| `foreign_effect_missing`, `unknown_foreign_effect` | effects | appended on 2026-09-30, again never inserted, with the first slice of effects ([`transparent-effects-proposal.md`](transparent-effects-proposal.md) §14.1). Both are the parser's: every `foreign` value states its rung — `pure`, `impure` or `suspends` — between `foreign` and its name, because a `foreign` has no body to infer from and a default of `pure` would let a clock read claim it may be duplicated. `foreign_effect_missing` is at a name that follows `foreign` directly; `unknown_foreign_effect` at a word that is not one of the three. The declaration is otherwise read as written |
| `misplaced_sync`, `sync_boundary`, `must_not_suspend` | effects again | appended on 2026-09-30, again never inserted, with the `sync` step ([`transparent-effects-proposal.md`](transparent-effects-proposal.md) §15). `misplaced_sync` is lowering's: a `sync` in a `foreign` signature that does not mark a function type written out, or marks one the platform hands back rather than receives. *Amended 2026-10-02:* and any `sync` in a package that may not write `foreign`. The other two are the checker's, and they are the guarantee the feature exists for — a function that may suspend never reaches a caller that cannot wait for it, where it would return a suspension object in place of a value, well typed and wrong at exit 0. `sync_boundary` is at the argument: a function handed to a `sync` parameter, a markup handler, row or key function, or a `foreign`'s evidence. `must_not_suspend` is at a declaration that is a boundary itself: `main`, and a type's `eq` or `compare`. Both name the calls that make it suspend, within the module (§15.4) |
| `cons_removed`, `two_spreads_in_pattern` | the list syntax | appended on 2026-10-01, again never inserted, with the owner's decision that `::` leaves the language (§6.8, *The list syntax*). Both are the parser's. `cons_removed` is at the first `::` of a chain — in an expression, in a pattern, or as `(::)` — and its message is the bracket form of the whole chain, built from the text the author wrote (`[ a, b, ...rest ]`, `[ x ]`, `List.cons`); the chain is parsed as before and lowered to an error, so it costs one message. `two_spreads_in_pattern` is at a list pattern's second spread, which would make the split between the leading and trailing items ambiguous. A spread outside a list and a pattern spread whose operand is not a name or `_` reuse `unexpected_token`, with messages of their own |
| `invalid_html_shell` | the backend again | appended on 2026-10-01, again never inserted, with the page shell a platform declares ([`backend.md`](backend.md) §2, *The page shell*; [`boundary.md`](boundary.md) §5.2's `"html"`). A program build writes the shell as `index.html`, its `{{entry}}` replaced by the entry file; a template that never says `{{entry}}` would ship a page that loads nothing — a build that succeeds and does nothing — so it is an error, against the template at `1:1` with no excerpt. A template that cannot be read is the same code, against the `beni.json` that named it |
| `backslash_lambda_removed` … `suspicious_argument_order` | the syntax batch | the two lines appended on 2026-10-02, again never inserted, with §12 (specified, not built). Three are the parser's: **`backslash_lambda_removed`** at a `\` that begins a lambda, its message the `λ` head; **`let_removed`** at a `let`, its message the block the bindings become (both parse the old form on, as `cons_removed` does, so one mistake costs one message); and **`block_ends_in_binding`** at a block's last item when it is a binding, an annotation or a bind. **`statement_not_unit`** is the checker's ([`checker-v2.md`](checker-v2.md) §29): a statement whose type is not `()`, naming the type, `_ =` and a binding as the fixes. **`name_removed`** is lowering's for an unqualified name and resolution's for a qualified one: `modBy`, `remainderBy` or `logBase`, its message the call rewritten with `Int.mod`, `Int.rem` or `Float.log` (§12.4). **`suspicious_argument_order`** is a `warning`, the checker's, on by default for the root package only: a call of a function §12.4 keeps with an order Elm does not share, in the shape a call written in Elm's order has (§12.5) |
| `ascii_symbol_removed`, `tuple_type_removed` | Unicode notation | the next line, appended on 2026-10-01, again never inserted, with §12.7–§12.8 (built 2026-10-02). Both are the parser's, and both parse the old form on as the new one, so one stale spelling costs one message. **`ascii_symbol_removed`** is at each `->`, `<-`, `/=`, `<=`, `>=`, `\|>`, `<\|` or `...`, its message the symbol to write, its code point, `beni fmt --migrate-unicode` and the editor input — one code for eight spellings, because the fix and the flag are one. **`tuple_type_removed`** is at the `(` of a parenthesised tuple type, its message the type written with `×`. The lookalikes of §12.7 reuse `invalid_character`, `expected_token` and `unexpected_token`, each with a message naming the symbol |
| `core_contract_violation` | the backend again | the line before the last, appended on 2026-10-02, again never inserted. A core package that does not declare a value the code generator calls on its own — `Basics.eq` and `String.compare` for a comparison, `List`'s core-private `unsafeGet`, `view`, `base`, `offset` and `close` for a list pattern, a walk or a building loop ([`backend.md`](backend.md) §4, *The emitter's imports of the core-private exports*). Only a `--core-root` core can lack one. Reported where a module first needs the value, once per module and value, and nothing is written; it replaced `internal` for the two comparison values the same day |
| `invalid_js_object` | `Js` | the line before the last, appended on 2026-10-02, again never inserted, with `Js.object` ([`boundary.md`](boundary.md) §4.2; [`backend.md`](backend.md) §4, *`Js.object` is an object literal*). The checker's, at a call of core's `Js.object` whose fields are not a list literal of `( "key", value )` pairs, each key a string literal that is a JavaScript identifier other than `__proto__`, no key twice. Only core and a platform package can write one (`js_outside_platform`) |
| `unit_spelling_removed` … `unit_discarded` | `⊤` and `⊥` | the last line, appended on 2026-10-02, again never inserted, with §12.10 (built the same day). **`unit_spelling_removed`** is the parser's, at the `(` of a `()` in a type, an expression or a pattern; **`never_spelling_removed`** lowering's, at a `Never` that names `Basics`' empty type; both go on as `⊤` and `⊥`, so one stale spelling costs one message. **`if_without_else_not_unit`** is the checker's, at the `then` branch of an `if` without `else` whose type is not `⊤`. **`unit_discarded`** is a `warning`, the checker's, for the root package only, at a `_ =` in front of a `⊤` |

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
| anything else: `=`, `(`, `[`, `{`, `,`, `->`, `<-`, `if`, `then`, `else`, `in`, `of`, `case`, any binary operator, `<|`, `|>`, the start of a markup hole or attribute | markup | `x = <b />`, `f (<b />)`, `[ <li />, <li /> ]`, `λr -> <tr />`, `f <| <b />` |

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

*Decided 2026-10-03 by the owner:* **both will be supported, for Solid parity; the design comes
before code.** A spread of a record whose fields are known at compile time compiles statically —
`<button {…attrs}>` with `attrs : { type : String, disabled : Bool }` is two ordinary attributes in
the template, no run-time cost — which covers the component library passing attributes through to
a native element. Whether a truly open bag of attributes is admitted at all, and its run-time path,
are the design's to settle. A tag chosen at run time takes a run-time path like Solid's
`<Dynamic>`, measured against Solid's, never the default.

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

**A helper call in an `Html msg` hole may be skipped** (*amended 2026-09-29*, decided by the
project's manager on the owner's delegation; research 39 §6.3 and §7 question 1). A hole whose
expression is a saturated call of a **top-level function** — of this module or another; never a
local function, which could capture something its arguments do not show, never a constructor, and
never a markup primitive (§11.13), whose value is the runtime's own —
gets §11.8's component rule applied to a plain function: when every argument is identical (`===`,
not `==`) to the one the same hole was given last render, the platform may keep what the hole shows
instead of calling the function again, because a beni function given the same arguments returns the
same value. That is what lets a view be written the way Elm programmers write one — a section, its
heading and each item a function returning markup — without every render rebuilding and patching
all of it: research 39 §6 measured such a page at 30 µs a message against 7 µs for the same helpers
behind components. The callee and the arguments are evaluated with the markup, in §6's order; the
call is made with the platform's render, after the markup's other values, as a component's is (§6,
*Evaluation order*). **A call that passes evidence is never skipped** (`static-dispatch-spike.md`
§8.2): what it computes depends on more than its written arguments. What defeats the skip is what
defeats a component's: an argument built during the render — a record literal, a message with
arguments, a list — is a new value each time; a nullary constructor is not (§11.12). §11.11 says what a skip means for evaluation.

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
message that is itself a function is written as a lambda returning it, `onClick={λ_ -> f}` — the one
corner the rule leaves, and it is loud, never silent (`checker-v2.md` §25.4).

A handler returns a message and does nothing else. **Once effects land, a handler is `sync`** (W8)
and may call the event's `preventDefault` itself, which is Solid 2's spelling (W34); until then an
event's `preventDefault` and `stopPropagation` are facts of its declaration (§11.14), so a platform
can offer the forms a program needs. Delegation is also the declaration's fact, never the
program's: one listener on the document for the events a platform delegates, a listener on the
element for the rest, exactly as Solid 2 does (research 36 §2.7). A message produced inside markup
that `Html.map` wraps is passed through the map's function on its way out (§11.13).

*Decided 2026-10-03 by the owner:* **effects have landed, so W34 is carried out and the stopgap
retired.** A handler is `sync`, receives the event, and calls `preventDefault` or `stopPropagation`
itself when it wants to (`onSubmit={λe → { Event.preventDefault e; Submitted }}`), so it can decide
case by case — a `keydown` handler preventing only Tab. The `preventDefault` and `stopPropagation`
facts of an event declaration (§11.14) are withdrawn: Solid 2 has no such flags, and two ways to say
one thing are not kept. The handler's exact spelling and the `Event` API are the specification's,
before code; platforms and programs that rely on the facts migrate.

### 11.8 Components

**A capitalised tag names a module, and the component is that module's `view`; a module path
followed by a lower-case name is that value.** `<TodoItem todo={t} done />` means
`TodoItem.view { todo = t, done = True }`, and `<Card.header title="x" />` means
`Card.header { title = "x" }`. The module part resolves through this file's imports exactly as a
qualified name does (§6.2), so `import Ui.TodoItem as TodoItem` is what makes `<TodoItem …/>`
reachable.

*Amended 2026-10-03 by the owner:* **a module may name itself in a tag.** A tag's module part that
is the current module's own name resolves to the current module, so `<Main.card title="x" />`
inside `Main` calls `card` from the same file, and a component used where it is defined is
spelled as every other component is. Today that is `unknown_module`, and the only way to use it is
the plain-call form. A module part that is both the module's own name and an import alias in that
file is one name with two meanings; the specification says which wins or refuses it, before code.

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

*Amended 2026-10-03 by the owner:* **an optional prop is a `Maybe` field a tag may leave out.** When
the props record has a field of type `Maybe t`, a tag that does not write that attribute passes
`Nothing`; a quoted or bare value is wrapped as `Just v`; a hole `{e}` must already have type
`Maybe t` and is not wrapped. A field of any other type is required, as above, so a tag can no
longer lose a required prop to a defaults record. The leading spread stays, to pass a record of
props through; it is no longer how optional props are written. A plain call is unchanged: it writes
every field. Default values for optional props are open, pending research on how ML-family
languages give them.

*Decided 2026-10-03 by the owner:* **a default is written `¿` (U+00BF INVERTED QUESTION MARK), in a
record pattern and as an expression.** In a pattern, `{ title, subtitle ¿ "None" }` binds `subtitle`
to the field's value when it is `Just v` and to the default when it is `Nothing`, so the field has
type `Maybe t` and the binding type `t`; the record's type is untouched, which is why defaults live
in patterns and never in record types (structural records with different defaults would be equal
types — Roc met exactly that and kept defaults to nominal records). As an expression,
`m ¿ d` is `Maybe.withDefault d m`. Every font has the glyph (Latin-1); the editor turns a typed
`??` into it. Evidence and the spellings considered: [`research/54`](research/54-default-values.md).
For the specification, before code: the precedence of `¿`; whether a default may be any expression
and may read the pattern's other fields; whether `¿` is allowed in every record pattern (`case`,
`let`, parameters) or only in parameters; and whether `¿` also works on `Result`.

**Children are the `children` field**, and what it holds depends on what is written between the
tags:

| Between the tags, after §11.4's trimming | `children` is |
|---|---|
| nothing | absent: the component's type decides whether that is `missing_field` |
| exactly one hole `{e}` | `e` itself, at whatever type `e` has — a render function included |
| anything else | one `Html msg`: the children as a fragment |

So `<List>{λitem -> <li>{item}</li>}</List>` passes a function, and `<Card><h1>Hi</h1>text</Card>`
passes one markup value. Writing `children` as an attribute as well as between the tags is
`duplicate_attribute`.

**Children are evaluated before the call, like every argument** — forced, not chosen: beni is strict
(§6, *Evaluation order*), and Solid's lazy `get children()` getter is laziness a strict language has
no counterpart for. Nothing a program computes can tell the difference, because evaluation is pure;
what it costs is work a component that does not show its children still pays. A component that wants
its children evaluated only when it shows them takes a function and is written with one hole:
`<Lazy>{λ() -> <Expensive />}</Lazy>`.

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
        {λrow → <tr class={rowClass model row}><td>{row.label}</td></tr>}
    </For>
</table>
```

`For` is Solid 2's list form (W33; research 27 §7.1, research 36 §4.4). **Its attributes** are
`each`, the list — `List a`, and `Array a` once `core/` has one (W35; *amended 2026-10-01: there
will be no `Array`, `List` being array-backed, §6.8, so `each` is a `List a`*) — which is required; `keyed`,
the keying mode; and `fallback`, an optional `Html msg` shown when the list is empty. An attribute
`For` does not take is `unknown_form_attribute`, with "did you mean" over the three (`key=` is
answered with `keyed=`), and a missing `each` is `missing_form_attribute`. Its only child is one hole
holding the **row function**, of type `a -> Html msg` or `a, Int -> Html msg`, whose second parameter
is the row's current position. Anything else between the tags is `invalid_form_children`.

**The row function is any expression of a function type**, as any argument is: a lambda
(`{λrow -> <tr>…</tr>}`), a function (`{viewRow}`), a placeholder application (`{viewRow model _}`,
which is a lambda, §6.7) or any other expression. Which of the two types it has is decided by its
type — by the lambda's parameter count when it is one — and a function of another arity is the
ordinary `type_mismatch`. What the shape changes is only what a lowering can compile away
(`backend.md` §15.5): a lambda whose body is markup — after any `let` bindings it opens, so
`λr -> let label = … in <tr>…</tr>` counts — becomes a row compiled in place, and anything else is
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
equal keys as two rows, which is a silent wrong answer; `keyed={λr -> r.id}` or a `String` built from
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
`keyed={λx -> x}` — and there is no second mode for the silence to hide.

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

*Amended 2026-09-30* (research 39 §12): **a selector.** A keyed row's input that the row reads only
to compare with the row's own key is a *selector*, and when it is all that changed, only the rows
whose comparison can have changed run — the one that was selected and the one that is — where the
table above would run every row. It is Solid's `createSelector` (Solid 2's `createProjection`),
recognised by the compiler instead of written by the programmer; there is no syntax for it, and a
row that is not recognised is exactly as correct, and runs as the table above says. An input is a
selector when all of this holds:

- the `For` is keyed by a key function that is a field path — `keyed={.id}`, `keyed={λr -> r.id}`,
  `keyed={λr -> r.a.b}` — or by reference, whose key is the item;
- every read of the input in the row — directly, or through a same-module function it is passed
  to, as the table above follows reads — is one operand of an `==` or a `/=`, in either order;
- the other operand of every such comparison is the row's key written as the same field path
  through the row's item (`row.id`, or `id` bound by `λ{ id } -> …`), or a constructor of one field
  applied to it (`Just row.id`);
- and the comparison's `eq` is `===` on the two operands (`static-dispatch-spike.md` §3.2's
  primitive `strict_eq`: the key types of this section), or, against the constructor, the derived
  `eq` whose one field is compared that way — which is `backend.md` §4's tag and field test.

`rowClass model row` with `rowClass model row = if model.selected == Just row.id then "danger" else
""` is one; `model.selected == Just row.label` under `keyed={.id}`, a `let sel = model.selected` in
the row, or `model.selected` also shown in the row, is not. A row has at most one selector, its
first such input; the others are compared as the table above says.

### 11.10 Fragments

`<>…</>` is markup with no element of its own: its children, in order, where it stands. A fragment
of one child is that child.

### 11.11 Evaluation, and what a render may skip

§6's *Evaluation order* table has six rows for markup (an element or fragment, a component, a helper call in a hole, `For`,
`Show`, an event handler), written there with the rest; they follow from its existing ones.

**A skipped component, row or `Show` body is not evaluated.** That is the one place markup relaxes
§6's "an expression is evaluated exactly once, when control reaches it": a render may evaluate a
component body, a row function or a `Show` body zero times or once. Nothing a program computes can
tell, because every beni expression is pure (§6, *What an optimiser may assume*); `Debug.log` in a
component body can, and logs only for the calls that happen. *Amended 2026-09-29:* **a skipped
helper call in a hole (§11.6) is not made either** — its arguments are evaluated, its body is not —
so a `Debug.log` in the helper's body logs only for the calls that happen, as in a component's.
*Amended 2026-09-29, the same day:* **a row that runs because an input changed may leave alone the
values of its body that read only its item** — no input, no captured local, no position — because
they are what they were whenever the item is the same one: in `<tr class={rowClass model row}>…
<a onClick={Select row.id}>{row.label}</a>`, a selection re-runs the class and not the message or
the label. Such a value is evaluated when the row is first shown and again only when its item is
not `===` the last one, after the row's other values; a `Debug.log` in it logs only then.
*Amended 2026-09-30:* **a row whose selector (§11.9) is the only input that changed is skipped
when its comparison cannot have changed**: every comparison of the selector in the row compares it
with the row's key, so a row whose key neither the old selector value nor the new one selects
answers `False` (or `True`, for `/=`) both times and computes what it computed before. Its item,
its position and every other input must be as last time, as for any skip; a `Debug.log` in such a
row logs only for the rows that run.
**A row's inputs are read before the
row is reached** — `model.selected`, read so the skip can compare it — and that is not an evaluation
a program can observe either: a field read of a record cannot fail and computes nothing. **When
effects land, a hole, prop, row or `Show` body whose expression is `impure` is never skipped**
(`transparent-effects-proposal.md` §5's rule, applied here), so the skip stays unobservable in what a
program does.

*Amended 2026-10-04 by the owner* ([`research/56`](research/56-matching-solid-1.md) §6.2, Fix B):
**a render may compute `view`'s values by group, not in source order.** The compiler may group the
values of a template by the model fields they read and, on a render, evaluate only the groups whose
fields changed, in an order that need not follow the source. A pure `view` gives the same page either
way; the difference is visible only through `Debug` inside `view` (a line may print fewer times, or
in another order), and `--release` refuses `Debug`. This is the rule that lets a `let` in `view`
behave like a memoised value. Before the slice that builds it, the evidence on why Svelte moved from
compiled dirty-checking to signals (X3) is read from primary sources.

*Made precise 2026-10-04, as built* (X3 read: research 56 §6.5's amendment; `backend.md` §15.4,
*A root computes its own values*). **A value of a markup root is evaluated at the root's first
render, and in a later render only when one of the paths it reads is not `===` to what it was at
the value's last evaluation**; otherwise the page keeps what that value wrote. Its paths are the
locals it reads from outside the markup, each through the fields it reads (§11.9's analysis: field
accesses, and arguments of same-module functions by what they read; the whole local for any other
use). The values a render evaluates run **group by group** — a group being the writes that read
the same paths, in the order of their first write — and in source order within a group. A
`stateful` attribute's value (§11.5) is evaluated on every render, since the page, not the model,
is what it is compared with; so is a value that may have an effect — the effects sentence above —
**except one of `Debug`'s**, which is grouped like any other, so that a fixture can count what runs
(`--release` refuses `Debug`, so no shipped program can tell). `Random.value` or `Time.now` in a
`view` therefore answers anew on every render, as it did before. *Amended the same day, after
review — skipped calls* (it was never applied to §11.6 and §11.8, and is now): **a helper call or a
component that may have an effect other than `Debug`'s is never skipped**, and **a skipped one
keeps what it shows current**: the markup it returned last is patched again on every render, so a
controlled input it renders is reconciled and a value inside it that must run every render runs;
only the call, and the markup that needs no patch, are saved. *And:* **wherever such a value or such an attribute stands, the markup holding it is patched on
every render** — markup in an `if`, a `case` branch or a `let`, nested at any depth, and every
markup value whose own value holds it — so a controlled input nested in a branch is reconciled
exactly as one at the top of the view is, and a view that reads nothing of its model still draws
anew.

**A `let` read only by markup is a value of that markup** (the owner's decision of 2026-10-04, the
rule the amendment above names). A constant `let` of the function enclosing a markup root — a name
bound to an expression, not a function — whose every use is inside that root's values is evaluated
as one of them: at the root's first render, and later only in a render in which one of the paths
its expression reads is not `===` to what it was when it was last evaluated; a value that uses it
reads those paths, and the `let`'s last value. So `shown = top model.items` in a `view` is
computed again only when `model.items` is another list. A `let` used anywhere outside the root,
one whose expression may have an effect other than `Debug`'s or holds markup that is patched on
every render (above), and one that defines a function — bound to a lambda, or written with
parameters — is evaluated where it is written, as before. **A `let` is a value of one root at
most**: when two roots could take it (the `h1` in `header = <h1>{title}</h1>` and the root that
reads `header`), the innermost does, and it is evaluated once per render that needs it.

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

**A list tail, once lists are arrays** (*amended 2026-10-01*, §6.8; specified, not built). "A list
tail" above meant a cons cell, which a pattern read and did not make. On an array a pattern's tail
is a **view** the match makes, so two matches of `x :: rest` against one list give two view objects
that are equal element for element and not `===`. The promise for them is this: **a view is the
same value as another view of the same list at the same position**, and every platform identity
check treats them as one (`backend.md` §4, *Identity*, and §15.5's `same`). Everything else above
holds unchanged for a list — a list that is not rebuilt is the same object, an untouched field
holding one keeps it, and the operations `backend.md` §4 lists return their input itself when their
result would equal it. *This narrows W27's wording for one case and is the owner's to confirm
(`plans/list-arrays.md` §1, O3).* *Amended 2026-10-01 (E1tp):* on a list that has been written to,
a pattern's tail is not a view but a smaller header over the same structure; the promise holds for
it wherever the match shares that structure, and does not hold for the tail that goes past the
list's claimable head — each match copies a new head there, so two such tails are equal and not one
value (`backend.md` §4, *Identity*). The first tail of a list built by `List.push` is of that kind.

**A nullary constructor is one value** (*amended 2026-09-29*, research 39 §10.3): every use of a
nullary constructor that a module writes is the same value, so `button "run" Run` gives its hole an
identical argument on every render and §11.6's skip applies to it. A constructor with arguments
still builds a new value each time it is applied. `backend.md` §4, *A nullary constructor is one
object*, says how.

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

*Decided 2026-10-03 by the owner:* **portals and `ref` will both be supported, for Solid parity; the
design comes before code.** Real programs need modals, tooltips and dropdowns mounted outside their
component, and a platform wrapping a JavaScript widget needs the element it binds to. Until then,
focusing and scrolling go through the browser-tea platform's `Dom` tasks by element id, Elm's way.
The candidate for `ref` under The Elm Architecture is an attribute such as `ref={GotElement}` that
delivers the element to `update` after render as an opaque handle the model may hold and pass to
platform functions; the design pass confirms or replaces it.

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
    {λuser → <UserEditor user={user} />}
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

## 12. Blocks, `λ` and trailing lambdas (2026-10-02)

*Specified 2026-10-02; not built.* The owner's syntax batch of 2026-10-02
([`plans/browser-decisions.md`](../../plans/browser-decisions.md), *Syntax — 2026-10-02*) answers a
readability review of beni code as it is written today: lambdas cost two characters of punctuation
and a pair of parentheses each, `let … in` spends three lines on a block of one binding and cannot
hold a statement, Elm names whose argument order beni flipped read backwards to anyone who knows
Elm, and the formatter breaks lines that read better whole. This section is the contract for all of
it, in one place, as `static-dispatch-spike.md` is for static dispatch; §0, §2–§10 and Appendix A
point here at each rule they lose or gain. [`frontend.md`](frontend.md) §11 says how the lexer,
parser, formatter and migrations build it, [`checker-v2.md`](checker-v2.md) §29 what the checker
adds, and [`plans/syntax-batch.md`](../../plans/syntax-batch.md) the order of work.

**What does not change.** A block is a `let` with its keywords removed and statements added: the
BIR it lowers to is the `let` instruction §8 already has, plus one tag for a statement. So the
checker's binding groups, generalisation and value restriction ([`checker-v2.md`](checker-v2.md)
§8.4), §7's initialisation rule and its diagnostics, §6's evaluation order, and every byte the
backend emits for a program written without statements are what they were for the same program
written with `let`.

### 12.1 `λ` is the only lambda

| Rule | Detail |
|---|---|
| the token | **`λ`**, U+03BB GREEK SMALL LETTER LAMDA, the two bytes `CE BB` in UTF-8. It is the token `lambda` and starts a lambda exactly where `\` did: `λx -> x + 1`, `λa b -> a + b`, `λ( k, v ) -> k`, `λ{ name } -> name`, `λ_ -> 0`. Nothing may follow `λ` but a parameter, so it needs no space and the formatter writes none |
| the lexer | §2.4's "a non-ASCII byte outside a string, char or comment is `invalid_character`" gains one exception: the sequence `CE BB` is the `lambda` token, wherever code is lexed (a markup hole and an attribute value included). `Λ` (U+039B) and every other non-ASCII byte stay `invalid_character`. A `λ` is never part of an identifier, so `λx` is two tokens and `fλ` is `f` then `λ` |
| columns | §2.1's columns count bytes, so a `λ` moves every later token on its line one column right of where an editor shows it. Layout only ever compares the columns of tokens that **begin** a line (§4, §12.2) — with one exception, a `case` whose first branch shares the `of` line — so this matters only there: a branch aligned by eye under a first branch written after a `λ` on the `of` line is one column off, which is the misaligned-branch `unexpected_token` with both columns quoted, never a silent re-reading. The formatter never writes a first branch on the `of` line. *Superseded 2026-10-02* (§12.7's *columns* row, built ahead of the symbols): a column counts code points, so a `λ` is one column and the exception is gone |
| `\` | **removed.** A `\` outside a string or character literal that does not begin `\\` is still lexed, as the token `backslash`, only so that the parser can report **`backslash_lambda_removed`** at it — once per lambda, with the `λ` spelling of that lambda's head in the message (`λx y ->`) — and then parse the lambda as before, so the rest of the file still checks. The same holds inside a markup hole (`onClick={\_ -> Toggle}`) |
| multiline strings | unchanged: a line whose first non-space characters are `\\` is a `multiline_line` (§2.7). §2.7's "one byte of lookahead separates it from a lambda" is now a lookahead that separates it from the removed token, and a `\\` can never be read as a lambda, or a lambda as a `\\` |
| a lambda of no arguments | **`λ() -> e`**, the unit pattern as the one parameter — the spelling that exists today, which `backend.md` §6 *A parameter of type `()`* already compiles to a zero-parameter JavaScript function. There is **no shorthand**: `λ-> e` is `unexpected_token` at `->`, whose message says to write `λ() ->`. *Rejected:* a `λ-> e` thunk form. It would be a second spelling of one thing (the owner: "there is only one way"), it saves two characters, and a thunk passed as a trailing lambda (§12.3) reads `Task.spawn λ() ->` either way. *Amended 2026-10-02 (§12.10):* the unit pattern is written `⊤`, so a thunk is `λ⊤ → e` |
| typing it | `λ` is not on a keyboard. The language's answer is the formatter's migration (`frontend.md` §11.4) and the editor: an editor mode or the M5 language server turns a typed `\` into `λ`, as Agda and Lean editors do. **`beni fmt` does not**: it formats only valid input (§9), and a file with a `\` lambda is not one |

### 12.2 Blocks

**A block is a body written as lines: bindings and statements, the last line being the block's
value.** It replaces `let … in`, which leaves the language, and it is how a statement — an
expression run for its effect — is written at all.

```elm
update msg model =
    case msg of
        Add →
            title = String.trim model.draft
            Log.info "adding ${title}"
            if String.isEmpty title then
                model
            else
                { model | todos = [ …model.todos, newTodo model.nextId title ] }
```

**Grammar** (§3's notation; it replaces §3's `Definition`, `LetBinding`, the four `Expr` forms and
`Block`, and adds one `Atom`):

```
Definition  := lower_ident Param* '=' Body                       -- top level and in a block
Body        := Block | Expr                                      -- Block when it begins a line
Block       := Item+                                             -- aligned (layout, below)
Item        := Annotation                                        -- its Definition is the next item
             | Definition
             | LetPattern '=' Body                               -- no annotation, no parameters
             | LetPattern '<-' App                               -- rest-of-block bind, §6.7
             | Expr                                              -- a statement; the value if last
Expr        := 'if' Expr 'then' Body 'else' Body
             | 'case' Expr 'of' Branch+
             | 'λ' Param+ '->' Body                              -- irrefutable only (§7)
             | BinOp
Branch      := Pattern '->' Body
Atom        := … | '(' Block ')'                                 -- a parenthesised block
TailForm    := 'if' … | 'case' … | 'λ' …                         -- §3's `Block`, renamed
```

`BinOp := Postfix (operator Postfix)* (operator TailForm)?` is §3's rule with its last operand
renamed, so that "block" means one thing; `let` is no longer one of the forms. `App` gains a
trailing lambda (§12.3).

**Where a block may stand.** A body opens a block exactly when **its first token is the first
token on its line**, and a body follows one of five openers:

| Opener | The body of |
|---|---|
| `=` | a top-level definition; a definition or a pattern binding in a block |
| `->` | a `case` branch; a lambda, parenthesised or trailing (§12.3) |
| `then`, `else` | an `if`'s branches (`else if` is an `if` on the `else` line, so never a block) |
| `(` | a **parenthesised block**: `(` ends its line, the items follow, `)` closes it |

A body that starts on its opener's line is an expression, read exactly as today (§4): `f x = x + 1`,
`A -> 0`, `if c then a else b`. A block of one item that is an expression is that expression, so
every body written today that has no `let` means what it meant. Nothing else opens a block — not a
record field's `=`, not `<|`, not a markup hole's `{`, not a list item: an expression there that
needs a binding is a parenthesised block, a lambda's body, or a binding lifted into the enclosing
block. *Rejected:* blocks after every token that can precede an expression (F#'s rule, which
pushes a context at `(`, `[`, `{`, `=`, `then`, `else`, `->` and more). It buys a second way to
write every one of those positions and makes a record whose field holds a block legal, at the price
of reading `{ a =` / `x = 1` / `x` / `, b = 2 }` as a record.

**What an item is** is decided from its **first line**, before it is parsed: it is a **binding**
when that line holds, outside brackets, string interpolation and markup tags, a `=` or a `<-`, or
when it begins `lower_ident :`; it is an **expression** otherwise. The test is exact because a
binding's head — its pattern, or its name and parameters — is never broken across lines (the
formatter writes it on one line, §9 *patterns*), and because `=`, `<-` and a leading `name :` occur
in no expression outside those delimiters (`==`, `<=`, `/=` are other tokens, and a record's `=`
is inside braces). A pattern written across lines, `( a` / `, b ) = pair`, is read as an expression
and then reported at the `=` as `unexpected_token`, whose message says a binding's head goes on one
line.

| Item | Rule |
|---|---|
| a definition, `name params = body` | as a `let` definition was: in scope throughout the block, function or value (§7) |
| an annotation, `name : Type` | must be followed by the definition of `name` as the next item, else `annotation_without_definition`; no `where` clause (static-dispatch-spike.md §2.1) |
| a pattern binding, `pattern = body` | as a `let` pattern was: irrefutable (`refutable_let_pattern`), no annotation, no parameters. `_ = e` evaluates `e` and discards it, **whatever its type** — the explicit way to throw a value away |
| a bind, `pattern <- call` | §6.7, unchanged: the rest of the block — every item after this one — is the callback's body. The bound pattern is a parameter (`refutable_parameter_pattern`) |
| a **statement**, any expression that is not the last item | evaluated where it stands, for its effect, and its value is thrown away. **Its type must be `()`**: anything else is **`statement_not_unit`** (checker-v2.md §29), whose message names the type and the two fixes — bind it and use it, or write `_ =` to discard it on purpose. A statement is a value binding with no name for §7's initialisation rule, so it may not read a value written below it (`let_forward_reference`) |
| the **value**, the last item | an expression, which is the block's value. A block whose last item is a binding, an annotation or a bind is **`block_ends_in_binding`**, reported at that item, whose message says a block ends with the expression it stands for |

**Why a statement must be `()`.** A value thrown away without a word is the commonest way to drop
work silently in a language with immutable data: `List.push xs 4` on a line of its own builds a
list and loses it, and `Dict.insert d k v` changes nothing. Requiring `()` makes every such line an
error that names the type, and `_ =` is the one-token escape for the line whose value really is not
wanted (rule 7: the guarantee is "no silent wrong answer", the escape keeps it from being a
restriction). Roc unifies a statement with `{}` for the same reason and says the same thing in its
message (`references/roc/src/check/report.zig:1580-1597`). `e?` as a statement is the idiom for a
check that can fail: `validate input?` stops the function with the error, and otherwise yields the
`()` the statement needs. **A block ending in a binding is an error, not a `()`**: Roc inserts an
implicit `{}` (`references/roc/src/canonicalize/Can.zig:9401-9406`); beni does not, because a block
that forgot its last line would otherwise type-check whenever `()` happens to fit.

**`<-` is kept.** Statements do not replace it: a statement runs and continues, while a bind hands
the rest of the block to a function — `Task.scope`, `Task.bracket`, `Result.andThen` — that decides
whether, when and how often it runs. Its rules are §6.7's with "the rest of the block" meaning the
items after it, and §7's *order* row unchanged. A bind can never be the last item, which
`block_ends_in_binding` says, and which §6.7's "a `<-` may appear … last included, where `rest` is
the body alone" no longer allows: there is no body apart from the items.

```elm
render url s =
    scope ← Task.scope
    conn ← Task.bracket (λ⊤ → Db.open url) Db.close
    h ← Result.andThen (readHeader s)
    draw scope conn h
```

**Scoping, mutual recursion and order** are `let`'s, item for item (§6 *Evaluation order*, §7):
every name a block binds is in scope in every item of the block, so its functions are mutually
recursive whatever their order; value bindings and statements are evaluated once each, in the order
written; a value binding or statement that reads a value written below it — directly, or through a
function of the block — is `let_forward_reference`; and shadowing is an error. Roc forbids a local
definition from naming a later one and refuses mutual recursion between local functions
(`references/roc/src/canonicalize/test/local_let_scoping_test.zig:1-6`); beni keeps what `let`
promised, because §7's analysis already makes the forward case safe and refusing it would refuse
programs that check today. **Declaration order** — the guarantee `ordering_test.zig` holds, that
the order of top-level declarations never changes whether a program checks or what it prints — is a
top-level guarantee and is untouched; inside a block, order is evaluation order and always was.

**Layout.** §4's machinery, with the block in place of the `let` binding list:

| # | Rule |
|---|---|
| B1 | A block's **column** *C* is the column of its first item's first token, and must be greater than the enclosing block's indent (§4 rule 2) |
| B2 | **An item begins at a token at exactly column *C* that can start an expression**: a name, a constructor, a literal, `(`, `[`, `{`, `λ`, `if`, `case`, `_`, a `.field` accessor, a `-` that abuts an atom (negation, §6.5), a markup `<` (below), a `multiline_line` that does not continue a literal (§2.7), and `let` and `\`, so that the removed forms are reported where they stand |
| B3 | **Every other token of an item is at a column greater than *C*, or at *C* if it cannot start an expression** — `,`, `)`, `]`, `}`, `\|`, a binary operator, `\|>`, `<\|`, `?`, `then`, `else`, `of`, `->`, `=`, `<-`, `:`, a closing tag — and a `multiline_line` directly below another continues that literal wherever it stands. So a list, record or tuple written vertically from the block's column, `[ a` / `, b` / `]`, is one item, as the formatter writes it |
| B4 | **A token at a column less than *C* ends the block**, and so does a token no item can continue with (a `)` that closes an enclosing group, a `,` of an enclosing list); the enclosing construct decides whether it is legal (§4 rule 4's wording) |
| B5 | A `case`'s branches inside a block must be right of *C*: §4 rule 4's "branches at the same column as `case` are legal" does not reach a `case` that begins an item, because a branch's pattern at *C* begins the next item (B2). The `case` then has no branches, `case_without_branches` — an error, never a different program |
| B6 | A parenthesised block's `(` is the last token on its line; its items follow at *C*, and its `)` ends the last item (B4) wherever it stands. A `,` after a parenthesised block's items is `unexpected_token`: a block is not a tuple element |

**Markup at the start of a line.** §11.2 opens markup at `<` only where no operand has just ended,
and a block's value often follows a binding that ends in one (`x = f a` / `<div>…`), where `<div`
would read as `a < div`. The rule gains a third row: **a `<` that is the first token on its line,
followed by an ASCII letter or `>`, opens markup whatever precedes it** (`frontend.md` §9.3). A
comparison never begins a line that way in canonical form — the formatter writes `<` with a space
after it — so the row changes the reading only of a hand-written `x` / `<y`, which becomes an
unclosed element: an error, never a different program.

**What no longer parses the same, and why that is safe.** Before blocks, a token at the column of a
body's first token was a continuation: `f x =` / `    foo` / `    bar` was `foo bar`. Under B2 it is
two items, a statement `foo` and the value `bar`, and `foo` — a function — is not `()`, so the
program is `statement_not_unit` rather than a different program. A program that checks today
could check with another meaning only if one expression were both a function (to be applied) and
`()` (to be a statement), which no type is, `Debug.todo` aside. The formatter has never written a
continuation at its body's first column (§9: arguments, operators and branches are indented), and
the migration reformats every file it touches (`frontend.md` §11.5), so no file in canonical form
changes meaning.

**What replaces `let` in expression position.** `let … in` could stand anywhere an expression can.
A block cannot, by the openers table, and the three replacements are, in order of preference: a
binding in the enclosing block (when evaluating it earlier changes nothing — it is not inside a
branch, a lambda, or the right operand of `&&`/`\|\|`); the body of a lambda or a branch the
expression is already in; and the parenthesised block, which is what `--migrate-let` writes when
neither applies, because it is the one rewrite that never moves an evaluation:

```elm
ok =
    first
        && (
            r = check b
            r.passed
        )
```

**The removed form.** `let` and `in` stay reserved words. A `let` is parsed as it was, reported as
**`let_removed`** at the `let` — one diagnostic per `let`, whose message is the block the bindings
become — and lowered as before, so the rest of the file still checks; `beni fmt --migrate-let`
rewrites them all (`frontend.md` §11.5). `let_forward_reference` and `refutable_let_pattern` keep
their codes, which are stable (§10); their titles and messages say "block".

**Lowering, checking, emitting.** A block lowers to §8's `let` instruction: its bindings become
`let_def` and `let_pattern` as before, in written order; a bind becomes the call §6.7 gives it, the
items after it its callback; a statement becomes the new **`let_stmt`**, whose operand is the
statement's expression; the value is the instruction's body. A parenthesised block is the same
instruction. `checker-v2.md` §29 checks a `let_stmt` as a pattern binding whose pattern is `()`,
under its own diagnostic; the backend emits it as `let _ = e` has been emitted since 2026-10-02 —
the expression as a JavaScript statement (`backend.md` §4, *A discarded value is a statement*).
`?` (§6.6) returns from the nearest enclosing definition with parameters, a block's included, as it
did from a `let`'s.

### 12.3 A lambda as the last argument

**The last argument of an application may be a lambda without parentheses**: `List.map todos λt ->
t.title`. It is the trailing-closure form of Swift, Kotlin and Ruby, and it is why the library is
function-last (§6.7, *library convention*): `List.foldl xs 0 λx acc -> x + acc`, `Maybe.map2 a b
λx y -> x + y`, `Task.scope λscope ->`.

```
App            := Atom Arg* TrailingLambda?
TrailingLambda := 'λ' Param+ '->' Body
```

| Rule | Detail |
|---|---|
| why it is unambiguous | a lambda was never an argument without parentheses — `f \x -> x` is §3's error, "write `f (\x -> x)`" — so admitting one as the **last** argument changes the reading of no program. Nothing can follow it as a further argument, because its body comes next: `f λx -> x y` is `f (λx -> x y)` |
| **where its body ends** | a body that **begins on a later line** than the `->` is a block (§12.2), ending where the block ends. A body that **begins on the `->` line** ends at the first token on a later line whose column is not greater than *L*, the column of the first token of the line the `λ` is on — the indentation of the line the lambda starts on, which is what a reader sees. Within that, it is an expression and stops where an expression stops: at `,`, a closing bracket, `then`, `else`, `of` |
| in a pipeline | so `todos` / `\|> List.filter λt -> t.done` / `\|> List.length` is a three-stage pipeline: the second `\|>` begins a line at column *L* and ends the first lambda's body. On **one** line the body takes everything after its `->`: `xs \|> List.filter λt -> t.done \|> List.length` is `List.filter xs (λt -> t.done \|> List.length)`, a type error at `List.length`. The formatter never writes that line (§9, *trailing lambdas*), so the reading is always the one the layout shows |
| `\|>` | a trailing lambda is part of its application, so `xs \|> List.map λx -> f x` is an application on the right of `\|>` and is `List.map xs (λx -> f x)` (§6.7 `pipe_rhs_not_application` is satisfied) |
| `<\|` | `f a <\| λx -> e` keeps its meaning, `f a (λx -> e)`. It is now the second spelling of a trailing lambda, and the formatter writes the first (§9) |
| `_` | a placeholder may stand among the other arguments: `f _ λx -> e` is `λp -> f p (λx -> e)` (§6.7). A trailing lambda is a lambda for §6.6, so a `?` in its body is `question_in_lambda` |
| `<-` | a bind's right-hand side may end in a trailing lambda; the callback is then appended after it: `x <- f λy -> g y` is `f (λy -> g y) (λx -> rest)` |
| markup | a hole or an attribute value may hold an application with a trailing lambda; its body ends at the hole's `}`: `{List.map todos λt -> <li>{t.title}</li>}`, `onInput={λs -> Typed s}` (a bare lambda there needs no rule: it is the whole hole) |
| parentheses | still legal around a last-argument lambda, and required around one that is not last: `Task.bracket (λ() -> open url) close λconn -> use conn`. The formatter removes them where they are redundant (§9) |
| lowering | none: the parser builds the same `lambda` node as the last argument of the same `app`, so BIR, checking and emitting cannot tell the two spellings apart |

### 12.4 Names that read right subject first

beni's library is subject first (§6.7), so every Elm function that took its subject last takes its
arguments in another order under the same name. **The owner's rule is "no Elm name with a flipped
argument order"** — and since that is every subject-first function, from `List.map` down, the audit
reads it as the decision's own example does (`modBy` giving way to "names that read right in
subject-first order"): no Elm name whose call reads wrong, or silently computes something else, in
beni's order. The audit below covers every `pub` value of
`core/` and of the platforms that shares a name with an Elm 0.19 function (`elm/core`,
`elm/random`) and orders its arguments differently. Each function is one of three things:

- **renamed**, when its *name* names an argument by role — `modBy n 2` reads "mod by `n`", but `n`
  is the dividend — so a call reads backwards to anyone who knows the Elm name. These are also the
  silent ones: both arguments have one type, so a call written in Elm's order checks and computes
  something else;
- **reordered** to Elm's order, for the one function whose subject is not its first argument;
- **kept**, when the name names no argument and reads right in beni's order. Where Elm's order would
  still type-check, the warning in §12.5 catches the shape a ported call has.

| Elm | beni today | Verdict | beni after |
|---|---|---|---|
| `modBy : Int -> Int -> Int` (modulus, then the number) | `modBy : Int, Int -> Int` (number, modulus) | **renamed** | **`Int.mod : Int, Int -> Int`** — `Int.mod n 2`; the sign of the modulus, as `Int32.mod` |
| `remainderBy` (divisor, then the number) | `remainderBy : Int, Int -> Int` (number, divisor) | **renamed** | **`Int.rem : Int, Int -> Int`** — `Int.rem n 3`; the sign of the dividend, as `Int32.rem` |
| `logBase : Float -> Float -> Float` (base, then the number) | `logBase : Float, Float -> Float` (number, base) | **renamed** | **`Float.log : Float, Float -> Float`** — `Float.log 100 10 == 2` |
| `Debug.log : String -> a -> a` | `Debug.log : a, String -> a` | **reordered** | **`Debug.log : String, a -> a`**, Elm's order: `Debug.log "total" (List.sum xs)`. The label is not the subject — the value passes through — but the label is short and the value long, so label first keeps the label beside the word `log` when the call wraps an expression, which is why Elm chose it; the pipeline spelling it was flipped for (`xs \|> Debug.log "xs"`) occurs once in the repository. As a statement, `Debug.log "done" ()` |
| `clamp : number -> number -> number -> number` (low, high, n) | `clamp : number, number, number -> number` (n, low, high) | kept | `clamp n low high` reads right, and it is the order Rust, C++ and JavaScript's `Math.clamp` give the same name. Elm's order type-checks: §12.5's warning |
| `String.split`, `contains`, `startsWith`, `endsWith`, `indexes`, `indices` (the needle first) | the string first | kept | `s.startsWith "http"`, `String.split line ","` read right, and they are JavaScript's, Go's, Rust's and Python's order under the same names. Elm's order type-checks: §12.5's warning |
| `String.replace` (before, after, string) | string, before, after | kept | as above: `s.replace "a" "b"` is JavaScript's `s.replace(a, b)`; §12.5's warning |
| `List.repeat : Int -> a -> List a` | `List.repeat : a, Int -> List a` | kept | `List.repeat x 3` reads "repeat `x` 3 times", Rust's `vec![x; 3]` order. Elm's order type-checks for a list of `Int`, and no syntactic shape tells the two apart (`List.repeat 0 3` is both); the doc comment says so |
| `String.join : String -> List String -> String`, `String.repeat`, `left`, `right`, `dropLeft`, `dropRight`, `slice`, `pad`, `padLeft`, `padRight`, `cons` | the string or list first | kept | the arguments have different types, so a call in Elm's order is a `type_mismatch` whose hint shows the call in beni's order (§12.5) |
| `Maybe.withDefault`, `Result.withDefault`, `Result.fromMaybe`, `Result.mapError`, `andThen`, `map`, `map2`–`map5` (Maybe, Result, List, Random), `List.foldl`, `foldr`, `filter`, `filterMap`, `concatMap`, `indexedMap`, `member`, `take`, `drop`, `intersperse`, `sortBy`, `sortWith`, `partition`, `any`, `all`, the `String` higher-order functions, `Dict.get`, `member`, `insert`, `remove`, `update`, `map`, `foldl`, `foldr`, `filter`, `partition`, `Set.insert`, `remove`, `member`, `map`, `foldl`, `foldr`, `filter`, `partition`, `Random.list`, `Random.generate`, `Cmd.map`, `Sub.map` | the subject first, the function last | kept | different types, as above. Function last is what makes a trailing lambda possible (§12.3): `Maybe.withDefault m 0` reads "`m` with default 0", and `List.foldl xs 0 λx acc -> x + acc` is the shape the batch exists for |

`List.cons x xs` keeps the element first — Elm's order and the order of the bracket form it spells
(§6.8) — and was never flipped. `Dict.union`, `intersect`, `diff`, `Set`'s three, `List.range`,
`List.append`, `String.append`, `always`, `compare`, `atan2`, `Random.int`, `Random.float`,
`Random.step` and `Random.uniform` already take Elm's order.

**`Int` and `Float` get modules of their own; the types stay in `Basics`.** *Amended 2026-10-01
(the owner), replacing the move this paragraph specified on 2026-10-02.* `core/Int.beni` and
`core/Float.beni` are ordinary core modules: `core/Int.beni` holds `mod` and `rem`, and
`core/Float.beni` holds `log`, each written in beni over `Js` as `modBy`, `remainderBy` and
`logBase` were, with no `foreign`, and each importing `Basics` like any other module. The `Int` and
`Float` **types** stay declared in `core/Basics.beni`, beside `Bool`, `Order` and `Never`, and the
well-known table of static-dispatch-spike.md §3.2 serves them as before (that document's A.6
stands). `Int` and `Float` join the prelude's **module aliases** (Appendix A), so `Int.mod n 2`,
`Int.rem n 3` and `Float.log x 10` need no import, as the prelude names they replace needed none.
**The method forms `n.mod 2` and `x.log 10` are not offered**: under the module rule
(static-dispatch-spike.md §1.2) a type's methods are the `pub` values of the module that declares
it, which stays `Basics`, and `Basics` declares no `mod`, `rem` or `log`. *Why the types did not
move:* moving them out of `Basics`, as `String` and `Char` moved on 2026-09-17 (§5.4,
static-dispatch-spike.md §5.1), makes an import cycle. `Basics` keeps every function typed with
`Int` or `Float` — `round`, `idiv`, `toFloat`, `sqrt`, the trigonometry — and writes numeric
literals, so it would need `Int` and `Float`; and `Int` and `Float` need `Bool`, `Order` and the
operator functions of `Basics`. `String` and `Char` escaped the cycle because `Basics` names
neither. Breaking it would move `Bool`, `Order` and the operators as well, the churn A.6 declined;
the owner's `Int.mod i 10` does not need it.

**The removed names.** `modBy`, `remainderBy` and `logBase` leave `Basics` and the prelude (Appendix
A); nothing unqualified replaces them, so `mod` and `rem` stay free as local names. A use of one —
unqualified, as `Basics.modBy`, in an `exposing` list, or as a method `n.modBy 2` — is
**`name_removed`**, at the name, whose message names the replacement with the call rewritten:
*`modBy` was removed: beni's `modBy n 2` read as Elm's `modBy 2 n`. Write `Int.mod n 2`.* A method
`n.modBy 2` gets the same qualified call, there being no method to offer (*amended 2026-10-01*). The
removed names are a table in the compiler beside the prelude, consulted by lowering for an
unqualified name and by resolution for a qualified one, before either says `unbound_variable` or
that the module does not expose the name. *As built (2026-10-01):* the table is
`src/bir/prelude.zig`'s `removed`, read by lowering (unqualified), resolution (qualified, and an
`exposing` entry, where only resolution knows the module is core's `Basics`), the checker (a
method on a type `Basics` declares) and `beni fmt --migrate-names`; the message is one text
for all four, its example call the table's.

### 12.5 The formatter, its gate, and call-style diagnostics

**Formatter rules** — §9's table carries each as an amended or added row:

| Rule | Detail |
|---|---|
| **a one-line `if`** | an `if` the author wrote on one line stays on one line when it fits in 100 columns and its condition and both branches have a one-line form (no `case`, block, multiline string, comment, or construct the author broke): `if t.id == id then { t \| done = not t.done } else t`. An `else if` chain is one `if` for this rule. An `if` written across lines stays vertical, as before: the never-join rule is not relaxed, so the formatter does not join the vertical `if`s it wrote until now |
| **hanging the last argument** | an application whose last argument is a lambda, a list, a record, a record update or markup **hangs** it. When the application must break — it does not fit, or the author broke it — and the callee with every other argument fits on one line, those stay on that line **whatever source breaks lie between them** (the never-join rule does not apply among a hanging application's head arguments, as it does not to the break after `=`), and the last argument starts there: a lambda's `λparams ->` ends the line and its body follows as a block indented 4 from that line's indentation; a list, record or markup goes on the next line, indented 4, in its own one-line or vertical form. An application that does not qualify breaks as before. A definition or binding whose body is an application hanging a **lambda** keeps the head line on its `=` line when it fits there: `todos = List.map model.todos λt ->` |
| **trailing lambdas** | a parenthesised lambda that is an application's last argument loses its parentheses, unless the token after the `)` on the same line is a binary operator or `?` (the body would take it, §12.3); `f a <\| λx -> e` is written `f a λx -> e`. A trailing lambda's body stays on the `->` line only when the whole body fits there and the lambda ends its line; otherwise it is a block on the lines below |
| **blocks** | items one per line at the block's column, which is 4 right of the opener line's indentation; a block always starts on the line after its opener and is never joined to it. At most one blank line between items, kept if present, never added. A parenthesised block is `(` at the end of its line, the items, and `)` alone on a line at the indentation of the line holding `(` |
| **a blank line after a comment** | between a standalone `--` comment (a comment on a line of its own) and the next token, one blank line is kept when the source has one, so a comment that labels a section is not glued to the section's first line. Doc comments are unchanged. *Amended 2026-10-01:* the blank line is dropped where the comment has nothing to label or where §9 never puts one — before a closing bracket (`)`, `]`, `}`), an interpolation's end, a markup tag's end (`>`, `/>`, `</`), `then`, `else`, `in` and `of`, at the end of the file, and between an annotation and its definition, which stay adjacent |
| **aligned parameters** | when a function type breaks (§9 *function types*), the first parameter is indented 6 rather than 4, so that every parameter starts in one column under the `, ` that leads the others: `update :` / `      Msg` / `    , Model` / `    -> Model` |

**`beni fmt --check` is a gate.** `zig build gates` gains a step, `beni-fmt-check`, which runs the
gates' own beni as `beni fmt --check` over every `.beni` file under `core/`, `platforms/`,
`bench/`, `tests/corpus/` and `tests/platforms/`, except the files that `tests/fmt-exempt.txt`
names. That file is one glob per line, each followed by `--` and its reason, and it starts with two
entries: `tests/corpus/fmt/**` (formatter inputs, unformatted on purpose — their `.expected` files
are already held to be fixed points) and `tests/corpus/parse/bad/**` (files that must not parse).
Every other exemption is a single file, hand-picked, with its reason — a `parse/good/` fixture that
pins a layout the formatter never writes, a `check/bad/` fixture whose syntax error is the point —
and an entry naming a single file that does not exist, or that is already canonical, fails the step,
so the list cannot rot. A file that fails `--check` fails the gate with the file named; `beni fmt
<file>` fixes it. The step is `frontend.md` §11.6's to build.

**Call-style diagnostics.** Four places where a habit from JavaScript or Elm meets a beni call:

| Written | Today | After |
|---|---|---|
| `xs.length`, `s.trim` — a field access on a value whose type is not a record, naming a `pub` function of the type's module that takes the value first | `type_mismatch`, "This is not a record with a `length` field" | the same code, with a hint: *`length` is a function of `List`, not a field. Write `List.length xs` — a method call needs its other arguments, `xs.take 3`, so one that takes none is written as a call.* |
| `xs.length ()` — a method call whose only argument is `()` | `too_many_args` | the same code, with the same hint |
| `f(a, b)` — an application whose one argument is a tuple literal written against the callee, when the callee takes as many parameters as the tuple has elements | `too_few_args` or `type_mismatch` | the same code, with a hint: *beni separates arguments with spaces: `f a b`.* |
| a call of a `core/` or platform function, in Elm's order, that fails to check | `type_mismatch`; the hint "this function looks like it belongs in the 2nd argument" exists today for a misplaced function | the hint generalises to every function §12.4 lists as kept with a different order: when the call would check with its arguments in Elm's order, the hint shows it in beni's — *`String.join` takes the list first: `String.join names ", "`* |

and one warning, for the kept functions whose Elm-ordered call still type-checks:
**`suspicious_argument_order`**, a `warning` on by default for the root package only, at a call of
`clamp`, `String.split`, `contains`, `startsWith`, `endsWith`, `indexes`, `indices` or `replace`
whose **subject** — the first argument — is a literal while its last argument, where Elm's order
puts the subject, is not: the shape `String.split "," line`, `clamp 0 100 x`, which beni code
written for beni never has. The
message shows the call in beni's order; the escape, when the literal really is the subject, is the
method form (`",".split line`) or a name. It is a warning and not an error because the call may be
meant (rule 7). `checker-v2.md` §29 places all five.

### 12.6 One program, before and after

A TodoMVC `update` and `view` for the `browser-tea` platform, and a loop from a core-style module,
as canonical beni before this section …

```elm
update : Msg, Model -> Model
update msg model =
    case msg of
        Add ->
            let
                title = String.trim model.draft
            in
            if String.isEmpty title then
                model
            else
                { model
                    | todos = [ ...model.todos, { id = model.nextId, title = title, done = False } ]
                    , nextId = model.nextId + 1
                    , draft = ""
                }

        Toggle id ->
            { model
                | todos =
                    List.map model.todos
                        (\t ->
                            if t.id == id then
                                { t | done = not t.done }
                            else
                                t
                        )
            }

        ClearDone ->
            let
                _ = Debug.log (List.length model.todos) "todos before"
                _ = Log.info "clearing"
            in
            { model | todos = List.filter model.todos (\t -> not t.done) }


view : Model -> Html Msg
view model =
    let
        left = List.length (List.filter model.todos (\t -> not t.done))
    in
    <section class="todoapp">
        <ul class="todo-list">
            <For each={model.todos} keyed={.id}>
                {\t i ->
                    let
                        stripe =
                            if modBy i 2 == 0 then
                                "even"
                            else
                                "odd"
                    in
                    <li class={stripe} onClick={Toggle t.id}>{t.title}</li>}
            </For>
        </ul>
        <span>{left} items left</span>
    </section>


hash : String -> Int
hash s =
    String.foldl s 5381 (\c h -> modBy (h * 33 + Char.toCode c) 4294967296)
```

… and after it, as a programmer writes it now:

```elm
update : Msg, Model → Model
update msg model =
    case msg of
        Add →
            title = String.trim model.draft
            if String.isEmpty title then
                model
            else
                { model
                    | todos = [ …model.todos, { id = model.nextId, title = title, done = False } ]
                    , nextId = model.nextId + 1
                    , draft = ""
                }

        Toggle id →
            todos = List.map model.todos λt →
                if t.id == id then { t | done = not t.done } else t
            { model | todos = todos }

        ClearDone →
            _ = Debug.log "todos before" (List.length model.todos)
            Log.info "clearing"
            { model | todos = List.filter model.todos λt → not t.done }


view : Model → Html Msg
view model =
    left = List.length (List.filter model.todos λt → not t.done)
    <section class="todoapp">
        <ul class="todo-list">
            <For each={model.todos} keyed={.id}>
                {λt i →
                    stripe = if Int.mod i 2 == 0 then "even" else "odd"
                    <li class={stripe} onClick={Toggle t.id}>{t.title}</li>}
            </For>
        </ul>
        <span>{left} items left</span>
    </section>


hash : String → Int
hash s = String.foldl s 5381 λc h → Int.mod (h * 33 + Char.toCode c) 4294967296
```

What each change is: the `let`s are blocks (§12.2), and `Log.info "clearing"`, a `()`, is a
statement while `Debug.log`'s value is discarded with `_ =`; every lambda is `λ` (§12.1) and every
last-argument lambda sheds its parentheses (§12.3), the `Toggle` body hanging below its head line
(§12.5); `Debug.log` takes its label first and `modBy` is `Int.mod` (§12.4); the `if`s written on one line stay there (§12.5). `<section` and `<li` begin
their lines after an operand, which is the markup row of §12.2's layout. The migrations
(`frontend.md` §11.4–§11.5) write the same program less the choices a person makes: they keep
`_ = Log.info "clearing"` as it was (seeing that its value is `()` needs types), keep the `if`s that
were vertical vertical (the never-join rule), leave the `Toggle` record update nested rather than
naming `todos`.

### 12.7 Unicode notation: one symbol for each arrow, comparison, pipe and spread

*Specified 2026-10-01; built 2026-10-02* — taught, the repository migrated, and the ASCII
spellings refused (`frontend.md` §11.8's *As built* notes). The owner adopted Lean 4's Unicode notation on 2026-10-01
([`plans/browser-decisions.md`](../../plans/browser-decisions.md) S8: "let's adopt the lean unicode
stuff"), with one spelling each, as §12.1 made `λ` the only lambda: Lean accepts `->` beside `→`
and `<=` beside `≤`, beni keeps only the symbol. This subsection is the contract for the tokens,
§12.8 for tuple types written with `×`, §12.9 for the formatter, the editor and the order of work;
[`frontend.md`](frontend.md) §11.8 says how the lexer, parser and `beni fmt --migrate-unicode`
build it. The open choices it made are `plans/syntax-batch.md` §1.3, Z1–Z15, all confirmed by the
owner as recommended on 2026-10-02.

**What does not change.** Every symbol is a new spelling of a token that exists, with that
token's grammar, binding power and associativity (§3, §6.5); the AST, the BIR and every byte the
backend emits are the same for a program written in either spelling, and `dump --stage=ast` and
`--stage=bir` print the same text for both — from the teach step they name an operator by its
symbol, `(op_fn ≠)` and `method_call … (≤)`, whichever spelling was read (the BIR dump's own
`lambda [...] -> %n` is dump notation, not source, and stays). Tuple **values** and **patterns** keep `( a, b )`.
`&&`, `||`, `==` and `++` stay ASCII, and so do `<`, `>`, `+`, `-`, `*`, `/`, `//`, `^`, `=`, `:`,
`|`, `?`, `_` and `..`: Lean writes `&&`, `||`, `==` and `++` in ASCII too, `<` is markup's opener
(§11.2), and `=` and `==` keep their meanings (Lean's `=` is propositional equality, not beni's
definition).

| Symbol | Code point | UTF-8 | Replaces | Token tag | Used for | Lean 4 |
|---|---|---|---|---|---|---|
| `→` | U+2192 RIGHTWARDS ARROW | `E2 86 92` | `->` | `arrow` | function types (§3), `case` branches, lambdas (`λx → e`) | `→` is the function type, right-associative at precedence 25; match arms and `fun` use `=>` (or Mathlib's `↦`) — beni keeps its one arrow for all three, as it had one `->` |
| `←` | U+2190 LEFTWARDS ARROW | `E2 86 90` | `<-` | `arrow_left` | the bind, `x ← f a` (§6.7, §12.2) | `let x ← e` in `do` notation: the same reading, the rest of the block runs with `x` bound |
| `≠` | U+2260 NOT EQUAL TO | `E2 89 A0` | `/=` | `op_ne` | inequality, precedence 4, non-associative | `≠` is `Ne`, `infix:50` |
| `≤` | U+2264 LESS-THAN OR EQUAL TO | `E2 89 A4` | `<=` | `op_le` | precedence 4, non-associative | `infix:50`, written `unicode(" ≤ ", " <= ")` — the ASCII is Lean's alternative |
| `≥` | U+2265 GREATER-THAN OR EQUAL TO | `E2 89 A5` | `>=` | `op_ge` | precedence 4, non-associative | `infix:50`, `unicode(" ≥ ", " >= ")` |
| `▷` | U+25B7 WHITE RIGHT-POINTING TRIANGLE | `E2 96 B7` | `\|>` | `op_pipe_right` | the pipe, precedence 0, left, syntactic (§6.7) | **not Lean's**: Lean's pipe is ASCII `\|>` (`syntax:min`); `▷` is the owner's choice. The editor abbreviation `\rhd` gives it |
| `◁` | U+25C1 WHITE LEFT-POINTING TRIANGLE | `E2 97 81` | `<\|` | `op_pipe_left` | backward application, precedence 0, right, syntactic | **not Lean's**: Lean writes `<\|`. `\lhd` gives it |
| `…` | U+2026 HORIZONTAL ELLIPSIS | `E2 80 A6` | `...` | `ellipsis` | the spread of a list (§6.8) and of a component's attributes (§11.5): `[ x, …rest ]`, `{…attrs}` | **not Lean's** (Lean's structure update is `..`); `\ldots` gives it |
| `×` | U+00D7 MULTIPLICATION SIGN | `C3 97` | `( a, b )` in a **type** | `times` | the tuple type, §12.8 | `×` is `Prod`, `infixr:35` — beni keeps Lean's precedence but not its nesting (§12.8) |

| Rule | Detail |
|---|---|
| **tokens** | each symbol is a token tag of its own, distinct from its ASCII spelling's, because a token's length is re-derived from its tag (`frontend.md` §3.2). The symbol takes the tag name above; the ASCII spelling is renamed `ascii_arrow`, `ascii_arrow_left`, `ascii_ne`, `ascii_le`, `ascii_ge`, `ascii_pipe_right`, `ascii_pipe_left` and `ascii_ellipsis` (so `op_slash_eq`, `op_lte` and `op_gte` are gone as names). The parser treats the two tags of a pair as one token everywhere, so until the enforce step a file may mix spellings, token by token |
| **the lexer** | §2.4's ASCII-only rule gains nine more exceptions beside `λ`: the byte sequences in the table are those tokens wherever code is lexed — a markup hole, an interpolation hole, an attribute's `{…}` value and a `where` clause included. They are **never** recognised inside a string, a character literal, a multiline string, a comment (doc comments included), markup text or a quoted attribute value, which keep whatever bytes they hold. A symbol is never part of an identifier or of another token: `a→b` is three tokens, `≤=` is `≤` then `=`, `……` is two spreads |
| **negative operands** | §2.2's longest-match trap — `x <-1` lexes as `<-`, so a comparison with a negative operand needs a space — does not exist for the symbols: `x ≤-1` and `x ≥-1` are `x ≤ -1` and `x ≥ -1`, the `-` being negation by §6.5's rule. `x <-1` itself still lexes as `ascii_arrow_left` (the enforce step reports it, and its message names `x < -1`) |
| **operators as functions** | `(≠)`, `(≤)` and `(≥)` are the 2-ary functions `(/=)`, `(<=)` and `(>=)` were; `(▷)` and `(◁)` are `operator_not_a_function`, as `(\|>)` and `(<\|)` are (§6.5) |
| **`×` outside a type** | `times` is a type token only. In an expression it is `unexpected_token`, with a message that says multiplication is `*` and a tuple value is `( a, b )` |
| **the ASCII spellings, removed** | from the enforce step (§12.9) each `ascii_*` token is still lexed, only so that the parser can report **`ascii_symbol_removed`** at it — title REMOVED ASCII SYMBOL, the message naming the symbol, its code point, the flag `beni fmt --migrate-unicode` and the editor input below — and then parse on as the symbol, so one stale token costs one message and the rest of the file checks. It is reported at every occurrence, as `backslash_lambda_removed` is, because each one is an edit and an editor needs each span. The `<-` message adds *if you meant less than a negative number, write `x < -1`*; a `...` where no spread may stand gets `ascii_symbol_removed` and not the spread's `unexpected_token`. The parenthesised tuple type is §12.8's `tuple_type_removed` |
| **columns** | §2.1's column counts bytes, so every symbol here (two or three bytes, one column on screen) would move a diagnostic's column and its excerpt's `^` one or two places right of where an editor shows it, on most lines of a program — the defect §12.1's *columns* row accepted for `λ` alone. **From the teach step, a column counts code points** (Unicode scalar values) from the line start, in every diagnostic's `{line, col}`, its excerpt's underline, and every layout comparison. Byte offsets stay what spans are made of. Indentation is ASCII, so no line-start column moves, and §12.1's one exception — a `case` whose first branch shares the `of` line after a `λ` — is no longer one. A code point is not a display cell: a CJK character in a string is two cells and one column, as in Rust's and Lean's own diagnostics. *Built 2026-10-02, before the symbols:* `diagnostic.position` takes the source and counts code points; the parser keeps every token's column when a file holds a byte past ASCII; the excerpt pads and underlines in code points; the token, AST and diagnostic outputs and the formatter's measure all count the same way |

**Lookalikes.** A character that a reader cannot tell from one of the symbols, or that a habit from
another notation produces, is refused by the lexer as **`invalid_character`** with a message that
names it — code point and Unicode name — and the symbol to write, and the parse goes on as though
that symbol had been written (`frontend.md` §11.8), so the mistake costs one message. Every other
non-ASCII byte outside a string, character or comment stays plain `invalid_character`, `Λ`
(U+039B) included (§12.1).

| Written | Code points | Message says write |
|---|---|---|
| `−`, `－` | U+2212 MINUS SIGN, U+FF0D FULLWIDTH HYPHEN-MINUS | `-` |
| `⇒`, `⟶`, `⟹`, `➝`, `➔`, `↦` | U+21D2, U+27F6, U+27F9, U+279D, U+2794, U+21A6 | `→` — `⟶` is Mathlib's morphism arrow and `↦` Lean's `fun x ↦ e`, both of which a Lean user types by habit |
| `⟵`, `⇐` | U+27F5, U+21D0 | `←` |
| `≦`, `⩽` | U+2266, U+2A7D | `≤` |
| `≧`, `⩾` | U+2267, U+2A7E | `≥` |
| `▶`, `▹`, `▸`, `▻`, `⊳` | U+25B6, U+25B9, U+25B8, U+25BB, U+22B3 | `▷` — `▹` is what Lean's editor gives for `\triangleright`, and `▸` Lean's `\t` (`Eq.subst`); `▶` is also an emoji base |
| `◀`, `◃`, `◂`, `◅`, `⊲` | U+25C0, U+25C3, U+25C2, U+25C5, U+22B2 | `◁` |
| `⋯`, `‥` | U+22EF MIDLINE HORIZONTAL ELLIPSIS, U+2025 TWO DOT LEADER | `…` |
| `⨯`, `✕` | U+2A2F VECTOR OR CROSS PRODUCT, U+2715 MULTIPLICATION X | `×` |
| U+FF01 – U+FF5E | the fullwidth forms (`＜`, `＞`, `＝`, `｜` …) | the ASCII character 0xFEE0 below it, named; the parse does **not** go on as that character, which may be a letter |
| `!=` | ASCII `!` then `=` (a lone `!` is `invalid_character` today) | `≠` — one message for the pair |
| `=>` | ASCII `=` then `>`, adjacent, where `→` is expected (a `case` branch, a lambda) | `→`, as `expected_token`'s message — the parser's, not the lexer's |
| `*` in a type | `Int * String` | `×`, as `unexpected_token`'s message |

`x` between two types (`Int x Int`) is an ordinary type variable and cannot be refused; it is a
`wrong_type_arity` on `Int` like any other.

### 12.8 `×` writes a tuple type

**A tuple type is its element types joined by `×`**: `Int × String` is the type of `( 1, "a" )`.
It replaces `( Int, String )` in every place a type is written — an annotation, a `type alias`, a
constructor's payload, a `foreign` signature, a `where` constraint, a record field, a schema's
type positions — and nothing else about tuples changes: their values and patterns, `t.0`, any arity
of two or more, `ambiguous_tuple`. `()` is unit, not a product, and does not change.

```
Type        := TypeParams '→' Type                               -- n-ary, right assoc in result
             | Product
TypeParams  := Product (',' Product)*                            -- no comma is a 1-ary function
Product     := TypeApp ('×' TypeApp)*                            -- n ≥ 2 operands: an n-tuple
TypeApp     := … as in §3 …                                      -- 'equatable' may start each operand
TypeAtom    := … as in §3, less the tuple line …                 -- '(' Type ')' still groups
```

**Precedence, from tightest:** type application, then `×`, then the parameter comma, then `→` —
Lean's order, where application binds tightest, `×` is 35 and `→` 25. **`×` is n-ary, not
nested**: a chain of `n` operands written without parentheses is one `n`-tuple. Lean's `×` is
right-associative, so its `α × β × γ` is a pair whose second element is a pair; beni's is a
3-tuple, because beni's tuples are n-ary values — `( a, b, c )` and `t.2` exist — and the nested
reading would make `a × b × c` a type no three-element tuple has. A parenthesised operand is never
flattened.

| Written | Is | Was |
|---|---|---|
| `Int, Int → Int` | a 2-ary function | `Int, Int -> Int` |
| `Int × Int → Int` | a 1-ary function over a pair | `( Int, Int ) -> Int` |
| `Int → Int × Int` | a 1-ary function returning a pair | `Int -> ( Int, Int )` |
| `Int, String × Bool → Order` | a 2-ary function whose second parameter is a pair | `Int, ( String, Bool ) -> Order` |
| `a × b × c` | a 3-tuple | `( a, b, c )` |
| `a × (b × c)`, `(a × b) × c` | pairs, one element of each a pair | `( a, ( b, c ) )`, `( ( a, b ), c )` |
| `Maybe a × List b` | a pair of `Maybe a` and `List b` | `( Maybe a, List b )` |
| `Maybe (a × b)`, `Pair (Int × Int)`, `Dict String (Int × Int)` | a product as a type argument or a constructor's payload takes parentheses, as any non-atom does | `Maybe ( a, b )` |
| `(Int → Int) × String` | a pair whose first element is a function: `→` binds loosest, so it takes parentheses | `( (Int -> Int), String )` — the inner parentheses were the trap |
| `(Int × Int → Int) × String` | the pair §3's trap row meant | `(((Int, Int) -> Int), String)` |
| `(a × b)` | `a × b` — a grouping | — |
| `{ at : Int × Int, label : String }` | two fields: §3's comma rule is unchanged, and `×` is not a comma | `{ at : ( Int, Int ), label : String }` |
| `equatable a × b` | marks `a`; a `TypeApp` starts after every `×` as after every comma (§3 *`equatable`*) | `( equatable a, b )` |
| `() × a` | a pair whose first element is unit | `( (), a )` |

`schema.md`'s left-nested builder product, `( ( ( (), a ), b ), c )`, is `((() × a) × b) × c`:
every level parenthesised, because unparenthesised it would be one 4-tuple.

**`( a, b )` in a type is removed.** From the enforce step (§12.9) a parenthesised list of two or
more types closed by `)` — §3's tuple `TypeAtom` — is **`tuple_type_removed`** at its `(`, title
REMOVED TUPLE TYPE, the message the type written with `×` (parenthesised when it stands where
an atom must, `Maybe (a × b)`), and is then parsed as the tuple it was, so the file checks on.
`( a, b → c )`, a parenthesised parameter list, is not a tuple and is untouched. With no tuple type
written with commas, `arrow_in_tuple_element`'s trap cannot be written any more; the code stays in
the catalogue (§10), and where it and `tuple_type_removed` would both be reported for one type only
`tuple_type_removed` is.

**Rendering.** The type renderer ([`checker.md`](checker.md) §8.2) prints `→` and `×` from the
enforce step, so a diagnostic, `dump --stage=types` and `--stage=interface` show what the program
must write. Its minimal parentheses gain one rule: a product is parenthesised as a type argument, a
constructor payload or an operand of another product, and nowhere else — not as a parameter, a
result or a field type. So the 1-ary function over a pair prints `Int × Int → Int`, still
distinguishable from the 2-ary `Int, Int → Int`. The renderer's truncation mark `…` (§8.2 there)
is already U+2026; a type has no spread, so the two cannot be confused.

### 12.9 The formatter, the editor, and the order of work

| Rule | Detail |
|---|---|
| **spacing** | the formatter writes one space either side of `→`, `←`, `≠`, `≤`, `≥`, `▷`, `◁` and `×`, and `…` against its operand (`[ x, …rest ]`, `{…attrs}`), as it wrote their ASCII spellings. `λx → e` |
| **width** | the 100-column measure (§9, `frontend.md` §3.7) counts code points, as §12.7's columns do: `→` is one column, not three bytes. No canonical file changes for it — a measure that shrinks can only let a construct fit, and the never-join rule keeps every construct an author broke broken. *As built (2026-10-02):* not quite — a hung trailing lambda (§12.5) is joined to its head line whenever the whole fits, so fifteen files of the gate's scope, each with a hung lambda whose joined line is at most 100 code points but more than 100 bytes, were joined in the commit that moved the measure |
| **a product type** | on one line when it fits and the author wrote it on one line; otherwise it breaks **before** each `×`, the operands after the first one per line, indented 4, `×` leading — the shape of an operator chain (§9). Parentheses the author wrote around a product are kept, as every grouping in a type is (§3) |
| **during the teach and migrate steps** | the formatter prints each token in the spelling it read, so a file may mix spellings and `beni fmt` moves no file from one to the other; a tuple type written `( a, b )` is printed as it was |
| **from the enforce step** | a file holding an ASCII spelling or a comma tuple type has syntax errors, so `beni fmt` reports it and leaves it untouched (§9, *total on valid input*); the formatter only ever prints the symbols |
| **`beni fmt` does not convert** | as with `λ` (§12.1, Y2): converting would make the ASCII a second input spelling. `beni fmt --migrate-unicode` migrates files (`frontend.md` §11.8) |

**Typing the symbols.** None is on a keyboard. The editor answer is the language server (M5) and
editor modes, which replace the ASCII spelling **as it is typed**, in code only — never in a
string, a character, a multiline string, a comment or markup text: `->` becomes `→`, `<-` `←`, `/=`
`≠`, `<=` `≤`, `>=` `≥`, `|>` `▷`, `<|` `◁`, `...` `…`, a `*` typed where a type is expected `×`,
and `\` `λ` (§12.1). Lean's editors use backslash abbreviations (`\to`, `\le`, `\x`); beni's do
not, because a typed `\` is already `λ`. An undo after a replacement restores the ASCII, so `x <`
`-1` can still be typed (and is then refused, with the message to write `x < -1`).

**The order of work** is §12's for `λ`: **teach** (the lexer reads the symbols and `×`, the
parser accepts both spellings, the lookalikes are refused, columns count code points, `beni fmt
--migrate-unicode` exists), **migrate** (one mechanical commit: the flag over every `.beni` file,
then plain `beni fmt` over the gate's scope for any tuple type it joined past 100 columns; core's
doc comments, the normative examples in `docs/design/`, Zig test programs and generators rewritten
alongside, by a reviewed script, because the flag does not touch comments), **enforce**
(`ascii_symbol_removed`, `tuple_type_removed`, the type renderer and every compiler message that
quotes code switch to the symbols). `plans/syntax-batch.md` slices 18–20.

### 12.10 `⊤` and `⊥`: the trivial and the empty type, and `if` without `else`

*Specified 2026-10-02; built the same day* (the owner's decision S10,
[`plans/browser-decisions.md`](../../plans/browser-decisions.md)). **`⊤` is the unit type and its one
value**, written the same in both roles — `log : String → ⊤`, `else ⊤`, `λ⊤ → e`, `key ⊤` — and
replacing `()` in both, so a parenthesis means only grouping or a tuple. **`⊥` is the type with no
values**, today's `Never`. **An `if` may leave out its `else` when its `then` branch is `⊤`**, the
missing branch being `⊤`. And every `_ = e` whose `e` is `⊤` becomes a plain statement line (§12.2).
The order of work is §12's: teach, migrate, enforce (§12.9's last row), as
[`plans/syntax-batch.md`](../../plans/syntax-batch.md) slices 21–24 give, with the choices the owner
should confirm in its §1.4, T1–T16. [`frontend.md`](frontend.md) §11.9 says how the lexer, parser,
formatter and `beni fmt --migrate-top` build it; [`checker-v2.md`](checker-v2.md) §34 what the
checker adds.

**What does not change.** `⊤` is the unit `()` was, and `⊥` names the type `Basics` declares as
`Never`: the BIR of a program is the same in either spelling, the checker sees the same types, and
every byte the backend emits is the same — **a `⊤` is `null` at run time** (`backend.md` §4, *a
`()` is `null` or `undefined`*, unchanged). A parameter of type `⊤` still compiles to a
zero-parameter JavaScript function (`backend.md` §6), a `⊤` result is still not written, and no
pattern tests a `⊤`.

| Symbol | Code point | UTF-8 | Replaces | Token tag | Where it may stand |
|---|---|---|---|---|---|
| `⊤` | U+22A4 DOWN TACK | `E2 8A A4` | `()` in a type, an expression and a pattern | `top` | a type atom (§3 `TypeAtom`), an expression atom (`Atom`, so an argument: `key ⊤`, `f ⊤`), a pattern atom (`λ⊤ → e`, `case u of ⊤ → …`) |
| `⊥` | U+22A5 UP TACK | `E2 8A A5` | `Never` | `bottom` | a type atom only |

**Grammar** (§3's notation; amendments, nothing renumbered):

```
TypeAtom    := … | '⊤' | '⊥'                                     -- '(' ')' until the enforce step
Atom        := … | '⊤'                                           -- '(' ')' until the enforce step
PatternAtom := … | '⊤'
Expr        := 'if' Expr 'then' Body ('else' Body)?              -- §12.2's line, the else optional
```

| Rule | Detail |
|---|---|
| **the lexer** | `⊤` and `⊥` are two more of §12.7's non-ASCII tokens, recognised wherever code is lexed (a markup hole, an interpolation hole, an attribute's `{…}` value and a `where` clause included) and never inside a string, a character, a multiline string, a comment or markup text. Neither is ever part of an identifier: `f⊤` is `f` then `⊤`, and the formatter writes `f ⊤` |
| **`⊤` is one token in three roles** | as `()` was: what it is follows from where it stands — a type in a type, the unit value in an expression, the unit pattern in a pattern. `⊤` is irrefutable, so it may be a parameter (`λ⊤ → e`, `run ⊤ = …`). `(⊤)` is a grouping of `⊤` |
| **`⊥` is a type only** | in an expression or a pattern it is `unexpected_token`, construct `bottom_outside_type`, whose message says `⊥` is a type with no values and that a value of it is used through `never` (`never v : a`) |
| **`⊥` is core's empty type, always** | it names the type `Basics` declares, in every module, whatever the module declares or imports under the name `Never`: it cannot be shadowed, as `⊤` cannot. `Basics` keeps declaring the type as `type Never = JustOneMore ⊥` — a declaration needs an upper identifier — and from the enforce step that name is written only inside `Basics`. `never : ⊥ → a` keeps its name |
| **`T`, the lookalike** | a capital `T` is the one ASCII character a reader may take for `⊤`. The lexer cannot refuse it — `T` is a legal type and constructor name, and a program may declare one — so the hint is resolution's: an **unbound** `T`, as a type (`unbound_type`) or as a constructor in an expression or a pattern (`unbound_constructor`), keeps its code and its message gains one sentence, *did you mean `⊤` (U+22A4 DOWN TACK), the unit type and its value?* A `T` the program declares or imports is that declaration, as any name is: it is never read as `⊤`, and nothing is accepted silently |
| **lookalikes** | §12.7's *Lookalikes* gain five, each `invalid_character` with the symbol named and the parse going on as that symbol: `⟙` U+27D9 LARGE DOWN TACK, `⫟` U+2ADF SHORT DOWN TACK and `⊺` U+22BA INTERCALATE → `⊤`; `⟘` U+27D8 LARGE UP TACK and `⫠` U+2AE0 SHORT UP TACK → `⊥` |
| **`( )`** | the unit written with whitespace or a newline between its parentheses is the same `()` (§3 reads two tokens), and is migrated and refused exactly as `()` is. One with a comment between its parentheses is refused the same way; the flag leaves its file alone and names it, for a hand edit |
| **markup** | `()` in markup text or a quoted attribute value is text, which no rule here reaches. In a markup hole or a `{…}` attribute value it is code, and is `⊤` like any other |
| **the type renderer** | from the enforce step, prints `⊤` for the unit type and `⊥` for `Basics`' empty type, so a diagnostic, `dump --stage=types` and `--stage=interface` show what the program must write. Neither is ever parenthesised. A type's run-time identity (`checker-v2.md` §33) is a key, not source, and keeps `()` |
| **`Debug.toString`** | from the enforce step, writes the unit value as `⊤` (Appendix B), as beni source writes it: `Mark ⊤` |
| **typing it** | §12.9's editor rule: the language server turns a `()` typed in code into `⊤`, and offers `⊥` where `Never` is typed in a type; no backslash abbreviation |

**`if` without `else`.**

| Rule | Detail |
|---|---|
| **where it parses** | anywhere an `if` may stand (§3's `TailForm`): a statement line, a block's last line, a branch's or a lambda's body, an operand, an argument in parentheses. It is a whole `if c then body` with no `else` after its body: an `if` whose body ends — at the end of its block (§12.2 B4), at a closing bracket, a comma, `of`, or the end of the file — without an `else` has none. A body that is a block keeps §12.2's layout, so the form most programs write is `if c then` / a block / the next item at the `if`'s column |
| **which `if` an `else` belongs to** | the nearest `if` before it that has no `else` and whose block the `else` is inside. **Layout decides first**: an `else` at a column left of a block's column ends that block (B4), so an `if` inside the block cannot take it — `if a then` / `    if b then` / `        x` / `else` / `    y` gives the `else` to the outer `if`, as it reads. **On one line** the nearest `if` takes it, as in OCaml, F#, Rust and Scala: `if a then if b then x else y` is `if a then (if b then x else y)`; the other reading is written with its parentheses, which the formatter keeps |
| **its type** | **the `then` branch must be `⊤`**, and the whole `if` is `⊤` — the missing branch is the value `⊤`. Its condition is `Bool`, as always. A `then` branch of any other type is **`if_without_else_not_unit`** (title MISSING ELSE, `checker-v2.md` §34), at the `then` branch, whose message names the branch's type and says to write the `else` that gives the `if` its value when the condition is false. The `if` is checked against what its context wants like any `⊤`: in `n = if c then f x` / `n + 1` the branch is reported, and `n + 1` is an ordinary mismatch of `⊤` against a number |
| **why only `⊤`** | an `if` producing any other type has no value to give when its condition is false; inventing one (a default, a `Maybe`) would be the silent wrong answer rule 7 forbids, and OCaml, F#, Rust and Scala all require the missing branch's type to be their unit. `if c then a else ⊤` stays legal; the migration writes it without its `else` |
| **lowering** | the missing branch is the value `⊤`, so `if c then a` lowers to the `case` that `if c then a else ⊤` lowers to (§8), its `False` branch the unit instruction, and the emitted JavaScript of the two spellings is byte-identical |
| **evaluation** | the condition, then the `then` branch when it is `True`; nothing when it is `False` |
| **the formatter** | an `if` without `else` is printed as an `if` with one is, without the `else` half: on one line only when the author wrote it on one line and it fits (§12.5, Y14), otherwise `if c then` and the body indented 4 below. The formatter never adds or removes an `else` |

**`_ = e` where `e` is `⊤`.** A statement line already requires `⊤` (§12.2), so `_ =` in front of a
`⊤` says nothing the line does not. From the enforce step it is the warning **`unit_discarded`**
(title UNIT DISCARDED, `checker-v2.md` §34), at the `_ =`, for the root package's modules only, as
`suspicious_argument_order` is: *this `_ =` throws away a `⊤`, which a statement line does
already*. A warning and not an error, because the line is redundant, not wrong (rule 7). Until
the enforce step it is emitted only under `--explain`, which is how the migration finds the lines
(`frontend.md` §11.9). `_ = e` for any other type is §12.2's explicit discard and is untouched.

**The removed spellings.** From the enforce step:

| Code | Title | At | Message |
|---|---|---|---|
| **`unit_spelling_removed`** | REMOVED UNIT SPELLING | the `(` of every `()` (or `( )`) in a type, an expression or a pattern — the parser's | `()` is written `⊤` (U+22A4 DOWN TACK), as the type and as its value; the flag `beni fmt --migrate-top`. The parse goes on as `⊤`, so one stale spelling costs one message |
| **`never_spelling_removed`** | REMOVED NEVER SPELLING | a type name `Never` that names `Basics`' empty type — through the prelude, an `exposing` list or `Basics.Never` — in any module but `Basics` — lowering's | `Never` is written `⊥` (U+22A5 UP TACK); the flag. Resolution goes on to the same type. A module's own `type Never`, and a `Never` imported from a module other than `Basics`, are other types and are untouched |

The prelude's exposed types keep `Never` (Appendix A), so that a stale `Never` gets the removal
diagnostic rather than `unbound_type`.

**The migration**, `beni fmt --migrate-top` (`frontend.md` §11.9), is an edit in §12.9's family —
it keeps the file's layout and reaches its fixed point in one run: `()` → `⊤` in every type,
expression and pattern; `Never` → `⊥` where the file neither declares nor imports a `Never` of its
own; `else ⊤` dropped from an `if` whose `else` branch is exactly the unit atom, unless an `else`
follows it (the `if` then ends the `then` branch of an outer `if`, and dropping it would hand the
outer `else` to the inner one); and, given the warnings of a `check --explain --diagnostics=json` run as
`--discards=<file>`, `_ = ` deleted in front of each `unit_discarded` line. Dropping `else ⊤` is
always type-safe: the two branches were unified, so the `then` branch is already `⊤`.

## Appendix A. The prelude

These names are in scope in every module without an import. The table is a constant inside the
compiler, never read from another module at resolution time, which keeps per-file name resolution
independent of every other file. The set is Elm's default imports minus the effect-system modules
(`Platform`, `Cmd`, `Sub` — open, see `fast-compiler.md` §3.1) and minus `Tuple` (§0); operators are
syntax (§6.5) and are never imported or exposed. *Amended 2026-10-01 (§12.7):* so the Unicode
spellings of the operators change nothing here.

Module aliases usable in qualified names: `Basics`, `List`, `Maybe`, `Result`, `String`, `Char`,
`Debug`. Exposed types: `Int Float Bool Char String List Maybe Result Order Never`. Exposed
constructors: `True False Just Nothing Ok Err LT EQ GT`. Exposed values (all from `Basics`):

```
toFloat round floor ceiling truncate max min compare not xor modBy remainderBy negate abs
clamp sqrt logBase e pi cos sin tan acos asin atan atan2 degrees radians turns toPolar
fromPolar isNaN isInfinite identity always never
```

*Amended 2026-10-02 (§12.4; specified, not built).* `modBy`, `remainderBy` and `logBase` leave the
exposed values, and a use of one is `name_removed`; nothing unqualified replaces them. `Int` and
`Float` join the module aliases, so `Int.mod n 2`, `Int.rem n 3` and `Float.log x 10` need no
import. The exposed types do not change. *Amended 2026-10-01:* the modules `Int` and `Float` do not
declare those two types, which stay in `Basics` (§12.4); they are ordinary core modules holding
`mod` and `rem`, and `log`. *Amended 2026-10-02 (§12.10; built the same day):* the empty type
is written `⊥`, which names `Basics`' type wherever it stands; `Never` stays among the exposed
types only so that a stale use is `never_spelling_removed` rather than `unbound_type`. Unlike `Int32` below, they are not an escape hatch beside the language
everyone writes but the home of three prelude values, which is why they keep a prelude row: an
edge to either exists only in a module that writes `Int.` or `Float.` (the conditional prelude edge,
static-dispatch-spike.md §5.1).

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

## Appendix B. What `Debug.toString` prints

*Added 2026-10-02* (the owner's report that a tuple printed as a record and a `Bool` as `true`;
`backend.md` §4, *`Debug.toString` reads the argument's type*, and `checker-v2.md` §32 say how).
`Debug.toString` — and `Debug.log`, which prints `label: ` and the same text — writes a value **as
beni source writes it**, as Elm's writes Elm, with Elm's spacing:

| value | prints |
|---|---|
| `Bool` | `True`, `False` |
| `Int` | `42`, `-3` |
| `Float` | `1.5`, `1.0` (a whole number keeps its point, as `String.fromFloat` writes it), `-0.0`, `NaN`, `Infinity`, `-Infinity` |
| `Char` | `'a'`, `'\''`, `'\n'` |
| `String` | `"a b"`, with `\"`, `\\`, `\n`, `\r`, `\t`, `\${` and `\u{…}` for any other control character — §2's escapes, so the text is a literal that reads back as the value |
| `()` | `()` |
| tuple | `(1,"x")`, `(1,'c',False)` |
| list | `[1,2,3]`, `[]` |
| record | `{ a = 1, b = "x" }`, `{}` |
| constructor | `Nothing`, `Just 1`, `Labeled "a b" (Circle 1.5)`: an argument in parentheses when it is more than one word or begins with `-` — `Just (-1)`, `Rect (-1) 2` — as source must write it; `Mark ()` keeps its `()` |
| `Dict` | `Dict.fromList [(1,"a"),(2,"b")]`, in key order |
| `Set` | `Set.fromList ['a','b']` |
| function | `<function>` |
| `foreign type` | `<internals>` |

*Amended 2026-10-02 (§12.10; built the same day):* from the enforce step the unit value prints
`⊤`, and `Mark ()` prints `Mark ⊤`, as source writes them.

An opaque type prints its constructor, as Elm's does: `Debug` is for the developer who can read
the module anyway. The exact text is not a promise (the module's own doc says so), but it is
pinned by `run/DebugToStringShapes`, `run/DebugLogShapes` and `run/DebugToStringModules`.

**Printing is directed by the type at the call.** The representation alone cannot tell a tuple
from a record whose fields are `a` and `b`, a `Char` from a `String`, an all-nullary
constructor from a string, or a `()` argument from padding, so the compiler hands the printer the
type the checker solved at each `Debug.toString` and `Debug.log`, in a call or passed as a value.
**Under a type variable** — `describe v = Debug.toString v`, with `describe : a → String` — nothing is
known at the call, the type is not passed through `describe`'s callers (that would make every
polymorphic function that logs grow a hidden parameter, or a `where` clause, for a development
aid), and the value is read by its representation: a `Bool` is still `True`, a number prints as
an `Int` would, a constructor with a tag prints with its arguments, but a tuple prints as the
record `{ a = 1, b = 2 }`, a `Char` as a one-character `String`, an all-nullary constructor as a
quoted string, and a `()` argument is dropped with the padding. The positions a type leaves open
— `List a`'s elements — are read the same way while the rest of the value prints by its type.
