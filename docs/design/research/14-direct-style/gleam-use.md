# Gleam's `use` expression and its JavaScript target

**Commissioned by** the direct-style effect-sequencing programme's landscape report
([`00-landscape.md`](00-landscape.md) §2, family D), which names `gleam-use` Tier 1 as "the cleanest
shipped rest-of-block form, compiling to JavaScript" and directs this report to go deeper than
[report 15](../15-flat-effect-syntax.md) §0.1 and §1, which already established the desugaring rule
and its 44-line cost in Roc's compiler. This report does not re-derive that rule; it reads the design
thread that produced it, the compiler source that implements it today, and what Gleam's own users and
maintainers say about living with it. Per the shared brief, this is ergonomics only — no benchmarks,
timings or allocation counts — and read-only: nothing here was compiled or run.

**Sources.** The full 30-comment design thread at
[gleam-lang/gleam#1709](https://github.com/gleam-lang/gleam/issues/1709) (2022-08-05 to 2022-10-31),
read in full via the GitHub API. The current `use`-handling source read directly from
`raw.githubusercontent.com/gleam-lang/gleam/main`: `compiler-core/src/parse.rs` (`parse_use`),
`compiler-core/src/type_/expression.rs` (`infer_use`, `get_use_expression_call`,
`extract_typed_use_call_assignments`, `UseAssignments`), `compiler-core/src/error.rs` (the four
`use`-specific diagnostic renderers), `compiler-core/src/type_/error.rs` (the four `use`-specific
`TypeError` variants), and `format/src/lib.rs` (the formatter's `use_` function). Two pull requests
read via `gh pr view`/`gh pr diff`: gleam-lang/gleam#3824 ("Desugar use expression", merged into
v1.7) and gleam-lang/gleam#3367 (the LSP "desugar to a lambda" code action). Nine issues and
discussions read via the GitHub API: #1826, #2118, #2824, #3336, #3314, #1740, #2051, #1276, #1864.
Six CHANGELOG.md files (v0.25.0 through v0.30.0) diffed by tag for the `try`-expression removal
timeline; release dates pulled from the GitHub releases API. The v0.25 announcement
([gleam.run/news/v0.25-introducing-use-expressions](https://gleam.run/news/v0.25-introducing-use-expressions/))
and the Gleam Language Tour's `use` page fetched and quoted verbatim. Two practitioner blog posts
(Erika Rowland, undated but referencing post-v0.25 syntax; Agustinus Kristiadi, 2023) and the
official `gleam/result` and conventions-and-anti-patterns documentation. All web sources accessed
**2026-09-14**. Two gaps: no Reddit or Hacker News thread specifically about `use` was found (the
generic search terms return only the announcement itself and unrelated results — see §8), and no
GitHub issue asks for `use` inside a loop body the way #2824 asks for it inside a `case` branch,
which is itself a finding, recorded in §5.

---

## 0. The three findings up front

**1. `use` was invented as a scope problem, not a monad problem, and its design record shows the
team explicitly deciding to not build a Haskell-shaped feature.** The originating issue
([#1709](https://github.com/gleam-lang/gleam/issues/1709)) opens with a `with ... as then { then x =
... }`-style proposal modelled on `do`-notation, and Louis Pilfold's first reply already redirects it:
"A syntax for a trailing lambda without extra indentation seems like it could solve the problem while
being conceptually simpler too" (2022-08-05). Thirty comments and two months of bikeshedding over the
keyword (`with`, `when`, `given`, `where`, `bind`, `yield`, finally `use`) and the binder (`=` vs
`<-`) never revisit that decision. When told independently that Koka's `with` is the same idea,
Pilfold wrote: "It is quite reassuring to discover other languages with the same feature after we
have designed it independently (Roc also has it)" (2022-09-04).

**2. The type system needs nothing, but the *compiler* needs a dedicated code path to keep the error
messages usable, and it took real engineering to get there.** `use` is typed by calling the ordinary
call-inference routine on the desugared call — but the call is tagged `CallKind::Use` and its last
argument `ArgumentKind::UseCallback` (`type_/expression.rs:253-273`) purely so four dedicated
diagnostics (`NotFnInUse`, `UseFnIncorrectArity`, `UseCallbackIncorrectArity`,
`UseFnDoesntTakeCallback`) can be raised instead of the generic type-mismatch and arity errors a plain
call would produce. Before this machinery existed, users hit exactly the confusing errors it was
built to avoid: [#1826](https://github.com/gleam-lang/gleam/issues/1826) (2022-11-02) and
[#3336](https://github.com/gleam-lang/gleam/issues/3336) (2024-06-27) are both reports of a `use` call
through a pipe producing an error that names types the user never wrote.

**3. Gleam considered both an async/await keyword and algebraic effect handlers, and rejected both
in favour of `use` explicitly on the "not another mechanism" argument.** Asked directly for
async/await ([discussion #2051](https://github.com/gleam-lang/gleam/discussions/2051), 2023-03-06),
Pilfold answered: "`use` is a superset of async/await syntax and has all of its advantages, but also
additional advantages of being applicable to other types and functions beyond the promise
combinators." Asked for algebraic effects ([discussion #1740](https://github.com/gleam-lang/gleam/discussions/1740),
2022-08-27), his answer was narrower and unresolved: "I am not yet convinced that effect handlers are
simple enough of an API to fit in Gleam." Effects-as-values were never adopted for JavaScript either:
Gleam's own `gleam_javascript` package wraps native `Promise`, so `use` sequences promises the same
way it sequences `Result` — by generic callback shape, with no interpreter in between.

---

## 1. The effect model

Gleam has no effect type, no `Task`, and (on JavaScript) no colour distinct from what JavaScript
itself imposes. "Sequencing two effects" is not a concept the type system knows about at all: `use`
desugars to an ordinary function call with an ordinary closure argument, and whatever effect the
callee performs — a `Result` case split, a `Promise.then`, opening a file — is exactly what the
callee's own body does. There is no `Monad` class, no effect row, no runtime that interprets a value
later; every "effect" in a Gleam program is either a pure computation returning `Result`/`Option`
data, or, on the JavaScript target, a genuine native side effect or a `Promise`. This is
family J-adjacent for Erlang (native effects, no colour) but not for JavaScript, where the underlying
host still colours `async` functions; Gleam does not add its own colour on top and instead leans on
`use` plus `gleam_javascript`'s promise combinators (`promise.then`, `promise.await`) to write
promise-sequencing code that reads flat, per Pilfold's async/await answer above. The language
"distinguishes effectful from pure code" only informally, by which stdlib function a program calls
(`io.println` is visibly impure; `result.map` is visibly pure) — nothing in a function's type
signature says so, matching the ML-family "explicit at the call site, not in the type" tradition
report 15 places OCaml's `let*` in.

---

## 2. The mechanism

### 2.1 What the user writes and what it becomes

Concretely, per `compiler-core/src/parse.rs`'s own comment block for `parse_use`:

```
// A `use` expression
// use <- function
// use <- function()
// use <- function(a, b)
// use <- module.function(a, b)
// use a, b, c <- function(a, b)
// use a, b, c, <- function(a, b)
```

`use` is parsed only in **statement position**: `parse_statement` special-cases the `use` keyword
before falling through to general expression parsing, so `use` cannot appear as a sub-expression, an
argument, or a `case` scrutinee — only as one line in a block, and (per the Tour) as the block's
final construct, since everything after it becomes its body. The right-hand side must, after parsing,
be a call (`f(a, b)`) or a bare value that is itself a function; `get_use_expression_call`
(`type_/expression.rs:4802`) pulls the callee and its existing arguments apart if it is a call, or
treats the whole expression as a zero-argument callee otherwise — no special case exists for a `|>`
pipe, which is exactly the source of the confusing-error reports in §0.2 and §5.

Type-checking, not parsing, does the actual rewrite. `infer_use` (`type_/expression.rs:802-895`):
takes the statements that follow the `use` line in the same block, prepends any assignments needed to
destructure a non-trivial pattern before `<-` (`UseAssignments::from_use_expression`, which for a
simple `use x <- ...` needs nothing beyond a plain function argument, and for `use Box(x) <- ...`
synthesizes an extra `let Box(x) = _use_assignment0` inside the callback body), wraps the whole thing
in an `UntypedExpr::Fn` node, and appends that closure as a new, compiler-synthesized argument
(`implicit: Some(ImplicitCallArgOrigin::Use)`) to the parsed call. It then calls the ordinary
`infer_call` on the result, tagged `CallKind::Use` for diagnostics (§0.2). The literal example from
the Tour:

```gleam
use a, b <- my_function
next(a)
next(b)
```

becomes

```gleam
my_function(fn(a, b) {
  next(a)
  next(b)
})
```

— textually the same rewrite report 15 gives for OCaml's `let*`, Koka's `with`, and Roc's removed
backpassing.

Since 2024-11 (PR [#3824](https://github.com/gleam-lang/gleam/pull/3824)) the typed AST keeps a
`Statement::Use` wrapper around the produced call, purely so the language server can show better
hover text and offer a "desugar this `use`" code action (PR
[#3367](https://github.com/gleam-lang/gleam/pull/3367)) — but both backends unwrap it immediately:
`javascript/expression.rs` compiles `Statement::Use(_use)` as `self.expression(&_use.call)`, i.e. as
the plain call it always was; before that PR the same line read
`unreachable!("Use must not be present for JavaScript generation")`, because until then the desugaring
had already erased the `Use` node before codegen ever saw it. **The JavaScript backend has never had,
and still does not have, any code specific to `use`.** It sees an ordinary call to an ordinary
function whose last argument is an ordinary arrow function or `function` expression, and emits
exactly that.

### 2.2 What the type system must know

Nothing beyond ordinary function-call inference. There is no trait, no class, no member lookup by
name — the callee is whatever value is written on the right of `<-`, resolved the same way any other
function reference is resolved. The *only* constraint is structural and checked, not declared: the
callee, after any already-supplied arguments, must accept one more argument and that argument's
inferred type must be a function whose parameter list matches the patterns on the left of `<-` in
count. Nothing about "the last parameter is a callback" is written anywhere in a signature; it falls
out of unification once the callback closure is appended and typed like any other argument.

### 2.3 The `fetchSummary` example, faithfully

```gleam
import gleam/result

pub fn fetch_summary() -> Result(Summary, Nil) {
  use user <- result.try(get_user())
  use perms <- result.try(get_permissions(user))
  case perms.is_admin {
    True -> {
      use log <- result.try(get_audit_log(user))
      Ok(Summary(user, perms, Some(log)))
    }
    False -> Ok(Summary(user, perms, None))
  }
}
```

This is exactly the example the shared brief gives, unmodified — Gleam's `use` was the model for it.
The `True` branch needs a new `{ }` block because `use` consumes "the rest of the enclosing block",
and the enclosing block for that arm is the `case` arm itself, not the function body; there is no way
to have the arm's `use` bind `log` and then have code *after* the `case` see it, matching report 15's
Question 2 answer for every family-D mechanism.

### 2.4 The loop example

There is no syntax for a bind inside a loop body. The idiomatic rewrite is exactly what report 15
predicts for family D — reach for a fold, or for recursion, which is the native Gleam idiom given the
BEAM heritage:

```gleam
import gleam/list
import gleam/result

pub fn fetch_all(ids: List(Int)) -> Result(List(User), Nil) {
  list.try_map(ids, fn(id) {
    use user <- result.try(get_user(id))
    Ok(user)
  })
}
```

Here `use` works *inside* the callback `list.try_map` passes to each element, because that callback
is itself a fresh block — but it cannot span iterations: there is no way to write one `use` line that
binds a value from iteration *i* and have iteration *i+1* see it, because "the rest of the block" ends
when the anonymous function passed to `try_map` returns. A hand-written loop over `Ok`/`Error`
accumulation must be written as an explicit recursive function or a `list.fold`, not as a flat
sequence of `use` lines — this is stated as fact by report 15 (family D, "a bind inside a loop is not
expressible") and no Gleam issue disputes it (see §5).

### 2.5 Other hard cases

- **Pattern matching on the bound value.** Works directly: `use Box(x) <- ...` is legal and
  desugars via the synthesized-argument-plus-`let` shown in §2.1. Type annotations were added later
  (`use x: Int <- ...`,
  [#1864](https://github.com/gleam-lang/gleam/issues/1864)) and are threaded through the same
  `UseAssignment` struct.
- **Early return from the middle.** Not applicable — Gleam has no early return at all (by design,
  per the v0.25 announcement's list of deliberately omitted features), so this question does not
  arise for `use` specifically; a `use` line simply *is* the point past which the rest of the block
  is conditional on the callee invoking its callback.
- **Mixing two effect types (`Result` inside `Promise`).** Handled by nesting two different `use`
  lines bound to two different combinators in the same block (`use x <- promise.await(...)` then
  `use y <- result.try(...)`), each independently typed; there is no unifying "effect" concept to
  reconcile, which is also why it costs nothing extra in the type system — see §1.
- **Error propagation.** Is exactly what `result.try` already does (case-split, return `Error` early,
  call the continuation only on `Ok`); `use` contributes no propagation semantics of its own, only
  flattening.

---

## 3. History and decisions

**2022-08-05.** [lucasavila00](https://github.com/lucasavila00) opens
[#1709](https://github.com/gleam-lang/gleam/issues/1709), inspired by discussion #1708, proposing a
`with X.then as then { then x = ... }` block modelled visibly on Haskell/F# `do`/computation-expression
syntax and requiring the compiler to track that `then` "has become a special keyword once the syntax
has been defined." Pilfold's first reply reframes the goal around three questions still visible in
the final design: ease-of-learning, parsing cost, and "the contract" — "I think they could also be
value in having a more flexible interface that offers little restrictions beyond the function taking
a function as the final argument" — explicitly rejecting a Haskell-style typeclass contract before
any alternative syntax is even chosen.

**2022-08-05, same day.** Hayleigh Thompson (hayleigh-dot-dev) pushes back on a `with x` /
"succeeding-keyword" shape on two grounds that read as UX predictions and were later vindicated by
issue traffic: it invites re-indentation ("Of course the formatter or whatever could just flatten the
nesting but I think it's still worth pointing out"), and binding on the right of the keyword is easy
to miss when scanning ("I think it might be easy to miss that `x` is now bound and in scope"). She
proposes matching Gleam's existing binders instead: `with x <- result.then(...)`.

**2022-08-05 – 2022-10-31.** Keyword bikeshedding: `with` (rejected — collides with existing label
usage and reads like a Python context manager, per lucasavila00: "it resembles python context
managers, and what's implemented with it in python won't play well with async code"), `when`, `given`,
`where`, `bind` (rejected by Pilfold explicitly to avoid inviting Haskell comparisons: "I'd like to
avoid any direct comparisons to Haskell as there is a lot of confusing information there"), `yield`
(the working name for over a month, defended by Pilfold as "it yields control of the block to the
previous expression" but eventually dropped once someone points out `with` and `yield` were both
already used as labels in stdlib code — "Seems that `with` is used quite a lot in labels so it would
be a good amount of work to change them all"), finally **`use`**, argued for by timjs on grounds of
family: "I'd still vote `use` to match the other three letter verbs used for binding in Gleam (`let`
and `try`)." Binder syntax settles on `<-` over `=` for two stated reasons from Pilfold: it signals
"more is happening than just a regular assignment," and `=` reads oddly with zero arguments
(`use = log.span(...)`). A proposal to drop the binder for pattern-only readability
(`use something ...`) is rejected by Pilfold on parser-ambiguity grounds: "It would introduce parser
ambiguities which mean we could never use patterns rather than raw variable names."

**2022-10-27.** Pilfold states the plan to retire the older, `Result`-only `try` expression once `use`
lands: "I think there's a good chance we'll remove `try` if `use` works out well." This is exactly
what happened: `try` is deprecated in **v0.27.0** (released 2023-03-01, per the GitHub Releases API)
with an automatic migration (`gleam fix`) and fully removed in **v0.28.0** (2023-04-03) — thirteen
months after `use` shipped. It is the one piece of syntax `use` is documented to have directly
replaced.

**2022-11-24.** `use` ships in **v0.25.0**
([announcement](https://gleam.run/news/v0.25-introducing-use-expressions/)). The announcement states
the trade-off in the designer's own words, unprompted: *"The trade off here is that it is less
immediately obvious what `use` does to a newcomer. We have introduced some additional complexity to
the language, but we think this additional learning requirement is a worthwhile trade for the better
developer experience, and Gleam is still a small language compared to most."*

**2024-11-12 – 2024-11-21.** PR [#3824](https://github.com/gleam-lang/gleam/pull/3824) moves the
desugared call's provenance into the typed AST (`Statement::Use` wrapping the call) so the language
server can offer a "desugar `use` to a lambda" code action and better hover information — a purely
tooling-motivated change, four years after `use` shipped, that touches type inference, the AST, both
codegen backends (to strip the wrapper again) and adds seven new LSP snapshot tests. This is the
clearest evidence that the original "it's just sugar, nothing to it" framing understated the ongoing
maintenance cost of keeping a construct legible to tooling once it exists.

**Alternatives considered and not adopted, outside the original thread.** Async/await as a keyword
(discussion #2051, 2023, rejected: "would unfortunately not remove the function colouring problem,
instead it would likely make it worse... making it possible for function colouring to infect the
Erlang target too"); algebraic effect handlers (discussion #1740, 2022, left open, not rejected but
never adopted: "I am not yet convinced that effect handlers are simple enough of an API to fit in
Gleam"). Both are family H/F territory this programme studies elsewhere (Koka, Effekt, C#); Gleam
looked at both and chose neither.

---

## 4. Costs — ergonomic and structural

**What it forces the user to restructure.** Every branch that needs to bind and continue must become
its own block (§2.3); every loop that needs to bind must become a fold or a named recursive function
(§2.4). Both are accepted as permanent, not "not yet implemented" — no issue proposes fixing the loop
case, and the one issue proposing a fix for the branch case
([#2824](https://github.com/gleam-lang/gleam/discussions/2824)) was closed by Pilfold pointing out
`use` "doesn't have any particular semantics, it's just sugar for a function call" and therefore
cannot special-case a no-op — the genericity that makes `use` cheap to add is the same genericity that
makes a conditional variant of it impossible to define.

**What it does to error messages.** Two shipped bugs (#1826, #3336) show the naive failure mode: a
`use` right-hand side that goes through a pipe (`input |> use_test`, `list.range(1, 10) |> list.each()`)
produces an arity or type error that names a synthetic curried type the user never wrote, because
`get_use_expression_call` only recognises a bare call, not a pipe ending in one. Pilfold's own
diagnosis of the second report: "Use does not have a special case for the pipe operator, it always
behaves consistently with anything on the right hand side" — a deliberate simplicity choice with a
real readability cost the reporter (yoshi-monster) pushed back on before Pilfold agreed it was a
compiler bug worth fixing (2024-07-25). Where the callee is not a two-or-more-argument function at all,
the compiler now raises one of four dedicated diagnostics built specifically for `use`
(`NotFnInUse`, `UseFnDoesntTakeCallback`, `UseFnIncorrectArity`, `UseCallbackIncorrectArity` —
`compiler-core/src/type_/error.rs:521-568`), each rendered with an explanation in prose and a link to
the Tour's `use` page (`compiler-core/src/error.rs:4700-4900`), e.g. for `use <- io.println`: *"The
function on the right hand side of `<-` has to take a callback function as its last argument. But the
last argument of this function has type: ... See:
https://tour.gleam.run/advanced-features/use/."* This is real, non-trivial compiler investment
purely to keep the error surface of a "purely syntactic, nothing for the type system" feature
legible — the cost moved from the type system (zero) to the diagnostics code (four bespoke error
paths, a `CallKind` enum, an `ArgumentKind` enum, and stacker-based stack growth for deeply chained
`use` to avoid a stack overflow, added for
[#4287](https://github.com/gleam-lang/gleam/issues/4287) and visible directly in `infer_use`'s
`stacker::maybe_grow` call).

**What it does to tooling.** The formatter needed a dedicated pretty-printer (`format/src/lib.rs:3449`,
`fn use_`) and had a real, shipped regression: v0.28.0's formatter spliced a comment written *above*
a multi-line `use` line into the *middle* of it
([#2118](https://github.com/gleam-lang/gleam/issues/2118), fixed same day it was reported, 2023-04-10)
— evidence that comment attachment around a construct whose "body" is implicit (everything after it,
not a delimited block) is easy to get wrong even for the construct's own authors. The language server
grew a "desugar `use`" code action (#3367, #3824) specifically because reading what a `use` chain
expands to is not obvious from the source alone — the inverse of a construct being "immediately
obvious," which is Pilfold's own stated trade-off from the announcement.

**What it demands of the compiler pipeline.** The desugaring lives entirely in the type-checking pass
(`infer_use`), not the parser and not a separate desugaring pass before inference — it is interleaved
with ordinary call inference so it can reuse `infer_call` and its error paths (§2.1, §4). This differs
from Roc's removed backpassing, which report 15 shows desugared in the parser/AST stage before any
type information exists. Gleam's placement is why its diagnostics can say precise things about the
type mismatch (§4, above) — but it also means `use` cannot be desugared, checked or reasoned about
independently of full inference, which matters for a language server wanting to show "what does this
expand to" without a full compile (motivating the later, separate LSP desugaring logic in #3367 that
duplicates the *untyped* shape of the rewrite outside the type checker).

**What newcomers get wrong.** No study or survey was found; the direct evidence is the volume and
content of design-thread comments themselves, all from experienced contributors debating the design,
not newcomers using it. The clearest first-person account of a newcomer surprise is in the original
issue: a first-time proposer of the `<-` binder direction (schurhammer) and Pilfold both worried aloud
about right-to-left readability ("It is unfortunate that the `then` sort-of reads backwards now") —
a concern about the shipped syntax's readability that predates any user encountering it, not a
newcomer report after the fact. Question 6 (per-bind and per-call cost on JavaScript) is **out of
scope** per the shared brief and the project owner's ergonomics-only instruction; it is not addressed
here.

---

## 5. What users say

Evidence is thin relative to Elm or Rust: `use` generates almost no adversarial discussion, and what
exists is mostly the maintainers' own bug reports and fixes (§3, §4), not third-party commentary. Of
the material found:

**Praise.** Erika Rowland's practitioner post lists three contexts where `use` helps: focusing on
"the unwrapped `id` in the success case" for error handling, avoiding "cascading function calls" for
chained `result.map`, and letting a reader "focus on the query we want to write, not on database
management" for setup/cleanup. Agustinus Kristiadi's post frames `use` as a `with`-statement analogue
for resource management and a `?`-operator analogue for error propagation, with no complaints
recorded. Neither is a large-codebase retrospective; both are single-author technical blog posts
evaluating the language, not maintaining a production system with it — the shared brief's distinction
between "maintaining" and "evaluating" cannot be drawn crisply here because no maintainer account was
found (see §8).

**Complaints.** Rowland is explicit about the one place `use` degrades readability: with
`list.map`, "it's no longer clear that I'm writing a callback function," and code after the mapped
operation cannot run without nesting it inside the callback — the same "must open a new block"
cost as §2.3, reported from the outside rather than the design thread. The official conventions
document independently names one anti-pattern combination: `use <- bool.guard(...)` immediately
followed by `let assert Ok(value) = data` is flagged **bad** because it throws away exhaustiveness
checking, versus the endorsed **good** pattern, `use value <- result.try(value)` followed directly by
`process(value)`. This is the one place Gleam's own documentation states which combinator `use`
should and should not be paired with — `result.try` is idiomatic, `bool.guard` plus a manual assert
is not, and `list.each`/`list.map` are usable but read worse for exactly the reason Rowland gives.

**Wishes.** The one substantive feature request, discussion #2824 ("Conditional `use`"), asks for
`use` to appear inside individual `case` branches without opening a new block — closed without being
implemented, on Pilfold's genericity argument (§4). No open issue or discussion asks for `use` inside
a loop; searches for "use" combined with "loop", "for loop", or "fold" (in title or body, via GitHub's
search API) return no proposal to make `use` loop-capable, only unrelated `fold`-adjacent bugs and
one closed 2024 discussion about extracting a fold into a named function via a *different* code
action. **That the branch limitation drew a discussion thread and the loop limitation drew none is
itself the finding**: Gleam's community appears to treat "reach for recursion in a loop" as
unremarkable — consistent with the language's BEAM heritage, where named recursion is the default
looping idiom regardless of `use` — while "I can't bind and continue past a `case` arm" reads as
surprising enough to ask about.

**Count.** Given the search budget, no basis exists for "N of the top-M threads" the shared brief
asks for; the corpus found is five GitHub threads, two blog posts and one design-thread issue, not a
ranked or exhaustive set of community discussion. This absence — not a manufactured count — is
reported per the brief's instruction to say "users mostly do not talk about this" when that is what
the evidence shows.

---

## 6. What it would take to do this in beni

beni's `let`-binding-list-as-statement-sequence (`fast-compiler.md`'s "Flat effect syntax" section,
citing `Lower.zig:1487`) already gives beni something Gleam's block-based statement sequence gives
Gleam, so a `use`-shaped mechanism is, in the narrow sense, cheaper to add to beni than it was to add
to Gleam: Gleam had to invent statement-position parsing for a *new* keyword inside an otherwise
expression-light language; beni would attach the same rewrite to an existing binding form.
Concretely, beni would need:

- **A parser rule** recognising `use <pattern>, ... <- <call>` (or a beni-flavoured equivalent) only
  where a `let` binding may appear, mirroring Gleam's parse-time restriction to statement position
  (§2.1) — cheap, matching report 15's "44 lines" baseline for the syntactically identical mechanisms.
- **A desugaring step during or after type inference**, not before it, if beni wants Gleam-quality
  diagnostics (§4): Gleam's choice to interleave the rewrite with `infer_call` is precisely what lets
  it say "the function on the right of `<-` here takes N arguments" instead of a generic mismatch.
  A pre-inference desugar (closer to Roc's dropped backpassing) is simpler to implement but produces
  worse errors, as Roc's own removal history (report 15 §2) documents for a different reason
  (fuzzing, not error quality) but the same trade-off shape.
- **Nothing from the type system.** No class, no row, no HKT — confirming report 15's §0.1 finding
  that this family costs beni's checker zero, which matters because `fast-compiler.md` §3.1 has
  already ruled out typeclasses and HKTs for other reasons.
- **A dedicated diagnostics path** if beni wants to avoid the exact bug class Gleam shipped twice
  (#1826, #3336): a pipeline or partially-applied expression on the right of the bind arrow needs its
  own error message, not the generic "expected N arguments" a plain call-arity check would produce.
  This is the single largest maintenance line item Gleam's history shows for an otherwise
  "free" feature (§4).
- **What it would deliver.** Exactly what Gleam delivers: a flat, `andThen`-free happy path for
  `Result`- or `Task`-returning code, with the same two structural costs — a new block at every
  branch (§2.3) and no expressibility inside a loop (§2.4) — that report 15 already flags as family
  D's defining limitation relative to a state-machine or generator transform. If beni's authors judge
  the loop case important (the shared brief's own `fetchSummary` framing calls it out explicitly:
  "a bind inside a LOOP is expressible with generators and not expressible at all with the syntactic
  rewrite"), a `use`-shaped mechanism does not solve it and Gleam's own history shows no path to
  solving it without abandoning genericity (§4, §5).
- **What Gleam's own designers would warn beni about.** First, do not let the "it's just sugar"
  framing understate the true cost: four bespoke error variants, two enums threaded through call
  inference, a formatter function, an LSP code action, and a stack-growth guard for deep chains all
  exist because a feature with "nothing" required of the type system still accumulates real compiler
  surface area once real programs use it (§0.2, §4). Second, resist adding a second special case (a
  pipe-aware right-hand side, a no-op sentinel for #2824's conditional case) to patch a rough edge —
  Pilfold's answer to both requests was to defend the mechanism's uniformity over the specific
  ergonomic win, and that policy is why the feature has stayed small enough to fully replace `try`
  rather than living alongside it.

---

## 7. Ranked summary

1. **`use` is one call-shaped rewrite, checked as an ordinary function call, with zero type-system
   footprint** — confirmed directly in `type_/expression.rs`; matches report 15's family-D
   classification exactly. (documented)
2. **The "nothing for the type system" claim hides real, ongoing compiler cost**: four dedicated
   error variants, two tag enums (`CallKind`, `ArgumentKind`), a stack-growth guard for chained `use`,
   and a 2024 AST change solely for tooling, four years after ship. (documented)
3. **Gleam explicitly considered and rejected both a native async/await keyword and algebraic effect
   handlers in favour of `use`**, on record from the designer, not inferred. (documented)
4. **The bind-inside-a-branch limitation drew a feature request that was refused on principle
   (genericity over a no-op sentinel); the bind-inside-a-loop limitation drew none at all** — the
   absence itself is evidence users treat looping-by-recursion as the expected idiom. (documented,
   with the loop-silence half being an absence-of-evidence inference, so: inferred)
5. **The two shipped confusing-error bugs (#1826, #3336) share one root cause**: `get_use_expression_call`
   does not special-case a pipe ending in a partial application, "always behaves consistently with
   anything on the right hand side" by design, and that consistency is what produces the bad error.
   (documented)
6. **`use` fully replaced an earlier, narrower `Result`-only construct (`try`)**, deprecated one
   version after `use` shipped and removed the version after that, with an automated migration tool —
   the cleanest evidence in this report that a generic rest-of-block mechanism can retire a
   special-purpose one rather than living beside it. (documented)
7. **No practitioner account of maintaining a large Gleam codebase with `use` was found** — only two
   single-author evaluation posts and the maintainers' own issue trackers; §5's "users mostly do not
   talk about this" is the finding, not a gap in search effort alone. (unverified as to whether such
   accounts exist and were merely not found by this report's search budget)
8. **The formatter needed a dedicated, bug-prone pretty-printer** for a construct whose "body" is
   implicit rather than delimited — the one shipped regression (#2118, comment splicing) was fixed
   the same day it was reported, suggesting the bug class is shallow once found but easy to introduce.
   (documented)
9. **Performance/runtime cost (cross-cutting question 6) is explicitly out of scope** for this report
   per the shared brief and the project owner's instruction; nothing here should be read as a claim
   about `use`'s cost on JavaScript. (not applicable, by design)

---

## 8. What could not be resolved

- **No large-codebase practitioner retrospective on `use`** was found, in contrast to Elm's Culture
  Amp/Rakuten/NoRedInk material the `elm` report can draw on. Searched: WebSearch for "Gleam use
  expression" combined with "reddit", "production", "large codebase", "maintaining"; all returned
  either the announcement itself, the Tour, or the same two blog posts already cited. No Gleam-specific
  subreddit or forum thread surfaced.
- **No count of how often `use` appears with each combinator** (`result.try` versus `bool.guard`
  versus `list.each`) in real code was obtainable without running a search over package sources,
  which the read-only constraint rules out; the ranking in §5 (`result.try` idiomatic, `bool.guard`
  plus assert anti-pattern, `list.each`/`list.map` usable but read worse) rests on the one official
  conventions document and one blog post, not a corpus count.
- **Whether newcomers specifically, as opposed to experienced contributors debating design, get `use`
  wrong in measurable ways** (a stated cross-cutting concern of the shared brief, §4) has no direct
  source: no onboarding study, tutorial-completion data, or "confused beginner" issue thread was
  found. The nearest evidence is designers' own predictions of confusion during the design thread
  (§4), which is not the same claim.
- **Whether `dl.acm.org`-hosted or paywalled academic treatments exist comparing `use` to
  Koka's `with` formally** was not pursued beyond the primary-source design thread and Koka's own
  book, per the brief's exclusion of secondhand summaries and this report's focus on Gleam's own
  designers' words; report 15 and the Koka-specific report in this programme are the fuller source
  for that comparison.
- **The exact wording Pilfold used in any conference talk or podcast** (Changelog #588, Thinking
  Elixir #23, the Serokell interview) about `use` specifically, as opposed to type classes and HKTs
  generally (quoted in §0 via the HKT discussion, which is text, not audio), was not transcribed or
  fetched as audio/video content is outside this report's tooling; the Serokell interview's text
  format was checked and did not mention `use` by name.
