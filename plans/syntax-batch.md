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
| `Int` and `Float` leave `Basics` | [`static-dispatch-spike.md`](../docs/design/static-dispatch-spike.md) A.6, [`checker.md`](../docs/design/checker.md) Appendix B |

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
| Y10 | **Confirm first.** `Int` and `Float` move to `core/Int.beni` and `core/Float.beni`, so `Int.mod n 2`, `Int.rem n 3`, `Float.log x 10` and the methods `n.mod 2`, `x.log 10` exist (the owner's `Int.mod i 10`) | keep both types in `Basics`, add unexposed `mod`, `rem`, `log` there: `n.mod 2` and `Basics.mod n 2` work, `Int.mod` does not | §12.4 |
| Y11 | **Confirm first.** `Debug.log` goes back to Elm's `String, a -> a`, keeping its name | rename it (`Debug.logAs value "label"`), which keeps pipelines and lets a removal diagnostic catch every stale call | §12.4 |
| Y12 | Renamed: only names that name an argument by role (`modBy`, `remainderBy`, `logBase`). Kept: `clamp`, `String.split`/`contains`/`startsWith`/`endsWith`/`indexes`/`indices`/`replace` (JavaScript's, Go's, Rust's order), `List.repeat`, and every function whose Elm-ordered call is a type error | rename every function whose Elm-ordered call still type-checks | §12.4 |
| Y13 | `suspicious_argument_order`, a warning, for the kept functions above when the call has the shape an Elm-ordered one has (a literal subject) | no warning, documentation only | §12.5 |
| Y14 | The formatter does not join the vertical `if`s it wrote until now; only an `if` written on one line stays there | join every `if` that fits, migrating old code (the `=` amendment's choice) | §12.5 |
| Y15 | A hanging application's head arguments ignore source breaks; the head line joins `=` only when the hung argument is a lambda | join for lists and records too, or honour source breaks | §12.5 |
| Y16 | `let` and `in` stay reserved words | release them as identifiers | §12.2 |

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
| 13 | **`Int` and `Float` modules**: `core/Int.beni`, `core/Float.beni`, `mod`, `rem`, `log`, the prelude rows, the well-known table entries, `name_removed` (§12.4; `checker-v2.md` §29.2–§29.3); `--migrate-names` without its `Debug.log` half | code | M | `check/good/TypeOwnerEdges` re-blessed; `check/bad/NameRemoved` for each of the four forms; `run/` that `Int.mod` and `Int.rem` give `modBy`'s and `remainderBy`'s answers, zero divisor included |
| 14 | **Migrate names** over the whole repository (an edit) | mechanical | S | run hashes re-recorded (the emitted names change) |
| 15 | **`Debug.log` label first** and its rewrite, one commit (the exception, `frontend.md` §11.7) | code + mechanical | S | the 24 `run/` fixtures that order by `Debug.log` print what they printed |
| 16 | **Call-style diagnostics**: the three hints, the generalised Elm-order hint, `suspicious_argument_order` (§12.5; `checker-v2.md` §29.4) | code | M | a `check/bad/` fixture per hint; a `check/good/` fixture where the warning fires and one where the method form silences it |
| 17 | **Unicode notation specified** (`browser-decisions.md` S8): `language.md` §12 gains the symbols, their tokens and precedence (each that of the ASCII operator it replaces), `×` in the type grammar beside the n-ary comma (`Int, Int → Int` is two arguments, `Int × Int → Int` one pair), the lookalikes the lexer refuses (`−`, `⇒`, `⟶`, `＜` …) and the removal codes; `frontend.md` §11 the migration | spec | S | the owner confirms the open choices it lists before slice 18 |
| 18 | **Unicode taught**: the lexer reads `→ ← ≠ ≤ ≥` as the tokens they replace and `×` in types, the formatter keeps the spelling it read, `beni fmt --migrate-unicode` | code | S | `parse/good/` and `fmt/` fixtures; a `tokens` golden; the migration on a fixture with `->` in strings, comments and multiline strings left alone |
| 19 | **Migrate Unicode** over every `.beni` file, normative doc examples, core doc comments, Zig test programs, generators and message examples, alone in its commit | mechanical | S | emitted JavaScript byte-identical |
| 20 | **Unicode enforced**: removal diagnostics for `->`, `<-`, `/=`, `<=`, `>=` and a parenthesised tuple type | code | S | one `parse/bad/` fixture per removed form |

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
  for after slice 9.
- **An editor input method for `λ`.** M5's language server is where `\` → `λ` belongs; until then
  the README of the editor support (when there is one) says which key sequence to use.
- **`Float`'s other functions.** `Float.log` is the one this batch needs; whether `round`, `floor`
  and the rest also become `Float` methods is a library question, not a syntax one.
