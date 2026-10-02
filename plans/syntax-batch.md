# The syntax batch of 2026-10-02: decisions and slices

**Status:** plan, 2026-10-02. The owner's decisions S1–S5 are in
[`browser-decisions.md`](browser-decisions.md), *Syntax — 2026-10-02*. The contract they build is
normative and lives in the design documents; this file is the order of work, what each step owes,
and the choices the specification had to make that the owner should confirm.

| Contract | Where |
|---|---|
| S1 `λ`, S2 blocks, S3 trailing lambdas, S4 names, S5 formatter, gate and diagnostics | [`language.md`](../docs/design/language.md) §12.1–§12.5, with dated pointers in §0, §2, §3, §4, §6.6, §6.7, §7, §8, §9, §10 and Appendix A |
| one program before and after | `language.md` §12.6 |
| lexer, parser, AST, BIR, migrations, the `fmt --check` gate, the formatter's measure | [`frontend.md`](../docs/design/frontend.md) §11 (pointers in §1, §3.5–§3.7, §9.3) |
| `statement_not_unit`, `name_removed` at a qualified name, `Int`/`Float` modules, call-style hints, `suspicious_argument_order` | [`checker-v2.md`](../docs/design/checker-v2.md) §29 |
| a statement is a discard; `Int.mod` stays a call | [`backend.md`](../docs/design/backend.md) §4 |
| `Int` and `Float` modules beside `Basics`, which keeps both types (amended 2026-10-01) | [`static-dispatch-spike.md`](../docs/design/static-dispatch-spike.md) A.6, [`checker.md`](../docs/design/checker.md) Appendix B |
| S8 Unicode notation: the symbols, `×` tuple types, lookalikes, removal codes, columns, formatter, editor input | `language.md` §12.7–§12.9, with dated pointers in §0, §2.1, §2.2, §2.4, §3, §6.5, §6.8, §9, §10, §12.1 and Appendix A; `frontend.md` §11.8 (pointers in §1, §3.1); `checker.md` §8.2 for the renderer |
| S10 `⊤` and `⊥`, `if` without `else`, `_ = e` of a `⊤` | `language.md` §12.10, with dated pointers in §0, §6.1, §10, §12.1 and Appendices A and B; `frontend.md` §11.9; `checker-v2.md` §34; `backend.md` §4 (*A `()` result is not written*, amended) |

Precedent read for it: Roc's blocks and statements (`references/roc/docs/langref/statements.md`,
`expressions.md`; `src/check/Check.zig:21835-21848` unifies a statement with `{}` and
`src/check/report.zig:1580-1597` says so; `src/canonicalize/Can.zig:9401-9406` gives a block that
ends in a binding an implicit `{}`; `src/canonicalize/test/local_let_scoping_test.zig` forbids
forward references and mutual recursion between local definitions), and F#'s offside rule, which
pushes a layout context after `=`, `->`, `then`, `else` and an opening bracket and permits closing
delimiters and infix operators to sit at a context's column.

---

## 1. Decisions

### 1.1 Taken by the owner (2026-10-02)

S1 `λ` only, `\` removed with a diagnostic and a migration. S2 `let … in` dropped for indentation
blocks of bindings and statement lines, the last line the value. S3 a lambda as the last argument
without parentheses. S4 no Elm name with a flipped argument order; `modBy`/`remainderBy` give way,
`Debug.log` keeps label-then-value or is renamed, the rest audited. S5 four formatter fixes,
`beni fmt --check` in the gates, call-style diagnostics.

### 1.2 Made by the specification — for the owner to confirm

Each is reversible until its slice lands; the ones marked **confirm first** change what a
mechanical commit writes, so they are cheapest to change before slice 7.

| # | Decision | Alternative | Where |
|---|---|---|---|
| Y1 | A thunk is `λ() -> e`; there is no `λ-> e` shorthand | the shorthand: one more spelling for two characters | §12.1 |
| Y2 | `beni fmt` does not turn `\` into `λ`; an editor or the language server does, and `--migrate-lambda` migrates files | let plain `fmt` accept `\` and print `λ`, which makes `\` a second input spelling | §12.1 |
| Y3 | **Confirm first.** Five openers start a block — `=`, `->`, `then`, `else`, and a `(` that ends its line; a body starts a block only when its first token begins a line. Not a record field's `=`, not `<\|`, not a markup hole | F#'s rule: a block after every bracket and `=`, which makes a record field holding a block legal | §12.2 |
| Y4 | A statement must be `()` (`statement_not_unit`); `_ = e` discards anything | warn instead of refusing; Roc refuses too | §12.2 |
| Y5 | A block ending in a binding is an error (`block_ends_in_binding`), not an implicit `()` | Roc's implicit `{}` | §12.2 |
| Y6 | `<-` stays, binding the rest of the block | remove it now that statements exist; it is not what statements do (a callback may run the rest zero or many times) | §12.2 |
| Y7 | A block keeps `let`'s scoping: functions mutually recursive in any order, values in written order with `let_forward_reference` | Roc's strictly sequential local scope, which would refuse programs that check today | §12.2 |
| Y8 | A `<` that begins a line opens markup whatever precedes it (a lexer rule), so a block's markup value can follow a binding | require parentheses around markup after a binding | §12.2, `frontend.md` §11.1 |
| Y9 | A trailing lambda whose body starts on the `->` line ends at the first later line not indented past the line the `λ` is on — so a `\|>` pipeline of trailing lambdas reads stage by stage | greedy to the end of the expression, as `<\|` is, which reads `xs \|> List.filter λt -> t.done` / `\|> List.length` as one lambda | §12.3 |
| Y10 | **Decided by the owner, 2026-10-01**, replacing the move S6 confirmed: `Int` and `Float` stay in `Basics`; `core/Int.beni` and `core/Float.beni` are ordinary modules holding only `mod`, `rem` and `log`, beni over `Js`, importing `Basics`, in the prelude's module aliases. `Int.mod n 2`, `Int.rem n 3` and `Float.log x 10` work; the methods `n.mod 2` and `x.log 10` are not offered. *Why:* moving the types makes an import cycle — `Basics` keeps `Int`- and `Float`-typed functions and literals, and the new modules need `Bool`, `Order` and the operators of `Basics` (`browser-decisions.md` S9) | the move as first specified, which needs `Bool`, `Order` and the operators moved too; or `mod` in `Basics`, giving `n.mod 2` and no `Int.mod` | §12.4 |
| Y11 | **Confirm first.** `Debug.log` goes back to Elm's `String, a -> a`, keeping its name | rename it (`Debug.logAs value "label"`), which keeps pipelines and lets a removal diagnostic catch every stale call | §12.4 |
| Y12 | Renamed: only names that name an argument by role (`modBy`, `remainderBy`, `logBase`). Kept: `clamp`, `String.split`/`contains`/`startsWith`/`endsWith`/`indexes`/`indices`/`replace` (JavaScript's, Go's, Rust's order), `List.repeat`, and every function whose Elm-ordered call is a type error | rename every function whose Elm-ordered call still type-checks | §12.4 |
| Y13 | `suspicious_argument_order`, a warning, for the kept functions above when the call has the shape an Elm-ordered one has (a literal subject) | no warning, documentation only | §12.5 |
| Y14 | The formatter does not join the vertical `if`s it wrote until now; only an `if` written on one line stays there | join every `if` that fits, migrating old code (the `=` amendment's choice) | §12.5 |
| Y15 | A hanging application's head arguments ignore source breaks; the head line joins `=` only when the hung argument is a lambda | join for lists and records too, or honour source breaks | §12.5 |
| Y16 | `let` and `in` stay reserved words | release them as identifiers | §12.2 |

### 1.3 Unicode notation (S8) — made by the specification, confirmed by the owner

Slice 17's open choices. **Confirmed 2026-10-02: the owner took all fifteen as recommended**, and
named three explicitly — Z2, `a × b × c` is a flat 3-tuple; Z4, columns count code points
everywhere (diagnostics, excerpt carets, layout and the formatter's 100-column limit), which also
removes §12.1's `λ` byte exception; Z9, `▷` U+25B7 and `◁` U+25C1. The Alternative column stays
as the record of what was weighed. **Confirm first** marked the ones that change what slice 19's
mechanical commit writes. Sections are `language.md`'s unless named.

| # | Decision | Alternative | Where |
|---|---|---|---|
| Z1 | Each symbol is a token tag of its own; the ASCII spellings' tags are renamed `ascii_*` and, from slice 20, lexed only to be refused (as `\` is) | one tag per pair with the length stored elsewhere — the token SoA derives length from the tag, so that is a new column | §12.7, `frontend.md` §11.8 |
| Z2 | **Confirm first.** `×` is n-ary and flat: `a × b × c` is a 3-tuple, `a × (b × c)` a pair holding a pair | Lean's right-nested `infixr`, which makes `a × b × c` a type no `( a, b, c )` value has | §12.8 |
| Z3 | Precedence: application, then `×`, then the parameter comma, then `→` (Lean's order), so `Int × Int → Int` takes one pair and `Int, String × Bool → Order` two arguments | require parentheses around a product that is a function parameter | §12.8 |
| Z4 | **Confirm first.** From slice 18 a column counts code points — diagnostics, excerpt carets, layout and the formatter's 100-column measure — so `→` is one column; this also removes §12.1's `λ` exception | keep byte columns, and every caret after a symbol on its line drifts right by one or two, on most lines of a program | §12.7, §12.9, `frontend.md` §3.1 |
| Z5 | One removal code, `ascii_symbol_removed`, for all eight ASCII spellings (the message names the symbol), and `tuple_type_removed` for `( a, b )` in a type | one code per spelling (`arrow_removed`, `pipe_removed` …), as `cons_removed` and `let_removed` are each one | §12.7, §12.8, §10 |
| Z6 | Removal is reported at every occurrence, each with its span | once per file with a count, which a CLI reader prefers but an editor cannot place | §12.7 |
| Z7 | Lookalikes reuse `invalid_character` (and `expected_token`/`unexpected_token` for `=>` and `*` in a type) with the symbol named, and the parse goes on as the symbol through a `lookalike` token | a new code, `lookalike_character`, for tools to route on | §12.7, `frontend.md` §11.8 |
| Z8 | The lookalike set: `−` `－` → `-`; `⇒ ⟶ ⟹ ➝ ➔ ↦` → `→`; `⟵ ⇐` → `←`; `≦ ⩽` → `≤`; `≧ ⩾` → `≥`; `▶ ▹ ▸ ▻ ⊳` → `▷`; `◀ ◃ ◂ ◅ ⊲` → `◁`; `⋯ ‥` → `…`; `⨯ ✕` → `×`; the fullwidth block named; `!=` → `≠`. `Λ` stays unexplained `invalid_character` | a shorter list, or `Λ` → `λ` too | §12.7 |
| Z9 | **Confirm first.** `▷` U+25B7 and `◁` U+25C1, the white triangles (Lean's editor gives them for `\rhd`/`\lhd`) | `▹`/`◃` (what Lean gives for `\triangleright`), or `⊳`/`⊲`; Lean itself writes `\|>` and `<\|` in ASCII | §12.7 |
| Z10 | `…` replaces `...` everywhere, a tag's attribute spread `{…attrs}` included, though JSX writes `{...props}` | keep `...` in markup only, which is two spellings of one token | §12.7, §6.8 |
| Z11 | `×` is a type token only; `2 × 3` is `unexpected_token`, pointing at `*` | let `×` also multiply, a second spelling of `*` | §12.7 |
| Z12 | The type renderer (`checker.md` §8.2) and every compiler message that quotes code switch to the symbols in slice 20, with the removal codes | switch in slice 18, while both spellings are accepted | §12.8, §12.9 |
| Z13 | The editor and language server replace the ASCII as it is typed, in code only (`->` becomes `→`, `*` in a type `×`); no Lean-style backslash abbreviations, since `\` already becomes `λ` | Lean's `\to`, `\le`, `\x` … abbreviations | §12.9 |
| Z14 | `--migrate-unicode` touches only tokens and tuple-type nodes, never a comment or string; slice 19 rewrites core's doc comments, Zig test programs, generators and the design docs' examples by a reviewed script in the same commit, joins multi-line tuple types onto one line, then runs plain `beni fmt` over the gate's scope | a comment mode in the flag, or doc comments left in ASCII until the docs test fails | §12.9, `frontend.md` §11.8 |
| Z15 | The `ast` and `bir` dumps name an operator by its symbol whichever spelling was read, from slice 18, so the two spellings dump byte-identically and the teach slice can prove it | print the spelling read, and prove equivalence some other way | §12.7, `frontend.md` §11.8 |

### 1.4 `⊤`, `⊥` and `if` without `else` (S10) — made by the specification, for the owner to confirm

The owner decided S10 on 2026-10-02 (`browser-decisions.md`): `⊤` U+22A4 is the unit type and its
value, replacing `()` in both roles; `⊥` U+22A5 is the empty type, today's `Never`; an `if` may
omit `else` when its `then` branch is `⊤`; every `_ = e` whose `e` is `⊤` becomes a statement
line. The contract is `language.md` §12.10, `frontend.md` §11.9, `checker-v2.md` §34 and a note
in `backend.md` §4 (*A `()` result is not written*). These are the choices the specification
made; **confirm first** marks those that change what slice 23's mechanical commit writes.

| # | Decision | Alternative | Where |
|---|---|---|---|
| T1 | `⊥` names core's empty type wherever it stands and cannot be shadowed; `Basics` keeps declaring it as `type Never = JustOneMore ⊥`, a declaration needing an upper identifier, and the name is written only there from the enforce step | make `⊥` a checker built-in with no declaration — `never`, exhaustiveness and the interface format would all move for no user-visible gain | §12.10 |
| T2 | `⊥` is a type token only; in an expression or a pattern it is `unexpected_token` whose message points at `never` | let `⊥` also be an expression (a second `Debug.todo`), or an absurd pattern | §12.10 |
| T3 | The `T` lookalike is resolution's: an **unbound** `T`, as a type or a constructor, gets a "did you mean `⊤`" sentence in its existing `unbound_type`/`unbound_constructor` message; a `T` the program declares or imports is never questioned | a warning on every declaration named `T` (`suspicious_name`), which would fire on legitimate code | §12.10 |
| T4 | Five lexer lookalikes: `⟙` `⫟` `⊺` → `⊤`, `⟘` `⫠` → `⊥` (`invalid_character`, the parse going on as the symbol) | none, or a longer list (box-drawing `┬`/`┴`, which no font confuses in code) | §12.10 |
| T5 | **Confirm first.** `( )` with whitespace between is `()` and migrates and is refused alike; with a comment between it is refused the same way, and the flag names the file for a hand edit | refuse `( )` now as malformed | §12.10, `frontend.md` §11.9 |
| T6 | `()` in markup text and quoted attribute values is text and never touched; in a markup hole or `{…}` attribute value it is code and migrates | — (the lexer already separates them) | §12.10 |
| T7 | Two removal codes, `unit_spelling_removed` (parser, every position) and `never_spelling_removed` (lowering, only a `Never` that names `Basics`'), both going on as the new spelling | one code `ascii_symbol_removed` for `()` too; one code for both | §12.10, §10 |
| T8 | The prelude keeps exposing `Never` after the enforce step, solely so a stale use gets `never_spelling_removed` and not `unbound_type` | drop it from the prelude and add a hint to `unbound_type` | Appendix A |
| T9 | **Confirm first.** A dangling `else` goes to the nearest `if` without one inside whose block it stands — layout first, so an `else` at the outer `if`'s column belongs to it; on one line the nearest (OCaml, F#, Rust, Scala) | refuse an `if` without `else` as the `then` branch of an `if` with one unless parenthesised | §12.10 |
| T10 | The `then` branch of an `if` without `else` must be `⊤`: `if_without_else_not_unit`, title MISSING ELSE, at the `then` branch, its message suggesting `else` | report at the `if`; or give such an `if` a `Maybe` value (a silent default, which rule 7 forbids) | §12.10, `checker-v2.md` §34 |
| T11 | The missing branch lowers to the `unit` instruction of `else ⊤`, marked by `lhs` 1 for the checker, so no pass but `caseExpr` changes and the JavaScript is byte-identical | a new BIR instruction, which every pass from `Exhaustive` to the emitter would have to learn | `frontend.md` §11.9 |
| T12 | `_ = e` with `e : ⊤` is the warning `unit_discarded`, root package only — under `--explain` until the enforce step, by default after it | no diagnostic (a migration only, so the norm decays); or an error (taste, not a guarantee — rule 7) | §12.10, `checker-v2.md` §34 |
| T13 | **Confirm first.** The typed half of the migration is driven by the checker's output: `beni check --explain --diagnostics=json` over every project and fixture, then `beni fmt --migrate-top --discards=<file>`, which deletes `_ = ` at each `unit_discarded` span | a typed rewrite inside `beni check` (a checker that writes files); a script over the `types` dump | `frontend.md` §11.9 |
| T14 | **Confirm first.** The flag drops `else ⊤` (either spelling) from every `if`, except one an `else` follows — it ends the `then` branch of an outer `if`, whose `else` would move to it — or one with a comment in the range; plain `beni fmt` never adds or removes an `else` | keep every `else ⊤` and let authors drop them; or have plain `fmt` drop them | §12.10, `frontend.md` §11.9 |
| T15 | The renderer, every message that quotes code, the call-style hints and `Debug.toString` switch to `⊤`/`⊥` in the enforce step (Z12's order); a type's run-time identity text and the cache's type-body digest keep `()`, being keys and not source | switch in the teach step; or keep `Debug.toString` printing `()` | §12.10, Appendix B, `checker-v2.md` §34 |
| T16 | **Confirm first.** The flag rewrites a type name `Never` (and `Basics.Never`) to `⊥` unless the file declares or imports by name a `Never` of its own — a per-file syntactic test, since the formatter resolves nothing | a typed rewrite, as for `_ =` | `frontend.md` §11.9 |

---

## 2. Slices

Every slice is one commit and leaves `zig build gates` green. Each piece of syntax moves in three
steps — **teach** (the compiler accepts the new form and still the old), **migrate** (a mechanical
commit that runs a flag and does nothing else), **enforce** (the old form refused, or only the new
one printed) — so no commit is half-landed (`frontend.md` §11.7). Sizes: **S** under a day, **M** one
to two days, **L** three to four.

| # | Slice | Kind | Size | Owes |
|---|---|---|---|---|
| 1 | **Formatter rules**: one-line `if`, hanging last arguments, the blank line after a standalone comment, the aligned first parameter (§12.5; `frontend.md` §11.7) | code | M | `fmt/` fixtures per rule, each a fixed point; the `AlreadyCanonical*` set updated |
| 2 | **Reformat** everything the gate will cover with plain `beni fmt` | mechanical | M | `emit/` goldens and run hashes unchanged (formatting moves no emitted byte); `.diag` goldens re-blessed, and the bless diff moves positions only |
| 3 | **The gate**: `beni-fmt-check` in `gates`, `tests/fmt-exempt.txt` with a reason per file (`frontend.md` §11.6) | code | S | a black-box test that a non-canonical file and a stale exemption both fail it |
| 4 | **`λ` taught**: the `lambda` token, the parser accepting `λ` and `\` alike, the formatter keeping the spelling it read, `--migrate-lambda` (§12.1; `frontend.md` §11.1, §11.4) | code | S | `parse/good/` and `fmt/` fixtures in `λ`; a `tokens` golden; the migration on a fixture |
| 5 | **Migrate `λ`**: `--migrate-lambda` over every `.beni` in the repository, exemptions included (it is an edit) | mechanical | S | emitted JavaScript byte-identical: `test-run-hashes` records nothing new |
| 6 | **`λ` enforced**: `backslash_lambda_removed`; core's doc comments in `λ` | code | S | `parse/bad/BackslashLambda` |
| 7a | **Blocks taught**: `parseBody`, items, layout B1–B6, the parenthesised block, the line-start markup rule, `block`/`stmt` nodes, lowering to `let`, `block_ends_in_binding` (§12.2; `frontend.md` §11.1–§11.3) | code | L | `parse/good/` and `parse/bad/` per layout rule; `bir/` goldens showing a block's BIR identical to the `let`'s; `run/` fixtures for evaluation order and a forward reference in a block |
| 7b | **Statements**: `let_stmt`, `statement_not_unit` (`checker-v2.md` §29.1), `Lower.discard` for it; the formatter printing blocks; `--migrate-let` (`frontend.md` §11.5) | code | M | `check/bad/StatementNotUnit` (a `List.push` line), `run/` statements with `Debug.log`, `emit/` a statement; the migration on a fixture with a `let` in each position |
| 8 | **Migrate `let`**: `--migrate-let` over the gate's scope; the `let` fixtures outside it (about 50 under `tests/corpus/parse/` and `fmt/`) rewritten by hand as block fixtures | mechanical, then hand | M | run hashes unchanged except where nested `let`s were flattened, each of those checked against its `.expected` |
| 9 | **`let` enforced**: `let_removed`; `let_forward_reference`'s and `refutable_let_pattern`'s texts say "block" | code | S | `parse/bad/LetRemoved` |
| 10 | **Trailing lambdas taught**: `parseApp` and the body-end rule (§12.3); `--migrate-trailing-lambda` | code | M | `parse/good/` for the pipeline case, markup holes, `<-`, `_`; `parse/bad/` for a lambda followed by an argument |
| 11 | **Migrate trailing lambdas** over the gate's scope | mechanical | S | emitted JavaScript byte-identical |
| 12 | **Trailing lambdas enforced**: the formatter's own rule; `<\| λ` printed as a trailing lambda | code | S | `fmt/` fixtures |
| 13 | **`Int` and `Float` modules**: `core/Int.beni`, `core/Float.beni`, `mod`, `rem`, `log`, the prelude rows, `name_removed` (§12.4; `checker-v2.md` §29.2–§29.3, both amended 2026-10-01); `--migrate-names` without its `Debug.log` half | code | M | `check/good/TypeOwnerEdges` unchanged (the types do not move); `check/bad/NameRemoved` for each of the four forms; `run/` that `Int.mod` and `Int.rem` give `modBy`'s and `remainderBy`'s answers, zero divisor included, and `Float.log` `logBase`'s |
| 14 | **Migrate names** over the whole repository (an edit) | mechanical | S | run hashes re-recorded (the emitted names change) |
| 15 | **`Debug.log` label first** and its rewrite, one commit (the exception, `frontend.md` §11.7) | code + mechanical | S | the 24 `run/` fixtures that order by `Debug.log` print what they printed |
| 16 | **Call-style diagnostics**: the three hints, the generalised Elm-order hint, `suspicious_argument_order` (§12.5; `checker-v2.md` §29.4) | code | M | a `check/bad/` fixture per hint; a `check/good/` fixture where the warning fires and one where the method form silences it |
| 17 | **Unicode notation specified** (`browser-decisions.md` S8): `language.md` §12 gains the symbols, their tokens and precedence (each that of the ASCII operator it replaces), `×` in the type grammar beside the n-ary comma (`Int, Int → Int` is two arguments, `Int × Int → Int` one pair), the lookalikes the lexer refuses (`−`, `⇒`, `⟶`, `＜`, and `▶`, `▹`, `⊳` beside `▷` …) and the removal codes; `frontend.md` §11 the migration | spec | S | the owner confirms the open choices it lists before slice 18 |
| 18 | **Unicode taught**: the lexer reads `→ ← ≠ ≤ ≥ ▷ ◁ …` as the tokens they replace and `×` in types, the formatter keeps the spelling it read, `beni fmt --migrate-unicode`; *added by slice 17:* the lookalikes refused, columns and the formatter's measure in code points (`frontend.md` §11.8) | code | S | `parse/good/` and `fmt/` fixtures; a `tokens` golden; the migration on a fixture with `->` in strings, comments and multiline strings left alone; *added:* AST and BIR dumps byte-identical for `Int × String` and `( Int, String )`; a `parse/bad/` fixture per lookalike group; a `.diag` golden whose caret follows a `→` on its line |
| 19 | **Migrate Unicode** over every `.beni` file, normative doc examples, core doc comments, Zig test programs, generators and message examples, alone in its commit | mechanical | S | emitted JavaScript byte-identical |
| 20 | **Unicode enforced**: removal diagnostics for `->`, `<-`, `/=`, `<=`, `>=`, `\|>`, `<\|`, `...` and a parenthesised tuple type; *added by slice 17:* `ascii_symbol_removed` and `tuple_type_removed`, the type renderer and the compiler's messages in the symbols | code | S | one `parse/bad/` fixture per removed form |
| 21 | **`⊤` and `⊥` specified** (`browser-decisions.md` S10): `language.md` §12.10, `frontend.md` §11.9, `checker-v2.md` §34, the `backend.md` §4 note; §1.4's T1–T16 | spec | S | the owner confirms the **confirm first** rows before slice 23 |
| 22 | **`⊤`, `⊥` and `if` without `else` taught**: the `top` and `bottom` tokens and their lookalikes; `⊤` beside `()` in types, expressions and patterns; `⊥` beside `Never`; `if_then` and `if_without_else_not_unit`; `unit_discarded` under `--explain`; the `T` sentence; the formatter; `beni fmt --migrate-top` with `--discards` | code | M | `parse/good/` for each position and the dangling `else` by layout and on one line; `parse/bad/` for `⊥` in an expression and a lookalike; `check/bad/` `IfWithoutElseNotUnit`, an unbound `T`, `unit_discarded` under `--explain`; `run/` for an `if` without `else` as a statement, a last line and a branch; BIR of `⊤` and `()`, `⊥` and `Never`, and `if c then a` and `if c then a else ()` identical; `fmt/` fixtures; the migration on a fixture with `()` in strings, comments and markup text left alone |
| 23 | **Migrate `⊤`**: `check --explain --diagnostics=json` over every project and fixture, the flag with that file over every `.beni`, plain `beni fmt` over the gate's scope; then the hand pass by reviewed script — doc comments, design-document examples, Zig test programs, generators, message examples | mechanical | M | emitted JavaScript byte-identical for every `run/` and `browser/` program, development without source maps and release, checked by script; run hashes re-recorded; `.diag` goldens moved by position only |
| 24 | **`⊤` enforced**: `unit_spelling_removed`, `never_spelling_removed`, `unit_discarded` on by default, the renderer, the messages and `Debug.toString` in `⊤` and `⊥`; CLAUDE.md's examples | code | S | one `parse/bad/` or `check/bad/` fixture per removed form; the run hashes `Debug.toString` moves |

*Slice 17, as written (2026-10-01).* The contract is `language.md` §12.7–§12.9 and `frontend.md`
§11.8; its open choices are §1.3's Z1–Z15. Lean 4's spellings and precedences were read from its
`src/Init/Notation.lean` and `Init/Core.lean` (`×` `infixr:35`, `≤ ≥ ≠` `infix:50`, `|>` and `<|`
ASCII at `min`) and its editor abbreviations from `vscode-lean4`'s `abbreviations.json`. Two
findings: Lean has no symbol for the pipes or the spread, so `▷`, `◁` and `…` are beni's own
(Z9, Z10); and the excerpt renderer pads its `^` by byte columns, so a caret after a `λ` is
already one place off today — Z4 is what fixes it.

*As built, slices 13–16 (2026-10-01).* Seven commits, each gates-green. Slice 13 split in two
around 14, so that no commit is half-landed: the `Int` and `Float` modules with `--migrate-names`
(the old names still working), then 14's rewrite, then `name_removed` with the three names gone
from `Basics` — a commit refusing `modBy` before the repository stopped writing it would have been
red. Slice 15 likewise: the flag's `Debug.log` half first, then `Debug.log`'s new order with the
rewrite (the exception), the 49 calls the flag named — a label held in a variable, two literals —
turned round by hand in that commit. `check/good/TypeOwnerEdges` did not move (Y10 as amended).
The `NameRemoved*` fixtures are written in the old names on purpose: **re-running
`--migrate-names` over `tests/` rewrites them, so restore those four files after a re-run.**
Slice 16's Elm-order hint is a read-only fit test, not §7.5 speculation (`checker-v2.md` §29.4,
*As built*).

*As built, Z4 and slices 18–20 (2026-10-02).* Columns count code points first, alone — a caret
after a `λ` had stood one place right, and eleven files whose hung lambda now fit in 100 columns
were joined in that commit. Then 18 (both spellings; dumps name operators by their symbols, so the
BIR goldens moved there and only there), 19 in two commits — the flag alone (`beni fmt
--migrate-unicode`, 1 413 files, JavaScript byte-identical in both builds, every BIR unchanged)
and the reviewed-script pass — each preceded by a fix the migration found in a message that read
source text for `->` or `|>`, and 20, preceded by the source-map column fix the migrated tests needed.
The one departure from the plan's row for 19: compiler message texts switched in 20, with the
renderer, as Z12 orders, not in 19. `frontend.md` §11.8 has the *As built* notes.

*As built, slices 10–12 (2026-10-02).* Six commits, each gates-green: 10, two formatter fixes the
migration's dry runs found (a `λ` measured as one byte, so a lambda could end a 101-byte line; and
a hung lambda measured with the breaks and parentheses the printer drops, so the migration's output
was not a fixed point of plain `fmt`), 11 alone (`--migrate-trailing-lambda`, 266 files; every
`run/` and `browser/` program's JavaScript byte-identical in development without source maps and in
release, every migrated file's BIR identical, 12 `.diag` goldens moved by position only), 11's hand
pass (doc comments, design-document examples, Zig test programs, `bench/gen.zig` and the compare
printer), then 12. The choices the specification left open are `frontend.md` §11.2 and §11.5's
*As built* notes: *"the lambda ends its line"* read as "nothing that would continue its body
follows it" (a closer or a comma may); the parentheses kept for the first operand of a broken
chain, an operand of a one-line chain but the last, before `?`, and with a comment on a
parenthesis or in the head; `<|` written as a trailing lambda only for a call without `_`, a name
or an accessor, in a chain of one `<|`; the hanging head line not counting `λparams ->` except
when it joins `=`; and an argument after a bare lambda `unexpected_token`
(`argument_after_lambda`). Two doc-comment examples whose lambda body holds an `==` keep their
parentheses: bare, the doc-example gate reads the line as an `expr == value` assertion.

**Dependencies.** 1 → 2 → 3 first, because every reformatting migration (8, 11) relies on the gate
holding its files canonical, and the blocks' safety argument (`language.md` §12.2) relies on
canonical layout. 4–6 next, because `λ` is the smallest piece and every later fixture is written in
it. 7a → 7b → 8 → 9, then 10 → 11 → 12 (a trailing lambda's body is a block, so 10 needs 7a). 13–15
and 16 depend only on 3 and may run beside 7–12; 16's warning table is §12.4's, so after 13.
17–20 (S8) come after 12 and 14, so their mechanical commit lands on a tree no other migration
is rewriting. Total: about three weeks of slices, of which the mechanical commits are minutes each to produce and
most of the review.

## 3. Coordinating with work that edits `.beni` files

The mechanical commits touch most of the repository's 1 750 `.beni` files — `core/`, the platforms
(the runtime-in-beni port is rewriting `platforms/browser/` now), `bench/` and the corpus.

- **Land each mechanical commit alone and fast**, announced to whoever has a branch open on `.beni`
  files, and rebase onto it at once.
- **Never hand-merge a conflict in a migrated file.** Every migration is deterministic and reaches
  its fixed point in one run, so: take your side of the file, run the same flag on it (or `beni fmt`
  for slice 2), and commit the result. The flag that produced each mechanical commit is named in its
  message.
- **After slice 3, every edit to a `.beni` file in the gate's scope runs `beni fmt` on it**, or the
  gate fails; agents writing fixtures that pin a layout add the file to `tests/fmt-exempt.txt` with
  a reason, in the same commit.
- **Write new code in the new syntax as soon as its teach slice lands** (4, 7b, 10, 13), so it never
  needs migrating; code written in the old syntax before the enforce slice is migrated by the flag
  like everything else.
- A fixture whose **point** is the old syntax — `let`'s layout, `\` next to `\\` — is not migrated
  but rewritten for the new form, or retired with the form, in the enforce slice.

## 4. What is not decided here

- **Turning `_ = e` into a statement line where `e` is `()`.** The migrations keep every `let _ =`
  as `_ =`, which is always correct; finding the ones whose value is `()` needs types, so it is a
  checker-assisted cleanup (an informational hint naming them, or a pass over the `types` dump) left
  for after slice 9. *Decided 2026-10-02 (S10, slices 21–24):* the checker's `unit_discarded`
  warning finds them, and `beni fmt --migrate-top --discards=<file>` removes the `_ =` (T12, T13).
- **An editor input method for `λ`.** M5's language server is where `\` → `λ` belongs; until then
  the README of the editor support (when there is one) says which key sequence to use.
- **`Float`'s other functions.** `Float.log` is the one this batch needs; whether `round`, `floor`
  and the rest also move to the `Float` module is a library question, not a syntax one.

*As built, slices 21–24 (2026-10-02).* Six commits: 21, the specification; 22, the teach step;
23, the mechanical commit (`beni fmt --migrate-top --discards`), the code commit that lets
`--explain` name every package's discards, and the reviewed-script hand pass; then 24.
The finding the migration made: a removed `_ =` is one BIR instruction fewer, and a markup site's
development name carries its instruction's number, so 27 markup programs' development JavaScript
moved by those names alone (release, every other program and every `emit/` golden byte-identical;
`frontend.md` §11.9's *As built*). The T-rows were built as written but T14, which the teach step
refined: an `else ⊤` is kept when an `else` follows it, the drops decided last first so that one
run is the fixed point. The owner has not yet confirmed §1.4.
