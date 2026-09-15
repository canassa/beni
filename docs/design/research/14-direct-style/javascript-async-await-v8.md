# JavaScript's own `async`/`await` and generators: TC39 history and what the substrate gives away free

**Commissioned by** the direct-style programme's Tier-1 slot for the platform itself
([00-landscape.md](00-landscape.md) §2, `javascript-async-await-v8`). Every other report in this
programme studies a language that *targets* JavaScript. This one studies the two constructs
JavaScript *natively* runs — generator functions (ES2015) and `async`/`await` (ES2017) — because
report [15](15-flat-effect-syntax.md) and `fast-compiler.md` §3.2 both treat "emit generators" or
"emit an async function" as a live option for beni's own Task syntax, and neither asks what that
buys beyond a shape. The question here is narrow and mechanical: **when beni's compiler emits a
`function*` or an `async function` instead of writing its own state machine, which of Rust's and
C#'s hand-written-transform costs (report `csharp-async-state-machine.md`,
`regenerator-and-tsc-downlevel.md`) does V8 absorb for free, and which does the *language design*
of generators — one-shot, no capture below the frame — refuse to let any compiler have, no matter
who writes the transform?** Effect-TS's use of generators as a library escape hatch is report
`effect-ts.md`'s subject and is cited here, not re-derived. The downlevel-to-ES5 transform is
`regenerator-and-tsc-downlevel.md`'s subject and is cited here, not re-derived. This report is the
substrate underneath both: the TC39 committee history that produced the two constructs, the exact
specification algorithms that define `yield`, `yield*`, `.return()`/`.throw()`, and `await`, and
what a compiler pass gets from V8 having already built this machinery into the engine rather than
into a code-generation pass.

**This research is ergonomics-only.** No benchmark, timing, or allocation count appears below;
question 6 of the shared brief's cross-cutting list (per-bind and per-call cost) is out of scope by
the programme owner's instruction and is answered "out of scope" wherever it recurs, not
"no verified number found" — the difference matters because report 15 and the landscape brief still
flag the generator-object-allocation question as genuinely unmeasured, and this report does not
attempt to close it. Nothing was run locally; no compiler, Node process, or script was executed.

**Sources.** The full text of the current ECMA-262 specification (`tc39/ecma262@main/spec.html`,
fetched 2026-09-14, 55,109 lines) read directly and grepped for every generator- and
await-related abstract operation cited below — `GeneratorResume`, `GeneratorResumeAbrupt`,
`RunSuspendedContext`, `RunCallerContext`, `Await`, the `YieldExpression` runtime semantics
(including the full `yield*` delegation algorithm), and the `ConciseBody` grammar production. The
**entire commit and issue/PR history of `tc39/proposal-async-await`** read via the GitHub API (120
issues and PRs, plus the README's history through `git log --follow`), which is where the original
1970s-style `spawn(function*(){...})` desugaring, the four rejected `function^`/`function!` surface
syntaxes, and the `await*`-to-`Promise.all` removal debate come from — none of this is on the
current README, which was stripped to a stub by
[PR #110](https://github.com/tc39/proposal-async-await/pull/110) in 2016; it survives only in the
git history, read here directly. Two ES-wiki strawman pages — `strawman:deferred_functions` (Erik
Arvidsson, last edited 2011-10-29) and `strawman:async_functions` (Mark S. Miller, last edited
2011-08-27) — recovered from the Internet Archive's CDX API and Wayback snapshots (`web.archive.org`
is unreachable through the fetch tool but reachable via direct HTTP, which is how these were read).
V8's `v8.dev/blog/fast-async` (Meurer & Marja, 2018-11-12, updated for V8 v7.2/v7.3) read in full for
the microtask-count history and zero-cost async stack traces. `tc39/ecma262#1250` ("Normative:
Reduce the number of ticks in async/await", Maya Lekova, merged 2019-02-26) and ESLint's
`no-return-await` rule documentation, which cites both. The `mozilla/task.js` and `tj/co` READMEs.
Bob Nystrom's "What Color is Your Function?" (2015-02-01). `mozilla/source-map#221`, a closed
debugger/source-map issue used as the concrete "what breaks" case for §4. The current
`tc39/proposal-async-context`, `tc39/proposal-explicit-resource-management`, and
`tc39/proposal-iterator-helpers` READMEs, `tc39/proposals` `README.md` and `finished-proposals.md`
for exact stage numbers, and the TC39 delegate meeting notes for 2025-09-23
(`tc39/notes/meetings/2025-09/september-23.md`, the "AsyncContext yield*" agenda item) read in full.
**This session's WebSearch budget was already exhausted before this report began** (a shared,
session-wide quota), so no query-based web discovery was available at any point; every source above
was reached by direct URL fetch, the GitHub REST API via `gh api`, or the Wayback Machine's CDX API
reached through `curl` (the dedicated fetch tool refuses `web.archive.org` outright). This is a
narrower discovery sweep than a search-backed one and §8 says where it likely cost coverage. All web
sources accessed **2026-09-14**.

---

## 0. The three findings, up front

**1. `async function`/`await` was never a new mechanism — it is `spawn(function*(){ ... })`,
literally, in the proposal's own words, and the modern specification still shares the *same*
resume/suspend machinery between the two constructs.** The original 2013 proposal by Luke Hoban
gave the rewrite rule verbatim:

```
async function <name>?<argumentlist><body>
=>
function <name>?<argumentlist>{ return spawn(function*() <body>); }
```

with `spawn` a **quoted, runnable** JavaScript function that drives the generator with a promise
chain (`tc39/proposal-async-await` README at commit `99d4f490`, 2014-03-15 — see §3.1 for the full
text). Thirteen years later the specification's `Await` abstract operation and the `%GeneratorPrototype%`
methods both bottom out in the *same two* execution-context primitives, `RunSuspendedContext` and
`RunCallerContext` (ECMA-262 §sec-runsuspendedcontext, §sec-runcallercontext) — the engine literally
suspends one execution context and resumes another, for a `yield` and for an `await` alike. **A
compiler that emits either construct is asking V8 to do exactly one job it already knows how to do
once**, not two.

**2. `yield` cannot cross a function boundary, and this is enforced by the grammar, not a runtime
check — which makes generators exactly as "coloured" as async functions, just at one function's
scope instead of the whole call graph.** `ConciseBody` — the production an arrow function's body
reduces to — takes **no** `[Yield]` parameter at all (ECMA-262 grammar, `sec-arrow-function-definitions`),
so `yield` inside an arrow function is a **parse-time** error regardless of what encloses it: `yield`
is confined to the literal `FunctionBody` of the generator that owns it. There is no way to write a
helper function, pass a callback, or factor out a loop body that itself suspends the *outer*
generator — the only escape hatch is `yield*`, which delegates to a second, independently-driven
generator, not a shared frame. This is report 00's "no capture below the generator frame" made
concrete: a generator is a **one-shot, single-frame coroutine**, and no library sitting on top of it
(co, Effect.gen, or beni's own codegen) can make it anything else.

**3. Native `async`/`await` gets two dated, documented wins that a library driving bare generators
structurally cannot get, because both wins depend on the engine recognising that `await`'s resume
point and suspend point are the same source location — true for `await` inside an `async function`,
not true for a `.next()` call issued from a trampoline several stack frames away.** V8's zero-cost
async stack traces (`v8.dev/blog/fast-async`, 2018, enabled by default at v7.3) reconstruct the
*await site*, not the call site, precisely because "for `await` the resume and suspend locations are
the same" — the article says outright that this is *not* true of `Promise#then()`/`.catch()`, and by
the same logic it is not true of a bare `gen.next()` call made by a driver library. Separately, the
2018 microtask-count fix (`tc39/ecma262#1250`, Maya Lekova, merged 2019-02-26; V8 7.2) is specified
**on the `Await` abstract operation itself**, so it applies to every `async function` an engine runs
and to nothing that merely uses `yield`. A compiler that lowers beni's `Task` sequencing to bare
generators — the only shape that preserves deferred execution, see §1 — inherits neither win for
free; a compiler that lowers to native `async`/`await` gets both, but only by giving up the
deferred-value model entirely (§1, §6).

---

## 1. The effect model

JavaScript has **no effect type system** anywhere in either construct. `Promise<T>` is an ordinary
class; `async function` is a function-kind flag on an ordinary function object; nothing in the type
of a value says whether producing it ran a side effect. The distinction beni's `Task e a` encodes in
the type checker does not exist here at all — it is entirely a runtime protocol, and this is true
even before TypeScript is added to the picture (TypeScript's `Promise<T>` is exactly V8's, with no
effect-tracking beyond it).

**Generators and async functions model two different things, and conflating them is the single
most common source of confusion in the proposal's own issue tracker** (see #49, quoted in §3.4).

- A **generator** (`function*`) is a **coroutine that produces values on demand** — the iterator
  protocol, `{ value, done }`, generalised to let the *consumer* pass a value back in via
  `.next(v)`. Calling a generator function does **not** run any of its body; it allocates one
  Generator object in `suspended-start` state (ECMA-262 §sec-generator-objects) and returns it.
  Nothing happens until something calls `.next()`. This is the closest thing JavaScript has to a
  deferred value — the generator object *is* inert until driven — which is exactly why every
  effects-as-values escape hatch in JavaScript (task.js's `spawn`, `co`, Effect.gen, report
  `effect-ts.md`'s subject) is built on generators and never on async functions.
- An **`async function`** is **eagerly-started, promise-returning, ordinary JavaScript**. Calling
  one runs its body synchronously up to the first `await` (or to completion, if there is none) —
  there is no "have I started yet" state to defer. `AsyncFunctionStart` (ECMA-262
  §sec-async-functions-abstract-operations-async-function-start) creates the return promise and
  immediately resumes the function body via `RunSuspendedContext`; the caller gets a `Promise` back
  whether it wanted the work to start now or not. **This is why native `async`/`await` cannot be
  beni's `Task` primitive on its own**: a `Task` that runs the moment it is constructed is not a
  value a runtime can retry, cancel, or sequence without side effects it didn't ask for — precisely
  the property `elm.md` and `roc-purity-inference.md` spend their §1 sections establishing for their
  own subjects. A bare generator, undriven, has that property; a called async function does not.

"Sequencing two effects" therefore means two different things depending on which construct is in
play. For `yield`, sequencing is whatever the driver's `.next()` loop does with the yielded value —
by convention "await this promise, then feed back the result" (task.js, co, the original `spawn`,
Effect.gen), but nothing in the language enforces that convention; a generator can just as well drive
a state machine, a parser, or `redux-saga`'s effect descriptors. For `await`, sequencing is fixed by
the specification: suspend the running execution context, register two promise reactions via
`PerformPromiseThen`, and resume on whichever reaction fires (§2.3 below, the `Await` algorithm
verbatim). There is exactly one interpretation of `await` and it is baked into the language; there
are as many interpretations of `yield` as there are libraries willing to write a driver loop.

---

## 2. The mechanism

### 2.1 The original rewrite (2013), still true in spirit

Luke Hoban's proposal (`tc39/proposal-async-await`, commit `97b5cbee`, 2014-01-28 — the repository's
initial commit, following on from Miller's and Arvidsson's ES-wiki strawmen, §3.1) defined `async
function` purely as sugar over generators and a hand-written scheduler, and the README quoted the
whole thing:

```JavaScript
function spawn(genF) {
    return new Promise(function(resovle,reject) {
        var gen = genF();
        function step(nextF) {
            var next;
            try {
                next = nextF();
            } catch(e) {
                reject(next); // (sic — the original had this bug; see below)
                return;
            }
            if(next.done) {
                resolve(next.value);
                return;
            }
            Promise.cast(next.value).then(function(v) {
                step(function() { return gen.next(v); });
            }, function(e) {
                step(function() { return gen.throw(e); });
            });
        }
        step(function() { return gen.next(undefined) });
    })
}
```

(the typo `resovle`/`reject(next)` instead of `reject(e)` was real, fixed by a later commit,
`13af7644` — even the language's own designer got a hand-rolled generator driver slightly wrong).
Everything a beni-emitted "drive this generator as a Task" runtime would write — a `step` function, a
`try`/`catch` around `.next()`, a promise chain re-entering on both fulfillment and rejection — is
already here, twelve years earlier, motivating the syntax rather than implementing an application.

### 2.2 The modern specification: shared primitives, separate surface

The current spec never mentions `spawn`; `async function` is specified directly, but on the *same*
two execution-context operations generators use:

```
RunSuspendedContext ( context, completionRecord ):
  1. Let callerContext be the running execution context.
  2. Suspend callerContext.
  3. Push context onto the execution context stack; context is now the running execution context.
  4. Resume the suspended evaluation of context, passing completionRecord as the result
     of the operation that suspended it. Let result be the Completion Record passed back.
  5. Assert: context has already been removed from the execution context stack.
  6. Return Completion(result).
```

(ECMA-262 §sec-runsuspendedcontext, condensed). `%GeneratorPrototype%.next(v)` calls
`GeneratorResume`, which sets the generator's state to `executing` and calls
`RunSuspendedContext(genContext, NormalCompletion(v))` (§sec-generatorresume). `Await(arg)` does the
conceptually identical thing on the *promise* job queue instead of a caller: it resolves `arg` to a
promise, attaches `onFulfilled`/`onRejected` handlers that each call
`RunSuspendedContext(asyncContext, …)`, and returns control to the caller via `RunCallerContext`
(§sec-await, quoted in full in §2.3). The two constructs differ in **who drives the resume** — the
generator's caller for `yield`, the promise job queue for `await` — and in nothing else at the level
of "suspend this stack frame and come back to it later." This is the concrete cash-out of finding 1:
whichever one a compiler emits, it is reusing one piece of V8 machinery, not asking for two.

### 2.3 `await`, verbatim, and what it says about microtask ordering

```
Await ( arg ):
  1. Let asyncContext be the running execution context.
  2. Let promise be ? PromiseResolve(%Promise%, arg).
  3. Let fulfilledClosure be a closure that, given value, performs
       RunSuspendedContext(asyncContext, NormalCompletion(value)).
  4. Let onFulfilled be CreateBuiltinFunction(fulfilledClosure, 1, "", « »).
  5. Let rejectedClosure be a closure that, given reason, performs
       RunSuspendedContext(asyncContext, ThrowCompletion(reason)).
  6. Let onRejected be CreateBuiltinFunction(rejectedClosure, 1, "", « »).
  7. Perform PerformPromiseThen(promise, onFulfilled, onRejected).
  8. Return ? RunCallerContext(empty).
```

(ECMA-262 §await, condensed from the full text read at `spec.html:52584-52605`). This already carries
the 2019 fix: `PromiseResolve` (step 2) returns an existing promise unchanged instead of always
wrapping. Before that fix, per V8's blog, `await`ing an already-fulfilled promise cost **three
microtask-queue ticks and two extra promises**: one wrapper promise created unconditionally, one
throwaway promise required by `PerformPromiseThen`'s API shape, and the ticks to resolve each. The
fix, `tc39/ecma262#1250` (Maya Lekova, merged 2019-02-26), treats this as an **observable semantics
change**, not an implementation detail: "JavaScript programmers may expect that [`promise.then(f)`]
and [`f(await promise)`] are largely similar... however... there are three job queue items enqueued
and dequeued before calling `f` in the `await` example, whereas there is just a single item for the
`then` usage," with a stated design goal that "job queue processing remains deterministic, including
both ordering and the number of jobs enqueued (which is observable by interspersing other jobs)."
**Microtask count is an observable-semantics question, and the committee landed the fix as a
normative spec PR, not an engine-only optimisation** — report 15's framing applies directly. ESLint's
`no-return-await` rule is the practitioner-facing residue: it warned against `return await x` because
it used to cost an extra tick, and its current text says the rule "is NOT recommended... anymore
because... `return await` on a promise will not result in an extra microtask," citing `ecma262#1250`
and the same blog post. The rule still special-cases `try` blocks, because there `return await x` is
not redundant — it is required to route a rejection through the enclosing `catch` (§4.4).

### 2.4 `yield`, `yield*`, and `.return()`/`.throw()`, verbatim

```
YieldExpression : yield
  1. Return ? Yield(undefined).
YieldExpression : yield AssignmentExpression
  1. Let value be ? GetValue(? Evaluation of AssignmentExpression).
  2. Return ? Yield(value).
```

`GeneratorYield` sets the generator's state to `suspended-yield` and calls
`RunCallerContext(iteratorResult)` (§sec-generatoryield) — the mirror image of `Await`: instead of
registering a promise callback, it hands control straight back to whoever called `.next()`.
`%GeneratorPrototype%.return(v)` and `.throw(e)` are both one-liners that construct a completion
record and call `GeneratorResumeAbrupt`:

```
GeneratorResumeAbrupt ( gen, abruptCompletion, genBrand ):
  1. Let state be ? GeneratorValidate(gen, genBrand).
  2. If state is suspended-start, set gen.[[GeneratorState]] to completed; set state to completed.
  3. If state is completed:
       - if abruptCompletion is a return completion, return an iterator result { value, done: true }
       - else, return ? abruptCompletion   (i.e. re-throw)
  4. Assert: state is suspended-yield.
  5. Set gen.[[GeneratorState]] to executing.
  6. Return ? RunSuspendedContext(genContext, abruptCompletion).
```

Step 6 is the entire mechanism behind "`finally` intercepts `.return()`/`.throw()`": the abrupt
completion is injected at **exactly the suspended `yield` expression**, as if that expression itself
had thrown or returned, and ordinary JavaScript completion-record propagation does the rest — a
`try { yield x } finally { cleanup() }` runs `cleanup()` because the injected `ReturnCompletion`
propagates out through the `try` statement's normal evaluation rules, precisely as a `return`
inside the `try` would. `tc39/proposal-explicit-resource-management`'s own motivating example
(§3.5) is the canonical illustration, and it predates the `using` syntax by describing the pattern
`using` is sugar for:

```js
function * g() {
  const handle = acquireFileHandle();       // critical resource
  try { /* ... */ }
  finally { handle.release(); }             // cleanup
}
const obj = g();
try { const r = obj.next(); /* ... */ }
finally { obj.return(); }                   // calls the finally block in g
```

`yield*` delegation is a **loop**, not a single hand-off, and its handling of an outer `.throw()`/
`.return()` is a documented *protocol*, not a language guarantee — this is worth stating precisely
because it is the exact place a hand-written driver (co, Effect.gen, beni's own runtime) has to get
right by hand if it reimplements delegation instead of using `yield*` itself:

```
YieldExpression : yield * AssignmentExpression   (abbreviated)
  ... obtain iteratorRecord from evaluating AssignmentExpression ...
  repeat:
    if received is a normal completion:
        call iteratorRecord.[[NextMethod]]; if done, return its value; else GeneratorYield it
    else if received is a throw completion:
        let throw be GetMethod(iterator, "throw")
        if throw is undefined:
            IteratorClose(iteratorRecord); throw a TypeError  — "protocol violation"
        else: call throw; if done, return its value; else GeneratorYield it
    else (received is a return completion):
        let return be GetMethod(iterator, "return")
        if return is undefined: return ReturnCompletion(received.[[Value]])   — propagate, no forwarding
        else: call return; if done, return ReturnCompletion(its value); else GeneratorYield it
```

(ECMA-262, `sec-generator-function-definitions-runtime-semantics-evaluation`, `YieldExpression :
yield * AssignmentExpression`). Two things fall out that a compiler emitting `yield*` for beni's own
delegation must reckon with: **an inner iterator that lacks a `.throw()` method turns an outer
`.throw()` into a hard `TypeError`, after closing the inner iterator** — delegation to a plain
(non-generator) iterable is not transparent to exceptions unless that iterable happens to implement
`.throw`; and **an inner iterator that lacks `.return()` still propagates the outer `.return()`'s
value**, so cleanup silently does not happen inside the delegate. Neither behaviour is a bug; both
are exactly what "the marker may appear anywhere, but the protocol is opt-in per iterator" buys —
report 15's Family-table axis ("where the marker may appear") applies here too, except the marker
(`yield*`) can appear anywhere a `yield` can (inside the one generator frame, per finding 2), and the
*protocol it forwards* is negotiated at run time against whatever object it is pointed at.

### 2.5 Position: anywhere an expression may appear, and V8 pays for that in the engine, not the parser

`await` is a `UnaryExpression`; `yield`/`yield*` is an `AssignmentExpression` (ECMA-262 grammar,
§sec-async-function-definitions, §sec-generator-function-definitions). Both can appear **anywhere an
expression may** — inside a condition, an argument list, a pipeline, a template literal — which is
exactly the shape report 15 measured as the *expensive* one when a language builds it as a source-to-
source desugaring (Roc's removed `!`, 1,046 lines and a shipped crash). JavaScript does not pay that
cost in a desugaring pass at all: the "arbitrary position" property is a property of the *bytecode*
V8 already generates for every expression, not of an extra compiler pass that has to find every
place the marker could occur. This is the concrete shape of finding 1 and finding 3 together — a
compiler that targets native generators or `async function` gets "suspend anywhere in this
expression tree" for the price of emitting a `yield`/`await` token in the right lexical position,
because the *engine's* interpreter loop already knows how to suspend and resume at an arbitrary
bytecode offset. Report `regenerator-and-tsc-downlevel.md` is the evidence for what it costs to
*re-derive* that property in userland, in a downlevelling pass that runs before V8 is involved.

### 2.6 The hard cases

**Bind inside a branch.** Trivial and unrestricted — `await`/`yield` are ordinary expressions, so
this needs no new block, unlike Gleam's `use` (report `gleam-use.md`):

```js
async function fetchSummary(userId) {
  const user = await getUser(userId);
  const perms = await getPermissions(user);
  if (perms.isAdmin) {
    const log = await getAuditLog(user);
    return new Summary(user, perms, log);
  }
  return new Summary(user, perms, null);
}
```

The bare-generator form of the same function, undriven (matching §1's point that only this form is a
deferred value), needs a driver — here the historical `spawn` from §2.1, or `co`, or beni's own
runtime:

```js
function* fetchSummaryTask(userId) {
  const user = yield getUser(userId);
  const perms = yield getPermissions(user);
  if (perms.isAdmin) {
    const log = yield getAuditLog(user);
    return new Summary(user, perms, log);
  }
  return new Summary(user, perms, null);
}
// fetchSummaryTask(id) returns an inert Generator; spawn(() => fetchSummaryTask(id)) runs it.
```

**Bind inside a loop** — the case report 00 says block-structured syntactic rewrites (`use`, `let*`,
backpassing) cannot express at all, needing a fold instead. Generators and `async`/`await` express it
directly, because `yield`/`await` are ordinary expressions and a `for` loop is ordinary control flow
around them:

```js
async function chainAnimations(elem, animations) {
  let ret = null;
  try {
    for (const anim of animations) {
      ret = await anim(elem);       // bind inside a loop, no fold required
    }
  } catch (e) { /* ignore and keep going */ }
  return ret;
}
```

(adapted from the 2013 proposal's own `chainAnimationsAsync` example, `README.md` at commit
`99d4f490`). Running every iteration's `await` **sequentially** is the default and the only thing a
bare loop expresses; running them **concurrently** needs an explicit `Promise.all` outside the loop
(`await Promise.all(animations.map(anim => anim(elem)))`), and the committee deliberately declined to
give that its own syntax — §5 counts how often that was asked for and quotes the refusal.

**Early return.** `return` inside an `async function` resolves its promise; a `throw` (or an awaited
rejection) rejects it; both interact with `try`/`finally` exactly as in synchronous code, because
`AsyncFunctionStart` runs the function body as ordinary statement evaluation with `Await` as the only
new expression form — no new control-flow rule was added for early return. Inside a **generator**,
`.return(v)` from *outside* is a different thing from a `return` statement written inside the
generator body: the former is `GeneratorResumeAbrupt` injecting a `ReturnCompletion` at the suspended
`yield` (§2.4); the latter is ordinary statement evaluation. Both run enclosing `finally` blocks.

**Pattern matching on the bound value.** No restriction — `await`/`yield` produce an ordinary value
that can be destructured, switched on, or passed to any expression form: `const { ok, value } = await
fetchResult()`.

**Mixing two effect types (a `Result` inside a `Task`).** JavaScript has no `Result` type to mix in
natively; user code represents it as a tagged union or throws, and `await`/`yield` are indifferent to
which — they suspend on the *value*, not on its shape. This is "not applicable" as a language-level
question and becomes a userland library design question the moment beni's own `Result`-in-`Task`
mixing is considered (`fast-compiler.md`'s `?`-on-`Task` discussion, cited in report 00, is exactly
this question for beni).

**Error propagation.** A rejected `await`ed promise throws synchronously at the `await` expression,
so ordinary `try`/`catch` catches it — this is the entire error-propagation story for `async`/
`await`, and it is also where the sharpest newcomer mistake lives (§4.4, `#92`).

---

## 3. History and decisions

### 3.1 Deferred Functions (2011) → async_functions strawman (2011) → task.js (2012) → co (2013) → the TC39 proposal (2013–2020)

The lineage is four steps, each one narrowing scope:

1. **"Deferred Functions"**, an ES-wiki strawman last edited 2011-10-29 by **Erik Arvidsson** (`arv`,
   a Google TC39 delegate), recovered from the Wayback Machine (`web.archive.org/web/20130820233020/
   http://wiki.ecmascript.org/doku.php?id=strawman:deferred_functions`). It already has the exact
   surface syntax that shipped: *"This proposal adds 'await expression' syntax... The 'await
   expression' evaluates the expression... suspends execution of the current function, attaches the
   continuation of the current function to the 'awaited object' by calling its `then` function, and
   then returns."* Its own example is the animation-loop case §2.6 still uses:

   ```js
   function deferredAnimate(element) {
     for (var i = 0; i < 100; ++i) {
       element.style.left = i;
       await deferredTimeout(20);
     }
   }
   ```

   The page footnotes itself: *"See async_functions for a revised version of this proposal
   implementable as a library in terms of concurrency and generators."*

2. **"Async Functions"**, the revision it points to, last edited 2011-08-27 by **Mark S. Miller**
   (`markm`). This is the pivot from a *new primitive* to *sugar over an existing one*: *"This page
   is a revision of deferred_functions to explain how to express it as a library in terms of the
   concurrency strawman and the generators proposal."* Its worked example is `Q.async` composed with
   a generator — `const asyncAnimate = Q.async(function*(element) { for (...) { yield delay(20); } });`
   — which is `spawn` in every respect except the name.

3. **task.js** (Mozilla, ~2012), which shipped `Q.async` as a standalone library function `spawn`:
   *"makes... sequential, blocking I/O simple and beautiful, using the power of JavaScript's new
   `yield` operator"*; its design note that *"tasks are interleaved like threads, but they are
   cooperative rather than pre-emptive: they block on promises with `yield`"* is the clearest
   statement in this lineage of what a driven generator actually is (a cooperative coroutine, §1).
   It required Firefox specifically, being the only engine with ES6 generators at the time.

4. **`co`** (TJ Holowaychuk, 2013), the library nearly every Node async codebase ran through before
   2017. Its README states its purpose plainly: *"`co@4.0.0` has been released, which now relies on
   promises. It is a stepping stone towards the
   [async/await proposal](https://github.com/lukehoban/ecmascript-asyncawait)"* — a library-space
   placeholder, by its own authors' admission, for a language feature already being drafted.

5. **The TC39 proposal itself**, `lukehoban/ecmascript-asyncawait` → `tc39/proposal-async-await`,
   initial commit 2014-01-28 (`97b5cbee`). Its very first substantial content (commit `99d4f490`,
   2014-03-15) makes the lineage explicit: *"A similar proposal was made with
   [Deferred Functions]... during ES6 discussions. The proposal here supports the same use cases,
   using similar or the same syntax, but directly building upon generators and promises instead of
   defining custom mechanisms."* — i.e., step 4's precondition (generators must already exist) is
   what let this proposal drop step 1's separate `Deferred` object model entirely and simply
   desugar to `spawn(function*(){...})` (§2.1). Async/await shipped as ES2017; `for await...of` and
   async generators followed in ES2018. The repository's last substantive activity is
   [PR #109, "incorporated into ECMA-262"](https://github.com/tc39/proposal-async-await/pull/109),
   merged 2020-11-19 — a housekeeping closure of the tracking repo, years after the feature had
   already shipped in every major engine.

### 3.2 Four rejected surface syntaxes, in the proposal's own words

Before the README was stripped in 2016 (§3.3), it recorded, under "Debatable Syntax & Semantics",
four alternative keyword pairings the committee weighed against `async function`/`await`
(`tc39/proposal-async-await` README at commit `0854d305`, 2015-12-17):

> Instead of `async function`/`await`, the following are options:
> - `function^`/`await`
> - `function!`/`yield`
> - `function!`/`await`
> - `function^`/`yield`

Two of the four keep `yield` as the suspension keyword and mark only the function head differently
(`function!`, `function^`) — a direct echo of "deferred functions"' original framing, where the
*function* is the thing that needs marking, not the suspension point. `async`/`await` won because it
reads as English and does not overload `yield`'s existing generator meaning, but the alternatives
column shows the committee seriously considered making async functions a variant of the *generator*
keyword rather than a new word — which would have made the "isomorphic to generators" relationship
syntactically visible instead of merely true underneath (finding 1).

### 3.3 `await*` and `Promise.all`: proposed, shipped in Babel, formally removed

The original 2014 proposal included `await*` as sugar for `Promise.all`, reasoning by analogy with
`yield*`: *"It has been suggested that the syntax could be reused for different semantics - sugar for
Promise.all... This is expected to be one of the most common Promise-related operations that would
not yet have syntax sugar"* (README at `99d4f490`). Babel implemented it; the spec never shipped it.
[Issue #102](https://github.com/tc39/proposal-async-await/issues/102) ("`server.asyncawait.js` uses
`await*` syntax") and [PR #103](https://github.com/tc39/proposal-async-await/pull/103) ("Convert
`await* ...` to `await Promise.all(...)`") record the removal in 2014-03, and
[issue #61](https://github.com/tc39/proposal-async-await/issues/61) preserves the committee's
reasoning directly:

> **bterlson** (Brian Terlson, spec editor): "It doesn't seem useful to me... we just don't need
> sugar for typing `Promise.all`."
> **domenic** (Domenic Denicola): "And it definitely wouldn't use `*` because it has no correlation
> with what `*` means for generators. Babel is just not implementing the spec here."
> **arv** (Erik Arvidsson): "Another point to not do `await*` now is that we might want to save it
> for something better."
> **ljharb** (Jordan Harband): "There's virtually no value in providing a syntax shortcut for
> `Promise.all()` and `Promise.race()` — just type them out."

`domenic`'s objection is worth isolating: the rejected syntax reused `yield*`'s delegation sigil for
an operation (fan-out to `Promise.all`) that has nothing to do with delegation — the committee was
protecting `*`'s meaning as "hand this suspension point to another iterator" (§2.4) from being
overloaded with "run all of these concurrently," a distinction beni's own design would have to hold
if it ever considers a `!*` or similar sigil for parallel `Task`s.

### 3.4 "Why is this in terms of generator objects?" — the committee's own answer to finding 1

[Issue #49](https://github.com/tc39/proposal-async-await/issues/49) objected to the early spec text
literally reusing `%GeneratorPrototype%`, `next`, and `throw` for async functions: *"Async functions
and generators need to be separate, so that they can evolve divergently as necessary. There must be
no dependency upon generators in the definition of async functions."* The committee took this
seriously enough to give async functions their own internal machinery (`AsyncFunctionStart`,
`AsyncGeneratorYield`, distinct from the generator methods) rather than literally calling into
`%GeneratorPrototype%` — but as §2.2 shows, the two constructs still share `RunSuspendedContext` and
`RunCallerContext` underneath, because that pair *is* "suspend and resume an execution context," a
primitive both features need regardless of surface separation. The 2016 objection won the argument
about API surface and lost the argument about the underlying primitive.

### 3.5 Two proposals still in flight that a compiler emitting generators or async functions must reckon with

- **`using` / Explicit Resource Management** — Stage 4 as of the 2026-05 TC39 plenary
  (`tc39/proposals` `finished-proposals.md`; last presented 2026-05, targeted for ECMA-262 2027),
  championed by Ron Buckton. Its own README motivates the entire feature from generator `.return()`
  semantics (quoted in full in §2.4): *"ECMAScript Generator Functions and Async Generator Functions
  expose this pattern through the `return` method, as a means to explicitly evaluate `finally`
  blocks to ensure user-defined cleanup logic is preserved"* — `using` is sugar for exactly the
  `try { obj.next() } finally { obj.return() }` pattern generators already required by hand. A
  compiler emitting generators as a Task representation (§6) gets `using`'s cleanup guarantee **for
  the generator's own internals for free**, and can offer `using` in beni's surface syntax as sugar
  over the same `.return()`/`finally` machinery, with no new runtime concept.
- **AsyncContext** — Stage 2 (`tc39/proposals` active list, most recent notes 2026-05). Its own
  motivating example is a direct statement of what `await` costs beni-style implicit propagation:
  a value set via `try { shared = value; implicit(); } finally { shared = undefined; }` "is only
  available for the *synchronous execution* of the try-finally code" once `implicit` becomes `async`
  and awaits — *"After awaiting, the shared reference has been reset to `undefined`. We've lost
  access to our original value."* Generators get a harder, still-unresolved version of this: TC39's
  2025-09-23 meeting (`tc39/notes/meetings/2025-09/september-23.md`, "AsyncContext yield*", presented
  by Nicolò Ribaudo) reached consensus on changing how `AsyncContext` propagates through `yield*`
  specifically so that "the context of the caller `.next`" can be forwarded "to the inner iterator
  passed to `yield*`" — Mark Miller's clarifying exchange in that thread ("You are not actually doing
  anything that enables combining context?" / "No... You are reifying the other contexts so that you
  have both contexts in hand") is the committee explicitly declining to make context-combination a
  language feature, leaving it to userland helpers built on the new primitive. Any beni runtime that
  wants ambient state (a trace ID, a cancellation token) threaded through `Task` sequencing is
  re-deriving exactly this problem, one version behind where TC39 currently stands.
- **Iterator helpers** — already **Stage 4**, merged into ECMA-262 (`tc39/proposals`
  `finished-proposals.md`, targeted 2025) — no longer "in flight" but recent enough that it changes
  what "generators for free" means going forward: `.map`, `.filter`, `.take`, `.drop`, and friends
  are now methods on every iterator, including generator objects, without a library. A beni backend
  emitting generators for `Task` sequencing inherits this vocabulary on its emitted output at zero
  additional cost, the same way it inherits `for...of`.

---

## 4. Costs — ergonomic and structural

**Type-system demand: nothing.** Neither construct requires anything of a type checker — no class,
no trait, no HKT, no member lookup. This is the one place JavaScript's own answer to cross-cutting
question 4 is simpler than every other subject in this programme: the mechanism is pure runtime
protocol plus grammar, and a compiler targeting it pays nothing in its own type system, only in its
code-generation pass (§2.5, §6).

### 4.1 Function coloring — Nystrom's essay, applied precisely to this substrate

Bob Nystrom's "What Color is Your Function?" (2015-02-01) is the canonical statement of the cost:
async functions can only be called conveniently from other async functions, so the colour infects
every caller transitively, and `async`/`await` "doesn't eliminate the color distinction — it merely
makes calling colored functions less syntactically painful... you still have divided the world in
two." Applied to *generators specifically* (not just `async`/`await`), Nystrom notes they face "the
same constraints" and may be "isomorphic" to async-await — which finding 1 and §2.2 confirm at the
specification level, not just as an essayist's intuition. Only languages with real threads or
stackful coroutines (his examples: Go's goroutines) "completely and totally eliminated" the colour
distinction by decoupling concurrency from the function signature — which is precisely why beni,
targeting JavaScript, cannot have that option (`13-the-javascript-boundary.md`'s subject: the host
has no threads to fall back on).

### 4.2 Generators have their *own*, narrower colour, and it is enforced at parse time

Finding 2 is the sharpest cost item this report has: **a generator's colour does not stop at the
function signature the way an async function's does — it stops at the literal lexical body**, because
`ConciseBody` (an arrow function's body) is parameterized `~Yield` unconditionally
(`sec-arrow-function-definitions`, verified directly in the spec grammar). Concretely:

```js
function* g() {
  const helper = () => { yield 1; };  // SyntaxError, unconditionally — not a runtime check
}
```

is a parse-time error no matter what encloses the arrow. A named nested `function` has the same
restriction because it establishes its own (non-generator) function context. **This means any
higher-order function a generator-based effect system wants to write — a `mapM`, a `forM_`, anything
that takes a callback and expects the callback to suspend the caller — cannot be written by handing
the callback a plain function; the callback itself has to be a generator, driven by `yield*`, or the
suspension has to happen before the higher-order call, not inside it.** This is the mechanical reason
Effect-TS's `Effect.gen` requires `yield*` at every effectful call site instead of ordinary function
calls that happen to suspend (`effect-ts.md` documents the consequence; this report documents the
spec-level cause). It is also exactly the loop/fold trade report 00 identifies for block-structured
syntax (§2.6) reappearing one level down: a generator solves "bind inside a loop" (§2.6) but not
"bind inside an arbitrary callback," and the two are not the same hard case.

### 4.3 Debugging: the committee explicitly declined to own this, and the mismatch is measured

[Issue #93](https://github.com/tc39/proposal-async-await/issues/93), "Debugging async/await"
(2016-04), got this answer from the spec editor: *"This proposal has nothing normative to say about
the debugging experience... As far as I am aware there is nothing inherent in the async functions
proposal that would make debugging experience poor. If there are such issues, please raise them!"*
(bterlson). A commenter (`getify`) made the boundary explicit: *"this stuff is just not in the
purview of TC39... That kind of discussion might need to happen, but should be conducted
elsewhere."* The concrete complaint in the same thread — stepping over an `await` in a debugger
either desynchronises from the code the developer is reading or silently lets unrelated code run —
was never resolved in that repository; it moved to engine issue trackers, which is where V8's
`--async-stack-traces` work (§0.3) eventually answered *one* version of it (post-mortem stack
reconstruction) while leaving live single-step debugging exactly as murky as `inikulin`'s worked
example in that thread describes.

**Source maps for downlevelled generators/async: structurally correct, behaviourally wrong.**
`mozilla/source-map#221` (2016, closed) is a clean example: a developer reports that stepping past an
`await` in a Babel-compiled (`_asyncToGenerator`) function jumps the debugger to the *last* line of
the function instead of the next line, even though the source map, verified line-by-line in the
`sokra.github.io/source-map-visualization` tool by a maintainer (`fitzgen`), is correct. The
explanation in the thread is exactly §2.5's point turned into a cost: once `await`/`yield` is
downlevelled to a `.next()`-driven state machine, "the next line" in source terms is no longer "the
next instruction" in generated-code terms — control returns through the trampoline's `step` function
(§2.1) between every suspension, and a source map that maps *lines* correctly cannot make a debugger
understand that the *next statement it should show* is not the next line physically emitted. Native
generators and async functions do not have this problem because V8 suspends and resumes the same
execution context (§2.2) rather than routing through a userland trampoline between every await —
this is a debugging-experience argument for report `regenerator-and-tsc-downlevel.md`'s subject
being strictly worse than the native construct, orthogonal to any performance claim.

### 4.4 What newcomers get wrong: `return x` vs `return await x`

[Issue #92](https://github.com/tc39/proposal-async-await/issues/92) is the cleanest documented
newcomer mistake, reported by a TC39 delegate against their own proposal while implementing async
generators:

```js
async function a() { throw new Error("can i haz err"); }
async function b() {
  try { return a(); }               // returns the REJECTED promise from a() —
  catch (error) { console.log("caught"); }  // this catch never fires
}
```

*"`b` will return a rejected promise, but the catch clause in `b` will not get fired... I am
wondering if there is a potential here for confusion if users think that they can simply elide the
`await` when returning a promise and get the same exact control flow behavior."* This is the
mechanical reason ESLint's `no-return-await` rule special-cases `try` blocks (§2.3): outside a `try`,
`return await x` is pure overhead the 2019 fix made free; inside a `try`, it is the *only* way to
route a downstream rejection through the local `catch`, and eliding the `await` — which looks
identical in every other position — silently breaks error handling. No type system catches this;
it is a pure control-flow footgun specific to the promise/await interaction, with no generator
analogue (a generator's `.throw()` has no equivalent elision to get wrong).

### 4.5 Optimiser transparency

`async function` and `function*` are function *kinds* V8's own optimising compiler recognises and
compiles specially, not library values passed through generic call machinery — opaque to nothing at
the engine level. That is a claim about what V8 can see, not about beni's own optimiser, where an
emitted generator is exactly as opaque as report 00's Family-G entry says (`fast-compiler.md` §3.2
point 5: "opaque to §9.5's elimination and renaming"). Question 7 gets a different answer at each
layer, and both are correct at their own layer.

---

## 5. What users say

Evidence source is narrower than a search-backed survey would give (§8): the `tc39/proposal-async-
await` issue tracker itself (120 issues and PRs, all read), which is unusually good practitioner
evidence precisely because it was the *public* forum where JavaScript developers argued with the
committee in real time, 2014–2016, before the feature shipped.

**Wishes, counted.** Of the repository's ~110 non-administrative issues, **nine** are requests for
parallel-`await` sugar of some form: #106 ("parallelize consecutive awaits"), #102/#61/#103 (the
original `await*`), #81 ("`await one, two, three` instead of `await* […]`"), #76 (whether array
literals run awaits in parallel), #75 and #70 (both titled, independently, "Parallel await
proposal"), #46 ("Parallel awaits"), #25 ("`await*` and parallelism is not ideal"). Every one was
declined or superseded by "just write `Promise.all` explicitly" (§3.3 quotes the refusal directly).
**This is the strongest single "N of M" signal available**: roughly 8% of all traffic on the
proposal's tracker was the same request, made independently at least eight times over two years, and
the committee held the line every time.

**Complaints.** Two flavours, both first-party TC39 evidence rather than outside commentary:
structural (#88, "Why is async function needed at all?" — *"our code bases will just end up with a
soup of `async` in front of every lambda and function"* — a direct anticipation of the colouring
complaint Nystrom's essay would formalise a year later) and experiential (#93, debugging, §4.3).
Neither complaint changed the design; #88 was answered with silence in the tracker (no committee
response recorded), and #93's answer was a jurisdictional deflection (§4.3).

**Praise.** Indirect but consistent: every step in the lineage (§3.1) frames itself as an improvement
over the previous one on *exactly* the axis this programme cares about — task.js's README calls
generator-driven code "simple and beautiful" next to callback code; the 2013 proposal's own worked
example (`chainAnimationsPromise` → `chainAnimationsGenerator` → `chainAnimationsAsync`, §2.6) is a
three-step demonstration, written by the proposal's own author, of each successive layer removing
"boilerplate... beyond the semantic content of the code," ending with *"all the remaining boiler
plate is removed, leaving only the semantically meaningful code in the program text."* This is
praise for the *destination*, not evidence of maintainers-vs-evaluators divergence — the tracker does
not distinguish the two populations, and no source found separates them for this specific subject
(§8).

---

## 6. What it would take to do this in beni

**Beni cannot use `async function` as its `Task` primitive**, for the reason §1 states structurally:
calling an async function starts it running immediately, which is incompatible with `Task e a` being
an inert value a runtime chooses whether and when to run (`elm.md`, `roc-purity-inference.md`).
**Beni can use bare generators**, and Effect-TS is the existence proof that this works in production
(`effect-ts.md`) — but doing so inherits, unconditionally, everything this report establishes about
what a generator can and cannot do, independent of any runtime built on top:

- **Gets for free, from V8, no compiler work required:** suspension at an arbitrary expression
  position (§2.5) without a Roc-`!`-style dedicated pass; `finally`/`using`-compatible cleanup on
  early exit via `.return()` (§2.4, §3.5); the `yield*` delegation protocol, including its exact
  (and slightly leaky, §2.4) forwarding of `.throw()`/`.return()` to nested `Task`s, for whatever
  beni's equivalent of composing sub-tasks looks like; the loop hard case (§2.6) solved outright,
  where every block-structured syntactic rewrite in report 15's family cannot solve it at all.
- **Does not get, no matter how good the compiler is:** the two async-function-only wins of finding
  3 — zero-cost stack traces and the 2019 microtask fix — because both are specified and implemented
  on `Await`, not on the generic suspend/resume pair generators share with async functions (§2.2,
  §2.3). A beni runtime driving generators with its own `step`-style loop (§2.1) is, stack-trace-wise,
  in exactly `co`'s position, not native `async`/`await`'s — every resume happens through the driver's
  own call frame, and V8 has no reason to know that frame represents "the code will continue here
  when this Task settles" the way it knows an `async function`'s own frame does.
- **Costs the compiler exactly finding 2's colour, one level down:** any beni-emitted helper — a
  `List.map`-equivalent callback, a closure captured inside a branch — that needs to suspend the
  *outer* Task cannot be emitted as a plain JavaScript function or arrow; it must itself be a
  generator, threaded through with `yield*`, exactly as `fast-compiler.md` §3.2's option-B/C table
  already anticipates ("B: Emit generators — yes [to loops and branches]... opaque to §9.5's
  elimination and renaming"). This is not a new discovery this report makes; it is this report's
  confirmation, at the specification level, that the constraint is real and is not an artifact of
  how Effect-TS happens to be built — it is inherent to what `yield` is allowed to cross (§4.2).
- **What the people who built it would warn beni's compiler team about:** the committee itself, twice
  — once refusing to give `await*`/parallel-await its own syntax because "just type it out" (§3.3),
  and once, on the still-open `AsyncContext`/`yield*` question, declining to let the language combine
  two propagated contexts automatically, leaving it to userland "helpers" that "reify" both contexts
  and let the caller choose (§3.5). Both are the same warning in different clothes: **don't let the
  suspension primitive silently pick a policy (which promise to await first; which ambient context
  wins) that the user cannot see or override in the source** — exactly the silent-wrong-answer
  failure mode `fast-compiler.md`'s `?`-on-`Task` section already flags for beni's own `?` operator.

---

## 7. Ranked summary

1. **`async`/`await` is generators plus a hand-written scheduler, by the proposal's own admission,
   and the modern spec still shares one suspend/resume primitive between the two.** (documented —
   §2.1, §2.2, primary source quoted verbatim)
2. **A generator's suspension point cannot cross into a nested function, enforced by the grammar at
   parse time, not by a runtime check.** (documented — ECMA-262 `ConciseBody` grammar, verified
   directly against the spec source)
3. **Native `async`/`await` gets zero-cost async stack traces and the one-microtick `await`
   optimisation; bare, library-driven generators structurally cannot, because both rely on the
   engine recognising `await`'s resume site as its own suspend site.** (documented — V8 blog,
   `tc39/ecma262#1250`)
4. **The committee refused parallel-`await` sugar independently requested at least eight times over
   two years, and refused automatic context-combination across `yield*` as recently as 2025.**
   (documented — proposal issue tracker counts; 2025-09-23 TC39 notes)
5. **`using`, at Stage 4 for ECMA-262 2027, is sugar for a pattern generators have required by hand
   since ES2015 — `try { .next() } finally { .return() }` — so a beni backend emitting generators
   inherits `using`'s guarantee on its own internals for free, before beni ever exposes `using` in
   its own surface syntax.** (documented — proposal README quoted verbatim)
6. **Downlevelled generators/async break debugger single-stepping even when the source map is
   verified correct, because the trampoline between suspensions has no line to attribute "resume
   here" to.** (documented — `mozilla/source-map#221`, maintainer-verified)
7. **`return x` vs `return await x` inside a `try` block is a live, reported footgun with no
   type-system defence, resolved only by an ESLint rule that special-cases exactly the one position
   where eliding `await` is wrong.** (documented — proposal issue #92, ESLint rule text)
8. **Neither construct demands anything of a type checker — the entire cost of this substrate is
   paid in the code-generation pass and the runtime, never in inference.** (inferred, from reading
   the full specification: no clause in either feature's definition mentions a type, class, or trait)
9. **Per-bind and per-call allocation cost, and whether V8 elides the generator-object allocation in
   any case, remain unmeasured — the landscape brief already flagged this and this report did not
   close it, by the programme owner's own scoping instruction.** (unverified — explicitly out of
   scope, not merely unfound)
10. **Whether Chrome DevTools' *current* (2026) generator-stepping experience still matches the 2016
    complaints in issue #93 could not be checked against a live tool.** (unverified — §8)

---

## 8. What could not be resolved

- **The exact bytecode-level register-spill mechanism V8's Ignition interpreter uses to preserve a
  suspended generator's locals** — the landscape brief explicitly asked for this. The specification
  gives only the architecture-neutral abstraction (`RunSuspendedContext`/`RunCallerContext` suspend
  and later exactly resume "the associated execution context," §2.2) and says nothing about how V8
  represents that context's live registers between suspensions. No V8 design document describing
  this at the implementation level was found within the available budget; `v8.dev/blog/fast-async`
  and `v8.dev/blog/ignition-interpreter` were both read directly and neither discusses it. This is a
  genuine gap, not a scoping decision — the brief asked for it and it was not found.
- **Whether V8 currently elides the per-call generator-object allocation in any case.** The landscape
  brief already recorded this as "no verified number found so far" before this report began; nothing
  found here closes it, and per the programme owner's ergonomics-only instruction this report did not
  pursue it further as a performance question even where it shaded into one.
- **Current (2026) Chrome DevTools behaviour for stepping through native (non-downlevelled)
  generators and async functions**, as distinct from the 2016-era complaints in issue #93 and the
  2016 source-map thread (§4.3, §4.4). No live DevTools documentation or changelog was fetched; both
  primary sources here predate V8 7.2/7.3's stack-trace work by roughly two years, and it is possible
  the single-stepping experience has since improved without this report's sources reflecting it.
- **A search-backed survey of practitioner sentiment outside the TC39 tracker itself** — Stack
  Overflow, Reddit, or blog-post commentary on living with `async`/`await` day to day, as opposed to
  arguing about its design before it shipped. This session's WebSearch budget was exhausted globally
  before this report began (a session-wide quota shared across the programme's parallel research
  agents), so §5's evidence is entirely first-party TC39 material, reached by direct fetch and the
  GitHub API rather than by query-based discovery. This is very good evidence for the *design*
  history and a narrower sample than ideal for "what maintainers of large codebases say" as opposed
  to "what the people arguing about the spec said" — the brief's distinction in §5 could not be drawn
  because the tracker does not separate the two populations and no outside source was reached to
  supply the contrast.
- **Whether the "Deferred Functions" and "Async Functions" ES-wiki strawmen had any TC39 meeting
  minutes recording committee discussion of them** — both pages were read in full via the Wayback
  Machine, but wiki.ecmascript.org itself has been offline for years and no contemporaneous TC39
  meeting notes from 2011 (the committee did not begin publishing detailed public notes until later)
  were locatable to corroborate how seriously either strawman was discussed in the room versus being
  one delegate's individual proposal.
