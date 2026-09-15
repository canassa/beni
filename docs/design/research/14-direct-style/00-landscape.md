# Direct-style effect sequencing: the landscape, and who gets a report

**Commissioned by** the multi-agent research programme on direct-style effect sequencing — the
question `fast-compiler.md` §3.2 leaves as "Flat effect syntax — OPEN" and report
[15](../15-flat-effect-syntax.md) narrowed under constraints the shared brief now lifts. This is not
a per-subject report. It is the map: every distinct way a language or framework has solved, or
sidestepped, "write effectful code flat without the `andThen` pyramid"; which shipped systems and
experiments deserve a dedicated agent; and the questions every report must answer so the reports
can be compared. The one fixed fact is the JavaScript target. Type classes, effect rows,
continuations, generators as a compilation target and statements-versus-expressions are all on the
table, and where report 15 or `fast-compiler.md` ruled one out, that is cited as prior thinking.

**Sources.** Forty-one WebSearch queries and eighteen WebFetch reads on 2026-09-14, then a bulk
`curl` sweep of 226 candidate URLs and GitHub contents-API checks on every compiler source path
cited: 201 returned HTTP 200 directly, the rest were confirmed through the API, corrected, or
replaced, except that `dl.acm.org` DOIs return 403 to non-browser clients (the papers exist; an
author-hosted PDF is given alongside wherever one was found) and `hfpug.org` blocks bots. Discovery
started from Yallop's effects bibliography, the Effekt evolution page, the Unison bibliography, the
Lean 4 `do` paper, Hacker News and lobste.rs threads on do-notation, algebraic effects and function
colouring, and the Elm, Roc, Gleam, ReScript, Scala.js and js_of_ocaml trackers. Report 15's Roc and
Gleam measurements are reused, not redone. The search budget did not run out. Claims from the
scout's own knowledge rather than a fetched source are marked (unverified) for the per-subject agent.

---

## 1. The mechanism families

Twelve families. For each: the shape, what the type system must know, where the bind may appear,
whether binds inside branches and loops work, and what it costs at runtime **on JavaScript** — the
column the literature mostly lacks, since it measures C, the JVM or native code.

**A. Class-directed do-notation** (Haskell, PureScript, Idris, Lean 4). `x <- m; rest` becomes
`m >>= \x -> rest`; the type system supplies `>>=` through a `Monad` class (HKT plus dictionaries).
Statement position inside `do`. A bind inside a branch needs a nested `do`; inside a loop, `forM_` or
recursion — **except in Lean 4**, whose `do` elaborator (`src/Lean/Elab/Do/`, ~165 KB across seven
files) adds `for`, `mut`, `return`, `break`, `continue` and `if` inside the block and compiles them
through `StateT`/`ExceptT` (Ullrich & de Moura, ICFP 2022): the "binds inside loops and branches"
question answered by a dedicated elaborator. JS cost: one closure and one indirect call per bind
plus the dictionary unless specialised — PureScript's `MagicDo.hs` exists to inline `Effect`'s bind
into straight-line JS.

**B. Scope- or name-resolved binding** (OCaml `let*`/`let+`, GHC `QualifiedDo` and
`RebindableSyntax`, Agda `do`, `ppx_let`). Same rewrite as A, but `>>=` is an ordinary value found by
scope or module qualifier; nothing beyond HM. `let` position (OCaml) or statement position (GHC).
Branches need a nested block; loops need a fold. Same JS cost as A minus the dictionary. Report 15
§0.1 established that B and D are one rewrite.

**C. Builder- or member-resolved** (F# computation expressions, Scala `for`, C# LINQ). The
desugaring targets members (`b.Bind`, `.flatMap`, `.SelectMany`) found by ordinary overloading. F# 6
is the outlier: `task { }` compiles through **resumable code** (FS-1087) into a real state machine,
so one syntax has a closure backend (`async { }`) and a state-machine backend. Statement position
inside the block; F# has `for`/`while`/`try` inside if the builder defines them; Scala `for` has no
loops and no early return. JS cost via Fable or Scala.js: closures per bind unless state-machine
backed.

**D. Generalised trailing lambda / rest-of-block** (Gleam `use`, Koka `with`, Roc backpassing,
Kotlin trailing lambdas, Elixir `with`). `use x <- f(a); rest` becomes `f(a, fn(x){ rest })`. The type
system needs nothing; the callee's last parameter must be a function. Statement position, the
continuation is the rest of the block; a bind in a branch needs a new block; a bind inside a loop is
not expressible. Cheapest desugarer there is (Roc: 44 lines, report 15 §0.2). JS cost: one closure
per bind. Elixir `with` is the lambda-free variant: pattern-bind, short-circuit on mismatch, `else`.

**E. Arbitrary-position markers** (Rust `?`, Roc `!`, Idris `!e`, Swift `try`/`await`). A marker
anywhere an expression may appear; the compiler hoists the surrounding expression into a
continuation or, for `?`, a local `match`+`return`. `?` needs a trait (`Try`) or, in beni today,
ordered speculative unification (report 15 §0.3). Binds inside branches and loops work because the
marker is an expression. The cost is compiler-side: Roc's `suffixed.rs` is 1,046 lines against 44
for backpassing, and Idris's `!` lifts "as high as possible within its current scope" — a rule
newcomers get wrong. JS cost is whatever the underlying bind costs.

**F. Compiler state-machine transforms** (C#, Rust, Kotlin, Swift, Dart, JavaScript `async`,
ClojureScript `go`, scala-async and dotty-cps-async, Nim CPS, F# `task`, regenerator and tslib
downlevelling). The whole body becomes a resumable object: locals live across suspensions are
spilled to fields, control flow becomes a `switch` on a state integer. The type system needs a
colour on the signature; `await` is legal anywhere in the coloured body — branches, loops, `try`,
early return. JS cost: one state object per **call**, not per bind, plus a resume and spill/restore
per suspension; V8's native `await` cost at least three microticks and two extra promises until V8
7.2 (Chrome 72, 2018-11), one microtick and usually no extra promise since (Armyanova & Meurer). The
downlevel transforms (tslib `__awaiter`/`__generator`, regenerator's `emit.js`) are the transform
beni would write for option C in `fast-compiler.md` §3.2, and have shipped for a decade.

**G. Generators and stackless coroutines as a library escape hatch** (Effect-TS `Effect.gen`, fp-ts,
Redux-Saga, `co`, task.js, Python pre-3.5, Lua, Kotlin Arrow's `either { }`). The host's coroutine
supplies suspension; a library interpreter drives it, so bind = `yield`. Nothing from the type
system (Effect-TS types `yield*` through iterator variance, adapter-free since PR #2602, 2024-04).
Binds in branches and loops; early return is `return`. JS cost: one generator object per call plus
the iterator-result protocol per bind; report 15 §0.5 records that Effect-TS's maintainers blame
the fiber runtime, not the generator. One-shot only: no multi-shot handlers, no backtracking.

**H. Algebraic effects with rows or capabilities** (Koka, Effekt, Unison, Frank, Eff, Links, Helium,
Flix, OCaml 5, Haskell `effectful`/`bluefin`/`polysemy`, Scala Caprese/Gears, Verse). No bind syntax:
effectful calls are ordinary calls and the *type* carries what may be performed — an effect row
(Koka, Links, Unison, Flix via Boolean unification), a capability in scope (Effekt, bluefin, Gears),
or nothing (OCaml 5 tracks no effects in types). Binds in branches and loops are free. The cost
moves to inference (row polymorphism, rejected in `fast-compiler.md` §3, now open) and to the
backend: with no native continuations on JS the choices are selective CPS (Koka's POPL 2017 backend,
js_of_ocaml's `--effects=cps`/`double-translation`, Links), a monadic runtime (Effekt's
`TransformerCps.scala`), or one-shot generators. js_of_ocaml's partial-CPS PR measured it: ocamlc
~10% slower, code +44% uncompressed / +6% compressed, compile +25% (PR #1384, 2023-02).

**I. Delimited continuations and native stack switching** (Racket/Scheme, Multicore OCaml fibers,
Java Loom, WebAssembly JSPI and stack switching, WasmFX, Asyncify, Lexa, Stopify). The runtime
captures the stack, so any function suspends without colour or transform; the type system needs
nothing. **JavaScript has no such primitive**: Stopify gets one by a JS-to-JS transform that reifies
the stack (PLDI 2018, ten languages, measured), JSPI only for Wasm frames (Chrome M126 API, Scala.js
1.19's "orphan await"), Asyncify by instrumenting Wasm. This is where "we control the language" is
weakest, because the host does not cooperate.

**J. Effects are native; the problem never arises** (Go, Erlang/Elixir, Java before Loom, Dart,
Zig's `Io` parameter, Roc after purity inference). Sequencing is `;`. What remains is *tracking*:
Roc infers purity and marks effectful functions `f!` with `=>` types; Zig passes `Io` as a value the
way it passes `Allocator`, explicitly to avoid colouring (Kelley, 2025-10-29); Dart and Java colour
with `async`/`Future` anyway. JS cost: none — which is also why this family cannot express
effects-as-values, cancellation, or retry by re-running.

**K. Type-directed implicit lifting and monadic reflection** (Swamy, Guts, Leijen & Hicks, ICFP
2011; Filinski, POPL 1994; Arrow's `bind()` over `suspend`; yelouafi's generator reflection).
Direct style with neither syntax nor rows: the checker inserts `bind`/`return` coercions where a
monadic value meets a pure context, or delimited control reifies any monad's `reflect`/`reify`.
Binds anywhere, because nothing is written. Needs coercion inference (a new constraint kind) or
one-shot continuations (family I). Neither shipped in a mainstream language; both are here because
nobody in A–J is using them.

**L. The evidentiary question** (Elm). Not a mechanism: one agent asks whether the complaint this
programme exists to fix is real and central among people maintaining large Elm codebases.

**Two axes fall out.** *Where the marker may appear* (statement/`let` position versus anywhere) is
the compiler-cost axis, per report 15 §1. *Whether the whole function body is transformed*
(F, G, H-via-CPS, I) versus *only the rest of a block* (A–D) is the expressiveness axis: only the
former puts a bind inside a loop. Every candidate below sits on both.

---

## 2. The candidate list

Forty-two candidates; slugs are file names under `docs/design/research/14-direct-style/`. Tier 1
must be studied, Tier 2 should be, Tier 3 holds one distinctive idea each. Every URL returned 200
on 2026-09-14 unless annotated.

### Family L — the evidentiary report

**`elm` — Elm — Tier 1.** The only evidentiary report. Is the `andThen` pyramid real and *central*
among people maintaining large Elm codebases, separated sharply from TEA-boilerplate and
no-type-class complaints; what has Evan Czaplicki said directly; what have NoRedInk, Vendr, Rakuten
and Culture Amp published. Two findings set the bar: Kevin Yank's 2023-04-05 Culture Amp retirement
post names five reasons and **none is syntax or effect ergonomics** (verified), and Evan himself
opened elm/compiler#908 on 2015-04-03 listing `let!`, `tasklet`, `async`/`await` and `@task`+`do`
as candidate task syntaxes, judged on learnability and "accessibility to non-functional
programmers". *Look for:* how #908 was closed and every later Evan statement on do-notation; the
elm-discuss threads "Talking about Effects" (2014-05) and "Idea for `do` notation desugaring"
(2015-12: "Evan had a proposal a while ago about including something like this in the 'let' syntax,
again using the 'with' keyword"; "the general consensus was that we shouldn't block on syntax for
releasing Tasks"); elm-pages' `BackendTask` code as the largest public corpus of `andThen` chains;
a count of Discourse threads about nesting versus TEA boilerplate. *Sources:*
https://github.com/elm/compiler/issues/908 ;
https://groups.google.com/g/elm-discuss/c/j9Da2UIA5xo/m/43fW9PEcsesJ ;
https://groups.google.com/g/elm-discuss/c/RJ6jHX01wF8 ;
https://kevinyank.com/posts/on-endings-why-how-we-retired-elm-at-culture-amp/ ;
https://engineering.rakuten.today/post/elm-at-rakuten/ ; https://github.com/NoRedInk/elm-style-guide ;
https://github.com/dillonkearns/elm-pages ; `references/elm`.

### Family A — class-directed do-notation

**`haskell-do-notation` — Haskell, GHC — Tier 1.** The origin and every extension: `ApplicativeDo`
(a dependency analysis beni could reuse for parallel tasks), `QualifiedDo`/`RebindableSyntax`
(name-resolved `do` without a class, the trick Agda's `do` also uses), `MonadFail` desugaring, and
"do notation considered harmful". *Look for:* the Report §3.14 rule verbatim; QualifiedDo's rejected
alternatives; ApplicativeDo's measured effect on Haxl; the 2020-05 HN thread as the for/against
record. *Sources:* https://www.haskell.org/onlinereport/haskell2010/haskellch3.html ;
https://github.com/ghc-proposals/ghc-proposals/blob/master/proposals/0216-qualified-do.rst ;
https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/rebindable_syntax.html ;
https://simonmar.github.io/bib/papers/applicativedo.pdf ;
https://wiki.haskell.org/Do_notation_considered_harmful ; https://news.ycombinator.com/item?id=23015593 ;
https://agda.readthedocs.io/en/latest/language/syntactic-sugar.html

**`purescript-do-and-magic-do` — PureScript — Tier 1.** The class-directed language whose only
target is JavaScript, so it pays family A's cost on our runtime and has an optimiser pass,
`MagicDo`, that rewrites `Effect` do-blocks into straight-line JS. *Look for:* what `MagicDo.hs`
matches and what it cannot see through (a bind under a lambda, a polymorphic monad); the measured
difference with the pass off; the v0.12.0 move from `Eff` rows to `Effect`; whether large-app users
complain about bind cost. *Sources:*
https://github.com/purescript/purescript/blob/master/src/Language/PureScript/CoreImp/Optimizer/MagicDo.hs ;
https://github.com/purescript/purescript/releases/tag/v0.12.0 ;
https://github.com/purescript/documentation/blob/master/language/Syntax.md

**`lean4-do-elaborator` — Lean 4 — Tier 1.** The only shipped `do` with `for`, `mut`, `return`,
`break`/`continue` and `if` inside the block; the paper says the technique "can readily be adapted to
any other functional language with support for monads and monad transformers". *Look for:* the
translation of `for`+`mut`+`return` through `ForIn`/`StateT`/`ExceptT` and its cost; the size of
`src/Lean/Elab/Do/` (`Legacy.lean` 82 KB, `Basic.lean` 49 KB — a rewrite is in progress, ask why);
error-message quality; what survives without typeclasses. *Sources:*
https://lean-lang.org/papers/do.pdf ; https://github.com/leanprover/lean4/blob/master/src/Lean/Elab/Do.lean
(and the `Do/` directory beside it) ;
https://lean-lang.org/doc/reference/latest/Functors___-Monads-and--do--Notation/Syntax/

**`idris2-bang-and-js-backend` — Idris 2 — Tier 2.** Has `do`, the arbitrary-position `!e`
marker, *and* a JavaScript backend, so the hoisting rule and its JS output can be read together.
*Look for:* the documented lifting rule ("as high as possible within its current scope, depth first,
left to right") and its surprises with `if`/`case`; the JS backend's `>>=`; Brady's `Effects` library
as an early capability system. *Sources:*
https://idris2.readthedocs.io/en/latest/tutorial/interfaces.html ;
https://idris2.readthedocs.io/en/latest/backends/javascript.html ;
https://www.type-driven.org.uk/edwinb/papers/effects.pdf

### Family B — scope-resolved binding

**`ocaml-let-operators` — OCaml `let*`/`let+`, `ppx_let` — Tier 1.** The no-typeclass `do`,
adopted in 4.08 after years of `ppx_let`/`let%lwt`. *Look for:* PR #1947 on `and*` (applicative
parallel binds) and why `let*` is a value not a keyword; what `ppx_let` had that the built-in form
dropped (`match%bind`, `if%bind` — binds inside branches); js_of_ocaml output for a `let*` chain.
*Sources:* https://github.com/ocaml/ocaml/pull/1947 ; https://ocaml.org/manual/5.3/bindingops.html ;
https://github.com/janestreet/ppx_let

### Family C — builder-resolved

**`fsharp-computation-expressions` — F#, FS-1087, Fable — Tier 1.** The richest builder protocol
(`Bind`, `For`, `While`, `TryWith`, `Delay`, `Combine`) and the one that grew a state-machine
backend; Fable compiles both to JavaScript. *Look for:* the "Computation Expression Zoo" taxonomy;
FS-1087's motivation and the darklang F# 6 task benchmark; what Fable emits for `async { }` versus
`task { }`; `Delay`/`Combine` as the price of loops inside the block. *Sources:*
https://tomasp.net/academic/papers/computation-zoo/ ;
https://github.com/fsharp/fslang-design/blob/main/FSharp-6.0/FS-1087-resumable-code.md ;
https://github.com/fsharp/fslang-design/discussions/455 ; https://blog.darklang.com/benchmarking-fsharp6-tasks/ ;
https://github.com/fable-compiler/Fable/blob/main/src/fable-library-ts/Async.ts

**`scala-for-comprehensions` — Scala `for`, Scala.js — Tier 2.** Member-resolved
`map`/`flatMap`/`withFilter`; no loops, no early return, a `withFilter` wart `better-monadic-for`
exists to fix; Scala.js makes the JS output measurable. *Look for:* the spec's rules;
better-monadic-for's list of what the built-in desugaring gets wrong; Scala 3 `boundary`/`break` as
early return added outside `for`. *Sources:*
https://www.scala-lang.org/files/archive/spec/3.4/06-expressions.html ;
https://github.com/oleg-py/better-monadic-for ; https://www.scala-lang.org/api/3.3.0/scala/util/boundary$.html

### Family D — rest-of-block

**`gleam-use` — Gleam — Tier 1.** The cleanest shipped rest-of-block form, compiling to
JavaScript; report 15 did the desugaring, so go deeper. *Look for:* Pilfold's trade-off ("it is less
immediately obvious what `use` does to a newcomer", 2022-11-24); `parse_use` at
`compiler-core/src/parse.rs:1066` and the formatter; the JS emitted for a `use` chain; issues asking
for `use` inside `case` arms or loops and the answers. *Sources:*
https://gleam.run/news/v0.25-introducing-use-expressions/ ; https://github.com/gleam-lang/gleam/issues/1709 ;
https://tour.gleam.run/advanced-features/use/ ;
https://github.com/gleam-lang/gleam/blob/main/compiler-core/src/parse.rs

**`koka-with-and-effects` — Koka — Tier 1.** Spans D and H: `with` on top of row-typed effects
compiled by type-directed selective CPS — **originally to JavaScript** (Leijen, POPL 2017) before
the C backend and evidence passing (Xie & Leijen, ICFP 2021). The one system where "effect rows plus
JS target" was built and measured. *Look for:* the POPL 2017 JS results; why the JS backend "does not
use evidence translation" (unverified); `src/Backend/JavaScript/FromCore.hs` (59 KB) today; what
Koka's authors say about JS as a handler target. *Sources:*
https://koka-lang.github.io/koka/doc/book.html ;
https://www.microsoft.com/en-us/research/wp-content/uploads/2016/12/algeff.pdf ;
https://xnning.github.io/papers/multip.pdf ;
https://github.com/koka-lang/koka/blob/dev/src/Backend/JavaScript/FromCore.hs

**`elixir-with` — Elixir `with` — Tier 2.** Pattern-directed flattening of `{:ok, _}` chains with
an `else` clause, added in 1.2 (2016-01-03), in a language with native effects — what a
lambda-free, class-free flattening looks like. *Look for:* the 1.2 rationale; `else`-clause
complaints; whether `with` is used beyond `ok`/`error`. *Sources:*
https://elixir-lang.org/blog/2016/01/03/elixir-v1-2-0-released/ ; https://hexdocs.pm/elixir/Kernel.SpecialForms.html

**`roc-purity-inference` — Roc after `Task` — Tier 1.** Report 15 measured backpassing and `!`;
what followed is the pivot: Roc **removed `Task` entirely** for purity inference — effectful
functions are `f!`, typed `=>`, called directly; "pure functions cannot call effectful functions".
The family-J answer from an Elm-descended language, argued in public. *Look for:* Feldman's "The
Functional Purity Inference Plan" (2024-10) and the Zulip design threads via `roc-zulip`; what
happened to effects-as-values (retry, cancellation, deferral); `!` under lambdas and higher-order
functions; what the platform must now do that `Task` did. *Sources:*
https://www.roc-lang.org/functional ; https://www.youtube.com/watch?v=42TUAKhzlRI ;
https://changelog.com/podcast/645 ; `references/roc` ; the `roc-zulip` skill.

### Family E — arbitrary-position markers

**`rust-question-mark-and-async` — Rust `?`, `async`/`await` — Tier 1.** The trait-directed
postfix marker (RFC 243, `Try` v2 RFC 3058) and the canonical state-machine transform (RFC 2394;
the 2019 await-syntax thread chose postfix `.await` after the longest syntax debate in the
language). `rustc_mir_transform/src/coroutine/` is the transform. *Look for:* RFC 243's `From::from`
conversion and why beni's §3.2 rule 2 rejects it; the postfix arguments; Mandry's generator-size
measurements; boats' retrospective. *Sources:*
https://rust-lang.github.io/rfcs/0243-trait-based-exception-handling.html ;
https://rust-lang.github.io/rfcs/3058-try-trait-v2.html ; https://rust-lang.github.io/rfcs/2394-async_await.html ;
https://internals.rust-lang.org/t/a-final-proposal-for-await-syntax/10021 ;
https://tmandry.gitlab.io/blog/posts/optimizing-await-1/ ; https://without.boats/blog/why-async-rust/

### Family F — compiler state-machine transforms

**`csharp-async-state-machine` — C# 5 `async`/`await`, LINQ — Tier 1.** The design every later
`async` copied, documented by its designers (Lippert 2010, Toub 2023) with the rewriter readable in
Roslyn (`AsyncMethodToStateMachineRewriter.cs`, 32 KB); LINQ query syntax is the same compiler's
family-C comprehension. *Look for:* the struct-vs-class state machine decision; ayende's cost post;
`await` inside `try`/`finally`/`catch`; what `SelectMany` requires of a type. *Sources:*
https://learn.microsoft.com/en-us/archive/blogs/ericlippert/asynchrony-in-c-5-part-one ;
https://devblogs.microsoft.com/dotnet/how-async-await-really-works/ ;
https://github.com/dotnet/roslyn/blob/main/src/Compilers/CSharp/Portable/Lowering/AsyncRewriter/AsyncMethodToStateMachineRewriter.cs ;
https://ayende.com/blog/174689/the-cost-of-the-async-state-machine

**`kotlin-suspend-and-arrow` — Kotlin coroutines, Kotlin/JS, Arrow `Raise` — Tier 1.** The most
complete public rationale for a library-agnostic suspension primitive: the compiler does only the
CPS/state-machine rewrite; libraries build schedulers and comprehensions (`either { x.bind() }`) on
it; Kotlin/JS emits it to JavaScript. *Look for:* KEEP's rejected alternatives; spill fields in JS
form; Arrow's `either { }` as reflection over one-shot continuations (family K) and its `eager`
variant; suspend-inside-lambda restrictions. *Sources:*
https://github.com/Kotlin/KEEP/blob/master/proposals/coroutines.md ;
https://kotlinlang.org/spec/asynchronous-programming-with-coroutines.html ;
https://old.arrow-kt.io/docs/patterns/monad_comprehensions/ ;
https://arrow-kt.io/learn/typed-errors/working-with-typed-errors/ ; https://kotlinlang.org/docs/js-overview.html

**`swift-async` — Swift — Tier 2.** Family F implemented differently: LLVM coroutine *splitting*
with a `swiftasync` calling convention and caller-allocated async frame, not a `switch`; plus `try`
as an arbitrary-position marker. *Look for:* SE-0296's rejected alternatives; the async-frame design;
SE-0304's structured-concurrency argument. *Sources:*
https://github.com/swiftlang/swift-evolution/blob/main/proposals/0296-async-await.md ;
https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md ;
https://llvm.org/docs/Coroutines.html ; https://www.swift.org/blog/swift-5.5-released/

**`dart-async-dart2js` — Dart on the web — Tier 2.** A team shipping `async` to JavaScript at
scale that rewrites it itself: `pkg/compiler/lib/src/js/rewrite_async.dart` is **103 KB**, and the
claim that dart2js "uses an exception which is thrown and caught for some state transitions"
(unverified) would be a striking cost finding. *Look for:* why dart2js does not emit native
`async`; case count of `rewrite_async.dart`; `await for` vs `listen()` 2x (sdk#23645); the
"Async/Await is a mess" thread. *Sources:*
https://github.com/dart-lang/sdk/blob/main/pkg/compiler/lib/src/js/rewrite_async.dart ;
https://dart.dev/language/async ; https://github.com/dart-lang/sdk/issues/23645 ;
https://groups.google.com/a/dartlang.org/g/misc/c/Vki5OTOoma4

**`rescript-async-await` — ReScript — Tier 2.** An ML-family JS-targeting language that in 10.1
(2022) mapped `async`/`await` *directly* onto JavaScript's with `promise<'a>` as the type — "just
use the host" for a language shaped like beni. *Look for:* the design discussion in #5857; what is
lost (effects-as-values, cancellation; promise semantics leak); `await` inside `if`/`switch`/loops.
*Sources:* https://rescript-lang.org/blog/release-10-1 ; https://rescript-lang.org/docs/manual/async-await/ ;
https://github.com/rescript-lang/rescript/issues/5857

**`clojurescript-core-async` — `go` macro — Tier 2.** A state-machine transform as a *library
macro* (`ioc_macros.clj`, 31 KB) targeting JavaScript since 2013 — family F without compiler
support, with a catalogue of what breaks. *Look for:* the rationale's IOC-threads stance; Petersen's
2013 walkthrough; restrictions on `<!` inside nested functions. *Sources:*
https://clojure.github.io/core.async/rationale.html ;
https://github.com/clojure/core.async/blob/master/src/main/clojure/cljs/core/async/impl/ioc_macros.clj ;
http://hueypetersen.com/posts/2013/08/02/the-state-machines-of-core-async/

**`javascript-async-await-v8` — JavaScript's own `async`/`await` and generators — Tier 1.** The
substrate: V8's implementation, the 2018 optimisation (three microticks and two extra promises per
`await` down to one microtick and usually none, V8 7.2), the TC39 history (task.js and `co` as
precursors), Nystrom's colouring essay as the canonical complaint. *Look for:* the register-spill
mechanism; whether generator-object allocation is elided (no verified number found so far); the
proposal's rejected alternatives; `await` in a loop versus `Promise.all`. *Sources:*
https://v8.dev/blog/fast-async ; https://github.com/tc39/proposal-async-await ;
https://github.com/mozilla/task.js ; https://github.com/tj/co ;
https://journal.stuffwithstuff.com/2015/02/01/what-color-is-your-function/

**`regenerator-and-tsc-downlevel` — regenerator, tslib, Babel — Tier 1.** The state-machine-to-JS
transform beni would write for option C exists three times and has shipped to every ES5 browser for
a decade: regenerator's `emit.js`/`leap.js` and tslib's `__generator`. *Look for:* Newman's JSConf
2014 "Yield Ahead" design (the `leap` manager for control flow crossing `try`); tslib's `finally`
and labelled breaks; any measurement of downlevelled vs native generators; the TypeScript 7 Go
port's `estransforms`. *Sources:* https://github.com/facebook/regenerator ;
https://github.com/facebook/regenerator/blob/main/packages/transform/src/emit.js ;
https://github.com/benjamn/jsconf-2014 ; https://github.com/microsoft/tslib/blob/main/tslib.js ;
https://mariusschulz.com/blog/compiling-async-await-to-es3-es5-in-typescript ;
https://github.com/microsoft/typescript-go/tree/main/internal/transformers/estransforms

**`scala-macro-cps-direct` — scala-async, dotty-cps-async, zio-direct, cats-effect-cps — Tier 2.**
Four attempts at direct style over an *arbitrary user monad* by macro CPS — the generic async/await
beni cannot have without type classes but can learn the edge cases from: ZIO's `Async.async` block
is "rewritten at compile time into a non-blocking flatMap/map chain", with Scala.js 3.8+ using native
`js.async`/`js.await` for direct-position awaits and the macro only for "closures, by-name
arguments, or nested methods". *Look for:* Shevchenko's transform rules (2022); the documented
await-position restrictions per platform; Nedelcu's "has edge cases" verdict. *Sources:*
https://github.com/dotty-cps-async/dotty-cps-async ; https://arxiv.org/abs/2209.10941 ;
https://github.com/zio/zio-direct ; https://github.com/typelevel/cats-effect-cps ;
https://github.com/scala/scala-async ; https://zio.dev/zio-blocks/reference/async/

**`nim-cps` — nim-works/cps — Tier 3.** A macro that rewrites a procedure into a continuation type
holding its locals plus a function pointer — 32–40 bytes each by the authors' claim — with no
scheduler. The minimal state-machine transform, isolated from any runtime. *Look for:* the
"suspendable function semantics" discussion; what control flow the rewrite refuses. *Sources:*
https://github.com/nim-works/cps ; https://github.com/nim-works/cps/discussions/42 ;
https://forum.nim-lang.org/t/13322

**`zig-async-io` — Zig — Tier 3.** Shipped stackless `async`/`await`, removed it, returned with
`Io` passed as a parameter "just like we already do with Allocator" — capability passing without
types, chosen to avoid colouring. *Look for:* Kelley's 2025-10-29 post and why the old design "never
felt finished"; four execution models behind one interface; the lobste.rs/LWN reception. *Sources:*
https://andrewkelley.me/post/zig-new-async-io-text-version.html ;
https://kristoff.it/blog/zig-new-async-io/ ; https://lwn.net/Articles/1046084/ ;
https://lobste.rs/s/rb81fq/zig_s_new_async_i_o_text_version

### Family G — generators as a library escape hatch

**`effect-ts` — Effect-TS `Effect.gen` — Tier 1.** Elm's effects-as-values model, flat via
generators, in production TypeScript; report 16 measured its fibers. *Look for:* the adapter's
removal (PR #2602, 2024-04-24, via iterator variance) and the v4 docs; "Abusing TypeScript
Generators"; language-service #172 on nested generators; how `yield*` inside `for`/`while` is
typed; maintainers on generator versus fiber cost. *Sources:*
https://effect.website/docs/getting-started/using-generators/ ;
https://www.effect.website/docs/v4/getting-started/using-generators ;
https://github.com/Effect-TS/effect/pull/2602 ; https://dev.to/effect/abusing-typescript-generators-4m5h ;
https://github.com/Effect-TS/effect/blob/main/packages/effect/src/internal/core.ts ;
https://github.com/Effect-TS/language-service/issues/172

**`zio-and-cats-effect` — ZIO 2, Cats Effect 3 — Tier 2.** The two JVM effects-as-values
runtimes, both living with `for` and both growing direct-style escape hatches. *Look for:* what each
says the `flatMap` chain costs on its interpreter loop; De Goes' position on direct style versus
monadic IO; Nedelcu's "monadic IO is not getting the support it needs in order to go mainstream".
*Sources:* https://zio.dev/ ; https://typelevel.org/cats-effect/ ;
https://alexn.org/blog/2025/08/29/scala-gamble-with-direct-style/ ;
https://virtuslab.com/blog/scala/comparing-effect-systems-in-scala-kyo-gears-and-ox

**`python-asyncio-and-trio` — PEP 342, PEP 492, Trio — Tier 2.** The best-documented migration
from generator coroutines to dedicated syntax (2015), and Smith's structured-concurrency essays on
what a suspension mechanism owes to cancellation. *Look for:* PEP 492's reasons to separate `async
def` from generators; "go statement considered harmful"; what `await` cannot express. *Sources:*
https://peps.python.org/pep-0492/ ; https://peps.python.org/pep-0342/ ;
https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/ ;
https://vorpus.org/blog/some-thoughts-on-asynchronous-api-design-in-a-post-asyncawait-world/

**`lua-coroutines` — Lua — Tier 3.** The paper arguing full asymmetric coroutines equal one-shot
delimited continuations — the bridge between G and I. *Look for:* symmetric vs asymmetric, stackful
vs stackless, why Lua chose stackful. *Sources:* https://www.inf.puc-rio.br/~roberto/docs/MCC15-04.pdf

**`js-coroutine-libraries` — task.js, co, Redux-Saga, fp-ts, effects.js — Tier 3.** A decade of
"generators as monads" in JavaScript before and beside Effect-TS: task.js (2012) and `co` (2013) as
async/await precursors; Saga's effects-as-data testing story; fp-ts's `Do`/`bind` chain; effects.js
"based on Koka and Eff". *Look for:* why `co` retired; yelouafi's continuation capture and its
one-shot limit. *Sources:* https://github.com/mozilla/task.js ; https://github.com/tj/co ;
https://redux-saga.js.org/ ; https://github.com/gcanti/fp-ts ; https://github.com/nythrox/effects.js ;
https://dev.to/yelouafi/algebraic-effects-in-javascript-part-2---capturing-continuations-with-generators-13da

### Family H — algebraic effects with rows or capabilities

**`effekt` — Effekt — Tier 1.** Lexical handlers with *capability passing* instead of rows, a
JavaScript backend from day one, and an evolution page recording every removal: the MLton pipeline
dropped in 2023 because "the pipeline was quite involved (we published three papers about it)";
`Console` replaced by a builtin `io` capability; first-class functions re-admitted via boxes. *Look
for:* what the JS backend emits (`effekt/shared/src/main/scala/effekt/generator/js/TransformerCps.scala`,
26 KB) and its monadic origin; the OOPSLA 2020 case that capabilities avoid row inference; evidence
monomorphisation (2023) as the optimisation a JS backend cannot do. *Sources:*
https://effekt-lang.org/evolution ; https://github.com/effekt-lang/effekt ;
https://se.informatik.uni-tuebingen.de/publications/brachthaeuser20effects/ ;
https://se.informatik.uni-tuebingen.de/publications/brachthaeuser22effects.pdf ;
https://ps.informatik.uni-tuebingen.de/publications/brachthaeuser20effekt.pdf

**`unison-abilities` — Unison — Tier 2.** Frank-derived abilities where "ability polymorphism is
provided by ordinary polymorphic types" with a separate `handle`; now compiled via Chez Scheme
(native continuations). *Look for:* divergences from Frank; the JIT's reliance on Scheme
continuations; the bibliography's related-work list. *Sources:*
https://unison-lang.org/learn/language-reference/abilities-and-ability-handlers ;
https://www.unison-lang.org/docs/fundamentals/abilities/ ; https://www.unison-lang.org/blog/jit-announce/ ;
https://www.unison-lang.org/docs/usage-topics/bibliography/

**`ocaml5-effects-and-jsoo` — OCaml 5, js_of_ocaml, wasm_of_ocaml — Tier 1.** Untyped handlers
retrofitted onto a mainstream language (PLDI 2021), then compiled to JavaScript with **published
numbers**: full CPS 60% slower on ocamlc; partial CPS via global control-flow analysis ~10%, at
+44% uncompressed / +6% compressed code and +25% compile time (PR #1384, 2023-02-02); a later
`double-translation` mode keeps a direct-style copy of each function. The closest thing to a measured
answer to "what do handlers cost on JS". *Look for:* `compiler/lib/effects.ml` and the
double-translation tests; `manual/effects.mld`; whether wasm_of_ocaml uses JSPI; the PLDI argument
for *not* typing effects. *Sources:* https://arxiv.org/abs/2104.00250 ;
https://ocaml.org/manual/5.3/effects.html ; https://github.com/ocsigen/js_of_ocaml/pull/1340 ;
https://github.com/ocsigen/js_of_ocaml/pull/1384 ;
https://github.com/ocsigen/js_of_ocaml/blob/master/manual/effects.mld

**`flix-effects` — Flix — Tier 2.** Rows inferred by Boolean unification, associated effects on
type classes (OOPSLA 2024), handlers on the JVM — the row-typed system with a production inference
story to set against `fast-compiler.md` §3's cost objection. *Look for:* measured inference cost;
handler compilation without JVM continuations; polymorphic effect constructors (#13229). *Sources:*
https://doc.flix.dev/effects-and-handlers.html ; https://github.com/flix/flix ;
https://dl.acm.org/doi/full/10.1145/3656393 (ACM; 403 to non-browser clients)

**`haskell-effect-libraries` — effectful, bluefin, polysemy — Tier 2.** Three generations, and
Ellis's 2025 "History of Effect Systems"; bluefin's move is effects "indicated by value-level
arguments" — the Haskell twin of Effekt and Gears. *Look for:* the effectful-vs-bluefin thread; why
polysemy's free-monad approach lost on performance; what a capability handle costs. *Sources:*
https://hackage.haskell.org/package/bluefin ; https://hackage.haskell.org/package/effectful ;
https://github.com/polysemy-research/polysemy ;
https://discourse.haskell.org/t/bluefin-compared-to-effectful-video/10723 ;
https://h2.jaguarpaw.co.uk/posts/bluefin-capability-system/

**`scala-direct-style-caprese` — Gears, Ox, Kyo, Caprese, `boundary`/`break` — Tier 2.** Scala's
bet on direct style via capabilities and Loom, with a JS story only through JSPI on Wasm; Nedelcu's
2025-08-29 critique ("the 'direct style' approaches are currently in limbo") is the best account of
a community mid-transition. *Look for:* Gears' reliance on virtual threads or one-shot continuations
and lack of a JS backend; Ox's JVM-only scope; the VirtusLab comparison. *Sources:*
https://github.com/lampepfl/gears ; https://github.com/softwaremill/ox ;
https://ox.softwaremill.com/v0.2.0/compare-gears.html ;
https://alexn.org/blog/2025/08/29/scala-gamble-with-direct-style/ ;
https://virtuslab.com/blog/scala/comparing-effect-systems-in-scala-kyo-gears-and-ox

**`frank-and-links` — Frank; Links's JS handler backend — Tier 3.** Frank's multihandlers with
invisible effect variables (the design Unison adapted), and Links's client-side handlers via
Hillerström's higher-order CPS translation (FSCD 2017; JFP 2020) — the first published
handler-to-JavaScript compilation with a correctness proof. *Look for:* deep vs shallow handlers in
the CPS translation; the thesis on what the JS backend cost. *Sources:*
https://arxiv.org/abs/1611.09259 ; https://github.com/frank-lang/frank ; https://links-lang.org/ ;
https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.FSCD.2017.18 ;
https://bentnib.org/handlers-cps-journal.html ; https://www.dhil.net/research/papers/thesis.pdf

**`verse-effects` — Verse (Epic) — Tier 3.** Effect specifiers (`<transacts>`, `<decides>`,
`<suspends>`) rather than rows, designed with Peyton Jones for an engine where "does not support
rollback" is an effect. *Look for:* how `<suspends>` functions are sequenced; effects versus choice
in the calculus. *Sources:* https://simon.peytonjones.org/verse-calculus/ ;
https://simon.peytonjones.org/assets/pdfs/verse-icfp23.pdf ;
https://lobste.rs/s/wskmhg/core_verse_haskell_with_simon_peyton

### Family I — delimited continuations and stack switching

**`racket-scheme-continuations` — Racket — Tier 3.** The reference implementation of the
primitive every family-H runtime wants; Flatt & Dybvig (PLDI 2020) is the cost model; RacketScript
had to face the missing primitive on JS. *Look for:* what RacketScript does about `call/cc`;
composable vs non-composable continuations; measured capture cost. *Sources:*
https://docs.racket-lang.org/reference/cont.html ; https://www-old.cs.utah.edu/plt/publications/pldi20-fd.pdf ;
https://github.com/racketscript/racketscript

**`java-loom` — JEP 444 — Tier 2.** Stack switching added to a mature runtime *specifically to
avoid* async colouring; Pressler's "State of Loom" is the designers' case against family F. *Look
for:* the pinning problem as the cost of retrofitting; why continuations were not exposed; what the
JVM predicts for JSPI. *Sources:* https://openjdk.org/jeps/444 ;
https://cr.openjdk.org/~rpressler/loom/loom/sol1_part1.html

**`wasm-jspi-stack-switching` — JSPI, stack switching, WasmFX, Asyncify, Lexa, Scala.js orphan
await — Tier 2.** The only route by which native suspension reaches a browser, and only for Wasm
frames: JSPI's revised API landed in Chrome M126; Scala.js 1.19 uses it for `js.await` outside
`js.async` with the rule that "there cannot be any JavaScript frame ... between the js.async block
and the call to js.await". *Look for:* JSPI's measured suspend cost; the proposal's status versus
Wasm 3.0; Asyncify's overhead (Zakai, 2019); whether a JS-targeting language could compile hot
loops to Wasm to get suspension. *Sources:* https://v8.dev/blog/jspi ;
https://github.com/WebAssembly/js-promise-integration ; https://github.com/WebAssembly/stack-switching ;
https://wasmfx.dev/ ; https://arxiv.org/abs/2308.08347 ;
https://kripken.github.io/blog/wasm/2019/07/16/asyncify.html ;
https://cs.uwaterloo.ca/~yizhou/papers/lexa-oopsla2024.pdf ;
https://www.scala-js.org/news/2025/04/21/announcing-scalajs-1.19.0/

**`stopify` — Stopify (PLDI 2018) — Tier 2.** First-class continuations for JavaScript by JS-to-JS
compilation, applied to ten language-to-JS compilers and measured — the direct answer to "what
would real continuations cost in beni's output". *Look for:* the overhead table per language and
strategy (exceptions vs generators vs CPS); the sampling heuristic; Pyret's use. *Sources:*
https://arxiv.org/abs/1802.02974 ; https://github.com/nuprl/Stopify

### Family K — implicit lifting and reflection

**`implicit-monads-and-reflection` — Swamy et al. 2011; Filinski 1994; Yang 2023 — Tier 3.** Two
ideas nobody in A–J uses: let the *checker* insert `bind`/`return` as coercions so monadic code is
direct with no syntax at all (Leijen's pre-Koka work, in an ML with HM inference — beni's setting),
and Filinski's proof that any monad is direct-style given `shift`/`reset`. *Look for:* the coercion
algorithm's interaction with HM and where it becomes ambiguous; why Koka went to rows instead;
whether one-shot generators suffice for `reify`. *Sources:*
https://www.microsoft.com/en-us/research/publication/lightweight-monadic-programming-in-ml/ ;
https://dl.acm.org/doi/10.1145/174675.178047 (ACM; 403 to non-browser clients) ;
https://arxiv.org/abs/2307.16073

### Folded in rather than given a report

Eff and Helium are the origin and the ML-module variant of family H; `koka-with-and-effects`,
`effekt` and `frank-and-links` should cite them. Go and Erlang are family J with nothing to sequence;
`elixir-with` and `java-loom` carry what those runtimes teach. Gren was checked: its 2024-08-19
language-changes post covers type-alias syntax, structural sum types and parametric modules and
says nothing about `Task` or sequencing (verified); the `elm` agent should confirm Gren never
discussed it. Agda's scope-resolved `do` is a look-for in `haskell-do-notation`. Roc backpassing
and `!` are in report 15 and are not redone.

---

## 3. Cross-cutting questions every report must answer

Each report's §2 and §4 must answer these, in this numbering, with "not applicable" or "no source
found" rather than silence:

1. **Loop.** Can a bind (or suspension) appear inside a loop body without leaving the mechanism —
   and if not, what is the idiom (fold, recursion, builder `For`, `forM_`)?
2. **Branch.** Can a bind appear inside an `if`/`case` arm without opening a new block, and can the
   bound value be used after the branch?
3. **Early return.** Can the middle of a sequence be left with a value (`return`, `?`, `break`,
   `raise`), and does that interact correctly with `try`/`finally`-style cleanup?
4. **Type-system demand.** A class or trait (with or without HKT), a member lookup, a name in
   scope, an effect row, a colour on the signature, or nothing?
5. **Position.** Statement or `let` position only, last statement of a block, or anywhere an
   expression may — and which compiler pass pays for that?
6. **Per-bind and per-call cost on JavaScript.** Allocation per bind, per call, resume cost per
   suspension, what the engine elides; author, date and platform for every number, or "no verified
   number found".
7. **Optimiser transparency.** Can the language's own inlining, dead-code elimination, renaming and
   code splitting see through the construct, or does it become an opaque object?
8. **Diagnostics and locations.** What a type error inside the construct looks like; whether stack
   traces and source maps survive the transform.
9. **Removed or regretted.** What was withdrawn, deprecated or publicly regretted by the designers,
   and the stated reason.
10. **Effects as values.** Does the mechanism preserve deferred execution, retry, cancellation and
    interpretation by a runtime, or collapse effects into native side effects?

---

## 4. Deliberately out of scope

**Concurrency-runtime design** — fibers, schedulers, cancellation, structured concurrency — is
report 16's subject; a candidate is studied for how its *sequencing* is written and compiled, and
its runtime cited only where the two cannot be separated (Effect-TS, Kotlin, Loom).

**Error-handling syntax on `Result` alone** (`?` on `Result`/`Maybe`, Elixir `with`) is in scope
only as a shape that generalises to `Task`; pure-`Result` ergonomics are settled in
`fast-compiler.md` §3.2 and not reopened.

**Wasm as a beni target.** JSPI, WasmFX and Lexa are studied for what native suspension costs and
buys, not as a proposal to change the target; the shared brief fixes JavaScript.

**Dependently typed uses** of `do` (Lean tactic blocks, Idris totality, Agda) — only the sequencing
mechanism is in scope.

**Reactive and FRP formulations** (Rx, streams, signals) sidestep the pyramid by changing the
programming model rather than the syntax; a different research question.

**Proof-of-concept effect libraries** outside the list (Turbolift, atnos-eff, Fram, Desk, Freak,
cpp-effects, libhandler, libmprompt, Pyro) are in Yallop's bibliography and add no mechanism not
already represented; an agent who finds one decisive may cite it.

**Secondhand summaries** — DeepWiki pages, Medium walkthroughs, aggregators — are excluded as
sources throughout; every agent cites the designer, the spec, the compiler source or the measured
benchmark.
