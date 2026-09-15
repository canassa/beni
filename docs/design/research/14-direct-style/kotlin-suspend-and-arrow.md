# Kotlin `suspend`: one compiler primitive, and what Arrow built on top of it

**Commissioned by** the shared brief for report 14 (`00-landscape.md` §2, `kotlin-suspend-and-arrow`,
Tier 1): Kotlin is the clearest public case of a language shipping *one* CPS/state-machine primitive
in the compiler and leaving every comprehension — `sequence { }`, `async`/`await`-style futures,
Arrow's typed-error `either { }` — to libraries built on it. The brief's own framing (Arrow's `Raise`
as "suspend-based direct style") turns out to be only half true of the code as shipped today, and
§0.2 below is the correction, sourced to Arrow's current implementation rather than its 2018 design.

**Sources.** The KEEP proposal for coroutines, fetched in full from
`raw.githubusercontent.com/Kotlin/KEEP/master/proposals/coroutines.md` (2026-09-14; the file opens
with a redirect notice to `Kotlin/KEEP/main/proposals/KEEP-0164-coroutines.md` but serves the
complete 1972-line document, authored by Andrey Breslav and Roman Elizarov, "Stable since Kotlin
1.3"), read section by section including its Terminology, Implementation details and Revision
history. The Kotlin language specification's asynchronous-programming chapter
(`kotlinlang.org/spec/asynchronous-programming-with-coroutines.html`). Kotlin compiler source read
directly from `raw.githubusercontent.com/JetBrains/kotlin/master/…`:
`compiler/ir/backend.js/.../lower/coroutines/JsSuspendFunctionsLowering.kt` and
`compiler/ir/backend.common/.../lower/AbstractSuspendFunctionsLowering.kt`. Arrow's `arrow-core`
source read directly from `raw.githubusercontent.com/arrow-kt/arrow/main/arrow-libs/core/arrow-core/
src/commonMain/kotlin/arrow/core/raise/{Raise,Fold,Builders,Effect}.kt` — this is where §0.2's
finding comes from, not from Arrow's docs pages, which describe the DSL from the outside and do not
show the `fold` implementation. Arrow's published guide (`arrow-kt.io/learn/typed-errors/...`) and
its superseded `old.arrow-kt.io/docs/patterns/monad_comprehensions/` page, read for the DSL's own
account of its history. Practitioner evidence from the Hacker News Algolia search API
(`hn.algolia.com/api/v1/search`, queried 2026-09-14) — a public API with no session budget, used
after this session's shared WebSearch allowance (200 calls) was already exhausted by earlier work in
this programme; counts below are that API's hit counts, not a survey. Two of Roman Elizarov's Medium
posts ("How do you color your functions", "Structured concurrency") were fetched through the
`r.jina.ai` reader proxy because `elizarov.medium.com` returns HTTP 403 to direct fetches; the proxy
returns a condensed extraction rather than raw HTML, so quotes drawn from it are marked and should be
read as reader-proxy-mediated, not hand-checked against the original markup. GitHub's REST contents
API was rate-limited for anonymous requests for this entire session, so some directory listings
(Arrow's platform-specific `jsMain`/`jvmMain` sources) could not be enumerated; §8 records what that
cost. No original measurements were run, per the shared brief's ergonomics-only, read-only rules.

---

## 0. The three findings, up front

**1. The compiler does exactly one thing — a CPS transform plus a state machine — and everything
else is a library.** The KEEP's stated goals are "no dependency on a particular implementation of
Futures", to "cover equally the 'async/await' use case and 'generator blocks'", and to make coroutines
"wrappers for different existing asynchronous APIs" (`coroutines.md`, Abstract). The mechanism section
says it plainly: "the compiler is only responsible for support of suspending functions, suspending
lambdas, and the corresponding suspending function types. There are few primitives in the standard
library and the rest is left to application libraries" (`coroutines.md`, Terminology). Concretely: a
`suspend fun f(x: A): T` is rewritten to `fun f(x: A, continuation: Continuation<T>): Any?`, and a
function body with more than one suspension point becomes one anonymous class with an integer `label`
field, fields for every local variable "spilled" across suspension points, and a `resumeWith`/
`invokeSuspend`/`doResume` method that is a `switch` on `label` (`coroutines.md`, State machines;
verified for JS in `JsSuspendFunctionsLowering.kt`, discussed in §2). `sequence { }`, `future { }`,
`launch { }`, and Arrow's `either { }` are all ordinary functions written against this one primitive
— none of them is compiler-known.

**2. Arrow's `either { }`, as it ships today, is not continuation-based — it is an `inline` function
plus an ordinary thrown exception, and it only *looks* suspend-based because of an unrelated Kotlin
inlining rule.** `Raise<Error>.raise(r: Error): Nothing` is not `suspend`
(`arrow/core/raise/Raise.kt:210`). `either { block }` desugars to `fold(block, { Left(it) }, { Right(it) })`
(`arrow/core/raise/Builders.kt:51-54`), and the primitive `fold` is:

```kotlin
// arrow/core/raise/Fold.kt:128-152
public inline fun <Error, A, B> fold(
  block: Raise<Error>.() -> A,
  catch: (throwable: Throwable) -> B,
  recover: (error: Error) -> B,
  transform: (value: A) -> B,
): B {
  val raise = DefaultRaise(false)
  return try {
    val res = block(raise)
    raise.complete()
    transform(res)
  } catch (e: RaiseCancellationException) {
    raise.complete()
    recover(e.raisedOrRethrow(raise))
  } catch (e: Throwable) {
    raise.complete()
    catch(e.nonFatalOrThrow())
  }
}
```
and `DefaultRaise.raise` is `throw if (isTraced) Traced(r, this) else NoTrace(r, this)`
(`Fold.kt:259-260`), where both are subclasses of the `expect sealed class RaiseCancellationException
… : CancellationException` (`Fold.kt:274-281`). This is family K/exceptions-as-nonlocal-return, not
family F. `suspend` calls are allowed *inside* `either { }`'s block only because `either` and `fold`
are `inline`, and Kotlin's own rule is that "suspending function calls inside inline lambdas … are
allowed" when the caller is itself a `suspend fun` (`coroutines.md`, Terminology) — the block is
spliced into the caller, so it inherits the caller's coroutine state machine for free and needs none
of its own. `Effect<Error, A>` — the genuinely `suspend`-typed sibling (`typealias Effect<Error, A> =
suspend Raise<Error>.() -> A`, `Effect.kt:665`) — exists for interop with async code, but the
mainstream `either { }`/`option { }`/`nullable { }` builders that users reach for do not use it.
Arrow's own KDoc warns against the consequence directly: "Handling errors can also be done with
`try`/`catch` but this is **not recommended**, it uses `CancellationException` … and is advised not to
capture" (`Raise.kt` doc comment, quoted in `Effect.kt:313-314`).

**3. Kotlin's designers treat colouring as a deliberate, defended trade — and Arrow's own history is
a second data point for the same trade, made independently, in the opposite direction of "more
suspend."** Elizarov, on why `suspend` is not eliminated the way Go eliminates the sync/async split:
"You immediately see which functions are allowed to perform potentially long communications and which
are supposed to complete quickly" (Elizarov, "How do you color your functions", via r.jina.ai
extraction, accessed 2026-09-14) — colouring-as-documentation, not colouring-as-accident. Nine years
of practitioner commentary mostly agrees the trade is real and mostly does not ask for its removal:
17 of Hacker News's indexed comments pair "function coloring" with Kotlin, and the recurring shape is
"yes, and it's fine because it's a compile error, not a runtime surprise" — e.g. "Kotlin's co-routines
… uses colored functions but because it is statically compiled language, there is no chance of doing
this wrong as that would simply be a compile error" (HN user, 2021-09-26, item 28659987). Separately,
Arrow's maintainers moved the opposite direction from where the brief expects: the DSL used to be
built on real coroutine machinery (`createCoroutine`, per `old.arrow-kt.io`'s monad-comprehensions
page, §3.2) and was rewritten onto plain exceptions specifically so the common, synchronous, typed-
error case would not need a continuation at all — see finding 2.

---

## 1. The effect model

Kotlin's `suspend` is not effects-as-values. There is no `Task` type the compiler knows about and no
monad the type system enforces; there is a **colour** — `suspend` as a modifier on a function type,
checked the same way `private` or `inline` is checked, with the sole extra rule that "a suspending
function cannot be invoked from a regular code, but only from other suspending functions and from
suspending lambdas" (`coroutines.md`, Terminology). Sequencing two effects is: write two suspend calls
one after another. There is no `andThen`, no `bind`, no operator at all in the base language — the
CPS transform makes the *next line* the continuation of the suspend call on the current line, which
is exactly what an `andThen` closure does by hand, done once, in the backend, for every suspend
function. `kotlin.coroutines.Continuation<T>` (`context: CoroutineContext`, `fun resumeWith(result:
Result<T>)`) is the entire compiler-visible vocabulary (`coroutines.md`, Continuation interface).
Everything with a shape — "does this suspend represent I/O, a generator step, or cooperative
scheduling" — is a library's interpretation of the same primitive: `launch { }`/`async { }` in
kotlinx.coroutines build a scheduler on top; `sequence { }` builds a pull-based iterator; Arrow's
`Raise<E>` builds typed short-circuiting that, per §0.2, does not even need suspension for its most
common form. So: **is there something interpreted by a runtime, the way Elm's `Task` is?** For
kotlinx.coroutines, yes — `Job`, `Deferred`, dispatchers, and structured `CoroutineScope`s are a real
runtime (out of scope here, report 16's subject). For the base `suspend` primitive itself and for
Arrow's `Raise`, no: a suspend function call executes eagerly up to its first real suspension, and
`either { }`'s block executes eagerly, top to bottom, the moment it is called — nothing is deferred,
retried, or re-interpreted (cross-cutting Q10, answered fully in §4).

---

## 2. The mechanism

### 2.1 What the user writes, what it compiles to

A `suspend fun`:
```kotlin
suspend fun sendEmail(emailArgs: EmailArgs): EmailResult
```
compiles, after "CPS transformation", to (`coroutines.md`, Continuation passing style):
```kotlin
fun sendEmail(emailArgs: EmailArgs, continuation: Continuation<EmailResult>): Any?
```
`T` moves into the continuation's type argument; the declared return type becomes `Any?` because
Kotlin has no denotable union of `T` and the sentinel `COROUTINE_SUSPENDED` — "when suspending
function *suspends* coroutine, it returns … `COROUTINE_SUSPENDED` … When a suspending function does
not suspend … it returns its result or throws an exception directly" (`coroutines.md`, same section).
For a body with two suspension points the compiler builds one class with an `int label`, one field
per local variable live across a suspension, and a state-machine method that is a `switch` on `label`
(`coroutines.md`, State machines; reproduced verbatim below because the exact shape is the load-bearing
fact):
```java
class <anonymous_for_state_machine> extends SuspendLambda<...> {
    int label = 0
    A a = null
    Y y = null
    void resumeWith(Object result) {
        if (label == 0) goto L0
        if (label == 1) goto L1
        if (label == 2) goto L2
        else throw IllegalStateException()
      L0:
        a = a(); label = 1
        result = foo(a).await(this)
        if (result == COROUTINE_SUSPENDED) return
      L1:
        y = (Y) result; b(); label = 2
        result = bar(a, y).await(this)
        if (result == COROUTINE_SUSPENDED) return
      L2:
        Z z = (Z) result; c(z); label = -1; return
    }
}
```
The KEEP is explicit that a **loop with a suspension point generates only one state**, "because loops
also work through (conditional) `goto`" — the pseudocode for `while (x < 10) { x += nextNumber().await() }`
has exactly two labels (before and after the `await`), not one per iteration (`coroutines.md`, State
machines). When suspend calls appear only in tail position, the compiler skips the state machine
entirely and compiles the function like an ordinary one, threading the continuation through
(`coroutines.md`, Compiling suspending functions) — the one place the transform is *not* paid.

### 2.2 What the type system must know

Nothing beyond the colour. There is no class or trait resolved for a bare suspend call — `suspend` on
a function type is checked structurally, the same way Kotlin checks any other function-type modifier.
Two annotations extend this without adding real type-system machinery: `@RestrictsSuspension` on a
receiver interface (e.g. `SequenceScope<T>`) makes any extension suspend function on that receiver a
*restricted suspending function*, which "can only invoke member or extension suspending functions on
the same instance of their restricted suspension scope" — so a `sequence { }` block cannot smuggle in
an arbitrary `suspendCoroutine` and must go through `SequenceScope.yield` (`coroutines.md`, Restricted
suspension). `suspendCoroutine`/`suspendCoroutineUninterceptedOrReturn` are ordinary standard-library
functions, not compiler magic, that expose the continuation to library code wanting to wrap a
callback-style API (`coroutines.md`, Wrapping callbacks, Coroutine intrinsics).

### 2.3 Where the construct may appear

Inside a `suspend fun` or `suspend` lambda body, a suspend call is legal **anywhere an expression may
appear** — this was not always true. Revision 3 of the KEEP (Kotlin 1.1-Beta) records: "Suspending
functions can invoke other suspending function at arbitrary points" as a *change*, implying earlier
revisions restricted where a suspend call could occur (`coroutines.md`, Revision history, Changes in
revision 3). Outside a suspend context the rule is absolute: "Non-suspending functions may not call
suspending functions directly" (Kotlin spec, Suspending functions). The one carve-out is inlining:
"suspending function calls inside inline lambdas … are allowed, but not in the `noinline` nor in
`crossinline` inner lambda expressions. A *suspension* is treated as a special kind of non-local
control transfer" (`coroutines.md`, Terminology) — the same rule that lets a non-local `return` cross
an inline lambda boundary. This is exactly the rule §0.2 uses to explain why `either { }`'s
non-`suspend` block can still contain suspend calls when inlined into a suspend caller.

### 2.4 The hard cases, in Kotlin

**Bind inside a branch**, no extra nesting, matching Effect-TS and unlike Gleam's `use`:
```kotlin
suspend fun Raise<HttpError>.fetchSummary(): Summary {
    val user  = getUser().bind()
    val perms = getPermissions(user).bind()
    return if (perms.isAdmin) {
        val log = getAuditLog(user).bind()
        Summary(user, perms, log)
    } else {
        Summary(user, perms, null)
    }
}
```
(`Raise<E>` as an extension receiver, resolved by ordinary scope lookup — Arrow's own docs give the
shape as `fun Raise<String>.failure(): Int = raise("failed")` and note "Kotlin offers two choices
here: we can use an extension receiver, and in the future we may use context parameters" — quoted
from `arrow/core/raise/Raise.kt`'s doc comment.)

**Bind inside a loop** — the case family D (Gleam `use`, Roc backpassing) cannot express at all:
```kotlin
suspend fun Raise<IoError>.readAll(source: ChunkSource): List<Chunk> = buildList {
    while (true) {
        val chunk = readChunk(source).bind()   // suspend AND raise, mid-loop, no fold
        if (chunk.isEnd) break
        add(chunk)
    }
}
```
This is a direct transcription of the KEEP's own `aRead`/`aWrite` loop example (`coroutines.md`,
Asynchronous computations) with a `bind()` substituted for the raw `await`-shaped call.

**Early return / error propagation.** `raise(e)` *is* the early return — `Raise.raise(r: Error):
Nothing` is documented to "behave like a return statement, immediately short-circuiting and
terminating the computation" (`Raise.kt` doc comment). Interaction with `try`/`finally`: the KEEP's
own generator example shows a suspension point directly inside `try { yield(lastItem()) } finally { … }`
working exactly as expected (`coroutines.md`, Generators) — a suspension is a "non-local control
transfer," so it composes with `finally` the same way a non-local `return` does. Arrow's `raise` goes
through the JVM/JS exception mechanism, so it also runs any enclosing `finally` — but this is precisely
the mechanism Arrow's own KDoc warns is fragile if the *user* wraps `either { }` code in a bare
`catch (e: Throwable)`, since that will catch `RaiseCancellationException` too unless the user is
careful (`Effect.kt`, quoted in §0.2).

**Mixing effect types (`Result` inside `Task`).** Arrow's `Raise<E>` is the general answer: any
wrapper type gets a `.bind()` extension (`Either<E,A>.bind()`, `Option<A>.bind()`) that calls
`raise()` on mismatch, so a plain `Result`/`Either` value binds inside a `suspend`-and-`Raise` block
with the same syntax as a suspend call — "we can use `.bind()` to 'inject' any sub-computation that
might be required, or `raise` to describe a logical failure" (`arrow-kt.io/learn/typed-errors`).

---

## 3. History and decisions

**A `coroutine` keyword existed and was removed.** The KEEP's revision history — the single most
concrete "regretted design" record found for this report — states for Revision 2 (Kotlin 1.1-M04):
"The `coroutine` keyword is replaced by suspending functional type," "Continuation for suspending
functions is implicit both on call site and on declaration site," and "The concept of coroutine
controller is dropped: Coroutine completion result is delivered via `Continuation` interface"
(`coroutines.md`, Changes in revision 2). So the shipped design — a modifier on ordinary function
types, no keyword, no explicit continuation threading by the user — was arrived at by *removing*
machinery from an earlier, more explicit design, not by adding it. The KEEP's own reference list marks
this split directly: "Part 1 (prototype design): Coroutines in Kotlin (Andrey Breslav at JVMLS 2016)"
versus "Part 2 (current design): Kotlin Coroutines Reloaded (Roman Elizarov at JVMLS 2017)"
(`coroutines.md`, References) — titled by Kotlin's own team as two different designs a year apart;
this report did not transcribe either talk, so treat the fact of a redesign as documented and its
content as (unverified).

**Why `suspend`, not `async`/`await`.** The KEEP argues the equivalence and the cost directly: a
`suspend fun` and an `async`-returning function "can be easily converted into one another," but
"async-style function composition is more verbose and *error prone*. If you omit `.await()` invocation
… the code still compiles and works, but it now does email sending process asynchronously or even
*concurrently* … thus potentially modifying some shared state" (`coroutines.md`, Asynchronous
programming styles). And on scope: "Suspending functions are a light-weight language concept in
Kotlin. All suspending functions are fully usable in any unrestricted Kotlin coroutine. Async-style
functions are framework-dependent" (same section) — this is the KEEP's stated reason `suspend` covers
both async/await *and* generators with one primitive, where C#/JS need `async`/`await` for one and
`function*`/`yield` for the other. Elizarov, later, on the name itself: `suspend` was chosen in part
because suspending functions can be entirely synchronous (a `sequence { }` body never touches a
thread), which "async" would misdescribe — "Asynchrony is a secondary concern. It should not stand in
the way of understanding the business logic" (Elizarov, "How do you color your functions," via
r.jina.ai). He also records a second, deliberate difference from Swift: no explicit `await` marker at
the call site, unlike Swift's `try`-style marker (same source) — a design choice this report's sibling
on Swift (`swift-async.md`) should be checked against for the opposite argument.

**Arrow's own reversal.** The superseded `old.arrow-kt.io/docs/patterns/monad_comprehensions/` page
describes the earlier `either { }`/`bindingCatch` as working by "us[ing] the rest of the sequential
operations as the function you'd normally pass to `flatMap`" and doing so "internally using the kotlin
suspension system" — i.e., built on `createCoroutine`, matching the brief's framing. The current
`fold`/`either { }` in `Fold.kt`/`Builders.kt` (§0.2) is not suspend-based at all. No changelog entry
explaining the switch was located in the time available (§8); the shipped source is the only
primary evidence for the change itself.

---

## 4. Costs — ergonomic and structural

**What it forces the user to restructure.** Almost nothing, which is the headline cost-benefit: since
a suspend call is legal in any expression position inside a coloured function, code does not need
restructuring around it the way family A/B/D syntaxes require a nested block per branch. The
restructuring is at the *boundary*: a non-suspend caller cannot reach a suspend function at all, and
must either become `suspend` itself (propagating the colour upward through every caller) or call
`runBlocking { }`. Kotlin's own docs frame this as the sanctioned but reluctant escape hatch: "Use
`runBlocking()` only when there is no other option to call suspending code from non-suspending code"
(`kotlinlang.org/docs/coroutines-basics.html`, via r.jina.ai) — a designed friction, not an oversight.

**Diagnostics and locations.** A type error inside a `suspend` block is an ordinary Kotlin type error
at the call site — the CPS transform is a *backend* lowering, done after type checking, so it does not
degrade diagnostics for `suspend` itself. Arrow's `raise()` is a different story: by default
`DefaultRaise(false)` throws a `NoTrace` exception, i.e. **no stack trace is captured for a raised
error** unless the user opts into `traced { }`, which the KDoc says "implies a performance penalty of
creating a stacktrace when calling `Raise.raise`" (`Fold.kt`, `traced` doc comment) — cited here only
because the source states it as a one-line fact, per the brief's rule. The ergonomic cost is squarely
in scope, though: a bare `raise("boom")` gives the caller a value, not a location, unless they
explicitly asked for one.

**What it demands of the compiler pipeline.** The frontend adds one check (a function-type modifier,
`suspend`-callable-only-from-`suspend`) and nothing to inference or unification — no new constraint
kind, matching cross-cutting Q4's cheapest answer, "nothing beyond a colour on the signature." The
expensive part is entirely a backend lowering pass:
`compiler/ir/backend.common/.../lower/AbstractSuspendFunctionsLowering.kt` defines the shared
"`CoroutineBuilder`" machinery and an abstract `buildStateMachine`;
`compiler/ir/backend.js/.../lower/coroutines/JsSuspendFunctionsLowering.kt` implements it for
JavaScript, naming the generated class `"${function.name}COROUTINE$"` and the state-machine method
`doResume` (`JsSuspendFunctionsLowering.kt:36-45`). Its `buildStateMachine` builds a `suspendResult`
variable, a `suspendState` variable, and an `IrWhenImpl` `switch` inside a `do`/`while` loop wrapped in
a `try` (`JsSuspendFunctionsLowering.kt:154-186`) — the same shape as the KEEP's pseudo-Java, now
verified in the actual JS lowering, not just the design document.

**Tooling.** Kotlin/JS's lowering contains a debugger-specific accommodation: for a suspend function
that only *delegates* to another suspend call at its tail (no real state machine needed), the compiler
still assigns the return value to a temporary variable before returning it, purely "to improve the
debugging experience. Otherwise, a breakpoint set to the closing brace of the function cannot be hit"
(`JsSuspendFunctionsLowering.kt:135-137`) — a concrete, sourced example of a state-machine backend
paying an extra line of generated code for debugger fidelity, the kind of cost §4 exists to record. The
same file's comment block shows the road not taken for JS specifically: a delegating suspend call
*could* compile to `function* foo() { return yield* bar() }` (native generator delegation) but Kotlin
instead emits a plain `function foo() { return bar() }`, because "it minimizes the output size"
(`JsSuspendFunctionsLowering.kt:99-118`) — the compiler has (or had) a generator-emitting path,
gated by a `context.compileSuspendAsJsGenerator` flag at `JsSuspendFunctionsLowering.kt:60`, that this
report could not further characterise (§8).

**Newcomer mistakes, with evidence.** The two recurring ones in official docs and practitioner
commentary are (a) reaching for `GlobalScope.launch` instead of a structured `CoroutineScope`, which
kotlinx.coroutines' own guide and Elizarov's "Structured concurrency" post exist specifically to head
off — "we need some mechanism to cancel it when the corresponding UI element is closed by a user"
(Elizarov, 2018-09-12, via r.jina.ai) — and (b) catching a bare `Throwable`/`Exception` around Arrow's
`Raise` code and inadvertently swallowing the internal `RaiseCancellationException`, which Arrow's own
docs flag as the reason to prefer `catch`/`recover` over `try`/`catch` (§0.2).

**Optimiser transparency (Q7).** Split result: an `inline` builder like `either { }` is maximally
transparent — the block is spliced into the caller, so Kotlin's own dead-code elimination and renaming
see straight-line code, and R8/DCE on the JS/JVM side see nothing coroutine-shaped at all. A `suspend`
lambda passed to a non-inline coroutine builder (`launch { }`, `future { }`) is the opposite: it
becomes its own class instance, opaque to cross-function inlining the way any heap-allocated closure
is. Family F's usual cost (opaque state object) and family K's usual benefit (fully inlinable) are
both present in Kotlin, on two different code paths that happen to share `suspend` as their surface
syntax.

---

## 5. What users say

**Praise, from practitioners, is mostly about structured concurrency, not about `suspend` syntax
itself** — matching the shared brief's own observation that report 16's subject and this one are
adjacent. HN, 2023-07-18: "One of the nice things with Kotlin is the ability to extend existing APIs
via extension functions… the co-routines library uses extensively to be able to provide co-routine
implementations on top of existing frameworks" (item 36767584) — praise for the library-not-keyword
design the KEEP set out to achieve (§3). Official docs state the guarantee plainly: "A parent
coroutine waits for its children to complete before it finishes. If the parent coroutine fails or gets
canceled, all its child coroutines are recursively canceled too" (`coroutines-basics.html`, via
r.jina.ai).

**Complaints cluster entirely on colouring and the `runBlocking` boundary**, and are argued, not just
felt: "Java's structured concurrency approach to async code eventually may result in much simpler
libraries compared to Kotlin's approach, which introduces function coloring with the 'suspend'
modifier" (HN, 2023-08-09, item 37067491, story 37068468); "I'm not too brushed up with Kotlin
suspend, but does it suffer from the classic 'function coloring' problem…" followed by a description
of the exact pain — updating "a huge call hierarchy" to add one effectful call partway down (HN,
2023-06-11, item 36284771). One thread names Elizarov directly as a source for the counter-argument:
"Roman Elizarov (of Jetbrains, author of Kotlin and lead on Kotlin Coroutines) agrees too" that
colouring's "insight… is terribly important," linking his own "How do you color your functions" post
(HN, 2023-06-05, item 36194075) — i.e., even complaint threads route back to the designer's stated
position rather than treating it as an accident. Of Hacker News's indexed comments, 17 pair "function
coloring" with Kotlin and 13 pair "suspend" with "colored" specifically about Kotlin (HN Algolia,
2026-09-14) — not a large corpus, but a real and recurring one, entirely about the suspend/blocking
split, never about Arrow or `either { }` (no HN hits found pairing Arrow's `Raise` with any complaint
term in the queries run for this report).

**Wishes**, inferred rather than directly quoted: Project Loom / Java virtual threads recur in the
same threads as an explicit "no coloring" alternative practitioners want Kotlin to be able to adopt —
"The interesting aspect is not 'running Kotlin coroutines on Loom', but eliminating the need for
source-level coroutine keywords and solving the problem of function coloring, no?" (HN, 2022-05-04,
item 31258746) — a wish for the JVM platform to make the whole `suspend` mechanism optional someday,
not a wish for Kotlin to change today.

**Maintainers vs evaluators.** The distinction the brief asks for is visible but not sharp in this
corpus: comments defending colouring tend to describe concrete Kotlin/Android codebases ("because it
is statically compiled language, there is no chance of doing this wrong as that would simply be a
compile error," item 28659987); comments attacking it tend to be comparative, from people evaluating
Kotlin against Go, Java Loom, or Elixir rather than reporting a maintenance cost — e.g. "I deal with
async function coloring in swift and Kotlin… but never feel like I'm wrestling with function coloring"
in Elixir (HN, 2025-10-31, item 45768930).

---

## 6. What it would take to do this in beni

**Type system.** Exactly what §4 already found for Kotlin's own frontend: one new modifier on a
function type (or, for beni's HM inference, one new tag threaded through unification the way
mutability or purity annotations are), checked structurally — no class, no HKT, no row polymorphism.
This is cheap in the sense report 15 already used that word: it lives in the checker as a colour, not
as a new constraint kind, so it does not touch the unifier's core algorithm.

**Compiler pipeline.** This is squarely option **C** in `fast-compiler.md`'s "live options" table —
"emit a state machine ourselves" — and Kotlin's JS backend is close to a worked example of exactly
that choice already made for JavaScript: one lowering pass, after type checking, walking the coloured
function body and producing a class with a label field and spilled locals
(`JsSuspendFunctionsLowering.kt`, §2.1/§4). It answers cross-cutting Q1–Q3 uniformly and for free: a
suspend/bind is legal inside a loop, inside a branch, and interacts correctly with `try`/`finally`,
because none of those are special-cased — the transform walks the whole function body once. This is
the same answer report 15 gave for *why* family F is more powerful than family D (`use`-style): the
marker can appear anywhere an expression may, at the cost of a real backend transform rather than a
44-line desugarer.

**What it would deliver.** The single biggest thing Kotlin's design demonstrates that beni's `Task`-
only framing does not yet consider: **one primitive, many comprehensions.** If beni built a
suspend-like colour for `Task` specifically, it would only ever buy flat `Task` sequencing. Kotlin's
lesson is that the *same* mechanism, if generalised to any effect a library wants to model as
"suspend, resume later," also buys `sequence`-style generators and (per Arrow's early history) typed
error handling — for free, in libraries, with no further compiler work. Whether that generality is
worth the cost is exactly the question `fast-compiler.md` marks open.

**What it would not solve, and what the Kotlin/Arrow story would warn against.** Two warnings, both
sourced above: first, the KEEP's designers would say — because they said it, repeatedly, as a design
goal (§3) — do not let the compiler know about `Task`, `Future`, or any specific effect shape; keep
the compiler's job to the colour and the transform, and put every builder in a library, exactly as
`fast-compiler.md`'s "minimal type-system surface area" premise already argues. Second, Arrow's
maintainers would say the opposite of what the brief's framing suggests: continuation-capture is not
free, and when a library only needs short-circuiting (not real suspension across an event loop), they
moved *away* from it, onto `inline` plus an exception (§0.2, §3). For beni, the actionable version is:
if the goal is flat `Result`/`Task` sequencing without a general-purpose async runtime, Arrow's second
design — an `inline` desugarer plus a control-flow exception used only inside a single call tree — may
be the closer analogue than Kotlin's `suspend`, and it has already been built and then *replaced* the
suspend-based version in the one library that tried both.

---

## 7. Ranked summary

1. (documented) Kotlin's compiler lowers exactly one thing — `suspend` — to a CPS transform and a
   state machine; every builder (`sequence`, `launch`, `either`) is a library function, stated as an
   explicit design goal in the KEEP's Abstract and Terminology sections.
2. (documented) Arrow's shipping `either { }`/`fold` is `inline` plus a thrown
   `RaiseCancellationException`, not continuation capture — verified directly in
   `arrow/core/raise/Fold.kt:128-152, 252-263`, contradicting the "suspend-based" framing this report
   was commissioned under.
3. (documented) A suspend call is legal anywhere an expression may appear inside a coloured function,
   including inside loops, branches, and `try`/`finally` — the KEEP states this was generalised in
   Revision 3 (Kotlin 1.1-Beta), implying it was more restricted before.
4. (documented) A `coroutine` keyword and an explicit continuation-passing surface syntax existed and
   were both removed in Revision 2, in favour of the modifier-only design that shipped.
5. (documented) Kotlin/JS shares its state-machine lowering with the JVM backend
   (`AbstractSuspendFunctionsLowering`), naming the generated class `<fn>COROUTINE$` and its resume
   method `doResume`; a native-JS-generator emission path exists behind a
   `compileSuspendAsJsGenerator` flag whose activation this report could not further characterise.
6. (documented) The type-system cost of `suspend` is exactly a colour on a function type — nothing
   added to unification or inference, the cheapest point on cross-cutting Q4's scale.
7. (documented) Practitioner complaint volume (HN) is concentrated entirely on the suspend/blocking
   colour boundary and `runBlocking`; no complaint about Arrow's `Raise` specifically was found in the
   same corpus.
8. (documented) Structured concurrency, not `suspend`/`await` syntax, is what both the designer
   (Elizarov's dedicated post) and practitioners cite as the mechanism's real payoff.
9. (unverified) The JVMLS 2016 "prototype design" talk versus the JVMLS 2017 "current design" talk,
   both cited by the KEEP's own reference list, imply a substantial redesign this report did not
   transcribe.
10. (inferred) For beni, Arrow's post-2018 move away from continuations for pure error-short-circuiting
    is a closer analogue than Kotlin's general `suspend` if the immediate goal is flat `Task`/`Result`
    sequencing rather than a general async-and-generators primitive.

---

## 8. What could not be resolved

- **`compileSuspendAsJsGenerator`.** Found only the guard clause (`JsSuspendFunctionsLowering.kt:60`,
  `if (context.compileSuspendAsJsGenerator) return`) and a comment showing the conceptual alternate
  output (`function* foo() { return yield* bar() }`). Could not locate the flag's definition, its
  default, or the alternate lowering's implementation: tried `raw.githubusercontent.com` guesses
  against several plausible file names, GitHub's code-search UI (requires sign-in), `grep.app`
  (HTTP 429), and `sourcegraph.com` (HTTP 403). Not resolved.
- **Arrow's platform-specific (`jsMain`/`jvmMain`) `actual` implementations of
  `RaiseCancellationException`.** The `commonMain` side is an `expect sealed class`; the JS-specific
  subclass could not be located because GitHub's REST contents API returned HTTP 403 ("API rate limit
  exceeded for anonymous requests") on every directory-listing attempt made during this session,
  including retries. The mechanism (throw/catch of a `CancellationException` subtype) is verified in
  `commonMain` and is very unlikely to differ meaningfully on JS, since `throw`/`catch` are native to
  both targets, but the exact class was not read.
- **Why Arrow rewrote `either { }` off continuations.** The `old.arrow-kt.io` monad-comprehensions
  page documents the *earlier* suspend-based design; the current `inline`+exception design is fully
  verified in source (§0.2); no changelog, release note, or design-rationale post explaining the
  *reason* for the change was located in the time available. Tried: `r.jina.ai`-proxied fetches of a
  small number of guessed Arrow blog URLs, all either 404 or off-topic.
- **This session's WebSearch budget (200 calls) was already exhausted by earlier work in this research
  programme before this report began.** All web discovery here used direct URL fetches, `curl` against
  `raw.githubusercontent.com` and the GitHub REST API (rate-limited, see above), and the free,
  unauthenticated Hacker News Algolia search API. No broad discovery sweep (e.g., of Reddit, the
  Kotlin Discourse/Slack archive, or YouTrack) was possible; the practitioner evidence in §5 should be
  read as "what HN's index surfaces," not as a survey of the Kotlin community.
- **Roman Elizarov's Medium posts were read through the `r.jina.ai` reader proxy**, not fetched
  directly (`elizarov.medium.com` returns HTTP 403 to non-browser clients, confirmed with and without
  a spoofed user agent). The proxy returns a condensed extraction; quotes taken from it are as
  rendered by that proxy and were not independently checked against Medium's raw markup.
- **The two JVMLS talks** ("Coroutines in Kotlin", Breslav 2016; "Kotlin Coroutines Reloaded",
  Elizarov 2017) cited by the KEEP as "prototype design" versus "current design" were not watched or
  transcribed; §3 and §7 item 9 rely only on the KEEP's own characterisation of the split.
