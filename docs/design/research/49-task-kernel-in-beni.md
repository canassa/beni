# The fiber kernel in beni: what `core/Task.js` needs to move

**Status:** research, 2026-10-02. Not normative. Commissioned as step 2 of
[`plans/core-in-beni.md`](../../../plans/core-in-beni.md): work out what it takes to write
`core/Task.js` — the fiber runtime of [`transparent-effects-proposal.md`](../transparent-effects-proposal.md)
§16 (**P2** below) — in beni over the `Js` intrinsics, held to R47-3's bar
([`plans/browser-decisions.md`](../../../plans/browser-decisions.md): no larger after brotli, no real
slowdown, an equivalent shape). The owner added, the same day, that the fiber runtime needs feature
and quality parity with Effect v4; §6 is the kernel's half of that, beside
[report 48](48-effect-parity-ledger.md)'s ledger of the whole API.

**What was built.** A prototype, on the scratch branch `task-kernel-proto` (commit `6ac5751b`, not
for merging): all of `core/Task.js` as it stood at `84a49831` — before the defect teardown of
`boundary.md` §9.8.14 landed — rewritten as beni in `core/Task.beni`, the sibling deleted, plus one
new intrinsic and one compiler fix (§3). §2 is the per-piece table, §3 the missing capabilities with
proposed spec text, §4 the measurements, §5 the teardown that landed since, §6 the Effect parity of
the kernel's semantics, §7 how to re-run. The slice plan is appended to `plans/core-in-beni.md`.

---

## 0. Findings

1. **Yes: kernel code can be written in beni, and the compiler's own suspendable-form lowering is
   an asset to it, not an obstacle.** The lowering applies only to a call whose callee may suspend,
   and every operation the kernel performs on its state — a `Js.get`, a `Js.set`, a `Js.call` — is
   `impure`, never `suspends`. So the kernel's functions are compiled as the plain code they are,
   handling the sentinel themselves, *except* where one calls another function of the kernel that
   suspends: there the compiler writes exactly the protocol `Task.js` wrote by hand
   (`Task$andThen(cancelAll(…), ($t) => finished(value))` where `finish` wrote
   `if (r === Y) { pending.ks.push(finished); return Y; }`). Three disciplines make it work, all
   expressible today: the kernel's records are `Js.Value`s read and written by name; every beni
   function the kernel *runs* — a fiber's work, a continuation, a finaliser, an observer — is held
   as a `Js.Value` and called with `Js.apply`, so the checker joins none of them into a kernel
   function's classes and **no kernel function gets a `$s` twin**; and `Exit` values cross into
   the kernel's records at a type variable, so they pin no tag. No "kernel mode", no continuation
   intrinsic, no scheduling intrinsic and no mutable record type is needed.
2. **One capability is missing, and it is small: a way for beni to return the sentinel with a
   `suspends` rung.** A beni body built over `Js` can only be inferred `impure`; the functions that
   park (`callback`, `yieldNow`, a self-cancel) must publish `suspends`, or no caller would treat
   them as suspension points. The prototype adds **`Js.suspending : sync (() -> a) -> a`**, the
   mirror of `Js.pure`: written in place as its body, declared `foreign suspends`. The whole kernel
   uses it in one three-line function (`park`). Spec text is §3.1. A second change is a compiler
   fix, not a capability: `Reach` adds the edge to `Task.andThen`/`Task.isWaiting` only when they
   are `foreign` declarations (§3.2).
3. **Correct, by the gates.** With the prototype embedded, `zig build test-blackbox` passes
   **581 of 582** tests: every `run/` program in both builds, every `browser/tea/` page under
   happy-dom (keyed command policies, subscriptions, `Http`, `Time`, `Dom.rendered`, defects in
   fibers), every `emit/` golden. The one failure is the module-graph golden, which gains
   `core:Task -> core:Js`, as it must.
4. **Smaller everywhere it reaches, never larger.** `bench/size.mjs`, release brotli: **20 programs
   smaller, 349 equal, none larger; total 438 262 → 434 101 (−4 161 B)**. Every program that runs a
   fiber is **182–279 B smaller (8–12 %)**; the `Http` + `Time` page **5 306 → 5 099**; the
   `Tea.element` and `Random.generate` pages, which reach only `soon`, −23 and −22. Twelve fiber
   programs built one by one agree (§4.2). The bytes come from the release pipeline the beni kernel
   now goes through — per-function elimination, renaming, joined `const`s — where `Task.js` only got
   `Minify`'s compaction.
5. **As fast, by instructions.** Single-threaded V8, instructions per operation, three rounds of
   whole processes, every figure repeating within ±1 % but one: a suspension point's fast path
   **66 = 66** (development) and **81 = 81** (release); a real park 0.98× and 1.00×; 10 000 fibers
   spawned and joined 0.92× and 0.99×; a scope with a bracket, a spawn and a join 0.98× and
   **1.02×**; a cancellation through a bracket 1.00× and 1.00×. Wall time on a quiet machine agrees
   where it could be read (§4.3). Research 44's 2.4 ns fast path is untouched: `andThen` and
   `isWaiting` compile to `Task.js`'s own bodies, byte for byte.
6. **The shape is `Task.js`'s, statement for statement** (§2, §4.4). The fiber literal is one
   literal — one hidden class, keys in the canonical sorted order; the scheduler is the same FIFO of
   quadruples, the same drain under a `try … finally` (`Js.finally`, no `catch`, rule 9), the same
   run loop as a tail-call loop. Two departures, both measured as noise: a suspension point that is
   not in tail position allocates its continuation before it knows whether the call parked
   (`closeScope`, `join`'s slow path), which a hand-written protocol avoided (§3.3); and a
   `Js.Ref` the program never writes folds to its initial value but leaves its dead branch behind
   (§3.4).
7. **A defect found on the way, in `Task.js` as it is on master:** a fiber started by a finaliser
   of a fiber being cancelled **outlives its parent**. `unwind` cancels the children first (A11),
   then runs the finalisers, then ends the fiber without looking at its children again, so a child a
   release `spawn`s keeps running after its parent ended `Cancelled` — contrary to `Task.beni`'s own
   "nothing a fiber starts outlives what started it". Reproduced (§6, item 1); Effect does not leak
   here, because `interruptChildren` runs after the whole stack has unwound. Not fixed: rule 3 wants
   its red fixture first, and `Task.js` is not to be touched by this study.
8. **The teardown that landed since (§9.8.14) is expressible the same way** (§5): phases as an
   `Int` and `Js.bitAnd`, the root registry and `live` counter as module `Js.Ref`s, the deadline on
   `Js.global "setTimeout"`, finaliser boundaries compared by identity, and `Task.js`'s
   hand-written elimination trick — `failure` and `closing` bound by `newFiber`, so a build with no
   fiber keeps no teardown — as a `Js.Ref` written there. Nothing in it needs more than finding 2.
9. **Effect parity at the kernel is mostly a matter of writing beni, once the kernel is beni**
   (§6). The kernel additions report 48 asks for — `Task.resume`, an interruptible region inside a
   masked one, a detached spawn, `poll`, `race`/`awaitAny` over the private observers, fixed fiber
   slots, a development-only spawn site for logical stack traces — are each a few lines over the
   fiber record in `Task.beni`, where in `Task.js` each would be new hand-written JavaScript plus a
   `foreign` declaration and its arity check.

---

## 1. The central question

`Task.js` implements suspension itself: a call that parks returns the sentinel `Y` and leaves a
pending suspension; each suspendable frame appends the rest of itself; the run loop takes the list
(P2 §16.1). The compiler emits that protocol for every function whose inferred class reaches
`suspends`. So can the code that *implements* the protocol be written in the language the protocol
is emitted for — would the compiler not wrap the kernel's own calls in the protocol, twice?

It would not, because the lowering is keyed on the inferred bit of each *call*, and the kernel
consists of two kinds of function:

- **Functions that manipulate state and handle the sentinel as data.** `run`, `drain`, `schedule`,
  `complete`, `interrupt`, `unwind`, `fork`, `observe` and the rest read and write fields with
  `Js.get`/`Js.set`, compare with `Js.same`, and call the continuations, observers and finalisers
  they hold with `Js.apply` on a `Js.Value`. Every one of those is `impure`; none is `suspends`. So
  the checker infers them `impure`, the backend emits them in the direct form, and the run loop's
  `const result = next(value); if (result === sentinel) …` is written exactly as in `Task.js`. That
  `next` is a `Js.Value` matters: called as a beni function of a parameter's type, the call would
  make the parameter's class *sensitive* (P2 §16.2) and the function would get a `$s` twin. Called
  through `Js.apply`, it is opaque, as a sibling's call is.
- **Functions that compose suspending kernel functions.** `finish` cancels the children, *then*
  completes the fiber; `closeScope` cancels and waits, *then* drops its finaliser; `join` waits,
  *then* reads the outcome. In `Task.js` each wrote the protocol by hand. In beni each is ordinary
  sequential code, `_ = cancelAll (copy children)` then `finished value`, and the compiler's lowering
  writes the protocol — the same calls of `Task.andThen` that every other module gets. They are
  `suspends` because what they call is, which is what they must publish anyway.

The only thing beni cannot say is the bottom of the second kind: the function that *returns* the
sentinel. It is not a call of anything that suspends; it is the definition of suspending. That is
§3.1's one intrinsic.

---

## 2. The pieces, one by one

"Today" means beni over `Js` as it stands on master, plus §3.1 where marked. "Shape" compares the
prototype's development output with `Task.js`, and its release output with `Task.js` after
`Minify` (§4.4 quotes both).

| Piece of `Task.js` | Expressible today? | Shape | Notes |
|---|---|---|---|
| The sentinel `Y`, `pending` | yes: `sentinel = Js.from { waiting = True }`, a module-level `Js.Ref` | identical: `const Task$sentinel = { waiting: true }; let Task$pending = null;` | a module `Js.Ref` that is not `pub` is a `let` (`backend.md` §4) |
| `andThen`, `isWaiting` | yes, with **`sync`** on a non-`foreign` core declaration (R47-4) | identical bodies, dev and release | needs §3.2 so `Reach` keeps them for a module that suspends. `andThen`'s interface now says its arrow depends on `next`'s class, where the `foreign` was `!impure` alone — more precise, and no emitted call reads it |
| The suspension itself: `suspend`'s park, `selfCancel`, `yieldNow`'s park | **no — needs `Js.suspending`** (§3.1) | identical once written: `park` is `Task$pending = {…}; return Task$sentinel;` | one function, `park : V, Bool -> a`, three lines |
| `suspend`'s wait record and `resume` closure | yes: a record literal through `Js.from`, a beni lambda | identical; both `wait` literals share one sorted key order, so one hidden class | `register` is a `sync` parameter, so its call joins nothing suspending |
| The fiber record, `newFiber` | yes: one record literal through `Js.from` | one literal, keys sorted (`children`, `finalizers`, …) where `Task.js` wrote them in its own order; one hidden class either way | read and written only through `Js.get`/`Js.set`, never as a beni record, so no optimiser may assume a field immutable |
| `current`, `outside`, `here` | yes: module `Js.Ref`s → `let`s | `current ?? (outside ??= …)` becomes two `if`s | — |
| The queue, `head`, `scheduled`, `budget` | yes | identical, but `queue[h] = queue[h+1] = … = undefined` is four statements | — |
| `macrotask` (`setImmediate`, else a `MessageChannel`) | yes: `Js.global`, `Js.construct`, `Js.set` on `port1.onmessage` | identical | the prototype tests `setImmediate !== undefined` and a canceller `== null` rather than `typeof … === "function"`: the string literal would add a `Task → String` edge to the module graph (harmless, String is in the prelude's closure) |
| `schedule`, `queueMicrotask` | yes: `Js.apply (Js.global "queueMicrotask") [ Js.from drain ]` | identical; release writes `queueMicrotask(q)` bare | no scheduling intrinsic needed |
| `drain` and its defect guard | yes: `Js.finally`, an `ok` cell, a tail-call loop | `try { for(;;) … } finally { if (!(ok …)) … }`, the loop inlined by release as `Task.js`'s `while` is | rule 9: a `finally`, nothing caught |
| `run`, the run loop | yes: a tail-recursive `loop`, which §8 makes a `for (;;)` | the same loop; release inlines `run` into `resumeFiber`, as V8 would | the continuation is `Js.apply next [ value ]` on a `Js.Value` |
| `complete`, `observe`, `unobserve` | yes: `Js.each` for `for … of` | identical | — |
| `interrupt`, `waitAll`, `cancelAll` | yes; `waitAll`'s counter is a captured `Js.Ref`, a `let` | identical | `waitAll` calls `suspend`, so it suspends by inference |
| `finish`, `finished`, `unwind`, `stopChildren`, `ended` | yes; the composition is the compiler's | `finish`'s slow path is `andThen(cancelAll(…), ($t) => finished(value))`, allocated only when there are children | `unwind` pushes `Js.from ended`, `Js.from stopChildren` and one closure per finaliser, as `Task.js` does |
| `fork`, `spawn`, `spawnIn`, `start`, `endSoon` | yes | identical | the work is `Js.from work`, called by `Js.apply work [ Js.null ]`: **no `$s` twin of `spawn` or `fork`** |
| `callback` | yes | identical | — |
| `join`, `wait`, `outcomeOf`, `joined` | yes | `join`'s slow path pushes `($t) => joined($t)` where `Task.js` pushed `joined` itself: one closure per join that parks | `joined` is a `case` on `Exit`, beni's own value |
| `cancel` | yes | identical; `waitAll [ f ]` in tail position returns what it returns | — |
| `openScope`, `closeScope`, `dropFinalizer`, `openRoot`, `closeRoot` | yes | identical but `closeScope`: the compiler's continuation closure is made before it is known whether `cancelAll` parked (§3.3) | `[...set]` is `Array.from(set)`, ~37 instructions more per copy, measured |
| `soon`, `runSoon`, `queued`, `onDefect` | yes | identical | — |
| `mask`, `unmask`, `pushFinalizer`, `popFinalizer` | yes | identical, but a `()`-returning `mask` returns nothing in release (`backend.md` §4, *A `()` result is not written*), so `uninterruptible`'s work is called with `undefined` where it was `null`; nothing can tell | — |
| `Exit`, `done`, `cancelled` | yes, and better: the kernel builds `Done value` and `Cancelled` as beni values and casts them at a type variable (`host : a -> V`) | `Exit` is no longer pinned by a `foreign` signature, so a page's `Exit` gets integer tags like any type | — |
| `Fiber`, `Scope`, `Resume`, `Soon` | stay `foreign type`s; values cross with `Js.to` | — | opaque, as now |

## 3. What is missing

### 3.1 `Js.suspending`: the one new intrinsic

**Spec text for `boundary.md` §4.2**, after `pure`:

> **`suspending : sync (() -> a) -> a`** (suspends, 2026-10-NN) is the body's value, and the
> opposite promise to `pure`'s: that the value may be the fiber runtime's sentinel, so a call of it
> may suspend. It is how `core/Task.beni` parks a fiber — its `park` sets the pending suspension
> and returns the sentinel through it — and it is the one way beni code acquires the `suspends`
> rung without calling something that already has it. The argument is `sync`: what computes the
> value cannot itself suspend. Unchecked, like every `Js` declaration: a body that returns an
> ordinary value through it costs its callers a comparison and nothing else, and only `Task`
> holds the sentinel. Written with a lambda, it is the lambda's body (`backend.md` §4,
> *`Js.suspending` is its body*).

**Spec text for `backend.md` §4**, a section beside *`Js.pure` is its body*:

> ### `Js.suspending` is its body
>
> `Js.suspending λ() -> body` is lowered as `Js.pure`'s is — wherever the call stands, the body
> stands there instead (`Lower.pureBody`) — and is a **suspension point** wherever it is not in
> tail position: in a value or discarded position the body's value is hoisted and the rest of the
> function becomes its continuation, as for any call whose callee may suspend (P2 §16.3); in tail
> position it is returned as it is. With any other argument it is a call of it. Fixture:
> `emit/core/JsSuspending` (a park in tail position and one in a value position, development and
> release).

**P2 §16.1** gains a sentence: *the sentinel is returned by `core/Task.beni`'s `park` through
`Js.suspending`; the module's other parking operations are beni over it.*

The prototype implements the tail and value positions (`Lower.zig`: `pureBody`, `jsIntrinsicCall`,
and `callExpr` wrapping the value in `suspension`), about ten lines; the discarded position, which
the kernel never uses, needs the same wrap in `discard`.

**Why not something larger.** A *kernel mode* — a declaration whose body the lowering skips — is
not needed, because the lowering already skips everything that does not call a suspending function.
An intrinsic for continuation objects is not needed, because a continuation is a function held as
a `Js.Value`. A scheduling intrinsic is not needed: `queueMicrotask` and `setImmediate` are globals.
And keeping a minimal `foreign suspends park` with a sibling is worse than any of these: the
pending suspension it sets would have to live in the sibling, and with it the run loop that reads
it, which is most of the file.

### 3.2 `Reach` keeps `Task.andThen` and `Task.isWaiting` whatever they are

`Reach.effectEdges` adds the edge from a body that may suspend to `Task.andThen` and
`Task.isWaiting` only for declarations of kind `foreign_value`. Written in beni they are values,
and a program whose own code suspends but which reaches no kernel function that calls `andThen`
(a program that only `yieldNow`s) would lose it. The fix is to drop the kind test (one line); no
spec text moves — P2 §16.2 and `backend.md` §9 already say "core's `Task.andThen`".

### 3.3 Not required: a continuation allocated on the fast path

Outside a tail-call loop, the lowering hands `Task.andThen` a closure for the rest of the function
at every suspension point that is not in tail position, whether or not the call parked
(research 44 §2, the "four calls in sequence" row). `Task.js`'s `closeScope` and `join` tested the
sentinel first and allocated only on the slow path. The prototype was measured both ways —
`closeScope` as the compiler writes it, and hand-written as `Task.js` does (`Js.apply` of
`cancelAll` as data, a test of the sentinel, and `Js.suspending λ() -> andThen r k` on the slow
path) — and the difference was inside the noise of the bimodal workload it sits in (§4.3). So no
capability is asked for. If one is later — for user code as much as for the kernel — it is a
lowering choice, not an intrinsic: write a non-tail suspension point's rest twice when it is
small, `const t = call; if (t === Y) return andThen(t, (t) => rest); rest`, as the loop form does.

### 3.4 Not required: a dead branch after a folded cell

Whole-program specialisation folds a `Js.Ref` nothing writes to its initial value — in a Node
program that never calls `soon` or `onDefect`, `soonRunning` and `defect` are always `null` — but
leaves the branch it makes unreachable: `finally{if(!(a||true))null(null)}` and, in `spawn`,
`if(b!==null||true)return …;` followed by a dead block that reads `null.kids`. It costs bytes, not
speed, and the prototype is smaller anyway; `Opt` folding `x || true` and dropping the unreachable
statement after it is a general improvement, not a requirement of this step.

---

## 4. Measurements

Machine: Ryzen 9 5950X, Linux 6.12, Node v24.19.0. **The machine was shared with other agents'
builds throughout, at load averages of 3 to 62**, so wall-time medians are quoted only from the
windows when the load was under 6, and the primary speed figure is **instructions retired**,
counted with `perf_event_open` over whole `node` processes (a 40-line counter, `icount`, §7) as
`(I(runs) − I(0)) / (runs × ops)`: each process runs the workload five times to warm up and then
`runs` times more, so JIT start-up cancels out.

Builds: master's compiler at `84a49831` with its embedded `core/Task.js` (**js**), against the same
sources plus the prototype (**beni**); `--library` builds of a kernel benchmark (`KBench.beni`, §7)
in development and `--release`.

### 4.1 Correctness

- The sixteen fiber programs of `run/` (`SpawnJoin`, `ScopeChildren`, `BracketRelease`,
  `SuspendDeepRecursion`, `SuspendLoopFastPath`, `SuspendJoinPoint`, `TaskRootScope`,
  `ReadFileErrors`, `JsMaySuspend`, …), built with `--core-root` pointing at the prototype, in
  development and in release: **32 of 32** print their golden.
- The prototype embedded (core replaced in the tree, the binary rebuilt), `zig build
  test-blackbox`: **581 / 582**, the one failure the module-graph golden (finding 3).

### 4.2 Size

`bench/size.mjs`, both compilers, release brotli: **438 262 → 434 101**, 20 smaller, 349 equal, 0
larger. The twenty:

| program | release raw | release brotli |
|---|--:|--:|
| `run/SuspendJoinPoint` | 6 370 → 5 003 | 2 266 → **1 987** (−279) |
| `run/ReadFileErrors` | 7 992 → 6 668 | 2 967 → **2 697** (−270) |
| `run/SuspendDeepRecursion` | 5 172 → 3 805 | 1 771 → **1 508** (−263) |
| `run/ScopeChildren` | 7 690 → 6 338 | 2 585 → **2 327** (−258) |
| `run/SuspendBothWays` | 7 196 → 5 839 | 2 548 → **2 292** (−256) |
| `run/ReadFileDefect` | 6 596 → 5 260 | 2 434 → **2 179** (−255) |
| `run/SuspendLoopClosure` | 7 269 → 5 908 | 2 671 → **2 419** (−252) |
| `run/JsMaySuspend` | 4 928 → 3 628 | 1 721 → **1 472** (−249) |
| `run/SuspendSequence` | 6 405 → 5 151 | 2 246 → **2 001** (−245) |
| `run/SuspendLoopFastPath` | 6 168 → 4 824 | 2 133 → **1 891** (−242) |
| `run/SuspendReadFile` | 6 905 → 5 643 | 2 515 → **2 284** (−231) |
| `run/SpawnJoin` | 6 268 → 5 006 | 2 196 → **1 967** (−229) |
| `run/ReleaseKeepsNamedSpawn` | 5 710 → 4 396 | 1 937 → **1 711** (−226) |
| `run/SuspendListBuildDeep` | 11 172 → 9 820 | 3 654 → **3 431** (−223) |
| page: `browser-tea` with `Http` and `Time` | 14 860 → 13 716 | 5 306 → **5 099** (−207) |
| `run/TaskRootScope` | 7 062 → 5 839 | 2 400 → **2 198** (−202) |
| `run/BracketRelease` | 7 194 → 6 132 | 2 489 → **2 307** (−182) |
| `run/ReleaseKeepsNamedForeign` | 894 → 786 | 433 → **386** (−47) |
| page: empty `Tea.element` | 2 848 → 2 803 | 1 222 → **1 199** (−23) |
| page: `browser-tea random` | 4 563 → 4 503 | 1 955 → **1 933** (−22) |

The browser pages of the corpus, built one by one (`--release`, every emitted file concatenated in
path order, as `bench/size.mjs` does): `tea/Policies` 6 155 → **5 966**, `tea/ClockStops` 4 777 →
**4 564**, `tea/DefectInFiber` 3 561 → **3 328**, `tea/HttpResults` 5 421 → **5 207**,
`tea/DebouncedSearch` 6 036 → **5 804**, `tea/DirectEvents` 7 382 → **7 141**, `tea/KeyEvents`
(no fiber) 2 696 = 2 696. Research 44's `Fibers` app: **2 054 → 1 812**.

Where the bytes come from, read off the two `Fibers` bundles: `Task.js` after `Minify` keeps its
long local names (`value`, `wait`, `outcome`, `observers`), one `const` per statement, and bodies
the program never calls (`Task.wait` and `Task.cancel`, and the `onDefect` slot the drain tests);
the beni kernel is renamed, joined and eliminated per function like any program. The
browser-runtime port saw the same (`plans/runtime-in-beni.md`).

### 4.3 Speed

**Instructions per operation, single-threaded V8** (`node --single-threaded`, so no concurrent
compiler or collector thread moves the count; three rounds, interleaved, each figure one round):

| workload | ops per run | js dev | beni dev | js release | beni release |
|---|--:|--:|--:|--:|--:|
| suspension point, fast path (`Task.andThen`), 4 per call | 4 000 000 | 66 66 66 | 66 66 66 | 81 81 81 | 81 81 81 |
| `yieldNow`: a real park, the queue, the drain, the run loop | 200 000 | 1 097 1 098 1 091 | 1 072 1 069 1 067 | 1 093 1 098 1 094 | 1 096 1 099 1 100 |
| 10 000 fibers spawned, each yields once, joined in order | 10 000 | 5 555 5 428 5 592 | 5 088 5 078 5 106 | 5 529 5 569 5 542 | 5 539 5 440 5 481 |
| a scope, a bracket, a child spawned in it and joined | 20 000 | 9 790 9 844 9 783 | 9 623 9 640 9 616 | 10 070 9 719 10 094 | 10 277 10 331 9 657 |
| a child in a bracket, started, cancelled, its release run | 20 000 | 8 191 8 225 8 247 | 8 218 8 216 8 253 | 8 193 8 201 8 234 | 8 203 8 178 8 232 |

beni over js, medians: **1.00, 0.98, 0.92, 0.98, 1.00** in development and **1.00, 1.00, 0.99,
1.02, 1.00** in release.

With V8's threads on (the default), the same counts are bimodal from process to process on the
three workloads that allocate most — `Task.js`'s scope workload read 7 145–9 816 within one run of
five, the prototype's 9 100–9 666 — and a first reading of 1.28× for the release scope workload
came from that, not from the code: single-threaded, both builds read ~10 000 and repeat.

**Wall time**, `taskset -c 11`, js / beni, medians of seven or nine interleaved rounds of whole
processes, taken in three windows when the load average was between 3.5 and 5.5 (every later
window was not, and is not quoted): fast path 17.37 / 17.34 ms (dev) and 21.09 / 21.09 ms (release;
another window 20.17 / 20.60); `yieldNow` 37.09 / 36.09 and 36.45 / 34.49, each with a spread of
±15 %; fan-out 8.61 / 8.65 and 8.23 / 8.24; scopes 16.36 / 16.76 and 16.03 / 16.76; cancellations
19.13 / 19.04 (release). The scope workload's wall time is bimodal in the beni release build
(16.4–17.0 ms in most processes, 18.5–27 ms in some); its minimum equals `Task.js`'s (16.37 against
16.23). **No reproducible slowdown on any workload**; the scope workload is the one to re-measure on
a quiet machine when the step lands, single-threaded and with threads.

Research 44's fast-path figure (2.4 ns a suspension point) needs no re-run: `Task.andThen` and
`Task.isWaiting` compile to `Task.js`'s bodies (§4.4), and the first row above is equal to the
instruction.

### 4.4 Shape, side by side

`Task.js`, then the prototype's release output (`Fibers`, one scope-hoisted file):

```js
// andThen, isWaiting, the park
const b=(value,y)=>{if(value!==A)return y(value);B.ks.push(y);return A};
const d=(a,e)=>{if(a===b){c.ks.push(e);return b}return e(a)}, e=(a,d)=>{c={interrupt:d,ks:[],wait:a};return b}
// the fiber record
const C=parent=>({stack:[],outcome:null,observers:null,parent,children:null,finalizers:null,masks:0,interrupted:false,unwinding:false,parked:null,scope:null,});
f=a=>({children:null,finalizers:null,interrupted:false,masks:0,observers:null,outcome:null,parent:a,parked:null,scope:null,stack:[],unwinding:false})
// the drain
const S=()=>{let sa=0;let oa=false;try{while(I<H.length){if(sa===K){oa=true;N(S);return}const t=H[I];…;if(t(a,ma,na))sa+=1}oa=true}finally{if(!oa&&R!==null)R(null)}H.length=0;I=0;J=false};
q=()=>{let a=false,b;try{let c=0,d;for(;;){let a=l;if(a>=k.length){d=true;break}if(c===64){p();d=false;break}let b=k[a],e=k[a+1],f=k[a+2],g=k[a+3];…;c=b(e,f,g)?c+1:c}a=true;b=d}finally{if(!(a||true))null(null)}if(b){k.length=0;l=0;m=false}}
// finish: the children cancelled and waited for, then the end
const aa=value=>{const m=E;m.unwinding=true;if(m.children!==null&&m.children.size!==0){const o=_([...m.children],value);if(o===A){B.ks.push(ba);return A}}W(m,done(value));return value};
E=a=>{let b=g;b.unwinding=true;let c=b.children;return c===null||c.size===0?D(a):d(z(A(c)),()=>D(a))}
```

The development output (`Task$park`, `Task$loop`, `Task$finish`, …) reads as `Task.js` with
`Task$` names; `bench/fiber`'s `Bench.beni` builds against it unchanged.

---

## 5. The teardown that landed since

`boundary.md` §9.8.14 landed in `Task.js` after this prototype's base (790 lines against 526). Read
piece by piece, it needs nothing beyond §3:

| Piece | In beni |
|---|---|
| `phase` 0–3, `phase & 1` | a module `Js.Ref Int`, `Js.bitAnd` |
| the root registry, `unlist`, `live` | module `Js.Ref`s; `indexOf`/`splice` through `Js.call` |
| `failure` and `closing`, bound by `newFiber` so a build with no fiber keeps no teardown | `Js.Ref`s written with `Js.from failed` in `newFiber`: `Reach` follows the reference from `newFiber`, exactly the reachability the hand-written trick buys |
| `failed`, `recover`, `stopping`, `teardown`, `allEnded` | ordinary beni over the fiber record; the sweep's `try { … } finally { if (!ok) macrotask(teardown) }` is `Js.finally` |
| the deadline, `expire`, `abandon` | `Js.apply (Js.global "setTimeout") [ … ]` and `clearTimeout` |
| finaliser boundaries, `cutBack`, `cleaning` | `boundary` a top-level function, compared by identity with `Js.same (Js.from boundary)`; `cleaning` a lazily made `Set` |
| `runSoon` dropping work while stopping, `fork` interrupting a fiber started while stopping | one `if` each |

The one thing to watch when porting it is §3.4: a teardown slot that a build never fills is folded
by specialisation, and the dead branch behind it should go too.

---

## 6. The kernel against Effect v4

Report 48 is the ledger of the whole API; this section is the kernel's semantics only — what
`Task.js` does differently from Effect's `FiberImpl` (`references/effect`,
`packages/effect/src/internal/effect.ts:528-760`), which differences are defects, which are
decisions, and how a beni kernel closes the gaps.

**Shortfalls.**

1. **A fiber started during its parent's cancellation outlives it** (finding 7). `unwind` stacks
   `stopChildren`, then the finalisers, then `ended`; `ended` completes the fiber and never looks
   at its children again. A `bracket` release that calls `Task.spawn` therefore starts a child the
   parent never cancels — reproduced with master's compiler: the parent reports `running: no`, and
   50 ms later the child prints. Effect's `evaluate` runs `interruptChildren` after the whole run
   loop has unwound (`effect.ts:632-638`), so a child forked by a finaliser is interrupted and
   awaited. **Fix:** `ended` (and `finished`) cancel and wait for any children that appeared after
   `stopChildren` before completing — in beni, `ended _ = _ = cancelAll (copy children); complete …`,
   which the lowering composes. A red `run/` fixture first.
2. **No interruptible region inside a masked one.** `Task.js` counts masks; Effect has
   `uninterruptibleMask(restore => …)` and `interruptible` (`effect.ts:4541-4562`), so a bracket's
   acquire can wait interruptibly (Effect's `acquireUseRelease` with `interruptible: true`) and a
   masked section can open a window. In a beni kernel: `Task.interruptible : (() -> a) -> a` saves
   the fiber's `masks`, sets it to 0, and restores it after — the save in a `Js.Ref`, the restore
   through the lowering's continuation — and, by beni's rule, a latched interrupt is delivered at
   the window's next suspension point.
3. **The observers are private, so nothing can wait for the first of several fibers.** Effect's
   `addObserver` is the record's public method, on which `race`, `raceAll` and `timeout` are built.
   `Task.js` has `waitAll` but no `waitAny`, and a platform cannot reach the observers. In beni,
   `race` and `waitAny` are written in `Task.beni` over `suspend` and `observe`, beside `waitAll`.
4. **No fiber-local slot.** Effect fibers carry a `Context`, inherited on fork; report 48 (A7)
   wants three or four fixed slots — the clock, the log context, the random seed. In beni they are
   fields of the one fiber literal, copied from the parent in `fork`: still one hidden class.
5. **No identity for a fiber in a report.** Effect's interruption carries the interrupter's id and
   annotations into the `Cause`, and its `Cause.pretty` prints span frames. A1 rules out the
   `Cause`; the report — a logical stack trace of where a fiber was spawned and where it is parked —
   needs a spawn-site field in development builds only. In beni that is
   `if Js.development () then … else …` in `fork`, which costs a release build nothing; in
   `Task.js` it would ship in every build or need a second file.
6. **`Resume` cannot be called from beni** outside `Js` (report 48, finding 2). In beni,
   `Task.resume r v = Js.to (Js.apply (Js.from r) [ Js.from v ])`, one line in core, and every
   coordination primitive report 48 §2.5 lists becomes ordinary beni.

**Departures, each decided and kept.**

- **Where a latched interrupt is delivered.** Effect delivers it the moment a region becomes
  interruptible again (`setInterruptible`'s `contAll`, `effect.ts:4494-4501`); beni at the next
  suspension point (report 43 §9.2 rule 2; `boundary.md` §9.8.14 (a), which explains why the end of
  a region would leak an acquired resource).
- **Children before the parent's finalisers** (A11), where Effect's `forkChild` interrupts children
  after the parent's `onExit` frames have run.
- **A defect is not a value** (A1): Effect's run loop catches every throw as `exitDie`
  (`effect.ts:703-705`); beni's guards are `finally` blocks and the throw reaches the host.
- **Interrupting a parked fiber is queued**, not evaluated inside `interruptUnsafe` as Effect does
  when the fiber is not running (`effect.ts:609-616`); the canceller runs at once in both, and in
  both `cancel` returns only after the cleanup.
- **Pre-emption counts resumptions, never operations.** Effect's `shouldYield` interrupts a run of
  2 048 operations whether or not any parked; beni's budget of 64 counts resumptions per drain
  (P2 §7.5), so code that never parks — including a suspending function on its fast path — is never
  pre-empted. It is what keeps the fast path one comparison.

**Why the beni kernel is the road to parity.** Every addition above, and report 48's kernel list,
is a few lines over the fiber record and the protocol. In `Task.js` each is hand-written
JavaScript, a `foreign` declaration, its arity check and an export kept or dropped by `Minify`; in
`Task.beni` it is beni the checker reads, whose bits are inferred, which the release pipeline
eliminates per function when a program does not use it — the reason §4.2's programs got smaller.

---

## 7. Reproduce

The prototype is commit `6ac5751b` on `task-kernel-proto`. The scripts were scratch files; their
essentials:

- **The benchmark.** `KBench.beni`, `--library --platform=node`, exporting `start` and five
  workloads (`sequenced` — research 44's four suspension points in sequence; `yielding`; `fanOut`;
  `scopes` — `Task.scope` with a `bracket`, a `spawnIn` and a `join`; `cancels` — a child in a
  `bracket` that yields forever, started and cancelled), built by master's compiler and by the
  prototype's with `--core-root`, in development and release.
- **The runner.** A `node` script that imports a build, runs a workload in a root fiber `warm`
  times and then `runs` times, and prints the median (wall mode) or nothing (count mode).
- **The counter.** A C program (`zig cc`) that forks, opens a `PERF_COUNT_HW_INSTRUCTIONS` counter
  on the child with `inherit` and `enable_on_exec`, execs `taskset -c 11 node …`, and prints the
  count; per operation is `(I(12) − I(0)) / (12 × ops)`, with and without `--single-threaded`.
- **Sizes.** `node bench/size.mjs --beni=<compiler>` with each compiler, compared line by line on
  `release_brotli_bytes`.
- **The leak of §6 item 1.** A `node` program: a spawned fiber whose `bracket` release calls
  `Task.spawn` on a function that sleeps 50 ms and logs; the program cancels the fiber, logs
  `Task.running`, and sleeps 200 ms. Master logs the child's line after the parent ended.
