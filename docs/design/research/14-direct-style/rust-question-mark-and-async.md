# Rust's `?` and `async`/`await`: two mechanisms, not one, and what each cost to build

**Commissioned by** the multi-agent programme mapped in
[`00-landscape.md`](00-landscape.md), whose §2 entry for this slug asks for two things: how
`rustc` lowers `async fn` to a state machine as a language-design matter — what the user can and
cannot write across an `.await`, and how errors and traces read — and the design history of `?`
and `Try`, including the `try!` macro, the `From`-conversion decision, the `try` block that never
stabilised, `?` inside closures, and the keyword-generics/effects initiative as Rust's answer to
function colouring. Report [15](../15-flat-effect-syntax.md) already places Rust's `?` in family E
("arbitrary-position markers") against Roc's withdrawn `!` and Gleam's `use`, with the finding that
an arbitrary-position marker costs a dedicated non-local compiler pass, not a small desugarer; this
report does not re-derive that comparison, only Rust's own side of it. Report
[16](../16-fibers-and-concurrency.md) covers concurrency-runtime design (schedulers, cancellation);
this report treats Rust's runtime only where the language design cannot be separated from it
(Pin, cancellation-via-drop).

**Sources.** Read directly, all accessed 2026-09-14: RFC
[243](https://rust-lang.github.io/rfcs/0243-trait-based-exception-handling.html) (2014),
RFC [1859](https://rust-lang.github.io/rfcs/1859-try-trait.html) (2016), RFC
[3058](https://rust-lang.github.io/rfcs/3058-try-trait-v2.html) (2020) and its source at
`rust-lang/rfcs/text/3058-try-trait-v2.md`, RFC
[2394](https://rust-lang.github.io/rfcs/2394-async_await.html) (2018); the Rust reference's
["The question mark operator"](https://doc.rust-lang.org/reference/expressions/operator-expr.html#the-question-mark-operator)
section; the try-blocks tracking issue
[rust-lang/rust#31436](https://github.com/rust-lang/rust/issues/31436) and the Ok-wrapping dispute
[rust-lang/rust#70941](https://github.com/rust-lang/rust/issues/70941); the internals thread
["A final proposal for await syntax"](https://internals.rust-lang.org/t/a-final-proposal-for-await-syntax/10021)
(2019-05-06); the 1.13 (2016-11-10) and async-await-stable (2019-11-07) release posts on
`blog.rust-lang.org`; Tyler Mandry's
["Optimizing await"](https://tmandry.gitlab.io/blog/posts/optimizing-await-1/) (2019); withoutboats'
["Why async rust"](https://without.boats/blog/why-async-rust/) (2023) and
["Asynchronous clean-up"](https://without.boats/blog/asynchronous-clean-up/) (2024-02-24); the
`rust-lang/rust` source at
`compiler/rustc_mir_transform/src/coroutine/mod.rs` (module doc comment, fetched from `master`);
the async book's
["Send approximation"](https://rust-lang.github.io/async-book/07_workarounds/03_send_approximation.html)
and ["Recursion"](https://rust-lang.github.io/async-book/07_workarounds/04_recursion.html)
chapters; Yoshua Wuyts'
["Announcing the keyword generics initiative"](https://blog.yoshuawuyts.com/announcing-the-keyword-generics-initiative/);
and `rust-lang/effects-initiative`'s `CHARTER.md` (the repository `rust-lang/keyword-generics-initiative`
redirects here). **This session's WebSearch budget was fully consumed by earlier work in the
programme** (200 of 200 calls) before this report's research began, so every source below was
reached by direct WebFetch on a known or guessed URL, GitHub's raw-content host, or a link found
inside another fetched page — no discovery search was possible. This is noted, and compensated,
per §8: it is the reason §5 (practitioner sentiment) is the thinnest section and relies on
insider/maintainer writing rather than a forum survey.

---

## 0. The three findings, up front

**1. Rust does not have one mechanism for "sequence an effect flatly" — it has two, orthogonal,
and they compose by sitting next to each other on the same line.** `?` is a trait-directed,
zero-runtime-cost desugaring to a `match` (`core::ops::Try::branch` / `FromResidual::from_residual`,
per the [reference](https://doc.rust-lang.org/reference/expressions/operator-expr.html#the-question-mark-operator));
`.await` is a coroutine transform that rewrites the entire enclosing function body into a state
machine (`rustc_mir_transform/src/coroutine/mod.rs`). Neither needs the other: `?` works in fully
synchronous code, `.await` works on infallible futures. `get_user().await?` is two independent
postfix operators applied in sequence to one expression — short-circuit-on-error and
suspend-on-pending are not the same problem in Rust's design, and the language never tried to make
them one. For beni, which is contemplating a single `Task e a` and a single `?`, this split is the
report's central transferable fact: it may be cheaper to solve "bind flatly" and "propagate an
error flatly" as two small, separately-justified mechanisms than as one.

**2. The coroutine transform, not `?`, is what actually gives Rust binds-in-loops and
binds-in-branches for free — and it costs a dedicated MIR pass to get it.** `rustc`'s coroutine
pass computes which MIR locals are live across a suspension point via liveness analysis, then
lays out one struct where non-overlapping locals share storage: "First upvars are stored... It is
followed by the coroutine state field. Then finally the MIR locals which are live across a
suspension point are stored" (`coroutine/mod.rs`, module doc). Because this is a backend transform
over an ordinary function body rather than a source-level rewrite of "the rest of the block", a
`.await` inside a `for` loop or an `if` arm needs no special case — the transform sees it exactly
like any other local. Tyler Mandry's 2019 optimisation work is the direct evidence this is not
free to build correctly: before the storage-overlap analysis shipped, "the size of an `async fn`
-generated future grew *exponentially* with each new level of future it awaited", and "some tests
had `async fn`s which returned a single state machine over 400 kB in size" inside Fuchsia
(tmandry, 2019). Report 15's family-D languages (Gleam `use`, Roc backpassing) get binds-in-loops
for free by refusing to try; Rust gets it by building the harder thing.

**3. Every stabilised piece of this design was cut back from something more ambitious, and the
designers say so themselves.** `catch` blocks from RFC 243 (2014) became `try` blocks, which are
still unstable twelve years later over one design question — whether the block's tail value gets
wrapped in `Ok` — that Josh Triplett, the issue's filer, held open for years before reversing
himself: "I don't actually object to Ok-wrapping specifically, and in fact I think Ok-wrapping is
the right answer" ([rust-lang/rust#70941](https://github.com/rust-lang/rust/issues/70941)). The
original `Try` trait (RFC 1859) was replaced wholesale by RFC 3058 because, among other faults,
"it's no longer clear that `From` should be part of the `?` desugaring for all types" — the
designers themselves walked back the exact coupling of error-conversion to the `?` desugaring that
beni's `fast-compiler.md` §3.2 rejects from day one. And boats, who drove async/await to
stabilisation, writes in 2023 that Pin's exposure to ordinary users — "you need to pin a future
trait object to await it" — "was an unforced error that would now be a breaking change to fix"
(without.boats, "Why async rust"). Nothing here shipped as first designed.

---

## 1. The effect model

Rust has no unified "effect" concept and does not claim to. Two mechanisms answer the two halves
of the brief's problem statement, and a third — ordinary `fn` — covers everything else:

- **Fallibility (`Result`/`Option`) is data, not an effect.** A `Result<T, E>` is a plain enum; a
  function that can fail simply returns one. There is no runtime interpreting it, no scheduler, no
  deferred execution — evaluating a `Result`-returning call runs it immediately, synchronously, to
  completion. `?` is sugar over pattern-matching that data, nothing more. This is the opposite of
  beni's `Task e a`, which is a *value the platform interprets later*; Rust's `Result` is already
  the "eager" side of that spectrum.
- **Asynchrony (`Future`) is a value, in the same sense as beni's `Task`.** A `Future` does
  nothing until polled; `async fn foo() -> T` returns a `Future<Output = T>` immediately without
  running any of the function body, exactly as Elm's `Task` runs nothing until handed to a
  runtime. This is the one place Rust's model and beni's line up structurally: "calling an async
  function does not do any scheduling in and of itself, which means that we can compose a complex
  nest of futures without incurring a per-future cost" (Rust blog,
  ["Async-await hits stable"](https://blog.rust-lang.org/2019/11/07/Async-await-stable/),
  2019-11-07).
- **Everything else is a native side effect.** Rust does not distinguish pure from effectful code
  in its type system (no `IO` type, no effect rows); `unsafe` marks a different axis (memory
  safety, not effects). `const fn` is the closest thing to a purity marker, and it constrains what
  can be *evaluated at compile time*, not what may have side effects at runtime.

Sequencing two effects therefore means two different things depending on which axis: two
`Result`s are sequenced with `?` (a match that either extracts the `Ok` value and continues in
plain control flow, or returns early); two `Future`s are sequenced with `.await` (poll the first
to completion, then run the rest of the function body, which the coroutine transform has turned
into "run to the next suspension point"). A function that does both — `get_user().await?` — is
polling a future and pattern-matching its `Result` output in the same expression, with `?` and
`.await` composing as two ordinary postfix operators, not as one operator that understands both.

---

## 2. The mechanism

### 2.1 `?`: what it desugars to, and where it may appear

The reference's normative desugaring (unstable `Try` trait exposed):

```rust
match core::ops::Try::branch(expr) {
    core::ops::ControlFlow::Continue(val) => val,
    core::ops::ControlFlow::Break(residual) =>
        return core::ops::FromResidual::from_residual(residual),
}
```

What the type system must know: the `Try` trait (`Output`, `Residual` associated types, a
`branch` method) plus `FromResidual` on the *target* type for the source's residual — an
associated-type-driven trait lookup, not higher-kinded types (RFC 3058, "The Try trait" section).
Where it may appear: **postfix on any expression** (`language.md`-style "anywhere an expression
may" position, family E in report 15/16's landscape) — `f(g()?, h()?)`, `if x? { }`, `arr[i?]` are
all legal. The `return` in the desugaring is lexically scoped like any other `return`: inside a
closure, `?` returns from the *closure*, not the enclosing function — a direct, if
under-documented, consequence of the desugaring rule itself, and precisely the hazard beni's own
`fast-compiler.md` §3.2 cites Roc's backpassing removal to justify making illegal by construction.

### 2.2 `async`/`.await`: what it lowers to

`async fn`/`async {}`/`async move {}` do not desugar in the surface-syntax sense; they mark a MIR
body as a **coroutine**, and a dedicated backend pass — `rustc_mir_transform::coroutine` —
rewrites it into a state machine. Per that pass's own module documentation (fetched from
`compiler/rustc_mir_transform/src/coroutine/mod.rs` on `master`):

> This is the implementation of the pass which transforms coroutines into state machines... It
> computes the final layout of the coroutine struct which looks like this: First upvars are
> stored. It is followed by the coroutine state field. Then finally the MIR locals which are live
> across a suspension point are stored... The pass creates two functions which have a switch on the
> coroutine state giving the action to take.

Three states are hard-coded: **0** unresumed, **1** returned/completed, **2** poisoned (a panic
inside `poll` marks the coroutine unusable rather than leaving it in an inconsistent state). `yield
y` and `return x` are rewritten to set the next state and hand back `Poll::Pending`/`Poll::Ready`.
What the type system must know: nothing beyond ordinary trait resolution for `Future` — the
transform is a compiler builtin over MIR, not a trait the user's code participates in. Where it
may appear: `.await` is legal anywhere an expression may appear, but *only* inside an `async`
context, which is a static, checked property of the enclosing item — unlike `?`, which needs only
a structurally compatible return type, `.await` needs the enclosing function to be declared
`async` at all.

### 2.3 `fetchSummary`, faithfully

```rust
async fn fetch_summary() -> Result<Summary, HttpError> {
    let user = get_user().await?;
    let perms = get_permissions(&user).await?;
    if perms.is_admin {
        let log = get_audit_log(&user).await?;
        Ok(Summary { user, perms, audit_log: Some(log) })
    } else {
        Ok(Summary { user, perms, audit_log: None })
    }
}
```

This reads exactly as flat as the Effect-TS generator version in the brief, for the same
structural reason: `.await` and `?` are ordinary postfix expression operators, not a block
rewrite, so the branch needs no extra nesting to bind `log` and use it in the same arm — the
`if`/`else` is Rust's ordinary `if` expression, not a special form the effect mechanism owns.

### 2.4 A bind inside a loop

```rust
async fn fetch_all(ids: &[UserId]) -> Result<Vec<User>, HttpError> {
    let mut users = Vec::new();
    for id in ids {
        let user = get_user(*id).await?;   // bind + suspend + short-circuit, inside the loop body
        users.push(user);
    }
    Ok(users)
}
```

This is the case report 15 marks "not expressible" for every family-D (rest-of-block) mechanism.
It is unremarkable here precisely because of finding §0.2: the coroutine transform operates on
already-lowered MIR control flow (`for` is already a `loop` plus a `match` on the iterator), so a
suspension point inside a loop body is not a different case for the pass at all.

### 2.5 The hard cases, per the cross-cutting list

1. **Loop** — yes, shown above; no fold, no builder method, ordinary `for`/`while`/`loop`.
2. **Branch** — yes; the bound value survives past the `if`/`match` because `.await`/`?` do not
   introduce a scope (§2.3).
3. **Early return** — `?` and `return` both leave the function immediately; ordinary `Drop`s run
   on the way out, exactly as with any early return in Rust. But this composes badly with
   asynchrony specifically: an async function can also be *dropped while suspended* (cancellation),
   and `Drop::drop` is synchronous — it cannot `.await`. Boats: "One problem with the design of
   async Rust is what to do about async clean-up code... if you could await in destructors" several
   things break, including "what happens if you drop the value in a non-async scope? It's not
   possible to `await` there!" (without.boats, "Asynchronous clean-up", 2024-02-24). Rust's
   `try`/`finally`-via-`Drop` idiom is therefore reliable for synchronous cleanup on early return,
   and known-incomplete for asynchronous cleanup on cancellation — there is no stable `AsyncDrop`.
4. **Type-system demand** — `?` needs `Try`/`FromResidual` (an associated-type trait, no HKT);
   `.await` needs nothing beyond `Future` being an ordinary trait the compiler already knows about
   — the state-machine transform itself is not trait-mediated at all.
5. **Position** — both are "anywhere an expression may appear"; `?` is checked by the desugarer/
   type-checker against the enclosing function's return type, `.await` is checked by the parser/
   HIR against whether the enclosing item is `async`.
6. **Runtime cost** — out of scope for this report by the shared brief's rule; not addressed
   beyond the one sentence in finding §0.2 needed to explain why the state-machine pass exists at
   all (a designer's own account, cited once, per the brief's allowance).
7. **Optimiser transparency** — `?` disappears entirely by MIR construction (it is a `match`
   before MIR optimisations ever run); the coroutine transform is itself a MIR pass, so subsequent
   MIR-level optimisation (inlining, dead-branch elimination) sees a real, ordinary enum-and-switch
   state machine, not an opaque object — this is exactly report 15/16's "option C" (emit a state
   machine ourselves) rather than "option B" (emit host-native generators), and Rust is the
   existence proof that option C is buildable, at the cost shown in §4.
8. **Diagnostics and locations** — covered in full in §4.
9. **Removed or regretted** — `catch`/`try` blocks (still unstable, §3); green threads (removed
   before 1.0, §3); `Try` v1 (replaced by RFC 3058); Pin's user-facing exposure (boats calls it "an
   unforced error", §3).
10. **Effects as values** — `Future` yes, in beni's sense exactly (§1); `Result` no, it is data
    evaluated eagerly, not a deferred computation a runtime later interprets.

---

## 3. History and decisions

**2014 and earlier — the `try!` macro.** Before any operator existed, error propagation was a
macro: `try!(File::open(path))` expanded to the same match-and-early-return `?` now performs. RFC
1859 later frames the operator's whole justification against it: "the `?` operator... has all the
advantages that `?` offered over `try!` to begin with" (RFC 1859, referencing the by-then-shipped
`?`), specifically that nested calls read as `foo()?.bar()?.baz()?` instead of
`try!(try!(try!(foo()).bar()).baz())` (Rust 1.13 release notes,
[2016-11-10](https://blog.rust-lang.org/2016/11/10/Rust-1.13/)).

**2014-08 — RFC 243, "Trait-based exception handling".** Proposed both the `?` operator and a
`catch { }` expression together, against Result's status quo being "gnarly and inconvenient to
work with" (RFC 243, Motivation). Alternatives explicitly rejected: not adding the feature; `?`
without `catch`; implementing `catch` as a macro ("awkward"); full checked exceptions with
automatic propagation; and waiting for higher-kinded types and generic monad sugar to arrive first
— the RFC declines to block a concrete, affordable win on a hypothetical, unaffordable one, the
same trade beni's own `fast-compiler.md` makes for `?` on `Result`. On conversion, RFC 243 chose
`Into`: "The `?` operator should therefore perform such an implicit conversion, in the nature of a
subtype-to-supertype coercion. The present RFC uses the `std::convert::Into` trait for this
purpose" — the seed of the `From`/`Into` auto-conversion beni's design explicitly declines to copy.

**2016-05 — RFC 1859, generalising `Try` beyond `Result`.** `?` as shipped in 1.13 only worked on
`Result`; RFC 1859 introduced a `Try` trait so `?` could also work on `Option` and user types,
replacing ad hoc macros like `try_opt!`. Its first trait shape was what the RFC calls the
"essentialist approach" — `trait Try<E> { type Success; fn try(self) -> Result<Self::Success, E>; }`
— chosen over a "reductionist" alternative that RFC 3058 would later revive in hybrid form.

**2016-11-10 — `?` stabilised (Rust 1.13).** Shipped as sugar purely over `Result`, with the
`try!`-replacing chaining example above.

**2018 — `catch` becomes `try`, RFC 2388.** The block-expression half of RFC 243 was renamed and
re-specified but not stabilised; tracked to this day at
[rust-lang/rust#31436](https://github.com/rust-lang/rust/issues/31436), opened 2016-02-05.

**2018-2019 — RFC 2394 and the await-syntax fight.** RFC 2394 (2018) specified the coroutine
return type ("You can think of this type as being like an enum, with one variant for every 'yield
point'") and the `!Unpin` impl needed for self-referential locals, but left the concrete `.await`
spelling open, flagging a real ambiguity: "await should have a tighter precedence than `?`...
because it introduces a space, it doesn't look like this is the precedence you would get." The
`internals` thread ["A final proposal for await syntax"](https://internals.rust-lang.org/t/a-final-proposal-for-await-syntax/10021)
(withoutboats, 2019-05-06) is, per the landscape doc's own framing, "the longest syntax debate in
the language" — prefix `await expr`, a macro `await!(expr)`, sigils, and postfix `expr.await` were
all live options. Boats argued for postfix because "nearly every await returns a Result, making
`(await x)?` immediately cumbersome"; nikomatsakis backed postfix on the same page because "postfix
is going to be the most convenient and predominant form" and prefix "has problems with constructs
like `try` blocks." The decision landed 2019-05-23, for Rust 1.39 (stabilised 2019-11-07).

**2019-11-07 — async/await stable, explicitly an MVP.** The announcement frames it as a beginning,
not an end point: no `async fn` in traits, no `async` closures, recursive `async fn` rejected
outright (`error[E0733]`) needing manual `Box::pin` indirection (async book, "Recursion"). Boats,
looking back in 2023: "we shipped an MVP in 2019, tokio shipped a 1.0 in 2020, and things have been
more stagnant since then than I think anyone involved would like" (without.boats, "Why async
rust").

**2020 — RFC 3058, `Try` trait v2, replacing RFC 1859 outright.** The rationale section lists why
v1 failed in practice: "the previous RFC's use of 'error' terminology is a poor fit for other
potential implementations of the trait"; "the mechanism for controlling interconversions proved
ineffective, with inference meaning that people did it unintentionally"; and, the point that
matters most for beni, "it's no longer clear that `From` should be part of the `?` desugaring for
all types" because it produces "inference difficulties" and is "more restrictive" without
specialisation. The fix: `From::from` is removed from the operator's desugaring and pushed into
`FromResidual`'s *implementation* — "The `From::from` is up to the trait implementation, not part
of the desugaring" — so the conversion is now a property of the specific `Result`/`Result`
`FromResidual` impl, not a universal rule the `?` operator itself enforces on every type. Rust, in
other words, arrived independently at almost the shape of beni's rule 2 ("no implicit error
conversion... the error type must match the enclosing function's error type exactly"), just kept a
narrower, opt-in version of the old behaviour for the one type (`Result`) where users wanted it.

**Ongoing — try blocks stall on one question for years.** Whether `try { x }` implicitly wraps `x`
in `Ok`. RFC 3058 itself declines to settle it, saying only that its design is "forward-looking to
be compatible with other features, like `try {}` blocks... but the statuses of those features are
not themselves impacted by this RFC," and separately flags the closures interaction directly: "A
core problem with try blocks as implemented in nightly, is that they require their contextual type
to be known... this usually isn't a problem on stable, as the `?` usually has a contextual type
from its function, **but can still happen there in closures**" (RFC 3058). Josh Triplett filed
[#70941](https://github.com/rust-lang/rust/issues/70941) opposing Ok-wrapping, then years later
reversed: "I don't actually object to Ok-wrapping specifically, and in fact I think Ok-wrapping is
the right answer" — his own account of the deadlock names himself as the last holdout against "a
couple of proponents of Ok-wrapping [and] several people who didn't seem to have a strong opinion
one way or another." `try` blocks remain unstable as of this report.

**2021-2022 onward — keyword generics, renamed the effects initiative.** Yoshua Wuyts framed the
underlying disease as function colouring in the Nystrom sense: "as soon as you start trying to
write higher-order functions, or reuse code, you're right back to realizing color is still there,
bleeding all over your codebase" (blog.yoshuawuyts.com, "Announcing the keyword generics
initiative"). The concrete pain cited is duplication — MongoDB, Postgres and Reqwest client crates
maintaining separate sync and async codebases, or wrapping async in `block_on` — and the "sandwich
problem": a closure passed to `.map()` cannot itself `.await`, forcing parallel APIs (`map`,
`async_map`, `try_map`, `async_try_map`). The proposed direction was generic-over-`async`ness
functions (sketched as `async<A> fn read_to_string(reader: &mut impl Read * A) -> Result<String>`).
The initiative's GitHub repository, `rust-lang/keyword-generics-initiative`, now redirects to
`rust-lang/effects-initiative`, whose `CHARTER.md` restates the same goal for `const` and `async`
jointly — "both these efforts have a lot in common, and may in fact require similar solutions" —
with Yosh Wuyts and Oli Scherer as owners and Niko Matsakis as liaison; as of this report's access
date the charter records the proposal and experimental phases complete and development in
progress, with **feature-complete and stabilisation not yet started**. Rust's own answer to
function colouring is therefore not `?`, not `async`/`await`, but a third, still-unstable
mechanism aimed at not needing to write the colour twice.

**Removed: green threads, pre-1.0.** Boats' retrospective explains why stackless coroutines won
over stackful ones for Rust specifically: "Rust could not adopt stack copying... Rust does not
have a garbage collector, so in the end it could not adopt stack copying," segmented stacks have
"unpredictable performance costs," and switching a green thread onto the OS stack "can be
prohibitively expensive for FFI" — decisive for a language that prioritises embedding
(without.boats, "Why async rust").

---

## 4. Costs — ergonomic and structural

**What the mechanism forces the user to restructure.** `?` forces nothing beyond a matching
return type. `.await` forces the entire call chain above a suspension point to be declared
`async`, "function colouring" made syntactically real — the whole reason the effects initiative
exists (§3). Cancellation forces a second kind of restructuring: because `Drop` cannot `.await`,
any resource that needs asynchronous teardown (draining a socket, flushing a buffer) cannot use
Rust's ordinary RAII idiom for it, and "async destructors" remain an open design problem in 2024
per boats' own account (§2.5, point 3).

**What it does to error messages.** `?`'s errors are ordinary type mismatches on `Try`/
`FromResidual` resolution — no worse than any other trait-bound failure. `.await`'s worst
diagnostic experience is the Send-approximation case: "the compiler does its best to approximate
when values may be held across an `.await` point, but this analysis is too conservative in a
number of places today" (async book, "Send approximation"); the documented workaround is
manually scoping a non-`Send` binding to end before the next `.await` —
```rust
async fn foo() {
    { let x = NotSend::default(); }   // ends before the await, or the future isn't Send
    bar().await;
}
```
— a source-level restructuring driven entirely by what the compiler's liveness analysis can prove,
not by anything semantically necessary in the program.

**What it does to source locations.** The coroutine-size story is the sharpest documented case:
before the storage-overlap optimisation shipped, "some tests had `async fn`s which returned a
single state machine over 400 kB in size" in Fuchsia's codebase (tmandry, 2019) — a cost invisible
at any single call site and only found by measuring the compiled artifact, because the state
machine is an implementation detail with no separate name in source. Recursion is rejected
outright at the same layer for the same reason (an infinitely-sized state machine), with a compiler
error (`E0733`) that names the fix (`Box::pin`) but not the state-machine mechanics that make the
fix necessary (async book, "Recursion").

**What it does to tooling.** Stack traces are the least-documented cost in this report: no
primary source found states precisely what a panic backtrace looks like from inside a suspended
coroutine, but the existence of `tokio-rs/async-backtrace` — a crate whose entire purpose is
producing "a fast, complete, and stable solution for on-demand logical 'stack' traces of async
functions", requiring the user to annotate every async fn with `#[framed]` to get one — is itself
the strongest available evidence that the *default* backtrace through an async call chain does not
read as the logical call chain (it reads as the poll-loop / executor's own frames). This report
could not source a first-party rustc or tokio document stating the failure mode directly; see §8.

**What it demands of the compiler pipeline.** `?` is a THIR/HIR-level desugaring with zero
backend involvement — cheap by any measure. `.await`/coroutines are a dedicated MIR transform pass
(`rustc_mir_transform::coroutine`) that must run a liveness analysis over the whole function body,
compute a non-overlapping storage layout across all suspension points, and synthesize two new
function bodies (poll/resume, and a drop shim) from the one the user wrote — the same order of
magnitude of compiler investment report 15 measured for Roc's withdrawn arbitrary-position `!`
(1,046 lines, a dedicated pass), except Rust's version is a permanent, load-bearing part of the
compiler rather than an experiment that shipped a crash and was removed.

**What newcomers get wrong, with evidence.** The two async-book chapters this report cites exist
*because* these are the errors newcomers hit often enough to warrant a permanent page each: holding
a non-`Send` value across an await point (Send approximation) and writing a naturally recursive
async function (recursion/boxing). Both are documented as compiler-rejection-plus-workaround, not
as edge cases mentioned in passing.

---

## 5. What users say

This section is the weakest in the report: the session's search budget was gone before this agent
could run a discovery sweep of Reddit, users.rust-lang.org or Hacker News threads on `?` and async
ergonomics, so no "N of the top-M threads mention Y" count can be produced honestly. What follows
is designer/maintainer writing that touches on practitioner experience — narrower and more biased
than a forum survey; treat it as insider testimony, not a user count.

**Praise, from the people who built it.** The 2019 stabilisation post frames zero-scheduling
composition as the headline win. That `?` composes with `.await` without either mechanism needing
to know about the other (§2.3) is not itself remarked on by any source found — it appears to have
simply been expected to work, and does.

**Complaints, from the people who built it.** Boats, from inside the project, on Pin: "the `Pin`
type itself has been the source of a fair amount of consternation," and pinning a future trait
object before awaiting it "was an unforced error that would now be a breaking change to fix"
(without.boats, "Why async rust", 2023). The same post's closing assessment — "things have been
more stagnant since [2020] than I think anyone involved would like" — is a maintainer's own account
of ecosystem friction, not a benchmark.

**Wishes.** The effects/keyword-generics initiative is the organised, multi-year expression of one
wish: library authors who do not want to hand-maintain sync and async copies of the same code (§3,
MongoDB/Postgres/Reqwest examples cited by Wuyts), and users who want `.await` inside a closure
passed to `.map()` without a parallel `async_map` existing (the "sandwich problem").
`AsyncDrop`/cancellation-safe cleanup is the second organised wish, documented by boats as open
rather than shipped (§2.5, §3). Whether `?`-in-closures (§2.1's `return`-scoping surprise) is a
commonly hit papercut, versus one the RFC authors merely pre-empted, could not be assessed — no
forum evidence either way was reachable this session (§8).

---

## 6. What it would take to do this in beni

**For `?` alone: cheap, and beni has already scoped the cheap version.** `fast-compiler.md` §3.2
already commits to exactly the design RFC 3058 arrived at after abandoning the alternative: no
implicit `From` conversion, desugared entirely in the desugarer, no new constraint kind. This
report's contribution is evidence, not a new conclusion: Rust tried the more permissive design
first (RFC 243's `Into`-based conversion) and walked it back for reasons — "inference difficulties"
and unintended interconversion — that a Hindley-Milner checker without specialisation would hit
identically. Beni's existing rule 1 (illegal inside a lambda) is independently justified by what
`?`'s own `return`-based desugaring does inside a Rust closure (§2.1): the hazard is real enough
that Rust's reference desugaring produces it by accident, and beni closing it by construction is
the more conservative choice.

**For the coroutine transform: this is the expensive option report 15/16 already named "C", and
Rust is the fullest public example of what it costs to build.** A beni `Task` state-machine
backend would need: (1) a liveness analysis over the lowered IR to find which bindings are live
across a suspension point — beni's `let`-as-statement-sequence structure (`Lower.zig:1487`, per
report 15 §0.3) may make this easier than Rust's, since the binding list is already lowered in
source order rather than discovered from arbitrary control flow; (2) a storage-layout pass that
overlaps non-conflicting bindings the way `rustc_mir_transform::coroutine` does, without which the
Fuchsia 400 kB-future failure mode (§4) recurs; and (3) an answer to what a suspended `Task`'s
early-exit/cancellation does to any in-flight cleanup, which is precisely the open problem boats
describes for `AsyncDrop` — beni does not have `Drop` at all today, so this problem does not yet
exist for beni, but adopting cancellation later would create it. This would solve all of report
15/16's "hard cases" (bind inside loop, bind inside branch) that block-structured rewrites cannot,
which is exactly why Rust built it instead of a `use`-style desugarer.

**What Rust's own designers would warn beni about, directly.** Three warnings are explicit in the
sources: don't let error conversion live inside the operator's desugaring (RFC 3058's own
retraction of RFC 243's choice); don't let a low-level implementation detail (Pin, for beni:
whatever a suspended-state representation is) leak into ordinary user code before checking every
place it must be named (boats' "unforced error"); and treat cancellation-time cleanup as a separate
design question from happy-path sequencing from the start; boats' 2024 post is a direct account of
what happens when it is not: "one problem with the design of async Rust is what to do about async
clean-up code" — five years after stabilisation, still unresolved.

**What it would not solve.** Function colouring itself — the fact that a `Task`-sequencing
construct and a non-`Task` function are not interchangeable — is not a compiler-pipeline problem
Rust has solved even for itself; the effects initiative (§3) is a multi-year, still-unstable
attempt at exactly this, and its own charter records feature-completion and stabilisation as not
yet started. A beni state-machine backend for `Task` would face the identical open question Rust
still has: is an ordinary function and a `Task`-returning function the same thing generically, or
two things forever.

---

## 7. Ranked summary

1. `?` and `async`/`.await` are two independent mechanisms in Rust, not one — beni should consider
   whether it needs one unified construct or can solve "bind" and "propagate an error" separately.
   (documented, §0.1, §1)
2. The coroutine MIR pass is what actually buys binds-inside-loops-and-branches, not `?`'s
   desugaring; a block-rewrite mechanism (report 15's family D) cannot get this for free.
   (documented, `rustc_mir_transform/src/coroutine/mod.rs`, §0.2)
3. Rust's own designers abandoned automatic `From` conversion inside `?`'s desugaring for reasons
   that generalise to any HM checker without specialisation — direct support for beni's existing
   rule 2. (documented, RFC 3058, §3)
4. `try` blocks have been unstable for over a decade over one unresolved design question
   (Ok-wrapping); a mechanism this small can still stall for years on a single ergonomics
   disagreement. (documented, rust-lang/rust#31436, #70941, §3)
5. Pin's leak into ordinary async trait-object code is an admitted, uncorrectable-without-breakage
   design mistake — evidence that whatever representation beni chooses for a suspended `Task`
   should be checked against every place it must be user-visible before stabilising. (documented,
   without.boats 2023, §3, §6)
6. Async cancellation and cleanup (`Drop` cannot `await`) remains an open problem in Rust five
   years after stabilisation — beni should treat this as a design question to answer up front if
   `Task` gains cancellation, not one to defer. (documented, without.boats 2024, §2.5, §3, §6)
7. The keyword-generics/effects initiative is Rust's still-unstable, multi-year answer to function
   colouring — evidence that this problem is hard even for a team with far more resources than
   beni's, and that "we'll generalise over async later" is not a small addition. (documented,
   effects-initiative CHARTER.md, §3, §6)
8. `?`'s `return`-scoping inside closures is a real, desugaring-derived hazard in Rust that beni's
   existing rule 1 (illegal inside a lambda) closes by construction — a case where beni's stricter
   rule is the more defensible one, not merely the cheaper one. (inferred from the reference
   desugaring plus Rust's ordinary `return` scoping, §2.1, §6)
9. Building a real state-machine backend (report 15/16's "option C") costs a dedicated,
   liveness-analysis-driven compiler pass comparable in scope to Roc's withdrawn `!` operator
   (report 15), and is a permanent architectural commitment in Rust rather than an experiment.
   (documented, §0.2, §4)
10. Practitioner sentiment on this specific ergonomics question (as opposed to maintainer/designer
    reflection) could not be surveyed this session; treat §5 as thin by necessity, not because
    users have nothing to say. (unverified — search budget exhausted, §5, §8)

---

## 8. What could not be resolved

- **A forum-level practitioner survey.** This session's WebSearch budget (200/200) was consumed by
  earlier work in the programme before this report began, so no discovery search across Reddit,
  users.rust-lang.org, Hacker News or lobste.rs was possible, and §5's "count where you can"
  instruction could not be honoured with real numbers. What is in §5 is maintainer/designer
  writing that touches on user experience, clearly labelled as such, not a survey.
- **A primary source stating precisely what an async panic's default backtrace looks like.** The
  existence and stated purpose of `tokio-rs/async-backtrace` is strong indirect evidence that the
  default trace does not read as the logical `.await` chain, but no rustc or tokio document was
  found stating this failure mode directly in its own words; §4 marks the claim as inferred from
  the crate's existence rather than a documented statement.
- **Whether `?` inside a closure is a commonly reported real-world papercut** or mainly a
  theoretical hazard the RFC authors pre-empted. RFC 3058 documents the *related* try-blocks/
  closures contextual-type problem directly (quoted in §3), but no bug-tracker or forum thread
  specifically about `?`'s `return`-into-closure surprise was reachable this session.
- **An exact date for Yoshua Wuyts' "Announcing the keyword generics initiative" post.** The page
  was read successfully but no explicit publication date could be extracted from the fetched
  content; internal evidence (references to the async and const working groups as already active)
  places it circa 2021-2022, marked here as approximate.
- **The dyn-compatibility story for `async fn` in traits** (stabilised 2023, separately from the
  core mechanism this report covers) was mentioned only via boats' one remark about pinning a
  future trait object; a full account of `async fn in trait` and return-position `impl Trait`'s
  own design history was out of this report's scope and not pursued further given the budget
  constraint above.
