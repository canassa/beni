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
whether `List` becomes an array-backed sequence. The first slice, inference, is §14.

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

- **Deferral is a thunk.** `\() -> fetchSummary id` is a value of type `() -> Summary` that runs
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
fetchSummary : UserId -> Summary
fetchSummary id =
    let
        user = getUser id
        perms = getPermissions user
    in
    if perms.isAdmin then
        Summary user perms (Just (getAuditLog user))
    else
        Summary user perms Nothing

fetchAll : List UserId -> List User
fetchAll ids =
    List.map ids (\id -> getUser id)
```

Both are ordinary beni. Note that `fetchAll` is the line P1 could not actually write: under P1's
own rule the application is itself effectful and needs a second marker,
`List.map ids (\id -> getUser id!)!`.

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
foreign pure     cons     : a, List a -> List a
foreign impure   now      : () -> Time
foreign impure   random   : Seed -> (Int, Seed)
foreign suspends httpSend : Request -> Response
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
fetchActive : List UserId -> Result HttpError (List User)
fetchActive ids =
    let
        Log.info "fetching"
        users = Result.combine (List.map ids getUser)?
        Log.info ("got " ++ String.fromInt (List.length users))
    in
    List.filter users (\u -> u.isActive)
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
`let x <- f a b` is now `f a b (\x -> rest)` for any callee taking its callback last, so a scope
and a resource bracket sit flat at the top of a block instead of indenting everything below them:

```elm
let
    scope <- Task.scope
    conn  <- Task.bracket (\() -> Db.open url) Db.close
    (user, prefs) = Task.par2 (\() -> getUser id) (\() -> getPrefs id)
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
Task.spawn       : (() -> a) -> Fiber a
Fiber.join       : Fiber a -> Result Cancelled a
Fiber.cancel     : Fiber a -> ()
Task.scope       : (Scope -> a) -> a
Scope.spawn      : Scope, (() -> b) -> Fiber b
Task.bracket     : (() -> r), (r -> ()), (r -> a) -> a
Task.par2        : (() -> a), (() -> b) -> (a, b)
Task.parAll      : Int, List (() -> a) -> List a        -- bounded concurrency
Task.race        : List (() -> a) -> a                  -- losers cancelled, finalisers run
Task.timeout     : Int, (() -> a) -> Maybe a
Task.retry       : Int, (() -> Result x a) -> Result x a
Semaphore.with   : Semaphore, (() -> a) -> a
Queue.take       : Queue a -> a
Queue.put        : Queue a, a -> ()
RateLimiter.with : RateLimiter, (() -> a) -> a
```

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
  type alias Payments = { charge : Cents -> Receipt, refund : ReceiptId -> () }
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
   callback people want is `\id -> getUser id?`, and it is banned. The lambda's own result is
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
it leans on is [`research/39`](research/39-effect-v4-and-the-inferred-bits.md).

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
- **`pure` means total and non-throwing** (report 39 §9.3). A `foreign` that can throw or stop the
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
   — is independent of the call (report 39 §9.6). That is unsound for exactly one kind, a callback
   the host calls synchronously during the call; the `sync` step closes it, since such a callback
   must be `sync` (`plans/browser-decisions.md` W8). For `impure` alone the gap stays open until
   then, and nothing reads `impure` before it.
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
generator, a capability record behind an opaque type all store functions that way. Report 39 §9.7
weighs three answers: a constant `suspends` saturates the standard library; a constant `pure`
checked at the constructor forbids the capability the type exists to hold; a hidden class per use
of the type is precise. **This step takes the third**, report 39's recommendation:

- **Every application of a nominal type is a class**, `Parser Int` included, like a function type.
- **A constructor joins its fields into its type.** Where a constructor's type is built for a use
  — a construction or a pattern — every function type and every nominal application written in its
  field types (through alias expansions, stopping at the declaration's type parameters) is joined
  with the application the constructor returns. So one class per use of the type, shared by all
  its arrows: `Parser (\s -> …)` and `case p of Parser run -> run s` meet in the class of
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
- **Markup's host-called functions** — a handler, a `For` row, a `Show` body, an `Html.map`
  function — are the host's to call and independent of the element, as rule 6's parameters are;
  checker-v2.md §25.6 makes each one `sync` in the next slice.
