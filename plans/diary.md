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
