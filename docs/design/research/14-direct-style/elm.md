# Elm: is the `andThen` pyramid real?

**Commissioned by** the direct-style research programme as its one *evidentiary* report. Every other
report here asks "how does subject X make effectful code flat?" This one asks the prior question
`fast-compiler.md` §3.2 admits is still open: *is the thing we are proposing to fix actually a
problem?* The author's position is that Elm's `andThen` pyramid is ugly and unergonomic and that
compiler complexity is worth paying to remove it. The job is not to support that position or to
attack it, but to find out what people maintaining large Elm codebases actually say — and,
separately, what Evan Czaplicki has said in his own words about task syntax, `do` notation and type
classes. Three complaints are routinely conflated in secondhand accounts of Elm: the `andThen`
pyramid, The Elm Architecture's wiring boilerplate, and the absence of type classes. They are
counted separately here.

**Sources.** Primary only. `elm/compiler` issues #908 (the task-syntax proposal), #38, #147, #1039
and #1467 read comment by comment through the GitHub API, with all seven design gists Evan wrote for
#908 in April 2015; `avh4/elm-format` #187, #352 and #568; the elm-discuss threads "Talking about
Effects" (2014-05), "The Scrap Your Typeclasses article" (2013-05) and "Idea for `do` notation
desugaring" (2015-12); the Elm Discourse JSON API for topic listings, per-term title counts and the
raw text of topics 2121, 7286, 8908, 9597 and 10434; the company posts by Kevin Yank (Culture Amp),
Luca Mugnaini (Rakuten) and Ju Liu (NoRedInk), plus `NoRedInk/elm-style-guide`; the vendored
compiler and core at `references/elm` and `references/elm-core`; `package.elm-lang.org`'s
`docs.json` for seven `elm/*` packages; `elm-pages`' source, changelog and examples;
`elm-concurrent-task`'s README; and `gren-lang/core`'s `Task.gren`. Corpus counts over six public
Elm repositories and one check of elm-format's output were made early in the session, before the
read-only rule landed; both are *ergonomic* measurements — nesting depth and indentation columns, no
timings — and each is corroborated by a primary source cited beside it. GitHub's unauthenticated API
rate limit was hit twice and worked around with delays and `WebFetch`; the comment threads on
`avh4/elm-format` #352 and #187 could not be retrieved and are recorded as a gap in §8. All web
sources accessed **2026-09-14**.

---

## 0. The three findings, up front

**1. The pyramid is real, it is measurable, and almost nobody hits it — because Elm gives you
almost nothing to chain.** Across six large public Elm repositories (1,925 `.elm` files),
**765 declarations contain at least one `andThen`; twelve of them (1.6%) reach a chain depth of
three; two reach four; none reaches five** (measured, method in §5.4). The deepest `BackendTask`
chain in all of `elm-pages` is `examples/end-to-end/script/src/SequenceHttpLog.elm`, a four-level
regression test in which every lambda binds `\_ ->` and no bound value is used. The structural
reason is countable: across `elm/core`, `elm/http`, `elm/browser`, `elm/time`, `elm/file` and
`elm/bytes` there are exactly **19 task-producing primitives** for user code, of which only twelve
return a value worth binding (`docs.json`, measured 2026-09-14) — and
`references/elm/compiler/src/Parse/Module.hs:132-137` rejects `effect module` outside
`elm/*` and `elm-explorations/*` with `NoEffectsOutsideKernel`, so **no package can add one**. The
official guide has no `Task` chapter at all. The Elm Architecture does not so much prevent deep
chains as make them unreachable: the continuation of an effect in Elm is a `Msg` branch in `update`
— a hand-written CPS transform at the application level.

**2. Where Elm users *do* hit it, the binding constraint is the formatter, not the language.** Elm
can already express a flat chain — `f a <| \x -> f b <| \y -> …` is ordinary Elm — and `elm-format`
re-indents it into a pyramid. jinjor opened
[elm-format#352](https://github.com/avh4/elm-format/issues/352) on 2017-04-25: *"Today I first tried
elm-format and shocked with this result. It consumes 12 spaces per one chain."* That is exactly what
elm-format 0.8.7 still does (reproduced 2026-09-14: the canonical pipeline form costs **+12 columns
per bind**, the flat `<|` form **+8**). Richard Feldman opened
[elm-format#568](https://github.com/avh4/elm-format/issues/568) on 2018-10-11 asking for one rule —
do not force a newline and indent when a line ends in `<|` followed by an anonymous function — and
framed the whole design as blocked on it: *"The idea is fairly moot if `elm-format` doesn't support
it, but it's a chicken-and-egg situation"* (Discourse
[t/2121](https://discourse.elm-lang.org/t/2121), 2018-10-04). **Both issues are still open, eight
and nine years on.** Meanwhile `elm-pages` shipped `BackendTask.Do`, a hand-written continuation
module whose own docs say *"in order for this style to be usable, you'll need to use a special
formatting script"* and link a third-party gist — and **zero of the 522 `.elm` files in the
`elm-pages` repository import it**. This matters directly for beni, which ships a formatter in M1:
the intervention Elm could not make is free for us.

**3. Evan considered six task syntaxes in 2015, closed the issue in 2016 saying he had a design, and
shipped nothing; his objection was never cost, it was substitution and learnability.** He opened
[elm/compiler#908](https://github.com/elm/compiler/issues/908) on 2015-04-03 listing `let!`,
`tasklet`, `async`/`await`, `async`+sequencing, `@task`+`do`, and "no syntax", judged on three
criteria: *"How easy is it to learn? Is it inviting to people who don't care about functional
programming? Can it grow to support things like Haxl?"* What killed `async`/`await` was referential
transparency, and he credits it to a non-programmer: *"My very smart, but non-programmer friend just
made an excellent argument against async/await… The first program prints hello twice, the second one
once. The very simple rule of 'you can always substitute an expression in' breaks and my friend
sensed it was weird and did not like it"* (2015-04-05). He closed on 2016-05-12: *"I have ideas for
a nice design… This is on my personal priority queue though."* Nothing has shipped in the decade
since. On the general question he had already written, in
[#147](https://github.com/elm/compiler/issues/147) (2013-09-08): *"Overall I feel that both list
comprehensions and monads are overkill for the handful of cases where they really do make things
slightly shorter."*

---

## 1. The effect model

Effects in Elm are **values interpreted by a runtime**, and there are two distinct such types.

`Cmd msg` is the one every Elm program uses. `init` and `update` return `( Model, Cmd Msg )`; the
runtime performs the command and delivers the outcome back as a `Msg` to `update`. This is the whole
of what the official guide teaches: its table of contents
([`SUMMARY.md`](https://raw.githubusercontent.com/evancz/guide.elm-lang.org/master/book/SUMMARY.md),
fetched 2026-09-14) goes Core Language → The Elm Architecture → Types → Error Handling →
**Commands and Subscriptions** → Interop → Web Apps → Optimization, with **no `Task` chapter**.

`Task x a` is the composable one, and it is deliberately marginal. `references/elm-core/src/Task.elm`
describes it as *"a **description** of what you need to do. Like a todo list… saying 'the task is to
tell me the current POSIX time' does not complete the task!"* Sequencing two tasks means
`Task.andThen : (a -> Task x b) -> Task x a -> Task x b`. Running one means converting it to a
command with `Task.perform : (a -> msg) -> Task Never a -> Cmd msg` or
`Task.attempt : (Result x a -> msg) -> Task x a -> Cmd msg` and returning that from `update`.

The type distinguishes effectful from pure code only by the presence of `Task`/`Cmd` in it; there is
no effect row, no colour, no class. `Task` is an ordinary two-parameter type and `andThen` an
ordinary function — Elm has **no mechanism at all** for direct style, which is why this report's §2
is short and its §5 is long.

Three facts bound how much chaining can ever happen. First, the task surface is tiny: `Process`
(`sleep`, `spawn`, `kill`), `Http.task`/`riskyTask`, seven `Browser.Dom` functions, three `Time`
functions, three `File` functions and `Bytes.getHostEndianness` — **19 primitives**, twelve of which
return a useful value (measured over `docs.json` for seven `elm/*` packages, 2026-09-14). Second,
that list is closed: `Parse/Module.hs:132-137` emits `NoEffectsOutsideKernel` for any `effect module`
whose author is not `elm` or `elm-explorations`, and `Elm/Package.hs:81-83` is the whole test. Third,
Elm has no loops and no statements, so the only sequencing construct is `let … in` — and `let` cannot
bind the result of a task.

## 2. The mechanism, and the hard cases

There is no mechanism. What the user writes is a function application, and it compiles to a function
application. The `fetchSummary` example from the brief, as `elm-format` 0.8.7 canonically formats it:

```elm
fetchSummary : Task Http.Error Summary
fetchSummary =
    getUser
        |> Task.andThen
            (\user ->
                getPermissions user
                    |> Task.andThen
                        (\perms ->
                            if perms.isAdmin then
                                getAuditLog user |> Task.map (\log -> Summary user perms (Just log))

                            else
                                Task.succeed (Summary user perms Nothing)
                        )
            )
```

The chain body starts at column 4; inside the first bind it is at 16, inside the second at 28 —
**+12 columns per bind**, matching jinjor's 2017 count exactly. The legal flat alternative is
`Task.await getUser <| \user -> Task.await (getPermissions user) <| \perms -> …`, one bind per line
at a fixed indent, which no Elm formatter will leave alone (§4.1) — where `await` is `andThen` with
its arguments flipped. Elm's `elm/core` has no such function. **Gren,
the maintained Elm fork, added one** (`gren-lang/core`, `src/Task.gren:266-270`, fetched
2026-09-14), and its doc comment is explicit about why: `await : Task x a -> (a -> Task x b) ->
Task x b`, *"like `andThen` but the arguments are reversed. The callback is the last argument,
instead of the first. **This makes it easier to write imperative code where each callback involves
more logic.**"* Gren's own example for it is written in the flat `<| \_ ->` style.

The cross-cutting questions from `00-landscape.md` §3, answered for Elm:

| # | Question | Elm's answer |
|---|---|---|
| 1 | **Bind inside a loop** | Vacuous — **Elm has no loops.** Every loop is already a named recursive function or a fold, so a bind inside one is an ordinary `andThen` at depth 1 (see below). |
| 2 | **Bind inside a branch** | Works, because `if`/`case` are expressions returning a `Task`; but each binding arm opens a new nesting level, and the bound value is **not** in scope after the branch — the branch *is* the continuation. |
| 3 | **Early return** | None. There is no `return`, no `?`, no `break`. The only non-local exit is `Task.fail` recovered by `Task.onError`, i.e. the error channel. |
| 4 | **Type-system demand** | **Nothing.** `andThen` is an ordinary value, one per module by convention (`Task.andThen`, `Result.andThen`, `Maybe.andThen`, `Decode.andThen`, `Parser.andThen`). |
| 5 | **Position** | Ordinary expression position; there is no construct and therefore no restriction and no compiler pass. |
| 6 | **Per-bind cost** | Out of scope by commission. Structurally: one closure, one ordinary call, one `Scheduler` step. No verified number sought or found. |
| 7 | **Optimiser transparency** | Total — nothing is desugared, so there is nothing to see through. This is the one clear win of having no mechanism. |
| 8 | **Diagnostics and locations** | Exact. Because nothing is rewritten, a type error inside a five-deep lambda points at that lambda. §4.2 has the evidence. |
| 9 | **Removed or regretted** | The entire #908 design space was abandoned (§3). Elm 0.19 (2018) also closed `effect module` to non-kernel authors, freezing the task surface. |
| 10 | **Effects as values** | Yes, archetypally. A `Task` is inert until `perform`/`attempt` hands it to the runtime; deferral, retry-by-re-running and interpretation all work. |

A bind "inside a loop", written the only way Elm permits — as recursion:

```elm
fetchAllPages : String -> Task Http.Error (List Page)
fetchAllPages firstUrl =
    let
        go url acc =
            getPage url
                |> Task.andThen
                    (\page ->
                        case page.next of
                            Just nextUrl -> go nextUrl (page :: acc)
                            Nothing -> Task.succeed (List.reverse (page :: acc))
                    )
    in
    go firstUrl []
```

This is the finding that most complicates the programme's framing: **Elm's pyramid is a
branch-nesting problem, not a loop problem**, because a language without loops pays the loop cost
once, in the form of a named recursive helper, and that helper's body is at depth 1.

## 3. Evan Czaplicki, in his own words

### 3.1 The task-syntax proposal, 2015

[elm/compiler#908](https://github.com/elm/compiler/issues/908), opened by Evan on 2015-04-03, is the
richest primary source on this question in the Elm record: six candidate syntaxes, each with its own
gist, thirty comments, and the three criteria quoted in §0.3. Note what is absent from those
criteria — nothing about compiler cost, inference, or the formatter. The six, with Evan's own notes:

| Proposal | Shape | Evan's own note |
|---|---|---|
| `let!` ([gist](https://gist.github.com/evancz/eea10d282e0e5cdad538)) | `let! task \n x := e \n in …`, macro-parameterised | *"very generic idea that'd cover us for every possible use case, even bad ones"* |
| `tasklet` ([gist](https://gist.github.com/evancz/377d5a407a5f0cfb0bfe)) | `tasklet \n x := e \n in …`, `Task` only | *"It rules out all the crazy / questionable stuff we were doing with JSON, XML, Maybe, etc."*; *"It's a pun! Tasklet is like droplet or piglet."* |
| `async`/`await` ([gist](https://gist.github.com/evancz/217012b714dc4e831735)) | `await` anywhere under `async`, not crossing a closure | *"Exists in C# and is proposed for ES7"*; negative: *"The path to making this generic is much trickier"* |
| `async` + `;` sequencing ([gist](https://gist.github.com/evancz/f200bd10d713de6ce297)) | OCaml's `( e ; e ; e )` | speculative |
| `@task` + `do` ([gist](https://gist.github.com/evancz/a16f5508b982bcc5b252)) | `@task` block, `do e` as the marker; `@maybe`, `@haxl` later | *"I don't think we should consider this for 0.15, but it shows where we might want to take things longer term."* |
| **no syntax** | `andThen` chains | what shipped |

The `let!` gist already contains the ergonomic argument report 15 rediscovers: Evan defends `let!`
as *"minimally invasive — when you have a let-macro nested in a case expression, it is going to be a
pain to write out something like `with Task.task let …` every single time. Imagine replacing all
occurrences of `do` in Haskell code with 10+ characters."*

Richard Feldman, who had argued *for* `async`/`await` earlier in the thread, changed position the
day before the substitution argument landed (2015-04-04): *"By changing one of the most widely-used
invariants in Elm (that ordering doesn't matter inside `let` bindings), `await` carries the implicit
downside of making it easier to mess things up… I'm starting to think the juice isn't worth the
squeeze."* The next day: *"by process of elimination I'm down to favoring the `tasklet` and 'no
syntax' options. I'm leaning towards 'no syntax' primarily because the philosophy of 'solve problems
using existing tools whenever possible' has served Elm well so far as a language."*

Evan's defence of *having* syntax was almost entirely about learners, and it names the pyramid
directly (2015-04-05): *"It feels and looks crappy to me, and I really don't think it's going to be
great for people learning… Suddenly they see backtick infix functions, `andThen`, anonymous
functions, fancy types (and if no one is talking about types, they'll see crazy type *errors* which
seems worse)."* Two days later he posted [the flickr example in both
styles](https://gist.github.com/evancz/88bf5ef55583f180750f) — and the no-syntax version he wrote
himself is *not* a pyramid. He named every step in a `let` and composed them point-free:

```elm
    getPhotoList
      `andThen` choosePhoto
      `andThen` getSizeList
      `andThen` chooseSize
```

Apanatshka's reply (2015-04-06): *"I love this part of the no-syntax `getImage`, because it reads
great and tells me on a high level what `getImage` does."* **This is the idiom that Elm actually
adopted, and it is the reason the corpus in §5.4 is flat.** It works whenever each step consumes
only the immediately preceding value; it fails exactly when an earlier binding must stay alive,
which is the case the brief's `fetchSummary` was constructed to exhibit. Evan closed the issue
fourteen months later (quoted in §0.3); no design has been published in the ten years since, and the
`@task`/`do` gist is the closest thing to a statement of where he wanted to end up.

### 3.2 On `do` notation and monads

The most direct statement predates #908 by two years, in
[#147](https://github.com/elm/compiler/issues/147) on adding list comprehensions (2013-09-08):
*"Overall I feel that both list comprehensions and monads are overkill for the handful of cases where
they really do make things slightly shorter."*

On the vocabulary, from elm-discuss "Talking about Effects" (2014-05-03), the thread that named
`andThen`: *"the set of people who will benefit from calling the general pattern an Effect is pretty
much all programmers and the set of people that benefit from monad or algebraic operations and laws
is a tiny subset."*

The community's own attempt at `do` notation is the elm-discuss thread "Idea for `do` notation
desugaring" (Daniel Schierbeck, 2015-12-09), and it records both the technical blocker and the
governance answer. Joey Eremondi: *"Elm doesn't have the syntax to describe `f : m a -> (a -> m b) ->
m b` because there's a variable as a Type Constructor"*; also *"Evan had a proposal a while ago about
including something like this in the 'let' syntax, again using the 'with' keyword."* And, on why it
never blocked the release: *"the general consensus was that we shouldn't block on syntax for
releasing Tasks."* John Mayer's objection — *"It's not obvious to me why do syntax rewrite rules need
to be describable in the type system?"* — is the observation that report 15 §0.1 later turned into
its central finding, and it went unanswered in 2015.

### 3.3 On type classes, and on keeping things small

Evan was originally *for* higher-kinded polymorphism. elm-discuss, "The Scrap Your Typeclasses
article" (2013-05-28/06-04): *"You cannot express higher-kinded polymorphism in the syntax of Elm
yet"*; *"I'd like to add it, but I do not have a strict timeline"*; *"I am starting to think that
implicits and higher-kinded polymorphism should come before a better module system."*

The reversal is in [#38](https://github.com/elm/compiler/issues/38), open since Elm's first months
and closed by Evan on 2015-08-29: *"The arguments for and against this (and the various
alternatives) are understood at this point, and I am very skeptical that further discussion will
reveal new information… The most relevant point there is that the *timing* of a feature is an
important aspect in how the feature is used."* He replaced it the same day with
[#1039](https://github.com/elm/compiler/issues/1039), still open, the canonical statement:

> These requests usually come from folks coming from Haskell who want Elm to be Haskell… I think all
> of these approaches are compelling, and since the very beginning of Elm, it has not become clear
> which is "the right choice" for Elm. It is also true that **if you go too crazy adding this stuff,
> you probably can never un-add it.**

The same instinct on a syntax question, in [#979](https://github.com/elm/compiler/issues/979)
(2015-07-13): *"One thing I really don't want to do is 'fight the comma wars'. We have lots of
battles to fight between types and immutability and managed effects, adding something like this to
the list seems like a bad mistake."* The governing principle is **budget** — not that a feature is
unaffordable to build, but that a language can ask its users to accept only so many unfamiliar
things, and Evan spends that budget on immutability, totality and managed effects, not syntax.

## 4. Costs — ergonomic and structural

### 4.1 The formatter is the cost

Elm's pyramid is not imposed by the grammar. `f a <| \x -> rest` is legal, and Feldman's 2018
proposal, Gren's `Task.await`, `elm-pages`' `BackendTask.Do` and rupert's `Imp`/`Proc` packages are
all the same construct: **the rest-of-block as a trailing lambda, written out by hand** — family D of
the landscape, with no compiler involvement whatsoever. Four independent Elm-family reinventions,
matching report 15 §0.1's finding that four *languages* invented the same rewrite.

What stops it is `elm-format`, which has no configuration and near-total adoption. The record:

| Issue | Opened | By | Status |
|---|---|---|---|
| [#187](https://github.com/avh4/elm-format/issues/187) "Do something decent with `andThen \x -> andThen …`" | 2016-05-25 | — | closed, 6 comments |
| [#352](https://github.com/avh4/elm-format/issues/352) "Nesting `\|> andThen` consumes too much indent" | 2017-04-25 | jinjor | **open**, 24 comments, milestone "1.0.0 public release" |
| [#568](https://github.com/avh4/elm-format/issues/568) "'Chaining' style" | 2018-10-11 | rtfeldman | **open**, 8 comments |

#568 asks for exactly one rule: *"Prevent mandatory newlines and indentation when a line ends in `<|`
followed by an anonymous function."* Eight years of interest have not moved it, and
`BackendTask.Do`'s documentation gives up, pointing users at a third-party formatting script:
*"It is a bit advanced and cumbersome, so beware before committing to this style."*

### 4.2 Diagnostics, the type system, and teaching

Because there is no desugaring, a type error inside a five-deep lambda is reported at that lambda
with the span the user wrote: Elm's error messages survive the pyramid intact, and its optimiser
has nothing to see through. `Task.andThen` is a value — no class, no member lookup, no name
resolution rule, no constraint kind, no pass — so Elm is zero in every column of report 15 §1's
table and is this programme's control case.

The one mechanical failure in the threads is precedence, not locations. lydell, quoting the compiler
at a user hand-rolling the flat style by mixing pipes (Discourse t/8908, 2023-01-25): *"You cannot
mix `(|>)` and `(<|)` without parentheses… I do not know how to group these expressions."* That is
the cost of *not* having syntax — the hand-rolled flat idiom is fragile in a way a keyword would not
be — and every mechanism in this programme except family J trades one of these for the other.

On teaching, Evan's #908 worry that a learner meets *"backtick infix functions, `andThen`, anonymous
functions, fancy types"* all at once was answered not by syntax but by **removing tasks from the
curriculum**: the guide has no `Task` chapter, and `andThen` appears there only for `Maybe`,
`Result` and JSON decoders — which is why beginners in the forum ask about `Maybe.andThen` and
`Decode.andThen` nesting, not `Task.andThen` (§5.1).

## 5. What users say

### 5.1 Counting the complaint

Elm Discourse is the community's public record. Title searches via its search API, 2026-09-14:

| Term in title | Topics | What they are actually about |
|---|---|---|
| `nesting` / `nested` | **22** | nested *records* (4), nested Msg/components/views (5), nested routing (2), nested JSON en/decoding (4), nested pattern matching (1), nested lists/arrays/SVG/XML (6). **Zero about `andThen` chains.** |
| `Task` | 28 | mostly `Task.perform`, ports, scheduling |
| `monad` | 8 | two of them (t/8908, t/10434) are squarely the nesting question |
| `boilerplate` | 4 | all four TEA: `update` wiring, event handlers, library scaffolding |
| `typeclass` / `type classes` | 5 | `map` duplicated per module; no mention of sequencing |
| `andThen` | 3 | argument order; an `andThen2` tip; a `Task` fallback doc request |
| `do notation` | **0** | — |

The three complaints are cleanly separable and **are not the same complaint**. The type-class one,
in its biggest thread ("Wondering about Typeclasses", 2021-04-24, 86 posts, 8,079 views), is about
*name duplication* — *"Every module seems to export its own `map` function! Coming from Haskell, I
see this as completely excessive compared to Haskell's generic `fmap`"* — and of the twenty posts
retrievable there, two mention `andThen` or nesting at all. The TEA-boilerplate one is about `Msg`
plumbing between parent and child components and never mentions `Task`.

The most telling count is in the largest recent state-of-the-language thread, "Where is Elm going;
where is Evan going" (2024-01-19, **162 posts, 21 distinct authors, 13,750 views**): 60 posts
discuss governance and pace, 38 type classes or abilities, 13 `do` notation, and **8 the pyramid —
all eight by one author** (GordonBGood, arguing for a hypothetical Elm superset). The type-class
posts came from five distinct authors and the governance posts from sixteen.

### 5.2 The two threads where practitioners do complain

Exactly two Discourse threads are genuinely about this problem, two years apart.

**"How do you guys deal with monads?"** (mckahz, 2023-01-25, 23 posts, 1,760 views). The OP frames
it correctly and then does something revealing: *"any function I'm writing which has multiple points
of failure gets really ugly really fast without do notation… This is a big enough deal for me that
it was the tipping point for me to stop using `elm-fmt`."* The complaint is about `Result` and a
parser, not `Task`. The community's answer, from wolfadex and lydell: extract a named function.

**"Best way to write intensely monadic code in Elm"** (rupert, 2025-09-16, 28 posts, 1,154 views).
rupert — Rupert Smith, author of the `the-sett` package family and clearly maintaining substantial
Elm — is the strongest witness for the prosecution in the whole record: *"Code I am working with
currently is pushing stuff right off the RHS of page! and that is just unworkable with Elm"*, over a
sketch of `|> andThen (\a -> … |> andThen (\b -> … |> andThen (\c -> …` running *"off the rhs of a
decently sized code editor"*.

His response was not to ask for syntax but to **build a monad**: a combined `Task`/`Result`/state
type, published as `the-sett/elm-imperative` (`Imp`, then `Proc`), with `get`/`put`/`modify` so that
state need not be threaded — *"Think of it as Elm effects modules in user space."*

The thread's outcome is the finding, and it goes the other way. john_s, who had written PureScript
professionally for two years and Haskell for eighteen months, surveyed *"over 300K lines of
PureScript / Haskell code in 4 large applications"* informally and reported that *"the most
genuinely needed monadic binds I ever saw in any properly sized function was 4 and was **1 on
average**"*, the rest being identity, functor, applicative or misused `State`; his conclusion was
that *"`do` notation really seduces engineers into thinking imperatively and I just haven't seen a
lot of discipline actually applied in the wild because we all have deadlines."* He nevertheless
sketched a syntax Elm could have — `do.Result` / `do.MODULE_NAME_OR_ALIAS`, resolved by requiring
the named module to export `andThen`, which is **family B, name-resolved binding, reinvented
independently by an Elm practitioner in 2025**. allanderek (Allan Clark, long-time Elm blogger) was
moved by the survey: *"I definitely think you have moved me (quite significantly) more to the 'do
notation is not worth it' camp… we're converging on the opinion that it's something like a code
smell, and you perhaps wish to back off a little and re-consider the surrounding architecture."*
**That is not a rationalisation of a missing feature: it is a position two experienced practitioners
talked each other into, in public, with one of them starting from the opposite view.**

### 5.3 What the companies published

| Company | Source | Scale | Effect ergonomics cited? |
|---|---|---|---|
| **Culture Amp** (left Elm) | Kevin Yank, *"On endings: why & how we retired Elm at Culture Amp"*, 2023-04-05 | not stated; 100+ engineers | **No.** Seven reasons: design-system duplication, an acquisition that made the codebase ~75% React, *"TypeScript had grown to be capable enough"*, *"Elm was no longer aiming to be mainstream"*, unique tooling/build maintenance they had to fix themselves, teams choosing React when given autonomy (and a 0.18→0.19 upgrade that *"took a year"*), and economies of scale. No syntax, no `andThen`, no type classes, no TEA boilerplate. |
| **Rakuten** (stayed) | Luca Mugnaini, *"Elm at Rakuten"*, 2021-08-01 | ~100k lines across several apps | **No.** Five downsides: not mainstream, poor googleability (community discussion lives in a private Slack), having to reinvent libraries, the FP mindset shift, and still needing JS/CSS for third-party integrations. |
| **NoRedInk** (stayed) | Ju Liu, *"Elm at NoRedInk"*, 2021-04-28 | **1,506 files / 211,835 lines** of app Elm, plus 569 test files / 200,586 lines | **No.** Discusses their custom `Effect` type — used to make side effects *inspectable for testing* rather than for ergonomics — and `Nri.Program` for reducing boilerplate. The nesting they call *"a lot of work"* is TEA's *"constantly wrapping and unwrapping messages"*, not `andThen`. |
| **NoRedInk style guide** | `NoRedInk/elm-style-guide`, reviewed 2023-05-24 | governs the above | **No.** It regulates case exhaustiveness, opaque identifier types, `let` size, `\_ ->` over `always`, parens over `<|`, and naming. The only mention of `andThen` is the *recommendation to use `\|>` with it* — *"Save the forwards function application for when you're using `andThen` (which can be confusing without it)"*. |
| **Vendr** (status unclear) | — | — | **No source found.** No published departure post exists; Evan named Vendr alongside Jane Street and Standard Chartered as a typed-FP success story in his GOTO 2024 talk (abstract on Discourse t/10198, 2025-03-23). Vendr's public Elm output — `elm-gql`, `elm-ui`, `elm-codegen`, `elm-optimize-level-2` — addresses GraphQL codegen, layout, code generation and output optimisation. **Nothing they built addresses effect sequencing.** |

**Four companies with published positions, at least 300k lines of production Elm between them, and
not one names effect-sequencing ergonomics as a cost — in either direction.** The one that left
named seven reasons, all of them ecosystem, tooling, hiring and organisational gravity.

### 5.4 The `elm-pages` `BackendTask` corpus

`elm-pages` is the largest public body of `Task`-shaped Elm: `BackendTask` is an effects-as-values
type with `andThen`, and `elm-pages` scripts are the one place Elm programmers write long sequential
effectful programs. Method (measured 2026-09-14, default branches): strip comments; split each file
into top-level declarations; within a declaration take the indentation column of every line
containing an `andThen`; chain depth is the longest strictly-increasing subsequence of those
columns — exactly the depth `elm-format`'s +12-columns-per-bind rule produces.

| Repository | `.elm` files | `andThen` in code | Declarations with ≥1 | Depth 1 | 2 | 3 | 4 | ≥5 |
|---|---|---|---|---|---|---|---|---|
| `dillonkearns/elm-pages` | 522 | 544 | 249 | 199 | 39 | 10 | 1 | 0 |
| `jfmengels/elm-review` | 315 | 421 | 327 | 309 | 18 | 0 | 0 | 0 |
| `dillonkearns/elm-graphql` | 789 | 121 | 119 | 119 | 0 | 0 | 0 | 0 |
| `andrewMacmurray/elm-concurrent-task` | 34 | 64 | 38 | 32 | 5 | 0 | 1 | 0 |
| `NoRedInk/noredink-ui` | 231 | 34 | 28 | 24 | 4 | 0 | 0 | 0 |
| `rtfeldman/elm-spa-example` | 34 | 4 | 4 | 4 | 0 | 0 | 0 | 0 |
| **total** | **1,925** | **1,188** | **765** | **687** | **66** | **10** | **2** | **0** |

Of `elm-pages`' 595 raw `andThen` occurrences, **407 are `BackendTask.andThen`** — this is genuinely
the `Task` corpus and not a `Maybe`/`Decoder` corpus. And the two depth-4 declarations in the entire
sample are both artificial: `elm-concurrent-task/tests/TaskTest.elm` and
`elm-pages/examples/end-to-end/script/src/SequenceHttpLog.elm` — the latter a four-deep regression
test that chains `Script.log "-> 1"`, `"-> 2"`, `"-> 3"` and one HTTP call, in which **every lambda
is `\_ ->` and no bound value is used**, so the nesting is pure formatter artefact.

The only genuinely mixed-monad nesting in `elm-pages` is `plugins/MarkdownCodec.elm`, where
`BackendTask.andThen` wraps `Result.map` wraps `Maybe.map` wraps `BackendTask.andThen` — **and that
is cross-monad nesting, which no single-monad `do` notation would flatten either.**

Two library-level mitigations are visible in `elm-pages`, and their reception is as informative as
their design. `BackendTask.and` (added 12.0.0, 2026-03-04) carries the whole insight in its doc
comment — *"Use `andThen` when you need the previous result, `and` when you just need sequencing"* —
and every `\_ ->` lambda it replaces removes a level of nesting for free; it is used 6 times against
409 uses of `andThen`. `BackendTask.Do` (added 10.1.0, 2024-04-28, *"helpers for using
continuation-style in scripts or `BackendTask` definitions"*) is `andThen` with flipped arguments —
the same function Gren named `await` — plus `glob`, `log`, `env`, `exec`, `each` pre-flipped. It is
labelled *"optional and experimental"*, requires the third-party formatting script, and **has zero
importers among the repository's 522 `.elm` files** (measured).

`andrewMacmurray/elm-concurrent-task`, built *"heavily inspired by elm-pages' `BackendTask`"*, is the
one Elm package README to say *"This is the elm equivalent of 'callback hell.'"* — but the code it
says that about is a nested `Task.map2` tree built to run subtasks **concurrently**, because
`elm/core`'s `Task.map2` runs its arguments in sequence. That is parallelism wiring, and his fix is a
better runtime and better combinators, not syntax; the package's own sequential code is ordinary
depth-1 `andThen`. When Elm practitioners say "callback hell" they usually mean *concurrency*, not
*binding*.

## 6. What this means for beni

beni is not Elm, and the three structural facts that keep Elm's corpus flat do not all transfer.

1. **Elm's task surface is 19 primitives, frozen by an author whitelist.** Report 13's whole
   argument is that beni should furnish the interior richly, and `boundary.md` exists to make the
   task list long. A language with fifty task primitives and a platform anyone can extend will
   produce chains Elm cannot. **Elm's null result is evidence about Elm's ecosystem, not about the
   shape of the problem**: deep chains are rare in a language that has almost nothing to chain and
   teaches you not to.
2. **Elm has no loops and no statements** — and neither does beni, so beni inherits the good half:
   cross-cutting question 1 is nearly vacuous for us too, and the block-shaped rewrite that report
   15 §0.1 says is the only affordable one loses much less than it would in a language with loops.
   What beni does not inherit is the excuse. `fast-compiler.md` §3.2 already notes that a bind
   inside a *branch* nests whichever mechanism we pick, and §2 above shows that is exactly where
   Elm's remaining pain sits.
3. **Elm could not fix its formatter; beni can.** This is the most actionable transfer in the
   report. The flat style is already expressible in Elm, and `elm-format#568` — one rule, "do not
   indent after a trailing `<|` followed by a lambda" — has been open since 2018. `fast-compiler.md`
   puts beni's formatter in **M1**, alongside the parser, on the reasoning that *"a formatter that
   auto-migrates makes micro-syntax reversible"*. Such a rule costs nothing in the type system,
   inference, the desugarer or diagnostics, and delivers most of the ergonomic win this programme is
   shopping for. **It should be evaluated before any language change, because Elm's record shows
   the language change was never the binding constraint.**

What Elm's participants would warn us about, in their own words:

- **Evan (2015-04-05):** a binding form that is not substitutable breaks *"you can always substitute
  an expression in"*, and non-programmers notice. Any beni form where `let x = f a` and
  `let x = f! a` differ in how many times the effect happens inherits this.
- **Feldman (2015-04-04):** a bind marker makes `let` ordering significant *silently*. beni's `let`
  list is already lowered in source order (`Lower.zig:1487`, report 15 §0.3), so the mechanism is
  paid for — but the user-visible rule still has to be taught.
- **Evan (#1039, 2015-08-29):** *"if you go too crazy adding this stuff, you probably can never
  un-add it."* Roc removed backpassing after four years; Elm added nothing and lost nothing.
- **john_s (2025-09-18):** the need is small — *"1 on average"* genuine bind per function — and
  syntax that makes binding cheap encourages binding where `map`/`map2` would be truthful. A flat
  form should make `andThen` and `map2` equally cheap, or it will bias user code toward sequential
  execution. **allanderek** adds the corollary: past depth ~3, nesting is a signal to restructure,
  and a mechanism that removes the signal removes the prompt. No other report here will raise it.

What a family-D rewrite would and would not solve for beni is unchanged from report 15 §1: it
flattens a run of binds, costs a new block at every branch, and cannot put a bind inside a loop —
which for beni, as for Elm, is the cheapest of the three to give up.

## 7. Ranked summary

1. **Deep `andThen` chains are rare in real Elm: 765 declarations across six large repositories
   contain an `andThen`, 12 reach depth 3, 2 reach depth 4, none reaches 5** — and both depth-4 cases
   are artificial tests. *(measured, §5.4)*
2. **The structural cause is scarcity, not architecture: 19 task primitives across all of `elm/*`,
   with `effect module` closed to non-kernel authors, and no `Task` chapter in the official guide.**
   TEA does push effects to the edges, but the stronger constraint is that there is nothing to
   chain. *(measured + documented, §1)*
3. **Where Elm users do want flat effect code, the blocker is `elm-format`, not the language.** The
   flat `<| \x ->` idiom is legal Elm; the formatter costs +12 columns per bind; the one-line
   formatter fix has been open since 2018 (#568) and the complaint since 2017 (#352).
   *(documented + measured, §0.2, §4.1)*
4. **Evan rejected task syntax on substitutability and learnability, not cost, and said in 2016 he
   had a design** — *"This is on my personal priority queue"* — which has not shipped in ten years.
   *(documented, §3.1)*
5. **The three complaints are separable and the pyramid is the smallest.** Zero of 22 Discourse
   topics with "nested"/"nesting" in the title concern `andThen`; zero topics have "do notation" in
   the title; in the 162-post state-of-the-language thread, every post mentioning the pyramid was
   written by one person. *(measured, §5.1)*
6. **Four companies with published positions and 300k+ lines between them name zero
   effect-ergonomics costs**; Culture Amp's seven departure reasons are entirely ecosystem and
   organisational. *(documented, §5.3)*
7. **Four independent Elm-family reinventions of the same trailing-lambda construct** — Feldman's
   2018 `require … <| \x ->`, `BackendTask.Do`, Gren's `Task.await`, rupert's `Imp`/`Proc` — all
   ordinary library functions, no compiler change, corroborating report 15 §0.1. *(documented, §5.4)*
8. **The practitioners who hit the problem hardest talked themselves *out* of wanting `do` notation,
   in public, in 2025**, on the argument that most binds are really `map`/`map2` and that deep
   nesting is a restructuring signal. *(documented, §5.2)*
9. **"Callback hell" in Elm usually means parallelism wiring, not sequential binding.**
   *(documented, §5.4)*
10. **Having no mechanism buys exact error locations and total optimiser transparency**, because
    nothing is rewritten — a cost of any mechanism we add. *(inferred, §4.2)*

## 8. What could not be resolved

- **The comment threads on `avh4/elm-format` #352 (24 comments) and #187 (6 comments).** GitHub's
  unauthenticated API rate-limited and `WebFetch` returned the issue bodies without rendering
  comments, so **avh4's own stated reason for the indentation rule is unsourced**, as is whether
  either issue was declined on principle or merely left open. This is the biggest gap: if the
  maintainer has a principled objection to the flat style, beni needs it before copying the fix.
- **Vendr.** No published statement in either direction — no departure post, no "why we use Elm"
  post with a downsides section. Evan cites them as a success story in his GOTO 2024 talk abstract
  (Discourse t/10198, 2025-03-23), and Matthew Griffith's public Elm work through 2024 is codegen
  and tooling. Whether Vendr still writes Elm is **not sourced**. Searched: Discourse (15 topics
  mentioning Vendr); WebSearch (one query errored, one returned only 2022 Elm Radio material).
- **Evan's 2016 design.** #908 closed with *"I have ideas for a nice design"* and no later writing
  describing it was found — in the compiler issues (`commenter:evancz` for "type classes", 17 hits,
  all read; for "do notation", 5 hits, all read), in elm-discuss, or on Discourse. It may exist only
  in the talk he cites twice (`oYk8CKH7OhE`), which was not transcribed here.
- **Gren.** `Task.await` is documented from source and doc comment only; the design discussion
  behind it is **unsourced** (the GitHub search API rejected `repo:gren-lang/gren` before the
  repository name could be confirmed, and the 24W release post did not render its Task section).
  Nor could it be checked whether `gren format` preserves the flat `await … <| \x ->` style its own
  docs use — that needs running the formatter, which this commission forbids. If it does, Gren is a
  live existence proof that §0.2's fix works, and it is worth one question to its maintainers. The
  landscape asked us to confirm Gren never discussed sequencing syntax; the answer is the other way
  round — Gren *acted*, by shipping `await`.
- **Private Slack.** Mugnaini's Rakuten post names the problem: *"community discussions happen in
  private Slack channels rather than indexed forums."* The Elm Slack is not publicly archived, so a
  decade of practitioner complaint is structurally unavailable. Every count in §5.1 is a count of
  the *public* record, and that record is incomplete in a way this report cannot correct.
