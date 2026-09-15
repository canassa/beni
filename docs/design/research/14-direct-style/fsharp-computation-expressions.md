# F# computation expressions: member lookup, resumable code, and Fable's JavaScript output

**Commissioned by** the shared brief for research programme 14 (direct-style effect sequencing).
F# is Tier 1 in the landscape's Family C ("member-resolved, no HKT") because it is the only
mechanism in the whole survey with two complete, independently-shipped compilation strategies for
the same surface syntax: a fifteen-year-old member-lookup desugaring resolved by ordinary
overload resolution (no type class, no HKT), and a 2021 state-machine backend
(FS-1087, "resumable code") added underneath specific builders — `task { }` and `taskSeq { }` —
without changing a single character of user-facing syntax. Because beni targets JavaScript and has
already ruled out type classes and HKT (`fast-compiler.md` §3.1), the first strategy is the one in
beni's reach; the second is a case study in what the *next* increment of investment buys, and what
it costs, on a host — JavaScript, via Fable — that has no value-type structs to build a state
machine out of.

**Sources.** Read in full and cited by file/line where code is quoted: the **formal F# language
specification**, `fsharp/fslang-spec`, `spec/expressions.md:691-950` (fetched via
`raw.githubusercontent.com`, current `main`), which carries the actual `T(e, V, C, q)` translation
function reproduced in §2 — this supersedes the Microsoft Learn language-reference page, which is
cited only where it restates the spec in prose form and gives the builder-member signature table.
Three RFCs read in full from `fsharp/fslang-design` on `main`: **FS-1063** (`let!`/`and!`
applicatives, 2019), **FS-1087** (resumable code, 2020) and **FS-1097** (the `task` builder, 2020),
plus the FS-1087 RFC discussion thread `fslang-design#455` (2020-04 to 2021-04). The F# compiler's
own error-string table, `dotnet/fsharp` `src/Compiler/FSComp.txt` on `main`, read directly with
`curl`/`grep` for the exact diagnostic text and error-code numbers in §2 and §4 — not summarised
from a search result. Petricek and Syme, *"The F# Computation Expression Zoo"* (TFP 2014,
tomasp.net) — the PDF has no extractable text layer reachable by the tools available in this
session (no `pdftotext`/`poppler` on the machine, no Python PDF library installed); a short script
in this session decompressed the PDF's content streams and reassembled the literal-string operators
by hand (Zlib inflate + manual `Tj`/`TJ` parsing), which recovers the prose but drops ligature
glyphs (`fl`, `fi`) that the paper's font subset does not map to plain ASCII — quotes below have
those two letters restored by hand and are marked as such once. Fable's `fable-library-ts` source —
`Async.ts`, `AsyncBuilder.ts`, `Task.ts`, `TaskBuilder.ts` — read directly from
`raw.githubusercontent.com` at `fable-compiler/Fable@main`. GitHub issues, discussions and one PR
read via `gh api`/`gh pr view`: `fable-compiler/Fable#3672`, `#2299`, `#4694`;
`fsprojects/FSharp.Control.TaskSeq#188`. Eirik Tsarpalis's 2015 blog post on stack traces in
computation expressions, read directly. The Darklang F#6 benchmarking post
(`blog.darklang.com/benchmarking-fsharp6-tasks`) was read for the *motivation* it supplies — it is
noted once in §3 and its numbers are not reproduced, per this report's ergonomics-only scope.
**This session's WebSearch budget was exhausted (200/200 calls) about two-thirds through
research**; the remainder used direct fetches, `gh api` and `curl` against raw source and specs,
which gives better provenance than search snippets but forecloses a broad discovery sweep for §5 —
see §8. All web sources accessed **2026-09-14**.

---

## 0. The three findings, up front

**1. F#'s computation expressions need no type class, no HKT and no effect row — only an ordinary
named value in scope and instance-member lookup on its type, checked exactly like any other method
call.** The formal rule, `fslang-spec/spec/expressions.md:729`, is `builder-expr '{' cexpr '}'`
translating to `let b = builder-expr in {| cexpr |}C`, and every keyword inside the braces
(`let!`, `do!`, `for`, `while`, `try`, `yield`) becomes a call to a method resolved on the static
type of `b` — `b.Bind`, `b.For`, `b.While`, `b.TryWith`, `b.Delay`. There is no `Monad` constraint
anywhere in this rule. This is the same family beni's own report 15 already identified as the only
affordable one without HKT — OCaml's `let*`, Gleam's `use`, Koka's `with` — except F#'s version is
resolved by *member lookup* rather than *scope lookup on an operator name*, which is what buys it
the richest surface of any mechanism in the survey (loops, `try`/`finally`, `use`, custom LINQ-style
operators) at the cost of a builder author implementing up to seventeen distinct members, several
with multiple valid signatures (§2).

**2. F# is the one design in the survey where a bind inside a loop costs nothing syntactically —
and that is bought by asking every builder author to implement `Delay`, `Combine` and `Zero`, three
members whose entire job is administrative.** `for x in e do ce` desugars to
`b.For(src(e), fun x -> {| ce |})` (`spec/expressions.md:797`), and because `ce` is itself
recursively translated, a `let!` inside the loop body is fully legal — this is precisely the
capability report 15 found *absent* from Gleam's `use` and OCaml's `let*` ("a bind inside a loop is
... not expressible at all with the syntactic rewrite — you must reach for a fold", shared brief).
But every `if` without an `else`, every sequential `;`, and every `while` loop routes through
`Delay`/`Combine`/`Zero` even when the builder's underlying type does not need them (a monad can
define them in terms of `Bind`/`Return`; a monoidal computation like a parser cannot — Petricek and
Syme, §2.2: *"For monads, these can be de ned in terms of Bind and Return, but this is not the case
for all computations"*, ligature restored). This is the fixed administrative tax for the loop-inside-
a-bind capability, paid once per builder, not per call site.

**3. The state-machine backend (FS-1087) and the classic member-lookup backend are not two options
a user picks between — they are two *compiler-internal* implementations of the same `task { }`
syntax, and Fable's JavaScript output uses neither of F#'s own choices: it re-derives the classic
1990s-style desugaring by hand, targeting `Promise` directly, and only shipped `task { }` support
for JS/TS in 2026.** `dotnet/fsharp` compiles `task { }` to a `ResumableStateMachine<'Data>` struct
manipulated with compiler intrinsics (`__resumableEntry`, `__stateMachine`, `__resumeAt`) that have
no JavaScript equivalent — there is no byref, no struct, no goto. Fable's
`fable-library-ts/TaskBuilder.ts` instead defines an ordinary `TaskBuilder` class with `Bind`,
`Combine`, `Delay`, `For`, `TryWith`, `TryFinally`, `Using`, `While`, `Zero`, `Run` — the *exact*
member set the 2010-era classic desugaring calls — over `Promise<T>` directly (`Task.ts:26-27`:
`// Task<T> = Promise<T> in JS/TS.`). This code was merged in
[fable-compiler/Fable#4694](https://github.com/fable-compiler/Fable/pull/4694), *"feat(js/ts): map
task { } to Promise<T>"*, on **2026-06-29** — five years after FS-1087 shipped in .NET, and after a
2023-12-18 issue ([#3672](https://github.com/fable-compiler/Fable/issues/3672)) sat open the whole
time because of a genuine semantic mismatch (§5). Fable is direct, load-bearing evidence for beni:
the team that already ships an F#-to-JS compiler chose the classic desugaring for this exact target,
not the state machine.

---

## 1. The effect model

F# has two effect-carrying value types relevant here, and computation expressions are a *syntax*
layered identically over both — the effect model itself is unrelated to the CE mechanism.

- **`Async<'T>`** is F#'s own type, not built on .NET's `Task`. Operationally it is closer to a
  continuation-passing computation: `Async<'T>` values are *cold* — constructing one runs nothing —
  and *multi-shot*: the same `Async<'T>` value can be started many times (`Async.RunSynchronously`,
  `Async.Start`, `Async.StartAsTask`, ...), each a fresh execution. Cancellation tokens propagate
  implicitly through the ambient context. This is a value interpreted by a runtime in the sense
  report 16 studies fibers: nothing happens until something runs it.
- **`Task<'T>`** is the BCL's task — *hot*: the work backing a `Task<'T>` begins as soon as the
  value exists, and it completes **once**. FS-1097 states this as a named limitation, not an
  aside: *"Limitation - Hot start, once. Unlike F# async, tasks start immediately ('hot start') and
  each task may only complete once."* (`FS-1097-task-builder.md:590-592`). Cancellation is explicit
  only — *"tasks do not support implicit passing of cancellation tokens"* (ibid., line 594) — and
  there are no asynchronous tailcalls, so `let rec loop n = task { ... return! loop (n+1) }` grows
  stack/heap without bound for large `n` (ibid., lines 598-614, with the code example given
  verbatim in the RFC).

Sequencing two effects, in both cases, means calling the builder's `Bind` member; nothing about
"effect" is a first-class kind or row. F# does not distinguish effectful from pure code in the type
system at all beyond the ordinary generic type (`Async<'T>`, `Task<'T>` are types like any other) —
there is no "colour" propagated onto function signatures the way `async fn` marks Rust or C#
signatures (though functions returning `Task<'T>` are conventionally suffixed `Async` by
[.NET naming convention](https://learn.microsoft.com/en-us/dotnet/standard/asynchronous-programming-patterns/task-based-asynchronous-pattern-tap),
a convention, not a checked property). `option { }`, `result { }`, `seq { }` and `parse { }`
computation expressions in the wild are effect-free syntax sugar over ordinary ADTs and closures —
the same mechanism serves monoids (parsers, list comprehensions), monads (async, option) and
applicative functors (validation) uniformly, which is the paper's stated thesis (§0.1 above and
§3.1 below).

---

## 2. The mechanism

### 2.1 The formal translation

The authoritative rule is `fslang-spec/spec/expressions.md:691-950`. For a fresh variable `b`:

```fsgrammar
builder-expr '{' cexpr '}'   ~~>   let b = builder-expr in {| cexpr |}C
```

`{| cexpr |}C` is defined by a recursive function `T(e, V, C, q)` — `e` the sub-expression being
translated, `V` the set of variables bound so far, `C` the surrounding continuation, `q` whether a
custom (LINQ-style) operator is permitted at this point. The clauses that matter for beni (spec
lines given):

| Surface form | Translation | Spec line |
|---|---|---|
| `let p = e in ce` | `T(ce, V∪var(p), v.C(let p = e in v), q)` | 763 |
| `let! p = e in ce` | `T(ce, V∪var(p), v.C(b.Bind(src(e), fun p -> v)), q)` | 765 |
| `do! e in ce` | `= let! () = e in ce` | 812 |
| `yield e` | `C(b.Yield(e))` | 767 |
| `yield! e` | `C(b.YieldFrom(src(e)))` | 769 |
| `return e` | `C(b.Return(e))` | 771 |
| `return! e` | `C(b.ReturnFrom(src(e)))` | 773 |
| `use p = e in ce` | `C(b.Using(e, fun p -> {ce}0))` | 775 |
| `use! p = e in ce` | `C(b.Bind(src(e), fun p -> b.Using(p, fun p -> {ce}0)))` | 777 |
| `match e with pi -> cei` | `C(match e with pi -> {cei}0)` | 779 |
| `match! e with pi -> cei` | `= let! p = e in match p with pi -> {cei}0` | 781 |
| `while e do ce` | `T(ce, V, v.C(b.While(fun()->e, b.Delay(fun()->v))), q)` | 783 |
| `try ce with pi -> cei` | `Assert(¬q); C(b.TryWith(b.Delay(fun()->{ce}0), fun pi -> {cei}0))` | 785 |
| `try ce finally e` | `Assert(¬q); C(b.TryFinally(b.Delay(fun()->{ce}0), fun()->e))` | 787 |
| `if e then ce` | `T(ce, V, v.C(if e then v else b.Zero()), q)` | 789 |
| `if e then ce1 else ce2` | `Assert(¬q); C(if e then {ce1}0 else {ce2}0)` | 791 |
| `for x in e do ce` | `T(ce, V∪{x}, v.C(b.For(src(e), fun x -> v)), q)` | 797 |
| `ce1; ce2` | `C(b.Combine({ce1}0, b.Delay(fun()->{ce2}0)))` | 908 |
| `e;` (trailing) | `C(e; b.Zero())` | 910 |

`src(e)` denotes `b.Source(e)` if the builder defines a `Source` method (used for query-expression
sources), otherwise `e` unchanged. `Assert(¬q)` is the spec's own name for the restriction that
**custom LINQ-style operators may not be mixed with `try`/`with`, `try`/`finally`, `if`/`then`/`else`,
`use`, `match` or sequential `;`** — "even if the custom operators are not used" (spec, note under
the translation table) — a genuine syntactic wall inside a single builder's block that has no
equivalent for a builder using only the classic keywords.

If the builder type has `Run`, `Delay` or `Quote` members, the whole thing is additionally wrapped:
`b.Run(b.Delay(fun () -> {cexpr}C))`, with each wrapper omitted if the corresponding member is
absent (spec lines 731-745). This omission is the entire mechanism by which a builder "opts out" of
a feature: **there is no interface, no marker attribute — a builder that does not define `For` simply
cannot be used in a `for` loop, and the compiler reports exactly that.**

### 2.2 What the type system must know (cross-cutting Q4)

**Nothing beyond ordinary instance-member resolution.** `b`'s type is inferred first (from
`builder-expr`), then every keyword becomes a normal method call resolved by F#'s usual overload
resolution against that one concrete type — the same mechanism that resolves `x.ToString()`. This
is why the mechanism needs no HKT: the compiler is never asked "does some `M` satisfy Monad" — it is
asked "does the type of `b` have a method named `Bind` with a compatible arity", a question ordinary
name resolution already answers. The one extension beyond plain method lookup is `let! ... and!`
(FS-1063, F# 5.0), which asks for either a `BindN` method (`Bind2`, `Bind3`, ...) or a `MergeSources`
family, and falls back through them in a fixed order the RFC specifies exactly
(`FS-1063:24-35`) — still ordinary overload resolution, just over a *set* of candidate method names
chosen by how many `and!` clauses are present.

### 2.3 Position (cross-cutting Q5)

Every one of these keywords is legal **only inside the braces of a `builder-expr { }` block**; the
grammar in `spec/expressions.md:691-707` lists `expr '{' let! ... '}'` etc. as the complete set of
forms. Outside a CE block, `let!`, `do!`, `yield`, `return`, `match!` are all syntax errors. Within
the block, a CE keyword may appear in `let`-position, in tail (return) position, and — because the
translation recurses into `if`/`match`/`try`/`for`/`while` bodies — inside any of those control
constructs' bodies too, to arbitrary nesting depth. It may *not* appear as an ordinary sub-expression
(as an argument to a function call, inside a record field initializer) the way Roc's now-removed `!`
suffix could (report 15, §2.1) — F#'s markers are statement/`let`-position only, and this is exactly
what buys the *desugarer* its locality: the translation is a straightforward tree walk with no
non-local hoisting.

### 2.4 The five hard cases

**Bind inside a branch, and the value survives the branch** — the brief's `fetchSummary` example,
faithfully:

```fsharp
let fetchSummary () : Task<Summary> =
    task {
        let! user = getUser ()
        let! perms = getPermissions user
        if perms.isAdmin then
            let! log = getAuditLog user
            return Summary(user, perms, Some log)
        else
            return Summary(user, perms, None)
    }
```

`user` and `perms` are bound before the `if`, so by the translation `T(if e then ce1 else ce2, ...)`
(spec line 791) both branches are inside the same closure as `user`/`perms` — no extra nesting, and
this is identical in shape to the generator example in the brief. A bind *inside* one branch (`log`)
is scoped to that branch only, exactly as in ordinary F#.

**Bind inside a loop** — the case Gleam's `use` and OCaml's `let*` cannot express directly (report
15) is native here, via `For`:

```fsharp
let fetchTotalScore (ids: int list) : Task<int> =
    task {
        let mutable total = 0
        for id in ids do
            let! score = getScore id
            total <- total + score
        return total
    }
```

`for id in ids do ce` translates to `b.For(ids, fun id -> {ce})` (spec line 797), and `{ce}` is
itself `let! score = ...; total <- ...` — a full computation-returning function, recursively
translated. No fold, no manual recursion.

**Early return and cleanup.** `return`/`return!` map to `Return`/`ReturnFrom` in *tail* position
only — there is no `?`-style early exit from the *middle* of an expression the way Rust's `?` or
beni's own `?` on `Result` can. To leave early from the middle of a `task { }`, F# uses ordinary
`.NET` exceptions and `try`/`with`/`finally`, which the CE compiles through `TryWith`/`TryFinally`
exactly as spec lines 785-787 show — cleanup and early exit are the *same* native mechanism used
outside computation expressions, not something the CE machinery reinvents.

**Pattern matching on the bound value** is `match!`, sugar for `let!` followed immediately by
`match` (spec line 781: `= let! p = e in match p with pi -> {cei}0`) — the F# language reference
states this is the *only* CE keyword that is pure sugar for two others rather than a distinct
builder member.

**Mixing effect types** (`Result` inside `Task`) has no automatic lift. Given
`getUser : unit -> Task<Result<User, Err>>`:

```fsharp
task {
    let! result = getUser ()
    match result with
    | Ok user -> return! doSomething user
    | Error e -> return Error e
}
```

There is no builder member that reaches through both layers at once — this is manual, the same cost
beni's `fast-compiler.md` §3.2 already assigns to `Result.andThen` chains, just inside a `task {}`
block instead of outside one.

### 2.5 The second backend: resumable code (FS-1087)

FS-1087 adds a **compiler-recognized, statically-inlined state-machine form**, used today only by
`task { }`, `taskSeq { }`, and library-internal `list`/`option`/`voption` builders — it changes
nothing about the syntax in §2.1-2.4, only how `task { }` specifically is *compiled*. The design's
own eight-point philosophy (`FS-1087-resumable-code.md:60-86`) is worth quoting because every clause
is a constraint on how invasive the feature is allowed to be:

> "1. No new syntax is added to the F# language. ... 4. We treat this as a compiler feature. The
> actual feature is barely surfaced as a language feature, but is rather a set of idioms known to
> the F# compiler... 7. The feature is designed for use only by highly skilled F# developers to
> implement low-allocation computation expression builders. 8. Semantically, there's nothing you
> can do with resumable state machines that you can't already do with existing workflows."

Mechanically: a builder marks its bind operation as `ResumableCode<'Data,'T>` (`delegate of
byref<ResumableStateMachine<'Data>> -> bool`), and the compiler, under aggressive `inline`, weaves
user code and builder code into one `MoveNext` method on an anonymous struct, using compiler
intrinsics `__resumableEntry` (a resumption label), `__resumeAt` (a `goto`, or a jump-table dispatch
on a computed label) and `__stateMachine` (materializes the struct type) — the same state-machine
transform report 16 studies for Rust/C# `async`, built by hand in library code instead of the
compiler's own IR.

**Its restrictions are exact, not fuzzy** — a list of the loop/branch/try cases in §2.4 that cannot
host a suspension point (`FS-1087:440-458`, `FSComp.txt`):

- an integer `for` loop containing a resumption point — `reprResumableCodeContainsFastIntegerForLoop`
- a `let rec` — `tcResumableCodeContainsLetRec` / `reprResumableCodeContainsLetRec`
- a `try`/`finally` containing a resumption point — `reprResumableCodeContainsResumptionInTryFinally`,
  *"A try/finally may not contain resumption points"*
- the `with` block of a `try`/`with` containing one — `reprResumableCodeContainsResumptionInHandlerOrFilter`

When a builder's code fails these checks but is guarded by `if __useResumableCode then ... else ...`,
compilation **still succeeds** — a warning is emitted and the dynamic (allocating, dictionary-
dispatched) fallback runs instead: `reprStateMachineNotCompilable`, *"This state machine is not
statically compilable. %s. An alternative dynamic implementation will be used, which may be slower.
Consider adjusting your code..."* (`FSComp.txt:1649`, code FS3511). The FS-1087 drawbacks section
gives a real example that trips this: a `let rec` inside a `task { }` compiles, but silently drops
to the slower path (`FS-1087:1196-1211`).

### 2.6 Error messages when a builder lacks a member

Read directly from `dotnet/fsharp`'s `src/Compiler/FSComp.txt` (`main`, accessed 2026-09-14):

| Code | Name | Text |
|---|---|---|
| FS0708 | `tcRequireBuilderMethod` | "This control construct may only be used if the computation expression builder defines a '%s' method" |
| FS0708 | `tcEmptyBodyRequiresBuilderZeroMethod` | "An empty body may only be used if the computation expression builder defines a 'Zero' method." |
| FS0750 | `tcConstructRequiresComputationExpression` | "This construct may only be used within computation expressions" |
| FS0749 | `tcConstructRequiresSequenceOrComputations` | "This construct may only be used within sequence or computation expressions" |
| FS0792 | `tcConstructIsAmbiguousInComputationExpression` | "This construct is ambiguous as part of a computation expression. Nested expressions may be written using 'let _ = (...)' and nested computations using 'let! res = builder { ... }'." |
| FS3343 | `tcRequireMergeSourcesOrBindN` | "The 'let! ... and! ...' construct may only be used if the computation expression builder defines either a '%s' method or appropriate 'MergeSources' and 'Bind' methods" |
| FS3885 | `parsLetBangCannotBeLastInCE` | "'%s' cannot be the final expression in a computation expression. Finish with 'return', 'return!', or a simple expression." |

FS0708 is the direct answer to "what does a missing member look like": the compiler names the
*exact* method it wanted (`'%s'` is substituted with `For`, `While`, `TryFinally`, etc. at the call
site) rather than reporting a generic type error — a diagnostic quality that reflects the mechanism
being ordinary name resolution, not constraint solving. FS0792 is the compiler's own answer to
"which builder am I in" when computation expressions nest: it fires specifically when a nested block
is ambiguous between being an ordinary parenthesized sub-expression and a nested computation, and
tells the user to disambiguate by writing `let! res = builder { ... }` explicitly.

---

## 3. History and decisions

**F# 1.x–2.0 (Syme, ~2007):** computation expressions ship as a general mechanism, motivated
explicitly by wanting `async { }` without hardwiring async into the compiler the way C# eventually
did for `await`. Petricek and Syme's 2014 TFP paper is the retrospective formalisation, not the
original design note, but its framing is the field's canonical statement of the trade-off:

> "The question is, is there a sweet spot between convenient, hardwired language features, and an
> inconvenient but flexible libraries? F# computation expressions answer this question in the
> affirmative. Unlike the 'do' notation in Haskell, computation expressions are not tied to a single
> kind of abstraction." (Abstract, ligatures restored by hand — see Sources.)

The paper's worked example is `async { }` against C# 5's built-in `await`, side by side, and its
punchline for `Combine`/`Delay`/`Zero` is exactly finding 2 above, stated in the builder-author's own
terms: *"the translation is the same, but the typing differs"* — the same four members serve a monad
(`async`), a parser (`Combine` as monoidal choice) and a sequence (`Combine` as concatenation), each
with different underlying types for the same method names.

**F# 5.0 / FS-1063 (2019-2020, approved in principle then implemented, `dotnet/fsharp#7756`):**
`let! ... and! ...` for applicative computation expressions. Motivation, in the RFC's own words: a
chain of independent `let!`s "forces re-execution of 'expensive' binds when these are independent" —
the dependency-graph example in the RFC shows this mattering for anything from parallel HTTP calls
to error-accumulating validation. **What was withdrawn before shipping:** `use!`/`anduse!` support
via an `ApplyUsing` method, removed from the design because `MergeSources` "gives no particular
place to put the resource reclamation" and the guarantees around when reclamation is guaranteed
were "not entirely easy to ascertain and can result in resource leaks" (`FS-1063:453-455`, linking
the specific commit that found the leak). The RFC also explicitly declines `do!`/`anddo!`: *"do!
implies side-effects and hence sequencing in a way that applicatives explicitly aim to avoid"*
(`FS-1063:474`). **A more general design was rejected first:** Tomas Petricek's own prior
"Joinads" proposal offered a superset of these features but was
[rejected](https://github.com/fsharp/fslang-suggestions/issues/172) "due to its complexity"
(`FS-1063:476`) — the shipped `and!` is the deliberately smaller design that survived that rejection.

**F# 6.0 / FS-1087 + FS-1097 (2020-2021):** resumable code and the `task { }` builder. Motivation
stated tersely: existing community implementations (`TaskBuilder.fs`, `Ply`) "tend to have
allocation overhead" (`FS-1087:29`) — the Darklang benchmarking post is the external, independently
measured case that the F# team and community cite for this claim; per this report's scope its
numbers are not reproduced here. **Alternatives explicitly considered and rejected**
(`FS-1087:1244-1259`): building compiler support for each computation expression individually, the
way C# bakes in `Task` and async-iterator support (*"This means the only user-code that can be
efficiently resumable is code that returns these two types"* — rejected in favour of a library-level
general mechanism); and restricting the mechanism to `FSharp.Core` only (left open, not taken — the
feature ships behind `/langversion:preview` for external use). **What was never redone:** F#'s own
`async` was not reimplemented on top of resumable code, and Syme says why directly in the RFC
discussion thread (`fslang-design#455`, 2021-04-30, in reply to Mads Torgersen of the C# team):

> "Then there is the original - F# `async { .. }` - which effectively adds explicit-multi-start,
> tailcalls and cancellation token propagation to tasks. It might benefit from this - though compat
> will make it hard for us to reimplement async to use this."

That single sentence is the designer's own account of why F# ended up with two permanently distinct
builders rather than one: `async` and `task` are not a historical accident of naming, they encode
genuinely different hot/cold, tailcall and cancellation contracts (§1), and backward compatibility
forecloses merging them even though the team that built resumable code would clearly have preferred
one mechanism.

**Removed/regretted, summarised (cross-cutting Q9):** `use!`/`anduse!` (FS-1063, pre-ship); Joinads
(rejected as too complex, pre-FS-1063); per-type compiler-baked CEs (rejected as an FS-1087
alternative); `async` reimplementation on resumable code (never attempted, stated incompatible).
Nothing in the shipped mechanism itself — `Bind`/`For`/`Combine`/`Delay`/`Zero`/`TryWith`/`TryFinally`
— has been withdrawn since F# 2.0.

---

## 4. Costs — ergonomic and structural

**Cross-cutting Q6 (per-bind/per-call cost) is explicitly out of scope for this report** by the
project owner's rule against benchmarks, timings and allocation counts; FS-1087's own motivation
cites allocation overhead as the reason it exists, and that one sentence (§3) is as far as this
report goes into that territory.

**What it does to the user's code.** Nothing, for a user only *consuming* `async`/`task`/`seq` — the
five hard cases in §2.4 are the whole surface. The cost lands on **builder authors**: to support
`if` without `else`, sequential statements, or `while`, a builder must implement `Zero`, `Combine`
and `Delay` even for computations where they have no independent meaning and exist purely to satisfy
the desugarer — Scott Wlaschin's "Implementing a CE" tutorial series exists because this
administrative surface needs one. Custom LINQ-style operators add an absolute restriction: a builder
defining *any* `CustomOperationAttribute` member cannot mix that operator with `try`/`with`,
`try`/`finally`, `if`/`then`/`else`, `use`, `match`, or `;` *anywhere in the same block, even where
the custom operator is not used* (the spec's own `Assert(¬q)` rule, §2.1) — a compile-time wall.

**Newcomers get wrong, with evidence:**
- **Sequential `let!` where `and!` was needed.** A chain of independent `let!`s type-checks and runs
  correctly but re-executes sequentially what could be parallel or shared — this is exactly the
  motivating complaint FS-1063 records (§3), and it produces no diagnostic at all; the "bug" is a
  missed opportunity, not an error.
- **`let rec` inside `task { }` silently taking the slow path.** FS3511 is a *warning*, not an
  error — code compiles and runs, just via the dynamic (dictionary-dispatched) fallback FS-1087
  built for exactly this case (§2.5), and a developer who does not read warnings never learns why.
- **The `async`/`task` naming confusion generalises to `taskSeq`.** In
  [fsprojects/FSharp.Control.TaskSeq#188](https://github.com/fsprojects/FSharp.Control.TaskSeq/discussions/188)
  (2022-11-06), TaskSeq's own author, Abel Braaksma, records the confusion by name: *"people
  thinking this is about 'sequences of tasks'"* — the type is an async-sequence-of-values, not a
  collection of `Task` objects, and the builder-name mechanism (§2) gives no way to signal that
  distinction beyond the name chosen. The same thread has Braaksma defending the two-builder split
  on purpose, not apologising for it: *"F# Core has two distinct builders, one for `task` and one
  for `async`"*, arguing the community already associates `Async` with multi-threading/
  parallelisation and `Task` with fast, hot-started, non-parallelised work — the split is treated as
  a feature by at least this maintainer, not a wart (§5 has the fuller quote).

**Tooling.** Stack traces are the clearest, best-documented casualty. Eirik Tsarpalis, 2015-12-27:

> "generated expressions are desugared into nested lambda invocations, which means that their
> corresponding stacktraces are often unreadable" — and separately, "implementations such as async
> have their own exception handling logic implemented, which often leads to stacktraces being
> completely erased."

His worked example is a recursive `factorial` written with `async { }`: the desugared version shows
one stack frame for the whole recursion where the direct-style version shows all five. This is a
structural consequence of §2.1's translation — every recursive call becomes a continuation closure,
not a nested call frame — and it long predates FS-1087; the state-machine backend does not fix it
(a `MoveNext` loop has, if anything, fewer frames than a closure chain). No fix has shipped for this
as of this report; Tsarpalis's proposed remedy (compiler-supplied invocation metadata passed to
builders) was never adopted into the language.

**Optimiser transparency (cross-cutting Q7).** The two backends diverge sharply here. Classic
member-lookup CEs desugar to ordinary method calls — on .NET the JIT inlines/devirtualizes them like
any other call; in Fable's JS output, `TaskBuilder.Bind` is literally `computation.then(binder)`
(`TaskBuilder.ts:6-8`), fully visible to V8's normal optimisation of `.then` chains, no opaque
object. Resumable code is the opposite case *by construction* — its whole point is to become a
single flattened `MoveNext` method the JIT sees as one unit — but FS-1087 names its own limit:
*"The resumable code composition and elimination happens late in the F# compiler. Not all code
optimizations are applied."* (`FS-1087:1220-1224`, "Imperfect optimization"). Neither backend is
"opaque" in the sense report 16 uses for Effect-TS's fiber interpreter; the cost is elsewhere
(allocation, out of scope here).

**Diagnostics and locations (cross-cutting Q8).** Covered above (§2.6, this section): F#'s own
compiler names the missing member precisely (FS0708) and disambiguates nested CEs precisely (FS0792).
Fable's diagnostics for CE-adjacent failures are a different style entirely — a generic translation-
layer error, not a CE-aware one: attempting `ValueTask.AsTask` under Fable produced *"Cannot resolve
replacement System.Threading.Tasks.ValueTask.AsTask"*
([fable-compiler/Fable#2299](https://github.com/fable-compiler/Fable/issues/2299), 2020-11-26) — the
message names a missing *runtime replacement*, not a missing *builder member*, because by the time
Fable's `Replacements.fs` layer runs, the CE has already been desugared by the F# compiler frontend
into ordinary method calls Fable then tries to map onto its JS runtime one at a time.

**Removed or regretted (cross-cutting Q9).** Answered in full in §3.

**Effects as values (cross-cutting Q10).** `Async<'T>` fully preserves deferred execution,
multi-shot restart and implicit cancellation propagation — a real effect value interpreted by a
runtime, in the sense report 16 uses the term. `Task<'T>` deliberately does not: FS-1097 states
hot-start-once and explicit-cancellation-only as *limitations*, not bugs (§1). On the JS side, Fable
collapses `Task<'T>` onto `Promise<T>` — itself hot and single-shot, so the .NET and JS semantics
happen to line up here (unlike `Async<'T>`, which Fable keeps as its own CPS-plus-trampoline
interpreter, `AsyncBuilder.ts:94` `export type Async<T> = (x: IAsyncContext<T>) => void`, so deferred
execution and multi-shot restart both survive intact on the JS target for `Async` but not for
`Task`).

---

## 5. What users say

The WebSearch budget ran out before a broad discovery sweep (§8), so this section reports what
direct fetches turned up rather than a counted survey across many threads; it is not a claim that
these are the only or the most representative voices, and no "N of M threads" count is offered
because the sample is too small to support one honestly.

**Praise.** Petricek and Syme's own "sweet spot" framing (§3) is a designer's account, not a
practitioner's, but it is echoed in Braaksma's defence of the split builders as intentional design
rather than debt (§4) — a maintainer of a widely used F# async library treating "two builders" as a
feature, in a thread that could easily have been a complaint. The loop-native `For` capability
(§2.4, finding 2) has no dedicated complaint thread found in this research; its absence from
the complaint corpus is itself suggestive, though not conclusive given the search gap.

**Complaints.** Three, each with a primary-source quote already given in full above: stack-trace
loss (Tsarpalis, 2015, §4); the `taskSeq` naming confusion (Braaksma, 2022, §4); and the
`async`/`task`/`Promise` three-way semantic mismatch specific to Fable, played out across
[fable-compiler/Fable#3672](https://github.com/fable-compiler/Fable/issues/3672) (opened
2023-12-18): Fable maintainer Alfonso García-Caro (MangelMaxime) opens by asking the hot/cold
question directly — *"Are `Task` in .NET hot or cold? ... Could it lead to problems if `Task` are
cold in .NET and/or Python, while in JavaScript `promise` are hot?"* — and issue author Dag Brattli
answers from direct .NET/Python/JS comparison that all three are in fact hot, but flags this is
*why* he was "unsure about rewriting all Task-based code to use F# async for interoperability."
Fable core contributor Alex Swan (ncave) confirms Rust's futures are the outlier — cold — in the
same thread. The issue stayed open **two and a half years** before
[#4694](https://github.com/fable-compiler/Fable/pull/4694) resolved it in 2026-06-29.

**Wishes.** MangelMaxime's own workaround, posted in the same thread, is itself evidence of a felt
gap: a hand-rolled `crossAsync`/`CrossAsync<'T>` pair using `#if FABLE_COMPILER` to pick `promise`
vs `async` at compile time, explicitly because no unified cross-target syntax existed yet. That
pattern — compiler-directive-gated builder selection — is a user paying, by hand, exactly the cost
a language-level unification would remove.

**Maintaining large codebases vs. evaluating the language.** The evidence found skews toward
library/tooling maintainers (Braaksma on TaskSeq, the Fable core team) rather than application
developers evaluating F# for the first time; no first-impressions blog post surfaced in the time
available that treats computation expressions as a barrier to adoption. This is a gap in the
research, not a finding about newcomers' silence (see §8).

---

## 6. What it would take to do this in beni

**The classic (member-lookup) backend transfers cleanly to beni's constraint set, with one
structural mismatch.** F#'s whole mechanism needs no HKT and no type class — exactly the two things
`fast-compiler.md` §3.1 already rules out for beni — because the compiler resolves every keyword
against the *concrete, already-known* type of the builder value named in the source
(`builder-expr { ... }`), the same "resolved by the written call, not by a class" family report 15
already placed OCaml's `let*`, Gleam's `use` and Koka's `with` in. The mismatch: F#'s translation
(§2.1) leans on F# *having* statement forms — `if e then ce` with no `else`, bare `while`, sequential
`;` — each with its own clause in `T`. Beni is expression-based (`fast-compiler.md` §3.2's open
section already names this as a separate, entangled question). Adopting F#'s exact recursive
translation would require beni to either grow statement-shaped forms inside a hypothetical CE block
(a bigger grammar change than beni's current `let ... in` sequencing) or accept a narrower
desugaring that only covers `let`-chains and `if`/`match` with both arms present — which would
recover finding 1 of the brief's example (bind inside a branch) but **not** finding 2 (bind inside a
loop), because `For` specifically needs an imperative loop construct to attach to, and beni currently
expresses iteration through `fold`/recursion, not a `for` statement. This is exactly report 15's
already-flagged Option A limit ("block-structured ... not expressible" for binds inside loops) — F#
escapes that limit only because it already has `for`/`while` as native statement forms for the CE
translation to piggyback on, which beni would have to add as new surface syntax, not inherit for
free.

**What it would deliver:** the five hard cases of §2.4 minus the loop case, unless beni also adds a
loop construct; automatic `try`/`finally`-shaped cleanup interacting correctly with early return,
since that piggybacks on whatever native exception/cleanup mechanism beni already has (§2.4) rather
than requiring new machinery; and the applicative `and!` shape (FS-1063) as a *pure addition* later,
since it is resolved by the same member-lookup mechanism and does not entangle with the loop
question.

**What the resumable-code path would cost, and Fable's own choice is the loudest warning available.**
FS-1087 is explicit that this is a compiler feature "designed for use only by highly skilled F#
developers" (§2.5), needing new IL-level intrinsics, a byref-struct state-machine representation and
a dedicated compilation pass with its own non-compilability diagnostics — a materially larger
investment than the desugarer-only `?` beni already has for `Result` (`fast-compiler.md` §3.2). More
directly on-target: **Fable, a compiler built specifically to target JavaScript from F#, evaluated
this exact problem and did not adopt the state-machine backend for JS at all** — it re-implemented
the classic desugaring by hand against `Promise` (§0.3), and that took until mid-2026, five years
after resumable code landed for .NET. Two reasons generalise directly to beni: JavaScript has no
value-type structs to host a `ResumableStateMachine<'Data>` in, and the byref/`goto`-table intrinsics
have no JS analogue without either a real generator (report 15/16's "Option B") or a hand-built state
machine in the compiler itself (Option C) — not a library the way F#'s is. What F#'s own team would
likely warn beni about: build the general mechanism once, in the compiler, rather than baking in
per-effect-type support (the alternative FS-1087 itself rejected, §3); and a silently-taken slow path
(FS3511, §2.5) is a real hazard — the same class of surprise beni's own checker discipline already
rejected once for `?` on `Task` (`fast-compiler.md` §3.2, report 15 §0.3).

---

## 7. Ranked summary

1. **(documented)** The classic desugaring needs only ordinary instance-member lookup on the
   builder's already-known static type — no HKT, no type class, no effect row — confirmed against
   the formal spec's `T(e,V,C,q)` rule (`fslang-spec/spec/expressions.md:729-950`).
2. **(documented)** A bind inside a loop is native, via the `For` member, unlike Gleam's `use` or
   OCaml's `let*` — the price is that every builder wanting `if`/`while`/`;` must also implement
   `Delay`, `Combine` and `Zero`, administrative members with no independent meaning for some
   computations (Petricek & Syme, §2.2).
3. **(documented)** `async` and `task` are permanently separate builders by explicit designer
   decision, not naming inertia: hot/cold, tailcall and implicit-cancellation semantics differ, and
   Syme states directly that backward compatibility "will make it hard for us to reimplement async"
   on the newer mechanism (`fslang-design#455`, 2021-04-30).
4. **(documented)** Fable did not adopt F#'s state-machine backend for JavaScript; it reimplemented
   the classic `Bind`/`Combine`/`Delay`/`For`/`TryWith`/`TryFinally`/`While`/`Zero`/`Run` protocol by
   hand against native `Promise`, merged 2026-06-29 (`fable-compiler/Fable#4694`) — five years after
   FS-1087 shipped for .NET.
5. **(documented)** The compiler's own error for a missing builder member names the member exactly
   (FS0708, `FSComp.txt:567`); this is a strong, positive diagnostic-quality finding, not an inferred
   one.
6. **(documented)** A `let rec` inside `task { }` compiles but silently falls back to a slower
   dynamic implementation with only a warning (FS3511) — a real, named footgun in F#'s own RFC.
7. **(documented)** Stack traces through computation-expression code lose recursive-call structure
   because every recursive step becomes a continuation closure, not a call frame (Tsarpalis, 2015);
   this predates and is unaffected by the state-machine backend.
8. **(documented)** `use!`/`anduse!` and Petricek's own earlier "Joinads" proposal were both
   designed and then withdrawn/rejected before FS-1063 shipped, for resource-leak and complexity
   reasons respectively (`FS-1063:453-476`).
9. **(unverified)** Whether the "which builder am I in" confusion named in the landscape brief has a
   canonical primary-source statement in those exact words — not found; the closest verified
   evidence is the compiler's own FS0792 ambiguous-nesting diagnostic and the `taskSeq` naming
   confusion thread (§4, §8).
10. **(inferred)** Beni could adopt the classic desugaring's member-lookup resolution directly, but
    would recover the loop-native capability only by first adding an imperative loop construct —
    without one, beni would land exactly at report 15's already-identified Option A ceiling
    (binds inside branches, not inside loops).

---

## 8. What could not be resolved

- **A quantified "N of M threads" count for §5.** The session's WebSearch budget was exhausted
  (200/200 calls) roughly two-thirds through this research, before a broad sweep of r/fsharp,
  Hacker News, Discourse or Stack Overflow could be completed. What follows the budget exhaustion
  used direct fetches (`gh api`, `curl` against raw GitHub content) against sources already known by
  name or found via the last searches that ran — good provenance, no discovery power. §5 says this
  explicitly rather than presenting a small, cherry-picked sample as a survey.
- **The exact phrase "which builder am I in"** from the landscape brief was not traced to a single
  primary-source quote in those words. The two closest verified proxies are the compiler's own
  FS0792 ambiguous-nested-CE diagnostic (§2.6) and the `taskSeq`-vs-"sequence of tasks" naming
  confusion (Braaksma, §4) — both real, both cited, neither is the phrase itself.
- **The Petricek & Syme paper's formal typing-rules section (their §3.2) and full worked
  applicative/monad-transformer proofs** could not be extracted with confidence. No PDF-rendering
  tool (`pdftotext`, `poppler-utils`, `PyPDF2`, `fitz`) was available in this environment; a
  hand-written content-stream decompressor recovered the running prose (quoted in §0 and §3 with
  ligatures manually restored and flagged) but the paper's code examples are set in a font whose
  character codes did not decode to plain text with the tooling available, so those specific
  formulas are not reproduced verbatim here — the equivalent formal rules were instead sourced from
  the F# language specification itself (§2.1), which is authoritative for the shipped language in a
  way a 2014 academic paper, however foundational, is not.
- **A first-impressions account from a developer evaluating F# for the first time**, as distinct
  from library maintainers and compiler-team members. Everything found in §5 comes from people
  already deep in the F# or Fable ecosystems; no comparably-sourced "newcomer's first week with
  computation expressions" account was located before the search budget ran out.
- **Whether beni's hypothetical loop-native `For` equivalent has ever been requested or rejected in
  beni's own design history.** Out of scope for direct verification here since it concerns a
  decision beni has not yet made; §6 states this as a structural consequence of beni's current
  expression-only grammar rather than a historical fact about a rejected proposal.
