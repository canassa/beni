# Koka: `with`, effect rows, and what a handler looks like once it reaches JavaScript

**Commissioned by** the direct-style research programme, as the Tier 1 report on the one system that
built *both* halves of the design space on *our* target. Koka has the cheap syntactic rewrite
(`with`, family D — the thing report [15](../15-flat-effect-syntax.md) §0.1 found four languages
invented independently) **and** row-typed algebraic effects (family H), and it compiled the second
to JavaScript, twice, with two different strategies. Report 15 and `fast-compiler.md` §3 both ruled
effect rows out on inference cost; the shared brief reopens that, and this report is asked to
describe what rows do *to the user* — what they write, what the signatures read like, what the
errors say — not what they cost the clock. No benchmarks, no timings, no performance claims.

**Sources.** The Koka repository read directly: `dev` at 2026-09-14 — the compiler (`src/Syntax/Parse.hs`,
`src/Type/Unify.hs`, `src/Core/{Monadic,MonadicLift,UnReturn,OpenResolve,AnalysisResume}.hs`,
`src/Compile/Optimize.hs`, `src/Backend/JavaScript/FromCore.hs`), the JavaScript handler runtime
(`lib/std/core/inline/hnd.js`, 317 lines), the standard library, the test suite, and the book's own
Markdown source (`doc/spec/tour.kk.md`, `why.kk.md`) rather than the rendered page, because the source
carries the translation tables verbatim. Two papers extracted from their author-hosted PDFs: Xie &
Leijen, *Generalized Evidence Passing for Effect Handlers* (ICFP 2021, `xnning.github.io/papers/multip.pdf`)
and Leijen, *Structured Asynchrony with Algebraic Effects* (MSR-TR-2017-21, May 2017). Xie & Leijen,
*Effect Handlers in Haskell, Evidently* (Haskell 2020) was read for the evidence-passing vocabulary.
**Leijen's POPL 2017 paper could not be read** — the MSR-hosted PDF uses a font encoding no available
tool decodes and `dl.acm.org` returns 403; §8 says what that cost. Commit history and issue threads via
the GitHub API (`gh`); two Hacker News threads. All web sources accessed **2026-09-14**. The JavaScript
quoted in §4.2 was emitted by Koka 3.2.3 for `--target=js` earlier in this session, before the
read-only rule took effect; it is quoted as *shape*, and no timing or benchmark from that work appears
anywhere in this report.

---
## 0. The three findings, up front

**1. Koka has two mechanisms, and `with` is not the one that answers the pyramid.** `with` is a
generalised trailing lambda — twenty-eight lines of parser (`src/Syntax/Parse.hs:1637-1665`), no
type-system involvement whatsoever. But Koka does not use it to sequence effects, because Koka has
nothing to sequence: an effectful call is an ordinary call, and the *type* carries what it may
perform. `with` exists to install handlers, to write `finally`/`initially` blocks, and to flatten
ordinary higher-order calls like `foreach`. The book's own examples of `with` for binding are
`with x <- list(1,10).foreach` and `with finally{ … }` — never a bind chain. **A language that has
effect rows does not need a bind syntax, and Koka's `with` is what is left over once you have them:
scope-shaped API calls, not effect sequencing.** For beni the two are alternatives with different
payoffs, not a cheap and an expensive version of one thing.

**2. Evidence passing reaches JavaScript in Koka v2/v3, and multi-shot resumption works there — the
landscape's "the JS backend does not use evidence translation" is true only of v1.** The repository
says it exactly: *"`v1-master`: last stable version of Koka v1: this is Koka with the Javascript (and
C#) backend **which does not use evidence translation**. This version supports `std/async` and should
compile examples from published papers."* (`readme.md`, "Branches"). The current backend does:
`lib/std/core/inline/hnd.js` is a JavaScript evidence-vector runtime — `_evv_get/_evv_at/_evv_swap`,
`_evv_insert`, `_yield_to`, `_yield_extend`, `_kcompose` — the "yield bubbling" and "short-cut
resumptions" of Xie & Leijen (ICFP 2021) §2.7–2.8, in 317 lines of ES modules. Because the resumption
is built as *a list of ordinary closures* rather than captured from the native stack, resuming twice is
just calling a function twice: *"in Koka (and Haskell) the resumption function is shared over multiple
resumes"* (§5). **JavaScript has no delimited continuations, and Koka gets multi-shot handlers on it
anyway, without generators and without a whole-program CPS transform** — by making every effectful
function return a `Pure`-or-`Yield` result and testing after every call.

**3. The `Task`-shaped thing beni actually wants — deferred, cancellable, runtime-interpreted async —
Koka built as a *library* on handlers, on JavaScript, and it did not survive the rewrite.** Leijen's
*Structured Asynchrony with Algebraic Effects* (MSR-TR-2017-21, 2017) is exactly the argument beni is
having: *"web servers written in JavaScript using Node.js are highly asynchronous and without language
support the resulting programs are difficult to write and debug due to excessive callbacks (i.e. the
so-called pyramid of doom)"*, answered by *"full support for asynchronous programming in the style of
async-await but as a library using just plain algebraic effect handlers without adding special
primitives to our language … in Koka … which compiles to JavaScript that can run fully asynchronous on
either Node.js or the browser"* (§1, §3). It gave block-scoped cancellation and timeout, and made
`val name = readline()` an ordinary line of code (`test/async/async1.kk`). Today `std/async` exists only
on `v1-master`; `lib/std/async/file.kk` is a module header whose entire body is the word `Todo.`;
`test/async/config.json` reads `"exclude": ["async.*.kk"]`; and *"Port `std/async` with `libuv`
integration"* is still an unticked box on `readme.md`'s todo list. **The most relevant artefact in the
whole subject is unmaintained**, and §5 says why: nobody is writing async Koka.

---
## 1. The effect model

Effects in Koka are **not values**. They are a *row* in the function type, and performing one is an
ordinary call. A function type has three parts — arguments, effect, result:

```koka
fun sqr    : (int) -> total int       // total: mathematical total function
fun divide : (int,int) -> exn int     // exn: may raise an exception (partial)
fun turing : (tape) -> div int        // div: may not terminate (diverge)
fun print  : (string) -> console ()   // console: may write to the console
```
— `doc/spec/why.kk.md`, "Effect Typing"

A row is written `<div,exn>` (with `alias pure = <div,exn>`), extended as `<l|e>`, and empty as `<>`
or `total`. `:io` is the top. **Sequencing two effects means writing two statements**; the rows are
unioned by unification at the call site — in `while { is-odd(srandom-int()) } { throw("odd") }` the
predicate has `<ndet|e1>` and the body `<exn|e2>`, and *"when applying `while`, those effects are
unified to the type `<exn,ndet,div|e3>`"* (`tour.kk.md` §Polymorphic effects). Rows are **scoped
labels** (Leijen 2005): duplicates are legal and meaningful — *"Koka allows duplicate effect labels
where `action` has an instantiated `<raise,raise>` effect type … there is a natural correspondence to
the structure of the evidence vectors at runtime"* (`tour.kk.md` §Abstracting Handlers).

The language distinguishes effectful from pure code in types, completely and by inference. The user
need not write it: `fun square5(x : int) : int = x*x` is total by inference, and `_e` is a wildcard
meaning "some inferred effect". Effects are *discharged* by handlers — given
`effect fun emit(msg : string) : ()` and `fun hello() : emit () = emit("hello world!")`, the handler
`with fun emit(msg) println(msg)` around `hello()` removes `emit` and adds `console`. Operations come
in four strengths: `val` (a dynamically bound constant), `fun` (tail-resumptive by construction), `ctl`
(first-class `resume`, may resume zero, one or many times), and `raw ctl` (an `rcontext` you may store
and resume or finalize later, *"from a different scope"*). The tour frames the whole thing as dynamic
binding with a type: *"we can view the handler `with fun emit` as a (statically typed) dynamic binding
of the function `emit` over the rest of the scope."*

**Effects as values (cross-cutting Q10): not by default, but reachable.** There is no `Task` node to
inspect, retry or schedule; deferral is a thunk, `() -> e a`. What Koka gives instead is the
ingredient — a first-class `resume` — out of which the 2017 async library built promises, cancellation
scopes and `timeout`. Leijen argues the difference is a feature: *"with algebraic effects we just have
certain functions with an `async` effect and there is no intermediate promise object … A common problem
with promises is 'losing' exceptions or forgetting to await a promise"*, then concedes in the same
paragraph that *"not all data flow in a program is lexically scoped"* and reintroduces a first-class
`promise` type for that (MSR-TR-2017-21 §3.5).

---
## 2. The mechanism

### 2.1 `with` — the syntactic half

The book states the rewrite as a table — *"The `with` statement essentially puts all statements that
follow it into an anonymous function block and passes that as the last parameter"*, so
`with f(e1,...,eN)` ⟼ `f(e1,...,eN, fn(){ <body> })` and `with x <- f(e1,...,eN)` ⟼
`f(e1,...,eN, fn(x){ <body> })` (`doc/spec/tour.kk.md` §sec-with) — and adds the framing report 15
already quoted: *"it helps thinking of `with` as a closure over the rest of the lexical scope."*

**The implementation is the rewrite and nothing else.** `withstat` (`src/Syntax/Parse.hs:1637-1653`)
parses `with`, optionally a `parameter` followed by `=` or `<-`, then a `basicexpr` or a handler
expression; `applyToContinuation` (`:1655-1665`) builds the lambda and appends it as the last argument:

```haskell
applyToContinuation wrng params expr body
  = let lam = Lam params body False (combineRanged wrng body)
        fun = Parens lam (newName "with") "expr" wrng
    in case unParens expr of
        App f args range -> App f (args ++ [(Nothing,fun)]) fullrange
        atom             -> App atom [(Nothing,fun)] fullrange
```

Twenty-eight lines, inside a 3,211-line parser. **What the type system must know: nothing** — the callee
must simply take a function of the right arity as its last argument, the same arity contract Gleam chose
(report 15 §3.2). There is exactly one type-inference interaction, and it is a comment in the source:
the lambda is wrapped in `Parens … (newName "with")` because *"Parens makes it last in type inference so
types can better propagate"*. The rewrite is free; the *ordering* of inference around it is tuned
deliberately, and a naive implementation would get that wrong.

**Where it may appear (Q5):** statement position inside a block, taking the rest of the block; or
`with … in expr` as an expression (`withexpr`, `:1700`). Not in arbitrary expression position. This is
exactly report 15's cheap half of the cost axis.

### 2.2 Effects — the half that has no syntax

For effects there is no bind construct at all, so the hard cases are not hard. Here is the brief's
`fetchSummary`, written faithfully in Koka (this compiles and runs on Koka 3.2.3):

```koka
effect fetch
  ctl get-user() : user
  ctl get-permissions( u : user ) : perms
  ctl get-audit-log( u : user ) : string

pub fun fetch-summary() : fetch summary
  val u = get-user()
  val p = get-permissions(u)
  if p.is-admin then
    val log = get-audit-log(u)
    Summary(u, p, Just(log))
  else
    Summary(u, p, Nothing)
```

Note what is absent: no `andThen`, no `use`, no `with`, no `yield*`, no `!`. The bind inside the `if`
arm costs no nesting and no new block. The effect row `fetch` is written once, in the signature, and
could be elided as `_e`.

And the loop, which block-structured rewrites cannot express at all:

```koka
pub fun fetch-many( names : list<string> ) : <fetch,div> list<summary>
  var acc := []
  foreach(names) fn(_n)
    val s = fetch-summary()
    acc := Cons(s,acc)
  acc.reverse
```

Three suspension points inside a loop body that also mutates a local. `var` is not a hazard here: the
tour is explicit that *"`var` state is correctly saved and restored on resumptions (as part of the
stack) and this is essential to the correct composition of effect handlers. If `var` declarations were
instead heap allocated or captured by reference, they would no longer be local to their scope and side
effects could 'leak' across different resumptions."*

### 2.3 The hard cases, answered

| Case | Koka | Evidence |
|---|---|---|
| **Bind in a branch (Q2)** | free; the bound value is usable after the branch | `fetch-summary` above |
| **Bind in a loop (Q1)** | free; `foreach`, `while`, recursion, all fine | `fetch-many` above |
| **Early return (Q3)** | `return e` — but it is scoped to the **nearest enclosing function or lambda**, which inside a `with` continuation is the continuation, not the outer function | `tour.kk.md` `encode2`: `s.map( fn(c) … return c … )` returns from `fn(c)` |
| **Early exit with cleanup (Q3)** | `with finally{ … }` runs *"either normally, or through an 'exception' (i.e. when an effect operation does not resume)"* | `tour.kk.md` §sec-with-finally |
| **Pattern match on the bound value** | **not supported in `with`**; `with (idx, foo) <- xs.map-indexed` produces `internal error: Syntax.Parse.parameter: unexpected function expression in parameter match transform` | [koka#721](https://github.com/koka-lang/koka/issues/721), HeikoRibberink, 2025-06-02, **open** |
| **Mixing two effect types** | not a thing; `<exn,fetch,console\|e>` is one row, unified at the call site | `tour.kk.md` §Combining effects |
| **Error propagation** | `exn` is an effect like any other; `raise-maybe` turns it into `maybe<a>` with a `return` clause | `tour.kk.md` §sec-return |

The `with` asymmetry in row five is worth dwelling on, because it is the kind of thing that only shows
up after five years of use. `val` bindings **do** take full patterns — `localValueDecl`
(`src/Syntax/Parse.hs:1594-1613`) falls back to `Case e [Branch pat …]` for anything that is not a
plain variable. `with x <- e` calls `parameter` instead, because the binder becomes a lambda parameter.
The reporter's argument is the right one: *"the construct is equivalent to `expr fn(x)`, where function
parameters already support any pattern."* **A rest-of-block rewrite that binds through a lambda
inherits the lambda's binder grammar, and if that grammar is narrower than `let`'s, users will notice.**

### 2.4 What the type system must know for the effects half

Row unification, and that is the whole of it. `src/Type/Unify.hs:373-465` — `unifyEffect`,
`unifyEffectVar`, `unifyLabels` — is roughly 92 lines of a 545-line unifier. Labels are kept in a
canonical order by name (`labelNameCompare`), duplicates are permitted (scoped labels), and an open
row's tail is a type variable that gets extended with the labels the other side has. There is a kind
for effects (`kindEffect`), and `src/Kind/Kind.hs:108` records a second kind for *linear* effects —
`"(used defined) linear effects: (E,V) -> V"` — which is how the compiler knows an effect can never
capture a resumption.

---
## 3. History and decisions

**The rest-of-block rewrite came before `with`, under two other keywords.** `applyToContinuation`
already existed when `with` was added; it served `use x = e` and `using e`, whose parsers survive
commented out in `src/Syntax/Parse.hs:1616-1633` complete with their deprecation calls
(`warnDeprecated "use" "with"`, `warnDeprecated "using" "with"`). **Koka shipped Gleam's spelling —
`use` — years before Gleam, then replaced it.**

**`with` was added on 2018-08-01, by Jonathan Brachthäuser, in six lines.** Commit `bc261a33`,
"Add with statement syntax": `+6 -1` in `Parse.hs`, and initially only for handler expressions
(`localWithDecl = do krng <- keyword "with"; handler <- handlerExprX …`); the binder form and the merge
with `use`/`using` came later. Worth saying plainly: **the author of Koka's `with` statement went on to
design Effekt, and chose capability passing over effect rows when he did** (see the `effekt` report).

**`<-` arrived on 2021-09-06**, Daan Leijen, commit `2211824e`, "allow `<-` for with bindings": one line
in the lexer, one in the parser, 47 lines of a benchmark reformatted. Before that the spelling was
`with x = f(…)`; both are still accepted (`keyword "=" <|> keyword "<-"`). Gleam's design discussion
([gleam#1709](https://github.com/gleam-lang/gleam/issues/1709)) chose `<-` on consistency-of-binders
grounds in 2022; Koka had made the same move nine months earlier, for reasons the commit does not record.

**Koka claims the priority and frames it as a design principle.** *"To the best of our knowledge, Koka
was the first language to have generalized trailing lambdas … Another novel syntactical feature is the
`with` statement"* (`tour.kk.md` §sec-with). The principle is *min-gen*: *"many languages have special
built-in support for this kind of pattern, like a `defer` statement, but in Koka it is all just function
applications with minimal syntactic sugar."* `while` is a function taking two thunks; `finally` is a
function; a handler is a function. **`with` is cheap precisely because everything it is applied to is
already a call** — a language whose control flow is *not* already function-shaped would pay more.

**The compilation strategy was replaced wholesale at v2.0.0 (2020-08-21).** v1 compiled row-typed
effects by the type-directed selective CPS/monadic translation of Leijen's POPL 2017 paper, to
JavaScript and C#. v2 replaced it with evidence passing (Xie et al., ICFP 2020; Xie & Leijen, ICFP 2021)
and a C backend, and rebuilt the JavaScript backend on the same evidence machinery — ES6 modules and
`BigInt` from v2.3.0 (2021-09-20). The v1 line is preserved *because* it is the one that runs the
published async examples.

**Removed, deprecated, or still marked Todo (Q9):** `use`/`using` superseded by `with`
(`Parse.hs:1616-1633`); `control` shortened to `ctl` in v2.3.1 (2021-09-29) and `brk` renamed `final ctl`
in v2.4.0 (2022-02-07) (`whatsnew.md`); `std/async` v1-only and not ported
([koka#341](https://github.com/koka-lang/koka/issues/341), `lib/std/async/file.kk` whose body is the
word `Todo.`); linear effects and named/scoped handlers both documented under `~ Todo` blocks
(`tour.kk.md` §sec-linear, §sec-namedh); source maps requested 2017-06-21 and still open with no
comments ([koka#30](https://github.com/koka-lang/koka/issues/30)).

---
## 4. Costs — ergonomic and structural

### 4.1 The compiler pipeline

`with` costs 28 lines of parser. **Effects cost a pipeline.** `src/Compile/Optimize.hs:110-135` runs, in
order: the monadic transform, `openResolve`, a simplify, monadic lifting, an inlining pass for the
primitive `yield-bind` definitions, an *unsafe* simplify to remove remaining `.open` calls that *"may
change effect types"*, and a final simplify. The passes are `Core/UnReturn.hs` (380 lines),
`Core/Monadic.hs` (431, *"Transform user-defined effects into monadic bindings"*),
`Core/MonadicLift.hs` (344, join-point sharing; names the lifted continuations `mlift` at `:263`),
`Core/OpenResolve.hs` (250, coercions between effect rows, *"must be after monTransform"*) and
`Core/AnalysisResume.hs` (143, which operations are tail-resumptive); behind them sit
`Backend/JavaScript/FromCore.hs` (1,367) and the handler runtime, `lib/std/core/hnd.kk` (938) plus
`inline/hnd.js` (317). **Twenty-eight lines against roughly 1,550 lines of Core passes, a 317-line
JavaScript runtime and a 938-line library.**

`UnReturn` deserves separate attention: it exists because *"transformations like 'Monadic' … introduce
new lambda abstractions over pieces of code; if those would still contain return statements, these
would now return from the inner function instead of the outer one."* That is exactly the hazard
`fast-compiler.md` §3.2 rule 1 worries about for `?` inside a lambda — and Koka paid a dedicated
380-line pass to normalise `return` away *before* any pass may introduce a lambda.

### 4.2 What the emitted JavaScript looks like

The monadic translation compiles every effectful call into "call it, then ask whether the world
yielded". Xie & Leijen describe the shape and its danger: *"since every bind operation takes a lambda as
its second argument this may lead to many closure allocations even for non-yielding code. Moreover, any
direct tail-recursive calls are no longer directly tail-recursive as they occur under a lambda now!"*
and, on inlining the binds, *"if we have a sequence of N statements, we may end up with 2^N
duplications"* (ICFP 2021 §2.10). The fix is join-point sharing, and you can see both halves in the
emitted module for `fetch-summary` above:

```js
export function fetch_summary() /* () -> fetch summary */  {
  var ev_10215 = $std_core_hnd._evv_at(0);
  var x_10212 = ev_10215.hnd._ctl_get_user(ev_10215.marker, ev_10215);
  if ($std_core_hnd._yielding()) {
    return $std_core_hnd.yield_extend(_mlift_fetch_summary_10175);
  }
  else {
    var ev_0_10220 = $std_core_hnd._evv_at(0);
    var x_0_10217 = ev_0_10220.hnd._ctl_get_permissions(ev_0_10220.marker, ev_0_10220, x_10212);
    if ($std_core_hnd._yielding()) { … }
    else { … }
  }
}
```

Every `val` in the source becomes a call, a `_yielding()` test and two branches; the `Pure` branch is
inlined straight-line (so the fast path reads like ordinary code) and the `Yield` branch hands a
top-level `_mlift_*` join point to `yield_extend`, which pushes it onto the resumption being built. The
loop compiles to `{ tailcall: while(1) { … continue tailcall; } }` with the same test at each suspension
point, returning on a yield a continuation closed over the remaining list. Handler installation compiles
to `_Hnd_fetch(3, clause, clause, clause)`, `3` being the control-flow-context tag; a `ctl` clause
compiles to `yield_to(m, function(k){ protect(x, …, k) })`.

**Three ergonomic consequences follow, none of them a performance claim.**

*Optimiser transparency (Q7).* The construct is not opaque — it is plain functions, closures and `if`s,
which is the point of the paper (*"a monadic translation into plain lambda calculus which can be
compiled efficiently to many target platforms"*), so a JS minifier can rename and
dead-code-eliminate it. What it cannot see is the *invariant* that `_yielding()` is false on the common
path, and Leijen's own unticked todo items name the resulting bloat: *"in effectful code we generate
many join-points (see [9]), can we increase the sharing/reduce the extra code"* and *"Can we use C++
exceptions to implement 'zero-cost' `if yielding() …` branches and remove the need for join points"*
(`readme.md`, "Tasks").

*Stack traces and the debugger.* A break inside `fetch-summary` shows `fetch_summary`; a break after a
suspension shows `_mlift_fetch_summary_10174`, a synthesised top-level function the user never wrote,
with parameters `(p, u, log)` reconstructed from the live set, and identifiers carrying unique integers
(`ev_10215`, `x_0_10217`). **And there are no source maps**:
[koka#30](https://github.com/koka-lang/koka/issues/30) has been open since 2017-06-21 with no comments.

*Backend maturity.* [koka#925](https://github.com/koka-lang/koka/issues/925) (2026-08-13, open) reports
the JS backend miscompiling a tail-recursive match into `undefined` values, worked around by reordering
a parameter. JS is the second-class target: daanx, 2020-11-11 — *"Currently I am mostly focused on the C
backend for best performance but keeping the JavaScript backend up-to-date."*
([koka#95](https://github.com/koka-lang/koka/issues/95))

One sentence on the performance fact that shaped the *user-visible* design, since §4's rule allows it:
general `ctl` operations must yield and rebuild a resumption, so Koka added `fun` and `val` operations
that are tail-resumptive by construction, plus `linear effect`, which *"removes the need for the monadic
transformation"* (`tour.kk.md` §sec-opfun, §sec-linear). **That performance fact leaks into the surface
language as three keywords the user must choose between** — the ergonomic cost beni would inherit.

### 4.3 Diagnostics

Effect-row errors are the weak spot, and the reports are specific.

*An effect mismatch points at a block, not a call.* [koka#402](https://github.com/koka-lang/koka/issues/402)
(chtenb, 2023-12-26, open). Adding a `println` to a body changes the inferred row and the compiler says:

```
repro.kk(3, 3): error: effects do not match
  context : val str = f().show
            println(str)
  term    : val str = f().show
            println(str)
  inferred effect: <exn,console|_e>
  expected effect: exn
```

The `context` and the `term` are the same two lines, and the offending call (`println`) is not singled
out. A user reading this has to diff two rows by eye to find `console`.

*`val`-binding a function loses its effect polymorphism.* [koka#401](https://github.com/koka-lang/koka/issues/401)
(chtenb, 2023-12-26, open; labelled `error-messages, polymorphism, types` by the maintainers).
`take-div(get); take-total(get)` type-checks; binding `val f = get` first and calling `take-div(f);
take-total(f)` does not:

```
repro.kk(4,14): error: effects do not match
  context : take-total(f)
  term    : f
  inferred effect: <div|_e>
  expected effect: (<>)
```

**This is the single most important diagnostic finding for a Hindley–Milner language.** It is
let-generalisation failing to generalise over the *effect* variable at a `val` binding, so "pull this
out into a local" — the most ordinary refactor there is — can break a program that type-checked. Any
beni design with rows must decide this deliberately.

*Handler mistakes report on library internals.* [koka#385](https://github.com/koka-lang/koka/issues/385)
(closed): *"Unclear error message `error: identifier .Hnd-div cannot be found`"* — a compiler-internal
handler-record name surfacing in a user error. [koka#126](https://github.com/koka-lang/koka/issues/126)
(closed, 2020-12-27): *"Error message for wrong return type of effect handler isn't helpful."*
[koka#888](https://github.com/koka-lang/koka/issues/888) (2026-05-01, open): a recursive default
argument causes *"effect inference failure (`effects do not match`)"*.

The good news is that the *handler-coverage* error is precise: writing `with ctl get-audit-log(u) …` for
an effect with three operations reports `type error: operator get-audit-log is not handled`, naming the
operation and pointing at the line.

### 4.4 Tooling

**There is no formatter.** [koka#521](https://github.com/koka-lang/koka/issues/521), opened by core
contributor TimWhiting on 2024-05-17, is still open, and the reason it is hard is `with` itself: *"I
don't think we should get rid of any `with` statements that the user introduces"* — a formatter cannot
normalise between `with f` and `f(fn(){…})` because the choice is the programmer's. **Any rest-of-block
rewrite creates two spellings of one program that the formatter must not unify.**

**What newcomers get wrong** is consistent in shape and it is never `with`: #401, #402, #732 (`val`
binding causes unexpected type escape in the presence of `local`), #785 and #788 (named effects
escaping) and #847 (`some` inference) are all effect-inference surprises filed by people trying ordinary
things. Separately, [koka#728](https://github.com/koka-lang/koka/issues/728) (2025-06-15) reports
*"Using `!` for both `not` and dereferencing a ref is confusing"* — `!` is already spoken for in Koka,
unlike in Roc.

---
## 5. What users say

**Almost nobody says anything, and that is itself an answer beni should note.** Koka's own front page
reads *"Koka v3 is a research language that is currently under development and not quite ready for
production use"* (`readme.md`), and the community behaves accordingly.

*The large thread.* [HN 38810073](https://news.ycombinator.com/item?id=38810073) (December 2023, 92
comments): **two** comments mention `with`, **zero** mention the JavaScript backend, **zero** mention
error messages. In favour, ctenb: *"With `with` you explicitly set the effect handler, no magic
involved."* The one syntax complaint is about operation declarations, not `with` — bruce343434: *"the
`fun yield( x : a ) : ()` syntax is highly unintuitive"*. The comments that bear on adoption are about
status: hamandcheese, *"It is self-proclaimed as a 'research Language' on the homepage, which has kept
me away so far."*; helix278, *"I wouldn't use it in production yet"*.
[HN 27710267](https://news.ycombinator.com/item?id=27710267) (June 2021, 12 comments) says nothing at
all on sequencing, `with`, rows, errors or the JS backend; it is entirely about Perceus.

*Praise* for `with` is structural rather than experiential — report 15 records Louis Pilfold's reaction
on discovering the convergence, and Koka's book makes its own case: *"Using the `with` statement this
way may look a bit strange at first but is very convenient in practice."*

*Wishes* cluster on the target, not the syntax. Lucifier129, who wrote a canvas demo in Koka v1 and hit
the old AMD-module output, filed a wishlist on 2020-11-03
([koka#95](https://github.com/koka-lang/koka/issues/95)) — ES modules, `.d.ts`, an npm package, JSX — of
which only ES modules shipped; [koka#768](https://github.com/koka-lang/koka/issues/768) (2025-07-29)
asks again for TypeScript types on the JS target.

**Nobody in the sources read is maintaining a large Koka codebase in anger**, so there is no counterpart
to the Elm-at-scale evidence the `elm` report is after. Treat every Koka ergonomics claim here as coming
from designers and evaluators, not from operators.

---
## 6. What it would take to do this in beni

**The `with` half is nearly free and beni could have it now** — a rest-of-block rewrite in the parser,
an arity contract checked by ordinary unification, no constraint kind, no class. Report 15 §8 already
lands there; Koka's twenty-eight lines are independent confirmation. Koka adds three warnings beyond
report 15. (a) Wire the with-lambda into inference *last*, deliberately, or types will not propagate
into the continuation — `Parens … newName "with"` exists for that. (b) Decide the binder grammar up
front: `with x <- e` inheriting lambda-parameter syntax rather than `let`-pattern syntax is
[koka#721](https://github.com/koka-lang/koka/issues/721), open for over a year, and beni's `let`
already binds patterns. (c) Budget for the formatter, not the desugarer
([koka#521](https://github.com/koka-lang/koka/issues/521)) — report 15 §0.2's Roc finding, confirmed in
a second compiler.

**The effect-row half is a different project, and this is what it buys.** Every hard case in §2.3 is
solved at once and by construction: a bind in a branch, a bind in a loop, a bind under a local mutation,
multi-shot resumption, and cancellation-by-not-resuming. No `use`-style mechanism gets the loop; no
generator gets multi-shot. The syntax cost is zero because there is no syntax.

**What the type system must grow.** A kind for effects; a row type former with an open tail; scoped
labels with duplicates permitted and a canonical ordering; row unification (≈90 lines in Koka's
unifier, `Type/Unify.hs:373-465`). Real but bounded, and *smaller* than the class-and-dictionary
machinery `fast-compiler.md` §3.1 rules out for `do`. **What is not bounded is the interaction with
let-generalisation**: koka#401 shows a `val`-bound function silently losing its effect polymorphism, so
"extract a local" becomes a type error. beni's `let` is its only sequencing construct, so beni would
meet that case constantly. This, not the unifier, is the thing to prototype first.

**What the pipeline must grow.** `UnReturn` before anything introduces a lambda; the monadic transform;
join-point lifting (or accept the 2^N expansion the paper warns of); an `open`-coercion resolver; a
tail-resumptive analysis; and a runtime module — 380 + 431 + 344 + 250 + 143 lines of Core passes and
317 lines of JavaScript, in Koka's case. There is no way to have handlers on JavaScript without most of
it: the alternatives are full CPS (what the POPL 2017 backend did and v2 replaced), generators (one-shot
only, so no multi-shot handlers), or a stack-reifying whole-program transform (Stopify). **Koka's
shape — a `Pure`/`Yield` return and an `if (yielding())` after every effectful call — is the cheapest
published route to multi-shot handlers on a host with no continuations, and it is proven to run.**

**What it would not solve.** Pattern binding through `with`. Source maps — Koka has none after nine
years, and beni's §9.5 code-splitting and renaming would have to keep the join points straight. Naming:
users read `_mlift_*` frames in a debugger unless beni maps them back. And rows do not by themselves
give effects-as-values: retry, cancellation, deferral and scheduling must be *built*, as the 2017 async
library built them — a second design project, and one Koka started, published, and let lapse.

**What the builders would warn us about.** Leijen's own unticked todo items: too many join points, too
much extra code in effectful functions, and no zero-cost way to elide the yield checks (`readme.md`,
"Tasks"); Xie & Leijen's warning that inlining binds naively is exponential (§2.10). The strongest
warning is a career move rather than a sentence: Jonathan Brachthäuser, who wrote Koka's `with`
statement in 2018, went on to build Effekt on *capability passing* — lexically scoped handler values —
explicitly to avoid row inference. Read the `effekt` report against this one.

---
## 7. Ranked summary

1. Row-typed effects remove the bind-syntax question entirely: branch, loop, early return, local
   mutation and multi-shot all work with no construct at all. (documented; verified in Koka source and
   the book's own examples)
2. Multi-shot resumption works on JavaScript, without generators and without whole-program CPS, because
   the resumption is a reified list of closures. (documented — Xie & Leijen ICFP 2021 §2.7–2.8;
   implemented at `lib/std/core/inline/hnd.js:250-303`)
3. Koka v1's JS backend did *not* use evidence translation; v2/v3's does — the landscape's open question
   is settled by `readme.md`'s own "Branches" note plus the current `hnd.js`. (documented)
4. `with` is twenty-eight lines of parser and needs nothing from the type system, but Koka does not use
   it to sequence effects — it uses it to install handlers and scope resources. (documented;
   `src/Syntax/Parse.hs:1637-1665`)
5. The worst ergonomic hazard of rows in an HM language is let-generalisation: `val f = get` loses
   effect polymorphism and breaks a program that type-checked without the binding. (documented —
   koka#401, open since 2023-12-26)
6. The handler pipeline is ~1,550 lines of Core passes plus a 317-line JS runtime, and one of those
   passes (`UnReturn`, 380 lines) exists purely because the transform introduces lambdas around code
   containing `return`. (documented; file line counts)
7. The Task-shaped async library Koka built on handlers for JavaScript in 2017 is v1-only, its tests are
   excluded, and its replacement is an unticked todo. (documented)
8. Effect-mismatch diagnostics point at whole blocks and ask the user to diff two rows by eye; handler
   errors sometimes surface compiler-internal names. (documented — koka#402, #385, #126)
9. No source maps (open since 2017), no formatter (open since 2024, blocked partly *by* `with`), and an
   open JS miscompilation bug. (documented — koka#30, #521, #925)
10. Practitioner evidence on Koka's sequencing ergonomics is essentially absent: 2 of 92 comments in the
    largest public thread mention `with`, none mention the JS backend. (measured — comment counts)

---
## 8. What could not be resolved

- **Leijen's POPL 2017 paper.** The MSR-hosted `algeff.pdf` uses a font encoding no available tool
  decodes and `dl.acm.org` returns 403 to non-browser clients, so the *original* JavaScript compilation
  story — the selective/type-directed CPS translation and Leijen's own account of what made it
  "selective" — is here only second-hand, from the v2 paper and the `v1-master` note. The extended
  technical report MSR-TR-2016-29 was not tried and should be.
- **Why `std/async` was not ported.** The repository records *that* it was not (todo list, the `Todo.`
  stub, the excluded tests, koka#341); no issue, commit message or post says *why*, and no Koka design
  forum surfaced in search. libuv, the rewrite, or lack of demand — unsourced.
- **Whether the current JS backend was ever exercised on async I/O at all.** `std/os/task` is C-only
  (`kk_task_schedule`) and self-described as *"very experimental and may not work as intended :-)"*.
  No source found either way.
- **Any narrated experience of debugging Koka-generated JavaScript.** No blog post, issue or thread
  describes stepping through it; §4.2's claims about `_mlift_*` frames are read off the emitted module,
  not off a user's account.
- **A designer statement on `return` inside a `with` continuation.** The lambda-scoping is clear from
  `Core/UnReturn.hs` and the `encode2` example, but nothing discusses the hazard the way Roc's community
  discussed backpassing's early returns. Searched the tracker for "return" plus "with"; nothing.
- **Whether `with` was ever considered for effect *sequencing*.** Commit `bc261a33` adds it for handlers
  and the binder form appears later without a rationale. Koka has no proposal process, so the commit log
  is the only record; no RFC, design note or mailing-list thread was found.
