# Proposal: typed effects as calls, with the platform as the only handler

**Status:** proposal, 2026-09-14. Not decided. Written for review. Every claim about another
language cites a report under `research/14-direct-style/`; every claim about beni cites the
design document it depends on. Sections marked **Sub-decision** are choices the proposal makes
that a reviewer should challenge; §12 lists the questions reviewers are asked to answer.

**What it assumes, already decided elsewhere.** No automatic currying, `_` placeholder, pipe-first
`|>`, n-ary types `Int, Int -> Int`, and a rest-of-block bind `let x <- e` for `andThen`-shaped
types (`fast-compiler.md` §9.3). JavaScript is the target. Elm's wall: user code does not reach
arbitrary JavaScript, effects cross a controlled boundary, well-typed code does not throw
(`fast-compiler.md` stance). Errors are `Result` values and `?` unwraps them (`language.md` §6.6).
Ergonomics is the goal and compiler complexity is an acceptable price (the author's stated
position for research 14).

---

## 1. The problem this solves

Sequencing two `Task`s means `andThen`, and holding an earlier value alive across an effect means
staying inside the closure that received it. Research 14 established three things about that
pyramid. It is rare in Elm because Elm has almost nothing to chain: 19 task primitives, closed to
packages, and no `Task` chapter in the guide (14/elm §0.1). Where it is hit, the formatter is the
binding constraint (14/elm §0.2). And the residual pain sits at the branch, not the loop, because
Elm has no loops (14/elm §2). beni intends a richer platform surface (`boundary.md`,
research 13), so the null result is about Elm's ecosystem, not the shape of the problem.

The rest-of-block bind already adopted removes the pyramid for straight-line code
(`fast-compiler.md` §9.3, delta item 7). What it does not give, and what this proposal is for:

1. **A bind in argument position.** `Summary user perms (Just (getAuditLog user!))` instead of a
   separate binding and a `succeed` at the tail.
2. **One standard library.** `List.map xs (\id -> getUser id!)` instead of `Task.traverse`, and
   the same for `filter`, `foldl`, `any`, `Dict.map`, and every other function that takes a
   callback. Every effects-as-values language pays this forever: Haskell's `forM_`/`foldM`/`when`
   zoo after thirty years (14/haskell §2), Roc's `List.walk` beside `List.walk!` accepted after a
   101-message debate (14/roc §3.2), Rust's still-unstable effects initiative (14/rust §3).
3. **Effects named in signatures.** Which functions reach the network, which ones only log. One
   `Task` bit says "does something"; the author's stated requirement is to tell those apart.
4. **The type system tells the backend what to lower.** Only functions with a non-empty effect
   set need suspension machinery; pure functions compile to plain JavaScript. js_of_ocaml had to
   build a whole-program dataflow analysis to recover this because OCaml's effects are untyped
   (14/ocaml5 §0.2); Koka and Effekt get it from the types (14/koka §4.1, 14/effekt §2).

---

## 2. The design on one page

- **Every function type carries a set of effect names.** `getUser : UserId -> User ! {Net}`.
  The empty set is purity and is omitted: `add : Int, Int -> Int`.
- **Effects are declared by the platform.** `Net`, `Dom`, `Log`, `Clock`, `Random`, `Time`, and
  whatever else `boundary.md`'s platform exposes. User packages cannot declare effects in this
  version (**Sub-decision**, §9.1). Aliases bundle them: `effect alias Io = {Net, Dom, Log, Clock}`.
- **An effectful call is marked at the call site**: `getUser id!`. An unmarked call to an
  effectful function is a compile error; a `!` on a pure call is a compile error.
- **Effects are inferred inside bodies and written at top level.** A function's effect set is
  the union of the effects of its marked calls. Top-level annotations name the set, as Elm
  convention names every top-level type. Local `let` bindings are never generalised over
  effects (Flix's rule, 14/flix §7.3), so there is no Koka-style "extract a local and it breaks"
  hazard (14/koka §4.3).
- **Higher-order functions are effect-polymorphic by unification.**
  `List.map : List a, (a -> b ! e) -> List b ! e`. Pure callback, pure map; effectful callback,
  effectful map. One definition.
- **A pure function cannot call an effectful one.** That is Roc's guarantee (14/roc §1), and it
  is a type error, not a lint.
- **Errors stay in `Result`, unwrapped by `?`, orthogonal to effects.** `getUser id!?` performs
  and then unwraps. Flix and Rust keep the two apart (14/flix §7.7, 14/rust §0.1), and it
  preserves "well-typed code does not throw".
- **The platform is the only handler and every effect is one-shot.** An effectful call reaches
  the runtime, which performs it, possibly asynchronously, and resumes the caller exactly once,
  or never (cancellation). No user-installed handlers, no multi-shot resumption.
- **Deferral is a thunk.** `\() -> fetchSummary id!` has type `() -> Summary ! {Net}` and runs
  nothing until called. Retry, timeout, parallel composition and cancellation scopes are
  effect-polymorphic platform functions over thunks.
- **The Elm Architecture is unchanged.** `update` is pure. Effectful code lives in functions the
  runtime is handed as thunks: `Cmd.run (\() -> fetchSummary id!) GotSummary`.

What the brief's example becomes:

```elm
fetchSummary : UserId -> Summary ! {Net}
fetchSummary id =
    let
        user = getUser id!
        perms = getPermissions user!
    in
    if perms.isAdmin then
        Summary user perms (Just (getAuditLog user!))
    else
        Summary user perms Nothing

fetchAll : List UserId -> List User ! {Net}
fetchAll ids =
    List.map ids (\id -> getUser id!)
```

---

## 3. Surface syntax

### 3.1 Types

```
Type        := ParamList? TypeApp Effects?
ParamList   := TypeApp (',' TypeApp)* '->'
Effects     := '!' EffectSet
EffectSet   := '{' '}' | '{' EffectName (',' EffectName)* '}' | lower_ident | '{' EffectName (',' EffectName)* '|' lower_ident '}'
EffectName  := upper_ident | qualified_upper
```

- `Effects` may appear only on a function type, after its result. `Int ! {Net}` on a non-function
  type is `effects_on_non_function`.
- A `lower_ident` effect is an effect variable, `e`. `{Net | e}` is "at least `Net`, plus
  whatever `e` is". `{}` is explicit purity and is what the formatter removes.
- `->` is right-associative and binds loosest, as decided: `a, b -> c -> d ! e` is a 2-ary
  function returning a 1-ary function whose effect is `e`; the outer function is pure. A
  function-typed parameter is parenthesised: `List.map : List a, (a -> b ! e) -> List b ! e`.
- **Sub-decision, spelling.** `!` is chosen so the type marker and the call marker are one
  concept. Alternatives: Effekt's `/ {Net}`, Flix's `\ {Net}`, Roc's `=>` (which names no set).
  A reviewer who finds `Summary ! {Net}` misreads as "not Summary" should say so.

### 3.2 Declarations

```
EffectDecl  := 'effect' upper_ident                                -- platform package only
EffectAlias := 'effect' 'alias' upper_ident '=' '{' EffectName (',' EffectName)* '}'
```

`effect Net` outside the platform package is `effect_outside_platform`, by the same rule that
confines `foreign` (`language.md` §5.4). Aliases are allowed anywhere and are transparent to
the checker: `Io` and `{Net, Dom, Log, Clock}` are the same set.

Primitive operations are `foreign` values with effectful types, declared in the platform:

```elm
foreign httpSend : Request -> Response ! {Net}
foreign now : () -> Time ! {Clock}
```

### 3.3 Calls

```
Postfix     := App ('!' | '?')*
```

`!` is postfix on an application, at the same precedence as `?` and combining with it left to
right: `getUser id!?` is `(getUser id)!` then `?`. `f a! b` is `args_after_effect`, by the
existing `args_after_question` rule.

Rules:

- `e!` where `e : t ! s` and `s` is non-empty: the call is performed; the expression has type `t`;
  `s` joins the enclosing function's effect set.
- `e!` where `e` is pure: `bang_on_pure`.
- `e` unmarked where `e : t ! s` and `s` is non-empty, in value position: `unmarked_effect_call`,
  with the hint "add `!` to perform it, or wrap it in `\() ->` to pass it along".
- `!` inside a lambda is legal and makes the lambda effectful. This differs from `?`, which
  `language.md` §6.6 forbids in a lambda: `?` is a non-local return and a lambda is the wrong
  function to return from; `!` has no control-flow effect beyond suspending, so a lambda that
  performs is an ordinary effectful function. This is what makes `List.map xs (\x -> f x!)` work.
- `!` at top level, outside any function body, is `effect_at_top_level`. Top-level values are
  pure (Roc's rule, 14/roc §1).

### 3.4 What a `!` means when read

Two things, both visible at the call site: this call suspends this function until the platform
resumes it, and the function you are in is effectful. Feldman's concern that a bind marker makes
`let` order "silently significant" (14/elm §6) is answered by the marker being loud, and Evan's
substitution concern (14/elm §0.3) does not arise because an unmarked effectful call is not a
value that runs twice, it is a compile error. Swift makes `try` and `await` mandatory for the
same reason (landscape §1 family E); Koka and Flix have no marker and rely on inference alone.
**Sub-decision:** the marker is mandatory. A reviewer who prefers Koka's markerless style should
argue it against §3.4's two reasons.

---

## 4. Typing

### 4.1 Effect sets in the type language

A function type is `(t₁, …, tₙ) -> t ! s` where `s` is a set expression over effect constants and
effect variables: `{}`, `{Net}`, `e`, `{Net | e}`, and unions of these. Two set expressions are
equal when they denote the same set under every assignment of the variables. `{Net, Net}` is
`{Net}`; there are no duplicate labels and no ordering, which is the difference from Koka's
scoped rows (14/koka §1) and the reason `List.map`'s `e` does not leak a synthesised effect
into the caller's type (Effekt's critique of Koka, 14/effekt §2).

### 4.2 Inference

The checker infers effect sets alongside types, in the same pass:

1. Every function body starts with a fresh effect variable `e_f`.
2. A marked call `g args!` where `g : … -> t ! s` adds the constraint `s ⊆ e_f`.
3. A lambda `\x -> body` gets its own `e_λ`; its effects do not join the enclosing function's
   unless the lambda is called with `!` there.
4. At the end of the body, `e_f` is the smallest set satisfying its constraints. If the body has
   no marked calls, `e_f = {}`.
5. **Generalisation.** Top-level definitions generalise their effect variables along with their
   type variables. `let` bindings do not (Flix, 14/flix §7.3). A local helper that performs `Net`
   has effect `{Net}`, not `{Net | e}`.
6. **Annotations.** An annotated effect set must be a superset of the inferred set
   (**Sub-decision**, §9.2). `fetch : … ! {Net, Log}` over a body that only performs `Net` is
   accepted; over a body that performs `Dom` it is `effect_not_declared`, reported at the
   offending call, naming the effect (§8).

### 4.3 Unification

Unifying two function types unifies their parameters, results, and effect sets. Set unification
is over the algebra of finite sets with variables; Flix implements it as `SetUnification` after
moving from Boolean formulas (14/flix §0, §7.1), and it is decidable with most general unifiers.
The cases the checker meets:

- constant against constant: equal or `effect_mismatch`;
- variable against anything: bind;
- `{Net | e₁}` against `{Net, Log | e₂}`: `e₁ := {Log | e₃}`, `e₂ := e₃`;
- `{Net}` against `{Log}`: mismatch, reported as "this function performs `Net`, but here it must
  not" with both sets minimised.

**Sub-effecting at lambda arguments.** A lambda passed where `(a -> b ! {Net, Log})` is expected
may have effect `{Net}`; the checker widens it. Flix restricts widening to lambda arguments and
trait instances, never to top-level definitions (14/flix §7.3); this proposal does the same.

**Sub-decision, the algorithm's cost.** Flix's inference cost at scale was unmeasurable in the
report (papers unreachable, 14/flix §8). beni's checker has a §2 throughput target. The
proposal's position is that set unification restricted as above is cheap in the common case
(most functions have constant sets; variables appear only in higher-order library functions),
but this is the single item to prototype before committing (§11).

### 4.4 What the type system does not know

Nothing about the platform's implementation, nothing about promises, nothing about scheduling.
An effect name is an opaque label. This is the "effect as requirement" reading Effekt documents
(14/effekt §1): `{Net}` on a function means "the runtime must be able to perform `Net` when this
runs", and since the runtime declares `Net`, the requirement is met by construction. There is
no unhandled effect, which is where this differs from OCaml 5, whose unhandled `perform` is a
well-typed crash (14/ocaml5 §3).

---

## 5. Semantics

- **Strict, in source order.** An effectful function's `let` bindings run in the order written,
  which is how beni already lowers them (`Lower.zig`, research 15 §0.3). A marked call performs
  when reached. This is the semantics of every strict language with effects and the reason the
  marker is mandatory: it is the one place ordering becomes observable.
- **One-shot.** The runtime resumes a suspended call exactly once, or never. There is no
  `resume` visible to user code.
- **Purity is real.** A function with effect `{}` is a pure function of its arguments, and the
  compiler may evaluate top-level pure values at compile time (Roc does, 14/roc §4) and
  memoise, reorder or drop pure calls whose results are unused.
- **Thunks are the deferral primitive.** `() -> t ! s` is a value; calling it with `!` performs.
  This is what replaces `Task e a` as the thing handed to the runtime.
- **Local mutation and loops are out of scope.** Iteration is recursion and higher-order
  functions, as today; effect polymorphism is what makes that sufficient. Lean and Roc each
  added `for`/`mut` as a separate language decision (14/lean4 §3, 14/roc §2.1) and this proposal
  does not.

---

## 6. The platform as handler

`boundary.md` settled that a platform-provided effect is an ordinary `foreign` at effect type
and that ports stay asynchronous. Under this proposal:

- The platform **declares** the effects and **implements** the primitives. `foreign httpSend :
  Request -> Response ! {Net}` is implemented by JavaScript that returns a promise; the runtime
  suspends the calling fiber until it settles.
- The platform **exports the combinators**, all effect-polymorphic over thunks:

  ```elm
  Task.par2   : (() -> a ! e), (() -> b ! e) -> (a, b) ! e
  Task.parAll : List (() -> a ! e) -> List a ! e
  Task.retry  : Int, (() -> Result x a ! e) -> Result x a ! e
  Task.timeout : Int, (() -> a ! e) -> Maybe a ! {Clock | e}
  Task.scope  : (Scope -> a ! e) -> a ! e            -- structured cancellation
  ```

  Because the runtime receives both thunks of `par2` before running either, it can start both;
  because it owns the fiber, it can cancel one. This is the vocabulary research 16 says a `Task`
  runtime must have, kept, and it is why the proposal does not make Roc's trade (14/roc §0.2):
  effects are not data, but the runtime still sees them before they run, because a thunk is
  handed over unevaluated.
- **The Elm Architecture.** `init` and `update` are pure: `update : Msg, Model -> (Model, Cmd Msg)`
  with `! {}`. A command is a thunk plus a message constructor:

  ```elm
  Cmd.run : (() -> a ! e), (a -> msg) -> Cmd msg
  update msg model =
      case msg of
          Load id -> ( model, Cmd.run (\() -> fetchSummary id!) GotSummary )
  ```

  The runtime runs the thunk as a fiber and delivers `GotSummary summary` to `update`. Tests of
  `update` stay pure and inspect the returned `Cmd`; a test platform records performed effects
  instead of performing them. This is what Roc's users lost when `Task` was removed (14/roc §4)
  and what this design keeps by not letting `update` perform.
- **Every declared effect has an implementation**, checked at link time: an effect the platform
  declares but does not implement is `effect_unimplemented`. Combined with §4.4, no effect can
  reach the runtime unhandled.

---

## 7. Compilation

### 7.1 Which functions are lowered

A function whose inferred effect set is `{}` compiles as today. A function whose set is
non-empty, or contains a variable, is lowered to a **suspendable form**. The type system decides;
no separate analysis (contrast js_of_ocaml's `partial_cps_analysis.ml`, 14/ocaml5 §2.3).

### 7.2 The suspendable form

Two candidates from research 14, both proven on JavaScript:

- **L1, closures with join points.** Each marked call becomes "call the primitive; if it
  returned a value continue inline; if it returned a suspension, return a continuation closure
  for the rest". Lean's elaborator and Koka's monadic pass are this (14/lean4 §0.1, 14/koka
  §4.2). Join points are mandatory: a branch after a suspension must not duplicate the rest of
  the function into every arm, which is exponential (14/lean4 §6). Output is ordinary closures,
  transparent to §9's optimiser, with exact source locations.
- **L2, a state machine.** The function body becomes a `switch` on a state integer with locals
  hoisted to fields; regenerator and TypeScript's transform converged on one architecture and
  TypeScript's header comment is an executable spec (14/regenerator §0.1). Type-blind, backend
  only. Known trap: hoisted declarations must be unmapped or the debugger breaks (14/regenerator
  §0.3); TypeScript is deleting it for complexity (14/regenerator §3).

**Sub-decision:** L1. It keeps the output as functions and calls, which is what §9's DCE, code
splitting and renaming already handle, and it keeps locations exact without special discipline.
Native generators (L3, Effect-TS's route) are rejected: opaque to the optimiser, poor stack
traces, `finally` semantics wrong by default, and `yield` cannot cross a function boundary so
every effectful lambda would have to be a generator (14/javascript §0.2, 14/effect-ts §2.4).

### 7.3 Effect-polymorphic functions

`List.map` has effect `e`. When called with a pure callback it should compile to a plain loop;
with an effectful one it must be suspendable. Two options:

- **Always suspendable, with a fast path.** Koka compiles every effect-polymorphic function once
  in the suspendable form, with an `if (yielding())` test after each callback invocation
  (14/koka §4.2). Pure callers pay the test.
- **Double translation.** Two compiled bodies per effect-polymorphic function, direct and
  suspendable, selected at each call site by the instantiated effect. js_of_ocaml does this at
  runtime because it cannot know statically (14/ocaml5 §2.3); beni knows at every monomorphic
  call site from the instantiated `e`, and only a call from inside another polymorphic function
  needs the suspendable copy.

**Sub-decision:** double translation, selected statically. The cost is two bodies for every
polymorphic higher-order function in core, which is a bounded set, and a lambda-lifting
constraint js_of_ocaml documents (14/ocaml5 §2.3). The benefit is that pure code calling `List.map`
is exactly today's code.

### 7.4 The boundary

A `foreign` effectful primitive is implemented as a JavaScript function returning either a value
or a promise. The runtime distinguishes at the call: a value resumes inline, a promise registers
the continuation. This is the `Step` protocol Koka's runtime uses in miniature (14/koka §0.2),
without evidence vectors because there is exactly one handler. Report 16's scheduler is the
runtime this plugs into; the `ITERATOR` op Effect-TS added (14/effect-ts §3.3) is not needed
because there are no generators.

### 7.5 Source locations and stack traces

A deliverable, not a follow-up. Effect-TS paid for this twice after shipping (14/effect-ts §3.4);
Kotlin/JS emits an extra temporary so a breakpoint on a closing brace can be hit (14/kotlin §4).
Under L1 each continuation closure carries the source span of the call it resumes, and the
runtime keeps the chain of pending continuations, so a failure inside a suspended function can
report the logical call stack. Source maps: each continuation is emitted at the original call's
position.

---

## 8. Diagnostics

The evidence is that this is where effect systems fail users: Koka points effect mismatches at
whole blocks and asks the user to diff two rows (14/koka §4.3); Flix prints unminimised formulas
with synthesised names (14/flix §7.5); Gleam's "purely syntactic" `use` needed four bespoke
error paths (14/gleam §0.2). Every diagnostic below names the call and the effect, never a set
expression the user did not write.

| Code | When | Message shape |
|---|---|---|
| `unmarked_effect_call` | effectful function called without `!` in value position | "`getUser` performs `Net`, so calling it needs `!`. Add `!` to perform it here, or wrap it in `\() ->` to pass it along." |
| `bang_on_pure` | `!` on a pure call | "`add` is pure; `!` is only for calls that perform effects." |
| `effect_not_declared` | body performs an effect the annotation lacks | "This call performs `Dom`, but `render` is declared `! {Net}`. Add `Dom` to the declaration, or move the call." |
| `effect_in_pure` | effectful call in a function annotated or inferred pure | as above with "declared pure" |
| `effect_mismatch` | argument function's effects exceed the parameter's | "This function performs `Net`, but `List.map` here is used in a pure context (its callback may not perform anything)." Points at the callback and at the enclosing function's declaration. |
| `effect_at_top_level` | `!` outside a function body | "Top-level values are computed once and cannot perform effects." |
| `effects_on_non_function` | `! {…}` on a non-function type | |
| `effect_outside_platform` | `effect X` in a user package | |
| `effect_unimplemented` | platform declares an effect it does not implement | link time |
| `args_after_effect` | `f a! b` | mirrors `args_after_question` |

Rendering rule: a set is always shown minimised and with aliases folded (`Io` rather than its
four members) when the user's own annotation used the alias.

---

## 9. Sub-decisions, collected

1. **Closed vocabulary.** Effects are declared only by the platform. Roc had platform-declared
   effect tags on `Task` and removed them because a closed vocabulary cannot say "only this
   domain" or "only under this directory" (14/roc-zulip-effect-granularity §1). This proposal
   accepts that limit for v1: the sets are for reading and for the backend, not for sandboxing.
   Opening the vocabulary means user-declared effects with one-shot user handlers, OCaml 5's
   restriction, which the type side already accommodates (a handler discharges an effect from the
   set) and the backend does not yet. Deferred, not rejected. Capability values passed as
   arguments, Roc's current answer to sandboxing, remain available to any platform without
   language support.
2. **Annotation superset.** Declared sets may exceed inferred sets, so a library can reserve
   `{Net, Log}` while implementing only `Net`. Flix requires exactness (14/flix §7.3). The
   proposal prefers API stability over precision; a reviewer may prefer a warning.
3. **Mandatory `!`.** §3.4.
4. **L1 over L2.** §7.2.
5. **Double translation over always-suspendable.** §7.3.
6. **`!` as the type spelling.** §3.1.

---

## 10. What is lost, and what is deliberately not attempted

- **Multi-shot resumption.** Backtracking, nondeterminism, choice-point parsing. Effect-TS never
  shipped it (14/effect-ts §3.1). Not wanted.
- **User handlers.** Local mocking, middleware over platform effects, exceptions and generators
  as libraries (14/effekt §2). Deferred per §9.1.
- **`Task` as an inspectable value.** A thunk is opaque. Retry, batching and parallelism work
  because the runtime receives thunks before running them; inspection of *what* a thunk would do
  needs a recording platform. This is the trade Roc made and its users felt (14/roc §4); the
  difference here is that `update` stays pure, so the TEA testing story survives.
- **Point-free effectful pipelines.** Already lost with currying.
- **Statements, loops, mutation.** Out of scope; §5.

---

## 11. Costs and risks, with the evidence

| Risk | Evidence | Mitigation in this proposal |
|---|---|---|
| Signature noise: `! {Net, Log, Clock}` on many functions | PureScript removed effect rows as "enormous work for developers" and "anti-modular" (14/purescript §3) | aliases; annotations only at top level; inference inside bodies; superset rule so sets rarely change |
| Diagnostics print formulas | Flix (14/flix §7.5), Koka (14/koka §4.3) | §8: every error names a call and an effect; minimised sets; aliases folded; a fixture suite is a deliverable as `?`'s was |
| Inference cost unmeasured | Flix papers unreachable (14/flix §8); beni's §2 throughput target | prototype set unification in `Solve.zig` against the corpus before any surface syntax lands (§12 Q1) |
| No exact precedent for the assembly | every piece shipped somewhere: types in Flix, one-handler runtime in Elm and Effect-TS, lowering in Lean/Koka | accept; the reviewers' job is to find the seam |
| Double translation complexity | js_of_ocaml needed lambda lifting for it (14/ocaml5 §2.3) | bounded to core's higher-order functions; fall back to always-suspendable if it does not land |
| Stack traces and source maps | Effect-TS, Kotlin/JS, TypeScript all paid late (14/effect-ts §3.4, 14/kotlin §4, 14/regenerator §0.3) | §7.5 is a deliverable with fixtures |
| Effectful lambdas everywhere | every `\x -> f x!` is a suspendable function | it is also every callback in Effect-TS today; the cost is in codegen, not in the user's text |
| The wall | `foreign` effectful primitives return promises; user code never sees them | unchanged from `boundary.md`: only the platform writes `foreign` |

---

## 12. Questions for reviewers

1. **Inference.** Is set unification as restricted in §4.3 (constants, variables, unions; no
   complement, no intersection) principal, and does it stay linear on the shapes beni's checker
   meets? What breaks first: recursion between effect-polymorphic functions, or annotations
   with variables?
2. **Generalisation.** Does "generalise effects at top level only" interact badly with anything
   `checker.md` already does for rank-based generalisation of type variables?
3. **`!` inside lambdas.** §3.3 makes an effectful lambda ordinary. Is there a case where a
   suspended callback inside a *pure* higher-order function (one not compiled suspendable) can
   be reached? The type system should make it impossible; check the seam between §4.3's
   sub-effecting and §7.3's double translation.
4. **The marker.** Is mandatory `!` right, or should inference carry it as in Koka and Flix?
   Argue against §3.4.
5. **Closed vocabulary.** Is v1 without user-declared effects acceptable, given Roc's
   finding? What does a `{Payments}` effect that a library wants to expose look like without
   user handlers?
6. **TEA.** Does §6's `Cmd.run` shape preserve everything `update`'s purity buys today,
   including testing and time-travel debugging, and what does a subscription look like?
7. **Cancellation.** A fiber cancelled mid-suspension never resumes. What runs? Rust's async
   `Drop` is unresolved five years on (14/rust §2.5); Effect-TS's `finally` never runs on
   failure (14/effect-ts §2.4). This proposal has no `finally`; is `Task.scope` enough?
8. **Lowering.** L1 with join points versus L2: which is cheaper to get right in Zig, and which
   is cheaper for §9.5's code splitting?
9. **The rest-of-block bind.** With this proposal, `let x <- e` serves `Result`, `Maybe` and
   `Decoder` and not effects. Is having both `<-` and `!` in the language confusing, and should
   `Decoder` become an effect instead?
10. **What is missing.** What did the seventeen reports warn about that this proposal ignores?

---

## 13. Alternatives considered and not taken

- **Rest-of-block bind only for `Task`** (research 14 option B). Already adopted for other
  types; insufficient on its own for §1's items 1 to 4.
- **`!` with `Task` as a value, lowered by state machine** (research 14 options C/D, Rust's
  shape). Gives item 1 but not 2, 3 or 4; `List.map` still needs a twin or an inline rule.
- **Native generators** (research 14 option E, Effect-TS). Rejected in §7.2.
- **Purity inference without effects as values** (research 14 option F, Roc). Loses the runtime
  vocabulary (14/roc §0.2); this proposal keeps it via thunks and a runtime that owns the fiber.
- **Full algebraic effects with rows and user handlers** (research 14 option G, Koka). Row
  inference's let-generalisation hazard (14/koka §4.3), no source maps after nine years, a
  research-grade backend; and Koka's own Task-on-handlers library for JavaScript was abandoned
  (14/koka §0.3).
- **Class-directed `do`**. Needs higher-kinded types; every language that had it retreated to
  name resolution for `do` (14/haskell §0.1); and it does not solve the callback problem.

---

## 14. Evidence index

`research/14-direct-style/01-solution-space.md` is the synthesis; the per-subject reports cited
above are in the same directory: `elm`, `haskell-do-notation`, `purescript-do-and-magic-do`,
`lean4-do-elaborator`, `ocaml-let-operators`, `fsharp-computation-expressions`, `gleam-use`,
`koka-with-and-effects`, `roc-purity-inference`, `roc-zulip-effect-granularity`,
`rust-question-mark-and-async`, `csharp-async-state-machine`, `kotlin-suspend-and-arrow`,
`javascript-async-await-v8`, `regenerator-and-tsc-downlevel`, `effect-ts`, `effekt`,
`ocaml5-effects-and-jsoo`, `flix-effects`. `research/16-fibers-and-concurrency.md` is the
runtime this proposal's §6 assumes.
