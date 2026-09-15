# Roc after `Task`: purity inference and the `!` suffix on effectful functions

**Commissioned by** the landscape's `roc-purity-inference` entry (`00-landscape.md` §2, Family J):
report 15 measured what Roc's backpassing (`x <- f a`) and its first `!` (`Task.await` sugar) cost
to build and to read, and both were removed. This report is about what came *after*: Roc deleted
`Task` — the effects-as-value type itself, not just its syntax — and replaced it with **purity
inference**: every function is either *pure* or *effectful*, the compiler infers which, `->` and
`=>` say which in a type, effectful names end in `!` by convention, and a pure function simply
cannot call an effectful one. There is no bind, no `andThen`, no do-notation, no generator, and as
of January 2025 no `Task` type at all. This is not a fifth syntax for sequencing effects; it is the
family's exit from the sequencing problem, by removing effects-as-data. The shared brief's family
taxonomy (do-notation, `use`, backpassing, `?`, `async`/`await`, generators, effect rows) has no
slot for it, and §1 explains why.

**Sources.** The vendored Roc compiler at `references/roc`, read at `HEAD` (`f083385b5b`,
2026-09-14) — now the **Zig** compiler, not the Rust one report 15 measured; Roc replaced its
implementation language while this feature was maturing, so `src/check/unify.zig` (Zig) is cited
alongside `crates/compiler/can/src/*.rs` (Rust, from git history) for the two eras of the same
mechanism. Git history read directly: the original `purity-inference` merge (`dfb2966281`,
2024-11-07), the `Remove Task from Roc` commit (`2150ee2219`, 2025-01-08, −14,295/+337 lines across
139 files), and the newest purity-unifier change in the repository, `1da6f04590` (Richard Feldman,
2026-09-09 — five days before this report). GitHub's API via `gh` for PR #7170 ("Purity inference")
and PR #7487 ("Remove Task from Roc") bodies, quoted verbatim below. The current language reference
(`docs/langref/functions.md`, `platforms.md`, `loops.md`, `operators.md`, `naming.md`) — itself
mid-rewrite, several sections literally `TODO`, evidence the docs are written alongside the
compiler, not after it. The `roc-zulip` skill, twelve threads read across `#ideas`, `#beginners`,
`#contributing`, `#platform development`, `#show and tell` and `#announcements`, 2024-08-28 to
2026-08-25, permalinks throughout. **Not reached**: Feldman's "The Functional Purity Inference Plan"
talk (YouTube `42TUAKhzlRI`, 2024-10-17) has no fetchable transcript; the original design-proposal
Google Doc renders only editor chrome to an unauthenticated fetch; the Houston FP abstract page
returned HTTP 403; the Changelog podcast episode 645 transcript discusses purity generally but not
the Task trade-off. §8 details what was substituted for each. Web sources accessed **2026-09-14**.

---

## 0. The three findings, up front

**1. Purity inference is the cheapest effect-typing mechanism in this whole research programme,
measured in what the type system needs — because it needs almost nothing.** It is not a monad, not
an effect row, not a class. In the current (Zig) checker it is a third case on the function
`FlatType`: `.fn_pure`, `.fn_effectful`, and `.fn_unbound` (`src/check/unify.zig:1148-1197`), unified
like any other structural type, with one extra list (`effect_deps`) carried only by the unbound
case. Report 15's `?`-on-`Task` alternative needed a **1,046-line** dedicated pass
(`suffixed.rs`); purity inference needed **zero** lines of desugaring, because after `Task`'s
removal `f!` and `f` parse to the *same* AST node — `git show 2150ee2219 -- can/src/desugar.rs`
shows `Var { .. }` moving into the catch-all "leave it alone" arm. The entire `!` mechanism is now a
naming convention checked by inference, not an operator.

**2. This was bought by giving up effects-as-values, and that is a different, larger trade than any
syntax choice — it forecloses Task's whole vocabulary (composability, retry, batching, and
above all concurrency), and twenty months later Roc's own contributors do not have a full
replacement.** Before purity inference, "the idea was that Roc returns tags and the platform
handles them like a state machine. I can see how parallel effects were possible in this world"
(Oskar Hahn, [2025-01-12](https://roc.zulipchat.com/#narrow/channel/302903-platform-development/topic/Parallel.20effects.20in.20a.20purity.20inference.20world/near/493171283)).
After it, effectful calls run immediately, so the platform never sees a data structure it could
batch or schedule; Sam Mohr's answer is "we just steal golang's green thread model"
([2025-01-12](https://roc.zulipchat.com/#narrow/channel/302903-platform-development/topic/Parallel.20effects.20in.20a.20purity.20inference.20world/near/493172137)),
pushed entirely into each platform's host. A proof-of-concept exists
(`bhansconnect/roc-coro-webserver`) but returning a closure to a host for concurrent execution "isn't
supported today" (Brendan Hansknecht,
[2025-01-15](https://roc.zulipchat.com/#narrow/channel/302903-platform-development/topic/Parallel.20effects.20in.20a.20purity.20inference.20world/near/493991093)).
Nineteen months on, a platform maintainer is still asking the open question: *"I think the `Task`
direction is great... Maybe more forward looking, but do we know how this will play with the roc
0.2.0 plan on concurrency?"* (Romain Lepert,
[2026-08-25](https://roc.zulipchat.com/#narrow/channel/397893-announcements/topic/roc-ray.200.9.0/near/618951964)).

**3. Roc explicitly designed, discussed at length, and rejected user-facing effect polymorphism —
then quietly needed a compiler-internal version of it anyway.** An `-fx->` type variable that would
let one `List.map` serve both pure and effectful callers was debated for 101 messages in
[`#ideas › opt-in effect polymorphism`](https://roc.zulipchat.com/#narrow/stream/304641-ideas/topic/opt-in.20effect.20polymorphism)
(2024-08-29) and turned down: *"We decided that if we could get away without that feature, we'd
probably be fine"* (Sam Mohr,
[2024-12-28](https://roc.zulipchat.com/#narrow/channel/316715-contributing/topic/More.20standard.20library.20purity.20inference/near/491125642)).
The accepted cost is a duplicated standard library (`List.walk` / `List.walk!`). Yet on 2026-09-09
— the newest commit in the vendored history that touches this feature — Feldman added exactly the
polymorphism machinery Ayaz Hafiz had argued for two years earlier, invisibly, inside the unifier
(`fn_unbound`'s `effect_deps`), to fix a real soundness bug where an unresolved higher-order
callback's effect was not correctly propagated (`src/check/test/issue_11245_test.zig`). The user
still writes no `fx` annotation; the compiler tracks the polymorphism it publicly said it wouldn't
expose.

---

## 1. The effect model

**There is no effect type.** Where Elm has `Task x a` and Roc itself used to, current Roc has
nothing standing between "call a function" and "the effect happens." An effect is not deferred,
represented as data, returned, composed, or interpreted by anything — it is an ordinary function
call that the platform's linked object code executes when control reaches it. `docs/langref/functions.md:44-105`
is the whole model:

> "Roc makes a first-class distinction between _pure functions_ and _effectful functions_ (functions
> that are not pure)... A function is effectful if it calls another effectful function, and
> otherwise it's pure. Effectful functions can only be called by other effectful functions; pure
> functions and top-level constants can only call pure functions."

"Sequencing two effects," in this model, is not a construct at all — it is just two statements in
the order the programmer wrote them, the way `console.log(a); console.log(b)` sequences in
JavaScript. The type system's only job is to make sure a function's own effectfulness matches what
it does, and that a pure function cannot smuggle an effect in through a call. Purity is checked, not
merely conventional: `Roc's compiler reports a warning if an effectful function's name does not end
in !` (`functions.md:82`), and — the load-bearing rule — *calling* an effectful function from a pure
one is a type error, not a lint (`fd2493ee51`'s `EFFECT IN PURE FUNCTION` diagnostic, §4).

Purity is inferred **bottom-up through ordinary unification**, with a third state for "not yet
known." `src/check/unify.zig` distinguishes three function shapes:

```zig
// merge()  — src/check/unify.zig:512-521
.fn_pure => |func| {
    // A pure function's effect formula is discharged: every
    // dependency it ever had was made pure when the two
    // sides unified, so the merged type carries none.
    return Content{ .structure = FlatType{ .fn_pure = .{ .args = func.args, .ret = func.ret } } };
},
.fn_effectful => |func| {
    return Content{ .structure = FlatType{ .fn_effectful = try self.funcForMerge(vars, func) } };
},
.fn_unbound => |func| {
    return Content{ .structure = FlatType{ .fn_unbound = try self.funcForMerge(vars, func) } };
},
```

`fn_unbound` is a function whose purity is not yet decided because it depends on other not-yet-known
functions (typically a callback parameter) — its `effect_deps` field carries exactly those
dependencies. Unifying it against `fn_pure` walks the dependency list and *demands* purity from each
one (`demandPureEffectDeps`, `unify.zig:2841-2884`); unifying it against `fn_effectful` propagates
effectfulness the same way (`unify.zig:1162-1197`); pure and effectful can never unify with each
other (`error.TypeMismatch`, `unify.zig:1132,1148`). This is Hindley-Milner unification with one
extra lattice bolted onto function types — no type class, no higher-kinded abstraction, no effect
row, no dictionary. The three-line summary the docs give is deliberately unglamorous:

> "By design, Roc has no syntax for 'either pure or effectful.' That is, there's no concept of
> _effect polymorphism_ like you might find in some languages that support algebraic effects."
> (`functions.md:71-72`)

That sentence is true of the **surface syntax** and false of the **inference engine**; §0.3 and §3.5
return to the gap.

**How effects run without a runtime.** Roc platforms are compiled, linked binaries: "the host
implements `main()`, and then at some point it calls a function exposed by the compiled Roc
application... the Roc application compiles down to a C library which the platform can choose to
call" (`docs/langref/platforms.md`, "Program start"). An effectful function like `Stdout.line!` is
not a `Task` the platform interprets; it is a symbol the platform's `provides` mapping links to a
host implementation, and calling it in Roc is calling it, full stop — the same way beni's own
`foreign` boundary (report 13) is a controlled but direct call, not an interpreted description. The
one restriction purity buys the compiler is at *compile time*: "Roc's compiler does not run
platform-provided low-level code during compilation... none of your dependencies... are permitted to
perform arbitrary I/O operations on your system" (`platforms.md`) — a comptime-safety property, not
a performance claim this report otherwise engages with.

---

## 2. The mechanism

**What the user writes.** An effectful function's *name* ends in `!`; its *type annotation* uses
`=>` instead of `->` for every arrow whose call performs (or may perform) an effect:

```roc
pure_fn : Str, Str -> Str

run_fx! : Str, Str => Str
```

(`functions.md`, "Function Type Annotations"). Calling it is calling it — no operator, no
backpassing arrow, nothing at the call site:

```roc
main! = |_args| {
    Stdout.line!("Hello, World!")?
    Ok({})
}
```

(`platforms.md`, the canonical "Hello, World" example; the trailing `?` here is the ordinary `Try`
early-return operator report 15 already covers, unrelated to effectfulness).

**What it compiles to.** Nothing extra. `git show 2150ee2219 -- can/src/desugar.rs` (the `Remove
Task from Roc` commit) shows the entire rewrite disappearing: before removal, `Var { ident }` ending
in `!` was rewritten to a `TrySuffix { target: TryTarget::Task, .. }` node that a later pass
(`suffixed.rs`) unwrapped into a `Task.await` call with a synthesized continuation lambda — exactly
report 15's 1,046-line mechanism. After removal, `Var { .. }` moved into the "leave this node alone"
arm alongside literals and underscores. **`f!` and `f` are the same call.** The only thing `!`
still does downstream of parsing is participate in symbol identity — Feldman: *"For Purity
Inference, I reserved one bit of `Symbol`s as a `!`-prefixed flag and it greatly simplified the
implementation overall"*
([2025-02-02](https://roc.zulipchat.com/#narrow/channel/316715-contributing/topic/approach.20to.20optimization/near/497211406)).

**What the type system must know.** A per-function-type purity tag with a three-state unification
lattice (§1) — nothing beyond ordinary HM. Contrast the class-directed family (Haskell `do`,
PureScript `ado`) which needs a `Monad`/`Applicative` dictionary, and the effect-row family (Koka,
Unison) which needs row polymorphism; purity inference needs neither, at the cost of only
distinguishing "does or doesn't," never "does what."

**Where the marker may appear.** Nowhere in *expression* position — this is the single biggest
structural difference from the `!` report 15 measured. It appears only on **names**: function
definitions, and per the original PR body, more broadly than that —

> "The `!` suffix is not only required on defs, but also on record fields, and all pattern matched
> identifiers (tuple, tags, opaques, etc)."
> — Agus Zubiaga, PR body, [roc-lang/roc#7170](https://github.com/roc-lang/roc/pull/7170)

There is no "anywhere an expression may appear" cost at all, because there is no rewrite to place.

### 2.1 The hard cases

**`fetchSummary`, in current Roc:**

```roc
fetch_summary! : Str => Summary
fetch_summary! = |token| {
    user = get_user!(token)
    perms = get_permissions!(user)
    if perms.is_admin {
        log = get_audit_log!(user)
        Summary(user, perms, Some(log))
    } else {
        Summary(user, perms, None)
    }
}
```

There is no `andThen`, no `use`, no `<-`, no `!` at the call site beyond the name itself. The bound
value from inside the `if` (`log`) is used in the same branch that produced it, with **zero** extra
nesting versus the pure version of the same function — because there is no wrapping construct to
open a level for. This is the flattest of every `fetchSummary` translation this research programme
has produced, and it is flat by *removing the mechanism*, not by improving it.

**Bind inside a loop.** Roc's native `for` and `while` loops (`docs/langref/loops.md`), with mutable
`var $x` locals, make this trivial for the same reason:

```roc
var $count = 0
for line in lines {
    write_line!(line)
    $count = $count + 1
}
```

`write_line!` is an ordinary statement inside an ordinary imperative loop. There is no fold, no
`Task.loop`, no accumulator threaded through a callback. This did not come free with purity
inference alone — it required Roc to *also* add native loops and mutable local bindings, which
report 15 and `fast-compiler.md` both treat as a separate, larger language decision (statements vs.
expression-only). Before native loops existed, the idiom was a hand-written recursive `loop!`
combinator; when a user proposed adding one to the standard library after upgrading code that used
`Task.loop`, Agus Zubiaga's answer was *"I'm not sure it adds much in the purity inference world...
using recursion with `Task` is a little less intuitive, so `Task.loop` makes sense [but] I'm not
sure it adds much"* here
([2024-11-08](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/purity-inference.20.60loop.21.60/near/481235684)) —
Task needed a trampoline combinator to avoid an ugly recursive-await shape; direct calls under a
native loop need nothing.

**Bind inside a branch.** Shown above in `fetchSummary`'s `if`; there is no synthesized lambda to
open a block for, so this is unconditionally free, in every position `if`/`match` allows.

**Early return.** Report 15 §2.1(c) is Roc's own worked hazard from the backpassing era: an early
`return` inside a synthesized continuation lambda returns from the *lambda*, not the function the
reader is looking at. **That hazard cannot occur under purity inference, because no lambda is ever
synthesized.** A `return` or a `?` inside an effectful function's body returns from that function,
full stop, the same as in any imperative language — this is a categorical elimination of the
problem, not a mitigation of it (report 15's beni answer, forbidding `?` in a lambda via
`question_in_lambda`, is a scope check that purity inference makes unnecessary for effect
sequencing specifically, though it remains necessary for `?`-on-`Try`, which is untouched).

**Pattern matching on a bound value.** Ordinary destructuring, since there is no bind construct
constraining the pattern shape — `user = get_user!(token)` can be any assignment pattern Roc's
`match`/`=` already supports, with the same exhaustiveness rules as anywhere else
(`docs/langref/statements.md`).

**Mixing two effect "types."** There is only one axis (pure/effectful), not effect *rows*, so this
question doesn't apply the way it does to Koka or Unison. `Try` (Roc's `Result`, renamed) still
composes with effectfulness orthogonally: `File.read_line!(path)?` calls an effectful function and
then unwraps its `Try` with the ordinary `?` — two independent mechanisms, not one merged mechanism,
and report 15's coverage of `?` is unchanged by any of this.

**Error propagation.** Unchanged from report 15 and `fast-compiler.md` §3.2: `?` on `Try` is a local
`case`/early-return, unaffected by whether the function is pure or effectful.

---

## 3. History and decisions

### 3.1 The proposal (2024-08-28) and the symbol-density objection

Richard Feldman posted a design document to `#ideas › Purity Inference` on 2024-08-28
([465772379](https://roc.zulipchat.com/#narrow/stream/304641-ideas/topic/Purity.20Inference/near/465772379)),
the same document behind the "Functional Purity Inference Plan" talk (§8). The sharpest immediate
pushback was not about the mechanism but about *notation density*:

> "as an outsider who occasionally checks in on the ecosystem, I feel like the language is
> accumulating a lot of sugar and symbols... right now I'm thinking about seeing `!`, `_`, `*`, `?`,
> `->`, `,`, and `=>`. it feels somewhat overwhelming for a language [that] bills itself as
> friendly."
> — drew, [2024-08-28](https://roc.zulipchat.com/#narrow/stream/304641-ideas/topic/Purity.20Inference/near/465823141)

Feldman reframed rather than conceded it: *"one related data point is that Ruby code has all of
those symbols... and I haven't heard people finding Ruby hard for beginners to learn or read"*
([465823430](https://roc.zulipchat.com/#narrow/stream/304641-ideas/topic/Purity.20Inference/near/465823430)).
Alternative markers (`$`, `@`) were floated on the grounds that `!` already means negation as a
prefix and macro-invocation in Rust as a suffix; Feldman's answer was that Rust's precedent for that
dual role was *why* he was comfortable with prefix `!x` ("not") and suffix `x!` ("effectful")
coexisting — and the type-annotation use is unambiguous, since there is no prefix `!` in a type.

### 3.2 Opt-in effect polymorphism: proposed, argued for 101 messages, and declined

The largest design debate, `#ideas › opt-in effect polymorphism`
([2024-08-29](https://roc.zulipchat.com/#narrow/stream/304641-ideas/topic/opt-in.20effect.20polymorphism)),
was whether a function like `List.map` should carry a hidden effect-polymorphism variable so one
definition serves both `List.map` and a would-be `List.map!`. Ayaz Hafiz argued for hiding the
polymorphism entirely from surface syntax: *"Every arrow `->` is potentially effect polymorphic.
Effectful calls are determined at the call site."* Feldman and Sam Mohr's counter, worked through
with a concrete caching-function example
([466051425](https://roc.zulipchat.com/#narrow/stream/304641-ideas/topic/opt-in.20effect.20polymorphism/near/466051425)),
was that invisible polymorphism breaks a caller's ability to *see* whether a value passed through is
safe to treat as pure (a caching wrapper handed an "effectively effectful" callback silently returns
stale results). The decision, stated by Feldman directly:

> "I think the incentives around the 'only use polymorphism in the most powerful and rare cases like
> `walk` and `parallel`' design are good."
> — [2024-08-29](https://roc.zulipchat.com/#narrow/stream/304641-ideas/topic/opt-in.20effect.20polymorphism/near/466062998)

Three months later the consequence landed in `#contributing › More standard library purity
inference` ([2024-12-28](https://roc.zulipchat.com/#narrow/channel/316715-contributing/topic/More.20standard.20library.20purity.20inference)):
a user asked outright, *"Does the purity inference work mean that we'll need a pretty much duplicate
stdlib? One effectful one pure?"*, and Sam Mohr answered, *"Just for the functions we want to have
potentially effectful, but yes"* — followed immediately by the quote in §0.3 recording the trade-off,
plus the note that user-defined effect-polymorphic *functions* (not *builtins*) remain possible via
ordinary parametric polymorphism, just without dedicated `-fx->` sugar (Brendan Hansknecht,
[466050273](https://roc.zulipchat.com/#narrow/stream/231634-beginners/topic/Purity.20Inference%20and%20Testing/near/466050273)).

### 3.3 The `purity-inference` merge (PR #7170, 2024-11-07) — Task kept working underneath

The PR that shipped the feature is explicit that this was additive, not yet a replacement: *"`Task`
still works if that's what the platform exposes in its `hosted` module. This will allow us to
migrate platforms incrementally"* (Agus Zubiaga, PR body,
[roc-lang/roc#7170](https://github.com/roc-lang/roc/pull/7170)). At this point `!` still desugared to
`Task.await` under the hood for unmigrated platforms (`can/src/desugar.rs`, commit `aeeaab4b99`,
comment: *"TODO remove when purity inference fully replaces Task"*) — the two effect models
coexisted for two months as two implementations of the same surface syntax.

### 3.4 Removing `Task` (PR #7487, 2025-01-08) — the second, larger deletion

> "Fully removes `Task` and the `!` suffix from Roc [as an operator]. If you grep for it, there are
> only a couple places left where you'll find it: the website... some already out-of-date docs...
> [and] syntax tests that don't actually use Task to run code."
> — Sam Mohr, PR body, [roc-lang/roc#7487](https://github.com/roc-lang/roc/pull/7487)

`git show 2150ee2219 --stat`: **139 files, −14,295/+337 lines** — an order of magnitude larger than
backpassing's 2,246-line removal (report 15 §2.1), because it deleted an entire builtin
(`builtins/roc/Task.roc`, 305 lines), the whole `suffixed.rs` continuation-lifting pass (1,046
lines, the same file report 15 measured), and every snapshot test built against it. Luke Boswell's
review comment — the only one on the PR — was *"Very nice 😄 Also tested this against basic-cli &
basic-webserver with all tests ✅"*; no dissent is recorded on the PR itself (contrast report 15's
extensively contested backpassing removal, §2.1). The word "suffix" in the title is precise, not
loose: what was removed is `!` *as an operator with rewrite semantics* (`TryTarget::Task`); `!` as a
bare naming convention on effectful functions is what survives and is documented today.

### 3.5 The internal effect-polymorphism the docs say doesn't exist (2026-09-09)

The newest commit touching this feature in the vendored history is not a syntax change at all.
Richard Feldman, `1da6f04590`, five days before this report:

> "An effect-polymorphic function's type carries the functions whose effect decides its own, so
> unifying it with a pure function type requires each of those dependencies to be pure. The unifier
> now rewrites each still unresolved dependency to a pure function (recursively) and rejects one
> that has already become effectful, and a merged pure type carries no dependencies."
> — commit message, `1da6f04590`

The regression test it fixes (`src/check/test/issue_11245_test.zig`) is concrete: a function that
hands a list of callbacks to a pure higher-order builtin (`List.join_map`) must reject a caller that
sneaks an effectful callback into that list, *even when the callback's effectfulness was still
unresolved at the point the higher-order call was type-checked*. Without the fix, "an `expect` that
performs an effect is accepted and crashes at runtime" (the test file's own doc comment). This is
exactly the `fn_unbound`/`effect_deps` machinery of §1 — real, load-bearing, and under active repair
nineteen months after §3.2 settled that users would never see an `fx` type variable. The user-facing
promise ("no syntax for effect polymorphism") held; the compiler-internal promise ("we can get away
without [tracking] it") did not.

---

## 4. Costs — ergonomic and structural

**Standard-library duplication, accepted and documented.** `List.walk` and `List.walk!` are
different functions with different types; a user asked directly, *"will there be effectful versions
of all higher-order functions in the builtins? ... the current builtins documentation has a
`List.walk!` but not a `List.map!`"* (misterdrgn,
[2025-01-31](https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Effectful.20higher-order.20functions/near/496999211)),
and Feldman's answer was to hold the line: *"I'd like to hold off on `map!` until we've seen some
use cases where it's desirable over `for_each!`"*
([2024-12-28](https://roc.zulipchat.com/#narrow/channel/316715-contributing/topic/More.20standard.20library.20purity.20inference/near/491117460)).
The cost is real but bounded by policy, not by the type system: each effectful variant is a
hand-written duplicate, added on demonstrated need (`List.walk!` was filed as
[roc-lang/roc#7425](https://github.com/roc-lang/roc/issues/7425), "a pretty good beginner issue" per
Sam Mohr) rather than generated.

**Diagnostics are markedly better than the `Task`-era ones report 15 documented**, because there is
no desugared code to leak into an error message. Compare report 15 §4.3's *"utterly useless"*
`Task.await`-shaped errors to purity inference's:

```
── EFFECT IN PURE FUNCTION in /code/proj/Main.roc ──────────────────────────────

This expression calls an effectful function:

10│      name = Effect.getLine! {}
                ^^^^^^^^^^^^^^^^^^

However, the type of the enclosing function indicates it must be pure:

8│  getCheer : Str -> Str
               ^^^^^^^^^^

Tip: Replace `->` with `=>` to annotate it as effectful.

You can still run the program with this error, which can be helpful
when you're debugging.
```
— `fd2493ee51`, `crates/compiler/load/tests/test_reporting.rs`. The error points directly at the
real call and the real annotation, because none of it went through a rewrite; and it is deliberately
a soft failure at `roc run` time (the last line), which report 15 never needed to consider because
`Task`-based programs had no equivalent "run it anyway" escape hatch for a type mismatch.

**The compiler-pipeline cost lands in the unifier, not the desugarer — and it is not finished.**
Where report 15 measured the old `!`'s cost as a 1,046-line standalone pass that could in principle
be deleted without touching anything else, purity inference's cost is diffused through `unify.zig`'s
core merge and instantiate logic (`fn_pure`/`fn_effectful`/`fn_unbound` appear in over twenty match
arms; `demandPureEffectDeps` and `funcForMerge` are ~90 lines together) and is still being corrected
five days before this report was written (§3.5). It is a smaller total surface than a full effect-row
system, but it is inference-invasive in a way beni's preferred `?`-on-`Try` design
(`fast-compiler.md` §3.2, "desugars in the desugarer... nothing touching inference") specifically is
not.

**Testing effectful code lost the Elm-architecture story.** A newcomer noted you can no longer "just
really test your main update function with some inputs and assert... the effect you expect to run,"
comparing to Elm (Unshipped9094,
[2025-01-28](https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Purity.20Inference.20and.20Testing/near/496257414)),
because an effectful function's effects are not returned as inspectable data — they simply happen.
Brendan Hansknecht concedes the trade: testability *can* be recovered, but only by hand-building an
Elm-Architecture-shaped platform on top of purity inference — *"You would make a platform that takes
a union of commands as output... It would actually be 100% pure. Would make it a lot more directly
testable like in elm"*
([2025-01-28](https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Purity.20Inference.20and.20Testing/near/496265742)) —
what `Task`-as-data gave every program by construction, purity inference requires opting back into
by re-introducing the effects-as-values pattern it removed.

**Newcomer friction with "no effects at all" contexts.** Roc's web REPL disappointed at least one
evaluator on first contact for a reason specific to this design: *"the first time I tried Roc's REPL,
I quickly wondered what I could actually do, other than pure functions. When I realized that there
were no effects, I was a bit disappointed"* (Aurélien Geron,
[2026-08-07](https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/Roc.20web.20REPL.20design/near/615139923)) —
a direct consequence of effectful functions requiring a linked platform to exist at all, which a
sandboxed REPL by definition does not have.

**Runtime cost is out of scope for this report** (cross-cutting question 6). The one number Roc's
own docs offer is framed as a design *motivation*, not a measured claim, so it is reported and set
aside: pure top-level values can be evaluated at compile time because purity guarantees the answer
never depends on when it runs (`functions.md`, "Pure Functions").

---

## 5. What users say

Of the twelve Zulip threads read for this report that discuss purity inference or its consequences
by name, only the original `Purity Inference` proposal thread (§3.1) and `opt-in effect
polymorphism` (§3.2) contest the *mechanism itself*; the other ten are practitioners working out its
downstream consequences — the stdlib split, testing, and above all concurrency. That split is itself
the finding: **nobody in this sample re-litigated pure-vs-effectful after August 2024; the live
argument for the next two years was entirely "now that effects aren't data, how do I get the things
`Task`-as-data used to give me for free."**

**Praise**, from someone maintaining a real platform, not evaluating a toy: *"I think the `Task`
direction is great with all the new IO capabilities (Http/Files/Socket/etc.). It is a big milestone
that I am happy to work with in its current form"* (Romain Lepert, roc-ray maintainer,
[2026-08-25](https://roc.zulipchat.com/#narrow/channel/397893-announcements/topic/roc-ray.200.9.0/near/618951964)).
A beginner comparing the discipline favourably to Haskell: *"I imagine the feel will be similar to
Haskell, where you try to minimize the code that needs to be in any kind of `IO` code"*
(Unshipped9094, [2025-01-29](https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Purity.20Inference.20and.20Testing/near/496453568)).

**Complaints**, mostly evaluator- rather than maintainer-voiced: drew's symbol-density concern
(§3.1); Aurélien Geron's REPL disappointment (§4); a maintainer's discovery that duplicated
higher-order builtins are a permanent tax, not a transitional one (misterdrgn, §4).

**Wishes**, overwhelmingly about concurrency: Oskar Hahn's two threads
([Parallel effects in a purity inference world](https://roc.zulipchat.com/#narrow/channel/302903-platform-development/topic/Parallel.20effects.20in.20a.20purity.20inference.20world),
[stackful coroutines in hosts](https://roc.zulipchat.com/#narrow/stream/304641-ideas/topic/stackful.20coroutines.20in.20hosts))
are a single practitioner methodically trying to build a parallel-HTTP-fetch platform and finding,
at every step, that the feature he needs was retired along with `Task`; Romain Lepert's still-open
question above is the same request from a different, later maintainer. No thread in this sample
reports the concurrency gap as *resolved*.

---

## 6. What it would take to do this in beni

**The type system cost is genuinely the cheapest option this whole 14-family programme has
surveyed.** A three-state lattice on function types — pure, effectful, unbound-with-dependencies —
unifies inside plain Hindley-Milner with no type class, no higher-kinded type, and no row
polymorphism, all three of which `fast-compiler.md` §3.1 has already ruled out for beni on other
grounds. Concretely: one more `Content`/`FlatType` variant (or, per Feldman's own shortcut, a bit on
the identifier), a `demandPureEffectDeps`-shaped recursive walk (~40 lines in Roc's Zig), and a
merge rule that unions `effect_deps` lists (~20 more). That is smaller than beni's own `?`-on-`Try`
design and orders of magnitude smaller than report 15's 1,046-line `suffixed.rs`.

**But it is not additive to beni's current stance — it replaces it.** `fast-compiler.md` §3.1
settles that "a `Task e a` is a value a platform interprets," and purity inference is not a syntax
for writing that value more conveniently; it is the abolition of that value. A pure function
"cannot call an effectful function" only means something if calling *is* running — which is
precisely false of a `Task`, whose entire value is that constructing one does not run it. Adopting
purity inference for beni means reopening §3.1, not extending it — a trade to weigh, not a strictly
better option:

- *What it would deliver*: every hard case in §2.1 solved with **zero new syntax at all** — no
  `use`, no `?`-on-effect, no generator, no backpassing. It is a stronger answer to the shared
  brief's `fetchSummary` problem than anything else this research programme has found, because it
  removes the need for a mechanism rather than adding a better one.
- *What it would cost beyond the unifier*: the vocabulary of report 16 ("what a `Task` runtime must
  do") — batching, retry combinators, `Task.parallel`, cancellation — has no home. Roc's own answer,
  twenty months in, is "the platform must invent this per-platform" (§0.2, §5), and Roc's platforms
  are native linked binaries with real threads and green-thread libraries available to them.
- *The warning specific to beni's JS target*: Roc's trick — effectful calls execute eagerly with no
  colouring, no `async`, no state machine — depends on a host that can block or hand off a stack when
  an effect blocks. JavaScript offers neither by default; every genuinely asynchronous browser or
  Node primitive is a `Promise`. Porting "effectful call = ordinary call" onto JS either restricts
  `!` to primitives that really are synchronous (`Date.now`, `Math.random`) — a far smaller surface
  than Roc's file/socket/HTTP set — or forces generated JS to be `async`, reintroducing the
  function-colouring problem `fast-compiler.md` §3.2's "no generators" stance exists to avoid. Roc
  escapes colouring by owning the runtime down to the linker; beni does not own the runtime, the JS
  event loop does. This is the one place §0's "cheapest type system" finding does not transfer along
  with the type system.

**What it solves and doesn't, restated against §2.1**: bind-in-loop and bind-in-branch, solved
completely and for free, contingent on beni also having (or adding) native loops with mutable
locals, exactly as Roc's win was contingent on the same prerequisite (§2.1). Early return, solved
categorically rather than mitigated. `?`/`Try` sequencing and mixing effect "types," untouched —
orthogonal to this mechanism in Roc and would remain so in beni. Concurrency, retries, and effect
composition: **not solved, and not solvable by this mechanism** — that problem moves wholesale to
beni's JS "platform" (report 13's boundary), which would face it with a strictly worse hand than
Roc's native hosts.

---

## 7. Ranked summary

1. Purity inference needs no type class, HKT, or row polymorphism — a bare pure/effectful/unbound
   lattice inside ordinary unification. (measured: `unify.zig`, `dfb2966281`, `2150ee2219`)
2. The old `!` (Task-await sugar) is gone as an operator; `!` today is a checked naming convention
   with zero desugaring. (measured: `git show 2150ee2219 -- can/src/desugar.rs`)
3. Removing `Task` deleted 14,295 lines across 139 files — six times backpassing's removal — with
   no recorded community dissent on the PR itself. (measured + documented: PR #7487)
4. User-visible effect polymorphism (`-fx->`) was proposed, argued for 101 messages, and explicitly
   declined in favour of a duplicated pure/effectful standard library. (documented: `#ideas › opt-in
   effect polymorphism`, `#contributing › More standard library purity inference`)
5. The compiler tracks effect polymorphism internally anyway (`fn_unbound`/`effect_deps`), and a
   real soundness bug in that tracking was fixed five days before this report was written.
   (documented: commit `1da6f04590`, 2026-09-09)
6. Diagnostics improved sharply over the `Task`-era ones report 15 measured, because there is no
   rewrite left to leak into an error message. (documented: `fd2493ee51`)
7. Concurrency, retry, and Task-style composition have no replacement as of this writing; every
   platform must invent its own, and the question was still open in public 20 months after `Task`'s
   removal. (documented: `#platform development` threads, 2025-01 and 2026-08)
8. Native `for`/`while` loops with mutable locals are a co-requisite for purity inference's loop
   ergonomics, not a consequence of it — the same dependency beni's own generator/state-machine
   options in report 15 have. (inferred, from `loops.md` and the `purity-inference loop!` thread)
9. What Roc's own contributors would flag for a JS-only target: purity inference's "no colouring"
   property is bought by owning a native host; it does not obviously survive a host whose only true
   asynchrony primitive is the `Promise`. (inferred, from §1's platform mechanism and report 13)
10. Practitioner sentiment on the mechanism itself is quiet; nearly all sustained community energy
    after August 2024 went into concurrency and stdlib duplication, not the pure/effectful split.
    (documented: §5's thread survey)

---

## 8. What could not be resolved

- **Feldman's original design document** (the Google Doc linked from the 2024-08-28 Zulip post) —
  an unauthenticated fetch returns only editor chrome, not content. Compensated with the Zulip
  thread that quotes and argues with it in detail (§3.1, §3.2) and the shipped PR's description
  (§3.3).
- **"The Functional Purity Inference Plan" talk** (YouTube `42TUAKhzlRI`, 2024-10-17) and the
  **Houston Functional Programmers abstract** for it — no transcript is fetchable (the HFPUG page
  returns HTTP 403 unauthenticated). Compensated with PR #7170's body, which cites the talk and
  restates its content point by point (§3.3), and the Zulip threads discussing its reception.
- **Changelog podcast episode 645** — fetched, but its transcript covers purity inference generally,
  not the Task-to-purity transition or what was given up. Treated as "no source found" for that
  angle.
- **The current, complete list of `!`-suffixed standard-library duplicates** — only the ones named
  in the Zulip threads read for this report are cited; `roc docs` was not run (read-only).
- **Whether a first-class parallel-effects combinator has since shipped** — the newest evidence
  (Romain Lepert, 2026-08-25, one month before this report) shows the question still open; no later
  resolution was located.
- **Runtime cost** (cross-cutting question 6) is out of scope by the shared brief; §4 notes the one
  performance-motivated design fact (compile-time evaluation of pure constants) in one sentence and
  does not measure it.
