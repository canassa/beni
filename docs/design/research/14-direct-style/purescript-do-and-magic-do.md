# PureScript: `do`, `ado`, `Effect`/`Aff`, and MagicDo

**Commissioned by** the landscape's slug `purescript-do-and-magic-do` (Tier 1): "the class-directed
language whose only target is JavaScript, so it pays family A's cost on our runtime and has an
optimiser pass, `MagicDo`, that rewrites `Effect` do-blocks into straight-line JS"
(`00-landscape.md:176-184`). PureScript is the closest existing thing to "Elm with type classes and
do-notation on JavaScript," which makes it the report that answers the counterfactual this whole
programme needs: once a language has do-notation and a compiler that inlines it, what do users
complain about *instead* of the andThen pyramid? Ergonomics only — no benchmarks, allocation
counts, or timings — and read-only: no compiler was run.

**Sources.** Read directly from `github.com/purescript/purescript` at current `master` (accessed
2026-09-14): `CoreImp/Optimizer/MagicDo.hs` (full, 137 lines), `CoreImp/Optimizer.hs` (the pipeline),
`Constants/Libs.hs` (the effect-dictionary tables), `Sugar/DoNotation.hs` and `Sugar/AdoNotation.hs`
(full, the two desugaring passes), `tests/purs/passing/Ado.purs`. From `purescript-effect`:
`src/Effect.purs`/`Effect.js`. From `purescript-contrib/purescript-aff`: `README.md`, `docs/
README.md`, `src/Effect/Aff.js`'s header comment (`Aff`'s constructor set). From
`purescript-prelude`: `src/Control/Bind.purs` (`Bind`, `Discard`). From `purescript/documentation`:
`language/Syntax.md`. Primary design discussion read in full via `gh`: issue
`purescript-deprecated/purescript-eff#25` and `purescript/purescript#3080` (2017, the Eff→Effect
naming/rationale thread, one discussion across two repos), PR `#2889` (2017-05, `ado`'s design
comment), PR `#3373` (2018-06, `QualifiedDo`), PR `#3289` (2018-03, MagicDo for `Effect`), issue
`#3913` (2020-07, a MagicDo evaluation-order hazard), issue `#4307` (an ST-inlining/transformer
unsoundness), issue `#4553` (an open QualifiedDo limitation). Discourse threads via the JSON API:
`cant-everyone-just-lift-effect-and-aff-in-their-libs/1524`,
`can-pure-expression-be-reduced-inlined-and-optimized-at-compile-time/1694`,
`having-trouble-getting-started-with-purescript/1293`. The v0.12.0 release notes via `gh release
view`. `paf31/purescript-book` chapter 8 (GitHub) and its successor at `book.purescript.org/
chapter8.html`. **The session's web-search budget was exhausted before this report started** (a
shared budget across the research programme); every source above was reached by direct fetch, `gh
api`/`gh issue view`/`gh pr view`, or the Discourse JSON API instead — better provenance than search
results, no broad discovery sweep. Where a claim could not be pinned to a primary source, §8 says so.

---

## 0. The three findings, up front

**1. MagicDo is a literal pattern match over the desugared JS-shaped AST for three named
dictionaries, and it goes blind at exactly the boundary where PureScript's own abstraction begins.**
`convert` in `MagicDo.hs:56` only fires on `App (App bind [m]) [Function s1 Nothing [arg] (Block s2
js)]` where `isBind` (`MagicDo.hs:71`) confirms the dictionary is literally `Ref (effectModule,
edBindDict)` — `bindEffect`, `bindEff`, or `bindST` (`Constants/Libs.hs:36-42`), three monomorphic
names the compiler was told to look for. Write the do-block against `MonadEffect m => m a` instead
of concrete `Effect a` and the dictionary becomes a function parameter, not that `Ref` — the match
fails silently, no warning, no flattening. Harry Garrood: *"MonadEffect is just more complicated
than plain Effect, and there's no way around that."* Gary Burgess's gloss: *"plain Effect can be
specially optimized in a way that will never be workable for MonadEffect as it doesn't apply to
monads in general — it basically turns a sequence of Effect binds into plain JS statements"*
([Discourse, 2020-06-30](https://discourse.purescript.org/t/cant-everyone-just-lift-effect-and-aff-in-their-libs/1524)).
The same blindness reaches `for_`/`traverse_`/`sequence_` — the generic combinators everyone
actually loops with — and a sibling pass, `ST` ref inlining, silently produces wrong runtime values
when a ref is threaded through a monad-transformer `lift` (`#4307`, open).

**2. `Effect` and `Aff` sit on opposite sides of the exact trade-off this research programme is
built around, inside one language.** `Effect a` compiles to a bare JS thunk, `() -> a`
(`purescript-effect/src/Effect.js:1-12`): calling it *runs* it, and it cannot be retried, inspected,
or cancelled — it has given up being a value so MagicDo can erase the monadic structure to native
statements. `Aff a` is a tagged union interpreted by a trampoline: `Pure | Throw | Catch | Sync |
Async | Bind | Bracket | Fork | Sequential` (`purescript-aff/src/Effect/Aff.js:6-20`) — every `>>=`
allocates a real `Bind` node, because `Aff` must stay inspectable enough for cancellation,
`bracket`, `Alt`, and forking. MagicDo's `isBind` never matches `Aff`'s dictionary and could not
usefully: flattening `Aff` would delete the structure its runtime needs. One syntax, two runtime
philosophies, decided per-monad by whether the compiler recognises the dictionary by name.

**3. `do`, `ado`, and `QualifiedDo` are one thin syntactic layer resolved by scope before type
inference runs, and PureScript rediscovered "resolve by qualified name" independently, for the one
case its type classes cannot reach.** `desugarDo` (`Sugar/DoNotation.hs:31`) turns `Do (Just m)
els` into calls to `Var (Qualified (Just m) "bind")` — literally `M.bind` if the user wrote `M.do`,
unqualified `bind` in scope otherwise — decided **before** the `Bind` constraint is ever checked.
`QualifiedDo` (PR #3373, merged 2018-12-30) exists because *indexed* monads (`m x y a`, three
parameters) cannot satisfy `Monad m => m a`, so ordinary class-directed `do` cannot type them;
qualifying the keyword sidesteps the class entirely — report 15's "resolved by scope" family
(OCaml `let*`, Gleam `use`), re-derived inside a language that already has type classes, for the
case the class mechanism cannot reach.

---

## 1. The effect model

PureScript's own framing, unchanged in substance since the original book: *"PureScript does not aim
to eliminate side-effects. It aims to represent side-effects in such a way that pure computations
can be distinguished from computations with side-effects in the type system"*
([book.purescript.org/chapter8.html](https://book.purescript.org/chapter8.html)). Purity is a
type-level fact, not a control-flow one: `Effect a` is a zero-argument function that must itself be
*called* to run (§2), so passing it, storing it, or discarding it is safe. There is no `async`/
`await` colouring and no effect-row polymorphism any more (that was `Eff`, removed in 0.12 — §3);
the type constructor is the marker, an ordinary type distinguished from `a` the way `Maybe a` is.

Two effect families exist, not interchangeable without an explicit `lift`:

- **`Effect`** — *native* effects: "the side-effects which distinguish JavaScript expressions from
  idiomatic PureScript expressions" — console I/O, mutation, exceptions, DOM, `Math.random`
  (`book.purescript.org/chapter8.html`). A synchronous JS thunk, not a value a runtime interprets —
  closer to Elm's kernel effect, except user code, not just the core team, can write the FFI thunk.
- **`Aff`** — asynchronous effects, and the one place PureScript's model *is* "effects as values
  interpreted by a runtime": a free-monad-shaped AST (`Pure/Throw/Catch/Sync/Async/Bind/Bracket/
  Fork/Sequential`, `Effect/Aff.js:6-20`) walked by a fiber trampoline, carrying `Bind`, `Monad`,
  `Alt`, `MonadError`, and `Parallel` instances (`docs/README.md`) — where retry (`<|>`,
  `catchError`), cancellation (`Fiber`, `killFiber`), and parallelism (`parallel`/`sequential`, a
  distinct `ParAff` applicative) all live. `ST` is a third, narrower case — a scoped mutable-
  reference monad with its own MagicDo-adjacent optimiser (`inlineST`, §2).

Sequencing two effects is ordinary monadic `bind`/`>>=` (`Control/Bind.purs:56-58`), dispatched by
the same type class that sequences `Maybe` or `Array`. `do`-notation is monad-generic syntax that
happens to be the primary way `Effect`/`Aff` get written; `Effect`'s straight-line codegen is a
codegen-time fact about which dictionary resolved, invisible at the syntax and type-checking level.

---

## 2. The mechanism

### 2.1 `do`: name resolution before type checking

`desugarDo` (`Sugar/DoNotation.hs:20-83`) runs as an AST-to-AST pass, before the type checker ever
sees the module. Each statement becomes, abridged from `Sugar/DoNotation.hs:56-72`:

```haskell
bind ss m = Var ss (Qualified (byMaybeModuleName m) (Ident C.S_bind))
discard ss m = Var ss (Qualified (byMaybeModuleName m) (Ident C.S_discard))
go pos m (DoNotationBind binder val : rest) = case binder of
    NullBinder    -> App (App (bind pos m) val) (Abs (VarBinder ss UnusedIdent) rest')
    VarBinder _ i -> App (App (bind pos m) val) (Abs (VarBinder ss i) rest')
    _             -> -- non-variable binder: bind to a fresh name, then `case` on it
```

A **statement** (no `<-`) desugars through `discard`, not `bind` — `Control.Bind.purs:107-108`
gives `class Discard a where discard :: forall f b. Bind f => f a -> (a -> f b) -> f b`, with
instances *only* for `Unit` and `Proxy a` (`Control/Bind.purs:110-114`). This is the one place the
type system genuinely participates: a statement whose value is not `Unit`-shaped fails to find a
`Discard` instance, which is how the compiler catches "you computed something and threw it away" —
at the cost of an error naming a class (`Discard`) most users have never touched intentionally.
`m :: Maybe ModuleName` in `Do m els` is qualified-do: `Foo.do` resolves `bind`/`discard` to
`Foo.bind`/`Foo.discard` by plain qualified name lookup, **no class involved at desugaring time at
all** — the constraint, if any, only shows up later, if `Foo.bind`'s own signature carries one.

### 2.2 `ado`: the same shape, but `Applicative`, and opt-in for a strictness reason

`desugarAdo` (`Sugar/AdoNotation.hs:23-58`) is structurally the twin of `desugarDo`: it folds the
block into a `map`/`apply` chain (or a single `pure`) instead of nested `bind`s. The design was
argued out in a single PR comment
([#2889](https://github.com/purescript/purescript/pull/2889#issuecomment-301260299), 2017-05,
`rightfold`), which states two departures from GHC's `ApplicativeDo` and why: *"Due to strict
evaluation, it is not preferred to transform any `do` expression into an applicative computation
whenever the types would allow this. Efficiency and termination could suffer due to the lack of
thunking... Therefore this proposal adds a new keyword `ado`"*; and, on why `pure` is not
special-cased: *"This would incur problems with higher-order combinators such as `$`... Instead, we
use the `in` keyword, as suggested by @ElvishJerricco."* Freeman's review caught a real cost early:
*"we can't use `ado` with just an `Apply`ative — we always need a full `Applicative`"* — an
`Apply`-only type cannot use `ado` at all. The rule, quoted verbatim: `ado x <- g; y <- h; in f x y`
desugars to `(\x y -> f x y) <$> g <*> h`. This is the class-directed branch report 15 ruled out for
beni generally (`ado` needs `Applicative`), kept here only because PureScript already pays for type
classes everywhere else.

### 2.3 `QualifiedDo`: scope-resolution grafted onto a class-directed language

PR [#3373](https://github.com/purescript/purescript/pull/3373) (merged 2018-12-30, `pkamenarsky`,
implementing issue `#3245`) lets `do` be written `M.do`, resolving `bind`/`pure` to `M.bind`/
`M.pure` textually. The PR's own example is why it exists — indexed monads:

```purescript
class IxMonad m where
  pure :: forall a x. a -> m x x a
  bind :: forall a b x y z. m x y a -> (a -> m y z b) -> m x z b

test :: forall m a. IxMonad m => m a a String
test = I.do
  a <- I.pure "test"
  b <- I.pure "test"
  I.pure (a <> b)
```

`m x y a` has three parameters and cannot unify with `Monad m => m a`, so ordinary `do` has no
instance to find; qualifying the keyword sidesteps the class entirely, decided by parsing (`Do
(Just m) els`), and costs nothing beyond the name lookup any qualified identifier already pays. It
is not fully general: [#4553](https://github.com/purescript/purescript/issues/4553) (open) is a
live complaint that `M.do` resolves only **one** `bind`/`apply` name per block, so a type indexed
enough to need different bind functions per transition still cannot use the sugar.

### 2.4 MagicDo: the optimiser pass, precisely

MagicDo runs on `CoreImp`, PureScript's post-typechecking, JS-shaped intermediate AST — not on
PureScript source or `CoreFn`. Its header states the target: *"inlines calls to return and bind for
the Eff monad, as well as some of its actions"* (`MagicDo.hs:1-2`). The pipeline
(`CoreImp/Optimizer.hs:34-40`) runs `magicDoEffect`, then `magicDoEff` (legacy), then `magicDoST`,
each to a fixed point, then `inlineST`, then tail-call elimination, then tidy-up — **three separate
calls for three separately-named dictionaries**, not one polymorphic optimisation.

The representation MagicDo exploits: `Effect a` is `() -> a` (`purescript-effect/src/Effect.js`):
`pureE = a => () => a`; `bindE = a => f => () => f(a())()`. Un-optimised, `main = random >>=
logShow` compiles to `bindEffect(random)(function(n){ return logShow(n); })` — every bind allocates
a closure and, when called, another. `convert` (`MagicDo.hs:56-57`) rewrites this shape:

```haskell
convert (App _ (App _ bind [m]) [Function s1 Nothing [arg] (Block s2 js)]) | isBind bind =
  Function s1 (Just fnName) [] $
    Block s2 (VariableIntroduction s2 arg (Just (UnknownEffects, App s2 m [])) : map applyReturns js)
```

into a named IIFE, `function __do(){ var n = random(); return logShow(n)(); }` — one JS function,
sequential `var` statements, no intermediate closures. `isBind` (`MagicDo.hs:71`) is the entire gate:
`(expander -> App _ (Ref C.P_bind) [Ref dict]) | dict == (effectModule, edBindDict)`. `expander`
(`Optimizer.hs:66-73`) substitutes top-level `let`-bound names first, so a dictionary hidden one
level of CSE indirection away still matches — but a dictionary arriving as a **function parameter**
(any polymorphic code, §0.1) never does, since it is not in the top-level list `buildExpander`
walks. `isPure` erases `pure x`/`return x` straight to `x` (skipping the thunk `pureE` would build
and immediately invoke). `isDiscard` handles §2.1's `discard`: PureScript's `Discard Unit` instance
is literally `discard = bind` (`Control/Bind.purs:111`), so after inlining it the pattern matches
the same shape as `isBind`. `untilE`/`whileE`/`forE`/`foreachE` — `Effect`'s native loop primitives
— get a dedicated rewrite (`MagicDo.hs:59-63`) straight to a native JS `while`/`for`.

**Optimiser transparency (Q7).** MagicDo does not participate in dead-code elimination, renaming, or
code splitting (separately implemented); it is a fixed-point rewrite that runs once and produces
ordinary JS AST nodes later passes see through fine. What they cannot see through is the
*unoptimised* form: an `Aff` do-block, or an `Effect` do-block reached only through `MonadEffect`,
remains a real chain of allocations no later pass touches, because none of them know what `Effect`,
`Aff`, or `Bind` mean — only MagicDo does, for its three named dictionaries.

### 2.5 The hard cases

**Loop (Q1).** `Effect` ships primitive loop combinators — `untilE`, `whileE`, `forE`, `foreachE`
(`Effect.purs`) — MagicDo compiles straight to native JS loops (§2.4), so a *non-binding* loop is
flat and native. A bind *inside* a loop over arbitrary data reaches for the generic idiom,
`for_`/`traverse_` from `Data.Foldable`:

```purescript
processAll :: Array User -> Aff Unit
processAll users = for_ users \user -> do
  perms <- getPermissions user
  when perms.isAdmin (log ("admin: " <> user.name))
```

This type-checks for any `Foldable`/`Applicative`, but — per §0.1 — it is **not** MagicDo-eligible
even specialised to `Effect`, because `for_` is compiled once, generically, dispatching through an
`Applicative` parameter: the loop body's bind is real allocation the optimiser never reaches.

**Branch (Q2).** `do` is expression-position, so a bind inside an `if` arm needs a nested `do` —
like Gleam's `use` needing a nested block — but not a new named function or an `andThen` call, just
one more `do` and one indent level:

```purescript
fetchSummary :: Aff Summary
fetchSummary = do
  user  <- getUser
  perms <- getPermissions user
  if perms.isAdmin
    then do
      auditLog <- getAuditLog user
      pure (Summary user perms (Just auditLog))
    else
      pure (Summary user perms Nothing)
```

`user`/`perms` remain usable around the branch since both arms sit inside the outer `do`'s lexical
scope; only bindings made *inside* one arm are scoped to it. `ado` cannot do this at all — every
clause runs via `<*>`/`map`, so there is no branch to put a `<-` inside; independent computations
only, stated outright in the design comment (§2.2) and never lifted (§3).

**Early return (Q3).** No `?`, no `return`/`break` mid-block. Short-circuiting `Aff` uses
`MonadError`'s `try`/`catchError`/`throwError` (native to `Aff`, §1) or `Either`/`ExceptT` layered
on top; `Effect` uses JS exceptions via `Effect.Exception.throw`/`catch`. `Aff`'s `bracket` is the
`try`/`finally` analogue — *"`closeFile` will always be called regardless of exceptions once
`openFile` completes"* (`docs/README.md`) — and composes correctly with cancellation because
`Bracket` is one of `Aff`'s own AST constructors (§1), not a library convention.

**Pattern matching on the bound value.** A non-variable binder (`Just x <- m`) is not left
irrefutable; `desugarDo` binds a fresh identifier and wraps the rest in a single-alternative `Case`
(`Sugar/DoNotation.hs:69-72`): `bind m (\fresh -> case fresh of Just x -> rest)`. There is no
`MonadFail`-style escape hatch — a non-exhaustive binder is caught by the ordinary case-
exhaustiveness checker at that `Case`, not a do-notation-specific rule.

**Mixing two effect types / error propagation.** `Either e a` composes with `Aff` as `Aff (Either e
a)` (checked with `try`) or `ExceptT e Aff a` (`purescript-transformers`) — an `ExceptT`-wrapped
do-block desugars the same way (§2.1), because `ExceptT`'s `Bind` instance is what changes, not the
sugar. `Aff` bakes error handling in — *"you only deal with it when you want to"* (`docs/README.md`)
— `Effect` has none; every `Effect` failure is an uncaught JS exception unless wrapped explicitly.

---

## 3. History and decisions

**`do` and `ado`'s asymmetry was argued in the open, and the strictness reasoning was accepted
without dissent.** §2.2 quotes the `ado`-versus-GHC-`ApplicativeDo` design comment in full; what was
*not* resolved is worth adding: the proposal's own "Open issues" note — *"Instead of making the
syntax opt-in, make `(<*>)` take thunks as arguments"* — was never taken up, and Freeman's review
flagged that `let` inside `ado` only desugars soundly *"if the bound names are only used in the
result, not the intermediate computations"* — a restriction that produced a multi-year bug trail:
`ado double let fails to parse` (#3675), `let-in expressions no longer seem to work in ado blocks`
(#3626), `Docs confused by multiple binds in ado` (#3622), `Rebinding 'apply' in a let binding...
does not produce an error` (#3702) — all closed by targeted fixes, none by redesign.
`tests/purs/passing/Ado.purs` now shows `let` working for both single- and multi-binding cases; it
took years of point patches to get there.

**`QualifiedDo` is the one place PureScript's class-directed design conceded ground to scope
resolution, driven by a concrete type shape classes cannot express.** §2.3's indexed-monad example
is the entire motivating case in the PR description; no `Monad`/multi-param class alternative was
proposed, because none exists — a `Bind`-class instance head fixes the arity of `m`.

**`Eff` → `Effect`, 2017: the row system was removed, not extended, decided in public with an
unusually blunt technical indictment from a named critic.** Issue `#3080` (`paf31`, 2017-09-20) and
`purescript-eff#25` (`natefaubion`, 2017-07-03) record the argument. John A. De Goes (`jdegoes`):

> "Eff's effects are described by strings... and are not semantic... I'd argue the effect system
> that piggybacks on row types has created enormous work for developers and adds layers of
> complexity not found in Elm, for no more actual guarantee of compile time benefits."

Kritzcreek's summary of the resulting consensus: *"Effect rows are useful... but they don't make for
a good default. They are anti-modular in that you need a canonical location for an effect like DOM,
they create boilerplate, and introduce a layer of complexity for beginners/intermediate users that
provides little benefit in their small/medium sized projects."* Naming was its own sub-debate (`IO`,
`Sync`, `IOSync`/`SyncIO`, `Task` all seriously proposed), settled by Phil Freeman: *"it a) doesn't
lead to confusion with the current `Eff`, b) doesn't lead to confusion with Haskell's `IO`, which is
asynchronous [and ours is not]... and c) is a decent name based on what `Eff` actually is."* Michael
Ficarra's gloss on how it was surfaced remains the most-quoted line in this history: the decision
*"was done via emoji-based Twitter poll — the most appropriate medium for language design
discourse."* Algebraic-effect-shaped tracking moved to a library, `purescript-run`, explicitly out
of the default (`kritzcreek`, same thread). **Removed or regretted (Q9), summary:** the row
parameter was deliberately removed and never restored; the name (`Effect`/`Aff`) was kept over
etymological purity for migration cost (`garyb`: *"it definitely seems like the update overhead will
be lower by continuing with `Eff`/`Aff`"*).

**MagicDo shipped as part of the same migration, so `Effect` would not regress relative to `Eff`.**
PR [#3289](https://github.com/purescript/purescript/pull/3289) (`kritzcreek`, 2018-03-24) landed
alongside `Effect` itself, its own description flagging the trade-off: *"This adds another pass over
the JS AST, so if that ends up being too slow I can look into merging these into a single pass, or
checking for an import of Control.Monad.Eff/Control.Monad.Effect before doing the traversal."* `Eff`
kept its own optimisation for backward compatibility (v0.12.0 notes: *"Added the 'magic do'
optimisation for the new simplified Effect type (Control.Monad.Eff is still supported)"*).

**An evaluation-order hazard MagicDo introduces has been open, undecided, since 2020.** Issue
`#3913` (`natefaubion`, 2020-07-25, still open) shows MagicDo, uniquely among PureScript's
optimisations, changes when the *first* statement's arguments evaluate relative to unoptimised code:

> "The magic do optimizations turns [`do { ok (wat "hello"); pure unit }`] into the equivalent of
> `pure unit >>= \_ -> ok (wat "hello") >>= \_ -> pure unit` where the call to `ok`... [is]
> completely deferred. This _only_ happens with Effect code, which makes it difficult to reason
> about... I removed the equivalent of `pure unit` at the end, and suddenly I had a major
> performance regression."

Harry Garrood: *"We probably should specify evaluation order though, right? Especially since the
language is strict?"* — a fix was proposed (hoist the first statement into an explicit `let` before
the `__do` wrapper) but never merged; the issue is still open six years later.

---

## 4. Costs — ergonomic and structural

**What the mechanism forces the user to restructure.** Nothing about `do`/`ado` forces restructuring
beyond ordinary block nesting for branches (§2.5) — the actual restructuring cost in this language is
the *choice* between `Effect`/`Aff` directly (concrete, MagicDo-eligible, worse composability) and
`MonadEffect m`/`MonadAff m` (composable, no MagicDo, worse type inference): *"writing the occasional
`liftAff` or `liftEffect` is not worth the cost of worse type inference and type error messages, and
making type signatures more complicated"* (`hdgarrood`, Discourse, 2020-06-30) — a genuinely
structural fork in how libraries are written, not a stylistic one; `garyb`'s stated practice is to
*"include the operations lifted and unlifted"* (i.e. ship two APIs) rather than pick one.

**What it does to error messages.** `discard`'s narrow instance set (`Unit`, `Proxy` only, §2.1)
converts "you forgot to bind a result" into a type-class-resolution failure naming a class
(`Discard`) that appears nowhere else in ordinary code — fully documented in the Prelude source, but
no practitioner thread names this specific error as a trip-up (§8). The general type-class
error-message complaint is well attested but not do-notation-specific: a beginner's *"Having
Trouble Getting Started With PureScript"* thread (Discourse #1293) lists do-notation misuse and
unclear type annotations among first-week friction, resolved by pointing at `JordanMartinez`'s
external learning repository rather than a documentation fix — the on-ramp cost is handled by
community material, not the compiler or official docs.

**What it does to reasoning about evaluation order.** §3's `#3913` is the sharpest structural cost:
MagicDo makes `Effect` do-blocks the *one* place where argument-evaluation order is not what the
source text suggests, unresolved by design choice rather than oversight — `paf31` concedes the fix
"might be tricky to implement... and keep the current optimization."

**What it demands of the compiler pipeline.** The sugar passes are pure `AST -> AST`, zero unifier
involvement, matching report 15's finding that the scope-resolved family is cheap. MagicDo is a
separate, later, JS-AST fixed-point rewrite (§2.4) run to convergence three times plus a fourth pass,
`inlineST`, whose soundness precondition (`allUsagesAreLocalVars && localVarsDoNotEscape`,
`MagicDo.hs:100-104`) a monad-transformer `lift` can violate: `#4307` (open) shows `execWriterT do
rf <- lift (new false); ...` inlining an `ST` ref as a plain value, producing **silently wrong
runtime output**, not a compile error — the exact failure class beni's own guarantee ("well-typed
code does not throw, and does not compute the wrong answer") exists to exclude, occurring here in a
language that otherwise holds it.

**Diagnostics, locations, and effects-as-values (Q8, Q10).** MagicDo's rewrites reuse source spans
from the matched sub-expressions (every `convert` constructor takes `s1`/`s2` from the original
AST, never synthesising fresh ones), so per-statement source-map fidelity survives by construction
**(inferred from source, not independently run)**. What changes observably is stack shape:
unoptimised, each `>>=` is a nested closure call, one JS frame per bind; MagicDo's `__do` wrapper
collapses a whole `Effect` do-block into one function with sequential statements, one frame total —
no practitioner report of this being felt as better or worse was found (§8). On effects-as-values:
`Effect` explicitly gives it up (an un-run `Effect a` is an opaque callable, and erasing that
structure is MagicDo's whole purpose); `Aff` explicitly keeps it (§0.2, §1), at the cost of never
being MagicDo-eligible.

**Per-bind and per-call cost on JavaScript (Q6).** **Out of scope** by the project owner's rule;
PureScript's own community defers the same question — *"an optimization [for constant-folding] will
probably not be implemented into the compiler in the near future"*, and the compiler has *"no...
robust, general optimization framework other than the handful of specific inlining rules it
currently performs"* (`natefaubion`,
[Discourse](https://discourse.purescript.org/t/can-pure-expression-be-reduced-inlined-and-optimized-at-compile-time/1694))
— cited for context, not as a performance claim of ours.

---

## 5. What users say

Evidence is thinner here than for the mechanism itself — PureScript's community is small, and its
Discourse/GitHub discussion is not deeply searchable without the exhausted web-search budget (§8);
this section draws on direct fetch of known threads, not a corpus sweep, and that thinness is
itself the finding for a niche-but-real production language.

**Praise**, where it appears, is about what the effect split buys, not `do` itself, which nobody
treats as remarkable: `Aff`'s baked-in cancellation/error handling is called out positively in its
own docs (§1), unopposed. **Complaints** cluster on two things, both evidenced above: the
`Effect`/`MonadEffect` ergonomics fork (§4 — a maintainer-level thread, `hdgarrood` and `garyb` both
against "just lift everywhere") and beginner friction with do-notation misuse and type errors
generally (Discourse #1293), not with `do`'s syntax specifically. **Wishes**: the still-open `#4553`
(multiple bind functions in one `QualifiedDo`/`ado` block) and the never-implemented "make `(<*>)`
take thunks" alternative to `ado`'s opt-in keyword (§3) — both live, low-noise wishes for the sugar
to reach further, not to be removed. **Maintainers versus evaluators**: every substantive thread
found is maintainer-to-maintainer (`hdgarrood`, `garyb`, `natefaubion`, `paf31`, `kritzcreek`) except
Discourse #1293, an evaluator's first week. **Count, honestly**: none of the reachable threads is a
"top-N of top-M" ranked complaint — PureScript's practitioners mostly do not litigate `do`/`ado` in
public; the open GitHub issues are the record instead, and were used as such throughout §3–§4.

---

## 6. What it would take to do this in beni

**Given beni has no type classes and no HKT (settled, `fast-compiler.md` §3.1),** the class-directed
half of what PureScript does — `Bind`/`Discard`/`Applicative`-dispatched `do`/`ado` — is not
available, confirming report 15's conclusion rather than adding to it. What is newly relevant:

- **QualifiedDo's lesson generalises beyond classes.** PureScript needed scope-resolution only for
  the one shape (indexed monads) its classes could not reach; beni has no classes at all, so every
  bind-like construct is in that position by default — a fourth independent convergence (after
  OCaml, Gleam, Koka, per report 15) on "resolve by name in scope."
- **MagicDo argues for building the Effect/`Task`-flattening pass ourselves, not hoping a generic
  optimiser finds it.** PureScript's optimiser had to be told, by name, about three dictionaries; a
  beni-shaped pass has an *easier* target, since without type classes there is no `MonadEffect`-style
  abstraction for a bind to hide behind (§0.1's blind spot is a consequence of overloading beni
  lacks). What carries over is `#4307`'s failure mode: any pass matching "does this AST shape still
  mean what I think" needs an explicit precondition check and a plan for what silently invalidates
  it later.
- **The evaluation-order hazard (§3, #3913) warns against any pass that special-cases one effect
  type for flattening.** If beni's desugarer emits `bind` uniformly across `Result`, `Maybe`, and
  `Task`, and only a later pass flattens `Task`, that pass must not change *when* arguments are
  evaluated relative to the unflattened semantics — the fix PureScript's own thread converged on but
  never shipped (hoist the first statement into an explicit binding first) is free for beni to adopt
  from day one, as a desugarer rule rather than a patch.
- **`ado`'s applicative-only restriction is not a shape beni needs to import.** Without polymorphic
  `Applicative`, a beni equivalent would be monomorphic to `Task`/`Result` from the start, removing
  the exact friction (`Apply` without `pure`, §2.2) PureScript's own review caught.
- **In the designers' own words**: `jdegoes`'s indictment of `Eff`'s row system — *"created enormous
  work for developers... for no more actual guarantee of compile time benefits"* — warns against a
  fine-grained, phantom-typed effect-tracking default, the same direction report 15 already ruled
  out on inference-cost grounds, now from the team that built and discarded it, on ergonomic
  grounds. `kritzcreek`'s hedge on shipping MagicDo — gate an expensive pass on a cheap pre-check
  (an import check) before paying for a full traversal — is a concrete, transferable note.

---

## 7. Ranked summary

1. MagicDo matches three named dictionaries (`bindEffect`/`bindEff`/`bindST`) by literal `Ref`
   equality and does not see through `MonadEffect`, generic `Foldable`/`Applicative` combinators
   (`for_`, `traverse_`), or monad transformers. (documented — `MagicDo.hs`, Discourse, `#4307`)
2. `Effect` (a bare JS thunk) and `Aff` (a tagged-union AST run by a fiber trampoline) are the two
   poles of "native side-effect" versus "effect as an interpreted value" inside one language, and
   MagicDo applies only to the first. (documented — `Effect.js`, `Aff.js`)
3. `do`, `ado`, and `QualifiedDo` all desugar in a pre-typechecking AST pass with zero unifier
   involvement; the class constraint is discovered afterward, not required by the sugar itself.
   (documented — `Sugar/DoNotation.hs`, `Sugar/AdoNotation.hs`)
4. `QualifiedDo` exists because indexed monads cannot satisfy `Monad m => m a` — PureScript's own
   "resolve by scope" case, converging independently with report 15's OCaml/Gleam/Koka finding.
   (documented — PR #3373)
5. The `Eff`→`Effect` row removal (2017–2018) was argued in public on ergonomic grounds ("anti-
   modular," "created boilerplate") and settled by a famously casual poll; the name was kept for
   migration cost over etymology. (documented — `#3080`, `purescript-eff#25`)
6. A MagicDo evaluation-order hazard, unique to `Effect` among all PureScript monads, has been open
   and unresolved since 2020. (documented — `#3913`)
7. `ado`'s `let`-inside-block restriction produced a multi-year trail of parser/desugar bugs before
   settling, not a redesign. (documented — issues #3622, #3626, #3675, #3679, #3702, #3754, #3758)
8. Library authors face a real fork between concrete `Effect`/`Aff` (MagicDo-eligible, simpler
   errors) and `MonadEffect`/`MonadAff` (composable, no flattening, worse inference); PureScript's
   own maintainers argue against defaulting to the composable choice. (documented — Discourse #1524)
9. Practitioner evidence on `do`/`ado` specifically is thin; public discussion is mostly maintainer
   design argument, not user complaint. (inferred, from a read-only, budget-constrained search)
10. Per-bind/per-call JavaScript cost is out of scope by the project owner's rule; PureScript's own
    compiler has, by its maintainer's account, "no robust, general optimization framework" beyond
    the named passes here. (documented — Discourse, `natefaubion`)

---

## 8. What could not be resolved

- **A direct practitioner complaint about the `Discard` type-class error message** (§4): the
  mechanism is fully sourced from `Control/Bind.purs`, but no thread frames it as a newcomer
  trip-up the way `#3913` documents the evaluation-order hazard. Tried: targeted GitHub issue/code
  search for "Discard" plus "confusing"/"error message" — no relevant hits.
- **Whether MagicDo's stack-frame collapse (§4, Q8) reads as better or worse for debugging**: no
  source either way, only the structural inference that spans survive per-statement while frames
  merge per-block. Tried: issue search for "source map"/"stack trace" with "magic do" — only an
  unrelated historical issue (#121) turned up. Not independently verifiable without running the
  compiler, out of scope by rule regardless.
- **A ranked or counted set of practitioner threads** (the brief's "N of top-M mention Y" for §5):
  not produced. The session's web-search budget was exhausted before this report began, so evidence
  is limited to threads reachable by direct fetch and the Discourse/GitHub APIs, not a search-driven
  sweep of the forum or Reddit/Hacker News.
- **Whether `purescript-run` (the community's answer to the removed `Eff` row system) is well- or
  poorly-regarded** was not investigated — concurrency/effect-handler territory the shared brief
  assigns to report 16, left there deliberately.
- **The numbered release `QualifiedDo` shipped in** (versus merging to `master` 2018-12-30) was not
  cross-checked against a changelog line — the merge date is solid; the shipping version was not
  the load-bearing fact here.
