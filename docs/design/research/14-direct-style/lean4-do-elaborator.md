# Lean 4's `do`: the only shipped do-notation where a bind inside a loop is ordinary code

**Commissioned by** the direct-style research programme, as the Tier 1 report on the one language
that answered the question the programme exists to ask. Every other family-A system (Haskell,
PureScript, Idris) gives you `x <- m; rest` and then tells you to reach for `forM_` or a fold the
moment the bind is inside a loop, and for a nested `do` the moment it is inside a branch. Lean 4
gives you `for`, `let mut`, `return`, `break`, `continue`, `if` and `match` *inside the block*, and
its authors claim in print that the technique "can readily be adapted to any other functional
language with support for monads and monad transformers" (Ullrich & de Moura 2022, §1). This report
tests that claim against the shipped compiler, not the paper, because the two differ in exactly the
place beni cares about most. **Scope:** the programme was narrowed to ergonomics on 2026-09-14,
after the research was complete; benchmarks and allocation counts have been cut, and a designer's
decision turning on a performance fact is cited in one sentence and left there.

**Sources.** The ICFP 2022 paper `'do' Unchained: Embracing Local Imperativity in a Purely
Functional Language (Functional Pearl)` (Ullrich & de Moura), fetched from
<https://lean-lang.org/papers/do.pdf> and read in full — with no `pdftotext` in this environment its
content streams were decompressed and the text extracted directly, and its TeX ligatures
reconstructed, so every quotation below was checked against the reconstruction and the notation of
Figures 1–9 is described rather than quoted. The **Lean 4 compiler**, cloned at `d3a0781`
(2026-09-14) and read directly: `src/Lean/Elab/Do/` (7 files), `src/Lean/Elab/BuiltinDo/`
(11 files), `src/Init/Core.lean`, `src/Init/Data/List/Control.lean`,
`tests/elab_fail/doErrorMsg.lean*`. GitHub's API for PR bodies (#11150, #12459, #13912, #13931,
#14160), issues (#1804, #9037, #12768, #12827, #13267), the git log of `Do/Basic.lean` and the
repository tree. The Lean reference manual's `do` chapter; two `leanprover-community` Zulip archive
threads. All web sources accessed **2026-09-14**; the WebSearch budget was not exhausted but search
returned little of value here, so nearly everything is a direct fetch of the compiler, the paper or
the tracker.

---

## 0. The three findings, up front

**1. Lean buys "a bind anywhere" with two mechanisms, not one, and the boundary between them is
stated in the source.** The simple path is a continuation-passing elaboration: each `do` element's
elaborator receives a `DoElemCont` — "the `DoElemCont` represents how the rest of the `do` block is
to be elaborated" ([PR #12459](https://github.com/leanprover/lean4/pull/12459), 2026-02-21) — and
`return`/`break`/`continue` are *jumps* to continuations held in a reader context (`ContInfo`,
`src/Lean/Elab/Do/Basic.lean:256-262`). It emits ordinary `>>=` and join points and needs no monad
transformers at all. The heavy path is the paper's `StateT`/`ExceptT` stack, and the compiler says
exactly when it is forced:

```lean
  -- We cannot use join points because `tryCatch` and `tryFinally` are never tail-resumptive.
  -- (Proof: `do tryCatch e h; throw x ≠ tryCatch (do e; throw x) (fun e => do h e; throw x)`)
  -- This is also known as the "algebraicity property" in the algebraic effects and handlers
  -- community. … So we need to pack up our effects and unpack them after the `try`.
```

(`src/Lean/Elab/BuiltinDo/TryCatch.lean:51-56`.) Everything tail-resumptive — `if`, `match`, `for`,
straight-line binds — takes the simple path. Only `try`/`catch`/`finally` and the new `do←` marker
build a stack, through `EffectForwarder.ofCont` (`src/Lean/Elab/Do/Control.lean:208-241`), which
layers `EarlyReturnT`, `StateT` over the reassigned mutables, `BreakT` and `ContinueT` — and only
the layers actually needed.

**2. `for` does not go through the paper's translation. It goes through one type class and one
two-constructor type, and that is the whole answer to "a bind inside a loop".** The paper (§4,
Figure 8) compiles `for` to `runCatch (forM e (fun x => runCatch (C[B[s]])))` — two nested `ExceptT`
layers over a `ForM` class. The shipped compiler never did that. It emits `ForIn.forIn` with a loop
state `β` that is a tuple of the reassigned `mut` variables *plus an `Option ρ` slot for an early
return*, and a body returning `m (ForInStep β)`:

```lean
inductive ForInStep (α : Type u) where
  | done  : α → ForInStep α   -- "produced by uses of `break` or `return` in the loop body"
  | yield : α → ForInStep α   -- "produced by `continue` and by reaching the bottom of the loop body"
```
(`src/Init/Core.lean:351-364`, docstrings verbatim.) `continue` is `pure (ForInStep.yield tuple)`,
`break` is `pure (ForInStep.done tuple)`, `return e` is `pure (ForInStep.done (some e :: muts))` —
three closures installed as the loop's `continueCont`/`breakCont`/`returnCont`
(`src/Lean/Elab/BuiltinDo/For.lean:359-375`); after the loop the `Option` slot is matched to either
resume the block or re-`return` (`For.lean:394-409`). **No monad transformer is involved.** The one
case a `use`/`let*` rewrite cannot express at all is bought with a tuple and a two-constructor sum.

**3. In 2026 Lean added the missing half of family D to family A, and it is the single most
transferable idea here.** `do← body` (ASCII `do<- body`), merged 2026-06-05
([PR #13931](https://github.com/leanprover/lean4/pull/13931)), "lets ordinary continuation-taking
wrappers like `withReader` or `Meta.withLocalDecl` participate in the surrounding `do` block's
control flow. When `do← body` appears as the last argument of an application inside a `do` block,
the body's `return`, `break`, `continue`, and `mut`-variable reassignments are forwarded out through
the wrapper to the enclosing block." That is Gleam's `use` and Koka's `with` — a trailing lambda in
the last argument slot — except that the lambda is not a control-flow wall: Lean's test file shows a
`break` fired inside a callback terminating the *enclosing* `for` (`tests/elab/doForward.lean:43-51`).
The wrapper is checked, not trusted — `validateForwarder` requires type `(… → m α) → m α` with `α`
universally quantified and not occurring elsewhere, and rejects `foldlM`-shaped things with a
dedicated diagnostic (`BuiltinDo/Forward.lean:38-63`).

---

## 1. The effect model

Effects in Lean are **monadic values**, exactly as in Elm's `Task`: `IO α` is a value the runtime
interprets, and sequencing two effects means `Bind.bind`. Effectful code is distinguished from pure
code *in the type*, by the monad `m` in `m α`, and by nothing else — no rows, no capabilities, no
colouring. `do` is a term elaborator, not a statement form: `do …` is an expression of type `m α`
wherever one is expected, and `Id.run do …` runs a block in the identity monad to get pure code with
loops and mutation — which the paper reports users doing unprompted (§8: "We are pleasantly
surprised that users are also using the extended `do` notation in pure code via the identity
monad"). The type-system demand is a `Monad` class over a higher-kinded `m : Type u → Type v`
resolved by instance search, plus `Pure` and `Bind` separately (PR #12459: "`do` notation now always
requires `Pure`"), `ForIn`/`ForIn'` for `for`, `MonadExcept`/`MonadFinally` for `try`, and
`MonadLift` for the automatic lifting coercion (paper §5.3) — and Lean uses the same classes for
*the transformers the elaborator itself introduces*, `StateT` and `ExceptT`.

---

## 2. The mechanism

### 2.1 What the user writes

The `fetchSummary` example from the shared brief, written faithfully in Lean 4:

```lean
structure Summary where
  user     : User
  perms    : Permissions
  auditLog : Option AuditLog

def fetchSummary : ExceptT HttpError IO Summary := do
  let user  ← getUser
  let perms ← getPermissions user
  if perms.isAdmin then
    let log ← getAuditLog user
    return { user, perms, auditLog := some log }
  return { user, perms, auditLog := none }
```

Note what is *absent*: the `if` opens no new block, the bind inside it is an ordinary `let ←`, and
the `then` branch needs no `else` because `if e then s` abbreviates `if e then s else pure ()`
(paper, A5). That is the shape of the brief's Effect-TS generator version, without generators. The
second example — a bind inside a loop, with `continue`, `break` and mutation:

```lean
def fetchAll (ids : List UserId) : ExceptT HttpError IO (Array Summary) := do
  let mut out := #[]
  for id in ids do
    let user ← getUserById id
    if user.isDeleted then continue
    let perms ← getPermissions user
    if perms.isBanned then break
    out := out.push { user, perms, auditLog := none }
  return out
```

### 2.2 What it becomes

The straight-line rule is the Haskell one: `D[[let x ← s; s']] = D[[s]] >>= fun x => D[[s']]`
(paper Figure 1, D2); `let x := e; s` abbreviates `let x ← pure e; s` (A1) and `s; s'` a bind to a
fresh name (A2).

**Local mutation.** `let mut x := e` introduces a state effect scoped to the rest of the block:
`D[[let mut x := e; s]] = let x := e; StateT.run' S_x[[D[[s]]]] x` (D3), where `S_x` lifts actions
with `StateT.lift`, turns `x := e` into `set e`, and — the whole content of the rule — **re-binds
`x` with `get` at every control-flow join point**: between the two statements of a bind (S2) and at
loop entry (S9). Reassignment is restricted to the declaring block, because "there is no way in
general to propagate reassignments back to the outer block without true mutation."

**Early return.** `return e` is `throw e` in an `ExceptT` layer wrapped around the block by
`runCatch` (Figure 7, R1/R2, top-level rule 1'), and the paper's argument for it is that nothing
else has to change: "we get the short-circuiting semantics for free from `ExceptT`'s implementation
of `>>=` introduced by our unchanged translation of `let x ← s; s'`. The only existing rule we had
to change was not that of an extension but the basic top-level translation rule."

**Iteration — as actually shipped**, not as in the paper. The legacy elaborator
(`src/Lean/Elab/Do/Legacy.lean:1630-1641`) builds `for_in% xs (MProd.mk (none : Option ρ)
uvarsTuple) (fun x r => let r := r.2; forInBody)` followed by `match r.1 with | none => pure
PUnit.unit | some a => return a`, where `uvarsTuple` is the tuple of reassigned `mut` variables and
`Option ρ` the early-return channel; the new elaborator does the same directly in `Expr`
(`For.lean:274-409`). So `fetchAll` elaborates to approximately:

```lean
let out := #[]
let r ← ForIn.forIn ids (MProd.mk (none : Option (Array Summary)) out)
  (fun id (r : MProd (Option (Array Summary)) (Array Summary)) => do
    let out := r.2
    let user ← getUserById id
    if user.isDeleted then
      pure (ForInStep.yield (MProd.mk none out))          -- continue
    else
      let perms ← getPermissions user
      if perms.isBanned then
        pure (ForInStep.done (MProd.mk none out))         -- break
      else
        let out := out.push { user, perms, auditLog := none }
        pure (ForInStep.yield (MProd.mk none out)))       -- fall through
out := r.2
match r.1 with
| none   => pure PUnit.unit
| some a => return a
```

The instance supplies the recursion — `List.forIn'` is a tail-recursive `loop` matching on
`ForInStep.done`/`yield` (`src/Init/Data/List/Control.lean:447-461`). `repeat s` is
`for u in Loop.mk do s`, `while c do s` is `repeat { unless c do break }; s` (paper §4): neither is
separate machinery.

### 2.3 The cross-cutting questions

**Q1 — Loop.** Yes, without leaving the mechanism — the distinguishing feature. A bind, a `mut`
reassignment, a `break`, a `continue` and an early `return` may all appear in a `for` body. The
idiom it replaces is `foldlM` over a state tuple; paper §4 gives the motive: "as soon as the number
of 'mutables' increases and/or the control flow inside the loop body gets more complex, handling and
updating of the state tuple can quickly get onerous."

**Q2 — Branch.** Yes, with no new block and no extra nesting; the bound value survives the branch if
declared `mut`, and is otherwise scoped to it. The manual's block-membership rules make
`if`/`match`/`unless` transparent: "elements in branches of `if`, `match`, or `unless` belong to the
same block as the control structure", and "the `do` keywords in `unless`, `while`, and `for` syntax
do *not* introduce new blocks."

**Q3 — Early return.** Yes, anywhere, and it composes with `try`/`finally`: `finally` compiles
through `MonadFinally.tryFinally` wrapping the *lifted* body, so a pending `return` is packed into
the value `tryFinally` threads (`TryCatch.lean:71-78`). The semantics are deliberately
**block-local**: "we will implement `return e` to abort execution *of the current `do` block* and
have it return the value of `e`" (paper §3). The authors flagged the hazard — "We conjecture scope
confusion may also occur when using `return`" — and mitigated it in the editor, not the language
(§4.3); an open draft (#14160, 2026-06-23) proposes *labelled* jumps.

**Q4 — Type-system demand.** Classes, with higher-kinded types: `Monad`/`Pure`/`Bind` for the base,
`ForIn`/`ForIn'` for `for`, `MonadExcept`/`MonadFinally` for `try`, `MonadLift` for implicit
lifting, `LawfulMonad` to prove anything. Instance resolution is load-bearing: `ForIn.forIn`'s
element type is an `outParam` assigned by instance search, which is how `for x in xs` types `x`.

**Q5 — Position.** Statement position for the control forms, plus **arbitrary expression position**
for nested actions: `(← e)` may appear anywhere a term may, inside the block. The rule is a hoist —
"The expression to which it is applied is replaced with a fresh variable, which is bound using
`bind` just before the current step", processed "from left to right, inside to outside" (manual) —
and it is deliberately *narrower* than Idris's: "instead of being lifted 'as high as possible'
[Brady 2014], they are always lifted to the enclosing `do` block. Using the notation outside of a
`do` block is an error." Since 2026-06-08 the thing after `←` may be an arbitrary `doElem`
([PR #13912](https://github.com/leanprover/lean4/pull/13912)) — a breaking change, because `return e`
inside `(← do …)` now returns from the *enclosing* block.

**Q6 — Per-bind cost; Q7 — optimiser transparency.** **Out of scope** under the programme's
ergonomics-only rule (2026-09-14). One sentence for whoever reopens it: paper §5.2 records that the
compiler removes the translation's overhead everywhere except `for`, and the authors responded by
swapping `StateT`/`ExceptT` for CPS variants (`StateCpsT`, `ExceptCpsT`) rather than by changing the
translation — the translation was judged sound and the *transformers* the problem.

**Q8 — Diagnostics and locations.** Good, and expensively so; see §4.2. Lean has no JavaScript
backend and so no source maps to inherit, and stack traces are unaffected because the translation
produces ordinary terms, not a state machine. **Q9 — Removed or regretted.** Three things; see §3.2.

**Q10 — Effects as values.** Fully preserved. The output is an ordinary term of type `m α`; nothing
runs at elaboration time, `m` may be deferred or runtime-interpreted, and paper §6 proves the
results equal to hand-written combinator code *for any `m` with a `LawfulMonad` instance*. Deferral
forces one semantic decision: for monads whose `>>=` runs its right-hand side more than once (list,
continuation), mutables are "interpreted as a *local state effect on top* of the underlying monad",
so "re-running a nondeterministic program or captured continuation is still 'pure'" — they restart.
Koka reached the same answer independently (paper §9).

---

## 3. History and decisions

### 3.1 Adoption

Lean 4 self-hosted in **October 2020** and the extended `do` was in use from then (paper §8: "In
October of 2020, we finally compiled Lean 4 using itself and started using the new notation in our
codebase"); the paper followed at ICFP 2022. The enabling syntax change is a language-level decision
beni would face: monadic binding was realigned from `x <- e` to `let x ← e`, freeing `x := e` for
reassignment and `x ← e` for monadic reassignment. "Since distinguishing between declaration and
reassignment is certainly a good idea, for Lean 4 we have decided on the drastic step of realigning
the monadic binding syntax to the pure one … Thus a variable definition in Lean 4 is uniformly
signified by the `let` keyword." 

### 3.2 What was tried and withdrawn

**Implicit mutability, withdrawn.** "In our first implementation of the extended `do` notation, we
did not have the `mut` modifier, and any variable could be locally mutated. We assumed it would make
the system more convenient to use. However, we have reverted this design decision after we
encountered a few non-trivial bugs in our codebase. All bugs occurred in code containing nested `do`
blocks" — a reassignment inside `f (fun y => do … x := b …)` silently targeting the inner block; "We
say the mistake was due to 'scope confusion.'" The second reason is the one beni should weigh: "the
`mut` keyword dramatically simplifies the implementation by making scope checks a simple decision
local to `do` notation."

**Values from `break`, considered and dropped.** Of `control-monad-loop`: "It also supports
returning values from `break`s, which we have considered but discarded for the time being for lack
of convincing use cases." **`for mut x in xs`, sketched and not built**: paper §9 sketches a
`traverse`-based form where the loop maps its collection and reassigns it; it has not shipped.

### 3.3 The 2025–2026 rewrite

The elaborator has been **replaced wholesale** since the paper, by Sebastian Graf at the Lean FRO.
[PR #11150](https://github.com/leanprover/lean4/pull/11150) (merged 2025-11-12) added an inactive
`doElem_elab` attribute; [PR #12459](https://github.com/leanprover/lean4/pull/12459) (merged
2026-02-21, +3,120/−479 over 46 files) turned it on. The rationale in the PR body is
**extensibility**, not cost: "New elaborators for the builtin `doElem` syntax category can be
registered with attribute `doElem_elab`. For new syntax, additionally a control info handler must be
registered with attribute `doElem_control_info` that specifies whether the new syntax `return`s
early, `break`s, `continue`s and which `mut` vars it reassigns." The old elaborator survives behind
`set_option backward.do.legacy true` and is still 1,866 lines.

The control-info handler is the load-bearing idea: a cheap syntactic pre-pass whose fields are
documented as *syntactic* over-approximations — "`true`/non-empty iff the corresponding construct
appears anywhere in the source text of the block, independent of whether it is semantically
reachable" (`src/Lean/Elab/Do/InferControlInfo.lean:23-40`) — deciding which transformer layers to
build and whether the continuation needs a join point (`numRegularExits > 1`). Since the rewrite:
`do←` (#13931, 2026-06-05); arbitrary `doElem`s after `←` (#13912, 2026-06-08); hover info on `mut`
names (#13970); `invariant`/`decreasing` clauses on loops behind `set_option
experimental.intrinsic` (2026-07/08); `erased` declarations (#15090, 2026-09-11); labelled jumps
still an open draft (#14160).

---

## 4. Costs — ergonomic and structural

*Per the programme's ergonomics-only rule, an earlier draft's subsections on allocation and on tail
calls have been cut; what follows is what the mechanism does to the user's code, to errors, to
tooling, to the type system and to the compiler.*

### 4.1 What it does to the user's code

**What it buys.** Six things that cost nesting elsewhere are ordinary here: a bind inside a branch,
a bind inside a loop, an early return from the middle, a pattern bind with a fallback
(`let some x ← e | fallback`), a mutable accumulator across iterations, and an arbitrary-position
`(← e)`. §2.1's two examples are the evidence: no nested lambda, no fold.

**What it forces the user to restructure.** Four rules the user must learn:

| Restriction | Why | Source |
|---|---|---|
| A `mut` variable may only be reassigned in the `do` block that declared it | "there is no way in general to propagate reassignments back to the outer block without true mutation" | paper §2 |
| A `do` under a `fun` is a *different* block, so reassignment there is an error | the lambda breaks the state threading | Miller, Zulip 2023-06-24 |
| Shadowing a `mut` variable is disallowed outright | side condition on rule S2, and "to avoid any confusion on the user's side between mutable and immutable bindings" | paper §2, `Legacy.lean:1292`/`Basic.lean:383-389` |
| `return` leaves the enclosing `do` *block*, not the function | chosen as "the reasonable semantics we can implement without changing code outside the `do` block" | paper §3 |

**What it cannot express**, and the user must still write by hand: a reassignment escaping into a
callback (the reason `do←` was added in 2026), a `break` carrying a value (declined, §3.2), and a
loop that *maps* its collection rather than accumulating (`for mut x in xs`, sketched, never built).

### 4.2 What it does to error messages and source locations

Good, and expensively so. For `n := false` where `let mut n : Nat := 0`,
`tests/elab_fail/doErrorMsg.lean.out.expected` records
`error: Type mismatch / false / has type / Bool / but is expected to have type / Nat` at
`28:7-28:12` — the user's position, the user's types, no transformer in sight. That is the check the
paper's §5.3 says the reference implementation lacks and the full one adds via `ensureTypeOf!`, and
keeping it costs dedicated machinery: position remapping so mutables inside a loop point at their
declaration (`Legacy.lean:1622-1625`, "a semantic no-op that replaces the `uvars`' position
information … with that of the respective mutable declarations outside the loop"), `FVarAliasInfo`
records tying each reassignment back to its `let mut` (`Basic.lean:118`, pushed at `606`), and
`Term.addTermInfo'` calls through the `for` elaborator. When it is wrong the failures are ugly:
#12768 "New do elaborator creates unbound free variables", #12827 "`for ... in ...` do elaborator
doesn't produce term info", #13267 "go to definition on do elements only shows generic documentation
for `bind`" — all filed within seven weeks of the new elaborator's merge.

### 4.3 What it does to tooling

The `do` elaborator is a **language-server client as much as a desugarer**. Three features exist
only because the desugaring would otherwise be opaque: hovering a `return` highlights the `do`
keyword it belongs to, added "as a precaution" against scope confusion (paper §8, Figure 13, via the
LSP "document highlight" request); `mut` names get hover info in the elaborator's own diagnostics
(#13970, 2026-06-09); and go-to-definition on a `mut` variable after a loop had to be explicitly
restored when the new elaborator broke it (#14296, 2026-07-06). Lean has no JS backend and so no
source-map story to inherit, but the lesson transfers: **every name the desugaring invents is a name
some tool will try to show the user**, and the counter-machinery is ongoing maintenance.

### 4.4 What it demands of the compiler

Measured against the checkout at `d3a0781` (2026-09-14):

| Directory | Files | Lines | Bytes |
|---|---|---|---|
| `src/Lean/Elab/Do/` | 7 | 3,735 | 164,923 |
| — of which `Legacy.lean` (the old elaborator, kept) | 1 | 1,866 | 82,030 |
| — of which `Basic.lean` (the new framework) | 1 | 1,104 | 49,368 |
| `src/Lean/Elab/BuiltinDo/` (per-element elaborators) | 11 | 1,484 | 68,853 |
| — of which `For.lean` | 1 | 409 | 20,834 |
| **Total** | **18** | **5,219** | **233,776** |

Calibration against report 15: Roc's backpassing desugarer was **44 lines**, its arbitrary-position
`!` marker **1,046**. Lean's `for` elaborator alone is 409, on a 3,735-line framework. Test surface:
**120 files** under `tests/elab/` and `tests/elab_fail/` carry "do" in their name, of which roughly
40 are unambiguously `do`-elaborator tests (`doNotation1`–`7`, `doForward`, `doIfLet`,
`doLegacyLoops`, `doMatchDependent`, `newdo`, `nestedDo`, `do_eqv`, …), out of 3,521 `.lean` files
there (GitHub tree API, 2026-09-14).

**Which pass, and how invasive.** All of it is the *term elaborator*, not a separate desugaring
pass, and that is consequential: the `for` elaborator needs the elaborated type of `xs` to run
instance search for `ForIn` (`For.lean:328-343`), needs fresh level metavariables and an explicit
`isLevelDefEq` nudge to stop universe constraints getting stuck (`For.lean:312-319`, the stuck
constraint written out in a comment), and needs the expected type of the whole block. **A `do` this
expressive cannot live in a pre-inference desugarer** — the most important structural fact here for
beni, which §6 turns into a design constraint.

### 4.5 What newcomers get wrong

Three recurring errors. **The lambda wall** — Kyle Miller, Lean Zulip, 2023-06-24: "when you have a
`do` inside a `fun` then it's not considered to be nested anymore", and "you're trying to mutate
`myVar` in a context where `myVar` isn't declared as a mutable variable (due to the `fun` separating
this `do`)". **Indentation capturing a reassignment** —
[#9037](https://github.com/leanprover/lean4/issues/9037) (2025-06-27): `i := i + 1` after a monadic
`let mut i ← match …` parsed into the `match` block, giving "unknown identifier 'i'"; Graf closed it
(2026-04-29) with "Fixed in the new do elaborator." **Where `return` returns to** — mitigated by
editor highlighting rather than by the language, and the reason the labelled-jump PR exists; and
[#1804](https://github.com/leanprover/lean4/issues/1804) (2022-11-07) is a real miscompilation of
that class, a nested action in a `let pat := e | fallback` alternative hoisted *before* the match,
so `f true` ran `inc` when it should not have.

---

## 5. What users say

**The honest finding first: Lean users barely discuss the `andThen` pyramid, because they do not
have one.** Searching the tracker and the Zulip archive for complaints about monadic sequencing
returns issues about *scoping*, *error messages* and *tooling* — never nesting. The question this
programme exists to answer does not appear in Lean's community record after 2020.

**Praise, from the authors' measurement of third parties** (paper §8, 2022): "out of 43 GitHub
repositories written in Lean with the topic 'lean4', **31 repositories by 20 different authors** make
use of at least `let mut` and `for`." In the compiler then: 459 `let mut`, 604 `for`, 3,185 `return`;
**counted here four years later on the same tree** (`src/`, 2,544 `.lean` files, 717,919 lines):
**2,270 `let mut`**, **2,241 `for … in`** — 5× and 3.7× growth. Users also prefer `for` to a
combinator that already exists: "Users also seem to prefer the `for` statement even when it
corresponds to an existing combinator such as `foldl`".

**Praise, from an evaluator.** A 2025-12-07 Advent-of-Code write-up
([sm2n.ca](https://sm2n.ca/log/tips-lean4-aoc/)): "Local mutation is easy… You can write code with
local mutable variables anywhere pretty easily. Lean's support for do-notation comes with local
mutable variables out of the box. It also gives you for loops."

**Complaints, from maintainers.** They are about *scope and tooling*, not sequencing. Miller's
lambda-wall explanation (§4.5) is the most-repeated support answer on Zulip; #9037, filed by a Lean
FRO engineer against core, is indentation swallowing a reassignment; #12768, #12827, #12846 and
#13267 are maintainers hitting the new elaborator's rough edges within seven weeks of the switch —
unbound free variables, missing term info, a confusing error, go-to-definition landing on `bind`.

**Wishes.** Labelled `return`/`break`/`continue` (#14160, open); values from `break` (asked for
often enough that the authors addressed and declined it in paper §9); and, judging from the 2026
feature run, better *verification* of loops (`invariant`, `decreasing`) rather than better
sequencing — which says where the pain actually is now.

---

## 6. What it would take to do this in beni

**From the type system: much less than Lean needs, if there is one `Task`.** Every class in §2.3-Q4
exists because `m` is a variable. Fix `m := Task e` and `Pure`/`Bind` become the names
`Task.succeed`/`Task.andThen`; `MonadLift` disappears; `MonadExcept`/`MonadFinally` become whatever
`Task.onError` and `Task.finally` beni chooses. **`ForIn` is the only real obstacle**, and it is
real: `for x in xs` over a list, an array, a range and a dictionary needs four `forIn`
implementations selected by the type of `xs`. Without classes the options are (a) one `List.forIn`
plus a conversion at every other call site, (b) a compiler-known closed table of container types,
resolved by the *inferred* type of the scrutinee — which drags the desugaring after inference, or
(c) drop `for` and generate a direct recursive helper, which a JS-targeting language can do and Lean
cannot, since JS has real loops and beni need not prove termination.

**From the compiler pipeline: the `ControlInfo` pre-pass and the join-point path, not the
transformer stack.** The central structural finding for beni is that
`for` + `mut` + `return` + `break` + `continue` **needs no monad transformers**. It needs:

1. a syntactic pre-pass computing, per element, `breaks`/`continues`/`returnsEarly`/`reassigns`
   (Lean's is `src/Lean/Elab/Do/InferControlInfo.lean`, 297 lines);
2. a continuation-passing lowering where the "rest of the block" is a value the element's lowering
   may drop (`return`), jump past (`break`) or re-enter (`continue`);
3. a join point whenever that continuation is wired in more than once;
4. for loops, the state tuple `(Option ρ, mut₁, …, mutₙ)` and a two-constructor `ForInStep`.

beni already has the shape for (2): `Lower.zig` lowers a `let` binding list in source order, so the
continuation of binding *i* is `bindings[i+1..]` plus the body (report 15 §0.3). It does not have
(3), and the warning is structural: without join points, a `return` in one arm of an `if` forces the
continuation to be *duplicated* into both arms — which is why `DoElemCont` carries a
`duplicable`/`nonDuplicable` flag (`Basic.lean:185-190`) and `ControlInfo.numRegularExits > 1` is the
trigger for introducing one. Getting it wrong is not slow code; it is exponential code size in
nested branches. **And §4.4's constraint is sharper still**: Lean's `for` cannot run before
inference, since it needs the elaborated type of the collection to pick a `ForIn` instance. beni
hits the same wall the moment `for` is polymorphic in its container — arguing either for a
compiler-known set of iterables resolved after inference, or for keeping the loop monomorphic so the
desugaring stays in the desugarer, where `fast-compiler.md` §3.2 wants it.

**What it would deliver.** Every hard case in the brief's §2 without reaching for a fold: bind in a
branch, bind in a loop, early return from the middle, a pattern bind with fallback
(`let some x ← e | fallback`, paper §5.3), and error propagation through `return`. **Mixing two
effect types is the one it does not solve for us**: Lean inserts `MonadLift` coercions, needing a
lattice of monads and an extension to coercion insertion; with one `Task`, a `Result` inside a
`Task` needs an explicit lift or a `?`-style marker, as `fast-compiler.md` §3.2 contemplates.

**What Lean's authors would warn us about**, in their own words. *Make mutability opt-in*: they
shipped it implicit, hit "non-trivial bugs" from scope confusion, reverted, and note that `mut`
"dramatically simplifies the implementation by making scope checks a simple decision local to `do`
notation." *Decide early where `return` returns to*: they chose block-local, conjectured it would
confuse users, and paid for an LSP feature to compensate. *The loop is the part that resists*: paper
§5.2's one exception is `for`, and they fixed it by changing the transformers, not the translation —
where beni has an option Lean does not, since it need not produce a total term it can reason about:
emit a real JavaScript `for` with the mutables as `let` bindings instead of threading a tuple.

Finally, a caution on portability. "The implementation can readily be adapted to any other
functional language with support for monads and monad transformers" is true of the *paper's*
translation. It is not the one Lean ships, and the shipped one is leaner and far less portable:
written against Lean's `Expr`, instance search, join points and macro hygiene, and 5,219 lines long.

---

## 7. Ranked summary

1. A bind inside a loop or a branch is ordinary code; the loop case needs one class (`ForIn`), one
   two-constructor type (`ForInStep`) and a state tuple with an `Option` early-return slot — no
   monad transformers. (measured, from compiler source)
2. The shipped `for` translation is **not** the paper's `runCatch`/`forM` nesting and never was;
   cite the source, not `do.pdf`, for what Lean does. (measured)
3. Transformers are needed only for `try`/`catch`/`finally` and `do←`, because those are not
   tail-resumptive — "also known as the 'algebraicity property'". (documented)
4. The mechanism rests on join points: without them a `return` in one branch duplicates the rest of
   the block into every arm, which is why `DoElemCont` carries a `duplicable` flag. (documented)
5. It cannot live in a pre-inference desugarer: `for` needs the elaborated type of the collection to
   run instance search, and fights universe constraints doing it (`For.lean:312-319`). (measured)
6. `do←` (2026-06) makes a Gleam-`use`-shaped trailing lambda transparent to the enclosing block's
   `return`/`break`/`continue`/`mut` — family D's missing half, and the most transferable idea here.
   (documented)
7. Implicit mutability was shipped and reverted after "non-trivial bugs" from "scope confusion";
   `mut` also "dramatically simplifies the implementation". (documented)
8. Nested actions `(← e)` are hoisted to the enclosing `do` block — *deliberately narrower* than
   Idris's "as high as possible", for predictability. (documented)
9. Adoption is total and still growing: 459 `let mut` / 604 `for` in the 2022 paper, 2,270 / 2,241
   in the same tree today. (measured)
10. The elaborator is 5,219 lines across 18 files, rewritten wholesale in 2025–2026 for
    extensibility with the old one kept behind `backward.do.legacy`. None of this is cheap.
    (measured)

---

## 8. What could not be resolved

- **A broader practitioner sample.** Lean's Zulip is not publicly archived past the
  `leanprover-community.github.io` mirror, message-level permalinks on `leanprover.zulipchat.com`
  need authentication, and the `roc-zulip` skill does not cover it. §5's complaint evidence is
  therefore the tracker plus two archive threads, not a counted survey.
- **Where the `(← e)` hoist surprises people.** The documented rule — bound "just before the current
  step" — implies that `(← p) && (← q)` loses short-circuiting and that a `(← e)` in a `match`
  discriminant runs before the match, but no Lean source, manual passage, issue or test confirming
  either was found, and no toolchain was available. (unverified)
- **The design discussion behind the 2025–2026 rewrite.** PR bodies #11150 and #12459 are the only
  rationale found; no RFC, Zulip design thread or FRO blog post about it surfaced in search. Whether
  the rewrite was motivated by extensibility alone or by the accumulated bug list is therefore
  (unverified) beyond what the PR bodies say.
