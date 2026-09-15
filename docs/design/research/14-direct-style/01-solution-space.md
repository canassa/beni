# Direct-style effects: the solution space

**What this is.** A synthesis of the seventeen per-subject reports in this directory, written for
a decision that has not been made. It states the problem plainly, lays out the choices beni
actually has, and attaches to each choice the evidence the reports found: what it buys the user,
what it costs, and what the people who built it say. It does not recommend. Every claim below is
traceable to a report in this directory, named in parentheses; nothing here is new research.

**Scope.** Ergonomics only, per the programme's rule. Nothing about performance appears below.
The one fixed fact is the JavaScript target. Everything else, including things
`fast-compiler.md` §3.1 currently treats as settled, was treated as open.

---

## 1. The problem, restated with what we now know

Sequencing two `Task`s means `andThen`, and holding an earlier value alive means staying inside
the closure that received it. That is the pyramid. Three things the reports established change
the shape of the problem before any mechanism is chosen.

**The pyramid is real but rare in Elm, and the reason is scarcity, not architecture.** Across
six large public Elm repositories, 765 declarations contain an `andThen`; twelve reach depth
three, two reach depth four, none deeper, and both depth-four cases are artificial tests. There
are 19 task-producing primitives in all of `elm/*`, no package may add one, and the official guide
has no `Task` chapter. Elm's continuation of an effect is a `Msg` branch in `update`, a
hand-written CPS transform at the application level (`elm.md` §0.1, §1, §5.4). beni intends a
richer platform surface (`13-the-javascript-boundary.md`), so this null result is evidence about
Elm's ecosystem, not about the shape of the problem.

**Where Elm users do hit it, the formatter is the binding constraint.** The flat form
`f a <| \x -> rest` is legal Elm; `elm-format` re-indents it by twelve columns per bind. The
one-rule fix has been open since 2018 with Feldman calling the whole design "moot" without it;
Gren shipped `Task.await` with flipped arguments and writes its own examples flat; `elm-pages`
shipped a continuation module that tells users to replace their formatter and has zero importers
(`elm.md` §0.2, §4.1). beni ships its formatter in M1.

**The three Elm complaints separate cleanly and the pyramid is the smallest.** Zero of 22
Discourse "nesting" threads concern `andThen`; the largest state-of-the-language thread has eight
pyramid posts by one author against 38 on type classes from five; four companies with 300k lines
between them name no effect-ergonomics cost. The two practitioners who hit it hardest talked
each other out of wanting do-notation in public in 2025, on the argument that most binds are
really `map` or `map2` and the genuine average is one bind per function (`elm.md` §5). When Elm
users say "callback hell" they mean parallelism wiring with `Task.map2`, not sequential binding
(`elm.md` §5.4).

What this calibrates rather than decides: the straight-line chain is the common case and the
branch is where Elm's residual pain sits; loops do not arise because Elm has none; parallel
composition matters at least as much as sequential.

---

## 2. Three axes, not one

Every mechanism in the seventeen reports sits on three independent axes. Conflating them is how
prior drafts of `fast-compiler.md` §3.2 got the cost model wrong.

**Axis 1, where the marker may appear.** Statement or `let` position only (Gleam `use`, OCaml
`let*`, F# `let!`, Haskell `do`) versus anywhere an expression may appear (Rust `?`/`.await`,
Roc's removed `!`, C# `await`, JS `yield`). Report 15 measured this as the compiler-cost axis:
44 lines for Roc's block-shaped rewrite against 1,046 for its anywhere-marker, which shipped a
crash. Every report here confirms the axis but two refine it. OCaml's `let*` is grammatically
"anywhere an expression may appear" yet cost nothing, because `let` *is* the production rather
than a marker inside one (`ocaml-let-operators.md` §2.6). And the anywhere-marker cost vanishes
when the host does the suspension: V8 already resumes at any bytecode offset, so a compiler
emitting `yield` pays nothing for arbitrary position (`javascript-async-await-v8.md` §2.5).

**Axis 2, whether the whole function body is transformed or only the rest of a block.** This is
the expressiveness axis. Only whole-body transforms (C#, Rust, Kotlin, generators, Lean's
elaborator, Koka's monadic pass) put a bind inside a loop or under a branch with the value live
afterwards. Every rest-of-block rewrite needs a fold for the loop and a new block for the branch
(`gleam-use.md` §2.4, `fsharp-computation-expressions.md` §0.2 for the one exception, which
buys it with a `For` builder member). Lean shows the loop case needs no monad transformer at all:
a state tuple of the mutated variables plus an `Option` early-return slot and a two-constructor
step type (`lean4-do-elaborator.md` §0.2).

**Axis 3, statements versus expressions.** This is the reading-flat axis and it is a language
question, not a codegen one. Effect-TS reads flat because a generator body is a statement list;
generators buy arbitrary-position binds and statements buy flat reading, and adopting one without
the other delivers half the brief's example (`effect-ts.md` §0.2, §6; `regenerator-and-tsc-downlevel.md`
§6). For beni specifically the cost is smaller than the reports assume, because beni's `let`
already lowers as a statement sequence and a bind inside an `if` arm nests exactly as pure code
does, which is not extra nesting. What an expression language cannot do without new syntax is a
loop with a mutable accumulator and a bind in its body; it writes a recursive helper, which is
flat at depth one and is what Elm does today (`elm.md` §2).

A fourth fact cuts across all three. **On JavaScript, every direct-style design ends up building
the same backend thing.** The host cannot suspend a stack, so Koka builds an evidence-passing
runtime with a `yielding()` test after every effectful call, js_of_ocaml builds a selective CPS
transform driven by a whole-program dataflow fixpoint, Effekt builds `shift`/`reset` on JS
exceptions with a trampoline, Kotlin/JS emits a state-machine class, Effect-TS drives a native
generator from a fiber (`koka-with-and-effects.md` §0.2, `ocaml5-effects-and-jsoo.md` §0.2,
`effekt.md` §2, `kotlin-suspend-and-arrow.md` §4, `effect-ts.md` §0.1). The type system decides
what the user writes and what is checked; it does not remove the lowering.

---

## 3. The options for beni

Five surface designs, three lowerings, and a set of sub-decisions that recur under every option.
They combine; §5 lists the combinations that the evidence supports.

### S0. Change nothing in the language: fix the formatter and add `Task.await`

```elm
fetchSummary =
    Task.await getUser <| \user ->
    Task.await (getPermissions user) <| \perms ->
    if perms.isAdmin then
        Task.map (\log -> Summary user perms (Just log)) (getAuditLog user)
    else
        Task.succeed (Summary user perms Nothing)
```

`Task.await` is `andThen` with flipped arguments; the formatter rule is "do not indent after a
trailing `<|` followed by a lambda". Four Elm-family projects reinvented this independently
(`elm.md` §5.4). Cost: zero in the type system, desugarer and diagnostics; one formatter rule.
Buys: flat straight-line chains and a flat branch, since the branch sits inside the lambda body
like any expression. Does not buy: a bind inside a fold body without a `Task.foldl`, early exit,
or a bind in argument position. The hand-rolled flat idiom is fragile in one documented way: Elm's
`|>`/`<|` mixing rule produces a confusing parse error (`elm.md` §4.2). The Elm report's own
conclusion is that this should be evaluated before any language change because in Elm the
language change was never the binding constraint (`elm.md` §6.3).

### S1. A bind form at `let` position: `let x <- e in`

```elm
fetchSummary =
    let
        user <- getUser
        perms <- getPermissions user
    in
    if perms.isAdmin then
        let log <- getAuditLog user in
        Task.succeed (Summary user perms (Just log))
    else
        Task.succeed (Summary user perms Nothing)
```

This is the family that OCaml, Gleam, Koka, Roc and F# invented independently and that
Haskell's own extensions retreated to over thirty years: `QualifiedDo` and `RebindableSyntax`
drop the class for name resolution, Agda did the same, PureScript re-derived qualified `do` for
the case its classes could not reach (`haskell-do-notation.md` §0.1, `purescript-do-and-magic-do.md`
§0.3). It needs nothing from the type system beyond knowing which `andThen` to call.

What it desugars to is settled: `Task.andThen e (\x -> rest)`, with `rest` being the remaining
bindings and the body, which beni's `let` already lowers in source order (report 15 §0.3).

**Resolution is the one design point.** With `Task`, `Result` and `Maybe` all two-parameter
types, the `?` operator's ordered speculative unification already silently picks `Result` in
beni's checker; a `<-` bind must not repeat that (`fast-compiler.md` §3.2 point 3). The options
are: infer the right-hand side first and dispatch on its head constructor from a closed table,
which is what Gleam does inside inference and what Lean must do; or an explicit qualifier such as
`Task.let`, the `QualifiedDo` shape an Elm practitioner independently proposed in 2025
(`elm.md` §5.2). Gleam's record is the warning: "nothing for the type system" still cost four
bespoke diagnostics, two enums threaded through call inference, a stack-growth guard, a formatter
function, an LSP code action and two shipped confusing-error bugs where a pipe on the right of
`<-` named synthetic types (`gleam-use.md` §0.2, §4).

Buys: the straight-line chain and the branch, both flat, with exact error locations because the
rewrite is local. Does not buy: a bind in a fold body, a bind in argument position, early exit.
Gleam's community filed a request for the branch limitation and none for the loop limitation,
which is consistent with recursion being the normal idiom (`gleam-use.md` §5). Koka's `with`
inherited lambda-parameter grammar for its binder, narrower than `let` patterns, and users
noticed after five years (`koka-with-and-effects.md` §2.3). Lean's 2026 `do←` shows the
trailing-lambda shape can be made transparent to the enclosing block's control flow, checked by
the wrapper's type `(… -> m a) -> m a` (`lean4-do-elaborator.md` §0.3).

### S2. A bind marker anywhere inside a `Task` block: `e!`

```elm
fetchSummary =
    Task.do
        let
            user = getUser!
            perms = getPermissions user!
        in
        if perms.isAdmin then
            Summary user perms (Just (getAuditLog user!))
        else
            Summary user perms Nothing
```

The body has type `Summary`; the block has type `Task e Summary`; `!` is legal only inside. This
is the shape of C#'s `await`, Rust's `.await`, Kotlin's suspend call, Effect-TS's `yield*` and
Lean's `(← e)`, and it is the shape Effect's own team chose when they had a compiler, as
`$(e)` rather than `yield*` (`effect-ts.md` §3.5). It is also the shape Roc shipped as Task `!`
and removed.

Two sub-choices. **Block or colour.** A `Task.do` block is an expression and functions keep
visible `Task` types; the alternative is Rust's and C#'s, where any function whose return type is
`Task e a` may use `!` and its body is written at type `a`. The block form avoids Evan's
substitution objection because the block boundary is explicit; the colour form is what `async fn`
is, and Lippert's eight-way trade-off for requiring the `async` keyword is mostly about tooling
diagnostics for a forgotten `await` (`csharp-async-state-machine.md` §0.3). **Position of `!`.**
Lean deliberately hoists `(← e)` only to the enclosing block, narrower than Idris's "as high as
possible", for predictability, and an unverified consequence is that `(← p) && (← q)` loses
short-circuiting (`lean4-do-elaborator.md` §2.3, §8).

Buys: everything. Bind in a branch with the value live after, bind in argument position, bind
in the body of a recursive helper that is itself a `Task.do`, and early exit if the block has a
`return`. Costs are in the lowering (§4) and in one hazard the reports agree on: an effect value
computed and not marked is a value silently thrown away, which typechecks. Effect-TS polices it
with an editor diagnostic; Elm cannot have the bug because there is no statement position to
drop a value in (`effect-ts.md` §4.3). In beni's expression language the hazard is narrower,
since an unused `let` binding is already visible, but `getUser` without `!` in a `Task.do` is
a `Task` where a `User` was expected and would be a type error, which is the better outcome.

### S3. Effect typing without values: purity inference

Roc deleted `Task` in 2025 and replaced it with a three-state lattice on function types inside
ordinary unification, pure, effectful, or unbound-with-dependencies. `f!` is a checked naming
convention with zero desugaring; the 1,046-line `!` rewrite was deleted; diagnostics point at
real code because nothing is rewritten (`roc-purity-inference.md` §0.1, §4). It is the cheapest
effect-typing mechanism in the survey and the flattest `fetchSummary` in any report, because it
removes the mechanism rather than improving it.

What it costs is the thing beni's `Task` exists for. Effects are no longer data, so retry,
batching, cancellation, concurrency combinators and Elm-style testability have no home; twenty
months later Roc's own platform maintainers still have no replacement and the compiler quietly
grew the internal effect polymorphism the design publicly rejected, patched for a soundness bug
five days before the report was written (`roc-purity-inference.md` §0.2, §0.3, §4). And Roc's
"effectful call is just a call" depends on a native host that can block; on JavaScript every
real effect is a promise, so either `!` is restricted to synchronous primitives or the generated
code must still suspend, which brings back exactly the lowering of §4 (`roc-purity-inference.md`
§6). Koka's async-as-library-on-handlers was built for JavaScript in 2017, named the pyramid of
doom as its motivation, and did not survive the v2 rewrite (`koka-with-and-effects.md` §0.3).

### S4. Effect typing with handlers: rows or capabilities

Koka (rows) and Effekt (capabilities, second-class blocks, capture sets) both make an effectful
call an ordinary call and both solve every hard case by construction, including multi-shot
resumption, which no generator can do (`koka-with-and-effects.md` §6, `effekt.md` §0.1). Both
compile to JavaScript today.

The costs the reports found. Rows in an HM language meet let-generalisation: `val f = get` loses
effect polymorphism and "extract a local" breaks a program that typechecked, open since 2023
(`koka-with-and-effects.md` §4.3). Effect-mismatch errors point at whole blocks and ask the user
to diff two rows by eye. Koka has no source maps after nine years and no formatter, blocked partly
by `with` creating two spellings of one program. The handler pipeline is roughly 1,550 lines of
Core passes plus a runtime, and a 380-line pass exists solely because the transform introduces
lambdas around code containing `return`. Effekt keeps safety without rows by making blocks
second-class, which beni's first-class closures at the JavaScript boundary would have to
un-learn, and its current backend has a maintainer-acknowledged soundness gap in `resume`
(`effekt.md` §4, §6). PureScript removed its effect rows in 2017 on ergonomic grounds, with a
named critic calling them "enormous work for developers" for "no more actual guarantee"
(`purescript-do-and-magic-do.md` §3). OCaml shipped effects untyped in 2022 promising a typed
layer and the maintainer who made the promise retracted it in 2026; and untyped effects make an
unhandled `perform` a well-typed program that crashes, which beni's guarantee forbids
(`ocaml5-effects-and-jsoo.md` §0.3, §6). Nobody in the sources is maintaining a large Koka or
Effekt codebase (`koka-with-and-effects.md` §5, `effekt.md` §5).

Flix is the third design in this family and the one that changes the calculus. Its effects are
Boolean or set formulas over effect names, solved by a dedicated unifier rather than rows, and
one `List.map` signature, `f: a -> b \ ef`, serves pure and effectful callbacks with no second
definition (`flix-effects.md` §0, §7.2). It sidesteps Koka's extraction hazard by never
generalising local `let`s, at the cost of top-level definitions having to state their effect
exactly (`flix-effects.md` §7.3). Its handlers compile to ordinary heap objects with a reified
resumption list, so the shape should transfer to JavaScript (`flix-effects.md` §7.6). What it
shares with Koka is the diagnostics problem: effect errors print unminimised formulas with
synthesised variable names, an acknowledged open backlog (`flix-effects.md` §7.5).

---

## 4. The lowerings

S1 has one lowering: closures. S2 and anything in S3/S4 need one of three.

**L1, frontend rewrite to `andThen` chains with join points.** This is what Lean's elaborator
does for everything tail-resumptive and what Koka's monadic pass does for all effectful code: a
continuation-passing walk where each construct receives "the rest of the block", `return` and
`break` are jumps, and a join point is introduced whenever the continuation is wired in more than
once. Without join points a `return` in one arm duplicates the rest of the block into every arm,
which is exponential code size, and this is why Lean's continuation carries a `duplicable` flag
(`lean4-do-elaborator.md` §0.1, §6). Roc's 1,046-line `suffixed.rs` was the naive version of
this without join points and shipped a crash (report 15 §4). Koka's pass needed an `UnReturn`
prepass because a lambda introduced around a `return` changes what it returns from; that is the
same hazard `fast-compiler.md` forbids `?` inside a lambda to avoid (`koka-with-and-effects.md`
§4.1). Output is plain closures and calls: transparent to beni's optimiser, effects stay values,
exact source locations, stack frames are synthesised continuations with generated names.

**L2, a state machine beni emits itself.** regenerator and TypeScript's `generators.ts`
converged independently on one architecture: a linear listing with back-patched labels, a
`while(1) switch`, a stack of enclosing loop/switch/try entries, and a static try-region table
the runtime searches for `finally`. TypeScript's 120-line header comment is an executable spec
with eleven opcodes and an emission table. The hard part is expressions: every sibling
subexpression of a suspension is spilled to a temporary because the compiler cannot prove it is
unchanged across the suspension (`regenerator-and-tsc-downlevel.md` §0.1, §0.2). Type-blind,
backend only, transparent to a minifier, and beni controls the protocol so the wrapper is a dozen
lines rather than tslib's iterator conformance. Debugger discipline is the known trap: hoisted
declarations must be left unmapped or breakpoints fire before the await, a bug both projects
shipped. Stack traces lose the user's function name irreducibly. TypeScript is deleting the
transform for complexity and the Go port never had it; Babel is still fixing hoisting and `try`
bugs in it in 2025 (`regenerator-and-tsc-downlevel.md` §3, §4.3). Kotlin/JS ships this shape
today for `suspend` (`kotlin-suspend-and-arrow.md` §4).

**L3, native generators plus one runtime op.** Emit the block as `function*`, add an `ITERATOR`
tag to the scheduler beside `AND_THEN`, and V8 does the suspension. `async`/`await` is literally
`spawn(function*(){…})` by its own proposal and the spec still shares one suspend/resume
primitive between the two (`javascript-async-await-v8.md` §0.1). Effect-TS's history shows the
naive per-yield `flatMap` version works first and the dedicated run-loop op can replace it later
(`effect-ts.md` §3.3, §6). Cheapest to build. What it does not give: the two engine wins that
belong to native `async` only, zero-cost async stack traces and single-microtick resumption,
because both rely on the engine knowing the resume site is the suspend site, which is false for
a `.next()` issued by a driver; source locations inside the block, which Effect reconstructs from
two synthetic `Error`s and a rejected Babel plugin; and `finally`, which Effect never runs on
failure because the fiber discards the frame (`javascript-async-await-v8.md` §0.3,
`effect-ts.md` §3.4, §2.4). The generator is opaque to beni's own inlining and renaming, and
`yield` cannot cross a function boundary at parse time, so any helper lambda that binds must
itself be a generator driven by `yield*` (`javascript-async-await-v8.md` §0.2, §4.2). One-shot
only, permanently.

L1 and L2 can both be exact about locations because beni emits them; L3 cannot without extra
work. L2 and L3 are indifferent to the type system; L1 runs after inference like the rest of the
desugarer. Fable, an F#-to-JavaScript compiler, evaluated F#'s state-machine backend for its JS
target and declined it, re-implementing the closure desugaring by hand over promises
(`fsharp-computation-expressions.md` §0.3).

---

## 5. Sub-decisions that recur under every option

These are independent of S and L and each has a documented failure mode.

1. **Implicit `succeed` at the tail.** S2 assumes it; S1 as sketched does not. Rust's `try`
   blocks have been unstable for a decade over exactly this "Ok-wrapping" question, with the
   filer of the objection reversing himself years later (`rust-question-mark-and-async.md` §3).
   Haskell, Lean and F# require an explicit `pure`/`return`; Effect-TS's `return v` is implicit
   because it is a generator.

2. **`?` and `!` as two operators or one.** Rust's `?` and `.await` are orthogonal and compose
   by juxtaposition: `get_user().await?` (`rust-question-mark-and-async.md` §0.1). Effect-TS
   makes `Either` a degenerate `Effect` so one `yield*` handles both and the error channel is a
   union (`effect-ts.md` §2.4). beni's `Task e a` already carries an error, so `!` propagates
   Task failure and the question is only what `!` does to a `Result` inside a `Task` block:
   reject, or lift via a per-type table. Rust's own designers retracted automatic `From`
   conversion inside `?` for inference reasons that apply to any HM checker
   (`rust-question-mark-and-async.md` §0.3); beni's rule 2 already matches the retracted-to
   position.

3. **Higher-order functions with effectful callbacks.** This is the real "loop" problem in an
   expression language, and it is where every design pays. Haskell lives with `forM_`, `foldM`,
   `when` and has for thirty years (`haskell-do-notation.md` §2). Roc rejected user-facing
   effect polymorphism after a 101-message debate and accepted a duplicated standard library,
   `List.walk` beside `List.walk!` (`roc-purity-inference.md` §3.2). Rust's answer is a
   multi-year, still-unstable effects initiative (`rust-question-mark-and-async.md` §3). Kotlin
   solves it with `inline`, which splices the lambda into the caller's state machine
   (`kotlin-suspend-and-arrow.md` §0.2). Koka and Effekt solve it with effect polymorphism, at
   the cost in S4. Lean's `do←` and Kotlin's inline are the same idea: a lambda passed to a
   wrapper of a known shape is transparent to the enclosing block. For beni the choices are
   `Task.traverse`/`Task.foldl` combinators (status quo), a duplicated `!` family on the
   standard library, or a checked forwarding rule for lambdas in a known argument position.

4. **Early return and `return` inside lambdas.** Lean chose block-local `return`, conjectured it
   would confuse users, and paid for an LSP highlight to compensate; a labelled-jump proposal is
   open (`lean4-do-elaborator.md` §2.3). Rust's `?` inside a closure returns from the closure by
   the desugaring rule (`rust-question-mark-and-async.md` §2.1). beni already forbids `?` in a
   lambda; the same rule would apply to `!`.

5. **Refutable patterns on a bind.** Haskell split `MonadFail` out of `Monad` because giving
   every monad a fallback `error` was "clearly a hack"; PureScript wraps the rest in a single
   `case` and lets exhaustiveness checking fire (`haskell-do-notation.md` §3,
   `purescript-do-and-magic-do.md` §2.5). beni's `let` patterns are irrefutable already; a bind
   inherits that for free, or a refutable pattern must widen into the `Task`'s own error channel.

6. **Parallel binds.** OCaml's `and+` was the contested half of its design and won on a
   correctness argument: for Incremental the choice between `and+` and a second `let*` changes
   asymptotic recomputation (`ocaml-let-operators.md` §0.1). F# has `and!`; ApplicativeDo's
   dependency analysis is a published algorithm that needs no class
   (`haskell-do-notation.md` §6). TC39 refused parallel-`await` syntax eight times in two years
   with "just type `Promise.all`" (`javascript-async-await-v8.md` §3.3, §5). Elm's "callback
   hell" is this problem. One fixed `let a <- t1 and b <- t2` shape for `Task` sidesteps the
   user-defined-operator objection (`ocaml-let-operators.md` §6.1).

7. **Statements, loops and local mutation.** Lean added `for`, `let mut`, `break`, `continue`
   to its `do` and shipped implicit mutability first, then reverted it after scope-confusion
   bugs (`lean4-do-elaborator.md` §3.2). Roc added `for` and `var`. F# and C# had them. Without
   them the loop win is recursion, and the reports are consistent that recursion is acceptable
   in a language that has always used it (`gleam-use.md` §5, `elm.md` §2). This is a separate
   language decision from the bind mechanism.

8. **Evaluation order when one type is flattened specially.** PureScript's MagicDo makes
   `Effect` do-blocks the one place where argument-evaluation order differs from source, open
   since 2020 (`purescript-do-and-magic-do.md` §3). If beni desugars uniformly and flattens
   `Task` later, the flattening must not move when arguments are evaluated.

9. **The formatter.** Koka has no formatter after nine years because `with f` and
   `f(fn(){…})` are two spellings of one program the formatter must not unify
   (`koka-with-and-effects.md` §4.4). Gleam's formatter shipped a comment-splicing bug for a
   construct whose body is implicit (`gleam-use.md` §4). Elm's formatter is the whole reason the
   flat idiom is unused. Whatever beni adds, the formatter rule is part of the feature.

10. **Diagnostics and source locations.** Every whole-body lowering pays here. Effect paid
    twice; TypeScript shipped a breakpoint bug; C# added a runtime attribute years later to hide
    generated frames; Kotlin/JS emits an extra temporary purely so a breakpoint on a closing
    brace can be hit (`effect-ts.md` §3.4, `regenerator-and-tsc-downlevel.md` §0.3,
    `csharp-async-state-machine.md` §4, `kotlin-suspend-and-arrow.md` §4). Budget it as a
    deliverable.

---

## 6. Combinations the evidence supports, and what each gives up

Not a ranking. Each row is a coherent design that at least one shipped system has run.

| | Surface | Lowering | Loop in a fold body | Bind in argument position | Effects stay values | Exact locations | Precedent |
|---|---|---|---|---|---|---|---|
| **A** | S0 formatter + `Task.await` | none | combinators | no | yes | yes | Gren, elm-pages |
| **B** | S1 `let x <- e` | closures | combinators | no | yes | yes | Gleam, OCaml, F# classic |
| **C** | S2 `e!` in `Task.do` | L1 join-point CPS | combinators or forwarding rule | yes | yes | yes | Lean, Koka's pass |
| **D** | S2 `e!` in `Task.do` | L2 own state machine | same | yes | yes | with discipline | Kotlin/JS, tsc |
| **E** | S2 `e!` in `Task.do` | L3 native generators | same | yes | yes | no, must add | Effect-TS |
| **F** | S3 purity inference | L1/L2/L3 underneath anyway | duplicated stdlib | yes | **no** | yes | Roc |
| **G** | S4 rows or capabilities | evidence passing or CPS | effect polymorphism | yes | reify by hand | no source maps in Koka | Koka, Effekt |

A and B are cheap and give up the same two things. C, D and E give up nothing in expressiveness
and differ in where the bill lands: C in a frontend pass with join points, D in a backend pass
with debugger discipline, E in a runtime op plus a location story. F and G buy flatness by
changing what an effect is, and both lose or must rebuild the `Task` vocabulary report 16 says
the runtime needs.

A is compatible with every other row and is the only one Elm's evidence says is certainly worth
doing.

---

## 7. What the builders would say, in one line each

- Evan Czaplicki: a binding form where `let x = f a` and `let x = f! a` differ in how many times
  the effect happens breaks "you can always substitute an expression in", and non-programmers
  notice (`elm.md` §6).
- Richard Feldman: a bind marker makes `let` ordering significant silently; teach it
  (`elm.md` §6). And later, from Roc: early returns inside synthesised lambdas were the reason
  backpassing died (report 15).
- Louis Pilfold: "it's just sugar" understates the compiler surface a feature grows once real
  programs use it; refuse the second special case (`gleam-use.md` §6).
- Leo White and Yaron Minsky: the applicative parallel bind is a correctness matter, not a
  convenience (`ocaml-let-operators.md` §0.1).
- Ullrich and de Moura: make mutability opt-in; decide where `return` returns to on day one;
  the loop is the part that resists (`lean4-do-elaborator.md` §6).
- Daan Leijen: too many join points, and no zero-cost way to elide the yield checks
  (`koka-with-and-effects.md` §6). Jonathan Brachthäuser wrote Koka's `with` and then built
  Effekt on capabilities to avoid row inference.
- Michael Arnaldi: pay only for syntax that expresses something the old form could not; and
  changing the semantics of a file you do not own is "a terrible idea", which does not apply
  to a language that owns its grammar (`effect-ts.md` §6).
- Ben Newman: "it's the trickiest code I've ever written"; source maps become an absolute
  necessity (`regenerator-and-tsc-downlevel.md` §6). Daniel Rosenwasser: "quite a bit of
  complexity", and did not port it.
- Eric Lippert: require the marker for the tooling's sake, not the compiler's
  (`csharp-async-state-machine.md` §0.3).
- withoutboats: do not let a representation detail leak into user code before checking every
  place it must be named; treat cancellation cleanup as a separate design from the happy path
  (`rust-question-mark-and-async.md` §6).
- Roman Elizarov: colouring is documentation, and structured concurrency is the actual payoff
  (`kotlin-suspend-and-arrow.md` §0.3, §5).
- Gabriel Scherer: do not justify shipping the untyped thing with a typed layer you have not
  staffed (`ocaml5-effects-and-jsoo.md` §0.3).
- TC39: no sugar for parallel await; do not let the suspension primitive silently pick a policy
  the user cannot see (`javascript-async-await-v8.md` §6).

---

## 8. What the reports could not settle

- Whether V8 elides the per-call generator allocation, and every other runtime-cost question:
  out of scope by rule, and still unmeasured (`javascript-async-await-v8.md` §8).
- Whether Elm's formatter maintainer had a principled objection to the flat style or merely left
  the issue open (`elm.md` §8).
- Any practitioner account of maintaining a large Gleam, Koka or Effekt codebase; the evidence
  for the rest-of-block and handler families is designers and evaluators only.
- Whether `(← p) && (← q)` in Lean actually loses short-circuiting in practice
  (`lean4-do-elaborator.md` §8).
- Why Arrow rewrote `either { }` off continuations onto an inline function and an exception
  (`kotlin-suspend-and-arrow.md` §8).
- Source-map fidelity through any CPS-converted or generator-lowered code, in every report that
  looked: no verified claim found in either direction.
- Most of the second wave was not run: Swift's two orthogonal effect markers, Scala's capture
  checking and Kyo, the implicit-bind designs of Swamy and Filinski, dotty-cps-async's transform
  rules, and Elixir's `with`. Flix was run as a short report after the synthesis was first
  written. The implicit-bind entry is the one idea no row above contains.
- Madsen's own rationale for Boolean effects over rows, and any practitioner account of Flix's
  effect system: the papers were unreachable and the search budget was gone
  (`flix-effects.md` §8).
