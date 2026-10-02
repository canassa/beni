# Proposal 2: transparent effects — two inferred bits, a fiber runtime, no surface syntax

**Status:** proposal, 2026-09-15. The surface is not decided; **the lowering is.** Supersedes most
of `typed-effects-proposal.md` (2026-09-14), which this document calls **P1**. Written after a
review of P1 recorded in `typed-effects-review.md`; the review's later sections argue for a
call-site marker this proposal abandons, and where the two disagree, this document is the later
position.

**Decided 2026-09-15, on the evidence of `research/16-fibers-and-concurrency.md`: the lowering is a
CPS pass onto a fiber runtime this language owns, not native `async`/`await`.** The deciding
measurement is `research/16` §2.4. A fiber parked on an uncooperative primitive, cancelled at 51 ms,
unwinds at **56 ms** under Effect and at **301 ms** under native `async` plus an `AbortController` —
"when the work settled, not when you cancelled." Effect-TS-grade concurrency is meant to be a
headline feature of this language, which makes that latency unacceptable rather than something to
design around. `research/16` §5.6 prices the alternative: prompt cancellation is free when the
runtime owns the resume callback and costs ~1 µs per suspension point, roughly 10×, when it does
not.

**This reverses §7 of this document's own earlier draft**, which chose `async`/`await`, argued it at
length, and called it "the cheapest reversible decision in the document". It is being reversed. §7
below is the replacement; the old §7.2's "the cost, stated plainly" is deleted rather than softened,
because the cost it accepted no longer exists.

**What does not change: the marker and the effect names stay rejected.** The surface of the language
is untouched by this decision. §3, §4, §5, §8, §9.3 and §12 stand as written, and §1's derivation —
the target cannot suspend a stack, separate compilation forces the bit into the interface, a bit in
the interface is a type — holds regardless of which lowering is chosen.

**The one-line difference from P1.** P1 puts effects in the source: named sets in every signature,
a mandatory `!` at every call site, and a CPS lowering. This proposal puts nothing in the source.
The compiler infers two booleans per function, uses them to decide which functions are emitted in a
suspendable form, and shows them to the reader through the editor rather than through syntax. Since
2026-09-15 the lowering is P1's; the surface is not.

**Both blockers cleared, 2026-09-18.** The no-currying change landed (§10 item 1) and the tail-call
loop landed with `List.foldl`/`foldr` leaving `foreign` (§7.3). What landed in between and this
document never considered is **static dispatch**
([`static-dispatch-spike.md`](static-dispatch-spike.md), normative since 2026-09-18): hidden leading
evidence parameters, method constraints on type variables, derived `eq`/`compare`, and
`boundary.md` §4's check 4. Every correction below is dated and marked as one; the implementation
plan, the new interactions and the decisions still owed are in
[`plans/effects-plan.md`](../../plans/effects-plan.md).

**The owner's decisions, 2026-09-30.** The eight questions of
[`plans/effects-plan.md`](../../plans/effects-plan.md) §5 are decided, each recorded there: `sync`
ships in the first cut (§3.2's postponement is withdrawn); the work interleaves with the backend now;
the runtime spike builds `spawn`/`join`/`scope`/`bracket` and the adoption all fifteen primitives;
both bits are inferred and only `suspends` is used in v1 (§11 Q6); `main : Program` stays with a
`sync` body; a well-known `eq`/`compare` must not suspend; the `sync` chain stops at one hop per
module; and library traversals get source order (§5), landing with the pending decision on
whether `List` becomes an array-backed sequence. The first slice, inference, is §14; the second,
the `sync` check, is §15.

**The owner's decisions, 2026-10-02.** The eighteen choices of
[`research/48`](research/48-effect-parity-ledger.md) §5 — the road to feature and quality parity
with Effect v4 — are taken as recommended, except the tenth: `Ref.update`'s atomicity is a `sync`
mark in core's own beni signature, not a JavaScript `foreign`. §17 is the contract for the APIs
they settle (slices P1–P5, and the logging and tracing of P7–P8, of
[`plans/effects-plan.md`](../../plans/effects-plan.md) §8); §6.5's list is superseded by it.

**What it assumes, already decided elsewhere.** No automatic currying, `_` placeholder, pipe-first
`|>`, n-ary types `Int, Int -> Int`, and a rest-of-block bind `let x <- e` (`fast-compiler.md`
§9.3). JavaScript is the target, and a modern one. Errors are `Result` values and `?` unwraps them
(`language.md` §6.6, §3). Platform packages are the only writers of `foreign` (`boundary.md` §2).

**What it reverses, and P1 did not say it was reversing.** `fast-compiler.md` §3.1 records
"a pure language, one function arrow, effects as values interpreted by a platform" as **Decided
2026-09-13**, with the consequence "§7's unifier is unchanged". Both halves go. `boundary.md` §4
admits a `foreign` at shape (b) `Task e a` / `Cmd msg` / `Sub msg`; `Task e a` is replaced by an
ordinary function type. `research/15` §0's "the unifier stays simple, so a syntax change that adds
a constraint kind is far more expensive than one that lives in the desugarer" is the standing
objection to this whole family, and §9.1 below is the answer to it.

---

## 1. Why effects exist in this language at all

Not for ergonomics. P1 §1 leads with the `andThen` pyramid, and the research commissioned to test
that claim came back negative: across six large Elm codebases, twelve declarations out of 765
containing an `andThen` reach depth three, none reaches five, zero of 22 Discourse "nesting"
threads concern it, and four companies with 300k lines between them name no effect-ergonomics cost
(`14/elm` §0.1, §5). That is the weakest available argument and it should not be the headline.

The real reason is a property of the target.

**JavaScript cannot suspend a stack.** There is no continuation capture, no stack copying, no
parking. Whether a function can suspend is therefore not a runtime property — it is a property of
how the function was *emitted*. A plain `function` has no way to stop in the middle and be resumed
later; a function emitted in §7's suspendable form does, because the rest of it is a closure the
scheduler holds. That choice is made once, per function, at code-generation time, and every
lowering in the survey pays it — `async function`, a generator, a state machine or CPS — which is
why the argument below does not depend on which one you pick.

So the compiler must know, for every function it emits, whether that function can suspend —
including functions defined in other modules. The only thing that crosses a module boundary is the
interface. **A bit that must live in every function's published interface and be checked against
uses of it is a type.** That is the entire derivation, and it is the only part of this proposal
that is forced rather than chosen.

The alternative is to work it out globally, which is js_of_ocaml's `partial_cps_analysis.ml`
(`14/ocaml5` §2.3). It is a whole-program dataflow fixpoint: you cannot compile a file until you
have analysed everything it transitively reaches. That ends per-file parallelism, incrementality,
and `fast-compiler.md` §2's budget of >250k LOC/s and an 800ms cold build for 100k lines.

Go, Loom, BEAM and OCaml 5 are all blind at the call site because their runtimes own the stack and
can park any frame. That option is not on the table here. Everything else in this document is a
choice; this is not.

---

## 2. The design on one page

- **Two booleans per function, both inferred, neither written in ordinary code.**
  - `suspends` — this function may yield to the scheduler. It decides whether the function is
    emitted as an ordinary `function` or in the suspendable form of §7. It is the colouring bit.
  - `impure` — this function transitively reaches any `foreign` primitive. It decides whether the
    optimiser may duplicate, drop, reorder or memoise a call. It does **not** colour anything.

  They are independent. `console.log` is `impure` and not `suspends`. A random number generator is
  `impure` and not `suspends`. `Http.get` is both. Arithmetic is neither. Collapsing them into one
  bit is what makes effect systems saturate — in a banking application everything logs, so a single
  purity bit is set everywhere and carries no information, while the `suspends` bit stays sparse.

- **There is no effect syntax.** No `!`, no `{Net}`, no `effect` declaration, no aliases, no
  `Task` type. `getUser id` is a call. It performs.

- **Effectful calls look like ordinary calls.** `let user = getUser id` performs a network request
  and binds its result.

- **Higher-order functions are bit-polymorphic by inference.** `List.map : List a, (a -> b) ->
  List b` serves a pure callback and an effectful one. One definition, no signature change, no
  `Task.traverse`, no `List.walk!` twin. This is the single largest thing the design buys and it
  is what Roc gave up (`14/roc` §3.2).

- **`foreign` declarations state their bits**, because there is no body to infer from. This is the
  only place the language spells them, and only platform packages may write `foreign`
  (`boundary.md` §2).

- **`sync` is an optional, deferrable check for boundaries that must not suspend**, and §3.2
  postpones it. It is the inverse of a colouring keyword: the author asserts the rare requirement
  at one root, and the compiler checks the entire call tree below it with nothing written anywhere
  in that tree. Nothing else in this proposal depends on it landing.

- **Deferral is a thunk.** `λ() -> fetchSummary id` is a value of type `() -> Summary` that runs
  nothing until called. Retry, timeout, racing, parallel composition and cancellation scopes are
  ordinary higher-order functions over thunks. This is what replaces `Task e a`.

- **Lowering is a CPS pass onto a fiber runtime this language owns.** A function with `suspends` is
  emitted in a suspendable form — L1, closures with join points — and a primitive that completes
  synchronously resumes inline on the same stack in the same tick. Everything else emits exactly
  what it emits today. Decided 2026-09-15 on `research/16` §2.4 and §5.6; §7.

- **The reader gets colouring from the editor, not from the text.** This is Kotlin's arrangement:
  `suspend` on the declaration, unmarked call sites, a gutter marker in the IDE — at a scale no
  effect system in the research reaches.

What P1's example becomes:

```elm
fetchSummary : UserId → Summary
fetchSummary id =
    user = getUser id
    perms = getPermissions user
    if perms.isAdmin then
        Summary user perms (Just (getAuditLog user))
    else
        Summary user perms Nothing

fetchAll : List UserId → List User
fetchAll ids =
    List.map ids λid → getUser id
```

Both are ordinary beni. Note that `fetchAll` is the line P1 could not actually write: under P1's
own rule the application is itself effectful and needs a second marker,
`List.map ids (λid -> getUser id!)!`.

---

## 3. Surface syntax

Almost none, which is the point.

### 3.1 `foreign` declarations

**Why anything is written here at all.** The compiler infers both bits for an ordinary function by
looking at what it calls. A `foreign` has nothing to look at, because its implementation is
JavaScript. It is the base case of the whole inference, and it is the only place in the language
where anyone writes a bit down — which only platform authors ever do. Elm needs no equivalent
because its effects live in types (`Http.get : … -> Task Error Response` declares itself), and a
kernel primitive is an ordinary annotated value whose body is `Elm.Kernel.String.length`. This
design took effects out of types, so the information has to go somewhere else.

```
ForeignDecl := 'foreign' Effect lower_ident ':' Type
Effect      := 'pure' | 'impure' | 'suspends'
```

```elm
foreign pure     cons     : a, List a → List a
foreign impure   now      : ⊤ → Time
foreign impure   random   : Seed → Int × Seed
foreign suspends httpSend : Request → Response
```

**One keyword with three values, not two independent flags, and never omitted.** The states are a
ladder — nothing suspends without being impure — so a pair like `suspends impure` would be
redundant and a pair like `pure suspends` contradictory; a single word can be neither. Omitting it
is not allowed: a default of `pure` would let `foreign now : () -> Time` silently claim that
duplicating a clock read is safe, which is the exact class of bug the second bit exists to catch.
`pure` is `boundary.md` §4's shape (a), unchanged. The checker still carries two bits internally,
because inference joins them independently up the call graph; that is representation, not syntax.

**Sub-decision, and it turns on a fact nobody has checked.** A keyword describes the *declaration*,
so it cannot say anything about a function type nested inside the signature: "suspends when its
callback does", or "the function I return suspends", are not expressible. Only a marker in the type
can say those, and the checker already carries and prints those bits internally, so declining to
let anyone write what diagnostics already render is a thin line to draw. The bet is that it never
comes up, because the foreign surface is the leaves — clock, random, HTTP send, console, timers,
DOM reads — and those are first-order, while everything higher-order in this design is written in
beni over thunks rather than declared `foreign`. **Enumerate the platform's primitives before
committing to this** (§10 item 0, and it is needed anyway to know how much of a program gets
coloured). If they are all first-order, the keyword is strictly simpler and the type grammar stays
untouched. If even one is higher-order, the bits belong in the type and the grammar has to grow —
and §3.2's `sync` turns on the same fact, which is why §10 item 0 answers both at once.

**Corrected 2026-09-18, on `research/17-platform-primitives.md` and on static dispatch.** The bet on
the leaves **wins**: report 17 §6.5 item 1 says freeze this keyword, because nothing in 71 projected
primitives needs `suspends` or `impure` inside a signature. Two things this paragraph did not
anticipate. First, a `foreign` may now carry a **`where` clause** — `core/List.beni:100` and `:114`
are `foreign eq`/`compare` over `where a.eq` / `where a.compare` — so a declaration keyword does
describe a signature with a function type in it after all, in the *evidence* position rather than in
a parameter's; the keyword says nothing about the evidence's bits. Second, the `random` example
above is wrong in a way report 17 §4.9 asks to be fixed: a *seeded* step `nextInt : Seed -> (Int,
Seed)` is a hash and is `pure`; what is `impure` is obtaining the first `Seed`. §2's argument is
unaffected, but as written a reader concludes a deterministic PRNG step cannot be memoised.

### 3.2 `sync` — optional, and postponed

*Superseded 2026-09-30 by §15, which specifies `sync` in the type position of a `foreign` and at
the language's own boundaries; the declaration modifier below is not built.*

**Status: not part of v1. Deferred, and nothing else in this document depends on it.** It is
written up here because the requirement it serves is real and the design should not be re-derived
later, not because it has to ship with the rest. Everything below stands whether or not it lands.

```
Decl := 'sync'? lower_ident ...
```

`sync f = …` asserts that `f` does not suspend, and is a compile error if it does. It propagates
*as a check, not as an obligation to write anything*: a `sync` function may only call functions
that do not suspend, and those callees are checked without carrying the keyword themselves. One
mark at a root covers the whole tree beneath it, and the diagnostic is §8's chain. Nothing else
changes about it — it is not a different type, and a `sync` function unifies with an ordinary one.

`sync` exists because some requirements come from outside a body rather than from inside it: a
`view` called by the virtual DOM, a comparator called inside `sort`, a decoder called inside a JSON
walk, a port handler whose caller needs a value now.

**Two positions, and only one of them works as a declaration modifier.**

- **At a root the author writes.** `sync view = …`, `sync compareRows = …`. This is the whole of
  what the keyword can do, it is cheap — one token per boundary, none in the tree below — and it
  is what makes postponing it safe: it adds a check, it does not change what compiles otherwise.
- **At an argument the platform demands.** A `view` handed to `Browser.element`, a comparator
  handed to `sort`, a decoder handed into a JSON walk. Here the requirement lives in the
  *callee's parameter type*, and a keyword on a declaration cannot reach it: `Browser.element`
  has no way to reject a suspending `view` unless its record field says so, and a field that says
  so has put the bit in the type language. §8's `sync_boundary` is by definition an
  argument-position error and is therefore not expressible under this rule either.

  So the earlier claim that "the platform writes the keyword and users do not" was backwards, and
  is withdrawn: under a declaration modifier only the *user* can write it, at their own roots,
  and the platform cannot impose it at all.

**This is the same open question as §3.1's**, from the other side: can a platform-facing signature
constrain a function type nested inside it? If every platform primitive is first-order, neither
§3.1's keyword nor `sync` ever needs the type position, and both stay cheap. If even one is
higher-order, both need the bits in the type, and they should be designed together rather than
separately. That is the reason to postpone: **enumerate the platform's primitives first** (§10),
then decide once.

**Corrected 2026-09-18 — the enumeration exists and it answers no.** `research/17` §5.1 lists seven
imposed signatures whose callback the host calls synchronously (`view`, `update`, `subscriptions`,
`init`, a DOM event handler, a `Html.map`/`Sub.map` tagger, an incoming port's tagger, a `Cmd`'s
tagger), and `boundary.md` §5.4 has already committed in writing to checking the first two. So the
sentence below — *"it is not a different type, and a `sync` function unifies with an ordinary one"* —
is **withdrawn**: `sync` needs an argument position, which means one bit on a function type. The
enumeration also narrows the price to far less than this section budgeted: one bool, one
`Interface.Term.Tag` value, one `Solve.Obligation.Kind` value, and a witness in the interface for
§8's chain. Costed against today's code in
[`plans/effects-plan.md`](../../plans/effects-plan.md) §2.5 and §3.

**What postponing costs.** The boundary question — "may this function suspend?" — is the one §1
calls load-bearing, and without `sync` v1 has no way to *assert* it. In practice a suspending
function reaching a synchronous JavaScript caller is a runtime failure rather than a compile
error until this lands. That is a real gap and it is recorded here rather than hidden; it is
acceptable for v1 only because the same information is already in the checker (§4) and the check
can be added later without changing anything that compiles today.

### 3.3 Bare items in a `let` block

Direct-style effects create calls with no result worth naming — a log line, an audit write, a
metric. beni is an expression language, so today those have to be bound, and the only spellings
are `let _ = Log.info "x"` or `let () = Log.info "x"`. The second already works: `()` is an
irrefutable `LetPattern` (`language.md` §3, §7), so the type-directed check this section wants is
*already in the language*. What follows is shorthand for it.

**Grammar delta.** One alternative:

```
LetBinding := Annotation? Definition | LetPattern '=' Expr | Expr
```

**Rule.** A bare item must have type `()`. That is the whole restriction, and it is what keeps
this from being the statements change:

- `Log.info "fetching"` is `()`. Accepted.
- `1 + 1` is `Int`. Rejected as `discarded_value`: "this expression has type `Int`, so its value
  is thrown away — bind it with `=`, or remove it."
- A bare item that is pure computes nothing observable, so it warns (`no_effect`) rather than
  erroring, since a pure `()` is a no-op by definition.

`for`, `break` and `return` get no foothold from this, because none of them is an expression of
type `()` — the guard is the type, not the grammar, which is the difference between this and
admitting a statement sequence.

**Parsing.** No new ambiguity. A `Definition` and a `LetPattern` binding both contain a top-level
`=`, a bare expression cannot (there is no assignment operator and `==` is a distinct token), so
the parser makes the same decision it already makes to tell `f x y = body` from `f x y`.

**Everything written today still parses**, since every existing binding has an `=` or a `<-`.

```elm
fetchActive : List UserId → Result HttpError (List User)
fetchActive ids =
    let
        Log.info "fetching"
        users = Result.combine (List.map ids getUser)?
        Log.info ("got " ++ String.fromInt (List.length users))
    in
    List.filter users λu → u.isActive
```

**Separable.** This is useful without any of the rest of this document — it is what `Debug.log`
wants today — and it should be reviewable on its own. It is included here because direct-style
effects are what make the ceremony frequent enough to notice.

**What it is not.** Clojure's implicit `do` sequences the *body*; beni's sequencing site is the
binding list, which is why the Clojure shape does not transplant and why the change has to land
here. Gleam gets the same result by having made its block a statement sequence outright, and pays
for it with `for`-shaped pressure this rule declines.

### 3.4 Parallel bindings: `and`

Two effectful bindings that do not depend on each other run one after the other, because §5
promises source order. Nothing in the source can ask for them together, and the library answer
needs an arity family — `par2`, `par3`, `par4` — because the results have different types and so
cannot be a list. That family is `Task.map2` through `map5` in Elm today, and it is what
`01-solution-space.md` §1 identifies as the complaint people actually voice: *"when Elm users say
'callback hell' they mean parallelism wiring with `Task.map2`, not sequential binding."*

**Grammar delta.** One alternative on the `let` item, and one keyword:

```
LetBinding := Annotation? Definition | LetPattern '=' Expr | LetPattern '<-' Expr | Expr
            | 'and' LetPattern '=' Expr
            | 'and' Expr
```

```elm
let
    user     = getUser id
    and prefs    = getPrefs id
    and settings = getSettings id
in
    Profile user prefs settings
```

**Rules.**

- `and` joins the item immediately above it into one **group**. A group is two or more items, and
  they start together and all complete before the next item below the group runs.
- **Items in a group may not reference one another.** `and prefs = getPrefs user` where `user` is
  bound in the same group is `parallel_binding_depends`, naming both. This is the whole content of
  the form: independence is asserted by the author and checked by the compiler, never inferred.
- **Only `=` bindings and bare items join a group.** A `<-` bind cannot, because it consumes the
  rest of the block as a callback and two of those cannot both have it.
- **The group is a scope.** If the enclosing fiber is cancelled, every fiber in the group is
  cancelled and its finalisers run (§6.3). Relative order of effects *within* a group is
  unspecified — that is what the form buys — while the group's position among its neighbours is
  not.
- **A group whose items are all pure is a warning** (`no_parallel_effect`): there is nothing to
  overlap. This is the same shape as §3.3's `no_effect`.

**Desugaring** is to a compiler-known n-ary parallel start over the group's thunks, which the
compiler writes. It is not user-definable and it is fixed to one meaning.

**Why `and` and not OCaml's `and+`.** OCaml 4.08 added `let*`/`and*`/`let+`/`and+` as grammar whose
meaning each module supplies, and `14/ocaml-let-operators` records that the applicative half was
the one contested part of the design, carried on a correctness argument rather than a convenience
one, and that at least eight of roughly fifty commenters over five months objected to the *spelling*
— bluddy's version being *"it's very easy for the small `+` and `*` operators to blend in,
particularly because our minds don't expect anything of importance in the area of the `let`"* — an
objection that produced a documentation revision and no syntax change. A keyword does not blend in,
and that report's own ninth finding is that beni cannot take OCaml's user-definable operator family
but *could* take the applicative parallel bind as one fixed, compiler-known construct. That is what
this is.

**Not adopted: inferring it.** The compiler can see that `prefs` never mentions `user` and could
start both without being asked. It must not: §5 promises source order, silently reordering effects
is the thing TC39 refused eight times when asked for a parallel `await`
(`14/javascript` §3.3, §5), and the author who wrote the two lines is the one who knows whether
they are genuinely independent.

### 3.5 What does *not* change

`?` keeps its rules exactly (`language.md` §3, §6.6): postfix on an application, binding tighter
than every binary operator, `args_after_question` after it, forbidden in a lambda, desugared to a
`case` on a fresh local. `getUser id?` performs and then unwraps. Because there is no `Task`,
`?`'s ordered speculative shape resolution in `checker.md` §6.5 never gains a third candidate,
which is the hazard `research/15` finding 3 named.

`let x <- e` (`fast-compiler.md` §9.3) keeps `Result`, `Maybe` and `Decoder` and loses `Task`,
which no longer exists. That removal is half the reason `<-` was generalised on 2026-09-15
(`fast-compiler.md` §9.3, item 7): with `Task` gone and `?` already serving `Result` and `Maybe`,
the `andThen` table was left dispatching for roughly one type, and it could not reach
`Task.scope : (Scope -> a) -> a` or `Task.bracket` — the two constructs §6 leans on hardest.
`let x <- f a b` is now `f a b (λx -> rest)` for any callee taking its callback last, so a scope
and a resource bracket sit flat at the top of a block instead of indenting everything below them:

```elm
let
    scope ← Task.scope
    conn  ← Task.bracket (λ⊤ → Db.open url) Db.close
    (user, prefs) = Task.par2 (λ⊤ → getUser id) λ⊤ → getPrefs id
    Log.info "loaded"
in
Dashboard user prefs
```

---

## 4. Typing

### 4.1 What is added to the type language

Nothing visible, and as little as possible internally. Each function type carries two flags drawn
from a **two-point lattice** (`false ⊑ true`), and a flag may be a variable.

This is deliberately not P1 §4.1's set algebra. The choice matters:

| | P1 | this proposal |
|---|---|---|
| domain | finite sets over an open vocabulary | two independent booleans |
| solver | set unification, Flix's `SetUnification` | constraint propagation to a fixpoint |
| precedent's cost | successive variable elimination over Zhegalkin polynomials, worst-case exponential | join over a two-element lattice |
| what a diagnostic prints | a set expression the user never wrote | a call and a chain of calls |

Flix needs a real unifier because its universe is open and its algebra has complement and
subtraction (`14/flix` §1, §7.1). With two booleans and no complement, every constraint is
`b₁ ⊑ b₂`, the constraint graph is a lattice, and the least solution is a fixpoint. This is the
answer to `research/15` §0's "the unifier stays simple": the unifier *is* unchanged. The flags ride
alongside it as obligations of the kind `Solve.zig` already carries per rank, not as a new
structure inside unification.

**Narrowed 2026-09-18, not withdrawn.** `research/17` §6.3 prices the `sync` demand as *"one case,
no new solver"* — `unifyFlat` (`src/check/Solve.zig:881`) compares two `Func`s at equal arity, and a
bit mismatch records an obligation rather than failing — so the honest form of the claim is now *the
unifier gains one case and no new structure*. Static dispatch is the standing precedent that this is
survivable and the standing warning about what it costs: a per-variable constraint set rides beside
`kind` and `equatable` on `TypeStore.Flags` (`src/check/TypeStore.zig:149-169`) without touching
`Kind`, and it cost **20.3 % of check time on code that never uses the feature** (report 19 §2.1).
A flag variable is the same shape of addition and should be budgeted the same way.

### 4.2 Inference

1. Every function body gets two fresh flag variables.
2. A call to `g` adds `g.suspends ⊑ f.suspends` and `g.impure ⊑ f.impure`.
3. A call to a `foreign` contributes its declared bits.
4. A lambda gets its own flags; they join the enclosing function's only where the lambda is
   actually called there, not where it is passed along.
5. The least solution is the fixpoint. A body with no effectful calls gets `false, false`.
6. Mutual recursion is solved per binding group; `checker.md` §6.1 already SCC-decomposes them.
7. **Generalisation.** Top-level definitions generalise their flag variables along with their type
   variables. Local `let` bindings do not.

### 4.3 The extraction hazard, stated honestly

P1 §2 claims that not generalising at `let` means "there is no Koka-style extract-a-local hazard".
That is backwards. `14/koka` §4.3 identifies non-generalisation as the *cause*: "let-generalisation
**failing to generalise over the effect variable at a `val` binding**, so 'pull this out into a
local' — the most ordinary refactor there is — can break a program that type-checked."

The true position, which this proposal adopts knowingly:

- **Extraction to a top-level definition is fine.** Flags generalise there, so the extracted
  function serves every instantiation.
- **Extraction to a local `let` monomorphises the flags.** Binding an effect-polymorphic function
  to a local and then using it at two different instantiations fails.

Flix's answer is a mandatory annotation at the extraction point (`14/flix` §7.3). This language has
no annotation to write, so the fallback is a diagnostic that names the refactor: "`f` is used here
with an effectful callback and there with a pure one; a `let` binding fixes which. Move it to a
top-level definition, or inline it." That is a worse story than Flix's and it is the sharpest open
risk in the design (§11 Q2).

### 4.4 Sub-typing, not just unification

A pure function must be usable wherever an effectful one is expected, in *every* covariant
position, not only as a lambda argument. P1 §4.3 takes Flix's restriction to lambda arguments, and
it does not typecheck P1's own `Task.par2` when the two thunks are named rather than written
inline, nor a record field of function type holding a pure function. With a two-point lattice,
general subsumption is cheap: `false ⊑ true` everywhere a function type appears covariantly.

---

## 5. Semantics

- **Strict, left to right, in source order.** Arguments are evaluated left to right, `let`
  bindings in the order written. This must be specified because it becomes observable, and
  PureScript's MagicDo has had exactly this open since 2020 (`14/purescript` §3;
  `01-solution-space.md` §5, sub-decision 8).
  **2026-09-18: now normative in `language.md` §6, *Evaluation order*, construct by construct** —
  this bullet is no longer where the rule lives, and effects add only the next one to it.
- **A call with `impure` is never eliminated, duplicated, reordered across another `impure` call,
  or memoised**, even when its result is unused. A call with neither bit may be.
- **One-shot.** The runtime resumes a suspended call exactly once, or never.
- **Thunks are the deferral primitive.** `() -> t` is a value; calling it performs.
- **Loops are recursion and higher-order functions**, as today. Bit polymorphism is what makes
  that sufficient.

---

## 6. The platform

The runtime this section describes is the one `research/16` §5 specifies. Its shape T — *"the
runtime owns the resume callback, exactly as `_Scheduler_binding` and `OP_ASYNC` do"* (§5.1) — is
what 2026-09-15's decision buys, and everything below is a consequence of owning that callback.

### 6.1 Primitives

`foreign suspends impure httpSend : Request -> Response` is implemented by a JavaScript function
that returns **either a value or a suspension**. A value resumes inline (§7.2). A suspension is a
registration: the primitive is handed the fiber's resume callback and calls it exactly once, or
never. This is P1 §7.4's `Step` protocol, which the earlier draft deleted and which the decision
restores — Koka's runtime protocol in miniature (`14/koka` §0.2), without evidence vectors because
there is exactly one handler.

Holding the resume callback is the whole decision. Everything in §6.2 follows from it and from
nothing else.

### 6.2 Cancellation

**The scheduler holds the continuation of a parked fiber and resumes it with an interrupt, without
consulting the primitive.** `research/16` §2.4 reads Effect's mechanism and it is four lines
(`internal/fiberRuntime.js:709-717`): `OP_INTERRUPT_SIGNAL` calls `this._asyncInterruptor` with a
failure exit and clears it. `_asyncInterruptor` *is* the resume callback the `Async` op handed out,
and it is one-shot. The fiber unwinds through its finalisers at cancel time; the abandoned
primitive's later resume is dropped on the floor; the primitive is never asked to cooperate.

`research/16` §5.3 row 3 states the four obligations. All four are free under this lowering, and
none of them was dischargeable under the earlier one:

1. an interrupt delivered to a **parked** fiber resumes it, rather than waiting on the primitive;
2. finalisers run at cancel time, in LIFO order;
3. the abandoned primitive's later resume is dropped — the resume callback is one-shot;
4. descendants are signalled before the parent unwinds.

What this replaces is the earlier draft's *"cancellation is an `AbortController`… cancelling rejects
the pending `await`, which unwinds through `try`/`finally` in the emitted code — so finalizers
run."* `research/16` §5.6 records that as the one claim this document asserted without hedging and
that the report refutes: §2.4 measured the `finally` running at 301 ms for a cancel issued at 51 ms,
and §3.6 case (i) is worse — a primitive that never settles deletes the finaliser entirely, the
frame collected and nothing reported.

**Nobody interrupts a synchronous loop**, under any lowering. `research/16` §4.7 is unanimous across
six runtimes: cancellation is cooperative, delivered at a suspension point, never a forced unwind,
because a forcibly-unwound task either runs unbounded cleanup or corrupts invariants. §5.3 row 3
says not to propose otherwise. `Task.yield` compiles to a polled `scope.cancelled` check, measured
at **3 ns** (§3.5).

### 6.3 `bracket` is a finaliser list, not `try`/`finally`

`Task.bracket` pushes its release onto the fiber's `finalizers` and sets an uninterruptible flag
over the acquire and over the release. It is not emitted as `try`/`finally` in the body.
`research/16` §5.3 row 4: under shape T *"this is a push onto `finalizers` and a flag"*, where
under native `async` it is `try`/`finally` with `research/16` §3.6's three caveats — a
never-settling `await` that deletes the finaliser, a suspending `finally` that delays cancellation
without bound, and a `finally` that returns and discards the cancellation. ZIO and Cats Effect
state the uninterruptible release as a documented guarantee (`research/16` §4.1, §4.2); Cats Effect
enforces it with a `masks += 1` that is never popped.

**One consequence for §3.2, worth recording because it retires an open amendment.** `research/16`
§5.3 row 4 calls `sync` *"load-bearing"* for `bracket`'s release **under native `async`** — a
release that cannot suspend cannot delay a cancellation — and observes that a platform signature
demanding a non-suspending argument needs `sync` in a **type** position, which §3.2 explicitly
refuses ("it is not a different type, and a `sync` function unifies with an ordinary one"). Under
this lowering the release runs uninterruptibly by construction, and `research/16` §5.6's table
types `bracket` under T with no such condition. So the runtime removes `bracket`'s demand for a
non-suspending argument entirely, and that is one of the two reasons §3.2 can be postponed without
losing anything: no concurrency primitive needs it. The other argument-position demands — `view`,
a comparator, a decoder — are *not* retired by this and remain §3.2's open case. They are also the
only thing that could force the bits into the type language, so §4.1's "the unifier *is* unchanged"
holds for v1 and is re-opened by whatever answers §3.2. Where a
suspending release is genuinely required, take Trio's bounded shield
(`move_on_after(CLEANUP_TIMEOUT, shield=True)`) and not Kotlin's unbounded
`withContext(NonCancellable)` (`research/16` §4.7).

### 6.4 The fiber record

`research/16` §5.2 is the specification, field for field:

| field | why |
|---|---|
| `outcome : ?Exit a` | without it nothing can learn what a spawned task produced |
| `observers : ?[]fn(Exit a)` | join, race, scope-exit and `Queue.take` are one mechanism |
| `parent : ?*Fiber` | cancellation must reach descendants |
| `children : ?Set(*Fiber)` | the scope rule: the block cannot exit until these are empty |
| `finalizers : ?[]fn(Exit a)` | §6.3; without it "a killed process leaks whatever it held" |
| `interruptor : ?fn(Exit a)` | §6.2's resume callback — Effect's `_asyncInterruptor` |
| `opCount : u32` | §7.5's fairness, and the smaller half of it |

**Not on the fiber: the `AbortController`.** An `AbortController` plus one listener costs 753 B and
0.98 µs on its own, more than doubling a bare frame, and `AbortSignal.any` costs 384 ns per
derivation (`research/16` §3.8 row 2, §3.5). One signal goes on the **scope**, fibers read
`scope.cancelled` through the parent chain, and a real `AbortController` is minted only at the leaf
where a platform primitive demands one. With that, the measured record is **692 B and 0.89 µs per
fiber** — 1.4× a bare parked `async` frame and 0.2× an Effect fiber (§3.8).

The field the earlier lowering got for free and this one pays for is the continuation stack.
`research/16` §5.2: *"`_stack` is deliberately absent"* under native `async`, because V8's async
frame *is* the stack; *"under shape T it comes back, and CE3's split `conts: ByteStack` +
`objectState: ArrayStack` is the layout to copy."*

### 6.5 The primitives

Eleven, typed as `research/16` §5.3 types them, all bit-polymorphic over thunks:

```elm
Task.spawn       : (⊤ → a) → Fiber a
Fiber.join       : Fiber a → Result Cancelled a
Fiber.cancel     : Fiber a → ⊤
Task.scope       : (Scope → a) → a
Scope.spawn      : Scope, (⊤ → b) → Fiber b
Task.bracket     : (⊤ → r), (r → ⊤), (r → a) → a
Task.par2        : (⊤ → a), (⊤ → b) → a × b
Task.parAll      : Int, List (⊤ → a) → List a        -- bounded concurrency
Task.race        : List (⊤ → a) → a                  -- losers cancelled, finalisers run
Task.timeout     : Int, (⊤ → a) → Maybe a
Task.retry       : Int, (⊤ → Result x a) → Result x a
Semaphore.with   : Semaphore, (⊤ → a) → a
Queue.take       : Queue a → a
Queue.put        : Queue a, a → ⊤
RateLimiter.with : RateLimiter, (⊤ → a) → a
```

*Amended 2026-10-02 (the owner's adoption of research 48's decisions; §17 is the contract):* **the
signatures above are superseded** and are kept only so the argument below stays readable. What
replaces each:

| Above | Now | Why |
|---|---|---|
| `Fiber.join : Fiber a → Result Cancelled a` | `Task.join : Fiber a → a` (propagates) and `Task.wait : Fiber a → Exit a` (observes), as built (§16.5) | A1, A2: a defect is fatal and `Exit a = Done a \| Cancelled` |
| `Fiber.cancel`, `Scope.spawn` | `Task.cancel`, `Task.spawnIn`, as built | a nullary method cannot be dot-called (`static-dispatch-spike.md` §1.1), so these are qualified calls of `Task` |
| `Task.bracket : (() → r), (r → ()), (r → a) → a` | `Task.bracket : (() → r), (r, Exit a → ()), (r → a) → a`, as built | A3: the release sees the outcome |
| `Task.par2` | `Task.par`, `Task.par3`, `Task.parOk` (§17.7) | one name per arity; `parOk` is the fail-fast form research 48 §0 finding 4 forces |
| `Task.parAll : Int, List (() → a) → List a` | `Task.forEach : List a, Int, (a → b) → List b` and `Task.forEachOk` (§17.7) | subject first; the bound stays mandatory |
| `Task.race : List (() → a) → a` | `Task.race`, `Task.raceAll`, `Task.raceOk` (§17.7) | a first argument makes the list non-empty; `raceOk` is Effect's `race` on a `Result` |
| `Task.timeout : Int, …` | `Task.timeout : Duration, (() → a) → Maybe a` (§17.7) | A12 (3): `Duration`, not a bare `Int` |
| `Task.retry : Int, …` | `Task.retry : Schedule e, (() → Result e a) → Result e a` and `Task.repeat` (§17.8) | A4: a `Schedule`, not a count |
| `Semaphore.with` | `Semaphore.withPermit`, `Semaphore.withPermits` (§17.9) | Effect's names; FIFO (decision 8) |
| `Queue.take : Queue a → a`, `Queue.put` | `Queue.take : Queue a → Maybe a`, `Queue.offer : Queue a, a → Bool` (§17.9) | decision 9: `Nothing` once ended and drained; Effect's `offer` |
| `RateLimiter.with` | **not in this adoption** | Effect v4 keeps its rate limiter in `unstable/persistence` over a store; a `Semaphore` and `Task.sleep` write one, and it waits with `Pool` for the batteries slice (`plans/effects-plan.md` §8, P9) |

The three obligations below hold unchanged for the new signatures: the bound is mandatory, every
argument is a thunk, and a cancelled waiter is removed from every waiter list.

**All eleven are available, and that is the point of the decision.** `research/16` §5.6: seven of
the eleven — spawn/join, scope, bounded parallel, retry, semaphore, queue, rate limiter — are free
under both lowerings, *"in the strong sense: same type, same runtime obligations, no difference in
cost."* The four that differ are **cancel, bracket, race and timeout**, and all four are the same
thing: cancellation. Prompt cancel is *"not available"* under native `async` without §3.7's raced
suspension point at ~1 µs each. `bracket` carries §3.6's three caveats. `Task.race` *"must be built
on `Task.scope`, not on `Promise.race`"*, because `Promise.race` forgets its losers — a loser
holding a socket holds it until the process dies and no `finally` ever runs. `timeout` is a race
against a sleep and inherits row 6 exactly. Owning the resume callback makes all four free, which
is the whole of what was bought.

`bracket` and `race` are also the two primitives P1 §6's list does not have; `research/16` §5.6
says so and says this document's list "is the more complete one". `bracket` is the one
`14/effect-ts` §6 says the answer "must" be.

Three obligations `research/16` singles out that the implementation is held to:

- **The `Int` on `parAll` is mandatory, not defaulted.** Not because Effect defaults to unbounded —
  `research/16` §2.6 shows it does not — but because *"`'unbounded'` is one word away from a
  number, and 901 MiB is one word away from 78.6 KiB for the same 200,000 operations"*
  (`research/16` §3.4, §5.3 row 5). Cats Effect's `require(n >= 1, …)` is the model.
- **A thunk, never a started computation.** `retry` is free *"only because the argument is a
  thunk"*: a `Promise` is already running and cannot be restarted (§5.3 row 8, quoting Trio's
  Smith). No beni API may hand out a started computation in a thunk's place. P1 and this document
  agree here and §5.6 calls the agreement load-bearing.
- **A cancelled `Queue` taker is removed from the waiter list**, or the queue leaks a dead waiter
  per cancellation and eventually hands a value to nobody. This is why `finalizers` has to exist
  before `Queue` can be written correctly (§5.3 row 10).

**`Scope` escape cannot be typed away**, under either lowering. `research/16` §5.3 row 2: preventing
a `Scope` from outliving its block needs region or rank-2 typing, `checker.md` §6.3 says "nothing
else may be added to `Kind`", and §4.1's whole argument is that the flags ride *alongside*
unification rather than inside it. Take Trio's position — the `Scope` is an ordinary value and the
guarantee is the runtime's, not the type's — with Smith's defence that an explicitly passed nursery
is visible at every call site. `research/16` §6 lists a Haskell-`ST`-style rank-2 skolem on
`Task.scope`'s callback as the thing it did not cost against beni's checker; if it is cheap, row 2
is wrong and beni gets something Trio, Kotlin and Go do not have.

**The one row where the earlier lowering was better**, recorded rather than buried: bounded fan-out.
`research/16` §3.4 measured a worker pool over 200,000 tasks at 22 ms and 78.6 KiB against
`Promise.all`'s 92 ms and 901 MiB, and §5.3 row 5 notes that under native `async` `parAll` is *"`n`
async worker loops over a shared index — sixteen lines, no fiber runtime"*. Under this lowering it
allocates a fiber record per in-flight task. At 692 B each against a bound the caller is required to
supply, that is a bounded cost rather than an unbounded one, but it is a real one and §9 counts it.

### 6.6 What this does to The Elm Architecture, and where the rest of it lives

**One language-level claim, and it is the only thing about TEA this document makes.** Everything a
TEA program performs lives in thunks handed to the runtime, `update` stays a pure function of
message and model, and time-travel debugging is unaffected because a command is still an inert
value the runtime interprets. That is what Roc's users lost when `Task` was removed (`14/roc` §4)
and it is the property this design has to be shown not to break.

**What holds that property up, in v1 and later.** It is the shape of the platform's API: `update`
returns a `Cmd` rather than performing, and a `view` returns `Html`. Nothing in v1 *enforces* it —
with §3.2 postponed there is no way to say "this one must not suspend", so a `view` that reaches a
suspending call is a runtime failure at the JavaScript boundary rather than a compile error. When
`sync` lands, the author writes it on `update` and `view` and the compiler rejects the call,
naming the chain (§8). Until then the guarantee is conventional, not checked — and that is the
sharpest practical cost of postponing §3.2, listed there.

**Everything else about TEA is a platform package's API and is out of scope here.** The command
type, its cancellation vocabulary, the concurrency policy on a keyed command, key scoping, and
subscriptions are ordinary functions over thunks written in beni, needing no language support —
which is the point rather than an omission. They are specified in `boundary.md` §5.4, which
`boundary.md` §5.3 already names as the browser platform's shape. If any of them turned out to need
a language feature, that would be a finding against this proposal; none of them does.

---

## 7. Compilation

Decided 2026-09-15. This section replaces the `async`/`await` lowering the earlier draft chose, and
adopts P1 §7.2's, whose argument was right.

### 7.1 The rule

A function whose `suspends` bit is `false` compiles as today. A function whose `suspends` bit is
`true`, or still a variable, is lowered to a **suspendable form**: **L1, closures with join
points**. Each suspending call becomes "call the primitive; if it returned a value, continue
inline; if it returned a suspension, hand the rest of the function to the scheduler as a
continuation closure".
Lean's elaborator and Koka's monadic pass are this shape (`14/lean4` §0.1, `14/koka` §4.2).

**Why L1 and not a state machine.** P1 §7.2's reason is the one that holds: continuations are
functions, so the output stays ordinary closures and calls, which is what §9.5's code splitting, DCE
and renaming already handle, and locations stay exact without special discipline. L2 — a `switch`
on a state integer with locals hoisted to fields — is type-blind and backend-only, and its known
trap is that hoisted declarations must be unmapped or the debugger breaks; TypeScript shipped that
bug and is now deleting the whole transform for complexity (`14/regenerator` §0.1, §0.3, §3).

**Join points are mandatory.** A branch after a suspension must not duplicate the rest of the
function into every arm. Lean carries a `duplicable`/`nonDuplicable` flag on its continuation and
introduces a join point whenever `numRegularExits > 1`; `14/lean4` §6 states the consequence of
omitting it — "not slow code; it is exponential code size in nested branches". Xie and Leijen
measure the same shape from the other side: *"if we have a sequence of N statements, we may end up
with 2^N duplications"* (`14/koka` §4.2). Leijen's own unticked todo on the resulting bloat —
*"in effectful code we generate many join-points …, can we increase the sharing/reduce the extra
code"* — is the acknowledged cost of getting it right.

**Native generators (L3) stay rejected**, on the reason of P1 §7.2's four that survives contact with
this design: `yield` cannot cross a function boundary — it is a parse error inside an arrow
function, enforced by the grammar, not a runtime check (`14/javascript` §0.2) — so every effectful
lambda would have to be its own generator, and `14/effect-ts` §2.4 is what that costs when the
runtime abandons the iterator frame.

### 7.2 The synchronous fast path

This is the largest thing the decision buys, and it is a gain rather than a mitigation.

A `foreign suspends` primitive that completes synchronously — a cache hit, a `localStorage` read, a
lookup behind an async-shaped API — returns a value rather than a suspension, and the caller
continues **inline, on the same stack, in the same tick**. Koka emits exactly this: a call, an
`if (_yielding())` test, and two branches, with the non-yielding branch inlined straight-line *"so
the fast path reads like ordinary code"* (`14/koka` §4.2). **The microtask turn per effectful call
is gone entirely.**

Under native `async`/`await` that path does not exist, and the specification says it cannot. `Await`
wraps a non-promise with `PromiseResolve`, enqueues a reaction job with `PerformPromiseThen`, and
returns to the caller: *"there is no branch for 'the value was already there'"* (`research/16` §3.1,
quoting ECMA-262 §27.10.5.3). Measured:

| | ns/op | vs direct |
|---|---|---|
| direct call | **1.8** | 1× |
| `await` on a non-promise | 122–135 | ~70× |
| `await` on an `async function` returning a value | 117–129 | ~68× |

`research/16` §3.1 costs the earlier draft's own worked example: a memoising `getUser` that hits
cache 480 times in 500 pays 480 × ~120 ns ≈ 58 µs **and 480 event-loop turns** under
`async`/`await`, and neither under this lowering. **The old §7.2 — "the cost, stated plainly", and
the cache-hit argument that accepted it — is deleted, not softened. That cost no longer exists.**

### 7.3 A trampoline for tail calls

A deliverable, not a risk. CPS moves a recursive tail call inside a continuation closure, and beni
has no tail-call elimination: `core/List.beni` says `foldl` is `foreign` because "written in beni it
is a self tail call, which the code generator is not yet required to turn into a loop".

**Corrected 2026-09-18 — the loop landed and the folds left `foreign` with it** (`backend.md`
§8). Direct self-recursion lowers to `label: while (true)` with carried parameters in
`$in$<i>` slots and a per-iteration `const` prologue; `core/List.beni:68` and `:86` are ordinary beni
and there is no `foreign` value left in the repository with a function type in its signature. The
sentence above is kept because it was the argument for scheduling the loop first. What it costs the
lowering below is *not* nothing: a suspendable body that is also a looping body has to return a
continuation instead of executing `continue`, and the composition is worked in
[`plans/effects-plan.md`](../../plans/effects-plan.md) §2.2. The miscompile the ordering existed to
prevent has **moved rather than gone** — `core/List.js`'s `eq` and `compare` are JavaScript loops
that call a beni evidence function, which is the same hazard in the position static dispatch
created (plan §2.1).

Xie and
Leijen name the defect exactly — *"any direct tail-recursive calls are no longer directly
tail-recursive as they occur under a lambda now!"* — and Koka's backend answers it in the emitted
JavaScript with `{ tailcall: while(1) { … continue tailcall; } }`, carrying the same `_yielding()`
test at each suspension point and returning, on a yield, a continuation closed over the remaining
work (`14/koka` §4.2).

beni emits the same. A self tail call in a suspendable body becomes a `continue` in the trampoline.
A tail call between suspendable functions passes the caller's continuation along rather than
building a frame, so an effectful fold does not accumulate O(n) live frames either. Without the
trampoline an effectful fold over a long list overflows the JavaScript stack — which is
`typed-effects-review.md` §A4's first item, raised against P1's lowering and inherited here in
full, and which the earlier draft escaped only because the microtask queue resumed each
continuation on a fresh stack.

### 7.4 Stack traces and source maps

A deliverable, and this is what the decision is paid for with. Native `async` was giving V8's
zero-cost async stack traces and native debugger stepping for nothing (`14/javascript` §0.3); under
CPS they are bought.

- **Each continuation carries the source span of the call it resumes**, and the runtime keeps the
  chain of pending continuations, so a failure inside a suspended function reports a logical call
  stack rather than the scheduler's frame.
- **Each continuation is emitted at its original call's position**, and is named rather than
  anonymous. Koka's break after a suspension shows `_mlift_fetch_summary_10174`, a synthesised
  top-level function the user never wrote, with parameters reconstructed from the live set — and
  Koka has had no source maps at all since 2017 (`14/koka` §4.2). That is the outcome to avoid.
- **The hoisting hazard is documented in both implementations of the other transform.** TypeScript
  kept the original source-map range on a hoisted declaration and made it *"practically impossible"*
  to break after an `await` (`microsoft/TypeScript#14506`, fixed by `#16376`, which moves the
  mapping onto the assignment); regenerator's `hoist.js` records the same hazard from the other
  direction. `14/regenerator` §4.3's verdict applies to any lowering that moves code: *"not
  discoverable by testing that output runs; it is discoverable only by stepping in a debugger."*

`14/effect-ts` §7.6 is the warning against deferring this: the generator *"destroys the call stack
and the source location, and Effect paid for that twice"* — `Effect.fn`'s two synthetic `Error`s and
a rejected build-time AST transform. A fixture suite for traces and for stepping ships with the
lowering, as `?`'s did.

### 7.5 Two-tier scheduling

Now achievable, and it was not before.

**An operation counter alone does not fix fairness, and Effect is the proof.** `research/16` §2.3
measured an `Effect.sync` chain of 2,000,000 operations with a `setTimeout(…, 0)` armed at the
start: the fiber yields ~977 times, the counter works perfectly, and **the armed timer fires after
361 ms**. A microtask is not a yield — it does not reach rendering or timers — so the page is frozen
for the duration. `research/16` §3.3 measures the same thing without Effect: a tight `await` loop
starves an armed `setTimeout(0)` for its full 274 ms.

**The fix is a macrotask escape, and three JavaScript-targeting runtimes arrived at it
independently** (`research/16` §4.7): Effect's `MixedScheduler` escapes to `setTimeout(…, 0)` every
2048 nested microtask drains, Cats Effect's `BatchingMacrotaskExecutor` every 64 fibers, and
kotlinx.coroutines every 16 messages — using `window.postMessage` in the browser to dodge
`setTimeout` clamping, with the reason in its KDoc: *"not to starve animations and non-coroutines
macrotasks."*

**The budget.** Run continuations in microtasks for throughput; escape to a macrotask every **64**
resumptions. `research/16` §5.5: *"the constant should be closer to Cats Effect's 64 or Kotlin's 16
than to Effect's 2048"*, because §2.3 measured what 2048 buys — Effect's is two to three orders of
magnitude too large for a browser. §5.5 also says it is *"the one number in this report that should
be a `foreign`-configurable platform constant rather than a language decision, since a server
platform wants it large and a browser platform wants it small"*, so 64 is the browser platform's
default and the number is not in the language. The mechanism is a counter on the current scope,
incremented at each suspension point, and one `await`-shaped park on a macrotask when it trips: a
dozen lines, not a second runtime.

**What it costs, stated with the measurement's limits.** `research/16` §3.3 priced a macrotask
yield every 2048 suspension points at **5.0× throughput** for 1.1 ms timer latency instead of
274 ms. At 64 the throughput cost is larger and was not measured. Every figure in `research/16` is
from Node, and its §6 — its own list of what it could not settle — names the missing experiment as
the single most valuable thing absent from it: a
`requestAnimationFrame` latency histogram at budgets of 16, 64, 512 and 2048, in Chrome and Firefox.
64 is therefore a starting value with an experiment attached to it (§11 Q3a).

### 7.6 Bit-polymorphic functions

`List.map` with a pure callback should be a plain loop; with an effectful one it must be
suspendable. **Double translation**: two compiled bodies per bit-polymorphic function, selected
statically at each call site from the instantiated flags, with the suspendable copy used whenever
the flag is still a variable. js_of_ocaml does this at run time because it cannot know statically,
and needed a lambda-lifting pass to make it tractable (`14/ocaml5` §2.3).

**The fallback is now cheap where it was not.** If double translation does not land, compile every
bit-polymorphic function once in the suspendable form with Koka's `if (_yielding())` test after each
callback invocation (`14/koka` §4.2). Pure callers then pay **a predictable branch**, not the
microtask turn the old §7.2 would have charged them on every `List.map` in pure code. The risk
reverses: under the earlier lowering the fallback was the shape most likely to hurt, and under this
one it is tolerable. What Koka's own history warns against is letting that cost leak upward — it
added `fun`/`val` tail-resumptive operations and `linear effect` to escape it, *"three keywords the
user must choose between"* (`14/koka` §4.2), and this design has nowhere to put such a keyword,
which is a reason to land double translation rather than to rely on the fallback.

---

## 8. Diagnostics

Three errors carry this feature, and **only one of them is a v1 error**, because the other two
belong to §3.2's postponed `sync`. There is no set expression to print, which is the failure mode
the research found in Koka and Flix (`14/koka` §4.3, `14/flix` §7.5).

| Code | v1 | When | Shape |
|---|---|---|---|
| `flag_monomorphised` | yes | §4.3's extraction hazard | "`f` is used here with an effectful callback and there with a pure one. A `let` binding fixes which one it is; move it to a top-level definition, or inline it." |
| `must_not_suspend` | with §3.2 | a `sync` function suspends | names the constraint, then the chain: "`view` is `sync`, but it suspends. `view` calls `renderRow` (View.beni:12), `renderRow` calls `iconFor` (View.beni:40), `iconFor` calls `fetchIcon` (Icon.beni:8), which suspends." |
| `sync_boundary` | needs the bits in the type | a suspending function is passed where a `sync` one is required | as above, at the argument |

`sync_boundary` is listed as *unimplementable under §3.2 as drafted*, not as scheduled work: it
fires at an argument, so the requirement lives in a parameter type, and a keyword on a declaration
cannot get there. It ships when §3.2's open question is answered, and its answer decides whether
the bits stay out of the type language.

**Corrected 2026-09-18.** §3.2's question is answered (`research/17` §6.1): `sync_boundary` is
**not droppable**, so the bits do not stay out of the type language, and the table's third row is
scheduled work rather than a hypothetical. Two additions the table does not have. A `must_not_suspend`
chain that crosses a module boundary needs a **witness in the interface** — `checker.md` §7 keeps
`Interface.Provenance` deliberately out of the record, so there is no call graph with spans to walk
— and `sync_boundary` now also fires at an **evidence** argument, which is a slot the source never
wrote (plan §2.1). Both are specified in
[`plans/effects-plan.md`](../../plans/effects-plan.md) §2.5.

**Specified 2026-09-30 in §15.4**: `must_not_suspend` is `main`'s and a well-known `eq`/`compare`'s,
`sync_boundary` every argument position, and the chain stops at one hop per module (decision 7a).
`flag_monomorphised` is not built.

The chain in `must_not_suspend` is the whole diagnostic budget of the boundary check, and it is
what replaces the marker: the compiler knows the path and prints it, rather than asking the author
to have written a character at every link. Note that this is the one place the argument for
inference-without-syntax is *paid for in errors* — until §3.2 lands there is no boundary check at
all, and once it does, the chain is where a reader first meets a concept the source never names
(§9.2).

---

## 9. What this costs, honestly

### 9.1 The accepted risk: silent interruption points

A maintainer adds a log line to a leaf function. If that primitive suspends, every caller becomes
suspendable. Nothing fails to compile anywhere — types still check, no signature changes, no
reviewer sees anything — and a new interruption point appears in the middle of someone else's
charge-then-reserve sequence three packages away.

**The 2026-09-15 decision makes this sharper, not milder, and the document should say so plainly.**
Under the earlier lowering an interruption point was a microtask boundary and not much else. Under
a fiber runtime it is where a cancellation is delivered, where a finaliser fires, where a sibling
fiber interleaves, and where the scheduler may take the frame back (§6.2, §6.3, §7.5). §6.2's four
obligations are all defined *at those points*. So the thing the source does not show has become the
thing the concurrency feature is built out of — a first-class, user-visible concern — and the source
still shows nothing. `research/16` §3.3 puts the same point the other way round: `suspends` is not
the same bit as "can be interrupted", because a suspension point is also a point at which nothing
else can run.

There is no annotation to catch it, because this proposal has none. `sync` would not catch it even
once it lands (§3.2), because the sequence was never meant to be synchronous, it was meant to be
uninterruptible, and those are different properties. `bracket`'s uninterruptible acquire and
release (§6.3) is the right answer for a *resource* and no answer at all for a *sequence*. Two
partial answers remain:

- A `beni diff` that computes the published interface, including both bits, and forces the semver
  bump. This is what Elm already does for types and it catches every other API change too.
- Editor colouring, which shows suspension points on demand.

**This is a decision, not an oversight.** P1 pays a mandatory marker on every effectful call in the
language to make this class of change visible. This proposal judges the trade the other way, and
since 2026-09-15 judges it knowing that the stakes went up. A reviewer who thinks that is wrong
should argue §11 Q1.

### 9.2 Transparency versus control — the central unresolved thing in this document

Interruption points and suspension points are the same points. A design that hides suspension hides
where a fiber can be cancelled, where a finaliser fires, and where another fiber interleaves. The
2026-09-15 decision does not resolve that tension; it sharpens it, because the author has chosen
**both horns**:

- **Full control.** §6 takes all eleven primitives and Effect's cancellation semantics, which is the
  entire reason for owning the resume callback.
- **Full transparency.** §3 keeps the surface at zero — no marker, no names, nothing at any call
  site.

Every other system `research/16` §4 surveys that has the first has some written form of the second:
Kotlin's `suspend`, Swift's `await`, ZIO's and Cats Effect's effect type, Trio's explicitly passed
nursery — which Smith defends in precisely these terms, *"since nursery objects have to be passed
around explicitly, you can immediately identify which functions violate normal flow control by
looking at their call sites"* (`research/16` §5.3 row 2).

This document takes both anyway, and records it as a **deliberate bet** rather than an oversight.
The precedent that it is survivable is Kotlin: the bit on the declaration, unmarked call sites, a
gutter marker in the IDE, and the structured-concurrency story the rest of the industry copies — at
a scale no effect system in the research reaches. Kotlin is one data point and it is the only one.
This is now the thing in the document most likely to be wrong, and it is no longer a footnote.

### 9.3 What is given up relative to P1

- **Named effects.** No signature says "this reaches the network but only logs". §1 item 3 of P1 is
  gone. The counter-evidence is on this side: PureScript removed effect rows as "enormous work for
  developers … for no more actual guarantee" and "anti-modular in that you need a canonical
  location for an effect like DOM" (`14/purescript` §3) — and a platform-owned vocabulary is
  *more* centralised than PureScript's, not less. Roc built platform-declared effect tags on
  `Task` and removed them, and its community converged on "granularity is the platform's job,
  expressed as capability values, not the compiler's job, expressed as effect names"
  (`14/roc-zulip-effect-granularity`). Restriction at a useful granularity is a capability record
  passed as an argument, which needs no language support:

  ```elm
  type alias Payments = { charge : Cents → Receipt, refund : ReceiptId → ⊤ }
  ```

- **Sandboxing.** Same as P1, which also disclaimed it.
- **User-defined effects and handlers.** Deferred, as in P1 — and note `14/effekt` §1's warning
  that first-class effectful thunks are safe here *only because nothing is ever discharged*. The
  moment a handler can discharge an effect, a thunk escaping its handler is Effekt's `leak`
  counterexample, which is why that language made blocks second-class. P1 §9.1 says the type side
  already accommodates handlers; it does not.
- **Multi-shot resumption.** Not wanted.

---

## 10. Prerequisites

0. **An enumeration of the platform's primitives and its imposed signatures**, which §3.1 and §3.2
   both defer to and which neither can be decided without. For each one: is it first-order, or does
   it take or return a function whose bits matter? If all first-order, §3.1's keyword is enough,
   `sync` stays a declaration modifier, §8's `sync_boundary` is dropped, and the type grammar is
   untouched. If even one is higher-order, the bits belong in the type and §4.1's "the unifier is
   unchanged" is withdrawn. This is cheap, it is needed anyway to know how much of a program gets
   coloured, and **no surface decision should be frozen before it exists.**

   **Discharged 2026-09-15 by [`research/17-platform-primitives.md`](research/17-platform-primitives.md),
   and the answer is neither branch.** 54 of 71 projected primitives are first-order, so §3.1's
   keyword is enough and nothing needs `suspends` *inside* a signature — but six primitives and
   seven imposed signatures are functions the **host** calls back into beni synchronously, so `sync`
   needs an argument position and §8's `sync_boundary` is not droppable (report 17 §6.1). One bit,
   in one direction, on function-typed parameters only.
1. **`TypeStore.Func` is `{ param: Var, result: Var }`** — the checker's function type is curried
   and built by `Constrain.funcChain`, and `checker.md` §6.1's application rule is still written
   curried. The n-ary decision of 2026-09-14 has not landed. Flags have nowhere to live on a
   curried chain, so this comes first and nothing can be prototyped before it.

   **Corrected 2026-09-18 — landed, and the cost estimate moved with it.**
   `TypeStore.Structure.Func` is `{ params: Range, result: Var }` (`src/check/TypeStore.zig:249`),
   `Constrain.funcChain` is `Constrain.func` (`src/check/Constrain.zig:516`), and
   `Interface.Term.func` spends `lhs` on an `extra` range and `rhs` on the result
   (`src/resolve/Interface.zig:180-184`). Flags now have somewhere to live. What also changed is the
   price: `Func` is **already** 12 bytes and already the widest `Structure` payload, so
   `research/17-platform-primitives.md` §6.3's "free in size" — written when `Func` was 8 bytes —
   no longer holds. Two constant bits on `Func` grow `Structure` 16 → 20, `Content` 20 → 24 and
   `Descriptor` 40 → 44; two flag *variables* grow them to 24 / 28 / 48. Zero-growth encodings exist
   and are costed in [`plans/effects-plan.md`](../../plans/effects-plan.md) §3.
2. **`checker.md` §6.3** says a generalised scheme records per quantified variable its kind and
   equatable flag, and that "nothing else may be added to `Kind`". Flag variables are exactly such
   an addition and that paragraph needs amending.
3. **`boundary.md` §4** shape (b) must be rewritten: a platform effect is a `foreign` with bits, not
   a `foreign` at type `Task e a`.
4. **`fast-compiler.md` §3.1**'s Decided-2026-09-13 bullet must be marked as reversed.
5. **The fiber runtime itself**, which the 2026-09-15 decision makes the largest single deliverable
   in this proposal and the one with no beni precedent: §6.4's record, §6.5's eleven primitives,
   §6.2's interrupt path, §6.3's finaliser list, and §7.5's two-tier scheduler. `research/16` §5 is
   no longer a survey of what such a runtime could be — it is this runtime's **specification**,
   field for field in §5.2, signature for signature in §5.3, and §5.3's "runtime must promise"
   paragraphs are the test list. `research/16` §6 is the list of what it does not settle and is
   therefore this deliverable's first open work: no figure anywhere was measured in a browser,
   `Queue` and `RateLimiter` were reasoned from the fiber record rather than read from Effect, the
   parent-chain cancellation check §6.4 recommends was reasoned about and not measured, and
   unhandled-rejection behaviour was checked only on Node.
6. **The formatter.** `01-solution-space.md` §5 sub-decision 9: "whatever beni adds, the formatter
   rule is part of the feature." This proposal adds two keywords and no expression syntax, which is
   the smallest formatter surface of any option considered — but the `<|`-plus-lambda rule that
   `14/elm` §0.2 identifies as Elm's actual binding constraint is worth doing regardless of this
   document, and is the only intervention the Elm evidence says is certainly worth it.

**What static dispatch, adopted 2026-09-18, did to this list**
([`static-dispatch-spike.md`](static-dispatch-spike.md)). Item 2 still stands and is unaffected:
`Kind` was *not* added to — a method constraint lives in a per-variable constraint set beside the
kind, and that set, with its interface encoding, is now the precedent for where a flag variable
could live. Item 0 gains a case it did not have: **evidence is a hidden function-typed leading
parameter**, so every constrained call passes a function whose bits would matter, and the
higher-order question item 0 asks about platform primitives now has an affirmative answer inside
`core` regardless of what the platform turns out to need. Item 3 is unchanged, and `boundary.md` §4
has meanwhile acquired a second unenforced rule of its own — a `foreign` with a `where` clause —
which any rewrite of shape (b) has to account for.

**Updated 2026-09-18.** That rule is now enforced, as `boundary.md` §4's **check 4**:
a sibling export takes evidence count + declared arity parameters. The check counts parameters; it
cannot see what the sibling *does* with them, and `core/List.js`'s `eq` and `compare` call `m0` from
inside a JavaScript `while` loop. That is report 17 §1's kind (i) — a host-called beni callback — in
the one place the report's own grep for a parenthesised arrow in a `foreign` signature cannot find
it, and it is `foldl`'s miscompile in a new position. [`plans/effects-plan.md`](../../plans/effects-plan.md)
is the work-up.

---

## 11. Questions for reviewers

1. **The accepted risk.** §9.1. Is invisible colouring the right trade, given that the failure mode
   is a silently-added interruption point rather than a compile error? Would `beni diff` plus
   editor colouring genuinely have caught the case you have in mind?
2. **Extraction.** §4.3 has no annotation to offer at the extraction point, which is what Flix uses
   to recover. Is a diagnostic enough, or does this force flag annotations back into the surface?
3. **The scheduler's constants, now that we own the scheduler.** The question this slot used to ask
   is answered: `research/16` §5.5 says the event loop suffices for ordering, for bounding in-flight
   work and for parking, and does **not** suffice for giving the frame back, and 2026-09-15 decided
   to own it. Three questions replace it.
   **(a) The budget.** §7.5 proposes 64 as the browser platform's default, from Cats Effect's 64
   and Kotlin's 16 against Effect's 2048. `research/16` §3.3's 5.0× throughput figure is measured
   at 2048, nothing was measured in a browser, and `research/16` §6 names the experiment that would
   settle it. What is the number, and who runs the histogram?
   **(b) Can the fiber record be lazy?** 692 B and 0.89 µs per fiber (§3.8) is cheap against an
   Effect fiber and expensive against a straight-line call. Most suspending calls never spawn, never
   join and never install a finaliser. Can §6.4's record be materialised only when something
   observes the fiber, so that a plain `httpSend` costs a continuation closure and nothing else —
   and does that survive `Task.scope`'s requirement that `children` be exact?
   **(c) What does a cancelled fiber's finaliser list cost?** §6.3 makes `bracket` a push and a
   flag, and an unwind walks the list LIFO with acquire and release uninterruptible. `research/16`
   measured the record and not the unwind, and `Queue`'s waiter-list removal (§5.3 row 10) runs on
   that path. What is the cost of cancelling a deep scope, and is LIFO-over-a-list the right
   structure?
4. **Parallel bindings.** §3.4 adopts `and`. Open within it: should a group's items be allowed to
   fail independently, so one failure cancels its siblings, or should the group collect every
   result? And is the ban on `<-` inside a group the right call, or should the last item of a group
   be allowed to bind the rest of the block?

5. **`?` in lambdas.** `language.md` §6.6 forbids it. Every realistic effect is fallible, so the
   callback people want is `λid -> getUser id?`, and it is banned. The lambda's own result is
   `Result`, so early return from it is exactly Rust's rule. Should the ban be narrowed?
6. **Two bits or one.** §2 splits `suspends` from `impure` because logging saturates a purity bit
   while a suspension bit stays sparse, and because a synchronous random generator breaks
   memoisation without colouring anything. Is `impure` worth tracking separately, or should the
   optimiser just be conservative about anything reaching a `foreign`?
7. **Double translation.** §7.6. Two compiled bodies per bit-polymorphic function, or one
   suspendable body with Koka's `if (_yielding())` test on every `List.map` in pure code? The
   2026-09-15 decision made the fallback much cheaper — a predictable branch, where under the
   earlier lowering it was a microtask turn — so the question is now whether double translation is
   worth building at all, and whether `research/16` §6's unanswered one (how a raced or bounded
   primitive interacts with a third compiled body) resurfaces under this lowering.
8. **`sync`, now that §3.2 postpones it.** The spreading worry this slot used to raise is
   withdrawn: `sync` propagates as a *check* down the call tree, not as an obligation to write the
   keyword, so the cost is one token per boundary and nothing in the tree below. Two questions
   replace it. **(a)** Is v1 shipping without any boundary check acceptable, given §1 calls the
   boundary question load-bearing — and what actually happens today when a suspending function is
   called from JavaScript expecting a value? **(b)** Enumerate the platform's primitives and its
   imposed signatures (§10 item 0). If any of them constrains a nested function type, `sync` and
   §3.1's `foreign` keyword both need the bits in the type, and §4.1's "the unifier is unchanged"
   goes with them. That one enumeration answers §3.1, §3.2 and §8's `sync_boundary` at once, and
   nothing about the surface should be frozen before it exists.
   **(b) is discharged, 2026-09-15**, by `research/17-platform-primitives.md`: the keyword is frozen,
   `sync` needs the type position, `sync_boundary` stays. **(a) is still open and is now the sharper
   half**, because `boundary.md` §5.4's promise that "`update` and `view` are `sync`" has no
   mechanism, and because check 4 counts a sibling's parameters without seeing what it does with
   them (§10). It is decision 1 of [`plans/effects-plan.md`](../../plans/effects-plan.md) §5.
9. **Bare `let` items.** §3.3. Is the type guard enough to keep this from becoming statements, or
   does the first request for `for` arrive the week after it ships? And should a pure bare item be
   a warning or an error?
10. **What is missing.** `01-solution-space.md` §5 lists ten recurring sub-decisions. This document
   answers evaluation order (8) and the formatter (9) and leaves parallel binds (6) open. What else
   in the seventeen reports does it ignore?
11. **Deterministic testing and fiber observability.** These are the two things owning the runtime
   buys that nothing else in this document claims, and that neither the earlier lowering nor P1
   could offer. A scheduler whose resumption order is ours can be made deterministic under a seed,
   which is a concurrency-testing story Elm has never had; a record carrying `outcome`, `observers`,
   `parent` and `children` (§6.4) is a supervision tree something could render, and `research/16`
   §1.4's complaint about Elm is exactly that `_Scheduler_spawn` has no outcome slot so nothing can
   learn what a spawned task produced. §6.6's honest claim today is only that `update` stays pure
   and `Cmd` stays opaque — Elm's story and no better. Are determinism and observability v1
   deliverables, and does committing to them constrain §7.5's budget or §6.5's primitives?

---

## 12. Alternatives

- **P1, `typed-effects-proposal.md`.** Named sets, mandatory `!`, CPS. Since 2026-09-15 the CPS is
  no longer a disagreement — §7 is P1's lowering — so what remains is the marker and the names, and
  §9.3 is the argument.
- **Do nothing but fix the formatter** (`01-solution-space.md` row A). Zero language cost, and the
  only row the Elm evidence certainly supports. Compatible with this proposal; do it either way.
- **Keep `Task` and the adopted `let x <- e`** (row B). Cheap, and gives up the bind in argument
  position and the single standard library.
- **P1 with the names removed but the marker kept.** The middle position, and the one the review
  argued for before Kotlin's precedent was weighed. If §9.1's accepted risk is judged unacceptable,
  this is where to retreat to: it is this document plus one character at each effectful call.
- **Full algebraic effects with handlers** (row G). Koka's let-generalisation hazard, no source maps
  after nine years, ~1,550 lines of Core passes, and Koka's own JavaScript Task library abandoned
  (`14/koka` §0.3, §4.1, §4.3).

---

## 13. Evidence index

`research/14-direct-style/01-solution-space.md` is the synthesis; per-subject reports cited above
are in the same directory. `research/15-flat-effect-syntax.md` is the cost measurement for
block-shaped versus anywhere-marker rewrites.

`research/16-fibers-and-concurrency.md` is complete as of 2026-09-15 and is the evidence base for
the lowering decision: §1 reads Elm's scheduler line by line, §2 reads Effect-TS 3.22.2, §3 is
original measurement on Node v24.19.0, §4 surveys six other systems, §5 is the primitive list, and
§6 is what it could not settle. §2.4 and §5.6 are the decision; §5.2 and §5.3 are §6's
specification; §2.3, §3.3, §4.7 and §5.5 are §7.5's. An earlier draft of this document described
report 16 as "§1 only and unfinished" and said its §5 "was never written"; that is out of date, and
P1 §6's claim to keep "the vocabulary research 16 says a `Task` runtime must have" now has a
section to be judged against — §5.6 finds it two primitives short, `bracket` and `race`.

`typed-effects-review.md` is the review of P1 this document came out of. Its §0.3 argued for the
native lowering that §7 has now reversed, and its §A4 raised the two costs §7.3 and §7.5 now
budget for — the de-tail-called effectful loop and the loop that never yields.

---

## 14. The inference step, as specified (2026-09-30)

**Status: normative** for the first slice of [`plans/effects-plan.md`](../../plans/effects-plan.md)
§4, the one the owner started on 2026-09-30 (decision 2): the checker infers both bits for every
function, joins them across calls, higher-order parameters, `where` evidence, recursion and
modules, publishes them in the interface and prints them in the dumps. **Nothing reads them yet.**
No diagnostic depends on them, and no emitted byte: every `emit/` golden and every run hash is
unchanged by this section. The `sync` check is the next slice and is not specified here. Where
this section and §3.1 or §4 disagree, this section is the later position; the Effect v4 evidence
it leans on is [`research/43`](research/43-effect-v4-and-the-inferred-bits.md).

### 14.1 The `foreign` keyword

```
Foreign := 'foreign' Rung lower_ident ':' Type WhereClause?
         | 'equatable'? 'foreign' 'type' upper_ident lower_ident*
Rung    := 'pure' | 'impure' | 'suspends'
```

- **The three words are contextual**, like `equatable` (`language.md` §2.4): a word is the rung
  only between `foreign` and the declared name, and stays an ordinary identifier everywhere else,
  so no existing program loses a name.
- **The rung is never omitted** (§3.1). `foreign name : T` is `foreign_effect_missing`, reported
  by the parser at the name; a word other than the three, `foreign pur name : T`, is
  `unknown_foreign_effect` at the word. Both are errors of the declaration, which is otherwise
  read as written, so the rest of the file still checks.
- **`pure` means total and non-throwing** (report 43 §9.3). A `foreign` that can throw or stop the
  program is at least `impure`, because an optimiser that drops an unused pure call must not be
  able to delete a crash. So `Debug.todo` is `impure`, with `Debug.log`.
- **What each existing `foreign` declares.** Everything in `core/` and the platforms is `pure`
  except `Debug.log` and `Debug.todo` (`impure`) and `Html.targetValue` and `Html.targetChecked`
  (`impure`: they read a live DOM node, whose answer can change between two reads). Nothing is
  `suspends` yet; the first `suspends` primitives arrive with the runtime.
- **The formatter** prints the word between `foreign` and the name. The AST needs no field (the
  word is the token before the name); the BIR declaration carries it (`Bir.Decl.rung`), so the
  frontend artifact's format moves.

### 14.2 What carries the bits

**One value on a three-point ladder, `pure ⊏ impure ⊏ suspends`.** §2's two bits enter the
inference only through a rung, and every rung is a point of this ladder (`suspends` implies
`impure`), so joining the two bits independently and joining the ladder compute the same thing.
The checker carries the ladder; the published record, the dumps and the later slices read the two
bits off it.

**A class is the union-find class of a type variable.** Every *function type* carries one — its
own class, so two function types that unify are one class, with no second structure beside the
store — and so does every *application of a nominal type* (§14.5). Records, tuples and type
variables carry none. Two classes are also joined, outside unification, where §14.3 says so.
This is §4.1's "the unifier is unchanged" made literal: nothing is added to `TypeStore` or to
`unify`, and the bits ride beside unification as a graph of `⊑` edges the checker solves after
every group of the module has been checked (§14.4).

### 14.3 The constraints

1. **A call joins its callee into its ambient.** `f a b`, `x.m a`, an operator's method, a type
   dispatch and a markup component each add `callee ⊑ ambient`. The *ambient* is the function
   whose body the call is in: a top-level or `let` definition's own arrow, a lambda's own arrow,
   and, for a top-level value with no parameters, its **evaluation class** — module-local, never
   published, printed by `dump --stage=types`, and what `sync` will read for `main` (decision 5).
   A lambda that is only passed along joins nothing (§4.2 rule 4). A dot-call answered by a
   record's field (`api.log s`, static-dispatch-spike.md §11) calls the field's function, so the
   field joins the dot-call's own arrow, which the call joined into its ambient.
2. **Unification joins.** Two function types that unify are one class, and so are the expansions
   of one alias applied to one argument list when unification merges the two names without
   meeting their expansions (`Unify.throughAlias`).
3. **A reference to a top-level declaration instantiates its summary** (§14.4), own or imported:
   each class of the scheme gets a fresh class at the use, which gets the scheme class's rung and
   `d ⊑ c` for every scheme class `d` that `c` depends on. This is §4.2 rule 7 — top-level
   definitions generalise their bits — and it is what makes `List.map` serve a pure and a
   suspending callback with one definition. It is also §4.4's subsumption where it matters: a pure
   function passed where a suspending one is expected meets a fresh class, never its definition.
4. **A reference to a generalised local `let` binding shares its classes** (§4.2 rule 7): its
   instance and its definition are one class, which is §4.3's extraction hazard, accepted.
5. **An annotation's arrows are inferred, never promised.** The annotation says nothing about
   bits, so the scheme callers instantiate and the reading the body is checked against are one:
   their classes are joined, position by position, the `where` clause's method types included —
   the body calls its evidence through the reading's givens, and callers see the scheme's.
6. **A `foreign`'s rung is its own arrow's.** Its `where` evidence joins its own arrow — evidence
   is handed over to be called during the call, as `core/List.js`'s `eq` loop does. A function
   type in a *positive* position of the signature (one the host makes and hands back: a returned
   function, a callback's own argument) gets the rung too. Every other function type in the
   signature — a beni function handed to the host, which may spawn it, store it or call it later
   — is independent of the call (report 43 §9.6). That is unsound for exactly one kind, a callback
   the host calls synchronously during the call; the `sync` step closes it, since such a callback
   must be `sync` (`plans/browser-decisions.md` W8). For `impure` alone the gap stays open until
   then, and nothing reads `impure` before it. *Amended 2026-09-30, when the release optimiser
   began reading `impure` (§16.5):* the gap is closed at the one `foreign` that calls a callback
   during the call and was declared `pure`, **`Task.andThen`, which is now `foreign impure`**
   (§16.1), so a hand-written `Task.andThen x k` is kept whatever `k` is. Joining every `sync`
   callback into its `foreign`'s own arrow was tried and withdrawn: most such callbacks are called
   later (a page's handler, `Task.start`'s observer), and the join carried a suspending callback's
   rung into the call too, so a `sync_boundary` error gained a second, cascading `must_not_suspend`
   at its caller.
7. **A derived `eq` or `compare` joins its context.** The derived function calls the evidence of
   each context entry, so each entry's method type `⊑` the method type it answers.
8. **Recursion needs nothing.** A binding group's members share their variables until the group is
   generalised, so the group is one graph; declarations that depend on each other only through
   their annotations are solved together to the least fixpoint (§14.4).

### 14.4 Summaries

A top-level declaration's **summary** is what rule 3 instantiates: the classes of its published
scheme — the body and its `where`-clause types, walked in the scheme's canonical order — and, per
class, the rung it reaches and the other classes of the same scheme that reach it. A `foreign`'s
summary is rule 6; every other declaration's is read off the graph of its body.

- **When.** After P5 (checker-v2.md §5), once every group, nested check and derived context has
  added its edges, and before P6 and P8. An own reference recorded during P4 is resolved then,
  through the summary of the declaration it names. Declarations are solved in dependency order,
  the order of their references; a set that depends on itself — two annotated declarations calling
  each other — is iterated until no summary changes.
- **Cost.** Linear in the edges per declaration for the rungs, and one pass per 64 scheme classes
  for the dependencies (a bit set per node), so a scheme of `k` classes costs `⌈k/64⌉` passes over
  its body. The plan's bound (§3 there: check ≤ +10 %, emit ± 0) is measured, not assumed.
- **Determinism.** Everything is indexed by store variable and declaration index, both input
  derived; no order depends on a hash or a thread (CLAUDE.md rule 5).

### 14.5 Nominal types carry one hidden class

A function type written in a **constructor field** of a `type` declaration is fixed at the
declaration; it is not an argument that unification can carry from the value that went in to the
function that comes out. `type Parser a = Parser (String -> Maybe ( a, String ))`, a decoder, a
generator, a capability record behind an opaque type all store functions that way. Report 43 §9.7
weighs three answers: a constant `suspends` saturates the standard library; a constant `pure`
checked at the constructor forbids the capability the type exists to hold; a hidden class per use
of the type is precise. **This step takes the third**, report 43's recommendation:

- **Every application of a nominal type is a class**, `Parser Int` included, like a function type.
- **A constructor joins its fields into its type.** Where a constructor's type is built for a use
  — a construction or a pattern — every function type and every nominal application written in its
  field types (through alias expansions, stopping at the declaration's type parameters) is joined
  with the application the constructor returns. So one class per use of the type, shared by all
  its arrows: `Parser (λs -> …)` and `case p of Parser run -> run s` meet in the class of
  `Parser a` there, and a summary that runs a parser depends on its parser argument's class.
- **Recursive types share it**: `type Stream = Stream (() -> ( Int, Stream ))` names `Stream` in
  its own field, and that application is joined too.
- **A type without a function in its fields** has classes nothing ever joins, which cost the
  checker a variable it already had and the record nothing (§14.6 writes only what carries
  information). A `foreign type` has no constructors: its values are the host's (`Html msg`,
  `Program`), and a function stored in one is the host's to call, which is the `sync` step's.

### 14.6 The interface

Interface format 8 → 9 (`iface_bytes.format_version`): **a scheme gains one word, `effects`**,
the `extra` offset of its effect block, or `no_terms` when every class of the scheme is pure and
independent (so most schemes cost the word and nothing else). The block, in words:

```
class_count
class_count × { rung, dep_count, dep_count × class }
site_count
site_count × { class, root, step_count, step_count × step }
```

- A **rung** is `0` pure, `1` impure, `2` suspends. A class's **deps** are classes of the same
  block, ascending.
- A **site** is one function type or nominal application of the scheme that belongs to a class
  worth writing — one with a rung, a dependency or a dependant. Every store variable of such a
  class gets a site, so a class split across two variables (§14.3 rule 4, §14.5) arrives joined.
- A site is found by a **path**: `root` is `0` for the scheme's body and `k + 1` for its `k`th
  `where`-clause type (quantifiers in scheme order, each quantifier's constraints in the order the
  record writes them), and each **step** is `kind << 28 | index`: `0` parameter `i`, `1` result,
  `2` argument `i` of an application, `3` tuple element `i`, `4` record field `index` (a
  `SymbolIndex`, the field's name), `5` a record's extension, `6` an alias's expansion. The
  reader follows the path through the variables it has just built; an alias's expansion is walked,
  never its argument list.
- **Order.** Sites in a depth-first walk of the scheme, parameters before result, arguments and
  elements in order, fields by name text, the body before the `where` types, each variable once;
  classes in order of their first site. Nothing in the block depends on symbol ids or `--jobs`.
- **The firewall.** The block is hashed with the record (`fast-compiler.md` §8.1), so a
  dependency whose bits change moves its hash and its dependents are re-checked. `entry_bytes`
  6 → 7 embeds the record, and the frontend artifact 8 → 9 carries §14.1's word.

### 14.7 What the dumps print

`dump --stage=interface` and `dump --stage=types` print a class after the type it belongs to;
diagnostics never do, so no message's text moves:

- a function type prints its class after its result: `Request -> Response !suspends`; a nominal
  application, and an alias of a function type or a nominal application, after the name, in
  parentheses where it is an argument: `List (Parser a !e1)`;
- the class is the join of its rung, its own name if another class depends on it, and the names of
  the classes it depends on: `!impure`, `!e1`, `!(impure | e1 | e2)`; `suspends` absorbs the rest,
  and a pure class nothing depends on prints nothing;
- names are `e1`, `e2`, … in order of first print, one namer per declaration shared by its locals;
  a function-typed result is parenthesised when its own arrow prints a class, so
  `Int -> (Int -> Int !e1) !impure` cannot be misread;
- `dump --stage=types` prints a top-level value's evaluation class, when it is not pure, as
  `  -- evaluates: impure` after its scheme.
- A class the printed type does not show — a function field inside a record alias, which prints
  by name — is still named where another class depends on it: `callApi : Api -> Int !e1` says
  the arrow depends on a function inside `Api`.

`List.map : List a, (a -> b !e1) -> List b !e1` is the whole feature on one line.

### 14.8 What this step does not do

- **No `sync`, no diagnostic about a bit, no lowering.** Those are the plan's next slices.
- **Library traversal order** (§5, decision 8) waits for the sequence decision.
- **A schema's generated parse and print** will join their `via` conversions' classes when they are
  generated; today `build` refuses a schema, and a published schema member has no block.
  *Amended 2026-10-02:* [`schema.md`](schema.md) §13 specifies this. `Schema` and `Conversion`
  applications carry two directional classes instead of §14.5's one, and `core/Schema`'s builders
  join through a compiler-known table.
- **Markup's host-called functions** — a handler, a `For` row, a `Show` body, an `Html.map`
  function — are the host's to call and independent of the element, as rule 6's parameters are;
  checker-v2.md §25.6 makes each one `sync` in the next slice. *Done 2026-09-30: §15.2.*

---

## 15. The `sync` step, as specified (2026-09-30)

**Status: normative** for the second slice of [`plans/effects-plan.md`](../../plans/effects-plan.md)
§4, decided by the owner on 2026-09-30 (decision 1: `sync` ships in the first cut). It is the first
reader of §14's bits: the checker refuses a function that may suspend wherever the program demands
one that does not. Still no lowering and no runtime: **no emitted byte and no run hash changes**.
Where this section and §3.2 or §8 disagree, this section is the later position; §3.2's declaration
modifier (`sync f = …`) is not built — the boundaries below are the platform's and the language's,
and a user who wants one of their own passes the function to a `sync` position.

### 15.1 What is refused, and what is not

**"May suspend", never "must"** (report 43 §9.5). A class whose rung is `suspends` — because it
calls something that can park its fiber, even rarely — is refused at a boundary. There is no
run-time check shaped like Effect's `runSync`, which fails only when a fiber *actually* parked and
so passes when a cache hits and crashes when it misses.

A **demand** says of one class, "this must not suspend". It is not a rung and not a type: nothing
is added to `TypeStore` or `unify`, and a `sync` function unifies with an ordinary one (§3.2's
sentence, withdrawn on 2026-09-18 for the type position, is true of the representation: the demand
rides beside unification, as §14.2's classes do). `impure` is never refused; the optimiser that
reads it does not exist yet.

### 15.2 Where a demand comes from

Six places, each a boundary where a beni function is called by something that cannot wait for it
(and a seventh, added 2026-09-30, where a value is computed by something that cannot):

1. **A `sync` parameter of a `foreign`.** A platform writes `sync` before a function type the
   sibling may call synchronously — W8 of [`plans/browser-decisions.md`](../../plans/browser-decisions.md):
   a `foreign` that receives a beni function the sibling may invoke declares it `sync`:

   ```
   TypeAtom := … | 'sync' '(' Type ')'     -- a function type, in a `foreign` value's signature only
   ```

   ```elm
   pub foreign pure onInput : sync (String → msg) → Attribute msg
   pub foreign pure program : { init : model, update : sync (msg, model → model), view : sync (model → Html msg) } → Program
   ```

   The word is **contextual**, like the rung: it is the marker only in a `foreign` value's
   signature, directly before `(`, and an ordinary identifier (a type variable) everywhere else.
   It marks the one function type written inside the parentheses — a record field's, a list
   element's, a parameter's — and nothing nested inside it. It must mark a **function type written
   out**, and one the platform **receives**: an argument position of the declaration's own arrow,
   at any depth inside it, but not a parameter of a parameter (a function the platform itself hands
   back to beni). Anything else is `misplaced_sync`, reported by lowering at the word; the
   declaration is otherwise read without the mark. Like the rung, it is a promise the platform
   author makes about the sibling; `boundary.md` §4's checks do not read the JavaScript to test it.

   *Amended 2026-10-02 (the owner's decision R47-4, `plans/browser-decisions.md`):* **a platform
   package may write `sync` in the signature of any top-level declaration**, not only a `foreign`'s,
   so a runtime piece moved from JavaScript to beni keeps its "must not suspend" (`Browser.program`'s
   `update` and `view`, the effects host). The word is the marker in every top-level annotation, in
   every package, directly before `(`, and an ordinary type variable everywhere else (a `let`
   annotation, a type alias, a type's constructor); what it may mark is unchanged. The one spelling
   this takes from a top-level annotation is a type variable named `sync` written directly before a
   parenthesised type argument (`Pair sync (Int)`, two arguments until now), which is the mark
   there now — rename the variable. In a package that
   may not write `foreign` (`boundary.md` §2) it is `misplaced_sync` at the word, *"only a platform
   package may write `sync`"*, and the declaration is read without it — user code gets the same
   guarantee from any platform function it passes a function to, and a boundary of its own by
   passing to one. A mark on an ordinary declaration is a **demand in the declaration's own graph**,
   on the marked class, attributed to the word: so (§15.3) the summary publishes the class `sync`
   whatever the body does with it — every use, in any module, demands its copy — and a body that
   makes the class suspend itself (by unifying the parameter with a function that suspends) is
   `sync_boundary` at the word, *"`program`'s signature marks this function `sync`"*, with the
   chain. A mark on a `foreign` is read as before.

   *Amended 2026-10-02 (the owner's decision 10 of research 48):* **core is one of the packages
   this paragraph means.** `boundary.md` §2 gives core every privilege a platform package has, and
   lowering already admits the word in both (`core/Schema.beni`'s `mapping` and `recursive` use
   it). The owner took the rule as the way `Ref.update` and `Ref.modify` promise atomicity —
   beni over `Js`, with no `foreign` and no sibling — rather than research 48's two-line `foreign`.
   §17.2 says what the mark promises there and what it does not; nothing in this item, in §15.3–
   §15.5 or in the checker changes.
2. **A `foreign`'s `where` evidence.** §14.3 rule 6 already says the sibling calls its evidence
   during the call; it calls it from JavaScript, synchronously — `core/List.js`'s `eq` loop is the
   case (plan §2.1). So every `where` type of a `foreign` is `sync`, with nothing written.
3. **A markup primitive's function parameters.** `Html.map`'s `a -> b` is called by the page at
   dispatch (checker-v2.md §25.6). Every function type in an argument position of a `markup`
   primitive's signature is `sync`, with nothing written.
4. **Markup's host-called functions** (checker-v2.md §25.6): a handler in its function form, a
   `For`'s or `Show`'s row function and a `keyed` function are called by the page from an event or
   a render, so each is `sync` where it is written.
5. **`main`** (decision 5a): `main : Program` stays, and its evaluation class (§14.3 rule 1) is
   `sync` — `main` is evaluated once, when the program starts, outside any fiber. This is the
   top-level value named `main` in a module of the root package, where a build looks for it
   (`boundary.md` §5); `check` needs no platform to say so.
6. **A well-known `eq` or `compare`** (decision 6a, plan §2.1): a `pub eq` or `pub compare` that is
   a method of a type its module declares — one `==` or `<` would call — is `sync`. `core/List.js`
   calls `eq` and `compare` from JavaScript loops and derived comparisons are single-bodied, so
   `==` and `<` never suspend. A `where a.eq` of an ordinary declaration needs nothing: whatever
   answers it is a type's `eq` (checked here), a derived one (pure, over answers checked here) or a
   primitive.
7. **Every other top-level value** (*added 2026-09-30*, a manager's decision on the owner's
   delegation, reversible; it answers §15.6's open question): a top-level declaration with no
   parameters is evaluated once, when its module is loaded, outside any fiber — exactly as `main`
   is — so its evaluation class is `sync` too, in every package. A value whose body is a lambda
   (`f = λx -> …`) builds a closure and performs nothing, so it is never refused; what its lambda
   calls is checked where the lambda is called. The error is `must_not_suspend` at the value's
   name. *Why:* the alternative, a top-level constant that may perform, needs either a lazy,
   fiber-run initialiser per value (and an order for them) or a program whose `main` is a thunk,
   which decision 5a declined for `main`; neither has a use case today that `λ() -> …` does not
   serve. *Reversal:* drop the demand and give such values a runtime initialiser; nothing that
   checks today stops checking.

### 15.3 How a demand travels

A demand flows **against** §14.3's edges: if `c` must not suspend and `d ⊑ c`, then `d` must not
either. Within a declaration nothing more is needed — the check (§15.4) reads the solved rungs. A
declaration's **summary** carries it to other declarations and modules:

- A class of a summary is **`sync`** when, in its declaration's graph, it reaches a demand and does
  not itself suspend. So `onType f = Page.onInput f` publishes
  `onType : (String -> msg !sync) -> Attribute msg`, and so does anything built on it: `Tea.sandbox`
  inherits `Browser.program`'s demands with nothing written.
- **A class that already suspends publishes no demand.** Its declaration is where the error is
  (§15.4); a use repeating it would say the same thing twice.
- **The declaration's own root class publishes no demand.** A use gets a fresh copy of it whose
  rung is the summary's, so the copy can only come to suspend through the classes it depends on —
  which publish their own demands — or by being unified with some other function, which is that
  other function's class and not this declaration's. (`eq`'s own demand, §15.2 item 6, is checked
  at `eq`.)
- **A use instantiating a summary** (§14.3 rule 3) puts a demand on its copy of every `sync`
  class, attributed to the use: the reference, or the `==`/`<`/dot-call whose method it is.

### 15.4 The check

After §14.4's solve, in a module that has no error so far (a poisoned type says nothing about a
bit): every demand whose class reached `suspends` is an error, **one per class**, at its site. The
errors are reported in region order. A `sync_boundary` whose chain runs through a declaration
refused as `must_not_suspend` is not reported: `[ x ] == [ y ]` on a type whose `eq` suspends is
that `eq`'s error, said once at `eq`. Two codes (§8's table):

| Code | Demands | Region |
|---|---|---|
| `sync_boundary` | §15.2 items 1–4, and every demand a use instantiated (§15.3) | the argument that must not suspend — for a record literal, the field's value — when the use is the callee of a call and the demand is at a parameter of its arrow; otherwise the use itself. Markup: the handler, row function or key function |
| `must_not_suspend` | §15.2 items 5, 6 and 7 | the declaration's name |

**The message names the boundary, then the chain.** The chain is decision 7a's: **one hop per
module**, read off this module's own graph and never an artifact. From the class that must not
suspend it follows the calls that carry `suspends` into it — through own declarations' bodies, and
through the functions a call was handed — to the first value that suspends by itself: an **imported
value**, which suspends because its module's record says so, or an own `foreign suspends`. It names
declarations, not lines — the checker holds the module's instructions, not its line table — so a
chain reads *"`main` calls `load`, and `load` calls `Net.get`, which suspends."* and a function
handed along reads *"`load` calls `List.map` with a function that calls `Net.get`, which suspends."*

```
-- SUSPENDING CALLBACK ---------------------------------------- Main.beni:14:18

This function must not suspend: `Page.onInput` hands it to the platform, which
calls it synchronously.

But it may suspend: it calls `Net.get`, which suspends.

Hint: a function called synchronously cannot wait for anything. Do the work that
suspends before handing this function over, and pass it what that work produced.

14|    Page.onInput (λs → Net.get s)
                    ^
```

### 15.5 The interface

Interface format 9 → 10: **a class word of §14.6's block carries the demand in bit 8** — `rung |
sync << 8`; any other bit set is a malformed record. A `sync` class is worth writing (§14.6) like
one with a rung. `entry_bytes` 7 → 8 embeds the record; the frontend artifact 9 → 10, because a
`type_fn` instruction's `main_token` is now the `sync` word when the type is marked (the BIR's
representation of the mark, which costs no column). The block is hashed with the record, so a
dependency whose demand appears or disappears moves its hash and its dependents are re-checked, and
a dependency whose rung flips re-checks the importer that hands its value to a `sync` position.

**The dumps** print a `sync` class's demand last in its suffix: `(String -> msg !sync)`,
`!(impure | sync)`, `!(e1 | sync)`.

### 15.6 What this step does not do

- **No lowering and no runtime**: a program that passes the check emits what it emitted before.
- **Top-level values other than `main`** are evaluated at import, as `main` is, and are not yet
  demanded: whether a top-level constant may perform is the owner's question, open.
  *Answered 2026-09-30: they are demanded, §15.2 item 7.*
- **The chain across modules** stops at the first import (decision 7a); a full chain needs the
  side artifact decision 7 declined.
- **§3.2's `sync f = …`**, a user-written root, and **`flag_monomorphised`** (§4.3) are not built.

---

## 16. The runtime spike, as specified (2026-09-30)

**Status: normative for the spike** — step 3 of [`plans/effects-plan.md`](../../plans/effects-plan.md)
§4 (its E3 and E4 together), decision 3(c): `spawn`, `join`, `scope` and `bracket`, plus the one
primitive a platform needs to suspend at all. It is the first reader of §14's bits in the backend:
a function that may suspend is emitted in the suspendable form of §7.1, and a fiber runtime this
language owns runs it. Where this section and §6 or §7 disagree, this section is the later
position. The measurements are [`research/44`](research/44-effects-runtime-spike.md).

**What must not move.** A program in which nothing may suspend is emitted exactly as before: every
`emit/` golden and every run hash is unchanged, because every decision below is keyed on a class
that reached `suspends` or on a class that depends on one that may.

### 16.1 The protocol: one sentinel, one pending suspension

The target cannot capture a stack (§1), so a suspension **unwinds** it, the way Koka's JavaScript
backend does (`14/koka` §4.2), and the fast path is a comparison:

- A call that parks returns the runtime's one sentinel, **`$Y`**, and leaves one **pending
  suspension** in the runtime: the registration to perform, and an empty list of continuations.
- A suspendable function that receives `$Y` from a call hands the runtime **the rest of itself** —
  one closure over its live values — to append to that list, and returns `$Y` in turn. The list
  therefore grows innermost first as the stack unwinds, and nothing is allocated unless a call
  really parked.
- When `$Y` reaches the fiber's run loop, the loop moves the list onto the fiber's continuation
  stack and performs the registration. A resumption pops one continuation at a time and calls it
  with the value, **from the run loop**, so a resumed stack is one frame deep however deep the
  suspended one was. A continuation that parks again appends to a fresh pending suspension, and the
  loop splices that list on top of what remains.
- A call whose callee answered with a value — the synchronous fast path of §7.2 — continues in
  place. **`$Y` is never a beni value**: it exists only between a `return` and the comparison that
  consumes it. *(Amended 2026-10-02:* with the kernel in beni (`plans/core-in-beni.md` step 2), the
  sentinel is returned by `core/Task.beni`'s `park` through `Js.suspending` (`boundary.md` §4.2);
  the module's other parking operations are beni over it.)

The code generator writes two operations of core's `Task` module and nothing else:

```elm
pub foreign pure andThen : a, sync (a → b) → b   -- `$Y`? hand `k` over and return `$Y`; else `k a`
pub foreign pure isWaiting : a → Bool              -- `a` is `$Y`
```

Both are `pub` because the emitted code of every module imports them as it imports any value; both
are harmless to call by hand — no beni value is `$Y`, so `andThen x k` is `k x`, and the `sync`
mark keeps a hand-written `k` from suspending under a caller that believes `andThen` pure.
*Amended 2026-09-30: `andThen` is `foreign impure`.* It calls `k` during the call, and §14.3 rule 6
makes a callback independent of the call, so declared `pure` it made `Task.andThen x k` pure however
impure `k` was — which the release optimiser, reading `impure` since that day (§16.5), would have
turned into a dropped call. The emitted code is unchanged: the generator's calls are JavaScript, not
beni, and no rung is read from them. The `sync` mark still does what the sentence above says.

### 16.2 What the checker hands the backend

The checker already knows, per class, the rung it reaches and which classes of its declaration's
scheme reach it (§14.4). The backend needs three answers, one per instruction, each **`no`, `yes`
or `poly`** — `poly` meaning *yes exactly when the enclosing declaration's scheme classes may
suspend*:

- **A call** (`call`, `method_call`, `type_dispatch`): may its callee suspend?
- **A function** (a lambda, a `let` definition, the declaration's own arrow): is it suspendable?
- **A reference to a declaration with two bodies** (below), and a method call's target: which body?

A class answers `yes` when its rung is `suspends`, `poly` when one of the enclosing declaration's
**sensitive** scheme classes reaches it, and `no` otherwise.

**Sensitive classes, and the second body.** A scheme class other than the declaration's own arrow is
*sensitive* when it reaches, in the declaration's graph, a class the lowering reads — a call's
callee, a function's own arrow, a sensitive class of a declaration it references — whose rung is
below `suspends`. A declaration with a sensitive class is emitted **twice** when both are reached
(§7.6's double translation): its **direct** body, under the name it has always had, where every
`poly` answer is `no`; and its **suspendable** body, `<name>$s`, where every `poly` answer is `yes`.
A use takes the `$s` body when the use's copy of some sensitive class reaches `suspends`, and
follows its own enclosing body when a copy is `poly`. `List.map` with a pure callback therefore
calls today's `List$map`, and with a suspending one `List$map$s`; a program that never suspends
reaches no `$s` body, and elimination (`backend.md` §9) writes none.

- **The interface.** A sensitive class is worth writing (§14.6) and its class word carries bit 9:
  `rung | sync << 8 | sensitive << 9` — interface format 10 → 11, `entry_bytes` 8 → 9. The dumps do
  not print it.
- **The table.** The answers ride in the dispatch table as two columns — one row per instruction
  with a `yes` or `poly` answer, or a call whose callee is `impure` whatever it is called with
  (§16.5's `let _ =`), and one byte per declaration (its own arrow's answer, and whether it has
  two bodies) — dispatch sidecar format 6 → 7. *Amended 2026-09-30:* a row's `impure` bit means
  **may be impure** — the callee's rung is `impure` or `suspends`, or its answer is `poly`, or a
  **`sync`** class of the declaration's scheme reaches it. The last is needed because a `sync` class
  cannot suspend, so it is never sensitive and never makes a call `poly`, yet it may be impure at a
  use: `k x` inside a function whose `k` also flows into `Task.andThen`'s callback is impure when
  the caller passes an impure `k`. The walk starts only at `sync` classes, which are few. No
  column or format moves; the release optimiser is the one reader (§16.5).
- **Evidence.** A declaration passed as `where` evidence takes the body the site's callee takes.
  The `where` types of an imported use are among the classes its choice is read off, and a
  declaration that calls its evidence has that evidence's class as a sensitive one, so a callee
  whose evidence may suspend is itself on its `$s` body there. The suspendable body of a function
  called with arguments that never suspend returns what the direct one does, so erring towards
  it costs only speed.
- *Amended 2026-10-02* (`backend.md` §4, *`Js.maySuspend` is the body's answer*; `boundary.md`
  §9.8.11): **the argument of a `Js.maySuspend` call is a class the lowering reads** too, so a
  declaration that asks about its argument has two bodies, and the call's answer rides in its
  instruction's choice-of-body column; and a use whose choice is `yes` keeps only the target's
  `$s` body, where it kept both.

### 16.3 The lowering

**A suspension point is a hoist, like `?`** (`backend.md` §4, *`?` is a test and a `return`*). A
call that may suspend, anywhere but in tail position, is bound to a temporary in the statement list
the expression is being lowered into, and everything that list later holds becomes the call's
continuation. `orderedExprs` already pins every value written before a hoist, so evaluation order
(`language.md` §6) needs nothing new: `f (log a) (fetch b)` evaluates `log a`, then `fetch b`,
then the call.

```js
// fetchSum a b = fetch a + fetch b
const Main$fetchSum = (a$1, b$2) =>
  Task$andThen(Main$fetch(a$1), ($t$1) =>
    Task$andThen(Main$fetch(b$2), ($t$2) => Basics$add($t$1, $t$2)));
```

- **A call in tail position** is returned as it is: `$Y` passes through, and the caller's own
  continuation is the one that runs. A continuation that only returns its argument is not written.
- **A non-tail `case` whose branches may suspend** gets a **join point** (§7.1's mandatory one): the
  rest of the function after the `case` is one named closure, `const $j = ($t) => …`, declared
  before the tree, and every leaf ends in `return $j(value)`. §7's labelled blocks are not join
  points (plan §2.3): a `break` cannot leave a closure. A `&&` or `||` whose right operand may
  suspend is the same `case`.
- **A tail-call loop** (`backend.md` §8) keeps its loop. At a suspension point in the loop's body
  the fast path continues **in place** — `const r = call; if (Task$isWaiting(r)) return
  Task$andThen(r, k);` then the rest of the iteration, `continue` included — and the slow path's
  continuation `k` is the same rest in which every `continue <label>` has become a call of the
  function with its slots, `return F($in$0, …)`: plan §2.2's finding that the loop's state *is* the
  parameter list. The continuation reads the iteration's `const`s, never a slot (§8's rule), since
  a slot is only read by the prologue. A join inside a loop is written into each leaf, not
  closed over, so the fast path never calls back into the function.
- **Tail recursion modulo cons** (`backend.md` §8) is **not applied** in a suspendable body: its
  destination is two locals a resumption would have to carry into a second entry of the loop, which
  the spike does not build. A `::` step there is an ordinary call, and its recursion is a real
  frame on the fast path, as it was before that rewrite. *Superseded 2026-09-30, when `core/List`'s
  `map` and its kin became cons steps and `List$map$s` overflowed at 100 000 elements on the fast
  path:* a suspendable body builds too. The fast path stays in the loop; the slow path's `continue`
  re-enters the function, which builds the rest of the list in a destination of its own, and the
  continuation links that list into `$last` and returns `$root.b` (`backend.md` §8, *What it owes
  the fiber lowering*). No second entry to the loop is needed.
  *Amended 2026-10-01, specified, not built (`backend.md` §4, *Lists are arrays*):* once lists are
  arrays the destination is one builder array, `$root`, and the continuation is
  `($built) => Basics$append($root, $built)` — one copy of the rest per park where linking was
  O(1) (`backend.md` §8, *Tail calls modulo cons, onto an array*). *Built 2026-10-01 as
  `($built) => List$close($root, $built)`, core-private: it pushes the rest onto `$root`, which
  the one-shot continuation owns, instead of concatenating both (`emit/SuspendShapes`).* A loop whose list slot is a
  scalar view (`backend.md` §8, *Scalar views*) re-enters with the slot **materialised**: the
  continuation's `F(…)` passes `List$view($s$<i>, o)`, a list, because the re-entered call computes
  its own base and offset. And `core/List`'s higher-order functions, now loops over indexes that
  thread a core-private builder, suspend exactly as any §8 loop does: the builder is one of the
  slots, and one-shot resumption (§16.1) is what makes sharing it with the continuation sound — a
  multi-shot continuation would have to copy it, as Koka copies a context.
- **A `let` function** a continuation's statements declare is hoisted in front of the suspension
  point when something before the point calls it, so `language.md` §7's "a function may be read
  anywhere" still holds.
- **Anything else that would hold a suspension point in a statement list that falls through** — a
  markup hole whose lowering nests statements, today — is refused at build with `not_implemented`,
  naming the call, rather than emitted wrongly.

### 16.4 The runtime

One file, core's `Task.js`, shared by every platform: nothing in it is Node's or a browser's
except the macrotask it escapes to, which it picks by feature (`setImmediate` where it exists, a
`MessageChannel` otherwise — never `setTimeout(0)`, which a browser clamps). *(Amended
2026-10-02: the runtime is `core/Task.beni`, written in beni over `Js` with no sibling
(`plans/core-in-beni.md` step 2, research 49); what this section says of `Task.js` it says of that
module, record for record. Its records are `Js.Value`s read by name, one literal each; every beni
function it runs is held as a `Js.Value` and called with `Js.apply`, so none of its functions has a
second body; it parks through `Js.suspending` (§16.1).)*

- **A fiber** is a record of `stack` (its continuations), `outcome`, `observers`, `parent`,
  `children`, `finalizers`, `masks`, `interrupted` and the `parked` registration: §6.4's list, with
  the continuation stack §6.4 says comes back under this lowering.
- **The scheduler** is a FIFO of ready fibers drained in a microtask; after **64** resumptions in
  one drain it continues in a macrotask (§7.5, `research/16` §5.5). The budget is counted per
  resumption, never per call, so code that does not suspend is never pre-empted.
- **Interruption** (§6.2): an interrupt delivered to a parked fiber resumes it at once — the
  registration's canceller is called, its later resume is dropped (one-shot), the continuations are
  discarded, the fiber's children are interrupted and awaited, and its finalisers run, last first.
  An interrupt delivered to a running or ready fiber, or to one inside `uninterruptible`, is latched
  and delivered at its next suspension point (report 43 §9.2's rule 2), never at the end of a
  region. Finalisers run uninterruptibly and may suspend (report 43 §9.4).
- **`Exit a = Done a | Cancelled`**: defects are fatal (the owner's A1) — a `foreign` that throws
  ends the program with the host's report and a non-zero exit — so a fiber ends in one of two ways.
- **Outside a fiber** — a top-level value, `main` — nothing can park (§15.2 items 5 and 7), and the
  runtime's impure operations (`spawn`, a finaliser's push) act on a root record.

### 16.5 The API

```elm
-- core/Task.beni
pub type Exit a = Done a | Cancelled
pub foreign type Fiber a
pub foreign type Scope
pub foreign type Resume a

pub foreign suspends callback : sync (Resume a → (⊤ → ⊤)) → a  -- the suspension primitive
pub foreign impure spawn : (⊤ → a) → Fiber a                     -- a child of the current fiber
pub foreign suspends join : Fiber a → a                            -- a cancelled child cancels the joiner
pub foreign suspends wait : Fiber a → Exit a                       -- observes, never propagates (`await` is reserved in JavaScript)
pub foreign suspends cancel : Fiber a → ⊤                         -- interrupts, then waits for cleanup
pub foreign suspends yieldNow : ⊤ → ⊤
pub scope : (Scope → a) → a                                       -- its children are cancelled when it ends
pub foreign impure spawnIn : Scope, (⊤ → a) → Fiber a
pub bracket : (⊤ → r), (r, Exit a → ⊤), (r → a) → a           -- the owner's A3: the release sees the outcome
pub uninterruptible : (⊤ → a) → a
pub foreign impure start : (⊤ → a), sync (Exit a → ⊤) → ⊤     -- a root fiber, for a platform's entry
```

`scope`, `bracket` and `uninterruptible` are beni over first-order kernel operations (report 43
§11 item 9), so their bits are inferred: `bracket` with a pure acquire, use and release is pure and
single-bodied, and its release is pushed onto the fiber's finalisers — run with `Cancelled` if the
fiber is interrupted, called with `Done a` on success, uninterruptible either way. A child spawned
with `spawn` belongs to the current fiber and is interrupted when that fiber ends (Effect's
`forkChild`); one spawned with `spawnIn` belongs to the scope, whose end interrupts it and waits.

A platform writes a suspending primitive in beni over `callback` and an `impure` `foreign` that
registers the host's callback and returns its canceller:

```elm
pub sleep : Int → ⊤
sleep ms =
    Task.callback λresume → startTimer ms resume

foreign impure startTimer : Int, Resume ⊤ → (⊤ → ⊤)
```

The `node` platform gains a module of its own, **`Io`**, so that no file an existing program is
built from changes by a byte: `Io.run : (() -> Program) -> Program`, whose evaluation — `main`'s —
starts a root fiber with `Task.start` (impure, so permitted where suspending is not, §15.2 item 5)
and returns the empty program, the fiber writing its own `Program`'s output and exit code when it
ends, 130 when it is cancelled; `Io.sleep : Int -> ()`; and a promise-backed
`Io.readFile : String -> Result String String`, cancelled through an `AbortSignal`. The `browser`
platform gains nothing yet: a browser program is The Elm Architecture's, whose effects are
commands, and the command type is the browser decisions' (W8–W10), not this spike's. The runtime
itself is platform-free and is exercised in a browser by the measurements (research 44).

*Amended 2026-10-01: the browser.* The owner's W46–W55 are specified in `boundary.md` §9.8: a
browser program's `update` returns `( model, Cmd msg )`, a `Cmd` naming direct-style bodies
`Send msg -> ()` that the platform runs in fibers of the program's root scope, with keys and four
policies written as fiber code over this API; `Sub.listen` runs one fiber per live key. `Task` gains
three `impure` operations for it: `running : Fiber a -> Bool`, and `openRoot : () -> Scope` /
`closeRoot : Scope -> ()`, a scope no function brackets, since a program's outlives every call; a
fiber spawned into a closed root scope is cancelled before it runs. `Time.sleep`, `Http.get` and
`Dom.rendered` are the browser's first suspending primitives, each beni over `callback`.

*Amended 2026-10-01: `Io.readFile`'s error is typed* (`CLAUDE.md` rule 9, `boundary.md` §4.1).
It is `Io.readFile : String -> Result FileError String`, and each failure Node documents for
`fs.promises.readFile` is one constructor of

```elm
pub type FileError
    = NotFound          -- ENOENT: no such file, or a directory on the path is missing
    | PermissionDenied  -- EACCES, EPERM
    | IsADirectory      -- EISDIR
    | NotADirectory     -- ENOTDIR: a component of the path is a file
    | TooManyOpenFiles  -- EMFILE, ENFILE
    | SymlinkLoop       -- ELOOP
    | NameTooLong       -- ENAMETOOLONG
    | InvalidPath       -- ERR_INVALID_ARG_VALUE: the path holds a NUL character
    | TooLarge          -- ERR_FS_FILE_TOO_LARGE, ERR_STRING_TOO_LONG: no string can hold it
```

The names are what a reader of the program would say, not the errno (Rust's `io::ErrorKind` names
the same set the same way). The `AbortError` of the primitive's own `AbortSignal` is not an answer:
the fiber was cancelled and the rejection is dropped. **Any other rejection is re-thrown** from the
handler, so it is a defect, below.

**A defect on Node.** Nothing in `core/Task.js` or a Node primitive catches: a `foreign` that
throws inside a fiber throws out of the scheduler's drain, a microtask, and a primitive's handler that
re-throws rejects a promise no one handles. Node treats both alike under its default
`--unhandled-rejections=throw`: it prints the error and its stack to standard error and exits **1**,
so the program's own output so far stands and nothing after the defect runs. That is the whole crash
path on Node, and the smallest one: a fiber's defect is not delivered to its parent, no scope is
closed and no finaliser runs (W2's teardown, `boundary.md` §9.8.9, is still not built). `run/`
fixtures assert it with a `.crash` golden (`tests/corpus/README.md`). *(Amended 2026-10-02:
the browser's teardown is specified in `boundary.md` §9.8.14 — core's new `Task.shutdown` closes
every root scope and runs every finaliser once, with `Cancelled`, under a deadline — and Node keeps
this paragraph, by that section's (k): an uncaught exception ends the process before a teardown
could run.)*

**`let _ = e` is kept.** `backend.md` §9 item 1 drops a binding nothing reads, initialiser and
all; `let _ = Task.spawn work` is written for the spawn. A `let` whose pattern binds nothing (`_`,
`()`) over a call whose callee is `impure` or worse is kept by the release optimiser (the
`impure` answer of §16.2's table, which is the owner's A5 applied where it is load-bearing). A
*named* binding nothing reads is still dropped, as `run/ReleaseDeadDebug` pins.

*Amended 2026-09-30: **every** `let` whose right-hand side may be impure or may suspend is kept,
named or not, whatever its pattern binds, and wherever in the right-hand side the call sits
(outside a function it builds).* Dropping the named one made a release build skip what its
development build does — `let t = Task.spawnIn s work` with `t` unread started no fiber — which
`language.md` §6 forbids; that section's first bullet and `backend.md` §9 item 1 now carry the rule,
`Debug.log` included, and `run/ReleaseDeadDebug` prints the same lines in both builds.
`run/ReleaseKeepsNamedSpawn` and `run/ReleaseKeepsNamedForeign` are its fixtures.

### 16.6 Fixtures

`run/` programs, red first: sequencing through a suspension (`Debug.log` order across the fast and
the slow path); spawn/join results; a scope ending with children still running; `bracket`'s release
on success, on a cancelled use and when its fiber is cancelled from outside, with its outcome; a
cancelled child joined; a deep non-tail recursion that suspends at every level; a 1 000 000-step
loop through a suspending callback on the fast path; `List.map` with a pure and with a suspending
callback in one program; a join point; a continuation that closes over a loop's iteration. `emit/`
goldens of the lowered shapes: a sequence, a join, a loop and a twin body.

### 16.7 What the spike does not do

- **The other eleven primitives of §6.5** (decision 3: they come with the adoption).
- **The browser-side measurement of §7.5's constant** beyond one fan-out and one timer-latency run.
- **Source maps and logical stack traces** (§7.4): each continuation is a named arrow at its call's
  position, which is the property §7.4 asks the lowering not to foreclose, and no map is written.
- **A per-site choice of body for evidence**, and mutual recursion's stack on the fast path
  (`backend.md` §14 question 5).

### 16.8 As built (2026-09-30)

Built to §16.1–§16.6 with no departure a program can see. The sentinel is `Y`, an object
local to `core/Task.js`; the answers of §16.2 are `src/check/EffectPlan.zig`'s, computed after the
effect solve and handed to the backend in the dispatch sidecar; the lowering is `src/js/Lower.zig`
(hoists, joins, twin bodies) and `src/js/Suspend.zig` (the post-pass that turns each hoist into a
closure or a loop's fast path). The budget sweep of §7.5 was run in Chrome as well as Node, but not
in Firefox. Measurements, against Effect v4 in both hosts, are
[`research/44`](research/44-effects-runtime-spike.md): a suspension point on its fast path costs
2.4 ns against a plain call's 1.7 ns in Node, a real park 125 ns, 10 000 fibers fan out and join in
3.4 ms, and a release program using a scope, a bracket, a spawn, a join and a sleep is 2 114 bytes
brotli against Effect's 26 878 for the same program; the budget of 64 keeps
a page painting through a loop of pure yields. Everything in §16.7 remains undone.

---

## 17. The adoption: Effect parity, as specified (2026-10-02)

**Status: normative** for slices P1–P5 of [`plans/effects-plan.md`](../../plans/effects-plan.md) §8
(the kernel's last pieces, time, the structured combinators, schedules, coordination), for the
logging and tracing of P7–P8, and for the Node rule research 48's finding 3 asks for. It is slice
P0: specification, no code. Where this section and §6.5 disagree, this section wins (§6.5's
amendment of the same day lists what it supersedes); where it and §16 disagree about something §16
built, §16 stands and this section is wrong. The ledger and its evidence are
[`research/48`](research/48-effect-parity-ledger.md); the kernel's port to beni, which several of
the additions here ride on, is [`research/49`](research/49-task-kernel-in-beni.md) and
`plans/core-in-beni.md` step 2 (K1–K5).

**The owner's decisions (2026-10-02).** Research 48 §5's eighteen are taken as recommended, with one
change:

| # | Decided |
|---|---|
| 1 | `core/Duration` and one `Task.sleep : Duration → ()` over the fiber's clock; `Time.Duration` an alias; `Time.sleep` and `Io.sleep` calls of `Task.sleep` (§17.6) |
| 2 | a virtual clock in core — `Clock.virtual`, `adjust`, `run` — in a fiber slot (§17.5, §17.6) |
| 3 | programs may write coordination primitives: `Task.resume` and a public `Ref` (§17.3, §17.4) |
| 4 | `race`/`raceAll` = first to return; `raceOk` = first `Ok`, every `Err` when none (§17.7) |
| 5 | separate fail-fast `…Ok` forms, `forEachOk` and `parOk` (§17.7) |
| 6 | the concurrency bound of `forEach` is a mandatory `Int` (§17.7) |
| 7 | `Schedule` is a closure returning the next schedule, with a pure `step` handed the random draw; v4's names (§17.8) |
| 8 | `Semaphore` is FIFO (§17.9) |
| 9 | `Queue.end`, and `take : Queue a → Maybe a` (§17.9) |
| **10** | **changed by the owner:** `Ref.update` and `Ref.modify` are beni, their function parameter marked `sync` in core's own signature — not a JavaScript `foreign` (§17.2) |
| 11 | `Task.spawnDetached`, a root in the teardown's registry (§17.3) |
| 12 | `Task.uninterruptibleMask` with a `Restore` token (§17.3) |
| 13 | four fixed fiber slots: clock, scheduler, log context, random seed (§17.5) |
| 14 | core `Log` with levels, `annotate`, `span`, `minimum` and platform sinks; the browser's `Log` moves into core (§17.11) |
| 15 | `core/Trace` with `span` now; compiler-emitted spans later (§17.11) |
| 16 | a Node program that can never wake is reported and exits 1 (§17.10) |
| 17 | no `Stream` in v1 |
| 18 | no `startImmediately` knob unless a measurement asks for one (§17.7, *How a combinator starts its children*) |

**Conventions.** Signatures are in today's syntax (`λ`, `→`, `▷`, `…`, `×`; `language.md` §12.7).
Every function is subject first, saturated and uncurried; wherever Effect takes an `Effect` value
this takes a thunk `() → a`, never a started computation (§6.5's second obligation). Names are
Elm's where Elm has the concept, Effect's otherwise, with `wait` for Effect's `await` (a reserved
word of the target, the precedent `Task.wait` set). A nullary method cannot be dot-called, so these
are qualified calls: `Queue.take q`, `Task.join fiber`. Effects are inferred: no signature below
says `suspends`, and the rung each function publishes is what its body makes it. Where the rung
matters — an `impure` that `--release` must keep — it is stated (a `-- impure` comment, or "rung"
in the text), and a slice whose function infers otherwise has a defect. **Citations** are research 48's: `Effect.ts:N` is
`references/effect/packages/effect/src/Effect.ts` line N at `4.0.0-rc.116`, `effect.ts:N` is
`src/internal/effect.ts`, any other `Module.ts:N` is `src/Module.ts`.

**Where the code lives.** Every function here is beni. Those marked **K** change the fiber kernel
and land in `core/Task.beni` after the kernel's port (`plans/core-in-beni.md` K3, as its K5); the
rest is library code over the kernel's public operations and over `Js`, in its own core module.
No new `foreign` and no new sibling is introduced by this section.

### 17.1 What every API here owes

1. **Cancellation is prompt and leaves nothing behind.** Every function that parks does so through
   `Task.callback`, whose canceller **removes the waiter** from whatever list holds it — Effect's
   one mechanism for the same obligation (`Deferred.ts:174-187`, `Semaphore.ts:207-223`) and §6.5's
   third. A cancelled waiter is never handed a value, never counted, and never blocks a waiter
   behind it.
2. **A combinator returns only after the fibers it started have finished their cleanup** (A10).
   Every child a combinator starts lives in a `Task.scope` the combinator opens, so the scope's end
   cancels and awaits whatever is left, and a cancellation of the calling fiber reaches the
   children first (A11).
3. **One fiber runs at a time, and the runtime switches only at a suspension point** (§16.4). This
   is the fact `Ref.update`'s atomicity, every waiter list here and every "in order" below rest on:
   `Task.resume`, `Deferred.complete`, `Queue.offer` and the rest **queue** a woken fiber, never run
   it inside the call that woke it. The one piece of other code an `impure` operation may run
   inside itself is a wait's canceller (§6.2), which is `sync` and belongs to the primitive.
4. **No runtime error, and no catch (`CLAUDE.md` rule 9).** Nothing here calls a host API that
   documents a failure: the clock and timers are `Date.now`, `setTimeout` and `clearTimeout`, the
   log's sinks `console` and `process.stderr.write`. So nothing here catches anything, and a throw
   that reaches any of it is a defect, handled as every defect is (§16.5; `boundary.md` §9.8.14).
   An argument no meaning fits is given the nearest one that keeps the guarantee — each is listed
   where it arises — rather than a crash, as Elm's `List.take -1` is `[]`.
5. **Deterministic.** What a program observes — which waiter is served, which branch wins, the
   order of results, every id — depends on the program and the scheduler's FIFO alone, never on a
   hash, a timestamp or a host's timer resolution; on a virtual clock (§17.6), not on wall time
   either. That is what lets a `run/` fixture print an order (`plans/effects-plan.md` §8, *Timing
   fixtures never sleep for real*).
6. **Code that does not use a slice pays nothing for it**: every `emit/` golden and run hash outside
   the slice is unchanged, and `Reach.zig` keeps no function a program does not reach. The one
   exception is §17.5's slots, four fields on the fiber record, which every program that runs a
   fiber carries and K5 measures.

### 17.2 `sync` in core's own signatures (decision 10)

**What the owner changed.** Research 48 §3 put `Ref.update` and `Ref.modify` behind a two-line
`foreign` because, it said, `sync` could be written only in a `foreign` signature. That was already
out of date when it was written: R47-4 (§15.2 item 1, amended 2026-10-02) lets a package that may
write `foreign` mark `sync` in the signature of **any** top-level declaration, and core is such a
package (`boundary.md` §2: core may do what a platform may). Lowering admits the word when
`options.core or options.platform` (`src/bir/Lower.zig`, `.type_sync`), and `core/Schema.beni`
already marks `mapping`, `injection`, `recursive` and its conversions that way. So the decision
needs **no change to the language or the checker**; it is that rule, used where it was needed:

```elm
--| Replace the value with what `f` makes of it. `f` must not suspend: no other
--| fiber runs between the read and the write, so no update is lost.
pub update : Ref a, sync (a → a) → ⊤
update ref f = set ref (f (get ref))

--| Like `update`, and also return something computed from the old value.
pub modify : Ref a, sync (a → b × a) → b
modify ref f =
    ( result, next ) = f (get ref)
    _ = set ref next
    result
```

**What the mark means there, exactly.** Read as §15.2 item 1's amended paragraph reads it:

- It is a **demand in `update`'s own graph** on the class of `f`'s function type, attributed to the
  word. `update`'s summary therefore publishes that class `sync` whatever the body does with it
  (§15.3), and **every use of `Ref.update`, in any module, demands its copy**: a function that may
  suspend, passed there directly, through a `let`, through a record or through another function's
  parameter, is `sync_boundary` at the argument, with the one-hop chain (§15.4). A wrapper a
  program writes — `bump r = Ref.update r (λn → n + 1)`, or one that takes the function as a
  parameter — publishes the demand on, with nothing written (§15.3, first bullet).
- **A body that made the marked class suspend itself** would be `sync_boundary` at the word in
  `core/Ref.beni`, *"`update`'s signature marks this function `sync`"* — the mark is checked against
  core's own code, not trusted, which is the reason to prefer it to a `foreign` whose sibling no
  check reads.
- **It is not a type.** `sync (a → a)` unifies with any `a → a`; the demand rides beside
  unification (§15.1).

**What it buys, stated as a guarantee.** A function that cannot suspend runs from its first
instruction to its return without any other fiber running (§17.1 item 3), so between `get` and
`set` nothing else can write the cell, and **no update is lost**. Effect states the same of its
`Ref.update` (`Ref.ts:573`, whose body is `self.ref.current = f(self.ref.current)`), where it
holds because an `Effect`'s plain function argument cannot run effects.

**What it does not promise.** `sync` refuses suspension, not impurity. An `f` that is itself
`impure` may write the same `Ref` — an `f` that calls `Ref.set r 0` and then returns `n + 1` —
and then `update`'s own write, which comes last, wins. That is a deterministic consequence of the program's own code,
not a race, and it is what Effect's `update` does with a function that writes the cell; the doc
comment says so. A program that needs an update which itself waits — a read, a request, then the
write — uses `Ref.Locked` (P9), a `Ref` behind a one-permit `Semaphore`, exactly Effect's
`SynchronizedRef` (`SynchronizedRef.ts:307`).

**Which other core signatures carry it.** Every function parameter in this section that core
calls synchronously, during the call: `Ref.update`'s and `modify`'s `f`, a log sink and a trace
exporter (§17.11). A thunk the runtime runs in a fiber — a spawned body, a combinator's branch,
the work `retry` repeats — is left unmarked (report 43 §9.6), because waiting is what a fiber is
for.

**Fixtures.** `check/bad/RefUpdateSuspends` (a function that calls `Task.sleep` handed to
`Ref.update`: `sync_boundary` at the argument, the chain naming `Task.sleep`);
`check/bad/RefUpdateWrapperSuspends` (the same through a program's own wrapper that takes the
function as a parameter: the demand published on, the error at the wrapper's caller);
`check/good/RefUpdateImpure` (an `impure` function, which `Log`s, is accepted).

### 17.3 The kernel's last pieces (P1)

```elm
-- core/Task.beni — additions
pub resume : Resume a, a → ⊤                                   -- K
pub never : ⊤ → a
pub poll : Fiber a → Maybe (Exit a)                             -- K
pub joinAll : List (Fiber a) → List a
pub cancelAll : List (Fiber a) → ⊤
pub spawnDetached : (⊤ → a) → Fiber a                          -- K
pub foreign type Restore                                        -- K: opaque, as `Fiber` is
pub uninterruptibleMask : (Restore → a) → a                     -- K
pub restore : Restore, (⊤ → b) → b                             -- K
pub onExit : (⊤ → a), (Exit a → ⊤) → a
pub defer : Scope, (Exit ⊤ → ⊤) → ⊤                          -- K
```

**`resume r value`** — rung `impure`. Hands `value` to the fiber waiting on `r` (the `Resume` a
`Task.callback` registration was given) and queues it; the waiting fiber runs at a later turn,
never inside `resume` (§17.1 item 3). One-shot: a second `resume` of the same `Resume`, a `resume`
after the waiting fiber was cancelled (its wait is done, §6.2 item 3), and a `resume` during the
teardown's *stopping* phase all do nothing (`boundary.md` §9.8.14 (d) step 6; research 48 §4.1). A
`resume` called while the registration function is still running answers the wait at once, with no
park, as a platform's synchronous callback does today (`Task.callback`'s documentation). It is the
one function that lets a program — not only a platform, through `Js` — finish a wait it started,
and with `Ref` it makes every primitive of §17.4 and §17.9 ordinary beni (research 48 §0 finding
2). **The `Y` sentinel cannot leak through it**: `resume` is `impure`, never `suspends`, and passes
a beni value to a JavaScript function the kernel made; no beni value is the sentinel (§16.1).
Effect: the `resume` its `callback` hands out (`effect.ts:1218`), which a program may hold and call.

**`never ()`** — parks forever: a `callback` whose registration keeps nothing and whose canceller
does nothing. Cancelling the fiber ends the wait like any other. Under Node a program whose every
fiber is in `never` is §17.10's case. Effect: `Effect.never` (`effect.ts:1227`,
`callback(constVoid)`).

**`poll fiber`** — rung `impure`. `Just` the fiber's `Exit` once it has ended, `Nothing` while it
runs, without waiting. A fiber that is cancelled but still running its cleanup is running, as
`Task.running` already says. Effect: `pollUnsafe` on the fiber (`Fiber.ts:86`).

**`joinAll fibers`** — waits for every fiber in the list, then: when any ended `Cancelled`, the
caller is cancelled (as `join` of that fiber would cancel it, A2); otherwise their values, in list
order. It waits for all before deciding, as Effect's `Fiber.joinAll` (`Fiber.ts:330`) awaits every
fiber before it fails; a list that names one fiber twice waits once and gives its value twice.
**`cancelAll fibers`** — interrupts every fiber in the list, in list order, then waits until all
have ended; Effect's `interruptAll` (`effect.ts:934`: interrupt each, then await all). Neither
takes ownership: a fiber that belongs to a scope still belongs to it.

**`spawnDetached work`** — rung `impure`. Starts `work` in a fiber that is **not** a child of the
current one: it is a root, kept in the registry of roots that `boundary.md` §9.8.14 (c) built, so
it outlives the fiber that started it, is not cancelled when that fiber ends, and is reached by
`Task.shutdown` with every other root. It inherits the four slots of §17.5 from the fiber (or the
outside-any-fiber record) that started it, as Effect's `forkDetach` keeps its parent's context
(`Effect.ts:8704`, `effect.ts:5477`). What ends it is its own end, `Task.cancel`, or a shutdown —
on a page the defect teardown, on Node the end of `Io.run` (§17.10). Its children are its own, as
any fiber's are.

**`uninterruptibleMask λrestore → …`** and **`restore token work`.** The mask runs its function
uninterruptibly, exactly as `uninterruptible` does, and hands it a `Restore` token. `restore token
work` runs `work` with the interruptibility that held **where the mask was entered** — so inside a
mask entered from interruptible code, `work` is interruptible, and inside a mask entered from an
uninterruptible region it is not — and puts the mask's back when `work` ends, either way. Effect:
`uninterruptibleMask(restore => …)` (`Effect.ts:7422`, `effect.ts:4550`), whose `restore` is a
function polymorphic in its effect; a token plus a function of it needs no rank-2 type (research 48
§2.2). An interrupt latched while masked is delivered at the next suspension point inside the
restored region, or after the mask at the next suspension point there — beni's rule (§16.4, report
43 §9.2 rule 2), not Effect's moment of unmasking, for the reason `boundary.md` §9.8.14 (a) gives.
**A token used where it cannot mean anything** — after its mask has returned, or by a fiber other
than the one that entered the mask — runs `work` with the interruptibility it already has: it
restores nothing, never unmasks someone else's region, and is not an error. `bracket` is unchanged;
`Semaphore.withPermits` (§17.9) is the first library user, as `Semaphore.ts:289` is Effect's.

**`onExit work finally`** — `bracket` with no resource: runs `work`, then `finally` with `Done
value` or `Cancelled`, uninterruptibly, and returns the value (or goes on being cancelled).
Effect's `onExit` (`Effect.ts:6987`); `ensuring` and `onInterrupt` are a `case` on the `Exit`.
`finally` may suspend, as every finaliser may (§16.4).

**`defer scope finally`** — a finaliser on a **scope** rather than on an expression: it runs when
the scope closes, after the scope's fibers have been cancelled and awaited (A11), **last added
first**, uninterruptibly, told `Done ()` when the scope's function returned and `Cancelled` when
the fiber running it was cancelled. Added to a scope that has already closed, it runs **at once**,
in the calling fiber, told `Cancelled` — Effect's rule for a finaliser added to a closed scope
(report 23 case 4.3; `Scope.ts:348`). A root scope's deferred finalisers run when `closeRoot`
closes it, in one fiber `closeRoot` starts for them (it does not wait, as it waits for nothing
else), and at a teardown with the root's other cleanup.

*Amended 2026-10-02, as K5 built it (`plans/core-in-beni.md` K5's note).* Two points the text above
left open. **What a root's deferred finalisers are told:** `Done ()` when `closeRoot` closes the
root — the root ended as its owner asked, which is a normal close, though its fibers were cancelled
— and `Cancelled` at a teardown, each root's after that root's fibers have ended, the roots in the
order they were listed. **When a scope counts as closed for `defer`:** from the moment it starts to
close — its fibers being cancelled — not only once it has, as Effect marks a scope `Closed` before
running its finalisers (`Scope.ts`); so a finaliser a child's release defers on its own closing
scope runs at once, told `Cancelled`. A `defer` on a root that has never run a fiber lists the root
in the registry, so the teardown finds it.

### 17.4 `Ref` and `Deferred` (P1)

```elm
-- core/Ref.beni
pub opaque type Ref a
pub make : a → Ref a                     -- impure: a new cell
pub get : Ref a → a                      -- impure
pub set : Ref a, a → ⊤                  -- impure
pub update : Ref a, sync (a → a) → ⊤
pub modify : Ref a, sync (a → b × a) → b

-- core/Deferred.beni
pub opaque type Deferred a
pub make : ⊤ → Deferred a               -- impure
pub wait : Deferred a → a                -- parks until completed
pub complete : Deferred a, a → Bool      -- impure: True if this call completed it
pub poll : Deferred a → Maybe a          -- impure
pub isDone : Deferred a → Bool           -- impure
```

**`Ref`** is a mutable cell that any fiber may read and write — Effect's `Ref` (`Ref.ts:173`,
`:200`, `:236`, `:573`, `:461`) and the `Js.Ref` core and the platforms already have, offered to
every program (decision 3; rule 7: nothing withheld). **Every operation must infer `impure`**, the
owner's A5 where it is load-bearing: `make` because two cells made by two calls are two identities
and `--release` may not merge them, `get` because two reads around a `set` are two different values
and `--release` may not memoise one into the other (report 22 §4.1). `Js.ref` is `pure`, so `make`
cannot be a bare `Js.ref`; its body builds its cell with an operation that is `impure`, and the
fixtures below are what proves it. `update` and `modify` are §17.2's. There is no `getAndSet`,
`updateAndGet` and the like: each is a `modify` (`Ref.ts:59-747` has a dozen of them, every one a
`modify` with a fixed function).

**`Deferred`** is a value that is completed once and waited for by any number of fibers — Effect's
`Deferred` (`Deferred.ts:172`, `:174`, `:261`, `:701`, `:749`). **`wait d`** returns the value at once
when `d` is complete, and otherwise parks until it is; a cancelled waiter is removed from the
waiter list by its canceller (`Deferred.ts:179-186` is the model, line for line). **`complete d
value`** completes `d` and returns `True`, then queues every waiter, **in the order they began to
wait**; when `d` was already complete it changes nothing and returns `False` — the first completion
wins (report 23 case 6.1). `fail`, `die` and `interrupt` are not offered: a failure is a `Result`
carried in `a`, a defect is fatal (A1), and a waiter that should stop is cancelled. Both modules
are beni over `Js` and `Task.callback`/`Task.resume`; neither is a kernel change.

**Fixtures.** `run/RefModify` (`update`, `modify`, `set`, `get`; both builds);
`run/RefMakeDistinct` (two `Ref.make 0` in one function are two cells under `--release`);
`run/RefReadsKeptInRelease` (two `Ref.get`s around a `Ref.set` read two values in both builds);
`run/RefUpdateAcrossFibers` (two fibers each `update` the same cell 1 000 times, yielding between
updates: 2 000, every time); `run/DeferredWaitComplete` (three waiters woken in wait order, the
value read by `poll` and `isDone`); `run/DeferredSecondComplete` (`True`, then `False`, the first
value kept); `run/DeferredWaiterCancelled` (a cancelled waiter is removed: the next `complete`
reaches the live waiter and nothing else); `run/TaskShutdown` gains a `Deferred` waiter (research
48 §4.1). For §17.3: `run/ResumeOneShot` (report 23 row 3: the second `resume` does nothing),
`run/ResumeAfterCancel`, `run/CancelReentrant` (row 8), `run/UninterruptibleLatch` (row 11),
`run/UninterruptibleMaskRestore` (row 13: interruptible inside `restore`, not outside it),
`run/RestoreOutsideMask` (a token used after its mask, and by another fiber, restores nothing),
`run/SpawnDetached` (row 24: it still runs after its parent ends, and `Task.shutdown` reaches it),
`run/PollFiber`, `run/JoinAllCancelAll`, `run/OnExitSeesOutcome`, `run/ScopeDeferLifo`,
`run/ScopeDeferAfterClose` (runs at once, told `Cancelled`).

### 17.5 The fiber's four slots (decision 13)

A7 refused a general `Context` and allowed a few fixed per-fiber slots; Effect v4 made the same
move when it replaced `FiberRef` with `Context.Reference` (`Context.ts:1325`; research 48 §2.6).
The fiber record gains **four fields** — the one literal keeps one hidden class (research 49 §2) —
and the outside-any-fiber record the same four:

| Slot | Holds | Default | Read by |
|---|---|---|---|
| **clock** | the real clock, or a `Clock.Virtual` (§17.6) | the real clock | `Task.sleep`, `Clock.now`, `Log`'s time and spans, `Trace`'s times, `retry`/`repeat`'s elapsed time, `Time.now` |
| **scheduler** | the scheduler the fiber's resumptions are queued on | the one scheduler of §16.4 | the kernel. **No API in this section writes it**: it exists so that a deterministic scheduler for tests can be installed per subtree later without adding a field to every fiber (report 21 §8.4: retrofitting one means threading it through every primitive) |
| **log context** | the annotations, the log spans, the minimum level and a sink override (§17.11), and the current trace span | none, none, `Info`, none, none | `Log`, `Trace` |
| **random seed** | `Maybe` a seed of core's `Random.Pcg` | `Nothing` | `retry`/`repeat`'s jitter (§17.8); `Random.withSeed` and the platforms' `Random.value` (P9) |

**Inheritance.** A fiber started by `spawn`, `spawnIn`, `spawnDetached` or a combinator of §17.7
copies its starter's four fields **by reference** at the start — Effect's fork copies the parent's
context the same way. A fiber `Task.start` makes (a platform's root) gets the defaults. Every slot
value is immutable, so sharing one is safe: a change makes a new value.

**Changing a slot** is only ever **scoped to a function**: `Clock.run`, `Log.annotate`, `Log.span`,
`Log.minimum`, `Log.withSink`, `Trace.span`, `Trace.withExporter` and (P9) `Random.withSeed` set
the field on the current fiber (or the outside record), run their function, and put the old value
back when it ends — returned or cancelled, as an `onExit` finaliser would. A fiber started inside
keeps what it copied, after the function has returned. There is no `set` for a slot.

**Cost.** Four fields written per fiber start, one read where a slot is used. K5 measures spawn and
join against research 49 §4.3's figures; a reproducible loss is a wall reported to the owner, never
a reason to drop a slot (`CLAUDE.md` rule 10).

*Amended 2026-10-02 (the owner, after K5's measurement).* **The four slots are one field, `slots`,
holding one immutable record** `{ clock, scheduler, logContext, seed }`, not four fields. K5 built
four and measured them: copying four fields on every start cost the release fan-out of research
49's workloads +3.5 % instructions per spawned fiber, the release cancellation +4.5 %, and every
fiber program 18–90 brotli bytes. One field copied by reference brought fan-out back but still cost
the cancellation about +1 %, and that remainder was the field itself: the same kernel without it
measured equal to the base. So **the field is not in the fiber literal**: `fork` adds it — copying
its starter's — only once some slot has been set anywhere in the program, behind a cell that only
the slot-setting functions write. A program that never sets a slot (every program on `master`)
folds that check away, and its fibers are byte for byte and instruction for instruction what they
were; this is §17.1 item 6 applied to the slots too, and the exception it names is withdrawn. A
program that sets one pays the copy on every start after the first set, and its fibers made before
it carry no field — which reads as every slot at its default, as an undefined record or field does.
Nothing else changes in meaning: inheritance is the copy of that one reference, a scoped change —
`Clock.run`, `Log.annotate` and the rest — sets the field to a **new** record with the one slot
changed and puts the old record back when its function ends, and reading a slot is two loads, paid
only where a slot is read.

### 17.6 Time: `Duration`, `Task.sleep`, `Clock` (P2)

```elm
-- core/Duration.beni
pub opaque type Duration                 -- whole milliseconds, never negative; eq and compare derived
pub zero : Duration
pub millis : Int → Duration
pub seconds : Int → Duration
pub minutes : Int → Duration
pub hours : Int → Duration
pub toMillis : Duration → Int
pub sum : Duration, Duration → Duration
pub times : Duration, Float → Duration

-- core/Task.beni
pub sleep : Duration → ⊤                                        -- K: through the clock slot

-- core/Clock.beni
pub now : ⊤ → Int                       -- impure: epoch milliseconds, through the clock slot
pub opaque type Virtual
pub virtual : Int → Virtual              -- impure: a new clock reading these epoch milliseconds
pub run : Virtual, (⊤ → a) → a
pub adjust : Virtual, Duration → ⊤
```

**`Duration`** is a length of time in **whole milliseconds, never negative**: `millis`, `seconds`,
`minutes` and `hours` clamp a negative count to `zero`, `times` rounds to the nearest millisecond
and clamps at `zero`. Effect's `Duration` (`Duration.ts:691`, `:707`, `:723`, `:788`, `:1408`
`times`, `:1488` `sum`) also carries nanoseconds, infinities and negative lengths
(`Duration.ts:402-419`); beni's timers count milliseconds, nothing here waits forever but
`Task.never`, and a negative wait has no meaning, so the type stays one non-negative `Int` and its
derived `compare` is the order of lengths. The names are Effect's (Elm has no duration); the
browser's `Time.inMillis` stays as `Time`'s own name for `toMillis`.

**`Time.Duration` becomes an alias** of `Duration.Duration`, and `Time.millis`, `Time.seconds` and
`Time.inMillis` stay, as calls of core's (research 48 §4.2), so `Http`'s `timeout : Maybe Duration`
and every page signature are unchanged. `Time.sleep` is `Task.sleep`. `Time.now` reads `Clock.now`,
so a page's code under `Clock.run` sees the virtual time. `Io.sleep` keeps its signature,
`Int → ()`, as `Task.sleep (Duration.millis ms)`, and `Io.js`'s `startTimer` goes.

**`Task.sleep d`** waits `d` on the calling fiber's clock; only that fiber waits. **A duration of
`zero` does not park or yield** — it returns at once, on either clock, so `sleep` never doubles as
`yieldNow` (Effect's test clock does the same, `testing/TestClock.ts:330`). On the real clock it is
one host timer — `setTimeout` through `Js.global`, present in every host beni targets and already
relied on by the teardown's deadline — whose canceller clears it; a wait longer than the timer's
limit, 2³¹ − 1 ms, is a chain of timers, so it never fires early (both hosts clamp a longer delay to
1 ms). On a virtual clock it registers a sleeper (below). Effect: `Effect.sleep` (`Effect.ts:4707`)
over the `Clock` reference (`Clock.ts:51`).

**`Clock.now ()`** is the epoch milliseconds of the calling fiber's clock: `Date.now()` on the real
one, the virtual clock's reading on a virtual one. Effect's `Clock.currentTimeMillis`
(`Clock.ts:265`). A page's or a process's own `Date` is not touched: the browser driver's
host-level clock (`tests/corpus/README.md`) stays what a page that never calls `Clock.run` sees.

**The virtual clock** is a reading and a list of sleepers, ordered by wake time and then by the
order they began to sleep — Effect's `TestClock` (`testing/TestClock.ts:201`, `SleepOrder`).

- **`Clock.virtual t`** makes one, reading `t`, with no sleepers. Two are independent.
- **`Clock.run v work`** runs `work` with the clock slot set to `v` (§17.5), so `work` and every
  fiber it starts — and the fibers those start — sleep on and read `v`.
- **`Clock.adjust v d`** moves `v` forward by `d` (a `zero` changes nothing; time never goes back),
  and returns once everything that moving it woke has run as far as it can:
  1. **settle**: wait until no fiber but the caller is ready to run;
  2. while the earliest sleeper's wake time is at or before the target: set the reading to that
     time, resume **every** sleeper due at exactly that time, in the order they began to sleep, and
     settle again — so a sleeper that the woken code registers, if it is due by the target, is
     woken in the same `adjust`;
  3. set the reading to the target, and return.

  *Settled* means the scheduler's ready queue holds nothing but the caller: every fiber is parked,
  has ended, or is the caller. It does not wait for host events — a real timer, a file read — which
  a test on a virtual clock should not depend on. **Departure from Effect, with the reason.**
  Effect's `adjust` yields **once** after waking each sleeper (`testing/TestClock.ts:361-366`), so a
  woken fiber that yields more than once before it sleeps again can still be running when the next
  sleeper wakes, and the interleaving a test prints depends on how many yields the code under test
  happens to make. Settling makes the order a function of the program alone (§17.1 item 5).
  `adjust` suspends; it is called by the test, outside `Clock.run`, typically from the fiber that
  `spawn`ed the work under test.
- **A sleeper that is cancelled is removed** (§17.1 item 1), so it is never woken, never counted
  and never holds up a settle.
- **A sleeper nobody will ever adjust for** is, under Node, a program that can never wake, and
  §17.10 reports it — Effect logs a warning for a test that sleeps on a `TestClock` it never adjusts
  (`testing/TestClock.ts:338`, `warningStart`); beni ends the program, exit 1.

```elm
-- Three fibers sleeping 30, 10 and 20 ms wake in time order, with no wall time:
main : Program
main = Io.run λ⊤ →
    clock = Clock.virtual 0
    sleeper = λms → λ⊤ → Clock.run clock λ⊤ →
        _ = Task.sleep (Duration.millis ms)
        Debug.log "woke" ms
    fibers = List.map [ 30, 10, 20 ] λms → Task.spawn (sleeper ms)
    _ = Clock.adjust clock (Duration.millis 30)
    _ = Task.joinAll fibers
    Node.print "done"
```

**Fixtures.** `run/VirtualClockSleepOrder` (the program above: 10, 20, 30);
`run/VirtualClockInherited` (a child spawned inside `Clock.run` reads its parent's virtual clock,
and keeps it after `run` returns); `run/VirtualClockNow` (`Clock.now` and `Time`-free arithmetic
before and after an `adjust`); `run/VirtualClockSettles` (a woken fiber that yields three times
before sleeping again finishes those steps before the next sleeper wakes);
`run/VirtualClockSleeperCancelled`; `run/VirtualClockNeverAdjusted` (`.crash`: §17.10's report);
`run/SleepZeroDoesNotYield` (another ready fiber does not run across a `sleep zero`);
`run/DurationArithmetic` (clamping and rounding); page `browser/tea/SleepBeyondTimerLimit` (a
2³¹ + 5 ms sleep on the driver's clock does not fire after `advance 1`, and does after the rest);
every existing `browser/tea/` page unchanged.

*Amended 2026-10-02 (the owner, as P2 was built).* **A `zero` sleep is Effect's, read from its
source, not the rule above.** Effect's real clock answers `sleep(0)` — any delay of at most 0 —
with `yieldNow` (`internal/effect.ts`, `ClockImpl.sleepMillis`: `if (millis <= 0) return
yieldNow`), and its `TestClock` returns at once when the wake time is not after now
(`testing/TestClock.ts`, `sleep`: `if (end <= currentTimestamp) return`). So `Task.sleep zero`
**yields on the real clock** — every other ready fiber runs first, as `yieldNow` — and **returns
at once on a virtual clock**. That keeps `Io.sleep 0`'s meaning: `run/SuspendLoopClosure` relies on
it parking, and it still does. The fixture is `run/SleepZeroYields` in place of
`run/SleepZeroDoesNotYield`. **`Time.every` ticks at least 1 ms apart**: an interval below 1 ms is
1 ms, since with `zero` a subscription's loop would sleep by yielding, forever, and the page would
never go on. Each `retry`/`repeat` step whose schedule answers `zero` (`recurs`, `forever`) yields
in the same way, as Effect's `Schedule` driver sleeps every delay through the clock.

**Where it is built.** `Task.sleep` and the virtual clock's sleepers, `adjust` and its *settle*
are kernel code in `core/Task.beni`, since `sleep` must register a sleeper and *settle* must see
the scheduler's queue. `core/Clock.beni` is a thin module over four `Task` functions whose
parameters or results are `Js.Value` — `currentClock`, `withClock`, `virtualClock`,
`adjustClock` — which a program cannot call usefully, having no way to make a `Js.Value`
(`Debug.logAs`'s precedent). A virtual clock is a record of its reading and its sleepers, kept in
wake-time order and, among equal times, in the order they began to sleep. Setting the clock slot is
the first slot write, so it is what turns on `fork`'s copy of the slots (§17.5's amendment).

### 17.7 Structured combinators (P3)

```elm
-- core/Task.beni
pub par : (⊤ → a), (⊤ → b) → a × b
pub par3 : (⊤ → a), (⊤ → b), (⊤ → c) → a × b × c
pub parOk : (⊤ → Result e a), (⊤ → Result e b) → Result e (a × b)
pub forEach : List a, Int, (a → b) → List b
pub forEachOk : List a, Int, (a → Result e b) → Result e (List b)
pub race : (⊤ → a), (⊤ → a) → a
pub raceAll : (⊤ → a), List (⊤ → a) → a
pub raceOk : List (⊤ → Result e a) → Result (List e) a
pub timeout : Duration, (⊤ → a) → Maybe a
```

All nine are beni over `scope`, `spawnIn`, `wait`, `cancel` and `Deferred` (report 43 §11 item 9).
**What they share:**

- **Children in a private scope.** Each branch, or each call of `forEach`'s function, runs in its
  own child fiber in a `Task.scope` the combinator opens, so §17.1 item 2 holds: the combinator
  returns, or is cancelled, only after every child it started has ended and run its cleanup — a
  loser, a sibling of the first `Err`, a timed-out body. The release a child's `bracket` runs is
  therefore always printed **before** the value the combinator returns (research 48's
  `run/RaceLosersCancelled`).
- **Children see the caller's slots** (§17.5): a `timeout` inside `Clock.run` times out on the
  virtual clock.
- **A child that ends `Cancelled` by itself** — it joined a cancelled fiber, or cancelled itself —
  is treated as `join` treats it (A2): the combinator cancels the other children, waits for them,
  and the calling fiber is cancelled. The exceptions are the races, below, where such a branch
  merely does not win.
- **How a combinator starts its children.** Each child is queued as `spawnIn` queues it, in
  argument or list order, so the first runs first. Effect forks its children with
  `startImmediately` (`effect.ts`'s `iterateConcurrentImpl` calls `forkUnsafe(parentFiber, eff,
  true, true)`), running each inline until it first suspends, and has a fast case for an item that
  is already a value (`effect.ts:4965-4975`); beni's thunks are never values, and a queued start
  costs one microtask drain for the whole batch, not a macrotask per child (decision 18). **P3's
  measurement decides**: if `par` of two thunks that never park, or `forEach` over 10 000 such
  items, is slower than Effect's `all`/`forEach` on the same work, the kernel gains a **core-private**
  immediate start for the combinators — never a public knob — specified then. *This replaces the
  plan's "forks no fiber": a child is a fiber whether or not it parks, because the protocol's
  `resume` is bound to the fiber current when the wait is registered (`Task.js`'s `suspend`), so
  work that may park needs a fiber of its own before it starts.*

**`par a b`, `par3 a b c`** — run the thunks concurrently; their values, in argument order. Effect:
`Effect.all` over a tuple with unbounded concurrency (`Effect.ts:492`).

**`parOk a b`** — as `par`, for thunks that answer a `Result`: the **first `Err` to arrive**
cancels the other branch, waits for its cleanup, and is the answer; `Ok` of both values otherwise.
Effect's `all` is fail-fast on the first failure in the same way and waits for the siblings
(report 23 case 3.2). It is the `Result`-aware half research 48 §0 finding 4 forces: beni's
failures are values, invisible to a combinator that does not look for them.

**`forEach xs bound f`** — calls `f` on every element, **at most `bound` calls in flight at once**,
started in list order, each as the one before it ends; the results in **list order**. The bound is
mandatory (§6.5's first obligation; `List.length xs` is how a program says "all at once"), and **a
bound below 1 is 1**: the guarantee the bound buys is a ceiling, and 1 is the nearest ceiling that
still runs the work (§17.1 item 4; Cats Effect's `require(n >= 1)` would be a crash). An empty list
is `[]` and starts nothing. Effect: `forEach` with `concurrency` (`Effect.ts:777`).
**`forEachOk xs bound f`** — as `forEach`, for a function that answers a `Result`: on the first
`Err`, no further element is started, the calls in flight are cancelled and awaited, and that `Err`
is the answer; `Ok` of every result, in list order, otherwise. `validate` and `partition` are
`forEach` and then `Result.combine`/`Result.partition` (P9).

**`race a b`, `raceAll first rest`** — run every branch concurrently; the **first to return** is the
answer, and every other branch is cancelled and awaited before it is returned (A10). A branch that
ends `Cancelled` by itself never wins; when every branch has, the calling fiber is cancelled.
`raceAll`'s first argument makes the list non-empty by construction. Effect calls this `raceFirst`
/ `raceAllFirst` (`Effect.ts:4904`, `:4807`): with no failure channel, "first to settle" and
"first to succeed" differ only through `Result`, which `raceOk` handles.

**`raceOk thunks`** — Effect's `race` (`Effect.ts:4847`, `effect.ts:1712`): the **first `Ok`** wins,
and the rest are cancelled and awaited; an `Err` does not end the race (report 23 case 3.5). When no
branch answers `Ok`, the answer is `Err` of every branch's error **in argument order** (report 23
row 31), a branch that ended `Cancelled` contributing none. When every branch ended `Cancelled`, the
calling fiber is cancelled. **An empty list is `Err []`** at once — the nearest meaning: no branch,
so no success and no error (§17.1 item 4).

**`timeout d work`** — runs `work` in a child; when it returns before `d` has passed on the caller's
clock, `Just` its value; otherwise the child is cancelled, its cleanup awaited, and the answer is
`Nothing` — **after** the cleanup, so `timeout 50` may take longer than 50 ms, and the doc comment
says so (A10; report 23 case 3.7 measured Effect's at 255 ms). `work` that is `uninterruptible` when
the time passes runs to its next suspension point first: a timeout is a request, not a guarantee
(report 23 case 3.10). **A `d` of `zero` answers `Nothing` without starting `work`**, on either
clock — the one reading that does not depend on how fast a timer fires. A child that ends
`Cancelled` by itself cancels the caller. Effect's `timeoutOption` (`Effect.ts:4604`); P2 chose the
`Maybe` (report 23 §0.2 row 6), and `Maybe.withDefault` is `timeoutOrElse`. HTTP's own per-request
`timeout` (`boundary.md` §9.8.12) stays: it answers `Error.Timeout`, this cancels the fiber, which
aborts the request through its canceller; `Http`'s doc says which to reach for.

**Fixtures** (report 23 rows 25–33 under these names, both builds): `run/ParBoth`,
`run/ParChildCancelled`, `run/ParOkFailCancelsSibling`, `run/ForEachOrder`, `run/ForEachBounded`
(peak concurrency, counted in a `Ref`, never above the bound), `run/ForEachBoundBelowOne`,
`run/ForEachOkFailFast`, `run/RaceLosersCancelled` (the loser's release logs before the winner's
value), `run/RaceAllCancelled`, `run/RaceOkOneSideFails`, `run/RaceOkAllFail`, `run/RaceOkEmpty`,
`run/TimeoutAwaitsCleanup` (on a virtual clock), `run/TimeoutUninterruptible`, `run/TimeoutZero`,
`run/ParentFinalizerOrder` (row 23: children first, A11); pages `browser/tea/TimeoutAroundRequest`
(a request to the faked slow service under `timeout` 500: after `advance 500`, `Nothing`, and
`timers` 0) and `browser/tea/RaceTwoServices`.

*Amended 2026-10-02, as P3 was built: the measurement asked for the immediate start.* With
children queued as `spawnIn` queues them, `bench/fiber`'s combinator group measured `forEach` over
10 000 items that answer at once at 904 ns an item against Effect's 84, `par` of two such thunks at
1 578 ns against 351, and `timeout` around one at 3 163 against 1 047. So, as this section foresaw,
**the combinators start each child at once, core-privately** (`begin` in `core/Task.beni`; no
program can ask for it): the child's work is called inside the combinator's call, with the child as
the current fiber, as Effect's `startImmediately`. Four consequences, all within the contract above:

- **A child that returns without suspending, and leaves no child of its own running, has simply
  ended**: it is never listed in a scope, queued or counted, and the fiber record it ran as is kept
  to run the next child (it is clean: masks and finalisers are symmetric over a call that returns).
  A child that suspends becomes a fiber of the combinator's scope like any other, its continuations
  on its stack, parked where it parked.
- **The combinator's scope is opened only when a child is still running** when its start returns,
  and closed — its fibers cancelled and awaited (§17.1 item 2) — when the combinator's body
  returns. Children that all end at once cost no scope.
- **"Children start queued … the first runs first" becomes "the first runs first, to its first
  suspension, before the second starts"** — the order Effect's own children have. Every fixture
  above prints the same lines either way. `timeout` starts its timer only when the work did not
  answer at once, so work on the fast path costs one fiber record and no host timer.
- **A defect in a child started at once** is the drain's, as any other: the throw goes on to the
  host; first the combinator's own fiber is made current again, so the guard takes it for the
  culprit, and the child is listed in the scope, set on the road to its end and queued, so the
  culprit's cleanup reaches it. Nothing is caught.

The combinators wait on the kernel's observers directly (`firstOf`), not on a `Deferred`: `Deferred`
is a module above `Task`, and the observers are what `Deferred` would have been built over.
Fixture names as built: `run/ForEachBounded` carries `ForEachBoundBelowOne`'s case, `run/RaceOk`
carries `RaceOkOneSideFails`, `RaceOkAllFail` and `RaceOkEmpty`, and `run/TimeoutAwaitsCleanup`
carries `TimeoutZero`.

### 17.8 `Schedule`, `retry`, `repeat` (P4)

```elm
-- core/Schedule.beni
pub opaque type Schedule i                -- a closure: Metadata i → Step i
pub type Step i
    = Continue Duration (Schedule i)
    | Stop
pub type alias Metadata i =
    input : i
    attempt : Int
    elapsed : Duration
    random : Float

pub step : Schedule i, Metadata i → Step i
pub delays : Schedule i, List i → List Duration
pub fromStep : (Metadata i → Step i) → Schedule i

pub recurs : Int → Schedule i
pub spaced : Duration → Schedule i
pub fixed : Duration → Schedule i
pub exponential : Duration, Float → Schedule i
pub fibonacci : Duration → Schedule i
pub forever : Schedule i
pub during : Duration → Schedule i
pub jittered : Schedule i → Schedule i
pub upTo : Schedule i, Duration → Schedule i
pub while : Schedule i, (Metadata i → Bool) → Schedule i
pub max : Schedule i, Schedule i → Schedule i
pub min : Schedule i, Schedule i → Schedule i
pub concat : Schedule i, Schedule i → Schedule i
pub modifyDelay : Schedule i, (Metadata i, Duration → Duration) → Schedule i

-- core/Task.beni
pub retry : Schedule e, (⊤ → Result e a) → Result e a
pub repeat : Schedule a, (⊤ → a) → a
```

**The representation** (decision 7, A4's sub-question). A schedule is a function from one step's
**metadata** to a `Step`: `Stop`, or `Continue` with the delay before the next run and **the
schedule to use for the step after it**. The next schedule carries whatever state the schedule
needs — a counter, the last two Fibonacci delays, the start of a window — in its closure, so
schedules of different state compose without an existential type, and every value is immutable.
Effect's v4 `Schedule` is a step function plus one metadata record (`Schedule.ts:53`, `fromStep`
`:250`, `toStep` `:344`, `InputMetadata` at `Schedule.ts:63-70`); beni keeps its metadata's
`input`, `attempt` and `elapsed`, adds the **random draw** so that a step is a pure function, and
drops the schedule's `Output`, which nothing here reads (`delays` is what a test of a schedule
reads instead).

- **`attempt`** counts from 1: the step after the first run is attempt 1. **`elapsed`** is the time
  from the start of the first run to now, on the running fiber's clock. **`random`** is one draw in
  [0, 1), made by the runner for every step whether or not the schedule reads it.
- **`step s m`** applies a schedule. **`delays s inputs`** runs one purely — each input in turn, as
  if each run took no time (`elapsed` is the sum of the delays so far) and every draw were 0.5 —
  and returns the delays until it stops or the inputs run out. So a schedule is tested with no clock
  at all, and jitter with chosen draws through `step`. `fromStep` writes a schedule of one's own.

**The constructors and combinators** are v4's, by name and by meaning:

| beni | Effect v4 | Delay, and when it stops |
|---|---|---|
| `recurs n` | `recurs` (`Schedule.ts:1169`) | zero; stops after `n` steps (`attempt ≤ n`), so `retry (recurs 2)` runs at most three times; `n < 1` stops at once |
| `spaced d` | `spaced` (`:1198`) | `d` after each run; never stops |
| `fixed d` | `fixed` (`:933`) | to the next multiple of `d` from the first start; a run longer than `d` is followed at once, and missed intervals are not replayed (its doc at `:907-908`) |
| `exponential base factor` | `exponential` (`:850`) | `base × factor^(attempt − 1)`: 100, 200, 400 ms for `exponential (millis 100) 2.0`. Effect's `factor` defaults to 2; beni has no defaults, so it is written |
| `fibonacci one` | `fibonacci` (`:882`) | `one`, `2 × one`, `3 × one`, `5 × one`, … — Effect's sequence exactly (its first step returns `0 + one`) |
| `forever` | `forever` (`:1460`, `spaced(zero)`) | zero; never stops |
| `during d` | `during` (`:750`) | zero; stops once `elapsed > d` |
| `jittered s` | `jittered` (`:1093`) | `s`'s delay × a factor in [0.8, 1.2): `delay × (0.8 × (1 − random) + 1.2 × random)`, Effect's formula (`:1097-1099`) |
| `upTo s d` | `upTo` with `duration` (`:1294`) | `s`'s, while `elapsed ≤ d`. Effect's `times` option is `max s (recurs n)` |
| `while s p` | `while` (`:1323`) | `s`'s, while `p` holds of the step's metadata — `while (exponential …) λm → isTransient m.input` |
| `max a b` | `max` (`:618`) | continues while **both** continue; the **longer** delay |
| `min a b` | `min` (`:783`) | continues while **either** continues; the **shorter** delay of those that do |
| `concat a b` | `concat` (`:500`) | `a` until it stops, then `b` with its own attempts from 1 |
| `modifyDelay s f` | `modifyDelay` (`:1043`) | `f` of the metadata and `s`'s delay |

Effect takes a non-empty array in `max`/`min`; two arguments and nesting say the same. `concat` is
v4's name; `andThen` (research 48 §3) would read as Elm's bind. `cron`, `windowed`, `tap` and the
outputs wait for a use. A module may declare `max`, `min` and `while` beside the prelude's: checked
on this tree, the module's own declaration is what an unqualified name means inside it (so
`Schedule.beni` writes `Basics.max`), and `Schedule.max` is unambiguous outside.

**`retry schedule work`** — runs `work` in the calling fiber; an `Ok` is the answer at once. On an
`Err e`, it steps the schedule with `input = e`: `Continue d next` sleeps `d` on the fiber's clock
and runs `work` again with `next`; `Stop` makes that last `Err` the answer. Effect's `retry`
(`Effect.ts:4090`) retries on a failure and never on a defect or an interrupt (report 23 case 5.2);
beni's is the same by construction — a defect ends the program, and a cancelled `work` never
returns, so it is never retried. `retryOrElse` is a `case` on the answer. **`repeat schedule work`**
— runs `work`, steps the schedule with the value as `input`, sleeps and runs again while it
continues; the last value is the answer (`Effect.ts:7656`; `repeat (recurs 2)` runs three times, as
Effect's doc example at `Schedule.ts:43-47` prints `[1, 2, 3]`).

**The draw.** `retry` and `repeat` draw `random` from the fiber's seed slot (§17.5) when it holds a
seed — stepping core's `Random.Pcg` and storing the next seed back in the slot — and from the
host's `Math.random()` when it does not. A draw that is not a test's concern needs no seed; a test
that prints jittered times sets one (P9's `Random.withSeed`) or tests the schedule with `step`.

**Fixtures.** `run/ScheduleDelays` (pure: `delays` of every row of the table above, `jittered` and
`modifyDelay` through `step` with fixed draws — no clock at all); `run/RetryBackoff` (row 34, on a
virtual clock: attempts at 0, 100, 300, 700 ms, then `Ok`); `run/RetryRecursCount` (`recurs 2`:
three runs, then the last `Err`); `run/RetryNotOnCancel` (row 35: a cancelled attempt is not
retried, and the caller is cancelled); `run/RepeatWhile`; page `browser/tea/RetryRequest` (a faked
service failing twice; `advance` through the backoff).

### 17.9 `Semaphore`, `Queue`, `Latch` (P5)

```elm
-- core/Semaphore.beni
pub opaque type Semaphore
pub make : Int → Semaphore                                   -- impure
pub withPermits : Semaphore, Int, (⊤ → a) → a
pub withPermit : Semaphore, (⊤ → a) → a
pub tryWithPermits : Semaphore, Int, (⊤ → a) → Maybe a
pub available : Semaphore → Int                              -- impure
pub resize : Semaphore, Int → ⊤                             -- impure

-- core/Queue.beni
pub opaque type Queue a
pub bounded : Int → Queue a                                  -- impure, and the three below
pub dropping : Int → Queue a
pub sliding : Int → Queue a
pub unbounded : ⊤ → Queue a
pub offer : Queue a, a → Bool
pub offerAll : Queue a, List a → List a
pub take : Queue a → Maybe a
pub takeAll : Queue a → List a
pub takeN : Queue a, Int → List a
pub poll : Queue a → Maybe a                                 -- impure
pub size : Queue a → Int                                     -- impure
pub end : Queue a → ⊤                                       -- impure

-- core/Latch.beni
pub opaque type Latch
pub make : Bool → Latch                                      -- impure: open or closed
pub open : Latch → ⊤                                        -- impure
pub close : Latch → ⊤                                       -- impure
pub release : Latch → ⊤                                     -- impure
pub wait : Latch → ⊤
pub isOpen : Latch → Bool                                    -- impure
```

Each module is beni over `Ref`, `Task.callback`, `Task.resume` and (for `withPermits`)
`uninterruptibleMask`; each keeps its waiters in a list from which the canceller removes a cancelled
one (§17.1 item 1).

**`Semaphore`** — a count of permits. **`withPermits s n work`** waits until `n` permits can be
taken, takes them, runs `work`, and gives them back when `work` ends, returned or cancelled. The
wait is interruptible and the give-back is guaranteed — Effect's shape exactly
(`Semaphore.ts:287-300`: `uninterruptibleMask`, `restore(wait)`, `onExit` release), written with
§17.3's mask. **FIFO** (decision 8): requests are served in the order they began to wait, and a
request waits while any earlier one still waits, even if there are permits enough for it — so a
request for many is never starved by a stream of requests for few. Effect serves whatever fits,
scanning in registration order, and says a smaller later request may overtake a larger earlier one
(`Semaphore.ts:121-127`); beni takes the fairness for a little throughput under mixed sizes. Two
consequences of FIFO the implementation owes: when the waiter at the head is cancelled, the next
ones are re-examined at once, since the head may have been all that held them; and **a request for
more permits than the semaphore has** would block the whole queue forever, so it is served when
**every** permit is free and takes them all (the nearest meaning, §17.1 item 4 — Effect's would
wait for a `resize`). A request for `n ≤ 0` takes nothing and does not wait. `withPermit` is
`withPermits s 1`. **`tryWithPermits s n work`** runs `work` with the permits only if it can take
them now **without passing anyone who waits**, else answers `Nothing` and runs nothing
(`withPermitsIfAvailable`, `Semaphore.ts:461`, which does not have FIFO to respect). **`resize s
n`** sets the number of permits (a negative `n` is 0), keeping those taken; waiters that now fit are
served, in order (`Semaphore.ts:270`). **`available s`** is the free count. No bare `take` or
`release`: Effect documents them as not interruption-safe, and a permit leaked by a cancellation is
the guarantee this module exists for (report 22 §8).

**`Queue`** — values passed between fibers, first in, first out. **`bounded n`** parks an offer while
the queue holds `n`; **`dropping n`** refuses the new value when full (`offer` answers `False`);
**`sliding n`** drops the oldest to make room; **`unbounded ()`** never fills (`Queue.ts:501`,
`:574`, `:538`, `:612`). A capacity below 1 is 1. **`offer q v`** answers `True` when `v` was
accepted, `False` when a dropping queue dropped it or the queue has ended (`Queue.ts:646`); parked
offers are served in order. **`offerAll q vs`** offers each in turn and answers those **not**
accepted, in order (`Queue.ts:763`). **`take q`** answers the oldest value, parking while the queue
is empty; **`Nothing` once the queue has ended and is empty**, so a consumer's loop ends with `?`
(decision 9). Effect fails a `take` from an ended queue with `Cause.Done` (`Queue.ts:1426`, its
example at `:1415`); beni has no failure channel, and `Maybe` is that `Done`. **`takeAll q`**
parks while empty, then answers every value held — `[]` only once ended and empty
(`Queue.ts:1244`). **`takeN q n`** parks until `n` values are held, or the queue ends, and answers
up to `n` (`Queue.ts:1331`). **`poll q`** answers the oldest value or `Nothing` without waiting
(`:1465`); **`size q`** the count held (`:1736`). **`end q`** ends the queue (`Queue.ts:1005`): later
offers answer `False`, values already held are still taken, takers parked on an empty queue are
answered `Nothing`, and parked offerers are answered `False`, their values not accepted. A second
`end` does nothing. There is no `shutdown` and no `interrupt`: a waiter that should stop is
cancelled, which its scope does (research 48 §5 item 9).

**`Latch`** — a gate fibers wait at (`Latch.ts`). **`wait l`** returns at once when `l` is open and
otherwise parks until it is opened or released (`Latch.ts:87`). **`open`** opens it and wakes every
waiter, in order; later waits pass (`:216`). **`close`** closes it; later waits park (`:312`).
**`release`** wakes every current waiter **without** opening it — a one-shot pulse; later waits
still park (`:260`). **`isOpen`** says which (`:382`). Effect's `open`/`close`/`release` answer
whether they changed anything; nothing here has needed it, and an `impure` `()` is never dropped.
`whenOpen` is `wait` and then the work.

**Fixtures** (report 23 rows 36–38 and the obligations above): `run/QueueTakerCancelled`,
`run/QueueBoundedBackpressure`, `run/QueueEndDrains` (takers see every value, then `Nothing`),
`run/QueueEndWakesOfferers`, `run/QueueSlidingDropping`, `run/QueueTakeAllTakeN`,
`run/SemaphorePermitsNotLeaked` (a holder cancelled inside `withPermits` gives its permit back),
`run/SemaphoreFifo` (a request for 3 is not overtaken by later requests for 1),
`run/SemaphoreHeadCancelled` (cancelling the head lets the requests behind it through),
`run/SemaphoreOversizeRequest`, `run/SemaphoreTryDoesNotJump`, `run/LatchRelease`,
`run/LatchOpenClose`; and the retained-bytes check of research 48 §2.10 (*Leak freedom*) in
`bench/fiber`: 100 000 cancelled waits on each primitive leave the heap where it started.

### 17.10 A program that can never wake (decision 16; A8, Node)

A8 decided "never a silent exit 0". Today an `Io.run` program whose fiber parks on something
nothing will ever answer — a `Task.never`, a `Deferred` no one completes, a virtual clock no one
adjusts, a `Resume` a registration kept and dropped — lets Node's event loop empty and **exits 0
with no output** (research 48 §0 finding 3, verified). The `node` platform's rule:

- **`Io.run` sets the exit code to 1 when it starts the fiber**, and the fiber's end sets it as
  now: the program's code when it ends `Done`, 130 when it ends `Cancelled`. A process that leaves
  by any route the platform did not foresee therefore leaves 1, never 0.
- **When Node's event loop is about to empty** (`process`'s `beforeExit` event, which fires only
  when no timer, socket or other handle can run anything again) **while `Io.run`'s fiber has not
  ended**, the platform writes to standard error

  ```
  beni: the program cannot go on: every fiber is waiting for something that can never happen.
  ```

  followed, in a development build once P6 has landed, by each waiting fiber's logical trace (its
  pending continuations and spawn sites, through the source maps), and the process exits **1**. It
  schedules nothing — work queued in `beforeExit` would make Node run the loop again — and runs no
  finaliser: the program has not failed in a way cleanup can repair, and §9.8.14 (k) already gives
  Node's defects the same ending. Effect keeps the process alive instead, waiting forever (research
  22 D9's reference-counted keep-alive); a program that provably cannot wake should end, loudly.
- **When `Io.run`'s fiber ends, the program ends** — Effect's `runMain` and Go's `main` alike. Its
  output and exit code are written as now, and then `Task.shutdown` (`boundary.md` §9.8.14) stops
  every fiber still running — a `spawnDetached` fiber, a root another library started — with its
  cleanup run under the teardown's deadline, so a detached fiber holding a timer does not keep the
  process alive after the program has answered. The deadline is the `browser` platform's, 1 000 ms.
  A program with no such fiber (every program on `master` today) sees no change.
- **A browser page is not affected**: a page is alive while it is open, and a fiber parked forever
  in it is the page's business, not a program that has ended. The report is Node's.

**Fixtures.** `run/MainParkedForever` (`.crash`: research 48 §6's program, `Task.callback` keeping
its `Resume`; **red today** — it exits 0 with no output); `run/MainParkedOnNever`,
`run/MainParkedOnDeferred` (`.crash`); `run/VirtualClockNeverAdjusted` (§17.6); and
`run/SpawnDetachedEndsWithMain` (a detached fiber sleeping 100 seconds is cancelled when `Io.run`'s
fiber ends, its release prints, and the process exits with the program's code at once).

### 17.11 `Log` and `Trace` (P7, P8)

```elm
-- core/Log.beni (replaces platforms/browser/Log.beni, whose three functions keep their signatures)
pub type Level
    = Trace
    | Debug
    | Info
    | Warn
    | Error
pub trace : String → ⊤                  -- impure, as are debug, info, warn, error and log
pub debug : String → ⊤
pub info : String → ⊤
pub warn : String → ⊤
pub error : String → ⊤
pub log : Level, String → ⊤
pub annotate : String, String, (⊤ → a) → a
pub span : String, (⊤ → a) → a
pub minimum : Level, (⊤ → a) → a
pub type alias Entry =
    level : Level
    message : String
    annotations : List (String × String)     -- outermost first
    spans : List (String × Int)              -- label, milliseconds since it began
    time : Int                               -- epoch milliseconds, from the fiber's clock
pub withSink : sync (Entry → ⊤), (⊤ → a) → a
pub setSink : sync (Entry → ⊤) → ⊤     -- impure; for a platform
pub logfmt : Entry → String

-- core/Trace.beni
pub type alias Span =
    id : Int
    parent : Maybe Int
    name : String
    start : Int
    end : Int
    annotations : List (String × String)
    exit : Exit ⊤
pub span : String, (⊤ → a) → a
pub annotate : String, String → ⊤       -- impure
pub withExporter : sync (Span → ⊤), (⊤ → a) → a
pub toLog : Span → ⊤                    -- impure: an exporter that logs the span at Debug
```

**Levels.** Five, ordered `Trace < Debug < Info < Warn < Error` by the derived `compare` (constructor
order). Effect has `Fatal` too (`LogLevel.ts:67`); a defect ends a beni program, so a level that
says "about to end" says nothing a defect report does not. The constructors live beside the
`Debug` module and a `Trace` module without ambiguity — checked on this tree: a constructor and a
module are different names. `debug` is a release-safe level, unlike `Debug.log`, which `--release`
refuses; the two are different tools.

**A call** builds an `Entry` — its level, the message, the fiber's annotations (outermost first,
an inner `annotate` of the same key replacing the outer), its log spans as `label` and the
milliseconds since that span began, and the time, all read from the calling fiber's slots (§17.5)
and clock — and hands it to the sink, **unless its level is below the fiber's minimum**, in which
case it builds nothing and costs one comparison. The default minimum is `Info`, Effect's
(`internal/references.ts:58`). `annotate key value work`, `span label work` and `minimum level
work` change the log context for `work` and every fiber it starts (§17.5) — Effect's `annotateLogs`
(`Effect.ts:14001`), `withLogSpan` (`:14114`) and `MinimumLogLevel` (`References.ts:349`). Every
call is `impure`, so `--release` never drops one, and an unused `Log` costs nothing.

**Sinks.** The sink is the platform's (decision 14):

- **The default**, core's own, is the `console` method for the level — `console.debug` for `Trace`
  and `Debug`, then `console.info`, `console.warn`, `console.error` — given the message with each
  span appended as ` label=Nms` (Effect's span text, `effect.ts:6539`), and the annotations as a
  second argument, an object of strings, when there are any. With no span and no annotation it is
  exactly today's `Log.info`'s call, so every page that logs prints what it printed. It is what a
  browser program uses.
- **`Log.setSink f`** replaces the default for the whole program; the last call wins, as
  `Task.onDefect`'s does. A platform calls it. **The `node` platform's `Io.run` installs a sink
  that writes one `logfmt` line per entry to standard error** — Effect's `formatLogFmt`
  (`Logger.ts:559`), the quoting `JSON.stringify`'s: `timestamp=<ISO 8601> level=INFO
  message="saving" user=7 save=12ms`. Standard error keeps a program's own output on standard
  output clean, which is the convention every Unix tool keeps and Effect's `LogToStderr` reference
  offers (`Logger.ts:166-176`). A Node program that never calls `Io.run` logs through the default.
- **`Log.withSink f work`** sends `work`'s entries, and those of the fibers it starts, to `f`
  instead — Effect's `Logger.replace`/`Logger.layer` for a subtree (`Logger.ts:1027`). It is how a
  test reads what was logged. `f` is `sync`: a sink is called during the log call (§17.2), and a
  log line that could suspend would make every function that logs suspend.
- **`Log.logfmt entry`** is the Node sink's text, for a sink of one's own.

**`Trace`.** **`Trace.span name work`** runs `work` inside a span: it takes the next span id — a
counter per program, from 1, in the order spans begin, so ids are deterministic — records the
fiber's current span as its parent, makes itself current for `work` and the fibers `work` starts,
and when `work` ends, returned or cancelled, hands the finished `Span` — its times from the fiber's
clock and `exit` saying how it ended — to the exporter in effect. **`Trace.annotate key value`**
adds an annotation to the current span, and does nothing outside one. **No exporter is installed by
default**: a span then records nothing and costs a slot read and two writes. **`withExporter f
work`** installs one for a subtree (Effect's `withTracer`, `Effect.ts:7963`); `f` is `sync`, as a
sink is. **`Trace.toLog`** is a ready exporter that logs each span at `Debug` through the log sink —
the platforms' console exporter, research 48's "the browser and Node ship a console one", written
once in core. Effect: `withSpan` (`Effect.ts:8371`), `annotateCurrentSpan` (`:8089`). The compiler
writing a span around every function that may suspend, at no per-call `Error`, remains the thing to
revisit (decision sheet C4).

**The browser's `Log` moves into core** (research 48 §4.2: module names are global, so the two
cannot both exist): `platforms/browser/Log.beni` is removed and `browser-tea` re-exports core's,
whose `info`, `warn` and `error` have the same signatures and, by the default sink, the same
output. `boundary.md` §9.8.10 (d) records the move.

**Fixtures.** `run/LogLevels` (every level through `withSink`, the default minimum dropping `Trace`
and `Debug`); `run/LogMinimumLevel`; `run/LogAnnotationsInherited` (a spawned child's entries carry
its parent's annotations, and an inner `annotate` replaces an outer one of the same key);
`run/LogSpanLabel` (on a virtual clock, so the span's milliseconds are fixed); the release pass
prints the same entries; a black-box test of the Node sink's line on standard error (a virtual
clock fixes the timestamp); the existing `browser/tea` logging page unchanged;
`run/TraceSpansNested` (parent and child span names, ids and order across fibers);
`run/TraceCancelledSpan` (a span whose work is cancelled is exported with `Cancelled`).

### 17.12 Choices this section made, for the owner to see

Each was taken here so the slices can proceed, and each is reversible until its slice ships.

1. **Decision 10 needs no language change.** R47-4's rule already covered core (`boundary.md` §2,
   `Lower.zig`); §17.2 only states what it means for `Ref`.
2. **Out-of-range arguments get the nearest meaning, never a crash**: a `forEach` bound below 1 is 1;
   a queue capacity below 1 is 1; negative durations and permits are 0; a semaphore request larger
   than the semaphore takes every permit when all are free; `raceOk []` is `Err []`; `timeout zero`
   is `Nothing` without starting the work. The alternative for each is a defect (Cats Effect's
   `require`), which rule 9 argues against for a program's own arguments.
3. **Combinator children start queued**, as `spawnIn`'s do, until P3's measurement says otherwise
   (§17.7); the plan's "forks no fiber" is replaced by "costs one fiber and no extra turn".
4. **`Clock.adjust` settles** between wake times instead of yielding once as Effect's does (§17.6).
5. **`Duration` uses Effect's names** (`sum`, `times`, `toMillis`) where research 48 §3 wrote
   `add`, `scale`; it is whole non-negative milliseconds. `Io.sleep` keeps `Int`.
6. **`Schedule.concat`**, v4's name, where research 48 §3 wrote `andThen`; `while` takes the step's
   metadata, as Effect's does, where research 48 wrote `i → Bool`; `Queue.takeAll`/`takeN`, v4's
   names, where it wrote `takeUpTo`; `upTo` takes only a duration.
7. **The scheduler slot is reserved**: present on every fiber, written by nothing yet (§17.5).
8. **The program ends when `Io.run`'s fiber ends**, with `Task.shutdown` for what is left (§17.10).
9. **Logging**: `Info` is the default minimum; the browser keeps today's console output; Node logs
   `logfmt` to standard error, installed by `Io.run`; spans are exported only when a program installs
   an exporter.
10. **`RateLimiter`**, the one §6.5 primitive not specified here, waits for P9 with `Pool`.

### 17.13 What this section does not do

- **No code.** Every slice still lands red fixtures first, then code, the gates, a read-only review
  and its measurement against Effect v4 in `bench/fiber` (`plans/effects-plan.md` §8).
- **P6** (logical stack traces) is §7.4's and the plan's; §17.10's report gains its traces then.
- **P9's batteries** — `Task.once`, `FiberMap`/`FiberSet`, `PubSub`, `Cache`, `Batch`, `Pool`,
  `RateLimiter`, `Ref.Locked`, `Result.combine`/`partition`, `Random.withSeed` — are specified when
  P9 starts; §17.5's seed slot and §17.8's draw are what `Random.withSeed` will write and read.
- **`Stream`, STM, `Metric`, `Layer`** (P10) are not in v1.
