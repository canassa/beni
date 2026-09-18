# M3b audit — what is actually missing, by experiment

Read-only. Written 2026-09-18 against `889c4fa` (queue slice 7). `backend.md` §1 defines M3b as
"Tail-call loops, decision trees, interpolation, `?`, tuples, record update, `Int32`, everything
remaining. Acceptance: the corpus compiles and runs" — a list assembled before M3a shipped. This
establishes what is missing **today**, construct by construct, against §4's codegen table and
`language.md` §3's grammar.

**Method.** A Debug `beni` built from a throwaway worktree of `889c4fa`. Each construct is a
minimal `Main.beni` in a fresh temp project, built with `beni build --platform=node --out=out` and
then run with `node out/main.mjs` (Node 24.19.0). "Works" means exit 0, no diagnostic, and the right
answer printed. Nothing in the repository was modified. The three gates were not re-run in the main
checkout because other agents were mid-edit; `zig build test-blackbox` was run in the worktree
instead and **passed**, so every number below is against a green `889c4fa`.

---

## Miscompiles — exit 0, wrong answer

### **M1. A refutable pattern in a function or lambda parameter compiles to an unchecked destructure**

`language.md` §3's `Definition := lower_ident PatAtom* '=' Expr` admits every `PatAtom`, which
includes constructors, literals and nullary constructors. §7 makes only **`let`** patterns
irrefutable (`refutable_let_pattern`), and `checker.md` §6.6's exhaustiveness runs on **`case`**.
A parameter pattern is neither, so nothing rejects it and nothing checks it. The backend's
`functionOf` (`src/js/Lower.zig:745`) emits the pattern's *bindings* with no test at all.

| Program | Prints | Should |
|---|---|---|
| `un (Just n) = n` … `un Nothing` | `null` | not compile |
| `f 0 = 99` … `f 5` | `99` | not compile |
| `g (x :: rest) = x` … `g []` | `null` | not compile |
| `(\(Just n) -> n) Nothing` | `null` | not compile |

All four exit 0 from both `beni build` and `node`. This is the exit-0-wrong-answer failure mode
`backend.md` §12 says a `run/` fixture exists to catch, and there is no fixture for it.

**It is not the backend's to fix.** The tree of `backend.md` §7 would have nowhere to send the
failing value either; the hole is that the grammar admits the pattern. Two candidate fixes, for the
implementer of the slice to choose between with the owner:

1. **Narrow the grammar** — `Definition`'s parameters become `LetPattern` (irrefutable), refutable
   ones raise `refutable_let_pattern` or a sibling code. This is Elm's rule and the smallest change.
2. **Check them** — run `check/Exhaustive.zig` over each parameter pattern as a one-row `case` and
   report `missing_patterns`. Better messages, more surface.

Either way it needs a fail-first fixture per row of the table above (`check/bad/`, not `run/`, once
it is refused).

No other miscompile was found. 49 emitted modules from the `check/good` sweep load and evaluate
their top-level bindings without throwing; arithmetic (`//`, `^`, `modBy`, `remainderBy`, `round`,
`floor`, negative operands), structural `==`/`<` over records, lists, tuples and `Char`, and
`String` length over non-ASCII all give the expected answers.

---

## Construct by construct

Rows are grouped: `backend.md` §4's codegen table first, then grammar forms §4 does not name.

| Construct | Status | Evidence | Slice |
|---|---|---|---|
| top-level value, function of *n* params, saturated call | works | every probe | — |
| record literal, field access, accessor `.f` | works | `{ x = 1 }.x`, `List.map xs .n` | — |
| **record update `{ r \| x = 9 }`** | **works** | prints `9`, `2` — `spread_property`, `JsIr.zig` | M3b list is stale |
| constructor, nullary constructor, padding | works | `emit/`, `run/Adt.beni` | — |
| **tuple literal, `t.0`, tuple pattern, tuple param** | **works** | `(1,2,3).2` is `3`; `swap (a, b) = (b, a)` | M3b list is stale |
| list, cons cells, `[]`/`::`/list patterns | works | `run/ConsPatterns.beni`, probes | — |
| string, `++`, `Char` as one-scalar string | works | `String.length "héllo"` is `5` | — |
| `Int` as a double | works | `7 // 2` = 3, `-7 // 2` = -3, `2 ^ 10` = 1024 | — |
| **`Int32`** | **absent from the language**, not just the backend | `Int32` is in no `core/*.beni` and no `docs/design/language.md`; `a : Int32` is `unbound_type`, `Int32.toInt` is `unknown_module_alias` | needs a core module + a spec paragraph, or striking from M3b |
| `case` → a decision tree (§7) | **linear if/else chain, not a tree** | `backend.md` §7's measured table: 17 tests where 2 suffice | **slice 6** (spec now landed) |
| `if` | works | ternary or `if`/`else` | — |
| `let`, mutually recursive `let` | works | `isEven`/`isOdd` in one `let` prints `even` | — |
| **string interpolation** | **works** | `"n is ${String.fromInt n}!"` → template literal, prints correctly, escapes intact | M3b list is stale |
| **`?`** | **refused**, `not_implemented`, `src/js/Lower.zig:1440` | "I cannot compile `?` to JavaScript yet." Two `check/good` fixtures (`QuestionShapes.beni`, `QuestionWithConstraints.beni`) check clean and cannot build | **the one real codegen gap**; needs §7's tail-position statement form, so it follows slice 6 |
| `foreign` import from the sibling | works | every build | — |
| method call → direct call, primitive operator, return-type dispatch, evidence params, derived `eq`/`compare` | works | `emit/Derived*.js`, `run/Dictionaries.beni` | — |
| **tail-call loops (§8)** | **landed** `bbfc869` | `List.foldl` over `List.range 1 1000000` prints `500000500000`; `foldl`/`foldr` left `foreign` | done |
| `<-` bind | works | `Result.andThen` chain prints `3` | — |
| `_` placeholder, `\|>`, `<\|` | works | `Basics.add 10 _`, three-stage pipeline | — |
| operators as functions `(+)`, `(::)` | works | `List.foldl xs 0 (+)` | — |
| `as`, record and nested patterns, literal patterns (`Int`/`String`/`Char`/`-1`) | works, but as a ternary or `if` chain | `word "b"` is a four-deep `===` ternary | slice 6 makes them a `switch` |
| unit `()` value and pattern, `\() -> …` | works | prints `1` | — |
| extensible record type `{ a \| name : String }` | works | `greet { name = "bo", age = 3 }` | — |
| multiline string `\\` | works | two lines out | — |
| opaque types, imports, aliases, diamonds, multi-module | works | 31 of 34 `check/good` units emit and load | — |
| `Dict`, `Set`, `Debug.todo` | works | sizes print; `todo` throws `Error: TODO: …` | — |
| **mutual recursion at depth** | overflows the stack | `isEven 100000` → `RangeError: Maximum call stack size exceeded` | **not a defect** — `backend.md` §8 and §14 question 5 state it as a limitation |
| **`lazy`** | not a keyword | `lazy page : String` parses as a second declaration and reports `shadowing` | M3d, correctly out of M3b |
| **`--release`** | refused, exit 0, one line on **stderr** | "not implemented until M3c" | M3c. Minor: `backend.md` §2 says a successful build prints nothing on either stream |
| **`--source-maps`** | **accepted silently, writes no `.map`** | `find out -name '*.map'` is 0, exit 0, no diagnostic | M5. Should refuse out loud like `--release` does, or §2's "on in dev" default should say M5 |
| **a sibling `.js` importing another FILE** | refused, `not_implemented`, `src/js/Emit.zig:296` | the copy is renamed to `.foreign.mjs`, so the specifier is stale | `backend.md` §2 assigns the specifier rewrite to M3b; nothing in `core/` or `platforms/` needs it today |
| **a constrained value in a derived-comparison `parts` position** | refused, `not_implemented`, `src/js/Lower.zig:3054` | "the `parts` tree has nowhere to put that evidence" | a static-dispatch table gap, not M3b's; it asks to be reported |
| ports, browser platform, `Intl`, chunking, daemon | absent by design | `backend.md` §14 | M3d / M4 / B3–B5 |

## The `check/good` sweep

All 54 `.beni` files under `tests/corpus/check/good/`, grouped into **34 fixture units** (20
single-file, 14 multi-module directories built with every sibling on the command line plus
`--root=.`; `core/` also with `--core`).

**As they stand, 0 of 34 build** — 33 report `missing_main` and one (`TwoModules`) `main_not_program`.
That is by design: a `check/` fixture has no entry point. Two harness traps worth recording, since
they invalidate a naive per-file sweep: building one module of a multi-module fixture alone yields
spurious `unknown_module`, and `beni build … .` on a directory fails `invalid_module_path` for
`./A.beni` while `beni check <dir>` accepts the directory.

Repeating the sweep with a trivial `Entry.beni` (`main : Program` / `Node.printLines [ "ok" ]`)
dropped beside each fixture isolates codegen from the entry point: **31 of 34 units then build and
emit JavaScript.** The three that do not:

| Unit | Code | Why |
|---|---|---|
| `QuestionShapes.beni` | `not_implemented` ×3 | `?` |
| `QuestionWithConstraints.beni` | `not_implemented` ×1 | `?` |
| `core/Foreign.beni` | `foreign_sibling_missing` | the directory holds `Foreign.beni` and `Foreign.iface` and no `Foreign.js`; `check` never needs one and `build` does, so this fixture is structurally unbuildable |

Warnings, which do not block: `ambiguous_method_receiver` on 4 units (5 instances) —
`InferredConstraint.beni` ×2, `SixtyFourConstraints.beni`, `TypeOwnerEdges`,
`WarningWithoutExplain.beni`. That is the warning `9074538` turned on by default, behaving as
specified.

**Running the 49 emitted fixture modules directly** (`await import('./out/X.mjs')`, which evaluates
their top-level bindings): 0 runtime failures.

---

## What M3b actually owes

The headline is that the M3b list in `backend.md` §1 is **stale in four of its seven items**:
interpolation, tuples and record update all work today, and tail-call loops landed in `bbfc869`.
What is left is decision trees, `?`, and `Int32` — and `Int32` is not a backend item at all.

### Proposed slice order

1. **Decision trees** (`backend.md` §7, queue slice 6). Spec landed with this audit. It is first
   because `?` needs the tail-position statement form it specifies, and because it is the only item
   here with a measured cost: 17 comparisons per loop iteration where 2 suffice.
2. **M1, the refutable parameter pattern.** A silent wrong answer outranks everything that only
   costs bytes. It is a front-end slice (grammar or checker), independent of 1, and could go first
   if a front-end agent is free while a backend agent works on 1. Spec amendment to `language.md`
   §3/§7 before code, per CLAUDE.md rule 1.
3. **`?`** (`Lower.zig:1440`). Mechanical once 1 has landed: `?` is already a `case` with an early
   return by BIR time (`language.md` §8), and the checker already settles the `Maybe`/`Result` shape
   (`checker.md` §6.5). Two `check/good` fixtures become `run/` fixtures on the same commit.
4. **`Int32`, or strike it.** It is a *language* gap: no type, no module, no paragraph in
   `language.md`. §4's row ("a number kept in range by its operations (§3.1)") is the whole design.
   This needs an owner decision — a `core/Int32.beni` with wrapping operations and a `language.md`
   paragraph, or removing the row from §4 and the word from §1. It does not block M3c.
5. **`--source-maps` honesty.** One line: refuse like `--release` does, or restate §2's default as
   M5. Ten minutes, and it stops a user believing they asked for something.
6. **The sibling-file import rewrite** (`Emit.zig:296`). §2 assigns it to M3b and nothing in the
   repository needs it, so it is last, and it is a legitimate candidate for deferral to whenever a
   platform wants a shared helper file.

Not in M3b and correctly refused today: `--release` (M3c), `lazy` and chunking (M3d),
mutual-recursion trampolining (§14 question 5), ports and the browser platform (B3–B5).
