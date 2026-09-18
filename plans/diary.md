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
