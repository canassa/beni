# Fibers, concurrency and cancellation: what a `Task` runtime must do

**Commissioned by** a one-line brief — *"Effect-TS-like control over fibers, concurrency, etc."* —
and by the fact that [`boundary.md`](../boundary.md) settled the architecture and said nothing about
the runtime. `fast-compiler.md` §3.1 settled that the language is pure and effects are values
interpreted by a platform; `boundary.md` §3 settled that a platform-provided effect is an ordinary
`foreign` at effect type and that ports stay asynchronous. What none of them settled is **what the
thing interpreting those values is allowed to do.** A `Task e a` that can only be run one after
another is a different language from one that can fan out, bound its own concurrency, cancel what it
no longer needs and release what it acquired.

**The brief's own hypothesis is that we have the right architecture and a poor runtime.** §1 and §2
test it against both sources. It survives, with one correction: the gap is not only richness, it is
that Elm's scheduler contains a *documented* capability its code does not implement (§1.3).

**The test stays the one this series uses.** A capability is admitted when it can be typed such that
well-typed code still cannot crash — and for a runtime that test has a second half, because a
scheduler can satisfy the type and still leak a process, drop a finaliser or wedge the event loop.
So every primitive in §5 is judged twice: *can it be typed*, and *what does the runtime have to
promise*.

**Sources.** The vendored `references/elm-core` read directly — `Elm/Kernel/Scheduler.js` (195
lines), `Elm/Kernel/Process.js`, `Process.elm`, `Task.elm`, `Elm/Kernel/Platform.js. Effect-TS
**3.22.2** read from an installed copy of the published package rather than from GitHub, so every
line quoted is the code that actually ships; file paths below are inside `node_modules/effect/dist/esm/`.
Primary documentation and source for ZIO 2, Cats Effect 3, Trio, kotlinx.coroutines, Swift's
stdlib and `golang.org/x/sync/errgroup`; MDN and the TC39 proposal repositories for the JavaScript
baseline. **Original measurements were run for this report** — §3 — on Node v24.19.0 / Intel N100 /
Linux, and every figure labelled *measured here* is reproducible from a script quoted inline. Where
a number is published by someone else it is attributed; where none exists the report says
**no verified number found** rather than estimating.

---

## 1. Elm's scheduler, read line by line

### 1.1 It is 195 lines and the architecture is right

`references/elm-core/src/Elm/Kernel/Scheduler.js` is the whole concurrency runtime. A `Task` is a
tagged record with one of five tags — `SUCCEED`, `FAIL`, `BINDING`, `AND_THEN`, `ON_ERROR` — plus
`RECEIVE` for effect-manager mailboxes. A *process* is `{ id, root, stack, mailbox }`, and
`_Scheduler_step` (lines 151–194) is a `while (proc.__root)` loop that rewrites `root` and `stack`
until it hits something it cannot advance:

```js
else if (rootTag === __1_BINDING)
{
    proc.__root.__kill = proc.__root.__callback(function(newRoot) {
        proc.__root = newRoot;
        _Scheduler_enqueue(proc);
    });
    return;
}
```

That is the whole asynchrony mechanism, and it is a good one. A `binding` hands the outside world a
one-shot resume callback and **the outside world hands back a canceller**, stored in `__kill`. It is
the same shape as Effect's `Async` op (§2.1), it is the same shape as Swift's
`withTaskCancellationHandler`, and it predates both. `_Scheduler_kill` (lines 102–115) invokes it:

```js
var task = proc.__root;
if (task.$ === __1_BINDING && task.__kill) { task.__kill(); }
proc.__root = null;
```

**The kill slot is used in practice, not vestigial.** `elm/http`'s `_Http_toTask` returns
`function() { xhr.__isAborted = true; xhr.abort(); }` from its binding
([elm/http `src/Elm/Kernel/Http.js`](https://raw.githubusercontent.com/elm/http/master/src/Elm/Kernel/Http.js),
fetched 2026-09-14), and `_Process_sleep` returns `function() { clearTimeout(id); }`. Two of the six
`_Scheduler_binding` call sites in `elm/core` are synchronous and correctly return nothing.

**So the brief is right about the architecture.** The five tags, the heap-allocated continuation
stack, the work queue and the canceller slot are the same four ideas Effect-TS's fiber runtime is
built from. What follows is the list of things this code does not do.

### 1.2 Nothing in `elm/core` runs two tasks concurrently

`Task.elm:139-143`, verbatim:

```elm
map2 : (a -> b -> result) -> Task x a -> Task x b -> Task x result
map2 func taskA taskB =
  taskA
    |> andThen (\a -> taskB
    |> andThen (\b -> succeed (func a b)))
```

`map3`–`map5` nest the same way and `sequence` is `List.foldr (map2 (::)) (succeed [])`
(`Task.elm:185`), so **every combinator in the module is sequential, transitively, from one
definition**. The module documents this itself rather than hiding it (`Task.elm:133-135`): *"Say we
were doing HTTP requests instead. `map2` does each task in order, so it would try the first request
and only continue after it succeeds."*

**Elm does have concurrency — one level up, where the `Task` language cannot reach it.** The `Task`
effect manager's `onEffects` is `sequence (List.map (spawnCmd router) commands)` and `spawnCmd` is
`Elm.Kernel.Scheduler.spawn` (`Task.elm:338,350`), so **separate `Cmd`s issued from one `update`
each get their own process and do run concurrently.** The consequence is exact and is the real
shape of the gap: *to run two HTTP requests in parallel in Elm you must leave the `Task` language,
issue two commands, add two `Msg` constructors and two `Maybe` fields to the model, and reassemble
the pair by hand in `update`.* The concurrency exists; it is just not expressible as a value.

### 1.3 `Process.elm` documents a fairness property the scheduler does not implement

`Process.elm:56-57` says of `spawn`: *"The Elm runtime will interleave their progress. So if a task
is taking too long, we will pause it at an `andThen` and switch over to other stuff."*

`_Scheduler_step` has no operation counter and no yield. `AND_THEN` pushes a frame and continues the
same `while` loop; the only three exits are a `BINDING`, an empty mailbox at a `RECEIVE`, and an
exhausted stack. **Measured here** (transcribing the vendored scheduler verbatim, spawning two
five-`andThen` processes and recording the order in which their callbacks fire):

```
interleaving at andThen: AAAAABBBBB
```

The processes do not interleave. A pure `andThen` loop with no `binding` in it occupies the
scheduler until it finishes, which on the browser's main thread is a frozen page. The doc comment
describes Effect's behaviour (§2.2), not Elm's.

### 1.4 The other four gaps, stated precisely

- **`Process.spawn : Task x a -> Task y Id` discards the result.** `_Scheduler_spawn` wraps
  `_Scheduler_rawSpawn`, whose process record has no observer list and no outcome slot, so nothing
  can ever learn what a spawned task produced. You can start work; you cannot collect it. This is
  exactly Trio's `start_soon`, which returns nothing — except Trio refuses on purpose and supplies a
  nursery instead, and Elm supplies nothing.
- **Cancellation costs a round trip through `update`.** `kill` needs an `Id`, `spawn` yields one
  only as a `Task`, and the only way to hold one is to run that task to completion, tag the result
  as a `Msg` and store it in the model. By the time you can cancel, a frame has passed.
- **No scope, no finaliser, no `acquireRelease`.** The process record is
  `{ $, __id, __root, __stack, __mailbox }` — there is no parent, no child set and no finaliser
  list. `_Scheduler_kill` sets `proc.__root = null` and returns; nothing runs on the way out. A
  killed process leaks whatever it held.
- **No bound, no timeout, no retry.** There is nothing to bound, since there is no parallel
  combinator to bound. `Process.sleep` plus hand-written recursion is the whole toolkit.

**Conclusion on the brief's hypothesis: confirmed, and sharper than stated.** The architecture is
sound and the missing pieces are all *additions to the process record and the step loop* — an
outcome slot, an observer list, a parent link, a finaliser list and an operation counter. None of
them changes the shape of a `Task`. §5 costs that out; §3 measures it.

---

## 2. Effect-TS 3.22.2, read line by line

**The copy read is an installed one.** `npm install effect@3.22.2` into a scratch directory;
`require('effect/package.json').version` reports `3.22.2`. Every path below is relative to
`node_modules/effect/dist/esm/`, and every line number is from that tree. Where §1 and
`14/effect-ts` cite line numbers in the same files, they still hold — `getNextFailCont` is at
`internal/fiberRuntime.js:889-897` in this copy, exactly as `14/effect-ts` §2.4 says.

### 2.1 The `Async` op is Elm's `BINDING` with three extra things

`internal/opCodes/effect.js` is fifteen tags, against Elm's six. The one §1 forward-referenced is
`OP_ASYNC`, and `internal/core.js:255-263` is the whole of it:

```js
export const unsafeAsync = (register, blockingOn = FiberId.none) => {
  const effect = new EffectPrimitive(OpCodes.OP_ASYNC);
  let cancelerRef = undefined;
  effect.effect_instruction_i0 = resume => { cancelerRef = register(resume); };
  effect.effect_instruction_i1 = blockingOn;
  return onInterrupt(effect, _ => isEffect(cancelerRef) ? cancelerRef : void_);
};
```

That is `_Scheduler_binding` line for line: hand out a one-shot `resume`, take back a canceller,
store it. §1.1 is right that Elm predates it. The three additions are each a field:

- **`effect_instruction_i1` — `blockingOn`.** The `FiberId` this fiber is waiting on. Elm's
  process record has nowhere to put it, which is why Elm cannot report a deadlock or draw a
  fiber graph.
- **An `AbortController`, minted per operation**, when the register function takes two arguments
  (`internal/core.js:287-290`):

  ```js
  if (this.effect_instruction_i0.length !== 1) {
    controllerRef = new AbortController();
    cancelerRef = internalCall(() => this.effect_instruction_i0(proxyResume, controllerRef.signal));
  }
  ```

  So Effect already hands platform primitives the same `AbortSignal` that P2 §6 proposes to make
  the only mechanism. It is the *second* mechanism here, not the first — §2.3 is the first.
- **`onInterrupt`, which is a finaliser, not a canceller.** The canceller runs *and* the fiber
  unwinds through its finaliser stack. Elm's `__kill` runs and then `proc.__root = null`.

### 2.2 Fairness is an operation counter, and Elm's doc comment still does not describe it

§1.3 says the `Process.elm` comment — *"we will pause it at an `andThen` and switch over to other
stuff"* — describes Effect's behaviour. **It does not, and the correction sharpens §1.3 rather
than weakening it.** Effect does not pause at a bind. It pauses at a *budget*, and the budget is
2048 (`internal/core.js:962`):

```js
export const currentMaxOpsBeforeYield = globalValue(
  Symbol.for("effect/FiberRef/currentMaxOpsBeforeYield"), () => fiberRefUnsafeMake(2048));
```

The run loop cashes it in at `internal/fiberRuntime.js:1127-1139`:

```js
if (!this._isYielding) {
  this.currentOpCount += 1;
  const shouldYield = this.currentScheduler.shouldYield(this);
  if (shouldYield !== false) {
    this._isYielding = true;
    this.currentOpCount = 0;
    const oldCur = cur;
    cur = core.flatMap(core.yieldNow({ priority: shouldYield }), () => oldCur);
  }
}
```

`shouldYield` is `fiber.currentOpCount > fiber.getFiberRef(core.currentMaxOpsBeforeYield)`
(`Scheduler.js:117-118`). **Measured here**, two forked fibers doing pure `flatMap` work:

```js
// m7b.mjs
import { Effect, Fiber } from "effect";
const trace = [];
const run = async (label, mk, n, wrap = (x) => x) => {
  trace.length = 0;
  await Effect.runPromise(wrap(Effect.gen(function* () {
    const a = yield* Effect.fork(mk('A', n));
    const b = yield* Effect.fork(mk('B', n));
    yield* Fiber.join(a); yield* Fiber.join(b);
  })));
  console.log(`${label}: ${trace.join('')}`);
};
const plain = (tag, n) => Effect.gen(function* () { for (let i = 0; i < n; i++) { trace.push(tag); yield* Effect.sync(() => i); } });
const withYield = (tag, n) => Effect.gen(function* () { for (let i = 0; i < n; i++) { trace.push(tag); yield* Effect.yieldNow(); } });
const withSleep = (tag, n) => Effect.gen(function* () { for (let i = 0; i < n; i++) { trace.push(tag); yield* Effect.sleep(0); } });

await run('5 flatMaps, default budget 2048 ', plain, 5);
await run('5 Effect.yieldNow              ', withYield, 5);
await run('5 Effect.sleep(0)              ', withSleep, 5);
await run('budget 512, 1500 flatMaps each ', (t, n) => plain(t, n), 1500,
  (e) => Effect.map(Effect.withMaxOpsBeforeYield(e, 512), () => { const s = trace.join(''); const runs = s.replace(/(.)\1*/g, (m) => m[0] + m.length + ' '); trace.length = 0; trace.push('run-lengths: ' + runs); }));
```

| what the two fibers do | trace |
|---|---|
| 5 `flatMap`s each, default budget | `AAAAABBBBB` |
| 5 `Effect.yieldNow()` each | `ABABABABAB` |
| 5 `Effect.sleep(0)` each | `ABABABABAB` |
| 1500 `flatMap`s each, `withMaxOpsBeforeYield(512)` | run lengths `A511 B511 A503 B503 A486 B486` |

**Effect's answer to §1.3's `AAAAABBBBB` is the same `AAAAABBBBB`.** The op counter is real and
does exactly what the fourth row shows, but at five operations it never fires. Elm's defect is
not that it lacks interleaving at a bind; it is that it has *no budget at all*, so the run length
is unbounded rather than 2048.

### 2.3 The macrotask escape is in the scheduler, not the fiber, and it is the thing that unfreezes a page

The op counter yields to *the scheduler*, and the default scheduler is
`new MixedScheduler(2048)` (`Scheduler.js:130`). Its runner (`Scheduler.js:97-104`):

```js
getRunner = SchedulerRunner.cached((depth, drain) => {
  if (depth >= this.maxNextTickBeforeTimer) { setTimeout(() => drain(0), 0); }
  else { Promise.resolve(void 0).then(() => drain(depth + 1)); }
});
```

Two counters, not one. `currentMaxOpsBeforeYield` (2048 ops) decides *when a fiber yields*;
`maxNextTickBeforeTimer` (2048 nested microtask drains) decides *when the queue leaves the
microtask checkpoint for a `setTimeout`*. Only the second gives the browser a frame back, because
a microtask does not yield to rendering or to timers (§3.3). **Measured here**, an `Effect.sync`
chain with a `setTimeout(…, 0)` armed at the start:

```js
// m6b.mjs
import { Effect } from "effect";

async function run(N, label, effect) {
  const t0 = process.hrtime.bigint();
  let firstTimerMs = null;
  setTimeout(() => { firstTimerMs = Number(process.hrtime.bigint() - t0) / 1e6; }, 0);
  const t = process.hrtime.bigint();
  const out = await Effect.runPromise(effect);
  const work = Number(process.hrtime.bigint() - t) / 1e6;
  await new Promise(r => setTimeout(r, 0));
  console.log(`${label} N=${N}: work ${work.toFixed(0)} ms -> ${out}, armed setTimeout(0) fired after ${firstTimerMs.toFixed(1)} ms`);
}

const mk = (N) => Effect.gen(function* () {
  let s = 0;
  for (let i = 0; i < N; i++) s = yield* Effect.sync(() => s + 1);
  return s;
});

for (const N of [2_000_000, 5_000_000, 8_000_000]) await run(N, 'default (2048 ops/yield)', mk(N));
// same work, but yield every 16 ops: 2048 microtask drains are consumed 16 ops at a time.
for (const N of [100_000, 200_000]) await run(N, 'maxOpsBeforeYield=16    ', Effect.withMaxOpsBeforeYield(mk(N), 16));
```

The table below quotes the first four of the five lines it prints.

| ops in the chain | work | armed `setTimeout(0)` fired after |
|---|---|---|
| 2,000,000, default | 361 ms | 361 ms |
| 5,000,000, default | 872 ms | 723 ms |
| 8,000,000, default | 1528 ms | 814 ms |
| 100,000, `withMaxOpsBeforeYield(16)` | 131 ms | 20 ms |

At 2M operations the fiber yields ~977 times and never exhausts the 2048-deep microtask budget,
so **the page is frozen for 361 ms with the op counter working perfectly.** The default
configuration's first macrotask yield is at roughly 2048 × 2048 ≈ 4.2M operations, which is what
rows 2 and 3 show. This is the single most important structural fact in §2 for beni: *an
operation counter is not a fairness mechanism on JavaScript. A macrotask escape is.* §4.7 shows
three other runtimes independently arriving at the same two-tier design, with far smaller budgets.

**Aside, reproduced twice**: `Effect.withMaxOpsBeforeYield(e, 1)` and `(e, 4)` diverge — heap
exhaustion at ~4 GB in both runs on this machine. Budgets of 16 and 512 are fine. Not pursued; a
low-budget configuration is not a shape beni would copy.

### 2.4 Interruption resumes the parked fiber; it does not wait for the primitive

This is the mechanism P2 does not have, and it is four lines
(`internal/fiberRuntime.js:709-717`):

```js
case FiberMessage.OP_INTERRUPT_SIGNAL: {
  this.processNewInterruptSignal(message.cause);
  if (this._asyncInterruptor !== null) {
    this._asyncInterruptor(core.exitFailCause(message.cause));
    this._asyncInterruptor = null;
  }
  return EvaluationSignalContinue; }
```

`_asyncInterruptor` *is* the resume callback the `Async` op handed out
(`internal/fiberRuntime.js:844-854`), and it is one-shot (`if (!alreadyCalled)`). So an interrupt
resumes the fiber with a failure **immediately**, the pending operation's later resume is dropped
on the floor, and the fiber unwinds through its finalisers at cancel time. The primitive is not
consulted and does not have to cooperate.

**Measured here**, the same uncooperative primitive —
`new Promise(res => setTimeout(() => res('done'), 300))`, which never looks at a signal — under
both runtimes, cancelled at 50 ms:

```js
// m8.mjs
import { Effect, Fiber } from "effect";
const t0 = process.hrtime.bigint();
const at = () => (Number(process.hrtime.bigint() - t0) / 1e6).toFixed(0) + 'ms';
const log = (...a) => console.log(at().padStart(6), ...a);

const uncooperative = () => new Promise(res => setTimeout(() => res('done'), 300));

// --- Effect: Effect.promise wraps it; the fiber has no canceller for it. ---
await Effect.runPromise(Effect.gen(function* () {
  const f = yield* Effect.fork(Effect.gen(function* () {
    try {
      log('E: parked on uncooperative promise');
      const r = yield* Effect.promise(uncooperative);
      log('E: primitive returned', r);
    } finally { log('E: generator finally ran'); }
  }).pipe(Effect.onInterrupt(() => Effect.sync(() => log('E: onInterrupt ran')))));
  yield* Effect.sleep(50);
  log('E: interrupting');
  yield* Fiber.interrupt(f);
  log('E: Fiber.interrupt returned; fiber exit =', f.unsafePoll()?._tag);
}));
await new Promise(r => setTimeout(r, 400));
log('E: 400ms after the primitive would have settled');

// --- Native async/await + AbortController ---
console.log('---');
const t1 = process.hrtime.bigint();
const at1 = () => (Number(process.hrtime.bigint() - t1) / 1e6).toFixed(0) + 'ms';
const log1 = (...a) => console.log(at1().padStart(6), ...a);

const ac = new AbortController();
async function body(signal) {
  try {
    log1('N: parked on uncooperative promise');
    const r = await uncooperative();       // ignores `signal` entirely
    log1('N: primitive returned', r);
  } finally { log1('N: finally ran'); }
}
const p = body(ac.signal).catch(e => log1('N: rejected', e.name));
setTimeout(() => { log1('N: abort()'); ac.abort(); }, 50);
await p;
log1('N: awaited body');
```

The four lines that matter from each half (the trailing end-of-window markers elided):

```
   4ms E: parked on uncooperative promise
  54ms E: interrupting
  55ms E: onInterrupt ran
  56ms E: Fiber.interrupt returned; fiber exit = Failure
   …
---
   0ms N: parked on uncooperative promise
  51ms N: abort()
 301ms N: primitive returned done
 301ms N: finally ran
   …
```

Effect is done at 56 ms. Native `async`/`await` plus an `AbortController` runs its `finally` at
301 ms — **when the work settled, not when you cancelled.** P2 §11 Q3 states this as a risk; this
is the measurement of it.

### 2.5 Finalisers are a scope stack, and the generator's own `try`/`finally` is not one

`14/effect-ts` §2.4's claim holds verbatim in 3.22.2. `getNextFailCont`
(`internal/fiberRuntime.js:889-897`) pops and discards `OP_ITERATOR` frames alongside
`OP_ON_SUCCESS` and `OP_WHILE`, and **nothing in the runtime ever calls `.return()` on an effect
generator.** `grep -rn '\.return(' internal/` has exactly one hit — `internal/stream.js:907`, in
`fromAsyncIterable`:

```js
Effect.acquireRelease(Effect.sync(() => iterable[Symbol.asyncIterator]()),
  iterator => iterator.return ? Effect.promise(async () => iterator.return()) : Effect.void)
```

— and that is Effect *closing a user-supplied async iterator* it was handed, not closing one of
its own `OP_ITERATOR` frames. (`List.js` and `MutableList.js` call `.return()` too, on their own
iterators; also unrelated.) The effect generator is abandoned. In the `m8.mjs` trace above,
`E: generator finally ran` never prints.

What runs instead is `addFinalizer`, which pushes onto a `Scope`, and `acquireRelease`, which is
one line (`internal/fiberRuntime.js:1301`):

```js
export const acquireRelease = dual(args => core.isEffect(args[0]), (acquire, release) =>
  core.uninterruptible(core.tap(acquire, a => addFinalizer(exit => release(a, exit)))));
```

`core.uninterruptible` around the acquire is the whole guarantee: an interrupt cannot land between
"the resource opened" and "the finaliser registered". **Measured here** (`m9.mjs`, quoted in §3.0, case b):
acquire at 1 ms, interrupt at 50 ms, `RELEASED` at 53 ms.

**So Effect's own generator syntax has exactly the defect P2 attributes to it, and Effect's
runtime does not rely on that syntax.** P2 §6 cites `14/effect-ts` §2.4 to argue that native
`async`'s `try`/`finally` is better. On the narrow point it is right — §3.6 confirms `try`/`finally`
does run on a rejected `await`, by spec. On the wide point §2.4 above and §3.7 say the trade is
the other way round: Effect gives up `try`/`finally` and buys prompt cancellation; native
`async`/`await` keeps `try`/`finally` and loses prompt cancellation.

### 2.6 The fiber record, and what concurrency defaults to

`internal/fiberRuntime.js:172-192` is the record §1's conclusion asks for, in full:

```js
_fiberRefs; _fiberId;
_queue = new Array();        _children = null;    _observers = new Array();
_running = false;            _stack = [];         _asyncInterruptor = null;
_asyncBlockingOn = null;     _exitValue = null;   _steps = [];
_isYielding = false;
currentRuntimeFlags; currentOpCount; currentSupervisor; currentScheduler;
currentTracer; currentSpan; currentContext; currentDefaultServices;
```

Against Elm's `{ $, __id, __root, __stack, __mailbox }`: `_exitValue` is §1's outcome slot,
`_observers` the observer list, `_children` the child set, `_asyncInterruptor` the prompt-cancel
hook, `currentOpCount` the operation counter. The parent link is not on the fiber — it is in the
`Local` fiber scope (`internal/fiberScope.js:21-35`), which registers the child with the parent
*and* registers an observer that removes it on exit. Finalisers are not on the fiber either; they
are on a `Scope` in the context. §5.2 takes a position on both.

`onInterrupt` on a parent reaches every descendant synchronously
(`internal/fiberRuntime.js:585-595`, `sendInterruptSignalToAllChildren`).

**The `currentConcurrency` FiberRef defaults to `"unbounded"` — but the absence of a
`concurrency` option never reaches it** (`internal/core.js:974`):

```js
export const currentConcurrency = globalValue(
  Symbol.for("effect/FiberRef/currentConcurrency"), () => fiberRefUnsafeMake("unbounded"));
```

`internal/concurrency.js:3-13` is the dispatch, and it consults that FiberRef only in the
`"inherit"` arm:

```js
export const match = (concurrency, sequential, unbounded, bounded) => {
  switch (concurrency) {
    case undefined:   return sequential();
    case "unbounded": return unbounded();
    case "inherit":   return core.fiberRefGetWith(core.currentConcurrency, concurrency =>
      concurrency === "unbounded" ? unbounded() : concurrency > 1 ? bounded(concurrency) : sequential());
    default:          return concurrency > 1 ? bounded(concurrency) : sequential();
  }
};
```

So `Effect.forEach` without a `concurrency` option is *sequential*, not parallel — `case
undefined` is `sequential()`. **Unbounded is opt-in**: `{ concurrency: 'unbounded' }`, or
`'inherit'` under the default FiberRef. §3.4 measures what that opt-in costs, and §5.3 row 5
reads it correctly — the sin is not a dangerous default, it is that the safe answer (a number)
and the dangerous one (`'unbounded'`) are equally easy to write.

---

## 3. Measurements

### 3.0 Machine, and how to reproduce

**Node v24.19.0 / Intel N100 (4 cores) / Linux 7.2.2 / 15.4 GiB**, which is the preamble's
machine; no correction needed. `node --version` → `v24.19.0`. Every script quoted in this report
is complete as quoted: write it to a file and run `node <file>` (or `node --expose-gc <file>`
where noted) in a directory with `effect@3.22.2` installed. Figures are the median of three runs
unless a range is given. Everything labelled *measured here* is from these scripts; nothing in §3
is estimated. §2 quotes three of its scripts at the point of use (`m7b.mjs` §2.2, `m6b.mjs` §2.3,
`m8.mjs` §2.4); the fourth, `m9.mjs`, is cited from §2.5, §3.6 and §5.4 and is quoted here
because it carries four separate cases.

```js
// m9.mjs — finaliser semantics under cancellation, four cases (a, b, d, e are cited in the text).
import { Effect, Fiber } from "effect";
const clock = () => { const t = process.hrtime.bigint(); return (...a) => console.log(((Number(process.hrtime.bigint()-t)/1e6).toFixed(0)+'ms').padStart(6), ...a); };

// (a) Effect: fiber interrupted while parked on a *cooperative* primitive (Effect.sleep).
{ const log = clock();
  await Effect.runPromise(Effect.gen(function* () {
    const f = yield* Effect.fork(Effect.gen(function* () {
      try { yield* Effect.sleep(300); log('a: sleep returned'); }
      finally { log('a: GENERATOR finally ran'); }
    }).pipe(Effect.ensuring(Effect.sync(() => log('a: Effect.ensuring ran')))));
    yield* Effect.sleep(50);
    yield* Fiber.interrupt(f); log('a: interrupt returned');
  }));
  await new Promise(r => setTimeout(r, 350)); log('a: end of window'); }
console.log('---');
// (b) Effect: acquireRelease across an interruption.
{ const log = clock();
  await Effect.runPromise(Effect.gen(function* () {
    const f = yield* Effect.fork(Effect.scoped(Effect.gen(function* () {
      yield* Effect.acquireRelease(Effect.sync(() => { log('b: acquired'); return 'R'; }),
                                   () => Effect.sync(() => log('b: RELEASED')));
      yield* Effect.sleep(300);
    })));
    yield* Effect.sleep(50);
    yield* Fiber.interrupt(f); log('b: interrupt returned');
  }));
  await new Promise(r => setTimeout(r, 350)); log('b: end of window'); }
console.log('---');
// (c) native: a *cooperative* primitive that rejects on abort.
{ const log = clock();
  const ac = new AbortController();
  const sleepAbortable = (ms, signal) => new Promise((res, rej) => {
    const id = setTimeout(res, ms);
    signal.addEventListener('abort', () => { clearTimeout(id); rej(signal.reason ?? new DOMException('Aborted','AbortError')); }, { once: true });
  });
  const p = (async () => { try { await sleepAbortable(300, ac.signal); log('c: sleep returned'); }
                           finally { log('c: finally ran'); } })().catch(e => log('c: rejected', e.name));
  setTimeout(() => { log('c: abort()'); ac.abort(); }, 50);
  await p; log('c: joined'); await new Promise(r => setTimeout(r, 300)); log('c: end of window'); }
console.log('---');
// (d) a synchronous loop: can either runtime interrupt it?
{ const log = clock();
  const spin = (ms) => { const end = Date.now() + ms; while (Date.now() < end) {} };
  const ac = new AbortController();
  const p = (async () => { try { log('d: entering 300ms sync loop'); spin(300); log('d: loop finished'); }
                           finally { log('d: finally ran'); } })();
  setTimeout(() => log('d: abort() timer — did it even fire on time?'), 50);
  await p; await new Promise(r => setTimeout(r, 10)); log('d: end'); }
console.log('---');
// (e) Effect, same synchronous loop inside Effect.sync
{ const log = clock();
  const spin = (ms) => { const end = Date.now() + ms; while (Date.now() < end) {} };
  await Effect.runPromise(Effect.gen(function* () {
    const f = yield* Effect.fork(Effect.sync(() => { log('e: entering 300ms sync loop'); spin(300); log('e: loop finished'); })
      .pipe(Effect.ensuring(Effect.sync(() => log('e: ensuring ran')))));
    yield* Effect.sleep(50);
    log('e: about to interrupt');
    yield* Fiber.interrupt(f); log('e: interrupt returned');
  })); }
```

```
  55ms a: Effect.ensuring ran
  57ms a: interrupt returned
 406ms a: end of window
---
   1ms b: acquired
  53ms b: RELEASED
  54ms b: interrupt returned
 403ms b: end of window
---
  51ms c: abort()
  51ms c: finally ran
  51ms c: rejected AbortError
  51ms c: joined
 352ms c: end of window
---
   0ms d: entering 300ms sync loop
 299ms d: loop finished
 300ms d: finally ran
 310ms d: end
---
   1ms e: entering 300ms sync loop
 300ms e: loop finished
 300ms e: ensuring ran
 611ms d: abort() timer — did it even fire on time?
 301ms e: about to interrupt
 301ms e: interrupt returned
```

Three things to read out of that. `a: GENERATOR finally ran` never prints — §2.5's point, that the
effect generator is abandoned rather than closed. In `b`, `RELEASED` lands at 53 ms for an
interrupt issued at 50 ms — §2.5's `acquireRelease` guarantee. And `d`'s abort timer, armed for
50 ms, does not run until *both* synchronous loops are over, which is why it prints out of order,
at 611 ms on `d`'s clock, in the middle of case `e` — §3.6's last paragraph.

### 3.1 One `await` costs ~120 ns and a microtask turn, and the spec says it must

```js
// m1.mjs
const N = 5_000_000;
function addSync(a, b) { return a + b; }
async function addAsync(a, b) { return a + b; }
async function direct()          { let s = 0; for (let i = 0; i < N; i++) s = addSync(s, 1); return s; }
async function awaitNonPromise() { let s = 0; for (let i = 0; i < N; i++) s = await addSync(s, 1); return s; }
async function awaited()         { let s = 0; for (let i = 0; i < N; i++) s = await addAsync(s, 1); return s; }
for (let r = 0; r < 3; r++) for (const [n, f] of
  [['direct', direct], ['await non-promise', awaitNonPromise], ['await async fn', awaited]]) {
    const t = process.hrtime.bigint(); await f();
    console.log(n, (Number(process.hrtime.bigint() - t) / N).toFixed(1), 'ns/op'); }
```

| | ns/op | vs direct |
|---|---|---|
| direct call | 1.8 | 1× |
| `await` on a non-promise | 122–135 | ~70× |
| `await` on an `async function` returning a value | 117–129 | ~68× |

**The turn is normative, not a V8 choice.** `Await ( arg )`, ECMA-262 §27.10.5.3
(tc39.es/ecma262, the editor's draft, fetched 2026-09-15 — published ES2026 numbers the same
abstract operation §27.7.5.3), verbatim:

> 1. Let *asyncContext* be the running execution context.
> 2. Let *promise* be ? PromiseResolve(%Promise%, *arg*).
> 3. Let *fulfilledClosure* be a new Abstract Closure with parameters (*value*) … Perform
>    Completion(RunSuspendedContext(*asyncContext*, NormalCompletion(*value*))). …
> 5. Let *rejectedClosure* be a new Abstract Closure with parameters (*reason*) … Perform
>    Completion(RunSuspendedContext(*asyncContext*, ThrowCompletion(*reason*))). …
> 7. Perform PerformPromiseThen(*promise*, *onFulfilled*, *onRejected*).
> 8. Return ? RunCallerContext(**empty**).

Step 2 wraps a non-promise, step 7 enqueues a reaction job, step 8 returns to the caller. There is
no branch for "the value was already there". **This is P2 §7.2's admitted cost, measured**: its
worked example — a memoising `getUser` that hits cache 480 times in 500 — pays 480 × ~120 ns ≈
58 µs and 480 event-loop turns that a suspension protocol with an inline fast path would not pay.
Note the two clauses of the spec text that §3.6 and §3.7 turn on: a rejection resumes with a
**ThrowCompletion**, and nothing at all happens if the promise never settles.

### 3.2 Deep async recursion: 416 B a frame, 96 B in tail position

```js
// m2b.mjs — run with node --expose-gc
const N = Number(process.argv[2] ?? 200_000);
let base = 0, deep = 0;
async function leaf(x) { return x + 1; }
async function foldAwait(i, acc) {   // non-tail
  if (i === 0) { global.gc(); deep = process.memoryUsage().heapUsed; return acc; }
  return await foldAwait(i - 1, await leaf(acc)); }
async function foldTail(i, acc) {    // tail: inner promise returned directly
  if (i === 0) { global.gc(); deep = process.memoryUsage().heapUsed; return acc; }
  return foldTail(i - 1, await leaf(acc)); }
for (const [n, f] of [['await', foldAwait], ['tail', foldTail]]) {
  global.gc(); base = process.memoryUsage().heapUsed; await f(N, 0);
  console.log(n, ((deep - base) / N).toFixed(0), 'B/frame'); }
```

| N | `return await f(…)` | `return f(…)` |
|---|---|---|
| 200,000 | 79.3 MiB — **416 B/frame** | 18.3 MiB — **96 B/frame** |
| 1,000,000 | 396.7 MiB — 416 B/frame | 91.6 MiB — 96 B/frame |

Throughput, same shapes at N = 1,000,000: sync loop 2.1 ms, `await` loop 139 ms, tail recursion
342 ms, non-tail recursion 867 ms.

**Neither overflows the stack at a million deep**, which confirms P2 §7.4's premise; what it costs
is live heap, and P2 §7.4's tail-call rule is worth **4.3× the bytes and 2.5× the time**. Chasing
this is not optional: 400 MiB for a fold over a million-element list is a crash on a phone.

### 3.3 A tight `await` loop starves timers completely

```js
// m5.mjs
const N = 2_000_000;
async function leaf(x) { return x + 1; }
{ const t = process.hrtime.bigint(); let fired = null;
  setTimeout(() => { fired = Number(process.hrtime.bigint() - t) / 1e6; }, 0);
  let s = 0; for (let i = 0; i < N; i++) s = await leaf(s);
  const work = Number(process.hrtime.bigint() - t) / 1e6;
  await new Promise(r => setTimeout(r, 0));
  console.log('await loop: work', work.toFixed(1), 'ms; armed setTimeout(0) fired after', fired.toFixed(1), 'ms'); }
{ const t = process.hrtime.bigint(); let fired = null;
  setTimeout(() => { fired = Number(process.hrtime.bigint() - t) / 1e6; }, 0);
  let s = 0; for (let i = 0; i < N; i++) { s = await leaf(s);
    if (i % 2048 === 2047) await new Promise(r => setTimeout(r, 0)); }
  console.log('yield every 2048: work', (Number(process.hrtime.bigint() - t) / 1e6).toFixed(1),
              'ms; armed setTimeout(0) fired after', fired.toFixed(1), 'ms'); }
```

```
await loop (2000000 awaits): work 274.2 ms, armed setTimeout(0) fired after 274.4 ms
yield to setTimeout every 2048: work 1381.3 ms, armed setTimeout(0) fired after 1.1 ms
```

**A microtask checkpoint is not a yield.** The armed timer waits the full 274 ms. This is §1.3's
frozen page reappearing under P2's lowering: an `await`-only loop freezes a browser exactly as an
`andThen`-only loop does in Elm, and for the same reason — the run never reaches the macrotask
queue. It also means **`suspends` is not the same bit as "can be interrupted"**, because every one
of those 2,000,000 suspension points is a point at which nothing else can run.

The second row is the price of fixing it: **5.0× throughput** for a 1.1 ms timer latency. That is
the knob every runtime in §4 tunes, and beni will have to pick a number for it.

### 3.4 Unbounded fan-out costs ~11,700× the resident memory

```js
// m11b.mjs — run with node --expose-gc
const N = 200_000, LIMIT = 16;
async function instant(i) { return i; }
async function boundedPool(n, limit, f) {
  const out = new Array(n); let next = 0;
  const worker = async () => { while (true) { const i = next++; if (i >= n) return; out[i] = await f(i); } };
  await Promise.all(Array.from({ length: limit }, worker)); return out; }
const time = async (l, f) => { const t = process.hrtime.bigint(); const r = await f();
  console.log(l, (Number(process.hrtime.bigint() - t) / 1e6).toFixed(0), 'ms', r.length); };
await time('Promise.all ', () => Promise.all(Array.from({ length: N }, (_, i) => instant(i))));
await time('bounded 16  ', () => boundedPool(N, LIMIT, instant));
await time('sequential  ', async () => { const o = new Array(N); for (let i = 0; i < N; i++) o[i] = await instant(i); return o; });
let release; const gate = new Promise(r => { release = r; });
const held = async () => { const buf = Buffer.allocUnsafe(4096); await gate; return buf.length; };
global.gc(); const base = process.memoryUsage().heapUsed + process.memoryUsage().external;
const all = Promise.all(Array.from({ length: N }, held));
await new Promise(r => setImmediate(r)); global.gc();
const live = process.memoryUsage().heapUsed + process.memoryUsage().external;
console.log(`${N} live ops holding 4 KiB each: ${((live - base) / 1048576).toFixed(1)} MiB`);
release(); await all;
```

The bounded side of that comparison is a separate run, because it has to be *measured* and not
divided out — 4724 B × 16 is arithmetic, not a figure:

```js
// m11c.mjs — run with node --expose-gc
const N = 200_000, LIMIT = 16;
const heap = () => { global.gc(); return process.memoryUsage().heapUsed + process.memoryUsage().external; };
let release; const gate = new Promise(r => { release = r; });
const held = async () => { const buf = Buffer.allocUnsafe(4096); await gate; return buf.length; };
const base = heap();
let next = 0, started = 0;
const worker = async () => { while (true) { const i = next++; if (i >= N) return; started++; await held(); } };
const all = Promise.all(Array.from({ length: LIMIT }, worker));
await new Promise(r => setImmediate(r));
const live = heap();
console.log(`${LIMIT} of ${N} operations in flight, 4 KiB each: ${((live - base) / 1024).toFixed(1)} KiB (${started} started)`);
release(); await all;
```

| | 200,000 instantly-settling tasks |
|---|---|
| `Promise.all`, all in flight | 92 ms |
| bounded pool, 16 in flight | 22 ms |
| sequential `await` loop | 16 ms |

| 200,000 operations each holding a 4 KiB buffer | resident, measured |
|---|---|
| unbounded (`m11b.mjs`) | **901.1 MiB** (4724 B/op) |
| bounded to 16 (`m11c.mjs`) | **78.6 KiB** (78.8 / 78.6 / 78.5 over three runs) |

**`Promise.all` is not a cheaper `parAll`; it is a slower one that also holds everything live.**
The bounded pool wins on time *and* on memory, because the 200,000-element promise array is itself
the cost. Bounded concurrency is not an ergonomic nicety in §5 — it is the difference between
79 KiB and 901 MiB for the same 200,000 operations, a factor of about 11,700.

### 3.5 An abort *check* is free; an abort *registration* is not

```js
// m10.mjs
const N = 10_000_000;
const ac = new AbortController();
const signal = ac.signal;
const flag = { aborted: false };          // the baseline the table's first row reports
function bench(name, fn, n = N) {
  fn(1000); // warm
  const t = process.hrtime.bigint();
  fn(n);
  const ns = Number(process.hrtime.bigint() - t);
  console.log(`${name}: ${(ns / n).toFixed(2)} ns/op  (${(ns/1e6).toFixed(1)} ms / ${n})`);
}
bench('plain boolean field    ', n => { let c = 0; for (let i = 0; i < n; i++) if (flag.aborted) c++; return c; });
bench('signal.aborted         ', n => { let c = 0; for (let i = 0; i < n; i++) if (signal.aborted) c++; return c; });
bench('signal.throwIfAborted()', n => { for (let i = 0; i < n; i++) signal.throwIfAborted(); });
bench('new AbortController()  ', n => { let x; for (let i = 0; i < n; i++) x = new AbortController(); return x; }, 1_000_000);
bench('add+remove abort lstnr ', n => { const f = () => {}; for (let i = 0; i < n; i++) { signal.addEventListener('abort', f); signal.removeEventListener('abort', f); } }, 1_000_000);
bench('AbortSignal.any([s])   ', n => { let x; for (let i = 0; i < n; i++) x = AbortSignal.any([signal]); return x; }, 200_000);
```

| | ns/op |
|---|---|
| plain boolean field read | 2.42 |
| `signal.aborted` | 3.14 |
| `signal.throwIfAborted()` | 3.06 |
| `new AbortController()` | 6.22 |
| `addEventListener` + `removeEventListener` for one `abort` | **306.44** |
| `AbortSignal.any([s])` | **383.79** |

**The asymmetry decides the shape of §5's cancel.** Polling a signal between operations is free —
cheaper than one `await`. Registering a per-operation canceller costs 2.5 `await`s, and *deriving*
a child signal from a parent (which is what a nested `Task.scope` needs on every entry) costs
three. A scope tree built out of `AbortSignal.any` pays ~384 ns per level per scope; a scope tree
built out of a parent pointer and a walk pays a pointer write.

### 3.6 `try`/`finally` runs on a rejected `await` — and fails three other ways

The spec (§3.1, step 5) resumes the suspended context with a **ThrowCompletion**, so a rejection
enters the body at the `await` and unwinds through `finally`. That much is correct by
construction, and §2.4's case (c) measures it: abort at 51 ms, `finally` at 51 ms. The three
failure modes are what P2 §6 does not account for.

```js
// m12.mjs — run with node --expose-gc. All three cases.
const clock = () => { const t = process.hrtime.bigint(); return (...a) => console.log(((Number(process.hrtime.bigint()-t)/1e6).toFixed(0)+'ms').padStart(6), ...a); };

// (i) A promise that never settles. The async function is suspended forever; its `finally`
//     is unreachable, and the whole frame is simply collected. No error, no finaliser, no trace.
{ const log = clock();
  let ran = false;
  let ref;
  (function () {
    const p = (async () => {
      try { await new Promise(() => {}); }        // never settles
      finally { ran = true; console.log('  (i) finally ran'); }
    })();
    ref = new WeakRef(p);
  })();
  await new Promise(r => setTimeout(r, 50));
  global.gc(); global.gc();
  await new Promise(r => setTimeout(r, 50));
  log(`(i) never-settling await: finally ran = ${ran}; frame collected = ${ref.deref() === undefined}`);
}

// (ii) A `finally` that itself awaits. It delays the rejection by its own duration...
{ const log = clock();
  const ac = new AbortController();
  const abortable = (ms, s) => new Promise((res, rej) => { const id = setTimeout(res, ms);
    s.addEventListener('abort', () => { clearTimeout(id); rej(new Error('aborted')); }, {once:true}); });
  const p = (async () => {
    try { await abortable(1000, ac.signal); }
    finally { log('  (ii) finally entered'); await new Promise(r => setTimeout(r, 200)); log('  (ii) finally done'); }
  })().catch(e => log('  (ii) rejection surfaced:', e.message));
  setTimeout(() => ac.abort(), 20);
  await p; log('(ii) joined');
}

// (iii) ...and a `return` or a swallowed throw in `finally` discards the cancellation entirely.
{ const log = clock();
  const ac = new AbortController();
  const abortable = (ms, s) => new Promise((res, rej) => { const id = setTimeout(res, ms);
    s.addEventListener('abort', () => { clearTimeout(id); rej(new Error('aborted')); }, {once:true}); });
  const r = await (async () => {
    try { await abortable(1000, ac.signal); return 'normal'; }
    finally { return 'swallowed'; }             // eslint-disable-line no-unsafe-finally
  })().then(v => 'resolved: ' + v, e => 'rejected: ' + e.message);
  setTimeout(() => {}, 0);
  log('(iii) cancelled function settled as ->', r);
}
setTimeout(() => {}, 0);
```

```
 105ms (i) never-settling await: finally ran = false; frame collected = true
  21ms   (ii) finally entered
 222ms   (ii) finally done
 222ms   (ii) rejection surfaced: aborted
 222ms (ii) joined
1002ms (iii) cancelled function settled as -> resolved: swallowed
```

**(i) A promise that never settles silently deletes the finaliser.** Spec step 7 registers
reactions; if neither fires, `RunSuspendedContext` is never called, the body never resumes, and
the frame is garbage. No error, no warning, no unhandled rejection, nothing in a stack trace. This
is §1.4's *"a killed process leaks whatever it held"* reappearing in a different costume — except
Elm at least ran `_Scheduler_kill`, whereas here nothing runs and nothing is even notified.

**(ii) A `finally` that itself awaits delays cancellation by its own duration.** Case (ii)
above: abort at 20 ms, `finally` entered at 21 ms, `finally` done at 222 ms, rejection
surfaced at 222 ms. A 200 ms cleanup makes the cancellation take 200 ms, and there is no bound and
no shield. Trio's doc calls this out by name and pairs its shield with a `CLEANUP_TIMEOUT`
(§4.3); Kotlin's `withContext(NonCancellable)` does not (§4.4).

**(iii) A `finally` that returns discards the cancellation.** Case (iii) above, isolated so the
settled value is the only thing printed:

```js
// m12b.mjs
const ac = new AbortController(); setTimeout(() => ac.abort(), 20);
const abortable = (ms, s) => new Promise((res, rej) => { const id = setTimeout(res, ms);
  s.addEventListener('abort', () => { clearTimeout(id); rej(new Error('aborted')); }, { once: true }); });
const r = await (async () => { try { await abortable(1000, ac.signal); return 'normal'; }
                               finally { return 'swallowed'; } })()
  .then(v => 'resolved: ' + v, e => 'rejected: ' + e.message);
console.log('(iii) a cancelled async function whose finally returns settles as ->', r);
```

```
(iii) a cancelled async function whose finally returns settles as -> resolved: swallowed
```

The cancelled function reports success. Trio prevents the analogue structurally by deriving
`Cancelled` from `BaseException` so `except Exception` cannot catch it (§4.3); Kotlin does not
prevent it and its own docs say so (§4.4). **beni can prevent it, because beni controls what a
`finally` compiles to** — §5.3's `bracket` row.

**Neither runtime can interrupt a synchronous loop.** `m9.mjs` (§3.0) case (d), a 300 ms busy loop inside
an `async function`: `finally` at 300 ms, and the abort timer armed for 50 ms did not run until
the loop ended. Case (e), the same loop inside `Effect.sync`: `ensuring` at 300 ms, and the
interrupt could not even be *issued* until 301 ms because the event loop was blocked. This is not
a difference between the two designs; it is the platform.

### 3.7 Prompt cancellation is buyable under native `async`, at ~10× per suspension point

§2.4's gap is not unfixable. Effect's `_asyncInterruptor` resumes the parked fiber without
consulting the primitive; the same is available under `await` by racing every suspension point
against the scope's cancellation promise.

```js
// m15.mjs, case (1) — the semantics. Case (2), the cost, is m15b.mjs below.
const clock = () => { const t = process.hrtime.bigint(); return (...a) => console.log(((Number(process.hrtime.bigint()-t)/1e6).toFixed(0)+'ms').padStart(6), ...a); };
const uncooperative = () => new Promise(res => setTimeout(() => res('done'), 300));
const log = clock();
const ac = new AbortController();
const cancelled = new Promise((_, rej) => ac.signal.addEventListener('abort', () => rej(new Error('cancelled')), {once:true}));
const p = (async () => {
  try { const r = await Promise.race([uncooperative(), cancelled]); log('  returned', r); }
  finally { log('  FINALLY ran'); }
})().catch(e => log('  rejected:', e.message));
setTimeout(() => { log('  cancel()'); ac.abort(); }, 50);
await p;
await new Promise(r => setTimeout(r, 300));
log('(1) 300ms later: the underlying setTimeout has fired and its result was dropped');
```

```
  51ms   cancel()
  54ms   FINALLY ran
  54ms   rejected: cancelled
 355ms (1) 300ms later: the underlying setTimeout has fired and its result was dropped
```

**Semantically this is Effect's behaviour**, including the "the primitive's result is dropped"
part. The cost, three rounds after warming all three shapes:

```js
// m15b.mjs — per-suspension-point cost of a cancellation check, three rounds.
const N = 1_000_000;
const ac = new AbortController();
const cancelled = new Promise((_, rej) => ac.signal.addEventListener('abort', () => rej(new Error('x')), {once:true}));
cancelled.catch(() => {});
async function leaf(x) { return x + 1; }
const cases = [
  ['plain   await e                ', async n => { let s=0; for (let i=0;i<n;i++) s = await leaf(s); return s; }],
  ['signal.aborted check, then await', async n => { let s=0; for (let i=0;i<n;i++) { if (ac.signal.aborted) throw 0; s = await leaf(s); } return s; }],
  ['await Promise.race([e, cancel]) ', async n => { let s=0; for (let i=0;i<n;i++) s = await Promise.race([leaf(s), cancelled]); return s; }],
];
for (const [name, fn] of cases) await fn(50_000);            // warm all three first
for (let r = 0; r < 3; r++) {
  const line = [];
  for (const [name, fn] of cases) {
    const t = process.hrtime.bigint(); await fn(N);
    line.push(`${name.trim()} = ${(Number(process.hrtime.bigint()-t)/N).toFixed(0)} ns`);
  }
  console.log(`round ${r}: ` + line.join('  |  '));
}
```

| per suspension point | round 0 | round 1 | round 2 |
|---|---|---|---|
| `await e` | 61 ns | 92 ns | 75 ns |
| `if (signal.aborted) throw; await e` | 48 ns | 48 ns | 48 ns |
| `await Promise.race([e, cancelled])` | **917 ns** | **1240 ns** | **831 ns** |

A polled check is free — indistinguishable from, or faster than, the plain loop. Racing costs
**roughly 10× an `await`** — call it ~1 µs; the three rounds span 831–1240 ns and the figure is
not stable to better than that — because it allocates a race capability and two reactions per
suspension point. §5.3 costs this out per primitive; the summary is that it is affordable at an
I/O boundary and not affordable on every `await` in a bit-polymorphic `List.map`.

### 3.8 What one parked unit of concurrency costs

Two scripts: `m13.mjs` is the table's rows 1, 2 and 5 (the baselines), `m14.mjs` is rows 3 and 4
(§5.2's record).

```js
// m13.mjs — run with node --expose-gc. Rows 1, 2 and 5.
import { Effect, Fiber } from "effect";
const N = Number(process.argv[2] ?? 100_000);
const mib = (b) => (b / 1048576).toFixed(1);
const heap = () => { global.gc(); global.gc(); return process.memoryUsage().heapUsed; };

// (a) a native async function parked on an unsettled promise
{ const base = heap(); const t = process.hrtime.bigint();
  const hold = []; const never = new Promise(() => {});
  for (let i = 0; i < N; i++) hold.push((async () => { try { await never; } finally {} })());
  const ms = Number(process.hrtime.bigint() - t) / 1e6;
  const d = heap() - base;
  console.log(`(a) ${N} parked async frames          : ${ms.toFixed(0)} ms to create, ${mib(d)} MiB, ${(d/N).toFixed(0)} B each`);
  hold.length = 0; }

// (b) the same, plus one AbortController + one abort listener (the minimum P2 §6 needs)
{ const base = heap(); const t = process.hrtime.bigint();
  const hold = [];
  for (let i = 0; i < N; i++) {
    const ac = new AbortController();
    const p = new Promise((_, rej) => ac.signal.addEventListener('abort', () => rej(new Error('x')), {once:true}));
    hold.push([ac, (async () => { try { await p; } catch {} })()]);
  }
  const ms = Number(process.hrtime.bigint() - t) / 1e6;
  const d = heap() - base;
  console.log(`(b) ${N} frames + AbortController+lstnr: ${ms.toFixed(0)} ms to create, ${mib(d)} MiB, ${(d/N).toFixed(0)} B each`);
  hold.length = 0; }

// (c) an Effect fiber forked and parked on Effect.never
{ const base = heap(); const t = process.hrtime.bigint();
  let ms, d;
  await Effect.runPromise(Effect.gen(function* () {
    const fibers = [];
    for (let i = 0; i < N; i++) fibers.push(yield* Effect.fork(Effect.never));
    ms = Number(process.hrtime.bigint() - t) / 1e6;
    d = heap() - base;
    console.log(`(c) ${N} forked Effect fibers         : ${ms.toFixed(0)} ms to create, ${mib(d)} MiB, ${(d/N).toFixed(0)} B each`);
    yield* Effect.forEach(fibers, f => Fiber.interrupt(f), { concurrency: 'unbounded', discard: true });
  }));
}
```

```
(a) 100000 parked async frames          : 69 ms to create, 45.9 MiB, 481 B each
(b) 100000 frames + AbortController+lstnr: 158 ms to create, 117.7 MiB, 1234 B each
(c) 100000 forked Effect fibers         : 986 ms to create, 329.1 MiB, 3450 B each
```

```js
// m14.mjs — run with node --expose-gc. Rows 3 and 4: §5's fiber record over a native frame.
const N = Number(process.argv[2] ?? 100_000);
const mib = (b) => (b / 1048576).toFixed(1);
const heap = () => { global.gc(); global.gc(); return process.memoryUsage().heapUsed; };
const never = new Promise(() => {});

class Fiber {              // exactly §1's list of missing fields
  outcome = null;          // Exit slot
  observers = null;        // lazily allocated, as Effect's _children is
  parent = null;
  finalizers = null;
  children = null;
  ctl = null;              // AbortController
  constructor(parent) { this.parent = parent; if (parent) (parent.children ??= new Set()).add(this); }
  addObserver(f) { (this.observers ??= []).push(f); }
  onExit(e) { this.outcome = e; if (this.observers) for (const o of this.observers) o(e); this.parent?.children?.delete(this); }
}

for (const lazy of [true, false]) {
  const base = heap(); const t = process.hrtime.bigint();
  const root = new Fiber(null);
  const hold = [];
  for (let i = 0; i < N; i++) {
    const f = new Fiber(root);
    if (!lazy) { f.ctl = new AbortController(); f.observers = []; f.finalizers = []; }
    hold.push([f, (async () => { try { await never; } finally { f.onExit('ok'); } })()]);
  }
  const ms = Number(process.hrtime.bigint() - t) / 1e6;
  const d = heap() - base;
  console.log(`${lazy ? 'lazy fields (null until used)' : 'eager: +AbortController+arrays'}: ${ms.toFixed(0)} ms, ${mib(d)} MiB, ${(d/N).toFixed(0)} B per fiber`);
  hold.length = 0; root.children = null;
}
```

```
lazy fields (null until used): 85 ms, 66.0 MiB, 692 B per fiber
eager: +AbortController+arrays: 191 ms, 75.1 MiB, 788 B per fiber
```

| 100,000 parked units | create | resident each |
|---|---|---|
| bare `async` frame parked on a promise | 71 ms (0.71 µs) | **481 B** |
| + one `AbortController` + one `abort` listener | 169 ms (1.69 µs) | **1234 B** |
| + §5.2's record instead, lazy fields | 89 ms (0.89 µs) | **692 B** |
| + §5.2's record, eager `AbortController` and arrays | 138 ms (1.38 µs) | **788 B** |
| `Effect.fork(Effect.never)` | 1032 ms (10.3 µs) | **3450 B** |

The output blocks above are single runs; the `create` column is the median of three, which is why
the milliseconds differ by up to a third. The `resident each` column is stable to the byte across
runs.

**The record §1's conclusion asks for costs 1.4–1.6× a bare async frame and about a fifth of an
Effect fiber.** The expensive part is not the outcome slot, the observer list or the parent link —
those are six words. It is the `AbortController` and its listener, which more than doubles the
bare frame on their own (row 2). That is the same finding as §3.5 from the other side, and it is
why §5.2 puts the signal on the *scope* and not on the fiber.

---

## 4. The other six systems

Each entry answers the same four questions — structured concurrency, cancellation, finalisers,
bounded concurrency — plus the one that matters most here: **what it refuses, and why.** Sources
are the shipping source and the authors' own writing, fetched 2026-09-15.

### 4.1 ZIO 2

`FiberRuntime.scala:28-67` (`zio/zio`, `series/2.x`) is the record, and it is Effect's with the
names changed: `_fiberRefs`, `_blockingOn`, `_asyncContWith`, `inbox: ConcurrentLinkedQueue`,
`_children: JavaSet`, `observers: List[Exit => Unit]`, `_stack`, `_isInterrupted`,
`@volatile _exitValue`. Finalisers are *not* a fiber field — they are ordinary continuations on
`_stack`, which is the design §5.2 rejects.

**Supervision is the default and the escape hatch is named.** zio.dev/reference/fiber: *"ZIO uses
a structured concurrency model where fiber lifetimes are cleanly nested… If we use the ordinary
`ZIO#fork` operation, the child fiber will be automatically supervised by the parent fiber."*
`forkDaemon` opts out: *"As these fibers have no parent, they are not supervised."*

**Fairness is two counters and the values are published** (`FiberRuntime.scala:1607-1609`):

```scala
private final val MaxForksBeforeYield      = 128
private final val MaxOperationsBeforeYield = 1024 * 10
private final val MaxDepthBeforeTrampoline = 300
```

gated on `RuntimeFlag.CooperativeYielding`, which is in `RuntimeFlags.default`. The flag's own
doc: *"Disabling this flag is highly discouraged."* A fork counter alongside an op counter is
something neither Effect nor any JavaScript runtime has, and it exists because a fiber that only
forks never executes 10,240 ops.

**Finalisers run uninterruptibly, both ends.** zio.dev/reference/interruption: *"`acquire` runs
uninterruptibly. An interrupt cannot land between 'the resource was opened' and 'the release
finalizer was registered'"* and *"`release` runs uninterruptibly. It runs whether `use` succeeded,
failed, died, or was interrupted, and it cannot itself be interrupted away."* `Scope` closes
finalisers in reverse registration order.

**Parallelism defaults to unbounded** (`FiberRef.scala:620`: `FiberRef.unsafe.make[Option[Int]](None)`),
with `ZIO.withParallelism(n)` to bound it.

**On Scala.js**, `RuntimePlatformSpecific.scala` sets `defaultExecutor` to `MacrotaskExecutor` and
makes the blocking executor the same object; `hasGreenThreads = false`. zio.dev/overview/platforms:
*"Because of the single threaded execution model of Javascript, blocking operations are not
supported on Scala.js."* The op counter is in `core/shared`, so it is live on JS, and every yield
becomes a macrotask round trip. **No verified benchmark number found** for ZIO on Scala.js.

### 4.2 Cats Effect 3

`IOFiber.scala:68-107` carries what ZIO does not: an explicit `finalizers: ArrayStack[IO[Unit]]`
on the fiber, `callbacks: CallbackStack`, `outcome`, `masks: Int`, `canceled: Boolean`, and
`conts: ByteStack.T` + `objectState: ArrayStack[AnyRef]` — a struct-of-arrays continuation stack,
which is the layout beni's own compiler architecture prefers. **It has no child set**, because
`start` is deliberately unstructured.

**`start` leaks by design; structure is opt-in.** `Supervisor.scala:28-45`: *"Whereas
`GenSpawn.background` links the lifecycle of the spawned fiber to the calling fiber, starting a
fiber via a `Supervisor` links the lifecycle of the spawned fiber to the supervisor fiber."* The
docs list `start` as *"start and forget, no lifecycle management for the spawned fiber."* This is
the opposite default from ZIO and from Trio, and it is the position §5.3's spawn row rejects.

**Two thresholds, with an enforced relationship** (`IORuntimeConfig.scala:33-41`):

```scala
require((autoYieldThreshold % cancelationCheckThreshold) == 0, …)
```

Defaults are **512** (cancellation poll) and **1024** (auto-cede), *identical on JVM and JS*. The
run loop (`IOFiber.scala:210-243`) decrements both counters and reschedules the fiber at the
auto-cede boundary.

**Finalisation is made uninterruptible structurally** (`IOFiber.scala:1132-1147`): on entering
cancellation the fiber does `masks += 1` and never pops it, and `shouldFinalize()` is
`canceled && masks == 0`, so the whole `finalizers` stack drains LIFO with cancellation permanently
suppressed.

**`parTraverseN(n)` takes `n` as a required argument** — `require(n >= 1, …)`
(`GenConcurrent.scala:145`). Plain `parTraverse` is unbounded.

**Its JavaScript scheduler is the closest thing in the survey to what beni needs.**
`BatchingMacrotaskExecutor.scala`, verbatim: *"An `ExecutionContext` that improves throughput by
providing a method to `schedule` fibers to execute in batches, instead of one task per event loop
iteration."* `batchSize = 64`; within a batch the continuation is a `queueMicrotask`, and every
64 fibers it re-dispatches through `MacrotaskExecutor`. On JS, `IO.blocking` and `IO.interruptible`
are *no-ops* (`IOCompanionPlatform.scala:26`). The scheduler docs state the primitive plainly:
*"The primary mechanism which needs to be provided for `IO` to successfully implement fibers is
often referred to as a yield. In JavaScript terms, this means the ability to submit a callback to
the event loop which will be invoked at some point in the future."*

**Benchmarks**, attributed: Daniel Spiewak, *Understanding Comparative Benchmarks*
(gist `f4cfc08e0827088f17032e0e9099d292`, ~July 2021, against **ZIO 2.0.0-M1** — stale for current
ZIO 2, and no machine spec given): *"about 7.86 nanoseconds per `flatMap` on Cats Effect, and
about 8.31 nanoseconds per `flatMap` on ZIO"*; *"Cats Effect `Fiber` is considerably smaller in
terms of memory footprint than ZIO's `Fiber` (roughly 3x smaller)"*. His own caveat is worth
carrying: *"all benchmarks in this post are slightly and systematically biased in favor of ZIO"*.
**No verified number found** for either runtime on Scala.js.

### 4.3 Trio

**The nursery is the only way to spawn, and `start_soon` returns nothing** —
`_core/_run.py:1340`, `def start_soon(…) -> None`. Its docstring: *"Note that this is not an async
function and you don't use await when calling it."* The reason is upstream of the API:
`docs/source/design.rst`, *"The only form of concurrency is the task… No callbacks, no implicit
concurrency, no futures/deferreds/promises/other APIs that involve callbacks."* With no `Future`
type there is nothing for `start_soon` to return. (**Unconfirmed**: no sentence in Trio's own
material says "`start_soon` returns nothing *because*"; the chain above is inference from the
design principles.)

**The block cannot exit first.** reference-core: *"the block does not exit until all tasks have
completed… the de-indentation at the end of the `async with` automatically 'joins' all of the
tasks."* Smith: *"No, really, nurseries always wait for the tasks inside to exit… We never
terminate a task without giving it a chance to run cleanup handlers."*

**Cancellation is level-triggered, and that is the whole finaliser story.** reference-core,
`.. _blocking-cleanup-example:`, on a `finally` that itself awaits: *"if we were using asyncio or
another library with 'edge-triggered' cancellation, we'd be in trouble: since our timeout already
fired, it wouldn't fire again, and at this point our application would lock up forever. But in
Trio, this doesn't happen: the `await conn.send_goodbye_msg()` call is still inside the cancelled
block, so it will also raise `Cancelled`."* The escape is
`trio.move_on_after(CLEANUP_TIMEOUT, shield=True)` — **a bounded shield** — and the doc's comment
on it is *"Intentional foot-shooting is no problem (or at least – it's not Trio's problem)."*
`Cancelled` derives from `BaseException` *"so that it won't be caught by catch-all `except
Exception:` blocks"* — §3.6 case (iii) prevented structurally.

**Checkpoints are narrower than "every await".** reference-core: *"Regular (synchronous) functions
never contain any checkpoints… If you call an async function provided by Trio … it always acts as
a checkpoint… Third-party async functions can act as checkpoints; if you see `await <something>`
… then that might be a checkpoint."*

**Bounded concurrency is `CapacityLimiter`**, and the default thread limit is candid
(`_threads.py:54`): `# I pulled this number out of the air; it isn't based on anything.` /
`DEFAULT_LIMIT = 40`. **There is no `gather`** and issue #2188 closed without adding one; the
recurring complaint in that thread is worth recording against §5.3's join row — *"the return
values of nursery-spawned tasks are being discarded, meaning they have to use alternate methods to
pass back values"* (TeamSpen210), and *"The decision to avoid gather and/or Futures is forcing me
to think in continuations again"* (phxnsharp).

**The refusal**, Smith, *Go statement considered harmful*: *"Go statements break abstraction…
whenever you call a function, it might or might not spawn some background task."* / *"Go
statements break automatic resource cleanup."* / *"Go statements break error handling."* The
prescription: *"Build that new construct into our concurrency framework as a primitive, **and
don't include any form of `go` statement**."* **No verified benchmark number found**; Trio
publishes none and says so: *"if necessary we are willing to accept some slowdowns in the service
of usability and reliability."*

### 4.4 kotlinx.coroutines

**The same tree, with `Job` as the record.** coroutines-basics: *"A parent coroutine waits for its
children to complete before it finishes. If the parent coroutine fails or gets canceled, all its
child coroutines are recursively canceled too."* exception-handling: *"If a coroutine encounters an
exception other than `CancellationException`, it cancels its parent with that exception. **This
behaviour cannot be overridden** and is used to provide stable coroutines hierarchies."*
`supervisorScope` is the one-directional variant.

**Cancellation is cooperative and the docs lead with the failure.** cancellation-and-timeouts
@1.8.1: *"However, if a coroutine is working in a computation and does not check for cancellation,
then it cannot be cancelled."* Master adds the sharper form: *"If a coroutine doesn't suspend,
other coroutines can't run on the same thread until it completes… If a coroutine doesn't suspend
for a long time, it also doesn't stop when it's canceled."* And the swallowing hazard is
documented rather than prevented: *"The same problem can be observed by catching a
`CancellationException` and not rethrowing it… like when using the `runCatching` function, which
does not rethrow `CancellationException`."*

**`finally` works; a *suspending* `finally` does not.** *"Any attempt to use a suspending function
in the `finally` block of the previous example causes `CancellationException`, because the
coroutine running this code is cancelled… in the rare case when you need to suspend in a cancelled
coroutine you can wrap the corresponding code in `withContext(NonCancellable) {...}`."* Unlike
Trio's shield, `NonCancellable` carries **no timeout**, and `join` waits for it. (**Unconfirmed**:
no Kotlin doc acknowledges that deadlock.)

**Unmarked call sites, on purpose, with the IDE as the affordance.** KEEP-0164: *"no special
keywords (like `async` and `await` in C#, JS and other languages) to support futures"* /
*"Syntactically, a suspension point is an invocation of suspending function."* KEEP-0443 treats
the marker as tooling: *"Similar to how all call-sites of `suspend` functions have a gutter icon
in IDE, we should add a gutter icon for all call-sites of functions with context parameters."*
**This is P2 §2's precedent, and it is exactly as strong as P2 claims.**

**Bounded concurrency is `Semaphore`, and `limitedParallelism` is a trap.**
`CoroutineDispatcher.kt`: *"**It is not a mutex!** Pitfall: `limitedParallelism` limits how many
threads can execute some code in parallel, but does not limit how many coroutines execute
concurrently! … Use a `kotlinx.coroutines.sync.Mutex` or a `kotlinx.coroutines.sync.Semaphore` for
limiting concurrency."*

**On Kotlin/JS the scheduler is a 16-message batch**, `internal/JSDispatcher.kt`:

```kotlin
internal abstract class MessageQueue : MutableList<Runnable> by ArrayDeque() {
    val yieldEvery = 16 // yield to JS macrotask event loop after this many processed messages
```

with the KDoc stating the two-tier design outright: *"`schedule` is used to schedule the initial
processing of the message queue. JS engine-specific microtask mechanism is used… `reschedule` is
used to schedule processing of the queue after yield to the JS event loop. JS engine-specific
macrotask mechanism is used **not to starve animations and non-coroutines macrotasks**."* Browser
`reschedule` is `window.postMessage` — chosen over `setTimeout` to dodge clamping. `Dispatchers.Main`
is a wrapper over `Default`; `Dispatchers.IO` does not exist on JS.

**Benchmarks:** the only official, attributable numbers are a *Flow* benchmark on the JVM
(`benchmarks/…/flow/scrabble/README.md`, Core i9-9880H, JDK 1.8.0_172): `FlowPlaysScrabbleOpt.play`
13.958 ± 0.278 ms/op vs `RxJava2PlaysScrabbleOpt.play` 23.653 ± 0.379 ms/op. They say nothing
about spawn cost, scheduling, or JS. The docs' *"roughly 500 MB"* for 50,000 coroutines is a
documentation claim with no methodology, not a measurement. **No verified number found** for
Kotlin/JS coroutine scheduling.

### 4.5 Swift

**The scope rule is the language's, not a library's.** SE-0304: *"A child task does not persist
beyond the scope in which it was created. By the time the scope exits, the child task must either
have completed, or it will be implicitly awaited. When the scope exits via a thrown error, the
child task will be implicitly cancelled before it is awaited."* SE-0317 states the cost in the
same breath: *"any structured invocation will take as much time to return as the longest of its
child tasks takes to complete"* and *"avoiding this can only be done by creating non-child tasks,
e.g. by using `Task.detached`."*

**Cancellation is a flag plus an immediate callback.** SE-0304: *"The effect of cancellation
within the cancelled task is fully cooperative and synchronous. That is, **cancellation has no
effect at all unless something checks for cancellation**… As a result, cancellation introduces no
additional control-flow paths within asynchronous functions."* Two immediate effects: *"A flag is
set in the task which marks it as having been cancelled; once this flag is set, it is never
cleared"* and *"Any cancellation handlers which have been registered on the task are immediately
run."* The stdlib doc for `withTaskCancellationHandler` is blunter than the proposal: *"**If
cancellation occurs while the operation is running, the cancellation handler executes concurrently
with the operation.**"* and *"The cancellation handler may be invoked while holding internal locks
associated with the task."* `Task.cancel()`: *"a function that doesn't specifically check for
cancellation will run to completion normally, even if the task it is running on is canceled."*

**Swift is the survey's strongest statement of the marker argument**, and it is the direct
counter-evidence to P2 §9.1. SE-0296: *"**Marking potential suspension points is particularly
important because suspensions interrupt atomicity.**… A classic but somewhat hackneyed example
where this atomicity matters is modeling a bank: if a deposit is credited to one account, but the
operation suspends before processing a matched withdrawal, it creates a window where those funds
can be double-spent. A more germane example for many Swift programmers is a UI thread… Requiring
that all potential suspension points are marked allows programmers to safely assume that places
without potential suspension points will behave atomically."* That is P2 §9.1's accepted risk,
argued the other way by the language that shipped the other choice. **Kotlin and Swift are a
controlled experiment on exactly this question and they reached opposite verdicts** — §5.4.

**No auto-yield.** `Task.yield()` is manual and the stdlib warns *"If this task is the
highest-priority task in the system, the executor immediately resumes execution of the same task.
As such, this method isn't necessarily a way to avoid resource starvation."* SE-0296 accepts the
consequence: *"long computations can still block threads… the thread cannot interleave code while
these computations are running."* SE-0392's executor contract is no-preemption in as many words:
jobs *"must run to completion before the other one is allowed to run."* **No verified benchmark
number found** on swift.org or developer.apple.com.

### 4.6 `golang.org/x/sync/errgroup`

**The whole runtime is five fields and 151 lines** (`errgroup.go`, `5071ed6a9f16`, 2026-05-30):

```go
type Group struct {
	cancel  func(error)
	wg      sync.WaitGroup
	sem     chan token
	errOnce sync.Once
	err     error
}
```

`Wait` is `g.wg.Wait()` then `g.cancel(g.err)` then `return g.err`; `SetLimit(n)` is
`g.sem = make(chan token, n)` and `Go` sends a token before spawning. The doc: *"The derived
Context is canceled the first time a function passed to Go returns a non-nil error or the first
time Wait returns, whichever occurs first."* / *"It blocks until the new goroutine can be added
without the number of goroutines in the group exceeding the configured limit."*

**It is a nursery with no enforcement and no finalisers.** Nothing in the file touches a running
goroutine; `context.CancelFunc` *"does not wait for the work to stop"*. A child that ignores
`ctx.Done()` runs forever and `Wait` blocks forever. A bare `go f()` inside `g.Go(...)` is legal
and invisible. Panics are deliberately not propagated, and the in-source rationale is a Go-team
primary source on exactly the question §5.3's scope row asks:

```go
// It is tempting to propagate panics from f() up to the goroutine that calls Wait, but
// it creates more problems than it solves:
// - it delays panics arbitrarily, making bugs harder to detect;
// - it turns f's panic stack into a mere value, hiding it from crash-monitoring tools;
// - it risks deadlocks that hide the panic entirely ...
```

**Why goroutines cannot be killed** — Ian Lance Taylor, golang/go#25664: *"Historically the POSIX
threads interface defined a `pthread_cancel` function, and it's been a source of great complexity
and bugs ever since."* Dave Cheney (contributor, not core team), golang/go#32610, states the
design problem in the terms §5.3 needs: *"If the process, thread, or goroutine stops dead in its
tracks -- what happens to the resource's it owned? Is the stack unwound? Are defer blocks
executed? If so, then the goroutine could continue to live indefinitely as defer blocks run. If
defer blocks are not run then that presents the situation where any goroutine can corrupt any
invariant of your system by taking a lock, then being shot dead on the spot."* **No verified
benchmark number found** in the module or on pkg.go.dev.

### 4.7 What the six agree on, and the one thing that is specific to JavaScript

**Unanimous, six for six.** Cancellation is *cooperative*: a flag or an exception delivered at a
suspension point, never a forced unwind. Nobody kills a stack. The reason is the same everywhere
and Cheney states it best: a forcibly-unwound task either runs unbounded cleanup or corrupts
invariants. **§5 must not propose interrupting a synchronous loop, and §3.6 already showed the
platform would not allow it.**

**Five of six enforce scope; CE3's `start` is the outlier and is documented as such.** ZIO
supervises by default with a named opt-out, Trio makes the nursery the only spawn form, Swift puts
the rule in the compiler, Kotlin makes it a `CoroutineScope` receiver; errgroup asks nicely and Go
declines to enforce it. Every one that enforces it pays the same price, stated most precisely by
SE-0317: *"any structured invocation will take as much time to return as the longest of its child
tasks takes to complete."*

**Finaliser-under-cancellation is where they differ, and the difference is a timeout.**

| | cleanup that itself suspends |
|---|---|
| Trio | fails immediately (level-triggered); shield is `move_on_after(CLEANUP_TIMEOUT, shield=True)` — **bounded** |
| Kotlin | fails immediately; `withContext(NonCancellable)` — **unbounded**, and `join` waits |
| ZIO / CE3 | release runs uninterruptibly by construction — **unbounded** |
| Swift | `defer` is not a suspension point at all; cleanup that awaits is ordinary code in a cancelled task |
| errgroup | none |
| native `async` (§3.6 ii) | the `finally` runs and **delays cancellation by its own duration**, unbounded, unshielded |

**And then the one that is not about types at all.** Three JavaScript-targeting fiber runtimes,
built independently, converged on the same two-tier scheduler: run continuations in microtasks for
throughput, escape to a macrotask every *N* to give the event loop back.

| | inner (microtask) | outer (macrotask) | outer every |
|---|---|---|---|
| Effect 3.22.2, `MixedScheduler` | `Promise.resolve().then` | `setTimeout(…, 0)` | **2048 nested drains** |
| Cats Effect 3, `BatchingMacrotaskExecutor` | `queueMicrotask` | `MacrotaskExecutor` | **64 fibers** |
| kotlinx.coroutines, `MessageQueue` | microtask (`process.nextTick` / `Promise`) | `setTimeout(0)` / `window.postMessage` | **16 messages** |

Kotlin's KDoc gives the reason in the source: *"not to starve animations and non-coroutines
macrotasks."* Effect's 2048 is two to three orders of magnitude larger than the other two, and
§2.3 measured what that buys: a 361 ms frozen page on work the other two would have interrupted
after 16 or 64 continuations. **This table, not the type system, is the answer to "does the event
loop suffice as the scheduler" — §5.5.**

---

## 5. The primitives

### 5.1 What is being judged, and why it is judged twice over

§1's conclusion — *"None of them changes the shape of a `Task`"* — was written against
`fast-compiler.md` §3.1, which has since been contested by two proposals. Everything below is
therefore judged against **both** shapes:

- **Shape T**, `Task e a` as a value interpreted by a platform. This is `fast-compiler.md` §3.1,
  `boundary.md` §4(b), and — with a thunk `() -> a ! e` replacing the `Task` constructor and a CPS
  lowering replacing the interpreter — P1 §6. The property that matters for §5 is **the runtime
  owns the resume callback**, exactly as `_Scheduler_binding` and `OP_ASYNC` do.
- **Shape N**, a plain thunk `() -> a` under native `async`/`await`. This is P2 §2, §6, §7.1.
  The property that matters is **the engine owns the resume callback and will not give it to
  you**: `PerformPromiseThen` (§3.1, step 7) hands the reactions to the promise, and the only
  handle you get back is the promise.

Everything in §5 follows from that one difference. The type column is nearly identical between
the two shapes; the runtime column is not.

**The test, restated for a runtime.** A primitive is admitted when (a) it can be given a beni type
such that well-typed code cannot crash, **and** (b) the runtime's obligations are ones a
JavaScript runtime can actually discharge. (b) is not a formality: §3.6 case (i) is a primitive
that types perfectly and silently deletes a finaliser.

### 5.2 The fiber record beni needs

§1's conclusion names five missing things. Here they are as fields, with the two additions §2 and
§3 argue for and one deliberate omission.

| field | why | evidence |
|---|---|---|
| `outcome : ?Exit a` | §1.4: `_Scheduler_spawn` has no outcome slot, so nothing can learn what a spawned task produced | Effect `_exitValue`, ZIO `@volatile _exitValue`, CE3 `outcome` |
| `observers : ?[]fn(Exit a)` | join, race, scope-exit and `Queue.take` are all one mechanism | Effect `_observers`, ZIO `observers`, CE3 `callbacks` |
| `parent : ?*Fiber` | cancellation must reach descendants; §1.4's record has no parent and no child set | Effect keeps it in `internal/fiberScope.js`'s `Local`, not on the fiber |
| `children : ?Set(*Fiber)` | the scope rule: the block cannot exit until these are empty | ZIO `_children`; **CE3 has none and `start` leaks as a result** (§4.2) |
| `finalizers : ?[]fn(Exit a)` | §1.4: *"nothing runs on the way out. A killed process leaks whatever it held"* | CE3 puts it on the fiber; ZIO and Effect put it on a `Scope` |
| `interruptor : ?fn(Exit a)` | **§2.4's `_asyncInterruptor`** — the resume callback, so cancelling does not wait for the primitive | Effect `_asyncInterruptor`, Swift `withTaskCancellationHandler` |
| `opCount : u32` | §1.3's fairness — but see §5.5, it is the *smaller* half of the answer | Effect 2048, ZIO 10240, CE3 512/1024 |

**Not on the fiber: the `AbortController`.** §3.8 row 2 is decisive — an `AbortController` plus
one listener costs 753 B and 0.98 µs *on its own*, more than doubling a bare frame, and §3.5 says
`AbortSignal.any` costs 384 ns per derivation. Put one signal on the **scope**, let fibers read
`scope.cancelled` through the parent chain, and mint a real `AbortController` only at the leaf
where a platform primitive demands one. With that, §3.8's measured record is **692 B and 0.89 µs
per fiber**, 1.4× a bare parked `async` frame and 0.2× an Effect fiber.

**`_stack` is deliberately absent.** Under shape N there is no continuation stack to keep: V8's
async frame *is* the stack, which is the whole of P2 §7.1's saving. Under shape T it comes back,
and CE3's split `conts: ByteStack` + `objectState: ArrayStack` is the layout to copy.

### 5.3 Each primitive, typed and costed

All types are written in P2's notation (no effect annotations); under P1 each thunk `() -> a`
reads `() -> a ! e` and each combinator is effect-polymorphic in `e`. **Neither shape changes the
*shape* of any signature below** — the `! e` rewriting is uniform — which is the one place §1's
conclusion survives intact. It is not the same as the two *documents* agreeing on the list: §5.6
names the three primitives where they do not.

| # | primitive | beni type | typeable? |
|---|---|---|---|
| 1 | spawn / join | `Task.spawn : (() -> a) -> Fiber a`<br>`Fiber.join : Fiber a -> Result Cancelled a` | yes, both |
| 2 | scope | `Task.scope : (Scope -> a) -> a`<br>`Scope.spawn : Scope, (() -> b) -> Fiber b` | **yes, but escape is not preventable** |
| 3 | cancel | `Fiber.cancel : Fiber a -> ()` | yes, both |
| 4 | bracket | `Task.bracket : (() -> r), sync (r -> ()), (r -> a) -> a` | yes — **and `sync` is load-bearing** |
| 5 | bounded parallel | `Task.parAll : Int, List (() -> a) -> List a` | yes, both |
| 6 | race | `Task.race : List (() -> a) -> a` | yes, both |
| 7 | timeout | `Task.timeout : Int, (() -> a) -> Maybe a` | yes, both |
| 8 | retry | `Task.retry : Int, (() -> Result x a) -> Result x a` | yes — **only because the argument is a thunk** |
| 9 | semaphore | `Semaphore.with : Semaphore, (() -> a) -> a` | yes, both |
| 10 | queue | `Queue.take : Queue a -> a`, `Queue.put : Queue a, a -> ()` | yes, both |
| 11 | rate limiter | `RateLimiter.with : RateLimiter, (() -> a) -> a` | yes, both |

**1. spawn / join.** *Runtime must promise:* the outcome slot is written exactly once; observers
fire exactly once; a join *after* exit returns immediately rather than parking forever (the
lost-wakeup bug); a join of a cancelled fiber returns a value, not a hang. Elm's
`Process.spawn : Task x a -> Task y Id` is *well-typed and useless* — the type discards `a`, which
is a modelling failure, not a type-system failure, and it is the same failure Trio's users report
about `start_soon` (§4.3: *"the return values of nursery-spawned tasks are being discarded"*).
**T and N are equal here**, and N is slightly cheaper: `Fiber a` is §5.2's record wrapping a
promise, and `join` is an `await`. **One hazard specific to N:** a spawned thunk whose promise
rejects with no joiner is an *unhandled rejection*, which on Node terminates the process by
default. `Task.spawn` must attach a catch at spawn time and route the failure into `outcome`. Under
T the outcome slot is the only sink and there is no host-level rejection to leak.

**2. scope.** *Runtime must promise:* the block does not return until `children` is empty; a child
failure cancels its siblings *and* the scope waits for them before propagating; a `Scope` used
after close is a diagnostic, not a silent leak. **Escape cannot be typed away under either
shape.** Preventing a `Scope` value from outliving its block needs region or rank-2 typing;
`checker.md` §6.3 says *"nothing else may be added to `Kind`"*, and P2 §4.1's whole argument is
that the flags ride *alongside* unification rather than inside it. Effekt's answer is
second-class blocks (P2 §9.3 already cites `14/effekt` §1 on this), which costs first-class
thunks — the thing every other primitive here is built out of. **Take Trio's position instead**:
the `Scope` is an ordinary value, and the guarantee is the runtime's, not the type's. Smith's
defence is the one to adopt — *"Since nursery objects have to be passed around explicitly, you can
immediately identify which functions violate normal flow control by looking at their call
sites."* Cost: T and N are equal; the expense is the implicit join, and SE-0317 priced it — *"any
structured invocation will take as much time to return as the longest of its child tasks takes to
complete."*

**3. cancel.** *Runtime must promise*, four things: (i) an interrupt delivered to a **parked**
fiber resumes it rather than waiting on the primitive; (ii) finalisers run at cancel time, in LIFO
order; (iii) the abandoned primitive's later resume is dropped (one-shot); (iv) descendants are
signalled before the parent unwinds. **This is the entire P1-vs-P2 delta, and it is the reason §5
exists.**

- Under **T** all four are free, because the runtime holds the resume callback. Effect does (i)
  and (iii) in four lines (§2.4) and (iv) in ten (`sendInterruptSignalToAllChildren`).
- Under **N**, (ii) and (iv) are fine and (i) and (iii) are not. §2.4 measured the failure: an
  uncooperative primitive makes the `finally` run at 301 ms for a cancel issued at 51 ms. §3.6(i)
  is worse: a primitive that *never* settles deletes the finaliser entirely, with the frame
  collected and nothing reported. P2 §6's *"Cancelling rejects the pending `await`"* is only true
  when the primitive both receives the signal and honours it — that is, for `fetch` and `setTimeout`
  and nothing else guaranteed.
- **The gap is buyable.** §3.7: emit every suspension point as `await race(e, scope.cancelled)` and
  N gets T's semantics exactly, including the dropped result. The price is **~1 µs per suspension
  point, roughly 10×** — §3.7's three rounds span 831–1240 ns, which is as precise as this
  quantity gets. That is affordable at an I/O boundary and not affordable on every `await`
  inside a bit-polymorphic `List.map` (P2 §7.3), so it wants to be a property of the *primitive*,
  not of the lowering: platform `foreign suspends` declarations get the race, ordinary
  bit-polymorphic code does not. That is a fourth bit, or a platform convention, and P2 has
  neither.
- **Nobody interrupts a synchronous loop**, in any of the eight systems here (§3.6, §4.7). Do not
  propose it. A polled `scope.cancelled` check costs 3 ns (§3.5) and is what `Task.yield` should
  compile to.

**4. bracket.** *Runtime must promise:* acquire runs uninterruptibly; release runs uninterruptibly,
on every exit path, in LIFO order. Effect buys the first with `core.uninterruptible` around the
acquire (§2.5), ZIO and CE3 state it as a documented guarantee (§4.1, §4.2), CE3 enforces the
second by `masks += 1` that is never popped.

Under **T** this is a push onto `finalizers` and a flag. Under **N** it is `try`/`finally`, which
spec §3.1 step 5 makes correct **for the case where the promise rejects** — and which §3.6 shows
is wrong three other ways. Two of those three beni can close, because beni controls what it emits:

- *A `finally` that returns discards the cancellation* (§3.6 iii). beni has no `return` and no
  `finally` in the surface language; `bracket`'s release is a thunk the runtime calls. Closed by
  construction, which is more than Kotlin manages (§4.4).
- *A release that suspends delays cancellation without bound* (§3.6 ii). The fix is in the type:
  **`sync (r -> ())`**. A release that cannot suspend cannot delay a cancellation, cannot
  deadlock, and needs no shield. This is the single strongest argument for P2 §3.2's `sync` and
  P2 does not make it — but note that P2 spells `sync` as a *declaration* modifier
  (`Decl := 'sync'? lower_ident …`), and a platform signature demanding a non-suspending argument
  needs it in a *type* position. P2 §3.2 is the sentence that refuses it — *"it is not a different
  type, and a `sync` function unifies with an ordinary one"* — and not P2 §3.1, whose sub-decision
  is about the `suspends`/`impure` bits on `foreign` and which invites the opposite (*"A reviewer
  who wants them in the type should say so"*). So this row is a live amendment to P2, not a use of
  it as written — and by §3.1's own invitation, the kind of amendment a reviewer is asked for. Where a suspending release is genuinely
  required, take Trio's bounded shield (`move_on_after(CLEANUP_TIMEOUT, shield=True)`) and not
  Kotlin's unbounded `withContext(NonCancellable)`.
- *A never-settling primitive deletes the finaliser* (§3.6 i) is **not** closeable under N without
  §3.7's race. It is the residue.

**5. bounded parallel.** *Runtime must promise:* at most `n` in flight; a failure cancels the
remainder and does not return before they have finished unwinding; results in argument order.
**The `Int` is mandatory, not defaulted** — and the argument for that is *not* that Effect
defaults to unbounded, because it does not. §2.6: `Effect.forEach` with no `concurrency` option is
*sequential*; `"unbounded"` is the `currentConcurrency` FiberRef's value and only `'inherit'`
reads it. So §3.4's 901 MiB is the cost of code that asked for `{ concurrency: 'unbounded' }`, not
the cost of forgetting an argument. The argument that survives is the weaker and still sufficient
one: **`'unbounded'` is one word away from a number, and 901 MiB is one word away from 78.6 KiB
for the same 200,000 operations.** Making the bound a positional `Int` removes the word. ZIO's
`None` (§4.1) and CE3's `require(n >= 1, …)` are the two ends of that choice, and CE3 has it
right.

**This is the one row where N is strictly better than T.** §3.4: a bounded worker pool over
200,000 tasks beats `Promise.all` on *both* axes, 22 ms against 92 ms and 78.6 KiB against 901 MiB,
because the giant promise array is itself the cost. Under N, `parAll` is `n` async worker loops
over a shared index — sixteen lines, no fiber runtime. P2 §6's *"Over promises these are
`Promise.all`, a semaphore, `Promise.race`, and `try`/`finally` — not a fiber runtime"* is right
about this primitive and wrong about the next one.

**6. race.** *Runtime must promise:* exactly one winner, and **every loser cancelled with its
finalisers run before `race` returns.** Effect does it with observers on both fibers and a
`raceIndicator` (`internal/fiberRuntime.js:2049-2056`). `Promise.race` does none of it: it
forgets the losers, which under §3.6(i) means a loser holding a socket holds it until the process
dies and no `finally` ever runs. **So `Task.race` under N must be built on `Task.scope`, not on
`Promise.race`** — and therefore inherits row 3's problem: a loser parked on an uncooperative
primitive is not actually cancelled, only abandoned. This is the primitive where P2 §6's list is
misleading.

**7. timeout.** A race against a sleep, so it inherits row 6 exactly. One extra obligation the
survey supplies: Kotlin documents the case where the timeout fires *after* the value is produced
but before it is bound — *"The timeout event in `withTimeout` is asynchronous with respect to the
code running in its block and may happen at any time, even right before the return… If you run the
above code, you'll see that it does not always print zero"* — which loses a resource. The
`Maybe a` result makes the outcome visible but does not fix it; the fix is that anything
acquiring a resource inside a `timeout` must acquire it through `bracket`. Note also that a
`timeout` around a *synchronous* loop does nothing at all under either shape (§3.6 d, e).

**8. retry.** *Runtime must promise:* the cancellation signal survives the retry loop, so a
cancelled retry stops rather than looping. Free under both shapes — **and free only because the
argument is a thunk.** Smith made exactly this argument for Trio's `start_soon`: *"`start_soon`
has to take a function, not a coroutine object or a `Future`. (You can call a function multiple
times, but there's no way to restart a coroutine object or a `Future`.)"* A `Promise` is a started
computation and cannot be retried. **This is an argument that P2's `() -> a` deferral is right and
that no beni API may ever hand out a started promise in its place** — and it applies identically
to P1's `() -> a ! e`. The two proposals agree here and the agreement is load-bearing.

**9. semaphore.** *Runtime must promise:* FIFO among waiters (Kotlin states it: *"Semaphore is
fair and maintains a FIFO order of acquirers"*); the permit is released on cancellation as well as
on completion — i.e. `acquire`/`release` is itself a `bracket`; and the *acquire* is cancellable
with Kotlin's prompt-cancellation rule, *"even if this function is ready to return the result, but
was cancelled while suspended, `CancellationException` will be thrown."* A waiter list is a list of
resume callbacks; under N a resume callback is a promise resolver, which is fine. Equal under both.

**10. queue.** *Runtime must promise:* a parked `take` is a cancellable park, and a cancelled
taker is **removed from the waiter list** — otherwise the queue leaks a dead waiter per
cancellation and eventually hands a value to nobody. This is where §5.2's observer list stops
being a convenience: the cancellation path has to reach into the queue's waiter list, which means
`Fiber.finalizers` has to exist before `Queue` can be written correctly. Equal under both shapes;
under N the parked taker is an `await` on a deferred promise the queue holds.

**11. rate limiter.** The only primitive whose resource is a *timer*. It must be cancellable
(`clearTimeout` from a finaliser — `_Process_sleep` already returns exactly that canceller, §1.1)
and it must not be the thing that keeps the process alive after everything else is cancelled.
Equal under both, and cheap.

### 5.4 The four questions the brief asks

**Can you interrupt a fiber parked on a promise that ignores the abort signal?** No — measured,
§2.4: nothing happens until the promise settles, 250 ms late. Nor one inside a synchronous loop —
also measured (§3.6 d/e), and no system in §4 claims otherwise. What *runs*, and when: under P2 as
written, the `finally` runs when the work settles; if the work never settles, nothing runs, ever,
and the frame is collected silently (§3.6 i). Under §3.7's raced lowering the `finally` runs at
cancel time and the late result is dropped — Effect's exact semantics, for ~1 µs per suspension
point (831–1240 ns over three rounds, §3.7).

**Does `try`/`finally` give correct finaliser semantics under cancellation?** Partly, and the
spec says exactly which part. ECMA-262 §27.10.5.3 step 5 — editor's draft numbering; §27.7.5.3
in published ES2026, same operation — resumes the suspended context with a `ThrowCompletion`, so
a *rejection* does unwind through `finally` — verified by measurement
(§2.4 c, 51 ms). It is wrong in the three cases of §3.6: a never-settling await, a suspending
`finally`, and a `finally` that returns. beni closes the third by construction and the second with
`sync` (§5.3 row 4); the first is the residue and is the same residue as the question above.

**Is an operation counter achievable under native `async`/`await`?** The counter is trivially
achievable — increment a field on the scope, check it at each emitted suspension point, and `await
new Promise(r => setTimeout(r, 0))` when it trips. **But the counter is the wrong mechanism and
Effect proves it.** §2.3: Effect has the counter, the counter fires 977 times, and the page is
still frozen for 361 ms, because yielding to a *microtask* is not yielding. What is needed is the
macrotask escape, and §4.7 shows Cats Effect (64), kotlinx.coroutines (16) and Effect (2048) all
built the same two-tier thing. §3.3 prices it: **a macrotask yield every 2048 suspension points
costs 5.0× throughput and buys 1.1 ms timer latency instead of 274 ms.** So P2 §7.2's admission
that fairness is unfixed is **too pessimistic about the mechanism and too optimistic about the
cost**: the mechanism is three lines, and the cost is a factor of five on suspension-heavy code.

**Does the event loop suffice as the scheduler?** See §5.5.

### 5.5 The scheduler: the four deciding cases

The event loop is a scheduler. The question is whether it is *the* scheduler, and it turns on four
cases. Three of the four say the event loop is enough; the fourth does not.

| case | does the event loop suffice? |
|---|---|
| **Ordering between ready fibers** — which of two resumable fibers runs next | **Yes.** The microtask queue is FIFO and that is all any of §4's runtimes does within a batch. Priorities (`Effect`'s `PriorityBuckets`) are not something beni needs first. |
| **Bounding in-flight work** | **Yes**, and better — §3.4: a worker pool beats `Promise.all` on time and on memory. This needs no scheduler at all, only a counter. |
| **Parking and resuming** | **Yes.** `PerformPromiseThen` is the resume mechanism and it is one-shot by construction. |
| **Giving the frame back** | **No.** §3.3: a tight `await` loop starves an armed `setTimeout(0)` for its full 274 ms duration. §2.3: Effect's own op counter does not fix it, because it yields into a microtask. |

**So beni needs a scheduler, and the whole of it is the fourth row.** Concretely: a counter on the
current scope, incremented at each emitted suspension point, and when it trips, one
`await new Promise(r => setTimeout(r, 0))` — or `MessagePort.postMessage`, which is what Kotlin
uses in the browser to dodge `setTimeout` clamping (§4.4). That is not a fiber runtime; it is a
dozen lines and a constant. **The constant should be closer to Cats Effect's 64 or Kotlin's 16
than to Effect's 2048**, because §2.3 measured what 2048 costs on a page and §3.3 measured what
the yield costs in throughput; the two together make the budget a real, tunable trade and not a
guess. It is also the one number in this report that should be a `foreign`-configurable platform
constant rather than a language decision, since a server platform wants it large and a browser
platform wants it small.

**This conclusion is independent of the P1/P2 choice.** Shape T needs exactly the same macrotask
escape — Effect *is* shape T and freezes for 361 ms without it.

### 5.6 What this costs, and where the two shapes actually differ

| primitive | typeable under T | typeable under N | runtime under T | runtime under N | measured cost |
|---|---|---|---|---|---|
| spawn / join | yes | yes | free | free, + must catch to avoid unhandled rejection | **692 B, 0.89 µs** per fiber (§3.8) |
| scope | escape unpreventable | escape unpreventable | free | free | implicit join = slowest child (SE-0317) |
| **cancel (prompt)** | yes | yes | **free** — runtime owns `resume` | **not available**; needs §3.7's race | **+~1 µs / suspension point** (831–1240 ns), ~10× (§3.7) |
| cancel (polled) | yes | yes | free | free | **3 ns** / check (§3.5) |
| bracket | yes | yes, if release is `sync` | free | `try`/`finally`, 3 caveats (§3.6) | free |
| bounded parallel | yes | yes | free | **free and faster** | 22 ms vs 92 ms; 78.6 KiB vs 901 MiB (§3.4) |
| race | yes | yes | free | must be a scope, not `Promise.race` | inherits cancel |
| timeout | yes | yes | free | inherits race | 1 fiber + 1 timer |
| retry | yes | yes | free | free | free — **because the argument is a thunk** |
| semaphore | yes | yes | free | free | waiter list |
| queue | yes | yes | free | free | waiter list; **needs `finalizers`** |
| rate limiter | yes | yes | free | free | 1 timer |
| **fairness** | **not free** | **not free** | macrotask escape | macrotask escape | **5.0× throughput** for 1.1 ms latency (§3.3) |

**Read the table by three things.**

*Seven of the eleven primitives are free under both shapes.* The four that are not are all under
native `async`: **cancel** (prompt cancellation is not available at all), **bracket** (`try`/`finally`
with §3.6's three caveats), **race** (must be a scope, not `Promise.race`) and **timeout** (which
inherits race). §5.3 rows 3, 4, 6 and 7 argue each of them at length. The seven that *are* free
under both — spawn/join, scope, bounded parallel, retry, semaphore, queue, rate limiter — are free
in the strong sense: same type, same runtime obligations, no difference in cost.

*The signatures are the same shape modulo `! e`, with three exceptions.* Under P1 each thunk
`() -> a` reads `() -> a ! e` and each combinator is effect-polymorphic in `e` (§5.3's preamble),
which is a uniform rewriting and not a difference of substance. The three real differences are in
what the two documents actually list:

- **`parAll`.** P2 §6 has `Task.parAll : Int, List (() -> a) -> List a`; P1 §6 has
  `Task.parAll : List (() -> a ! e) -> List a ! e`, with **no bound**. Row 5 above says the `Int`
  is mandatory, so this report is on P2's side of that one.
- **`bracket`.** P2 §6 has it; P1 §6 does not. Row 4 is the argument that it is required, and P2
  §6 says so itself (*"`bracket` is the one P1 did not have"*).
- **`race`.** P2 §6 has it; P1 §6 does not. Row 6 is the argument that it is required and that it
  is the primitive P2's own lowering gets wrong.

So §1's conclusion — *"None of them changes the shape of a `Task`"* — survives the removal of
`Task` as a statement about *shape*, but the vocabularies are not interchangeable: P1 §6's claim
to keep *"the vocabulary research 16 says a `Task` runtime must have"* is two primitives short of
it, and P2's list is the more complete one.

*The costs point in opposite directions.* Prompt cancellation is free under T and costs ~10× per
suspension point under N — the largest single argument for P1 in this report, and
the exact thing P2 §11 Q3 asks about. Bounded fan-out is free under both but measurably *better*
under N, because the native shape does not build a fiber per element. And fairness, the defect
§1.3 opened with, is unaffected by the choice: it is the scheduler's problem under either shape,
and §5.5 says it is a dozen lines either way.

**The honest summary for the P1/P2 decision is a narrow one.** The concurrency evidence does not
settle it. It **rules out one position P2 itself leaves open** — P2 §6 ends its combinator bullet
*"over promises these are `Promise.all`, a semaphore, `Promise.race`, and `try`/`finally` — not a
fiber runtime. Whether that is enough is §11 Q3"*, and §11 Q3 poses it as a genuine question;
rows *cancel* and *race* answer it, and the answer is no. It also **refutes the narrower claim P2
does assert without hedging**, in the same section's cancellation bullet: *"Cancelling rejects the
pending `await`, which unwinds through `try`/`finally` in the emitted code — so finalizers run."*
§2.4 measures a cancel at 51 ms whose `finally` runs at 301 ms, and §3.6(i) a `finally` that never
runs at all. It then names the price of the fix (§3.7). If that price is paid at platform
`foreign` boundaries only, P2 keeps its lowering and gets
Effect's cancellation semantics where they matter. If it has to be paid at every suspension point,
the ~10× is a reason to own the resume callback, which is P1.

---

## 6. What could not be settled

- **Every figure in §3 is from Node. Nothing was measured in a browser.** The "frozen page" claim
  in §1.3, §2.3 and §3.3 is inferred from `setTimeout(0)` starvation, which is the right proxy but
  is not rendering. The measurement that would settle §5.5's constant is a `requestAnimationFrame`
  latency histogram under a suspension-heavy load at budgets of 16, 64, 512 and 2048, in Chrome
  and Firefox. It is an afternoon's work with a headless browser and it is the single most
  valuable thing missing from this report, because §5.5 recommends a number and does not have
  browser evidence for it.
- **No published benchmark figure exists for any of §4's runtimes on JavaScript.** Searched for
  ZIO and Cats Effect on Scala.js and for Kotlin/JS coroutines; **no verified number found** in
  any case, from any primary source. Trio publishes none by policy (*"we are willing to accept
  some slowdowns in the service of usability and reliability"*), Swift and errgroup publish none.
  The only attributable numbers in §4 are Spiewak's 2021 gist (JVM, ZIO 2.0.0-M1, no machine spec,
  and his own caveat that the setup favours ZIO) and a kotlinx.coroutines *Flow* benchmark on the
  JVM that measures nothing relevant here. **§4's costing is therefore entirely source-reading
  plus §3's own measurements**, and no cross-runtime performance comparison is made anywhere in
  this report.
- **`Effect.withMaxOpsBeforeYield(e, 1)` and `(e, 4)` diverge** — 4 GB heap exhaustion, reproduced
  twice (§2.3). Not diagnosed, and the Effect issue tracker was not searched. It does not affect
  any conclusion, since no design here uses a budget below 16, but it means the low end of §5.5's
  tuning range is untested in the one runtime that could have validated it.
- **Whether scope escape can be made a type error more cheaply than region typing.** §5.3 row 2
  asserts it cannot, on the strength of `checker.md` §6.3 (*"nothing else may be added to
  `Kind`"*) and P2 §4.1's argument that flags must ride alongside unification. Not investigated:
  an affine or linear `Scope`, or a Haskell-`ST`-style rank-2 skolem on `Task.scope`'s callback.
  The second is the standard answer to exactly this problem and it was not costed against beni's
  checker. If it is cheap, §5.3 row 2 is wrong and beni can have something Trio, Kotlin and Go
  cannot.
- **The recommended scope-signal design in §5.2 is measured only on one side.** §3.5 prices
  `AbortSignal.any` at 384 ns per derivation, and §3.8 prices a per-fiber `AbortController` at
  753 B; the parent-chain-walk alternative §5.2 recommends instead was not measured, only
  reasoned about. Its cost is a pointer chase per check and it should be measured before §5.2 is
  taken as settled.
- **Whether §3.7's raced suspension point survives V8's async stack traces and source maps.** P2
  §7.1's strongest claim is that the native lowering keeps zero-cost async stack traces and native
  debugger stepping. Wrapping every suspension point in `Promise.race` inserts a frame V8 did not
  write, and no measurement of the resulting stack trace, source map or step behaviour was made.
  If it degrades them, §5.3 row 3's "buyable" is more expensive than the ~1 µs suggests.
- **How §3.7's race interacts with P2 §7.3's double translation.** §5.3 row 3 proposes that only
  platform `foreign suspends` primitives get the race. Whether that survives a bit-polymorphic
  `List.map` whose callback is a platform primitive — and therefore whether it needs a third
  compiled body — was not worked out.
- **`Queue` and `RateLimiter` in §5.3 are reasoned from the fiber record, not read from Effect.**
  `internal/queue.js`, `internal/deferred.js` and `RateLimiter.js` were not read line by line, so
  rows 10 and 11's runtime obligations are derived rather than corroborated.
- **Unhandled-rejection behaviour is host-specific and only Node was checked.** §5.3 row 1's
  hazard — a spawned fiber's rejection terminating the process — is Node's default. Browsers
  report and continue; Deno and Bun differ again. Whether `Task.spawn`'s catch is a correctness
  requirement or a politeness depends on which, and that was not enumerated.
- **No primary statement was found on why Effect chose 2048** for either counter, nor on why Cats
  Effect chose 64 or Kotlin 16. The three values are in the source and the reasoning is not. §5.5
  recommends a range on the strength of the measurements alone.
- **True parallelism is out of scope and was not examined.** Everything here assumes one
  JavaScript thread. `Worker`, `SharedArrayBuffer` and the structured-clone boundary change every
  row of §5.6 and none of it was considered; `boundary.md` does not cover them either.
