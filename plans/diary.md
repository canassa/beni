# Captain's log

Append-only. Newest entries at the bottom. Never edit or delete a prior entry —
correct a past statement in a new one.

## 2026-09-16 00:05 CEST — the no-currying spec pass, and the first slice of it

**What I did**

- Read `transparent-effects-proposal.md` (P2) end to end and assessed what it
  would take to start implementing. The answer was that nothing in it can start:
  the 2026-09-14 no-currying decision had never been written into the spec, and
  `language.md` still carried it as a "pending spec change" note. Two independent
  reasons it gates P2 — effect flags have nowhere to live on a curried
  `{param, result}` chain, and statically choosing the direct or suspendable body
  at a call site needs known arity, which currying denies.
- Wrote the spec pass. `language.md` gained n-ary function types `Int, Int -> Int`,
  a new §6.7 for saturated calls, `_`, pipe-first `|>` and the `<-` bind, plus
  token, grammar, operator-table, lowering, formatter and diagnostic updates.
  `checker.md` §6.1/§6.2 now describe a function type that unifies only at equal
  arity, and §8.3 was re-cut from the missing-argument suite into an arity suite.
  `backend.md` §6 lost the calling convention entirely — no adapter, no arity tag,
  no curry wrapper, no direct-call share to measure. Commit `92ee10b`.
- Commissioned and landed `research/17-platform-primitives.md`, which discharges
  P2 §10 item 0 — the enumeration P2 says twice must exist before any surface
  decision is frozen. Commit `20823e8`.
- Shipped the first implementation slice: `>>` and `<<` removed, the `_`
  placeholder, the `let x <- e` rest-of-block bind, and the formatter's
  trailing-`<|` lambda rule. 23 new corpus fixtures, 3 new diagnostic codes,
  ~820 lines of compiler change. Commit `5cf3ec6`.
- Corrected the README, which claimed beni "keeps Elm's semantics" (false since
  currying was dropped) and described the daemon in the present tense (unwritten).
  Commit `1241bea`.
- Ran three read-only reviews: one over the spec pass, one over the slice-A
  implementation, one over `language.md`'s structure.
- Restructured `language.md`: §3's 18-item flat notes dump became three grouped
  sets, four rules moved to the sections that own them (which killed the §3/§6
  duplication), and §6.7 now names its four parts instead of stapling them
  together. 962 → 958 lines with the §10 catalogue, the grammar block and the
  heading list all verified byte-identical. Fixed four defects it found and left
  alone: two diagnostic codes jammed into one span in §7, `nesting_too_deep`
  missing from the §10 catalogue, a reference to a `tests/corpus/bad/` directory
  that does not exist, and implementation status leaking into a normative rule.
- Started this log, and wrote the repo's first `CLAUDE.md`, both modelled on the
  Betrayal at Krondor repo's conventions.

**What I learned**

- **A green test suite proved almost nothing here.** Each of the three reviews
  found real defects while `zig build test`, `test-blackbox` and `fmt-check` were
  all passing. The spec review found a grammar rule that could not parse a record
  type with two fields; the code review found a formatter that lied to itself
  about `if`/`let`/`case` nested in a bind value, and a `?` that escaped the
  placeholder lambda when the call was reached through a pipe. The corpus is the
  asset, not the unit tests.
- **The proposal's own headline example miscompiles against the repo as it
  stands.** `List.map` is `foldr`, `foldr` is a `foreign` whose JavaScript does
  `f(at.a)(out)`, and under P2's CPS lowering a suspending callback returns a
  suspension object — so the loop would cons scheduler objects into the output
  list. Well-typed, no diagnostic, garbage out. This reorders the plan: the
  tail-call loop must land before effects, not after, because it is what lets
  `foldl`/`foldr` leave `foreign` at all.
- **P2 §10 item 0's conditional splits rather than resolving.** Of 68 foreign
  values, 66 are first-order and only `foldl`/`foldr` are not. So the `foreign`
  keyword survives and nothing needs `suspends` inside a signature. But six
  primitives and seven imposed signatures are functions the *host* calls back
  into synchronously, which `boundary.md` §5.4 already promises in writing to
  check — so `sync` cannot stay a declaration modifier and `sync_boundary` is not
  droppable. The price is small: one bool on `Structure.Func`, one spare
  `Term.Tag`, one obligation kind.
- **A reviewer's proposed fix can be confidently wrong.** For the trailing-lambda
  indentation the reviewer said to pass `indent` instead of `lineIndent()`. That
  changes nothing for a list element, because `collection` passes the bracket's
  own column as the element's indent, so the two are already equal. The quantity
  actually wanted is where the chain starts. Verified by reverting and diffing the
  golden.
- **`sync` will need a witness in the interface, and P2 does not say so.** Its §8
  chain diagnostic names call sites in other modules with source positions. An
  interface carries types, not a call graph with spans. Either the interface gains
  a witness or the checker reaches into another module's body — which is exactly
  what the JS backend already does for arity, with a comment saying M4's cache
  cannot.
- Removing `>>` and `<<` had a lexical side effect nobody would predict: `--` no
  longer always begins a comment, because `x <-- c` now lexes as `<-`, `-`, `c`.
- **"Make it shorter" and "make it organised" pull against each other, and the
  first pass will silently pick organised.** Restructuring `language.md` grew it
  from 962 to 996 lines, because relocations and group lead-ins cost lines. A
  second pass with structure frozen and words as the only target got it to 956,
  and stopped there with an argument rather than a number: 412 of those lines are
  structural floor (blanks, headings, fences, frozen grammar and catalogue
  blocks, tables) and the remaining 544 carry roughly 250 rules. A mechanical
  reflow to the 100-column guide, deleting nothing, recovered one line — proof
  the prose was already packed and the length is content. Ask for a target, but
  accept arithmetic over obedience.

## 2026-09-16 01:50 CEST — n-ary function types, end to end

### What I did

Landed the largest slice of the no-currying change: **function types are n-ary**.
A function type carries a parameter range plus a result, two of them unify only
at equal arity, and every call is saturated. Argument order and `|>` were
deliberately left alone — they flip together in the next slice, and keeping them
out is what made this one atomic.

- **`TypeStore.Structure.Func`** is `{ params: Range, result: Var }`.
  `arrowCount` became `paramCount`: one lookup, not a walk down a chain, because
  `a, b -> c -> d` takes **two** arguments and counting three there is exactly the
  conflation currying forced.
- **Grammar.** `Type := TypeParams '->' Type | TypeApp`,
  `TypeParams := TypeApp (',' TypeApp)*`. One routine collects the
  comma-separated items and the next token decides: `->` makes them a parameter
  list, `)` a tuple at two or more and a grouping at one. New code
  `arrow_in_tuple_element` for a tuple element with a bare `->`, whose message
  carries `((Int, Int) -> Int, String)` verbatim.
- **AST/BIR** `type_fn` carries a params range plus a result.
- **Checker.** `Constrain.funcChain` became `func` — one n-ary node, no chain.
  `Solve.unifyFlat` compares `params.len` as part of the head. `Solve.call` is
  now one comparison rather than a peeling loop. `Interface.Term.func` gained an
  `extra` range. `Render` prints `A, B -> C` with §8.2's parenthesisation.
- **Backend.** Deleted `curried`, `curriedLambda`, `Arity`, `declArity`,
  `arrowCount`, `externalArity`, `local_arity` and `calleeIdent`. Every call is
  `l.call(callee, args)`. The only wrapper left is `ctorLambda`, and only because
  a constructor is an object literal with no binding to name.
- **core, the Node platform, 373 corpus files and `bench/`** rewritten; `check/args`
  re-cut around §8.3's six shapes; `ComposeMissingArg` deleted with `>>`/`<<`.

### What I learned

- **A nullary constructor PATTERN reaches the solver as a call of ZERO
  arguments.** The peeling loop absorbed that silently (`arrows == given == 0`
  fell through); a rule phrased as "is the callee a function?" reports
  `not_a_function` on every `True ->` in core. The fix is a `given == 0` guard
  that unifies the result with the callee, but the lesson is that replacing a
  loop with a predicate changes what the degenerate case means.
- **`suspect_lambda` became unreachable, and that is the change working.** It
  existed to say "the mismatch you are reading is really the lambda two arguments
  back". With arity in the type, unification fails AT the lambda, so the suspicion
  and the report are the same site and the hint can never fire. Deleted.
- **Removing currying makes the applicative idiom inexpressible.** `Valid Ctor |>
  andMap a |> andMap b` needs a curried constructor; an n-ary one cannot be fed
  one argument at a time. `bench/corpus/FormValidation.beni` now spells the
  currying out as nested lambdas. That is a real cost of the decision, and it is
  worth writing down before someone rediscovers it in application code.
- **A benchmark corpus documented as "must be valid" was 224 diagnostics from
  valid on `master`** — `Json.Decode` does not exist and `Dict.empty`/
  `Set.fromList` have wanted an explicit comparator for some time. I measured the
  baseline in a detached worktree rather than assuming, got back to exactly 224,
  and left the pre-existing 224 alone. Without the baseline I would have spent an
  hour "fixing" errors I did not cause.
- **`AnnotationWidthBand` is measured in bytes, so changing the SPELLING of a
  type breaks it silently.** `->` (4 chars with spaces) became `,` (2), every
  band shifted by two, and the 101-column case quietly fitted. A fixture whose
  name asserts a width has to have the width recomputed, not re-blessed.
- The record-type comma rule is one token of lookahead and no backtracking, and
  applying it everywhere rather than only inside a record body is safe for the
  same reason it works at all: a `:` can never follow a type item.
- **One code cannot carry two readings.** A comma list with no `->` is a tuple
  element with a stray arrow inside parentheses, and an ordinary missing `->`
  outside them. Reporting `arrow_in_tuple_element` for both made `x : Int, String`
  explain a tuple the author never wrote. The parser now asks whether the
  innermost open bracket is a `(` and picks the message from that.


## 2026-09-16 02:27 CEST — five review defects in the n-ary function types change

**What I did**

Fixed the five defects a read-only review found in the uncommitted n-ary
function types change, each with a corpus fixture proved to fail before the fix
by stashing it.

- **A tuple of function types was silently misparsed.** `parseTypeAtom`'s `(`
  branch called `finishType`, whose result is a whole `Type`, so the result
  re-entered `parseTypeItems` and ate the next top-level comma:
  `( Int -> Int, Bool -> Bool )` parsed as `Int -> ((Int, Bool) -> Bool)` with no
  diagnostic. `finishType` now takes a `ResultMode`; inside parentheses the
  result is `.single` — an arrow chain whose links are single `TypeApp`s, never a
  comma list — and a comma after it is `arrow_in_tuple_element`. Fixture
  `parse/bad/ArrowInTupleElementAllFunctions`. The existing
  `ArrowInTupleElement`'s span moved from the closing `)` to the comma, which is
  what its own message ("and then found a comma after it") points at.
- **The nesting guard no longer charged for a parenthesised type.**
  `parseTypeItems → parseTypeApp → parseTypeAtom → parseTypeItems` is a cycle
  with no `enter()` in it, so 30 000 nested `(` in a type were accepted in
  silence where 4096 used to report. `enter()`/`leave()` at the head of the `(`
  branch. Fixture pair `check/depth/TypeParens{Ok,Deep}` and its entry in
  `generate.sh`: measured 4095 clean, 4096 reports, the same boundary as the
  expression case.
- **`Render` printed a tuple element that re-read as a different type.** The
  `.tuple` arm wrote elements at `.top`, so `( (Int -> Int), Int )` printed as
  `( Int -> Int, Int )` — which the parser reads as a 2-ary function. `.arg`
  parenthesises exactly the function-typed elements. Fixture
  `check/bad/TupleElementOfFunctionType`.
- **The `given == 0` shortcut in `Solve.call` ran before the callee was
  inspected**, so a constructor of arity ≥ 1 written bare in a pattern got a raw
  `type_mismatch` instead of §8.3's arity message. Now
  `given == 0 and st.paramCount(info.callee) == 0`. Fixture
  `check/args/ConstructorBareInPattern`.
- **`Lower.Input.birs` and `.provenance` were write-only** once `externalArity`
  went, and `birs`' doc comment told M4 that arity is not in the interface — which
  this change discharges. Both fields, their allocation loops in `js/Lower.zig`
  and `js/Emit.zig`, and the note are gone.

**What I learned**

- **`language.md` §3 settles `( Int -> Int, Bool -> Bool )` against the tuple
  reading, and the grammar alone does not.** `TypeAtom := '(' TypeApp (','
  TypeApp)+ ')'` makes a tuple's elements `TypeApp`s, which cannot contain an
  arrow, so the 2-tuple of functions is not derivable at all; but `'(' Type ')'`
  with `Type := TypeParams '->' Type` *is* derivable and is exactly what the
  parser was doing. What decides it is the Types table and the diagnostic's own
  text — "I read the `->` … and then found a comma after it" — so the answer is
  the diagnostic, not the tuple and not the nested function.
- The price is that `(a, b -> c, d -> e)`, legal by a literal reading of the
  grammar, is now `arrow_in_tuple_element` too. That is the right trade: nobody
  writes it, it is exactly as confusing as the shape the message is about, and
  `(a, b -> (c, d -> e))` says it. Outside parentheses the greedy reading stays,
  because there is no tuple to be confused with there.
- **A guard that is reached through one entry point is not reached at all once a
  refactor adds a second.** The depth charge lived in `parseType`; the new `(`
  branch called `parseTypeItems` directly and the cycle closed behind the guard's
  back. `check/depth`'s pairing — a fixture UNDER the limit that must pass and one
  OVER it that must report — is the only shape of test that sees this, because
  the failure mode is silence.
- `.l_brace` needs no `enter()`: every path into a record type body goes through
  `parseRecordTypeFields → parseType`, which charges. Said so in a comment, since
  the asymmetry with `.l_paren` otherwise looks like the same oversight.

## 2026-09-16 03:21 CEST — pipe-first `|>`, and the library flipped subject-first

**What I did**

- Made `|>` insert its operand at the **first** argument in `bir/Lower.zig`:
  `saturate`/`lowerApplication` grew a `Position`, and the operand is still
  lowered where it is written — only its slot in the argument list moves, by a
  one-word `std.mem.rotate` over the scratch slice. Instruction order therefore
  stays source order and nothing about determinism changes.
- Two diagnostics that §10 catalogued but nobody had implemented:
  `pipe_rhs_not_application` (the right operand of `|>` must be an `App`; a
  block, an operator chain or a `?` is not one) and `operator_not_a_function`
  (`(|>)` and `(<|)` have no parenthesised form). Both are parse-time.
- `<-` now accepts a pipe chain on its right-hand side, which §6.7 had marked
  as implementation lag. Lowering grew `bindSpine`, which walks parens and
  pipes to find the head application's callee and argument *nodes*, so the
  callback is appended to the rewritten call rather than to the pipe.
- Deleted `Basics.apL`, `apR`, `composeL` and `composeR`, and their `WellKnown`
  entries. The first two were the desugaring targets `|>`/`<|` no longer have;
  the last two were left 3-ary by the previous slice, which made them "apply
  two functions in sequence" rather than composition, and `fast-compiler.md`
  §9.3 already records point-free composition as the deliberate loss.
- Flipped every signature in `core/`, `core/Dict/`, `core/Set.beni` and
  `platforms/node/Node.beni` to subject-first / function-last, with the
  sibling JavaScript and every doc comment and example. Then the whole corpus:
  `tests/corpus/{run,check,parse,fmt,bir,regress}` and `bench/corpus`.

**What I learned**

- **`beni build` does not check unused core declarations.** A deliberately
  broken `List.sortBy` left the build green. `beni check --core --root=core
  core/*.beni core/Dict/*.beni` is the command that actually gates the library,
  and it is what every agent working on the flip was told to run. Worth
  knowing before trusting a green build about a change to `core/`.
- **The embedded core is a build artefact.** Editing `core/*.beni` changes
  nothing until `zig build` re-embeds it; only `--core-root` reads from disk.
  I lost fifteen minutes to a "type error" that was a stale binary.
- The corpus paid for itself twice over. The flip's real risk is a call whose
  arguments are the same type — `String.contains filter title` became
  `String.contains title filter` and nothing but a runtime fixture would ever
  have noticed. Every `run/` fixture that printed the same bytes after the flip
  is evidence its rewrite was right; the one that moved
  (`PlaceholderAndBind`) moved because the order rule it pins is what changed.
- **A fixture named after the missing argument goes stale when the order
  flips.** `too_few_args` always names the *trailing* parameter, so
  `DictInsertMissingDict` became `DictInsertMissingValue`,
  `StringJoinMissingList` became `StringJoinMissingSeparator`, and so on. The
  name was carrying a claim the body no longer made.
- Pre-existing and untouched: `zig build bench` does not compile
  (`bench/bench.zig` still passes `.birs` to `js.Lower.Input`, which dropped
  the field), and `bench/corpus/{NotesApp,JsonCodecs}.beni` import `Html` and
  `Json.*` modules that have never existed, so `README.md`'s claim that
  `beni check bench/corpus` stays clean is false.

## 2026-09-16 04:10 CEST — six review defects in the pipe-first slice

**What I did**

Fixed the six defects a read-only review found in the uncommitted pipe-first
change, each with a black-box fixture proved to fail before it and pass after
by reverting the fix and re-running the corpus.

- **`List.repeat` missed the flip.** `Int, a -> List a` became
  `a, Int -> List a`, matching `String.repeat : String, Int -> String`. Both
  arguments can be `Int`, so the mis-ordered pipe produced no diagnostic and a
  wrong answer — `0 |> List.repeat 3` gave `[]` where `List.repeat 3 0` gave
  three zeros. `core/String.beni:188` was the only caller in `core/`;
  `tests/corpus/run/ListBuild.beni` was the only one in the corpus. The `--!`
  header's claim that `cons` is the one exception was rewritten: the builders
  (`repeat`, `range`, `singleton`) take no list, so "the list comes first"
  cannot be what subject first means for them, and `range lo hi` has no
  subject at all.
- **Swept every arity ≥ 2 `pub` function in `core/` and `platforms/node/`**
  against §6.7 and against its siblings. `List.repeat` was the only defect.
  New fixture `tests/corpus/run/LibraryArgumentOrder.beni` pins the orders a
  swap would NOT be caught by the checker — both `repeat`s, `modBy`,
  `remainderBy`, `clamp`, `replace`, `contains` — because those are the ones
  that fail silently.
- **`saturate` and `bindSpine` disagreed about a parenthesised nested pipe.**
  `saturate` stripped parentheses and flattened only `.apply`, so
  `1 |> (2 |> f)` fell through to the call-the-value branch in expression
  position while a `<-` right-hand side flattened it. `saturate` now calls
  `bindSpine`, so there is one spine walk and one reading.
- **`<|` lowered its operand before the callee.** The new comment claimed the
  operand is lowered where it is written either way, which is true for `|>`
  and false for `<|`. The `.last` operand is now lowered after the argument
  loop, mirroring the hole branch. Latent today because the backend re-derives
  evaluation order from the tree, but visible in BIR and load-bearing once `?`
  reaches the backend: `Just (two (String.toInt a?) <| String.toInt b?)` used
  to dump the `try` on `b` first, so the wrong early return would win.
- **`pipe_rhs_not_application` suggested a repair that does not do what it
  says.** Parenthesising does not pass the block along as a value —
  `5 |> (\y -> y + 1)` calls the lambda on `5` and is `6`, because §6.7 looks
  through the parentheses. The message now says that and points at `<|` for a
  block that is meant to be the argument.
- **Two false statements of fact.** `InternPool.zig`'s "declaration order IS
  the index; append only" was broken by deleting `apL`, `apR`, `composeL` and
  `composeR` from the middle. I restated rather than dropped it: the identity
  holds within one build, and the sentence now says an index is not a value to
  persist and that M4's on-disk cache must be keyed on the compiler build.
  `tests/corpus/check/args/README.md` cited §6.5 for the subject-first
  convention; that is §6.7's library-convention row.

**What I learned**

- **A same-shape pair across two modules is a better defect detector than
  either module read alone.** `List.repeat` looked fine next to `List.range`
  and wrong only next to `String.repeat`. The sweep that followed found
  nothing else, which is the useful half of the result: the flip was
  systematic and this was the single miss.
- **Two argument positions of the same type are the checker's blind spot.**
  Every other flip in this change was caught by a type error somewhere in
  `core/` or the corpus. `repeat` was not, because `Int, a` unifies with
  `a, Int` when `a` is `Int`. The new run fixture is deliberately built out of
  exactly that class — `modBy`, `remainderBy`, `clamp`, `replace` — rather than
  out of whatever was convenient to print.
- **Duplicating a desugaring rule is how two positions drift apart.**
  `saturate` and `bindSpine` both implemented "look through parentheses, then
  flatten", and the newer one implemented more of it. One function now, called
  from both.
- **A comment that states an invariant is a test that nothing runs.** Both
  false statements here were written true and made false by a later edit in
  the same change. The fix for the `InternPool` one is not to restate it more
  carefully but to say what will depend on it and when — the daemon, in M4.

## 2026-09-16 10:26 CEST — review of report 18, and the static-dispatch spike plan

**What I did**

- **Checked `research/18-static-dispatch-revisited.md` against its sources.** All seven Zulip
  quotes I pulled match the live messages verbatim, with the right authors and dates; the three
  Roc langref quotes and the repo citations hold. Defects found and reported, not yet fixed:
  "§708" is a stale line number used four times for what is §3.2 "Modules: no header"; the `->`
  operator is not in `test/echo/all_syntax_test.roc` as claimed (it is in other vendored tests);
  the comparator-site counts (19/20) do not reproduce (grep gives 9/12); the research session left
  no diary entry; `fast-compiler.md` line 79 still cites only reports 09 and 10; the §3.1 table
  still states the three withdrawn reasons unmarked. Two argument weaknesses: §2.3's claim that Roc
  does not pay the interface-churn cost is unsourced, and the churn comparison ignores that today's
  equivalent edit adds a parameter, which also changes the interface; §2.2 reads Roc's
  implementation defect (since designed away by per-use instantiation, which is how Haskell class
  methods always worked) as an inherent loss of principality.
- **Planned the static-dispatch spike** in `plans/static-dispatch-spike.md`, from four read-only
  maps of the checker, module system, backend and harness. Decisions taken with the user: dot-call
  syntax resolved on the receiver's type; the *module rule* for the method set (Roc's original
  design, flagged as something we may change); all four scope items (`where` constraints, `==` as
  `eq` with derivation, `compare` as a well-known method, return-type dispatch); N hidden function
  arguments for polymorphic sites. Eight slices on `spike/static-dispatch`, nine measurements with
  baselines captured on `master` before the first checker change.

**What I learned**

- **The mechanism is beni's `equatable` obligation generalised.** Roc's constraints live on the
  flex/rigid var, merge on flex-flex unification and become a *deferred check* when a flex meets a
  concrete type (`references/roc/src/check/unify.zig:859-1044`). beni already has the var payload
  (`TypeStore.Flags`), the per-rank obligation list, the drain loop that tolerates re-registration,
  and the "fold into the flex var for the caller to carry" path (`Solve.zig:1253`). The declaring
  module of every nominal type is already recorded (`Types.Entry.module`). What is genuinely new is
  the interface quantifier carrying a constraint range, the dispatch side table for the backend,
  and the implicit graph edges parallel checking needs.
- **Why Roc left the module rule.** It was "a method is a function defined in the same module as
  the type of its first argument" for ten months; the 2025-10 block form was adopted so that two
  types in one file, mutually recursive ones especially, can each have a `to_str`. The other three
  stated reasons are cosmetic or already covered here (`equatable` on the type is the derivation
  opt-in). For beni the immediate consequence is that `String` and `Char` are declared in `Basics`
  and must move to their own modules for `s.split` to resolve.
- **The grammar already has the `where` clause's disambiguation.** A comma ends a record field's
  type when the next tokens are `lower_ident ':'`; a constraint's type ends when the next three are
  `lower_ident dot_lower ':'`. No new precedence, no backtracking.
- **Nothing measures emitted JavaScript.** No runtime timing, no compressed size, no interface
  hashing, no CI. Node 24's built-in `zlib` brotli covers size; a `run/`-style runner covers time;
  `dump --stage=raw` byte-diffs are the honest interface-churn instrument until M4 hashes them.

## 2026-09-17 13:57 CEST — spike S0–S2 landed, S3 in flight

**What I did**

- **Roc research, before the spike.** Confirmed via Zulip that Roc deleted abilities
  (type classes) for static dispatch in early 2025, and characterised what the trade
  actually is: constrained parametric polymorphism kept, the *declaration layer* dropped —
  no nameable class, no grouped members, no conformance declaration, no orphans (which
  abilities never had either). Return-position dispatch reached parity via `module(a)`.
  Sources in the conversation; the durable half went into report 20.
- **S0** (`9f47e9d`, `d0226bc`): the normative spec `docs/design/static-dispatch-spike.md`
  and `plans/static-dispatch-c1-rewrite.md`, written by one agent from the plan, reviewed
  read-only (5 blocking / 15 must-fix / 15 minor — the dispatch table's own worked example
  miscompiled, caller/callee evidence order could silently disagree, no way to request a
  derived function from a using module), fixed, then amended again from report 20. Nine
  manager decisions recorded in Appendix A: eager nominal derivation, eta-expanded evidence
  in value position, code-point order for `String`/`Char` `<`, no `let` generalisation over
  a constrained variable (evidence stays one level, captured lexically), `==` pins both
  operands, `well_known` as an operator enum, discharge tables journaled with the store,
  obligations printing both the call and the constraint's origin, `where`-only type
  variables forbidden. 44 rows in Appendix A by the end.
- **Research 20** (`97018d3`): a code-level walk of Roc's implementation for S3–S6, verified
  citation-by-citation (~200 checked, ~20 line drifts corrected, all three headline findings
  held). Every citation now prefixed `roc:`/`beni:`.
- **S1** (`c870e9a`, `5833928`): the harness and its baselines. The harness review found the
  churn instrument scoring 130 of 258 non-compiling edits, size totals that were 34 copies of
  core, R5/R6 encodings that compiled identically, and a `--dispatch` corpus with +14 % `pub`
  values — all fixed before a single baseline was taken. Baselines captured on an idle
  machine from a ReleaseFast build in a `beni-s1` worktree (kept for S8's interleaving).
- **S2** (`19ddd37`): the front end. Review found no panics in 800 fuzz cases, but
  `type_dispatch` compiled to `undefined` with rc 0, `basicsValue` emitted `undefined` when
  core lacked a value, and operator sections lost their name and pre-solve type in
  diagnostics. Thirteen fixes, each with a fail-first fixture; two fixtures could not be made
  to fail before and are recorded as such rather than dressed up.
- **S3 launched** as two agents: the checker (§6, §7, §10) and §6.8's implicit graph edges.

**What I learned**

- **The headline finding is already in the baseline.** On today's compiler, adding an
  operation to a parameter typed `a` is rejected on every annotated declaration (16/16 in
  core) and changes the interface on every unannotated one (14/14). That is report 18 §2.3
  measured before dispatch exists; S8's job is the C1 column, not the C0 one.
- **The plan's `Descriptor` claim was wrong in a way that helps.** `Flags` 8→12 bytes fits
  the existing 16-byte `Content` payload; `Descriptor` stays 40 bytes, so M1a measures time
  only.
- **A green suite coexisted with rc-0 `undefined` twice in one slice** (rule 3 in
  CLAUDE.md, again). Both were caught only by a reviewer building programs outside the
  corpus. `bir/` and `parse/` goldens prove shape, never behaviour; every new syntax needs a
  `check/` or `run/` fixture even when the checker cannot yet do anything but refuse it.
- **Two pre-existing `master` defects** found while measuring M2: `Render.writeRecord`
  flattens under a 64-field guard and silently drops the `| r` tail, and `Schemes.Writer.
  max_depth` writes `<error>` into an interface that `beni check` exits 0 on. Both need
  fixtures on `master`; neither is the spike's.
- **Spec line numbers drift under concurrent editing.** Every reviewer's `:N` was off by
  the amount the file had grown since they opened it; matching by content, not line, is the
  only thing that worked.
- **`git worktree` is the right tool for fail-first proofs and baselines** when agents share
  a tree: no stashing, and a ReleaseFast binary of a known commit that survives later work.

## 2026-09-17 21:37 CEST — recovered from the OOM; S3 fix pass and S4 landed

**What I did**

- **Reconstructed the killed session** from its transcript and the two agents'
  transcripts. The OOM hit at ~17:45 with the S3 fix agent and the S4 backend
  agent both mid-gate; neither had reported, and their work sat uncommitted in
  one tree. Both slices were audited and reviewed before anything was committed.
- **S3 fix pass** (`04fdd62`). A read-only review of the uncommitted pass found
  defects 1 and 3 verified, 2 and 4 partial, and three blocking findings: the
  per-instantiation obligation duplicated Rule U3's deferral so every failing
  `where`-clause diagnostic printed twice (and one success path passed the same
  evidence twice); `declaresCompare` ignored `pub` and was module-scoped, so an
  unrelated `pub compare : Tag, Tag -> Order` made `Wraps Handle`'s `<` compile
  to an unsound call. Two more surfaced mid-slice from the S4 side: a `number`
  literal against an *imported* constrained callee got no evidence site (the
  emitted call was one argument short and Node threw at load), and the A.55
  branch sent every `foreign type` — `List` included — to `Basics.eq`, turning
  a correct refusal of `[ Id 1 2 ] == [ Id 1 99 ]` into a silent `False`. All
  fixed at the obligation and the gate, not the output; `Dispatch.zig`'s dedup
  block went away entirely. Spec appendix A.54–A.60 records the decisions.
- **S4 backend** (`a7f8219`). The prior agent's work was complete on all eight
  scope items; the completion agent added the A.7 `pub foreign … where`
  scenario, an `emissionOrder` rescan fix and the `internal` report for
  evidence-shape mismatches. Review then found that wall did not check arity
  (too-long and too-short evidence lists both emitted wrong-arity calls that
  ran) and four silent `undefined` returns; fixed, with an in-source test over a
  synthetic table proven to fail first. `run/UserEqInsideRecord` is held for S5,
  its refusal pinned as a blackbox scenario.
- Gates run by me on the combined tree: all green, blackbox twice.

**What I learned**

- **Two concurrent implementers plus a long manager transcript is over the
  machine's memory.** Each agent runs its own `zig build` pipeline; three at
  once with ReleaseFast benches in the mix is what died. The recovery worked
  because every agent's transcript survived on disk, but it cost a session.
  Rule now: one implementer building at a time, reviewers read-only alongside,
  no ReleaseFast inside agents, and `git worktree` for every fail-first proof.
- **Concurrent slices find each other's bugs faster than reviews do.** The
  cross-module literal site and the `List` regression were both caught by the
  backend running the checker's table, not by anyone reading `Solve.zig`. The
  `emit/` goldens caught the double-evidence regression the same way. Wiring
  slices together early is worth the coordination cost.
- **"Fix at the obligation, not the output."** The dedup block in
  `Dispatch.finish` hid a real duplication for a whole slice; removing it made
  a third duplicate source (Rule U2 vs the instantiation) visible immediately.
- **Harness gap, not fixed:** `corpus_test.zig` collects `core/` subdirectories
  with `projects=false`, so a two-module `--core` fixture cannot exist; the
  `PrivateForeignCompare` fixture carries a `foreign_outside_platform`
  diagnostic instead. One-line change, owed to S5 or S6.
- Follow-ups owed: a `dispatch/` golden pinning that the only `err` part a
  clean program produces is a `number` one (`structuralEq` relies on it); the
  churn test in `build_test` flaked twice on a first run after a rebuild
  (`churn.sh` swallows a failed spawn with `|| true`).

Next: S5, well-known `eq` — the derived bodies the backend currently refuses.

## 2026-09-18 00:28 CEST — S5 landed: derived `eq`

**What I did**

- **S5** (`dd5c58b`). One implementer, one read-only reviewer, one fix pass. The
  derived pass emits every `eq` row per §9 ahead of the declarations; `/=` is
  `!eq`; `Maybe`/`Result` evidence crosses modules; `List.member` takes
  `where a.eq`. M5 R4 measured at −29 % against `c63ae48` (a lower bound: the
  list workloads still bridge through `Basics.eq`). The reviewer found three
  exit-0 miscompiles — a constrained `top`/`ext` in value position emitted a
  wrong-arity call, a private `eq` suppressed the derived row while the
  importer still named it, and `Shapes$Box$eq` collided with module
  `Shapes.Box`'s `pub eq` — plus the `Basics` gap: its own `pub foreign eq`
  and `pub compare` excluded every type it declares from eager derivation,
  so `Order` and `Never` had no rows while uses referenced them. All fixed
  with fail-first fixtures; A.61–A.63.
- `bench/churn.sh` now exits non-zero on a failed compiler spawn instead of
  counting zero rejections; that was the `test-blackbox` flake.
- Wrote the S6 brief from a read-only planning pass (`/tmp/s6-brief.md`,
  contents to be folded into the plan when S6 lands): split into **S6a**
  (derived `compare`, `$order` tables, `Target.ext`/`top` gaining a parts
  range, `List`'s own `eq`) and **S6b** (the core rewrite and the C1 corpus,
  one commit). Decisions: `Dict.empty : Dict k v` is a constant (spec over
  plan); Dict's private helpers keep annotations with explicit `where`;
  `max`/`min` stay `number`; `Dict`/`Set` get no `eq`/`compare` of their
  own — a fixture prints what structural equality answers, for report 19.

**What I learned**

- **A synthesised name must be unspellable.** `<Module>$<Type>$eq` was the
  first emitted name containing the module separator, and a module named
  `Type` under `Module` spelled it too. `$$` is the fix; any future
  synthesised name follows the same rule.
- **§7.1's `Target.ext` has no parts range, and §9.5 needs one.** The table
  cannot express "the `List` module's own `eq`, applied to element evidence"
  inside a derived shape, which is why `List`'s foreign `eq` waits for S6a.
  The body position refused it; the value position did not — the same
  defect surfaced as a diagnostic in one place and a `TypeError` in the other.
- **The module rule bites core exactly where §11 said it would.** `Basics`
  declares `pub compare : number, number -> Order`, so step 1 of §3.3 said
  "`Order` has its own `compare`" and nothing derived. The table must be
  consulted before the exclusion.
- `dispatch/ErrParts` is a pin, not a regression fixture — it passed before
  the change it documents. Say so in the header, or someone will cite it as
  proof.

## 2026-09-18 02:26 CEST — S6a landed: derived `compare`, parts on `ext`/`top`, `List.eq`

**What I did**

- **S6a** (`fe3bdfa`). Derived `compare` bodies for every shape, `$$order`
  tables in declaration order emitted ahead of all functions, code-point
  comparators callable from inside a body. §7.1 amended: `top`/`ext` targets
  carry a parts range, filled when nested in a shape and empty at a call site,
  which is what lets `core/List.beni` own `pub foreign eq … where a.eq` and
  retires the A.51 bridge for lists. `Basics` now emits `Order`'s and
  `Never`'s rows. The reviewer found no blocking defect; two must-fix items
  were a latent `Bool`-into-`Order` fallback in value position and evidence
  slots of one instruction all numbered `1`, masked by a stable sort. A.64–A.68.
- Two checker mechanisms were added along the way and are worth knowing:
  `settleUndetermined` (A.66) gives an evidence slot nothing ever pinned —
  `[] == []` — the number/equatable bridge after promotion, keyed on the
  promoted list rather than rank; and a per-instruction evidence cursor
  (A.68) threaded through instantiation.
- Split S6 at a cleaner seam than the plan's row: S6a is the emitter side and
  landed green on its own; S6b is the core rewrite plus the C1 corpus and
  measurements, one commit. The brief for both is in `/tmp/s6-brief.md` and
  will be folded into `plans/` when S6b lands.
- **In flight before S6b:** the cursor exposed a pre-existing drain-order
  defect — a call with two constrained slots that each nest gets breadth-first
  site numbering, so `pair [[1]] [[2]]` under `where a.eq, b.eq` emits a
  four-deep evidence tree for `a` and none for `b`, exit 0. Being fixed at the
  drain, with a `run/` fixture that executes the repro.

**What I learned**

- **A stable sort can hide a broken key for a whole milestone.** The
  `(inst, evidence_index)` key had duplicates since S3; output was right only
  because `std.sort.block` is stable and insertion happened to be pre-order.
  The dump showing `1 1 1 1` was the tell, and nobody had a fixture with a
  nested constrained element until `List` got its own `eq`.
- **The value position and the body position must refuse the same things.**
  Twice now (S5's `partValue`, S6a's `derivedValue`) the body-side wall was
  right and the value-side fell through to `Basics.eq`. Any new wall goes in
  both, and the review checklist asks for it by name.
- **Pins are not proofs.** `ConstrainedMutualRecursion` and `ErrParts` both
  pass on the base commit; the headers now say so. A fixture that cannot fail
  first is still worth having, but it must not be cited as evidence.

## 2026-09-18 05:11 CEST — S6b landed: the core rewrite and the C1 corpus

**What I did**

- **Pre-order sites** (`8081b5f`): the S6a cursor exposed that a call with two
  constrained slots that each nest was numbered breadth-first, so `pair [[1]]
  [[2]]` under `where a.eq, b.eq` ran wrong with exit 0. Fixed with a parent
  link per site and a pre-order sort in `Dispatch.finish`, not by changing the
  drain — the drain alone could not have worked, since both slots are
  numbered by one instantiation before either is discharged.
- **S6b** (`5dfc082`, one commit as planned): `Dict`/`Set`/`List.sort` on
  `where k.compare`, `Dict.empty` a constant, `Dict.String`/`Dict.Int` deleted
  with all 24 use sites, `List.compare` foreign, the six `bench/corpus` files
  and three runtime programs rewritten by hand, the derived-body refusals
  removed from the backend. Reviewed against C0 with eight probe programs
  whose output was byte-identical on the `c870e9a` binary. Two checker
  defects surfaced under the rewrite and were fixed at the cause: a rebuilt
  constraint set stranded its inputs as live obligations (A.75, a redirect map
  journalled for `tryShape` rollback), and a joined constraint instantiated
  its callee's nested evidence for the first instruction only (A.76).
- **Measurements** appended to the results file: the `--dispatch` generator
  goes from 1 682 diagnostics to 0; M3 annotated rows stay at 0 interface
  changes on both corpora; M4 floor +5.5 % with derived `eq` 1 050 B and
  derived `compare` 1 889 B reported separately, about 200 B per derived
  function on the bench corpus; M5 R1–R3 flat within round-to-round spread
  with identical checksums; M8 17→0, 15→4, 7+17→0, two modules deleted.
- Fixed a harness flake: `bench/churn.sh` passed the corpus copy as a bare
  positional, and a tmp-dir name beginning with `-` was parsed as an option
  about once per 32 seeds. Now `--` precedes it.

**What I learned**

- **The corpus rewrite was cheap; the checker under it was not.** Every
  blocking finding in S5–S6b was in `Solve.zig`'s constraint bookkeeping, and
  every one was a *pre-existing* S3 defect that only a richer program shape
  could reach: nested constrained calls over a `let`-bound seed, two names on
  two variables, list keys. Report 19 should say that the table design held
  and the obligation plumbing needed four passes.
- **"Answered exactly once" needs an identity, and a constraint index is not
  one.** Sets are append-only ranges, so every rebuild changes the index;
  anything keyed on it (obligations, `resolved_methods`, `deferred`) must
  follow a redirect. This is the same lesson as the `evidence_index` key,
  one level down.
- **Structural `==` on `Dict` compares tree shape.** With four insertions in
  two orders `==` answers `False` while `toList` agrees. Left for report 19
  as a language decision (O-5), pinned by `run/DictStructuralEquality`.
- S7 is pin-and-close: the feature landed across S2–S4; what is missing is
  fixtures for the untested mechanisms (result-only quantifier across a
  module boundary, forwarded return-position evidence, the `.any`
  undetermined arm) and a §4.1 citation that names a Roc syntax which does
  not exist.

## 2026-09-18 05:30 CEST — S7 landed: return-type dispatch pinned

**What I did**

- **S7** (`0ef34da`) as a pin-and-close slice, on the read-only planner's finding
  that S2–S4 had already built return-type dispatch end to end. Six new
  fixtures, every one passing at base and recorded as such: the dump shape of
  a receiver-less site, the second trigger of §10.8, the `.any` undetermined
  arm, `run/DecodeInto` (forwarded evidence, a later-use `let`, a
  `number`-spelled variable through the A.53 bridge), its table, and a
  result-only quantifier crossing a module boundary. No `src/` change. §4's
  Roc citation now names the shipped `s_type_var_alias` form; A.77–A.80.
- Briefs for S6, S7 and S8 now live under `plans/`. S8 is split: S8a takes
  the rows never measured or measured on a superseded binary — M1a
  interleaved, M1b on one corpus with two compilers, M2 on the final tree,
  M5 R4–R6 with C1 programs, profiles, M7 — and S8b writes report 19.

**What I learned**

- **A brief that says "expected to pass at base" is the honest shape for a
  pin slice.** Three of the six S7 fixtures were predicted to pass and all
  six did; saying so up front kept the implementer from dressing pins up as
  fail-first proofs, which happened twice in S6.
- **The forwarded-evidence site is flat.** A forwarded `$m$k` is one slot,
  never a tree; pre-order nesting (A.68) only arises when the target itself
  takes evidence. The brief expected otherwise; the golden was right.
- Owed to a later pass: §10.8's message renders argument types as unresolved
  flexes because the rigid arm reports before the same `and_`'s argument
  constraints are solved. Cosmetic, pre-existing, out of S7's scope.

## 2026-09-18 10:31 CEST — handoff: S8a paused, moving machines

**What I did**

- Committed the S8a rows the previous session had taken before it died
  (`3984d2d`): the S6b-header correction, M1a interleaved (check 1.20×, emit
  1.48× on a corpus with no dot-call), and M1b as one corpus through two
  compilers (1 683 errors on `master`'s checker, 0 on the branch).
- Stopped the relaunched S8a agent before it appended anything. The tree is
  clean and pushed. Two stale agents from the S3/S4 era were reported
  "stopped" on resume; their work is in `10f89b5`–`a7f8219`, nothing lost.

**Handoff — resuming on another machine**

- **Every number in `plans/static-dispatch-spike-results.md` is from one
  Intel N100.** The remaining S8a rows (M2, M3, M4, M5, M7, M8, M9 — brief
  §3) must not mix machines with the rows above. Either take them here later,
  or on the new machine re-take the C0 sides they compare against (M2, M5 R1–R6
  need the A binary; M3/M4/M8 cite S1's C0 rows at `:220/:293/:448` and would
  need re-taking too) under a new "machine 2" heading, and let report 19's §1
  method section say which rows are on which machine.
- **Binaries:** A is a ReleaseFast build of `c870e9a` (`git worktree add
  ../beni-s1 c870e9a`, then `zig build -Doptimize=ReleaseFast` — 13 317 664 B
  on the N100); B is HEAD built `--prefix /tmp/rf`. Neither worktree nor
  `/tmp/rf` travels; recreate both.
- **Still owed by S8a:** the `size.mjs` split fields (`eq_bytes` … `order_tables`)
  and `bench/runtime/c1/R5EvidenceForwarding.beni`, `c1/R6Megamorphic.beni`
  with the C0 checksums (5000000, 1352000). Then S8b writes report 19 per the
  brief's §5 outline.
- **Machine rules that came from the OOM:** one building agent at a time, no
  concurrent `zig build`, reviewers read-only. On a bigger machine relax as it
  allows, but keep the ABBA interleaving — it is what made M1a's 20 % trustworthy
  where S6b's 8 % was not.

**What I learned**

- A session can die with an agent mid-append and leave a valid, partial,
  uncommitted results file: append-only plus raw-lines-verbatim is what made
  it committable as-is instead of reconstructed.

## 2026-09-18 12:16 CEST — S8-fix: the constraint chain was cubic, and the bisect lied

**What I did**

- Found and fixed the M2 defect S8a measured (`beni check` cubic in time *and*
  memory on `--pathological=constraint-chain=n`, killed at 29 GiB at n = 1000).
  The cause is `Solve.attachConstraint`: §6.3's `flex` row re-attaches every
  deferred constraint to the variable it is already on, the name is already in
  the set, so the JOIN path rebuilt the whole set — copying it, joining a site
  list with itself, and redirecting every index to the copy of itself — to
  produce the set it started from. O(set) per obligation, and link k of the
  chain defers k constraints over a set of k. The fix is a three-comparison
  guard that returns the caller's index when it already lies inside the root's
  range under `c`'s name (A.81).
- Test: `tests/blackbox/abuse_test.zig`, "an unannotated constraint chain costs
  one merge per link, not one per constraint" — two chains (64 and 128 links,
  `--core-root=nocore`, so no core number is in it), counters read back out of
  `--self-profile`. Fail-first proved by stashing the fix: `expected 63, found
  2143`. It pins all six dispatch counters, not just the merges, because the
  cheap way to make merges linear is to stop registering obligations.
- Evidence (ReleaseFast, `--iterations=5`): n = 100 **51.2 → 6.4 ms**, n = 1000
  **killed → 459.9 ms**, n = 2000 **never attempted → 1 967.7 ms**. `beni check`
  peak RSS n = 400 **3 307 → 70 MB**, n = 1000 **29.2 GiB → 388 MB**. The
  100 159-line corpus is unmoved (73.2 → 72.2 ms check). Four gates green,
  `test-blackbox` twice.

**What I learned**

- **The bisect pointed at the wrong commit and the counters said so.** S6b
  (`5dfc082`) is where RSS crosses whatever threshold you bisect on, but
  `8081b5f` — its parent, "good" — already reads 21 / 132 / 935 ms at
  n = 100 / 200 / 400, which is cubic too. A.75's redirect map multiplied the
  constant by ~3.3; it did not introduce the exponent. A bisect over a
  *continuous* quantity finds where it crossed your threshold, not where its
  growth rate changed — for a complexity defect, fit the curve on both sides of
  the "good" commit before believing the bisect.
- The brief's other framing was wrong the same way: obligations did not go
  linear → quadratic at S6b. `8081b5f` reports 5 064 at n = 100 against HEAD's
  5 099. n(n+1)/2 obligations is what A.57 asks for on this input and matches
  `constraints_promoted`, which has been n(n+1)/2 since S3. The S3 row's 1 014
  is a *different* checker, and reading two counters from two commits as one
  series is what made a correct quadratic look like a regression.
- The counter that actually localises this defect is `constraints_merged`: it
  counts set rebuilds, and on the chain it was n(n+1)/2 + n − 1 where the honest
  number is n − 1. A rate that should be per-declaration and reads
  per-constraint-per-declaration is the whole signature, and it is visible from
  outside the binary through `--self-profile` — which is why the test is a
  counter assertion and not a timeout.

## 2026-09-18 13:04 CEST — S8 closed on a second machine: rows, A.81, report 19

**What I did**

- Resumed from `plans/static-dispatch-resume.md` on a new machine (`dagon`,
  Ryzen 9 5950X, 32 threads, 31 GiB) and took §2's option (b): a "machine 2"
  heading in the results file, every C0 side re-taken here, M1a/M1b left
  N100-only. A rebuilt at `c870e9a` is 13 253 080 B here against 13 317 664 on
  the N100; nobody has explained the difference and report 19 §16 says so.
- **S8a** (`d9e1b02`): M2–M5, M7–M9, the `eq`/`compare`/`order` split in
  `bench/size.mjs`, `c1/R5` and `c1/R6` with checksums agreeing. Validated by
  re-running M2 at n = 200 and both runtime variants myself before committing.
- **S8-fix** (`98fe87a`, A.81; the implementer's own entry is the one above):
  M2 found the branch cubic on the unannotated chain. Stash-proved the counter
  test (`expected 63, found 2143`) before committing.
- **S8a′** (`0680e08`): M2 re-taken ABBA on the fixed binary — exponent down by
  exactly one in time and space, n = 1000 441 ms / 411 MB — plus the correction
  of S8a's "regression since S3" reading, and M3/M4/M5-checksum identity across
  the fix established by diff rather than asserted.
- **S8b**: report 19 (`docs/design/research/19-static-dispatch-spike-results.md`,
  1 025 lines). Validated by a script that checks every number on a
  `results:NNNN`-citing line against the cited range (82 checked, 5 unmatched,
  all five false positives or cited elsewhere on the page), a hand trace of
  seventeen headline figures, and a read of §0 and §15. One edit of mine: the
  closing question said "5–6×" from the brief's draft where §4 measures
  4.4–6.5×.
- Filename discrepancy owed by the S8 brief's decision (1): plan §7 names
  `19-static-dispatch-spike.md`; the report is `19-static-dispatch-spike-results.md`.
- The spike is complete. **The branch does not merge**; the adoption decision is
  taken on `master` after the report is read. `../beni-s1` and `/tmp/rf` are
  left in place on this machine.

**What I learned**

- **My bisect was wrong and the implementer's curve-fit was right.** I bisected
  on an RSS threshold, got S6b, and briefed the fix as "a regression since S3
  in A.75". The implementer built the "good" parent, found it already cubic,
  and corrected the brief. A manager's diagnosis in a brief is a hypothesis;
  the brief should say so, and "confirm the cause before you fix" is the line
  that saved this one.
- **A measurement slice earns its keep by being allowed to fail.** S8a's rule
  was "no `src/` change, stop and report" and it reported a 29 GiB kill rather
  than working around it. Had M2 been re-taken only at the n the N100 rows
  used, with the S3-era numbers cited for the rest, report 19 would have
  priced a bookkeeping bug as the design's cost — or missed it.
- **Re-taking the C0 side on a new machine was cheap and paid twice**: M3 and
  M4 came out byte-identical across machines, which the report can now state
  as machine-independence instead of assuming it.
- The manager-workflow memory did not travel with the repo; the resume
  document's §5 was enough to rebuild it. Anything a future session needs to
  drive the work belongs under `plans/`, not only in a per-machine memory.

## 2026-09-18 15:36 CEST — static dispatch adopted and landed; the loop; the cap

**What I did**

- **The decision.** The owner read report 19's options, asked what `where` is
  for, and chose option (b): adopt the whole spike — `where` is the extension
  point library authors need, the code is written and measured, and pre-1.0 it
  can still be withdrawn. Then went offline with "continue, don't stop; you are
  manager, planner and validator; Opus agents implement". The running order is
  `plans/queue.md`.
- **L1** (`89ce028`): the spec promoted in place to a normative document —
  file name and every §N kept, because ~100 files cite them — instead of the
  re-slice into four documents report 19 §14 assumed; `fast-compiler.md` §3.1
  records points 3 and 4 as reversed; pointers at every extended section;
  `checker.md` Appendix B brought back in line with `core/`. `master` had not
  moved since the branch was cut, so it **fast-forwarded** (owner-approved) and
  was pushed.
- **The stale hint** (`cfe4665`): two "numbers only" hints still named `<`.
- **Tail-call loop**: spec (`1cbf68e`) then code (`bbfc869`, built in an
  isolated worktree beside the checker slice and cherry-picked after).
  `$in$<i>` slots plus a per-iteration `const`, no temporaries; `foldl` and
  `foldr` are beni now and **no `foreign` value in the repository takes a
  function**. Validated by reverting `Lower.zig` and core to the parent: seven
  `run/` fixtures overflow the stack, the `emit/` golden mismatches.
- **The warning and the cap** (`9074538`, A.83) — **manager decisions, taken
  with the owner offline, each reversible in one commit**: §10.9's
  inferred-interface warning is on by default for the author's own package; an
  unannotated declaration inferring more than 64 method constraints is
  `too_many_inferred_constraints` and hands nothing on. The 3 000-link chain:
  4.4 s / 3.7 GB → 0.10 s check (re-run by me: 46 diagnostics). 64 because the
  pre-dispatch checker already refused such chains there. The slice also found
  `beni build` asserting that no warning exists before emit — a panic the
  moment one did.
- CLAUDE.md corrected: the no-currying change had already landed in the backend
  (the "still to come" line was stale), and both of the effects proposal's
  blockers are now discharged.

**What I learned**

- **"The branch never merges" was a statement about documents, not code.** The
  obstacle was rule 1 — a contract living in a file that called itself a spike
  while four documents described a different language. Promoting the spec in
  place cost one docs slice; the re-slice would have renumbered what a hundred
  files cite.
- **I briefed "evidence parameters are loop-invariant" and the spec author
  proved it a miscompile**: polymorphic recursion type-checks with an
  annotation and passes different evidence at the self-call. Second time today
  a brief's premise was wrong and the instruction "verify before you build on
  it" is what caught it (the first was my bisect). Briefs now state premises as
  things to check.
- **Elm's `$temp$` scheme is wrong here even with the temporaries**: the
  closures fixture prints `0 0 0` under it. The ordering hazard and the capture
  hazard are different bugs and only the per-iteration binding fixes the second.
- **A worktree per building agent works on this machine** and keeps two code
  slices honest; the cost is a cherry-pick and one more gate run on the
  combined tree. The harness moves the session's cwd into the worktree when its
  agent reports — never use bare `git stash` from there, the stack is shared.
- Replacing `foldr`'s JS array walk with reverse + `foldl` in beni did not
  slow R1–R6; R3 moved ~11 % the good way. Attribution unverified.

## 2026-09-18 18:35 CEST — unattended: the adoption's debts paid, M3b nearly closed, five exit-0 holes shut

**What I did** (manager; every implementation by an Opus agent, every unit
validated by me — fixtures proven to fail first, gates re-run on the combined
tree — before its commit; running order in `plans/queue.md`)

- **The five debts of the dispatch adoption are paid**: printer defects
  (`83ce553` — the `<error>`-in-an-interface cause was a 256-slot stack in the
  poisoned-type scan, not `Schemes.Writer.max_depth` as report 19 guessed),
  the `foreign` arity check as `boundary.md` §4 check 4 (`16b1c0d`, a token
  count, no JS parser), the warning-by-default and the cap of 64 (`9074538`),
  and **reachability DCE** (`dc311d0` spec, `22f7f2f` code): hello-world went
  from 68 794 bytes in 19 files to 2 061 in 5 — re-measured by me.
- **M3b**: tail-call loop (`bbfc869`), decision trees (`ebacb5b` spec,
  `cf7806f` code: worst path 17 → 2 on an enum-in-a-cons match, R1–R6 10–20 %
  faster, checksums identical). `?` codegen is in flight and is the last gap;
  `Int32` does not exist in the language at all — **owner decision**.
- **Five exit-0 wrong-answer paths found and closed**, none by the gates:
  a refutable pattern in a parameter was an unchecked destructure (`59e47f3`);
  a `case` the usefulness budget could not decide passed in silence and fell
  off a default-free tree (`f21ac4c`); a sibling that forgot its evidence
  parameter made `[1,2] == [1,2]` answer "different" (`16b1c0d`); `List.map`
  ran its callback right-to-left and `Dict.map` pre-order (`51ab217`); a
  `let` value naming a later one threw a TDZ error (`3c8fbf8`). Two more are
  queued: record literals evaluate fields in sorted-name order, and top-level
  value cycles throw at load.
- Evaluation order is normative at last (`language.md` §6, `f21ac4c`) with
  four `run/` guards for M3c's inlining; `--source-maps` is refused rather
  than swallowed (`b41e860`); `Render.Namer` is O(1) per name (`b48160b`).
- `plans/effects-plan.md` (`fe3cf8e`): the proposal corrected against what
  landed, slices E0–E6, and **eight decisions that are the owner's**. No
  effects code was written.

**Manager decisions taken with the owner offline** (each one commit, each
recorded where it lives, each reversible): the inferred-interface warning on by
default and the cap of 64 (A.83); irrefutable positions decided by usefulness,
`let` widened to admit single-constructor patterns (`language.md` §7);
budget exhaustion is an error; core callbacks run in list order and `foldr`
is the exception by contract; `let` keeps written order and refuses forward
value dependencies; `--library` as DCE's second root rule.

**What I learned**

- **My briefs were wrong four times and "verify the premise" caught each**:
  the bisect (morning), "evidence is loop-invariant" (polymorphic recursion),
  "parameters obey `let`'s syntactic rule" (40 sites broke, 27 in core — the
  implementer built it, counted, and argued for the type-directed rule), and
  the DCE spec's edge set (wrong three times: operators leave no `refs` row,
  `primitive string_compare` calls core, `err` calls `Basics.eq`). What
  saved DCE was a **compile-time self-check** — "I emitted a reference to X,
  which this build eliminated" — that fired before any fixture ran. For any
  pass whose failure mode is a runtime `ReferenceError`, build the check that
  turns it into a compiler error first.
- **An audit by experiment beats a list in a document.** `backend.md` §1's
  M3b list was stale in four of seven items, and the audit's headline was a
  miscompile nobody had listed. Same for "zero higher-order `foreign`
  values": true of signatures, false of `where` clauses.
- **Tests had been asserting two of the holes.** An abuse test pinned "a
  2000-deep single-branch `case` checks clean" and a `parse/good` fixture
  advertised "a binding used before its textual position". A fixture that is
  never RUN proves nothing about behaviour — rule 3's preference for `run/`
  is not a style note.
- **Worktree-per-building-agent scales to four agents on this machine**; the
  cost is a rebase + one gate run on the combined tree per landing, and that
  gate run is the real integration test (it is what ran every evaluation-order
  fixture under DCE). Docs shared between two in-flight slices in ONE checkout
  cannot be committed separately — give each slice its own files or its own
  worktree.
- Emit MB/s is a bad regression metric once a slice shrinks the output: decision
  trees made emit 13 % faster and the MB/s figure 9.6 % worse.

## 2026-09-18 22:54 CEST — unattended, second half: M3b closed, `--release`, and three plans for the owner

**What I did** (same arrangement: Opus agents implement, I validate and commit)

- **M3b is closed** apart from `Int32`, which does not exist in the language
  (owner decision): `?` codegen (`b545b60` — a test and a `return` of the
  failing object itself; BIR has a dedicated `try` instruction, the audit and
  `language.md` were both wrong about that), record literals evaluate in written
  order (`2bf6f03`).
- **M3c slice 1, `--release`** (`e605066`..`822eab5`): dead bindings, narrow
  single-use inlining, two-namespace emission-order names, compact printing,
  `const` joining. `bench/corpus` 126 436 → 55 593 raw, 21 840 → 15 017 brotli;
  the whole `run/` corpus runs a second time under `--release`.
- **Three more exit-0 holes closed**: `let` forward value references
  (`3c8fbf8`), top-level value cycles (`a9b77c9`, a checker pass that walks
  dispatch-table edges because a method call leaves no `refs` row), and the
  exhaustiveness budget, whose flat and pair-keyed fast paths (`992ab59`,
  `0d2c1c5`) also make lookup tables linear to check.
- **The interface record is pure** (`792bf76`): it named types by a
  whole-program `TypeId`, so a type added to any earlier module renumbered
  untouched interfaces — and a RENAME of a mentioned type did not change the
  bytes at all. Found by the M4 audit, fixed the same hour.
- `sortBy` computes each key once (`128002b`); evaluation order is normative
  and guarded; `check`'s budget default is 5 M.
- **Three plans for the owner, no code behind any of them**:
  `plans/effects-plan.md` (8 decisions), `plans/m3d-plan.md` (6 — `lazy` is
  hard-blocked on effects), `plans/m4-plan.md` (9 — disk cache before daemon;
  slice zero does not exist). Plus `plans/state-of-the-compiler.md`: measured
  on a quiet machine, check 1.3 M LOC/s per core (5× budget), cold 100k build
  109 ms (7×), floor 2 147 bytes against C0's 65 214.

**Correction to an earlier statement**: commit `128002b` and my report at the
time said `sortBy`'s fix makes R3Sorting 18 % slower. That was measured beside
building agents. On a quiet machine the same C0 source through both compilers
costs +1.9 %, and R3's C1 side reads 808 ns/op, not 928. The mechanism is real
(GC 7.4 → 18.5 ms on R3's profile — a pair per element); the size of it was
noise. The ABBA-on-a-quiet-machine rule exists for this, and I broke it by
accepting an interleaved number taken on a busy one.

**What I learned**

- **The widened-inliner experiment is the pattern to repeat.** The release spec
  restricted inlining to atoms and member chains on a bytes argument; asking the
  implementer to widen it and sweep the corpus showed the restriction is a
  SAFETY rule (four programs reorder or duplicate evaluation). A spec rule
  justified by measurement alone should always get the "what breaks if we
  don't" run before it is written down as merely an optimisation choice.
- **Three more of my specs were corrected by their implementers** (DCE's edge
  set ×3, release's count array and substitution key, §7's default edge). Every
  one was found by a mechanism, not by reading: a compile-time self-check
  (`requireLive`, `Rename.verify`) or the corpus running under the new mode.
  Specs state intent; the self-check and the second corpus pass are what make
  an implementer's deviation visible the moment it matters.
- **A design audit is worth running BEFORE the milestone, by reading code.**
  The M4 audit found a leak that every existing instrument was structurally
  blind to (determinism tests vary `--jobs`, churn edits the module it diffs),
  and it cost one slice today against a re-bless per milestone later.
- **Owner-gated work piles up fast in unattended mode.** By the end, effects,
  M3d's `lazy`, M4's ordering and `Int32` all waited on decisions; what kept
  the queue moving was the audit-by-experiment slices (M3b audit, evaluation
  order, state of the compiler), each of which surfaced real defects. When the
  roadmap is blocked, measure and audit — it found nine miscompile-class bugs
  today that no gate had caught.
- `beni check` cannot check a program that imports its platform — found only
  because a measurement wanted a warning count. Tooling gaps hide where the
  test corpus has no reason to go.

## 2026-09-19 02:53 CEST — unattended, third stretch: M4 slice zero, two audits, and what they caught

**What I did** (Opus agents implement; I validate, commit and push)

- **M4 slice zero** (`506f596`..`f8357ba`, spec `a11535e`): the interface as
  little-endian bytes with its symbols as text, a SipHash128 over them, a
  32 251-mutation corruption test, and the acceptance matrix — 336 fixtures
  checked cold and again with every interface round-tripped, at `--jobs=1` and
  `8`, byte-identical. **Manager decision**: started without the owner because
  it is the same under every answer to `plans/m4-plan.md`'s nine decisions and
  adds only two hidden flags. First firewall numbers, by hash: an interface
  change never moved a second module (366 edits), a type added elsewhere moves
  nothing, reading every record is 0.50 % of a cold check.
- **The interface record is pure** (`792bf76`, found by the M4 audit the same
  hour): it named types by whole-program `TypeId`.
- **`beni check --platform`** (`b3156c6`): a real program could not be
  type-checked without being built.
- **Coverage audit by experiment** (`cf1b14a`): core's public values executed
  by a fixture 126 → 199 of 205 under V8 coverage; all 107 diagnostic codes
  tested. It found `String.indexes` counting UTF-16 units, two `main`s titled
  MISSING MAIN, nine doc examples that did not compile, `map2`–`map5`
  overflowing near 5 000 elements — all fixed (`3edc718`, `06a2893`,
  `6eca714`, `60bc529`).
- **A doc-example gate** (`45ca0f9`): every `--|     expr == value` in core is
  appended verbatim to a copy of its own module, built and RUN — 225 examples.
  On its first run it caught a miscompile: a constrained `foreign` used in
  value position inside its own module was eta-expanded at arity 0 (fixed in
  this session's last commit; BIR now sets a `foreign`'s `params` from its
  annotation, and boundary check 4 reads the same number).
- M3c slice 2 (field ambiguation) **specified and declined on measurement**:
  0.07 % brotli over 109 trees. `plans/state-of-the-compiler.md` has the
  quiet-machine numbers.
- `String.indexes` now finds NON-overlapping matches (Elm's rule, read from the
  vendored kernel) — a behaviour change, stated in the doc; `contains s ""` is
  `True`. Both manager decisions, reversible.

**What I learned**

- **A gate that executes documentation is a test generator.** 225 tiny
  programs written by whoever documented core, each compiled INSIDE its module:
  that in-module scope is what no corpus fixture has (the corpus can only
  import core), and it is exactly where the `foreign` arity bug lived. Any
  claim that can be executed should be.
- **Two independent computations of one fact is a bug waiting.** Check 4
  computed a foreign's arity from its annotation; the backend read BIR's
  `params`; they disagreed for a year of commits' worth of code and both
  passed. The fix was to make one read the other. Same shape as the
  `Cycles`/`Reach` duplicated edge walk still in the queue.
- **"Measured on a busy machine" is now a required label.** The map2 slice saw
  the same phantom regression the sortBy slice did, and the implementer
  discarded it by interleaving — the lesson transferred through the brief.
- **When the roadmap is owner-gated, the work that pays is: audits by
  experiment, the architecture-neutral first slice of the next milestone, and
  closing what they find.** Eleven miscompile-class defects in one day, none
  caught by the three gates as they stood that morning; the gates are now
  materially different (second corpus pass under `--release`, the round-trip
  matrix, the doc gate, three compile-time self-checks).

## 2026-09-19 16:21 CEST — the owner returns: M4 first, rule 7, Effect as gold standard; M4-1 lands

**What I did** (manager; Opus agents implement; I validate, land, push)

- **Owner decisions taken today**: M4 before effects; `lazy` parked until a
  browser platform and a large app want it (M3d shrinks to static multi-entry
  chunking + the single-file release bundle); `--release` refuses `Debug`;
  `Int32` is built; effects gets a full spike with **Effect-TS v4 as the gold
  standard** ("Effect-level quality and API coverage"); and the stance that is
  now `CLAUDE.md` **rule 7, guarantees not restrictions**.
- **M4-1, the persistent cache** (`1191d46`..`008e5e1`, spec `36dc8df`): a
  module whose key held is not re-checked. Warm `check` 63 ms against 131
  (`--jobs=1`, 100k lines), within the spec's prediction; the front end is 76 %
  of a warm run, which is M4-2's. An import contributes its KEY, not its
  interface hash, so a comment in a leaf still re-checks importers until M4-3.
  Warm ≠ cold was never observed; I truncated every entry by hand — 14 misses,
  then 14 hits, output identical to `--no-cache`.
- **`core/Int32`** (`dca83e9`, `d6582ba`): my own FNV-1a in beni printed the
  published vector under `--release`. It also exposed that any function named
  `add`/`eq`/`cons` in any module was reported as "the (+) operator".
- **`--release` refuses `Debug`** (`ad1144b`) with a hidden `--allow-debug` so
  the 24 `Debug.log`-based order fixtures still run in the release pass.
- **Robustness audit** (`1592b34`): 613/613 files idempotent under `fmt` with
  AST, comments and emitted JS preserved; 86 900 mutants, no crash. What broke
  was the CLI around them — `beni check .` rejected every file, `fmt` reset
  modes to 0644 and replaced symlinks, `dump` exited 0 over an error — all
  fixed (`0bc5d89`..`492842e`).
- **Effects research**: `references/effect` vendored at 4.0.0-rc.116; reports
  21 (runtime, measured), 22 (API surface), 23 (78 executed semantics cases);
  `plans/effects-decisions.md` (16 / 11 / 9 decisions by tier, five to answer
  first) and `plans/effects-spike.md` (sixteen slices, kernel probe first).

**Corrections to things I told the owner**

- I said `Int32` had "no design paragraph" and recommended striking it. Wrong:
  `fast-compiler.md` §3.1 and `checker.md` Appendix B specify it; I had
  repeated an audit's summary without checking. The owner then explained it was
  an EXAMPLE of a stance, which became rule 7.
- My hand test of the cache "found" a body edit with zero misses. The file
  content had been written by an earlier failed attempt of mine and was already
  cached — content addressing doing its job. Check the test before the code.

**What I learned**

- **The owner's stance changes recommendations I had already made.** Under
  rule 7 the default for a restriction that buys no guarantee is a warning, and
  the default for a capability gap is to fill it inside the wall. Report 22
  applied it within the hour: a shipped program cannot log (queue 51).
- **Executable research beats read research.** Reports 21 and 23 installed the
  vendored version and RAN it: two of report 16's quoted figures failed to
  reproduce, v4 turned out not to be the runtime report 16 studied, and 51 of
  78 observable behaviours are simply absent from the proposal. A design
  document reviewed only by reading would not have shown any of that.
- **When a long slice must rebase over a busy master, send it back to its
  implementer.** I started M4-1's nine-commit rebase myself, hit a conflict
  that recurs per commit, and aborted; the implementer resolved it with context
  AND used the new base to strengthen four tests. The manager's rebase is for
  one-conflict cases.
- A test that leaves a read-only directory behind breaks `git worktree remove`
  — harmless, but the harness should restore modes on teardown.

## 2026-09-19 21:58 CEST — parked by the owner; effects decisions; M4-2 landed, M4-3 in flight

**What I did**

- **M4-2** landed (`13dfa84`..`ea89358`): the front end on disk, the AST
  deliberately not cached. Warm `check` 62 → 39.5 ms, warm `build` 122 → 100.5 —
  the `< 120 ms` warm-start budget met for the first time. By hand: a body edit
  in a leaf re-lowered 1 file and re-checked 2 modules; every artifact truncated
  → 14 re-lowered, 0 re-checked, output identical to `--no-cache`.
- **M4-3** specified (`4b51386`): thirty kinds of cross-module fact, an
  instrumented run that saw none the list lacks, and two demonstrated programs
  where the interface hash holds while an importer goes from exit 0 to exit 1 —
  hence a second hash, the dependency digest. Its implementer was running in
  `slice/m4-3` when work was parked.
- **Effects decisions with the owner** (sheet `plans/effects-decisions.md`): A1
  defects are fatal and the wall's job to prevent, finalisers infallible,
  `Exit a = Done a | Cancelled`, the seven interruption rules; A5 `impure` used
  from the slice that infers it; A6 `sync` in the first cut; A8 `main` stays,
  keep-alive, exit 0/1/130. A7 (services) was mid-discussion.
- **The owner parked implementation**: no new agents after M4-3 finishes.
  `plans/resume.md` is the single place to resume from.

**What I learned**

- **The owner's instinct simplified my design twice in one conversation.** I
  proposed catching defects at the fiber boundary with a list-of-reasons
  outcome type; "isn't it beni/core's responsibility that this never happens?"
  turned that into: defects are fatal, finalisers infallible, and the outcome
  type lost its `Cause`. The argument I had missed was mine to find — JS fibers
  share a heap, so containing a throw means running on state nobody can vouch
  for. When a design needs a rich failure taxonomy, first ask who is allowed to
  fail.
- **Explain decisions in the user's terms, one case at a time.** The
  five-question shortlist stalled until it became "a foreign throws", "an
  interrupt arrives", "what is the type of `user`?". Jargon I had stopped
  hearing ("from the first slice") cost a round trip.
- **A spec's prediction is a test of the spec.** M4-1 predicted 55–70 ms and
  got 63; M4-2 predicted 28–38 and got 39.5, with the miss localised to one
  phase (`decode`) the spec had not measured. Requiring a number before the
  code exists is cheap and tells you afterwards whether the model was right.

## 2026-09-19 22:02 CEST — M4-3 landed after parking; nothing is in flight

**What I did**

- Landed **M4-3, the firewall cutoff** (`92cfca8`..`ed8385f`) without a new
  agent, as `plans/resume.md` said I would: rebased, four gates green, and by
  hand — a comment in a leaf re-checks 1 module (3 under M4-1), and the
  demonstrated miscompile (a private type's payload becoming a function)
  re-checks the importer and reports `NOT EQUATABLE`, identical to
  `--no-cache`. **The cache is now on by default** (`.beni-cache/`).
- Updated `plans/resume.md` §1 (nothing in flight) and the queue.

**What I learned**

- **The slice's own report named its two misses before I looked**: a `pub`
  signature edit still re-checks 624 of 634 modules (the spec predicted
  41–47 ms; it is 127–134), and the warm floor regressed 41 → 44 ms. The first
  is the design being SOUND rather than fast — the interface-hash term is
  load-bearing because the solver reads records of modules never imported —
  and the spec's prediction was wrong because it missed that the digest chain
  propagates a hash move transitively. Two predictions held within 5 %; the
  third was off 3×, and that is the one worth re-reading before M4-4.
- Incremental ≠ cold was never observed, across 180 edit scenarios; every
  discrepancy was a counter mismatch in the harness. The self-check, the
  coarsening assertion and the differential harness each earned their place by
  finding nothing in the product and four bugs in the tests.

## 2026-09-19 22:39 CEST — the owner answers services; the five effects questions are closed

**What I did**

- Recorded **A7, services**, as the owner decided it: records of functions and
  `where` clauses now; three fixed per-fiber slots (clock, scheduler, log
  context) with the runtime, not a general service locator; the "everything
  provided at the entry point" proof conceded in writing.
- Folded all five answers (A1, A5, A6, A7, A8, and A2/A3/A10/A11 with them)
  into `plans/effects-spike.md` §0.1 and its pending table, a block at the top
  of `plans/effects-decisions.md`, the queue and `plans/resume.md`. No agent
  was started; implementation stays parked.

**What I learned**

- The fold was cheap because the plan had been written with a PENDING table
  that named, per decision, the default assumed and the slices that change.
  A1 was answered differently from the default, and the table said exactly
  what that touches: S9 shrinks to `Exit` plus the crash reporter.

## 2026-09-20 02:55 CEST — The browser design pass: reports 24–26 and the owner's sheet

**What I did**

The owner un-parked RESEARCH only ("Let's do 1"): what is a beni browser program, now that beni is
browser-first and an effectful call is just a call? No code changed; implementation stays parked.

- Vendored `references/elm-browser` and `references/elm-virtual-dom` (shallow, `657aa7b`), then ran
  three docs-only Opus researchers in parallel, one new file each, none committing:
  **24** Elm's browser runtime as built (`0ebdce5`), **25** the UI architecture design space
  (`d5c04c0`), **26** the browser as a host, measured in headless Chrome 153 with Firefox 156 as a
  second engine (`3302367`).
- Validated each before committing. 25: spot-checked five citations against the clones (TCA's
  prefix-path cancellation, Solid's promise-identity discard, Leptos's `ScopedFuture`, `elm/http`'s
  `cancel`, effect-atom's `interruptUnsafe`) — all hold. 24: `VirtualDom.js:674`, the line counts,
  the absence of `try`/`catch` in `Scheduler.js`, and the size figures re-measured from the built
  artifacts (109 530 raw / 22 722 brotli). 26: re-ran `e3b` (microtask-64 p50 358 / max 638 ms, never
  64 / 346, `MessageChannel` 0 / 1 at every budget) and `e8` (4G 1 056 / 357 / 703 ms, fast 3G
  3 437 / 1 156 / 2 281) on a quiet machine (load 0.08): both reproduce.
- A fourth agent wrote the synthesis: `plans/browser-decisions.md` (W1–W24, nine in tier 1, each
  answerable without reading the reports) and `plans/browser-platform.md` (worked program + test,
  kernel, slices B0–B9, output track O1–O3, edits owed to normative documents, whole-project
  sequence). I parse-checked its two beni examples with the compiler: clean once the proposed `sync`
  keyword is stripped and one `[ ... ]` elision is filled.
- `plans/queue.md` rows B-R1..B-P marked done; `plans/resume.md` §0 rewritten as the resume point.

**What I learned**

- **`sync` on `update` is a concurrency proof, not a boundary check.** A suspension point is the only
  place another fiber can interleave, so a `sync` `update` applies every message atomically. Elm has
  that for free because JavaScript cannot suspend a stack; beni will be able to, so it must be bought,
  and A6 already bought it. This is the argument for TEA-with-fibers and against an effectful
  `update`, and no document stated it before report 25.
- **A microtask yield is worse than no yield** for input latency (p50 371 vs 84 ms), and a macrotask
  hop costs only 2–4 µs. P2 §7.5's microtask tier should be withdrawn, not tuned; report 21's Node op
  budget of 512 does not transfer; the browser default is `MessageChannel` on a ~1 ms TIME slice.
- **A measurement overturned a document**: Elm's docs (and report 24, quoting them) say user-gesture
  capabilities die when work leaves the handler's tick; report 26 measured `window.open` surviving a
  4.9 s macrotask hop. Running the three reports in parallel and then cross-reading them in a
  synthesis is what caught it — the synthesis found six joins/disagreements no single report saw,
  including a re-entrancy hazard (a `sync` `send` re-entering the dispatcher) that Elm guards with a
  nineteen-line comment.
- "Fatal" has no browser mechanism: an uncaught throw kills nothing in either engine, so A1 needs a
  page meaning the platform implements (W2), and A8 has only a Node half (W9).
- One bundle reaches `main` 3.0× faster than 13 modules on 4G and fast 3G (round-trip depth, not
  bytes; HTTP/1.1 caveat), and 71.6 % of shipped bytes are unminified sibling `.js`. The single-file
  `--release` bundle is the recommended first slice when the owner un-parks: it needs no decision.
- Process: two researchers ran 25–60 % over their line budgets and said so; the content justified it.
  An early, flawed version of an experiment script (`e3`) was left beside the corrected one (`e3b`) —
  my first re-run hit the wrong one and "contradicted" the report. Re-run the script the report names.

## 2026-09-20 12:25 CEST — JSX and Solid's speed: reports 27–29, and the decision sheet revised

**What I did**

The owner read the browser design pass and changed the requirement: **"I want built in JSX in the
language. Also, clone and research SolidJS 2. I want a Beni UI to be fast, as fast as solid, the
runtime cannot be a limitation."** Still research only; implementation stays parked; no code changed.

- Recorded the direction in `plans/queue.md` (it withdrew W1, W4, W5, W6, W10 as written) and in
  memory; vendored `references/solid` (`next`, 2.0.0-rc.9, signals core in-tree) and
  `references/dom-expressions` (`4b29ac9`).
- Three parallel Opus researchers, one file each: **27** Solid 2 as built (`62c7108`), **28** JSX in
  beni (`2271159`), **29** rendering strategies measured (`740dd40`).
- Validation. 28: ran the binary — `<` at operand start is a syntax error today, `f a <b` parses as a
  comparison, `...` is two INVALID CHARACTERs; Mint and ReScript citations hold. 27: the uibench
  96/96 quote and the module-level tracking variables check out; `split2.mjs` and `refeq.mjs` re-run
  (3.2 ms of 21–23 ms for 1 000 rows; 9.8 µs to walk 10 000 rows) — reproduce. 29: read the P2/P3
  prototypes (mechanical, compiler-plausible), re-ran the seven-subject core for ten minutes on a
  quiet machine: **the ranking and per-op script medians reproduce; the headline "P3 equals vanilla's
  script cost (0.989)" does not (1.260)**. I put a validation note at the top of the report rather
  than let the claim travel.
- A fourth agent revised the synthesis: `plans/browser-decisions.md` rev 2 (W1–W45, withdrawn ids
  kept in place, seventeen tier-1 questions, a direct answer to the owner's three sentences) and
  `plans/browser-platform.md` rev 2 (JSX worked program, template renderer, language / rendering /
  core tracks, experiment X1). Queue, resume point and memory updated.
- The synthesis agent found a **compiler defect** while parse-checking its example; I reproduced it:
  `Ok ()` / `Just ()` patterns are reported as missing and a valid program is rejected. Queue row 56.
  Not fixed — parked — but it blocks `Result e ()`, so it is first when implementation resumes.

**What I learned**

- **The first synthesis recommended the right programming model on an unexamined assumption.** Report
  25 assumed a virtual DOM while listing "whether beni has one" as undetermined; the owner's one
  sentence exposed it. Measured, a vdom is the slowest sensible design (146× a template per message on
  a static-heavy page), and TEA survives *because* it was re-tested, not because it was assumed.
- **Solid's speed is mostly its compiler, not its signals** — templates, compile-time hole paths,
  delegation — and all of that is available to TEA. beni's immutability is what makes it cheap:
  a record update is a spread, so an unchanged row is the same object and `===` means deeply
  unchanged. That makes field identity LOAD-BEARING: it must become a written promise in
  `language.md` that constrains the optimiser forever (W27).
- **A geometric mean of ratios over sub-millisecond operations is not a reproducible number.** One
  op (vanilla's `swap`, 0.10 vs 0.57 ms) moved the headline by 20 %. Orderings and per-op medians
  reproduce; parity claims built on geo-means of tiny numbers do not. Re-running is what caught it.
- Report 25's "signals need a fourth fiber slot" was wrong: Solid's observer is a module variable
  restored synchronously, correct whenever tracked code is `sync`. So signals are possible as a
  library, buy no speed (P4 = Solid 2 at 12× the bytes), and rule 7 says: unshipped, never forbidden.
- JSX is cheap in beni for reasons beni already has: `<` is never prefix, shadowing is an error,
  strings already interpolate. Quoted text children remove the lexer mode AND make the formatter
  meaning-preserving by construction. The one real conflict is `f a <b`.
- The open technical question is W29: reports 28 ("`Html msg` is an ordinary value; recognise
  templates structurally") and 29 (prototypes that never build a tree) only meet if the recogniser
  sees the whole path to every hole — and an idiomatic view breaks that at every helper call. Two
  researchers working in parallel each assumed the other's half; only the cross-read found it.
- `dump --stage=ast` only parses. Two reports claimed their examples were "checked" with it and one
  shadowed `Basics.e`. Examples in a spec should go through `beni check`.
- beni's `List` has no indexed read: a capability gap (rule 7), not a speed problem.

## 2026-09-20 13:20 CEST — `Ok ()` was a missing pattern: one absolute index hard-coded to 0

**What I did**

The owner un-parked one fix — queue row 56, found during the browser synthesis — with the instruction
"red black box test before". One Opus implementer in a worktree; I validated and committed (`b160152`).

- The defect: `case m of Just () -> …; Nothing -> …` was rejected with MISSING PATTERNS `Just ()`, and
  the mirror image — `Just ()` then `Just _` — was NOT reported redundant.
- Root cause, `src/check/Exhaustive.zig`: a `Ctor`'s `alt` is an absolute index into `pats.alts`. Every
  arm computes it as `unionAt(un).alts_start + k`; `.pat_unit` alone wrote the literal `0`. That is
  right only when the unit union is the first one interned — a bare `()` or a top-level tuple — and
  wrong under any constructor, list or parameter pattern, where `0` names an alternative of `Maybe`.
  One arm changed; the `Flat` fast path never read it. `checker.md` §6.6 gained one sentence.
- Fixtures written and seen RED before any `src/` change: `run/UnitSubPattern` (18 printed lines —
  `Just ()`, `Ok ()`, unit in tuples, multi-field constructors, nested twice, lists, irrefutable
  parameter / `let` / lambda positions, a lookup table for the fast path) and
  `check/bad/RedundantPatternUnitArg`; `check/bad/MissingPatternsUnitArg` guards over-correction.
- My validation: reversed the `src` patch in the worktree, rebuilt, ran `test-blackbox` — exactly
  those two fixtures fail and nothing else; re-applied; three gates green; my original repro exits 0.

**What I learned**

- The bug hid for the whole life of the checker because the two obvious tests of `()` — a bare
  `case u of ()` and `( (), n )` — are precisely the two shapes where the wrong constant is right by
  luck. A fixture for a leaf pattern should always also put it UNDER something.
- It was found by a docs agent running `beni check` on a worked example for a plan. Examples in
  specs, compiled, keep finding real defects (the 305 doc examples did the same); `dump --stage=ast`
  would not have — it only parses.
- A false rejection breaks no guarantee, which is why nothing screamed; but `Result e ()` is the
  shape of every effect that can fail, so it would have been the first thing anyone hit in effects
  or browser work.

## 2026-09-20 19:20 CEST — Two Ryan Carniato streams filed under `references/talks/`

**What I did**

The owner dropped two YouTube transcript pastes (Solid's author; 5 h 16 m and 5 h 05 m, ~85 000
words of auto-captions together) and asked for them to be formatted, organised and stored in the
references. One Opus agent each; I validated and committed (`23f72f1`, and this commit).

- New convention, `references/talks/<year>-<speaker>-<title>/`: `raw.txt` (byte-identical paste),
  `transcript.md` (chapters, time-linked paragraphs, light corrections, `[?]` for the unresolved, an
  appendix of every correction), `notes.md` (thesis, chapter arguments, topic index, "what this means
  for beni" tied to W ids, his claims separated from our inference). `README.md` is the index;
  `CLAUDE.md` References now points at it.
- The mechanical part is a script: the glued timestamps (`3:083 minutes, 8 seconds…`) are split by
  regenerating YouTube's spoken-out form and asserting it on every line — 0 failures in 2 242 and
  2 153 lines — and the word count is conserved exactly before the editorial pass (44 457; 40 486).
- Validation: checksums of both `raw.txt`, no leaked tool markup, and passages compared against the
  raw captions (the Elm answer at 2:25:57; "SSR is a toggle" at 28:05; 5:00:06).
- When the second paste arrived under the same filename while the first agent was running, I moved
  it to `references/talks/_incoming/` first and told the second agent what it may read and must not
  write; the shared README row came back in its report and I merged it.

**What I learned**

- Both talks press on the same two places in beni's browser plan. **Local state**: "MVC in stateless
  is lovely; MVC in stateful is a disaster", and Redux is "too simple" — the one-model cell is what he
  argues against, and ephemeral UI state needs somewhere to live. This is the owner's live question
  (Elm has no components), and an argument for designing narrow widget-local state.
  **Server rendering**: his whole taxonomy (SPA / server components and islands / stateful servers)
  puts beni-as-planned in the SPA bucket's worst cell for first load; beni has no SSR, hydration,
  routing or data-loading design at all. He also says SSR is "a toggle" on an SPA, and that the real
  fix needs one language on both sides compiling to JavaScript — which beni is.
- Supporting evidence for the current direction: his case against diffing is a case against
  memoisation-by-hand (so W29's seam must never make a programmer reach for it); "compilers have
  limits on the scope they can analyze" (against inline-everything; and an SVG-namespace question
  nobody wrote down); template bytes, not runtime bytes, are what grows.
- Auto-captions are evidence of what was argued, not of what was said: 84 and 159 `[?]` remain, and
  the header of each transcript tells the reader to quote from the video.

## 2026-09-20 21:16 CEST — a `hackernews` skill: search and retrieve HN threads

**What I did**

- Read `references/talks/` end to end — both `notes.md` and both auto-caption `transcript.md`,
  about 85 000 words — after the owner asked for the talks in depth. No repo change from the
  reading itself; the argument and the beni-facing readings were already captured by the session
  that landed them.
- Built `.claude/skills/hackernews/`, modelled on `roc-zulip`: `SKILL.md` plus three fish scripts
  and two support files in `scripts/`.
  - `hn-search.fish` — full-text over stories or comments, with `--type`, `--by-date`,
    `--min-points`, `--min-comments`, `--after`/`--before`, `--author`, `--story`, `--in`,
    `--loose`, `--json`.
  - `hn-item.fish` — a story plus its entire comment tree, or a comment plus its replies, with
    `--depth`/`--top`, `--limit`, `--grep`, `--width`; accepts a pasted `item?id=` URL.
  - `hn-url.fish` — the HN discussion(s) of an article URL, ordered by comment count.
  - `_common.fish` (request, retry, error shapes, date→epoch, the exact-phrase rule) and `hn.jq`
    (HTML cleaning, wrapping, tree flattening, output formats).
- Registered it in CLAUDE.md's Skills paragraph, next to `roc-zulip`.
- Verified every flag and every error path against the live API, and fixed two bugs found that way:
  `--in title` sent a non-searchable attribute and errored, and an author- or story-only search
  printed an empty header.

**What I learned**

- **Algolia's typo tolerance makes an unquoted HN query useless.** `query=elm&tags=story` returns
  5 496 hits, matching `Elon` and any URL containing the letters; `query="elm"` returns 1 087 real
  ones. Relevance ranking hides this on `/search` and exposes it completely on `/search_by_date`,
  so a chronological search that looks like noise is a quoting bug. The scripts quote by default
  and `--loose` opts out. `restrictSearchableAttributes=title` is *not* a substitute — it still
  returns 75 479 hits, because the typo match happens inside the title too.
- Only `title`, `url`, `author`, `story_text` and `comment_text` are searchable. `story_title` is
  returned on every comment record but is not indexed, and naming it is an API error — returned and
  indexed are different sets.
- **Comments carry no score** (`points` is always null, because HN does not publish them), so no
  comment can honestly be described as highly upvoted. Any result set caps at 1 000 hits however
  you page, while `nbHits` still reports the true total; date windows are the only way past it.
- `/items/<id>` returns a whole nested tree in one request, at any size, and works on comment ids
  too — so reading a 432-comment thread is one call, not a crawl.
- A popular article has many submissions and almost all are dead: "Why I'm Leaving Elm" has four,
  drawing 432, 87, 55 and 0 comments. Sorting by comment count is what makes `hn-url.fish` useful
  rather than merely correct.
- Putting every regex in `hn.jq` and loading it with `jq -L` avoids the fish→JSON→jq triple
  escaping that `roc-zulip/scripts/_common.fish` carries a warning comment about.

## 2026-09-20 21:36 CEST — report 30: what Elm's users complained about, 2011–2026

**What I did**

- Built a corpus with the new `hackernews` skill: searched `"elm"` as an exact phrase, took the
  first five pages of relevance-ranked stories (100), kept the **80 with ≥ 20 comments**, and
  downloaded every comment tree in full — **7 285 comments, 2 776 distinct commenters, 2011–2026**.
- Fanned out **8 agents** over byte-balanced ~450 KB shards, each reading its shard in full against
  a fixed schema (distinct-commenter counts, date ranges, verbatim quotes with ids,
  production-vs-speculation flags, and the counter-case). Ran a mechanical term-frequency pass over
  all 7 285 comments separately, so the frequency table is measured rather than inferred from eight
  partial views.
- **Spot-checked 38 load-bearing quotes against the source. Every id, author, date and wording
  matched exactly, in all eight shards.**
- Wrote [`docs/design/research/30-elm-complaints-on-hackernews.md`](../docs/design/research/30-elm-complaints-on-hackernews.md).

**What I learned**

- **The premise of the question did not survive the data.** Counting distinct commenters:
  ecosystem 480, governance 234, ports/interop 188, forks 141, "dead" 119, type classes 108,
  0.19 breakage 97, boilerplate 77 — and **centralized state, named explicitly, 20**. People left
  Elm over interop, governance and ecosystem, not over TEA. Three of eight agents opened with an
  unprompted caveat that their threads were thin on the state question.
- **Where the state pain does show up, it attaches to `Msg`, not to `Model`** — "The Model for that
  is pretty straightforward. It's just a tree of data. The Msg for that is what is being complained
  about" (phamilton, #12076766). That relocates beni's open question: the tractable design target is
  letting a subtree own a message type without every ancestor naming it, *not* adding local state.
- **Two mechanical findings, not ergonomics.** (1) The message queue can silently drop a message,
  because the delay between issuing and `update` is undefined — and the idiom people reach for to
  cut `Msg` boilerplate (a coarse `SetModel`) is exactly the unsound one (dwohnitmok, #25098676).
  (2) A whole-model rebuild destroys the reference identity `Html.Lazy` tests on, making it
  "worthless" (Existenceblinks, #28223910) — which is the exact failure W27 exists to prevent, so
  the corpus is evidence that beni's identity promise is load-bearing rather than theoretical.
- **Four complaints beni already answers by construction**: privileged `comparable` (static
  dispatch removes the caste), `Int` is a double (`core/Int32` shipped for that reason), the `lazy`
  identity cliff (W27), and the `foreign` wall (rule 7) — where the escape valves users asked for
  are rule 7's exact shape, "a scary compilation warning… like `unsafe` in Rust".
- **One finding that could change `boundary.md`:** a production user gets synchronous, type-safe FFI
  by encoding/decoding through a prototype hack and argues "it's still safe FFI!" — i.e. the safety
  came from the **serialisation boundary, not the asynchrony** (1-more, #48806400). If that holds, a
  synchronous codec-checked `foreign` closes the `Intl`-shaped gap without weakening a guarantee.
- **Costs get pushed out of the program**, which is the strongest evidence that centralization has a
  real price: one compiled build per language to avoid threading i18n through the model (#19302138),
  a JS code generator emitting `main.elm` (#13620638), an 800-line diff to display a timezone
  (#26865296).
- **I got a number wrong and caught it in review.** I wrote that SSR appears "from perhaps five
  commenters"; the measured figure is 28 distinct authors. The direction held — it is still an
  order of magnitude below interop and governance — but the figure was invented rather than counted,
  in a report whose whole standard is that figures get counted. Corrected before commit. Count it,
  then write it.

## 2026-09-20 23:12 CEST — report 31: derived codecs

**What I did**

- Wrote [`docs/design/research/31-derived-codecs.md`](../docs/design/research/31-derived-codecs.md),
  assembling the evidence for `fast-compiler.md`'s undecided standing recommendation from report 18
  ("decide structural codec derivation separately, needing no dispatch at all"). The report lays out
  the design space and the open questions; it deliberately does not take the decision.
- Sources: beni's own documents; the report 30 HN corpus for cost evidence; **Roc's Zulip via the
  `roc-zulip` skill**; Effect v4's `Schema` as vendored. Found `references/roc` and
  `references/zig` are **uninitialised submodules**, so no Roc source was readable — every Roc
  claim is chat-sourced and flagged as such.

**What I learned**

- **Roc moved encode/decode off abilities and onto static dispatch with auto-derivation** — "Just
  not abilities anymore" (Brendan Hansknecht, #ideas › Encode/Decode, 2025-12-29, 565607409).
  Report 18 recommended deciding codec derivation *without* dispatch; the peer project beni's static
  dispatch is modelled on did the opposite. The recommendation's premise now has a counterexample and
  should not be carried forward unexamined.
- **Roc's derivation is opt-in per type**, written in the declaration as `encoder_for : _` /
  `parser_for : _` (Richard Feldman, 2026-07-26, 612853585) — not structural-by-default. Records,
  lists, tuples and tag unions derive; derivation lags equality.
- **Derivation broke on exactly the construct beni's capability roadmap depends on.** Roc derived
  for an opaque over a record but not over a primitive — the validated-newtype case — and it
  *panicked* (613054979); Feldman called it a bug. `boundary.md` §6 makes `Intl` first precisely
  because it "establishes the validated-newtype pattern that every later capability reuses". A
  second question neither thread settles: a derived decoder for a validated newtype must re-run the
  smart constructor or it manufactures values violating the invariant.
- **Derivation creates a new class of type error and it must be a diagnostic, not a panic.** Roc's
  float case was resolved by closing it "at the checker … instead of panicking" (614066861). beni's
  `Int` is a double, so the same question arrives immediately at 2⁵³.
- **Derived-versus-hand-written is a false dichotomy.** Effect's `Schema` is one declaration
  yielding both directions plus JSON Schema, with **2 100 lines of `SchemaTransformation`** for the
  shape-mismatch case that is Elm's whole defence of hand-written decoders. The third option is a
  declared bidirectional description, and it is the only one of the three that makes the round-trip
  law checkable.
- **The rule-7 case is the guarantee, not the keystrokes.** A hand-written encoder/decoder pair has
  nothing checking that `decode (encode x) == x`. That is the justification that survives the
  1:1-shape objection; "code the compiler could be writing" does not.
- Corpus finding worth keeping: the JSON complaint peaked in 2017 and faded, but **codegen-as-the-
  answer is the only sub-theme that grew after 0.19** — the demand was met outside the language, by
  every team separately. Same pattern as i18n builds and generated `main` in report 30 §3.9.

## 2026-09-21 21:25 CEST — schemas: from "derived codecs" to a `schema` declaration at Effect parity

**What I did**

A design conversation with the owner, starting from report 31 (another session's) and ending in a
decided model. No code changed. One research agent, docs only, resumed once.

- The owner set the bar — "as powerful as Effect schemas" — and then corrected my first three
  proposals in turn: deriving a schema FROM a type is not enough ("there are two different types for
  the same schema… most real life schemas have different representations"); new syntax is wanted;
  and "we are defining a schema User, not a type User". Decided: `schema User = { … }` defines a
  schema; its types are reached through it as **`User.Type` / `User.Encoded`**; **no shorthand**.
  Recorded in `plans/queue.md` and memory.
- A quick family-only web survey (Elm, Gren, Lamdera, Gleam, Roc, Mint, Derw, Grain, plus
  rescript-schema and Thoth; no powerful type systems, no code generation — the owner's scope, after
  they stopped my first, too-broad brief): two camps — write reader and writer by hand (Elm, Gleam),
  or the compiler does it and cannot express a rename or a default (Roc, Mint, Lamdera); elm-codec
  and rescript-schema in between; nobody has one declaration giving both types and both directions.
- **Report 32** (`78e58b0`, revision 2 `e687c93`), designed from Effect's `SCHEMA.md` docs only:
  164 capabilities answered (same 43, different 67, not needed 38, cannot 14 — ten of them
  pick / omit / partial, a type computed from a type — help 2); `Schema e a` carries both sides;
  a field position holds a SCHEMA, so `via` names the wire side (`createdAt : Int via Date.millis`);
  a tagged union's `Encoded` is a flattened record; the schema is used as `User.parse` or passed as
  `User.schema ()`. K1–K16; K13–K16 await the owner.
- Validation: the agent's check projects re-run (exit 0); namespace claims verified with the binary
  (`User.Type` resolves as a qualified type; a Capitalised name in expression position is always a
  constructor); parity rows spot-checked against `SCHEMA.md`.
- **The report found a real compiler defect and I reproduced it — queue row 57**: an annotated
  top-level value with a `where` clause and no parameters builds with exit 0 and the program then
  throws `TypeError` at run time. NOT fixed; the owner has not yet said to.
- Committed the other session's work with this one at the owner's word: reports 30 and 31, the
  `hackernews` skill, its `CLAUDE.md` line and its diary entries.
- Answered two language questions from the docs and `core/`: beni has no `comparable` (static
  dispatch replaced it; any type can be a `Dict` key), and no arrays, so no bounds checks — every
  lookup returns `Maybe` or clamps; W35's `Array` would return `Maybe` on `get`.

**What I learned**

- **My vocabulary was the obstacle, twice.** "Codec", "derivation", "dispatch", "round-trip" made the
  first explanation unreadable; then "what the compiler generates", shown as source, read as code
  generation. What worked: one `User` and its JSON, and the two lists "what you write" / "what you
  can then refer to".
- The owner's model was better than mine each time it differed. "The schema is the thing" removed
  the invented `UserWire` name and the implicit type, and forced the two-parameter `Schema` that
  makes `Encoded` usable. Offer the sketch, then listen for the noun the owner uses.
- "No new syntax needed" was wrong, and the report's unargued "needs syntax" was right for a reason
  it did not give: without computing a type from a value, ONE text yielding TWO types is only
  possible if the compiler reads the declaration.
- Asking a design agent to verify grammar claims with the binary paid again: it is how the defect in
  row 57 surfaced, and how `Schema.parse User text` was ruled out before anyone got attached to it.
- A brief that is too broad gets stopped. The owner's four-line scope produced a better survey in
  2.5 minutes than my 40-line one would have in fifteen.

## 2026-09-21 22:03 CEST — the flake had one system, and macOS folds `main.mjs` onto `Main.mjs`

**What I did**

- `flake.nix` named a single `system = "x86_64-linux"`, so the first checkout on an
  aarch64-darwin machine got *no* devShell at all and direnv fell back to the ambient
  environment — which had a `zig` from `~/.nix-profile` but no `node`, so gate 2 could
  not have run even in principle. Rewrote it with a `systems` list and a `forAllSystems`
  helper over `nixpkgs.lib.genAttrs`; the package list, the comments and the `shellHook`
  are untouched. The shell builds on darwin from the public cache alone:
  `zig 0.16.0 · node v24.19.0 · zls 0.16.0 · jq 1.8.2`.
- Ran the three gates on darwin. `fmt-check` and `test` pass. **`test-blackbox` fails,
  31 of 277**, and the cause is one defect, not thirty-one.

**What I learned**

- `src/js/Emit.zig:1371` hardcodes the entry file as `out/main.mjs`, and the conventional
  entry module `Main.beni` emits `out/Main.mjs` into the same directory. **APFS is
  case-insensitive by default**, so the two are one file: whichever is written second
  wins, and here the shim wins. The surviving `out/Main.mjs` is the shim, whose
  `import { Main$main } from "./Main.mjs"` now resolves to *itself* —
  `SyntaxError: does not provide an export named 'Main$main'`, exit 1. Every failing
  test is downstream of that: 14 `expected 0, found 1`, 9 golden-output mismatches, the
  `Debug.todo` message, and the platform's exit code 3 arriving as 1.
- The harness has the same hazard from the other side: `build_test.zig:1684` asserts
  `!w.exists("out/main.mjs")` to prove `--library` writes no entry file, and on a
  case-insensitive filesystem a perfectly correct `Main.mjs` makes that assertion lie.
- §5.2 says "the platform declares this … rather than hardcoding one", and the entry
  file's NAME is the one part of the output shape that is still hardcoded in the emitter.
  A fix that moves the name into `platforms/node/beni.json` would be §5.2 being finished
  rather than amended — but it is a spec change and the owner's call, so nothing is
  changed here beyond the flake.
- A separate, non-blocking observation: `abuse_test`'s "5 000 empty modules produce
  identical output" hit the harness's 60 s `CompilerTimeout` on this machine. Not
  investigated; it may be nothing more than a cold `.zig-cache` and a first run.

## 2026-09-21 23:01 CEST — queue row 58: the reserved output names begin with `_`

**What I did**

Spec first, red tests second, code third — and the order paid, because writing
§2 is what turned "rename `main.mjs`" into two rules with a guarantee over them.

- **`backend.md` §2** gained *The output tree does not depend on the file
  system's case sensitivity*: the guarantee is **a build's output is the same
  set of files on every file system**. Rule 1 — every reserved output name
  begins with `_` (`_main.mjs`, `_core/`, `_platform/`), which no module path
  can reach because every segment is an upper identifier. Rule 2 —
  `output_path_collision`, two written paths equal under ASCII case folding,
  checked over everything produced before the first byte is written. §5, §9 and
  §10's mentions of the old names moved with them; no section was renumbered.
- **`boundary.md` §5/§5.2** gained the `"entry"` manifest key, which finishes
  §5.2's own "declares … rather than hardcoding" for the one part of the output
  shape the emitter still owned — constrained by rule 1 and checked when the
  platform loads, `invalid_entry_file` otherwise.
- **`language.md` §10** gained both codes at the end of the catalogue. Its
  positional row labels ("the second-from-last line", …) were already drifting
  before I added two more, so they are now correct as well as stable.
- Red first, and the corpus fixtures with `_expected.diag` of `[]` so the
  failure was "the build exited 0", not a missing golden. With the behaviour
  reversed and the two new enum members kept, **36 of 280 fail**; with it
  applied, 279/280. The one is queue row 59, below.
- The `emit/` and `emit/release/` goldens were re-blessed and the diff **is
  paths only** — proved rather than eyeballed: rewrite `./_core/` → `./core/`
  and `./_platform/` → `./platform/` on the added side, sort both sides, diff,
  empty.

**What I learned**

- **The fixture the rule is really for cannot exist.** Rule 2's headline case is
  two modules `Json.Decode` and `JSON.Decode`, and a corpus fixture for it needs
  two source files that are themselves one file on macOS — the repository would
  not survive a checkout there. So the collision is provoked instead by a
  platform whose sibling and whose runtime land on the same output name
  (`platform/Prog.js` and `platform/js/PROG.js`, two source paths differing by
  more than case), and the real backstop is a harness invariant: after **every**
  build the black-box suite makes, fold the written-file list and fail on a
  duplicate. That one would have caught row 58 on Linux, where the file system
  hides it, and it costs one directory listing per case. It is the test I would
  keep if I could keep only one.
- **A defect is invisible exactly where it bites.** On APFS the two colliding
  files have already collapsed into one, so `listFiles` sees nothing wrong and
  only the emitted program misbehaves; on Linux both are there and nothing
  misbehaves. Neither side can see the whole thing, which is why this survived
  every green run until someone built on a Mac.
- **Moving a name into a manifest is not the same as making it safe.** The
  obvious fix — let the platform declare the entry file — would have let a
  platform author write `"entry": "main.mjs"` and reintroduce the defect in
  data. The key was only worth adding once the rule was enforced on it, which is
  the owner's decision restated: the guarantee, not the convention.
- The `abuse_test` 60 s timeout is **not** a compiler problem. Five warm runs of
  `check --jobs=1` over 5 000 empty modules: 12.05, 24.29, 26.11, 59.16, 61.16 s
  — while the default-jobs run beside it is 6.00, 6.00, 6.08. Identical,
  deterministic work, and USER cpu varies 6.77–16.22 s, which is a single thread
  landing on an efficiency core rather than a performance one. A wall-clock
  deadline cannot separate that from a hang on this hardware. Recorded as row
  59; the timeout was not touched, because the instruction was a number first.
  Frequency, since a flake needs one: `test-blackbox` was green on **3 of 4**
  consecutive full runs of the finished branch, red on the fourth, always this
  one case.
- A second thing fell out of measuring: `CLAUDE.md`'s `--release` figures are
  stale by ~1.9 kB against today's binary (row 60). The −31% claim is fine; the
  absolutes were recorded at an earlier commit. Left alone deliberately — the
  fix is one re-measurement of that whole paragraph, not patching the two
  numbers I happened to check.
- **Not run on Linux.** Everything here is darwin. The three gates are owed on
  the owner's NixOS machine, and the harness invariant is the part most likely
  to have something to say there.

## 2026-09-22 00:48 CEST — schema readiness review and reference checkout

**What I did**

- Read report 32 revision 2, its predecessor and owner decisions, and cross-checked
  the relevant language, frontend, checker, backend, boundary, static-dispatch,
  incrementality, effects and browser contracts. This was a design review, not an
  implementation session; existing compiler and test edits were left alone.
- At the owner's request, ran `git submodule update --init --recursive --jobs 8`.
  All nine reference submodules checked out their recorded commits. Read the pinned
  Effect schema guide, its flip/projection implementation and arbitrary-generation
  limitations after checkout.
- Checked JSON numeric loss with Node: `9007199254740991.1` parses to the safe
  integer `9007199254740991`; `1e400` parses to Infinity; NaN stringifies as null.
  No compiler tests or schema performance measurements were run.

**What I learned**

- The owner model is settled, but report 32 is not implementation-ready. Unrestricted
  flipping contradicts a fallible decoder plus an infallible encoder. `typeOnly`
  also needs program-side representation information the proposed Schema does not
  retain. Effect retains both sides and allows failure in either direction.
- Generic selection by `a.schema` loses structural record aliases' schema identity,
  cannot select two wire forms for the same program type, and needs a namespace
  ownership rule. Generic convenience signatures also encounter the existing rule
  that every constraint variable must occur in the annotated type.
- Arbitrary wire keys cannot all become ordinary record field names; flattened
  union records reject legitimate variants sharing a key at different types.
  Recursive schemas with transformed fields need an encoded recursive type beyond
  the identity example. Opaque schemas need an explicit account of their private
  representation and constructor.
- The proposed reader representation does not thread options/path/depth; the
  erased Variant omits structural readers/writers needed by choice. Node loses
  recursive targets, literal values and structured checks. Unconditionally
  successful sampling cannot handle an always-false check. These need executable
  library proofs, not just signatures that type-check.
- Lowering is per-file and cannot inspect an imported conversion's type as claimed.
  Schema/Json ownership must also avoid an import cycle. JSON precision must be
  addressed before token text is lost, and total writing needs rules for values
  admitted by Int/Float but refused by the reader or JSON.
- Recommended next work: settle encoding failure, generic schema selection,
  namespace ownership and wire-presence/union representation; prove a small
  library prototype with adversarial cases; measure browser behavior; then update
  normative contracts and define acceptance fixtures before production slices.

## 2026-09-22 00:56 CEST — schema decisions: failure, composition and imports

**What I did**

- Recorded the owner's three accepted decisions in `plans/queue.md`: encoding may
  fail with `Result`; generic schemas receive explicit schema arguments; multiple
  schemas may live in one module, reachable through full qualification or explicit
  exposure of the schema name.
- Added a notice to report 32 marking conflicting revision-2 recommendations as
  superseded. A full specification revision remains owed; no implementation changed.

**What I learned**

- A schema's imported name keeps its members qualified: exposing `User` does not
  expose bare `Type` or `parse`. Ordinary import behavior matters to the owner;
  these decisions do not request a general-purpose namespace feature.
- Fallible encoding and explicit schema arguments resolve two central design
  conflicts. Wire presence, arbitrary keys and union representations remain open.

## 2026-09-22 00:58 CEST — schema presence follows Effect

**What I did**

- Recorded the owner's acceptance of Effect's separate optionality and nullability
  model in the queue and report 32's supersession notice. Missing/null/value remain
  distinct unless an explicit transformation merges them. No implementation changed.

**What I learned**

- The convenient default is composable presence and nullability, not an automatic
  merge into `Nothing`. Beni's syntax and presence types still need specification;
  following these semantics does not require adding JavaScript `undefined`.

## 2026-09-22 01:00 CEST — encoded tagged unions preserve variants

**What I did**

- Recorded the owner's acceptance of custom unions for a tagged schema's encoded
  side, superseding report 32's flattened-record recommendation. Recorded the
  accepted encoded/program constructor paths in the queue and updated the report's
  supersession notice. Documentation only; no implementation changed.

**What I learned**

- `Message.Encoded.Count` and `Message.Count` keep each side's payload types tied
  to its variant while the codec preserves the declared JSON shape. Variants can
  therefore share a wire key with different types without renaming that key.

## 2026-09-22 01:01 CEST — effectful schema transformations accepted

**What I did**

- Recorded the owner's agreement to support effectful transformations, with a
  synchronous first delivery permitted, in the queue and report 32's update notice.
  No implementation changed.

**What I learned**

- Separating validation and enrichment is a usage recommendation, not a restriction.
  Stored-function effect propagation, suspension and cancellation need investigation
  before committing to the schema representation; the capability decision does not
  itself resolve H4 or commission runtime implementation.

## 2026-09-22 01:04 CEST — schema field names and external keys

**What I did**

- Recorded the owner's agreement that `Type` and `Encoded` retain declared Beni
  field names while `as` maps external keys. Updated the queue and report 32's
  supersession notice. Documentation only; no implementation changed.

**What I learned**

- Arbitrary external keys need no quoted-field language feature: `userId` remains
  the typed field on both sides even when the JSON key is `user-id`. This rule
  applies to all renames, not just keys that are invalid Beni identifiers.

## 2026-09-22 01:03 CEST — queue rows 57 and 59: a thunk where a value belonged, and a bound with a number behind it

**What I did**

- **Row 57**, the last exit-0 path to a runtime exception in the queue.
  `pub blank : List a where a.eq : a, a -> Bool` / `blank = []` built with exit
  0 and threw `TypeError` at load. A reference to a constrained value is its
  eta-expansion (spike A.25), and at beni arity 0 an eta-expansion is a
  **thunk**: `blankInts = () => blank(eq$prim)`, handed to `List.length`, while
  every consumer reads the name as the list it is annotated to be. One branch
  in `Lower.etaExpand` — at arity 0 the expansion is the call. Spec first: §8.1,
  §8.2/A.25 and §10.10 corrected, A.85 appended. `run/ConstrainedConstant` is
  the fixture, and with the branch reversed it is the **only** test that fails.
- **Row 59**, the flaky 60 s bound on the 5 000-module abuse case. Now per-run:
  60 s everywhere, 300 s for the one case whose input is 5 000 files.
- Rows 57 and 59 closed; all three gates green on darwin.

**What I learned**

- **The spec was wrong in two places, and the second one is why nobody caught
  the first.** §8.1 said a zero-parameter constrained declaration is refused by
  the checker "so the backend never meets one". §10.10 explained at length why
  the INFERRED case is refused — and said nothing about the annotated case
  except that this code does not apply to it. Each section was locally coherent;
  the hole was in the space between them, and it is exactly the space the
  emitter walked into. When a document says another phase already handled
  something, that sentence is a claim needing a test, not a fact.
- **Rule 7 settled the fork cleanly, and it was not the smaller diff.** Refusing
  the annotated constant would have been fewer lines than fixing the emitter,
  and it was the wrong answer: both close the same hole, so the refusal buys no
  guarantee and costs `Dict.empty` — a polymorphic constant carrying a
  requirement is a shape anyone would want, and forcing it to grow a dummy
  parameter is the "you should not need that" rule 7 rejects. The test for a
  restriction is what guarantee it buys, and here the answer was *none*.
- **A.25's reason did not say what I first read it as saying.** "A function-typed
  value in flight must be a closure of known arity" is a claim about
  FUNCTION-typed values. A constant is not one, so the closure was never an
  arity fix that happened to be wrong at 0 — it was the emitter writing a type
  error. The giveaway that the fix is right: **no `emit/` golden moved**, because
  every eta-expansion that already existed had arity above zero.
- **I recommended the wrong mechanism for row 59 and had to withdraw it.** Cpu
  time is the right thing to bound, but reading a LIVE child's cpu time needs
  per-pid rusage (`proc_pid_rusage` on macOS, `/proc/<pid>/stat` on Linux),
  neither is in std, and `getrusage(RUSAGE_CHILDREN)` only counts children
  already reaped — it says nothing about the run being bounded. Two non-portable
  syscalls inside a test harness is a worse trade than a per-case wall-clock
  bound. The numbers and that reasoning are in the harness doc comment so the
  next person does not re-derive them.
- **Two sessions were writing this repo at once.** A concurrent session appended
  the 00:48 and 01:01 entries above and the schema decisions in the queue while
  I was fixing rows 57 and 59. Nothing collided — its work is design records, mine
  is code — but I committed my code separately first and left its files alone
  until the owner said to proceed. Worth knowing the diary and the queue are the
  two files where that can bite.
- **Still not run on Linux**, both rows included.

## 2026-09-22 01:05 CEST — Effect as the default for delegated schema decisions

**What I did**

- Recorded the owner's instruction to decide routine schema semantics autonomously
  using Effect as the standard. Checked the pinned numeric implementation and
  recorded safe-integer validation as the baseline in the queue.
- Distinguished the earlier lossless unquoted-JSON-number recommendation from
  Effect's actual default: its JSON getter uses JSON.parse. No implementation changed.

**What I learned**

- Effect's isInt uses Number.isSafeInteger. Its exact large-integer support includes
  BigIntFromString; this does not establish automatic lossless JSON-number parsing.
- The owner wants decisions on routine behavior made from the reference, with
  questions reserved for material departures or unresolved language tradeoffs.

## 2026-09-22 01:19 CEST — Schema prototype with Sol implementation agents

**What I did**

- Wrote the bounded prototype plan before implementation and launched three Sol
  agents for the library, scenarios/effects analysis, and portable boundary/runner.
  Kept production compiler, core and grammar untouched.
- Managed integration and independently reviewed the source. Found and had the
  agents correct nested refinement bypasses, first-error aggregation, unknown-key
  handling and missing depth checks, with executable regression cases.
- Independently ran 50 exact assertions through development/release at jobs 1/8
  under Node 24 and Chrome 153, two whole-diagnostic negative fixtures, output
  determinism and Beni formatting. All passed. The full project test, blackbox
  and formatting gates also passed under the pinned dev shell.
- Captured full results and wrote report 33: release test application 59,394 raw
  bytes / 14,207 concatenated Brotli; the small decode/encode browser batch had
  a 1.2 ms median in both modes. No Effect performance parity claim. No commits.

**What I learned**

- Two explicit endpoints make fallible flip and projections implementable without
  guessing program structure from the wire description. Explicit list schema
  arguments preserve two wire forms for one program type; recursive payload
  conversion and separate presence/nullability work in ordinary Beni.
- A whole-record transformation cannot run after failed structural parsing—also
  true in Effect. Independent field transforms therefore need field-level schema
  composition if their errors must be collected together. The prototype records
  that limit rather than claiming a false parity result.
- Stored synchronous functions in transparent aliases do not settle directional
  effects through an opaque nominal schema. Eager first-error evaluation and
  repeated validation also need a production design, not merely more signatures.
- The actual mixed-union representation boxes Wire.Null in both output modes;
  checking emitted behavior resolved a misleading simplified representation rule.

## 2026-09-22 11:28 CEST — Close the schema prototype as dated research

**What I did**

- Pulled first: the default rebase pull refused the existing uncommitted work;
  `git pull --no-rebase --ff-only` preserved it and reported already up to date.
  Read the plan, report, complete prototype tree and CLAUDE rules 1–5. Reproduced
  the original 50/50 and its exact sizes before changing a file.
- Added three limitation assertions for the tagged reader: fractional payload
  loses its field path, `maxDepth = 0` is ignored, reordered keys are rejected.
  Recorded the unenforced context-ownership gap as report 33 §4's fifth bullet;
  did not change the representation or start its next slice.
- Added a nested recursive-definition probe. It found omission, not duplication:
  only the outer definition survives. Pinned the whole two-sided description
  and recorded this separate defect as queue row 61, without fixing it.
- Changed the malformed-JSON fixture to assert boundary-owned `invalid JSON`.
  Proved it red first (only that assertion failed, other 53 passed), then made
  `Wire.parse` normalize host `SyntaxError` to that message.
- Ran the full Node 24 / Chrome 153 runner: 54/54, both negative fixtures exact,
  deterministic dev/release outputs at jobs 1/8. Committed `results.json` exactly
  as captured. Development 113,935 raw / 17,970 concatenated Brotli; release
  61,696 / 14,541. All three project gates, Beni formatting and staged whitespace
  checks passed. No production `src/`, `core/`, `platforms/` or build file changed;
  even the prototype's `src/Schema.beni` was left untouched during close-out.
- Committed the evidence as `9a8f903`, separately from this report/plan/queue/diary
  close-out commit. The artifact is dated research, not a feature or build gate.
  Left the untracked `.agents` and `AGENTS.md` symlinks out of both commits.

**What I learned**

- A transparent record of arbitrary endpoint functions cannot guarantee context
  threading. Correct library combinators do not make hand-written endpoints
  safe: the interpreter or closed construction must own paths and traversal
  limits. This is a guarantee-shaped reason for the next AST representation.
- The dedupe premise needed checking: `List.append` is in `object2Endpoint`,
  whereas `recursiveEndpoint` publishes a singleton and loses nested definitions.
  No duplicates in this probe does not mean definitions are correct or deduped.
- Pinning complete, deliberately wrong results documents an experiment's limits;
  it is not production conformance. A host engine's syntax-error prose is not a
  stable fixture contract, even when Node and Chrome happen to agree.

## 2026-09-22 12:02 CEST — Compiled schema benchmark subjects

**What I did**

- Implemented strict decode/encode adapters for Ajv, generated Ajv standalone,
  Typia, TypeBox value and compiled modes, ArkType, and the explicitly labelled
  `fast-json-stringify+handwritten-guard` encode-only row. All validate before
  the shared rename mapping; only Typia and FJS use native generated serializers.
- Added committed Ajv standalone output, transformed Typia sources/output, and
  direction-specific flat browser entries that do not root the workload matrix.
  The Typia source uses `validateEquals`, safe-integer tags, and a native custom
  finite-number tag; the emitted proof contains the generated checks.
- Normalized native union diagnostics to the discriminant-selected branch,
  increased TypeBox's native diagnostic cap so that branch is available, and set
  Ajv to first-error work before regenerating its standalone validators.
- Ran the official correctness-only preflight under pinned Node 24: all 13 rows
  loaded and passed. Independently checked every compiled flat entry and built
  each as minified browser ESM; none imported a matrix adapter or Typia's matrix
  proof. I did not run the timed matrix or change production code.

**What I learned**

- Typia 15 deliberately replaced its legacy TypeScript transformer with a native
  `ttsc` plugin. `ts-patch` 4 fails with TypeScript 7 before transformation, and
  invoking Typia 15's plugin through `ts-patch` on TypeScript 6 also fails because
  the expected plugin context is absent. The latest supported candidate therefore
  uses Typia 15 + TypeScript 7 + `ttsc`; whether to substitute the older
  ts-patch-compatible Typia line remains an explicit owner decision.
- A plain Typia `number` and ArkType `number` do not establish the benchmark's
  finite-number contract. Both needed native refinements, and generated output
  had to be inspected to prove `Number.isFinite` was really emitted.
- TypeBox caps native errors at eight by default. A four-branch union can exhaust
  that cap before reporting the branch named by the discriminant, so exact native
  fault paths require raising the cap before filtering the library's own details.

## 2026-09-22 12:09 CEST — Tighten compiled-subject edge contracts

**What I did**

- Corrected the Typia candidate after reviewing its generated strict-object code.
  Enabled the native transform's `finite: true` and `undefined: false` options
  together with TypeScript exact optional properties, then removed the redundant
  custom finite tag and regenerated both matrix and flat proof.
- Typia's key-count fast path only reported the parent when an object contained
  every optional field plus a surplus key. Added a never-valued template index
  signature to the proof types; it accepts no extra value but keeps generated
  `validateEquals` on its native per-key diagnostic path. Verified exact paths
  for ordinary and undefined-valued surplus keys, present optional `undefined`,
  non-finite numbers and the never-prefix itself.
- Corrected CSP metadata after both source inspection and a code-generation-
  disabled process: ArkType selects its jitless evaluator and TypeBox Compile
  selects its interpreted fallback. Recorded the separate Ajv/TypeBox native
  mismatch that a present optional property valued `undefined` is accepted.

**What I learned**

- Typia 15's supported options can meet finite-number and exact optional-presence
  requirements without a hand-written guard. Its generated key-count shortcut is
  nevertheless too lossy for the benchmark's exact fault-path contract; a
  semantically empty dynamic signature is needed to request per-key diagnostics.
- JSON Schema validators commonly treat a known optional property whose value is
  JavaScript `undefined` as absent. That is outside JSON wire data but reachable
  on the encode side, so it is a native contract mismatch to report, not silently
  repair or omit from the evidence.

## 2026-09-22 12:13 CEST — Pin and build schema benchmark sources

**What I did**

- Added shallow source submodules at the resolved release tags for Ajv 8.20.0,
  Typia 15.0.0, TypeBox 1.3.34, ArkType 2.2.3,
  fast-json-stringify 7.0.1, Zod 4.6.5 and Valibot 1.5.0; retained Effect's
  existing 4.0.0-rc.116 pointer unchanged. Recorded tags, commits, dates and
  permanent source links without committing or staging vendored contents.
- Built every subject from its pinned source. Ajv, Typia's native `ttsc` path,
  TypeBox, the topologically ordered ArkType workspace, Zod, Valibot and Effect
  passed; fast-json-stringify has no build step and passed a direct-source smoke
  test. Captured the exact commands and the failed partial attempts that exposed
  package-manager and workspace ordering requirements.
- Added the exact runtime/tooling lock, source-build and wiring scripts,
  provenance JSON and mechanism/CSP notes. The wiring replaces all eight npm
  subjects with source-built submodule artifacts; an audit resolved every public
  entry to those paths, compiled generation passed, and each measured entry has
  a recorded SHA-256.

**What I learned**

- TypeBox 1 is the `typebox` package and exposes `Compile`, not the old
  `@sinclair/typebox` `TypeCompiler`. Its evaluator and ArkType both have CSP
  interpreter fallbacks, while their normal paths generate functions.
- Typia 15 deliberately moved from the legacy Typia 12 / TypeScript 6 /
  `ts-patch` path to TypeScript 7 and `ttsc`. The current source build is slow
  because the native transform can force a full-project recompile, but its
  emitted result needs no runtime code generation.
- Zod 4.6.5 is hybrid: object validation JITs a specialized fast path when
  allowed and otherwise interprets it. Per-parse jitless selects the interpreter
  but does not suppress the earlier capability probe; only global jitless does.

## 2026-09-22 13:00 CEST — Close the compiled-schema evidence

**What I did**

- Completed report 34 from the qualified final capture: four full steady-state
  tables with medians, p10/p90 and net JSON comparisons; flat browser bundle and
  both startup surfaces; blocked-eval outcomes; all raw/group ordering-flip and
  equivalent-work audits; and conditional per-operation ratios to Zod without a
  geometric mean or single-library verdict.
- Registered the result and its limits in the queue. The final capture contains
  nine fresh processes, 4,500 supported timed process-cells and 157,500 retained
  samples. All eight subjects resolve to source-built artifacts; source pointers
  are commit `c5ba612`. No production compiler, core, platform or build file
  changed.
- Preserved the first complete capture as compressed diagnostic evidence, then
  excluded it from conclusions. Review found that four flat-only baseline
  entries retained unrelated branches through generic schema builders, which
  overstated browser bundles and aligned cold imports. After specializing only
  those entry schemas, the entire matrix was captured again rather than splicing
  supplemental size/startup observations into the earlier timings.

**What I learned**

- The 12:09 entry's statement that all 13 rows had loaded and passed was
  premature: it described an intermediate adapter state before final source
  wiring, and later source-wiring checks initially exposed missing Typia native
  plugin content and Effect subpath resolution. Those were repaired before the
  official preflight and final captures; the earlier diary text remains
  append-only and this entry corrects its scope.
- A fast success path says little about failure cost. TypeBox Compile re-enters
  interpreted error production, while early-rejecting generated validators can
  finish before a successful JSON baseline would serialize. Net failure values
  are therefore counterfactual, not validation-only time.
- The hand-written row is an auditable reference, not a physical ceiling. All 65
  contexts that preceded it retained equivalent required work, but native key
  traversal, union dispatch, first-fault order and serializer strategy differ.
  The final run still has 91 pairwise flips between selected groups, so the
  useful result is a set of conditional operation ranges and architectural
  tradeoffs, not a winner.

## 2026-09-22 13:06 CEST — Validate the compiled-schema close-out

**What I did**

- Independently rechecked the final report against the selected capture: the
  four generated timing blocks match byte for byte; every bundle, startup,
  time-to-first-validation, CSP, flip-endpoint, partial-order and Zod-ratio cell
  matches the retained raw observations at the documented rounding.
- Recorded the manager's final validation result: the second complete run of
  `zig build test`, `zig build test-blackbox` and `zig build fmt-check` exited
  zero after the final capture and documentation work.

**What I learned**

- Keeping generated descriptive tables mechanically reproducible and checking
  derived prose claims separately caught the important distinction between an
  unbundled flat-entry import and execution of its tree-shaken browser bundle.
  Both are useful measurements, but they are not the same startup surface.

## 2026-09-22 12:44 CEST — Specialize schema benchmark flat bundles

**What I did**

- Audited the flat-only browser bundle evidence and found that the Zod,
  Valibot and Effect entries executed a generic JSON-Schema-to-native converter,
  retaining unrelated union, array and recursive-schema capabilities.
- Replaced only those flat entry paths, including the Zod jitless control, with
  literal native flat-schema constructors while preserving each subject's
  strictness, numeric checks, optional-field semantics and native error options.
- Left the matrix adapters and generic builders unchanged. The focused Node 24
  preflight passed all 13 rows, source verification passed all eight corrected
  entries, and all 25 browser bundles passed their flat-only and execution
  audits without a generic builder input.

**What I learned**

- Tree shaking cannot remove branches in a schema converter that executes over
  runtime schema data, even when the entry supplies a constant flat schema.
  Its own retained bytes understate the effect because its references also root
  unrelated native-library APIs.
- The correction affects only flat-entry cold startup and browser bundle size;
  steady-state matrix measurements, full-adapter startup and CSP evidence use
  different entry surfaces and are unchanged.

## 2026-09-22 14:09 CEST — Specify schemas and the compilation fork

**What I did**

Pulled first (already up to date), read the schema owner decisions and research
against the existing contracts, and wrote `docs/design/schema.md` as a new
normative delta rather than revising report 32. Recorded the description plus
specialised parse/print fork, the five guarantees, engine-owned context,
namespace/interface elaboration, codegen/DCE, diagnostics, effects obligations
and five slices. Twelve open questions lead the document with recommendations
and costs; their dependent rules remain conditional. Added one pointer each in
language/checker/backend/boundary, appended the diagnostic codes, wired CLAUDE.md
and the queue, and preserved all existing section headings. Replaced positional
labels in the language diagnostic table with code names so appended rows do not
make them false. No production code or benchmark capture changed.

Ran temporary grammar/resolution probes against the installed binary, including
qualified types, explicit schema arguments, contextual words, real-module
constructor patterns, namespace exposure and recursive aliases. Checked local
links and whitespace. `nix develop --command sh -c 'zig build test && zig build
test-blackbox && zig build fmt-check'` passed, exit 0. The existing untracked
`.agents` and `AGENTS.md` are outside the staged set. No measurement run was made.

**What I learned**

Multi-segment qualified names and constructor patterns already work for actual
modules; that proves neither schema namespace exposure nor schema elaboration.
The input schema's Encoded need not equal the intermediate type consumed by a
via conversion, so Q1 now has a concrete conditional signature with an explicit
program endpoint. Context cannot be a convention for arbitrary endpoint authors:
the engine must own it on both compiled and dynamic paths, including mixed paths.
Report 34's size/startup observations support the fork but not a universal speed
ratio; fused-codec and optional Effect-compiler rows remain owed. The effects
plan has no H4 heading, and a separate imported primitive-alias probe rejected a
numeric literal; queue rows 66–68 preserve those findings and the representation
proof still owed. M4 slices 1–3 are already marked done, so the scheduling
question asks where schemas enter the recorded sequence without inventing a
requirement to finish every remaining M4 slice first.

## 2026-09-22 14:22 CEST — Schema contract review decisions

**What I did**

Revised schema.md around the owner's Q1/Q2/Q4/Q5/Q8/Q10 decisions: optional
conversion target checks, the v1 primitive set, ordinary Result failures,
Effect defaults with bounded native recursion, the smaller namespace and
explicit nominal recursion with separate presence/nullability. Made the raw
host representation and direct JsIr validation explicit, removing the implied
Value-ADT marshalling pass. Removed repeated conditional wording, retained the
five outstanding owner questions, and appended A.2/A.3 without renumbering.
Updated CLAUDE and the queue: delegated scheduling puts S1 next, with the
broader numeric-alias defect fixed before S2. No compiler or runtime changes.

**What I learned**

Optional target checks preserve typed projections but do not supply an external
representation for an arbitrary target; Q6 and row 68 retain that S3 obligation.
A 4,096-depth ceiling is not proven safe by choosing native recursion: existing
queue row 39 records another function overflowing near 3,700 calls. New row 69
requires evidence for both paths, helper frames, browsers and caller stack
before shipping; this does not reopen native recursion. Row 67 is confirmed
for local/imported Int and Float aliases and owes fail-first check/good fixtures.
Relative links, stable section numbers, unchanged G1–G5, open-decision IDs and
stale-wording checks passed, as did git diff --check. No measurement runs or
compiler gates rerun for this documentation-only revision.

## 2026-09-22 14:27 CEST — Settle opaque schema boundary construction

**What I did**

Recorded the owner's Q6 representation decision in schema.md §5 and A.4:
read/write construction fails when Type contains an opaque target without a
structural description; typeOnly keeps its optional checks, identity if none.
Only Q6's metadata/tooling scope remains open. Corrected CLAUDE's stale claim
that M4 had not started: slices 0–3 have landed. Updated the current scheduling
in the contract, CLAUDE and queue so row 67 may run in parallel with S1, with
both required before S2. Historical decision entries remain intact.

**What I learned**

The opaque boundary decision can be settled independently of JSON Schema and
generators. The numeric-alias fix is a checker task, not a dependency of S1's
frontend work. Relative links, section stability, stale-wording checks and
`git diff --check` passed. This was documentation only; no code, measurements
or compiler gate runs.

## 2026-09-22 15:33 CEST — Schema S1 frontend, implemented by Sol agents

**What I did**

Managed three Sol agents for implementation, fixtures and formatter/AST work,
then independently reviewed and validated the integrated slice. Specified the
unresolved BIR plan, formatter layout and temporary pre-resolution refusal
before the corresponding implementation. S1 now parses schema declarations,
fields/modifiers, tagged unions, generic operands and recursive references;
formats them; and preserves their unresolved structure in AST/BIR dumps and
frontend artifact v2. Check/build and later dumps explicitly refuse schemas
until S2. No endpoint typing, library codec or specialised runtime landed.
Updated CLAUDE, schema status and the queue; row 67 remains a prerequisite for S2.

Added 14 corpus fixtures and three focused black-box scenarios. Independently
confirmed fail-first behavior with the saved pre-S1 binary, exact success
outputs, 49 truncated-source probes, over-depth diagnostics, sibling recovery
and all five later dump refusals. Final gates: `zig build test` 464/464,
`zig build test-blackbox` 283/283, and `zig build fmt-check` green. Document
links, stable numbered sections, unchanged G1–G5 and `git diff --check` passed.
No schema benchmark measurements were run.

**What I learned**

Integration review found real failures before acceptance: AST accessor gaps,
recursive formatter/dumper frame growth, a variant-rename representation
mismatch, detached field docs, lost siblings after malformed fields, missing
rename strings reaching a string-node assertion, and secondary “not a module”
errors after the temporary refusal. These were fixed and covered. The refusal
must precede resolution and survive cache reloads; malformed schema payload
ranges also need verification at the artifact boundary.

The first full black-box run failed twice because an empty, untracked
build/bad/SchemaUnsupported directory remained after relocating that fixture.
The corpus and matrix each treated it as a project. Removed only that empty
directory and reran the full black-box gate successfully; no compiler change
was needed. Directory-based harnesses require directory cleanup, not just file
cleanup. The remaining schema decisions and row 67 were not folded into S1.

## 2026-09-22 16:11 CEST — Schema field docs and primitive alias literals

**What I did**

Delegated two independent fixes to Sol agents and reviewed their changes. Schema
field docs now occupy their own line at the ordinary field column; updated the
§2 contract and one formatter fixture/golden, including mixed plain/doc comments
and arbitrarily indented input. Fixed queue row 67 by checking a constrained
variable against the alias root in `unifyAlias`. Added the fail-first
`check/good/NumericAliasLiterals` project covering local/imported Int and Float
aliases, chains, both operand orientations, record controls and interface names.
The baseline produced six kind_mismatch diagnostics; the fixed compiler checks
cleanly and matches the interface golden. The combined `zig build test`,
`zig build test-blackbox` and `zig build fmt-check` gates all passed.

**What I learned**

The alias defect also rejected appendable String aliases: the same wrong-root
check caused both failures, and the fixture pins both without changing the kind
lattice. Moving field docs must canonicalize already separate docs as well as
inline ones; AST preservation, comment order and formatter idempotence pass.
Q7's constructor-pattern spelling still needs owner confirmation before S2.
Schema-containing inputs remain excluded wholesale from resolver fuzz during S1;
removing that exclusion is now explicit in S2's contract and queue acceptance.

## 2026-09-22 16:20 CEST — report 35: record syntax in ML-style languages

**What I did**

- The owner, looking at `type alias User =` / `{ name : String` / `, age : Int` /
  `}`, said it is ugly and that an indentation-sensitive language should use
  that to its advantage. Sent one research agent for primary sources on how
  ML-family and layout-sensitive languages declare records; it wrote
  `docs/design/research/35-record-syntax-in-ml-languages.md` (Lean 4, Idris 2,
  Agda, F#, Nim, Koka, Scala 3, Elm and its forks, Roc, Haskell, PureScript,
  Gleam and others; 288 links; three `[sketch]` layout syntaxes for beni's
  record type and `schema` declaration; no verdict). Spot-checked its local
  line references and key sources before relaying it. Committed the report;
  nothing else changed.

**What I learned**

- **Layout records and inline record types have never coexisted.** Every
  language with `structure … where`-style fields (Lean, Idris, Agda, Nim) has
  no anonymous record type in a signature; every structural-records language
  (Elm, Roc, PureScript, SML) kept braces. Beni's records are structural and
  appear inline, so a layout form is a second spelling, not a replacement —
  Koka's situation, tied by desugaring, is the only precedent for having both.
- Elm's leading comma is not a principle: Tibell called comma-first a
  workaround for Haskell's missing trailing comma, Evan declined to argue it,
  and elm-format ended the debate by adoption. Feldman proposed newline
  records in 2015 and later, in Roc, made commas load-bearing again — for
  VALUES and for types spanning lines, not for a declaration whose every
  field starts `name :`.
- The beni-shaped candidate is the `let`-binding column: a bare field block
  after `=` needs no new parser state and no new lookahead, and it fixes the
  one place the current form is awkward (a doc comment separated from its
  field by the comma). The cost is two spellings; the mitigation is Koka's
  desugaring. F#'s decade of alignment-by-field-name-length is the warning
  against the alternative of letting a brace set a column.
- S1 is the cheapest moment to change the schema body's spelling — parser,
  formatter, fourteen fixtures — and the moment passes at S2.

## 2026-09-22 17:36 CEST — Layout record declaration bodies

**What I did**

- Pulled first (already current), read report 35 and the language/frontend/schema
  contracts, then specified option A before implementation. Spec commit `fee8a02`;
  feature commit `1faf6fe`. Delegated parser, formatter and fixture implementation
  to separate agents and independently reviewed and validated their work.
- Added the field-block grammar, exact later-line `lower_ident ':'` nesting test,
  sibling/continuation/recovery columns and always-vertical declaration formatting;
  appended schema A.5 and updated CLAUDE.md and the schema queue. Only
  `src/parse/Parse.zig` and `src/fmt/Format.zig` changed under `src/`; AST node
  shapes and the checker, resolver, BIR and JS phases are unchanged.
- Added 15 corpus cases: parse/good `BraceRecordAlias`, `LayoutRecordAlias`,
  `LayoutSchemaDeclarations`, `LayoutSchemaFallbacks`, `SchemaTaggedBraceNextLine`;
  parse/bad `LayoutFieldWrongColumn`, `LayoutFieldMissingColon`,
  `LayoutNestedAfterType`, `LayoutFieldRecovery`, `LayoutFieldEof`,
  `LayoutSchemaViaMultiline`; fmt `RecordDeclarationBodies`,
  `LayoutDeclarationBodies`, `RecordLayoutOneLine`, `TaggedSchemaComments`.
  Two black-box scenarios assert complete AST/BIR spelling equality and complete
  recovery diagnostics/AST, retaining malformed siblings, `kept` and `after`.
- Verified byte-identical brace/layout dumps: the record alias pair is 593 AST
  bytes and 850 BIR bytes; the complete SchemaDeclarations mirror is 2,255 AST
  bytes and 2,683 BIR bytes. Its `.ast` golden is copied from the brace oracle,
  and the black-box `expectEqualStrings` checks make equality an explicit law.
  The fmt corpus supplies AST preservation, comment preservation and fixed points.
- Proved red before source edits with the old binary, then saved and reversed the
  implementation patch, restored the seven old formatter goldens temporarily,
  rebuilt and ran the full black-box suite: exactly 14 NEW corpus cases and the
  two NEW scenarios failed; no existing case failed. The old brace compatibility
  control passed. The six negative cases differed in their full diagnostic
  goldens; the one-line and tagged-comment formatter cases parsed but differed in
  output; the remaining red good/fmt cases were rejected by the old syntax/doc
  rules. Reapplied the patches without `git stash`. After updating two stale
  supplementary formatter expectations, verified the refreshed patch still
  reverses to the exact same original source tree; production code did not change.
- Read all seven existing fmt golden diffs: AlreadyCanonicalModule,
  AlreadyCanonicalTypes, CommentsBetweenAndInside, ExtraSpacesEverywhere,
  NaryTypes, SchemaDeclarations and TypeDeclUgly. Only declaration record bodies
  and tagged variants moved, including comments formerly attached to removed
  delimiters. Inline/extensible records, ordinary `type`, `case`, `let` and record
  values remain unchanged. The one-line Point alias always becomes layout.
- Reformatted ten benchmark files in this separate source-format commit:
  `bench/corpus/{Counter,Data/Parser,FormValidation,JsonCodecs,NotesApp,PrettyPrinter,Router,Ui/View}.beni`
  and `bench/schema-prototype/{cases/Cases,src/Schema}.beni`. Compared every
  worktree file's before/after BIR stdout byte for byte (both exits 0), then passed
  `beni fmt --check bench/corpus bench/schema-prototype`. No core/platform source
  required reformatting and no emit/run golden changed.
- All three gates passed before the feature commit and after source reformat:
  `zig build test` 464/464; `zig build test-blackbox` 285/285, including jobs 1/8
  determinism and the development/release runtime corpus; `zig build fmt-check`.
  Independent 17-case probes also checked old brace geometry, nested/inline and
  extensible types, n-ary continuations, modifier/via layout and malformed sibling
  recovery. Both 4,100-level layout alias/schema inputs stopped with
  `nesting_too_deep`, without panic. Detailed command logs and patch/proof files
  are in `/tmp/beni-layout-proof/` for this workspace session.

**What I learned**

- Nesting must compare the next token's line with the COLON, while indentation
  belongs to the field name; bracket columns never enter the rule. Old tagged
  brace payloads can legally sit left of the variant name, so detecting layout
  must not tighten the old brace arm's declaration-relative indentation.
- Ordinary brace record-type fields previously rejected field docs. Consuming
  those docs in the parser is necessary for the commissioned two-spelling
  equivalence; they stay comments, without adding semantic AST/BIR payload.
- A payloadless variant and an explicitly empty record payload have different
  ASTs. The latter therefore retains `{}` (`Empty as "empty" {}`); schema record
  operands with outer modifiers likewise retain braces because a nested field
  block has no outer-modifier production.
- Moving a tagged rename before its payload reverses source-token visitation.
  Its comments must be emitted after payload comments, exactly once and in the
  original order; the tagged comment fixture catches both duplication and
  second-pass indentation drift.
- Confirmed a separate pre-existing S1 defect and recorded queue row 70 without
  fixing it: `schema X = { a : Int } nullable` is rejected at `nullable` despite
  schema §2's operand/value-modifier grammar. The direct brace arm in
  `parseSchemaDecl` bypasses value modifiers. This layout slice leaves it alone.


## 2026-09-22 21:06 CEST — Schema S2 checker, interfaces and emit boundary

**What I did**

- Pulled `021f331`, specified schema.md A.6, and used three Sol agents for
  checker/resolution, plan/cache contracts and black-box fixtures while managing
  integration and validation. Committed and pushed the public `core/Schema`
  type surface (`2d2c0e7`) and the fail-first row 70 brace-modifier fix
  (`875f623`), each with all three gates green.
- Implemented schema namespaces, both endpoint families, generic member schemes,
  conversion checks, constructor patterns and immutable resolved plans. Published
  schema interface v2, frontend artifact v3, cache entry v2 and plan v1. Moved
  the S1 wall to emit: schemas check, but build refuses before output until S4.
- Added 36 new/moved corpus cases across the three commits, with complete member
  goldens and exact diagnostics; upgraded the schema BIR conversion dependency
  golden deliberately. Added persistent firewall, alpha-rename and malformed-plan
  repair coverage. Updated schema status, CLAUDE.md and the queue.
- Reversed only the source patch, never stashed, rebuilt and tested the exact
  baseline. Confirmed the expected new failures and byte-identical old
  SchemaUnsupported refusal. Repeated the source reversal after final fixes,
  verified the same baseline and reapplied exactly. The detailed evidence and
  fixture list are in [schema-s2-validation.md](schema-s2-validation.md), including
  the corrected test-only typo and discarded zero-test filtered invocations.
- Final restored-tree gates: 468/468 unit tests, 287/287 black-box tests (including
  determinism, round-trips and release execution), fmt-check green. Independent
  cache runs checked 13/0/1/2 modules for cold/warm/private-edit/public-edit;
  private edits preserved serialized interface bytes and stopped at the firewall.
  Appended this entry without changing prior diary entries; left user-owned
  `.agents` and `AGENTS.md` untouched.

**What I learned**

- Cached frontend tokens omit payloads: namespace candidate resolution must
  recover spelling from stable token positions and source bytes. Ambiguity
  requires two valid complete paths, not merely a shared root identifier.
- Private endpoint definitions and settled capabilities must survive cache hits,
  while executable conversion bodies stay outside interface hashing. Generic
  parameter spellings must also remain unhashed so alpha-renames preserve the
  firewall.
- Rejecting a semantically invalid plan requires clearing the loaded entry slot
  and cutoff hit state as well as freeing its payload; otherwise the canonical
  repaired entry is not written. The malformed-plan black-box test proves both
  the miss and exact repair.
- A focused Zig test filter placed after a dependency module can run zero root
  tests. Counted execution, not an empty successful log, is the evidence; the
  corrected focused tests and full final suite passed.
- Found two separate schema-free baseline defects and recorded, rather than
  fixed, queue rows 71–72: imported ordinary arities above 255 and derived
  wrapper equality ignoring a payload type's custom public `eq`.

## 2026-09-23 21:01 CEST — row 72 finished: no second obligation for a committed custom method

**What I did**

- Picked up the half-landed row 72 fix (derived wrapper equality honours a
  payload type's public `eq`/`compare`). The one regression left was
  `TwoSlotsNested` (dispatch dump and run build): two extra evidence arguments
  and an INTERNAL ERROR "The hidden arguments of this call do not add up".
- Root cause: after the speculative applicability probe accepts a custom method
  inside a derived target, `commit{Local,Imported}MethodApplication` repeats the
  unification on the real store so a specialised receiver (`Holder Int`) narrows
  the caller. That commit registered the copy's constraints as obligations a
  second time (first via `registerInstantiated`, then through Rule U3's
  `deferConstraints`), and `siteOrigins` invented free child slots for the
  site-less copy — evidence the part tree from `ownValueParts`/
  `importedValueParts` already supplies.
- The previous agent's unbuilt fix returned early from `deferConstraints` for the
  whole commit. That also dropped the CALLER's constraints whenever a caller flex
  met the copy's structure. Narrowed it: `Solver.committed_method_from` holds the
  constraint table length before the copy, and only indices at or above it are
  skipped. Probed with a caller flex carrying `left.label ()` beside a
  `Holder Key`-specialised `==`, in both orders, plus `left.bogus ()`: interface
  `Key, Key -> ( String, Bool )`, correct JS, and `unknown_method` still reported.
- Documented the rule in static-dispatch §6.3.1 step 4 and marked queue row 72
  done. Rows 73/74 left unfixed as recorded.
- Gates: 468/468 unit, 288/288 black-box (33/33 steps), fmt-check green. Red
  proof: reversed `git diff -- src`, rebuilt; `DerivedEqThroughCustom` (16
  diagnostics) and `DerivedEqLocalCustom` (2) red, both inference fixtures fail
  with `not_equatable` at the definition's `==`; the negative fixtures and
  `DerivedEqWithArbitraryConstraint` are controls that pass either way.
  Reapplied; the src diff hash matches byte for byte.

**What I learned**

- A speculative check followed by a committing re-unification must not
  re-register what the check already accounted for, but the filter has to be by
  PROVENANCE (constraint index minted by the copy), not by phase: caller
  constraints can meet the copy's structure in the same unification.
- A caller flex's own method constraint already has a live obligation from its
  call site, so the probe above could not tell the broad suppression from the
  narrow one; the narrowing is justified by the invariant, not by a red test.

## 2026-09-23 21:39 CEST — row 72 review: exact commit provenance, capabilities final for early groups

**What I did**

- A read-only review found three defects in the row 72 fix, each reproduced
  with the installed binary. Fixed all three, one fixture each, every one red
  on the previous-round binary and green now.
- HIGH, a regression: the `committed_method_from` watermark skipped every
  constraint at or above it, and a commit can merge two callers' FOLDED
  constraints (`x < x`, `y < y` in a `let`) into a fresh set before that set
  meets `Int` (`Trip.eq : Trip a a a, …` at `Trip x y Int`). Rule U3 skipped
  the callers' set and nothing answered it: INTERNAL ERROR "I cannot tell what
  this call dispatches to". Replaced the watermark with exact provenance:
  `committed_copy` is the range the copy's instantiation created, and `adopt`
  records a rebuild as copy-owned only when every source is. A join with a
  caller constraint keeps its obligation. Fixture
  `run/DerivedEqCommitKeepsCallerConstraints/` (tuple and record shapes).
- MEDIUM and LOW, one cause: groups checked early for an unannotated
  `pub eq`/`pub compare` read `Types.settleDispatchCapabilities`' syntactic
  first cut. It descends into a parameter with an arbitrary requirement
  (valid `W (Holder Keyed)` refused) and ignores a specialised receiver
  (`L (Holder String)` accepted, then an INTERNAL ERROR about too few derived
  parts). `Check.zig` now runs Solve's `settleOrdinaryCapabilities` before the
  early groups too, and again after they publish their schemes. Fixtures
  `run/DerivedEqInPriorityGroup/` and
  `check/bad/PriorityGroupSpecializedPayloadEq/`.
- Corrected queue row 73: after row 72 its reproducer, and the `R.eq` where
  `a.compare` variant, are refused as `not_equatable`. They used to crash or
  print a wrong `False`. What is left is a capability gap. Recorded row 75: an
  `==` on a module's own type, inside another early group, runs before that
  type's unannotated `pub eq` has a scheme. Its site is `err` with no
  diagnostic and it emits `undefined`. Pre-existing on 875f623 and not fixed.
- Extended static-dispatch §6.3.1 step 4 with both rules. Gates: 468/468 unit,
  288/288 black-box (33/33 steps), fmt-check green. Nothing committed.

**What I learned**

- "Skip what the commit created" has to be computed per constraint through
  every rebuild (`adopt` is the one choke point all rebuilds share). An index
  watermark conflates the copy's constraints with callers' constraints that a
  rebuild merely moved.
- A per-module fact that an early phase reads must already be final by then,
  or visibly undecided. A cheap first approximation that a later pass refines
  is wrong in both directions for whoever reads it in between.
- `p1_tuple` (`Pair.eq` where `a.compare` under a tuple shape) is now
  `not_implemented`, the §7.1 gap for an evidence-taking `ext` in a part
  position, where 875f623 said `not_equatable`. Both refuse the program, and
  the INTERNAL ERROR it also produced is gone.

## 2026-09-23 22:35 CEST — row 75: late derived parts become part sites; untyped own methods refused

**What I did**

- The review found a program 875f623 refused that row 72 compiled to a wrong
  answer. `M.T` holds a function, and there is an unannotated `pub eq`. Inside
  an unannotated `pub compare`, the `let` holds `{ v = left } == { v = right }`.
  It printed `not lt`, where `lt` is right. The review read it as row 75's
  ordering defect. Its real cause is different. When the comparison is solved,
  `left` is still a flex, so `targetFor` wrote `part 0 err` and `Lower` answers
  an `err` part with a structural `Basics$eq`. The `T = T Int Int` twin was
  already wrong on 875f623. So was `pair l r = let s = ( l, 0 ) == ( r, 0 ) in s`
  at a type with a custom `eq`, whose promoted evidence parameter the part
  never used.
- Fixed that class properly (A.86). The constraint the flex arm attaches now
  carries a PART SITE: `parent = part_site_parent`, `evidence_index` into
  `Solver.part_slots`, which holds the absolute part index. `fillPart` tells
  `targetFor` which part it fills. `emitSites` writes a part site's answer
  into its part. A named method is re-resolved in part form, so it carries its
  own evidence. `siteOrigins` skips part sites, and site de-duplication
  compares `parent`. `dispatch/ErrParts`'s `crossed` part moved from `err` to
  `strict_eq`; its intent comment was rewritten and the golden re-blessed.
- The own-method ordering form (an early group's `==` on a type whose
  unannotated `pub eq` comes later) is option (b): refused with the new
  `method_needs_annotation` (§10.12). It is catalogued in `language.md`,
  `checker.md` and static-dispatch. `js/Lower.zig` now refuses an `err`
  site as `internal` instead of emitting `undefined`: Lower only runs after a
  clean check, so such a site had no diagnostic.
- Fixtures `run/DerivedPartTypedLater/` (function-holding, plain and promoted
  forms; round-2 binary prints `False False False …`) and
  `check/bad/MethodNeedsAnnotation/` (round-2 binary: `check` exit 0). Gates:
  468/468 unit, 288/288 black-box (33/33 steps), fmt-check green. Queue row 75
  narrowed to "part form fixed; own-method form refused". Nothing committed.

**What I learned**

- `err` in a part had two meanings: a position nothing inhabits, and a
  position not yet known. `dispatch/ErrParts` pinned the first meaning and
  itself documented the second (`crossed`) as "harmless". It was harmless
  only while no type in the comparison had its own `eq`.
- A site-level answer and a part-level answer differ in where the callee's
  evidence goes: child sites of the instruction versus the part's own
  `parts`. Re-resolving through `targetFor` at answer time is simpler and
  safer than translating one form into the other.

## 2026-09-23 23:28 CEST — row 76: cyclic receivers end the drain; `pub` in the §10.12 hint

**What I did**

- A review found a regression: `pairEq x y = let inner a b = a == b in inner x y
  && inner [ x ] [ y ]` panicked on 875f623 after 2^20 drain rounds (about
  10 s). On the round 3 tree it never finished. Cause: a constrained `let`
  helper is monomorphic (§11), so the two calls make `x ~ List x`. The occurs
  check waits for generalisation, and `List.eq`'s `where a.eq` re-asks for
  the element's `eq` forever. Instrumenting showed the round 3 tree's drain
  ending after about 100k rounds, not the 2^20 that panicked. A `sample`
  of the hung process showed it inside `Dispatch.Builder.finish`, sorting a
  huge number of sites for one instruction. So each pass wasn't slower; the
  endless chain now leaves its output in the dispatch table, and `finish` is
  superlinear in it.
- Fix: `Obligation.depth` records how long the discharge chain that raised an
  obligation is (`Solver.discharge_depth`, stamped in `register`). Every
  `cycle_check_depth` (64) generations the drain runs `occurs` on the
  receiver. A cyclic one is reported `infinite_type` and poisoned. All four
  reported bodies now fail with `infinite_type` in under a second. It is a
  real error: the program is not valid under §11's rule.
- `method_needs_annotation`'s hint now carries `pub` when the method is
  `pub` (`pub eq : T, T -> Bool`); the fixture's `.diag` was re-blessed.
- Recorded queue row 77, the Tree/record hidden-argument miscount (same on
  875f623; not fixed). Row 75 now notes that eq-before-compare is the common
  case, so the method-group ordering is the next step.
- New fixtures: `check/bad/LetHelperCyclicReceiver`, plus an `abuse_test.zig`
  scenario over all four bodies with an 8 s limit. The round 3 binary times
  out on the fixture at 15 s. Gates: 468/468 unit, 289/289 black-box (33/33
  steps), fmt-check green. Nothing committed.

**What I learned**

- "It hangs" and "it loops" are different claims: sample the process before
  guessing. The loop had become finite. The cost had moved into a later
  phase that is superlinear in what the loop leaves behind.
- A deferred occurs check means every consumer that walks a type between
  unification and generalisation must survive a cyclic graph. Charging the
  check to obligation generations keeps it off the hot path.

## 2026-09-24 00:17 CEST — row 72: fast path past the applicability probe

**What I did**

- The review measured row 72's cost on programs with no custom method at all.
  `s_tup6000` (`( a, [ b ] ) < ( b, [ a ] )` ×6000) was 1.63x master, and
  mixed `gen` 1.14x. A `sample` over a 400k-function version showed two
  sources, and neither was the cycle check:
  - `List.eq`/`List.compare` are public methods, so every `List` part went
    through `importedMethodAcceptsApplication`'s probe and commit.
  - `derivable`'s probe rebuilt the whole target that `finishDerived`
    builds right after.
- Added `plainMethodMask`: a scheme `T a1 … an, T a1 … an -> Bool|Order`
  over distinct variables whose only constraints are the method's own name
  at the standard type. It is cached per module for imported values
  (`Env.plain_methods`) and skips the copy, the probe and the commit. The
  receiver must match (`UnrelatedEqDoesNotGrantCapability` caught the first
  version). `flagUnansweredParts` stands in for the probe's completeness
  test. `targetNeedsProbe` lets `derivable` skip its probe when the shape
  reaches no non-plain method, no untyped own method, and no nominal type
  that cannot derive.
- ReleaseFast, `--self-profile` check-phase medians of 7, master /
  round-4 tree / now:
  - s_tup6000: 20.1 / 37.5 / 21.7 ms (+8% over master)
  - s_int6000: 15.3 / — / 15.7 ms
  - gen: 73.8 / 94.4 / 76.0 ms (+3%)
  - `zig build bench -- --generate=100000` check phase: master 52.6 ms,
    now 55.2 ms. The `resolve` phase is untouched by row 72 (no file under
    `src/resolve` changed) and read 6.20 ms on master against 4.68 ms now;
    the reported 0.00 → 6.40 was not a real regression.
- No golden changed. Gates: 468/468 unit, 289/289 black-box (33/33 steps),
  fmt-check green. Nothing committed.

**What I learned**

- A speculative check pays for itself only where it can decide something.
  Say when that is (a scheme that can narrow or refuse) and test for it
  before speculating.
- `zig build bench`'s `resolve` line is graph-plus-resolution only. A
  capability or checker change cannot move it, so look for noise before
  looking for code.

## 2026-09-24 15:00 CEST — the checker is rewritten from the ground up; R0 lands its red fixtures

**What I did**

- Started on queue row 75 and stopped it: the owner asked how sound the checker was, and five
  read-only reviews at `7427828` (inference core, static dispatch, orchestration, adversarial
  black-box, and a study of Roc's Zig checker, now checked out under `references/roc` with the
  other uninitialised submodules) found about 30 confirmed defects. Half of them are programs
  that check and then misbehave, several in plain Elm code: mutual recursion typed against the
  last member's locals table (since M2b), an annotated `let` whose rigid variables escape, any
  warning switching off exhaustiveness, `f n = if n == 0 then True else f (n - 1)` failing to
  build, the record-alias constructor building a tagged object. The row 75 partial work was
  discarded (`master` reset; the patch stayed in that session's scratch only).
- The owner ordered a ground-up rewrite. A planner wrote `plans/checker-findings.md` (CK-01 …
  CK-77, each with program, observed output, cause, class K1–K15, fixture and slice),
  `docs/design/checker-v2.md` (normative architecture, invariants I1–I16, decisions D1–D14) and
  `plans/checker-rewrite.md` (slices R0–R15). Four design-review rounds each found real holes
  (a walk that made every receiver cyclic, order-dependence in four different mechanisms, a
  fixpoint that did not terminate); all are resolved in the text, round 4 cleared R4a–R8a.
  Pointer notes went into `checker.md`, `static-dispatch-spike.md` and `language.md`; nothing
  renumbered. Queue rows 78 (the rewrite) and 79 (`beni dump` writes at offset 0) added.
- Decisions: the owner took the planner's recommendations (D1–D13); I took D14 under that
  standing instruction and flagged it (a recursive group's ambiguous receiver is refused in both
  orders; an annotation lifts it). CK-71 → R1, CK-75 → R8a. Added R15, a structural audit.
- R0 landed: `tests/pending/` (73 red fixtures, each with a `-- CK-NN` line and a recorded red
  signature in `RED`), 9 timed scenarios, `zig build test-pending`, and 15 regression guards in
  `tests/corpus/` that v1 already passes. A read-only review found no blocker and seven
  should-fixes (loose `.codes`, a CK-42 scenario that could never go green, custom `eq`s that
  behaved structurally), all fixed. Gates: 468/468 unit, 289/289 black-box, fmt-check green;
  `test-pending` 82 RED, 0 GREEN.

**What I learned**

- A green suite and a sound checker were far apart: the corpus exercised features, not
  ordinary program shapes. The adversarial reviewer found a build failure on four-line
  recursion in minutes.
- Every design-review round found blocking holes in the previous round's fixes. The fixes that
  held were the ones that deleted machinery (nesting at demand replaced parking, pinning and
  prefix closures); the ones that added a mechanism each needed another round.
- Black-box fixtures cannot see structure. Two checkers can pass the same corpus while one
  counts evidence once and the other in twelve places that happen to agree; that is why R15
  exists.

## 2026-09-24 — R1: shared-code fixes and v1 one-liners

**What I did**

- R1 of the checker rewrite (`plans/checker-rewrite.md`) closed CK-11, 17, 19, 43, 44, 45, 46,
  47 and 71 on v1, CK-12 by a unit test, and CK-78 as a decision. Each fixture was red with the
  fix stashed and is promoted from `tests/pending/` into `tests/corpus/` with a blessed golden.
  - The record-alias constructor emits a record (D12, `backend.md` §4); an irrefutable alias
    pattern reads the fields in declaration order. I decided that under rule 7 after the review:
    R1 had first refused a pattern that ran correctly on 22daa5f and guarded nothing. Imported
    alias constructors stay refused until interface v3 carries field names (R3).
  - Warnings no longer switch off exhaustiveness; `Session`'s quiet flag counts errors.
  - Symbol ids are input-derived: the per-worker intern pools merge in file-index order. A
    loaded black-box test (one spinner per CPU, 36 runs) differed on 22daa5f and never now.
  - The equatable walk's stack grows instead of answering "yes" at 256. That exposed a runtime
    `RangeError` on derived `==` past ~40 000 fields, so derived record `==`/`compare` is
    refused at check time past a named cap of 4 096 fields (CK-79, lifted in R2a).
  - Frontend artifact format v4 (a new `..` token).
- New findings: CK-78 (decided), CK-79 and CK-81 (a compiler segfault printing a 60 000-field
  derived body; pre-existing) assigned to R2a, CK-80 (exponential `==` on nested tuples) to R6a.
- Gates: 470/470 unit, 292/292 black-box, fmt-check green; `test-pending` 74 RED, 0 GREEN. Bench
  check phase +1.0 % against 7427828.

**What I learned**

- Making one walk honest moves the failure somewhere else: the growable walk turned a false
  refusal into a runtime stack overflow. Every "we now accept more" change needs a probe at the
  new extreme, run to completion in Node, not only through `check`.
- A reviewer's measurement beat the brief twice: capping CK-71's load at 8 spinners made the race
  vanish, and the planner's "silence only T's constructors" was not implementable in lowering.

## 2026-09-24 — R2a stage 1: evidence trees are the checker→backend contract

**What I did**

- `checker-v2.md` §13 is live on v1: `Dispatch.finish` converts v1's flat pre-order sites and
  parts into evidence trees (the one place that order is interpreted), and `Lower`, `Edges` and
  `Reach` read trees. `Lower`'s counting (`targetEvidence`, `externalEvidence`, `ownEvidence`,
  `valueEvidence`, the cursor) is deleted; counts live in `Dispatch`. The I7 assert runs last in
  `ModuleCheck.run` and reports `internal`, never a panic. Dispatch dump v2, dispatch bytes v2
  (verified acyclic on load), cache entry v3. CK-61 closed.
- Emitted JavaScript byte-identical: no `run/` or `emit/` golden moved, and the reviewer compared
  1 998 programs in four build modes against 9a931d7. The 27 `dispatch/` goldens were
  re-blessed in the new format and read one by one.
- The review caught a silent wrong answer the new converter introduced: past a 1 024-level cap it
  wrote `undetermined`, which `Lower` answers with structural `Basics.eq`. The cap is gone; only
  a cycle guard remains, and it becomes `internal`. Also moved the assert after every other
  error pass (a real `cyclic_value` gained a spurious `internal`).
- My decision, recorded in `checker-v2.md` §13.1 and `tests/pending/run/DeadMiscount.beni`:
  `check` now refuses v1's CK-30 miscount even in unreachable code that used to build and run.
  v2 removes the miscount at R7.
- Pending perf scenarios now judge on the child's CPU time: a concurrent build had made CK-40
  read GREEN on wall time (87 s / 162 s).
- Gates: 474/474 unit, 293/293 black-box, fmt-check; `test-pending` 75 RED, 0 GREEN. Bench check
  +1.3–1.5 %, emit −2 %.

**What I learned**

- Removing a guard exposes what it was hiding. The old depth-32 caps in `Reach` and `Edges` were
  why 9a931d7 refused the deep case at all; the new converter needed its own answer for depth,
  and "undetermined" was the wrong one because the backend treats it as permission to guess.
- Wall-clock ratios are not evidence on a shared machine. Measure the thing's own CPU time.

## 2026-09-24 — R2a stage 2: the backend's walks no longer recurse per chain link (CK-81)

**What I did**

- CK-81 closed: a derived `eq` over a 60 000-field record payload segfaulted the printer, which
  recursed once per `&&` (and once per cell of a long list literal). `js/Print.zig` recurses for
  256 levels and then switches to an explicit work stack; the release walkers in `Opt` and
  `Rename` use an explicit stack (`JsIr.pushOperands`); `Rename.verify` is linear. All three
  switches list every node tag, and a seeded test prints 400 random declarations through both
  printer paths at several switch-over depths and compares bytes.
- Past 4 096 evidence parameters a derived function takes one array (`static-dispatch-spike.md`
  §9.2, A.87): V8 threw `RangeError` at a 60 002-argument call and refuses functions over 65 535
  parameters. The threshold is the backend's own constant; R2b's `Convention` will own the choice.
- Every `run/`, `emit/` and `emit/release/` golden unchanged; the reviewer compared 179 fixtures
  in four build modes. Emit time unchanged.
- New findings: CK-82 (65 536+ fields: a Debug panic, a false refusal in ReleaseFast) → R8a with
  CK-79, which I moved there from R2a because D4 already changes the derived signature; CK-83
  (accepted programs whose JavaScript nests past Node's parser: ~1 700-element lists, long `++`
  chains, ~2 000 nested calls) → a new backend slice R2c.
- Owner-approved: `CLAUDE.md` now says cache entry v3 since R2a; an earlier session's 2.6 GB
  scratch was deleted (`/tmp` had filled to 98 % with review worktrees).
- Gates green; `test-pending` 77 RED, 0 GREEN.

**What I learned**

- Fixing a crash at one layer moved the limit to the next: the printer fix exposed V8's argument
  limit, which exposed the checker's `u16` count. Probe the new extreme end to end each time.
- Two implementations of one function stay equal only if the compiler forces it: an `else`
  branch would have hidden a new node kind in exactly the programs the corpus never builds.

## 2026-09-25 — R2b: one calling convention

**What I did**

- `src/check/Convention.zig` is now the only place that decides how a constrained value is
  defined, called and treated at load time (`checker-v2.md` §12.5), for `Lower`, `Cycles` and
  `Emit`'s `foreign` check 4, and whether a derived function takes its evidence positionally or
  as one array. Dispatch bytes v3 carry the `convention` column; importers derive theirs from
  the interface through aliases.
- Closed CK-33 (`same = (==)` and cross-module constrained function constants emitted with the
  wrong shape), CK-34, and CK-84, which R2b found: an imported constrained function typed through
  an alias was eta-expanded at arity 0 and threw.
- The review found that R2b, following §12.5, let a `where` exempt a point-free value from
  `cyclic_value`: `h = compose h g` checked and overflowed at its first call. I ruled for
  `language.md` §7 (a guarantee-protecting refusal must not depend on an annotation); the fix
  changed only the cycle reading.
- Also from the review: `constrained_constant` no longer refuses `pub same = (==)` (rule 7);
  `foreign` check 4 reads `Convention`, which un-refused a correct `foreign` typed through a
  concrete alias. The body of a zero-parameter `where` value now runs per use: documented in
  `language.md` §6, pinned by a fixture, and CK-85 schedules one-evaluation-per-call-site for R8a
  (owner, 2026-09-25). New CK-86 (the `exposing (Box, Box)` hint) for R13. Catalogue: 86 entries.
- Gates: 482/482 unit, 299/299 black-box, fmt-check; `test-pending` 76 RED, 0 GREEN. No existing
  `run/` or `emit/` golden moved.

**What I learned**

- The design document itself was the bug here: §12.5 prescribed a reading that contradicted
  `language.md` §7. Reviewers must check the spec against the other specs, not only the code
  against the spec.
- I timed the suites (`84e3cb1`, machine partly loaded): `test` 23 s, `test-blackbox` 5.1 min
  (bounded by `corpus_test`'s 5 min), `test-pending` 12.2 min, of which 11 min are timing
  scenarios running the old super-linear code in a Debug build, three times at n and 2n. A
  harness slice comes next.

## 2026-09-25 — harness: the test steps run in two minutes, not thirteen

**What I did**

- The owner asked why slices took two hours; I timed the suites. The review loop is half of it,
  but every run of the gates plus `test-pending` cost about 13 minutes, run 3–4 times per slice.
  A harness slice, approved by the owner:
  - `test-pending` keeps the pending fixtures and the Debug-only scenarios (CK-82's red is a Debug
    panic); the timing scenarios moved to `test-pending-perf`, which runs a ReleaseFast compiler
    (`zig-out/perf/bin/beni`, `BENI_EXE`) on sizes recalibrated for CPU time. Each is still red,
    and CK-40/CK-41 read green with their known fixes applied in a scratch worktree.
    `plans/checker-rewrite.md` §1 lists the slices that must run the perf step.
  - `corpus_test` runs as five parallel parts (parse, check, build, run dev, run release), each
    kind assigned by an exhaustive switch; `abuse_test`'s wide-input tests split out. 743
    fixtures before and after; one broken golden per kind (17) still fails the gate with every
    harness variable exported to a hostile value.
- My run on an idle machine: `test` 17 s, `test-blackbox` 98 s (was 307 s loaded, 156 s idle),
  `fmt-check` 0.2 s, `test-pending` 33 s (was 10–12 min), `test-pending-perf` 23 s. 76 RED, 0
  GREEN.
- Open, for R3: where a timing scenario goes once its bug is fixed (the old "move into
  `abuse_test`" would run ReleaseFast-sized scenarios on Debug).

**What I learned**

- The expensive tests were the ones proving the old code is slow: cubic schema settling at 800
  schemas in a Debug build, six times over. Measuring the thing you are fixing on the build the
  budget is about (ReleaseFast) cut them from 11 minutes to 23 seconds.

## 2026-09-25 — R2c: emitted JavaScript nests only as deep as the source (CK-83)

**What I did**

- CK-83 closed: accepted programs lowered to JavaScript nested past what engines parse (a
  ~1 700-element list, long `++` chains, ~2 000 nested calls), so `build` exited 0 and Node threw.
  The implementer measured six engines from nix (headless Chrome 153, Firefox 144, WebKit, Node,
  the SpiderMonkey shell, Bun) and specified bounded shapes first in `backend.md` §4: long lists
  as one array folded into cells, flat `&&`/`||` (including operands that need statements), deep
  subexpressions and closures bound to `const`s in the hoisting list, flat `else if` chains.
  Budgets sit at least 2.5× under the scarcest browser; source nesting past them (about 120
  nested functions, a view about 65 levels of `List.map` deep) is `nesting_too_deep`, naming the
  declaration.
- The review caught two refusals of programs that built before and load in every browser: a
  TEA-style `view` with a `List.map` per level was refused at 20 levels (lambda bodies did not
  count toward their parent's height), and a 140-term `&&` of statement operands. Both fixed,
  with fixtures checked in Chrome, Firefox and WebKit.
- Evaluation order unchanged across about 60 generated probes against 7ae452f. No existing golden
  moved; emit ≈ +1 %; output size unchanged after brotli.
- New: CK-87 (derived `==` past 32 nested record levels is `internal`) → R8a; CK-88 (a `case` of
  many literal branches emits in O(n²), and past 65 046 a `switch` SpiderMonkey refuses) → R12.
- Gates green; `test-pending` 69 + `test-pending-perf` 8 RED, 0 GREEN.

**What I learned**

- For a browser-first language the refusal thresholds are a product decision, not a detail: the
  first version refused ordinary UI code. Test a new limit against the code users will actually
  write (a generated `view`), not only against the synthetic extreme.

## 2026-09-25 — R3: interface v3

**What I did**

- `checker-v2.md` §14.2 is live on v1. Type arity is `u16` (CK-38; a new `too_many_type_parameters`
  at the 65 536th); record-alias constructor rows carry their field names, so an imported alias
  constructor builds a record in expressions and patterns (CK-39, and R1's refusal is gone); each
  exported nominal type publishes `payload_params` and a derived `eq`/`compare` row with a status
  vocabulary settled in the spec first; `Schemes.Writer` uses epoch marks (CK-41, ratio 3.69 →
  1.50). Interface bytes v3 and digest v2; an old cache is rejected.
- The cross-module wide-evidence path (A.87) is exercised for the first time: a 4 097-parameter
  type compared across modules threw on 3487c12 and now works cold, warm, `--release` and after
  edits.
- CK-41 is the first timing scenario to turn green. My decision: fixed timing scenarios live in a
  new `test-perf` step on the ReleaseFast compiler, which I run with `test-pending-perf` before
  every commit, not in the Debug gates.
- The review caught a missing `payload_params` bit for a parameter reached through a schema type,
  the unsafe direction for D10 and already written into the cached record; fixed with a red test.
  CK-89 (derived rows only exist for exported types, yet importers compare private types reached
  through `pub` schemes) → R8a, spec amendment first.
- Gates green; `test-pending` 67 + `test-pending-perf` 7 RED, 0 GREEN; `test-perf` 1 GREEN.
  Check phase −0.6 %.

**What I learned**

- Data published for a future reader is still published: a wrong bit nothing reads yet sits in
  every cache entry. Review it as if the reader already existed.

## 2026-09-25 — R4a: the v2 harness; v1 is frozen

**What I did**

- R4a landed everything around the new checker with v1 unchanged: v1's scheduler, core gate and
  cutoff protocol moved (a pure move, checked line by line) into `src/check2/Check.zig`,
  `Driver.zig` and `Incremental.zig`; a hidden `--checker=v1|v2` (v2 checks the app package's
  modules, v1 core and dependencies); the checker id in every module's cache key (`key_version`
  3), with a test that neither checker reads the other's cache; a v2 stub reporting
  `not_implemented` ("checker v2: R4b"); and `zig build test-v2`, the corpus in report mode
  under v2 with the `v2-green.txt` ratchet (seeded with the 143 fixtures where v2 correctly stays
  silent on an already-poisoned module) and a validated `v2-expected.md`.
- The review confirmed v1 byte-identical over 397 fixtures in five modes, and 0aedf0a's own
  cache, cutoff, matrix and determinism tests pass against the new binary. It found that the
  ratchet files accepted lines naming no fixture; now refused, and every listed line must be
  visited.
- Owner decision: master need not keep working during the conversion. I kept v1 only as the
  oracle (it checks `core` and dependencies, which use dispatch v2 cannot check before R6–R8, so
  without it no program builds and the ~740 corpus goldens go dark) and froze it: no more fixes
  on v1; it is deleted once v2 checks `core` and passes the corpus.
- Gates green; `test-pending` 67 v1 + 64 v2 RED lines; `test-v2` 297 pass / 445 fail / 13 skip.

**What I learned**

- An escape hatch in a ratchet needs the same validation as the ratchet: a line that names
  nothing silently checks nothing.

## 2026-09-25 — R4b: the new checker's foundation

**What I did**

- The first slice of the new checker, `src/check2/`, written from the ground up to
  `checker-v2.md`: a type store read only through `Walk` (two named successor sets), `Unify` that
  merges and never resolves or reports, frames with iterative rank adjustment and quantification,
  the annotation generality check, occurs at binders, one publication routine, one emit path with
  failure bits set by errors only. About 4 400 lines in 16 files, none over 525.
- v2 checks every root module that needs no dispatch and no obligation, now including modules
  that declare a `type` (my decision after review: their derived rows publish as `unchecked`,
  and only a `--library` build is refused, naming R8a); anything else reports `not_implemented`
  naming its slice. `test-v2`: 331 fixtures green under v2, all 313 of the subset, byte-identical
  JavaScript to v1 on the 51 green `run/`/`emit/app` programs. 20 pending fixtures claimed,
  among them CK-01, CK-04, CK-07, CK-13, CK-57 and two v1 defects R4b found: CK-90 (a `let`
  pattern binding outside its group's edges, accepted ill-typed) and CK-91 (v1's solver guard
  silently dropped constraints past ~4 200 `let` bindings).
- Two reviews. The structural one found a six-line program that hung v2 (unification recursing
  through cycles, exponentially through records); the adversarial one found the same root
  reporting infinite types as "nested 4 200 levels deep" and rejecting a valid program. `Unify`
  is now coinductive (a pair met again on the stack is assumed equal), so cyclic graphs
  terminate and unify; §7.3 records why not link-first. Also: silent defaults became `internal`,
  v2's last imports of v1's `Constrain`/`Solve` moved to shared files with a test refusing new
  ones, I2 restated and grep-tested, cycle reports in field-name order.
- CK-92, found by the adversarial review and shared with v1: a two-line program made the
  mismatch printer write 300 MB. Fixed in the shared `Render` with a per-message node budget.
  New: CK-93 (growing `let` chains quadratic) → R6a; CK-94 (`number` prints as `a`) → R13; CK-95
  (BIR lowering quadratic in a `let`'s size) → R12.
- Bench: v2 0.94× v1 on a generated 131 000-line dispatch-free corpus. Gates and all four other
  steps green.

**What I learned**

- The adversarial reviewer found no unsoundness in the new core, the first time a review of this
  checker has come back without one. The design reviews paid off; the bugs left were at the edges
  of the design (cycles the fallback lets live), not inside it.
- Two reviewers with different briefs (structure vs adversarial) found the same root cause from
  two sides, which made the fix obvious. Worth keeping for the big slices.

## 2026-09-25 — R5: obligations in the new checker

**What I did**

- v2 now checks every program without method dispatch: tuple index, interpolation, the
  `equatable` marker walk (growable, payload-descending per D10) and `?` as a deferred
  obligation with §8.1's default step. Decided spec-first where the rows live: `obls` is one new
  field of the shared `Flags` (a link into v2's `Obligations` table), `wants` stays
  `Flags.constraints`, so `Schemes.Writer` and `Render` are neither forked nor hooked. v1
  byte-identical over 1 888 comparisons.
- Claimed CK-05, 06, 16, 51, 68, CK-62's dispatch-free form, CK-09 with five members, CK-59's
  generation half; 33 claims in all. `test-v2` 593 passes; the 73 green `run/`/`emit/app/`
  programs emit identical JavaScript under both checkers.
- Two reviews again. Structural: the equatable walk flagged before it knew the answer, so one
  question could report twice, the count depending on symbol ids. Adversarial: three quadratic
  blowups (up to 33 s where v1 took 0.5 s) and one valid program rejected, a spec gap: a `?`
  pinned its whole target to the subject's rank, so a `let` helper lost its polymorphism. All
  fixed: one report per question; obligation sets as growable lists merged smaller-into-larger,
  owned rows kept apart from decided ones, a per-frame open-`?` list; I15 amended so ranks run
  from an obligation's owner to its dependants only. New CK-96–98 as `test-perf` scenarios (now
  1.12–1.90), CK-99 for the `?` case. `Solve.zig` split into `Solve` and `Decide`.
- Bench: v2 1.01–1.03× v1 on a 133 000-line corpus with obligations. All seven steps green.

**What I learned**

- The adversarial tester is worth its cost on every checker slice: again no unsoundness, but the
  performance cliffs it found (thirty seconds on eight thousand interpolations) are the kind a
  user meets first and a corpus never does.
- A rank-sharing rule written as "all variables of an obligation share one rank" is too strong;
  sharing must follow the direction of the decision.

## 2026-09-25 — R6a: the new checker resolves static dispatch

**What I did**

- v2 now types dispatching programs under `check`: `Evidence.zig` (wanteds, givens, answers,
  the canonical requirement order, each wanted paired with one `Flags.constraints` entry by
  position), `Resolve.zig` (the step by receiver root: attach to a flex, the `number` bridge for
  flex and rigid, the given or a precise `missing_where_constraint` on a rigid, lookup on a
  structure), and one derivability verdict in `Instances.zig`. `build` of a dispatching module is
  still refused (R6b); an own untyped method used early is R7's; own derived contexts R8a's.
- Claimed CK-02, 03, 09 (the dispatch half), 20, 21, 48, 100 (new: v1 left a method's result
  untied when the receiver was learned later) and 101 (new: v1 overflows its stack on alternating
  `eq`/`compare` cycles); 47 claims. `where` blocks byte-identical to v1 on 471 interfaces.
  Bench 1.02× v1 on a dispatch corpus.
- Three review rounds, as expected for the part v1 got most wrong. Round 1 structural: `==`
  accepted on a function-holding type because three functions answered "can T derive eq" and
  disagreed; a recursive walk that overflowed; a memo that shared one instantiation of a
  polymorphic method; evidence order left for R6b. Two of v1's six root causes were creeping
  back. Fixed structurally: one iterative `(node, method)` verdict, no shared instantiations,
  canonical order at creation, every silent drop now `internal`. Round 2 found the lineage rule's
  premise false (a `where` can constrain another parameter), rejecting valid code as an infinite
  type; §9.5 corrected and the rule replaced by a real cycle test plus the reporting budget. The
  harness now kills a crashing child at Zig's crash banner so crash signatures do not race.
- All seven steps green.

**What I learned**

- On this slice the reviewers mattered more than the tests: the unsound `==` was found by reading
  code, not by the adversarial probes, and the false-cycle rule came from a false sentence in the
  spec. A design premise needs a counterexample hunt as much as code does.
- The six-root-cause table was a useful acceptance check: asking the implementer to fill it in
  made the regressions in #2 and #4 visible as regressions, not local bugs.

## 2026-09-26 — R6b: the new checker builds dispatching programs

**What I did**

- P6 elaboration (`check2/Elaborate.zig`, with `Unit.zig` for the DAG writer) builds the §13
  evidence tables from v2's answers, reading only what was recorded when each requirement was
  created; P5 (`Eager.zig`) writes v1's eager derived rows under v1's one-entry-per-parameter rule
  until R8a. `build --checker=v2` works for dispatching programs: every `dispatch/` golden is
  v1's byte for byte, 351 of 351 `run/`/`emit/` builds give identical JavaScript, and 60 pending
  fixtures are claimed (CK-08, 27, 28, 29, 32, 62 and the `run/` halves of CK-30, 31, 66, 67).
- §13.1 now allows shared terms (a DAG); the shared `checkI7` and `Edges` judge each term once,
  which kept CK-80 and CK-101 linear in `check`, and `Lower` binds a shared evidence closure to one
  `const`, which fixed CK-80's `build` half (JavaScript 474 KB → 3 KB at depth 12).
- The adversarial review found no wrong answer at run time across 823 old probe projects and
  hand-written non-structural `eq`/`compare`; v2 builds 91 programs v1 cannot. Both reviews found
  `[ [] ] == [ [] ]` failing `internal` under v2 (the `undetermined` leaf written outside a derived
  ancestor), now fixed, with `checkI7` checking the leaf's placement. New CK-103 (v1 hands an
  `eq` to a `compare` slot; latent, only ever applied to empty values) and CK-104 (a derived row's
  body naming a later declaration was not in emission order, so both checkers built a program
  that threw `ReferenceError` at load; fixed in the shared `Edges`).
- I accepted one change to the frozen v1 through shared code: the placement rule makes v1's
  `check` refuse CK-103's shape, which it used to compile into code that worked by parametricity.
  The fuzz and probe sweeps showed no other v1 result moving, and v1 is deleted at R12.
- Bench: `check` 1.02–1.04× v1, `build` 1.05–1.06×. All seven steps green.

**What I learned**

- "Identical to v1 on every corpus golden" is evidence about the corpus, not the rule: the
  `undetermined` placement bug had no corpus fixture. The fuzzer found it in 17 of 340 programs;
  keep a fuzzer in the adversarial brief.

## 2026-09-26 — R7: own methods without a scheme, merged groups, order independence

**What I did**

- Priority groups and `method_needs_annotation` for ordering are gone from v2. A use of an
  unchecked own group checks it at once in a fresh frame (`Groups.zig`, nesting at demand, with a
  cumulative budget; `nest_cost` = 3, measured at about 15 KB of stack per Debug nesting of a
  reverse-ordered chain, so ~600 deep); a back-edge merges top-level frames, which hand their
  pools, binders and queues to one root and generalise once; every frame has its own ready queue.
  D14 lowers group-level receivers in recursive groups, and its hint is computed at the class
  root from the source only. Queue row 75, where this rewrite began, is closed here (CK-36).
- The contract is I9. `scenario/PERM` checks 48 programs over 2 796 declaration orders; the
  reviewers' fuzzers ran ~63 000 more orders with no difference in acceptance or output.
- Three review rounds. The adversarial fuzz found order dependence the implementer's own scenario
  missed: `x.combine 1` became a field call or a method constraint depending on which fact
  arrived first (also in plain value recursion), and the D14 hint named different members by
  order. The structural review found a merge during the root's boundary losing members; round 2
  found a joined dot-call/`where` requirement inheriting a field answer (internal error).
- Owner decisions (2026-09-26, all yes): a dot-call whose receiver becomes a record before the
  constraint is generalised is a field call (spike §11 *Deferred receiver*); I9 promises
  acceptance, types and output, not the exact error set of a refused recursive group; and at
  R14 a `let` whose requirements are only dot-calls stays monomorphic.
- New CK-105 (field call vs method by order) and CK-106 (a `number` receiver's method in a
  recursive group was `internal`, also in v1). 99 claims. Bench 1.08–1.09× v1, little headroom.

**What I learned**

- A permutation scenario written by the implementer proves the cases the implementer thought
  of. A random generator with every order of every program found the field-call hole in minutes.
- Some order dependence lives in the language rule, not the code: the old spec text itself
  decided by "already known". Fixing I9 needed a language decision from the owner.

## 2026-09-26 — R8a: one derived-context computation

**What I did**

- v1's root cause #4 ("can T derive eq/compare", answered 4–5 ways) is closed in v2:
  `check2/Contexts.zig` runs one joint eq+compare fixpoint per type-level SCC; `Derivable.zig` is
  the one verdict reading it; interface v4 publishes each row's context as `(param, method,
  slot)` triples plus rows for private types reachable from published terms (CK-89); a cache hit
  installs rows and recomputes nothing. R6a/R6b's stopgaps are deleted, including
  `refuseV2LibraryTypes`, so `--library` works under v2. D4: a derived function takes one
  evidence parameter per context entry. Also CK-40 (schema settling linear), CK-79 (field cap
  lifted), CK-85 (a `where` value memoised per evidence identity; the promise narrowed in
  `language.md` §6), CK-87.
- Reviews: the structural one found the fixpoint dropping a payload's `equatable` requirement, so
  v2 compared functions and printed `True` (CK-108); both found a `u16` evidence index panicking
  past 65 535 (CK-109, widened end to end). The adversarial review's ~1 800 fuzzed programs gave
  0 wrong answers; v2 accepted 163 programs v1 refuses. My perf run flagged CK-42 as regressed;
  20-run perf stat showed noise (2.16 vs 2.18).
- New CKs 107–117, among them CK-111 (quadratic nested-record `==` per use) and CK-114 (a record
  literal 2 100 deep refused), for a performance slice I am adding before R9; CK-117 records that
  §11.2's "nothing escapes a fixpoint frame" is false when a pass demands a group that merges.
- Bench (whole process, perf stat): v2 1.07× v1 on both generated corpora.

**What I learned**

- Measure a small ratio of differences with many runs before calling it a regression: the
  scenario's 7 ms difference turned one noisy run into a false alarm.
- A proposed invariant assert that fails on real fixtures is information, not an obstacle: it
  showed a spec claim was false, which is now a CK instead of a comment.

## 2026-09-26 — R8b: private methods (D1) and schema endpoints

**What I did**

- D1 end to end in v2: a private method answers dispatch only inside its own module; reached from
  another module, directly or through any wrapper and across any number of modules, it is
  `private_method` naming the type that hides it (interface v5 row status). ~60 hand probes and
  2 364 fuzzed comparisons found no hole. Schema endpoints go through the same derived-context
  fixpoint, and v1's schema property settle is gone from v2's path, fenced by `rules_test`.
  `plans/checker-rewrite.md` gains §1.1, the six-root-cause table with status by slice.
- Three review rounds again. Round 1: the lazy `via` join was exponential and ended in a false
  refusal (rings of schemas: 16 s, 1.3 GB, then "does not support =="), and v2 panicked on a
  definition followed by a separate `where` annotation. Round 2: the equality gate read an
  unchecked schema's unfilled `via` target as "no function", so `Basics.eq` on a function-holding
  type was accepted or refused by declaration order, and a heavy comparison elsewhere could spend
  an unrelated one's step budget. Fixed: an exact unit graph built from what each comparison
  reaches, a deferred gate checked in P5 once every group is done, a budget per fixpoint run.
  PERM (71 programs, 4 506 orders) now checks refusals by exact diagnostic count.
- New CKs 118–125; CK-122 (a `type alias` of a schema endpoint gives `internal` in both checkers)
  goes to a small follow-up before R8c, CK-123 (a polymorphic `via` target leaks a type variable)
  to the schema slices, CK-124 (frontend quadratic in schema count) unassigned.
- `test-pending-perf` failed once in five runs on `scenario/CK-42` under v2: its extra cost is
  8–10 ms, so the ratio is noise around the 2.5 bound. Added to R8c's scope. Bench 1.04–1.06× v1.

**What I learned**

- Two rounds found order dependence that the permutation scenario missed because it only checked
  that a refusal code appeared. A test that checks "some error" instead of "exactly these errors"
  hides the very bugs it is meant to catch.

## 2026-09-27 — R8c: performance and limits (and CK-122)

**What I did**

- CK-122: a `type alias` of a schema endpoint was read as a silent `err` by the shared alias
  reader, giving `internal` on `==`, a false refusal through a wrapper, and in both checkers
  `r + 1` on the alias checked. Fixed in `Types.Builder.aliasBody`; CK-126 (a private record
  schema reached through another module's `pub` alias) stays pending.
- Performance, each change measured: rank adjustment answering leaves at once and successors in
  the parent's frame, pool compaction, Unify's bounded pair scan and flex-flex fast path, P6 maps
  only with evidence. CK-93, 111, 112 and 114 fixed with `test-perf` scenarios (CK-111: 44 s →
  0.5 s). The CK-42 v2 twin resized so it measures.
- The two proof-keeping shortcuts (CK-93's stamps, CK-111's inherited proofs) were unsound: round
  1 found a cycle escaping the occurs check through an `err` overwrite; round 2 found two more
  holes, both through `err`, one accepting an infinite type with exit 0. Now one mechanism:
  acyclicity proofs in the shared `TypeStore`, voided on any write that could add an edge, with
  the broad `err` rule the reviewer verified (my choice over a narrower rule argued sufficient),
  and a Debug detector that re-walks from every trusted proof. 20 500 fuzzed programs: 0
  differences, 0 panics.
- Owner decision: CK-128 (derived `==` on deep data throws `RangeError`: a user linked list at
  ~8 900 cells) is fixed as Elm does, in R8d, with black-box tests.
- Bench: v2/v1 1.03× (plain) and ~1.055× (dispatch) in cycles; R8c's own 1.05× target missed by
  choice for the broad rule; R9's budget is 1.10×.

**What I learned**

- Performance shortcuts that keep a proof beyond its walk are where soundness breaks: three
  review rounds, three holes, each behind an argument for why a narrower condition sufficed. When
  a soundness argument has already failed twice, take the verified rule and pay the cost.

## 2026-09-27 — R8d: derived == and compare do not grow the native stack

**What I did**

- CK-128, the owner's decision: derived `eq`/`compare` must not throw on deep data (a user linked
  list threw `RangeError` at ~8 900 cells in node). Derived functions that can recurse carry a
  depth and, past 400 units, continue from a generator twin driven by a small per-module engine,
  so the native stack no longer grows with the data. Evaluation order and short-circuiting are
  exactly the recursive version's (a 4.6 M-line ordered-call-log fuzz against e86883a matched).
  3 × 10⁶-cell lists compare in Chrome, Firefox, WebKit and node. Stated exclusion: recursion
  THROUGH a hand-written parametric method still grows the stack, pinned by an abuse test.
- Black-box tests, red before: `run/DerivedDeepData`, `DerivedDeepPaths`, `DerivedDeepOrder/`,
  `DerivedDeepAcrossModules/`, and three abuse scenarios (a 4 095-deep record literal, 4 096- and
  4 097-parameter recursive types, the exclusion).
- Cost: shallow recursive-type comparisons 11–20 % slower in node; release brotli +2.5 % across
  the size corpus. The reviewer found a better shape (a tail self-call becomes a loop; depth only
  on real recursive cycles; one shared engine), which should make recursive types faster than
  before R8d and halve the size cost: the next small slice, R8e.

**What I learned**

- A fix can be correct and still be the wrong shape for a browser-first language. Asking the
  reviewer to price alternatives turned a 20 % regression into a likely net speed-up.

## 2026-09-27 — R8e: deep-safe comparisons, cheaper than before

**What I did**

- The reviewer's alternatives to R8d's shape: a derived function's tail self-call is a loop, so
  list-like types need no depth or twin at all; types whose depth-taking calls are all in tail
  position (`Maybe`, `Result`, wrappers) only forward the depth; one runtime file,
  `_core/_derived.mjs`, is written only when imported, replacing the per-module engines, and
  `core/List.js` is back to its pre-R8d bytes.
- Against e86883a (before R8d): user lists 51–61 % faster, trees 11–15 % faster, a rose tree
  through `List` 3.5 % slower (the one real remaining cost); release brotli +1.1 % across 164
  programs (R8d was +2.5 %), 144 of them byte-identical in dev. A 5.2 M-line ordered-log fuzz
  matched e86883a exactly. All seven steps green.
- Owed: the dev and `--release` copies of the runtime are kept in step by hand, tied only by the
  `run/` corpus running both.

**What I learned**

- The loop form beat both the old recursive code and the stack-safe version: removing the
  problem's cause (recursion on a tail) was better than managing it.

## 2026-09-27 — R9: v2 checks every package, core included; test-v2 strict

**What I did**

- `--checker=v2` now checks `core`, the platforms and every package, so every record a v2 build
  reads is v2-written and the v1-ABI fallbacks are deleted. `test-v2` is strict (the ratchet is
  gone; only `v2-expected.md` entries skip), and the determinism, 600- and 5 000-module scenarios
  run under v2. `key_version` 4.
- Checking `core` under v2 found CK-130: the module rule answered `Basics`' own types from its
  own `eq`/`compare` before asking the well-known table, so `LT < GT` failed in other modules.
- The review confirmed `core`'s interfaces and types byte-identical under both checkers (only
  R8b's `no_function` bit differs) and `bench/corpus`'s JavaScript identical except one A.18
  `===` for an all-nullary field; a 56-line probe over every core comparison API matched v1 in
  dev and release.
- One exit criterion missed and deferred by my decision: `s_tup6000` checks at ~1.6× v1 against
  the 1.10× budget (CK-131; it was 1.89× before R9 and unmeasured since 2026-09-24). New slice
  R9b before R11. `bench/corpus/DictExtra.beni` rewritten: it compared a rigid `v`
  structurally, which v2 rightly refuses.

**What I learned**

- A benchmark nobody re-runs stops being a budget. The tuple scenario drifted to 1.89× over four
  slices because every slice measured the generated corpora instead.

## 2026-09-27 — R9b: tuple comparisons back within budget (CK-131)

**What I did**

- `s_tup6000` (`( a, [ b ] ) < ( b, [ a ] )` × 6 000) went from 1.60× v1 to 1.06–1.10×: table
  primitives answered at once, v1's plain-method fast path ported, a dense ground-derivability
  memo, a per-module derivability memo keyed by type structure, P6's small-unit memo inline. A
  byte-for-byte differential over 656 fixtures, `core` and both bench corpora matched 919f8be. I
  had a cycle-test skip reverted (≈1 %, resting on an argument) and a rollback guard added to the
  two memos keyed by variable ids.
- R9's review leftovers: filtered determinism binaries assert their test counts; a
  `v2-expected.md` fixture that starts passing fails the step; one statement of the §3.2 table.

**What I learned**

- The last few percent after a round of real wins tend to come from shortcuts that rest on
  arguments; decline them unless the walk itself proves them.

## 2026-09-27 — R10: incrementality under v2

**What I did**

- Every cache, cutoff, matrix and digest scenario now runs under v2 too (whole files in
  `test-v2`); the cutoff table pins re-checked/cut-off counts, identical under both checkers.
  New scenarios: adv's k1–k8 cache probes, and four edits that move a dependency's derived
  context (a function payload, a `where` on a payload's `eq`, `pub`↔private, a schema `via`
  target), each warm build byte-identical to a cold one. A new `derived_context_runs` counter
  proves I10: a cache hit runs no fixpoint.
- v2's cache path needed no fix. CK-107 fixed (`dispatch_bytes` writer quadratic in types).
  New CK-132, v1 only: a private `eq` added moves no hash, so v1's warm check misses a
  `private_method` its cold check reports; frozen, gone at R12.
- Committed on my own gate run without a separate review: tests plus one byte-preserving fix.

## 2026-09-27 — R11: the cut-over — v2 is the default checker

**What I did**

- `--checker` defaults to `v2`; the three gates run the new checker. `test-v2` is deleted (it is
  now `test-blackbox`), with its filtered binaries and `v2-expected.md`; the hidden
  `--checker=v1` survives only for scenarios that name it, until R12.
- All 119 claimed fixtures promoted from `tests/pending/` into the corpus; 70 `.codes` turned
  into blessed `.diag`s, each checked line by line against its `.codes` by script. 20 goldens
  re-blessed one at a time, each with its CK or D reason (table in the R11 As built). PERM and
  the nesting scenarios moved to a new `tests/blackbox/ordering_test.zig`.
- `tests/pending/` holds 13 red fixtures: 12 message-quality ones for R13, CK-126 for the schema
  slices; `scenario/CK-88` for R12. Pointer notes in `checker.md` and the spike now say
  "superseded", except the two D5 notes that stay normative until R14.
- Bench check phase 1.01× v1. Committed on my own gate run; the reason table is the review
  evidence the plan asked for.
- `CLAUDE.md` is now stale in five places (v2 as default, the pipeline description, items 3–5 of
  "Owed after the static-dispatch adoption", rule 1's contract list); I asked the owner.

**What I learned**

- Seven black-box scenarios still asserted v1 behaviour because only `test-v2`'s subset ever ran
  them under v2. A parallel harness proves what it runs, not what it skips.

## 2026-09-27 — R12: the old checker is deleted

**What I did**

- v1 is gone: `Solve.zig`, `Constrain.zig`, v1's `Check.zig`, the capability code in `Types.zig`,
  the flat dispatch builder, `--checker`, `BENI_CHECKER`, the checker id in the cache key
  (`key_version` 5). `src/check2/` is now `src/check/` (git mv); three files over 1 500 lines were
  split; `rules_test` fences every file with a 1 500-line cap. Scenarios that existed to compare
  the checkers were deleted or folded.
- CK-88 (a `case` of many literal branches: quadratic, and one `switch` past SpiderMonkey's limit)
  and CK-95/127 (lowering a big `let`: quadratic) fixed with perf scenarios red before; CK-133
  (a Debug-only re-walk budget) fixed.
- Final numbers, check phase against `7427828` (the commit the rewrite started from), medians of
  five interleaved rounds: plain 92.98 → 101.05 ms (1.087×), `--dispatch` 101.05 → 113.38 ms
  (1.122×, over the 1.10× line: CK-134). Whole-process user cycles: 1.06× and 1.10×. The new
  checker does strictly more (occurs at every binder, generality checks, one derived-context
  fixpoint, deep-safe comparisons) and fixes ~130 catalogued defects; the gap is CK-134's.

**What I learned**

- Compare against the baseline the budget names. R11's "1.01×" compared both checkers inside
  R11's binary, which hid the drift from `7427828` that R12's measurement exposed.

## 2026-09-27 — R13: diagnostic quality

**What I did**

- Every message finding closed spec-first (`checker.md` §8.7, spike §10.13 and amendments):
  CK-49, 50, 52, 53, 54, 55, 56, 58, 59, 60, 86/129, 94 (`number` variables named by kind, in
  messages and interfaces), 116 (a failed payload requirement is reported as itself, not as "a
  function anywhere inside", carried on answers and a new published `requirement` row;
  interface format 6), and the deferred-record redraw R11 noted. All 12 pending message fixtures
  promoted; `tests/pending/` now holds only CK-126 (schema slices). CK-115 did not reproduce; a
  guard fixture holds it. Each re-blessed `.diag` names its CK.
- Committed on my own gate run; R15's audit covers this slice's checker changes.
- Open doubt: articles are chosen by the first letter ("an `url`"), as the spec now says.

## 2026-09-27 — R14: constrained `let` helpers generalise (D5); the cross-language comparison

**What I did**

- D5 landed: a `let` function binding generalises over the requirements everything it reaches
  owns, and takes evidence parameters (`$l<inst>$<k>`, the `lets` column of the dispatch table),
  so `let same a b = a == b` works at two types, also inside lambdas and branches. Kept
  monomorphic: a `let` whose variables carry only dot-calls' own requirements (the owner's
  2026-09-26 decision), value and pattern bindings (a value restriction I confirmed: it keeps
  `let` bindings evaluated once), and a helper over the 64-requirement cap (held with a hint,
  never refused). CK-02's outer-receiver program stays refused. The review found both rules
  wrong in the first cut (lets below a lambda never generalised; over-cap helpers refused);
  fixed with fixtures.
- `bench/compare/` (`f38eb30`): three pure-logic programs ported to beni, Elm, Gleam, Roc and
  PureScript, duplicated into N modules, checked cold on one core; cost per copy: beni 3.2 ms,
  Gleam 12.4, Elm 14.0, Roc 24.0, PureScript ~1 200 (its exhaustiveness checker on one deep
  pattern). Per token: Gleam 2.5×, Elm 4.3×, Roc 5.7× beni's time.
- My mistake: that commit first swept in two of R14's staged fixture moves; I redid it within a
  minute with `git commit -- bench/compare`. Use path-limited commits while an agent has staged
  work.

## 2026-09-27 — R14b: the new checker is faster than the old one (CK-134)

**What I did**

- CK-134 closed: the bench's check line is 0.76× `7427828` on `--dispatch` and 0.72× on plain
  (it was 1.10× / 1.06× at `881e23d`); whole-process user cycles 1.01× / 0.98×. The largest cost
  was invisible to user-cycle profiles: every module's type store mapped and unmapped its own
  pages, so page faults (R9's 3-variables-per-instruction reservation) dominated the wall-clock
  line. The store now lives in the worker's reset scratch arena. Also a stamped memo for
  imported instantiations, rank adjustment skipping roots an earlier walk already reached, and
  small inline fast paths — each measured on its own and as an ablation; nothing resting on a
  soundness argument. A differential over 56 365 output files was byte-identical to `881e23d`.
- Committed path-limited: the compare-bench agent's files are in the same tree.

**What I learned**

- Profile the metric the budget names. Every slice since R8c measured user cycles; the bench's
  wall-clock line was paying for page faults nobody's profile showed.

## 2026-09-28 00:47 CEST — R15: the audit's findings, red first, and the first two fix slices

**What I did**

- Collected the four R15 audits (core, dispatch, orchestration, adversarial) and had one agent
  turn every finding into CK-135…CK-168: 22 behavioural ones with a red fixture or scenario in
  `tests/pending/`, 12 structural ones catalogued without (`071cc0b`).
- Saved the broad perf study as `plans/perf-study-2026-09-27.md` (`1bec73c`).
- Landed R15-fix-B (`7fdf8a2`, `34c3cd6`): the printer brackets any arrow body or statement
  whose leftmost printed token is `{` (CK-138); shared evidence is judged once per term and the
  dispatch dump prints a shared term once as `#n` (CK-136, 48 s → 5 ms); one emit specifier
  table per importer depth (−10 % cycles, −54 % page faults, output byte-identical).
- Landed R15-fix-A (`763b7c8`): the plain-method memo is keyed by every input of its verdict,
  type included (CK-137, the unsound one); a `poisoned` wanted state for rejections against
  `err` (CK-141); arity mismatch and alias self-expansion build `err` (CK-139, CK-140);
  explicit-stack `orderWalk` (CK-135); derived-row templates publish through the one
  `Publisher` (CK-142).
- The generated cross-language benchmark finished a first full run (uncommitted, awaiting a
  fairness review and a quiet-machine rerun). A read-only reviewer is on both fix slices.

**What I learned**

- The one unsound finding was a memo key that omitted an input of the verdict it cached. When
  a memo is added, its key should be "everything the computation reads", reviewed as such.
- Parallel fix agents in worktrees plus a separately built baseline binary proved
  fixture-first without the shared stash stack, which is unsafe across worktrees.
- A usage limit killed three agents mid-slice; SendMessage resumed each from its transcript
  with nothing lost.

## 2026-09-28 08:44 CEST — R15 fix slices C–H, the compare benchmark committed

**What I did**

- Landed R15-fix-C (alias chains without a silent cap; alias DAG expanded once; every `err`
  reported, enforced in Debug by `assertErrorsReported`), R15-fix-D (CK-126, 143, 145, 147,
  148), R15-fix-E (CK-154, 159, 162, 168; CK-161's message), R15-fix-F (linear resolve and
  lower, parser depth as a max, wide-sum exhaustiveness, `_manifest.txt` for a clean
  `--out`), R15-fix-G (injective aliases for CK-175, alias names kept, cycles before
  mismatches, poisoned payloads) and R15-fix-H (a `--release` miscompile on alias chains past
  128 fixed by path-compressed substitutions; a 64-slot walk in foreign check 1; the manifest's
  case fold and header).
- A read-only adversarial reviewer ran after every pair of slices; each round found something
  (a silent `err`, a phantom-alias I9 break, the release miscompile), which became the next
  slice with red fixtures first.
- Committed the generated cross-language benchmark (`17a42d0`) and its first clean run
  (`60a9558`): CPU ms per unit, beni 6.1, Gleam 22.2, Elm 27.4, TypeScript 39.6, Roc 92.6,
  PureScript 1004. A fairness review found no bias in beni's favour; Roc's compile-time
  evaluation and Elm's 128 MB nursery are disclosed.
- The owner decided CK-161 (dot-call reaches a derived eq/compare) and CK-179 (alias names in
  inferred types: agree or expand). R15-fix-I implements both, plus the residues.

**What I learned**

- Budgets that run out into an answer are the recurring defect class: 1024 in
  `TypeStore.resolved`, 64 in `Printer.resolve` and `Emit.firstTypeVar`, 512 in
  `orderWalk`. The rule now written into checker-v2 §12.2 and backend.md §9: a budget may
  only decline an optimisation or report a diagnostic, never yield a result.
- `7fdf8a2` is a red commit (fixtures promoted one commit before their fix). Every later
  slice was told: red fixtures stay in tests/pending until the commit that fixes them.
- Parallel slices in worktrees need disjoint source directories; the plan documents always
  conflict and always merge by keeping both sides.

## 2026-09-28 10:05 CEST — History rewritten before the first push of R15

**What I did**

- Squashed `7fdf8a2` (which promoted two fixtures one commit before their fix, so it failed
  the gates on its own) into R15-fix-B, then pushed `master`. The tree is byte-identical;
  only the hashes after `1bec73c` changed. Hashes quoted in earlier entries, in
  `plans/checker-rewrite.md`, `plans/checker-findings.md` and in
  `bench/compare/results/2026-09-27.json` (`beni_commit`) refer to the old ones:

  | old | new | commit |
  |---|---|---|
  | 7fdf8a2 + 34c3cd6 | 4563484 | R15-fix-B (with the emit specifier tables) |
  | 763b7c8 | 4f72a7e | R15-fix-A |
  | 346268b | 718fb4c | diary |
  | 17a42d0 | bbb08ea | compare generator (the benchmark's beni) |
  | 60a9558 | 1c8588a | compare first run |
  | 830e547 / 669826f | ce16243 / c474673 | R15-fix-C red / fix |
  | 01d0f21 | 83918e1 | R15-fix-D |
  | 8a68e12 | 5a90894 | R15-fix-E |
  | 31dd4bd | 5ebd0c1 | R15-fix-F |
  | 88256a3 / 6434900 | 6c54e1a / 7fb9172 | R15-fix-G red / fix |
  | c175745 / 3984c7c | 8c8937b / 275b203 | R15-fix-H red / fix |
  | 443a88b | f1aa9c3 | diary |

**What I learned**

- Rewrite before the first push, never after: nothing outside this machine held the old hashes.

## 2026-09-28 16:32 CEST — Fast tests, plain commit messages, the history rewritten

**What I did**

- Tests: the black-box suites run a ReleaseSafe beni; stress sweeps were deleted or cut to just
  past the limit they reach; the acceptance matrix and the under-load spinner test were deleted
  in favour of a few hand-picked tests; tests run as sharded processes; `zig build gates` runs
  the three gates in one graph; `-Dquick` (self-hosted backend), `-Dcorpus`,
  `-Dtest-filter` and per-file steps give the testing tiers now written in CLAUDE.md; every
  worktree shares the main checkout's Zig cache; worker pools are sized by the source there is.
  Warm gates went from about 5 minutes to 13–25 s; `zig build test-time-report` measures it.
- Scrubbed internal plan codes from code comments, test names and design documents, and
  rewrote every commit message in the repository (404 commits) to plain, whole-line subjects
  with no trailers, then force-pushed master. Hashes quoted in earlier entries and in plans/
  refer to the history before this rewrite.
- Investigated the cross-language benchmark's Roc figure: fair as measured, but `roc check`
  spends only a third of its time type checking; the README now says so.

**What I learned**

- The gates were bound by total CPU, 40% of it kernel time from thread pools sized to the
  machine instead of the work; one sweep test had asserted nothing for its whole life.
- The owner wants tests that reach specific branches, not matrices; commit messages, comments
  and docs readable without the plans; and agents that climb test tiers instead of re-running
  full suites.

## 2026-09-28 18:02 CEST — the last sweeps out of the gates

**What I did**
- `ordering_test`: ran all 73 permutation programs, five orders each, on compilers built
  from before each fix. Most failed in their written order (the corpus walker's own case),
  a few only in the order a twin fixture already holds, some never. Seven failed only
  reversed; each is now one test writing that order, red on the pre-fix compiler.
- `frontend_test`: the identity oracle's tokens/ast/fmt runs never reached the round trip
  (it runs where lowering ends) and its `check` runs loaded the cache instead of
  round-tripping. Replaced by one source filling every artifact section and one type error
  pinning token and line starts, each red with its section corrupted.
- `cutoff_test`: one edit per input of a module's key — own terms, an import's hash, an
  import's digest — instead of nineteen edit classes in four quarters.
- `abuse_test`: 39 → 19 tests; duplicates of `parse/bad`, `check/depth` and
  `run/DerivedDeep*` deleted after breaking each guard showed both went red together. The
  4 096/4 097-parameter recursive types recursed in the last position, looped, and never
  reached the depth limit; they now recurse first and fail when the guard is broken.
- Gates test-process CPU on the self-hosted beni: 607 → 410 CPU-s (loads 12.7 and 8.6 at
  the start).

**What I learned**
- Replaying a regression sweep on the compiler from before each fix is cheap (Debug builds
  of old commits, a probe test) and says exactly which order each program needs.
- A sweep can pass for its whole life without reaching the code it names: check that
  breaking the guard turns it red before trusting it.

## 2026-09-28 19:00 CEST — line coverage with kcov

**What I did**
- Added `zig build coverage` (not a gate), from the `nix develop .#coverage`
  shell that adds kcov. A child `zig build coverage-run` builds an LLVM
  ReleaseSafe beni that keeps its debug info, points every black-box suite's
  `BENI_EXE` at a small Zig wrapper (`tests/coverage_wrapper.zig`) that
  replaces itself with `kcov --collect-only … <beni> args…`, and runs the
  unit tests (LLVM, same mode) under kcov directly. `tests/coverage.zig`
  merges the per-process directories in parallel batches with
  `kcov --merge`, even when a test failed, and writes
  `zig-out/coverage/` plus `summary.md` (total, per directory, per file),
  leaving the tests' own lines (`*_test.zig`, `test` blocks) out of the
  figures. `-Dcorpus` and `-Dtest-filter` narrow it.
- The harness's time limits scale with `BENI_TIMEOUT_SCALE` (pinned empty
  in the gates, 20 under coverage): two abuse tests with 3 s limits failed
  under kcov before it.
- First full run: 94.1% of 23 718 counted lines; 11 min wall, 9 100 CPU-s,
  3 214 processes, quiet machine.

**What I learned**
- kcov (elfutils) reads no line table from the self-hosted backend's output
  for beni, though it reads a two-file hello; an LLVM Debug build marks an
  untaken `if` body as run (the jump that skips it carries the body's
  line); LLVM ReleaseSafe was accurate on the spot checks, counts fewer
  lines (folded code is in neither count) and runs about fifteen times
  faster under kcov than LLVM Debug.
- The black-box harness gives the compiler an empty environment, so the
  wrapper carries every path baked in at build time.

## 2026-09-28 20:58 CEST — coverage from LLVM block guards, without kcov

**What I did**
- Replaced kcov in `zig build coverage` with SanitizerCoverage
  `trace-pc-guard`. The instrumented LLVM ReleaseSafe beni's root is
  `tests/coverage/runtime.zig`: the module constructor maps one shared
  hits file (a process count, then a byte per guard) and the callback
  writes a guard's byte the first time its block runs, so a process that
  panics or is killed keeps its hits (checked with SIGSEGV and SIGKILL
  mid-run: each kept 1 800 to 2 800 guards). A one-line C file defines
  `__sancov_lowest_stack`.
- Wrote the report in Zig: `tests/coverage/x86.zig` (a length and
  control-flow decoder, whose instruction boundaries matched objdump on
  all 1 588 005 instructions of the binary's `.text`),
  `tests/coverage/cfg.zig` (per-function graphs, jump tables, calls of
  functions that cannot return, dominator and post-dominator inference)
  and `tests/coverage.zig` (ELF symbols and sections, DWARF rows through
  `std.debug.Dwarf`, `summary.md` and `lcov.info`). Dropped the wrapper,
  kcov from the flake (lcov, for `genhtml`, instead) and
  `BENI_TIMEOUT_SCALE`.
- Full run on today's master: 3.6 s wall, 68 CPU-s, 2 557 processes,
  92.0% of 22 965 lines (kcov took 12 minutes and 9 100 CPU-s).

**What I learned**
- kcov on the same instrumented binary and the same 502 processes agreed
  on 99.45% of 22 773 lines: 115 lines ran that the rules could not prove,
  10 the other way, which were rows without a statement marker or sharing
  an address with another line's.
- Two things the first graphs got wrong. A call of a panic handler falls
  through, in the machine code, into the next block, and that invented
  edge hid dominators: the tokenizer read 72.9% until a call of a function
  with no return path ended its block. And a labelled switch dispatches
  through `jmp [table + reg]` with an index already scaled, not only
  `[table + index*8]`.
- The DWARF line table names a few lines past the end of their file;
  `genhtml` refuses those, so the report drops them.

## 2026-09-29 01:34 CEST — The checker rewrite is finished; the tests take ten seconds

**What I did**

- Closed the checker rewrite: the audit's last open finding (interfaces now name aliases and
  write each body once per record, bytes linear in a chain's length), the structural clean-ups
  (dead guards and the unused undo journal deleted, a growing stack, invariant checks proven
  live, a caller-independent unify contract), and two final read-only reviews and their fixes
  (alias names agree-or-expand at every depth, the exponential alias DAG, truthful field and
  equality messages, the schema endpoint keeping its name, a safety-build quadratic, and output
  paths that are symlinks refused). tests/pending/ is empty; nothing unsound, crashing or
  order-dependent is known.
- Rebuilt the test system around speed: a self-hosted ReleaseSafe beni by default (LLVM behind
  -Dllvm), sweeps and matrices replaced by hand-picked tests, a 4 300M-instruction budget per
  test, Node skipped for verified output (0 runs on an unchanged tree), sharded processes,
  instruction-based timing scenarios, test-time reporting and block-guard coverage written in
  Zig. The gates went from about 5 minutes to about 6 s warm and 10 s after an edit; the
  testing tiers were deleted as obsolete.
- Found and fixed real defects on the way: a cache reader and every file read trapping when a
  file changes under it (a Zig 0.16 std issue; draft upstream report in plans/), a stale-binary
  false green from sharing one Zig cache across worktrees (reverted).
- The owner took the browser direction: The Elm Architecture with Solid 2's compiled JSX, Solid
  2's render loop and JSX answers, TEA possibly as a platform. Research 36 studied Solid's Rust
  JSX compiler for the port.

**What I learned**

- Every review round found something until the last; the ones that mattered came from
  differential oracles (two orders, two job counts, warm vs cold, dev vs release, two backends).
- Several "tests" asserted nothing for a long time (the acceptance matrix's dumps, most of the
  identity oracle); sweeps hide that, hand-picked tests reaching named branches do not.
- A tool that shares state across worktrees must be proven safe on this Zig version first.

## 2026-09-29 11:52 CEST — the lexer reads markup

**What I did**

- Built frontend.md §9.1–§9.3: a mode stack in the tokenizer (`tag`, `children`, `close`,
  `hole`), eight markup token kinds each re-derivable from tag and start, the operand-start rule
  for `<`, the column-1 reset, the 4 096 bound, the stray bytes in text and in tags, the spread
  rule. Front-end artifact v5. The parser reports each markup expression once as
  `not_implemented` and skips it until the markup parser exists.
- A parse fixture may now carry a `.tokens` golden; twelve markup fixtures and one
  comparisons-stay fixture use it. `bench --phases=` and `bench/markup/` measure the lexer
  alone: ~277 MB/s, ~8.1 M LOC/s on markup; markup-free lexing unchanged.
- Recorded in §9.3's as-built note the readings the spec left open (close mode, stray-byte
  length and codes, text runs raw, the newline before a column-1 break, the bound reported once).

**What I learned**

- A first cut cost markup-free code 2–3 %: a 32 KiB array field copied into every file's
  tokenizer, and markup states inflating `next`'s state machine. A local array behind a slice
  and a separate `nextMarkup` removed it. Pin to one core and interleave eleven runs; single
  runs on the small corpus vary by ±5 %.
- Strings never nest, so they need no stack entry — which keeps the string fast path exactly
  what it was.
- A `builtin.is_test` assertion that every token's re-derived end equals what the lexer
  consumed turns the property, fuzz and stress tests into a check of the two-column cache.

## 2026-09-29 14:11 CEST — the parser, formatter and lowering read markup

**What I did**

- Three lexer fixes from the lexer's review, each with a fixture that failed first: a column-1
  `--` comment inside a tag or a hole no longer ends the markup; a stray byte in a tag stops at
  the tag's own syntax (a new `markup_stray` token, artifact v6); a stray's message says where it
  stood (opening tag, closing tag or text).
- Built frontend.md §9.4–§9.7: markup and vocabulary declarations parse with recovery
  (`unclosed_element`, `mismatched_closing_tag`, `element_as_argument`), dump as S-expressions,
  format under §11.15, and lower to one `markup` instruction per tree with items, constants,
  class/style entries, components, For/Show rows and their captures and inputs. Text is trimmed as
  Solid trims it and decoded against WHATWG's table, generated at build time from htmlize 1.1.0's
  pinned `entities.json`, with htmlize's vectors as tests. Artifact v7 carries `uses_markup`.
- The checker stops a markup module with `no_markup_vocabulary` and a vocabulary declaration with
  `not_implemented`, markup typing as the error type so nothing cascades. The 22 markup codes are
  in the catalogue. As-built notes in §9.3–§9.7 record every reading the spec left open.

**What I learned**

- Markup-free lexing lost 4–5 % with the lexer's source untouched and its instruction count equal;
  branch misses rose by a third. Appending the 22 diagnostic codes alone reproduced it, and aligning
  `tokenize` did not help this time. Count instructions, cycles and branch misses with
  `perf_event_open` before chasing a timing difference in source.
- The parser's vocabulary lookahead after `pub` cost 2 % of parse instructions until it tested the
  next token's tag before comparing the word's text.
- The fmt harness can check "never changes what a page says" before any lowering exists, by
  comparing the BIR dump, which holds each text run after trimming and decoding.

## 2026-09-29 15:42 CEST — markup is typed against the platform's vocabulary

**What I did**

- Built checker-v2.md §25.3–§25.7 and §25.9: a module that writes markup is typed instead of
  stopped. A per-module view of the vocabulary resolves tags and attribute names (exact, then the
  most specific pattern; element-scoped before unscoped), reading the vocabulary module's published
  rows, or its own checked declarations when the vocabulary module writes markup itself.
- Six obligation kinds ride on their variables as `interpolatable` does — `renderable`, `handler`,
  `attr_form`, `row`, `key` and `item` (primitive-`eq`, which also raises `unkeyed_for`) — and take
  their boundary rule at step 3 with `try`'s defaults, since three of them unify. What the syntax
  and the rows decide alone is a fault node the solver reports, so it lands on the right
  declaration.
- Components are typed as the call they mean: a `call` node at the callee, a closed record or a
  record update over the spread, `children` interned by the graph.
- The dispatch table gained a markup section (format 5, cache entry 5) and `dump --stage=dispatch`
  prints it. `build` refuses a surviving markup root with `unknown_markup_lowering`.
- The owner's refusal of quoted `on…` attribute names is a new code, `untyped_event_attribute`.
  `markup_type_in_foreign` compares each platform's own lowering with the build's, which the graph
  now carries; the cache key of a platform module with a `foreign` includes both.
- Fixtures: a `markup/` flag directory runs check and dispatch fixtures under `--platform=html`.
  One `check/bad` per diagnostic, the typeahead and the list/row forms as dispatch goldens,
  components across modules, two `build/bad`; blackbox scenarios for warm vs cold, `--jobs`, the
  dispatch round trip and a reversed declaration order.

**What I learned**

- A lambda of the wrong arity leaves its parameters unbound, so the "cannot tell" default of a
  hole inside it said a second thing about one mistake; the default now stays silent in a
  declaration that already failed.
- A module's `check` given a single file does not see a sibling module; a two-module blackbox
  project must be checked as a directory.
- `src/check/rules_test.zig` holds every checker file to 1 500 lines and lists every file by name,
  and it forbids reading a type's children outside `Walk`: the category sentences moved to
  `MarkupTexts.zig` and field lookups go through `Walk.fieldIn`.

## 2026-09-29 15:47 CEST — the markup review's defects in the parser, formatter and lowering

**What I did**

- A quoted attribute name with no `=` at the end of the file crashed lowering, which found the
  value's brace two tokens past the name. The escape's node now records its value and brace
  (`Ast.MarkupAttrEscape`), and lowering, the dump and the formatter read them from there.
- The formatter prints markup that must stay on its line (after a sibling with no space, after a
  `{`) whole, flat; a broken one after a sibling hangs off the children's column; no break where
  it cannot shorten a line (a lone name in a hole, an attribute-less tag's `>`). 200 glued `For`s
  went from 2.7 MB of output to the input re-indented; 36 non-idempotent fuzz finds pass.
- An element's attributes and children are parser siblings, so thousands of `{x.r}` holes are not
  "nested" past 4 096; CRLF text lines lose their `\r`; the lexer's mode stack spills past its
  frame and reports nothing, so markup nested through holes is one parser `nesting_too_deep`;
  braces on an element, two roots, a hole closed by a tag and a stray closing tag are one message
  each, in their own words; duplicate attributes are found in linear time.
- Corrected bench/README's claim of a 4–5 % lexing loss: interleaved, pinned `perf stat` with a
  short run subtracted shows identical instructions and cycles within the spread.

**What I learned**

- Allowing braces without `...` to parse (so lowering says the one thing) let the formatter print
  a `...` that was not there and change the program; the review's generators found it in minutes.
  Keep them (`gen.mjs`, `mut.mjs` in the scratchpad) running after any recovery change.
- A width that is finite means the node has a one-line form; printing a glued node flat is what
  makes "the author wrote it on one line" a fixed point.

## 2026-09-29 16:53 CEST — markup type-checking's review defects, and the other script sinks

**What I did**

- Catalogued CK-215 to CK-220 with red fixtures on the base, then fixed and promoted each.
  A `let` generalised the message variable of markup whose handler, hole or `For` row named an
  enclosing parameter, so `Html Other` passed as `Html Msg`: those obligations now have the
  message variable, payload and item as dependants, held at the owner's rank like a
  `tuple_index`'s result (`ordering_test.zig` swaps the `let`'s bindings).
- `markup_type_in_foreign` now walks records and custom types (a `holds_markup` fixpoint beside
  `has_function`, in the dependency digest) with no budget; the fixpoint moved to `TypeFacts.zig`
  for the 1 500-line rule. A component's markup children get their own message variable, per the
  plain-call equivalence, with a `children`-naming message when the field takes no markup.
- Dependency platform names must be one plain directory name, unique in the chain; nameless
  dependencies take their directory's last segment. Element attribute duplicates fold case.
- Diagnostics: markup too deep for the generator is worded for markup and poisons what it did not
  read; `unkeyed_for` suggests a field the item has; `unknown_form_attribute` has its own title; a
  non-keyed `Show` is shown its own `case`; a hole whose expression stops short skips to its `}`.
- The owner's MD39: `invalid_attribute_name`, `untyped_srcdoc_attribute`, a `url` bit on escapes
  in the markup section (dispatch and entry formats 6), and no `script` in `html`.

**What I learned**

- The checker's obligation table already had the right tool — dependants lowered to the owner's
  rank — and the markup rows simply declared none; the generalisation bug was a missing column
  entry, not missing machinery.
- A hole's recovery that skips to its `}` exposed an error a sibling hole had been hiding
  (`MarkupEllipsisElsewhere`), which is the recovery working, not a regression.

## 2026-09-29 17:49 CEST — the markup lowering interface, and `ssr`: markup runs

**What I did**

- `src/markup/Interface.zig` (`beni_markup`, version 1.0): the typed tree, the `Lowering` value,
  and a `Context`/`Js` builder behind a table of functions over opaque handles, so a lowering
  imports nothing of the compiler and can spell no name it was not given. `build.zig` reads each
  platform's `"zig"`, makes `platform_<name>` modules, and generates the sorted registry with the
  compile-time version check; `-Dplatform=<dir>` and `beni.addPlatform` add one; the build id
  hashes platform Zig.
- The compiler side: `src/js/MarkupTree.zig` builds a module's tree from its `Bir`, the checker's
  markup section and the vocabulary's rows; `Lower` evaluates each root's values in order and
  places row values where the lowering asks; `Emit` checks the markup runtime against the union
  of exports, copies it when used, and writes program start data into the entry file.
- `node` names `ssr` (`platforms/node/zig/ssr.zig`, `markup.js`); `html`'s Zig is the parser table.
  Eleven `run/` fixtures (text, attributes, class/style, holes, `For`, nested rows, `Show`,
  components, blocks, field identity over a test platform's `refEq`, a hoist-name collision),
  emit goldens, seven `build/bad` fixtures, determinism, warm-vs-cold and format round-trip
  scenarios, and a toy external platform built into a second beni inside `test-blackbox`.

**What I learned**

- Importing `Html` from `Node` cost every `node` build about 350 million instructions — the
  vocabulary module is checked by every build that imports it — and pushed a cache test over the
  budget. `render` lives in its own module, `Ssr`, so only programs that render markup pay.
- A lowering that must keep no state still needs to find what `module` hoisted, and needs memory
  to build lists: `cx.hoisted` and `cx.arena` were the two smallest answers.
- `Maybe`'s padded payload makes `Just ()` and `Nothing` both have a `null` payload; `cx.maybe`
  alone cannot tell them apart, so `cx.isJust` exists.
- A kind named `<Module>$k<inst>` collides with a declaration named `k<inst>`; hoist names skip
  declared names.

## 2026-09-29 18:55 CEST — parallel emit and parallel resolve

**What I did**

- Emit runs on one pool of threads per build: reachability's edge lists, lowering, printing
  and the writes, each module into its own slot, results read back in module order. A
  lowering invents names in a per-module `InternPool.Overlay` over the session's pool, which
  the workers only read; the fixed names are interned before the fan-out. `--release` lowers
  and plans in parallel, lists each module's whole-program names in print order
  (`Rename.collectGlobals`), moves them into the session's pool and numbers them serially in
  module order, then renames and prints in parallel — the ordinals are the serial walk's.
  Output directories are made once each, and printed bytes are handed over, not copied.
- Resolution runs on the module DAG (`Resolve.Schedule`), per-module diagnostics joined in the
  graph's order with their `available` ranges rebased.
- A build test where three modules name another module's derived functions, dev and
  `--release`, twice at `--jobs=1` and `--jobs=8`, and the program runs.
- Measured (plain 100k corpus, `--jobs=8`, min of 11 interleaved, load 1.5–2.5): `build
  --library` 68.7 → 50.2 ms, `--release` 79.3 → 59.7, warm build 52.4 → 31.0, cold check 40.4
  → 37.9, warm check 22.6 → 19.1; instructions +0.3 % (`--release` +1.8 %). Skipping the
  rewrite for cache hits was not done: see the perf study's item 5.

**What I learned**

- A persistent pool that spawns threads lazily must start a new thread as having done the
  current round: one spawned before the round's announcement ran the job early and
  decremented a busy count that was not set yet. Only the 16 400-branch abuse test, the one
  default-`--jobs` build big enough to spawn in a later round, reached it.
- Threads are not free for a tiny program: an explicit `--jobs=8` on one file cost 2.6 ms until
  each round's thread count was bounded by its work, keeping two so tests still run parallel.

## 2026-09-29 19:38 CEST — the dom lowering and the browser platform

**What I did**
- Merged the `browser` platform: the `dom` lowering (`platforms/browser/zig/dom.zig`, ported
  from dom-expressions with file:line citations), its runtime (templates, keyed and positional
  rows, events, the microtask render loop), `emit/dom/` goldens, five page fixtures, and a
  differential oracle comparing templates against dom-expressions' own 16 fixtures
  (`tests/oracle/`). Gates green, `-Dllvm` green, headless Chrome green.
- Measured immutable array representations (report 38) and discussed `core/Array` with the owner:
  keep `List` as the cons list; `Array` is either the hybrid (plain array ≤1024, 32-way trie
  above) or a plain JS array read as `a[i]` with copying updates. Not decided yet.

**What I learned**
- The spec contradicted itself: skipping `view` when `update` returns the same model breaks the
  controlled input that puts back a rejected edit, so a flush renders after every message.
- `html` declares custom elements as `"*-*"`, which the vocabulary rules forbid (one `*`), so
  `<my-widget>` is `unknown_element` today.
- Headless Chrome fires no `focus` events without focus emulation.

## 2026-09-30 06:25 CEST — markup against Solid 1 and 2, sizes, sequences, effects steps 1–3

**What I did**
- Markup performance: Solid 1 joined the benchmark. The renderer now matches a keyed list's
  ends before its key map, skips helpers whose arguments are unchanged, recognises selectors,
  empties a parent on replace, mounts rows through their patch and inserts rows directly.
  beni beats Solid 2 on all nine operations and Solid 1 on all but remove (a `List.filter`
  cost in `update`).
- Size: `--release` compacts and renames hand-written JavaScript, drops unused exports and
  writes one scope-hoisted file; nullary constructors are shared constants. The benchmark app
  went 12.1 → 5.1 KB brotli (Solid 1 4.4, Solid 2 22.1); an empty page 7.0 → 1.2 KB.
- Correctness: a single-constructor `case` now evaluates its scrutinee; recursion under `::`
  compiles to a loop (stack overflows at 100 000 gone); `--release` keeps unread bindings
  that may be impure, so both builds print the same.
- Sequences: reports 38 §15–§17, 40, 42 measured adaptive arrays, one type vs two, array-first
  code, brotli-minimal siblings and reference counting in JavaScript. The owner's
  List-or-one-type decision is still open.
- Effects: the owner took the eight decisions; the checker infers impure/suspends, the sync
  check refuses suspending code at synchronous boundaries, and the fiber runtime spike
  (spawn/join/scope/bracket) beats Effect v4 on every measure taken.

**What I learned**
- Research claims about where time goes were wrong twice (the model half of remove/swap);
  timing update and render separately in the page settled it both times.
- Array types measured on cons-shaped code look bad; the owner's point that the code should
  change, not the data structure, changed the study's outcome.
- Cherry-picking agent branches with run-hash conflicts is safe only for hash files: a
  blanket "take theirs" once dropped a test from build_test.zig, which I restored by hand.

## 2026-10-01 11:38 CEST — one List, spreads, specialisation, and the runtime moved to beni

**What I did**
- Sequences: measured every candidate in one batch (research 46); the owner chose one
  array-backed `List` (E1tp, with a claimable head and tail), `::` replaced by bracket and
  spread syntax, `++` routed to `List.append`. Core List rewritten, scalar views for
  `[ x, ...rest ]` walks, append and filter brought back to or under the cons list's speed.
- Compiler: arithmetic as operators, statements for discarded values, in-place loops,
  `Js` intrinsics with `Js.Ref`, `Js.each`, `Js.construct`, `Js.setAt`, `Js.finally`;
  runtime modules in beni; whole-program specialisation (constant arguments, constant lets,
  never-read fields, one-literal and never-null fields, an inliner after the facts); scope-aware
  name reuse; `sync` in platform signatures.
- Runtime: slot/mount, holes, events, `Browser.program`, keyed lists, class/style and the
  effects host loop moved from runtime.js to beni, each step no larger and no slower. Empty page
  978 → 605 brotli; table app 6 139 → 5 723; beni leads Solid 1 on all nine operations.
- A hand-minify skill and a study that took the empty page to 157 bytes by hand; its ledger is
  the compiler's to-do list (escape analysis, constant propagation through objects).

**What I learned**
- Benchmarking array types on cons-shaped code was the wrong question; the owner's "change the
  code, not the data structure" changed the outcome.
- Unique short names can make code larger after brotli: the beni list code was 469 raw bytes
  smaller and 150–220 brotli bytes larger until names were reused across scopes.
- A faster primitive in isolation (`createComment`) can be slower in context (document adoption
  of cloned rows); measure in the page.
- Long benchmark sweeps waste the owner's time; every run now has a 5-minute budget.

## 2026-10-01 22:32 CEST — The syntax batch lands: fmt gate, λ, blocks, names, trailing lambdas

**What I did** (as manager; Opus agents in worktrees implemented every slice)
- Merged the repo-wide reformat and the `beni-fmt-check` gate, then fixed the gate walking
  gitignored bench output (`bench/arrays/dist` and others), which my merge script had pushed red.
- Landed `λ` as the only lambda head (`backslash_lambda_removed`, `--migrate-lambda`), blocks in
  place of `let … in` (`statement_not_unit`, `block_ends_in_binding`, `let_removed`), `Int.mod`,
  `Int.rem`, `Float.log` with `name_removed`, `Debug.log` label first, the call-style hints and
  `suspicious_argument_order`, and trailing lambdas as `fmt`'s own rule. Every mechanical
  migration was its own commit and left emitted JavaScript byte-identical.
- Y10 hit a wall (moving `Int`/`Float` out of `Basics` makes an import cycle); the agent stopped,
  the owner chose plain `Int`/`Float` modules beside the types in `Basics` (S9).
- The owner adopted Lean-style Unicode notation (S8: → ← ≠ ≤ ≥ ▷ ◁ … ×); slice 17 specified it
  (`language.md` §12.7–§12.9, `frontend.md` §11.8) with Z1–Z15 awaiting the owner.
- Merged the schema-engine gap work: release builds keep top-level `const` (V8 folds it; a `let`
  made a hot call 2.5× slower), and schema callbacks cross to the host at a type variable so
  field renaming applies. A cold-path rewrite of `core/Schema.beni` awaits the owner.

**What I learned**
- A merge script must stop on a red gate before `git push`; chaining with `;` pushed a failure.
- `reduce` in V8 is as fast as a loop only once TurboFan compiles its caller; in Maglev it is
  10–20× slower, because the builtin's loop cannot be on-stack-replaced. Compiling folds to
  plain loops is the right shape.
- Columns counted in bytes misplace carets and the 100-column limit after every non-ASCII
  symbol; the Unicode notation makes code-point columns necessary (Z4).

## 2026-10-02 10:59 CEST — Routing, HTTP v2, teardown, Unicode, and core leaving JavaScript

**What I did** (as manager; Opus agents in worktrees implemented every slice)
- Landed HTTP v2 and routing: `Url` in core over the host's `URL.parse`, elm/url's parser and
  builder, `Browser.Navigation`, link requests, `Tea.document`/`Tea.application`, deep links in
  `beni serve`, `Http` on elm/http 2.0 (multipart, progress, typed errors). JSON over HTTP is
  parked on `http-json-blocked`: `Http` importing `Schema` puts its pages over the test budget.
- Landed the defect teardown (`boundary.md` §9.8.14) and fixed a kernel leak: a fiber started by
  a finaliser of a cancelled fiber outlived it (also through scopes).
- Landed the Unicode notation (→ ← ≠ ≤ ≥ ▷ ◁ … ×), with code-point columns; ASCII forms refused.
- `core/Basics.js` and `core/Debug.js` are gone (beni over `Js`, new `Js.typeIs`); `Basics.eq`
  by name fixed for list forms and `()`; equality 1.5–7× faster.
- Studies: research 48 (Effect v4 parity ledger, plan P0–P10), 49 (fiber kernel in beni, needs
  `Js.suspending`), 50 (List.js in beni, needs `Js.object`/`Js.method`). Their compiler
  findings landed: emitter-called core values exported and returned, exit-first loops printed as
  `while` (compare 1.17× faster), exact specialiser speedups (the List port now fits the budget).
- Fixed: a dangling-else in release printing, a suspendable-twin-only module never written, field
  renaming through `Js.from` in twins, cache identity missing embedded core/platform files/build.zig,
  a `--core-root` core lacking an emitter import now refused, path-dependent dev hashes in the
  harness, two timer-flaky fixtures.

**What I learned**
- My merge script must check the merge itself succeeded before gating and pushing: twice it gated
  and pushed an unchanged master, and once a hand-merged test file was committed broken (reset
  and redone before push).
- Dirty-set incrementality in `Spec` cannot be exact (facts fall, travel past callers, and fact 3
  depends on walk order); exact per-statement savings were enough for the List port.
- Agents' scratch output filled /tmp (8 GB tmpfs); clean old scratch directories routinely.

## 2026-10-02 19:17 CEST — Core in beni, Effect parity, typed keys, ⊤/⊥, and the optimiser's audit

**What I did** (as manager; Opus agents in worktrees implemented every slice)
- Core is beni but `Js.js` and a 13-line `List.js`: `Task.js` and `List.js` ported (release equal or
  faster; `List` −6.8 KB in total), `Basics.eq` by name uses a type's own `eq`, `Dict`/`Set` compare by
  contents (Elm had this; beni had regressed), `Debug.toString` prints beni source by type.
- Effect parity: kernel additions, `Deferred`, `Duration`, `Schedule` with retry/repeat, a virtual
  clock, `par`/`forEach`/`race`/`timeout` (all faster than Effect v4 by instructions); the runtime made
  pay-for-what-you-use; listener subscriptions run without a fiber.
- Milestone 2's acceptance app `ApiAndRoutes` landed after core and platforms are checked at beni build
  time and several exact compiler speedups; JSON over HTTP landed; command keys carry a type identity.
- TodoMVC is one full-spec app: 10 053 → 8 575 B brotli whole-spec (Solid 1 5 717, Svelte 4 4 565).
- Syntax: `⊤`/`⊥` replace `()`/`Never`, `if` without `else` for `⊤` branches, `_ =` on `⊤` warned.
- Research 52 audited `Spec` against SCCP/IPSCCP, LLVM's Attributor, MLton, Closure; the owner adopted
  a combined optimistic solver. Slices 0–3 landed (an undefined-memory read, counters, a monotone
  points-to, truthiness); the solver's design is normative in `backend.md` §9.
- Fixed along the way: a soundness hole (schema `Type` in constructors), build output depending on
  where the project lives, an unsound specialiser fact, an order-dependent inline, a browser-only
  macrotask slot that dropped the defect teardown, a cache key missing embedded core files.

**What I learned**
- Agents' "confirm first" choices must come to the owner before a mechanical commit, not after.
- A green gate can hide order- and location-dependent bugs: the harness's paths sort one way; add
  tests that vary the project's location and module order.
- `/tmp` filled repeatedly from the page driver's unbounded cache and agents' scratch; now bounded.

## 2026-10-03 00:38 CEST — How long building beni takes, and incremental compilation

**What I did**
- Measured Zig 0.16 building beni: Debug 9.0 s cold, 7.6 s after an edit, ~0.5 GiB; ReleaseFast
  (LLVM) 3 min 28 s either way, one thread, ~2.4 GiB. Tried `-fincremental`, with and without
  `--watch`. Findings and options for the owner in `plans/build-speed.md`. No code changed.

**What I learned**
- An edit costs almost a cold build, because any change under `src/` changes the build id, and
  then the core-pack maker is recompiled and re-run before beni is compiled again.
- `--watch -fincremental` rebuilds beni in ~0.13 s, but on 0.16 it crashes on the maker's Run step,
  and the configure-time build id goes stale under `--watch`. Incremental without `--watch` gives
  almost nothing, so it barely helps agents' one-shot gate runs.

## 2026-10-03 16:35 CEST — A design pass with the owner, Zig 0.17, and the build id

**What I did** (as manager; three Sonnet research agents and two Opus implementers in worktrees)
- Put the open decisions to the owner one at a time and recorded each in the spec: the package
  model (URL + hash, enforced semver, one version per package, path dependencies for apps only;
  `fast-compiler.md` §3.1); interop (ports withdrawn, one platform per project, libraries pure beni;
  `boundary.md` §3.1); the daemon's D6–D10 after research 53; chunking (static multi-entry, `lazy`
  as a call that may suspend with a typed `LoadError`, preload; `backend.md` §10); all ~39 markup
  decisions (MD1 components may name their own module, MD2 optional props are omittable `Maybe`
  fields, defaults written `¿` in a record pattern and as an expression after research 54, MD10 and
  MD37 element spread, run-time tags, portals and `ref` to be supported, MD12 handlers call
  `preventDefault` themselves); `sync` writable by every package.
- Merged the Zig 0.17 port's last fix (a nondeterministic allocation-failure test) after the agent
  could not reproduce the reported memory exhaustion; merged the build id as a build step, so
  one-shot builds and plain `--watch` always carry the right id. The owner parked incremental
  compilation (`plans/build-speed.md`).

**What I learned**
- Research agents overstate: two of four spot-checks in research 53/54 needed correcting (Rust
  Glancer's author; Roc #6423 "not planned", not a withdrawal). Check the claims a decision rests on.
- The owner wants decisions discussed in prose, one at a time, with plain explanations and a
  recommendation — not multiple-choice prompts, and not jargon ("props" needed explaining).
- Under `-fincremental --watch`, Zig 0.17 never re-sends a compiler its command line, so every
  generated module — the core pack included — silently stays the first build's.

## 2026-10-08 11:24 CEST — Research 56's renderer lands, and work moves to pull requests

**What I did**
- Found research 56's slices A and B with three review rounds (25 commits from 10-04) unmerged in
  an agent worktree. Rebased them, ran the gates and opened PR #3. Slice C is not among them; it
  is still only on `r56-slice-C-over-budget`.
- The owner moved all work to GitHub pull requests reviewed by the Claude workflow. I recorded the
  procedure in CLAUDE.md (PR #4). I also fixed the review workflow, which could not read the PR it
  reviewed: only the inline-comment tool was allowed, so its first run was denied six times and
  posted nothing.
- Answered the `@claude` reviews.
  - Fixed: a turn is now a guard, so a throw from the runtime itself stops the page instead of
    leaving it never rendering.
  - Fixed: a group whose only read is `undefined` (a `⊤` under `--release`) now runs at mount; it
    used `NaN` fields, and `browser/dom/UnitReadMount` failed before and passes after.
  - Declined the reviewer's plain flag reset, because rule 9 says an unknown error must stop the
    program.
  - Found a separate, older defect: an event message of `⊤` is dead under `--release`. Queued in
    the handover §6 item 8.

**What I learned**
- A branch-history listing that concatenates two `git log` ranges reads as one branch: I credited
  PR #3 with slice C, and the reviewer caught it.
- The review is worth having but not obeying. One finding needed a better fix than the one it
  suggested; one needed a non-inlined function to reproduce at all (a `⊤` literal is `null`, and a
  trivial `⊤` function folds to `null`).
- Check a claim before telling the reviewer it: I said tuples cap at three; they do not.

## 2026-10-08 16:56 CEST — Measuring against vanilla, and how far TEA can be compiled away

**What I did** (as manager; work now lands through GitHub PRs reviewed by Claude)
- Re-measured the merged renderer against Solid 1 and vanilla JS on every sweep and the table
  benchmark, with bundle sizes per page. I fixed the scaling harness, which reused pages a
  previous compiler had built, and corrected research 56 §9.9's mislabelled "master" column, the
  PR #3 body and the handover.
- On the owner's question, why not compile down to vanilla, a Fable agent wrote an adversarial
  review (research 58). It found TEA is not the obstacle and recommended message-indexed
  rendering with kill criteria. Three Opus spikes followed:
  - research 59: real-click untraced timing shows research 58's "0.035 ms plumbing" was mostly the
    trace; beni is 7.7 µs over P2, 6.8 µs of it removable. V8's 1 020-property limit is
    confirmed. The table app's bytes are attributed part by part.
  - research 60: hand-written message-indexed pages (P3). The renderer reaches about 1.2× vanilla;
    all three kill criteria are missed, every miss in the model half (`List` cold paths, the depth
    page's per-level update functions, core `List` bytes). The agent's proposal to restate the
    criteria is the owner's call; I recommended keeping them as the unmet overall bar.
  - research 61: 231 TEA constructors, none with an unbounded write set. Real apps are about half
    `List.map`/`filter` idioms; the corpus is mostly our own fixtures.

**What I learned**
- The Chrome trace multiplies every subject's per-message time about 4–5×. A constant measured
  only traced can send work after the instrument; real clicks timed in the page are the honest unit.
- A spike that misses its criteria can still be the most useful result. The point was where the
  gap lives, and it now lives in the model and `List`, not the renderer.
- In this environment Chromium needs `LD_LIBRARY_PATH` unset; `pgrep -f` with a pattern also in the
  current command line kills the command itself; a stray `MERGE_RR.lock` race interrupts rebases.

## 2026-10-08 20:45 CEST — Specifying the write-set analysis (R3/R4's shared summary)

**What I did**
- Wrote `docs/design/write-sets.md`, the normative contract for the per-message write-set
  analysis the owner decided on after research 62: nested-message dispatch and same-variant
  analysis as a sound abstract interpretation, gated on a read-only pass. The domain is
  k-limited access paths (k = 8, from the model root; fields, tuple indices, constructor
  tag-and-position steps, list positions with edit tags) with two write kinds, `node` (rebuilt,
  children keep identity) and `value`. The abstract values are symbolic terms over the old
  model (`Same`, `Rec`, `Con`, `Lst`, `Fresh`, `Alt` with tag facts); the write set is read off
  the result by a `diff` that knows the matched tag per `case` arm. Functions are symbolic
  summaries instantiated by substitution, which is how `updateWith Home …` is seen through;
  recursion is a bounded Kleene iteration. Message keys are paths of constructors through the
  message, split where `update` and its callees match.
- Added pointer paragraphs in `backend.md` §15.4 and `plans/compile-away.md` R3/R4; no section
  renumbered, no compiler code.

**What I learned**
- The prototype classifier's "root write" problem is a domain problem, not a rule gap: without a
  `node`/`value` distinction, re-applying a constructor around matched parts can only be read as
  a write of the whole path. With the distinction and one tag fact per `case` arm, Conduit's
  page union, the status rebuilds and `Feed`'s opaque wrapper all fall out of one `diff` row.
- Slice B's read paths are relative to locals and at most four links; anchoring them to the
  model through nested pages adds steps, so the write side's k must be larger than 4 (Conduit's
  deepest anchored read is about nine). The same interpreter that computes writes gives the
  anchor for free.
- `List.map` and friends are beni over `foreign` `at`/`put`/`kept`, so their precision has to
  come from a declared row citing `backend.md` §4's identity list, not from their bodies; most
  of `Maybe`/`Result` needs no row at all.

## 2026-10-08 21:05 CEST — Write-set spec: the adversarial review's holes closed

**What I did**
- Amended `docs/design/write-sets.md` in place for PR #18's soundness review (branch
  `write-sets-spec`, not pushed). A1–A6: negation facts only from single-path,
  irrefutable-below patterns; a two-path or refutable pattern contributes none; conflict uses a
  may-prefix order in which `[*]` and `[κ]` coincide and index symbols alias unless both are
  distinct literals; `Same` of a path with `[*]`/`[?]` is never identity and the callback
  element is its own root; an `Alt` carries its scrutinee and anchors to it and to its facts'
  paths. B1–B7: roots unique per function and `inst` descends into closures; non-path bases at
  instantiation; unrecognised programs are `value ρ` and every hole dynamic; the k-cut never
  truncates a `Same`; R3 bakes only a hole that is exactly a path with a string-literal `init`;
  the `[*]`-node conflict clause withdrawn; element sub-writes survive tag joins. C1–C5:
  hash-consed terms, `diff` memoised on `(node, p, Γ)`, a work budget W per summary and per
  key, S on every term, a keyed `Alt` exempt from the width cap (Conduit's `ArticlePage` has
  17 constructors and would have hit the old cliff), I = 4, the "linear" claim replaced by a
  bound. §5.2 now carries the negation lemma, the conflict lemma and the singleton condition;
  §8.3 lists the review's eleven fixtures, one of them a `test-pending-perf` scenario. The gate's
  expected Conduit figure is unchanged (about 100 of 101), re-checked rule by rule in §8.2.
- `zig build gates` green (docs only).

**What I learned**
- Per-component negation on a tuple scrutinee is a disjunction, and a Γ of conjunctive tag
  facts cannot hold it; the only sound negation comes from a pattern that can fail for exactly
  one reason.
- Capping the width of an `Alt` was the wrong knob twice: it bounded no work (chains of `if`s
  nest instead of widening) and it punished exactly the shape nested dispatch needs (a `case`
  on a message with many constructors). Cap the work; let a `case` on a path be as wide as its
  type.
- "Linear in the program" is a claim about inputs that hit no cap; a pass with caps should
  state the bound the caps give and measure the rest.
