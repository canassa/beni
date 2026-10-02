# The fiber runtime against Effect v4: a parity ledger

**Commissioned by** the owner, 2026-10-02: *"The fiber/async runtime needs feature/quality parity
with effect."* Effect v4 is the gold standard; beni aims at its quality and API coverage while not
inheriting what Effect does only because it lives in TypeScript — generators, type-level encodings,
the `R` channel of `Effect<A, E, R>` where transparent effects and plain functions already do the
job.

**What this is.** One row per Effect v4 capability area, read from Effect's source: what Effect
provides, what beni has today, a status, and the beni shape that reaches parity. The prioritised
slice plan that follows from it is appended to [`plans/effects-plan.md`](../../../plans/effects-plan.md)
as §8. This report specifies nothing: each slice writes its contract into
[`transparent-effects-proposal.md`](../transparent-effects-proposal.md) (**P2**) before its code
(`CLAUDE.md` rule 1). It re-reads reports [21](21-effect-v4-runtime.md) (runtime),
[22](22-effect-v4-api-surface.md) (API surface), [23](23-effect-v4-semantics.md) (78 semantic
cases), [43](43-effect-v4-and-the-inferred-bits.md) (the bits), [44](44-effects-runtime-spike.md)
(the spike, measured) and [45](45-effects-in-a-browser-program.md) (commands and subscriptions)
against the tree as it stands at `84a49831`, and repeats their evidence only where a row needs it.

**Decisions already taken are not reopened.** From
[`plans/effects-decisions.md`](../../../plans/effects-decisions.md) and the effects plan §5:
defects are fatal and `Exit a = Done a | Cancelled` (A1, re-confirmed as `boundary.md` §9.8.14
choice 1); `join` propagates, `wait` observes (A2); a `bracket` release sees the `Exit` (A3);
`impure` is used (A5); `sync` shipped (A6); services are records of functions and `where` clauses,
with a few fixed per-fiber slots and no general `Context` (A7); `main : Program` stays and its body
does not suspend (A8); a well-known `eq`/`compare` does not suspend (A9); combinators return only
after their losers' cleanup (A10); children are cancelled before a parent's own finalisers run
(A11); the adoption ships all of P2 §6.5's primitives (plan decision 3). The yield budget of 64 was
measured in Chrome by report 44 §3. Open and answered here as recommendations: A4 (`retry` takes a
`Schedule`), A12 (the primitive-list amendments), A13 (deterministic time) and A16 (a logger).

**Citations.** `effect:<path>:<line>` is `references/effect/<path>` at `4.0.0-rc.116`, the checkout
reports 21–23 cite; every line cited below was re-read for this report. `Effect.ts` alone is
`effect:packages/effect/src/Effect.ts` (the public declaration, where the doc and the signature
are); `effect.ts` alone is `effect:packages/effect/src/internal/effect.ts` (the implementation).
Other modules are `packages/effect/src/<Module>.ts`, written `<Module>.ts:<line>`.

---

## 0. Findings

1. **The kernel is at parity; the library on top of it is not there yet.** Every mechanism Effect's
   concurrency rests on — a one-shot suspension with a canceller, prompt interruption of a parked
   fiber, latched interruption, uninterruptible regions, LIFO finalisers that see the outcome,
   parent/child structure, scopes, cancel-and-wait — is in `core/Task.js` and measured faster than
   Effect's (report 44: a fast-path suspension point 2.4 ns against `flatMap`'s 97.8 ns, a park
   125 ns against 1 527 ns, 2 114 B brotli against 26 878 B). What is missing is almost all
   **library code over that kernel**: `par`/`forEach`, `race`, `timeout`, `Schedule` with `retry`
   and `repeat`, `Deferred`, `Ref`, `Semaphore`, `Queue`, `Latch`, `PubSub`, logging with
   annotations, spans. Of the 50 rows of §2, **11 are at parity (7 of them better than Effect),
   14 partial, 19 missing, and 6 not applicable** by a decision or because the language already
   does the work; of the 19 missing, 9 are the app-blocking rows the plan's first slices take.

2. **Nobody but a platform can write a coordination primitive today, and that is a rule-7 gap.**
   `Task.callback` is public, but the `Resume a` it hands out can only be *called* through `Js`
   (`Js.apply (Js.from resume) [ … ]`, as `platforms/browser/Http.beni` does), and `Js` is refused
   outside core and the platforms (`js_outside_platform`). Nor is there a mutable cell outside `Js`
   (`Js.Ref`). So an application cannot write a `Deferred`, a `Queue` or a `Semaphore` — the
   things report 22 §0 finding 2 calls "writable by an ordinary developer once the kernel exists".
   The kernel exists; two functions are withheld: **`Task.resume : Resume a, a -> ()`** and a
   public **`Ref`**. With them, every row of §2.5 is ordinary beni.

3. **A Node program can exit 0 having done nothing.** `Io.run` hands `main` the empty program, whose
   `runtime.js` sets `process.exitCode = 0`; the fiber's own `finish` overwrites it only when the
   fiber ends. A fiber parked on something no host handle will ever answer — a `Task.callback`
   whose register keeps its `Resume` and never calls it, writable today; a `Deferred` nobody
   completes, the moment `Deferred` exists — lets Node's event loop empty, and the process exits
   **0 with no output** (§2.10, verified by the program in §6). That is decision A8's
   *"never a silent exit 0"*, not yet built. Effect answers it by keeping the process alive forever
   (a reference-counted keep-alive, report 22 D9); beni can do better, because it knows when every
   fiber is parked and nothing can wake one: report it and exit 1.

4. **beni has no failure channel, so Effect's combinators split in two.** Effect's `race` is "first
   to *succeed*" (`effect.ts:1712`, `Effect.ts:4847`) and `all` is fail-fast on the first failure
   (`Effect.ts:492`, report 23 case 3.2), because failure is a channel. In beni a failure is an
   `Err` inside `a`, invisible to a combinator that does not look for it. So each combinator whose
   Effect semantics depend on failure comes in two forms: a plain one (`race` — first to *return*;
   `forEach` — every element) and a `Result`-aware one (`raceOk` — first `Ok`, every `Err` kept
   when none succeeds; `forEachOk` — the first `Err` cancels the rest and waits for their cleanup).
   This is the only systematic API divergence the ledger recommends, and it is forced (§5 item 4).

5. **Deterministic time is the slice everything else's tests wait on.** The browser test driver
   already virtualises `setTimeout` and `Date` for pages (`tests/corpus/README.md`, *The page's clock
   is virtual*), but the `node` platform's `run/` corpus has nothing, and `Io.sleep` takes a bare
   `Int` while the browser's `Time.sleep` takes a `Time.Duration`. Effect's `TestClock`
   (`testing/TestClock.ts:507` `adjust`) made a ten-hour retry schedule a sub-200 ms test (report 23
   case 5.5). The proposal is A13's: **`Duration` in core, one `Task.sleep` that reads a clock slot
   on the fiber, and `Clock.virtual`/`adjust`/`run` in core**, so a `run/` fixture can test
   `timeout`, `retry` and a debounce by order alone, with no wall time in a golden.

6. **Effect's `Cause` is not the target; its *report* is.** A1 decided that a defect is not a value
   and §9.8.14 (l) keeps that, listing where beni departs from `Cause` and why. What Effect does
   better is what a developer *sees*: `Cause.pretty` (`Cause.ts:1115`) renders the failure with the
   fiber's span stack (`effect.ts:466-489`, `Effect.fn`'s frames). beni's defect today is the host's
   stack, which after a park shows `Task.js`'s run loop, not the code that suspended. Parity is a
   **logical stack trace in development builds** — the parked fiber's continuation chain and spawn
   sites, mapped through the development source maps that landed on 2026-10-01 — at zero cost in
   release. P2 §7.4 promised it; nothing has built it.

7. **Effect's largest families shrink to almost nothing here, each for a stated reason.** `R`,
   `Layer` and `Context` are not applicable: records of functions and `where` clauses do their work
   (A7). `Effect.gen` is beaten, not copied: direct style has no generator step to pay (67–82 ns in
   Effect, report 21 §9.1; 2.4 ns for beni's fast path). `FiberRef`'s general mechanism, which
   Effect itself demoted to `Context.Reference` in v4 (`Context.ts:1325`), becomes three or four
   fixed fiber slots — missing today, built by the slices that need them (clock, log context,
   seed). `Config` is a `Schema` plus an environment reader, and beni has the first.

8. **Three pieces of other work touch this plan, and none contradicts it** (§4): the defect
   teardown (`boundary.md` §9.8.14, landed) supplies the root registry every detached fiber must
   join; HTTP v2 (§9.8.12, landed) takes a `Time.Duration` that moving `Duration` to core turns
   into an alias; and the study moving `core/Task.js` into beni (`plans/core-in-beni.md` step 2) is
   where the few kernel additions — `resume`, the clock slot, `uninterruptibleMask`, detached
   spawn — should land, so they are written once.

---

## 1. How to read the ledger

**Status.** **have** — beni does what Effect does, possibly under another name or better.
**partial** — some of it, or the mechanism without the API. **missing** — nothing yet.
**n/a** — not applicable, with the reason: a decision the owner took, or something beni's
language already does so that no library is wanted.

**Parity means capability and quality, not export count.** Report 22 counted Effect's 4 783
exports and found ~2 % of them cover what its effect, concurrency, resource and scheduling families
do, because direct style, `Result` with `?`, exhaustive `case`, derived `eq`/`compare` and `|>` as
syntax delete the rest at the language level. A row is at parity when a beni program can do what an
Effect program does with that capability, with the same guarantees, at no worse cost.

**Shapes** follow `language.md`'s rules: subject first, function last, every call saturated, no
currying; a thunk `() -> a` wherever Effect takes an `Effect` value (P2 §6.5: never a started
computation); effects inferred, so no signature says `suspends` except a `foreign`'s; Elm's names
where Elm has the concept (`Process.sleep` → `Task.sleep`, `Process.kill` → `Task.cancel`, already
taken); otherwise Effect's names, with `wait` for Effect's `await` (a reserved word in JavaScript,
the precedent `Task.wait` set). A nullary method cannot be dot-called (`static-dispatch-spike.md`
§1.1), so these are qualified calls: `Task.join fiber`, `Queue.take q`.

---

## 2. The ledger

### 2.1 Fibers, structure and scopes

| Area | Effect v4 provides | beni today | Status | Proposed beni shape |
|---|---|---|---|---|
| **Fork and join** | `Fiber.join` propagates (`Fiber.ts:304`), `Fiber.await` returns the `Exit` (`Fiber.ts:185`, exported `:222`), `joinAll`/`awaitAll` (`:330`, `:260`), `interrupt` waits for cleanup (`:379`), `interruptAll` (`:472`), `id` and `pollUnsafe` on the record (`Fiber.ts:74`, `:86`) | `Task.spawn`, `join` (propagates), `wait` (observes), `cancel` (waits), `running`, `yieldNow` — `core/Task.beni` | **partial** | add `Task.poll : Fiber a -> Maybe (Exit a)`, `Task.joinAll : List (Fiber a) -> List a`, `Task.cancelAll : List (Fiber a) -> ()` (interrupt all, then wait for all, as `effect.ts:934`). No fiber id in the API: a log line or a trace names a fiber by its spawn site (§2.10) |
| **Fork variants** | `forkChild` (`Effect.ts:8578`), `forkDetach` (`:8704`), `forkIn` (`:8621`), `forkScoped` (`:8664`), each with `startImmediately` and `uninterruptible` options (`:8580-8584`); `awaitAllChildren` (`:8743`) | `spawn` (child), `spawnIn` (a scope), `openRoot`/`start` for a platform | **partial** | add **`Task.spawnDetached : (() -> a) -> Fiber a`**, Effect's `forkDetach`: the fiber outlives its parent and is a root in `Task.js`'s registry, so `Task.shutdown` reaches it (§4.1). `forkScoped` is `spawnIn`. **No `startImmediately` knob** unless measured: Effect's scheduled start costs a *macrotask* (6.7×, report 21 §9.2), beni's a microtask drain (report 44 §3) |
| **Supervision** | v4 deleted `Supervisor`, `FiberStatus` and the global registry (report 21 §8.4) and named `FiberSet` (`FiberSet.ts:56`), `FiberMap` (`FiberMap.ts:60`) and `FiberHandle` (`FiberHandle.ts:57`) as the replacement | children cancelled when their parent ends (`Task.js` `finish`); `browser-tea`'s keyed command table is a `FiberMap` written for one purpose (`platforms/browser-tea/Tea.beni`) | **partial** | structure is at parity. `FiberMap k a` and `FiberSet a` in core as T2 library code over `spawnIn` and `wait` (`run`, `get`, `cancel`, `size`, `waitEmpty`); `Tea`'s table may later be re-expressed over `FiberMap` (not required) |
| **Scope** | `Scope.make` (`Scope.ts:240`), `addFinalizer`/`addFinalizerExit` (`:382`, `:348`), `fork` (`:415`), `close` with an `Exit` (`:493`), `use` (`:542`); finalisers LIFO, each one's failure collected (`effect.ts:3935`, `:3941`); a finaliser added to a closed scope runs at once (report 23 case 4.3) | `Task.scope` (children cancelled and awaited at the end), `spawnIn`, `openRoot`/`closeRoot` | **partial** | `Task.scope` is `Scope.use`. Missing: a finaliser on a scope rather than a fiber — **`Task.defer : Scope, (Exit () -> ()) -> ()`**, run LIFO when the scope closes, at once if it has closed — for a resource whose lifetime is a scope's, not an expression's (report 21 §0.3 item 2: two lifetimes, two mechanisms) |
| **Finalisers on an expression** | `acquireRelease` (`Effect.ts:6589`), `acquireUseRelease` (`:6721`), `ensuring` (`:6815`), `onExit` (`:6987`), `onError` (`:6852`), `onInterrupt` (`:7354`); `onExit` is a stack frame (`effect.ts:4177`) | `Task.bracket : (() -> r), (r, Exit a -> ()), (r -> a) -> a`, acquire and release uninterruptible, release told `Done`/`Cancelled` | **have**, one spelling short | `acquireUseRelease` is `bracket`. Add **`Task.onExit : (() -> a), (Exit a -> ()) -> a`** — `bracket` with no resource — for `ensuring`/`onExit`/`onInterrupt` (a `case` on the `Exit`). `onError` is n/a: an error is an `Err` the body returns, read with a `case` |

### 2.2 Failure and interruption

| Area | Effect v4 provides | beni today | Status | Proposed beni shape |
|---|---|---|---|---|
| **Exit and Cause** | `Exit` = `Success \| Failure(Cause)` (`Exit.ts:59`); `Cause` a flat list of `Fail \| Die \| Interrupt` reasons (`Cause.ts:75`, `:144`) with annotations (`:1720`) and stack traces (`:1815`), `combine` (`:692`), `squash` (`:736`), `pretty` (`:1115`); v3's sequential/parallel tree deleted (report 21 §6.2) | `Exit a = Done a \| Cancelled`; a typed failure is an `Err` in `a`; a defect ends the program with the host's report | **n/a by decision** (A1; `boundary.md` §9.8.14 (l)) | no `Cause`. A finaliser cannot fail (`-> ()`), so `Fail + Die` (report 23 case 1.4) cannot arise from beni code; a throwing `foreign` in a finaliser is a second, separate host report (§9.8.14 (g)). The quality half — what the developer sees — is §2.10's *defect reports* row |
| **Interruption semantics** | an interrupt resumes a parked fiber through its canceller frame (`effect.ts:1218`, report 21 §4.1); latched while running (`_deferredInterrupt`, `effect.ts:545`, `:611`, `:667`); cancel-and-wait | the same: canceller from `Task.callback`, `interrupted` latched and delivered at the next suspension point, `cancel` waits (`core/Task.js`) | **have** | — . Effect delivers a latched interrupt before *every* operation; beni only at suspension points, which report 43 §0 item 2 shows is the right reading of "may be interrupted" for a compiled language |
| **Masks** | `uninterruptible` (`Effect.ts:7387`), `interruptible` (`:7326`), `uninterruptibleMask` with `restore` (`:7422`; `effect.ts:4550`), `interruptibleMask` (`:7459`) | `Task.uninterruptible : (() -> a) -> a`; `bracket`'s use is interruptible between two masked ends | **partial** | add **`Task.uninterruptibleMask : (Restore -> a) -> a`** and **`Task.restore : Restore, (() -> b) -> b`**: a token rather than a polymorphic function argument, so no rank-2 type is needed. `interruptibleMask` is the same with the roles swapped and is not needed: `restore` inside a mask is the only interruptible region beni code can ask for |
| **`disconnect`** | **gone in v4** (report 23 case 3.9) | — | **n/a** | Effect removed it; a `timeout` around work that should finish in the background is `spawnDetached` plus `timeout` on its `wait` |
| **Self-interruption** | `Effect.interrupt` (`Effect.ts:7307`); catchable when self-inflicted, not when external (report 23 case 2.16) | joining a cancelled child cancels the joiner (`selfCancel`); `Task.cancel` of the current fiber | **have** | uncatchable in both directions: there is nothing to catch with (A1). `Task.wait` is how a parent observes a child's cancellation without being cancelled |

### 2.3 Concurrency combinators

| Area | Effect v4 provides | beni today | Status | Proposed beni shape |
|---|---|---|---|---|
| **`all` / `forEach` with concurrency** | `Effect.all` over tuples, records and iterables with `concurrency`, `discard` and `mode: "default" \| "result"` (`Effect.ts:492`, options `:497-499`); `forEach` (`:777`); `validate` (`:621`), `partition` (`:533`); all built on `iterateConcurrentImpl` with a fast path that forks nothing (`effect.ts:4981`); the first failure interrupts the siblings and **waits for them** (report 23 case 3.2); results in input order | nothing; `List.map` with a suspending callback runs sequentially, in source order | **missing** — app-blocking | **`Task.par : (() -> a), (() -> b) -> ( a, b )`**, **`par3`**; **`Task.forEach : List a, Int, (a -> b) -> List b`** — the bound is mandatory (P2 §6.5; `List.length xs` is "unbounded"), results in input order; **`Task.forEachOk : List a, Int, (a -> Result e b) -> Result e (List b)`** and **`Task.parOk`** — the first `Err` cancels the rest and returns only after their cleanup (A10). `validate`/`partition` are `forEach` then `Result` functions (§2.9) |
| **`race`, `raceAll`, `raceFirst`, `raceAllFirst`** | `race` = first to succeed, losers interrupted and awaited (`Effect.ts:4847`, `effect.ts:1712`); `raceFirst` = first to settle (`:4904`); `raceAll` / `raceAllFirst` over an iterable (`:4771`, `:4807`); a failure does not end a `race` (report 23 case 3.5) | nothing | **missing** — app-blocking | **`Task.race : (() -> a), (() -> a) -> a`** and **`Task.raceAll : (() -> a), List (() -> a) -> a`** — first to *return* wins (Effect's `raceFirst`; there is no failure channel to skip), the others cancelled and awaited (A10); the first argument makes the list non-empty by construction. **`Task.raceOk : List (() -> Result e a) -> Result (List e) a`** — Effect's `race`: the first `Ok` wins; when every branch returns `Err`, all of them, in argument order (report 23 row 31). A branch that is cancelled never wins; if all are, the racing fiber is cancelled |
| **`firstSuccessOf`** | sequential: try each in turn until one succeeds (`Effect.ts:4519`, `effect.ts:3433`) | — | **n/a** (free) | a `List` fold with `?`, or a `case`; no combinator wanted |
| **`timeout`** | `timeout` fails with `TimeoutError` (`Effect.ts:4564`, `effect.ts:3836-3840`, `Cause.ts:1391`); `timeoutOption` returns `Option` (`:4604`); `timeoutOrElse` (`:4641`); returns only after the timed-out work's cleanup (report 23 case 3.7: 255 ms for 50 ms) | nothing generic. HTTP v2's per-request `timeout` (`boundary.md` §9.8.12) is a property of one request | **missing** — app-blocking | **`Task.timeout : Duration, (() -> a) -> Maybe a`** — `Nothing` when the work had not returned, **after** its cleanup (A10; the doc comment says "may take longer than `duration`"). P2 was right and Effect's default is the odd one out (report 23 §0.2 row 6): `Maybe.withDefault` is `timeoutOrElse`, and a `Result` caller maps `Nothing` to its own error. A timeout around an uninterruptible region is a request, not a guarantee (report 23 case 3.10) |
| **Delays** | `sleep` (`Effect.ts:4707`), `delay` (`:4674`), `timed` (`:4733`), `never` (`:1253`) | `Time.sleep : Duration -> ()` (browser), `Io.sleep : Int -> ()` (node) | **partial** | **`Task.sleep : Duration -> ()`** in core, over the fiber's clock (§2.4); the platforms' `sleep`s call it. **`Task.never : () -> a`**. `delay` and `timed` are a `sleep` and two `Clock.now` reads in a block |

### 2.4 Time, schedules and retries

| Area | Effect v4 provides | beni today | Status | Proposed beni shape |
|---|---|---|---|---|
| **`Duration`** | `Duration.ts` (1 798 lines: units, arithmetic, formatting) | `Time.Duration` in the browser platform (`millis`, `seconds`, `inMillis`); none on Node | **partial** | **`core/Duration`**: `millis`, `seconds`, `minutes`, `toMillis`, `add`, `scale : Duration, Float -> Duration`, with `eq`/`compare` derived. `Time.Duration` becomes an alias of it and keeps every function a page uses (§4.2) |
| **`Schedule`** | a value with a step function and one metadata record (`Schedule.ts:53`, `fromStep` `:250`, `toStep` `:344`); `recurs` (`:1169`), `spaced` (`:1198`), `exponential` (`:850`), `fibonacci` (`:882`), `fixed` (`:933`), `jittered` (`:1093`), `upTo` (`:1294`), `during` (`:750`), `while` (`:1323`), `max` (`:618`), `min` (`:783`), `concat` (`:500`), `modifyDelay` (`:1043`), `tap` (`:1234`), `cron` (`:678`), `windowed` (`:1423`), `forever` (`:1460`); about 25 v3 combinators deleted (report 22 §1.3) | nothing | **missing** — app-blocking | **`core/Schedule`**, pure data, no runtime: `Schedule i` is a closure that, given `{ input : i, attempt : Int, elapsed : Duration, random : Float }`, returns `Continue Duration (Schedule i)` or `Stop` — the next schedule carries its own state, so composing schedules of different states needs no existential type (A4's sub-question). `recurs`, `spaced`, `exponential : Duration, Float -> Schedule i`, `fibonacci`, `fixed`, `forever`, `jittered` (Effect's 0.8–1.2 range, drawn from `random`), `upTo : Schedule i, Duration -> Schedule i`, `while : Schedule i, (i -> Bool) -> Schedule i`, `max`, `min`, `andThen` (Effect's `concat`), `modifyDelay`. **`Schedule.delays : Schedule i, List i -> List Duration`** runs one purely, so a schedule is tested with no clock at all. `cron` and `windowed` wait for a date library |
| **`retry` / `repeat`** | `retry` (`Effect.ts:4090`) and `retryOrElse` (`:4166`) re-run on a failure; never on a defect or an interrupt (report 23 case 5.2); `repeat` (`:7656`), `repeatOrElse` (`:7730`), `schedule` (`:7856`) | nothing | **missing** — app-blocking | **`Task.retry : Schedule e, (() -> Result e a) -> Result e a`** — the schedule sees each `Err`; the last `Err` when it stops. **`Task.repeat : Schedule a, (() -> a) -> a`** — the last value. A cancelled attempt is never retried, by construction: a cancelled fiber does not return. `retryOrElse` is a `case` on the result |
| **`Clock` and test time** | `Clock` is a `Context.Reference` with a default (`Clock.ts:51`, `currentTimeMillis` `:265`); `Effect.clockWith` (`Effect.ts:13688`); `TestClock.make`/`adjust`/`setTime`/`withLive` (`testing/TestClock.ts:244`, `:507`, `:544`, `:580`); the scheduler itself is a fiber-local (`Scheduler.ts:78`, report 21 §7.3) | the page driver replaces `setTimeout`/`Date` under the browser corpus; nothing for `run/`; the scheduler is one module-level queue in `Task.js` | **partial** | A13, as a fiber slot inherited at spawn by pointer (A7's "clock" slot): **`core/Clock`** — `Clock.now : () -> Int` (epoch milliseconds through the fiber's clock), `Clock.virtual : Int -> Virtual`, `Clock.adjust : Virtual, Duration -> ()` (moves the clock on, waking every sleeper whose time has come in time order, and returns once each has run to its next suspension — it suspends, as `TestClock.adjust` is an effect), `Clock.run : Virtual, (() -> a) -> a` (`work` and every fiber it starts read the virtual clock). `Task.sleep` asks the slot. The browser driver's host-level virtual clock stays: a page's own timers are the page's |

### 2.5 Coordination primitives

All of these are library code over `Task.callback`, `Task.resume` and `Ref` (finding 2): the
canceller a parked waiter registers removes it from the waiter list, which is the one mechanism
Effect discharges the "a cancelled waiter is removed" obligation with (`Semaphore.ts`'s
`waiters.delete`, report 21 §5.6; P2 §6.5's third obligation).

| Area | Effect v4 provides | beni today | Status | Proposed beni shape |
|---|---|---|---|---|
| **`Deferred`** | `make` (`Deferred.ts:172`), `await`, `succeed` (`:784`), `complete` (`:261`), `fail`/`die`/`interrupt` (`:389`, `:549`, `:630`), `isDone` (`:701`), `poll` (`:749`); a second completion is ignored (report 23 case 6.1) | nothing; `Resume` is one-shot and platform-only | **missing** — app-blocking | **`Deferred.make : () -> Deferred a`**, **`wait : Deferred a -> a`** (parks until completed; a cancelled waiter is removed), **`complete : Deferred a, a -> Bool`** (first completion wins), `poll : Deferred a -> Maybe a`, `isDone`. `fail`/`die`/`interrupt` are n/a: carry a `Result` in `a`; a defect is fatal |
| **`Ref`** | `make` (`Ref.ts:173`), `get` (`:200`), `set` (`:236`), `update` (`:573`), `modify` (`:461`), `getAndSet`, `updateAndGet`, … (`Ref.ts:59`-`:747`) | `Js.Ref` (`ref`/`read`/`write`), core and platforms only | **missing** for programs — app-blocking | **`Ref.make : a -> Ref a`** (`impure`: a new cell is a new identity, so the optimiser may not merge two), `get`, `set`, **`update : Ref a, sync (a -> a) -> ()`**, **`modify : Ref a, sync (a -> ( b, a )) -> b`**. The `sync` is the atomicity guarantee: a function that suspended between the read and the write would lose an update. Report 22 §4.1: `Ref.get` is `impure` or `--release` may memoise two reads into one |
| **`SynchronizedRef`** | an update that may itself run effects, serialised (`SynchronizedRef.ts:38`, `modifyEffect` `:307`, `updateEffect` `:485`) | nothing | **missing** (T2) | **`Ref.Locked a`** — a `Ref` and a one-permit `Semaphore`: `Ref.updateLocked : Locked a, (a -> a) -> ()` whose function may suspend. Library code over the two rows above and below |
| **`Semaphore`** | `make` (`Semaphore.ts:358`), `withPermits` (`:407`), `withPermit` (`:432`), `withPermitsIfAvailable` (`:461`), bare `take`/`release` (`:494`, `:554`, documented as not interruption-safe), `resize` (`:380`); **not FIFO** (`Semaphore.ts:125`: "scanned in registration order, but a request is served only when" it fits) | nothing | **missing** — app-blocking | **`Semaphore.make : Int -> Semaphore`**, **`withPermits : Semaphore, Int, (() -> a) -> a`**, `withPermit`, `tryWithPermits : Semaphore, Int, (() -> a) -> Maybe a`, `available`, `resize`. No bare `take`/`release`: they leak a permit on cancellation, which is a guarantee, not taste (report 22 §8). **FIFO** — a large request is never starved by small ones (§5 item 8) |
| **`Queue`** | `bounded` (`Queue.ts:501`), `dropping` (`:574`), `sliding` (`:538`), `unbounded` (`:612`); `offer` (`:646`, parks when a bounded queue is full), `offerAll` (`:763`), `take` (`:1426`), `takeAll` (`:1244`), `takeN` (`:1331`), `poll` (`:1465`), `size` (`:1736`), `end` (`:1005`) and `fail` (`:873`) end it, `shutdown` (`:1138`) interrupts its waiters | nothing | **missing** — app-blocking | **`Queue.bounded : Int -> Queue a`**, `dropping`, `sliding`, `unbounded : () -> Queue a`; **`offer : Queue a, a -> Bool`** (parks while a bounded queue is full; `False` when a dropping queue drops), `offerAll`; **`take : Queue a -> Maybe a`** (parks while empty; `Nothing` once ended and drained, so a consumer loop ends with `?`), `takeUpTo : Queue a, Int -> List a`, `poll`, `size`, **`end : Queue a -> ()`**. No `shutdown`: a waiter is cancelled by cancelling its fiber, which a scope does (§5 item 9) |
| **`PubSub`** | `bounded`/`dropping`/`sliding`/`unbounded` (`PubSub.ts:335`-`:468`), `publish` (`:908`), `subscribe` scoped (`:1083`), `take`/`takeAll` (`:1150`, `:1198`) | `Sub.listen` in a page: one fiber per live key, its sends fanned out to every declaration's tagger (`platforms/browser/Sub.beni`) | **partial** (pages only) | **`PubSub.bounded : Int -> PubSub a`** etc., `publish : PubSub a, a -> Bool`, **`subscribe : PubSub a, (Queue a -> b) -> b`** — the subscription lives exactly as long as the function, the bracket shape, since beni has no scoped value to return (T2) |
| **`Latch`** | `make` (`Latch.ts:196`), `open` (`:216`), `close` (`:312`), `release` (`:260`, a one-shot pulse), `await` (`:87`), `whenOpen` (`:360`), `isOpen` (`:382`) | nothing | **missing** | **`Latch.make : Bool -> Latch`**, `open`, `close`, `release`, **`wait : Latch -> ()`**, `isOpen`. `whenOpen` is `wait` then the work |

### 2.6 Ambient state, services, configuration, randomness

| Area | Effect v4 provides | beni today | Status | Proposed beni shape |
|---|---|---|---|---|
| **Fiber locals** | v3's `FiberRef`/`FiberRefs` deleted; v4 has `Context.Reference` — a service with a default that never appears in `R` (`Context.ts:335`, `:1325`), read through the fiber's context cache (`effect.ts:742-781`, report 21 §7.2); `References.ts` declares the built-in ones (log level `:225`, annotations `:185`, spans `:290`, whether tracing is on `:391`) | none; every fiber shares `Task.js`'s module state | **missing** | A7: **fixed slots on the fiber record, inherited by pointer at spawn** — the clock (§2.4), the log context (annotations, spans, minimum level, §2.7) and, recommended here, the random seed (row below). No general `Task.Local a` in v1: report 22 §10 item 1's typing question (B11) is unanswered and no row of this ledger needs one (§5 item 13) |
| **Services, `Layer`, `Context`** | `Context.Service`/`Key` (`Context.ts:98`, `:64`), `Layer` (`Layer.ts:54`, 2 802 lines: `succeed` `:807`, `effect` `:1014`, `merge` `:1298`, `provide` `:1431`), `Effect.provide`/`provideService`/`service` (`Effect.ts:5882`, `:6318`, `:6057`); `R = never` proves no dependency was forgotten | records of functions passed as arguments; `where` clauses for a handle with methods (`static-dispatch-spike.md`); `Http`'s doc tells a testable program to take its requests as a record | **n/a by decision** (A7) | nothing to build. Written down once more, as A7 asked: **beni does not have `R = never` at the entry point** — a forgotten capability is a missing argument, which the checker reports as one; there is no service that can be "not provided" at run time. A resource with a lifetime (`Layer.scoped`) is a `bracket` around the code that uses it |
| **`Config`** | `Config.ts` (1 626 lines): typed, schema-driven reading of environment and providers, `withDefault` (`:528`), redaction; `ConfigProvider.ts` | `core/Schema` parses any structured input; no environment reader | **partial** | n/a in a browser (there is no environment). On Node: **`Io.env : String -> Maybe String`** and **`Io.environment : () -> Dict String String`**, decoded with a `Schema` like any other input — `Config` is a `Schema` plus a reader, and beni already has the first |
| **`Random`** | `Random` is a `Context.Reference` (`Random.ts:69`): `next`, `nextInt`, `nextBetween`, `shuffle`, `choice` (`:93`-`:256`), and **`withSeed`** (`:304`) for a deterministic test | core's `Random.Pcg` (elm/random's generators, pure with a `Seed`); the platforms' `Random.value` draws from a page or process seed seeded by `crypto.getRandomValues` (`platforms/browser/Random.beni`, `platforms/node/Random.beni`) | **partial** | generators are at parity (pure, with Elm's names). Missing: the deterministic run — **`Random.withSeed : Seed, (() -> a) -> a`**, the seed held in a fourth fiber slot that `value` reads, so a test of code that draws is reproducible without threading a `Seed` through it (§5 item 13) |

### 2.7 Observability

| Area | Effect v4 provides | beni today | Status | Proposed beni shape |
|---|---|---|---|---|
| **Logging** | `log`, `logTrace`/`Debug`/`Info`/`Warning`/`Error`/`Fatal` (`Effect.ts:13758`-`:13917`), `logWithLevel` (`:13729`); levels `All … None` (`LogLevel.ts:67`); `annotateLogs` over a subtree (`:14001`), `withLogSpan` (`:14114`); minimum level (`References.ts:349`); pluggable loggers (`Logger.ts:64`, `make` `:471`, `consolePretty` `:801`, `formatLogFmt` `:559`, `formatJson` `:664`, `batched` `:702`); an unhandled failure logged at a level (`References.ts:573`) | browser `Log.info`/`warn`/`error : String -> ()` (`platforms/browser/Log.beni`), kept by `--release`; Node has nothing but `Debug.log`, which `--release` refuses | **partial** | **`core/Log`**: `type Level = Trace \| Debug \| Info \| Warn \| Error`; `trace`, `debug`, `info`, `warn`, `error : String -> ()`; **`annotate : String, String, (() -> a) -> a`** (inherited by the fibers the work starts), **`span : String, (() -> a) -> a`** (each line inside carries `label=<ms>`), **`minimum : Level, (() -> a) -> a`**; all three in the log-context slot. The sink is the platform's: the browser's console with the annotations as an object, Node's standard error as logfmt. The browser's `Log` module becomes core's (§4.2). Effect's "unhandled failure" log has no beni counterpart: an `Err` is a value, and a child's value is what its parent chose to read |
| **Tracing** | `withSpan` (`Effect.ts:8371`), `makeSpan`/`useSpan` (`:8288`, `:8347`), `annotateCurrentSpan` (`:8089`), `currentSpan` (`:8119`), `linkSpans` (`:8251`), `withParentSpan` (`:8446`), `withTracer` (`:7963`); `Effect.fn("name")` opens a span per call and records a call-site frame from a `new Error()` (`Effect.ts:13659`, `effect.ts:1283`) at 7.2 µs a call (report 21 §9.6); exporters in `unstable/observability` | nothing | **missing** | **`core/Trace`**: **`span : String, (() -> a) -> a`**, `annotate : String, String -> ()` on the current span, spans parented through the fiber's log-context slot (one slot holds both, as Effect's `References` does). A platform installs an exporter; the browser and Node ship a console one. Report 22 D8's option (c) — a build flag that wraps every `suspends` function in a span named by the compiler, at no per-call `Error` — stays the thing to revisit (decisions sheet C4) |
| **Metrics** | `Metric.ts` (3 529 lines): `counter` (`:2093`), `gauge` (`:2179`), `histogram` (`:2352`), `summary` (`:2428`), `frequency` (`:2273`), `timer` (`:2533`) | nothing | **missing** (later) | platform work, as report 22 §1.2 judged: a `Metric` module with `counter`/`gauge`/`histogram` over a `Ref`, an exporter per platform. Not on any app-blocking path |

### 2.8 Batteries

| Area | Effect v4 provides | beni today | Status | Proposed beni shape |
|---|---|---|---|---|
| **`Stream`, `Sink`, `Channel`, `Pull`** | 23 741 lines, 506 exports (`Stream.ts` 11 864, `Channel.ts` 8 923, `Sink.ts` 2 205, `Pull.ts` 392); end-of-input as `Cause.Done` in the error channel (`Cause.ts:1286`) | `Sub.listen` for event sources in a page; nothing general | **n/a for v1** (decision sheet C1, report 23 D16) | not in v1. When it comes: a pull source — `() -> Maybe a`, ended by `Nothing`, which is exactly v4's `Pull` with `?` doing `Done`'s work (report 22 §0) — over `Queue` with `end`, and **no `Channel`**. Report 23 §8's six cases are the acceptance criteria |
| **`Cache`, `cached`** | `Cache.make`/`get`/`invalidate`/`refresh` (`Cache.ts:288`, `:420`, `:960`, `:1160`): N concurrent `get`s, one lookup (report 23 case 6.10); `Effect.cached` (`:7122`), `cachedWithTTL` (`:7207`), `cachedInvalidateWithTTL` (`:7279`) | nothing | **missing** (T2) | **`Task.once : (() -> a) -> (() -> a)`** — the first caller runs the work, concurrent callers wait on its `Deferred`. **`Cache.make : Int, Duration, (k -> v) -> Cache k v`** (capacity, time to live, lookup), `get`, `invalidate`; `k` with `compare`; time from the fiber's clock, so a TTL is tested on a virtual one |
| **`Request` batching** | `Request.Class`/`TaggedClass` (`Request.ts:370`, `:409`), `RequestResolver.make`/`batchN` (`RequestResolver.ts:237`, `:790`), `Effect.request` (`Effect.ts:8496`): N concurrent lookups become one batched call | nothing | **missing** (T2) | **`Batch.make : Duration, (List k -> Dict k v) -> Batch k v`** and **`Batch.get : Batch k v, k -> Maybe v`**: requests arriving within the window are collected, one call answers all, each waiter wakes on its `Deferred`. A record of functions, not a class hierarchy |
| **`Pool`, `RcRef`** | `Pool.make`/`get` (`Pool.ts:232`, `:446`), `RcRef.make`/`get` (`RcRef.ts:157`, `:220`) | nothing | **missing** (T2) | `Pool` is a `Semaphore`, a `Queue` of idle resources and a `bracket`: **`Pool.with : Pool r, (r -> a) -> a`**. `RcRef` waits for a use |
| **STM (`Tx*`)** | eleven `Tx*` modules (9 289 lines), `Effect.tx` (`Effect.ts:14609`) | nothing | **n/a for v1** (decision sheet C2) | not in v1. It is the one family that constrains the kernel (a transaction must retry), so the kernel's spec should say what it would need rather than discover it |

### 2.9 Error handling and style

| Area | Effect v4 provides | beni today | Status | Proposed beni shape |
|---|---|---|---|---|
| **Catching by tag** | `catchTag` (`Effect.ts:2744`), `catchTags` (`:2843`), `catchIf` (`:3366`), `catchCause` (`:3259`), `catchDefect` (`:3312`), `catch` (exported `:2694`) — a `_tag` string narrowed with no exhaustiveness check | `case` on an error ADT, checked exhaustive (`missing_patterns`) | **have, better** | — . The one row where beni's existing guarantee beats the gold standard (report 22 §0 item 3). `catchDefect` is n/a (A1) |
| **Mapping and recovery** | `mapError` (`Effect.ts:3601`), `orElseSucceed` (`:4466`), `result` (`:2275`), `exit` (`:2360`), `option` (`:2318`), `tapError` (`:3722`), `orDie` (`:3688`), `sandbox` (`:4206`), `ignore` (`:4252`), `eventually` (`:3983`) | `Result.map`, `mapError`, `andThen`, `withDefault`, `toMaybe`, `fromMaybe`, `map2`–`map5` (`core/Result.beni`); `?` on `Result` and `Maybe` | **have** | the outcome is already a value, so `result`/`exit`/`option` are the identity. `orDie` and `sandbox` are **n/a by rule 9**: turning a typed failure into a defect from program code is a runtime error on purpose. `eventually` is `retry` with `forever` |
| **Error accumulation** | `validate` (`Effect.ts:621`), `partition` (`:533`), `all` with `mode: "result"` | none | **missing** (small) | decision sheet C7 (a): **`Result.combine : List (Result e a) -> Result e (List a)`** (first `Err`) and **`Result.partition : List (Result e a) -> ( List e, List a )`**, beside `Task.forEach` |
| **`Effect.gen` against direct style** | `gen` (`Effect.ts:1432`) with `yield*`, `fn`/`fnUntraced` (`:13659`, `:13535`); 67 ns a step (report 21 §9.1) | direct style: a call that may suspend is a call; the fast path is one comparison, 2.4 ns (report 44 §2) | **have, better** | — . Nothing to copy; `Effect.gen` exists because TypeScript has no other way to write a sequence (report 22 §7.5) |
| **Interop with JavaScript failure** | `try` (exported `:1710`), `tryPromise` (`:967`), `promise` (`:893`), `callback` (`:1229`); `Effect.try` with no mapper produces a contentless error (report 23 case 1.8) | `Task.callback` for a host callback; `Js.catchIf` names each failure a host API documents, everything else a defect (`CLAUDE.md` rule 9) | **have, stricter** | — . A broad `try` is refused by rule 9; every platform wrapper maps each documented failure to a constructor, as `Io.readFile`, `Storage` and `Http` do |

### 2.10 Quality

| Area | Effect v4 provides | beni today | Status | Proposed beni shape |
|---|---|---|---|---|
| **Logical stack traces** | a `StackFrame` list on the fiber, pushed by `Effect.fn` from a `new Error()` captured at `stackTraceLimit = 2` and printed by `Cause.pretty` (`effect.ts:466-489`, `:1283`; report 21 §8.1); 7.2 µs per traced call | development source maps for emitted code (`backend.md` §11.1); each continuation is a named arrow at its call's position (P2 §16.7); a throw after a park shows `Task.js`'s run loop and the continuation, not the chain that led there | **missing** | **development builds only**: when a fiber throws, the report lists its pending continuations (`stack`, innermost first) and its ancestry (each fiber's spawn site, recorded at `spawn` as one reference), each mapped through the source maps to `Module.beni:line`. Release builds record nothing: no bytes, no instructions (P2 §7.4; §8 slice P6) |
| **Defect reports** | `Cause.pretty` (`Cause.ts:1115`; `effect.ts:492`) with every reason, its stack and span; `runMain` exits 1 on a defect, 130 on an interrupt (report 23 case 8.8); an unhandled `runFork` failure is silent and exits 0 (case 8.4 — a wart) | the host's report and a crash screen in a development page (`boundary.md` §9.8.10 (c)); Node prints and exits 1 (P2 §16.5); `Io.run` exits 130 when its fiber is cancelled; **the teardown** — every finaliser once, later throws reported separately and listed — landed 2026-10-02 (§9.8.14) | **partial** | the teardown, plus the logical trace above in the same report, plus **no silent exit 0** (finding 3): `Io.run` leaves exit code 1 until its fiber ends, and when Node's loop is about to empty (`beforeExit`) with the root fiber parked, prints *"the program is waiting for something that cannot happen"* with the parked fibers' traces, and exits 1. Effect keeps the process alive instead (report 22 D9); a program that can never wake should end, loudly |
| **Leak freedom** | `Scope` + interruption + waiter removal through the canceller; a retained-bytes gate in its own suite (`serverAllocations.ts`; the decision sheet's B3) | the canceller removes a cancelled wait's host handle; a cancelled `join`/`wait` unobserves (`Task.js` `outcomeOf`); the teardown releases every host resource on a defect (§9.8.14 (a)) | **partial** | every waiter list in §2.5 removes its waiter in the canceller, with a `run/` fixture per primitive; and a retained-bytes check in `bench/fiber`: 100 000 cancelled waits on each primitive leave the heap where it started (a `--expose-gc` heap delta) |
| **Performance per operation** | report 21 §9 and report 44, v4 on the same machine: `flatMap` step 82–98 ns; `yieldNow` 1 527 ns (Node), 4.13 ms (Chrome, `setTimeout` clamped); 10 000-fiber fan-out 9.5 ms / 70.3 ms; fork+join 472 ns (immediate) / 3 172 ns (scheduled); scope finaliser 2 076 ns install, 199 ns unwind; parked fiber 419 B / 659 B | fast-path point 2.4 ns; park 125 ns (Node), 162 ns (Chrome); fan-out 3.4 ms / 3.8 ms (report 44 §0) | **have, better** for the kernel; unmeasured for everything in §2.3–§2.5 | every slice in §8 of the plan measures its operations against Effect's equivalents in `bench/fiber`, in Node and Chrome, as report 44 did, and states bytes brotli beside Effect's tree-shaken bundle. Bar: no operation slower than Effect's; a regression on code that does not use the slice is 0 |
| **Bytes** | 25 118 B raw / 9 094 B gzip for `runFork` alone; ~5 kB gzip more for the concurrency surface (report 21 §0.4); the spike's program 26 878 B brotli | 2 114 B brotli for the same program; `Reach.zig` drops what a build does not reach | **have, better** | the new modules are beni over the kernel, so a program pays for the combinators it calls and no more (`backend.md` §9) |
| **Compile-time error quality** | errors in `E` and requirements in `R` are TypeScript type errors; nothing stops a synchronous callback from receiving an effect | `sync_boundary` and `must_not_suspend` with a one-hop chain (P2 §15); `missing_patterns` on an error `case` | **have, better** | — |
| **Scheduler fairness** | `MaxOpsBeforeYield` 2 048 (`Scheduler.ts:279`); every yield a macrotask, `setTimeout(0)` without `setImmediate` | 64 resumptions per drain, then a `MessageChannel` macrotask in a browser (`Task.js`; report 44 §3 measured it in Chrome) | **have, better** for a browser | — |

---

## 3. The proposed API in one place

Every function below is beni over the kernel (`callback`, `resume`, `spawn`, `spawnIn`, `cancel`,
`wait`, masks, finalisers) except the four kernel additions marked **K**, which belong in
`core/Task.js` or its beni successor (§4.3). `pub foreign type` where a module's type is opaque to
programs and only core touches its representation; otherwise `pub opaque type`.

```elm
-- core/Task — additions
pub resume : Resume a, a -> ()                          -- K: resume a waiting fiber, once; later calls do nothing
pub never : () -> a                                     -- parks forever (cancellable)
pub sleep : Duration -> ()                              -- K: through the fiber's clock
pub poll : Fiber a -> Maybe (Exit a)
pub joinAll : List (Fiber a) -> List a
pub cancelAll : List (Fiber a) -> ()                    -- cancel each, then wait for all
pub spawnDetached : (() -> a) -> Fiber a                -- K: a root; outlives its parent
pub foreign type Restore
pub uninterruptibleMask : (Restore -> a) -> a           -- K
pub restore : Restore, (() -> b) -> b
pub onExit : (() -> a), (Exit a -> ()) -> a
pub defer : Scope, (Exit () -> ()) -> ()
pub par : (() -> a), (() -> b) -> ( a, b )
pub par3 : (() -> a), (() -> b), (() -> c) -> ( a, b, c )
pub parOk : (() -> Result e a), (() -> Result e b) -> Result e ( a, b )
pub forEach : List a, Int, (a -> b) -> List b
pub forEachOk : List a, Int, (a -> Result e b) -> Result e (List b)
pub race : (() -> a), (() -> a) -> a
pub raceAll : (() -> a), List (() -> a) -> a
pub raceOk : List (() -> Result e a) -> Result (List e) a
pub timeout : Duration, (() -> a) -> Maybe a
pub retry : Schedule e, (() -> Result e a) -> Result e a
pub repeat : Schedule a, (() -> a) -> a
pub once : (() -> a) -> (() -> a)

-- core/Duration, core/Clock, core/Schedule
pub millis : Int -> Duration        pub seconds : Int -> Duration       pub minutes : Int -> Duration
pub toMillis : Duration -> Int      pub add : Duration, Duration -> Duration
pub scale : Duration, Float -> Duration
pub now : () -> Int                                    -- Clock: epoch ms through the fiber's clock
pub virtual : Int -> Virtual        pub adjust : Virtual, Duration -> ()
pub run : Virtual, (() -> a) -> a
pub type Step i = Continue Duration (Schedule i) | Stop
pub recurs : Int -> Schedule i      pub spaced : Duration -> Schedule i
pub exponential : Duration, Float -> Schedule i        pub fibonacci : Duration -> Schedule i
pub fixed : Duration -> Schedule i  pub forever : Schedule i
pub jittered : Schedule i -> Schedule i
pub upTo : Schedule i, Duration -> Schedule i
pub while : Schedule i, (i -> Bool) -> Schedule i
pub max : Schedule i, Schedule i -> Schedule i         -- both continue; the longer delay
pub min : Schedule i, Schedule i -> Schedule i         -- either continues; the shorter delay
pub andThen : Schedule i, Schedule i -> Schedule i
pub modifyDelay : Schedule i, (Int, Duration -> Duration) -> Schedule i
pub step : Schedule i, { input : i, attempt : Int, elapsed : Duration, random : Float } -> Step i
pub delays : Schedule i, List i -> List Duration       -- pure: what a run would wait

-- core/Deferred, Ref, Semaphore, Queue, Latch
pub make : () -> Deferred a         pub wait : Deferred a -> a
pub complete : Deferred a, a -> Bool                   pub poll : Deferred a -> Maybe a
pub make : a -> Ref a               pub get : Ref a -> a        pub set : Ref a, a -> ()
pub update : Ref a, sync (a -> a) -> ()                pub modify : Ref a, sync (a -> ( b, a )) -> b
pub make : Int -> Semaphore         pub withPermits : Semaphore, Int, (() -> a) -> a
pub withPermit : Semaphore, (() -> a) -> a             pub tryWithPermits : Semaphore, Int, (() -> a) -> Maybe a
pub bounded : Int -> Queue a        pub dropping : Int -> Queue a       pub sliding : Int -> Queue a
pub unbounded : () -> Queue a       pub offer : Queue a, a -> Bool      pub take : Queue a -> Maybe a
pub takeUpTo : Queue a, Int -> List a                  pub poll : Queue a -> Maybe a
pub size : Queue a -> Int           pub end : Queue a -> ()
pub make : Bool -> Latch            pub open : Latch -> ()      pub close : Latch -> ()
pub release : Latch -> ()           pub wait : Latch -> ()

-- core/Log, core/Trace
pub type Level = Trace | Debug | Info | Warn | Error
pub info : String -> ()             -- and trace, debug, warn, error
pub annotate : String, String, (() -> a) -> a
pub span : String, (() -> a) -> a
pub minimum : Level, (() -> a) -> a
pub span : String, (() -> a) -> a                      -- Trace
pub annotate : String, String -> ()                    -- Trace: the current span
```

**Why `sync` on `Ref.update` and nowhere else.** The `sync` mark is written only in a `foreign`
signature (P2 §15; `misplaced_sync`), and it is the only way to promise the atomicity of a
read-modify-write in a runtime that interleaves at suspension points. So `update` and `modify` are
`foreign` — two lines of JavaScript each — or the language allows `sync` in a core declaration's
signature. §5 item 10.

---

## 4. Where this touches other work

The ledger was written against `84a49831`; the defect teardown and HTTP version 2 landed on
`master` the same day (`2cb618e5`), and the report was re-checked against them before it was
committed. Neither contradicts it.

### 4.1 The defect teardown (`boundary.md` §9.8.14), landed 2026-10-02

**No conflict; one dependency, now met.** The teardown's registry of roots (§9.8.14 (c)) is what
makes **`spawnDetached`** safe: a detached fiber is a root, so it joins the registry, and
`Task.shutdown` reaches it with everything else. The combinators of §2.3 cancel and wait exactly as
`closeScope` does, so they inherit the teardown's ordering (§9.8.14 (e)) and its deadline for a
finaliser that suspends; nothing in them needs a teardown rule of its own. The *stopping* state
must also drop a `Task.resume` from program code the way it drops a host callback's (its wait is
done), and `run/TaskShutdown` should gain a `Deferred` waiter once P1 exists. The logical trace of
§2.10 adds a line to the crash screen on which §9.8.14 (g) already lists later throws. Node keeps
§9.8.14 (k)'s unchanged crash path; finding 3's quiescence report is a different case — no throw,
a program that can never wake — and does not touch it.

### 4.2 HTTP version 2 (`boundary.md` §9.8.12), landed 2026-10-02

**No conflict; one migration.** A request's `timeout : Maybe Duration` is `Time.Duration`
(`platforms/browser/Http.beni`, `import Time exposing (Duration)`). Moving `Duration` into core
makes `Time.Duration` an alias and leaves every signature as written, so `Http` changes only
through the alias. The request's own `timeout` and `Task.timeout` are different things and both
stay: the first is `Error.Timeout`, raised through the request's `AbortSignal` reason; the second
cancels the fiber, which aborts the request through its canceller and answers `Nothing`. `Http`'s
doc comment should say which to reach for. **A `browser` `Log` module and a core `Log` cannot both
exist** — module names are global — so the logging slice moves `platforms/browser/Log.beni`'s three
functions into core with the same signatures, as routing just moved `Url` into core
(`b92a78aa`).

### 4.3 `core/Task.js` in beni (`plans/core-in-beni.md` step 2), being studied

**A coordination point, not a conflict.** Report 43 §11 item 9 already asks that `race`,
`timeout`, `retry`, `par2` and the rest be beni over first-order kernel operations, so every row of
§3 except the four **K** additions is beni, and it does not matter whether the kernel under it is
JavaScript or beni. The four **K** additions — `resume`, the clock slot behind `sleep`,
`uninterruptibleMask`, `spawnDetached` — change the kernel itself. They should land either before
step 2 starts (so step 2 ports them) or as part of it, **never in the middle**, so the kernel is
written once. One tension to flag: §5 item 10's `foreign` `Ref.update` adds JavaScript where
step 2 removes it; the alternative is a language change that lets core write `sync` in a beni
signature, which step 2 may want for its own kernel declarations anyway.

### 4.4 P2 §6.5's primitive list

P2 §6.5's eleven signatures predate decisions A2, A3, A4 and A12: `Fiber.join : Fiber a -> Result
Cancelled a`, `Task.timeout : Int, …`, `Task.retry : Int, …` and `Task.parAll : Int, List (() ->
a) -> List a` are superseded by `join`/`wait` (as built), `Duration`, `Schedule` and `forEach`.
P2 §16.5 records the built ones; the first slice of §8 writes a dated amendment into §6.5 rather
than editing it in place (rule 2: no section is renumbered).

---

## 5. Decisions for the owner

Each is taken in the plan as recommended unless the owner says otherwise; each is reversible
until its slice ships.

| # | Question | Recommendation | Alternative |
|---|---|---|---|
| 1 | Where does time live? | **`core/Duration` and one `Task.sleep : Duration -> ()`** over a clock slot; the platforms' `Time.Duration` becomes an alias and `Io.sleep` a call of `Task.sleep` | keep `Duration` and `sleep` per platform; core combinators then take a bare `Int` of milliseconds |
| 2 | Deterministic time (A13) | **a virtual clock in core**, `Clock.virtual`/`adjust`/`run`, as a fiber slot, so `run/` fixtures test timing on Node by order alone | the browser driver's host-level clock only; Node timing fixtures sleep for real, or do not exist |
| 3 | May programs write coordination primitives? | **yes: `Task.resume` and a public `Ref`** — rule 7, nothing withheld | core ships the primitives and programs get only those (`Resume` stays callable only through `Js`) |
| 4 | `race` without a failure channel | **`race`/`raceAll` = first to return; `raceOk` = first `Ok`, every `Err` when none** | Effect's names on `Result` thunks: `race` = first `Ok`, `raceFirst` = first to return |
| 5 | Fail-fast on `Err` | **separate `…Ok` forms** (`forEachOk`, `parOk`) that cancel the rest on the first `Err` and wait | one `forEach`; a program wanting fail-fast writes the scope and cancellation itself |
| 6 | The concurrency bound | **mandatory `Int`** on `forEach` (P2 §6.5, report 16's 901 MiB against 78.6 KiB); `par`/`par3` need none | Effect's optional `concurrency`, defaulting to sequential, with an "unbounded" value |
| 7 | `Schedule`'s representation | **a closure returning the next schedule**, with a pure `step` that is handed the random draw, so jitter is testable and composition needs no existential type; v4's `max`/`min` names | a fixed state record (`Int` + `Duration`), which cannot compose `while` or schedules of different state; or v3's `intersect`/`union` names |
| 8 | Semaphore order | **FIFO**: a request for many permits is never starved by small ones | Effect's order (scan in registration order, serve what fits), slightly higher throughput under mixed sizes |
| 9 | How a queue ends | **`Queue.end`; `take : Queue a -> Maybe a`**, `Nothing` once ended and drained, so `?` ends a consumer loop | `take : Queue a -> a`; ending cancels the waiting takers (Effect's `shutdown`) |
| 10 | `Ref.update`'s atomicity | **`sync` callbacks through a two-line `foreign`** | allow `sync` in a core beni signature (a language change), or no guarantee (a suspending update may lose a write) |
| 11 | Detached fibers | **`Task.spawnDetached`, a root in the teardown's registry** | none: a program opens a root scope with `openRoot` (platform-facing today) |
| 12 | `uninterruptibleMask` | **yes, with a `Restore` token** (no rank-2 type) | `uninterruptible` only; `bracket` stays the only way to have an interruptible middle |
| 13 | Fiber-local state | **four fixed slots**: clock, scheduler, log context (annotations, spans, level, trace parent), random seed | A7's three, and `Random.withSeed` is not offered; or a general typed `Task.Local a` (report 22 §10 item 1's probe first) |
| 14 | Logging (A16) | **core `Log`** with levels, `annotate`, `span`, `minimum`; platform sinks; the browser's `Log` moves into core | keep the browser's three functions, add a Node one, no annotations |
| 15 | Tracing | **`core/Trace` with `span` now**; compiler-emitted spans revisited later | no tracing until a platform asks for an exporter |
| 16 | A program that can never wake (finding 3) | **report it and exit 1** when the loop would empty with the root fiber parked; `Io.run` leaves exit code 1 until its fiber ends | Effect's keep-alive: the process stays up forever, waiting |
| 17 | Streams | **not in v1** (C1); revisit once `Queue.end` exists | a minimal pull `Stream` with the coordination slice |
| 18 | `startImmediately` | **no knob** unless a measurement asks for one: beni's scheduled start is a microtask, Effect's a macrotask | `Task.spawnNow`, starting the child before `spawn` returns |

---

## 6. Could not determine, and the one thing run

- **Whether a core module may export `max` and `min` beside the prelude's `Basics.max`/`min`.**
  `Schedule.max` would be called qualified, but a module declaring a name its prelude also exposes
  may be refused as ambiguous inside it. If so, `both`/`either` (v3's semantics, plainer words).
- **Nothing about the silent exit is undetermined; it is recorded here because it is the one
  behaviour this report ran.** Finding 3 is read off `platforms/node/runtime.js` (`exitCode =
  program.code`, 0 for `Node.done`) and `Io.js` (`finish` sets it only when the fiber ends), and
  confirmed on `84a49831`'s ReleaseSafe beni under Node 24.19.0: the program

  ```elm
  main : Program
  main =
      Io.run λ() ->
          _ = Task.callback λ_ -> λ() -> ()
          Node.print "unreachable"
  ```

  built with `beni build --platform=node` and run with `node _main.mjs`, printed nothing and exited
  **0**. It is the first fixture of the plan's slice P1, red first, as a `.crash` golden.
- **What `Task.resume` costs** against the platform's direct call of the JavaScript function, and
  whether the protocol's `Y` sentinel can leak through a program-held `Resume` (it cannot by
  construction — `resume` is `impure`, never `suspends` — but no fixture shows it).
- **Every number for §2.3–§2.5.** Nothing above was measured; each slice measures its own.

---

## 7. Evidence index

- `core/Task.beni`, `core/Task.js` — the kernel as built.
- `platforms/node/Io.beni`, `Io.js`, `runtime.js`; `platforms/browser/Time.beni`, `Http.beni`,
  `Hosted.beni`, `Cmd.beni`, `Sub.beni`, `Log.beni`, `Random.beni`, `Storage.beni`;
  `platforms/browser-tea/Tea.beni`.
- `boundary.md` §9.8.10–§9.8.14; `transparent-effects-proposal.md` §6, §7.4, §7.5, §16.
- Reports 21 (§0, §4, §5, §8, §9), 22 (§0, §6, §8, §9), 23 (§0), 43 (§0, §11), 44 (§0, §8),
  45 (§0); `plans/effects-decisions.md`; `plans/effects-plan.md` §5; `plans/core-in-beni.md`;
  `plans/status-2026-10.md`.
- Effect v4 (`4.0.0-rc.116`): `Effect.ts`, `internal/effect.ts`, `Fiber.ts`, `Scope.ts`,
  `Exit.ts`, `Cause.ts`, `Deferred.ts`, `Ref.ts`, `SynchronizedRef.ts`, `Semaphore.ts`, `Queue.ts`,
  `PubSub.ts`, `Latch.ts`, `Schedule.ts`, `Clock.ts`, `testing/TestClock.ts`, `Random.ts`,
  `Context.ts`, `References.ts`, `Layer.ts`, `Config.ts`, `Logger.ts`, `LogLevel.ts`, `Tracer.ts`,
  `Metric.ts`, `Cache.ts`, `Request.ts`, `RequestResolver.ts`, `FiberSet.ts`, `FiberMap.ts`,
  `FiberHandle.ts`, `Pool.ts`, `RcRef.ts`, `Scheduler.ts`, `Stream.ts`, `Channel.ts`, `Sink.ts`,
  `Pull.ts`, `Duration.ts`.
