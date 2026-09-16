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
