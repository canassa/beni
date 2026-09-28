# JSX as a built-in feature of the beni language: the design space

**Commissioned by** the project owner, 2026-09-20, after reading the browser design pass:
*"I want built in JSX in the language. Also, clone and research SolidJS 2. I want a Beni UI to be
fast, as fast as solid, the runtime cannot be a limitation."*
([`plans/queue.md`](../../../plans/queue.md), *Owner direction, 2026-09-20*, item **B-R5**.)

JSX is therefore a **language** feature — grammar, lexer, typing, formatter, codegen — and CLAUDE.md
rule 1 says it is specified before it is built. This report is the evidence and the option space for
that specification. **It does not decide.** §12 lists the five decisions that are the owner's.

This is one of three reports commissioned together. [`research/27`](27-solid-2-as-built.md) is
**Solid 2 as built**, including what its JSX compiler emits; [`research/29`](29-rendering-measured.md)
is **how fast, measured**. This report cites both and duplicates neither: where a claim about Solid's
*output* or about *speed* would belong to them, it is named and left there.

Every beni code sample is valid under [`language.md`](../language.md) today except the proposed JSX
forms, which are marked **`[proposed]`**.

---

## 0. Findings

**The one-line answer.** beni can have JSX for a smaller price than any language in the prior art,
and the reason is three properties it already has: **`<` is never a prefix operator** (so the
position is free, with zero lookahead), **shadowing is an error** (so the intrinsic-versus-component
problem that every other language solves with a capitalisation convention *does not exist*), and
**string literals already carry typed interpolation** (so text children need no lexer mode). Take
quoted text children, admit an element only where an operand starts, and the entire feature is a
**parser** feature: `0–30` lines in the lexer, `≈1 300–1 900` lines of Zig in total, and no change
to the checker's core, the cache format, the interface hash or the throughput budget.

**The uncomfortable finding, stated up front.** The compiler's ability to split a static template
from dynamic holes — the thing that makes Solid fast — **does not depend on JSX**. A pass that
recognises `Html.div [literal] [literal]` structurally can do exactly the same, and should, because
then the plain-call form is never the slow path. What JSX genuinely buys over
`div [ class "x" ] [ text "hi" ]` is **typed child holes** (`{name}` with `name : String` compiles to
a text-node update, with no `Html.text` wrapper ever written), a syntactic guarantee that the
structure is literal, and familiarity. That is the honest accounting (§8.1, §10), and it means JSX
and the performance work can — and should — be sequenced independently (J5).

### The ten findings, in order of value

1. **beni tokenises the whole file before the parser runs** (`src/lex/Tokenizer.zig:119-127`,
   `src/Session.zig:774, 825`), so the parser cannot steer the lexer the way Babel, TypeScript and
   old ReScript do. **This single fact decides the shape of the feature**: bare text children would
   need the tokenizer to track element nesting — a mini-parser inside the lexer, whose state must
   also survive the front-end cache's token stream. Quoted children need **no lexer change at all**. (§3.1,
   §4.2)
2. **A JSX element with quoted children already tokenises today.** `q = <div class="a">` and
   `q = <input type="text"/>` produce exactly the token sequence a JSX parser wants; the only
   diagnostic is the parser's `unexpected_token` at the `<`. The complete lexical bill is **one new
   token** (`...`, for spread) and **two parser-level joins** (hyphenated names, keyword attribute
   names). (§3.2)
3. **Prefix `<` is a free position, and this is stronger in beni than in JavaScript.** `canStartAtom`
   (`src/parse/Parse.zig:1468-1473`) does not list `op_lt` and `parseAtom`'s `else` arm is
   `unexpectedExpr` (`:1720`), so `<` at operand start is a syntax error in every beni program that
   exists or could exist. beni has no `<T>` type-assertion or type-argument syntax in expressions, so
   TypeScript's `.tsx` `<T,>` wart — a fixed three-token lookahead in
   `ts/tsc/internal/parser/parser.go:4340-4366` — has **no beni analogue**. (§3.3)
4. **One restriction is forced, and it is one line.** `f a <b` is a *legal comparison today*, so `<`
   may not join `canStartAtom` and **an element may not be a bare application argument** — write
   `f (<div/>)`. This puts an element in the same class as a `let`, `if`, `case` or lambda, which
   `language.md` §3 already excludes from bare argument position. It also means beni needs **none**
   of the heuristics the prior art was forced into: Scala's preceding-token whitelist, Imba's
   previous-character `TYPE_GENERICS_AFTER` test (`lexer.mjs:1021`), ReScript's
   whitespace-and-line-number demotion (`res_core.ml:2390-2395`). (§3.4, §2)
5. **Essentially every markup DSL embedded in a non-JavaScript host requires quoted text children** —
   Mint (`src/parsers/html_body.cr:21`), ReScript (`res_grammar.ml:264`), Dioxus
   (`packages/rsx/src/node.rs:37-39`), Yew (`html_node.rs:42-51`), Sycamore (`parse.rs:25-26`),
   Imba (`<h1> "Hello"`). Marko, which allows bare text, had to invent a `--` fence for it. **The one
   system that does allow bare text is the proof, not the counter-example**: Leptos accepts it via
   rstml's `RawText` reconstructed from `Span::source_text()`
   (`leptos_macro/src/view/mod.rs:731-735`), and its own book documents the result — *"can
   occasionally cause spacing issues around punctuation, and does not support all Unicode
   strings"* — with a worse failure mode the docs do not mention: source-text recovery is
   unavailable when the input came from another macro. And the payoff of quoting compounds: **the
   formatter provably cannot change what the page says**, because `language.md` §9 already forbids it
   to touch bytes inside a literal. Mint's formatter re-splits a long text child **mid-word** and the
   output is byte-identical (`spec/formatters/html_content_multiline`) — no JSX formatter can do
   that. (§4, §7)
6. **The intrinsic-versus-component problem does not exist in beni.** Everywhere else, a capitalised
   tag means "component" because a local `div` might shadow the intrinsic. beni forbids shadowing
   (`language.md` §7), so `<div>` has exactly one meaning in a file, always. A tag name can therefore
   be **an ordinary name**, resolved by §6.2's existing rules — which is also the direction Solid 2.0
   moved for dynamic components (a `dynamic()` factory returning a value, replacing the
   `<Dynamic component={…}>` element). (§6.1, J2)
7. **Props are one record, and beni's gap is optional fields.** ReScript moved v3→v4 from curried
   labelled arguments to a single props record, and its stated reason was **inference**, not
   ergonomics (release 10.1: `<Button variant=Primary/>` instead of `<Button variant=Button.Primary/>`).
   With no currying, beni has no alternative anyway. ReScript pays for it with *optional record
   fields* (`{a?: 'a}` at type, literal and pattern level) and compiles defaults to a `switch` in the
   body. beni does not have optional fields — and **does not need them**: a component module exports
   `defaults : Props` and `<Card title="x"/>` is `Card { Card.defaults | title = "x" }`, which is
   `language.md` §6.3's record update, unchanged. Spread falls out of the same rule. (§6.2)
8. **The element table belongs to the platform, not to the compiler.** `boundary.md` §5.2 already has
   the mechanism — a platform declares `program` and `runtime` in its manifest, *"the smallest thing
   that is a real declaration rather than a hardcoded special case"*. ReScript keeps `JsxDOM.domProps`
   (622 lines) in the **runtime package**, not the compiler. Solid 2.0 **moved JSX types out of core
   into renderer packages**, writing down that binding them to the core package had been a mistake
   (`documentation/solid-2.0/09-typescript-jsx.md`). Three independent confirmations of the same
   rule. (§5.1, §8.2)
9. **beni does not need Solid's control-flow components.** `<Show>`, `<Switch>` and `<For>` exist
   because *"a Solid component is only run once"* and a ternary in the body would freeze. Under W1's
   answer — a pure `sync` `view` returning a data tree — a `case` inside `{…}` is just an expression,
   and each branch is its own static template. Keys, however, are a real correctness matter and Solid
   2.0's lesson is sharp: **"what is keyed" fully determines "what is reactive"**, and it collapsed
   `For`/`Index` into one `keyed` axis. In beni, keys should be a **type** (`Keyed msg` from
   `Html.keyed`), with a default-on **warning** — not a proof — for an unkeyed dynamic list, because
   "this list can reorder" is not decidable. (§4.5, §4.6)
10. **Namespaced attributes are a dead end, on Solid's own evidence.** Solid 1.x's `on:`, `attr:`,
    `prop:`, `bool:` and `use:` all ride on JSX's `JSXNamespacedName` production. **Solid 2.0 removed
    every one of them** (`packages/solid/CHEATSHEET.md:463, 639-641`): *"No `attr:` / `bool:` / `on:`
    / `oncapture:` namespaces."* `use:` became `ref={fn}`; `classList` became `class={{…}}`. beni
    should not add them; an ordinary attribute name plus `Html.attribute "data-foo" "1"` covers
    everything and withholds nothing. (§5.2)

### What the prior art taught, one line each

| System | The lesson |
|---|---|
| **Mint** | An Elm-like language *can* have built-in HTML, and it requires quoted text children (`src/parsers/html_body.cr:21`) — but it pays for markup with the **only** line-sensitivity in its grammar (`src/parsers/operator.cr:56`) and a speculative full parse of the right operand (`:66`) |
| **ReScript v4** | `<` needs **no lexer mode** if JSX is reachable only from atomic position (`res_core.ml:2111`) — they *deleted* the modes v11 had; and props became one record because it makes **inference** better, not because it is prettier |
| **Reason/OCaml ppx** | Curried labelled args plus a trailing `()` — pure currying tax, and exactly what v4's record form deleted. beni never has it |
| **Scala 2 → 3** | The only officially stated reasons for removal are **parser and spec complexity**; Odersky's own words on the mis-parse: *"a non-obvious interaction between the XML parser (which I don't know) and the normal parser"* (scala3#8214) |
| **Imba** | Indentation-as-children genuinely works and reuses the existing INDENT/OUTDENT stack (`lexer.mjs:658-660`) — but `<` needs a previous-character hack, `>` is overloaded four ways, and `[`/`(` change meaning inside a tag |
| **Leptos / Dioxus / Yew / Sycamore** | Four independent Rust macro DSLs, all with quoted text children, all resolving intrinsic-vs-component by capitalisation, all emitting templates |
| **Solid 2.0** | Namespaced attributes were removed wholesale; `<Dynamic>` became a value-returning factory; JSX types moved out of the core package into renderers |
| **TypeScript** | Its `<T,>` wart is **self-inflicted** — TS put `<` back into prefix position. A language that never does gets JSX with zero lookahead |
| **Feliz / Lustre / Elm** | The list-of-calls baseline is genuinely good, and Lustre says so as a feature: *"No templates, no macros, just Gleam"* (`README.md:68`) |
| **Compose / SwiftUI** | Markup as ordinary calls with trailing lambdas: control flow inside markup comes **free** rather than being reinvented as `v-if`/`{#each}` |

---

## 1. Method

Read-only. No compiler code was changed. The only repository output is this file.

**Clones** (all under the session scratchpad, never in the repository):

| Project | Commit | Date |
|---|---|---|
| `mint-lang/mint` | `4e15025bd338f6dee66f138d82f7eacbcb630198` | 2026-09-11 |
| `rescript-lang/rescript` (`13.0.0-alpha.7`) | `e35c08a86cd077bf53d938fbe7a5291fed49da00` | 2026-09-16 |
| `facebook/jsx` | `d614ce76e6ea996ea6dfa122f2a7be71ed96e6eb` | 2022-08-04 |
| `microsoft/TypeScript` (now the Go port) | `f29aeb9f825d96feea27841f3f7342dbf0df68a8` | 2026-09-19 |
| `solidjs/solid` | `main` `b25c5577` (v1.9.15) · `next` `be46a04d` (2.0) | 2026-09-04 / 2026-09-19 |
| `lustre-labs/lustre` | `e5ca4d8b647c2c13f2f42f51d500c2198a7a4d19` | — |
| `imba/imba` | `5d0f0ebb9c9f8a65723d87c3e40386445dd2c7f9` | — |
| `leptos-rs/leptos`, `DioxusLabs/dioxus` | see §2.4 | — |

**Experiments.** Every claim about what beni's lexer and parser do today was run against the
installed `./zig-out/bin/beni` on scratchpad files, with `dump --stage=tokens`, `dump --stage=ast`
and `check --diagnostics=json`. The transcripts are quoted inline (§3.2, §3.4).

**Sources.** A claim about another system cites `path:line` in a clone at the commit above, or a
primary URL. Where the sub-agents could only find a secondhand account, this report says so.

---

## 2. Prior art, read from source

### 2.1 Mint — the closest existing thing

Mint is an Elm-inspired language with HTML built into the grammar, plus components, styles and
stores. It is the single most relevant system in the survey, and the most instructive about cost.

**The grammar** (`src/parsers/html_element.cr:3-69`, `html_component.cr:3-53`, `html_body.cr:3-49`):

```
html_element   := '<' lowercase-name-with-hyphens ('::' style+)? ('as' var)? html_body
html_component := '<' Uppercase(.Uppercase)*                      html_body
html_body      := attribute* '/'? '>'  ( child* '</' tag '>' )?
```

Five things worth carrying into beni's design:

1. **Text must be quoted.** `html_body.cr:21` is `items = many { comment || expression }` — children
   are *expressions*, full stop. There is no text-node production anywhere in `src/parsers/`.
   `<p>text</p>` parses `text` as a variable reference and fails with `variable_missing`. The
   corollary is that **there is no whitespace collapsing, because there is no text node to collapse**.
2. **There is no element or attribute table.** `grep '"div"' src/` returns nothing; an unknown element
   compiles straight to `createElement("mycustomel", {})` and an unknown attribute is typed `String`
   (`src/type_checkers/html_attribute.cr:45-47`). Only a handful of names are special-cased: `on*` is
   an event function, `readonly`/`disabled`/`checked` are `Bool`, `style` is a style map, and `ref`
   and `className` are **hard errors** redirecting to `as` and `class` (`:29-42`).
3. **An event handler is `Function(Html.Event, a)` or `Function(a)`** — one flat record type,
   `core/source/Html/Event.mint:1-56`, with every field of every DOM event pre-declared and a runtime
   `Proxy` filling in defaults (`runtime/src/normalize_event.js:30-60`). The return type is an
   unconstrained variable.
4. **Keys are just a string attribute.** There is no keyed `for`; `key` on a component is
   special-cased to `String` (`src/type_checkers/html_attribute.cr:74-87`) and on an element it falls
   through to the generic `String` rule and reaches Preact's `createElement`.
5. **Properties have defaults, and defaults drive optionality**
   (`src/type_checkers/html_component.cr:29-37`): a property without a default is required at the
   call site. `children` is hard-coded to be `Array(Html)` and to have a default
   (`src/type_checkers/property.cr:59-69`), and properties **may not be generic** (`:49-57`, *"not
   supported this time"*).

**What it costs Mint.** A repo-wide grep for positional sensitivity in the parsers returns **exactly
one hit** — and it is the markup rule:

```crystal
# src/parsers/operator.cr:52-76
when "<"
  # If we are in a different line then left side then it's probably not a operation
  next if start_position.line < position.line
  # If the right side parses as a base expression
  next if parse { whitespace; base_expression }
  # prevents parsing `</div>` as a regexp literal
  next if next_char == '/'
```

So Mint's `<` is disambiguated by (a) a line-number comparison, (b) a **full speculative parse** of
the right-hand side, thrown away on failure by the parser's snapshot/rollback
(`src/parser.cr:32-50`), and (c) a raw next-character peek. beni's LL(k) parser has no backtracking
and `fast-compiler.md` §2's budget is why. **beni cannot copy this, and does not need to** (§3.4).

**Codegen** is Preact, one `createElement` per element, **no template splitting**
(`src/compilers/html_element.cr:92-96`). Fragments are collapsed at compile time.

**The formatter** normalises `<div></div>` to `<div/>` (`src/formatters/html.cr:31-32`) and breaks
attributes all-or-nothing (`src/formatter.cr:60-69`). And it does the thing that proves finding 5: a
long text child is re-split across a `\` string continuation **at a different point, mid-word**, and
the output is byte-identical because `\` is pure concatenation
(`spec/formatters/html_content_multiline`).

### 2.2 ReScript v4 — JSX in an ML family, and the lexer modes they deleted

**The `<` decision is grammatical, not lexical.** `grep jsx src/res_scanner.ml` returns **zero hits**;
`<` is scanned unconditionally (`res_scanner.ml:954-961`), and JSX is reached from one place:

```ocaml
(* compiler/syntax/src/res_core.ml:2111, in parse_atomic_expr *)
| LessThan -> parse_jsx p
```

Multi-character operators (`<=`, `>=`, `>>`) are **re-formed on demand in operator position only**
(`res_parser.ml:193-203`), which is what lets `array<option<int>>` close naturally with no mode.
`ParserCursor.md:44-58` is the design note; `:127-130` records the abandoned `Diamond` PoC.
**v11 had modes and they were removed** — `jscomp/syntax/src/res_scanner.ml:5, 30, 32` in `v11.1.4`
had `type mode = Jsx | Diamond`, `setJsxMode`, and a fused `LessThanSlash` token (`:805-823`).

There remains one heuristic, and it is the cost of allowing JSX in infix position:

```ocaml
(* res_core.ml:2390-2395 — demote an infix `<` back out of the binary loop *)
| (Minus | MinusDot | LessThan | Percent)
  when (not (Scanner.is_binary_op p.source …))
       && (Parser.start_pos p).pos_lnum > (Parser.position p).pos_lnum -> -1
```
with `is_binary_op` at `res_scanner.ml:1059-1074` testing *whitespace on both sides*. So in ReScript
`a < b` is comparison and `a\n<div/>` is JSX, but `a <b` **on the same line is still comparison**.
beni's answer (§3.4) is stricter and needs no heuristic.

**No bare text.** `is_jsx_child_start = is_atomic_expr_start` (`res_grammar.ml:264`), and children are
parsed with `~no_call:true` so that adjacent children do not become an application
(`res_core.ml:2951-2971`). `React.string` is mandatory and is a `%identity` external
(`packages/@rescript/runtime/Jsx.res:8-16`); the docs are explicit that this is deliberate — *"which
is actually a good thing because it's also a huge source for subtle bugs"*.

**v3 → v4, and why.** v3 compiled `<Comp a=1/>` to a curried call through `makeProps`; v4 compiles it
to `React.jsx(Comp.make, {a: 1})`. The stated reasons, from primary sources:

- *"Remove as much magic / use the language as much as possible"* — the forum kickoff.
- *"With the introduction of more general structural typing most of the JSX ppx could be removed. In
  particular, one could just use functions from the language directly."* — RFC issue 521.
- **Inference**, from the 10.1 release post: *"With the earlier JSX version, you'd often need to write
  `<Button variant=Button.Primary text="Click" />`. With JSX v4, you won't need to tell the compiler
  where the variant you're passing is located: `<Button variant=Primary text="Click" />`."*

That last is the deep one: a **nominal props record gives the checker a known expected type at each
field**, which drives type-directed disambiguation. It is an argument that transfers to beni
unchanged.

**Optional props.** v4 needs optional *record fields* — `{a?: 'a}` at type level, `{a: ?e}` at
literal level, `{a: ?__a}` at pattern level (`jsx_v4.ml:161-190`) — and compiles a default into a
`switch` **in the body**, so a later default can see an earlier parameter:

```rescript
type props<'a, 'b> = { a?: 'a, b?: 'b }
let make = ({a: ?__a, b: ?__b, _}: props<_, _>) => {
  let __a_value = switch __a { | Some(a) => a | None => 2 }
  …
```
(`tests/syntax_tests/data/ppx/react/expected/defaultValueProp.res.txt:1-23`.) **beni has no optional
record fields** — §6.2 is about not needing them.

**Components** are decided by capitalisation, syntactically, with no lookup: `<Foo.Bar/>` →
`Foo.Bar.make`, `<Foo.bar/>` → `Foo.bar` (`jsx_v4.ml:1305-1314`), and **a lowercase tag cannot be
shadowed** because `<div/>` becomes the string `"div"` (`:1336-1346`). **Intrinsics** are one closed
record type, `JsxDOM.domProps`, 622 lines, **in the runtime package** — with `@as("aria-current")` for
hyphenated names and `dangerouslySetInnerHTML` as the single raw escape. **Spread** is record update:
head position only, at most one, and the spread value must have *exactly* the props type
(`jsx_v4.ml:1155-1192`); children spread was **removed** (`res_core.ml:264-265`).

**The formatter** groups attributes all-or-nothing (`res_printer.ml:4602-4620`) and joins them back
up when they fit; children get a hard line break when there is more than one or any of them is an
element (`:4760-4769`); and it **deliberately does not normalise `<div></div>`** — *"JSX elements
keep their closing tag"* (CHANGELOG, PR 8561). That is the opposite of Mint, and it is J4.

**The structural lesson**, which is the most copyable thing in this section: since PR 7286 ReScript
**parses JSX into first-class AST nodes** (`Pexp_jsx_element`, `jsx_prop = JSXPropPunning |
JSXPropValue | JSXPropSpreading`) and lowers them in a **separate pass**. It is what makes the
canonical formatter exact and keeps the ambiguity in the grammar rather than in the lexer. beni's
`Ast` → `Bir` split is already this shape.

### 2.3 The JSX specification, and TypeScript's typing

**What the spec is.** JSX extends **`PrimaryExpression` and nothing else** (`spec.emu:54-58`). The
productions are `JSXElement`, `JSXSelfClosingElement`, `JSXFragment`, `JSXOpeningElement`,
`JSXClosingElement`, `JSXAttribute`, `JSXSpreadAttribute`, `JSXNamespacedName`, `JSXMemberExpression`,
`JSXText`, `JSXChildExpression` (`spec.emu:65-187`). A tag name may carry `-`
(`JSXIdentifier … [no WhiteSpace or Comment here] '-'`, `:88-91`) — which is why `data-foo` works.
Opening and closing tag names must be **source-text** equal (`:107-115`).

**`JSXText` excludes exactly four characters** (`spec.emu:180-181`):

```
JSXTextCharacter :: JSXStringCharacter but not one of `{` or `<` or `>` or `}`
```

and there is **no escape mechanism**: you cannot backslash-escape `<`; you write `{'<'}` or `&lt;`.

**The spec defines no whitespace rule.** There is no production, no early error and no static
semantic anywhere in `spec.emu` that mentions whitespace in `JSXText`. *"JSX is an XML-like syntax
extension to ECMAScript **without any defined semantics**"* (`README.md:7`). The actual rule is
Babel's `cleanJSXElementLiteralChild`, which TypeScript reimplements
(`tsc/internal/transformers/jsxtransforms/jsx.go:795-851`, whose doc comment states the equivalent
algorithm). Paraphrased:

> split on newlines; replace tabs with spaces; strip leading spaces on every line but the first and
> trailing spaces on every line but the last; drop empty lines; join the rest with a single space;
> if the result is empty, emit **no child at all**.

Note the subtleties React's own prose omits: leading whitespace on the *first* line and trailing
whitespace on the *last* line are **preserved**, and `<a> </a>` (whitespace with no newline) survives
verbatim as `" "`. **Adopting bare text means adopting this**, and pinning the formatter to it
forever.

**Entities.** The spec defines the *grammar* (`spec.emu:194-241`) — decimal, hex, and the **252 HTML4
named references**, explicitly excluding HTML5's 2 231 — and leaves decoding implementation-defined,
naming Babel (in the parser) and TypeScript (in a transformer) as the two placements. The trade is
stated: entities in, **backslash escapes out** (`:197`).

**The `<` ambiguity in TypeScript is self-inflicted.** In plain ECMAScript `<` occurs *only* as the
infix relational operator — it appears in none of the productions that can begin a
`UnaryExpression`/`PrimaryExpression` — so handing a prefix `<` to JSX removes no valid program.
TypeScript **added** prefix `<` (`<T>expr` assertions, `<T>` type parameters), and pays for it: angle-
bracket assertions are banned outright in `.tsx`, and the generic-arrow case is a fixed **three-token
lookahead** (`tsc/internal/parser/parser.go:4340-4366`) — after `<` and an identifier, a third token
of `,` or `=` means arrow, `extends` means arrow *unless* followed by `=`, `>` or `/`, and anything
else means JSX. Hence `<T,>`, `<T = X>` and `<T extends unknown>`. **beni has no prefix `<` and
should never acquire one.**

**Typing.** `JSX.IntrinsicElements` maps a lowercase tag name to a props type; *"if this interface is
not specified, then anything goes"*. The intrinsic/value-based rule is **first character only**
(`TSJSX.md:70`; `checker/utilities.go:1160` also treats a namespaced name as intrinsic). `key` is
**not** compiler-special — it is a member of `JSX.IntrinsicAttributes`, a framework-attributes bag the
library injects into every element's props. `children` is desugared into a **prop** whose name comes
from `JSX.ElementChildrenAttribute`. Spread is ordinary assignability. And there is a revealing
hole: *"If an attribute name is not a valid JS identifier (like a `data-*` attribute), it is not
considered to be an error if it is not found in the element attributes type."*

### 2.4 Rust: markup embedded by macro

Four independent designs in a typed, non-JavaScript host language. Commits:
`leptos-rs/leptos` `6196370` (2026-09-18), `DioxusLabs/dioxus` `fda3dc9` (2026-09-16),
`yewstack/yew` `bfa6c19` (2026-08-26), `sycamore-rs/sycamore` `48e55bb` (2026-08-30).

**Text children.** Three of four require a quoted literal; the fourth is the exception that proves
the rule.

| DSL | bare text? | evidence |
|---|---|---|
| Dioxus `rsx!` | no | `BodyNode::parse` takes text only on `stream.peek(LitStr)` — `packages/rsx/src/node.rs:37-39` |
| Yew `html!` | no | `HtmlNode::peek` = `cursor.literal()` — `html_node.rs:42-51`; the golden `element-fail.stderr:49` says `<div>Invalid</div>` is `error: expected a valid html element` |
| Sycamore `view!` | no | `Node::peek_type` → `Text` only on `input.peek(LitStr)` — `parse.rs:25-26` |
| Leptos `view!` | **yes, lossily** | `Node::RawText` → `raw.to_string_best()` — `leptos_macro/src/view/mod.rs:731-735` |

Leptos's book states the bill: *"Due to limitations of Rust proc macros, using unquoted text can
occasionally cause spacing issues around punctuation, and does not support all Unicode strings…
they can always be resolved by quoting the text node as an ordinary Rust string."* The mechanism is
`Span::source_text()`, which is **unavailable when the tokens came from another macro** — so bare
text silently degrades under composition. A language that owns its lexer does not have limitations 1
and 2; it still has the fourth one, which is the real question: **at the first token after `>`, is
this text or an expression?** Quoting makes that a one-token decision.

Dioxus takes the other honest route: text is a quoted literal that *contains* holes,
`"Hello {name}!"`, parsed by its own `ifmt` scanner over the literal's contents
(`packages/rsx/src/ifmt.rs:128-191`), so the tag body is a pure list of items and text never competes
with expressions for a position. For beni this is available almost for free, because
`language.md` §2.6's `"…${e}…"` **is already exactly that** — which is why §4.2(b) is cheap here and
was not cheap for Dioxus.

**Intrinsic versus component** is capitalisation in Leptos (of the *last path segment*,
`leptos_hot_reload/src/parsing.rs:50-65`) and Sycamore, and **four orthogonal signals** in Dioxus —
a dash means a web component, a leading lowercase means an element, an underscore means a component,
a multi-segment path means a component (`packages/rsx/src/node.rs:72-113`). Worth noting as the
caution it is: that is a lot of surface for one question, and beni needs none of it (§6.1).

**Unknown names are resolved by the host's name resolution, not by a table in the macro.** Leptos
lowers `<div>` to `::leptos::tachys::html::element::div()` and an attribute to a typed method
(`view/mod.rs:944-982`, `:1167-1185`); Dioxus lowers to an associated const `html::div` and a typed
extension method (`packages/rsx/src/template_body.rs:607-684`). The vocabulary is a macro-generated
table in the *library* (`tachys/src/html/element/elements.rs:228+`,
`dioxus/packages/html/src/elements.rs:15+`), never in the compiler. **An unknown element or
attribute is therefore an ordinary "no method named `hreff`" error** — decent, with rustc's "did you
mean", but it leaks the generic view type into the message, and neither project uses
`#[diagnostic::on_unimplemented]` on that path. That is the concrete error-quality cost of the
lower-to-method-calls strategy, and beni can do better because its diagnostics are its own.

**The escape hatch for an unknown attribute is, in three of four, quoting the name**: Dioxus
`"data-foo": v` (`packages/rsx/src/attribute.rs:272-283`, whose doc comment says exactly why),
Sycamore `"data-foo"=v` (`ir.rs:57`), Leptos an `attr:` prefix or a `-` in the name
(`view/mod.rs:1157-1166`). **Quoted-name-means-untyped is a good, cheap, greppable convention** and
§5.2 adopts it.

**Control flow.** Dioxus and Yew have first-class productions in child position — `BodyNode::ForLoop`
and `BodyNode::IfChain` (`packages/rsx/src/node.rs:12-33`), each branch becoming **its own nested
template** (`forloop.rs:39-53`, `ifchain.rs:13-73`); Yew adds `while`, `loop` and `match`. Leptos and
Sycamore have none, and use `<Show>`/`<For>` components instead — for Solid's reason, which Leptos's
book states plainly: *"`<Show/>` memoizes the `when` condition… for a very simple node a
`move || if …` will be more efficient. But if it's at all expensive to render either branch, reach
for `<Show/>`."* `Show`'s body is literally `match memoized_when.get() { true => Either::Left(…),
false => Either::Right(…) }` (`leptos/src/show.rs:23-29`) — **branch types unified structurally**,
which is how each branch keeps a static template. beni's `case` gives the same thing for free
(§4.5).

**Props** are a generated struct with a type-state builder. Leptos's `#[component]` emits a
`NameProps` deriving `typed_builder` (`leptos_macro/src/component.rs:585-600`) with
`#[prop(optional)]`, `#[prop(default = expr)]`, `#[prop(into)]`; an unset slot is `()` in the
builder's type and `.build()` is implemented only when every required slot is filled. Yew's
`#[derive(Properties)]` with `#[prop_or_default]` produces the best missing-field message of the
four — `error[E0277]: not all required properties have been provided for 't3::Props'` with the span
labelled `missing required properties`. **And Leptos has to pay a visible wart for the encoding**:
`nostrip:` optionals cannot go through the builder at all and become post-build field assignments
(`view/component_builder.rs:81-97`) — the sub-agent's note is the right one, *"a language with
first-class optional fields wouldn't need it"*. §6.2 is about getting the same effect from record
update, which beni already has.

**Keys.** Leptos's `<For each= key= children=>` takes `key: KF where KF: Fn(&T) -> K, K: Eq + Hash`
and **`key` is not optional** — there is no unkeyed `<For>` (`leptos/src/for_loop.rs:112-134`). Each
row gets its own reactive `Owner` so context provided in one row is not wiped by a sibling
(`:135-145`). Sycamore's `Keyed` is the same shape (`sycamore-web/src/iter.rs:19-80`). Yew is the
counter-example and the warning: keys are optional per node, and `VList` tracks
`fully_keyed: FullyKeyedState` (`virtual_dom/vlist.rs:21-131`) to pick a fast path, so **mixing
keyed and unkeyed children silently degrades**. Dioxus checks keys *syntactically at macro time*: a
static string key is a compile error — *"Key must not be a static string. Make sure to use a
formatted string like `key: \"{value}\"`"* (`template_body.rs:850-867`). §4.6 takes the Leptos
shape and adds beni's warning where a proof is impossible.

**What they emit.** Leptos's *default* is an **inert-HTML collapse**: a subtree with no components,
blocks or special attributes is serialised to one `&'static str` at macro-expansion time
(`view/mod.rs:301-403`) and becomes `InertElement::new(html)`, whose `build()` keeps a
`TEMPLATE_CACHE` and does `tpl.content().clone_node_with_deep(true)`
(`tachys/src/renderer/dom.rs:552-570`). The `template!` macro is the typed version
(`tachys/src/view/template.rs:11-51`), memoised by `TypeId`. **Holes are located by a
`firstChild`/`nextSibling` cursor walk, not by index paths** (`tachys/src/hydration.rs:13-98`,
`view/mod.rs:515-529`), the path implicit in the recursion order — and **client construction reuses
the hydration path verbatim**, `hydrate::<false>(…)`. Server string and client DOM share the view
types and the traversal order but are **three hand-written methods that must agree**
(`Render::build`, `RenderHtml::to_html_with_buf`, `RenderHtml::hydrate`), with a runtime hydration
panic as the check. beni has a compiler where they have a trait, and should derive both from one
description (§8.1).

Dioxus's template is a **flat, bit-packed op tape** — `Template { ops: &[TemplateOp], strings,
anchors, hash }`, `TemplateOp(u16)` (`packages/core-template/src/{data.rs:3-45, op.rs:1-66}`) — and a
hole path is a **shift register**: `TemplatePath { path: u128 }`, `next_child` = `(path << 1) | 1`
(`path.rs:8-60`). A compile-time `hash: u64` exists *"to ensure identical templates compare equal
regardless of optimization levels"*.

**The compile-time cost is real and both have scar tissue.** Leptos ships
`RUSTFLAGS="--cfg erase_components"`, documented as *"one `Arc<Mutex<_>>` allocation per closure + a
vtable dispatch per render, in exchange for substantially less monomorphization (smaller WASM, faster
compile)"* (`leptos/src/lib.rs:256-266`). Dioxus caps view tuples at 128
(`packages/rsx/src/template_body.rs:12-14`) and has `split_oversized_templates`, which halves a
sibling list into nested templates when the packed encoding would overflow (`:713-786`). **If beni
adopts a packed hole path, that overflow rule has to be in the spec before it ships.** Both costs
come from encoding the view's *shape in its type*, which lowering (i) does not do (§9.2).

**Error recovery.** All three mature systems converged independently on *recovery plus partial
output*, explicitly for IDE reasons. Leptos uses rstml with `recover_block(true)` and
`parse_recoverable(...).split_vec()` (`leptos_macro/src/lib.rs:325-328`); Yew guards its fatal errors
with `is_ide_completion()` so an unclosed tag is tolerated when rust-analyzer is driving
(`html_element.rs:127, 143`); Dioxus states it as a principle:

> *"oddly enough, we want the tree to actually be capable of being technically invalid. This is not
> usual for building in Rust — you want strongly typed things to be valid — but in this case, we want
> to accept all sorts of malformed input and then provide the best possible error messages."*
> — `packages/rsx/src/component.rs:1-17`

**beni already builds this way** (`frontend.md` §3.5: error placeholder nodes, "the tree is always
structurally complete"), which is one more place where the feature costs less here than it did
elsewhere. Yew's catalogue is the best set of messages to copy from
(`tests/html_macro/element-fail.stderr`): *"this opening tag has no corresponding closing tag"*,
*"this closing tag has no corresponding opening tag"*, *"the tag `<img>` is a void element and cannot
have children (hint: rewrite this as `<img />`)"*, *"`attr` can only be specified once but is given
here again"*.

### 2.5 The refusers, and the one that removed it

**Scala 2 had XML literals in the grammar; Scala 3 removed them.** The reference page states only the
fact and the migration to `xml"…"` interpolation. The **stated reasons** are in the scala-xml FAQ:
*"to simplify the Scala parser and compiler and the Scala language specification, the XML literal
support will eventually be dropped in Scala 3."* Two reasons, both about the compiler, neither about
XML.

The strongest primary evidence is Odersky on dotty#8214, where `val n: NodeBuffer = <hello/><world/>`
followed by `println()` mis-parses because the XML parser swallows the next line:

> *"Since I am strongly in favor of abandoning XML literals for Scala 3 I won't put effort in fixing
> this. It seems like a non-obvious interaction between the XML parser (which I don't know) and the
> normal parser."* — odersky, 2020-02-06

*"the XML parser (which I don't know)"* — the language's designer disclaiming knowledge of a
sub-parser inside his own compiler. The same bug had been open in Scala 2 for years (scala/bug#9027).
And the mechanism of the damage is the `<` rule, from the Scala 2 spec:

> *"Lexical analysis switches from Scala mode to XML mode when encountering an opening angle bracket
> '<' … preceded either by whitespace, an opening parenthesis or an opening brace and immediately
> followed by a character starting an XML name."* … *"no Scala tokens are constructed in XML mode,
> and … comments are interpreted as text."*

An ad-hoc preceding-token whitelist, plus two genuinely disjoint grammars with a mode flag between
them, plus whitespace collapsing in the spec. **The reason this report recommends quoted children,
an operand-only position and no lexer mode is that all three of Scala's wounds are then absent.**

One counter-argument from that thread is worth keeping: IDE syntax highlighting for interpolated XML
needs external configuration, which is a real cost of the string-interpolation escape route. It does
not apply to a grammar production.

**Elm.** Evan Czaplicki, on a request for JSX-like syntax:

> *"it's nice that the full power of Elm is available with elm-html. No special syntax is needed,
> it's easy to use lists or dictionaries or functions or whatever else, and you get type checking
> very easily."*
> *"my feeling is that templating languages tend to evolve into bad languages... What if your
> templating language meshed perfectly with the host language? I think you can think of elm-html as
> an answer to that question."*

The thesis is that a markup sublanguage will grow conditionals, then loops, then bindings, then
functions, each ad hoc. **Function calls start out already having all of them.** (Imba's
`<ul> for {type,title} in items` is the counter-demonstration: a tag grammar *can* get there, by
letting statements into child position.) Note also that Elm's `lazy` depends on view construction
being an ordinary function application you can defer as a value — `lazy f a` compares `f` and `a` by
reference (`guide.elm-lang.org/optimization/lazy.html`). A markup grammar has no first-class deferred
application, which is why React needs `memo` as a separate bolt-on.

**Gleam and Lustre.** Gleam's FAQ lists Lisp-style macros among features *"not planned"*, on the
grounds that *"Gleam will always be a small and cohesive language with a minimal feature set"* and
that metaprogramming must not be *"detrimental to Gleam's readability and fast compilation."*
Lustre's README states the consequence as a feature:

> *"A declarative, functional API for constructing HTML. **No templates, no macros, just Gleam.**"*
> — `lustre/README.md:68`, with *"there should be only one way to do things!"* at `:132-133`

The API is `html.div([attribute.class("x")], [html.text("hi")])`
(`src/lustre/element/html.gleam:219`, `src/lustre/attribute.gleam:148`, `:18`), i.e. Elm's shape. Its
own React-migration guide names the one real cost honestly: *"To render text you need to use the
`html.text` function"* (`pages/reference/for-react-devs.md`). **That is precisely the tax §4.4's
typed hole deletes**, and it is the clearest statement in the survey of what JSX-with-types actually
buys.

**Note for honesty:** Gleam's objection is to **macros**, which is an argument against a `view!`-style
macro and not against a grammar production. Elm's is a general "no syntax you can avoid" position.
Neither is evidence that a grammar production is wrong; they are positions.

### 2.6 Imba — an indentation-sensitive language with built-in tags

The most directly relevant precedent, because beni is indentation-sensitive.

**Indentation replaces the closing tag.** There is none:

```imba
tag login-form < form
	<self @submit.prevent=api.login(name,secret)>
		<input.username type='text' bind=name>
		<button> "Login as {name}"
```
(`imba/readme.md:48-58`.) Children are indented under the parent; **text must be quoted**
(`<h1> "Hello"`), and an unquoted word is an expression. Class and id shorthands are `.cls` and
`#id`; events are `@click=expr` with modifiers `@submit.prevent=…`; the tag type itself can be
interpolated, `<{data.type}>`. Components are kebab-case custom elements, so **intrinsic-vs-component
is decided by name shape rather than by capitalisation**.

**How it interleaves with layout** — this is the piece worth studying:

```js
// imba/packages/imba/src/compiler/lexer.mjs:658-660
Lexer.prototype.refreshScope = function (){
    var ctx0 = this._ends[this._ends.length - 1];
    var ctx1 = this._ends[this._ends.length - 2];
    return this._inTag = ctx0 == 'TAG_END' || (ctx1 == 'TAG_END' && ctx0 == 'OUTDENT');
};
```

The indented block is pushed as an ordinary `OUTDENT` scope nested inside the tag scope, so
children-by-indentation **reuses the existing INDENT/OUTDENT machinery** with a one-level peek. It is
cheaper than it looks.

**What it costs.** `<` needs a previous-character test — `TYPE_GENERICS_AFTER = /\w|\]|\)$/` at
`lexer.mjs:57`, consulted at `:1021` and `:2353` — so `a<b` and `a <b` mean different things: the
identical wound Scala had. `>` is overloaded four ways (`->`, `=>`, `/>`, `>` all end a tag header,
`:2247-2255`). `[` becomes `STYLE_START` and a spaced `(` is rewritten to `,` when `inTag`
(`:2242-2246`) — ordinary punctuation changing meaning by context. And the whole thing lives in a
2 860-line hand-written lexer with the `inTag` predicate duplicated in two places.

**The conclusion for beni.** Imba proves indentation-as-children is pleasant to write and structurally
cheap. It does **not** make the `<` problem easier — it makes it harder, because tags now appear in
statement position too. beni's element should be an ordinary expression governed by `language.md` §4
rule 6 ("brackets do not suspend layout"), with the formatter choosing the layout (§3.6).

### 2.7 What the ML and mobile worlds chose instead

**Feliz (F#/Fable)** — *"A fresh retake of the React API in Fable, optimized for happiness."* Its
stated goals are typing and discoverability, not syntax: *"no more `Margin of obj` but instead
utilizing a plethora of overloaded functions"*, and *"Approximately Zero bundle size increase where
everything function body is erased"*. The shape is
`Html.div [ prop.className "x"; prop.onClick …; prop.text "Increment" ]` — a list of values built by
namespaced **overloaded** members, giving closed-world attribute typing plus autocomplete at zero
runtime cost. §5.2's recommendation is the same shape with a different spelling. *(No statement by
its author arguing against JSX was found; the README simply never considers it.)*

**Fable.Lit** is the third axis — markup as a **typed interpolated string**,
`html $"""<div class="content">{value}</div>"""`. This is Scala 3's chosen replacement mechanism
validated in another language, and its docs itemise the bill: *"holes in interpolated strings are not
typed"*, plus a VS Code extension for highlighting.

**Compose and SwiftUI** get markup as ordinary calls with trailing lambdas and **no new grammar
whatsoever**. Compose states the payoff against XML layouts: *"Because composable functions are
written in Kotlin instead of XML, they can be as dynamic as any other Kotlin code."* SwiftUI's
`@resultBuilder` proposal (SE-0289) frames the exact tension this report is about — expression-based
tree building has "no local variables, awkward control flow", statement-based building loses the
hierarchy — and result builders are *"a compromise between these two approaches"* with no new
grammar: `if`/`for`/`let` inside a `@ViewBuilder` are **real Swift statements** mapped to
`buildEither`/`buildArray`. **Control flow inside markup comes free rather than being reinvented as
`v-if`/`{#each}`**, and beni gets the same property for the same reason (§4.5).

**Markup as a top-level declaration form** is a fourth axis, and the survey's cautionary tale lives
here. Templ (Go) confines markup to `templ Name(params) { … }` blocks; Razor makes HTML the default
language of the file with `@` transitioning to C#; Svelte and Vue make markup a *section* of a
component file; Marko starts every file in an indentation-based concise mode. Razor is the warning:
it documents the `<` ambiguity as permanent and unfixable — *"Implicit expressions cannot contain C#
generics, as the characters inside the brackets (`<>`) are interpreted as an HTML tag"*, so
`<p>@GenericMethod<int>()</p>` is **not valid** and you must write `@(GenericMethod<int>())`. Two
grammars sharing `<` produce exactly that.

---

## 3. Lexing, and the `<` question

### 3.1 The one fact that decides the shape of the whole feature

**beni tokenises the entire file before the parser runs.** `Tokenizer.tokenize` is
`while (try t.next() != .eof) {}` (`src/lex/Tokenizer.zig:119-127`), called from the per-file phase
(`src/Session.zig:774`) which then hands a finished `tokens.slice()` to `Parse.parse`
(`src/Session.zig:825`). There is no on-demand scanner and no way for the parser to tell the lexer
what mode to be in — which is exactly how Babel, TypeScript and old ReScript lex JSX, and is
therefore the one technique beni cannot copy.

The lexer *does* have modes — `mode: Mode = .normal | .string | .interp` with a brace depth
(`src/lex/Tokenizer.zig:57-59, 76`) — and string interpolation uses them (`:210-252, 317-324`). But
that mode switch is **self-delimiting**: `"` opens it, `"` closes it, `${` and a balanced `}` nest
inside it, and none of that needs to know whether the lexer stands in expression position.
`language.md` §2.6 makes a `"` inside an interpolation an error *"precisely because it would need a
mode STACK"* (`src/lex/Tokenizer.zig:20-24`).

JSX *text children* are not self-delimiting in that sense. `<p>hello</p>`'s `hello` is text only
because a tag was open, and whether `<` opened a tag is a question about expression position, which
the lexer does not have. So **bare text children require the lexer to track element nesting** — a
mini parser inside the tokenizer, whose state must also survive the front-end cache's token stream
(`frontend.md` §3.2: the cached form is `tag` and `start`, five bytes, two columns).

**Quoted string children require no lexer change at all.** That is not a stylistic preference; it is
the difference between a parser feature and a lexer rewrite. §4 spends the finding.

### 3.2 A JSX element, spelled with quoted children, already tokenises today

Run against the installed binary (scratchpad `probe/src/T.beni`):

```
$ beni dump --stage=tokens        # q = <div class="a">
1:5 op_lt <      1:6 lower_ident div    1:10 lower_ident class
1:15 equal =     1:16 str_start "       1:17 str_chunk a
1:18 str_end "   1:19 op_gt >

$ beni dump --stage=tokens        # q = <input type="text"/>
1:5 op_lt <      1:6 lower_ident input  1:12 keyword_type type
1:16 equal =     1:17 str_start "  1:18 str_chunk text  1:22 str_end "
1:23 op_slash /  1:24 op_gt >
```

Both print exactly the token sequence a JSX parser wants. The only diagnostic in either case is the
parser's `unexpected_token`: *"I was parsing a definition and ran into `<`. I was expecting an
expression."* Every other spelling checks out the same way:

| Spelling | Tokens today | Consequence |
|---|---|---|
| `</` | `op_lt` `op_slash` — the `.lt` state has no `/` arm (`src/lex/Tokenizer.zig:411-418`) | a closing tag needs no new token |
| `<>` `</>` | `op_lt op_gt`, `op_lt op_slash op_gt` | fragments need no new token |
| `/>` | `op_slash` `op_gt` | self-closing needs no new token |
| `Ui.Button` | one `qualified_upper` | a qualified tag is **one token** |
| `on:click` | `lower_ident` `colon` `lower_ident` | namespaced names would work — but §5.2 says do not |
| `data-x`, `aria-label` | `lower_ident` `op_minus` `lower_ident` | a hyphenated name needs either a **parser-level join** with `Parse.adjacent` (`src/parse/Parse.zig:279`) or §5.2's quoted-name form `"data-x"="1"`, which needs neither |
| `type`, `as` | `keyword_type`, `keyword_as` | the parser must accept **keyword tokens as attribute names**; `<input type=…>` and `<link as=…>` are the two that matter |
| `...props` | `invalid` `invalid` `dot_lower .props` — two `INVALID CHARACTER` diagnostics | **spread is the one spelling that needs a lexer change**, or a different spelling |

That table is the complete lexical bill: one new token (or an alternative spelling for spread), and
two parser-level joins. Nothing else.

### 3.3 Where a `<` may start an element, proved from the parser

`language.md` §6.5 has no prefix `<`: an expression *"may not begin with an operator, except `-` for
negation"*. The code agrees — `canStartAtom` (`src/parse/Parse.zig:1468-1473`) lists fourteen tags
and `op_lt` is not among them, and `parseAtom`'s `else` arm is `unexpectedExpr` (`:1720`). So:

> **At operand-start position, `<` is a syntax error in every beni program that exists or could
> exist today. The position is free.**

This is the property that makes JSX decidable in JavaScript (§2.3), and beni's version is
**stronger**, because beni has no `<T>` syntax in expressions at all — TypeScript's `.tsx` `<T,>`
wart has no beni analogue. ReScript arrived at the same rule from the other direction, by *deleting*
its lexer modes and reaching JSX from one place only: `| LessThan -> parse_jsx p` in
`parse_atomic_expr` (`res_core.ml:2111`).

`parseAtomAccess(true)` — operand start — is reached from `parseApp` (`src/parse/Parse.zig:1602`) and
from negation's operand (`:1704`). `parseExpr`/`parseBinop` are called at twenty-five sites. Written
as surface positions, an operand starts:

- after `=` in a definition or a record field (`:891`, `:1821`);
- after `(`, and after each `,` in a tuple (`:1755`, `:1763`);
- after `[` and after each `,` in a list (`:1778-1779`);
- inside `${…}` (`:1856`);
- after `->` in a lambda or a `case` branch (`:1902`, `:1976`);
- after `if`, `then`, `else` (`:1912-1916`);
- after `case` — the scrutinee (`:1926`);
- after `=` and after `<-` in a `let` binding (`:2012`, `:2055`, `:2075`, `:2080`);
- after any binary operator, `|>` and `<|` included (`:1557-1569`).

That list is the answer to "where may an element start", and it needs no new rule: **an element is
an `Atom`, and `op_lt` joins `parseAtom`'s switch.** Every layout rule then applies unchanged,
because §4 rule 2 is checked per token against the block indent and knows nothing about what
construct it is inside.

### 3.4 The counter-example, and the one restriction it forces

The position that is **not** free is *argument* position. `parseArgs` (`:1612-1642`) calls
`parseAtomAccess(false)` and stops at any tag `canStartAtom` rejects — which is how `f a < b` parses
today:

```
$ beni check          # q = f a <b      →  (clean)
$ beni check          # q = a <b        →  (clean; dump --stage=ast gives (lt (ident a) (ident b)))
```

`a <b` and `a < b` produce the identical AST, because whitespace around `<` is not significant.
**So `<` may not be added to `canStartAtom`**: if it were, `f a <b` — a legal comparison today —
would start parsing an element and fail at end of file.

The restriction that follows is one line:

> **An element is an operand, never a bare argument.** `f <div/>` is not a call of `f` on an
> element; write `f (<div/>)`, or `f <| <div/>`, or pipe it.

This is not a new *kind* of restriction. `language.md` §3 already says a `let`, `if`, `case` or
lambda *"may not be a bare application argument: `f \x -> x` is an error, write `f (\x -> x)`"*. An
element joins that list, and the diagnostic can say exactly that.

**And the shape it would collide with is already an error.** `<` and `>` are both precedence-4
non-associative (`src/parse/Parse.zig:1507-1512`), so:

```
$ beni check          # q = a < b > c
non_associative_chain @ 18:11   "I found a second comparison operator, `>`, in the same chain."

$ beni check          # q = f <b>a</b>
2 × non_associative_chain, 1 × unexpected_token
```

The JSX-shaped texts that argument position can parse at all are therefore a vanishingly small set —
one comparison and nothing after it. **This is what lets beni avoid every heuristic the prior art
was forced into**: Scala's preceding-token whitelist (`whitespace | ( | {`), Imba's
`TYPE_GENERICS_AFTER` test on the previous character (`lexer.mjs:1021`), ReScript's
whitespace-and-line-number demotion (`res_core.ml:2390-2395`), Mint's full speculative parse of the
right operand (`src/parsers/operator.cr:66`). beni needs **none** of them, and that matters because
its parser is LL(k) with no backtracking and `fast-compiler.md` §2's budget is why.

### 3.5 Three smaller ambiguities, and how each resolves

**`(<)`.** `parseParens` tests `p.peek().isOperator() and p.peekAt(1) == .r_paren` *before* parsing an
expression (`src/parse/Parse.zig:1740-1751`), so `(<)` is decided by two tokens of lookahead and
never reaches `parseAtom`. `( <` followed by anything but `)` is an element. No change.

**Negation.** `parseAtom`'s `.op_minus` arm calls `parseAtomAccess(true)` (`:1704`), so `-<div/>`
would be grammatical if an element were a plain atom. It should be the ordinary `unexpected_token` —
an element is not a number — by making the element production a case the negation arm does not
admit. One `if`.

**`<-`.** The lexer's longest match turns `<` immediately followed by `-` into `arrow_left`
(`src/lex/Tokenizer.zig:414-416`; `q = a<-b` tokenises as `lower_ident arrow_left lower_ident`). No
tag name can begin with `-`, so no element spelling is affected. What *is* affected is the message:
`<-div>` will say "`<-` is only legal in a `let` binding" rather than "I expected a tag name", and
the diagnostic should special-case it.

### 3.6 Layout

An element is an ordinary expression, so `language.md` §4 rule 2 governs it and nothing more: every
token must be at a column greater than the enclosing block's indent. Rule 6 — *"brackets do not
suspend layout"* — is the precedent: an element that runs off the end of a declaration is ended by
the first token at column 1 and reported at its opening tag, exactly as an unclosed `[` is. So a
missing `</div>` cannot swallow the rest of the file.

**Children are therefore free-form within the element, and indentation inside an element carries no
meaning.** Three reasons. (1) It is what rule 6 already does for brackets, so there is one rule
rather than two. (2) The formatter can then choose the layout, which is what makes `beni fmt`
canonical (§7). (3) Imba's indentation-as-nesting is the alternative and §2.6 is its bill: it does
not make the `<` problem easier, it makes it harder, because tags then appear in statement position
too.

### 3.7 Error recovery

`frontend.md` §3.5 requires a structurally complete tree; `Parse` keeps a `brackets` stack
(`src/parse/Parse.zig:517-528`) and `recover` (`:544-564`) skips to the closer of an open bracket, to
the first token left of the block, or to `eof`. An element is a bracket in exactly this sense:

- an opening tag with no closing tag → **`unclosed_element`** at the opening tag, carrying the tag
  name and the required column, the way `unclosed_delimiter` does (`:501-509`);
- a mismatched closing tag (`<div>…</span>`) → **`mismatched_closing_tag`** naming both, *recovered
  from by accepting it*, so one mistake yields one message;
- a `>` that never arrives inside an opening tag → `expected_token`, unchanged.

`isStructural` (`:534-539`) gains no member: an element's `>` and `</` are consumed by the element's
own parser.

**This is one more place where beni starts ahead.** All three mature Rust systems converged
independently on *recovery plus partial output*, explicitly for IDE reasons, and two of them
refactored into it — Dioxus writes it down as a principle: *"we want the tree to actually be capable
of being technically invalid… we want to accept all sorts of malformed input and then provide the
best possible error messages"* (`packages/rsx/src/component.rs:1-17`). `frontend.md` §3.5 already
says the same thing. Yew's catalogue is the best set of messages to copy
(`tests/html_macro/element-fail.stderr`), including the void-element one — *"the tag `<img>` is a
void element and cannot have children (hint: rewrite this as `<img />`)"* — which beni needs the
moment a platform declares which elements are void. Note that Mint has no void-element table at all,
so `<br>` is a parse error demanding `</br>` (`src/parsers/html_body.cr:35`).

---

## 4. Children

### 4.1 The question, stated precisely

JSX's `JSXText` is "any character except `{`, `<`, `>`, `}`" (`spec.emu:180-181`), and the
*semantics* — whitespace collapsing, entity decoding — are **not in the specification at all**
(§2.3). Adopting bare text means adopting Babel's `cleanJSXElementLiteralChild` algorithm verbatim
into `language.md`, and binding `beni fmt` to it forever.

beni has a third option JavaScript did not: **the language already has string literals with typed
interpolation** (`language.md` §2.6), which is the exact shape a text child wants.

### 4.2 The three options

**(a) Bare text, JSX's rules.** `<p>Hello {name}</p>`.
Costs: a lexer that must decide, for every `<`, whether it is in expression position — the parser's
knowledge (§3.1); `--` inside text becomes a comment and eats the rest of the line
(`language.md` §2.3); a tab inside text is `tab_in_source`; the formatter may never reflow text
(§7); and the front-end cache's token stream has to carry the mode.
Buys: familiarity, and markup pasted from HTML.

**(b) Quoted string children.** `<p>"Hello " {name}</p>`.
Costs: quotes, and a paste from HTML needs them added.
Buys: **zero lexer change**; interpolation for free, so `<p>"Hello ${name}"</p>` is *one* text node
rather than three children; escapes and `\u{…}` for free; `--` inside a string is already literal
text; the multiline raw-string form (`\\`) for a block of prose; and the formatter may break and
rejoin lines freely, because whitespace inside a literal is bytes it may not touch
(`language.md` §9).

**(c) No text children at all** — every child is `{expr}`, and text is `{"Hello"}`.
Costs: noise on the commonest child. Buys: one rule.

### 4.3 What everyone else chose

§2 has the citations. Mint, ReScript, Dioxus, Yew, Sycamore and Imba all require (b) or (c). Leptos
allows (a) and its own documentation calls it lossy. Marko allows it and had to invent a `--` fence.
Only JSX itself — whose lexer re-scans on parser demand — affords (a) cleanly, and even there the
whitespace rule is implementation-defined folklore.

**Recommendation: (b).** It is the only option whose cost is a keystroke and whose saving is a lexer
mode stack, a whitespace specification, a formatter restriction and a cache-format change.

### 4.4 What a child hole may be, and why the set should be closed

The child hole `{e}` is where the compiler's advantage over a library lives. If the checker knows
`e : String`, the backend can emit a text-node update; if `Html msg`, a node slot; if
`List (Html msg)`, a fragment slot with its own reconciler. A library cannot do this, because a
library receives a value, not a type.

**A closed, typed set** [proposed]:

| Hole type | Emitted as | Note |
|---|---|---|
| `String` | a text node; the update is `node.data = s` | **no `Html.text` wrapper** — the checker knows |
| `Int`, `Float`, `Bool`, `Char` | a text node, stringified | `language.md` §2.6's `interpolatable` obligation, reused |
| `Html msg` | one node slot | the ordinary case |
| `Maybe (Html msg)` | a node slot that may be empty | saves Elm's `Html.none` idiom |
| `List (Html msg)` | a fragment slot with markers | the unkeyed list; §4.6 is about keys |
| `Keyed msg` | a keyed reconciler | §4.6 |

Everything else is `child_not_renderable`, naming the type and the accepted shapes.

**This deletes the `React.string` tax, and that tax is real and documented.** ReScript's docs defend
it — *"ReScript forces explicit type conversion… which is actually a good thing because it's also a
huge source for subtle bugs"* — and Lustre's own React-migration guide names it as the cost of the
list-of-calls form: *"To render text you need to use the `html.text` function"*
(`pages/reference/for-react-devs.md`). In an ML language with a **typed** hole the conversion is the
compiler's job, because the hole's type is known before codegen. **This is the clearest thing JSX
buys beni that `Html.div [] []` cannot**, and it is worth naming precisely:
`Html.div [] [ Html.text name ]` needs the wrapper because `List (Html msg)` is one type; a typed
hole does not.

A closed set is a restriction, so rule 7 applies: it buys a guarantee — every hole has a known update
strategy, so nothing is rendered through a generic `toString` that the release optimiser is free to
change (the `debug_in_release` argument, `backend.md` §9). And the escape hatch never closes:
`Html.text (myRender x)` is always available, and `{ }` accepts an `Html msg` from anywhere.

### 4.5 Control flow in children

beni's `if` and `case` are **expressions** (`language.md` §3), so they work inside `{…}` with no new
rule. That is a real difference from Solid and Leptos, and it is worth being precise about why.

Solid needs `<Show>`, `<Switch>`/`<Match>` and `<For>` because *"a Solid component is only run once,
when it is first rendered into the DOM"* and its reactivity is fine-grained: a ternary in the body
would be evaluated once and freeze; a `.map` would recreate every node. The components exist to put
the branch behind a function the reactive system can re-run. Leptos is the same design and says so:
`Show`'s body is `match memoized_when.get() { true => Either::Left(children()), false =>
Either::Right(fallback.run()) }` (`leptos/src/show.rs:23-29`).

Under `plans/browser-decisions.md` W1's answer — a pure `sync` `view` returning a data tree — **beni's
`view` is re-run wholesale anyway**, so a `case` in a hole is just an expression producing a
different subtree. No component is needed. The compiler's job is different: **each branch is its own
static template**, and the hole's update code is "if the branch tag changed, swap templates;
otherwise update this branch's holes". Dioxus does exactly this for its `IfChain` and `ForLoop`,
each branch becoming a nested `TemplateBody` (`packages/rsx/src/ifchain.rs:13-73`,
`forloop.rs:39-53`); Leptos gets the same effect through `Either<L, R>` unifying the branch types
structurally. In beni the shape already exists: `backend.md` §7's decision tree, `src/js/Decision.zig`.

The typeahead's five states are the worked example (§11.2), and they are one `case` with five
templates.

**If beni later adopts signals** (report 25 §7, ranked fourth), this changes: a hole would need to be
a thunk and `<Show>`-shaped components come back. The syntax above serves both — `{e}` is a hole
either way — and what differs is whether the compiler wraps `e` in a closure. That is a lowering
decision, not a grammar one, and it is the neutrality the brief asked for.

### 4.6 Lists and keys

`{List.map rows viewRow}` type-checks as a `List (Html msg)` hole and works. It is also where a UI
silently does the wrong thing: an unkeyed list that reorders re-uses the wrong DOM nodes, losing
focus, input state and scroll position. Report 24 §6.5 has Elm's keyed diff and its limits (a
duplicate key is silently mangled to `key + '_elmW6BL'`); report 27 has Solid's `For`.

**The prior art is unusually clear here.**

- **Leptos makes `key` non-optional**: `<For each= key= children=>` with `key: Fn(&T) -> K,
  K: Eq + Hash`, and there is no unkeyed `<For>` (`leptos/src/for_loop.rs:112-134`). Sycamore's
  `Keyed` is the same (`sycamore-web/src/iter.rs:19-80`).
- **Yew is the warning**: keys are optional per node and `VList` keeps a `FullyKeyedState` to pick a
  fast path (`virtual_dom/vlist.rs:21-131`), so mixing keyed and unkeyed children **silently
  degrades**.
- **Dioxus refuses a static key at macro time**: *"Key must not be a static string. Make sure to use
  a formatted string like `key: \"{value}\"`"* (`packages/rsx/src/template_body.rs:850-867`).
- **Solid 2.0 collapsed `For` and `Index` into one `keyed` axis** — `keyed={true}` (identity),
  `keyed={false}` (position), `keyed={fn}` (a key function) — with the stated motivation that
  *"having both `For` and `Index` encourages bikeshedding and accidental misuse"*
  (`documentation/solid-2.0/03-control-flow.md`). The lesson it draws is the sharp one:
  **what is keyed fully determines what is reactive.**

Three ways to express a key in beni [proposed]:

1. **A `key` attribute on the element inside the loop** — React's and Elm's `Html.Keyed` in JSX
   clothing. The key is on the child, so the *list hole* cannot see it without looking inside a
   lambda the compiler did not inline.
2. **A keyed hole form** — `{for r in rows key r.id}<li>…</li>{/for}`. A second grammar inside the
   grammar, and beni has no `for`.
3. **A keyed list function whose type says so** —
   `Html.keyed : List (k, Html msg) -> Keyed msg where k.compare : k, k -> Order`, used as
   `{Html.keyed (List.map rows (\r -> ( r.id, viewRow r )))}`. The hole's type is `Keyed msg`, a
   *different type* from `List (Html msg)`, so the compiler picks the keyed reconciler **by the type
   rather than by a convention it has to trust**.

**Can the compiler REQUIRE a key?** Not soundly: "this list is dynamic" is not decidable — a
`List (Html msg)` hole may be a constant. What it *can* do is what rule 7 asks — **a warning**, on by
default for the root package, the way `ambiguous_method_receiver` is
(`static-dispatch-spike.md` §10.9): *"this list hole is not keyed; if its elements can be reordered,
inserted or removed, state below them will attach to the wrong row"*, suppressed by `Html.keyed` or
by an explicit `Html.unkeyed`. A real hazard, no proof available, so warn and give the escape hatch.

**Recommendation: option 3.** It needs no grammar, it is typed, and `where k.compare` is the
mechanism report 25 §3.1 already uses for command keys. Option 1 can be added later as sugar that
lowers to option 3 *when the lambda is syntactically present*, which is the only case it can be read
anyway.

---

## 5. Attributes, events, and where the element table lives

### 5.1 The table is a platform package's beni declarations, not compiler knowledge

Rule 6 says only a platform package may write `foreign`, and `boundary.md` §5.2 already has the
precedent for *"the platform declares what the compiler must know"*: a platform's manifest carries
`program` (the opaque type `main` must have) and `runtime` (the JS file whose `run` export receives
it) — *"the smallest thing that is a real declaration rather than a hardcoded special case, and it
is why a Bun or Deno platform needs no compiler change."*

The same mechanism serves JSX, and three independent systems confirm the rule:

- **ReScript** keeps `JsxDOM.domProps` — 622 lines, every DOM attribute and event — in the
  `@rescript/runtime` **package**, not in the compiler.
- **Leptos and Dioxus** generate their element tables in the *library* (`tachys/src/html/element/
  elements.rs:228+`, `dioxus/packages/html/src/elements.rs:15+`) and the macro contains no
  vocabulary at all.
- **Solid 2.0 moved JSX types out of the core package into renderer packages** and wrote down why:
  *"`solid-js` is the renderer-neutral UI core, but its old TypeScript surface implicitly depended
  on DOM JSX types"* (`documentation/solid-2.0/09-typescript-jsx.md`). They had to undo it.

Mint is the counter-example in the other direction: it has **no table at all**
(`grep '"div"' src/` returns nothing), so an unknown element compiles straight through and an
unknown attribute is typed `String` (`src/type_checkers/html_attribute.cr:45-47`). That is maximal
freedom and zero help; beni should not copy it either.

**A platform therefore declares an element namespace**: a module whose `pub` values are the
intrinsic elements and the attribute constructors. `<div class="x">` resolves the way any imported
name resolves, and a server-rendering platform, a native platform or a test platform declares its
own. If the compiler hardcoded HTML, the element list would version with the compiler rather than
with the platform, beni could not target anything but a browser, and `boundary.md`'s wall would have
a hole in it labelled "except markup".

### 5.2 Typing an attribute

Two shapes are available.

**(A) An element takes one closed record.** `div : { class : String, id : String, … } -> …`. An
unknown attribute is `unknown_field`, which already has "did you mean". This is ReScript's, and its
docs defend the closed record deliberately so that typos are errors. But HTML has ~100 global
attributes plus per-element ones, a closed record type per element is a very large interface, and
**every field would be mandatory** unless beni gains optional record fields.

**(B) An attribute is a value of type `Attr msg`, and the element takes a list.** That is
`Html.div : List (Attr msg), List (Html msg) -> Html msg` — Elm's, Lustre's and Feliz's design, with
JSX as the surface. `<div class="x" onClick={Clicked}>` desugars to
`Html.div [ Html.class "x", Html.onClick Clicked ] [ … ]`. An unknown attribute is
`unbound_variable` on `Html.frobnicate`, with the usual "did you mean", and nothing is withheld
because `Html.attribute "data-foo" "1"` is always there.

**Recommendation: (B)**, with the attribute name resolved in the platform-declared namespace. It
reuses every mechanism the language has; it keeps the intrinsic table out of the compiler; it gives
**better diagnostics than any of the prior art**, because Leptos's and Dioxus's unknown-attribute
error is whatever rustc says about a missing method with the view type spliced into it, and beni's
would be its own `unbound_variable` with a caret on the attribute name; and it makes JSX and the
plain-call form literally the same program, which is §10's answer to the strongest objection.

Under (B) the surface sugar is:

| Written | Means |
|---|---|
| `class="x"` | `Html.class "x"` — an ordinary string literal, with interpolation: `class="btn ${size}"` |
| `value={s}` | `Html.value s` |
| `disabled` | `Html.disabled True` — a valueless attribute is `True`, as in Leptos (`view/mod.rs:1669-1670`) |
| `{disabled}` | punned: `Html.disabled disabled` |
| `"data-foo"="1"` | **quoted name = escape the typed vocabulary** → `Html.attribute "data-foo" "1"` |
| `{...attrs}` | `attrs : List (Attr msg)`, concatenated |

**Two of those deserve their own sentence.**

*The quoted attribute name* is stolen from Dioxus (`"data-foo": v`,
`packages/rsx/src/attribute.rs:272-283`) and Sycamore (`"data-foo"=v`, `ir.rs:57`). It is cheap,
local, greppable, and it removes the need for a hyphen-join in the parser *and* for any namespaced
prefix. It also gives `aria-*` and `data-*` an honest home rather than TypeScript's accidental one
(*"If an attribute name is not a valid JS identifier … it is not considered to be an error"*).
Whether `data-x="1"` unquoted should ALSO work — the hyphen join of §3.2 — becomes optional sugar
rather than a requirement.

*Spread is trivially typed* under (B): it is a `List (Attr msg)` and `++` is its semantics, so there
is no head-position rule, no "at most one", and no "must be exactly this record type". ReScript's
spread carries all three restrictions because it is record update
(`jsx_v4.ml:1155-1192`), and the release post says so: *"this implementation has harder constraints
than its JS counterpart."* That is a real, if small, win for (B) over (A).

**Do not add namespaced attributes** (`on:click`, `attr:x`, `prop:y`, `use:d`). They would lex today
(§3.2) and Solid 1.x built its whole escape-hatch vocabulary on them — and **Solid 2.0 removed every
one**: *"Lowercase HTML attribute names. No `attr:` / `bool:` / `on:` / `oncapture:` namespaces.
Event handlers stay camelCase (`onClick`)"* (`packages/solid/CHEATSHEET.md:463`, with the removals
table at `:637-641`). `use:` became `ref={fn}`; `classList` became `class={{…}}`. A namespace is a
second vocabulary that must be documented, formatted, diagnosed and kept in step with the first, and
the system with the most experience of it stopped.

### 5.3 What an event handler is — and the one place the architecture leaks

The brief asks for neutrality between TEA and signals. It is mostly achievable; here is exactly where
it is not.

Under **TEA** (report 25 option C, W1's recommendation) a handler is a **message value or a function
to one**: `onClick={Clicked}` passes a `msg`, `onInput={GotText}` passes `sync (String -> msg)`.
Under **signals** a handler is a `sync` function that performs a write. **The syntax is identical**
and so is the typing rule: *the attribute's declared parameter type is what the handler is checked
against*. What leaks is the default set of declared types the platform ships — a platform decision,
not a grammar one.

Three consequences that belong in the specification whichever way it goes:

1. **`sync` is not optional.** W8: a handler that suspends breaks `preventDefault` undetectably, and
   report 26 §5.1 measured the link navigating anyway while `event.defaultPrevented` read `true`. So
   every handler attribute's type is `sync (…)`, and the check is the one A6 already buys. JSX does
   not weaken it; JSX is where most handlers are written, so it is where the check is most visible.
2. **The handler's *variant* must be data.** Report 24 §6.6 and `plans/browser-platform.md` §2.3: the
   `passive` flag is decided by whether the handler may call `preventDefault`, so
   `Normal | MayStopPropagation | MayPreventDefault | Custom` has to travel beside the closure. In
   JSX that is either four attribute spellings or one with a modifier — **J3**.
3. **Do not copy Elm's silent drop.** Elm's handler is a `Decoder msg` and a decode failure *"silently
   drops the event. No message, no log"* (report 24 §6.6). That is rule 7's silent-wrong-answer
   class. The beni answer is a typed accessor per event — `onInput` hands a `String` because the
   platform declared it that way — with the raw `Event` available for anything the platform did not
   anticipate. Mint's answer is the other extreme and worth knowing: one flat `Html.Event` record
   with every field of every DOM event pre-declared and a runtime `Proxy` supplying defaults
   (`core/source/Html/Event.mint:1-56`, `runtime/src/normalize_event.js:30-60`).

### 5.4 `class`, `style`, `ref`

- **`class`**: a string, with interpolation, plus `Html.classList : List (String, Bool) -> Attr msg`
  for the conditional case. Solid 2.0's `class={{ active: isActive() }}` object/array form is the
  same idea; the list form needs no grammar. Note Solid's own warning about the 1.x `classList`
  pseudo-attribute — *"it doesn't work in prop spreads like `<div {...props} />` or in `<Dynamic>`"* —
  which is exactly the hole a plain value in a plain list does not have.
- **`style`**: `Html.style : List (String, String) -> Attr msg`, **not** a record. Style properties
  are hyphenated and open-ended. Solid writes styles through `el.style.setProperty(key, value)` and
  therefore uses **dash-case with explicit units** rather than React's camelCase-plus-magic-`px`
  (`domexpr-jsx.d.ts:691-700`); beni should do the same, because the alternative is a name table in
  the platform for no gain.
- **`ref`**: a real problem under immutability, and it should be **deferred, not designed here**. The
  browser platform needs `Browser.Dom.getElement`-shaped access (report 24 §8.2), which is
  identifier-based rather than a mutable cell. Note that Mint refuses `ref` outright and redirects to
  an `as` clause (`src/type_checkers/html_attribute.cr:30-33`), and Solid 2.0's answer to *both*
  `ref` and directives is *"refs are functions"* — `ref={el => …}`, with `use:` folded into it. §15
  records this as undetermined.

---

## 6. Components

### 6.1 The naming conflict, stated at full strength

JSX's rule is *"a capitalised tag is a value-based element; a lowercase tag is intrinsic"*, and
ReScript, Mint, Leptos, Sycamore and TypeScript all copy it (§2). In beni that rule collides with a
rule the language already has:

> **A capitalised identifier in expression position is a constructor** (`language.md` §6.2), and
> `unbound_constructor` is what it is when it is not one.

So `<Card title="x"/>` naming a *function* would introduce a second reading of an upper name in
expression position, decided by the `<` in front of it. Decidable, with no lookahead — but a real
departure, and the report should not pretend otherwise. Three honest ways out, which are J2.

**(a) A tag name is an ordinary name.** `<div/>` is `Html.div`; a component is `<userCard title="x"/>`;
a qualified one is `<Ui.card/>`. Capitalisation stops carrying meaning in a tag, so nothing collides
with the constructor rule. **No rule is added to the language**: a tag name resolves exactly as a
name in an expression resolves (`language.md` §6.2).

**(b) A capitalised tag names a MODULE, and the component is its `view`.** `<Card title="x"/>` means
`Card.view { title = "x" }`. This is ReScript's — `<Foo.Bar/>` → `Foo.Bar.make`
(`jsx_v4.ml:1305-1314`) — and Mint's `component` declaration in a different key. It costs no new
namespace, because `Card` before a `.` is already a module alias, and it gives a module a home for
its props type, its `defaults` and its helpers. Cost: one component per module.

**(c) A capitalised tag names a `pub` value in a new component namespace.** Most familiar; the only
option that adds a third meaning for a capitalised name in expression position.

### 6.2 The problem that does not exist in beni

**Every other language needs a convention here because a local `div` might shadow the intrinsic.**
beni forbids shadowing (`language.md` §7: *"a binding may not reuse a name already bound in an
enclosing scope, including top-level names of this file and names in `exposing` lists"*), so if
`Html.div` is in scope, a local `div` is `shadows_import` and cannot exist. **`<div>` therefore has
exactly one meaning in a file, always.**

Compare what the others pay. ReScript makes a lowercase tag *unshadowable by construction* — `<div/>`
becomes the string literal `"div"` and a `let div = …` in scope is simply irrelevant
(`jsx_v4.ml:1336-1346`) — which is decidable but means you can never reach your own `div`. Dioxus
spends **four orthogonal signals** on the question (a dash means a web component, a leading lowercase
means an element, an underscore means a component, a multi-segment path means a component,
`packages/rsx/src/node.rs:72-113`). TypeScript spends a whole `JSX.IntrinsicElements` interface on
it. Leptos spends `is_component_tag_name` on the last path segment.

**beni spends nothing**, and that is the strongest argument for J2 option (a). It also matches where
Solid went: `<Dynamic component={…}>` became `dynamic(…)`, a factory returning a **stable `Component`
value**, so a dynamic tag is *an ordinary identifier in tag position* — the same direction as "a tag
name is a name".

**Recommendation: (a)**, with (b) available later as sugar if the familiar look is missed. The cost
of (a) is that `<userCard/>` does not look like `<UserCard/>`, and that is exactly the kind of thing
the owner should decide rather than the manager.

### 6.3 What a component call IS, with no currying

beni has no currying, no optional arguments and no optional record fields, so
`<Card title="x" elevated>children</Card>` must become a **saturated call**. Three candidates.

**(i) One record.** `Card { title = "x", elevated = True, children = [ … ] }`. This is ReScript v4's
answer, and the stated reason for the v3→v4 move transfers to beni unchanged: **a nominal props
record gives the checker a known expected type at each field**, so
`<Button variant=Primary/>` works where the curried form needed `<Button variant=Button.Primary/>`
(release 10.1). Props are a value, so they can be built, stored, passed and **spread**, because
`{ base | title = "x" }` is record update.

The problem is **optional props**, since a record literal in beni is closed (`checker.md` §6.1).
Three sub-options:

- **`defaults` + record update.** The component module exports `defaults : Props`, and
  `<Card title="x"/>` desugars to `Card { Card.defaults | title = "x" }`. **This needs no language
  change at all**: record update is `language.md` §6.3, and "the base must have every updated field"
  is exactly the check wanted — a typo in a prop name is `unknown_field` with the existing "did you
  mean". It is Mint's per-property semantics (a property without a default is required,
  `src/type_checkers/html_component.cr:29-37`) obtained per-record instead of per-property.
- **Optional record fields** (`{ title : String, elevated? : Bool }`) — ReScript's route, needing the
  `?` sigil at type, literal and pattern level (`jsx_v4.ml:161-190`), and a real addition to
  `checker.md` §6.1's row rules. A large language feature for JSX to introduce; if beni ever wants it
  for other reasons, JSX benefits.
- **`Maybe` everywhere** — cheap and wrong: every component body unwraps, and `Maybe Bool` has three
  states where two were meant.

**Recommendation: (i) with `defaults` + record update.** Zero new language surface; `{...props}`
falls out; the diagnostics are the ones the checker already produces. And it avoids the wart every
builder-based system has: Leptos's `nostrip:` optionals cannot go through its type-state builder at
all and become post-build field assignments (`view/component_builder.rs:81-97`) — *"a language with
first-class optional fields wouldn't need it"*, and neither does one with record update.

**(ii) Positional.** `Card "x" True [ … ]` — rejected, and the reason is beni-specific: saturated
calls make every arity mistake a diagnostic at the call site, which is good, but markup's whole point
is that attributes are **named and unordered**. Positional would make `<Card elevated title="x"/>`
and `<Card title="x" elevated/>` different programs, which no markup language has ever done.

**(iii) A module with `view`** — this is §6.1(b) and is orthogonal: it decides where the function
lives, not what its parameter is. Combine (b) with (i) and the result is ReScript v4 exactly.

### 6.4 `children`, slots, generics, dynamic tags

`children` is an ordinary field of the props record, typed by the component:

| Written | `children`'s type |
|---|---|
| `<Card>…</Card>`, any number of children | `List (Html msg)` |
| `<Card><Slot/></Card>`, exactly one | `Html msg` — a checked arity, `component_children_arity` |
| a render prop / slot | `sync (a -> Html msg)`, written as an ordinary attribute: `row={\r -> <li>…</li>}` |

The third is the one JSX handles badly — a "function child" is a child that happens to be a function
and the type must admit both — and in beni it should simply **not be a child**. One fewer overloaded
position, and it types exactly. (Leptos's `let:item` is the same idea reached through sugar:
`.children(move |item| …)`, `view/component_builder.rs:236-248`.)

Mint hard-codes the first case — a `children` property must be `Array(Html)` and must have a default
(`src/type_checkers/property.cr:59-69`). beni needs no hard-code, because the props record is an
ordinary type.

- **Method components** (`<model.header title="x"/>`): `language.md` §6.3 already makes `x.m a b` a
  method call, and a tag is an application, so this falls out. **Admit it, do not advertise it** —
  forbidding it would be a restriction with no guarantee behind it (rule 7).
- **Generic components**: a component is a function, so it is generic exactly as functions are, and a
  `where` clause on its annotation works unchanged. Mint explicitly refuses this
  (`src/type_checkers/property.cr:49-57`, *"not supported this time"*); beni gets it free.
- **Dynamic tags** (`<{tag}>` with `tag : String`): a **function, not syntax** —
  `Html.node tag [ … ] [ … ]` — because a dynamic tag defeats the static-template lowering (§8) and
  the surface should make that visible. Solid 2.0 reached the same place from the other side by
  turning `<Dynamic>` into a value-returning factory.

---

## 7. The formatter

`beni fmt` is canonical, idempotent, structure-preserving and total on valid input
(`language.md` §9, `frontend.md` §3.7), and every corpus fixture is kept in canonical form. JSX
raises four questions; three have answers already in the document, and one is the whole argument for
quoted text.

**1. Does the formatter ever change meaning?** With bare text children, yes, unavoidably: reflowing
`<p>Hello   world</p>` changes the DOM unless the formatter implements Babel's whitespace algorithm
exactly and never crosses a boundary it does not tolerate. With **quoted** children it cannot —
`language.md` §9 already says *"strings, numbers and chars are printed as written, with no escape
normalisation; the formatter never changes bytes inside a literal"*, and the bytes of a text child
are inside a literal. **Meaning preservation is by construction.**

Mint is the proof by example. Because its text children are string literals and inter-child
whitespace is syntactically dead, its formatter re-flows a long text child across a `\` continuation
**at a different, mid-word split point** and the output is byte-identical
(`spec/formatters/html_content_multiline`, `src/formatters/html.cr:3-36`). No JSX formatter can do
that. ReScript gets a weaker version of the same safety for the same reason: it has no text nodes at
all, so *"there is no whitespace-significant content for the printer to damage."*

**2. Attribute line breaking.** `language.md` §9's governing rule applies unchanged: *"the formatter
never joins lines the author broke."* An opening tag's attribute list is a multi-element construct
like a list or a record — one line when it fits in 100 columns and the author wrote no break between
attributes, otherwise one per line. Both Mint (`src/formatter.cr:60-69`, `Behavior::BreakAll`) and
ReScript (`res_printer.ml:4602-4620`, one Wadler group) do all-or-nothing, and ReScript additionally
*joins back up* when it fits — which beni's never-join rule declines, deliberately and consistently
with every other construct.

Children follow a list's rule. ReScript's refinement is worth copying: a hard line break when there
is more than one child **or any child is an element**, so `<A>{a}</A>` may stay inline but
`<A><B/></A>` does not (`res_printer.ml:4760-4769`).

**3. Self-closing normalisation.** The prior art splits, which is what makes it **J4**. Mint
normalises `<div></div>` to `<div/>` (`src/formatters/html.cr:31-32`); ReScript deliberately does not
and calls it fidelity — *"JSX elements keep their closing tag"* (CHANGELOG, PR 8561),
`res_printer.ml:4670-4682`. beni's formatter is canonical in the gofmt sense rather than a
fidelity-preserving printer — it already sorts imports, removes a leading `|` in a `type`
declaration and removes whitespace inside `( + )` — so the recommendation is **normalise**.

**4. Parenthesisation.** Because §3.4 makes an element an operand and not an argument, a multi-line
element inside an application already carries parentheses and the formatter keeps them. An element as
the body of a definition needs none, and the `=`-then-newline-indent-4 rule applies unchanged.

One new rule is needed and it is small: **a closing tag aligns with its opening tag's column**, and an
element whose opening tag broke is always vertical — the `if`/`case`/`let` rule, applied to a
construct that has a visible closer.

---

## 8. What the compiler emits

Report 27 owns what Solid emits and report 29 owns the measurement. This section is only about where
the seam is in *beni's* pipeline.

### 8.1 Two lowerings, and they are not exclusive

**(i) Desugar to ordinary calls, early.** `bir/Lower.zig` turns `<div class="x">{kid}</div>` into
`call(Html.div, [ list [ call(Html.class, ["x"]) ], list [ kid ] ])`, and BIR contains no JSX. This is
Mint's shape (one `createElement` per element, `src/compilers/html_element.cr:92-96`), and every
existing pass then works unchanged: the checker, the dispatch table, `Reach`, `Opt`, `Rename`,
`Decision`. **`language.md` §8 step 2's desugaring list gains one row and nothing else changes.**

The consequence is the honest one: **JSX is then pure sugar, and any template optimisation is a
separate pass that works equally well on a hand-written `Html.div [] []`.** The brief asks whether the
compiler could recognise `Html.div [..] [..]` structurally. It can: the calls are saturated, the
callee is a resolved `ext_value(Html, div)`, the attribute and child lists are literal `list` nodes
of known length — exactly the shape a pattern-matching pass wants. **Leptos proves it**: its default
strategy is not a JSX-specific template at all but an `is_inert_element` walk that collapses any
subtree with no components, blocks or special attributes into one `&'static str`
(`leptos_macro/src/view/mod.rs:108, 301-403`). The predicate is structural; the surface is incidental.

**So say it plainly: the template optimisation is independent of the surface.** JSX does not buy the
optimisation. What JSX buys is (a) familiarity, (b) a syntactic guarantee that the structure is
literal — a hand-written `Html.div` may take a computed `List (Attr msg)` and defeat the pass without
saying so — and (c) **typed holes** (§4.4), which delete the `Html.text` wrapper and let a `String`
hole compile to `node.data = s` instead of to a node construction plus a diff.

**(ii) A dedicated BIR node.** `element { template_id, static_shape, holes: [ (path, kind, expr) ] }`,
so the backend emits a `<template>`, `cloneNode(true)`, a hole walk and one update function per hole.
This is what Solid, Leptos (`tachys/src/view/template.rs:11-51`) and Dioxus do, and what report 29
measures. Two mechanisms from §2.4 are worth pinning now because they are the real design choices:

- **How a hole is located.** Leptos uses a `firstChild`/`nextSibling` **cursor walk** with the path
  implicit in the recursion order (`tachys/src/hydration.rs:13-98`). Dioxus uses an explicit
  **bit-packed path** — `TemplatePath { path: u128 }` where `next_child` is `(path << 1) | 1`
  (`core-template/src/path.rs:8-60`) — and pays for it with an overflow path that splits oversized
  templates into nested ones (`packages/rsx/src/template_body.rs:713-786`). **If beni takes the packed
  path, the overflow rule has to be in the spec before it ships.**
- **Whether one description drives both the client build and the server string.** Leptos has *three
  hand-written methods that must agree* — `Render::build`, `RenderHtml::to_html_with_buf`,
  `RenderHtml::hydrate` — with a runtime hydration panic as the check. beni has a compiler where they
  have a trait, and should **derive both from one description** rather than inherit that invariant.

**Recommendation: build (i) first, and add (ii) as a `--release`-gated pass over the BIR shape (i)
produces, recognised structurally.** (i) is small and cannot regress anything; (ii) wants report 29
before its shape is fixed; and building (ii) as a *recogniser* rather than as a parallel lowering
means the plain-call form gets the same treatment — which is rule 7's answer to "two ways to write
the same thing" (§10). This is **J5**.

### 8.2 How the backend stays renderer-agnostic without compiler magic

If (ii) emits calls to a runtime, the compiler knows the names of runtime functions — which looks like
a hole in `boundary.md`'s wall.

Solid's answer is `dom-expressions`' configurable `moduleName`, so the compiler emits imports from a
name the build supplies, with `packages/universal` as a second renderer behind the same names
(report 27 has the detail). **beni has two better-fitting precedents already in the repository**:
`boundary.md` §5.2's manifest keys (§5.1 above), and `static-dispatch-spike.md` §3.2's **well-known
method table** — `eq` and `compare` are names the compiler asks for by name, resolved through the
ordinary module rule and derived when absent.

So: **a platform that wants template lowering declares a markup interface** — a module whose `pub`
values are a fixed list of well-known names (`template`, `insert`, `setAttribute`, `addEventListener`,
`effect`, `keyed`, …), checked the way `boundary.md` §4's check 4 is checked: count what is declared,
do not parse the JavaScript. A platform that declares none gets lowering (i) and a perfectly good
program. A server-rendering platform declares a different implementation of the same names and **the
same JSX compiles to a string builder**. This is not a new mechanism; it is two existing mechanisms
pointed at a third thing.

### 8.3 Non-browser targets, and how rule 3 is satisfied

Rule 3 says every defect gets a black-box fixture and `tests/corpus/run/` executes the emitted
JavaScript. There is no DOM under Node. Two requirements follow, and they are requirements on the
design rather than consequences of it:

1. **A render-to-string platform must exist before JSX ships**, so `run/` fixtures can build a `view`,
   render it and compare bytes. Under §8.2's markup interface this is a second implementation of the
   well-known names and costs no compiler change. It is also what proves the interface is real rather
   than a browser API wearing a hat.
2. **The `emit/` corpus pins the shape.** `emit/` goldens are what made the `--release` slice provable
   (*"development output did not move by one byte"*); an `emit/Jsx*.js` golden is how "JSX and
   `Html.div [] []` emit the same bytes" becomes a test rather than a claim.

---

## 9. What it costs the compiler

### 9.1 By phase

The estimates are anchored on two features of comparable surface already in the tree: **string
interpolation** (a lexer mode, four token kinds, an AST node, a BIR node, a checker obligation, a
formatter case, two dump cases) and the **`case` decision tree** (`src/js/Decision.zig`, 653 lines,
plus `src/check/Exhaustive.zig`, 1 523).

| Phase | File (current size) | Change | Rough lines of Zig |
|---|---|---|---|
| Lexer | `src/lex/Tokenizer.zig` (1 944) | **one new token `...`** — or none, if spread is spelled differently or quoted-name attributes carry it. **No mode.** | **0–30** |
| Parser | `src/parse/Parse.zig` (4 468) | `parseElement`, `parseOpeningTag`, `parseAttribute`, `parseChildren`; keywords as attribute names; the `op_lt` arm of `parseAtom`; two recovery cases | **350–500** |
| AST | `src/parse/Ast.zig` (1 172) | ~6 node tags (`element`, `fragment`, `attribute`, `attr_spread`, `child_expr`, `closing`) with `extra` records and full accessors | **150–220** |
| BIR lowering | `src/bir/Lower.zig` (4 215) | lowering (i): build the two lists and the call; resolve attribute names in the platform namespace | **200–300** |
| Checker | `src/check/Constrain.zig` (1 642) | under §5.2(B) + lowering (i): **nothing** — it is a call. With typed holes (§4.4): one obligation kind, its discharge arm, its diagnostic | **80–150** |
| Formatter | `src/fmt/Format.zig` (3 272) | element printing, attribute break-all, self-closing normalisation, the width measure | **250–350** |
| Dump | `src/dump/ast.zig`, `bir.zig` | `ast` gains the new tags; `bir` gains nothing under (i) | **40** |
| Diagnostics | `src/*/Diagnostics.zig` | 6–9 new codes with Elm-style prose and "did you mean" over the element namespace | **200–300** |
| **Total, lowering (i)** | | | **≈ 1 300–1 900** |
| Backend, lowering (ii) | `src/js/` | template extraction, hole paths, per-hole update, the well-known-name interface, the `--release` gate, the path-overflow rule | **600–1 000**, later |

The headline is that **the lexer line is 0–30 and the checker line is 80–150**, and both are
consequences of the two recommendations (quoted children; attributes are values in a list). The
alternatives move ~400 lines into the lexer and ~400 into the checker.

### 9.2 Throughput

`fast-compiler.md` §2's budget is >250k LOC/s cold per core for checking. The relevant risk is that a
mode-switching lexer slows *ordinary* code — and under the recommendation **there is no mode switch**,
so the lexer is untouched and the risk is zero by construction. The parser gains one arm on
`parseAtom`'s switch, which is a jump-table entry.

The costs that are real are the **formatter's width measure** (`frontend.md` §3.7: one bottom-up pass
into a side array) over deeply nested markup, and the **parser's depth accounting** — an element is a
nesting level, and `language.md` §10's 4096-level limit plus the per-declaration spine charge already
covers it. A 20-deep view is 20 levels.

Note what beni does **not** inherit. Leptos and Dioxus both have serious compile-time and
binary-size scar tissue from markup — Leptos ships an `erase_components` build flag trading
*"one `Arc<Mutex<_>>` allocation per closure + a vtable dispatch per render, in exchange for
substantially less monomorphization (smaller WASM, faster compile)"* (`leptos/src/lib.rs:256-266`);
Dioxus caps view tuples at 128 and splits oversized templates. Both are consequences of encoding the
view's *shape in its type*. Lowering (i) emits ordinary saturated calls into a flat BIR, so beni has
no monomorphised view type to blow up.

### 9.3 Determinism, and the cache

- **Determinism (rule 5)**: nothing in the design depends on thread timing. Attribute order is source
  order; the emitted attribute list is source order; **a template id must be derived from the module
  index and the instruction index, never from a counter shared across workers.** That is the one place
  a template-lowering implementer can break rule 5, and it belongs in the spec. Dioxus needed a
  compile-time content hash *"to ensure identical templates compare equal regardless of optimization
  levels"* (`core-template/src/data.rs:33-44`), which is the same problem arriving by another door.
- **Interface hashes**: under lowering (i) JSX produces ordinary calls, so a module's interface is
  whatever its annotations say and JSX is invisible to `checker.md` §7's serialized form. **The interface
  firewall is unaffected.**
- **The front-end cache**: `frontend.md` §3.2 caches `tag` and `start` only, and §3.6 the
  pre-resolve `Bir`. A new token tag is a new enum value — an ordinary format change the
  compiler-build-id key already invalidates. **A lexer mode would have been the thing that needed a
  format decision, and there isn't one.**

---

## 10. The strongest case against building markup into the language

Stated at full strength first, because the owner's decision is already taken and a decision that has
not met the best objection is untested.

**1. Scala did it, shipped it for fifteen years, and removed it.** XML literals were in the Scala 2
*grammar*; Scala 3 dropped them. The only officially stated reasons are **parser complexity and spec
complexity**, and the concrete evidence is Odersky refusing to fix a mis-parse in a sub-parser he
describes as one *"which I don't know"* (§2.5). The pattern: a markup syntax welded into a
general-purpose language ages with the markup, not with the language, and the exit is expensive
because it is in everybody's source.

**2. In an Elm-like language the baseline is already good, and JSX's advantage over it is smaller
than in JavaScript.** `div [ class "app" ] [ text "hi" ]` is *data*: refactored with ordinary
functions, extracted with ordinary `let` bindings, mapped over, stored in a list — and it needs no new
grammar, no new formatter rules, no new diagnostics and no new lexer. `elm-format` already lays it out
well. Be honest about the size of the gap: `<div class="app">` saves brackets and a `text` wrapper; it
does not save a concept. Lustre says so as a feature — *"No templates, no macros, just Gleam"* — and
Elm's own position is that a markup sublanguage *"tend[s] to evolve into bad languages"*.

**3. The compiler-sees-markup argument is weaker than it sounds, and §8.1 proves it.** A pass that
recognises `Html.div [literal] [literal]` structurally can split a static template from dynamic holes
exactly as well as one that reads a JSX node — Leptos's default strategy *is* such a pass. The two
things JSX genuinely adds are typed holes and a syntactic guarantee of literalness. Neither is the
optimisation itself.

**4. Two ways to write the same thing.** Every beni view becomes writable twice, and a code base will
contain both. `language.md` has resisted this elsewhere — sections do not exist, `(|>)` does not
exist — and JSX would be the largest deliberate duplication the language has taken on.

**5. Tooling cost compounds.** The formatter, `dump --stage=ast`, error recovery, the M5 LSP, syntax
highlighting and every future pass that walks the AST all grow a second shape. The Scala thread's one
durable counter-argument was precisely this, in the other direction: IDE support for the
*replacement* (`xml"…"` interpolation) was worse than for the grammar it replaced.

**6. Elm and Gleam refuse, and their view code is not what people complain about.**

### What answers it, given the decision is taken

- **Objection 1 (Scala)** is answered by *what* is being built in. The design above puts **no HTML
  knowledge in the compiler** (§5.1, §8.2) — the element, attribute and event tables are a platform
  package's beni declarations, which is what ReScript, Leptos, Dioxus and (after a correction) Solid
  all concluded independently. What goes into the grammar is `<name attrs> children </name>`: a
  shape, not a vocabulary. Scala put a *schema-shaped syntax* in the grammar; this puts a bracket in
  it. And the specific wound — two grammars with a lexer mode flag between them — is the thing §3.1
  and §4 exist to avoid.
- **Objection 2 (the baseline is good)** is answered by conceding it and naming what is bought: typed
  holes, and a syntax the entire web already reads. Lustre's migration guide states the tax JSX
  removes in one sentence (*"you need to use the `html.text` function"*).
- **Objection 3 (the optimisation is independent)** is answered by *agreeing and building it that
  way* — §8.1's recommendation is a recogniser over ordinary calls, so the optimisation serves both
  surfaces and the plain-call form is never the slow path.
- **Objection 4 (two ways)** is answered by rule 7 and by making it *literally* true that they are the
  same program: **JSX desugars to `Html.div [] []` in `bir/Lower.zig`, and an `emit/` golden proves
  the two produce identical bytes.** One semantics, one optimiser, one set of diagnostics. That is the
  difference between a second way to write something and a second language.
- **Objection 5 (tooling)** is answered with a number: §9.1's ≈1 300–1 900 lines, of which 0–30 are in
  the lexer, and a formatter share bounded by the fact that whitespace inside a text child is bytes it
  may not touch.
- **Objection 6 (Elm and Gleam refuse)** is answered by their own reasons. Gleam's is *no macros*,
  which is an argument against a `view!`-style macro, not against a grammar production. Elm's is a
  general "no syntax you can avoid" position — and note that `elmx`, a third-party JSX precompiler for
  Elm, exists, which says the demand was real and was answered outside the language rather than
  inside it.

**The one thing that should be conceded in writing:** if JSX ships and the template optimisation is
built as a recogniser over ordinary calls, then **JSX's measurable contribution is the typed hole and
nothing else**. Everything about speed is `Html.div`'s too. That accounting belongs in this report
rather than in a post-mortem.

---

## 11. The recommended design

### 11.1 beni JSX in twenty rules [proposed]

1. An **element** is an `Atom` in `language.md` §3's grammar, admitted only where an operand starts —
   **never as a bare application argument**. `f (<div/>)`, `f <| <div/>`, or pipe it.
2. `Element := '<' TagName Attr* '/' '>' | '<' TagName Attr* '>' Child* '</' TagName '>'`, plus the
   fragment `'<' '>' Child* '</' '>'`. The closing `</` is two tokens that must abut; the closing tag
   name must equal the opening one.
3. A **tag name is an ordinary name**, resolved by `language.md` §6.2's existing rules: a
   `lower_ident` or a `qualified_lower`. `<div>` is `Html.div` because the platform's prelude exposes
   it; `<userCard>` is a local or top-level function; `<Ui.card>` is qualified. **Capitalisation
   carries no meaning in a tag**, so nothing collides with the constructor rule.
4. **Shadowing is already an error** (§7), so `<div>` has exactly one meaning in a file, always.
   There is no intrinsic-versus-component question in beni.
5. An **attribute** is `name`, `name="literal"`, `name={expr}`, `{name}` (punned), or
   `"quoted-name"="literal"` / `"quoted-name"={expr}`. A `name` may be a keyword token (`type`, `as`).
6. `name="literal"` is an ordinary string literal, **interpolation included**: `class="btn ${size}"`.
7. A bare `name` means `name={True}`; a punned `{name}` means `name={name}`.
8. An attribute desugars to a call in the tag's namespace — `class="x"` is `Html.class "x"` — and
   **a quoted name is the escape from the typed vocabulary**: `"data-foo"="1"` is
   `Html.attribute "data-foo" "1"`. An unknown unquoted attribute is `unbound_variable` with "did you
   mean". `{...attrs}` splices a `List (Attr msg)`. **No namespaced attributes** (`on:`, `attr:`,
   `prop:`, `use:`): Solid removed all of them in 2.0.
9. A **child** is `"a string literal"`, `{expr}`, or a nested element. **There is no bare text.**
10. Whitespace between children is not data. The formatter lays children out as it likes, and
    therefore **cannot change what the page says**.
11. A `{expr}` child's type must be one of `String`, `Int`, `Float`, `Bool`, `Char`, `Html msg`,
    `Maybe (Html msg)`, `List (Html msg)`, `Keyed msg` — otherwise `child_not_renderable`. **No
    `Html.text` wrapper is ever written**: the checker knows the type and the compiler inserts it.
12. `if` and `case` are expressions, so they work inside `{…}` with no new rule and no `<Show>`; each
    branch is its own static template.
13. A **fragment** is `<>…</>`.
14. A **component** is an ordinary function taking **one record**, called saturated:
    `<Card title="x"/>` is `Card { Card.defaults | title = "x" }` when `Card.defaults` is in scope,
    and `Card { title = "x" }` otherwise. **Optional props are `defaults` plus record update** — no
    language feature is added, and `{...props}` is the same rule.
15. `children` is an ordinary field of that record, typed by the component (`List (Html msg)`, or
    `Html msg` for exactly one). A **slot is an attribute whose type is a function**, not a child.
16. **Event handlers are `sync`** — `onClick={Clicked}`, `onInput={GotText}` — because a handler that
    suspends breaks `preventDefault` undetectably (W8, report 26 §5.1). The attribute's declared
    parameter type is what the handler is checked against, so TEA and signals both fit. A decode
    failure is never silent (report 24 §6.6 is what not to copy).
17. **Keys are a type, not syntax**:
    `Html.keyed : List (k, Html msg) -> Keyed msg where k.compare : k, k -> Order`. An unkeyed
    `List (Html msg)` hole gets a **warning**, on by default for the root package, with
    `Html.unkeyed` as the escape hatch.
18. The intrinsic element, attribute and event tables are a **platform package's beni declarations**,
    never compiler knowledge — the mechanism `boundary.md` §5.2 already uses for `program` and
    `runtime`.
19. `bir/Lower.zig` desugars an element to the **same calls a hand-written `Html.div [] []`
    produces**, and an `emit/` golden proves the two emit identical bytes. One semantics, one
    optimiser, one set of diagnostics.
20. The **template optimisation is a separate `--release` pass that recognises the call shape
    structurally**, so it serves the plain-call form too; a platform opts into it by declaring a fixed
    list of well-known runtime names — `static-dispatch-spike.md` §3.2's mechanism, pointed at markup.

### 11.2 The typeahead's `view`, written in it

Report 25 §2 is the specification; §2.2 has `Model`, `Hit` and `Status` and §3.3 the `Msg` and the
`view`. Below is the same view under rule set 11.1. Everything outside the markup is valid
`language.md` today — the plain-call form of `viewStatus`/`viewHit` was checked with
`beni dump --stage=ast` and parses clean — and `sync` and the markup are `[proposed]`.

```elm
--| [proposed] The typeahead view. `Model`, `Msg` and `Status` are report 25 §2.2's.
view : Model -> Html Msg
sync view model =
    <div class="typeahead" style={Html.style [ ( "max-width", "${model.width}px" ) ]}>
        <input
            class="query"
            value={model.query}
            placeholder="Search…"
            onInput={Typed}
        />
        {viewStatus model}
    </div>


viewStatus : Model -> Html Msg
sync viewStatus model =
    case model.status of
        Idle ->
            <p class="hint">"Start typing."</p>

        Loading ->
            <p class="hint" "aria-busy"="true">"Searching…"</p>

        Failed e ->
            <p class="error" role="alert">"Could not search: ${errorText e}"</p>

        Loaded [] ->
            <p class="hint">"No results for “${model.query}”."</p>

        Loaded hits ->
            <ul class="results">
                {Html.keyed (List.map hits (\hit -> ( hit.id, viewHit model hit )))}
            </ul>


viewHit : Model, Hit -> Html Msg
sync viewHit model hit =
    let
        isFav = Set.member model.favourites hit.id
        isSaving = Set.member model.saving hit.id
    in
    <li class="hit">
        <span class="title">{hit.title}</span>
        <button
            class="fav"
            disabled={isSaving}
            "aria-pressed"={boolText isFav}
            onClick={Favourited hit.id (not isFav)}
        >
            {if isFav then "★" else "☆"}
        </button>
    </li>
```

Six things to notice, because each is a rule earning its keep:

- `{hit.title}` is a **`String` hole**. No `Html.text`. Under lowering (ii) it becomes
  `node.data = hit.title` and nothing else.
- `{if isFav then "★" else "☆"}` is also a `String` hole — an ordinary `if` expression, no `<Show>`,
  and the compiler sees two constant strings.
- `viewStatus`'s five branches are five templates and the hole swaps between them — the shape
  `src/js/Decision.zig` already produces for a `case`.
- `"aria-pressed"={…}` is the quoted-name escape: no hyphen join in the parser, no `attr:` namespace,
  and the reader can see at a glance that it left the typed vocabulary.
- `Html.keyed` makes the list hole a `Keyed msg`, so the keyed reconciler is chosen **by the type**
  rather than by a convention the compiler has to trust.
- `class="btn ${…}"` and `"${model.query}"` are the language's own interpolation
  (`language.md` §2.6), reused unchanged — which is the whole reason quoted children cost nothing.

And the plain-call form of one branch, because rule 19 says these are the same program:

```elm
Loaded hits ->
    Html.ul [ Html.class "results" ]
        [ Html.keyed (List.map hits (\hit -> ( hit.id, viewHit model hit ))) ]
```

---

## 12. The decisions that are genuinely the owner's

Five. Everything else in this report is either forced by the grammar (§13) or is a manager-level
call.

### J1. Are text children quoted, or bare?

**What it is.** In HTML and React you write `<p>Hello</p>`. The question is whether beni does, or
whether text must be a string literal.

```elm
<p>Hello, ${name}!</p>          -- bare     [proposed]
<p>"Hello, ${name}!"</p>        -- quoted   [proposed]
```

**What bare text costs, concretely.** beni tokenises the whole file before the parser runs
(`src/lex/Tokenizer.zig:119-127`), so the lexer would have to decide for itself when it is inside a
tag — which is the parser's knowledge. It also means `--` inside text becomes a comment and eats the
rest of the line; a tab inside text is `tab_in_source`; a whitespace-collapsing rule (Babel's, §2.3)
has to go into `language.md` and bind `beni fmt` forever; and the front-end cache's token stream has to carry
the mode.

**What quoted text buys.** No lexer change at all. `${…}` interpolation inside the text, so
`<p>"Hello, ${name}!"</p>` is *one* text node instead of three children. Escapes and `\u{…}`. The
`\\` raw form for a block of prose. And the one that matters most: **the formatter provably cannot
change what the page says**, because `language.md` §9 already forbids it to touch bytes inside a
literal.

**Everyone else.** Mint, ReScript, Dioxus, Yew, Sycamore and Imba all require quoted text. Leptos
allows bare text and its own book calls it lossy — *"can occasionally cause spacing issues around
punctuation, and does not support all Unicode strings"*. Marko allows it and had to invent a `--`
fence.

**Recommendation: quoted.** It is the difference between a parser feature and a lexer rewrite.

### J2. Is a tag name just a name, or does a Capital mean "component"?

**What it is.** Everywhere else, `<Card/>` with a capital means "component, not HTML element". In beni
a capital already means constructor, module or type.

**(a) A tag name is an ordinary name.** `<div/>` is `Html.div`; a component is `<userCard title="x"/>`;
a qualified one is `<Ui.card/>`. **Nothing is added to the language.** And because shadowing is an
error, `<div>` can never mean anything but `Html.div` — the problem every other language solves with
a convention simply is not there.

**(b) A capitalised tag names a module, and the component is its `view`.** `<Card title="x"/>` means
`Card.view { title = "x" }`. Markup keeps the familiar look; `Card` before a `.` is already a module
name, so nothing collides. This is ReScript's (`<Foo.Bar/>` → `Foo.Bar.make`). Cost: one component
per module, and a convention to learn.

**(c) A capitalised tag names a value in a new component namespace.** Most familiar; the only option
that adds a third meaning for a capitalised name in expression position.

**Recommendation: (a)**, with (b) as later sugar if the look is missed. It is the only option that
adds no rule to a language that has spent a year keeping its rules few. The cost is that
`<userCard/>` does not look like `<UserCard/>` — which is precisely a taste question, and therefore
the owner's.

### J3. What is an event handler, and how are `preventDefault` and `stopPropagation` spelled?

**What is already settled.** The handler must be `sync` (W8) — report 26 §5.1 measured a link
navigating anyway when `preventDefault()` was called one macrotask late, while
`event.defaultPrevented` still read `true`, an undetectable wrong answer. And the handler's *variant*
(`Normal`, `MayStopPropagation`, `MayPreventDefault`, `Custom`) must be **data** beside the closure,
because it decides the listener's `passive` flag (report 24 §6.6).

**What is open** is the spelling:

```elm
<a href="/x" onClickPrevent={Navigate url}>          -- (a) four named attributes per event
<a href="/x" on:click|prevent={Navigate url}>        -- (b) one attribute, a modifier
```

**Recommendation: (a)** — four named attributes per event, because they are ordinary values in the
platform's namespace and need no grammar. (b) is Vue's and Imba's spelling
(`@submit.prevent=api.login(…)`), reads better, and costs a modifier production **plus** the
namespaced-attribute machinery Solid 2.0 just removed. It can be added later without breaking (a).

**A sub-question worth answering at the same time**: does `onInput` hand the handler a `String` (the
platform decodes) or an `Event` (the handler decodes)? Elm's answer is a `Decoder msg` that
**silently drops the event when the decode fails** — rule 7's silent-wrong-answer class, and not to
be copied. Recommend: typed per event, with the raw `Event` reachable for anything the platform did
not anticipate.

### J4. Does `beni fmt` rewrite `<div></div>` as `<div/>`?

**What it is.** A one-line formatter question with a genuine split in the prior art. Mint normalises
(`src/formatters/html.cr:31-32`). ReScript deliberately does not and calls it fidelity — *"JSX
elements keep their closing tag"* (CHANGELOG PR 8561).

**Recommendation: normalise.** beni's formatter is canonical in the gofmt sense, not a
fidelity-preserving printer: it already sorts imports, removes a leading `|` in a `type` declaration,
and removes whitespace inside `( + )`. `<div></div>` and `<div/>` are the same tree.

### J5. Does JSX ship before the template optimisation, or with it?

**What it is.** JSX can land as pure sugar — the same calls a hand-written `Html.div [] []` produces,
about a week's work — or it can wait for the compiled-template lowering that makes it fast.

**Why it is the owner's.** The direction was two things at once: built-in JSX, *and* "the runtime
cannot be a limitation". §8.1 is the honest finding that **they are independent**: the template
optimisation can be a pass that recognises the ordinary call shape — which is literally what Leptos's
default strategy is — and it then speeds up `Html.div [] []` too. So shipping JSX first costs nothing
and delays nothing.

**Recommendation: sugar first.** It is small (§9.1), it cannot regress anything, and it puts the
surface in front of real views before report 29 fixes the shape of the optimisation. The one thing it
must not do is land without the `emit/` golden proving rule 19 — and without the render-to-string
platform of §8.3, because otherwise rule 3 cannot be satisfied at all.

---

## 13. What is forced, rather than chosen

Worth separating, so the owner does not spend attention on things that have no alternative.

| Forced | By what |
|---|---|
| An element may not be a bare application argument | `f a <b` is a legal comparison today (`canStartAtom`, `src/parse/Parse.zig:1468-1473`) |
| An element may start wherever an operand starts | `op_lt` is `unexpectedExpr` there today, in every program (`:1720`) — the position is free |
| No lexer mode, given quoted text | `Tokenizer.tokenize` runs to `eof` before `Parse.parse` (`src/lex/Tokenizer.zig:119-127`, `src/Session.zig:774, 825`) |
| `type` and `as` must be accepted as attribute names | they are keyword tokens, and `<input type=…>` is unavoidable |
| `data-x` needs either a quoted name or a parser-level hyphen join | `a-b` is three tokens |
| Spread needs a new token or a different spelling | `...` is two `INVALID CHARACTER` diagnostics today |
| A closing tag's `</` must abut | `</` is two tokens; adjacency is `Parse.adjacent` (`:279`) |
| The intrinsic table cannot live in the compiler | rule 6, `boundary.md` §5.2, and three systems that learned it |
| A template id may not come from a shared counter | rule 5 (determinism) |
| Attribute order is source order, everywhere | rule 5, and `language.md` §6's evaluation-order table |
| Interface hashes are unaffected | JSX lowers to calls; `checker.md` §7's record sees annotations only |
| An ill-formed element must still produce a tree | `frontend.md` §3.5, and independently what all three mature Rust systems converged on |

---

## 14. What would change in the normative documents

Nothing is renumbered (rule 2). Every addition is a **new** section at the end of its document, or a
row in an existing table.

**`language.md`**
- §0's table: one new row — *"JSX: `<div class="x">…</div>` is an expression; it desugars to the same
  calls the plain form produces"* — pointing at the new section.
- §2.2's token list: `...` if spread takes that spelling.
- §3's grammar block: `Element` added to `Atom`'s alternatives, with the `Element`, `TagName`, `Attr`
  and `Child` productions beneath it, and the *"an element is an operand, never a bare argument"*
  sentence beside §3's existing one about blocks.
- §6, a **new unnumbered subsection** beside *Evaluation order*, or **§6.8** if a number is wanted:
  *Elements* — the twenty rules of §11.1, plus attribute and child evaluation order (left to right in
  source order, which is §6's application row and not a new rule).
- §9: element formatting — attribute break-all, children, self-closing normalisation, the closing-tag
  alignment rule, and the never-join-lines rule applied.
- §10: the new codes **appended at the end of the catalogue, never inserted** —
  `unclosed_element`, `mismatched_closing_tag`, `child_not_renderable`, `duplicate_attribute`,
  `element_as_argument`, `component_children_arity`, `void_element_with_children`, and
  `unkeyed_list_hole` (a `warning`, root package only, like `ambiguous_method_receiver`).

**`frontend.md`**
- §1.2: `dump --stage=ast` gains the element node tags — one sentence, like the `method_call` one.
- §3.5: the new `Ast.Node.Tag` members named.
- **New §9** — *Elements in the front end*: the parser's element production, the two recovery cases,
  keyword attribute names, the quoted-name rule, and the statement that **no lexer mode is added**
  and why (§3.1 of this report).

**`checker.md`**
- §6.1's Bir table: one row for the child-hole obligation if typed holes ship —
  `renderable(var, region)` beside `equatable`, `interpolatable`, `tuple_index`, `try` and the method
  obligation.
- §6.4's discharge loop: the new obligation's arm.
- §8: `child_not_renderable`'s message shape.

**`backend.md`**
- §4: nothing, under lowering (i) — an element is a call.
- **New §11** — *Compiled templates*: the recogniser and its predicate, the template/hole
  representation, hole kinds and their update code, the template-id derivation rule (module index +
  instruction index, never a shared counter), the path-overflow rule if a packed path is used, and
  the `--release` gate.

**`boundary.md`**
- **New §9** — *The markup interface*: a platform may declare an element namespace and a fixed list
  of well-known runtime names, checked the way §4's check 4 is checked; a platform that declares none
  gets lowering (i); the render-to-string platform is the second implementation and is what
  `tests/corpus/run/` exercises.

**`static-dispatch-spike.md`** — nothing. Its well-known-name mechanism is cited, not changed.

---

## 15. Could not determine

- **Whether a `String` hole really compiles to a cheaper update than an `Html.text` node in a
  compiled template**, in numbers. That is report 29's; the claims in §4.4 and §11.2 are arguments,
  not measurements.
- **What `ref` should be** under immutability (§5.4). Mint refuses it outright and redirects to `as`;
  Solid 2.0 folds both `ref` and directives into `ref={fn}`; beni's browser platform needs
  `Browser.Dom.getElement`-shaped access (report 24 §8.2). Deliberately left open.
- **Whether attribute punning should also pun a nested field** (`<Card {model.title}/>` meaning
  `title = model.title`). ReScript's `JSXPropPunning` takes a bare identifier only
  (`jsx_v4.ml:1167-1178`); no evidence either way.
- **Whether ReScript's formatter can ever flip JSX into a comparison by joining a line.** The
  sub-agent found no test pinning it. beni's design does not have the hazard (§3.4), but the claim
  about ReScript is unverified.
- **How much of a realistic beni corpus would be markup**, and therefore what JSX does to the
  >250k LOC/s budget in practice. §9.2 argues the risk is structurally zero; nobody has measured a
  markup-heavy corpus because none exists.
- **Whether `Html.lazy` (W4, parked) survives compiled templates.** If templates land, `lazy`'s reason
  for existing changes shape and W4 should be re-asked. Not analysed here.
- **Measured compile-time numbers for any of the Rust macro DSLs.** The mechanisms and the stated
  trade-offs are cited; no benchmark table was found.
- **Whether Mint's `VALID_HTML` list or its golden is authoritative** — the sub-agent found the
  committed tree inconsistent about whether `Number` is a valid child (`src/type_checker.cr:59-66`
  vs `spec/errors/html_content_type_mismatch:13-16`). Immaterial to beni; recorded for honesty.
- **What was removed from Mint over time.** The clone is shallow with one squashed commit and there
  is no CHANGELOG, so the "what it got wrong and abandoned" question could only be answered from
  in-source self-criticism (§2.1), not from history.

---

## 16. Evidence index

### beni, read and run

| Claim | Where |
|---|---|
| The whole file is tokenised before parsing | `src/lex/Tokenizer.zig:119-127`; `src/Session.zig:774, 825` |
| The lexer's three modes, and why there is no stack | `src/lex/Tokenizer.zig:20-24, 57-59, 76, 210-252, 317-324` |
| `<` lexing: `<|`, `<=`, `<-`, else `op_lt` | `src/lex/Tokenizer.zig:411-418` |
| `op_lt` cannot start an atom or an argument | `src/parse/Parse.zig:1468-1473`, `:1612-1642`, `:1720` |
| Operand-start positions (25 call sites) | `src/parse/Parse.zig:891, 1755, 1763, 1778-1779, 1821, 1856, 1902, 1912-1916, 1926, 1976, 2012, 2055, 2075, 2080, 1557-1569, 1602, 1704` |
| `<` and `>` are precedence-4 non-associative | `src/parse/Parse.zig:1507-1512` |
| `(<)` decided before `parseAtom` | `src/parse/Parse.zig:1740-1751` |
| Adjacency test for access chains | `src/parse/Parse.zig:279`, `language.md` §3 |
| Bracket stack, recovery, `unclosed_delimiter` | `src/parse/Parse.zig:494-515, 517-528, 534-539, 544-564` |
| Token tags, and `type`/`as` as keywords | `src/lex/Token.zig` |
| `q = <div class="a">` tokenises today | run: `beni dump --stage=tokens` |
| `a <b` ≡ `a < b`; `f a <b` is clean; `a < b > c` and `f <b>a</b>` are errors | run: `beni dump --stage=ast`, `beni check --diagnostics=json` |
| `...props` is two `INVALID CHARACTER` diagnostics | run: `beni dump --stage=tokens` |
| The plain-call typeahead parses | run: `beni dump --stage=ast`, exit 0 |
| Phase sizes for the cost estimate | `wc -l src/**/*.zig` |

### beni, normative documents

`language.md` §0, §2.2, §2.3, §2.6, §3, §4 (rules 2 and 6), §6.2, §6.3, §6.5, §6.7, §7, §8 step 2,
§9, §10 · `frontend.md` §1.2, §3.2, §3.5, §3.6, §3.7 · `checker.md` §6.1, §6.4, §7 ·
`backend.md` §4, §7, §9 · `boundary.md` §4 (check 4), §5.2, §5.3 · `static-dispatch-spike.md` §3.2,
§10.9 · `plans/browser-decisions.md` W1, W4, W8 · `plans/browser-platform.md` §2.2, §2.3 ·
`research/24` §6.3–§6.6, §6.8, §8.2 · `research/25` §2, §3.1, §3.3, §7, §9.1, §10 · `research/26` §5.1

### Prior art

**Mint** `4e15025` — `src/parsers/html_element.cr:3-69`, `html_component.cr:3-53`,
`html_body.cr:3-49` (`:21` children are expressions, `:35` closing-tag literal),
`html_attribute.cr:3-43`, `operator.cr:10-13, 44-76` (the `<` heuristic), `src/parser.cr:32-50`
(backtracking), `257-272`; `src/type_checkers/html_attribute.cr:23-69, 74-87`,
`html_component.cr:29-37`, `property.cr:49-57, 59-69`; `src/type_checker.cr:26, 30, 59-66`;
`src/compilers/html_element.cr:18, 92-96`; `core/source/Html/Event.mint:1-56`;
`runtime/src/normalize_event.js:30-60`; `src/formatters/html.cr:3-36`, `src/formatter.cr:60-69`;
`spec/formatters/html_content_multiline`

**ReScript** `e35c08a` (13.0.0-alpha.7) — `compiler/syntax/src/res_scanner.ml:954-961, 1059-1074`,
`res_parser.ml:193-207`, `res_core.ml:894-947, 2111, 2390-2395, 2850-2903, 2951-2971`,
`res_grammar.ml:138-143, 264`, `res_printer.ml:4588-4897`, `ParserCursor.md:44-58`;
`jsx_v4.ml:105-190, 1152-1206, 1300-1373`; `packages/@rescript/runtime/Jsx.res:8-24`,
`JsxDOM.res:19-24, 620`, `JsxEvent.res:7, 45-72`;
`tests/syntax_tests/data/ppx/react/expected/{defaultValueProp,fragment,spreadProps,v4}.res.txt`;
v11 `jscomp/syntax/src/res_scanner.ml:5, 30, 32, 805-823`. Primary URLs: the 10.1 release post,
forum thread 3431, syntax issue 521, `rescript-lang.org/docs/react/elements-and-jsx`,
`/docs/manual/jsx`

**JSX spec** `d614ce7` — `spec.emu:54-58, 65-115, 123-187, 194-241, 255-279`; `AST.md:42-57, 111-117`;
`README.md:7, 33`. **TypeScript** `f29aeb9` — `tsc/internal/parser/parser.go:4340-4366`,
`checker/utilities.go:1160`, `transformers/jsxtransforms/jsx.go:795-851, 861-960`; handbook JSX page;
TypeScript 3.0 release notes (`LibraryManagedAttributes`); Babel's
`cleanJSXElementLiteralChild.ts`; `@babel/parser` `disallowAmbiguousJSXLike`

**Solid** `main` `b25c5577` / `next` `be46a04d` — `packages/solid/CHEATSHEET.md:326-337, 420-500, 463,
622, 637-641, 646-668`; `documentation/solid-2.0/03-control-flow.md`, `09-typescript-jsx.md`;
`dom-expressions` `packages/dom-expressions/src/jsx.d.ts:137-194, 681-700`; docs.solidjs.com on
`class`/`style`, `on:`, `prop:`, `use:`, `<Dynamic>`, `<For>`/`<Index>`, `<Portal>`

**Leptos** `6196370` — `leptos_macro/src/lib.rs:274-292, 325-346, 381-392`;
`view/mod.rs:108, 301-403, 672-777, 944-982, 1089-1188, 1507-1670`;
`view/component_builder.rs:30-124, 170-176, 236-306, 337-424`; `component.rs:585-600, 1000-1113`;
`leptos_hot_reload/src/parsing.rs:50-65`; `leptos/src/show.rs:10-29`, `for_loop.rs:112-187`,
`children.rs:247, 393`, `lib.rs:256-266`, `Cargo.toml:138-145`;
`tachys/src/html/mod.rs:108-158`, `html/element/mod.rs:349, 424, 510, 534-585, 771-797`,
`html/element/elements.rs:9-70, 228+`, `html/attribute/global.rs:150, 352`, `attribute/key.rs:10-33`,
`renderer/dom.rs:510-570`, `hydration.rs:13-98, 150-250`, `view/mod.rs:40-137, 451-529`,
`view/template.rs:11-51`, `view/keyed.rs:16-79`; `ARCHITECTURE.md:73-150`; the Leptos book, chapters
on the view macro, control flow and iteration

**Dioxus** `fda3dc9` — `packages/rsx/src/node.rs:12-113`, `rsx_block.rs:20-323`,
`element.rs:62-204`, `component.rs:1-17, 364`, `attribute.rs:272-283`, `ifmt.rs:128-309`,
`text_node.rs:11-42`, `forloop.rs:16-53`, `ifchain.rs:13-73`, `template_body.rs:12-14, 607-684,
713-811, 850-867`, `stats.rs`; `packages/core-template/src/{lib.rs:1-60, data.rs:3-45, op.rs:1-66,
path.rs:8-60, anchor.rs:7-23}`; `packages/html/src/elements.rs:15+`;
`packages/html-internal-macro/src/elements.rs:131-160, 337-360, 519-560`; dioxuslabs.com docs on rsx
and attributes

**Yew** `bfa6c19` — `packages/yew-macro/src/html_tree/html_node.rs:11-78`,
`html_element.rs:14-50, 100-141, 333-449, 523-629`, `html_tree/{html_if,html_for,html_while,
html_loop,html_match,html_iterable}.rs`, `derive_props/field.rs:222-233`;
`packages/yew/src/virtual_dom/mod.rs:237-276`, `vlist.rs:21-131`;
`tests/html_macro/element-fail.stderr`, `tests/derive_props/fail.stderr:64-72`

**Sycamore** `48e55bb` — `packages/sycamore-view-parser/src/{ir.rs:10-63, parse.rs:24-69}`,
`sycamore-macro/src/view/codegen.rs:107-121, 183-201+`;
`packages/sycamore-web/src/{elements.rs:254-1190, iter.rs:19-80}`

**Lustre** `e5ca4d8` — `README.md:68, 132-133`; `src/lustre/element.gleam:107`,
`element/html.gleam:18, 219`, `attribute.gleam:34, 148`, `event.gleam:192`;
`pages/reference/for-react-devs.md:49-58` and its text-rendering paragraph

**Imba** `5d0f0eb` — `readme.md:48-58, 102-104`; `packages/imba/src/compiler/lexer.mjs:57, 133-138,
658-660, 1014-1022, 2189, 2242-2255, 2353`; `packages/imba-dev-skill/tags-and-components.md:3-32`;
imba.io/docs/tags

**Scala** — docs.scala-lang.org/scala3/reference/dropped-features/xml.html; the scala-xml wiki FAQ;
github.com/scala/scala3/issues/8214 (Odersky, 2020-02-06); scala/bug#9027;
scala-lang.org/files/archive/spec/2.13/01-lexical-syntax.html and
/10-xml-expressions-and-patterns.html; contributors.scala-lang.org thread 2146

**Elm** — the elm-discuss thread *"HTML-like syntax for elm-html"* (Czaplicki);
guide.elm-lang.org/optimization/lazy.html; github.com/pzavolinsky/elmx

**Gleam** — gleam.run/frequently-asked-questions (macros "not planned");
lpil.uk/blog/how-to-add-metaprogramming-to-gleam/

**Feliz / Fable.Lit / Compose / SwiftUI / Templ / Razor / Svelte / Vue / Marko** —
github.com/Zaid-Ajaj/Feliz; fable.io/Fable.Lit/docs/templates.html;
developer.android.com/develop/ui/compose/mental-model; SE-0289 (result builders);
templ.guide/syntax-and-usage/basic-syntax;
learn.microsoft.com/en-us/aspnet/core/mvc/views/razor (the generics restriction);
svelte.dev/docs/svelte/svelte-files; vuejs.org/guide/scaling-up/sfc.html;
markojs.com/docs/reference/concise-syntax (the `--` text fence)

### Sub-agent reports

Five read-only agents produced the prior-art evidence: Mint; ReScript and the Reason ppx; the JSX
specification, TypeScript's typing and Solid's JSX surface; the four Rust macro DSLs; and the case
against (Scala, Elm, Gleam/Lustre, Imba, Feliz/Fable, Compose/SwiftUI, the SFC family). Each cited
`path:line` at a stated commit or a primary URL, and each was asked to say "could not determine"
rather than guess; §15 carries what they could not close.
