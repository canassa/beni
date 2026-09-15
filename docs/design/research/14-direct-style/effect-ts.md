# Effect-TS: `Effect.gen`, and what a library does when it cannot add syntax

**Commissioned by** the direct-style programme's family-G slot
([00-landscape.md](00-landscape.md) §2): *generators and stackless coroutines as a library escape
hatch*. Effect-TS is the closest living relative of the thing beni already has — a `Task e a` that is
a value a runtime interprets — written flat. It is also the only subject in this programme whose
authors **built the language-level syntax, shipped it, and then deleted it**, and wrote a post-mortem
saying why. Report [16](../16-fibers-and-concurrency.md) covered the fiber runtime and
`fast-compiler.md` §3.2 point 5 already records that "Effect-TS's cost is its fiber runtime, not its
generators". This report is about the generator layer above it: what `Effect.gen` actually is, what it
buys, what it silently costs the user, and what its designers say about doing it in the grammar
instead.

**This report is about ergonomics.** The programme owner withdrew performance from scope partway
through; no benchmark, timing or allocation count appears below. Where a designer's own account of a
decision turns on a performance fact, it is cited in one sentence and dropped.

**Sources.** The published `effect` package **3.22.2** (npm `latest`, 2026-09-09) read from an
installed copy, as report 16 did, so every line quoted is code that ships; paths below are inside
`node_modules/effect/dist/`. Effect **4.0.0-rc.115** (npm `rc`, 2026-09-11) read from
`packages/effect/src/` on GitHub `main`. History from the Effect-TS GitHub API — PRs #2602, #2674,
#3880, #3883, #5772 and issue #5991, with diffs and comments. Arnaldi's *Abusing TypeScript
Generators* fetched as raw markdown from the dev.to API; the **TS+ Post-Mortem** (Arnaldi, last
updated 2025-07-03) fetched and de-marked-up in full. The `Effect-TS/language-service` README and six
diagnostic sources from `raw.githubusercontent.com`. Effect's docs for generators (v3 and v4),
`code-style/do`, `Either`, *Myths About Effect*, the 3.12 release post and the podcast index.
Practitioner accounts from Tom MacWright (Val Town), Dimitrios Lytras and Nathan Leung (Harbor).
Usage counts from GitHub's code-search API. **Reddit and AnswerOverflow (the Effect Discord mirror)
refused every client tried** — 403 and a Vercel bot check — so the Discord, where most Effect
discussion happens, is absent from §5 and §8 says so. Web search returned mostly SEO tutorial content
and was abandoned early for direct fetches. All web sources accessed **2026-09-14**.

---

## 0. The three findings, up front

**1. `Effect.gen` is not a desugaring. It is a runtime protocol, and that is why it costs the
type system nothing.** There is no rewrite rule to cite because there is no rewrite. `Effect.gen`
stores the *live iterator* in an effect node and hands it to the interpreter
(`dist/esm/internal/core.js:651-660`):

```js
export const fromIterator = iterator => suspend(() => {
  const effect = new EffectPrimitive(OpCodes.OP_ITERATOR);
  effect.effect_instruction_i0 = iterator();
  return effect;
});
export const gen = function () {
  const f = arguments.length === 1 ? arguments[0] : arguments[1].bind(arguments[0]);
  return fromIterator(() => f(pipe));
};
```

The fiber's continuation table drives it (`dist/esm/internal/fiberRuntime.js:120-138`): call
`next(value)`, and if what comes back is an already-completed `Exit` keep draining in a local
`while` loop; otherwise push the iterator frame onto the fiber stack and return the effect for the
run loop. The *whole* type-level apparatus is three things — `Effect` declares
`[Symbol.iterator](): EffectGenerator<Effect<A, E, R>>` (`dist/dts/Effect.d.ts:88`), the three
parameters are declared covariant (`interface Effect<out A, out E = never, out R = never>`,
`:84`), and `gen`'s return type destructures the *union* of everything yielded with two conditional
types. No class, no trait, no member protocol, no row. **A mechanism that demands nothing of the
type system is exactly what `fast-compiler.md` §3.1's "no typeclasses, no HKT" constraint was
looking for, and family G is the only family in the landscape that delivers it while also permitting
a bind inside a loop.**

**2. The syntax is flat because TypeScript has statements, not because generators are magic.** A
generator body is a statement list, and `yield*` is an *expression* inside it. Those are two separate
gifts and beni has neither. The statement list is what makes `const user = yield* getUser` read like
`let user = ...`; the expression-ness is what lets a bind appear in an argument position, an `if`
condition, a loop body — the arbitrary-position property that report 15 §0.2 measured at **1,046
lines** of dedicated compiler pass when Roc tried to obtain it by source rewriting (`suffixed.rs`),
against 44 lines for the block-structured shape. A generator gets it free because the continuation
is the engine's own resume point, not a syntactic construct anyone has to hoist. `fast-compiler.md`
§3.2's closing paragraph isolates the other half — *"beni is expression-based, so `let … in` is the
only sequencing construct"* — and §6 argues the two must be answered together or the mechanism
delivers half its value.

**3. Effect's authors built beni's option — real syntax in a real compiler — and killed it, and
their stated reasons are ecosystem reasons that do not transfer, plus one aesthetic judgement that
does.** TS+ was a TypeScript compiler fork with a `Do(($) => { const user = $(getUser(id)) })` form
replacing `Effect.gen(function* () { const user = yield* getUser(id) })`, plus operator overloading,
a native pipe operator, fluent methods and type-driven derivation. Arnaldi's post-mortem (last
updated 2025-07-03): *"Most modern tooling achieves speed through parallel compilation of each file,
something that doesn't really work with `tsc`'s architecture"*; *"we should never cross the boundary
of having to integrate with build tooling"*; and the one that matters most here — *"While we had new
shiny features, there wasn't anything there that couldn't be accomplished natively in TypeScript with
a comparable amount of syntax. Our enhancements looked cleaner to the untrained eye, but the
syntactic improvements were largely cosmetic."* **Three of the four objections are about forking a
language you do not own. The fourth is a verdict that `$(e)` beats `yield* e` only cosmetically —
and beni's baseline is not `yield* e`, it is Elm's `andThen` pyramid, which is a different
comparison entirely.** They also left the door ajar: *"If we were to do anything at the language
level again, we would need to work with a different file extension and we would need to gain some
major advantages that justify the ecosystem split."*

---

## 1. The effect model

An `Effect<A, E, R>` is an immutable description of a workflow: success type `A`, the *expected*
failures `E`, and `R`, the services that must be supplied before it runs. It is a value, exactly as
an Elm `Task e a` is; the extra channel `R` is dependency injection, which Elm and beni do not have
(`boundary.md` §3 gives the platform that job). The runtime representation is a tagged node —
`new EffectPrimitive(OpCodes.OP_*)` with up to three instruction slots — and report 16 §1.1 recorded
that Elm's scheduler is the same shape with five tags.

**Sequencing two effects means building a node, not running anything.** `Effect.flatMap(a, f)`
allocates an `OP_ON_SUCCESS` node; the fiber's run loop walks the tree, pushing and popping a
continuation stack. Nothing executes until `Effect.runSync`/`runPromise`/`runFork`. Deferred
execution, retry by re-running, cancellation by killing the fiber, and interpretation under a
different service layer all follow, and `Effect.gen` preserves every one of them (cross-cutting Q10):
`fromIterator` wraps its body in `suspend`, so the generator function is invoked afresh on **every**
run, not once at construction.

**Effectful and pure are distinguished in the type, with no colouring keyword.** A function returning
`Effect<A, E, R>` is effectful; one returning `A` is not. There is no `async` modifier and no effect
row. What TypeScript cannot do is *stop* you calling an impure function from inside a pure one —
hence the language-service's twelve "Effect-native" diagnostics against `Math.random()`, `Date.now()`,
`fetch`, `console`, `setTimeout` and `process.env` inside a generator (§4.3). **The purity discipline
is a linter, not a type system.**

---

## 2. The mechanism

### 2.1 What the user writes, and what it becomes

```ts
const fetchSummary: Effect.Effect<Summary, HttpError, UserService> = Effect.gen(function* () {
  const user  = yield* getUser
  const perms = yield* getPermissions(user)
  if (perms.isAdmin) {
    const log = yield* getAuditLog(user)
    return new Summary(user, perms, Option.some(log))
  }
  return new Summary(user, perms, Option.none())
})
```

There is nothing to desugar. TypeScript emits the generator function unchanged (or downlevels it to
`tslib`'s `__generator` state machine for old targets — the docs require *"the `downlevelIteration`
flag or ... a `target` of `"es2015"` or higher"*). At runtime `Effect.gen` calls the function to get
an iterator and stores it in an `OP_ITERATOR` node. `yield* eff` works because `EffectPrototype`
carries `[Symbol.iterator]` (`dist/esm/internal/effectable.js:65-67`), returning a `SingleShotGen`
(`dist/esm/Utils.js:82-121`) whose sole `next()` yields the effect itself, boxed in a `YieldWrap`
(`Utils.js:275-289`) — a private-field wrapper added in 3.0.6 so a `yield*`ed `Effect` is
distinguishable at the type level from other iterables. **In v4 the box is gone**:
`packages/effect/src/Effect.ts:1431` types the body as `Generator<Eff, AEff, never>` with
`Eff extends Effect<any, any, any>` directly.

### 2.2 What the type system must know

Nothing about monads. The v3 signature, verbatim (`dist/dts/Effect.d.ts:5029`):

```ts
export declare const gen: {
  <Eff extends YieldWrap<Effect<any, any, any>>, AEff>(
    f: (resume: Adapter) => Generator<Eff, AEff, never>
  ): Effect<AEff,
    [Eff] extends [never] ? never
      : [Eff] extends [YieldWrap<Effect<infer _A, infer E, infer _R>>] ? E : never,
    [Eff] extends [never] ? never
      : [Eff] extends [YieldWrap<Effect<infer _A, infer _E, infer R>>] ? R : never>
}
```

Three tricks make it work. `Eff` is inferred as the **union** of every type yielded in the body.
Wrapping in a one-tuple (`[Eff] extends [...]`) suppresses conditional-type distribution, so
`infer E` over a union of covariant `Effect`s yields the union of the error types. `TNext` is
`never`, which is what lets a union of differently-typed yields typecheck at all. **The error channel
is computed by ordinary structural inference over a union — no constraint solving, no class
resolution, no dictionary.** `Adapter` — the legacy first parameter — survives as a twenty-overload
interface for source compatibility and is gone in v4.

### 2.3 Where the construct may appear

`yield*` may appear **anywhere an expression may appear, inside a generator function body**. That
answers cross-cutting Q5 with the strongest possible answer and it costs the compiler nothing,
because the "compiler pass" is V8's existing generator lowering. The complement is the restriction:
**it may not cross a function boundary.** A `yield*` inside a nested arrow function is a syntax
error, so a helper that wants to bind must itself be a generator — which is the entire reason
`Effect.fn` exists (§3.4).

### 2.4 The hard cases

**Bind inside a loop** (cross-cutting Q1) — expressible, with `break` and `continue`:

```ts
const fetchAll = (ids: ReadonlyArray<string>) => Effect.gen(function* () {
  const out: Array<User> = []
  for (const id of ids) {
    const user = yield* getUserById(id)     // a bind, in a loop body
    if (user.deleted) continue
    out.push(user)
    if (out.length >= 10) break
  }
  return out
})
```

Report 15 §0 established that family D (`use`, `let*`, `with`, backpassing) **cannot express this at
all**; there you write a fold. It is the single largest expressiveness difference in the landscape.

**Bind inside a branch** (Q2) — no new block, and the bound value survives the branch, as
`fetchSummary` shows. Contrast the Gleam version in the shared brief, which needs `{ }`.

**Early return from the middle** (Q3) — plain `return`, and `return yield*` to fail. The latter is
idiomatic enough that the language-service ships a fix for it (`missingReturnYieldStar`, *"Suggests
using 'return yield*' for Effects with never success for better type narrowing"*):

```ts
const report = Effect.gen(function* () {
  const cfg = yield* Config
  if (!cfg.enabled) return Option.none<Report>()
  const rows = yield* query(cfg)
  if (rows.length === 0) return yield* new EmptyResult()   // failure, from the middle
  return Option.some(summarise(rows))
})
```

**But `try`/`finally` does not interact correctly with it, and the code says why.** On failure the
fiber unwinds with `getNextFailCont`, which **pops and discards** `OP_ITERATOR` frames alongside
`OP_ON_SUCCESS` and `OP_WHILE` (`dist/esm/internal/fiberRuntime.js:889-897`), and neither the run
loop nor `core.js` ever calls `iterator.return()` or `iterator.throw()` — zero call sites. **The
generator is abandoned mid-suspension; a `finally` block in the body never runs.** Cleanup must use
`Effect.acquireRelease`, `Effect.ensuring` or a `Scope`. That is the mechanical reason behind the
`tryCatchInEffectGen` diagnostic: *"This Effect generator contains `try/catch`; in this context,
error handling is expressed with Effect APIs"*.

**Pattern matching on the bound value** is ordinary TypeScript, because the bound value is an
ordinary value: `const r = yield* Effect.either(risky)` then `switch (r._tag) { case "Left": ... }`.

**Mixing two effect types** — there is no lifting, because the other types *are* Effects. The docs
state the subtyping directly: *"The Either type works as a subtype of the Effect type"*, with
`Left<L>` → `Effect<never, L>` and `Right<R>` → `Effect<R>`; `Option` likewise, failing with
`NoSuchElementException`. So:

```ts
const mixed = Effect.gen(function* () {
  const raw  = yield* readFile(path)                      // E: PlatformError
  const json = yield* Either.try(() => JSON.parse(raw))   // E: + UnknownException
  const name = yield* Option.fromNullable(json.name)      // E: + NoSuchElementException
  return name
})
```

The union in the error channel is formed by TypeScript's own inference over the yielded union
(§2.2). **Nothing in the library converts anything.** For beni this is the shape to copy: make
`Result e a` a degenerate `Task e a`, and `?`-style mixing becomes free rather than a coercion
problem — dissolving the trap `fast-compiler.md` §3.2 point 3 identifies, where ordered speculative
unification silently picks `Result` over `Task`.

**Error propagation** (Q4 is answered above: *nothing*) — the docs: *"If any of the effects that you
handle inside of the generator with `yield*` fail, then the generator will stop and exit with that
failure"*, stopping at *"the **first error** it encounters"*.

---

## 3. History and decisions

### 3.1 2020: the adapter, and why it existed

Arnaldi, *Abusing TypeScript Generators*, dev.to, **2020-11-02**, names the prior art — Paul Gray's
fluent `Do`, and Giulio Canti's pipeable `T.do` / `T.bind` chain, *"really nice to use but still
doesn't feel native typescript and there is a good degree of repetition in accessing the scope
explicitly at every bind"* — and credits the generator idea to nythrox and the replay trick to
Mattia Manzati. The adapter `_` was a deliberate compromise:

> "we would like to avoid modifying the types of `Effect` and in general any type so we won't
> directly add a generator inside them. That would also break variance of the type."

Then the compromise was mined for value: because `yield* _(x)` routes through a function, `_` could
be overloaded to accept a `Tag`, an `Option`, an `Either` or a `Managed` — *"if you have restrictions
at the api level, find opportunities to exploit them"*.

The same post records family G's hard ceiling. Multi-shot effects (`Stream`, `Array`, the list monad)
need the generator replayed from the start for each element, because *"Iterators are mutable so there
is no way we can 'clone' the iterator"* — hence `genF` *"(to be used in one-shot cases, very
efficient)"* and `genWithHistoryF` *"(to be used in multi-shot cases, n^2 complexity for the n-th
yield)"*. **Generators buy direct style for anything resumable once, and nothing else.**

### 3.2 2024: the adapter's removal

PR [#2602](https://github.com/Effect-TS/effect/pull/2602), Arnaldi, opened and merged
**2024-04-24**, touching 24 packages: *"allow use of generators (Effect.gen) without the adapter"*.
The PR body is empty; the design is in Arnaldi's own first comment nine minutes later — the
`EffectGenerator` interface, followed by *"This is nuts but it may actually work..."* The 2020
objection (an iterator on `Effect` *"would also break variance"*) was answered by declaring the
variance explicitly — `out A, out E, out R` — which is what makes §2.2's union inference sound. The
docs now say *"With advances in TypeScript (v5.5+), the adapter is no longer necessary for type
inference."* The old form still compiles and is flagged by `effectGenUsesAdapter`; code search finds
it in **3,032** files against **282,624** for the modern form (§5.1).

A week later PR [#2674](https://github.com/Effect-TS/effect/pull/2674) (Tim Smart, 2024-05-01)
proposed `Effect.genFn`, to turn a parameterised generator into a function. Smart's own body: *"Not
so sure I like it though, as it kills composability (you can't just tack on a `.pipe()` after the
definition."* Arnaldi: *"Also it feels very ad-hoc, why genFn and not any other constructor? imho not
worth"*. Rejected — then shipped seven months later as `Effect.fn`, the composability objection
answered by a variadic pipeline parameter and with *tracing*, not convenience, as the justification
(§3.4).

### 3.3 The run-loop rewrite, and why it matters structurally

Until **2024-11-03**, `gen` built a `flatMap` chain: `core.flatMap(yieldWrapGet(result.value), next)`
per yield. PRs [#3880](https://github.com/Effect-TS/effect/pull/3880) and
[#3883](https://github.com/Effect-TS/effect/pull/3883) (Tim Smart) replaced that with a dedicated
`OP_ITERATOR` primitive handled by the fiber's continuation table — a seven-file change whose
interesting part is sixteen lines of `fiberRuntime.ts`. PR
[#5772](https://github.com/Effect-TS/effect/pull/5772) (Smart, **2025-11-20**, brought back from the
v4 line) then wrapped that handler in a `while (true)` draining consecutive already-completed yields
without returning to the run loop at all. The stated motivation is performance and is not pursued
here. **The structural point transfers: once the block is a single node holding a resumable
continuation, the runtime can see the whole sequence and optimise across it, which it cannot do with
an opaque chain of user closures.** v4 exposes that as `Effect.fnUntracedEager` — *"Executes
generator functions eagerly when all yielded effects are synchronous, stopping at the first async
effect"* (`packages/effect/src/Effect.ts:15428`).

### 3.4 `Effect.fn`, and the stack-trace problem

`Effect.fn` shipped in **3.11.0** (2024-12-02), improved in **3.12** (Tim Smart, 2024-12-23):
*"Stack traces will now include the location where the function was defined, not just where it was
called."* The implementation is the tell (`dist/esm/Effect.js:10734-10757`, `10786-10832`): at
*definition* time it sets `Error.stackTraceLimit = 2`, allocates a throwaway `new Error()` and keeps
it; at every *call* it does the same again; on failure `captureStackTrace` splices the two two-frame
stacks together and hangs the result on a span.

```js
export const fn = function (nameOrBody, ...pipeables) {
  const limit = Error.stackTraceLimit
  Error.stackTraceLimit = 2
  const errorDef = new Error()        // the definition site
  Error.stackTraceLimit = limit
  ...
```

**This exists because the generator destroys the call stack.** The body runs inside the fiber's run
loop, so when a `yield*`ed effect fails there are no caller frames on the JS stack to report. A
compiler would attach a source location to the bind; a library reconstructs one from two synthetic
exceptions. The sibling `Effect.fnUntraced` — *"for when performance is critical"* — is the opt-out,
and it is used: **27,008** files against **86,528** for `Effect.fn` (§5.1).

Source *locations* inside the block are still missing. Issue
[#5991](https://github.com/Effect-TS/effect/issues/5991) (clayroach, **2026-01-20**) proposed a Babel
transform in a new `@effect/unplugin` rewriting `yield* getUserById(id)` into
`yield* $(getUserById(id), _trace0)` with a hoisted location record, so logs read
`source=UserRepo.ts:3`. Closed by its author: *"Per @tim-smart closing this in favor of starting on
4.0"*. **Note what it is: a build-time source-to-source transform over the user's generator body, to
recover what a compiler would have had for free.**

### 3.5 TS+: the language-level version, built and withdrawn

Covered in §0.3. Three further details matter for beni. The *shape* they chose when they had a
compiler was **not** `yield*` — it was `Do(($) => { const user = $(getUser(id)) })`, a marker
function applied in expression position, i.e. landscape family E, not family G. Their replacement
strategy after abandoning it is explicit: *"we can strategically patch the compiler to produce
better, Effect-specific diagnostics that improve the IDE experience when editing `.ts` files"* — the
language-service plugin of §4.3, and now `Effect-TS/tsgo`, a fork of the Go TypeScript compiler
carrying it. And the retrospective is not closed: with TSGo, *"many of the performance constraints
that plagued our original fork are no longer in place ... However, the tooling ecosystem remains a
significant burden, and we're pretty sure that changing the semantics of a `.ts` file remains a
terrible idea."*

---

## 4. Costs — ergonomic and structural

**Cross-cutting Q6 (per-bind and per-call cost on JavaScript) is out of scope by the programme
owner's instruction.** The designers' one-sentence account, from Effect's own *Myths About Effect*:
*"Effect's internals are not built on generators, we only use generators to provide an API which
closely mimics async-await."* Report 15 §0.5 and `fast-compiler.md` §3.2 point 5 record the same
attribution. Nothing further is claimed here.

### 4.1 What it does to the user's code

Nothing, inside a block: control flow is JavaScript's. The restructuring cost is at the **function
boundary**. Because `yield*` cannot cross one, every helper that binds must be a generator, and every
generator must be wrapped by `Effect.gen` or `Effect.fn` to become a value — which is why the
language-service has both `effectFnOpportunity` (*"Suggests using `Effect.fn` for functions that
returns an Effect"*) and `unnecessaryEffectGen` (*"Suggests removing `Effect.gen` when it contains
only a single return statement"*) and `nestedEffectGenYield` (*"This `yield*` is applied to a nested
`Effect.gen(...)` that can be inlined"*). **The wrapper is noise the user is constantly adding and
removing, and an editor plugin arbitrates.**

### 4.2 Diagnostics, locations and tooling (cross-cutting Q8)

Type errors inside the block are TypeScript's, over a three-parameter type whose `E` and `R` are
inferred unions. A missing service surfaces at the *outer* `Effect.gen` call as an `R` mismatch, not
at the `yield*` that needed it — hence the plugin's `missingEffectContext`, `missingEffectError`
(with a fix) and `anyUnknownInErrorContext`. Source locations inside the block: absent (§3.4).
Runtime stack traces: reconstructed by `Effect.fn` from two synthetic `Error`s, or absent. Formatter
and parser: nothing to do — `function* () {}` is stock grammar, which was the design goal. Debugger:
stepping works up to the `yield*`, then control leaves for the fiber run loop. Source maps: survive,
since TypeScript emits the generator unchanged for ES2015+ and `tslib`'s `__generator` below that;
**no verified statement found** about fidelity through the downlevel path. And the `.pipe()`
alternative has a hard ceiling `Effect.gen` does not: `Pipeable` declares a fixed overload ladder
(`dist/dts/Pipeable.d.ts:9-40`) topping out at twenty transformation arguments, a twenty-first giving
`error TS2554: Expected 0-20 arguments`. That asymmetry is structural, not stylistic, and is a real
reason long pipelines migrate to generators.

### 4.3 What newcomers get wrong — the evidence is an editor plugin

`Effect-TS/language-service` ships **79 diagnostics** (count of
`packages/language-service/src/diagnostics/` on `main`, 2026-09-14). **Twelve are about the generator
mechanism itself**, and read as a catalogue of the failure modes:

| Diagnostic | Message or description (verbatim) |
|---|---|
| `missingStarInYieldEffectGen` | "This uses `yield` for an `Effect` value. `yield*` is the Effect-aware form in this context." |
| `floatingEffect` | "This Effect value is neither yielded nor used in an assignment." |
| `returnEffectInGen` | "This generator returns an Effect-able value directly, which produces a nested `Effect<Effect<...>>`." |
| `tryCatchInEffectGen` | "This Effect generator contains `try/catch`; in this context, error handling is expressed with Effect APIs" |
| `nestedEffectGenYield` | "This `yield*` is applied to a nested `Effect.gen(...)` that can be inlined" |
| `missingReturnYieldStar` | "Suggests using 'return yield*' for Effects with never success for better type narrowing" |
| `effectGenUsesAdapter` | "Warns when using the deprecated adapter parameter in Effect.gen" |
| `unnecessaryEffectGen`, `effectFnOpportunity`, `effectFnIife`, `effectFnImplicitAny`, `effectDoNotation` | wrapper hygiene (§4.1) |

Two of these are the genuinely dangerous ones and both are specific to *effects as values in
statement position*. **`floatingEffect`: an effect you forget to `yield*` is a value you computed and
threw away — it silently never runs, and it typechecks.** Elm's `andThen` cannot have this bug,
because there is no statement position in which to drop a value. **`missingStarInYieldEffectGen`: one
missing `*` changes the meaning and not obviously the type.** Tom MacWright (Val Town, 2026-07-16)
independently wrote `ast-grep` rules against a third: *"If you run into an issue, you yield an error,
not throw"* — a `throw` inside a generator becomes a defect, not a typed failure, taking *"a totally
different error handling path"*.

### 4.4 Removed or regretted (cross-cutting Q9)

| Thing | Status | Stated reason |
|---|---|---|
| The `_` adapter | removed 2024-04-24 (#2602), still accepted, linted against | unnecessary once `Effect` declares variance and iterability |
| `YieldWrap` | removed in v4 | type-level box no longer needed |
| `Effect.genFn` | rejected 2024-05-01 (#2674) | Smart: *"it kills composability"*; Arnaldi: *"feels very ad-hoc"* |
| `Effect.Do` / `bind` / `let` | demoted; `effectDoNotation` suggests `Effect.gen` instead | docs call `Effect.gen` *"the most concise and convenient solution"* |
| TS+ (the language) | abandoned; post-mortem 2025-07-03 | fork friction, build tooling, *"largely cosmetic"* |
| Multi-shot `genWithHistoryF` | never brought into `effect` | replay is O(n²) in yields (author's own note, 2020) |

---

## 5. What users say

### 5.1 Counts

GitHub code search over public TypeScript, **2026-09-14** (counts are approximate, include vendored
copies, and should be read as ratios, not censuses):

| Query | Files |
|---|---|
| `Effect.gen(function*` | 282,624 |
| `Effect.flatMap(` | 66,304 |
| `.pipe(Effect.flatMap` | 10,080 |
| `Effect.andThen(` | 26,496 |
| `Effect.fn(` | 86,528 |
| `Effect.fnUntraced(` | 27,008 |
| `Effect.gen(function* (_)` (legacy adapter) | 3,032 |

**The "`Effect.gen` versus `pipe`" debate is over and generators won by roughly 28 to 1 against the
piped `flatMap` form.** The remaining `pipe` usage is overwhelmingly *combinator application* —
`effect.pipe(Effect.retry(...), Effect.timeout(...))` — not sequencing, which is also what the docs
recommend. The library's own position is not neutral: `code-style/do` calls `Effect.gen` *"the most
concise and convenient solution"*, and `effectDoNotation` flags the applicative `Do`/`bind` chain as
a style problem. `effect` itself is at **24.5M weekly npm downloads** (npm API, week ending
2026-09-11); v4 has been in beta since 2026-02-18 and is at `4.0.0-rc.115`.

### 5.2 People maintaining large codebases

Effect's own podcast index lists ten episodes, eight with named production adopters: Zendesk
(2024-11-26), Markprompt, MasterClass, Vercel, Spiko, OpenRouter, Warp and OpenCode. **In none of the
practitioner material found does the generator syntax itself appear as a complaint.** What appears
instead:

- **Documentation.** MacWright (Val Town, 2026-07-16), on a codebase where most *"database-touching,
  authentication-enforcing, or business logic-producing methods"* use Effect: *"The documentation
  problem is still pretty bad ... the fear that documentation simply isn't highly valued or
  prioritized persists because I've seen so little improvement."* He is not adopting v4: *"v4 is
  **not documented**."*
- **Traps about effects-as-values, not about generators.** MacWright's two named rules: don't `throw`
  inside `Effect.gen`, and never use `Effect.promise`, because a rejection *"produces a **defect**,
  not a failure, and that goes through a totally different error handling path."*
- **Ecosystem boundaries.** Nathan Leung (Harbor, 2025-11-24), on why they do not use Effect:
  *"instead of writing regular JavaScript, all effect-ful functions must be wrapped in
  Effect-specific wrappers and control flow (e.g. `Effect.tryPromise`, `Effect.gen`, etc.). This
  results in code that is markedly different from 'normal' JavaScript."* The objection is to the
  wrapping, not to `yield*`.

### 5.3 People evaluating it, and what anyone wishes for

Dimitrios Lytras (2024-02-09), using Effect for validation and error handling only: *"Chances are
that generators aside, you can read it just fine. There's some syntax sugar, but it's familiar."* On
the three-channel type, *"For me, this is a big deal. I can see at a glance what my function does and
what can go wrong."* On the learning curve, *"I found myself in a rabbit hole ... I was always
searching for how to do it the **right way** ... I became overwhelmed."*

The wishes are all about *locations*: #5991's source-trace injection, `Effect.fn`, `Effect-TS/tsgo`.
**Nobody is asking for different bind syntax.** That is the most useful finding in §5: in the one
ecosystem that has lived with generator-based direct style at scale for six years, the syntax stopped
being a topic and what it cost the debugger did not.

---

## 6. What it would take to do this in beni

**From the type system: nothing.** Not a class, not HKT, not a row — cross-cutting Q4's cheapest
possible answer, and the reason family G belongs in beni's shortlist at all despite
`fast-compiler.md` §3.2's earlier dismissal. beni's situation is strictly easier than Effect's: one
known type constructor `Task e a` rather than a three-channel type inferred as a union, and no `R`
channel because `boundary.md` §3 gives the platform that job. The checker needs to know one thing —
that this block sequences `Task` — and beni already knows that from the block's own type.

**From the compiler pipeline: one lowering case and one runtime op.** Lower the block's body to a
JavaScript `function*` and emit `Task.fromIterator(() => body())`, then teach the scheduler an
`ITERATOR` tag beside its existing `AND_THEN`. Report 16 §1.1 quotes Elm's `_Scheduler_step` and it
is the same `while (proc.__root)` shape as Effect's run loop; the addition is Effect's twelve-line
`OP_ITERATOR` handler, and Effect's own history (§3.3) shows the naive version — build an `andThen`
per yield — works first and can be replaced later without touching the front end. **Crucially the
desugarer stays local.** Report 15 §0.2's measured 24:1 gap between Roc's 44-line backpassing rewrite
and its 1,046-line `suffixed.rs` exists because a source-level marker in arbitrary position must be
hoisted; a generator's continuation is the engine's resume point, so nothing is hoisted and there is
no `is_expr_suffixed` predicate to re-walk the tree at eight call sites.

**What it would deliver:** every hard case in §2. Binds in loops (which no block-structured rewrite
can express), binds in branches with the value surviving, early `return` from the middle,
arbitrary-position binds, and mixed `Result`/`Task` sequencing with no coercion if `Result` is made a
degenerate `Task` as Effect makes `Either` a degenerate `Effect` (§2.4) — which also dissolves the
silent-wrong-answer hazard `fast-compiler.md` §3.2 point 3 found in beni's own checker, since there
would be nothing to speculate between.

**What it would not deliver, and what to budget for:**

1. **Source locations and stack traces** — the real bill, paid twice by Effect: `Effect.fn`'s two
   synthetic `Error`s and a rejected Babel plugin injecting per-yield locations (§3.4). A compiler
   can do better by attaching a location to each resume point at lowering time, but it must actually
   do it; diagnostic quality is a deliverable, not a freebie.
2. **`try`/`finally` semantics.** Effect abandons the generator on failure and never runs a `finally`
   (§2.4). beni's `Task` has no exceptions, so the analogue is resource cleanup and the answer must
   be a scoped `acquireRelease` in the runtime — which report 16 §1.4 already lists as missing from
   Elm's process record.
3. **Multi-shot is out**, permanently (Arnaldi, 2020). No backtracking, no list monad, no re-running
   a block from the middle. For `Task` that is not a loss; it forecloses a direction.
4. **Optimiser transparency (cross-cutting Q7).** A generator is opaque to beni's own inlining,
   dead-code elimination and renaming — `fast-compiler.md` §3.2's option-B row says so. §3.3 adds the
   counter-argument: the *runtime* gains visibility it did not have, because the whole block is one
   node it can drain in a loop rather than a chain of user closures it must walk. The trade is
   compile-time transparency for run-time transparency.
5. **The surface syntax is a separate decision from the compilation target.** Effect writes `yield*`
   because a library cannot invent a keyword; when its own team could, they chose `$(e)` — a marker
   in expression position, not a yield (§3.5). **Lowering a `do`-block to a generator does not oblige
   beni to expose `yield*` to users.**
6. **Half the ergonomic win is a language change, not a codegen change.** `Effect.gen` reads flat
   because a generator body is a *statement list*. beni is expression-based; a run of binds inside one
   `let … in` is already flat, but a branch is an expression, so a bind inside a branch nests
   whichever mechanism is chosen. **Generators buy arbitrary-position binds; statements buy flat
   reading; adopting one without the other delivers half the example in the shared brief.**

**What the people who built it would warn us about**, in their words. Arnaldi, TS+ post-mortem:
*"there wasn't anything there that couldn't be accomplished natively in TypeScript with a comparable
amount of syntax. Our enhancements looked cleaner to the untrained eye, but the syntactic
improvements were largely cosmetic."* That is a warning about *marginal* syntax over an
already-adequate baseline, and the baseline was adequate only because `yield*` existed. beni's
baseline is the `andThen` pyramid, which Effect's users have not had to write since 2020. The
transferable rule is narrower and sharper: **do not pay for syntax that only looks better; pay for
syntax that expresses something the old form could not.** By that test the bind inside a loop is the
whole case, and it is the one thing block-structured rewrites cannot do.

---

## 7. Ranked summary

1. `Effect.gen` demands **nothing** of the type system — only a covariant type and union inference
   over yielded values (documented, `dist/dts/Effect.d.ts:84-96`, `:5029`).
2. It is a **runtime protocol, not a desugaring**: the live iterator sits in an `OP_ITERATOR` node
   driven by the fiber's continuation table (documented, `internal/core.js:651-660`,
   `fiberRuntime.js:120-138`).
3. A bind inside a loop is expressible, and **no block-structured rewrite in the landscape can do
   it** (documented; report 15 §0).
4. Arbitrary-position binds come free, avoiding the 1,046-line hoisting pass Roc needed for the same
   property (documented; report 15 §0.2).
5. Effect's own team **built the language-level version (TS+) and killed it** for fork, tooling and
   "largely cosmetic" reasons — three of which do not apply to a language that owns its grammar
   (documented, Arnaldi 2025-07-03).
6. The generator **destroys the call stack and the source location**, and Effect paid for that twice:
   `Effect.fn`'s two synthetic `Error`s and a rejected build-time AST transform (documented,
   `Effect.js:10734-10832`; issue #5991).
7. On failure the fiber **discards the iterator frame without calling `return`/`throw`**, so a
   `finally` inside the block never runs (documented, `fiberRuntime.js:889-897`).
8. The dangerous newcomer errors are `yield` for `yield*` and a **floating effect that silently never
   runs** — both artefacts of effect values in statement position, both policed by an editor plugin
   rather than the type system (documented, 12 of 79 language-service diagnostics).
9. Generators are **one-shot only**; multi-shot needs O(n²) replay and was never shipped (documented,
   Arnaldi 2020-11-02).
10. In six years of production use practitioners complain about documentation, defect-vs-failure and
    ecosystem wrapping — **not about the generator syntax** (inferred from §5.2; the Discord could
    not be read, §8).

---

## 8. What could not be resolved

- **The Effect Discord**, where the gen-versus-pipe question was actually argued. AnswerOverflow (its
  public mirror) returned 403 to WebFetch and a Vercel bot check to `curl` with a browser user-agent;
  Reddit refused both its JSON API and WebSearch domain filtering. §5 therefore rests on code-search
  counts, official docs, GitHub threads and four named blog posts, and **no direct maintainer quote
  on gen-versus-pipe style was obtained** — only the docs' recommendation and the language-service's
  encoded opinion.
- **Whether union-based `E`/`R` inference is a real scaling problem in large codebases.**
  Practitioners named documentation and interop, never inference; Spiko's type-check-performance post
  mentions Effect only in passing and attributes nothing to it. Measuring it is forbidden here; it is
  measurable in an afternoon.
- **No maintainer statement on a *hypothetical* language-level bind syntax for a language they would
  own** — only the TS+ post-mortem, about a language they did not. Searched Arnaldi's and Smart's
  posts, the Effect blog archive, the release notes and the GitHub threads; closest is *"If we were to
  do anything at the language level again, we would need to work with a different file extension."*
  The Effect Days 2025 talks (*Building Effect 4.0*) are video only and were not transcribed.
- **Source-map fidelity through `tslib`'s `__generator` downlevelling.** No verified statement found;
  the landscape's `regenerator-and-tsc-downlevel` agent is better placed.
- **Why `Either`/`Option` lost their declared `[Symbol.iterator]` in the 3.22 `.d.ts` while
  `EffectPrototype` still carries it at runtime** (`internal/effectable.js:65`). Probably a late-v3
  alignment with v4, where `Result` replaces `Either`; no changeset found saying so, and *"v4 is not
  documented"* (MacWright, 2026-07-16).
