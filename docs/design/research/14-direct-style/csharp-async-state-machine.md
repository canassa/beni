# C# 5 `async`/`await`: the compiler's state-machine rewrite, and LINQ as an earlier comprehension

**Commissioned by** the direct-style effect-sequencing research programme's landscape document
(`00-landscape.md` §2, family F, Tier 1), which names this report as covering "the design every
later `async` copied, documented by its designers (Lippert 2010, Toub 2023) with the rewriter
readable in Roslyn," plus LINQ query syntax as "the same compiler's family-C comprehension." Family
F — compiler state-machine transforms — is the branch of the mechanism space that transforms the
*whole function body* into a resumable object, rather than only the rest of a block (families A–D);
it is the only family in the twelve that lets a bind appear inside a loop with no fold and inside a
branch with no new block, which is exactly the two properties `fast-compiler.md` §3.2 leaves open
for beni ("Flat effect syntax — OPEN"). This report treats C# as the reference implementation of
that transform, and LINQ as evidence that the same compiler independently discovered the other
half of report 15's finding — that member-resolved, pattern-based binding needs no type-class
machinery — three years before `await` shipped.

**Sources.** Read directly: three of Eric Lippert's 2010 "Asynchrony in C# 5" blog posts, archived at
`learn.microsoft.com/en-us/archive/blogs/ericlippert/` — Part One (2010-10-28, the PDC announcement),
Part Two "Whence await?" (2010-10-29, the `GetAwaiter`/`BeginAwait`/`EndAwait` pattern and its LINQ
analogy), and Part Six "Whither async?" (2010-11-11, why the `async` modifier is required); Stephen
Toub's "How Async/Await Really Works in C#" (devblogs.microsoft.com/dotnet, 2023-03-16); Roslyn
source at `github.com/dotnet/roslyn` — the `AsyncRewriter/` directory listing, and the full or
partial text of `AsyncMethodToStateMachineRewriter.cs` (695 lines), `AsyncExceptionHandlerRewriter.cs`,
and `Lowering/SpillSequenceSpiller.cs` (1,541 lines); Microsoft Learn's shorter conceptual pages —
the `await` operator reference, the `lock` statement reference, "Asynchronous programming
scenarios" (the async-void and LINQ-deferred-execution warnings), "Query expression basics," and
"The history of C#" (version-by-version feature lists); the C# 8 async-streams proposal on
`dotnet/csharplang`; and the `StackTraceHiddenAttribute` API reference. **This session's shared
WebSearch budget (200 calls, pooled across every parallel research agent in this programme) was
already exhausted before this report could issue a single search**, so every source above was
reached by direct WebFetch to a known or guessed URL, with several guesses (a Torgersen "New
Features in C#6" post, an InfoQ C#6 preview article, a specific Roslyn issue number) 404-ing and
simply abandoned. A second, unrelated limitation: the WebFetch tool truncates very large single-file
pages — the C# language specification's `expressions.md`, `classes.md`, and `statements.md`, both
as rendered by Microsoft Learn and as raw Markdown from `dotnet/csharpstandard` — before reaching
the sections this report most wanted (§12.9.9 Await expressions, §15.15 Async functions, §12.20
Query expressions), regardless of anchor or prompt. §8 records what this cost and how it was
compensated. Ayende's "The cost of the async state machine" post was read and found to contain only
performance benchmarking, out of scope per the brief; it contributes nothing here. All web sources
accessed **2026-09-14**.

---

## 0. The three findings, up front

**1. The awaitable pattern and the LINQ query pattern are the same design trick, and Lippert says so
explicitly while inventing the former.** Explaining what makes an expression awaitable, Lippert
writes: *"we're going to use the same strategy we used for LINQ. In LINQ if you say `from c in
customers where c.City == "London" …` then that gets translated into `customers.Where(c=>c.City=="London")`
… and overload resolution tries to find the best possible `Where` method by checking to see if
`customers` implements such a method, or, if not, by going to extension methods. The
`GetAwaiter`/`BeginAwait`/`EndAwait` pattern will be the same; we'll just do overload resolution on
the transformed expression and see what it comes up with. If we need to go to extension methods, we
will."* (Lippert, "Asynchronous Programming in C# 5.0 part two: Whence await?", 2010-10-29). Neither
mechanism needs an interface; both are resolved by ordinary C# member lookup on the type of an
expression, extension methods included. Report 15's finding that OCaml, Gleam, Koka and Roc
independently invented one design is family C/D's answer to "no type classes"; C# shows the same
answer, invented earlier, for two unrelated features by the same team.

**2. Every place `await` may not appear is a place where the state-machine rewrite collides with a
CLR or runtime invariant, not an arbitrary syntax restriction — and one of those collisions was
fixed later while another has stood since 2012.** `await` is illegal inside a `lock` statement body
because `Monitor.Exit` must be called by the same thread that called `Monitor.Enter`, and a
suspended `async` method can resume on a different thread; the C# 5 restriction on `await` inside
`catch`/`finally` existed because the CLR forbids branching into or out of the middle of an
exception-handler protected region, which is exactly what resuming a `MoveNext` state machine via a
`switch` would otherwise have to do — and Roslyn's `AsyncExceptionHandlerRewriter.cs` exists purely
to rewrite try/catch/finally bodies containing `await` into ordinary code outside any protected
region *before* the state-machine rewriter runs, which is what let C# 6 lift the restriction in
2015 while `lock` has never been lifted, because `lock`'s constraint is about a *thread*, not IL
shape.

**3. Requiring the `async` keyword was argued in public as a bundle of tooling and backward
-compatibility trade-offs, not a technical necessity — and the same 2010 comment thread already
contains the answer to beni's "bind inside a loop" question, four years before Roslyn shipped.**
Lippert lists eight separate design principles weighed against each other (avoiding breaking
changes, consistency with `yield`, lambda type inference, tooling diagnostics such as detecting a
forgotten `await`) and concludes *"That's a whole lot of pros and cons… I think that's a reasonable
choice"* (Part Six, 2010-11-11) rather than claiming one clean derivation. In the same thread, a
reader named Cory asks why the compiler doesn't split an async method into several smaller methods
chained with `Task.ContinueWith` instead of one big state machine; a reader named Jon replies:
*"splitting it into multiple methods might work for methods with simple control flow, but how would
[it] cope with a loop? … it's hard to see how that could cleanly be split into separate methods. You
basically need to be able to re-enter the code at any point — and a state machine is quite possibly
the simplest way of modelling that."* This is the whole of family F's expressiveness argument over
families A–D, stated by a commenter before the compiler existed.

---

## 1. The effect model

`Task` and `Task<T>` are ordinary values, interpreted by the .NET thread pool and synchronization
context — the same effects-as-values shape as Elm's `Task`. What C# adds is not a different effect
model but a different *compilation strategy* for sequencing them: an `async` method's body is
written exactly as if it executed synchronously to completion, and the compiler alone is
responsible for turning every suspension point into a place the method can be re-entered. Lippert
frames the insight that makes `Task` the right vehicle rather than a bespoke future type: *"asynchrony
does not require parallelism, but parallelism does require asynchrony… There is no inherent
parallelism in `Task`"* (Part Two) — the type was already general enough.

C# does **not** distinguish effectful from pure code in the type system beyond a method modifier
that is invisible to the type itself: `async Task<int> Foo()` and a hand-written `Task<int> Foo()`
have the identical signature, and Lippert notes the caller-facing consequence directly: *"The
caller cares not a bit whether a given method is marked as `async` or not"* (Part Six). This is the
opposite of a row-typed or capability-typed effect system (family H): there is no effect that
propagates through inference, no polymorphism over "may await," and no way for a type error to
say "this function performs an effect it didn't declare" — `async` only changes what is legal
*inside* the method body (an `await` expression) and how the *implementation* is compiled, never
what the caller can observe statically. "Sequencing two effects" here means exactly what it means in
synchronous code — two statements, one after another — because the compiler makes the entire
enclosing function resumable, not just a continuation captured at one bind site. That is the
structural fact every other section returns to.

---

## 2. The mechanism

**What the user writes.** An ordinary-looking method, lambda, anonymous method, or (C# 7.1+) `Main`
marked with the `async` contextual keyword, containing `await` expressions wherever an expression
may otherwise appear.

**What it compiles to, precisely.** Toub's walkthrough of a method `CopyStreamToStreamAsync`
(devblogs, 2023-03-16) shows the generated struct `<CopyStreamToStreamAsync>d__0` implementing
`IAsyncStateMachine`, with fields:

```csharp
int <>1__state;                       // which suspension point to resume at
AsyncTaskMethodBuilder <>t__builder;   // owns the returned Task and drives completion
Stream source, destination;           // hoisted parameters
byte[] <buffer>5__2;                  // hoisted local, live across an await
TaskAwaiter<int> <>u__1, <>u__2;      // hoisted awaiters, one per pending suspension
```

and a `MoveNext` method that is a `switch` over `<>1__state` guarded by a single `try`/`catch`:
each `await` becomes a check of `awaiter.IsCompleted`; if false, the state is recorded, the awaiter
is stashed in its hoisted field, `builder.AwaitUnsafeOnCompleted(ref awaiter, ref this)` registers
the resumption, and the method **returns**, giving control back to the caller — Lippert's original
framing of the semantics, unchanged since 2010: *"Whenever a task is 'awaited', the remainder of the
current method is signed up as a continuation of the task, and then control immediately returns to
the caller"* (Part One). The original method name becomes a thin wrapper that constructs the state
machine, copies in the parameters, sets state `-1`, and calls `builder.Start(ref stateMachine)`,
returning `builder.Task` immediately. Any unhandled exception anywhere in the body is caught by
the single outer `catch`, which sets the state to finished and calls `builder.SetException` — Toub:
*"any exception that goes unhandled inside of an async method, no matter where it is in the method
and no matter whether the method has yielded, will end up"* completing the returned task as faulted.

The actual Roslyn pipeline that produces this, read from source:

| Pass | File (`Lowering/`) | Job |
|---|---|---|
| 1 | `AsyncRewriter/AsyncExceptionHandlerRewriter.cs` | Where `await` appears inside a `catch` or `finally`, rewrites the handler into a "surrogate" outside any CLR protected region — storing the pending exception in a local, using `goto`/labels to run the real handler code as ordinary statements, then reconstructing the throw/branch afterward — because the CLR does not allow resuming execution by branching into the middle of an exception-handler region. |
| 2 | `SpillSequenceSpiller.cs` (1,541 lines) | Where `await` appears in the middle of a larger expression (an argument, an operand of `+`, a conditional), walks the bound tree and "spills" everything evaluated so far into a `BoundSpillSequenceBuilder` of synthesized locals and statements, so the `await` becomes a statement boundary and the rest of the original expression resumes reading from temps afterward. |
| 3 | `AsyncRewriter/AsyncMethodToStateMachineRewriter.cs` (695 lines) | "Produces a `MoveNext()` method for an async method." Rewrites each `await` (`VisitAwaitExpression`) into the `IsCompleted`/`OnCompleted`/`GetResult` state-transition shape above; rewrites `return` (`VisitReturnStatement`) into a store to `_exprRetValue` and a branch to `_exprReturnLabel`; generates the single outer exception handler (`generateExceptionHandling`) and the final `builder.SetResult(...)` call (`GenerateSetResultCall`). |

**What the type system must know.** Nothing beyond ordinary member lookup. An expression `e` is
awaitable if `e.GetAwaiter()` resolves (by normal overload resolution, extension methods included)
to something exposing `bool IsCompleted`, `void OnCompleted(Action)` (via `INotifyCompletion`, or
`UnsafeOnCompleted` via `ICriticalNotifyCompletion`), and a `GetResult()` method — no interface
implementation is required of the *awaited* expression itself, the exact analogy Lippert draws to
LINQ's `Where`/`Select` resolution (§0.1). `Task`/`Task<T>` were given this pattern as ordinary
methods; anything else — the CTP's early `IAsyncResult`, an `IObservable<T>` via Rx's `GetAwaiter`
extension method mentioned in the Part One comments, or a custom "task-like" type carrying an
`[AsyncMethodBuilder]` attribute for the return position — works by the same lookup, with no change
to the compiler's type-checking rules. Async methods additionally cannot have `ref`/`out` parameters
and cannot simultaneously be iterators in the pre-C#8 sense (C# 8's async streams add that
combination as its own state machine, below).

**Where the marker may appear.** Because the whole method body is rewritten, `await` may appear
**anywhere an expression may appear** inside an `async` body — inside `if`/`else`, inside `for`,
`foreach`, `while`, `switch`, as a method argument, as an operand of any operator, in the middle of
an object-initializer — which the spilling pass above exists specifically to make legal. The
documented exceptions, quoted from Microsoft's `await` operator reference (accessed 2026-09-14):

> "you can't use the `await` operator in the body of a synchronous local function, inside the block
> of a `lock` statement, and in an `unsafe` context."

and, on `lock` specifically, from the `lock` statement reference: *"You can't use the `await`
expression in the body of a `lock` statement."* `catch`/`finally` are the one restriction that moved:

| Restriction | C# 5 (2012) | C# 6 (2015) onward |
|---|---|---|
| `await` in `catch`/`finally` | illegal | legal — new `AsyncExceptionHandlerRewriter` pass added |
| `await` in `lock` body | illegal | still illegal (thread-affinity of `Monitor.Exit`, not an IL-shape problem) |
| `await` in `unsafe` context | illegal | still illegal |
| `await` in a synchronous local function | illegal | still illegal (that function isn't itself a state machine) |

"The history of C#" (Microsoft Learn, accessed 2026-09-14) lists "Await in catch/finally blocks"
among C# 6's 2015-07 features, alongside the note that C# 5 (2012) shipped with "Nearly all of the
effort for that version" spent on `async`/`await` alone.

**The hard cases, in C#:**

*Bind inside a branch — no new block, value usable after.* This is where C# is strictly better than
every family-A–D mechanism in report 15: because the bound value is a local variable in the state
machine, not a lambda parameter, using it after the branch costs nothing syntactically:

```csharp
async Task<Summary> FetchSummaryAsync()
{
    var user  = await GetUserAsync();
    var perms = await GetPermissionsAsync(user);
    if (perms.IsAdmin)
    {
        var log = await GetAuditLogAsync(user);
        return new Summary(user, perms, log);
    }
    return new Summary(user, perms, null);
}
```

This is the shared brief's `fetchSummary` example, and it reads exactly like the Effect-TS
generator version, with none of Gleam's `use`-block nesting at the branch.

*Bind inside a loop — no fold.* Family D (Gleam `use`, Roc backpassing) cannot express this at all;
family F can, because the whole function, loop included, is one resumable unit:

```csharp
async Task ProcessAllAsync(IEnumerable<Url> urls)
{
    Summary previous = null;
    foreach (var url in urls)
    {
        var summary = await FetchSummaryAsync(url);
        if (previous != null)
            await SaveAsync(previous);
        previous = summary;
    }
    if (previous != null) await SaveAsync(previous);
}
```

This is a direct descendant of Lippert's own PDC-announcement example (Part One, 2010-10-28):
`for(int i = 0; i < urls.Count; ++i) { var document = await FetchAsync(urls[i]); if (archive !=
null) await archive; archive = ArchiveAsync(document); }`.

*Early return.* `return` in the middle of an async method is legal anywhere and is rewritten
(`VisitReturnStatement`) to a store-and-branch to a single exit point that calls `builder.SetResult`;
any enclosing `try`/`finally` runs exactly as it would in synchronous code, because `finally` blocks
are still ordinary CLR protected regions in the *lowered* MoveNext body once `AsyncExceptionHandlerRewriter`
has removed any `await` from directly inside them.

*Pattern matching on the bound value.* No restriction — the bound value is an ordinary local; C#'s
pattern-matching operators (`is`, `switch` expressions) apply to it exactly as to any variable.

*Mixing two effect types (e.g. a `Result`-shaped type inside a `Task`).* C# has no built-in `Result`,
so the idiom is `Task<TResult>` where `TResult` is a user discriminated shape (an OO hierarchy, a
tagged union library, or C#'s pattern-matching over sealed record hierarchies); `await` only ever
unwraps the outer `Task` layer, and the inner value is matched with ordinary C# afterward — the two
layers do not interact, which is the same "for free" composability report 15 attributes to any
family-F/family-D design that keeps the marker orthogonal to the value's own type.

*Error propagation.* An unhandled exception inside the method body faults the returned `Task`; a
caller's `await` on that faulted task rethrows it (via `ExceptionDispatchInfo`, preserving the
original stack information) — from the `await` operator reference: *"if `t` throws an exception,
`await t` rethrows the exception."*

**Query expressions as the same compiler's family-C comprehension.** Introduced in C# 3.0 (2007),
three years before `await`, query syntax desugars purely syntactically into calls to `Where`,
`Select`, `SelectMany`, `Join`, `GroupJoin`, `OrderBy`/`ThenBy`, and `GroupBy`, resolved by the same
ordinary overload resolution (member or extension method) as any other call — the exact analogy
Lippert draws on when inventing `GetAwaiter` (§0.1). From Microsoft's "Query expression basics"
(accessed 2026-09-14), the shared-brief-style example of a bind inside a loop is literally LINQ's
own textbook case for a second `from` clause — "Use more `from` clauses when each element in the
source sequence is itself a collection":

```csharp
IEnumerable<City> cityQuery =
    from country in countries
    from city in country.Cities
    where city.Population > 10000
    select city;
```

which desugars to nested `SelectMany`. A `let` clause is the query-syntax analogue of a
non-monadic intermediate binding — *"Use the `let` clause to store the result of an expression…
in a new range variable"* — implemented by introducing an anonymous type (a "transparent
identifier") that carries both the original range variable and the new one forward so later clauses
can see both. This is family C exactly as report 15's table describes it (`for`/`Select`/`flatMap`
resolved by member lookup, no HKT), and it is C#'s earlier, narrower proof that the trick works: a
query expression's `Select`/`Where`/`SelectMany` are ordinary methods that any type can define —
`IEnumerable<T>` and `IQueryable<T>` are conventions, not requirements the *compiler* checks for.

---

## 3. History and decisions

**C# 3.0 (November 2007).** Query expressions, lambda expressions, expression trees, extension
methods, and anonymous types shipped together, deliberately, as LINQ's foundation — "The history
of C#" calls query expressions "this version's killer feature" and treats the surrounding features
as "the foundation upon which LINQ is constructed."

**C# 5.0 (August 2012), announced at PDC 2010-10-28.** Lippert's Part One frames the whole feature
as the same pattern C# had already used three times — iterators (2.0), anonymous methods (2.0),
query comprehensions (3.0) — of "let the compiler generate all that stuff for you": *"The designers
of C# 5.0 realized that writing asynchronous code is painful… This shall not stand."* The early CTP
protocol was `GetAwaiter`/`BeginAwait`/`EndAwait` (Part Two, 2010-10-29) rather than the
`IsCompleted`/`OnCompleted`/`GetResult` split that shipped; this report could not source a primary
account of exactly when or why the CTP protocol was refined into the final one (§8). The `async`
keyword itself was argued at length in Part Six (§0.3): eliminating ambiguity with existing
identifiers named `await`, making lambda return-type inference stable regardless of whether an
`await` is commented out, and enabling tooling diagnostics for a forgotten `await` or an
unnecessary `async` were all cited as reasons, alongside *"the language should be amenable to rich
tools"* — an argument later borne out by Roslyn (compiler-as-a-service) shipping in the very next
version.

**C# 6.0 (July 2015), shipped with Roslyn.** "Await in catch/finally blocks" is listed among C# 6's
features in "The history of C#." The mechanism — `AsyncExceptionHandlerRewriter.cs` restructuring
`await`-containing handlers into code outside any CLR protected region before the state-machine
rewrite runs — is a compiler capability, not a CLR one; the CLR's protected-region rule did not
change, C#'s lowering got smarter about working around it.

**C# 7.x.** Return types generalized beyond `Task`/`Task<T>`/`void` to any "task-like" type
(`ValueTask<T>` included) via an `[AsyncMethodBuilder]` attribute.

**C# 8.0 (September 2019).** Async streams (`await foreach` over `IAsyncEnumerable<T>`) filled the
gap the csharplang proposal states directly: *"C# has support for iterator methods and async
methods, but no support for a method that is both an iterator and an async method."* The mechanism
is a second, sibling state-machine rewriter (`AsyncIteratorMethodToStateMachineRewriter.cs`,
present in the same Roslyn directory) rather than a reuse of either the plain-iterator or
plain-async rewriter — confirming that "await inside a loop that also yields" needed its own
compiler support. The pattern is again member-resolved: the spec's `await foreach` translation
requires a `GetAsyncEnumerator` method returning something with `MoveNextAsync`/`Current`,
mirroring `foreach`'s own long-standing pattern-based lookup.

**Nothing in this family was later withdrawn.** Unlike Roc's backpassing (family D, removed
2025-01) or `?`'s original `From::from` conversion rule in Rust, C#'s async design has only grown
new task-like return types and new statement forms (`await using`, `await foreach`) on the same
`GetAwaiter`/`IsCompleted`/`OnCompleted`/`GetResult` foundation fixed in 2012 — the closest thing
to a regret this report found is the `lock`/`await` restriction, which nobody has proposed lifting,
because its cause (thread affinity of `Monitor.Exit`) is a runtime fact, not a compiler limitation
like the one `catch`/`finally` had.

---

## 4. Costs — ergonomic and structural, not performance

**What the mechanism does to the user's code.** Nothing has to be restructured for a bind inside a
branch or a loop — §2's hard cases show ordinary control flow works unmodified, which is the
entire point of a whole-function transform over a rest-of-block one. The costs that remain are
about the four *excluded* positions (`lock`, `unsafe`, sync local functions, and — until 2015 —
`catch`/`finally`): a user who reaches for `await` in one of them gets a compile-time error, not a
runtime failure or a silently wrong result, which is strictly better than beni's own finding in
report 15 about `?`'s silent ordered-speculative-unification failure mode.

**Error messages and source locations.** Every restriction in the table above is caught statically,
at the position of the illegal `await`, before codegen. This report could not independently verify
the exact wording of the compiler's diagnostics (e.g. the "call is not awaited" warning, commonly
known as CS4014) against a primary source this session (§8), but the restriction list itself is
confirmed from Microsoft's own reference pages, not inferred.

**Tooling.** The generated `MoveNext` method and its enclosing state-machine type are compiler
artifacts that would otherwise pollute a debugger's call stack and an exception's `StackTrace`
string with meaningless synthesized frames. .NET's answer is `System.Diagnostics.StackTraceHiddenAttribute`
(added to `System.Private.CoreLib`'s async infrastructure types), whose documented purpose is that
"types and methods attributed with `StackTraceHidden` will be omitted from the stack trace text
shown in `StackTrace.ToString()` and `Exception.StackTrace`" — a runtime-library answer to a
compiler-generated-code problem, added years after `async`/`await` itself shipped, which is itself
evidence that the debugging story was not solved on day one. Visual Studio separately maintains a
dedicated "Tasks"/async-call-stack view that reconstructs the logical await chain, because the raw
CLR stack at a suspension point is just a thread-pool worker with no caller frames at all — the
physical stack and the logical one diverge completely, and tooling has to bridge that gap
explicitly rather than by walking frames.

**Compiler pipeline.** This is a **lowering-only** feature: nothing about `await` or `async` changes
binding or type inference (per §2, `GetAwaiter`/`GetResult` are resolved by ordinary overload
resolution during normal binding, exactly as any method call would be). The actual work — three
Roslyn passes (`AsyncExceptionHandlerRewriter`, `SpillSequenceSpiller`, `AsyncMethodToStateMachineRewriter`,
plus a fourth, `AsyncIteratorMethodToStateMachineRewriter`, for C# 8's async iterators) — sits
entirely between binding and code generation. Measured only in lines available from GitHub's file
listing (not a benchmark; this is a size fact, not a performance one): `AsyncMethodToStateMachineRewriter.cs`
is 695 lines, `SpillSequenceSpiller.cs` is 1,541 lines — considerably larger than report 15's 44
-line family-D backpassing desugarer, and closer in scale to Roc's 1,046-line `suffixed.rs` for its
arbitrary-position `!` marker, because both are paying for "the marker may appear anywhere an
expression may."

**What newcomers get wrong**, each documented directly by Microsoft's own "Asynchronous programming
scenarios" guidance rather than inferred:

- **`async void`.** *"Exceptions thrown in an `async void` method can't be caught outside of that
  method"*, *"`async void` methods are difficult to test"*, and *"`async void` methods can cause
  negative side effects if the caller isn't expecting them to be asynchronous."* The guidance
  restricts legitimate use to event handlers, where the signature is fixed by the event's delegate
  type.
- **Blocking on async code.** *"Synchronous blocking on asynchronous operations can lead to
  deadlocks and should be avoided whenever possible"* — `.Result`/`.Wait()` wrap exceptions in
  `AggregateException` and carry "higher deadlock risk" versus `await` or `GetAwaiter().GetResult()`.
- **Mixing async lambdas with LINQ.** *"LINQ uses deferred (or lazy) execution, which means the
  code can execute at an unexpected time. The introduction of blocking tasks into this scenario can
  easily result in a deadlock"* — the same guidance recommends forcing eager evaluation with
  `.ToList()`/`.ToArray()` before applying `Task.WhenAll`/`WhenAny`, precisely because LINQ's own
  family-C laziness and `async`'s family-F eagerness-once-started don't compose for free.

**Optimiser transparency (question 7).** The state machine is an ordinary heap (or, when the method
never actually suspends, stack-resident struct) object dispatched through `IAsyncStateMachine.MoveNext()`
— the JIT can inline *within* `MoveNext`, but no source read this session confirms or denies
cross-boundary inlining of an `async` method's body into its caller; flagged **(unverified)**.

**Question 6 (per-bind and per-call cost) is out of scope** by the shared brief's hard rule against
benchmarks; the one source checked that discusses it (ayende's "cost of the async state machine")
is pure benchmarking and is not cited beyond its title.

---

## 5. What users say

The material read this session skews toward the design team's own writing and Microsoft's reference
documentation rather than independent practitioner forums, because the shared WebSearch budget was
exhausted before this report could run any searches of its own (§8) — so this section is thinner
than the brief's "count where you can" standard asks for, and says so rather than fabricating counts.

**Praise**, from what is verifiable: the landscape document's own framing — "the design every later
`async` copied" — is itself a form of practitioner verdict, since Kotlin, Swift, Dart, Rust,
JavaScript, ClojureScript, and F# `task { }` all adopted variations of the same whole-function
state-machine strategy after C# shipped it (`00-landscape.md` §1, family F). Within the material
read directly, the 2010 comment thread on Lippert's own posts is uniformly enthusiastic about the
ergonomic result (§0.3's "This is.... amazing. I think it might even be more beneficial than Linq"
is representative), though blog comments on an announcement post are a weak signal for
"practitioners maintaining large codebases," which the brief asks to be distinguished from people
evaluating a new feature — this thread is entirely the latter.

**Complaints**, documented rather than counted: Microsoft's own "Review considerations for
asynchronous programming" section (§4) is, in effect, a maintained list of mistakes the design team
expects experienced .NET developers to keep making a decade after ship — `async void`, blocking on
`Task.Result`, and deferred-execution/async interaction in LINQ. That Microsoft maintains this list
as a living document, updated as recently as 2025-03-12 per its page metadata, is evidence these are
recurring, not historical, complaints — a documented signal, not a counted one.

**Wishes**: none independently found beyond the 2010 comment thread's requests (a built-in
`IAsyncEnumerable<T>`, eventually shipped in C# 8; awaiting an array of tasks directly instead of
via `Task.WhenAll`, not adopted as written). No source discusses what large C# codebases wish were
different about `async`/`await` specifically, as opposed to .NET more broadly.

---

## 6. What it would take to do this in beni

**The type-system cost is close to zero, the headline transferable result.** Nothing about
`await`'s resolution touches HM inference: `GetAwaiter`/`IsCompleted`/`OnCompleted`/`GetResult` are
resolved by C#'s ordinary member lookup, the same mechanism Lippert reused from LINQ's `Where`/`Select`.
If beni fixed one canonical shape for its own `Task e a`, the analogous lookup is a name in scope,
cheaper even than C#'s overload resolution and squarely inside what `fast-compiler.md` §3.1 already
allows (member access without typeclasses) — the strongest point of contact with report 15's finding
that every affordable-without-typeclasses design converges on one trick; C# spent it on `await`
independently of OCaml, Gleam, Koka, and Roc spending it on bind syntax.

**The compiler-pipeline cost is real and is exactly what `fast-compiler.md`'s option C already
names.** Roslyn's three-pass, ~2,500-line subsystem (`AsyncExceptionHandlerRewriter`,
`SpillSequenceSpiller`, `AsyncMethodToStateMachineRewriter`) is the concrete shape of the work: a
pass that walks every expression and, on hitting a suspension point mid-expression, hoists
everything evaluated so far into synthesized locals — exactly what beni would need the moment it
allows `await`/`?`-for-`Task` anywhere an expression may appear, not just at `let` position. Report
15 §0.3 already predicted this cost from Roc's 1,046-line `suffixed.rs`; C#'s larger
`SpillSequenceSpiller` is an independent confirmation of the same shape of problem in a second
mainstream, shipped compiler. A second pass is needed purely to reconcile suspension with structured
exception handling, because "resume in the middle of a protected region" is a hard boundary in the
CLR and — since JS's own `try`/`catch`/`finally` has the same jump-into-a-handler restriction —
plausibly in JS bytecode too; this report cannot resolve that without reading V8 internals (out of
brief) or beni choosing an implementation strategy first.

**What it would deliver, and which hard cases transfer.** Exactly the property `fast-compiler.md`
marks open: a bind inside a loop with no fold, and inside a branch with no new block, both
consequences of transforming the whole function rather than only the rest of a block. beni's being
expression-based should make the branch case *easier* than C#'s: the "no new block" win there is
really "the bound value is a variable in a struct field, not a lambda parameter," a property that
survives with or without statements — which answers `fast-compiler.md`'s open question of whether
"can a bind appear anywhere" and "does a sequence of binds read flat" are one decision or two: C#
shows they collapse into one once the state-machine backend is chosen, contrary to that document's
assumption that they "should be decided separately." Loop, branch, pattern-matching-after-bind, and
mixing two effect layers all transfer cleanly (§2). **Error propagation does not transfer as-is**:
C#'s "an uncaught exception faults the `Task`" mechanism depends on exceptions being C#'s only
failure channel, which contradicts `fast-compiler.md`'s guarantee that well-typed code does not
throw at runtime — beni would need to keep failure inside the `Result`/`Maybe` layer `Task` already
wraps, rather than adopting C#'s throw-and-fault model.

**What the C# team would warn beni about.** Make the effect visible to tooling even if not to the
type system — Lippert's reasons for requiring `async` at all lean heavily on enabling diagnostics
for a forgotten `await`, which beni's checker could do more strongly since it already types effects
explicitly as `Task e a` rather than hiding them behind an invisible modifier; and build the
debugging story alongside the transform, not after it — `StackTraceHiddenAttribute` shipped years
after `async`/`await` itself, evidence the state machine's ugly stack traces were a real cost the
original design did not fully anticipate.

---

## 7. Ranked summary

1. A whole-function state-machine transform is the only family-F–style mechanism that puts a bind
   inside both a loop and a branch with zero restructuring — verified directly against beni's own
   `fetchSummary` and loop examples in C#. (documented)
2. The awaitable pattern (`GetAwaiter`/`IsCompleted`/`OnCompleted`/`GetResult`) is resolved by
   ordinary member/extension-method lookup, explicitly modeled by its designer on LINQ's
   `Where`/`Select` resolution — no interface, no type-class, no HKT. (documented)
3. Every position where `await` is illegal maps to a specific runtime or CLR invariant
   (`Monitor` thread-affinity for `lock`; protected-region entry rules for `catch`/`finally`, later
   worked around by a dedicated compiler pass) rather than to an arbitrary syntactic choice.
   (documented)
4. The type-system cost of this design is near zero (ordinary overload resolution); the
   compiler-pipeline cost is real and large — a 695-line state-machine rewriter plus a 1,541-line
   expression-spilling pass plus a dedicated exception-handler-restructuring pass — squarely in the
   same cost tier report 15 measured for Roc's arbitrary-position `!` marker. (documented, partly
   measured as line counts, not performance)
5. Requiring the `async` keyword was a negotiated bundle of trade-offs (backward compatibility,
   lambda type inference, tooling diagnostics), argued in public by the language's own designer,
   not a technical necessity of the transform itself. (documented)
6. `async` is invisible to the caller-facing type of a method, which both designers and Microsoft's
   own maintained guidance treat as a source of recurring newcomer mistakes (`async void`, blocking
   on `.Result`, deferred LINQ plus async). (documented)
7. The debugging/stack-trace story for the state machine was not solved on day one;
   `StackTraceHiddenAttribute` was added to the runtime years later specifically to hide
   compiler-generated `MoveNext` frames. (documented)
8. LINQ's query syntax (2007) is the same compiler's earlier, narrower proof that member-resolved,
   pattern-based comprehension needs no type class — three years before `await` reused the idea.
   (documented)
9. Nothing in the `async`/`await` design has been withdrawn since 2012; the one restriction that
   moved (`catch`/`finally`) moved because a new compiler pass made it possible, not because the
   original restriction was reconsidered as wrong. (documented)
10. Per-bind/per-call runtime cost on JavaScript (question 6) is unanswered here by design — the
    brief marks it out of scope for ergonomics research, and this report's one source that touches
    it is a pure benchmark, set aside rather than cited. (documented, scope note)

---

## 8. What could not be resolved

- **The C# language specification's normative text for §12.9.9 (Await expressions), §15.15 (Async
  functions), and §12.20 (Query expression translation) could not be fetched verbatim.** Both the
  Microsoft Learn rendering and the raw `dotnet/csharpstandard` Markdown files are large enough that
  the fetch tool used this session truncates them before reaching those sections, regardless of the
  URL anchor or prompt given — attempted with roughly a dozen different anchors and prompts across
  `expressions.md`, `classes.md`, and `statements.md` with no success. Compensated with shorter
  derived conceptual pages (the `await` operator reference, the `lock` statement reference,
  "Query expression basics") that restate or quote the same rules, and with Roslyn source directly
  for the parts the spec itself would not describe (the algorithm).
- **Anders Hejlsberg's PDC 2010 talk** is cited only at one remove, through Lippert's contemporaneous
  post and its link to the session video; no transcript was located or fetched this session.
- **Mads Torgersen's own design notes on the C# 6 `catch`/`finally` change** (an LDM note or blog
  post along the lines of "New Features in C# 6") could not be located at a working URL — three
  guessed URLs (a devblogs post, an InfoQ article, a Roslyn issue) each returned HTTP 404. The
  version-history page and the `AsyncExceptionHandlerRewriter.cs` source were used instead, which
  establish *that* and *how* the change happened but not the design team's own narrative of the
  decision.
- **No independently counted practitioner evidence** ("N of the top-M threads mention Y") was
  gathered for §5, because the shared session-wide WebSearch budget (200 calls, pooled across every
  parallel agent in this research programme) was already exhausted before this report attempted its
  first search. §5 relies on Microsoft's own maintained pitfall documentation as a weaker,
  documented-not-counted proxy for frequency, and says so.
- **The exact wording of the compiler's "unawaited call" warning (commonly cited by its code as
  CS4014)** was not independently verified against a fetched primary source and is not quoted in §4
  for that reason.
- **Whether the JIT can inline an `async` method's `MoveNext` body into its caller** (question 7,
  optimiser transparency) was not confirmed or denied by any source read this session; §4 marks
  this explicitly **(unverified)** rather than guessing.
- **The precise moment the CTP's `BeginAwait`/`EndAwait` protocol (seen in Lippert's Part Two,
  2010-10-29) was replaced by the shipped `IsCompleted`/`OnCompleted`/`GetResult` split**, and the
  designers' stated reason, was not sourced; §3 records the CTP shape as a historical data point
  without an explanation of the change.
