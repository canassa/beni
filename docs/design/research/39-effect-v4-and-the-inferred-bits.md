# Effect v4 and the two inferred bits

**Commissioned by** the owner's task of 2026-09-30: study Effect v4, the gold standard for effects,
before the checker infers `suspends` and `impure`. That inference step joins both bits through
calls, higher-order parameters, `where` evidence, `foreign pure | impure | suspends`, recursion and
interfaces — no lowering, no runtime, no `sync` check yet. The owner's 2026-09-30 decisions are not
reopened: both bits inferred, only `suspends` used in v1; well-known `eq`/`compare` must not
suspend; `main : Program` with a body that does not suspend; spawn/join/scope/bracket for the
runtime spike, all fifteen P2 §6.5 primitives for adoption.

**Relationship to reports 21–23**, which read Effect v4 whole — runtime
([21](21-effect-v4-runtime.md)), API ([22](22-effect-v4-api-surface.md)), semantics
([23](23-effect-v4-semantics.md)). This note repeats none of them and asks one narrower question:
**what does Effect's runtime say about the two bits** — which operations park a fiber, where
interruption and interleaving happen, and whether "impure" is one property or several.

**Citations.** `effect:<path>:<line>` is `references/effect/<path>`, `packages/effect` version
`4.0.0-rc.116`, the same checkout reports 21–23 cite; every line below was re-read for this note.
`effect.ts` alone means `effect:packages/effect/src/internal/effect.ts`. **P2** is
[`transparent-effects-proposal.md`](../transparent-effects-proposal.md); **the plan** is
[`plans/effects-plan.md`](../../../plans/effects-plan.md); **the decision sheet** is
[`plans/effects-decisions.md`](../../../plans/effects-decisions.md).

---

## 0. Findings

1. **Effect infers neither bit; beni copies nothing here, and P2 §2 is confirmed.** `Effect.sync`
   and `Effect.promise` both have type `Effect<A>` (`effect:packages/effect/src/Effect.ts:1169`,
   `:893`). Effect distinguishes a synchronous side effect from a suspension only at run time: the
   `callback` fast path (`effect.ts:1172`) and `runSync`'s `AsyncFiberError` when a fiber happens
   to park (`effect.ts:5733`). beni's bits are the static version of that distinction.
2. **Effect's atomic unit is one operation; beni's is the span between suspension points.** Effect
   delivers a latched interrupt before every operation (`effect.ts:667-670`) and may insert a yield
   before any operation (`:674-682`), so every `flatMap` boundary is an interruption and
   interleaving point. Under P2 §6.2 and §7.5 both happen only at suspension points, so **"may be
   interrupted" = "may interleave" = `suspends`; no third bit** — given two runtime rules (§9.2).
3. **Interruptibility is a runtime region, in Effect and in beni.** A flag plus a stack marker
   (`effect.ts:4484-4504`), not in the type. A region only removes interruption points, so it cannot
   change what the checker infers; P2 §9.1's "uninterruptible, not synchronous" need is met by the
   region primitive already decided.
4. **`impure` does not need splitting** (§9.3): a read/write split buys one optimiser permission,
   and Effect, with no optimiser, has no precedent. **But `pure` must mean "cannot throw or stop the
   program"**, since defects are fatal: `Debug.todo` is `impure`, or dead-binding elimination
   deletes a crash.
5. **`suspends` is "may", and Effect shows why.** A `callback` resumed before its register returns
   never parks (`effect.ts:1163-1172`), nor does joining a finished fiber (`:862`); `runSync`
   accepts whatever happened not to park *this time* (`:5729-5733`) — passes on a cache hit, dies
   on a miss. No "must suspend" inference; the sync step rejects "may".
6. **Spawning is `impure`, not `suspends`.** `forkChild` returns without the parent parking
   (`effect.ts:5442-5450`), even when the child starts inline (`:5464-5465`); the child's bits never
   reach the parent. Cancel-and-wait is `suspends` (`:925-930`). §9.1 classifies all fifteen
   primitives.
7. **Two questions the inference step must answer now, which Effect cannot, because it erases the
   information:** the bits of a function type (a) nested in a `foreign` signature — a thunk, `where`
   evidence — and (b) inside a **nominal type** — `Generator (Seed -> (a, Seed))`, a decoder, a
   wrapped capability record. Both fix what the interface records; (b) decides whether `suspends`
   saturates (§9.6, §9.7).

---

## 1. The fiber and its run loop

**Effect.** `FiberImpl` (`effect.ts:528-762`); `runLoop` (`:657-709`) checks a latched interrupt,
counts the operation, maybe inserts a yield, and evaluates (report 21 §3.2). **Verdict: adapt; it
does not touch the checker.** It interprets a data structure beni emits as code (report 21 §0.1).
The inference needs only *where* the loop can stop and *where* it checks for interrupts (§3, §4).

## 2. Synchronous side effects and suspensions

**Effect.** Five constructors, and only two of them can park the calling fiber:

| constructor | what it does | parks the fiber? |
|---|---|---|
| `sync(thunk)` | runs the thunk, passes the value to the next continuation (`effect.ts:975-982`); documented as *"a synchronous side-effectful computation"* (`Effect.ts:1130-1131`) | never |
| `suspend(f)` | calls `f` to build the next effect (`effect.ts:985-992`) — deferral, not suspension | never |
| `callback(register)` | hands `register` a one-shot `resume`; if `resume` ran before `register` returned, continues inline (`effect.ts:1163-1172`); otherwise installs the disarm thunk and a canceller frame and returns `Yield` (`:1173-1187`) | only if the answer is not ready |
| `promise(f)` | a `callback` over `.then` (`effect.ts:1097-1105`); `.then` never calls back synchronously | always |
| `yieldNow` | schedules its own resumption and parks (`effect.ts:1028-1043`) | always |

Every waiting operation in Effect — `Fiber.join`, `Fiber.await`, `Deferred`, `Semaphore`, `Queue` —
is built from `callback` (report 22 §0 finding 2). `fiberJoin` shows the pattern: a finished fiber
answers immediately (`effect.ts:862`); otherwise it registers an observer and parks (`:863-866`).

**Verdict: copy the classification — it is P2 §3.1's ladder, with no fourth rung.** `sync` is
`impure`; `callback`, `promise` and `yieldNow` are `suspends`; `suspend` is beni's thunk
`() -> a`. For platform authors: a `Promise`-based primitive takes the fast path only if it checks
its cache *before* creating the promise.

## 3. Yielding and the operation budget

**Effect.** `shouldYield` is `currentOpCount >= maxOpsBeforeYield`
(`effect:packages/effect/src/Scheduler.ts:184-186`), default 2048 (`:279-282`), switchable off
(`:305-308`), checked before **every** operation, inserting `yieldNow` (`effect.ts:674-682`). A
chain of `Effect.sync` calls is pre-empted, and another fiber may run between any two; under
`runSync` those yields are drained on the spot (`Scheduler.ts:171`, `effect.ts:5732`).

**Verdict: adapt, and keep the budget check at suspension points only.** P2 §7.5 counts suspension
points, and report 21 §3.5's trampoline return on the budget is also inside suspendable code. A
budget check on a loop back-edge or a plain call would make that function suspendable and spread
`suspends` to every loop — the saturation P2 §2 exists to avoid. The accepted cost: a long
computation that only computes or logs is never pre-empted (P2 §6.2; report 23 §3.1); code that
needs pre-emption calls `Task.yield`.

## 4. Interruption and interruptible regions

**Effect.** `interruptUnsafe` records the cause and then acts on it: if the fiber is interruptible
and parked, it resumes it at once with a failure; if it is running, it latches the interrupt
(`effect.ts:609-615`). The latch fires at the next operation (`:667-670`) or the next continuation
(`:714-717`). An uninterruptible region sets the flag and pushes a marker (`:4484-4492`). When the
marker is popped, the flag is restored and **a latched interrupt fires right there, at the end of
the region** (`:4494-4501`). `uninterruptibleMask` hands the body a `restore` (`:4550-4562`), and
`acquireUseRelease` uses it to leave `use` interruptible between an uninterruptible acquire and an
uninterruptible release (`:4346-4358`). Report 21 §4.1–§4.3 has the mechanics.

**Verdict: copy the region as a runtime mechanism** (the decision sheet has taken `uninterruptible`
+ `restore`), **with one change to where the latch fires** (§9.2). Effect's types carry no
interruptibility, and beni's should not either.

## 5. Scope, `acquireRelease`, `ensuring` / `onExit`

**Effect.** Two lifetimes (report 21 §0.3 item 2): a `Scope` runs its finalisers in reverse order
on close (`effect.ts:3941-3962`), `acquireRelease` registers there inside `uninterruptibleMask`
(`:4106-4122`), and `onExit` is a stack frame whose handler runs uninterruptibly by default
(`:4137-4174`, flag at `:4148-4153`). **Finalisers are effects and may suspend**: sequential
closing waits for each (`:3953`); parallel closing forks and awaits them (`:3955`, `:3959`).
**Verdict: adapt (report 21 §5); for the bits, nothing new** — §9.4.

## 6. Structured concurrency

**Effect.** All four fork forms (`effect.ts:5418-5596`) end in `forkUnsafe` (`:5454-5474`): build
the child, run it now or schedule it (`:5464-5468`), attach it unless detached, return. **The
parent never parks.** **Verdict: adapt (report 21 §5.2, report 23 §3.12).** Every `spawn` form is
`impure`, and its thunk runs in another fiber, so the thunk's bits must not join the caller's
(§9.6). With `startImmediately` the child runs *during* the parent's call — an ordinary impure
call from the parent's side (it may change a `Ref`), not a hidden interleaving.

## 7. `Exit` and `Cause`

**Effect.** `Exit` is `Success | Failure` (`effect:packages/effect/src/Exit.ts:59`); a cause is a
flat list of `Fail | Die | Interrupt` (`effect:packages/effect/src/Cause.ts:144`). **Verdict:
already decided differently** — the owner's `Exit a = Done a | Cancelled`, defects fatal,
finalisers infallible. For the bits: a throwing `foreign` ends the program, which is observable, so
it cannot be `pure` (§9.3).

## 8. `Context` and services

**Effect.** `Clock` and `Random` are context references with defaults
(`effect:packages/effect/src/Clock.ts:189`, `effect:packages/effect/src/Random.ts:69`), read
through the fiber (`Random.ts:71-72`), each with a synchronous `…Unsafe` twin (`Clock.ts:65`,
`Random.ts:30-34`), as `Ref` has (`effect:packages/effect/src/Ref.ts:747`); the effectful
`Ref.get`/`set`/`update` are plain `Effect.sync` (`Ref.ts:200`, `:239`, `:613`). **Verdict: already
decided** — records of functions and `where` clauses, plus three fixed per-fiber slots. Reading a
slot is `impure` (the answer depends on which fiber asks); running a thunk under an overridden slot
is "`suspends` iff the thunk does". The records of functions raise §9.7.

---

## 9. The bits

### 9.1 Which primitives are on which rung

"Parks" means the calling fiber may return to the scheduler. The rung is what the platform writes
if the operation is a `foreign`. "Inferred" means the operation should be written in beni over
first-order foreigns, so that the checker computes its bits (§9.6).

| beni operation | Effect analogue | parks? | rung |
|---|---|---|---|
| `sleep`, `Task.yield` | `Clock.sleep` (`Clock.ts:148`), `yieldNow` (`effect.ts:1028-1043`) | always | `suspends` |
| `httpSend` / `fetch` | `promise` (`effect.ts:1097-1105`) | always | `suspends` |
| `Fiber.join`, `Fiber.await` | `fiberJoin`, `fiberAwait` (`effect.ts:860-867`, `:813-822`) | unless the fiber is done | `suspends` |
| `Fiber.cancel`, waiting for cleanup (the owner's default) | `fiberInterruptAs` = interrupt, then await (`effect.ts:925-930`) | yes | `suspends` |
| a cancel that does not wait, if one ships | `interruptUnsafe` (`effect.ts:595-616`) | no | `impure` |
| `Task.spawn`, `Scope.spawn`, a detached spawn | `forkChild` / `forkIn` / `forkDetach` (`effect.ts:5442-5450`, `:5555-5568`, `:5501`) | no | `impure`; the thunk's bits do not reach the caller |
| `Task.scope` | `scoped` (`effect.ts:4073-4082`) + waiting for children | yes, at exit | inferred (it calls `join`) |
| `bracket`, `uninterruptible`, `retry` with a count | `acquireUseRelease`, `uninterruptible` (`effect.ts:4346-4358`, `:4484-4492`) | only if a thunk does | inferred; if written as a `foreign`, `suspends` |
| `par2`, `parAll`, `race`, `timeout` | built from fork and observers (report 21 §0.4) | yes | inferred (spawn + join) |
| `Semaphore.with`, `Queue.take`, `put` on a bounded `Queue`, `RateLimiter.with` | `callback` waiters (report 21 §5.6) | if they must wait | `suspends` |
| `put` on an unbounded `Queue` | an `Effect.sync` push | no | `impure` |
| `Ref.get`, `Ref.set`, `Ref.update` | `Effect.sync` (`Ref.ts:200`, `:239`, `:613`) | no | `impure` |
| `now`, the random seed source, a read of a per-fiber slot | `Clock.currentTimeMillisUnsafe`, `randomWith` (`Clock.ts:65`, `Random.ts:71-72`) | no | `impure` |
| a seeded PRNG step, `posixToMillis`, formatting | none — pure functions | no | `pure` (report 17 §4.9) |
| `console.log`, `Debug.log` | the `Effect.sync` example (`Effect.ts:1153-1156`) | no | `impure` |
| `Debug.todo` (`core/Debug.beni:32`) | `die` | no; ends the program | **`impure`** (§9.3) |

### 9.2 Is "may be interrupted" a third bit? No — given two runtime rules

In Effect, "can this code be interrupted, or can another fiber run here?" is answered "at every
operation" (§3, §4), which is why it needs regions for any sequence that must hold together. Under
P2 the points are the calls that may park — the `suspends` bit — and regions only take points
away. So per function, "may be interrupted" = "may interleave" = `suspends`, provided the runtime
spec states two rules:

- **Rule 1 — the budget check lives only at suspension points** (§3).
- **Rule 2 — an interrupt that arrives while the fiber runs, or inside an uninterruptible region,
  is delivered at the fiber's next suspension point, not when the region ends.** Effect fires it at
  region end (`effect.ts:4498-4500`); in beni that would make leaving a region an interruption
  point, and `uninterruptible (\() -> pureSequence)` would have to be `suspends`. The two differ
  only if non-suspending impure code runs between region end and the next suspension point, and
  "interruption only where the code can suspend" is the stronger promise. Report 21 §4.3's latch
  is unchanged; only its delivery point moves.

With rule 2, deliver the latch at the return of **every** call to a suspending callee, fast path
included — Effect's next operation checks it the same way (`effect.ts:667-670`). Then the
interruption points are exactly the calls the checker marks `suspends`, which is what editor
colouring shows (P2 §9.1), not a cache-dependent subset.

**For the inference step: no third bit, no interface field for interruptibility.** P2 §9.1's
"must not suspend" versus "must not be interrupted" is a real distinction, but the second belongs
to a sequence at a call site, and a runtime region is the tool for it, in Effect and in beni.

### 9.3 Does `impure` need a finer grain?

The optimiser P2 §5 describes may do four things to a call: drop it when its result is unused,
duplicate it (inline a binding used twice), move it past another call, or reuse one result for two
calls. Sorting the `impure` rows of §9.1 by what each of those would break:

| class | examples | drop if unused | duplicate / reuse | move past a write |
|---|---|---|---|---|
| reads whose answer can change | `now`, seed source, `Ref.get`, DOM read, per-fiber slot | safe | unsafe | unsafe |
| writes and terminations | `log`, `Ref.set`, `Debug.todo`, `httpSend` | unsafe | unsafe | unsafe |

A split buys one permission — dropping an unused read — which source code rarely needs and which
saves one host call when inlining creates it. Effect offers no counter-evidence: it has no
optimiser, and its only purity distinction is the `…Unsafe` hatch that effect-as-value forces.
The split's cost is a fourth keyword rung; its interface bit would only be a format bump (the M4
decision makes a bump a cache discard, `plans/effects-spike.md` §2.2). **Recommendation: one
`impure` bit, no reserved split**; revisit only on a measurement of unused reads in real output.

**One contract fix for the inference step.** Defects are fatal, so a throwing `foreign` ends the
program, observably, and the dead-binding pass (`src/js/Opt.zig`) deletes unused bindings with
neither bit. So **`pure` must mean total and non-throwing**: a `foreign` that can throw or stop
the program is at least `impure`, and `Debug.todo` (`core/Debug.beni:32`) is `impure` — the plan's
"`Debug.log` is the only `impure` value" becomes "`log` and `todo`". Divergence in pure beni code
stays untracked, as in Elm: a pure call that never returns may be dropped when unused. P2 §5
should say so.

### 9.4 Finalisers and release actions that suspend

Effect lets a finaliser suspend and runs it uninterruptibly (§5); the owner took the same shape
(infallible `-> ()`, uninterruptible, suspending allowed). **No new bit.** A beni-written
`bracket` calls `release` on its success path, so the release's `suspends` is joined already; the
cancel path is the runtime calling the release during unwind — §9.6's case (ii), which constrains
nothing the caller infers. The costs are run-time ones (a slow release delays the cancel, report 23
§2.5) and P2 §6.3's bounded shield answers them later.

### 9.5 The fast path, and `suspends` as "may"

A primitive that completes synchronously keeps its rung. The evidence that the bit has to be
"may": Effect built the fast path into `callback` (`effect.ts:1163-1172`), `fiberJoin` (`:862`) and
`fiberAwait` (`:817`), and its one run-time check, `runSync`, fails only if a fiber *actually*
parked (`:5729-5733`). That is the "must" reading, and it is exactly the failure P2 §3.2 describes:
code that passes when a cache hits and crashes when it misses. So:

- a `foreign` that can park even once is `suspends`, however rarely it does; one that never parks
  is `impure`, and declaring it `suspends` only colours its callers for nothing;
- the checker never infers "must suspend", and no diagnostic depends on it;
- the fast path belongs to the lowering (P2 §7.2) and is invisible to the checker;
- the sync step rejects "may suspend". It must not become a run-time check shaped like `runSync`.

### 9.6 Function types nested inside a `foreign` signature

The rung describes the declaration's outer arrow (P2 §3.1). A `foreign` can also mention function
types *inside* its signature: `spawn`'s thunk, a finaliser callback, the evidence of
`List.eq`'s `where a.eq` (the plan §2.1). Effect has no equivalent, because the child of
`forkChild` is a value and its type records nothing about suspending (`effect.ts:5433`).

**Recommendation for the inference step:** the rung constrains nothing about nested arrows; they
get independent bits, and a call joins only the rung into its caller. Fresh generalised variables
or a constant "anything" in parameter position both do this (equivalent under P2 §4.4's
subsumption; the constant costs no interface word). Sound for (i) a callback run in another fiber
(`spawn`), (ii) one the runtime runs later (a finaliser push), (iii) a `foreign` that is
`suspends` anyway (`Semaphore.with`). **Unsound** for one kind: a callback JavaScript calls
synchronously in the current fiber expecting a value — host callbacks and the evidence
`core/List.js`'s loops call. That is the sync step's case; the owner has already ruled that
well-known `eq`/`compare` must not suspend, and Effect agrees: its `Order` and `Equal` are plain
synchronous functions (`effect:packages/effect/src/Order.ts:53-55`,
`effect:packages/effect/src/Equal.ts:109-111`). The spec should state the gap, not hide it.

**Corollary, for later steps:** combinators that run a thunk in the current fiber — `bracket`,
`uninterruptible`, `retry`, `Semaphore.with`, `timeout`'s body — should be beni over first-order
foreigns, so their bits are inferred as "suspends iff the thunk does". As `foreign`s they must be
`suspends`, and `uninterruptible` around a pure sequence would colour its caller for nothing.
Effect is built the same way: everything over `callback` plus a cell (report 22 §0, report 21 §0.4).

### 9.7 Function types inside a nominal type declaration

Not in P2, and it matters now because the interface is being bumped now. A record alias is
structural — `type alias Payments = { charge : Cents -> Receipt, … }` (P2 §9.3) expands, and its
arrows get whatever inference gives them at each use. A function inside a **constructor** is fixed
at declaration: `type Generator a = Generator (Seed -> (a, Seed))` (report 17 §4.9), a decoder, a
capability record behind an opaque type — and records of functions are the owner's mechanism for
services. Effect gives no guidance: a service method returns an `Effect`, "may do anything" by
construction. Three options:

- **constant "suspends"** — sound, but every `Random.step` and decoder run colours its caller:
  P2 §2's saturation, through the standard library;
- **constant "pure", checked where the function is stored** — sound, reuses the sync step's
  machinery, but forbids a suspending capability inside a type, which is the use case;
- **hidden flag parameters on the type**, instantiated at each use like a type variable (Koka's
  answer) — precise, at a cost in interface space and arity; cheapest as one pair per declaration
  that contains an arrow, shared by all its arrows.

**Recommendation: the third, one pair per type, decided before the interface bump.** Only it keeps
`suspends` sparse and lets a capability suspend. This comes from beni's constraints, not Effect.

---

## 10. What does not transfer

**Effect as a value** — the reason Effect needs `suspend`, `sync`, `…Unsafe` twins and an
interpreter, and the reason its types carry no bit (report 21 §0.1). **Generators** — beni
sequences with `let` (P2 §7.1, report 21 §2.5). **The type-level `R` and `E` channels** — `E` is
`Result`; `R` is conceded (report 22 §3.3). **Pipeable and dual APIs** — a TypeScript tax
(report 22 §7.4). **The per-operation interrupt check and pre-emption** — §9.2.

## 11. Recommendations

**For the inference step, now:**

1. Infer exactly two bits. No interruptibility bit and no read/write split (§9.2, §9.3).
2. The rung vocabulary stays at three (`pure | impure | suspends`); Effect has no fourth kind of
   primitive (§2).
3. Write into P2 §3.1: **`pure` means total and non-throwing**; a `foreign` that can throw or stop
   the program is at least `impure`. Declare `Debug.todo` `impure` (§9.3).
4. Write into P2 §4.2: `suspends` is "may park"; there is no "must" (§9.5).
5. Write into P2 §4.2: a `foreign`'s rung constrains only its outer arrow. Nested arrows get
   independent bits, and a call joins only the rung. Record that this is unsound for callbacks
   JavaScript calls synchronously until the sync step lands (§9.6).
6. Decide the bits of arrows inside constructor arguments before the interface bump — recommended:
   one hidden flag pair per type declaration that contains an arrow (§9.7).
7. Use §9.1's table as the reference for fixtures: `spawn` is `impure`; `join`, `await`, a waiting
   `cancel`, `sleep` and `yield` are `suspends`; `Ref` operations, `now` and the seed source are
   `impure`.

**For the later steps:**

8. The lowering and runtime spec states §9.2's two rules: the budget check only at suspension
   points; a latched interrupt delivered at the next suspension point (including after a fast
   path), not at the end of a region.
9. The primitive list: write `bracket`, `uninterruptible`, `retry`, `scope`, `par2`, `race` and
   `timeout` in beni over first-order kernel foreigns, so their bits are inferred (§9.6).
10. The sync step rejects "may suspend", checks nested arrows in `foreign` signatures where the
    platform demands a value now, and never becomes a `runSync`-shaped run-time check (§9.5).
11. The optimiser step: `impure` blocks all four transformations; revisit the read/write split
    only on a measurement of unused reads in real output (§9.3).

---

## 12. Evidence index

Effect v4, `references/effect/packages/effect/src/`, `4.0.0-rc.116`, read for this note:

- `internal/effect.ts` `:528-1227` (fiber, run loop, join/await/interrupt, `sync`, `suspend`,
  `yieldNow`, `promise`, `callback`), `:3900-4358` (scope, `acquireRelease`, `onExit`,
  `acquireUseRelease`), `:4478-4577` (regions), `:5418-5596` (forks), `:5700-5753` (`run*`),
  `:6303-6311` (`clockWith`, `sleep`).
- `Effect.ts` `:893`, `:1130-1229`, `:1735`; `Scheduler.ts` `:93-113`, `:162-222`, `:265-308`;
  `Clock.ts` `:51-79`, `:148`, `:189`; `Random.ts` `:26-34`, `:69-72`; `Ref.ts` `:173-747`;
  `Cause.ts` `:144`; `Exit.ts` `:59`; `Order.ts` `:53-55`; `Equal.ts` `:109-111`.

This repository: P2 §2, §3.1, §3.2, §4, §5, §6, §7.2, §7.5, §9.1–§9.3, §11 Q6; the plan §1, §2.1,
§2.5, §3, §5; `plans/effects-decisions.md` (the owner's 2026-09-19 answers);
`plans/effects-spike.md` §2.2; reports 21 §0, §3.2–§3.5, §4; 22 §0; 23 §0; 16 §5.4–§5.5; 17 §4.2,
§4.8–§4.10, §4.14, §6.1, §6.5; `core/Debug.beni`.
