# OCaml binding operators: a scope-resolved rewrite, and what two production monads did with it

**Commissioned by** the shared brief for report 14 and by `00-landscape.md`'s Family B entry, which
asks specifically for PR #1947's rejected alternatives, `and+`/applicative parallelism, and what
`ppx_let` had that the built-in operators dropped. Research 15 §3.1 already established the core
mechanism — `let*` resolves to an ordinary value by lexical scope, at zero type-system cost — and
this report does not re-derive that. It goes to the primary sources research 15 cites only in
summary: the PR discussion itself (86 issue comments, 20 review comments, four sessions of debate
over five months), the two production monads that motivated it (Lwt and Async), and the one
mechanism boundary research 15 does not cover — OCaml 5's effect handlers, which give one of those
two libraries' successor a reason to stop using `let*` at all.

**Sources.** The full comment threads on
[ocaml/ocaml#1947](https://github.com/ocaml/ocaml/pull/1947) and its PR body, fetched via the GitHub
API (86 issue comments, read in full, author and timestamp preserved); the OCaml manual's binding
operators chapter at
[ocaml.org/manual/5.3/bindingops.html](https://ocaml.org/manual/5.3/bindingops.html), fetched and
quoted verbatim; the vendored-equivalent compiler source read directly from
`raw.githubusercontent.com/ocaml/ocaml/trunk` (`typing/typedtree.mli`, `lambda/translcore.ml`) since
OCaml is not vendored in this repository; `janestreet/ppx_let`'s current README; two Jane Street blog
posts (Minsky, 2016 and the "plans for 4.08" post); the discuss.ocaml.org threads "Lwt now has let*
syntax" and "Ppx_let vs. binding operators"; Lwt's own `src/core/lwt.mli` doc comments (read
directly, not summarized); Lwt's GitHub history for the `both` combinator, `Lwt.Syntax`, and PR #776
(fetched via `gh api`, with exact commit SHAs and dates); `ocsigen/lwt#325`; the `lwt_eio` README's
worked migration example; and one Tarides blog post on porting Lwt to Eio. **This session's
WebSearch budget (shared across the research programme) was exhausted partway through**; the
remainder of the research — Lwt's own doc comments, its commit history, `ppx_let`'s exact feature
list, and the effects/Eio material — was completed with direct `curl`/`gh api`/WebFetch calls against
raw source and the GitHub API, which is better provenance than search results but forecloses a
broader discovery sweep of, e.g., blog posts about `let*` from outside the accounts already known to
this research programme. No original measurements were run; this report is read-only per the
project's rule and contains no performance claims. All web sources accessed **2026-09-14**.

---

## 0. The three findings, up front

**1. The fight in PR #1947 was never about `let*` — it was about whether `and*` belongs in a
monad at all, and the two production monads this report covers are the reason it won.** Xavier
Leroy's opening objection was narrow and textbook-correct: *"There is no 'and' in any theory of
monads I know of. […] Could we leave the extra syntax to existing PPXs, for people who can't live
without, and just have basic monads that everyone understands in the core system?"*
([2018-07-31](https://github.com/ocaml/ocaml/pull/1947#issuecomment-408859034)). Leo White's reply
named the cost of following that advice: *"in most useful monads the applicative operations are
cheaper than the monad operations. This is true of: lwt, async, incremental, build monads in Jenga
and dune, monadic parsers etc. Which means that writing efficient code requires you to use `and`"*
([2018-07-31](https://github.com/ocaml/ocaml/pull/1947#issuecomment-408860721)). Yaron Minsky then
supplied the concrete reason it is not just an efficiency footnote: for Jane Street's Incremental,
`let+ x = f a and+ y = g b in x + y` and `let* x = f a in let+ y = g b in x + y` *"have very
different recomputation semantics. […] These are not small efficiencies, but potentially large
changes to asymptotic complexity"* ([2018-07-31](https://github.com/ocaml/ocaml/pull/1947#issuecomment-408895312)).
`and+`/`and*` shipped. §1 and §3 trace what this bought Lwt, eighteen months later, when Lwt itself
had to catch up to the feature it inspired.

**2. The mechanism is a pure, parser-adjacent rewrite to an ordinary function application — there is
nothing for js_of_ocaml (or any downstream pass) to special-case.** `let* x = e in body` becomes a
`Texp_letop` node in the typed tree (`typing/typedtree.mli:291-297`, a value carrying `let_`, `ands`,
`param`, `body`, `partial` — note `partial`, discussed in §2.3), which exists purely so error
messages and `ocamlformat` can see that a `let*` was written. By the time the compiler reaches the
untyped Lambda IR, `lambda/translcore.ml`'s `transl_letop` (lines 1270–1321) has already turned it
into an ordinary `Lapply` of the operator to the bound expression and a synthesised closure — line
for line, the same tree it would build for `( let* ) e (fun x -> body)` written by hand. **The
rewrite happens above the boundary every JS backend or native backend reads from**, so "what
js_of_ocaml emits for a `let*` chain" is not a distinct question with a distinct answer: it emits
whatever `Lwt.bind` (or the monad's own `bind`) compiles to, unchanged.

**3. The ecosystem did not absorb this for free, and one production number survives to describe the
"before".** OCaml's own binding-operator feature landed in trunk 2018-11-27, but Lwt could not
supply an efficient `and+`/`and*` until it grew an efficient pairing primitive — `Lwt.both`, added
[2019-03-21](https://github.com/ocsigen/lwt/commit/d7e23c702c61b3e09258af191dbbcbe46841d45e) — and
did not ship the applicative half of `Lwt.Syntax` until
[PR #776](https://github.com/ocsigen/lwt/pull/776), **seventeen months after the language feature
merged**. That PR's own justification quotes a `git grep` over `mirage/irmin`, a real production
Lwt codebase: **1,480 uses of `>>=` against 347 uses of `>|=`** (craigfe, 2020-04-22) — the closest
this report can get to a measured "what the pyramid looked like" number, and it says the applicative
form was already a fifth of all sequencing before the ergonomic sugar for it even existed.

---

## 1. The effect model

OCaml has no built-in notion of "an effect" in the type system that Lwt or Async use. `'a Lwt.t` and
`'a Deferred.t` are ordinary abstract types — a promise/cell that will eventually hold a value — and
"sequencing two effects" means calling an ordinary higher-order function, `bind : 'a t -> ('a -> 'b
t) -> 'b t`, that a library author wrote by hand against the runtime's own scheduler (`Lwt_engine` /
Async's `Scheduler`). Nothing distinguishes "effectful" from "pure" code beyond this: `'a Lwt.t` says,
by convention and by the shape of the type, "this value is not ready yet" — no effect row, no
capability, no colour enforced by the compiler beyond what an ordinary abstract type gives. A
function can freely discard an `'a Lwt.t` it never binds, silently dropping the callback, and the
compiler will not stop it; Lwt's runtime issues a best-effort warning for this at `Lwt_main.run` time,
but that is a library convention, not a type-system guarantee.

**Binding operators are, precisely, agnostic to all of this.** `let*` does not know that `Lwt.t`
represents a deferred computation; it is resolved by ordinary lexical scoping to whatever value named
`( let* )` is in scope, exactly as `+` resolves to whatever `( + )` is bound to. This is why the
mechanism transfers identically to `option`, `result`, `list`, and any user's own type: nothing in
the parser or typer treats effects as a special case, and nothing prevents `let*` inside a
`Lwt.Syntax` scope from silently meaning something else if the user opened the wrong module — the
concrete complaint research 15 §3.1 already documents ("which `open` am I under?").

OCaml 5's effect handlers (`effect`/`match … with effect e k -> …`) are a genuinely different,
native mechanism — resumable continuations installed by the runtime, not a value bound with `let*`.
**The two do not interact at the language level; they interact only at the ecosystem level**, in the
choice a codebase makes between a promise-returning library (Lwt, Async) that still needs
`let*`/`let+`, and a direct-style library (Eio) built on effect handlers, where a function that "does
I/O" has an ordinary, non-monadic return type and needs no binding operator at all. §3.4 and §6.4
return to this boundary, the one part of this report genuinely about effects rather than `let*`.

---

## 2. The mechanism

### 2.1 What the user writes, precisely, and what it becomes

The manual's grammar (§23, [ocaml.org/manual/5.3/bindingops.html](https://ocaml.org/manual/5.3/bindingops.html)):

```
let-operator ::= let ( core-operator-char | < ) { dot-operator-char }
and-operator ::= and ( core-operator-char | < ) { dot-operator-char }
expr ::= … | let-operator letop-binding { and-operator letop-binding } in expr
```

and the desugaring rule, quoted verbatim:

> "The form `let<op0> x1 = e1 and<op1> x2 = e2 and<op2> x3 = e3 in e` desugars into
> `( let<op0> ) (( and<op2> ) (( and<op1> ) e1 e2) e3) (fun ((x1, x2), x3) -> e)`. This of course
> works for any number of nested `and`-operators."
> — [ocaml.org/manual/5.3/bindingops.html §23.3](https://ocaml.org/manual/5.3/bindingops.html)

For a single binding this collapses to `( let<op> ) e1 (fun x1 -> e)` — an ordinary application of
whatever value `( let<op> )` names. There is no type class, no member lookup: `let*` inside
`Lwt.Syntax` works because `Lwt.Syntax.( let* )` has type `'a Lwt.t -> ('a -> 'b Lwt.t) -> 'b Lwt.t`
and unification does the rest, exactly as it would for a hand-written call. **What the type system
must know (cross-cutting Q4): nothing beyond ordinary name resolution and ordinary unification.**

Below the typer, nothing survives of the special syntax. `typing/typedtree.mli:291-297` gives the
node a distinct shape purely for tooling and diagnostics:

```
| Texp_letop of {
    let_ : binding_op;
    ands : binding_op list;
    param : Ident.t;
    body : value case;
    partial : partial;
  }
```

and `lambda/translcore.ml`'s `transl_letop` (1270–1321) immediately erases that shape: it threads
`Lapply` nodes pairwise for the `and`-chain (1271–1292) and finishes with one more `Lapply` of the
let-operator to the accumulated bindings and a freshly built `lfunction` (1298–1321) — the identical
Lambda tree a hand-written `( let* ) e (fun x -> body)` produces. **This answers the landscape
entry's specific ask about js_of_ocaml output: there is nothing js_of_ocaml-specific to find**,
because js_of_ocaml compiles bytecode built from this same Lambda representation, several passes
downstream of where the rewrite already happened. The cost of the feature is entirely in the parser
and the typer — never in code generation, never in the JS backend specifically.

### 2.2 `fetchSummary`, in OCaml against Lwt

The brief's example, faithfully, using `Lwt.Syntax`:

```ocaml
open Lwt.Syntax

let fetch_summary () =
  let* user  = get_user () in
  let* perms = get_permissions user in
  if perms.is_admin then
    let+ log = get_audit_log user in
    Summary (user, perms, Some log)
  else
    Lwt.return (Summary (user, perms, None))
```

This is cross-cutting **Q2 (branch)** answered directly: the `if` needs no extra block and no extra
indentation level, because `let*`/`let+` are ordinary expressions and `if … then <expr> else <expr>`
already accepts an expression on each arm; the bound values from before the branch stay in scope
inside both arms as ordinary closure variables. This is also where OCaml most directly answers the
brief's Elm complaint: Elm's version needs the `if` *inside* the `Task.andThen` lambda because
`andThen` is a pipeline stage, not a `let`; OCaml's `if` sits at the same syntactic level as the
`let*` chain because `let*` was never a pipeline stage to begin with.

**The mixing-two-effect-types hard case** (`Result` inside `Task`) is solved not by nesting two
`let*`s but by picking a composite monad whose `bind` already threads both layers, and opening its
own `Syntax`:

```ocaml
open Lwt_result.Syntax   (* 'a t = ('a, error) result Lwt.t *)

let fetch_summary () =
  let* user  = get_user () in
  let* perms = get_permissions user in
  if perms.is_admin then
    let+ log = get_audit_log user in
    Summary (user, perms, Some log)
  else
    Lwt_result.return (Summary (user, perms, None))
```

`Lwt_result.bind` short-circuits on `Error` the way `Result.bind` does and waits on the `Lwt.t` layer
the way `Lwt.bind` does, in one function — so **error propagation** (the last item in the brief's
list) is not a feature of `let*` at all; it is a property of whichever monad's `bind` the user opened
`Syntax` from. This is the OCaml answer to why there is no `?` here: the propagation lives in the
monad, and `let*` is indifferent to which monad it is.

### 2.3 Pattern matching on the bound value, and a hard case beni does not have

`letop-binding ::= pattern = expr | value-name` — the manual's grammar permits *any* pattern, not
just a variable, and `Texp_letop`'s `partial : partial` field is precisely the compiler's admission
that this pattern can be refutable. `let* (Ok x) = e in body` type-checks and compiles, with an
ordinary non-exhaustiveness warning and a `Match_failure` at runtime if the pattern fails — the same
contract as an ordinary refutable `let`. This is a capability the OCaml design has that beni's
`let` does not: beni's `LetPattern` is deliberately irrefutable (cited in research 15 §4.2,
`language.md` §7), so a beni bind position could only ever take the patterns `LetPattern` already
takes — a restriction inherited for free, not a new one, and already noted there.

### 2.4 Bind inside a loop

OCaml has no looping construct that produces a value at all — `for` and `while` are `unit`-typed
imperative statements — so **cross-cutting Q1 (loop)** has the same answer for ordinary OCaml code
and for monadic OCaml code: recursion, or a combinator. Lwt's own combinator library supplies the
`_s`/`_p` family (`Lwt_list.fold_left_s`, `iter_s`, `map_s` — sequential; `_p` for the parallel
analogue) for exactly this shape:

```ocaml
let sum_scores ids =
  Lwt_list.fold_left_s
    (fun acc id ->
       let+ score = get_score id in
       acc + score)
    0 ids
```

or, written out as the fold itself, the idiom every OCaml programmer reaches for regardless of monad:

```ocaml
let rec sum_scores = function
  | [] -> Lwt.return 0
  | id :: rest ->
      let* score = get_score id in
      let* total = sum_scores rest in
      Lwt.return (score + total)
```

There is no construct comparable to beni's `question_in_lambda`-style scope check, no `forM_`, and
no special loop syntax for binds at all — the loop-with-a-bind problem is solved once, at the
library level (`Lwt_list`), rather than by the language.

### 2.5 Early return and exception propagation

OCaml has no `return`/early-exit keyword in ordinary functions, monadic or not, so
**cross-cutting Q3** inherits that absence rather than adding to it. What a `let*` chain *does* get,
for free, is that a synchronously raised exception inside the continuation becomes a rejected
promise — not a special case of `let*`, but a documented property of `Lwt.bind` itself, quoted
verbatim from `Lwt.mli`:

> "`f` may finish by returning the promise `p_2`, or raising an exception. […] If `f` raises an
> exception, `p_3` is rejected with that exception."
> — [`src/core/lwt.mli:512-514`](https://github.com/ocsigen/lwt/blob/master/src/core/lwt.mli)

So `raise`, inside any position a `let*`-bound continuation can reach, behaves like an early return
that terminates the whole chain with a failed promise — no `try`/`finally` interaction to special-case,
because ordinary OCaml exception semantics apply directly; `Lwt.catch`/`Lwt.finalize` compose with
it exactly as `try`/`with`/`finally` compose with ordinary exceptions.

### 2.6 Position (cross-cutting Q5)

`let<op>`/`and<op>` are grammatically an `expr` production (`expr ::= … | let-operator …`), so they
may appear **anywhere an expression may** — nested inside a function argument, a record field, an
`if` branch, a `match` arm — with no restriction to statement or top-level position. This is the one
respect in which OCaml's design sits at the "expensive" end of research 15's table (§1): the "where
the marker may appear" column is "anywhere", the same column Roc's abandoned `!` suffix occupied.
The cost that research 15 measured for Roc (a 1,046-line `suffixed.rs` to hoist a marker out of
argument position) does not appear here for a specific, load-bearing reason: **`let<op>` is not a
marker inside an existing expression grammar production that must be rewritten out of place — it
*is* the production**. There is no "unwrap this marker from inside an `Apply`" problem to solve,
because a `let*` is never inside an `Apply`; the parser builds the letop node directly at the point
where the `let` keyword appears, and the "rest of the expression" the continuation closes over is
already, syntactically, everything that follows `in` — exactly the shape `beni`'s existing `let`
already has (research 15 §0.3). This is the deepest reason OCaml's design was cheap to build (per
§2.1) despite having Roc's most expensive position rule.

---

## 3. History and decisions

### 3.1 Before the language feature: `ppx_let`, 2015 onward

Leo White's own framing in the PR body is explicit about lineage: *"The translation chosen is a
generalisation of the one used by [ppx_let](https://github.com/janestreet/ppx_let)"*
([PR body](https://github.com/ocaml/ocaml/pull/1947), 2018-07-31). `ppx_let` predates the language
feature by about three years and is a Jane Street PPX rewriter providing `let%bind`/`let%map` (and
their `and` forms, needing a `both` function) resolved via a locally opened `Let_syntax` module.
Yaron Minsky's 2016 case for it names the actual complaint it answers, and it is not indentation:

> "`Bind` is used often enough that it's a bit of a pain to have to write `>>=` followed by an
> anonymous function... [With let-syntax] the name comes first, mirroring the syntax of ordinary
> `let` bindings, [which] I think flows a bit more naturally."
> — Yaron Minsky, [*Let syntax, and why you should use it*](https://blog.janestreet.com/let-syntax-and-why-you-should-use-it/), 2016-06-21

`ppx_let`'s current README lists what it grew beyond simple bind/map: `match%bind`/`match%map`
(`match%bind M with P1 -> E1 | …` ⇝ `bind M ~f:(function P1 -> E1 | …)`), `if%bind`/`if%map`
(*"morally equivalent to `let%bind p = expr1 in if p then expr2 else expr3`"* — i.e. lifting the
**condition itself** out of the monad, not binding inside a branch), `while%bind`, qualified
operators (`let%map.Some.Module`), and `%map_open`/`%bind_open` for applicative-style APIs
(`janestreet/ppx_let/README.md`, current). **None of `match%bind`, `if%bind`, or qualified operators
made it into the core-language feature** — §3.3 covers why, in Minsky's own words, and it is the
central reason Jane Street still uses `ppx_let` today rather than `let*`.

### 3.2 The PR: what was proposed, argued, and rejected (2018-07-31 to 2018-11-27)

Leo White (`lpw25`) opened [#1947](https://github.com/ocaml/ocaml/pull/1947) on 2018-07-31,
explicitly reviving an idea he could not find a prior GitHub/Mantis thread for. The proposal's
grammar (`let ([core-operator-char] | <) { [dot-operator-char] }`) **deliberately excludes `let!`**:
*"the existence of `open!` and `method!` would make that too confusing"* (PR body). §0.1 above covers
the central `and*` fight; three further threads matter:

**Alternative resolution mechanisms, all rejected.** Yassine Keleshev proposed dispatch by a named
suffix rather than scope: *"For any identifier `⟨foo⟩`, let `let.⟨foo⟩ x = y in z` translate to
`⟨foo⟩ y ~f:(fun x -> z)`"* ([2018-08-01](https://github.com/ocaml/ocaml/pull/1947#issuecomment-409159531)),
endorsed by Antonin Décimo (`aantron`): *"It is much more clear to the reader what is going on, and
allows readily mixing multiple `let` operators"*
([2018-08-15](https://github.com/ocaml/ocaml/pull/1947#issuecomment-414737286)); OvermindDL1 proposed
a module-qualified variant, `let.MyModule a = … in`, as late as
[2018-12-13](https://github.com/ocaml/ocaml/pull/1947#issuecomment-448395735); Alain Frisch proposed
moving the operator onto `=` instead of `let` (`let x =@ e1 and y =@ e2 in e3`). White weighed three
named options explicitly (`a) let<op>` resolved as `(let<op>)`, `b) let.foo` resolved as `(let.foo)`,
`c) let.foo` resolved as plain `foo`) and picked `a`, against Xavier Leroy's framing of the
underlying design question — ten years of prior, unresolved discussion: *"We've been discussing (on
and off) the idea of mapping `letXXX x = a in b` to `YYY a (fun x -> b)`… for about 10 years. So far,
the discussions have always failed on 1- the concrete syntax… and 2- how to shoehorn Lwt's `let…and`
in the proposal"* ([2018-08-16](https://github.com/ocaml/ocaml/pull/1947#issuecomment-414983802)).
**Every alternative that survived to a final vote lost to scope-resolution of an ordinary value** —
the mechanism research 15 §3.1 already names as the cheapest possible answer, arrived at here after
ten years and one PR of arguing the alternatives, not by default.

**The `match`/`if`/`while` extensions were explicitly deferred, on record, to keep the PR mergeable.**
Jeremy Yallop raised the `match` case directly (*"Is there any reasonable way to support qualified
versions of these operators?"* territory) and proposed the split himself:
*"Personally, I think it'd be useful to see the `match` syntax proposed & discussed in a separate
PR, since… the `match` sugar raises additional questions that aren't related to monads, such as
forwards compatibility with effects"*
([2018-07-31](https://github.com/ocaml/ocaml/pull/1947#issuecomment-408886835)) — the PR body
confirms: *"These have now been split into #1955"*. That companion PR for `match<op>`/`if<op>` never
merged into trunk; `ppx_let`'s `match%bind`/`if%bind` remain the only shipped route to that feature,
which is the direct cause of §3.1's "Jane Street still uses `ppx_let`" fact.

**The maintainers disagreed openly about readiness, and merged anyway.** Gabriel Scherer, after White
declared the PR approved: *"I don't find the argument very convincing; I think it would be more
reasonable to wait until someone… approves explicitly"*
([2018-11-22](https://github.com/ocaml/ocaml/pull/1947#issuecomment-441399885)) — then, the same day,
closed the question himself: *"I'm happy to make a decision there: let's consider this specific
question resolved for now."* It merged five days later, 2018-11-27T15:05:37Z, into OCaml 4.08.0.

### 3.3 Post-merge: newcomers, and Jane Street's own verdict

Newcomer confusion is documented, not inferred. Nils Becker, a self-described "non-Haskell-
knowledgeable and non-CS user of OCaml", reading the manual's own example:

> "what I find surprising is that after the `let*` bindings, `x1` and `x2` are apparently not bound
> values as usual in OCaml. For instance, replacing the last line with `(x1 + x2)` would not
> type-check. […] I'm wondering if the documentation can do something specifically to prevent this
> incorrect but… plausible reading."
> — [2018-12-12](https://github.com/ocaml/ocaml/pull/1947#issuecomment-447805259)

which `meadofpoetry` generalised: *"I think what people are complaining about is that custom monadic
let is way too confusing, especially for the novice… let seems even more confusing than do-notation
due to its syntactic similarity to the usual let"*
([2018-12-14](https://github.com/ocaml/ocaml/pull/1947#issuecomment-447977658)). White's response —
*"It is more correct to think of `let` as an expression… I'll see if I can improve the documentation
wording"* — produced [PR #2206](https://github.com/ocaml/ocaml/pull/1947#issuecomment-448186552)
(2018-12-18), a documentation-only follow-up.

Separately, `bluddy` raised a visual-salience objection that four other commenters endorsed within
two days: *"it's very easy for the small `+` and `*` operators to blend in, particularly because our
minds don't expect anything of importance in the area of the `let`… `let%bind` [is] ugly [but] you
can't mistake it for a simple `let`"* ([2018-12-14](https://github.com/ocaml/ocaml/pull/1947#issuecomment-447982453)),
seconded immediately by `pmetzger` (*"[bluddy] just put his finger on much of what was bothering
me"*) and OvermindDL1. **Counting directly: of roughly 50 distinct commenters on #1947, at least
eight — bluddy, pmetzger, OvermindDL1, rnd4222, texastoland, ejgallego, nilsbecker, meadofpoetry,
spanning 2018-07-31 to 2018-12-14 — raised a readability or visual-salience objection to the
spelling itself**, a volume that produced a documentation revision but no syntax change.

Two years later, with years of production use behind them, Jane Street's own verdict on
`discuss.ocaml.org` was that none of this mattered enough to switch:

> "for now, ppx_let is very much what we use… we have several extensions that aren't supported by
> the built-in operators yet (e.g., `match%bind`)… [and we're] contemplating [changes] that would
> move us yet further away from what the built-in language support can do."
> — Yaron Minsky, [*Ppx_let vs. binding operators*](https://discuss.ocaml.org/t/ppx-let-vs-binding-operators/7037/2), 2021-01-01

No source found dated later than this (2021) revisiting the question at Jane Street; §8 records the
search for a more recent update as unresolved.

### 3.4 Removed or regretted (cross-cutting Q9)

**Nothing about `let*`/`let+`/`and*`/`and+` itself has been withdrawn or deprecated** since 4.08.0 —
the manual's only addition since is let-punning (`let+ x in …` for `let+ x = x in …`, 4.13.0, a pure
convenience). What *was* effectively regretted is the scope: the `match`/`if` extension split into
#1955 never shipped, leaving a permanent gap `ppx_let` still fills, and this is the one part of the
proposal's original ambition that the ecosystem never got back for free.

The closest thing to a language-level "removal" adjacent to this report's subject is not to `let*`
at all, but to the promise-based model it serves: OCaml 5's effect handlers make Eio's direct style
possible, and Tarides' own porting guidance is unambiguous that the promise-plus-`let*` style is the
thing being moved away from, not extended: *"OCaml 5 added support for 'effects', removing the need
for monadic code"* ([Tarides, 2023-09-27](https://tarides.com/blog/2023-09-27-tutorial-how-to-port-lwt-applications-to-eio/)).
§6.4 traces the actual migration mechanics.

---

## 4. Costs — ergonomic and structural

**Cross-cutting Q6 (per-bind and per-call cost) is out of scope by this report's mandate — this
research is about ergonomics, and no benchmark or allocation count is reported.**

### 4.1 The pyramid OCaml never quite had, and the one it did

Lwt's own `.mli` documents its motivation for binding operators in almost the same words the brief
uses for Elm, but with a caveat about which spelling of `bind` triggers it. Directly nested
`Lwt.bind` does pyramid:

> "`Lwt.bind` is almost never written directly, because sequences of `Lwt.bind` result in growing
> indentation and many parentheses:
> ```
> Lwt.bind Lwt_io.(read_line stdin) (fun line ->
>   Lwt.bind (Lwt_unix.sleep 1.) (fun () ->
>     Lwt_io.printf "One second ago, you entered %s\n" line))
> ```
> The recommended way to write `Lwt.bind` is using the `let%lwt` syntactic sugar."
> — [`src/core/lwt.mli:524-541`](https://github.com/ocsigen/lwt/blob/master/src/core/lwt.mli)

but the manual's very next example shows the infix `>>=` form the ecosystem actually wrote, and it
does **not** pyramid, because `fun x -> body` in OCaml extends unparenthesised to the right, so a
chain of `e >>= fun x -> e' >>= fun y -> e''` reads at one indentation level even though it parses as
deeply nested closures:

```ocaml
Lwt_io.(read_line stdin) >>= fun line ->
Lwt_unix.sleep 1. >>= fun () ->
Lwt_io.printf "One second ago, you entered %s\n" line
```

**This is the load-bearing nuance this report adds to research 15's account: OCaml's pyramid problem
was never primarily about visual indentation the way Elm's is** (Elm's `|> Task.andThen (\x -> …)`
needs a closing paren per level, because the lambda is a pipe argument, not the tail of an infix
chain) — it shows up specifically inside an `if`/`match` branch, or wherever the continuation must
sit inside another expression and so needs explicit parentheses. What `let*` actually buys, per
Minsky's account (§3.1), is removing the `fun x ->` line-noise and restoring `let`'s name-first
reading order — an aesthetic and cognitive win, not primarily a de-nesting one. That matters for §6:
a `Task` design that already reads flat via infix chaining gets comparatively less from a
`let`-based rewrite than Elm's design does.

### 4.2 Diagnostics and locations (cross-cutting Q8)

Research 15 §3.5 already tabulates the wrong-code error (`Unbound value ( let* )` for a missing
`open`, an ordinary unification failure for a wrong monad). What that table does not show is the
`partial` field from §2.3: because `Texp_letop` is a distinct typed-tree node carrying its own
`partial : partial`, a refutable pattern in a `let*` binding gets the compiler's ordinary
non-exhaustive-match warning attributed to the `let*` site itself, not to a desugared `match`
elsewhere — one concrete benefit of giving the construct its own AST node rather than eagerly
desugaring in the parser, which is exactly the tradeoff White flagged as an open question in the PR
body (*"Currently the implementation is entirely as a translation in the parser… Should I give all
operators their own AST nodes?"*) and then resolved in the node's favor by 2018-11-05.

### 4.3 Tooling and optimiser transparency (cross-cutting Q7)

No dedicated source was found describing `ocamlformat`'s handling of let-operator chains in detail;
this report can only report the direct evidence from §2.1: because the rewrite to an ordinary
application happens after typing, not before, **every OCaml optimisation pass that operates on
Lambda or below — inlining, dead-code elimination, flambda's specialisation — sees an ordinary
function call and nothing more**, which is the strongest form of "optimiser transparency" available:
there is no opaque object to see through, because the object was never anything but a call.

### 4.4 What newcomers get wrong, and the tradeoff long-term users actually report

§3.3 already gives the two documented newcomer failure modes with dates and quotes (mistaking a
bound value for an ordinary one; missing the operator visually). The tradeoff practitioners report
**after years of production use**, not at first encounter, is narrower and more specific: `cvine` and
`hcarty`, in the 2020 "Lwt now has let* syntax" thread, on whether to migrate off `ppx_lwt`:

> "ppx_lwt is probably still the recommended way, because of better backtraces, and things like
> `try%lwt`." — `antron`, quoted by `cvine`,
> [2020-04-30](https://discuss.ocaml.org/t/lwt-now-has-let-syntax/5651/6)

`hcarty` adds the mechanism: `let%lwt` compiles to `Lwt.backtrace_bind` rather than plain `Lwt.bind`
(`src/core/lwt.mli:2054-2056` declares the distinct signature, taking a source file and line for
exactly this purpose) — a capability `Lwt.Syntax`'s `let*` (an alias for plain `bind`) does not carry
forward. **This is the one specific, named cost of choosing the language-level operator over the
PPX that this report can source directly**: better error messages and backtraces were traded for
independence from a preprocessor, and the tradeoff is still being made consciously in 2020, two years
after the language feature shipped.

### 4.5 Effects as values (cross-cutting Q10)

`let*`/`let+` preserve deferred execution, retry and interpretation-by-a-runtime exactly to the
degree the underlying monad does — the binding operators contribute nothing to this property and
take nothing away from it, per §1. Lwt's promises remain heap-allocated, cancellable-by-convention
values interpreted by `Lwt_engine` whether sequenced with `>>=`, `let%lwt`, or `let*`; the choice of
binding syntax is orthogonal to whether effects are collapsed into native side effects. The one place
this *does* collapse — Eio, under OCaml 5 effects — is covered as an ecosystem-level, not a
`let*`-level, change in §6.4.

---

## 5. What users say

**Praise**, concentrated in the design's originators and early adopters, is about clarity and
diffability, not about eliminating nesting: Minsky's 2016 case (§3.1) leads with *"flows a bit more
naturally"* and *"cleaner diffs"* — turning `expr` into `let%bind x = expr in …` when adding a new
dependent step is a one-token change, versus rewriting an entire `>>=` chain's parenthesisation.
Andrejbauer, evaluating the feature from outside OCaml's own concurrency libraries entirely: *"we'd
love OCaml support for monads. We've been considering using one of the ppx extensions to get a saner
syntax, but anything that is actually built into OCaml is of course a big advantage"*
([2018-12-12](https://github.com/ocaml/ocaml/pull/1947#issuecomment-447736498)) — evaluator praise,
distinct from the maintainer-of-a-large-codebase category the brief asks to separate.

**Complaints** split cleanly into two kinds, and the split itself is a finding: newcomers complain
about the *notation* (§3.3's eight-commenter count on visual salience and the "is `x1` a real value"
confusion), while long-term maintainers complain about a *specific missing feature*, not the
mechanism — the backtrace tradeoff (§4.4) and Minsky's `match%bind` gap (§3.1, §3.3) are the only
complaints sourced from people maintaining production Lwt/Async code, and neither is about
readability. **This is the finding the brief asks to report honestly: OCaml's large-codebase
maintainers, once past the initial notation objection, mostly do not talk about `let*`'s ergonomics
at all** — the discuss.ocaml.org threads found here are short (5–8 posts), not long-running
arguments, and close on a practical workaround rather than a grievance.

**Wishes**, all unresolved as far as this report can source: `tcoopman` asking twice whether `try%lwt`
would get a core-language equivalent (`try*`) — [2020-04-29](https://discuss.ocaml.org/t/lwt-now-has-let-syntax/5651)
— no source found that this shipped; `bobzhang` asking, about the `and*`-via-nested-`bind` fallback
White gave `ELLIOTTCABLE` in the PR thread, *"Do we have some plans to optimize such pattern?"*
([2019-04-24](https://github.com/ocaml/ocaml/pull/1947#issuecomment-486826147)) — answered only
indirectly, by Lwt shipping `both` itself (§0.3) rather than a compiler-level optimisation; and
Minsky's 2018 wishlist for the built-in operators (`if%bind`, qualified operators, `%bind_open`) —
§3.3 confirms none of it shipped, three years on.

---

## 6. What it would take to do this in beni

**6.1 The transferable half: resolve by fixed shape, not by scope.** Research 15 §3.1 already rules
out OCaml's literal mechanism — an open-ended family of `let<op>` spellings resolved by lexical
scope is user-defined operators wearing a keyword, and beni's fixed operator set forecloses it. What
this report adds is that the *design pressure* behind `and+` (§0.1) is not specific to OCaml's
scope-resolution choice — it is a fact about applicative computations in general, and it survives
translation to a single, compiler-known `Task` type. beni does not need a general `and<op>` family to
get Minsky's Incremental-style win (§0.1); it needs exactly one fixed construct, e.g. `let a = t1 and
b = t2 in body` recognised specifically when `t1`/`t2` : `Task`, compiled to a parallel-await
primitive rather than to sequential binds. This sidesteps the "no user-defined operators" objection
entirely, because it would be one compiler-known shape for one compiler-known type, not a mechanism
users extend — closer to how Gleam or Roc's `use`/backpassing are one fixed shape (research 15 §1)
than to how OCaml's `let<op>` is an open family.

**6.2 What it would deliver.** Exactly the applicative-parallelism win §0.1 documents for
Incremental, translated to beni's `Task`: two independent `Task`s bound with `and` would be started
together and awaited together, rather than the second only starting once the first resolves — a
correctness-relevant distinction (not a performance one; per this report's mandate, the *shape* of
the win is in scope, its magnitude is not) that a purely sequential `let* .. let* ..`-style rewrite
cannot express without a second, separate combinator the user must remember to reach for.

**6.3 What it would not solve.** Everything research 15 §4 already priced for a `let`-position bind
in beni — non-local rewrite cost, error-message attribution, source-map fidelity — applies unchanged
to an `and`-parallel extension of it, because `and` resolves at the same `let`-node granularity
(§2.6, `Lower.zig:1487`). What it *would* need, that a plain sequential bind does not, is a rule for
what happens when one of two parallel `Task`s fails while the other is still running — OCaml answers
this at the library level (`Lwt.both`'s semantics, not read in full here), and beni would need an
equivalent runtime rule: squarely research 16's territory, not this report's.

**6.4 The warning from the people who built it: this doesn't get retrofitted, it gets replaced.** The
Lwt→Eio migration is the one piece of direct, documented evidence in this research about what happens
when a language gains a second, better effect model after `let*`-style binding operators are already
established. The `lwt_eio` README's own worked example shows the actual mechanics: a function that
starts as

```ocaml
let process_lines src fn =
  let* lines = Lwt_stream.to_list (Lwt_io.read_lines src) in
  let* lines = fn lines in
  let* () = write lines in
  Lwt_io.(flush stdout)
(* : Lwt_io.input_channel -> (string list -> string list Lwt.t) -> unit Lwt.t *)
```

ends, after full conversion, as

```ocaml
let process_lines ~src ~dst fn =
  Eio.Buf_read.of_flow src ~max_size:max_int
  |> Eio.Buf_read.lines
  |> List.of_seq
  |> fn
  |> List.iter (fun line -> Eio.Flow.copy_string (line ^ "\n") dst)
(* : src:… r -> dst:… r -> (string list -> string list) -> unit *)
```

— every `let*` is gone, `Lwt.t` is gone from the type, and the function is an ordinary total
function. The migration is not gradual within one function: the bridge library is explicit that
calling one style's code from the other requires an explicit crossing function, not a silent
conversion — *"It's important not to call Eio functions directly from Lwt, but instead wrap such
code with `run_eio`… Simply wrapping the result of an Eio call with `Lwt.return` is NOT safe"*
(`ocaml-multicore/lwt_eio` README). **The lesson for beni, if a second concurrency style is ever
added after `Task`-and-`let*`-shaped binds are established: budget for a wholesale,
signature-changing migration with an explicit crossing primitive, not an incremental one that lets
old and new styles blend inside a single function.**

---

## 7. Ranked summary

1. **(documented)** The core mechanism is a scope-resolved rewrite to an ordinary function
   application, settled at the parser/typer boundary; nothing downstream (Lambda, bytecode,
   js_of_ocaml) treats it specially. `lambda/translcore.ml:1270-1321`.
2. **(documented)** `and+`/`and*` (applicative parallel binds) were the one contested part of the
   design, defended on a correctness argument (Incremental's recomputation semantics), not a
   performance one, by the feature's own designer and Jane Street's Yaron Minsky.
   [ocaml/ocaml#1947](https://github.com/ocaml/ocaml/pull/1947), 2018-07-31.
3. **(documented)** The applicative half of the ecosystem's biggest consumer (Lwt) trailed the
   language feature by 17 months, waiting on Lwt to grow its own `both` combinator (2019-03-21)
   before `Lwt.Syntax`'s `and+`/`and*` could ship (2020-04-23,
   [ocsigen/lwt#776](https://github.com/ocsigen/lwt/pull/776)).
4. **(measured, single data point)** A production Lwt codebase (`mirage/irmin`) had 1,480 `>>=`
   call sites against 347 `>|=` sites at the moment the applicative sugar for the latter shipped
   (craigfe, 2020-04-22) — the only quantified "before" this report could source.
5. **(documented)** `ppx_let`'s `match%bind`/`if%bind`/qualified-operator features were explicitly
   split out of the core-language proposal (#1955) and never merged; this gap is the stated reason
   Jane Street still used `ppx_let`, not `let*`, as of 2021.
6. **(documented)** Lwt's own doc comments confirm a synchronous exception raised inside a
   `let*`-bound continuation is caught and rejects the resulting promise — early return/error
   propagation is a property of the monad's `bind`, not a feature `let*` adds or needs.
   `src/core/lwt.mli:512-514`.
7. **(documented)** At least eight distinct PR commenters, across five months, objected to `let*`/
   `let+`'s visual salience or to the "is the bound value a real value" confusion; the response was
   a documentation revision (#2206), not a syntax change.
8. **(documented)** OCaml 5 effect handlers do not interact with binding operators at the language
   level; the interaction is entirely at the ecosystem level, where a direct-style library (Eio)
   makes `let*` unnecessary for new code, and migrating existing `let*`-based code to it is a
   wholesale, signature-changing rewrite with an explicit crossing primitive, not a gradual one.
9. **(inferred)** beni cannot adopt OCaml's scope-resolved `let<op>` family (ruled out already by
   research 15 on user-defined-operator grounds), but could adopt the *applicative-parallel-bind*
   idea as one fixed, compiler-known `Task`-only construct, sidestepping that objection.
10. **(unverified)** Whether `ocamlformat` treats let-operator chains as a first-class formatting
    concern with dedicated rules — no primary source was read for this; see §8.

---

## 8. What could not be resolved

- **ocamlformat's exact treatment of let-operator chains.** No documentation or source was read
  directly on this; the tooling claim in §4.3 is limited to what the compiler pipeline itself does,
  which is sourced, not to the formatter, which is not.
- **A more recent (post-2021) statement from Jane Street on `ppx_let` vs. binding operators.** The
  2021-01-01 discuss.ocaml.org thread (§3.3) is the newest primary source found; whether the
  2021 "future improvements… that would move us yet further away" materialized was searched for
  (`ppx_let` deprecation, 2023–2024) with no result beyond confirmation that `ppx_let` is still
  maintained and still used in 2024-era Jane Street package migrations.
- **`Lwt.both`'s exact fairness/cancellation semantics when one of two parallel promises rejects.**
  Cited by reference (`Lwt.mli`) but not read in full; §6.3 flags this as the concrete unresolved
  question research 16 would need to answer for a beni `and`-parallel `Task` design.
  **Deliberately out of scope: any timing, allocation, or benchmark comparison between `let*`,
  `>>=`, and `let%lwt`.** This is excluded by the project's ergonomics-only mandate, not by search
  failure — no such measurement was sought.
- **A primary source for how OCaml 5's typer specifically treats a `Texp_letop` node whose bound
  expression itself performs an `effect`.** No discussion of this specific intersection was found in
  the effect-handlers manual chapter or in searches; given the brief's framing that effects
  themselves are another agent's subject, this report did not pursue it further once the ecosystem-
  level answer (§6.4) was well sourced.
- **This session's WebSearch budget was exhausted** partway through (noted in the Sources
  paragraph); later research relied on direct `curl`/`gh api`/WebFetch against known primary sources
  rather than a broad search sweep, so blog posts or forum threads outside the accounts already
  surfaced by earlier queries may exist unfound.
