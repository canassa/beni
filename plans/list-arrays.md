# One array-backed `List`: decisions, migration and slices

**Status:** plan, 2026-10-01. The contract it builds is normative and lives in the design documents;
this file is the order of work, what each step owes, and the decisions left to the owner.

| Contract | Where |
|---|---|
| representation (E1tp: E1t plus a claimable head), invariants, the runtime `core/List.js`, the reader protocol, identities, list syntax, `--release` | [`backend.md`](../docs/design/backend.md) §4, *Lists are arrays* |
| list patterns, re-consing a match | `backend.md` §7, *List patterns over arrays* |
| tail calls modulo cons onto an array; scalar views | `backend.md` §8, *Tail calls modulo cons, onto an array*, *Scalar views* |
| `For` and the other markup loops | `backend.md` §15.5, *`For` over arrays* |
| surface, `core/List` API and costs, callbacks | [`language.md`](../docs/design/language.md) §6.8; §11.9 and §11.12's amendments |
| siblings, ports, host arrays | [`boundary.md`](../docs/design/boundary.md) §4, *How a sibling sees a `List`* |
| decoders and encoders | [`schema.md`](../docs/design/schema.md) §6, *Lists are arrays* |
| suspending bodies | [`transparent-effects-proposal.md`](../docs/design/transparent-effects-proposal.md) §16.3, amendment of 2026-10-01 |
| signatures | [`checker.md`](../docs/design/checker.md) Appendix B, amendment of 2026-10-01 |

The evidence: research 38 §7, §9, §12, §15–§17; research 40; research 42 (not taken); research 46.
The prototype: `bench/arrays/ports/first-tail.js`, `bench/arrays/lists/first-core/List.{beni,js}`,
`bench/arrays/seq/e1t.js`, and the persistence sweep `bench/arrays/lists/claim-test.mjs`.
*Amended 2026-10-01 (E1tp):* the runtime's prototype is `bench/arrays/ports/first-tail-prepend.js`
(`bench/arrays/seq/e1tp.js`), and its sweep `bench/arrays/lists/claim-prepend-test.mjs`; research
46 §11 is the evidence for the head.

---

## 1. Decisions

### 1.1 Taken by the owner (2026-10-01, `browser-decisions.md` W35 amended)

One sequence type; `List` array-backed with E1t's representation; no `Array`, no cons list; `[a, b]`
literals and `x :: rest` patterns stay, the pattern an O(1) view; programs build at the end with
`push`; the compiler rule that turns an `x :: rest` walk into an index loop ships with it.

**Amended 2026-10-01, the owner's second amendment of W35: the list syntax.** `::` leaves the
language. Lists are written, built and matched with brackets and a `...` spread, as in JavaScript:
`[ x, ...rest ]`, `[ ...init, last ]` and `[ first, ...middle, last ]` as patterns, `[ 0, ...xs ]`,
`[ ...xs, 4 ]` and `[ ...a, ...b ]` as expressions, whatever the prepend benchmark finds. O1 and O2
are withdrawn; O3–O5 are taken as recommended (§1.3). Everywhere below, `x :: rest` is read as
`[ x, ...rest ]` and `f x :: go rest` as `[ f x, ...go rest ]`. **This change is slice 0, and it has
landed on today's cons cells** (§4): the contract is `language.md` §6.8 *The list syntax*,
`checker.md` §6.6's amendment of 2026-10-01, and `backend.md` §7 *List patterns with elements after
the spread* and §8 *A cons step in the bracket spelling*.

**Amended 2026-10-01, the owner's third amendment of W35: E1tp.** The array-backed `List` uses
E1tp (research 46 §11): E1t plus a claimable head, so `[ x, ...xs ]` is amortised O(1) like `push`,
access and updates unchanged, +429 bytes brotli on the whole surface (3 468 → 3 897). The contract
is `backend.md` §4, *The claimable head: E1tp*, and the amendments marked *E1tp* through `backend.md`
§4, §7, §8 and §15.5, `language.md` §0, §6.8 and §11.12, and `boundary.md` §4. The flip (slice 2)
ships it; nothing in slices 0 and 1 changes.

### 1.2 Made by this specification, with the reason

| Choice | Reason |
|---|---|
| **Tail calls modulo cons are kept, retargeted to a builder**, not removed | Without them `f x :: go rest` on an array is a copy per step *and* a frame per element: O(n²) and a stack overflow at 100 000 (research 38 §16, candidate B). A stack overflow breaks a guarantee, so the rewrite is still mandatory (`backend.md` §8). Research 46 §0.4 measured it at 1.4–2.4× the best on E1t. *Amended 2026-10-01 (E1tp):* the unrewritten step is now amortised O(1), not a copy, so the reason is the stack alone — a frame per element overflows at 100 000 whatever a prepend costs — and it is enough. The destination stays the builder: a plain array pushed in place reads at O(1) afterwards, where prepending would hand back a trie |
| **Re-consing a match is free** (research 38's R5) | It keeps Elm-shaped `pairwise` and `merge` linear, and it is a local, syntactic rule. *Amended 2026-10-01 (E1tp):* the runtime's `cons` re-conses too (onto a view whose backing array holds the head, and onto a trie whose head slot holds it), so linearity no longer depends on R5; it stays, in slice 3, for identity (`===` the list matched in every form) and to allocate nothing |
| **`List.append` pushes when it can** (2026-10-01, E1tp) | `[ ...xs, x ]` lowers to `List.append xs [ x ]`, not to `push`; if it stayed a concatenation, the spread at the end would be O(n) while the one at the front is O(1). So `core/List.js` exports `append`: `ys` pushed onto `xs` when `xs` is a trie or has 32+ elements while `ys` has fewer than 32, a fresh concatenation otherwise. A deviation from the prototype, whose `append` pushes onto a trie only; reversible |
| **A trie's tail is a trie for every `k`** (2026-10-01, E1tp) | The prototype's `$tl` is `k = 1`; `view(xs, k)` generalises it (whole leaves by the offset, the partial leaf's rest a reversed head of at most 31), so `[ a, b, ...rest ]` and `List.drop` keep a trie cheap to prepend onto instead of flattening it |
| **`$chunks()`, if adopted, returns ranges** (2026-10-01, E1tp) | A trie's elements start at radix `off` behind a reversed head and end in a tail this version owns a prefix of; `[a, from, to, …]` triples say that with one copy (the head) and give a view without a copy (`backend.md` §15.5) |
| **A tail is bound only where it is read** | Research 38 §17.2's hazard at its source: a view is an allocation |
| **`e :: [ … ]` folds into one literal** | Free, and same evaluation order. *2026-10-01:* moot — `[ e, … ]` is written as the literal it is |
| **Tail calls modulo cons retarget to `[ h, ...self-call ]`** (2026-10-01) | Lowering writes that literal as `List.cons` calls, so it is the same cons step and needs nothing new (`backend.md` §8, *A cons step in the bracket spelling*); `[ ...go rest, x ]` is an append, not a step |
| **A suffix pattern is a length split** (2026-10-01) | `[ ...init, last ]` cannot be `[]`/`::` rows; the checker and the tree split a column by length as Rust's slice patterns do. On cons cells it walks (O(n)); after the flip it is a length test and indexed reads (`backend.md` §7) |
| **A reader protocol of three points** (`length`, `Array.isArray`, `$plain()`) instead of a shared helper | A sibling cannot import another file (`backend.md` §2), and the backend reads no types, so it cannot convert at a `foreign` call site |
| **`$plain` is a field holding a shared function**, not a prototype method | `Minify` declines a file with `class` or a top-level expression statement, and no core file may be declined |
| **`++` is O(n + m) always**, a fresh plain array unless one side is empty | `Basics.append` is a sibling and cannot reach `core/List.js`'s trie code. The cost is Elm's own `++` class; `acc ++ [ x ]` in a loop stays quadratic, as it is today on cons cells, and `push` is the way to grow. Research 46 counted `acc ++ [x]` linear under E1t only because its array-first programs wrote `push`. *Amended 2026-10-01 (E1tp):* still so for `++`; `[ ...acc, x ]` is now linear (the row on `List.append`), so the two spellings of one list differ in cost. The owner may prefer to close that — see §1.3, O6 |
| **The core-private primitives are non-`pub` `foreign`s the emitter imports by well-known symbol** | A `pub unsafeGet` would let a program read `undefined` as a value of any type |
| **Higher-order functions in beni, the sibling first-order**; `eq`/`compare` stay `foreign` with `sync` evidence | Research 38 §12.2's effects rule; the `sync` step already covers `where` evidence |
| **Decoders build fresh arrays; they adopt the input only when they created it and validation is the identity** | A host array may still be written by the host |
| **The trie's leaf walk in `For` is measured, not assumed** | `$plain()` is cached per header and measured at 13 µs per 10 000 against an 82 µs render (research 38 §15.9); the leaf walk needs a fourth protocol point |

### 1.3 Open, the owner's

*Decided 2026-10-01 (W35's second amendment):* **O1 and O2 are withdrawn** — with `::` gone there is
no `::` to warn about or to keep a rewrite for; the rewrite itself stays under its new spelling
(§1.2). **O3, O4 and O5 are taken as recommended**, reversibly. The table is kept as the record.

| | Question | Recommendation |
|---|---|---|
| **O1** | The warning `prepend_in_loop` (`language.md` §6.8): a `::`, or `acc ++ [ e ]`, whose result feeds a tail self-call's argument or is a fold lambda's result over its accumulator, and that no rewrite removes. On by default for the root package, off, or not at all? | **On, root package only**, as `ambiguous_method_receiver` and `unkeyed_for`. It is the one place the new representation turns a program Elm programmers write every day into an O(n²) one, silently; it guards no guarantee, so it is a warning (rule 7) |
| **O2** | Tail calls modulo cons kept (§1.2). The brief called them obsolete | Keep: see §1.2. Removing them breaks the no-runtime-exception guarantee for the most Elm-shaped code there is |
| **O3** | `language.md` §11.12 (W27) promised a list tail keeps its identity. A pattern's tail is now a view object per match; the amendment promises *"a view is the same value as another view of the same list at the same position"*, and the runtime compares with `same` on the miss path | Accept. The alternative, caching one view per array per offset, costs a `WeakMap` lookup per match on every walk the scalar-view rule does not cover |
| **O4** | `map` and `indexedMap` return their input when every result is `===` its element (research 38 §7, Immutable.js's rule): one comparison per element, the built array dropped | Accept: a `map` that touched nothing then wakes no hole |
| **O5** | `tail` and `drop` return views, O(1), which keep the whole backing array alive (as a substring can); the alternative is a copy, O(n), which frees it | Views: `drop` is O(n) in Elm too only because it walks; O(1) is the array's gift. A program that must free the prefix writes `slice` |

*Added 2026-10-01 with E1tp; open, the owner's.* Neither blocks slice 2: each recommendation is
what the contract now says, and each is reversible.

| | Question | Recommendation |
|---|---|---|
| **O6** | `xs ++ ys` stays O(n + m) while `[ ...xs, ...ys ]` pushes when it can (§1.2), because `++` is `Basics.append`, a sibling that cannot reach the trie. Close the gap, by a fourth protocol point (`xs.$append(ys)`, which `Basics.append` calls on a non-string) or by having the checker lower a `List` `++` to `List.append`? | **Leave it**, documented (`language.md` §6.8). `++` is Elm's O(n + m) and never promised more; a protocol point costs every sibling nothing but widens the surface rule 6 guards, and the checker route adds type-directed lowering the backend has avoided. Revisit if the corpus or a port shows `acc ++ [ x ]` in a loop |
| **O7** | Under E1t two `rest`s of one unchanged pushed trie were `same` (views over one cached copy). Under E1tp the first tail of a trie with an empty head — every trie `push` made — copies a fresh head at each match, so two such tails are equal and not `same` (`backend.md` §4, *Identity*): a `For` over it reconciles rows it used to skip. Memoise `view(xs, k)` for `k > hc` on the header (one field, written once like `p`)? | **Not yet.** The shape is rare (a `For` over the `rest` of a pushed list), slice 3's scalar views and re-consing remove most tails before they are made, and the memo costs a field on every header. Slice 4's `ForViewIdentity` measures it; add the memo if it shows |

---

## 2. What changes, file by file

| Area | Files | Change |
|---|---|---|
| runtime | `core/List.js` | rewritten: E1t (`first-tail.js`), the exports of `backend.md` §4's table, research 40 §8's writing rules, readers never naming write code, hoistable. *Amended 2026-10-01:* **E1tp**, a port of `bench/arrays/ports/first-tail-prepend.js` — the head claim, the radix offset, left growth, the trie tail — plus the contract's two generalisations (`view(xs, k)` for every `k`, `append`'s push rule) and `same`'s trie case. The port is rewritten, not copied: research 40 §8's rules (one walk written once, parameters named by role, capitalised top-level names, every speed-motivated line commented, the 2³² radix bound stated), no `class` (the prototype's view `class V` becomes a header literal with `$plain`), no top-level expression statement, the `ADA_T`/`PUSH_T` probes gone, every export `export const f = (…) =>`, and `cons` and `append` counted as writers for the read/write split |
| core | `core/List.beni` | rewritten over `unsafeGet` and the builder, as `bench/arrays/lists/first-core/List.beni`, with the API of slice 1 and the identities of `backend.md` §4 written into each doc comment; `foldr` backwards; `length` O(1). *E1tp:* `append` becomes `foreign`; `tail` and `drop` doc comments say what a trie's tail is |
| core | `core/Dict.beni`, `core/Set.beni` | `keys`, `values`, `toList` (and `Set.toList`) built with `foldl` and `List.push` instead of `foldr … ::` (which would copy per element); `merge`'s walk unchanged. *E1tp:* `foldr` with a prepend would be linear too; `push` is kept because it is faster and its result reads with no header below 32 |
| core | `core/Basics.js` | `append`'s list half on the protocol; the representation comment |
| core | `core/String.js`, `core/String.beni` | the `fromArray`/`toArray` helpers gone: results are the arrays made, arguments read by the idiom |
| core | `core/Debug.js` | `toString` recognises a list by the protocol |
| compiler | `src/js/Lower.zig` | literals as array literals (and `e :: [ … ]` folding); `nilNode`, `consNode`, `flatList`, `max_cons_elements` gone; list tests, bindings and lazy tails (§7); tail calls modulo cons onto `$root` (§8); the markup entries list as an array literal; the core-private imports and their `Reach` edges |
| compiler | `src/js/Decision.zig` | unchanged (the matrix is representation-free) |
| compiler | `src/js/derived_runtime.mjs` (+ `.min.mjs`) | `listEq`, `listCompare`, `listSteps` over plain arrays |
| compiler | `src/js/Suspend.zig` | the building loop's continuation (§8, transparent-effects §16.3) |
| compiler | `src/js/Print.zig` | the `consNode` comment; nothing else expected |
| platforms | `platforms/browser/runtime.js`, `platforms/node/markup.js`, `platforms/node/Node.js`, `platforms/browser/Browser.js`, `tests/platforms/page/Page.js` | walks by the idiom; `same` for views (slice 4) |
| benches | `bench/arrays/` | a `beni` candidate (the real compiler, no list-syntax rewrite); the rewritten programs pinned to a pre-flip compiler (`BENI_BEFORE`) so research 46 reproduces. *E1tp:* `lists/claim-prepend-test.mjs` run against the shipped `core/List.js` as well as the prototype |

The checker, BIR, the parser and the formatter do not change, except the warning of O1 (BIR
diagnostics, slice 3) if the owner takes it. *2026-10-01:* O1 is withdrawn, and the list syntax
changed all four in slice 0, before the flip.

---

## 3. What the corpus sees

**Every `run/` and `browser/` output stays byte for byte**, with one exception below: the run corpus
is the differential test of the flip, as `bench/arrays`' 218 and 298 checks were for the prototype.
Their **run hashes all change** (the emitted JavaScript and `core/` change), so the flip commits the
output of `zig build test-run-hashes`.

| Fixture | Changes | Why |
|---|---|---|
| `run/ListIdentity/` | three lines, `xs ++ ys tail same`, `concat last same` and `concatMap last same`, become `copied` | an array cannot share a tail (`backend.md` §4, *Identity*); the other ten lines hold |
| `emit/TailModConsLoop`, `emit/release/TailModConsLoop` | re-recorded | `$root` is an array, `$last` gone (§8) |
| `emit/SuspendShapes` (+ `emit/release/`) | re-recorded | the building loop's continuation (§8) |
| `emit/MatchNested`, `emit/MatchSwitch`, `emit/MatchSharedLeaf`, `emit/NestingShapes` | re-recorded | length tests and index reads (§7); a long literal is one array literal (§4) |
| `emit/DerivedEqList`, `emit/DerivedCompare*`, `emit/DerivedEq*`, `emit/ComparisonOperators`, `emit/EqAgainstConstructor`, `emit/EvidenceParameters`, `emit/EvidenceValue`, `emit/LetEvidenceParameter`, `emit/PrimitiveEvidence`, `emit/QuestionShape`, `emit/RecordFieldOrder`, `emit/TypeDispatch`, `emit/MethodTargets`, `emit/ConstantMethodCall`, `emit/NullaryConstant`, `emit/TailCallLoop`, `emit/DerivedEmissionOrder` | re-recorded | each writes a list literal (usually `[]` for `printLines`) or a list test; no other line may move |
| `emit/app/Dce*` | re-recorded | the same, and which `List` exports a program imports |
| `emit/release/app/HoistOrder`, `emit/release/ReleaseCompact`, `emit/release/ReleaseInline`, `emit/release/ReleaseNames` | re-recorded | the same in the one file, and `core/List.js` hoisted |
| `run/NestingFlatList` | output unchanged; its intent comment's claim about cell shapes withdrawn | `backend.md` §4's nesting table |
| `tests/blackbox/build_test.zig` pinned bytes | re-pinned where a pinned program uses a list | |

A reviewer checks every re-recorded golden against the shapes the contract gives; a golden line that
moves for any other reason is a finding (CLAUDE.md, *Development output did not move by one byte*).

---

## 4. The slices

Each slice passes `zig build gates` on its own; the flip is one slice because a representation
cannot change in half the files. `-Dllvm` gates on slices 2 and 3 (layouts, recursion depth).

### Slice 0 — the list syntax, on today's cons cells (2026-10-01, landed)

**Scope.** The owner's second amendment of W35: `[ x, ...rest ]`, `[ ...init, last ]` and the rest of
`language.md` §6.8's syntax through the lexer (`...` in every mode), parser, formatter, BIR (the
`pat_spread` instruction; a spread expression lowers to `List.cons`/`List.append` calls), checker
(the spread's type; the length split for exhaustiveness) and backend (a column with elements after
a spread split by length down the cons spine, `List.length`/`drop`/`take` for its end). Then every
`::` in `core/`, `platforms/`, `tests/corpus/`, `bench/` and the skills migrated to the bracket
spelling by a one-off formatter mode, and `::` made the parse error `cons_removed`, whose message
is the bracket form of what was written.

**What it leaves the flip.** The desugaring of spreads stays, so slice 2's `List.cons` and
`List.append` are what `[ x, ...xs ]` and `[ ...xs, x ]` cost. The length split's emission (§7 of
`backend.md`, *List patterns with elements after the spread*) moves from a walk to a length test and
indexed reads, and the spread in the middle of a pattern needs a view with an end, or `slice`: slice
2 decides which and adds it to `backend.md` §4's protocol if it is a view.

### Slice 1 — the API, on today's cons cells (2026-10-01, landed)

**Scope.** `core/List.beni` gains `initialize`, `get`, `last`, `set`, `update`, `push`, `pop`,
`slice`, `insertAt`, `removeAt` and `swap`, written in beni over cons cells with the meanings and
identities of `language.md` §6.8 and `backend.md` §4 — O(n) for now, each doc comment saying so
until slice 2. Nothing else moves. This makes the API's *meaning* testable before its
representation changes, so slice 2's run corpus is a differential test of it too.

**Tests owed.** `run/ListIndexed` (every new function at its edges: empty, index 0, the last index,
−1, `length`, past it; `slice` with negative and clamped bounds and `from ≥ to`; `insertAt` at
`length`); `run/ListIndexedIdentity/` through the test platform's `refEq` (set of the same value,
`swap xs i i`, every out-of-range write, a full `slice` and `take`, `drop 0`, `pop []`, `filter`
keeping all — and `map` of the identity if O4 is taken); `run/ListIndexedDeep` (each new function
once on 100 000 elements, and `initialize` building 100 000: stack safety); the doc examples, which
`docs_test.zig` runs. Green on cons cells by construction; they are the oracle for slice 2.

**Measurements owed.** `bench/size.mjs` (dev and release totals unmoved except the new fixtures:
elimination drops what nothing calls).

### Slice 2 — the flip

**Scope.** Every row of §2 except the markup identity (`same`), the scalar views, re-consing and the
warning: `core/List.js` (E1t, research 40's rules), `core/List.beni` (loops over `unsafeGet` and the
builder), `Dict`/`Set` conversions, every sibling and runtime on the protocol, the emitter's
literals, `::`, patterns with lazy tails, tail calls modulo cons onto `$root`, the markup entries
list, `derived_runtime`, `Suspend.zig`'s continuation, and §3's goldens and hashes.

*Amended 2026-10-01 (E1tp):* **the flip ships E1tp, not E1t.** `core/List.js` is the port of
`bench/arrays/ports/first-tail-prepend.js` that §2's runtime row describes, `List.append` becomes
its `foreign`, and the runtime's re-cons comes with it; R5, the compiler's re-consing rule, stays in
slice 3. There is no E1t step in between: nothing in the repository ever ran E1t outside
`bench/arrays`, so the prototype's differential and persistence tests are the only record of it and
stay where they are.

**Tests owed.**
- **The differential**: every `run/` and `browser/` output unchanged but `ListIdentity`'s three lines
  (§3) — the slice-1 fixtures included.
- **Red-first where behaviour changes**: `ListIdentity`'s three lines are recorded failing against
  the new core before they are re-recorded, with the reason in the fixture's intent comment.
- `run/ListPersistence` — the claimable tail, in beni: a seeded generator applies a few thousand
  `push`, `pop`, `set` and `++` to randomly chosen *old* versions (tries two levels deep, over 1 056
  elements), and checks every live version element by element against a `Dict Int` model. Proved
  by breaking the claim condition (`t.length === c` dropped) in a scratch build: it must fail.
  *E1tp:* the generator also prepends, re-conses what it took the tail of, and takes tails
  (`[ x, ...rest ]` and `List.drop k` for `k` below, at and past the head count) on old versions,
  with the root grown left both ways it can be: 33 prepends onto a trie `push` made (its tree
  starts at offset 0, so the first full head grows the root), and some 600 prepends onto a short
  list (its tree starts mid-root, at 512) — `claim-prepend-test.mjs`'s sweep in beni, as small as
  the budget needs. Proved
  twice: with the head claim's condition (`h.length === hc`) dropped, and with the
  already-there test (`h[hc] === x`) replaced by an unconditional share, each in a scratch build.
- `run/ListForms` — one list as plain, as a view and as a trie: `==` and `compare` across forms,
  `Debug.toString` of each, `++` in every pairing, `String.join` and `String.fromList` of a trie
  and of a view, `Dict.fromList` of a trie. *E1tp:* the trie twice, once built by `push` (an empty
  head) and once by prepending (a head, an offset left of 0), and the tail of each.
- `run/ListConsCopies` — `x :: xs` leaves `xs` unchanged, onto each form; `e :: [ … ]` folding
  keeps `Debug.log` order. *Amended 2026-10-01 (E1tp):* renamed `run/ListPrepend` — `[ x, ...xs ]`
  leaves `xs` unchanged onto a plain list below and at 32, a view below and at 32, the newest
  version of a trie, an older version (two prepends of different values onto one list, both kept),
  a full head (32 prepends), and a runtime re-cons onto a view; `[ ...xs, x ]` and
  `[ ...xs, ...ys ]` on the same forms, below and at `append`'s thresholds.
- `run/ListPrependDeep` (*added 2026-10-01, E1tp*): at 100 000 elements, `x :: acc` then
  `List.reverse`, `List.foldr` building a list, a persistent stack pushed and popped at its front
  with old versions kept, `[ ...acc, x ]` in a loop, and `run/ListRecons` (moved here from slice 3,
  §7 of `backend.md`). Linear under E1tp, so green; each is a guard, proved by a scratch core whose
  `cons` always copies and whose `append` never pushes: it must exceed the 4 300-million-instruction
  budget.
- `emit/ListPatterns` (`backend.md` §7's fixture list).
- **Stack safety**: `ListDirectDeep`, `ListMapNDeep`, `ListFoldDeep`, `ListMapFilterDeep`, the
  `TailModCons*` fixtures and `SuspendListBuildDeep` at their current sizes; add a 100 000-element
  `x :: rest` walk that is not a tail call of its own list (`run/ListWalkDeep`).
- **Order**: `run/CallbackOrderList`, `run/ListDirectEdges`, `run/TailModConsOrder` unchanged.
- Determinism: the `--jobs` test covers it with nothing new.

**Measurements owed.**
- `bench/list/run.mjs --before-rev=<parent>` for every `core/List` function at 1 000, 10 000 and
  100 000; no function slower than the cons core by more than 1.5× at any size without a line of
  explanation in the commit.
- `bench/arrays`, **default run, ≤ 5 minutes**, with the new `beni` candidate beside `E1t` and
  `cons` (the latter on the pinned pre-flip compiler): the list, single-operation and array tables;
  `beni` within 1.5× of research 46's E1t prototype on its rows, except the bare `x :: rest` walk
  (slice 3's). *Amended 2026-10-01 (E1tp):* beside `E1tp` as well, and within 1.5× of research
  46 §11's **E1tp** prototype — the one it ports — on its rows, the Elm-style table A included:
  every row research 46 §11.5 found linear stays linear, `x :: acc` then `reverse` at 10 000 in
  the same order of magnitude as §11.4's 547 µs.
- `bench/size.mjs`: dev and release totals, the floor, the empty page; the whole-surface figure
  against research 46's 3 468 bytes brotli for E1t (and 3 189 for today's two types).
  *Amended 2026-10-01 (E1tp):* against research 46 §11.6's **3 897** for E1tp; and the release
  cost of a program that only prepends, which now ships the trie's write half (`backend.md` §4,
  *`--release`*).
- `bench/ui` (research 29's harness, headless Chrome) on the table app against Solid 1 and Solid 2:
  per-operation medians, no operation slower than before the flip beyond noise; the release bundle's
  growth reported against the sibling's measured cost (research 40 §5: ~450 bytes read-only, ~900
  written).

### Slice 3 — the compiler rules

**Scope.** Scalar views (`backend.md` §8), re-consing a match (§7), the literal folding if not
already in slice 2, and the warning `prepend_in_loop` if O1 is taken (BIR diagnostics; the code
appended to `language.md` §10 on its own line, root package only).

**Tests owed.**
- **Red-first**: `run/ListRecons` — `pairwise` written `(a, b) :: pairwise (b :: rest)` and a `merge`
  re-consing its heads, at 100 000 elements. After slice 2 each is O(n²) copies and exceeds the
  4 300-million-instruction budget; after this slice it passes. *Amended 2026-10-01 (E1tp):* no
  longer true — the runtime re-conses and prepends cheaply, so `run/ListRecons` is green after
  slice 2 and moved there. This slice's red-first fixture is `run/ListReconsIdentity`
  (`backend.md` §7): `[ h, ...t ]` after matching `[ h, ...t ]` against a view and a trie is
  `copied` through `refEq` before R5 and `same` after; against a plain list, `same` throughout.
- `run/ListScalarView` and `emit/ListScalarView` (+ `emit/release/`), `backend.md` §8's list:
  every materialisation point, entry-value identity through `refEq`, two list slots, a trie and a
  view as input, `Debug.log` order.
- The warning: `check/` fixtures for each of its two shapes, and near misses that must stay silent
  (a TEA `update` that prepends once, a cons step, a re-cons, `e :: [ … ]`).

**Measurements owed.** `bench/arrays` default run: the bare `sum` walk (research 46: ≈ 10× the best
on E1t) expected at or below the cons list; `pairwise` and merge sort; `bench/size.mjs`. *E1tp:*
the merge sort of sorted input first of all, which research 46 §11.5 item 3 found at about 2× E1t
for a header per tail of a trie; scalar views are expected to remove that.

### Slice 4 — markup

**Scope.** `backend.md` §15.5 *`For` over arrays*: `same` for views on every identity check of
`platforms/browser/runtime.js` that can see a list; the leaf walk measured against `$plain()` and
adopted only if it wins (then `$chunks()` joins the protocol); `platforms/node/markup.js` likewise;
`language.md` §11.9's `each`. The benchmark app's `update` may use `List.swap`, `List.set` and
`List.removeAt` where it now rebuilds with `indexedMap` and `filter` — measured both ways.
*Amended 2026-10-01 (E1tp):* `same` has a trie case (`backend.md` §4, *Identity*); `$chunks()`, if
the leaf walk wins, returns `[a, from, to, …]` ranges from the head, the leaves from radix `off`
and the cut tail (`backend.md` §15.5), and the measurement is of that shape, on a trie built by
`push` and on one built by prepending; O7's memo is decided by `ForViewIdentity`'s trie case.

**Tests owed.** `browser/dom/ForForms`, `browser/dom/ForViewIdentity` (red without `same`),
`browser/dom/ClassListForms`; an `ssr` `run/` fixture over the three forms; every `browser/` golden
unchanged, in happy-dom and (`zig build test-browser`) Chrome. *E1tp:* `ForForms` and
`ForViewIdentity` gain the trie-with-a-head cases of `backend.md` §15.5's fixture list.

**Measurements owed.** `bench/ui` against Solid 1 and Solid 2, every operation's median at 1 000 and
10 000 rows (create, replace, update every 10th, select, swap, remove, append, clear), quoted as
orderings, never as a geometric mean (CLAUDE.md rule 8); `bench/size.mjs`'s `page` lines.

### Slice 5 — cleanup and bytes

**Scope.** `core/List.js` reordered by research 40 §4.3's search and its order committed; whether
the trie's read half can drop out of a read-only program (`backend.md` §4, *`--release`*),
measured; the withdrawn text of `backend.md` §4 (the cons rows, `max_cons_elements`, the
corrections' empty-list paragraph) marked superseded where it still reads as current;
`bench/arrays` README for the `beni` candidate; `fast-compiler.md` §9.4's list bullet pointed at the
decision; `CLAUDE.md`'s lines (§5 below). *E1tp:* the E1t text of `backend.md` §4 that the *E1tp*
amendments override — the prepend-is-a-copy rows, invariant 3's view over a trie's copy, *What is
not done*'s front buffer — folded into the amended text once it is built, so the subsection reads
as one representation.

**Tests owed.** `Minify`'s unit test that no core file is declined (existing) covering the new
`List.js`; the fuzz sweep unchanged.

**Measurements owed.** `bench/size.mjs` (`release_gross`, the floor, the page); the read-only and
the writing program's `List.js` cut, against research 40's 452 and 901 bytes; a Chrome pass of
`bench/arrays` (`FULL=1 node all.mjs chrome`), which research 46 did not make. *E1tp:* a third
cut, the program that prepends and never pushes or sets; and the Chrome pass includes E1tp, which
research 46 §11 measured on Node only.

---

## 5. `CLAUDE.md` lines to update when the flip lands

Not edited by this specification. For whoever lands slice 2:

- **M3's paragraphs**: one new paragraph — *`List` is array-backed* (the owner's decision of
  2026-10-01), with its date, the representation in a sentence, the pointer to `backend.md` §4
  *Lists are arrays*, `language.md` §6.8 and this plan, and the headline measurement. *E1tp:* the
  sentence names both claimable ends — `[ x, ...xs ]` and `List.push` amortised O(1).
- **Effects, and what blocked them**: *"One hazard survives in a new place: `List.eq`/`List.compare`
  are `foreign` with a `where` clause, so their siblings are JavaScript loops calling beni evidence
  — the shape `foldl` was."* The hazard is unchanged by the flip, but since the `sync` step their
  evidence is `sync` (`boundary.md` §4), so the sentence can say it is covered.
- **Rule 8** mentions field identity as load-bearing: a pointer to `language.md` §11.12's view
  amendment once O3 is decided.
