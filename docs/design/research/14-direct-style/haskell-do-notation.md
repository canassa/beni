# Haskell `do`-notation: the origin, and what thirty years bought it

**Commissioned by** the shared brief for report 14 (`docs/design/research/14-direct-style/00-landscape.md`
§2, `haskell-do-notation`): Haskell is where the mechanism this whole programme studies was born, so
this report is the history report as much as the mechanism report. beni's constraints are fixed
elsewhere and are not reopened here — no typeclasses, no higher-kinded types, no row polymorphism
(`fast-compiler.md` §3.1, §3), and report 15 already ruled class-directed `do` out for beni on those
grounds (`15-flat-effect-syntax.md` §1: *"Class-directed … needs either HKT plus dictionaries, or a
trait with an associated type. §3.1 settled that we have neither."*). What report 15 could not do —
because it was surveying twelve mechanisms across many languages — is go deep on the one language
that ran this experiment for three decades: what `do` cost GHC to build, what it desugars to exactly,
what changed when the class stopped being able to carry it (`QualifiedDo`, `RebindableSyntax`), and
what Haskell programmers still complain about after thirty years of practice. This report goes deep.

**Sources.** Read directly: the Haskell 2010 Report §3.14 (`haskell.org/onlinereport`); GHC's
`RebindableSyntax`, `QualifiedDo`, `ApplicativeDo` and `MonadComprehensions` user's-guide pages
(`ghc.gitlab.haskell.org`, current `9.15` development docs, which track the shipped behaviour); the
GHC proposal `0216-qualified-do.rst` in full; the ApplicativeDo paper itself, Marlow, Peyton Jones,
Kmett and Mokhov, *"Desugaring Haskell's do-Notation into Applicative Operations"* (Haskell
Symposium 2016, `simonmar.github.io/bib/papers/applicativedo.pdf`), read via a text-extraction proxy
after direct PDF parsing failed, with section numbers quoted below; Hudak, Hughes, Peyton Jones and
Wadler, *"A History of Haskell: Being Lazy with Class"* (HOPL III, 2007), same extraction method,
partial — §7 (Monads and I/O) did not come through the extraction and could not be recovered before
the session's web-search budget was exhausted (see §8); Wadler's *"Comprehending Monads"* (LFP 1990 /
MSCS 1992), abstract and secondary description only, full text not fetched; the `wiki.haskell.org`
pages for `Do_notation_considered_harmful` and `MonadFail_Proposal`; the 2020-05-08 Hacker News
thread `news.ycombinator.com/item?id=23015593`; the Agda language reference's syntactic-sugar page;
Michael Snoyman's *"The ReaderT Design Pattern"* (FP Complete/fpblock, 2017-06); and secondary
descriptions (Discourse, a Monday Morning Haskell write-up) of the GHC JavaScript backend's
architecture, since the backend's own README returned 404 and its wiki page was blocked by an
anti-bot gate. **The session's WebSearch budget was exhausted partway through this report** (a
shared budget across all agents in the programme) — everything after that point used WebFetch
against URLs already known from the first pass, or a jina.ai text-extraction proxy for PDFs
WebFetch's own PDF path could not parse. This cost the report primary-source access to History of
Haskell §7, `prime.haskell.org`'s MonadFail proposal text (DNS failure, and the jina proxy also
failed on it), and a live fetch of the GHC JS backend's own architecture docs; §8 lists these by
name. All web sources accessed **2026-09-14**.

---

## 0. The three findings, up front

**1. Haskell's `do` was never one thing, and its history is the history of trying to make it not
need a class.** It started as sugar for a `Monad` dictionary method (`>>=`) in the Haskell 1.3
Report (1996) — the Report's own words, quoted in full in §2, are four lines of rewrite rules. Every
extension since has been an argument about whether that class is the right thing to hang `do` off of:
`ApplicativeDo` (2016) desugars to a *weaker* class when the dependency structure allows it, because
`Applicative` is what many real monads (Haxl above all) actually need; `QualifiedDo` (GHC 9.0, 2021,
GHC proposal 0216) desugars to *no class at all* — `M.>>=`, resolved by module qualifier, exactly
what beni would need since it has no classes to resolve against; and `RebindableSyntax` (long
present, `-XRebindableSyntax`) desugars to *whatever is lexically in scope*, no class, no qualifier,
just a name. Agda's `do`, cited by the landscape file as a look-for, independently arrived at
`QualifiedDo`'s answer: *"Do-notation is desugared before scope checking and is translated into
calls to `_>>=_` and `_>>_`, which can be arbitrary user-defined functions"* (Agda language
reference, `agda.readthedocs.io/en/latest/language/syntactic-sugar.html`, accessed 2026-09-14). Two
languages independently concluded that a class is not required to make `do` work — only a name in
scope is. That is the design report 15 already picked for beni (the "syntactic, resolved by scope"
family); Haskell is proof that even the class-oriented ancestor of the idea ended up building the
class-free version too, once real users needed it.

**2. `ApplicativeDo`'s desugaring is not a free lunch — it is a compiler heuristic with a
correctness precondition and a measured, real payoff.** GHC's own documentation states the
condition plainly: *"Applicative do-notation desugaring preserves the original semantics, provided
that the `Applicative` instance satisfies `<*> = ap` and `pure = return`"*
(`ghc.gitlab.haskell.org/…/applicative_do.html`, current dev docs). The paper is blunter about what
happens when a program is refactored: *"a minor change to the program might cause a different
rearrangement, which in turn had very different behaviour (e.g. parallelism)"* (§3.10), and *"the
applicative structure that the compiler derives may change as the code is refactored"* (§2.3). The
payoff, at Facebook, was real and specific — not a synthetic microbenchmark but three production
request classes in Sigma, their abuse-detection system, each independently measured: *"44%
improvement in average latency"*, *"34% improvement"*, *"22% improvement"* across three request
types (§5.5) — because ApplicativeDo let the *existing* Haxl `Applicative` instance batch requests
that `>>=`'s sequential desugaring could never see as independent. (This is a published number from
the paper's own evaluation, not a measurement this report ran; it is cited once, per the brief's
rule on performance facts, because the designers' account of the decision hinges on it.)

**3. The complaints that survive thirty years of `do` are not about `do` itself — they are about
what sits underneath it: the class, and the transformer stacks built to combine several of them.**
`do` syntax is uncontroversial in the Haskell community; searching for its critics surfaces one
wiki page (`Do_notation_considered_harmful`) whose own author hedges — *"frames criticism as matters
of style preference rather than absolute rules"* — and a single 2020 HN thread reacting to a decade-
old post, where the top rebuttal is explicitly that the criticism "hasn't aged well" now that
`ApplicativeDo` exists. The real, sustained complaint is monad-transformer-stack pain — Michael
Snoyman's ReaderT pattern post exists because *"Deep monad transformer stacks are confusing"* and
because a five-layer stack makes GHC itself worse at optimising: *"It's simpler for GHC too, which
tends to have a much better time optimizing one-layer ReaderT code versus 5-transformer-deep code"*
(fpblock.com, 2017-06). That pain is upstream of `do`'s syntax entirely — it is the cost of *stacking
classes*, which is exactly the mechanism beni has already ruled out having at all.

---

## 1. The effect model

Haskell's effects are **class-dispatched values, not native side effects, with one historical
exception that the language spent its first decade fighting: I/O.** A value of type `IO a` is a
description of an action, opaque to inspection, executed only when linked into `main`; "sequencing
two effects" means applying the `Monad` class's `(>>=) :: m a -> (a -> m b) -> m b` to values of the
same `m`. There is no runtime that "interprets" a `Task`-like value the way Elm's platform does —
`IO`'s implementation in GHC is close to the metal (the `IO` monad is `State# RealWorld -> (# State#
RealWorld, a #)`, a token-threading trick, not an interpreter loop) — but the *language-level*
model is identical to Elm's: an effect is a value, distinguished from a pure value by its type, and
combined with other effects of the same type through a uniform interface. Purity is enforced by the
type system, not convention: a function `Int -> Int` cannot perform `IO`, full stop; there is no
`unsafePerformIO` in normal code (it exists, and using it is a well-known escape hatch, not part of
the effect model). This is stronger than Elm's split, which relies on `Task`/`Cmd` being the only
things the runtime executes — Haskell additionally prevents *any* function from having a hidden
effect regardless of what runs it.

The class is deliberately generic: `Monad` has no built-in notion of "the effects a `Task` needs"
(retry, cancellation) — those are library concerns (see report 16 for what a `Task` runtime needs;
Haskell's own concurrency story is `async`/`STM`, out of scope here). What `Monad` buys is a single
vocabulary — `>>=`, `>>`, `return`/`pure`, `fail` — reused across dozens of otherwise-unrelated
types: `Maybe`, `Either e`, lists, `State s`, `Reader r`, parsers, STM transactions, and `IO` itself.
`do`-notation is sugar over that one vocabulary, which is why it looks identical for a total, pure
computation (`Maybe`) and a live network request (`IO`) — the syntax carries no information about
which.

---

## 2. The mechanism

### The rewrite rule, verbatim

The Haskell 2010 Report, §3.14, gives four rules (`haskell.org/onlinereport/haskell2010/haskellch3.html`):

```
do {e}                    = e

do {e;stmts}              = e >> do {stmts}

do {p <- e; stmts}        = let ok p = do {stmts}
                                 ok _ = fail "..."
                             in e >>= ok

do {let decls; stmts}     = let decls in do {stmts}
```

`>>`, `>>=` and `fail` are, in the Report's words, "operations in the class Monad, as defined in the
Prelude." The Report is explicit about a scoping subtlety that matters for any implementation of the
same idea: *"variables bound by `let` have fully polymorphic types while those defined by `<-` are
lambda bound and are thus monomorphic"* — a `let x = e` inside a `do` block generalises `x`'s type
the normal Hindley-Milner way, but `x <- e` cannot, because it is really a lambda argument to `ok`.
Any HM language building the same sugar inherits this exact asymmetry for free, because it falls out
of ordinary lambda-bound-vs-let-bound generalisation, not from anything `do`-specific.

### What the type system must know

For plain `do`, a **class** — `Monad`, with a superclass `Applicative`/`Functor` chain since GHC 8
(the Applicative-Monad Proposal, AMP, not separately sourced here but visible in every modern
`Prelude`) — resolved by ordinary dictionary-passing type-class inference: the compiler must infer
which `Monad` instance `e`'s type belongs to and pass its `(>>=)` method. For `QualifiedDo` (proposal
0216, merged for GHC 9.0), **nothing** beyond ordinary name resolution: `M.do { x <- u; stmts }`
desugars to `u M.>>= \x -> M.do { stmts }` — the proposal's own words on why this is enough: *"An
advantage of `M.do` is that it doesn't need the programmer to understand a new notion of expressions
having fully settled types"* — a direct rejection of an earlier design (a "builder" record of
operations, à la F#) that *did* need settled types, in favour of pure syntactic substitution of a
qualified name. `RebindableSyntax` goes one step further than even that: **no qualifier, no class,
whatever `(>>=)`, `(>>)` and `fail` are lexically in scope**, file-wide — the GHC user's guide's own
warning is blunt: *"Be warned: this is an experimental facility, with fewer checks than usual. Use
`-dcore-lint` to typecheck the desugared program. If Core Lint is happy you should be all right."*
That sentence is worth sitting with: GHC's own documentation recommends debugging `RebindableSyntax`
by looking at the *compiler's internal IR*, because the surface-language error messages are not
trusted to explain it. `QualifiedDo` was proposed specifically to give most of `RebindableSyntax`'s
per-block flexibility without that all-or-nothing, whole-file, weakly-checked cost — the proposal's
listed alternative, an even more class-like "qualify by `MonadFail.do`" scheme, was rejected because
it "encourag[ed] single-instance classes" and required "navigating superclass hierarchies."

### Where the marker may appear

Statement position inside a `do { … }` block. But because `do` is an ordinary Haskell *expression*
— not a statement form bolted onto an expression language, as in F# or Python — a `do` block may
appear anywhere an expression may: as an `if`/`case` branch, as a function argument, inside another
`do` block's `let`. This is the single largest structural difference from every block-structured
sugar report 15 surveyed (Gleam's `use`, OCaml's `let*`, Koka's `with`): those languages' bind
constructs consume "the rest of the enclosing block" by construction, so a bind under a branch
*must* open a new block. Haskell's `do` is just sugar for an expression tree, so the branch case is
qualitatively different — see below.

### The hard cases

**Bind inside a branch, and the value used after.** This is where Haskell's expression-orientation
earns its keep. Because `if`/`case` are expressions, and a `do`-typed value is an ordinary value,
you can bind the *result of a branching expression* in the outer `do` block, provided both arms
produce the same monadic type:

```haskell
fetchSummary :: User -> IO Summary
fetchSummary user = do
  perms <- getPermissions user
  mLog  <- if isAdmin perms
             then Just <$> getAuditLog user
             else pure Nothing
  pure (Summary user perms mLog)
```

Here `mLog` is bound in the *outer* block from a branching expression whose two arms are both
`IO (Maybe AuditLog)` — no nested `do` is needed at the call site, and the branch's result is used
freely afterward, unlike Gleam's `use`, which cannot express this shape at all (it must fall back to
a nested block that the *rest of the function* lives inside, per report 15). If instead the two arms
need to diverge in more than their result — as the brief's own `fetchSummary` example does, where the
admin arm makes an *extra* call before producing the value — each arm gets its own nested `do`:

```haskell
fetchSummary :: IO Summary
fetchSummary = do
  user  <- getUser
  perms <- getPermissions user
  if isAdmin perms
    then do
      auditLog <- getAuditLog user
      pure (Summary user perms (Just auditLog))
    else
      pure (Summary user perms Nothing)
```

This is structurally identical to the Gleam version in the brief (a nested block in the admin arm),
because the *number of subsequent binds differs per branch* — no syntax, block-structured or
otherwise, avoids that; only a generator or full CPS transform can (report 15 §0.4, echoing
`fast-compiler.md`'s note on this). Haskell's win over Gleam is narrower than "any bind in a branch is
flat" — it is "a branch whose two arms are already single monadic values, of the same effect type,
can be bound directly," which is a real and common case (the `mLog` example) that `use`-style sugar
cannot express without restructuring.

**Bind inside a loop.** Not expressible as a literal loop with a bind in its body — Haskell has no
loop statement at all, direct-style or otherwise. The idiom is a higher-order traversal function
from `Control.Monad`/`Data.Traversable`: `forM_ :: (Monad m) => [a] -> (a -> m b) -> m ()` for
effects-only iteration, `mapM`/`traverse` to collect results, `foldM` to thread an accumulator:

```haskell
processAll :: [User] -> IO [Summary]
processAll users = forM users $ \user -> do
  perms <- getPermissions user
  pure (Summary user perms Nothing)

-- an accumulating loop needs foldM, not forM_:
totalCost :: [Item] -> IO Int
totalCost items = foldM (\acc item -> do
                            price <- fetchPrice item
                            pure (acc + price))
                        0 items
```

`when`/`unless` (`Control.Monad`) are the loop-adjacent idiom for conditional effects without a
value: `when (isAdmin perms) (logAccess user)`. This is precisely the family the landscape file
flags as "the idioms that replace loops" — and it is a real cost: a Haskell learner must know four
different combinators (`forM_`, `mapM`, `foldM`, `when`/`unless`) to cover what a generator-based
direct-style loop covers with one construct (a `for` loop with `yield*`/`await` inside it, per the
brief's Effect-TS example). Lean 4's `do` (a sibling report in this programme) is the one shipped
system report 15's table does not cover that puts `for`, `mut` and `break`/`continue` *inside* `do`
itself, precisely to remove this combinator zoo — worth reading that report against this one.

**Early return.** No native early return from a `do` block: `return`/`pure` in Haskell is *not* a
control-flow escape (a beginner trap the community names explicitly — `return x` inside a `do` block
just produces `m a` at that point, it does not stop the block; the desugaring rules in §2 make this
obvious once seen — `return x` is only the last statement if it is written last). Escaping mid-block
requires reaching for a monad whose semantics already model "stop here": `Maybe`, `Either e` (via
`ExceptT` in a stack, or `MonadError`'s `throwError`), or an actual runtime exception under `IO`
caught with `catch`/`try` from `Control.Exception`. There is no `?`-like operator in base Haskell for
this (unlike Rust); `ExceptT`'s `throwE`/`catchE` is the closest analogue, and it interacts with
`bracket`/`finally` (`Control.Exception`) the normal way exceptions do — `bracket` runs its cleanup
under `IO` regardless of which path (normal return, exception, or async exception) left the guarded
action, which is a real strength of Haskell's actual-exception plumbing that a pure `Either`-based
short-circuit does not automatically get (an `ExceptT` stack does not run `finally`-style cleanup
unless the stack has `MonadCatch`/`MonadMask`, from `exceptions` or `unliftio`, layered in — one more
transformer, one more thing to reason about, which is exactly §0.3 and §4's complaint).

**Pattern matching on the bound value; mixing two effect types.** Pattern matching on `<-` is
supported directly (`(x, y) <- getPair`) and is exactly where `MonadFail` (§3) exists: a refutable
pattern desugars to the `fail`-calling `ok` function in §2's rewrite rule, so `Just x <- maybeAction`
inside an `IO` `do`-block *type-checks* — `IO` has a `MonadFail` instance (defaulting to `error`) —
while the same pattern under a monad with **no** `MonadFail` instance is a compile error, by design
(§3). Mixing two effect types — a `Result` (`Either e`) inside a `Task` (`IO`) — has no native
syntax; the idiom is `ExceptT e IO a`, a monad transformer that *is* `IO` composed with `Either`'s
short-circuiting, and once inside an `ExceptT` `do`-block, plain `<-` binds either layer
transparently (`liftIO` needed only to reach the base `IO` action from user code, or automatically
via `MonadIO`). This transformer machinery is precisely §0.3's and §4's subject.

---

## 3. History and decisions

**Monad comprehensions, 1990–1998.** Wadler's *"Comprehending Monads"* (LFP 1990, MSCS 1992)
generalised the list-comprehension notation `[e | qualifiers]` to an arbitrary monad — a
comprehension is a value to the left of `|`, filters are boolean expressions, parallel to `do`'s
later shape but pre-dating it as a *comprehension* rather than a statement sequence. Early Haskell
(pre-1.3) had comprehensions generalised to arbitrary monads directly; this was reversed: by the
Haskell 98 Report, list comprehensions had "revert[ed] to just lists" (Hudak, Hughes, Peyton Jones,
Wadler §4.5, via the extracted text — full section not independently re-verified, see §8). GHC
later revived exactly Wadler's generalisation as an **opt-in extension**, `MonadComprehensions`,
which generalises "the list comprehension notation, including parallel comprehensions and transform
comprehensions … to work for any monad" — Wadler's 1990 idea, shipped thirty years later as a flag
instead of the default, once `do` had already won the default slot.

**`do` itself: Haskell 1.3, May 1996.** The extracted text of *"A History of Haskell"* dates it
precisely: *"Monadic I/O made its first appearance, including 'do' syntax"* in the Haskell 1.3
Report (§2.5, per the extraction — this report could not reach the paper's own §7, "Monads and
input/output," where the design narrative and the authors' own account of *why* `do` over Wadler's
comprehension syntax would live; see §8). The design choice visible in the surviving sections is
that `do` is a **statement-flavoured surface syntax over the same monadic core** Wadler already
had — `do { x <- m; e }` versus a comprehension's `[ term | x <- m ]` are the same rewrite,
reordered to look like an imperative statement list, presumably to make monadic I/O *read* like
sequential code, which term-first comprehension syntax does not for a multi-statement program.

**Layout rule.** `do`'s statement list uses Haskell's general layout rule (indentation implies the
`{ ; }` an explicit-brace `do` would otherwise need) — not `do`-specific, but the mechanism the
Report defines once and reuses everywhere a block of declarations or statements occurs (`let`,
`where`, `case` alternatives, `do`). The relevant interaction: a **mis-indented** `do` statement
produces a parse error about layout, not about monads — a formatter/tooling cost category report 15
already flagged, real here too.

**`MonadFail`: the class was split because `fail` could not be honestly given to every monad.**
Originally `fail` lived directly in `Monad`, invoked by the compiler on any refutable pattern bind
(§2's `ok _ = fail "..."`). The proposal's own diagnosis, quoted from the wiki page via search
(`wiki.haskell.org/MonadFail_Proposal`, accessed 2026-09-14): *"the problem is that `fail` cannot be
sensibly implemented for many monads, for example `State`, `IO`, `Reader`. In those cases it
defaults to `error`. The presence of `fail` in `Monad` class is, clearly, a hack."* Implementation
began at ZuriHac 2015 (Franz Thoma and David Luposchainsky), gated initially behind
`-XMonadFailDesugaring`; the migration completed in GHC 8.8.1 (July 2019), when `fail` was finally
removed from `Monad` and `MonadFail` exported from `Prelude`. The shape of the fix matters for any
language borrowing this idea: **the compiler needs to know, per-monad, whether refutable pattern
binds are even legal**, and the honest way to express "this monad has no sensible failure behaviour"
is a *missing instance*, not a runtime `error` — exactly the guarantee beni's own stance (`no null`,
"well-typed code does not throw") would want, if beni ever added a pattern-bind sugar of its own.

**`ApplicativeDo`: 2016, driven by one production system.** Motivated explicitly by Haxl at
Facebook — a monad whose `>>=` is necessarily sequential (it must know one request before issuing
the next) but whose `Applicative` instance can *see* that two requests are independent and batch
them. The paper's abstract, quoted via Peyton Jones's own site: *"Programmers are increasingly
waking up to the usefulness and ubiquity of `Applicative`s, but they have so far been hampered by
the absence of supporting notation."* Rather than invent new syntax, the authors reused `do` itself
and taught the desugarer to prefer `<*>`/`<$>`/`join` over `>>=` wherever the statements' data
dependencies allow it — full mechanism in §2 and §4.

**`QualifiedDo`: GHC proposal 0216, merged for GHC 9.0 (2020–2021).** Motivated by the same "modern
Haskell has monad-like things that are not `Monad`" pressure (indexed monads, graded monads, linear
types) that `RebindableSyntax` already answered, but badly: *"`-XRebindableSyntax` … affect[s] an
entire file"*, the proposal says, and the authors wanted per-block, not per-file, control. Two
alternatives were explicitly rejected: a **builder** approach (a record of operations with a fully
"settled" type, modelled on F#'s computation expressions) — rejected because it needed a new notion
of "fully settled types" the proposal's authors judged too complex for programmers to reason about;
and qualifying by **type class** (`MonadFail.do`) — rejected for "navigating superclass hierarchies"
and for "encouraging single-instance classes," i.e., defining a one-off `Monad`-shaped class purely
to get `do` sugar for a type that isn't really a monad. The chosen design — resolve by *module
qualifier*, an ordinary name-in-scope lookup — needed, in the proposal's words, no understanding
that "expressions hav[e] fully settled types": pure syntax, no semantic analysis at all.

**`RebindableSyntax`: no single proposal document found; long-standing GHC extension**, documented
in the current user's guide (`exts/rebindable_syntax.html`) as affecting `do`, `if`/`then`/`else`
(desugars to a user `ifThenElse`), numeric and string literals (`fromInteger`, `fromRational`,
`fromString`), and, with `-XOverloadedLists`, list syntax. It predates `QualifiedDo` and remains the
strictly more powerful, strictly less safe sibling — the extension `QualifiedDo` exists specifically
to make mostly unnecessary at per-block granularity.

**Do notation considered harmful, and what survived it.** The `wiki.haskell.org` page argues
`do` "obscures" the underlying `>>=`/`fmap` structure, that beginners read do-blocks as imperative
statement order when only data dependencies matter, and that do-notation licenses silently discarding
a bound value's meaning (`do { getLine; ... }`, the value simply dropped) — the page's own comparison
is to *"a dark side of the C programming language,"* i.e., an unused expression statement. But the
page itself frames this as a style objection, not a correctness one, and closes by praising `mdo`
notation's safety. The 2020-05-08 Hacker News discussion of the (by-then decade-old) essay is a
useful for/against snapshot precisely because it happened *after* `ApplicativeDo` shipped: the top
comment calls the original argument "a very old opinion, and one I don't think has aged terribly
well," citing `ApplicativeDo` and the `Applicative`-as-`Monad`-superclass change as reasons the
original complaint no longer lands; the most-quoted pro-`do` line in the thread is *"Do-notation
papers over map and bind in the same way that for-loops paper over cmp and jmp. I do not want to go
back to map and bind."* No secondary sources beyond the thread's own text were used for its content.

---

## 4. Costs — ergonomic and structural

**What it forces the user to restructure.** Nothing, for the base case — `do` over `Monad` is
opt-in sugar for `>>=`/`>>`, always available as an escape hatch (`e >>= \x -> ...`) when the sugar
doesn't fit. The forcing function is elsewhere: **mixing two different monads in one function forces
a transformer stack**, and every layer of that stack is a separate `do`-desugaring target requiring
either an `mtl`-style class instance (`MonadReader`, `MonadState`, …) or an explicit `lift`. This is
where the real restructuring cost lives, and it is a cost `do` inherits rather than causes — the
class-per-effect design (§1) is what makes combining effects expensive, and `do` just makes the
expense legible.

**Error messages.** `RebindableSyntax`'s own documentation effectively concedes this is a real,
serious cost: recommending `-dcore-lint` — reading the compiler's post-desugaring internal
representation — as the way to sanity-check a `do`-block under rebound operators, because ordinary
type errors against the surface syntax are not reliable there. `QualifiedDo` narrows this: because
the qualified operators are ordinary, statically-typed functions resolved by ordinary name lookup, a
type error inside a qualified `do`-block is an ordinary type error against `M.>>=`'s signature, not
a Core-level mystery — this is presented in the proposal as one of its selling points over
`RebindableSyntax`, though no direct quote to that effect was found (inferred from the proposal's
"doesn't need... fully settled types" framing and from the mechanism itself).

**Tooling.** No source located on formatter or debugger interaction specific to `do`-notation beyond
the layout rule (§3): a `do`-block is ordinary syntax to `fourmolu`/`ormolu`; no source describes
stack-trace behavior specific to `do`-desugared code versus explicit `>>=` chains. Not resolved; §8.

**What the compiler pipeline pays.** Base `do` desugars in the **renamer/typechecker**, before Core
— by the time GHC's optimiser sees a `do`-block, it is already `>>=`/`>>` applications, indistinguishable
from code the user wrote by hand. `ApplicativeDo` is the one variant that is genuinely a *pass*, not
a syntax-directed rewrite: §2's algorithm (dependency analysis + a cost-based `split` that
"exhaustively test[s] the possibilities and pick[s] the best," per the paper's §3.2) runs before
desugaring proper and chooses, per do-block, which of several *semantically distinct* desugarings to
emit. `QualifiedDo` and `RebindableSyntax` cost nothing extra in the pipeline beyond ordinary name
resolution — this is precisely why report 15 classes them, alongside OCaml's `let*` and Gleam's
`use`, as the affordable family for a language without typeclasses.

**What newcomers get wrong.** Two documented traps: (1) reading `do`-statement order as imperative
execution order when only data dependencies matter (the wiki page's central complaint, and precisely
what `ApplicativeDo` exploits by reordering); (2) treating `return`/`pure` as an early-return
control-flow keyword by analogy to imperative languages, when it is an ordinary function producing
an `m a` value wherever it's written (§2). No count of newcomer questions ("N of M threads") was
sourced; this evidence is qualitative, not a tally.

**Runtime cost.** *Out of scope by the brief's hard rule* — not measured or estimated here beyond
the one Haxl percentage already quoted once in §0 and §3 as the designers' stated motivation, not as
a number this report evaluates.

---

## 5. What users say

**Praise.** Concentrated on `do` as *readable sequencing*, not on any technical property — the HN
thread's "papers over map and bind... I do not want to go back" comment is the clearest statement
found, and it is explicitly a comparison to imperative sugar (`for` loops over `cmp`/`jmp`), i.e.
praise for exactly the ergonomic move report 15's whole survey is about. `MonadComprehensions`'
continued existence as an opt-in extension, and `ApplicativeDo`'s adoption at Facebook, are indirect
praise-by-uptake for the *generalisation* of `do` beyond `Monad`, not for `do` syntax itself.

**Complaints.** Two distinct populations, matching the brief's instruction to separate them.
Newcomers evaluating the language: the wiki page's complaints (imperative misreading, silently
dropped binds) read as an *evaluator's* critique — someone learning Haskell finding the syntax
deceptive relative to what it does. People maintaining large codebases: Snoyman's ReaderT-pattern
post is explicitly a maintainer's document, written for teams running deep transformer stacks in
production, and its complaint is not about `do` but about what `do` sits on top of once you combine
effects: *"Deep monad transformer stacks are confusing,"* both for humans and, his stronger claim,
for GHC's own optimiser (§0.3 quote). This is the "which monad am I in" complaint the brief's launch
message names directly, and Snoyman's fix — collapse the stack to `ReaderT Env IO` plus `mtl`-style
classes for the rest — is itself evidence that the complaint is taken seriously enough to have a
canonical, widely cited answer rather than being dismissed. No thread-counting ("N of top-M") was
possible within this report's search budget; see §8.

**Wishes.** `QualifiedDo`'s own motivation section is a wishlist made concrete: support for
non-`Monad` "monad-like" abstractions (indexed monads, graded monads, linear-typed sequencing)
*without* `RebindableSyntax`'s whole-file blast radius. That wish shipped. No further wishlist
material (feature-request threads, GHC ticket surveys) was sourced within budget; see §8.

---

## 6. What it would take to do this in beni

beni already has, decided, exactly what makes `QualifiedDo`'s answer (not `do`'s original,
class-directed one) the relevant precedent: no typeclasses, no HKT (`fast-compiler.md` §3.1). Report
15 already picked the "syntactic, resolved by scope" family for exactly this reason and this report
does not relitigate that. What Haskell's history adds, specifically:

- **The `MonadFail` split is a direct warning for any pattern-bind sugar beni considers.** If beni
  ever sugars `let Just x = maybeVal in …`-style refutable binds inside a bind-chain, Haskell's
  history says: do not give every effect type a fallback `error`-like failure path by default (that
  is "clearly a hack," in the proposal's own words) — require an explicit, typed failure story per
  effect type, or reject refutable binds against effects that cannot express one. beni's own
  no-throw guarantee makes the honest answer easier than Haskell's: a refutable bind against a
  `Result`/`Task e a` should widen into that type's own error channel, and a refutable bind against
  an effect with no error channel should be a compile error, not a hidden `error "Pattern match
  failure"`.
- **`ApplicativeDo`'s dependency analysis is a genuinely reusable idea, decoupled from its class
  machinery.** The segmentation algorithm (§2, §3) — find statements whose bound variables are
  unused by everything after them, and consider running those "in parallel" — needs *no* `Applicative`
  class to be meaningful; it needs only that beni's runtime *has* a parallel/batched form for its
  effect type (which report 16 is the place to establish for `Task`). If beni's `Task` runtime ever
  offers something like `Task.all` or Haxl-style batching, the ApplicativeDo segmentation pass is a
  concrete, already-published algorithm to adapt: run it over `let`-binding sequences, emit the
  batched form where the dependency graph allows it, fall back to sequential otherwise — with the
  same correctness precondition GHC states (the batched and sequential forms must be observably
  equivalent for beni's `Task`, which, unlike an arbitrary `Applicative`, beni controls completely
  and can simply guarantee by construction rather than by law-abiding-instance convention).
- **Haskell's branch case (§2) is the strongest argument in this whole report for keeping beni
  expression-oriented for effects.** The `mLog <- if … then … else …` example is *not* available to
  Gleam's `use`, and it falls directly out of `if` being an ordinary expression whose branches can be
  monadic values bound in the outer scope. beni is already expression-based (`fast-compiler.md`'s own
  open question notes this explicitly: *"beni is expression-based, so `let … in` is the only
  sequencing construct"*). Whatever bind syntax beni picks, it should preserve this property:
  a branch whose two arms are both the same effect type should be bindable from outside the branch,
  not force a nested block the way Gleam's `use` does. This is free if beni's chosen bind form (per
  report 15, most likely a `let`-position rewrite) treats a branching expression as just another
  expression that can appear on the right of a bind — no extra compiler work beyond what already
  exists for ordinary `if`-as-expression.
- **The loop case is not solved by anything in this report, and Haskell's own answer (`forM_`,
  `foldM`, `when`) is exactly the combinator zoo `fast-compiler.md`'s open question already flags as
  unsolved for beni ("not expressible" in report 15's table, row A).** Nothing here changes that
  finding; Haskell confirms it by having lived with the zoo for thirty years without fixing it in the
  core language (`MonadComprehensions` does not help with loops either — it only helps with
  collection-shaped iteration, exactly `forM`'s territory, not an accumulating loop with early exit).
- **What GHC's own JS backend would warn beni about:** its architecture (per secondary description,
  §8) reuses GHC's frontend — parsing, renaming, typechecking, `do`-desugaring, Core — completely
  unmodified, and only replaces the code generator at the STG stage. Haskell's `do` desugaring is,
  on GHC's JS target, exactly as opaque to JS-specific optimisation as on native: the JS backend
  inherits GHC's generic thunk/closure representation rather than emitting anything JS-idiomatic for
  monadic binds. beni, which controls its entire pipeline down to the JS it emits (unlike GHCJS,
  retrofitting a JS backend onto a compiler built around STG/Cmm), does not have to accept "generic
  backend, opaque binds" as a given — it can make the bind-desugaring pass JS-aware from the start,
  which reports 15 and 16 already assume it will.

---

## 7. Ranked summary

1. **(documented)** Class-directed `do` is Haskell's original and default design (Haskell 2010
   Report §3.14, `>>=`/`>>`/`fail` on `Monad`), but every extension since has moved *away* from the
   class: `QualifiedDo` (name-resolved), `RebindableSyntax` (scope-resolved), `MonadComprehensions`
   (a revived pre-1.3 idea, opt-in). The class was never load-bearing for the *syntax*, only for the
   *default* resolution strategy.
2. **(documented)** `QualifiedDo`'s two rejected alternatives — a "builder" needing fully-settled
   types, and a type-class-qualified `MonadFail.do` — were both rejected for needing more machinery
   than a bare module-qualified name lookup, which is exactly the "nothing" column report 15 already
   picked for beni.
3. **(documented)** `ApplicativeDo`'s correctness is conditional, stated by GHC itself: *"provided
   that the `Applicative` instance satisfies `<*> = ap` and `pure = return."`* A language that
   controls its own effect types (as beni would) can make this an invariant rather than a convention.
4. **(published, cited once per the brief's rule)** ApplicativeDo's real-world payoff at Facebook was
   measured per request class (44%/34%/22% latency improvement, Marlow et al. §5.5) — the designers'
   own stated reason for building it, not a number this report evaluated independently.
5. **(documented)** The `MonadFail` split happened because giving every `Monad` instance a fallback
   `error`-based `fail` was, in the proposal's own word, "a hack" — direct precedent against giving
   beni's effect types a silent default failure path for refutable binds.
6. **(inferred, from the two primary sources read)** The dominant real complaint from Haskell
   maintainers (Snoyman) is about *transformer stacks*, not `do` syntax — which matches the brief's
   framing that today's effect libraries exist to fix the stacking problem, not the sugar problem.
7. **(documented)** Haskell's `do` is an ordinary expression, so a branch whose two arms share an
   effect type can be bound in the *outer* scope without nesting — a capability Gleam's `use` lacks
   and worth preserving in whatever bind form beni adopts.
8. **(documented)** Haskell has no native loop-with-bind; the idiom is `forM_`/`mapM`/`foldM`/`when`,
   unresolved after thirty years, matching report 15's and `fast-compiler.md`'s existing finding that
   block-structured bind syntax cannot express a bind inside a loop at all.
9. **(unverified)** Whether `do`-desugared code produces measurably worse or better stack traces /
   debugger stepping than explicit `>>=` chains — no source found; see §8.
10. **(inferred)** The GHC JS backend's unmodified-frontend architecture means Haskell's `do`
    desugaring is exactly as opaque to JS-specific optimisation on that target as on native — a data
    point in favour of beni doing its own bind-lowering with JS in mind from the start, rather than
    treating it as backend-agnostic sugar the way GHC does.

---

## 8. What could not be resolved

- **History of Haskell §7 ("Monads and input/output"), full text.** The text-extraction proxy used
  for the PDF (jina.ai) returned only earlier sections (§2, §4–6) before truncating; the section that
  would contain the authors' own account of *why* `do` syntax over Wadler's comprehension form, and
  any recorded internal debate, was not recovered. Tried: direct WebFetch of the PDF (failed, binary
  content only); the extraction proxy on the same URL twice (truncated both times); WebSearch for
  quoted fragments of §7 specifically (blocked — session web-search budget exhausted at that point).
- **`prime.haskell.org`'s MonadFail proposal page, primary text.** `wiki.haskell.org`'s own copy
  states it "has been moved to the Haskell Prime Wiki," but `prime.haskell.org` failed DNS resolution
  directly and returned HTTP 422 through the extraction proxy. The proposal's rationale used in §3 is
  sourced instead from a WebSearch-engine synthesis of the same page (attributed, with the direct
  quote "clearly, a hack" reproduced as found), not from reading the page itself — weaker provenance
  than this report's other primary-source citations, and flagged as such at first use.
- **GHC JavaScript backend's own architecture documentation.** The compiler source's `StgToJS`
  README returned 404 at the guessed path; the GHC wiki page was blocked by an anti-bot gate
  (Anubis); `engineering.iog.io`'s announcement post 404'd directly and was unreachable through
  `web.archive.org` (tool-level restriction, not a network failure). §1 and §6's description of the
  backend's architecture rest on a WebSearch-engine synthesis of secondary sources (a Monday Morning
  Haskell write-up and a Discourse thread), not a primary document — flagged at first use in §6.
- **Wadler's "Comprehending Monads," full text.** Only the abstract and secondary descriptions were
  read (via WebSearch synthesis); the paper's own comparison of comprehension notation to what became
  `do` syntax, if it makes one, was not directly verified.
- **Newcomer-confusion and complaint counts ("N of top-M threads").** The brief asks for counts where
  possible; this report's search budget did not stretch to a systematic Reddit/Discourse/Stack
  Overflow sweep for do-notation-specific confusion threads, so §4 and §5 report only the qualitative
  sources found (one wiki page, one HN thread, one blog post), explicitly not claiming these
  represent a counted sample.
- **Tooling interaction (formatter, debugger, stack traces, source maps) specific to `do`.** No
  source was found describing behaviour distinct from ordinary Haskell code once desugared; this may
  genuinely be "nothing to report" (the desugaring happens before any tool-visible stage) rather than
  an unsearched gap, but this report could not confirm that distinction with a source.
- **Question 6 (per-bind and per-call cost on JavaScript) is out of scope by the brief's hard rule**
  and is not addressed beyond the one Haxl percentage cited once in §0/§3/§7 as the designers'
  stated motivation, not as an original or endorsed measurement.
