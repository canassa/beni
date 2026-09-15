# Effekt: capabilities instead of rows, and what that buys a JavaScript backend

**Commissioned by** the shared brief's Family H — "algebraic effects with rows or capabilities" —
and specifically by the claim that Effekt gets effect *safety* without effect *rows* or row
polymorphism: Brachthäuser, Schuster and Ostermann, **"Effects as Capabilities: Effect Handlers and
Lightweight Effect Polymorphism"** (OOPSLA 2020), plus the JFP-era Scala library papers and the
2022/2023/2025 follow-ups that changed how the idea compiles. beni has no effect rows and no row
polymorphism (report 15, `fast-compiler.md` §3.1) and targets JavaScript, which has no delimited
continuations natively. Effekt is the one Tier-1 subject in this programme that answers "how do you
get effect safety anyway" with a different type-system mechanism than rows, and that has shipped a
JavaScript backend under three different compilation strategies while doing it. Unlike every other
report in this series, Effekt's answer to "how do you avoid the `andThen` pyramid" is not a syntax —
it is "you never had the pyramid": effects are not values, so there is nothing to sequence with a
combinator at all. §1 explains why, and §6 is about whether beni could get the same thing.

**Sources.** Read directly: the OOPSLA 2020 paper and its extended technical report (through a
markdown-extraction proxy, since WebFetch could not parse the PDF's compressed streams directly),
quoted below by section number where the extraction preserved one; the OOPSLA 2022 "Effects,
Capabilities, and Boxes" and OOPSLA 2023 "From Capabilities to Regions" papers the same way; the
`effekt-lang.org` documentation site and its `tour/*.effekt.md` pages, fetched as raw markdown via
the GitHub API from `effekt-lang/effekt-website` and its `effekt-lang/effekt` submodule (the tour
pages are symlinks into the compiler repo's `examples/tour/`); the compiler source at
`effekt-lang/effekt`, specifically `effekt/shared/src/main/scala/effekt/generator/js/{Transformer,
TransformerCps}.scala`, `effekt/shared/src/main/scala/effekt/cps/Transformer.scala`, and
`libraries/js/effekt_runtime.js` (260 lines, read in full); the compiler's own golden-test corpus at
`examples/neg/*.check` for exact diagnostic text; twelve GitHub issues, including one (#1176) with a
maintainer admission of a live soundness gap; one Hacker News thread (2021, 18 comments). **The
session's WebSearch budget was exhausted before this report started** (shared across the programme's
agents), so all web discovery here is direct URL fetches, the GitHub REST API (`gh api`), and the
Hacker News Algolia API — no search-engine sweep was possible; this likely under-samples blog posts
and forum threads a search would surface. Access date for all web sources: **2026-09-14**.

---

## 0. The three findings, up front

**1. Effekt does not have the `andThen`-pyramid problem, because effects are not values — the
mechanism this whole programme studies does not exist here.** Effekt's effect system attaches a
*requirement* to a function's return type (`Double / { exc }`), not a monadic wrapper around its
result. Calling `do exc("msg")` is an ordinary expression that returns whatever type the surrounding
code expects; there is no `Task`, no `.then`, nothing to bind. The tour states this as the whole
point of the design: *"an effectful expression depends on or modifies its context"*
([`tour/effect-handlers.effekt.md`](https://github.com/effekt-lang/effekt/blob/main/examples/tour/effect-handlers.effekt.md)),
and sequencing two effects is just writing two statements. The brief's `fetchSummary` example (§2.1)
comes out completely flat in Effekt with no construct added for the purpose — not because Effekt
solved the sequencing problem, but because it never had it. This is the single most important fact
for beni to take from this report, and §6 spells out the price.

**2. The mechanism that keeps this safe without effect rows is that blocks, objects and regions are
*second-class* — and the papers name exactly why first-class functions would break it.** An effect
annotation reads as *"the calling context must supply a capability"*, not as a description of what
the function does; Effekt's own docs call this the difference between "traditional" and "contextual"
effect polymorphism (§1, §2). The 2020 paper's own worked counterexample: *"we define the block
`leak`, which lists no effects since they are handled in its definition context. However, using the
leaked block outside of the corresponding delimiter `try { ... }` is not safe and leads to a runtime
error"* — which is why *"blocks are considered second-class and can neither be returned nor stored in
data structures"* (§1.6, via markdown extraction). The 2022 OOPSLA paper, *"Effects, Capabilities,
and Boxes,"* then re-admits a first-class *value* form (`box`/`unbox`, capture-set types `T at C`)
precisely because pure second-classness was "a severe loss of expressivity" (§2.4) — the two papers
together are the full story, and §2 and §4 both use it.

**3. The JavaScript backend has been rebuilt from a different theoretical foundation twice, and the
current one still has an admitted, open soundness gap in exactly the corner the theory is weakest.**
Effekt shipped three JS-relevant compilation strategies (full history §3, mechanism §2): a monadic
encoding inherited from pre-2020 Scala/Java libraries; a lift-inference/iterated-CPS/evidence-
monomorphization pipeline (OOPSLA 2023) that targeted **MLton, not JavaScript**, and was dropped that
same year as "quite involved"; and the current `core → cps → js` pipeline emitting `shift`/`reset` on
plain JS exceptions, a trampoline, and a persistent-arena scheme for multi-shot local mutable state.
That arena is the very feature a lead maintainer, in a still-open 2025-11 issue, called *"a bit
fragile ... an underused part of the language"* while confirming a colleague's own code was
*"effect-unsafe, I just didn't realize in the moment, but the issue is, the compiler didn't realize
either"* ([#1176](https://github.com/effekt-lang/effekt/issues/1176), Jonathan Brachthäuser as
`b-studios`, 2025-11-04). Three of the ten most-discussed open issues in the repository are
JS-backend codegen bugs that emit invalid JavaScript (§5).

---

## 1. The effect model

Effekt's effects are **native, not reified**. There is no `Task`, no effect monad, no generator
protocol standing in for control flow — `do get()` is an ordinary function-call-shaped expression
that, at runtime, transfers control to whatever handler is lexically enclosing it. The docs are
explicit that this is a deliberate reinterpretation, not an implementation detail:

> "As opposed to other effect systems, where effects communicate the *side effects* a program has
> besides computing a result, the notion of effects in the Effekt language is that of a
> **requirement**." — [`docs/concepts/effect-safety.md`](https://github.com/effekt-lang/effekt-website/blob/main/docs/concepts/effect-safety.md)

Concretely: `def div(n: Double, m: Double): Double / { exc } = ...` is read *"`div` computes a
`Double`, requiring a capability for `exc` in its calling context"* — an obligation on the caller,
not a claim about what the callee might do. This inverts the usual mental model (Koka, Eff, Links):
those track *possible side effects a term might perform*; Effekt tracks *what capabilities must
already be in scope for a term to type-check at all*. The practical consequence: **sequencing two
effects is exactly sequencing two statements** — nothing about calling an effectful function differs
syntactically from calling a pure one. `val user = do getUser(); val perms = do getPermissions(user)`
*is* the direct-style code; it is not sugar for anything, and there is no lower-level "andThen" form
it desugars into. The real distinguishing mark in the type system is a second, disjoint tracked
property called a **capture**:

> "**Effects** express a *requirement* on the context — certain capabilities still need to be
> provided by the caller. **Captures** express a *restriction* on where a computation can be used —
> the handler is already fixed in its lexical scope." — [`docs/tour/captures.effekt.md`](https://github.com/effekt-lang/effekt/blob/main/examples/tour/captures.effekt.md)

Every function, block, object and region has a capture set (`{io}`, `{exc}`, `{r}`, `{}`) tracking
which capabilities it has already closed over; every call site has an effect set (the right side of
`/`) tracking which capabilities it still needs handed to it — two axes, not one, and the tour says
outright this is a frequent source of newcomer confusion (§4). Builtin effects like `println` are not
effects at all in the tracked sense — they are **resources** (`io`, `global`, `async`), threaded like
any capability but fixed and unhandleable: *"Builtin side-effects like printing to the console are
tracked, but cannot be handled ... hence we do not track them as effects, but as second-class
resources"* (`docs/concepts/effect-handlers.md`, citing the 2022 paper).

**Effects as values? No, by design, but user code can convert either direction.** The `Exception[E]`
effect and the `Result[A, E]` datatype are explicitly two representations of one thing:

```effekt
/// Represent ("reify") the result of a potentially failing computation.
def result[A, E] { f: => A / Exception[E] }: Result[A, E] = try {
  Success(f())
} with Exception[E] {
  def raise(exc, msg) = Error(exc, msg)
}

/// Extracts the value of a result, if available — "monadic reflection"
def value[A, E](r: Result[A, E]): A / Exception[E] = r match {
  case Success(a) => a
  case Error(exc, msg) => do raise(exc, msg)
}
```
(`libraries/common/result.effekt`, comments verbatim: "reification" and "reflection" are the
library's own words.) So question 10 of the cross-cutting list has a real, sourced answer: **the
mechanism itself collapses effects into native control flow; it is user code, via a named
reify/reflect pair over `try`/`with`, that recovers deferred, inspectable effect *values* when a
program wants retry, logging, or `Result`-shaped composition.** There is no scheduler, no fiber
runtime, and no cancellation model in the base language — report 16's subject is out of scope here
and Effekt does not, on the evidence gathered, have one built in.

---

## 2. The mechanism

**What the user writes.** An effect signature is declared as an `interface` (or the `effect`
shorthand for a single operation); a function that needs it lists the interface name after `/` in
its return type; the operation is invoked with `do opName(args)`; a handler is `try { ... } with
Interface { def op(...) = ...; resume(v) }`. Not calling `resume` discards the rest of the delimited
computation (this *is* how you express early return / abort — cross-cutting question 3); calling it
more than once re-runs the delimited computation from the call site, each time with its own view of
any local mutable state (cross-cutting question 1, revisited below).

**What it means to the type system.** Nothing beyond ordinary lexical scoping resolves *which*
handler answers a `do` — Effekt performs no row unification, because there is no row. What the
checker enforces, per the OOPSLA 2020 paper, is two separate disciplines layered on an otherwise
ordinary HM-style checker:

1. **Values vs. computations, term- and type-level.** Blocks (functions), objects (interface
   instances) and regions are *computations*; everything else (numbers, strings, ADT instances,
   records, and *boxed* computations) is a *value*. Value arguments are parenthesised (`f(42)`);
   computation arguments are braced (`f { x => ... }`) and syntactically distinct in every position —
   this is not optional style, it's grammar. Computations are second-class by default: *"blocks are
   considered second-class and can neither be returned nor stored in data structures"* (2020 paper
   §1.6). This is exactly the restriction that makes the "leak" counterexample in Finding 2
   ill-typed rather than a runtime hazard: a block that closes over a capability simply cannot escape
   the scope that capability lives in, because escaping requires either returning it or storing it,
   both forbidden for second-class things.
2. **Boxing recovers a first-class value form, and makes captures a first-class type-level artefact
   to pay for it.** `box block` converts a second-class computation into a first-class value whose
   type carries an explicit capture set: `(() => Nothing / {}) at {exc}`. `unbox` reverses this, and
   is only well-typed where every capability in the capture set is still lexically in scope — the
   compiler enforces this, not a convention. The whole point, per the 2022 paper: *"note how `box`
   marks the transition from scope-based to type-based reasoning"* — before boxing, "can I use this
   capability" is answered by "is it in my lexical scope"; after boxing, it's answered by reading a
   type.

**Where the marker may appear (question 5).** There is no marker to place — `do` is an ordinary
prefix keyword on an ordinary call, legal anywhere a call is legal, with no "last position of a
block" restriction the way there is for Gleam's `use` or F#'s `let!` (report 15 §1). The only
positional restriction anywhere in the design is on `box`/`unbox`, and that is about *scope*, not
*statement position*.

**What it desugars to.** The surface language elaborates to a Core IR *"in explicit
capability-passing style"*, called *"System Ξ"* in the 2020 paper and *"System C"* in the 2022 paper.
A `try { S } with X { ... }` becomes a delimiter binding a fresh capability value for `X`'s
operations, and every `do op(...)` inside `S` becomes an ordinary method call on that value, looked
up lexically — the tour's own rewrite of a handler into an explicit capability
(`try { useCounter {counter} } with counter: Counter { def increment() = ...; resume(()) }`) makes
the correspondence to plain OOP explicit: *"guided by the type-and-effect system, the Effekt compiler
performs this translation from implicitly handled effects to explicitly passed capabilities"*
(`docs/tour/objects.effekt.md`, citing Brachthäuser et al. 2020). The lift-inference page shows the
literal generated Core for a two-handler example, capabilities materialised as extra parameters —
one of few Family-H sources showing its desugaring output verbatim rather than in prose.

**Contextual effect polymorphism — the payoff that avoids rows.** A higher-order function's
block-parameter type carries an effect set describing what the *function itself* requires, not what
the block may do: `def eachLine(file: File) { f: String => Unit / {} }: Unit / {}`. The traditional
(row-polymorphic) reading of `f`'s `/ {}` is "given a pure `f`, `eachLine` is pure" — useless for a
block that logs or raises. Effekt's contextual reading is *"given a block `f` without any further
requirements, `eachLine` does not require any effects"* — `f`'s real effects are discharged **at the
call site of `eachLine`**, in `f`'s own lexical scope (`docs/concepts/effect-polymorphism.md`). The
2020 paper calls this genuinely novel: *"Effekt offers contextual effect polymorphism ... To the best
of our knowledge, all languages with support for effects and handlers and static effect-typing
support this parametric form"* instead (§1.3). Its own case study draws blood against Koka
specifically: translating a lexer, *"the type checker would reject the program ... Koka translates
mutable variables ... to a synthesized state effect. Built around row-polymorphism, the details of
this encoding and the corresponding synthesized effects leak into the type of user programs"*
(§6.3.1) — and on the payoff: *"Modeling effects as sets greatly simplifies typing as no special
unification rules are needed"* (§3.2).

**Compiling to JavaScript, and how `resume` is represented.** The current default backend
(`generator/js/TransformerCps.scala`, since late 2024) lowers Core to a `cps` IR (a standard
direct-style-to-CPS pass threading a meta-continuation `ks` and continuation `k`), emitted as plain
JavaScript on four primitives read from `libraries/js/effekt_runtime.js`: `RESET` opens a delimiter
under a fresh `Symbol` prompt; `SHIFT` walks the meta-continuation chain collecting frames until it
finds that prompt, packaging each skipped frame's stack, prompt and mutable-state arena into a
linked-list value `cont` — this **is** `resume`, a heap-allocated JS object, not a captured native
call stack; `RESUME` rewinds `cont` onto the current continuation, restoring each frame's
mutable-state snapshot as it goes; `RUN_TOPLEVEL`/`TRAMPOLINE` bounce on plain function returns so a
long resumption chain cannot blow the native stack. Multi-shot resumption of *local mutable state* —
the `example1`/`example2` divergence in `tour/regions.effekt.md` — is handled by a small
persistent-array scheme (`Arena`/`Ref`): each write after a `snapshot` is recorded as a reversible
diff, so `restore` rewinds a variable to the value it held when a continuation was captured, in time
proportional to writes since, not to the variable's whole history. None of this is the
iterated-CPS/evidence-monomorphization scheme from the 2023 MLton paper (§3) — it is simpler,
JS-native, and, per §4 and §5, the corner where the implementation is still admittedly fragile.

### 2.1 The brief's `fetchSummary` example, faithfully

```effekt
interface Http {
  def getUser(): User
  def getPermissions(user: User): Permissions
  def getAuditLog(user: User): Log
}

record Summary(user: User, perms: Permissions, log: Option[Log])

def fetchSummary(): Summary / Http = {
  val user  = do getUser()
  val perms = do getPermissions(user)
  if (perms.isAdmin) {
    val log = do getAuditLog(user)
    Summary(user, perms, Some(log))
  } else {
    Summary(user, perms, None())
  }
}
```
This is not a rewrite of anything — it is what a programmer writes first. No `andThen`, no `use`, no
`yield*`. The bind-inside-a-branch case (cross-cutting question 2) needs no comment: `val log = ...`
inside the `if` arm is bound and used in the same expression with the same scoping rules as any other
`if` in a direct-style language, because `do getAuditLog` never left direct style to begin with.

### 2.2 Bind inside a loop (question 1)

```effekt
def fetchAllAdmins(ids: List[UserId]): List[Summary] / Http = {
  var out: List[Summary] = Nil()
  ids.foreach { id =>
    val perms = do getPermissions(id)
    if (perms.isAdmin) {
      val log = do getAuditLog(id)
      out = Cons(Summary(id, perms, Some(log)), out)
    }
  }
  out.reverse
}
```
`foreach`'s block parameter is effect-polymorphic exactly as `eachLine` was above — the library
function itself needs no effects, and the effects the block actually uses (`Http`) are discharged
wherever `fetchAllAdmins` is called. There is no fold-only idiom the way there is for Gleam's `use`
(report 15 §1): Effekt ships a native `while` plus library `each`/`repeat`/`loop` with
`break`/`continue` implemented as an algebraic effect named `Control` (`tour/loops.effekt.md`), so
even early-exit-from-a-loop is a handler, not special syntax.

### 2.3 Early return, pattern matching on the bound value, error propagation (questions 2, 3)

There is no `?` operator and no early-return keyword distinct from "don't call `resume`." Exceptions
are a *library*, not new syntax: `interface Exception[E] { def raise(...): Nothing }`, and *not
calling `resume`* in a handler is the entire mechanism for aborting the rest of a computation:

```effekt
def divide(n: Double, m: Double): Double / Exception[String] =
  if (m == 0.0) { do raise("division by zero", "div") } else { n / m }

def safeDivide(n: Double, m: Double): Result[Double, String] =
  result { divide(n, m) }   // "reify" — see §1
```
Pattern matching on a bound value is just `match`, no different from any other expression:
`do receive[A]()` in `libraries/common/list.effekt`-adjacent code returns an `Option[A]` matched with
`case Present(a) => ... case Absent() => ...` in the same statement that bound it — nothing about the
effect changes how matching works. **Mixing two effect types** (`Result` inside a handler-based
effect) is the `result`/`value` reify/reflect pair from §1: there is no automatic lifting the way
Rust's `?` applies `From::from` (report 15's Rust entry) — converting between the effect and the
value form is one named library call in each direction, and both directions are ordinary functions,
not compiler magic.

### 2.4 Diagnostics — what a missing or leaking capability looks like

Straight from the compiler's golden-test corpus, all paths under `examples/neg/`:

| Situation | Diagnostic | Source |
|---|---|---|
| Effectful call in a `/ {}` context | `Effect Console is not allowed in this context.` | `toplevel_effects.check` |
| `main` has unhandled effects | `Main cannot have effects, but includes effects: { Flip }` | `unhandledmain.check` |
| A boxed block's result type still mentions the handler's capability | `Capture Get escapes through type () => Int at {Get} inferred as return type of operation get.` | `lambdas/capability_closure.check` |
| A computation used where a value is expected | `Expected a value, but e is a computation. Use box e to pass it as a value instead` | `must_box_capability.check` |
| An effect's type parameter can't be inferred (two handlers in scope) | `Effects need to be fully known, but effect Greet[T]'s type parameter(s) T could not be inferred. Maybe try annotating them?` plus an `[info]` note per candidate | `lexical_capability_selection_ambiguous.check` |

These are unusually good as compiler diagnostics go — they name the exact capability, the exact
escape route, and (in the ambiguous case) offer a concrete fix. §4 has the counter-evidence: two
open, filed complaints that other diagnostics in the same checker are not this good.

---

## 3. History and decisions

Effekt's own [`docs/evolution.md`](https://github.com/effekt-lang/effekt-website/blob/main/docs/evolution.md)
is a rare thing in this programme: a page the design team maintains specifically to record what
changed since each paper, written for researchers who might otherwise benchmark or cite a stale
design. Quoted verbatim, in order:

- **2017–2018, Scala/Java libraries.** *"Effekt: Extensible Algebraic Effects in Scala"* (SCALA 2017)
  and *"Effect Handlers for the Masses"* (OOPSLA 2018) implemented lexical effect handlers as a
  Scala/Java library predating the standalone language, compiling *"to capability-passing style,
  using a monadic implementation of delimited control"* (`publications.md`); *"a translation of the
  monadic implementation of the Scala libraries is still the operational foundation of the JavaScript
  backend"* (`evolution.md`) — the JS runtime's ancestry predates the standalone language entirely.
- **2020, OOPSLA — the language itself.** Introduced lexical handlers, contextual effect
  polymorphism, and the block/value split, "using a capability-passing translation as an
  implementation strategy." Small surface changes since: operations now lower-case; `interface`
  groups operations, `effect` sugars a single one; singleton-operation type parameters are now
  universally, not existentially, quantified.
- **2022, OOPSLA — boxes.** *"Enabled us to add first-class functions back."* Before it: *"we talked
  about 'user-defined effects' and 'builtin effects' ... After this paper, we understood that there
  are no builtin effects, but that these are captures / resources ... Consequently, the `Console`
  effect was removed and replaced by the builtin `io` capability."* A conceptual reclassification, not
  a rename: `Console` had been *handleable*; `io` is a resource that can be captured but never
  intercepted.
- **2023, OOPSLA — lift inference, then its own retraction.** *"We complete the lift-inference
  pipeline from core ... via lifted, to regions, to iterated CPS,"* with evidence monomorphization
  and MLton's whole-program optimizer generating the binaries. Then, same page: *"we dropped the
  whole pipeline as well as the MLton backend ... the pipeline was quite involved (we published three
  papers about it), System F requires higher-rank polymorphism which is not supported by MLton, we
  only supported System Xi, but not System C."* This is why the JS backend read from source today
  does **not** implement evidence-passing or region inference — that machinery targeted a native-code
  backend that no longer exists; comparing against it needs "Effekt version 0.3.0 or older."
- **2025, ICFP — the current backend.** *"Multiple Resumptions and Local Mutable State, Directly"*
  describes the new LLVM backend, which *"supersedes the now deprecated MLton backend."* The JS
  backend is not this LLVM backend, but shares its era's `cps` IR and persistent-arena technique for
  multi-shot local state — mechanism detailed in §2.
- **Disclaimer, still current.** README: *"Effekt is a research-level language ... very likely to
  change ... there are (probably) many bugs."* Not boilerplate — §5's issue tracker backs it.

**Considered and rejected.** The 2020 paper rejected first-class blocks for the "leak" reason in
Finding 2, noting prior work pointed the other way: *"The work by Osvald et al. and Zhang et al.
suggests that it is viable to add first-class functions to Effekt. However, we purposefully refrained
from doing so"* (§7.2.1) — reversed only partially, via boxing, in 2022.

---

## 4. Costs — ergonomic and structural

**Question 4 (type-system demand), answered precisely.** Not a typeclass, not HKT, not an effect row.
It is (a) a second syntactic and type-theoretic category (computations vs. values) enforced
throughout the grammar, tracking a *capture set* on every computation type alongside its ordinary
type, and (b) an escape-analysis-flavoured well-formedness pass rejecting a capability that would
outlive its binder. In the compiler this is not one pass bolted onto HM — `effekt/shared/src/main/scala/effekt/typer/`
holds `CapabilityScope.scala`, `ConcreteEffects.scala`, `UnboxInference.scala` and
`Wellformedness.scala` as distinct files beside `Unification.scala` and `TypeComparer.scala`. Boxing
adds a further job: inserting or rejecting implicit `box`/`unbox` coercions at typing time
(`UnboxInference.scala`) — narrower than Haskell dictionary passing, but still a checker
responsibility beyond name lookup.

**Question 8 (diagnostics) — the other side of §2.4's good examples.** Two filed, still-open
complaints: a user's own type parameter named `Int` shadowed the builtin `Int`, and an
overload-resolution error printed `Expected Int but got Int` with no way to tell the two apart; a
later fix added a shadowing note, but the same class of confusion recurred on a different
type name later in the same thread ([#326](https://github.com/effekt-lang/effekt/issues/326)).
Separately, a user boxing a block inline got a message they themselves could not tell was "a bad
error message or ... an actual bug in Typer," and a workaround produced a *different* unhelpful
message for the same mistake ([#356](https://github.com/effekt-lang/effekt/issues/356)).

**Question 9 (removed or regretted) and the live soundness gap.** §3 covers the two large,
*acknowledged* removals. Beyond those, [#1176](https://github.com/effekt-lang/effekt/issues/1176)
(opened 2025-11-03, still open) is a maintainer-confirmed hole in effect *safety itself* — the
property this language exists to guarantee — where bidirectional effects (operations whose own
signature carries a further effect requirement) combine with `resume` and boxing. The reporter
(`kyay10`) showed `resume`'s inferred type under-reports what it captures, letting a locally-scoped
handler leak past its own delimiter — the exact "leak" hazard the 2020 paper's second-class
restriction exists to prevent, recurring *inside* the capability-passing translation for a feature
added after that paper. The lead author (Brachthäuser, as `b-studios`): *"Indeed it looks like there
is a bug in our implementation when it comes to typing bidirectional resumptions. This part is a bit
fragile in the implementation ... still fragile and an underused part of the language."* Asked
whether Effekt has proofs of effect safety covering this: *"No, sadly not. The written Effekt saga so
far was only 'no first class functions.'"* The formal guarantees in the papers and the shipped
compiler's actual type-checking of `resume` are, by the lead author's own account, not the same
artifact in this corner.

**Error locations, stack traces, tooling, and what newcomers get wrong.** No documentation, paper, or
issue discusses source-map fidelity, debugger readability across the CPS transform, or formatter
behaviour around `box`/`do`/`try` specifically (§8 records this as unresolved). On the confusion
newcomers do report: the tour flags the values/captures split in its own words — *"When programming
in Effekt, it can be very confusing that there are two different aspects of the type system that
ensure type-and-effect safety"* (`tour/captures.effekt.md`) — a rare case of a language's own docs
naming its ergonomic cost rather than leaving it to be discovered.

---

## 5. What users say

The evidence base here is thin relative to Koka or Roc (report 15's subjects): Effekt is a smaller,
more clearly research-labelled project, and the search-engine sweep this report would normally run
was unavailable (see Sources). What was found:

**One substantial discussion thread — evaluators, not production users.** The 2021 Hacker News
submission of `effekt-lang.org` (77 points, 18 comments) reads entirely as language-design
enthusiasts comparing Effekt to prior art, not anyone reporting production use. `saityi` gave the one
comment grounded in hands-on use of a comparable system: *"attempting effect libraries in Idris and
Agda, finding type inference issues to be too much to work around,"* requiring explicit signatures
everywhere, contrasted with Koka's "minimal hand-holding." `karmakaze` called the
no-first-class-functions design "exciting" while flagging uncertainty about its cost in practice — a
question §2 and §4 above now answer with more detail than was available in 2021. No comment reports a
completed project built in Effekt.

**GitHub issues, counted.** Of the ten most-discussed open issues in `effekt-lang/effekt` (by comment
count), **three are JS-backend codegen bugs producing invalid or crashing JavaScript**: a hyphenated
file name emitted verbatim as a JS identifier ([#149](https://github.com/effekt-lang/effekt/issues/149),
15 comments); a coroutine-shaped program compiling to `ReferenceError: $this is not defined`
([#249](https://github.com/effekt-lang/effekt/issues/249), 11); an optimizer pass producing
`ReferenceError: b_k_0 is not defined` on a mutable-reference example
([#934](https://github.com/effekt-lang/effekt/issues/934), 11). **Two more concern the correctness of
bidirectional/multi-resumption handlers**: an optimizer-breaks-multi-resume bug
([#971](https://github.com/effekt-lang/effekt/issues/971), 13) and the soundness gap quoted in §4
([#1176](https://github.com/effekt-lang/effekt/issues/1176), 18 — currently the single most-discussed
open issue in the repository). **Two more show users hitting the edges of capabilities alone**: how
to combine a producer and consumer effect into one coroutine-like computation, unresolved
([#108](https://github.com/effekt-lang/effekt/issues/108)); and whether polymorphic effects can
substitute for monad transformers, met with *"effects can't have lambdas as parameters in any way"*
in the position wanted ([#171](https://github.com/effekt-lang/effekt/issues/171)). The tracker skews
toward compiler-team-adjacent contributors, so this reads as "what the implementers find hard" more
than a cross-section of an application-building user base. **No independent account of a team
shipping and maintaining an Effekt codebase at scale was found** — available practitioner evidence is
almost entirely from language researchers and compiler contributors, itself informative about where
the language sits.

---

## 6. What it would take to do this in beni

beni is Hindley–Milner, has no typeclasses or HKT (ruled out in `fast-compiler.md` §3.1, restated by
report 15), has no row polymorphism, and targets JavaScript. Effekt's mechanism is the one candidate
in this whole programme designed for exactly that no-typeclasses, no-rows constraint set — its
second-class-computation discipline needs neither. What adopting it would require, deliver, and cost:

- **A second, disjoint tracked property on every function/closure type**: a *capture set*, closer to
  lifetime tracking than to an effect row — not a new type variable to solve for, but a new set to
  propagate and check for well-formedness at every function boundary, closer to escape analysis than
  to inference proper.
- **Distinguishing values from closures syntactically**, the way Effekt distinguishes `f(42)` from
  `f { x => ... }`. beni's closures are already fully first-class (JavaScript demands this at the
  boundary, `13-the-javascript-boundary.md`), so retrofitting second-classness would be a bigger break
  than Effekt's own history, where second-class was the *starting* point and boxing relaxed it later.
  Adopting only the "boxing" half — first-class by default, with an explicit annotation to *restrict*
  capture — fits beni's shape better than Effekt's own starting point did.
- **What it would deliver and not deliver:** true elimination of the `andThen` pyramid, by making
  effectful and pure code syntactically identical — every hard case in report 15's table (branch,
  loop, early return) is trivially "yes." It would **not** give effects-as-*values*: retry,
  cancellation and deferred execution (beni's Elm-derived `Task` use case) need the same hand-built
  reify/reflect pattern Effekt's `result`/`value` pair uses, not something free from the base
  mechanism — and it inherits Effekt's own admitted gap combining producer/consumer coroutines through
  capabilities alone (§5, #108); report 16's concurrency questions are not answered by this.
- **What the pipeline pays:** a JS backend here is not "compile handlers to functions." Effekt shipped
  three strategies and its current one still has an open soundness gap exactly where the
  capability-passing translation gets subtle (bidirectional/multi-resumption). The parts simple to
  explain (second-class blocks, contextual polymorphism) are proven by three papers; the parts needed
  to make `resume` fast and general with no native continuations are where the design still moves and
  its own authors call the implementation fragile. beni should expect the same split: the type
  discipline is adoptable now; compiling `resume` beyond simple non-resumptive exceptions is
  research-grade, by the testimony of the people who wrote three papers about the harder version and
  then retired it.

---

## 7. Ranked summary

1. Effekt has no `andThen`/pyramid problem to begin with: effects are requirements on the calling
   context, not values, so sequencing is native statement order. (documented — `effect-safety.md`, 2020 paper)
2. "Contextual effect polymorphism" (second-class blocks whose effects propagate to their call site,
   not definition site) is Effekt's alternative to row polymorphism; the 2020 paper shows a concrete
   case (a Koka lexer) where row-based typing leaks synthesized effect names that contextual
   polymorphism does not. (documented — Brachthäuser, Schuster & Ostermann 2020 §6.3.1)
3. The safety guarantee rests on computations being second-class by default (cannot be returned or
   stored); `box`/`unbox` (2022 paper) re-admits first-class values at the cost of an explicit,
   checker-tracked capture set on every boxed type. (documented — both OOPSLA papers)
4. The JavaScript backend has changed strategy twice: a monadic Scala-library inheritance, then a
   lift-inference/iterated-CPS pipeline built for MLton and dropped in 2023, now a `cps`-IR-to-JS
   pass using JS exceptions, a trampoline, and a persistent-arena snapshot/reroot scheme for
   multi-shot local mutable state. (documented — `evolution.md`; verified against `TransformerCps.scala`
   and `effekt_runtime.js`)
5. The current implementation has an open, maintainer-acknowledged soundness gap in `resume`'s typing
   for bidirectional and multi-resumption effects — the property the whole design exists to guarantee
   — as of a still-open November 2025 issue. (documented — #1176, quoting the lead author)
6. Diagnostics for common cases (missing capability, capability escape, forgetting to box) are
   unusually precise; diagnostics for overload resolution and inline boxing are separately filed as
   confusing, by users who could not tell a bad message from a bug. (documented — `examples/neg/*.check`
   vs. #326, #356)
7. Three of the ten most-discussed open GitHub issues are JS-backend codegen bugs emitting invalid
   JavaScript; two more concern bidirectional/multi-resume correctness. (measured — this report's own
   count via `gh api search/issues`, 2026-09-14)
8. Available user testimony is almost entirely from language researchers and the compiler's own
   contributors; no independent report of a production Effekt codebase was found. (documented, by
   absence)
9. There is no effects-as-values story in the base language; deferred/retryable computation is
   recovered by hand via a named reify/reflect pair over `try`/`with`, demonstrated for
   `Exception`/`Result`. (documented — `libraries/common/result.effekt`)
10. Combining two independently-defined effects into one coroutine-like computation is reported by at
    least one user as unclear with capabilities alone, unresolved in the linked thread. (unverified as
    a general limitation — single reported instance, #108)

---

## 8. What could not be resolved

- **No direct read of the OOPSLA 2020/2022 paper PDFs was possible** — WebFetch could not parse the
  compressed PDF streams, so a third-party markdown-extraction proxy (`r.jina.ai`) was used instead.
  Quotes from these papers came through that extraction and could not be checked against page images;
  section numbers are as reported, likely-but-unconfirmed. The 2025 "Multiple Resumptions" paper's
  abstract could not be retrieved at all (`dl.acm.org` served a bot-verification page), so the
  persistent-arena mechanism in §2 is sourced to the runtime directly, not the paper that proves it.
- **No search-engine discovery sweep** — the WebSearch budget was exhausted before this report began
  (shared across the programme's concurrent agents); only the Hacker News Algolia API and GitHub's
  issue/code search were available. A proper search likely would surface blog posts, a
  Discourse/Zulip/Discord community, and conference-talk commentary not captured here.
- **Formatter, IDE/LSP behaviour, and source-map/stack-trace fidelity** — no source discussed
  `effekt-vscode`/`effekt-neovim` behaviour around `box`/`do`/`try`, or readability across the CPS
  transform; neither package's source was read for this report.
- **Whether any production codebase exists** — no case study, blog post, or company using Effekt in
  production was found; `docs/casestudies` was not fully enumerated beyond its file listing.
- **Runtime cost (question 6) is out of scope by the project owner's instruction** — no benchmarks,
  timings, or allocation counts were sought, including for the CPS/trampoline/arena machinery
  described structurally in §2–§3.
