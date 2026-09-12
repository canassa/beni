# Currying, and Roc's decision not to have it

Research into the one genuinely contested decision in the Beni design (§9.3): keep Elm-style
automatic currying, or follow Roc/Gleam into explicit partial application.

Primary source: Roc's FAQ, plus ~3 years of roc.zulipchat.com history read via
[`.claude/skills/roc-zulip`](../../../.claude/skills/roc-zulip/SKILL.md). Chat is people thinking
out loud — quotes are attributed and dated, and team claims are marked where unverified.

---

## 1. The canonical documented rationale

From Roc's FAQ, *"Why aren't Roc functions curried by default?"*
(https://www.roc-lang.org/faq#curried-functions) — the only place the decision is officially
argued. Currying's downsides, verbatim:

> - It lowers error message quality, because there can no longer be an error for "function called
>   with too few arguments." (Calling a function with fewer arguments is always valid in curried
>   functions; the error you get instead will unavoidably be some other sort of type mismatch, and
>   it will be up to you to figure out that the real problem was that you forgot an argument.)
> - It significantly increases the language's learning curve.
> - It facilitates pointfree function composition.
>
> There's also a downside that it would make runtime performance of compiled programs worse by
> default, but it would most likely be possible to optimize that away at the cost of slightly
> longer compile times.
>
> These downsides seem to outweigh the one upside (conciseness in some places).

On the learning curve, the FAQ concedes the counter-example directly:

> Clearly currying doesn't preclude a language from being easy to learn, because Elm has currying,
> and Elm's learning curve is famously gentle. That said, beginners who feel confused while
> learning the language are less likely to continue with it.

On pointfree style, it goes further than "we don't need it": *"since currying facilitates pointfree
function composition, making Roc a curried language would have the downside of facilitating an
antipattern in the language."*

Note that the FAQ lists runtime performance as a cost of **having** currying, hedged as probably
optimisable away — it is not the primary argument, and Roc does not claim a measured win.

## 2. The error-message argument, with a concrete artifact

This is the strongest claim and the only one with a demonstrable artifact. Because Roc functions
are never validly partially applied, "wrong argument count" stays its own localised error class
rather than degrading into a type mismatch somewhere else:

```
── TOO FEW ARGS in BinarySearch.roc ────────────────────────────────────────────
The get function expects 2 arguments, but it got only 1:
7│          middle_value = array |> List.get(middle_index)?
                                    ^^^^^^^^
Roc does not allow functions to be partially applied. Use a closure to
make partial application explicit.
```

— Anton, #bugs › "too few args", 2025-01-25,
https://roc.zulipchat.com/#narrow/channel/463736-bugs/topic/too.20few.20args/near/495876278

**Caveat worth recording:** the other half of the argument — that a curried language necessarily
produces a confusing distant error here — is asserted in the FAQ, never demonstrated, and cannot be
demonstrated from Roc, which never shipped a curried mode to compare against.

## 3. The fuller argument from chat

**The team's strongest empirical claim**, Anton, #beginners › "question about tutorial and some
comments", 2025-12-30, replying to a newcomer who said he disagreed with the decision
(https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/question.20about.20tutorial.20and.20some.20comments/near/565767645):

> I believe Richard taught currying numerous times in a practical setting and noticed difficulties
> when people had to use it. So the experience may be different from explaining the concept.
> [...] We experience a lot of benefits from minimizing the number of features and concepts in the
> language. Perhaps most importantly, once people gain some experience with Roc they never miss
> currying. **We've had zero reports from people still wanting currying after using Roc for a
> couple of months.**

That is the closest thing to a retrospective in the corpus, from a core contributor two-plus years
after the FAQ was written. It is an unverified team claim — no survey, no count.

**The observation that undercuts the antipattern argument**, Richard Feldman — creator of both
languages — #ideas › "static dispatch - partial application syntax", 2025-01-13
(https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/static.20dispatch.20-.20partial.20application.20syntax/near/493255245):

> it does remind me that Elm is curried, and actually even ships with function composition
> operators, and yet pointfree function composition is culturally done very little in practice
> (slightly more than in Roc, where it isn't done at all, but not enough for it to be a serious
> problem imo)

He does not draw the conclusion, but it follows: **Elm demonstrates that culture suppresses the
antipattern without removing currying.** The FAQ's third bullet is therefore the weakest of the
three.

**Sam Mohr**, #beginners, 2024-06-30: *"it can be very easy to write code using currying that's
harder for beginners to understand, and there isn't enough of a benefit to overcome that
detriment."*

## 4. The costs, in Roc users' own words

**The pipe operator already buys most of what currying was for.** A newcomer wanting point-free
definition, told Roc doesn't support automatic partial application, replied — and went unrebutted
in the thread (Tobias, #beginners › "Point-free function definition", 2025-05-19,
https://roc.zulipchat.com/#narrow/channel/231634-beginners/topic/Point-free.20function.20definition/near/519160681):

> I read the FAQ on currying. But I feel like pipe support is sabotaging the argument.

**No-currying forces pipe-first, and the team calls the convention arbitrary.** Brendan
Hansknecht, #beginners › "Can pipe-last (`|>>`) be implemented in user-space?", 2024-06-01
(https://roc.zulipchat.com/#narrow/stream/231634-beginners/topic/Can.20pipe-last.20.28.60.7C.3E.3E.60.29.20be.20implemented.20in.20user-space.3F/near/441955479):

> Mostly around API design. Roc is not a curried language (curried languages tend to promote pipe
> last APIs). As such, Roc tends to design APIs such that the main element is the first element of
> a function. `List.someThing` functions always take the List first. [...] Given roc isn't curried,
> we have chosen the convention to put what is operated on first. **This is essentially an
> arbitrary convention.**

**A named cost that isn't mere unfamiliarity.** Eli Dowling, #ideas › "method for partial
application", 2024-03-11
(https://roc.zulipchat.com/#narrow/channel/304641-ideas/topic/method.20for.20partial.20application/near/426024299):

> One of the few design decisions in roc that makes me annoyed is the lack of partial
> application/currying. I actually agree with most of roc's reasons for not including it, but the
> added friction when making specialized versions of more generic functions does annoy me. It's
> something I do a lot when writing F# and OCaml code and I find it is very much a "pit of success"
> type effect. [...] I recently saw the Gleam language, it allows using an underscore in a function
> call to automatically return a partially applied version. [...] [it reduces] a whole collection
> of errors that can occur when you accidentally switch the order of variables.

That Gleam-style `_` proposal was discussed and dropped; the standing answer stays "write a lambda."

**Manual currying works, with syntax tax at every site.** `curried = |x| |y| existing(x, y)`, and a
user-space `curry2` helper is possible (Brendan Hansknecht, #beginners, 2026-01-02). The recurring
community line, half-joking, is *"roc has currying Q.E.D."* — technically true, and it sidesteps the
actual complaint, which is about the automatic case.

**A mechanical papercut for arrivals from Haskell/Elm/OCaml:** repeatedly, newcomers write
`a -> b -> c` signatures and hit confusing parse errors, because Roc's syntax is `a, b -> c`.

## 5. Regret: none found

Searched `regret`, `wish we had`, `wish roc had` across all channels. No hits concern currying.
Across roughly three years and many newcomer objections, **no core contributor expresses doubt**.
The posture is consistent re-affirmation under pushback.

When an adjacent feature (`val.(fn)` partial-application syntax, proposed during static-dispatch
design) threatened to reintroduce currying by a side door, Ayaz Hafiz flagged it as *"straight up
currying"* and the team killed it — Feldman: *"my default thinking is that we shouldn't do the
partial application thing, largely on the grounds that all else being equal I don't think Roc would
be improved by adding an ad-hoc partial application feature"* (2025-01-13). Sam Mohr, the next day:
*"Now that partial application is off the table..."*

## 6. The performance story is orthogonal — and does not transfer to JS

Roc's closure performance comes from **lambda sets**, a compile-time defunctionalization scheme from
the Morphic research compiler. Richard Feldman, #compiler development › "current type inference
incomplete...", 2024-07-09
(https://roc.zulipchat.com/#narrow/channel/395097-compiler-development/topic/current.20type.20inference.20incomplete.../near/450288122):

> we already know that lambda sets enable llvm optimizations of closures that are otherwise blocked
> by llvm's inability to optimize function pointers [...] there are at least 3 performance benefits
> that defunctionalization (via lambda sets) unlocks: stack-allocated closures; llvm optimizations
> of closures; morphic optimizations.

Folkert de Vries, same thread: *"this is exactly the problem that the morphic paper describes: boxed
closures obscure control flow from LLVM."* Feldman also notes the cost: implementing lambda sets
during type-checking rather than as a separate pass *"has caused a subset of the lambda set bugs
we've seen."*

**Critically, no message ties lambda sets causally to the no-currying decision.** Both descend from
Roc's "compile away the abstraction" philosophy, but curried source could be defunctionalized the
same way after call-site collapsing. And every benefit listed is LLVM/native-specific:

- JS closures are already heap-allocated, GC'd objects — there is no "stack-allocate this closure."
- V8 does not suffer LLVM's opaque-function-pointer problem; its inlining and escape analysis work
  differently.
- Emitting `fn(a, b)` costs nothing extra in JS whether or not the source language curries. You need
  an `A2`/`F2` adapter scheme **only if you choose to represent curried functions as genuinely
  curried at runtime** — the alternative is to specialize saturated call sites into direct multi-arg
  calls and fall back to a wrapper only for real partial application.

So for a JS target the performance argument reduces to "how good is your saturated-call
specializer," which is exactly the tradeoff Roc's own FAQ concedes is surmountable.

## 7. What could not be found

1. **No measurement, from anyone, of either side** — neither the claimed error-message improvement
   nor the claimed performance cost of currying is quantified. Both halves of the FAQ's central
   argument are asserted.
2. **No regret and no reconsideration**, despite recurring pushback.
3. **Gleam's own rationale is unsourced.** The referenced tracker issue turned out to be about
   `const` semantics; reachable Gleam docs don't argue the decision. Gleam appears here only
   second-hand, through Roc's discussion of its `_` syntax.
4. **No Roc statement about JS-target implications** — Roc doesn't target JS. §6's transfer analysis
   is inference from the described mechanics, not a Roc claim.

## 8. Bearing on Beni

**The argument that transfers, and bites:** error quality. It is a property of the type checker, not
the backend, and Beni's whole §7 premise is Elm-grade diagnostics. In a curried language, "you
forgot an argument" and "you passed the wrong thing" genuinely are the same event to the unifier.

**The argument that transfers and cuts the other way:** dropping currying is not a local change to
Beni — it rewrites the idiom. Elm's `|>` *depends on* partial application: `x |> String.split sep`
only works because `String.split sep` is a legal value. Removing currying forces Roc's pipe-first
convention and an entire stdlib whose subject argument comes first — the opposite of Elm's
`List.map f list` / `String.split sep str`. "Elm-like without currying" means every signature in the
standard library flips. That is a much larger change than the calling convention.

**The argument that half-transfers:** performance. Roc's *stated* wins are LLVM-specific (lambda
sets, stack-allocated closures, function-pointer visibility) and are irrelevant to JS. But
[`03-js-codegen.md`](03-js-codegen.md) §5.2–5.3 records a JS-specific cost that is real and measured,
and it must not be waved away with Roc's:

| Tier | Cost |
|---|---|
| Naive curried closures (PureScript stock backend) | 25–35% runtime, 20–25% bundle size |
| Elm's `A2`/`F2` adapter at saturated call sites | **+49% Chrome**, +109% Firefox, +37% Safari vs. direct call (`map` benchmark) |
| Direct n-ary call where arity is statically known | baseline |

The measured penalty is the **adapter**, not currying as a language feature: `A2(f,a,b)` performs a
property load, an `=== 2` test and an indirect call before reaching `f.f(a,b)`. Elm pays it at every
saturated call site because it always routes through the wrapper. A compiler that specializes
statically-known saturated calls to direct n-ary calls pays it only in genuinely higher-order
positions. (Caveat: community microbenchmarks on `map`/`foldl`, browser- and workload-specific —
directionally consistent with the PureScript figure, but not a precise budget.)

So currying is affordable on JS **conditional on the specializer existing**, which is why it is an
M3 requirement rather than a later optimisation.

**Resolution taken (§9.3):** keep currying, and attack the error-message problem directly rather
than by removing the feature. The unifier knows when it expected `a` and found `b -> a`; that is
precisely a missing-argument shape, and it can be reported as `TOO FEW ARGS` with the call site
underlined, matching Roc's diagnostic without Roc's language change. This is worth an explicit
fixture suite in M2 — the mitigation is the whole justification for keeping currying, so it has to
be proven, not assumed. Roc's evidence stands as the strongest case against; if the targeted
diagnostic does not land convincingly on real mistakes, revisit before M3, because after M3 it is a
breaking language change rather than a compiler change.
