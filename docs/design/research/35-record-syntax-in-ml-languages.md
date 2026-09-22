# 35 — Record type declarations in ML-family and layout-sensitive languages

Research, 2026-09-22. This is evidence for a syntax question the owner raised
about record and `schema` declarations; it is not a specification, it changes
no normative document and it recommends nothing. Where it sketches beni
syntax (§5) the sketches are marked **`[sketch]`** and every one of them is
invalid under [`language.md`](../language.md) today. Every beni sample that is
not so marked is valid under `language.md` §3–§4 and
[`schema.md`](../schema.md) §2 at `1e64248`.

Method: five read-only research passes, each over primary sources — official
language references, formatter documentation, compiler source, issue
trackers, the Roc Zulip and the Elm mailing lists — with the instruction to
say "not found" rather than guess. Quotations are copied from the cited page
or file. Chat and forum quotations are people thinking aloud, not
documentation, and are labelled as such. Every claim carries its URL; §7 is
the index.

---

## 1. The question

The owner, 2026-09-22, on the current spelling of a record type:

```elm
type alias User =
    { name : String
    , age : Int
    }
```

> "We are a space-sensitive language, I think we should use that to our
> advantage."

The question this report answers with evidence is therefore: **is a
layout-based record declaration — indentation, no braces, no commas — viable
for a beni `type alias` record and for the `schema` declaration of
`schema.md` §2, and what does it cost?** The schema case matters because its
fields carry postfix modifiers (`userId : Int as "user-id"`,
`nickname : String optional nullable`), inline nested records and tagged
variants, which is exactly where a layout rule has to decide where a field
ends.

The short version of what the evidence says, stated as findings and not as a
verdict:

1. **Every language surveyed that spells a record type in layout — Lean 4,
   Idris 2, Agda, Nim, Python, Koka — has only nominal records.** None of
   them lets an anonymous record *type* appear inline where a type is
   expected; the one language with anonymous records and an offside rule,
   F#, spells them in braces (`{| … |}`). beni's records are structural and
   appear inline in annotations, so a layout form there would be a second
   spelling beside braces, not a replacement (§3, §5).
2. **The rule that ends a layout field is the same everywhere: the next
   token at the field column starts the next field, and a type that spans
   lines must be indented past that column.** Lean enforces it with
   `checkColGt` on every application argument; Idris with a terminator set
   plus `col <= indent`; Agda's lexer with virtual `;`/`}`; Nim with
   `IND{=}`; F# with an inserted `$sep`. beni's `let`-binding list already
   implements this exact mechanism (`language.md` §4 rule 3) (§3).
3. **Elm's leading comma has one official rationale — diffs — and Evan
   declined to defend it further.** The style guide's sentence is the whole
   argument; Evan said in 2015 he did not want Elm "in the business of
   making people go that route" and preferred trailing commas, which he then
   never shipped. Richard Feldman proposed newline-delimited records in 2015
   (elm/compiler #979); the objection that killed it concerned *value*
   literals (`( 3 4 5 )` reads as application), not type declarations (§4).
4. **Error recovery is where the layout languages diverge most.** F#
   recovers per field with an error-typed `SynField`; Scala 3 skips to the
   next statement separator; Nim abandons the rest of the object body and
   reports "invalid indentation" as a catch-all (open since 2020); Idris and
   Agda abort the whole parse. beni's parser already recovers to the next
   sibling comma in a schema record (`src/parse/Parse.zig:861–889`); a layout
   body would recover to the next token at the field column instead (§3, §5).
5. **No official formatter exists for Lean 4, Idris 2 or Agda**, and the
   formatter fights on record (Fantomas, nph, scalafmt, the Scala 3
   `-rewrite -indent`) are all one fight: a formatter that moves a bracket
   whose position is semantic under the offside rule. beni's rule 6 —
   brackets do not suspend layout, and do not set a column — is the property
   that avoids the F# class of defect (§3.6, §5).
6. **Practitioners who shipped code split on layout along one axis: whether
   the formatter can still rescue them.** The strongest reports against
   (Scala, Nim) name copy-paste and merge resolution; the strongest for point
   to an opinionated formatter making it moot — including an Elm user saying
   exactly that about elm-format (§6).

---

## 2. The table

Verbatim declaration examples are from the language's own reference (link in
the last column). "Layout?" says whether the *language* is
indentation-sensitive; "Record body" says what actually delimits the *record
fields*. "Nested" is whether an anonymous record type may be written inline
where a type is expected.

| Language | Layout? | Record type declaration (verbatim) | Record body | Nested inline record type | Formatter convention | Source |
|---|---|---|---|---|---|---|
| **Lean 4** | yes (`withPosition`/`colGt`) | `structure Point where`<br>`  x : Float`<br>`  y : Float` | indent; no braces, no separators; `:= default` postfix | **no** — `declId` required; use `×`/`Σ` | none official (#1488 open since 2022) | [FPIL](https://lean-lang.org/functional_programming_in_lean/Getting-to-Know-Lean/Structures/), [Command.lean](https://raw.githubusercontent.com/leanprover/lean4/master/src/Lean/Parser/Command.lean) |
| **Idris 2** | yes | `record Person where`<br>`    constructor MkPerson`<br>`    firstName, middleName, lastName : String`<br>`    age : Int` | indent, or explicit `{ }`; modifiers are *prefix* `{auto x : T}` | **no** | none official | [tutorial](https://idris2.readthedocs.io/en/latest/tutorial/typesfuns.html), [Parser.idr](https://raw.githubusercontent.com/idris-lang/Idris2/main/src/Idris/Parser.idr) |
| **Agda** | yes, mandatory ("you cannot use explicit `{`, `}` and `;`") | `record Pair (A B : Set) : Set where`<br>`  field`<br>`    fst : A`<br>`    snd : B` | `field` is a layout keyword; virtual `;`/`}` | **no** | none official | [record-types](https://agda.readthedocs.io/en/latest/language/record-types.html), [lexical-structure](https://agda.readthedocs.io/en/latest/language/lexical-structure.html) |
| **F#** | yes (light syntax) | `type Customer =`<br>`    { First: string`<br>`      Last: string`<br>`      SSN: uint32 }` | `{ }` required; `;` or newline at the offside column | **yes**, `{| Name: string |}` | Fantomas: `Cramped` (historic default), `Aligned`, `Stroustrup` | [Records](https://learn.microsoft.com/en-us/dotnet/fsharp/language-reference/records), [Lexical Filtering](https://github.com/fsharp/fslang-spec/blob/main/spec/lexical-filtering.md) |
| **Nim** | yes | `type`<br>`  Person = object of RootObj`<br>`    name*: string`<br>`    age: int` | indent (`IND{>} … IND{=} … DED`); `##` doc after field | tuples yes (`tuple[…]`), objects **no** | nph (community; AST-equivalence checked) | [manual](https://nim-lang.org/docs/manual.html#types-tuples-and-object-types), [grammar.txt](https://nim-lang.org/docs/grammar.txt) |
| **Python** | yes | `@dataclass`<br>`class InventoryItem:`<br>`    name: str`<br>`    unit_price: float`<br>`    quantity_on_hand: int = 0` | indent; fields are annotated statements | **no** (TypedDict functional form only) | Black; never changes indentation structure | [PEP 557](https://peps.python.org/pep-0557/), [PEP 589](https://peps.python.org/pep-0589/) |
| **Koka** | yes (token-pass brace/semicolon insertion) | `struct person`<br>`  age : int`<br>`  name : string`<br>`  realname : string = name` | indent **or** `struct person{ age : int; name : string }` — both official, layout desugars to braces | **no** (`struct` named) | — | [tour](https://koka-lang.github.io/koka/doc/book.html), [spec §Layout](https://koka-lang.github.io/koka/doc/book.html#sec-layout) |
| **Scala 3** | optional braces | `case class Person(name: String, relation: String)` | class *body* may be `:`+indent; parameter list keeps `( )` and `,` | structural refinement `Record { val name: String }` | scalafmt `rewrite.scala3.optionalBraces` | [indentation](https://docs.scala-lang.org/scala3/reference/other-new-features/indentation.html), [syntax](https://docs.scala-lang.org/scala3/reference/syntax.html) |
| **Elm** | yes | `type alias User =`<br>`    { name : String`<br>`    , age : Int`<br>`    }` | `{ }` and `,` required; no trailing comma | **yes**, structural, anywhere | elm-format: leading commas, per the style guide | [style guide](https://elm-lang.org/docs/style-guide), [guide](https://guide.elm-lang.org/types/type_aliases.html) |
| **Haskell** | yes (`let where do of` only) | `data Person = Person`<br>`    { firstName :: !String`<br>`    , lastName  :: !String`<br>`    } deriving (Eq, Show)` | `{ }` and `,` are terminals of `constr`; layout never applies | no anonymous records in GHC Haskell | Ormolu trailing; Fourmolu `comma-style: leading` default | [Report §2.7](https://www.haskell.org/onlinereport/haskell2010/haskellch2.html#x7-210002.7), [Tibell](https://github.com/tibbe/haskell-style-guide/blob/master/haskell-style.md) |
| **PureScript** | yes | `type User = { name :: String, age :: Int }` (sugar for `Record ( … )`) | `{ }`, `,` | **yes**, row types | purs-tidy: leading commas, no option | [Records.md](https://github.com/purescript/documentation/blob/master/language/Records.md), [purs-tidy](https://github.com/natefaubion/purescript-tidy) |
| **Roc** (Zig compiler) | mostly no since 2025 (brace blocks) | `Person : { name : Str, age : U64 }`<br>`Point := { x : F64, y : F64 }` | `{ }`, `,`; `?:` optional, `?? 3` default (nominal only) | **yes**, structural, anywhere | trailing comma is the only layout bit; never line-length | [records.md](https://raw.githubusercontent.com/roc-lang/roc/records-langref/docs/langref/records.md), [fmt.zig](https://raw.githubusercontent.com/roc-lang/roc/main/src/fmt/fmt.zig) |
| **Gleam** | no | `pub type Person {`<br>`  Person(name: String, age: Int, needs_glasses: Bool)`<br>`}` | `{ }` around variants, `( )`+`,` around fields | **no**; records are constructors | trailing comma forces multi-line | [tour](https://tour.gleam.run/data-types/records/) |
| **Unison** | yes (blocks) | `type Song = {title : Text, artist : Text, year : Nat}` | `{ }`, `,` | no | — | [record-type](https://www.unison-lang.org/docs/language-reference/record-type/) |
| **Grain** | not stated | `record Person { name: String, age: Number }` | `{ }`, `,` | no | trailing comma when broken | [data types](https://grain-lang.org/docs/guide/data_types) |
| **Futhark** | no | `type person = {name: []u8, age: i32}` | `{ }`, `,`, trailing `,` permitted | yes, structural (tuples are records) | — | [reference](https://futhark.readthedocs.io/en/latest/language-reference.html) |
| **OCaml** | no | `type user = { name : string; age : int }` | `{ }`, `;`, trailing `;` optional | inline records in constructors only | ocamlformat `break-separators=after` | [typedecl](https://ocaml.org/manual/latest/typedecl.html), [inline records](https://ocaml.org/manual/latest/inlinerecords.html) |
| **ReScript / Reason** | no | `type person = {`<br>`  age: int,`<br>`  name: string,`<br>`}` | `{ }`, `,`; `name?: string` optional | nested records need a declared type | `rescript format`, non-configurable | [record](https://rescript-lang.org/docs/manual/record) |
| **Standard ML** | no | `type person = {name : string, age : int}` (`{ ⟨tyrow⟩ }`) | `{ }`, `,` | yes, structural | none | [Definition](https://smlfamily.github.io/sml97-defn.pdf) |
| **Rust** | no | `struct Point {x: i32, y: i32}` | `{ }`, `,`, trailing `,` optional | no | rustfmt: one field per line, trailing comma | [structs](https://doc.rust-lang.org/reference/items/structs.html), [style](https://doc.rust-lang.org/nightly/style-guide/items.html) |
| **Kotlin** | no | `data class User(val name: String, val age: Int)` | `( )`, `,` | no | — | [data classes](https://kotlinlang.org/docs/data-classes.html) |
| **Swift** | no | `struct Resolution {`<br>`    var width = 0`<br>`    var height = 0`<br>`}` | `{ }`; newline or `;` | no | — | [structures](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures/) |
| **Gren** | yes | as Elm; head changing to `Named : { name : String }` | `{ }`, `,`; "Trailing commas are not allowed in record types" | yes | Elm's | [book](https://gren-lang.org/book/syntax/records/), [news](https://gren-lang.org/news/240819_upcoming_language_changes/) |
| **Derw** | no | `type alias Person = { name: string, age: number }` | `{ }`, `,` | yes | — | [features](https://github.com/eeue56/derw/blob/main/LANGUAGE_FEATURES.md) |
| **Mint** | no | `type User {`<br>`  email : String,`<br>`  name : String`<br>`}` | `{ }`, `,`, no trailing | no | — | [guide](https://github.com/mint-lang/guide/blob/master/reference/records.md), [0.20.0](https://github.com/mint-lang/mint/releases) |

Two patterns fall out of the table. The layout column and the nested column
are inverses: every "layout, no braces" row is a "no inline record type" row,
and every structural-records row (Elm, PureScript, Roc, Futhark, SML) keeps
braces. And of the two languages that offer *both* spellings, Koka defines
the layout form by desugaring to the brace form ("desugars to:
`type person / Person{ age : int; name : string; realname : string = name }`",
[tour](https://raw.githubusercontent.com/koka-lang/koka/dev/doc/spec/tour.kk.md)),
and Idris accepts explicit braces around a `where` block ("unless the block
is explicitly delimited by curly braces",
[Source.idr](https://raw.githubusercontent.com/idris-lang/Idris2/main/src/Parser/Rule/Source.idr)).

---

## 3. Layout-based record declarations, examined closely

### 3.1 Lean 4 — `structure … where`

**The rule that ends a field.** Lean has no layout pre-pass; it saves a
column and checks against it. The field list is
`manyIndent`, defined as `withPosition $ many (checkColGe "irrelevant" >> p)`
— "each subsequent `p` parse needs to be indented the same or more than the
first parse"
([Extra.lean](https://raw.githubusercontent.com/leanprover/lean4/master/src/Lean/Parser/Extra.lean)).
What stops the *previous* field's type from swallowing the next field name is
in the term grammar, not the structure grammar:

```lean
def argument :=
  checkWsBefore "expected space" >>
  checkColGt "expected to be indented" >>
  (namedArgument <|> ellipsis <|> termParser argPrec)
```
([Term.lean](https://raw.githubusercontent.com/leanprover/lean4/master/src/Lean/Parser/Term.lean)).
`checkColGt` "requires that the next token starts a strictly greater column
than the saved position"
([Basic.lean](https://raw.githubusercontent.com/leanprover/lean4/master/src/Lean/Parser/Basic.lean)),
so in `x : Float` / `y : Float` the `y` at the field column cannot be an
argument of `Float`. A type continued on the next line must therefore be
indented past the field column. Postfix material is settled by tokens:
`:= default` cannot begin an argument, and `deriving` is a keyword, so
`structSimpleBinder`'s `ident` fails and `optDeriving` takes over. Inside
parentheses the column check is switched off: bracketed fields run under
`withoutPosition`, which "is usually used by bracketing constructs like
`(...)` so that the user can locally override whitespace sensitivity"
(Basic.lean). The same `colGt` rule bites in ordinary code: a `fun f ↦` whose
body starts on the next line at the wrong column gives
`unexpected token '('; expected command`
([lean4#8222](https://github.com/leanprover/lean4/issues/8222)).

**Nested records.** None. The grammar requires `declId`; "The product type
in Lean is a structure named `Prod`"
([reference](https://lean-lang.org/doc/reference/latest/The-Type-System/Inductive-Types/#structures)).

**Documentation and defaults.** Every field form begins with
`declModifiers true`, so `/-- … -/` sits on the line before a field
([mathlib4 docs](https://leanprover-community.github.io/mathlib4_docs/Lean/Parser/Command.html)).
"Structure fields may have default values, specified with `:=`", and
`extends` merges parents by C3 linearisation, with "a heuristic … used to
find an order nonetheless" when none exists (reference, above).

**Error recovery.** Command-level recovery skips to the next command keyword
and produces the notorious list-every-keyword message:
`unexpected token 'mutual'; expected '#guard_msgs', 'abbrev', 'add_decl_doc', 'axiom', 'binder_predicate'...`
([lean4#4156](https://github.com/leanprover/lean4/issues/4156)). Inside
declarations recovery is opt-in per production, and `structure` opts out —
the source comment reads "Note: no error recovery here due to clashing with
the `class abbrev` syntax"
([Command.lean](https://raw.githubusercontent.com/leanprover/lean4/master/src/Lean/Parser/Command.lean)).
A malformed field ends the structure's syntax tree there and the top-level
loop resumes at the next command. A verbatim malformed-*field* error from
Zulip or an issue was **not found**.

**Formatter.** None. #369 (2021) was closed as a duplicate of
[#1488](https://github.com/leanprover/lean4/issues/1488) "[RFC] Pretty
Printer / Code Formatting" (2022), still open; Henrik Böving on Zulip,
2022-09-17: "that is still quite a bit away from what it can do"
([archive](https://leanprover-community.github.io/archive/stream/113489-new-members/topic/Lean.20formatter.html)).
Community tools exist ([leanfmt](https://github.com/duckki/leanfmt),
[lean-fmt](https://github.com/lotusirous/lean-fmt), the latter "a workaround
until the official Lean formatter is ready").

**Complexity.** `Lean/Elab/Structure.lean` is roughly 1 700 lines; 4.19.0
added a `_flat_ctor` "in 'field normal form'"
([release notes](https://lean-lang.org/doc/reference/latest/releases/v4.19.0/)).
Most of that is inheritance and defaults, not layout.

### 3.2 Idris 2 — `record … where`

**The rule that ends a field**, from `src/Parser/Rule/Source.idr`:

```idris
||| Any token which indicates the end of a statement/block/expression
isTerminator : Token -> Bool
isTerminator (Symbol ",") = True
isTerminator (Symbol "]") = True
isTerminator (Symbol ";") = True
isTerminator (Symbol "}") = True
isTerminator (Symbol ")") = True
isTerminator (Symbol "|") = True
isTerminator (Symbol "**") = True
isTerminator (Keyword "in") = True
isTerminator (Keyword "then") = True
isTerminator (Keyword "else") = True
isTerminator (Keyword "where") = True
isTerminator InterpEnd = True
isTerminator EndInput = True
isTerminator _ = False

||| Check we're at the end of a block entry, given the start column
||| of the block.
||| It's the end if we have a terminating token, or the next token starts
||| in or before indent. Works by looking ahead but not consuming.
atEnd : (indent : IndentInfo) -> EmptyRule ()
```
([Source.idr](https://raw.githubusercontent.com/idris-lang/Idris2/main/src/Parser/Rule/Source.idr)).
The record parser calls `fieldBody` then `atEnd indents` for each field
([Parser.idr](https://raw.githubusercontent.com/idris-lang/Idris2/main/src/Idris/Parser.idr)).
Modifiers are *prefix* and bracketed — `{auto x : T}`, `{default e x : T}` —
so no postfix word can be mistaken for a field. Because `where` is itself a
terminator, a line-initial `where` ends the preceding declaration; issue #234
records the result for `data Bool' : Type` / `where` on the next line:
`Parse error: Couldn't parse declaration (next tokens: [where, identifier True', symbol :, …])`,
labelled "expected behaviour"
([Idris2#234](https://github.com/idris-lang/Idris2/issues/234)).

**Nested records.** None; users ask for them
([idris-lang list](https://groups.google.com/g/idris-lang/c/Q8E4_6Ui5Ms)).

**Documentation.** `|||` on the line before a field or the constructor
([documenting](https://idris2.readthedocs.io/en/latest/reference/documenting.html)).

**Error recovery.** `topDecl`'s last alternative is
`fatalError "Couldn't parse declaration"`; the message appends the lookahead
tokens and the parse stops. #504 is labelled "wontfix" / "error: bad message"
([Idris2#504](https://github.com/idris-lang/Idris2/issues/504)). The
tracking issue #3369 "Parsing Performance & Maintainability" opens: "one of
the weaknesses of the compiler is it's most common interaction model: the
parser", listing "inconsistent error recovery" and "unexpected whitespace
handling"
([Idris2#3369](https://github.com/idris-lang/Idris2/issues/3369)).

**Formatter.** None official; one community tool
([idrisfmt](https://github.com/idris-industry/idrisfmt)).

### 3.3 Agda — `record … where field …`

**The rule.** "Agda is layout sensitive using similar rules as Haskell, with
the exception that layout is mandatory: you cannot use explicit `{`, `}` and
`;` to avoid it." `field` and `constructor` are layout keywords; "The first
token after the layout keyword decides the indentation of the block. Any
token indented more than this is part of the previous statement, a token at
the same level starts a new statement, and a token indented less lies outside
the block."
([lexical-structure](https://agda.readthedocs.io/en/latest/language/lexical-structure.html)).
The lexer's `offsideRule` returns virtual close-brace / semicolon / nothing
for left-of / at / right-of column, and since 2.6.2 columns are "`Tentative`
or `Confirmed`" so that "block starters can be stacked on the same line"
([Layout module](https://agda.github.io/agda/Agda-Syntax-Parser-Layout.html),
[changelog](https://hackage.haskell.org/package/Agda-2.6.2/changelog)) —
stacking `constructor c; field` on one line had regressed
([agda#5236](https://github.com/agda/agda/issues/5236)).

**Nested records.** None; the record body is more than a field list — "fields
can be given in more than one block, interspersed with other declarations",
with the constraint that interleaved definitions must be expressible in the
constructor's type
([record-types](https://agda.readthedocs.io/en/latest/language/record-types.html)),
which is what makes an infix definition before `field` fail with "Could not
parse the left-hand side" ([agda#917](https://github.com/agda/agda/issues/917)).

**Documentation, defaults.** None and none. Docstrings are an open Icebox
issue ([agda#5541](https://github.com/agda/agda/issues/5541)).

**Error recovery.** "All errors produced during parsing are necessarily
fatal."
([ParserErrors wiki](https://wiki.portal.chalmers.se/agda/pmwiki.php?n=AIMXXIV.ParserErrors)).
An empty `field` block was `Parse error field<ERROR>` until 2.6.1
([agda#3803](https://github.com/agda/agda/issues/3803)).

**Formatter.** None found.

### 3.4 F# — braces under the offside rule

F# is the one language in the survey with braces *and* a layout rule that
applies inside them, and it is the one with a decade of record-layout
defects. The spec: a `{` pushes a `Paren` context and then a `SeqBlock` whose
column is "the first token following the significant token"; "When a token
occurs directly on the offside line of a _SeqBlock_ on the second or
subsequent lines of the block, the `$sep` token is inserted. This token plays
the same role as `;` in the grammar rules."
([Lexical Filtering](https://github.com/fsharp/fslang-spec/blob/main/spec/lexical-filtering.md)).
The parser's `seps` accepts `OBLOCKSEP | SEMICOLON | OBLOCKSEP SEMICOLON | SEMICOLON OBLOCKSEP`
([pars.fsy](https://github.com/dotnet/fsharp/blob/main/src/Compiler/pars.fsy)),
which is why "When each label is on a separate line, the semicolon is
optional"
([Records](https://learn.microsoft.com/en-us/dotnet/fsharp/language-reference/records)).

**The defect class.** Because `{` sets a column at *the first token after
it*, the legality of a nested record depends on the length of the enclosing
field name. fslang-suggestions #130 (2016): `let bar = { F = { Foo = 10 } }`
compiles, `let baz = { VeryLongName = { Foo = 10 } }` warns
`FS0058: Possible incorrect indentation: this token is offside of context started at position (10:20)`;
the reporter: the rules "seem inconsistent, or at least counter-intuitive"
([#130](https://github.com/fsharp/fslang-suggestions/issues/130)). The same
shape warned for anonymous records but not named ones, "only … in the
presence of function application"
([dotnet/fsharp#10552](https://github.com/dotnet/fsharp/issues/10552)).
Fantomas itself emitted offside code
([fantomas#536](https://github.com/fsprojects/fantomas/issues/536),
[#1341](https://github.com/fsprojects/fantomas/issues/1341)). The fix was
F# 6's RFC FS-1108, which opens "Prior to this RFC, the F# indentation rules
are very inconsistent" and rules that the left bracket of nine bracket pairs
"will not impose an additional indentation limit to the following line"
([FS-1108](https://github.com/fsharp/fslang-design/blob/main/FSharp-6.0/FS-1108-undentation-frenzy.md)).

**Error recovery is per field**, and the grammar says so:

```
fieldDecl:
  | opt_mutable opt_access ident COLON typ
  | opt_mutable opt_access ident COLON recover   // type := SynType.FromParseError
  | opt_mutable opt_access ident recover
  | opt_mutable opt_access recover
```
(pars.fsy). A real message: `let x : {||} = {||};;` gives
`error FS0010: Unexpected symbol '|}' in field declaration. Expected identifier or other token.`
([dotnet/fsharp#6941](https://github.com/dotnet/fsharp/issues/6941)).

**Formatter.** Fantomas' `fsharp_multiline_bracket_style` is `Cramped` /
`Aligned` / `Stroustrup`
([Configuration](https://fsprojects.github.io/fantomas/docs/end-users/Configuration.html));
the style guide admits "The `Cramped` style has been the default style for F#
code, as it tends to favor styles that allow the compiler to easily parse
code", and that Stroustrup needs a `with` keyword before members "due to
compiler rules"
([formatting](https://learn.microsoft.com/en-us/dotnet/fsharp/style-guide/formatting)).

### 3.5 Nim — `type X = object` with indented fields

**The rule.** "The lexer annotates the following token with the preceding
number of spaces; indentation is not a separate token. This trick allows
parsing of Nim with only 1 token of lookahead." `IND{>}` pushes, `IND{=}`
starts a sibling, `DED` pops
([manual](https://nim-lang.org/docs/manual.html#lexical-analysis-indentation)).
The grammar: `objectPart = IND{>} (COMMENT IND{=})? objectPart^+IND{=} DED / …declColonEquals (optPar COMMENT)?`,
with `declColonEquals = identWithPragma (comma identWithPragma)* comma? (':' optInd typeDescExpr)? ('=' optInd expr)?`
([grammar.txt](https://nim-lang.org/docs/grammar.txt)). `optInd = COMMENT? IND{>}?`
lets a type continue on a more-indented line, and every binary operator in
`simpleExpr` allows the same.

**Nested records.** `tuple[…]` yes; a bare `object` with a field body is
reachable only from a `type` section's right-hand side.

**Documentation.** `##` *after* the field is a grammar slot; rendering is
weak ([Nim#12353](https://github.com/nim-lang/Nim/issues/12353), open).

**Error recovery abandons the body.** `parseObjectPart` loops
`while sameInd(p)` and on any line at the field column that does not start
with an identifier does `parMessage(p, errIdentifierExpected, p.tok); break`
([parser.nim](https://github.com/nim-lang/Nim/blob/devel/compiler/parser.nim))
— the remaining fields are parsed as whatever follows the type section. The
quality problem is that "invalid indentation" is the fallback for unrelated
errors: `a = b = 10`, `var (k, v) = 1, 2` and `n++` all report it
([Nim#15667](https://github.com/nim-lang/Nim/issues/15667), open since 2020,
"seems to trip so many people"); a generic object with a pragma did too
([#6072](https://github.com/nim-lang/Nim/issues/6072)).

**Formatter.** nph (community) checks AST equivalence before writing and
names the hazard: "the Nim parser will generate different AST:s depending on
whitespace even if semantically there is no difference"
([FAQ](https://arnetheduck.github.io/nph/faq.html)); "`nimpretty` formats
tokens, not the AST" ([introduction](https://arnetheduck.github.io/nph/introduction.html)).

### 3.6 What the five have in common

| | Field ends when | Type continues if | Postfix on a field | Recovery | Formatter |
|---|---|---|---|---|---|
| Lean 4 | next token at col ≥ first field's col (`checkColGe`); app args need col > (`checkColGt`) | indented past field col | `:= v`, `:= by …` (tokens) | resume at next command; `structure` opts out of `recover` | none official |
| Idris 2 | terminator token or col ≤ block col (`atEnd`) | indented past block col | none (prefix `{…}`) | fatal | none official |
| Agda | virtual `;` at col, virtual `}` left of col | indented past field col | none | fatal | none official |
| F# | `$sep` at the offside col, or `;` | right of the offside limit | none | per field, error type | Fantomas, three styles |
| Nim | `IND{=}` | `IND{>}` | `= default` | breaks out of the body | nph (community) |
| Koka | inserted `;` at aligned indentation | not an "expression continuation" | `= default` | — | — |

Three facts recur. **(a)** The rule is the `let`-binding rule: siblings at
one column, continuation strictly right of it. **(b)** Postfix material is
always a token that cannot start a type argument (`:=`, `=`, a keyword), or
is banned. **(c)** Where a *bracket* sets a layout column (F#), the layout
becomes sensitive to identifier length and the formatter can emit code the
compiler rejects; where brackets set no column (Lean's `withoutPosition`,
Koka's token pass), it does not.

---

## 4. Why Elm and Haskell ended up with leading commas

### 4.1 Haskell: braces are terminals, layout applies to four keywords

The Report's layout rule "takes effect whenever the open brace is omitted
after the keyword `where`, `let`, `do`, or `of`"
([§2.7](https://www.haskell.org/onlinereport/haskell2010/haskellch2.html#x7-210002.7));
the layout function inserts only `;` and `}`
([§10.3](https://www.haskell.org/onlinereport/haskell2010/haskellch10.html#x17-17800010.3));
and the record production is
`constr → con { fielddecl1 , … , fielddecln }` with literal braces and commas
(§10.5). A layout record would need a new keyword to hang the virtual brace
on, and none was ever proposed to the Report.

**Comma-first was a workaround for the missing trailing comma**, by its
author's account. Tibell's style guide gives the `{ a ::` / `, b ::` / `}`
layout with no rationale
([haskell-style.md](https://github.com/tibbe/haskell-style-guide/blob/master/haskell-style.md));
Tweag quotes him: "I designed [Haskell style guide] to work with the lack of
support for a trailing comma. If we supported a trailing comma my style guide
would probably be different"
([Ormolu release](https://www.tweag.io/blog/2019-10-11-ormolu-first-release/)).
Ormolu chose trailing commas because "GHC supports a trailing comma now" in
export lists and because a leading comma in a multi-line *pattern* is a parse
error; Fourmolu exists partly to give the leading style back
(`comma-style`, default `leading`,
[docs](https://fourmolu.github.io/config/comma-style/)). The maintainer's
position on the question: "This is not math where one can have a proof. This
is the realm of psychology"
([ormolu#710](https://github.com/tweag/ormolu/issues/710)). The GHC proposal
to allow extra commas in "record-like occurences (declarations, patterns,
constructions, etc)" was voted accepted minus tuples in 2019 — `(a, b,)`
"would conflict with the `TupleSections` language extension" — then abandoned
and labelled Dormant
([ghc-proposals#87](https://github.com/ghc-proposals/ghc-proposals/pull/87)).
One committee member's vote note is the only place in the record where a
layout alternative is named: nomeata preferred "a layout-based solution that
gets _rid_ of separators" as "more pleasant, innovative and Haskell'ish".

### 4.2 Elm: one sentence of rationale, and a refusal to fight

The official argument is one paragraph of the style guide, under **Types**:

> "If we ever add a new field to `Circle` that is longer than `radius`, we
> have to change the indentation of all lines, leading to a bad diff.
> Furthermore, ending lines with a comma makes diffs messier because adding a
> field must change two lines instead of one."
> — [elm-lang.org/docs/style-guide](https://elm-lang.org/docs/style-guide)

The guide's stated goal is "a consistent style that is easy to read and
produces clean diffs". There is no "comma first" heading and no argument from
`[ , ]` symmetry or parse ambiguity. **elm-format does not own the choice**:
when asked for trailing commas, Aaron VonderHaar answered "This is a case
where I agree with you, but elm-format needs to be consistent with the Elm
Style Guide … not going to happen until the style guide changes"
([elm-format#161](https://github.com/avh4/elm-format/issues/161)), and he
opened #100 himself anticipating that if the compiler allowed trailing
commas "the official elm style guide will likely change to prefer trailing
commas instead of leading commas"
([elm-format#100](https://github.com/avh4/elm-format/issues/100), open).

**Evan's statements.** Closing Richard Feldman's "Commas Work Like
Semicolons" (newline-delimited multi-line records, 2015):

> "One thing I really don't want to do is 'fight the comma wars'. … I
> personally have grown accustomed to the leading comma stuff, but in the
> spirit of 'don't fight the comma wars' I don't think it makes sense for Elm
> to be in the business of making people go that route."
> — [elm/compiler#979](https://github.com/elm/compiler/issues/979)

He preferred optional trailing commas, "pretty widely implemented in other
languages", then never shipped them: elm-plans #2 closed with "I will
revisit this myself when the time comes"
([elm-plans#2](https://github.com/elm-lang/elm-plans/issues/2)), and #1478 in
2016 with "Features that are 'it can be done, but I'd rather do it with a
different syntax' are lower priority than 'it cannot be done'"
([elm/compiler#1478](https://github.com/elm/compiler/issues/1478)). On
layout versus braces for records nothing was found beyond a 2013 note that
records follow Haskell's rules and that he loosened them so a record type's
closing `}` may sit in column 0
([elm-discuss 2013](https://groups.google.com/g/elm-discuss/c/AHHZtSyk480)).

**The 2015 attempt at what the owner is asking.** Feldman's #978 argued
leading commas are "visually noisier than 'no commas' **without improving
clarity**" and "strictly harder to scan"
([elm/compiler#978](https://github.com/elm/compiler/issues/978)); #979
proposed `type alias Bounds = {` / `  width : Int` / `  height : Int` / `}`,
with the field observation that at a 20-person workshop "the second most
common solution was 'you need to add a comma.'" The objection that carried
was about *values*: `( 3 4 5 )` is indistinguishable from an application
(#979, Apanatshka and kmarekspartz). A record **type** field begins
`name :`, which that objection does not reach — a point no one made in the
thread and which §5 returns to.

**Elm's parser: one error, no recovery.** The record-type diagnostics live in
`Reporting/Error/Syntax.hs` (`TRecordOpen | TRecordEnd | TRecordField |
TRecordColon | …`). A missing comma between `name : String` and `age : Int`
is not reported as a missing comma: `Parse/Type.hs` greedily reads
`String age` as an application and fails at `:` with `TRecordEnd` —
"I am partway through parsing a record type, but I got stuck here: … I was
expecting to see a closing curly brace before this, so try adding a } and
see if that helps?"
([Syntax.hs](https://github.com/elm/compiler/blob/master/compiler/src/Reporting/Error/Syntax.hs),
[Type.hs](https://github.com/elm/compiler/blob/master/compiler/src/Parse/Type.hs)).
`Parser x a` is a four-continuation CPS parser returning one error per
module ([Primitives.hs](https://github.com/elm/compiler/blob/master/compiler/src/Parse/Primitives.hs)).
The design rationale for the column-0 rule is in the 0.19.1 announcement:
"the compiler can always pinpoint the particular definition that contains a
syntax error. No more errors at the end of the file!"
([the-syntax-cliff](https://elm-lang.org/news/the-syntax-cliff)). beni's
rule 1 is the same rule.

### 4.3 The forks kept it

PureScript's purs-tidy emits leading commas with no option; Faubion: "I
don't have an intention of being principled and necessarily transparent
about all these choices, because aesthetic choices are so often quite
irrational"
([discourse](https://discourse.purescript.org/t/announcing-purs-tidy-a-syntax-tidy-upper-for-purescript/2524)).
Gren's record-type parser is Elm's and its only announced change is to the
alias head, `Named : { name : String }`, "inspired by Roc"
([gren news](https://gren-lang.org/news/240819_upcoming_language_changes/)).
Derw and Mint use braces and commas with no layout.

### 4.4 Roc: the language most like beni kept braces twice

Roc is the nearest relative — layout-sensitive definitions and `when`, no
`in`, structural records — and it kept brace-and-comma records through two
syntax eras. In 2022, when a comma-less multi-line record was proposed,
Richard Feldman's first question was "what happens if the record field
definition has a super long type, and needs to be multiline?", and of the
indent-as-continuation answer: "CoffeeScript does this. It worked well as I
recall, but there was definitely a backlash about how much indentation
mattered in that language"
([Zulip](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Don.27t.20require.20comma.20when.20doing.20multiline.20lists.3F/near/276697491),
[276698239](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Don.27t.20require.20comma.20when.20doing.20multiline.20lists.3F/near/276698239)).
In 2025 the new brace-block syntax made commas load-bearing a second way:
"`{` followed by lowercase identifier followed by either `,` or `:` is a
record" / "anything else is a block"
([braces syntax](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/braces.20syntax/near/500475014)),
with Joshua Warner's concern that "we have to look ahead an unbounded number
of tokens" for nested records and a proposed `NoSpaceColon` token
([500474078](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/braces.20syntax/near/500474078),
[500495876](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/braces.20syntax/near/500495876)),
and a contributor writing snapshots four months later finding "'is this a
block or a record' a little confusing"
([525989152](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/.E2.9C.94.20Should.20type.20annos.20use.20.3A.3A/near/525989152)).
Roc's formatter makes the trailing comma the only layout bit — "I don't
think `roc format` should ever take line length into consideration"
([493010354](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Code.20format.20to.20single.2Fmultiline.20by.20trailing.20comma/near/493010354)) —
and its new parser reports record errors as "I was parsing a record type, and
I expected `,` or `}`." with malformed nodes and top-level declarations as
the resync boundary
([AST.zig](https://raw.githubusercontent.com/roc-lang/roc/main/src/parse/AST.zig),
[526199766](https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/fuzz.20crash.20-.20handling.20malformed.20tokens.20and.20parsing/near/526199766)).
Roc's optional fields were removed with static dispatch because the
config-record use had "various type problems in practice, and was confusing
to learn", then re-added in 2026 as `label ?: Str` for serialization
([611468685](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/record.20field.20operations/near/611468685)) —
the same use beni's `optional` modifier serves.

---

## 5. What it would mean for beni

### 5.1 What beni already has, and what a layout body would reuse

`language.md` §4 has no layout pre-pass and no virtual tokens: "the parser
carries one integer, the **indent** of the current block, and a token
belongs to the current construct only if its **column is greater than the
indent**". A `let` binding list is the mechanism a layout record needs,
already specified: "The first binding sets the column; a token at exactly
that column begins the next binding" (rule 3), and a binding's body ends at
"a token at column ≤ that, or one the expression cannot continue with". This
is Lean's `checkColGe`/`checkColGt` pair and Agda's virtual `;`/`}`, stated
for one construct. Two further facts bear on the sketches:

- **Brackets set no column** (rule 6: "Inside `( [ {` rule 2 applies against
  the enclosing block's indent"). This is the property F# lacks and the reason
  its record layout depends on field-name length (§3.4). It also means a
  layout body *inside* braces would have to introduce a column where none
  exists today.
- **The comma rule already uses the `lower_ident ':'` lookahead**: "a comma
  inside a record-type body ends the field's type when the next two tokens
  are `lower_ident ':'` … one token of lookahead settles it with no
  backtracking, because `:` can never follow a type item" (§3 *Types*). The
  same two tokens are what every layout sketch below uses to recognise a
  field, so the lookahead is not new.
- **Recovery today.** `parseRecordTypeFields` (`src/parse/Parse.zig:1613`)
  recovers a bad field with `recoverUnlessStructural` and continues only if a
  comma follows; `parseSchemaRecord` (`:861`) consumes "the broken field's
  tail only" up to the next comma or `}` because "Schema records promise
  sibling recovery at comma/brace (§2), which generic delimiter recovery
  cannot provide because it skips to the closing brace". A layout body has no
  comma to resynchronise on; it would resynchronise on *a token at exactly
  the field column*, which is what `let` bindings do.
- **The schema formatter is already always-vertical.** `schema.md` §2: "the
  record or operand body starts on the next line indented four spaces" and
  "prints each field doc on its own line at the ordinary field column rather
  than after `{` or `,`". So a layout schema body forfeits no one-line form,
  while a `type alias` record has one (`{ a : Int, b : Int }` when it fits and
  the author wrote no break, §9) and appears inline in annotations.

The two languages whose situation is closest are **Koka**, which offers both
`struct person` in layout and `struct person{ … }` in braces with the layout
form defined by desugaring, and **Idris**, which accepts braces around any
layout block. Neither has structural records, so neither had to answer what
the layout form means *inline*.

### 5.2 Sketch A — bare field block after `=` `[sketch]`

The Lean/Agda shape: the declaration head ends in `=`, fields follow on
aligned lines, nothing else.

```elm
-- [sketch] A: bare field block
type alias User =
    name : String
    age : Int
    address :
        street : String
        city : String
    greet : String, Int -> String


pub schema User =
    userId : Int as "user-id"
    nickname : String optional nullable
    address :
        street : String
        postalCode : String as "postal-code"
    tags : List String via Tags.fromCsv


pub schema Message tagged "kind" of
    Text as "text"
        value : String
    Count as "count"
        value : Int
    Empty as "empty"
```

Grammar delta, in §3's notation:

```text
TypeAlias      := 'type' 'alias' upper_ident lower_ident* '=' (Type | FieldBlock)
FieldBlock     := LayoutField+                    -- aligned, §4 rule 3
LayoutField    := DocComment? lower_ident ':' (Type | FieldBlock)
SchemaBody     := '=' (SchemaRecord | SchemaFieldBlock | SchemaOperand ValueModifier*)
                | 'tagged' string 'of' LayoutVariant+
SchemaFieldBlock := LayoutSchemaField+
LayoutSchemaField := DocComment? lower_ident ':' (SchemaOperand FieldModifier* | SchemaFieldBlock)
LayoutVariant  := upper_ident ('as' string)? SchemaFieldBlock?
```

**Where a field ends.** A `FieldBlock` is a block in §4's table: its indent
is the first field's column; a token at exactly that column begins the next
field; a token at a smaller column ends the block. A field's type or
modifiers continue while tokens are at a column greater than the field
column — the `let` body rule. Rule 1 still ends everything at column 1.

**Ambiguities a parser must resolve.**

1. *Nested block versus type.* After `address :` the next token is
   `street` on a new line — a `lower_ident`, which today starts a `Type` as a
   type variable. The two-token test `lower_ident ':'` decides "field block"
   and is the comma rule's own lookahead. If the author writes
   `address : Maybe` and then `street : String` indented, the parser reads
   `Maybe` (arity error) and then meets `street : String` at a column that is
   neither the sibling column nor a continuation — `field_at_unexpected_column`
   or similar — so the shape is a diagnostic, not a misparse. This is Lean's
   `checkColGt` outcome exactly.
2. *A type variable that happens to be followed by a colon.* Cannot occur:
   `:` never follows a type item, so `lower_ident ':'` inside a type is
   always a field head. The same holds for schema operands, where a
   `lower_ident` may be a schema parameter (`Page a`).
3. *Postfix modifiers.* `optional`, `nullable`, `via` are contextual words
   that "terminate schema application at the current delimiter depth"
   (`schema.md` §2); in layout the rule is unchanged, and a modifier on a
   continuation line (`nickname : String` / `optional nullable` indented) is
   a continuation because it is right of the field column. `via Atom` takes
   an `Atom` "including its abutting access chain"; an atom may be a `{…}`
   record literal or a parenthesised expression, whose brackets balance under
   rule 6, so the field's end is still the next aligned `lower_ident ':'`.
   Lean and Koka settle postfix material with tokens that cannot begin an
   argument (`:=`, `=`); beni's modifiers are words, and their disambiguation
   is already specified.
4. *The `->` and the `,` in a field's type.* `greet : String, Int -> String`
   needs no lookahead at all in layout: the comma is only ever the parameter
   separator, because there is no field separator to confuse it with. A
   layout body removes the one ambiguity the brace body has.
5. *A variant with no payload* (`Empty as "empty"`) is followed by a token at
   the variant column or by column 1; a variant *with* a payload is followed
   by a deeper `lower_ident ':'`. The `|` bars of the brace form become
   unnecessary; keeping them is a choice, not a need.
6. *Annotations look like fields.* `Annotation := lower_ident ':' Type` is a
   field's shape. At top level rule 1 separates them by column. In a `let`,
   an annotation's type could begin a field block on the next line
   (`f :` / `a : Int` indented) — grammatical under this sketch but odd.
   Every surveyed layout language avoids the question by having no anonymous
   record types; a beni rule restricting `FieldBlock` to declaration bodies
   (`type alias`, constructor payload, `schema`) would be the same choice.
7. *Inline positions keep braces.* `view : { name : String } -> Html` has no
   layout spelling: a `->` at the field column would be read as continuing
   the field's function type (`->` is a token a type *can* continue with).
   Extensible records `{ r | a : Int }` likewise. So braces remain the inline
   and one-line form, and the sketch is a second spelling for the same type —
   Koka's situation, with the layout form defined by desugaring to the brace
   form, which keeps BIR and the checker untouched.

**Recovery of a malformed field.** Skip tokens until one is at exactly the
field column and the two tokens there are `lower_ident ':'`, or a token is at
a column ≤ the enclosing block's indent, or column 1. A field whose type is
broken keeps its name with an `error_type` placeholder, as F#'s
`SynType.FromParseError` does and as `Parse.zig`'s `error_field` does now.
A mis-indented sibling (one space off) is not a skipped field but a
diagnostic at that line, because siblings must be exactly aligned — the
outcome Nim does not deliver (§3.5). What cannot be recovered well is the
missing-colon case `age Int`: it is `lower_ident upper_ident`, not a field
head, and would be consumed as continuation of the previous field's type
(`String age Int`) exactly as Elm's `String age` is (§4.2); the report would
land on the previous field's arity, not on `age`. The brace form has the
same weakness today, with the comma to stop the damage one field later.

**Formatting.** Always vertical, like `case` and `let` (§9: "`if`, `case`
and `let` are always vertical"); one field per line at +4 from the head,
nested blocks at +4 from their field, modifiers on the field line separated
by one space, doc comment on its own line at the field column. Idempotent by
construction: there is one printed form. The `type alias` one-line form
`{ a : Int }` and the vertical layout form would be chosen by the existing
rule — "the construct is printed on one line when it fits in 100 columns
*and* the source has no line break between its elements" — so an author who
breaks a brace record gets a layout record back and an author who joins one
gets braces; whether that is acceptable, or whether the two spellings must
be preserved as written, is a decision. A type that does not fit breaks at
`->` with continuation lines at +4 from the field column, which is deeper
than the sibling column by construction and therefore never a sibling.

**What the surveyed experience points at.** The Lean/Idris/Agda shape with no
official formatter in any of the three (§3.1–3.3); Roc's 2022 objection —
the multi-line type — answered by indentation, which Feldman noted had a
CoffeeScript backlash (§4.4); and the fact that no structural-records
language has adopted it, so the inline-braces-plus-layout-declaration split
would be beni's own.

### 5.3 Sketch B — braces kept, commas optional at a line break `[sketch]`

The F# shape, minus F#'s bracket-column rule.

```elm
-- [sketch] B: braces, newline-separated fields
type alias User =
    {
        name : String
        age : Int
        address :
            {
                street : String
                city : String
            }
    }


pub schema User =
    {
        userId : Int as "user-id"
        nickname : String optional nullable
    }
```

Grammar delta: `RecordTypeFields := Field (FieldSep Field)*` where `FieldSep`
is `','` or *a line break followed by `lower_ident ':'` at exactly the first
field's column*; the same for `SchemaRecord`. The `{ a : Int, b : Int }`
one-line form is unchanged, and mixing (`,` on one line, newline on the next)
is either allowed or `mixed_field_separators`.

**Ambiguities.**

1. *A bracket now sets a column.* Today `{` sets none (rule 6). To make "next
   field at the first field's column" meaningful, the first field's column
   must be recorded — a second integer while inside the braces. Where the
   first field sits on the `{` line (F#'s Cramped: `{ First: string` /
   `      Last: string`), that column is wherever `{ ` put it, and a nested
   record's column depends on the length of the enclosing field name. That
   is the mechanism behind FS0058 in fslang-suggestions #130 (§3.4); it does
   not produce F#'s *warning* here, because beni's `}` is governed only by
   the enclosing block indent, but it does produce name-length-dependent
   alignment in hand-written code, which is what the Elm style guide's first
   sentence argues against (§4.2). The formatter can normalise it; the parser
   must still accept it.
2. *Field end.* Same as A: `lower_ident ':'` at the field column, or `,`, or
   `}`. The comma lookahead rule survives for one-liners.
3. *Missing colon* `age Int` on its own line: consumed as continuation, same
   failure as A and as today.

**Recovery.** Strictly better than today's: resynchronise at the next `,`,
the next `lower_ident ':'` at the field column, or `}`. The `}` still
guarantees the damage stays inside the record, which A cannot guarantee
(A's damage stops at column 1 or at the enclosing block).

**Formatting.** Two forms exist today (one-line and vertical); B keeps both
and changes only the vertical one's separators. The vertical form's `{` and
`}` placement must be fixed by the formatter — on their own lines, as above,
to avoid the name-length column — so the output is deterministic.
Fantomas needed three named styles and a `with`-keyword exception to make
this shape formattable under F#'s rules (§3.4); beni's rule 6 removes the
`with` problem but not the placement decision.

**What the experience points at.** F# is the only language with this exact
shape and the only one with a decade of record-layout defects, all traceable
to the bracket setting a column. B has the bracket set a column by design.
It also keeps the braces the owner called ugly, removing only the commas.

### 5.4 Sketch C — a body keyword, fields in layout, braces for inline only `[sketch]`

Idris's shape: the head ends in a word that announces a layout body, and the
brace form is reserved for inline use.

```elm
-- [sketch] C: `where`-style body keyword
type alias User where
    name : String
    age : Int
    address where
        street : String
        city : String


pub schema User where
    userId : Int as "user-id"
    nickname : String optional nullable


pub schema Message tagged "kind" where
    Text as "text" where
        value : String
    Count as "count" where
        value : Int
```

**Ambiguities.**

1. *`where` is taken.* `where` is a contextual word for dispatch constraints
   on a top-level annotation (`language.md` §3, `static-dispatch-spike.md`
   §2.1), recognised "by three tokens of lookahead". A `where` after
   `type alias User` or after a schema head is a different position — no
   annotation precedes it — so the two uses are separable by the token before
   `where`, but every reader now holds two meanings of one word. Any other
   word (`with`, `has`, `fields`) is a new keyword and a breaking change to
   identifiers; `equatable`-style contextual recognition is possible and is
   more lookahead.
2. *The nested form `address where`* removes ambiguity 1 of sketch A: the
   body keyword announces the block, so `address :` followed by a bare type
   and `address where` followed by fields never meet. The price is a keyword
   on every nested record.
3. *Everything else as A*: field end at the aligned `lower_ident ':'`,
   modifiers as contextual words, function-type commas unambiguous, inline
   positions in braces.

**Recovery.** As A, with one improvement: the body keyword gives the
recovering parser a definite start-of-block token, so "expected `where` or
`=`" is reportable at the head line, and a block whose first field is
malformed still knows it is a block.

**Formatting.** As A; the keyword is part of the head line; nothing else
changes. Idempotent by construction. The head line of a `type alias` never
ends in `=` in this form, so the §9 rule "`=` goes at the end of the head
line and the body on the next line indented 4" gets a sibling rule, not an
exception.

**What the experience points at.** Idris's `where` is itself a terminator
token, which made a line-initial `where` end the *previous* declaration
(#234, §3.2); beni's rule 1 already forbids a `where` at column 1 from
belonging to anything above it, and a `where` at column ≥ 2 belongs to the
declaration it is in, so the Idris trap does not transfer. What does
transfer is the two-meanings cost, which beni would be the first to pay.

### 5.5 The trade-offs, side by side

| | A — bare block after `=` | B — braces, optional commas | C — body keyword |
|---|---|---|---|
| Removes braces from declarations | yes | no | yes |
| Removes commas | yes | yes | yes |
| Inline / extensible records | braces, as today | braces, as today | braces, as today |
| Two spellings of one type | yes (Koka's situation) | no — one form, two separators | yes |
| New parser state | one block column per body (the `let` mechanism) | a bracket that sets a column (new; F#'s mechanism) | one block column per body |
| New lookahead | none — `lower_ident ':'` is the comma rule's | none | contextual `where` in a new position |
| Function-type comma in a field | unambiguous | needs today's rule on one-liners | unambiguous |
| Damage of a malformed field bounded by | the aligned column, then column 1 | `}` | the aligned column, then column 1 |
| Missing-colon field (`age Int`) | consumed as continuation (as Elm, as today) | same | same |
| Name-length-dependent alignment | never — the column is set by indentation | when the first field shares the `{` line | never |
| Formatter forms | vertical only for the layout spelling; one-line stays braces | one-line and vertical, `{`/`}` placement fixed | as A |
| Nearest prior art | Lean 4, Agda, Nim, Python | F# | Idris 2, Lean's `where` |
| Prior art's cost on record | no official formatter in Lean/Idris/Agda; Nim's catch-all error | FS0058 for a decade; FS-1108; Fantomas' three styles | Idris's fatal parse, `where`-as-terminator trap |

Two things are common to all three and are worth stating without a
recommendation. First, **record *values*** — `{ a = 1, b = 2 }` — are out of
scope of the owner's question and stay in braces under every sketch; that is
where Feldman's `( 3 4 5 )` objection (§4.2) and Roc's block-versus-record
lookahead (§4.4) live, and none of it reaches a type declaration whose every
field begins `name :`. Second, **a doc comment per field** is the one place
the current brace-and-leading-comma form is already awkward — `schema.md` §2
has to say the doc goes "on its own line at the ordinary field column rather
than after `{` or `,`", so a documented field reads `--| doc` / `, field :`
with the comma between the comment and its field. In all three sketches the
comment and its field share a column with nothing between them, as in Lean,
Idris and Rust.

---

## 6. What practitioners reported

Ordered from the concrete (people describing consequences in code they
shipped) to the aesthetic. Forum quotations are opinions, dated where the
source dates them; HN does not publish comment scores and none are claimed.

### 6.1 On Elm's and Haskell's leading commas

*The one argument that survives a permitted trailing comma* is three-way
merges. vore, 2022: two branches appending `d` and `dd` after `c` — with
leading commas "Your usual 3 way merge algorithm will correctly deduce" the
union; with trailing commas and no trailing-comma support "You now have a
merge conflict between 'd,' and 'dd'"
([HN 33503200](https://news.ycombinator.com/item?id=33503200)). Every other
pro argument — one-line appends, visible missing comma, commenting a line
out — is conceded by its own proponents to be delivered equally by a
trailing comma: "Leading comma vs allow a non-terminating comma both leads to
the same diff of just the one line" (Tehnix,
[HN 13621507](https://news.ycombinator.com/item?id=13621507)); "Not if the
language allows trailing commas on the last line, like Python and Go do"
(icebraining, [HN 14620958](https://news.ycombinator.com/item?id=14620958)).

*The complaints a trailing comma does not fix*: sorting and the first line.
"This doesn't allow me to easily sort lines alphabetically, as some lines
start with `{` and others with `,`" (sporto,
[elm-format#161](https://github.com/avh4/elm-format/issues/161)); "Adding or
removing the first element requires to change TWO lines instead of one"
(Porto, [elm-dev](https://groups.google.com/g/elm-dev/c/c711R30X1lE));
danny-andrews counted keystrokes and found the recommended format "performs
the **worst possible** in terms of reducing keystrokes" with line-duplication
shortcuts (elm-format#161). Feldman, who switched: "Yeah, I've felt that pain
too since switching to leading commas. It is definitely annoying"
([elm-dev](https://groups.google.com/g/elm-dev/c/h97FcHrbTaw)).

*The Rust test.* In a language that already had trailing commas, a 2018
pre-RFC to add leading ones drew, as its most-liked reply: "I've only seen
leading commas used as a workaround in places where trailing commas aren't
supported. Since Rust does support trailing commas quite well, I'm against
adding an ugly hack for a non-existent problem" (kornel, 7 likes,
[internals](https://internals.rust-lang.org/t/pre-rfc-leading-commas/7260)).

*Defences from Elm shippers.* "Comma-first makes sense since you're chaining
off the right-hand side of an expression more than most other languages"
(danneu, [HN 14874277](https://news.ycombinator.com/item?id=14874277)); "The
leading commas … make diffs easy and make lists a bit easier to read. The
syntax is almost the same in Haskell, but Ormolu puts the commas at the end
and somehow it's harder to pick apart complicated list entries" (1-more,
[HN 33457081](https://news.ycombinator.com/item?id=33457081)); "the majority
(91%) of the Elm community who use elm-format enjoy it… The people who are
most vocal about elm-format being negative are those who have not actually
used it outside of short trials" (enalicho, 2.5 years of Elm at work,
[HN 14874038](https://news.ycombinator.com/item?id=14874038)). Vinnl on
review cost: "if you add a line, you'll also have to inspect the
`radius: Float` line when doing a code review, even though it only added a
comma" ([HN 13370125 thread](https://news.ycombinator.com/item?id=13370125)).

*The aesthetic reaction*, recorded because the owner's question begins
there: "makes me shudder with revulsion every time I see it --- that's not
where commas go, dammit" (david-given,
[HN 13370125](https://news.ycombinator.com/item?id=13370125)); "prefix commas
is fixing one mistake with another mistake. Enforce trailing commas"
(davidjfelix, [HN 33456396](https://news.ycombinator.com/item?id=33456396));
"Thank god someone finally said it: Elm format is way too white space heavy"
(wryoak, [HN 36256606](https://news.ycombinator.com/item?id=36256606)); the
counter-image "view them like bullet points rather than as typographic
commas" (Marek-Spartz,
[elm-discuss](https://groups.google.com/g/elm-discuss/c/wu-BwDDKUSw)). Over
320 GB of SQL, trailing commas outnumbered leading roughly 35:1
([Hoffa, 2017](https://hoffa.medium.com/winning-arguments-with-data-leading-with-commas-in-sql-672b3b81eac9)).

After 2017 the Elm Discourse is effectively silent on the question — two
incidental posts were found
([4915](https://discourse.elm-lang.org/t/my-first-hours-of-elm/4915/2),
[2012](https://discourse.elm-lang.org/t/hi-elmers-lets-talk-about-elms-code-formatting/2012/12));
the practitioner record reads as a debate that elm-format's adoption ended
rather than settled.

### 6.2 On braces inside an offside-rule language (F#)

The concrete reports are the issues in §3.4 — a warning that depends on how
long a field name is (#130), that fires on anonymous records and not named
ones (#10552), that a formatter emitted (#1341) — and the RFC that fixed
them (FS-1108). Sentiment tracks the fix: "Indentation sensitivity was one of
F#'s design flaws" (jdh30, 2014,
[HN 8499874](https://news.ycombinator.com/item?id=8499874)); "every time I'm
using F# I seem to run into weird problems around indentation" (bratsche,
2014, [HN 7048181](https://news.ycombinator.com/item?id=7048181)); versus "I
honestly rarely have any issue with indentation in F# that isn't immediately
fixable by some editor feedback" (bmitc, 2023,
[HN 34749177](https://news.ycombinator.com/item?id=34749177)) and "I believe
they revamped the indentation rules a few years back, because I definitely
remember things like that not working" (rmunn, 2026,
[HN 48663399](https://news.ycombinator.com/item?id=48663399)).

### 6.3 On layout-only blocks (Scala 3, Nim, Python)

The largest primary record is Scala 3's "Feedback sought: Optional Braces"
(578 posts). Odersky, 42 likes: "using optional braces is the single most
important productivity boost for me when switching to Scala-3", with the
admission "It was the one change where I was relying on my authority as
informal BDFL to push it through"
([contributors 4702](https://contributors.scala-lang.org/t/feedback-sought-optional-braces/4702)).
The Scala.js lead, 23 likes: "With braces, I can put my cursor on each brace,
one at a time, to immediately see the various scopes. With indentation, not
so: I only have access to the innermost and outermost scopes" (sjrd, same
thread). The tooling author, 23 likes: "code formatting for significant
indentation syntax is one where we have a shred of evidence from Python that
it's a complicated and largely unsolved issue" (gabro). The shipped-code
report against: "moving code around was much slower… this moves indentation
and formatting from 'stuff I don't have to think about' to 'stuff I have to
actively manage'" (morgen-peschke); and Nedelcu, after trying for years,
switched back because "Scalafmt won't help as it chokes on invalid syntax"
([alexn.org, 2025](https://alexn.org/blog/2025/10/26/scala-3-no-indent/)).
For: "braceless syntax has an obvious drawback (copy/pasting code doesn't
work without adjusting indentation). Yet I personally find this drawback is
compensated by the benefit (layout reflects semantics, without
duplication!)" (jdegoes, 14 likes, 4702). Li Haoyi's conditional support is
the one that names beni's situation: "we can look at F# and Haskell to see
that when given a choice… people generally end up picking the
indent-delimited version" — but "two-space indentation makes it very hard to
distinguish blocks when skimming" (4702). Scala's own 2026 style thread
opens "The question whether to use indentation or braces currently divides
the Scala community"
([contributors 7383](https://contributors.scala-lang.org/t/towards-a-common-scala-style-recommendation/7383)).

Nim's designer, on the copy-paste complaint: "Tools that throw away
whitespace are broken tools. Broken tools should not guide syntax design"
(Araq, [forum 8596](https://forum.nim-lang.org/t/8596), thread locked). The
HN side of the same argument: "after the invention and normalization of
opinionated autoformatters, it means that the autoformatter can't figure out
for me how my code should be indented" (mumblemumble,
[HN 28918044](https://news.ycombinator.com/item?id=28918044)); "when working
with others and resolving merge conflicts your example is my nightmare"
(feffe, same thread); and, from an Elm user in that thread: "I don't
personally run into either of these issues at all working with Elm code
(significant whitespace language) in vim… elm-format is opinionated… and
pretty much everyone uses it. No issues with indentation that I can recall"
(rapind, same thread).

On Lean 4's `structure` syntax and on Python dataclass *layout*
specifically, practitioner sentiment was **not found**; dataclass praise is
about generated methods ([HN 46231804](https://news.ycombinator.com/item?id=46231804)).

### 6.4 The single biggest risk each language's experience points at

| Language | The risk its record points at |
|---|---|
| Lean 4 | A layout declaration with **no formatter** for four years and counting (#1488); recovery inside `structure` deliberately switched off |
| Idris 2 | A **fatal** parse on the first malformed field, and a body keyword (`where`) that is also a terminator |
| Agda | Layout-lexer complexity (tentative/confirmed/passive columns) whose regressions land on records (#5236) |
| F# | A **bracket that sets a column**: legality depends on field-name length, the formatter emits offside code, and it took FS-1108 to undo |
| Nim | **"invalid indentation" as the catch-all** for unrelated errors (#15667), and a body parser that gives up at the first bad field |
| Scala 3 | **Two spellings** of one construct dividing the community for six years; formatter cannot rescue invalid layout |
| Elm | A style the language's author would not defend, a debate ended by formatter adoption rather than argument, and a **one-error parser** |
| Haskell | Layout hard-wired to four keywords, so the record production could never use it; comma-first as a **workaround** for a missing trailing comma |
| Roc | Multi-line field types are the first objection (2022); commas became **load-bearing for disambiguation** against blocks (2025) |
| Koka | Two official forms tied by **desugaring** — the cheapest way to have both, and the one no structural-records language has tried |

---

## 7. Sources

### beni, read

`docs/design/language.md` §3 (grammar, the comma rule), §4 (layout), §6.3,
§9 (formatting); `docs/design/schema.md` §2; `docs/design/frontend.md` §3.5;
`src/parse/Parse.zig:544–571` (`recover`, `recoverUnlessStructural`),
`:861–911` (`parseSchemaRecord`, `parseSchemaField`), `:913–963`
(`parseSchemaOperand`, modifier predicates), `:1575–1633` (record type and
`parseRecordTypeFields`), at `1e64248`.

### Lean 4
https://lean-lang.org/doc/reference/latest/The-Type-System/Inductive-Types/#structures ·
https://raw.githubusercontent.com/leanprover/reference-manual/main/Manual/Language/InductiveTypes/Structures.lean ·
https://lean-lang.org/functional_programming_in_lean/Getting-to-Know-Lean/Structures/ ·
https://raw.githubusercontent.com/leanprover/lean4/master/src/Lean/Parser/Command.lean ·
…/Extra.lean · …/Basic.lean · …/Term.lean · …/Term/Basic.lean · …/Module.lean ·
https://raw.githubusercontent.com/leanprover/lean4/master/src/Lean/Elab/Structure.lean ·
https://leanprover-community.github.io/mathlib4_docs/Lean/Parser/Command.html ·
https://lean-lang.org/doc/reference/latest/releases/v4.19.0/ ·
https://github.com/leanprover/lean4/issues/369 · /1488 · /4156 · /8222 · /13818 ·
https://leanprover-community.github.io/archive/stream/113489-new-members/topic/Lean.20formatter.html ·
https://github.com/duckki/leanfmt · https://github.com/lotusirous/lean-fmt

### Idris 2
https://idris2.readthedocs.io/en/latest/tutorial/typesfuns.html ·
https://idris2.readthedocs.io/en/latest/reference/documenting.html ·
https://raw.githubusercontent.com/idris-lang/Idris2/main/src/Idris/Parser.idr ·
https://raw.githubusercontent.com/idris-lang/Idris2/main/src/Parser/Rule/Source.idr ·
https://github.com/idris-lang/Idris2/issues/234 · /504 · /626 · /3369 ·
https://groups.google.com/g/idris-lang/c/Q8E4_6Ui5Ms · https://github.com/idris-industry/idrisfmt

### Agda
https://agda.readthedocs.io/en/latest/language/record-types.html ·
https://agda.readthedocs.io/en/latest/language/lexical-structure.html ·
https://agda.github.io/agda/Agda-Syntax-Parser-Layout.html ·
https://hackage.haskell.org/package/Agda-2.6.2/changelog ·
https://wiki.portal.chalmers.se/agda/pmwiki.php?n=AIMXXIV.ParserErrors ·
https://github.com/agda/agda/issues/917 · /3046 · /3400 · /3803 · /5236 · /5541

### F#
https://learn.microsoft.com/en-us/dotnet/fsharp/language-reference/records ·
https://learn.microsoft.com/en-us/dotnet/fsharp/language-reference/anonymous-records ·
https://learn.microsoft.com/en-us/dotnet/fsharp/style-guide/formatting ·
https://github.com/fsharp/fslang-spec/blob/main/spec/lexical-filtering.md ·
https://github.com/fsharp/fslang-design/blob/main/FSharp-6.0/FS-1108-undentation-frenzy.md ·
https://github.com/dotnet/fsharp/blob/main/src/Compiler/pars.fsy ·
https://github.com/dotnet/fsharp/blob/main/src/Compiler/FSComp.txt ·
https://github.com/dotnet/fsharp/issues/6941 · /10552 · /2834 ·
https://github.com/fsharp/fslang-suggestions/issues/130 · /786 ·
https://fsprojects.github.io/fantomas/docs/end-users/Configuration.html ·
https://github.com/fsprojects/fantomas/issues/536 · /1341

### Nim
https://nim-lang.org/docs/manual.html · https://nim-lang.org/docs/grammar.txt ·
https://github.com/nim-lang/Nim/blob/devel/compiler/parser.nim ·
https://github.com/nim-lang/Nim/issues/15667 · /6072 · /7884 · /12353 ·
https://forum.nim-lang.org/t/8596 · https://forum.nim-lang.org/t/10361 ·
https://arnetheduck.github.io/nph/introduction.html · …/faq.html · …/style.html

### Python, Scala 3, Kotlin, Swift, Rust
https://peps.python.org/pep-0557/ · https://peps.python.org/pep-0589/ · https://peps.python.org/pep-0655/ ·
https://docs.python.org/3/reference/lexical_analysis.html#indentation ·
https://black.readthedocs.io/en/stable/the_black_code_style/current_style.html ·
https://docs.scala-lang.org/scala3/reference/other-new-features/indentation.html ·
https://docs.scala-lang.org/scala3/reference/syntax.html ·
https://docs.scala-lang.org/scala3/reference/changed-features/structural-types.html ·
https://docs.scala-lang.org/sips/fewer-braces.html ·
https://github.com/scala/scala3/blob/main/compiler/src/dotty/tools/dotc/parsing/Parsers.scala ·
https://github.com/scala/scala3/issues/12185 · /12442 · /21382 ·
https://scalameta.org/scalafmt/docs/configuration.html · https://github.com/scalameta/scalafmt/issues/2688 ·
https://contributors.scala-lang.org/t/feedback-sought-optional-braces/4702 ·
https://contributors.scala-lang.org/t/scala-3-significant-indentation/4672 ·
https://contributors.scala-lang.org/t/towards-a-common-scala-style-recommendation/7383 ·
https://alexn.org/blog/2022/10/24/scala-3-optional-braces/ · https://alexn.org/blog/2025/10/26/scala-3-no-indent/ ·
https://kotlinlang.org/docs/data-classes.html ·
https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures/ ·
https://doc.rust-lang.org/reference/items/structs.html · https://doc.rust-lang.org/nightly/style-guide/items.html ·
https://internals.rust-lang.org/t/pre-rfc-leading-commas/7260

### Elm and its forks
https://elm-lang.org/docs/style-guide · https://github.com/elm/elm-lang.org/blob/master/pages/docs/style-guide.elm ·
https://elm-lang.org/docs/syntax · https://guide.elm-lang.org/types/type_aliases.html ·
https://elm-lang.org/news/the-syntax-cliff ·
https://github.com/avh4/elm-format · https://github.com/avh4/elm-format/issues/100 · /161 · /224 ·
https://github.com/elm/compiler/issues/978 · /979 · /1478 · https://github.com/elm-lang/elm-plans/issues/2 ·
https://groups.google.com/g/elm-dev/c/h97FcHrbTaw · https://groups.google.com/g/elm-dev/c/c711R30X1lE ·
https://groups.google.com/g/elm-discuss/c/wu-BwDDKUSw · https://groups.google.com/g/elm-discuss/c/AHHZtSyk480 ·
https://github.com/elm/compiler/blob/master/compiler/src/Reporting/Error/Syntax.hs ·
https://github.com/elm/compiler/blob/master/compiler/src/Parse/Type.hs ·
https://github.com/elm/compiler/blob/master/compiler/src/Parse/Primitives.hs ·
https://discourse.elm-lang.org/t/hi-elmers-lets-talk-about-elms-code-formatting/2012 ·
https://discourse.elm-lang.org/t/my-first-hours-of-elm/4915 ·
https://gren-lang.org/book/syntax/records/ · https://gren-lang.org/news/240819_upcoming_language_changes/ ·
https://github.com/gren-lang/compiler/blob/main/compiler/src/Parse/Type.hs ·
https://github.com/eeue56/derw/blob/main/LANGUAGE_FEATURES.md ·
https://github.com/mint-lang/guide/blob/master/reference/records.md · https://github.com/mint-lang/mint/releases

### Haskell and PureScript
https://www.haskell.org/onlinereport/haskell2010/haskellch2.html#x7-210002.7 ·
https://www.haskell.org/onlinereport/haskell2010/haskellch10.html#x17-17800010.3 ·
https://github.com/tibbe/haskell-style-guide/blob/master/haskell-style.md ·
https://kowainik.github.io/posts/2019-02-06-style-guide ·
https://www.tweag.io/blog/2019-10-11-ormolu-first-release/ ·
https://github.com/tweag/ormolu/issues/497 · /710 · https://fourmolu.github.io/config/comma-style/ ·
https://github.com/ghc-proposals/ghc-proposals/pull/87 ·
https://mail.haskell.org/pipermail/ghc-devs/2014-September/006397.html ·
https://github.com/purescript/documentation/blob/master/language/Records.md ·
https://github.com/natefaubion/purescript-tidy ·
https://discourse.purescript.org/t/announcing-purs-tidy-a-syntax-tidy-upper-for-purescript/2524

### Roc
https://raw.githubusercontent.com/roc-lang/roc/0.0.0-alpha2-rolling/www/content/tutorial.md ·
https://github.com/roc-lang/roc/blob/main/docs/mini-tutorial-new-compiler.md ·
https://github.com/roc-lang/roc/pull/11567 · https://raw.githubusercontent.com/roc-lang/roc/records-langref/docs/langref/records.md ·
https://raw.githubusercontent.com/roc-lang/roc/main/src/fmt/fmt.zig ·
https://raw.githubusercontent.com/roc-lang/roc/main/src/parse/AST.zig ·
https://raw.githubusercontent.com/roc-lang/roc/main/src/parse/Parser.zig ·
https://raw.githubusercontent.com/roc-lang/roc/main/test/snapshots/fmt_record_type_extension_trailing_comma_issue_9374.md ·
https://raw.githubusercontent.com/roc-lang/roc/main/test/snapshots/record_optional_defaulted_fields.md ·
https://raw.githubusercontent.com/roc-lang/roc/0.0.0-alpha2-rolling/crates/reporting/src/error/parse.rs ·
Zulip permalinks (roc.zulipchat.com): #ideas "Don't require comma when doing multiline lists?" near/276697491, 276698239, 276698250 ·
"Change tuple syntax from () to {}?" near/489527110 · "custom types" near/481035551 ·
"✔ insignificant whitespace" near/498931961, 498931833 ·
"braces syntax" near/499096002, 500474078, 500475014, 500475881, 500478811, 500495876, 500531794, 500531931, 499383497 ·
"✔ Should type annos use ::" near/525989152 ·
"Code format to single/multiline by trailing comma" near/493010354, 493031515, 493032310 ·
#compiler development "zig compiler - formatter and newlines" near/502101997 ·
"zig compiler - parser diagnostics" near/499146924 ·
"fuzz crash - handling malformed tokens and parsing" near/526199469, 526199766, 526199830, 526199885 ·
#ideas "✔ reflecting on static dispatch... and discussing removin..." near/493452520 ·
"record field operations" near/611468230, 611468305, 611468685, 611470163 ·
"Optional record field syntax" near/624823723 · #beginners "Multiline in repl?" near/274269733

### Gleam, Grain, Futhark, OCaml, ReScript, Reason, SML, Unison, Koka
https://tour.gleam.run/everything/ · https://tour.gleam.run/data-types/records/ ·
https://gleam.run/cheatsheets/gleam-for-python-users/ · https://gleam.run/news/no-more-dependency-management-headaches/ ·
https://github.com/gleam-lang/gleam/blob/main/changelog/v1.1.md ·
https://grain-lang.org/docs/guide/data_types · https://grain-lang.org/blog/2021/09/04/grain-formatter/ ·
https://futhark.readthedocs.io/en/latest/language-reference.html · https://futhark-book.readthedocs.io/en/latest/language.html ·
https://ocaml.org/manual/latest/typedecl.html · https://ocaml.org/manual/latest/inlinerecords.html ·
https://ocaml.org/manual/latest/ocamldoc.html · https://ocaml.org/p/ocamlformat/latest/doc/manpage_ocamlformat.html ·
https://rescript-lang.org/docs/manual/record · https://forum.rescript-lang.org/t/rescript-formatting-options/3199 ·
https://reasonml.github.io/docs/en/record#single-field-records ·
https://smlfamily.github.io/sml97-defn.pdf ·
https://www.unison-lang.org/docs/language-reference/record-type/ ·
https://www.unison-lang.org/docs/language-reference/lexical-syntax-of-blocks/ ·
https://koka-lang.github.io/koka/doc/book.html · https://koka-lang.github.io/koka/doc/book.html#sec-layout ·
https://raw.githubusercontent.com/koka-lang/koka/dev/doc/spec/tour.kk.md · https://raw.githubusercontent.com/koka-lang/koka/dev/doc/spec/spec.kk.md

### Practitioner threads
Hacker News items (news.ycombinator.com/item?id=…): 13370125, 14873538, 14874038, 14874277, 13621507,
13622621, 33457081, 33456396, 33456483, 33456085, 34270553, 36256606, 16798065, 37806858, 14620413,
14620958, 11459921, 42275808, 33503200, 8668468, 43018298, 43011270, 6936052, 8666747, 5639263,
8499874, 7048181, 34749177, 48663399, 47253736, 43549303, 27151732, 14388242, 28918044, 44932547,
45056257, 46231804 ·
https://lobste.rs/s/5feang/how_about_trailing_commas_sql · https://dev.to/tao/the-case-for-comma-leading-lists-3n49 ·
https://hoffa.medium.com/winning-arguments-with-data-leading-with-commas-in-sql-672b3b81eac9

### Not found

Practitioner sentiment on Lean 4 `structure` layout; a verbatim
malformed-field error from Lean; Louis Pilfold's rationale for Gleam's
braces; any Evan Czaplicki statement on *why* records use braces rather than
layout; Reddit threads (every endpoint returned an HTML shell); the original
venue of Tibell's trailing-comma remark; whether Roc's `##` doc comments
attach to individual record fields; whether Grain is whitespace-sensitive.

### Sub-agent reports

Five read-only research passes produced the prior-art evidence: Lean 4,
Idris 2, Agda, Koka and Unison; F#, Nim, Python, Scala 3, Kotlin and Swift;
Elm, Haskell, PureScript, Gren, Derw and Mint; Roc (via the Zulip), Gleam,
Grain, Futhark, OCaml, ReScript/Reason, SML and Rust; and practitioner
sentiment across HN, the Elm lists, Scala Contributors, the Nim forum and
Rust internals. Each was asked to quote primary sources with URLs and to say
"not found" rather than guess; the *Not found* list above is theirs.
