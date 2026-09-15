# Review: typed effects as calls

Opinions, since that is what was asked for. The detailed findings are the appendix.

---

## The short version

There is a genuinely excellent language design buried in this document and it is not the one the
title names. The excellent idea is `() -> a ! e`: a `Task` is a suspended computation, a
suspended computation is a function, so stop having a `Task` type. That deletes a module, a monad,
a mental model, and a row from the `<-` desugaring table. It makes the language *smaller*.

The named effect sets are a separate feature riding along with it, they are the expensive half,
and I would cut them.

So: ship the thunk, ship the marker, ship effect polymorphism with **one** variable and **no**
names. Then spend the saved budget on structured concurrency, which is the thing users will
actually feel.

---

## 0. Why effects at all, and why not Go

The prior question, and the proposal never answers it, because §1 answers a different one.

The proposal to beat is not Elm. Elm is not blind — it moves the effect out of the type and into a
value you are not allowed to call, which is why `andThen` exists. The proposal to beat is **Go**:
`getUser id` is an ordinary call, it suspends, the runtime handles it, and no part of the language
mentions any of it. No marker, no effect in the type, no `Task`. That is a better programmer
experience than colouring, essentially everyone who has used both says so, and it should not be
waved away.

**Go can do this because Go owns the stack.** A goroutine's stack is a heap object the runtime
allocates, grows, parks and resumes. Any goroutine can be suspended at any call, so the compiler
never has to know which functions block. Same for Loom's virtual threads, for BEAM, for OCaml 5.
The blindness is bought by the runtime, not by the language.

**JavaScript gives you one stack and no way to capture it.** No continuation capture, no stack
copying, no parking. So there is no runtime that buys blindness for you. If a beni function can
suspend and the compiler does not know which functions those are, it must assume *every* function
can, and that means one of:

1. **CPS-transform everything.** Coherent, complete, and what Scheme-on-JS implementations do. You
   get Go's model: green threads, spawn, channels if you want them. The price is that no beni
   function is ever a plain JavaScript function again. V8 inlines nothing, every call allocates a
   continuation, and the trampoline is between you and every stack trace. js_of_ocaml measured
   ~60% slowdown for whole-program CPS against ~10% once they built an analysis to avoid it — and
   that is OCaml's baseline, not "plain JS functions V8 can inline", so for beni the relative hit
   is worse.
2. **Make everything an `async function`.** Blind at the beni level, colouring pushed entirely
   into the output. Dead on arrival: every call allocates a promise and defers to a microtask, and
   nothing can return synchronously.

**And the thing that actually kills it is not performance. It is that beni is a guest.** Go owns
the process; every frame on the stack is Go's. beni is called *by* JavaScript constantly — the
virtual DOM calls `view`, a port handler is invoked from an event, a comparator is called from
inside `sort`, a decoder runs inside a JSON walk. Those frames belong to JavaScript, and a beni
function suspending underneath one cannot resume into it, because the frame is gone. So there is a
real, load-bearing question at every boundary: *may this function suspend?* Go never has to ask
it. beni has to answer it in a dozen places, and if the answer is nowhere in the types, the
compiler cannot check it and the programmer cannot see it.

**Why "in the types" and not just "the compiler works it out".** Because in JavaScript, whether a
function can suspend is not a runtime property. It is a property of *how the function was emitted*
— a plain `function` cannot suspend and an `async function` can, and that choice is made once, at
code-generation time, per function. So the compiler must know the answer for every function it
emits, including functions defined in other files. The only thing that crosses a module boundary
is the interface. A bit that has to live in every function's published interface, and be checked
against uses of it, is a type. That is the whole derivation: **the target forces a per-function
compile-time decision, separate compilation forces it into the interface, and a bit in the
interface is a type.**

The alternative — work it out globally — means you cannot compile a file until you have analysed
everything it transitively reaches, which is the end of per-file parallelism, of incrementality,
and of the 800ms cold build.

That is the justification for effects, and note what it justifies: **one bit, in the types,
because the backend and the boundary checks both need a cheap static answer.** It is §1's item 4,
not items 1 through 3. The document leads with the `andThen` pyramid, and its own research says the
pyramid is rare — 1.6% of Elm declarations reach depth three, zero of 22 "nesting" threads concern
it. That is the weakest card in the hand.

### 0.1 The version of "make it blind" that does survive

There is a real design between Go and this proposal, and it deserves costing rather than
dismissing: **effects inferred, never written, never marked.** The checker computes the bit,
records it in the interface so callers in other files can see it, and prints nothing. The backend
lowers from it. Boundary checks use it: `view` must not suspend, and the compiler says so when it
does. In the source, calling an effectful function looks exactly like calling any other function.
This is js_of_ocaml's model with the analysis replaced by inference you already run, and at the
source level it *is* Go.

What you actually give up, honestly:

- **Substitution.** `let x = getUser id` performs once; inlining it at two use sites performs
  twice. Every strict language with side effects lives with this. Elm does not, and "you can
  always lift a subexpression into a `let`" is a property this language is built on.
- **A visible cost model.** `render user prefs` might be three network round trips. In Go you
  accept that because the culture is to read implementations. In a language whose pitch is that
  you can read a `view` function and know what it does, hiding I/O behind an ordinary-looking call
  is a real loss.
- **Locality.** With a marker you scan one function and see its I/O. Without, you have to know the
  transitive behaviour of everything it calls.

You do *not* give up: purity for the optimiser, the lowering decision, DCE, or boundary checking.
All of those work off the inferred bit and need no syntax at all.

### 0.2 Three separate questions, not one

"Do we have effects" is really three questions and they have different answers.

1. **Effects in the compiler's types.** Required, and for a technical reason: the target cannot
   suspend a stack, so something must decide what to transform, and the boundary question
   ("may `view` suspend?") must be answerable statically. Not a matter of taste.
2. **Effects written in signatures.** *Required only where there is no body to infer from* —
   `foreign` declarations, and any signature the platform imposes (`view` must not suspend). In
   ordinary code, optional. My modularity argument for making it conventional does not survive
   contact with how this ecosystem already works: Elm's answer to "did I silently change my API"
   is not annotations, it is `elm diff` computing the interface and forcing the semver bump. The
   effect bit lives in the computed interface either way, so a `beni diff` catches the change
   without anyone writing anything, and catches every other API change at the same time. That is
   strictly better than relying on an author to have annotated.

   What survives is narrower and conditional. *If* the convention is that top-level definitions
   carry annotations, then the bit belongs in them, because it is part of the type — you would not
   write a signature that omits an argument. And a written annotation puts the error at the
   function you just edited ("you declared this pure and it isn't") rather than at a boundary three
   modules away. Both are reasons to write it. Neither is a reason to require it.
3. **A marker at every call site.** See §0.5. I no longer think this one is carried by the
   arguments usually given for it.

## 0.3 Lower to native `async`/`await`. §7.2 never considered it.

Separate idea from the marker question, and a better one. The compiler infers which functions
suspend; in the emitted JavaScript those become `async function` and the calls become `await`.
Pure functions emit exactly as they do today.

§7.2 offers three lowerings and rejects the third, but the third is **generators**, and its four
reasons are reasons about generators. They do not carry to `async`/`await`:

| §7.2's reason to reject L3 | true of `async`/`await`? |
|---|---|
| opaque to the optimiser | yes, but only for functions that actually suspend |
| poor stack traces | **no.** V8 has had zero-cost async stack traces since 2018 |
| `finally` semantics wrong by default | **no.** `try`/`finally` around an `await` works correctly |
| `yield` cannot cross a function boundary | **no.** `await` composes; no `yield*` delegation |

What this buys, and it is a lot:

- **§7.2 and §7.5 mostly disappear.** No CPS pass, no join points, no continuation
  representation, no logical-stack reconstruction. The code shape is preserved, so source maps
  are trivial and the debugger steps natively. This is the largest single piece of compiler work
  in the proposal, deleted.
- **§7.4's `Step` protocol disappears.** A `foreign` primitive returns a promise; you `await` it.
  No inline-versus-suspend discrimination, no registration.
- **`finally` works, so cancellation works.** §12 Q7 has no answer today and I proposed
  `Task.bracket` as a primitive. Under native `async`, `bracket` is `try`/`finally` in the emitted
  code, and cancellation is an `AbortController` rejecting the pending `await`, which unwinds
  through the `finally` blocks correctly. That is how `fetch` already behaves. The single hardest
  open question in the document becomes ordinary.
- **Effectful loops stop overflowing the stack.** §A4.1 is the problem that L1 de-tail-calls
  recursion into a language that has no tail-call elimination. Under `await`, the continuation
  runs on a fresh stack from the microtask queue, so a long effectful fold does not crash. It
  costs O(n) promises on the heap instead, which is worse than a loop and much better than dying.
- **You may not need report 16's fiber runtime at all.** `par2` and `parAll` are `Promise.all`,
  `timeout` is `Promise.race`, spawn-with-a-result is just a promise, bounded concurrency is
  twenty lines. The event loop is the scheduler. Weigh that against writing and maintaining one.

Two real costs, neither fatal.

- **Every `await` defers at least one microtask tick, even on a value.** So a synchronous effect
  pays a scheduling round trip. The fix is the thing §2.2 was reaching for: mark a `foreign`
  primitive as synchronous, and a function whose effects are all synchronous never becomes async.
  That is a two-state distinction on the platform declaration, invisible to users, and it is the
  useful half of what named effects were being asked to do.
- **Microtasks do not yield to rendering.** So §A4.2's fairness problem is unchanged, not fixed.
  A tight loop of synchronous effects still freezes the page.

I would take this lowering whether or not the marker survives. It is the single change that most
reduces what has to be built.

### 0.4 The marker: I argued for it and the arguments do not hold

I gave four reasons for a mandatory `!` at call sites over the course of this review. Three of
them are wrong and the fourth is weaker than I made it sound. Setting them out, because the
proposal leans on the same ones in §3.4 and §12 Q4.

**"It preserves substitution." No. Nothing preserves substitution.** `let x = getUser id!`
inlined into two use sites becomes `getUser id!` twice, and performs twice. The marker does not
restore the property, it only makes the place where the property fails visible. And Evan's
objection in the research is to the whole construction, marked or not: once a call can perform,
"you can always substitute an expression in" is gone. I presented visibility as if it were
preservation. It is not.

**"It makes the boundary error local." No, that is an error-message problem.** The compiler knows
the chain and can print it:

```
`view` cannot suspend, but it does.
  view calls renderRow          View.elm:12
  renderRow calls iconFor       View.elm:40
  iconFor calls fetchIcon       Icon.elm:8    -- this one performs
```

That is a perfectly good diagnostic, and this project already holds itself to that standard. A
chain the compiler can print is not an argument for making the user write the chain.

**"Lippert's tooling argument." It does not apply here.** C# requires `await` because forgetting it
produces a *program that still compiles* and silently yields a `Task`. Under the design you are
describing, the compiler inserts the `await`. There is no forgotten-marker bug to protect against.
The strongest cited authority for the mandatory marker is an argument about a failure mode this
design does not have.

**"You can see which lines do I/O." This one is real, and it is modest.** Without a marker, reading
a function body tells you nothing about which calls perform; you need each callee's signature. In
an editor that is an inlay hint. In a code review on a web page it is a genuine loss. It is the
same argument that makes Elm write type annotations that are perfectly inferrable: reading happens
more often than writing. That is a cultural choice about what kind of language this is, and it
should be argued as one rather than dressed up as a safety property.

**And dropping the marker deletes a wart I found earlier.** §A1.1 is that `List.map ids (\id ->
getUser id!)` does not compile under the proposal's own rules, because the application is itself
effectful and needs a second `!`. Every effect-polymorphic call takes that shape. Unmarked, the
whole problem evaporates:

```elm
fetchAll ids =
    List.map ids (\id -> getUser id)
```

which is the line the proposal wanted to write in the first place.

**So: I would try it without the marker.** Effects inferred, written in top-level signatures for
modularity, auto-`await` in the output, nothing at call sites. That is §0.1, and the objections I
raised against it do not survive contact with auto-`await`. If it turns out that reading bodies
without an editor is too hard, adding the marker later is a codemod the compiler can perform,
because it already knows every answer.

The one thing I would not drop is point 2 of §0.2. Keep the bit in the signature. That is where
the modularity guarantee lives, and it costs one character.

---

## 1. Lead with the subtraction, not the addition

§1 lists four things the design buys. Read from the outside, that is four new things in a language
whose entire pitch is that there are not many things. It is the wrong frame and it makes the
proposal look more expensive than it is.

The true frame is that this design *removes* `Task`:

| today | after |
|---|---|
| `Task e a` | `() -> Result e a !` — an ordinary function type |
| `Task.andThen` | `let x = f()!` — an ordinary binding |
| `Task.map`, `Task.map2` | ordinary calls, ordinary constructors |
| `Task.succeed` | nothing. A value is a value. |
| `Task.traverse`, `Task.sequence` | `List.map` |
| `Task` in §9.3's `<-` table | gone, and `?`'s speculative shape resolution never grows a third candidate |

That is a real deletion of a concept, and it is the only argument in this space I find
*compelling* rather than merely favourable. Ergonomics arguments are always contestable, because
the other side can say "just write `andThen`". A concept-count argument is not contestable: either
`Task` is in the language or it is not.

Rewrite §1 around this. The current §1 is four ergonomic claims of which the research supports
one and a half.

---

## 2. Cut the effect names

This is the main opinion and I hold it strongly.

### 2.1 What "no handlers" actually costs

First, precisely what the phrase means here, because it is checkable against the document rather
than a matter of taste. **No construct in this proposal ever removes an effect from a set.** A
marked call adds its callee's effects to the enclosing function's; that is the only rule that
moves effects. They accumulate from leaf to root and stop at `Cmd.run`, which does not discharge
`e` but erases it, because the runtime takes over there. Growth plus one erasure at the boundary.

That matters for *names* specifically. In the algebraic-effects literature a name is a dispatch
address: `Net` is the label `try … with Net -> …` matches on, and the type row exists to tell the
checker which handler must be in scope. Koka, Effekt, Flix and OCaml 5 all work this way. Take
handlers away and the name has no operational role left. Nothing reads it. It is propagated by
the checker and printed by the renderer, and that is the whole of its life.

I should be more careful than I was about the second half of this, though, because two things
survive the absence of handlers and I collapsed them.

**Coarse restriction survives, and it is real.** `audit : Event -> () ! {Log}` genuinely forbids a
network call in `audit`'s body, enforced by the checker, and one bit cannot express it. §9.1's
disclaimer is narrower than I made it sound: it says the sets cannot express "only *this* domain"
or "only under *this* directory", and that user packages cannot mint effects to be restrictive
about. It does not say nothing is enforced. My "disclaiming both of its purposes" was wrong.

**A non-dischargeable named effect can still earn its keep.** Koka's `div` is the counterexample
to my own rule: no handler discharges divergence, and the name is still worth having, because
`total` is a property you want to read off a signature. So "names need handlers" is not a law.

### 2.2 The argument for names that nobody in this debate has made

And here is the best case for keeping them, which the proposal does not make and which is stronger
than §1 item 3. **If the platform marks an effect as synchronous, names drive lowering.** A
function whose set is exactly `{Log}`, where `Log` never returns a promise, needs no suspension
machinery at all — no continuation closure, no join point, no double translation. One bit cannot
see that; it lowers every effectful function the same way. Names give the backend a partition of
the effect universe into "may suspend" and "never suspends", and on a target where suspension is
the expensive thing, that is not documentation.

If you keep named sets, that is the argument to build §1 item 4 on. It is also the argument that
tells you what the vocabulary is *for*, which is the question §9.1 currently leaves open.

I still would not keep them, for the reason in §2.3. But the honest framing is that this is a
trade, not a mechanism carrying a corpse.

### 2.3 Why I still land on cutting them

Because both surviving benefits are better served by something else.

The synchronous-effect win is a two-point distinction — suspends or does not — and it belongs on
the `foreign` declaration where the platform author already knows the answer, not in a user-facing
vocabulary that every signature in the language then has to carry. Two bits, inferred, invisible.

The restriction win is real but its value is entirely a function of granularity, and
platform-fixed granularity is exactly what Roc found does not work: you get `{Net}` when what you
wanted to say was "only my own API". A capability argument gives you restriction at whatever
granularity you choose, needs no language support, and is where Roc's community landed. Being able
to prove a function only logs is worth something; it is not worth set unification plus an alias
system plus a new quantifier class on schemes.

And what is left over, as documentation, is weak in three ways that compound:

- §9.2 makes a declared set an *upper bound*, so a signature says "may reach the network", not
  "does". The question §1 item 3 poses is not the question the type answers.
- `Cmd msg` erases the effect variable, so in a TEA app every effectful path funnels through a
  type that names nothing. The sets are visible on internal helpers and invisible at the boundary
  anyone reads.
- The granularity is fixed by the platform forever. `{Net}` cannot say "my own API" versus
  "anywhere", which is the distinction anyone who cares about this actually wants.

**And the empirical record is one-sided.** Every language that shipped a one-bit effect marker to
a large audience is alive and the marker is uncontroversial: Haskell's `IO` for thirty-five years,
Kotlin's `suspend`, Swift's `async`, Rust's `unsafe`, JavaScript's `async`. Every language that
shipped *named effect sets* has under a hundred users and is a research vehicle: Koka, Effekt,
Flix, Frank, Eff. The two exceptions prove it — PureScript shipped effect rows to a real audience
and removed them in 2017; Roc shipped platform-declared effect tags on `Task` and removed them,
and its community converged on "granularity is the platform's job, expressed as capability values".

That is not a coincidence and it is not about implementation difficulty. It is that the value of
distinguishing `Net` from `Log` in a type is smaller than the cost of every user writing, reading,
aliasing, and maintaining the distinction in every signature forever.

**What I would write instead.** Three spellings, no braces:

```elm
add     : Int, Int -> Int              -- pure
getUser : UserId -> User !             -- performs something
List.map : List a, (a -> b ! e) -> List b ! e   -- polymorphic in whether it does
```

`!` alone, `! e` for the variable, nothing for pure. That keeps every one of §1's items except
item 3, and it deletes: effect declarations, effect aliases, set unions, the `{Net | e}` row form,
sub-effecting, set unification, the alias-folding rule in §8, the new `Kind` on schemes that
`checker.md` §6.3 forbids, and the entire §11 prototype risk that the proposal itself calls the
one thing to settle before committing.

**And the door stays open.** One bit is the empty-or-not projection of a set. Names are a
source-compatible superset added later, once there are users who can say which distinctions they
want. Right now the granularity is being chosen with zero users, and choosing granularity with
zero users is precisely what Roc got wrong.

If item 3 is a genuine hard requirement rather than a nice-to-have, then say so in §1 and accept
that it, alone, is paying for §4.3, §8's rendering rules, and §11's risk table. Do not present it
as one of four co-equal wins. It is three cheap wins and one expensive one bundled together, and
the bundling is what makes the price look reasonable.

---

## 3. The feature is structured concurrency. Sell that.

Elizarov's line, quoted in your own synthesis: "colouring is documentation, and structured
concurrency is the actual payoff." He is right, and it is the single most useful sentence in the
seventeen reports.

Kotlin is the closest living relative of what you are building: one bit, mandatory colouring,
compiles to a state machine on a host that cannot suspend a stack, millions of users. Nobody
chooses Kotlin coroutines for `suspend` in signatures. They choose it for `coroutineScope`,
cancellation that actually cancels, and the guarantee that a scope does not return until its
children finish.

§6 has the beginnings of this and then stops one step short. It has `par2`, `parAll`, `retry`,
`timeout`, `scope`. It has no `bracket`, no bounded concurrency, no spawn-with-a-result, and no
answer to what runs when a fiber is cancelled mid-suspension. §12 Q7 asks "is `Task.scope`
enough?" and the answer is plainly no: without a release hook there is no way to hold a resource
across a `!`, which is the second thing anyone writes.

```elm
Task.bracket : (() -> r ! e), (r -> () ! e), (r -> a ! e) -> a ! e
```

The runtime owns the fiber, so it *can* run `release` on cancellation. That is the thing Rust
cannot do and has not resolved in five years. It is a genuine advantage of owning the runtime and
the proposal does not claim it. Claim it.

---

## 4. Parallelism is the actual pain, and this design has a unique answer it does not use

Your own Elm report: "When Elm users say 'callback hell' they mean parallelism wiring with
`Task.map2`, not sequential binding." The synthesis repeats it: "parallel composition matters at
least as much as sequential."

The proposal optimises sequential binding, which the evidence says is rare, and answers
parallelism with `Task.par2 (\() -> a!) (\() -> b!)`, which is `Task.map2` wearing a hat.

Here is the argument the proposal is sitting on and never makes. **Putting effects in the type
system rather than in values is the only way the compiler can see the dependency graph of a
block.** In

```elm
let
    user  = getUser id!
    prefs = getPrefs id!
in
    render user prefs
```

nothing links `prefs` to `user`. A compiler that knows both lines perform, and knows `prefs` does
not mention `user`, can start them together. This is Haskell's ApplicativeDo and OCaml's `and+`,
and OCaml's community settled that argument on a *correctness* ground, not a convenience one.

I would not do it implicitly — §5 promises source order, TC39 refused silent parallel `await`
eight times, and silently reordering effects is exactly the kind of thing that makes people
distrust a compiler. But an explicit shape costs almost nothing:

```elm
let
    user  = getUser id!
    and prefs = getPrefs id!
in
```

Decide this before the syntax freezes. It is the one place where "effects in types" beats "effects
as values" on capability rather than on taste, and it addresses the complaint the research
actually found.

---

## 5. Three calls I agree with, and one I would reverse

**`!` in lambdas: right, and it is the most important decision in the document.** It is what makes
`List.map ids (\id -> getUser id!)` work, and therefore what kills the duplicated standard library
that Haskell has carried for thirty years and Roc accepted after a 101-message debate. The
synthesis assumed beni would ban `!` in lambdas by analogy with `?`; diverging was correct.

**Mandatory marker: I withdraw this.** See §0.4. I originally endorsed it on Lippert's tooling
argument, which turns out not to apply once the compiler inserts the `await` itself. If the marker
is kept anyway, note that it means "may suspend" rather than "suspends", since in polymorphic code
you must write `!` on a call whose effect variable may be empty.

**Colour over block: right.** A `Task.do` block would make the effect boundary a syntactic
construct *and* a type-system one, which is two mechanisms for one idea. The signature is the
boundary. The proposal makes this choice silently; it deserves a paragraph.

**`?` banned in lambdas: I would reverse it.** Every real effect is fallible, so the callback
people want to write is `\id -> getUser id!?`, and it is banned. The ban exists because non-local
return from a lambda is confusing, but here the lambda's own return type *is* `Result`, so `?`
returning early from the lambda is exactly right and exactly what Rust does. Allow `?` in a lambda
whose own result is `Result`- or `Maybe`-shaped. Otherwise the flagship win of §1 item 2 works
only for effects that cannot fail, and none can.

---

## 6. Two things that will bite in month one

Not style points. These are "the second program anyone writes does not work."

**Effectful loops blow the stack.** §5 says iteration is recursion. L1 puts the recursive tail
call inside a continuation closure, so it stops being a tail call — Leijen's own note on this
approach. beni has no tail-call elimination yet; `core/List.beni` says `foldl` is `foreign`
precisely because a self tail call is not turned into a loop. So an effectful fold over a long
list overflows. Koka answers with an explicit trampoline in its backend. Budget one in §7, not in
§11's risk table.

**A synchronous effect loop freezes the page.** §7.4 resumes inline when a primitive returns a
value rather than a promise. So a loop of synchronous effects never returns to the scheduler.
Report 16 measured this exact defect in Elm and called it a frozen page. An operation counter that
forces a yield every N resumptions is on report 16's own list of what a process record needs.

---

## 7. What I would actually ship, in order

1. **The formatter rule.** Free, independent of everything here, and the only intervention your own
   Elm evidence says is certainly worth doing. Do it whether or not any of the rest happens.
2. **`Task` becomes `() -> a !`.** One bit, inferred, recorded in the interface, written only on
   `foreign` declarations and platform-imposed signatures. No names, no braces, no aliases, no
   call-site marker. `Task.andThen` and friends disappear. Everything above the bit is a codemod
   away if it turns out to be wanted.
3. **Lower with native `async`/`await`** (§0.3), not with the CPS pass in §7.2.
4. **Effect polymorphism, one variable.** `List.map` serves both callbacks. This is what makes the
   deletion in step 2 stick.
5. **Structured concurrency as the headline:** `scope`, `bracket`, `par`, `race`, bounded
   `parAll`, cancellation that runs release hooks. This is the feature. The type system is the
   enabling mechanism, not the product.
6. **Decide parallel binds before the syntax freezes.**
7. **Named sets: not now.** Revisit when there are users and a platform surface to be granular
   about. The one-bit design is a strict subset, so nothing is foreclosed.

---

## 8. On how the document is written

The proposal is an advocate's brief. Every sub-decision is stated with its answer attached, the
risk table has a mitigation in every row, and the questions in §12 are mostly requests to confirm.
That is why my first pass came back as a list of defects: when a document leaves no room to
disagree about the shape, a reviewer can only attack details.

A designer's version would put three designs at three prices on the table — S0 plus the formatter,
one-bit effects, named sets — and argue for one. The evidence to do that is already assembled in
`research/14`; the synthesis deliberately did not recommend, and this document jumped straight to
a single candidate without walking back through the alternatives at the level of "what does the
language cost the reader."

---

# Appendix: the detailed findings

These stand regardless of which design you pick. The first three are substantive; the rest are
accuracy.

## A1. Defects that block judging the design as written

### 2.1 §2's flagship example violates §3.3

```elm
fetchAll : List UserId -> List User ! {Net}
fetchAll ids =
    List.map ids (\id -> getUser id!)
```

`List.map : List a, (a -> b ! e) -> List b ! e`. The callback has effect `{Net}`, so `e := {Net}`,
so the application `List.map ids (…)` has type `List User ! {Net}`. §3.3 rule 3 says an unmarked
effectful call in value position is `unmarked_effect_call`. The example does not compile under its
own rules. It must be:

```elm
fetchAll ids =
    List.map ids (\id -> getUser id!)!
```

I think the double marker is *correct* and should be kept: the outer `!` tells the reader this
`List.map` suspends, which is information they cannot otherwise recover. But it is the shape every
effect-polymorphic call takes, it is not what the proposal shows anywhere, and it is the shape a
reviewer is being asked to judge. Fix the example rather than the rule.

### 2.2 The marker does not mean what §3.4 says

Consider any effect-polymorphic function that calls its own parameter:

```elm
twice : (() -> a ! e) -> (a, a) ! e
twice f =
    ( f()!, f()! )
```

`e` may be instantiated to `{}`. So `bang_on_pure` cannot fire on a set that is merely *unknown*;
it can only fire on a set statically known to be empty. Inside polymorphic code the marker is
mandatory on calls that may be pure at every instantiation.

That is fine operationally, but §3.4 says a `!` means "this call suspends this function". It
means "this call may suspend". State the weaker reading, or Koka's and Flix's argument against
markers gets a foothold it does not currently have.

### 2.3 The grammar in §3.1 cannot derive the types the rest of the proposal uses

```
Type        := ParamList? TypeApp Effects?
ParamList   := TypeApp (',' TypeApp)* '->'
EffectSet   := '{' '}' | '{' Name (',' Name)* '}' | lower_ident | '{' Name (',' Name)* '|' lower_ident '}'
```

Three problems.

- **No chained arrows.** The result position is `TypeApp`, not `Type`, so `ParamList` cannot
  repeat. `a, b -> c -> d ! e` — §3.1's own worked example — is underivable. The result must be
  `Type`, and once it is, where `Effects` attaches becomes genuinely ambiguous: `a -> b ! e` could
  be `a -> (b ! e)` or `(a -> b) ! e`. §3.1 asserts the first without a rule that produces it.
- **No union of two effect variables.** §4.1 says the set language includes "unions of these", and
  §6's own API needs it. `Task.par2 : (() -> a ! e), (() -> b ! e) -> (a, b) ! e` as written
  forces both thunks to the same set; a `{Net}` thunk and a `{Log}` thunk do not unify. The
  signature you want is `… ! {e1 | e2}`, and `EffectSet` has no production for it.
- **Parenthesised function types as parameters** depend on `TypeApp` admitting `'(' Type ')'`,
  which is never stated, though `List.map`'s signature requires it.

### 2.4 Widening restricted to lambda arguments is too narrow

§4.3 takes Flix's rule: a lambda passed where a larger effect set is expected is widened, and
widening happens nowhere else. That breaks on the proposal's own platform API and on ordinary
data:

```elm
Task.par2 (\() -> fetchUser id!) (\() -> logIt!)   -- two literal lambdas: widens, fine
Task.par2 fetchThunk logThunk                      -- two named thunks: no widening, type error
{ onClick = alwaysPure }                           -- field typed (() -> () ! {Dom}): no widening
```

Effect sets want subsumption in every covariant position, not a coercion at one syntactic site.
That is a subtyping system rather than a unification system, which changes the answer to §12 Q1.
The cheap alternative is to accept eta-expansion (`\() -> fetchThunk()!`) and say so, with a
diagnostic that suggests it. Either way §4.3 as written does not typecheck §6.

### 2.5 Nothing says how effects appear in type aliases and data types

Can a type abstract over an effect?

```elm
type alias Handler e = () -> () ! e
type alias Task e a = () -> a ! e
```

This needs effect parameters on type constructors, which means a kind distinction between type
parameters and effect parameters. The proposal never mentions it. It matters immediately, because
`Task e a = () -> a ! e` is the alias that would let `boundary.md` §4's shape (b) stand unchanged
(see §A3), and because any user-written record of callbacks needs it.

### 2.6 There is no way to perform an effect for its own sake

Every `!` in the proposal is in value position. Logging, metrics, and `Debug`-shaped effects want
`log "x"!` as a statement. The only spelling available is `let _ = log "x"!`, which works but is
never shown, and §5's "the compiler may drop pure calls whose results are unused" needs an
explicit companion rule: an effectful call is never dropped, even when its result is unused.

---

## A2. The claim in §2/§4.2 that is backwards

> Local `let` bindings are never generalised over effects (Flix's rule, 14/flix §7.3), so there is
> no Koka-style "extract a local and it breaks" hazard (14/koka §4.3).

This is inverted. `koka-with-and-effects.md` §4.3 identifies non-generalisation as the *cause*:

> **This is the single most important diagnostic finding for a Hindley–Milner language.** It is
> let-generalisation **failing to generalise over the *effect* variable at a `val` binding**, so
> "pull this out into a local" — the most ordinary refactor there is — can break a program that
> type-checked.

The proposal adopts that exact rule and concludes the hazard cannot arise. Under §4.2.5,
`let f = someEffectPolymorphicFn` followed by two differently-effectful uses of `f` reproduces
koka#401 verbatim.

`flix-effects.md` does assert that non-generalisation "removes Koka's bug outright" — which is
where the proposal got it — but the same paragraph continues, and the proposal stops before the
continuation:

> …but **reintroduces the §2 asymmetry: pull an effect-polymorphic lambda out into a named
> top-level `def` and you must supply its effect annotation yourself**, since the automatic
> widening that applied inside the lambda position does not apply to a `def`.

§7.3 calls this "Flix's analogue to Koka's extraction hazard, but a required annotation rather
than a silent break."

So the true claim has two halves, and only one of them is good news.

*Extraction to a top-level definition is fine, and better than Flix's.* §4.2.5 generalises effect
variables at top level, so the extracted function annotated `… ! e` serves every instantiation,
and §9.2's superset rule means the annotation you are forced to write need not even be exact.
Flix requires exactness; you do not. Make that argument, it is a real advantage.

*Extraction to a local `let` is the surviving hazard, and it is Koka's, unchanged.* A local binding
is monomorphised in its effect, so the second use at a different instantiation fails. There is no
annotation you can write on a `let` to recover it, because §4.2.5 forbids generalising there.

As written, §2, §4.2.5 and §12 Q2 all rest on a claim the cited source contradicts. The honest
version is: the silent break is confined to local bindings, and the top-level escape hatch is
cheaper than Flix's.

One more divergence hiding in the same sentence. In Flix nothing local generalises at all — only
top-level `def`s are schemes, and the issue asking for local let-polymorphism was closed with
"let should not be generalized". beni generalises *types* at `let` (`Solve.let_`, Rémy levels).
"Flix's rule" is therefore being cited for an effects-only carve-out Flix does not have: you are
proposing a pool scan that generalises type variables and skips effect variables in the same
region. That is new, not precedented, and it is exactly what §12 Q2 should be asking.

---

## A3. Decisions the tree records as settled that this reverses

None of these is fatal. All of them mean a reviewer reading the design docs first hits a flat
contradiction the proposal never flags.

**`fast-compiler.md` §3.1, Decided 2026-09-13.** "Effects: a pure language, one function arrow,
effects as values interpreted by a platform… The alternative — Roc's `->`/`=>` with effects in
the types — … puts two function kinds and effect polymorphism into the unifier, exactly the
surface §3 keeps small… Consequences: §9.1's DCE is exact by construction; §7's unifier is
unchanged… **the effect-marking syntax question in §3.2 closes as 'none'. Decided 2026-09-13.**"

§3.2 reopens the narrow question and names this candidate, so the proposal is invited. But it
overturns "one function arrow", "effects as values" and "the unifier is unchanged", and §3.1 has
not been amended. The proposal's preamble should list §3.1 under what it *reverses*, not leave it
out of what it assumes.

**`research/15-flat-effect-syntax.md` §0** is blunter: "No row polymorphism (§3), so algebraic
effect rows are out. **The unifier stays simple (§7), so a syntax change that adds a constraint
kind is far more expensive than one that lives in the desugarer.**" §4.1 answers half of this by
distinguishing sets from rows. The "unifier stays simple" half is untouched, and §11's "inference
cost unmeasured" row does not mention that two documents already ruled the direction out on
exactly that ground.

**`boundary.md` §4 check 1** admits a `foreign` type in only two shapes: a total pure function, or
an effect value `Task e a` / `Cmd msg` / `Sub msg`. The proposal's `foreign httpSend : Request ->
Response ! {Net}` is a third shape, and §5's "this is what replaces `Task e a`" deletes shape (b),
which is a normative M3 check. §11's last row says "unchanged from `boundary.md`", true only of
the `foreign`-writing restriction.

There is a cheap repair that costs nothing and preserves the whole document:

```elm
type alias Task e a = () -> a ! e
```

A thunk *is* a `Task`. §10's "`Task` as an inspectable value" is lost is overstated — what is lost
is inspecting a task's *structure*, which Elm never offered either, since `Task` is opaque there
too. Keep the name, keep `boundary.md` §4 shape (b) textually intact, and §10's regret shrinks to
something true and small. This needs effect parameters on type aliases, which is §A1.5 above.

**`fast-compiler.md` §9.3.** The adopted `let x <- e` andThen table already lists `Task` first.
§12 Q9 asks whether having both `<-` and `!` is confusing; the honest framing is that this
proposal *removes* `Task` from an adopted table. That is a simplification and should be claimed as
one — see Q9 below.

**`checker.md` §6.3.** "a generalised scheme records, per quantified variable, its kind and
equatable flag… **Nothing else may be added to `Kind` without revisiting `fast-compiler.md`
§3.1**." Effect variables on schemes are precisely such an addition.

**The checker's function type is curried.** `TypeStore.Func` is `{ param: Var, result: Var }` and
`Constrain.funcChain` builds `a -> (b -> c)` for a 2-ary surface type; `checker.md` §6.1's
application rule is still written curried. So the n-ary decision of 2026-09-14 has not landed in
the checker, and until it does there is nowhere for an effect set to live: on a curried chain,
`a, b -> c ! {Net}` gives every intermediate arrow an effect slot, and the intermediate arrow is
not a type any user can hold. **§11's "prototype set unification before committing" cannot be
done until `Func` becomes n-ary.** That is the real sequencing constraint and it is not in §11.

---

## A4. What the lowering does not budget for

Two costs that the evidence names and §7 does not.

### 5.1 L1 de-tail-calls every effectful loop

Xie and Leijen, quoted in `koka-with-and-effects.md` §4.2: "**any direct tail-recursive calls are
no longer directly tail-recursive as they occur under a lambda now!**" Koka's backend answers with
an explicit `{ tailcall: while(1) … }` trampoline.

§5 says iteration is recursion and higher-order functions. So every effectful loop in beni is a
recursion whose tail call L1 moves inside a continuation closure. And beni has no tail-call
elimination yet — `core/List.beni` says `foldl` is `foreign` precisely because "written in beni it
is a self tail call, which the code generator is not yet required to turn into a loop". An
effectful fold over a long list will blow the JavaScript stack. A trampoline for continuation-tail
calls belongs in §7.2 as a deliverable, not in §11 as a risk.

Leijen's own open todo on the same approach — "in effectful code we generate many join-points…,
can we increase the sharing/reduce the extra code" — is acknowledged L1 code bloat, also absent.

### 5.2 Nothing yields, so a synchronous effect loop freezes the page

§7.4: "a value resumes inline, a promise registers the continuation." So a loop performing only
synchronous effects never returns to the scheduler. `research/16` §1.3 measured this exact defect
in Elm — `Process.elm` promises "we will pause it at an `andThen` and switch over to other stuff",
the measured interleaving is `AAAAABBBBB`, and the report's verdict is that a pure `andThen` loop
"on the browser's main thread is a frozen page".

The proposal reproduces the defect the report it cites was written to document. Report 16's own
closing list of what a process record needs includes "an operation counter" for exactly this.
Budget a forced yield every N inline resumptions.

### 5.3 Koka did not accept the uniform cost

§7.3 option A is described as "pure callers pay the test". What Koka actually did was add
`fun`/`val` tail-resumptive operations and `linear effect` to escape it, and
`koka-with-and-effects.md` §4.2 draws the conclusion for beni: "**That performance fact leaks into
the surface language as three keywords the user must choose between** — the ergonomic cost beni
would inherit." That strengthens §7.3's choice of double translation. Use it.

---

## A5. Gaps against research 14's own checklist

`01-solution-space.md` §5 lists ten sub-decisions "independent of S and L, each with a documented
failure mode". The proposal answers seven well. Three are missing, and one of the three is the
thing Elm users actually complain about.

**Sub-decision 6, parallel binds — missing.** §1 of the synthesis: "When Elm users say 'callback
hell' they mean parallelism wiring with `Task.map2`, not sequential binding", and "parallel
composition matters at least as much as sequential." The proposal answers with library functions:
`Task.par2 (\() -> a!) (\() -> b!)` plus tuple destructuring. That is `Task.map2` with more
punctuation. The design optimises the axis the evidence says is not the pain point and leaves the
pain point where it was. Whether the answer is a `let a <- t1 and b <- t2` shape (OCaml's `and+`,
F#'s `and!`) or TC39's "just type `Promise.all`" is a real choice; not making it is not.

**Sub-decision 8, evaluation order — missing.** `Summary user perms (Just (getAuditLog user!))`
puts a suspension in argument position. With two marked calls in two arguments, the order is
observable and unspecified. PureScript's MagicDo has had this open since 2020. State
left-to-right, and state that an effectful call is never dropped as dead even when its result is
unused.

**Sub-decision 9, the formatter — missing.** The synthesis: "Whatever beni adds, the formatter
rule is part of the feature", Koka has no formatter after nine years partly because of this, and
"A is compatible with every other row and is the only one Elm's evidence says is certainly worth
doing" — A being the formatter fix. The proposal says nothing about how `beni fmt` breaks a long
effect row, or a pipeline containing `!`. §7.5 correctly treats source maps as a deliverable; the
formatter deserves the same line.

**And report 16's list, which §6 draws from, has four more holes.** Report 16 is 141 lines and
unfinished: it has §1 only, and forward-references a §5 that was to be the primitive list and was
never written. So §6's "this is the vocabulary research 16 says a `Task` runtime must have, kept"
and §14's "report 16 … is the runtime this proposal's §6 assumes" cite a section that does not
exist. Against what report 16 *does* say the process record needs — "an outcome slot, an observer
list, a parent link, a finaliser list and an operation counter" — §6's five combinators drop:

- **finalizers / `acquireRelease`.** Report 16 §1.4: "No scope, no finaliser, no `acquireRelease`.
  … `_Scheduler_kill` … **nothing runs on the way out. A killed process leaks whatever it held.**"
  `effect-ts.md` §6 independently says "the answer **must** be a scoped `acquireRelease` in the
  runtime". §12 Q7 asks whether `Task.scope` is enough; both reports already answered no.
- **bounded concurrency.** `Task.parAll` takes no limit.
- **spawn with an outcome.** Report 16: "You can start work; you cannot collect it." §6 has no
  spawn or join.
- **fairness.** §A4.2 above.

---

## A6. Citation problems

Minor individually; they matter because the document's whole authority rests on every claim being
traceable.

- `14/flix §0` and `14/flix §8` **do not exist** — `flix-effects.md` has §1 through §7 and no
  "findings up front" header. Both pointers are in §4.3 and §11, on the two claims about
  SetUnification's provenance and about cost being unmeasured. The *substance* of "no cost
  evidence in the report" is correct; the pointer is not.
- "**after moving from Boolean formulas**" is not in the report. Flix has both: §1 shows
  `BoolFormula.scala` with the algebra `True | False | Var | Not | And | Or`, and unification
  translates to `SetFormula` and calls `SetUnification.solve`. They coexist; no migration is
  narrated.
- **Flix's algebra is harder than beni's, not the same.** It is cofinite with complement and
  subtraction, "because Flix's effect universe is open — users declare new `eff`s", and the
  algorithm is successive variable elimination over Zhegalkin polynomials, the classic
  worst-case-exponential Boolean unification procedure. §12 Q1 proposes "no complement, no
  intersection" and cites Flix as precedent for solving a strictly harder problem. That is good
  news for beni — see Q1 below — but the precedent does not transfer as stated.
- `14/koka §4.1` is cited in §1 item 4 for "Koka gets it from the types". §4.1 is the section
  costing Koka's effects at "roughly 1,550 lines of Core passes, a 317-line JavaScript runtime and
  a 938-line library". It is cost evidence, not type-direction evidence.
- **Effekt's critique of Koka (§4.1) is about something else.** `effekt.md` §2 quotes the leak as
  caused by "**Koka translates mutable variables … to a synthesized state effect**", whose encoding
  leaks into user types. beni has no mutable variables, so it does not support "the reason
  `List.map`'s `e` does not leak". The quote you want is in the same report and is unused:
  "Modeling effects as sets greatly simplifies typing as no special unification rules are needed."
- `foreign`'s confinement is `boundary.md` §2, not `language.md` §5.4 — §5.4 confines `foreign` to
  *core*, and boundary.md is what widened it to platform packages and renamed the diagnostic.
- The throughput target is `fast-compiler.md` §2, not `checker.md` §2 (checker.md §2 is the CLI
  surface). The number is > 250k LOC/s cold per core.
- `args_after_question` and `?`'s precedence are `language.md` §3, not §6.6.
- `research/15 §0.3` has no such heading; it is the third bolded finding under §0, and it asserts
  lowering order *within one `let` node* to argue a rewrite is local. §5 upgrades it to a general
  source-order evaluation semantics. Fair extrapolation, not a quotation.

---

## A7. Counter-evidence in the reports that the proposal does not engage

1. **Roc's community converged against the whole approach.**
   `roc-zulip-effect-granularity.md` closes: "the community … converged — without calling it this
   — on '**granularity is the platform's job, expressed as capability values, not the compiler's
   job, expressed as effect names**.'" §9.1 reports the closed vocabulary as a limit accepted for
   v1. It never reports that the primary source treats effect names as superseded by capability
   values. That is the direct rebuttal to §1 item 3 and it should be answered, not omitted.
   Feldman also gave *two* reasons for dropping the 3-arg `Task`, "threading cost, and that it
   still wasn't granular enough"; the proposal reports only the second, though threading cost is
   §11's own top risk row.

2. **PureScript's complaint is anti-modularity, and beni's design is more centralised, not less.**
   Kritzcreek: "**They are anti-modular in that you need a canonical location for an effect like
   DOM**". §11's mitigation reads this as signature noise and answers with aliases and inference.
   PureScript's rows were user-declarable and were *still* judged anti-modular; §9.1 makes the
   platform the single canonical location by construction. De Goes's other half — effects "are
   **not semantic** … no more actual guarantee" — is conceded in §9.1 ("the sets are for reading
   and for the backend, not for sandboxing") and never carried into the risk table where it
   belongs. There is a rebuttal available that the proposal never makes: PureScript's rows drove
   no codegen, whereas §1 item 4 is a benefit `Eff` never had.

3. **Roc's argument against effect polymorphism is never stated.** The 101-message thread's
   counter-argument was not cost: "invisible polymorphism breaks a caller's ability to *see*
   whether a value passed through is safe to treat as pure (a caching wrapper handed an
   'effectively effectful' callback silently returns stale results)". beni's `e` is written in
   top-level signatures, which is a real answer. Give it.

4. **Effekt's second-classness is the price of the "effect as requirement" reading §4.4 borrows.**
   Effekt's safety rests on blocks being second-class — "blocks … can neither be returned nor
   stored in data structures" — because a block escaping its `try` "is not safe and leads to a
   runtime error"; the 2022 paper re-admitted first-class values only via `box`/`unbox` with an
   explicit capture set. The proposal's deferral story is first-class effectful thunks stored in
   `Cmd` and passed to `Task.par2`. **This is safe in v1 only because no effect is ever
   discharged.** Write that sentence down. And note that §9.1's deferred user handlers is exactly
   the step that breaks it: once a handler can discharge `{X}`, a `() -> a ! {X}` escaping its
   handler is Effekt's counterexample. §9.1 says "the type side already accommodates … and the
   backend does not yet"; Effekt's evidence says the type side is the hard part.

5. **js_of_ocaml's double translation has no measured code-size number anywhere in the report.**
   §7.3's "bounded to core's higher-order functions" is unrebutted and also unevidenced. Two
   other things in that report bear on §7.5: `assume_no_perform` is an *unchecked* escape hatch,
   "a silent-until-you-hit-it correctness bug", and the report found "no source stating a specific
   source-map or stack-trace fidelity guarantee for CPS-converted code".

---

## A8. The twelve questions, answered

**Q1 — Inference.** The restriction you propose makes the problem much easier than Flix's, and the
proposal does not exploit that. With only constants, variables and unions — no complement, no
intersection, no cofinite universe — effect sets form a finite join-semilattice ordered by `⊆`.
Every constraint the checker generates is `s ⊆ e` (a marked call contributing to its function's
set) or a subsumption at a callback argument. That is a bounded constraint system solvable by
fixpoint, not a unification problem. It is linear in the number of marked calls, and it gives §8
what it needs for free: when an annotation is violated you know which constraint introduced the
offending effect, so you can point at *the call*, which is exactly what Flix cannot do and what
§8 promises.

Flix uses full unification because its universe is open and its algebra has complement, and the
algorithm it therefore needs — successive variable elimination over Zhegalkin polynomials — is
worst-case exponential. Importing it is importing a cost you designed the language to avoid.

What breaks first, in order: (a) **the representation**, because `TypeStore.Func` is curried and
there is nowhere to put the set — this blocks the §11 prototype entirely; (b) **bipolar variables**
— in `List.map : List a, (a -> b ! e) -> List b ! e`, `e` occurs contravariantly in the parameter
and covariantly in the result, so it needs both a lower and an upper bound, which is bounded
polymorphism, not unification; (c) **mutual recursion** between effect-polymorphic functions, which
needs an SCC fixpoint — `Solve` already SCC-decomposes binding groups, so this is cheap.

**Q2 — Generalisation.** Rémy levels extend to effect variables without difficulty, and the
deferred occurs check does not apply since effect sets cannot be recursive. Two frictions the
proposal understates. First, `checker.md` §6.3's "nothing else may be added to `Kind`" — effect
variables are a new quantifier class on schemes, and `adjustRank` must traverse sets. Second,
§4.2.5 asks `Solve.let_` to generalise type variables and skip effect variables **in the same pool
scan at the same rank**; the pool does not distinguish the two today. That is the novel part, and
§A2 above shows it is not Flix's rule, since Flix generalises nothing at `let`.

**Q3 — `!` inside lambdas.** The direction you are worried about is safe: an effectful lambda
cannot reach a pure higher-order function, because `e := {}` would have to unify with a non-empty
set. The seam is the *other* direction, and it is §A1.4 above — widening restricted to lambda
arguments does not typecheck `Task.par2` with named thunks, or a record field of function type.
Fix widening, not the lambda rule.

**Q4 — The marker.** Keep it, and Lippert's is the right reason: "require the marker for the
tooling's sake, not the compiler's." Two amendments. It means "may suspend", not "suspends"
(§A1.2). And `bang_on_pure` makes "this function became pure" a breaking change at every call site,
which is the one place §9.2's superset rule earns its keep — a library that may ever perform
should keep declaring the effect. Say that as library guidance.

**Q5 — Closed vocabulary.** Acceptable for v1, on the proposal's own terms, because §9.1 concedes
the sets are not a sandbox. `{Payments}` without user handlers looks like this, and it needs no
language support:

```elm
type alias Payments = { charge : Cents -> Receipt ! {Net}, refund : ReceiptId -> () ! {Net} }
```

A capability record of platform-effectful functions, taken as an argument, unforgeable because
only the platform can build the leaves. That is where Roc's community landed. Put the example in
§9.1 — it turns the closed vocabulary from a limitation into a stated division of labour.

**Q6 — TEA.** `update`'s purity survives intact, and so does time-travel, since a `Cmd` is still
an inert value the runtime interprets. What does *not* survive is §1 item 3 at the top: `Cmd msg`
erases `e`, so the effect sets are visible on internal helpers and invisible at the boundary a
reader inspects. Testing is exactly as good as Elm's and no better — `Cmd` is opaque in both — so
§6's "this is what Roc's users lost and what this design keeps" overstates it; what is kept is
`update`'s purity, not effect inspectability. Subscriptions need nothing new: a `Sub msg` is
platform-owned and its handlers are pure functions, so no effect row appears.

**Q7 — Cancellation.** `Task.scope` is not enough, and both of your own reports say so —
report 16 §1.4 ("nothing runs on the way out; a killed process leaks whatever it held") and
`effect-ts.md` §6 ("the answer **must** be a scoped `acquireRelease` in the runtime"). Add the
primitive:

```elm
Task.bracket : (() -> r ! e), (r -> () ! e), (r -> a ! e) -> a ! e
```

The runtime owns the fiber, so it can run `release` on cancellation — which is the thing Rust
cannot do and why async `Drop` is still open there. withoutboats' line in the synthesis is the
instruction: "treat cancellation cleanup as a separate design from the happy path", meaning design
it now, not after shipping.

**Q8 — L1 versus L2.** L1, and for a reason §7.2 does not give: `fast-compiler.md` §9.5's code
splitting works on functions, and L1's continuations *are* functions, so they split, rename and
DCE with no new machinery; L2's `switch` is one indivisible body. L1 also composes with `?`, which
already desugars to a `case` on a fresh local, whereas L2 would have to state-machine the `case`
too. In Zig, L1 is a BIR pass reusing the `let`-sequence structure `Lower.zig` already has; L2
needs a new IR with hoisted locals and the debugger discipline `regenerator` documents. The
proposal's answer is right; add §A4.1's trampoline to its bill.

**Q9 — `<-` and `!`.** They do not overlap, and the proposal should claim this as a win rather
than ask about it. Under this design `Task` leaves §9.3's andThen table, so `<-` serves `Result`,
`Maybe` and `Decoder` only — and `?`'s shape resolution in `checker.md` §6.5, which is *ordered
speculative unification* over `Result` then `Maybe`, never gains a third candidate. That is the
hazard `research/15` finding 3 named, removed. Three markers with three jobs is teachable:
`!` performs, `?` returns early, `<-` binds the rest of the block.

Do not make `Decoder` an effect. A decoder is a value you build, combine and run more than once;
an effect is a call you make once. Folding them would need multi-shot resumption, which §10 rules
out for good reasons.

**Q10 — What is missing.** Against `01-solution-space.md` §5's own ten: parallel binds (6),
argument evaluation order (8), the formatter (9). Against report 16: finalizers, bounded
concurrency, spawn-with-outcome, and fairness. Against the type language: effect parameters on
type aliases and data types, and a union of two effect variables. Against the checker: the n-ary
`Func` representation that everything else waits on.

**Q11/Q12 — the two sub-decisions I would change.** §9.2's superset rule, keep it but say what it
costs (signatures become upper bounds, which weakens item 3). §9.1's closed vocabulary, keep it
and add the capability-record example so the division of labour is stated rather than deferred.

---

## A9. Smaller notes

- `?` is forbidden in lambdas and `!` is not, so `List.map ids (\id -> getUser id!?)` is illegal.
  Since a network call returns a `Result` in any realistic API, the shape users will actually
  write is a map followed by one combinator:

  ```elm
  fetchAll : List UserId -> Result HttpError (List User) ! {Net}
  fetchAll ids =
      let results = List.map ids (\id -> getUser id!)!
      in Result.combine results
  ```

  That is fine — one combinator, not Haskell's zoo — but every example in the proposal uses
  infallible effects, which hides the shape users will actually write. Show one fallible example.
- `?` also serves `Maybe`, not only `Result`; the preamble says only `Result`.
- The §8 message for `effect_mismatch` — "`List.map` here is used in a pure context" — names the
  wrong function. The constraint comes from the enclosing function's declaration, not from
  `List.map`. Point at the declaration.
- Alias folding: with two aliases that overlap, "fold aliases" is a set-cover problem with no
  unique answer. Restrict the rule to "fold exactly the alias the user's own annotation used".
- `EffectSet`'s first alternative is written `'{' '}'`; presumably `{}` with no space.
- §3.1's argument for `!` as the spelling is good, and there is no lexical obstacle: `!` is
  currently unused as an operator token, `/=` is not-equal, and `--!` is a module doc comment in a
  different lexical class.
- Credit where it is due on sub-decision 1: because the body's type *is* the result type, there is
  no implicit-`succeed` question at all. Rust has had that unresolved for a decade. Say so.

---

## A10. Sequencing, if the named-set design is kept

1. Land the n-ary `Func` representation in `TypeStore`/`Constrain`. Nothing else can be prototyped
   first.
2. Prototype the constraint system of Q1 — `⊆` by fixpoint, not unification — against the corpus,
   with the §2 throughput target as the gate.
3. Decide item 3. If named sets survive that decision, the rest follows; if they do not, the
   one-bit version of this same design is a much smaller change and keeps `boundary.md` whole.
4. Write the missing three sub-decisions (parallel binds, evaluation order, formatter) before the
   surface syntax is frozen, because each of them can move it.
5. Then the lowering, with the trampoline and the fairness counter in §7's budget rather than
   §11's risk table.
