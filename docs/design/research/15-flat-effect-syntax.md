# Flat effect syntax: what a language adds when it owns its grammar

**Commissioned by** `fast-compiler.md` §3.2's one explicitly open subsection — "Flat effect syntax —
OPEN" — which records a proposal and says outright that it is not a decision. Effects are settled:
a `Task e a` is a value a platform interprets (§3.1, `boundary.md` §3), and that is not reopening.
Sequencing them today means `andThen`, and every binding you must keep alive costs a level of
nesting. **The question is what syntax buys flat, straight-line effect code, given that we control
the grammar.**

One answer is already excluded. **No generators.** Effect-TS reaches flat effect code with `yield*`
because a library cannot add syntax; we can, and importing a workaround for a constraint we do not
have — an allocated generator object and a suspend/resume per bind — would be strange. §3.2 says so
and this report does not revisit it.

**Four constraints make this hard, and all four are settled.** No typeclasses and no
higher-kinded types (§3.1), so there is no way to write one generic `do` — whatever we add is
resolved by the compiler per type, not by a class. No row polymorphism (§3), so algebraic effect
rows are out. The unifier stays simple (§7), so a syntax change that adds a constraint kind is far
more expensive than one that lives in the desugarer. And the target is JavaScript, which has no
delimited continuations.

**Sources.** The Roc Zulip archive read directly through the project's `roc-zulip` skill (17 threads,
2022-07 to 2026-08) and the **vendored Roc compiler's git history** at `references/roc`, which is
where this report's only hard numbers come from; the Gleam compiler's current `compiler-core`
sources read from `raw.githubusercontent.com`; the Koka book; the OCaml manual, the F# spec, the
Scala spec, the Haskell 2010 Report and the GHC user's guide; primary issue and proposal threads for
Gleam, Roc, Rust, Swift and Kotlin. **Beni's own compiler was run** to settle one question nothing
external could answer (§7.2). The session's WebSearch budget was exhausted partway, so later work
used direct URL fetches and the GitHub API — better provenance, no broad discovery sweep. All web
sources accessed **2026-09-14**.

---

## 0. The three findings, up front

**1. Every shipped design that is affordable without typeclasses is the same design, and three
languages invented it independently.** OCaml's `let*`, Gleam's `use`, Koka's `with`, Roc's
(removed) backpassing and F#'s `let!` all reduce to one rewrite: *take the rest of the block, make
it a lambda, pass it as the last argument to a named thing.* None of them consults a type class.
OCaml resolves the name by scope (`( let* )`), Gleam and Koka by writing the call out in the source,
F# by the builder object named before the braces. Koka claims priority — *"Another novel syntactical
feature is the `with` statement"* — and Gleam's author, told about it after the fact, wrote: *"It is
quite reassuring to discover other languages with the same feature after we have designed it
independently (Roc also has it)"*
([gleam#1709](https://github.com/gleam-lang/gleam/issues/1709#issuecomment-1236297281)). **Four
independent inventions of one mechanism is the strongest signal in this report.**

**2. The cost is not in the desugarer; it is in the parser, the formatter and the fuzzer — and the
difference between a local and a non-local rewrite is a factor of twenty-four, measured in one
compiler.** Roc shipped both shapes. Backpassing (`x <- foo`, rest-of-block becomes a lambda
argument) desugared in **44 lines** of `desugar.rs`. The `!` suffix on `Task` (a marker in arbitrary
expression position, everything after it moved into a continuation) needed a dedicated
**1,046-line** `crates/compiler/can/src/suffixed.rs` with **39 snapshot tests**, twenty-odd
`internal_error!` sites, a `Malformed` error variant, four `TODO`s on the rewrite itself, and a
~140-line `is_expr_suffixed` predicate in `parse/src/ast.rs` that re-walks the expression tree at
eight call sites. It shipped with a bug that crashed the compiler on a `!` inside a record field:
*"a `Expr::TaskAwaitBang` expression was not completely removed in `desugar_value_def_suffixed`"*
([roc#7001](https://github.com/roc-lang/roc/issues/7001)). Removing backpassing deleted 2,246 lines
across 94 files, of which **the desugarer was 44 and the parser 378**; Joshua Warner's comment on
the removal PR is *"I'm still running into weird edge cases with multi-backpassing in fuzzing"*
([Zulip, 2025-01-01](https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/Remove.20backpassing.20from.20compiler.20for.20now/near/491531569)).
**The expensive thing is not "the rewrite is non-local"; it is "the marker may appear anywhere an
expression may."**

**3. `?` extended to `Task` is the most expensive of the three shapes §3.2 lists, not the cheapest —
and beni's compiler already demonstrates the reason.** `?` is postfix on any `App`
(`language.md` §3: `Postfix := App '?'*`), so `f (fetch url ?) y` is legal today. For `Maybe` and
`Result` that is fine: it desugars to a local `case`. For `Task` the continuation must be hoisted
out of an argument position, out of an `if` condition, out of a `case` scrutinee, out of a `|>`
chain — which is precisely the `suffixed.rs` problem, adopted whole. A `let`-binding-position form
has no such problem, because beni's `let` binding list *is already* a statement sequence lowered in
source order (`Lower.zig:1487`), and the continuation of binding *i* is textually `bindings[i+1..]`
plus the `in` body: a rewrite local to one `let` node. Separately, running beni shows a second cost
in the checker: `?`'s shape is chosen by **ordered speculative unification** (`Solve.zig:1177`
tries `Result`, then `Maybe`), so `pub step a = let v = a? in Ok v` infers `Result e a -> Result e a`
with no diagnostic — the first candidate wins silently. `Task e a` would be a **second two-parameter
candidate** in that ordered list, and an unannotated `?` meant for a `Task` would silently be typed
`Result`.

---
## 1. The design space: what the user writes, what it becomes, what it costs

Twelve shipped mechanisms. The column that decides everything for us is **"what the type system
must know"** — anything in that column beyond "nothing" is a cost §3 and §7 already ruled out.

| Mechanism | User writes | Desugars to | What the type system must know | Where the marker may appear |
|---|---|---|---|---|
| **Haskell `do`** | `x <- m; rest` | `m >>= \x -> rest` | **a `Monad` class** — HKT + dictionaries | statement position in a `do` block |
| **GHC `QualifiedDo`** | `M.do { x <- m; … }` | `(M.>>=) m (\x -> …)` | **nothing** — `>>=` resolved by module qualifier | same |
| **GHC `RebindableSyntax`** | `do` | whatever `>>=` is in scope | **nothing** — name resolution only | same |
| **OCaml `let*` / `let+`** | `let* x = e in body` | `( let* ) e (fun x -> body)` | **nothing** — `( let* )` is an ordinary value found by scope | `let`-binding position |
| **F# `let!`** | `b { let! x = e; … }` | `b.Bind(e, fun x -> …)` | the builder's **members** (.NET member lookup, statically typed) | statement position inside `b { }` |
| **Scala `for`** | `for (x <- m) yield f(x)` | `m.map(x => f(x))` / `flatMap` / `withFilter` | the type's **members** (ordinary method lookup) | generator position in `for` |
| **Gleam `use`** | `use x <- f(a)` then rest | `f(a, fn(x) { rest })` | **nothing** — last argument must be a function of the right arity | last statement of a block |
| **Koka `with`** | `with x <- f(a)` then rest | `f(a, fn(x){ rest })` | **nothing** — same shape contract | statement position |
| **Roc backpassing** (removed) | `x <- f a` then rest | `f a (\x -> rest)` | **nothing** — same shape contract | statement position |
| **Roc `!`** (removed) | `x = f! a`, `g (h! b)` | `Task.await (f a) \x -> …` | the name `Task.await` | **anywhere an expression may** |
| **Rust `?`** | `e?` | local `match` + `return` | the `Try`/`FromResidual` traits | anywhere an expression may |
| **Rust/Swift/Kotlin `async`** | `await e` | a **state machine** over the whole function | an effect-like colour on every signature | anywhere, inside an `async fn` |
| **Koka / Unison effects** | ordinary calls | evidence passing / continuations | **effect rows** — row polymorphism | anywhere |
| **Idris `!`** | `!e` | lifts `e` into a preceding bind | a `Monad`-ish `>>=` in scope | anywhere inside a `do` |
| **PureScript `ado`** | `ado x <- m in f x` | `map`/`apply` chain | `Applicative` class | statement position |

Three groups fall out, and only one of them is available to us:

- **Class-directed** (`do`, `ado`, Rust's `?`, Scala's `for` in spirit). Needs either HKT plus
  dictionaries, or a trait with an associated type. §3.1 settled that we have neither. *Ruled out by
  a decision already taken, not by this report.*
- **Type-system-directed on effects** (Koka, Unison). Flat by construction, no bind syntax at all —
  and both buy it with **effect rows**, which is row polymorphism for effects, rejected in §3 on
  inference cost. Koka's compilation strategy is also the one JavaScript makes expensive:
  with no delimited continuations in the host, the JS backend must either CPS-convert or thread
  evidence by hand. *Ruled out by two decisions already taken.*
- **Syntactic, resolved by scope or by the written call.** OCaml, Gleam, Koka's `with`, Roc's
  backpassing, F#'s builder. **This is the whole of what is available**, and §0.1 is that they are
  all one design.

**Where the marker may appear is the cost axis, not the resolution mechanism.** Every "nothing"
in column four sits next to a *restricted* position in column five, and every "anywhere" in column
five sits next to either a class or a state machine. That is not a coincidence; §4 is why.

---

## 2. The designs that were withdrawn

Why a design was removed is worth more than why one was adopted. Two were, and the Roc one is
documented in unusual depth because its team argued it in public for eighteen months.

### 2.1 Roc's backpassing: adopted 2021, deprecated 2024-08, removed 2025-01

The syntax was `x <- expr`, and the desugaring was exactly Gleam's `use`: the rest of the block
became a lambda appended as the last argument to the call on the right. Multi-argument
(`y, z <- bar x`) was supported. It was not tied to any monad — `Result.try`, `Task.await`,
`List.walk`, parser combinators and RAII wrappers all worked, because the contract was an arity
contract.

**Four reasons were given, and they are not the ones a reader would guess.**

**(a) Beginners could not hold it.** This is the stated primary reason and it is consistent across
four years and four different people. Anton: *"it was removed because it was one of the most
complicated things to understand in Roc"*
([2024-12-31](https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Do.20expressions/near/491413516));
*"we got rid of it because it was a source of confusion and it increased the Roc learning curve"*
([2024-10-04](https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Generic.20version.20of.20.21.20or.20.3F/near/474873893)).
Sam Mohr, on the deprecation: *"there are many people that have expressed difficulty with grokking
the syntax between Roc and Gleam's `use` keyword. We want to optimize the trade-off between beginner
friendliness and clean code"*
([2024-08-25](https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Is.20backpassing.20done.20for.3F/near/465025939)).
Richard Feldman, when told good docs would be enough: *"in general I'd say the opposite: simplifying
is more important than documenting complexity"*
([2024-08-27](https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Is.20backpassing.20done.20for.3F/near/465429388)).
The sharpest version is Brendan Hansknecht's, and it is the one that generalises:

> "I really thought the same, but after years of working on roc and helping users, `!` is something
> users are happy with not understanding and handwaving away. `<-` is strange enough, especially
> when paired with `|>` that users feel the need to grok it fully. I think the constraints of `!`
> are probably part of why users just accept it. Code still reads relatively normal and it is only
> ever used as `Task.await`. Backpassing reads weirder and can be used in so many more contexts."
> — [2024-08-27](https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Is.20backpassing.20done.20for.3F/near/465504689)

**That is an argument for a narrow feature over a general one, made by someone who wanted the
general one** — his next message is *"I love backpassing at this point and wish Roc was keeping
it."* Generality is what made it demand full comprehension.

**(b) It was parser-hostile, and the bill kept arriving.** Joshua Warner proposed removing
*multi*-backpassing eighteen months before the rest went, purely on parsing grounds:

> "Parsing multi-backpassing is difficult because the `,` can often end up confused for a list,
> tuple, or record separator if we're parsing anywhere inside one of those — and we end up needing
> to tip-toe around in the parser to avoid accidentally making the wrong choice. The core problem is
> *ambiguity*."
> — [2023-07-06](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Removing.20multi-backpassing.3F/near/372752607)

The vendored history bears the cost out. **42 commits mention backpassing**; seven of the twelve in
2024 are bug fixes, six of them in the last six weeks before removal ("Fix lifting of backpassing",
"Fix return backpassing case", "lift spaces in backpassing (fixes #7364)", "Lift spaces in
backpassing", "Don't simplify backpassing record assignment", "Fix issue with multibackpassing in
closure in binop"). Every one of those is a **formatter or parser** fix, not a semantics fix.
The removal commit (`cbcbfd3265`, 2025-01-01) is 94 files, −2,246 lines, and the split is the
finding: `can/src/desugar.rs` −44, `fmt/src/expr.rs` −164, `parse/src/expr.rs` **−378 with 217
added** — the parser was not deleted, it was *restructured*. Sam Mohr's framing when proposing it:
*"We have complexity in the form of detecting commas and arrows that would go away… The desugaring
logic is pretty simple, so I don't think it's worth keeping"*
([2025-01-01](https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/Remove.20backpassing.20from.20compiler.20for.20now/near/491531465)).

**(c) Early return lands in the wrong function.** This is the hazard `fast-compiler.md` §3.2 rule 1
already names, and Roc's own worked example is worth keeping:

```
check_contents! = |path|
    full_path = get_full_path(path)
    |file| = with_file!(full_path)
    if full_path.is_dir() return "early"
    contents = file.read!()?
```

> "That early return and the `?` are going to return to `with_file!`, not to `check_contents!`."
> — Sam Mohr, [2025-01-06](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/backpassing.20-.3E.20lambda.20destructuring.3F/near/492135268)

His proposed mitigation — *"We could put a warning on early returns within backpassing contexts"* —
is what beni's `question_in_lambda` already is, made into a hard error rather than a warning.

**(d) It spread past its intended use.** Georges Boris, reporting from Gleam:

> "the `use` thing really spread across usages that I wouldn't expect over there and now it is not
> uncommon to see it being used like: `use x, acc <- list.foldl(xs, 0)` … when something is
> possible, people will use it in unplanned ways (tbh this is used like this by core folks on the
> gleam community so it would be taken as 'best/common practice')"
> — [2024-12-26](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/backpassing.20-.3E.20lambda.20destructuring.3F/near/490896504)

Sam Mohr's conclusion from it: *"Roc does well with a few, powerful primitives, but backpassing
probably can be replaced by better, more numerous tools that don't lead to beginners needing to
engage with a complex concept"*
([2024-12-26](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/backpassing.20-.3E.20lambda.20destructuring.3F/near/490892395)).

**What replaced it:** two narrow operators. `?` for `Result` (a local `case` with an early return)
and, at the time, `!` for `Task`. Anthony Bullard's side-by-side is the whole argument for narrow
over general — and his closing note is one we should take: *"if `try` desugars to `when`, probably
better perf than callbacks"*
([2024-12-26](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/backpassing.20-.3E.20lambda.20destructuring.3F/near/490892581)).

**The counter-evidence, recorded honestly.** The removal was contested by users who had learned it.
*"Very sad if so… this is a beautiful general-purpose tool to improve callback readability (in
absence of true monads it is responsible for like a third of my initial interest in Roc)"*
(Karakatiza). MystPi, who came from Gleam, asked for a generic `!` for a parser-combinator package
and was told *"There are no such plans currently. Only task and result"*; Brendan Hansknecht's
answer names the real cost of the narrow design: without it, *"this all has to be done manually"*,
and the alternative he sketches is *"a lot more verbose and less nice than having arbitrary monadic
chaining"*
([2024-10-05](https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Generic.20version.20of.20.21.20or.20.3F/near/475027617)).
**The narrow design does not cover parser combinators, and nobody in the Roc thread claims it does.**

**And the `!` that replaced it was removed too.** When a user asked in 2026 whether Roc would take
*"a `do` construct that works for types with the equivalent of `bind` and `return`… I don't think
this would require HKT"*, Feldman's answer was: *"we used to have it, but we took that out too — it
was called 'backpassing'"*
([2026-08-11](https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/What.20does.20the.20Roc.20community.20mean.20by.20.22effect.22.3F/near/615946288)).
Roc's current answer to flat effect code is not syntax at all: **purity inference**, where an
effectful call is an ordinary call and the compiler infers the effect. That route is closed to us —
§3.1 settled that effects are values a platform interprets, exactly the design Roc abandoned.

---
## 3. Monomorphic do-notation: how you resolve a bind without typeclasses

This is the crux. Four shipped answers, in increasing order of how much the compiler has to know.

### 3.1 OCaml: resolve the operator by scope (`let*`)

The OCaml manual is explicit that the mechanism is a rewrite to a *name*, and gives the equation:

> "`let<op0> x1 = e1 and<op1> x2 = e2 and<op2> x3 = e3 in e` desugars into
> `( let<op0> ) (( and<op2> ) (( and<op1> ) e1 e2) e3) (fun ((x1, x2), x3) -> e)`"
> — [ocaml.org/manual/bindingops.html](https://ocaml.org/manual/bindingops.html), introduced 4.08.0

and for the single-binding case, *"the let-operator in `let<op> x1 = e1 in e` can be desugared into
an application `( let<op> ) e1 (fun x1 -> e)`."* The operator name is constrained by a grammar
production — `let ([core-operator-char] | <) { [dot-operator-char] }` — so `let*`, `let+`, `let*?`
are all legal spellings and each is a **distinct ordinary value**. Nothing is type-directed:
`let*` means whatever `( let* )` is bound to at that point in scope, and the manual's own advice is
social rather than mechanical — *"let-operators and and-operators working together use the same
symbol"*, which it recommends rather than enforces.

**What this buys, and what it costs.** It buys zero type-system surface: `let*` is parsing plus
name resolution, and everything after is ordinary inference of an ordinary application. It costs a
**dependence on what is in scope at a point in a file** for the meaning of a control construct —
which is why the idiom in the OCaml ecosystem is a per-library `Syntax` module (`Lwt.Syntax`,
`Result.Syntax`) opened locally, and why the question a reader asks at a `let*` is "which `open` am
I under?" That is the same question `RebindableSyntax` makes a Haskell reader ask, and the same one
`QualifiedDo` was added to answer by writing the module at the use site.

**Why it does not transfer to beni as-is.** §3.1 settled *"no user-defined infix operators. Fixed
set, fixed fixities"*, on the LL(k) grounds of §3 and on Feldman's retrospective that Elm's removal
of custom operators *"was for the best."* An open-ended family of `let<op>` spellings is
user-defined operators wearing a keyword. The *resolution principle* transfers; the open-ended
spelling does not.

### 3.2 Gleam and Koka: write the call, take the rest of the block

Both make the resolution question vanish by putting the function in the source.

Koka's manual states the rewrite as a translation table:

> "The `with` statement essentially puts all statements that follow it into an anonymous function
> block and passes that as the last parameter."
> `with f(e1,...,eN)` ⇝ `f(e1,...,eN, fn(){ <body> })`
> `with x <- f(e1,...,eN)` ⇝ `f(e1,...,eN, fn(x){ <body> })`
> — [Koka book §3.1.5](https://koka-lang.github.io/koka/doc/book.html)

and adds the framing that is the best one-line description of the whole family: *"it helps thinking
of `with` as a closure over the rest of the lexical scope."* Koka also claims the priority: *"To the
best of our knowledge, Koka was the first language to have generalized trailing lambdas… Another
novel syntactical feature is the `with` statement."*

Gleam's `use` is the same rewrite and its implementation confirms there is no type-level machinery:
`infer_use` (`compiler-core/src/type_/expression.rs:802`) collects the following statements, builds
an `UntypedExpr::Fn` from them, and appends it as the last argument to whatever call sits right of
`<-`; `get_use_expression_call` accepts any expression and treats a non-call as a zero-argument
call. Inference then runs on an ordinary application.

**The contract Gleam chose instead of a class is the sentence worth copying.** Louis Pilfold, in the
design issue, weighing Haskell:

> "In Haskell to use [do] notation you must implement the bind function, which has a specific and
> precise interface. I think there could also be value in having a more flexible interface that
> offers little restrictions beyond the function taking a function as the final argument."
> — [gleam#1709](https://github.com/gleam-lang/gleam/issues/1709#issuecomment-1206363829), 2022-08-05

**An arity contract instead of a type contract.** It is checkable with what a Hindley–Milner
unifier already does — the last parameter must be an arrow of the right arity — and it needs no
constraint kind, no class, and no new type representation. That is the whole answer to research
question 3.

**Ambiguity does not arise, because there is nothing to resolve.** `use x <- result.try(r)` names
`result.try`; there is no second reading. The errors are therefore all arity errors (§4.3), and
Gleam's three diagnostics are exactly the three arity mistakes available.

**The cost is generality, and it is the cost §2.1(d) describes.** Because the contract is "last
argument is a function", `use` works for `list.fold`, for middleware, for RAII wrappers, for
logging spans — and Gleam's community did all of those, which is what Roc cited as a warning.
Pilfold's own issue anticipates it approvingly (`db.transaction(conn) with tx_conn`,
`logger.span(context, "user_creation") with context`), so this is a chosen breadth, not an accident.

**The other cost is reading order.** Pilfold noticed it the same day: *"It is unfortunate that the
`then` sort-of reads backwards now… `with user <- result.then(log_in())`. It would be nice to have
the `then` be later on the line than the `log_in`."* Hayleigh Thompson's objection in the same
thread is the one that shaped the final syntax — she rejected a trailing `with x` because *"it's
kind of possible to just miss the binding when you're scanning over the code"* and because every
other Gleam binder reads right-to-left, and proposed `with x <- result.then(...)` for that reason.
**The binder goes on the left because that is where every other binder in the language is** — a
consistency argument, and the one that applies to beni's `let` too.

### 3.3 F# and Scala: resolve by ordinary member lookup

F#'s `let!` is resolved by the *builder object* named immediately before the braces:
`async { let! x = e in … }` becomes `async.Bind(e, fun x -> …)`, where `async` is an ordinary value
and `Bind` an ordinary member. Scala's `for` is resolved by `map`/`flatMap`/`withFilter` being
members of the scrutinee's type. Neither is a type class; both are nominal member lookup, which is
what beni does not have — beni has no methods, no dot-call on user types, and `boundary.md` §7.1
plus `fast-compiler.md` §3.1 rule out adding prototype dispatch. **Ruled out for a reason unrelated
to this report.**

### 3.4 The class-directed designs, and why they are not available

Haskell's `do` needs `Monad`; PureScript's `do` and `ado` need `Bind` and `Applicative`; Idris's
`do` and `!` need a `>>=` in scope with the right shape. Each of those is either a class (HKT plus
dictionaries — §3.1, settled) or `RebindableSyntax` in disguise, which is §3.1 again. The one
member of this family that is genuinely interesting is **GHC's `QualifiedDo`** (GHC 9.0): `M.do`
resolves `>>=` to `M.>>=`, making the bind a *qualified name* rather than a class method. That is
OCaml's answer with an explicit module instead of an implicit `open` — and it exists because the
implicit-scope version was found confusing. It is the strongest argument that **if a bind is to be
resolved by name, the name should be written at the use site**, which is what Gleam and Koka do
and what §8's recommendation does.

### 3.5 What the wrong-code error looks like, per mechanism

| Mechanism | User error | What the compiler says |
|---|---|---|
| OCaml `let*` | no `( let* )` in scope | `Unbound value ( let* )` — a name error, points at the `let*` |
| OCaml `let*` | wrong monad | ordinary unification failure inside an application the user did not write |
| Gleam `use` | RHS takes no callback | *"has to take a callback function as its last argument. But the last argument of this function has type: …"* |
| Gleam `use` | wrong callback arity | *"This function takes a callback that expects 2 arguments. But 1 was provided on the left hand side of `<-`."* |
| Roc `<-` | wrong type | *"This 2nd argument to `await` has an unexpected type"* — blames the desugaring |
| Roc `try`/`?` | wrong shape | *"This returns a value of type: `[Err *]`"* against an unrelated record type |
| beni `?` today | neither `Result` nor `Maybe` | *"`?` needs a `Result` or a `Maybe`, and this is neither"* + the enclosing type + a hint |

**beni's existing message is already the best one in this table**, and it is best for a structural
reason: the candidate set is *closed and written down*, so the message can name it. Gleam's
messages are good for the same reason — three named failure modes, each with its own prose. The two
bad rows are both cases where the compiler reports against a node the user did not write.

---
## 4. The non-local rewrite, measured

A `?` on a `Task` cannot desugar to a local `case`: everything after it moves into a continuation.
This section is about what that actually costs, and the answer is that it depends almost entirely on
**where the marker is allowed to appear** — not on the fact that the rewrite is non-local.

### 4.1 The 44-versus-1,046 measurement

Roc shipped both shapes in the same compiler, in the same era, written by overlapping people, so the
comparison is unusually clean.

| | Backpassing `x <- f a` | `!` suffix `f! a` |
|---|---|---|
| Marker position | statement position only | **anywhere an expression may appear** |
| Desugarer | **44 lines** in `can/src/desugar.rs` | **1,046 lines** in `can/src/suffixed.rs` + 257 in `desugar.rs` |
| Dedicated tests | in the shared parser snapshot corpus | **39** dedicated `suffixed_tests__*` snapshots |
| Internal invariants | none | **20+** `internal_error!` sites, a `Malformed` variant, 4 `TODO`s |
| Happy-path cost | none | `is_expr_suffixed`, a ~140-line recursive walk over every expression form, **8 call sites**, no memo |
| Shipped crash | — | [roc#7001](https://github.com/roc-lang/roc/issues/7001) |

Both figures are from the vendored repo: `git show 8001de5:crates/compiler/can/src/desugar.rs` for
the backpassing case (the `Backpassing(loc_patterns, loc_body, loc_ret)` arm), and
`git show 2150ee2219^:crates/compiler/can/src/suffixed.rs | wc -l` for the other. The removal of
`Task` (`2150ee2219`, 2025-01-08) deleted 14,295 lines across 139 files.

`suffixed.rs`'s own doc comments explain where the 1,046 lines go, and it is not the bind:

```rust
/// Suffixed sub expression
/// e.g. x = first! (second! 42)
/// In this example, the second unwrap (after unwrapping the top level `first!`) will produce
/// `UnwrappedSubExpr<{ sub_arg: second 42, sub_pat: #!0_arg, sub_new: #!0_arg }>`
```

A marker in argument position has to be lifted *out* of the argument, given a compiler-generated
name (`#!0_arg`), and bound by a fresh continuation wrapped around the whole enclosing expression.
The module then has to do that for every expression form that can contain a subexpression: `Apply`,
`PncApply`, `BinOps`, `If`, `When`, `ParensAround`, `Closure`, `Defs`, record fields, `dbg`,
`expect`. That enumeration is the file. Three of the four `TODO`s are in the `Defs` arm and all
three bail out with `Err(EUnwrapped::Malformed)` — the rewrite gives up and reports nothing useful.

### 4.2 Early `return`, and pattern matching on the bind

Every implementation that has both a continuation-forming bind and an early return hits §2.1(c):
the `return` lands in the synthesised lambda, not in the function the reader is looking at. There
are exactly three answers in the survey.

- **Forbid the combination.** beni already does, and it is free: `question_in_lambda` is a scope
  check in `Lower.zig:1472`, walking the frame stack to the nearest `.function`. Extending it costs
  nothing because the frame stack is already there.
- **Have no early return at all.** Gleam's answer. Gleam has no `return` statement, so the question
  cannot be asked; `use` is safe by the absence of the other feature.
- **Warn.** Roc's proposed mitigation, never shipped, and the reason backpassing's removal became
  easier to argue.

**Pattern matching on the bind is where the syntactic designs differ most.** Gleam allows a full
pattern and desugars a refutable one into a fresh argument plus a generated assignment in the
callback body (`UseAssignments::from_use_expression`, `compiler-core/src/type_/expression.rs:4849`):
a plain variable or `_` becomes a function argument directly, and `Box(x)`, a tuple, a list, a
literal each become `#use_assignment_N` plus a `let` inside the body. That is a clean rule, and it
is only clean because Gleam's `let` may be refutable. **beni's may not** — `LetPattern` is
irrefutable by construction (`language.md` §7, `refutable_let_pattern`) precisely to keep
exhaustiveness out of `let`. So a beni bind may take exactly the patterns `LetPattern` already
takes, and nothing more. That is a restriction inherited for free from a decision already made,
not a new one.

### 4.3 Error messages pointing at desugared code

This is the cost every implementation pays and none of them fully solves.

Roc's is on the record from 2022, before any of the removals:

> ```
> This 2nd argument to await has an unexpected type:
> 24│>   template <- File.readUtf8 templatePath |> Task.await
> ```
> "I did a double-take at 'This 2nd argument to await' before realising that backpassing is similar
> to bind in do-notation… It took a moment to jump through these steps though, and I don't think I
> would've gotten it if I hadn't used bind before."
> — David Dunn, [2022-09-15](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Desugared.20syntax.20in.20error.20messages/near/299063878)

Ayaz Hafiz's reply names the fix and why it was not taken: *"I think the error message should be
improved to say something like 'this backpassed function has type …' instead of the '2nd argument'
message… I'd be a bit hesitant about adding [the desugared form] to all error messages, because it
might be a bit noisy."* Nothing shipped. Two years later the same class of complaint was still
arriving, now about `try` and `?`: a user's half-hour with *"a whole collection of confusing and
unhelpful error messages"* produced `This returns a value of type: [Err *]` against a record type,
and his own verdict — *"These are both utterly useless"*
([2024-12-01](https://roc.zulipchat.com/#narrow/channel/463736-bugs/topic/Extremely.20confusing.20errors.20from.20try.20and.20.3F.20operator/near/485462097)).
Sam Mohr's explanation is the general lesson: *"I initially attempted to implement it as a proper
keyword that did its own kind of type-checking, but I kept finding myself running into issues. So as
a stop-gap, we started with a simpler impl, where `try` is desugared to [a `when`]"* — and the
stop-gap desugaring is what the messages then describe.

**Gleam is the one implementation that spent real effort here, and the mechanism is copyable.** The
synthesised lambda is tagged at construction — `FunctionLiteralKind::Use { location }` — so the
type checker knows a function literal came from a `use` and can blame the `use` rather than the
lambda. On top of that Gleam carries **three dedicated diagnostics** for `use` alone, in
`compiler-core/src/type_/error.rs`: `UseFnIncorrectArity`, `UseCallbackIncorrectArity`,
`UseFnDoesntTakeCallback` (plus `NotFnInUse`). Their rendered text never mentions monads or binds:

> "The function on the right hand side of `<-` has to take a callback function as its last argument.
> But the last argument of this function has type: …"

> "The function on the right of `<-` here takes 2 arguments. You supplied 1 argument and the final
> one is the `use` callback function."

Each ends with `See: https://tour.gleam.run/advanced-features/use/`. **The price of good errors for
a syntactic bind is roughly three bespoke diagnostics and one tag on the synthesised node** — which
is the same order as beni's existing `try_shape` plus `question_in_lambda` plus
`question_outside_function`, and directly comparable to `language.md` §10's existing budget.

### 4.4 Source maps and the debugger

**No verified number found**, in any of the twelve ecosystems, for source-map fidelity of a
continuation-forming rewrite. What can be said:

- `fast-compiler.md` §9.6 defers source maps and `src/js/Lower.zig` already attaches a byte offset
  to every node — *"Maps are off in M3a; the offsets are here because retrofitting them means
  touching this file, the printer and every pass between."* A `let`-local bind rewrite preserves
  that property trivially: every instruction in the continuation keeps the offset it already had,
  because the rewrite reparents nodes rather than synthesising them.
- The synthesised lambda is the one node with no source text. Gleam's `FunctionLiteralKind::Use`
  carries the `use` keyword's own span for exactly that node, which is the right answer and is
  cheap.
- Roc's compiler-generated names are visible in its own diagnostics (`#!0_arg`, `#record_updater_field`).
  A generated name that can reach a user-facing message is a defect; Gleam's `#use_assignment_N`
  can too. beni's equivalent would be a fresh *local index*, not a name, because BIR locals are
  indices already — so this particular ugliness does not transfer.

---
