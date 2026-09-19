# How Effect v4 executes an effect, as built

**Commissioned by** the project owner, 2026-09-19 — *"Clone EffectTS locally. It's our gold
standard. I want to achieve EffectTS levels of quality and API coverage… Effect needs to deal with
shit we don't — like generators and TypeScript — but we should learn from them regardless."* — and
by [`plans/effects-plan.md`](../../../plans/effects-plan.md) §4, which makes **E3 + E4 the spike**
and names `research/16` §6 as that spike's list of open questions. This report is one of three
inputs to the spike's plan.

**What this is not.** It is not a design argument. [`research/16`](16-fibers-and-concurrency.md)
decided the lowering (own the resume callback, not native `async`) on Effect **3.22.2**, and that
decision is not reopened here — it is *confirmed*, twice, by measurement (§4.4, §0). What this
report answers is the next question: **v4 is a rewrite of the runtime report 16 read**, and the
spike is about to build the beni equivalent. What does the rewritten runtime do, what did the
rewrite change, and which parts of report 16's specification are now out of date.

**Citations.** `effect:<path>:<line>` is `references/effect/<path>`. A bare `` `:1234` `` continues
the citation immediately before it. All Effect line numbers are against `3d59ae6`
(2026-09-19), `packages/effect` version `4.0.0-rc.116`. `beni:` and bare document references
(`P2 §7.2`) are into this repository; **P2** throughout is
[`transparent-effects-proposal.md`](../transparent-effects-proposal.md).

**Read §0, then §11.** §0 is the one-page answer; §11 is the same thing at working depth. §1–§10
are the evidence.

---

## 0. Findings

### 0.1 The table the spike needs

| mechanism | Effect v4 does | beni's proposal says | verdict |
|---|---|---|---|
| **effect representation** | a heap object whose prototype carries `[evaluate]`, `[contA]`, `[contE]`, `[contAll]` as symbol-keyed methods; the fiber calls `current[evaluate](this)` with no `switch` (`effect:packages/effect/src/internal/core.ts:365-381`, `:393-422`; dispatch at `effect:packages/effect/src/internal/effect.ts:683-685`) | nothing — beni compiles CPS directly, there is no effect *value* | **not needed.** This whole layer is an interpreter for a data structure beni's compiler emits as code. It is ~154 lines beni does not write (§1) |
| **the continuation stack** | `_stack: Array<Primitive>`, pushed by `evaluateCont` (`effect:…/effect.ts:1471-1474`), popped by `getCont` (`:710-731`) | P2 §6.4 has no `_stack`; report 16 §5.2 says *"under shape T it comes back"* and recommends CE3's split `conts` + `objectState` | **adapt, and the recommendation is wrong for beni.** v4 uses ONE array of primitives, not two. beni's continuations are closures, so the array holds closures: one `Array<fn>`, no byte-stack (§2.2, §11.3) |
| **op budget** | `currentOpCount >= cache.maxOpsBeforeYield`, default **2048** (`effect:packages/effect/src/Scheduler.ts:184-186`, `:279-282`) | P2 §7.5: an `opCount` on the fiber, budget **64** | **copy the mechanism; the number is measured wrong.** §3.3, §9.3 |
| **what a yield is** | **always a macrotask.** `setImmediate` in Node, `setTimeout(f,0)` otherwise (`effect:…/Scheduler.ts:93-113`, `:217-222`). v3's microtask-with-escape-every-2048-drains is **gone** | P2 §7.5 proposes microtasks for throughput with a macrotask escape every 64 — explicitly against *"Effect's 2048"* | **the premise changed.** v4 already does what P2 proposes, more aggressively. Report 16 §2.3's 361 ms freeze is **8.9 ms** on v4 (§9.3). P2 §7.5's argument survives; its numbers do not |
| **the sync fast path** | a `callback` register that calls `resume` before returning never yields — `if (yielded !== false) return yielded` (`effect:…/effect.ts:1163-1172`); `iterateConcurrentImpl` has an explicit *"fast case (already an exit)"* branch that forks no fiber (`:5016-5021`) | P2 §7.2, the largest thing the lowering buys | **copy — and v4 is the proof it matters.** Effect built the same branch in three places (§1.5, §5.5) |
| **interruption of a parked fiber** | `interruptUnsafe` → `evaluate(failCause(cause))`; `evaluate` first calls `this._yielded()`, which sets the pending `resume`'s `resumed = true`; then the run loop unwinds `contE` through `_stack` and finds the `asyncFinalizer` frame, which runs the canceller (`effect:…/effect.ts:595-616`, `:620-627`, `:1174-1187`, `:1200-1215`) | P2 §6.2 and §6.4: an `interruptor : ?fn(Exit a)` field on the fiber — Effect v3's `_asyncInterruptor` | **adapt: v4 deleted that field.** The canceller is a *stack frame*, not a fiber field, and the one-shot disarm is a separate `_yielded` thunk. This is strictly better and beni should copy v4, not v3 (§4.1, §11.2) |
| **`bracket` / finalisers** | two mechanisms, not one: `Scope` holds a keyed `Map` of finalisers run LIFO on close (`effect:…/effect.ts:3941-3962`, `:4002-4023`), and `onExitPrimitive` is a *stack* frame with `contA`/`contE`/`contAll` (`:4137-4174`) | P2 §6.3: *"a push onto `finalizers` and a flag"*, one list on the fiber | **adapt.** One list is not enough: a scope outlives the expression that created it and a bracket does not. Measured: build 2.1 µs/finaliser, unwind 199 ns/finaliser, LIFO confirmed (§9.5) |
| **uninterruptible regions** | a `boolean` on the fiber plus a `setInterruptibleTrue` sentinel pushed on `_stack` (`effect:…/effect.ts:4484-4504`); `uninterruptibleMask(restore)` hands back `interruptible` (`:4550-4562`) | P2 §6.3: *"an uninterruptible flag over the acquire and over the release"* | **copy, and note the missing half.** P2 has the flag and not the *mask with restore*, which is what `acquireUseRelease` needs to keep `use` interruptible between two uninterruptible ends (§4.2, §5.3) |
| **deferred interrupt while running** | `_deferredInterrupt`: an interrupt arriving at a fiber that is *on the stack* is latched and delivered at the next op or next `getCont` (`effect:…/effect.ts:609-615`, `:667-670`, `:714-717`) | **P2 is silent** | **decision needed.** beni's fast path re-enters the same fiber synchronously; without this latch a re-entrant interrupt corrupts the unwind (§4.3, §11.5) |
| **`Cause`** | a **flat array** of `Fail` / `Die` / `Interrupt` reasons with per-reason annotations (`effect:packages/effect/src/internal/core.ts:138-176`); `combine` is concat-with-dedupe (`effect:…/effect.ts:265-281`). v3's `Sequential`/`Parallel` tree is deleted (`effect:migration/cause.md:3-7`, `:23-27`) | **P2 is silent.** Report 16 §5.2 has `outcome : ?Exit a` and nothing about what the failure *is* | **decision needed, and copy v4's answer.** beni has no exceptions, so `Die` is what a throwing `foreign` becomes and `Interrupt` is not a `Result` — neither fits `Result e a` (§6, §11.6) |
| **fork variants** | `forkChild` (parent's `children`), `forkDetach` (daemon), `forkIn(scope)` / `forkScoped` (a scope finaliser interrupts it) — `effect:…/effect.ts:5418-5596`; renamed from v3 (`effect:migration/forking.md:8-15`) | P2 §6.5 has `Task.spawn` and `Scope.spawn` — two of the four | **adapt: take three.** `forkDetach` is missing from P2 and is what a background task needs; `startImmediately` is a real knob measured at **6.7×** (§9.2) |
| **child interruption on parent exit** | `fiberMiddleware.interruptChildren`, installed *only* by `forkChild` so it tree-shakes away (`effect:…/effect.ts:632-637`, `:792-796`, `:6859-6861`) | P2 §6.4 `children : ?Set(*Fiber)` and §6.2 obligation 4 | **copy, including the tree-shaking trick** — beni has `Reach.zig` and the same problem (§5.2) |
| **services / fiber-locals** | `Context` = a base `Map` + an overlay linked list capped at depth 8 (`effect:packages/effect/src/Context.ts:474-506`, `:531-545`, `:787-808`), plus a *derived cache* recomputed only when the `cacheRoot` changes (`effect:…/effect.ts:742-757`, `:764-781`). v3's FiberRef patch/diff-on-fork is deleted (`effect:migration/fiberref.md:3-5`) | **P2 is silent**; P2 §9.3 recommends "a capability record passed as an argument" | **not needed for v1, and P2's answer is right.** But the *scheduler itself* is a fiber-local in v4, and beni will want one too (§7.3) |
| **stack traces** | a `StackFrame` linked list on a fiber-cached reference; `Effect.fn` pushes a frame per call built from a `new Error()` captured at `stackTraceLimit = 2`, stringified lazily (`effect:…/effect.ts:1334-1355`, `:466-489`; `effect:packages/effect/src/internal/tracer.ts:18-44`) | P2 §7.4: *"each continuation carries the source span of the call it resumes"* and the runtime keeps the chain | **copy the shape, and beni gets it far cheaper.** Effect pays 7.2 µs per call for what beni's compiler knows statically (§8.1, §9.6) |
| **`Exit` is an `Effect`** | `Exit.Proto extends Effect.Effect` (`effect:packages/effect/src/Exit.ts:86`), which is what makes `flatMapEager`/`mapEager`/`fromIteratorEagerUnsafe` able to short-circuit (`effect:…/effect.ts:1842-1865`, `:1379-1416`) | n/a | **not needed** — beni has no such value; the compiler does this at compile time |
| **generators** | `Effect.gen` builds a `SingleShotGen` and an `Iterator` primitive whose `contA` pumps `iter.next(value)` and only touches `_stack` when the yielded value is not already an `Exit` (`effect:…/effect.ts:1419-1451`) | P2 §7.1 rejects generators (L3) | **not needed, and P2's reason is right** — but the measurement is a surprise: `gen` is **faster** than `flatMap` in v4, 67 ns vs 82 ns (§9.1), because the generator *is* the continuation and allocates nothing |
| **`Semaphore` / `Latch` / `Deferred` / waiter removal** | a `Set` of observer thunks; the cancelled-waiter obligation is discharged by the canceller returned from `callback` — `self.waiters.delete(observer)` (`effect:packages/effect/src/Semaphore.ts:207-223`) | report 16 §5.3 row 10 states the obligation; P2 §6.5 repeats it | **copy.** One mechanism — the canceller returned by the suspension primitive — discharges it for `Semaphore`, `Latch`, `Deferred`, `Fiber.await` and `Fiber.joinAll` alike (§5.6) |
| **bounded concurrency** | `iterateConcurrentImpl`: one parent `callback`, daemon forks, a `paused` flag at the limit, and a synchronous fast path that forks nothing (`effect:…/effect.ts:4981-5128`) | P2 §6.5 `Task.parAll : Int, List (() -> a) -> List a`, bound mandatory | **copy the shape.** 126 lines. The mandatory bound is right and Effect does not enforce it (§5.5) |
| **runtime flags / supervisors** | **deleted in v4.** No `RuntimeFlags` bitset, no `FiberStatus`, no global fiber registry, `OpSupervision` removed with no replacement (`effect:migration/annotations/effect__RuntimeFlags.yaml:76-99`, `effect__FiberStatus.yaml:4-6`, `effect__Fiber.yaml:103-105`) | P2 §11 Q11 asks whether observability is a v1 deliverable | **evidence for "no".** The gold standard shipped v4 by *removing* its supervision surface (§8.4) |

### 0.2 Five things P2 §6–§7 gets right, on this evidence

1. **Owning the resume callback is the whole decision, and the v4 rewrite did not touch it.** Report
   16 §2.4 measured 56 ms on v3; the identical experiment on v4 gives **57 ms**, against 301 ms for
   native `async` + `AbortController`. The mechanism was rewritten and the number did not move (§4.4).
2. **The synchronous fast path is real and Effect keeps re-implementing it.** A `callback` that
   resumes before returning stays on the stack (`effect:…/effect.ts:1163-1172`); `flatMapEager`,
   `mapEager` and `fromIteratorEagerUnsafe` exist only to take it; `iterateConcurrentImpl` has it
   as a named branch. P2 §7.2 is the one place beni gets it for free, at compile time.
3. **A macrotask escape, not an op counter, is what unfreezes the page.** v4 agrees so completely
   that it deleted the microtask path from its async scheduler (§3.3).
4. **`bracket` as a finaliser list rather than `try`/`finally` is correct**, and the generator's own
   `finally` is still never run on interruption in v4 — report 16 §2.5's finding reproduces verbatim
   (§5.4).
5. **A thunk, never a started computation.** Every v4 retry/repeat/race takes an `Effect` value,
   which is a description; the one place it takes a started thing (`Fiber`) it must also take an
   observer-removal callback (`effect:…/effect.ts:577-594`). Report 16 §5.3 row 8's rule holds.

### 0.3 Five things P2 §6–§7 has not thought about

1. **A re-entrant interrupt.** P2's fast path resumes inline on the same stack, so an interrupt can
   arrive at a fiber that is *currently inside its own run loop*. v4 needs three separate pieces of
   state for this — `_running`, `_deferredInterrupt` and a `getCont` that can return a synthetic
   interrupt continuation (`effect:…/effect.ts:561-562`, `:667-670`, `:714-717`, `:783-790`). P2 has
   none of them, and `research/16` §5.2's field list does not either.
2. **Two finaliser mechanisms, not one.** `Scope` (an object with an identity, passed around, closed
   explicitly) and `onExit` (a frame on the continuation stack, popped when the expression ends) are
   different lifetimes and v4 implements them separately. P2 §6.3 has one list on the fiber and
   P2 §6.5 has `Task.scope` as if it were the same thing.
3. **What an interrupt *is*, as a value.** beni has no exceptions and P2 §5 says errors are `Result`
   values, so there is nowhere for "this fiber was killed" or "your `foreign` threw" to go. v4's
   answer is `Cause` with three reason kinds, flat, and it is the part of v4 most directly
   applicable to a language that has decided against exceptions (§6, §11.6).
4. **The `where`-clause hazard has a runtime twin.** Plan §2.1 found that `core/List.js`'s
   JavaScript loop calling a suspending `m0` is a silent miscompile. v4 has exactly this class of
   boundary and closes it by *making the loop an effect* — `fiberAwaitAll`'s `loop()`
   (`effect:…/effect.ts:839-855`) is a hand-written recursion that re-enters through `addObserver`
   rather than through the stack. Every hand-written JavaScript loop in v4 that touches an effect is
   written this way. That is the shape `core/List.js` would have to take under plan §5 decision 6(c).
5. **`startImmediately`.** v4 makes a fork's *start* a caller choice, because the default
   (schedule it) costs a macrotask. Measured: 472 ns per immediate fork+join pair against 3172 ns
   for a scheduled one, **6.7×** (§9.2). P2 §6.5's `Task.spawn` has no such knob and, read literally,
   specifies the expensive one.

### 0.4 The minimal kernel, sized against v4

Effective (non-blank, non-comment, non-doc) lines of the v4 code that implements each piece, measured
by stripping `packages/effect/src`. beni's column is the same job with no interpreter, no dual API,
no variance phantoms, no `Pipeable`, and a compiler that has already done the CPS.

| primitive | v4 lines | v4 location | beni estimate |
|---|---:|---|---:|
| the fiber record + run loop + `getCont` | 220 | `effect:…/effect.ts:528-762` | 120 |
| the primitive/continuation protocol | 154 | `effect:packages/effect/src/internal/core.ts:365-530` | **0** — the compiler emits it |
| `succeed` / `sync` / `suspend` / `yieldNow` | 60 | `effect:…/effect.ts:966-1043` | 15 |
| the suspension primitive (`callback`) + its canceller frame | 74 | `effect:…/effect.ts:1148-1224` | 50 |
| `flatMap` / `map` continuation objects | 52 | `effect:…/effect.ts:1471-1532` | **0** — closures |
| interruptibility regions and masks | 72 | `effect:…/effect.ts:4480-4577` | 60 |
| fiber `await` / `join` / `interrupt` / `interruptAll` | 137 | `effect:…/effect.ts:812-963` | 110 |
| fork variants + `forkUnsafe` | 169 | `effect:…/effect.ts:5418-5596` | 60 |
| `Scope` + finalisers + `acquireRelease` | 191 | `effect:…/effect.ts:3900-4135` | 150 |
| `onExit` as a stack frame | 38 | `effect:…/effect.ts:4137-4174` | 35 |
| the scheduler (priority buckets, dispatcher, macrotask escape) | 128 | `effect:packages/effect/src/Scheduler.ts` | 90 |
| `Cause` (three reasons, flat, annotations, combine, squash) | 212 | `effect:…/core.ts:102-362` | 90 |
| `Cause.pretty` and the stack-frame walk | 158 | `effect:…/effect.ts:335-508` | 120 |
| `race` / `raceAll` | 54 | `effect:…/effect.ts:1606-1661` | 50 |
| bounded concurrency (`parAll`) | 126 | `effect:…/effect.ts:4981-5128` | 110 |
| `Latch` | 87 | `effect:…/effect.ts:5755-5860` | 60 |
| `Semaphore` | 103 | `effect:packages/effect/src/Semaphore.ts:205-320` | 90 |
| the `run*` entry points | 126 | `effect:…/effect.ts:5602-5753` | 50 |
| **total** | **2 161** | | **~1 260** |

Measured bundle, for a sanity check on the totals: an `esbuild --bundle --minify` of
`Effect.succeed(123).pipe(Effect.runFork)` is **25 118 B raw / 9 094 B gzip**; the same with
`forkChild`, `Fiber.join`, `scoped`, `acquireRelease`, `race` and `timeout` is **39 706 B /
14 155 B** (§9.7). So *the whole concurrency surface* costs about 5 kB gzip on top of the base. For
beni that is the number to hold `platforms/node/runtime.js` to, and `bench/corpus`'s 15 017 brotli
bytes is the thing it would be measured against.

**The eleven-primitive list of P2 §6.5 is the right surface and is not the kernel.** Seven of the
eleven — `par2`, `parAll`, `race`, `timeout`, `retry`, `Semaphore.with`, `Queue`,
`RateLimiter.with` — are *library code over the kernel* in v4 too, written in terms of `callback`,
`forkUnsafe` and `addObserver`. The kernel is the first ten rows of that table, ~600 lines.

### 0.5 The experiments the spike must run

Ordered by how much they can change the plan.

1. **The browser latency histogram** (`research/16` §6, P2 §11 Q3a) — still unrun, and now more
   urgent for a new reason: v4's scheduler uses `setImmediate` where available and falls back to
   `setTimeout(f, 0)` (`effect:…/Scheduler.ts:93-103`). In a browser there is no `setImmediate`, and
   `setTimeout(0)` is clamped to 4 ms after five nested levels. So **v4's default scheduler is a Node
   design** and beni must not copy the escape mechanism blind: measure `MessageChannel` /
   `postMessage` (kotlinx's choice, `research/16` §4.7) against `setTimeout` at budgets 16 / 64 /
   512 / 2048, in Chrome and Firefox.
2. **Re-run §9.3's budget sweep on beni's own runtime and pick the number from it, not from Cats
   Effect.** On Node, 512 buys 1.7 ms latency at a throughput cost inside the noise, and 64 costs
   1.4× for no latency gain (§9.3). P2 §7.5's 64 is not supported by any measurement.
3. **The re-entrant interrupt fixture.** Fork a fiber whose next primitive resumes synchronously,
   interrupt it from inside its own continuation, assert the finalisers ran once and the value is
   not delivered. This is §0.3 item 1 and there is no existing beni analogue.
4. **`run/ListEqSuspendingElement`** (plan §6 row 1) — write it before deciding §5 decision 6, and
   write the (c) variant too: make `core/List.js`'s `eq` re-enter through an observer the way
   `fiberAwaitAll` does, and measure it. If (c) is 10 lines and costs nothing, decision 6's
   "widens the privileged surface" objection is weaker than it looks.
5. **Fiber size and fork cost against beni's own record.** v4's parked fiber is **419 B** with no
   canceller and **659 B** with one (§9.4). `research/16` §3.8 measured beni's proposed record at
   692 B and called it *"0.2× an Effect fiber"* — that was 3 450 B on v3. **On v4 the ratio is 1.05,
   not 0.2**, so fiber size is no longer a beni advantage and P2 §11 Q3(b)'s "can the record be
   lazy?" gets more important, not less.
6. **Unwind cost at depth** (P2 §11 Q3c) — v4: 2 076 ns to install a scope finaliser, 199 ns to run
   it on an interrupt, LIFO confirmed at depth 5 (§9.5). Install cost dominating run cost by 10× is
   the finding; beni's `bracket` must not pay v4's `uninterruptibleMask` + `contextWith` + `Map.set`
   per acquire.

---

## 1. Method

### 1.1 What was read

`references/effect` at `3d59ae6d5f9ff3e52cb6ed4a9f325320580218d5` (2026-09-19),
`packages/effect/package.json` version `4.0.0-rc.116`.

Read in full: `packages/effect/src/internal/core.ts` (693 lines), `Scheduler.ts` (308),
`internal/tracer.ts` (46), `internal/stackTraceLimit.ts` (59), `internal/references.ts` (69),
`Semaphore.ts:205-320`, `Fiber.ts:60-220`, `Pipeable.ts:564-594`, `Effectable.ts:32-44`.

Read in the regions cited, out of `packages/effect/src/internal/effect.ts` (6 912 lines): `100-508`
(Cause), `510-963` (the fiber, await/join/interrupt), `966-1532` (primitives, `callback`, `gen`,
`fn`, continuations), `1606-1950` (race, flatMap/map, the eager family), `3806-4250` (timeout,
Scope, `acquireRelease`, `onExit`), `4320-4620` (interruption), `4981-5230` (bounded concurrency),
`5400-5860` (forks, `run*`, `Latch`), `6855-6880`. Also `Context.ts:240-275`, `:465-545`, `:780-960`.

Documents: `MIGRATION.md`, `migration/{cause,forking,fiberref,runtime,generators,yieldable,`
`layer-memoization,equality,fiber-keep-alive}.md`, `migration/annotations/*.yaml` (539 files,
searched), `LLMS.md`, `packages/effect/CHANGELOG.md` (4 529 lines, searched), and the whole of
`packages/effect/runtimeperf/`, `typeperf/`, `benchmark/`, `packages/tools/bundle/`.

### 1.2 What was run

**`effect@4.0.0-rc.116` installed from npm** into a scratchpad — the same version as the vendored
tree, so the source read and the code measured are the same code. Node **v24.19.0**.

Machine: Ryzen 9 5950X (16c/32t), Linux 6.12.110. **The machine was busy throughout** — other agents
were running `zig build` concurrently, `uptime` reported a 1-minute load average between **16.4 and
44.7** during the runs. Every table below therefore reports **min of N repetitions**, and §9.1
carries an in-process normaliser (a direct JS call) so that *ratios* are defensible even where
absolute numbers are inflated. Where a number is used to draw a conclusion, the conclusion is stated
as a ratio.

Eight scripts, all in the scratchpad: `e1-loop.mjs` (interpreter cost per op),
`e2-fastpath.mjs` (sync path, fork/join), `e3-cancel.mjs` (report 16 §2.4 re-run),
`e4-fair.mjs` (report 16 §2.3 re-run), `e5-budget.mjs` (op-budget sweep),
`e6b-mem.mjs` (allocation, one sample per process), `e7-observability.mjs` (`Effect.fn`, context),
`e8b-unwind.mjs` (finaliser install and unwind), `e9-headline.mjs` (the normalised table).

### 1.3 What was not run

- **Nothing in a browser.** This is Node-only, exactly as `research/16` was, and §0.5 item 1 is the
  consequence.
- **No comparison against Effect v3.** v3 was not installed. Where this report says "v3 did X", the
  source is either `research/16`'s own measurement of 3.22.2 or a `migration/` document, and it is
  labelled as such.
- **No rollup/terser bundle.** §9.7's bundle figures are `esbuild --bundle --minify`, which is not
  the toolchain `MIGRATION.md`'s 6.3 kB figure was produced with; the numbers are not directly
  comparable and §9.7 says so.
- **No profiling, no heap snapshots.** §9.4's allocation figures are `heapUsed` deltas around forced
  GC, one sample per process.

---

## 2. What an effect *is* at runtime

### 2.1 The primitive protocol

There is no `Effect` class and no opcode. An effect is any object whose prototype carries four
symbol-keyed slots (`effect:packages/effect/src/internal/core.ts:365-381`):

```ts
export interface Primitive {
  readonly [identifier]: string
  readonly [contA]: ((value, fiber, exit?) => Primitive | Yield) | undefined
  readonly [contE]: ((cause, fiber, exit?) => Primitive | Yield) | undefined
  readonly [contAll]: ((fiber) => ((value, fiber) => Primitive | Yield) | undefined) | undefined
  [evaluate](fiber: FiberImpl): Primitive | Yield
}
```

`makePrimitiveProto` builds that prototype (`:393-422`) and `makePrimitive` wraps it in a
one-field constructor storing the argument under `[args]` (`:425-466`). The three continuation slots
are what a stack frame does: `contA` on success, `contE` on failure, `contAll` on *both* — the last
is how interruptibility sentinels and `onExit` frames get to run whichever way control leaves
(`:410-413`).

The fiber's dispatch is one line (`effect:packages/effect/src/internal/effect.ts:683-685`):

```ts
current = cache.tracerContext
  ? cache.tracerContext(current as any, this)
  : (current as any)[evaluate](this)
```

`grep -rn "OP_" packages/effect/src/internal/core.ts` returns nothing. v3's `switch` on an opcode
integer is gone; each primitive carries its own method, which is a megamorphic call site but also
what makes the whole thing tree-shakeable — an unused primitive is an unreferenced module-level
object.

### 2.2 The continuation stack

`_stack: Array<Primitive>` (`:538`, declared `:555`). A combinator that needs to run something after
a sub-effect *is* a primitive, and its `[evaluate]` pushes itself and returns the sub-effect
(`:1471-1474`):

```ts
const evaluateCont = function(this: any, fiber: FiberImpl): Primitive {
  fiber._stack.push(this)
  return this[args]
}
```

`getCont` pops until it finds a frame carrying the slot it wants (`:710-731`), running each frame's
`contAll` on the way past. That is the entire unwinding mechanism: a failure and a success walk the
same array, looking for different slots.

**One array of objects, not two.** Report 16 §5.2 recommends *"CE3's split `conts: ByteStack` +
`objectState: ArrayStack`"* for beni. That layout exists because Cats Effect stores the *kind* of
each continuation as a byte and its payload separately; v4 does not, because the kind is the object's
prototype. For beni the question does not arise at all: beni's continuations are **closures the
compiler emitted**, so the stack is an `Array<fn>` and there is no kind to store.

### 2.3 `flatMap`, `map`, and the shared-continuation trick

`flatMap` allocates one object with two fields (`:1792-1806`, `:1486-1490`): `[args] = self`,
`[contA] = f`. `map` is `new ContImpl(self, mapCont, f)` where `mapCont` is a **shared module-level
continuation** reading its argument from a third `payload` slot (`:1496-1531`). The comment at
`:1492-1495` says why: *"combinators like map / as / tap / andThen can share module-level
continuation functions instead of allocating a closure per call."* Measured: a `map` node is
**104 B**, a `flatMap` node **96 B**, an `Effect.sync` node **128 B** (§9.4) — sharing does not make
`map` smaller here, because its payload is still the user's closure.

### 2.4 `succeed` is an `Exit`, and that is load-bearing

`succeed === exitSucceed` (`:966`), and an `Exit` is itself an effect
(`effect:packages/effect/src/Exit.ts:86`: `interface Proto<A, E> extends Effect.Effect<A, E>`). Its
`[evaluate]` is a direct hand-off to the next continuation with no allocation:
`const cont = fiber.getCont(contA); return cont ? cont[contA](this[args], fiber, this) :
fiber.yieldWith(this)` (`effect:…/core.ts:521-523`).

Because an already-resolved value is indistinguishable from an effect, v4 can test
`effectIsExit(self)` and skip the machinery entirely — `mapEager = (self, f) =>
effectIsExit(self) ? exitMap(self, f) : map(self, f)` (`:1907`). That one test is the whole of the
**eager family**: `flatMapEager`, `mapEager`, `catchEager`, `matchEager`, `mapErrorEager`,
`mapBothEager` (`:1846-1942`).

**For beni:** none of §2 exists. beni's compiler emits the continuation as a closure and the
scheduler never sees a description of the program. The 154 effective lines of `core.ts:365-530` are
a cost of being a library, not of being a fiber runtime. What *does* transfer is that an effect
which has already produced its value must be recognisable in O(1) and must not enter the loop —
which in beni is the §7.2 fast path, a compile-time property rather than a runtime test.

### 2.5 Generators, and why they are fast in v4

`Effect.gen(f)` is `suspend(() => fromIteratorUnsafe(f()))` (`:1230-1253`). The `Iterator` primitive
(`:1419-1451`) drives the generator from its `contA`:

```ts
while (true) {
  const state = iter.next(value)
  if (state.done) return succeed(state.value)
  if (!effectIsExit(state.value)) { fiber._stack.push(this); return state.value }
  else if (state.value._tag === "Failure") return state.value
  value = state.value.value
}
```

The `while (true)` is the point: a `yield*` of an already-resolved `Exit` is consumed **inside the
loop**, without pushing anything on `_stack` and without returning to the run loop. Only a genuine
effect costs a push. `fromIteratorEagerUnsafe` (`:1379-1416`) takes this further and runs the whole
generator eagerly, falling back to `suspend` only at the first non-`Exit` yield.

Measured (§9.1, normalised): `yield* Effect.succeed(i)` costs **67 ns**, a `flatMap` step costs
**82 ns**. **The generator is cheaper than the combinator.** That is the reverse of the received
wisdom and of `14/effect-ts` §2.4's cost argument, and the reason is structural: the generator frame
*is* the continuation, so nothing is allocated for it.

**For beni:** P2 §7.1's rejection of L3 (native generators) stands on its stated reason — `yield`
cannot cross a function boundary, so every effectful lambda becomes its own generator
(`14/javascript` §0.2). This measurement does not weaken that argument. But it does retire a
*different* argument that has been made in passing: generators are not slow here, and "CPS is faster
than generators" is not a claim this report supports.

---

## 3. The fiber

### 3.1 The record

`FiberImpl` (`effect:…/effect.ts:528-762`), fields at `:550-572`:

| field | v4 | P2 §6.4 / report 16 §5.2 |
|---|---|---|
| `id: number` | `++fiberIdStore.id` (`:522`, `:535`) | absent. v3's composite `FiberId` was deleted (`effect:migration/annotations/effect__FiberId.yaml:13-15`) |
| `interruptible: boolean` | `:553` | P2 §6.3's "flag" |
| `currentOpCount: number` | `:554` | `opCount : u32` ✓ |
| `_stack: Array<Primitive>` | `:555` | **absent from P2**; report 16 §5.2 says it returns under shape T |
| `_observers: Array<(exit) => void> \| undefined` | `:556` | `observers` ✓ |
| `_exit: Exit \| undefined` | `:557` | `outcome` ✓ |
| `_children: Set<FiberImpl> \| undefined` | `:558` | `children` ✓ |
| `_interruptedCause: Cause \| undefined` | `:559` | **absent** — P2 has no `Cause` |
| `_yielded: Exit \| (() => void) \| undefined` | `:560` | **absent** — this is the one-shot disarm (§4.1) |
| `_running: boolean` | `:561` | **absent** (§4.3) |
| `_deferredInterrupt: boolean` | `:562` | **absent** (§4.3) |
| `_parent: FiberImpl \| undefined` | `:563` | `parent` ✓ |
| `context: Context` + `cache: Fiber.Cache` | `:566-567` | **absent** (§7) |
| `_dispatcher` | `:569-572`, lazily `cache.scheduler.makeDispatcher()` | absent |
| — | — | `finalizers : ?[]fn(Exit a)` — **v4 has no such field** (§5.1) |
| — | — | `interruptor : ?fn(Exit a)` — **v4 deleted it** (§4.1) |

Two of report 16 §5.2's seven fields are not in v4, and four fields v4 needs are not in report 16.
Measured size of a parked fiber: **419 B** with no canceller, **659 B** with one (§9.4).

### 3.2 The run loop

`runLoop` (`:657-709`) is 40 lines and is the whole interpreter. Its body, elided:

```ts
const prevFiber = globalThis[currentFiberTypeId]; globalThis[currentFiberTypeId] = this
const prevRunning = this._running; this._running = true
let yielding = false; this.currentOpCount = 0
try {
  while (true) {
    if (this._deferredInterrupt) { this._deferredInterrupt = false; current = failCause(this._interruptedCause!) }
    this.currentOpCount++
    const cache = this.cache
    if (!yielding && !cache.preventYield && cache.scheduler.shouldYield(this)) {
      yielding = true; const prev = current; current = flatMap(yieldNow, () => prev)
    }
    current = cache.tracerContext ? cache.tracerContext(current, this) : current[evaluate](this)
    if (current === Yield) { … return Yield }
  }
} catch (error) { … return this.runLoop(exitDie(error)) }
finally { this._running = prevRunning; globalThis[currentFiberTypeId] = prevFiber }
```

Four things to notice. **The current fiber is a global** — `globalThis[currentFiberTypeId]`, saved
and restored around every `runLoop` (`:658-659`, `:707`), which is what makes `getCurrentFiber()`
(`:525`) work inside a `sync` thunk and what makes `runLoop` re-entrant-safe. **A thrown JavaScript
exception becomes a `Die` and re-enters the loop** (`:704`) — one `try` for the whole program.
**The yield is inserted into the program, not around it** (`:681`), so the fiber re-enters at
exactly the effect it was about to run. And **`yielding` is set once per `runLoop` entry**, so a
resumed fiber gets a full fresh budget.

`evaluate` (`:620-656`) is the outer shell: disarm any pending resume, run the loop, and on a real
exit publish it — interrupt the children first if the middleware is installed (`:632-637`), record
metrics, detach from the parent, call the observers, then **clear `_stack`, `_children` and
`context`** (`:653-655`). That last line is the leak fix: a completed fiber holds nothing.

### 3.3 Yielding and the scheduler

`shouldYield` is one comparison (`effect:packages/effect/src/Scheduler.ts:184-186`):

```ts
shouldYield(fiber) { return fiber.currentOpCount >= fiber.cache.maxOpsBeforeYield }
```

`MaxOpsBeforeYield` is a `Context.Reference` defaulting to **2048** (`:279-282`), and
`PreventSchedulerYield` turns the check off entirely (`:305-308`).

`yieldNow` is a primitive that schedules a task and parks (`effect:…/effect.ts:1028-1043`):

```ts
[evaluate](fiber) {
  let resumed = false
  fiber.currentDispatcher.scheduleTask(() => { if (resumed) return; fiber.evaluate(exitVoid) }, this[args] ?? 0)
  return fiber.yieldWith(() => { resumed = true })
}
```

**The scheduler's queue.** `MixedSchedulerDispatcher` (`Scheduler.ts:203-257`) holds
`PriorityBuckets` — an array of `[priority, tasks[]]` kept sorted, lower priority first, FIFO within
a priority (`:115-141`). One timer per *drain*, not per task (`:217-222`):

```ts
scheduleTask(task, priority) {
  this.tasks.scheduleTask(task, priority)
  if (this.running === undefined) this.running = this.setImmediate(this.afterScheduled)
}
```

**And this is the v3→v4 change that matters most to beni.** `setImmediate` here is
(`:93-113`):

```ts
const setTimer = "setImmediate" in globalThis
  ? (f) => { const t = globalThis.setImmediate(f); return () => globalThis.clearImmediate(t) }
  : (f) => { const t = setTimeout(f, 0); return () => clearTimeout(t) }
```

**Every yield in async mode is a macrotask.** Report 16 §2.3 read v3's `MixedScheduler` and found
*two* counters — an op budget of 2048 and a separate `maxNextTickBeforeTimer` of 2048 nested
*microtask* drains, so that the first macrotask escape came at roughly 2048 × 2048 ≈ 4.2 M ops. That
second counter does not exist in v4. `grep` for `maxNextTickBeforeTimer` across the whole repository
returns nothing, and the only `2048` in `packages/effect` is the op budget. The
`migration/` guides do not mention the change at all, so this is a source-and-measurement finding,
not a documented one.

The consequence is measured in §9.3: report 16 §2.3's exact experiment — 2 M `Effect.sync` ops with
a `setTimeout(0)` armed at the start — froze the timer for **361 ms** on v3 and for **8.9 ms** on v4.

Sync mode (`runSync`) uses a microtask instead (`Scheduler.ts:171`) and `runSyncExit` calls
`fiber._dispatcher?.flush()` to drain it synchronously (`effect:…/effect.ts:5726-5735`).

### 3.4 The synchronous fast path

Three distinct places.

- **`runSyncExit` never builds a fiber for an already-resolved effect**:
  `if (effectIsExit(effect)) return effect` (`:5729`). Measured at **3.9 ns**, against ~460 ns for
  `runSync(Effect.sync(…))` which does build one (§9.2).
- **`callback`'s register may resume before it returns** (`:1148-1198`). The
  `yielded`/`resumed` handshake:

  ```ts
  let resumed = false, yielded: boolean | Primitive = false
  const onCancel = register((effect) => {
    if (resumed) return
    resumed = true
    if (yielded) fiber.evaluate(effect); else yielded = effect
  }, controller?.signal)
  if (yielded !== false) return yielded     // ← resumed inline; never left the stack
  yielded = true; fiber._yielded = () => { resumed = true }
  ```

  A primitive that has its answer already returns it as the *next effect*, on the same stack, in the
  same tick. **This is P2 §7.2, in Effect, in seven lines.** Measured at 186 ns per op inside a
  `runSync` loop against 67 ns for a bare `succeed` (§9.1) — so the suspension *protocol* costs
  ~120 ns even when nothing suspends, which for beni is a static branch instead.
- **`iterateConcurrentImpl` forks nothing until it meets a real effect** (`:5016-5021`), comment
  *"fast case (already an exit)"*, and only then *"enter async mode"* by wrapping the rest of the
  iteration in a `callback`.

### 3.5 Stack safety

Deep `flatMap` chains are safe because nothing recurses: `evaluateCont` pushes and returns, the
`while (true)` in `runLoop` iterates. The JavaScript stack depth is O(1) in the length of the chain.
The exception is `runLoop`'s own `catch`, which calls itself once (`:704`).

Effect's own test for this is thin — `packages/effect/test/Effect.test.ts:2312-2321` is the only
`describe("stack safety")` block, and it is `Effect.void.pipe(Effect.flatMap(() => loop))` under a
50 ms timeout, with no N.

**For beni:** the guarantee beni needs is different and harder. Under P2 §7.2's fast path *nothing
returns to the scheduler*, so a synchronous chain of suspendable calls grows the real JavaScript
stack. Plan §2.2 already flags this for mutual recursion; §3.4's measurement is the reason it is not
hypothetical. v4's answer would be the op budget forcing a yield every 2048 ops, which turns a stack
into a heap queue — beni's equivalent is that the trampoline must return to the loop on the budget,
not only on a genuine suspension.

---

## 4. Interruption

### 4.1 The mechanism, and how it changed from v3

`interruptUnsafe` (`:595-616`) builds an `Interrupt` cause annotated with the interruptor's stack
frame, merges it into `_interruptedCause`, and then:

```ts
if (this.interruptible) {
  if (this._running) this._deferredInterrupt = true
  else this.evaluate(failCause(this._interruptedCause))
}
```

A parked interruptible fiber is **resumed with a failure**, immediately, synchronously, on the
interruptor's stack.

`evaluate`'s first act is the disarm (`:620-627`):
`else if (this._yielded !== undefined) { const y = this._yielded; this._yielded = undefined; y() }`.

`_yielded` is the thunk `callback` installed — `() => { resumed = true }` (`:1174-1176`). Calling it
makes the abandoned primitive's later `resume` a no-op. **That is the one-shot guarantee**
(report 16 §5.3 row 3, obligation 3).

Then the run loop unwinds. `failCause`'s `[evaluate]` walks `getCont(contE)`
(`effect:…/core.ts:541-555`) and finds the frame `callback` pushed (`effect:…/effect.ts:1180-1187`):

```ts
fiber._stack.push(asyncFinalizer(() => { resumed = true; controller?.abort(); return onCancel ?? exitVoid }))
```

and `asyncFinalizer` runs it — but only for an interrupt, and uninterruptibly
(`:1200-1215`):

```ts
[contAll](fiber) { if (fiber.interruptible) { fiber.interruptible = false; fiber._stack.push(setInterruptibleTrue) } },
[contE](cause) { return hasInterrupts(cause) ? flatMap(this[args](), () => failCause(cause)) : failCause(cause) }
```

**What changed from v3.** Report 16 §2.4 quotes v3's four lines:
`OP_INTERRUPT_SIGNAL` → `this._asyncInterruptor(exitFailCause(cause))`, and P2 §6.4 puts
`interruptor : ?fn(Exit a)` on the fiber record on the strength of it. **`_asyncInterruptor` does not
exist in v4** — the identifier returns zero hits across the whole repository. The canceller is a
*continuation frame*, and the disarm is a separate one-shot thunk.

This is a better design and beni should take v4's, not v3's: the canceller is found by the *same*
unwinding walk that runs `bracket`'s releases, so there is one mechanism instead of two; it composes
with nesting for free (two suspensions in flight are two frames); it is automatically uninterruptible
while it runs (`contAll`); and it runs **only on an interrupt** (`hasInterrupts`), not on an ordinary
failure — a distinction P2 §6.3 does not draw.

### 4.2 Interruptible regions

`uninterruptible` is a flag plus a sentinel on the stack (`:4484-4504`): it sets
`fiber.interruptible = false` and pushes `setInterruptibleTrue`, whose `contAll` is

```ts
[contAll](fiber) {
  fiber.interruptible = this[args]
  if (fiber._interruptedCause && fiber.interruptible) return () => failCause(fiber._interruptedCause!)
}
```

That second line is the part P2 does not have: **when the region ends and the fiber becomes
interruptible again, a latched interrupt fires**. An interrupt delivered during an uninterruptible
region is recorded in `_interruptedCause` and not acted on (`:609`); the sentinel's `contAll` is what
acts on it.

`uninterruptibleMask(f)` calls `f(interruptible)` so the body can punch a hole (`:4550-4562`), and
`interruptibleMask` is the mirror (`:4565-4577`). `acquireUseRelease` is exactly this shape
(`:4346-4358`):

```ts
uninterruptibleMask((restore) =>
  flatMap(acquire, (a) => onExitPrimitive(suspend(() => restore(use(a))), (exit) => release(a, exit), true)))
```

— acquire uninterruptible, `use` restored to interruptible, release uninterruptible by default
(`onExitPrimitive`'s `contAll` at `:4148-4153` flips the flag unless `interruptible === true`, and
here the `true` applies to `use`, not to `release`).

**For beni:** P2 §6.3 says *"sets an uninterruptible flag over the acquire and over the release"* and
stops. It needs the other three pieces: the latched `_interruptedCause`, the re-arm at region end,
and `restore`. Without `restore` there is no way to write `acquireUseRelease` at all — the body would
inherit the acquire's uninterruptibility and a long-running `use` would be uncancellable.

### 4.3 The re-entrant interrupt

`_running` and `_deferredInterrupt` exist because the fast path makes a fiber interruptible *while it
is on its own stack*. If `interruptUnsafe` called `evaluate` then, two run loops would be walking one
`_stack`. Instead it latches (`:610-611`) and the loop picks it up at the top of the next op
(`:667-670`).

`getCont` carries the same guard, one level deeper (`:714-717`):

```ts
if (this._deferredInterrupt) { this._deferredInterrupt = false; return deferredInterruptCont }
```

where `deferredInterruptCont` (`:783-790`) answers both `contA` and `contE` with
`failCause(fiber._interruptedCause!)`. So an interrupt latched mid-op is delivered at the *next
continuation boundary* even if the op was going to succeed. And `exitFailCause` has a matching loop
(`effect:…/core.ts:548-551`) that keeps popping `contE` frames while the fiber is interruptible and
interrupted, so a recovery handler cannot swallow a live interrupt.

**This is §0.3 item 1 and it is the largest thing P2's runtime specification is missing.** It is not
optional: P2 §7.2 makes synchronous resumption the headline, and synchronous resumption is precisely
what creates the re-entrancy.

### 4.4 The measurement: report 16 §2.4 re-run on v4

`e3-cancel.mjs`, the same uncooperative primitive (`new Promise(res => setTimeout(() => res('done'),
300))`), cancelled at ~50 ms:

```
   9ms E: parked on uncooperative promise
  55ms E: interrupting
  57ms E: onInterrupt ran
  57ms E: Fiber.interrupt returned; fiber exit = Failure
 458ms E: 400ms after the primitive would have settled
```

**57 ms on v4, against report 16's 56 ms on v3 and 301 ms for native `async` + `AbortController`.**
The lowering decision of 2026-09-15 is confirmed against the rewritten runtime.

Two more lines from the same run. With a canceller registered (an `Effect.callback` returning a
cleanup effect), the canceller runs at **51 ms** and `clearTimeout` fires — the timer is not left
armed. And `E: generator finally ran` **never prints**: report 16 §2.5's finding that the effect
generator is abandoned rather than closed holds verbatim in v4.

With two `acquireRelease` resources held:

```
  51ms R: interrupting
  53ms R: release B
  53ms R: release A
  54ms R: interrupt returned
```

Finalisers run **at cancel time, in LIFO order**, which is report 16 §5.3 row 3 obligations 1, 2 and
4 discharged in one trace.

---

## 5. Structured concurrency and resources

### 5.1 `Scope`

A `Scope` is a plain object — `{ …TypeIds, strategy, state }` (`:4050-4055`) — with a mutable
`state` of `Empty | Open | Closed`. `Open` has a **fast single-finaliser form** — `finalizerKey` +
`finalizer` — that only promotes to a `Map` on the second registration (`:4002-4023`). Closing
(`:3914-3933`) special-cases zero and one finaliser before falling through to
`scopeCloseFinalizers` (`:3941-3962`), which iterates **backwards** — `for (let i = arr.length - 1;
i >= 0; i--)` — and either sequences the finalisers or forks them as daemons, per `strategy`.

A finaliser that fails does not silently vanish: `combineFinalizerCause` (`:3935-3939`) merges its
cause into the exit's.

`acquireRelease` (`:4106-4122`) is `uninterruptibleMask` + `flatMap(scope)` +
`tap(acquire, a => scopeAddFinalizerExit(…))`. The finaliser is keyed by a fresh `{}` so it can be
**removed** later (`scopeRemoveFinalizerUnsafe`, `:4026-4039`) — which is what `forkIn` uses so that
a fiber completing on its own does not leave a dead finaliser behind (`:5562`).

`scoped` (`:4073-4082`) is the interesting one: it swaps the fiber's `context`, installs an
`onExitPrimitive` that restores it and closes the scope, and never allocates an effect for the close
in the common case (`scopeCloseUnsafe` returns `undefined` when there is nothing to run).

**For beni.** P2 §6.3 and report 16 §5.2 have *one* `finalizers` list, on the fiber. v4 has two
mechanisms because they have different lifetimes:

- a **`Scope`** is a value with an identity. It can be handed to `forkIn`, forked into a child scope
  (`scopeFork`, `:3965-3979`), closed explicitly, and it outlives the expression that made it.
- an **`onExit` frame** is on the continuation stack and dies when the expression does.

P2 §6.5's `Task.scope : (Scope -> a) -> a` needs the first and P2 §6.3's `Task.bracket` needs the
second. Building only the fiber-level list makes `Task.scope` impossible to implement correctly.

### 5.2 Fork variants and supervision

`forkUnsafe` (`:5454-5474`) is the whole of it:

```ts
const child = new FiberImpl(parentRuntime.context, interruptible)
if (immediate) child.evaluate(effect)
else parentRuntime.currentDispatcher.scheduleTask(() => child.evaluate(effect), 0)
if (!daemon && !child._exit) { parentRuntime.children().add(child); child._parent = parentRuntime }
```

Four dimensions: the parent, `immediate`, `daemon`, `uninterruptible: boolean | "inherit"`. The four
public forms (`effect:migration/forking.md:8-15`, source `:5418-5596`):

| v4 | v3 | shape |
|---|---|---|
| `forkChild` | `fork` | `daemon: false` — parent's `children`, interrupted when the parent exits |
| `forkDetach` | `forkDaemon` | `daemon: true` — outlives the parent |
| `forkIn(scope)` | `forkIn` | daemon, but a scope finaliser interrupts it, removed by an observer when it completes |
| `forkScoped` | `forkScoped` | `forkIn(currentScope)` |

**Child interruption is optional middleware.** `fiberMiddleware.interruptChildren` starts
`undefined` (`:792-796`), is installed only by `forkChild` calling `interruptChildrenPatch()`
(`:5443`, `:6859-6861`), and is read at the end of `evaluate` (`:632-637`) with the comment *"so it
can be tree-shaken if not used"*. A program that never calls `forkChild` does not ship the
child-interruption path.

beni has the identical problem and the identical tool: `src/js/Reach.zig` roots a build at what it
can reach, and a runtime whose child-interruption path is only reachable from `Task.spawn` gets it
for free. `run/BracketCancel` and friends must therefore assert against a build that *does* reach it,
and `emit/` must have a fixture that does not, or the elimination is untested.

**`startImmediately`.** New in v4 (`effect:migration/forking.md:58-69`) and the reason is in §9.2: a
scheduled fork costs a macrotask turn. 472 ns for an immediate fork+join pair against 3 172 ns
scheduled. P2 §6.5's `Task.spawn : (() -> a) -> Fiber a` does not say which it is; it should say, and
the default should be argued rather than inherited.

### 5.3 `onExit` as a stack frame

`onExitPrimitive` (`:4137-4174`) is the mechanism behind `ensuring`, `onError`, `onInterrupt`,
`acquireUseRelease` and `scoped`. It is 38 effective lines and carries all four slots:
`[evaluate]` pushes itself and returns the body; `[contAll]` makes the finaliser region
uninterruptible; `[contA]` and `[contE]` build the `Exit`, run the handler, and re-raise.

`onInterrupt` is defined on top of it as a filter (`:4329-4343`) — there is no separate mechanism.

### 5.4 The generator's `finally` is still not a finaliser

`getCont` pops `Iterator` primitives looking for `contE`, finds none, and the generator frame is
discarded without `.return()` ever being called. §4.4's trace confirms it. `14/effect-ts` §2.4 and
report 16 §2.5 said this about v3; it is unchanged.

beni has no generators, but the rule generalises and belongs in the spec: **the only thing that runs
on an unwind is a registered finaliser**, and a `try`/`finally` in emitted JavaScript is not one.
The beni analogue is a resource acquired into a local of a suspendable body with no `bracket` around
it — the unwinder has no way to know it exists.

### 5.5 Bounded concurrency

`iterateConcurrentImpl` (`:4981-5128`, 126 effective lines) is the engine behind `forEach`, `all`,
`validateAll` and the rest. Its shape, in order:

1. iterate items synchronously; if `onItem` returns an `Exit`, step and continue — **no fiber**;
2. on the first real effect, wrap the remainder in one `callback` and record `resume`;
3. for each item, `forkUnsafe(parentFiber, eff, true, true, "inherit")` — immediate, daemon,
   inheriting the parent's interruptibility;
4. each child's observer removes it from the set, steps the state, and resumes the parent if the
   run is done or unpauses it if it was at the limit;
5. at the limit, set `paused = true` and return;
6. the `callback`'s canceller sets `terminal` and interrupts every live child.

Note step 3's `daemon: true`: the children are **not** in `parentFiber._children`, because the
`callback`'s canceller already owns their lifetime. That avoids paying the child-set bookkeeping
twice.

**`concurrency` is a required argument of the internal function and Effect's public API defaults it
to 1.** Report 16 §5.3 row 5 and P2 §6.5 make beni's bound mandatory for a different reason —
*"901 MiB is one word away from 78.6 KiB"* — and nothing in v4 contradicts that.

### 5.6 Waiter removal is one mechanism

Report 16 §5.3 row 10 says a cancelled `Queue` taker must be removed from the waiter list, and that
this is why `finalizers` must exist before `Queue` can be written. **In v4 the mechanism is the
canceller returned from `callback`**, and it is the same three lines everywhere:

- `Semaphore` (`effect:packages/effect/src/Semaphore.ts:207-223`):
  `self.waiters.add(observer); return internal.sync(() => { self.waiters.delete(observer) })`
- `Latch` (`effect:…/effect.ts:5818-5823`): `this.waiters.push(resume)`, canceller splices it out
- `Fiber.await` (`:813-822`): `sync(self.addObserver(…))` — `addObserver` *returns* its own remover
  (`:587-593`)
- `Fiber.joinAll` (`:870-900`): a `cancels` array, all called from the canceller

Verified empirically (§9.5, case e): 20 000 fibers parked on a 1-permit semaphore, all interrupted,
then a `take` that completes — which it could not if the waiter set had leaked.

**For beni:** this retires the need for a `finalizers` field on the fiber *for this purpose*. If the
suspension primitive can return a canceller, every waiter list is cleaned by the same path as every
`bracket`.

---

## 6. `Exit` and `Cause`

### 6.1 The failure model

`Exit<A, E> = Success<A> | Failure<E>` where `Failure` carries a `Cause<E>`
(`effect:…/core.ts:469-515`, `:518-556`), and a `Cause` is a **flat array** —
`readonly reasons: ReadonlyArray<Cause.Fail<E> | Cause.Die | Cause.Interrupt>`
(`effect:…/core.ts:138-150`). Three reasons, each a subclass of `ReasonBase` carrying `_tag` and an
`annotations: ReadonlyMap<string, unknown>` (`:181-239`):

| reason | payload | means |
|---|---|---|
| `Fail<E>` | `error: E` | the typed, expected error — beni's `Result` failure |
| `Die` | `defect: unknown` | a thrown JavaScript value; `runLoop`'s `catch` produces these (`effect:…/effect.ts:704`) |
| `Interrupt` | `fiberId: number \| undefined` | a cancellation, with the interruptor's id |

`causeCombine` is concat-with-dedupe (`:265-281`, `dedupeReasons` at `:241-262`, hashed into
buckets). `causeSquash` picks the first `Fail`, else the first `Die`, else a synthesised
`"All fibers interrupted without error"` (`:322-332`) — that is what `runSync` and `runPromise`
throw.

### 6.2 What changed from v3

`effect:migration/cause.md:3-7`: *"In v3, `Cause<E>` was a recursive tree with six variants: `Empty |
Fail<E> | Die | Interrupt | Sequential<E> | Parallel<E>`"*; `:23-27`: *"There are only three reason
variants… Multiple failures (from concurrent or sequential composition) are collected into a flat
array."*; `:106-108`: *"The distinction between sequential and parallel composition is no longer
represented in the data structure."*

**No rationale is stated anywhere.** I searched the migration guides, the 539 annotation files and
the 4 529-line changelog; the closest is *"v4 **intentionally** no longer records whether
composition was parallel or sequential"*
(`effect:migration/annotations/effect__Cause.yaml:160-162`). What *is* stated is that the flattening
let them delete the span-proxy machinery — v3 wrapped errors in `Proxy` objects to attach tracing,
v4 puts tracing on `Reason.annotations` (same file, `:158-159`, `:166-168`).

### 6.3 Rendering

`causePretty` (`:492-496`) builds one `Error` per non-interrupt reason (`causePrettyErrors`,
`:335-370`), setting `Error.stackTraceLimit = 1` for the duration. `cleanErrorStack` (`:430-445`)
**truncates the native stack at the first frame matching `/(?:Generator\.next|~effect\/Effect)/`** —
i.e. it cuts the runtime's own frames off — and then appends the *logical* stack from the
`StackTrace` annotation. `currentStackTrace` (`:466-489`) walks the `StackFrame` linked list, at most
**10** frames deep, rendering `at <name> (<location>)`.

If every reason is an `Interrupt`, it synthesises one error whose `cause` lists the interruptors
(`:455-464`): `at fiber (#17)` plus that interruptor's captured stack.

### 6.4 For beni

**This is the section of v4 that applies most directly, and P2 is silent on all of it.**

beni's position (P2 §5, `language.md` §6.6) is that errors are `Result` values and `?` unwraps them,
and that there are no exceptions. Three things happen at runtime that a `Result` cannot express:

1. **A `foreign` throws.** `boundary.md` §4 does not forbid it and JavaScript cannot be stopped from
   doing it. v4's answer is `Die(defect)`, produced by the one `try` around the run loop
   (`effect:…/effect.ts:700-704`). beni needs the same: a `Die` reason, one `try` in the trampoline,
   and a rule that a `Die` is not catchable by `?`.
2. **A fiber is interrupted while another awaits it.** `Fiber.join` propagates the child's `Exit`
   into the parent (`:860-867`), so the parent fails with `Interrupt`, not with a `Result` error.
   P2 §6.5 types `Fiber.join : Fiber a -> Result Cancelled a` — which *is* a decision, and it is a
   different one from Effect's: it makes cancellation an ordinary typed error at the join point and
   says nothing about what happens to `Task.par2`'s other branch or to `Task.bracket`'s release.
3. **A finaliser fails.** v4 combines its cause with the exit's (`combineFinalizerCause`,
   `:3935-3939`), so both are reported. Under `Result Cancelled a` there is nowhere to put the
   second one.

**Recommendation for the spike:** take v4's three-reason flat `Cause` as the runtime's internal
failure value, keep `Result` as the *language's* error type, and make the mapping explicit —
`Fail` ⟷ a `Result` failure, `Die` and `Interrupt` reaching the language only through
`Fiber.join`/`Task.scope`'s result type. The flat array is the right call for a second reason P2
would care about: it is one allocation and it dedupes, where a `Sequential`/`Parallel` tree has to be
linearised before it can be printed, and beni's whole diagnostic culture is about printing.

---

## 7. Fiber-local state and services at runtime

### 7.1 `Context`

`ContextImpl` (`effect:packages/effect/src/Context.ts:474-506`) is a base `ReadonlyMap<string, any>`
plus an **overlay linked list** — `{key, value, parent}` links, capped at `MaxDepth = 8` (`:489`).
`addUnsafe` (`:787-808`) pushes a link, or flattens into a new `Map` once depth reaches 8. `lookup`
(`:531-545`) walks the chain first, then the base map, so a read is at worst 8 pointer comparisons
plus one `Map.get`. Keys are **strings**, and `Context.Reference(key, { defaultValue })` makes a
lookup that cannot miss (`:245-267`).

### 7.2 The fiber cache

The expensive part is not the lookup; it is that the run loop reads eleven things per op. v4's
answer is a derived cache object shared by every fiber with the same `cacheRoot`. `setContext`
(`effect:…/effect.ts:742-757`) returns early on `Context.hasSameCache(previous, context)`, and
otherwise takes `root._fiberCache ??= makeFiberContextCache(context)`.

`makeFiberContextCache` (`:764-781`) materialises `scheduler`, `tracer`, `tracerContext`,
`tracerEnabled`, `span`, `logLevel`, `minimumLogLevel`, `stackFrame`, `runtimeMetrics`,
`maxOpsBeforeYield`, `preventYield`. Adding a service whose key is *not* marked `fiberCached` keeps
the `cacheRoot` and so keeps the cache (`Context.ts:793`); adding one that *is* invalidates it. The
comment at `:748-750` says forked fibers reuse the parent's cache object.

**This replaces v3's FiberRef patch/diff-on-fork entirely.** `FiberRef`, `FiberRefs` and
`FiberRefsPatch` are deleted (`effect:migration/fiberref.md:3-5`), and the annotations are explicit
that fork-time patching is gone: *"Context is inherited automatically when a v4 child fiber is
forked; custom per-reference fork patches were removed"*
(`effect:migration/annotations/effect__FiberRefs.yaml:16-18`). A fork is
`new FiberImpl(parent.context, …)` — one pointer copy.

Measured (§9.6): a reference read costs ~2.5× a bare `succeed`; going from 0 to 8 overlay links costs
~1.2×; a `provideService` around a single effect costs ~6× a bare `succeed`.

### 7.3 For beni

P2 is silent and P2 §9.3's position — *"restriction at a useful granularity is a capability record
passed as an argument, which needs no language support"* — is the right one and this evidence
supports it. beni should not build a `Context`.

But **the fiber needs one or two fiber-locals regardless**, and v4 shows which:

- the **scheduler** (so a test can install a deterministic one — P2 §11 Q11's determinism
  deliverable is exactly this, and v4 gets it by making `Scheduler` a `Context.Reference`);
- the **op budget** (report 16 §5.5 says it must be a platform constant, not a language one, so it
  must be reachable from the runtime and settable by the platform);
- the **current stack frame** for §8.1.

Three slots on the fiber record, inherited by pointer on fork, is all of it. That is the whole of what
v4's 500-line `Context` buys the run loop.

---

## 8. Observability

### 8.1 Stack traces for suspended fibers

The mechanism is a linked list of frames on the fiber-cached `CurrentStackFrame` reference
(`effect:packages/effect/src/internal/references.ts:16-19`). `Effect.fn` pushes two per call — the
call site and the definition site (`effect:…/effect.ts:1341-1355`):

```ts
updateService(…, CurrentStackFrame, (prev) => ({
  name, stack: callError ? fnStackCleaner(() => callError.stack) : constUndefined,
  parent: { name: `${name} (definition)`, stack: defError ? … : constUndefined, parent: prev }
}))
```

The costs are made cheap three ways:

1. `Error.stackTraceLimit` is clamped to 2 around the capture and restored (`:1334-1339`), so V8
   walks two frames, not ten;
2. the string is produced **lazily and memoised** — `makeStackCleaner(2)` returns a thunk that
   splits and caches on first call (`effect:packages/effect/src/internal/tracer.ts:32-44`);
3. if `Error.stackTraceLimit === 0`, capture is skipped entirely — the documented opt-out
   (`packages/effect/CHANGELOG.md:889`; guarded at `:1336`, `:1290`).

`stackTraceLimit.ts` exists because writing that property throws in hardened environments; every
write is best-effort (`effect:packages/effect/src/internal/stackTraceLimit.ts:25-58`).

**And it is expensive anyway.** Measured (§9.6): building the effect costs **68 ns** with
`fnUntraced` and **7 244 ns** with `Effect.fn`; with `Error.stackTraceLimit = 0` it falls to 325 ns.
Running it costs 1 377 ns against 21 621 ns. `LLMS.md:56-58` therefore tells users to pick:

> Use `Effect.fn("name")` when the function should create a tracing span. Prefer `Effect.fnUntraced`
> when tracing is not needed, particularly for library implementations and hot paths.

### 8.2 What "Effect-level quality" means for debugging a suspended beni program

P2 §7.4 promises that *"each continuation carries the source span of the call it resumes, and the
runtime keeps the chain of pending continuations."* This evidence says three things about that
promise.

1. **The shape is right, and it is the only shape.** v4 independently arrived at a linked list of
   `{name, stack, parent}` frames, walked at unwind time, rendered with the runtime's own frames
   stripped. Nothing else in the surveyed code tries to reconstruct a logical stack.
2. **beni gets it 100× cheaper, and that is the real prize.** Effect pays 7.2 µs per call because it
   must *discover* the call site at run time, from a `new Error()`. beni's compiler already knows the
   span — P2 §7.4's continuation "carries" it as a constant. A frame becomes
   `{name, span, parent}` with **no `Error`, no `stackTraceLimit` fiddling, and no lazy
   stringification**, and there is no reason for beni to have an `fn` / `fnUntraced` split at all.
   This is the single clearest place where compiling beats interpreting, and it should be said in
   §7.4.
3. **The truncation rule is a deliverable.** `cleanErrorStack`'s regex cutting Effect's own frames
   out of a native stack (`:439-443`) is the ugly version of what beni gets from source maps: the
   scheduler's frames must not appear. P2 §7.4 says continuations must be *named*, which is half of
   it; the other half is that the trampoline's own frame must be suppressible.

### 8.3 Tracing, logging, metrics

Tracing is off the hot path unless installed: `cache.tracerContext` is `undefined` when no tracer is
present, and the run loop's dispatch tests it every op (`:683-685`). The comment at `:765-767` says
the string-keyed lookups exist *"to keep the Tracer key values… out of every bundle"*.
`addSpanStackTrace` (`effect:packages/effect/src/internal/tracer.ts:10-29`) captures at
`stackTraceLimit = 3` with the same zero-limit opt-out.

Logging and metrics are fiber-cached references (`logLevel`, `minimumLogLevel`, `runtimeMetrics`),
read once per `setContext` rather than per op.

### 8.4 Runtime flags and supervisors: deleted

v4 removed the entire supervision surface:

- **`RuntimeFlags`** — the bitset is gone; each flag became a separate mechanism, and `OpSupervision`
  was removed **with no replacement** (`effect:migration/annotations/effect__RuntimeFlags.yaml:76-99`).
- **`FiberStatus`** — gone. *"Use `fiber.pollUnsafe()`; `undefined` means incomplete and `Exit` means
  completed, **with no running/suspended distinction**"*
  (`effect:migration/annotations/effect__FiberStatus.yaml:4-6`).
- **The global fiber registry and fiber dumps** — gone
  (`effect:migration/annotations/effect__Fiber.yaml:103-105`, `:13-15`).
- **`Runtime<R>`** — gone; *"Run functions live directly on `Effect`, and the `Runtime` module is
  reduced to process lifecycle utilities"* (`effect:migration/runtime.md:15-17`).

**For P2 §11 Q11.** The question asks whether determinism and fiber observability are v1
deliverables. The gold standard's answer, at v4, is: **determinism yes** (the scheduler is a
replaceable service and `runSync` installs a different one — `effect:…/effect.ts:5730`), **fiber
observability no** (it shipped by deleting it). A supervision tree is the thing beni can afford to
defer; a swappable scheduler is not, because retrofitting it means threading a parameter through
every primitive.

---

## 9. Performance

### 9.0 What Effect measures, and what that says

`packages/effect/runtimeperf/` is a serious harness — a fresh child process per measurement,
batch-size calibration, median-of-5 processes with MAD, paired base/head against two detached git
worktrees with order alternated per round, a seeded bootstrap CI over paired log-ratios, and an
asymmetric improvement/regression classification at −2 % / +5 %
(`effect:packages/effect/runtimeperf/README.md:141-155`, `config.json:2-12`, `stats.mts:50-122`,
`compare.mts:80-180`). beni's `zig build bench` does better on one axis (ABBA interleaving) and
worse on two (no process isolation, no bootstrap CI).

**And all 322 of its cases are `Schema` and `Arbitrary`.** Not one fixture builds an `Effect` and
runs it. The only tinybench file across the three `benchmark/` directories whose subject is the
runtime is `effect:packages/effect/benchmark/Pool.ts`. There is no checked-in ns/op number for
`flatMap`, a fork, interruption or the run loop; the tables in `packages/effect/CHANGELOG.md:1910`
and `:1976` are Schema, HEAD-vs-`main`, within v4.

There is one genuine allocation gate and it is worth copying:
`effect:packages/effect/benchmark/http/serverAllocations.ts:4-12` fixes hard per-request budgets —
**≤ 17 000 B allocated, ≤ 64 B retained, ≤ 512 B deferred** — sampled with the inspector heap
profiler over 50 000 requests, `process.exit(1)` on breach (`:126-136`). That is the right
instrument for P2 §11 Q3(b)'s lazy-fiber question. Two other transferable habits: paired base/head
with an explicit "inconclusive" verdict, which is what would have made report 19's 20.3 % dispatch
regression arguable rather than assertable; and publishing the losses — `CHANGELOG.md:1910` shows
Effect 8.5× slower than Zod on typed codec encode, in Effect's own changelog.

### 9.1 The interpreter, normalised

`e9-headline.mjs`, min of 9, one process, busy machine (load 16.4 at the end of the run). The
normaliser is a direct JS call in the same process.

| | ns/op | × direct call |
|---|---:|---:|
| direct JS call (normaliser) | **0.75** | 1 |
| `await` on an `async` function returning a value | 54.1 | 73 |
| `await` on a non-promise | 55.0 | 74 |
| Effect: `flatMap` step, `runSync` | 82.0 | 110 |
| Effect: `sync` + `flatMap` step, `runSync` | 85.3 | 114 |
| Effect: `gen`, `yield* Effect.succeed` | **66.7** | 89 |
| Effect: `gen`, `yield* Effect.sync` | 120.6 | 162 |
| Effect: `gen`, `yield*` a `callback` resuming inline | 185.7 | 249 |
| Effect: `forkChild(startImmediately)` + `join` pair | 472.4 | 634 |

Three readings.

- **A generator step is cheaper than a `flatMap` step** (67 vs 82 ns), for the reason in §2.5.
- **An Effect op and an `await` are the same order of magnitude** — 82 ns against 55 ns. Owning the
  scheduler does not cost throughput; it buys §4.4's 57 ms.
- **`await` on a non-promise measured 55 ns here, where `research/16` §3.1 reports 122–135 ns** on
  the same Node version. I do not know report 16's exact harness shape and cannot say which is right;
  my loop is `x = await (x + 1)` inside one hot `async` function, which V8 may optimise more than a
  realistic shape does. **P2 §7.2's table quotes the 122–135 ns figure and its ~70× multiplier, and
  that row should be re-measured before it is quoted again.** P2 §7.2's *argument* is unaffected —
  ECMA-262 §27.10.5.3 still has no branch for "the value was already there" — but the size of the
  win is in question.

### 9.2 The fast path and forking

`e2-fastpath.mjs`, min of 7, machine busier than §9.1 (absolute values inflated; read the ratios).

| | ns/op |
|---|---:|
| `Effect.runSync(Effect.succeed(1))` — the `effectIsExit` short-circuit, no fiber | **3.9** |
| `Effect.runSync(Effect.sync(…))` — builds a fiber and a scheduler | 459 |
| `Effect.runSync(sync >>= sync)` | 525 |
| `Effect.callback` resuming synchronously, per `runSync` | 438 |
| `forkChild({startImmediately: true})` + `join`, per pair | 572 |
| `forkChild()` (scheduled) + `join`, per pair | **2 816** |
| fork N, then `awaitAll`, per fiber | 750 |

**A scheduled fork costs 4.9× an immediate one** in this run (6.7× in §9.1's quieter one), because it
is a macrotask. That is §0.3 item 5.

### 9.3 Fairness: report 16 §2.3 re-run, and the budget sweep

`e4-fair.mjs`, the same script shape as report 16 §2.3 — an `Effect.sync` chain with a
`setTimeout(…, 0)` armed at the start.

| ops in the chain | v3 (report 16 §2.3) | **v4, measured here** |
|---|---|---|
| 2 000 000, default | work 361 ms, armed timer fired after **361 ms** | work 802 ms, armed timer fired after **8.9 ms** |
| 5 000 000, default | 872 ms / 723 ms | 2 248 ms / **7.9 ms** |
| 8 000 000, default | 1 528 ms / 814 ms | 3 342 ms / **3.7 ms** |
| 100 000, budget 16 | 131 ms / 20 ms | 113 ms / **0.9 ms** |

**Report 16 §2.3's headline finding is now historical.** v4 at its *default* 2048 gives the page back
in 8.9 ms where v3 froze it for 361 ms, because the yield is always a macrotask (§3.3).

`e5-budget.mjs`, 1 M ops, min of 5, same process, sweeping the budget:

| `MaxOpsBeforeYield` | ns/op | armed-timer latency (median) |
|---:|---:|---:|
| 16 | 1 580 | 1.1 ms |
| 64 | 1 073 | 1.0 ms |
| 512 | **753** | 1.7 ms |
| 2048 | 820 | 6.1 ms |
| 8192 | 822 | 20.8 ms |
| `PreventSchedulerYield` (never) | 558 | **566 ms** |

(Absolutes inflated by load; the column is internally comparable.)

**This answers P2 §11 Q3(a), for Node.** Yielding at all costs 1.35–1.5× against never yielding.
**512 is the knee**: it is the fastest budget measured *and* gives 1.7 ms latency. 64 costs 1.4×
against 512 and buys 0.7 ms. P2 §7.5's *"the constant should be closer to Cats Effect's 64 or
Kotlin's 16 than to Effect's 2048"* was reasoning from v3's 361 ms freeze, which was caused by the
*microtask* path and not by the budget. **The recommendation should be re-derived, and on this
evidence a Node platform wants 512, not 64.**

The browser number is still unmeasured and is now more interesting, not less: with no `setImmediate`,
v4's escape is `setTimeout(f, 0)`, clamped to 4 ms after five nested levels. At a budget of 512 that
would cap a browser fiber at ~128 000 ops/s. §0.5 item 1.

### 9.4 Allocation

`e6b-mem.mjs`, 200 000 samples, one measurement per process, `--expose-gc`, four forced GCs each
side. The array-slot baseline (8 B) is subtracted.

| | bytes each |
|---|---:|
| `Effect.succeed(i)` — an `Exit` node | 32 |
| `Effect.flatMap(base, f)` node | 96 |
| `Effect.map(base, f)` node | 104 |
| `Effect.sync(() => i)` node | 128 |
| a bare parked `async` frame (never-settling `await` in a `try`/`finally`) | 50 |
| a `Promise` that never settles | 50 |
| **a parked Effect fiber, `callback` with no canceller** | **419** |
| **a parked Effect fiber, `callback` with a canceller** | **659** |
| a parked fiber inside a `scoped` with one `acquireRelease` | 2 310 |

**This kills one of report 16 §3.8's conclusions.** It measured beni's proposed 692 B record as
*"1.4× a bare parked `async` frame and 0.2× an Effect fiber"*, on v3's 3 450 B fiber. **A v4 fiber is
659 B.** The ratio is 1.05, not 0.2 — fiber size is no longer a beni advantage, and P2 §11 Q3(b)'s
"can the record be lazy?" becomes the only place left to win.

(Report 16's (a) row measured 481 B for a parked async frame where I measure 50 B. The shapes differ
— mine holds the promise in an array, report 16's holds the frame — and I cannot reconcile them from
here. I report mine and flag the discrepancy; it is the second measurement in this report that does
not reproduce, after §9.1's `await` row.)

### 9.5 The unwind (P2 §11 Q3c)

`e8b-unwind.mjs`, 20 000 finalisers on one scope, min of 5, with a `Latch` to guarantee all of them
exist before the interrupt:

| | ns each |
|---|---:|
| installing an `acquireRelease` finaliser (build) | **2 076** |
| running them, unwound by an interrupt | **199** |
| `onExit` chain depth 2 000, unwound by interrupt (build + unwind) | 1 034 |
| interrupting N `forkChild` children on parent exit | 945 |
| `Semaphore`: N cancelled waiters registered, interrupted, removed | 2 214 |

Order verified at depth 5: `4,3,2,1,0` — **LIFO**.

**Install cost dominates unwind cost by 10×.** `acquireRelease` is `contextWith` +
`uninterruptibleMask` + `flatMap(scope)` + `tap` + a `Map.set` with a fresh key object
(`:4106-4122`), and that is where the 2 µs goes. For beni: P2 §6.3's *"a push onto `finalizers` and
a flag"* is the cheap design and v4 is the expensive one; the reason v4 pays is the `Scope` *value*
(§5.1). If beni's `Task.bracket` is a stack frame and only `Task.scope` allocates a keyed map, beni
should beat this by an order of magnitude — and that is a measurable spike deliverable, not a hope.

### 9.6 Observability cost

`e7-observability.mjs`, min of 7:

| | ns/op |
|---|---:|
| build `Effect.fnUntraced(x)` | **68** |
| build `Effect.fn("name")(x)` | **7 244** |
| build `Effect.fn`, with `Error.stackTraceLimit = 0` | 325 |
| run `fnUntraced` in one fiber | 1 377 |
| run `Effect.fn` (span + two stack frames) | **21 621** |
| a `Context.Reference` read in a `gen` loop | 864 |
| baseline: `Effect.succeed` in the same loop | 344 |
| `Effect.provideService(Ref, v)` around one `succeed` | 2 004 |
| a reference read under 8 nested `provideService` overlays | 1 024 |

Ratios: `Effect.fn` costs **106×** `fnUntraced` to build and **16×** to run. A reference read costs
**2.5×** a bare `succeed`. Eight overlay links cost **1.19×** one. `provideService` costs **5.8×** a
bare `succeed`.

### 9.7 Bundle size

`esbuild --bundle --minify --format=esm --platform=neutral`, gzip `-9`:

| program | minified | gzip |
|---|---:|---:|
| `Effect.succeed(123).pipe(Effect.runFork)` | 25 118 B | **9 094 B** |
| the same + `forkChild`, `Fiber.join`, `scoped`, `acquireRelease`, `race`, `timeout` | 39 706 B | **14 155 B** |
| `import { Effect } from "effect"` (barrel) instead of `effect/Effect` | 164 021 B | 56 717 B |

`MIGRATION.md:54-57` claims *"a minimal Effect program bundles to ~6.3 KB (minified + gzipped)"*
using rollup + terser + `stripInternal` (`effect:packages/tools/bundle/src/Plugins.ts:140-152`,
`effect:.github/workflows/check.yml:76-110`). My 9.1 kB is a different toolchain and is not a
refutation; the claim is the right order.

**Three things beni should take from the third row.** Importing the barrel costs **6.2×** the
per-module import. `effect`'s `sideEffects` field lists exactly two files
(`packages/effect/package.json`), and the changelog records *"Fix module-level side effects that
defeated bundler tree-shaking"* (`effect:packages/effect/CHANGELOG.md:3003`). And the whole
concurrency surface — fork, join, scope, bracket, race, timeout — is **5 kB gzip**. That is the
budget for `platforms/node/runtime.js`, and `backend.md` §9's DCE is what keeps a program that never
spawns from paying it.

---

## 10. What is TypeScript/JavaScript-induced, and beni does not need

| thing | v4 | why beni does not need it |
|---|---|---|
| **the `Primitive`/`evaluate` protocol** | `effect:…/core.ts:365-530`, 154 lines | beni's compiler emits the continuation. An effect is not a value. |
| **`ContImpl` / `OnSuccessImpl` / the shared-continuation trick** | `:1481-1531` | a beni continuation is a closure; there is nothing to share a payload slot with. |
| **generators, `SingleShotGen`, the `Iterator` primitive, `yield*` adapters** | `:1230-1451`, `effect:…/core.ts:103-105` | direct-style source, CPS output. P2 §7.1. |
| **`Effect.fn` / `fnUntraced` / `fnUntracedEager` and their pipeable variadics** | `:1256-1417` | three functions whose only job is to make a generator look like a function and attach a call site the compiler already knows (§8.2). |
| **the eager family** (`flatMapEager`, `mapEager`, `catchEager`, `matchEager`, …) | `:1846-1942` | a run-time test for "is this value already computed". beni knows at compile time; this is the `suspends` bit. |
| **`dual`** (every combinator has a data-first and a data-last overload) | used ~200× in `effect.ts` | beni has `\|>` pipe-first and no overloading. |
| **`Pipeable` / `pipeArguments`** | `effect:packages/effect/src/Pipeable.ts:564-594`, unrolled to arity 9 | same. |
| **`Inspectable` / `toJSON` / `NodeInspectSymbol` on every primitive** | `effect:…/core.ts:66-79`, mixed into `EffectProto` `:100-113` | beni has `Debug.log` and derivation. |
| **variance phantom fields** (`effectVariance = {_A, _E, _R}` on every effect; `fiberVariance`) | `effect:…/core.ts:24-28`, `effect:…/effect.ts:517-520` | a TypeScript encoding with a runtime footprint. beni's types are erased. |
| **`Unify`** | `effect:packages/effect/src/Unify.ts`, 312 lines | works around TS union inference. Not a runtime concept. |
| **`HKT`** | `effect:packages/effect/src/HKT.ts`, 219 lines | same. |
| **`Effectable.Prototype` / `Class`** | `effect:packages/effect/src/Effectable.ts:32-44` | a public escape hatch for user types to become effects. beni's answer is static dispatch. |
| **runtime type guards** (`isEffect`, `isExit`, `isCause`, `hasProperty`, `effectIsExit`) | `effect:…/core.ts:116`, `:119`, `:132`; `effect:…/effect.ts:1842` | beni's checker has already decided. |
| **`Yieldable`** (a type that can be `yield*`ed but is not an `Effect`) | `effect:migration/yieldable.md:14-16` | exists to undo v3's "everything is an Effect" subtyping. |
| **structural `Equal`/`Hash` on `Cause` and every reason** | `effect:…/core.ts:82-97`, `:166-175`, `:263-274` | needed because `causeCombine` dedupes by value. beni derives `eq` and would too — **keep this one**: §6.1's dedupe is the reason. |
| **string-keyed `Context`** | `effect:packages/effect/src/Context.ts` | §7.3: beni needs 3 slots on the fiber, not a service locator. |

**Total not-needed, by line count:** roughly 154 (protocol) + 52 (continuation objects) + 222
(generators and `fn`) + 100 (eager) + 675 (`Pipeable`) + 312 (`Unify`) + 219 (`HKT`) + 331
(`Inspectable`) ≈ **2 065 lines**, before counting `dual`'s pervasive overhead. Effect's core
`internal/effect.ts` is 6 912 lines; the part of it that is *a fiber runtime* is the ~2 161 in §0.4.

---

## 11. Synthesis for beni's spike

### 11.1 The one-sentence version

**Take v4's interruption architecture, v4's `Cause`, and v4's scheduler shape; re-derive P2 §7.5's
budget from measurement rather than from Cats Effect; add the three fields P2's fiber record is
missing; and delete the interpreter, because beni's compiler is it.**

### 11.2 Corrections P2 and report 16 need

1. **P2 §6.2 and §6.4's `interruptor` field is v3's design.** v4 has no `_asyncInterruptor`. The
   canceller is a continuation frame pushed by the suspension primitive (`:1180-1187`) and the
   one-shot disarm is a separate `_yielded` thunk called at the top of `evaluate` (`:620-627`).
   Rewrite §6.4's table row.
2. **P2 §7.5's characterisation of Effect is out of date.** *"Effect's `MixedScheduler` escapes to
   `setTimeout(…, 0)` every 2048 nested microtask drains"* describes 3.22.2. v4 escapes on **every**
   drain. The paragraph's conclusion is unchanged; its evidence is now stronger and its number is now
   wrong (§9.3).
3. **P2 §7.5's budget of 64 is not supported.** On Node, 512 is the knee. Re-derive.
4. **Report 16 §5.2's `finalizers` list is one mechanism where two are needed** (§5.1).
5. **Report 16 §5.2's split `conts: ByteStack` + `objectState: ArrayStack` recommendation does not
   apply.** v4 uses one array; beni's continuations are closures (§2.2).
6. **Report 16 §3.8's "0.2× an Effect fiber" is v3.** On v4 it is 1.05× (§9.4).
7. **P2 §7.2's 122–135 ns `await` figure should be re-measured** (§9.1).
8. **P2 §6.5 types `Fiber.join : Fiber a -> Result Cancelled a`.** That is a decision about the
   failure model and it needs §6.4's three cases answered before it is frozen.

### 11.3 The minimal kernel, as a build order

§0.4 sizes it; this is the order to build it in. Ten pieces, ~600 effective lines, each one E4 slice
with one fixture.

1. **The fiber record** — thirteen fields (§3.1's table minus `context`/`cache`/`_dispatcher`, plus
   `scheduler`). Report 16 §5.2 has seven of them.
2. **The run loop and the trampoline** — the `while (true)`, the op counter, the yield insertion,
   the one `try` producing a `Die`. Fixture: `run/SuspendInLoop`, already plan §4's E3.
3. **The suspension primitive** — register / resume-inline / park, the `yielded`/`resumed`
   handshake, the canceller pushed as a frame. P2 §6.1's `Step` protocol lives here.
   Fixture: `run/SuspendFastPath`.
4. **Interruption** — the disarm, `deferredInterrupt`, the unwind through the canceller frame.
   Fixture: the re-entrant-interrupt fixture of §0.5 item 3.
5. **Interruptible regions** — flag, sentinel frame, latched cause, re-arm, `restore`. Fixture:
   `run/BracketCancel`, plus one asserting `use` is interruptible between two uninterruptible ends.
6. **The scheduler** — priority buckets, one macrotask per drain, `flush`, a `sync` mode. It must be
   a **replaceable service on the fiber from the first commit** (§8.4).
7. **`Cause` and `Exit`** — three flat reasons, `combine` with dedupe, `squash` (§6.4).
8. **Fork and join** — `forkUnsafe(parent, thunk, immediate, daemon, interruptible)` and three
   public forms; `addObserver` returning its remover; child interruption as reachable-only
   middleware. Fixtures: `run/SpawnJoin`, `run/ScopeChildren`.
9. **`Scope` and finalisers** — the keyed map with a one-finaliser fast form, LIFO close, removal,
   `combineFinalizerCause`, **and** `onExit` as a stack frame: both mechanisms (§5.1). Fixture:
   `run/BracketCancel` asserting LIFO order and the release printing before exit.
10. **`Cause.pretty` and the stack-frame chain** — `{name, span, parent}`, walked at unwind, runtime
    frames suppressed, and no `Error` anywhere in it (§8.2).

Everything in P2 §6.5's list beyond `spawn`/`join`/`scope`/`bracket` — `par2`, `parAll`, `race`,
`timeout`, `retry`, `Semaphore`, `Queue`, `RateLimiter` — is library code over those ten, exactly as
it is in v4. **Plan §5 decision 3's recommendation of (c) for the spike is right**, and this is the
reason: the ten above are the only pieces whose cost is unknown.

### 11.4 What to hold the spike to

- **Retained bytes per parked fiber**, as a gate that fails the build, on the model of
  `effect:packages/effect/benchmark/http/serverAllocations.ts:4-12`. Target: beat v4's 659 B, or
  explain why not. Report 16's 692 B projection is now *parity*, not an advantage.
- **`emit/` bytes for a program with no suspending call: zero change.** Plan §3's bound.
- **Op-budget sweep** at 16 / 64 / 512 / 2048 / never, reporting throughput *and* armed-timer
  latency, in Node and in a browser. The browser half is `research/16` §6's missing experiment and it
  is now the most valuable unrun thing in the whole effects file.
- **Cancellation latency**: report 16 §2.4's script, in beni. The target is Effect's 57 ms; anything
  above ~60 ms means the resume callback is not actually owned.
- **Finaliser install and unwind cost at depth 20 000.** v4: 2 076 ns install, 199 ns unwind. beni's
  `bracket` should be cheaper to install because it is a frame, not a keyed map entry — prove it.

### 11.5 The three fields P2's record must gain

Stated separately because they are easy to miss and each is a silent-wrongness class.

- **`running: boolean` and `deferredInterrupt: boolean`** — without them, an interrupt delivered to a
  fiber executing on its own stack starts a second walk of the same continuation stack. Symptom: a
  finaliser runs twice, or a value is delivered after cancellation. Plan §6's table has no row for
  this.
- **`yielded: fn | undefined`** — the one-shot disarm. Without it, report 16 §5.3 row 3's obligation
  3 ("the abandoned primitive's later resume is dropped") is unimplemented, and the symptom is a
  cancelled fiber resuming later and running the rest of its continuation on a dead scope.
- **`interruptedCause`** — the latch for an interrupt arriving during an uninterruptible region.
  Without it, `bracket`'s release swallows the cancellation and the fiber continues.

### 11.6 The decision P2 has not taken

**What is the runtime's failure value?** Options, with v4 as the reference:

- **(a) v4's shape.** A flat `Cause` of `Fail | Die | Interrupt`; the language's `Result` failure is
  a `Fail`; `Die` and `Interrupt` reach beni only through `Fiber.join`, `Task.scope` and
  `Task.bracket`'s release. Costs ~90 lines and one new opaque type in `core/`.
- **(b) P2 §6.5 as written.** `Fiber.join : Fiber a -> Result Cancelled a`. Simple, and it has no
  answer for a throwing `foreign`, for a failing finaliser, or for two concurrent failures.
- **(c) Defects are fatal.** A throwing `foreign` kills the program. Defensible for v1, and it makes
  `run/ForeignThrows` a diagnostic fixture rather than a runtime one.

This is a language decision, not a runtime one, and it belongs in plan §5 as a ninth item. **The
recommendation is (a)** — because (b) cannot express a finaliser failure that happens *while*
unwinding another failure, which is the first thing `run/BracketCancel` will hit.

---

## 12. Could not determine

- **Why the `Cause` tree was flattened.** No rationale is stated anywhere in the repository. The
  migration guide says what changed; the annotation says "intentionally"
  (`effect:migration/annotations/effect__Cause.yaml:160-162`). Whether it was for bundle size,
  allocation, rendering or ergonomics is not recorded, so §6.4's recommendation rests on my own
  reasoning about beni, not on Effect's.
- **Whether v4's scheduler change was deliberate or a side effect of the dispatcher split.** The only
  related changelog line is *"seperate scheduler dispatch from yield decisions"*
  (`effect:packages/effect/CHANGELOG.md:3854`). Nothing in the repository mentions v3's nested-drain
  counter at all.
- **Any v3-vs-v4 runtime number published by Effect.** There is none: no ns/op, no ×-faster, no
  bundle baseline. The `~6.3 KB` in `MIGRATION.md:56` is an absolute with no v3 comparison. Every
  v3→v4 comparison in this report is my own measurement against report 16's published v3 figures,
  which were taken on the same machine with a different harness.
- **The browser.** Nothing here was measured in one. §0.5 item 1.
- **Why my `await`-on-a-non-promise figure (55 ns) and parked-async-frame figure (50 B) differ from
  `research/16` §3.1's (122–135 ns) and §3.8's (481 B)** by 2.4× and 9.6× respectively. Both were
  Node v24.19.0 on this machine. I did not have report 16's scripts to run side by side. Two of the
  four figures P2 §7.2 and §6.4 quote therefore need re-taking before they are quoted again.
- **What the fiber-cache sharing actually saves.** `makeFiberContextCache` is computed once per
  `cacheRoot` and shared, which should make a fork nearly free — but I measured the fork, not the
  cache, and the two are confounded.
- **Whether beni's continuation-as-closure stack is cheaper than v4's array-of-primitives.** It
  should be — no prototype dispatch, no `[args]` indirection — but nothing here measures it, and it
  is the single assumption the whole "compiling beats interpreting" claim rests on. It is the first
  thing E3 should measure.
- **The cost of `Effect.fn`'s span versus its stack frames.** §9.6 measures them together (21.6 µs)
  and I did not separate them. For beni the split matters: spans are optional and stack frames are
  not.

---

## 13. Evidence index

**Source, `references/effect` at `3d59ae6`, `packages/effect@4.0.0-rc.116`.** The heart is
`packages/effect/src/internal/effect.ts` (6 912 lines): the fiber at `:528-762`, interruption at
`:595-616` and `:4480-4577`, the suspension primitive at `:1148-1224`, `Scope` at `:3900-4135`,
forks at `:5418-5596`, bounded concurrency at `:4981-5128`, `Cause` at `:100-508`. The primitive
protocol and `Exit` are `packages/effect/src/internal/core.ts:365-556`; `Cause`'s data type is
`:138-176`. The scheduler is `packages/effect/src/Scheduler.ts`, whole. `Context` is
`packages/effect/src/Context.ts:474-545`, `:787-808`. Stack traces are
`packages/effect/src/internal/tracer.ts` and `internal/stackTraceLimit.ts`.

**Documents.** `MIGRATION.md:52-57` is the only prose statement of the rewrite and the only bundle
figure. `migration/cause.md`, `migration/forking.md`, `migration/fiberref.md`, `migration/runtime.md`
and `migration/yieldable.md` are the five that matter for the runtime. `migration/annotations/`
(539 YAML files) is richer than the prose and is where the deletions are recorded.
`migration/fiber-keep-alive.md` is stale and contradicted by
`packages/effect/CHANGELOG.md:4073` and `packages/effect/src/Runtime.ts:217-221` — do not cite it.

**Effect's own harnesses.** `packages/effect/runtimeperf/` (322 cases, all Schema/Arbitrary),
`packages/effect/typeperf/` (37 fixtures with checked-in type-instantiation budgets),
`packages/effect/benchmark/` (`Pool.ts` is the only runtime subject;
`http/serverAllocations.ts:4-12` is the allocation gate worth copying),
`packages/tools/bundle/` (33 fixtures, rollup+terser, base-ref comparison in CI at
`.github/workflows/check.yml:76-110`). No benchmark result is checked in.

**Measurements**, all Node v24.19.0, Ryzen 9 5950X, **busy machine** (load 16–45), min of N, scripts
in the session scratchpad: `e1-loop.mjs`, `e2-fastpath.mjs`, `e3-cancel.mjs`, `e4-fair.mjs`,
`e5-budget.mjs`, `e6b-mem.mjs`, `e7-observability.mjs`, `e8b-unwind.mjs`, `e9-headline.mjs`.

**beni documents.** [`transparent-effects-proposal.md`](../transparent-effects-proposal.md) §6, §7,
§9, §11 is what this report is measured against;
[`plans/effects-plan.md`](../../../plans/effects-plan.md) §4 slices E3/E4, §5 decisions 3 and 6, §6's
exit-0 table and §7's could-not-determine list are what it feeds.
[`research/16-fibers-and-concurrency.md`](16-fibers-and-concurrency.md) §2.3, §2.4, §2.5, §3.1, §3.8,
§5.2, §5.3 and §6 are the claims re-tested here — §2.4 and §2.5 **reproduce**, §2.3 is **superseded**,
§3.1 and §3.8 **do not reproduce**, §5.2's field list and stack-layout recommendation need amending.
[`research/17-platform-primitives.md`](17-platform-primitives.md) §1 kind (i) is the shape §0.3 item
4 is about.
